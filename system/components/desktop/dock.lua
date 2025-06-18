local utils = require("libraries.public.utils")
local path = require("libraries.public.path")
local logger = require("libraries.public.logger")
local colorHex = require("libraries.public.utils").tHex
local configs = require("libraries.private.configs")

local icon = {}
icon.__index = icon

function icon.new(app, dock)
    local self = setmetatable({}, icon)
    self.dock = dock
    self.app = app
    self.process = nil
    self.pinned = false
    self.bimg = utils.loadBimg(path.resolve(app.manifest.icon or "{assets}/icons/default.bimg"))
    self.iconElement = self.dock.frame:addImage()
        self.iconElement:setPosition(#self.dock.apps * 4 + 2, 1)
        self.iconElement:setSize(3, 2)
        self.iconElement:setBimg(self.bimg)
        self.iconElement:onClick(function(_, button, x, y)
            if button == 1 then
                if not self.process or not self.process.window then
                    local processManager = require("libraries.private.processManager")
                    self.process = processManager.create(dock.desktop, self.app)
                    if self.process then
                        self.process.dockIcon = self
                        self.process:run()
                        if self.process.window then
                            self:updateStatus("maximized")
                        end
                    end
                else
                    if self.process.window:getStatus() == "maximized" then
                        self:updateStatus("minimized")
                        self.process.window:minimize()
                    else
                        self:updateStatus("maximized")
                        self.process.window:restore()
                    end
                end
            end
        end)
        self.iconElement:onClickUp(function(_, button, x, y)
            if button == 2 then
                self:openContextMenu()
            end
        end)
    return self
end

function icon:openContextMenu()
    local menu = self.dock.desktop.frame:addFrame()
    menu:setBackground(colors.lightGray)
    menu:setZ(200)
    menu:setWidth(10)

    local frameCanvas = menu:getCanvas()
    frameCanvas:addCommand(function(_self)
        local width, height = _self.get("width"), _self.get("height")
        local bg = _self.get("background")
        local borderColor = configs.get("windows", "primaryColor")

        _self:textFg(1, 1, ("\131"):rep(width), borderColor)
        _self:blit(1, height, ("\143"):rep(width), colorHex[bg]:rep(width), colorHex[borderColor]:rep(width))
        for i = 1, height-1 do
            _self:blit(1, i, ("\149"), colorHex[borderColor], colorHex[bg])
            _self:blit(width, i, ("\149"), colorHex[bg], colorHex[borderColor])
        end
        _self:blit(1, 1, "\151", colorHex[borderColor], colorHex[bg])
        _self:blit(width, 1, "\148", colorHex[bg], colorHex[borderColor])
        _self:blit(1, height, "\138", colorHex[bg], colorHex[borderColor])
        _self:blit(width, height, "\133", colorHex[bg], colorHex[borderColor])
    end)

    local menuItems = {}

    if self.pinned then
        table.insert(menuItems, {
            text = "Unpin",
            action = function()
                self:setPinned(false)
                menu:destroy()
                -- Force remove if no process is running
                if not self.process then
                    if self.iconElement then
                        self.iconElement:destroy()
                    end
                    self.dock:removeIcon(self)
                end
            end
        })
    else
        table.insert(menuItems, {
            text = "Pin",
            action = function()
                self:setPinned(true)
            end
        })
    end

    if self.process and self.process.window then
        table.insert(menuItems, {
            text = "Close",
            action = function()
                self.process:stop()
            end
        })
    end

    if self.process and self.process.window then
        table.insert(menuItems, {
            text = "Restart",
            action = function()
                if self.process.window.restart then
                    self.process.window:restart()
                end
            end
        })
    end

    for i, item in ipairs(menuItems) do
        local menuButton = menu:addButton()
        menuButton:setPosition(2, i + 1)
        menuButton:setSize(8, 1)
        menuButton:setText(item.text)
        menuButton:setBackground(colors.lightGray)
        menuButton:setForeground(colors.black)
        menuButton:onClick(function()
            item.action()
            if item.text ~= "Unpin" then -- Unpin handles its own menu closing
                menu:destroy()
            end
        end)
    end

    local function closeMenu()
        if menu then
            menu:setVisible(false)
            menu = nil
        end
    end

    local xOffset = self.iconElement.x - 1
    local yOffset = self.dock.frame:getY() - 3 - #menuItems
    menu:setHeight(#menuItems + 2)

    menu:setPosition(xOffset, yOffset)
    menu:setFocused(true)
    menu:onBlur(closeMenu)
end

function icon:updateStatus(status)
    if self.iconElement then
        local canvas = self.iconElement:getCanvas()
        if self.canvasId then
            canvas:removeCommand(self.canvasId)
            self.canvasId = nil
        end
        if status == "maximized" then
            self.canvasId = canvas:text(1, 3, "\136\140\132", colors.lightGray)
        elseif status == "minimized" then
            self.canvasId = canvas:text(2, 3, "\7", colors.lightGray)
        elseif status == "closed" and self.pinned then
            -- Leave empty for now - just shows the normal icon
        end
        self.iconElement:updateRender()
    end
end

function icon:remove()
    if self.process then
        self.process.dockIcon = nil
        self.process = nil
    end

    if not self.pinned then
        if self.iconElement then
            self.iconElement:destroy()
        end
        self.dock:removeIcon(self)
    else
        self:updateStatus("closed")
    end
end

function icon:setPinned(pinned)
    self.pinned = pinned
end

local dock = {}
dock.__index = dock

function dock.new(desktop)
    local self = setmetatable({}, dock)
    self.apps = {}
    self.desktop = desktop
    self.frame = desktop.frame:addFrame()
    self.frame:setPosition(3, "{parent.height-2}")
    self.frame:setSize("{parent.width-4}", 3)
    self.frame:setZ(100)
    self.frame:setBackground(colors.white)
    self.frame:setForeground(colors.black)
    self.frame:setBackgroundEnabled(false)
    self.frame:addVisualElement()
    :setSize("{parent.width}", 2)
    :setBackground(colors.gray)
    :setPosition(1, 2)
    return self
end

function dock:getPinnedApp(app)
    for _, pinnedApp in pairs(self.apps) do
        if pinnedApp.app.manifest.name == app.manifest.name then
            return pinnedApp
        end
    end
end

function dock:add(app)
    local existingIcon = self:getPinnedApp(app)
    if existingIcon then
        return existingIcon
    else
        local dockIcon = icon.new(app, self)
        table.insert(self.apps, dockIcon)
        self:repositionIcons()
        return dockIcon
    end
end

function dock:removeIcon(iconToRemove)
    for i, icon in ipairs(self.apps) do
        if icon == iconToRemove then
            table.remove(self.apps, i)
            self:repositionIcons()
            break
        end
    end
end

function dock:repositionIcons()
    for i, icon in ipairs(self.apps) do
        if icon.iconElement then
            icon.iconElement:setPosition(i * 4 - 2, 1)
        end
    end
end

return dock