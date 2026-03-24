-- BasaltShell Service
-- Command line interface for BasaltOS

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")

local api = api_factory.new()

-- Built-in commands (only core commands)
local builtins = {}
local command_history = {}
local aliases = {}
local current_directory = "/"

function api.public.init()
    api.private.registerCoreCommands()

    event.dispatch("basaltshell.ready")

    log.info("BASALTSHELL", "Service initialized")
end

-- Execute a command line
-- @param command_line string The full command line to execute
-- @param env table Optional environment table
-- @return boolean success, string|nil output or error message
function api.public.execute(command_line, env)
    if not command_line or command_line:match("^%s*$") then
        return true, nil
    end
    
    -- Add to history
    table.insert(command_history, command_line)
    
    -- Parse command line
    local parts = api.private.parseCommandLine(command_line)
    if #parts == 0 then
        return true, nil
    end
    
    local cmd = parts[1]
    local args = {table.unpack(parts, 2)}
    
    -- Check for alias
    if aliases[cmd] then
        cmd = aliases[cmd]
    end
    
    -- Check for builtin command
    if builtins[cmd] then
        return builtins[cmd](args, env)
    end
    
    -- Check for app in registry
    local app_service = service.getService("app")
    if app_service then
        local app = app_service.getApp(cmd)
        if app then
            return api.private.launchApp(app, args, env)
        end
    end
    
    -- Try to execute as Lua file
    local file_path = api.private.resolveCommand(cmd)
    if file_path and fs.exists(file_path) then
        return api.private.executeFile(file_path, args, env)
    end
    
    return false, "Command not found: " .. cmd
end

-- Parse command line into parts (respecting quotes)
function api.private.parseCommandLine(line)
    local parts = {}
    local current = ""
    local in_quote = false
    local quote_char = nil
    
    for i = 1, #line do
        local char = line:sub(i, i)
        
        if char == '"' or char == "'" then
            if not in_quote then
                in_quote = true
                quote_char = char
            elseif char == quote_char then
                in_quote = false
                quote_char = nil
            else
                current = current .. char
            end
        elseif char:match("%s") and not in_quote then
            if #current > 0 then
                table.insert(parts, current)
                current = ""
            end
        else
            current = current .. char
        end
    end
    
    if #current > 0 then
        table.insert(parts, current)
    end
    
    return parts
end

-- Resolve command to file path
function api.private.resolveCommand(cmd)
    -- Check if absolute path
    if cmd:sub(1, 1) == "/" then
        return cmd
    end
    
    -- Check in current directory
    local local_path = fs.combine(current_directory, cmd)
    if fs.exists(local_path) then
        return local_path
    end
    
    -- Check common locations
    local search_paths = {
        "system/bin",
        "system/apps",
        "bin",
        "usr/bin"
    }
    
    for _, path in ipairs(search_paths) do
        local full_path = fs.combine(path, cmd)
        if fs.exists(full_path) then
            return full_path
        end
        
        -- Try with .lua extension
        if fs.exists(full_path .. ".lua") then
            return full_path .. ".lua"
        end
    end
    
    return nil
end

-- Launch an app from registry
function api.private.launchApp(app, args, env)
    local process_service = service.getService("process")
    if not process_service then
        return false, "Process service not available"
    end
    
    local pid = process_service.startProgram(app.id, app.executable, args)
    if pid then
        return true, "Launched " .. app.name .. " (PID: " .. pid .. ")"
    else
        return false, "Failed to launch " .. app.name
    end
end

-- Execute a Lua file
function api.private.executeFile(file_path, args, env)
    env = env or {}
    setmetatable(env, {__index = _G})
    
    local fn, err = loadfile(file_path, "t", env)
    if not fn then
        return false, "Failed to load: " .. err
    end
    
    local success, result = pcall(fn, table.unpack(args))
    if success then
        return true, result
    else
        return false, result
    end
end

-- Get command history
function api.public.getHistory()
    return command_history
end

-- Clear command history
function api.public.clearHistory()
    command_history = {}
end

-- Set current directory
function api.public.setDirectory(path)
    if fs.exists(path) and fs.isDir(path) then
        current_directory = path
        return true
    end
    return false
end

-- Get current directory
function api.public.getDirectory()
    return current_directory
end

-- Set alias
function api.public.setAlias(name, command)
    aliases[name] = command
end

-- Get alias
function api.public.getAlias(name)
    return aliases[name]
end

-- Remove alias
function api.public.removeAlias(name)
    aliases[name] = nil
end

-- Register a builtin command
function api.public.registerBuiltin(name, handler)
    builtins[name] = handler
    log.debug("BASALTSHELL", "Registered command: " .. name)
end

-- Unregister a builtin command
function api.public.unregisterBuiltin(name)
    builtins[name] = nil
end

-- Get list of registered commands
function api.public.getCommands()
    local commands = {}
    for name in pairs(builtins) do
        table.insert(commands, name)
    end
    table.sort(commands)
    return commands
end

-- Register core built-in commands
function api.private.registerCoreCommands()
    -- File system commands
    builtins.cd = function(args)
        if #args == 0 then
            current_directory = "/"
            return true, "/"
        end
        
        local path = args[1]
        if path:sub(1, 1) ~= "/" then
            path = fs.combine(current_directory, path)
        end
        
        if fs.exists(path) and fs.isDir(path) then
            current_directory = path
            return true, path
        else
            return false, "Directory not found: " .. path
        end
    end

    builtins.pwd = function(args)
        return true, current_directory
    end

    builtins.ls = function(args)
        local path = args[1] or current_directory
        if path:sub(1, 1) ~= "/" then
            path = fs.combine(current_directory, path)
        end
        
        if not fs.exists(path) then
            return false, "Path not found: " .. path
        end
        
        if fs.isDir(path) then
            local items = fs.list(path)
            table.sort(items)
            return true, table.concat(items, "\n")
        else
            return true, path
        end
    end

    -- Terminal commands
    builtins.clear = function(args)
        return true, "\x1b[2J\x1b[H" -- ANSI clear screen
    end

    builtins.exit = function(args)
        return true, "EXIT"
    end

    -- Process management
    builtins.kill = function(args)
        if #args == 0 then
            return false, "Usage: kill <pid>"
        end

        local pid = tonumber(args[1])
        if not pid then
            return false, "Invalid PID: " .. args[1]
        end

        local process_service = service.getService("process")
        if not process_service then
            return false, "Process service not available"
        end

        if process_service.terminateProcess(pid) then
            return true, "Process " .. pid .. " terminated"
        else
            return false, "Failed to terminate process " .. pid
        end
    end

    -- History and alias commands
    builtins.history = function(args)
        if #command_history == 0 then
            return true, "No command history"
        end
        
        local lines = {}
        for i, cmd in ipairs(command_history) do
            table.insert(lines, string.format("%3d  %s", i, cmd))
        end

        return true, table.concat(lines, "\n")
    end

    builtins.alias = function(args)
        if #args == 0 then
            if next(aliases) == nil then
                return true, "No aliases defined"
            end

            local lines = {}
            for name, cmd in pairs(aliases) do
                table.insert(lines, string.format("%s='%s'", name, cmd))
            end
            return true, table.concat(lines, "\n")
        elseif #args == 1 then
            local name = args[1]
            if aliases[name] then
                return true, string.format("%s='%s'", name, aliases[name])
            else
                return false, "Alias not found: " .. name
            end
        else
            -- Set alias
            local name = args[1]
            local cmd = table.concat(args, " ", 2)
            aliases[name] = cmd
            return true, string.format("Alias set: %s='%s'", name, cmd)
        end
    end

    -- Help command
    builtins.help = function(args)
        local help_text = {
            "BasaltShell Commands:",
            "",
            "File System:",
            "  cd <path>     - Change directory",
            "  pwd           - Print working directory",
            "  ls [path]     - List directory contents",
            "",
            "Terminal:",
            "  clear         - Clear screen",
            "  exit          - Exit terminal",
            "  help          - Show this help",
            "",
            "Process:",
            "  ps            - List processes",
            "  kill <pid>    - Kill process",
            "",
            "Utilities:",
            "  history       - Show command history",
            "  alias         - Manage aliases",
            "  notify <msg>  - Show notification",
            "  alert <msg>   - Show alert dialog",
            "",
            "Run apps by name: settings, worm, etc."
        }
        return true, table.concat(help_text, "\n")
    end
end

return api
