local utils = require("libraries.public.utils")
local path = require("libraries.public.path")
local processManager = require("libraries.private.processManager")

local icon = {}
icon.__index = icon

function icon.new(app, dock)
    local self = setmetatable({}, icon)
    self.dock = dock
    self.app = app
    self.bimg = utils.loadBimg(path.resolve(app.manifest.icon or "{assets}/icons/default.bimg"))
    self.iconElement = self.dock.frame:addImage()
        self.iconElement:setPosition(#self.dock.apps * 4 + 2, 1)
        self.iconElement:setSize(3, 2)
        self.iconElement:setBimg(self.bimg)
        self.iconElement:onClick(function()
            if not self.process then
                self.process = self:launchApp()
                if self.process.window then
                    self:updateStatus("maximized")
                end
            else
                if self.process.window then
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
    return self
end

function icon:launchApp()
    local process = processManager.create(self.app)
    if process then
        process:setIcon(self)
        process:run()
        return process
    else
        error("Failed to launch app: " .. self.manifest.name)
    end
end

function icon:updateStatus(status)
    if self.iconElement then
        local canvas = self.iconElement:getCanvas()
        if self.canvasId then
            canvas:removeCommand(self.canvasId)
        end
        if status == "maximized" then
            self.canvasId= canvas:text(1, 3, "\136\140\132", colors.lightGray)
        elseif status == "minimized" then
            self.canvasId = canvas:text(2, 3, "\7", colors.lightGray)
        end
        self.iconElement:updateRender()
    end
end

function icon:remove()
    self:updateStatus("closed")
    self.process = nil
    if not self.pinned then
        self.dock:remove(self.app)
    end
end

function icon:setPinned(pinned)
    self.pinned = pinned
end

local dock = {}
dock.__index = dock

-- Creates a new dock component
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
    local pinnedApp = self:getPinnedApp(app)
    if not pinnedApp then
        local dockIcon = icon.new(app, self)
        table.insert(self.apps, dockIcon)
    end
    return pinnedApp
end

function dock:remove(app)
    local pinnedApp = self:getPinnedApp(app)
    if pinnedApp and not pinnedApp.pinned then
        for i, app in ipairs(self.apps) do
            if app == pinnedApp then
                table.remove(self.apps, i)
                break
            end
        end
    end
end

return dock