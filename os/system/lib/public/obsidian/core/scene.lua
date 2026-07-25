-- Obsidian Scene module
-- Combines ECS World with spatial systems, rendering, and game logic

---@diagnostic disable: undefined-global

local ecs = require("core.ecs")
local logger = require("core.logger")
local loader = require("core.loader")
local mathUtils = require("core.math")
local uiModule = require("core.ui")
local errorModule = require("core.error")
local EventEmitter = require("core.event")
local debug = require("core.debug")

--- The tile id
---@alias TileID number

--- The tile properties structure for slopes and one-way platforms
---@class TileProperties
---@field type "slope"|"one-way"|string Type of tile (slope, one-way platform, or custom)
---@field hL number? Height left (for slopes)
---@field hR number? Height right (for slopes)

--- The tilemap structure used by the scene
---@class Tilemap
---@field sprite table Tileset sprite
---@field spritePath string|nil Original path to the tileset sprite (for reloading)
---@field data TileID[][] Tile data grid
---@field solidTiles table<TileID, boolean> Set of solid tile IDs for quick lookup
---@field tileProperties table<TileID, TileProperties> Tile properties by ID
---@field tileW number Tile width in pixels
---@field tileH number Tile height in pixels
---@field layers table[]|nil Optional multi-layer format: array of { name=string, data=TileID[][] }

--- A static element in the scene, such as a background tile or decorative object.
---@class StaticElement
---@field sprite table|nil Sprite to draw (optional if collider-only)
---@field spritePath string|nil Original path to the sprite (for reloading)
---@field x number World X coordinate
---@field y number World Y coordinate
---@field z number Render order (lower renders behind)
---@field w number Width for spatial queries (from sprite or collider)
---@field h number Height for spatial queries (from sprite or collider)
---@field collider table|nil|boolean Collider definition { x, y, w, h } relative to (x,y), or `false` for no collider
---@field layer number Collision layer bitmask (default 1)
---@field oneWay boolean Whether this static is a one-way platform (only collides from above)

--- A dynamic element in the scene, representing an entity with a collider for spatial queries.
--- This is not a component but an internal structure used for spatial grid management.
---@class DynamicElement
---@field x number World X coordinate (from `pos` component)
---@field y number World Y coordinate (from `pos` component)
---@field w number Width for spatial queries (from `collider` component)
---@field h number Height for spatial queries (from `collider` component)
---@field collider table Collider definition (table with `x`,`y`,`w`,`h`) taken from the entity's `collider` component
---@field layer number Collision layer bitmask (from `layer` component or default 1)

--- A trigger zone that can call callbacks when entities enter or exit.
---@class TriggerZone
---@field x number World X coordinate
---@field y number World Y coordinate
---@field w number Width of the trigger zone
---@field h number Height of the trigger zone
---@field onEnter function|nil Callback when an entity enters the zone (receives entityId)
---@field onExit function|nil Callback when an entity exits the zone (receives entityId)
---@field entitiesInside table<number, boolean> Set of entity IDs currently inside the trigger

---@type BufferInstance
local buffer = nil -- Injected via Scene.setBuffer(buf) by engine.lua

---@class SceneModule
---@field activeScene SceneInstance|nil Currently active scene instance
local Scene = {}

local WorldProto = getmetatable(ecs.new())
---@class SceneInstance : World
---@field name string Scene name (for debugging)
---@field memory table General-purpose table for storing scene-specific data across systems and scripts
---@field camera Vec2 Current camera position
---@field _lastCam Vec2 Last camera position
---@field _camera table|nil Camera instance
---@field event EventEmitter Event system for the scene
---@field ui table UI system instance
---@field tilemap Tilemap|nil Tilemap data for collision and rendering
---@field _staticElements StaticElement[] List of static elements in the scene
---@field _staticCache table Cache for static rendering: { t = {}, f = {}, b = {} }
---@field _staticDirty boolean Flag indicating if static cache needs to be rebuilt
---@field _staticSortDirty boolean Flag indicating if static elements need to be re-sorted by Z order
---@field _foregroundElements table[] List of foreground elements drawn after dynamic entities
---@field _foregroundSortDirty boolean Flag indicating if foreground elements need to be re-sorted by Z order
---@field _rowsToRestore table<number, boolean> Set of screen rows that need to be restored before drawing (for partial redraw optimization)
---@field _sortedEntities number[] List of entity IDs sorted by Y coordinate for rendering
---@field _zDirty boolean Flag indicating if entities need to be re-sorted by Y coordinate for rendering
---@field _cellSize number Size of spatial grid cells
---@field _spatialGrid table Spatial grid for efficient collision queries: _spatialGrid[cellX][cellY] = { static = StaticElement[], dynamic = table<entityId, DynamicElement> }
---@field _activeDynamicCells table[] List of spatial grid cells that currently contain dynamic entities (for efficient updates)
---@field _triggers TriggerZone[] List of trigger zones in the scene
---@field _systems { update: table[], render: table[] } Tables of ECS systems for update and render phases
---@field onDraw function|nil User-defined hook called after the engine's default drawing (for overlays)
---@field onUpdate function|nil User-defined hook called during the update phase (after systems)
---@field onEvent function|nil User-defined hook called when an event is emitted in the scene
---@field onLoad function|nil User-defined hook called when the scene is loaded
---@field onUnload function|nil User-defined hook called when the scene is unloaded
---@field _hudCallbacks table List of HUD callbacks registered for rendering custom HUD elements
---@field _nextHudId number Incremental ID for HUD callbacks
local SceneInstance = setmetatable({}, { __index = WorldProto })
SceneInstance.__index = SceneInstance

--- Must be called once before any Scene.new() is used
--- Called by engine during initialization to provide the buffer for rendering and UI.
--- @param buf BufferInstance The buffer to use for rendering (injected by engine)
function Scene.setBuffer(buf)
    buffer = buf
end

local _luaDebug = _G and _G.debug

local function tracebackHandler(e)
    return (_luaDebug and _luaDebug.traceback)
        and _luaDebug.traceback(tostring(e), 2)
        or tostring(e)
end

local function deepCopy(orig)
    local copy
    if type(orig) ~= 'table' then return orig end
    copy = {}
    for k, v in pairs(orig) do copy[deepCopy(k)] = deepCopy(v) end
    setmetatable(copy, deepCopy(getmetatable(orig)))
    return copy
end

-- ============================================================================
-- Scene Class
-- ============================================================================

--- Create a new Scene instance (wraps an ECS registry with scene systems).
---@return SceneInstance
function Scene.new()
    local self = ecs.new()
    setmetatable(self, SceneInstance)
    ---@cast self SceneInstance

    self.name = ""
    self.memory = {}

    self.camera = mathUtils.vec2(0, 0)
    self._lastCam = mathUtils.vec2(0, 0)
    self._camera = nil -- Set by camera.new(scene)

    self.event = EventEmitter.new()

    self.ui = uiModule.new(buffer)

    self.tilemap = nil

    -- ========================================================================
    -- Rendering State
    -- ========================================================================

    self._staticElements = {}
    self._staticCache = { t = {}, f = {}, b = {} }
    self._staticDirty = true
    self._staticSortDirty = false

    self._foregroundElements = {}
    self._foregroundSortDirty = false

    self._rowsToRestore = {}
    self._sortedEntities = {}
    self._zDirty = true

    -- ========================================================================
    -- Spatial Grid
    -- ========================================================================

    self._cellSize = 10
    self._spatialGrid = {}
    self._activeDynamicCells = {}

    -- ========================================================================
    -- Game Logic
    -- ========================================================================

    self._triggers = {}
    self._systems = {
        update = {},
        render = {}
    }

    -- HUD callbacks: list of { id=number, name=string, fn=function }
    self._hudCallbacks = {}
    self._nextHudId = 0

    -- Lifecycle hooks
    self.onUpdate = nil
    self.onDraw = nil
    self.onEvent = nil
    self.onLoad = nil
    self.onUnload = nil

    return self
end

--- Creates a new static element definition (background tile or decorative object).
--- This is a helper function for defining static elements without needing to construct the full table manually.
--- @param sprite Sprite|nil Sprite to draw (optional if collider-only)
--- @param x number World X coordinate
--- @param y number World Y coordinate
--- @param config {spritePath?:string, z?:number, collider?:table|boolean, layer?:number, oneWay?:boolean}|nil Additional configuration for the static element
function Scene.newStaticElement(sprite, x, y, config)
    config = config or {}
    return {
        sprite = sprite,
        spritePath = config.spritePath or (sprite and sprite.path),
        x = x,
        y = y,
        z = config.z or -100,
        w = sprite and sprite.width or (config.collider and config.collider.w or 0),
        h = sprite and sprite.height or (config.collider and config.collider.h or 0),
        collider = config.collider,
        layer = config.layer or 1,
        oneWay = config.oneWay or false
    }
end

--- Creates a new trigger zone definition.
--- This is a helper function for defining trigger zones without needing to construct the full table manually.
--- @param x number World X coordinate
--- @param y number World Y coordinate
--- @param w number Width of the trigger zone
--- @param h number Height of the trigger zone
--- @param onEnter function|nil Callback when an entity enters the zone (receives entityId)
--- @param onExit function|nil Callback when an entity exits the zone (receives entityId)
--- @param onStay function|nil Callback when an entity stays in the zone (receives entityId)
--- @return TriggerZone
function Scene.newTriggerZone(x, y, w, h, onEnter, onExit, onStay)
    return {
        x = x,
        y = y,
        w = w,
        h = h,
        onEnter = onEnter,
        onExit = onExit,
        onStay = onStay,
        entitiesInside = {}
    }
end

--- Creates a new tilemap definition.
--- This is a helper function for defining tilemaps without needing to construct the full table manually.
--- @param sprite Sprite Tileset sprite
--- @param data TileID[][] Tile data grid
--- @param solidTiles table<TileID, boolean> Set of solid tile IDs for quick lookup
--- @param tileProperties table<TileID, TileProperties> Tile properties by ID
--- @param spritePath string|nil Original path to the tileset sprite (for reloading)
--- @return Tilemap
function Scene.newTilemap(sprite, data, solidTiles, tileProperties, spritePath)
    return {
        sprite = sprite,
        spritePath = spritePath or (sprite and sprite.path),
        data = data,
        solidTiles = solidTiles or {},
        tileProperties = tileProperties or {},
        tileW = sprite and sprite.width or 1,
        tileH = sprite and sprite.height or 1
    }
end


-- ========================================================================
-- SceneInstance Methods
-- ========================================================================

--- Set the tilemap for the scene (legacy single-layer or multi-layer format).
---@param sprite Sprite Tileset sprite (processed)
---@param data table Tile data grid or layers
---@param solidTiles table|nil
---@param tileProperties table|nil
---@param spritePath string|nil
function SceneInstance:setTilemap(sprite, data, solidTiles, tileProperties, spritePath)
    self.tilemap = {
        sprite = sprite,
        spritePath = spritePath,
        data = data,
        solidTiles = solidTiles or {},
        tileProperties = tileProperties or {},
        tileW = sprite and sprite.width or 1,
        tileH = sprite and sprite.height or 1
    }
    self._staticDirty = true
end

--- Instantiate an entity from a template (table of components).
---@param template table Component template
---@param x number|nil Initial X position (optional, requires 'pos' component in template)
---@param y number|nil Initial Y position (optional, requires 'pos' component in template)
---@return number id ID of the newly created entity
function SceneInstance:instantiate(template, x, y)
    local id = self:spawn()
    for compName, data in pairs(template) do
        self:attach(id, compName, deepCopy(data))
    end
    if x and y then
        if self:has(id, "pos") then
            self:get(id, "pos"):set(x, y)
        else
            self:attach(id, "pos", mathUtils.vec2(x, y))
        end
    end
    return id
end

--- Set a parent for an entity with optional offset.
---@param childId number ID of the child entity
---@param parentId number ID of the parent entity
---@param offsetX number|nil X offset from the parent
---@param offsetY number|nil Y offset from the parent
function SceneInstance:setParent(childId, parentId, offsetX, offsetY)
    self:attach(childId, "parent", {
        id = parentId,
        offset = mathUtils.vec2(offsetX or 0, offsetY or 0)
    })
end

--- Add a static (background) element to the scene.
---@param sprite Sprite Sprite to draw (optional if collider-only)
---@param x number World X coordinate
---@param y number World Y coordinate
---@param config {spritePath?:string, z?:number, collider?:table|boolean, layer?:number, oneWay?:boolean}|nil Additional configuration for the static element
function SceneInstance:addStatic(sprite, x, y, config)
    config = config or {}

    if not sprite and not config.collider then
        logger.warn(string.format(
            "Scene: addStatic at (%.1f, %.1f) with nil sprite and no collider",
            x or 0, y or 0
        ))
    end
    local item = {
        sprite = sprite,
        spritePath = config.spritePath or (sprite and sprite.path),
        x = x,
        y = y,
        z = config.z or -100,
        w = sprite and sprite.width or (config.collider and config.collider.w or 0),
        h = sprite and sprite.height or (config.collider and config.collider.h or 0),
        collider = config.collider,
        layer = config.layer or 1,
        oneWay = config.oneWay or false
    }
    table.insert(self._staticElements, item)
    self._staticSortDirty = true
    self._staticDirty = true
    self:_addToGrid(item, true)
end

--- Add a foreground element drawn after dynamic entities.
---@param sprite Sprite Sprite to draw
---@param x number World X coordinate
---@param y number World Y coordinate
---@param z number|nil Render order (lower renders behind, default 100)
function SceneInstance:addForeground(sprite, x, y, z)
    table.insert(self._foregroundElements, {
        sprite = sprite,
        x = x,
        y = y,
        z = z or 100,
        w = sprite.width,
        h = sprite.height
    })
    self._foregroundSortDirty = true
end

--- Internal: add object to spatial grid.
---@param obj {x:number, y:number, w:number, h:number, collider:table|boolean, layer:number}|StaticElement|DynamicElement
---@param isStatic boolean Whether this is a static element (true) or dynamic entity (false)
---@param id number|nil Entity ID (required if isStatic is false, ignored if isStatic is true)
function SceneInstance:_addToGrid(obj, isStatic, id)
    if obj.collider == false then return end
    local col = obj.collider or { x = 0, y = 0, w = obj.w, h = obj.h }
    local x1 = math.floor((obj.x + col.x) / self._cellSize)
    local y1 = math.floor((obj.y + col.y) / self._cellSize)
    local x2 = math.floor((obj.x + col.x + col.w - 0.001) / self._cellSize)
    local y2 = math.floor((obj.y + col.y + col.h - 0.001) / self._cellSize)

    for cx = x1, x2 do
        for cy = y1, y2 do
            self._spatialGrid[cx] = self._spatialGrid[cx] or {}
            self._spatialGrid[cx][cy] = self._spatialGrid[cx][cy] or {
                static = {},
                dynamic = {}
            }
            local cell = self._spatialGrid[cx][cy]
            obj.layer = obj.layer or 1
            if isStatic then
                table.insert(cell.static, obj)
            else
                if not next(cell.dynamic) then
                    table.insert(self._activeDynamicCells, cell)
                end
                cell.dynamic[id] = obj
            end
        end
    end
end

--- Rebuild dynamic spatial grid from entities with `pos`+`collider`.
function SceneInstance:_updateDynamicGrid()
    for i = 1, #self._activeDynamicCells do
        self._activeDynamicCells[i].dynamic = {}
    end
    self._activeDynamicCells = {}

    local entities = self:select("pos", "collider")
    for _, id in ipairs(entities) do
        local p = self:get(id, "pos")
        local c = self:get(id, "collider")
        local l = self:get(id, "layer") or 1

        self:_addToGrid({
            x = p.x,
            y = p.y,
            w = c.w,
            h = c.h,
            collider = c,
            layer = l
        }, false, id)
    end
end

--- Return entity id at world coordinates (or nil).
---@param worldX number World X coordinate
---@param worldY number World Y coordinate
---@param ignoreId number|nil Entity ID to ignore (optional)
---@return number|nil ID of the entity at the given coordinates, or nil if none
function SceneInstance:getEntityAt(worldX, worldY, ignoreId)
    local cx = math.floor(worldX / self._cellSize)
    local cy = math.floor(worldY / self._cellSize)
    local cell = self._spatialGrid[cx] and self._spatialGrid[cx][cy]

    if cell then
        for id, obj in pairs(cell.dynamic) do
            if id ~= ignoreId then
                local col = obj.collider
                local icx = obj.x + col.x
                local icy = obj.y + col.y

                if worldX >= icx and worldX < icx + col.w and
                   worldY >= icy and worldY < icy + col.h then
                    return id
                end
            end
        end
    end
    return nil
end

--- Get Euclidean distance between two entities (by id).
---@param id1 number Entity ID of the first entity
---@param id2 number Entity ID of the second entity
---@return number distance Distance between the two entities, or 9999 if either entity doesn't exist or lacks a `pos` component
function SceneInstance:getDistance(id1, id2)
    local p1 = self:get(id1, "pos")
    local p2 = self:get(id2, "pos")
    if not p1 or not p2 then return 9999 end
    return mathUtils.dist(p1.x, p1.y, p2.x, p2.y)
end

--- Query dynamic entities whose collider intersects rect.
---@param x number World X coordinate of the rect
---@param y number World Y coordinate of the rect
---@param w number Width of the rect
---@param h number Height of the rect
---@param layerMask number|nil Collision layer bitmask to filter entities (optional)
---@return number[] List of entity IDs whose colliders intersect the given rect and match the layer mask
function SceneInstance:queryRect(x, y, w, h, layerMask)
    local results = {}
    local x1 = math.floor(x / self._cellSize)
    local y1 = math.floor(y / self._cellSize)
    local x2 = math.floor((x + w) / self._cellSize)
    local y2 = math.floor((y + h) / self._cellSize)

    for cx = x1, x2 do
        if self._spatialGrid[cx] then
            for cy = y1, y2 do
                local cell = self._spatialGrid[cx][cy]
                if cell then
                    for id, obj in pairs(cell.dynamic) do
                        if not layerMask or bit.band(obj.layer or 1, layerMask) > 0 then
                            local c = obj.collider
                            local icx = obj.x + c.x
                            local icy = obj.y + c.y

                            if x < icx + c.w and x + w > icx and
                               y < icy + c.h and y + h > icy then
                                table.insert(results, id)
                            end
                        end
                    end
                end
            end
        end

    end

    return results
end

--- Return UI element name at screen coordinates or nil.
---@param screenX number Screen X coordinate
---@param screenY number Screen Y coordinate
---@return string|nil ui Name of the UI element at the given screen coordinates, or nil if none
function SceneInstance:getUIAt(screenX, screenY)
    local ox, oy = 0, 0
    if debug.designW and debug.designH then
        local tw, th = buffer:getSize()
        ox = math.floor((tw - debug.designW) / 2)
        oy = math.floor((th - debug.designH) / 2)
    end

    for i = #self.ui.sorted, 1, -1 do
        local el = self.ui.sorted[i]
        local ex, ey = self.ui:getAbsolutePos(el, ox, oy)

        if screenX >= ex and screenX < ex + el.w and
           screenY >= ey and screenY < ey + el.h then
            return el.name
        end
    end
end

-- ========================================================================
-- Collision & Raycasting
-- ========================================================================

--- Cast a ray and return hit info: (hit:boolean, x:number, y:number, entityId?:number)
---@param startX number Starting X coordinate of the ray
---@param startY number Starting Y coordinate of the ray
---@param targetX number Target X coordinate of the ray
---@param targetY number Target Y coordinate of the ray
---@param maxDist number|nil Maximum distance to check along the ray (optional, default 100)
---@param ignoreId number|nil Entity ID to ignore during the raycast (optional)
---@param layerMask number|nil Collision layer bitmask to filter entities during the raycast (optional)
---@return boolean, number, number, number|nil hit Whether the ray hit an obstacle, the X and Y coordinates of the hit or end point, and the ID of the hit entity (if applicable)
function SceneInstance:castRay(startX, startY, targetX, targetY, maxDist, ignoreId, layerMask)
    local stepX, stepY, dist = mathUtils.normalizeRaw(targetX - startX, targetY - startY)

    if dist == 0 then
        return false, startX, startY
    end

    local checkDist = math.min(dist, maxDist or 100)

    for d = 0, checkDist, 0.5 do
        local curX = startX + stepX * d
        local curY = startY + stepY * d

        local cx = math.floor(curX / self._cellSize)
        local cy = math.floor(curY / self._cellSize)
        local cell = self._spatialGrid[cx] and self._spatialGrid[cx][cy]

        if cell then
            for id, obj in pairs(cell.dynamic) do
                if id ~= ignoreId and (not layerMask or bit.band(obj.layer or 1, layerMask) > 0) then
                    local c = obj.collider
                    local ox = (obj.x or 0) + (c.x or 0)
                    local oy = (obj.y or 0) + (c.y or 0)

                    if curX >= ox and curX < ox + (c.w or 0) and
                       curY >= oy and curY < oy + (c.h or 0) then
                        return true, curX, curY, id
                    end
                end
            end

            for _, item in ipairs(cell.static) do
                if item.collider ~= false and
                   (not layerMask or bit.band(item.layer or 1, layerMask) > 0) then
                    local col = item.collider
                    local ox = (item.x or 0) + (col and col.x or 0)
                    local oy = (item.y or 0) + (col and col.y or 0)
                    local ow = col and col.w or item.w or 0
                    local oh = col and col.h or item.h or 0

                    if curX >= ox and curX < ox + ow and
                       curY >= oy and curY < oy + oh then
                        return true, curX, curY, nil
                    end
                end
            end
        end
    end

    return false, startX + stepX * checkDist, startY + stepY * checkDist
end

--- Line-of-sight check between two cells (Bresenham-based).
---@param ax number Starting X coordinate
---@param ay number Starting Y coordinate
---@param bx number Target X coordinate
---@param by number Target Y coordinate
---@param cw number|nil Width of the area to check around the line (optional, default 1)
---@param ch number|nil Height of the area to check around the line (optional, default 1)
---@param ignoreId number|nil Entity ID to ignore during the LOS check (optional)
---@param layerMask number|nil Collision layer bitmask to filter entities during the LOS check (optional)
---@return boolean hasLOS True if there is a clear line of sight between the two points, false if blocked by any obstacle
function SceneInstance:hasLOS(ax, ay, bx, by, cw, ch, ignoreId, layerMask)
    cw = cw or 1
    ch = ch or 1

    local x0, y0 = math.floor(ax), math.floor(ay)
    local x1, y1 = math.floor(bx), math.floor(by)
    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx - dy
    local cx, cy = x0, y0

    while cx ~= x1 or cy ~= y1 do
        local e2 = 2 * err
        local stepX = e2 > -dy
        local stepY = e2 < dx

        if stepX and stepY then
            if self:isAreaBlocked(cx + sx, cy, cw, ch, ignoreId, layerMask) or
               self:isAreaBlocked(cx, cy + sy, cw, ch, ignoreId, layerMask) then
                return false
            end
        end

        if stepX then err = err - dy; cx = cx + sx end
        if stepY then err = err + dx; cy = cy + sy end

        if (cx ~= x1 or cy ~= y1) and
           self:isAreaBlocked(cx, cy, cw, ch, ignoreId, layerMask) then
            return false
        end
    end

    return true
end

--- Check whether an axis-aligned area is blocked by tiles/statics/dynamics.
---@param x number World X coordinate of the area
---@param y number World Y coordinate of the area
---@param w number Width of the area
---@param h number Height of the area
---@param ignoreId number|nil Entity ID to ignore during the check (optional)
---@param layerMask number|nil Collision layer bitmask to filter entities during the check (optional)
---@return boolean, string|number|nil, number|nil isBlocked True if the area is blocked, the type of obstacle ("tile", "static", or entity ID), and for slopes/platforms the Y coordinate of the ground
function SceneInstance:isAreaBlocked(x, y, w, h, ignoreId, layerMask)
    local bestSlopeY = nil

    if self.tilemap then
        local tm = self.tilemap
        local startX = math.floor(x / tm.tileW) + 1
        local startY = math.floor(y / tm.tileH) + 1
        local endX = math.floor((x + w - 0.001) / tm.tileW) + 1
        local endY = math.floor((y + h - 0.001) / tm.tileH) + 1

        for ty = startY, endY do
            if tm.data[ty] then
                for tx = startX, endX do
                    local tileId = tm.data[ty][tx]
                    if tileId then
                        local prop = tm.tileProperties[tileId]

                        if prop and prop.type == "slope" then
                            local relX = (x + w/2 - (tx-1)*tm.tileW) / tm.tileW
                            relX = mathUtils.clamp(relX, 0, 1)
                            local slopeHeight = mathUtils.lerp(prop.hL, prop.hR, relX) * tm.tileH
                            local groundY = (ty-1)*tm.tileH + (tm.tileH - slopeHeight)

                            if y + h > groundY then
                                bestSlopeY = groundY
                            end
                        elseif prop and prop.type == "one-way" then
                            local platformY = (ty-1)*tm.tileH
                            if ignoreId then
                                local vel = self:get(ignoreId, "velocity")

                                if vel and vel.y > 0 and
                                (y + h - vel.y * 0.1) <= platformY then
                                    if y + h > platformY then
                                        bestSlopeY = platformY
                                    end
                                end
                            end
                        elseif tm.solidTiles[tileId] then
                            return true, "tile"
                        end
                    end
                end
            end
        end
    end

    if bestSlopeY then
        return true, "tile", bestSlopeY
    end

    local x1 = math.floor(x / self._cellSize)
    local y1 = math.floor(y / self._cellSize)
    local x2 = math.floor((x + w - 0.001) / self._cellSize)
    local y2 = math.floor((y + h - 0.001) / self._cellSize)

    for cx = x1, x2 do
        if self._spatialGrid[cx] then
            for cy = y1, y2 do
                local cell = self._spatialGrid[cx][cy]
                if cell then
                    for _, item in ipairs(cell.static) do
                        if item.collider ~= false and
                           (not layerMask or bit.band(item.layer or 1, layerMask) > 0) then
                            local col = item.collider
                            local ox, oy, ow, oh

                            if col then
                                ox = item.x + (col.x or 0)
                                oy = item.y + (col.y or 0)
                                ow = col.w or item.w or 0
                                oh = col.h or item.h or 0
                            else
                                ox = item.x or 0
                                oy = item.y or 0
                                ow = item.w or 0
                                oh = item.h or 0
                            end

                            if x < ox + ow and x + w > ox and
                               y < oy + oh and y + h > oy then
                                if item.oneWay then
                                    if ignoreId then
                                        local vel = self:get(ignoreId, "velocity")
                                        if vel and vel.y >= 0 and
                                        (y + h - vel.y * 0.1) <= oy then
                                            return true, "static"
                                        end
                                    end
                                else
                                    return true, "static"
                                end
                            end
                        end
                    end

                    for id, obj in pairs(cell.dynamic) do
                        if id ~= ignoreId and
                           (not layerMask or bit.band(obj.layer or 1, layerMask) > 0) then
                            local col = obj.collider
                            local ox = (obj.x or 0) + (col.x or 0)
                            local oy = (obj.y or 0) + (col.y or 0)

                            if x < ox + (col.w or 0) and x + w > ox and
                               y < oy + (col.h or 0) and y + h > oy then
                                return true, id
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- ========================================================================
-- Triggers
-- ========================================================================

--- Add a trigger zone with enter/exit callbacks.
---@param x number World X coordinate of the trigger zone
---@param y number World Y coordinate of the trigger zone
---@param w number Width of the trigger zone
---@param h number Height of the trigger zone
---@param onEnter fun(id:number)|nil Callback function that is called when an entity enters the trigger zone. Receives the entity ID as an argument. Can be nil if no callback is needed.
---@param onExit fun(id:number)|nil Callback function that is called when an entity exits the trigger zone. Receives the entity ID as an argument. Can be nil if no callback is needed.
function SceneInstance:addTrigger(x, y, w, h, onEnter, onExit)
    table.insert(self._triggers, {
        x = x,
        y = y,
        w = w,
        h = h,
        onEnter = onEnter,
        onExit = onExit,
        entitiesInside = {}
    })
end

--- Internal: update trigger zones and call callbacks.
function SceneInstance:_updateTriggers()
    for _, trigger in ipairs(self._triggers) do
        local entities = self:queryRect(trigger.x, trigger.y, trigger.w, trigger.h)
        local entityMap = {}
        for _, id in ipairs(entities) do
            entityMap[id] = true
        end

        for id in pairs(trigger.entitiesInside) do
            if not entityMap[id] then
                if trigger.onExit then
                    trigger.onExit(id)
                end
                trigger.entitiesInside[id] = nil
            end
        end

        for _, id in ipairs(entities) do
            if not trigger.entitiesInside[id] then
                if trigger.onEnter then
                    trigger.onEnter(id)
                end
                trigger.entitiesInside[id] = true
            end
        end
    end
end

-- ========================================================================
-- UI Management
-- ========================================================================

--- Load OUI file and add elements to UI.
---@param path string Path to the OUI file to load
---@param x number|nil Optional X offset to apply to all loaded UI elements (default 0)
---@param y number|nil Optional Y offset to apply to all loaded UI elements (default 0)
function SceneInstance:loadUI(path, x, y)
    local uiData, err = loader.loadUI(path)
    if not uiData then
        logger.error("Failed to load OUI: " .. tostring(err))
        return
    end

    for name, el in pairs(uiData.elements) do
        self.ui:add(name, el.type, (x or 0) + (el.x or 0), (y or 0) + (el.y or 0), el)
    end
end

--- Unload OUI elements from UI by path.
---@param path string Path to the OUI file to unload (must match the path used in loadUI)
function SceneInstance:unloadUI(path)
    local uiData = loader.loadUI(path)
    if uiData then
        for name in pairs(uiData.elements) do
            self.ui:remove(name)
        end
    end
end

--- Add a UI element (proxy to ui module).
---@param name string Unique name for the UI element
---@param type string Type of the UI element (e.g., "text", "image", "button")
---@param x number Screen X coordinate
---@param y number Screen Y coordinate
---@param config table|nil Additional configuration for the UI element (e.g., text content, sprite path, size, etc.)
---@return table element The created UI element, or nil if creation failed (e.g., due to duplicate name)
function SceneInstance:addUI(name, type, x, y, config)
    return self.ui:add(name, type, x, y, config)
end

--- Update a UI element configuration.
---@param name string Unique name of the UI element to update
---@param config table New configuration for the UI element (e.g., text content, sprite path, size, etc.)
function SceneInstance:updateUI(name, config)
    self.ui:update(name, config)
end

--- Bind a HUD updater function to a UI element name. The function is called
--- every frame from the scene update loop and receives the scene instance.
---@param name string Name of the UI element this HUD callback is associated with (for organizational purposes, not used for lookup)
---@param fn fun(scene:SceneInstance, dt:number) Function that updates the HUD element. Receives the scene instance and delta time as arguments.
---@return number id Unique ID for the bound HUD callback, which can be used to unbind it later
function SceneInstance:bindHUD(name, fn)
    self._nextHudId = (self._nextHudId or 0) + 1
    local id = self._nextHudId
    table.insert(self._hudCallbacks, { id = id, name = name, fn = fn })
    return id
end

--- Unbind a previously bound HUD updater by id.
---@param id number Unique ID of the HUD callback to unbind (returned from bindHUD)
function SceneInstance:unbindHUD(id)
    for i = #self._hudCallbacks, 1, -1 do
        if self._hudCallbacks[i].id == id then
            table.remove(self._hudCallbacks, i)
        end
    end
end

-- ========================================================================
-- Systems
-- ========================================================================

--- Register an update system. `filter` is an array of component names.
---@param filter string[] Array of component names that an entity must have to be included in this system's update calls
---@param fn fun(dt:number, entities:number[], components:table) Function that updates entities matching the filter. Receives delta time, list of entity IDs, and a components table for accessing component data.
function SceneInstance:addSystem(filter, fn)
    table.insert(self._systems.update, {
        filter = filter,
        update = fn
    })
end

-- ========================================================================
-- Component Overrides (for rendering hooks)
-- ========================================================================

--- Attach component to entity and mark z-order dirty for render-relevant components.
---@param id number Unique ID of the entity
---@param component string Name of the component to attach
---@param data any Data associated with the component
function SceneInstance:attach(id, component, data)
    WorldProto.attach(self, id, component, data)

    if component == "z" or component == "sprite" then
        if component == "sprite" and data == nil then
            logger.warn("Scene: Sprite component set to nil for entity " .. tostring(id))
        end
        self._zDirty = true
    end
end

--- Despawn entity and mark affected rows for restoration.
---@param id number Unique ID of the entity to despawn
function SceneInstance:despawn(id)
    local p = self:get(id, "pos")
    local s = self:get(id, "sprite")

    if p and s then
        local termW, termH = buffer:getSize()
        local designW, designH = debug.designW, debug.designH
        local offsetY = (designW and designH) and math.floor((termH - designH) / 2) or 0
        local totalCamY = self.camera.y - offsetY

        local sy = math.floor(p.y - totalCamY)
        for i = 0, s.height - 1 do
            local targetY = sy + i
            if targetY >= 1 and targetY <= termH then
                self._rowsToRestore[targetY] = true
            end
        end
    end

    WorldProto.despawn(self, id)
    self._zDirty = true
end

-- ========================================================================
-- Update Loop
-- ========================================================================

--- Update scene systems and user `onUpdate` hook.
---@param dt number Delta time since last update (in seconds)
function SceneInstance:update(dt)
    self:_updateDynamicGrid()

    local children = self:select("pos", "parent")
    for _, id in ipairs(children) do
        local parentData = self:get(id, "parent")
        local parentPos = self:get(parentData.id, "pos")
        local childPos = self:get(id, "pos")

        if parentPos and childPos then
            childPos:set(
                parentPos.x + parentData.offset.x,
                parentPos.y + parentData.offset.y
            )
        end
    end

    for _, system in ipairs(self._systems.update) do
        local entities = self:select(table.unpack(system.filter))
        local ok, err = xpcall(function()
            system.update(dt, entities, self._store)
        end, tracebackHandler)

        if not ok then
            local filterStr = "[" .. table.concat(system.filter, ", ") .. "]"
            errorModule.report("System " .. filterStr .. ":\n" .. err)
            return
        end
    end

    self:_updateTriggers()

    if self.onUpdate then
        local ok, err = xpcall(self.onUpdate, tracebackHandler, dt)
        if not ok then
            errorModule.report("Scene.onUpdate:\n" .. err)
            return
        end
    end

    for _, hud in ipairs(self._hudCallbacks) do
        local ok, err = xpcall(function() hud.fn(self, dt) end, tracebackHandler)
        if not ok then
            errorModule.report("HUD callback:\n" .. err)
        end
    end
end

-- ========================================================================
-- Render Loop
-- ========================================================================

--- Draw scene: static layers, entities, foreground and UI.
function SceneInstance:draw()

    local camMoved = self.camera.x ~= self._lastCam.x or
                    self.camera.y ~= self._lastCam.y
    local termW, termH = buffer:getSize()

    local designW, designH = debug.designW, debug.designH
    local offsetX, offsetY = 0, 0
    if designW and designH then
        offsetX = math.max(0, math.floor((termW - designW) / 2))
        offsetY = math.max(0, math.floor((termH - designH) / 2))
    end

    local shakeX, shakeY = 0, 0
    if self._camera and self._camera:isShaking() then
        shakeX, shakeY = self._camera:getShakeOffset()
    end

    local totalCamX = self.camera.x - offsetX + shakeX
    local totalCamY = self.camera.y - offsetY + shakeY

    if self._staticSortDirty then
        table.sort(self._staticElements, function(a, b)
            return a.z < b.z
        end)
        self._staticSortDirty = false
    end

    if self._foregroundSortDirty then
        table.sort(self._foregroundElements, function(a, b)
            return a.z < b.z
        end)
        self._foregroundSortDirty = false
    end

    if self._staticDirty or camMoved or
       (self._camera and self._camera:isShaking()) then
        self:_renderStatic(totalCamX, totalCamY, termW, termH)
    else
        self:_restoreRows()
    end

    self:_renderEntities(totalCamX, totalCamY, termW, termH)

    self:_renderForeground(totalCamX, totalCamY, termW, termH)

    if not debug.unsupportedResolution then
        self.ui:draw(offsetX, offsetY, self._rowsToRestore)
    end

    if self._camera and self._camera:isFlashing() then
        local fc = self._camera:getFlashColor()
        buffer:drawRect(1, 1, termW, termH, " ", fc, fc)
    end

    if debug.enabled then
        self:_renderDebug(termW, termH)
    end

    if self.onDraw then
        local ok, err = xpcall(self.onDraw, tracebackHandler)
        if not ok then
            errorModule.report("Scene.onDraw:\n" .. err)
        end
    end
end

--- Internal: render tilemap + static elements into the static cache buffer.
---@param camX number Camera X coordinate
---@param camY number Camera Y coordinate
---@param termW number Terminal width in characters
---@param termH number Terminal height in characters
function SceneInstance:_renderStatic(camX, camY, termW, termH)
    buffer:clear()

    if self.tilemap then
        local tm = self.tilemap
        local startX = math.max(1, math.floor(camX / tm.tileW) + 1)
        local startY = math.max(1, math.floor(camY / tm.tileH) + 1)
        local endX = math.floor((camX + termW) / tm.tileW) + 1
        local endY = math.floor((camY + termH) / tm.tileH) + 1

        if tm.layers then
            for _, layer in ipairs(tm.layers) do
                for ty = startY, endY do
                    if layer.data[ty] then
                        for tx = startX, endX do
                            local tid = layer.data[ty][tx]
                            if tid and tid > 0 and tm.sprite[tid] then
                                buffer:drawSprite(
                                    tm.sprite[tid],
                                    (tx-1) * tm.tileW,
                                    (ty-1) * tm.tileH,
                                    camX, camY
                                )
                            end
                        end
                    end
                end
            end
        else
            for ty = startY, endY do
                if tm.data[ty] then
                    for tx = startX, endX do
                        local tid = tm.data[ty][tx]
                        if tid and tid > 0 and tm.sprite[tid] then
                            buffer:drawSprite(
                                tm.sprite[tid],
                                (tx-1) * tm.tileW,
                                (ty-1) * tm.tileH,
                                camX, camY
                            )
                        end
                    end
                end
            end
        end
    end

    for _, item in ipairs(self._staticElements) do
        local s = item.sprite
        local sx = math.floor(item.x - camX)
        local sy = math.floor(item.y - camY)

        if s and s[1] and
           sx + s.width >= 1 and sx <= termW and
           sy + s.height >= 1 and sy <= termH then
            buffer:drawSprite(s[1], item.x, item.y, camX, camY)
        end
    end

    buffer:copyTo(self._staticCache)
    self._staticDirty = false
    self._rowsToRestore = {}
    self._lastCam.x, self._lastCam.y = self.camera.x, self.camera.y
end

--- Internal: restore only dirty rows from the static cache (partial redraw).
function SceneInstance:_restoreRows()
    for y in pairs(self._rowsToRestore) do
        buffer:restoreLine(y, self._staticCache)
    end
    self._rowsToRestore = {}
end

--- Internal: render all dynamic entities sorted by z-order.
---@param camX number Camera X coordinate
---@param camY number Camera Y coordinate
---@param termW number Terminal width in characters
---@param termH number Terminal height in characters
function SceneInstance:_renderEntities(camX, camY, termW, termH)
    if self._zDirty then
        self._sortedEntities = self:select("pos", "sprite")
        table.sort(self._sortedEntities, function(a, b)
            local za = self:get(a, "z") or 0
            local zb = self:get(b, "z") or 0
            return za < zb
        end)
        self._zDirty = false
    end

    debug.dynamicCount = #self._sortedEntities

    for _, id in ipairs(self._sortedEntities) do
        local p = self:get(id, "pos")
        local s = self:get(id, "sprite")

        local anim = self:get(id, "animation")
        local frameIdx = 1

        if anim and anim.sequences and anim.state then
            local seq = anim.sequences[anim.state]
            frameIdx = seq and seq[anim.currentFrame or 1] or (anim.currentFrame or 1)
        elseif anim then
            frameIdx = anim.currentFrame or 1
        end

        local currentFrame = s and s[frameIdx]

        if currentFrame then
            local sx = math.floor(p.x - camX)
            local sy = math.floor(p.y - camY)
            local frameW = s.width or 0
            local frameH = s.height or 0

            if sx + frameW >= 1 and sx <= termW and
               sy + frameH >= 1 and sy <= termH then

                local colorOverride = self:get(id, "colorOverride")
                local charOverride = self:get(id, "charOverride")
                local bgOverride = self:get(id, "bgOverride")

                if colorOverride or charOverride or bgOverride then
                    -- Draw with color/char/bg override: use sprite chars as fallback so
                    -- the entity stays visible when only colorOverride is set.
                    for row = 0, frameH - 1 do
                        local ty = math.floor(p.y - camY) + row
                        local rowStr
                        if charOverride then
                            rowStr = string.rep(charOverride:sub(1, 1), frameW)
                        elseif currentFrame[1] and currentFrame[1][row + 1] then
                            rowStr = table.concat(currentFrame[1][row + 1])
                        else
                            rowStr = string.rep(" ", frameW)
                        end
                        buffer:drawText(math.floor(p.x - camX), ty, rowStr, colorOverride or " ", bgOverride or " ")
                    end
                else
                    buffer:drawSprite(currentFrame, p.x, p.y, camX, camY)
                end

                for i = 0, frameH - 1 do
                    local targetY = sy + i
                    if targetY >= 1 and targetY <= termH then
                        self._rowsToRestore[targetY] = true
                    end
                end
            end
        end
    end
end

--- Internal: render foreground elements on top of dynamic entities.
---@param camX number Camera X coordinate
---@param camY number Camera Y coordinate
---@param termW number Terminal width in characters
---@param termH number Terminal height in characters
function SceneInstance:_renderForeground(camX, camY, termW, termH)
    for _, item in ipairs(self._foregroundElements) do
        local s = item.sprite
        local sx = math.floor(item.x - camX)
        local sy = math.floor(item.y - camY)

        if s and s[1] and
           sx + s.width >= 1 and sx <= termW and
           sy + s.height >= 1 and sy <= termH then
            buffer:drawSprite(s[1], item.x, item.y, camX, camY)

            for i = 0, s.height - 1 do
                self._rowsToRestore[sy + i] = true
            end
        end
    end
end

--- Internal: render debug overlay (FPS, entity count, logs).
function SceneInstance:_renderDebug()
    if debug.alwaysOnTop then return end
    local stats = string.format(
        "FPS: %d | Upd: %dms | Draw: %dms",
        debug.fps, debug.updateTime, debug.drawTime
    )
    local entInfo = string.format(
        "Entities: %d (Dyn) | %d (Stat)",
        debug.dynamicCount, #self._staticElements
    )

    buffer:drawText(1, 1, stats, "0", "f")
    buffer:drawText(1, 2, entInfo, "7", "f")
    self._rowsToRestore[1] = true
    self._rowsToRestore[2] = true

    if debug.showLogs then
        local history = logger.getHistory()
        for i, entry in ipairs(history) do
            buffer:drawText(1, 3 + i, entry.text, entry.color, "f")
            self._rowsToRestore[3 + i] = true
        end
    end
end

return Scene