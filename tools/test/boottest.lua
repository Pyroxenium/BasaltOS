-- Headless boot test. tools/test.ps1 installs this file as /startup.lua of a
-- throwaway computer; the real boot loader sits next to it as /boot.lua.
--
-- Boots the image inside an off-screen window, plays the steps of one suite
-- from /teststeps.lua (suite name in /testsuite.txt) and writes what happened
-- to /testresult.txt. The last line is "RESULT: passed" or "RESULT: FAILED".
--
-- Steps:
--   {await="text", timeout=10}   wait until the screen shows the text
--   {expect="text"}              the screen must show the text now
--   {absent="text"}              the screen must not show the text now
--   {click={x, y}}, {double={x, y}}, {text="..."}, {key="enter"}
--   {event={"name", ...}}        queue an event for the kernel
--   {wait=seconds}, {snapshot="title"}
--   {report_file="path"}         copy a file into the report; a missing file
--                                or a line starting with FAIL fails the test

local WIDTH, HEIGHT = 51, 19
local STORE_URL = "https://raw.githubusercontent.com/Pyroxenium/BasaltOSStore/main/"
local STORE_FILES = "teststore"

local screen = window.create(term.current(), 1, 1, WIDTH, HEIGHT, false)
local report, failures = {}, {}

local function log(text)
    report[#report + 1] = text
end

local function fail(text)
    failures[#failures + 1] = text
    log("FAIL  " .. text)
end

local function screenText()
    local lines = {}
    for y = 1, HEIGHT do lines[y] = screen.getLine(y) end
    return table.concat(lines, "\n")
end

local function shows(text)
    return screenText():find(text, 1, true) ~= nil
end

local function snapshot(title)
    log("")
    log("--- " .. title .. " (t=" .. string.format("%.1f", os.clock()) .. "s) ---")
    for y = 1, HEIGHT do
        local text = screen.getLine(y)
        log("|" .. text:gsub("[%z\1-\31\127-\255]", "#") .. "|")
    end
end

local function readText(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local handle = fs.open(path, "r")
    local text = handle.readAll() or ""
    handle.close()
    return text
end

-- Serve the store from a local copy of build/dist-store, so installing from
-- the store can be tested without the network. Setting _G.storetest_damage
-- cuts the end off every package to imitate a broken download.
local function serveStoreLocally()
    local stub = {}
    for name, value in pairs(http or {}) do stub[name] = value end

    function stub.checkURL() return true end

    function stub.get(request)
        local url = type(request) == "table" and request.url or request
        if type(url) ~= "string" or url:sub(1, #STORE_URL) ~= STORE_URL then
            return nil, "The test harness only serves the store"
        end
        local path = fs.combine(STORE_FILES, url:sub(#STORE_URL + 1))
        if not fs.exists(path) or fs.isDir(path) then return nil, "Not found" end
        local handle = fs.open(path, "rb")
        local body = handle.readAll() or ""
        handle.close()
        if _G.storetest_damage and path:match("%.bpk$") then
            body = body:sub(1, #body - 20)
        end
        return {
            readAll=function() return body end,
            close=function() end,
            getResponseCode=function() return 200 end,
        }
    end

    _G.http = stub
end

local function finish()
    log("")
    log("--- packages ---")
    if bpk then
        log("boot loader time: " .. tostring(bpk.boot_ms) .. " ms")
        for _, package in ipairs(bpk.stats()) do
            log(("%-6s %-36s files=%-3d packed=%-6d unpacked=%-5s %s"):format(
                package.eager and "eager" or "lazy",
                package.path,
                package.file_count,
                package.stream_length,
                tostring(package.unpacked),
                package.unpack_ms and (package.unpack_ms .. " ms") or ""
            ))
        end
    else
        fail("the package runtime was never loaded")
    end

    local boot_log = readText("system/logs/boot.log")
    log("")
    log("--- system/logs/boot.log ---")
    log(boot_log or "(missing)")
    if not boot_log then
        fail("the kernel wrote no boot log")
    elseif boot_log:find("[FAIL]", 1, true) or boot_log:find("[ERROR]", 1, true) then
        fail("the boot log reports an error")
    end

    if fs.exists("system/logs") then
        for _, name in ipairs(fs.list("system/logs")) do
            if name ~= "boot.log" then
                local text = readText(fs.combine("system/logs", name)) or ""
                local shown = {}
                for line in text:gmatch("[^\n]+") do
                    if line:find("ERROR", 1, true) or line:find("FATAL", 1, true)
                        or line:find("PANIC", 1, true) or line:find("crash", 1, true) then
                        shown[#shown + 1] = line
                    end
                end
                log("")
                log(("--- %s: %d bytes, %d error lines ---"):format(name, #text, #shown))
                for index = 1, math.min(#shown, 25) do log(shown[index]) end
                if #shown > 0 then fail(name .. " contains error lines") end
            end
        end
    end

    log("")
    for _, text in ipairs(failures) do log("FAILED: " .. text) end
    log(#failures == 0 and "RESULT: passed" or "RESULT: FAILED")

    local handle = fs.open("testresult.txt", "w")
    handle.write(table.concat(report, "\n") .. "\n")
    handle.close()
    os.shutdown()
end

local function loadSteps()
    local suite = (readText("testsuite.txt") or ""):match("^%s*(.-)%s*$")
    local suites = dofile("teststeps.lua")
    local steps = suites[suite]
    if not steps then error("teststeps.lua has no suite '" .. suite .. "'", 0) end
    log("suite: " .. suite)
    return steps
end

local function click(position, button)
    os.queueEvent("mouse_click", button or 1, position[1], position[2])
    os.queueEvent("mouse_up", button or 1, position[1], position[2])
end

local function runSteps()
    local steps = loadSteps()
    for _, step in ipairs(steps) do
        if step.await then
            local deadline = os.clock() + (step.timeout or 10)
            while not shows(step.await) and os.clock() < deadline do sleep(0.1) end
            if not shows(step.await) then
                snapshot("waited in vain for '" .. step.await .. "'")
                fail("the screen never showed '" .. step.await .. "'")
            end
        elseif step.expect then
            if not shows(step.expect) then
                snapshot("expected '" .. step.expect .. "'")
                fail("the screen does not show '" .. step.expect .. "'")
            end
        elseif step.absent then
            if shows(step.absent) then
                snapshot("did not expect '" .. step.absent .. "'")
                fail("the screen shows '" .. step.absent .. "'")
            end
        elseif step.wait then
            sleep(step.wait)
        elseif step.snapshot then
            snapshot(step.snapshot)
        elseif step.text then
            for index = 1, #step.text do
                os.queueEvent("char", step.text:sub(index, index))
            end
        elseif step.key then
            os.queueEvent("key", keys[step.key], false)
            os.queueEvent("key_up", keys[step.key])
        elseif step.double then
            click(step.double)
            click(step.double)
        elseif step.click then
            click(step.click, step.button)
        elseif step.event then
            os.queueEvent(table.unpack(step.event))
        elseif step.report_file then
            local text = readText(step.report_file)
            log("")
            log("--- " .. step.report_file .. " ---")
            log(text or "(missing)")
            if not text then
                fail(step.report_file .. " was not written")
            elseif ("\n" .. text):find("\nFAIL", 1, true) then
                fail(step.report_file .. " reports a failure")
            end
        end
        sleep(0.15)
    end
    finish()
end

if fs.exists(STORE_FILES) then serveStoreLocally() end

local previous = term.redirect(screen)
local ok, message = pcall(parallel.waitForAny,
    function()
        shell.run("boot.lua")
        fail("the system stopped running")
        sleep(1)
    end,
    runSteps
)
term.redirect(previous)
if not ok then fail("harness error: " .. tostring(message)) end
snapshot("at exit")
finish()
