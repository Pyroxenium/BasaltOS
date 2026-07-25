-- /services/startmenu.lua
-- Compact icon-aware start menu for the two-row taskbar.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")
local icon = require("core.icon")
local ui_helpers = require("core.ui_helpers")

local function theme(key) return config.get("theme." .. key) end

local api = api_factory.new()

local TASKBAR_HEIGHT = 2
local DEFAULT_PINNED = {"launcher", "filely", "basaltterminal", "settings"}
local PINNED_CONFIG = "startmenu.pinned"
local RECENT_CONFIG = "startmenu.recent"
local RECENT_STORAGE_LIMIT = 20

local menu_frame = nil
local is_open = false

local function fitText(value, width)
    local text = tostring(value or "")
    width = math.max(0, math.floor(tonumber(width) or 0))
    if #text <= width then return text end
    if width <= 2 then return (".."):sub(1, width) end
    return text:sub(1, width - 2) .. ".."
end

local function bindHover(source, callback)
    source:onMouseEnter(function() callback(true) end)
    source:onMouseLeave(function() callback(false) end)
end

local function setting(path, fallback)
    local settings = service.getService("settings")
    if not settings or not settings.get then return fallback end
    return settings.get(path, fallback)
end

local function copyArray(source)
    local result = {}
    for _, value in ipairs(source or {}) do result[#result + 1] = value end
    return result
end

local function storedList(path, fallback)
    if type(config.getUserConfig) ~= "function" then return copyArray(fallback) end
    local value = config.getUserConfig(path, nil)
    if type(value) ~= "table" then return copyArray(fallback) end
    return copyArray(value)
end

local function saveList(path, value)
    if type(config.setUserConfig) ~= "function" then return false end
    return config.setUserConfig(path, copyArray(value), true)
end

local function cleanIds(source, limit)
    local registry = service.getService("registry")
    local result, seen = {}, {}
    if not registry then return result end
    for _, program_id in ipairs(source or {}) do
        if type(program_id) == "string" and not seen[program_id]
            and registry.getProgram(program_id) then
            seen[program_id] = true
            result[#result + 1] = program_id
            if limit and #result >= limit then break end
        end
    end
    return result
end

local function sameIds(left, right)
    if #left ~= #right then return false end
    for index, value in ipairs(left) do
        if right[index] ~= value then return false end
    end
    return true
end

local function programsForIds(ids, limit)
    local registry = service.getService("registry")
    local result = {}
    if not registry then return result end
    for _, program_id in ipairs(ids or {}) do
        local program = registry.getProgram(program_id)
        if program then
            result[#result + 1] = program
            if limit and #result >= limit then break end
        end
    end
    return result
end

local function refreshOpenMenu()
    if not is_open or not menu_frame then return end
    api.public.hide(true)
    api.public.show()
end

function api.public.getPinned()
    return cleanIds(storedList(PINNED_CONFIG, DEFAULT_PINNED))
end

function api.public.getRecent(limit)
    limit = math.max(1, math.floor(tonumber(limit) or RECENT_STORAGE_LIMIT))
    return cleanIds(storedList(RECENT_CONFIG, {}), limit)
end

function api.public.isPinned(program_id)
    for _, candidate in ipairs(api.public.getPinned()) do
        if candidate == program_id then return true end
    end
    return false
end

function api.public.pin(program_id)
    local registry = service.getService("registry")
    if type(program_id) ~= "string" or not registry
        or not registry.getProgram(program_id) then
        return false, "Program not found"
    end
    local pinned = api.public.getPinned()
    for _, candidate in ipairs(pinned) do
        if candidate == program_id then return true end
    end
    pinned[#pinned + 1] = program_id
    if not saveList(PINNED_CONFIG, pinned) then return false, "No user logged in" end
    event.dispatch("startmenu.pins_changed", api.public.getPinned())
    refreshOpenMenu()
    return true
end

function api.public.unpin(program_id)
    local pinned = api.public.getPinned()
    local removed = false
    for index = #pinned, 1, -1 do
        if pinned[index] == program_id then
            table.remove(pinned, index)
            removed = true
        end
    end
    if not removed then return true end
    if not saveList(PINNED_CONFIG, pinned) then return false, "No user logged in" end
    event.dispatch("startmenu.pins_changed", api.public.getPinned())
    refreshOpenMenu()
    return true
end

function api.public.addRecent(program_id)
    local registry = service.getService("registry")
    if type(program_id) ~= "string" or not registry
        or not registry.getProgram(program_id) then
        return false, "Program not found"
    end
    local recent = api.public.getRecent(RECENT_STORAGE_LIMIT)
    for index = #recent, 1, -1 do
        if recent[index] == program_id then table.remove(recent, index) end
    end
    table.insert(recent, 1, program_id)
    while #recent > RECENT_STORAGE_LIMIT do table.remove(recent) end
    if not saveList(RECENT_CONFIG, recent) then return false, "No user logged in" end
    event.dispatch("startmenu.recent_changed", api.public.getRecent())
    return true
end

function api.public.clearRecent()
    if not saveList(RECENT_CONFIG, {}) then return false, "No user logged in" end
    event.dispatch("startmenu.recent_changed", {})
    refreshOpenMenu()
    return true
end

function api.public.removeRecent(program_id)
    local recent = api.public.getRecent(RECENT_STORAGE_LIMIT)
    local removed = false
    for index = #recent, 1, -1 do
        if recent[index] == program_id then
            table.remove(recent, index)
            removed = true
        end
    end
    if not removed then return true end
    if not saveList(RECENT_CONFIG, recent) then return false, "No user logged in" end
    event.dispatch("startmenu.recent_changed", api.public.getRecent())
    refreshOpenMenu()
    return true
end

function api.private.removeProgram(program_id)
    local pinned = storedList(PINNED_CONFIG, DEFAULT_PINNED)
    local recent = storedList(RECENT_CONFIG, {})
    local changed_pinned, changed_recent = false, false
    for index = #pinned, 1, -1 do
        if pinned[index] == program_id then
            table.remove(pinned, index)
            changed_pinned = true
        end
    end
    for index = #recent, 1, -1 do
        if recent[index] == program_id then
            table.remove(recent, index)
            changed_recent = true
        end
    end
    if changed_pinned then saveList(PINNED_CONFIG, pinned) end
    if changed_recent then saveList(RECENT_CONFIG, recent) end
    if changed_pinned or changed_recent then refreshOpenMenu() end
end

function api.private.pruneStoredPrograms()
    local pinned = storedList(PINNED_CONFIG, DEFAULT_PINNED)
    local recent = storedList(RECENT_CONFIG, {})
    local clean_pinned = cleanIds(pinned)
    local clean_recent = cleanIds(recent, RECENT_STORAGE_LIMIT)
    if not sameIds(pinned, clean_pinned) then
        saveList(PINNED_CONFIG, clean_pinned)
    end
    if not sameIds(recent, clean_recent) then
        saveList(RECENT_CONFIG, clean_recent)
    end
end

function api.public.init()
    event.on("process.started", function(_, program_id, process_type)
        if process_type == "windowed" then api.public.addRecent(program_id) end
    end)
    event.on("registry.program_uninstalled", function(program_id)
        api.private.removeProgram(program_id)
    end)
    event.on("registry.reloaded", function(username)
        if username then api.private.pruneStoredPrograms() end
    end)
    event.on("startmenu.settings_changed", function()
        refreshOpenMenu()
    end)
    event.on("user.logout", function()
        api.public.hide(true)
    end)
    event.on("theme.changed", function()
        api.public.hide(true)
    end)
    log.debug("STARTMENU", "Icon start menu service initialized")
end

function api.public.show()
    if is_open then return end
    local ui = service.getService("ui")
    if not ui then
        log.error("STARTMENU", "UI service not available")
        return
    end
    local desktop_frame = ui.getScreen("desktop")
    if not desktop_frame then
        log.error("STARTMENU", "Desktop frame not available")
        return
    end

    api.private.createMenu(desktop_frame)
    is_open = menu_frame ~= nil
end

function api.public.hide(immediate)
    if not menu_frame then
        is_open = false
        return
    end

    local frame = menu_frame
    menu_frame = nil
    is_open = false
    if immediate then
        frame:destroy()
        return
    end

    local _, screen_height = frame:getRoot():getSize()
    frame:animate({x=1, y=screen_height + 1}, 0.15, "easeIn", function()
        frame:destroy()
    end)
end

function api.public.toggle()
    if is_open then api.public.hide() else api.public.show() end
end

function api.private.createMenu(parent_frame)
    local process = service.getService("process")
    if not process then
        log.error("STARTMENU", "Process service not available")
        return
    end

    local screen_width, screen_height = parent_frame:getSize()
    local taskbar = service.getService("taskbar")
    local work_area = taskbar and taskbar.getWorkArea and taskbar.getWorkArea()
        or {
            x=1, y=1, width=screen_width,
            height=math.max(1, screen_height - TASKBAR_HEIGHT),
        }
    local show_recent = setting("startmenu.show_recently_used", true) ~= false
    local two_columns = show_recent and screen_width >= 30
    local menu_width = math.min(screen_width, two_columns and 34 or 26)
    local menu_height = math.min(17, work_area.height)
    local target_y = math.max(
        work_area.y,
        work_area.y + work_area.height - menu_height
    )
    local divider_y = menu_height - 3
    local item_slots = math.max(0, math.floor((divider_y - 5) / 2))
    local recent_limit = math.max(
        1,
        math.min(10, math.floor(tonumber(
            setting("startmenu.max_recent_items", 4)
        ) or 4))
    )
    local pinned_ids = api.public.getPinned()
    local recent_ids = show_recent and api.public.getRecent(recent_limit) or {}
    local pinned = programsForIds(pinned_ids, two_columns and item_slots or nil)
    local recent = programsForIds(recent_ids, two_columns and item_slots or nil)

    menu_frame = parent_frame:addFrame({
        x=1,
        y=screen_height + 1,
        width=menu_width,
        height=menu_height,
        background=theme("menu_bg"),
        z=900,
    })

    local header = menu_frame:addFrame({
        x=1, y=1, width=menu_width, height=2,
        background=theme("primary"), disabled=true,
    })
    icon.addPath(header, icon.BASALTOS_TASKBAR_PATH, {
        x=2, y=1,
        iconForeground=theme("text"), iconBackground=theme("primary"),
        monochrome=true,
    })
    header:addLabel({
        x=6, y=1, width=menu_width - 7, height=1,
        text="BasaltOS", foreground=theme("text"),
        background=false, disabled=true,
    })
    header:addLabel({
        x=6, y=2, width=menu_width - 7, height=1,
        text="Applications", foreground=theme("text_dim"),
        background=false, disabled=true,
    })
    menu_frame:addFrame({
        x=2, y=3, width=menu_width - 2, height=1,
        background=theme("border"), disabled=true,
    })

    local function addProgramItem(program, x, y, width, section)
        local captured_program = program
        local item = menu_frame:addFrame({
            x=x, y=y, width=width, height=2,
            background=theme("menu_bg"),
        })
        item:setStateStyle("hover", {background=theme("surface")})
        item:setStateStyle("pressed", {background=theme("btn_clicked")})
        local item_icon = icon.add(item, captured_program, {
            x=1, y=1,
            iconForeground=theme("icon_fg"), iconBackground=theme("menu_bg"),
            monochrome=true,
            variant="taskbar",
        })
        local name_label = item:addLabel({
            x=5, y=1, width=math.max(1, width - 5), height=1,
            text=fitText(captured_program.name or captured_program.id, width - 5),
            foreground=theme("menu_fg"), background=false, disabled=true,
        })
        local description_label = item:addLabel({
            x=5, y=2, width=math.max(1, width - 5), height=1,
            text=fitText(
                captured_program.description
                    or captured_program.category or "Application",
                width - 5
            ),
            foreground=theme("menu_muted"), background=false, disabled=true,
        })

        local function setItemHover(hovered)
            item:setState("hover", hovered)
            icon.update(
                item_icon,
                captured_program,
                theme("icon_fg"),
                hovered and theme("surface") or theme("menu_bg"),
                true,
                "taskbar"
            )
        end
        for _, source in ipairs({item, item_icon, name_label, description_label}) do
            bindHover(source, setItemHover)
        end

        item:onClick(function(source, button, mouse_x, mouse_y)
            if button == 1 then
                local _, err = process.startProgram(captured_program.id)
                if err then
                    log.error("STARTMENU", "Failed to start program", {
                        program_id=captured_program.id, error=tostring(err),
                    })
                end
                api.public.hide()
            elseif button == 2 then
                local contextmenu = service.getService("contextmenu")
                if not contextmenu then return end
                local pinned_now = api.public.isPinned(captured_program.id)
                local items = {
                    {
                        label=pinned_now and "Unpin from Start" or "Pin to Start",
                        action=function()
                            if pinned_now then api.public.unpin(captured_program.id)
                            else api.public.pin(captured_program.id) end
                        end,
                    },
                }
                if section == "recent" then
                    items[#items + 1] = {
                        label="Remove from Recent",
                        action=function()
                            api.public.removeRecent(captured_program.id)
                        end,
                    }
                end
                contextmenu.openFor(source, mouse_x, mouse_y, items)
            end
        end)
    end

    local function addSectionLabel(text, x, width)
        menu_frame:addLabel({
            x=x, y=4, width=width, height=1,
            text=fitText(text, width),
            foreground=theme("menu_muted"),
            background=false, disabled=true,
        })
    end

    if two_columns then
        local inner_width = menu_width - 2
        local gap = 1
        local column_width = math.floor((inner_width - gap) / 2)
        local recent_x = 2 + column_width + gap
        addSectionLabel("Pinned", 2, column_width)
        addSectionLabel("Recent", recent_x, column_width)
        for index, program in ipairs(pinned) do
            addProgramItem(
                program, 2, 5 + (index - 1) * 2,
                column_width, "pinned"
            )
        end
        for index, program in ipairs(recent) do
            addProgramItem(
                program, recent_x, 5 + (index - 1) * 2,
                column_width, "recent"
            )
        end
        if #pinned == 0 then
            menu_frame:addLabel({
                x=2, y=5, width=column_width, height=1,
                text="No pinned apps", foreground=theme("menu_muted"),
                background=false, disabled=true,
            })
        end
        if #recent == 0 then
            menu_frame:addLabel({
                x=recent_x, y=5, width=column_width, height=1,
                text="No recent apps", foreground=theme("menu_muted"),
                background=false, disabled=true,
            })
        end
    else
        addSectionLabel(show_recent and "Applications" or "Pinned", 2, menu_width - 2)
        local entries, seen = {}, {}
        local reserve_recent = show_recent and #recent > 0 and item_slots > 1 and 1 or 0
        local pinned_limit = math.max(0, item_slots - reserve_recent)
        for _, program in ipairs(pinned) do
            if #entries >= pinned_limit then break end
            entries[#entries + 1] = {program=program, section="pinned"}
            seen[program.id] = true
        end
        for _, program in ipairs(recent) do
            if #entries >= item_slots then break end
            if not seen[program.id] then
                entries[#entries + 1] = {program=program, section="recent"}
                seen[program.id] = true
            end
        end
        for index, entry in ipairs(entries) do
            addProgramItem(
                entry.program, 2, 5 + (index - 1) * 2,
                menu_width - 2, entry.section
            )
        end
        if #entries == 0 then
            menu_frame:addLabel({
                x=2, y=5, width=menu_width - 2, height=1,
                text="No applications", foreground=theme("menu_muted"),
                background=false, disabled=true,
            })
        end
    end

    menu_frame:addFrame({
        x=2, y=divider_y, width=menu_width - 2, height=1,
        background=theme("border"), disabled=true,
    })

    local logout_button = menu_frame:addButton({
        x=2, y=menu_height - 2, width=menu_width - 2, height=1,
        text="Logout", background=theme("menu_bg"), foreground=theme("menu_fg"),
    })
    logout_button:setStateStyle("hover", {
        background=theme("danger"), foreground=theme("text"),
    })
    logout_button:setStateStyle("pressed", {background=theme("btn_clicked")})
    logout_button:onClick(function()
        api.public.hide(true)
        local auth = service.getService("auth")
        if auth then auth.logout() end
    end)

    local shutdown_button = menu_frame:addButton({
        x=2, y=menu_height - 1, width=menu_width - 2, height=1,
        text="Shutdown", background=theme("menu_bg"), foreground=theme("menu_fg"),
    })
    shutdown_button:setStateStyle("hover", {
        background=theme("danger"), foreground=theme("text"),
    })
    shutdown_button:setStateStyle("pressed", {background=theme("btn_clicked")})
    shutdown_button:onClick(function()
        api.public.hide(true)
        os.shutdown()
    end)

    ui_helpers.addBorder(menu_frame, theme("primary"), {
        innerColor=theme("menu_bg"), topStyle="solid", name="startmenu_border",
    })

    menu_frame:animate({x=1, y=target_y}, 0.2, "easeOut")
    menu_frame:focus()
    log.debug("STARTMENU", "Start menu opened", {
        pinned=#pinned, recent=#recent,
    })
end

function api.public.isOpen()
    return is_open
end

return api
