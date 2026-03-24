-- Dialog Service
-- Custom dialog system for BasaltOS (alert, confirm, prompt, file picker)

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")

local api = api_factory.new()

local active_dialogs = {}
local next_dialog_id = 1
local desktop_frame  = nil

local DIALOG_W   = 32
local FINAL_Y    = 3
local BTN_W      = 10
local BTN_SPACING = 2

local function theme(key) return config.get("theme." .. key) end

-- ── Init ──────────────────────────────────────────────────────────────────────

function api.public.init()
    event.on("desktop.created", function()
        local ui = service.getService("ui")
        if not ui then return end
        desktop_frame = ui.getScreen("desktop")
        log.info("DIALOG", "Service initialized")
    end)

    event.on("wm.app_crashed", function(app_name, err_msg)
        api.public.alert(app_name .. " crashed", err_msg)
    end)

    event.on("basaltshell.ready", function()
        local shell = service.getService("basaltshell")
        if shell then
            shell.registerBuiltin("alert", function(args)
                if #args == 0 then return false, "Usage: alert <message>" end
                api.public.alert("Shell", table.concat(args, " "))
                return true, nil
            end)
        end
    end)
end

-- ── Core builder ──────────────────────────────────────────────────────────────

-- Wraps a content height into a fully decorated dialog frame (title bar + border).
-- Returns: overlay (modal blocker), frame (the dialog), content_y (first free row inside)
local function buildFrame(title, content_h)
    local screen_w, _ = desktop_frame:getSize()
    local total_h = 2 + content_h  -- 1 titlebar + 1 gap + content rows + 1 bottom gap = content_h already includes those
    local final_x = math.floor((screen_w - DIALOG_W) / 2) + 1

    local id = next_dialog_id
    next_dialog_id = next_dialog_id + 1

    -- Dialog frame, starts off-screen above
    local frame = desktop_frame:addFrame({
        x=final_x, y=-(total_h),
        width=DIALOG_W, height=total_h,
        background=theme("secondary"),
    })
    frame:addBorder(theme("border"), { top=true, bottom=true, left=true, right=true })
    frame:setZ(200)

    -- Title bar
    frame:addVisualElement({ x=1, y=1, width=DIALOG_W, height=1, background=theme("primary") })
    frame:addLabel({ x=2, y=1, text=title:sub(1, DIALOG_W-2), foreground=theme("text"), background=theme("primary") })

    active_dialogs[id] = { frame=frame }

    return id, frame, final_x, total_h
end

local function slideIn(frame, final_x)
    frame:setVisible(true)
    frame:animate()
        :move(final_x, FINAL_Y, 0.2, "easeOutQuad")
        :start()
end

local function slideOut(id, frame, callback)
    frame:animate()
        :move(frame:getX(), -(frame:getHeight()), 0.15, "easeInQuad")
        :onComplete(function()
            frame:destroy()
            active_dialogs[id] = nil
            if callback then callback() end
        end)
        :start()
end

-- Centered button X helper
local function btnX(count, index)
    -- count: total number of buttons, index: 1-based
    local total = count * BTN_W + (count - 1) * BTN_SPACING
    local start = math.floor((DIALOG_W - total) / 2) + 1
    return start + (index - 1) * (BTN_W + BTN_SPACING)
end

-- ── Alert ─────────────────────────────────────────────────────────────────────

function api.public.alert(title, message, callback)
    if not desktop_frame then return end
    local msg_w = DIALOG_W - 4
    local msg_lines = math.max(1, math.ceil(#message / msg_w))
    local total_h = 1 + 1 + msg_lines + 1 + 1 + 1

    local id, frame, final_x, _ = buildFrame(title, total_h - 2)
    frame:setHeight(total_h)

    frame:addLabel({
        x=3, y=3, width=msg_w,
        text=message, foreground=theme("text"), background=theme("secondary"),
        autoSize=false,
    })

    local bx = btnX(1, 1)
    frame:addButton({
        x=bx, y=total_h-1, width=BTN_W, height=1,
        text="OK",
        background=theme("success"), foreground=theme("text_on_light"),
    }):onClick(function()
        slideOut(id, frame, callback)
    end)

    slideIn(frame, final_x)
end

-- ── Confirm ───────────────────────────────────────────────────────────────────

function api.public.confirm(title, message, callback)
    if not desktop_frame then return end
    local msg_w = DIALOG_W - 4
    local msg_lines = math.max(1, math.ceil(#message / msg_w))
    local total_h = 1 + 1 + msg_lines + 1 + 1 + 1

    local id, frame, final_x, _ = buildFrame(title, total_h - 2)
    frame:setHeight(total_h)

    frame:addLabel({
        x=3, y=3, width=msg_w,
        text=message, foreground=theme("text"), background=theme("secondary"),
        autoSize=false,
    })

    frame:addButton({
        x=btnX(2,1), y=total_h-1, width=BTN_W, height=1,
        text="Cancel",
        background=theme("surface"), foreground=theme("text_on_light"),
    }):onClick(function()
        slideOut(id, frame, function() if callback then callback(false) end end)
    end)

    frame:addButton({
        x=btnX(2,2), y=total_h-1, width=BTN_W, height=1,
        text="OK",
        background=theme("success"), foreground=theme("text_on_light"),
    }):onClick(function()
        slideOut(id, frame, function() if callback then callback(true) end end)
    end)

    slideIn(frame, final_x)
end

-- ── Prompt ────────────────────────────────────────────────────────────────────

function api.public.prompt(title, message, default, callback)
    if not desktop_frame then return end
    local msg_w = DIALOG_W - 4
    local total_h = 1 + 1 + 1 + 1 + 1 + 1 + 1  -- titlebar+gap+msg+input+gap+btn+gap

    local id, frame, final_x, _ = buildFrame(title, total_h - 2)
    frame:setHeight(total_h)

    frame:addLabel({
        x=3, y=3, text=message:sub(1, msg_w),
        foreground=theme("text"), background=theme("secondary"),
    })

    local input = frame:addInput({
        x=3, y=4, width=DIALOG_W-4, height=1,
        defaultText=default or "",
        background=theme("surface"), foreground=theme("text"),
    })

    frame:addButton({
        x=btnX(2,1), y=total_h-1, width=BTN_W, height=1,
        text="Cancel",
        background=theme("surface"), foreground=theme("text_on_light"),
    }):onClick(function()
        slideOut(id, frame, function() if callback then callback(nil) end end)
    end)

    frame:addButton({
        x=btnX(2,2), y=total_h-1, width=BTN_W, height=1,
        text="OK",
        background=theme("success"), foreground=theme("text_on_light"),
    }):onClick(function()
        local value = input.get("text") or ""
        slideOut(id, frame, function() if callback then callback(value) end end)
    end)

    slideIn(frame, final_x)
end

-- ── File Picker ───────────────────────────────────────────────────────────────
-- filter: "files" | "dirs" | "all" (default: "files")

function api.public.file(title, start_path, filter, callback)
    if not desktop_frame then return end
    filter = filter or "files"
    local cwd = start_path or "/"

    local FILE_H  = 14
    local total_h = 1 + 1 + 1 + FILE_H + 1 + 1 + 1  -- titlebar+gap+pathbar+list+gap+btn+gap

    local id, frame, final_x, _ = buildFrame(title, total_h - 2)
    frame:setHeight(total_h)

    -- Path bar
    local path_label = frame:addLabel({
        x=2, y=3, width=DIALOG_W-2, height=1,
        text="", foreground=theme("text_dim"), background=theme("secondary"),
    })

    -- File list
    local file_list = frame:addList({
        x=2, y=4, width=DIALOG_W-2, height=FILE_H,
        background=theme("surface"), foreground=theme("text"),
    })
    file_list:setSelectionColor(theme("primary"), theme("text"))

    -- Buttons
    frame:addButton({
        x=btnX(2,1), y=total_h-1, width=BTN_W, height=1,
        text="Cancel",
        background=theme("surface"), foreground=theme("text_on_light"),
    }):onClick(function()
        slideOut(id, frame, function() if callback then callback(nil) end end)
    end)

    local ok_btn = frame:addButton({
        x=btnX(2,2), y=total_h-1, width=BTN_W, height=1,
        text="Open",
        background=theme("success"), foreground=theme("text_on_light"),
    })

    -- State
    local selected_path = nil
    local entries = {}

    local function loadDir(path)
        cwd = path
        selected_path = nil
        entries = {}
        file_list:clear()

        -- Truncate path for display
        local display = cwd
        if #display > DIALOG_W - 3 then
            display = "\26" .. display:sub(-(DIALOG_W - 5))
        end
        path_label:setText(display)

        -- Parent dir entry
        if cwd ~= "/" then
            table.insert(entries, { label=" \26 ..", path=fs.getDir(cwd), isDir=true })
            file_list:addItem(" \x11 ..", nil, theme("text_dim"), theme("surface"))
        end

        local items = fs.list(cwd)
        -- Dirs first, then files
        local dirs, files = {}, {}
        for _, name in ipairs(items) do
            local full = fs.combine(cwd, name)
            if fs.isDir(full) then
                table.insert(dirs, name)
            else
                table.insert(files, name)
            end
        end
        table.sort(dirs)
        table.sort(files)

        for _, name in ipairs(dirs) do
            local full = fs.combine(cwd, name)
            table.insert(entries, { label=name, path=full, isDir=true })
            file_list:addItem(" \x10 " .. name, nil, theme("primary"), theme("surface"))
        end

        if filter ~= "dirs" then
            for _, name in ipairs(files) do
                local full = fs.combine(cwd, name)
                table.insert(entries, { label=name, path=full, isDir=false })
                file_list:addItem("   " .. name, nil, theme("text"), theme("surface"))
            end
        end
    end

    file_list:onChange("selectedItem", function(_, item)
        if not item then return end
        local idx = file_list:getItemIndex()
        local entry = entries[idx]
        if not entry then return end
        if entry.isDir then
            if filter == "dirs" then
                selected_path = entry.path
            else
                loadDir(entry.path)
            end
        else
            selected_path = entry.path
        end
    end)

    file_list:onDoubleClick(function()
        local idx = file_list:getItemIndex()
        local entry = entries[idx]
        if not entry then return end
        if entry.isDir then
            loadDir(entry.path)
        else
            local p = entry.path
            slideOut(id, frame, function() if callback then callback(p) end end)
        end
    end)

    ok_btn:onClick(function()
        if not selected_path then return end
        local p = selected_path
        slideOut(id, frame, function() if callback then callback(p) end end)
    end)

    loadDir(cwd)
    slideIn(frame, final_x)
end

-- ── Utility ───────────────────────────────────────────────────────────────────

function api.public.isActive()
    for _ in pairs(active_dialogs) do return true end
    return false
end

function api.public.getActiveCount()
    local count = 0
    for _ in pairs(active_dialogs) do count = count + 1 end
    return count
end

function api.public.closeAll()
    for _, d in pairs(active_dialogs) do
        if d.frame then d.frame:destroy() end
    end
    active_dialogs = {}
end

return api

