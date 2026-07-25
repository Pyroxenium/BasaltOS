-- Obsidian retained renderer.
--
-- Backwards compatible with the original Buffer API while adding:
--   * logical RGB colors resolved through a sticky terminal palette mapper,
--   * nested translation/clipping contexts,
--   * a 2x3 subpixel canvas compiled into CC mosaic characters,
--   * optional z-sorted surfaces with per-channel transparency.

---@diagnostic disable: undefined-global

local color = require("core.color")
local flimg = require("flimg")

local buffer = {}

local WHITE = color.encode("0")
local BLACK = color.encode("f")
local rep, char = string.rep, string.char

-- table.move is not available in every CraftOS-PC Lua runtime.
local move = table.move or function(source, first, last, targetStart, target)
    target = target or source
    if target == source and targetStart > first and targetStart <= last then
        for i = last, first, -1 do target[targetStart + i - first] = source[i] end
    else
        for i = first, last do target[targetStart + i - first] = source[i] end
    end
    return target
end

local Buffer = {}
Buffer.__index = Buffer

local Surface = {}
Surface.__index = Surface

-- ---------------------------------------------------------------------------
-- Mosaic compiler
-- ---------------------------------------------------------------------------

local mosaicChars = {}
for mask = 0, 31 do mosaicChars[mask] = string.char(128 + mask) end

local mosaicCache = {}

local function nearestOf(value, a, b)
    local v = color.getRGB(value:byte())
    local ar = color.getRGB(a:byte())
    local br = color.getRGB(b:byte())
    local adr, adg, adb = v[1] - ar[1], v[2] - ar[2], v[3] - ar[3]
    local bdr, bdg, bdb = v[1] - br[1], v[2] - br[2], v[3] - br[3]
    local da = adr * adr + adg * adg + adb * adb
    local db = bdr * bdr + bdg * bdg + bdb * bdb
    return da <= db and 0 or 1
end

local function compileMosaic(c1, c2, c3, c4, c5, c6)
    local key = c1 .. c2 .. c3 .. c4 .. c5 .. c6
    local cached = mosaicCache[key]
    if cached then return cached[1], cached[2], cached[3] end

    local values = { c1, c2, c3, c4, c5, c6 }
    local counts, order = {}, {}
    for i = 1, 6 do
        local c = values[i]
        if counts[c] == nil then
            counts[c] = 1
            order[#order + 1] = c
        else
            counts[c] = counts[c] + 1
        end
    end

    local a, b
    for _, c in ipairs(order) do
        if not a or counts[c] > counts[a] then
            b, a = a, c
        elseif not b or counts[c] > counts[b] then
            b = c
        end
    end

    if not b then
        cached = { " ", a, a }
        mosaicCache[key] = cached
        return cached[1], cached[2], cached[3]
    end

    local bits = {}
    for i = 1, 6 do
        local c = values[i]
        if c == a then bits[i] = 0
        elseif c == b then bits[i] = 1
        else bits[i] = nearestOf(c, a, b) end
    end

    local pivot = bits[6]
    local mask = 0
    if bits[1] ~= pivot then mask = mask + 1 end
    if bits[2] ~= pivot then mask = mask + 2 end
    if bits[3] ~= pivot then mask = mask + 4 end
    if bits[4] ~= pivot then mask = mask + 8 end
    if bits[5] ~= pivot then mask = mask + 16 end

    local fg, bg
    if pivot == 0 then fg, bg = b, a else fg, bg = a, b end
    cached = { mosaicChars[mask], fg, bg }
    mosaicCache[key] = cached
    return cached[1], cached[2], cached[3]
end

-- ---------------------------------------------------------------------------
-- Surface internals
-- ---------------------------------------------------------------------------

local function newRows(width, height, textValue, fgValue, bgValue)
    local text, fg, bg = {}, {}, {}
    for y = 1, height do
        local rowT, rowF, rowB = {}, {}, {}
        if textValue ~= nil or fgValue ~= nil or bgValue ~= nil then
            for x = 1, width do
                rowT[x], rowF[x], rowB[x] = textValue, fgValue, bgValue
            end
        end
        text[y], fg[y], bg[y] = rowT, rowF, rowB
    end
    return text, fg, bg
end

local function resetContext(surface)
    local owner = surface._owner
    surface._ox, surface._oy = 0, 0
    surface._clipX1, surface._clipY1 = 1, 1
    surface._clipX2, surface._clipY2 = owner._w, owner._h
    surface._stack, surface._stackN = {}, 0
end

local function markDirty(surface, x1, y1, x2, y2)
    local owner = surface._owner
    x1, y1 = math.max(1, x1), math.max(1, y1)
    x2, y2 = math.min(owner._w, x2), math.min(owner._h, y2)
    if x1 > x2 or y1 > y2 then return end
    if x1 < surface._dirtyX1 then surface._dirtyX1 = x1 end
    if y1 < surface._dirtyY1 then surface._dirtyY1 = y1 end
    if x2 > surface._dirtyX2 then surface._dirtyX2 = x2 end
    if y2 > surface._dirtyY2 then surface._dirtyY2 = y2 end
end

local function resetDirty(surface)
    surface._dirtyX1, surface._dirtyY1 = math.huge, math.huge
    surface._dirtyX2, surface._dirtyY2 = 0, 0
end

local function resetSurface(surface)
    local owner = surface._owner
    if surface._opaque then
        surface._text, surface._fg, surface._bg = newRows(
            owner._w, owner._h, " ", WHITE, BLACK)
    else
        surface._text, surface._fg, surface._bg = newRows(owner._w, owner._h)
    end
    surface._spFg, surface._spBg, surface._spBits = nil, nil, nil
    surface._spX1, surface._spY1 = math.huge, math.huge
    surface._spX2, surface._spY2 = 0, 0
    resetContext(surface)
    resetDirty(surface)
    markDirty(surface, 1, 1, owner._w, owner._h)
end

local function createSurface(owner, name, zIndex, opaque)
    local surface = setmetatable({
        _owner = owner,
        name = name,
        zIndex = zIndex or 0,
        visible = true,
        _opaque = opaque == true,
        _sequence = owner._nextSequence,
    }, Surface)
    owner._nextSequence = owner._nextSequence + 1
    resetSurface(surface)
    return surface
end

local function inClip(surface, x, y)
    return x >= surface._clipX1 and x <= surface._clipX2
        and y >= surface._clipY1 and y <= surface._clipY2
end

local function encodeSurfaceColor(surface, value, nativeDefault)
    if surface._opaque and value == nil then return color.encode(nativeDefault) end
    return color.encode(value)
end

local function ensureSubpixels(surface)
    if surface._spBits then return end
    surface._spFg, surface._spBg, surface._spBits = {}, {}, {}
end

local function virtualClip(surface)
    return (surface._clipX1 - 1) * 2 + 1,
        (surface._clipY1 - 1) * 3 + 1,
        surface._clipX2 * 2,
        surface._clipY2 * 3
end

local function storeSubpixel(surface, vx, vy, encoded, bgEncoded)
    local virtualWidth = surface._owner._w * 2
    local index = (vy - 1) * virtualWidth + vx
    surface._spFg[index] = encoded
    if bgEncoded ~= nil then surface._spBg[index] = bgEncoded end
    surface._spBits[index] = true
end

local function markSubpixelArea(surface, vx1, vy1, vx2, vy2)
    local cellX1 = math.floor((vx1 + 1) / 2)
    local cellY1 = math.floor((vy1 + 2) / 3)
    local cellX2 = math.floor((vx2 + 1) / 2)
    local cellY2 = math.floor((vy2 + 2) / 3)
    if cellX1 < surface._spX1 then surface._spX1 = cellX1 end
    if cellY1 < surface._spY1 then surface._spY1 = cellY1 end
    if cellX2 > surface._spX2 then surface._spX2 = cellX2 end
    if cellY2 > surface._spY2 then surface._spY2 = cellY2 end
    markDirty(surface, cellX1, cellY1, cellX2, cellY2)
end

local function rowValue(row, index)
    if type(row) == "string" then return row:sub(index, index) end
    return row and row[index] or nil
end

-- ---------------------------------------------------------------------------
-- Surface public API
-- ---------------------------------------------------------------------------

function Surface:getSize()
    return self._owner._w, self._owner._h
end

function Surface:getVirtualSize()
    return self._owner._w * 2, self._owner._h * 3
end

function Surface:setVisible(visible)
    visible = visible ~= false
    if self.visible ~= visible then
        self.visible = visible
        self._owner:_markFullComposition()
    end
    return self
end

function Surface:setZIndex(zIndex)
    zIndex = tonumber(zIndex) or 0
    if self.zIndex ~= zIndex then
        self.zIndex = zIndex
        self._owner:_sortLayers()
        self._owner:_markFullComposition()
    end
    return self
end

--- Push a translated local coordinate system and intersect its clip rectangle.
function Surface:push(x, y, width, height)
    x, y = math.floor(x or 1), math.floor(y or 1)
    width, height = math.floor(width or 0), math.floor(height or 0)
    local n, stack = self._stackN, self._stack
    stack[n + 1], stack[n + 2] = self._ox, self._oy
    stack[n + 3], stack[n + 4] = self._clipX1, self._clipY1
    stack[n + 5], stack[n + 6] = self._clipX2, self._clipY2
    self._stackN = n + 6

    local ox, oy = self._ox + x - 1, self._oy + y - 1
    self._ox, self._oy = ox, oy
    self._clipX1 = math.max(self._clipX1, ox + 1)
    self._clipY1 = math.max(self._clipY1, oy + 1)
    self._clipX2 = math.min(self._clipX2, ox + width)
    self._clipY2 = math.min(self._clipY2, oy + height)
    return self
end

function Surface:pop()
    local n, stack = self._stackN, self._stack
    if n < 6 then error("Obsidian Buffer: clip stack underflow", 2) end
    self._ox, self._oy = stack[n - 5], stack[n - 4]
    self._clipX1, self._clipY1 = stack[n - 3], stack[n - 2]
    self._clipX2, self._clipY2 = stack[n - 1], stack[n]
    for i = n - 5, n do stack[i] = nil end
    self._stackN = n - 6
    return self
end

--- Legacy absolute clipping API.
function Surface:setClip(x1, y1, x2, y2)
    local owner = self._owner
    self._clipX1 = math.max(1, math.floor(x1 or 1))
    self._clipY1 = math.max(1, math.floor(y1 or 1))
    self._clipX2 = math.min(owner._w, math.floor(x2 or owner._w))
    self._clipY2 = math.min(owner._h, math.floor(y2 or owner._h))
    return self
end

function Surface:clearClip()
    local owner = self._owner
    self._clipX1, self._clipY1 = 1, 1
    self._clipX2, self._clipY2 = owner._w, owner._h
    return self
end

function Surface:clear(charValue, fore, back)
    local owner = self._owner
    local textValue, fgValue, bgValue
    if self._opaque then
        textValue = charValue == nil and " " or tostring(charValue):sub(1, 1)
        fgValue = color.encode(fore, "0") or WHITE
        bgValue = color.encode(back, "f") or BLACK
    else
        textValue = charValue ~= nil and charValue ~= false
            and tostring(charValue):sub(1, 1) or nil
        fgValue = color.encode(fore)
        bgValue = color.encode(back)
    end
    self._text, self._fg, self._bg = newRows(
        owner._w, owner._h, textValue, fgValue, bgValue)
    self._spFg, self._spBg, self._spBits = nil, nil, nil
    self._spX1, self._spY1 = math.huge, math.huge
    self._spX2, self._spY2 = 0, 0
    markDirty(self, 1, 1, owner._w, owner._h)
    return self
end

function Surface:drawText(x, y, text, fore, back)
    x, y = math.floor(x or 1) + self._ox, math.floor(y or 1) + self._oy
    text = tostring(text or "")
    if y < self._clipY1 or y > self._clipY2 or #text == 0 then return self end

    local sourceStart = 1
    local drawStart, drawEnd = x, x + #text - 1
    if drawStart < self._clipX1 then
        sourceStart = sourceStart + self._clipX1 - drawStart
        drawStart = self._clipX1
    end
    drawEnd = math.min(drawEnd, self._clipX2)
    if drawStart > drawEnd then return self end

    local fgValue = encodeSurfaceColor(self, fore, "0")
    local bgValue = encodeSurfaceColor(self, back, "f")
    local rowT, rowF, rowB = self._text[y], self._fg[y], self._bg[y]
    for tx = drawStart, drawEnd do
        rowT[tx] = text:sub(sourceStart, sourceStart)
        if fgValue ~= nil then rowF[tx] = fgValue end
        if bgValue ~= nil then rowB[tx] = bgValue end
        sourceStart = sourceStart + 1
    end
    markDirty(self, drawStart, y, drawEnd, y)
    return self
end

function Surface:drawLine(y, text, fore, back)
    local width = self._owner._w
    text = tostring(text or "")
    if #text < width then text = text .. rep(" ", width - #text)
    elseif #text > width then text = text:sub(1, width) end
    return self:drawText(1, y, text, fore, back)
end

function Surface:drawRect(x, y, width, height, charValue, fore, back)
    width, height = math.floor(width or 0), math.floor(height or 0)
    if width <= 0 or height <= 0 then return self end
    local ch = tostring(charValue or " ")
    local row
    if #ch == 1 then
        row = rep(ch, width)
    else
        row = (ch .. rep(" ", width)):sub(1, width)
    end
    for dy = 0, height - 1 do self:drawText(x, y + dy, row, fore, back) end
    return self
end

function Surface:drawSprite(frame, x, y, camX, camY)
    if not frame or not frame[1] or not frame[2] or not frame[3] then return self end
    local sx = math.floor((x or 1) - (camX or 0)) + self._ox
    local sy = math.floor((y or 1) - (camY or 0)) + self._oy

    for rowIndex = 1, #frame[1] do
        local ty = sy + rowIndex - 1
        if ty >= self._clipY1 and ty <= self._clipY2 then
            local chars = frame[1][rowIndex]
            local fgs = frame[2][rowIndex]
            local bgs = frame[3][rowIndex]
            local rowLength = type(chars) == "string" and #chars or #(chars or {})
            local rowT, rowF, rowB = self._text[ty], self._fg[ty], self._bg[ty]
            local changedX1, changedX2 = math.huge, 0
            for column = 1, rowLength do
                local tx = sx + column - 1
                if inClip(self, tx, ty) then
                    local didChange = false
                    local c = rowValue(chars, column)
                    local fg = rowValue(fgs, column)
                    local bg = rowValue(bgs, column)
                    if c and c ~= " " then rowT[tx], didChange = c, true end
                    if fg and fg ~= " " then
                        rowF[tx], didChange = color.encode(fg), true
                    end
                    if bg and bg ~= " " then
                        rowB[tx], didChange = color.encode(bg), true
                    end
                    if didChange then
                        if tx < changedX1 then changedX1 = tx end
                        if tx > changedX2 then changedX2 = tx end
                    end
                end
            end
            if changedX1 <= changedX2 then
                markDirty(self, changedX1, ty, changedX2, ty)
            end
        end
    end
    return self
end

local function imagePalette(image)
    if image._obsidianPalette then return image._obsidianPalette end
    local mapped = {}
    for paletteIndex = 1, #image.palette do
        local rgb, encoded = image.palette[paletteIndex]
        for nativeIndex = 0, 15 do
            if rgb == flimg.NATIVE_RGB[nativeIndex] then
                encoded = color.encode(2 ^ nativeIndex)
                break
            end
        end
        mapped[paletteIndex] = encoded or color.encode(color.rgb(rgb))
    end
    image._obsidianPalette = mapped
    image._composedFrames = image._composedFrames or {}
    return mapped
end

--- Draws a FLIMG image at terminal-cell coordinates. Pixel-mode images keep
-- their virtual pixels until the surface is composed; cell-mode images apply
-- channel transparency directly.
function Surface:drawImage(image, x, y, frameIndex, camX, camY)
    if type(image) ~= "table" or image.format ~= "FLIMG" then
        error("Obsidian: drawImage expects a decoded FLIMG image", 2)
    end
    frameIndex = math.max(1, math.min(#image.frames, frameIndex or 1))
    local composed = image._composedFrames and image._composedFrames[frameIndex]
    if not composed then
        composed = flimg.compose(image, frameIndex)
        image._composedFrames = image._composedFrames or {}
        image._composedFrames[frameIndex] = composed
    end
    local palette = imagePalette(image)
    local cellX = math.floor((x or 1) - (camX or 0)) + self._ox
    local cellY = math.floor((y or 1) - (camY or 0)) + self._oy

    if image.mode == "pixel" then
        local clipX1, clipY1, clipX2, clipY2 = virtualClip(self)
        local originX, originY = (cellX - 1) * 2, (cellY - 1) * 3
        local dirtyX1, dirtyY1, dirtyX2, dirtyY2 = math.huge, math.huge, 0, 0
        for sourceY = 1, image.height do
            local targetY = originY + sourceY
            if targetY >= clipY1 and targetY <= clipY2 then
                local row = composed[sourceY]
                for sourceX = 1, image.width do
                    local targetX, paletteIndex = originX + sourceX, row:byte(sourceX)
                    if paletteIndex ~= 0 and targetX >= clipX1 and targetX <= clipX2 then
                        local encoded = palette[paletteIndex]
                        if not encoded then error("Obsidian: FLIMG palette index " .. paletteIndex .. " is missing", 2) end
                        ensureSubpixels(self)
                        storeSubpixel(self, targetX, targetY, encoded)
                        if targetX < dirtyX1 then dirtyX1 = targetX end
                        if targetY < dirtyY1 then dirtyY1 = targetY end
                        if targetX > dirtyX2 then dirtyX2 = targetX end
                        if targetY > dirtyY2 then dirtyY2 = targetY end
                    end
                end
            end
        end
        if dirtyX1 <= dirtyX2 then markSubpixelArea(self, dirtyX1, dirtyY1, dirtyX2, dirtyY2) end
        return self
    end

    for sourceY = 1, image.height do
        local targetY = cellY + sourceY - 1
        if targetY >= self._clipY1 and targetY <= self._clipY2 then
            local line, changedX1, changedX2 = composed[sourceY], math.huge, 0
            for sourceX = 1, image.width do
                local targetX = cellX + sourceX - 1
                if inClip(self, targetX, targetY) then
                    local glyph = line[1]:byte(sourceX)
                    local fgIndex, bgIndex = line[2]:byte(sourceX), line[3]:byte(sourceX)
                    local changed = false
                    if glyph ~= 0 then self._text[targetY][targetX], changed = char(glyph), true end
                    if fgIndex ~= 0 then self._fg[targetY][targetX], changed = palette[fgIndex], true end
                    if bgIndex ~= 0 then self._bg[targetY][targetX], changed = palette[bgIndex], true end
                    if changed then
                        if targetX < changedX1 then changedX1 = targetX end
                        if targetX > changedX2 then changedX2 = targetX end
                    end
                end
            end
            if changedX1 <= changedX2 then markDirty(self, changedX1, targetY, changedX2, targetY) end
        end
    end
    return self
end

function Surface:drawSubpixel(vx, vy, value, bgValue)
    vx, vy = math.floor(vx or 1) + self._ox * 2,
        math.floor(vy or 1) + self._oy * 3
    local clipVx1, clipVy1, clipVx2, clipVy2 = virtualClip(self)
    if vx < clipVx1 or vx > clipVx2 or vy < clipVy1 or vy > clipVy2 then return self end

    local encoded = color.encode(value)
    if not encoded then return self end
    local bgEncoded
    if bgValue ~= nil and bgValue ~= false and bgValue ~= " " then
        bgEncoded = color.encode(bgValue)
    end
    ensureSubpixels(self)
    storeSubpixel(self, vx, vy, encoded, bgEncoded)
    markSubpixelArea(self, vx, vy, vx, vy)
    return self
end

function Surface:drawSubpixelRect(vx, vy, width, height, value, bgValue)
    width, height = math.floor(width or 0), math.floor(height or 0)
    if width <= 0 or height <= 0 then return self end
    local x1 = math.floor(vx or 1) + self._ox * 2
    local y1 = math.floor(vy or 1) + self._oy * 3
    local x2, y2 = x1 + width - 1, y1 + height - 1
    local clipX1, clipY1, clipX2, clipY2 = virtualClip(self)
    x1, y1 = math.max(x1, clipX1), math.max(y1, clipY1)
    x2, y2 = math.min(x2, clipX2), math.min(y2, clipY2)
    if x1 > x2 or y1 > y2 then return self end

    local encoded = color.encode(value)
    if not encoded then return self end
    local bgEncoded
    if bgValue ~= nil and bgValue ~= false and bgValue ~= " " then
        bgEncoded = color.encode(bgValue)
    end
    ensureSubpixels(self)
    for py = y1, y2 do
        for px = x1, x2 do
            storeSubpixel(self, px, py, encoded, bgEncoded)
        end
    end
    markSubpixelArea(self, x1, y1, x2, y2)
    return self
end

function Surface:drawSubpixelLine(x1, y1, x2, y2, value)
    x1, y1 = math.floor(x1) + self._ox * 2, math.floor(y1) + self._oy * 3
    x2, y2 = math.floor(x2) + self._ox * 2, math.floor(y2) + self._oy * 3
    local encoded = color.encode(value)
    if not encoded then return self end
    ensureSubpixels(self)
    local clipX1, clipY1, clipX2, clipY2 = virtualClip(self)
    local boundX1, boundY1 = math.max(clipX1, math.min(x1, x2)), math.max(clipY1, math.min(y1, y2))
    local boundX2, boundY2 = math.min(clipX2, math.max(x1, x2)), math.min(clipY2, math.max(y1, y2))
    local dx, dy = math.abs(x2 - x1), math.abs(y2 - y1)
    local sx, sy = x1 < x2 and 1 or -1, y1 < y2 and 1 or -1
    local err = dx - dy
    while true do
        if x1 >= clipX1 and x1 <= clipX2 and y1 >= clipY1 and y1 <= clipY2 then
            storeSubpixel(self, x1, y1, encoded)
        end
        if x1 == x2 and y1 == y2 then break end
        local twice = 2 * err
        if twice > -dy then err, x1 = err - dy, x1 + sx end
        if twice < dx then err, y1 = err + dx, y1 + sy end
    end
    if boundX1 <= boundX2 and boundY1 <= boundY2 then
        markSubpixelArea(self, boundX1, boundY1, boundX2, boundY2)
    end
    return self
end

Surface.drawPixel = Surface.drawSubpixel

function Surface:clearSubpixels()
    if self._spX1 <= self._spX2 and self._spY1 <= self._spY2 then
        markDirty(self, self._spX1, self._spY1, self._spX2, self._spY2)
    end
    self._spFg, self._spBg, self._spBits = nil, nil, nil
    self._spX1, self._spY1 = math.huge, math.huge
    self._spX2, self._spY2 = 0, 0
    return self
end

function Surface:copyTo(target)
    target.t, target.f, target.b = target.t or {}, target.f or {}, target.b or {}
    local width, height = self._owner._w, self._owner._h
    for y = 1, height do
        target.t[y], target.f[y], target.b[y] = target.t[y] or {}, target.f[y] or {}, target.b[y] or {}
        move(self._text[y], 1, width, 1, target.t[y])
        move(self._fg[y], 1, width, 1, target.f[y])
        move(self._bg[y], 1, width, 1, target.b[y])
    end
    if self._spBits then
        local size = width * 2 * height * 3
        target.spFg, target.spBg, target.spBits = {}, {}, {}
        move(self._spFg, 1, size, 1, target.spFg)
        move(self._spBg, 1, size, 1, target.spBg)
        move(self._spBits, 1, size, 1, target.spBits)
    else
        target.spFg, target.spBg, target.spBits = nil, nil, nil
    end
    return target
end

function Surface:copyFrom(source)
    local width, height = self._owner._w, self._owner._h
    for y = 1, height do
        if source.t and source.t[y] then
            move(source.t[y], 1, width, 1, self._text[y])
            move(source.f[y], 1, width, 1, self._fg[y])
            move(source.b[y], 1, width, 1, self._bg[y])
        end
    end
    if source.spBits then
        local size = width * 2 * height * 3
        self._spFg, self._spBg, self._spBits = {}, {}, {}
        move(source.spFg, 1, size, 1, self._spFg)
        move(source.spBg, 1, size, 1, self._spBg)
        move(source.spBits, 1, size, 1, self._spBits)
        self._spX1, self._spY1, self._spX2, self._spY2 = 1, 1, width, height
    else
        self._spFg, self._spBg, self._spBits = nil, nil, nil
        self._spX1, self._spY1, self._spX2, self._spY2 = math.huge, math.huge, 0, 0
    end
    markDirty(self, 1, 1, width, height)
    return self
end

function Surface:restoreLine(y, source)
    local width, height = self._owner._w, self._owner._h
    if y < 1 or y > height or not source.t or not source.t[y] then return self end
    move(source.t[y], 1, width, 1, self._text[y])
    move(source.f[y], 1, width, 1, self._fg[y])
    move(source.b[y], 1, width, 1, self._bg[y])
    local virtualWidth = width * 2
    if source.spBits then ensureSubpixels(self) end
    if self._spBits then
        for subRow = (y - 1) * 3 + 1, y * 3 do
            local first = (subRow - 1) * virtualWidth + 1
            local last = first + virtualWidth - 1
            if source.spBits then
                move(source.spFg, first, last, first, self._spFg)
                move(source.spBg, first, last, first, self._spBg)
                move(source.spBits, first, last, first, self._spBits)
            else
                for index = first, last do
                    self._spFg[index], self._spBg[index], self._spBits[index] = nil, nil, nil
                end
            end
        end
        -- Extents are deliberately conservative; they are only used to dirty
        -- the correct area when clearSubpixels() is called later.
        self._spX1, self._spY1, self._spX2, self._spY2 = 1, 1, width, height
    end
    markDirty(self, 1, y, width, y)
    return self
end

function Surface:present()
    return self._owner:present()
end

-- ---------------------------------------------------------------------------
-- Buffer / compositor
-- ---------------------------------------------------------------------------

local function initComposite(self)
    self._screenT, self._screenF, self._screenB = newRows(
        self._w, self._h, " ", WHITE, BLACK)
    self._lastT, self._lastF, self._lastB = {}, {}, {}
    self._dirty = {}
    for y = 1, self._h do self._dirty[y] = true end
end

function buffer.new(width, height, targetTerm)
    if type(width) == "table" then
        targetTerm, width, height = width, nil, nil
    end
    local target = targetTerm or term
    local terminalWidth, terminalHeight = target.getSize()
    local self = setmetatable({
        _term = target,
        _w = width or terminalWidth,
        _h = height or terminalHeight,
        _layers = {},
        _layerByName = {},
        _nextSequence = 1,
        _fullComposition = true,
        BufferModule = buffer,
    }, Buffer)
    self._mapper = color.newMapper(target)
    self._default = createSurface(self, "default", 0, true)
    self._layers[1], self._layerByName.default = self._default, self._default
    initComposite(self)
    return self
end

function Buffer:_sortLayers()
    table.sort(self._layers, function(a, b)
        if a.zIndex == b.zIndex then return a._sequence < b._sequence end
        return a.zIndex < b.zIndex
    end)
end

function Buffer:_markFullComposition()
    self._fullComposition = true
    for y = 1, self._h do self._dirty[y] = true end
end

function Buffer:getSize()
    return self._w, self._h
end

function Buffer:getVirtualSize()
    return self._w * 2, self._h * 3
end

function Buffer:setSize(width, height)
    width, height = math.floor(width), math.floor(height)
    if width < 1 or height < 1 then return self end
    self._w, self._h = width, height
    for _, layer in ipairs(self._layers) do resetSurface(layer) end
    initComposite(self)
    self._fullComposition = true
    return self
end

function Buffer:getTarget()
    return self._term
end

function Buffer:addLayer(name, zIndex)
    assert(type(name) == "string" and name ~= "", "Buffer:addLayer requires a name")
    if self._layerByName[name] then
        error("Obsidian Buffer: layer already exists: " .. name, 2)
    end
    local layer = createSurface(self, name, zIndex or 0, false)
    self._layers[#self._layers + 1] = layer
    self._layerByName[name] = layer
    self:_sortLayers()
    self:_markFullComposition()
    return layer
end

Buffer.createLayer = Buffer.addLayer

function Buffer:getLayer(name)
    return self._layerByName[name]
end

function Buffer:getLayers()
    local result = {}
    for i, layer in ipairs(self._layers) do result[i] = layer end
    return result
end

function Buffer:removeLayer(layerOrName)
    local layer = type(layerOrName) == "string" and self._layerByName[layerOrName]
        or layerOrName
    if not layer or layer == self._default then return false end
    for i, item in ipairs(self._layers) do
        if item == layer then table.remove(self._layers, i); break end
    end
    self._layerByName[layer.name] = nil
    self:_markFullComposition()
    return true
end

function Buffer:getDefaultLayer()
    return self._default
end

local function flushPixels(pixels)
    return compileMosaic(pixels[1], pixels[2], pixels[3],
        pixels[4], pixels[5], pixels[6])
end

function Buffer:_composeCell(x, y)
    local outT, outF, outB = " ", WHITE, BLACK
    local pixels
    local spIndices

    for _, layer in ipairs(self._layers) do
        if layer.visible then
            local lt, lf, lb = layer._text[y][x], layer._fg[y][x], layer._bg[y][x]
            if lt ~= nil or lf ~= nil or lb ~= nil then
                if pixels then
                    outT, outF, outB = flushPixels(pixels)
                    pixels = nil
                end
                if lt ~= nil then outT = lt end
                if lf ~= nil then outF = lf end
                if lb ~= nil then outB = lb end
            end

            if layer._spBits then
                if not spIndices then
                    local virtualWidth = self._w * 2
                    local vy1 = (y - 1) * 3 + 1
                    local vx1 = (x - 1) * 2 + 1
                    spIndices = {
                        (vy1 - 1) * virtualWidth + vx1,
                        (vy1 - 1) * virtualWidth + vx1 + 1,
                        vy1 * virtualWidth + vx1,
                        vy1 * virtualWidth + vx1 + 1,
                        (vy1 + 1) * virtualWidth + vx1,
                        (vy1 + 1) * virtualWidth + vx1 + 1,
                    }
                end
                local hasSubpixels = false
                for i = 1, 6 do
                    local index = spIndices[i]
                    if layer._spBits[index] or layer._spBg[index] ~= nil then
                        hasSubpixels = true
                        break
                    end
                end
                if hasSubpixels then
                    if not pixels then pixels = { outB, outB, outB, outB, outB, outB } end
                    for i = 1, 6 do
                        local index = spIndices[i]
                        if layer._spBits[index] then
                            pixels[i] = layer._spFg[index] or outF
                        elseif layer._spBg[index] ~= nil then
                            pixels[i] = layer._spBg[index]
                        end
                    end
                end
            end
        end
    end

    if pixels then outT, outF, outB = flushPixels(pixels) end
    return outT, outF, outB
end

function Buffer:_compose()
    local x1, y1, x2, y2 = math.huge, math.huge, 0, 0
    if self._fullComposition then
        x1, y1, x2, y2 = 1, 1, self._w, self._h
    else
        for _, layer in ipairs(self._layers) do
            if layer._dirtyX1 < x1 then x1 = layer._dirtyX1 end
            if layer._dirtyY1 < y1 then y1 = layer._dirtyY1 end
            if layer._dirtyX2 > x2 then x2 = layer._dirtyX2 end
            if layer._dirtyY2 > y2 then y2 = layer._dirtyY2 end
        end
    end
    if x1 > x2 or y1 > y2 then return false end

    x1, y1 = math.max(1, x1), math.max(1, y1)
    x2, y2 = math.min(self._w, x2), math.min(self._h, y2)
    for y = y1, y2 do
        local rowT, rowF, rowB = self._screenT[y], self._screenF[y], self._screenB[y]
        for x = x1, x2 do
            rowT[x], rowF[x], rowB[x] = self:_composeCell(x, y)
        end
        self._dirty[y] = true
    end
    for _, layer in ipairs(self._layers) do resetDirty(layer) end
    self._fullComposition = false
    return true
end

local function scanColors(row, used)
    for x = 1, #row do used[row:byte(x)] = true end
end

function Buffer:present()
    self:_compose()

    local hasDirty = false
    for y = 1, self._h do
        if self._dirty[y] then hasDirty = true; break end
    end
    if not hasDirty then return self end

    local logicalT, logicalF, logicalB = {}, {}, {}
    local used = {}
    for y = 1, self._h do
        logicalT[y] = table.concat(self._screenT[y])
        logicalF[y] = table.concat(self._screenF[y])
        logicalB[y] = table.concat(self._screenB[y])
        scanColors(logicalF[y], used)
        scanColors(logicalB[y], used)
    end

    local map, force = self._mapper:build(used)
    for y = 1, self._h do
        if force or self._dirty[y] then
            local text, fg, bg = logicalT[y], logicalF[y], logicalB[y]
            if force or text ~= self._lastT[y] or fg ~= self._lastF[y] or bg ~= self._lastB[y] then
                self._term.setCursorPos(1, y)
                self._term.blit(text, (fg:gsub(".", map)), (bg:gsub(".", map)))
                self._lastT[y], self._lastF[y], self._lastB[y] = text, fg, bg
            end
            self._dirty[y] = false
        end
    end
    return self
end

Buffer.flush = Buffer.present

function Buffer:invalidate()
    self._lastT, self._lastF, self._lastB = {}, {}, {}
    self:_markFullComposition()
    return self
end


function Buffer:restorePalette()
    self._mapper:restore()
    return self
end

function Buffer:compileSubpixels()
    self:_compose()
    return self
end

-- Legacy drawing methods target the opaque default surface.
local delegated = {
    "push", "pop", "setClip", "clearClip", "clear",
    "drawText", "drawLine", "drawRect", "drawSprite",
    "drawImage",
    "drawSubpixel", "drawSubpixelRect", "drawSubpixelLine",
    "drawPixel", "clearSubpixels", "copyTo", "copyFrom", "restoreLine",
}
for _, method in ipairs(delegated) do
    Buffer[method] = function(self, ...)
        return self._default[method](self._default, ...)
    end
end

buffer.rgb = color.rgb
buffer.color = color
buffer.Buffer = Buffer
buffer.Surface = Surface

return buffer
