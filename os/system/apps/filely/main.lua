-- Filely - responsive file manager for BasaltOS / Basalt 2.5

local launch_args = {...}
local basalt = require("basalt")
local app = require("app")
local event = require("core.event")
local ui_helpers = require("core.ui_helpers")

local filesystem = assert(app.filesystem, "FileSystem service not available")
local userfs = app.userfs
local dialog = app.dialog
local contextmenu = app.contextmenu
local clipboard = app.clipboard
local fileops = app.fileops
local dragdrop = app.dragdrop

-- Use BasaltOS' palette, matching the Settings app. Basalt supplies only the
-- widgets here; all colors come from the OS-level app.theme API.
local function theme(key, fallback)
    return app.theme(key, fallback)
end

local palette = {}
local function readOsPalette()
    palette.background = theme("desktop_bg", colors.white)
    palette.foreground = theme("desktop_fg", colors.black)
    palette.muted = theme("desktop_muted", colors.gray)
    palette.surface = theme("surface", colors.lightGray)
    palette.accent = theme("primary", colors.blue)
    palette.accentText = theme("text", colors.white)
    palette.pressed = theme("btn_clicked", theme("secondary", colors.gray))
    palette.danger = theme("danger", colors.red)
    palette.success = theme("success", colors.lime)
    palette.warning = theme("warning", colors.orange)
end

local main_frame = basalt.getMainFrame()
local current_path = "/"
local directory_entries = {}
local visible_entries = {}
local back_history = {}
local forward_history = {}
local filter_query = ""
local sort_key = "name"
local sort_ascending = true
local local_mutation = false
local refresh_pending = false
local pending_refresh_path = nil
local event_listeners = {}
local drop_target = nil
local drag_candidate = nil
local ctrl_down = false
local shift_down = false

local toast
local renderList
local rebuildBreadcrumb
local applyTheme
local loadDirectory

local DEFAULT_ICON_CHAR = 131

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function canonicalPath(value)
    value = tostring(value or ""):gsub("\\", "/")
    value = value:gsub("^/+", "")
    local ok, combined = pcall(fs.combine, value, "")
    if not ok then return nil, tostring(combined) end
    return combined == "" and "/" or combined
end

local function displayPath(path)
    return path == "/" and "/" or "/" .. path
end

local function parentPath(path)
    if path == "/" then return "/" end
    return canonicalPath(fs.getDir(path)) or "/"
end

local function resolveAddress(value)
    value = trim(value)
    if value == "" then return current_path end
    if value:sub(1, 1) == "/" then return canonicalPath(value) end
    local base = current_path == "/" and "" or current_path
    return canonicalPath(fs.combine(base, value))
end

local function pathInside(path, parent)
    path = canonicalPath(path)
    parent = canonicalPath(parent)
    if not path or not parent then return false end
    if parent == "/" then return true end
    return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function fileIcon(entry)
    if entry.isDir then return string.char(DEFAULT_ICON_CHAR), nil, colors.yellow end

    local declared = entry.file_icon
    if type(declared) == "table" then
        local char = declared.char
        if type(char) == "number" and char >= 0 and char <= 255 then
            char = string.char(math.floor(char))
        elseif type(char) == "string" and #char > 0 then
            char = char:sub(1, 1)
        else
            char = nil
        end

        local function resolveColor(color)
            if type(color) == "string" then color = colors[color] end
            if type(color) == "number" and colors.toBlit then
                local valid = pcall(colors.toBlit, color)
                if not valid then return nil end
            end
            return type(color) == "number" and color or nil
        end

        local foreground = resolveColor(declared.fg or declared.foreground)
        local background = resolveColor(declared.bg or declared.background or declared.color)
        if char then return char, foreground, background end
    end

    return string.char(DEFAULT_ICON_CHAR), nil, colors.lightGray
end

local function formatSize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
    if bytes >= 1024 then return string.format("%.1f KB", bytes / 1024) end
    return tostring(bytes) .. " B"
end

local function formatDate(epoch)
    epoch = tonumber(epoch)
    if not epoch or epoch <= 0 or not os.date then return "-" end
    local seconds = epoch > 100000000000 and math.floor(epoch / 1000) or math.floor(epoch)
    local ok, result = pcall(os.date, "%Y-%m-%d", seconds)
    return ok and tostring(result) or "-"
end

local function fitText(value, width)
    value = tostring(value or "")
    if width <= 0 then return "" end
    if #value <= width then return value .. (" "):rep(width - #value) end
    if width == 1 then return value:sub(1, 1) end
    return value:sub(1, width - 1) .. "~"
end

local function padLeft(value, width)
    value = tostring(value or "")
    if #value > width then value = value:sub(1, width) end
    return (" "):rep(math.max(0, width - #value)) .. value
end

local function validName(name)
    if type(name) ~= "string" then return false end
    name = trim(name)
    if name == "" or name == "." or name == ".." then return false end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return false end
    if name:find("[%c]") then return false end
    return true, name
end

-- Toolbar -----------------------------------------------------------------

local toolbar = main_frame:addFrame({
    x=1, y=1, width="{parent.width}", height=1,
})

local function toolbarButton(properties)
    local button = toolbar:addButton(properties)
    return button
end

local btn_back = toolbarButton({x=1, y=1, width=1, height=1, text=string.char(27)})
local btn_forward = toolbarButton({x=3, y=1, width=1, height=1, text=string.char(26)})
local btn_home = toolbarButton({x=5, y=1, width=1, height=1, text=string.char(8)})
local btn_up = toolbarButton({x=7, y=1, width=1, height=1, text=string.char(30)})

local breadcrumb_frame = toolbar:addFrame({
    x=9, y=1, width="{parent.width - 25}", height=1,
})
local breadcrumb_buttons = {}

local path_input = toolbar:addInput({
    x=9, y=1, width="{parent.width - 25}", height=1,
    text="/", placeholder="Path", visible=false,
})

local filter_input = toolbar:addInput({
    x="{parent.width - 15}", y=1, width=11, height=1,
    text="", placeholder="Search...",
})

local btn_add = toolbarButton({
    x="{parent.width - 3}", y=1, width=4, height=1, text=" + ",
})

-- Content -----------------------------------------------------------------

local header = main_frame:addFrame({
    x=1, y=2, width="{parent.width}", height=1,
})
local header_label = header:addLabel({
    x=1, y=1, width="{parent.width}", height=1, text="",
    disabled=true,
})

local file_list_view = main_frame:addList({
    x=1, y=3, width="{parent.width}", height="{parent.height - 3}",
    emptyText="This folder is empty", scrollbar="auto",
})

local empty_action = main_frame:addButton({
    x="{parent.width / 2 - 6}", y="{parent.height / 2 + 1}",
    width=13, height=1, text="+ New folder", visible=false, z=20,
})

local status_bar = main_frame:addLabel({
    x=1, y="{parent.height}", width="{parent.width}", height=1,
    text="", disabled=true,
})

toast = main_frame:addToast({y=3, maxWidth=28, duration=2.5})

local function setStatus(text)
    local width = main_frame:getSize()
    local message = tostring(text or "")
    local hint = width >= 50 and "  |  F1 Help" or ""
    local available = math.max(0, width - 1 - #hint)
    if #message > available then
        message = available > 1 and message:sub(1, available - 1) .. "~" or ""
    end
    status_bar:setText(" " .. message .. hint)
end

local function notify(message, kind)
    if not toast then return end
    toast:show(message, kind or "info", 2.5)
end

local function showError(title, message)
    message = tostring(message or "Unknown error")
    if dialog then dialog.alert(title, message) else notify(message, "error") end
end

local function showHelp()
    if not dialog then return end
    dialog.alert("Filely Shortcuts", table.concat({
        "Enter          Open",
        "Backspace      Parent folder",
        "F2             Rename",
        "Delete         Delete",
        "F5             Refresh",
        "Ctrl+L         Edit path",
        "Ctrl+F         Search",
        "Ctrl+N         New file",
        "Ctrl+Shift+N   New folder",
        "Ctrl+C         Copy",
        "Ctrl+X         Cut",
        "Ctrl+V         Paste",
        "Drag           Move item",
        "Ctrl+Drag      Copy item",
    }, "\n"))
end

local function selectedEntry()
    local index = file_list_view:getSelectedIndex()
    return index and visible_entries[index] or nil
end

local function isReadOnly()
    return fs.isReadOnly and fs.isReadOnly(current_path) or false
end

local function updateNavigationState()
    btn_back:setDisabled(#back_history == 0)
    btn_forward:setDisabled(#forward_history == 0)
    btn_up:setDisabled(current_path == "/")
    btn_add:setDisabled(isReadOnly())
end

local function updateDirectoryStatus()
    local dirs, files = 0, 0
    for _, entry in ipairs(directory_entries) do
        if entry.isDir then dirs = dirs + 1 else files = files + 1 end
    end
    if filter_query ~= "" then
        setStatus(string.format("%d shown  |  %d folders, %d files", #visible_entries, dirs, files))
    else
        setStatus(string.format("%d folders, %d files", dirs, files))
    end
end

local function updateSelectionStatus()
    local entry = selectedEntry()
    if not entry then
        updateDirectoryStatus()
    elseif entry.isDir then
        setStatus(entry.name .. "  |  folder")
    else
        local date = formatDate(entry.modified)
        setStatus(string.format("%s  |  %s  |  %s", entry.name, formatSize(entry.size), date))
    end
end

local function columnLayout()
    local list_width = file_list_view:getSize()
    local width = math.max(1, list_width) - 1
    local show_size = width >= 42
    local show_date = width >= 56
    local size_width = show_size and 9 or 0
    local date_width = show_date and 12 or 0
    local name_width = math.max(6, width - 3 - size_width - date_width)
    return {
        width=width, showSize=show_size, showDate=show_date,
        nameWidth=name_width, sizeWidth=size_width, dateWidth=date_width,
        sizeX=4 + name_width,
        dateX=4 + name_width + size_width,
    }
end

local function sortValue(entry, key)
    if key == "size" then return tonumber(entry.size) or 0 end
    if key == "modified" then return tonumber(entry.modified) or 0 end
    return tostring(entry.name or ""):lower()
end

local function compareEntries(left, right)
    if left.isDir ~= right.isDir then return left.isDir end
    local a, b = sortValue(left, sort_key), sortValue(right, sort_key)
    if a == b then
        a, b = left.name:lower(), right.name:lower()
    end
    if a == b then a, b = left.name, right.name end
    if sort_ascending then return a < b end
    return a > b
end

local function headerText(layout)
    local arrow = sort_ascending and "\31" or "\30"
    local name = "NAME" .. (sort_key == "name" and " " .. arrow or "")
    local text = "   " .. fitText(name, layout.nameWidth)
    if layout.showSize then
        local size = "SIZE" .. (sort_key == "size" and arrow or "")
        text = text .. padLeft(size, layout.sizeWidth)
    end
    if layout.showDate then
        local date = "MODIFIED" .. (sort_key == "modified" and " " .. arrow or "")
        text = text .. padLeft(date, layout.dateWidth)
    end
    return text
end

local function entryText(entry, layout, icon_char)
    local text = " " .. icon_char .. " " .. fitText(entry.name, layout.nameWidth)
    if layout.showSize then
        text = text .. padLeft(entry.isDir and "-" or formatSize(entry.size), layout.sizeWidth)
    end
    if layout.showDate then
        text = text .. padLeft(formatDate(entry.modified), layout.dateWidth)
    end
    return text
end

renderList = function(options)
    options = options or {}
    local selected_path = options.select_path
    if not selected_path and options.keep_selection then
        local selected = selectedEntry()
        selected_path = selected and selected.path or nil
    end

    visible_entries = {}
    local query = filter_query:lower()
    for _, entry in ipairs(directory_entries) do
        if query == "" or entry.name:lower():find(query, 1, true) then
            visible_entries[#visible_entries + 1] = entry
        end
    end
    table.sort(visible_entries, compareEntries)

    local layout = columnLayout()
    header_label:setText(headerText(layout))
    file_list_view:clear()
    local selected_index = nil
    for index, entry in ipairs(visible_entries) do
        local icon_char, icon_foreground, icon_background = fileIcon(entry)
        file_list_view:addItem({
            text=entryText(entry, layout, icon_char),
            fg=entry.isDir and palette.accent or palette.foreground,
            bg=palette.background,
            selectedFg=palette.accentText, selectedBg=palette.accent,
            iconChar=icon_char, iconX=2,
            iconForeground=icon_foreground or palette.background,
            iconBackground=icon_background or palette.background,
            selectedIconForeground=icon_foreground or palette.accent,
            selectedIconBackground=icon_background or palette.accent,
        })
        if selected_path and entry.path == selected_path then selected_index = index end
    end
    if selected_index then file_list_view:selectItem(selected_index, false) end

    file_list_view:setEmptyText(query == "" and "This folder is empty" or "No matching files")
    empty_action:setVisible(#directory_entries == 0 and query == "" and not isReadOnly())
    updateNavigationState()
    if selected_index then updateSelectionStatus() else updateDirectoryStatus() end
end

local function breadcrumbParts()
    local parts = {}
    local user_dir = userfs and userfs.getUserDir() or nil
    user_dir = user_dir and canonicalPath(user_dir) or nil
    local relative = current_path

    if user_dir and pathInside(current_path, user_dir) then
        parts[#parts + 1] = {label="Home", path=user_dir}
        if current_path == user_dir then return parts end
        relative = current_path:sub(#user_dir + 2)
        local built = user_dir
        for name in relative:gmatch("[^/]+") do
            built = fs.combine(built, name)
            parts[#parts + 1] = {label=name, path=canonicalPath(built)}
        end
    else
        parts[#parts + 1] = {label="Root", path="/"}
        if current_path == "/" then return parts end
        local built = ""
        for name in current_path:gmatch("[^/]+") do
            built = fs.combine(built, name)
            parts[#parts + 1] = {label=name, path=canonicalPath(built)}
        end
    end
    return parts
end

rebuildBreadcrumb = function()
    for i = #breadcrumb_buttons, 1, -1 do breadcrumb_buttons[i]:destroy() end
    breadcrumb_buttons = {}

    local available = math.max(1, breadcrumb_frame:getSize())
    local parts = breadcrumbParts()
    local first = #parts
    local used = 0
    while first >= 1 do
        local prefix = first == 1 and "" or "> "
        local needed = #prefix + #parts[first].label + 1
        if used + needed > available then break end
        used = used + needed
        first = first - 1
    end
    first = math.max(1, first + 1)

    local x = 1
    if first > 1 and available >= 3 then
        local target = parts[first - 1].path
        local button = breadcrumb_frame:addButton({
            x=x, y=1, width=3, height=1, text="..",
            background=palette.surface, foreground=palette.muted,
        })
        button:setStateStyle("hover", {background=palette.accent, foreground=palette.accentText})
        button:setStateStyle("pressed", {background=palette.pressed, foreground=palette.accentText})
        button:onClick(function() loadDirectory(target, {record=true}) end)
        breadcrumb_buttons[#breadcrumb_buttons + 1] = button
        x = x + 3
    end

    for index = first, #parts do
        local label = (x == 1 and "" or "> ") .. parts[index].label
        local width = math.min(#label + 1, available - x + 1)
        if width <= 0 then break end
        local target = parts[index].path
        local active = index == #parts
        local button = breadcrumb_frame:addButton({
            x=x, y=1, width=width, height=1, text=label,
            background=palette.surface,
            foreground=active and palette.accent or palette.muted,
        })
        button:setStateStyle("hover", {background=palette.accent, foreground=palette.accentText})
        button:setStateStyle("pressed", {background=palette.pressed, foreground=palette.accentText})
        button:onClick(function() loadDirectory(target, {record=true}) end)
        breadcrumb_buttons[#breadcrumb_buttons + 1] = button
        x = x + width
    end
end

loadDirectory = function(path, options)
    options = options or {}
    local normalized, path_error = canonicalPath(path)
    if not normalized then
        showError("Cannot Open", path_error)
        return false
    end

    local entries, err = filesystem.listDir(normalized)
    if not entries then
        showError("Cannot Open", err or ("Directory not found: " .. displayPath(normalized)))
        path_input:setText(displayPath(current_path))
        return false
    end

    local previous_path = current_path
    if options.record and previous_path ~= normalized then
        back_history[#back_history + 1] = previous_path
        if #back_history > 100 then table.remove(back_history, 1) end
        forward_history = {}
    end

    current_path = normalized
    directory_entries = entries
    path_input:setText(displayPath(current_path))
    rebuildBreadcrumb()
    renderList(options)
    return true
end

local function navigate(path)
    return loadDirectory(path, {record=true})
end

local function navigateAddress(value)
    local target, err = resolveAddress(value)
    if not target then showError("Invalid Path", err) return false end
    return navigate(target)
end

local function refresh(options)
    options = options or {keep_selection=true}
    return loadDirectory(current_path, options)
end

local function showPathEditor()
    breadcrumb_frame:setVisible(false)
    path_input:setVisible(true)
    path_input:setText(displayPath(current_path))
    path_input:focus()
end

local function hidePathEditor()
    path_input:setVisible(false)
    breadcrumb_frame:setVisible(true)
    path_input:setText(displayPath(current_path))
    file_list_view:focus()
end

local function mutate(action)
    local_mutation = true
    local ok, result, extra = pcall(action)
    local_mutation = false
    if not ok then return false, tostring(result) end
    return result, extra
end

local function openEntry(entry)
    if not entry then return end
    if entry.isDir then
        navigate(entry.path)
        return
    end
    local ok, err = filesystem.executeFileAction(entry.path, "open")
    if not ok then showError("Cannot Open", err or "No app associated with this file type") end
end

local function executeEntryAction(entry, action)
    if not entry or entry.isDir then return end
    local ok, err = filesystem.executeFileAction(entry.path, action.id)
    if not ok then showError("Cannot " .. tostring(action.label or action.id), err) end
end

local function createFolder()
    if not dialog or isReadOnly() then return end
    dialog.prompt("New Folder", "Folder name:", "", function(name)
        local valid, clean_name = validName(name)
        if not valid then
            if name ~= nil then showError("Invalid Name", "Enter a single folder name") end
            return
        end
        local target = fs.combine(current_path, clean_name)
        local ok, err = mutate(function() return filesystem.makeDir(target) end)
        if not ok then showError("Cannot Create Folder", err) else
            refresh({select_path=target})
            notify("Folder created", "success")
        end
    end)
end

local function createFile()
    if not dialog or isReadOnly() then return end
    dialog.prompt("New File", "File name:", "", function(name)
        local valid, clean_name = validName(name)
        if not valid then
            if name ~= nil then showError("Invalid Name", "Enter a single file name") end
            return
        end
        local target = fs.combine(current_path, clean_name)
        local ok, err = mutate(function() return filesystem.createFile(target, "") end)
        if not ok then showError("Cannot Create File", err) else
            refresh({select_path=target})
            notify("File created", "success")
        end
    end)
end

local function renameEntry(entry)
    if not dialog or not entry or isReadOnly() then return end
    dialog.prompt("Rename", "New name:", entry.name, function(name)
        local valid, clean_name = validName(name)
        if not valid then
            if name ~= nil then showError("Invalid Name", "Enter a single name") end
            return
        end
        if clean_name == entry.name then return end
        local target = fs.combine(current_path, clean_name)
        local ok, err = mutate(function() return filesystem.move(entry.path, target) end)
        if not ok then showError("Cannot Rename", err) else
            refresh({select_path=target})
            notify("Renamed", "success")
        end
    end)
end

local function deleteEntry(entry)
    if not dialog or not entry or isReadOnly() then return end
    dialog.confirm("Delete", "Delete '" .. entry.name .. "'?", function(confirmed)
        if not confirmed then return end
        local ok, err = mutate(function() return filesystem.delete(entry.path) end)
        if not ok then showError("Cannot Delete", err) else
            refresh({keep_selection=true})
            notify("Deleted", "info")
        end
    end)
end

local function copyEntry(entry)
    if not fileops or not entry then return false end
    local ok, err = fileops.copy(entry.path)
    if not ok then
        showError("Cannot Copy", err)
        return false
    end
    notify("'" .. entry.name .. "' ready to copy", "info")
    return true
end

local function cutEntry(entry)
    if not fileops or not entry or isReadOnly() then return false end
    local ok, err = fileops.cut(entry.path)
    if not ok then
        showError("Cannot Cut", err)
        return false
    end
    notify("'" .. entry.name .. "' ready to move", "info")
    return true
end

local function pasteInto(path)
    if not fileops then return false end
    if not fileops.canPaste(path) then
        showError("Cannot Paste", "There are no files that can be pasted here")
        return false
    end

    local ok, result = mutate(function() return fileops.paste(path) end)
    if not ok then
        showError("Cannot Paste", result)
        return false
    end

    if path == current_path then
        refresh({select_path=result.destinations and result.destinations[1] or nil})
    else
        refresh({keep_selection=true})
    end
    notify(result.operation == "cut" and "Moved" or "Copied", "success")
    return true
end

local function showProperties(entry)
    if not dialog or not entry then return end
    local kind = entry.isDir and "Folder" or "File"
    local size = entry.isDir and "-" or formatSize(entry.size)
    local associated = entry.app_id and ("\nOpens with: " .. entry.app_id) or ""
    if entry.editor_id and entry.editor_id ~= entry.app_id then
        associated = associated .. "\nEdits with: " .. entry.editor_id
    end
    dialog.alert("Properties", string.format(
        "Name: %s\nType: %s\nSize: %s\nModified: %s\nPath: %s%s",
        entry.name, kind, size, formatDate(entry.modified), displayPath(entry.path), associated
    ))
end

local function creationItems()
    local items = {
        {label="New File", action=createFile},
        {label="New Folder", action=createFolder},
    }
    if fileops then
        items[#items + 1] = {separator=true}
        items[#items + 1] = {
            label="Paste",
            disabled=isReadOnly() or not fileops.canPaste(current_path),
            action=function() pasteInto(current_path) end,
        }
    end
    return items
end

local function contextItems(entry)
    if not entry then
        local items = creationItems()
        items[#items + 1] = {separator=true}
        items[#items + 1] = {label="Refresh", action=function() refresh() end}
        return items
    end

    local items = {}
    if entry.isDir then
        items[#items + 1] = {label="Open", action=function() openEntry(entry) end}
    else
        for _, action in ipairs(filesystem.getFileActions(entry.path)) do
            local captured = action
            items[#items + 1] = {
                label=captured.label,
                action=function() executeEntryAction(entry, captured) end,
            }
        end
    end
    items[#items + 1] = {separator=true}
    items[#items + 1] = {
        label="Copy",
        disabled=not fileops,
        action=function() copyEntry(entry) end,
    }
    items[#items + 1] = {
        label="Cut",
        disabled=not fileops or isReadOnly(),
        action=function() cutEntry(entry) end,
    }
    if entry.isDir then
        items[#items + 1] = {
            label="Paste into Folder",
            disabled=not fileops or not fileops.canPaste(entry.path),
            action=function() pasteInto(entry.path) end,
        }
    end
    items[#items + 1] = {separator=true}
    items[#items + 1] = {label="Rename", disabled=isReadOnly(), action=function() renameEntry(entry) end}
    items[#items + 1] = {label="Delete", disabled=isReadOnly(), action=function() deleteEntry(entry) end}
    items[#items + 1] = {separator=true}
    items[#items + 1] = {label="Copy Path", action=function()
        if clipboard then
            clipboard.set(displayPath(entry.path))
            notify("Path copied", "info")
        end
    end}
    items[#items + 1] = {label="Properties", action=function() showProperties(entry) end}
    return items
end

local function openCreationMenu()
    if not contextmenu or isReadOnly() then return end
    contextmenu.openFor(btn_add, 1, 1, creationItems())
end

-- Navigation and pointer events ------------------------------------------

btn_back:onClick(function()
    local target = table.remove(back_history)
    if not target then return end
    local old = current_path
    if loadDirectory(target) then forward_history[#forward_history + 1] = old
    else back_history[#back_history + 1] = target end
    updateNavigationState()
end)

btn_forward:onClick(function()
    local target = table.remove(forward_history)
    if not target then return end
    local old = current_path
    if loadDirectory(target) then back_history[#back_history + 1] = old
    else forward_history[#forward_history + 1] = target end
    updateNavigationState()
end)

btn_home:onClick(function()
    navigate(userfs and userfs.getUserDir() or "/")
end)

btn_up:onClick(function()
    if current_path ~= "/" then navigate(parentPath(current_path)) end
end)

btn_add:onClick(openCreationMenu)
empty_action:onClick(createFolder)

path_input:onEnter(function(_, value)
    if navigateAddress(value) then hidePathEditor() end
end)

filter_input:onChange(function(_, value)
    filter_query = tostring(value or "")
    renderList({keep_selection=true})
end)

header:onClick(function(_, _, x)
    local layout = columnLayout()
    local target = "name"
    if layout.showDate and x >= layout.dateX then target = "modified"
    elseif layout.showSize and x >= layout.sizeX then target = "size" end
    if sort_key == target then sort_ascending = not sort_ascending
    else sort_key, sort_ascending = target, true end
    renderList({keep_selection=true})
end)

file_list_view:onChange(updateSelectionStatus)

ui_helpers.onDoubleClick(file_list_view, function(_, button)
    if button == 1 then openEntry(selectedEntry()) end
end, 0.40)

file_list_view:onClick(function(_, button, x, y)
    drag_candidate = nil
    if button ~= 1 or not dragdrop then return end
    local width = file_list_view:getSize()
    if x >= width then return end
    drag_candidate = visible_entries[file_list_view:getOffset() + y]
end)

file_list_view:onDrag(function(_, button)
    if button ~= 1 or not drag_candidate or not dragdrop
        or dragdrop.isDragging() then return end
    dragdrop.beginFiles(drag_candidate.path, {
        label=drag_candidate.name,
        source_id="filely",
    })
end)

file_list_view:onClickUp(function(_, button, x, y)
    drag_candidate = nil
    if button ~= 2 or not contextmenu then return end
    local width = file_list_view:getSize()
    if x >= width then return end
    local entry = visible_entries[file_list_view:getOffset() + y]
    contextmenu.openFor(file_list_view, x, y, contextItems(entry))
end)

-- Keyboard shortcuts ------------------------------------------------------

local function isCtrl(key)
    return key == keys.leftCtrl or key == keys.rightCtrl
end

local function isShift(key)
    return key == keys.leftShift or key == keys.rightShift
end

local function trackModifier(_, key)
    if isCtrl(key) then ctrl_down = true end
    if isShift(key) then shift_down = true end
end

local function releaseModifier(_, key)
    if isCtrl(key) then ctrl_down = false end
    if isShift(key) then shift_down = false end
end

local function commonShortcut(key)
    if key == keys.f1 then showHelp() return true end
    if ctrl_down and key == keys.l then showPathEditor() return true end
    if ctrl_down and key == keys.f then filter_input:focus() return true end
    if ctrl_down and key == keys.c and selectedEntry() then
        return copyEntry(selectedEntry())
    end
    if ctrl_down and key == keys.x and selectedEntry() then
        return cutEntry(selectedEntry())
    end
    if ctrl_down and key == keys.v and fileops and fileops.canPaste(current_path) then
        return pasteInto(current_path)
    end
    if ctrl_down and key == keys.n then
        local create_folder = shift_down
        ctrl_down, shift_down = false, false
        if create_folder then createFolder() else createFile() end
        return true
    end
    return false
end

local function handleGeneralKey(_, key)
    trackModifier(nil, key)
    if commonShortcut(key) then return end
    if key == keys.backspace and current_path ~= "/" then
        navigate(parentPath(current_path))
    elseif key == keys.f5 then
        refresh()
        notify("View updated", "info")
    end
end

local function handleListKey(_, key)
    trackModifier(nil, key)
    if commonShortcut(key) then return end
    if key == keys.enter then
        openEntry(selectedEntry())
    elseif key == keys.backspace then
        if current_path ~= "/" then navigate(parentPath(current_path)) end
    elseif key == keys.f2 then
        renameEntry(selectedEntry())
    elseif key == keys.delete then
        deleteEntry(selectedEntry())
    elseif key == keys.f5 then
        refresh()
        notify("View updated", "info")
    end
end

local function handlePathKey(_, key)
    trackModifier(nil, key)
    if commonShortcut(key) then return end
    if key == keys.escape then hidePathEditor() end
end

local function handleFilterKey(_, key)
    trackModifier(nil, key)
    if commonShortcut(key) then return end
    if key == keys.escape then
        filter_input:setText("")
        filter_query = ""
        renderList({keep_selection=true})
        file_list_view:focus()
    elseif key == keys.enter then
        file_list_view:focus()
    end
end

local shortcut_elements = {
    btn_back, btn_forward, btn_home, btn_up, btn_add, empty_action, header,
}
for _, element in ipairs(shortcut_elements) do
    element:onKey(handleGeneralKey)
    element:on("keyUp", releaseModifier)
end
file_list_view:onKey(handleListKey):on("keyUp", releaseModifier)
path_input:onKey(handlePathKey):on("keyUp", releaseModifier)
filter_input:onKey(handleFilterKey):on("keyUp", releaseModifier)

-- Live filesystem and theme updates --------------------------------------

local function listen(name, callback)
    event.on(name, callback)
    event_listeners[#event_listeners + 1] = {name=name, callback=callback}
end

local function removeEventListeners()
    if drop_target then drop_target:destroy(); drop_target = nil end
    for _, listener in ipairs(event_listeners) do
        event.off(listener.name, listener.callback)
    end
    event_listeners = {}
end

local function queueRefresh(target)
    if local_mutation then return end
    if target then pending_refresh_path = target end
    if refresh_pending then return end
    refresh_pending = true
    basalt.schedule(function()
        sleep(0.05)
        refresh_pending = false
        local target_path = pending_refresh_path or current_path
        pending_refresh_path = nil
        target_path = canonicalPath(target_path) or "/"
        while target_path ~= "/" and (not fs.exists(target_path) or not fs.isDir(target_path)) do
            target_path = parentPath(target_path)
        end
        loadDirectory(target_path, {keep_selection=true})
    end)
end

listen("filesystem.file_created", function() queueRefresh() end)
listen("filesystem.directory_created", function() queueRefresh() end)
listen("filesystem.file_deleted", function() queueRefresh() end)
listen("filesystem.file_copied", function() queueRefresh() end)
listen("filesystem.file_moved", function(source, destination)
    source, destination = canonicalPath(source), canonicalPath(destination)
    if source and destination and pathInside(current_path, source) then
        local suffix = current_path == source and "" or current_path:sub(#source + 2)
        queueRefresh(suffix == "" and destination or fs.combine(destination, suffix))
    else
        queueRefresh()
    end
end)
listen("filesystem.association_changed", function() queueRefresh() end)
listen("filesystem.associations_reset", function() queueRefresh() end)
listen("filesystem.associations_pruned", function() queueRefresh() end)

listen("theme.changed", function()
    applyTheme()
    rebuildBreadcrumb()
    renderList({keep_selection=true})
end)

local own_window_id = os.getWindowId and os.getWindowId() or nil
if dragdrop and own_window_id then
    drop_target = dragdrop.registerTarget("filely:" .. tostring(own_window_id), {
        window_id=own_window_id,
        resolve=function(_, y)
            if isReadOnly() then return nil, "This folder is read-only" end
            local _, height = main_frame:getSize()
            if y >= 3 and y < height then
                local row = file_list_view:getOffset() + y - 2
                local entry = visible_entries[row]
                if entry and entry.isDir and fs.exists(entry.path) then
                    return entry.path
                end
            end
            return current_path
        end,
    })
end
listen("wm.window_closed", function(window_id)
    if own_window_id and window_id == own_window_id then removeEventListeners() end
end)

-- Theme and responsive relayout ------------------------------------------

local function styleButton(button)
    button:setBackground(palette.surface)
    button:setForeground(palette.foreground)
    button:setStateStyle("hover", {background=palette.accent, foreground=palette.accentText})
    button:setStateStyle("pressed", {background=palette.pressed, foreground=palette.accentText})
    button:setStateStyle("disabled", {background=palette.surface, foreground=palette.muted})
end

applyTheme = function()
    readOsPalette()
    main_frame:setBackground(palette.background)
    toolbar:setBackground(palette.surface)
    breadcrumb_frame:setBackground(palette.surface)
    path_input:setBackground(palette.background):setForeground(palette.foreground)
    path_input:setPlaceholderColor(palette.muted)
    filter_input:setBackground(palette.background):setForeground(palette.foreground)
    filter_input:setPlaceholderColor(palette.muted)
    header:setBackground(palette.surface)
    header_label:setBackground(palette.surface):setForeground(palette.muted)
    file_list_view:setBackground(palette.background):setForeground(palette.foreground)
    file_list_view:setEmptyTextColor(palette.muted)
    file_list_view:setSelectionColor(palette.accentText, palette.accent)
    file_list_view:setScrollbarColor(palette.surface)
    file_list_view:setScrollbarThumbColor(palette.accent)
    status_bar:setBackground(palette.background):setForeground(palette.muted)
    empty_action:setBackground(palette.accent):setForeground(palette.accentText)
    toast:setToastColors({
        default={bg=palette.surface, fg=palette.foreground},
        success={bg=palette.success, fg=palette.accentText},
        error={bg=palette.danger, fg=palette.accentText},
        warning={bg=palette.warning, fg=colors.black},
        info={bg=palette.accent, fg=palette.accentText},
    })
    for _, button in ipairs({btn_back, btn_forward, btn_home, btn_up, btn_add, empty_action}) do
        styleButton(button)
    end
    btn_add:setBackground(palette.accent):setForeground(palette.accentText)
    empty_action:setBackground(palette.accent):setForeground(palette.accentText)
end

local last_width = 0
main_frame:on("layout", function(_, width)
    if width ~= last_width then
        last_width = width
        rebuildBreadcrumb()
        renderList({keep_selection=true})
    end
end)

-- Initial location --------------------------------------------------------

applyTheme()

local initial_path = launch_args[1]
local initial_select = nil
if type(initial_path) == "string" and fs.exists(initial_path) then
    if fs.isDir(initial_path) then
        initial_path = canonicalPath(initial_path)
    else
        initial_select = canonicalPath(initial_path)
        initial_path = parentPath(initial_select)
    end
else
    initial_path = userfs and userfs.getUserDir() or "/"
end

loadDirectory(initial_path, {select_path=initial_select})
file_list_view:focus()

basalt.run()
removeEventListeners()
