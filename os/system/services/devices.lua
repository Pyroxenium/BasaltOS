-- /system/services/devices.lua
-- Central peripheral inventory and Rednet lifecycle service.

local api_factory = require("core.api")
local event = require("core.event")
local log = require("core.log")

local api = api_factory.new()
local unpack = table.unpack or unpack
local pack = table.pack or function(...)
    return {n=select("#", ...), ...}
end

local devices = {}
local managed_modems = {}
local rednet_requested = false

local function copyArray(values)
    local result = {}
    for index, value in ipairs(values or {}) do result[index] = value end
    return result
end

local function publicDescriptor(device)
    if not device then return nil end
    return {
        name=device.name,
        type=device.type,
        types=copyArray(device.types),
        methods=copyArray(device.methods),
        present=device.present == true,
        isModem=device.isModem == true,
    }
end

local function contains(values, wanted)
    for _, value in ipairs(values or {}) do
        if value == wanted then return true end
    end
    return false
end

local function safeIsPresent(name)
    local ok, result = pcall(peripheral.isPresent, name)
    return ok and result == true
end

local function safeIsRednetOpen(name)
    local ok, result = pcall(rednet.isOpen, name)
    return ok and result == true
end

local function describe(name)
    if type(name) ~= "string" or name == "" or not safeIsPresent(name) then
        return nil
    end

    local type_result = pack(pcall(peripheral.getType, name))
    if not type_result[1] then return nil end

    local types = {}
    local primary_type = nil
    for index = 2, type_result.n do
        if type(type_result[index]) == "string" then
            if not primary_type then primary_type = type_result[index] end
            types[#types + 1] = type_result[index]
        end
    end
    table.sort(types)
    if #types == 0 then types[1] = "unknown" end

    local methods = {}
    local methods_ok, methods_result = pcall(peripheral.getMethods, name)
    if methods_ok and type(methods_result) == "table" then
        for _, method in ipairs(methods_result) do
            if type(method) == "string" then methods[#methods + 1] = method end
        end
        table.sort(methods)
    end

    return {
        name=name,
        type=primary_type or types[1],
        types=types,
        methods=methods,
        present=true,
        isModem=contains(types, "modem"),
        signature=table.concat(types, "\0") .. "|" .. table.concat(methods, "\0"),
    }
end

local function dispatchChange(action, name, descriptor)
    local copy = publicDescriptor(descriptor)
    event.dispatch("devices." .. action, name, copy)
    event.dispatch("devices.changed", action, name, copy)
end

local function sortedNames(source)
    local names = {}
    for name in pairs(source) do names[#names + 1] = name end
    table.sort(names)
    return names
end

local function dispatchRednetChanged()
    event.dispatch("devices.rednet_changed", api.public.getRednetStatus())
end

function api.public.init()
    api.private.refresh(true)

    event.on("peripheral", function(name)
        api.private.refreshDevice(name)
    end)

    event.on("peripheral_detach", function(name)
        api.private.removeDevice(name)
    end)

    event.on("system.shutdown", function()
        api.private.closeManagedModems()
    end)

    log.info("DEVICES", "Device service initialized", {
        count=api.public.count(),
    })
    event.dispatch("devices.ready", api.public.list())
end

function api.public.list(device_type)
    local result = {}
    for _, name in ipairs(sortedNames(devices)) do
        local device = devices[name]
        if not device_type or contains(device.types, device_type) then
            result[#result + 1] = publicDescriptor(device)
        end
    end
    table.sort(result, function(left, right)
        if left.type == right.type then return left.name < right.name end
        return left.type < right.type
    end)
    return result
end

function api.public.get(name)
    return publicDescriptor(devices[name])
end

function api.public.count(device_type)
    if device_type then return #api.public.list(device_type) end
    local count = 0
    for _ in pairs(devices) do count = count + 1 end
    return count
end

function api.public.exists(name)
    return devices[name] ~= nil and safeIsPresent(name)
end

function api.public.hasType(name, device_type)
    local device = devices[name]
    return device ~= nil and contains(device.types, device_type)
end

function api.public.getTypes(name)
    local device = devices[name]
    return device and copyArray(device.types) or {}
end

function api.public.getMethods(name)
    local device = devices[name]
    return device and copyArray(device.methods) or {}
end

function api.public.find(device_type)
    return api.public.list(device_type)
end

-- Returns success followed by all values returned from peripheral.call.
function api.public.call(name, method, ...)
    local device = devices[name]
    if not device then return false, "Device not found: " .. tostring(name) end
    if type(method) ~= "string" or not contains(device.methods, method) then
        return false, "Method not available: " .. tostring(method)
    end

    local result = pack(pcall(peripheral.call, name, method, ...))
    if not result[1] then return false, tostring(result[2]) end
    return true, unpack(result, 2, result.n)
end

function api.public.refresh()
    return api.private.refresh(false)
end

function api.public.getModems()
    return api.public.list("modem")
end

function api.public.openModem(name)
    if not api.public.hasType(name, "modem") then
        return false, "Modem not found: " .. tostring(name)
    end
    if safeIsRednetOpen(name) then return true end

    local ok, err = pcall(rednet.open, name)
    if not ok or not safeIsRednetOpen(name) then
        return false, ok and "Could not open modem" or tostring(err)
    end
    managed_modems[name] = true
    log.info("DEVICES", "Rednet modem opened", {name=name})
    dispatchRednetChanged()
    return true
end

function api.public.closeModem(name)
    if not api.public.hasType(name, "modem") then
        return false, "Modem not found: " .. tostring(name)
    end
    local ok, err = pcall(rednet.close, name)
    if not ok then return false, tostring(err) end
    managed_modems[name] = nil
    log.info("DEVICES", "Rednet modem closed", {name=name})
    dispatchRednetChanged()
    return true
end

-- Keeps Rednet available. Newly attached modems are opened automatically
-- until disableRednet is called.
function api.public.ensureRednet()
    rednet_requested = true
    local errors = {}

    for _, modem in ipairs(api.public.getModems()) do
        local ok, err = api.public.openModem(modem.name)
        if not ok then errors[#errors + 1] = modem.name .. ": " .. tostring(err) end
    end

    local status = api.public.getRednetStatus()
    if status.openCount > 0 then return true, status end
    if #status.modems == 0 then return false, "No modem attached", status end
    return false, table.concat(errors, "; "), status
end

function api.public.disableRednet()
    rednet_requested = false
    api.private.closeManagedModems()
    dispatchRednetChanged()
    return true
end

function api.public.isRednetOpen(name)
    if name then return safeIsRednetOpen(name) end
    for _, modem in ipairs(api.public.getModems()) do
        if safeIsRednetOpen(modem.name) then return true end
    end
    return false
end

function api.public.getRednetStatus()
    local modems = {}
    local open_count = 0
    for _, modem in ipairs(api.public.getModems()) do
        local is_open = safeIsRednetOpen(modem.name)
        if is_open then open_count = open_count + 1 end
        modems[#modems + 1] = {
            name=modem.name,
            open=is_open,
            managed=managed_modems[modem.name] == true,
        }
    end
    return {
        requested=rednet_requested,
        availableCount=#modems,
        openCount=open_count,
        modems=modems,
    }
end

function api.private.refresh(silent)
    local seen = {}
    local attached, updated, detached = 0, 0, 0

    for _, name in ipairs(peripheral.getNames()) do
        seen[name] = true
        local action = api.private.refreshDevice(name, silent)
        if action == "attached" then attached = attached + 1 end
        if action == "updated" then updated = updated + 1 end
    end

    local missing = {}
    for name in pairs(devices) do
        if not seen[name] then missing[#missing + 1] = name end
    end
    for _, name in ipairs(missing) do
        if api.private.removeDevice(name, silent) then detached = detached + 1 end
    end

    return {
        attached=attached,
        updated=updated,
        detached=detached,
        total=api.public.count(),
    }
end

function api.private.refreshDevice(name, silent)
    local descriptor = describe(name)
    if not descriptor then
        api.private.removeDevice(name, silent)
        return nil
    end

    local previous = devices[name]
    local action
    if not previous then
        action = "attached"
    elseif previous.signature ~= descriptor.signature then
        action = "updated"
    end
    devices[name] = descriptor

    if rednet_requested and descriptor.isModem then
        api.public.openModem(name)
    end
    if action and not silent then dispatchChange(action, name, descriptor) end
    return action
end

function api.private.removeDevice(name, silent)
    local previous = devices[name]
    if not previous then return false end
    devices[name] = nil
    managed_modems[name] = nil
    if not silent then dispatchChange("detached", name, previous) end
    if previous.isModem then dispatchRednetChanged() end
    return true
end

function api.private.closeManagedModems()
    local names = sortedNames(managed_modems)
    for _, name in ipairs(names) do
        pcall(rednet.close, name)
        managed_modems[name] = nil
    end
end

return api
