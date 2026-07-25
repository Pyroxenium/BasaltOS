-- /system/apps/calculator/main.lua
-- Compact keyboard- and mouse-driven calculator for BasaltOS.

local basalt = require("basalt")
local app = require("app")
local calculator = require("calculator_logic")

local function theme(key, fallback)
    return app.theme(key, fallback)
end

local C = {
    background=theme("menu_bg", colors.white),
    foreground=theme("menu_fg", colors.black),
    muted=theme("menu_muted", colors.gray),
    surface=theme("surface", colors.lightGray),
    primary=theme("primary", colors.blue),
    text=theme("text", colors.white),
    danger=theme("danger", colors.red),
    border=theme("border", colors.gray),
    pressed=theme("btn_clicked", colors.cyan),
}

local main = basalt.getMainFrame()
main:setBackground(C.background)

local header = main:addFrame({
    x=1, y=1, width="{parent.width}", height=1,
    background=C.primary,
})
header:addLabel({
    x=2, y=1, width="{parent.width - 2}", height=1,
    text="Calculator", foreground=C.text, background=C.primary, disabled=true,
})

local display = main:addInput({
    x=2, y=2, width="{parent.width - 3}", height=1,
    text="", placeholder="0", maxLength=128,
    foreground=C.foreground, background=C.surface,
    placeholderColor=C.muted,
})

local history_label = main:addLabel({
    x=2, y=3, width="{parent.width - 3}", height=1,
    text="Enter = calculate", foreground=C.muted,
    background=C.background, disabled=true,
})

main:addFrame({
    x=1, y=4, width="{parent.width}", height=1,
    background=C.border, disabled=true,
})

local keypad = main:addFrame({
    x=1, y=5, width="{parent.width}", height=10,
    background=C.background,
})

local function columnX(column)
    return string.format("{floor(parent.width * %d / 4) + 1}", column - 1)
end

local function columnWidth(column)
    return string.format(
        "{floor(parent.width * %d / 4) - floor(parent.width * %d / 4)}",
        column, column - 1
    )
end

local just_evaluated = false
local last_result_text = ""

local function setDisplay(value)
    value = tostring(value or "")
    display:setText(value)
    if display._moveCursor then display:_moveCursor(#value + 1) end
end

local function clearDisplay()
    setDisplay("")
    history_label:setText("Enter = calculate")
    history_label:setForeground(C.muted)
    just_evaluated = false
    display:focus()
end

local function backspace()
    local value = tostring(display:getText() or "")
    setDisplay(value:sub(1, math.max(0, #value - 1)))
    just_evaluated = false
    display:focus()
end

local function calculate()
    local expression = tostring(display:getText() or "")
    local result, err = calculator.evaluate(expression)
    if result == nil then
        history_label:setText(err)
        history_label:setForeground(C.danger)
        display:focus()
        return
    end

    local formatted = calculator.format(result)
    history_label:setText(expression .. " =")
    history_label:setForeground(C.muted)
    setDisplay(formatted)
    last_result_text = formatted
    just_evaluated = true
    display:focus()
end

local function appendToken(token)
    local value = tostring(display:getText() or "")
    local starts_new = token:match("^[%d%.]$") ~= nil
    if just_evaluated and starts_new then value = "" end
    setDisplay(value .. token)
    just_evaluated = false
    history_label:setForeground(C.muted)
    display:focus()
end

local BUTTONS = {
    {"C", "Back", "(", ")"},
    {"7", "8", "9", "/"},
    {"4", "5", "6", "*"},
    {"1", "2", "3", "-"},
    {"0", ".", "=", "+"},
}

for row, values in ipairs(BUTTONS) do
    for column, label in ipairs(values) do
        local is_operator = label:match("^[%+%-%*/=]$") ~= nil
        local button = keypad:addButton({
            x=columnX(column), y=(row - 1) * 2 + 1,
            width=columnWidth(column), height=2,
            text=label,
            foreground=is_operator and C.text or C.foreground,
            background=is_operator and C.primary or C.surface,
        })
        button:setStateStyle("hover", {
            background=is_operator and C.pressed or C.primary,
            foreground=C.text,
        })
        button:setStateStyle("pressed", {
            background=C.pressed, foreground=C.text,
        })
        button:onClickUp(function(_, mouse_button)
            if mouse_button ~= 1 then return end
            if label == "C" then
                clearDisplay()
            elseif label == "Back" then
                backspace()
            elseif label == "=" then
                calculate()
            else
                appendToken(label)
            end
        end)
    end
end

display:onEnter(function()
    calculate()
end)

display:onChange(function(_, value)
    value = tostring(value or "")
    if just_evaluated and value:sub(1, #last_result_text) == last_result_text then
        local typed = value:sub(#last_result_text + 1)
        if typed:match("^[%d%.]+$") then setDisplay(typed) end
    end
    just_evaluated = false
    history_label:setForeground(C.muted)
end)

display:onKey(function(_, key)
    if key == keys.escape then clearDisplay() end
end)

display:focus()
basalt.run()
