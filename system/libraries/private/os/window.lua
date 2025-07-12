local window = {}

function window.createWindow()
    local desktopManager = require("libraries.private.screenManager").getScreen("desktop")
    local activeDesktop = desktopManager.getActive()

    if activeDesktop and activeDesktop.registerDraggableItem then
        return activeDesktop:createWindow({
            x = 0,
            y = 0,
            width = 800,
            height = 600,
            background = colors.white,
            foreground = colors.black,
        })
    end
end

return window
