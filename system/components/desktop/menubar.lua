local basalt = require("libraries.public.basalt")
local configs = require("libraries.private.configs")
local colorHex = require("libraries.public.utils").tHex

local menubar = {}
menubar.__index = menubar

-- Needs a rework, make clock a global element
function menubar.new(desktop)
    local self = setmetatable({}, menubar)
    self.desktop = desktop
    self.menubar = desktop.frame:addFrame({z=100, width="{parent.width}", height=1})
    self.menubar:setBackground(colors.gray)
    self.menubar:setForeground(colors.white)
    self.curWindow = nil
    self.lastWindow = nil
    self.startMenuOpen = false
    
    self.programMenubar = self.menubar:addFrame({
        width="{parent.width - 16}",
        x = 10,
        height=1,
        background = "{parent.background}"
    })


    local date = desktop.frame:addLabel():setVisible(false)
    date:setBackground(colors.gray)
    date:setPosition("{parent.width - #self.text}", 2)
    local clock = self.menubar:addLabel()
    clock:setPosition("{parent.width - #self.text}", 1)
    clock:onClick(function()
        basalt.schedule(function()
            if(date:getVisible()) then
                date:setVisible(false)
                return
            end
            date:setVisible(true)
            date:setText(os.date("%A, %B %d, %Y"))
            sleep(5)
            date:setVisible(false)
        end)
    end)

    basalt.schedule(function()
        while true do
            local time = os.date("%H:%M")
            clock:setText(time)
            sleep(20) -- Update clock every 20 seconds
        end
    end)

    local logo = self.menubar:addLabel({text="BasaltOS"}):onClick(function()
        self:toggleStartMenu()
    end)

    local canvas = logo:getCanvas()
    canvas:addCommand(function(self)
        self:blit(1, 1, "BasaltOS", "e145d9bb", "77777777")
    end)

    return self
end

function menubar:createStartMenu()
    if self.startMenu then
        return
    end

    self.startMenu = self.desktop.frame:addFrame()
    self.startMenu:setSize(15, 8)
    self.startMenu:setPosition(1, 2)
    self.startMenu:setBackground(colors.lightGray)
    self.startMenu:setZ(50)

    local frameCanvas = self.startMenu:getCanvas()
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

    local menuItems = {
        {
            text = "App Launcher",
            action = function()
                self.desktop:openApp("AppLauncher")
                self:closeStartMenu()
            end
        },
        {
            text = "File Manager",
            action = function()
                self.desktop:openApp("Finder")
                self:closeStartMenu()
            end
        },
        {
            text = "Settings",
            action = function()
                -- TODO: Open Settings app when created
                local BasaltOS = require("basaltos")
                BasaltOS.notify("Settings not yet available", 3)
                self:closeStartMenu()
            end
        },
        {
            text = "separator"
        },
        {
            text = "Restart",
            action = function()
                self:showPowerDialog("restart")
            end
        },
        {
            text = "Shutdown",
            action = function()
                self:showPowerDialog("shutdown")
            end
        }
    }

    local currentY = 2
    for _, item in ipairs(menuItems) do
        if item.text == "separator" then
            local separator = self.startMenu:addLabel()
            separator:setPosition(2, currentY)
            separator:setText(string.rep("-", 12))
            separator:setForeground(colors.gray)
            currentY = currentY + 1
        else
            local button = self.startMenu:addButton()
            button:setPosition(2, currentY)
            button:setSize(12, 1)
            button:setText(item.text)
            button:setBackground(colors.lightGray)
            button:setForeground(colors.black)

            button:onClick(function()
                if item.action then
                    item.action()
                end
            end)

            currentY = currentY + 1
        end
    end
end

function menubar:showPowerDialog(action)
    local dialog = self.desktop.frame:addFrame()
    dialog:setSize(24, 6)
    dialog:setPosition(math.floor(self.desktop.frame.width/2 - 12), math.floor(self.desktop.frame.height/2 - 3))
    dialog:setBackground(colors.white)
    dialog:setZ(300)

    local frameCanvas = dialog:getCanvas()
    frameCanvas:addCommand(function(_self)
        local width, height = _self.get("width"), _self.get("height")
        local bg = _self.get("background")
        local borderColor = colors.red

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

    local title = dialog:addLabel()
    title:setPosition(2, 2)
    title:setText("Confirm " .. (action == "restart" and "Restart" or "Shutdown"))
    title:setForeground(colors.black)

    local message = dialog:addLabel()
    message:setPosition(2, 3)
    message:setText("Are you sure?")
    message:setForeground(colors.gray)

    local yesButton = dialog:addButton()
    yesButton:setPosition(2, 5)
    yesButton:setSize(8, 1)
    yesButton:setText("Yes")
    yesButton:setBackground(colors.red)
    yesButton:setForeground(colors.white)

    local noButton = dialog:addButton()
    noButton:setPosition(12, 5)
    noButton:setSize(8, 1)
    noButton:setText("No")
    noButton:setBackground(colors.gray)
    noButton:setForeground(colors.white)

    yesButton:onClick(function()
        if action == "restart" then
            os.reboot()
        else
            os.shutdown()
        end
    end)

    noButton:onClick(function()
        dialog:destroy()
        self:closeStartMenu()
    end)

    dialog:setFocused(true)
end

function menubar:toggleStartMenu()
    if self.startMenuOpen then
        self:closeStartMenu()
    else
        self:openStartMenu()
    end
end

function menubar:openStartMenu()
    if not self.startMenuOpen then
        self:createStartMenu()
        self.startMenuOpen = true

        self.desktop.frame:onClick(function()
            if self.startMenuOpen then
                self:closeStartMenu()
            end
        end)
    end
end

function menubar:closeStartMenu()
    if self.startMenu then
        self.startMenu:destroy()
        self.startMenu = nil
    end
    self.startMenuOpen = false
end

function menubar:setMenu(list, window)
    self.programMenubar:clear()
    self.curWindow = window
    self.lastWindow = window and window or self.lastWindow
    local x = 1
    for name, callback in pairs(list) do
        local label = self.programMenubar:addLabel({
            text=name,
            x=x,
            foreground=colors.white,
        })
        label:onClick(function()
            self.curWindow = self.lastWindow
            basalt.schedule(function()
                sleep(0.05)
                if self.lastWindow then
                    self.lastWindow.appFrame:setFocused(true)
                end
            end)
        end)
        label:onClickUp(function()
            self.curWindow = window
            callback()
        end)
        x = x + #name + 1
    end
end

return menubar