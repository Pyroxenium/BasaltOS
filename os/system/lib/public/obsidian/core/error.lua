---@diagnostic disable: undefined-global
-- Obsidian Error Handler
-- Displays a panic screen with stack trace on unhandled errors.
-- Override Error.handler via Engine.onError(fn) to implement custom error handling.

local logger = require("core.logger")

---@class ErrorModule
---@field handler fun(msg: string)|nil Custom error handler function (optional)
---@field _shouldStop boolean Internal flag to indicate if the engine should stop after an error
local Error = {
    handler = nil,
    _shouldStop = false
}

local function writeLog(msg)
    logger.error("[PANIC] " .. tostring(msg))
end

local function drawPanic(msg)
    writeLog(msg)

    local mainMsg, trace = msg, nil
    local splitPos = msg:find("\nstack traceback:")
    if splitPos then
        mainMsg = msg:sub(1, splitPos - 1)
        trace   = msg:sub(splitPos + 1)
    end

    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()

    term.setBackgroundColor(colors.red)
    term.setCursorPos(1, 1)
    term.clearLine()
    local title = " OBSIDIAN ERROR "
    term.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
    term.setTextColor(colors.white)
    term.write(title)
    term.setBackgroundColor(colors.black)

    local y = 3
    term.setTextColor(colors.yellow)
    for line in mainMsg:gmatch("[^\n]+") do
        if y > h - 5 then break end
        term.setCursorPos(2, y)
        term.write(line:sub(1, w - 2))
        y = y + 1
    end

    if trace and y < h - 2 then
        y = y + 1
        if y <= h - 2 then
            term.setCursorPos(2, y)
            term.setTextColor(colors.lightGray)
            term.write("Stack Traceback:")
            y = y + 1
        end
        for line in trace:gmatch("[^\n]+") do
            if y > h - 2 then break end
            if line ~= "stack traceback:" then
                local isInternal = line:find("/core/")
                    or line:find("engine%.lua")
                    or line:find("error%.lua")
                    or line:find("%[C%]")
                term.setTextColor(isInternal and colors.gray or colors.white)
                term.setCursorPos(3, y)
                term.write(line:sub(1, w - 3))
                y = y + 1
            end
        end
    end

    -- Footer
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, h)
    term.clearLine()
    local footer = " Press any key to exit  |  crash saved to obsidian.log "
    term.setCursorPos(math.max(1, math.floor((w - #footer) / 2) + 1), h)
    term.write(footer:sub(1, w))

    os.pullEvent("key")
end


---Report an error through the configured handler or show panic screen.
---@param msg any
---@param trace? string
---@return nil
function Error.report(msg, trace)
    local fullMsg
    if trace and #tostring(trace) > 0 then
        fullMsg = tostring(msg) .. "\n" .. tostring(trace)
    else
        fullMsg = tostring(msg)
    end

    if Error.handler then
        Error.handler(fullMsg)
    else
        drawPanic(fullMsg)
    end

    Error._shouldStop = true
end

return Error
