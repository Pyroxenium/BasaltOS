-- Exec
-- Loads and executes a Lua script passed as the first argument.
-- Errors propagate naturally so the WM crash dialog fires on failure.

local path = ...

if not path or path == "" then
    error("No script path provided")
end

if not fs.exists(path) then
    error("File not found: " .. path)
end

window.setTitle(fs.getName(path))

local fn, load_err = loadfile(path, "t", _ENV)
if not fn then
    error(load_err)
end

fn()