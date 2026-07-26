local BASALT_URL =
    "https://raw.githubusercontent.com/Pyroxenium/Basalt2/refs/heads/basalt2.5/bundle/basalt.min.lua"
local MANIFEST_URL =
    "https://raw.githubusercontent.com/Pyroxenium/BasaltOS/refs/heads/main/install-manifest.txt"
local RAW_BASE =
    "https://raw.githubusercontent.com/Pyroxenium/BasaltOS/refs/heads/main/"

local HEADERS = {
    ["User-Agent"] = "BasaltOS-Installer",
    ["Cache-Control"] = "no-cache",
}

local function isRuntimePath(path)
    return path == "system/config.dat"
        or path:match("^system/logs/") ~= nil
        or path:match("^users/") ~= nil
end

local function resetTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function request(url)
    local ok, response, reason = pcall(http.get, url, HEADERS)
    if not ok then return nil, tostring(response) end
    if not response then return nil, tostring(reason or "request failed") end
    return response
end

local function download(url)
    local response, reason = request(url)
    if not response then return nil, reason end
    local ok, content = pcall(response.readAll)
    response.close()
    if not ok then return nil, tostring(content) end
    if type(content) ~= "string" then return nil, "empty response" end
    return content
end

if not http then
    resetTerminal()
    error("BasaltOS Installer requires the HTTP API.", 0)
end

resetTerminal()

if term.isColor and not term.isColor() then
    error("BasaltOS requires an Advanced Computer.", 0)
end

local terminalWidth, terminalHeight = term.getSize()
if terminalWidth < 51 or terminalHeight < 19 then
    error(("BasaltOS requires a terminal of at least 51x19 (current: %dx%d).")
        :format(terminalWidth, terminalHeight), 0)
end

term.setTextColor(colors.lightBlue)
print("Loading BasaltOS Installer...")
term.setTextColor(colors.white)

local basaltSource, basaltError = download(BASALT_URL)
if not basaltSource then
    error("Could not download Basalt: " .. tostring(basaltError), 0)
end

local basaltChunk, loadError = load(
    basaltSource, "@basalt.min.lua", "t", _ENV)
if not basaltChunk then
    error("Could not load Basalt: " .. tostring(loadError), 0)
end

local basalt = basaltChunk()
local installing = false
local cancelRequested = false
local readyToReboot = false
local stagePath
local logoFrame = 1
local logoAccent

local theme = basalt.use("theme")
local palette = theme.applyPreset("basalt")
local animation = basalt.use("animation")
basalt.use("bigfont")

logoAccent = palette.lava

local main = basalt.getMainFrame():setBackground(palette.bg)

local brandPanel = main:addFrame({
    x=1, y=1, width=17, height="{parent.height}",
    background=palette.surface,
})

local crystal = {
    "     1     ",
    "    121    ",
    "   12321   ",
    "  1234321  ",
    " 123454321 ",
    "  2345432  ",
    "   34543   ",
    "    454    ",
    "     5     ",
}

local orbit = {
    {8, 1}, {13, 3}, {15, 7}, {13, 12},
    {8, 14}, {3, 12}, {1, 7}, {3, 3},
}

local logo = brandPanel:addCanvas({
    x=2, y=2, width=15, height=14,
    background=palette.surface,
    draw=function(_, buffer)
        local layers = {
            palette.border,
            palette.info,
            palette.ember,
            palette.lava,
            logoAccent,
        }

        for row, line in ipairs(crystal) do
            for column = 1, #line do
                local layer = tonumber(line:sub(column, column))
                if layer then
                    local color = layers[layer]
                    buffer:fill(column + 2, row + 2, 1, 1,
                        " ", color, color)
                end
            end
        end

        local current = orbit[logoFrame]
        local previous = orbit[(logoFrame + #orbit - 2) % #orbit + 1]
        buffer:blit(previous[1], previous[2], ".",
            palette.muted, palette.surface)
        buffer:blit(current[1], current[2], "*",
            logoAccent, palette.surface)
    end,
})

brandPanel:addLabel({
    x=4, y=17, width=11, height=1,
    autoSize=false, text="BASALT 2.5",
    foreground=palette.text,
})

brandPanel:addLabel({
    x=5, y=18, width=9, height=1,
    autoSize=false, text="INSTALLER",
    foreground=palette.muted,
})

local brand = main:addBigFont({
    x=22, y=2, text="BasaltOS", fontSize=1,
    foreground=palette.lava, background=palette.bg,
})

local tagline = main:addLabel({
    x=24, y=5, width="{parent.width - 21}", height=1,
    autoSize=false, text="A playful OS for CC:Tweaked",
    foreground=palette.muted,
})

local statusCard = main:addFrame({
    x=19, y=7, width="{parent.width - 20}", height=9,
    background=palette.surface,
})

local phase = statusCard:addLabel({
    x=2, y=2, width=8, height=1,
    autoSize=false, text=" READY",
    foreground=palette.bg, background=palette.lava,
})

local title = statusCard:addLabel({
    x=11, y=2, width="{parent.width - 12}", height=1,
    autoSize=false, text="Ready to install",
    foreground=palette.text,
})

local status = statusCard:addLabel({
    x=2, y=4, width="{parent.width - 4}", height=2,
    autoSize=false, foreground=palette.text,
})
status:setText("Target: computer root (/)")

local detail = statusCard:addLabel({
    x=2, y=6, width="{parent.width - 4}", height=1,
    autoSize=false, foreground=palette.muted,
})
detail:setText("User data stays untouched.")

local progress = statusCard:addProgressBar({
    x=2, y=8, width="{parent.width - 4}", height=1,
    background=palette.border,
    foreground=palette.text,
    barColor=palette.lava,
    showPercentage=true,
})

main:addLabel({
    x=20, y=17, width="{parent.width - 21}", height=1,
    autoSize=false, text="Staged install + safe rollback",
    foreground=palette.muted,
})

local closeButton = main:addButton({
    x=20, y=19, width=10, height=1,
    text="Close", background=palette.raised, foreground=palette.text,
})

local installButton = main:addButton({
    x="{parent.width - 11}", y=19,
    width=10, height=1, text="Install",
    background=palette.lava, foreground=palette.bg,
})

local function setPhase(text, color)
    text = tostring(text):upper():sub(1, 8)
    phase:setText(string.rep(" ", math.max(0, math.floor((8 - #text) / 2)))
        .. text)
    phase:setBackground(color or palette.lava)
    phase:setForeground(palette.bg)
    logoAccent = color or palette.lava
    logo:markRenderDirty()
end

animation.to(brand, {x=20}, 0.4, "easeOut")
animation.to(tagline, {x=20}, 0.5, "easeOut")

basalt.schedule(function()
    while true do
        sleep(installing and 0.09 or 0.18)
        logoFrame = logoFrame % #orbit + 1
        logo:markRenderDirty()
    end
end)

local function setStatus(message, color)
    status:setForeground(color or palette.text)
    status:setText(message)
end

local function setDetail(message)
    local width = math.max(1, detail:getWidth())
    if #message > width then
        message = message:sub(1, math.max(1, width - 3)) .. "..."
    end
    detail:setText(message)
end

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
end

local function writeFile(path, content)
    ensureParent(path)
    local handle, reason = fs.open(path, "w")
    if not handle then
        error("Could not write " .. path .. ": " .. tostring(reason), 0)
    end
    handle.write(content)
    handle.close()
end

local function checkCancelled()
    if cancelRequested then error("Installation cancelled.", 0) end
end

local function isSafeManifestPath(path)
    if path == "" or path:sub(1, 1) == "/" then return false end
    if path:find("\\", 1, true) or path:find("%z") then return false end
    if not path:match("^[%w%._%-%/]+$") then return false end
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." then return false end
    end
    return true
end

local function fetchFileList()
    setPhase("PREPARE", palette.info)
    setStatus("Reading the install manifest...", palette.text)
    setDetail("Requesting the versioned BasaltOS file list.")

    local body, reason = download(MANIFEST_URL)
    if not body then
        error("Could not download the install manifest: "
            .. tostring(reason), 0)
    end

    local files = {}
    local totalBytes = 0
    local seen = {}
    local lineNumber = 0
    for line in (body .. "\n"):gmatch("(.-)\r?\n") do
        lineNumber = lineNumber + 1
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local source, size = line:match("^(os/[^|]+)|(%d+)$")
            local relative = source and source:match("^os/(.+)$") or nil
            if not source or not relative or not isSafeManifestPath(relative) then
                error(("Invalid install manifest entry on line %d.")
                    :format(lineNumber), 0)
            end
            if seen[relative] then
                error("Duplicate install manifest path: " .. relative, 0)
            end
            seen[relative] = true

            if not isRuntimePath(relative) then
                size = tonumber(size) or 0
                if size < 0 then
                    error("Invalid file size for " .. relative, 0)
                end
                files[#files + 1] = {
                    source=source,
                    target=relative,
                    size=size,
                }
                totalBytes = totalBytes + size
            end
        end
    end

    table.sort(files, function(a, b)
        -- Keep the computer's previous startup entry intact until every other
        -- BasaltOS file has been applied successfully.
        if a.target == "startup.lua" then return false end
        if b.target == "startup.lua" then return true end
        return a.target < b.target
    end)
    if #files == 0 then
        error("The install manifest contains no BasaltOS files.", 0)
    end
    return files, totalBytes
end

local function verifySpace(totalBytes)
    local free = fs.getFreeSpace("/")
    local required = totalBytes + 32768
    if type(free) == "number" and free < required then
        error(("Not enough free space for the staged installation. "
            .. "Need about %d KB, have %d KB.")
            :format(math.ceil(required / 1024), math.floor(free / 1024)), 0)
    end
end

local function makeStagePath()
    local stamp
    if os.epoch then
        stamp = tostring(os.epoch("utc"))
    else
        stamp = tostring(math.floor(os.clock() * 1000))
    end
    local path = fs.combine("/", ".basaltos-install-" .. stamp)
    local suffix = 0
    while fs.exists(path) do
        suffix = suffix + 1
        path = fs.combine("/", ".basaltos-install-" .. stamp .. "-" .. suffix)
    end
    fs.makeDir(path)
    return path
end

local function backupStartup(stagedStartup)
    if not fs.exists("startup.lua") or fs.isDir("startup.lua") then return end

    local current = fs.open("startup.lua", "r")
    local replacement = fs.open(stagedStartup, "r")
    if not current or not replacement then
        if current then current.close() end
        if replacement then replacement.close() end
        error("Could not compare the existing startup.lua.", 0)
    end

    local oldContent = current.readAll()
    local newContent = replacement.readAll()
    current.close()
    replacement.close()
    if oldContent == newContent then return end

    local backup = "startup.before-basaltos.lua"
    local suffix = 0
    while fs.exists(backup) do
        suffix = suffix + 1
        backup = "startup.before-basaltos-" .. suffix .. ".lua"
    end
    fs.copy("startup.lua", backup)
end

local function installFiles(files)
    stagePath = makeStagePath()
    local newRoot = fs.combine(stagePath, "new")
    local backupRoot = fs.combine(stagePath, "backup")
    fs.makeDir(newRoot)
    fs.makeDir(backupRoot)

    setPhase("DOWNLOAD", palette.lava)
    for index, file in ipairs(files) do
        checkCancelled()
        local percent = math.floor(index / #files * 88)
        progress:setProgress(percent)
        setStatus(("Downloading file %d of %d..."):format(index, #files))
        setDetail(file.target)

        local content, reason = download(RAW_BASE .. file.source)
        if not content then
            error("Could not download " .. file.target .. ": "
                .. tostring(reason), 0)
        end
        if file.size > 0 and #content ~= file.size then
            error(("Downloaded size mismatch for %s (expected %d, got %d).")
                :format(file.target, file.size, #content), 0)
        end
        writeFile(fs.combine(newRoot, file.target), content)
    end

    checkCancelled()
    local stagedStartup = fs.combine(newRoot, "startup.lua")
    if fs.exists(stagedStartup) then backupStartup(stagedStartup) end

    setPhase("APPLY", palette.warning)
    setStatus("Applying the installation...", palette.text)
    local applied = {}
    local applyOk, applyError = pcall(function()
        for index, file in ipairs(files) do
            checkCancelled()
            local source = fs.combine(newRoot, file.target)
            local target = fs.combine("/", file.target)
            local backup = fs.combine(backupRoot, file.target)
            local entry = {
                target=target,
                backup=backup,
                hadOriginal=false,
            }
            applied[#applied + 1] = entry

            ensureParent(target)
            if fs.exists(target) then
                if fs.isDir(target) then
                    error("Cannot replace directory with file: " .. target, 0)
                end
                ensureParent(backup)
                fs.move(target, backup)
                entry.hadOriginal = true
            end
            fs.move(source, target)

            local percent = 88 + math.floor(index / #files * 12)
            progress:setProgress(math.min(100, percent))
            setDetail(file.target)
        end
    end)

    if not applyOk then
        setPhase("RESTORE", palette.warning)
        setStatus("Restoring the previous installation...", palette.warning)
        for index = #applied, 1, -1 do
            local entry = applied[index]
            if fs.exists(entry.target) and not fs.isDir(entry.target) then
                fs.delete(entry.target)
            end
            if entry.hadOriginal and fs.exists(entry.backup) then
                ensureParent(entry.target)
                fs.move(entry.backup, entry.target)
            end
        end
        error("Could not apply BasaltOS; previous files were restored. "
            .. tostring(applyError), 0)
    end

    fs.delete(stagePath)
    stagePath = nil
end

local function finishAttempt(ok, reason)
    installing = false
    closeButton:setText("Close")

    if stagePath and fs.exists(stagePath) then
        pcall(fs.delete, stagePath)
    end
    stagePath = nil

    if ok then
        readyToReboot = true
        progress:setProgress(100)
        title:setText("Install complete")
        title:setForeground(palette.success)
        setPhase("COMPLETE", palette.success)
        setStatus("BasaltOS is ready to use.", palette.success)
        setDetail("Reboot the computer to start BasaltOS.")
        installButton:setText("Reboot")
        installButton:setVisible(true)
    else
        progress:setProgress(0)
        title:setText("Installation failed")
        title:setForeground(palette.danger)
        setPhase("ERROR", palette.danger)
        setStatus(tostring(reason or "Unknown installation error"), palette.danger)
        setDetail("Check HTTP access and free disk space, then try again.")
        installButton:setText("Retry")
        installButton:setVisible(true)
    end
end

local function performInstallation()
    installing = true
    cancelRequested = false
    readyToReboot = false
    title:setText("Installing BasaltOS")
    title:setForeground(palette.text)
    setPhase("PREPARE", palette.info)
    installButton:setVisible(false)
    closeButton:setText("Cancel")
    progress:setProgress(0)

    local ok, reason = pcall(function()
        local files, totalBytes = fetchFileList()
        verifySpace(totalBytes)
        setDetail(("%d files, approximately %d KB")
            :format(#files, math.ceil(totalBytes / 1024)))
        installFiles(files)
    end)
    finishAttempt(ok, reason)
end

installButton:onClick(function(_, button)
    if button and button ~= 1 then return end
    if readyToReboot then
        os.reboot()
        return
    end
    if not installing then basalt.schedule(performInstallation) end
end)

closeButton:onClick(function(_, button)
    if button and button ~= 1 then return end
    if installing then
        cancelRequested = true
        closeButton:setText("Stopping")
        setPhase("CANCEL", palette.warning)
        setStatus("Cancelling after the current download...", palette.warning)
    else
        basalt.stop()
    end
end)

basalt.run()
resetTerminal()
