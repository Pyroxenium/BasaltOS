-- Obsidian Engine: Asset Loader
-- Handles loading and caching of sprites, UI, and emitters.

---@diagnostic disable: undefined-global

local logger = require("core.logger")
local flimg = require("flimg")

---@alias SpriteLayer table<number, table|string> Each layer contains legacy string rows or per-cell value tables. Color layers may contain RGB handles/#RRGGBB values.
---@alias SpriteFrame table<number, SpriteLayer> [1]=Chars, [2]=Fore, [3]=Back

--- Represents a multi-frame sprite with character, foreground, and background layers.
---@class Sprite
---@field width number The width of the sprite
---@field height number The height of the sprite
---@field frameCount number The number of frames in the sprite
---@field path string The original file path of the sprite (for reference)
---@field [number] SpriteFrame Frames indexed from 1 to frameCount

--- Represents UI layout data loaded from .oui files.
---@class UIData
---@field elements table<string, table> A table of UI elements, where each key is an element name and the value is a table of properties.

--- Represents particle emitter configuration loaded from .pe files.
---@class EmitterData
---@field sprite Sprite|nil The sprite associated with the emitter, if any
---@field [string] any Additional emitter properties

--- Loader module definition
---@class LoaderModule
---@field basePath string|nil Optional base path for resolving asset files
---@field spriteCache table<string, Sprite> Cache of loaded sprites, keyed by full file path
---@field uiCache table<string, UIData> Cache of loaded UI data, keyed by full file path
---@field emitterCache table<string, EmitterData> Cache of loaded emitter data, keyed by full file path
local loader = {
    basePath = nil,
    spriteCache = {},
    imageCache = {},
    uiCache = {},
    emitterCache = {}
}

loader.flimg = flimg

local function resolvePath(path)
    if not path or path:sub(1,1) == "/" then return path end

    if loader.basePath then
        return fs.combine(loader.basePath, path)
    end

    if shell then
        local runningProg = shell.getRunningProgram()
        if runningProg then
            return fs.combine(fs.getDir(runningProg), path)
        end
    end

    return path
end

--- Set a base path for asset loading. Relative paths will be resolved against this base path.
---@param path string|nil The base path to set, or nil to disable
function loader.setBasePath(path)
    loader.basePath = path
end

local function toTable(str)
    local t = {}
    for i = 1, #str do t[i] = str:sub(i, i) end
    return t
end

local function _loadFile(path)
    local fullPath = resolvePath(path)
    if not fs.exists(fullPath) then
        return false, "File not found: " .. fullPath
    end
    local file = fs.open(fullPath, "r")
    if not file then
        return false, "Could not open file: " .. fullPath
    end
    local raw = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserialize, raw)
    if not ok or data == nil then
        return false, "Failed to unserialize: " .. fullPath
    end
    return true, data, fullPath
end

--- Convert string rows into character tables for faster pixel access.
---@param data Sprite The sprite data to process
function loader._processSprite(data)
    if not data then return end
    for i = 1, (data.frameCount or #data) do
        local frame = data[i]
        if frame then
            for layer = 1, 3 do
                if frame[layer] then
                    for rowIdx, row in ipairs(frame[layer]) do
                        if type(row) == "string" then
                            frame[layer][rowIdx] = toTable(row)
                        end
                    end
                end
            end
        end
    end
end

--- Validate that the loaded sprite data has the correct structure and dimensions.
---@param path string The file path of the sprite (for error messages)
---@param data any The loaded data to validate
---@return boolean ok, string? error Returns true if valid, or false and an error message if invalid
function loader._validateSprite(path, data)
    if not data or type(data) ~= "table" then
        return false, "File is not a valid table."
    end

    local req = {"width", "height", "frameCount"}
    for _, field in ipairs(req) do
        if not data[field] then return false, "Missing field: " .. field end
    end

    for f = 1, data.frameCount do
        local frame = data[f]
        if not frame or #frame ~= 3 then
            return false, string.format("Frame %d must have exactly 3 layers (Chars, Fore, Back).", f)
        end

        for layer = 1, 3 do
            if #frame[layer] ~= data.height then
                return false, string.format("Frame %d, layer %d: row count (%d) does not match height (%d).", f, layer, #frame[layer], data.height)
            end

            for r = 1, data.height do
                local row = frame[layer][r]
                local len = #row
                if len ~= data.width then
                    return false, string.format("Frame %d, layer %d, row %d: length (%d) does not match width (%d).", f, layer, r, len, data.width)
                end

                if type(row) == "table" then
                    for c = 1, data.width do
                        local cell = row[c]
                        local validCell
                        if layer == 1 then
                            validCell = type(cell) == "string" and #cell == 1
                        else
                            validCell = type(cell) == "number"
                                or (type(cell) == "string" and (
                                    #cell == 1
                                    or cell:match("^#%x%x%x$")
                                    or cell:match("^#%x%x%x%x%x%x$")
                                    or cell:match("^#%x%x%x%x%x%x%x%x$")
                                ))
                        end
                        if not validCell then
                            local content = tostring(cell)
                            return false, string.format(
                                "Frame %d, layer %d, row %d, column %d: invalid %s value '%s'.",
                                f, layer, r, c, layer == 1 and "character" or "color", content)
                        end
                    end
                end
            end
        end
    end
    return true
end

--- Load a sprite (.obs file) from disk or cache.
---@param path string The file path of the sprite to load
---@return Sprite|nil sprite The loaded sprite data, or nil if loading failed
function loader.loadSprite(path)
    local fullPath = resolvePath(path)
    if loader.spriteCache[fullPath] then
        return loader.spriteCache[fullPath]
    end

    local ok, data, fp = _loadFile(path)
    if not ok then
        logger.error("Loader: " .. data)
        return nil, data
    end

    local valid, verr = loader._validateSprite(path, data)
    if not valid then
        logger.error("Loader: Validation error in " .. path .. ": " .. verr)
        return nil, verr
    end

    loader._processSprite(data)
    data.path = path
    loader.spriteCache[fp] = data
    logger.info("Loader: Cached sprite: " .. fp)
    return data
end

--- Loads a binary FLIMG image. Pixel images retain their virtual 2x3 data;
-- draw them with buffer:drawImage(image, x, y, frame).
---@param path string
---@return table|nil image
---@return string? error
function loader.loadImage(path)
    local fullPath = resolvePath(path)
    if loader.imageCache[fullPath] then return loader.imageCache[fullPath] end
    if not fs.exists(fullPath) then return nil, "File not found: " .. fullPath end
    local handle = fs.open(fullPath, "rb") or fs.open(fullPath, "r")
    if not handle then return nil, "Could not open file: " .. fullPath end
    local raw = handle.readAll()
    handle.close()
    local ok, image = pcall(flimg.decode, raw)
    if not ok then
        logger.error("Loader: " .. tostring(image))
        return nil, tostring(image)
    end
    image.path = path
    loader.imageCache[fullPath] = image
    logger.info("Loader: Cached FLIMG image: " .. fullPath)
    return image
end

--- Load UI data (.oui file) from disk or cache.
---@param path string The file path of the UI data to load
---@return UIData|nil oui The loaded UI data, or nil if loading failed
---@return string? err An error message if loading failed
function loader.loadUI(path)
    local fullPath = resolvePath(path)
    if loader.uiCache[fullPath] then
        return loader.uiCache[fullPath]
    end

    local ok, data, fp = _loadFile(path)
    if not ok then
        logger.error("Loader: " .. data)
        return nil, data
    end

    loader.uiCache[fp] = data
    return data
end

--- Load emitter configuration (.pe file) from disk or cache.
---@param path string The file path of the emitter data to load
---@return EmitterData|nil pe The loaded emitter data, or nil if loading failed
function loader.loadEmitter(path)
    local fullPath = resolvePath(path)
    if loader.emitterCache[fullPath] then
        return loader.emitterCache[fullPath]
    end

    local ok, data, fp = _loadFile(path)
    if not ok then
        logger.error("Loader: " .. data)
        return nil, data
    end

    if data.sprite then loader._processSprite(data.sprite) end
    loader.emitterCache[fp] = data
    return data
end

--- Remove an asset from all caches.
---@param path string The file path of the asset to unload
function loader.unload(path)
    local fullPath = resolvePath(path)
    loader.spriteCache[fullPath] = nil
    loader.imageCache[fullPath] = nil
    loader.uiCache[fullPath] = nil
    loader.emitterCache[fullPath] = nil
    logger.info("Loader: Unloaded asset: " .. tostring(fullPath))
end

--- Clear all cached assets.
function loader.clearCache()
    loader.spriteCache = {}
    loader.imageCache = {}
    loader.uiCache = {}
    loader.emitterCache = {}
    logger.info("Loader: Asset cache cleared.")
end

return loader
