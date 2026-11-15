local huffman = require("shale.huffman")

local compressor = {}

local DEFAULT_WINDOW = 65535
local DEFAULT_CHAIN = 128
local MIN_MATCH = 4
local MAX_MATCH = 259

local byte, sub, char = string.byte, string.sub, string.char
local concat = table.concat

--- Calculate Adler-32 without requiring bitwise operations.
---
--- @param input string
--- @return number
function compressor.adler32(input)
    if type(input) ~= "string" then
        error("bad argument #1 to 'adler32' (string expected)", 2)
    end
    local a, b = 1, 0
    for position = 1, #input do
        a = (a + input:byte(position)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

local function positiveInteger(value, default, name, maximum)
    if value == nil then return default end
    if type(value) ~= "number"
        or value < 1
        or value ~= math.floor(value)
        or (maximum and value > maximum) then
        error(name .. " must be a positive integer"
            .. (maximum and (" up to " .. maximum) or ""), 3)
    end
    return value
end

local function remember(positions, input, at, inputLength, chain)
    if at + 2 > inputLength then return end
    local key = sub(input, at, at + 2)
    local list = positions[key]
    if not list then
        list = {
            count = 0,
            cursor = 1,
        }
        positions[key] = list
    end

    list[list.cursor] = at
    list.cursor = list.cursor % chain + 1
    if list.count < chain then list.count = list.count + 1 end
end

local function candidateAt(list, offset, chain)
    local slot = (list.cursor - 2 - offset) % chain + 1
    return list[slot]
end

--- Find the longest match for the three-byte prefix at `position`.
---
--- Candidates are visited most-recent first, so distances only grow and the
--- window check can stop the scan outright.
---
--- @return number|nil distance
--- @return number|nil length
local function longestMatch(input, positions, position, inputLength, window, chain)
    if position + MIN_MATCH - 1 > inputLength then return nil end

    local candidates = positions[sub(input, position, position + 2)]
    if not candidates then return nil end

    local maximum = math.min(MAX_MATCH, inputLength - position + 1)
    local bestDistance, bestLength
    for offset = 0, candidates.count - 1 do
        local previous = candidateAt(candidates, offset, chain)
        local distance = position - previous
        if distance > window then break end

        local matched = 3
        while matched < maximum
            and byte(input, previous + matched)
                == byte(input, position + matched) do
            matched = matched + 1
        end
        if matched >= MIN_MATCH
            and (not bestLength or matched > bestLength) then
            bestDistance = distance
            bestLength = matched
            if matched == maximum then break end
        end
    end

    return bestDistance, bestLength
end

local function encodeFlat(symbols, distances, tokenCount)
    local output, count = { "\1" }, 1
    local index = 1
    while index <= tokenCount do
        local control, body = 0, {}
        for bit = 0, 7 do
            local symbol = symbols[index]
            if not symbol then break end
            if symbol < 256 then
                body[#body + 1] = char(symbol)
            else
                control = control + 2 ^ bit
                local distance = distances[index]
                body[#body + 1] = char(
                    math.floor(distance / 256),
                    distance % 256,
                    symbol - 256
                )
            end
            index = index + 1
        end
        count = count + 1
        output[count] = char(control) .. concat(body)
    end
    return concat(output)
end

local function encodeEntropy(symbols, distances, tokenCount)
    local symbolFrequencies, distanceFrequencies = {}, {}
    for symbol = 0, huffman.SYMBOL_COUNT - 1 do
        symbolFrequencies[symbol] = 0
    end
    for value = 0, huffman.DISTANCE_COUNT - 1 do
        distanceFrequencies[value] = 0
    end

    for index = 1, tokenCount do
        local symbol = symbols[index]
        symbolFrequencies[symbol] = symbolFrequencies[symbol] + 1
        if symbol >= 256 then
            local high = math.floor(distances[index] / 256)
            distanceFrequencies[high] = distanceFrequencies[high] + 1
        end
    end
    symbolFrequencies[huffman.END_OF_STREAM] = 1

    local symbolLengths, symbolMax = huffman.codeLengths(
        symbolFrequencies,
        huffman.SYMBOL_COUNT
    )
    local distanceLengths, distanceMax = huffman.codeLengths(
        distanceFrequencies,
        huffman.DISTANCE_COUNT
    )
    local symbolCodes = huffman.canonicalCodes(
        symbolLengths,
        huffman.SYMBOL_COUNT,
        symbolMax
    )
    local distanceCodes = huffman.canonicalCodes(
        distanceLengths,
        huffman.DISTANCE_COUNT,
        distanceMax
    )

    local writer = huffman.writer()
    huffman.writeLengths(writer, symbolLengths, huffman.SYMBOL_COUNT)
    huffman.writeLengths(writer, distanceLengths, huffman.DISTANCE_COUNT)

    for index = 1, tokenCount do
        local symbol = symbols[index]
        writer.write(symbolCodes[symbol], symbolLengths[symbol])
        if symbol >= 256 then
            local distance = distances[index]
            local high = math.floor(distance / 256)
            writer.write(distanceCodes[high], distanceLengths[high])
            writer.write(distance % 256, 8)
        end
    end
    writer.write(
        symbolCodes[huffman.END_OF_STREAM],
        symbolLengths[huffman.END_OF_STREAM]
    )

    return "\2" .. writer.finish()
end

--- Compress a byte string with Shale's bounded LZSS stream.
---
--- The stream stores one control byte per eight tokens. A set control bit is
--- followed by a two-byte distance and one-byte length (4..259); a clear bit
--- is followed by one literal byte.
---
--- Options:
--- - window: match distance, up to 65535.
--- - chain: maximum candidates retained per three-byte prefix.
--- - lazy: false disables lazy match selection. Enabled by default, it emits
---   a literal whenever the next position starts a longer match, which costs
---   a second search per position and buys roughly five percent.
--- - entropy: true or false forces the coded or flat stream. Left unset, both
---   are built and the smaller wins.
--- - entropyOverhead: extra bytes the caller pays for the entropy decoder,
---   counted against it when choosing automatically.
--- - yield: optional callback invoked periodically during long builds.
--- - validate: false skips the post-compression roundtrip check.
---
--- @param input string
--- @param options? table
--- @return string, table
function compressor.compress(input, options)
    if type(input) ~= "string" then
        error("bad argument #1 to 'compress' (string expected)", 2)
    end
    if options ~= nil and type(options) ~= "table" then
        error("bad argument #2 to 'compress' (table expected)", 2)
    end

    options = options or {}
    local window = positiveInteger(
        options.window,
        DEFAULT_WINDOW,
        "window",
        65535
    )
    local chain = positiveInteger(
        options.chain,
        DEFAULT_CHAIN,
        "chain",
        512
    )
    local yieldCallback = options.yield
    if yieldCallback ~= nil and type(yieldCallback) ~= "function" then
        error("yield must be a function", 2)
    end
    local lazy = options.lazy ~= false

    local symbols, distances, tokenCount = {}, {}, 0
    local positions = {}
    local position, inputLength = 1, #input
    local literalCount, matchCount, matchedBytes = 0, 0, 0
    local nextYield = 16384

    while position <= inputLength do
        if yieldCallback and position >= nextYield then
            yieldCallback(position, inputLength)
            nextYield = position + 16384
        end

        do
            local bestDistance, bestLength = longestMatch(
                input,
                positions,
                position,
                inputLength,
                window,
                chain
            )

            if bestLength and lazy and position < inputLength then
                local _, aheadLength = longestMatch(
                    input,
                    positions,
                    position + 1,
                    inputLength,
                    window,
                    chain
                )
                if aheadLength and aheadLength > bestLength then
                    bestDistance, bestLength = nil, nil
                end
            end

            local consumed
            tokenCount = tokenCount + 1
            if bestLength then
                symbols[tokenCount] = 256 + bestLength - MIN_MATCH
                distances[tokenCount] = bestDistance
                consumed = bestLength
                matchCount = matchCount + 1
                matchedBytes = matchedBytes + bestLength
            else
                symbols[tokenCount] = byte(input, position)
                consumed = 1
                literalCount = literalCount + 1
            end

            for offset = 0, consumed - 1 do
                remember(
                    positions,
                    input,
                    position + offset,
                    inputLength,
                    chain
                )
            end
            position = position + consumed
        end
    end

    local entropy, compressed, flatBytes, entropyBytes
    if options.entropy == true or options.entropy == false then
        entropy = options.entropy
        compressed = entropy
            and encodeEntropy(symbols, distances, tokenCount)
            or encodeFlat(symbols, distances, tokenCount)
    else
        local coded = encodeEntropy(symbols, distances, tokenCount)
        local flat = encodeFlat(symbols, distances, tokenCount)
        flatBytes, entropyBytes = #flat, #coded
        entropy = #coded + (options.entropyOverhead or 0) < #flat
        compressed = entropy and coded or flat
    end

    if options.validate ~= false then
        local restored = compressor.decompress(compressed)
        if restored ~= input then
            error("compressor roundtrip validation failed", 0)
        end
    end

    return compressed, {
        inputBytes = #input,
        outputBytes = #compressed,
        savedBytes = #input - #compressed,
        ratio = #input == 0 and 1 or #compressed / #input,
        literalCount = literalCount,
        matchCount = matchCount,
        matchedBytes = matchedBytes,
        tokenCount = tokenCount,
        window = window,
        chain = chain,
        lazy = lazy,
        entropy = entropy,
        entropyBytes = entropyBytes,
        flatBytes = flatBytes,
        version = entropy and 2 or 1,
        checksum = compressor.adler32(input),
    }
end

--- Decompress a Shale LZSS byte stream.
---
--- @param source string
--- @return string
function compressor.decompress(source)
    if type(source) ~= "string" then
        error("bad argument #1 to 'decompress' (string expected)", 2)
    end

    if source == "" then return "" end

    local version = byte(source, 1)
    if version == 2 then return huffman.decode(source) end
    if version ~= 1 then
        error("unknown Shale stream version: " .. tostring(version), 2)
    end

    local output, count = {}, 0
    local position, size = 2, #source
    while position <= size do
        local control = byte(source, position)
        position = position + 1

        for _ = 1, 8 do
            if position > size then break end
            if control % 2 == 1 then
                if position + 2 > size then
                    error("truncated Shale match token", 2)
                end
                local distance = byte(source, position) * 256
                    + byte(source, position + 1)
                local length = byte(source, position + 2) + MIN_MATCH
                position = position + 3
                if distance < 1 or distance > count then
                    error("invalid Shale match distance", 2)
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
    end
    return concat(output)
end

--- Encode arbitrary bytes using five printable ASCII characters per four
--- input bytes. The original byte length must be retained for decoding.
---
--- @param input string
--- @return string
function compressor.encode85(input)
    if type(input) ~= "string" then
        error("bad argument #1 to 'encode85' (string expected)", 2)
    end

    local output, count = {}, 0
    local block = {}
    for position = 1, #input, 4 do
        local a, b, c, d = byte(input, position, position + 3)
        local value = (a or 0) * 16777216
            + (b or 0) * 65536
            + (c or 0) * 256
            + (d or 0)
        for index = 5, 1, -1 do
            block[index] = char(value % 85 + 33)
            value = math.floor(value / 85)
        end
        count = count + 1
        output[count] = concat(block)
    end
    return concat(output)
end

--- Decode the printable representation produced by encode85.
---
--- @param source string
--- @param length number Original binary byte length.
--- @return string
function compressor.decode85(source, length)
    if type(source) ~= "string" then
        error("bad argument #1 to 'decode85' (string expected)", 2)
    end
    if type(length) ~= "number"
        or length < 0
        or length ~= math.floor(length) then
        error("bad argument #2 to 'decode85' (length expected)", 2)
    end
    if #source % 5 ~= 0 then error("invalid Base85 length", 2) end

    local output, count = {}, 0
    local floor = math.floor
    for position = 1, #source, 5 do
        local a, b, c, d, e = byte(source, position, position + 4)
        a, b, c, d, e = a - 33, b - 33, c - 33, d - 33, e - 33
        if a < 0 or a > 84 or b < 0 or b > 84 or c < 0 or c > 84
            or d < 0 or d > 84 or e < 0 or e > 84 then
            error("invalid Base85 character", 2)
        end
        local value = (((a * 85 + b) * 85 + c) * 85 + d) * 85 + e
        count = count + 1
        output[count] = char(
            floor(value / 16777216) % 256,
            floor(value / 65536) % 256,
            floor(value / 256) % 256,
            value % 256
        )
    end
    return sub(concat(output), 1, length)
end

return compressor
