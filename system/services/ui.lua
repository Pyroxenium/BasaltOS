-- /services/ui.lua
-- UI Manager: Central Basalt instance manager

local api_factory = require("core.api")
local basalt = require("lib.public.basalt")
local event = require("core.event")

local api = api_factory.new()

local screens = {}
local current_screen = nil
local is_running = false
local main_frame = nil

-- Forward all events to Basalt.
-- Guard against re-entrancy: if basalt.update() is already running (e.g. an OS event
-- was dispatched synchronously from within a Basalt callback), store the event in a
-- local pending queue instead of calling os.queueEvent. This prevents the kernel from
-- re-dispatching the event through event.dispatch (which would double-fire OS listeners
-- like the taskbar). After basalt.update() finishes we drain the queue ourselves.
local is_updating = false
local pending_events = {}
local pending_dispatches = {}  -- deferred event.dispatch calls (from within Basalt callbacks)

local function handleRawEvent(event_name, ...)
    if not is_running then return end
    if is_updating then
        table.insert(pending_events, {event_name, ...})
        return
    end
    is_updating = true
    basalt.update(event_name, ...)
    is_updating = false
    -- Drain any deferred OS event dispatches first (e.g. wm.app_crashed)
    while #pending_dispatches > 0 do
        local ev = table.remove(pending_dispatches, 1)
        event.dispatch(table.unpack(ev))
    end
    while #pending_events > 0 do
        local ev = table.remove(pending_events, 1)
        is_updating = true
        basalt.update(table.unpack(ev))
        is_updating = false
    end
end

-- Schedule an event.dispatch to run after the current Basalt update cycle.
-- Use this from inside Basalt callbacks (onClick, onError, etc.) to avoid re-entrancy.
function api.public.deferDispatch(event_name, ...)
    table.insert(pending_dispatches, {event_name, ...})
end

function api.public.init()
    main_frame = basalt.getMainFrame()

    event.onRaw(handleRawEvent)
end

function api.public.registerScreen(screen_id, builder_fn)
    if screens[screen_id] then
        return false, "Screen already registered"
    end

    screens[screen_id] = {
        id = screen_id,
        builder = builder_fn,
        frame = nil
    }

    return true
end

function api.public.switchScreen(screen_id, ...)
    local screen = screens[screen_id]
    main_frame:setCursor(1, 1, false)

    if not screen then
        return false, "Screen not found: " .. screen_id
    end

    if current_screen then
        api.private.clearCurrentScreen()
    end

    local screen_frame = main_frame:addFrame()
    screen_frame:setPosition(1, 1)
    screen_frame:setSize("{parent.width}", "{parent.height}")
    --screen_frame:stretch(main_frame)

    screen.frame = screen_frame
    screen.builder(screen_frame, ...)
    current_screen = screen_id

    -- Mark UI as running, events will be forwarded to Basalt
    is_running = true

    return true
end

function api.private.clearCurrentScreen()
    if not current_screen then
        return
    end

    local screen = screens[current_screen]
    if screen and screen.frame then
        screen.frame:destroy()
        screen.frame = nil
    end
end

function api.public.stop()
    if is_running then
        is_running = false
        api.private.clearCurrentScreen()
    end

    current_screen = nil
end

function api.public.getCurrentScreen()
    return current_screen
end

function api.public.isRunning()
    return is_running
end

function api.public.getMainFrame()
    return main_frame
end

function api.private.getBasalt()
    return basalt
end

function api.public.getScreen(screen_id)
    local screen = screens[screen_id]
    if screen then
        return screen.frame
    end
    return nil
end

function api.public.unregisterScreen(screen_id)
    if current_screen == screen_id then
        return false, "Cannot unregister active screen"
    end

    screens[screen_id] = nil
    return true
end

return api
