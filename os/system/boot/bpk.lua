-- BasaltOS package runtime.
--
-- A .bpk file is a compressed archive of Lua sources and assets. Mounted
-- packages are unpacked into memory only; a read-only overlay on the global
-- `fs` API makes their files visible at their original paths. loadfile,
-- require and every OS service therefore keep working without knowing that
-- packages exist.
--
-- File layout (binary):
--   BPK1\n
--   <package name>\n
--   <root>\n                             "/" paths start at the computer root
--                                        "." paths start at the package's folder
--   <stream bytes> <original bytes> <adler32> <file count>\n
--   <file bytes> <file path>\n          (file count times)
--   <compressed stream>                  (stream bytes)
--
-- App packages (<apps folder>/<id>/app.bpk) must use "." so the same package
-- works under system/apps and under a user's apps folder, and so an app can
-- never provide files outside its own folder. Packages are written by
-- tools/pack/build.lua.

local bpk = {VERSION=1}

local byte, sub, char, find, match = string.byte, string.sub, string.char, string.find, string.match
local concat, floor = table.concat, math.floor

local BREATH = 16384

-- Huffman-coded LZSS stream (stream version 2). This is the decoder of
-- tools/pack/shale/huffman.lua; the build unpacks every package it writes
-- with this file, so the two cannot drift apart unnoticed.
local function decodeEntropy(source, breathe, max_output)
    local position, size = 2, #source
    local hold, bits = 0, 0

    -- Reads may legitimately run a little past the last byte, because the
    -- decoder peeks a fixed width before it knows the code is shorter. Any
    -- more than that means the stream ended early, and without this bound a
    -- corrupt stream would be fed zero bits forever and never terminate.
    local limit = size + 3

    local function need(width)
        while bits < width do
            if position > limit then
                error("Corrupt package (truncated stream)", 0)
            end
            local value = position <= size and byte(source, position) or 0
            position = position + 1
            hold = hold * 256 + value
            bits = bits + 8
        end
    end

    local function take(width)
        need(width)
        local shift = bits - width
        local value = floor(hold / 2 ^ shift)
        hold = hold - value * 2 ^ shift
        bits = shift
        return value
    end

    local function readLengths(count)
        local lengths, index = {}, 0
        while index < count do
            local length = take(4)
            if length == 0 then
                local run = take(7)
                for _ = 0, run do
                    if index >= count then break end
                    lengths[index] = 0
                    index = index + 1
                end
            else
                lengths[index] = length
                index = index + 1
            end
        end
        return lengths
    end

    local function buildDecoder(lengths, count)
        local counts, symbols = {}, {}
        for length = 0, 15 do counts[length] = 0 end
        for symbol = 0, count - 1 do
            local length = lengths[symbol]
            if length > 0 then counts[length] = counts[length] + 1 end
        end

        -- A valid prefix code never claims more slots than the tree has.
        -- Checking here turns a corrupt header into a clean error instead of
        -- a decoder that wanders off into nonsense symbols.
        local left = 1
        for length = 1, 15 do
            left = left * 2 - counts[length]
            if left < 0 then
                error("Corrupt package (over-subscribed code)", 0)
            end
        end

        local offsets, total = {}, 0
        for length = 1, 15 do
            offsets[length] = total
            total = total + counts[length]
        end
        for symbol = 0, count - 1 do
            local length = lengths[symbol]
            if length > 0 then
                symbols[offsets[length]] = symbol
                offsets[length] = offsets[length] + 1
            end
        end

        local root = {}
        local first, index = 0, 0
        for length = 1, 10 do
            local amount = counts[length]
            local span = 2 ^ (10 - length)
            for offset = 0, amount - 1 do
                local packed = symbols[index + offset] * 16 + length
                local base = (first + offset) * span
                for fill = 0, span - 1 do
                    root[base + fill] = packed
                end
            end
            index = index + amount
            first = (first + amount) * 2
        end

        return {counts=counts, symbols=symbols, root=root}
    end

    local function decode(decoder)
        need(10)
        local packed = decoder.root[floor(hold / 2 ^ (bits - 10))]
        if packed then
            local length = packed % 16
            local shift = bits - length
            hold = hold - floor(hold / 2 ^ shift) * 2 ^ shift
            bits = shift
            return (packed - length) / 16
        end

        local code, index, first = 0, 0, 0
        for length = 1, 15 do
            code = code * 2 + take(1)
            local amount = decoder.counts[length]
            if code - first < amount then
                return decoder.symbols[index + code - first]
            end
            index = index + amount
            first = (first + amount) * 2
        end
        error("Corrupt package (bad Huffman code)", 0)
    end

    local literals = buildDecoder(readLengths(513), 513)
    local distances = buildDecoder(readLengths(256), 256)

    local output, count = {}, 0
    local next_breath = BREATH
    while true do
        local symbol = decode(literals)
        if symbol == 512 then break end

        if symbol < 256 then
            count = count + 1
            output[count] = char(symbol)
        else
            local length = symbol - 252
            local distance = decode(distances) * 256 + take(8)
            if distance < 1 or distance > count then
                error("Corrupt package (invalid distance)", 0)
            end
            local start = count - distance + 1
            for index = start, start + length - 1 do
                count = count + 1
                output[count] = output[index]
            end
        end

        -- A stream may never grow beyond the size its header announced;
        -- this keeps a hostile download from filling the memory.
        if count > max_output then
            error("Corrupt package (stream longer than announced)", 0)
        end
        if breathe and count > next_breath then
            breathe()
            next_breath = count + BREATH
        end
    end

    return concat(output)
end

-- Plain LZSS stream (stream version 1).
local function decodeFlat(source, breathe, max_output)
    local output, count = {}, 0
    local position, size = 2, #source
    local next_breath = BREATH
    while position <= size do
        local control = byte(source, position)
        position = position + 1
        for _ = 1, 8 do
            if position > size then break end
            if control % 2 == 1 then
                if position + 2 > size then
                    error("Corrupt package (truncated match)", 0)
                end
                local distance = byte(source, position) * 256 + byte(source, position + 1)
                local length = byte(source, position + 2) + 4
                position = position + 3
                if distance < 1 or distance > count then
                    error("Corrupt package (invalid distance)", 0)
                end
                local start = count - distance + 1
                for index = start, start + length - 1 do
                    count = count + 1
                    output[count] = output[index]
                end
            else
                count = count + 1
                output[count] = sub(source, position, position)
                position = position + 1
            end
            control = (control - control % 2) / 2
        end
        if count > max_output then
            error("Corrupt package (stream longer than announced)", 0)
        end
        if breathe and count > next_breath then
            breathe()
            next_breath = count + BREATH
        end
    end
    return concat(output)
end

local function adler32(input)
    local a, b = 1, 0
    local size = #input
    local position = 1
    while position <= size do
        -- Sums stay far below 2^53 for a block, so one modulo per block is enough.
        local stop = position + 5551
        if stop > size then stop = size end
        for index = position, stop do
            a = a + byte(input, index)
            b = b + a
        end
        a = a % 65521
        b = b % 65521
        position = stop + 1
    end
    return b * 65536 + a
end

local native = {}
for name, value in pairs(fs) do native[name] = value end
bpk.native = native

local files = {}     -- normalized path -> {package, offset, length}
local dirs = {}      -- normalized path -> {child name -> true}
local packages = {}  -- mounted packages in mount order
local installed = false

local function normalize(path)
    return native.combine("", path)
end

-- Packages are picked up automatically only where BasaltOS keeps apps:
-- .../apps/<id>/app.bpk. A package sitting in a download or staging folder
-- stays an ordinary file until the app is installed.
local function isAppPackage(path)
    return match("/" .. normalize(path), "/apps/[^/]+/app%.bpk$") ~= nil
end

-- A packaged path may only lead downwards from its root. It must also be
-- written exactly the way fs.combine would write it: combine drops some
-- characters, which could otherwise turn a harmless looking name into "..".
local function isSafePath(path)
    if path == "" or sub(path, 1, 1) == "/" or find(path, "\\", 1, true)
        or find(path, "//", 1, true) or sub(path, -1) == "/" then
        return false
    end
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." then return false end
    end
    return native.combine("", path) == path
end

-- Read the header and file index of a package without touching its stream.
local function readHeader(path)
    local handle = native.open(path, "rb")
    if not handle then return nil, "Cannot open package: " .. tostring(path) end
    local raw = handle.readAll() or ""
    handle.close()

    local position = 1
    local function line()
        local stop = find(raw, "\n", position, true)
        if not stop then return nil end
        local text = sub(raw, position, stop - 1)
        position = stop + 1
        return text
    end

    if line() ~= "BPK1" then return nil, "Not a BasaltOS package: " .. tostring(path) end
    local name = line()
    local root = line()
    local stream_length, original_length, checksum, count =
        match(line() or "", "^(%d+) (%d+) (%d+) (%d+)$")
    if not count or (root ~= "/" and root ~= ".") then
        return nil, "Corrupt package header: " .. tostring(path)
    end
    if root ~= "." and isAppPackage(path) then
        return nil, "App packages must use relative paths: " .. tostring(path)
    end

    local header = {
        name=name,
        root=root,
        path=normalize(path),
        stream_length=tonumber(stream_length),
        original_length=tonumber(original_length),
        checksum=tonumber(checksum),
        file_count=tonumber(count),
        entries={},
    }

    local total, seen, folders = 0, {}, {}
    for index = 1, header.file_count do
        local length, file_path = match(line() or "", "^(%d+) (.+)$")
        if not length or not isSafePath(file_path) or seen[file_path] then
            return nil, "Corrupt package index: " .. tostring(path)
        end
        length = tonumber(length)
        header.entries[index] = {path=file_path, length=length}
        total = total + length

        seen[file_path] = true
        local folder = native.getDir(file_path)
        while folder ~= "" and not folders[folder] do
            folders[folder] = true
            folder = native.getDir(folder)
        end
    end
    if total ~= header.original_length then
        return nil, "Corrupt package index: " .. tostring(path)
    end
    -- Nothing may be a file and a folder at the same time.
    for file_path in pairs(seen) do
        if folders[file_path] then
            return nil, "Corrupt package index: " .. tostring(path)
        end
    end
    header.body_offset = position
    return header
end

local function registerDirs(path)
    local child = native.getName(path)
    local parent = native.getDir(path)
    while true do
        local entries = dirs[parent]
        if not entries then
            entries = {}
            dirs[parent] = entries
        end
        if entries[child] then return end
        entries[child] = true
        if parent == "" then return end
        child = native.getName(parent)
        parent = native.getDir(parent)
    end
end

local function decodeStream(package, stream, breathe)
    local version = byte(stream, 1)
    local data
    if package.original_length == 0 then
        data = ""
    elseif version == 2 then
        data = decodeEntropy(stream, breathe, package.original_length)
    elseif version == 1 then
        data = decodeFlat(stream, breathe, package.original_length)
    else
        error("Corrupt package (unknown stream version)", 0)
    end

    if #data ~= package.original_length then
        error("Corrupt package (length mismatch)", 0)
    end
    if adler32(data) ~= package.checksum then
        error("Corrupt package (checksum mismatch)", 0)
    end
    return data
end

local function unpackPackage(package, progress)
    if package.data then return package.data end
    -- A damaged package stays damaged; do not decode it again on every read.
    if package.failure then error(package.failure, 0) end

    local handle = native.open(package.path, "rb")
    if not handle then
        error("Package is no longer readable: " .. package.path, 0)
    end
    local raw = handle.readAll() or ""
    handle.close()

    local stream = sub(raw, package.body_offset, package.body_offset + package.stream_length - 1)
    raw = nil
    if #stream ~= package.stream_length then
        package.failure = "Corrupt package (truncated stream): " .. package.path
        error(package.failure, 0)
    end

    local started = os.epoch and os.epoch("utc") or 0
    local breathe
    if progress then
        local done = 0
        breathe = function()
            done = done + BREATH
            if done > package.original_length then done = package.original_length end
            progress(package, done, package.original_length)
        end
    end

    local ok, data = pcall(decodeStream, package, stream, breathe)
    if not ok then
        package.failure = tostring(data) .. ": " .. package.path
        error(package.failure, 0)
    end

    package.data = data
    package.unpack_ms = (os.epoch and os.epoch("utc") or 0) - started
    if progress then progress(package, package.original_length, package.original_length) end
    return data
end

local function content(entry)
    local data = unpackPackage(entry.package)
    return sub(data, entry.offset, entry.offset + entry.length - 1)
end

local function register(package)
    for _, entry in ipairs(package.index) do
        files[entry.path] = {package=package, offset=entry.offset, length=entry.length}
        registerDirs(entry.path)
    end
end

-- Two packages may provide the same path; the one mounted last wins. The
-- tables are rebuilt from every remaining package so the earlier one takes
-- over again when the later one goes away.
local function unmount(package)
    for index = #packages, 1, -1 do
        if packages[index] == package then table.remove(packages, index) end
    end
    files, dirs = {}, {}
    for _, remaining in ipairs(packages) do register(remaining) end
end

--- Remove a mounted package and every file it provides.
function bpk.unmount(path)
    local normalized = normalize(path)
    for index = #packages, 1, -1 do
        if packages[index].path == normalized then unmount(packages[index]) end
    end
end

--- Read a package header and register its files. The stream itself is
--- unpacked on first access, or earlier through bpk.unpack.
function bpk.mount(path, options)
    options = options or {}
    bpk.unmount(path)
    local package, reason = readHeader(path)
    if not package then return nil, reason end

    local base = package.root == "." and native.getDir(package.path) or ""
    local index, offset = {}, 1
    for position, entry in ipairs(package.entries) do
        local file_path = native.combine(base, entry.path)
        -- readHeader has vetted the paths; this is the second lock on the
        -- rule that a package never reaches outside its own folder.
        if base ~= "" and sub(file_path, 1, #base + 1) ~= base .. "/" then
            return nil, "Corrupt package index: " .. tostring(path)
        end
        index[position] = {path=file_path, offset=offset, length=entry.length}
        offset = offset + entry.length
    end
    package.entries = nil
    package.index = index
    package.eager = options.eager == true

    packages[#packages + 1] = package
    register(package)
    return package
end

--- Unpack a mounted package now instead of on first access.
--- progress(package, done_bytes, total_bytes) is called roughly every 16 KiB.
function bpk.unpack(package, progress)
    unpackPackage(package, progress)
    return true
end

--- Describe a package file anywhere on disk without mounting it:
--- {name, root, file_count, stream_length, original_length, files}, where
--- files maps each packaged path to its size. With verify set, the stream is
--- unpacked once to prove that the package is complete and undamaged.
function bpk.inspect(path, verify)
    local package, reason = readHeader(path)
    if not package then return nil, reason end

    if verify then
        local ok, unpack_error = pcall(unpackPackage, package)
        package.data = nil
        if not ok then return nil, tostring(unpack_error) end
    end

    local listed = {}
    for _, entry in ipairs(package.entries) do listed[entry.path] = entry.length end
    return {
        name=package.name,
        root=package.root,
        file_count=package.file_count,
        stream_length=package.stream_length,
        original_length=package.original_length,
        files=listed,
    }
end

local function stringHandle(data, binary)
    local position, closed = 1, false
    local size = #data
    local handle = {}

    local function check()
        if closed then error("attempt to use a closed file", 3) end
    end

    function handle.readAll()
        check()
        if position > size then
            if size == 0 and position == 1 then
                position = 2
                return ""
            end
            return nil
        end
        local text = sub(data, position)
        position = size + 1
        return text
    end

    function handle.readLine(with_trailing)
        check()
        if position > size then return nil end
        local stop = find(data, "\n", position, true)
        local text
        if stop then
            text = sub(data, position, with_trailing and stop or stop - 1)
            -- Like a real file handle, treat "\r\n" as one line ending.
            if not with_trailing and sub(text, -1) == "\r" then text = sub(text, 1, -2) end
            position = stop + 1
        else
            text = sub(data, position)
            position = size + 1
        end
        return text
    end

    function handle.read(count)
        check()
        if position > size then return nil end
        if count == nil then
            local value
            if binary then
                value = byte(data, position)
            else
                value = sub(data, position, position)
            end
            position = position + 1
            return value
        end
        local text = sub(data, position, position + count - 1)
        position = position + count
        return text
    end

    function handle.seek(whence, offset)
        check()
        whence, offset = whence or "cur", offset or 0
        local target
        if whence == "set" then
            target = offset
        elseif whence == "cur" then
            target = position - 1 + offset
        elseif whence == "end" then
            target = size + offset
        else
            error("bad argument #1 to 'seek' (invalid option '" .. tostring(whence) .. "')", 2)
        end
        if target < 0 then return nil, "Position is negative" end
        position = target + 1
        return target
    end

    function handle.close()
        check()
        closed = true
    end

    return handle
end

local function virtualFile(path)
    if native.exists(path) then return nil end
    return files[normalize(path)]
end

local function virtualDir(path)
    if native.exists(path) then return nil end
    return dirs[normalize(path)]
end

-- Mount every app package that has just appeared at or below a path.
local function adopt(path)
    if not native.exists(path) then return end
    if native.isDir(path) then
        for _, name in ipairs(native.list(path)) do
            adopt(native.combine(path, name))
        end
    elseif isAppPackage(path) then
        bpk.mount(path)
    end
end

local function prune()
    for index = #packages, 1, -1 do
        if not native.exists(packages[index].path) then unmount(packages[index]) end
    end
end

--- Patch the global fs table in place. Real files always win over packaged
--- ones, so a file dropped next to a package overrides it during development.
function bpk.install()
    if installed then return end
    installed = true

    function fs.exists(path)
        if native.exists(path) then return true end
        local normalized = normalize(path)
        return files[normalized] ~= nil or dirs[normalized] ~= nil
    end

    function fs.isDir(path)
        if native.exists(path) then return native.isDir(path) end
        return dirs[normalize(path)] ~= nil
    end

    function fs.list(path)
        local entries = dirs[normalize(path)]
        local on_disk = native.exists(path)
        if not entries or (on_disk and not native.isDir(path)) then
            return native.list(path)
        end

        local seen, result = {}, {}
        if on_disk then
            for _, name in ipairs(native.list(path)) do
                seen[name] = true
                result[#result + 1] = name
            end
        end
        for name in pairs(entries) do
            if not seen[name] then result[#result + 1] = name end
        end
        table.sort(result)
        return result
    end

    function fs.getSize(path)
        local entry = virtualFile(path)
        if entry then return entry.length end
        if virtualDir(path) then return 0 end
        return native.getSize(path)
    end

    function fs.isReadOnly(path)
        if virtualFile(path) or virtualDir(path) then return true end
        return native.isReadOnly(path)
    end

    function fs.getDrive(path)
        if virtualFile(path) or virtualDir(path) then return "hdd" end
        return native.getDrive(path)
    end

    if native.attributes then
        function fs.attributes(path)
            local entry = virtualFile(path)
            local directory = not entry and virtualDir(path)
            if not entry and not directory then return native.attributes(path) end
            return {
                size=entry and entry.length or 0,
                isDir=directory and true or false,
                isReadOnly=true,
                created=0,
                modified=0,
                modification=0,
            }
        end
    end

    function fs.open(path, mode)
        if mode == "r" or mode == "rb" then
            local entry = virtualFile(path)
            if entry then return stringHandle(content(entry), mode == "rb") end
            return native.open(path, mode)
        end

        -- Writing to a packaged file creates a real file that overrides it.
        -- Modes that keep the old content get that content to start from.
        if mode == "a" or mode == "ab" or mode == "r+" or mode == "r+b" then
            local entry = virtualFile(path)
            if entry then
                local copy = native.open(path, "wb")
                if copy then
                    copy.write(content(entry))
                    copy.close()
                end
            end
        end

        local handle, reason = native.open(path, mode)
        if handle and isAppPackage(path) then
            -- A package written in place (for example by an updater) becomes
            -- visible as soon as the writer closes it.
            local close = handle.close
            handle.close = function(...)
                close(...)
                adopt(path)
            end
        end
        return handle, reason
    end

    function fs.copy(source, destination)
        local entry = virtualFile(source)
        if entry then
            if fs.exists(destination) then error("File exists", 2) end
            local handle = native.open(destination, "wb")
            if not handle then error("/" .. normalize(destination) .. ": Access denied", 2) end
            handle.write(content(entry))
            handle.close()
        elseif virtualDir(source) then
            -- A folder that exists only inside a package: copy it out file by file.
            if fs.exists(destination) then error("File exists", 2) end
            native.makeDir(destination)
            for _, name in ipairs(fs.list(source)) do
                fs.copy(native.combine(source, name), native.combine(destination, name))
            end
        else
            native.copy(source, destination)
            adopt(destination)
        end
    end

    function fs.move(source, destination)
        if virtualFile(source) or virtualDir(source) then
            error("/" .. normalize(source) .. ": Access denied", 2)
        end
        native.move(source, destination)
        prune()
        adopt(destination)
    end

    function fs.delete(path)
        if virtualFile(path) or virtualDir(path) then
            error("/" .. normalize(path) .. ": Access denied", 2)
        end
        native.delete(path)
        prune()
    end
end

--- Whether a path is served from a package.
function bpk.isPackaged(path)
    return virtualFile(path) ~= nil
end

--- Summary of all mounted packages, for diagnostics.
function bpk.stats()
    local result = {}
    for index, package in ipairs(packages) do
        result[index] = {
            name=package.name,
            path=package.path,
            eager=package.eager,
            unpacked=package.data ~= nil,
            file_count=package.file_count,
            stream_length=package.stream_length,
            original_length=package.original_length,
            unpack_ms=package.unpack_ms,
        }
    end
    return result
end

return bpk
