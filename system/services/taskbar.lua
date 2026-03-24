-- /services/taskbar.lua
-- Taskbar: Shows running programs at bottom of screen

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")

local function theme(key) return config.get("theme." .. key) end

local api = api_factory.new()

local taskbar_frame = nil
local window_buttons = {} -- window_id -> button

local TASKBAR_HEIGHT = 1
local BUTTON_WIDTH = 12

function api.public.init()
    event.on("desktop.created", function(username)
        api.private.createTaskbar()
    end)

    event.on("user.logout", function()
        api.private.destroyTaskbar()
    end)

    event.on("wm.window_created", function(window_id, pid)
        api.private.addWindowButton(window_id)
    end)

    event.on("wm.window_closed", function(window_id, pid)
        api.private.removeWindowButton(window_id)
    end)

    event.on("wm.window_focused", function(window_id)
        api.private.updateButtonStates(window_id)
    end)
end

function api.private.createTaskbar()
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
        x = 1,
        y = "{parent.height}",
        width = "{parent.width}",
        height = TASKBAR_HEIGHT,
        background = theme("secondary"),
        z = 1000 -- ensure taskbar is above other elements
    })

    taskbar_frame:addButton({
        x = 1,
        y = 1,
        width = 10,
        height = 1,
        text = "BasaltOS",
        foreground = theme("text"),
        background = theme("primary")
    }):setBackgroundState("clicked", theme("btn_clicked"))
    :setForegroundState("clicked", theme("text"))
    :onClickUp(function()
        local startmenu = service.getService("startmenu")
        if startmenu then
            startmenu.toggle()
        else
            log.error("TASKBAR", "Startmenu service not available")
        end
    end)

    local clock_label = taskbar_frame:addLabel({
        x = "{parent.width - 7}",
        y = 1,
        width = 8,
        height = 1,
        text = os.date("%H:%M:%S"),
        foreground = theme("text_dim"),
        background = theme("secondary")
    })

    local function updateClock()
        if clock_label then
            clock_label:setText(os.date("%H:%M:%S"))
        end
    end

    local function clockTimer()
        while taskbar_frame do
            updateClock()
            os.sleep(1)
        end
    end
    
    -- Run clock in background (TODO: proper background task)
    
    log.info("TASKBAR", "Taskbar created")
end

function api.private.destroyTaskbar()
    if taskbar_frame then
        taskbar_frame:remove()
        taskbar_frame = nil
    end

    window_buttons = {}
    log.info("TASKBAR", "Taskbar destroyed")
end

function api.private.addWindowButton(window_id)
    if not taskbar_frame then
        return
    end

    local wm = service.getService("wm")
    if not wm then
        return
    end

    local window = wm.getWindow(window_id)
    if not window then
        return
    end

    local button_count = 0
    for _ in pairs(window_buttons) do
        button_count = button_count + 1
    end

    local button_x = 12 + (button_count * (BUTTON_WIDTH + 1))

    local button = taskbar_frame:addButton({
        x = button_x,
        y = 1,
        width = BUTTON_WIDTH,
        height = 1,
        text = window.title:sub(1, BUTTON_WIDTH - 1),
        foreground = theme("text"),
        background = theme("surface")
    })

    local captured_window_id = window_id
    button:onClick(function()
        local current_window = wm.getWindow(captured_window_id)
        if not current_window or not current_window.frame then
            log.warn("TASKBAR", "Window not found on click", {window_id = captured_window_id})
            return
        end

        local is_focused = (wm.getFocusedWindow() == captured_window_id)

        local is_visible = current_window.frame:getVisible()

        if is_visible and is_focused then
            wm.minimizeWindow(captured_window_id)
            log.debug("TASKBAR", "Window minimized", {window_id = captured_window_id})
        else
            if not is_visible then
                wm.restoreWindow(captured_window_id)
                log.debug("TASKBAR", "Window restored", {window_id = captured_window_id})
            else
                wm.focusWindow(captured_window_id)
                log.debug("TASKBAR", "Window focused", {window_id = captured_window_id})
            end
        end
    end)

    window_buttons[window_id] = button

    log.debug("TASKBAR", "Window button added", {window_id = window_id, title = window.title})
end

function api.private.removeWindowButton(window_id)
    local button = window_buttons[window_id]

    if button then
        button:destroy()
        window_buttons[window_id] = nil

        api.private.repositionButtons()

        log.debug("TASKBAR", "Window button removed", {window_id = window_id})
    end
end

function api.private.repositionButtons()
    if not taskbar_frame then
        return
    end

    local buttons = {}
    for window_id, button in pairs(window_buttons) do
        table.insert(buttons, {id = window_id, button = button})
    end

    table.sort(buttons, function(a, b) return a.id < b.id end)

    for i, entry in ipairs(buttons) do
        local button_x = 12 + ((i - 1) * (BUTTON_WIDTH + 1))
        entry.button:setPosition(button_x, 1)
    end
end

function api.private.updateButtonStates(focused_window_id)
    for window_id, button in pairs(window_buttons) do
        if window_id == focused_window_id then
            button:setBackground(theme("primary"))
        else
            button:setBackground(theme("surface"))
        end
    end
end

return api
