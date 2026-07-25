-- Obsidian Engine core
--- Main entry point that initializes subsystems, manages the main loop, and provides global configuration and utilities.

---@diagnostic disable: undefined-global

--- The Engine module serves as the central hub for the Obsidian game engine, responsible for initializing all core subsystems, managing the main update and render loop, handling scene transitions, and providing global configuration options. It also includes error handling and a debug overlay for performance metrics.
---@class Engine
---@field ecs ECSModule Entity-Component-System for managing game entities and their components
---@field error ErrorModule Global error handling and panic screen
---@field scene SceneModule Scene management system with entity storage, rendering, and update loops
---@field thread ThreadModule Lightweight cooperative threading system for concurrent tasks
---@field buffer BufferInstance Centralized drawing buffer for rendering to the terminal with support for letterboxing and design resolution
---@field renderer BufferInstance Alias for buffer; exposes layers, subpixels and palette control
---@field rgb fun(r:number|string, g:number|nil, b:number|nil):number Registers a reusable logical RGB color
---@field input InputModule Handles keyboard and mouse input, including state tracking and event processing
---@field loader LoaderModule Resource loading system for sprites, audio, and other assets with caching
---@field inputMapper InputMapperModule Configurable input mapping system to abstract raw input into game actions
---@field ui UIModule Simple immediate-mode UI system for buttons, text, and basic layout
---@field tween TweenModule Tweening system for smooth transitions of values over time with various easing functions
---@field timer TimerModule Scheduling system for delayed and repeating callbacks, useful for timed events and animations
---@field camera CameraModule 2D camera system for managing viewports, following entities, and applying transformations
---@field tilemap TilemapModule Support for tile-based maps with rendering, collision, and properties
---@field event EventEmitter Global event bus for decoupled communication between systems and scenes
---@field logger LoggerModule Logging system with multiple levels and optional console output
---@field math MathModule Utility functions for math operations, including vector math and easing functions
---@field physics PhysicsModule Basic physics system with support for static and dynamic bodies, collision detection, and response
---@field audio AudioModule Audio playback system for sound effects and music with support for multiple channels and basic controls
---@field ai AIModule Artificial intelligence system for NPC behavior and decision-making
---@field pathfinding PathfindingModule Pathfinding system for navigating complex environments
---@field serialization SerializationModule System for saving and loading game state
---@field network NetworkModule Networking system for multiplayer and online features
---@field server ServerModule Server management system for hosting multiplayer games
---@field storage StorageModule Local and cloud storage system for game data
---@field db DatabaseModule Database management system for structured data storage
---@field particles ParticlesModule Particle system for visual effects like explosions, smoke, and magic
---@field console ConsoleModule In-game console for debugging, command execution, and log viewing
local Engine = {}

local config = {
    fps = 20,
    frameTime = 1 / 20,
    deltaHistorySize = 10,
}

local state = {
    running = false,
    activeScene = nil,
    manualViewport = false,
    consoleEnabled = true,
    lastDeltaTime = 0,
    deltaHistory = {},
    lastTime = 0,
    currentFPS = 0,
    frameCount = 0,
    fpsTimer = 0,
    transition = nil,
}

local callbacks = {
    update = {},
    render = {},
    event = {},
}

Engine.ecs = require("core.ecs")
Engine.scene = require("core.scene")
Engine.thread = require("core.thread")
local bufferModule = require("core.buffer")
Engine.buffer = bufferModule.new()
Engine.renderer = Engine.buffer
Engine.rgb = bufferModule.rgb
Engine.color = bufferModule.color
Engine.input = require("core.input")
Engine.loader = require("core.loader")
Engine.flimg = Engine.loader.flimg
Engine.inputMapper = require("core.input_mapper")
Engine.ui = require("core.ui")
Engine.tween = require("core.tween")
Engine.timer = require("core.timer")
Engine.camera = require("core.camera")
Engine.tilemap = require("core.tilemap")
Engine.event = require("core.event").new()
Engine.logger = require("core.logger")
Engine.math = require("core.math")
Engine.physics = require("core.physics")
Engine.audio = require("core.audio")
Engine.ai = require("core.ai")
Engine.pathfinding = require("core.pathfinding")
Engine.serialization = require("core.serialization")
Engine.network = require("core.network")
Engine.server = require("core.server")
Engine.storage = require("core.storage")
Engine.db = require("core.db")
Engine.particles = require("core.particles")
Engine.console = require("core.console")
Engine.error = require("core.error")
local debug = require("core.debug")
local errorModule = Engine.error

-- ============================================================================
-- Module Initialization & Wiring
-- ============================================================================

-- Wire buffer into scene before any Scene.new() calls
Engine.scene.setBuffer(Engine.buffer)

--- Create an optional retained render layer. Existing drawing continues to use
--- Engine.buffer's opaque default layer.
---@param name string Unique layer name
---@param zIndex number|nil Lower values render first
---@return table layer
function Engine.addRenderLayer(name, zIndex)
    return Engine.buffer:addLayer(name, zIndex)
end

---@param name string Layer name
---@return table|nil layer
function Engine.getRenderLayer(name)
    return Engine.buffer:getLayer(name)
end

---@param layerOrName table|string
---@return boolean removed
function Engine.removeRenderLayer(layerOrName)
    return Engine.buffer:removeLayer(layerOrName)
end

-- Wire logger → console hook so all log calls reach the console
Engine.logger._consoleHook = function(text, fg)
    Engine.console.addLine(text, fg)
end

-- Wire network and server to emit on Engine.event
local function engineEmit(name, ...)
    Engine.event:emit(name, ...)
    if state.activeScene and state.activeScene.event then
        state.activeScene.event:emit(name, ...)
    end
end
Engine.network._emit = engineEmit
Engine.server._emit = engineEmit

-- Wire thread error handler
Engine.thread.errorHandler = function(err)
    Engine.buffer:restorePalette()
    errorModule.report(err)
    state.running = false
end

local _luaDebug = _G and _G.debug

local function tracebackHandler(e)
    return (_luaDebug and _luaDebug.traceback)
        and _luaDebug.traceback(tostring(e), 2)
        or tostring(e)
end

--- Set custom error handler
---@param fn function Custom error handler function that takes a single string argument (the error message)
function Engine.onError(fn)
    errorModule.handler = fn
end

--- Internal error reporting
---@param msg string Error message
---@param trace string|nil Optional stack trace
function Engine._reportError(msg, trace)
    Engine.buffer:restorePalette()
    errorModule.report(msg, trace)
    state.running = false
end

-- ============================================================================
-- Configuration
-- ============================================================================

--- Set target frames per second
---@param fps number Desired frames per second (e.g. 30)
function Engine.setFPS(fps)
    config.fps = fps
    config.frameTime = 1 / fps
end

--- Get target FPS
---@return number fps returns configured target frames per second
function Engine.getTargetFPS()
    return config.fps
end

--- Get actual measured FPS
---@return number fps returns the actual measured frames per second
function Engine.getFPS()
    return state.currentFPS
end

--- Get averaged delta time in seconds
---@return number deltaTime returns the averaged delta time in seconds
function Engine.getDeltaTime()
    return state.lastDeltaTime
end

-- ============================================================================
-- Callback Registration
-- ============================================================================

--- Register per-frame update callback
---@param fn fun(dt:number) Callback function that receives delta time in seconds as an argument
function Engine.onUpdate(fn)
    table.insert(callbacks.update, fn)
end

--- Register per-frame render callback
---@param fn fun() Callback function that is called every frame for rendering
function Engine.onRender(fn)
    table.insert(callbacks.render, fn)
end

--- Register event callback (receives raw OS event table)
---@param fn fun(event:table) Callback function that receives raw OS event table as an argument
function Engine.onEvent(fn)
    table.insert(callbacks.event, fn)
end

-- ============================================================================
-- Scene Management
-- ============================================================================

--- Set the active scene (calls onUnload/onLoad hooks)
---@param scene SceneInstance Scene instance to set as active
function Engine.setScene(scene)
    if state.activeScene then
        if state.activeScene.event then
            state.activeScene.event:emit("unload")
        end
        if state.activeScene.onUnload then
            state.activeScene:onUnload()
        end
    end

    Engine.tween.stopAll()
    errorModule._shouldStop = false
    state.activeScene = scene
    Engine.scene.activeScene = scene

    if state.activeScene and state.activeScene.onLoad then
        state.activeScene:onLoad()
    end

    if state.activeScene and state.activeScene.event then
        state.activeScene.event:emit("load")
    end

    Engine.logger.info("Scene changed: " .. (state.activeScene.name or "Unnamed"))
end

--- Get the currently active scene
---@return SceneInstance|nil scene the currently active scene instance, or nil if no scene is active
function Engine.getScene()
    return state.activeScene
end

--- Transition to another scene with fade effect
---@param targetScene SceneInstance Scene instance to transition to
---@param duration number|nil Default: 1 second
function Engine.transition(targetScene, duration)
    state.transition = {
        target = targetScene,
        duration = duration or 1,
        elapsed = 0,
        stage = "out"
    }
end

--- Check if a transition is currently active
---@return boolean isTransitioning returns true if a scene transition is currently in progress
function Engine.isTransitioning()
    return state.transition ~= nil
end

-- ============================================================================
-- Viewport & Resolution
-- ============================================================================

--- Set explicit viewport size on the Engine buffer
---@param w number Width of the viewport
---@param h number Height of the viewport
function Engine.setViewport(w, h)
    state.manualViewport = true
    Engine.buffer:setSize(w, h)
    if state.activeScene then 
        state.activeScene._staticDirty = true 
    end
end

--- Set the design resolution used for letterboxing and UI
---@param w number Width of the design resolution
---@param h number Height of the design resolution
function Engine.setDesignResolution(w, h)
    debug.designW, debug.designH = w, h
end

--- Set minimum required resolution
---@param w number Minimum width of the terminal for the engine to run (e.g. 40)
---@param h number Minimum height of the terminal for the engine to run (e.g. 20)
function Engine.setMinResolution(w, h)
    debug.minW = w
    debug.minH = h
end

--- Get currently configured design resolution
---@return number|nil, number|nil resolution width and height of the design resolution, or nil if not set
function Engine.getDesignResolution()
    return debug.designW, debug.designH
end

--- Get viewport offset for letterboxing
---@return number, number offset x and y offset of the viewport for letterboxing based on current terminal size and design resolution
function Engine.getViewportOffset()
    if not debug.designW or not debug.designH then 
        return 0, 0 
    end
    local tw, th = Engine.buffer:getSize()
    return math.floor((tw - debug.designW) / 2), 
           math.floor((th - debug.designH) / 2)
end

--- Convert screen coordinates to viewport coordinates
---@param sx number Screen x coordinate
---@param sy number Screen y coordinate
---@return number, number viewport Viewport x and y coordinates converted from screen coordinates based on current viewport offset
function Engine.screenToViewport(sx, sy)
    local ox, oy = Engine.getViewportOffset()
    return sx - ox, sy - oy
end

-- ============================================================================
-- Debug
-- ============================================================================

--- Enable or disable debug overlay
---@param enabled boolean Whether to enable or disable the debug overlay
---@param alwaysOnTop boolean|nil Optional parameter to keep the debug overlay always on top
function Engine.showDebug(enabled, alwaysOnTop)
    debug.enabled = enabled
    if alwaysOnTop ~= nil then
        debug.alwaysOnTop = alwaysOnTop
    end
end

--- Internal: render engine-level debug overlay (keeps overlay visible even
--- when scenes provide custom draw hooks).
function Engine._renderDebug()
    if not debug.enabled then return end
    local stats = string.format(
        "FPS: %d | Upd: %dms | Draw: %dms",
        debug.fps, debug.updateTime, debug.drawTime
    )
    local staticCount = 0
    if state.activeScene and state.activeScene._staticElements then
        staticCount = #state.activeScene._staticElements
    end
    local entInfo = string.format(
        "Entities: %d (Dyn) | %d (Stat)",
        debug.dynamicCount or 0, staticCount
    )

    Engine.buffer:drawText(1, 1, stats, "0", "f")
    Engine.buffer:drawText(1, 2, entInfo, "7", "f")

    if state.activeScene then
        state.activeScene._rowsToRestore[1] = true
        state.activeScene._rowsToRestore[2] = true
    end

    if debug.showLogs then
        local history = Engine.logger.getHistory()
        for i, entry in ipairs(history) do
            Engine.buffer:drawText(1, 3 + i, entry.text, entry.color, "f")
            if state.activeScene then
                state.activeScene._rowsToRestore[3 + i] = true
            end
        end
    end
end

--- Enable or disable console
---@param enabled boolean Whether to enable or disable the in-game console
function Engine.enableConsole(enabled)
    state.consoleEnabled = enabled
    if not enabled then
        Engine.console.close()
    end
end

--- Check if console is enabled
---@return boolean isEnabled returns true if the in-game console is enabled, false otherwise
function Engine.isConsoleEnabled()
    return state.consoleEnabled
end

-- Convenience method to disable console
function Engine.disableConsole()
    Engine.enableConsole(false)
end

--- Render debug overlay on top of everything when enabled via `debug.alwaysOnTop`.
function Engine._renderDebugTop()
    if not debug.enabled or not debug.alwaysOnTop then return end
    local termW, termH = Engine.buffer:getSize()
    local stats = string.format(
        "FPS: %d | Upd: %dms | Draw: %dms",
        debug.fps, debug.updateTime, debug.drawTime
    )
    local staticCount = 0
    if state.activeScene and state.activeScene._staticElements then
        staticCount = #state.activeScene._staticElements
    end
    local entInfo = string.format(
        "Entities: %d (Dyn) | %d (Stat)",
        debug.dynamicCount or 0, staticCount
    )

    Engine.buffer:drawText(1, 1, stats, "0", "f")
    Engine.buffer:drawText(1, 2, entInfo, "7", "f")

    if state.activeScene then
        state.activeScene._rowsToRestore[1] = true
        state.activeScene._rowsToRestore[2] = true
    end

    if debug.showLogs then
        local history = Engine.logger.getHistory()
        for i, entry in ipairs(history) do
            Engine.buffer:drawText(1, 3 + i, entry.text, entry.color, "f")
            if state.activeScene then
                state.activeScene._rowsToRestore[3 + i] = true
            end
        end
    end
end

-- ============================================================================
-- DeltaTime
-- ============================================================================

local function updateDeltaTime()
    local currentTime = os.epoch("utc") / 1000
    local rawDelta = currentTime - state.lastTime
    state.lastTime = currentTime

    table.insert(state.deltaHistory, rawDelta)
    if #state.deltaHistory > config.deltaHistorySize then
        table.remove(state.deltaHistory, 1)
    end

    local sum = 0
    for _, dt in ipairs(state.deltaHistory) do
        sum = sum + dt
    end
    state.lastDeltaTime = sum / #state.deltaHistory
end

-- ============================================================================
-- Transition Rendering
-- ============================================================================

local function renderTransition()
    if not state.transition then return end

    state.transition.elapsed = state.transition.elapsed + state.lastDeltaTime
    local half = state.transition.duration / 2
    local progress = 0

    if state.transition.stage == "out" then
        progress = math.min(1, state.transition.elapsed / half)
        if state.transition.elapsed >= half then
            Engine.setScene(state.transition.target)
            state.transition.stage = "in"
        end
    else
        progress = math.max(0, 1 - (state.transition.elapsed - half) / half)
        if state.transition.elapsed >= state.transition.duration then
            state.transition = nil
            return
        end
    end

    local tw, th = Engine.buffer:getSize()
    local curtainH = math.floor((th / 2) * progress)
    if curtainH > 0 then
        Engine.buffer:drawRect(1, 1, tw, curtainH, " ", "0", "f")
        Engine.buffer:drawRect(1, th - curtainH + 1, tw, curtainH, " ", "0", "f")
    end
end

local function updateFrame()
    local frameStart = os.epoch("utc")

    local curW, curH = term.getSize()
    if debug.minW and debug.minH and (curW < debug.minW or curH < debug.minH) then
        debug.unsupportedResolution = true
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.write("Terminal size not supported.")
        term.setCursorPos(1, 2)
        term.write(string.format("Required: %dx%d | Current: %dx%d", 
            debug.minW, debug.minH, curW, curH))
        os.sleep(0.2)
        state.lastTime = os.epoch("utc") / 1000
        return
    end
    debug.unsupportedResolution = false

    updateDeltaTime()

    Engine.tween.update(state.lastDeltaTime)
    Engine.timer.update(state.lastDeltaTime)

    if state.activeScene then 
        state.activeScene:update(state.lastDeltaTime) 
    end

    if state.activeScene then
        local ok, list = pcall(function() return state.activeScene:select("pos", "sprite") end)
        if ok and list then
            debug.dynamicCount = #list
        else
            debug.dynamicCount = 0
        end
    else
        debug.dynamicCount = 0
    end

    if errorModule._shouldStop then
        state.running = false
        return
    end

    for _, fn in ipairs(callbacks.update) do
        fn(state.lastDeltaTime)
    end

    debug.updateTime = os.epoch("utc") - frameStart
    Engine.input._endFrame()

    local drawStart = os.epoch("utc")

    if state.transition and state.activeScene then 
        state.activeScene._staticDirty = true 
    end

    if state.activeScene then 
        state.activeScene:draw() 
    end

    for _, fn in ipairs(callbacks.render) do
        fn()
    end

    renderTransition()

    if state.consoleEnabled then 
        Engine.console.draw(Engine.buffer)
    end

    Engine._renderDebugTop()

    Engine.buffer:present()
    debug.drawTime = os.epoch("utc") - drawStart

    state.frameCount = state.frameCount + 1
    local now = os.clock()
    if now - state.fpsTimer >= 1 then
        state.currentFPS = state.frameCount
        debug.fps = state.frameCount
        state.frameCount = 0
        state.fpsTimer = now
    end

    local workTime = (os.epoch("utc") - frameStart) / 1000
    local sleepTime = math.max(0, config.frameTime - workTime)

    local t = os.startTimer(sleepTime)
    repeat
        local _, tid = os.pullEvent("timer")
    until tid == t
end

-- ============================================================================
-- Event Loop
-- ============================================================================

local function handleEvent(event)
    local consumed = false

    if state.activeScene and state.activeScene.ui then
        local ox, oy = Engine.getViewportOffset()
        consumed = state.activeScene.ui:handleEvent(event, ox, oy)
    end

    local consoleConsumed = false
    if state.consoleEnabled then
        local wasOpen = Engine.console.isOpen()
        consoleConsumed = Engine.console.handleEvent(event, consumed)

        if wasOpen and not Engine.console.isOpen() and state.activeScene then
            state.activeScene._staticDirty = true
        end
    end

    if consumed then
        if event[1] == "mouse_click" then 
            Engine.input.clear() 
        end
    elseif not consoleConsumed then
        Engine.input.processEvent(table.unpack(event))
        Engine.network.processEvent(event)
        Engine.server.processEvent(event)

        Engine.event:emit(event[1], table.unpack(event, 2))
        if state.activeScene and state.activeScene.event then
            state.activeScene.event:emit(event[1], table.unpack(event, 2))
        end

        if state.activeScene and state.activeScene.onEvent then
            local ok, err = xpcall(state.activeScene.onEvent, tracebackHandler, event)
            if not ok then
                Engine._reportError(err)
            end
        end
    end

    if event[1] == "term_resize" and not state.manualViewport then
        local nw, nh = term.getSize()
        Engine.buffer:setSize(nw, nh)
        if state.activeScene then 
            state.activeScene._staticDirty = true 
        end
    end

    for _, fn in ipairs(callbacks.event) do
        fn(event)
    end

    Engine.thread.update(table.unpack(event))
end

-- ============================================================================
-- Main Loop
-- ============================================================================

--- Start the main engine loop (blocking)
function Engine.start()
    state.running = true
    state.lastTime = os.epoch("utc") / 1000
    state.fpsTimer = os.clock()

    Engine.audio.refresh()

    Engine.console.setEnv(setmetatable({
        Engine = Engine,
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[i] = tostring(select(i, ...))
            end
            Engine.console.print(table.concat(parts, "\t"))
        end,
    }, { __index = _G }))

    Engine.thread.start(function()
        while state.running do
            updateFrame()
        end
    end)

    while state.running do
        local event = { os.pullEvent() }
        handleEvent(event)
    end

    Engine.buffer:restorePalette()
end

--- Stop the engine loop
function Engine.stop()
    state.running = false
    Engine.buffer:restorePalette()
end

--- Check if engine is running
---@return boolean isRunning returns true if the engine loop is currently running, false otherwise
function Engine.isRunning()
    return state.running
end

return Engine
