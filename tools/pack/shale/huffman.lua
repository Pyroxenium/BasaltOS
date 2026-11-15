local huffman = {}

huffman.SYMBOL_COUNT = 513
huffman.END_OF_STREAM = 512
huffman.DISTANCE_COUNT = 256
huffman.MAX_BITS = 15
huffman.ROOT_BITS = 10

local MAX_BITS = huffman.MAX_BITS

--- Assign a code length to every used symbol.
---
--- Lengths are capped at `limit`. When the natural tree is deeper the
--- frequencies are halved and the tree rebuilt: with every weight down at one
--- the depth cannot exceed ceil(log2(alphabet)), so this always terminates.
---
--- @param frequencies table Symbol to count, zero-based.
--- @param count number Alphabet size.
--- @param limit? number Maximum code length, defaults to MAX_BITS.
--- @return table lengths
--- @return number maxLength
function huffman.codeLengths(frequencies, count, limit)
    limit = limit or MAX_BITS
    local lengths = {}
    for symbol = 0, count - 1 do lengths[symbol] = 0 end

    local used = {}
    for symbol = 0, count - 1 do
        local weight = frequencies[symbol]
        if weight and weight > 0 then
            used[#used + 1] = { weight = weight, symbol = symbol }
        end
    end

    if #used == 0 then return lengths, 0 end
    if #used == 1 then
        lengths[used[1].symbol] = 1
        return lengths, 1
    end

    local shift = 0
    while true do
        local leaves = {}
        for index = 1, #used do
            local weight = used[index].weight
            if shift > 0 then
                weight = math.floor(weight / 2 ^ shift)
                if weight < 1 then weight = 1 end
            end
            leaves[index] = { weight = weight, symbol = used[index].symbol }
        end
        table.sort(leaves, function(left, right)
            if left.weight ~= right.weight then
                return left.weight < right.weight
            end
            return left.symbol < right.symbol
        end)

        local merged = {}
        local leafCursor, mergedCursor = 1, 1
        local function takeSmallest()
            local leaf = leaves[leafCursor]
            local node = merged[mergedCursor]
            if leaf and (not node or leaf.weight <= node.weight) then
                leafCursor = leafCursor + 1
                return leaf
            end
            mergedCursor = mergedCursor + 1
            return node
        end

        local remaining = #leaves
        while remaining > 1 do
            local left = takeSmallest()
            local right = takeSmallest()
            merged[#merged + 1] = {
                weight = left.weight + right.weight,
                left = left,
                right = right,
            }
            remaining = remaining - 1
        end

        for index = 1, #leaves do lengths[leaves[index].symbol] = 0 end
        local maxLength = 0
        local stack = { { node = takeSmallest(), depth = 0 } }
        while #stack > 0 do
            local top = stack[#stack]
            stack[#stack] = nil
            local node = top.node
            if node.left then
                stack[#stack + 1] = { node = node.left, depth = top.depth + 1 }
                stack[#stack + 1] = { node = node.right, depth = top.depth + 1 }
            else
                lengths[node.symbol] = top.depth
                if top.depth > maxLength then maxLength = top.depth end
            end
        end

        if maxLength <= limit then return lengths, maxLength end
        shift = shift + 1
    end
end

--- Derive canonical codes from code lengths.
---
--- @param lengths table
--- @param count number
--- @param maxLength number
--- @return table codes
function huffman.canonicalCodes(lengths, count, maxLength)
    local perLength = {}
    for length = 0, maxLength do perLength[length] = 0 end
    for symbol = 0, count - 1 do
        local length = lengths[symbol]
        if length > 0 then
            perLength[length] = perLength[length] + 1
        end
    end

    local nextCode, code = {}, 0
    perLength[0] = 0
    for length = 1, maxLength do
        code = (code + perLength[length - 1]) * 2
        nextCode[length] = code
    end

    local codes = {}
    for symbol = 0, count - 1 do
        local length = lengths[symbol]
        if length > 0 then
            codes[symbol] = nextCode[length]
            nextCode[length] = nextCode[length] + 1
        end
    end
    return codes
end

--- A most-significant-bit-first bit writer backed by a byte buffer.
---
--- @return table
function huffman.writer()
    local bytes, count = {}, 0
    local hold, bits = 0, 0
    local writer = {}

    function writer.write(value, width)
        hold = hold * 2 ^ width + value
        bits = bits + width
        while bits >= 8 do
            local shift = bits - 8
            local top = math.floor(hold / 2 ^ shift)
            count = count + 1
            bytes[count] = string.char(top)
            hold = hold - top * 2 ^ shift
            bits = shift
        end
    end

    function writer.finish()
        if bits > 0 then
            count = count + 1
            bytes[count] = string.char(hold * 2 ^ (8 - bits))
            hold, bits = 0, 0
        end
        return table.concat(bytes)
    end

    return writer
end

--- Serialise code lengths, collapsing runs of unused symbols.
---
--- Four bits per symbol, and a zero is followed by a seven bit count of the
--- further zeros that follow it.
---
--- @param writer table
--- @param lengths table
--- @param count number
function huffman.writeLengths(writer, lengths, count)
    local index = 0
    while index < count do
        local length = lengths[index]
        if length == 0 then
            local run = 0
            while run < 127
                and index + run + 1 < count
                and lengths[index + run + 1] == 0 do
                run = run + 1
            end
            writer.write(0, 4)
            writer.write(run, 7)
            index = index + run + 1
        else
            writer.write(length, 4)
            index = index + 1
        end
    end
end

huffman.DECODER_SOURCE = [==[
function(source, breathe)
    local byte, char, concat = string.byte, string.char, table.concat
    local floor = math.floor
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
                error("Corrupt Shale bundle (truncated stream)", 0)
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
        local lengths, maxLength = {}, 0
        local index = 0
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
                if length > maxLength then maxLength = length end
            end
        end
        return lengths, maxLength
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
                error("Corrupt Shale bundle (over-subscribed code)", 0)
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

        return { counts = counts, symbols = symbols, root = root }
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
        error("Corrupt Shale bundle (bad Huffman code)", 0)
    end

    if byte(source, 1) ~= 2 then
        error("Corrupt Shale bundle (unknown stream version)", 0)
    end

    local literals = buildDecoder(readLengths(513), 513)
    local distances = buildDecoder(readLengths(256), 256)

    local output, count = {}, 0
    local nextBreath = 16384
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
                error("Corrupt Shale bundle (invalid distance)", 0)
            end
            local start = count - distance + 1
            for index = start, start + length - 1 do
                count = count + 1
                output[count] = output[index]
            end
        end

        if breathe and count > nextBreath then
            breathe()
            nextBreath = count + 16384
        end
    end

    return concat(output)
end
]==]

local function globalValue(name)
    return rawget(_G, name) or _G[name]
end

local function loadDecoder()
    local loadString = globalValue("loadstring")
    local chunk
    if _VERSION == "Lua 5.1" and loadString then
        chunk = loadString("return " .. huffman.DECODER_SOURCE, "@huffman")
    else
        local loadFunction = globalValue("load")
        chunk = loadFunction(
            "return " .. huffman.DECODER_SOURCE,
            "@huffman",
            "t"
        )
    end
    return assert(chunk, "huffman decoder source is not loadable")()
end

--- Decode an entropy-coded stream.
---
--- @param source string
--- @param breathe? function
--- @return string
huffman.decode = loadDecoder()

return huffman
