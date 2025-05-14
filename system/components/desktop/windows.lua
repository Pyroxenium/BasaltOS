local configs = require("libraries.private.configs")
local path = require("libraries.public.path")
local colorHex = require("libraries.public.utils").tHex

local windowManager = {}
windowManager.__index = windowManager

local osWindow = {}
osWindow.__index = osWindow

function osWindow.new(desktop, process)
    local self = setmetatable({}, osWindow)
    self.process = process
    self.desktop = desktop
    self.appFrame = desktop.frame:addFrame()
    self.appFrame:setPosition(3, 3) -- Maybe center it later
    self.appFrame:setSize(30, 12)
    --self.appFrame:setBackground(colors.gray)
    self.appFrame:setBackgroundEnabled(false)
    self.appFrame:setDraggable(true)

    self.program = self.appFrame:addProgram({y=2, x=2, width="{parent.width-2}", height="{parent.height-2}", background=colors.black})

    local dragMap = self.appFrame.get("draggingMap")
    dragMap[1] = {x=4, y=1, width="width", height=1}

    -- Close button
    self.appFrame:addLabel({text="\7", foreground=colors.red}):onClick(function()
        self.process:stop()
        require("logging").debug("Window closed")
    end)
    -- Minimize button
    self.appFrame:addLabel({text="\7", foreground=colors.yellow, x=2}):onClick(function()
        self.process:minimize()
        require("logging").debug("Window minimized")
    end)
    -- Maximize button
    self.appFrame:addLabel({text="\7", foreground=colors.green, x=3}):onClick(function()

    end)

    local frameCanvas = self.appFrame:getCanvas()

    frameCanvas:addCommand(function(self) -- Border for Frame:
        local width, height = self.get("width"), self.get("height")
        local bg = self.get("background")
        local borderColor = self.focused and configs.get("windows", "focusColor") or configs.get("windows", "blurColor")

        self:textFg(1, height, ("\131"):rep(width), borderColor)
        for i = 1, height-1 do
            self:blit(1, i, ("\149"), colorHex[borderColor], colorHex[bg])
            self:blit(width, i, ("\149"), colorHex[bg], colorHex[borderColor])
        end
    end)


    local titleBar = self.appFrame:addVisualElement()
    :setSize("{parent.width}", 1)
    :setBackground(configs.get("windows", "blurColor"))

    self.appFrame:onFocus(function()
        self.focus(self)
        titleBar:setBackground(configs.get("windows", "focusColor"))
        if self.title then
            self.title:setForeground(configs.get("windows", "focusTextColor"))
        end
    end)

    self.appFrame:onBlur(function()
        titleBar:setBackground(configs.get("windows", "blurColor"))
        if self.title then
            self.title:setForeground(configs.get("windows", "blurTextColor"))
        end
    end)

    self:setTitle("App Title")
    return self
end

function osWindow:setTitle(title)
    if not self.title then
        self.title = self.appFrame:addLabel({x= "{parent.width / 2 - #self.text/2}", y=1})
    end
    self.title:setText(title)
end

function osWindow:run()
    if self.process then
        if self.process.app then
            if self.process.app.manifest then
                if self.process.app.manifest.executable then
                    local appPath = path.resolve(self.process.app.manifest.executable)
                    if fs.exists(appPath) then
                        self.program:execute(appPath)
                    end
                end
            end
        end
    end
end

function osWindow:close()
    if self.appFrame then
        self.appFrame:destroy()
        self.appFrame = nil
    end
end

function osWindow:restart()
    if self.program then
        self.program:execute(self.path)
    end
end

function osWindow:focus()
    self.desktop.frame:removeChild(self.appFrame)
    self.desktop.frame:addChild(self.appFrame)
end

function osWindow:minimize()
    self.appFrame:setVisible(false)
end

function osWindow:restore()
    self.appFrame:setVisible(true)
    self:focus()
    self.appFrame:setFocused(true)
end

function osWindow:getStatus()
    return self.appFrame:getVisible() and "maximized" or "minimized"
end

-- Window Manager Functions
function windowManager.new(desktop)
    local self = setmetatable({}, windowManager)
    self.desktop = desktop
    return self
end

function windowManager:createWindow(process)
    local osWindow = osWindow.new(self.desktop, process)
    return osWindow
end

return windowManager