-- Exec
-- Runs a Lua script inside a target-aware environment. The launched script
-- resolves modules relative to its own directory, not relative to Exec.

local argv = {...}
local path = table.remove(argv, 1)

if not path or path == "" then
    error("No script path provided")
end

path = fs.combine("", path)
if not fs.exists(path) then
    error("File not found: " .. path)
end
if fs.isDir(path) then
    error("Cannot execute a directory: " .. path)
end

window.setTitle(fs.getName(path))

local targetDir = fs.getDir(path)
local targetEnv = setmetatable({}, {__index = _ENV})
local makePackage = dofile("rom/modules/main/cc/require.lua").make
targetEnv.require, targetEnv.package = makePackage(targetEnv, "/")

-- Preserve APIs injected by BasaltOS (notably require("app")), while keeping
-- loaded modules and package.path isolated for the launched script.
for name, loader in pairs(package.preload or {}) do
    targetEnv.package.preload[name] = loader
end

targetEnv.package.path = table.concat({
    fs.combine(targetDir, "?.lua"),
    fs.combine(targetDir, "?/init.lua"),
    "system/?.lua",
    "system/?/init.lua",
    "system/lib/public/?.lua",
    "system/lib/public/?/init.lua",
    targetEnv.package.path,
}, ";")

-- shell.getRunningProgram() is commonly used to locate assets and save data.
-- The inherited shell would otherwise report system/apps/exec/main.lua.
local targetShell = setmetatable({}, {__index = shell})
function targetShell.getRunningProgram()
    return path
end
targetEnv.shell = targetShell

targetEnv.arg = {[0] = path}
for index, value in ipairs(argv) do targetEnv.arg[index] = value end

local fn, loadErr = loadfile(path, "t", targetEnv)
if not fn then error(loadErr) end

return fn(table.unpack(argv))
