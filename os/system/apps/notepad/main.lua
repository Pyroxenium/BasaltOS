-- /system/apps/notepad/main.lua
-- Compact BasaltOS text editor with open/save support.

local launch_args = {...}
local basalt = require("basalt")
local app = require("app")

local dialog = app.dialog
local notification = app.notification
local filesystem = app.filesystem
local userfs = app.userfs

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
    pressed=theme("btn_clicked", colors.cyan),
    border=theme("border", colors.gray),
}

local current_path = nil
local dirty = false
local loading_document = false
local ctrl_down = false

local main = basalt.getMainFrame()
main:setBackground(C.background)

local toolbar = main:addFrame({
    x=1, y=1, width="{parent.width}", height=2,
    background=C.background,
})

toolbar:addFrame({
    x=1, y=2, width="{parent.width}", height=1,
    background=C.border, disabled=true,
})

local editor = main:addTextBox({
    x=1, y=3,
    width="{parent.width}", height="{parent.height - 3}",
    text="", foreground=C.foreground, background=C.background,
    scrollbar="auto", scrollbarColor=C.surface,
    scrollbarThumbColor=C.primary,
    selectionBackground=C.primary, selectionForeground=C.text,
})

local status_bar = main:addFrame({
    x=1, y="{parent.height}", width="{parent.width}", height=1,
    background=C.surface, disabled=true,
})

local status_label = status_bar:addLabel({
    x=2, y=1, width="{parent.width - 2}", height=1,
    text="", foreground=C.muted, background=false, disabled=true,
})

local function setWindowTitle()
    local title = "Notepad"
    if current_path then title = title .. " - " .. fs.getName(current_path) end
    if window and window.setTitle then window.setTitle(title) end
end

local function updateStatus()
    local text = editor:getText() or ""
    local lines = 1
    for _ in text:gmatch("\n") do lines = lines + 1 end

    local name = current_path and fs.getName(current_path) or "Untitled"
    if dirty then name = "* " .. name end
    status_label:setText(('%s  |  %d lines  |  %d chars'):format(
        name, lines, #text
    ))
    setWindowTitle()
end

local function showError(message)
    if dialog and dialog.alert then
        dialog.alert("Notepad", tostring(message or "Unknown error"))
    elseif notification and notification.show then
        notification.show("Notepad", tostring(message or "Unknown error"), "error")
    end
end

local function readFile(path)
    if type(path) ~= "string" or path == "" then
        return nil, "No file selected"
    end
    if not fs.exists(path) then return nil, "File not found: " .. path end
    if fs.isDir(path) then return nil, "Cannot open a directory" end

    local handle, err = fs.open(path, "r")
    if not handle then return nil, err or "Could not open file" end
    local ok, result = pcall(handle.readAll)
    handle.close()
    if not ok then return nil, tostring(result) end
    return result or ""
end

local function loadDocument(path)
    local text, err = readFile(path)
    if text == nil then
        showError(err)
        return false
    end

    loading_document = true
    editor:setText(text)
    loading_document = false
    current_path = path
    dirty = false
    if filesystem and filesystem.addRecentFile then
        filesystem.addRecentFile(path)
    end
    updateStatus()
    editor:focus()
    return true
end

local function defaultSavePath()
    local root = userfs and userfs.getUserDir and userfs.getUserDir()
    if root and root ~= "" then
        return fs.combine(root, "documents/Untitled.txt")
    end
    return "Untitled.txt"
end

local function writeDocument(path)
    if type(path) ~= "string" then return false, "No path entered" end
    path = path:match("^%s*(.-)%s*$") or ""
    if path == "" then return false, "No path entered" end
    if fs.exists(path) and fs.isDir(path) then
        return false, "Cannot save over a directory"
    end

    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        return false, "Folder not found: " .. parent
    end

    local handle, err = fs.open(path, "w")
    if not handle then return false, err or "Could not open file for writing" end
    local ok, write_err = pcall(handle.write, editor:getText() or "")
    handle.close()
    if not ok then return false, tostring(write_err) end

    current_path = path
    dirty = false
    if filesystem and filesystem.addRecentFile then
        filesystem.addRecentFile(path)
    end
    updateStatus()
    return true
end

local saveDocument

local function saveAs()
    local suggested = current_path or defaultSavePath()
    local start_path = fs.getDir(suggested)
    if start_path == "" then start_path = "/" end
    dialog.saveFile({
        title="Save As",
        startPath=start_path,
        defaultName=fs.getName(suggested),
        defaultExtension="txt",
    }, function(path)
        if not path or path == "" then
            editor:focus()
            return
        end
        local ok, err = writeDocument(path)
        if not ok then showError(err) end
        editor:focus()
    end)
end

saveDocument = function()
    if not current_path then
        saveAs()
        return
    end
    local ok, err = writeDocument(current_path)
    if not ok then showError(err) end
    editor:focus()
end

local function confirmDiscard(callback)
    if not dirty then
        callback()
        return
    end
    dialog.confirm("Unsaved Changes", "Discard changes to the current document?", function(confirmed)
        if confirmed then callback() else editor:focus() end
    end)
end

local function newDocument()
    confirmDiscard(function()
        loading_document = true
        editor:setText("")
        loading_document = false
        current_path = nil
        dirty = false
        updateStatus()
        editor:focus()
    end)
end

local function openDocument()
    confirmDiscard(function()
        local start_path = current_path and fs.getDir(current_path)
            or (userfs and userfs.getUserDir and userfs.getUserDir())
            or "/"
        dialog.openFile({title="Open File", startPath=start_path}, function(path)
            if path then loadDocument(path) else editor:focus() end
        end)
    end)
end

local function toolbarButton(x, width, text, callback)
    local button = toolbar:addButton({
        x=x, y=1, width=width, height=1, text=text,
        foreground=C.foreground, background=C.background,
    })
    button:setStateStyle("hover", {background=C.primary, foreground=C.text})
    button:setStateStyle("pressed", {background=C.pressed, foreground=C.text})
    button:onClickUp(function(_, mouse_button)
        if mouse_button == 1 then callback() end
    end)
    return button
end

toolbarButton(2, 4, "New", newDocument)
toolbarButton(7, 4, "Open", openDocument)
toolbarButton(12, 4, "Save", saveDocument)
toolbarButton(17, 7, "Save As", saveAs)

editor:onChange(function()
    if loading_document then return end
    dirty = true
    updateStatus()
end)

editor:onKey(function(_, key)
    if key == keys.leftCtrl or key == keys.rightCtrl then
        ctrl_down = true
    elseif ctrl_down and key == keys.s then
        saveDocument()
    elseif ctrl_down and key == keys.o then
        openDocument()
    elseif ctrl_down and key == keys.n then
        newDocument()
    end
end)

editor:onKeyUp(function(_, key)
    if key == keys.leftCtrl or key == keys.rightCtrl then ctrl_down = false end
end)

editor:onBlur(function() ctrl_down = false end)

if filesystem and filesystem.registerFileType then
    filesystem.registerFileType("txt", "notepad")
    filesystem.registerFileType("md", "notepad")
    filesystem.registerFileType("json", "notepad")
    filesystem.registerFileType("log", "notepad")
end

local initial_path = launch_args[1]
if type(initial_path) == "string" and initial_path ~= "" then
    if not loadDocument(initial_path) then
        current_path = nil
        dirty = false
        updateStatus()
        editor:focus()
    end
else
    updateStatus()
    editor:focus()
end

basalt.run()
