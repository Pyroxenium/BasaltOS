local configs = require("libraries.private.configs")
local path = require("libraries.public.path")
local colorHex = require("libraries.public.utils").tHex
local deepCopy = require("libraries.public.utils").deepCopy

local windowManager = {}
windowManager.__index = windowManager

local osWindow = {}
osWindow.__index = osWindow

local make_package = dofile("rom/modules/main/cc/require.lua").make

local format = "path;/path/?.lua;/path/?/init.lua;"
local libs = format:gsub("path", "{system}/libraries/public/")

local basaltos = require("basaltos")

local function setupBasaltOSApi(desktop)
    basaltos.setup(desktop)
    basaltos.setRoot(path.resolve("{system}"))
    basaltos.setRoot = nil
end

local function getDir(process)
    local appPath = process.app.manifest.executable
    if appPath then
        return fs.getDir(path.resolve(appPath))
    end
end

-- This function generates application-specific APIs
local function generateBasaltOS(process)
    local osAPI = deepCopy(basaltos)
    osAPI.getAppPath = function()
        return path.resolve(getDir(process))
    end
    osAPI.getWindowPosition = function()
        if process.window then
            local frame = process.window.appFrame
            return frame.x, frame.y, frame.width, frame.height
        end
    end
    osAPI.getAppName = function()
        return process.app.manifest.name
    end
    osAPI.setTitle = function(title)
        process.window:setTitle(title)
    end
    osAPI.setBackground = function(color)
        process.window.primaryColor = color
    end
    osAPI.getBackground = function()
        return process.window.primaryColor
    end
    osAPI.setForeground = function(color)
        process.window.title:setForeground(color)
        process.window.titleColor = color
    end
    if process.app.manifest.window.resizable and not process.app.manifest.window.fullscreen then
        osAPI.setSize = function(width, height)
            local minWidth = process.window.minWidth or 15
            local minHeight = process.window.minHeight or 6

            local newWidth = math.max(minWidth, width)
            local newHeight = math.max(minHeight, height)

            process.window.appFrame:setSize(newWidth, newHeight)
            process.window.program:setSize(newWidth-2, newHeight-2)
        end

        osAPI.getMinSize = function()
            return process.window.minWidth or 15, process.window.minHeight or 6
        end

        osAPI.setMinSize = function(minWidth, minHeight)
            process.window.minWidth = minWidth or 15
            process.window.minHeight = minHeight or 6
        end
    end
    osAPI.setAppFrameColor = function(color)
        process.window.appFrame:setBackground(color)
    end

    osAPI.setMenu = function(list)
        process.window:setMenu(list)
    end

    return osAPI
end


local function createEnvironment(process) -- TODO: Create multishell wrapper for desktop windowManager instead of cc tweaked multishell
    local dir = getDir(process)
    if not dir then
        error("No directory found for the process")
    end
    local env = setmetatable({}, {__index=_ENV})
    env.shell = shell
    env.require, env.package = make_package(env, fs.getDir(dir))
    local dir = fs.getDir(path.resolve(process.app.manifest.executable))
    local appPath = format:gsub("path", dir)
    env.package.path = appPath..path.resolve(libs)..env.package.path
    env.package.preload.basaltos = function()
        return generateBasaltOS(process)
    end
    env.package.preload.path = function()
        return path
    end
    return env
end

local function createFullscreen(self, process, desktop) -- FULLSCREEN VERSION
    local manifest = process.app.manifest

    -- Create the window frame
    self.appFrame = desktop.frame:addFrame({background=colors.black, z=5000})
    self.appFrame:setPosition(1, 1)
    self.appFrame:setSize(desktop.frame.width, desktop.frame.height)

    self.program = self.appFrame:addProgram({y=1, x=1, width=self.appFrame.width, height=self.appFrame.height-1, background=colors.black})
    self.program:observe("width", function(self, width)
        self.appFrame.set("width", width)
    end)
    self.program:observe("height", function(self, height)
        self.appFrame.set("height", height)
    end)

    -- Close button
    self.appFrame:addLabel({x=2, text="[Close]", foreground=colors.red, y="{parent.height}"}):onClick(function()
        self.process:stop()
    end)
    -- Restart button (Placeholder for now)
    self.appFrame:addLabel({x=10, text="[Restart]", foreground=colors.purple, y="{parent.height}"}):onClick(function()
        self:restart()
    end)
    -- Minimize button
    self.appFrame:addLabel({x=20, text="[Minimize]", foreground=colors.yellow, y="{parent.height}"}):onClick(function()
        self.process:minimize()
    end)
    -- Title
    self.title = self.appFrame:addLabel({x="{parent.width - #self.text - 1}", text="App Title", foreground=colors.white, y="{parent.height}"})

    local titleBar = self.appFrame:addVisualElement()
    :setSize("{parent.width}", 1)
    :setBackground(configs.get("windows", "primaryColor"))

    self.appFrame:onFocus(function()
        titleBar:setBackground(configs.get("windows", "focusColor"))
        if self.title then
            self.title:setForeground(configs.get("windows", "focusTextColor"))
        end
    end)

    self.appFrame:onBlur(function()
        titleBar:setBackground(configs.get("windows", "primaryColor"))
        if self.title then
            self.title:setForeground(configs.get("windows", "primaryTextColor"))
        end
    end)
end

local function createWindow(self, process, desktop) -- WINDOWED VERSION
    local manifest = process.app.manifest
    self.focusColor = configs.get("windows", "focusColor")
    self.primaryColor = configs.get("windows", "primaryColor")
    self.titleColor = configs.get("windows", "primaryTextColor")
    self.minWidth = manifest.window.min_width or 15
    self.minHeight = manifest.window.min_height or 6

    -- Create the window frame
    self.appFrame = desktop.frame:addFrame()
    self.appFrame:setPosition(3, 3) -- Maybe center it later
    self.appFrame:setSize(manifest.window.width or 30, manifest.window.height or 12)
    self.appFrame:setBackgroundEnabled(false)
    self.appFrame:setDraggable(true)
    self.title = self.appFrame:addLabel({x= "{parent.width / 2 - #self.text/2}", y=1})

    self.program = self.appFrame:addProgram({y=2, x=2, width=self.appFrame.width-2, height=self.appFrame.height-2, background=colors.black})

    local dragMap = self.appFrame.get("draggingMap")
    dragMap[1] = {x=5, y=1, width="width", height=1}

    -- Close button
    self.appFrame:addLabel({text="\7", foreground=colors.red}):onClick(function()
        self.process:stop()
    end)
    -- Restart button (Placeholder for now)
    self.appFrame:addLabel({text="\7", foreground=colors.purple, x=2}):onClick(function()
        self:restart()
    end)
    -- Minimize button
    self.appFrame:addLabel({text="\7", foreground=colors.yellow, x=3}):onClick(function()
        self.process:minimize()
    end)
    if manifest.window.resizable then
        -- Maximize button
        self.appFrame:addLabel({text="\7", foreground=colors.green, x=4}):onClick(function()
            if self.status == "maximized" then
                self:restoreSize()
                self.status = "restored"
            else
                self:maximize()
                self.status = "maximized"
            end
        end)
    end

    local frameCanvas = self.appFrame:getCanvas()

    frameCanvas:addCommand(function(_self)
        local width, height = _self.get("width"), _self.get("height")
        local bg = _self.get("background")
        local borderColor = _self.focused and self.focusColor or self.primaryColor

        _self:blit(1, height, ("\143"):rep(width), colorHex[bg]:rep(width), colorHex[borderColor]:rep(width))
        for i = 1, height-1 do
            _self:blit(1, i, ("\149"), colorHex[borderColor], colorHex[bg])
            _self:blit(width, i, ("\149"), colorHex[bg], colorHex[borderColor])
        end
        _self:blit(1, height, "\138", colorHex[bg], colorHex[borderColor])
        _self:blit(width, height, "\133", colorHex[bg], colorHex[borderColor])
    end)

    self.titleBar = self.appFrame:addVisualElement()
    :setSize("{parent.width}", 1)
    :setBackground(self.primaryColor)

    self.appFrame:onFocus(function()
        self.focus(self)
        self.desktop.menubar:setMenu(self.menuItems, self)
        self.titleBar:setBackground(self.focusColor)
        if self.title then
            self.title:setForeground(configs.get("windows", "focusTextColor"))
        end
    end)

    self.appFrame:onBlur(function()
        self.titleBar:setBackground(self.primaryColor)
        if self.title then
            self.title:setForeground(self.titleColor)
        end
    end)

    if manifest.window.resizable then
        self.appFrame:onClick(function(element, button, x, y)
            self.desktop.menubar.curWindow = self
            local width, height = element:getSize()

            if x >= width and y >= height then
                -- Bottom-right corner
                self.resizing = true
                self.resizeEdge = "corner"
                self.startX = x
                self.startY = y
                self.startW = width
                self.startH = height
            elseif x >= width then
                -- Right edge
                self.resizing = true
                self.resizeEdge = "right"
                self.startX = x
                self.startW = width
            elseif y >= height then
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
                    local newWidth = math.max(self.minWidth, self.startW + dx)
                    element.set("width", newWidth)
                    self.program.set("width", newWidth-2)
                end

                if self.resizeEdge == "bottom" or self.resizeEdge == "corner" then
                    local newHeight = math.max(self.minHeight, self.startH + dy)
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
    end

end

function osWindow.new(desktop, process)
    local self = setmetatable({}, osWindow)
    local manifest = process.app.manifest
    self.process = process
    self.desktop = desktop
    self.menuItems = {}

    if manifest.window.fullscreen then
        createFullscreen(self, process, desktop)
    else
        createWindow(self, process, desktop)
    end
    self:setTitle("App Title")
    return self
end

function osWindow:setMenu(list)
    self.menuItems = list
    if self.appFrame.focused then
        self.desktop.menubar:setMenu(list, self)
    end
end

function osWindow:getMenu()
    return self.menuItems
end

function osWindow:setTitle(title)
    if self.title then
        self.title:setText(title)
    end
end

function osWindow:run(...)
    if self.process then
        if self.process.app then
            if self.process.app.manifest then
                if self.process.app.manifest.executable then
                    local appPath = path.resolve(self.process.app.manifest.executable)
                    if fs.exists(appPath) then
                        self.program:execute(appPath, createEnvironment(self.process), nil, ...)
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
            self.program:execute(appPath, createEnvironment(self.process))
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
    self.program:setSize(self.appFrame.width-3, self.appFrame.height-2)
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
    setupBasaltOSApi(desktop)
    local self = setmetatable({}, windowManager)
    self.desktop = desktop
    return self
end

function windowManager:createWindow(process)
    local osWindow = osWindow.new(self.desktop, process)
    return osWindow
end

return windowManager