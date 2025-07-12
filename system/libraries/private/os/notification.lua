-- Notification System for BasaltOS
-- Handles system notifications and user alerts

local notification = {}

function notification.show(title, message, duration)
    local desktopManager = require("libraries.private.screenManager").getScreen("desktop")
    local activeDesktop = desktopManager.getActive()
    if activeDesktop and activeDesktop.showNotification then
        return activeDesktop:showNotification(title, message, duration)
    end
end

function notification.notify(message, duration)
    return notification.show("Notification", message, duration)
end

return notification
