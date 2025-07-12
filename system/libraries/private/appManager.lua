local pathManager = require("libraries.public.path")
local store = require("store")
local desktopManager = require("libraries.private.screenManager").getScreen("desktop")
local fileRegistry = require("libraries.private.fileRegistry")

-- App API
local app = {}
app.__index = app
app.__tostring = function(self)
    return "App: " .. self.manifest.name
end

function app.new(manifest)
    local self = setmetatable({}, app)
    self.path = manifest.path
    self.manifest = manifest
    return self
end


function app:attachToDock()
    if not self.dockIcon then
        self.dockIcon = desktopManager.getActive().dock:add(self)
        return self.dockIcon
    end
    return self.dockIcon
end

function app:pinToDock()
    local icon = self:attachToDock()
    if icon then
        icon:setPinned(true)
    end
    return icon
end

local appManager = {}
appManager.apps = {}

appManager.protectedApps = {
    "AppLauncher",
    "Finder", 
    "Edit",
    "Shell",
    "Settings"
}

function appManager.addProtectedApp(appName)
    if not appManager.isProtected(appName) then
        table.insert(appManager.protectedApps, appName)
        return true
    end
    return false
end

function appManager.removeProtectedApp(appName)
    for i, name in ipairs(appManager.protectedApps) do
        if name == appName then
            table.remove(appManager.protectedApps, i)
            return true
        end
    end
    return false
end

function appManager.isProtected(appName)
    for _, name in ipairs(appManager.protectedApps) do
        if name == appName then
            return true
        end
    end
    return false
end

function appManager.getProtectedApps()
    return appManager.protectedApps
end

function appManager.getApp(name)
    if appManager.apps[name] then
        return appManager.apps[name]
    else
        error("App not found: " .. name)
    end
end

function appManager.getApps()
    return appManager.apps
end

function appManager.isInstalled(name)
    return appManager.apps[name] ~= nil
end

function appManager.removeApp(appName)
    local app = appManager.apps[appName]
    if not app then
        return false, "App not found: " .. appName
    end

    if appManager.isProtected(appName) then
        return false, "Cannot remove protected app: " .. appName
    end

    local appPath = app.manifest.path
    local appDir = appPath:match("^(.+)/[^/]+%.json$")

    if not appDir then
        return false, "Could not determine app directory for " .. appName
    end

    local success, error = pcall(function()
        if app.manifest.fileAssociations then
            local extensionsToRemove = {}

            if app.manifest.fileAssociations.open then
                for _, ext in ipairs(app.manifest.fileAssociations.open) do
                    if ext ~= "__directory" then
                        table.insert(extensionsToRemove, ext)
                    end
                end
            end

            if app.manifest.fileAssociations.edit then
                for _, ext in ipairs(app.manifest.fileAssociations.edit) do
                    if ext ~= "__directory" then
                        local found = false
                        for _, existing in ipairs(extensionsToRemove) do
                            if existing == ext then
                                found = true
                                break
                            end
                        end
                        if not found then
                            table.insert(extensionsToRemove, ext)
                        end
                    end
                end
            end

            if #extensionsToRemove > 0 then
                fileRegistry.uninstallExtensions(extensionsToRemove)
            end
        end

        fileRegistry.cleanupDeletedApps()

        appManager.apps[appName] = nil
        store.remove("apps", appName)

        if fs.exists(appDir) then
            fs.delete(appDir)
        end
    end)

    if not success then
        return false, "Failed to remove app: " .. tostring(error)
    end

    return true, "App removed successfully"
end

function appManager.canRemoveApp(appName)
    local app = appManager.apps[appName]
    if not app then
        return false, "App not found"
    end

    if appManager.isProtected(appName) then
        return false, "App is protected and cannot be removed"
    end

    return true, "App can be removed"
end

function appManager.registerApp(basePath)
    local path = pathManager.resolve(basePath):gsub(".json", "").. ".json"
    local file = fs.open(path, "r")
    if not file then
        error("Manifest file not found: " .. path)
    end
    local manifest = textutils.unserializeJSON(file.readAll())
    file.close()
    if not appManager.apps[manifest.name] then
        if not manifest then
            error("Invalid manifest file: " .. path)
        end
        manifest.path = basePath
        appManager.apps[manifest.name] = app.new(manifest)
        store.set("apps", manifest.name, {path=basePath, name=manifest.name})

        if manifest.fileAssociations then
            fileRegistry.registerAppHandlers(manifest.name, manifest.fileAssociations)
        end
    end
end

for k,v in pairs(store.getCategory("apps")) do
    appManager.registerApp(v.path)
end



return appManager