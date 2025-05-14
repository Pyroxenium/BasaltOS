local configs = require("libraries.private.configs")
local store = require("libraries.private.store")

local manifest = {}

function manifest.update(manifest)

end

function manifest.createDefault(path, appName)
    local manifest = {
        name = appName,
        path = path,
        windows = {
            width = configs.get("windows", "defaultWidth") or 25,
            height = configs.get("windows", "defaultHeight") or 10,
            title = appName:sub(1,1):upper() .. appName:sub(2),
        }
    }
    return manifest
end

function manifest.getAppManifest(name)
    local apps = store.getCategory("apps")
    if apps and apps[name] then
        local app = apps[name]
        local manifestPath = app.path:gsub(".lua", ".json")
        if fs.exists(manifestPath) then
            local file = fs.open(manifestPath, "r")
            local content = file.readAll()
            file.close()
            return manifest.update(textutils.unserialiseJSON(content))
        else
            return manifest.createDefault(app.path, app.name)
        end
    else
        error("App not found: " .. name)
    end
end

return manifest