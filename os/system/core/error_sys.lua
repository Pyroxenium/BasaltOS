-- /core/error_log.lua
-- Central error logging to system/logs/error.log
-- Opens and closes file for each write to prevent file locking issues

local function ensureLogDirectory()
    if not fs.exists("system/logs") then
        fs.makeDir("system/logs")
    end
end

local function formatTimestamp()
    local time = os.time()
    local hour = math.floor(time)
    local minute = math.floor((time % 1) * 60)
    local second = math.floor(((time * 60) % 1) * 60)

    local day = os.day()
    return string.format("[%04d-%02d:%02d:%02d]", day, hour, minute, second)
end

local function logError(level, source, error_msg, trace)
    ensureLogDirectory()

    local log_file = fs.open("system/logs/error.log", "a")
    if log_file then
        local timestamp = formatTimestamp()
        log_file.writeLine(string.format("%s [%s] %s", timestamp, level, source))
        log_file.writeLine("  Error: " .. tostring(error_msg))

        if trace then
            log_file.writeLine("  Trace:")
            for line in trace:gmatch("[^\r\n]+") do
                log_file.writeLine("    " .. line)
            end
        end

        log_file.writeLine(string.rep("-", 60))
        log_file.close()
    end
end

-- Public API
return {
    -- Log kernel panic
    logKernelPanic = function(error_msg, trace)
        logError("KERNEL PANIC", "system/main.lua", error_msg, trace)
    end,
    
    -- Log app crash
    logAppCrash = function(app_name, pid, error_msg, trace)
        local source = string.format("APP:%s (PID:%s)", app_name or "unknown", tostring(pid))
        logError("APP CRASH", source, error_msg, trace)
    end,
    
    -- Log general error
    logError = function(source, error_msg, trace)
        logError("ERROR", source, error_msg, trace)
    end
}
