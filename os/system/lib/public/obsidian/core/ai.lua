--- Obsidian AI — Brain (ECS-integrated FSM)
-- Each entity gets a Brain instance that acts as a full state machine.
-- Auto-transitions, push/pop stack, per-state timers, and perception helpers.
---@diagnostic disable: undefined-global

-- This module is designed to be used as an ECS system that updates all Brain components each frame.
---@class AIModule
local ai = {}

--- ===========================================================================
-- BrainTimer
-- ===========================================================================

-- Represents a scheduled callback for a Brain state.  Managed by the Brain class.
---@class BrainTimer
---@field kind "once"|"repeat" "once" = one-shot, removed after firing; "repeat" = rescheduled after firing
---@field interval? number Interval for "repeat" timers (ignored for "once")
---@field remaining number Seconds until the timer fires
---@field fn any Callback function to call when the timer fires. Signature: `fn(brain)`
local BrainTimer = {}

--- Create a new BrainTimer.
---@param kind "once"|"repeat" "once" = one-shot, removed after firing
---@param seconds number Seconds until the timer fires (and interval for "repeat")
---@param fn any Callback function to call when the timer fires. Signature: `fn(brain: Brain)`
---@return BrainTimer
function BrainTimer.new(kind, seconds, fn)
    assert(kind == "once" or kind == "repeat", "BrainTimer.new — invalid kind '" .. tostring(kind) .. "'")
    assert(type(seconds) == "number" and seconds >= 0, "BrainTimer.new — invalid seconds (must be non-negative number)")
    assert(type(fn) == "function", "BrainTimer.new — fn must be a function")
    return {
        kind = kind,
        interval = (kind == "repeat") and seconds or nil,
        remaining = seconds,
        fn = fn
    }
end

--- ===========================================================================
-- BrainTransition
-- ===========================================================================

-- Represents an automatic transition between states, evaluated each frame before onUpdate.
---@class BrainTransition 
---@field from string Source state name
---@field to string Destination state name
---@field cond any Condition function evaluated each frame. Signature: `fn(brain: Brain) -> bool`. If true, the transition triggers.
local BrainTransition = {}

--- Create a new BrainTransition.
---@param from string Source state name
---@param to string Destination state name
---@param cond any Condition function evaluated each frame.
---@return BrainTransition
function BrainTransition.new(from, to, cond)
    assert(type(from) == "string", "BrainTransition.new — from must be a string")
    assert(type(to) == "string", "BrainTransition.new — to must be a string")
    assert(type(cond) == "function", "BrainTransition.new — cond must be a function")
    return { from = from, to = to, cond = cond }
end

-- ===========================================================================
-- BrainState class
-- ===========================================================================

-- BrainState is just a struct for holding optional callbacks for a state.  The
---@class BrainState
---@field onEnter? fun(self: Brain, fromState: string|nil) Called when the state is entered.
---@field onUpdate? fun(self: Brain, dt: number): string|nil Called every frame. Return a state name to transition.
---@field onExit? fun(self: Brain, toState: string|nil) Called when the state is exited.
---@field onDraw? fun(self: Brain) Called every frame after update for debug drawing.
local BrainState = {}

--- Create a new BrainState.
--- @param onEnter? fun(self: Brain, fromState: string|nil) Called when the state is entered.
--- @param onUpdate? fun(self: Brain, dt: number): string|nil Called
--- @param onExit? fun(self: Brain, toState: string|nil) Called when the state is exited.
--- @param onDraw? fun(self: Brain) Called every frame after update for debug drawing
--- @return BrainState
function BrainState.new(onEnter, onUpdate, onExit, onDraw)
    return {
        onEnter = onEnter,
        onUpdate = onUpdate,
        onExit = onExit,
        onDraw = onDraw
    }
end

-- ===========================================================================
-- Brain class
-- ===========================================================================

---@class Brain
---@field _states table<string, BrainState> State definitions
---@field _transitions BrainTransition[] List of auto-transitions evaluated each frame (first match wins)
---@field _stack string[] Pushdown stack of active states (top is current). Normally only one state, but push/pop allows temporary suspension.
---@field _timers BrainTimer[] List of active timers for the current state, automatically cancelled on state change
---@field current string|nil Current state name (nil if not started)
---@field previousState string|nil Previous state name (for onEnter/onExit callbacks)
---@field timer number Time spent in current state
---@field memory table Free-form data storage
---@field id number|nil Entity ID (set during update)
---@field scene SceneInstance|nil Reference to current scene (set during update)
local Brain = {}
Brain.__index = Brain

--- Create a new Brain.
--- @param states table<string, BrainState> State definitions
--- @param initialState string? Starting state name (optional, call brain:start() later).
--- @param data table?  Optional arbitrary fields merged into the brain instance.
---@return Brain
function Brain.new(states, initialState, data)
    local self = setmetatable({}, Brain)
    ---@cast self Brain
    self._states = states or {}
    self._transitions = {}
    self._stack = {}
    self._timers = {}
    self.current = nil
    self.previousState = nil
    self.timer = 0
    self.memory = {}
    self.id = nil
    self.scene = nil

    if data then
        for k, v in pairs(data) do self[k] = v end
    end

    if initialState then self:start(initialState) end

    return self
end

-- ---------------------------------------------------------------------------
-- State registration
-- ---------------------------------------------------------------------------

--- Dynamically add or replace a state.
--- @param self Brain
--- @param name string State name
---@param callbacks BrainState State callbacks (onEnter, onUpdate, onExit, onDraw)
function Brain:addState(name, callbacks)
    assert(type(name) == "string", "Brain:addState — name must be a string")
    local cb = callbacks or {}
    self._states[name] = BrainState.new(cb.onEnter, cb.onUpdate, cb.onExit, cb.onDraw)
end

--- Register an automatic conditional transition evaluated each frame before onUpdate.
--- Only the first matching transition fires per frame.
--- @param self Brain
--- @param from string Source state name
--- @param to string Destination state name
--- @param condition function Condition function evaluated each frame. Signature: `fn(brain) -> bool`. If true, the transition triggers.
function Brain:addTransition(from, to, condition)
    table.insert(self._transitions, BrainTransition.new(from, to, condition))
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Set the initial state and call its onEnter.  Safe to call multiple times
--- (resets the stack and restarts the machine).
--- @param self Brain
--- @param name string State name to start
function Brain:start(name)
    assert(self._states[name], "Brain:start — unknown state '" .. tostring(name) .. "'")
    self._stack = { name }
    self._timers = {}
    self.current = name
    self.previousState = nil
    self.timer = 0
    local s = self._states[name]
    if s and s.onEnter then s.onEnter(self, nil) end
end

--- Force an immediate transition to `name`.
--- Calls onExit on the old state and onEnter on the new state.
--- @param self Brain
--- @param name string State name to transition to
function Brain:go(name)
    assert(self._states[name], "Brain:go — unknown state '" .. tostring(name) .. "'")
    if name == self.current then return end
    local prev = self.current
    if prev then
        local old = self._states[prev]
        if old and old.onExit then old.onExit(self, name) end
    end
    if #self._stack == 0 then
        table.insert(self._stack, name)
    else
        self._stack[#self._stack] = name
    end
    self.previousState = prev
    self.current = name
    self.timer = 0
    self._timers = {}
    local s = self._states[name]
    if s and s.onEnter then s.onEnter(self, prev) end
end

--- Push a new state onto the stack (suspends the current one).
--- The suspended state's onExit is called; the new state's onEnter is called.
--- @param self Brain
--- @param name string State name to push and transition to
function Brain:push(name)
    assert(self._states[name], "Brain:push — unknown state '" .. tostring(name) .. "'")
    local prev = self.current
    if prev then
        local old = self._states[prev]
        if old and old.onExit then old.onExit(self, name) end
    end
    table.insert(self._stack, name)
    self.previousState = prev
    self.current = name
    self.timer = 0
    self._timers = {}
    local s = self._states[name]
    if s and s.onEnter then s.onEnter(self, prev) end
end

--- Pop the current state and resume the one below it.
--- Does nothing if the stack has only one entry.
--- @param self Brain
function Brain:pop()
    if #self._stack <= 1 then return end
    local prev = self.current
    local old  = self._states[prev]
    table.remove(self._stack)
    local next = self._stack[#self._stack]
    if old and old.onExit then old.onExit(self, next) end
    self.previousState = prev
    self.current = next
    self.timer = 0
    self._timers = {}
    local s = self._states[next]
    if s and s.onEnter then s.onEnter(self, prev) end
end

-- ---------------------------------------------------------------------------
-- Per-state timers
-- ---------------------------------------------------------------------------

--- Schedule a one-shot callback after `seconds` in the current state.
--- Automatically cancelled on any state change.
--- @param self Brain
--- @param seconds number Seconds to wait before firing
--- @param fn fun(brain: Brain) Callback function to call when the timer fires. Signature: `fn(brain)`
function Brain:after(seconds, fn)
    table.insert(self._timers, BrainTimer.new("once", seconds, fn))
end

--- Schedule a repeating callback every `seconds` while in the current state.
--- Automatically cancelled on any state change.
--- @param self Brain
--- @param seconds number Seconds between each callback
--- @param fn fun(brain: Brain) Callback function to call each time the timer fires. Signature: `fn(brain)`
function Brain:every(seconds, fn)
    table.insert(self._timers, BrainTimer.new("repeat", seconds, fn))
end

--- Internal method to tick timers each frame and call their callbacks when they fire.
--- @param self Brain
--- @param dt number Delta time in seconds
function Brain:_tickTimers(dt)
    local i = 1
    while i <= #self._timers do
        local t = self._timers[i]
        t.remaining = t.remaining - dt
        if t.remaining <= 0 then
            t.fn(self)
            if t.kind == "repeat" then
                t.remaining = t.interval
                i = i + 1
            else
                table.remove(self._timers, i)
            end
        else
            i = i + 1
        end
    end
end

-- ---------------------------------------------------------------------------
-- Per-frame update / draw
-- ---------------------------------------------------------------------------

--- Call every frame.  Evaluates auto-transitions, ticks timers, runs onUpdate.
--- onUpdate may return a state name to trigger a transition.
--- @param self Brain
--- @param dt number  Delta time in seconds
function Brain:update(dt)
    if not self.current then return end

    for _, tr in ipairs(self._transitions) do
        if tr.from == self.current and tr.cond(self) then
            self:go(tr.to)
            break
        end
    end

    self.timer = self.timer + dt
    self:_tickTimers(dt)

    local s = self._states[self.current]
    if s and s.onUpdate then
        local next = s.onUpdate(self, dt)
        if next and next ~= self.current then
            self:go(next)
        end
    end
end

--- Call every frame (after update) to allow the current state to issue draw commands.
--- @param self Brain
function Brain:draw()
    if not self.current then return end
    local s = self._states[self.current]
    if s and s.onDraw then s.onDraw(self) end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Returns true if the current state matches `name`.
--- @param self Brain
--- @param name string State name to check
--- @return boolean state True if current state is `name`
function Brain:is(name)   
    return self.current == name
end

--- Returns true if the previous state matches `name`.
--- @param self Brain
--- @param name string State name to check
--- @return boolean state True if previous state is `name`
function Brain:was(name)
    return self.previousState == name
end

--- Returns seconds spent in the current state.
--- @param self Brain
--- @return number time Seconds spent in the current state
function Brain:timeInState()
    return self.timer

end

--- Returns the push/pop stack depth.
--- @param self Brain
--- @return number depth Depth of the pushdown stack (number of states, including the current one)
function Brain:stackDepth()
    return #self._stack
end

--- Returns the number of registered states.
--- @param self Brain
--- @return number count Number of registered states
function Brain:stateCount()
    local n = 0
    for _ in pairs(self._states) do n = n + 1 end
    return n
end

-- ===========================================================================
-- Perception helpers
-- ===========================================================================

--- Returns true if entity `id` has line-of-sight to `targetId`.
--- @param id number Observer entity ID
--- @param targetId number Target entity ID
---@param scene SceneInstance Active scene
--- @param maxDist number? Optional max distance (world units)
--- @param layerMask number? Optional collision layer bitmask
---@return boolean canSee True if `id` can see `targetId`
function ai.canSee(id, targetId, scene, maxDist, layerMask)
    local pos  = scene.components.pos[id]
    local tPos = scene.components.pos[targetId]
    if not pos or not tPos then return false end

    if maxDist and pos:dist(tPos) > maxDist then return false end

    local hit, _, _, hitId = scene:castRay(pos.x, pos.y, tPos.x, tPos.y, maxDist or 100, id, layerMask)
    return (not hit) or (hitId == targetId)
end

--- Returns true if entity `id` is within `maxDist` of `targetId` (no raycast — cheap).
--- @param id number
--- @param targetId number
---@param scene SceneInstance
--- @param maxDist  number
---@return boolean canHear True if `id` can hear `targetId`
function ai.canHear(id, targetId, scene, maxDist)
    local pos  = scene.components.pos[id]
    local tPos = scene.components.pos[targetId]
    if not pos or not tPos then return false end
    return pos:dist(tPos) <= maxDist
end

--- Returns the entity ID and distance of the nearest entity with `tag`,
--- within `maxDist`, excluding `id` itself.  Returns nil, nil if none found.
--- Assumes scene.components.tags[id] is a set-table: { tagName = true }.
--- @param id number Observer entity ID
--- @param scene SceneInstance Active scene
--- @param tag string?  If nil, searches all entities with a position.
--- @param maxDist number? Search radius (infinite if nil)
---@return number|nil id, number|nil distance
function ai.nearest(id, scene, tag, maxDist)
    local pos = scene.components.pos[id]
    if not pos then return nil, nil end

    local bestId, bestDist = nil, maxDist or math.huge
    local tags      = scene.components.tags
    local positions = scene.components.pos

    for otherId, otherPos in pairs(positions) do
        if otherId ~= id then
            local hasTag = not tag or (tags and tags[otherId] and tags[otherId][tag])
            if hasTag then
                local d = pos:dist(otherPos)
                if d < bestDist then
                    bestDist = d
                    bestId   = otherId
                end
            end
        end
    end

    return bestId, bestDist
end

-- ===========================================================================
-- ECS system
-- ===========================================================================

--- Returns an ECS system function that drives all Brain components.
--- Sets brain.id and brain.scene each frame so callbacks can access them.
---@param scene SceneInstance Active scene (passed to callbacks via brain.scene)
---@return fun(dt:number, ids:number[], components:table)
function ai.system(scene)
    return function(dt, ids, components)
        local brains = components.brain
        if not brains then return end

        for _, id in ipairs(ids) do
            local brain = brains[id]
            if brain then
                brain.id    = id
                brain.scene = scene
                brain:update(dt)
            end
        end
    end
end

-- ===========================================================================
-- Public API
-- ===========================================================================

ai.Brain = Brain
ai.BrainState = BrainState
ai.BrainTimer = BrainTimer
ai.BrainTransition = BrainTransition

return ai