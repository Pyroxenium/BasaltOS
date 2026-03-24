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
    "apps",
    "config"
}

-- Initialize user directory structure
local function initUserDirectory(username)
    local user_path = fs.combine(BASE_USER_DIR, username)
    
    -- Create base user directory
    if not fs.exists(user_path) then
        fs.makeDir(user_path)
        print("  [USERFS] Created user directory: " .. username)
    end
    
    -- Create subdirectories
    for _, dir in ipairs(USER_DIRS) do
        local dir_path = fs.combine(user_path, dir)
        if not fs.exists(dir_path) then
            fs.makeDir(dir_path)
        end
    end
    
    -- Create default files
    local installed_apps_file = fs.combine(user_path, "apps/installed.dat")
    if not fs.exists(installed_apps_file) then
        local file = fs.open(installed_apps_file, "w")
        file.write(textutils.serialize({}))
        file.close()
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
        current_user_dir = initUserDirectory(username)
        event.dispatch("userfs.ready", username)
    end)
    
    -- Listen to logout event
    event.on("user.logout", function()
        current_user_dir = nil
    end)
end

-- Public API: Get user-specific path
-- @param subpath: Optional subpath (e.g., "documents", "apps/myapp")
-- @return: Full path or nil if no user logged in
function api.public.getPath(subpath)
    if not current_user_dir then
        return nil, "No user logged in"
    end
    
    if subpath then
        return fs.combine(current_user_dir, subpath)
    end
    
    return current_user_dir
end

-- Public API: Get current user's directory
function api.public.getUserDir()
    return current_user_dir
end

-- Public API: List installed apps
function api.public.getInstalledApps()
    if not current_user_dir then
        return {}
    end
    
    local apps_file = fs.combine(current_user_dir, "apps/installed.dat")
    if not fs.exists(apps_file) then
        return {}
    end
    
    local file = fs.open(apps_file, "r")
    local content = file.readAll()
    file.close()
    
    local ok, apps = pcall(textutils.unserialize, content)
    if ok and type(apps) == "table" then
        return apps
    end
    
    return {}
end

-- Public API: Register installed app
function api.public.installApp(app_id, app_data)
    if not current_user_dir then
        return false, "No user logged in"
    end
    
    local apps = api.public.getInstalledApps()
    
    apps[app_id] = {
        id = app_id,
        name = app_data.name or app_id,
        version = app_data.version or "1.0",
        path = app_data.path,
        installed_at = os.epoch("utc")
    }
    
    local apps_file = fs.combine(current_user_dir, "apps/installed.dat")
    local file = fs.open(apps_file, "w")
    file.write(textutils.serialize(apps))
    file.close()
    
    event.dispatch("app.installed", app_id)
    
    return true
end

-- Public API: Uninstall app
function api.public.uninstallApp(app_id)
    if not current_user_dir then
        return false, "No user logged in"
    end
    
    local apps = api.public.getInstalledApps()
    
    if not apps[app_id] then
        return false, "App not found"
    end
    
    apps[app_id] = nil
    
    local apps_file = fs.combine(current_user_dir, "apps/installed.dat")
    local file = fs.open(apps_file, "w")
    file.write(textutils.serialize(apps))
    file.close()
    
    event.dispatch("app.uninstalled", app_id)
    
    return true
end

-- Public API: Create directory in user space
function api.public.createDir(subpath)
    if not current_user_dir then
        return false, "No user logged in"
    end
    
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
    
    local full_path = fs.combine(current_user_dir, subpath)
    return fs.exists(full_path)
end

return api
