-- /core/api.lua

local function new()
    local api_object = {
        public = {},
        private = {},
    }

    setmetatable(api_object.private, { __index = api_object.public })
    return api_object
end

return { new = new }