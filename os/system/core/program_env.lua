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
--   context.executable - resolved path of the running program

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
    local executable = context.executable

    -- require / package
    -- Match CraftOS semantics inside a managed window. Libraries can locate
    -- assets relative to the actual app instead of seeing BasaltOS' launcher
    -- as the running program. Do not mutate the host shell table.
    env.shell = setmetatable({}, {__index = shell})
    if executable then
        function env.shell.getRunningProgram()
            return executable
        end
    end
    env.require, env.package = make_pkg(env, "/")

    -- User-registered PineStore libraries become ordinary require() modules
    -- for each newly started app. Exact preload mappings make the selected
    -- entry file authoritative, while the root paths allow its companion
    -- modules to resolve normally.
    local libraries = service.getService("libraries")
    if libraries and libraries.list then
        for _, record in ipairs(libraries.list()) do
            local module_name = tostring(record.module_name or "")
            local entry_path = tostring(record.entry_path or "")
            local root_path = tostring(record.root_path or fs.getDir(entry_path))
            if module_name ~= "" and entry_path ~= ""
                and not env.package.preload[module_name] then
                env.package.path = table.concat({
                    fs.combine(root_path, "?.lua"),
                    fs.combine(root_path, "?/init.lua"),
                    env.package.path,
                }, ";")
                local selected_module = module_name
                local selected_entry = entry_path
                env.package.preload[selected_module] = function()
                    local fn, load_error
                    if setfenv then
                        fn, load_error = loadfile(selected_entry)
                        if fn then setfenv(fn, env) end
                    else
                        fn, load_error = loadfile(selected_entry, "t", env)
                    end
                    if not fn then error(load_error, 0) end
                    return fn()
                end
            end
        end
    end

    -- Convenience detection for the small number of genuinely OS-specific
    -- integrations. Portable code should still feature-detect app services.
    env.isBasaltOS = true
    env.basaltOS = {
        apiVersion=1,
        appDir=program_dir,
        executable=executable,
    }

    local function contextualContextMenu()
        local contextmenu = service.getService("contextmenu")
        if not contextmenu then return nil end
        local contextual = {}

        function contextual.open(x, y, items, options)
            if contextmenu.openForWindowPoint then
                return contextmenu.openForWindowPoint(window_id, x, y, items, options)
            end
            return contextmenu.open(x, y, items, options)
        end

        function contextual.openFor(source, x, y, items, options)
            if contextmenu.openForWindow then
                return contextmenu.openForWindow(window_id, source, x, y, items, options)
            end
            return contextmenu.openFor(source, x, y, items, options)
        end

        function contextual.create(items, options)
            local contextual_options = {}
            for key, value in pairs(options or {}) do contextual_options[key] = value end
            contextual_options.window_id = window_id
            return contextmenu.create(items, contextual_options)
        end

        return setmetatable(contextual, {__index=contextmenu})
    end

    env.package.preload["app"] = function()
        return setmetatable({
            theme = function(key, fallback)
            local cfg = require("core.config")
            return cfg.get("theme." .. key) or fallback or colors.black
            end,
            contextmenu = contextualContextMenu(),
        }, { __index = app_api })
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
                -- Route arbitrary paths through the managed Exec system app so
                -- they receive a normal PID, window and lifecycle.
                local launch_args = {sProgramPath, ...}
                return process_service.startProgram("exec", launch_args)
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
                if wm.setWindowTitle then
                    return wm.setWindowTitle(window_id, sTitle)
                end
                windows[window_id].title = tostring(sTitle)
                return true
            end
            return false
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

    -- Window control API. Preserve the native CC window module through
    -- __index: Basalt's embedded Program element needs window.create(), while
    -- BasaltOS apps also use window.getId(), window.close(), and friends.
    -- Replacing the module outright made those two APIs collide.
    env.window = setmetatable({
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

        isMaximized = function()
            local w = windows[window_id]
            return w and w.maximized == true or false
        end,

        setTitle = function(title)
            local w = windows[window_id]
            if not w then return false end
            if wm.setWindowTitle then
                return wm.setWindowTitle(window_id, title)
            end
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

        maximize = function()
            return wm.maximizeWindow(window_id)
        end,

        restore = function()
            return wm.restoreWindow(window_id)
        end,

        close = function()
            return wm.closeWindow(window_id)
        end,

        -- The handler receives resolve(allow), so apps can wait for an
        -- asynchronous confirmation dialog before allowing the close.
        -- Passing nil removes the handler again.
        setCloseHandler = function(handler)
            if wm.setWindowCloseHandler then
                return wm.setWindowCloseHandler(window_id, handler)
            end
            return false, "Close handlers are not supported"
        end,
    }, {__index = window})

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
