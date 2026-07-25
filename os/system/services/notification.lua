-- /services/notification.lua
-- Compact animated BasaltOS toast notifications and notification history.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")
local ui_helpers = require("core.ui_helpers")

local api = api_factory.new()

local function theme(key) return config.get("theme." .. key) end

local active_toasts = {}
local toast_history = {}
local next_toast_id = 1
local desktop_frame = nil
local history_panel = nil
local timer_to_toast = {}

local TOAST_MAX_WIDTH = 30
local TOAST_MIN_WIDTH = 18
local TOAST_SPACING = 1
local MAX_TOASTS = 4
local MAX_MESSAGE_LINES = 3
local DEFAULT_DURATION = 3
local DEFAULT_DURATION_ERROR = 5

local TYPE_STYLE = {
    info = { marker="i", color=function() return theme("primary") end },
    success = { marker="+", color=function() return theme("success") end },
    warning = { marker="!", color=function() return theme("warning") end },
    error = { marker="x", color=function() return theme("danger") end },
}

local function fitText(value, width)
    local text = tostring(value or "")
    width = math.max(0, math.floor(tonumber(width) or 0))
    if #text <= width then return text end
    if width <= 2 then return (".."):sub(1, width) end
    return text:sub(1, width - 2) .. ".."
end

local function wrapText(value, width, max_lines)
    local lines = {}
    local text = tostring(value or "")
    width = math.max(1, width)

    for raw_line in (text .. "\n"):gmatch("(.-)\n") do
        if raw_line == "" then
            if #lines > 0 then lines[#lines + 1] = "" end
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
            if remaining ~= "" then lines[#lines + 1] = remaining end
        end
    end

    if max_lines and #lines > max_lines then
        while #lines > max_lines do table.remove(lines) end
        lines[#lines] = fitText(lines[#lines] .. "..", width)
    end
    return lines
end

local function getScreenSize()
    if desktop_frame then return desktop_frame:getSize() end
    return term.getSize()
end

local function countActive()
    local count = 0
    for _, toast in pairs(active_toasts) do
        if not toast.closing then count = count + 1 end
    end
    return count
end

local function sortedActiveIds()
    local ids = {}
    for id, toast in pairs(active_toasts) do
        if not toast.closing then ids[#ids + 1] = id end
    end
    table.sort(ids, function(a, b) return a > b end)
    return ids
end

local function reflowToasts(animated)
    if not desktop_frame then return end
    local screen_width, screen_height = getScreenSize()
    local bottom = screen_height - 2

    for _, id in ipairs(sortedActiveIds()) do
        local toast = active_toasts[id]
        local target_x = screen_width - toast.width
        local target_y = bottom - toast.height + 1
        bottom = target_y - TOAST_SPACING
        toast.y = target_y

        if animated then
            toast.frame:animate({x=target_x, y=target_y}, 0.22, "easeOut")
        else
            toast.frame:setPosition(target_x, target_y)
        end
    end
end

local function removeTimer(toast)
    if toast and toast.timer_id then
        timer_to_toast[toast.timer_id] = nil
        toast.timer_id = nil
    end
end

local function slideOut(id)
    local toast = active_toasts[id]
    if not toast or toast.closing then return false end
    toast.closing = true
    removeTimer(toast)

    local screen_width = getScreenSize()
    toast.frame:animate({x=screen_width + 2, y=toast.frame:getY()}, 0.2, "easeIn", function()
        if toast.frame then toast.frame:destroy() end
        active_toasts[id] = nil
        reflowToasts(true)
    end)
    return true
end

local function removeOldestToast()
    local oldest_id = nil
    for id, toast in pairs(active_toasts) do
        if not toast.closing and (not oldest_id or id < oldest_id) then oldest_id = id end
    end
    if not oldest_id then return end
    local toast = active_toasts[oldest_id]
    removeTimer(toast)
    if toast.frame then toast.frame:destroy() end
    active_toasts[oldest_id] = nil
end

local function trimStackToScreen()
    local _, screen_height = getScreenSize()
    local available_height = math.max(3, screen_height - 3)

    while true do
        local total_height = 0
        local ids = sortedActiveIds()
        for index, id in ipairs(ids) do
            total_height = total_height + active_toasts[id].height
            if index > 1 then total_height = total_height + TOAST_SPACING end
        end
        if total_height <= available_height or #ids <= 1 then return end
        removeOldestToast()
    end
end

local function resetTransientState()
    for _, toast in pairs(active_toasts) do
        removeTimer(toast)
        if toast.frame then toast.frame:destroy() end
    end
    active_toasts = {}
    timer_to_toast = {}
    history_panel = nil
end

function api.public.init()
    event.on("desktop.created", function()
        local ui = service.getService("ui")
        if not ui then return end
        resetTransientState()
        desktop_frame = ui.getScreen("desktop")
        api.private.createHistoryPanel()
        log.info("NOTIFICATION", "Modern toast service initialized")
    end)

    event.on("timer", function(timer_id)
        local id = timer_to_toast[timer_id]
        if id then
            timer_to_toast[timer_id] = nil
            slideOut(id)
        end
    end)

    event.on("user.logout", function()
        resetTransientState()
        desktop_frame = nil
    end)

    event.on("theme.changed", function()
        if history_panel then
            history_panel:destroy()
            history_panel = nil
        end
        if desktop_frame then
            api.private.createHistoryPanel()
        end
    end)

    event.on("basaltshell.ready", function()
        local shell = service.getService("basaltshell")
        if shell then
            shell.registerBuiltin("notify", function(args)
                if #args == 0 then return false, "Usage: notify <message>" end
                api.public.info("Shell", table.concat(args, " "))
                return true, nil
            end)
        end
    end)
end

function api.private.createHistoryPanel()
    if not desktop_frame then return end
    local screen_width = desktop_frame:getWidth()
    local panel_width = math.max(20, math.min(32, screen_width - 2))

    history_panel = desktop_frame:addFrame({
        x=screen_width - panel_width,
        y=2,
        width=panel_width,
        height="{parent.height - 3}",
        background=theme("desktop_bg"),
        visible=false,
        z=850,
    })
    ui_helpers.addBorder(history_panel, theme("primary"), {
        innerColor=theme("desktop_bg"), topStyle="solid", name="notification_history_border",
    })
    history_panel:addFrame({
        x=1, y=1, width=panel_width, height=1,
        background=theme("primary"), disabled=true,
    })
    history_panel:addLabel({
        x=2, y=1, text="Notifications",
        foreground=theme("text"), background=theme("primary"), disabled=true,
    })
    history_panel:addButton({
        x=panel_width - 7, y=1, width=5, height=1,
        text="Clear", background=theme("primary"), foreground=theme("text"),
    }):setStateStyle("hover", {
        background=theme("warning"), foreground=theme("text_on_light"),
    }):onClick(function() api.public.clearHistory() end)
    history_panel:addButton({
        x=panel_width - 1, y=1, width=1, height=1,
        text="x", background=theme("primary"), foreground=theme("text"),
    }):setStateStyle("hover", {
        background=theme("danger"), foreground=theme("text"),
    }):onClick(function() api.public.hideHistory() end)

    history_panel:addList({
        name="historyList",
        x=2, y=3,
        width=panel_width - 2,
        height="{parent.height - 4}",
        background=theme("desktop_bg"),
        foreground=theme("desktop_fg"),
    })
end

local function updateHistoryPanel()
    if not history_panel then return end
    local list = history_panel:find("historyList")
    if not list then return end
    list:clear()
    local panel_width = history_panel:getWidth()

    if #toast_history == 0 then
        list:addItem({
            text=" No notifications",
            fg=theme("desktop_muted"), bg=theme("desktop_bg"),
        })
        return
    end

    for _, entry in ipairs(toast_history) do
        local style = TYPE_STYLE[entry.type] or TYPE_STYLE.info
        local text = style.marker .. " " .. entry.timestamp .. " " .. entry.title
        if entry.message ~= "" then text = text .. " - " .. entry.message end
        list:addItem({
            text=fitText(text, panel_width - 3),
            fg=style.color(), bg=theme("desktop_bg"),
        })
    end
end

function api.public.show(title, message, toast_type, duration)
    if not desktop_frame then return nil end
    title = tostring(title or "Notification")
    message = tostring(message or "")
    toast_type = TYPE_STYLE[toast_type] and toast_type or "info"
    duration = tonumber(duration) or DEFAULT_DURATION

    if countActive() >= MAX_TOASTS then removeOldestToast() end

    local screen_width, screen_height = getScreenSize()
    local width = math.max(TOAST_MIN_WIDTH, math.min(TOAST_MAX_WIDTH, screen_width - 2))
    local content_width = math.max(4, width - 5)
    local lines = wrapText(message, content_width, MAX_MESSAGE_LINES)
    local height = math.max(4, #lines + 3)
    local style = TYPE_STYLE[toast_type]
    local id = next_toast_id
    next_toast_id = next_toast_id + 1

    local frame = desktop_frame:addFrame({
        x=screen_width + 2,
        y=math.max(2, screen_height - height - 1),
        width=width,
        height=height,
        background=theme("desktop_bg"),
        z=800,
    })
    frame:addLabel({
        x=3, y=2, text=style.marker,
        foreground=style.color(), background=theme("desktop_bg"), disabled=true,
    })
    frame:addLabel({
        x=5, y=2, width=width - 8, height=1,
        text=fitText(title, width - 8),
        foreground=theme("desktop_fg"), background=theme("desktop_bg"), disabled=true,
    })
    frame:addButton({
        x=width - 1, y=2, width=1, height=1,
        text="x", background=theme("desktop_bg"), foreground=theme("desktop_muted"),
    }):setStateStyle("hover", {
        background=theme("danger"), foreground=theme("text"),
    }):onClick(function() slideOut(id) end)

    for index, line in ipairs(lines) do
        frame:addLabel({
            x=3, y=2 + index, width=content_width, height=1,
            text=line, foreground=theme("desktop_muted"),
            background=theme("desktop_bg"), disabled=true,
        })
    end

    ui_helpers.addBorder(frame, style.color(), {
        innerColor=theme("desktop_bg"), name="toast_border",
    })

    active_toasts[id] = {
        frame=frame, width=width, height=height, y=frame:getY(), closing=false,
    }
    trimStackToScreen()
    reflowToasts(true)

    if duration > 0 then
        local timer_id = os.startTimer(duration)
        active_toasts[id].timer_id = timer_id
        timer_to_toast[timer_id] = id
    end

    table.insert(toast_history, 1, {
        title=title,
        message=message,
        type=toast_type,
        timestamp=textutils.formatTime(os.time(), true),
    })
    if #toast_history > 50 then table.remove(toast_history) end
    updateHistoryPanel()

    log.debug("NOTIFICATION", "Toast shown", {id=id, type=toast_type, title=title})
    return id
end

function api.public.info(title, message, duration)
    return api.public.show(title, message, "info", duration)
end

function api.public.success(title, message, duration)
    return api.public.show(title, message, "success", duration)
end

function api.public.warning(title, message, duration)
    return api.public.show(title, message, "warning", duration)
end

function api.public.error(title, message, duration)
    return api.public.show(title, message, "error", duration or DEFAULT_DURATION_ERROR)
end

function api.public.dismiss(id)
    return slideOut(id)
end

function api.public.clearAll()
    local ids = {}
    for id in pairs(active_toasts) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do slideOut(id) end
end

function api.public.clearHistory()
    toast_history = {}
    updateHistoryPanel()
end

function api.public.showHistory()
    if history_panel then
        updateHistoryPanel()
        history_panel:setVisible(true)
        history_panel:focus()
    end
end

function api.public.hideHistory()
    if history_panel then history_panel:setVisible(false) end
end

function api.public.toggleHistory()
    if not history_panel then return end
    if history_panel:getVisible() then api.public.hideHistory()
    else api.public.showHistory() end
end

function api.public.getHistory()
    return toast_history
end

return api
