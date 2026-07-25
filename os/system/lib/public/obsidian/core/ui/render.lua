--- ui/render.lua
--- All drawing functions for the UI system.
--- Every function takes a Buffer instance (buf) as first argument.

local render = {}

-- ─── Private helpers ──────────────────────────────────────────────────────────

local function drawScrollbar(buf, x, topY, trackH, scrollOffset, totalRows, trackColor, thumbColor)
    if totalRows <= trackH then return end
    local thumbSize = math.max(1, math.floor(trackH * trackH / totalRows))
    local maxScroll = totalRows - trackH
    local thumbPos  = math.floor((scrollOffset / maxScroll) * (trackH - thumbSize))
    for i = 0, trackH - 1 do
        local isThumb = (i >= thumbPos and i < thumbPos + thumbSize)
        buf:drawText(x, topY + i, " ", "0", isThumb and thumbColor or trackColor)
    end
end

--- Draw the four box-drawing borders of an element.
-- @param buf   Buffer instance
-- @param el    Element table (needs borderTop/Bottom/Left/Right, w, h)
-- @param rx,ry Absolute render position
-- @param bc    Border colour (hex char)
-- @param bg    Background colour (hex char)
local function drawBorder(buf, el, rx, ry, bc, bg)
    if el.borderTop    then buf:drawText(rx, ry,            ("\131"):rep(el.w), bc, bg) end
    if el.borderBottom then buf:drawText(rx, ry + el.h - 1, ("\143"):rep(el.w), bg, bc) end
    if el.borderLeft   then
        for i = 0, el.h - 1 do buf:drawText(rx,           ry + i, "\149", bc, bg) end
    end
    if el.borderRight  then
        for i = 0, el.h - 1 do buf:drawText(rx + el.w - 1, ry + i, "\149", bg, bc) end
    end
    if el.borderTop    and el.borderLeft  then buf:drawText(rx,           ry,           "\151", bc, bg) end
    if el.borderTop    and el.borderRight then buf:drawText(rx + el.w - 1, ry,           "\148", bg, bc) end
    if el.borderBottom and el.borderLeft  then buf:drawText(rx,           ry + el.h - 1, "\138", bg, bc) end
    if el.borderBottom and el.borderRight then buf:drawText(rx + el.w - 1, ry + el.h - 1, "\133", bg, bc) end
end

-- ─── Element draw ─────────────────────────────────────────────────────────────

--- Draw a single non-container element at absolute position (rx, ry).
---@param buf Buffer
---@param el table Element table
---@param rx number Absolute render X
---@param ry number Absolute render Y
---@param pressedEl table|nil Currently pressed element
---@param focusedEl table|nil Currently focused element
---@param rowsToRestore table Table populated with touched row indices
function render.drawEl(buf, el, rx, ry, pressedEl, focusedEl, rowsToRestore)
    -- Sprite
    if el.sprite then
        local frame = el.sprite[el.config.frame or 1]
        if frame then
            buf:drawSprite(frame, rx, ry, 0, 0)
            for i = 0, el.h - 1 do rowsToRestore[ry + i] = true end
        end
        return
    end

    -- Single-line text label
    if el.type == "text" then
        buf:drawText(rx, ry, el.config.text or "", el.disabled and "8" or el.fore, el.back)
        rowsToRestore[ry] = true
        return
    end

    -- Multi-line label with word-wrap
    if el.type == "multiline" then
        local element = require("core.ui.element")
        local lines   = element.wrapText(el.config.text or "", el.w)
        local align   = el.config.align or "left"
        local fg      = el.disabled and "8" or el.fore
        buf:drawRect(rx, ry, el.w, el.h, " ", fg, el.back)
        for i, line in ipairs(lines) do
            local row = ry + i - 1
            if row >= ry + el.h then break end
            local tx = rx
            if align == "center" then
                tx = rx + math.floor((el.w - #line) / 2)
            elseif align == "right" then
                tx = rx + el.w - #line
            end
            if #line > 0 then buf:drawText(tx, row, line, fg, el.back) end
        end
        -- drawRect touched the complete element, including empty wrapped rows.
        for i = 0, el.h - 1 do rowsToRestore[ry + i] = true end
        return
    end

    -- Box-based widgets: rect, button, input, checkbox, dropdown, progress
    if el.type == "rect"   or el.type == "button" or el.type == "input"
    or el.type == "checkbox" or el.type == "dropdown" or el.type == "progress" then
        local isPressed = (pressedEl == el)
        local isFocused = (focusedEl == el)
        local bg = el.disabled and "8" or (isPressed and el.borderColor or el.back)
        local fg = el.disabled and "7" or (isPressed and el.back or el.fore)
        local bc = (isPressed or isFocused) and el.fore or el.borderColor

        buf:drawRect(rx, ry, el.w, el.h, el.config.char or " ", fg, bg)

        -- Progress fill
        if el.type == "progress" then
            local progress = math.max(0, math.min(1, el.config.progress or 0))
            local fillCol  = el.config.fillColor or "d"
            local fillW    = math.floor(el.w * progress)
            local frac     = el.w * progress - fillW
            if fillW > 0 then
                buf:drawRect(rx, ry, fillW, el.h, el.config.fillChar or " ", fillCol, fillCol)
            end
            if frac >= 0.5 and fillW < el.w then
                for row = 0, el.h - 1 do
                    buf:drawText(rx + fillW, ry + row, "\149", fillCol, el.back)
                end
            end
        end

        drawBorder(buf, el, rx, ry, bc, bg)

        -- Checkbox mark
        if el.type == "checkbox" then
            local mark = el.config.checked and "\7" or " "
            buf:drawText(rx + math.floor(el.w / 2), ry + math.floor(el.h / 2), mark, fg, bg)
        end

        -- Button / Input text
        if (el.type == "button" or el.type == "input") and el.config.text ~= nil then
            local text = el.config.text
            local ty   = ry + math.floor(el.h / 2)
            local tx

            if el.type == "input" then
                tx = rx + 1
                local cursor = isFocused and (math.floor(os.clock() * 2) % 2 == 0)
                if el.config.password then
                    text = string.rep("*", #text)
                end
                if cursor then text = text .. "_" end
                local maxW = math.max(1, el.w - 2)
                if #text > maxW then text = text:sub(#text - maxW + 1) end
            else
                tx = rx + math.floor((el.w - #text) / 2)
            end

            buf:drawText(tx, ty, text, fg, bg)
        end

        -- Dropdown value + arrow + open list
        if el.type == "dropdown" then
            local selected    = el.config.selectedIndex
            local displayText = tostring(
                (selected and el.config.options and el.config.options[selected])
                or el.config.text or "")
            local maxW = math.max(1, el.w - 2)
            if #displayText > maxW then displayText = displayText:sub(1, maxW) end
            buf:drawText(rx + 1, ry + math.floor(el.h / 2), displayText, fg, bg)
            buf:drawText(rx + el.w - 1, ry + math.floor(el.h / 2),
                         el.isOpen and "\30" or "\31", fg, bg)

            if el.isOpen and el.config.options then
                for i, opt in ipairs(el.config.options) do
                    local optY  = ry + el.h - 1 + i
                    local optBg = (i == selected) and el.fore or el.back
                    local optFg = (i == selected) and el.back or el.fore
                    buf:drawRect(rx, optY, el.w, 1, " ", optFg, optBg)
                    local optText = tostring(opt)
                    if #optText > el.w - 1 then optText = optText:sub(1, el.w - 1) end
                    buf:drawText(rx + 1, optY, optText, optFg, optBg)
                    rowsToRestore[optY] = true
                end
            end
        end

        for i = 0, el.h - 1 do rowsToRestore[ry + i] = true end
        return
    end

    -- List
    if el.type == "list" then
        local options       = el.config.options or {}
        local scrollOffset  = el.config.scrollOffset or 0
        local selectedIndex = el.config.selectedIndex
        local selFore    = el.config.selectedFore or el.back
        local selBack    = el.config.selectedBack or el.fore
        local needsBar   = #options > el.h
        local itemW      = needsBar and (el.w - 1) or el.w
        local trackColor = el.config.scrollTrack or "8"
        local thumbColor = el.config.scrollThumb or el.fore

        buf:drawRect(rx, ry, el.w, el.h, " ", el.fore, el.back)
        for row = 0, el.h - 1 do
            local itemIdx = scrollOffset + row + 1
            local opt = options[itemIdx]
            if opt then
                local isSelected = (itemIdx == selectedIndex)
                local fg = isSelected and selFore or el.fore
                local bg = isSelected and selBack or el.back
                local text = tostring(opt)
                if #text > itemW then text = text:sub(1, itemW) end
                buf:drawRect(rx, ry + row, itemW, 1, " ", fg, bg)
                buf:drawText(rx, ry + row, text, fg, bg)
            end
        end
        if needsBar then
            drawScrollbar(buf, rx + el.w - 1, ry, el.h, scrollOffset, #options, trackColor, thumbColor)
        end
        for i = 0, el.h - 1 do rowsToRestore[ry + i] = true end
        return
    end

    -- Slider
    if el.type == "slider" then
        local sMin      = el.config.min or 0
        local sMax      = el.config.max or 100
        local value     = el.config.value or sMin
        local t         = (sMax > sMin) and math.max(0, math.min(1, (value - sMin) / (sMax - sMin))) or 0
        local thumbPos  = math.floor(t * (el.w - 1))
        local fillColor = el.disabled and "8" or (el.config.fillColor or "d")
        local trackBg   = el.disabled and "7" or el.back
        local thumbFore = el.config.thumbFore or el.back
        local thumbBack = el.config.thumbBack or (el.disabled and "8" or el.fore)
        local thumbChar = el.config.thumbChar or "\149"

        buf:drawRect(rx, ry, el.w, el.h, " ", el.fore, trackBg)
        if thumbPos > 0 then
            buf:drawRect(rx, ry, thumbPos, el.h, " ", fillColor, fillColor)
        end
        buf:drawText(rx + thumbPos, ry, thumbChar, thumbFore, thumbBack)
        if el.config.showValue then
            local label = tostring(math.floor(value))
            local lx = rx + math.floor((el.w - #label) / 2)
            if lx + #label - 1 ~= rx + thumbPos then
                buf:drawText(lx, ry, label, el.fore, trackBg)
            end
        end
        for i = 0, el.h - 1 do rowsToRestore[ry + i] = true end
    end
end

-- ─── Container draw ───────────────────────────────────────────────────────────

--- Draw a container and all its visible, clipped children.
-- @param buf             Buffer instance
-- @param el              Container element table
-- @param rx, ry          Absolute render position
-- @param ctx             UI context (for pressedElement / focusedElement)
-- @param rowsToRestore   Table populated with touched row indices
---@param buf Buffer
---@param el table Container element table
---@param rx number Absolute render X
---@param ry number Absolute render Y
---@param ctx table UI context (for pressedElement / focusedElement)
---@param rowsToRestore table Table populated with touched row indices
function render.drawContainer(buf, el, rx, ry, ctx, rowsToRestore)
    -- Background + borders
    buf:drawRect(rx, ry, el.w, el.h, " ", el.fore, el.back)
    drawBorder(buf, el, rx, ry, el.borderColor, el.back)

    -- Optional title in the top border
    if el.config.title and el.borderTop then
        local t  = " " .. el.config.title .. " "
        local tx = rx + math.floor((el.w - #t) / 2)
        buf:drawText(tx, ry, t, el.borderColor, el.back)
    end

    for i = 0, el.h - 1 do rowsToRestore[ry + i] = true end

    -- (Re)sort children by z if stale
    if el.childrenDirty then
        el.sortedChildren = {}
        for _, child in pairs(el.children) do
            table.insert(el.sortedChildren, child)
        end
        table.sort(el.sortedChildren, function(a, b) return a.z < b.z end)
        el.childrenDirty = false
    end

    local contentX = rx + (el.borderLeft and 1 or 0)
    local contentY = ry + (el.borderTop  and 1 or 0)
    local contentH = el.h - (el.borderTop  and 1 or 0) - (el.borderBottom and 1 or 0)
    local contentW = el.w - (el.borderLeft and 1 or 0) - (el.borderRight  and 1 or 0)
    local scrollY  = el.scrollOffset or 0

    -- Total content height for scrollbar calculation
    local maxChildBottom = 0
    for _, child in pairs(el.children) do
        local b = child.y + child.h
        if b > maxChildBottom then maxChildBottom = b end
    end

    local needsBar   = maxChildBottom > contentH
    local trackColor = el.config.scrollTrack or "8"
    local thumbColor = el.config.scrollThumb or el.fore

    for _, child in ipairs(el.sortedChildren) do
        if child.visible then
            local childRY = contentY + child.y - scrollY
            if childRY + child.h > contentY and childRY < contentY + contentH then
                buf:setClip(contentX, contentY, contentX + contentW - 1, contentY + contentH - 1)
                render.drawEl(buf, child, contentX + child.x, childRY,
                              ctx.pressedElement, ctx.focusedElement, rowsToRestore)
                buf:clearClip()
            end
        end
    end

    if needsBar then
        drawScrollbar(buf, contentX + contentW - 1, contentY, contentH,
                      scrollY, maxChildBottom, trackColor, thumbColor)
    end
end

return render
