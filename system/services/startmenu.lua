-- /services/startmenu.lua
-- Start menu service: Application launcher popup

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")

local function theme(key) return config.get("theme." .. key) end

local api = api_factory.new()

local menu_frame = nil
local is_open = false

function api.public.init()
    log.debug("STARTMENU", "Start menu service initialized")
end

function api.public.show()
    if is_open then
        log.debug("STARTMENU", "Menu already open, closing instead")
        api.public.hide()
        return
    end

    local ui = service.getService("ui")
    if not ui then
        log.error("STARTMENU", "UI service not available")
        return
    end

    local desktop_frame = ui.getScreen("desktop")
    if not desktop_frame then
        log.error("STARTMENU", "Desktop frame not available")
        return
    end

    api.private.createMenu(desktop_frame)
    if menu_frame then
        menu_frame:setFocused(true)
    end
    is_open = true
    log.debug("STARTMENU", "Start menu opened")
end

function api.public.hide()
    if menu_frame then
        local screen_w, screen_h = term.getSize()
        local frame = menu_frame
        menu_frame = nil
        is_open = false
        frame:animate()
            :move(1, screen_h + 1, 0.15)
            :onComplete(function()
                frame:destroy()
            end)
            :start()
    end
    is_open = false
    log.debug("STARTMENU", "Start menu closed")
end

function api.public.toggle()
    if is_open then
        api.public.hide()
    else
        api.public.show()
    end
end

function api.private.createMenu(parent_frame)
    local process = service.getService("process")

    if not process then
        log.error("STARTMENU", "Process service not available")
        return
    end

    local MENU_W = 22
    local MENU_H = 12
    local screen_w, screen_h = term.getSize()
    local target_y = screen_h - MENU_H  -- target position (above taskbar)

    menu_frame = parent_frame:addFrame()
        :setPosition(1, screen_h + 1)   -- start off-screen below
        :setSize(MENU_W, MENU_H)
        :setBackground(theme("secondary"))
        :setZ(100)

    -- Slide up animation
    menu_frame:animate()
        :move(1, target_y, 0.2)
        :start()

    menu_frame:onBlur(function()
        if is_open then
            api.public.hide()
        end
    end)

    -- Header
    menu_frame:addVisualElement({
        x = 1, y = 1,
        width = MENU_W, height = 1,
        background = theme("primary"),
    })
    menu_frame:addLabel({
        x = 2, y = 1,
        text = "BasaltOS",
        foreground = theme("text"),
        background = theme("primary"),
    })

    -- Divider
    menu_frame:addLabel({
        x = 1, y = 2,
        text = string.rep("\140", MENU_W),
        foreground = theme("text_dim"),
        background = theme("secondary"),
    })

    -- Pinned apps
    local pinned = {
        { label = "App Launcher", id = "launcher" },
        { label = "Settings",     id = "settings" },
        { label = "Terminal",     id = "basaltterminal" },
    }

    for i, item in ipairs(pinned) do
        local btn = menu_frame:addButton({
            x = 1, y = 2 + i,
            width = MENU_W, height = 1,
            text = " " .. item.label,
            background = theme("secondary"),
            foreground = theme("text"),
        })
        btn:setBackgroundState("hover", theme("surface"))
        btn:setForegroundState("hover", theme("text_on_light"))
        btn:setBackgroundState("clicked", theme("btn_clicked"))
        btn:setForegroundState("clicked", theme("text"))
        btn:onClick(function()
            local pid, err = process.startProgram(item.id)
            if not pid then
                log.error("STARTMENU", "Failed to start " .. item.id, {error = err})
            end
            api.public.hide()
        end)
    end

    -- Divider before actions
    menu_frame:addLabel({
        x = 1, y = MENU_H - 2,
        text = string.rep("\140", MENU_W),
        foreground = theme("text_dim"),
        background = theme("secondary"),
    })

    -- Logout button
    local logout_btn = menu_frame:addButton({
        x = 1, y = MENU_H - 1,
        width = MENU_W, height = 1,
        text = " Logout",
        background = theme("secondary"),
        foreground = theme("text"),
    })
    logout_btn:setBackgroundState("hover", theme("danger"))
    logout_btn:setBackgroundState("clicked", theme("btn_clicked"))
    logout_btn:onClick(function()
        api.public.hide()
        local auth = service.getService("auth")
        if auth then auth.logout() end
    end)

    -- Shutdown button
    local shutdown_btn = menu_frame:addButton({
        x = 1, y = MENU_H,
        width = MENU_W, height = 1,
        text = " Shutdown",
        background = theme("secondary"),
        foreground = theme("text"),
    })
    shutdown_btn:setBackgroundState("hover", theme("danger"))
    shutdown_btn:setBackgroundState("clicked", theme("btn_clicked"))
    shutdown_btn:onClick(function()
        api.public.hide()
        os.shutdown()
    end)
end

return api
