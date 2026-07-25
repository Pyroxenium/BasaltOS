-- Obsidian logical color registry and terminal palette mapper.
--
-- Render surfaces store one registry index per color cell as a raw byte. The
-- mapper assigns visible registry colors to the terminal's 16 hardware slots
-- only when a frame is presented. Native blit colors keep their slots while
-- custom RGB colors reuse currently invisible native slots.

---@diagnostic disable: undefined-global

local color = {}

local floor = math.floor
local char = string.char

local NATIVE_HEX = {
    [0] = 0xF0F0F0, 0xF2B233, 0xE57FD8, 0x99B2F2,
    0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x4C4C4C,
    0x999999, 0x4C99B2, 0xB266E5, 0x3366CC,
    0x7F664C, 0x57A64E, 0xCC4C4C, 0x111111,
}

local HEX = {}
local HEX_TO_INDEX = {}
local NATIVE_VALUE_TO_INDEX = {}
for i = 0, 15 do
    local h = ("%x"):format(i)
    HEX[i] = h
    HEX_TO_INDEX[h] = i
    HEX_TO_INDEX[h:upper()] = i
    NATIVE_VALUE_TO_INDEX[2 ^ i] = i
end

local function hexToRGB(n)
    return floor(n / 65536) / 255,
        floor(n / 256) % 256 / 255,
        (n % 256) / 255
end

local registry = {}
for i = 0, 15 do registry[i] = { hexToRGB(NATIVE_HEX[i]) } end

local nextIndex = 16
local dedupe = {}
local HANDLE_BASE = 0x1000000

for i = 0, 15 do dedupe[NATIVE_HEX[i]] = i end

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function parseRGB(r, g, b)
    if type(r) == "string" then
        local value = r:gsub("#", "")
        if value:match("^%x%x%x$") then
            value = value:sub(1, 1):rep(2)
                .. value:sub(2, 2):rep(2)
                .. value:sub(3, 3):rep(2)
        elseif value:match("^%x%x%x%x%x%x%x%x$") then
            value = value:sub(3)
        elseif not value:match("^%x%x%x%x%x%x$") then
            error("Obsidian: invalid RGB color '" .. tostring(r)
                .. "' (expected #RGB, #RRGGBB or #AARRGGBB)", 3)
        end
        return hexToRGB(tonumber(value, 16))
    end

    if type(r) ~= "number" then
        error("Obsidian: invalid color value " .. tostring(r), 3)
    end

    if g == nil then
        if r < 0 or r > 0xFFFFFF or r % 1 ~= 0 then
            error("Obsidian: invalid RGB number " .. tostring(r)
                .. " (expected 0x000000-0xFFFFFF)", 3)
        end
        return hexToRGB(r)
    end

    if type(g) ~= "number" or type(b) ~= "number" then
        error("Obsidian: rgb requires three numeric components", 3)
    end
    if r > 1 or g > 1 or b > 1 then
        r, g, b = r / 255, g / 255, b / 255
    end
    return clamp01(r), clamp01(g), clamp01(b)
end

local function registerRGB(r, g, b)
    local rr, gg, bb = parseRGB(r, g, b)
    local key = floor(rr * 255 + 0.5) * 65536
        + floor(gg * 255 + 0.5) * 256
        + floor(bb * 255 + 0.5)
    local known = dedupe[key]
    if known then return known end
    if nextIndex > 255 then
        local best, bestDistance = 0, math.huge
        for index = 0, 255 do
            local rgb = registry[index]
            local distance = (rr - rgb[1]) ^ 2 + (gg - rgb[2]) ^ 2 + (bb - rgb[3]) ^ 2
            if distance < bestDistance then best, bestDistance = index, distance end
        end
        dedupe[key] = best
        return best
    end
    local idx = nextIndex
    nextIndex = nextIndex + 1
    registry[idx] = { rr, gg, bb }
    dedupe[key] = idx
    return idx
end

--- Register a reusable custom RGB color.
--- Accepts 0xRRGGBB, #RGB/#RRGGBB, 0-1 floats or 0-255 components.
---@return number handle Opaque color handle accepted by all draw methods.
function color.rgb(r, g, b)
    return HANDLE_BASE + registerRGB(r, g, b)
end

local function indexOf(value)
    if value == nil or value == false or value == " " then return nil end

    if type(value) == "string" then
        if #value == 1 and HEX_TO_INDEX[value] ~= nil then
            return HEX_TO_INDEX[value]
        end
        return registerRGB(value)
    end

    if type(value) == "number" then
        if value >= HANDLE_BASE then
            local idx = value - HANDLE_BASE
            if idx >= 0 and idx <= 255 and registry[idx] then return idx end
            error("Obsidian: invalid RGB color handle " .. tostring(value), 3)
        end
        local native = NATIVE_VALUE_TO_INDEX[value]
        if native ~= nil then return native end
        return registerRGB(value)
    end

    error("Obsidian: unsupported color value " .. tostring(value), 3)
end

--- Encode a public color as a one-byte registry value.
---@param value any
---@param default any|nil Used only when value is nil.
---@return string|nil byte
function color.encode(value, default)
    if value == nil then value = default end
    local idx = indexOf(value)
    return idx ~= nil and char(idx) or nil
end

function color.indexOf(value)
    return indexOf(value)
end

function color.getRGB(index)
    return registry[index]
end

color.identityMap = {}
for i = 0, 15 do color.identityMap[char(i)] = HEX[i] end

local Mapper = {}
Mapper.__index = Mapper

local function rgbDistance(a, b)
    local dr, dg, db = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return dr * dr + dg * dg + db * db
end

local function readPalette(t, index)
    local getter = t.getPaletteColour or t.getPaletteColor
    if getter then
        local ok, r, g, b = pcall(getter, 2 ^ index)
        if ok and r ~= nil then return { r, g, b } end
    end
    return { hexToRGB(NATIVE_HEX[index]) }
end

--- Create a sticky palette mapper for one terminal-like target.
function color.newMapper(t)
    local native = {}
    for i = 0, 15 do native[i] = readPalette(t, i) end
    return setmetatable({
        term = t,
        native = native,
        overridden = {},
        previousSlot = {},
        previousMap = {},
    }, Mapper)
end

local function setPalette(mapper, slot, rgb, registryIndex)
    local setter = mapper.term.setPaletteColour or mapper.term.setPaletteColor
    if not setter then return end
    if mapper.overridden[slot] == registryIndex then return end
    setter(2 ^ slot, rgb[1], rgb[2], rgb[3])
    mapper.overridden[slot] = registryIndex
end

--- Build a registry-byte -> blit-character map for the visible colors.
---@param used table<number, boolean>
---@return table map
---@return boolean forceRedraw
function Mapper:build(used)
    local setter = self.term.setPaletteColour or self.term.setPaletteColor
    local map, occupant = {}, {}

    -- Visible native colors own their conventional slots.
    for i = 0, 15 do
        map[char(i)] = HEX[i]
        if used[i] then
            occupant[i] = i
            if setter and self.overridden[i] ~= nil then
                setter(2 ^ i, self.native[i][1], self.native[i][2], self.native[i][3])
                self.overridden[i] = nil
            end
        end
    end

    local custom = {}
    for idx in pairs(used) do
        if idx > 15 then custom[#custom + 1] = idx end
    end
    table.sort(custom)

    local leftovers = {}
    if setter then
        local function assign(idx, slot)
            occupant[slot] = idx
            self.previousSlot[idx] = slot
            setPalette(self, slot, registry[idx], idx)
            map[char(idx)] = HEX[slot]
        end

        local pending = {}
        for _, idx in ipairs(custom) do
            local slot = self.previousSlot[idx]
            if slot ~= nil and occupant[slot] == nil then
                assign(idx, slot)
            else
                pending[#pending + 1] = idx
            end
        end

        local nextSlot = 0
        for _, idx in ipairs(pending) do
            while nextSlot <= 15 and occupant[nextSlot] ~= nil do
                nextSlot = nextSlot + 1
            end
            if nextSlot <= 15 then
                assign(idx, nextSlot)
                nextSlot = nextSlot + 1
            else
                leftovers[#leftovers + 1] = idx
            end
        end
    else
        -- Without palette support every hardware slot displays its native RGB.
        for i = 0, 15 do occupant[i] = i end
        leftovers = custom
    end

    -- Colors beyond the available slots use the nearest visible color.
    for _, idx in ipairs(leftovers) do
        local bestSlot, bestDistance = 15, math.huge
        for slot = 0, 15 do
            local shownIndex = occupant[slot]
            if shownIndex ~= nil then
                local shown = shownIndex <= 15 and self.native[shownIndex]
                    or registry[shownIndex]
                local distance = rgbDistance(registry[idx], shown)
                if distance < bestDistance then
                    bestSlot, bestDistance = slot, distance
                end
            end
        end
        map[char(idx)] = HEX[bestSlot]
    end

    local force = false
    for byte, slot in pairs(map) do
        local previous = self.previousMap[byte]
        if previous ~= nil and previous ~= slot then
            force = true
            break
        end
    end
    self.previousMap = map
    return map, force
end

--- Restore all palette slots changed by this mapper.
function Mapper:restore()
    local setter = self.term.setPaletteColour or self.term.setPaletteColor
    if setter then
        for slot in pairs(self.overridden) do
            local rgb = self.native[slot]
            setter(2 ^ slot, rgb[1], rgb[2], rgb[3])
        end
    end
    self.overridden, self.previousSlot, self.previousMap = {}, {}, {}
end

return color
