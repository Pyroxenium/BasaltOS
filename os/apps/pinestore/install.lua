-- Runs one PineStore install command inside the visible embedded terminal.

local command = tostring((...) or "")
local install_root, install_mode = select(2, ...)
install_root = tostring(install_root or "")
install_mode = install_mode == "legacy" and "legacy" or "managed"

local function tokenize(line)
    local result, current = {}, {}
    local quote, escaped = nil, false

    local function push()
        if #current > 0 then
            result[#result + 1] = table.concat(current)
            current = {}
        end
    end

    for index = 1, #line do
        local char = line:sub(index, index)
        if escaped then
            current[#current + 1] = char
            escaped = false
        elseif char == "\\" and quote == '"' then
            escaped = true
        elseif quote then
            if char == quote then quote = nil else current[#current + 1] = char end
        elseif char == '"' or char == "'" then
            quote = char
        elseif char:match("%s") then
            push()
        else
            current[#current + 1] = char
        end
    end
    if escaped then current[#current + 1] = "\\" end
    if quote then return nil, "Unclosed quote in install command" end
    push()
    return result
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

print("PineStore installer")
print(("="):rep(math.max(1, math.min(30, ({term.getSize()})[1]))))

if command == "" then
    printError("This project has no install command.")
    return false
end

local arguments, parse_error = tokenize(command)
if not arguments or #arguments == 0 then
    printError(parse_error or "Invalid install command")
    return false
end

print("> " .. command)
if install_mode == "managed" then
    print("Project folder: " .. install_root)
else
    print("Mode: legacy root install")
end
print("")

local previous_directory = shell.dir and shell.dir() or nil
if install_mode == "managed" then
    if install_root == "" then
        printError("No project folder was provided.")
        return false
    end
    if not fs.exists(install_root) then fs.makeDir(install_root) end
    if not fs.exists(install_root) or not fs.isDir(install_root) then
        printError("Could not create the project folder.")
        return false
    end
    if shell.setDir then shell.setDir(install_root) end
end

local ok, result = pcall(shell.run, table.unpack(arguments))
if previous_directory and shell.setDir then shell.setDir(previous_directory) end
if not ok then
    printError(tostring(result))
    return false
end
if result == false then
    printError("The install command reported a failure.")
    return false
end

print("")
term.setTextColor(colors.lime)
print("Installation complete.")
term.setTextColor(colors.white)
return true
