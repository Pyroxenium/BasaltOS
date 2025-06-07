local pathManager = require("libraries.public.path")
local store = require("store")
local desktopManager = require("libraries.private.screenManager").getScreen("desktop")

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

-- App Manager
local appManager = {}
appManager.apps = {}

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

-- Path to manifest file
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
        manifest.path = basePath -- Store the base path in manifest
        appManager.apps[manifest.name] = app.new(manifest)
        store.set("apps", manifest.name, {path=basePath, name=manifest.name})
    end
end

for k,v in pairs(store.getCategory("apps")) do
    appManager.registerApp(v.path)
end



return appManager