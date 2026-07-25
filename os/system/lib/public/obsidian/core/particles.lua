--- Obsidian Particle System
--- Provides a simple particle emitter system for visual effects. Emitters can be configured with various parameters and will spawn particles that move, update, and expire over time.
--- Particles can optionally bounce off solid tiles, be affected by gravity, and have their color

---@diagnostic disable: undefined-global

local mathUtils = require("core.math")
local physics = require("core.physics")
local logger = require("core.logger")
local loader = require("core.loader")

--- The particle emitter component defines how particles are spawned and their initial properties.
---@class ParticleEmitter
---@field active boolean Whether the emitter is active and should spawn particles
---@field spawnRate number Number of particles to spawn per second
---@field accumulator number Internal timer to track spawning intervals
---@field angle number Base angle (in degrees) for particle emission
---@field spread number Angle spread (in degrees) for randomizing particle emission direction
---@field speedMin number Minimum initial speed of particles
---@field speedMax number Maximum initial speed of particles
---@field lifeMin number Minimum lifetime of particles in seconds
---@field lifeMax number Maximum lifetime of particles in seconds
---@field sprite any|nil Optional sprite to use for particles
---@field colors table|nil Optional list of colors for particles to cycle through over their lifetime
---@field chars table|nil Optional list of characters for particles to cycle through over their lifetime
---@field bgColors table|nil Optional list of background blit chars for particles over their lifetime
---@field z number Render layer for particles (default 1)
---@field bounce boolean Whether particles should bounce off solid tiles
---@field gravityScale number Multiplier for how much gravity affects the particle (0 for no gravity)
---@field drag number Linear drag coefficient to slow down particles over time (0 for no drag)

--- The main particles module with functions to create emitters and systems.
---@class ParticlesModule
local particles = {}

--- Create a particle emitter instance from a config table.
---@param config table Configuration parameters for the emitter
---@return ParticleEmitter emitter The created emitter instance
function particles.createEmitter(config)
    return {
        active = config.active ~= false,
        spawnRate = math.max(0.001, config.spawnRate or 10),
        accumulator = 0,
        angle = config.angle or 0,
        spread = config.spread or 360,
        speedMin = config.speedMin or 5,
        speedMax = config.speedMax or 10,
        lifeMin = config.lifeMin or 1,
        lifeMax = config.lifeMax or 2,
        sprite = config.sprite,
        colors = config.colors,
        chars = config.chars,
        bgColors = config.bgColors,
        z = config.z or 1,
        bounce = config.bounce or false,
        gravityScale = config.gravityScale or 0,
        drag = config.drag or 0
    }
end

--- Load an emitter config from a file and create an emitter instance.
---@param path string Path to the emitter config file
---@return ParticleEmitter|nil emitter The created emitter instance, or nil if loading failed
function particles.load(path)
    local config = loader.loadEmitter(path)
    if not config then
        logger.error("[particles] Failed to load emitter: " .. tostring(path))
        return nil
    end
    return particles.createEmitter(config)
end

--- Create an emitter system for the ECS. This system will spawn particles according to the emitter's configuration.
---@param scene SceneInstance The scene to which the system will be added
---@return fun(dt:number, ids:table, components:table) fn The emitter system function to be called each update
function particles.emitterSystem(scene)
    return function(dt, ids, components)
        for _, id in ipairs(ids) do
            local emitter = components.emitter[id]
            local pos = components.pos[id]

            if emitter.active and pos then
                emitter.accumulator = emitter.accumulator + dt
                local waitTime = 1 / emitter.spawnRate

                while emitter.accumulator >= waitTime do
                    emitter.accumulator = emitter.accumulator - waitTime

                    local p = scene:spawn()
                    local angle = math.rad(emitter.angle + (math.random() - 0.5) * emitter.spread)
                    local speed = emitter.speedMin + math.random() * (emitter.speedMax - emitter.speedMin)
                    local life = emitter.lifeMin + math.random() * (emitter.lifeMax - emitter.lifeMin)

                    scene:attach(p, "pos", mathUtils.vec2(pos.x, pos.y))
                    scene:attach(p, "velocity", mathUtils.vec2(math.cos(angle) * speed, math.sin(angle) * speed))
                    scene:attach(p, "lifetime", life)
                    scene:attach(p, "maxLifetime", life)
                    scene:attach(p, "isParticle", true)
                    scene:attach(p, "z", emitter.z)
                    if emitter.bounce then scene:attach(p, "particleBounce", true) end
                    if emitter.gravityScale ~= 0 then scene:attach(p, "particleGravity", emitter.gravityScale) end
                    if emitter.drag > 0 then scene:attach(p, "particleDrag", emitter.drag) end

                    if emitter.sprite then scene:attach(p, "sprite", emitter.sprite) end
                    if emitter.colors then scene:attach(p, "particleColors", emitter.colors) end
                    if emitter.chars then scene:attach(p, "particleChars", emitter.chars) end
                    if emitter.bgColors then scene:attach(p, "particleBgColors", emitter.bgColors) end
                end
            end
        end
    end
end

--- Create a motion system for particles. This system applies velocity to position, gravity, drag, and optional bouncing.
---@param scene SceneInstance The scene to which the system will be added
---@return fun(dt:number, ids:table, components:table) fn The motion system function to be called each update
function particles.motionSystem(scene)
    return function(dt, ids, components)
        for _, id in ipairs(ids) do
            local pos = components.pos[id]
            local vel = components.velocity[id]
            local hasBounce = components.particleBounce and components.particleBounce[id]

            local drag = components.particleDrag and components.particleDrag[id]
            if drag then
                mathUtils.applyDamping(vel, drag, dt)
            end

            local gScale = components.particleGravity and components.particleGravity[id]
            if gScale then
                vel.y = vel.y + physics.GRAVITY_VECTOR.y * gScale * dt
            end

            if hasBounce then
                local oldX = pos.x
                pos.x = pos.x + vel.x * dt
                local hitX, _, slopeYX = scene:isAreaBlocked(pos.x, pos.y, 1, 1, id)
                if hitX and not slopeYX then
                    pos.x = oldX
                    vel.x = -vel.x * 0.5
                end

                local oldY = pos.y
                pos.y = pos.y + vel.y * dt
                local hitY, _, slopeY = scene:isAreaBlocked(pos.x, pos.y, 1, 1, id)
                if hitY then
                    if slopeY then pos.y = slopeY - 1 else pos.y = oldY end
                    vel.y = -vel.y * 0.5
                end
            else
                pos.x = pos.x + vel.x * dt
                pos.y = pos.y + vel.y * dt
            end
        end
    end
end

--- Create an update system for particles (color/char progress).
---@param scene SceneInstance The scene to which the system will be added
---@return fun(dt:number, ids:table, components:table) fn The update system function to be called each update
function particles.updateSystem(scene)
    return function(dt, ids, components)
        for _, id in ipairs(ids) do
            local life = components.lifetime[id]
            local maxLife = components.maxLifetime[id]
            local colors = components.particleColors and components.particleColors[id]
            local chars = components.particleChars and components.particleChars[id]

            local progress = math.max(0, math.min(1, 1 - (life / (maxLife > 0 and maxLife or 1))))

            if colors then
                local idx = math.max(1, math.min(#colors, math.ceil(progress * #colors)))
                scene:attach(id, "colorOverride", colors[idx])
            end

            if chars then
                local idx = math.max(1, math.min(#chars, math.ceil(progress * #chars)))
                scene:attach(id, "charOverride", chars[idx])
            end

            local bgColors = components.particleBgColors and components.particleBgColors[id]
            if bgColors then
                local idx = math.max(1, math.min(#bgColors, math.ceil(progress * #bgColors)))
                scene:attach(id, "bgOverride", bgColors[idx])
            end
        end
    end
end

--- Create a cleanup system that destroys expired particles.
---@param scene SceneInstance The scene to which the system will be added
---@return fun(dt:number, ids:table, components:table) fn The cleanup system function to be called each update
function particles.cleanupSystem(scene)
    return function(dt, ids, components)
        for _, id in ipairs(ids) do
            components.lifetime[id] = components.lifetime[id] - dt
            if components.lifetime[id] <= 0 then
                scene:despawn(id)
            end
        end
    end
end

--- Register particle systems on the given scene.
---@param scene SceneInstance The scene to which the systems will be added
function particles.registerAll(scene)
    scene:addSystem({"emitter", "pos"}, particles.emitterSystem(scene))
    scene:addSystem({"pos", "velocity", "isParticle"}, particles.motionSystem(scene))
    scene:addSystem({"lifetime", "maxLifetime", "isParticle"}, particles.updateSystem(scene))
    scene:addSystem({"lifetime", "isParticle"},  particles.cleanupSystem(scene))
end

return particles