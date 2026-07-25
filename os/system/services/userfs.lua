-- /services/userfs.lua
-- User filesystem service: Manages user-specific directories and files

local api_factory = require("core.api")
local event = require("core.event")
local config = require("core.config")

local api = api_factory.new()

local current_user_dir = nil
local BASE_USER_DIR = "users"

-- Default user directory structure
local USER_DIRS = {
    "desktop",
    "documents",
    "programs",
    "apps",
    "cache",
    "config"
}

local function validUsername(username)
    return type(username) == "string"
        and username:match("^[a-z0-9][a-z0-9_-]*$") ~= nil
end

local function validSubpath(subpath)
    if type(subpath) ~= "string" or subpath == "" then return true end
    if subpath:sub(1, 1) == "/" or subpath:sub(1, 1) == "\\" then return false end
    for part in subpath:gmatch("[^/\\]+") do
        if part == ".." then return false end
    end
    return true
end

-- Initialize user directory structure
local function initUserDirectory(username)
    if not validUsername(username) then return nil, "Invalid username" end
    local user_path = fs.combine(BASE_USER_DIR, username)
    
    -- Create base user directory
    if not fs.exists(user_path) then
        fs.makeDir(user_path)
    end
    
    -- Create subdirectories
    for _, dir in ipairs(USER_DIRS) do
        local dir_path = fs.combine(user_path, dir)
        if not fs.exists(dir_path) then
            fs.makeDir(dir_path)
        end
    end
    
    return user_path
end

-- Service initialization
function api.public.init()
    -- Create base users directory
    if not fs.exists(BASE_USER_DIR) then
        fs.makeDir(BASE_USER_DIR)
    end
    
    -- Listen to login event
    event.on("user.login", function(username)
        local user_path = initUserDirectory(username)
        if user_path then
            current_user_dir = user_path
            event.dispatch("userfs.ready", username)
        end
    end)
    
    -- Listen to logout event
    event.on("user.logout", function()
        current_user_dir = nil
    end)
end

-- Creates/repairs a user's standard home structure without logging them in.
function api.public.initializeUser(username)
    local user_path, err = initUserDirectory(username)
    if not user_path then return false, err end
    return true, user_path
end

-- Public API: Get user-specific path
-- @param subpath: Optional subpath (e.g., "documents", "apps/myapp")
-- @return: Full path or nil if no user logged in
function api.public.getPath(subpath)
    if not current_user_dir then
        return nil, "No user logged in"
    end
    
    if subpath and not validSubpath(subpath) then
        return nil, "Invalid user path"
    end
    if subpath and subpath ~= "" then
        return fs.combine(current_user_dir, subpath)
    end
    
    return current_user_dir
end

-- Public API: Get current user's directory
function api.public.getUserDir()
    return current_user_dir
end

-- Public API: Create directory in user space
function api.public.createDir(subpath)
    if not current_user_dir then
        return false, "No user logged in"
    end
    
    if not validSubpath(subpath) then return false, "Invalid user path" end
    local full_path = fs.combine(current_user_dir, subpath)
    
    if fs.exists(full_path) then
        return false, "Path already exists"
    end
    
    fs.makeDir(full_path)
    return true
end

-- Public API: Check if path exists in user space
function api.public.exists(subpath)
    if not current_user_dir then
        return false
    end
    
    if not validSubpath(subpath) then return false end
    local full_path = fs.combine(current_user_dir, subpath)
    return fs.exists(full_path)
end

return api
