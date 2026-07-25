-- /system/apps/calendar/main.lua
-- Compact offline monthly calendar for BasaltOS.

local basalt = require("basalt")
local app = require("app")
local calendar = require("calendar_logic")

local userfs = app.userfs
local notification = app.notification

local MONTH_NAMES = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}
local WEEKDAYS = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}

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
    danger=theme("danger", colors.red),
    border=theme("border", colors.gray),
    pressed=theme("btn_clicked", colors.cyan),
}

local now = os.date("*t")
local today = {year=now.year, month=now.month, day=now.day}
local shown_year, shown_month = today.year, today.month
local selected_day = today.day
local notes = {}

local storage_path = userfs and userfs.getPath and userfs.getPath("config/calendar.dat")

local function loadNotes()
    if not storage_path or not fs.exists(storage_path) or fs.isDir(storage_path) then return end
    local handle = fs.open(storage_path, "r")
    if not handle then return end
    local content = handle.readAll()
    handle.close()
    local ok, value = pcall(textutils.unserialize, content)
    if ok and type(value) == "table" then notes = value end
end

local function saveNotes()
    if not storage_path then return false, "No user storage available" end
    local handle, err = fs.open(storage_path, "w")
    if not handle then return false, err or "Could not open calendar data" end
    local ok, write_err = pcall(handle.write, textutils.serialize(notes))
    handle.close()
    if not ok then return false, tostring(write_err) end
    return true
end

loadNotes()

local main = basalt.getMainFrame()
main:setBackground(C.background)

local header = main:addFrame({
    x=1, y=1, width="{parent.width}", height=1,
    background=C.primary,
})

local previous_button = header:addButton({
    x=2, y=1, width=3, height=1, text="<",
    foreground=C.text, background=C.primary,
})
previous_button:setStateStyle("hover", {background=C.pressed, foreground=C.text})

local today_button = header:addButton({
    x=6, y=1, width=7, height=1, text="Today",
    foreground=C.text, background=C.primary,
})
today_button:setStateStyle("hover", {background=C.pressed, foreground=C.text})

local month_label = header:addLabel({
    x=14, y=1, width="{parent.width - 18}", height=1,
    text="", foreground=C.text, background=C.primary, disabled=true,
})

local next_button = header:addButton({
    x="{parent.width - 3}", y=1, width=3, height=1, text=">",
    foreground=C.text, background=C.primary,
})
next_button:setStateStyle("hover", {background=C.pressed, foreground=C.text})

local weekday_bar = main:addFrame({
    x=1, y=2, width="{parent.width}", height=1,
    background=C.surface,
})

local function columnX(column)
    return string.format("{floor(parent.width * %d / 7) + 1}", column - 1)
end

local function columnWidth(column)
    return string.format(
        "{floor(parent.width * %d / 7) - floor(parent.width * %d / 7)}",
        column, column - 1
    )
end

for column, name in ipairs(WEEKDAYS) do
    weekday_bar:addLabel({
        x=columnX(column), y=1, width=columnWidth(column), height=1,
        text=name, foreground=column >= 6 and C.primary or C.foreground,
        background=C.surface, disabled=true,
    })
end

local grid = main:addFrame({
    x=1, y=3, width="{parent.width}", height=6,
    background=C.background,
})

local day_buttons = {}
for slot = 1, 42 do
    local column = (slot - 1) % 7 + 1
    local row = math.floor((slot - 1) / 7) + 1
    local button = grid:addButton({
        x=columnX(column), y=row, width=columnWidth(column), height=1,
        text="", foreground=C.foreground, background=C.background,
    })
    button:setStateStyle("hover", {background=C.surface, foreground=C.foreground})
    button._calendar_day = false
    day_buttons[slot] = button
end

main:addFrame({
    x=1, y=9, width="{parent.width}", height=1,
    background=C.border, disabled=true,
})

local details = main:addFrame({
    x=1, y=10, width="{parent.width}", height="{parent.height - 9}",
    background=C.background,
})

local selected_label = details:addLabel({
    x=2, y=1, width="{parent.width - 3}", height=1,
    text="", foreground=C.foreground, background=C.background, disabled=true,
})

local note_input = details:addInput({
    x=2, y=2, width="{parent.width - 16}", height=1,
    text="", placeholder="Note for this day...", maxLength=120,
    foreground=C.foreground, background=C.surface, placeholderColor=C.muted,
})

local save_button = details:addButton({
    x="{parent.width - 13}", y=2, width=6, height=1,
    text="Save", foreground=C.text, background=C.primary,
})
save_button:setStateStyle("hover", {background=C.pressed, foreground=C.text})

local clear_button = details:addButton({
    x="{parent.width - 6}", y=2, width=5, height=1,
    text="Clear", foreground=C.danger, background=C.surface,
})
clear_button:setStateStyle("hover", {background=C.danger, foreground=C.text})

local status_label = details:addLabel({
    x=2, y=4, width="{parent.width - 3}", height=1,
    text="Notes are stored locally", foreground=C.muted,
    background=C.background, disabled=true,
})

local function setStatus(text, color)
    status_label:setText(tostring(text or ""))
    status_label:setForeground(color or C.muted)
end

local function selectedKey()
    if not selected_day then return nil end
    return calendar.dateKey(shown_year, shown_month, selected_day)
end

local function updateSelectionDetails()
    local key = selectedKey()
    if not key then
        selected_label:setText("Select a day")
        note_input:setText("")
        return
    end
    selected_label:setText(string.format(
        "%s, %s %d, %d",
        WEEKDAYS[calendar.weekday(shown_year, shown_month, selected_day)],
        MONTH_NAMES[shown_month], selected_day, shown_year
    ))
    note_input:setText(tostring(notes[key] or ""))
end

local renderCalendar

local function selectDay(day)
    if not day then return end
    selected_day = day
    renderCalendar()
    note_input:focus()
end

for _, button in ipairs(day_buttons) do
    button:onClickUp(function(self, mouse_button)
        if mouse_button == 1 then selectDay(self._calendar_day) end
    end)
end

renderCalendar = function()
    month_label:setText(MONTH_NAMES[shown_month] .. " " .. shown_year)
    local cells = calendar.monthCells(shown_year, shown_month)
    for slot, button in ipairs(day_buttons) do
        local day = cells[slot]
        button._calendar_day = day
        button:setDisabled(not day)

        if not day then
            button:setText("")
            button:setBackground(C.background)
            button:setForeground(C.muted)
        else
            local key = calendar.dateKey(shown_year, shown_month, day)
            local has_note = type(notes[key]) == "string" and notes[key] ~= ""
            button:setText(tostring(day) .. (has_note and "*" or ""))

            if day == selected_day then
                button:setBackground(C.primary)
                button:setForeground(C.text)
            elseif shown_year == today.year and shown_month == today.month and day == today.day then
                button:setBackground(C.surface)
                button:setForeground(C.primary)
            else
                button:setBackground(C.background)
                button:setForeground(has_note and C.success or C.foreground)
            end
        end
    end
    updateSelectionDetails()
end

local function changeMonth(offset)
    shown_year, shown_month = calendar.normalizeMonth(shown_year, shown_month + offset)
    selected_day = nil
    renderCalendar()
end

local function goToday()
    now = os.date("*t")
    today = {year=now.year, month=now.month, day=now.day}
    shown_year, shown_month, selected_day = today.year, today.month, today.day
    renderCalendar()
end

local function storeSelectedNote(clear)
    local key = selectedKey()
    if not key then
        setStatus("Select a day first", C.danger)
        return
    end

    local value = clear and "" or tostring(note_input:getText() or "")
    value = value:match("^%s*(.-)%s*$")
    if value == "" then notes[key] = nil else notes[key] = value end

    local ok, err = saveNotes()
    if not ok then
        setStatus(err, C.danger)
        if notification and notification.error then
            notification.error("Calendar", err)
        end
        return
    end

    setStatus(value == "" and "Note removed" or "Note saved", C.success)
    renderCalendar()
end

previous_button:onClickUp(function(_, button)
    if button == 1 then changeMonth(-1) end
end)

next_button:onClickUp(function(_, button)
    if button == 1 then changeMonth(1) end
end)

today_button:onClickUp(function(_, button)
    if button == 1 then goToday() end
end)

save_button:onClickUp(function(_, button)
    if button == 1 then storeSelectedNote(false) end
end)

clear_button:onClickUp(function(_, button)
    if button == 1 then storeSelectedNote(true) end
end)

note_input:onEnter(function()
    storeSelectedNote(false)
end)

renderCalendar()
basalt.run()
