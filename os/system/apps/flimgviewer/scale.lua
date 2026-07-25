-- Nearest-neighbour FLIMG scaling for the viewer. The result is flattened to
-- one layer because viewing does not need to retain editable layer geometry.

local scale = {}

local function sourceCoordinate(target, sourceSize, targetSize)
    return math.min(sourceSize,
        math.floor((target - 0.5) * sourceSize / targetSize) + 1)
end

local function pixelRows(rows, sourceWidth, sourceHeight, width, height)
    local output = {}
    for y = 1, height do
        local sourceRow = rows[sourceCoordinate(y, sourceHeight, height)]
        local row = {}
        for x = 1, width do
            row[x] = sourceRow:byte(sourceCoordinate(x, sourceWidth, width)) or 0
        end
        output[y] = row
    end
    return output
end

local function cellRows(rows, sourceWidth, sourceHeight, width, height)
    local output = {}
    for y = 1, height do
        local sourceRow = rows[sourceCoordinate(y, sourceHeight, height)]
        local text, foreground, background = {}, {}, {}
        for x = 1, width do
            local sourceX = sourceCoordinate(x, sourceWidth, width)
            text[x] = sourceRow[1]:sub(sourceX, sourceX)
            foreground[x] = sourceRow[2]:sub(sourceX, sourceX)
            background[x] = sourceRow[3]:sub(sourceX, sourceX)
        end
        output[y] = {
            table.concat(text), table.concat(foreground), table.concat(background),
        }
    end
    return output
end

function scale.resize(codec, source, factor)
    assert(type(codec) == "table" and codec.compose and codec.normalize,
        "FLIMG scale requires the codec")
    assert(type(source) == "table" and source.format == "FLIMG",
        "FLIMG scale requires a decoded FLIMG image")
    factor = math.max(0.05, math.min(16, tonumber(factor) or 1))
    local width = math.max(1, math.floor(source.width * factor + 0.5))
    local height = math.max(1, math.floor(source.height * factor + 0.5))
    if width == source.width and height == source.height then return source end

    local frames = {}
    for frameIndex, frame in ipairs(source.frames) do
        local composed = codec.compose(source, frameIndex)
        frames[frameIndex] = {
            duration=frame.duration,
            layers={ { rows=source.mode == "pixel"
                and pixelRows(composed, source.width, source.height, width, height)
                or cellRows(composed, source.width, source.height, width, height) } },
        }
    end

    return codec.normalize({
        mode=source.mode,
        width=width,
        height=height,
        palette=source.palette,
        layers={ { name="Scaled image", width=width, height=height, z=1 } },
        frames=frames,
        loop=source.loop,
        pingPong=source.pingPong,
        keyframeInterval=source.keyframeInterval,
    })
end

return scale
