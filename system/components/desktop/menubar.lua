local basalt = require("libraries.public.basalt")

local menubar = {}
menubar.__index = menubar

-- Needs a rework, make clock a global element
function menubar.new(desktop)
    local self = setmetatable({}, menubar)
    self.menubar = desktop.frame:addFrame({z=100, width="{parent.width}", height=1})
    self.menubar:setBackground(colors.gray)
    self.menubar:setForeground(colors.white)
    self.curWindow = nil
    self.lastWindow = nil
    self.programMenubar = self.menubar:addFrame({
        width="{parent.width - 16}",
        x = 10,
        height=1,
        background = "{parent.background}"
    })


    local date = desktop.frame:addLabel():setVisible(false)
    date:setBackground(colors.gray)
    date:setPosition("{parent.width - #self.text}", 2)
    local clock = self.menubar:addLabel()
    clock:setPosition("{parent.width - #self.text}", 1)
    clock:onClick(function()
        basalt.schedule(function()
            if(date:getVisible()) then
                date:setVisible(false)
                return
            end
            date:setVisible(true)
            date:setText(os.date("%A, %B %d, %Y"))
            sleep(5)
            date:setVisible(false)
        end)
    end)

    basalt.schedule(function()
        while true do
            local time = os.date("%H:%M")
            clock:setText(time)
            sleep(20) -- Update clock every 20 seconds
        end
    end)

    local logo = self.menubar:addLabel({text=""}):onClick(function()
        -- Open BasaltOS menu
    end)

    local canvas = logo:getCanvas()
    canvas:addCommand(function(self)
        self:blit(1, 1, "BasaltOS", "e145d9bb", "77777777")
    end)

    return self
end

function menubar:setMenu(list, window)
    self.programMenubar:clear()
    self.curWindow = window
    self.lastWindow = window and window or self.lastWindow
    local x = 1
    for name, callback in pairs(list) do
        local label = self.programMenubar:addLabel({
            text=name,
            x=x,
            foreground=colors.white,
        })
        label:onClick(function()
            self.curWindow = self.lastWindow
            basalt.schedule(function()
                sleep(0.05)
                if self.lastWindow then
                    self.lastWindow.appFrame:setFocused(true)
                end
            end)
        end)
        label:onClickUp(function()
            self.curWindow = window
            callback()
        end)
        x = x + #name + 1
    end
end

return menubar