-- Filely - File Manager for BasaltOS

local basalt = require("basalt")
basalt.LOGGER.setLogToFile(true)
basalt.LOGGER.setEnabled(true)
local app    = require("app")

local filesystem  = app.filesystem
local userfs      = app.userfs
local dialog      = app.dialog
local contextmenu = app.contextmenu
local theme       = app.theme

if not filesystem then error("FileSystem service not available") end

local main_frame = basalt.getMainFrame()
main_frame:setBackground(theme("secondary"))

-- State
local current_path = "/"
local file_list    = {}
local history      = {}

-- Icons
local EXT_ICONS = { lua="\xb7", txt="\xb7", md="\xb7", json="\xb7", nfp="*" }
local function fileIcon(entry)
    if entry.isDir then return "\x10" end
    return EXT_ICONS[entry.extension or ""] or "-"
end

-- Toolbar (row 1)
local toolbar = main_frame:addFrame({
    x=1, y=1, width="{parent.width}", height=1,
    background=theme("primary"),
})

local btn_back = toolbar:addButton({
    x=1, y=1, width=3, height=1,
    text=" \17 ", background=theme("primary"), foreground=theme("text"),
})
btn_back:setBackgroundState("clicked", theme("btn_clicked"))

local btn_home = toolbar:addButton({
    x=4, y=1, width=3, height=1,
    text=" \169 ", background=theme("primary"), foreground=theme("text"),
})
btn_home:setBackgroundState("clicked", theme("btn_clicked"))

local btn_up = toolbar:addButton({
    x=7, y=1, width=3, height=1,
    text=" \30 ", background=theme("primary"), foreground=theme("text"),
})
btn_up:setBackgroundState("clicked", theme("btn_clicked"))

local path_label = toolbar:addLabel({
    x=11, y=1, width="{parent.width - 21}", height=1,
    text="/", foreground=theme("text"), background=theme("primary"),
})

local btn_newfolder = toolbar:addButton({
    x="{parent.width - 9}", y=1, width=5, height=1,
    text="+Dir", background=theme("primary"), foreground=theme("text"),
})
btn_newfolder:setBackgroundState("clicked", theme("btn_clicked"))

local btn_newfile = toolbar:addButton({
    x="{parent.width - 4}", y=1, width=5, height=1,
    text="+Fil", background=theme("primary"), foreground=theme("text"),
})
btn_newfile:setBackgroundState("clicked", theme("btn_clicked"))

-- File list
local file_list_view = main_frame:addList({
    x=1, y=2,
    width="{parent.width}",
    height="{parent.height - 2}",
    background=theme("secondary"),
    foreground=theme("text"),
})
file_list_view:setSelectionColor(theme("primary"), theme("text"))

-- Status bar
local status_bar = main_frame:addLabel({
    x=1, y="{parent.height}",
    width="{parent.width}", height=1,
    text="", foreground=theme("text_dim"), background=theme("surface"),
})

-- Directory loader
local function loadDirectory(path, push_history)
    if push_history and current_path ~= path then
        table.insert(history, current_path)
    end
    current_path = path

    local display = path
    if #display > 30 then display = "<" .. display:sub(-29) end
    path_label:setText(display)

    file_list = filesystem.listDir(path) or {}

    if path ~= "/" then
        table.insert(file_list, 1, { name="..", path=fs.getDir(path), isDir=true, size=0 })
    end

    file_list_view:clear()
    for _, entry in ipairs(file_list) do
        local icon = fileIcon(entry)
        local fg   = entry.isDir and theme("primary") or theme("text")
        file_list_view:addItem(" " .. icon .. " " .. entry.name, nil, fg, theme("secondary"))
    end

    local dirs, files = 0, 0
    for _, e in ipairs(file_list) do
        if e.name ~= ".." then
            if e.isDir then dirs = dirs + 1 else files = files + 1 end
        end
    end
    status_bar:setText(string.format(" %s  |  %d folders, %d files", path, dirs, files))
end

-- Toolbar actions
btn_back:onClick(function()
    if #history > 0 then
        loadDirectory(table.remove(history), false)
    end
end)

btn_home:onClick(function()
    local home = userfs and userfs.getUserDir() or "/"
    loadDirectory(home, true)
end)

btn_up:onClick(function()
    if current_path ~= "/" then
        loadDirectory(fs.getDir(current_path), true)
    end
end)

btn_newfolder:onClick(function()
    if dialog then
        dialog.prompt("New Folder", "Folder name:", "", function(name)
            if name and name ~= "" then
                filesystem.makeDir(fs.combine(current_path, name))
                loadDirectory(current_path, false)
            end
        end)
    end
end)

btn_newfile:onClick(function()
    if dialog then
        dialog.prompt("New File", "File name:", "", function(name)
            if name and name ~= "" then
                local f = fs.open(fs.combine(current_path, name), "w")
                if f then f.close() end
                loadDirectory(current_path, false)
            end
        end)
    end
end)

-- File list interaction
file_list_view:onDoubleClick(function(self)
    local idx   = file_list_view:getSelectedIndex()
    local entry = file_list[idx]
    if not entry then return end
    if entry.isDir then
        loadDirectory(entry.path, true)
    else
        local ok, err = filesystem.openFile(entry.path)
        if not ok and dialog then
            dialog.alert("Cannot Open", err or "No app associated with this file type")
        end
    end
end)

file_list_view:onClickUp(function(self, btn_num, x, y)
    if btn_num ~= 2 then return end
    local offset = file_list_view.getResolved("offset") or 0
    local idx    = y + offset
    local entry  = file_list[idx]
    if not entry or entry.name == ".." then return end
    if not contextmenu then return end

    local items = {}
    if entry.isDir then
        table.insert(items, { label="Open", action=function() loadDirectory(entry.path, true) end })
    else
        table.insert(items, { label="Open", action=function()
            local ok, err = filesystem.openFile(entry.path)
            if not ok and dialog then dialog.alert("Cannot Open", err or "") end
        end })
    end
    table.insert(items, { separator=true })
    table.insert(items, { label="Rename", action=function()
        if dialog then
            dialog.prompt("Rename", "New name:", entry.name, function(name)
                if name and name ~= "" then
                    filesystem.move(entry.path, fs.combine(current_path, name))
                    loadDirectory(current_path, false)
                end
            end)
        end
    end })
    table.insert(items, { label="Delete", action=function()
        if dialog then
            dialog.confirm("Delete", "Delete '" .. entry.name .. "'?", function(ok)
                if ok then
                    filesystem.delete(entry.path)
                    loadDirectory(current_path, false)
                end
            end)
        end
    end })

    local ax, ay = file_list_view:getAbsolutePosition(x, y)
    local winX, winY = window.getPosition()
    contextmenu.open(ax + winX, ay + winY, items)
end)

-- Keyboard shortcuts
main_frame:onKey(function(self, key)
    if key == keys.enter then
        local idx   = file_list_view:getSelectedIndex()
        local entry = file_list[idx]
        if not entry then return end
        if entry.isDir then loadDirectory(entry.path, true)
        else filesystem.openFile(entry.path) end
    elseif key == keys.backspace then
        if current_path ~= "/" then loadDirectory(fs.getDir(current_path), true) end
    elseif key == keys.h then
        loadDirectory(userfs and userfs.getUserDir() or "/", true)
    elseif key == keys.r then
        loadDirectory(current_path, false)
    end
end)

-- Boot
loadDirectory(userfs and userfs.getUserDir() or "/", false)

basalt.run()