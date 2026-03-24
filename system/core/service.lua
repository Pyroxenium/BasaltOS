-- /system/core/service.lua
-- Service registry: Manages system services with public/private APIs

local registered_public_apis = {}
local registered_private_apis = {}

local function register(service_name, path)
    local ok, service_object = pcall(require, path)

    if not ok then
        error("Could not load service '" .. service_name .. "': " .. tostring(service_object))
        return
    end

    if service_object.public then
        registered_public_apis[service_name] = service_object.public
    end

    if service_object.private then
        registered_private_apis[service_name] = service_object.private
    end

    if registered_private_apis[service_name] and registered_public_apis[service_name] then
         setmetatable(registered_private_apis[service_name], { __index = registered_public_apis[service_name] })
    end
end

local function getPublicService(service_name)
    return registered_public_apis[service_name]
end

local function getPrivateService(service_name)
    return registered_private_apis[service_name]
end

local function getAllServices()
    return registered_public_apis
end

local function isRegistered(service_name)
    return registered_public_apis[service_name] ~= nil or registered_private_apis[service_name] ~= nil
end

return {
    register = register,
    getService = getPublicService,
    getPrivateApi = getPrivateService,
    getAllServices = getAllServices,
    isRegistered = isRegistered,
}