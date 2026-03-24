-- /core/path.lua
-- Path Resolution: Handle path variables and absolute/relative paths

local path = {}

-- Path variables registry
local variables = {
    ["ROOT"] = "",  -- Root directory (empty for absolute paths)
    ["SYSTEM"] = "system",
    ["APPS"] = "apps",
    ["SYSTEM_APPS"] = "system/apps",
    ["USERS"] = "users",
    ["ROM"] = "rom",
    ["TEMP"] = "temp",
    ["LOGS"] = "system/logs",
}

-- Current context (set by services)
local current_user = nil
local current_program_path = nil

-- Set current user (called by auth service)
function path.setCurrentUser(username)
    current_user = username
    if username then
        variables["USER"] = fs.combine("users", username)
        variables["USER_HOME"] = fs.combine("users", username)
        variables["USER_APPS"] = fs.combine("users", username, "apps")
        variables["USER_DESKTOP"] = fs.combine("users", username, "desktop")
        variables["USER_DOCUMENTS"] = fs.combine("users", username, "documents")
        variables["USER_CONFIG"] = fs.combine("users", username, "config")
    else
        variables["USER"] = nil
        variables["USER_HOME"] = nil
        variables["USER_APPS"] = nil
        variables["USER_DESKTOP"] = nil
        variables["USER_DOCUMENTS"] = nil
        variables["USER_CONFIG"] = nil
    end
end

-- Set current program path (called by process/wm when executing)
function path.setCurrentProgramPath(program_path)
    current_program_path = program_path
    if program_path then
        variables["PROGRAMPATH"] = program_path
        variables["APPPATH"] = program_path  -- Alias
    else
        variables["PROGRAMPATH"] = nil
        variables["APPPATH"] = nil
    end
end

-- Register a custom path variable
function path.registerVariable(name, value)
    variables[name] = value
end

-- Get a path variable value
function path.getVariable(name)
    return variables[name]
end

-- Resolve path variables in a path string
-- Supports: %%VAR%%, ${VAR}, $VAR
function path.resolveVariables(input_path)
    if not input_path or input_path == "" then
        return input_path
    end
    
    local resolved = input_path
    
    -- Replace %%VAR%% style
    resolved = resolved:gsub("%%%%([%w_]+)%%%%", function(var_name)
        local value = variables[var_name]
        if value == nil then
            error("Undefined path variable: " .. var_name)
        end
        return value
    end)
    
    -- Replace ${VAR} style
    resolved = resolved:gsub("%${([%w_]+)}", function(var_name)
        local value = variables[var_name]
        if value == nil then
            error("Undefined path variable: " .. var_name)
        end
        return value
    end)
    
    -- Replace $VAR style (must be at start or after /)
    resolved = resolved:gsub("(^|/)%$([%w_]+)", function(prefix, var_name)
        local value = variables[var_name]
        if value == nil then
            error("Undefined path variable: " .. var_name)
        end
        return prefix .. value
    end)
    
    return resolved
end

-- Check if path is absolute (starts with /)
function path.isAbsolute(input_path)
    return input_path and input_path:sub(1, 1) == "/"
end

-- Normalize path: resolve . and .. segments
function path.normalize(input_path)
    if not input_path or input_path == "" then
        return ""
    end
    
    local is_absolute = path.isAbsolute(input_path)
    local parts = {}
    
    -- Split by /
    for part in input_path:gmatch("[^/]+") do
        if part == ".." then
            -- Go up one level
            if #parts > 0 then
                table.remove(parts)
            end
        elseif part ~= "." and part ~= "" then
            -- Add normal segment
            table.insert(parts, part)
        end
    end
    
    local result = table.concat(parts, "/")
    
    -- Add leading / back if was absolute
    if is_absolute and not result:match("^/") then
        result = "/" .. result
    end
    
    return result
end

-- Resolve a path: handle variables, absolute/relative, and normalization
-- This is the main function to use
function path.resolve(input_path, base_path)
    if not input_path or input_path == "" then
        return ""
    end
    
    -- Step 1: Resolve variables
    local resolved = path.resolveVariables(input_path)
    
    -- Step 2: Handle absolute vs relative
    if path.isAbsolute(resolved) then
        -- Remove leading / for CC:Tweaked (which doesn't use leading /)
        resolved = resolved:sub(2)
    elseif base_path then
        -- Relative path: combine with base
        resolved = fs.combine(base_path, resolved)
    end
    
    -- Step 3: Normalize (resolve . and ..)
    resolved = path.normalize(resolved)
    
    return resolved
end

-- Join path segments
function path.join(...)
    local segments = {...}
    local result = ""
    
    for i, segment in ipairs(segments) do
        if segment and segment ~= "" then
            if result == "" then
                result = segment
            else
                result = fs.combine(result, segment)
            end
        end
    end
    
    return result
end

-- Get directory name (parent path)
function path.dirname(input_path)
    if not input_path or input_path == "" then
        return ""
    end
    
    return fs.getDir(input_path)
end

-- Get file name (last segment)
function path.basename(input_path, extension)
    if not input_path or input_path == "" then
        return ""
    end
    
    local name = fs.getName(input_path)
    
    -- Remove extension if provided
    if extension and name:sub(-#extension) == extension then
        name = name:sub(1, -#extension - 1)
    end
    
    return name
end

-- Get file extension
function path.extname(input_path)
    if not input_path or input_path == "" then
        return ""
    end
    
    local name = fs.getName(input_path)
    local ext = name:match("%.([^%.]+)$")
    
    return ext and ("." .. ext) or ""
end

-- Convert to absolute path (with leading /)
function path.toAbsolute(input_path)
    if path.isAbsolute(input_path) then
        return input_path
    end
    
    return "/" .. input_path
end

-- Examples of usage:
--[[
    path.resolve("/rom/programs/fun/worm.lua")
    -- Returns: "rom/programs/fun/worm.lua"
    
    path.resolve("%%PROGRAMPATH%%/main.lua")
    -- Returns: "system/apps/myapp/main.lua" (if PROGRAMPATH is set)
    
    path.resolve("%%USER%%/documents/file.txt")
    -- Returns: "users/admin/documents/file.txt" (if user is admin)
    
    path.resolve("data/config.json", "system/apps/myapp")
    -- Returns: "system/apps/myapp/data/config.json"
    
    path.join("system", "apps", "worm")
    -- Returns: "system/apps/worm"
    
    path.dirname("system/apps/worm/app.json")
    -- Returns: "system/apps/worm"
    
    path.basename("system/apps/worm/app.json")
    -- Returns: "app.json"
    
    path.extname("app.json")
    -- Returns: ".json"
]]

return path
