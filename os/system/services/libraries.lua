-- User library registry: maps require() module names to installed Lua files.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")

local api = api_factory.new()
local RESERVED_MODULES = {app=true, basalt=true}

local function validProjectId(project_id)
    project_id = tostring(project_id or "")
    return project_id ~= "" and project_id:match("^[%w][%w._-]*$") ~= nil
end

local function validModuleName(module_name)
    module_name = tostring(module_name or "")
    if module_name == "" or RESERVED_MODULES[module_name] then return false end
    if module_name:sub(1, 1) == "." or module_name:sub(-1) == "." then
        return false
    end
    for part in module_name:gmatch("[^%.]+") do
        if part:match("^[%a_][%w_]*$") == nil then return false end
    end
    return not module_name:find("..", 1, true)
end

local function recordsDirectory()
    local userfs = service.getService("userfs")
    return userfs and userfs.getPath
        and userfs.getPath("config/libraries") or nil
end

local function recordPath(project_id)
    local directory = recordsDirectory()
    if not directory then return nil end
    return fs.combine(directory, tostring(project_id) .. ".json")
end

local function ensureDirectory(path)
    if not path then return false end
    if not fs.exists(path) then fs.makeDir(path) end
    return fs.exists(path) and fs.isDir(path)
end

local function readJson(path)
    if not path or not fs.exists(path) or fs.isDir(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local body = handle.readAll()
    handle.close()
    local ok, value = pcall(textutils.unserializeJSON, body)
    return ok and type(value) == "table" and value or nil
end

local function writeJson(path, value)
    if not path or not ensureDirectory(fs.getDir(path)) then
        return false, "Could not create library registry folder"
    end
    local ok, body = pcall(textutils.serializeJSON, value)
    if not ok then return false, tostring(body) end
    local handle = fs.open(path, "w")
    if not handle then return false, "Could not write library registration" end
    handle.write(body)
    handle.close()
    return true
end

local function normalizeRecord(record, fallback_id)
    if type(record) ~= "table" then return nil end
    local project_id = tostring(record.project_id or fallback_id or "")
    local module_name = tostring(record.module_name or "")
    local entry_path = fs.combine("", tostring(record.entry_path or ""))
    if not validProjectId(project_id) or not validModuleName(module_name)
        or entry_path == "" or not fs.exists(entry_path) or fs.isDir(entry_path) then
        return nil
    end
    record.project_id = project_id
    record.module_name = module_name
    record.entry_path = entry_path
    record.root_path = fs.combine("", tostring(
        record.root_path or fs.getDir(entry_path)))
    return record
end

function api.public.init()
    event.on("user.login", function()
        ensureDirectory(recordsDirectory())
    end)
end

function api.public.list()
    local directory = recordsDirectory()
    if not directory or not fs.exists(directory) or not fs.isDir(directory) then
        return {}
    end
    local result = {}
    for _, filename in ipairs(fs.list(directory)) do
        local project_id = filename:match("^(.-)%.json$")
        if project_id then
            local record = normalizeRecord(
                readJson(fs.combine(directory, filename)), project_id)
            if record then result[#result + 1] = record end
        end
    end
    table.sort(result, function(left, right)
        return left.module_name:lower() < right.module_name:lower()
    end)
    return result
end

function api.public.get(project_id)
    if not validProjectId(project_id) then return nil end
    return normalizeRecord(readJson(recordPath(project_id)), project_id)
end

function api.public.isRegistered(project_id)
    return api.public.get(project_id) ~= nil
end

function api.public.register(project_id, module_name, entry_path, metadata)
    project_id = tostring(project_id or "")
    module_name = tostring(module_name or "")
    entry_path = fs.combine("", tostring(entry_path or ""))
    if not validProjectId(project_id) then return false, "Invalid project ID" end
    if not validModuleName(module_name) then
        return false, "Use a Lua module name such as example or example.tools"
    end
    if entry_path == "" or not fs.exists(entry_path) or fs.isDir(entry_path) then
        return false, "Library entry file not found"
    end
    if entry_path:lower():sub(-4) ~= ".lua" then
        return false, "Library entry must be a Lua file"
    end
    for _, existing in ipairs(api.public.list()) do
        if existing.module_name == module_name
            and existing.project_id ~= project_id then
            return false, "Another library already uses this module name"
        end
    end

    metadata = type(metadata) == "table" and metadata or {}
    local record = {
        format_version=1,
        project_id=project_id,
        module_name=module_name,
        entry_path=entry_path,
        root_path=fs.getDir(entry_path),
        name=metadata.name,
        author=metadata.author,
        source=metadata.source,
        registered_at=os.epoch and os.epoch("utc") or 0,
    }
    local written, write_error = writeJson(recordPath(project_id), record)
    if not written then return false, write_error end
    event.dispatch("libraries.changed", project_id, module_name, true)
    return true
end

function api.public.unregister(project_id)
    project_id = tostring(project_id or "")
    if not validProjectId(project_id) then return false, "Invalid project ID" end
    local path = recordPath(project_id)
    local record = readJson(path)
    if not record then return false, "Library is not registered" end
    fs.delete(path)
    event.dispatch("libraries.changed", project_id, record.module_name, false)
    return true
end

return api
