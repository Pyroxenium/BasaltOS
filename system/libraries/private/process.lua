local process = {}
process.__index = process


function process.new(app, pid)
    local self = setmetatable({}, process)
    self.app = app
    self.pid = pid
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

function process:run()
    if not self.running then
        self.running = true
        self.status = "running"
        if not self.window then
        local wManager = self.app:getDesktop().windowManager
            self.window = wManager:createWindow(self)
            self.window:setTitle(self.app.manifest.name)
            self.window:run()
        end

        -- add icon if icon doesnt exist
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