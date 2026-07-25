--- Obsidian Engine Physics Module
-- Provides basic 2D physics body definitions, impulse resolution, AABB collision detection, and an ECS system for physics integration.

---@diagnostic disable: undefined-global
local M = require("core.math")

--- This is a physics body configuration table.  It does not store state like position or velocity;
---@class PhysicsBody
---@field mass number The mass of the object (0 or negative = infinite mass/unmovable)
---@field bounciness number Elasticity from 0 (no bounce) to 1 (perfect reflection)
---@field friction number Friction coefficient (0 to 1, exponential decay)
---@field gravityScale number Multiplier for the global gravity
---@field isKinematic boolean If true, the object is moved only by script, not by physics forces
---@field useGravity boolean Whether gravity should be applied to this body

--- This is the main physics module with utility functions and an ECS system for integration.
---@class PhysicsModule
---@field GRAVITY_VECTOR Vec2 Default gravity vector (world units/s²). Change via Physics.setGravity().
local Physics = {}
Physics.GRAVITY_VECTOR = M.vec2(0, 50)

--- Returns a copy of the current gravity vector (immutable-safe).
---@return Vec2 Current gravity vector
function Physics.gravity()
    return M.vec2(Physics.GRAVITY_VECTOR.x, Physics.GRAVITY_VECTOR.y)
end

--- Override the global gravity.
---@param x number Gravity X component (world units/s²)
---@param y number Gravity Y component (world units/s²)
function Physics.setGravity(x, y)
    Physics.GRAVITY_VECTOR.x = x
    Physics.GRAVITY_VECTOR.y = y
end

-- ===========================================================================
-- Body factory
-- ===========================================================================

--- Create a physics body configuration table.
---@param config? {mass:number, bounciness:number, friction:number, gravityScale:number, isKinematic:boolean, useGravity:boolean} Optional configuration parameters (see PhysicsBody fields)
---@return PhysicsBody body New physics body configuration
function Physics.createBody(config)
    config = config or {}
    return {
        mass = config.mass or 1.0,
        bounciness = config.bounciness or 0.0,
        friction = config.friction or 0.15,
        gravityScale = config.gravityScale or 1.0,
        isKinematic = config.isKinematic or false,
        useGravity = config.useGravity ~= false,
    }
end

-- ===========================================================================
-- Impulse helpers
-- ===========================================================================

--- Reflect `velocity` off a surface described by `normal`.
--- Mutates `velocity` in place and returns it.
---@param velocity Vec2 Incoming velocity vector
---@param normal Vec2 Surface normal (unit vector)
---@param bounciness? number 0 = no bounce, 1 = perfect elastic
--- @return Vec2 vector Resulting velocity vector after bounce
function Physics.resolveBounce(velocity, normal, bounciness)
    bounciness = bounciness or 1.0
    local dot = velocity:dot(normal)
    if dot < 0 then
        velocity:add(normal * (-(1 + bounciness) * dot))
    end
    return velocity
end

--- Resolve an impulse-based collision between two dynamic bodies.
--- Mutates vel1 and vel2 in place.
---@param body1 PhysicsBody First body's physics configuration
---@param vel1 Vec2 Velocity of body1 before collision, modified in place to the post-collision velocity
---@param body2 PhysicsBody Second body's physics configuration
---@param vel2 Vec2 Velocity of body2 before collision, modified in place to the post-collision velocity
---@param normal Vec2 Collision normal pointing from body2 → body1
function Physics.resolveCollision(body1, vel1, body2, vel2, normal)
    local m1 = body1.mass or 1.0
    local m2 = body2.mass or 1.0
    if m1 <= 0 and m2 <= 0 then return end

    local e = math.min(body1.bounciness or 0, body2.bounciness or 0)

    local relVel = vel1 - vel2
    local velAlongNormal = relVel:dot(normal)
    if velAlongNormal > 0 then return end   -- already separating

    local invM1 = m1 > 0 and (1 / m1) or 0
    local invM2 = m2 > 0 and (1 / m2) or 0
    local j     = -(1 + e) * velAlongNormal / (invM1 + invM2)

    local impulse = normal * j
    vel1:add(impulse *  invM1)
    vel2:add(impulse * -invM2)
end

--- Apply a force or scalar impulse to `velocity`.
---@param velocity Vec2 Velocity vector to be modified
---@param force Vec2|number Force vector or scalar
---@param mass? number Mass of the object (default 1.0)
function Physics.applyImpulse(velocity, force, mass)
    local m = mass or 1.0
    if m <= 0 then return end
    if type(force) == "table" and force.x then
        velocity:add(force * (1 / m))
    else
        velocity.x = velocity.x + (force / m)
    end
end

-- ===========================================================================
-- AABB collision detection
-- ===========================================================================

--- Returns true if two axis-aligned bounding boxes overlap.
--- All values in world units.  x/y are the top-left corner.
---@param ax number X-coordinate of AABB A
---@param ay number Y-coordinate of AABB A
---@param aw number Width of AABB A
---@param ah number Height of AABB A
---@param bx number X-coordinate of AABB B
---@param by number Y-coordinate of AABB B
---@param bw number Width of AABB B
---@param bh number Height of AABB B
---@return boolean True if the AABBs overlap
function Physics.aabbOverlap(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and ax + aw > bx
       and ay < by + bh and ay + ah > by
end

--- Returns the collision normal (Vec2) and penetration depth (number) for two
--- overlapping AABBs.  normal points from B into A (push A out of B).
--- Returns nil, 0 if there is no overlap.
---@param ax number X-coordinate of AABB A
---@param ay number Y-coordinate of AABB A
---@param aw number Width of AABB A
---@param ah number Height of AABB A
---@param bx number X-coordinate of AABB B
---@param by number Y-coordinate of AABB B
---@param bw number Width of AABB B
---@param bh number Height of AABB B
---@return Vec2|nil normal Collision normal vector (unit vector) pointing from B into A, or nil if no collision
---@return number depth Penetration depth (overlap amount) along the collision normal, or 0 if no collision
function Physics.getAABBOverlap(ax, ay, aw, ah, bx, by, bw, bh)
    if not Physics.aabbOverlap(ax, ay, aw, ah, bx, by, bw, bh) then
        return nil, 0
    end
    local overlapX = math.min(ax + aw, bx + bw) - math.max(ax, bx)
    local overlapY = math.min(ay + ah, by + bh) - math.max(ay, by)

    local cax, cay = ax + aw * 0.5, ay + ah * 0.5
    local cbx, cby = bx + bw * 0.5, by + bh * 0.5
    local normDx = math.abs(cax - cbx) / ((aw + bw) * 0.5)
    local normDy = math.abs(cay - cby) / ((ah + bh) * 0.5)

    if normDx >= normDy then
        local nx = cax < cbx and -1 or 1
        return M.vec2(nx, 0), overlapX
    else
        local ny = cay < cby and -1 or 1
        return M.vec2(0, ny), overlapY
    end
end

-- ===========================================================================
-- ECS system
-- ===========================================================================

--- Returns an ECS system function that applies gravity, friction, and
--- velocity integration to all entities that have `pos`, `vel`, and `body`
--- components.
---@param scene SceneInstance The scene to which the system will be added
---@param steps? number Sub-steps per frame (default 1). Higher values prevent tunneling for fast-moving objects.
---@return fun(dt:number, ids:number[], components:table) ECS system function to be added to the scene
function Physics.system(scene, steps)
    steps = math.max(1, math.floor(steps or 1))
    return function(dt, ids, components)
        local positions = components.pos
        local velocities = components.vel
        local bodies = components.body
        if not positions or not velocities or not bodies then return end

        local grav  = Physics.gravity()
        local subDt = dt / steps

        for _ = 1, steps do
            for _, id in ipairs(ids) do
                local pos  = positions[id]
                local vel  = velocities[id]
                local body = bodies[id]
                if pos and vel and body and not body.isKinematic then
                    if body.useGravity and body.gravityScale ~= 0 then
                        vel.x = vel.x + grav.x * body.gravityScale * subDt
                        vel.y = vel.y + grav.y * body.gravityScale * subDt
                    end

                    if body.friction and body.friction > 0 then
                        local factor = (1 - body.friction) ^ (subDt * 20)
                        vel.x = vel.x * factor
                        vel.y = vel.y * factor
                    end

                    local col = components.collider and components.collider[id]
                    if col and scene and scene.isAreaBlocked then
                        -- X movement
                        local oldX = pos.x
                        pos.x = pos.x + vel.x * subDt
                        local hitX = scene:isAreaBlocked(pos.x, pos.y, col.w or 1, col.h or 1, id)
                        if hitX then
                            pos.x = oldX
                            vel.x = -(vel.x or 0) * (body.bounciness or 0)
                        end

                        local oldY = pos.y
                        pos.y = pos.y + vel.y * subDt
                        local hitY, _, slopeY = scene:isAreaBlocked(pos.x, pos.y, col.w or 1, col.h or 1, id)
                        if hitY then
                            if slopeY then
                                pos.y = slopeY - (col.h or 1)
                            else
                                pos.y = oldY
                            end
                            vel.y = -(vel.y or 0) * (body.bounciness or 0)
                        end
                    else
                        pos.x = pos.x + vel.x * subDt
                        pos.y = pos.y + vel.y * subDt
                    end
                end
            end

            if components.onSubStep then
                components.onSubStep(ids)
            end
        end
    end
end

return Physics