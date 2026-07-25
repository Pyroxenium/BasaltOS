-- /apps/launcher/main.lua
-- Compact, icon-aware application browser for BasaltOS.

local basalt = require("basalt")
local app = require("app")
local icon = require("core.icon")

-- Apps load Basalt through their own package context. Register Image there as
-- well, otherwise frames created by this Basalt instance have no addImage().
basalt.use("image")

local registry = app.registry
local process = app.process

local function theme(key, fallback)
    return app.theme(key, fallback)
end

local C = {
    background = theme("menu_bg", colors.white),
    foreground = theme("menu_fg", colors.black),
    muted = theme("menu_muted", colors.gray),
    surface = theme("surface", colors.lightGray),
    primary = theme("primary", colors.blue),
    accent_text = theme("text", colors.white),
    accent_muted = theme("text_dim", colors.lightGray),
    icon = theme("icon_fg", colors.black),
    pressed = theme("btn_clicked", colors.cyan),
    border = theme("border", colors.gray),
    danger = theme("danger", colors.red),
}

local SIDEBAR_WIDTH = 12
local CARD_HEIGHT = 3
local CARD_GAP = 1

local CATEGORY_ORDER = {"all", "system", "utilities", "games", "other"}
local CATEGORY_LABELS = {
    all = "All Apps",
    system = "System",
    utilities = "Utilities",
    games = "Games",
    other = "Other",
}

local main = basalt.getMainFrame()
local selected_category = "all"
local search_query = ""
local app_elements = {}
local category_buttons = {}
local visible_apps = {}

main:setBackground(C.background)

local sidebar = main:addFrame({
    x=1, y=1,
    width=SIDEBAR_WIDTH, height="{parent.height}",
    background=C.surface,
})

sidebar:addFrame({
    x=1, y=1,
    width=1, height="{parent.height}",
    background=C.primary, disabled=true,
})

sidebar:addLabel({
    x=3, y=2, width=SIDEBAR_WIDTH - 3, height=1,
    text="Categories", foreground=C.muted,
    background=false, disabled=true,
})

local count_label = sidebar:addLabel({
    x=3, y="{parent.height - 1}",
    width=SIDEBAR_WIDTH - 3, height=1,
    text="", foreground=C.muted,
    background=false, disabled=true,
})

local toolbar = main:addFrame({
    x=SIDEBAR_WIDTH + 1, y=1,
    width="{parent.width - " .. SIDEBAR_WIDTH .. "}", height=3,
    background=C.background,
})

toolbar:addLabel({
    x=2, y=2, width=1, height=1,
    text=">", foreground=C.primary,
    background=C.background, disabled=true,
})

local search_input = toolbar:addInput({
    x=4, y=2,
    width="{parent.width - 5}", height=1,
    placeholder="Search apps...",
    foreground=C.foreground, background=C.surface,
})

toolbar:addFrame({
    x=1, y=3,
    width="{parent.width}", height=1,
    background=C.border, disabled=true,
})

local content = main:addFrame({
    x=SIDEBAR_WIDTH + 1, y=4,
    width="{parent.width - " .. SIDEBAR_WIDTH .. "}",
    height="{parent.height - 3}",
    background=C.background,
    scrollable=true,
    scrollbar="auto",
})

local function fitText(value, width)
    local text = tostring(value or "")
    width = math.max(0, math.floor(tonumber(width) or 0))
    if #text <= width then return text end
    if width <= 2 then return (".."):sub(1, width) end
    return text:sub(1, width - 2) .. ".."
end

local function normalize(value)
    return tostring(value or ""):lower()
end

local function matchesSearch(program, query)
    if query == "" then return true end
    return normalize(program.name):find(query, 1, true)
        or normalize(program.id):find(query, 1, true)
        or normalize(program.description):find(query, 1, true)
        or normalize(program.category):find(query, 1, true)
end

local function getVisibleApps()
    local result = {}
    local query = normalize(search_query)

    for _, program in ipairs(registry.listPrograms()) do
        local category = program.category or "other"
        if (selected_category == "all" or category == selected_category)
            and matchesSearch(program, query) then
            result[#result + 1] = program
        end
    end

    table.sort(result, function(a, b)
        return normalize(a.name or a.id) < normalize(b.name or b.id)
    end)
    return result
end

local function bindHover(source, callback)
    source:onMouseEnter(function() callback(true) end)
    source:onMouseLeave(function() callback(false) end)
end

local function clearContent()
    for _, element in ipairs(app_elements) do
        element:destroy()
    end
    app_elements = {}
end

local function showLaunchError(program, err)
    local notification = app.notification
    if notification and notification.show then
        notification.show(
            "Could not open " .. tostring(program.name or program.id),
            tostring(err or "Unknown error"),
            "error"
        )
    end
end

local function launch(program)
    local _, err = process.startProgram(program.id)
    if err then showLaunchError(program, err) end
end

local function refreshContent()
    clearContent()
    visible_apps = getVisibleApps()

    local count = #visible_apps
    count_label:setText(tostring(count) .. (count == 1 and " app" or " apps"))

    if count == 0 then
        local empty = content:addLabel({
            x=2, y=2,
            width="{parent.width - 3}", height=1,
            text=search_query ~= "" and "No matching apps." or "No apps in this category.",
            foreground=C.muted, background=C.background,
            disabled=true,
        })
        app_elements[#app_elements + 1] = empty
        return
    end

    local available_width = math.max(1, content:getWidth() - 2)
    local columns = available_width >= 30 and 2 or 1
    local card_width = math.floor((available_width - (columns - 1) * CARD_GAP) / columns)

    for index, program in ipairs(visible_apps) do
        local captured = program
        local column = (index - 1) % columns
        local row = math.floor((index - 1) / columns)
        local x = 2 + column * (card_width + CARD_GAP)
        local y = 1 + row * (CARD_HEIGHT + CARD_GAP)

        local card = content:addFrame({
            x=x, y=y,
            width=card_width, height=CARD_HEIGHT,
            background=C.surface,
        })
        card:setStateStyle("hover", {background=C.primary})
        card:setStateStyle("pressed", {background=C.pressed})

        local card_icon = icon.add(card, captured, {
            x=1, y=1,
            width=icon.DESKTOP_WIDTH, height=icon.DESKTOP_HEIGHT,
            iconForeground=C.icon, iconBackground=C.surface,
            variant="main",
        })

        local text_width = math.max(1, card_width - 6)
        local name_label = card:addLabel({
            x=6, y=1, width=text_width, height=1,
            text=fitText(captured.name or captured.id, text_width),
            foreground=C.foreground, background=false, disabled=true,
        })
        local description_label = card:addLabel({
            x=6, y=2, width=text_width, height=1,
            text=fitText(captured.description or "Application", text_width),
            foreground=C.muted, background=false, disabled=true,
        })
        local category_label = card:addLabel({
            x=6, y=3, width=text_width, height=1,
            text=fitText(captured.category or "other", text_width),
            foreground=C.primary, background=false, disabled=true,
        })

        local function setCardHover(hovered)
            card:setState("hover", hovered)
            icon.update(
                card_icon,
                captured,
                hovered and C.accent_text or C.icon,
                hovered and C.primary or C.surface,
                false,
                "main"
            )
            name_label:setForeground(hovered and C.accent_text or C.foreground)
            description_label:setForeground(hovered and C.accent_muted or C.muted)
            category_label:setForeground(hovered and C.accent_text or C.primary)
        end

        for _, source in ipairs({card, card_icon, name_label, description_label, category_label}) do
            bindHover(source, setCardHover)
        end

        -- Launch after the complete mouse gesture. Starting on mouse_click
        -- leaves the matching mouse_up queued; that event can hit this launcher
        -- window after the new app was created and bring the launcher forward
        -- again.
        card:onClickUp(function(_, button)
            if button == 1 then launch(captured) end
        end)

        app_elements[#app_elements + 1] = card
    end
end

local function selectCategory(category)
    selected_category = category

    for id, button in pairs(category_buttons) do
        local selected = id == category
        button:setBackground(selected and C.primary or C.surface)
        button:setForeground(selected and C.accent_text or C.foreground)
    end

    content:scrollTo(0, 0)
    refreshContent()
end

for index, category in ipairs(CATEGORY_ORDER) do
    local captured = category
    local button = sidebar:addButton({
        x=3, y=3 + index,
        width=SIDEBAR_WIDTH - 3, height=1,
        text=fitText(CATEGORY_LABELS[category] or category, SIDEBAR_WIDTH - 3),
        foreground=C.foreground, background=C.surface,
    })
    button:setStateStyle("hover", {background=C.background, foreground=C.foreground})
    button:setStateStyle("pressed", {background=C.pressed, foreground=C.accent_text})
    button:onClick(function(_, mouse_button)
        if mouse_button == 1 then selectCategory(captured) end
    end)
    category_buttons[category] = button
end

search_input:onChange(function(_, value)
    search_query = tostring(value or "")
    content:scrollTo(0, 0)
    refreshContent()
end)

search_input:onKey(function(_, key)
    if key == keys.enter and visible_apps[1] then
        launch(visible_apps[1])
    end
end)

selectCategory("all")

basalt.run()
