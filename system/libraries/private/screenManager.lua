local format = "path;/path/?.lua;/path/?/init.lua;"
local libs = format:gsub("path", "system/libraries/public/")
local main = format:gsub("path", "system/")

local basalt = require("libraries.public.basalt")

local screens = {}
local screenManager = {}

function screenManager.getScreen(screen)
    if screens[screen] then
        return screens[screen]
    else
        local curPath = package.path
        package.path = package.path .. libs .. main
        screens[screen] = require("screens/"..screen)
        package.path = curPath
        screens[screen].create()
        return screens[screen]
    end
end

function screenManager.switchScreen(screen)
    if screens[screen] then
        basalt.setActiveFrame(screens[screen].get())
    else
        local curPath = package.path
        package.path = package.path .. libs .. main
        screens[screen] = require("screens/"..screen)
        package.path = curPath
        screens[screen].create()
        if screens[screen] then
            basalt.setActiveFrame(screens[screen].get())
        else
            error("Screen not found: " .. screen)
        end
    end
    return screens[screen]
end

return screenManager