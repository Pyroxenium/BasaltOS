local utils = require("libraries.public.utils")
local configs = require("libraries.private.configs")
local colorHex = utils.tHex

local notification = {}
notification.__index = notification

function notification.new(manager, title, message, duration)
    local self = setmetatable({}, notification)
    self.manager = manager
    self.title = title or "Notification"
    self.message = message or ""
    self.duration = duration or 5
    self.visible = false

    local titleLen = #self.title
    local messageLen = #self.message
    self.width = math.max(titleLen + 4, messageLen + 4, 15)
    self.height = message and 4 or 3

    self:create()
    return self
end

function notification:create()
    local desktop = self.manager.desktop
    self.frame = desktop.frame:addFrame()
    self.frame:setSize(self.width, self.height)
    self.frame:setBackground(colors.gray)
    self.frame:setZ(100)
    self.frame:setVisible(false)

    local frameCanvas = self.frame:getCanvas()
    frameCanvas:addCommand(function(_self)
        local width, height = _self.get("width"), _self.get("height")
        local bg = _self.get("background")
        local borderColor = configs.get("windows", "primaryColor")

        _self:textFg(1, 1, ("\131"):rep(width), borderColor)
        _self:textFg(1, height, ("\131"):rep(width), borderColor)

        for i = 2, height-1 do
            _self:blit(1, i, "\149", colorHex[borderColor], colorHex[bg])
            _self:blit(width, i, "\149", colorHex[bg], colorHex[borderColor])
        end

        _self:blit(1, 1, "\151", colorHex[borderColor], colorHex[bg])
        _self:blit(width, 1, "\148", colorHex[bg], colorHex[borderColor])
        _self:blit(1, height, "\138", colorHex[borderColor], colorHex[bg])
        _self:blit(width, height, "\133", colorHex[bg], colorHex[borderColor])
    end)

    self.titleLabel = self.frame:addLabel()
    self.titleLabel:setPosition(2, 2)
    self.titleLabel:setText(self.title)
    self.titleLabel:setForeground(colors.white)

    if self.message and self.message ~= "" then
        self.messageLabel = self.frame:addLabel()
        self.messageLabel:setPosition(2, 3)
        self.messageLabel:setText(self.message)
        self.messageLabel:setForeground(colors.lightGray)
    end

    self.timer = os.startTimer(self.duration)
end

function notification:show()
    if not self.visible then
        self.visible = true
        self.frame:setVisible(true)

        self.frame:setBackground(colors.gray)
    end
end

function notification:hide()
    if self.visible then
        self.visible = false
        self.frame:setVisible(false)
        self.manager:removeNotification(self)
    end
end

function notification:setPosition(x, y)
    if self.frame then
        self.frame:setPosition(x, y)
    end
end

function notification:destroy()
    if self.frame then
        self.frame:destroy()
        self.frame = nil
    end
end

function notification:handleTimer(timerId)
    if self.timer == timerId then
        self:hide()
    end
end

local notificationManager = {}
notificationManager.__index = notificationManager

function notificationManager.new(desktop)
    local self = setmetatable({}, notificationManager)
    self.desktop = desktop
    self.notifications = {}
    self.spacing = 2
    return self
end

function notificationManager:show(title, message, duration)
    local notif = notification.new(self, title, message, duration)
    table.insert(self.notifications, notif)
    self:repositionNotifications()
    notif:show()
    return notif
end

function notificationManager:removeNotification(notification)
    for i, notif in ipairs(self.notifications) do
        if notif == notification then
            notif:destroy()
            table.remove(self.notifications, i)
            self:repositionNotifications()
            break
        end
    end
end

function notificationManager:repositionNotifications()
    local desktopWidth = self.desktop.frame.width
    local desktopHeight = self.desktop.frame.height
    local currentY = desktopHeight - 3

    for i = #self.notifications, 1, -1 do
        local notif = self.notifications[i]
        local x = desktopWidth - notif.width - 1
        local y = currentY - notif.height + 1

        notif:setPosition(x, y)
        currentY = y - self.spacing
    end
end

function notificationManager:handleTimer(timerId)
    for _, notif in ipairs(self.notifications) do
        notif:handleTimer(timerId)
    end
end

function notificationManager:handleEvent(event)
    if event[1] == "timer" then
        self:handleTimer(event[2])
    end
end

return notificationManager
