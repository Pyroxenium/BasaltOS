local store = require("store")
local path = require("libraries.public.path")

local configs = {
    loaded = {},
}

local function loadConfigFile(category)
    local configPath = path.resolve("{system}/configs/"..category..".json")
    if fs.exists(configPath) then
        local file = fs.open(configPath, "r")
        local content = file.readAll()
        file.close()
        return textutils.unserialiseJSON(content) or {}
    end
    return {}
end

local function loadCategory(category)
    if not configs.loaded[category] then
        configs.loaded[category] = loadConfigFile(category)
        local stored = store.getCategory("config_"..category) or {}
        for key, value in pairs(stored) do
            configs.loaded[category][key] = value
        end
    end
    return configs.loaded[category]
end

function configs.get(category, key)
    local categoryData = loadCategory(category)
    if not key then 
        local t = {}
        for k,v in pairs(categoryData) do
            t[k] = colors[v] or v
        end
        return t
     end
    return colors[categoryData[key]] or categoryData[key]
end

function configs.set(category, key, value)
    local categoryData = loadCategory(category)
    categoryData[key] = value
    store.set("config_"..category, key, value)
    store.save("config_"..category)
end

return configs
