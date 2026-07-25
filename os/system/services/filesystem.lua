-- FileSystem Service
-- Central file management service for BasaltOS

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")

local api = api_factory.new()

-- File type registry: extension -> {app_id, editor_id, icon}
local file_type_registry = {}
-- Recent files list (newest first)
local recent_files = {}
local max_recent_files = 20
local USER_OPEN_ASSOCIATIONS = "filetypes.associations"
local USER_EDIT_ASSOCIATIONS = "filetypes.editors"

local function extensionOf(value)
    value = tostring(value or "")
    local extension = value:match("%.([^%.\\/]+)$")
    if extension then return extension:lower() end
    if not value:find("[\\/]") then
        extension = value:gsub("^%.", ""):lower()
        if extension ~= "" then return extension end
    end
    return nil
end

local function associationPath(action)
    return action == "edit" and USER_EDIT_ASSOCIATIONS or USER_OPEN_ASSOCIATIONS
end

local function userAssociations(action)
    if type(config.getUserConfig) ~= "function" then return {} end
    local values = config.getUserConfig(associationPath(action), {})
    return type(values) == "table" and values or {}
end

local function copyMap(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function installedProgram(app_id)
    if type(app_id) ~= "string" or app_id == "" then return false end
    local registry = service.getService("registry")
    return not registry or not registry.getProgram or registry.getProgram(app_id) ~= nil
end

local function configuredAssociation(extension, action)
    if not extension then return nil end
    local user_value = userAssociations(action)[extension]
    if installedProgram(user_value) then return user_value, "user" end

    local root = action == "edit" and "filetypes.editors." or "filetypes.associations."
    local system_value = config.get(root .. extension)
    if installedProgram(system_value) then return system_value, "system" end

    local registered = file_type_registry[extension]
    local runtime_value = registered
        and (action == "edit" and registered.editor_id or registered.app_id)
    if installedProgram(runtime_value) then return runtime_value, "runtime" end
    return nil, nil
end

function api.public.init()
    api.private.registerDefaultTypes()
    event.on("registry.program_uninstalled", function()
        api.private.pruneUserAssociations()
    end)
    event.on("registry.reloaded", function(username)
        if username then api.private.pruneUserAssociations() end
    end)
    log.info("FILESYSTEM", "Service initialized")
end

-- Load file type associations from system config
function api.private.registerDefaultTypes()
    local associations = config.get("filetypes.associations", {})
    for ext, app_id in pairs(associations) do
        api.public.registerFileType(ext, app_id)
    end
    local editors = config.get("filetypes.editors", {})
    for ext, app_id in pairs(editors) do
        api.public.registerFileEditor(ext, app_id)
    end
end

-- Open a file with its associated application.
-- Prompts with the shared Open-with dialog when no association exists.
-- @param path string  Full path to the file
-- @return boolean success, string|nil error
local function launchFile(path, app_id)
    if not fs.exists(path) then
        return false, "File not found: " .. path
    end
    if fs.isDir(path) then
        return false, "Cannot open a directory as a file: " .. path
    end

    if type(app_id) ~= "string" or app_id == "" then
        return false, "No application selected"
    end

    local process_service = service.getService("process")
    if not process_service then
        return false, "Process service not available"
    end

    local pid, err = process_service.startProgram(app_id, {path})
    if not pid then
        return false, err or ("Could not start application: " .. app_id)
    end

    api.public.addRecentFile(path)
    return true, pid
end

function api.public.openFile(path)
    local app_id = api.public.getAppForFile(path)
    if not app_id then return api.public.openWith(path, {action="open"}) end
    return launchFile(path, app_id)
end

-- Open a file with an explicit application instead of its registered default.
-- @param path string Full path to the file
-- @param app_id string Registered application ID
-- @return boolean success, number|string|nil pid_or_error
function api.public.openFileWith(path, app_id)
    return launchFile(path, app_id)
end

-- Open a file with the editor registered for its extension.
function api.public.editFile(path)
    local app_id = api.public.getEditorForFile(path)
    if not app_id then return api.public.openWith(path, {action="edit"}) end
    return launchFile(path, app_id)
end

-- Register a file type association
-- @param extension string File extension (without dot)
-- @param app_id string|nil App ID to open this file type (nil = no association)
-- @param icon string|nil Optional icon character
function api.public.registerFileType(extension, app_id, icon)
    extension = tostring(extension or ""):gsub("^%.", ""):lower()
    if extension == "" then return false, "Invalid extension" end
    local entry = file_type_registry[extension] or {}
    entry.app_id = app_id
    entry.icon = icon or entry.icon
    file_type_registry[extension] = entry
    log.debug("FILESYSTEM", "Registered file type: " .. extension .. " -> " .. tostring(app_id))
    return true
end

-- Register the application used for an explicit Edit action. This does not
-- alter the application's normal Open association.
function api.public.registerFileEditor(extension, app_id)
    extension = tostring(extension or ""):gsub("^%.", ""):lower()
    if extension == "" then return false, "Invalid extension" end
    local entry = file_type_registry[extension] or {}
    entry.editor_id = app_id
    file_type_registry[extension] = entry
    log.debug("FILESYSTEM", "Registered file editor: " .. extension .. " -> " .. tostring(app_id))
    return true
end

-- Set or clear a per-user association. Passing nil resets the extension to the
-- system/runtime default instead of creating a global configuration change.
function api.public.setUserAssociation(extension, app_id, action)
    extension = extensionOf(extension)
    action = tostring(action or "open"):lower()
    if not extension then return false, "Invalid extension" end
    if action ~= "open" and action ~= "edit" then return false, "Invalid action" end
    if app_id ~= nil and not installedProgram(app_id) then
        return false, "Application not found"
    end
    if type(config.setUserConfig) ~= "function" then
        return false, "User configuration is unavailable"
    end

    local values = copyMap(userAssociations(action))
    values[extension] = app_id
    if not config.setUserConfig(associationPath(action), values, true) then
        return false, "No user logged in"
    end
    event.dispatch("filesystem.association_changed", extension, action, app_id)
    return true
end

function api.public.resetUserAssociations(extension, action)
    if extension ~= nil then
        extension = extensionOf(extension)
        if not extension then return false, "Invalid extension" end
    end
    if action ~= nil then
        action = tostring(action):lower()
        if action ~= "open" and action ~= "edit" then return false, "Invalid action" end
    end

    local actions = action and {action} or {"open", "edit"}
    for _, current_action in ipairs(actions) do
        local values = copyMap(userAssociations(current_action))
        if extension then values[extension] = nil else values = {} end
        if type(config.setUserConfig) ~= "function"
            or not config.setUserConfig(
                associationPath(current_action), values, false
            ) then
            return false, "No user logged in"
        end
    end
    if type(config.saveUserConfig) == "function" then config.saveUserConfig() end
    event.dispatch("filesystem.associations_reset", extension, action)
    return true
end

function api.private.pruneUserAssociations()
    local registry = service.getService("registry")
    if not registry or not registry.getProgram
        or type(config.setUserConfig) ~= "function" then
        return false
    end

    local changed = false
    for _, action in ipairs({"open", "edit"}) do
        local values = copyMap(userAssociations(action))
        local action_changed = false
        for extension, app_id in pairs(values) do
            if type(extension) ~= "string" or not registry.getProgram(app_id) then
                values[extension] = nil
                action_changed = true
            end
        end
        if action_changed then
            config.setUserConfig(associationPath(action), values, false)
            changed = true
        end
    end
    if changed then
        if type(config.saveUserConfig) == "function" then config.saveUserConfig() end
        event.dispatch("filesystem.associations_pruned")
    end
    return changed
end

-- Get the app associated with a file type
-- Reads live from config so changes to config.dat take effect without restart.
-- @param filename string Full filename or just extension
-- @return string|nil app_id The app ID, or nil if no association
-- @return string|nil icon The icon character, or nil
function api.public.getAppForFile(filename)
    local extension = extensionOf(filename)
    local app_id, source = configuredAssociation(extension, "open")
    local registered = extension and file_type_registry[extension]
    return app_id, registered and registered.icon or nil, source
end

-- Get the explicit editor associated with a filename or extension.
function api.public.getEditorForFile(filename)
    local extension = extensionOf(filename)
    if not extension then return nil end
    return configuredAssociation(extension, "edit")
end

local function programAcceptsExtension(program, extension)
    local argument = type(program.args) == "table" and program.args[1] or nil
    if type(argument) ~= "table" or argument.type ~= "file" then return false end
    if type(argument.extensions) ~= "table" or #argument.extensions == 0 then
        return true
    end
    for _, supported in ipairs(argument.extensions) do
        if tostring(supported):lower():gsub("^%.", "") == extension then return true end
    end
    return false
end

-- Installed applications ranked for an Open-with chooser. Manifest file
-- arguments improve the ranking, while every launchable app remains available.
function api.public.getAppsForFile(path, action)
    action = tostring(action or "open"):lower()
    local registry = service.getService("registry")
    if not registry or not registry.listPrograms then return {} end
    local extension = extensionOf(path)
    local current = action == "edit"
        and api.public.getEditorForFile(path) or api.public.getAppForFile(path)
    local registered = extension and file_type_registry[extension] or nil
    local runtime = registered
        and (action == "edit" and registered.editor_id or registered.app_id)
    local result = {}

    for _, program in ipairs(registry.listPrograms()) do
        if type(program.id) == "string" and type(program.executable) == "string" then
            local score = 40
            if program.id == current then score = 0
            elseif program.id == runtime then score = 5
            elseif extension and programAcceptsExtension(program, extension) then score = 10
            elseif program.id == "notepad" or program.id == "edit" then score = 20 end
            result[#result + 1] = {
                id=program.id,
                name=program.name or program.id,
                description=program.description or program.category or "Application",
                score=score,
                recommended=score <= 10,
            }
        end
    end
    table.sort(result, function(left, right)
        if left.score == right.score then
            return left.name:lower() < right.name:lower()
        end
        return left.score < right.score
    end)
    return result
end

-- Shared native Open-with dialog used by Filely, Desktop and unknown-file
-- double-clicks. options.action is "open" or "edit".
function api.public.openWith(path, options, callback)
    options = type(options) == "table" and options or {}
    local action = tostring(options.action or "open"):lower()
    if action ~= "open" and action ~= "edit" then return false, "Invalid action" end
    if not fs.exists(path) then return false, "File not found: " .. tostring(path) end
    if fs.isDir(path) then return false, "Cannot open a directory as a file" end

    local dialog = service.getService("dialog")
    if not dialog or not dialog.custom then return false, "Dialog service not available" end
    local candidates = api.public.getAppsForFile(path, action)
    if #candidates == 0 then return false, "No applications are available" end
    local extension = extensionOf(path)
    local selected_index = 1
    local always_use = options.always == true
    local height = math.min(16, math.max(10, #candidates + 7))
    local verb = action == "edit" and "edit" or "open"
    local action_label = action == "edit" and "Edit" or "Open"

    local controller, err = dialog.custom(
        "Open with...",
        40,
        height,
        function(box, control)
            local width, box_height = box:getSize()
            box:addLabel({
                x=2, y=3, width=width - 3, height=1,
                text="Choose an app to " .. verb .. " " .. fs.getName(path),
                foreground=config.get("theme.desktop_fg"),
                background=config.get("theme.desktop_bg"),
                disabled=true,
            })
            local app_list = box:addList({
                x=2, y=5, width=width - 3,
                height=math.max(2, box_height - 9),
                background=config.get("theme.desktop_bg"),
                foreground=config.get("theme.desktop_fg"),
                selectionBackground=config.get("theme.primary"),
                selectionForeground=config.get("theme.text"),
            })
            for _, candidate in ipairs(candidates) do
                local suffix = candidate.recommended and "  (recommended)" or ""
                app_list:addItem({text=candidate.name .. suffix})
            end
            app_list:selectItem(1, false)
            app_list:onChange(function(_, index)
                selected_index = tonumber(index) or app_list:getSelectedIndex() or 1
            end)

            if extension then
                box:addCheckbox({
                    x=2, y=box_height - 3,
                text=action == "edit"
                    and ("Always use this app to edit ." .. extension .. " files")
                    or ("Always use this app for ." .. extension .. " files"),
                    checked=always_use,
                    foreground=config.get("theme.desktop_fg"),
                    background=config.get("theme.desktop_bg"),
                }):onChange(function(_, checked)
                    always_use = checked == true
                end)
            end
            box:addButton({
                x=width - 18, y=box_height - 1, width=8, height=1,
                text="Cancel",
                foreground=config.get("theme.desktop_fg"),
                background=config.get("theme.surface"),
            }):onClick(function() control:close(nil) end)
            box:addButton({
                x=width - 9, y=box_height - 1, width=8, height=1,
                text=action_label,
                foreground=config.get("theme.text"),
                background=config.get("theme.primary"),
            }):onClick(function()
                local candidate = candidates[selected_index]
                if candidate then
                    control:close({
                        app_id=candidate.id,
                        always=always_use,
                        action=action,
                    })
                end
            end)
        end,
        function(result)
            if not result then return end
            if result.always and extension then
                local associated, association_error = api.public.setUserAssociation(
                    extension, result.app_id, action
                )
                if not associated then
                    if callback then pcall(callback, false, association_error) end
                    return
                end
            end
            local opened, launch_result = launchFile(path, result.app_id)
            event.dispatch(
                "filesystem.opened_with", path, result.app_id, action, result.always
            )
            if callback then pcall(callback, opened, launch_result, result) end
        end
    )
    if not controller then return false, err end
    return true, controller
end

-- Return the user-facing actions available for a file. Consumers such as
-- Filely do not need hard-coded knowledge of Lua, image, or document types.
function api.public.getFileActions(path)
    if type(path) ~= "string" or path == "" or fs.isDir(path) then return {} end
    local open_app = api.public.getAppForFile(path)
    local editor_app = api.public.getEditorForFile(path)
    local actions = {}
    if open_app then
        actions[#actions + 1] = {id="open", label="Open", app_id=open_app}
    end
    if editor_app and editor_app ~= open_app then
        actions[#actions + 1] = {id="edit", label="Edit", app_id=editor_app}
    end
    actions[#actions + 1] = {id="open_with", label="Open with...", app_id=nil}
    return actions
end

-- Execute an action returned by getFileActions(). Keeping execution here means
-- desktops and file managers only consume the OS model and never duplicate
-- association rules.
function api.public.executeFileAction(path, action_id)
    action_id = tostring(action_id or "open"):lower()
    if action_id == "open" then return api.public.openFile(path) end
    if action_id == "edit" then return api.public.editFile(path) end
    if action_id == "open_with" then return api.public.openWith(path, {action="open"}) end
    return false, "Action not available: " .. action_id
end

local function normalizeFileIcon(value)
    if type(value) ~= "table" then return nil end
    local char = value.char
    if type(char) == "number" then
        char = math.floor(char)
        if char < 0 or char > 255 then return nil end
    elseif type(char) == "string" and #char > 0 then
        char = char:sub(1, 1)
    else
        return nil
    end

    local function normalizeColor(color)
        if color == nil then return nil, true end
        if type(color) == "string" then
            return colors[color], colors[color] ~= nil
        end
        if type(color) == "number" then
            local valid = colors.toBlit and pcall(colors.toBlit, color)
            return color, valid == true
        end
        return nil, false
    end

    local foreground, valid_foreground = normalizeColor(value.fg or value.foreground)
    -- `color` is retained as a backwards-compatible alias for `bg`.
    local background, valid_background = normalizeColor(value.bg or value.background or value.color)
    if not valid_foreground or not valid_background then return nil end

    return {char=char, fg=foreground, bg=background}
end

-- Return the optional 1x1 file icon declared by an associated app manifest.
function api.public.getFileIconForApp(app_id)
    if type(app_id) ~= "string" or app_id == "" then return nil end
    local registry = service.getService("registry")
    local program = registry and registry.getProgram(app_id) or nil
    return program and normalizeFileIcon(program.file_icon) or nil
end

-- Get all registered file types
-- @return table List of {extension, app_id, editor_id, icon}
function api.public.getFileTypes()
    local extensions = {}
    for extension in pairs(file_type_registry) do extensions[extension] = true end
    for extension in pairs(config.get("filetypes.associations", {}) or {}) do
        extensions[extension] = true
    end
    for extension in pairs(config.get("filetypes.editors", {}) or {}) do
        extensions[extension] = true
    end
    for extension in pairs(userAssociations("open")) do extensions[extension] = true end
    for extension in pairs(userAssociations("edit")) do extensions[extension] = true end

    local types = {}
    local user_open = userAssociations("open")
    local user_edit = userAssociations("edit")
    for ext in pairs(extensions) do
        local entry = file_type_registry[ext] or {}
        local app_id, _, open_source = api.public.getAppForFile(ext)
        local editor_id, edit_source = api.public.getEditorForFile(ext)
        local system_app_id = config.get("filetypes.associations." .. ext)
            or entry.app_id
        local system_editor_id = config.get("filetypes.editors." .. ext)
            or entry.editor_id
        table.insert(types, {
            extension = ext,
            app_id = app_id,
            editor_id = editor_id,
            system_app_id = installedProgram(system_app_id) and system_app_id or nil,
            system_editor_id = installedProgram(system_editor_id)
                and system_editor_id or nil,
            open_source = open_source,
            edit_source = edit_source,
            user_app_id = user_open[ext],
            user_editor_id = user_edit[ext],
            icon = entry.icon,
            file_icon = api.public.getFileIconForApp(app_id),
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

local function runFsAction(action)
    local ok, err = pcall(action)
    if not ok then return false, tostring(err) end
    return true
end

function api.public.exists(path)
    return type(path) == "string" and fs.exists(path)
end

-- Copy a file or directory
-- @param source string Source path
-- @param destination string Destination path
-- @return boolean success
function api.public.copy(source, destination)
    if not fs.exists(source) then
        return false, "Source does not exist"
    end
    if fs.exists(destination) then
        return false, "Destination already exists"
    end
    local ok, err = runFsAction(function() fs.copy(source, destination) end)
    if not ok then return false, err end
    event.dispatch("filesystem.file_copied", source, destination)
    return true
end

-- Move a file or directory
-- @param source string Source path
-- @param destination string Destination path
-- @return boolean success
function api.public.move(source, destination)
    if not fs.exists(source) then
        return false, "Source does not exist"
    end
    if fs.exists(destination) then
        return false, "Destination already exists"
    end
    local ok, err = runFsAction(function() fs.move(source, destination) end)
    if not ok then return false, err end
    event.dispatch("filesystem.file_moved", source, destination)
    return true
end

-- Delete a file or directory
-- @param path string Path to delete
-- @return boolean success
function api.public.delete(path)
    if not fs.exists(path) then
        return false, "Path does not exist"
    end
    local ok, err = runFsAction(function() fs.delete(path) end)
    if not ok then return false, err end
    event.dispatch("filesystem.file_deleted", path)
    return true
end

-- Create a directory
-- @param path string Directory path
-- @return boolean success
function api.public.makeDir(path)
    if fs.exists(path) then
        return false, "Path already exists"
    end
    local ok, err = runFsAction(function() fs.makeDir(path) end)
    if not ok then return false, err end
    event.dispatch("filesystem.directory_created", path)
    return true
end

-- Create a new file and optionally write initial content.
-- @return boolean success, string|nil error
function api.public.createFile(path, content)
    if fs.exists(path) then return false, "Path already exists" end
    local ok, err = runFsAction(function()
        local handle = assert(fs.open(path, "w"), "Could not open file for writing")
        if content ~= nil and content ~= "" then handle.write(tostring(content)) end
        handle.close()
    end)
    if not ok then return false, err end
    event.dispatch("filesystem.file_created", path)
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
    extension = extension and extension:lower() or nil
    local is_dir = fs.isDir(path)
    local size = is_dir and 0 or fs.getSize(path)
    local modified = nil
    if fs.attributes then
        local ok, attributes = pcall(fs.attributes, path)
        if ok and type(attributes) == "table" then
            modified = attributes.modified
        end
    end
    
    -- Get associated app and icon
    local app_id, editor_id, icon, file_icon = nil, nil, nil, nil
    if not is_dir and extension then
        app_id, icon = api.public.getAppForFile(name)
        editor_id = api.public.getEditorForFile(name)
        file_icon = api.public.getFileIconForApp(app_id)
    end
    
    return {
        name = name,
        path = path,
        size = size,
        isDir = is_dir,
        extension = extension,
        modified = modified,
        app_id = app_id,
        editor_id = editor_id,
        icon = icon,
        file_icon = file_icon,
    }
end

-- List directory contents with file info
-- @param path string Directory path
-- @return table|nil List of file info tables
function api.public.listDir(path)
    if type(path) ~= "string" or not fs.exists(path) or not fs.isDir(path) then
        return nil, "Directory not found: " .. tostring(path)
    end

    local listed, items = pcall(fs.list, path)
    if not listed then return nil, tostring(items) end
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
