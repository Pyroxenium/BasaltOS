
-- Obsidian Engine: Camera module
-- Provides a camera prototype used by scenes to follow entities, perform
-- world<->screen coordinate conversions, and apply simple screen-space
-- effects (shake, flash). Create instances with `camera.new(scene)`; methods
-- are available on the `CameraInstance` prototype.
-- Camera module. Manages a virtual camera position that maps world coordinates to screen coordinates.
---@diagnostic disable: undefined-global

---@class CameraModule
local camera = {}

--- Camera instance class. Each scene has one camera instance that drives its .camera vec2.
---@class CameraInstance
---@field _scene SceneInstance
---@field _targetX number Target X position in world units
---@field _targetY number Target Y position in world units
---@field lerpFactor number 0-1 smoothing factor for camera movement (default 0.1)
---@field _followId number|nil Entity id to follow, or nil for no following
---@field _followComp string Component name that holds {x,y} to follow (default "pos")
---@field _deadzone { w:number, h:number }|nil Deadzone rectangle size in world units, or nil for no deadzone
---@field _boundsX1 number|nil Left bound in world units, or nil for no bound
---@field _boundsY1 number|nil Top bound in world units, or nil for no bound
---@field _boundsX2 number|nil Right bound in world units, or nil for no bound
---@field _boundsY2 number|nil Bottom bound in world units, or nil for no bound
---@field offsetX number Horizontal offset added to the camera position (useful for looking ahead of movement)
---@field offsetY number Vertical offset added to the camera position
---@field _shakeIntensity number Current shake intensity (max pixel offset)
---@field _shakeDuration number Seconds of shake remaining
---@field _shakeDurationMax number Initial shake duration for calculating falloff
---@field _shakeOffsetX number Current shake offset X in world units (updated each frame during shake)
---@field _shakeOffsetY number Current shake offset Y in world units (updated each frame during shake)
---@field _flashColor string Current flash color (CC blit character)
---@field _flashDuration number Seconds of flash remaining
local CameraInstance = {}
CameraInstance.__index = CameraInstance

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

--- Create a new camera bound to a scene.
--- @param scene SceneInstance The scene whose .camera vec2 will be driven
--- @return CameraInstance
function camera.new(scene)
    assert(scene and scene.camera, "camera.new: scene must have a .camera vec2")
    local self = setmetatable({}, CameraInstance)
    ---@cast self CameraInstance

    self._scene       = scene
    self._targetX     = scene.camera.x
    self._targetY     = scene.camera.y
    self.lerpFactor   = 0.1
    self._followId    = nil
    self._followComp  = "pos"
    self._deadzone    = nil   -- { w, h } or nil
    self._boundsX1    = nil
    self._boundsY1    = nil
    self._boundsX2    = nil
    self._boundsY2    = nil
    self.offsetX      = 0
    self.offsetY      = 0
    self._shakeIntensity   = 0
    self._shakeDuration    = 0
    self._shakeDurationMax = 0
    self._shakeOffsetX     = 0
    self._shakeOffsetY     = 0
    self._flashColor       = "0"
    self._flashDuration    = 0

    scene._camera = self
    return self
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

--- Follow an entity by its id.
--- @param self CameraInstance
--- @param id number Entity id (must have a `pos` component or the component named via `comp`)
--- @param opts table|nil Optional settings
function CameraInstance:follow(id, opts)
    opts = opts or {}
    self._followId   = id
    self._followComp = opts.comp or "pos"
    if opts.lerp    ~= nil then self.lerpFactor = opts.lerp end
    if opts.deadzone       then self._deadzone  = opts.deadzone end
end

--- Stop following any entity.
---@param self CameraInstance
function CameraInstance:unfollow()
    self._followId = nil
end

--- Clamp the camera so it never shows world area outside the given rectangle.
--- Pass nil values to remove clamping.
---@param self CameraInstance
--- @param x1 number Left bound in world units
--- @param y1 number Top bound in world units
--- @param x2 number Right bound in world units
--- @param y2 number Bottom bound in world units
function CameraInstance:setBounds(x1, y1, x2, y2)
    self._boundsX1 = x1
    self._boundsY1 = y1
    self._boundsX2 = x2
    self._boundsY2 = y2
end

--- Remove world bounds.
---@param self CameraInstance
function CameraInstance:clearBounds()
    self._boundsX1, self._boundsY1 = nil, nil
    self._boundsX2, self._boundsY2 = nil, nil
end

--- Set a camera lead offset (useful for making the camera look ahead of movement).
--- @param self CameraInstance
--- @param ox number Horizontal offset in world units
--- @param oy number Vertical offset in world units
function CameraInstance:setOffset(ox, oy)
    self.offsetX = ox or 0
    self.offsetY = oy or 0
end

-- ---------------------------------------------------------------------------
-- Immediate positioning
-- ---------------------------------------------------------------------------

--- Snap the camera to an exact world position (no lerp this frame).
--- @param self CameraInstance
--- @param wx number World X
--- @param wy number World Y
function CameraInstance:moveTo(wx, wy)
    self._targetX = wx + self.offsetX
    self._targetY = wy + self.offsetY
    self:_applyBounds()
    self._scene.camera.x = self._targetX
    self._scene.camera.y = self._targetY
end

--- Pan by a delta (adds to the current target position).
--- @param self CameraInstance
--- @param dx number
--- @param dy number
function CameraInstance:pan(dx, dy)
    self._targetX = self._targetX + (dx or 0)
    self._targetY = self._targetY + (dy or 0)
    self:_applyBounds()
    self._scene.camera.x = self._targetX
    self._scene.camera.y = self._targetY
end

-- ---------------------------------------------------------------------------
-- Per-frame update  (call inside scene:onUpdate or similar)
-- ---------------------------------------------------------------------------

--- Advance the camera each frame.
--- Reads the followed entity's pos, evaluates the deadzone, lerps, clamps to
--- bounds, and writes the result into scene.camera.
--- @param self CameraInstance
--- @param dt number Delta time in seconds
function CameraInstance:update(dt)
    local scene = self._scene

    if self._followId then
        local comp = scene.components[self._followComp]
        local pos  = comp and comp[self._followId]
        if pos then
            local desiredX = pos.x + self.offsetX
            local desiredY = pos.y + self.offsetY

            if self._deadzone then
                local hw = self._deadzone.w * 0.5
                local hh = self._deadzone.h * 0.5
                local cx = self._targetX
                local cy = self._targetY
                if desiredX < cx - hw then
                    self._targetX = desiredX + hw
                elseif desiredX > cx + hw then
                    self._targetX = desiredX - hw
                end
                if desiredY < cy - hh then
                    self._targetY = desiredY + hh
                elseif desiredY > cy + hh then
                    self._targetY = desiredY - hh
                end
            else
                self._targetX = desiredX
                self._targetY = desiredY
            end
        end
    end

    self:_applyBounds()

    local f = math.min(1, self.lerpFactor * (dt * 60))  -- frame-rate independent
    scene.camera.x = scene.camera.x + (self._targetX - scene.camera.x) * f
    scene.camera.y = scene.camera.y + (self._targetY - scene.camera.y) * f

    if self._shakeDuration > 0 then
        self._shakeDuration = self._shakeDuration - dt
        if self._shakeDuration <= 0 then
            self._shakeDuration = 0
            self._shakeOffsetX  = 0
            self._shakeOffsetY  = 0
            scene._staticDirty   = true
        else
            local falloff = self._shakeDuration / self._shakeDurationMax
            local intensity = self._shakeIntensity * falloff
            self._shakeOffsetX = (math.random() - 0.5) * 2 * intensity
            self._shakeOffsetY = (math.random() - 0.5) * 2 * intensity
        end
    end

    if self._flashDuration > 0 then
        self._flashDuration = self._flashDuration - dt
    end
end

-- ---------------------------------------------------------------------------
-- Screen-space effects
-- ---------------------------------------------------------------------------

--- Shake the camera with a given intensity and duration.
--- @param self CameraInstance
--- @param intensity number  Max pixel-offset per frame
--- @param duration number  Seconds the shake lasts
function CameraInstance:shake(intensity, duration)
    self._shakeIntensity   = intensity or 1
    self._shakeDuration    = duration  or 0.5
    self._shakeDurationMax = self._shakeDuration
end

--- Flash the screen with a solid color overlay for a short duration.
--- @param self CameraInstance
--- @param color string CC blit color character (e.g. "e" = red)
--- @param duration number Seconds the flash lasts
function CameraInstance:flash(color, duration)
    self._flashColor    = color    or "0"
    self._flashDuration = duration or 0.2
end

--- @param self CameraInstance
--- @return boolean
function CameraInstance:isShaking()
    return self._shakeDuration > 0
end

--- @param self CameraInstance
--- @return number shakeX World-space pixel offset this frame
--- @return number shakeY World-space pixel offset this frame
function CameraInstance:getShakeOffset()
    return self._shakeOffsetX, self._shakeOffsetY
end

--- @param self CameraInstance
--- @return boolean
function CameraInstance:isFlashing()
    return self._flashDuration > 0
end

--- @param self CameraInstance
--- @return string CC blit color character
function CameraInstance:getFlashColor()
    return self._flashColor
end

-- ---------------------------------------------------------------------------
-- Coordinate helpers
-- ---------------------------------------------------------------------------

--- Convert a world position to screen (terminal character) position.
--- Accounts for the current camera and the engine's design-resolution letterbox offset.
--- @param self CameraInstance
--- @param wx number World X
--- @param wy number World Y
--- @return number sx 1-based screen X character position
--- @return number sy 1-based screen Y character position
function CameraInstance:worldToScreen(wx, wy)
    local scene = self._scene
    local termW, termH
    if scene and scene.ui and scene.ui.buf and type(scene.ui.buf.getSize) == "function" then
        termW, termH = scene.ui.buf:getSize()
    else
        termW, termH = term.getSize()
    end
    local designW, designH = debug.designW, debug.designH
    local offsetX, offsetY = 0, 0
    if designW and designH then
        offsetX = math.max(0, math.floor((termW - designW) / 2))
        offsetY = math.max(0, math.floor((termH - designH) / 2))
    end
    local sx = math.floor(wx - scene.camera.x + offsetX) + 1
    local sy = math.floor(wy - scene.camera.y + offsetY) + 1
    return sx, sy
end

--- Convert a screen (terminal) position back to world coordinates.
--- @param self CameraInstance
--- @param sx  number  1-based screen X character position
--- @param sy  number  1-based screen Y character position
--- @return number wx World X
--- @return number wy World Y
function CameraInstance:screenToWorld(sx, sy)
    local scene = self._scene
    local termW, termH
    if scene and scene.ui and scene.ui.buf and type(scene.ui.buf.getSize) == "function" then
        termW, termH = scene.ui.buf:getSize()
    else
        termW, termH = term.getSize()
    end
    local designW, designH = debug.designW, debug.designH
    local offsetX, offsetY = 0, 0
    if designW and designH then
        offsetX = math.max(0, math.floor((termW - designW) / 2))
        offsetY = math.max(0, math.floor((termH - designH) / 2))
    end
    local wx = (sx - 1) + scene.camera.x - offsetX
    local wy = (sy - 1) + scene.camera.y - offsetY
    return wx, wy
end

--- Read the camera's current world position (what the top-left corner maps to).
--- @param self CameraInstance
--- @return number x
--- @return number y
function CameraInstance:getPosition()
    return self._scene.camera.x, self._scene.camera.y
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Apply the current bounds to the target position.
function CameraInstance:_applyBounds()
    if self._boundsX1 ~= nil and self._targetX < self._boundsX1 then
        self._targetX = self._boundsX1
    end
    if self._boundsY1 ~= nil and self._targetY < self._boundsY1 then
        self._targetY = self._boundsY1
    end
    if self._boundsX2 ~= nil and self._targetX > self._boundsX2 then
        self._targetX = self._boundsX2
    end
    if self._boundsY2 ~= nil and self._targetY > self._boundsY2 then
        self._targetY = self._boundsY2
    end
end

return camera
