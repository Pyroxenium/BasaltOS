-- /services/desktop.lua
-- Desktop service: Main desktop environment after login

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")

local function theme(key) return config.get("theme." .. key) end

local api = api_factory.new()

local is_running = false

function api.public.init()
    local ui = service.getService("ui")
    if ui then
        ui.registerScreen("desktop", api.private.buildDesktop)
    end

    event.on("user.login", function(username)
        is_running = true
    end)

    event.on("user.logout", function()
        is_running = false

        local ui = service.getService("ui")
        if ui then
            ui.switchScreen("login")
        end
    end)
end

function api.private.buildDesktop(frame, username)
    frame:setBackground(theme("desktop_bg"))

    frame:addLabel()
        :setText("Welcome to BasaltOS, " .. username .. "!")
        :setPosition(2, 2)
        :setForeground(colors.white)

    frame:addLabel()
        :setText("System is running...")
        :setPosition(2, 4)
        :setForeground(colors.lightGray)

    -- Terminal launch button
    local terminalBtn = frame:addButton()
        :setText("Terminal")
        :setPosition(2, 6)
        :setSize(12, 1)
        :setBackground(colors.gray)
        :setForeground(colors.white)
    
    terminalBtn:onClick(function()
        local process = service.getService("process")
        if process then
            process.startProgram("basaltterminal", "system/apps/basaltterminal/main.lua", {})
        end
    end)

    -- Filely launch button
    local filelyBtn = frame:addButton()
        :setText("Files")
        :setPosition(15, 6)
        :setSize(12, 1)
        :setBackground(colors.gray)
        :setForeground(colors.white)
    
    filelyBtn:onClick(function()
        local process = service.getService("process")
        if process then
            process.startProgram("filely", "system/apps/filely/main.lua", {})
        end
    end)

    -- Test notification buttons
    local testNotifyBtn1 = frame:addButton()
        :setText("Test Info")
        :setPosition(2, 6)
        :setSize(12, 1)
        :setBackground(colors.blue)
        :setForeground(colors.white)
    
    testNotifyBtn1:onClick(function()
        local notify = service.getService("notification")
        if notify then
            notify.info("Test", "This is an info notification")
        end
    end)

    local testNotifyBtn2 = frame:addButton()
        :setText("Test Success")
        :setPosition(15, 6)
        :setSize(12, 1)
        :setBackground(colors.green)
        :setForeground(colors.white)
    
    testNotifyBtn2:onClick(function()
        local notify = service.getService("notification")
        if notify then
            notify.success("Success", "Operation completed!")
        end
    end)

    local testNotifyBtn3 = frame:addButton()
        :setText("Test Warning")
        :setPosition(2, 7)
        :setSize(12, 1)
        :setBackground(colors.orange)
        :setForeground(colors.white)

    testNotifyBtn3:onClick(function()
        local notify = service.getService("notification")
        if notify then
            notify.warning("Warning", "Something to check")
        end
    end)

    local testNotifyBtn4 = frame:addButton()
        :setText("Test Error")
        :setPosition(15, 7)
        :setSize(12, 1)
        :setBackground(colors.red)
        :setForeground(colors.white)

    testNotifyBtn4:onClick(function()
        local notify = service.getService("notification")
        if notify then
            notify.error("Error", "Something went wrong!")
        end
    end)

    -- Test dialog buttons
    local testDialogBtn1 = frame:addButton()
        :setText("Test Alert")
        :setPosition(2, 9)
        :setSize(12, 1)
        :setBackground(colors.gray)
        :setForeground(colors.white)
    
    testDialogBtn1:onClick(function()
        local dialog = service.getService("dialog")
        if dialog then
            dialog.alert("Alert", "This is an alert message!", function()
                local notify = service.getService("notification")
                if notify then
                    notify.info("Alert", "OK clicked")
                end
            end)
        end
    end)

    local testDialogBtn2 = frame:addButton()
        :setText("Test Confirm")
        :setPosition(15, 9)
        :setSize(12, 1)
        :setBackground(colors.gray)
        :setForeground(colors.white)
    
    testDialogBtn2:onClick(function()
        local dialog = service.getService("dialog")
        if dialog then
            dialog.confirm("Confirm", "Do you want to proceed?", function(result)
                local notify = service.getService("notification")
                if notify then
                    if result then
                        notify.success("Confirm", "OK clicked")
                    else
                        notify.warning("Confirm", "Cancel clicked")
                    end
                end
            end)
        end
    end)

    local testDialogBtn3 = frame:addButton()
        :setText("Test Prompt")
        :setPosition(2, 10)
        :setSize(12, 1)
        :setBackground(colors.gray)
        :setForeground(colors.white)

    testDialogBtn3:onClick(function()
        local dialog = service.getService("dialog")
        if dialog then
            dialog.prompt("Prompt", "Enter your name:", "Guest", function(result)
                local notify = service.getService("notification")
                if notify then
                    if result then
                        notify.info("Prompt", "Hello, " .. result .. "!")
                    else
                        notify.warning("Prompt", "Cancelled")
                    end
                end
            end)
        end
    end)

    local testDialogBtn4 = frame:addButton()
        :setText("Long Alert")
        :setPosition(15, 10)
        :setSize(12, 1)
        :setBackground(colors.gray)
        :setForeground(colors.white)

    testDialogBtn4:onClick(function()
        local dialog = service.getService("dialog")
        if dialog then
            dialog.alert("Error Details", "An unexpected error occurred while processing your request. The system encountered a nil value at line 42 and could not continue execution.")
        end
    end)

    event.dispatch("desktop.created", username)
    return frame
end

function api.public.isRunning()
    return is_running
end

return api
