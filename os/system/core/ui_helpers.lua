-- Shared Basalt 2.5 helpers used by OS services.
-- Keeps compatibility concerns in BasaltOS instead of modifying Basalt itself.

local ui_helpers = {}

local function resolve(value)
    if type(value) == "function" then return value() end
    return value
end

-- Adds the BasaltOS semigraphic border as a non-interactive overlay. color and
-- innerColor may be functions, which lets focused windows update without
-- rebuilding their chrome. topStyle="solid" keeps a titlebar as the top edge.
function ui_helpers.addBorder(frame, color, options)
    options = options or {}
    local explicit_sides = options.top ~= nil or options.bottom ~= nil
        or options.left ~= nil or options.right ~= nil
    local top = not explicit_sides or options.top == true
    local bottom = not explicit_sides or options.bottom == true
    local left = not explicit_sides or options.left == true
    local right = not explicit_sides or options.right == true

    local layer = frame:addFrame({
        x=1, y=1,
        width="{parent.width}", height="{parent.height}",
        background=false, disabled=true,
        z=options.z or 32767,
    }):setName(options.name or "border")
    local base_render = layer.render

    -- Visual overlays must never become the hover/click target.
    layer.contains = function() return false end
    layer.render = function(self, buf)
        base_render(self, buf)
        local width, height = self:getSize()
        if width < 2 or height < 2 then return end

        local border_color = resolve(color) or colors.gray
        local inner_color = resolve(options.innerColor)
        if inner_color == nil or inner_color == false then
            inner_color = frame.background or colors.black
        end

        if top and options.topStyle ~= "solid" and width > 2 then
            buf:blit(2, 1, ("\131"):rep(width - 2), border_color, inner_color)
        end
        if left then
            for y = top and 2 or 1, height - (bottom and 1 or 0) do
                buf:blit(1, y, "\149", border_color, inner_color)
            end
        end
        if right then
            for y = top and 2 or 1, height - (bottom and 1 or 0) do
                buf:blit(width, y, "\149", inner_color, border_color)
            end
        end
        if bottom and width > 2 then
            buf:blit(2, height, ("\143"):rep(width - 2), inner_color, border_color)
        end

        if top and left then buf:blit(1, 1, "\151", border_color, inner_color) end
        if top and right then buf:blit(width, 1, "\148", inner_color, border_color) end
        if bottom and left then buf:blit(1, height, "\138", inner_color, border_color) end
        if bottom and right then buf:blit(width, height, "\133", inner_color, border_color) end
    end

    return frame, layer
end

-- Recreates the old double-click convenience at OS level. Mouse-down only
-- recognizes the gesture; the callback runs on the matching mouse-up. This
-- prevents the release event from refocusing a launcher/browser after its
-- callback opened a new window.
function ui_helpers.onDoubleClick(element, callback, interval)
    local last_time = 0
    local last_key = nil
    local pending_key = nil
    interval = interval or 0.35
    element:onClick(function(self, button, ...)
        local now = os.clock()
        local item = self.getSelectedIndex and self:getSelectedIndex() or true
        local key = tostring(button) .. ":" .. tostring(item)
        if key == last_key and now - last_time <= interval then
            last_time, last_key = 0, nil
            pending_key = key
        else
            last_time, last_key = now, key
            pending_key = nil
        end
    end)
    element:onClickUp(function(self, button, ...)
        if not pending_key then return end
        local expected_key = pending_key
        pending_key = nil
        local item = self.getSelectedIndex and self:getSelectedIndex() or true
        local key = tostring(button) .. ":" .. tostring(item)
        if key == expected_key then
            callback(self, button, ...)
        end
    end)
    return element
end

return ui_helpers
