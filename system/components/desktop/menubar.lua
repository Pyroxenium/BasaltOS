local basalt = require("libraries/private/basalt")

local menubar = {}

function menubar.create(desktop)
    local menubar = desktop.get():addFrame()
    menubar:setPosition(1, 1)
    menubar:setSize("{parent.width}", 1)
    menubar:setBackground(colors.gray)
    menubar:setForeground(colors.white)

    local date = desktop.get():addLabel():setVisible(false)
    date:setBackground(colors.gray)
    date:setPosition("{parent.width - #self.text}", 2)
    local clock = menubar:addLabel()
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

    local finderFrame
    menubar:addLabel():setText("Finder"):setPosition(2, 1):onClick(function()
        if not finderFrame then
            desktop.openApp("finder")
        end
    end)

    local editFrame
    menubar:addLabel():setText("Edit"):setPosition(12, 1):onClick(function()
        -- Open edit menu
    end)

    return menubar
end

return menubar