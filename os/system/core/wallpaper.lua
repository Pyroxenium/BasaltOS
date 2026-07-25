-- /system/core/wallpaper.lua
-- Resolution-independent BasaltOS desktop wallpaper generator.

local wallpaper = {}

local cache = {}
local cache_order = {}
local CACHE_LIMIT = 12

local function colorBlit(value, fallback)
    value = value or fallback
    if colors.toBlit then
        local ok, result = pcall(colors.toBlit, value)
        if ok and type(result) == "string" then return result end
    end
    return value == colors.white and "0" or "f"
end

local function remember(key, value)
    if cache[key] then return value end
    cache[key] = value
    cache_order[#cache_order + 1] = key
    while #cache_order > CACHE_LIMIT do
        cache[table.remove(cache_order, 1)] = nil
    end
    return value
end

local function samplePattern(pixel_x, pixel_y, pixel_width, pixel_height, palette)
    local nx = (pixel_x - 0.5) / pixel_width
    local ny = (pixel_y - 0.5) / pixel_height
    local curve = 0.50
        + 0.10 * math.sin((nx * 1.55 + 0.08) * math.pi)
        + 0.13 * nx
    local accent_curve = curve + 0.24

    if ny >= accent_curve then return palette.accent end
    if ny >= curve then return palette.surface end
    return palette.background
end

local function encodeCell(pixels, palette)
    local background = pixels[6]
    local foreground = background
    for index = 1, 5 do
        if pixels[index] ~= background then
            foreground = pixels[index]
            break
        end
    end

    if foreground == background then
        local blit = colorBlit(background, palette.background)
        return " ", blit, blit
    end

    local mask = 0
    local weights = {1, 2, 4, 8, 16}
    for index = 1, 5 do
        if pixels[index] == foreground then mask = mask + weights[index] end
    end
    return string.char(128 + mask),
        colorBlit(foreground, palette.background),
        colorBlit(background, palette.background)
end

--- Generates a BIMG frame exactly matching the requested terminal size.
---@param width number Width in terminal cells
---@param height number Height in terminal cells
---@param options table|nil background, surface, accent and style
---@return table bimg
function wallpaper.generate(width, height, options)
    options = options or {}
    width = math.max(1, math.floor(tonumber(width) or 1))
    height = math.max(1, math.floor(tonumber(height) or 1))
    local palette = {
        background=options.background or colors.white,
        surface=options.surface or colors.lightGray,
        accent=options.accent or colors.blue,
    }
    local style = options.style or "pattern"
    local key = table.concat({
        style, width, height,
        tostring(palette.background), tostring(palette.surface), tostring(palette.accent),
    }, ":")
    if cache[key] then return cache[key] end

    local pixel_width, pixel_height = width * 2, height * 3
    local frame = {}
    local offsets = {
        {0, 0}, {1, 0}, {0, 1}, {1, 1}, {0, 2}, {1, 2},
    }

    for cell_y = 1, height do
        local text, foregrounds, backgrounds = {}, {}, {}
        for cell_x = 1, width do
            local pixels = {}
            for index, offset in ipairs(offsets) do
                if style == "solid" then
                    pixels[index] = palette.background
                else
                    pixels[index] = samplePattern(
                        (cell_x - 1) * 2 + offset[1] + 1,
                        (cell_y - 1) * 3 + offset[2] + 1,
                        pixel_width, pixel_height, palette
                    )
                end
            end
            text[cell_x], foregrounds[cell_x], backgrounds[cell_x] =
                encodeCell(pixels, palette)
        end
        frame[cell_y] = {
            table.concat(text),
            table.concat(foregrounds),
            table.concat(backgrounds),
        }
    end

    local result = {frame}
    result.basaltOSWallpaper = 1
    return remember(key, result)
end

function wallpaper.clearCache()
    cache = {}
    cache_order = {}
end

return wallpaper
