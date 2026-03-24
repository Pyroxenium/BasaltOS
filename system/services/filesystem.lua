-- FileSystem Service
-- Central file management service for BasaltOS

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")

local api = api_factory.new()

-- File type registry: extension -> app_id
local file_type_registry = {}
-- Recent files list (newest first)
local recent_files = {}
local max_recent_files = 20

function api.public.init()
    api.private.registerDefaultTypes()
    log.info("FILESYSTEM", "Service initialized")
end

-- Load file type associations from system config
function api.private.registerDefaultTypes()
    local config = require("core.config")
    local associations = config.get("filetypes.associations", {})
    for ext, app_id in pairs(associations) do
        api.public.registerFileType(ext, app_id)
    end
end

-- Open a file with its associated application.
-- Falls back to the configured default_app (default: "edit") when no association exists.
-- @param path string  Full path to the file
-- @return boolean success, string|nil error
function api.public.openFile(path)
    if not fs.exists(path) then
        return false, "File not found: " .. path
    end

    local app_id = api.public.getAppForFile(path)
    if not app_id then
        local config = require("core.config")
        app_id = config.get("filetypes.default_app", "edit")
    end

    local process_service = service.getService("process")
    if not process_service then
        return false, "Process service not available"
    end

    api.public.addRecentFile(path)
    process_service.startProgram(app_id, {path})
    return true
end

-- Register a file type association
-- @param extension string File extension (without dot)
-- @param app_id string|nil App ID to open this file type (nil = no association)
-- @param icon string|nil Optional icon character
function api.public.registerFileType(extension, app_id, icon)
    file_type_registry[extension] = {
        app_id = app_id,
        icon = icon
    }
    log.debug("FILESYSTEM", "Registered file type: " .. extension .. " -> " .. tostring(app_id))
end

-- Get the app associated with a file type
-- Reads live from config so changes to config.dat take effect without restart.
-- @param filename string Full filename or just extension
-- @return string|nil app_id The app ID, or nil if no association
-- @return string|nil icon The icon character, or nil
function api.public.getAppForFile(filename)
    local extension = filename:match("%.([^%.]+)$")

    -- Check static registry first (set via registerFileType API calls from other services)
    local reg_entry = extension and file_type_registry[extension]
    if reg_entry and reg_entry.app_id then
        return reg_entry.app_id, reg_entry.icon
    end

    -- Fall back to live config lookup
    local config = require("core.config")
    if extension then
        local app_id = config.get("filetypes.associations." .. extension)
        if app_id then return app_id, nil end
    end

    return nil, nil
end

-- Get all registered file types
-- @return table List of {extension, app_id, icon}
function api.public.getFileTypes()
    local types = {}
    for ext, entry in pairs(file_type_registry) do
        table.insert(types, {
            extension = ext,
            app_id = entry.app_id,
            icon = entry.icon
        })
    end
    table.sort(types, function(a, b) return a.extension < b.extension end)
    return types
end

-- Add a file to recent files list
-- @param path string Absolute path to the file
function api.public.addRecentFile(path)
    if not path or path == "" then
        return
    end
    
    -- Remove if already in list
    for i = #recent_files, 1, -1 do
        if recent_files[i].path == path then
            table.remove(recent_files, i)
        end
    end
    
    -- Add to front
    table.insert(recent_files, 1, {
        path = path,
        timestamp = os.epoch("utc")
    })
    
    -- Limit list size
    while #recent_files > max_recent_files do
        table.remove(recent_files)
    end
    
    event.dispatch("filesystem.recent_file_added", path)
end

-- Get recent files list
-- @param limit number|nil Maximum number of files to return (default: all)
-- @return table List of {path, timestamp}
function api.public.getRecentFiles(limit)
    limit = limit or #recent_files
    local result = {}
    for i = 1, math.min(limit, #recent_files) do
        table.insert(result, recent_files[i])
    end
    return result
end

-- Clear recent files list
function api.public.clearRecentFiles()
    recent_files = {}
    event.dispatch("filesystem.recent_files_cleared")
end

-- Remove a file from recent files list
-- @param path string Absolute path to remove
function api.public.removeRecentFile(path)
    for i = #recent_files, 1, -1 do
        if recent_files[i].path == path then
            table.remove(recent_files, i)
            event.dispatch("filesystem.recent_file_removed", path)
            return true
        end
    end
    return false
end

-- Wrapper functions for fs API with event dispatch
-- These allow other services/apps to listen for file changes

-- Copy a file or directory
-- @param source string Source path
-- @param destination string Destination path
-- @return boolean success
function api.public.copy(source, destination)
    if not fs.exists(source) then
        return false
    end
    
    fs.copy(source, destination)
    event.dispatch("filesystem.file_copied", source, destination)
    return true
end

-- Move a file or directory
-- @param source string Source path
-- @param destination string Destination path
-- @return boolean success
function api.public.move(source, destination)
    if not fs.exists(source) then
        return false
    end
    
    fs.move(source, destination)
    event.dispatch("filesystem.file_moved", source, destination)
    return true
end

-- Delete a file or directory
-- @param path string Path to delete
-- @return boolean success
function api.public.delete(path)
    if not fs.exists(path) then
        return false
    end
    
    fs.delete(path)
    event.dispatch("filesystem.file_deleted", path)
    return true
end

-- Create a directory
-- @param path string Directory path
-- @return boolean success
function api.public.makeDir(path)
    if fs.exists(path) then
        return false
    end
    
    fs.makeDir(path)
    event.dispatch("filesystem.directory_created", path)
    return true
end

-- Get file info
-- @param path string File path
-- @return table|nil {name, path, size, isDir, extension, modified}
function api.public.getFileInfo(path)
    if not fs.exists(path) then
        return nil
    end
    
    local name = fs.getName(path)
    local extension = name:match("%.([^%.]+)$")
    local is_dir = fs.isDir(path)
    local size = is_dir and 0 or fs.getSize(path)
    
    -- Get associated app and icon
    local app_id, icon = nil, nil
    if not is_dir and extension then
        app_id, icon = api.public.getAppForFile(name)
    end
    
    return {
        name = name,
        path = path,
        size = size,
        isDir = is_dir,
        extension = extension,
        app_id = app_id,
        icon = icon
    }
end

-- List directory contents with file info
-- @param path string Directory path
-- @return table|nil List of file info tables
function api.public.listDir(path)
    if not fs.exists(path) or not fs.isDir(path) then
        return nil
    end

    local items = fs.list(path)
    local result = {}

    for _, item in ipairs(items) do
        local item_path = fs.combine(path, item)
        local info = api.public.getFileInfo(item_path)
        if info then
            table.insert(result, info)
        end
    end

    table.sort(result, function(a, b)
        if a.isDir ~= b.isDir then
            return a.isDir
        end
        return a.name < b.name
    end)

    return result
end

return api
