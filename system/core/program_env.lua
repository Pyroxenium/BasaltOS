-- /system/core/program_env.lua
-- Program Environment Builder: Constructs the sandboxed environment APIs
-- injected into every app process. Add new APIs here; WM picks them up automatically.
--
-- Each builder receives a context table:
--   context.pid        - process ID
--   context.window_id  - window ID
--   context.windows    - reference to WM windows table
--   context.wm         - WM public API (api.public)
--   context.focused    - function() -> currently focused window_id

local service = require("core.service")
local app_api = require("core.app_api")

local program_env = {}

-- Build and return the full sandboxed environment for a program.
-- @param base_env   table  The base environment (setmetatable'd against _ENV by WM)
-- @param context    table  Context provided by WM (see above)
-- @param make_pkg   func   make_package function from CC require module
-- @param program_dir string  Directory of the executable
function program_env.build(base_env, context, make_pkg, program_dir)
    local env = base_env
    local pid        = context.pid
    local window_id  = context.window_id
    local windows    = context.windows
    local wm         = context.wm
    local getFocused = context.focused

    -- require / package
    env.shell = shell
    env.require, env.package = make_pkg(env, "/")

    env.package.preload["app"] = function()
        return setmetatable({ theme = function(key, fallback)
            local cfg = require("core.config")
            return cfg.get("theme." .. key) or fallback or colors.black
        end }, { __index = app_api })
    end

    env.package.path = table.concat({
        program_dir .. "/?.lua",
        program_dir .. "/?/init.lua",
        "system/?.lua",
        "system/?/init.lua",
        "system/lib/public/?.lua",
        "system/lib/public/?/init.lua",
    }, ";") .. ";" .. env.package.path

    -- os extension
    env.os = setmetatable({
        getProcessId = function()
            return pid
        end,
        getWindowId = function()
            return window_id
        end,
    }, {__index = os})

    -- multishell compatibility shim
    env.multishell = {
        launch = function(tProgramEnv, sProgramPath, ...)
            local process_service = service.getPrivateApi("process")
            if process_service then
                return process_service.startProgram("unknown_app", sProgramPath, {...})
            end
            return nil
        end,

        getCurrent = function()
            return pid
        end,

        getCount = function()
            local process_service = service.getPrivateApi("process")
            if process_service then
                local count = 0
                for _ in pairs(process_service.listProcesses()) do count = count + 1 end
                return count
            end
            return 1
        end,

        setTitle = function(nTask, sTitle)
            if nTask == pid and windows[window_id] then
                windows[window_id].title = tostring(sTitle)
            end
        end,

        getTitle = function(nTask)
            if nTask == pid and windows[window_id] then
                return windows[window_id].title
            end
            return nil
        end,

        setFocus = function(nTask)
            if nTask == pid then
                wm.focusWindow(window_id)
                return true
            end
            return false
        end,

        getFocus = function()
            local fw = getFocused()
            if fw and windows[fw] then
                return windows[fw].pid
            end
            return nil
        end,
    }

    -- window control API
    env.window = {
        getId = function()
            return window_id
        end,

        getTitle = function()
            local w = windows[window_id]
            return w and w.title or nil
        end,

        getSize = function()
            local w = windows[window_id]
            if not w or not w.frame then return nil end
            return w.width, w.height
        end,

        getPosition = function()
            local w = windows[window_id]
            if not w or not w.frame then return nil end
            return w.frame.get("x"), w.frame.get("y")
        end,

        isVisible = function()
            local w = windows[window_id]
            if not w or not w.frame then return false end
            return w.frame:getVisible()
        end,

        isFocused = function()
            return getFocused() == window_id
        end,

        setTitle = function(title)
            local w = windows[window_id]
            if not w then return false end
            w.title = tostring(title)
            return true
        end,

        setSize = function(width, height)
            return wm.resizeWindow(window_id, width, height)
        end,

        setPosition = function(x, y)
            return wm.moveWindow(window_id, x, y)
        end,

        focus = function()
            return wm.focusWindow(window_id)
        end,

        minimize = function()
            return wm.minimizeWindow(window_id)
        end,

        restore = function()
            return wm.restoreWindow(window_id)
        end,

        close = function()
            return wm.closeWindow(window_id)
        end,
    }

    -- clipboard API
    -- clipboard.paste() routes string content through the native CC paste event,
    -- so Basalt automatically delivers it to whichever Input is currently focused.
    -- Non-string data (tables etc.) must be consumed manually via clipboard.get().
    env.clipboard = {
        set = function(data)
            local svc = service.getService("clipboard")
            if svc then svc.set(data) end
        end,

        get = function()
            local svc = service.getService("clipboard")
            return svc and svc.get()
        end,

        paste = function()
            local svc = service.getService("clipboard")
            if not svc then return end
            local data = svc.get()
            if type(data) == "string" then
                -- Let Basalt route to the focused element automatically
                os.queueEvent("paste", data)
            end
            return data
        end,

        isEmpty = function()
            local svc = service.getService("clipboard")
            return svc and svc.isEmpty() or true
        end,

        clear = function()
            local svc = service.getService("clipboard")
            if svc then svc.clear() end
        end,
    }

    return env
end

return program_env
