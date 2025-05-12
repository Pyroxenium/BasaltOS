local basalt = require("libraries/private/basalt")

local menubar = {}

function menubar.create(desktop)
    local menubar = desktop.get():addFrame():setVisible(false)
    menubar:setPosition(1, 1)
    menubar:setSize("{parent.width}", 1)
    menubar:setForeground(colors.white)
    menubar:setBackground(colors.gray)

    local logo = menubar:addLabel()
        logo:setText("")
        logo:setPosition(1, 1)
        logo:setSize(8, 1)

    local canvas = logo:getCanvas()
    canvas:addCommand(function(self)
        self:blit(1, 1, "BasaltOS", "e145d9bb", "77777777")
    end)

    local settingsToggleIndicator = menubar:addLabel()
        settingsToggleIndicator:setText("^")
        settingsToggleIndicator:setForeground(colors.cyan)
        settingsToggleIndicator:setPosition(desktop.get():getWidth(), 1)
        settingsToggleIndicator:setSize(1, 1)

    local date = desktop.get():addLabel():setVisible(false)
    date:setPosition("{parent.width - #self.text - 1}", 2)
    date:setForeground(colors.lightBlue)
    date:setBackground(colors.gray)
    date:setZ(10)

    local clock = menubar:addLabel()
    clock:setPosition("{parent.width - #self.text - 1}", 1)
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

    menubar:setX(1 - desktop.get():getWidth()):setVisible(true)
    menubar:animate()
        :move(1 - desktop.get():getWidth(), 1, 0.6)
        :sequence()
        :move(1, 1, 1)
        :sequence()
        :start()

    menubar:onClick(function()
            if menubar:getHeight() > 1 then
                menubar:animate()
                    :resize(desktop.get():getWidth(), 1, 0.45)
                    :start()

                settingsToggleIndicator:setText("^")
            else
                menubar:animate()
                    :resize(desktop.get():getWidth(), 10, 0.6)
                    :start()

                settingsToggleIndicator:setText("V")
            end

    end)

    basalt.schedule(function()
        while true do
            local time = os.date("%H:%M")
            clock:setText(time)
            sleep(20) -- Update clock every 20 seconds
        end
    end)

    local finderFrame
    menubar:addLabel():setText("Finder"):setPosition(11, 1):setForeground(colors.white):onClick(function()
        if not finderFrame then
            desktop.openApp("finder")
        end
    end)

    local editFrame
    menubar:addLabel():setText("Edit"):setPosition(19, 1):setForeground(colors.white):setVisible(false):onClick(function()
        -- Open edit menu
    end)

    return menubar
end

return menubar