-- /apps/settings/main.lua
-- Settings application: Configure system settings

local basalt = require("basalt")

local osAPI = require("app")

local settings = osAPI.settings

if not settings then
    error("Settings API not available")
end

local main = basalt.getMainFrame()
local current_category = nil
local category_buttons = {}
local setting_elements = {}

local COLOR_BG = colors.gray
local COLOR_SIDEBAR = colors.lightGray
local COLOR_SELECTED = colors.blue
local COLOR_TEXT = colors.white
local COLOR_LABEL = colors.lightGray

local sidebar = main:addFrame()
    :setPosition(1, 1)
    :setSize(14, "{parent.height}")
    :setBackground(COLOR_SIDEBAR)

local sidebar_title = sidebar:addLabel()
    :setText("Settings")
    :setPosition(2, 2)
    :setForeground(colors.black)

local content = main:addFrame()
    :setPosition(15, 1)
    :setSize("{parent.width - 14}", "{parent.height}")
    :setBackground(COLOR_BG)

local nav = main:addSideNav({
    width = "{parent.width}",
    height = "{parent.height}",
    background = COLOR_SIDEBAR,
})

local function createSettingElement(parent, setting_path, meta, y_pos)
    local current_value = settings.get(setting_path)

    parent:addLabel()
        :setText(meta.label)
        :setPosition(2, y_pos)
        :setForeground(colors.black)

    local input_y = y_pos + 1

    if meta.type == "boolean" then
        local checkbox = parent:addCheckBox()
            :setPosition(2, input_y)
            :onChange("checked", function(self, checked)
                settings.set(setting_path, checked)
            end)
        return input_y + 1

    elseif meta.type == "number" then
        local input = parent:addInput()
            :setPosition(2, input_y)
            :setSize(15, 1)
            :onChange("text", function(self, value)
                local num = tonumber(value)
                if num then
                    local valid, err = settings.validate(setting_path, num)
                    if valid then
                        settings.set(setting_path, num)
                        self:setBackground(colors.black)
                    else
                        self:setBackground(colors.red)
                    end
                end
            end)

        if meta.min or meta.max then
            local range_text = "(" .. (meta.min or "?") .. "-" .. (meta.max or "?") .. ")"
            parent:addLabel()
                :setText(range_text)
                :setPosition(18, input_y)
                :setForeground(COLOR_LABEL)
        end
        return input_y + 1

    elseif meta.type == "string" then
        local input = parent:addInput()
            :setPosition(2, input_y)
            :setSize(25, 1)
            :onChange("text", function(self, value)
                settings.set(setting_path, value)
            end)
        return input_y + 1

    elseif meta.type == "choice" then
        local dropdown = parent:addDropDown()
            :setPosition(2, input_y)
            :setSize(20, 1)
            :setBackground(colors.black)
            :setForeground(COLOR_TEXT)

        for _, choice in ipairs(meta.choices) do
            dropdown:addItem(choice)
        end

        for i, choice in ipairs(meta.choices) do
            if choice == current_value then
                dropdown:selectItem(i)
                break
            end
        end

        dropdown:onChange("selectedItem", function(self, item)
            if item and item.text then
                settings.set(setting_path, item.text)
            end
        end)
        return input_y + 1

    elseif meta.type == "color" then
        local preview
        local input = parent:addInput()
            :setPosition(2, input_y)
            :setSize(12, 1)
            :onChange("text", function(self, value)
                if colors[value] then
                    settings.set(setting_path, value)
                    preview:setBackground(colors[value])
                    self:setBackground(colors.black)
                else
                    self:setBackground(colors.red)
                end
            end)

        preview = parent:addLabel()
            :setText("  ")
            :setPosition(15, input_y)
            :setBackground(colors[current_value] or colors.black)

        return input_y + 1
    end

    parent:addLabel()
        :setText(tostring(current_value))
        :setPosition(2, input_y)
        :setForeground(COLOR_LABEL)
    return input_y + 1
end

local categories = settings.getCategories()
for i, category in ipairs(categories) do
    local category_settings = settings.getVisibleSettings(category.id)
    local tab = nav:addTab(category.label)
    local content = tab:addScrollFrame({
        width = "{parent.width}",
        height = "{parent.height}",
        background = colors.lightGray,
    })
    content:addLabel()
        :setText(category.label)
        :setPosition(2, 2)
        :setForeground(colors.black)

    local y = 4
    for key, meta in pairs(category_settings) do
        local setting_path = category.id .. "." .. key
        y = createSettingElement(content, setting_path, meta, y) + 2
    end
end

basalt.run()