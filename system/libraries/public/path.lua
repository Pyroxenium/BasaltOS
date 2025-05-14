local args = {...}
local systemPath = args[2]:gsub("/libraries/public/path.lua", "") or "system"

local path = {}

function path.resolve(_path)
    _path = _path:gsub("{system}", systemPath)
    _path = _path:gsub("{apps}", systemPath .. "/apps")
    _path = _path:gsub("{assets}", systemPath .. "/assets")
    return _path
end

function path.getAppPath()
    return systemPath .. "/apps/"
end

return path