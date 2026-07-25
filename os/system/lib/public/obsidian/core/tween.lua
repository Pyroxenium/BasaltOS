--- Obsidian Tweening Module
--- Provides functions to animate properties of tables over time with various easing functions. Useful for smooth transitions, animations, and timed effects. Tweens can be created, paused, resumed, cancelled, and completed via their handles.

---@diagnostic disable: undefined-global

local logger = require("core.logger")

---@alias TweenHandle table Opaque handle for tween control
---@alias EasingFunction fun(t:number):number Easing function that takes normalized time (0.0 - 1.0) and returns eased value (0.0 - 1.0)

--- Tween entry structure
---@class TweenEntry
---@field handle TweenHandle Opaque handle for control
---@field target table Object being tweened
---@field duration number Tween duration in seconds
---@field elapsed number Time elapsed since tween started
---@field startValues table Starting property values {key = value}
---@field endValues table Target property values {key = value}
---@field easing EasingFunction Easing function to apply
---@field onComplete function|nil Optional callback to call when tween completes
---@field delay number Optional delay before tween starts
---@field loop boolean Whether to loop the tween indefinitely
---@field pingpong boolean Whether to reverse direction on each loop
---@field paused boolean Whether the tween is currently paused
---@field _isReversing boolean Internal flag for pingpong direction

--- This module provides functions to animate properties of tables over time with various easing functions. Useful for smooth transitions, animations, and timed effects. Tweens can be created, paused, resumed, cancelled, and completed via their handles.
---@class TweenModule
---@field _active TweenEntry[] List of active tweens
---@field easing table<string, EasingFunction> Predefined easing functions
local TweenModule = {
    _active = {},
    easing = {}
}

-- ============================================================================
-- Easing Functions
-- ============================================================================

--- Linear easing (no easing, constant speed)
TweenModule.easing.linear = function(t) return t end

--- Quadratic easing (accelerating from zero velocity)
TweenModule.easing.quadIn = function(t)
    return t * t
end

--- Quadratic easing (accelerating until halfway, then decelerating)
TweenModule.easing.quadInOut = function(t)
    return t < 0.5 and 2 * t * t or -1 + (4 - 2 * t) * t
end

--- Sine easing (accelerating from zero velocity)
TweenModule.easing.sineIn = function(t)
    return 1 - math.cos((t * math.pi) / 2)
end

--- Sine easing (decelerating to zero velocity)
TweenModule.easing.sineOut = function(t)
    return math.sin((t * math.pi) / 2)
end

--- Sine easing (accelerating until halfway, then decelerating)
TweenModule.easing.sineInOut = function(t)
    return -(math.cos(math.pi * t) - 1) / 2
end

--- Cubic easing (accelerating from zero velocity)
TweenModule.easing.cubicIn = function(t)
    return t * t * t
end

--- Cubic easing (decelerating to zero velocity)
TweenModule.easing.cubicOut = function(t)
    local u = t - 1
    return u * u * u + 1
end

--- Cubic easing (accelerating until halfway, then decelerating)
TweenModule.easing.cubicInOut = function(t)
    return t < 0.5 and 4 * t * t * t or 1 - (-2 * t + 2) ^ 3 / 2
end

-- Exponential easing (accelerating from zero velocity)
TweenModule.easing.expoIn = function(t)
    return t == 0 and 0 or 2 ^ (10 * t - 10)
end

--- Exponential easing (decelerating to zero velocity)
TweenModule.easing.expoOut = function(t)
    return t == 1 and 1 or 1 - 2 ^ (-10 * t)
end

--- Exponential easing (accelerating until halfway, then decelerating)
TweenModule.easing.expoInOut = function(t)
    if t == 0 then return 0 end
    if t == 1 then return 1 end
    return t < 0.5 and 2 ^ (20 * t - 10) / 2 or (2 - 2 ^ (-20 * t + 10)) / 2
end

-- Back easing (overshooting cubic easing)
TweenModule.easing.backIn = function(t)
    local c1 = 1.70158
    local c3 = c1 + 1
    return c3 * t * t * t - c1 * t * t
end

--- Back easing (overshooting cubic easing)
TweenModule.easing.backOut = function(t)
    local c1 = 1.70158
    local c3 = c1 + 1
    return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
end

--- Back easing (overshooting cubic easing)
TweenModule.easing.backInOut = function(t)
    local c1 = 1.70158
    local c2 = c1 * 1.525
    return t < 0.5
        and (2 * t) ^ 2 * ((c2 + 1) * 2 * t - c2) / 2
        or ((2 * t - 2) ^ 2 * ((c2 + 1) * (t * 2 - 2) + c2) + 2) / 2
end

-- Elastic easing (exponentially decaying sine wave)
TweenModule.easing.elasticIn = function(t)
    local c4 = (2 * math.pi) / 3
    if t == 0 then return 0 end
    if t == 1 then return 1 end
    return -(2 ^ (10 * t - 10)) * math.sin((t * 10 - 10.75) * c4)
end

--- Elastic easing (exponentially decaying sine wave)
TweenModule.easing.elasticOut = function(t)
    local c4 = (2 * math.pi) / 3
    if t == 0 then return 0 end
    if t == 1 then return 1 end
    return 2 ^ (-10 * t) * math.sin((t * 10 - 0.75) * c4) + 1
end

--- Elastic easing (exponentially decaying sine wave)
TweenModule.easing.elasticInOut = function(t)
    local c5 = (2 * math.pi) / 4.5
    if t == 0 then return 0 end
    if t == 1 then return 1 end
    return t < 0.5
        and -(2 ^ (20 * t - 10) * math.sin((20 * t - 11.125) * c5)) / 2
        or (2 ^ (-20 * t + 10) * math.sin((20 * t - 11.125) * c5)) / 2 + 1
end

-- Bounce easing (bounce out)
TweenModule.easing.bounceOut = function(t)
    local n1, d1 = 7.5625, 2.75
    if t < 1 / d1 then
        return n1 * t * t
    elseif t < 2 / d1 then
        t = t - 1.5 / d1
        return n1 * t * t + 0.75
    elseif t < 2.5 / d1 then
        t = t - 2.25 / d1
        return n1 * t * t + 0.9375
    else
        t = t - 2.625 / d1
        return n1 * t * t + 0.984375
    end
end

--- Bounce easing (bounce in)
TweenModule.easing.bounceIn = function(t)
    return 1 - TweenModule.easing.bounceOut(1 - t)
end

--- Bounce easing (bounce in/out)
TweenModule.easing.bounceInOut = function(t)
    return t < 0.5
        and (1 - TweenModule.easing.bounceOut(1 - 2 * t)) / 2
        or (1 + TweenModule.easing.bounceOut(2 * t - 1)) / 2
end

local function findTweenByHandle(handle)
    for _, tween in ipairs(TweenModule._active) do
        if tween.handle == handle then
            return tween
        end
    end
    return nil
end

local handle_methods = {}

---- Pause a tween by handle
---@param self TweenHandle Opaque handle returned by tween functions
---@return boolean isPaused True if tween was found and paused, false if not found
function handle_methods:pause()
    return TweenModule.pause(self)
end

--- Resume a paused tween
---@param self TweenHandle Opaque handle returned by tween functions
---@return boolean isPaused True if tween was found and resumed, false if not found
function handle_methods:resume()
    return TweenModule.resume(self)
end

--- Cancel a tween by handle (onComplete not called)
---@param self TweenHandle Opaque handle returned by tween functions
---@return boolean isCancelled True if tween was found and cancelled, false if not found
function handle_methods:cancel()
    return TweenModule.cancel(self)
end

--- Complete a tween immediately (jumps to end, calls onComplete)
---@param self TweenHandle Opaque handle returned by tween functions
---@return boolean isCompleted True if tween was found and completed, false if not found
function handle_methods:complete()
    return TweenModule.complete(self)
end

--- Check if a tween is active
---@param self TweenHandle Opaque handle returned by tween functions
---@return boolean isActive True if tween is active, false if not found
function handle_methods:isActive()
    return TweenModule.isActive(self)
end

--- Check if a tween is paused
---@param self TweenHandle Opaque handle returned by tween functions
---@return boolean isPaused True if tween is paused, false if not found or not paused
function handle_methods:isPaused()
    return TweenModule.isPaused(self)
end

--- Get tween progress (0.0 - 1.0)
---@param self TweenHandle Opaque handle returned by tween functions
---@return number|nil Progress value between 0.0 and 1.0, or nil if tween not found
function handle_methods:getProgress()
    return TweenModule.getProgress(self)
end

--- Seek a tween to a given normalized progress (0.0 - 1.0) without completing
---@param self TweenHandle Opaque handle returned by tween functions
---@param progress number Normalized progress to seek to (0.0 - 1.0)
---@return boolean found True if tween was found and seeked, false if not found or invalid progress
function handle_methods:seek(progress)
    if type(progress) ~= "number" then return false end
    local tween = findTweenByHandle(self)
    if not tween then return false end
    progress = math.max(0, math.min(1, progress))
    tween.elapsed = tween.delay + progress * tween.duration
    local effectiveElapsed = math.max(0, tween.elapsed - tween.delay)
    local p = math.min(1, effectiveElapsed / tween.duration)
    local alpha = tween.easing(p)
    for key, endValue in pairs(tween.endValues) do
        if tween.startValues[key] then
            tween.target[key] = tween.startValues[key] + (endValue - tween.startValues[key]) * alpha
        end
    end
    return true
end

local function createHandle()
    local h = {}
    setmetatable(h, { __index = handle_methods })
    return h
end

-- ============================================================================
-- Tween Creation
-- ============================================================================

--- Animate properties of a target object
---@param target table Object to animate
---@param duration number Animation duration in seconds
---@param properties table Target property values {key = value}
---@param easingFunc function|table|nil Easing function or options table
---@param onComplete function|nil Completion callback (if easingFunc is function)
---@return TweenHandle handle Opaque handle for control
function TweenModule.to(target, duration, properties, easingFunc, onComplete)
    if type(target) ~= "table" then
        logger.error("Tween: Target must be a table")
        return createHandle()
    end
    if type(properties) ~= "table" then
        logger.error("Tween: Properties must be a table")
        return createHandle()
    end

    local options = type(easingFunc) == "table" and easingFunc or {
        easing = easingFunc,
        onComplete = onComplete
    }

    local handle = createHandle()

    local startValues = {}
    for key, endValue in pairs(properties) do
        if type(target[key]) == "number" then
            startValues[key] = target[key]
        else
            logger.warn("Tween: Property '" .. tostring(key) .. "' is not a number, skipping")
        end
    end

    local tween = {
        handle = handle,
        target = target,
        duration = math.max(0.001, duration),
        elapsed = 0,
        startValues = startValues,
        endValues = properties,
        easing = options.easing or TweenModule.easing.linear,
        onComplete = options.onComplete,
        delay = options.delay or 0,
        loop = options.loop or false,
        pingpong = options.pingpong or false,
        paused = false,
        _isReversing = false,
    }

    table.insert(TweenModule._active, tween)
    return handle
end

--- Animate from specific values to current values
---@param target table Object to animate
---@param duration number Animation duration in seconds
---@param fromProperties table Start property values {key = value}
---@param options table|nil Options {easing, onComplete, delay, loop, pingpong}
---@return TweenHandle handle Opaque handle for control
function TweenModule.from(target, duration, fromProperties, options)
    options = options or {}

    local currentValues = {}
    for key, startValue in pairs(fromProperties) do
        currentValues[key] = target[key]
        target[key] = startValue
    end

    return TweenModule.to(target, duration, currentValues, options)
end

-- ============================================================================
-- Tween Control
-- ============================================================================

--- Pause a tween by handle
---@param handle TweenHandle Opaque handle returned by tween functions
---@return boolean isPaused True if tween was found and paused, false if not found
function TweenModule.pause(handle)
    for _, tween in ipairs(TweenModule._active) do
        if tween.handle == handle then
            tween.paused = true
            return true
        end
    end
    return false
end

--- Resume a paused tween
---@param handle TweenHandle Opaque handle returned by tween functions
---@return boolean isResumed True if tween was found and resumed, false if not found
function TweenModule.resume(handle)
    for _, tween in ipairs(TweenModule._active) do
        if tween.handle == handle then
            tween.paused = false
            return true
        end
    end
    return false
end

--- Cancel a tween by handle (onComplete not called)
---@param handle TweenHandle Opaque handle returned by tween functions
---@return boolean isCancelled True if tween was found and cancelled, false if not found
function TweenModule.cancel(handle)
    for i = #TweenModule._active, 1, -1 do
        if TweenModule._active[i].handle == handle then
            table.remove(TweenModule._active, i)
            return true
        end
    end
    return false
end

--- Stop all tweens targeting a specific object (onComplete not called)
---@param target table Object whose tweens should be stopped
---@return number removed Count of tweens that were removed
function TweenModule.stop(target)
    local removed = 0
    for i = #TweenModule._active, 1, -1 do
        if TweenModule._active[i].target == target then
            table.remove(TweenModule._active, i)
            removed = removed + 1
        end
    end
    return removed
end

--- Stop all active tweens (onComplete not called)
function TweenModule.stopAll()
    TweenModule._active = {}
end

--- Complete a tween immediately (jumps to end, calls onComplete)
---@param handle TweenHandle Opaque handle returned by tween functions
---@return boolean isCompleted True if tween was found and completed, false if not found
function TweenModule.complete(handle)
    for i = #TweenModule._active, 1, -1 do
        local tween = TweenModule._active[i]
        if tween.handle == handle then
            for key, endValue in pairs(tween.endValues) do
                tween.target[key] = endValue
            end

            local callback = tween.onComplete
            table.remove(TweenModule._active, i)
            if callback then
                callback()
            end
            return true
        end
    end
    return false
end

--- Seek a tween to a given normalized progress (0.0 - 1.0) without completing
---@param handle TweenHandle Opaque handle returned by tween functions
---@param progress number Normalized progress to seek to (0.0 - 1.0)
---@return boolean found True if tween was found and seeked, false if not found or invalid progress
function TweenModule.seek(handle, progress)
    local tween = findTweenByHandle(handle)
    if not tween or type(progress) ~= "number" then return false end
    progress = math.max(0, math.min(1, progress))
    tween.elapsed = tween.delay + progress * tween.duration 
    local effectiveElapsed = math.max(0, tween.elapsed - tween.delay)
    local p = math.min(1, effectiveElapsed / tween.duration)
    local alpha = tween.easing(p)
    for key, endValue in pairs(tween.endValues) do
        if tween.startValues[key] then
            tween.target[key] = tween.startValues[key] + (endValue - tween.startValues[key]) * alpha
        end
    end
    return true
end

--- Return a list of tween handles currently targeting `target`
---@param target table Object to check for active tweens
---@return TweenHandle[] handles List of tween handles targeting the specified object
function TweenModule.getTweensForTarget(target)
    local out = {}
    for _, tween in ipairs(TweenModule._active) do
        if tween.target == target then
            table.insert(out, tween.handle)
        end
    end
    return out
end

-- ============================================================================
-- Tween Queries
-- ============================================================================

--- Get number of active tweens
---@return number
function TweenModule.count()
    return #TweenModule._active
end

--- Check if a tween is active
---@param handle TweenHandle Opaque handle returned by tween functions
---@return boolean isActive True if tween is active, false if not found
function TweenModule.isActive(handle)
    for _, tween in ipairs(TweenModule._active) do
        if tween.handle == handle then
            return true
        end
    end
    return false
end

--- Check if a tween is paused
---@param handle TweenHandle Opaque handle returned by tween functions
---@return boolean isPaused True if tween is paused, false if not found
function TweenModule.isPaused(handle)
    for _, tween in ipairs(TweenModule._active) do
        if tween.handle == handle then
            return tween.paused
        end
    end
    return false
end

--- Get tween progress (0.0 - 1.0)
---@param handle TweenHandle Opaque handle returned by tween functions
---@return number|nil Progress value between 0.0 and 1.0, or nil if tween not found
function TweenModule.getProgress(handle)
    for _, tween in ipairs(TweenModule._active) do
        if tween.handle == handle then
            local effectiveElapsed = math.max(0, tween.elapsed - tween.delay)
            return math.min(1, effectiveElapsed / tween.duration)
        end
    end
    return nil
end

-- ============================================================================
-- Update Loop
-- ============================================================================

--- Update all tweens (called by engine each frame)
---@param dt number Delta time in seconds
function TweenModule.update(dt)
    for i = #TweenModule._active, 1, -1 do
        local tween = TweenModule._active[i]
        tween.elapsed = tween.elapsed + dt
        if not tween.paused then
            local effectiveElapsed = tween.elapsed - tween.delay
            if effectiveElapsed >= 0 then
                local progress = math.min(1, effectiveElapsed / tween.duration)
                local alpha = tween.easing(progress)

                for key, endValue in pairs(tween.endValues) do
                    if tween.startValues[key] then
                        tween.target[key] = tween.startValues[key] +
                                           (endValue - tween.startValues[key]) * alpha
                    end
                end

                if progress >= 1 then
                    if tween.pingpong then
                        for key, endValue in pairs(tween.endValues) do
                            local startValue = tween.startValues[key]
                            tween.startValues[key] = endValue
                            tween.endValues[key] = startValue
                        end
                        tween.elapsed = tween.delay
                        tween._isReversing = not tween._isReversing
                    elseif tween.loop then
                        tween.elapsed = tween.delay
                    else
                        local callback = tween.onComplete
                        table.remove(TweenModule._active, i)
                        if callback then
                            callback()
                        end
                    end
                end
            end
        end
    end
end

--- Get debug info for all active tweens
---@return table[] info List of tween info tables with target, progress, duration, paused state, loop, and pingpong
function TweenModule.getDebugInfo()
    local info = {}
    for _, tween in ipairs(TweenModule._active) do
        local effectiveElapsed = math.max(0, tween.elapsed - tween.delay)
        table.insert(info, {
            target = tostring(tween.target),
            progress = math.min(1, effectiveElapsed / tween.duration),
            duration = tween.duration,
            paused = tween.paused,
            loop = tween.loop,
            pingpong = tween.pingpong,
        })
    end
    return info
end

return TweenModule