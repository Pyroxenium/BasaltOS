
local store = {
    data = {},
    cache = {}
}

function store.set(category, key, value)
    if not store.data[category] then
        store.data[category] = {}
    end
    store.data[category][key] = value
    store.save(category)
end

function store.get(category, key)
    if store.data[category] then
        return store.data[category][key]
    end
end

function store.save(category)
    if(not category) then
        for cat, _ in pairs(store.data) do
            store.save(cat)
        end
        return
    end
    local path = "system/data/"..category..".json"
    local file = fs.open(path, "w")
    file.write(textutils.serializeJSON(store.data[category]))
    file.close()
end

function store.load()
    if not fs.exists("system/data") then
        fs.makeDir("system/data")
        return
    end

    local files = fs.list("system/data")
    for _, file in ipairs(files) do
        local category = file:match("(.+)%.json$")
        if category then
            local path = "system/data/"..file
            local handle = fs.open(path, "r")
            if handle then
                local content = handle.readAll()
                handle.close()
                store.data[category] = textutils.unserializeJSON(content) or {}
            end
        end
    end
end

function store.getCategory(category)
    if store.data[category] then
        return store.data[category]
    end
end

function store.setCache(category, key, value)
    if not store.cache[category] then
        store.cache[category] = {}
    end
    store.cache[category][key] = value
end

function store.getCache(category, key)
    if store.cache[category] then
        return store.cache[category][key]
    end
end

function store.clearCache(category)
    if category then
        store.cache[category] = {}
    else
        store.cache = {}
    end
end

return store