local basalt = require("libraries.public.basalt")
local dockComponent = require("components/desktop/dock")
local menubarComponent = require("components/desktop/menubar")
local windowsComponent = require("components/desktop/windows")
local notificationComponent = require("components/desktop/notifications")
local config = require("libraries.private.configs")
local processManager = require("libraries.private.processManager")

local desktop = {}
desktop.__index = desktop

local activeDesktop
local desktopId = 0

function desktop.new(id)
    local self = setmetatable({}, desktop)
    self.id = id
    self.frame = basalt.createFrame()
    self.frame:setBackground(config.get("desktop", "primaryColor"))
    self.dock = dockComponent.new(self)
    self.menubar = menubarComponent.new(self)
    self.windowManager = windowsComponent.new(self)
    self.notifications = notificationComponent.new(self)

    self.frame:onClick(function()
        self.menubar.curWindow = nil
    end)
    self.frame:onClickUp(function()
        if not self.menubar.curWindow then
            self.menubar:setMenu({})
            self.menubar.lastWindow = nil
        end
    end)
    activeDesktop = self
    return self
end

function desktop:getApps()
    local appManager = require("libraries.private.appManager")
    return appManager.getApps()
end

function desktop:openApp(name, ...)
    local appManager = require("libraries.private.appManager")
    local app = appManager.getApp(name)
    if app then
        local dockIcon = self.dock:getPinnedApp(app)
        if dockIcon and dockIcon.process and dockIcon.process.window then
            dockIcon.process.window:restore()
            dockIcon:updateStatus("maximized")
            return dockIcon.process
        end

        local process = processManager.create(self, app)
        if process then
            if dockIcon then
                process.dockIcon = dockIcon
                dockIcon.process = process
            else
                dockIcon = self.dock:add(app)
                dockIcon:updateStatus("maximized")
                process.dockIcon = dockIcon
                dockIcon.process = process
            end

            process:run(...)
            return process
        else
            error("Failed to launch app: " .. name)
        end
    else
        error("App not found: " .. name)
    end
end

function desktop:showNotification(title, message, duration)
    return self.notifications:show(title, message, duration)
end

function desktop:handleEvent(event)
    if self.notifications then
        self.notifications:handleEvent(event)
    end
end

local desktopManager = {desktops={}}

function desktopManager.get()
    return activeDesktop.frame
end

function desktopManager.getActive()
    return activeDesktop
end

function desktopManager.create()
    local newDesktop = desktop.new(desktopId)
    desktopManager.desktops[desktopId] = newDesktop
    desktopId = desktopId + 1
    return newDesktop
end

function desktopManager.switch(id)
    if desktopManager.desktops[id] then
        activeDesktop = desktopManager.desktops[id]
        basalt.setActiveFrame(activeDesktop.frame)
    else
        error("Desktop not found: " .. id)
    end
end

return desktopManager