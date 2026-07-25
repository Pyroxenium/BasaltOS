-- /system/apps/taskmanager/main.lua
-- System process viewer backed by the BasaltOS process service.

local basalt = require("basalt")
local app = require("app")
local process = assert(app.process, "Process service not available")
local wm = app.wm
local dialog = app.dialog

local function theme(key, fallback)
    return app.theme(key, fallback)
end

local C = {
    background=theme("menu_bg", colors.white),
    foreground=theme("menu_fg", colors.black),
    muted=theme("menu_muted", colors.gray),
    surface=theme("surface", colors.lightGray),
    primary=theme("primary", colors.blue),
    text=theme("text", colors.white),
    success=theme("success", colors.green),
    warning=theme("warning", colors.orange),
    danger=theme("danger", colors.red),
    border=theme("border", colors.gray),
    pressed=theme("btn_clicked", colors.cyan),
}

local function fit(value, width)
    local text = tostring(value or "")
    width = math.max(0, math.floor(tonumber(width) or 0))
    if #text <= width then return text end
    if width <= 2 then return (".."):sub(1, width) end
    return text:sub(1, width - 2) .. ".."
end

local function duration(ms)
    ms = math.max(0, tonumber(ms) or 0)
    if ms < 1000 then return tostring(math.floor(ms)) .. " ms" end
    local seconds = math.floor(ms / 1000)
    if seconds < 60 then return tostring(seconds) .. " s" end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then return string.format("%dm %02ds", minutes, seconds % 60) end
    return string.format("%dh %02dm", math.floor(minutes / 60), minutes % 60)
end

local main = basalt.getMainFrame()
main:setBackground(C.background)

local header = main:addFrame({
    x=1, y=1, width="{parent.width}", height=1,
    background=C.primary,
})
header:addLabel({
    x=2, y=1, width=14, height=1, text="Task Manager",
    foreground=C.text, background=C.primary, disabled=true,
})
local stats_label = header:addLabel({
    x=16, y=1, width="{parent.width - 26}", height=1, text="",
    foreground=C.text, background=C.primary, disabled=true,
})
local refresh_button = header:addButton({
    x="{parent.width - 9}", y=1, width=8, height=1, text="Refresh",
    foreground=C.text, background=C.primary,
})
refresh_button:setStateStyle("hover", {background=C.pressed, foreground=C.text})

local sidebar = main:addFrame({
    x=1, y=2, width=28, height="{parent.height - 2}",
    background=C.surface,
})
local active_tab = sidebar:addButton({
    x=1, y=1, width=14, height=1, text="Active",
    foreground=C.text, background=C.primary,
})
local history_tab = sidebar:addButton({
    x=15, y=1, width=14, height=1, text="Recent",
    foreground=C.foreground, background=C.surface,
})
active_tab:setStateStyle("hover", {background=C.pressed, foreground=C.text})
history_tab:setStateStyle("hover", {background=C.pressed, foreground=C.text})

local process_list = sidebar:addList({
    x=1, y=2, width=28, height="{parent.height - 1}",
    background=C.surface, foreground=C.foreground,
    selectionBackground=C.primary, selectionForeground=C.text,
    scrollbar="auto", scrollbarColor=C.border,
    scrollbarThumbColor=C.primary,
    emptyText="No processes", emptyTextColor=C.muted,
})

local details = main:addFrame({
    x=29, y=2, width="{parent.width - 28}", height="{parent.height - 2}",
    background=C.background,
})
local name_label = details:addLabel({
    x=2, y=1, width="{parent.width - 3}", height=1,
    text="Select a process", foreground=C.foreground,
    background=C.background, disabled=true,
})
local state_label = details:addLabel({
    x=2, y=2, width="{parent.width - 3}", height=1,
    text="", foreground=C.muted, background=C.background, disabled=true,
})
local pid_label = details:addLabel({
    x=2, y=3, width="{parent.width - 3}", height=1,
    text="", foreground=C.foreground, background=C.background, disabled=true,
})
local runtime_label = details:addLabel({
    x=2, y=4, width="{parent.width - 3}", height=1,
    text="", foreground=C.foreground, background=C.background, disabled=true,
})
local cpu_label = details:addLabel({
    x=2, y=5, width="{parent.width - 3}", height=1,
    text="", foreground=C.foreground, background=C.background, disabled=true,
})
local events_label = details:addLabel({
    x=2, y=6, width="{parent.width - 3}", height=1,
    text="", foreground=C.muted, background=C.background, disabled=true,
})
local path_label = details:addLabel({
    x=2, y=7, width="{parent.width - 3}", height=1,
    text="", foreground=C.muted, background=C.background, disabled=true,
})
local error_label = details:addLabel({
    x=2, y=8, width="{parent.width - 3}", height=1,
    text="", foreground=C.danger, background=C.background, disabled=true,
})

local focus_button = details:addButton({
    x=2, y="{parent.height - 3}", width=7, height=1, text="Focus",
    foreground=C.text, background=C.primary,
})
local pause_button = details:addButton({
    x=10, y="{parent.height - 3}", width="{max(8, parent.width - 11)}",
    height=1, text="Pause", foreground=C.foreground, background=C.surface,
})
local end_button = details:addButton({
    x=2, y="{parent.height - 2}", width="{parent.width - 3}",
    height=1, text="End task", foreground=C.text, background=C.danger,
})
focus_button:setStateStyle("hover", {background=C.pressed, foreground=C.text})
pause_button:setStateStyle("hover", {background=C.primary, foreground=C.text})
end_button:setStateStyle("hover", {background=C.warning, foreground=C.text})

local status_label = details:addLabel({
    x=2, y="{parent.height}", width="{parent.width - 3}", height=1,
    text="Ready", foreground=C.muted, background=C.background, disabled=true,
})

local view_mode = "active"
local selected_record
local selected_key
local own_pid = os.getProcessId and os.getProcessId() or nil

local function recordKey(record)
    if not record then return nil end
    return tostring(record.pid) .. ":" .. tostring(record.ended_at or "active")
end

local function setStatus(message, color)
    status_label:setText(fit(message, math.max(1, status_label:getWidth())))
    status_label:setForeground(color or C.muted)
end

local function setActions(record)
    local active = view_mode == "active" and record ~= nil
    local is_self = active and record.pid == own_pid
    focus_button:setDisabled(not active or not record.window_id)
    pause_button:setDisabled(not active or is_self)
    end_button:setDisabled(not active or is_self)
    pause_button:setText(active and record.state == "paused" and "Resume" or "Pause")
end

local function renderDetails(record)
    selected_record = record
    selected_key = recordKey(record)
    if not record then
        name_label:setText("Select a process")
        state_label:setText("")
        pid_label:setText("")
        runtime_label:setText("")
        cpu_label:setText("")
        events_label:setText("")
        path_label:setText("")
        error_label:setText("")
        setActions(nil)
        return
    end

    name_label:setText(fit(record.program_name or record.program_id,
        math.max(1, name_label:getWidth())))
    local state_text
    if view_mode == "history" then
        state_text = (record.exit_reason or "exited") .. " - " .. record.type
    else
        state_text = record.state .. " - " .. record.type
    end
    state_label:setText(fit(state_text, math.max(1, state_label:getWidth())))
    state_label:setForeground(record.exit_reason == "crashed" and C.danger
        or record.state == "paused" and C.warning or C.muted)
    pid_label:setText("PID " .. tostring(record.pid)
        .. (record.window_id and (" / Window " .. tostring(record.window_id)) or ""))
    runtime_label:setText("Runtime: " .. duration(record.runtime_ms))
    cpu_label:setText("Lua time: " .. duration(record.cpu_time_ms))
    events_label:setText(fit(string.format(
        "%d resumes / %d events%s",
        record.resume_count or 0, record.event_count or 0,
        record.last_event and (" / " .. record.last_event) or ""
    ), math.max(1, events_label:getWidth())))
    path_label:setText(fit(record.executable, math.max(1, path_label:getWidth())))
    error_label:setText(fit(record.exit_error or "", math.max(1, error_label:getWidth())))
    setActions(record)
end

local function updateTabs()
    local active = view_mode == "active"
    active_tab:setBackground(active and C.primary or C.surface)
    active_tab:setForeground(active and C.text or C.foreground)
    history_tab:setBackground(active and C.surface or C.primary)
    history_tab:setForeground(active and C.foreground or C.text)
    process_list:setEmptyText(active and "No processes" or "No recent tasks")
end

local function refresh(preferred_key)
    preferred_key = preferred_key or selected_key
    local records = view_mode == "active"
        and process.listProcesses() or process.getHistory(30)
    local stats = process.getStats()
    stats_label:setText(string.format(
        "%d run  %d pause  %d crash",
        stats.total or 0, stats.paused or 0, stats.total_crashed or 0
    ))

    process_list:clear()
    local selected_index
    for index, record in ipairs(records) do
        local marker
        if view_mode == "history" then
            marker = record.exit_reason == "crashed" and "!"
                or record.exit_reason == "completed" and "+" or "-"
        else
            marker = record.state == "paused" and "P"
                or record.type == "background" and "B" or "W"
        end
        process_list:addItem({
            text=string.format("%3d [%s] %s", record.pid, marker,
                record.program_name or record.program_id),
            processRecord=record,
            processKey=recordKey(record),
            fg=record.exit_reason == "crashed" and C.danger or C.foreground,
            bg=C.surface,
        })
        if recordKey(record) == preferred_key then selected_index = index end
    end

    if not selected_index and #records > 0 then selected_index = 1 end
    if selected_index then
        process_list:selectItem(selected_index, false)
        renderDetails(records[selected_index])
    else
        renderDetails(nil)
    end
end

process_list:onSelect(function(_, _, item)
    renderDetails(item and item.processRecord or nil)
end)

active_tab:onClickUp(function(_, button)
    if button ~= 1 or view_mode == "active" then return end
    view_mode = "active"
    selected_key = nil
    updateTabs()
    refresh()
end)

history_tab:onClickUp(function(_, button)
    if button ~= 1 or view_mode == "history" then return end
    view_mode = "history"
    selected_key = nil
    updateTabs()
    refresh()
end)

refresh_button:onClickUp(function(_, button)
    if button ~= 1 then return end
    refresh()
    setStatus("Refreshed", C.success)
end)

focus_button:onClickUp(function(_, button)
    if button ~= 1 or not selected_record or not selected_record.window_id then return end
    local ok, err = wm and wm.focusWindow(selected_record.window_id)
    setStatus(ok and "Window focused" or (err or "Cannot focus window"),
        ok and C.success or C.danger)
end)

pause_button:onClickUp(function(_, button)
    if button ~= 1 or not selected_record or selected_record.pid == own_pid then return end
    local was_paused = selected_record.state == "paused"
    local ok, err
    if was_paused then
        ok, err = process.resumeProcess(selected_record.pid)
    else
        ok, err = process.pauseProcess(selected_record.pid)
    end
    refresh()
    setStatus(ok and (was_paused and "Process resumed" or "Process paused")
        or err, ok and C.success or C.danger)
end)

end_button:onClickUp(function(_, button)
    if button ~= 1 or not selected_record or selected_record.pid == own_pid then return end
    local pid = selected_record.pid
    local name = selected_record.program_name or selected_record.program_id
    local function terminate(confirmed)
        if not confirmed then return end
        local ok, err = process.terminateProcess(pid)
        refresh()
        setStatus(ok and "Task ended" or err, ok and C.success or C.danger)
    end
    if dialog and dialog.confirm then
        dialog.confirm("End task", "End " .. tostring(name) .. " (PID "
            .. tostring(pid) .. ")?", terminate)
    else
        terminate(true)
    end
end)

-- Lifecycle events update immediately; the timer keeps runtime values live.
basalt.schedule(function()
    local timer_id = os.startTimer(1)
    while true do
        local event_name, value = os.pullEventRaw()
        local lifecycle = event_name == "process.started"
            or event_name == "process.exited"
            or event_name == "process.paused"
            or event_name == "process.resumed"
        if lifecycle or (event_name == "timer" and value == timer_id) then
            refresh()
        end
        if event_name == "timer" and value == timer_id then
            timer_id = os.startTimer(1)
        end
    end
end)

updateTabs()
refresh()
basalt.run()
