-- /services/contextmenu.lua
-- Public ContextMenu API backed by Basalt 2.5's native ContextMenu element.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")
local ui_helpers = require("core.ui_helpers")

local api = api_factory.new()

local function theme(key) return config.get("theme." .. key) end

local desktop_frame = nil
local active_menu = nil
local legacy_menu = nil
local menus = {}

-- Keep the pointer on the menu corner. When there is not enough room to the
-- right/below, open to the left/above instead of sliding the menu underneath
-- the pointer (which makes the pointer appear in the middle of the menu).
local function anchoredPosition(pointer, size, limit)
    pointer = math.floor(tonumber(pointer) or 1)
    size = math.max(1, math.floor(tonumber(size) or 1))
    limit = math.max(1, math.floor(tonumber(limit) or 1))
    if size >= limit then return 1 end
    if pointer + size - 1 > limit then pointer = pointer - size + 1 end
    return math.max(1, math.min(pointer, limit - size + 1))
end

-- Returns the desktop-local origin of a hosted application's terminal.
-- Elements inside a Basalt Program use coordinates relative to that terminal,
-- not relative to the OS desktop frame.
local function programOrigin(window_id)
    local wm = service.getService("wm")
    local window = wm and wm.getWindow(window_id) or nil
    local program = window and window.program_element or nil
    if not program or not program.getAbsolutePosition or not desktop_frame then return nil end
    local program_x, program_y = program:getAbsolutePosition()
    local desktop_x, desktop_y = desktop_frame:getAbsolutePosition()
    return program_x - desktop_x + 1, program_y - desktop_y + 1
end

local function removeMenu(controller)
    for i = #menus, 1, -1 do
        if menus[i] == controller then
            table.remove(menus, i)
            return
        end
    end
end

local function closeActive(except)
    if active_menu and active_menu ~= except then active_menu:close() end
end

local function normalizeItems(items)
    local labels = {}
    local definitions = {}
    for i, item in ipairs(items or {}) do
        local definition = type(item) == "table" and item or {label=tostring(item)}
        definitions[i] = definition
        if definition.separator then
            labels[i] = {separator=true}
        else
            local label = tostring(definition.label or definition.text or "")
            if definition.icon then label = tostring(definition.icon) .. " " .. label end
            labels[i] = {
                text=label,
                disabled=definition.disabled == true,
                fg=definition.disabled and theme("menu_muted") or nil,
            }
        end
    end
    return labels, definitions
end

function api.public.init()
    event.on("desktop.created", function()
        local ui = service.getService("ui")
        desktop_frame = ui and ui.getScreen("desktop") or nil
        active_menu = nil
        legacy_menu = nil
        menus = {}
        log.info("CONTEXTMENU", "Native ContextMenu API initialized")
    end)

    event.on("user.logout", function()
        api.public.closeAll()
        desktop_frame = nil
    end)

    event.on("theme.changed", function()
        api.public.closeAll()
    end)
end

-- Creates a reusable context-menu controller.
--
-- local menu = app.contextmenu.create({
--   { label="Open", action=function(item, index, menu) end },
--   { separator=true },
--   { label="Delete", action=deleteItem },
-- })
-- menu:open(x, y)             -- desktop-local coordinates
-- menu:openFor(element, x, y) -- element-local coordinates
function api.public.create(items, options)
    if not desktop_frame then return nil, "Desktop is not available" end
    options = options or {}

    local background = options.background or theme("menu_bg")
    local wrapper = desktop_frame:addFrame({
        x=1, y=1, width=3, height=3,
        background=background, visible=false,
        z=options.z or 1200,
    })
    local element = wrapper:addContextMenu({
        x=2, y=2,
        foreground = options.foreground or theme("menu_fg"),
        background = background,
        selectionForeground = options.selectionForeground or theme("text"),
        selectionBackground = options.selectionBackground or theme("primary"),
        separatorColor = options.separatorColor or theme("border"),
        z = 1,
    })
    ui_helpers.addBorder(wrapper, options.borderColor or theme("border"), {
        innerColor=background, name="contextmenu_border",
    })

    local controller = {
        element=element,
        wrapper=wrapper,
        definitions={},
        window_id=options.window_id,
    }

    local function resizeWrapper()
        if not element or not wrapper then return end
        local width, height = element:getSize()
        wrapper:setSize(width + 2, height + 2)
    end

    function controller:setItems(new_items)
        local labels, definitions = normalizeItems(new_items)
        self.definitions = definitions
        self.element:setItems(labels)
        resizeWrapper()
        return self
    end

    local function openAtDesktop(self, x, y)
        closeActive(self)
        resizeWrapper()
        local parent_width, parent_height = desktop_frame:getSize()
        local width, height = self.wrapper:getSize()
        x = math.floor(tonumber(x) or 1)
        y = math.floor(tonumber(y) or 1)
        x = anchoredPosition(x, width, parent_width)
        y = anchoredPosition(y, height, parent_height)
        self.wrapper:setPosition(x, y)
        self.wrapper:setVisible(true)
        self.element:openAt(2, 2)
        active_menu = self
        return self
    end

    function controller:open(x, y)
        if self.window_id then
            local origin_x, origin_y = programOrigin(self.window_id)
            if origin_x then
                return openAtDesktop(
                    self,
                    origin_x + (tonumber(x) or 1) - 1,
                    origin_y + (tonumber(y) or 1) - 1
                )
            end
        end
        return openAtDesktop(self, x, y)
    end

    function controller:openForWindow(window_id, source, x, y)
        if not source or not source.getAbsolutePosition then return self end
        local origin_x, origin_y = programOrigin(window_id)
        if not origin_x then return self end
        local source_x, source_y = source:getAbsolutePosition()
        return openAtDesktop(
            self,
            origin_x + source_x + (tonumber(x) or 1) - 2,
            origin_y + source_y + (tonumber(y) or 1) - 2
        )
    end

    function controller:openFor(source, x, y)
        if not source or not source.getAbsolutePosition then return self end
        if self.window_id then
            return self:openForWindow(self.window_id, source, x, y)
        end
        local source_x, source_y = source:getAbsolutePosition()
        local desktop_x, desktop_y = desktop_frame:getAbsolutePosition()
        return openAtDesktop(
            self,
            source_x - desktop_x + (tonumber(x) or 1),
            source_y - desktop_y + (tonumber(y) or 1)
        )
    end

    function controller:close()
        if self.element then self.element:close() end
        if self.wrapper then self.wrapper:setVisible(false) end
        if active_menu == self then active_menu = nil end
        return self
    end

    function controller:isOpen()
        return self.element ~= nil and self.wrapper ~= nil
            and self.element:getVisible() and self.wrapper:getVisible()
    end

    function controller:getElement()
        return self.element
    end

    function controller:destroy()
        self:close()
        if self.wrapper then self.wrapper:destroy() end
        self.element = nil
        self.wrapper = nil
        removeMenu(self)
    end

    element:onSelect(function(_, index)
        local definition = controller.definitions[index]
        if controller.wrapper then controller.wrapper:setVisible(false) end
        if active_menu == controller then active_menu = nil end
        if not definition or definition.separator or definition.disabled then return end
        if definition.action then
            local ok, err = pcall(definition.action, definition, index, controller)
            if not ok then
                log.error("CONTEXTMENU", "Menu action failed", {index=index, error=tostring(err)})
            end
        end
    end)
    element:on("blur", function()
        if controller.wrapper then controller.wrapper:setVisible(false) end
        if active_menu == controller then active_menu = nil end
    end)

    controller:setItems(items or {})
    menus[#menus + 1] = controller
    return controller
end

-- Compatibility convenience: reuses one service-owned menu.
local function getLegacyMenu(items, options)
    if not legacy_menu or not legacy_menu.element then
        local err
        legacy_menu, err = api.public.create(items, options)
        if not legacy_menu then return nil, err end
    else
        legacy_menu:setItems(items)
    end
    return legacy_menu
end

function api.public.open(x, y, items, options)
    local menu, err = getLegacyMenu(items, options)
    if not menu then return nil, err end
    return legacy_menu:open(x, y)
end

function api.public.openFor(source, x, y, items, options)
    local menu, err = getLegacyMenu(items, options)
    if not menu then return nil, err end
    return menu:openFor(source, x, y)
end

-- Opens a menu for an element inside a hosted application window. The source
-- coordinates are application-local and are translated through the WM's
-- Program element into desktop coordinates.
function api.public.openForWindow(window_id, source, x, y, items, options)
    local menu, err = getLegacyMenu(items, options)
    if not menu then return nil, err end
    return menu:openForWindow(window_id, source, x, y)
end

-- Window-aware variant of open() for callers that already have coordinates
-- relative to the application's terminal.
function api.public.openForWindowPoint(window_id, x, y, items, options)
    local menu, err = getLegacyMenu(items, options)
    if not menu then return nil, err end
    local origin_x, origin_y = programOrigin(window_id)
    if not origin_x then return nil, "Application window is unavailable" end
    return menu:open(origin_x + (tonumber(x) or 1) - 1,
        origin_y + (tonumber(y) or 1) - 1)
end

function api.public.close()
    if active_menu then active_menu:close() end
end

function api.public.closeAll()
    for i = #menus, 1, -1 do
        local menu = menus[i]
        if menu.wrapper then menu.wrapper:destroy() end
        menu.element = nil
        menu.wrapper = nil
    end
    menus = {}
    active_menu = nil
    legacy_menu = nil
end

function api.public.isOpen()
    return active_menu ~= nil and active_menu:isOpen()
end

return api
