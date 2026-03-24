-- /system/core/kernel.lua
-- Core kernel: Manages system boot, services, and main event loop

local kernel = {}
local config = require("core.config")
local event = require("core.event")
local service = require("core.service")
local error_sys = require("core.error_sys")

local running = false
local boot_completed = false

local boot_log_file = nil
local function bootLog(message, level)
    level = level or "INFO"
    local timestamp = os.date("%H:%M:%S")
    local log_line = string.format("[%s] [%s] %s", timestamp, level, message)

    if boot_log_file then
        boot_log_file.writeLine(log_line)
        boot_log_file.flush()
    end
    print(message)
end

local function initBootLog()
    if not fs.exists("system/logs") then
        fs.makeDir("system/logs")
    end

    boot_log_file = fs.open("system/logs/boot.log", "w")
    if boot_log_file then
        bootLog("Boot log initialized", "DEBUG")
    end
end

local function closeBootLog()
    if boot_log_file then
        bootLog("Boot log closed", "DEBUG")
        boot_log_file.close()
        boot_log_file = nil
    end
end

function kernel.boot()
    initBootLog()
    
    term.clear()
    term.setCursorPos(1, 1)
    bootLog("BasaltOS booting...")
    bootLog("Loading configuration...")
    config.load()
    bootLog("Initializing event system...")
    event.init()
    bootLog("Registering services...")
    kernel.registerCoreServices()
    bootLog("Initializing services...")
    kernel.initializeServices()
    bootLog("Boot completed!", "INFO")
    closeBootLog()
    event.dispatch("system.boot_complete")
end

-- Auto-discover and register all services from system/services/
function kernel.registerCoreServices()
    local services_path = "system/services"
    local loaded_count = 0
    local failed_count = 0
    bootLog("  Scanning services directory...")

    if not fs.exists(services_path) or not fs.isDir(services_path) then
        bootLog("  ! Services directory not found", "ERROR")
        return
    end

    local files = fs.list(services_path)

    for _, filename in ipairs(files) do
        if filename:match("%.lua$") then
            local service_name = filename:gsub("%.lua$", "")
            local service_path = "services." .. service_name

            local ok, err = pcall(function()
                service.register(service_name, service_path)
            end)

            if ok then
                bootLog("  [OK] Service loaded: " .. service_name, "INFO")
                loaded_count = loaded_count + 1
            else
                bootLog("  [FAIL] Service failed: " .. service_name, "ERROR")
                bootLog("    Error: " .. tostring(err), "ERROR")
                failed_count = failed_count + 1
            end
        end
    end
    bootLog("  ---")
    bootLog("  Services: " .. loaded_count .. " loaded, " .. failed_count .. " failed", "INFO")
end

function kernel.initializeServices()
    local services = service.getAllServices()

    for name, svc in pairs(services) do
        if svc.init and type(svc.init) == "function" then
            bootLog("  - Initializing service: " .. name, "DEBUG")
            local ok, err = pcall(svc.init)
            if not ok then
                bootLog("  [FAIL] Service init failed: " .. name, "ERROR")
                bootLog("    Error: " .. tostring(err), "ERROR")
                error("Failed to initialize service '" .. name .. "': " .. tostring(err))
            end
        end
    end
end

function kernel.run()
    running = true

    print("\nStarting main event loop...")
    print("(Press Ctrl+T to terminate)\n")

    while running do
        local eventData = {os.pullEventRaw()}
        local eventType = eventData[1]

        if eventType == "terminate" then
            kernel.shutdown()
            break
        end

        event.dispatch(eventType, table.unpack(eventData, 2))
    end
end

function kernel.shutdown()
    print("\nShutting down...")

    event.dispatch("system.shutdown")

    config.save()
    running = false
    print("Goodbye!")
    --sleep(0.2)
    --os.shutdown() // Uncomment this line to actually shut down the computer
end

function kernel.isRunning()
    return running
end

function kernel.isBootCompleted()
    return boot_completed
end

return kernel
