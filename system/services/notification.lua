-- /services/notification.lua
-- Notification System: Custom toast notifications with border and dynamic sizing

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")

local api = api_factory.new()

local function theme(key) return config.get("theme." .. key) end

local active_toasts  = {}   -- id -> { frame, height, y }
local toast_history  = {}
local next_toast_id  = 1
local desktop_frame  = nil
local history_panel  = nil
local stack_bottom   = nil
local timer_to_toast = {}   -- timer_id -> toast_id (single persistent handler)

local TOAST_W            = 28
local TOAST_SPACING      = 1
local MAX_TOASTS         = 4
local DEFAULT_DURATION   = 3
local DEFAULT_DURATION_ERROR = 5

local TYPE_TITLE_BG = {
    info    = function() return theme("primary") end,
    success = function() return theme("success") end,
    warning = function() return theme("warning") end,
    error   = function() return theme("danger")  end,
}

local function initStack()
    local _, h = term.getSize()
    stack_bottom = h - 2  -- row above taskbar
end

local function countActive()
    local n = 0
    for _ in pairs(active_toasts) do n = n + 1 end
    return n
end

-- ── Toast creation ────────────────────────────────────────────────────────────

local function slideOut(id)
    local t = active_toasts[id]
    if not t then return end
    local screen_w, _ = term.getSize()
    t.frame:animate()
        :move(screen_w + 2, t.frame:getY(), 0.25, "easeInQuad")
        :onComplete(function()
            t.frame:destroy()
            active_toasts[id] = nil
            if countActive() == 0 then initStack() end
        end)
        :start()
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function api.public.init()
    event.on("desktop.created", function()
        local ui = service.getService("ui")
        if not ui then return end
        desktop_frame = ui.getScreen("desktop")
        initStack()
        api.private.createHistoryPanel()
        log.info("NOTIFICATION", "Service initialized")
    end)

    -- Single persistent timer handler for all toasts
    event.on("timer", function(t_id)
        local id = timer_to_toast[t_id]
        if id then
            timer_to_toast[t_id] = nil
            slideOut(id)
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

-- ── History panel ─────────────────────────────────────────────────────────────

function api.private.createHistoryPanel()
    if not desktop_frame then return end

    history_panel = desktop_frame:addFrame()
        :setPosition("{parent.width - 32}", 2)
        :setSize(32, "{parent.height - 3}")
        :setBackground(theme("secondary"))
        :setVisible(false)
    history_panel:addBorder(theme("border"), { top=true, bottom=true, left=true, right=true })
    history_panel:addVisualElement({ x=1, y=1, width=32, height=1, background=theme("primary") })
    history_panel:addLabel({ x=2, y=1, text="Notifications", foreground=theme("text"), background=theme("primary") })
    history_panel:addButton({
        x=31, y=1, width=1, height=1,
        text="X", background=theme("danger"), foreground=theme("text"),
    }):onClick(function() api.public.hideHistory() end)

    history_panel:addList()
        :setName("historyList")
        :setPosition(2, 3)
        :setSize(28, "{parent.height - 4}")
        :setBackground(theme("surface"))
        :setForeground(theme("text"))
end

local function updateHistoryPanel()
    if not history_panel then return end
    local list = history_panel:getChild("historyList")
    if not list then return end
    list:clear()
    local icons = { info=" i ", success=" \xfb ", warning=" ! ", error=" X " }
    for _, entry in ipairs(toast_history) do
        local icon = icons[entry.type] or "   "
        list:addItem(icon .. entry.title .. ": " .. entry.message:sub(1, 20), nil, theme("text"), theme("surface"))
    end
end

-- ── Toast creation (show) ─────────────────────────────────────────────────────

function api.public.show(title, message, toast_type, duration)
    if not desktop_frame then return nil end
    toast_type = toast_type or "info"
    duration   = duration or DEFAULT_DURATION

    if countActive() >= MAX_TOASTS then
        log.warn("NOTIFICATION", "Max toasts reached, dropping notification")
        return nil
    end

    local content_w = TOAST_W - 2
    local msg_lines = message and message ~= "" and math.max(1, math.ceil(#message / content_w)) or 0
    local height    = 1 + msg_lines + 1
    local screen_w, _ = term.getSize()

    local target_x = screen_w - TOAST_W
    local start_x  = screen_w + 2
    local toast_y  = stack_bottom - height + 1
    stack_bottom   = toast_y - TOAST_SPACING

    local id = next_toast_id
    next_toast_id = next_toast_id + 1

    local title_bg = (TYPE_TITLE_BG[toast_type] or TYPE_TITLE_BG.info)()

    local frame = desktop_frame:addFrame({
        x=start_x, y=toast_y,
        width=TOAST_W, height=height,
        background=theme("secondary"),
    })
    frame:addBorder(theme("border"), { bottom=true, left=true, right=true })
    frame:setZ(150)

    frame:addVisualElement({ x=1, y=1, width=TOAST_W, height=1, background=title_bg })
    frame:addLabel({ x=2, y=1, text=title:sub(1, TOAST_W-3), foreground=theme("text"), background=title_bg })

    if msg_lines > 0 then
        frame:addLabel({
            x=2, y=2, width=content_w,
            text=message, foreground=theme("text"), background=theme("secondary"),
            autoSize=false,
        })
    end

    active_toasts[id] = { frame=frame, height=height, y=toast_y }

    frame:animate()
        :move(target_x, toast_y, 0.3, "easeOutQuad")
        :start()

    local timer_id = os.startTimer(duration)
    timer_to_toast[timer_id] = id

    table.insert(toast_history, 1, {
        title=title, message=message or "", type=toast_type,
        timestamp=textutils.formatTime(os.time(), true),
    })
    if #toast_history > 50 then table.remove(toast_history) end
    updateHistoryPanel()

    log.debug("NOTIFICATION", "Toast shown", { id=id, type=toast_type, title=title })
    return id
end

-- ── Public API ────────────────────────────────────────────────────────────────

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

function api.public.clearAll()
    for id in pairs(active_toasts) do slideOut(id) end
end

function api.public.showHistory()
    if history_panel then history_panel:setVisible(true) end
end

function api.public.hideHistory()
    if history_panel then history_panel:setVisible(false) end
end

function api.public.toggleHistory()
    if history_panel then history_panel:setVisible(not history_panel:getVisible()) end
end

function api.public.getHistory()
    return toast_history
end

return api

