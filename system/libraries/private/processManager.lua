local process = require("libraries.private.process")

--- Process Manager
-- This module manages the processes in the system.
local processManager = {}
processManager.processes = {}
local pid = 0

function processManager.create(desktop, app)
    local newProcess = process.new(desktop, app, pid)
    processManager.processes[pid] = newProcess
    pid = pid + 1
    return newProcess
end

function processManager.get(pid)
    return processManager.processes[pid]
end

function processManager.remove(pid)
    local proc = processManager.get(pid)
    if proc then
        -- Clean up dock icon if it exists
        if proc.dockIcon then
            proc.dockIcon:remove()
        end
        proc:stop()
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