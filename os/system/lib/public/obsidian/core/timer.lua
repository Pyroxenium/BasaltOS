-- Obsidian Timer Module
-- Scheduling system for delayed and repeating callbacks

---@diagnostic disable: undefined-global

local logger = require("core.logger")

---@alias TimerHandle table Opaque handle returned by timer functions

--- Timer entry structure
---@class TimerEntry
---@field handle TimerHandle Opaque handle for control
---@field elapsed number Time elapsed since last trigger
---@field interval number Time between triggers
---@field callback function Function to call when timer triggers
---@field repeating boolean Whether the timer should repeat
---@field maxTimes number Maximum times to trigger (math.huge for infinite)
---@field firedCount number How many times the timer has triggered
---@field paused boolean Whether the timer is currently paused

--- This module provides functions to schedule delayed and repeating callbacks, useful for timed events, animations, or game logic. Timers can be created, paused, resumed, and cancelled via their handles.
---@class TimerModule
---@field _active TimerEntry[] List of active timers
local TimerModule = {
    _active = {}
}

local function createHandle()
    local handle = {}
    local methods = {
        cancel = function(self) return TimerModule.cancel(self) end,
        pause = function(self) return TimerModule.pause(self) end,
        resume = function(self) return TimerModule.resume(self) end,
        isActive = function(self) return TimerModule.isActive(self) end,
        getRemaining = function(self) return TimerModule.getRemaining(self) end,
        getFiredCount = function(self) return TimerModule.getFiredCount(self) end,
    }
    return setmetatable(handle, { __index = methods })
end

--- Schedule a one-shot callback after a delay
---@param delay number Seconds to wait
---@param callback function Callback to execute
---@return TimerHandle handle Opaque handle for cancellation
function TimerModule.after(delay, callback)
    if type(delay) ~= "number" or delay < 0 then
        logger.error("Timer: Invalid delay (must be non-negative number)")
        return createHandle()
    end
    if type(callback) ~= "function" then
        logger.error("Timer: Invalid callback (must be function)")
        return createHandle()
    end

    local handle = createHandle()

    table.insert(TimerModule._active, {
        handle = handle,
        elapsed = 0,
        interval = delay,
        callback = callback,
        repeating = false,
        maxTimes = 1,
        firedCount = 0,
        paused = false,
    })
    
    return handle
end

--- Schedule a repeating callback
---@param interval number Seconds between each execution
---@param callback function Callback to execute
---@param maxTimes number|nil Maximum executions (nil = infinite)
---@return TimerHandle handle Opaque handle for cancellation
function TimerModule.every(interval, callback, maxTimes)
    if type(interval) ~= "number" or interval <= 0 then
        logger.error("Timer: Invalid interval (must be positive number)")
        return createHandle()
    end
    if type(callback) ~= "function" then
        logger.error("Timer: Invalid callback (must be function)")
        return createHandle()
    end

    local handle = createHandle()

    table.insert(TimerModule._active, {
        handle = handle,
        elapsed = 0,
        interval = interval,
        callback = callback,
        repeating = true,
        maxTimes = maxTimes or math.huge,
        firedCount = 0,
        paused = false,
    })

    return handle
end

--- Schedule callback for next frame (shorthand for after(0, fn))
---@param callback function Callback to execute
---@return TimerHandle handle Opaque handle for cancellation
function TimerModule.nextFrame(callback)
    return TimerModule.after(0, callback)
end

--- Cancel a timer by handle
---@param handle TimerHandle Opaque handle returned by timer functions
---@return boolean True if timer was found and cancelled, false if not found
function TimerModule.cancel(handle)
    for i = #TimerModule._active, 1, -1 do
        if TimerModule._active[i].handle == handle then
            table.remove(TimerModule._active, i)
            return true
        end
    end
    return false
end

--- Pause a specific timer
---@param handle TimerHandle Opaque handle returned by timer functions
---@return boolean True if timer was found and paused, false if not found
function TimerModule.pause(handle)
    for _, timer in ipairs(TimerModule._active) do
        if timer.handle == handle then
            timer.paused = true
            return true
        end
    end
    return false
end

--- Resume a specific timer
---@param handle TimerHandle Opaque handle returned by timer functions
---@return boolean True if timer was found and resumed, false if not found
function TimerModule.resume(handle)
    for _, timer in ipairs(TimerModule._active) do
        if timer.handle == handle then
            timer.paused = false
            return true
        end
    end
    return false
end

--- Pause all active timers
function TimerModule.pauseAll()
    for _, timer in ipairs(TimerModule._active) do timer.paused = true end
end

--- Resume all paused timers
function TimerModule.resumeAll()
    for _, timer in ipairs(TimerModule._active) do timer.paused = false end
end

--- Cancel all active timers
function TimerModule.cancelAll()
    TimerModule._active = {}
end

--- Check if a timer is still active
---@param handle TimerHandle Opaque handle returned by timer functions
---@return boolean True if timer is active, false if not
function TimerModule.isActive(handle)
    for _, timer in ipairs(TimerModule._active) do
        if timer.handle == handle then
            return true
        end
    end
    return false
end

--- Get number of active timers
---@return number Count of active timers
function TimerModule.count()
    return #TimerModule._active
end

--- Get remaining time for a timer
---@param handle TimerHandle Opaque handle returned by timer functions
---@return number|nil Remaining time in seconds, or nil if timer not found
function TimerModule.getRemaining(handle)
    for _, timer in ipairs(TimerModule._active) do
        if timer.handle == handle then
            return math.max(0, timer.interval - timer.elapsed)
        end
    end
    return nil
end

--- Get how many times a repeating timer has fired
---@param handle TimerHandle Opaque handle returned by timer functions
---@return number|nil Fired count, or nil if timer not found
function TimerModule.getFiredCount(handle)
    for _, timer in ipairs(TimerModule._active) do
        if timer.handle == handle then
            return timer.firedCount
        end
    end
    return nil
end

--- Update all timers (called by engine each frame)
---@param dt number Delta time in seconds
function TimerModule.update(dt)
    for i = #TimerModule._active, 1, -1 do
        local timer = TimerModule._active[i]
        timer.elapsed = timer.elapsed + dt
        if not timer.paused then
            if timer.elapsed >= timer.interval then
                timer.elapsed = timer.elapsed - timer.interval
                timer.firedCount = timer.firedCount + 1

                local ok, err = pcall(timer.callback)
                if not ok then
                    logger.error("Timer: Callback error - " .. tostring(err))
                    table.remove(TimerModule._active, i)
                elseif not timer.repeating or 
                       (timer.maxTimes ~= math.huge and timer.firedCount >= timer.maxTimes) then
                    table.remove(TimerModule._active, i)
                end
            end
        end
    end
end

--- Get debug info for all active timers
---@return table[] info List of timer info tables with remaining time, interval, repeating, fired count, max times, and paused state
function TimerModule.getDebugInfo()
    local info = {}
    for _, timer in ipairs(TimerModule._active) do
        table.insert(info, {
            remaining = timer.interval - timer.elapsed,
            interval = timer.interval,
            repeating = timer.repeating,
            firedCount = timer.firedCount,
            maxTimes = timer.maxTimes,
        })
    end
    return info
end

return TimerModule