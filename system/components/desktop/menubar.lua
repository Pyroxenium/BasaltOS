local basalt = require("libraries.public.basalt")

local menubar = {}
menubar.__index = menubar

-- Needs a rework, make clock a global element
function menubar.new(desktop)
    local self = setmetatable({}, menubar)
    self.menubar = desktop.frame:addFrame({z=100, width="{parent.width}", height=1})
    self.menubar:setBackground(colors.gray)
    self.menubar:setForeground(colors.white)

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

return menubar