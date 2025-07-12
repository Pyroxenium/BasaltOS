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

function processManager.getFocus()
    for _, proc in pairs(processManager.processes) do
        if proc.window and proc.window.isFocused() then
            return proc
        end
    end
    return nil
end

function processManager.setFocus(pid)
    local proc = processManager.get(pid)
    if proc and proc.window then
        proc.window:focus()
        return true
    end
    return false
end

function processManager.getCurrentId()
    local current = processManager.getFocus()
    if current then
        return current.id
    end
    return nil
end

function processManager.getCount()
    local count = 0
    for _ in pairs(processManager.processes) do
        count = count + 1
    end
    return count
end

function processManager.getAll()
    return processManager.processes
end

return processManager