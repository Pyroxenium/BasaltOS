local BasaltOS = require("basaltos")
local clipboard = require("clipboard")
local basalt = require("basalt")
basalt.LOGGER.setEnabled(true)
basalt.LOGGER.setLogToFile(true)
local theme = BasaltOS.getTheme()

local main = basalt.getMainFrame()
local path = ""
local backHistory = {}
local nextHistory = {}
local searchTerm = ""
local lastClickTime = 0
local lastClickedItem = nil
local DOUBLE_CLICK_TIME = 0.5 -- double click in seconds

local function findAvailableName(targetDir, originalName)
    local baseName, extension = originalName:match("^(.-)%.([^%.]+)$")
    if not baseName then
        baseName = originalName
        extension = ""
    else
        extension = "." .. extension
    end

    local counter = 1
    local newName = originalName

    while fs.exists(fs.combine(targetDir, newName)) do
        newName = baseName .. "(" .. counter .. ")" .. extension
        counter = counter + 1
    end

    return newName
end

main:setBackground(theme.primaryColor)
BasaltOS.setAppFrameColor(theme.primaryColor)
BasaltOS.setMenu({["File"] = function() end})
local searchInput, updateList

local topbar = main:addFrame({
    x = 1,
    y = 1,
    width = "{parent.width}",
    height = 1,
    background = colors.gray
})

local backButton = topbar:addButton({
    text = "\27",
    width = 1,
    height = 1,
    foreground = theme.primaryTextColor,
    background = colors.gray,
})

local nextButton = topbar:addButton({
    text = "\26",
    width = 1,
    height = 1,
    x = 3,
    foreground = theme.primaryTextColor,
    background = colors.gray,
})

local homeButton = topbar:addButton({
    text = "\1",
    width = 1,
    height = 1,
    x = 5,
    foreground = theme.primaryTextColor,
    background = colors.gray,
})

local breadcrumbFrame = topbar:addFrame({
    x = 7,
    y = 1,
    width = "{parent.width - 14}",
    height = 1,
    background = colors.gray
})

local pathSegments = {}

local function createBreadcrumbs()
    for _, segment in ipairs(pathSegments) do
        if segment.element then
            segment.element:destroy()
        end
    end
    pathSegments = {}

    local segments = {}
    if path == "" or path == "/" then
        -- Don't add any segments for root
    else
        local currentPath = ""
        for segment in path:gmatch("[^/]+") do
            currentPath = currentPath .. "/" .. segment
            table.insert(segments, {name = segment, fullPath = currentPath})
        end
    end

    local totalWidth = 0
    for i, segment in ipairs(segments) do
        totalWidth = totalWidth + #segment.name + 2
        if i < #segments then
            totalWidth = totalWidth + 1
        end
    end

    local frameWidth = breadcrumbFrame.width
    local currentX = 1

    if totalWidth > frameWidth then
        local offset = totalWidth - frameWidth + 3
        currentX = 1 - offset

        local ellipsisLabel = breadcrumbFrame:addLabel()
        ellipsisLabel:setPosition(1, 1)
        ellipsisLabel:setText("...")
        ellipsisLabel:setForeground(colors.gray)

        table.insert(pathSegments, {
            element = ellipsisLabel,
            ellipsis = true
        })
    end

    for i, segment in ipairs(segments) do
        local segmentButton = breadcrumbFrame:addButton()
        segmentButton:setPosition(currentX, 1)
        segmentButton:setSize(#segment.name + 2, 1)
        segmentButton:setText(segment.name)
        segmentButton:setBackground(colors.gray)
        segmentButton:setForeground(theme.primaryTextColor)

        segmentButton:onClick(function()
            if segment.fullPath ~= path then
                table.insert(backHistory, path)
                nextHistory = {}
                path = segment.fullPath
                searchInput:setText("")
                searchTerm = ""
                updateList()
                createBreadcrumbs()
            end
        end)

        table.insert(pathSegments, {
            element = segmentButton,
            name = segment.name,
            fullPath = segment.fullPath
        })

        currentX = currentX + #segment.name + 2

        if i < #segments then
            local separator = breadcrumbFrame:addLabel()
            separator:setPosition(currentX, 1)
            separator:setText(">")
            separator:setForeground(colors.lightGray)

            table.insert(pathSegments, {
                element = separator,
                separator = true
            })

            currentX = currentX + 1
        end
    end
end

main:observe("width", function()
    createBreadcrumbs()
end)

local pathLabel = topbar:addLabel({
    text = path,
    x = 5,
    height = 1,
    foreground = theme.primaryTextColor
})

searchInput = topbar:addInput({
    x = "{parent.width - 7}",
    width = 8,
    height = 1,
    background = colors.lightGray,
    focusedBackground = colors.white,
    foreground = colors.black,
    focusedForeground = colors.black,
})

local fList = main:addTable({
    x = 1,
    y = 3,
    width = "{parent.width-1}",
    height = "{parent.height-2}",
})

local scrollbar = main:addScrollbar({
    x = "{parent.width}",
    y = 3,
    width = 1,
    height = "{parent.height-2}",
})

fList:setColumns({{name="Name",width=12}, {name="Type",width=10}, {name="Size",width=7}})
scrollbar:attach(fList, {property = "scrollOffset", min=0, max=function()
    return math.max(0, #fList:getData() - fList:getHeight() + 1)
end})

local function isDoubleClick(item)
    local currentTime = os.clock()
    if lastClickedItem == item and (currentTime - lastClickTime) < DOUBLE_CLICK_TIME then
        return true
    end
    lastClickTime = currentTime
    lastClickedItem = item
    return false
end

local function filterFiles(files, searchTerm)
    if not searchTerm or searchTerm == "" then
        return files
    end

    local filtered = {}
    local lowerSearch = string.lower(searchTerm)

    for _, file in ipairs(files) do
        if string.find(string.lower(file), lowerSearch) then
            table.insert(filtered, file)
        end
    end

    return filtered
end

function updateList()
    local files = fs.list(path)
    local filteredFiles = filterFiles(files, searchTerm)
    local data = {}

    for _, file in ipairs(filteredFiles) do
        local filePath = path .. "/" .. file
        local fileType = fs.isDir(filePath) and "Folder" or "File"
        local fileSize = fs.isDir(filePath) and "-" or fs.getSize(filePath)
        table.insert(data, {file, fileType, fileSize})
    end

    fList:setData(data)
    createBreadcrumbs()
end

searchInput:onChange("text", function()
    searchTerm = searchInput:getText()
    updateList()
end)

local function createContextMenu(x, y, fileName, filePath)
    local isDirectory = fs.isDir(filePath)
    local menuItems = {}

    if isDirectory then
        table.insert(menuItems, {
            text = "Open",
            action = function()
                table.insert(backHistory, path)
                nextHistory = {}
                path = filePath
                searchInput:setText("")
                searchTerm = ""
                updateList()
            end
        })
        table.insert(menuItems, {
            text = "New File",
            action = function()
                local newFileName = "new_file.txt"
                local newFilePath = filePath .. "/" .. newFileName
                local file = fs.open(newFilePath, "w")
                if file then
                    file.close()
                    updateList()
                end
            end
        })
        table.insert(menuItems, {
            text = "New Folder", 
            action = function()
                local newFolderName = "new_folder"
                local newFolderPath = filePath .. "/" .. newFolderName
                fs.makeDir(newFolderPath)
                updateList()
            end
        })
    else
        table.insert(menuItems, {
            text = "Open",
            action = function()
                BasaltOS.openPath(filePath)
            end
        })
        table.insert(menuItems, {
            text = "Edit",
            action = function()
                BasaltOS.editPath(filePath)
            end
        })
    end    table.insert(menuItems, {
        text = "Copy",
        action = function()
            clipboard.copyFile(filePath, fileName)
        end
    })

    table.insert(menuItems, {
        text = "Rename",
        action = function()
            BasaltOS.inputDialog("Rename File", "Enter new name:", fileName, function(newName)
                if newName and newName ~= "" and newName ~= fileName then
                    fs.move(filePath, path .. "/" .. newName)
                    updateList()
                end
            end)
        end
    })    
    table.insert(menuItems, {
        text = "Delete ",
        action = function()
            local confirmMessage = string.format("Are you sure?")

            BasaltOS.confirmDialog("Delete " .. fileName, confirmMessage, function(confirmed)
                if confirmed then
                    fs.delete(filePath)
                    updateList()
                end
            end)
        end
    })

    table.insert(menuItems, {
        text = "Properties",
        action = function()
            local size = isDirectory and "Directory" or tostring(fs.getSize(filePath)) .. " bytes"
            local info = string.format("Name: %s\nType: %s\nSize: %s\nPath: %s", 
                                     fileName, 
                                     isDirectory and "Directory" or "File",
                                     size,
                                     filePath)
            BasaltOS.tooltip(x, y - 5, info, {duration = 5})
        end
    })
      return BasaltOS.contextMenu(x, y, menuItems, {
        width = 12,
        maxHeight = 12
    })
end

local function createFolderContextMenu(x, y)
    local menuItems = {}

    table.insert(menuItems, {
        text = "New File",
        action = function()
            BasaltOS.inputDialog("New File", "Enter filename:", "new_file.txt", function(fileName)
                if fileName and fileName ~= "" then
                    local newFilePath = path .. "/" .. fileName
                    local file = fs.open(newFilePath, "w")
                    if file then
                        file.close()
                        updateList()
                    end
                end
            end)
        end
    })    table.insert(menuItems, {
        text = "New Folder",
        action = function()
            BasaltOS.inputDialog("New Folder", "Enter folder name:", "new_folder", function(folderName)
                if folderName and folderName ~= "" then
                    local newFolderPath = path .. "/" .. folderName
                    fs.makeDir(newFolderPath)
                    updateList()
                end
            end)
        end
    })

    if clipboard.hasFile() then        
        table.insert(menuItems, {
            text = "Paste",
            action = function()
                local fileInfo = clipboard.getFile()
                if fileInfo then
                    local availableName = findAvailableName(path, fileInfo.name)
                    local success, error = clipboard.pasteFile(path, availableName)

                    if success then
                        updateList()
                    else
                        BasaltOS.notify("Error: " .. (error or "Unknown error"))
                    end
                end
            end
        })
    end

    table.insert(menuItems, {
        text = "--------",
        action = function() end
    })

    table.insert(menuItems, {
        text = "Refresh",
        action = function()
            updateList()
        end
    })

    table.insert(menuItems, {
        text = "Properties",
        action = function()
            local itemCount = 0
            local files = fs.list(path)
            if files then
                itemCount = #files
            end

            local info = string.format("Path: %s\nType: Directory\nItems: %d", 
                                     path,
                                     itemCount)
            BasaltOS.createDialog({
                title = "Folder Properties",
                message = info,
                buttons = {{text = "OK", action = function() end}}
            })
        end
    })
      return BasaltOS.contextMenu(x, y, menuItems, {
        width = 12,
        maxHeight = 8
    })
end

updateList()

fList:onClickUp(function(self, btn, x, y)
    if self.focused then
        local selected = self:getData()[y-1+self.scrollOffset]
        if selected then
            local fileName = selected[1]
            local filePath = path .. "/" .. fileName

            if btn == 1 then
                if isDoubleClick(fileName) then
                    if fs.isDir(filePath) then
                        table.insert(backHistory, path)
                        nextHistory = {}
                        path = filePath
                        searchInput:setText("")
                        searchTerm = ""
                        updateList()
                    else
                        BasaltOS.openPath(filePath)
                    end
                end
            elseif btn == 2 then
                local winX, winY = BasaltOS.getWindowPosition()
                createContextMenu(winX + x, winY + y + 2, fileName, filePath)
            end
        else
            if btn == 2 then
                local winX, winY = BasaltOS.getWindowPosition()
                createFolderContextMenu(winX + x, winY + y + 2)
            end
        end
    end
end)

backButton:onClickUp(function()
    if #backHistory > 0 then
        table.insert(nextHistory, path)
        path = table.remove(backHistory)
        searchInput:setText("")
        searchTerm = ""
        updateList()
    end
end)

nextButton:onClickUp(function()
    if #nextHistory > 0 then
        table.insert(backHistory, path)
        path = table.remove(nextHistory)
        searchInput:setText("")
        searchTerm = ""
        updateList()
    end
end)

homeButton:onClickUp(function()
    if path ~= "" then
        table.insert(backHistory, path)
        nextHistory = {}
        path = ""
        searchInput:setText("")
        searchTerm = ""
        updateList()
    end
end)

basalt.run()