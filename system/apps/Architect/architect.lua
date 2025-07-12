local basalt = require("basalt")
basalt.LOGGER.setEnabled(true)
basalt.LOGGER.setLogToFile(true)

local canvasX, canvasY
local canvasElements = {}

local main = basalt.getMainFrame()

local elementManager = basalt.getElementManager()
local elementList = elementManager.getElementList()

local canvasArea = main:addFrame({
    x = 1,
    y = 2,
    width = "{parent.width - 14}",
    height = "{parent.height - 1}",
    background = colors.black,
})
local drawCanvas = canvasArea:getCanvas()
drawCanvas:addCommand(function()
    local width, height = canvasArea.get("width"), canvasArea.get("height")
    canvasArea:multiBlit(1, 1, width, height,"\127", "7", "f")
end)

local canvas = canvasArea:addFrame({
    x = 5,
    y = 3,
    width = 51,
    height = 19,
    background = colors.white,
})

local menubar = main:addFrame({
    x = 1,
    y = 1,
    width = "{parent.width}",
    height = 1,
    background = colors.cyan,
})

local sidePanel = main:addFrame({
    x = "{parent.width - 13}",
    y = 2,
    width = 14,
    height = "{parent.height - 1}",
    background = colors.cyan,
})

local propertiesArea = main:addFrame({
    x = "{parent.width - 13}",
    y = "{parent.height - 10}",
    width = 14,
    height = 10,
    background = colors.lightGray,
    visible = false,
})

local pressedKeys = {}
local contextMenu = nil
local selectedElement = nil

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

local function deleteElement(element)
    if element == selectedElement then
        selectedElement = nil
    end

    for i, el in ipairs(canvasElements) do
        if el == element then
            table.remove(canvasElements, i)
            break
        end
    end
    element:destroy()
end

local function showContextMenu(element, x, y)
    if contextMenu then
        contextMenu:destroy()
    end

    local properties = element._properties or {}
    local propertyCount = 0
    for _ in pairs(properties) do
        propertyCount = propertyCount + 1
    end

    local windowHeight = math.min(math.max(9, 7 + propertyCount), main.get("height") - 2)
    local windowWidth = 30

    contextMenu = main:addFrame({
        x = math.max(1, math.min(x, main.get("width") - windowWidth)),
        y = math.max(1, math.min(y, main.get("height") - windowHeight)),
        width = windowWidth,
        height = windowHeight,
        background = colors.lightGray,
        border = colors.gray,
    })

    local titleBar = contextMenu:addFrame({
        x = 1,
        y = 1,
        width = windowWidth,
        height = 1,
        background = colors.gray,
    })

    titleBar:addLabel({
        x = 2,
        y = 1,
        text = "Properties - " .. element:getType(),
        foreground = colors.white,
        background = colors.gray,
    })

    local closeBtn = titleBar:addButton({
        x = windowWidth - 1,
        y = 1,
        width = 2,
        height = 1,
        text = "X",
        background = colors.red,
        foreground = colors.white,
    })

    closeBtn:onClick(function()
        contextMenu:destroy()
        contextMenu = nil
    end)
    local contentArea = contextMenu:addFrame({
        x = 2,
        y = 3,
        width = windowWidth - 2,
        height = windowHeight - 4,
        background = colors.white,
    })

    scrollableFrame(contentArea)

    contentArea:addLabel({
        x = 1,
        y = 1,
        text = "Type: " .. element:getType(),
        foreground = colors.black,
        background = colors.white,
    })

    local currentY = 3
    local propertyInputs = {}

    local function valueToString(value)
        if type(value) == "boolean" then
            return value and "true" or "false"
        elseif value == nil then
            return ""
        else
            return tostring(value)
        end
    end

    local function stringToValue(str, propType, defaultValue, propName)
        if propType == "number" then
            local num = tonumber(str)
            return num or (type(defaultValue) == "number" and defaultValue or 0)
        elseif propType == "boolean" then
            local lower = str:lower()
            return lower == "true" or lower == "1" or lower == "yes"
        elseif propType == "string" then
            return str
        elseif propType == "color" then
            local colorCode = colors[str:lower()]
            if colorCode then
                return colorCode
            elseif tonumber(str) then
                return tonumber(str)
            else
                return str
            end
        else
            local currentValue = element.get(propName)
            if type(currentValue) == "number" then
                return tonumber(str) or currentValue
            elseif type(currentValue) == "boolean" then
                local lower = str:lower()
                return lower == "true" or lower == "1" or lower == "yes"
            else
                return str
            end
        end
    end

    local sortedProps = {}
    local commonProps = {"x", "y", "width", "height", "text", "background", "foreground", "visible"}

    for _, propName in ipairs(commonProps) do
        if properties[propName] then
            table.insert(sortedProps, propName)
        end
    end

    for propName, _ in pairs(properties) do
        local isCommon = false
        for _, common in ipairs(commonProps) do
            if propName == common then
                isCommon = true
                break
            end
        end
        if not isCommon then
            table.insert(sortedProps, propName)
        end
    end

    for _, propName in ipairs(sortedProps) do
        local propData = properties[propName]
        local propType = propData.type or "string"
        local defaultValue = propData.default
        local currentValue = element.get(propName)
        if not propName:match("^_") and propName ~= "type" and propName ~= "id" and propType ~= "table" then
            local labelText = propName .. ":"
            if string.len(labelText) > 12 then
                labelText = string.sub(labelText, 1, 12) .. "..."
            end

            contentArea:addLabel({
                x = 1,
                y = currentY,
                text = labelText,
                foreground = colors.gray,
                background = colors.white,
            })

            local input
            if propType == "boolean" then
                input = contentArea:addButton({
                    x = 14,
                    y = currentY,
                    width = 8,
                    height = 1,
                    text = valueToString(currentValue),
                    background = currentValue and colors.green or colors.red,
                    foreground = colors.white,
                })

                input:onClick(function()
                    local current = input.get("text") == "true"
                    local newValue = not current
                    input.set("text", valueToString(newValue))
                    input.set("background", newValue and colors.green or colors.red)
                end)
            else
                input = contentArea:addInput({
                    x = 14,
                    y = currentY,
                    width = 12,
                    height = 1,
                    text = valueToString(currentValue),
                    background = colors.lightGray,
                    foreground = colors.black,
                })
            end

            propertyInputs[propName] = {
                input = input,
                type = propType,
                default = defaultValue
            }
              currentY = currentY + 1

        end
    end

    local applyBtn = contentArea:addButton({
        x = 1,
        y = currentY + 1,
        width = 8,
        height = 1,
        text = "Apply",
        background = colors.green,
        foreground = colors.white,
    })

    applyBtn:onClick(function()
        for propName, inputData in pairs(propertyInputs) do
            local input = inputData.input
            local propType = inputData.type
            local defaultValue = inputData.default

            local inputText = input.get("text")
            local newValue = stringToValue(inputText, propType, defaultValue, propName)

            local success, err = pcall(function()
                element.set(propName, newValue)
            end)

            if not success then
                basalt.LOGGER.warn("Failed to set property " .. propName .. ": " .. tostring(err))
            end
        end

        contextMenu:destroy()
        contextMenu = nil
    end)

    local deleteBtn = contentArea:addButton({
        x = 1,
        y = currentY + 3,
        width = 8,
        height = 1,
        text = "Delete",
        background = colors.red,
        foreground = colors.white,
    })

    deleteBtn:onClick(function()
        deleteElement(element)
        contextMenu:destroy()
        contextMenu = nil
    end)

    local copyBtn = contentArea:addButton({
        x = 10,
        y = currentY + 3,
        width = 8,
        height = 1,
        text = "Copy",
        background = colors.blue,
        foreground = colors.white,
    })

    copyBtn:onClick(function()
        -- TODO: Implement copy functionality
        contextMenu:destroy()
        contextMenu = nil
    end)
end

local function selectElement(element)
    if selectedElement then
        selectedElement.set("background", selectedElement.__originalBg or colors.white)
    end

    selectedElement = element
    if element then
        element.__originalBg = element.get("background")
        element.set("background", colors.yellow)
    end
end

local function setupElementInteraction(element)
    local startX, startY

    element:onClick(function(self, button, x, y)
        if button == 1 then
            selectElement(element)
            startX, startY = x, y
            return true
        elseif button == 2 then
            showContextMenu(element, x, y)
            return true
        end
        return false
    end)

    element:onDrag(function(self, button, x, y)
        if button == 1 and selectedElement == element and startX and startY then
            local dx = x - startX
            local dy = y - startY
            local newX = element.get("x") + dx
            local newY = element.get("y") + dy


            element.set("x", newX)
            element.set("y", newY)
            return true
        end
        return false
    end)

    element:onClickUp(function(self, button, x, y)
        if button == 1 then
            startX, startY = nil, nil
            return true
        end
        return false
    end)
end

local y = 2
for k,v in pairs(elementList) do
    local element = sidePanel:addButton({
        x = 2,
        y = #sidePanel.get("children") + y,
        width = 12,
        height = 1,
        text = k,
        background = colors.lightGray,    })
    y = y + 1    element:onClick(function()
        local methodName = "add" .. k
        if not canvas[methodName] then
            return
        end

        local success, newElement = pcall(function()
            return canvas[methodName](canvas, {
                x = 1,
                y = 1,
                width = 10,
                height = 3,
            })
        end)

        if not success then
            return
        end

        if not newElement then
            return
        end

        if k == "Button" then
            newElement.set("text", "Button")
        elseif k == "Label" then
            newElement.set("text", "Label")
        elseif k == "Input" then
            newElement.set("text", "Input")
        end

        table.insert(canvasElements, newElement)
        setupElementInteraction(newElement)

        selectElement(newElement)
    end)
end

scrollableFrame(sidePanel)

local fileBtn = menubar:addButton({
    x = 1,
    y = 1,
    width = 6,
    height = 1,
    text = "File",
    background = colors.cyan,
})

local editBtn = menubar:addButton({
    x = 7,
    y = 1,
    width = 6,
    height = 1,
    text = "Edit",
    background = colors.cyan,
})

local viewBtn = menubar:addButton({
    x = 13,
    y = 1,
    width = 6,
    height = 1,
    text = "View",
    background = colors.cyan,
})

main:onKey(function(self, key)
    pressedKeys[key] = true
    
    if key == keys.delete and selectedElement then
        deleteElement(selectedElement)
    end
end)

main:onKeyUp(function(self, key)
    pressedKeys[key] = false
end)

canvasArea:onClick(function(self, button, x, y)

    if pressedKeys[keys.leftShift] and button == 1 then
        canvasX, canvasY = x, y
        return true
    else
        local clickedOnElement = false
        for _, element in ipairs(canvasElements) do
            local ex, ey = element.get("x"), element.get("y")
            local ew, eh = element.get("width"), element.get("height")
            if x >= ex and x < ex + ew and y >= ey and y < ey + eh then
                clickedOnElement = true
                break
            end
        end

        if not clickedOnElement then
            selectElement(nil)
        end
          if contextMenu then
            contextMenu:destroy()
            contextMenu = nil
        end
        return false
    end
end)

canvasArea:onDrag(function(self, button, x, y)
    if pressedKeys[keys.leftShift] and button == 1 then
        if canvasX and canvasY then
            local dx = canvasX - x
            local dy = canvasY - y
            canvasArea.set("offsetX", dx)
            canvasArea.set("offsetY", dy)
        end
    end
end)

canvasArea:onClickUp(function(self, button, x, y)
    if button == 1 then
        canvasX, canvasY = nil, nil
    end
end)


fileBtn:onClick(function()
    local menu = main:addFrame({
        x = 1,
        y = 2,
        width = 12,
        height = 4,
        background = colors.lightGray,
    })

    local newBtn = menu:addButton({
        x = 1,
        y = 1,
        width = 12,
        height = 1,
        text = "New",
        background = colors.white,
    })

    local saveBtn = menu:addButton({
        x = 1,
        y = 2,
        width = 12,
        height = 1,
        text = "Save",
        background = colors.white,
    })

    local loadBtn = menu:addButton({
        x = 1,
        y = 3,
        width = 12,
        height = 1,
        text = "Load",
        background = colors.white,
    })      newBtn:onClick(function()
        for _, element in ipairs(canvasElements) do
            element:destroy()
        end
        canvasElements = {}
        selectElement(nil)
        menu:destroy()
    end)    saveBtn:onClick(function()
        menu:destroy()
    end)    loadBtn:onClick(function()
        menu:destroy()
    end)

    main:onClick(function()
        menu:destroy()
    end, nil, nil, true)
end)

editBtn:onClick(function()
    if selectedElement then
        local menu = main:addFrame({
            x = 7,
            y = 2,
            width = 12,
            height = 3,
            background = colors.lightGray,
        })

        local deleteBtn = menu:addButton({
            x = 1,
            y = 1,
            width = 12,
            height = 1,
            text = "Delete",
            background = colors.white,
        })

        local copyBtn = menu:addButton({
            x = 1,
            y = 2,
            width = 12,
            height = 1,
            text = "Copy",
            background = colors.white,
        })
          deleteBtn:onClick(function()            
            deleteElement(selectedElement)
            menu:destroy()
        end)

        copyBtn:onClick(function()
            menu:destroy()
        end)

        main:onClick(function()
            menu:destroy()
        end, nil, nil, true)
    end
end)

viewBtn:onClick(function()
    local menu = main:addFrame({
        x = 13,
        y = 2,
        width = 15,
        height = 3,
        background = colors.lightGray,
    })

    local propertiesBtn = menu:addButton({
        x = 1,
        y = 1,
        width = 15,
        height = 1,
        text = "Properties Panel",
        background = colors.white,
    })

    local gridBtn = menu:addButton({
        x = 1,
        y = 2,
        width = 15,
        height = 1,
        text = "Toggle Grid",
        background = colors.white,
    })
      propertiesBtn:onClick(function()
        menu:destroy()
    end)

    gridBtn:onClick(function()
        menu:destroy()
    end)
      main:onClick(function()
        menu:destroy()
    end, nil, nil, true)
end)

main:onClick(function(self, button, x, y)
    if contextMenu then

    end
end)

basalt.run()