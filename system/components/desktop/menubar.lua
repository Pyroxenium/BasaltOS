local basalt = require("libraries/private/basalt")

local menubar = {}

function menubar.create(desktop)
    local menubar = desktop.get():addFrame()
    menubar:setPosition(1, 1)
    menubar:setSize("{parent.width}", 1)
    menubar:setBackground(colors.gray)

    local logo = menubar:addLabel()
        logo:setText("BasaltOS")
        logo:setPosition(1, 1)
        logo:setSize(8, 1)
        logo:setForeground(colors.lightBlue)
        logo:setBackground(colors.gray)

    local date = desktop.get():addLabel():setVisible(false)
    date:setPosition("{parent.width - #self.text}", 2)
    date:setForeground(colors.lightBlue)
    date:setBackground(colors.gray)

    local clock = menubar:addLabel()
    clock:setPosition("{parent.width - #self.text}", 1)
    clock:setForeground(colors.lightBlue)

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
    menubar:addLabel():setText("Finder"):setPosition(11, 1):setForeground("white"):onClick(function()
        if not finderFrame then
            desktop.openApp("finder")
        end
    end)

    local editFrame
    menubar:addLabel():setText("Edit"):setPosition(19, 1):setForeground("white"):onClick(function()
        -- Open edit menu
    end)

    return menubar
end

return menubar