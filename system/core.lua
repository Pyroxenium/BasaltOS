local defaultPath = package.path
local format = "path;/path/?.lua;/path/?/init.lua;"

local libs = format:gsub("path", shell.dir().."/system/libraries/public/")
local main = format:gsub("path", shell.dir().."/system/")
package.path = libs..main..defaultPath

local basalt = require("libraries.public.basalt")
local screenManager = require("libraries.private.screenManager")
local appManager = require("libraries.private.appManager")
local desktop
--local store = require("libraries.private.store")
local backgroundProcess = {}

local core = {
    version = "1.0.0",
    name = "Basalt OS Template",
    isRunning = false,
    LOGGER = require("libraries.private.log")
}

local function handleBackgroundProcess(event, ...)
    for i, process in ipairs(backgroundProcess) do
        if process.coroutine and coroutine.status(process.coroutine) == "suspended" then
            if process.filter==nil or event==process.filter then
                process.filter=nil
                local ok, result = coroutine.resume(process.coroutine, event, ...)
                if not ok then
                    error("Error in background app: " .. process.path .. "\n" .. result)
                else
                    process.filter = result
                end
            end
            if coroutine.status(process.coroutine) == "dead" then
                table.remove(backgroundProcess, i)
            end
        end
    end
end

-- Event management
function core.handleEvents(event)
    handleBackgroundProcess(table.unpack(event))
    basalt.update(table.unpack(event))
end

function core.run()
    if not core.isRunning then
        core.isRunning = true
    while true do
        local event = {os.pullEventRaw()}
        if event[1] == "terminate" then
            term.clear()
            term.setCursorPos(1, 1)
            break
        end
        core.handleEvents(event)
    end
    core.isRunning = false
    end
end

function core.thread(fn)
    basalt.schedule(fn)
end


--- Main entry point for the OS -- should be moved to startup.lua (later)
function core.init()
    -- Application Registry
    appManager.registerApp("{system}/apps/Finder/finder")
    appManager.registerApp("{system}/apps/Edit/edit")
    appManager.registerApp("{system}/apps/Worm/worm")
    appManager.registerApp("{system}/apps/AppLauncher/applauncher")

    --core.switchScreen("login")

    -- Desktop screen
    desktop = screenManager.switchScreen("desktop")
    local activeDesktop = desktop.getActive()

    -- Pin specific apps to the dock
    local finderIcon = activeDesktop.dock:add(appManager.getApp("Finder"))
    finderIcon:setPinned(true)
    
    local wormIcon = activeDesktop.dock:add(appManager.getApp("Worm"))
    wormIcon:setPinned(true)
    
    local launcherIcon = activeDesktop.dock:add(appManager.getApp("AppLauncher"))
    launcherIcon:setPinned(true)
    
    core.run()
end

core.init()


return core