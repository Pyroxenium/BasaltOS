--- ui/events.lua
--- Event dispatch for the UI context.
--- Called by ctx:handleEvent(); receives the context and buffer as parameters.

local events = {}

-- ─── Private helpers ──────────────────────────────────────────────────────────

--- Compute a clamped, stepped slider value from a mouse x position.
--- Compute a clamped, stepped slider value from a mouse x position.
local function sliderValue(el, mx, ex)
    local relX = math.max(0, math.min(el.w - 1, mx - ex))
    local sMin = el.config.min  or 0
    local sMax = el.config.max  or 100
    local step = el.config.step or 1
    local raw  = sMin + (relX / math.max(1, el.w - 1)) * (sMax - sMin)
    local val  = math.floor(raw / step + 0.5) * step
    return math.max(sMin, math.min(sMax, val))
end

--- Hit-test the sorted element list and return the topmost interactive element
--- under (mx, my), along with its absolute render position.
--- Hit-test the sorted element list and return the topmost interactive element
--- under (mx, my), along with its absolute render position.
local function hitTest(ctx, mx, my, ox, oy)
    for i = #ctx.sorted, 1, -1 do
        local el = ctx.sorted[i]
        if not el.visible then goto next end

        local ex, ey = ctx:getAbsolutePos(el, ox, oy)

        if el.type == "container" then
            if mx >= ex and mx < ex + el.w and my >= ey and my < ey + el.h then
                -- Sort container children on demand
                if el.childrenDirty then
                    el.sortedChildren = {}
                    for _, c in pairs(el.children) do table.insert(el.sortedChildren, c) end
                    table.sort(el.sortedChildren, function(a, b) return a.z < b.z end)
                    el.childrenDirty = false
                end
                local contentX = ex + (el.borderLeft and 1 or 0)
                local contentY = ey + (el.borderTop  and 1 or 0)
                local contentH = el.h - (el.borderTop  and 1 or 0) - (el.borderBottom and 1 or 0)
                local scrollY  = el.scrollOffset or 0
                for j = #el.sortedChildren, 1, -1 do
                    local child = el.sortedChildren[j]
                    if child.visible then
                        local crx = contentX + child.x
                        local cry = contentY + child.y - scrollY
                        if cry + child.h > contentY and cry < contentY + contentH then
                            local childH = (child.type == "dropdown" and child.isOpen
                                            and child.config.options)
                                           and (child.h + #child.config.options) or child.h
                            if mx >= crx and mx < crx + child.w
                            and my >= cry and my < cry + childH then
                                return child, crx, cry
                            end
                        end
                    end
                end
                -- No child hit — return the container itself if it has onClick
                if el.config.onClick then
                    return el, ex, ey
                end
                return nil, 0, 0
            end
        else
            local elH = (el.type == "dropdown" and el.isOpen and el.config.options)
                        and (el.h + #el.config.options) or el.h
            if mx >= ex and mx < ex + el.w and my >= ey and my < ey + elH then
                return el, ex, ey
            end
        end
        ::next::
    end
    return nil, 0, 0
end

-- ─── Public API ───────────────────────────────────────────────────────────────

--- Process one CC:Tweaked event for the given UI context.
--- Process one CC:Tweaked event for the given UI context.
---@param ctx table UI context (from UI.new)
---@param buf Buffer Buffer instance (unused here, kept for signature symmetry)
---@param event table { eventType, ... } (e.g. { os.pullEvent() })
---@param ox number X offset used when the context was drawn
---@param oy number Y offset used when the context was drawn
---@return boolean consumed True if the event was consumed by the UI
function events.handle(ctx, buf, event, ox, oy)
    local eventType = event[1]

    -- ── Mouse click & drag ─────────────────────────────────────────────────────
    if eventType == "mouse_click" or eventType == "mouse_drag" then
        local mx, my = event[3], event[4]

        if ctx.dirty then ctx:_sort() end
        local hit, hitAbsX, hitAbsY = hitTest(ctx, mx, my, ox, oy)

        if eventType == "mouse_click" then
            -- Update input focus; close all open dropdowns except the one clicked
            ctx.focusedElement = (hit and hit.type == "input") and hit or nil
            for _, el in pairs(ctx.elements) do
                if el.type == "dropdown" and el ~= hit then el.isOpen = false end
                if el.type == "container" then
                    for _, child in pairs(el.children) do
                        if child.type == "dropdown" and child ~= hit then child.isOpen = false end
                    end
                end
            end

            if hit and hit.interactive and not hit.disabled then
                -- Checkbox toggle
                if hit.type == "checkbox" then
                    hit.config.checked = not hit.config.checked
                    if hit.config.onChanged then hit.config.onChanged(hit.config.checked) end
                    return true
                end

                -- Dropdown open/select
                if hit.type == "dropdown" then
                    if hit.isOpen then
                        local relY = my - hitAbsY - hit.h
                        if relY >= 0 and hit.config.options and relY < #hit.config.options then
                            hit.config.selectedIndex = relY + 1
                            if hit.config.onChanged then
                                hit.config.onChanged(hit.config.selectedIndex,
                                                     hit.config.options[hit.config.selectedIndex])
                            end
                        end
                        hit.isOpen = false
                    else
                        hit.isOpen = true
                    end
                    return true
                end

                -- List item select
                if hit.type == "list" then
                    local relY    = my - hitAbsY
                    local itemIdx = (hit.config.scrollOffset or 0) + relY + 1
                    if hit.config.options and itemIdx >= 1 and itemIdx <= #hit.config.options then
                        hit.config.selectedIndex = itemIdx
                        if hit.config.onChanged then
                            hit.config.onChanged(itemIdx, hit.config.options[itemIdx])
                        end
                    end
                    return true
                end

                -- Slider immediate set
                if hit.type == "slider" then
                    local val = sliderValue(hit, mx, hitAbsX)
                    hit.config.value = val
                    if hit.config.onChanged then hit.config.onChanged(val) end
                end

                ctx.pressedElement = hit
                ctx.pressedAbsX    = hitAbsX
                ctx.pressedAbsY    = hitAbsY
                return true
            end

        elseif eventType == "mouse_drag" then
            if ctx.pressedElement and ctx.pressedElement.type == "slider" then
                local el  = ctx.pressedElement
                local val = sliderValue(el, mx, ctx.pressedAbsX or 0)
                el.config.value = val
                if el.config.onChanged then el.config.onChanged(val) end
                return true
            end
        end

    -- ── Mouse up ──────────────────────────────────────────────────────────────
    elseif eventType == "mouse_up" then
        if ctx.pressedElement then
            local el     = ctx.pressedElement
            local ex, ey = ctx.pressedAbsX or 0, ctx.pressedAbsY or 0
            local mx, my = event[3], event[4]

            if el.type == "slider" then
                local val = sliderValue(el, mx, ex)
                el.config.value = val
                if el.config.onChanged then el.config.onChanged(val) end
            elseif mx >= ex and mx < ex + el.w and my >= ey and my < ey + el.h then
                if el.config.onClick then
                    el.config.onClick(event[2])
                end
            end

            ctx.pressedElement = nil
            ctx.pressedAbsX    = nil
            ctx.pressedAbsY    = nil
            return true
        end

    -- ── Text input ────────────────────────────────────────────────────────────
    elseif eventType == "char" then
        if ctx.focusedElement and ctx.focusedElement.type == "input" then
            local el = ctx.focusedElement
            el.config.text = (el.config.text or "") .. event[2]
            if el.config.onChange then el.config.onChange(el.config.text) end
            return true
        end

    -- ── Key input ─────────────────────────────────────────────────────────────
    elseif eventType == "key" then
        if ctx.focusedElement and ctx.focusedElement.type == "input" then
            local el  = ctx.focusedElement
            local key = event[2]
            if key == keys.backspace then
                el.config.text = (el.config.text or ""):sub(1, -2)
                if el.config.onChange then el.config.onChange(el.config.text) end
            elseif key == keys.enter then
                ctx.focusedElement = nil
                if el.config.onConfirm then el.config.onConfirm(el.config.text) end
            end
            return true
        end

    -- ── Scroll ────────────────────────────────────────────────────────────────
    elseif eventType == "mouse_scroll" then
        local dir, mx, my = event[2], event[3], event[4]
        if ctx.dirty then ctx:_sort() end
        for i = #ctx.sorted, 1, -1 do
            local el = ctx.sorted[i]
            if el.visible and not el.disabled then
                local ex, ey = ctx:getAbsolutePos(el, ox, oy)
                if mx >= ex and mx < ex + el.w and my >= ey and my < ey + el.h then
                    if el.type == "list" then
                        local maxScroll = math.max(0, #(el.config.options or {}) - el.h)
                        el.config.scrollOffset = math.max(0,
                            math.min(maxScroll, (el.config.scrollOffset or 0) + dir))
                        return true
                    elseif el.type == "slider" then
                        local sMin = el.config.min  or 0
                        local sMax = el.config.max  or 100
                        local step = el.config.step or 1
                        local val  = math.max(sMin, math.min(sMax,
                                         (el.config.value or sMin) - dir * step))
                        el.config.value = val
                        if el.config.onChanged then el.config.onChanged(val) end
                        return true
                    elseif el.type == "container" and el.config.scrollable ~= false then
                        local contentH = el.h
                            - (el.borderTop    and 1 or 0)
                            - (el.borderBottom and 1 or 0)
                        local maxChildBottom = 0
                        for _, child in pairs(el.children) do
                            local b = child.y + child.h
                            if b > maxChildBottom then maxChildBottom = b end
                        end
                        local maxScroll = math.max(0, maxChildBottom - contentH)
                        el.scrollOffset = math.max(0, math.min(maxScroll, el.scrollOffset + dir))
                        return true
                    end
                end
            end
        end
    end

    return false
end

return events
