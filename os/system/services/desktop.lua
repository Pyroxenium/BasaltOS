-- /services/desktop.lua
-- User desktop backed by users/<username>/desktop.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")
local icon = require("core.icon")
local wallpaper = require("core.wallpaper")

local function theme(key) return config.get("theme." .. key) end

local api = api_factory.new()

local DEFAULT_SHORTCUTS = {
    "filely",
    "basaltterminal",
    "launcher",
    "settings",
    "architect",
}

local SHORTCUT_EXTENSION = ".shortcut"
local FOLDER_ICON_PATH = "system/assets/icons/folder.bimg"
local FILE_ICON_PATH = icon.DEFAULT_PATH
local DOUBLE_CLICK_TIME = 0.45

local is_running = false
local desktop_frame = nil
local workspace = nil
local current_username = nil
local desktop_path = nil
local layout_file = nil
local layout = {}
local desktop_items = {}
local desktop_drop_target = nil
local selected_name = nil
local last_click_name = nil
local last_click_time = 0
local refresh_pending = false
local ctrl_down = false

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function fitText(value, width)
    local text = tostring(value or "")
    width = math.max(0, math.floor(tonumber(width) or 0))
    if #text <= width then return text end
    if width <= 2 then return (".."):sub(1, width) end
    return text:sub(1, width - 2) .. ".."
end

local function validName(value)
    local name = trim(value)
    if name == "" or name == "." or name == ".." then return false end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return false end
    return true, name
end

local function notifyError(message)
    local notification = service.getService("notification")
    if notification then notification.error("Desktop", tostring(message)) end
end

local function notify(message, kind)
    local notification = service.getService("notification")
    if not notification then return end
    if kind == "success" and notification.success then
        notification.success("Desktop", tostring(message))
    elseif notification.info then
        notification.info("Desktop", tostring(message))
    end
end

local function requestRefresh()
    if not desktop_frame or refresh_pending then return end
    refresh_pending = true
    local ui = service.getService("ui")
    if ui and ui.deferDispatch then
        ui.deferDispatch("desktop.refresh")
    else
        event.dispatch("desktop.refresh")
    end
end

local function resolveDesktopPaths()
    local userfs = service.getService("userfs")
    desktop_path = userfs and userfs.getPath("desktop") or nil
    if not desktop_path and current_username then
        desktop_path = fs.combine("users", current_username, "desktop")
    end
    if not desktop_path then return false end
    if not fs.exists(desktop_path) then fs.makeDir(desktop_path) end

    local config_dir = fs.combine("users", current_username or "default", "config")
    if not fs.exists(config_dir) then fs.makeDir(config_dir) end
    layout_file = fs.combine(config_dir, "desktop_layout.dat")
    return true
end

local function loadLayout()
    layout = {}
    if not layout_file or not fs.exists(layout_file) then return end
    local handle = fs.open(layout_file, "r")
    if not handle then return end
    local content = handle.readAll()
    handle.close()
    local ok, data = pcall(textutils.unserialize, content)
    if ok and type(data) == "table" then layout = data end
end

local function saveLayout()
    if not layout_file then return false end
    local handle = fs.open(layout_file, "w")
    if not handle then return false end
    handle.write(textutils.serialize(layout))
    handle.close()
    return true
end

local function readShortcut(path)
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local content = handle.readAll()
    handle.close()
    local ok, data = pcall(textutils.unserialize, content)
    if not ok or type(data) ~= "table" then return nil end
    if (data.type ~= "program" and data.type ~= "path")
        or type(data.target) ~= "string" or data.target == "" then
        return nil
    end
    return data
end

local function writeShortcut(path, data, emit_event)
    local content = textutils.serialize({
        version=1,
        type=data.type,
        target=data.target,
        args=type(data.args) == "table" and data.args or nil,
    })
    if emit_event then
        local filesystem = service.getService("filesystem")
        if not filesystem then return false, "Filesystem service unavailable" end
        return filesystem.createFile(path, content)
    end
    local handle = fs.open(path, "w")
    if not handle then return false, "Could not create shortcut" end
    handle.write(content)
    handle.close()
    return true
end

local function uniquePath(name, extension)
    local base = name
    local index = 1
    local candidate = fs.combine(desktop_path, base .. (extension or ""))
    while fs.exists(candidate) do
        index = index + 1
        candidate = fs.combine(desktop_path,
            base .. " (" .. tostring(index) .. ")" .. (extension or ""))
    end
    return candidate
end

local function seedDesktop()
    local marker = fs.combine("users", current_username or "default", "config", "desktop_seeded.dat")
    if fs.exists(marker) then return end

    local files = fs.list(desktop_path)
    if #files == 0 then
        local registry = service.getService("registry")
        for _, program_id in ipairs(DEFAULT_SHORTCUTS) do
            local program = registry and registry.getProgram(program_id) or nil
            if program then
                local name = tostring(program.name or program_id):gsub("[/\\]", "-")
                writeShortcut(uniquePath(name, SHORTCUT_EXTENSION), {
                    type="program", target=program_id,
                }, false)
            end
        end
    end

    local handle = fs.open(marker, "w")
    if handle then handle.write("true"); handle.close() end
end

local function launchProgram(program_id, args)
    local process = service.getService("process")
    if not process then
        notifyError("Process service is unavailable")
        return false
    end
    local pid, err = process.startProgram(program_id, args)
    if err then
        log.error("DESKTOP", "Failed to launch program", {
            program_id=program_id, error=tostring(err),
        })
        notifyError(err)
        return false
    end
    return pid ~= nil or err == nil
end

local function openPath(path)
    if not fs.exists(path) then
        notifyError("Target no longer exists: " .. tostring(path))
        return false
    end
    if fs.isDir(path) then
        return launchProgram("filely", {path})
    end
    local filesystem = service.getService("filesystem")
    if not filesystem then return false end
    local ok, err = filesystem.openFile(path)
    if not ok then notifyError(err or "No application is associated with this file") end
    return ok
end

local function descriptorFor(entry)
    local registry = service.getService("registry")
    local filesystem = service.getService("filesystem")
    local descriptor = {
        name=entry.name,
        label=entry.name,
        path=entry.path,
        size=entry.size,
        isDir=entry.isDir,
        kind=entry.isDir and "folder" or "file",
        icon_path=entry.isDir and FOLDER_ICON_PATH or FILE_ICON_PATH,
    }

    if not entry.isDir and entry.name:lower():sub(-#SHORTCUT_EXTENSION) == SHORTCUT_EXTENSION then
        local shortcut = readShortcut(entry.path)
        if shortcut then
            descriptor.kind = "shortcut"
            descriptor.shortcut = shortcut
            descriptor.label = entry.name:sub(1, #entry.name - #SHORTCUT_EXTENSION)
            if shortcut.type == "program" then
                descriptor.icon_program = registry and registry.getProgram(shortcut.target) or nil
            elseif fs.exists(shortcut.target) and fs.isDir(shortcut.target) then
                descriptor.icon_path = FOLDER_ICON_PATH
            elseif fs.exists(shortcut.target) and filesystem then
                local target_info = filesystem.getFileInfo(shortcut.target)
                descriptor.icon_program = target_info and target_info.app_id
                    and registry and registry.getProgram(target_info.app_id) or nil
            end
        end
    elseif not entry.isDir and entry.app_id then
        descriptor.icon_program = registry and registry.getProgram(entry.app_id) or nil
    end
    return descriptor
end

local function listDesktopEntries()
    local filesystem = service.getService("filesystem")
    local entries = filesystem and filesystem.listDir(desktop_path) or {}
    local result = {}
    for _, entry in ipairs(entries or {}) do
        if entry.name:sub(1, 1) ~= "." then
            result[#result + 1] = descriptorFor(entry)
        end
    end
    return result
end

local function openItem(item)
    if not item then return false end
    if item.kind == "shortcut" and item.shortcut then
        if item.shortcut.type == "program" then
            return launchProgram(item.shortcut.target, item.shortcut.args)
        end
        return openPath(item.shortcut.target)
    end
    return openPath(item.path)
end

local function renderItemVisual(record)
    if not record or not record.frame then return end
    local background = (record.hovered or record.selected)
        and theme("surface") or false
    record.frame:setBackground(background)
    local icon_background = background or theme("desktop_bg")
    if record.item.icon_program then
        icon.update(record.image, record.item.icon_program,
            theme("icon_fg"), icon_background, false, "main")
    else
        icon.updatePath(record.image, record.item.icon_path or FILE_ICON_PATH,
            theme("icon_fg"), icon_background)
    end
end

local function selectItem(name)
    selected_name = name
    for item_name, record in pairs(desktop_items) do
        record.selected = item_name == name
        renderItemVisual(record)
    end
end

local function selectedItem()
    local record = selected_name and desktop_items[selected_name] or nil
    return record and record.item or nil
end

local function clampItem(frame)
    if not workspace then return end
    local max_x = math.max(1, workspace:getWidth() - frame:getWidth() + 1)
    local max_y = math.max(1, workspace:getHeight() - frame:getHeight() + 1)
    frame:setPosition(
        math.max(1, math.min(max_x, frame:getX())),
        math.max(1, math.min(max_y, frame:getY()))
    )
end

local function createFolder()
    local dialog = service.getService("dialog")
    local filesystem = service.getService("filesystem")
    if not dialog or not filesystem then return end
    dialog.prompt("New Folder", "Folder name:", "New Folder", function(value)
        if value == nil then return end
        local valid, name = validName(value)
        if not valid then notifyError("Enter a single folder name"); return end
        local ok, err = filesystem.makeDir(fs.combine(desktop_path, name))
        if not ok then notifyError(err) end
    end)
end

local function createFile()
    local dialog = service.getService("dialog")
    local filesystem = service.getService("filesystem")
    if not dialog or not filesystem then return end
    dialog.prompt("New File", "File name:", "New File.txt", function(value)
        if value == nil then return end
        local valid, name = validName(value)
        if not valid then notifyError("Enter a single file name"); return end
        local ok, err = filesystem.createFile(fs.combine(desktop_path, name), "")
        if not ok then notifyError(err) end
    end)
end

local function createShortcut()
    local dialog = service.getService("dialog")
    local registry = service.getService("registry")
    if not dialog then return end
    dialog.prompt("New Shortcut", "App ID or file/folder path:", "", function(target_value)
        if target_value == nil then return end
        local target = trim(target_value)
        local program = registry and registry.getProgram(target) or nil
        local shortcut_type
        local suggested_name
        if program then
            shortcut_type = "program"
            suggested_name = program.name or program.id
        elseif target ~= "" and fs.exists(target) then
            shortcut_type = "path"
            suggested_name = fs.getName(target)
        else
            notifyError("No application or path found: " .. target)
            return
        end

        dialog.prompt("Shortcut Name", "Display name:", suggested_name, function(name_value)
            if name_value == nil then return end
            local valid, name = validName(name_value)
            if not valid then notifyError("Enter a single shortcut name"); return end
            name = name:gsub("%.shortcut$", "")
            local ok, err = writeShortcut(uniquePath(name, SHORTCUT_EXTENSION), {
                type=shortcut_type,
                target=program and program.id or target,
            }, true)
            if not ok then notifyError(err) end
        end)
    end)
end

local function renameItem(item)
    local dialog = service.getService("dialog")
    local filesystem = service.getService("filesystem")
    if not dialog or not filesystem or not item then return end
    dialog.prompt("Rename", "New name:", item.label, function(value)
        if value == nil then return end
        local valid, name = validName(value)
        if not valid then notifyError("Enter a single name"); return end
        if item.kind == "shortcut" then name = name:gsub("%.shortcut$", "") .. SHORTCUT_EXTENSION end
        if name == item.name then return end
        local destination = fs.combine(desktop_path, name)
        local ok, err = filesystem.move(item.path, destination)
        if not ok then notifyError(err); return end
        layout[name] = layout[item.name]
        layout[item.name] = nil
        saveLayout()
    end)
end

local function deleteItem(item)
    local dialog = service.getService("dialog")
    local filesystem = service.getService("filesystem")
    if not dialog or not filesystem or not item then return end
    dialog.confirm("Delete", "Delete '" .. item.label .. "'?", function(confirmed)
        if not confirmed then return end
        local ok, err = filesystem.delete(item.path)
        if not ok then notifyError(err); return end
        layout[item.name] = nil
        saveLayout()
    end)
end

local function copyItem(item)
    local fileops = service.getService("fileops")
    if not fileops or not item then return false end
    local ok, err = fileops.copy(item.path)
    if not ok then notifyError(err or "Could not copy item"); return false end
    notify("'" .. item.label .. "' ready to copy")
    return true
end

local function cutItem(item)
    local fileops = service.getService("fileops")
    if not fileops or not item then return false end
    local source_dir = fs.getDir(item.path)
    if fs.isReadOnly and fs.isReadOnly(source_dir) then return false end
    local ok, err = fileops.cut(item.path)
    if not ok then notifyError(err or "Could not cut item"); return false end
    notify("'" .. item.label .. "' ready to move")
    return true
end

local function pasteInto(path)
    local fileops = service.getService("fileops")
    if not fileops or not fileops.canPaste(path) then
        notifyError("There are no files that can be pasted here")
        return false
    end
    local ok, result = fileops.paste(path)
    if not ok then notifyError(result or "Could not paste item"); return false end
    requestRefresh()
    notify(result.operation == "cut" and "Moved" or "Copied", "success")
    return true
end

local function showProperties(item)
    local dialog = service.getService("dialog")
    if not dialog or not item then return end
    local kind = item.kind == "shortcut" and "Shortcut"
        or (item.isDir and "Folder" or "File")
    local details = "Name: " .. item.label
        .. "\nType: " .. kind
        .. "\nPath: " .. item.path
    if item.shortcut then details = details .. "\nTarget: " .. item.shortcut.target end
    dialog.alert("Properties", details)
end

local function fileActionPath(item)
    if not item then return nil end
    if item.kind == "file" then return item.path end
    if item.kind == "shortcut" and item.shortcut
        and item.shortcut.type == "path"
        and fs.exists(item.shortcut.target)
        and not fs.isDir(item.shortcut.target) then
        return item.shortcut.target
    end
    return nil
end

local function executeItemFileAction(path, action)
    local filesystem = service.getService("filesystem")
    if not filesystem then return end
    local ok, err = filesystem.executeFileAction(path, action.id)
    if not ok then notifyError(err or ("Could not " .. tostring(action.label))) end
end

local function openItemMenu(source, x, y, item)
    local contextmenu = service.getService("contextmenu")
    if not contextmenu then return end
    local items = {}
    local action_path = fileActionPath(item)
    local filesystem = service.getService("filesystem")
    if action_path and filesystem then
        for _, action in ipairs(filesystem.getFileActions(action_path)) do
            local captured = action
            items[#items + 1] = {
                label=captured.label,
                action=function() executeItemFileAction(action_path, captured) end,
            }
        end
    else
        items[#items + 1] = {label="Open", action=function() openItem(item) end}
    end
    items[#items + 1] = {separator=true}
    local fileops = service.getService("fileops")
    items[#items + 1] = {
        label="Copy",
        disabled=not fileops,
        action=function() copyItem(item) end,
    }
    items[#items + 1] = {
        label="Cut",
        disabled=not fileops,
        action=function() cutItem(item) end,
    }
    if item.isDir then
        items[#items + 1] = {
            label="Paste into Folder",
            disabled=not fileops or not fileops.canPaste(item.path),
            action=function() pasteInto(item.path) end,
        }
    end
    items[#items + 1] = {separator=true}
    items[#items + 1] = {label="Rename", action=function() renameItem(item) end}
    items[#items + 1] = {label="Delete", action=function() deleteItem(item) end}
    items[#items + 1] = {separator=true}
    items[#items + 1] = {label="Copy Path", action=function()
            local clipboard = service.getService("clipboard")
            if clipboard then clipboard.set(item.path) end
        end}
    items[#items + 1] = {label="Properties", action=function() showProperties(item) end}
    contextmenu.openFor(source, x, y, items)
end

local function resetLayout()
    layout = {}
    saveLayout()
    requestRefresh()
end

local function openDesktopMenu(source, x, y)
    local contextmenu = service.getService("contextmenu")
    if not contextmenu then return end
    local fileops = service.getService("fileops")
    contextmenu.openFor(source, x, y, {
        {label="New Folder", action=createFolder},
        {label="New File", action=createFile},
        {label="New Shortcut", action=createShortcut},
        {separator=true},
        {
            label="Paste",
            disabled=not fileops or not fileops.canPaste(desktop_path),
            action=function() pasteInto(desktop_path) end,
        },
        {separator=true},
        {label="Arrange Icons", action=resetLayout},
        {label="Refresh", action=requestRefresh},
        {separator=true},
        {label="App Launcher", action=function() launchProgram("launcher") end},
        {label="File Manager", action=function() launchProgram("filely", {desktop_path}) end},
        {label="Terminal", action=function() launchProgram("basaltterminal") end},
        {label="Settings", action=function() launchProgram("settings") end},
    })
end

local function pathTouchesDesktop(path)
    return type(path) == "string" and desktop_path
        and (path == desktop_path or fs.getDir(path) == desktop_path)
end

function api.public.init()
    local ui = service.getService("ui")
    if ui then ui.registerScreen("desktop", api.private.buildDesktop) end

    event.on("user.login", function(username)
        is_running = true
        current_username = username
        desktop_path = nil
        layout_file = nil
    end)

    event.on("user.logout", function()
        if desktop_drop_target then
            desktop_drop_target:destroy()
            desktop_drop_target = nil
        end
        is_running = false
        desktop_frame = nil
        workspace = nil
        current_username = nil
        desktop_path = nil
        layout_file = nil
        layout = {}
        desktop_items = {}
        refresh_pending = false
        local active_ui = service.getService("ui")
        if active_ui and active_ui.deferDispatch then
            active_ui.deferDispatch("auth.show_login")
        else
            event.dispatch("auth.show_login")
        end
    end)

    event.on("desktop.refresh", function()
        refresh_pending = false
        if desktop_frame then api.private.renderWorkspace() end
    end)

    event.on("theme.changed", function()
        if desktop_frame then
            desktop_frame:setBackground(theme("desktop_bg"))
            api.private.renderWorkspace()
        end
    end)
    event.on("desktop.settings_changed", requestRefresh)
    event.on("taskbar.work_area_changed", requestRefresh)
    event.on("term_resize", requestRefresh)

    event.on("filesystem.file_created", function(path)
        if pathTouchesDesktop(path) then requestRefresh() end
    end)
    event.on("filesystem.directory_created", function(path)
        if pathTouchesDesktop(path) then requestRefresh() end
    end)
    event.on("filesystem.file_deleted", function(path)
        if pathTouchesDesktop(path) then requestRefresh() end
    end)
    event.on("filesystem.file_copied", function(_, destination)
        if pathTouchesDesktop(destination) then requestRefresh() end
    end)
    event.on("filesystem.file_moved", function(source, destination)
        if pathTouchesDesktop(source) or pathTouchesDesktop(destination) then requestRefresh() end
    end)
    event.on("filesystem.association_changed", requestRefresh)
    event.on("filesystem.associations_reset", requestRefresh)
    event.on("filesystem.associations_pruned", requestRefresh)
end

function api.private.renderWorkspace()
    if not desktop_frame or not resolveDesktopPaths() then return false end

    if desktop_drop_target then
        desktop_drop_target:destroy()
        desktop_drop_target = nil
    end
    if workspace then workspace:destroy(); workspace = nil end
    desktop_items = {}
    selected_name = nil
    last_click_name = nil
    last_click_time = 0

    seedDesktop()
    loadLayout()

    local taskbar = service.getService("taskbar")
    local work_area = taskbar and taskbar.getWorkArea and taskbar.getWorkArea()
    if not work_area then
        local width, height = desktop_frame:getSize()
        work_area = {
            x=1, y=1, width=math.max(1, width),
            height=math.max(1, height - 2),
        }
    end
    workspace = desktop_frame:addFrame({
        x=work_area.x, y=work_area.y,
        width=work_area.width, height=work_area.height,
        background=theme("desktop_bg"), z=0,
    })

    local dragdrop = service.getService("dragdrop")
    if dragdrop then
        desktop_drop_target = dragdrop.registerTarget("desktop", {
            element=workspace,
            priority=-1000,
            resolve=function(x, y, payload)
                local sources = {}
                for _, path in ipairs(payload and payload.paths or {}) do
                    sources[path] = true
                end
                for _, record in pairs(desktop_items) do
                    local item = record.item
                    if not sources[item.path] then
                        local target_path
                        if item.isDir then
                            target_path = item.path
                        elseif item.shortcut and item.shortcut.type == "path"
                            and fs.exists(item.shortcut.target)
                            and fs.isDir(item.shortcut.target) then
                            target_path = item.shortcut.target
                        end
                        if target_path then
                            local left, top = record.frame:getPosition()
                            local width, height = record.frame:getSize()
                            if x >= left and x < left + width
                                and y >= top and y < top + height then
                                return target_path
                            end
                        end
                    end
                end
                return desktop_path
            end,
        })
    end

    local settings = service.getService("settings")
    local wallpaper_style = settings
        and settings.get("desktop.wallpaper_style", "pattern") or "pattern"
    local workspace_width, workspace_height = workspace:getSize()
    workspace:addImage({
        x=1, y=1,
        width=workspace_width, height=workspace_height,
        autoSize=false, disabled=true, z=0,
        bimg=wallpaper.generate(workspace_width, workspace_height, {
            style=wallpaper_style,
            background=theme("desktop_bg"),
            surface=theme("surface"),
            accent=theme("primary"),
        }),
    })

    workspace:onClick(function(_, button)
        if button == 1 then selectItem(nil) end
    end)
    workspace:onClickUp(function(source, button, x, y)
        if button == 2 then
            selectItem(nil)
            openDesktopMenu(source, x, y)
        end
    end)

    local show_icons = not settings or settings.get("desktop.show_desktop_icons", true) ~= false
    local entries = listDesktopEntries()
    if not show_icons then return true end

    -- Character-cell desktop icons use one canonical footprint. Variable icon
    -- sizes make labels and grid spacing look uneven on CC terminals.
    local icon_size = {
        width=icon.DESKTOP_WIDTH,
        height=icon.DESKTOP_HEIGHT,
    }
    local card_width = math.max(8, icon_size.width + 2)
    local card_height = icon_size.height + 1
    local cell_width = card_width + 1
    local cell_height = card_height + 1
    local max_x = math.max(1, workspace:getWidth() - card_width + 1)
    local max_y = math.max(1, workspace:getHeight() - card_height + 1)
    local columns = math.max(1, math.floor((max_x - 1) / cell_width) + 1)
    local rows = math.max(1, math.floor((max_y - 1) / cell_height) + 1)
    local slot_count = columns * rows
    local occupied = {}
    local valid_names = {}
    local placements = {}
    local layout_dirty = false

    local function clampIndex(value, maximum)
        return math.max(1, math.min(maximum, math.floor(tonumber(value) or 1)))
    end

    local function slotKey(column, row)
        return tostring(column) .. ":" .. tostring(row)
    end

    local function occupySlot(column, row)
        local key = slotKey(column, row)
        occupied[key] = (occupied[key] or 0) + 1
    end

    local function releaseSlot(column, row)
        if not column or not row then return end
        local key = slotKey(column, row)
        local count = occupied[key] or 0
        if count <= 1 then occupied[key] = nil else occupied[key] = count - 1 end
    end

    local function positionForSlot(column, row)
        return 1 + (column - 1) * cell_width,
            1 + (row - 1) * cell_height
    end

    local function slotForPosition(x, y)
        local column = math.floor(((tonumber(x) or 1) - 1) / cell_width + 0.5) + 1
        local row = math.floor(((tonumber(y) or 1) - 1) / cell_height + 0.5) + 1
        return clampIndex(column, columns), clampIndex(row, rows)
    end

    local function slotForSavedPosition(saved)
        if tonumber(saved.column) and tonumber(saved.row) then
            return clampIndex(saved.column, columns), clampIndex(saved.row, rows)
        end
        return slotForPosition(saved.x, saved.y)
    end

    local function findNearestFree(preferred_column, preferred_row)
        local best_column, best_row, best_distance, best_order
        for column = 1, columns do
            for row = 1, rows do
                if not occupied[slotKey(column, row)] then
                    local distance = math.abs(column - preferred_column)
                        + math.abs(row - preferred_row)
                    local order = (column - 1) * rows + row
                    if not best_distance or distance < best_distance
                        or (distance == best_distance and order < best_order) then
                        best_column, best_row = column, row
                        best_distance, best_order = distance, order
                    end
                end
            end
        end
        return best_column, best_row
    end

    local function firstFreeSlot()
        for column = 1, columns do
            for row = 1, rows do
                if not occupied[slotKey(column, row)] then return column, row end
            end
        end
        return nil, nil
    end

    local function fallbackSlot(index)
        local slot = (index - 1) % slot_count
        return math.floor(slot / rows) + 1, (slot % rows) + 1
    end

    local function placeItem(item, column, row)
        occupySlot(column, row)
        local x, y = positionForSlot(column, row)
        placements[item.name] = {x=x, y=y, column=column, row=row}
        local saved = layout[item.name]
        if type(saved) ~= "table" or tonumber(saved.x) ~= x or tonumber(saved.y) ~= y
            or tonumber(saved.column) ~= column or tonumber(saved.row) ~= row then
            layout_dirty = true
        end
        layout[item.name] = {x=x, y=y, column=column, row=row}
    end

    for _, item in ipairs(entries) do
        valid_names[item.name] = true
    end
    for name in pairs(layout) do
        if not valid_names[name] then layout[name] = nil; layout_dirty = true end
    end

    -- Existing positions get first choice. This migrates old freely placed
    -- coordinates to their nearest grid slot without letting icons overlap.
    for _, item in ipairs(entries) do
        local saved = layout[item.name]
        if type(saved) == "table" then
            local preferred_column, preferred_row = slotForSavedPosition(saved)
            local column, row = findNearestFree(preferred_column, preferred_row)
            if not column then column, row = preferred_column, preferred_row end
            placeItem(item, column, row)
        end
    end

    -- New entries fill the desktop top-to-bottom, then left-to-right.
    for index, item in ipairs(entries) do
        if not placements[item.name] then
            local column, row = firstFreeSlot()
            if not column then column, row = fallbackSlot(index) end
            placeItem(item, column, row)
        end
    end

    for _, item in ipairs(entries) do
        local placement = placements[item.name]
        local x, y = placement.x, placement.y

        local frame = workspace:addFrame({
            x=x, y=y, width=card_width, height=card_height,
            background=false, z=1,
            draggable=true,
            draggingMap={{x=1, y=1, width="full", height="full"}},
        })
        frame:setStateStyle("pressed", {background=theme("surface")})

        local image_properties = {
            x=math.floor((card_width - icon_size.width) / 2) + 1,
            y=1, width=icon_size.width, height=icon_size.height,
            iconForeground=theme("icon_fg"),
            iconBackground=theme("desktop_bg"),
            variant="main",
        }
        local image
        if item.icon_program then image = icon.add(frame, item.icon_program, image_properties)
        else image = icon.addPath(frame, item.icon_path or FILE_ICON_PATH, image_properties) end

        local label = fitText(item.label, card_width)
        local label_element = frame:addLabel({
            x=math.max(1, math.floor((card_width - #label) / 2) + 1),
            y=card_height, text=label,
            foreground=theme("desktop_fg"), background=false, disabled=true,
        })

        local record = {
            item=item, frame=frame, image=image,
            selected=false, hovered=false, dragged=false, drag_started=false,
            column=placement.column, row=placement.row,
        }
        desktop_items[item.name] = record

        local function setHover(hovered)
            record.hovered = hovered
            renderItemVisual(record)
        end
        for _, source in ipairs({frame, image, label_element}) do
            source:onMouseEnter(function() setHover(true) end)
            source:onMouseLeave(function() setHover(false) end)
        end

        frame:onClick(function(self, button)
            if button == 1 or button == 2 then
                record.dragged = false
                record.drag_started = false
                selectItem(item.name)
                self:toFront()
            end
        end)
        frame:onDrag(function(self, button)
            if button == 1 then
                record.dragged = true
                if not record.drag_started then
                    record.drag_started = true
                    local active_dragdrop = service.getService("dragdrop")
                    if active_dragdrop and not active_dragdrop.isDragging() then
                        active_dragdrop.beginFiles(item.path, {
                            label=item.label,
                            source_id="desktop",
                        })
                    end
                end
            end
            clampItem(self)
        end)
        frame:onClickUp(function(self, button, mouse_x, mouse_y)
            clampItem(self)
            record.drag_started = false
            if record.dragged then
                local drag_x, drag_y = self:getPosition()
                local preferred_column, preferred_row = slotForPosition(drag_x, drag_y)
                local old_column, old_row = record.column, record.row
                releaseSlot(old_column, old_row)
                local new_column, new_row = findNearestFree(preferred_column, preferred_row)
                if not new_column then new_column, new_row = old_column, old_row end
                occupySlot(new_column, new_row)

                local new_x, new_y = positionForSlot(new_column, new_row)
                self:setPosition(new_x, new_y)
                record.column, record.row = new_column, new_row
                layout[item.name] = {
                    x=new_x, y=new_y, column=new_column, row=new_row,
                }
                saveLayout()
                last_click_name, last_click_time = nil, 0
                record.dragged = false
                return
            end
            if button == 2 then
                openItemMenu(self, mouse_x, mouse_y, item)
                return
            end
            if button ~= 1 then return end
            local now = os.clock()
            if last_click_name == item.name and now - last_click_time <= DOUBLE_CLICK_TIME then
                last_click_name, last_click_time = nil, 0
                openItem(item)
            else
                last_click_name, last_click_time = item.name, now
            end
        end)
    end

    if layout_dirty then saveLayout() end
    return true
end

function api.private.buildDesktop(frame, username)
    desktop_frame = frame
    current_username = username or current_username or "User"
    ctrl_down = false
    frame:setBackground(theme("desktop_bg"))
    frame:onKey(function(_, key)
        if key == keys.leftCtrl or key == keys.rightCtrl then
            ctrl_down = true
            return
        end
        if not ctrl_down then return end
        local item = selectedItem()
        if key == keys.c and item then
            copyItem(item)
        elseif key == keys.x and item then
            cutItem(item)
        elseif key == keys.v then
            local fileops = service.getService("fileops")
            if fileops and fileops.canPaste(desktop_path) then pasteInto(desktop_path) end
        end
    end)
    frame:on("keyUp", function(_, key)
        if key == keys.leftCtrl or key == keys.rightCtrl then ctrl_down = false end
    end)
    resolveDesktopPaths()
    api.private.renderWorkspace()
    event.dispatch("desktop.created", current_username)
    return frame
end

function api.public.refresh()
    requestRefresh()
    return true
end

function api.public.getPath()
    return desktop_path
end

function api.public.isRunning()
    return is_running
end

return api
