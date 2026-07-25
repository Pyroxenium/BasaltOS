-- /services/arg_collector.lua
-- Themed native Dialog form for collecting missing program arguments.
-- Supports: text, file, fixed and select with nested option arguments.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")

local api = api_factory.new()

local DIALOG_MAX_WIDTH = 42
local active_forms = {}
local next_form_id = 1

local function theme(key, fallback)
    return config.get("theme." .. key, fallback)
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function flattenArgs(arg_defs, state)
    local result = {}
    for _, def in ipairs(arg_defs or {}) do
        if def.type == "fixed" then
            result[#result + 1] = def.value
        elseif def.type == "text" or def.type == "file" then
            result[#result + 1] = state[def.name] or ""
        elseif def.type == "select" then
            local value = state[def.name] or ""
            result[#result + 1] = value
            for _, option in ipairs(def.options or {}) do
                if option.value == value and option.args then
                    for _, nested in ipairs(flattenArgs(option.args, state)) do
                        result[#result + 1] = nested
                    end
                    break
                end
            end
        end
    end
    return result
end

local function countRows(arg_defs)
    local height = 0
    for _, def in ipairs(arg_defs or {}) do
        if def.type == "text" or def.type == "file" then
            height = height + 3
        elseif def.type == "select" then
            height = height + 3
            local largest_branch = 0
            for _, option in ipairs(def.options or {}) do
                largest_branch = math.max(largest_branch, countRows(option.args))
            end
            height = height + largest_branch
        end
    end
    return height
end

local function validateArgs(arg_defs, state)
    for _, def in ipairs(arg_defs or {}) do
        if def.type == "text" or def.type == "file" then
            if def.required and trim(state[def.name]) == "" then
                return false, def.label or def.name
            end
        elseif def.type == "select" then
            local value = state[def.name]
            if def.required and trim(value) == "" then
                return false, def.label or def.name
            end
            for _, option in ipairs(def.options or {}) do
                if option.value == value then
                    local valid, missing = validateArgs(option.args, state)
                    if not valid then return false, missing end
                    break
                end
            end
        end
    end
    return true
end

local function styleButton(button, primary)
    if primary then
        button:setBackground(theme("primary", colors.blue))
        button:setForeground(theme("text", colors.white))
        button:setStateStyle("hover", {
            background=theme("btn_clicked", colors.cyan),
            foreground=theme("text", colors.white),
        })
    else
        button:setBackground(theme("surface", colors.lightGray))
        button:setForeground(theme("text_on_light", colors.black))
        button:setStateStyle("hover", {
            background=theme("border", colors.gray),
            foreground=theme("desktop_fg", colors.black),
        })
    end
    button:setStateStyle("pressed", {
        background=theme("btn_clicked", colors.cyan),
        foreground=theme("text", colors.white),
    })
    return button
end

local function defaultBrowserPath(def)
    if def.startPath and def.startPath ~= "" then return def.startPath end
    local userfs = service.getService("userfs")
    local user_dir = userfs and userfs.getUserDir and userfs.getUserDir()
    if user_dir and user_dir ~= "" then
        local documents = fs.combine(user_dir, "documents")
        if fs.exists(documents) and fs.isDir(documents) then return documents end
        return user_dir
    end
    return "/"
end

local function browserOptions(def, current, title)
    current = trim(current)
    local options = {
        title=title or def.label or "Select File",
        startPath=defaultBrowserPath(def),
        extensions=def.extensions,
        defaultExtension=def.defaultExtension,
    }

    if current ~= "" then
        if fs.exists(current) then
            options.startPath = current
        else
            local parent = fs.getDir(current)
            if parent ~= "" and fs.exists(parent) and fs.isDir(parent) then
                options.startPath = parent
                options.defaultName = fs.getName(current)
            end
        end
    elseif def.defaultName then
        options.defaultName = def.defaultName
    end
    return options
end

local function browseFile(dialogs, def, current, title, callback)
    local options = browserOptions(def, current, title)
    if def.allowCreate or def.pickerMode == "save" then
        options.confirmOverwrite = false
        options.actionLabel = def.actionLabel or "Select"
        return dialogs.saveFile(options, callback)
    end
    return dialogs.openFile(options, callback)
end

local function buildForm(parent, arg_defs, state, context, start_y)
    local y = start_y or 1
    local width = math.max(6, parent:getWidth() - 1)

    for _, def in ipairs(arg_defs or {}) do
        if def.type == "text" or def.type == "file" then
            if state[def.name] == nil then state[def.name] = def.default or "" end
            parent:addLabel({
                x=1, y=y, width=width, height=1,
                text=(def.label or def.name) .. (def.required and " *" or ""),
                foreground=theme("desktop_fg", colors.black),
                background=theme("desktop_bg", colors.white),
                disabled=true,
            })
            y = y + 1

            local is_file = def.type == "file"
            local input_width = is_file and math.max(1, width - 4) or width
            local input = parent:addInput({
                x=1, y=y, width=input_width, height=1,
                text=tostring(state[def.name] or ""),
                placeholder=tostring(def.description or ""),
                foreground=theme("text_on_light", colors.black),
                background=theme("surface", colors.lightGray),
            })
            local name = def.name
            input:onChange(function(_, value)
                state[name] = value
                context.clearStatus()
            end)
            input:onEnter(context.submit)
            if is_file then
                styleButton(parent:addButton({
                    x=width - 2, y=y, width=3, height=1, text="...",
                }), false):onClick(function()
                    context.browseFile(def, state[name], function(path)
                        if not path then return end
                        state[name] = path
                        input:setText(path)
                        context.clearStatus()
                        input:focus()
                    end)
                end)
            end
            if not context.first_control then context.first_control = input end
            y = y + 2

        elseif def.type == "select" then
            local options = def.options or {}
            if state[def.name] == nil then
                state[def.name] = options[1] and options[1].value or ""
            end
            parent:addLabel({
                x=1, y=y, width=width, height=1,
                text=(def.label or def.name) .. (def.required and " *" or ""),
                foreground=theme("desktop_fg", colors.black),
                background=theme("desktop_bg", colors.white),
                disabled=true,
            })
            y = y + 1

            local dropdown = parent:addDropdown({
                x=1, y=y, z=1000, width=width,
                text="Select...",
                foreground=theme("text_on_light", colors.black),
                background=theme("surface", colors.lightGray),
                dropBackground=theme("menu_bg", colors.black),
                selectionForeground=theme("text", colors.white),
                selectionBackground=theme("primary", colors.blue),
                dropHeight=math.min(5, math.max(1, #options)),
            })
            local selected_index = 1
            for index, option in ipairs(options) do
                dropdown:addItem({text=tostring(option.label or option.value)})
                if option.value == state[def.name] then selected_index = index end
            end
            if #options > 0 then dropdown:selectItem(selected_index, false) end

            local name = def.name
            dropdown:onSelect(function(_, index)
                local option = options[index]
                if not option then return end
                state[name] = option.value
                context.clearStatus()
                context.requestRebuild()
            end)
            if not context.first_control then context.first_control = dropdown end
            y = y + 2

            local selected = state[def.name]
            for _, option in ipairs(options) do
                if option.value == selected and option.args then
                    y = buildForm(parent, option.args, state, context, y)
                    break
                end
            end
        end
    end
    return y
end

local function requestRebuild(form_id)
    local record = active_forms[form_id]
    if not record or record.rebuild_pending then return end
    record.rebuild_pending = true
    local ui = service.getService("ui")
    if ui and ui.deferDispatch then
        ui.deferDispatch("arg_collector.rebuild", form_id)
    else
        os.queueEvent("arg_collector.rebuild", form_id)
    end
end

function api.public.init()
    event.on("arg_collector.rebuild", function(form_id)
        local record = active_forms[form_id]
        if not record then return end
        record.rebuild_pending = false
        record.rebuild()
    end)
    event.on("user.logout", function() active_forms = {} end)
    log.info("ARG_COLLECTOR", "Native themed argument dialog initialized")
end

-- Shows a modal form. callback receives flattened args or nil when cancelled.
-- Non-empty provided args continue to bypass collection as before.
function api.public.collect(program, provided, callback)
    local arg_defs = program.args
    if not arg_defs or #arg_defs == 0 then callback(provided or {}); return end
    if provided and #provided > 0 then callback(provided); return end

    local dialogs = service.getService("dialog")
    if not dialogs or not dialogs.custom or not dialogs.openFile or not dialogs.saveFile then
        log.error("ARG_COLLECTOR", "Modern dialog service unavailable")
        callback(nil)
        return
    end

    if #arg_defs == 1 and arg_defs[1].type == "file" then
        local def = arg_defs[1]
        local current = def.default or ""
        return browseFile(
            dialogs,
            def,
            current,
            "Open " .. tostring(program.name or program.id or "Application"),
            function(path)
                if path then callback({path}) else callback(nil) end
            end
        )
    end

    local screen_width, screen_height = term.getSize()
    local width = math.max(24, math.min(DIALOG_MAX_WIDTH, screen_width - 4))
    local height = math.max(8, math.min(countRows(arg_defs) + 5, screen_height - 3))
    local form_id = next_form_id
    next_form_id = next_form_id + 1

    local record = {state={}}
    local callback_delivered = false
    local function finishCallback(result)
        if callback_delivered then return end
        callback_delivered = true
        active_forms[form_id] = nil
        callback(result)
    end

    local controller, err = dialogs.custom(
        "Open " .. tostring(program.name or program.id or "Application"),
        width,
        height,
        function(box, custom_dialog)
            record.controller = custom_dialog
            local box_width, box_height = box:getSize()
            local form
            local status = box:addLabel({
                x=2, y=box_height - 2,
                width=math.max(1, box_width - 21), height=1,
                text="* Required",
                foreground=theme("desktop_muted", colors.gray),
                background=theme("desktop_bg", colors.white),
                disabled=true,
            })

            local function clearStatus()
                status:setText("* Required")
                status:setForeground(theme("desktop_muted", colors.gray))
            end

            local function submit()
                local valid, missing = validateArgs(arg_defs, record.state)
                if not valid then
                    status:setText("Required: " .. tostring(missing))
                    status:setForeground(theme("danger", colors.red))
                    return
                end
                custom_dialog:close(flattenArgs(arg_defs, record.state))
            end

            record.rebuild = function()
                if form then form:destroy() end
                form = box:addFrame({
                    x=2, y=2,
                    width=box_width - 2,
                    height=math.max(1, box_height - 5),
                    background=theme("desktop_bg", colors.white),
                    scrollable=true, scrollbar="auto",
                })
                local context = {
                    clearStatus=clearStatus,
                    submit=submit,
                    requestRebuild=function() requestRebuild(form_id) end,
                    browseFile=function(def, current, selected)
                        browseFile(dialogs, def, current, def.label or "Select File", selected)
                    end,
                }
                buildForm(form, arg_defs, record.state, context, 1)
                if context.first_control then context.first_control:focus() end
            end

            styleButton(box:addButton({
                x=box_width - 18, y=box_height - 1,
                width=8, height=1, text="Cancel",
            }), false):onClick(function() custom_dialog:close(nil) end)
            styleButton(box:addButton({
                x=box_width - 9, y=box_height - 1,
                width=7, height=1, text="Open",
            }), true):onClick(submit)

            active_forms[form_id] = record
            record.rebuild()
        end,
        finishCallback
    )

    if not controller and not callback_delivered then
        active_forms[form_id] = nil
        log.error("ARG_COLLECTOR", "Could not open argument dialog", {error=tostring(err)})
        finishCallback(nil)
    end
    return controller
end

return api
