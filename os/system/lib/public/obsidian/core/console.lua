--- Obsidian Console Module
--- Provides an in-game console overlay for executing Lua commands and printing output.
--- Open with F1, scroll with PgUp/PgDn or mouse wheel, navigate command history with Up/Down arrows.
---@diagnostic disable: undefined-global

---@class ConsoleCommandEntry
---@field fn fun(...: string): any
---@field desc string

---@class ConsoleStateEntry
---@field text string
---@field fg string

---@class ConsoleState
---@field open boolean Console open/closed state
---@field input string Current input line (not yet executed)
---@field scroll number Lines scrolled up in the history view (0 = bottom)
---@field history ConsoleStateEntry[] List of past console lines, newest at the end
---@field cmdHist string[] History of executed commands for up/down navigation, newest at the end
---@field cmdIdx number Index into cmdHist for current input (0 = not browsing history)
---@field env table|nil Lua environment for executing commands (set by engine.lua, defaults to _ENV)
---@field commands table<string, ConsoleCommandEntry> Registered named commands: [name] = { fn, desc }

---@class ConsoleModule
local Console = {}

local HEIGHT = 10
local PROMPT = "> "
local MAX_HIST = 300

---@type ConsoleState
local state = {
    open    = false,
    input   = "",
    scroll  = 0,
    history = {},
    cmdHist = {},
    cmdIdx  = 0,
    env     = nil,
    commands = {},
}

-- ─── Public state helpers ─────────────────────────────────────────────────────

--- Returns true if the console is currently open.
--- @return boolean
function Console.isOpen()
    return state.open
end

--- Opens the console, allowing it to receive input and draw on screen.
function Console.open()
    state.open   = true
    state.scroll = 0
end

--- Closes the console and clears the input line (but not history).
function Console.close()
    state.open   = false
    state.input  = ""
    state.cmdIdx = 0
    state.scroll = 0
end

--- Toggles the console open/closed.
function Console.toggle()
    if state.open then Console.close() else Console.open() end
end

--- Set the Lua environment used when executing commands.
--- Called from engine.lua: Console.setEnv(setmetatable({Engine=Engine}, {__index=_G}))
--- @param env table
function Console.setEnv(env)
    state.env = env
end

-- ─── Output ───────────────────────────────────────────────────────────────────
local function wrapText(text, maxW)
    local lines = {}
    for para in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
        if #para == 0 then
            table.insert(lines, "")
        elseif #para <= maxW then
            table.insert(lines, para)
        else
            local words = {}
            for w in para:gmatch("%S+") do table.insert(words, w) end
            local cur = ""
            for _, word in ipairs(words) do
                if #cur == 0 then
                    if #word > maxW then
                        while #word > maxW do
                            table.insert(lines, word:sub(1, maxW))
                            word = word:sub(maxW + 1)
                        end
                        cur = word
                    else
                        cur = word
                    end
                elseif #cur + 1 + #word <= maxW then
                    cur = cur .. " " .. word
                else
                    table.insert(lines, cur)
                    cur = word
                end
            end
            if #cur > 0 then table.insert(lines, cur) end
        end
    end
    return lines
end

local currentWrapWidth = 48

--- Add a line of text to the console history, splitting into multiple lines if needed.
---@param text any Text to add (will be converted to string)
---@param fg? string Optional foreground color code (default "0" = white)
function Console.addLine(text, fg)
    local lines = wrapText(tostring(text), currentWrapWidth - 2)  -- -2 for left margin
    for _, line in ipairs(lines) do
        table.insert(state.history, { text = line, fg = fg or "0" })
    end
    while #state.history > MAX_HIST do
        table.remove(state.history, 1)
    end
end


--- Write a line to the console output (callable from user code).
---@param text any Text to print (will be converted to string)
function Console.print(text)
    Console.addLine(tostring(text), "b")
end

-- ─── Command registry ────────────────────────────────────────────────────────

--- Register a named command callable from the console.
---@param name string Command name (e.g. "test", "spawnPlayer")
---@param fn function Function to call. Receives any space-separated args as strings.
---@param description? string Optional help text shown by the built-in "help" command.
---@return nil
function Console.addCommand(name, fn, description)
    state.commands[name] = { fn = fn, desc = description or "" }
end

--- Remove a previously registered command.
---@param name string Command name to remove
---@return nil
function Console.removeCommand(name)
    state.commands[name] = nil
end

--- Execute a console command string.
---@param cmd string Command string to execute (e.g. "spawnPlayer Bob 100 200")
---@return nil
function Console.exec(cmd)
    if cmd == "" then return end

    if state.cmdHist[#state.cmdHist] ~= cmd then
        table.insert(state.cmdHist, cmd)
    end
    state.cmdIdx = 0
    state.scroll = 0

    Console.addLine(PROMPT .. cmd, "7")
    if cmd == "help" then
        Console.addLine("  Registered commands:", "7")
        local found = false
        for name, entry in pairs(state.commands) do
            found = true
            local line = "  " .. name
            if entry.desc ~= "" then line = line .. "  —  " .. entry.desc end
            Console.addLine(line, "b")
        end
        if not found then Console.addLine("  (none registered)", "8") end
        return
    end

    local cmdName, rest = cmd:match("^(%S+)(.*)$")
    if cmdName and state.commands[cmdName] then
        local args = {}
        for arg in (rest or ""):gmatch("%S+") do
            table.insert(args, arg)
        end
        local oldPrint = _G.print
        _G.print = Console.print
        local ok, err = pcall(state.commands[cmdName].fn, table.unpack(args))
        _G.print = oldPrint
        if not ok then
            Console.addLine("  " .. tostring(err), "e")
        end
        return
    end

    local env = state.env or _ENV

    local chunk, err = load("return " .. cmd, "console", "t", env)
    if not chunk then
        chunk, err = load(cmd, "console", "t", env)
    end

    if not chunk then
        Console.addLine("  " .. tostring(err), "e")
        return
    end

    local results = table.pack(pcall(chunk))
    local ok = results[1]
    if not ok then
        Console.addLine("  " .. tostring(results[2]), "e")
    elseif results.n > 1 then
        local parts = {}
        for i = 2, results.n do
            parts[i - 1] = tostring(results[i])
        end
        Console.addLine("  = " .. table.concat(parts, ", "), "5")
    end
end

-- ─── Event handling ───────────────────────────────────────────────────────────

--- Process a raw event table.
--- When console is closed, only watches for the toggle character (^).
--- When open, consumes all events except term_resize.
---@param event table Raw event table: { eventName, p1, p2, ... }
---@param consumed? boolean true if the UI already consumed this event
---@return boolean true if the console consumed the event
function Console.handleEvent(event, consumed)
    local etype = event[1]

    if not state.open then
        if not consumed and etype == "key" and event[2] == keys.f1 then
            Console.open()
            return true
        end
        return false
    end

    if etype == "term_resize" then return false end

    if etype == "char" then
        state.input = state.input .. event[2]

    elseif etype == "key" then
        local k = event[2]
        if k == keys.f1 then
            Console.close()
            return true
        elseif k == keys.enter then
            Console.exec(state.input)
            state.input  = ""
            state.cmdIdx = 0
        elseif k == keys.backspace then
            state.input = state.input:sub(1, -2)
        elseif k == keys.up then
            if #state.cmdHist > 0 then
                state.cmdIdx = math.min(state.cmdIdx + 1, #state.cmdHist)
                state.input  = state.cmdHist[#state.cmdHist - state.cmdIdx + 1]
            end
        elseif k == keys.down then
            if state.cmdIdx > 1 then
                state.cmdIdx = state.cmdIdx - 1
                state.input  = state.cmdHist[#state.cmdHist - state.cmdIdx + 1]
            else
                state.cmdIdx = 0
                state.input  = ""
            end
        elseif k == keys.pageUp then
            local maxOut = HEIGHT - 3
            state.scroll = math.min(state.scroll + math.floor(maxOut / 2), #state.history - maxOut)
            state.scroll = math.max(0, state.scroll)
        elseif k == keys.pageDown then
            state.scroll = math.max(0, state.scroll - math.floor((HEIGHT - 3) / 2))
        end

    elseif etype == "mouse_scroll" then
        state.scroll = state.scroll - event[2]   -- event[2]: -1 = up, 1 = down
        local maxOut = HEIGHT - 3
        state.scroll = math.max(0, math.min(state.scroll, math.max(0, #state.history - maxOut)))
    end

    return true
end

-- ─── Drawing ─────────────────────────────────────────────────────────────────

--- Draw the console overlay onto the provided buffer.
--- Should be called every frame after scene draw, before buf:present().
---@param buf BufferInstance
---@return nil
function Console.draw(buf)
    if not state.open then return end

    local w, h = buf:getSize()
    local top  = h - HEIGHT + 1
    currentWrapWidth = w

    buf:drawRect(1, top, w, HEIGHT, " ", "f", "8")

    buf:drawRect(1, top, w, 1, " ", "0", "7")
    local title = " Obsidian Console   F1 toggle  PgUp/PgDn scroll"
    buf:drawText(1, top, title:sub(1, w), "0", "7")

    local maxOut   = HEIGHT - 3
    local total    = #state.history
    local startIdx = math.max(1, total - maxOut + 1 - state.scroll)
    local endIdx   = math.min(total, startIdx + maxOut - 1)

    local row = top + 1
    for i = startIdx, endIdx do
        local line = state.history[i]
        buf:drawText(2, row, line.text, line.fg, "8")
        row = row + 1
    end

    if state.scroll > 0 then
        local indicator = string.format(" ^%d ", state.scroll)
        buf:drawText(w - #indicator, top + 1, indicator, "5", "8")
    end

    local sepRow = top + HEIGHT - 2
    buf:drawRect(1, sepRow, w, 1, string.rep("\140", w), "7", "8")

    local inputRow  = top + HEIGHT - 1
    local available = w - #PROMPT - 1
    local display   = PROMPT .. state.input:sub(-available)
    buf:drawRect(1, inputRow, w, 1, " ", "f", "0")
    buf:drawText(1, inputRow, display:sub(1, w), "f", "0")
end

return Console
