-- /core/app_api.lua
-- App API: Public interface for applications to interact with the OS

local app_api = {}

-- Service access (read-only public APIs)
local service_loader = require("core.service")

local function getServicePublicApi(name)
    return service_loader.getService(name)
end

setmetatable(app_api, {
    __index = function(t, key)
        local svc = getServicePublicApi(key)
        if svc then return svc end
        return nil
    end
})

return app_api