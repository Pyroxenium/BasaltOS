local lexer = {}

local keywords = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
}

local reservedNames = {
    ["goto"] = true,
}

local singleSymbols = {
    ["+"] = true,
    ["-"] = true,
    ["*"] = true,
    ["/"] = true,
    ["%"] = true,
    ["^"] = true,
    ["#"] = true,
    ["="] = true,
    ["<"] = true,
    [">"] = true,
    ["~"] = true,
    ["("] = true,
    [")"] = true,
    ["{"] = true,
    ["}"] = true,
    ["["] = true,
    ["]"] = true,
    [";"] = true,
    [":"] = true,
    [","] = true,
    ["."] = true,
}

local simpleEscapes = {
    ["a"] = true,
    ["b"] = true,
    ["f"] = true,
    ["n"] = true,
    ["r"] = true,
    ["t"] = true,
    ["v"] = true,
    ["\\"] = true,
    ['"'] = true,
    ["'"] = true,
}

local simpleEscapeValues = {
    ["a"] = "\a",
    ["b"] = "\b",
    ["f"] = "\f",
    ["n"] = "\n",
    ["r"] = "\r",
    ["t"] = "\t",
    ["v"] = "\v",
    ["\\"] = "\\",
    ['"'] = '"',
    ["'"] = "'",
}

local function isDigit(char)
    return char ~= "" and char >= "0" and char <= "9"
end

local function isHexDigit(char)
    return isDigit(char)
        or (char >= "a" and char <= "f")
        or (char >= "A" and char <= "F")
end

local function isIdentifierStart(char)
    return char == "_"
        or (char >= "a" and char <= "z")
        or (char >= "A" and char <= "Z")
end

local function isIdentifierPart(char)
    return isIdentifierStart(char) or isDigit(char)
end

local function isWhitespace(char)
    return char == " "
        or char == "\t"
        or char == "\n"
        or char == "\r"
        or char == "\v"
        or char == "\f"
end

local function formatError(sourceName, line, column, message)
    return ("%s:%d:%d: %s"):format(sourceName, line, column, message)
end

local function longBracketLevel(source, position)
    if source:sub(position, position) ~= "[" then return nil end

    local cursor = position + 1
    while source:sub(cursor, cursor) == "=" do
        cursor = cursor + 1
    end

    if source:sub(cursor, cursor) ~= "[" then return nil end
    return cursor - position - 1, cursor
end

--- Tokenize CC:Tweaked-compatible Lua source.
---
--- Significant tokens are returned by default. Set `comments`, `whitespace`,
--- or `trivia` to true to retain trivia tokens too.
---
--- Every token contains:
--- - kind: keyword, identifier, number, string, symbol, comment, whitespace
--- - text: the exact source spelling
--- - start/finish: inclusive byte offsets
--- - line/column: one-based start position
--- - endLine/endColumn: the exclusive end position
---
--- @param source string
--- @param options? table
--- @return table
function lexer.lex(source, options)
    if type(source) ~= "string" then
        error("bad argument #1 to 'lex' (string expected)", 2)
    end
    if options ~= nil and type(options) ~= "table" then
        error("bad argument #2 to 'lex' (table expected)", 2)
    end

    options = options or {}
    local includeComments = options.trivia == true
        or options.comments == true
        or options.includeComments == true
    local includeWhitespace = options.trivia == true
        or options.whitespace == true
        or options.includeWhitespace == true
    local sourceName = options.sourceName or options.name or "<source>"

    local tokens = {}
    local length = #source
    local position, line, column = 1, 1, 1

    local function peek(offset)
        offset = offset or 0
        local at = position + offset
        if at < 1 or at > length then return "" end
        return source:sub(at, at)
    end

    local function fail(message, atLine, atColumn)
        error(formatError(
            sourceName,
            atLine or line,
            atColumn or column,
            message
        ), 0)
    end

    local function advance()
        local char = peek()
        if char == "" then return end

        if char == "\r" then
            if peek(1) == "\n" then
                position = position + 2
            else
                position = position + 1
            end
            line, column = line + 1, 1
        elseif char == "\n" then
            position = position + 1
            line, column = line + 1, 1
        else
            position, column = position + 1, column + 1
        end
    end

    local function addToken(kind, start, startLine, startColumn)
        tokens[#tokens + 1] = {
            kind = kind,
            text = source:sub(start, position - 1),
            start = start,
            finish = position - 1,
            line = startLine,
            column = startColumn,
            endLine = line,
            endColumn = column,
        }
    end

    local function consumeLongBracket(kind, start, startLine, startColumn)
        local level, openerEnd = longBracketLevel(source, position)
        if level == nil then return false end

        while position <= openerEnd do advance() end

        local closer = "]" .. string.rep("=", level) .. "]"
        local closeStart = source:find(closer, position, true)
        if not closeStart then
            fail(
                kind == "comment"
                    and "unfinished long comment"
                    or "unfinished long string",
                startLine,
                startColumn
            )
        end

        local closeEnd = closeStart + #closer - 1
        while position <= closeEnd do advance() end
        addToken(kind, start, startLine, startColumn)
        return true
    end

    local function consumeShortString(quote, start, startLine, startColumn)
        advance()

        while true do
            local char = peek()
            if char == "" then
                fail("unfinished string", startLine, startColumn)
            elseif char == quote then
                advance()
                addToken("string", start, startLine, startColumn)
                return
            elseif char == "\r" or char == "\n" then
                fail("unfinished string")
            elseif char ~= "\\" then
                advance()
            else
                local escapeLine, escapeColumn = line, column
                advance()
                local escaped = peek()

                if escaped == "" then
                    fail("unfinished escape sequence", escapeLine, escapeColumn)
                elseif escaped == "\r" or escaped == "\n" then
                    advance()
                elseif simpleEscapes[escaped] then
                    advance()
                elseif escaped == "z" then
                    advance()
                    while isWhitespace(peek()) do advance() end
                elseif escaped == "x" then
                    advance()
                    for _ = 1, 2 do
                        if not isHexDigit(peek()) then
                            fail(
                                "hexadecimal escape must contain exactly two digits",
                                escapeLine,
                                escapeColumn
                            )
                        end
                        advance()
                    end
                elseif escaped == "u" and peek(1) == "{" then
                    advance() -- u
                    advance() -- {

                    local digits = ""
                    while isHexDigit(peek()) do
                        digits = digits .. peek()
                        advance()
                    end
                    if digits == "" or peek() ~= "}" then
                        fail(
                            "invalid UTF-8 escape sequence",
                            escapeLine,
                            escapeColumn
                        )
                    end
                    local value = tonumber(digits, 16)
                    if value > 0x10FFFF
                        or (value >= 0xD800 and value <= 0xDFFF) then
                        fail(
                            "UTF-8 escape is outside the valid Unicode range",
                            escapeLine,
                            escapeColumn
                        )
                    end
                    advance() -- }
                elseif isDigit(escaped) then
                    local digits = ""
                    for _ = 1, 3 do
                        if not isDigit(peek()) then break end
                        digits = digits .. peek()
                        advance()
                    end
                    if tonumber(digits, 10) > 255 then
                        fail(
                            "decimal escape is too large",
                            escapeLine,
                            escapeColumn
                        )
                    end
                else
                    fail(
                        "invalid escape sequence '\\" .. escaped .. "'",
                        escapeLine,
                        escapeColumn
                    )
                end
            end
        end
    end

    local function rejectNumberSuffix()
        local suffix = peek()
        if isIdentifierStart(suffix) or isDigit(suffix) or suffix == "." then
            fail("malformed number")
        end
    end

    local function consumeNumber(start, startLine, startColumn, startsWithDot)
        if startsWithDot then
            advance() -- .
            while isDigit(peek()) do advance() end
        elseif peek() == "0" and (peek(1) == "x" or peek(1) == "X") then
            advance()
            advance()

            local digits = 0
            while isHexDigit(peek()) do
                digits = digits + 1
                advance()
            end
            if peek() == "." and peek(1) ~= "." then
                advance()
                while isHexDigit(peek()) do
                    digits = digits + 1
                    advance()
                end
            end
            if digits == 0 then fail("malformed hexadecimal number") end

            if peek() == "p" or peek() == "P" then
                advance()
                if peek() == "+" or peek() == "-" then advance() end
                if not isDigit(peek()) then
                    fail("hexadecimal exponent has no digits")
                end
                while isDigit(peek()) do advance() end
            end

            rejectNumberSuffix()
            addToken("number", start, startLine, startColumn)
            return
        else
            while isDigit(peek()) do advance() end
            if peek() == "." then
                if peek(1) == "." then fail("malformed number") end
                advance()
                while isDigit(peek()) do advance() end
            end
        end

        if peek() == "e" or peek() == "E" then
            advance()
            if peek() == "+" or peek() == "-" then advance() end
            if not isDigit(peek()) then
                fail("exponent has no digits")
            end
            while isDigit(peek()) do advance() end
        end

        rejectNumberSuffix()
        addToken("number", start, startLine, startColumn)
    end

    while position <= length do
        local char = peek()
        local start, startLine, startColumn = position, line, column

        if isWhitespace(char) then
            repeat advance() until not isWhitespace(peek())
            if includeWhitespace then
                addToken("whitespace", start, startLine, startColumn)
            end
        elseif char == "-" and peek(1) == "-" then
            advance()
            advance()

            if not consumeLongBracket(
                "comment",
                start,
                startLine,
                startColumn
            ) then
                while peek() ~= ""
                    and peek() ~= "\r"
                    and peek() ~= "\n" do
                    advance()
                end
                if includeComments then
                    addToken("comment", start, startLine, startColumn)
                end
            elseif not includeComments then
                tokens[#tokens] = nil
            end
        elseif char == '"' or char == "'" then
            consumeShortString(char, start, startLine, startColumn)
        elseif char == "[" and longBracketLevel(source, position) ~= nil then
            consumeLongBracket("string", start, startLine, startColumn)
        elseif isDigit(char) then
            consumeNumber(start, startLine, startColumn, false)
        elseif char == "." and isDigit(peek(1)) then
            consumeNumber(start, startLine, startColumn, true)
        elseif isIdentifierStart(char) then
            repeat advance() until not isIdentifierPart(peek())
            local text = source:sub(start, position - 1)
            addToken(
                keywords[text] and "keyword" or "identifier",
                start,
                startLine,
                startColumn
            )
        else
            local three = source:sub(position, position + 2)
            local two = source:sub(position, position + 1)
            if three == "..." then
                advance()
                advance()
                advance()
                addToken("symbol", start, startLine, startColumn)
            elseif two == ".."
                or two == "=="
                or two == "~="
                or two == "<="
                or two == ">="
                or two == "::" then
                advance()
                advance()
                addToken("symbol", start, startLine, startColumn)
            elseif singleSymbols[char] then
                advance()
                addToken("symbol", start, startLine, startColumn)
            else
                local byte = source:byte(position)
                fail(("unexpected character 0x%02X"):format(byte))
            end
        end
    end

    if options.eof == true or options.includeEof == true then
        tokens[#tokens + 1] = {
            kind = "eof",
            text = "",
            start = position,
            finish = position - 1,
            line = line,
            column = column,
            endLine = line,
            endColumn = column,
        }
    end

    return tokens
end

local function encodeUtf8(value)
    if value <= 0x7F then
        return string.char(value)
    elseif value <= 0x7FF then
        return string.char(
            0xC0 + math.floor(value / 0x40),
            0x80 + value % 0x40
        )
    elseif value <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(value / 0x1000),
            0x80 + math.floor(value / 0x40) % 0x40,
            0x80 + value % 0x40
        )
    end
    return string.char(
        0xF0 + math.floor(value / 0x40000),
        0x80 + math.floor(value / 0x1000) % 0x40,
        0x80 + math.floor(value / 0x40) % 0x40,
        0x80 + value % 0x40
    )
end

--- Decode one CC:Tweaked string literal without executing host Lua code.
---
--- This deliberately follows the same escapes accepted by `lexer.lex`, so
--- tools running under Lua 5.1 recover the same value CC:Tweaked will see.
---
--- @param text string Exact short- or long-string source spelling.
--- @return string
function lexer.decodeStringLiteral(text)
    if type(text) ~= "string" then
        error(
            "bad argument #1 to 'decodeStringLiteral' (string expected)",
            2
        )
    end

    local tokens = lexer.lex(text, { sourceName = "<string literal>" })
    if #tokens ~= 1
        or tokens[1].kind ~= "string"
        or tokens[1].text ~= text then
        error("string literal expected", 2)
    end

    if text:sub(1, 1) == "[" then
        local level, openerEnd = longBracketLevel(text, 1)
        local closerLength = level + 2
        local value = text:sub(openerEnd + 1, #text - closerLength)

        value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
        if value:sub(1, 1) == "\n" then value = value:sub(2) end
        return value
    end

    local output = {}
    local position, finish = 2, #text - 1
    while position <= finish do
        local current = text:sub(position, position)
        if current ~= "\\" then
            output[#output + 1] = current
            position = position + 1
        else
            local escaped = text:sub(position + 1, position + 1)
            local simple = simpleEscapeValues[escaped]
            if simple then
                output[#output + 1] = simple
                position = position + 2
            elseif escaped == "\r" or escaped == "\n" then
                output[#output + 1] = "\n"
                if escaped == "\r"
                    and text:sub(position + 2, position + 2) == "\n" then
                    position = position + 3
                else
                    position = position + 2
                end
            elseif escaped == "z" then
                position = position + 2
                while isWhitespace(text:sub(position, position)) do
                    position = position + 1
                end
            elseif escaped == "x" then
                output[#output + 1] = string.char(tonumber(
                    text:sub(position + 2, position + 3),
                    16
                ))
                position = position + 4
            elseif escaped == "u" then
                local close = text:find("}", position + 3, true)
                local value = tonumber(text:sub(position + 3, close - 1), 16)
                output[#output + 1] = encodeUtf8(value)
                position = close + 1
            else
                local digits = text:match("^(%d%d?%d?)", position + 1)
                output[#output + 1] = string.char(tonumber(digits, 10))
                position = position + 1 + #digits
            end
        end
    end

    return table.concat(output)
end

lexer.tokenize = lexer.lex
lexer.keywords = keywords
lexer.reservedNames = reservedNames

return lexer
