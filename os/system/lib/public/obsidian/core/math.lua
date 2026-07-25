-- Obsidian Engine: Math & Vector Module
--- Provides basic math utilities and a 2D vector class with common operations.

---@diagnostic disable: undefined-global

local m_sqrt  = math.sqrt
local m_cos   = math.cos
local m_sin   = math.sin
local m_atan2 = math.atan2
local m_floor = math.floor
local m_abs   = math.abs
local m_min   = math.min
local m_max   = math.max

--- The Math module provides utility functions and a Vec2 class for 2D vector math.
---@class MathModule
local Math = {}

--- Vec2 class definition and operations
---@class Vec2
---@field x number The x component of the vector
---@field y number The y component of the vector
---@operator add(Vec2): Vec2 -- Vector addition
---@operator sub(Vec2): Vec2 -- Vector subtraction
---@operator mul(Vec2|number): Vec2 -- Vector-scalar or vector-vector multiplication
---@operator div(number): Vec2 -- Vector-scalar division
---@operator unm(): Vec2 -- Unary minus (negation)
local Vector2 = {}
Vector2.__index = Vector2

--- Create a new 2D vector.
---@param x? number x component (default 0)
---@param y? number y component (default 0)
---@return Vec2 Vec2 New vector instance
function Math.vec2(x, y)
    local v = { x = x or 0, y = y or 0 }
    setmetatable(v, Vector2)
    return v
end

function Vector2.__add(v1, v2) return Math.vec2(v1.x + v2.x, v1.y + v2.y) end
function Vector2.__sub(v1, v2) return Math.vec2(v1.x - v2.x, v1.y - v2.y) end
function Vector2.__eq(v1, v2)  return v1.x == v2.x and v1.y == v2.y end
function Vector2.__mul(v, s)
    if type(v) == "number" then return Math.vec2(s.x * v, s.y * v) end
    if type(s) == "number" then return Math.vec2(v.x * s, v.y * s) end
    return Math.vec2(v.x * s.x, v.y * s.y)
end
function Vector2.__div(v, s) return Math.vec2(v.x / s, v.y / s) end
function Vector2.__unm(v) return Math.vec2(-v.x, -v.y) end
function Vector2.__tostring(v) return string.format("Vec2(%.2f, %.2f)", v.x, v.y) end

--- Calculate distance to another vector.
---@param self Vec2 The vector to measure distance from
---@param other Vec2 The other vector to measure distance to
---@return number distance The distance between this vector and the other
function Vector2:dist(other)
    if not other then return math.huge end
    return Math.dist(self.x, self.y, other.x, other.y)
end

--- Calculate squared distance to another vector (faster, no sqrt).
---@param self Vec2 The vector to measure distance from
---@param other Vec2 The other vector to measure squared distance to
---@return number distance The squared distance between this vector and the other
function Vector2:sqDist(other)
    if not other then return math.huge end
    local dx = self.x - other.x
    local dy = self.y - other.y
    return dx * dx + dy * dy
end

--- Returns the magnitude (length) of the vector.
--- @param self Vec2 The vector to calculate the length of
---@return number length The length of the vector
function Vector2:len()
    return m_sqrt(self.x * self.x + self.y * self.y)
end

--- Returns the squared magnitude of the vector.
--- @param self Vec2 The vector to calculate the squared length of
---@return number length The squared length of the vector
function Vector2:sqLen()
    return self.x * self.x + self.y * self.y
end

--- Returns a normalized (length=1) version of this vector.
---@param self Vec2 The vector to normalize
---@return Vec2 normalized The normalized vector, or zero vector if length is 0
function Vector2:normalize()
    local l = self:len()
    if l == 0 then return Math.vec2(0, 0) end
    return Math.vec2(self.x / l, self.y / l)
end

--- Returns a vector linearly interpolated between this and other.
---@param other Vec2 The other vector to interpolate towards
---@param t number Interpolation factor (0-1)
---@return Vec2 The interpolated vector
function Vector2:lerp(other, t)
    return Math.vec2(Math.lerp(self.x, other.x, t), Math.lerp(self.y, other.y, t))
end

--- Dot product of two vectors.
---@param self Vec2 The first vector
---@param other Vec2 The second vector to dot with
---@return number The dot product result
function Vector2:dot(other)
    return self.x * other.x + self.y * other.y
end

--- Unpack vector into x, y.
---@param self Vec2 The vector to unpack
---@return number x, number y
function Vector2:unpack() return self.x, self.y end

--- Mutate: set vector components.
---@param self Vec2 The vector to set components for
---@param x? number New x component (optional)
---@param y? number New y component (optional)
---@return Vec2 self
function Vector2:set(x, y)
    if x ~= nil then self.x = x end
    if y ~= nil then self.y = y end
    return self
end

--- Mutate: add another vector to this one.
---@param self Vec2 The vector to add to
---@param v Vec2 The vector to add
---@return Vec2 self
function Vector2:add(v)
    self.x = self.x + v.x
    self.y = self.y + v.y
    return self
end

--- Mutate: multiply this vector by a scalar.
---@param self Vec2 The vector to multiply
---@param s number The scalar to multiply by
---@return Vec2 self
function Vector2:mul(s)
    self.x = self.x * s
    self.y = self.y * s
    return self
end

--- Mutate: Limit the length of this vector.
---@param self Vec2 The vector to limit
---@param max number The maximum length
---@return Vec2 self
function Vector2:limit(max)
    local sq = self:sqLen()
    if sq > max * max then
        local l = m_sqrt(sq)
        self.x, self.y = (self.x / l) * max, (self.y / l) * max
    end
    return self
end

--- 2D cross product (scalar z-component: x1*y2 - y1*x2).
---@param self Vec2 The first vector
---@param other Vec2 The second vector
---@return number The z-component of the cross product
function Vector2:cross(other)
    return self.x * other.y - self.y * other.x
end

--- Returns a new Vec2 with the same values.
---@param self Vec2 The vector to clone
---@return Vec2 Vec2 The cloned vector
function Vector2:clone()
    return Math.vec2(self.x, self.y)
end

--- Non-mutating: Returns vector rotated by radians.
--- @param self Vec2 The vector to rotate
---@param angle number The angle in radians to rotate by
---@return Vec2 Vec2 The rotated vector
function Vector2:rotate(angle)
    local c = m_cos(angle)
    local s = m_sin(angle)
    return Math.vec2(self.x * c - self.y * s, self.x * s + self.y * c)
end

--- Linear interpolation between two numbers.
---@param a number Starting value
---@param b number Ending value
---@param t number Interpolation factor (0-1)
---@return number Interpolated value
function Math.lerp(a, b, t)
    return a + (b - a) * t
end

--- Apply frame-rate independent damping to a velocity vector.
---@param velocity Vec2 The velocity vector to apply damping to (mutated in place)
---@param amount number Damping strength (0-1)
---@param dt number Delta time in seconds
function Math.applyDamping(velocity, amount, dt)
    local factor = (1 - amount) ^ (dt * 20)
    velocity.x = velocity.x * factor
    velocity.y = velocity.y * factor
end

--- Checks if a value is a Vec2 instance.
---@param v any The value to check
---@return boolean isVec2 True if the value is a Vec2, false otherwise
function Math.isVec2(v)
    return type(v) == "table" and getmetatable(v) == Vector2
end

--- Clamp a value between min and max.
---@param val number The value to clamp
---@param min number The minimum allowed value
---@param max number The maximum allowed value
---@return number The clamped value
function Math.clamp(val, min, max)
    return m_min(m_max(val, min), max)
end

--- Calculate distance between two points.
---@param x1 number x coordinate of the first point
---@param y1 number y coordinate of the first point
---@param x2 number x coordinate of the second point
---@param y2 number y coordinate of the second point
---@return number distance The distance between the two points
function Math.dist(x1, y1, x2, y2)
    local dx = x1 - x2
    local dy = y1 - y2
    return m_sqrt(dx * dx + dy * dy)
end

--- Returns a normalised Vec2.  Returns zero-vec if length is 0.
---@param x number The x component of the vector
---@param y number The y component of the vector
---@return Vec2 normalized The normalized vector
function Math.normalize(x, y)
    local length = m_sqrt(x * x + y * y)
    if length == 0 then return Math.vec2(0, 0) end
    return Math.vec2(x / length, y / length)
end

--- Returns nx, ny, length as raw numbers (for callers that need the length too).
---@param x number The x component of the vector
---@param y number The y component of the vector
---@return number nx The normalized x component
---@return number ny The normalized y component
---@return number length The length of the vector
function Math.normalizeRaw(x, y)
    local length = m_sqrt(x * x + y * y)
    if length == 0 then return 0, 0, 0 end
    return x / length, y / length, length
end

---@param val number The value to round
---@return number rounded The rounded value
function Math.round(val)
    return m_floor(val + 0.5)
end

---@param val number The value to get the sign of
---@return number sign The sign of the value: 1 for positive, -1 for negative, 0 for zero
function Math.sign(val)
    if val > 0 then return 1 elseif val < 0 then return -1 else return 0 end
end

--- Returns the angle in radians between two points.
---@param x1 number x coordinate of the first point
---@param y1 number y coordinate of the first point
---@param x2 number x coordinate of the second point
---@param y2 number y coordinate of the second point
---@return number angle The angle in radians between the two points
function Math.angleBetween(x1, y1, x2, y2)
    return m_atan2(y2 - y1, x2 - x1)
end

--- Create a vector from an angle and length.
---@param angle number The angle in radians
---@param length? number The length of the vector (default 1)
---@return Vec2 The resulting vector
function Math.fromAngle(angle, length)
    length = length or 1
    return Math.vec2(m_cos(angle) * length, m_sin(angle) * length)
end

return Math