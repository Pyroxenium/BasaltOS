-- /services/registry.lua
-- Program Registry: Manages installed programs and their metadata

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local path = require("core.path")

local api = api_factory.new()

local APPS_DIR = "apps"
local SYSTEM_APPS_DIR = "system/apps"
local programs = {}

-- Program metadata structure
--[[
{
    id = "unique_program_id",        -- REQUIRED: unique identifier
    name = "Display Name",
    version = "1.0.0",
    executable = "/path/to/program.lua",
    icon = "/path/to/icon.nfp",      -- optional
    window = {
        fullscreen = false,
        resizable = true,
        default_width = 30,
        default_height = 15,
        min_width = 10,
        min_height = 5
    },
    category = "games" | "utilities" | "system" | "other",
    author = "Author Name",          -- optional
    description = "Program description"  -- optional
}
]]

function api.public.init()
    if not fs.exists(APPS_DIR) then
        fs.makeDir(APPS_DIR)
    end

    if not fs.exists(SYSTEM_APPS_DIR) then
        fs.makeDir(SYSTEM_APPS_DIR)
    end

    api.private.loadAllPrograms()
end

function api.private.loadAllPrograms()
    programs = {}

    -- Scan system/apps/ (system apps with app.json)
    api.private.scanAppDirectory(SYSTEM_APPS_DIR, true)

    -- Load user-installed apps from users/USERNAME/apps/*.json
    local config = require("core.config")
    local current_user = config.getCurrentUser()
    
    if current_user then
        api.private.loadUserInstalledApps(current_user)
    end

    print("  [REGISTRY] Loaded " .. #api.public.listPrograms() .. " programs")
end

-- Private: Load user-installed apps from users/USERNAME/apps/*.json
function api.private.loadUserInstalledApps(username)
    local user_apps_dir = fs.combine("users", username, "apps")
    
    if not fs.exists(user_apps_dir) or not fs.isDir(user_apps_dir) then
        return
    end
    
    local files = fs.list(user_apps_dir)
    
    for _, filename in ipairs(files) do
        if filename:match("%.json$") then
            local json_path = fs.combine(user_apps_dir, filename)
            local app_data = api.private.loadAppJson(json_path)
            
            if app_data and app_data.id then
                -- Handle executable path
                if app_data.executable then
                    local app_folder = fs.combine(APPS_DIR, app_data.id)
                    path.setCurrentProgramPath(app_folder)
                    app_data.executable = path.resolve(app_data.executable, app_folder)
                    path.setCurrentProgramPath(nil)
                end
                
                -- Handle icon path
                if app_data.icon then
                    local app_folder = fs.combine(APPS_DIR, app_data.id)
                    path.setCurrentProgramPath(app_folder)
                    app_data.icon = path.resolve(app_data.icon, app_folder)
                    path.setCurrentProgramPath(nil)
                end
                
                app_data.user_installed = true
                app_data.app_path = fs.combine(APPS_DIR, app_data.id)
                
                -- Only register if not already registered (system apps have priority)
                if not programs[app_data.id] then
                    programs[app_data.id] = app_data
                end
            end
        end
    end
end

function api.private.scanAppDirectory(directory, is_system)
    if not fs.exists(directory) or not fs.isDir(directory) then
        return
    end
    
    local folders = fs.list(directory)
    
    for _, folder_name in ipairs(folders) do
        local app_path = fs.combine(directory, folder_name)

        if fs.isDir(app_path) then
            local app_json_path = fs.combine(app_path, "app.json")

            if fs.exists(app_json_path) then
                local app_data = api.private.loadAppJson(app_json_path)

                if app_data then
                    app_data.id = app_data.id or folder_name

                    -- Resolve executable path using path service
                    if app_data.executable then
                        -- Set context for %%PROGRAMPATH%%
                        path.setCurrentProgramPath(app_path)
                        app_data.executable = path.resolve(app_data.executable, app_path)
                        path.setCurrentProgramPath(nil)
                    end

                    -- Resolve icon path
                    if app_data.icon then
                        path.setCurrentProgramPath(app_path)
                        app_data.icon = path.resolve(app_data.icon, app_path)
                        path.setCurrentProgramPath(nil)
                    end

                    app_data.system = is_system
                    app_data.app_path = app_path

                    programs[app_data.id] = app_data
                end
            end
        end
    end
end

-- Private: Load app.json from a path
function api.private.loadAppJson(filepath)
    if not fs.exists(filepath) then
        return nil
    end
    
    local file = fs.open(filepath, "r")
    if not file then
        return nil
    end
    
    local content = file.readAll()
    file.close()
    
    local ok, data = pcall(textutils.unserializeJSON, content)
    if ok and type(data) == "table" then
        data.version = data.version or "1.0.0"
        data.window = data.window or {}
        data.window.fullscreen = data.window.fullscreen or false
        data.window.resizable = data.window.resizable ~= false
        data.window.default_width = data.window.default_width or 30
        data.window.default_height = data.window.default_height or 15
        data.window.min_width = data.window.min_width or 10
        data.window.min_height = data.window.min_height or 5
        data.category = data.category or "other"

        return data
    end

    return nil
end

function api.public.installProgram(app_id, app_data, source_path, to_system)
    local target_dir = to_system and SYSTEM_APPS_DIR or APPS_DIR
    local app_folder = fs.combine(target_dir, app_id)

    if fs.exists(app_folder) then
        return false, "App already installed"
    end

    fs.makeDir(app_folder)

    if source_path and fs.exists(source_path) then
        local files = fs.list(source_path)
        for _, file in ipairs(files) do
            local src = fs.combine(source_path, file)
            local dest = fs.combine(app_folder, file)
            fs.copy(src, dest)
        end
    end

    app_data.id = app_id
    local json_path = fs.combine(app_folder, "app.json")
    local file = fs.open(json_path, "w")
    if file then
        file.write(textutils.serializeJSON(app_data))
        file.close()
    end

    api.private.loadAllPrograms()

    event.dispatch("registry.program_installed", app_id)
    return true
end

-- Public API: Uninstall a program for current user
function api.public.uninstallProgram(program_id)
    local program = programs[program_id]

    if not program then
        return false, "Program not found"
    end
    
    if program.system then
        return false, "Cannot uninstall system apps"
    end
    
    -- Get current user
    local config = require("core.config")
    local current_user = config.getCurrentUser()
    
    if not current_user then
        return false, "No user logged in"
    end
    
    -- Remove user's JSON
    local user_app_json = fs.combine("users", current_user, "apps", program_id .. ".json")
    if fs.exists(user_app_json) then
        fs.delete(user_app_json)
    end
    
    -- Check if any other user has this app
    local userfs = require("core.service").getService("userfs")
    local users_dir = "users"
    local other_users_have_app = false
    
    if fs.exists(users_dir) then
        local users = fs.list(users_dir)
        for _, username in ipairs(users) do
            if username ~= current_user then
                local other_user_json = fs.combine(users_dir, username, "apps", program_id .. ".json")
                if fs.exists(other_user_json) then
                    other_users_have_app = true
                    break
                end
            end
        end
    end
    
    -- Only delete shared files if no other user has it
    if not other_users_have_app and program.app_path and fs.exists(program.app_path) then
        fs.delete(program.app_path)
    end

    -- Remove from memory
    programs[program_id] = nil

    event.dispatch("registry.program_uninstalled", program_id, current_user)
    return true
end

function api.public.getProgram(program_id)
    return programs[program_id]
end

function api.public.listPrograms(category)
    local list = {}

    for id, program in pairs(programs) do
        if not category or program.category == category then
            table.insert(list, program)
        end
    end
    return list
end

-- Alias for listPrograms
function api.public.getPrograms(category)
    return api.public.listPrograms(category)
end

function api.public.updateProgram(program_id, updates)
    local program = programs[program_id]

    if not program then
        return false, "Program not found"
    end

    for key, value in pairs(updates) do
        if key ~= "id" then
            programs[program_id][key] = value
        end
    end

    if program.app_path then
        local json_path = fs.combine(program.app_path, "app.json")
        local file = fs.open(json_path, "w")
        if file then
            file.write(textutils.serializeJSON(programs[program_id]))
            file.close()
        end
    end

    event.dispatch("registry.program_updated", program_id)

    return true
end

function api.public.hasProgram(program_id)
    return programs[program_id] ~= nil
end

function api.public.getProgramsByCategory()
    local by_category = {}

    for id, program in pairs(programs) do
        local cat = program.category or "other"
        if not by_category[cat] then
            by_category[cat] = {}
        end
        table.insert(by_category[cat], program)
    end

    return by_category
end

return api
