-- /services/taskbar.lua
-- Two-row monochrome icon taskbar with manifest BIMG support and a live clock.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")
local icon = require("core.icon")

local function theme(key) return config.get("theme." .. key) end

local api = api_factory.new()

local TASKBAR_HEIGHT = 2
local TILE_WIDTH = icon.TASKBAR_WIDTH
local TILE_GAP = 1
local TILE_STRIDE = TILE_WIDTH + TILE_GAP
local CLOCK_WIDTH = 8
local CLOCK_RESERVED = CLOCK_WIDTH + 1

local taskbar_frame = nil
local start_tile = nil
local clock_time = nil
local clock_date = nil
local clock_timer_id = nil
local window_buttons = {} -- window_id -> {tile, image, program}

local function setting(path, fallback)
    local settings = service.getService("settings")
    if not settings or not settings.get then return fallback end
    return settings.get(path, fallback)
end

local function showsClock()
    return setting("taskbar.show_clock", true) ~= false
end

local function clockReservedWidth()
    return showsClock() and CLOCK_RESERVED or 0
end

local function bindHover(source, on_hover)
    source:onMouseEnter(function() on_hover(true) end)
    source:onMouseLeave(function() on_hover(false) end)
end

local function getWindowProgram(window)
    local process = service.getService("process")
    local registry = service.getService("registry")
    if not process or not registry or not window then return nil end
    local running = process.getProcess(window.pid)
    return running and registry.getProgram(running.program_id) or nil
end

local function openWindowMenu(source, x, y, window_id)
    local wm = service.getService("wm")
    local contextmenu = service.getService("contextmenu")
    if not wm or not contextmenu then return end
    local window = wm.getWindow(window_id)
    if not window then return end

    local minimized = window.state == "minimized" or window.state == "minimizing"
        or not (window.frame and window.frame:getVisible())
    contextmenu.openFor(source, x, y, {
        {label=window.title or "Application", disabled=true},
        {separator=true},
        {
            label=minimized and "Restore" or "Minimize",
            action=function()
                if minimized then wm.restoreWindow(window_id)
                else wm.minimizeWindow(window_id) end
            end,
        },
        {label="Close", action=function() wm.closeWindow(window_id) end},
    })
end

local function activateWindow(window_id)
    local wm = service.getService("wm")
    if not wm then return end
    local window = wm.getWindow(window_id)
    if not window or not window.frame then
        log.warn("TASKBAR", "Window not found on click", {window_id=window_id})
        return
    end

    local focused = wm.getFocusedWindow() == window_id
    local visible = window.frame:getVisible()
    if visible and focused then
        wm.minimizeWindow(window_id)
    elseif not visible or window.state == "minimized" then
        wm.restoreWindow(window_id)
    else
        wm.focusWindow(window_id)
    end
end

function api.public.init()
    event.on("desktop.created", function()
        api.private.createTaskbar()
    end)

    event.on("user.logout", function()
        api.private.destroyTaskbar()
    end)

    event.on("wm.window_created", function(window_id)
        api.private.addWindowButton(window_id)
    end)

    event.on("wm.window_closed", function(window_id)
        api.private.removeWindowButton(window_id)
    end)

    event.on("wm.window_focused", function(window_id)
        api.private.updateButtonStates(window_id)
    end)

    event.on("wm.window_minimized", function()
        local wm = service.getService("wm")
        api.private.updateButtonStates(wm and wm.getFocusedWindow() or nil)
    end)

    event.on("wm.window_restored", function(window_id)
        api.private.updateButtonStates(window_id)
    end)

    event.on("term_resize", function()
        api.private.repositionButtons()
    end)

    event.on("taskbar.settings_changed", function()
        if taskbar_frame then api.private.createTaskbar() end
        event.dispatch("taskbar.work_area_changed", api.public.getWorkArea())
    end)

    event.on("theme.changed", function()
        if taskbar_frame then api.private.createTaskbar() end
    end)

    event.on("timer", function(timer_id)
        if timer_id ~= clock_timer_id then return end
        clock_timer_id = nil
        if taskbar_frame then
            api.private.updateClock()
            clock_timer_id = os.startTimer(1)
        end
    end)
end

function api.private.updateClock()
    local format = tostring(setting("taskbar.clock_format", "%H:%M:%S"))
    local ok, formatted = pcall(os.date, format)
    if not ok or type(formatted) ~= "string" then
        formatted = os.date("%H:%M:%S")
    end
    if clock_time then clock_time:setText(formatted) end
    if clock_date then clock_date:setText(os.date("%d.%m.%y")) end
end

function api.private.createTaskbar()
    api.private.destroyTaskbar()

    local ui = service.getService("ui")
    if not ui then
        log.error("TASKBAR", "UI service not available")
        return
    end
    local desktop_frame = ui.getScreen("desktop")
    if not desktop_frame then
        log.error("TASKBAR", "Desktop frame not available")
        return
    end

    taskbar_frame = desktop_frame:addFrame({
        x=1,
        y="{parent.height - 1}",
        width="{parent.width}",
        height=TASKBAR_HEIGHT,
        background=theme("taskbar_bg"),
        z=1000,
    })

    start_tile = taskbar_frame:addFrame({
        x=1, y=1, width=TILE_WIDTH, height=TASKBAR_HEIGHT,
        background=theme("taskbar_bg"),
    })
    start_tile:setStateStyle("hover", {background=theme("surface")})
    start_tile:setStateStyle("pressed", {background=theme("surface")})
    local start_image = icon.addPath(start_tile, icon.BASALTOS_TASKBAR_PATH, {
        x=1, y=1,
        iconForeground=theme("icon_fg"),
        iconBackground=theme("taskbar_bg"),
        monochrome=true,
        variant="taskbar",
    })
    local function setStartHover(hovered)
        start_tile:setState("hover", hovered)
        icon.updatePath(
            start_image,
            icon.BASALTOS_TASKBAR_PATH,
            theme("icon_fg"),
            hovered and theme("surface") or theme("taskbar_bg"),
            true
        )
    end
    bindHover(start_tile, setStartHover)
    bindHover(start_image, setStartHover)
    start_tile:onClick(function(_, button)
        if button ~= 1 then return end
        local startmenu = service.getService("startmenu")
        if startmenu then startmenu.toggle()
        else log.error("TASKBAR", "Startmenu service not available") end
    end)

    if showsClock() then
        taskbar_frame:addFrame({
            x="{parent.width - 8}", y=1,
            width=1, height=TASKBAR_HEIGHT,
            background=theme("taskbar_bg"), disabled=true,
        })
        local clock_frame = taskbar_frame:addFrame({
            x="{parent.width - 7}", y=1,
            width=CLOCK_WIDTH, height=TASKBAR_HEIGHT,
            background=theme("taskbar_bg"),
        })
        clock_time = clock_frame:addLabel({
            x=1, y=1, width=CLOCK_WIDTH, height=1,
            text="", foreground=theme("taskbar_fg"),
            background=theme("taskbar_bg"), disabled=true,
        })
        clock_date = clock_frame:addLabel({
            x=1, y=2, width=CLOCK_WIDTH, height=1,
            text="", foreground=theme("taskbar_muted"),
            background=theme("taskbar_bg"), disabled=true,
        })
        local function setClockHover(hovered)
            local background = hovered and theme("surface") or theme("taskbar_bg")
            clock_frame:setState("hover", hovered)
            clock_frame:setBackground(background)
            clock_time:setBackground(background)
            clock_date:setBackground(background)
        end
        clock_frame:setStateStyle("hover", {background=theme("surface")})
        clock_frame:setStateStyle("pressed", {background=theme("surface")})
        bindHover(clock_frame, setClockHover)
        clock_frame:onClick(function(_, button)
            if button ~= 1 then return end
            local notification = service.getService("notification")
            if notification and notification.toggleHistory then
                notification.toggleHistory()
            else
                log.error("TASKBAR", "Notification service not available")
            end
        end)
        api.private.updateClock()
        clock_timer_id = os.startTimer(1)
    end

    local wm = service.getService("wm")
    if wm then
        local windows = wm.listWindows()
        table.sort(windows, function(a, b) return a.id < b.id end)
        for _, window in ipairs(windows) do api.private.addWindowButton(window.id) end
        api.private.updateButtonStates(wm.getFocusedWindow())
    end

    log.info("TASKBAR", "Two-row icon taskbar created")
end

function api.private.destroyTaskbar()
    if clock_timer_id and os.cancelTimer then pcall(os.cancelTimer, clock_timer_id) end
    clock_timer_id = nil
    clock_time = nil
    clock_date = nil
    start_tile = nil

    if taskbar_frame then
        taskbar_frame:destroy()
        taskbar_frame = nil
    end
    window_buttons = {}
end

function api.private.addWindowButton(window_id)
    if not taskbar_frame or window_buttons[window_id] then return end
    local wm = service.getService("wm")
    if not wm then return end
    local window = wm.getWindow(window_id)
    if not window then return end

    local tile = taskbar_frame:addFrame({
        x=1, y=1, width=TILE_WIDTH, height=TASKBAR_HEIGHT,
        background=theme("taskbar_bg"),
    })
    tile:setStateStyle("hover", {background=theme("surface")})
    tile:setStateStyle("pressed", {background=theme("surface")})
    local program = getWindowProgram(window)
    local image = icon.add(tile, program, {
        x=1, y=1,
        iconForeground=theme("icon_fg"),
        iconBackground=theme("taskbar_bg"),
        monochrome=true,
        variant="taskbar",
    })
    tile:onClick(function(source, button, x, y)
        if button == 1 then activateWindow(window_id)
        elseif button == 2 then openWindowMenu(source, x, y, window_id) end
    end)

    local record = {
        tile=tile, image=image, program=program,
        foreground=theme("icon_fg"), hovered=false,
    }
    local function setWindowHover(hovered)
        record.hovered = hovered
        record.tile:setState("hover", hovered)
        icon.update(
            record.image,
            record.program,
            record.foreground,
            hovered and theme("surface") or theme("taskbar_bg"),
            true,
            "taskbar"
        )
    end
    bindHover(tile, setWindowHover)
    bindHover(image, setWindowHover)

    window_buttons[window_id] = record
    api.private.repositionButtons()
    api.private.updateButtonStates(wm.getFocusedWindow())
    log.debug("TASKBAR", "Window icon added", {window_id=window_id, title=window.title})
end

function api.private.removeWindowButton(window_id)
    local record = window_buttons[window_id]
    if not record then return end
    record.tile:destroy()
    window_buttons[window_id] = nil
    api.private.repositionButtons()
end

function api.private.repositionButtons()
    if not taskbar_frame then return end
    local entries = {}
    for window_id, record in pairs(window_buttons) do
        entries[#entries + 1] = {id=window_id, record=record}
    end
    table.sort(entries, function(a, b) return a.id < b.id end)

    local available = math.max(
        0, taskbar_frame:getWidth() - TILE_STRIDE - clockReservedWidth()
    )
    local capacity = math.floor(available / TILE_STRIDE)
    for index, entry in ipairs(entries) do
        entry.record.tile:setPosition(TILE_STRIDE + 1 + (index - 1) * TILE_STRIDE, 1)
        entry.record.tile:setVisible(index <= capacity)
    end
end

function api.private.updateButtonStates(focused_window_id)
    local wm = service.getService("wm")
    for window_id, record in pairs(window_buttons) do
        local window = wm and wm.getWindow(window_id) or nil
        local minimized = window and (window.state == "minimized" or window.state == "minimizing"
            or not (window.frame and window.frame:getVisible()))

        if minimized then
            record.tile:setBackground(theme("taskbar_bg"))
            record.foreground = theme("taskbar_muted")
        elseif window_id == focused_window_id then
            record.tile:setBackground(theme("taskbar_bg"))
            record.foreground = theme("icon_active")
        else
            record.tile:setBackground(theme("taskbar_bg"))
            record.foreground = theme("icon_fg")
        end
        icon.update(
            record.image,
            record.program,
            record.foreground,
            record.hovered and theme("surface") or theme("taskbar_bg"),
            true,
            "taskbar"
        )
    end
end

function api.public.getHeight()
    return TASKBAR_HEIGHT
end

-- Usable coordinates within the desktop screen. Keeping this in the taskbar
-- service gives the WM and desktop one source of truth for reserved shell UI.
function api.public.getWorkArea()
    local ui = service.getService("ui")
    local desktop_frame = ui and ui.getScreen("desktop")
    if not desktop_frame then return nil end
    local width, height = desktop_frame:getSize()
    width = math.max(1, math.floor(tonumber(width) or 1))
    height = math.max(1, math.floor(tonumber(height) or 1) - TASKBAR_HEIGHT)
    return {x=1, y=1, width=width, height=height}
end

return api
