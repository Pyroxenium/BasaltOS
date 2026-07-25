--- Obsidian Input Module
-- Tracks current and previous key/mouse states, provides helper functions for querying input state, and allows registration of key and combo hooks.

---@diagnostic disable: undefined-global

--- The main input module, responsible for tracking key and mouse states and providing helper functions.
---@class InputModule
---@field keysDown table<number, boolean> Keys currently held down
---@field keysDownPrevious table<number, boolean> Keys held down in the previous frame
---@field mouseDown table<number, boolean> Mouse buttons currently held down
---@field mouseDownPrevious table<number, boolean> Mouse buttons held down in the previous frame
---@field mouseX number Current mouse X position
---@field mouseY number Current mouse Y position
---@field _keyHooks table<number, table> # map key -> list of handlers
---@field _comboHooks table<number, table> # list of combos
---@field _nextHookId number Next numeric ID to assign to a registered hook
local input = {
    keysDown         = {},
    keysDownPrevious = {},
    mouseDown         = {},
    mouseDownPrevious = {},
    mouseX = 0,
    mouseY = 0,
    _keyHooks = {},
    _comboHooks = {},
    _nextHookId = 0,
    _defaultRepeatDelay = 0.4,
    _defaultRepeatInterval = 0.12,
}

--- Process a raw input event.
--- This is called by the engine when an input event occurs. It updates internal state and triggers any relevant hooks.
---@param event string The event type (e.g. "key", "key_up", "mouse_click", etc.)
---@param ... any Event-specific parameters (e.g. key code, mouse button, coordinates)
function input.processEvent(event, ...)
    local p1, p2, p3 = ...
    if event == "key" then
        input.keysDown[p1] = true

        if input.isJustPressed(p1) then
            local hooks = input._keyHooks[p1]
            if hooks then
                local now = os.clock()
                for _, h in ipairs(hooks) do
                    local ok, _ = pcall(h.handler, p1, { event = "pressed" })
                    if not ok then end
                    -- start repeat if requested (support alias `repeatable` to avoid reserved word)
                    local wantsRepeat = false
                    if h.opts then
                        if h.opts.repeatable ~= nil then
                            wantsRepeat = h.opts.repeatable
                        elseif h.opts["repeat"] ~= nil then
                            wantsRepeat = h.opts["repeat"]
                        elseif h.opts.repeating ~= nil then
                            wantsRepeat = h.opts.repeating
                        elseif h.opts.repeats ~= nil then
                            wantsRepeat = h.opts.repeats
                        end
                    end
                    if wantsRepeat then
                        h._holding = true
                        local delay = h.opts.repeatDelay or h.opts.repeatInterval or input._defaultRepeatDelay
                        h._nextRepeat = now + (delay or input._defaultRepeatDelay)
                    end
                end
            end
        end

        for _, combo in ipairs(input._comboHooks) do
            local allDown = true
            for _, k in ipairs(combo.keys) do
                if not input.keysDown[k] then allDown = false; break end
            end
            if allDown and not combo._fired then
                combo._fired = true
                pcall(combo.handler, combo.keys)
            end
        end
    elseif event == "key_up" then
        input.keysDown[p1] = false
        for _, combo in ipairs(input._comboHooks) do
            for _, k in ipairs(combo.keys) do
                if k == p1 then combo._fired = false; break end
            end
        end

        local hooks = input._keyHooks[p1]
        if hooks then
            for _, h in ipairs(hooks) do
                h._holding = false
                h._nextRepeat = nil
            end
        end
    elseif event == "mouse_click" or event == "mouse_drag" then
        input.mouseDown[p1] = true
        input.mouseX = p2
        input.mouseY = p3
    elseif event == "mouse_up" then
        input.mouseDown[p1] = false
        input.mouseX = p2
        input.mouseY = p3

    elseif event == "mouse_scroll" then
        input.mouseX = p2
        input.mouseY = p3
    elseif event == "mouse_move" then
        input.mouseX = p1
        input.mouseY = p2
    end
end

--- Advance internal frame state (copy current -> previous and trim nils).
function input._endFrame()
    local now = os.clock()
    for k, hooks in pairs(input._keyHooks) do
        for _, h in ipairs(hooks) do
            if h._holding and h._nextRepeat and now >= h._nextRepeat then
                local ok, _ = pcall(h.handler, k, { event = "repeat" })
                if not ok then end
                local interval = (h.opts and h.opts.repeatInterval) or input._defaultRepeatInterval
                h._nextRepeat = now + interval
            end
        end
    end
    for k, v in pairs(input.keysDown)  do input.keysDownPrevious[k]  = v end
    for k, v in pairs(input.mouseDown) do input.mouseDownPrevious[k] = v end
    for k in pairs(input.keysDownPrevious) do
        if not input.keysDown[k] then input.keysDownPrevious[k] = nil end
    end
    for k in pairs(input.mouseDownPrevious) do
        if not input.mouseDown[k] then input.mouseDownPrevious[k] = nil end
    end
end

--- Clear all input state (useful when switching scenes).
function input.clear()
    input.keysDown = {}
    input.keysDownPrevious = {}
    input.mouseDown = {}
    input.mouseDownPrevious = {}
end

--- Check if a key is currently held down.
---@param key number|string Key code or key name
---@return boolean True if the key is currently down
function input.isKeyDown(key)
    if type(key) == "string" then key = keys[key] end
    return input.keysDown[key] == true
end

--- True if key pressed this frame (was not down previous frame).
---@param key number|string Key code or key name
---@return boolean True if the key was just pressed this frame
function input.isJustPressed(key)
    if type(key) == "string" then key = keys[key] end
    return input.keysDown[key] == true and not (input.keysDownPrevious[key] == true)
end

--- True if key was released this frame.
---@param key number|string Key code or key name
---@return boolean True if the key was just released this frame
function input.isJustReleased(key)
    if type(key) == "string" then key = keys[key] end
    return not (input.keysDown[key] == true) and input.keysDownPrevious[key] == true
end

--- Check if a mouse button is currently down.
---@param button number Mouse button index (1 = left, 2 = right, 3 = middle)
---@return boolean True if the mouse button is currently down
function input.isMouseDown(button)
    return input.mouseDown[button] == true
end

--- True if mouse button pressed this frame.
---@param button number Mouse button index (1 = left, 2 = right, 3 = middle)
---@return boolean True if the mouse button was just pressed this frame
function input.isMouseJustPressed(button)
    return input.mouseDown[button] == true and not (input.mouseDownPrevious[button] == true)
end

--- True if mouse button was released this frame.
---@param button number Mouse button index (1 = left, 2 = right, 3 = middle)
---@return boolean True if the mouse button was just released this frame
function input.isMouseJustReleased(button)
    return not (input.mouseDown[button] == true) and input.mouseDownPrevious[button] == true
end

--- Get current mouse position.
---@return number x, number y Current mouse coordinates
function input.getMousePos()
    return input.mouseX, input.mouseY
end

local function _normalizeKey(k)
    if type(k) == "string" then return keys[k] end
    return k
end

--- Register a handler for a key press. Returns a numeric id.
--- `key` may be a number (keycode), a string key name, or a table of such values.
---@param key number|string|table Key code, key name, or array of codes/names to bind
---@param handler fun(key:any, info:table) Function to call when the key is pressed. Receives the normalized key code and an info table with an `event` field ("pressed" or "repeat").
---@param opts table? Optional settings
---@return number id Numeric ID for the registered hook, used for unregistration
function input.onKey(key, handler, opts)
    opts = opts or {}
    input._nextHookId = input._nextHookId + 1
    local id = input._nextHookId
    local keysToRegister = {}
    if type(key) == "table" then
        for _, k in ipairs(key) do
            local nk = _normalizeKey(k)
            if nk ~= nil then table.insert(keysToRegister, nk) end
        end
    else
        local nk = _normalizeKey(key)
        if nk ~= nil then table.insert(keysToRegister, nk) end
    end
    if #keysToRegister == 0 then return nil end
    for _, k in ipairs(keysToRegister) do
        if not input._keyHooks[k] then input._keyHooks[k] = {} end
        table.insert(input._keyHooks[k], { id = id, handler = handler, opts = opts, _holding = false, _nextRepeat = nil })
    end
    return id
end

--- Unregister a key hook by id.
---@param id number ID of the hook to unregister (returned by onKey)
function input.offKey(id)
    for k, list in pairs(input._keyHooks) do
        for i = #list, 1, -1 do
            if list[i].id == id then table.remove(list, i) end
        end
        if #list == 0 then input._keyHooks[k] = nil end
    end
end

--- Register a simultaneous combo (array of keys). Returns id.
---@param keys table Array of key codes or key names that must be held simultaneously to trigger
---@param handler fun(keys:table) Function to call when the combo is activated. Receives an array of the normalized key codes.
---@param opts table? Optional settings
---@return number id Numeric ID for the registered combo hook, used for unregistration
function input.onCombo(keys, handler, opts)
    opts = opts or {}
    input._nextHookId = input._nextHookId + 1
    local id = input._nextHookId
    local normalized = {}
    for _, k in ipairs(keys) do
        local nk = _normalizeKey(k)
        if nk ~= nil then table.insert(normalized, nk) end
    end
    if #normalized == 0 then return nil end
    table.insert(input._comboHooks, { id = id, keys = normalized, handler = handler, opts = opts, _fired = false })
    return id
end

--- Unregister a combo hook by id.
---@param id number ID of the combo hook to unregister (returned by onCombo)
function input.offCombo(id)
    for i = #input._comboHooks, 1, -1 do
        if input._comboHooks[i].id == id then table.remove(input._comboHooks, i) end
    end
end

--- Remove all registered hooks.
function input.clearHooks()
    input._keyHooks = {}
    input._comboHooks = {}
    input._nextHookId = 0
end

return input