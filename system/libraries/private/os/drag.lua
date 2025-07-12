-- Drag & Drop System for BasaltOS
-- Minimal API for registering draggable items

local drag = {}

function drag.registerDraggableItem(filePath, fileName, sourceWindow, localX, localY)
    local desktopManager = require("libraries.private.screenManager").getScreen("desktop")
    local activeDesktop = desktopManager.getActive()

    if activeDesktop and activeDesktop.registerDraggableItem then
        return activeDesktop:registerDraggableItem(filePath, fileName, sourceWindow, localX, localY)
    end
end

return drag
