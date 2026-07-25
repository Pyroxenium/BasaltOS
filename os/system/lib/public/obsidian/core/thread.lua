--- Obsidian Thread Module
--- Provides a simple cooperative threading system using Lua coroutines. Threads can yield with an optional event filter and will be resumed when that event occurs. Uncaught errors in threads are handled by an optional global error handler.

local logger = require("core.logger")

---@diagnostic disable: undefined-global

--- This is the thread module for managing concurrent coroutines in the engine. It provides functions to start, stop, and update threads, as well as error handling and event filtering.
---@class ThreadModule
---@field errorHandler any|nil Optional global error handler function for uncaught thread errors
local ThreadModule = {}
ThreadModule.errorHandler = nil

local threads = {}
local nextId  = 1

local function tracebackHandler(e)
    local d = _G and _G.debug
    return (d and d.traceback) and d.traceback(tostring(e), 2) or tostring(e)
end

--- Public Thread handle class with methods to control individual threads. The actual thread data is stored in the ThreadModule's internal threads table, and the handle provides a safe interface to interact with it.
---@class Thread
---@field id number Unique thread ID
local thread = {}

--- Stop the thread. Returns true if the thread was successfully stopped, false if it was not found.
---@return boolean success True if the thread was stopped, false if not found
function thread:stop()
    return ThreadModule.stop(self)
end

--- Check if the thread is still alive (not dead). Returns false if the thread has finished or was stopped.
---@return boolean alive True if the thread is alive, false if dead or not found
function thread:isAlive()
    local id = type(self) == "table" and self.id or nil
    if not id then return false end
    local entry = threads[id]
    return entry ~= nil and coroutine.status(entry.co) ~= "dead"
end

--- Get the current status of the thread ("running", "suspended", "dead"). Returns nil if the thread is not found.
---@return string|nil status The current status of the thread, or nil if not found
function thread:getStatus()
    local id = type(self) == "table" and self.id or nil
    if not id then return nil end
    local entry = threads[id]
    return entry and entry.status or nil
end

--- Yield the current thread with an optional event filter. The thread will be resumed when an event matching the filter occurs (or on any event if filter is nil). Returns the event arguments when resumed.
---@param eventFilter any|nil Optional event filter to yield on (e.g. "timer", "redstone", etc.). If nil, the thread will resume on any event.
---@return ... The event arguments passed to coroutine.resume when the thread is resumed
function thread:yield(eventFilter)
    return ThreadModule.yield(eventFilter)
end

local function createHandle(id)
    local h = { id = id }
    setmetatable(h, { __index = thread })
    return h
end

--- Start a new thread running the given function. The function will be wrapped in error handling to catch uncaught errors. Returns a Thread handle object.
---@return Thread
function ThreadModule.start(fn)
    local co = coroutine.create(function(...)
        local ok, err = xpcall(fn, tracebackHandler, ...)
        if not ok then
            if ThreadModule.errorHandler then
                ThreadModule.errorHandler(err)
            else
                logger.error("[Thread] Uncaught error: " .. tostring(err))
            end
        end
    end)
    local id = nextId
    nextId = nextId + 1
    local handle = createHandle(id)
    threads[id] = { id = id, co = co, status = "running", filter = nil, handle = handle }
    return handle
end

--- Stop a thread by its ID or handle. Returns true if the thread was successfully stopped, false if it was not found.
---@param idOrHandle number|Thread The thread ID or handle to stop
---@return boolean success True if the thread was stopped, false if not found
function ThreadModule.stop(idOrHandle)
    local id = idOrHandle
    if type(idOrHandle) == "table" and idOrHandle.id then id = idOrHandle.id end
    if id == nil then return false end
    if threads[id] then
        threads[id] = nil
        return true
    end
    return false
end

--- Returns a shallow copy of the active threads table (id → {co, status, filter}).
--- Note that the coroutines themselves cannot be safely exposed, so only the thread metadata is included. Use with caution as this is a snapshot and may not reflect the current state of threads.
---@return table A copy of the active threads table with thread metadata (id → {status,
function ThreadModule.getAll()
    local copy = {}
    for id, t in pairs(threads) do copy[id] = t end
    return copy
end

--- Returns the number of threads that are still alive.
---@return number count The number of alive threads
function ThreadModule.count()
    local n = 0
    for _, t in pairs(threads) do
        if coroutine.status(t.co) ~= "dead" then n = n + 1 end
    end
    return n
end

--- Resets the thread system by clearing all threads and resetting the ID counter. Use with caution as this will stop all active threads without cleanup.
function ThreadModule.reset()
    threads = {}
    nextId  = 1
end

--- Yield the current thread with an optional event filter. The thread will be resumed when an event matching the filter occurs (or on any event if filter is nil). Returns the event arguments when resumed.
---@param eventFilter any|nil Optional event filter to yield on (e.g. "timer", "redstone", etc.). If nil, the thread will resume on any event.
---@return ... The event arguments passed to coroutine.resume when the thread is resumed
function ThreadModule.yield(eventFilter)
    return coroutine.yield(eventFilter)
end

--- Internal function to update threads based on events. Should be called by the engine's main loop with the current event.
---@param ... any The event arguments
function ThreadModule.update(...)
    local event = { ... }
    local snapshot = {}
    for id, t in pairs(threads) do snapshot[id] = t end

    for id, t in pairs(snapshot) do
        if coroutine.status(t.co) ~= "dead" then
            if t.filter == event[1] or t.filter == nil then
                local ok, result = coroutine.resume(t.co, table.unpack(event))
                if not ok then
                    if ThreadModule.errorHandler then
                        ThreadModule.errorHandler(result)
                    else
                        logger.error("[Thread] Error in Thread " .. id .. ": " .. tostring(result))
                    end
                    threads[id] = nil
                else
                    t.filter = result
                end
            end
        else
            threads[id] = nil
        end
    end
end

return ThreadModule
