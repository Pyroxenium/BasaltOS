-- BasaltTerminal
-- Terminal application for BasaltOS

local basalt = require("basalt")
local app = require("app")

local shell_service = app.basaltshell
if not shell_service then
    error("BasaltShell service not available")
end

local main_frame = basalt.getMainFrame()

local output_lines = {}
local max_output_lines = 100

local BG_COLOR = colors.black
local FG_COLOR = colors.white
local PROMPT_COLOR = colors.lime
local ERROR_COLOR = colors.red
local SUCCESS_COLOR = colors.green

main_frame:setBackground(BG_COLOR)

local output_list = main_frame:addList()
    :setPosition(1, 1)
    :setSize("{parent.width}", "{parent.height - 2}")
    :setBackground(BG_COLOR)
    :setForeground(FG_COLOR)
    :setSelectedBackground(BG_COLOR)
    :setSelectedForeground(FG_COLOR)

local prompt_label = main_frame:addLabel()
    :setPosition(1, "{parent.height - 1}")
    :setText("/")
    :setForeground(PROMPT_COLOR)
    :setBackground(BG_COLOR)

local input_field = main_frame:addInput()
    :setPosition(3, "{parent.height - 1}")
    :setSize("{parent.width - 2}", 1)
    :setBackground(BG_COLOR)
    :setForeground(FG_COLOR)

input_field:onEnter(function(self, value)
    if not value or value == "" then
        return
    end

    local dir = shell_service.getDirectory()
    if #dir > 20 then
        dir = "..." .. dir:sub(-17)
    end
    local prompt = dir .. " >"

    table.insert(output_lines, {text = prompt .. " " .. value, color = PROMPT_COLOR})

    local success, output = shell_service.execute(value)

    if output and output ~= "" then
        if output:match("\x1b%[2J") then
            output_lines = {}
        else    
            for line in output:gmatch("[^\n]+") do
                table.insert(output_lines, {text = line, color = success and FG_COLOR or ERROR_COLOR})
            end
        end
    end

    while #output_lines > max_output_lines do
        table.remove(output_lines, 1)
    end

    output_list:clear()
    for _, line in ipairs(output_lines) do
        output_list:addItem({ text=line.text, fg=line.color, bg=BG_COLOR })
    end
    output_list:selectItem(#output_lines)

    local new_dir = shell_service.getDirectory()
    if #new_dir > 20 then
        new_dir = "..." .. new_dir:sub(-17)
    end
    prompt_label:setText(new_dir .. " >")

    self:setText("")
end)

table.insert(output_lines, {text = "Welcome to BasaltTerminal!", color = SUCCESS_COLOR})
table.insert(output_lines, {text = "Type 'help' for available commands", color = FG_COLOR})
table.insert(output_lines, {text = "", color = FG_COLOR})

for _, line in ipairs(output_lines) do
    output_list:addItem({ text=line.text, fg=line.color, bg=BG_COLOR })
end

basalt.run()
