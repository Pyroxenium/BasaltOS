local basalt = require("basalt")
basalt.LOGGER.setEnabled(true)
basalt.LOGGER.setLogToFile(true)
local BasaltOS = require("basaltos")
local path = require("path")

local args = {...}
local initialPath = args[1]

local main = basalt.getMainFrame()
local theme = BasaltOS.getTheme()

main:setBackground(theme.primaryColor)

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
scrollableFrame(main)

local appData = {
    name = "",
    executable = initialPath or "",
    version = "1.0.0",
    author = "",
    description = "",
    icon = "{assets}/icons/default.bimg",
    window = {
        width = 30,
        height = 15,
        min_width = 20,
        min_height = 10,
        resizable = true,
        title = ""
    }
}

local elements = {}

local function createUI()
    elements.subtitleLabel = main:addLabel({
        x = 2,
        y = 2,
        text = "Convert .lua files to BasaltOS apps",
        foreground = colors.lightGray
    })
    elements.nameLabel = main:addLabel({
        x = 2,
        y = 6,
        text = "Name:",
        foreground = colors.white
    })
    elements.nameInput = main:addInput({
        x = 8,
        y = 6,
        width = "{parent.width - 9}",
        height = 1,
        background = colors.black,
        foreground = colors.white,
        placeholder = "Enter app name..."
    })

    elements.execLabel = main:addLabel({
        x = 2,
        y = 8,
        text = "Exec:",
        foreground = colors.white
    })

    elements.execInput = main:addInput({
        x = 7,
        y = 8,
        width = "{parent.width - 16}",
        height = 1,
        background = colors.black,
        foreground = colors.white,
        placeholder = "Path to .lua file..."
    })

    elements.browseBtn = main:addButton({
        x = "{parent.width - 8}",
        y = 8,
        width = 7,
        height = 1,
        text = "Browse",
        background = colors.blue,
        foreground = colors.white
    })
    elements.versionLabel = main:addLabel({
        x = 2,
        y = 10,
        text = "Ver:",
        foreground = colors.white
    })
    elements.versionInput = main:addInput({
        x = 6,
        y = 10,
        width = "{parent.width - 7}",
        height = 1,
        background = colors.black,
        foreground = colors.white,
        text = "1.0.0"
    })

    elements.authorLabel = main:addLabel({
        x = 2,
        y = 12,
        text = "Author:",
        foreground = colors.white
    })

    elements.authorInput = main:addInput({
        x = 9,
        y = 12,
        width = "{parent.width - 10}",
        height = 1,
        background = colors.black,
        foreground = colors.white,
        placeholder = "Your name..."
    })

    elements.descLabel = main:addLabel({
        x = 2,
        y = 14,
        text = "Desc:",
        foreground = colors.white
    })

    elements.descInput = main:addInput({
        x = 2,
        y = 15,
        width = "{parent.width - 3}",
        height = 1,
        background = colors.black,
        foreground = colors.white,
        placeholder = "Brief description..."
    })

    elements.windowLabel = main:addLabel({
        x = 2,
        y = 17,
        text = "Window Settings:",
        foreground = colors.yellow
    })
    elements.widthLabel = main:addLabel({
        x = 2,
        y = 19,
        text = "W:",
        foreground = colors.white
    })
    elements.widthInput = main:addInput({
        x = 4,
        y = 19,
        width = 4,
        height = 1,
        background = colors.black,
        foreground = colors.white,
        text = "30"
    })

    elements.heightLabel = main:addLabel({
        x = 9,
        y = 19,
        text = "H:",
        foreground = colors.white
    })

    elements.heightInput = main:addInput({
        x = 12,
        y = 19,
        width = 4,
        height = 1,
        background = colors.black,
        foreground = colors.white,
        text = "15"
    })
    elements.minWidthLabel = main:addLabel({
        x = 2,
        y = 21,
        text = "MinW:",
        foreground = colors.white
    })

    elements.minWidthInput = main:addInput({
        x = 7,
        y = 21,
        width = 4,
        height = 1,
        background = colors.black,
        foreground = colors.white,
        text = "20"
    })

    elements.minHeightLabel = main:addLabel({
        x = 12,
        y = 21,
        text = "MinH:",
        foreground = colors.white
    })

    elements.minHeightInput = main:addInput({
        x = 17,
        y = 21,
        width = 4,
        height = 1,
        background = colors.black,
        foreground = colors.white,
        text = "10"
    })

    elements.resizableCheckbox = main:addCheckbox({
        x = 2,
        y = 23,
        foreground = colors.white,
        checked = true
    })
    elements.resizableCheckbox:setText("Static")
    elements.resizableCheckbox:setCheckedText("Resizable")

    elements.fullscreenCheckbox = main:addCheckbox({
        x = 12,
        y = 23,
        foreground = colors.white,
        checked = false
    })
    elements.fullscreenCheckbox:setText("Windowed")
    elements.fullscreenCheckbox:setCheckedText("Fullscreen")

    elements.fileAssocLabel = main:addLabel({
        x = 2,
        y = 25,
        text = "File Associations:",
        foreground = colors.yellow
    })

    elements.openExtLabel = main:addLabel({
        x = 2,
        y = 27,
        text = "Open:",
        foreground = colors.white
    })

    elements.openExtInput = main:addInput({
        x = 7,
        y = 27,
        width = "{parent.width - 8}",
        height = 1,
        background = colors.black,
        foreground = colors.white,
        placeholder = ".lua,.txt (comma separated)"
    })

    elements.editExtLabel = main:addLabel({
        x = 2,
        y = 29,
        text = "Edit:",
        foreground = colors.white
    })

    elements.editExtInput = main:addInput({
        x = 7,
        y = 29,
        width = "{parent.width - 8}",
        height = 1,
        background = colors.black,
        foreground = colors.white,
        placeholder = ".lua,.txt,.json (comma separated)"
    })

    elements.requiresFileCheckbox = main:addCheckbox({
        x = 2,
        y = 31,
        foreground = colors.white,
        checked = false
    })
    elements.requiresFileCheckbox:setText("Requires File Path")
    elements.requiresFileCheckbox:setCheckedText("Requires File Path")

    elements.handlesDirectoriesCheckbox = main:addCheckbox({
        x = 2,
        y = 32,
        foreground = colors.white,
        checked = false
    })
    elements.handlesDirectoriesCheckbox:setText("Can Handle Directories")
    elements.handlesDirectoriesCheckbox:setCheckedText("Can Handle Directories")

    elements.installBtn = main:addButton({
        x = 2,
        y = 34,
        width = 8,
        height = 1,
        text = "Install",
        background = colors.green,
        foreground = colors.white
    })

    elements.cancelBtn = main:addButton({
        x = 11,
        y = 34,
        width = 6,
        height = 1,
        text = "Cancel",
        background = colors.red,
        foreground = colors.white
    })
end

local function setInitialPath()
    if initialPath then
        elements.execInput:setText(initialPath)

        local fileName = fs.getName(initialPath)
        if fileName:match("%.lua$") then
            local guessedName = fileName:gsub("%.lua$", "")
            guessedName = guessedName:sub(1,1):upper() .. guessedName:sub(2)
            elements.nameInput:setText(guessedName)
            appData.window.title = guessedName
        end
    end
end

local function browseForFile()
    BasaltOS.fileDialog("Select Lua File", "*.lua", function(selectedPath)
        if selectedPath then
            elements.execInput:setText(selectedPath)

            if elements.nameInput:getText() == "" then
                local fileName = fs.getName(selectedPath)
                if fileName:match("%.lua$") then
                    local guessedName = fileName:gsub("%.lua$", "")
                    guessedName = guessedName:sub(1,1):upper() .. guessedName:sub(2)
                    elements.nameInput:setText(guessedName)
                end
            end
        end
    end)
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

local function validateInput()
    local errors = {}

    if trim(elements.nameInput:getText()) == "" then
        table.insert(errors, "App name is required")
    end

    if trim(elements.execInput:getText()) == "" then
        table.insert(errors, "Executable path is required")
    elseif not fs.exists(elements.execInput:getText()) then
        table.insert(errors, "Executable file does not exist")
    elseif not elements.execInput:getText():match("%.lua$") then
        table.insert(errors, "Executable must be a .lua file")
    end

    if trim(elements.authorInput:getText()) == "" then
        table.insert(errors, "Author is required")
    end

    local width = tonumber(elements.widthInput:getText())
    local height = tonumber(elements.heightInput:getText())
    local minWidth = tonumber(elements.minWidthInput:getText())
    local minHeight = tonumber(elements.minHeightInput:getText())

    if not width or width < 10 then
        table.insert(errors, "Width must be at least 10")
    end

    if not height or height < 5 then
        table.insert(errors, "Height must be at least 5")
    end

    if not minWidth or minWidth < 5 then
        table.insert(errors, "Min width must be at least 5")
    end

    if not minHeight or minHeight < 3 then
        table.insert(errors, "Min height must be at least 3")
    end

    if width and minWidth and minWidth > width then
        table.insert(errors, "Min width cannot be greater than width")
    end

    if height and minHeight and minHeight > height then
        table.insert(errors, "Min height cannot be greater than height")
    end

    return errors
end

local function parseExtensions(extensionString)
    if not extensionString or extensionString == "" then
        return {}
    end
    
    local extensions = {}
    for ext in extensionString:gmatch("[^,]+") do
        ext = ext:match("^%s*(.-)%s*$") -- trim whitespace
        if ext:sub(1,1) ~= "." then
            ext = "." .. ext
        end
        table.insert(extensions, ext:lower())
    end
    return extensions
end

local function generateManifest()
    local manifest = {
        name = trim(elements.nameInput:getText()),
        version = trim(elements.versionInput:getText()),
        author = trim(elements.authorInput:getText()),
        description = trim(elements.descInput:getText()),
        executable = trim(elements.execInput:getText()),
        icon = "{assets}/icons/default.bimg",
        window = {
            width = tonumber(elements.widthInput:getText()),
            height = tonumber(elements.heightInput:getText()),
            min_width = tonumber(elements.minWidthInput:getText()),
            min_height = tonumber(elements.minHeightInput:getText()),
            resizable = elements.resizableCheckbox:getChecked(),
            fullscreen = elements.fullscreenCheckbox:getChecked(),
            title = trim(elements.nameInput:getText())
        }
    }

    if elements.requiresFileCheckbox:getChecked() then
        manifest.requiresFile = true
    end

    local openExts = parseExtensions(elements.openExtInput:getText())
    local editExts = parseExtensions(elements.editExtInput:getText())
    local handlesDirectories = elements.handlesDirectoriesCheckbox:getChecked()

    if #openExts > 0 or #editExts > 0 or handlesDirectories then
        manifest.fileAssociations = {}
        if #openExts > 0 then
            manifest.fileAssociations.open = openExts
        end
        if #editExts > 0 then
            manifest.fileAssociations.edit = editExts
        end

        if handlesDirectories then
            if not manifest.fileAssociations.open then
                manifest.fileAssociations.open = {}
            end
            if not manifest.fileAssociations.edit then
                manifest.fileAssociations.edit = {}
            end
            table.insert(manifest.fileAssociations.open, "__directory")
            table.insert(manifest.fileAssociations.edit, "__directory")
        end
    end

    return manifest
end

local function installApp()
    local errors = validateInput()

    if #errors > 0 then
        BasaltOS.errorDialog("Validation Error:\n" .. table.concat(errors, "\n"))
        return
    end

    local manifest = generateManifest()
    local appName = manifest.name

    local appDir = path.resolve("programs/" .. appName)

    if fs.exists(appDir) then
        BasaltOS.confirmDialog(
            "App Exists",
            "An app with this name already exists. Overwrite?",
            function(confirmed)
                if confirmed then
                    fs.delete(appDir)
                    installApp()
                end
            end
        )
        return
    end

    fs.makeDir(appDir)

    local execPath = manifest.executable
    local targetExec = appDir .. "/" .. appName:lower() .. ".lua"

    if fs.exists(execPath) then
        fs.copy(execPath, targetExec)
        manifest.executable = targetExec
    end

    local manifestPath = appDir .. "/" .. appName:lower() .. ".json"
    local manifestFile = fs.open(manifestPath, "w")
    manifestFile.write(textutils.serializeJSON(manifest))
    manifestFile.close()

    if manifest.fileAssociations then
        local extensionsToInstall = {}

        if manifest.fileAssociations.open then
            for _, ext in ipairs(manifest.fileAssociations.open) do
                if ext ~= "__directory" then
                    table.insert(extensionsToInstall, {
                        extension = ext,
                        canOpen = true,
                        canEdit = false
                    })
                end
            end
        end

        if manifest.fileAssociations.edit then
            for _, ext in ipairs(manifest.fileAssociations.edit) do
                if ext ~= "__directory" then
                    local found = false
                    for _, existing in ipairs(extensionsToInstall) do
                        if existing.extension == ext then
                            existing.canEdit = true
                            found = true
                            break
                        end
                    end
                    if not found then
                        table.insert(extensionsToInstall, {
                            extension = ext,
                            canOpen = false,
                            canEdit = true
                        })
                    end
                end
            end
        end

        if #extensionsToInstall > 0 then
            local installed = BasaltOS.installFileExtensions(extensionsToInstall, appName)
            if installed then
                BasaltOS.showNotification("Extensions", "File extensions installed for " .. appName, 2)
            end
        end
    end

    BasaltOS.showNotification("Success", "App '" .. appName .. "' installed successfully!", 3)
    BasaltOS.registerApp(manifestPath)
    BasaltOS.confirmDialog(
        "Launch App",
        "Would you like to launch the newly installed app?",
        function(confirmed)
            if confirmed then
                BasaltOS.openApp(appName)
            end
        end
    )
end

local function setupEvents()
    elements.browseBtn:onClick(browseForFile)
    elements.installBtn:onClick(installApp)
    elements.cancelBtn:onClick(function() basalt.stop() end)

    elements.nameInput:onChange(function(self)
        appData.window.title = self:getText()
    end)
end

local function init()
    createUI()
    setInitialPath()
    setupEvents()
end

init()
basalt.run()
