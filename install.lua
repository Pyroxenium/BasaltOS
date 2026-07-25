local BASALT_URL =
    "https://raw.githubusercontent.com/Pyroxenium/Basalt2/refs/heads/main/release/basalt-full.lua"
local TREE_URL =
    "https://api.github.com/repos/Pyroxenium/BasaltOS/git/trees/main?recursive=1"
local RAW_BASE =
    "https://raw.githubusercontent.com/Pyroxenium/BasaltOS/refs/heads/main/"

local HEADERS = {
    ["User-Agent"] = "BasaltOS-Installer",
    ["Accept"] = "application/vnd.github+json",
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
term.setTextColor(colors.lightBlue)
print("Loading BasaltOS Installer...")
term.setTextColor(colors.white)

local basaltSource, basaltError = download(BASALT_URL)
if not basaltSource then
    error("Could not download Basalt: " .. tostring(basaltError), 0)
end

local basaltChunk, loadError = load(
    basaltSource, "@basalt-full.lua", "t", _ENV)
if not basaltChunk then
    error("Could not load Basalt: " .. tostring(loadError), 0)
end

local basalt = basaltChunk()
local main = basalt.getMainFrame():setBackground(colors.gray)

local header = main:addFrame({
    x=1, y=1, width="{parent.width}", height=3,
    background=colors.blue,
})

header:addLabel({
    x=2, y=1, text="BasaltOS Installer",
    foreground=colors.white,
})

header:addLabel({
    x=2, y=2, text="A lightweight and playful OS for CC:Tweaked",
    foreground=colors.lightBlue,
})

local title = main:addLabel({
    x=3, y=5, text="Ready to install",
    foreground=colors.white,
})

local description = main:addLabel({
    x=3, y=7, width="{parent.width - 5}", height=2,
    autoSize=false, foreground=colors.lightGray,
})
description:setText(
    "BasaltOS will be installed into the computer root. "
    .. "Existing BasaltOS files are updated and user files are kept.")

local progress = main:addProgressBar({
    x=3, y=10, width="{parent.width - 5}", height=1,
    background=colors.lightGray,
    foreground=colors.white,
    progressColor=colors.lime,
    showPercentage=true,
})

local status = main:addLabel({
    x=3, y=12, width="{parent.width - 5}", height=1,
    autoSize=false, foreground=colors.white,
})
status:setText("Destination: /")

local detail = main:addLabel({
    x=3, y=14, width="{parent.width - 5}", height=2,
    autoSize=false, foreground=colors.lightGray,
})
detail:setText("The existing startup.lua is backed up before it is replaced.")

local closeButton = main:addButton({
    x=3, y="{parent.height - 2}", width=10, height=1,
    text="Close", background=colors.lightGray, foreground=colors.black,
})

local installButton = main:addButton({
    x="{parent.width - 13}", y="{parent.height - 2}",
    width=11, height=1, text="Install",
    background=colors.lime, foreground=colors.black,
})

local installing = false
local cancelRequested = false
local readyToReboot = false
local stagePath

local function setStatus(message, color)
    status:setForeground(color or colors.white)
    status:setText(message)
end

local function setDetail(message)
    local width = math.max(1, main:getWidth() - 5)
    if #message > width * 2 then
        message = message:sub(1, width * 2 - 3) .. "..."
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

local function fetchFileList()
    setStatus("Reading the BasaltOS repository...", colors.white)
    setDetail("Requesting the current file list from GitHub.")

    local body, reason = download(TREE_URL)
    if not body then
        error("Could not read the repository: " .. tostring(reason), 0)
    end

    local tree, jsonError = textutils.unserializeJSON(body)
    if type(tree) ~= "table" then
        error("GitHub returned invalid repository data: "
            .. tostring(jsonError or "unknown response"), 0)
    end
    if type(tree.tree) ~= "table" then
        error(tostring(tree.message or "The repository tree is unavailable."), 0)
    end
    if tree.truncated then
        error("The GitHub repository tree was truncated.", 0)
    end

    local files = {}
    local totalBytes = 0
    for _, entry in ipairs(tree.tree) do
        local relative = type(entry.path) == "string"
            and entry.path:match("^os/(.+)$") or nil
        if relative and entry.type == "blob" and not isRuntimePath(relative) then
            files[#files + 1] = {
                source=entry.path,
                target=relative,
                size=tonumber(entry.size) or 0,
            }
            totalBytes = totalBytes + (tonumber(entry.size) or 0)
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
        error("No BasaltOS files were found in the repository.", 0)
    end
    return files, totalBytes
end

local function verifySpace(totalBytes)
    local free = fs.getFreeSpace("/")
    if type(free) == "number" and free < totalBytes then
        error(("Not enough disk space. Need %d bytes, have %d bytes.")
            :format(totalBytes, free), 0)
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
        writeFile(fs.combine(stagePath, file.target), content)
    end

    checkCancelled()
    local stagedStartup = fs.combine(stagePath, "startup.lua")
    if fs.exists(stagedStartup) then backupStartup(stagedStartup) end

    setStatus("Applying the installation...", colors.white)
    for index, file in ipairs(files) do
        checkCancelled()
        local source = fs.combine(stagePath, file.target)
        local target = fs.combine("/", file.target)
        ensureParent(target)

        if fs.exists(target) then
            if fs.isDir(target) then
                error("Cannot replace directory with file: " .. target, 0)
            end
            fs.delete(target)
        end
        fs.move(source, target)

        local percent = 88 + math.floor(index / #files * 12)
        progress:setProgress(math.min(100, percent))
        setDetail(file.target)
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
        title:setText("Installation complete")
        title:setForeground(colors.lime)
        setStatus("BasaltOS was installed successfully.", colors.lime)
        setDetail("Reboot the computer to start BasaltOS.")
        installButton:setText("Reboot")
        installButton:setVisible(true)
    else
        progress:setProgress(0)
        title:setText("Installation failed")
        title:setForeground(colors.red)
        setStatus(tostring(reason or "Unknown installation error"), colors.red)
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
    title:setForeground(colors.white)
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
        setStatus("Cancelling after the current download...", colors.yellow)
    else
        basalt.stop()
    end
end)

basalt.run()
resetTerminal()
