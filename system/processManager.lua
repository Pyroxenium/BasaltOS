local process = {}
process._index = process
local pid = 0

function process.new(data, manifest)
    local self = setmetatable({}, process)
    self.name = data.name
    self.path = data.path
    self.args = data.args or {}
    self.manifest = manifest or {}
    self.data = data
    self.pid = pid
    self.running = false
    self.created = os.epoch("utc")
    self.status = "created"  -- created, running, suspended, terminated
    return self
end

function process:start()
    if not self.running then
        self.running = true
        self.status = "running"
    end
end

function process:stop()
    if self.running then
        self.running = false
        self.status = "terminated"
    end
end

function process:restart()
    self:stop()
    self:start()
end

local processManager = {}
processManager.processes = {}

function processManager.create(data, manifest)
    local newProcess = process.new(data, manifest)
    processManager.processes[pid] = newProcess
    pid = pid + 1
    return newProcess.pid
end

function processManager.get(pid)
    return processManager.processes[pid]
end

function processManager.remove(pid)
    local proc = processManager.get(pid)
    if proc then
        --proc:stop()
        processManager.processes[pid] = nil
    end
end

function processManager.findByName(name)
    local processes = {}
    for id, proc in pairs(processManager.processes) do
        if proc.name == name then
            table.insert(processes, {id = id, process = proc})
        end
    end
    return processes
end

function processManager.getAll()
    return processManager.processes
end

return processManager