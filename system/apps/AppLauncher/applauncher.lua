local basalt = require("basalt")
basalt.LOGGER.setEnabled(true)
basalt.LOGGER.setLogToFile(true)
local BasaltOS = require("basaltos")
local utils = require("utils")
local path = require("path")

local main = basalt.getMainFrame()
local theme = BasaltOS.getTheme()
local searchTerm = ""
local selectedCategory = "Installed"

main:setBackground(theme.primaryColor)
BasaltOS.setAppFrameColor(theme.primaryColor)

local updateAppGrid, refreshApps

local function getChildrenHeight(container)
    local height = 0
    for _, child in ipairs(container.get("children")) do
        if(child.get("visible"))then
            local newHeight = child.get("y") + child.get("height")
            if newHeight > height then
                height = newHeight
            end
        end
    end
    return height
end

local function scrollableFrame(container)
    container:onScroll(function(self, direction)
        local height = getChildrenHeight(self)
        local scrollOffset = self.get("offsetY")
        local maxScroll = height - self.get("height")
        scrollOffset = math.max(0, math.min(maxScroll, scrollOffset + direction))
        self.set("offsetY", scrollOffset)
    end)
end

BasaltOS.setMenu({
    ["File"] = {
        ["Refresh Apps"] = function()
            refreshApps()
        end,
        ["Exit"] = function()
            main:destroy()
        end
    },
    ["View"] = {
        ["Show Installed"] = function()
            selectedCategory = "Installed"
            updateAppGrid()
        end,
        ["Show Available"] = function()
            selectedCategory = "Available"
            updateAppGrid()
        end
    }
})

local topbar = main:addFrame({
    x = 1,
    y = 1,
    width = "{parent.width}",
    height = 1,
    background = colors.gray
})

local installedButton = topbar:addButton({
    text = "Installed",
    width = 10,
    height = 1,
    x = 2,
    foreground = colors.white,
    background = colors.gray,
})

local availableButton = topbar:addButton({
    text = "Available",
    width = 10,
    height = 1,
    x = 13,
    foreground = colors.black,
    background = colors.gray,
})

local searchInput = topbar:addInput({
    x = "{parent.width - 12}",
    width = 12,
    height = 1,
    background = colors.lightGray,
    focusedBackground = colors.white,
    foreground = colors.black,
    focusedForeground = colors.black,
})

local gridFrame = main:addFrame({
    x = 1,
    y = 3,
    width = "{parent.width}",
    height = "{parent.height - 3}",
    background = theme.primaryColor
})
scrollableFrame(gridFrame)

local scrollbar = main:addScrollbar({
    x = "{parent.width}",
    y = 3,
    width = 1,
    height = "{parent.height - 3}",
    background = colors.gray,
    foreground = colors.lightGray
})

local appButtons = {}
local apps = {}
local availableApps = {}
local filteredApps = {}
local resizeTimeout = nil

local excludedApps = {
    ["AppLauncher"] = true
}

local function updateCategoryButtons()
    installedButton:setBackground(selectedCategory == "Installed" and colors.black or colors.gray)
    installedButton:setForeground(selectedCategory == "Installed" and colors.white or colors.lightGray)

    availableButton:setBackground(selectedCategory == "Available" and colors.black or colors.gray)
    availableButton:setForeground(selectedCategory == "Available" and colors.white or colors.lightGray)
end

local function filterApps()
    filteredApps = {}
    local lowerSearch = string.lower(searchTerm)

    local sourceApps = {}

    if selectedCategory == "Installed" then
        for _, app in pairs(apps) do
            if not excludedApps[app.manifest.name] then
                table.insert(sourceApps, app)
            end
        end
    elseif selectedCategory == "Available" then
        sourceApps = availableApps
    end

    for _, app in ipairs(sourceApps) do
        local matchesSearch = searchTerm == "" or string.find(string.lower(app.manifest.name), lowerSearch)

        if matchesSearch then
            table.insert(filteredApps, app)
        end
    end

    table.sort(filteredApps, function(a, b)
        return string.lower(a.manifest.name) < string.lower(b.manifest.name)
    end)
end

local function removeApp(appName)
    local success, message = BasaltOS.removeApp(appName)

    if success then
        BasaltOS.showNotification("Success", message, 3)
        refreshApps()
    else
        BasaltOS.errorDialog(message)
    end
end

local function showRemoveAppDialog(appName, app)
    local canRemove, reason = BasaltOS.canRemoveApp(appName)
    if not canRemove then
        BasaltOS.errorDialog(reason)
        return
    end

    local message = "Are you sure you want to remove \"" .. appName .. "\"?"
    if app.manifest.fileAssociations then
        message = message .. "\n\nThis will also remove associated file extensions."
    end

    BasaltOS.confirmDialog(
        "Remove App",
        message,
        function(confirmed)
            if confirmed then
                removeApp(appName)
            end
        end
    )
end
local function createAppGrid()
    for _, button in ipairs(appButtons) do
        if button.frame then
            button.frame:destroy()
        end
    end
    appButtons = {}

    local availableWidth = gridFrame.width + 1
    local appCardWidth = 11
    local spacing = 1
    local totalCardWidth = appCardWidth + spacing

    local cols = math.max(1, math.floor(availableWidth / totalCardWidth))
    local rows = math.ceil(#filteredApps / cols)

    for i, app in ipairs(filteredApps) do
        local col = ((i - 1) % cols) + 1
        local row = math.floor((i - 1) / cols) + 1

        local x = (col - 1) * totalCardWidth + 1
        local y = (row - 1) * 6 + 1

        local appFrame = gridFrame:addFrame({
            x = x,
            y = y,
            width = appCardWidth,
            height = 5,
            background = colors.black
        })

        local iconElement
        local launchIcon = false
        local iconPath = ""
        if app.manifest.launchIcon then 
            iconPath = path.resolve(app.manifest.launchIcon)
            if fs.exists(iconPath) then
                launchIcon = true
            end
        else
            iconPath = app.manifest.icon and path.resolve(app.manifest.icon) or ""
        end
        if selectedCategory == "Installed" then
            if iconPath ~= "" then
                local bimg = utils.loadBimg(iconPath)
                if bimg then
                    iconElement = appFrame:addImage()
                    if launchIcon then 
                        iconElement:setPosition(1, 1)
                        iconElement:setSize(appCardWidth, 4)
                    else
                        iconElement:setPosition(5, 2)
                        iconElement:setSize(3, 2)
                    end
                    iconElement:setBimg(bimg)
                end
            end
        end

        if not iconElement then
            iconElement = appFrame:addLabel({
                x = 5,
                y = 1,
                text = selectedCategory == "Available" and "[D]" or "[A]",
                foreground = selectedCategory == "Available" and colors.green or colors.blue
            })
        end

        local labelBg = appFrame:addVisualElement({
            x = 1,
            y = 5,
            width = appCardWidth,
            height = 1,
            background = colors.lightGray
        })

        local name = string.sub(app.manifest.name, 1, 8)
        local nameLabel = appFrame:addLabel({
            x = math.floor(appCardWidth / 2 - #name / 2 + 0.5),
            y = 5,
            text = name,
            foreground = colors.black
        })

        local appName = app.manifest.name

        appFrame:onClickUp(function(self, button, x, y)
            if self.focused then
                if selectedCategory == "Installed" then
                    if button == 1 then
                        BasaltOS.openApp(appName)
                    elseif button == 2 then
                        local winX, winY = BasaltOS.getWindowPosition()
                        local menuX = winX + x + appFrame.x
                        local menuY = winY + y + 2 + appFrame.y - gridFrame.offsetY

                        local menuItems = {
                            {
                                text = "Open",
                                action = function()
                                    BasaltOS.openApp(appName)
                                end
                            }
                        }

                        local canRemove, _ = BasaltOS.canRemoveApp(appName)
                        if canRemove then
                            table.insert(menuItems, { 
                                text = "Remove",
                                action = function()
                                    showRemoveAppDialog(appName, app)
                                end
                            })
                        end

                        BasaltOS.contextMenu(menuX, menuY, menuItems, {
                            width = 12,
                            maxHeight = 12
                        })
                    end
                end
            end
        end)

        table.insert(appButtons, {
            frame = appFrame,
            app = app
        })
    end

    local maxScroll = math.max(0, rows * 5 - gridFrame.height + 1)
    scrollbar:setMax(maxScroll)
end

function updateAppGrid()
    updateCategoryButtons()
    filterApps()
    createAppGrid()

    local resultText = #filteredApps .. " " .. string.lower(selectedCategory) .. " apps"
    if searchTerm ~= "" then
        resultText = resultText .. " (filtered)"
    end
end

local function loadAvailableApps()
    availableApps = {}
end

function refreshApps()
    apps = BasaltOS.getApps()
    loadAvailableApps()
    updateAppGrid()
end

searchInput:onChange("text", function()
    searchTerm = searchInput:getText()
    updateAppGrid()
end)

searchInput:onKey(function(self, key)
    if key == keys.escape then
        searchInput:setText("")
        searchTerm = ""
        updateAppGrid()
    end
end)

installedButton:onClick(function()
    selectedCategory = "Installed"
    updateAppGrid()
end)

availableButton:onClick(function()
    selectedCategory = "Available"
    updateAppGrid()
end)

scrollbar:onChange("value", function()
    local offset = scrollbar:getValue()
    gridFrame:setScrollOffset(0, -offset)
end)

local function scheduleResize()
    if resizeTimeout then
        resizeTimeout = nil
    end

    basalt.schedule(function()
        if resizeTimeout == nil then
            resizeTimeout = true
            createAppGrid()
            resizeTimeout = nil
        end
    end)
end

main:observe("width", function()
    scheduleResize()
end)

main:observe("height", function()
    scheduleResize()
end)

main:onKey(function(self, key)
    if key == keys.f5 then
        refreshApps()
    elseif key == keys.escape then
        searchInput:setText("")
        searchTerm = ""
        updateAppGrid()
    end
end)

refreshApps()

basalt.run()