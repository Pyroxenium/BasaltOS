-- /system/core/event.lua
-- Event system: Event bus for system-wide event handling

local event = {}

local listeners = {}
local raw_callbacks = {}  -- Callbacks that receive ALL events

function event.init()
    listeners = {}
    raw_callbacks = {}
end

-- Register an event listener
-- @param event_name: Name of the event (e.g., "mouse_click", "system.boot_complete")
-- @param callback: Function to call when event fires
-- @param priority: Optional priority (higher = called first), default = 0
function event.on(event_name, callback, priority)
    if type(callback) ~= "function" then
        error("Event callback must be a function")
    end

    priority = priority or 0

    if not listeners[event_name] then
        listeners[event_name] = {}
    end

    table.insert(listeners[event_name], {
        callback = callback,
        priority = priority
    })

    table.sort(listeners[event_name], function(a, b)
        return a.priority > b.priority
    end)
end

function event.off(event_name, callback)
    if not listeners[event_name] then
        return
    end

    for i = #listeners[event_name], 1, -1 do
        if listeners[event_name][i].callback == callback then
            table.remove(listeners[event_name], i)
        end
    end
end

-- Register a raw callback that receives ALL events
-- Useful for UI systems that need to handle all OS events
-- @param callback: Function(event_name, ...) that receives every event
function event.onRaw(callback)
    if type(callback) ~= "function" then
        error("Raw callback must be a function")
    end

    table.insert(raw_callbacks, callback)
end

function event.offRaw(callback)
    for i = #raw_callbacks, 1, -1 do
        if raw_callbacks[i] == callback then
            table.remove(raw_callbacks, i)
        end
    end
end

-- Dispatch an event to all registered listeners
-- @param event_name: Name of the event
-- @param ...: Additional arguments passed to listeners
function event.dispatch(event_name, ...)
    local args = {...}

    if listeners[event_name] then
        for _, listener in ipairs(listeners[event_name]) do
            local ok, err = pcall(function()
                listener.callback(table.unpack(args))
            end)

            if not ok then
                print("Error in event listener for '" .. event_name .. "': " .. tostring(err))
            end
        end
    end

    for _, callback in ipairs(raw_callbacks) do
        local ok, err = pcall(function()
            callback(event_name, table.unpack(args))
        end)

        if not ok then
            print("Error in raw event callback: " .. tostring(err))
        end
    end
end


function event.once(event_name, callback, priority)
    local wrapper
    wrapper = function(...)
        event.off(event_name, wrapper)
        callback(...)
    end

    event.on(event_name, wrapper, priority)
end

function event.getRegisteredEvents()
    local events = {}
    for event_name, _ in pairs(listeners) do
        table.insert(events, event_name)
    end
    return events
end

function event.clear(event_name)
    if event_name then
        listeners[event_name] = nil
    else
        listeners = {}
    end
end

return event
