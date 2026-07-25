-- /system/core/icon.lua
-- Shared BIMG/FLIMG loader, color/monochrome rendering and size normalization.

local basalt = require("lib.public.basalt")
local image_module = basalt.use("image")
local log = require("core.log")

local icon = {}

icon.TASKBAR_WIDTH = 2
icon.TASKBAR_HEIGHT = 2
icon.DESKTOP_WIDTH = 4
icon.DESKTOP_HEIGHT = 3
icon.DEFAULT_MAIN_PATH = "system/assets/icons/default.bimg"
icon.DEFAULT_TASKBAR_PATH = "system/assets/icons/default-taskbar.bimg"
icon.BASALTOS_MAIN_PATH = "system/assets/icons/basaltos.bimg"
icon.BASALTOS_TASKBAR_PATH = "system/assets/icons/basaltos-taskbar.bimg"

-- Compatibility aliases for existing direct-path callers.
icon.DEFAULT_PATH = icon.DEFAULT_MAIN_PATH
icon.BASALTOS_PATH = icon.BASALTOS_MAIN_PATH

-- Compatibility aliases for callers that use the taskbar dimensions.
icon.WIDTH = icon.TASKBAR_WIDTH
icon.HEIGHT = icon.TASKBAR_HEIGHT

local source_cache = {}
local render_cache = {}
local inline_fallback = {
    {
        {"\151\131\131\148", "bbbb", "0000"},
        {"\149::\149", "b99b", "0000"},
        {"\138\143\143\133", "bbbb", "0000"},
    },
    basaltOSIcon = 2,
}

local function validBimg(value)
    if type(value) ~= "table" or type(value[1]) ~= "table" or #value[1] == 0 then
        return false
    end
    for _, frame in ipairs(value) do
        if type(frame) ~= "table" or #frame == 0 then return false end
        for _, line in ipairs(frame) do
            if type(line) ~= "table" or type(line[1]) ~= "string"
                or type(line[2]) ~= "string" or type(line[3]) ~= "string" then
                return false
            end
            if #line[1] ~= #line[2] or #line[1] ~= #line[3] then return false end
        end
    end
    return true
end

local function validFlimg(value)
    return type(value) == "table" and value.format == "FLIMG"
        and (value.mode == "pixel" or value.mode == "cell")
        and type(value.palette) == "table" and type(value.layers) == "table"
        and type(value.frames) == "table" and #value.frames > 0
end

local function validSource(value)
    return validBimg(value) or validFlimg(value)
end

local function loadPath(path)
    if not path or path == "" or not fs.exists(path) then return nil end
    if source_cache[path] then return source_cache[path] end

    local ok, result = pcall(image_module.load, path)
    if ok and validSource(result) then
        source_cache[path] = result
        return result
    end

    log.warn("ICON", "Unable to load image icon", {
        path=path,
        error=ok and "Invalid BIMG/FLIMG data" or tostring(result),
    })
    return nil
end

local function colorBlit(value, fallback)
    value = value or fallback
    if type(value) == "string" and #value == 1 then return value end
    if colors.toBlit then
        local ok, result = pcall(colors.toBlit, value)
        if ok and type(result) == "string" then return result end
    end
    return fallback == colors.white and "0" or "f"
end

local function transform(source, width, height, foreground, background, monochrome)
    local ink = colorBlit(foreground, colors.black)
    local paper = colorBlit(background, colors.white)
    local format = tonumber(source.basaltOSIcon) or 0
    local output = {}

    for frame_index, frame in ipairs(source) do
        local source_height = math.max(1, #frame)
        local source_width = math.max(1, frame[1] and #frame[1][1] or 1)
        local target = {}
        for y = 1, height do
            local source_y = math.min(source_height,
                math.floor((y - 1) * source_height / height) + 1)
            local source_line = frame[source_y] or {" ", "f", "0"}
            local text = {}
            local foregrounds = {}
            local backgrounds = {}
            for x = 1, width do
                local source_x = math.min(source_width,
                    math.floor((x - 1) * source_width / width) + 1)
                text[x] = source_line[1]:sub(source_x, source_x)
                if format == 1 then
                    -- Binary Icon Studio v1: canonical black is ink, white is paper.
                    foregrounds[x] = source_line[2]:sub(source_x, source_x) == "f" and ink or paper
                    backgrounds[x] = source_line[3]:sub(source_x, source_x) == "f" and ink or paper
                elseif format == 2 and monochrome then
                    -- Color Icon Studio v2: white is the canvas paper, every other
                    -- source color becomes monochrome ink. This preserves inverted
                    -- semigraphic cells where the sixth subpixel owns background.
                    foregrounds[x] = source_line[2]:sub(source_x, source_x) == "0" and paper or ink
                    backgrounds[x] = source_line[3]:sub(source_x, source_x) == "0" and paper or ink
                elseif monochrome then
                    -- Legacy taskbar behavior deliberately ignores source colors.
                    foregrounds[x] = ink
                    backgrounds[x] = paper
                else
                    -- Desktop, launcher and other large surfaces retain BIMG colors.
                    foregrounds[x] = source_line[2]:sub(source_x, source_x)
                    backgrounds[x] = source_line[3]:sub(source_x, source_x)
                end
            end
            target[y] = {
                table.concat(text),
                table.concat(foregrounds),
                table.concat(backgrounds),
            }
        end
        output[frame_index] = target
    end
    output.secondsPerFrame = source.secondsPerFrame
    output.basaltOSIcon = source.basaltOSIcon
    return output
end

local function nativeRgb(value, fallback)
    local blit = colorBlit(value, fallback)
    return image_module.flimg.NATIVE_RGB[tonumber(blit, 16)]
end

local function transformFlimg(source, width, height, foreground, background, monochrome)
    local codec = image_module.flimg
    local pixel = source.mode == "pixel"
    local targetWidth = pixel and width * 2 or width
    local targetHeight = pixel and height * 3 or height
    local palette = monochrome and {
        nativeRgb(foreground, colors.black),
        nativeRgb(background, colors.white),
    } or source.palette
    local frames = {}

    for frameIndex, sourceFrame in ipairs(source.frames) do
        local composed = codec.compose(source, frameIndex)
        local rows = {}
        for y = 1, targetHeight do
            local sourceY = math.min(source.height,
                math.floor((y - 1) * source.height / targetHeight) + 1)
            local sourceRow = composed[sourceY]
            if pixel then
                local row = {}
                for x = 1, targetWidth do
                    local sourceX = math.min(source.width,
                        math.floor((x - 1) * source.width / targetWidth) + 1)
                    local index = sourceRow:byte(sourceX) or 0
                    row[x] = monochrome and (index == 0 and 0 or 1) or index
                end
                rows[y] = row
            else
                local text, foregrounds, backgrounds = {}, {}, {}
                for x = 1, targetWidth do
                    local sourceX = math.min(source.width,
                        math.floor((x - 1) * source.width / targetWidth) + 1)
                    text[x] = sourceRow[1]:sub(sourceX, sourceX)
                    local fg = sourceRow[2]:byte(sourceX) or 0
                    local bg = sourceRow[3]:byte(sourceX) or 0
                    foregrounds[x] = string.char(monochrome and (fg == 0 and 0 or 1) or fg)
                    backgrounds[x] = string.char(monochrome and (bg == 0 and 0 or 2) or bg)
                end
                rows[y] = {
                    table.concat(text),
                    table.concat(foregrounds),
                    table.concat(backgrounds),
                }
            end
        end
        frames[frameIndex] = {
            duration=sourceFrame.duration,
            layers={ { rows=rows } },
        }
    end

    return codec.normalize({
        mode=source.mode,
        width=targetWidth,
        height=targetHeight,
        palette=palette,
        layers={ {
            name="Icon",
            width=targetWidth,
            height=targetHeight,
            z=1,
        } },
        frames=frames,
        loop=source.loop,
        pingPong=source.pingPong,
        keyframeInterval=source.keyframeInterval,
    })
end

local function normalizeVariant(variant)
    return variant == "main" and "main" or "taskbar"
end

local function variantSize(variant)
    if normalizeVariant(variant) == "main" then
        return icon.DESKTOP_WIDTH, icon.DESKTOP_HEIGHT
    end
    return icon.TASKBAR_WIDTH, icon.TASKBAR_HEIGHT
end

local function appendPath(paths, seen, value)
    if type(value) ~= "string" or value == "" or seen[value] then return end
    seen[value] = true
    paths[#paths + 1] = value
end

function icon.load(path, fallback_path)
    local requested = loadPath(path)
    if requested then return requested, path, false end

    fallback_path = fallback_path or icon.DEFAULT_MAIN_PATH
    local fallback = loadPath(fallback_path)
    if fallback then return fallback, fallback_path, true end
    if fallback_path ~= icon.DEFAULT_MAIN_PATH then
        fallback = loadPath(icon.DEFAULT_MAIN_PATH)
        if fallback then return fallback, icon.DEFAULT_MAIN_PATH, true end
    end
    return inline_fallback, nil, true
end

function icon.forProgram(program, variant)
    variant = normalizeVariant(variant)
    local paths, seen = {}, {}
    local icons = program and type(program.icons) == "table" and program.icons or {}

    if variant == "taskbar" then
        appendPath(paths, seen, icons.taskbar)
        if program and program.app_path then
            appendPath(paths, seen, fs.combine(program.app_path, "taskbar.flimg"))
            appendPath(paths, seen, fs.combine(program.app_path, "taskbar.bimg"))
        end
        -- Apps do not need to ship two assets. Their main icon is the graceful
        -- fallback and is normalized to 2x2 monochrome by the caller.
        appendPath(paths, seen, icons.main)
        appendPath(paths, seen, program and program.icon)
        if program and program.app_path then
            appendPath(paths, seen, fs.combine(program.app_path, "icon.flimg"))
            appendPath(paths, seen, fs.combine(program.app_path, "icon.bimg"))
        end
        appendPath(paths, seen, icon.DEFAULT_TASKBAR_PATH)
    else
        appendPath(paths, seen, icons.main)
        appendPath(paths, seen, program and program.icon)
        if program and program.app_path then
            appendPath(paths, seen, fs.combine(program.app_path, "icon.flimg"))
            appendPath(paths, seen, fs.combine(program.app_path, "icon.bimg"))
        end
    end
    appendPath(paths, seen, icon.DEFAULT_MAIN_PATH)

    for index, candidate in ipairs(paths) do
        local source = loadPath(candidate)
        if source then return source, candidate, index > 1 end
    end
    return inline_fallback, nil, true
end

local function render(source, cache_path, options)
    options = options or {}
    local default_width, default_height = variantSize(options.variant)
    local width = math.max(1, math.floor(tonumber(options.width) or default_width))
    local height = math.max(1, math.floor(tonumber(options.height) or default_height))
    local foreground = options.foreground or colors.black
    local background = options.background or colors.white
    local monochrome = options.monochrome == true
    local key = table.concat({
        cache_path or "<fallback>", width, height,
        colorBlit(foreground, colors.black), colorBlit(background, colors.white),
        tostring(source.basaltOSIcon or "legacy"),
        monochrome and "mono" or "color",
    }, ":")
    if render_cache[key] then return render_cache[key] end
    local result = validFlimg(source)
        and transformFlimg(source, width, height, foreground, background, monochrome)
        or transform(source, width, height, foreground, background, monochrome)
    render_cache[key] = result
    return result
end

function icon.renderProgram(program, options)
    options = options or {}
    local source, path = icon.forProgram(program, options.variant)
    return render(source, path, options)
end

function icon.renderPath(path, options)
    local source, resolved = icon.load(path)
    return render(source, resolved, options)
end

-- Renders an in-memory BIMG using the same normalization and tinting as
-- manifest icons. Icon Studio uses this for live taskbar/desktop previews.
function icon.renderBimg(source, options)
    if not validBimg(source) then source = inline_fallback end
    options = options or {}
    return transform(
        source,
        math.max(1, math.floor(tonumber(options.width) or icon.WIDTH)),
        math.max(1, math.floor(tonumber(options.height) or icon.HEIGHT)),
        options.foreground or colors.black,
        options.background or colors.white,
        options.monochrome == true
    )
end

local function imageProperties(properties)
    local props = {}
    for key, value in pairs(properties or {}) do
        if key ~= "iconForeground" and key ~= "iconBackground"
            and key ~= "monochrome" and key ~= "variant" then
            props[key] = value
        end
    end
    local default_width, default_height = variantSize(properties and properties.variant)
    props.autoSize = false
    props.width = props.width or default_width
    props.height = props.height or default_height
    props.disabled = props.disabled ~= false
    return props
end

function icon.add(parent, program, properties)
    local props = imageProperties(properties)
    props.bimg = icon.renderProgram(program, {
        width=props.width,
        height=props.height,
        foreground=properties and properties.iconForeground,
        background=properties and properties.iconBackground,
        monochrome=properties and properties.monochrome,
        variant=properties and properties.variant,
    })
    return parent:addImage(props)
end

function icon.addPath(parent, path, properties)
    local props = imageProperties(properties)
    props.bimg = icon.renderPath(path, {
        width=props.width,
        height=props.height,
        foreground=properties and properties.iconForeground,
        background=properties and properties.iconBackground,
        monochrome=properties and properties.monochrome,
    })
    return parent:addImage(props)
end

function icon.update(image, program, foreground, background, monochrome, variant)
    if not image then return end
    image:setBimg(icon.renderProgram(program, {
        width=image:getWidth(), height=image:getHeight(),
        foreground=foreground, background=background,
        monochrome=monochrome,
        variant=variant,
    }))
end

function icon.updatePath(image, path, foreground, background, monochrome)
    if not image then return end
    image:setBimg(icon.renderPath(path, {
        width=image:getWidth(), height=image:getHeight(),
        foreground=foreground, background=background,
        monochrome=monochrome,
    }))
end

function icon.clearCache(path)
    if path then source_cache[path] = nil else source_cache = {} end
    render_cache = {}
end

return icon
