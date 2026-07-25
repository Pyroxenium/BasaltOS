-- Image Viewer: deliberately small FLIMG viewer with automatic playback.

local launchArgs = { ... }
local basalt = require("basalt")
local app = require("app")
local scaler = require("scale")
local imageModule = basalt.use("image")
local flimg = imageModule.flimg

local dialog, filesystem = app.dialog, app.filesystem
local function theme(key, fallback) return app.theme(key, fallback) end
local C = {
    background = theme("menu_bg", colors.black),
    foreground = theme("menu_fg", colors.white),
    muted = theme("menu_muted", colors.gray),
    surface = theme("surface", colors.lightGray),
    primary = theme("primary", colors.blue),
    text = theme("text", colors.white),
    danger = theme("danger", colors.red),
}

local main = basalt.getMainFrame()
main:setBackground(C.background)

local header = main:addFrame({
    x = 1, y = 1, width = "{parent.width}", height = 2,
    background = C.surface,
})
local title = header:addLabel({
    x = 2, y = 1, width = "{parent.width - 10}", height = 1,
    text = "Image Viewer", foreground = C.foreground,
    background = C.surface, disabled = true,
})
local openButton = header:addButton({
    x = "{parent.width - 7}", y = 1, width = 8, height = 1,
    text = "Open...", foreground = C.foreground, background = C.surface,
})
openButton:setStateStyle("hover", { background = C.primary, foreground = C.text })

local zoomOutButton = header:addButton({
    x=1, y=2, width=3, height=1, text="-",
    foreground=C.foreground, background=C.surface,
})
local zoomButton = header:addButton({
    x=4, y=2, width=7, height=1, text="100%",
    foreground=C.foreground, background=C.surface,
})
local zoomInButton = header:addButton({
    x=11, y=2, width=3, height=1, text="+",
    foreground=C.foreground, background=C.surface,
})
local fitButton = header:addButton({
    x=14, y=2, width=5, height=1, text="Fit",
    foreground=C.foreground, background=C.surface,
})
for _, button in ipairs({ zoomOutButton, zoomButton, zoomInButton, fitButton }) do
    button:setStateStyle("hover", { background=C.primary, foreground=C.text })
end

local viewport = main:addFrame({
    x = 1, y = 3, width = "{parent.width}", height = "{parent.height - 2}",
    background = C.background,
})
local display = viewport:addImage({
    x = 1, y = 1, autoSize = true, visible = false,
    background = false,
})
local emptyLabel = viewport:addLabel({
    x = 2, y = 2, width = "{parent.width - 2}", height = 2,
    text = "Open a .flimg image", foreground = C.muted,
    background = false, disabled = true,
})

local currentPath, currentSource
local zoom, fitMode = 1, false
local panX, panY, panActive = 0, 0, false
local panStartX, panStartY, panOriginX, panOriginY = 0, 0, 0, 0
local scaledCache = {}
local ZOOM_LEVELS = { 0.25, 0.5, 1, 2, 3, 4, 6, 8 }
local MAX_SCALED_PIXELS = 262144

local function centerDisplay()
    if not display.visible then return end
    local baseX = math.floor((viewport.width - display.width) / 2) + 1
    local baseY = math.floor((viewport.height - display.height) / 2) + 1
    local x, y = baseX + panX, baseY + panY
    if display.width > viewport.width then
        x = math.max(viewport.width - display.width + 1, math.min(1, x))
    else x, panX = baseX, 0 end
    if display.height > viewport.height then
        y = math.max(viewport.height - display.height + 1, math.min(1, y))
    else y, panY = baseY, 0 end
    panX, panY = x - baseX, y - baseY
    display:setPosition(x, y)
end

local function maximumZoom()
    if not currentSource then return 16 end
    local pixels = math.max(1, currentSource.width * currentSource.height)
    return math.max(0.05, math.min(16, math.sqrt(MAX_SCALED_PIXELS / pixels)))
end

local function fitZoom()
    if not currentSource then return 1 end
    local horizontal, vertical
    if currentSource.mode == "pixel" then
        horizontal = viewport.width * 2 / currentSource.width
        vertical = viewport.height * 3 / currentSource.height
    else
        horizontal = viewport.width / currentSource.width
        vertical = viewport.height / currentSource.height
    end
    return math.max(0.05, math.min(16, horizontal, vertical))
end

local function scaledImage(factor)
    local width = math.max(1, math.floor(currentSource.width * factor + 0.5))
    local height = math.max(1, math.floor(currentSource.height * factor + 0.5))
    local key = width .. "x" .. height
    local cached = scaledCache[key]
    if cached then return cached end
    cached = scaler.resize(flimg, currentSource, factor)
    scaledCache[key] = cached
    return cached
end

local function applyZoom(factor, fit, preservePan)
    if not currentSource then return end
    zoom = math.max(0.05, math.min(maximumZoom(), tonumber(factor) or 1))
    fitMode = fit == true
    if not preservePan then panX, panY = 0, 0 end
    local source = scaledImage(zoom)
    local frame = display.currentFrame or 1
    if display.bimg ~= source then
        display:stop()
        display:setBimg(source)
        display:setCurrentFrame(math.max(1, math.min(#source.frames, frame)))
        if #source.frames > 1 then display:play() end
    end
    display:setVisible(true)
    zoomButton:setText(("%d%%"):format(math.floor(zoom * 100 + 0.5)))
    fitButton:setBackground(fitMode and C.primary or C.surface)
    fitButton:setForeground(fitMode and C.text or C.foreground)
    centerDisplay()
end

local function absoluteEventPosition(source, x, y)
    if source.getAbsolutePosition then
        local absoluteX, absoluteY = source:getAbsolutePosition()
        return absoluteX + x - 1, absoluteY + y - 1
    end
    return x, y
end

local function beginPan(source, button, x, y)
    if button ~= 1 or not currentSource
        or (display.width <= viewport.width and display.height <= viewport.height) then return end
    panActive = true
    panStartX, panStartY = absoluteEventPosition(source, x, y)
    panOriginX, panOriginY = panX, panY
end

local function dragPan(source, button, x, y)
    if not panActive or button ~= 1 then return end
    local absoluteX, absoluteY = absoluteEventPosition(source, x, y)
    panX = panOriginX + absoluteX - panStartX
    panY = panOriginY + absoluteY - panStartY
    centerDisplay()
end

local function endPan(_, button)
    if button == 1 then panActive = false end
end

local function bindPan(element)
    element:onClick(beginPan)
    element:onDrag(dragPan)
    element:onClickUp(endPan)
end

local function stepZoom(direction)
    if not currentSource then return end
    local nextZoom = direction > 0 and ZOOM_LEVELS[#ZOOM_LEVELS] or ZOOM_LEVELS[1]
    if direction > 0 then
        for _, level in ipairs(ZOOM_LEVELS) do
            if level > zoom + 0.001 then nextZoom = level break end
        end
    else
        for index = #ZOOM_LEVELS, 1, -1 do
            if ZOOM_LEVELS[index] < zoom - 0.001 then nextZoom = ZOOM_LEVELS[index] break end
        end
    end
    applyZoom(nextZoom, false)
end

local function showError(message)
    if dialog and dialog.alert then dialog.alert("Image Viewer", tostring(message)) end
end

local function loadPath(path)
    path = tostring(path or "")
    if path == "" or not fs.exists(path) or fs.isDir(path) then
        showError("Image file not found")
        return false
    end

    local ok, source = pcall(imageModule.load, path)
    if not ok then
        showError(source)
        return false
    end
    if source.format ~= "FLIMG" then
        local converted, convertedSource = pcall(flimg.fromBimg, source)
        if not converted then
            showError("Unsupported image: " .. tostring(convertedSource))
            return false
        end
        source = convertedSource
    end

    display:stop()
    emptyLabel:setVisible(false)
    currentPath, currentSource = path, source
    scaledCache, zoom, fitMode, panX, panY = {}, 1, false, 0, 0

    local frames = #source.frames
    title:setText(("%s  |  %dx%d  |  %d frame%s"):format(
        fs.getName(path), source.width, source.height, frames, frames == 1 and "" or "s"))
    applyZoom(1, false)
    if filesystem and filesystem.addRecentFile then filesystem.addRecentFile(path) end
    if window and window.setTitle then window.setTitle("Image Viewer - " .. fs.getName(path)) end
    return true
end

local function openImage()
    if not dialog or not dialog.openFile then return end
    local startPath = currentPath and fs.getDir(currentPath) or "/"
    if startPath == "" or not fs.exists(startPath) then startPath = "/" end
    dialog.openFile({
        title = "Open Image", startPath = startPath, extensions = { "flimg", "bimg" },
    }, function(path) if path then loadPath(path) end end)
end

openButton:onClick(function(_, button) if button == 1 then openImage() end end)
zoomOutButton:onClick(function(_, button) if button == 1 then stepZoom(-1) end end)
zoomInButton:onClick(function(_, button) if button == 1 then stepZoom(1) end end)
zoomButton:onClick(function(_, button) if button == 1 then applyZoom(1, false) end end)
fitButton:onClick(function(_, button) if button == 1 and currentSource then applyZoom(fitZoom(), true) end end)
bindPan(viewport)
bindPan(display)
main:on("layout", function()
    if fitMode and currentSource then applyZoom(fitZoom(), true, true) else centerDisplay() end
end)

if filesystem and filesystem.registerFileType then
    filesystem.registerFileType("flimg", "flimgviewer")
    filesystem.registerFileType("bimg", "flimgviewer")
end

if type(launchArgs[1]) == "string" and launchArgs[1] ~= "" then
    loadPath(launchArgs[1])
end

basalt.run()
