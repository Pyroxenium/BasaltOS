-- Safe arithmetic expression evaluator used by Calculator.

local calculator = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function calculator.evaluate(expression)
    expression = trim(expression)
    if expression == "" then return nil, "Enter a calculation" end
    if #expression > 128 then return nil, "Calculation is too long" end
    if not expression:match("^[%d%s%.%+%-%*/%%%^%(%)]+$") then
        return nil, "Only numbers and arithmetic operators are allowed"
    end
    if expression:find("%.%.", 1, false) then
        return nil, "Invalid decimal number"
    end

    local source = "return (" .. expression .. ")"
    local chunk, compile_error
    if loadstring and setfenv then
        chunk, compile_error = loadstring(source, "calculator")
        if chunk then setfenv(chunk, {}) end
    else
        chunk, compile_error = load(source, "calculator", "t", {})
    end
    if not chunk then return nil, "Invalid calculation" end

    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "number" then
        return nil, "Invalid calculation"
    end
    if result ~= result or result == math.huge or result == -math.huge then
        return nil, "Result is not a finite number"
    end
    return result
end

function calculator.format(result)
    if type(result) ~= "number" then return tostring(result or "") end
    if result == 0 then return "0" end
    if result == math.floor(result) and math.abs(result) < 100000000000000 then
        return string.format("%.0f", result)
    end
    return string.format("%.12g", result)
end

return calculator
