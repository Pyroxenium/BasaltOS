-- Public BasaltOS API for programs
local theme = require("libraries.private.configs").get("windows")

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

return BasaltOS