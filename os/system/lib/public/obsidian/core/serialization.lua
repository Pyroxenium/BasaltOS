--- Obsidian Serialization module
--- Provides functions to serialize and deserialize scene data to/from Lua tables and disk files.
--- Useful for saving/loading game state, scene templates, or level data.
--- 
---@diagnostic disable: undefined-global

local logger = require("core.logger")
local loader = require("core.loader")
local mathUtils = require("core.math")

---@class SerializationModule
local Serialization = {}

--- Serialize a scene into a plain Lua table (no I/O).
---@param scene SceneInstance The scene to serialize
---@return table serializedScene Serialized scene data
function Serialization.pack(scene)
    local data = {
        name = scene.name or "Unnamed Scene",
        camera = { x = scene.camera.x, y = scene.camera.y },
        tilemap = nil,
        statics = {},
        entities = {}
    }

    if scene.tilemap then
        data.tilemap = {
            spritePath = scene.tilemap.spritePath,
            data = scene.tilemap.data,
            solidTiles = scene.tilemap.solidTiles,
            tileProperties = scene.tilemap.tileProperties
        }
    end

    for _, item in ipairs(scene._staticElements) do
        table.insert(data.statics, {
            spritePath = item.spritePath,
            x = item.x,
            y = item.y,
            z = item.z,
            collider = item.collider,
            layer = item.layer
        })
    end

    for id, _ in pairs(scene._entities) do
        local entData = { id = id, components = {} }
        local signature = scene._tags[id]

        for compName, _ in pairs(signature) do
            local comp = scene._store[compName][id]
            if compName == "sprite" then
                entData.components[compName] = { spritePath = comp.path }
            elseif mathUtils.isVec2(comp) then
                entData.components[compName] = { __type = "vec2", x = comp.x, y = comp.y }
            elseif type(comp) == "table" then
                local copy = {}
                for k, v in pairs(comp) do if type(v) ~= "function" then copy[k] = v end end
                entData.components[compName] = copy
            else
                entData.components[compName] = comp
            end
        end
        table.insert(data.entities, entData)
    end

    return data
end

--- Save a serialized scene to disk at `path`.
---@param scene SceneInstance The scene to serialize and save
---@param path string File path to save the serialized scene (e.g. "scenes/level1.obs")
---@return boolean success True if save succeeded, false on error
function Serialization.save(scene, path)
    local data = Serialization.pack(scene)
    local file = fs.open(path, "w")
    if not file then
        logger.error("Serialization: Could not open file for writing: " .. tostring(path))
        return false
    end
    local ok, err = pcall(function() file.write(textutils.serialize(data)) end)
    file.close()
    if not ok then
        logger.error("Serialization: Failed to serialize scene: " .. tostring(err))
        return false
    end
    logger.info("Scene serialized to " .. path)
    return true
end

--- Apply serialized scene data into a live scene instance.
---@param scene table SceneInstance The scene to which the data will be applied
---@param data table Serialized scene data (as produced by `Serialization.pack`)
function Serialization.apply(scene, data)
    local toDestroy = {}
    for id in pairs(scene._entities) do
        toDestroy[#toDestroy + 1] = id
    end
    for _, id in ipairs(toDestroy) do
        scene:despawn(id)
    end

    scene._staticElements = {}
    scene._foregroundElements = {}
    scene.tilemap = nil
    scene._spatialGrid = {}
    scene._activeDynamicCells = {}
    scene._staticDirty = true

    scene.name = data.name
    scene.camera:set(data.camera.x, data.camera.y)

    if data.tilemap and data.tilemap.spritePath then
        local sprite = loader.load(data.tilemap.spritePath)
        scene:setTilemap(sprite, data.tilemap.data, data.tilemap.solidTiles, data.tilemap.tileProperties)
        scene.tilemap.spritePath = data.tilemap.spritePath
    end

    for _, s in ipairs(data.statics) do
        local sprite = s.spritePath and loader.load(s.spritePath) or nil
        scene:addStatic(sprite, s.x, s.y, {
            z        = s.z,
            collider = s.collider,
            layer    = s.layer,
        })
        scene._staticElements[#scene._staticElements].spritePath = s.spritePath
    end

    local idMap = {}
    for _, entData in ipairs(data.entities) do
        local newId = scene:spawn()
        idMap[entData.id] = newId
    end

    for _, entData in ipairs(data.entities) do
        local id = idMap[entData.id]
        for compName, compData in pairs(entData.components) do
            if compName == "sprite" then
                local s = loader.load(compData.spritePath)
                scene:attach(id, "sprite", s)
            elseif type(compData) == "table" and compData.__type == "vec2" then
                scene:attach(id, compName, mathUtils.vec2(compData.x, compData.y))
            elseif compName == "pos" then
                scene:attach(id, "pos", mathUtils.vec2(compData.x or 0, compData.y or 0))
            elseif compName == "parent" and type(compData) == "table" and compData.id then
                local remapped = { id = idMap[compData.id] or compData.id }
                if compData.offset then
                    remapped.offset = mathUtils.vec2(compData.offset.x or 0, compData.offset.y or 0)
                end
                scene:attach(id, "parent", remapped)
            else
                scene:attach(id, compName, compData)
            end
        end
    end
end

return Serialization