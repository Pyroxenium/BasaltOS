local utils = require ("libraries/public/utils")
local dock = {apps={}}
local defaultIcon = {
    {
      {
        "\131\131\131",
        "9f9",
        "fff",
      },
      {
        "\7\7 ",
        "999",
        "fff",
      },
    },
  }

local dockApp = {}
dockApp.__index = dockApp

function dockApp.newWindow(app)
    local self = setmetatable({}, dockApp)
    app.dock = self
    self.app = app
    self.process = app.process
    self.name = app.name
    self.path = app.path
    self.icon = dock.frame:addImage()
    self.icon:setBackground(colors.black)
    self.icon:setForeground(colors.white)
    self.icon:setSize(3, 2)
    if app.manifest.icon then
        self.icon:setBimg(app.manifest.icon)
    else
        self.icon:setBimg(defaultIcon)
    end
    self.iconCanvasId = self.icon:getCanvas()
    :text(1, 3, "\136\140\132", colors.lightGray)
    self.icon:onClickUp(function()
        if self.app:getStatus() == "running" then
            self.app:minimize()
        else
            self.app:restore()
        end
    end)

    return self
end

function dockApp.newApp(data, manifest)
    local self = setmetatable({}, dockApp)
    self.data = data
    self.name = data.name
    self.path = data.path
    self.pinned = true
    self.manifest = manifest or {}
    self.icon = dock.frame:addImage()
    self.icon:setBackground(colors.black)
    self.icon:setForeground(colors.white)
    self.icon:setSize(3, 2)
    if manifest.icon then
        self.icon:setBimg(manifest.icon)
    else
        self.icon:setBimg(defaultIcon)
    end
    self.icon:onClickUp(function()
        --if not processManager.get(self.process.pid) then
            --dock.desktop.launchApp(self.process)
        --end
    end)

    return self
end

function dock.create(desktop)
    local wallpaperPath = "media/bimg/wallpaper/basalty.bimg"
    local wallpaperImg = utils.loadBimg(wallpaperPath)
    local wallPaper = desktop.get():addImage()
        :setSize(desktop.get():getSize())
        :setPosition(1,1)
        :setBimg(wallpaperImg)
        :setPosition(1, 1 - desktop.get():getHeight())

    local wallPaperAnim = wallPaper:animate()
        :move(1,2, 0.75)
        :sequence()
        :start()
    
    local h = desktop.get():getHeight()
    dock.desktop = desktop
    dock.frame = desktop.get():addFrame():setVisible(false)
    dock.frame:setPosition(3, "{parent.height+1}")
    dock.frame:setSize("{parent.width-4}", 3)
    dock.frame:setBackground(colors.lightGray)
    dock.frame:setForeground(colors.black)
    dock.frame:addVisualElement()
        :setSize("{parent.width}", 2)
        :setBackground(colors.gray)
        :setPosition(1, 2)
    dock.frame:setY(desktop.get():getHeight()):setVisible(true)
    local dockAnim = dock.frame:animate()
        :move(3, desktop.get():getHeight(), 2)
        :sequence()
        :move(3, desktop.get():getHeight()-2, 0.5)
        :sequence()
        :start()

    return dock
end

function dock.updateDock()
    local x = 1
    for _, app in ipairs(dock.apps) do
        app.icon:setPosition(x, 1)
        x = x + 4
    end
end

function dock.addWindow(application)
    local app = dockApp.newWindow(application)
    table.insert(dock.apps, app)
    dock.updateDock()
    return app
end

function dock.addApp(data, manifest)
    local app = dockApp.newApp(data, manifest)
    table.insert(dock.apps, app)
    dock.updateDock()
    return app
end

function dock.removeWindow(process)
    for i, app in pairs(dock.apps) do
        if app.process then
            if app.process.pid == process.pid then
                table.remove(dock.apps, i)
                app.icon:destroy()
                dock.updateDock()
                return true
            end
        end
    end
    return false
end

return dock