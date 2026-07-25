-- /services/dialog.lua
-- BasaltOS dialog service using Basalt 2.5's native modal Dialog container.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")
local ui_helpers = require("core.ui_helpers")

local api = api_factory.new()

local active_dialogs = {}
local next_dialog_id = 1
local desktop_frame = nil
local DIALOG_Z_BASE = 2000

local function theme(key) return config.get("theme." .. key) end

local DIALOG_TYPES = {
    alert = { marker="i", color=function() return theme("primary") end },
    confirm = { marker="?", color=function() return theme("warning") end },
    prompt = { marker=">", color=function() return theme("primary") end },
}

local function callSafely(callback, ...)
    if not callback then return end
    local ok, err = pcall(callback, ...)
    if not ok then log.error("DIALOG", "Dialog callback failed", {error=tostring(err)}) end
end

local function wrapText(value, width)
    local lines = {}
    local text = tostring(value or "")
    width = math.max(1, width)

    for raw_line in (text .. "\n"):gmatch("(.-)\n") do
        if raw_line == "" then
            lines[#lines + 1] = ""
        else
            local remaining = raw_line
            while #remaining > width do
                local split = width
                local candidate = remaining:sub(1, width)
                local last_space = candidate:match("^.*()%s+")
                if last_space and last_space > 1 then split = last_space - 1 end
                lines[#lines + 1] = remaining:sub(1, split)
                remaining = remaining:sub(split + 1):gsub("^%s+", "")
            end
            lines[#lines + 1] = remaining
        end
    end

    if #lines == 0 then lines[1] = "" end
    return lines
end

local function fitText(value, width)
    local text = tostring(value or "")
    width = math.max(0, math.floor(tonumber(width) or 0))
    if #text <= width then return text end
    if width <= 2 then return (".."):sub(1, width) end
    return text:sub(1, width - 2) .. ".."
end

local function fitTailText(value, width)
    local text = tostring(value or "")
    width = math.max(0, math.floor(tonumber(width) or 0))
    if #text <= width then return text end
    if width <= 2 then return (".."):sub(1, width) end
    return ".." .. text:sub(-(width - 2))
end

local function styleButton(button, primary)
    if primary then
        button:setBackground(theme("primary"))
        button:setForeground(theme("text"))
        button:setStateStyle("hover", {
            background=theme("btn_clicked"), foreground=theme("text"),
        })
    else
        button:setBackground(theme("surface"))
        button:setForeground(theme("text_on_light"))
        button:setStateStyle("hover", {
            background=theme("border"), foreground=theme("desktop_fg"),
        })
    end
    button:setStateStyle("pressed", {
        background=theme("btn_clicked"), foreground=theme("text"),
    })
    return button
end

local function queueCleanup(id, dialog)
    active_dialogs[id] = nil
    local ui = service.getService("ui")
    if ui then
        ui.deferDispatch("dialog.cleanup", id, dialog)
    elseif dialog then
        dialog:destroy()
    end
end

local function prioritizeDialog(id)
    local target = active_dialogs[id]
    if not target or not target.dialog then return end

    local ordered = {}
    for candidate_id, record in pairs(active_dialogs) do
        if candidate_id ~= id and record.dialog then
            ordered[#ordered + 1] = {id=candidate_id, dialog=record.dialog}
        end
    end
    table.sort(ordered, function(left, right)
        local left_z = tonumber(left.dialog.z) or DIALOG_Z_BASE
        local right_z = tonumber(right.dialog.z) or DIALOG_Z_BASE
        if left_z == right_z then return left.id < right.id end
        return left_z < right_z
    end)

    for index, entry in ipairs(ordered) do
        entry.dialog.z = DIALOG_Z_BASE + index
    end
    target.dialog.z = DIALOG_Z_BASE + #ordered + 1
end

local function newDialog()
    if not desktop_frame then return nil, nil end
    local id = next_dialog_id
    next_dialog_id = next_dialog_id + 1
    local dialog = desktop_frame:addDialog({
        background=false,
        visible=false,
        z=DIALOG_Z_BASE,
    })
    active_dialogs[id] = {dialog=dialog}
    prioritizeDialog(id)
    dialog:onClick(function()
        prioritizeDialog(id)
    end)
    dialog:onClose(function()
        if active_dialogs[id] then queueCleanup(id, dialog) end
    end)
    return id, dialog
end

local function addShadow(dialog, x, y, width, height)
    dialog:addFrame({
        x=math.min(dialog:getWidth() - width + 1, x + 1),
        y=math.min(dialog:getHeight() - height + 1, y + 1),
        width=width,
        height=height,
        background=theme("border"),
        disabled=true,
    })
end

local function addChrome(dialog, title, width, height)
    local screen_width, screen_height = desktop_frame:getSize()
    local x = math.max(1, math.floor((screen_width - width) / 2) + 1)
    local y = math.max(1, math.floor((screen_height - height) / 2) + 1)
    addShadow(dialog, x, y, width, height)

    local box = dialog:addFrame({
        x=x, y=y, width=width, height=height,
        background=theme("desktop_bg"),
    })
    ui_helpers.addBorder(box, theme("primary"), {
        innerColor=theme("desktop_bg"), topStyle="solid", name="dialog_border",
    })
    box:addFrame({
        x=1, y=1, width=width, height=1,
        background=theme("primary"), disabled=true,
    })
    box:addLabel({
        x=2, y=1, width=math.max(1, width - 5), height=1,
        text=fitText(title or "Dialog", math.max(1, width - 5)),
        foreground=theme("text"), background=theme("primary"), disabled=true,
    })
    return box
end

local function openMessageDialog(kind, title, message, default, callback)
    local id, dialog = newDialog()
    if not dialog then return nil, "Desktop is not available" end

    local screen_width, screen_height = desktop_frame:getSize()
    local box_width = math.max(16, math.min(38, screen_width - 4))
    local content_width = math.max(4, box_width - 5)
    local lines = wrapText(message, content_width)
    local extra_rows = kind == "prompt" and 2 or 0
    local max_lines = math.max(1, screen_height - 8 - extra_rows)
    if #lines > max_lines then
        while #lines > max_lines do table.remove(lines) end
        lines[#lines] = fitText(lines[#lines] .. "..", content_width)
    end

    local box_height = #lines + 5 + extra_rows
    local box = addChrome(dialog, title, box_width, box_height)
    local closed = false

    local function finish(result)
        if closed then return end
        closed = true
        dialog:close(result)
        callSafely(callback, result)
    end

    box:addButton({
        x=box_width - 1, y=1, width=1, height=1,
        text="x", background=theme("primary"), foreground=theme("text"),
    }):setStateStyle("hover", {
        background=theme("danger"), foreground=theme("text"),
    }):onClick(function()
        if kind == "alert" then finish(true)
        elseif kind == "confirm" then finish(false)
        else finish(nil) end
    end)

    local type_style = DIALOG_TYPES[kind] or DIALOG_TYPES.alert
    box:addLabel({
        x=2, y=3, text=type_style.marker,
        foreground=type_style.color(), background=theme("desktop_bg"), disabled=true,
    })
    for index, line in ipairs(lines) do
        box:addLabel({
            x=4, y=2 + index, width=content_width, height=1,
            text=line, foreground=theme("desktop_fg"),
            background=theme("desktop_bg"), disabled=true,
        })
    end

    local button_y = box_height - 1
    if kind == "alert" then
        styleButton(box:addButton({
            x=box_width - 9, y=button_y, width=7, height=1, text="OK",
        }), true):onClick(function() finish(true) end)
    elseif kind == "confirm" then
        styleButton(box:addButton({
            x=box_width - 18, y=button_y, width=8, height=1, text="Cancel",
        }), false):onClick(function() finish(false) end)
        styleButton(box:addButton({
            x=box_width - 9, y=button_y, width=7, height=1, text="Confirm",
        }), true):onClick(function() finish(true) end)
    else
        local input_y = box_height - 4
        local input = box:addInput({
            x=3, y=input_y, width=box_width - 5,
            text=tostring(default or ""),
            foreground=theme("text_on_light"), background=theme("surface"),
        })
        local function accept() finish(input.text) end
        input:onEnter(accept)
        styleButton(box:addButton({
            x=box_width - 18, y=button_y, width=8, height=1, text="Cancel",
        }), false):onClick(function() finish(nil) end)
        styleButton(box:addButton({
            x=box_width - 9, y=button_y, width=7, height=1, text="OK",
        }), true):onClick(accept)
        input:focus()
    end

    dialog:setVisible(true)
    dialog:focus()
    return dialog
end

function api.public.init()
    event.on("desktop.created", function()
        local ui = service.getService("ui")
        desktop_frame = ui and ui.getScreen("desktop") or nil
        active_dialogs = {}
        log.info("DIALOG", "Modern BasaltOS dialog service initialized")
    end)

    event.on("dialog.cleanup", function(id, dialog)
        if active_dialogs[id] then return end
        if dialog then dialog:destroy() end
    end)

    event.on("user.logout", function()
        api.public.closeAll()
        desktop_frame = nil
    end)

    event.on("wm.app_crashed", function(app_name, err_msg)
        api.public.alert(app_name .. " crashed", err_msg)
    end)

    event.on("basaltshell.ready", function()
        local shell = service.getService("basaltshell")
        if shell then
            shell.registerBuiltin("alert", function(args)
                if #args == 0 then return false, "Usage: alert <message>" end
                api.public.alert("Shell", table.concat(args, " "))
                return true, nil
            end)
        end
    end)
end

function api.public.alert(title, message, callback)
    return openMessageDialog("alert", title, message, nil, function()
        callSafely(callback)
    end)
end

function api.public.confirm(title, message, callback)
    return openMessageDialog("confirm", title, message, nil, function(result)
        callSafely(callback, result == true)
    end)
end

function api.public.prompt(title, message, default, callback)
    return openMessageDialog("prompt", title, message, default, function(result)
        callSafely(callback, result)
    end)
end

-- Creates a themed native modal with caller-defined content. The builder gets
-- the inner box and a controller with close(result), getFrame() and isOpen().
-- This keeps specialized OS forms on the same Dialog/chrome path as alerts,
-- prompts and file pickers without exposing dialog service internals.
function api.public.custom(title, width, height, builder, callback)
    if type(builder) ~= "function" then return nil, "Dialog builder must be a function" end
    if not desktop_frame then return nil, "Desktop is not available" end

    local screen_width, screen_height = desktop_frame:getSize()
    width = math.max(16, math.min(math.floor(tonumber(width) or 32), screen_width - 4))
    height = math.max(6, math.min(math.floor(tonumber(height) or 10), screen_height - 3))

    local id, dialog = newDialog()
    if not dialog then return nil, "Desktop is not available" end
    local box = addChrome(dialog, title or "Dialog", width, height)
    local closed = false
    local controller = {}

    local function finish(result)
        if closed then return false end
        closed = true
        dialog:close(result)
        callSafely(callback, result)
        return true
    end

    function controller:close(result) return finish(result) end
    function controller:getFrame() return box end
    function controller:getDialog() return dialog end
    function controller:isOpen() return not closed and active_dialogs[id] ~= nil end

    box:addButton({
        x=width - 1, y=1, width=1, height=1,
        text="x", background=theme("primary"), foreground=theme("text"),
    }):setStateStyle("hover", {
        background=theme("danger"), foreground=theme("text"),
    }):onClick(function() finish(nil) end)

    local ok, err = pcall(builder, box, controller)
    if not ok then
        log.error("DIALOG", "Custom dialog builder failed", {error=tostring(err)})
        finish(nil)
        return nil, tostring(err)
    end

    dialog:setVisible(true)
    dialog:focus()
    return controller
end

local function extensionSet(value)
    if type(value) == "string" then value = {value} end
    if type(value) ~= "table" then return nil end

    local result = {}
    for _, extension in ipairs(value) do
        extension = tostring(extension):lower():gsub("^%.", "")
        if extension ~= "" then result[extension] = true end
    end
    return next(result) and result or nil
end

local function matchesExtensions(name, extensions)
    if not extensions then return true end
    local extension = tostring(name):match("%.([^%.]+)$")
    return extension and extensions[extension:lower()] == true or false
end

local function cleanName(value)
    local name = tostring(value or ""):match("^%s*(.-)%s*$") or ""
    if name == "" then return nil, "Enter a file name" end
    if name == "." or name == ".." or name:find("[/\\]") then
        return nil, "The name cannot contain / or \\"
    end
    return name
end

local function resolveBrowserStart(options, save_mode)
    local start_path = options.startPath or options.path or "/"
    local default_name = options.defaultName or options.filename or ""
    start_path = tostring(start_path or "/")

    if start_path ~= "" and fs.exists(start_path) and not fs.isDir(start_path) then
        if default_name == "" then default_name = fs.getName(start_path) end
        start_path = fs.getDir(start_path)
    elseif save_mode and start_path ~= "" and not fs.exists(start_path) then
        local parent = fs.getDir(start_path)
        if parent ~= "" and fs.exists(parent) and fs.isDir(parent) then
            if default_name == "" then default_name = fs.getName(start_path) end
            start_path = parent
        end
    end

    if start_path == "" then start_path = "/" end
    if not fs.exists(start_path) or not fs.isDir(start_path) then start_path = "/" end
    return start_path, default_name
end

-- Public native file browser.
-- options.mode: "open" | "save" | "folder" | "all"
-- options.startPath/path: initial directory or file path
-- options.defaultName/filename: initial file name in save mode
-- options.extensions: optional list such as {"txt", "md"}
-- options.defaultExtension: appended in save mode when no extension was entered
-- options.confirmOverwrite: false disables the built-in replacement prompt
function api.public.fileBrowser(options, callback)
    options = type(options) == "table" and options or {}
    local mode = options.mode or "open"
    local save_mode = mode == "save"
    local folder_mode = mode == "folder"
    local all_mode = mode == "all"
    local extensions = extensionSet(options.extensions)
    local cwd, default_name = resolveBrowserStart(options, save_mode)

    local id, dialog = newDialog()
    if not dialog then return nil, "Desktop is not available" end

    local screen_width, screen_height = desktop_frame:getSize()
    local box_width = math.max(20, math.min(40, screen_width - 4))
    local minimum_height = save_mode and 12 or 10
    local box_height = math.max(minimum_height, math.min(save_mode and 18 or 17, screen_height - 3))
    local list_height = math.max(3, box_height - (save_mode and 8 or 6))
    local title = options.title
        or (save_mode and "Save File")
        or (folder_mode and "Select Folder")
        or "Open File"
    local box = addChrome(dialog, title, box_width, box_height)
    local path_label = box:addLabel({
        x=3, y=3, width=box_width - 10, height=1, text="",
        foreground=theme("desktop_muted"), background=theme("desktop_bg"), disabled=true,
    })
    box:addLabel({
        x=2, y=3, text=">", foreground=theme("primary"),
        background=theme("desktop_bg"), disabled=true,
    })
    local file_list = box:addList({
        x=2, y=4, width=box_width - 2, height=list_height,
        background=theme("desktop_bg"), foreground=theme("desktop_fg"),
    })
    file_list:setSelectedBackground(theme("primary"))
    file_list:setSelectedForeground(theme("text"))

    local selected_path = nil
    local entries = {}
    local closed = false
    local name_input = nil
    local loadDir
    local acceptCurrent

    local function finish(result)
        if closed then return end
        closed = true
        dialog:close(result)
        callSafely(callback, result)
    end

    box:addButton({
        x=box_width - 1, y=1, width=1, height=1,
        text="x", background=theme("primary"), foreground=theme("text"),
    }):setStateStyle("hover", {
        background=theme("danger"), foreground=theme("text"),
    }):onClick(function() finish(nil) end)

    loadDir = function(path)
        if path == "" then path = "/" end
        if not fs.exists(path) or not fs.isDir(path) then return false end
        cwd = path
        selected_path = nil
        entries = {}
        file_list:clear()

        local display = fitTailText(cwd, box_width - 10)
        path_label:setText(display)

        if cwd ~= "/" then
            entries[#entries + 1] = {
                label="..", path=fs.getDir(cwd), isDir=true, isParent=true,
            }
            file_list:addItem({text=" < ..", fg=theme("desktop_muted"), bg=theme("desktop_bg")})
        end

        local listed, contents = pcall(fs.list, cwd)
        if not listed then
            path_label:setText("Unable to read folder")
            return false
        end

        local dirs, files = {}, {}
        for _, name in ipairs(contents) do
            local full = fs.combine(cwd, name)
            if fs.isDir(full) then dirs[#dirs + 1] = name else files[#files + 1] = name end
        end
        table.sort(dirs, function(a, b) return a:lower() < b:lower() end)
        table.sort(files, function(a, b) return a:lower() < b:lower() end)

        for _, name in ipairs(dirs) do
            local full = fs.combine(cwd, name)
            entries[#entries + 1] = {label=name, path=full, isDir=true}
            file_list:addItem({text=" + " .. name, fg=theme("primary"), bg=theme("desktop_bg")})
        end
        if not folder_mode then
            for _, name in ipairs(files) do
                if matchesExtensions(name, extensions) then
                    local full = fs.combine(cwd, name)
                    entries[#entries + 1] = {label=name, path=full, isDir=false}
                    file_list:addItem({text="   " .. name, fg=theme("desktop_fg"), bg=theme("desktop_bg")})
                end
            end
        end
        return true
    end

    local function selectCurrent()
        local entry = entries[file_list:getSelectedIndex()]
        if not entry then return end
        if entry.isDir then
            if entry.isParent then selected_path = nil
            elseif folder_mode or all_mode then selected_path = entry.path
            else selected_path = nil end
        elseif not folder_mode then
            selected_path = entry.path
            if save_mode and name_input then name_input:setText(entry.label) end
        end
    end

    local function openCurrent()
        local entry = entries[file_list:getSelectedIndex()]
        if not entry then return end
        if entry.isDir then
            loadDir(entry.path)
        elseif save_mode then
            name_input:setText(entry.label)
            acceptCurrent()
        else
            finish(entry.path)
        end
    end

    file_list:onChange(selectCurrent)
    ui_helpers.onDoubleClick(file_list, openCurrent)
    file_list:onKey(function(_, key)
        if key == keys.enter then openCurrent() end
    end)

    if save_mode then
        box:addLabel({
            x=2, y=box_height - 3, width=5, height=1, text="Name",
            foreground=theme("desktop_muted"), background=theme("desktop_bg"), disabled=true,
        })
        name_input = box:addInput({
            x=7, y=box_height - 3, width=box_width - 8, height=1,
            text=default_name, foreground=theme("text_on_light"), background=theme("surface"),
        })
    end

    styleButton(box:addButton({
        x=box_width - 4, y=3, width=3, height=1, text="+",
    }), false):onClick(function()
        api.public.prompt("New Folder", "Folder name:", "", function(value)
            if value == nil then return end
            local name, err = cleanName(value)
            if not name then api.public.alert("New Folder", err) return end
            local path = fs.combine(cwd, name)
            if fs.exists(path) then
                api.public.alert("New Folder", name .. " already exists")
                return
            end
            local ok, make_err = pcall(fs.makeDir, path)
            if not ok then
                api.public.alert("New Folder", tostring(make_err))
                return
            end
            loadDir(cwd)
        end)
    end)

    acceptCurrent = function()
        if save_mode then
            local name, err = cleanName(name_input:getText())
            if not name then api.public.alert(title, err) return end
            if options.defaultExtension and not name:match("%.([^%.]+)$") then
                name = name .. "." .. tostring(options.defaultExtension):gsub("^%.", "")
                name_input:setText(name)
            end
            if extensions and not matchesExtensions(name, extensions) then
                api.public.alert(title, "Choose a supported file type")
                return
            end

            local path = fs.combine(cwd, name)
            if fs.exists(path) and fs.isDir(path) then
                api.public.alert(title, "A folder already uses that name")
                return
            end
            if fs.exists(path) and options.confirmOverwrite ~= false then
                api.public.confirm("Replace File", name .. " already exists. Replace it?", function(confirmed)
                    if confirmed then finish(path) end
                end)
            else
                finish(path)
            end
            return
        end

        if folder_mode then
            finish(selected_path or cwd)
        elseif selected_path then
            finish(selected_path)
        end
    end

    if name_input then name_input:onEnter(acceptCurrent) end

    local button_y = box_height - 1
    styleButton(box:addButton({
        x=2, y=button_y, width=8, height=1, text="Cancel",
    }), false):onClick(function() finish(nil) end)
    styleButton(box:addButton({
        x=box_width - 9, y=button_y, width=7, height=1,
        text=options.actionLabel
            or (save_mode and "Save" or (folder_mode and "Select" or "Open")),
    }), true):onClick(acceptCurrent)

    dialog:setVisible(true)
    dialog:focus()
    loadDir(cwd)
    if name_input then name_input:focus() else file_list:focus() end
    return dialog
end

function api.public.openFile(options, callback)
    if type(options) == "string" then options = {startPath=options} end
    options = options or {}
    options.mode = "open"
    return api.public.fileBrowser(options, callback)
end

function api.public.saveFile(options, callback)
    if type(options) == "string" then options = {startPath=options} end
    options = options or {}
    options.mode = "save"
    return api.public.fileBrowser(options, callback)
end

function api.public.selectFolder(options, callback)
    if type(options) == "string" then options = {startPath=options} end
    options = options or {}
    options.mode = "folder"
    return api.public.fileBrowser(options, callback)
end

-- Backwards-compatible picker API.
-- filter: "files" | "dirs" | "all" (default: "files")
function api.public.file(title, start_path, filter, callback)
    local mode = filter == "dirs" and "folder" or (filter == "all" and "all" or "open")
    return api.public.fileBrowser({
        title=title, startPath=start_path, mode=mode,
    }, callback)
end

function api.public.isActive()
    return next(active_dialogs) ~= nil
end

function api.public.getActiveCount()
    local count = 0
    for _ in pairs(active_dialogs) do count = count + 1 end
    return count
end

function api.public.closeAll()
    for _, record in pairs(active_dialogs) do
        if record.dialog then record.dialog:destroy() end
    end
    active_dialogs = {}
end

return api
