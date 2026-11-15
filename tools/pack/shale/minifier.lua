local lexer = require("shale.lexer")

local minifier = {}

local wordKinds = {
    keyword = true,
    identifier = true,
}

local symbolPairCache = {}

local function sameToken(actual, expected)
    return actual
        and actual.kind == expected.kind
        and actual.text == expected.text
end

local function symbolPairNeedsSeparator(left, right)
    local key = left.text .. "\0" .. right.text
    local cached = symbolPairCache[key]
    if cached ~= nil then return cached end

    local ok, combined = pcall(lexer.lex, left.text .. right.text)
    local needsSeparator = not ok
        or #combined ~= 2
        or not sameToken(combined[1], left)
        or not sameToken(combined[2], right)

    symbolPairCache[key] = needsSeparator
    return needsSeparator
end

--- Return whether two significant tokens require whitespace between them.
---
--- This is deliberately conservative. It protects token boundaries and also
--- prevents three-token long-bracket openers such as `[`, `=`, `[`.
---
--- @param left table
--- @param right table
--- @return boolean
function minifier.needsSeparator(left, right)
    if not left or not right then return false end

    if wordKinds[left.kind] then
        return wordKinds[right.kind] or right.kind == "number"
    end

    if left.kind == "number" then
        return wordKinds[right.kind]
            or right.kind == "number"
            or right.text:sub(1, 1) == "."
    end

    if left.kind == "symbol"
        and left.text == "."
        and right.kind == "number" then
        return true
    end

    if left.kind == "symbol"
        and left.text == "["
        and right.kind == "symbol"
        and right.text:sub(1, 1) == "=" then
        return true
    end

    if left.kind == "symbol"
        and left.text == "["
        and right.kind == "string"
        and right.text:sub(1, 1) == "[" then
        return true
    end

    if left.kind == "symbol" and right.kind == "symbol" then
        return symbolPairNeedsSeparator(left, right)
    end

    return false
end

local function mismatchError(sourceName, index, expected, actual)
    local expectedText = expected
        and ("%s %q"):format(expected.kind, expected.text)
        or "<end of source>"
    local actualText = actual
        and ("%s %q"):format(actual.kind, actual.text)
        or "<end of generated source>"
    local line = expected and expected.line or 1
    local column = expected and expected.column or 1

    return ("%s:%d:%d: minifier changed token %d"
        .. "\nexpected: %s"
        .. "\nactual:   %s"):format(
        sourceName,
        line,
        column,
        index,
        expectedText,
        actualText
    )
end

--- Verify that generated source contains exactly the same significant tokens.
---
--- @param originalTokens table
--- @param generated string
--- @param options? table
--- @return true
function minifier.validate(originalTokens, generated, options)
    options = options or {}
    local sourceName = options.sourceName or options.name or "<source>"
    local generatedTokens = lexer.lex(generated, {
        sourceName = sourceName .. " (minified)",
    })
    local count = math.max(#originalTokens, #generatedTokens)

    for index = 1, count do
        local expected = originalTokens[index]
        local actual = generatedTokens[index]
        if not sameToken(actual, expected) then
            error(mismatchError(
                sourceName,
                index,
                expected,
                actual
            ), 0)
        end
    end

    return true
end

--- Rebuild a significant token sequence with only required separators.
---
--- @param tokens table
--- @return string
function minifier.rebuild(tokens)
    if type(tokens) ~= "table" then
        error("bad argument #1 to 'rebuild' (table expected)", 2)
    end

    local output = {}
    local previous
    for index = 1, #tokens do
        local token = tokens[index]
        if token.kind ~= "comment"
            and token.kind ~= "whitespace"
            and token.kind ~= "eof" then
            if minifier.needsSeparator(previous, token) then
                output[#output + 1] = " "
            end
            output[#output + 1] = token.text
            previous = token
        end
    end

    return table.concat(output)
end

--- Safely remove Lua comments and unnecessary whitespace.
---
--- Returns the generated source and a statistics table.
---
--- Options:
--- - sourceName/name: used in diagnostics
--- - validate: set to false to skip the token-equivalence safety check
---
--- @param source string
--- @param options? table
--- @return string, table
function minifier.minify(source, options)
    if type(source) ~= "string" then
        error("bad argument #1 to 'minify' (string expected)", 2)
    end
    if options ~= nil and type(options) ~= "table" then
        error("bad argument #2 to 'minify' (table expected)", 2)
    end

    options = options or {}
    local sourceName = options.sourceName or options.name or "<source>"
    local tokens = lexer.lex(source, {
        sourceName = sourceName,
    })
    local generated = minifier.rebuild(tokens)

    if options.validate ~= false then
        minifier.validate(tokens, generated, {
            sourceName = sourceName,
        })
    end

    return generated, {
        inputBytes = #source,
        outputBytes = #generated,
        savedBytes = #source - #generated,
        tokenCount = #tokens,
    }
end

return minifier
