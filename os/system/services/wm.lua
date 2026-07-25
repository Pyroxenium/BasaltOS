-- /services/wm.lua
-- Window Manager: Manages application windows

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local error_sys = require("core.error_sys")
local program_env = require("core.program_env")
local config = require("core.config")
local ui_helpers = require("core.ui_helpers")

local api = api_factory.new()

local function theme(key)
    return config.get("theme." .. key)
end

local windows = {}           -- window_id -> window_data
local next_window_id = 1
local focused_window = nil
local focus_order = {}
local shortcut_controller = nil
local tab_consumed = false
local tab_cycle = {
    candidates={},
    index=1,
    last_at=0,
    switching=false,
}

local OPEN_DURATION = 0.20
local CLOSE_DURATION = 0.18
local MINIMIZE_DURATION = 0.16
local WINDOW_Z_BASE = 100
local FALLBACK_TASKBAR_HEIGHT = 2
local USER_GEOMETRY_CONFIG = "window.geometry"
local frameGeometry

local function windowSetting(key, fallback)
    local settings = service.getService("settings")
    if not settings or not settings.get then return fallback end
    return settings.get("window." .. key, fallback)
end

local function integer(value, fallback)
    value = tonumber(value)
    if not value then return fallback end
    return math.floor(value)
end

local function workspaceBounds()
    local ui = service.getService("ui")
    local desktop_frame = ui and ui.getScreen("desktop")
    if not desktop_frame then return nil end

    local taskbar = service.getService("taskbar")
    local work_area = taskbar and taskbar.getWorkArea and taskbar.getWorkArea()
    if type(work_area) == "table" then
        return {
            x=integer(work_area.x, 1),
            y=integer(work_area.y, 1),
            width=math.max(1, integer(work_area.width, 1)),
            height=math.max(1, integer(work_area.height, 1)),
        }
    end

    local width, height = desktop_frame:getSize()
    width = math.max(1, integer(width, 1))
    height = math.max(1, integer(height, 1) - FALLBACK_TASKBAR_HEIGHT)
    return {x=1, y=1, width=width, height=height}
end

local function normalizeWindowGeometry(window, geometry, bounds)
    bounds = bounds or workspaceBounds()
    if not bounds then return nil end
    geometry = geometry or {}

    -- Manifest minimums win on normal screens. On very small terminals the
    -- actual workspace wins so the titlebar can never become unreachable.
    local min_width = math.min(
        bounds.width,
        math.max(8, integer(window and window.min_width, 10))
    )
    local min_height = math.min(
        bounds.height,
        math.max(4, integer(window and window.min_height, 5))
    )
    local width = math.max(
        min_width,
        math.min(integer(geometry.width, min_width), bounds.width)
    )
    local height = math.max(
        min_height,
        math.min(integer(geometry.height, min_height), bounds.height)
    )
    local max_x = bounds.x + bounds.width - width
    local max_y = bounds.y + bounds.height - height
    local x = math.max(bounds.x, math.min(integer(geometry.x, bounds.x), max_x))
    local y = math.max(bounds.y, math.min(integer(geometry.y, bounds.y), max_y))

    return {x=x, y=y, width=width, height=height}
end

local function sameGeometry(left, right)
    return left and right
        and left.x == right.x and left.y == right.y
        and left.width == right.width and left.height == right.height
end

local function snapWindowGeometry(window, geometry, bounds)
    if windowSetting("snap_to_edges", true) == false then return geometry end
    bounds = bounds or workspaceBounds()
    if not bounds then return geometry end
    local distance = math.max(
        0, math.floor(tonumber(windowSetting("snap_distance", 2)) or 2)
    )
    local max_x = bounds.x + bounds.width - geometry.width
    local max_y = bounds.y + bounds.height - geometry.height
    local snapped = {
        x=geometry.x, y=geometry.y,
        width=geometry.width, height=geometry.height,
    }
    if math.abs(snapped.x - bounds.x) <= distance then
        snapped.x = bounds.x
    elseif math.abs(max_x - snapped.x) <= distance then
        snapped.x = max_x
    end
    if math.abs(snapped.y - bounds.y) <= distance then
        snapped.y = bounds.y
    elseif math.abs(max_y - snapped.y) <= distance then
        snapped.y = max_y
    end
    return snapped
end

local function updateWindowContentSize(window, width, height)
    window.width, window.height = width, height
    if window.program_element and not window.fullscreen then
        window.program_element:setSize(
            math.max(1, width - 2),
            math.max(1, height - 2)
        )
    end
end

local function applyWindowGeometry(window, geometry)
    if not window or not window.frame or not geometry then return false end
    window.frame:setPosition(geometry.x, geometry.y)
    window.frame:setSize(geometry.width, geometry.height)
    updateWindowContentSize(window, geometry.width, geometry.height)
    return true
end

local function getSavedGeometry(app_id)
    if not app_id or type(config.getUserConfig) ~= "function" then return nil end
    local records = config.getUserConfig(USER_GEOMETRY_CONFIG, {})
    if type(records) ~= "table" or type(records[app_id]) ~= "table" then return nil end
    local record = records[app_id]
    return {
        x=record.x,
        y=record.y,
        width=record.width,
        height=record.height,
        maximized=record.maximized == true,
    }
end

local function saveWindowGeometry(window)
    if not window or window.fullscreen or not window.app_id
        or type(config.getUserConfig) ~= "function"
        or type(config.setUserConfig) ~= "function" then
        return false
    end

    local geometry = window.preferred_geometry
    if not geometry and window.maximized and window.maximize_restore_geometry then
        geometry = window.maximize_restore_geometry
    elseif not geometry and window.state == "minimized" and window.restore_geometry then
        geometry = window.restore_geometry
    elseif not geometry and window.frame then
        geometry = frameGeometry(window)
    end
    if type(geometry) ~= "table" then return false end
    geometry = {
        x=integer(geometry.x, 1),
        y=integer(geometry.y, 1),
        width=math.max(1, integer(geometry.width, 1)),
        height=math.max(1, integer(geometry.height, 1)),
    }

    local records = config.getUserConfig(USER_GEOMETRY_CONFIG, {})
    if type(records) ~= "table" then records = {} end
    records[window.app_id] = {
        x=geometry.x,
        y=geometry.y,
        width=geometry.width,
        height=geometry.height,
        maximized=window.maximized == true,
    }
    return config.setUserConfig(USER_GEOMETRY_CONFIG, records, true)
end

local function removeFromFocusOrder(window_id)
    for index = #focus_order, 1, -1 do
        if focus_order[index] == window_id then table.remove(focus_order, index) end
    end
end

local function touchFocusOrder(window_id)
    removeFromFocusOrder(window_id)
    table.insert(focus_order, 1, window_id)
end

local function cancelAnimation(window)
    if window and window.animation then
        pcall(window.animation.cancel)
        window.animation = nil
    end
end

local function animateWindow(window, properties, duration, easing, on_done)
    if not window or not window.frame then return end
    cancelAnimation(window)

    if windowSetting("enable_animations", true) == false
        or not window.frame.animate then
        for property, value in pairs(properties) do window.frame[property] = value end
        if on_done then on_done(window.frame) end
        return
    end

    local frame = window.frame
    window.animation = frame:animate(properties, duration, easing, function(element)
        if window.frame ~= frame then return end
        window.animation = nil
        if on_done then on_done(element) end
    end)
end

frameGeometry = function(window)
    local x, y = window.frame:getPosition()
    local width, height = window.frame:getSize()
    return {x=x, y=y, width=width, height=height}
end

local function collapsedGeometry(geometry, width, height)
    width, height = width or 4, height or 3
    return {
        x = math.floor(geometry.x + (geometry.width - width) / 2),
        y = math.floor(geometry.y + (geometry.height - height) / 2),
        width = width,
        height = height,
    }
end

local function absoluteEventPosition(source, x, y)
    local source_x, source_y = source:getAbsolutePosition()
    return source_x + (tonumber(x) or 1) - 1,
        source_y + (tonumber(y) or 1) - 1
end

local function windowCanReceiveFocus(window)
    return window and window.frame and window.state ~= "closing"
        and window.state ~= "minimized" and window.state ~= "minimizing"
end

local function topmostWindow(excluded_id)
    for _, id in ipairs(focus_order) do
        if id ~= excluded_id and windowCanReceiveFocus(windows[id]) then return id end
    end
    local top_id, top_z
    for id, candidate in pairs(windows) do
        if id ~= excluded_id and windowCanReceiveFocus(candidate) then
            local z = tonumber(candidate.frame.z) or 0
            if not top_id or z > top_z then
                top_id, top_z = id, z
            end
        end
    end
    return top_id
end

local function switchableWindow(window)
    return window and window.frame and window.state ~= "closing"
end

local function switchableWindows()
    local result, seen = {}, {}
    for _, id in ipairs(focus_order) do
        if switchableWindow(windows[id]) then
            result[#result + 1] = id
            seen[id] = true
        end
    end

    local missing = {}
    for id, window in pairs(windows) do
        if not seen[id] and switchableWindow(window) then
            missing[#missing + 1] = id
        end
    end
    table.sort(missing, function(left, right)
        local left_z = tonumber(windows[left].frame.z) or 0
        local right_z = tonumber(windows[right].frame.z) or 0
        if left_z == right_z then return left < right end
        return left_z > right_z
    end)
    for _, id in ipairs(missing) do result[#result + 1] = id end
    return result
end

local function resetTabCycle()
    tab_cycle.candidates = {}
    tab_cycle.index = 1
    tab_cycle.last_at = 0
end

local function validTabCycle()
    if #tab_cycle.candidates == 0
        or focused_window ~= tab_cycle.candidates[tab_cycle.index] then
        return false
    end
    local available = switchableWindows()
    if #available ~= #tab_cycle.candidates then return false end
    local seen = {}
    for _, id in ipairs(available) do seen[id] = true end
    for _, id in ipairs(tab_cycle.candidates) do
        if not seen[id] then return false end
    end
    return true
end

local function handleGlobalShortcut(event_name, key, held)
    if not keys or key ~= keys.tab then return false end
    if event_name == "key_up" and tab_consumed then
        tab_consumed = false
        return true
    end
    if event_name ~= "key" then return false end

    local candidates = switchableWindows()
    if #candidates <= 1 then return false end
    tab_consumed = true
    if not held then api.public.cycleWindowFocus(1) end
    return true
end

local function prioritizeWindow(window)
    if window.fullscreen then
        window.frame:toFront()
        return
    end

    local ordered = {}
    for id, candidate in pairs(windows) do
        if candidate ~= window and candidate.frame and not candidate.fullscreen then
            ordered[#ordered + 1] = {id=id, window=candidate}
        end
    end
    table.sort(ordered, function(left, right)
        local left_z = tonumber(left.window.frame.z) or WINDOW_Z_BASE
        local right_z = tonumber(right.window.frame.z) or WINDOW_Z_BASE
        if left_z == right_z then return left.id < right.id end
        return left_z < right_z
    end)

    for index, entry in ipairs(ordered) do
        entry.window.frame.z = WINDOW_Z_BASE + index
    end
    window.frame.z = WINDOW_Z_BASE + #ordered + 1
end

local function setResizeHandlesVisible(window, visible)
    for _, handle in pairs(window.resize_handles or {}) do
        handle:setVisible(visible == true)
    end
end

local function setMaximizedVisualState(window, maximized)
    window.maximized = maximized == true
    if window.frame and not window.fullscreen then
        window.frame:setDraggable(not window.maximized)
    end
    setResizeHandlesVisible(window, window.resizable and not window.maximized)
end

local function addWindowBorder(window)
    local _, layer = ui_helpers.addBorder(window.frame, function()
        return window.border_color or theme("secondary")
    end, {
        innerColor=function() return window.frame.background or colors.black end,
        topStyle="solid",
        name="window_border",
    })

    window.border_layer = layer
    return layer
end

local make_package = dofile("rom/modules/main/cc/require.lua").make

-- Load app API
local app_api = require("core.app_api")

local function build_program_environment(pid, window_id, program_dir, executable_path)
    local env = setmetatable({}, {__index = _ENV})
    return program_env.build(env, {
        pid       = pid,
        window_id = window_id,
        windows   = windows,
        wm        = api.public,
        focused   = function() return focused_window end,
        executable = executable_path,
    }, make_package, program_dir)
end

function api.public.init()
    event.on("process.terminated", function(pid)
        api.private.closeWindowByPid(pid)
    end)

    -- Deferred cleanup after Basalt's update cycle completes
    event.on("wm.window_done", function(pid, success, result)
        local process_service = service.getPrivateApi("process")
        if process_service then
            process_service.completeWindowProcess(pid, success, result)
        end
    end)

    -- Process termination starts animated closes. A session logout destroys the
    -- entire desktop immediately afterwards, so cancel those animations and
    -- release every old-session window before the login screen is rebuilt.
    event.on("user.logout", function()
        focus_order = {}
        tab_consumed = false
        resetTabCycle()
        api.private.closeAllWindowsImmediate()
    end)

    event.on("theme.changed", function()
        for id, window in pairs(windows) do
            api.private.refreshWindowChrome(window, id == focused_window)
        end
    end)

    event.on("term_resize", function()
        api.private.normalizeAllWindows()
    end)

    event.on("taskbar.work_area_changed", function()
        api.private.normalizeAllWindows()
    end)

    local ui = service.getService("ui")
    if ui and ui.registerGlobalEventHandler then
        shortcut_controller = ui.registerGlobalEventHandler(
            "wm.window_cycle", handleGlobalShortcut, 100
        )
    end
end

-- Public API: Create a window for a process
-- @param pid: Process ID
-- @param program: Program metadata from registry
-- @param executable_path: Path to the program to execute
-- @param args: Arguments to pass to the program
-- @return window_id
function api.public.createWindow(pid, program, executable_path, args)
    log.debug("WM", "createWindow called", {pid = pid, program = program.name, executable = executable_path})

    local ui = service.getService("ui")
    if not ui then
        log.error("WM", "UI service not available")
        return nil, "UI service not available"
    end

    local window_id = next_window_id
    next_window_id = next_window_id + 1

    local window_config = program.window or {}
    local fullscreen = window_config.fullscreen or false
    local auto_close = window_config.auto_close ~= false
    local width = window_config.default_width or 30
    local height = window_config.default_height or 15

    log.debug("WM", "Window config", {fullscreen = fullscreen, width = width, height = height})

    local program_dir = fs.getDir(executable_path)
    log.debug("WM", "Program directory", {dir = program_dir})

    local program_env = build_program_environment(
        pid, window_id, program_dir, executable_path)

    local window = {
        id = window_id,
        pid = pid,
        app_id = tostring(program.id or program.name or executable_path),
        title = program.name,
        fullscreen = fullscreen,
        width = width,
        height = height,
        resizable = window_config.resizable ~= false,
        min_width = window_config.min_width or 10,
        min_height = window_config.min_height or 5,
        frame = nil,
        program_element = nil,
        state = "opening",
        animation = nil,
        restore_geometry = nil,
        maximize_restore_geometry = nil,
        maximized = false,
        chrome_elements = {},
        resize_handles = {},
        close_handler = nil,
        close_request_pending = false,
        close_request_serial = 0,
    }

    windows[window_id] = window

    local saved_geometry = not fullscreen and getSavedGeometry(window.app_id) or nil
    local normal_geometry = not fullscreen and normalizeWindowGeometry(window, {
        x=saved_geometry and saved_geometry.x or 3,
        y=saved_geometry and saved_geometry.y or 3,
        width=saved_geometry and saved_geometry.width or width,
        height=saved_geometry and saved_geometry.height or height + 1,
    }) or nil
    if not fullscreen then
        window.preferred_geometry = {
            x=saved_geometry and integer(saved_geometry.x, 3) or 3,
            y=saved_geometry and integer(saved_geometry.y, 3) or 3,
            width=math.max(
                1, saved_geometry and integer(saved_geometry.width, width) or width
            ),
            height=math.max(
                1,
                saved_geometry and integer(saved_geometry.height, height + 1)
                    or height + 1
            ),
        }
    end
    local initial_maximized = saved_geometry and saved_geometry.maximized == true

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
            window.frame:addFrame({
                x = 1,
                y = "{parent.height}",
                width = "{parent.width}",
                height = 1,
                background = theme("secondary"),
                disabled = true
            })
            local fullscreen_title = window.frame:addLabel({
                x = 2,
                y = "{parent.height}",
                text = window.title,
                foreground = theme("text"),
                background = theme("secondary")
            })
            window.chrome_elements.title = fullscreen_title
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

            window.frame:toFront()

            window.restore_geometry = {x=1, y=1, width=screen_w, height=screen_h}
            animateWindow(window, window.restore_geometry, OPEN_DURATION, "easeOut", function()
                if windows[window_id] ~= window or window.state == "closing" then return end
                window.state = "open"
                window.frame:setPosition(1, 1)
                window.frame:setSize("{parent.width}", "{parent.height}")
                window.program_element:setSize("{parent.width}", "{parent.height - 1}")
            end)
        else
            -- Windowed: attach to desktop_frame
            local target_geometry = normal_geometry or {
                x=3, y=3, width=width, height=height + 1,
            }
            if initial_maximized then
                window.maximize_restore_geometry = target_geometry
                target_geometry = workspaceBounds() or target_geometry
            end
            local target_x = target_geometry.x
            local target_y = target_geometry.y
            local final_width = target_geometry.width
            local final_height = target_geometry.height
            local start_width, start_height = 4, 3
            local start_x = math.floor(target_x + (final_width - start_width) / 2)
            local start_y = math.floor(target_y + (final_height - start_height) / 2)

            window.frame = desktop_frame:addFrame({
                x = start_x,
                y = start_y,
                width = start_width,
                height = start_height,
                draggable = true,
                background = colors.black
            })
            local titlebar_bg = window.frame:addFrame({
                x = 1,
                y = 1,
                width = "{parent.width}",
                height = 1,
                background = theme("secondary"),
                disabled = true
            }):setName("titlebar_bg")
            local titlebar_label = window.frame:addLabel({
                x = 2,
                y = 1,
                text = window.title,
                foreground = theme("text"),
                background = theme("secondary"),
                disabled = true,
            }):setName("titlebar_label")
            window.chrome_elements.titlebar = titlebar_bg
            window.chrome_elements.title = titlebar_label

            local close_button = window.frame:addButton({
                x = "{parent.width - 1}",
                y = 1,
                width = 1,
                height = 1,
                text = string.char(7),
                foreground = theme("danger"),
                background = theme("secondary")
            }):setName("window_close")
            close_button:setStateStyle("hover", {
                foreground=theme("text"), background=theme("danger"),
            })
            close_button:setStateStyle("pressed", {
                foreground=theme("text"), background=theme("danger"),
            })
            close_button:onClick(function()
                api.public.closeWindow(window_id)
            end)

            local maximize_button = window.frame:addButton({
                x = "{parent.width - 2}", y = 1, width = 1, height = 1,
                text = string.char(7), foreground = theme("success"),
                background = theme("secondary"),
            }):setName("window_maximize")
            maximize_button:setStateStyle("hover", {
                foreground=theme("text_on_light"), background=theme("success"),
            })
            maximize_button:setStateStyle("pressed", {
                foreground=theme("text_on_light"), background=theme("success"),
            })
            maximize_button:onClick(function()
                api.public.maximizeWindow(window_id)
            end)

            local minimize_button = window.frame:addButton({
                x = "{parent.width - 3}",
                y = 1,
                width = 1,
                height = 1,
                text = string.char(7),
                foreground = theme("warning"),
                background = theme("secondary")
            }):setName("window_minimize")
            minimize_button:setStateStyle("hover", {
                foreground=theme("text_on_light"), background=theme("warning"),
            })
            minimize_button:setStateStyle("pressed", {
                foreground=theme("text_on_light"), background=theme("warning"),
            })
            minimize_button:onClick(function()
                api.public.minimizeWindow(window_id)
            end)
            window.control_buttons = {
                close_button, maximize_button, minimize_button,
            }
            window.maximize_button = maximize_button

            window.program_element = window.frame:addProgram({
                x = 2,
                y = 2,
                width = math.max(1, final_width - 2),
                height = math.max(1, final_height - 2),
                background = colors.black
            })

            window.frame:setDraggingMap({{x=1, y=1, width="full", height=1}})

            window.frame:onClick(function()
                api.private.activateWindow(window_id, false)
            end)
            window.frame:onFocus(function()
                api.private.activateWindow(window_id, false)
            end)
            window.frame:onClickUp(function()
                api.private.commitWindowGeometry(window_id)
            end)
            window.program_element:onClick(function()
                api.private.activateWindow(window_id, false)
            end)
            window.program_element:onFocus(function()
                api.private.activateWindow(window_id, false)
            end)

            local function addResizeHandle(name, x, y)
                local handle = window.frame:addFrame({
                    x=x, y=y, width=1, height=1,
                    background=false,
                }):setName("window_resize_" .. name)
                local drag_x, drag_y
                handle:onClick(function(source, button, mouse_x, mouse_y)
                    api.private.activateWindow(window_id, false)
                    if button == 1 and window.resizable and not window.maximized then
                        drag_x, drag_y = absoluteEventPosition(source, mouse_x, mouse_y)
                    end
                end)
                handle:onDrag(function(source, button, mouse_x, mouse_y)
                    if button ~= 1 or not drag_x or not drag_y then return end
                    local absolute_x, absolute_y = absoluteEventPosition(source, mouse_x, mouse_y)
                    api.private.resizeFromCorner(
                        window, name, absolute_x - drag_x, absolute_y - drag_y
                    )
                    drag_x, drag_y = absolute_x, absolute_y
                end)
                handle:onClickUp(function()
                    drag_x, drag_y = nil, nil
                    api.private.commitWindowGeometry(window_id)
                end)
                window.resize_handles[name] = handle
            end
            addResizeHandle("top_left", 1, 1)
            addResizeHandle("top_right", "{parent.width}", 1)
            addResizeHandle("bottom_left", 1, "{parent.height}")
            addResizeHandle("bottom_right", "{parent.width}", "{parent.height}")
            setResizeHandlesVisible(window, window.resizable)
            addWindowBorder(window)
            if initial_maximized then setMaximizedVisualState(window, true) end

            window.restore_geometry = {
                x=target_x, y=target_y,
                width=final_width, height=final_height,
            }
            window.committed_geometry = {
                x=target_x, y=target_y,
                width=final_width, height=final_height,
            }
            updateWindowContentSize(window, final_width, final_height)
            animateWindow(window, window.restore_geometry, OPEN_DURATION, "easeOut", function()
                if windows[window_id] ~= window or window.state == "closing" then return end
                window.state = "open"
                updateWindowContentSize(window, final_width, final_height)
            end)
        end

        window.program_element:onDone(function(prog, success, result)
            log.info("WM", "Program completed", {pid = pid, success = success})
            -- When success=false, onError fires right after this – let onError handle cleanup
            if not success then return end
            if not auto_close then return end
            -- Defer cleanup: frame:destroy() inside basalt.update() corrupts Basalt state
            local ui = service.getService("ui")
            if ui then
                ui.deferDispatch("wm.window_done", pid, true, result)
            end
        end)

        window.program_element:onError(function(prog, error_msg, trace)
            log.error("WM", "Program error", {pid = pid, error = error_msg, trace = trace})
            local app_name = windows[window_id] and windows[window_id].title or "unknown"
            error_sys.logAppCrash(app_name, pid, error_msg, trace)

            -- A crashed Program keeps its last terminal buffer, whose default
            -- background is black. Do not animate that dead buffer underneath
            -- the crash dialog; deferred cleanup will destroy the hidden frame.
            window.state = "crashed"
            if window.frame then window.frame:setVisible(false) end

            local short_err = tostring(error_msg):gsub("^.*%.lua:%d+: ", "")
            local ui = service.getService("ui")
            if ui then
                ui.deferDispatch("wm.window_done", pid, false, error_msg)
                ui.deferDispatch("wm.app_crashed", app_name, short_err)
            end

            -- Return false: prevents Basalt from calling errorManager.error() which would crash the OS
            return false
        end)

        log.info("WM", "Executing program", {executable = executable_path, args = args})
        window.program_element:setEnv(program_env)
        window.program_element:execute(executable_path, table.unpack(args or {}))
        log.info("WM", "Program execution started")
    else
        log.error("WM", "Desktop frame or main frame is nil!")
    end

    event.dispatch("wm.window_created", window_id, pid)

    api.public.focusWindow(window_id)

    log.info("WM", "Window created successfully", {window_id = window_id, pid = pid})

    return window_id
end

local function finalizeWindowClose(window_id, window)
    if windows[window_id] ~= window then return end

    cancelAnimation(window)
    window.close_handler = nil
    window.close_request_pending = false
    window.close_request_serial = (window.close_request_serial or 0) + 1
    if window.frame then
        window.frame:destroy()
        window.frame = nil
    end
    windows[window_id] = nil
    removeFromFocusOrder(window_id)
    resetTabCycle()

    local was_focused = focused_window == window_id
    if was_focused then focused_window = nil end
    event.dispatch("wm.window_closed", window_id, window.pid)

    if was_focused then
        local next_id = topmostWindow(window_id)
        if next_id then
            api.public.focusWindow(next_id)
        else
            event.dispatch("wm.window_focused", nil)
        end
    end
end

function api.private.closeAllWindowsImmediate()
    local closing = {}
    for window_id, window in pairs(windows) do
        closing[#closing + 1] = {id=window_id, window=window}
    end
    focused_window = nil
    for _, entry in ipairs(closing) do
        local window = entry.window
        cancelAnimation(window)
        window.close_handler = nil
        window.close_request_pending = false
        window.close_request_serial = (window.close_request_serial or 0) + 1
        if window.frame then
            window.frame:destroy()
            window.frame = nil
        end
        windows[entry.id] = nil
        event.dispatch("wm.window_closed", entry.id, window.pid)
    end
    focus_order = {}
    resetTabCycle()
end

-- Register an app-owned close request handler. The handler receives a
-- resolve(allow) callback and may answer immediately or after an async dialog.
-- Passing nil removes the handler. Forced process termination bypasses it.
function api.public.setWindowCloseHandler(window_id, handler)
    local window = windows[window_id]
    if not window then return false, "Window not found" end
    if handler ~= nil and type(handler) ~= "function" then
        return false, "Close handler must be a function or nil"
    end
    if window.state == "closing" then return false, "Window is closing" end

    window.close_handler = handler
    window.close_request_pending = false
    window.close_request_serial = (window.close_request_serial or 0) + 1
    return true
end

-- Internal close path for process completion, crashes, logout, shutdown and
-- Task Manager termination. Apps cannot veto this path.
function api.private.forceCloseWindow(window_id)
    local window = windows[window_id]
    if not window then return false, "Window not found" end

    if window.state == "closing" then return true end
    window.close_request_pending = false
    window.close_request_serial = (window.close_request_serial or 0) + 1
    window.state = "closing"

    if not window.frame or not window.frame:getVisible() then
        finalizeWindowClose(window_id, window)
        return true
    end

    local geometry = frameGeometry(window)
    local target = collapsedGeometry(geometry)
    animateWindow(window, target, CLOSE_DURATION, "easeIn", function()
        finalizeWindowClose(window_id, window)
    end)

    return true
end

-- Normal user/app close request. A registered handler may asynchronously allow
-- or cancel it; repeated requests are coalesced while the handler is deciding.
function api.public.closeWindow(window_id)
    local window = windows[window_id]
    if not window then return false, "Window not found" end
    if window.state == "closing" then return true end

    local handler = window.close_handler
    if type(handler) ~= "function" then
        return api.private.forceCloseWindow(window_id)
    end
    if window.close_request_pending then return true end

    window.close_request_pending = true
    window.close_request_serial = (window.close_request_serial or 0) + 1
    local request_serial = window.close_request_serial
    local resolved = false

    local function resolve(allow)
        if resolved then return false, "Close request already resolved" end
        resolved = true
        if windows[window_id] ~= window
            or window.close_request_serial ~= request_serial then
            return false, "Close request is no longer active"
        end

        window.close_request_pending = false
        if allow == true then
            return api.private.forceCloseWindow(window_id)
        end
        return true
    end

    local ok, result = pcall(handler, resolve)
    if not ok then
        resolve(false)
        log.error("WM", "Window close handler failed", {
            window_id=window_id, pid=window.pid, error=result,
        })
        return false, tostring(result)
    end

    -- Boolean returns are supported for simple synchronous handlers. Apps that
    -- show a dialog leave the return value nil and call resolve later.
    if not resolved and type(result) == "boolean" then resolve(result) end
    return true
end

function api.private.closeWindowByPid(pid)
    for window_id, window in pairs(windows) do
        if window.pid == pid then
            api.private.forceCloseWindow(window_id)
            return
        end
    end
end

function api.private.setTitlebarColor(window, color)
    if not window.frame or window.fullscreen then return end
    window.border_color = color
    for _, element in pairs(window.chrome_elements or {}) do
        element:setBackground(color)
    end
    for _, button in ipairs(window.control_buttons or {}) do
        button:setBackground(color)
    end
    if window.border_layer then
        window.border_layer:markRenderDirty()
    end
end

function api.private.refreshWindowChrome(window, focused)
    if not window or window.fullscreen then return end
    local color
    if focused then
        color = theme("window_focused")
    else
        color = theme("secondary")
    end
    api.private.setTitlebarColor(window, color)
end

function api.private.activateWindow(window_id, focus_program)
    local window = windows[window_id]
    if not windowCanReceiveFocus(window) then
        return false, "Window cannot receive focus"
    end

    local changed = focused_window ~= window_id
    if not tab_cycle.switching then resetTabCycle() end
    focused_window = window_id
    touchFocusOrder(window_id)
    window.frame:setVisible(true)
    prioritizeWindow(window)

    for id, candidate in pairs(windows) do
        api.private.refreshWindowChrome(candidate, id == window_id)
    end

    if focus_program and window.program_element then
        window.program_element:focus()
    end
    if changed then
        event.dispatch("wm.window_focused", window_id)
    end
    return true
end

function api.public.focusWindow(window_id)
    local window = windows[window_id]

    if not window then
        return false, "Window not found"
    end

    if window.state == "closing" then
        return false, "Window is closing"
    end
    if window.state == "minimized" or window.state == "minimizing" then
        return api.public.restoreWindow(window_id)
    end

    return api.private.activateWindow(window_id, true)
end

function api.public.getWindow(window_id)
    return windows[window_id]
end

-- Suspend/resume the Program element without hiding or destroying its window.
function api.public.setWindowProcessPaused(window_id, paused)
    local window = windows[window_id]
    if not window then return false, "Window not found" end
    if not window.program_element then return false, "Window program not found" end

    if paused then
        window.program_element:pause()
    else
        window.program_element:resume()
    end
    return true
end

function api.public.listWindows()
    local list = {}
    for id, window in pairs(windows) do
        table.insert(list, window)
    end
    return list
end

-- Most-recently-used window IDs, newest first. Minimized windows remain in
-- the order so keyboard window cycling can restore them.
function api.public.getFocusOrder()
    local result = {}
    for _, id in ipairs(focus_order) do
        if windows[id] then result[#result + 1] = id end
    end
    return result
end

function api.public.listWindowsByFocus()
    local result = {}
    for _, id in ipairs(api.public.getFocusOrder()) do
        result[#result + 1] = windows[id]
    end
    return result
end

-- Immediately focuses the next/previous window in a stable MRU cycle.
function api.public.cycleWindowFocus(direction)
    local candidates = switchableWindows()
    if #candidates == 0 then return false, "No windows available" end
    if #candidates == 1 then return api.public.focusWindow(candidates[1]) end

    local now = os.clock and os.clock() or 0
    if now - tab_cycle.last_at > 1 or not validTabCycle() then
        tab_cycle.candidates = candidates
        tab_cycle.index = 1
    end
    local step = direction and direction < 0 and -1 or 1
    tab_cycle.index = ((tab_cycle.index - 1 + step)
        % #tab_cycle.candidates) + 1
    tab_cycle.last_at = now
    local target = tab_cycle.candidates[tab_cycle.index]
    tab_cycle.switching = true
    local result = table.pack(api.public.focusWindow(target))
    tab_cycle.switching = false
    return table.unpack(result, 1, result.n)
end

function api.public.getFocusedWindow()
    return focused_window
end

function api.public.setWindowTitle(window_id, title)
    local window = windows[window_id]
    if not window then return false, "Window not found" end

    title = tostring(title or "")
    if title == "" then title = "Application" end
    window.title = title

    local title_element = window.chrome_elements
        and window.chrome_elements.title or nil
    if title_element then title_element:setText(title) end

    event.dispatch("wm.window_title_changed", window_id, title)
    return true
end

-- Finalize a mouse-driven move/resize. Basalt moves draggable frames directly,
-- so the WM clamps the result and persists it once on mouse-up instead of
-- writing the user config for every drag event.
function api.private.commitWindowGeometry(window_id)
    local window = windows[window_id]
    if not window or not window.frame or window.fullscreen or window.maximized
        or window.state ~= "open" then
        return false
    end

    local current = frameGeometry(window)
    local geometry = normalizeWindowGeometry(window, current)
    if not geometry then return false end
    geometry = snapWindowGeometry(window, geometry)
    local previous = window.committed_geometry
    local moved = not previous or previous.x ~= geometry.x or previous.y ~= geometry.y
    local resized = not previous
        or previous.width ~= geometry.width or previous.height ~= geometry.height
    applyWindowGeometry(window, geometry)
    window.restore_geometry = geometry
    window.preferred_geometry = {
        x=geometry.x, y=geometry.y,
        width=geometry.width, height=geometry.height,
    }
    window.committed_geometry = {
        x=geometry.x, y=geometry.y,
        width=geometry.width, height=geometry.height,
    }

    if moved then event.dispatch("wm.window_moved", window_id, geometry.x, geometry.y) end
    if resized then
        event.dispatch("wm.window_resized", window_id, geometry.width, geometry.height)
    end
    if moved or resized then saveWindowGeometry(window) end
    return true
end

function api.private.normalizeAllWindows()
    local ui = service.getService("ui")
    local main_frame = ui and ui.getMainFrame()
    local bounds = workspaceBounds()

    for window_id, window in pairs(windows) do
        if window.frame and window.state ~= "closing" then
            local before = frameGeometry(window)
            local target

            if window.fullscreen then
                if main_frame then
                    local width, height = main_frame:getSize()
                    target = {
                        x=1, y=1,
                        width=math.max(1, integer(width, 1)),
                        height=math.max(1, integer(height, 1)),
                    }
                    cancelAnimation(window)
                    applyWindowGeometry(window, target)
                    window.program_element:setSize(
                        target.width,
                        math.max(1, target.height - 1)
                    )
                    window.restore_geometry = target
                    if window.state == "opening" or window.state == "restoring" then
                        window.state = "open"
                    end
                end
            elseif bounds then
                if window.maximized then
                    target = {
                        x=bounds.x, y=bounds.y,
                        width=bounds.width, height=bounds.height,
                    }
                elseif window.state == "minimized" or window.state == "minimizing"
                    or window.state == "opening" or window.state == "restoring" then
                    target = normalizeWindowGeometry(
                        window, window.restore_geometry or before, bounds
                    )
                else
                    target = normalizeWindowGeometry(window, before, bounds)
                end

                if window.state == "minimizing" then
                    cancelAnimation(window)
                    window.frame:setVisible(false)
                    window.state = "minimized"
                elseif window.state == "opening" or window.state == "restoring" then
                    cancelAnimation(window)
                    window.state = "open"
                end

                applyWindowGeometry(window, target)
                window.restore_geometry = target
                window.committed_geometry = {
                    x=target.x, y=target.y,
                    width=target.width, height=target.height,
                }
            end

            if target and not sameGeometry(before, target) then
                if before.x ~= target.x or before.y ~= target.y then
                    event.dispatch("wm.window_moved", window_id, target.x, target.y)
                end
                if before.width ~= target.width or before.height ~= target.height then
                    event.dispatch(
                        "wm.window_resized", window_id, target.width, target.height
                    )
                end
            end
        end
    end
end

function api.public.minimizeWindow(window_id)
    local window = windows[window_id]

    if not window then
        return false, "Window not found"
    end

    if window.state == "closing" then return false, "Window is closing" end
    if window.state == "minimized" or window.state == "minimizing" then return true end
    if not window.frame then return false, "Window frame not found" end

    local current = frameGeometry(window)
    if window.state ~= "opening" then window.restore_geometry = current end

    local target = collapsedGeometry(current)
    local ui = service.getService("ui")
    local main_frame = ui and ui.getMainFrame()
    if main_frame then
        local _, screen_height = main_frame:getSize()
        target.y = math.max(1, screen_height - target.height + 1)
    end

    window.state = "minimizing"
    animateWindow(window, target, MINIMIZE_DURATION, "easeIn", function()
        if windows[window_id] ~= window or window.state ~= "minimizing" then return end
        window.frame:setVisible(false)
        local restore = window.restore_geometry
        if restore then
            window.frame:setPosition(restore.x, restore.y)
            window.frame:setSize(restore.width, restore.height)
        end
        window.state = "minimized"
        if focused_window == window_id then
            focused_window = nil
            local next_id = topmostWindow(window_id)
            if next_id then
                api.public.focusWindow(next_id)
            else
                event.dispatch("wm.window_focused", nil)
            end
        end
        event.dispatch("wm.window_minimized", window_id)
    end)

    return true
end

function api.public.restoreWindow(window_id)
    local window = windows[window_id]

    if not window then
        return false, "Window not found"
    end

    if window.state == "closing" then return false, "Window is closing" end
    if not window.frame then return false, "Window frame not found" end
    if window.state ~= "minimized" and window.state ~= "minimizing" then
        return api.public.focusWindow(window_id)
    end

    cancelAnimation(window)
    local target = window.restore_geometry or frameGeometry(window)
    local start = collapsedGeometry(target)
    local ui = service.getService("ui")
    local main_frame = ui and ui.getMainFrame()
    if main_frame then
        local _, screen_height = main_frame:getSize()
        start.y = math.max(1, screen_height - start.height + 1)
    end

    window.frame:setPosition(start.x, start.y)
    window.frame:setSize(start.width, start.height)
    window.frame:setVisible(true)
    window.state = "restoring"
    api.public.focusWindow(window_id)

    animateWindow(window, target, OPEN_DURATION, "easeOut", function()
        if windows[window_id] ~= window or window.state ~= "restoring" then return end
        window.state = "open"
        if window.fullscreen then
            window.frame:setPosition(1, 1)
            window.frame:setSize("{parent.width}", "{parent.height}")
            window.program_element:setSize("{parent.width}", "{parent.height - 1}")
        end
        event.dispatch("wm.window_restored", window_id)
    end)
    return true
end

function api.public.maximizeWindow(window_id)
    local window = windows[window_id]
    if not window then return false, "Window not found" end
    if window.fullscreen then return false, "Fullscreen windows cannot be maximized" end
    if window.state == "closing" then return false, "Window is closing" end
    if window.state == "minimized" or window.state == "minimizing" then
        cancelAnimation(window)
        local restore = window.restore_geometry
        if not restore then return false, "Restore geometry not found" end
        window.frame:setPosition(restore.x, restore.y)
        window.frame:setSize(restore.width, restore.height)
        window.frame:setVisible(true)
        window.state = "open"
    end
    if not window.frame then return false, "Window frame not found" end

    local bounds = workspaceBounds()
    if not bounds then return false, "Desktop frame not found" end

    local target
    if window.maximized then
        target = normalizeWindowGeometry(
            window,
            window.preferred_geometry or window.maximize_restore_geometry,
            bounds
        )
        if not target then return false, "Restore geometry not found" end
        setMaximizedVisualState(window, false)
        window.maximize_restore_geometry = nil
    else
        if not window.preferred_geometry then
            local current = frameGeometry(window)
            window.preferred_geometry = {
                x=current.x, y=current.y,
                width=current.width, height=current.height,
            }
        end
        window.maximize_restore_geometry = normalizeWindowGeometry(
            window, window.preferred_geometry, bounds
        )
        target = {
            x=bounds.x, y=bounds.y,
            width=bounds.width, height=bounds.height,
        }
        setMaximizedVisualState(window, true)
    end

    applyWindowGeometry(window, target)
    window.restore_geometry = target
    window.committed_geometry = {
        x=target.x, y=target.y,
        width=target.width, height=target.height,
    }
    api.private.activateWindow(window_id, true)
    event.dispatch("wm.window_resized", window_id, target.width, target.height)
    event.dispatch(window.maximized and "wm.window_maximized" or "wm.window_unmaximized", window_id)
    saveWindowGeometry(window)
    return true
end

function api.private.resizeFromCorner(window, corner, delta_x, delta_y)
    if not window or not window.frame or not window.resizable or window.maximized then
        return false
    end
    if window.state ~= "open" then return false end

    delta_x = math.floor(tonumber(delta_x) or 0)
    delta_y = math.floor(tonumber(delta_y) or 0)
    if delta_x == 0 and delta_y == 0 then return true end

    local bounds = workspaceBounds()
    if not bounds then return false end
    local geometry = normalizeWindowGeometry(window, frameGeometry(window), bounds)
    local min_width = math.min(
        bounds.width, math.max(8, integer(window.min_width, 10))
    )
    local min_height = math.min(
        bounds.height, math.max(4, integer(window.min_height, 5))
    )
    if corner ~= "top_left" and corner ~= "top_right"
        and corner ~= "bottom_left" and corner ~= "bottom_right" then
        return false
    end

    local from_left = corner:sub(-5) == "_left"
    local from_top = corner:sub(1, 3) == "top"
    local right = geometry.x + geometry.width - 1
    local bottom = geometry.y + geometry.height - 1
    local workspace_right = bounds.x + bounds.width - 1
    local workspace_bottom = bounds.y + bounds.height - 1
    local new_x, new_y = geometry.x, geometry.y
    local new_width, new_height

    if from_left then
        new_x = math.max(
            bounds.x,
            math.min(geometry.x + delta_x, right - min_width + 1)
        )
        new_width = right - new_x + 1
    else
        new_width = math.max(
            min_width,
            math.min(geometry.width + delta_x, workspace_right - geometry.x + 1)
        )
    end

    if from_top then
        new_y = math.max(
            bounds.y,
            math.min(geometry.y + delta_y, bottom - min_height + 1)
        )
        new_height = bottom - new_y + 1
    else
        new_height = math.max(
            min_height,
            math.min(geometry.height + delta_y, workspace_bottom - geometry.y + 1)
        )
    end

    if new_x == geometry.x and new_y == geometry.y
        and new_width == geometry.width and new_height == geometry.height then
        return true
    end

    applyWindowGeometry(window, {
        x=new_x, y=new_y, width=new_width, height=new_height,
    })
    event.dispatch("wm.window_resized", window.id, new_width, new_height)
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
    if window.maximized then
        return false, "Window is maximized"
    end
    if not window.frame then return false, "Window frame not found" end

    width, height = tonumber(width), tonumber(height)
    if not width or not height then return false, "Invalid window size" end
    local before = frameGeometry(window)
    local geometry = normalizeWindowGeometry(window, {
        x=before.x, y=before.y,
        width=math.floor(width), height=math.floor(height),
    })
    if not geometry then return false, "Desktop frame not found" end

    applyWindowGeometry(window, geometry)
    window.restore_geometry = geometry
    window.preferred_geometry = {
        x=geometry.x, y=geometry.y,
        width=geometry.width, height=geometry.height,
    }
    window.committed_geometry = {
        x=geometry.x, y=geometry.y,
        width=geometry.width, height=geometry.height,
    }
    if before.x ~= geometry.x or before.y ~= geometry.y then
        event.dispatch("wm.window_moved", window_id, geometry.x, geometry.y)
    end
    event.dispatch("wm.window_resized", window_id, geometry.width, geometry.height)
    return true
end

function api.public.moveWindow(window_id, x, y)
    local window = windows[window_id]

    if not window then
        return false, "Window not found"
    end
    if window.maximized then return false, "Window is maximized" end
    if not window.frame then return false, "Window frame not found" end

    x, y = tonumber(x), tonumber(y)
    if not x or not y then return false, "Invalid window position" end
    local before = frameGeometry(window)
    local geometry = normalizeWindowGeometry(window, {
        x=math.floor(x), y=math.floor(y),
        width=before.width, height=before.height,
    })
    if not geometry then return false, "Desktop frame not found" end

    applyWindowGeometry(window, geometry)
    window.restore_geometry = geometry
    window.preferred_geometry = {
        x=geometry.x, y=geometry.y,
        width=geometry.width, height=geometry.height,
    }
    window.committed_geometry = {
        x=geometry.x, y=geometry.y,
        width=geometry.width, height=geometry.height,
    }
    event.dispatch("wm.window_moved", window_id, geometry.x, geometry.y)
    return true
end

return api
