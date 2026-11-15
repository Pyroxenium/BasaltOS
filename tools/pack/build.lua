-- Builds the packed BasaltOS image and, when a store repository is mounted,
-- the packed store. Runs inside CraftOS-PC; start it with tools/build.ps1.
--
-- Mounts expected:
--   /src    the "os" directory of this repository   (read-only)
--   /pack   this directory, tools/pack              (read-only)
--   /store  a BasaltOSStore checkout                (read-only, optional)
--   /out    the build directory                     (read-write)
--
-- Output:
--   /out/dist                  the OS image (root of a computer)
--   /out/dist-store            catalog.json and apps for the store
--   /out/install-manifest.txt  file list of the image for the installer
--   /out/build-report.txt
--
-- Package format and runtime: os/system/boot/bpk.lua.

local SOURCE = "src"
local STORE = "store"
local OUTPUT = "out/dist"
local STORE_OUTPUT = "out/dist-store"
local REPORT = "out/build-report.txt"
local MANIFEST = "out/install-manifest.txt"
local RUNTIME = "system/boot/bpk.lua"
local BOOT_LOADER = "startup.lua"
local CHAIN = 128

-- The build fails when the image outgrows this. A default CC:Tweaked
-- computer holds 1,000,000 bytes; half of that leaves room for user data,
-- logs and store apps.
local MAX_IMAGE_BYTES = 500000

-- Runtime state of a live installation; never part of an image.
local function isRuntimeState(path)
    return path == "system/config.dat"
        or path:match("^system/logs/")
        or path:match("^users/")
end

local lexer, minifier, compressor

-- Loaded inside main() so a failure here is reported instead of leaving the
-- headless emulator sitting at a shell prompt.
local function loadShale()
    local make = dofile("rom/modules/main/cc/require.lua").make
    local env = setmetatable({}, {__index=_G})
    local require, package = make(env, "/")
    env.require, env.package = require, package
    package.path = "/pack/?.lua;" .. package.path

    lexer = require("shale.lexer")
    minifier = require("shale.minifier")
    compressor = require("shale.compressor")
end

local function breathe()
    os.queueEvent("build_breath")
    os.pullEvent("build_breath")
end

local function readFile(path)
    local handle = assert(fs.open(path, "rb"), "cannot read " .. path)
    local data = handle.readAll() or ""
    handle.close()
    return data
end

local function writeFile(path, data)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local handle = assert(fs.open(path, "wb"), "cannot write " .. path)
    handle.write(data)
    handle.close()
end

local function walk(dir, relative, found)
    local names = fs.list(dir)
    table.sort(names)
    for _, name in ipairs(names) do
        local full = fs.combine(dir, name)
        local rel = relative == "" and name or (relative .. "/" .. name)
        if fs.isDir(full) then
            walk(full, rel, found)
        else
            found[#found + 1] = rel
        end
    end
    return found
end

local function significant(tokens)
    local result = {}
    for index = 1, #tokens do
        local token = tokens[index]
        if token.kind ~= "comment" and token.kind ~= "whitespace" and token.kind ~= "eof" then
            result[#result + 1] = token
        end
    end
    return result
end

-- Remove comments and indentation but keep every token on its original line,
-- so error messages and tracebacks still point at the right source line.
local function stripKeepingLines(source, name)
    local tokens = significant(lexer.lex(source, {sourceName=name}))
    local output, line, previous = {}, 1, nil
    for index = 1, #tokens do
        local token = tokens[index]
        if token.line > line then
            output[#output + 1] = ("\n"):rep(token.line - line)
        elseif minifier.needsSeparator(previous, token) then
            output[#output + 1] = " "
        end
        output[#output + 1] = token.text
        line = token.endLine or token.line
        previous = token
    end
    local generated = table.concat(output)

    local check = significant(lexer.lex(generated, {sourceName=name .. " (stripped)"}))
    if #check ~= #tokens then
        error(name .. ": token count changed while stripping", 0)
    end
    for index = 1, #tokens do
        local expected, actual = tokens[index], check[index]
        if expected.kind ~= actual.kind or expected.text ~= actual.text
            or expected.line ~= actual.line then
            error(("%s:%d: stripping changed token %d"):format(name, expected.line, index), 0)
        end
    end
    return generated
end

local written = {}  -- every package written, for the final runtime check

-- Write one package. files: {{path=..., data=...}}, paths relative to the
-- package folder when root is ".", to the computer root when it is "/".
local function writePackage(target, name, root, files, raw_bytes)
    table.sort(files, function(left, right) return left.path < right.path end)

    local index, parts = {}, {}
    for position, file in ipairs(files) do
        index[position] = #file.data .. " " .. file.path
        parts[position] = file.data
    end
    local body = table.concat(parts)
    local stream = compressor.compress(body, {chain=CHAIN, yield=breathe})

    local header = table.concat({
        "BPK1",
        name,
        root,
        -- %.0f: an Adler-32 value does not fit %d on Lua 5.1.
        ("%d %d %.0f %d"):format(#stream, #body, compressor.adler32(body), #files),
        table.concat(index, "\n"),
        "",
    }, "\n")
    writeFile(target, header .. stream)
    written[#written + 1] = {target=target, body=body}

    print(("packed %-40s %7d -> %6d"):format(target, raw_bytes, #header + #stream))
    return {
        target=target,
        files=#files,
        raw=raw_bytes,
        stripped=#body,
        packed=#header + #stream,
    }
end

-- Files the registry reads before an app is started. They stay ordinary
-- files, so listing installed apps never forces a package to be unpacked.
local function appFilesKeptOnDisk(app_dir)
    local keep = {["app.json"]=true}
    local manifest_path = fs.combine(app_dir, "app.json")
    if fs.exists(manifest_path) then
        local manifest = textutils.unserializeJSON(readFile(manifest_path))
        if type(manifest) == "table" then
            local function declare(value)
                if type(value) == "string" and value ~= "" then
                    keep[fs.combine("", value)] = true
                end
            end
            declare(manifest.icon)
            if type(manifest.icons) == "table" then
                for _, value in pairs(manifest.icons) do declare(value) end
            end
            if type(manifest.file_icon) == "table" then
                for _, value in pairs(manifest.file_icon) do declare(value) end
            else
                declare(manifest.file_icon)
            end
        end
    end
    for _, name in ipairs({"icon.bimg", "icon.flimg", "taskbar.bimg", "taskbar.flimg"}) do
        keep[name] = true
    end
    return keep
end

-- Pack one app folder: manifest and icons are copied, documentation is left
-- out, everything else (code and assets) goes into app.bpk.
-- only: optional set of app-relative paths to consider (the store catalog).
local function packApp(app_dir, output_dir, name, only)
    local keep = appFilesKeptOnDisk(app_dir)
    local packaged, raw_bytes = {}, 0
    local result = {source_files=0, source_bytes=0, out_files={}, out_bytes=0}

    for _, path in ipairs(walk(app_dir, "", {})) do
        if not only or only[path] then
            local data = readFile(fs.combine(app_dir, path))
            result.source_files = result.source_files + 1
            result.source_bytes = result.source_bytes + #data

            if keep[path] then
                writeFile(fs.combine(output_dir, path), data)
                result.out_files[#result.out_files + 1] = path
                result.out_bytes = result.out_bytes + #data
            elseif path:match("%.md$") then
                -- Documentation is not needed on the computer.
            else
                raw_bytes = raw_bytes + #data
                if path:match("%.lua$") then
                    data = stripKeepingLines(data, fs.combine(name, path))
                end
                packaged[#packaged + 1] = {path=path, data=data}
                breathe()
            end
        end
    end

    if #packaged > 0 then
        local row = writePackage(fs.combine(output_dir, "app.bpk"), name, ".", packaged, raw_bytes)
        result.out_files[#result.out_files + 1] = "app.bpk"
        result.out_bytes = result.out_bytes + row.packed
        result.package = row
    end
    table.sort(result.out_files)
    return result
end

local function buildImage(report)
    if fs.exists(OUTPUT) then fs.delete(OUTPUT) end
    fs.makeDir(OUTPUT)

    local totals = {source_bytes=0, source_files=0}
    local groups, order = {}, {}
    local rows = {}
    local boot_bytes = {}

    local function group(target, name)
        local entry = groups[target]
        if not entry then
            entry = {target=target, name=name, files={}, raw=0}
            groups[target] = entry
            order[#order + 1] = target
        end
        return entry
    end

    local apps = {}
    for _, path in ipairs(walk(SOURCE, "", {})) do
        if not isRuntimeState(path) then
            local app = path:match("^system/apps/([^/]+)/")
            if app then
                apps[app] = true
            else
                local data = readFile(fs.combine(SOURCE, path))
                totals.source_bytes = totals.source_bytes + #data
                totals.source_files = totals.source_files + 1
                if path == RUNTIME then
                    -- Needed before any package can be read, so the runtime
                    -- and the boot loader stay ordinary files.
                    data = minifier.minify(data, {sourceName=path})
                    writeFile(fs.combine(OUTPUT, path), data)
                    boot_bytes[path] = #data
                elseif path == BOOT_LOADER then
                    data = stripKeepingLines(data, path)
                    writeFile(fs.combine(OUTPUT, path), data)
                    boot_bytes[path] = #data
                elseif path:match("%.lua$") then
                    local entry
                    if path:match("^system/lib/public/obsidian/") then
                        entry = group("system/boot/obsidian.bpk", "Obsidian")
                    elseif path:match("^system/lib/public/") then
                        entry = group("system/boot/basalt.bpk", "Basalt")
                    else
                        entry = group("system/boot/system.bpk", "BasaltOS")
                    end
                    entry.files[#entry.files + 1] = {
                        path=path,
                        data=stripKeepingLines(data, path),
                    }
                    entry.raw = entry.raw + #data
                    breathe()
                else
                    writeFile(fs.combine(OUTPUT, path), data)
                end
            end
        end
    end
    assert(boot_bytes[RUNTIME], RUNTIME .. " is missing in the source tree")
    assert(boot_bytes[BOOT_LOADER], BOOT_LOADER .. " is missing in the source tree")

    table.sort(order)
    for _, target in ipairs(order) do
        local entry = groups[target]
        local row = writePackage(fs.combine(OUTPUT, target), entry.name, "/", entry.files, entry.raw)
        row.target = target
        rows[#rows + 1] = row
    end

    local app_ids = {}
    for app in pairs(apps) do app_ids[#app_ids + 1] = app end
    table.sort(app_ids)
    for _, app in ipairs(app_ids) do
        local relative = "system/apps/" .. app
        local result = packApp(fs.combine(SOURCE, relative), fs.combine(OUTPUT, relative), app)
        totals.source_bytes = totals.source_bytes + result.source_bytes
        totals.source_files = totals.source_files + result.source_files
        if result.package then
            result.package.target = relative .. "/app.bpk"
            rows[#rows + 1] = result.package
        end
    end

    local manifest = {
        "# BasaltOS installation manifest v1 (packed image)",
        "# Format: repository path|size in bytes",
    }
    local dist_files, dist_bytes = 0, 0
    for _, path in ipairs(walk(OUTPUT, "", {})) do
        local size = fs.getSize(fs.combine(OUTPUT, path))
        dist_files = dist_files + 1
        dist_bytes = dist_bytes + size
        manifest[#manifest + 1] = "os/" .. path .. "|" .. size
    end
    writeFile(MANIFEST, table.concat(manifest, "\n") .. "\n")

    report[#report + 1] = "OS IMAGE"
    report[#report + 1] = ""
    report[#report + 1] = ("%-38s %5s %9s %9s %9s"):format(
        "package", "files", "source", "stripped", "packed")
    local sum = {files=0, raw=0, stripped=0, packed=0}
    for _, row in ipairs(rows) do
        report[#report + 1] = ("%-38s %5d %9d %9d %9d"):format(
            row.target, row.files, row.raw, row.stripped, row.packed)
        for key in pairs(sum) do sum[key] = sum[key] + row[key] end
    end
    report[#report + 1] = ("%-38s %5d %9d %9d %9d"):format(
        "all packages", sum.files, sum.raw, sum.stripped, sum.packed)
    report[#report + 1] = ""
    report[#report + 1] = ("manifests, icons, other assets: %4d files %9d bytes"):format(
        dist_files - #rows - 2,
        dist_bytes - sum.packed - boot_bytes[RUNTIME] - boot_bytes[BOOT_LOADER])
    report[#report + 1] = ("runtime (bpk.lua):                         %9d bytes"):format(
        boot_bytes[RUNTIME])
    report[#report + 1] = ("boot loader (startup.lua):                 %9d bytes"):format(
        boot_bytes[BOOT_LOADER])
    report[#report + 1] = ""
    report[#report + 1] = ("source tree:                    %4d files %9d bytes"):format(
        totals.source_files, totals.source_bytes)
    report[#report + 1] = ("packed image:                   %4d files %9d bytes"):format(
        dist_files, dist_bytes)
    report[#report + 1] = ("packed / source:                %.1f %%"):format(
        dist_bytes / totals.source_bytes * 100)
    report[#report + 1] = ("size budget:                    %d bytes, %d left"):format(
        MAX_IMAGE_BYTES, MAX_IMAGE_BYTES - dist_bytes)

    if dist_bytes > MAX_IMAGE_BYTES then
        error(("image is %d bytes, over the budget of %d"):format(dist_bytes, MAX_IMAGE_BYTES), 0)
    end
end

local function buildStore(report)
    local catalog_path = fs.combine(STORE, "catalog.json")
    if fs.exists(STORE_OUTPUT) then fs.delete(STORE_OUTPUT) end
    if not fs.exists(catalog_path) then
        report[#report + 1] = ""
        report[#report + 1] = "STORE: no store repository mounted, skipped"
        return
    end
    fs.makeDir(STORE_OUTPUT)

    local catalog = assert(textutils.unserializeJSON(readFile(catalog_path)), "catalog.json is invalid")
    report[#report + 1] = ""
    report[#report + 1] = "STORE"
    report[#report + 1] = ""
    report[#report + 1] = ("%-16s %14s %14s %7s"):format("app", "catalog files", "packed files", "ratio")

    local sum = {source_files=0, source_bytes=0, out_files=0, out_bytes=0}
    for _, app in ipairs(catalog.apps or {}) do
        local source = type(app.source) == "table" and app.source or {}
        local relative = source.path or ("apps/" .. tostring(app.id))
        local app_dir = fs.combine(STORE, relative)
        if fs.exists(app_dir) and fs.isDir(app_dir) then
            local only = {}
            for _, file in ipairs(source.files or {}) do only[fs.combine("", file)] = true end

            local result = packApp(app_dir, fs.combine(STORE_OUTPUT, relative), tostring(app.id), only)
            source.files = result.out_files

            report[#report + 1] = ("%-16s %3d %10d %3d %10d %6.1f%%"):format(
                tostring(app.id), result.source_files, result.source_bytes,
                #result.out_files, result.out_bytes,
                result.source_bytes > 0 and result.out_bytes / result.source_bytes * 100 or 0)
            sum.source_files = sum.source_files + result.source_files
            sum.source_bytes = sum.source_bytes + result.source_bytes
            sum.out_files = sum.out_files + #result.out_files
            sum.out_bytes = sum.out_bytes + result.out_bytes
        else
            report[#report + 1] = ("%-16s source folder missing, skipped"):format(tostring(app.id))
        end
    end
    report[#report + 1] = ("%-16s %3d %10d %3d %10d %6.1f%%"):format(
        "all store apps", sum.source_files, sum.source_bytes, sum.out_files, sum.out_bytes,
        sum.source_bytes > 0 and sum.out_bytes / sum.source_bytes * 100 or 0)

    writeFile(fs.combine(STORE_OUTPUT, "catalog.json"), textutils.serializeJSON(catalog))
end

local function main()
    local started = os.epoch("utc")
    loadShale()

    local report = {"BasaltOS packed build - report", ""}
    buildImage(report)
    buildStore(report)

    -- Verify every package with the runtime that will actually ship.
    local shipped = dofile(fs.combine(OUTPUT, RUNTIME))
    for _, entry in ipairs(written) do
        local mounted = assert(shipped.mount(entry.target))
        shipped.unpack(mounted)
        if mounted.data ~= entry.body then
            error("runtime roundtrip failed for " .. entry.target, 0)
        end
        breathe()
    end

    report[#report + 1] = ""
    report[#report + 1] = ("%d packages verified with the shipped runtime"):format(#written)
    report[#report + 1] = ("build time: %.1f s"):format((os.epoch("utc") - started) / 1000)
    writeFile(REPORT, table.concat(report, "\n") .. "\n")
    print("build finished, report written to " .. REPORT)
end

local ok, message = pcall(main)
if not ok then
    print("BUILD FAILED: " .. tostring(message))
    local handle = fs.open(REPORT, "w")
    if handle then
        handle.write("BUILD FAILED: " .. tostring(message) .. "\n")
        handle.close()
    end
end
os.shutdown(ok and 0 or 1)
