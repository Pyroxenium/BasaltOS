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
    self.appFrame:setBackgroundEnabled(false)
    self.appFrame:setDraggable(true)

    self.program = self.appFrame:addProgram({y=2, x=2, width=self.appFrame.width-2, height=self.appFrame.height-2, background=colors.black})

    local dragMap = self.appFrame.get("draggingMap")
    dragMap[1] = {x=5, y=1, width="width", height=1}

    -- Close button
    self.appFrame:addLabel({text="\7", foreground=colors.red}):onClick(function()
        self.process:stop()
    end)
    -- Minimize button
    self.appFrame:addLabel({text="\7", foreground=colors.yellow, x=2}):onClick(function()
        self.process:minimize()
    end)
    -- Maximize button
    self.appFrame:addLabel({text="\7", foreground=colors.green, x=3}):onClick(function()
        if self.status == "maximized" then
            self:restoreSize()
            self.status = "restored"
        else
            self:maximize()
            self.status = "maximized"
        end
    end)
    -- Restart button (Placeholder for now)
    self.appFrame:addLabel({text="\7", foreground=colors.purple, x=4}):onClick(function()
        self:restart()
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

    self.appFrame:onClick(function(element, button, x, y)
        local width, height = element:getSize()
        
        -- Check if click is on resize areas (right edge or bottom edge)
        if x >= width-1 and y >= height-1 then
            -- Bottom-right corner
            self.resizing = true
            self.resizeEdge = "corner"
            self.startX = x
            self.startY = y
            self.startW = width
            self.startH = height
        elseif x >= width-1 then
            -- Right edge
            self.resizing = true
            self.resizeEdge = "right"
            self.startX = x
            self.startW = width
        elseif y >= height-1 then
            -- Bottom edge
            self.resizing = true
            self.resizeEdge = "bottom"
            self.startY = y
            self.startH = height
        end
    end)

    self.appFrame:onDrag(function(element, _, x, y)
        if self.resizing then
            local dx = x - (self.startX or x)
            local dy = y - (self.startY or y)
            
            if self.resizeEdge == "right" or self.resizeEdge == "corner" then
                local newWidth = math.max(10, self.startW + dx)
                element.set("width", newWidth)
                self.program.set("width", newWidth-2)
            end
            
            if self.resizeEdge == "bottom" or self.resizeEdge == "corner" then
                local newHeight = math.max(5, self.startH + dy)
                element.set("height", newHeight)
                self.program.set("height", newHeight-2)
            end
        end
    end)

    self.appFrame:onClickUp(function()
        self.dragging = false
        self.resizing = false
        self.resizeEdge = nil
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
        local appPath = path.resolve(self.process.app.manifest.executable)
        if fs.exists(appPath) then
            self.program:execute(appPath)
        end
    end
end

function osWindow:focus()
    self.desktop.frame:removeChild(self.appFrame)
    self.desktop.frame:addChild(self.appFrame)
end

function osWindow:minimize()
    self.appFrame:setVisible(false)
end

function osWindow:maximize()
    self.appFrame:setVisible(true)
    self:focus()
    self.appFrame:setFocused(true)
    self.oldWidth = self.appFrame.width
    self.oldHeight = self.appFrame.height
    self.oldX = self.appFrame.x
    self.oldY = self.appFrame.y
    self.appFrame:setSize(self.desktop.frame.width, self.desktop.frame.height-2)
    self.program:setSize(self.appFrame.width-2, self.appFrame.height-2)
    self.appFrame:setPosition(1, 2)
    self.status = "maximized"
end

function osWindow:restoreSize()
    if self.oldWidth and self.oldHeight then
        self.appFrame:setSize(self.oldWidth, self.oldHeight)
        self.program:setSize(self.appFrame.width-2, self.appFrame.height-2)
        self.appFrame:setPosition(self.oldX, self.oldY)
    end
    self.status = "restored"
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