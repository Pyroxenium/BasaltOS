local basalt = require("basalt")
local BasaltOS = require("basaltos")

local main = basalt.getMainFrame()
local theme = BasaltOS.getTheme()
local searchTerm = ""
local selectedCategory = "All"

main:setBackground(theme.primaryColor)
BasaltOS.setAppFrameColor(theme.primaryColor)

local updateAppGrid, refreshApps

BasaltOS.setTitle("App Launcher")
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
        ["Show All"] = function()
            selectedCategory = "All"
            updateAppGrid()
        end,
        ["Show System"] = function()
            selectedCategory = "System"
            updateAppGrid()
        end,
        ["Show User"] = function()
            selectedCategory = "User"
            updateAppGrid()
        end
    }
})

local header = main:addFrame({
    x = 1,
    y = 2,
    width = "{parent.width}",
    height = 3,
    background = colors.black
})

local titleLabel = header:addLabel({
    x = 2,
    y = 1,
    text = "Application Launcher",
    foreground = theme.primaryTextColor
})

local searchLabel = header:addLabel({
    x = 2,
    y = 2,
    text = "Search:",
    foreground = theme.primaryTextColor
})

local searchInput = header:addInput({
    x = 10,
    y = 2,
    width = "{parent.width - 12}",
    height = 1,
    background = colors.white,
    foreground = colors.black
})

local categoryFrame = header:addFrame({
    x = 2,
    y = 3,
    width = "{parent.width - 4}",
    height = 1,
    background = colors.black
})

local allButton = categoryFrame:addButton({
    x = 1,
    y = 1,
    width = 6,
    height = 1,
    text = "All",
    background = colors.gray,
    foreground = colors.white
})

local systemButton = categoryFrame:addButton({
    x = 8,
    y = 1,
    width = 8,
    height = 1,
    text = "System",
    background = colors.lightGray,
    foreground = colors.black
})

local userButton = categoryFrame:addButton({
    x = 17,
    y = 1,
    width = 6,
    height = 1,
    text = "User",
    background = colors.lightGray,
    foreground = colors.black
})

local gridFrame = main:addFrame({
    x = 1,
    y = 6,
    width = "{parent.width}",
    height = "{parent.height - 6}",
    background = theme.primaryColor
})

local scrollbar = main:addScrollbar({
    x = "{parent.width}",
    y = 6,
    width = 1,
    height = "{parent.height - 6}",
    background = colors.gray,
    foreground = colors.lightGray
})

local appButtons = {}
local apps = {}
local filteredApps = {}

local function updateCategoryButtons()
    allButton:setBackground(selectedCategory == "All" and colors.gray or colors.lightGray)
    allButton:setForeground(selectedCategory == "All" and colors.white or colors.black)

    systemButton:setBackground(selectedCategory == "System" and colors.gray or colors.lightGray)
    systemButton:setForeground(selectedCategory == "System" and colors.white or colors.black)

    userButton:setBackground(selectedCategory == "User" and colors.gray or colors.lightGray)
    userButton:setForeground(selectedCategory == "User" and colors.white or colors.black)
end

local function filterApps()
    filteredApps = {}
    local lowerSearch = string.lower(searchTerm)

    for _, app in pairs(apps) do
        local matchesSearch = searchTerm == "" or string.find(string.lower(app.manifest.name), lowerSearch)
        local matchesCategory = selectedCategory == "All" or 
                               (selectedCategory == "System" and (app.manifest.category == "system" or not app.manifest.category)) or
                               (selectedCategory == "User" and app.manifest.category == "user")

        if matchesSearch and matchesCategory then
            table.insert(filteredApps, app)
        end
    end

    table.sort(filteredApps, function(a, b)
        return string.lower(a.manifest.name) < string.lower(b.manifest.name)
    end)
end

local function createAppGrid()
    for _, button in ipairs(appButtons) do
        if button.frame then
            button.frame:destroy()
        end
    end
    appButtons = {}

    local cols = math.floor((gridFrame.width - 2) / 12)
    local rows = math.ceil(#filteredApps / cols)

    for i, app in ipairs(filteredApps) do
        local col = ((i - 1) % cols) + 1
        local row = math.floor((i - 1) / cols) + 1

        local x = (col - 1) * 12 + 2
        local y = (row - 1) * 4 + 1

        local appFrame = gridFrame:addFrame({
            x = x,
            y = y,
            width = 10,
            height = 3,
            background = colors.lightGray
        })

        local iconLabel = appFrame:addLabel({
            x = 5,
            y = 1,
            text = "[A]",
            foreground = colors.blue
        })

        local nameLabel = appFrame:addLabel({
            x = 1,
            y = 2,
            text = string.sub(app.manifest.name, 1, 8),
            foreground = colors.black
        })

        appFrame:onClick(function()
            BasaltOS.openApp(app.manifest.name)
        end)

        table.insert(appButtons, {
            frame = appFrame,
            app = app
        })
    end

    local maxScroll = math.max(0, rows * 4 - gridFrame.height + 1)
    scrollbar:setMax(maxScroll)
end

function updateAppGrid()
    updateCategoryButtons()
    filterApps()
    createAppGrid()
end

function refreshApps()
    apps = BasaltOS.getApps()
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

allButton:onClick(function()
    selectedCategory = "All"
    updateAppGrid()
end)

systemButton:onClick(function()
    selectedCategory = "System"
    updateAppGrid()
end)

userButton:onClick(function()
    selectedCategory = "User"
    updateAppGrid()
end)

scrollbar:onChange("value", function()
    local offset = scrollbar:getValue()
    gridFrame:setScrollOffset(0, -offset)
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