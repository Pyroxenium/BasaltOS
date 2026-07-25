-- Per-user PineStore project locations and installation receipts.

local projects = {}

local function projectKey(project)
    local value = tostring(type(project) == "table" and project.id or project or "")
    value = value:lower():gsub("[^%w._-]", "-"):gsub("%-+", "-")
    value = value:match("^%-*(.-)%-*$") or ""
    if value == "" then return nil, "Project has no stable ID" end
    return value
end

local function safeRelative(path)
    path = tostring(path or ""):gsub("\\", "/")
    if path == "" then return nil, "Project declares no target file" end
    if path:sub(1, 1) == "/" then return nil, "Target file is absolute" end
    for part in path:gmatch("[^/]+") do
        if part == ".." then return nil, "Target file leaves the project folder" end
    end
    return path
end

local function ensureDirectory(path)
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
    local parent = fs.getDir(path)
    if parent ~= "" and not ensureDirectory(parent) then
        return false, "Could not create receipt folder"
    end
    local ok, body = pcall(textutils.serializeJSON, value)
    if not ok then return false, tostring(body) end
    local handle = fs.open(path, "w")
    if not handle then return false, "Could not write installation receipt" end
    handle.write(body)
    handle.close()
    return true
end

local function listFiles(root)
    local result = {}
    local function visit(path, relative)
        for _, name in ipairs(fs.list(path)) do
            local child = fs.combine(path, name)
            local child_relative = relative == "" and name
                or fs.combine(relative, name)
            if fs.isDir(child) then
                visit(child, child_relative)
            else
                result[#result + 1] = child_relative:gsub("\\", "/")
            end
        end
    end
    if fs.exists(root) and fs.isDir(root) then visit(root, "") end
    table.sort(result)
    return result
end

function projects.paths(userfs, project)
    if not userfs or not userfs.getPath then
        return nil, "User filesystem is unavailable"
    end
    local key, key_error = projectKey(project)
    if not key then return nil, key_error end
    local programs_root, programs_error = userfs.getPath("programs/pinestore")
    if not programs_root then return nil, programs_error or "No user logged in" end
    local receipts_root, receipts_error = userfs.getPath("config/pinestore")
    if not receipts_root then return nil, receipts_error or "No user logged in" end
    return {
        key=key,
        root=fs.combine(programs_root, key),
        receipt=fs.combine(receipts_root, key .. ".json"),
        app_id="pinestore." .. key,
    }
end

function projects.prepare(userfs, project, mode)
    local paths, paths_error = projects.paths(userfs, project)
    if not paths then return nil, paths_error end
    mode = mode == "legacy" and "legacy" or "managed"
    if mode == "managed" and not ensureDirectory(paths.root) then
        return nil, "Could not create the project folder"
    end
    return paths
end

function projects.resolveTarget(project, paths, mode)
    local target = tostring(project and project.target_file or "")
    if target == "" then return nil, "Project declares no target file" end
    if mode == "legacy" then
        return fs.combine("", target)
    end
    local relative, relative_error = safeRelative(target)
    if not relative then return nil, relative_error end
    return fs.combine(paths.root, relative)
end

function projects.load(userfs, project)
    local paths = projects.paths(userfs, project)
    if not paths then return nil end
    return readJson(paths.receipt)
end

function projects.isInstalled(userfs, project)
    return projects.load(userfs, project) ~= nil
end

function projects.record(userfs, project, mode)
    local paths, paths_error = projects.prepare(userfs, project, mode)
    if not paths then return nil, paths_error end
    mode = mode == "legacy" and "legacy" or "managed"
    local target_path, target_error = projects.resolveTarget(project, paths, mode)
    local receipt = {
        format_version=1,
        project_id=project.id,
        name=project.name,
        author=project.author,
        category=project.category,
        install_command=project.install_command,
        install_mode=mode,
        install_root=mode == "managed" and paths.root or "/",
        target_file=project.target_file,
        target_path=target_path,
        target_error=target_error,
        target_exists=target_path ~= nil and fs.exists(target_path)
            and not fs.isDir(target_path),
        files=mode == "managed" and listFiles(paths.root) or {},
        app_id=paths.app_id,
        installed_at=os.epoch and os.epoch("utc") or 0,
    }
    local written, write_error = writeJson(paths.receipt, receipt)
    if not written then return nil, write_error end
    return receipt
end

function projects.remove(userfs, project)
    local paths, paths_error = projects.paths(userfs, project)
    if not paths then return false, paths_error end
    local receipt = readJson(paths.receipt)
    if not receipt then return false, "Project is not installed" end

    if receipt.install_mode == "managed"
        and receipt.install_root == paths.root
        and fs.exists(paths.root) then
        fs.delete(paths.root)
    end
    if fs.exists(paths.receipt) then fs.delete(paths.receipt) end
    return true, receipt.install_mode == "legacy"
end

return projects
