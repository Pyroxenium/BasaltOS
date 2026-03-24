-- /apps/launcher/main.lua
-- App Launcher: Browse and launch installed applications

local basalt  = require("basalt")
local osAPI   = require("app")

local registry = osAPI.registry
local process  = osAPI.process

-- Colors
local C_BG         = colors.gray
local C_SIDEBAR    = colors.lightGray
local C_SEL        = colors.blue
local C_CARD_BG    = colors.black
local c_CARD_SELECTED_BG = colors.blue
local C_CARD_HOV   = colors.gray
local C_TEXT       = colors.white
local C_SUBTEXT    = colors.lightGray
local C_HEADER_BG  = colors.blue

local SIDEBAR_W    = 13
local CARD_H       = 3

-- Category display names and order
local CATEGORY_ORDER = { "all", "system", "utilities", "games", "other" }
local CATEGORY_LABELS = {
    all       = "All Apps",
    system    = "System",
    utilities = "Utilities",
    games     = "Games",
    other     = "Other",
}

local main         = basalt.getMainFrame()
local selected_cat = "all"
local app_buttons  = {}

-- ── Layout ──────────────────────────────────────────────────────────────────

main:setBackground(C_BG)

-- Header
local header = main:addFrame({
    x = 1, y = 1,
    width = "{parent.width}", height = 1,
    background = C_HEADER_BG,
})
header:addLabel({
    x = 2, y = 1,
    text = "App Launcher",
    foreground = C_TEXT,
    background = C_HEADER_BG,
})

-- Sidebar
local sidebar = main:addScrollFrame({
    x = 1, y = 2,
    width = SIDEBAR_W,
    height = "{parent.height - 1}",
    background = C_SIDEBAR,
    scrollable = true,
})

-- Content area
local content = main:addScrollFrame({
    x = SIDEBAR_W + 1, y = 2,
    width  = "{parent.width - " .. SIDEBAR_W .. "}",
    height = "{parent.height - 1}",
    background = C_BG,
    scrollable = true,
})

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function truncate(str, max)
    if #str <= max then return str end
    return str:sub(1, max - 1) .. "\26"
end

local function getAppsForCategory(cat)
    local all = registry.listPrograms()
    if cat == "all" then
        table.sort(all, function(a, b)
            return (a.name or a.id) < (b.name or b.id)
        end)
        return all
    end
    local filtered = {}
    for _, app in ipairs(all) do
        if (app.category or "other") == cat then
            table.insert(filtered, app)
        end
    end
    table.sort(filtered, function(a, b)
        return (a.name or a.id) < (b.name or b.id)
    end)
    return filtered
end

-- ── App cards ────────────────────────────────────────────────────────────────

local cat_buttons = {}

local function refreshContent(cat)
    -- Clear old cards
    for _, frame in ipairs(app_buttons) do
        frame:destroy()
    end
    app_buttons = {}

    local apps = getAppsForCategory(cat)
    local card_w = content.getResolved("width") - 2

    if #apps == 0 then
        local lbl = content:addLabel({
            x = 2, y = 2,
            text = "No apps in this category.",
            foreground = C_SUBTEXT,
            background = C_BG,
        })
        table.insert(app_buttons, lbl)
        return
    end

    for i, app in ipairs(apps) do
        local y = (i - 1) * (CARD_H + 1) + 1
        local app_id = app.id

        local card = content:addFrame({
            x = 2, y = y,
            width  = card_w,
            height = CARD_H,
            background = C_CARD_BG,
        })
        card:setBackgroundState("clicked", c_CARD_SELECTED_BG)

        card:addLabel({
            x = 2, y = 1,
            text = truncate(app.name or app_id, card_w - 2),
            foreground = C_TEXT,
            background = C_CARD_BG,
        })

        card:addLabel({
            x = 2, y = 2,
            text = truncate(app.description or "", card_w - 2),
            foreground = C_SUBTEXT,
            background = C_CARD_BG,
        })

        local tag = (app.version or "1.0.0") .. "  [" .. (app.category or "other") .. "]"
        card:addLabel({
            x = 2, y = 3,
            text = truncate(tag, card_w - 2),
            foreground = colors.gray,
            background = C_CARD_BG,
        })

        card:onClick(function()
            process.startProgram(app_id)
        end)

        table.insert(app_buttons, card)
    end
end

-- ── Sidebar category buttons ──────────────────────────────────────────────

local function selectCategory(cat)
    selected_cat = cat

    -- Update sidebar button colors
    for c, btn in pairs(cat_buttons) do
        if c == cat then
            btn:setBackground(C_SEL)
            btn:setForeground(C_TEXT)
        else
            btn:setBackground(C_SIDEBAR)
            btn:setForeground(colors.black)
        end
    end

    content:setOffset(0, 0)
    refreshContent(cat)
end

for i, cat in ipairs(CATEGORY_ORDER) do
    local label = CATEGORY_LABELS[cat] or cat
    local btn = sidebar:addButton({
        x = 1, y = i,
        width  = SIDEBAR_W,
        height = 1,
        text   = truncate(label, SIDEBAR_W),
        background = C_SIDEBAR,
        foreground = colors.black,
    })
    btn:onClick(function()
        selectCategory(cat)
    end)
    cat_buttons[cat] = btn
end

-- ── Initial render ────────────────────────────────────────────────────────

selectCategory("all")

basalt.run()
