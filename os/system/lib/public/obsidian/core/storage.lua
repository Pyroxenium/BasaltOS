--- Obsidian storage module
--- Provides functions to save and load Lua tables to disk, useful for saving game state, player progress, or configuration data.

---@diagnostic disable: undefined-global

---@class StorageModule
local storage = {}

local SAVE_DIR = "saves/"

--- Override the default save directory (must end with "/").
---@param path string New save directory path
function storage.setDir(path)
    SAVE_DIR = path
end

--- Save a value to disk under `saves/<name>.dat`.
---@param name string Name of the save (without extension)
---@param data table Lua table to save (must be serializable by textutils.serialize)
---@return boolean, string|nil success if save was successful, false and error message if failed
---@return string? error Error message if save failed, nil if successful
function storage.save(name, data)
    if not fs.exists(SAVE_DIR) then
        fs.makeDir(SAVE_DIR)
    end

    local path = fs.combine(SAVE_DIR, name .. ".dat")
    local file = fs.open(path, "w")
    if not file then return false, "Could not open file for writing: " .. path end
    local ok, err = pcall(function()
        file.write(textutils.serialize(data))
    end)
    file.close()
    return ok, err
end

--- Load a value from disk at `saves/<name>.dat`.
---@param name string Name of the save to load (without extension)
---@return table|nil, string|nil data if load was successful, nil and error message
function storage.load(name)
    local path = fs.combine(SAVE_DIR, name .. ".dat")
    if not fs.exists(path) then return nil, "Save file does not exist: " .. path end

    local file = fs.open(path, "r")
    if not file then return nil, "Could not open file for reading: " .. path end
    local raw = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserialize, raw)
    if not ok then return nil, "Failed to deserialize save data: " .. tostring(data) end
    return data, nil
end

--- Delete a save file at `saves/<name>.dat`.
---@param name string Name of the save to delete (without extension)
---@return boolean success True if the file was deleted, false if it did not exist
function storage.delete(name)
    local path = fs.combine(SAVE_DIR, name .. ".dat")
    if fs.exists(path) then
        fs.delete(path)
        return true
    end
    return false
end

--- Returns a list of save names (without the .dat extension) in SAVE_DIR.
---@return string[] list List of save names
function storage.list()
    if not fs.exists(SAVE_DIR) then return {} end
    local names = {}
    for _, file in ipairs(fs.list(SAVE_DIR)) do
        if file:sub(-4) == ".dat" then
            names[#names + 1] = file:sub(1, -5)
        end
    end
    return names
end

return storage