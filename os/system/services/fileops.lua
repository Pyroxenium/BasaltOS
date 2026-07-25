-- /services/fileops.lua
-- System-wide user file operations shared by Filely, Desktop and other apps.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")

local api = api_factory.new()

local PAYLOAD_TYPE = "basaltos.file-transfer"
local PAYLOAD_VERSION = 1

local function canonicalPath(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("\\", "/"):gsub("^/+", "")
    local ok, combined = pcall(fs.combine, value, "")
    if not ok then return nil end
    return combined == "" and "/" or combined
end

local function pathInside(path, parent)
    path, parent = canonicalPath(path), canonicalPath(parent)
    if not path or not parent then return false end
    if parent == "/" then return true end
    return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function normalizePaths(value)
    local source = type(value) == "table" and value or {value}
    local paths, seen = {}, {}
    for _, path in ipairs(source) do
        local normalized = canonicalPath(path)
        if not normalized or normalized == "/" then
            return nil, "Invalid source path: " .. tostring(path)
        end
        if not fs.exists(normalized) then
            return nil, "Source does not exist: " .. tostring(path)
        end
        if not seen[normalized] then
            seen[normalized] = true
            paths[#paths + 1] = normalized
        end
    end
    if #paths == 0 then return nil, "No files selected" end
    return paths
end

local function getPayload()
    local clipboard = service.getService("clipboard")
    local value = clipboard and clipboard.get() or nil
    if type(value) ~= "table" or value.type ~= PAYLOAD_TYPE
        or value.version ~= PAYLOAD_VERSION
        or (value.operation ~= "copy" and value.operation ~= "cut")
        or type(value.paths) ~= "table" or #value.paths == 0 then
        return nil
    end
    return value
end

local function clonePayload(payload)
    if not payload then return nil end
    local paths = {}
    for index, path in ipairs(payload.paths) do paths[index] = path end
    return {
        type=payload.type,
        version=payload.version,
        operation=payload.operation,
        paths=paths,
    }
end

local function putPayload(operation, value)
    local paths, err = normalizePaths(value)
    if not paths then return false, err end
    local clipboard = service.getService("clipboard")
    if not clipboard then return false, "Clipboard service unavailable" end

    local payload = {
        type=PAYLOAD_TYPE,
        version=PAYLOAD_VERSION,
        operation=operation,
        paths=paths,
    }
    clipboard.set(payload)
    event.dispatch("fileops.selection_changed", clonePayload(payload))
    log.debug("FILEOPS", "File selection placed on clipboard", {
        operation=operation, count=#paths,
    })
    return true, clonePayload(payload)
end

local function splitName(name, is_directory)
    if is_directory then return name, "" end
    local base, extension = name:match("^(.*)(%.[^%.]+)$")
    if not base or base == "" then return name, "" end
    return base, extension
end

local function uniqueDestination(directory, source, operation)
    local name = fs.getName(source)
    local candidate = fs.combine(directory, name)
    if not fs.exists(candidate) then return candidate end

    local base, extension = splitName(name, fs.isDir(source))
    if operation == "copy" then
        candidate = fs.combine(directory, base .. " - Copy" .. extension)
        if not fs.exists(candidate) then return candidate end
        local index = 2
        repeat
            candidate = fs.combine(directory,
                base .. " - Copy (" .. tostring(index) .. ")" .. extension)
            index = index + 1
        until not fs.exists(candidate)
        return candidate
    end

    local index = 2
    repeat
        candidate = fs.combine(directory,
            base .. " (" .. tostring(index) .. ")" .. extension)
        index = index + 1
    until not fs.exists(candidate)
    return candidate
end

local function validatePaste(payload, destination)
    destination = canonicalPath(destination)
    if not destination or not fs.exists(destination) or not fs.isDir(destination) then
        return nil, "Destination is not a directory"
    end
    if fs.isReadOnly and fs.isReadOnly(destination) then
        return nil, "Destination is read-only"
    end

    for _, source in ipairs(payload.paths) do
        if not fs.exists(source) then
            return nil, "Source no longer exists: " .. tostring(source)
        end
        if payload.operation == "cut"
            and canonicalPath(fs.getDir(source)) == destination then
            return nil, "The item is already in this folder"
        end
        if fs.isDir(source) and pathInside(destination, source) then
            return nil, "A folder cannot be pasted into itself"
        end
    end
    return destination
end

function api.public.init()
    event.on("user.logout", function()
        local clipboard = service.getService("clipboard")
        if getPayload() and clipboard then clipboard.clear() end
    end)
    log.info("FILEOPS", "Service initialized")
end

function api.public.copy(paths)
    return putPayload("copy", paths)
end

function api.public.cut(paths)
    return putPayload("cut", paths)
end

function api.public.canPaste(destination)
    local payload = getPayload()
    if not payload then return false end
    if destination == nil then return true end
    return validatePaste(payload, destination) ~= nil
end

function api.public.getClipboardInfo()
    return clonePayload(getPayload())
end

function api.public.clear()
    local clipboard = service.getService("clipboard")
    if not getPayload() or not clipboard then return false end
    clipboard.clear()
    event.dispatch("fileops.selection_changed", nil)
    return true
end

local function executeTransfer(payload, destination, options)
    options = options or {}
    local target_directory, err = validatePaste(payload, destination)
    if not target_directory then
        event.dispatch("fileops.failed", payload.operation, err)
        return false, err
    end

    local filesystem = service.getService("filesystem")
    if not filesystem then return false, "Filesystem service unavailable" end

    local destinations = {}
    for _, source in ipairs(payload.paths) do
        local target = uniqueDestination(target_directory, source, payload.operation)
        local ok, operation_error
        if payload.operation == "copy" then
            ok, operation_error = filesystem.copy(source, target)
        else
            ok, operation_error = filesystem.move(source, target)
        end
        if not ok then
            local message = operation_error or ("Could not " .. payload.operation .. " " .. source)
            event.dispatch("fileops.failed", payload.operation, message, source)
            return false, message
        end
        destinations[#destinations + 1] = target
    end

    if options.clear_clipboard and payload.operation == "cut" then
        local clipboard = service.getService("clipboard")
        if clipboard then clipboard.clear() end
        event.dispatch("fileops.selection_changed", nil)
    end

    local result = {
        operation=options.result_operation or payload.operation,
        sources=clonePayload(payload).paths,
        destinations=destinations,
        count=#destinations,
    }
    event.dispatch("fileops.completed", result)
    log.info("FILEOPS", "File operation completed", {
        operation=result.operation, count=result.count,
    })
    return true, result
end

function api.public.paste(destination)
    local payload = getPayload()
    if not payload then return false, "No files to paste" end
    return executeTransfer(payload, destination, {
        clear_clipboard=true,
        result_operation=payload.operation,
    })
end

-- Performs a file transfer without changing or depending on the clipboard.
-- This is used by Drag & Drop and is also available to future OS apps.
function api.public.transfer(paths, destination, operation)
    operation = operation or "move"
    if operation ~= "move" and operation ~= "copy" then
        return false, "Invalid transfer operation: " .. tostring(operation)
    end

    local normalized, err = normalizePaths(paths)
    if not normalized then return false, err end
    local payload = {
        type=PAYLOAD_TYPE,
        version=PAYLOAD_VERSION,
        operation=operation == "move" and "cut" or "copy",
        paths=normalized,
    }
    return executeTransfer(payload, destination, {
        clear_clipboard=false,
        result_operation=operation,
    })
end

return api
