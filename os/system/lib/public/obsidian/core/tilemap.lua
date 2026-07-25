--- Obsidian Tilemap Module
-- Multi-layer tile map with collision, slopes, one-way platforms, and
-- runtime editing.  Connects to a Scene via map:attach(scene).
--
-- Coordinate conventions:
--   Tile   coords: (tx, ty)  1-based
--   World  coords: (wx, wy)  pixel-space, same as scene entities
--
-- Basic usage:
--   local map = Engine.tilemap.new({ tileW = 2, tileH = 1 })
--   map:defineTile(1, { sprite = "assets/grass.osf" })
--   map:defineTile(2, { sprite = "assets/stone.osf", solid = true })
--   map:addLayer("bg",        { z = -200 })
--   map:addLayer("collision", { z = -100, collision = true })
--   map:setTile("bg",        3,  2, 1)
--   map:setTile("collision",  3,  3, 2)
--   map:attach(scene)

local loader  = require("core.loader")
local storage = require("core.storage")

--- A tilemap instance representing a multi-layer tile map. Tilemaps manage tile definitions, layers, and integration with scenes. They can be saved and loaded from storage, but sprite objects must be reloaded and re-attached after loading.
---@class TilemapInstance
---@field tileW number Tile width in pixels
---@field tileH number Tile height in pixels
---@field _defs table<number, table> Tile definitions by ID
---@field _layers table List of layers with name, z, collision, and data
---@field _layerMap table<string, table> Quick lookup of layers by name
---@field _sprites table<string, any> Loaded sprite objects by path
---@field _scene SceneInstance|nil Attached scene reference (set by map:attach)
local tilemap = {}

--- This is the tilemap module for managing multi-layer tile maps in the engine. It provides functions to define tile types, manage layers, read/write tiles, and integrate with scenes. Tilemaps can be saved and loaded from storage, but sprite objects must be reloaded and re-attached after loading.
---@class TilemapModule
local TilemapModule = {}

--- Create a new empty tilemap.
---@param opts  table|nil  { tileW=number, tileH=number } Tile size in pixels (default tileW=2, tileH=1)
---@return TilemapInstance tilemap A new tilemap instance
function TilemapModule.new(opts)
    opts = opts or {}
    local self = {
        tileW = opts.tileW or 2,
        tileH = opts.tileH or 1,
        _defs = {},
        _layers = {},
        _layerMap = {},
        _sprites = {},
        _scene = nil,
    }
    ---@cast self TilemapInstance
    setmetatable(self, { __index = tilemap })
    return self
end

-- ---------------------------------------------------------------------------
-- Tile definitions
-- ---------------------------------------------------------------------------

--- Register a tile type.
---@param id number Positive integer tile ID (0 = empty)
---@param opts {spritePath:string|nil, solid:boolean|nil, type:string|nil, hL:number|nil, hR:number|nil}  Tile properties: spritePath = path to sprite for this tile; solid = whether it blocks movement; type = "slope" or "one-way"; hL/hR = slope heights (0-1) for left/right edges (only for slopes)
function tilemap:defineTile(id, opts)
    assert(type(id) == "number" and id > 0, "tilemap:defineTile id must be a positive number")
    opts = opts or {}
    self._defs[id] = {
        spritePath = opts.spritePath,
        solid = opts.solid or false,
        type = opts.type,
        hL = opts.hL or 0,
        hR = opts.hR or 0,
    }
end

--- Get the definition table for a tile id (read-only).
function tilemap:getTileDef(id)
    return self._defs[id]
end

-- ---------------------------------------------------------------------------
-- Layer management
-- ---------------------------------------------------------------------------

--- Add a new data layer.
---@param name string Unique layer name
---@param opts { z:number|nil, collision:boolean|nil }  Layer properties: z = rendering order (lower renders first); collision = whether this layer is used for collision (first layer with collision=true is used by the engine)
---@return table map The new layer object (with name, z, collision, and data fields)
function tilemap:addLayer(name, opts)
    assert(type(name) == "string", "layer name must be a string")
    assert(not self._layerMap[name], "layer '" .. name .. "' already exists")
    opts = opts or {}
    local layer = {
        name = name,
        z = opts.z or -100,
        collision = opts.collision or false,
        data = {},
    }
    table.insert(self._layers, layer)
    table.sort(self._layers, function(a, b) return a.z < b.z end)
    self._layerMap[name] = layer
    return layer
end

--- Remove a layer by name.
---@param name string Name of the layer to remove
---@return boolean success True if the layer was found and removed, false if no such layer exists
function tilemap:removeLayer(name)
    self._layerMap[name] = nil
    for i = #self._layers, 1, -1 do
        if self._layers[i].name == name then
            table.remove(self._layers, i)
            return true
        end
    end
    return false
end

--- Get the data table for a layer (raw access for bulk operations).
---@param name string Name of the layer
---@return table|nil The layer data table, or nil if the layer doesn't exist
function tilemap:getLayer(name)
    return self._layerMap[name]
end

-- ---------------------------------------------------------------------------
-- Tile read / write
-- ---------------------------------------------------------------------------

--- Set a single tile.
--- @param layerName string
--- @param tx number  1-based column
--- @param ty number  1-based row
--- @param tileId number  0 or nil = clear; positive = place
function tilemap:setTile(layerName, tx, ty, tileId)
    local layer = self._layerMap[layerName]
    assert(layer, "tilemap:setTile: unknown layer '" .. tostring(layerName) .. "'")
    if not layer.data[ty] then layer.data[ty] = {} end
    layer.data[ty][tx] = (tileId and tileId > 0) and tileId or nil
    self:_markDirty()
end

--- Get the tile id at (tx, ty) on a layer.  Returns nil for empty.
---@param layerName string
---@param tx number  1-based column
---@param ty number  1-based row
---@return number|nil tileId The tile ID at the specified location, or nil if empty or out of bounds
function tilemap:getTile(layerName, tx, ty)
    local layer = self._layerMap[layerName]
    if not layer then return nil end
    return layer.data[ty] and layer.data[ty][tx] or nil
end

--- Fill the entire layer (or a rectangular region) with a single tile id.
--- @param layerName string Name of the layer to fill
--- @param tileId number 0 or nil = clear; positive = place
--- @param x1 number|nil 1-based left column of the fill area (optional, defaults to full layer)
--- @param y1 number|nil 1-based top row of the fill area (optional, defaults to full layer)
--- @param x2 number|nil 1-based right column of the fill area (optional, defaults to full layer)
--- @param y2 number|nil 1-based bottom row of the fill area (optional, defaults to full layer)
function tilemap:fill(layerName, tileId, x1, y1, x2, y2)
    local layer = self._layerMap[layerName]
    assert(layer, "tilemap:fill: unknown layer '" .. tostring(layerName) .. "'")
    local val = (tileId and tileId > 0) and tileId or nil
    if not x1 then
        if val then
            error("tilemap:fill: provide x1,y1,x2,y2 when placing tiles (can't fill unbounded)")
        end
        layer.data = {}
    else
        for ty = y1, y2 do
            if not layer.data[ty] then layer.data[ty] = {} end
            for tx = x1, x2 do
                layer.data[ty][tx] = val
            end
        end
    end
    self:_markDirty()
end

--- Copy a rectangular region from one layer/position to another.
---@param srcLayer string Name of the source layer
---@param dstLayer string Name of the destination layer
---@param sx1 number 1-based left column of the source rectangle
---@param sy1 number 1-based top row of the source rectangle
---@param sx2 number 1-based right column of the source rectangle
---@param sy2 number 1-based bottom row of the source rectangle
---@param dx number 1-based left column of the destination rectangle
---@param dy number 1-based top row of the destination rectangle
function tilemap:copyRect(srcLayer, dstLayer, sx1, sy1, sx2, sy2, dx, dy)
    local src = self._layerMap[srcLayer]
    local dst = self._layerMap[dstLayer]
    assert(src, "copyRect: unknown source layer '" .. tostring(srcLayer) .. "'")
    assert(dst, "copyRect: unknown dest layer '"   .. tostring(dstLayer) .. "'")
    for oy = 0, sy2 - sy1 do
        local ty = sy1 + oy
        local dty = dy + oy
        if not dst.data[dty] then dst.data[dty] = {} end
        for ox = 0, sx2 - sx1 do
            local tx = sx1 + ox
            dst.data[dty][dx + ox] = src.data[ty] and src.data[ty][tx] or nil
        end
    end
    self:_markDirty()
end

-- ---------------------------------------------------------------------------
-- Coordinate helpers
-- ---------------------------------------------------------------------------

--- Convert world position to tile coordinates.
---@return number tx, number ty  -- 1-based, may be outside map bounds
function tilemap:worldToTile(wx, wy)
    return math.floor(wx / self.tileW) + 1,
           math.floor(wy / self.tileH) + 1
end

--- Convert tile coordinates to the world position of its top-left corner.
---@return number wx, number wy
function tilemap:tileToWorld(tx, ty)
    return (tx - 1) * self.tileW,
           (ty - 1) * self.tileH
end

--- Iterate all non-empty tiles within a world-space rectangle.
---@param wx1 number Left edge of the rectangle
---@param wy1 number Top edge of the rectangle
---@param wx2 number Right edge of the rectangle
---@param wy2 number Bottom edge of the rectangle
---@param fn fun(layerName:string, tx:number, ty:number, tileId:number) Callback function
function tilemap:forArea(wx1, wy1, wx2, wy2, fn)
    local startX = math.floor(wx1 / self.tileW) + 1
    local startY = math.floor(wy1 / self.tileH) + 1
    local endX   = math.floor(wx2 / self.tileW) + 1
    local endY   = math.floor(wy2 / self.tileH) + 1
    for _, layer in ipairs(self._layers) do
        for ty = startY, endY do
            if layer.data[ty] then
                for tx = startX, endX do
                    local id = layer.data[ty][tx]
                    if id then fn(layer.name, tx, ty, id) end
                end
            end
        end
    end
end

--- Return a table of { name, tx, ty, tileId } for the 4 cardinal neighbors
--- of (tx, ty) on a specific layer.
---@param layerName string Name of the layer to check
---@param tx number 1-based column
---@param ty number 1-based row
---@return table[] neighbors List of neighbor info tables with fields: name (layer name), tx, ty, tileId (nil if empty)
function tilemap:getNeighbors(layerName, tx, ty)
    local layer = self._layerMap[layerName]
    if not layer then return {} end
    local dirs = { {0,-1},{0,1},{-1,0},{1,0} }
    local result = {}
    for _, d in ipairs(dirs) do
        local nx, ny = tx + d[1], ty + d[2]
        local id = layer.data[ny] and layer.data[ny][nx] or nil
        table.insert(result, { tx = nx, ty = ny, tileId = id })
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Scene integration
-- ---------------------------------------------------------------------------

--- Attach this tilemap to a scene.  Preloads sprites and writes the scene's
--- `tilemap` field in the format the engine renderer and collision system expect.
--- @param scene SceneInstance The scene to attach to. The tilemap will write to scene.tilemap and mark scene._staticDirty when modified.
function tilemap:attach(scene)
    self._scene = scene

    for _, def in pairs(self._defs) do
        if def.spritePath and not self._sprites[def.spritePath] then
            local spr = loader.loadSprite(def.spritePath)
            if spr then
                self._sprites[def.spritePath] = spr
            end
        end
    end

    self:_buildSceneTilemap(scene)
end

--- Detach from the scene (clears scene.tilemap).
function tilemap:detach()
    if self._scene then
        self._scene.tilemap = nil
        self._scene._staticDirty = true
        self._scene = nil
    end
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

--- Save the tilemap's layer data (definitions and tile arrays) to storage.
--- Sprites are NOT saved — re-define them with defineTile() on load.
--- @param name string Storage key (passed to storage.save)
function tilemap:save(name)
    local payload = {
        tileW  = self.tileW,
        tileH  = self.tileH,
        defs   = {},
        layers = {},
    }
    for id, def in pairs(self._defs) do
        payload.defs[id] = {
            spritePath = def.spritePath,
            solid      = def.solid,
            type       = def.type,
            hL         = def.hL,
            hR         = def.hR,
        }
    end
    for _, layer in ipairs(self._layers) do
        table.insert(payload.layers, {
            name      = layer.name,
            z         = layer.z,
            collision = layer.collision,
            data      = layer.data,
        })
    end
    storage.save(name, payload)
end

--- Load layer data from storage. Does NOT re-attach to a scene;
--- call map:attach(scene) afterwards.
---@param name string Same key used in map:save()
---@return TilemapInstance|nil, string|nil The tilemap instance (self) if successful, or nil and an error message if loading failed
function tilemap:load(name)
    local payload = storage.load(name)
    if not payload then return nil, "tilemap: no saved data for key '" .. name .. "'" end

    self.tileW = payload.tileW or self.tileW
    self.tileH = payload.tileH or self.tileH

    for id, def in pairs(payload.defs or {}) do
        self._defs[tonumber(id)] = def
    end

    self._layers   = {}
    self._layerMap = {}
    for _, saved in ipairs(payload.layers or {}) do
        local layer = {
            name      = saved.name,
            z         = saved.z,
            collision = saved.collision,
            data      = saved.data or {},
        }
        table.insert(self._layers, layer)
        self._layerMap[saved.name] = layer
    end
    table.sort(self._layers, function(a, b) return a.z < b.z end)
    return self
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Internal function to mark the tilemap as dirty and trigger a scene update. Should be called after any modification to tile data or definitions.
function tilemap:_markDirty()
    if self._scene then
        self:_buildSceneTilemap(self._scene)
        self._scene._staticDirty = true
    end
end

--- Build the canonical scene.tilemap table from current state.
--- The renderer iterates `tm.layers` (ordered by z); the collision system
--- uses `tm.data` / `tm.solidTiles` / `tm.tileProperties` (mapped from the
--- first layer flagged collision=true, preserving backward compatibility).
---@param scene SceneInstance The scene to which the tilemap is attached
function tilemap:_buildSceneTilemap(scene)
    local spriteTable = {}
    local solidTiles = {}
    local tileProperties = {}

    for id, def in pairs(self._defs) do
        if def.spritePath then
            local spr = self._sprites[def.spritePath]
            if spr then
                spriteTable[id] = spr
            end
        end
        if def.solid then
            solidTiles[id] = true
        end
        if def.type then
            tileProperties[id] = {
                type = def.type,
                hL = def.hL or 0,
                hR = def.hR or 0,
            }
        end
    end

    local collisionData = {}
    for _, layer in ipairs(self._layers) do
        if layer.collision then
            collisionData = layer.data
            break
        end
    end

    scene.tilemap = {
        layers = self._layers,
        data = collisionData,
        sprite = spriteTable,
        solidTiles = solidTiles,
        tileProperties = tileProperties,
        tileW = self.tileW,
        tileH = self.tileH,
        _map = self,
    }
end

return TilemapModule