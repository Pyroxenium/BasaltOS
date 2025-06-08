local BasaltOS = require("basaltos")
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

updateList()

fList:onClickUp(function(self, btn, x, y)
    if self.focused and btn == 1 then
        local selected = self:getData()[y-1+self.scrollOffset]
        if selected then
            local fileName = selected[1]

            if isDoubleClick(fileName) then
                local filePath = path .. "/" .. fileName
                if fs.isDir(filePath) then
                    table.insert(backHistory, path)
                    nextHistory = {}
                    path = filePath
                    searchInput:setText("")
                    searchTerm = ""
                    updateList()
                else
                    BasaltOS.openApp("Edit", filePath)
                end
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

-- Home button functionality
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