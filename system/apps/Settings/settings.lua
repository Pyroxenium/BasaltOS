local BasaltOS = require("basaltos")
local basalt = require("basalt")
local theme = BasaltOS.getTheme()

local main = basalt.getMainFrame()
main:setBackground(theme.primaryColor)
BasaltOS.setAppFrameColor(theme.primaryColor)

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

local function showAppSelectionDialog(extension, actionType, callback)
    BasaltOS.appSelectionDialog(extension, actionType, function(selectedApp)
        callback(selectedApp)
    end)
end

local currentSection = "file_associations"

local sidebar, contentFrame, updateContent

sidebar = main:addFrame({
    x = 1,
    y = 1,
    width = 10,
    height = "{parent.height}",
    background = colors.gray
})

contentFrame = main:addFrame({
    x = 11,
    y = 1,
    width = "{parent.width - 10}",
    height = "{parent.height}",
    background = theme.primaryColor
})
scrollableFrame(sidebar)


local sidebarItems = {
    {id = "file_associations", text = "File Types", y = 2},
    {id = "extension_mgmt", text = "Extensions", y = 4},
    {id = "general", text = "General", y = 6},
    {id = "about", text = "About", y = 8}
}

local function createSidebar()
    for _, item in ipairs(sidebarItems) do
        local button = sidebar:addButton({
            x = 1,
            y = item.y,
            width = 9,
            height = 1,
            text = item.text,
            background = currentSection == item.id and colors.lightGray or colors.gray,
            foreground = colors.white
        })

        button:onClick(function()
            currentSection = item.id
            updateContent()
            createSidebar()
        end)
    end
end

local function createFileAssociationsContent()
    contentFrame:clear()

    local title = contentFrame:addLabel({
        x = 2,
        y = 2,
        text = "File Type Associations",
        foreground = colors.yellow
    })

    local subtitle = contentFrame:addLabel({
        x = 2,
        y = 3,
        text = "Choose which apps open specific file types",
        foreground = colors.lightGray
    })

    local allAssociations = BasaltOS.getFileAssociations()
    local extensions = {}

    for ext, _ in pairs(allAssociations.defaults) do
        table.insert(extensions, ext)
    end
    for ext, _ in pairs(allAssociations.associations) do
        local found = false
        for _, existing in ipairs(extensions) do
            if existing == ext then
                found = true
                break
            end
        end
        if not found then
            table.insert(extensions, ext)
        end
    end

    table.sort(extensions)

    local scrollFrame = contentFrame:addFrame({
        x = 2,
        y = 5,
        width = "{parent.width - 3}",
        height = "{parent.height - 6}",
        background = theme.primaryColor
    })
    scrollableFrame(scrollFrame)

    local currentY = 1
      for _, extension in ipairs(extensions) do
        if extension ~= "__directory" then -- Skip directory for now, we'll add it separately
            local extLabel = scrollFrame:addLabel({
                x = 1,
                y = currentY,
                text = extension .. ":",
                foreground = colors.white
            })

            local openHandler = BasaltOS.getFileHandler(extension, "open")
            local openLabel = scrollFrame:addLabel({
                x = 1,
                y = currentY + 1,
                text = "Open:",
                foreground = colors.lightGray
            })

            local openButton = scrollFrame:addButton({
                x = 7,
                y = currentY + 1,
                width = 12,
                height = 1,
                text = openHandler,
                background = colors.blue,
                foreground = colors.white
            })

            openButton:onClick(function()
                showAppSelectionDialog(extension, "open", function(selectedApp)
                    if selectedApp then
                        BasaltOS.setFileAssociation(extension, "open", selectedApp)
                    end
                    updateContent()
                end)
            end)

            local editHandler = BasaltOS.getFileHandler(extension, "edit")
            local editLabel = scrollFrame:addLabel({
                x = 1,
                y = currentY + 2,
                text = "Edit:",
                foreground = colors.lightGray
            })

            local editButton = scrollFrame:addButton({
                x = 7,
                y = currentY + 2,
                width = 12,
                height = 1,
                text = editHandler,
                background = colors.green,
                foreground = colors.white
            })

            editButton:onClick(function()
                showAppSelectionDialog(extension, "edit", function(selectedApp)
                    if selectedApp then
                        BasaltOS.setFileAssociation(extension, "edit", selectedApp)
                    end
                    updateContent()
                end)
            end)

            local resetButton = scrollFrame:addButton({
                x = 20,
                y = currentY + 1,
                width = 5,
                height = 1,
                text = "Reset",
                background = colors.red,
                foreground = colors.white
            })

            resetButton:onClick(function()
                BasaltOS.clearFileAssociation(extension, "open")
                BasaltOS.clearFileAssociation(extension, "edit")
                updateContent()
            end)

            currentY = currentY + 4
        end
    end

    local dirLabel = scrollFrame:addLabel({
        x = 1,
        y = currentY,
        text = "Directories:",
        foreground = colors.cyan
    })

    local dirOpenHandler = BasaltOS.getFileHandler("__directory", "open")
    local dirOpenLabel = scrollFrame:addLabel({
        x = 1,
        y = currentY + 1,
        text = "Open:",
        foreground = colors.lightGray
    })

    local dirOpenButton = scrollFrame:addButton({
        x = 7,
        y = currentY + 1,
        width = 12,
        height = 1,
        text = dirOpenHandler,
        background = colors.blue,
        foreground = colors.white
    })

    dirOpenButton:onClick(function()
        showAppSelectionDialog("__directory", "open", function(selectedApp)
            if selectedApp then
                BasaltOS.setFileAssociation("__directory", "open", selectedApp)
            end
            updateContent()
        end)
    end)

    local dirResetButton = scrollFrame:addButton({
        x = 20,
        y = currentY + 1,
        width = 5,
        height = 1,
        text = "Reset",
        background = colors.red,
        foreground = colors.white
    })

    dirResetButton:onClick(function()
        BasaltOS.clearFileAssociation("__directory", "open")
        updateContent()
    end)
end

local function createGeneralContent()
    contentFrame:clear()

    local title = contentFrame:addLabel({
        x = 2,
        y = 2,
        text = "General Settings",
        foreground = colors.yellow
    })

    local comingSoon = contentFrame:addLabel({
        x = 2,
        y = 4,
        text = "General settings will be available in a future update.",
        foreground = colors.lightGray
    })
end

local function createAboutContent()
    contentFrame:clear()
    
    local title = contentFrame:addLabel({
        x = 2,
        y = 2,
        text = "About BasaltOS Settings",
        foreground = colors.yellow
    })
    
    local info = {
        "BasaltOS Settings v1.0.0",
        "",
        "File Association System:",
        "- Configure default apps for file types",
        "- Set custom handlers for directories", 
        "- Reset to system defaults",
        "",
        "System Integration:",
        "- Changes apply immediately",
        "- User preferences override defaults",
        "- Supports all installed apps"
    }
    
    for i, line in ipairs(info) do
        contentFrame:addLabel({
            x = 2,
            y = 3 + i,
            text = line,
            foreground = line == "" and colors.black or colors.lightGray
        })
    end
end

-- Update content based on current section
function updateContent()
    if currentSection == "file_associations" then
        createFileAssociationsContent()
    elseif currentSection == "extension_mgmt" then
        createExtensionManagementContent()
    elseif currentSection == "general" then
        createGeneralContent()
    elseif currentSection == "about" then
        createAboutContent()
    end
end

-- Initialize UI
createSidebar()
updateContent()

-- Set up menu
BasaltOS.setMenu({
    ["Settings"] = {
        ["Refresh"] = function()
            updateContent()
        end,        ["Reset All"] = function()
            BasaltOS.confirmDialog("Reset All Settings", "This will reset all file associations to defaults. Continue?", function(confirmed)
                if confirmed then
                    -- Clear all user preferences
                    local allAssociations = BasaltOS.getFileAssociations()
                    for ext, _ in pairs(allAssociations.userOverrides) do
                        BasaltOS.clearFileAssociation(ext, "open")
                        BasaltOS.clearFileAssociation(ext, "edit")
                    end
                    updateContent()
                    BasaltOS.notify("All settings reset to defaults")
                end
            end)
        end
    },
    ["View"] = {
        ["File Associations"] = function()
            currentSection = "file_associations"
            updateContent()
            createSidebar()
        end,
        ["General"] = function()
            currentSection = "general"
            updateContent()
            createSidebar()
        end,
        ["About"] = function()
            currentSection = "about"
            updateContent()
            createSidebar()
        end
    }
})

basalt.run()
