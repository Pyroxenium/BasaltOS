---@diagnostic disable: undefined-global
local logger = require("core.logger")

--- EventEmitter — instanced event bus.
--- Create a new bus with EventEmitter.new().
--- Each Engine and each Scene owns one bus:
---   Engine.event   → global, always active
---   scene.event    → scene-local, only forwarded when the scene is active
---@class EventEmitter
---@field _listeners table<string, table<any, function>> Internal map of event name to listener functions
local EventEmitter = {}
EventEmitter.__index = EventEmitter

--- Create a new EventEmitter instance.
--- @return EventEmitter
function EventEmitter.new()
    return setmetatable({ _listeners = {} }, EventEmitter)
end

--- Subscribe to an event.
--- @param self EventEmitter event emitter instance
--- @param name string event name
--- @param fn function event handler callback
--- @return function Unsubscribe call to remove this listener
function EventEmitter:on(name, fn)
    if not self._listeners[name] then
        self._listeners[name] = {}
    end
    local id = {}
    self._listeners[name][id] = fn
    return function()
        local bucket = self._listeners[name]
        if bucket then bucket[id] = nil end
    end
end

--- Subscribe to an event exactly once; auto-removes after first call.
--- @param self EventEmitter event emitter instance
--- @param name string event name
--- @param fn function event handler callback
--- @return function  Unsubscribe call to remove this listener
function EventEmitter:once(name, fn)
    local unsub
    unsub = self:on(name, function(...)
        unsub()
        fn(...)
    end)
    return unsub
end

--- Emit an event, calling all registered listeners.
--- Errors in listeners are caught and logged so one bad handler cannot
--- break the chain.
--- @param self EventEmitter event emitter instance
--- @param name string event name
--- @param ... any additional arguments to pass to listeners
function EventEmitter:emit(name, ...)
    local bucket = self._listeners[name]
    if not bucket then return end
    for _, fn in pairs(bucket) do
        local ok, err = pcall(fn, ...)
        if not ok then
            logger.error(string.format("EventEmitter '%s' handler failed: %s", name, tostring(err)))
        end
    end
end

--- Remove all listeners for a specific event name.
--- @param self EventEmitter event emitter instance
--- @param name string event name
function EventEmitter:off(name)
    self._listeners[name] = nil
end

--- Remove all listeners on this emitter.
--- @param self EventEmitter event emitter instance
function EventEmitter:clear()
    self._listeners = {}
end

return EventEmitter