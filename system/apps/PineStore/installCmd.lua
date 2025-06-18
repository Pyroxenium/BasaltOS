local args = {...}
local link = args[1]

if not link then
    print("Usage: installCmd <command>")
    return
end

print("Running install command: " .. link)
sleep(0.1)
print(shell.run(link))

