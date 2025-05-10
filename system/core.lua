local defaultPath = package.path
local format = "path;/path/?.lua;/path/?/init.lua;"

local libs = format:gsub("path", "system/libraries/public/")
local main = format:gsub("path", "system/")
package.path = libs..main..defaultPath

local basalt = require("libraries/private/basalt")
local store = require("store")
local process = require("processManager")
local screens = {}
local backgroundProcess = {}

local make_package = dofile("rom/modules/main/cc/require.lua").make

local function createEnvironment(dir, _env) -- TODO: Create multishell wrapper for desktop windowManager instead of cc tweaked multishell
    _env = _env or {}
    local env = setmetatable(_env, {__index=_ENV})
    env.shell = shell
    env.require, env.package = make_package(env, fs.getDir(dir))

    return env
end

local core = {
    version = "1.0.0",
    name = "Basalt OS Template",
    isRunning = false,
    LOGGER = require("logging")
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

function core.getScreen(screen)
    if screens[screen] then
        return screens[screen]
    else
        local curPath = package.path
        package.path = package.path .. format:gsub("path", "system/screens/")
        screens[screen] = require(screen)
        package.path = curPath
        screens[screen].create(core)
        return screens[screen]
    end
end

function core.switchScreen(screen)
    if screens[screen] then
        basalt.setActiveFrame(screens[screen].get())
    else
        local curPath = package.path
        package.path = package.path .. libs .. main
        screens[screen] = require("screens/"..screen)
        package.path = curPath
        screens[screen].create(core)
        if screens[screen] then
            basalt.setActiveFrame(screens[screen].get())
        else
            error("Screen not found: " .. screen)
        end
    end
end

function core.createProcess(app, manifest)
    local process = process.create(app, manifest)
    if process then
        return process
    else
        error("Failed to create process: " .. app.name)
    end
end

function core.removeProcess(pid)
    process.remove(pid)
end

function core.getProcess(pid)
    local process = process.get(pid)
    if process then
        return process
    else
        error("Process not found: " .. pid)
    end
end

function core.openApp(name)
    local apps = store.getCategory("apps")
    if apps and apps[name] then
        local app = apps[name]
        if app.path then
            local manifest = core.getAppManifest(name)
            local pid = core.createProcess(app, manifest)
            local process = core.getProcess(pid)

            if(process.manifest.singleInstance)then
                local processes = process.findByName(name)
                if #processes > 0 then
                    for _, proc in ipairs(processes) do
                        proc.process:stop()
                    end
                end
            end

            if process then
                if(process.manifest.background)then
                    core.launchBackgroundApp(process)
                else
                    if(screens.desktop)then
                        screens.desktop.launchApp(process)
                    else
                        error("Desktop not found")
                    end
                end
                return process
            else
                error("Failed to run app: " .. name)
            end
        else
            print("App path not found for " .. name)
        end
    else
        error("App not found: " .. name)
    end
end

function core.getAppManifest(name)
    local apps = store.getCategory("apps")
    if apps and apps[name] then
        local app = apps[name]
        local manifestPath = app.path:gsub(".lua", ".json")
        if fs.exists(manifestPath) then
            local file = fs.open(manifestPath, "r")
            local content = file.readAll()
            file.close()
            return core.updateManifest(textutils.unserialiseJSON(content))
        else
            return core.createDefaultManifest(app.path, app.name)
        end
    else
        error("App not found: " .. name)
    end
end

function core.getApp(name)
    local apps = store.getCategory("apps")
    if apps and apps[name] then
        return apps[name]
    else
        error("App not found: " .. name)
    end
end

function core.updateManifest(manifest)
    if manifest.windows == nil then
        manifest.windows = {}
    end
    if manifest.windows.width == nil then
        manifest.windows.width = desktop.get():getWidth() - 4
    end
    if manifest.windows.height == nil then
        manifest.windows.height = desktop.get():getHeight() - 4
    end
    if manifest.windows.title == nil then
        manifest.windows.title = manifest.name:sub(1,1):upper() .. manifest.name:sub(2)
    end
    return manifest
end

function core.createDefaultManifest(path, appName)
    local manifest = {
        name = appName,
        path = path,
        windows = {
            width = 25,
            height = 10,
            title = appName:sub(1,1):upper() .. appName:sub(2),
        }
    }
    return manifest
end

function core.registerApp(path)
    local appName = path:match("([^/]+)$"):gsub(".lua", "")
    local app = {path = path, name = appName}
    store.set("apps", appName, app)
    store.save("apps")
    core.LOGGER.info("App registered: " .. appName)
end

function core.thread(fn)
    basalt.schedule(fn)
end

function core.launchBackgroundApp(process, ...)
    local args = {...}
    table.insert(backgroundProcess, process)
    process.window = window.create(term.current(), 1, 1, 51, 19, false)
    process.coroutine = coroutine.create(function()
        if(fs.exists(process.path)) then
            local file = fs.open(process.path, "r")
            local content = file.readAll()
            file.close()
            local env = createEnvironment(process.path, process.env)
            env.term = process.window
            process:start()

            local program = load(content, process.path, "bt", env)
            if program then
                local current = term.current()
                term.redirect(process.window)
                local result = program(process.path, table.unpack(args))
                term.redirect(current)
                return result
            end
        end
    end)
    local current = term.current()
    term.redirect(process.window)
    local ok, result = coroutine.resume(process.coroutine, ...)
    term.redirect(current)
    if not ok then
        error("Error in background app: " .. process.path .. "\n" .. result)
    end
end

function core.init()
    store.load()
    core.registerApp("system/apps/Finder/finder.lua")
    --core.switchScreen("login")
    core.switchScreen("desktop")
    core.run()
end

core.init()


return core