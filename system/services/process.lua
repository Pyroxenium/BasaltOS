-- /services/process.lua
-- Process Manager: Manages running applications and background processes

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")

local api = api_factory.new()

local processes = {}
local next_pid = 1

-- Process states
local STATE = {
    RUNNING = "running",
    PAUSED = "paused",
    TERMINATED = "terminated"
}

-- Process types
local TYPE = {
    WINDOWED = "windowed",      -- Has a window (managed by WM)
    BACKGROUND = "background"    -- No window (daemon/service)
}

function api.public.init()
    event.on("user.logout", function()
        api.private.terminateAllProcesses()
    end)

    event.on("wm.window_closed", function(window_id, pid)
        -- Clean up the process when its window is closed (e.g. user clicked X)
        local process = processes[pid]
        if process and process.state ~= STATE.TERMINATED then
            process.state = STATE.TERMINATED
            event.dispatch("process.terminated", pid)
            processes[pid] = nil
        end
    end)

    event.on("basaltshell.ready", function()
        local shell = service.getService("basaltshell")
        if shell then
            shell.registerBuiltin("ps", function(args)
                local processes = api.public.listProcesses()
                local lines = {"PID  | Program"}
                table.insert(lines, "-----|---------")

                for pid, proc in pairs(processes) do
                    table.insert(lines, string.format("%-4d | %s", pid, proc.program_id))
                end

                return true, table.concat(lines, "\n")
            end)
        end
    end)
end

-- Public API: Start a program
-- @param program_id: ID from registry
-- @param args: Arguments to pass to program (if non-empty, skips arg collection UI)
-- @param process_type: "windowed" or "background"
-- @return pid or nil (nil when arg collection UI is shown – launch happens async via callback)
function api.public.startProgram(program_id, args, process_type)
    log.debug("PROCESS", "startProgram called", {program_id = program_id, args = args, type = process_type})

    local registry = service.getService("registry")
    local program = registry.getProgram(program_id)

    if not program then
        log.error("PROCESS", "Program not found: " .. program_id)
        return nil, "Program not found: " .. program_id
    end

    log.debug("PROCESS", "Program found", program)

    if not fs.exists(program.executable) then
        log.error("PROCESS", "Executable not found: " .. program.executable)
        return nil, "Executable not found: " .. program.executable
    end

    process_type = process_type or TYPE.WINDOWED

    -- If program defines args and no args were provided, collect them via UI first
    local arg_collector = service.getService("arg_collector")
    if arg_collector and program.args and #program.args > 0 then
        arg_collector.collect(program, args or {}, function(full_args)
            if full_args == nil then
                log.info("PROCESS", "Arg collection cancelled by user", {program_id = program_id})
                return
            end
            api.private.doLaunch(program, program_id, full_args, process_type)
        end)
        return nil
    end

    return api.private.doLaunch(program, program_id, args or {}, process_type)
end

function api.private.doLaunch(program, program_id, args, process_type)
    local pid = next_pid
    next_pid = next_pid + 1

    local process = {
        pid = pid,
        program_id = program_id,
        program_name = program.name,
        executable = program.executable,
        args = args,
        type = process_type,
        state = STATE.RUNNING,
        window_id = nil,
        started_at = os.epoch("utc"),
        coroutine = nil
    }

    processes[pid] = process

    log.info("PROCESS", "Process created", {pid = pid, program = program_id, type = process_type})

    event.dispatch("process.started", pid, program_id, process_type)

    if process_type == TYPE.WINDOWED then
        log.debug("PROCESS", "Creating window for PID " .. pid)
        local wm = service.getService("wm")
        if wm then
            local window_id, err = wm.createWindow(pid, program, process.executable, process.args)
            if window_id then
                process.window_id = window_id
                log.info("PROCESS", "Window created", {pid = pid, window_id = window_id})
            else
                log.error("PROCESS", "Failed to create window", {pid = pid, error = err})
            end
        else
            log.error("PROCESS", "WM service not available")
        end
    else
        log.debug("PROCESS", "Starting background process PID " .. pid)
        api.private.startBackgroundProcess(pid)
    end

    return pid
end

function api.private.startBackgroundProcess(pid)
    local process = processes[pid]
    if not process then return end

    local ok, program_func = pcall(loadfile, process.executable)
    if not ok then
        process.state = STATE.TERMINATED
        return
    end

    process.coroutine = coroutine.create(program_func)

    local success, err = coroutine.resume(process.coroutine, table.unpack(process.args))
    if not success then
        print("[PROCESS] Background process " .. pid .. " error: " .. tostring(err))
        process.state = STATE.TERMINATED
    end
end

function api.public.terminateProcess(pid)
    local process = processes[pid]

    if not process then
        return false, "Process not found"
    end

    if process.state == STATE.TERMINATED then
        return false, "Process already terminated"
    end

    process.state = STATE.TERMINATED

    if process.window_id then
        local wm = service.getService("wm")
        if wm then
            wm.closeWindow(process.window_id)
        end
    end

    event.dispatch("process.terminated", pid)

    processes[pid] = nil

    return true
end

function api.private.terminateAllProcesses()
    local pids = {}
    for pid, _ in pairs(processes) do
        table.insert(pids, pid)
    end

    for _, pid in ipairs(pids) do
        api.public.terminateProcess(pid)
    end
end

function api.public.getProcess(pid)
    return processes[pid]
end

function api.public.findProcessByProgram(program_id)
    for pid, process in pairs(processes) do
        if process.program_id == program_id and process.state == STATE.RUNNING then
            return process
        end
    end
    return nil
end

function api.public.listProcesses(filter_type)
    local list = {}

    for pid, process in pairs(processes) do
        if not filter_type or process.type == filter_type then
            table.insert(list, process)
        end
    end

    return list
end

function api.public.getWindowedProcesses()
    return api.public.listProcesses(TYPE.WINDOWED)
end

function api.public.getBackgroundProcesses()
    return api.public.listProcesses(TYPE.BACKGROUND)
end

function api.public.pauseProcess(pid)
    local process = processes[pid]

    if not process then
        return false, "Process not found"
    end

    process.state = STATE.PAUSED
    event.dispatch("process.paused", pid)

    return true
end

function api.public.resumeProcess(pid)
    local process = processes[pid]

    if not process then
        return false, "Process not found"
    end

    process.state = STATE.RUNNING
    event.dispatch("process.resumed", pid)

    return true
end

function api.public.getProcessCount()
    local count = 0
    for _ in pairs(processes) do
        count = count + 1
    end
    return count
end

return api
