-- Frame System for BasaltOS
-- Creates and manages UI frames on the desktop

local frame = {}

function frame.create(x, y, width, height, options)
    options = options or {}
    local desktopManager = require("libraries.private.screenManager").getScreen("desktop")
    local activeDesktop = desktopManager.getActive()

    local frameElement = activeDesktop.frame:addFrame({
        x = x,
        y = y,
        width = width,
        height = height,
        background = options.background or colors.white,
        foreground = options.foreground or colors.black,
    })

    frameElement:setFocused(true)

    return frameElement
end

return frame
