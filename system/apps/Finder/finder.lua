local BasaltOS = require("basaltos")
local basalt = require("basalt")

local main = basalt.getMainFrame()

local testLabel = main:addLabel({
    text = "Hello World",
})

local btn = main:addButton({
    text = "Click Me",
    width = 10,
    height = 3,
    x = 5,
    y = 5,
})

basalt.run()