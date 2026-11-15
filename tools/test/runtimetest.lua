-- Checks the package runtime against the way BasaltOS installs, updates and
-- removes apps. Run by tools/test.ps1 on a throwaway computer that holds the
-- shipped /system/boot/bpk.lua and one packed app (Calculator) in /stage.

local results, failed = {}, false

local function check(name, condition)
    results[#results + 1] = (condition and "ok    " or "FAIL  ") .. name
    if not condition then failed = true end
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

local function readAll(path, mode)
    local handle = fs.open(path, mode or "r")
    local data = handle.readAll()
    handle.close()
    return data
end

local function writeAll(path, data)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local handle = fs.open(path, "wb")
    handle.write(data)
    handle.close()
end

local function adler32(input)
    local a, b = 1, 0
    for index = 1, #input do
        a = (a + input:byte(index)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

-- A package made by hand, stored without compression (stream version 1,
-- every control byte announces eight literal bytes).
-- files: {{path, content}, ...}; stream_content: what the stream really
-- holds, when that is meant to differ from what the header announces.
local function handmadePackage(root, files, stream_content)
    local index, contents = {}, {}
    for position, file in ipairs(files) do
        index[position] = #file[2] .. " " .. file[1]
        contents[position] = file[2]
    end
    local body = table.concat(contents)
    local source = stream_content or body
    local parts = {string.char(1)}
    for position = 1, #source, 8 do
        parts[#parts + 1] = "\0" .. source:sub(position, position + 7)
    end
    local stream = table.concat(parts)
    return ("BPK1\nhandmade\n%s\n%d %d %.0f %d\n%s\n"):format(
        root, #stream, #body, adler32(body), #files, table.concat(index, "\n")) .. stream
end

local function run()
    local bpk = dofile("system/boot/bpk.lua")
    bpk.install()

    check("a package in a staging folder stays an ordinary file",
        not fs.exists("stage/main.lua") and #bpk.stats() == 0)

    -- What the store service does with a download before installing it.
    local info = bpk.inspect("stage/app.bpk")
    check("a package can be inspected without mounting it",
        info ~= nil and info.root == "." and (info.files["main.lua"] or 0) > 0
            and #bpk.stats() == 0 and not fs.exists("stage/main.lua"))
    check("an intact package passes verification", bpk.inspect("stage/app.bpk", true) ~= nil)

    local raw = readAll("stage/app.bpk", "rb")
    writeAll("truncated.bpk", raw:sub(1, #raw - 20))
    local verified, reason = bpk.inspect("truncated.bpk", true)
    check("a truncated package fails verification",
        bpk.inspect("truncated.bpk") ~= nil and verified == nil and type(reason) == "string")
    check("a file that is not a package is refused", bpk.inspect("stage/app.json") == nil)

    -- The registry installs by creating the folder and copying entry by entry.
    local app = "apps/demo"
    fs.makeDir(app)
    for _, name in ipairs(fs.list("stage")) do
        fs.copy(fs.combine("stage", name), fs.combine(app, name))
    end
    local main = fs.combine(app, "main.lua")
    check("installing makes the packaged files visible without a reboot", fs.exists(main))
    check("packaged files are listed next to real ones",
        contains(fs.list(app), "main.lua") and contains(fs.list(app), "app.json"))
    check("only the package itself takes disk space", not bpk.native.exists(main))
    check("size and read-only flag are reported", fs.getSize(main) > 0 and fs.isReadOnly(main))
    check("packaged code loads", type(loadfile(main)) == "function")

    local handle = fs.open(main, "r")
    local first = handle.readLine()
    handle.close()
    check("packaged files can be read line by line", type(first) == "string")
    check("packaged files cannot be deleted one by one", not pcall(fs.delete, main))

    -- A real file with the same path overrides the package (development).
    writeAll(main, "return 42")
    check("a real file overrides the packaged one", loadfile(main)() == 42)
    fs.delete(main)
    local restored = readAll(main)
    check("removing the override brings the packaged file back",
        not bpk.native.exists(main) and restored ~= "return 42" and #restored > 100)

    handle = fs.open(main, "a")
    handle.write("-- appended")
    handle.close()
    check("appending to a packaged file keeps its content",
        bpk.native.exists(main) and readAll(main) == restored .. "-- appended")
    fs.delete(main)

    fs.copy(main, "exported.lua")
    check("a packaged file can be copied out", bpk.native.exists("exported.lua"))

    fs.move(app, "apps/renamed")
    check("moving an app folder moves its packaged files",
        fs.exists("apps/renamed/main.lua") and not fs.exists(main))

    fs.delete("apps/renamed")
    check("uninstalling removes the packaged files",
        not fs.exists("apps/renamed/main.lua") and #bpk.stats() == 0)

    -- An updater that writes the package in place.
    fs.makeDir("system/apps/demo")
    local target = fs.open("system/apps/demo/app.bpk", "wb")
    target.write(raw)
    check("a package is not mounted while it is still being written",
        not fs.exists("system/apps/demo/main.lua"))
    target.close()
    check("a package written in place is mounted when it is closed",
        fs.exists("system/apps/demo/main.lua"))

    writeAll("system/apps/demo/app.bpk", raw:sub(1, #raw - 20))
    check("a truncated package is reported instead of loading garbage",
        not pcall(loadfile, "system/apps/demo/main.lua"))
    fs.delete("system/apps/demo")

    -- Packages made by hand: what a careless or hostile app could ship.
    writeAll("apps/handmade/app.bpk", handmadePackage(".", {
        {"lib/hello.lua", "return 'hello'"},
        {"notes.txt", "one\r\ntwo"},
    }))
    check("an uncompressed package is read correctly",
        fs.isDir("apps/handmade/lib") and loadfile("apps/handmade/lib/hello.lua")() == "hello")
    handle = fs.open("apps/handmade/notes.txt", "r")
    first = handle.readLine()
    handle.close()
    check("Windows line endings are read as one line break", first == "one")
    fs.copy("apps/handmade/lib", "copied-lib")
    check("a folder that exists only in a package can be copied out",
        bpk.native.exists("copied-lib/hello.lua"))

    local mounted = #bpk.stats()
    writeAll("apps/climber/app.bpk", handmadePackage(".", {{"../../escaped.lua", "return 1"}}))
    check("a package cannot place files outside its own folder",
        not fs.exists("escaped.lua") and #bpk.stats() == mounted
            and bpk.mount("apps/climber/app.bpk") == nil)

    -- fs.combine drops ':' on some platforms, which would turn ".:." into "..".
    writeAll("apps/sneaky/app.bpk", handmadePackage(".", {{".:./.:./sneaked.lua", "return 1"}}))
    check("a disguised path cannot leave the folder either", not fs.exists("sneaked.lua"))

    writeAll("apps/rooted/app.bpk", handmadePackage("/", {{"system/core/kernel.lua", "return 1"}}))
    check("an app package cannot provide system files",
        not fs.exists("system/core/kernel.lua") and bpk.mount("apps/rooted/app.bpk") == nil)

    writeAll("apps/twofold/app.bpk", handmadePackage(".", {{"x", "1"}, {"x/y.lua", "2"}}))
    check("a package cannot make one path a file and a folder",
        bpk.mount("apps/twofold/app.bpk") == nil)

    writeAll("bomb.bpk", handmadePackage(".", {{"small.lua", "12345678"}}, ("x"):rep(4096)))
    local accepted, bomb_reason = bpk.inspect("bomb.bpk", true)
    check("a stream that unpacks to more than announced is stopped early",
        accepted == nil and tostring(bomb_reason):find("longer than announced", 1, true) ~= nil)

    -- Two system packages providing the same file: the later one wins, and
    -- the earlier one takes over again when the later one is unmounted.
    writeAll("layers/first.bpk", handmadePackage("/", {{"shared/value.lua", "return 'first'"}}))
    writeAll("layers/second.bpk", handmadePackage("/", {{"shared/value.lua", "return 'second'"}}))
    bpk.mount("layers/first.bpk")
    bpk.mount("layers/second.bpk")
    local layered = loadfile("shared/value.lua")()
    bpk.unmount("layers/second.bpk")
    check("unmounting a package uncovers the one below it",
        layered == "second" and loadfile("shared/value.lua")() == "first")
end

local ok, message = pcall(run)
if not ok then
    results[#results + 1] = "FAIL  test aborted: " .. tostring(message)
    failed = true
end
results[#results + 1] = failed and "RESULT: FAILED" or "RESULT: passed"

local handle = fs.open("testresult.txt", "w")
handle.write(table.concat(results, "\n") .. "\n")
handle.close()
os.shutdown(failed and 1 or 0)
