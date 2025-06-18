-- Public BasaltOS API for programs
local theme = require("libraries.private.configs").get("windows")
local colorHex = require("libraries.public.utils").tHex
local configs = require("libraries.private.configs")
local path = require("libraries.public.path")
local osError = require("libraries.private.osError")

local desktop
local BasaltOS = {root="/"}

function BasaltOS.getRoot()
    return BasaltOS.root
end

function BasaltOS.setRoot(path)
    if type(path) == "string" then
        BasaltOS.root = path
    else
        error("Path must be a string")
    end
end


function BasaltOS.openApp(...)
    desktop:openApp(...)
end

function BasaltOS.getApps()
    return desktop:getApps()
end

function BasaltOS.registerApp(path)
    local appManager = require("libraries.private.appManager")
    if not path or type(path) ~= "string" then
        error("Path must be a string")
    end
    if not fs.exists(path) then
        error("Path does not exist: " .. path)
    end
    appManager.registerApp(path)
    return true
end

function BasaltOS.setup(_desktop)
    desktop = _desktop
    if not desktop then
        error("Desktop cannot be nil")
    end
end

function BasaltOS.getTheme(name)
    if not name then
        return theme
    end

    local t = theme[name]
    if not t then
        error("Theme '" .. name .. "' does not exist")
    end

    return t
end

function BasaltOS.showNotification(title, message, duration)
    local desktopManager = require("libraries.private.screenManager").getScreen("desktop")
    local activeDesktop = desktopManager.getActive()
    if activeDesktop and activeDesktop.showNotification then
        return activeDesktop:showNotification(title, message, duration)
    end
end

function BasaltOS.notify(message, duration)
    return BasaltOS.showNotification("Notification", message, duration)
end

function BasaltOS.frame(x, y, width, height, options)
    options = options or {}
    local desktopManager = require("libraries.private.screenManager").getScreen("desktop")
    local activeDesktop = desktopManager.getActive()

    local frame = activeDesktop.frame:addFrame({
        x = x,
        y = y,
        width = width,
        height = height,
        background = options.background or colors.white,
        foreground = options.foreground or colors.black,
    })

    frame:setFocused(true)

    return frame
end

function BasaltOS.contextMenu(x, y, items, options)
    options = options or {}
    local width = options.width or 12
    local maxHeight = options.maxHeight or #items + 2
    local height = math.min(#items+2, options.maxHeight)

    local contextMenu = BasaltOS.frame(x, y, width, height, {
        background = colors.lightGray,
    })

    local frameCanvas = contextMenu:getCanvas()
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

    for i, item in ipairs(items) do
        if i <= maxHeight then
            local button = contextMenu:addButton({
                x = 2,
                y = i+1,
                width = width-2,
                height = 1,
                text = item.text or ("Item " .. i),
                background = colors.lightGray,
                foreground = colors.black
            })

            button:onClick(function()
                if item.action then
                    item.action()
                end
                contextMenu:destroy()
            end)
        end
    end

    contextMenu.basalt.schedule(function()
        sleep(0.05)
        contextMenu:setFocused(true)
    end)

    local destroyed = false
    contextMenu:onBlur(function()
        if not destroyed then
            contextMenu:setVisible(false)
            contextMenu.basalt.schedule(function()
                sleep(0.05)
                contextMenu:destroy()
            end)
            destroyed = true
        end
    end)

    return contextMenu
end

function BasaltOS.dialog(options)
    options = options or {}
    local title = options.title or "Dialog"
    local message = options.message or ""
    local inputConfig = options.input or {}
    local buttons = options.buttons or {{text = "OK", action = function() end}}
    local dialogWidth = math.max(28, #title + 4, #message + 5)

    local dialogHeight = 2

    if title and title ~= "" then
        dialogHeight = dialogHeight + 2
    end

    if message and message ~= "" then
        dialogHeight = dialogHeight + 2
    end

    if inputConfig.label or inputConfig.value or inputConfig.placeholder then
        if inputConfig.label then
            dialogHeight = dialogHeight + 1
        end
        dialogHeight = dialogHeight + 2
    end

    dialogHeight = dialogHeight + 1

    local desktopManager = require("libraries.private.screenManager").getScreen("desktop")
    local activeDesktop = desktopManager.getActive()

    local desktopW, desktopH = activeDesktop.frame:getSize()
    local x = math.floor((desktopW - dialogWidth) / 2)
    local y = math.floor((desktopH - dialogHeight) / 2)

    local dialog = activeDesktop.frame:addFrame({
        x = x,
        y = y,
        width = dialogWidth,
        height = dialogHeight,
        background = colors.lightGray,
        border = false
    })

    local canvas = dialog:getCanvas()
    canvas:addCommand(function(_self)
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

    local currentY = 2

    if title and title ~= "" then
        dialog:addLabel({
            x = 2,
            y = currentY,
            width = dialogWidth - 2,
            height = 1,
            text = title,
            background = colors.lightGray,
            foreground = colors.black,
            align = "center"
        })
        currentY = currentY + 2
    end

    if message and message ~= "" then
        dialog:addLabel({
            x = 2,
            y = currentY,
            width = dialogWidth - 2,
            height = 1,
            text = message,
            background = colors.lightGray,
            foreground = colors.black
        })
        currentY = currentY + 2
    end

    local inputField = nil

    if inputConfig.label or inputConfig.value or inputConfig.placeholder then
        if inputConfig.label then
            dialog:addLabel({
                x = 2,
                y = currentY,
                width = dialogWidth - 2,
                height = 1,
                text = inputConfig.label,
                background = colors.lightGray,
                foreground = colors.black
            })
            currentY = currentY + 1
        end

        inputField = dialog:addTextBox({
            x = 2,
            y = currentY,
            width = dialogWidth - 2,
            height = 1,
            background = colors.white,
            foreground = colors.black,
            text = inputConfig.value or ""
        })

        if inputConfig.placeholder then
            inputField:setPlaceholder(inputConfig.placeholder)
        end

        currentY = currentY + 2
    end

    local buttonWidth = math.floor((dialogWidth - 2) / #buttons) - 1
    local buttonX = 2

    for i, buttonConfig in ipairs(buttons) do
        local button = dialog:addButton({
            x = buttonX,
            y = currentY,
            width = buttonWidth,
            height = 1,
            text = buttonConfig.text or "Button",
            background = colors.gray,
            foreground = colors.white
        })

        button:onClick(function()
            local inputValue = inputField and inputField:getText() or nil
            if buttonConfig.action then
                buttonConfig.action(inputValue)
            end
            dialog:destroy()
        end)

        buttonX = buttonX + buttonWidth + 1
    end

    dialog.basalt.schedule(function()
        sleep(0.05)
        dialog:setFocused(true)
        if inputField then
            inputField:setFocused(true)
        end
    end)

    local destroyed = false
    dialog:onBlur(function()
        if not destroyed then
            dialog:setVisible(false)
            dialog.basalt.schedule(function()
                sleep(0.05)
                dialog:destroy()
            end)
            destroyed = true
        end
    end)

    return dialog
end

function BasaltOS.inputDialog(title, message, defaultValue, callback)
    return BasaltOS.dialog({
        title = title,
        message = message,
        input = {
            value = defaultValue or ""
        },
        buttons = {
            {
                text = "Cancel",
                action = function()
                    if callback then callback(nil) end
                end
            },
            {
                text = "OK",
                action = function(inputValue)
                    if callback then callback(inputValue) end
                end
            }
        }
    })
end

function BasaltOS.confirmDialog(title, message, callback)
    return BasaltOS.dialog({
        title = title,
        message = message,
        buttons = {
            {
                text = "Cancel",
                action = function()
                    if callback then callback(false) end
                end
            },
            {
                text = "OK",
                action = function()
                    if callback then callback(true) end                end
            }
        }
    })
end

function BasaltOS.errorDialog(message, callback)
    return BasaltOS.dialog({
        title = "Error",
        message = message,
        buttons = {
            {
                text = "OK",
                action = function()
                    if callback then callback() end
                end
            }
        }
    })
end

function BasaltOS.fileDialog(title, filter, callback, initialPath)
    title = title or "Select File"
    filter = filter or "*"
    initialPath = initialPath or "/"

    if not fs.exists(initialPath) then
        initialPath = "/"
    end

    local currentPath = initialPath
    local selectedFile = nil

    local desktopManager = require("libraries.private.screenManager").getScreen("desktop")
    local activeDesktop = desktopManager.getActive()

    local desktopW, desktopH = activeDesktop.frame:getSize()
    local dialogWidth = math.min(25, desktopW - 4)
    local dialogHeight = math.min(12, desktopH - 4)

    local x = math.floor((desktopW - dialogWidth) / 2)
    local y = math.floor((desktopH - dialogHeight) / 2)

    local dialog = activeDesktop.frame:addFrame({
        x = x,
        y = y,
        width = dialogWidth,
        height = dialogHeight,
        background = colors.lightGray,
        border = false,
        z = 999
    })

    local canvas = dialog:getCanvas()
    canvas:addCommand(function(_self)
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

    dialog:addLabel({
        x = 2,
        y = 2,
        text = title,
        foreground = colors.black
    })

    local pathLabel = dialog:addLabel({
        x = 2,
        y = 3,
        width = dialogWidth - 4,
        text = currentPath,
        foreground = colors.blue
    })

    local fileList = dialog:addList({
        x = 2,
        y = 5,
        width = dialogWidth - 2,
        height = dialogHeight - 7,
        background = colors.white,
        foreground = colors.black,
        selectionBackground = colors.blue,
        selectionForeground = colors.white
    })

    local function updateFileList()
        fileList:clear()
        pathLabel:setText(currentPath)

        if currentPath ~= "/" then
            fileList:addItem(".. (Parent Directory)", colors.yellow)
        end

        if fs.exists(currentPath) and fs.isDir(currentPath) then
            local files = fs.list(currentPath)
            table.sort(files)

            for _, file in ipairs(files) do
                local fullPath = fs.combine(currentPath, file)
                if fs.isDir(fullPath) then
                    fileList:addItem("/" .. file, colors.cyan)
                end
            end

            for _, file in ipairs(files) do
                local fullPath = fs.combine(currentPath, file)
                if not fs.isDir(fullPath) then
                    if filter == "*" or file:match(filter:gsub("%*", ".*")) then
                        fileList:addItem(file, colors.black)
                    else
                        fileList:addItem(file, colors.gray)
                    end
                end
            end
        end
    end

    fileList:onSelect(function(self, event, item, index)
        if item then
            local itemText = item.text
            if itemText == ".. (Parent Directory)" then
                currentPath = fs.getDir(currentPath)
                if currentPath == "" then currentPath = "/" end
                updateFileList()
                selectedFile = nil
            elseif itemText:sub(1, 1) == "/" then
                local dirName = itemText:sub(2)
                currentPath = fs.combine(currentPath, dirName)
                updateFileList()
                selectedFile = nil
            else
                selectedFile = fs.combine(currentPath, itemText)
            end
        end
    end)

    local buttonY = dialogHeight - 1

    local selectBtn = dialog:addButton({
        x = 2,
        y = buttonY,
        width = 8,
        height = 1,
        text = "Select",
        background = colors.green,
        foreground = colors.white
    })

    local cancelBtn = dialog:addButton({
        x = 12,
        y = buttonY,
        width = 8,
        height = 1,
        text = "Cancel",
        background = colors.red,
        foreground = colors.white
    })

    selectBtn:onClick(function()
        if selectedFile and fs.exists(selectedFile) and not fs.isDir(selectedFile) then
            dialog:destroy()
            if callback then
                callback(selectedFile)
            end
        end
    end)

    cancelBtn:onClick(function()
        dialog:destroy()
        if callback then
            callback(nil)
        end
    end)

    updateFileList()

    return dialog
end

return BasaltOS