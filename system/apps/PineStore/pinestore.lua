local basalt = require("basalt")
basalt.LOGGER.setEnabled(true)
basalt.LOGGER.setLogToFile(true)
local BasaltOS = require("basaltos")
local appInstaller = require("apploader")

local main = basalt.getMainFrame()
local theme = BasaltOS.getTheme()
local searchTerm = ""
local selectedCategory = "Featured"

main:setBackground(theme.primaryColor)

local updateAppGrid, refreshApps

local PINE_STORE_API = "https://pinestore.cc/api/projects"
local storeApps = {}
local filteredApps = {}
local appButtons = {}

local cachedApps = nil
local cacheTimestamp = nil
local CACHE_DURATION = 300

local lastUpdateTime = 0
local UPDATE_THROTTLE = 0.5
local pendingUpdate = false

local detailFrame = nil
local detailElements = {}
local currentSelectedApp = nil

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

local function httpGet(url)
    local allowed, reason = http.checkURL(url)
    if not allowed then
        return nil, "URL blocked: " .. (reason or "Unknown reason")
    end

    local handle, err = http.get(url, nil, nil, 5000)
    if not handle then
        return nil, "Failed to connect: " .. (err or "Connection timeout")
    end

    local response = handle.readAll()
    local responseCode = handle.getResponseCode()
    handle.close()

    if responseCode ~= 200 then
        return nil, "HTTP Error " .. responseCode
    end

    if not response or response == "" then
        return nil, "Empty response from server"
    end

    local success, data = pcall(textutils.unserializeJSON, response)
    if not success then
        return nil, "JSON Parse Error: " .. tostring(data)
    end

    return data
end

local function loadPineStoreApps()
    local currentTime = os.epoch("utc") / 1000
    if cachedApps and cacheTimestamp and (currentTime - cacheTimestamp) < CACHE_DURATION then
        return cachedApps, nil
    end

    if not http then
        local errorMsg = "HTTP is disabled. Enable it in ComputerCraft config:\n- Set http_enable=true\n- Restart ComputerCraft"
        return {}, errorMsg
    end

    local data, error = httpGet(PINE_STORE_API)
    if not data then
        if cachedApps then
            return cachedApps, nil
        end
        return {}, error
    end

    if not data.success then
        if cachedApps then
            return cachedApps, nil
        end
        return {}, "Pine Store API returned success=false"
    end

    if not data.projects then
        if cachedApps then
            return cachedApps, nil
        end
        return {}, "No projects field in response"
    end

    local apps = {}
    local processedCount = 0

    for i, projectWrapper in ipairs(data.projects) do
        if type(projectWrapper) == "table" and projectWrapper.name then
            local project = projectWrapper

            if project.name and project.name ~= "" then
                local category = "Utilities"
                local featured = false

                if project.tags and type(project.tags) == "table" then
                    for _, tag in ipairs(project.tags) do
                        if type(tag) == "string" then
                            local lowerTag = string.lower(tag)
                            if lowerTag == "game" or lowerTag == "games" or lowerTag == "fun" or lowerTag == "action" then
                                category = "Games"
                                break
                            end
                        end
                    end
                end

                local downloads = tonumber(project.downloads) or 0
                local likes = tonumber(project.likes) or 0
                if downloads > 0 or likes >= 0 then
                    featured = true
                end

                local app = {
                    manifest = {
                        name = project.name,
                        description = project.description_short or project.description or "No description available",
                        version = "1.0.0",
                        author = project.owner_name or "Unknown",
                        category = category,
                        downloads = downloads,
                        rating = math.min(5, math.max(1, likes / 2 + 3))
                    },
                    featured = featured,
                    pineStore = {
                        id = project.id,
                        install_command = project.install_command or "echo 'No install command'",
                        repository = project.repository
                    }
                }

                table.insert(apps, app)
                processedCount = processedCount + 1
            end
        elseif projectWrapper and projectWrapper.success and projectWrapper.project then
            local project = projectWrapper.project

            if project.name and project.name ~= "" then
                local category = "Utilities"
                local featured = true

                if project.tags and type(project.tags) == "table" then
                    for _, tag in ipairs(project.tags) do
                        if type(tag) == "string" then
                            local lowerTag = string.lower(tag)
                            if lowerTag == "game" or lowerTag == "games" or lowerTag == "fun" or lowerTag == "action" then
                                category = "Games"
                                break
                            end
                        end
                    end
                end

                local downloads = tonumber(project.downloads) or 0
                local likes = tonumber(project.likes) or 0

                local app = {
                    manifest = {
                        name = project.name,
                        description = project.description_short or project.description or "No description available",
                        version = "1.0.0",
                        author = project.owner_name or "Unknown",
                        category = category,
                        downloads = downloads,
                        rating = math.min(5, math.max(1, likes / 2 + 3))
                    },
                    featured = featured,
                    pineStore = {
                        id = project.id,
                        install_command = project.install_command or "echo 'No install command'",
                        repository = project.repository
                    }
                }

                table.insert(apps, app)
                processedCount = processedCount + 1
            end
        end
    end

    cachedApps = apps
    cacheTimestamp = currentTime

    return apps, nil
end

BasaltOS.setMenu({
    ["File"] = {
        ["Refresh Store"] = function()
            refreshApps()
        end,
        ["Force Refresh"] = function()
            cachedApps = nil
            cacheTimestamp = nil
            refreshApps()
        end,
        ["Exit"] = function()
            main:destroy()
        end
    },
    ["View"] = {
        ["Show Featured"] = function()
            selectedCategory = "Featured"
            updateAppGrid()
        end,
        ["Show Games"] = function()
            selectedCategory = "Games"
            updateAppGrid()
        end,
        ["Show Utilities"] = function()
            selectedCategory = "Utilities"
            updateAppGrid()
        end,
        ["Cache Info"] = function()
            local currentTime = os.epoch("utc") / 1000
            if cachedApps and cacheTimestamp then
                local age = math.floor(currentTime - cacheTimestamp)
                local remaining = math.max(0, CACHE_DURATION - age)
                print("Cache: " .. #cachedApps .. " apps, age: " .. age .. "s, expires in: " .. remaining .. "s")
            else
                print("No cache data")
            end
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

local featuredButton = topbar:addButton({
    text = "Featured",
    width = 9,
    height = 1,
    x = 2,
    foreground = colors.white,
    background = colors.gray,
})

local gamesButton = topbar:addButton({
    text = "Games",
    width = 7,
    height = 1,
    x = 12,
    foreground = colors.black,
    background = colors.gray,
})

local utilitiesButton = topbar:addButton({
    text = "Utils",
    width = 6,
    height = 1,
    x = 20,
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

local scrollbar = main:addScrollbar({
    x = "{parent.width}",
    y = 3,
    width = 1,
    height = "{parent.height - 3}",
    background = colors.gray,
    foreground = colors.lightGray
})

local function updateCategoryButtons()
    featuredButton:setBackground(selectedCategory == "Featured" and colors.black or colors.gray)
    featuredButton:setForeground(selectedCategory == "Featured" and colors.white or colors.lightGray)

    gamesButton:setBackground(selectedCategory == "Games" and colors.black or colors.gray)
    gamesButton:setForeground(selectedCategory == "Games" and colors.white or colors.lightGray)

    utilitiesButton:setBackground(selectedCategory == "Utilities" and colors.black or colors.gray)
    utilitiesButton:setForeground(selectedCategory == "Utilities" and colors.white or colors.lightGray)
end

local function filterApps()
    filteredApps = {}
    local lowerSearch = string.lower(searchTerm)

    for _, app in ipairs(storeApps) do
        local matchesCategory = false

        if selectedCategory == "Featured" then
            matchesCategory = app.featured
        elseif selectedCategory == "Games" then
            matchesCategory = app.manifest.category == "Games"
        elseif selectedCategory == "Utilities" then
            matchesCategory = app.manifest.category == "Utilities"
        end

        local matchesSearch = searchTerm == "" or string.find(string.lower(app.manifest.name), lowerSearch)

        if matchesCategory and matchesSearch then
            table.insert(filteredApps, app)
        end
    end

    table.sort(filteredApps, function(a, b)
        return a.manifest.downloads > b.manifest.downloads    end)
end

local function createDetailFrame()
    if detailFrame then return end

    detailFrame = main:addFrame({
        x = 1,
        y = 1,
        z = 50,
        width = "{parent.width}",
        height = "{parent.height}",
        background = colors.black,
        visible = false
    })
    detailFrame:onClick(function() end)
    scrollableFrame(detailFrame)

    detailElements.backBtn = detailFrame:addButton({
        x = 2,
        y = 2,
        width = 8,
        height = 1,
        text = "< Back",
        background = colors.gray,
        foreground = colors.white
    })

    detailElements.installBtn = detailFrame:addButton({
        x = "{parent.width - 12}",
        y = 2,
        width = 10,
        height = 1,
        text = "Install",
        background = colors.green,
        foreground = colors.white
    })    detailElements.titleLabel = detailFrame:addLabel({
        x = 2,
        y = 4,
        text = "",
        foreground = colors.white,
        fontSize = 2
    })

    detailElements.authorLabel = detailFrame:addLabel({
        x = 2,
        y = 6,
        text = "",
        foreground = colors.lightGray
    })

    detailElements.versionLabel = detailFrame:addLabel({
        x = 2,
        y = 7,
        text = "",
        foreground = colors.lightGray
    })

    detailElements.statsHeader = detailFrame:addLabel({
        x = 2,
        y = 9,
        text = "Statistics:",
        foreground = colors.yellow
    })    detailElements.downloadsLabel = detailFrame:addLabel({
        x = 4,
        y = 10,
        text = "",
        foreground = colors.white
    })

    detailElements.ratingLabel = detailFrame:addLabel({
        x = 4,
        y = 11,
        text = "",
        foreground = colors.yellow
    })

    detailElements.descHeader = detailFrame:addLabel({
        x = 2,
        y = 13,
        text = "Description:",
        foreground = colors.yellow
    })    
    detailElements.descLines = {}

    detailElements.descLabel = detailFrame:addLabel({
        x = 4,
        y = 14,
        width = "{parent.width - 6}",
        height = 8,
        text = "",
        foreground = colors.white
    })
    detailElements.descLabel:setAutoSize(false)
    detailElements.repoLabel = detailFrame:addLabel({
        x = 2,
        y = 23,
        width = "{parent.width - 4}",
        text = "",
        foreground = colors.cyan
    })
    detailElements.repoLabel:setAutoSize(false)detailElements.backBtn:onClick(function()
        detailFrame:setVisible(false)
    end)    detailElements.installBtn:onClick(function()
        if currentSelectedApp and currentSelectedApp.pineStore and currentSelectedApp.pineStore.install_command then
            appInstaller.install(main, currentSelectedApp)
        end
    end)
end

local function updateDetailFrame(app)
    if not detailFrame then createDetailFrame() end
    currentSelectedApp = app

    detailElements.titleLabel:setText(app.manifest.name)
    detailElements.authorLabel:setText("by " .. app.manifest.author)
    detailElements.versionLabel:setText("Version: " .. app.manifest.version .. " | Category: " .. app.manifest.category)
    detailElements.downloadsLabel:setText("Downloads: " .. app.manifest.downloads)

    local stars = math.floor(app.manifest.rating)
    local starText = string.rep("*", stars) .. string.rep("-", 5 - stars)
    detailElements.ratingLabel:setText("Rating: " .. starText .. " (" .. app.manifest.rating .. "/5)")    

    detailElements.descLabel:setText(app.manifest.description)
    detailElements.descLabel:setWidth("{parent.width - 4}")

    if app.pineStore and app.pineStore.repository then
        detailElements.repoLabel:setText("Repository: " .. app.pineStore.repository)
        detailElements.repoLabel:setVisible(true)
        detailElements.repoLabel:setY(detailElements.descLabel.y + detailElements.descLabel.height + 1)
    else
        detailElements.repoLabel:setVisible(false)
    end

    detailFrame:setVisible(true)
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
        local y = (row - 1) * 7 + 1

        local appFrame = gridFrame:addFrame({
            x = x,
            y = y,
            width = appCardWidth,
            height = 6,
            background = colors.black
        })

        local iconElement = appFrame:addLabel({
            x = 5,
            y = 1,
            text = "[" .. string.upper(string.sub(app.manifest.category, 1, 1)) .. "]",
            foreground = app.manifest.category == "Games" and colors.red or colors.cyan
        })

        local stars = math.floor(app.manifest.rating)
        local starText = string.rep("*", stars)
        local ratingLabel = appFrame:addLabel({
            x = 2,
            y = 2,
            text = starText,
            foreground = colors.yellow
        })

        local dlText = tostring(app.manifest.downloads)
        if app.manifest.downloads >= 1000 then
            dlText = string.format("%.1fk", app.manifest.downloads / 1000)
        end
        local downloadLabel = appFrame:addLabel({
            x = appCardWidth - #dlText,
            y = 2,
            text = dlText,
            foreground = colors.lightGray
        })

        local labelBg = appFrame:addVisualElement({
            x = 1,
            y = 6,
            width = appCardWidth,
            height = 1,
            background = colors.lightGray
        })

        local name = string.sub(app.manifest.name, 1, 9)
        local nameLabel = appFrame:addLabel({
            x = math.floor(appCardWidth / 2 - #name / 2 + 0.5),
            y = 6,
            text = name,
            foreground = colors.black
        })

        appFrame:onClick(function()
            updateDetailFrame(app)
        end)

        table.insert(appButtons, {
            frame = appFrame,
            app = app
        })
    end

    local maxScroll = math.max(0, rows * 7 - gridFrame.height + 1)
    scrollbar:setMax(maxScroll)
end

local function updateAppGrid()
    local currentTime = os.epoch("utc") / 1000

    if currentTime - lastUpdateTime < UPDATE_THROTTLE then
        if not pendingUpdate then
            pendingUpdate = true
            os.startTimer(UPDATE_THROTTLE)
        end
        return
    end

    pendingUpdate = false
    lastUpdateTime = currentTime

    updateCategoryButtons()
    filterApps()
    createAppGrid()

    if #filteredApps == 0 then
        local messageFrame = gridFrame:addFrame({
            x = 10,
            y = 5,
            width = 30,
            height = 6,
            background = colors.gray
        })

        if #storeApps == 0 then
            messageFrame:addLabel({
                x = 8,
                y = 2,
                text = "No apps loaded",
                foreground = colors.white
            })

            messageFrame:addLabel({
                x = 5,
                y = 4,
                text = "Press F5 to refresh",
                foreground = colors.lightGray
            })
        else
            messageFrame:addLabel({
                x = 5,
                y = 2,
                text = "No " .. string.lower(selectedCategory) .. " apps",
                foreground = colors.white
            })

            messageFrame:addLabel({
                x = 3,
                y = 4,
                text = "Try different category",
                foreground = colors.lightGray
            })

            if searchTerm ~= "" then
                messageFrame:addLabel({
                    x = 7,
                    y = 5,
                    text = "or clear search",
                    foreground = colors.lightGray
                })
            end
        end
    end
end

local function refreshApps()
    storeApps = {}
    filteredApps = {}

    for _, button in ipairs(appButtons) do
        if button.frame then
            button.frame:destroy()
        end
    end
    appButtons = {}

    local currentTime = os.epoch("utc") / 1000
    if cachedApps and cacheTimestamp and (currentTime - cacheTimestamp) < CACHE_DURATION then
        storeApps = cachedApps
        updateAppGrid()
        return
    end

    local loadingFrame = main:addFrame({
        x = 10,
        y = 5, 
        width = 35,
        height = 7,
        background = colors.black,
        border = colors.white
    })

    loadingFrame:addLabel({
        x = 8,
        y = 2,
        text = "Loading Pine Store...",
        foreground = colors.white
    })

    loadingFrame:addLabel({
        x = 10,
        y = 3,
        text = "Please wait...",
        foreground = colors.lightGray
    })

    if cachedApps then
        loadingFrame:addLabel({
            x = 5,
            y = 4,
            text = "Refreshing cache...",
            foreground = colors.yellow
        })
    end

    local apps, error = loadPineStoreApps()
    storeApps = apps

    if loadingFrame then
        loadingFrame:destroy()
    end

    if error then
        local errorFrame = main:addFrame({
            x = 5,
            y = 3,
            width = 40,
            height = 8,
            background = colors.red,
            border = colors.white
        })

        errorFrame:addLabel({
            x = 2,
            y = 2,
            text = "Pine Store Connection Failed",
            foreground = colors.white
        })

        local errorLines = {}
        local maxWidth = 36
        local currentLine = ""
        for word in error:gmatch("%S+") do
            if #currentLine + #word + 1 <= maxWidth then
                currentLine = currentLine .. (currentLine == "" and "" or " ") .. word
            else
                table.insert(errorLines, currentLine)
                currentLine = word
            end
        end
        if currentLine ~= "" then
            table.insert(errorLines, currentLine)
        end

        for i, line in ipairs(errorLines) do
            if i <= 3 then
                errorFrame:addLabel({
                    x = 2,
                    y = 2 + i,
                    text = line,
                    foreground = colors.white
                })
            end
        end

        local retryBtn = errorFrame:addButton({
            x = 8,
            y = 6,
            width = 8,
            height = 1,
            text = "Retry",
            background = colors.green,
            foreground = colors.white
        })

        local closeBtn = errorFrame:addButton({
            x = 24,
            y = 6,
            width = 8,
            height = 1,
            text = "Close",
            background = colors.gray,
            foreground = colors.white
        })

        retryBtn:onClick(function()
            errorFrame:destroy()
            refreshApps()
        end)

        closeBtn:onClick(function()
            main:destroy()
        end)

        return
    end

    updateAppGrid()
end

local eventDispatch = main.dispatchEvent
function main:dipatchEvent(event, ...)
    eventDispatch(self, event, ...)
    if event == "timer" then
        local timerId = ({...})[2]
        if timerId and pendingUpdate then
            pendingUpdate = false
            lastUpdateTime = os.epoch("utc") / 1000
            updateAppGrid()
        end
    end
end

scrollableFrame(gridFrame)

local function initialize()
    createDetailFrame()
    local success, error = pcall(refreshApps)
    if not success then
        local errorFrame = main:addFrame({
            x = 10,
            y = 5,
            width = 40,
            height = 10,
            background = colors.red,
            foreground = colors.white
        })

        errorFrame:addLabel({
            x = 2,
            y = 2,
            text = "Error loading Pine Store:",
            foreground = colors.white
        })

        errorFrame:addLabel({
            x = 2,
            y = 4,
            text = tostring(error),
            foreground = colors.white
        })

        errorFrame:addButton({
            x = 15,
            y = 7,
            width = 10,
            height = 1,
            text = "Close",
            background = colors.gray,
            foreground = colors.white,
            onClick = function()
                main:destroy()
            end
        })
    end
end

main:observe("width", function()
    updateAppGrid()
end)

main:observe("height", function()
    updateAppGrid()
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

initialize()
basalt.run()