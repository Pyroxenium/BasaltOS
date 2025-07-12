local basalt = require("libraries.public.basalt")
local dockComponent = require("components/desktop/dock")
local menubarComponent = require("components/desktop/menubar")
local windowsComponent = require("components/desktop/windows")
local notificationComponent = require("components/desktop/notifications")
local config = require("libraries.private.configs")
local processManager = require("libraries.private.processManager")
local path = require("libraries.public.path")

local desktop = {}
desktop.__index = desktop

local activeDesktop
local desktopId = 0
local lastOpenAppCall = {}

function desktop.new(id)
    local self = setmetatable({}, desktop)
    self.id = id
    self.frame = basalt.createFrame()
    self.frame:setBackground(config.get("desktop", "primaryColor"))
    self.dock = dockComponent.new(self)
    self.menubar = menubarComponent.new(self)
    self.windowManager = windowsComponent.new(self)
    self.notifications = notificationComponent.new(self)

    self.backgroundImage = self.frame:addImage({
        x = 1,
        y = 1,
        width = "{parent.width}",
        height = "{parent.height}",
        background = colors.black,
    })

    local imgPath = config.get("desktop", "backgroundImage")
    if imgPath then 
        imgPath = path.resolve(imgPath)
    end
    if imgPath and fs.exists(imgPath) then
        local file = fs.open(imgPath, "rb")
        if file then
            local imageData = textutils.unserialize(file.readAll())
            file.close()
            self.backgroundImage:setBimg(imageData)
        end
    end

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

function desktop:createWindow(title, width, height, x, y)
    local window = self.windowManager:createWindow(title, width, height, x, y)
    if not window then
        error("Failed to create window: " .. title)
    end
    return window
end

function desktop:getApps()
    local appManager = require("libraries.private.appManager")
    return appManager.getApps()
end

function desktop:openApp(name, ...)
    local appManager = require("libraries.private.appManager")
    local app = appManager.getApp(name)
    if app then
        shell.setDir("/")
        local currentTime = os.clock()
        local callKey = name .. tostring(select("#", ...))

        if lastOpenAppCall[callKey] and (currentTime - lastOpenAppCall[callKey] < 0.5) then
            return
        end
        lastOpenAppCall[callKey] = currentTime

        if app.manifest.requiresFile and select("#", ...) == 0 then
            local dialog = require("libraries.private.os.dialog")
            dialog.file("Select File for " .. name, "*", function(selectedPath)
                if selectedPath then
                    self:openApp(name, selectedPath)
                end
            end)
            return
        end

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

function desktop:openPath(path)
    if not path or path == "" then
        error("Path cannot be empty")
    end

    if not fs.exists(path) then
        error("File not found: " .. path)
    end

    local fileRegistry = require("libraries.private.fileRegistry")
    local extension = fileRegistry.getFileExtension(path)
    local handler = fileRegistry.getHandler(extension, "open")

    return self:openApp(handler, path)
end

function desktop:editPath(path)
    if not path or path == "" then
        error("Path cannot be empty")
    end

    if not fs.exists(path) then
        error("File not found: " .. path)
    end

    local fileRegistry = require("libraries.private.fileRegistry")
    local extension = fileRegistry.getFileExtension(path)
    local handler = fileRegistry.getHandler(extension, "edit")

    return self:openApp(handler, path)
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