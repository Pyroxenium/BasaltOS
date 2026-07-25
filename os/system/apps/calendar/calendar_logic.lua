-- Pure Gregorian calendar helpers used by the Calendar UI.

local calendar = {}

function calendar.isLeapYear(year)
    year = math.floor(tonumber(year) or 0)
    return year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0)
end

function calendar.daysInMonth(year, month)
    local days = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    month = math.floor(tonumber(month) or 0)
    if month < 1 or month > 12 then return nil end
    if month == 2 and calendar.isLeapYear(year) then return 29 end
    return days[month]
end

-- Returns 1 for Monday through 7 for Sunday.
function calendar.weekday(year, month, day)
    year = math.floor(tonumber(year) or 0)
    month = math.floor(tonumber(month) or 0)
    day = math.floor(tonumber(day) or 0)
    local offsets = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4}
    if month < 3 then year = year - 1 end
    local sunday_based = (year + math.floor(year / 4) - math.floor(year / 100)
        + math.floor(year / 400) + offsets[month] + day) % 7
    return (sunday_based + 6) % 7 + 1
end

function calendar.normalizeMonth(year, month)
    year = math.floor(tonumber(year) or 0)
    month = math.floor(tonumber(month) or 1)
    local absolute = year * 12 + month - 1
    return math.floor(absolute / 12), absolute % 12 + 1
end

function calendar.monthCells(year, month)
    year, month = calendar.normalizeMonth(year, month)
    local cells = {}
    local offset = calendar.weekday(year, month, 1) - 1
    local count = calendar.daysInMonth(year, month)
    for slot = 1, 42 do
        local day = slot - offset
        cells[slot] = day >= 1 and day <= count and day or false
    end
    return cells
end

function calendar.dateKey(year, month, day)
    return string.format("%04d-%02d-%02d", year, month, day)
end

return calendar
