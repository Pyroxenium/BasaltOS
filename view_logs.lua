-- Quick log viewer utility
local log = require("system.core.log")

local log_file = log.getCurrentLogFile()

if not log_file then
    print("No log file found")
    return
end

print("Current log file: " .. log_file)
print("=" .. string.rep("=", 50))

local content, err = log.readLog(log_file)
if not content then
    print("Error reading log: " .. tostring(err))
    return
end

print(content)
