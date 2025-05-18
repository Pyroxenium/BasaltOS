local BasaltOS = require("basaltos")
local basalt = require("basalt")
local theme = BasaltOS.getTheme()

local main = basalt.getMainFrame()
main:setBackground(theme.defaultColor)
BasaltOS.setAppFrameColor(theme.defaultColor)
BasaltOS.setMenu({["File"] = function() end})

local topbar = main:addFrame({
    x = 1,
    y = 1,
    width = "{parent.width}",
    height = 2,
    background = colors.black
})

basalt.run()