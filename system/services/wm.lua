-- /services/wm.lua
-- Window Manager: Manages application windows

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local error_sys = require("core.error_sys")
local program_env = require("core.program_env")
local config = require("core.config")

local api = api_factory.new()

local function theme(key)
    return config.get("theme." .. key)
end

local windows = {}           -- window_id -> window_data
local next_window_id = 1
local focused_window = nil

local make_package = dofile("rom/modules/main/cc/require.lua").make

-- Load app API
local app_api = require("core.app_api")

-- Build custom environment for programs
-- This can be extended with additional APIs later
local function build_program_environment(pid, window_id, program_dir)
    local env = setmetatable({}, {__index = _ENV})
    return program_env.build(env, {
        pid       = pid,
        window_id = window_id,
        windows   = windows,
        wm        = api.public,
        focused   = function() return focused_window end,
    }, make_package, program_dir)
end

function api.public.init()
    event.on("process.terminated", function(pid)
        api.private.closeWindowByPid(pid)
    end)

    -- Deferred cleanup after Basalt's update cycle completes
    event.on("wm.window_done", function(pid)
        local process_service = service.getPrivateApi("process")
        if process_service then
            process_service.terminateProcess(pid)
        end
    end)
end

-- Public API: Create a window for a process
-- @param pid: Process ID
-- @param program: Program metadata from registry
-- @param executable_path: Path to the program to execute
-- @param args: Arguments to pass to the program
-- @return window_id
function api.public.createWindow(pid, program, executable_path, args)
    log.debug("WM", "createWindow called", {pid = pid, program = program.name, executable = executable_path})

    if program.singleton then
        local process_service = service.getService("process")
        if process_service then
            local existing = process_service.findProcessByProgram(program.id)
            if existing and existing.window_id then
                log.info("WM", "Singleton app already running, focusing existing window", {
                    program_id = program.id,
                    existing_pid = existing.pid,
                    window_id = existing.window_id
                })
                api.public.focusWindow(existing.window_id)

                process_service.terminateProcess(pid)
                return existing.window_id, nil
            end
        end
    end

    local ui = service.getService("ui")
    if not ui then
        log.error("WM", "UI service not available")
        return nil, "UI service not available"
    end

    local window_id = next_window_id
    next_window_id = next_window_id + 1

    local window_config = program.window or {}
    local fullscreen = window_config.fullscreen or false
    local auto_close = window_config.auto_close ~= true  -- default true; set to false to keep window open on exit
    local width = window_config.default_width or 30
    local height = window_config.default_height or 15

    log.debug("WM", "Window config", {fullscreen = fullscreen, width = width, height = height})

    local program_dir = fs.getDir(executable_path)
    log.debug("WM", "Program directory", {dir = program_dir})

    local program_env = build_program_environment(pid, window_id, program_dir)

    local window = {
        id = window_id,
        pid = pid,
        title = program.name,
        fullscreen = fullscreen,
        width = width,
        height = height,
        resizable = window_config.resizable ~= false,
        min_width = window_config.min_width or 10,
        min_height = window_config.min_height or 5,
        frame = nil,
        program_element = nil
    }

    windows[window_id] = window

    local desktop_frame = ui.getScreen("desktop")
    local main_frame = ui.getMainFrame()

    if desktop_frame and main_frame then
        if fullscreen then
            -- Fullscreen: attach to main_frame so it covers taskbar, notifications, everything
            local screen_w, screen_h = main_frame:getSize()
            local fs_start_x = math.floor(screen_w / 2)
            local fs_start_y = math.floor(screen_h / 2)

            window.frame = main_frame:addFrame({
                x = fs_start_x,
                y = fs_start_y,
                width = 2,
                height = 2,
                background = colors.black
            })

            -- Program fills all but the bottom control bar
            window.program_element = window.frame:addProgram({
                x = 1,
                y = 1,
                width = screen_w,
                height = screen_h - 1,
                background = colors.black
            })

            -- Control bar at bottom
            window.frame:addVisualElement({
                x = 1,
                y = "{parent.height}",
                width = "{parent.width}",
                height = 1,
                background = theme("secondary")
            })
            window.frame:addLabel({
                x = 2,
                y = "{parent.height}",
                text = window.title,
                foreground = theme("text"),
                background = theme("secondary")
            })
            window.frame:addButton({
                x = "{parent.width - 17}",
                y = "{parent.height}",
                width = 10,
                height = 1,
                text = "Minimize",
                foreground = theme("text"),
                background = theme("warning")
            }):onClick(function()
                api.public.minimizeWindow(window_id)
            end)
            window.frame:addButton({
                x = "{parent.width - 6}",
                y = "{parent.height}",
                width = 7,
                height = 1,
                text = "Close",
                foreground = theme("text"),
                background = theme("danger")
            }):onClick(function()
                api.public.closeWindow(window_id)
            end)

            window.frame:prioritize()

            window.frame:animate()
                :move(1, 1, 0.15, "easeOutQuad")
                :resize(screen_w, screen_h, 0.15, "easeOutQuad")
                :onComplete(function()
                    window.frame:setPosition(1, 1)
                    window.frame:setSize("{parent.width}", "{parent.height}")
                    window.program_element:setSize("{parent.width}", "{parent.height - 1}")
                end)
                :start()
        else
            -- Windowed: attach to desktop_frame
            local target_x = window.x or 3
            local target_y = window.y or 3
            local final_width = width
            local final_height = height + 1
            local start_x = math.floor(target_x + final_width / 2) - 1
            local start_y = math.floor(target_y + final_height / 2) - 1

            window.frame = desktop_frame:addFrame({
                x = start_x,
                y = start_y,
                width = 2,
                height = 2,
                draggable = true,
                background = colors.black
            })
            :addBorder(theme("border"), {bottom=true, right=true, left=true})

            window.frame:addVisualElement({
                x = 1,
                y = 1,
                width = "{parent.width}",
                height = 1,
                background = theme("secondary")
            }):setName("titlebar_bg")
            window.frame:addLabel({
                x = 2,
                y = 1,
                text = window.title,
                foreground = theme("text"),
                background = theme("secondary")
            }):setName("titlebar_label")
            window.frame:addButton({
                x = "{parent.width}",
                y = 1,
                width = 1,
                height = 1,
                text = "X",
                foreground = theme("text"),
                background = theme("danger")
            }):onClick(function()
                api.public.closeWindow(window_id)
            end)
            window.frame:addButton({
                x = "{parent.width - 1}",
                y = 1,
                width = 1,
                height = 1,
                text = "_",
                foreground = theme("text"),
                background = theme("warning")
            }):onClick(function()
                api.public.minimizeWindow(window_id)
            end)

            window.program_element = window.frame:addProgram({
                x = 2,
                y = 2,
                width = width - 2,
                height = height - 1,
                background = colors.black
            })

            window.frame:setDraggingMap({{x=1, y=1, width=width-2, height=1}})
            window.frame:onFocus(function(self)
                self:prioritize()
                api.private.setTitlebarColor(window, theme("window_focused"))
                api.public.focusWindow(window_id)
            end)
            window.frame:onBlur(function(self)
                api.private.setTitlebarColor(window, theme("secondary"))
            end)

            window.frame:animate()
                :move(target_x, target_y, 0.15, "easeOutQuad")
                :resize(final_width, final_height, 0.15, "easeOutQuad")
                :onComplete(function()
                    window.program_element:setSize("{parent.width-2}", "{parent.height - 2}")
                end)
                :start()
        end

        window.program_element:onDone(function(prog, success, result)
            log.info("WM", "Program completed", {pid = pid, success = success})
            -- When success=false, onError fires right after this – let onError handle cleanup
            if not success then return end
            if not auto_close then return end
            -- Defer cleanup: frame:destroy() inside basalt.update() corrupts Basalt state
            local ui = service.getService("ui")
            if ui then
                ui.deferDispatch("wm.window_done", pid)
            end
        end)

        window.program_element:onError(function(prog, error_msg, trace)
            log.error("WM", "Program error", {pid = pid, error = error_msg, trace = trace})
            local app_name = windows[window_id] and windows[window_id].title or "unknown"
            error_sys.logAppCrash(app_name, pid, error_msg, trace)

            local short_err = tostring(error_msg):gsub("^.*%.lua:%d+: ", "")
            local ui = service.getService("ui")
            if ui then
                ui.deferDispatch("wm.window_done", pid)
                ui.deferDispatch("wm.app_crashed", app_name, short_err)
            end

            -- Return false: prevents Basalt from calling errorManager.error() which would crash the OS
            return false
        end)

        log.info("WM", "Executing program", {executable = executable_path, args = args})
        window.program_element:execute(executable_path, program_env, true, table.unpack(args or {}))
        log.info("WM", "Program execution started")
    else
        log.error("WM", "Desktop frame or main frame is nil!")
    end

    event.dispatch("wm.window_created", window_id, pid)

    api.public.focusWindow(window_id)

    log.info("WM", "Window created successfully", {window_id = window_id, pid = pid})

    return window_id
end

function api.public.closeWindow(window_id)
    local window = windows[window_id]

    if not window then
        return false, "Window not found"
    end

    if window.frame then
        window.frame:destroy()
    end

    windows[window_id] = nil

    event.dispatch("wm.window_closed", window_id, window.pid)

    return true
end

function api.private.closeWindowByPid(pid)
    for window_id, window in pairs(windows) do
        if window.pid == pid then
            api.public.closeWindow(window_id)
            return
        end
    end
end

function api.private.setTitlebarColor(window, color)
    if not window.frame or window.fullscreen then return end
    local bg = window.frame:getChild("titlebar_bg")
    local lbl = window.frame:getChild("titlebar_label")
    if bg  then bg.set("background", color) end
    if lbl then lbl.set("background", color) end
end

function api.public.focusWindow(window_id)
    local window = windows[window_id]

    if not window then
        return false, "Window not found"
    end

    focused_window = window_id

    if window.frame then
        window.frame:setVisible(true)
        window.frame:setFocused(true)
        if window.fullscreen then
            window.frame:prioritize()
        end
    end

    event.dispatch("wm.window_focused", window_id)

    return true
end

function api.public.getWindow(window_id)
    return windows[window_id]
end

function api.public.listWindows()
    local list = {}
    for id, window in pairs(windows) do
        table.insert(list, window)
    end
    return list
end

function api.public.getFocusedWindow()
    return focused_window
end

function api.public.minimizeWindow(window_id)
    local window = windows[window_id]

    if not window then
        return false, "Window not found"
    end

    if window.frame then
        window.frame:setVisible(false)
    end

    event.dispatch("wm.window_minimized", window_id)

    return true
end

function api.public.restoreWindow(window_id)
    local window = windows[window_id]

    if not window then
        return false, "Window not found"
    end

    if window.frame then
        window.frame:setVisible(true)
    end

    api.public.focusWindow(window_id)

    event.dispatch("wm.window_restored", window_id)
    return true
end

function api.public.resizeWindow(window_id, width, height)
    local window = windows[window_id]

    if not window then
        return false, "Window not found"
    end

    if not window.resizable then
        return false, "Window is not resizable"
    end

    width = math.max(width, window.min_width)
    height = math.max(height, window.min_height)

    window.frame:setSize(width, height)
    event.dispatch("wm.window_resized", window_id, width, height)
    return true
end

function api.public.moveWindow(window_id, x, y)
    local window = windows[window_id]

    if not window then
        return false, "Window not found"
    end

    window.frame:setPosition(x, y)
    event.dispatch("wm.window_moved", window_id, x, y)
    return true
end

return api
