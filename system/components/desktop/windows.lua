local basalt = require("libraries/private/basalt")

local windowManager = {apps={}}

local app = {}
app.__index = app

function app.new(process, desktop)
    local self = setmetatable({}, app)
    local data, manifest = process.data, process.manifest
    self.process = process
    self.name = data.name
    self.path = data.path
    self.data = data or {}
    self.manifest = manifest or {}
    self.desktop = desktop

    self.appFrame = desktop.get():addFrame()
    self.appFrame:setPosition(2, 2)
    self.appFrame:setSize(self.manifest.windows.width, self.manifest.windows.height - 2)
    self.appFrame:setBackground(colors.black)
    self.appFrame:setForeground(colors.white)
    self.appFrame:setDraggable(true)

    local dragMap = self.appFrame.get("draggingMap")
    dragMap[1] = {x=4, y=1, width="width", height=1}

    self.appFrame:onFocus(function()
        self.focus(self)
    end)

    -- Close button
    self.appFrame:addLabel():setText("\7"):setForeground(colors.red):setPosition(1, 1):onClick(function()
        desktop.closeApp(process.pid)
    end)
    -- Minimize button
    self.appFrame:addLabel():setText("\7"):setForeground(colors.yellow):setPosition(2, 1):onClick(function()

    end)
    -- Maximize button
    self.appFrame:addLabel():setText("\7"):setForeground(colors.green):setPosition(3, 1):onClick(function()

    end)
    self.appFrame:addVisualElement()
    :setSize("{parent.width}", 1)
    :setBackground(colors.blue)

    self.title = self.appFrame:addLabel():setText(self.manifest.windows.title):setPosition("{parent.width / 2 - #self.text/2}", 1):setForeground(colors.white)

    self.program = self.appFrame:addProgram()
    self.program:setPosition(1, 2)
    self.program:setSize("{parent.width}", "{parent.height - 1}")

    return self
end

function app:run()
    if self.path then
        windowManager.apps[self.name] = self
        self.program:execute(self.path)
    else
        print("No path specified for app.")
    end
end

function app:close()
    if self.program then
        self.program:stop()
        self.appFrame:destroy()
        self.appFrame = nil
    end
end

function app:restart()
    if self.program then
        self.program:execute(self.path)
    end
end

function app:focus()
    self.desktop.get():removeChild(self.appFrame)
    self.desktop.get():addChild(self.appFrame)
    if self.appFrame then
        self.appFrame:setVisible(true)
    end
end

function app:minimize()
    self.appFrame:setVisible(false)
    if self.dock then
        local canvas = self.dock.icon:getCanvas()
        canvas:removeCommand(self.dock.iconCanvasId)
        self.dock.iconCanvasId = canvas:text(2, 3, "\7", colors.lightGray)
    end
end

function app:restore()
    self.appFrame:setVisible(true)
    self.appFrame:focus()
    if self.dock then
        local canvas = self.dock.icon:getCanvas()
        canvas:removeCommand(self.dock.iconCanvasId)
        self.dock.iconCanvasId = canvas:text(1, 3, "\136\140\132", colors.lightGray)
    end
end

function app:getStatus()
    return self.appFrame:getVisible() and "running" or "minimized"
end

-- Window Manager Functions
function windowManager.create(desktop)
    windowManager.desktop = desktop
    return windowManager
end

function windowManager.getApp(name)
    return windowManager.apps[name]
end

function windowManager.removeApp(process)
    local app = windowManager.apps[process.pid]
    if app then
        app:close()
        windowManager.apps[process.pid] = nil
    end
end

function windowManager.getApps()
    return windowManager.apps
end

function windowManager.launchProcess(process)
    local newApp = app.new(process, windowManager.desktop)
    newApp:run()
    windowManager.apps[process.pid] = newApp
    return newApp
end

return windowManager