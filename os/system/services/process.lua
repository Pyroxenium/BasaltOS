-- /services/process.lua
-- Process Manager: lifecycle, scheduling and statistics for applications.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")

local api = api_factory.new()

local processes = {}
local history = {}
local next_pid = 1
local HISTORY_LIMIT = 50

local STATE = {
    RUNNING = "running",
    PAUSED = "paused",
    TERMINATED = "terminated",
}

local TYPE = {
    WINDOWED = "windowed",
    BACKGROUND = "background",
}

local totals = {
    started = 0,
    exited = 0,
    crashed = 0,
}

local function nowMs()
    if os.epoch then return os.epoch("utc") end
    return math.floor((os.clock and os.clock() or 0) * 1000)
end

local service_started_at = nowMs()

local function copyArray(source)
    local result = {}
    for index, value in ipairs(source or {}) do result[index] = value end
    return result
end

local function snapshot(process, at)
    if not process then return nil end
    at = at or nowMs()
    local ended_at = process.ended_at
    return {
        pid = process.pid,
        program_id = process.program_id,
        program_name = process.program_name,
        executable = process.executable,
        args = copyArray(process.args),
        type = process.type,
        state = process.state,
        window_id = process.window_id,
        started_at = process.started_at,
        updated_at = process.updated_at,
        ended_at = ended_at,
        runtime_ms = math.max(0, (ended_at or at) - process.started_at),
        exit_reason = process.exit_reason,
        exit_error = process.exit_error,
        filter = process.filter,
        resume_count = process.resume_count or 0,
        event_count = process.event_count or 0,
        last_event = process.last_event,
        cpu_time_ms = process.cpu_time_ms
            or math.floor((process.cpu_time or 0) * 1000 + 0.5),
    }
end

local function addHistory(entry)
    table.insert(history, 1, entry)
    while #history > HISTORY_LIMIT do table.remove(history) end
end

local function isTerminationError(result)
    local message = tostring(result or "")
    return message == "Terminated" or message:match(": Terminated$") ~= nil
end

-- Remove a process exactly once and publish a stable final snapshot.
local function finishProcess(process, reason, err, notify_window)
    if not process or processes[process.pid] ~= process then return false end

    local finished_at = nowMs()
    process.state = STATE.TERMINATED
    process.updated_at = finished_at
    process.ended_at = finished_at
    process.exit_reason = reason or "terminated"
    process.exit_error = err and tostring(err) or nil
    process.filter = nil
    process.in_resume = false

    local final = snapshot(process, finished_at)
    processes[process.pid] = nil
    addHistory(final)

    totals.exited = totals.exited + 1
    if final.exit_reason == "crashed" or final.exit_reason == "launch_error" then
        totals.crashed = totals.crashed + 1
    end

    event.dispatch("process.exited", process.pid, final.exit_reason, final)
    if notify_window ~= false then
        -- Kept for existing WM/service consumers.
        event.dispatch("process.terminated", process.pid, final.exit_reason, final)
    end
    return true
end

local function accountResume(process, started_clock)
    process.resume_count = process.resume_count + 1
    if os.clock then
        process.cpu_time = process.cpu_time + math.max(0, os.clock() - started_clock)
    end
    process.updated_at = nowMs()
end

local function resumeBackground(process, ...)
    if not process or processes[process.pid] ~= process or not process.coroutine then
        return false, "Process not available"
    end
    if process.in_resume or coroutine.status(process.coroutine) ~= "suspended" then
        return false, "Process is not suspended"
    end

    process.in_resume = true
    local started_clock = os.clock and os.clock() or 0
    local result = table.pack(coroutine.resume(process.coroutine, ...))
    process.in_resume = false
    accountResume(process, started_clock)

    if not result[1] then
        local err = result[2]
        log.error("PROCESS", "Background process crashed", {
            pid=process.pid, program=process.program_id, error=err,
        })
        finishProcess(process, "crashed", err)
        return false, err
    end

    process.filter = result[2]
    if coroutine.status(process.coroutine) == "dead" then
        finishProcess(process, "completed")
    end
    return true
end

function api.public.init()
    event.on("user.logout", function()
        api.private.terminateAllProcesses("logout")
    end)

    event.on("system.shutdown", function()
        api.private.terminateAllProcesses("shutdown")
    end)

    event.on("wm.window_closed", function(_, pid)
        -- Direct window closes (titlebar/taskbar) end their owning process.
        -- The window is already gone, so no process.terminated round-trip is needed.
        local process = processes[pid]
        if process then finishProcess(process, "closed", nil, false) end
    end)

    event.onRaw(api.private.handleRawEvent)

    event.on("basaltshell.ready", function()
        local shell_service = service.getService("basaltshell")
        if shell_service then
            shell_service.registerBuiltin("ps", function()
                local running = api.public.listProcesses()
                local lines = {"PID  | State   | Type       | Program"}
                table.insert(lines, "-----|---------|------------|--------")
                for _, process in ipairs(running) do
                    table.insert(lines, string.format(
                        "%-4d | %-7s | %-10s | %s",
                        process.pid, process.state, process.type, process.program_id
                    ))
                end
                return true, table.concat(lines, "\n")
            end)
        end
    end)
end

-- Start a registry program.
-- @return pid or nil (nil also means argument collection was opened)
function api.public.startProgram(program_id, args, process_type)
    log.debug("PROCESS", "startProgram called", {
        program_id=program_id, args=args, type=process_type,
    })

    local registry = service.getService("registry")
    if not registry then return nil, "Registry service not available" end
    local program = registry.getProgram(program_id)
    if not program then
        log.error("PROCESS", "Program not found: " .. tostring(program_id))
        return nil, "Program not found: " .. tostring(program_id)
    end
    if not fs.exists(program.executable) then
        log.error("PROCESS", "Executable not found: " .. tostring(program.executable))
        return nil, "Executable not found: " .. tostring(program.executable)
    end

    process_type = process_type or TYPE.WINDOWED
    if process_type ~= TYPE.WINDOWED and process_type ~= TYPE.BACKGROUND then
        return nil, "Invalid process type: " .. tostring(process_type)
    end

    -- Resolve singletons before allocating a PID. Doing this inside WM used to
    -- create a second process record and then attach it to the first window.
    if program.singleton then
        local existing = api.public.findProcessByProgram(program_id)
        if existing then
            if existing.window_id then
                local wm = service.getService("wm")
                if wm then wm.focusWindow(existing.window_id) end
            end
            return existing.pid
        end
    end

    local arg_collector = service.getService("arg_collector")
    if arg_collector and program.args and #program.args > 0
        and program.prompt_for_args ~= false
        and (not args or #args == 0) then
        arg_collector.collect(program, args or {}, function(full_args)
            if full_args == nil then
                log.info("PROCESS", "Arg collection cancelled", {program_id=program_id})
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
    local started_at = nowMs()
    local process = {
        pid = pid,
        program_id = program_id,
        program_name = program.name or program_id,
        executable = program.executable,
        args = copyArray(args),
        type = process_type,
        state = STATE.RUNNING,
        window_id = nil,
        started_at = started_at,
        updated_at = started_at,
        coroutine = nil,
        filter = nil,
        resume_count = 0,
        event_count = 0,
        last_event = nil,
        cpu_time = 0,
        in_resume = false,
    }

    processes[pid] = process
    totals.started = totals.started + 1
    log.info("PROCESS", "Process created", {
        pid=pid, program=program_id, type=process_type,
    })
    event.dispatch("process.started", pid, program_id, process_type, snapshot(process))

    if process_type == TYPE.WINDOWED then
        local wm = service.getService("wm")
        if not wm then
            finishProcess(process, "launch_error", "WM service not available")
            return nil, "WM service not available"
        end

        local window_id, err = wm.createWindow(
            pid, program, process.executable, process.args
        )
        if not window_id then
            finishProcess(process, "launch_error", err or "Failed to create window")
            return nil, err or "Failed to create window"
        end
        -- A program can finish synchronously during createWindow.
        if processes[pid] == process then
            process.window_id = window_id
            process.updated_at = nowMs()
        end
    else
        local ok, err = api.private.startBackgroundProcess(pid)
        if not ok then return nil, err end
    end

    return pid
end

function api.private.startBackgroundProcess(pid)
    local process = processes[pid]
    if not process then return false, "Process not found" end

    local program_func, load_error = loadfile(process.executable)
    if not program_func then
        log.error("PROCESS", "Could not load background process", {
            pid=pid, error=load_error,
        })
        finishProcess(process, "launch_error", load_error)
        return false, load_error
    end

    process.coroutine = coroutine.create(program_func)
    return resumeBackground(process, table.unpack(process.args))
end

-- Feed queued OS/internal events into background processes using the same
-- pullEvent filter convention as ComputerCraft.
function api.private.handleRawEvent(event_name, ...)
    local pids = {}
    for pid, process in pairs(processes) do
        if process.type == TYPE.BACKGROUND
            and process.state == STATE.RUNNING
            and not process.in_resume
            and process.coroutine
            and (process.filter == nil or process.filter == event_name
                or event_name == "terminate") then
            pids[#pids + 1] = pid
        end
    end
    table.sort(pids)

    for _, pid in ipairs(pids) do
        local process = processes[pid]
        if process and process.state == STATE.RUNNING then
            process.event_count = process.event_count + 1
            process.last_event = event_name
            resumeBackground(process, event_name, ...)
        end
    end
end

function api.public.terminateProcess(pid, reason)
    local process = processes[tonumber(pid) or pid]
    if not process then return false, "Process not found" end

    reason = reason or "terminated"
    if process.type == TYPE.BACKGROUND and process.coroutine
        and coroutine.status(process.coroutine) == "suspended"
        and not process.in_resume then
        process.in_resume = true
        local started_clock = os.clock and os.clock() or 0
        local ok, result = coroutine.resume(process.coroutine, "terminate")
        process.in_resume = false
        accountResume(process, started_clock)

        if not ok and not isTerminationError(result) then
            log.warn("PROCESS", "Background process errored while terminating", {
                pid=process.pid, error=result,
            })
        end
        if coroutine.close and coroutine.status(process.coroutine) ~= "dead" then
            pcall(coroutine.close, process.coroutine)
        end
    end

    finishProcess(process, reason)
    return true
end

function api.private.completeWindowProcess(pid, success, result)
    local process = processes[pid]
    if not process then return false, "Process not found" end
    if success == false then
        finishProcess(process, "crashed", result)
    else
        finishProcess(process, "completed")
    end
    return true
end

function api.private.terminateAllProcesses(reason)
    local pids = {}
    for pid in pairs(processes) do pids[#pids + 1] = pid end
    table.sort(pids)
    for _, pid in ipairs(pids) do
        api.public.terminateProcess(pid, reason or "terminated")
    end
end

function api.public.getProcess(pid)
    return snapshot(processes[tonumber(pid) or pid])
end

function api.public.findProcessByProgram(program_id)
    local found
    for _, process in pairs(processes) do
        if process.program_id == program_id
            and process.state ~= STATE.TERMINATED
            and (not found or process.pid < found.pid) then
            found = process
        end
    end
    return snapshot(found)
end

function api.public.listProcesses(filter_type)
    local list = {}
    local at = nowMs()
    for _, process in pairs(processes) do
        if not filter_type or process.type == filter_type then
            list[#list + 1] = snapshot(process, at)
        end
    end
    table.sort(list, function(left, right) return left.pid < right.pid end)
    return list
end

function api.public.getWindowedProcesses()
    return api.public.listProcesses(TYPE.WINDOWED)
end

function api.public.getBackgroundProcesses()
    return api.public.listProcesses(TYPE.BACKGROUND)
end

function api.public.getHistory(limit)
    limit = math.max(0, math.min(tonumber(limit) or HISTORY_LIMIT, HISTORY_LIMIT))
    local result = {}
    for index = 1, math.min(limit, #history) do
        result[index] = snapshot(history[index], history[index].ended_at)
    end
    return result
end

function api.public.pauseProcess(pid)
    local process = processes[tonumber(pid) or pid]
    if not process then return false, "Process not found" end
    if process.state == STATE.PAUSED then return true end
    if process.state ~= STATE.RUNNING then return false, "Process is not running" end

    if process.window_id then
        local wm = service.getService("wm")
        if not wm or not wm.setWindowProcessPaused then
            return false, "Window manager cannot pause programs"
        end
        local ok, err = wm.setWindowProcessPaused(process.window_id, true)
        if not ok then return false, err end
    end

    process.state = STATE.PAUSED
    process.updated_at = nowMs()
    event.dispatch("process.paused", process.pid, snapshot(process))
    return true
end

function api.public.resumeProcess(pid)
    local process = processes[tonumber(pid) or pid]
    if not process then return false, "Process not found" end
    if process.state == STATE.RUNNING then return true end
    if process.state ~= STATE.PAUSED then return false, "Process is not paused" end

    if process.window_id then
        local wm = service.getService("wm")
        if not wm or not wm.setWindowProcessPaused then
            return false, "Window manager cannot resume programs"
        end
        local ok, err = wm.setWindowProcessPaused(process.window_id, false)
        if not ok then return false, err end
    end

    process.state = STATE.RUNNING
    process.updated_at = nowMs()
    event.dispatch("process.resumed", process.pid, snapshot(process))
    return true
end

function api.public.getProcessCount()
    local count = 0
    for _ in pairs(processes) do count = count + 1 end
    return count
end

function api.public.getStats()
    local stats = {
        total = 0,
        running = 0,
        paused = 0,
        windowed = 0,
        background = 0,
        total_started = totals.started,
        total_exited = totals.exited,
        total_crashed = totals.crashed,
        history_count = #history,
        uptime_ms = math.max(0, nowMs() - service_started_at),
        cpu_time_ms = 0,
    }
    for _, process in pairs(processes) do
        stats.total = stats.total + 1
        stats[process.state] = (stats[process.state] or 0) + 1
        stats[process.type] = (stats[process.type] or 0) + 1
        stats.cpu_time_ms = stats.cpu_time_ms
            + math.floor((process.cpu_time or 0) * 1000 + 0.5)
    end
    return stats
end

function api.public.getConstants()
    return {
        states={running=STATE.RUNNING, paused=STATE.PAUSED, terminated=STATE.TERMINATED},
        types={windowed=TYPE.WINDOWED, background=TYPE.BACKGROUND},
    }
end

return api
