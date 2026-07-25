--- Obsidian Logger Module
--- Provides logging functionality with different levels (info, warn, error, debug).

---@diagnostic disable: undefined-global

--- This is the main logger module for Obsidian. It buffers log entries in memory and also writes them to a log file. The logger supports different log levels (info, warn, error, debug) and can be extended with a console hook to forward log lines to an in-game console overlay.
---@class LoggerModule
---@field history table<number, { level:string, text:string, color:string }> Buffered log history entries
---@field maxHistory number Maximum number of log entries to keep in history
---@field logFile string Path to the log file
---@field _fileInitialized boolean Internal flag to track if the log file has been initialized
---@field _consoleHook any|nil Optional hook function to forward log lines to the console
local logger = {
    history = {},
    maxHistory = 8,
    logFile = "obsidian.log",
    _fileInitialized = false,
    --- Optional hook: set by engine to forward log lines to the console.
    --- Signature: function(text, colorChar)
    _consoleHook = nil,
}

local colors = {
    INFO = "0",
    WARN = "1",
    ERROR = "e",
    DEBUG = "7"
}

--- Add a log entry to history and the log file.
---@param level string
---@param msg any
function logger._add(level, msg)
    local timestamp = os.date("%H:%M:%S")
    local logLine = string.format("[%s] [%s] %s", timestamp, level, tostring(msg))

    local entry = {
        level = level,
        text = logLine,
        color = colors[level] or "0"
    }

    table.insert(logger.history, entry)
    if #logger.history > logger.maxHistory then
        table.remove(logger.history, 1)
    end

    local mode = logger._fileInitialized and "a" or "w"
    local f = fs.open(logger.logFile, mode)
    if f then
        logger._fileInitialized = true
        f.writeLine(logLine)
        f.close()
    end

    if logger._consoleHook then
        logger._consoleHook(logLine, colors[level] or "0")
    end
end

--- Log an info-level message.
---@param msg any
function logger.info(msg) logger._add("INFO", msg) end

--- Log a warn-level message.
---@param msg any
function logger.warn(msg) logger._add("WARN", msg) end

--- Log an error-level message.
---@param msg any
function logger.error(msg) logger._add("ERROR", msg) end

--- Log a debug-level message.
---@param msg any
function logger.debug(msg) logger._add("DEBUG", msg) end

--- Return the buffered log history.
---@return table
function logger.getHistory() return logger.history end

return logger