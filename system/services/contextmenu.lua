-- /services/contextmenu.lua
-- Context Menu Service: Dynamic right-click context menus

local api_factory = require("core.api")
local event       = require("core.event")
local service     = require("core.service")
local log         = require("core.log")
local config      = require("core.config")

local api = api_factory.new()

local function theme(key) return config.get("theme." .. key) end

local desktop_frame  = nil
local active_menu    = nil   -- { frame, x, y, w, h, close_listener }

local MIN_W   = 16
local MAX_W   = 32
local PADDING = 2   -- left padding for item text

-- ── Init ──────────────────────────────────────────────────────────────────────

function api.public.init()
    event.on("desktop.created", function()
        local ui = service.getService("ui")
        if not ui then return end
        desktop_frame = ui.getScreen("desktop")
        log.info("CONTEXTMENU", "Service initialized")
    end)
end

-- ── Core ──────────────────────────────────────────────────────────────────────

local function close()
    if not active_menu then return end
    active_menu.frame:destroy()
    active_menu = nil
end

-- items: array of tables, each one of:
--   { label = "Text",  action = function() end }          normal item
--   { label = "Text",  action = fn, icon = "\x10" }       item with icon
--   { label = "Text",  disabled = true }                  greyed out, no action
--   { separator = true }                                   horizontal line
--
-- x, y: screen position where the menu should appear (1-based)
function api.public.open(x, y, items)
    if not desktop_frame then return end
    if active_menu then close() end
    if not items or #items == 0 then return end

    -- Calculate dimensions
    local screen_w, screen_h = desktop_frame:getSize()
    local max_label = MIN_W
    for _, item in ipairs(items) do
        if not item.separator then
            local lbl = (item.icon and (item.icon .. " ") or "") .. (item.label or "")
            max_label = math.max(max_label, #lbl + PADDING * 2)
        end
    end
    local w = math.min(max_label, MAX_W)
    local h = #items + 2  -- top + bottom border rows

    -- Keep menu on screen
    local mx = math.min(x, screen_w - w)
    local my = math.min(y, screen_h - h)
    if mx < 1 then mx = 1 end
    if my < 1 then my = 1 end

    -- Build frame
    local frame = desktop_frame:addFrame({
        x=mx, y=my,
        width=w, height=h,
        -- Use the same surface bg as windows use for content
        background=theme("surface"),
    })
    frame:addBorder(theme("border"), { top=true, bottom=true, right=true, left=true })
    frame:setZ(400)

    -- Populate items
    for i, item in ipairs(items) do
        local row = i + 1  -- +1 to account for the top strip

        if item.separator then
            -- Horizontal rule
            frame:addLabel({
                x=PADDING, y=row, width=w - PADDING, height=1,
                text = ("\140"):rep(w - PADDING),
                foreground = theme("border"),
                background = theme("surface"),
            })
        elseif item.disabled then
            local lbl = (item.icon and (item.icon .. " ") or "") .. (item.label or "")
            frame:addLabel({
                x=PADDING, y=row,
                text=lbl:sub(1, w - PADDING),
                foreground=theme("text_dim"),
                background=theme("secondary"),
            })
        else
            local lbl = (item.icon and (item.icon .. " ") or "") .. (item.label or "")
            local btn = frame:addButton({
                x=PADDING, y=row, width=w - PADDING, height=1,
                text=" " .. lbl:sub(1, w - 2),
                background=theme("surface"),
                foreground=theme("text"),
            })
            btn:setBackgroundState("hover",   theme("primary"))
            btn:setForegroundState("hover",   theme("text"))
            btn:setBackgroundState("clicked", theme("btn_clicked"))
            local action = item.action
            btn:onClick(function()
                close()
                if action then action() end
            end)
        end
    end

    frame:onBlur(function()
        close()
    end)
    frame:setFocused(true)

    active_menu = { frame=frame, x=mx, y=my, w=w, h=h }
    log.debug("CONTEXTMENU", "Opened menu", { x=mx, y=my, items=#items })
end

function api.public.close()
    close()
end

function api.public.isOpen()
    return active_menu ~= nil
end

return api
