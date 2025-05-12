local basalt = require("libraries/private/basalt")
local dockComponent = require("components/desktop/dock")
local menubarComponent = require("components/desktop/menubar")
local windowsComponent = require("components/desktop/windows")
local store = require("store")

local desktop = {}
local screen
local components = {}

function desktop.create(core)
    desktop.core = core
    screen = basalt.createFrame()
    screen:setBackground(colors.lightGray)

    components.dock = dockComponent.create(desktop)
    components.menubar = menubarComponent.create(desktop)
    components.windows = windowsComponent.create(desktop)

    desktop.addAppToDock("finder")
    return screen
end

function desktop.addAppToDock(name)
    if desktop.core then
        local data = desktop.core.getApp(name)
        local manifest = desktop.core.getAppManifest(name)
        if data and manifest then
            local app = dockComponent.addApp(data, manifest)
            if app then
                return app
            end
        end
    end
end

function desktop.get()
    if not screen then
        desktop.create()
    end
    return screen
end

function desktop.getComponents()
    return components
end

function desktop.getComponent(name)
    return components[name]
end

function desktop.openApp(name)
    return desktop.core.openApp(name)
end

function desktop.closeApp(pid)
    pid = type(pid) == "number" and pid or tonumber(pid.pid)
    local process = desktop.core.getProcess(pid)
    if process then
        desktop.core.removeProcess(pid)
        windowsComponent.removeApp(process)
        dockComponent.removeWindow(process)
    end
end

function desktop.launchApp(process)
    local window = windowsComponent.launchProcess(process)
    dockComponent.addWindow(window)
end

return desktop