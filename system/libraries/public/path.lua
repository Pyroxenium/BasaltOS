local args = {...}
local systemPath = args[2]:gsub("/libraries/public/path.lua", "") or "system"

local path = {}

function path.resolve(_path)
    _path = _path:gsub("{system}", systemPath)
    _path = _path:gsub("{apps}", systemPath .. "/apps")
    _path = _path:gsub("{assets}", systemPath .. "/assets")
    return _path:gsub("//", "/")
end

function path.getAppPath()
    return systemPath .. "/apps/"
end

function path.join(...)
    local parts = {...}
    local path = ""

    for i, part in ipairs(parts) do
        if part:sub(1, 1) == "/" then
            part = part:sub(2)
        end
        if i > 1 then
            path = path .. "/"
        end
        path = path .. part
    end

    return path:gsub("//", "/")
end

return path