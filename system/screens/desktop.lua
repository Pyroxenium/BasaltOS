local basalt = require("libraries.private.basalt")
local dockComponent = require("components/desktop/dock")
local menubarComponent = require("components/desktop/menubar")
local windowsComponent = require("components/desktop/windows")
local config = require("libraries.private.configs")

local desktop = {}
desktop.__index = desktop

local activeDesktop
local desktopId = 0

function desktop.new(id)
    local self = setmetatable({}, desktop)
    self.id = id
    self.frame = basalt.createFrame()
    self.frame:setBackground(config.get("theme", "background"))
    self.dock = dockComponent.new(self)
    self.menubar = menubarComponent.new(self)
    self.windowManager = windowsComponent.new(self)
    activeDesktop = self
    return self
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