-- Context Menu System for BasaltOS
-- Creates and manages context menus

local contextMenu = {}
local colorHex = require("libraries.public.utils").tHex
local configs = require("libraries.private.configs")

function contextMenu.create(x, y, items, options)
    options = options or {}
    local width = options.width or 12
    local maxHeight = options.maxHeight or #items + 2
    local height = math.min(#items+2, options.maxHeight)

    local frame = require("libraries.private.os.frame")
    local menu = frame.create(x, y, width, height, {
        background = colors.lightGray,
    })

    local frameCanvas = menu:getCanvas()
    frameCanvas:addCommand(function(_self)
        local width, height = _self.get("width"), _self.get("height")
        local bg = _self.get("background")
        local borderColor = configs.get("windows", "primaryColor")

        _self:textFg(1, 1, ("\131"):rep(width), borderColor)
        _self:blit(1, height, ("\143"):rep(width), colorHex[bg]:rep(width), colorHex[borderColor]:rep(width))
        for i = 1, height-1 do
            _self:blit(1, i, ("\149"), colorHex[borderColor], colorHex[bg])
            _self:blit(width, i, ("\149"), colorHex[bg], colorHex[borderColor])
        end
        _self:blit(1, 1, "\151", colorHex[borderColor], colorHex[bg])
        _self:blit(width, 1, "\148", colorHex[bg], colorHex[borderColor])
        _self:blit(1, height, "\138", colorHex[bg], colorHex[borderColor])
        _self:blit(width, height, "\133", colorHex[bg], colorHex[borderColor])
    end)

    for i, item in ipairs(items) do
        if i <= maxHeight then
            local button = menu:addButton({
                x = 2,
                y = i+1,
                width = width-2,
                height = 1,
                text = item.text or ("Item " .. i),
                background = colors.lightGray,
                foreground = colors.black
            })

            button:onClick(function()
                if item.action then
                    item.action()
                end
                menu:destroy()
            end)
        end
    end

    menu.basalt.schedule(function()
        sleep(0.05)
        menu:setFocused(true)
    end)

    local destroyed = false
    menu:onBlur(function()
        if not destroyed then
            menu:setVisible(false)
            menu.basalt.schedule(function()
                sleep(0.05)
                menu:destroy()
            end)
            destroyed = true
        end
    end)

    return menu
end

return contextMenu
