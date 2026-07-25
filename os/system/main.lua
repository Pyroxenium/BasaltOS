-- /system/main.lua
-- Entry point: Initializes kernel and handles critical errors

local error_sys = require("core.error_sys")

local function main()

    local function errorHandler(err)
        local trace = debug.traceback()

        error_sys.logKernelPanic(err, trace)

        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.red)
        print("=== KERNEL PANIC ===")
        term.setTextColor(colors.white)
        print("\nError: " .. tostring(err))
        print("\nStack trace:")
        print(trace)
        term.setTextColor(colors.yellow)
        print("\nError logged to: system/logs/error.log")
        print("\nPress any key to reboot...")
        os.pullEvent("key")
        os.reboot()
    end

    local ok, err = xpcall(function()
        local kernel = require("core.kernel")

        kernel.boot()

        kernel.run()
    end, errorHandler)

    if not ok then
        return
    end
end

main()
