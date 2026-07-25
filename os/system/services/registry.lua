-- /services/registry.lua
-- Program Registry: Manages installed programs and their metadata

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local path = require("core.path")
local log = require("core.log")

local api = api_factory.new()

local APPS_DIR = "apps"
local SYSTEM_APPS_DIR = "system/apps"
local programs = {}
local resolveIconPaths

local function validAppId(app_id)
    return type(app_id) == "string"
        and app_id:match("^[%w][%w._-]*$") ~= nil
end

local function readJson(filepath)
    if not fs.exists(filepath) or fs.isDir(filepath) then return nil end
    local file = fs.open(filepath, "r")
    if not file then return nil end
    local content = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserializeJSON, content)
    if ok and type(data) == "table" then return data end
    return nil
end

local function writeJson(filepath, value)
    local parent = fs.getDir(filepath)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local file = fs.open(filepath, "w")
    if not file then return false, "Could not write " .. filepath end
    local ok, encoded = pcall(textutils.serializeJSON, value)
    if not ok then
        file.close()
        return false, tostring(encoded)
    end
    file.write(encoded)
    file.close()
    return true
end

local function userAppsDirectory(username)
    return fs.combine("users", username, "apps")
end

local function userInstallPath(username, app_id)
    return fs.combine(userAppsDirectory(username), app_id .. ".json")
end

local function installedAt()
    if os.epoch then return os.epoch("utc") end
    if os.time then return math.floor(os.time() * 1000) end
    return 0
end

local function installRecord(app_id, app_data, source, timestamp)
    return {
        id=app_id,
        version=tostring(app_data.version or "1.0.0"),
        source=source,
        installed_at=tonumber(timestamp) or installedAt(),
    }
end

local function writeUserInstallRecord(username, app_id, app_data, source, timestamp)
    return writeJson(userInstallPath(username, app_id),
        installRecord(app_id, app_data, source, timestamp))
end

local function normalizeExternalProgram(record, app_id)
    local executable = type(record.executable) == "string"
        and fs.combine("", record.executable) or ""
    if executable == "" or not fs.exists(executable) or fs.isDir(executable) then
        return nil
    end
    local app_data = {
        id=app_id,
        name=tostring(record.name or app_id),
        version=tostring(record.version or "1.0.0"),
        author=record.author,
        description=record.description,
        category=tostring(record.category or "other"),
        executable=executable,
        window=type(record.window) == "table" and record.window or {},
        external=true,
        user_installed=true,
        app_path=fs.getDir(executable),
        installed_at=record.installed_at,
        install_source=record.source,
    }
    app_data.window.fullscreen = app_data.window.fullscreen == true
    app_data.window.resizable = app_data.window.resizable ~= false
    app_data.window.default_width = app_data.window.default_width or 40
    app_data.window.default_height = app_data.window.default_height or 15
    app_data.window.min_width = app_data.window.min_width or 20
    app_data.window.min_height = app_data.window.min_height or 8
    resolveIconPaths(app_data, app_data.app_path)
    return app_data
end

-- Program metadata structure
--[[
{
    id = "unique_program_id",        -- REQUIRED: unique identifier
    name = "Display Name",
    version = "1.0.0",
    executable = "/path/to/program.lua",
    icon = "/path/to/icon.bimg",     -- legacy alias for icons.main
    icons = {                         -- optional; paths are app-relative
        main = "icon.flimg",         -- BIMG/FLIMG, normally 4x3 terminal cells
        taskbar = "taskbar.flimg",   -- BIMG/FLIMG, normally 2x2 terminal cells
    },
    file_icon = {                     -- optional 1x1 icon for associated files
        char = 131,                   -- ComputerCraft character code (0..255)
        fg = "white",                -- optional colors.* name/value
        bg = "lightBlue",            -- optional colors.* name/value
    },
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

resolveIconPaths = function(app_data, app_path)
    local declared = type(app_data.icons) == "table" and app_data.icons or {}
    local icons = {
        main=declared.main or app_data.icon,
        taskbar=declared.taskbar,
    }

    if not icons.main then
        local default_flimg = fs.combine(app_path, "icon.flimg")
        local default_bimg = fs.combine(app_path, "icon.bimg")
        if fs.exists(default_flimg) then icons.main = "icon.flimg"
        elseif fs.exists(default_bimg) then icons.main = "icon.bimg" end
    end
    if not icons.taskbar then
        local default_flimg = fs.combine(app_path, "taskbar.flimg")
        local default_bimg = fs.combine(app_path, "taskbar.bimg")
        if fs.exists(default_flimg) then icons.taskbar = "taskbar.flimg"
        elseif fs.exists(default_bimg) then icons.taskbar = "taskbar.bimg" end
    end

    path.setCurrentProgramPath(app_path)
    if icons.main then icons.main = path.resolve(icons.main, app_path) end
    if icons.taskbar then icons.taskbar = path.resolve(icons.taskbar, app_path) end
    path.setCurrentProgramPath(nil)

    app_data.icons = icons
    -- Keep old consumers and third-party services working during migration.
    app_data.icon = icons.main
end

function api.public.init()
    if not fs.exists(APPS_DIR) then
        fs.makeDir(APPS_DIR)
    end

    if not fs.exists(SYSTEM_APPS_DIR) then
        fs.makeDir(SYSTEM_APPS_DIR)
    end

    api.private.loadAllPrograms()

    event.on("user.login", function(username)
        api.private.loadAllPrograms(username)
        event.dispatch("registry.reloaded", username)
    end)
    event.on("user.logout", function()
        api.private.loadAllPrograms(false)
        event.dispatch("registry.reloaded", nil)
    end)
end

function api.private.loadAllPrograms(username)
    programs = {}

    -- Scan system/apps/ (system apps with app.json)
    api.private.scanAppDirectory(SYSTEM_APPS_DIR, true)

    -- Load user-installed apps from users/USERNAME/apps/*.json
    local config = require("core.config")
    local current_user = username == false and nil or (username or config.getCurrentUser())
    
    if current_user then
        api.private.loadUserInstalledApps(current_user)
    end

end

-- Private: Load user-installed apps from users/USERNAME/apps/*.json
function api.private.loadUserInstalledApps(username)
    api.private.migrateLegacyInstalledApps(username)
    local user_apps_dir = userAppsDirectory(username)
    
    if not fs.exists(user_apps_dir) or not fs.isDir(user_apps_dir) then
        return
    end
    
    local files = fs.list(user_apps_dir)
    
    for _, filename in ipairs(files) do
        if filename:match("%.json$") then
            local json_path = fs.combine(user_apps_dir, filename)
            local record = readJson(json_path)
            local filename_id = filename:gsub("%.json$", "")
            local app_id = record and (record.id or filename_id) or nil

            if validAppId(app_id) then
                if record and record.external == true then
                    local external = normalizeExternalProgram(record, app_id)
                    if external and not programs[app_id] then
                        programs[app_id] = external
                    end
                else
                local app_folder = fs.combine(APPS_DIR, app_id)
                local manifest_path = fs.combine(app_folder, "app.json")
                local app_data = api.private.loadAppJson(manifest_path)

                -- Older BasaltOS versions stored the full manifest in the
                -- user's apps directory. Keep it readable long enough to
                -- compact the record, even if the shared copy is incomplete.
                if not app_data and record and record.executable then
                    app_data = api.private.loadAppJson(json_path)
                end

                if app_data then
                    app_data.id = app_id
                -- Handle executable path
                if app_data.executable then
                    path.setCurrentProgramPath(app_folder)
                    app_data.executable = path.resolve(app_data.executable, app_folder)
                    path.setCurrentProgramPath(nil)
                end
                
                resolveIconPaths(app_data, app_folder)

                app_data.user_installed = true
                app_data.app_path = app_folder
                app_data.installed_at = record and record.installed_at or nil
                app_data.install_source = record and record.source or nil
                
                -- Only register if not already registered (system apps have priority)
                if not programs[app_id] then
                    programs[app_id] = app_data
                end

                -- Compact legacy per-user manifests into the single registry
                -- install-record format. The app's own metadata lives only in
                -- apps/<id>/app.json.
                if record and (record.executable ~= nil or record.window ~= nil
                    or record.name ~= nil or record.category ~= nil) then
                    writeUserInstallRecord(username, app_id, app_data,
                        record.source, record.installed_at)
                end
                end
                end
            end
        end
    end
end

-- One-time migration for the retired userfs installed.dat database. It never
-- controlled the Registry, so only entries with a valid shared app manifest can
-- be recovered. The legacy file is removed after the migration attempt.
function api.private.migrateLegacyInstalledApps(username)
    local legacy_path = fs.combine(userAppsDirectory(username), "installed.dat")
    if not fs.exists(legacy_path) or fs.isDir(legacy_path) then return false end

    local legacy
    local file = fs.open(legacy_path, "r")
    if file then
        local content = file.readAll()
        file.close()
        local ok, value = pcall(textutils.unserialize, content)
        if ok and type(value) == "table" then legacy = value end
    end

    local migrated = 0
    for app_id, old_record in pairs(legacy or {}) do
        app_id = tostring(app_id)
        local manifest_path = fs.combine(APPS_DIR, app_id, "app.json")
        local app_data = validAppId(app_id)
            and api.private.loadAppJson(manifest_path) or nil
        local destination = validAppId(app_id)
            and userInstallPath(username, app_id) or nil
        if app_data and destination and not fs.exists(destination) then
            local ok = writeUserInstallRecord(username, app_id, app_data,
                old_record and old_record.source,
                old_record and old_record.installed_at)
            if ok then migrated = migrated + 1 end
        end
    end

    local removed, remove_error = pcall(fs.delete, legacy_path)
    if not removed then
        log.warn("REGISTRY", "Could not remove legacy installed.dat", {
            username=username, error=remove_error,
        })
    elseif migrated > 0 then
        log.info("REGISTRY", "Migrated legacy app records", {
            username=username, count=migrated,
        })
    end
    return removed, migrated
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

                    resolveIconPaths(app_data, app_path)

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
    local data = readJson(filepath)
    if data then
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

function api.public.installProgram(app_id, app_data, source_path, to_system, install_source)
    if not validAppId(app_id) then return false, "Invalid app ID" end
    if type(app_data) ~= "table" then return false, "Invalid app manifest" end

    local config = require("core.config")
    local current_user = not to_system and config.getCurrentUser() or nil
    if not to_system and not current_user then
        return false, "No user logged in"
    end
    if programs[app_id] and programs[app_id].system and not to_system then
        return false, "A system app already uses this ID"
    end

    local target_dir = to_system and SYSTEM_APPS_DIR or APPS_DIR
    local app_folder = fs.combine(target_dir, app_id)
    local user_record_path = current_user and userInstallPath(current_user, app_id)
        or nil
    if user_record_path and fs.exists(user_record_path) then
        return false, "App already installed"
    end

    local created_app_folder = false
    if fs.exists(app_folder) then
        if to_system then return false, "App already installed" end
        local existing = api.private.loadAppJson(fs.combine(app_folder, "app.json"))
        if not existing then return false, "Existing app files are incomplete" end
        if tostring(existing.version) ~= tostring(app_data.version or "1.0.0") then
            return false, "Another version of this app is already installed"
        end
        app_data = existing
    else
        local ok, install_error = pcall(function()
            fs.makeDir(app_folder)
            created_app_folder = true
            if source_path then
                if not fs.exists(source_path) or not fs.isDir(source_path) then
                    error("Source folder not found")
                end
                for _, filename in ipairs(fs.list(source_path)) do
                    fs.copy(fs.combine(source_path, filename),
                        fs.combine(app_folder, filename))
                end
            end
            app_data.id = app_id
            local written, write_error = writeJson(
                fs.combine(app_folder, "app.json"), app_data)
            if not written then error(write_error) end
        end)
        if not ok then
            if created_app_folder and fs.exists(app_folder) then
                pcall(fs.delete, app_folder)
            end
            return false, tostring(install_error)
        end
    end

    if current_user then
        local source = install_source or app_data.install_source
            or app_data.source or app_data.repository
        local written, write_error = writeUserInstallRecord(
            current_user, app_id, app_data, source)
        if not written then
            if created_app_folder and fs.exists(app_folder) then
                pcall(fs.delete, app_folder)
            end
            return false, write_error
        end
    end

    api.private.loadAllPrograms(current_user)
    event.dispatch("registry.program_installed", app_id, current_user)
    return true
end

function api.public.registerExternalProgram(app_id, app_data, executable_path, install_source)
    if not validAppId(app_id) then return false, "Invalid app ID" end
    if type(app_data) ~= "table" then return false, "Invalid app metadata" end

    executable_path = type(executable_path) == "string"
        and fs.combine("", executable_path) or ""
    if executable_path == "" or not fs.exists(executable_path)
        or fs.isDir(executable_path) then
        return false, "Executable file not found"
    end

    local config = require("core.config")
    local current_user = config.getCurrentUser()
    if not current_user then return false, "No user logged in" end
    if programs[app_id] and programs[app_id].system then
        return false, "A system app already uses this ID"
    end
    if programs[app_id] and not programs[app_id].external then
        return false, "Another installed app already uses this ID"
    end

    local record = {
        id=app_id,
        name=tostring(app_data.name or app_id),
        version=tostring(app_data.version or "1.0.0"),
        author=app_data.author,
        description=app_data.description,
        category=tostring(app_data.category or "other"),
        executable=executable_path,
        window=type(app_data.window) == "table" and app_data.window or nil,
        external=true,
        source=install_source,
        installed_at=installedAt(),
    }
    local written, write_error = writeJson(
        userInstallPath(current_user, app_id), record)
    if not written then return false, write_error end

    api.private.loadAllPrograms(current_user)
    event.dispatch("registry.program_installed", app_id, current_user)
    return true
end

function api.public.isSystemProgram(program_id)
    local program = programs[program_id]
    return program ~= nil and program.system == true
end

function api.public.canUninstallProgram(program_id)
    local program = programs[program_id]
    if not program then
        return false, "Program not found"
    end

    if program.system then
        return false, "Cannot uninstall system apps"
    end

    local config = require("core.config")
    local current_user = config.getCurrentUser()
    if not current_user then
        return false, "No user logged in"
    end

    local user_app_json = userInstallPath(current_user, program_id)
    if not fs.exists(user_app_json) then
        return false, "App is not installed for this user"
    end
    return true
end

-- Public API: Uninstall a program for current user
function api.public.uninstallProgram(program_id)
    local allowed, reason = api.public.canUninstallProgram(program_id)
    if not allowed then return false, reason end

    local program = programs[program_id]
    local config = require("core.config")
    local current_user = config.getCurrentUser()
    local user_app_json = userInstallPath(current_user, program_id)
    fs.delete(user_app_json)
    
    -- Check if any other user has this app
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
    if not program.external and not other_users_have_app
        and program.app_path and fs.exists(program.app_path) then
        fs.delete(program.app_path)
    end

    api.private.loadAllPrograms(current_user)

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

-- Rescan installed program manifests after an external installer has written
-- files. Package managers such as PineStore use this after their command
-- finishes so compatible BasaltOS apps appear without a reboot.
function api.public.reload()
    api.private.loadAllPrograms()
    local config = require("core.config")
    event.dispatch("registry.reloaded", config.getCurrentUser())
    return true
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
