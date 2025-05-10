local basalt = require("libraries/private/basalt")
local users = require("auth/users")
local session = require("auth/session")

local login = {}
local screen

function login.create(core)
    screen = basalt.createFrame()
    screen:addLabel({text="Login"})
    screen:addButton():setText("Login"):setPosition(4, 4):onClick(function()
        core.switchScreen("desktop")
    end)
    return screen
end

function login.get()
    if not screen then
        login.create()
    end
    return screen
end

return login