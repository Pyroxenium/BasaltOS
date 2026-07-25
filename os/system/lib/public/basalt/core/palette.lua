-- Color engine for Basalt: more than 16 colors on a 16-color terminal.
--
-- Every color that can appear on screen is an entry in a global registry
-- (index 0-255). Indices 0-15 are the native CC colors; palette.rgb()
-- registers custom colors above that. The render buffer stores registry
-- indices as raw bytes. At flush time a per-terminal Mapper assigns the 16
-- hardware palette slots to whatever registry colors are actually visible:
--  * native colors always keep their own slot,
--  * custom colors take over the slots of native colors that are NOT
--    currently on screen (via term.setPaletteColour),
--  * anything beyond 16 simultaneous colors falls back to the nearest
--    currently-assigned color.
-- Slot assignments are sticky between frames to avoid palette flicker.

local palette = {}

local floor = math.floor
local char = string.char

-- Native CC:Tweaked palette, indexed by log2 of the colors.* constant.
local NATIVE_HEX = {
    [0] = 0xF0F0F0, 0xF2B233, 0xE57FD8, 0x99B2F2,
    0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x4C4C4C,
    0x999999, 0x4C99B2, 0xB266E5, 0x3366CC,
    0x7F664C, 0x57A64E, 0xCC4C4C, 0x111111,
}

local reg = {}       -- registry index -> {r, g, b} (floats 0-1)
local regCount = 16  -- next free registry index
local charOf = {}    -- public color value -> 1-byte string (registry index)
local dedupe = {}    -- rgb24 -> existing handle

local function hexToRGB(n)
    return floor(n / 65536) / 255, floor(n / 256) % 256 / 255, (n % 256) / 255
end

for i = 0, 15 do
    reg[i] = { hexToRGB(NATIVE_HEX[i]) }
    charOf[2 ^ i] = char(i)
    dedupe[NATIVE_HEX[i]] = 2 ^ i
end

palette.charOf = charOf

--- Resolves a registry byte/index or public color handle to RGB floats.
---@param value string|number Registry byte, registry index, or colors.* handle
---@return number r, number g, number b
function palette.getRGB(value)
    local index
    if type(value) == "string" then
        index = value:byte()
    elseif charOf[value] then
        index = charOf[value]:byte()
    else
        index = value
    end
    local rgb = reg[index]
    if not rgb then error("Basalt: unknown registry color " .. tostring(value), 2) end
    return rgb[1], rgb[2], rgb[3]
end

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function parse(r, g, b)
    if type(r) == "string" then
        local hex = r:gsub("#", "")
        if hex:match("^%x%x%x$") then -- #RGB shorthand
            hex = hex:gsub("%x", "%0%0")
        elseif hex:match("^%x%x%x%x%x%x%x%x$") then -- #AARRGGBB: ignore alpha
            hex = hex:sub(3)
        elseif not hex:match("^%x%x%x%x%x%x$") then
            error("Basalt: invalid color string '" .. r
                .. "' (expected #RGB, #RRGGBB or #AARRGGBB)", 3)
        end
        return hexToRGB(tonumber(hex, 16))
    end
    if g == nil then
        if r < 0 or r > 0xFFFFFF or r % 1 ~= 0 then
            error("Basalt: invalid color number "
                .. tostring(r) .. " (expected 0x000000-0xFFFFFF)", 3)
        end
        return hexToRGB(r)
    end
    if r > 1 or g > 1 or b > 1 then
        r, g, b = r / 255, g / 255, b / 255
    end
    return clamp01(r), clamp01(g), clamp01(b)
end

--- Registers (or reuses) a custom color and returns a handle usable anywhere
--- a colors.* value is accepted.
--- Accepts: rgb floats 0-1, rgb ints 0-255, 0xRRGGBB, or "#RRGGBB".
--- Registers or resolves an RGB color for use by the render buffer.
---@param r number|string Red component or #RRGGBB string
---@param g number|nil Green component
---@param b number|nil Blue component
---@return number color
function palette.rgb(r, g, b)
    local rr, gg, bb = parse(r, g, b)
    local key = floor(rr * 255 + 0.5) * 65536 + floor(gg * 255 + 0.5) * 256 + floor(bb * 255 + 0.5)
    local known = dedupe[key]
    if known then return known end

    if regCount > 255 then
        local best, bestDistance = 0, math.huge
        for index = 0, 255 do
            local rgb = reg[index]
            local distance = (rr - rgb[1]) ^ 2 + (gg - rgb[2]) ^ 2 + (bb - rgb[3]) ^ 2
            if distance < bestDistance then best, bestDistance = index, distance end
        end
        local fallback = best < 16 and 2 ^ best or 0x10000 + best
        dedupe[key] = fallback
        return fallback
    end
    local idx = regCount
    regCount = regCount + 1
    reg[idx] = { rr, gg, bb }

    local handle = 0x10000 + idx
    charOf[handle] = char(idx)
    dedupe[key] = handle
    return handle
end

--- True once any custom color has been registered.
--- Returns whether custom palette colors are currently registered.
---@return boolean hasCustomColors
function palette.hasVirtual()
    return regCount > 16
end

local HEXC = {}
for i = 0, 15 do HEXC[i] = ("%x"):format(i) end

-- Translation used when only native colors exist (byte -> blit hex char).
local identity = {}
for i = 0, 15 do identity[char(i)] = HEXC[i] end
palette.identityMap = identity

----------------------------------------------------------------------------
-- Hosted window translation (Program element)
--
-- A program running inside an invisible CC window may manage the window's
-- 16-slot palette itself (Obsidian's renderer does). Those palette calls
-- never reach the hardware: only the window's blit characters are copied
-- into the render buffer, and this module then restores the native colors
-- because the characters look like plain native slots. windowTranslation()
-- bridges the gap: it reads the palette stored in the window, registers
-- every deviating slot as a Basalt RGB color, and returns a blit-hex ->
-- registry-byte table, so the hosted program's colors take part in the
-- normal slot assignment instead of being discarded.
----------------------------------------------------------------------------

local HEX2BYTE = {}
for i = 0, 15 do
    HEX2BYTE[HEXC[i]] = char(i)
    HEX2BYTE[HEXC[i]:upper()] = char(i)
end
palette.hexToByte = HEX2BYTE

--- Builds a blit-hex -> registry-byte translation for a hosted CC window.
--- Returns nil when the window palette is untouched (identity is cheaper).
---@param win table CC window (or any terminal-like object with a palette)
---@return table<string, string>|nil translate
function palette.windowTranslation(win)
    local getPal = win.getPaletteColour or win.getPaletteColor
    if not getPal then return nil end
    local translate
    for i = 0, 15 do
        local ok, r, g, b = pcall(getPal, 2 ^ i)
        if ok and type(r) == "number" and type(g) == "number"
            and type(b) == "number" then
            local nr, ng, nb = palette.getRGB(i)
            if math.abs(r - nr) + math.abs(g - ng) + math.abs(b - nb) > 0.004 then
                if not translate then
                    translate = {}
                    for k, v in pairs(HEX2BYTE) do translate[k] = v end
                end
                local byte = charOf[palette.rgb(r, g, b)]
                translate[HEXC[i]] = byte
                translate[HEXC[i]:upper()] = byte
            end
        end
    end
    return translate
end

----------------------------------------------------------------------------
-- Mapper: per-terminal palette slot allocator
----------------------------------------------------------------------------

---@class Mapper
local Mapper = {}
Mapper.__index = Mapper

--- Creates a palette mapper for one terminal.
---@param t table Terminal-like object
---@return table mapper
function palette.newMapper(t)
    return setmetatable({
        term = t,
        overridden = {}, -- slot -> registry idx whose rgb is currently loaded
        prevSlot = {},   -- registry idx -> slot it had last time (stickiness)
        prevMap = {},
    }, Mapper)
end

local function dist(a, b)
    local dr, dg, db = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return dr * dr + dg * dg + db * db
end

--- Assigns hardware palette slots for the set of used registry indices and
--- returns (map, changed): a byte->hex translation table and whether any
--- still-visible color moved to a different slot (forces a full redraw).
---@param used table<number, boolean> Registry indices used by this frame
---@return table<number, string> map Registry byte to terminal blit character
---@return boolean changed
function Mapper:build(used)
    local t = self.term
    local setPal = t.setPaletteColour or t.setPaletteColor
    local map = {}
    local occupant = {} -- slot -> registry idx displayed in that slot

    -- Native colors own their slot; restore their rgb if we overrode it.
    for i = 0, 15 do
        map[char(i)] = HEXC[i]
        if used[i] then
            occupant[i] = i
            if setPal and self.overridden[i] then
                local n = reg[i]
                setPal(2 ^ i, n[1], n[2], n[3])
                self.overridden[i] = nil
            end
        end
    end

    local virt = {}
    for idx in pairs(used) do
        if idx > 15 then virt[#virt + 1] = idx end
    end

    if #virt > 0 then
        table.sort(virt) -- deterministic assignment order
        local leftovers = {}

        if setPal then
            local function assign(idx, slot)
                occupant[slot] = idx
                self.prevSlot[idx] = slot
                if self.overridden[slot] ~= idx then
                    local c = reg[idx]
                    setPal(2 ^ slot, c[1], c[2], c[3])
                    self.overridden[slot] = idx
                end
                map[char(idx)] = HEXC[slot]
            end

            -- Sticky pass: keep last frame's slot when it is still free.
            local pending = {}
            for _, idx in ipairs(virt) do
                local s = self.prevSlot[idx]
                if s and occupant[s] == nil then
                    assign(idx, s)
                else
                    pending[#pending + 1] = idx
                end
            end

            -- Fresh pass: hand out any remaining free slots.
            local nextSlot = 0
            for _, idx in ipairs(pending) do
                local slot
                while nextSlot <= 15 do
                    if occupant[nextSlot] == nil then
                        slot = nextSlot
                        break
                    end
                    nextSlot = nextSlot + 1
                end
                if slot then
                    assign(idx, slot)
                else
                    leftovers[#leftovers + 1] = idx
                end
            end
        else
            leftovers = virt -- ancient terminal: no palette support at all
        end

        -- Whatever didn't get a slot maps to the closest visible color.
        for _, idx in ipairs(leftovers) do
            local c = reg[idx]
            local best, bestD = 15, math.huge
            for s = 0, 15 do
                local occ = occupant[s]
                -- Without setPal every slot shows its native color; with it,
                -- only occupied slots have a known color this frame.
                local shown = occ and reg[occ] or (not setPal and reg[s] or nil)
                if shown then
                    local d = dist(c, shown)
                    if d < bestD then best, bestD = s, d end
                end
            end
            map[char(idx)] = HEXC[best]
        end
    end

    -- A full redraw is needed if a color that stays on screen changed slots.
    local changed = false
    local prev = self.prevMap
    for k, v in pairs(map) do
        if prev[k] ~= nil and prev[k] ~= v then
            changed = true
            break
        end
    end
    self.prevMap = map
    return map, changed
end

--- Restores every palette slot we overrode back to its native color.
--- Restores terminal palette colors changed by this mapper.
---@return self
function Mapper:restore()
    local t = self.term
    local setPal = t.setPaletteColour or t.setPaletteColor
    if setPal then
        for slot in pairs(self.overridden) do
            local n = reg[slot]
            setPal(2 ^ slot, n[1], n[2], n[3])
        end
    end
    self.overridden, self.prevSlot, self.prevMap = {}, {}, {}
end

return palette
