-- /core/log.lua
-- Logging system: Write logs to files for debugging

local log = {}

-- Log levels
log.LEVEL = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    FATAL = 5
}

local LEVEL_NAMES = {
    [1] = "DEBUG",
    [2] = "INFO",
    [3] = "WARN",
    [4] = "ERROR",
    [5] = "FATAL"
}

-- Configuration
local current_level = log.LEVEL.DEBUG
local log_dir = "system/logs"
local current_log_file = nil
local max_log_size = 50000 -- bytes
local log_rotation_count = 3
local init

local function rotate_logs()
    local files = fs.list(log_dir)
    local log_files = {}

    for _, file in ipairs(files) do
        if file:match("%.log$") then
            local full_path = fs.combine(log_dir, file)
            local modified = fs.attributes(full_path).modified
            table.insert(log_files, {path = full_path, time = modified})
        end
    end

    table.sort(log_files, function(a, b) return a.time < b.time end)

    while #log_files > log_rotation_count do
        fs.delete(log_files[1].path)
        table.remove(log_files, 1)
    end
end

local function write_to_file(message)
    if not current_log_file then
        init()
    end

    local file = fs.open(current_log_file, "a")
    if file then
        file.writeLine(message)
        file.close()

        local size = fs.getSize(current_log_file)
        if size > max_log_size then
            init()
        end
    end
end

function init()
    if not fs.exists(log_dir) then
        fs.makeDir(log_dir)
    end

    local timestamp = os.date("%Y%m%d_%H%M%S")
    current_log_file = log_dir .. "/system_" .. timestamp .. ".log"

    rotate_logs()

    write_to_file("[LOG] System started at " .. os.date("%Y-%m-%d %H:%M:%S"))
end

local function format_message(level, category, message)
    local timestamp = os.date("%H:%M:%S")
    local level_name = LEVEL_NAMES[level] or "UNKNOWN"
    return string.format("[%s] [%s] [%s] %s", timestamp, level_name, category, tostring(message))
end

local function log_message(level, category, message, data)
    if level < current_level then
        return
    end

    local formatted = format_message(level, category, message)

    if data then
        formatted = formatted .. " | Data: " .. textutils.serialize(data)
    end

    write_to_file(formatted)

    if level >= log.LEVEL.ERROR then
        print(formatted)
    end
end

function log.debug(category, message, data)
    log_message(log.LEVEL.DEBUG, category, message, data)
end

function log.info(category, message, data)
    log_message(log.LEVEL.INFO, category, message, data)
end

function log.warn(category, message, data)
    log_message(log.LEVEL.WARN, category, message, data)
end

function log.error(category, message, data)
    log_message(log.LEVEL.ERROR, category, message, data)
end

function log.fatal(category, message, data)
    log_message(log.LEVEL.FATAL, category, message, data)
end

function log.setLevel(level)
    current_level = level
end

function log.getCurrentLogFile()
    return current_log_file
end

function log.getLogFiles()
    local files = {}
    if fs.exists(log_dir) then
        for _, file in ipairs(fs.list(log_dir)) do
            if file:match("%.log$") then
                table.insert(files, fs.combine(log_dir, file))
            end
        end
    end
    return files
end

function log.readLog(filepath)
    if not fs.exists(filepath) then
        return nil, "File not found"
    end

    local file = fs.open(filepath, "r")
    if not file then
        return nil, "Cannot open file"
    end

    local content = file.readAll()
    file.close()
    return content
end

function log.clearLogs()
    if fs.exists(log_dir) then
        for _, file in ipairs(fs.list(log_dir)) do
            if file:match("%.log$") then
                fs.delete(fs.combine(log_dir, file))
            end
        end
    end
    init()
end

init()

return log
