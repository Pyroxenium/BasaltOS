-- /services/ui.lua
-- UI Manager: Central Basalt instance manager

local api_factory = require("core.api")
local basalt = require("lib.public.basalt")
local event = require("core.event")

-- Animation is an optional Basalt 2.5 module and must be enabled explicitly.
basalt.use("animation")

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
local redraw_pending = false
local force_redraw_pending = false
local RENDER_INTERVAL = 0.05
local global_event_handlers = {}
local global_handler_order = 0

-- Basalt keeps a diff of the last frame it presented. A forced redraw binds the
-- root to the current terminal again, which creates a fresh render buffer and
-- guarantees that every row is written even if boot output changed the terminal
-- behind Basalt's back.
local function redraw(force)
    if not main_frame then
        return false, "UI is not initialized"
    end

    if is_updating then
        redraw_pending = true
        force_redraw_pending = force_redraw_pending or force == true
        return true
    end

    if force then
        local target = term.current and term.current() or term
        main_frame:setTerm(target)
    else
        main_frame:markDirty()
    end

    basalt.flush()
    return true
end

local function flushPendingRedraw()
    if not redraw_pending then return end

    local force = force_redraw_pending
    redraw_pending = false
    force_redraw_pending = false
    redraw(force)
end

local function dispatchGlobalHandlers(event_name, ...)
    for _, record in ipairs(global_event_handlers) do
        local ok, consumed = pcall(record.callback, event_name, ...)
        if not ok then
            print("Error in global UI handler '" .. record.id .. "': " .. tostring(consumed))
        elseif consumed == true then
            return true
        end
    end
    return false
end

local function processRawEvent(event_name, ...)
    if dispatchGlobalHandlers(event_name, ...) then return end
    basalt.update(event_name, ...)
end

local function handleRawEvent(event_name, ...)
    if not is_running then return end
    if is_updating then
        table.insert(pending_events, {event_name, ...})
        return
    end
    is_updating = true
    processRawEvent(event_name, ...)
    is_updating = false
    -- Drain any deferred OS event dispatches first (e.g. wm.app_crashed)
    while #pending_dispatches > 0 do
        local ev = table.remove(pending_dispatches, 1)
        event.dispatch(table.unpack(ev))
    end
    while #pending_events > 0 do
        local ev = table.remove(pending_events, 1)
        is_updating = true
        processRawEvent(table.unpack(ev))
        is_updating = false
    end
    flushPendingRedraw()
end

-- Schedule an event.dispatch to run after the current Basalt update cycle.
-- Use this from inside Basalt callbacks (onClick, onError, etc.) to avoid re-entrancy.
function api.public.deferDispatch(event_name, ...)
    table.insert(pending_dispatches, {event_name, ...})
end

-- Redraws the active UI immediately. Use force=true after direct terminal
-- output so Basalt does not rely on its retained line-diff cache.
function api.public.redraw(force)
    return redraw(force == true)
end

function api.public.init()
    basalt.setRenderInterval(RENDER_INTERVAL)
    main_frame = basalt.getMainFrame()

    event.onRaw(handleRawEvent)
end

-- Registers an OS-level event handler which runs before events reach the
-- focused application. Returning true consumes the event.
function api.public.registerGlobalEventHandler(id, callback, priority)
    if type(id) ~= "string" or id == "" then
        return nil, "Handler ID is required"
    end
    if type(callback) ~= "function" then
        return nil, "Handler callback is required"
    end

    api.public.unregisterGlobalEventHandler(id)
    global_handler_order = global_handler_order + 1
    local record = {
        id=id,
        callback=callback,
        priority=tonumber(priority) or 0,
        order=global_handler_order,
    }
    global_event_handlers[#global_event_handlers + 1] = record
    table.sort(global_event_handlers, function(left, right)
        if left.priority == right.priority then return left.order < right.order end
        return left.priority > right.priority
    end)

    local controller = {}
    function controller:destroy()
        for index = #global_event_handlers, 1, -1 do
            if global_event_handlers[index] == record then
                table.remove(global_event_handlers, index)
                break
            end
        end
    end
    return controller
end

function api.public.unregisterGlobalEventHandler(id)
    local removed = false
    for index = #global_event_handlers, 1, -1 do
        if global_event_handlers[index].id == id then
            table.remove(global_event_handlers, index)
            removed = true
        end
    end
    return removed
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

    -- Screen changes are rare and must fully replace boot/login leftovers.
    redraw(true)

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
