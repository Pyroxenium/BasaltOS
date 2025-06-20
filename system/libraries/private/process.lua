local process = {}
process.__index = process


function process.new(desktop, app, pid)
    local self = setmetatable({}, process)
    self.app = app
    self.pid = pid
    self.desktop = desktop
    self.running = false
    self.created = os.epoch("utc")
    self.status = "created"  -- created, running, suspended, terminated
    return self
end

function process:getStatus()
    return self.status
end

function process:setIcon(icon)
    self.icon = icon
end

function process:run(...)
    if not self.running then
        self.running = true
        self.status = "running"
        if not self.window then
            self.window = self.desktop.windowManager:createWindow(self)
            local title = self.app.manifest.window and (self.app.manifest.window.title or self.app.manifest.name) or self.app.manifest.name or "Undefined"
            self.window:setTitle(title)
            self.window:run(...)

            local iconImg = self.app.manifest.icon
            iconImg = iconImg or "{assets}/icons/default.bimg"
            self.icon = self.desktop.dock:add(self.app)
        end
    end
end

function process:minimize()
    if self.window then
        self.window:minimize()
        self.status = "minimized"
    end
    if self.icon then
        self.icon:updateStatus("minimized")
    end
end

function process:restore()
    if self.window then
        self.window:restore()
        self.status = "restored"
    end
    if self.icon then
        self.icon:updateStatus("restored")
    end
end

function process:maximize()
    if self.window then
        self.window:maximize()
        self.status = "maximized"
    end
    if self.icon then
        self.icon:updateStatus("maximized")
    end
end

function process:stop()
    if self.running then
        self.running = false
        self.status = "terminated"
        if self.window then
            self.window:close()
        end
        if self.icon then
            self.icon:remove()
        end
    end
end

return process