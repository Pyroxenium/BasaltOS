-- Dialog System for BasaltOS
-- Creates and manages various types of dialogs

local dialog = {}
local colorHex = require("libraries.public.utils").tHex
local configs = require("libraries.private.configs")
local logger = require("libraries.public.logger")

local function wrapText(text, maxWidth)
    if not text or text == "" then return {} end

    local lines = {}
    local words = {}

    for word in text:gmatch("%S+") do
        table.insert(words, word)
    end

    local currentLine = ""

    for _, word in ipairs(words) do
        local testLine = currentLine == "" and word or (currentLine .. " " .. word)

        if #testLine <= maxWidth then
            currentLine = testLine
        else

            if currentLine ~= "" then
                table.insert(lines, currentLine)
                currentLine = ""
            end

            if #word > maxWidth then
                local remaining = word
                while #remaining > 0 do
                    local chunk = remaining:sub(1, maxWidth)
                    table.insert(lines, chunk)
                    remaining = remaining:sub(maxWidth + 1)
                end
            else
                currentLine = word
            end
        end
    end

    if currentLine ~= "" then
        table.insert(lines, currentLine)
    end

    return lines
end

function dialog.create(options)
    options = options or {}
    local title = options.title or "Dialog"
    local message = options.message or ""
    local inputConfig = options.input or {}
    local buttons = options.buttons or {{text = "OK", action = function() end}}
    local desktopManager = require("libraries.private.screenManager").getScreen("desktop")
    local activeDesktop = desktopManager.getActive()
    local desktopW, desktopH = activeDesktop.frame:getSize()

    local maxDialogWidth = math.floor(desktopW * 0.75)
    local maxDialogHeight = math.floor(desktopH * 0.75)

    local minWidth = 28
    local titleWidth = #title + 4
    local messageWidth = 0

    if message and message ~= "" then
        for word in message:gmatch("%S+") do
            messageWidth = math.max(messageWidth, #word + 4)
        end
    end

    local dialogWidth = math.max(minWidth, math.min(math.max(titleWidth, messageWidth), maxDialogWidth))

    local messageLines = {}
    if message and message ~= "" then
        messageLines = wrapText(message, dialogWidth - 4)
    end

    local dialogHeight = 2    if title and title ~= "" then
        dialogHeight = dialogHeight + 2
    end

    if #messageLines > 0 then
        dialogHeight = dialogHeight + #messageLines + 1
    end

    if inputConfig.label or inputConfig.value or inputConfig.placeholder then
        if inputConfig.label then
            dialogHeight = dialogHeight + 1
        end
        dialogHeight = dialogHeight + 2
    end

    dialogHeight = dialogHeight + 1

    if dialogHeight > maxDialogHeight then
        dialogHeight = maxDialogHeight
    end

    local x = math.floor((desktopW - dialogWidth) / 2)
    local y = math.floor((desktopH - dialogHeight) / 2)

    local frame = require("libraries.private.os.frame")
    local dialogFrame = frame.create(x, y, dialogWidth, dialogHeight, {
        background = colors.lightGray,
        z = 1000,
    })

    local canvas = dialogFrame:getCanvas()
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

    local currentY = 2    if title and title ~= "" then
        dialogFrame:addLabel({
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

    if #messageLines > 0 then
        for i, line in ipairs(messageLines) do
            dialogFrame:addLabel({
                x = 2,
                y = currentY,
                width = dialogWidth - 2,
                height = 1,
                text = line,
                background = colors.lightGray,
                foreground = colors.black
            })
            currentY = currentY + 1
        end
        currentY = currentY + 1
    end

    local inputField = nil

    if inputConfig.label or inputConfig.value or inputConfig.placeholder then
        if inputConfig.label then
            dialogFrame:addLabel({
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

        inputField = dialogFrame:addTextBox({
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
        local button = dialogFrame:addButton({
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
            dialogFrame:destroy()
        end)

        buttonX = buttonX + buttonWidth + 1
    end

    dialogFrame.basalt.schedule(function()
        sleep(0.05)
        dialogFrame:setFocused(true)
        if inputField then
            inputField:setFocused(true)
        end
    end)

    local destroyed = false
    dialogFrame:onBlur(function()
        if not destroyed then
            dialogFrame:setVisible(false)
            dialogFrame.basalt.schedule(function()
                sleep(0.05)
                dialogFrame:destroy()
            end)
            destroyed = true
        end
    end)

    return dialogFrame
end

function dialog.input(title, message, defaultValue, callback)
    return dialog.create({
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

function dialog.confirm(title, message, callback)
    return dialog.create({
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
                    if callback then callback(true) end
                end
            }
        }
    })
end

function dialog.error(title, message, callback)
    logger.error(message)
    return dialog.create({
        title = title or "Error",
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

function dialog.file(title, filter, callback, initialPath)
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

    local frame = require("libraries.private.os.frame")
    local dialogFrame = frame.create(x, y, dialogWidth, dialogHeight, {
        background = colors.lightGray,
        z = 1000,
    })

    local canvas = dialogFrame:getCanvas()
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

    dialogFrame:addLabel({
        x = 2,
        y = 2,
        text = title,
        foreground = colors.black
    })

    local pathLabel = dialogFrame:addLabel({
        x = 2,
        y = 3,
        width = dialogWidth - 4,
        text = currentPath,
        foreground = colors.blue
    })

    local fileList = dialogFrame:addList({
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

    local selectBtn = dialogFrame:addButton({
        x = 2,
        y = buttonY,
        width = 8,
        height = 1,
        text = "Select",
        background = colors.green,
        foreground = colors.white
    })

    local cancelBtn = dialogFrame:addButton({
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
            dialogFrame:destroy()
            if callback then
                callback(selectedFile)
            end
        end
    end)

    cancelBtn:onClick(function()
        dialogFrame:destroy()
        if callback then
            callback(nil)
        end
    end)

    updateFileList()

    return dialogFrame
end

function dialog.showAppSelection(extension, actionType, callback)
    local appManager = require("libraries.private.appManager")
    local apps = appManager.getApps()
    local availableApps = {}
    local selectedApp = nil

    for appName, appData in pairs(apps) do
        if appData.fileAssociations then
            local associations = appData.fileAssociations[extension] or appData.fileAssociations["*"]
            if associations and (associations[actionType] or associations["*"]) then
                table.insert(availableApps, appName)
            end
        end
    end

    if #availableApps == 0 then
        for appName, _ in pairs(apps) do
            table.insert(availableApps, appName)
        end
    end

    table.sort(availableApps)

    local title = "Select App for " .. extension .. " (" .. actionType .. ")"

    local desktopManager = require("libraries.private.screenManager").getScreen("desktop")
    local activeDesktop = desktopManager.getActive()

    local desktopW, desktopH = activeDesktop.frame:getSize()
    local dialogWidth = math.min(30, desktopW - 4)
    local dialogHeight = math.min(15, desktopH - 4)

    local x = math.floor((desktopW - dialogWidth) / 2)
    local y = math.floor((desktopH - dialogHeight) / 2)

    local dialogFrame = activeDesktop.frame:addFrame({
        x = x,
        y = y,
        width = dialogWidth,
        height = dialogHeight,
        background = colors.lightGray,
        border = false,
        z = 999
    })

    local canvas = dialogFrame:getCanvas()
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

    dialogFrame:addLabel({
        x = 2,
        y = 2,
        text = title,
        foreground = colors.black
    })

    local appList = dialogFrame:addList({
        x = 2,
        y = 4,
        width = dialogWidth - 2,
        height = dialogHeight - 6,
        background = colors.white,
        foreground = colors.black,
        selectionBackground = colors.blue,
        selectionForeground = colors.white
    })

    for _, appName in ipairs(availableApps) do
        appList:addItem(appName, colors.black)
    end

    appList:onSelect(function(self, event, item, index)
        if item then
            selectedApp = item.text
        end
    end)
      local buttonY = dialogHeight - 1
    local buttonWidth = math.floor((dialogWidth - 6) / 2)

    local selectBtn = dialogFrame:addButton({
        x = 2,
        y = buttonY,
        width = buttonWidth,
        height = 1,
        text = "Select",
        background = colors.green,
        foreground = colors.white
    })

    local cancelBtn = dialogFrame:addButton({
        x = 2 + buttonWidth + 2,
        y = buttonY,
        width = buttonWidth,
        height = 1,
        text = "Cancel",
        background = colors.red,
        foreground = colors.white
    })

    selectBtn:onClick(function()
        if selectedApp then
            dialogFrame:destroy()
            if callback then callback(selectedApp) end
        end
    end)

    cancelBtn:onClick(function()
        dialogFrame:destroy()
        if callback then callback(nil) end
    end)

    return dialogFrame
end

return dialog
