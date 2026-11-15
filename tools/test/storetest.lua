-- Test-only service. tools/test.ps1 copies it into system/services of a
-- throwaway computer whose HTTP API is served from a packed store
-- (see boottest.lua). Two events drive it; each writes one "ok" or "FAIL"
-- line per check:
--   "storetest_install" <app id>   install the app through the store service
--                                  (result in /storetest-install.txt)
--   "storetest_start" <app id>     after a reboot: the app is still there
--                                  (result in /storetest-start.txt)

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")

local api = api_factory.new()

local function contains(list, value)
    for _, item in ipairs(list or {}) do
        if item == value then return true end
    end
    return false
end

local function install(app_id, check)
    local store = service.getService("basaltstore")
    local registry = service.getService("registry")
    local process = service.getService("process")
    local runtime = _G.bpk
    local app_folder = fs.combine("apps", app_id)

    local refreshed, refresh_error = store.refresh(true)
    check("the catalog of the packed store loads", refreshed, refresh_error)
    local app = store.getApp(app_id)
    check("the catalog offers the app as a package",
        app ~= nil and contains(app.source.files, "app.bpk"))
    if not app then return end

    _G.storetest_damage = true
    local installed, install_error = store.installApp(app_id)
    _G.storetest_damage = false
    check("a damaged download is rejected",
        not installed and tostring(install_error):find("damaged", 1, true) ~= nil,
        install_error)
    check("a rejected download leaves nothing behind",
        not registry.hasProgram(app_id) and not fs.exists(app_folder))

    installed, install_error = store.installApp(app_id)
    check("a clean download is installed", installed, install_error)
    if not installed then return end

    local program = registry.getProgram(app_id)
    check("the registry knows the app", program ~= nil)
    check("the package stays compressed on disk",
        runtime.native.exists(fs.combine(app_folder, "app.bpk")))
    local executable = program and program.executable or fs.combine(app_folder, "main.lua")
    check("the code exists only inside the package",
        fs.exists(executable) and not runtime.native.exists(executable)
            and runtime.isPackaged(executable),
        executable)

    local pid, start_error = process.startProgram(app_id)
    check("the installed app starts", pid ~= nil, start_error)
end

local function startAfterReboot(app_id, check)
    local registry = service.getService("registry")
    local process = service.getService("process")
    local runtime = _G.bpk

    local program = registry.getProgram(app_id)
    check("the app is still registered after a reboot", program ~= nil)
    if not program then return end
    check("the boot loader mounted its package",
        fs.exists(program.executable) and runtime.isPackaged(program.executable),
        program.executable)
    local pid, start_error = process.startProgram(app_id)
    check("the app starts after a reboot", pid ~= nil, start_error)
end

-- Run one scenario and write its checks to the result file.
local function report(result_path, scenario, app_id)
    local lines = {}
    local function check(name, condition, detail)
        local line = (condition and "ok    " or "FAIL  ") .. name
        if not condition and detail ~= nil then line = line .. " (" .. tostring(detail) .. ")" end
        lines[#lines + 1] = line
    end

    local ok, message = pcall(scenario, tostring(app_id), check)
    if not ok then lines[#lines + 1] = "FAIL  test aborted: " .. tostring(message) end
    local handle = fs.open(result_path, "w")
    handle.write(table.concat(lines, "\n") .. "\n")
    handle.close()
end

function api.public.init()
    event.on("storetest_install", function(app_id)
        report("storetest-install.txt", install, app_id)
    end)
    event.on("storetest_start", function(app_id)
        report("storetest-start.txt", startAfterReboot, app_id)
    end)
end

return api
