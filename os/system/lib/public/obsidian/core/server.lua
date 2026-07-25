-- Obsidian Engine: Server Module
-- High-level server abstraction built on top of network.lua
-- Greatly simplifies building dedicated servers with Obsidian.

---@diagnostic disable: undefined-global

local logger  = require("core.logger")
local network = require("core.network")
local buffer  = require("core.buffer")

--- Network packet structure
---@class NetworkPacket
---@field type string Message type identifier
---@field data table Arbitrary message data payload
---@field sender number Computer ID of the sender
---@field timestamp number Epoch time in milliseconds when the packet was sent

--- Server client object structure
---@class ServerClient
---@field id number Computer ID
---@field meta table Arbitrary metadata
---@field joinedAt number Timestamp (epoch seconds)
---@field lastSeen number Timestamp of last activity
---@field ping number|nil Last measured RTT in ms
---@field heartbeatSent number|nil Timestamp when last PING was sent
---@field lastSeq number Last processed sequence number

--- Server profile object structure
---@class ServerProfile
---@field cid number Client ID
---@field name string Player name
---@field passwordHash string DJB2 hash of the player's password (stored but never sent to clients)
---@field class string|nil Optional player class/type for game-specific logic

--- Server console object structure
---@class ServerConsole
---@field enabled boolean Whether the console is enabled and should be rendered
---@field title string Title shown in the console header
---@field maxEntries number Maximum number of log entries to keep in memory
---@field log table[] Raw log entries with timestamp, prefix, raw text, and color
---@field lines table[] Pre-wrapped lines for display, with text and color
---@field lastWidth number Last known terminal width (for detecting resize)
---@field lastHeight number Last known terminal height (for detecting resize)
---@field startTime number|nil Timestamp when the console was enabled (for uptime display)
---@field dirty boolean Flag indicating whether the console needs to be re-rendered
---@field buf BufferInstance|nil Buffer instance used for rendering the console, created lazily

--- This module provides a high-level server abstraction built on top of network.lua, making it easy to build dedicated servers with Obsidian. It includes client management, message handling, rooms, a built-in auth system, and an optional server console for logging and monitoring.
---@class ServerModule
local server = {}

---@type fun(event: string, ...: any)
server._emit = function() end

-- ─── Internal State ───────────────────────────────────────────────────────────

local _clients = {}   -- [id] = { id, meta, joinedAt, lastSeen, ping, heartbeatSent, lastSeq }
local _rooms = {}   -- [roomName] = { [clientId] = true }
local _handlers = {}   -- [msgType]  = fn(clientId, data, packet)
local _middleware = {}   -- list of fn(clientId, packet, next)
local _tickCbs = {}   -- list of fn(dt)
local _onConnectCb = nil
local _onDisconnectCb = nil
local _running = false
local _protocol = nil
local _hostname = nil
local _tickRate = 20
local _timeout = 30   -- seconds until a client is considered timed out (0 = off)
local _heartbeat = 5    -- send a PING every N seconds (0 = off)
local _seqEnabled = false -- enable per-client sequence number dedup

-- ─── Server Console ───────────────────────────────────────────────────────────

---@type ServerConsole
local _con = {
    enabled = false,
    title = "Obsidian Server",
    maxEntries = 200,
    log = {},
    lines = {},
    lastWidth = 0,
    lastHeight = 0,
    startTime = nil,
    dirty = true,
    buf = nil,   -- Buffer instance, created lazily on first render
}

-- Colour palette for log levels
local CON_LEVEL = {
    info = { fore = "0", prefix = "[INFO ] " },
    warn = { fore = "1", prefix = "[WARN ] " },
    error = { fore = "e", prefix = "[ERROR] " },
    success = { fore = "d", prefix = "[OK   ] " },
    system = { fore = "b", prefix = "[SYS  ] " },
    debug = { fore = "7", prefix = "[DEBUG] " },
}

local CON_PREFIX_W = 0

local function _conTimestamp()
    local t = os.date("*t")
    return string.format("%02d:%02d:%02d", t.hour, t.min, t.sec)
end

local function _wrapText(fullLine, width, indentW)
    if width <= 0 or #fullLine <= width then return { fullLine } end
    local result = {}
    local indent = string.rep(" ", indentW)
    local remaining = fullLine
    while #remaining > width do
        local cut = width
        for i = width, indentW + 1, -1 do
            if remaining:sub(i, i) == " " then
                cut = i - 1
                break
            end
        end
        result[#result + 1] = remaining:sub(1, cut)
        local rest = remaining:sub(cut + 1):match("^%s*(.*)")
        remaining = (#rest > 0) and (indent .. rest) or ""
    end
    if #remaining > 0 then
        result[#result + 1] = remaining
    end
    return result
end

local function _rebuildLines(width)
    _con.lines = {}
    for _, entry in ipairs(_con.log) do
        local full = entry.ts .. "  " .. entry.prefix .. entry.raw
        for _, wl in ipairs(_wrapText(full, width, CON_PREFIX_W)) do
            _con.lines[#_con.lines + 1] = { text = wl, fore = entry.fore }
        end
    end
    _con.lastWidth = width
end

local function _consolePush(text, level)
    level = CON_LEVEL[level] or CON_LEVEL.info
    local entry = {
        ts = _conTimestamp(),
        prefix = level.prefix,
        raw = tostring(text),
        fore = level.fore,
    }
    table.insert(_con.log, entry)
    if #_con.log > _con.maxEntries then
        table.remove(_con.log, 1)
        if _con.lastWidth > 0 then
            _rebuildLines(_con.lastWidth)
        end
    else
        if _con.lastWidth > 0 then
            local full = entry.ts .. "  " .. entry.prefix .. entry.raw
            for _, wl in ipairs(_wrapText(full, _con.lastWidth, CON_PREFIX_W)) do
                _con.lines[#_con.lines + 1] = { text = wl, fore = entry.fore }
            end
        end
    end
    _con.dirty = true
end

local function _consoleRender()
    if not _con.enabled or not _con.dirty then return end
    _con.dirty = false

    local sw, sh = term.getSize()
    if sw == 0 or sh == 0 then return end

    if not _con.buf then
        _con.buf = buffer.new(sw, sh)
        _con.lastWidth = sw
        _con.lastHeight = sh
    elseif sw ~= _con.lastWidth or sh ~= _con.lastHeight then
        _con.buf:setSize(sw, sh)
        _con.lastWidth = sw
        _con.lastHeight = sh
    end

    if sw ~= _con.lastWidth then
        _rebuildLines(sw)
    end

    local buf = _con.buf
    local uptime = ""
    if _con.startTime then
        local secs = math.floor(os.epoch("utc") / 1000 - _con.startTime)
        local m = math.floor(secs / 60)
        local s = secs % 60
        uptime = string.format("up %dm%02ds", m, s)
    end
    local right = string.format("ID:%-3d  %s ", os.getComputerID(), uptime)
    local header = (" " .. _con.title .. string.rep(" ", sw)):sub(1, sw - #right) .. right
    buf:drawLine(1, header, "f", "5")

    local proto = _protocol or "(no protocol)"
    local nClients = 0
    for _ in pairs(_clients) do nClients = nClients + 1 end
    local status = string.format(" proto: %-20s  clients: %d", proto, nClients)
    buf:drawLine(sh, status, "0", "8")

    local logH = sh - 2
    local startIdx = math.max(1, #_con.lines - logH + 1)
    local row = 2

    for i = startIdx, math.min(startIdx + logH - 1, #_con.lines) do
        local line = _con.lines[i]
        buf:drawLine(row, line.text, line.fore, "f")
        row = row + 1
    end

    while row < sh do
        buf:drawLine(row, "", "0", "f")
        row = row + 1
    end

    buf:present()
end

--- Enable the server console. Call before server.run().
---@param title? string Optional title string shown in the header.
function server.showConsole(title)
    _con.enabled = true
    if title then _con.title = title end
end

--- Write a line to the server console.
---@param text any Message to log.
---@param level? "info"|"warn"|"error"|"success"|"system"|"debug"
function server.log(text, level)
    _consolePush(tostring(text), level or "info")
end

-- ─── Packet Helpers ───────────────────────────────────────────────────────────

local function makePacket(msgType, data)
    return {
        type = msgType,
        data = data or {},
        sender = os.getComputerID(),
        timestamp = os.epoch("utc"),
    }
end

-- ─── Client Management ────────────────────────────────────────────────────────

--- Returns all currently connected client IDs as a list.
---@return number[] list List of connected client IDs
function server.getClients()
    local list = {}
    for id in pairs(_clients) do
        list[#list + 1] = id
    end
    return list
end

--- Returns the number of connected clients.
---@return number count Count of connected clients
function server.clientCount()
    local n = 0
    for _ in pairs(_clients) do n = n + 1 end
    return n
end

--- Returns true if the given client ID is connected.
---@param clientId number Client ID to check
---@return boolean isConnected True if the client is currently connected, false otherwise
function server.isConnected(clientId)
    return _clients[clientId] ~= nil
end

--- Store arbitrary key/value metadata on a connected client.
---@param clientId number Client ID of the client
---@param key string Metadata key
---@param value any Metadata value
function server.setMeta(clientId, key, value)
    if _clients[clientId] then
        _clients[clientId].meta[key] = value
    end
end

--- Retrieve metadata from a connected client. Returns nil if not found.
---@param clientId number Client ID of the client
---@param key string Metadata key
---@return any|nil data Metadata value or nil if not found
function server.getMeta(clientId, key)
    if _clients[clientId] then
        return _clients[clientId].meta[key]
    end
    return nil
end

-- Internal: remove client and clean up rooms
---@param clientId number Client ID to remove
local function _removeClient(clientId)
    if not _clients[clientId] then return end
    _clients[clientId] = nil

    for roomName, members in pairs(_rooms) do
        members[clientId] = nil
        local count = 0
        for _ in pairs(members) do count = count + 1 end
        if count == 0 then _rooms[roomName] = nil end
    end

    if _onDisconnectCb then
        pcall(_onDisconnectCb, clientId)
    end
    server._emit("server.clientDisconnect", clientId)
    logger.info("Server: Client " .. clientId .. " disconnected")
    _consolePush("Client #" .. clientId .. " disconnected", "warn")
end

--- Kick a client from the server with an optional reason string.
---@param clientId number Client ID to kick
---@param reason? string Optional reason for the kick, sent to the client before disconnecting
function server.kick(clientId, reason)
    if not _clients[clientId] then return end
    server.send(clientId, "SERVER_KICK", { reason = reason or "Kicked by server" })
    _removeClient(clientId)
end


-- ─── Rooms ────────────────────────────────────────────────────────────────────

--- Add a client to a named room (creates it if it doesn't exist).
---@param clientId number Client ID to add to the room
---@param roomName string Name of the room to join
function server.joinRoom(clientId, roomName)
    if not _clients[clientId] then return end
    if not _rooms[roomName] then _rooms[roomName] = {} end
    _rooms[roomName][clientId] = true
end

--- Remove a client from a named room.
---@param clientId number Client ID to remove from the room
---@param roomName string Name of the room to leave
function server.leaveRoom(clientId, roomName)
    if _rooms[roomName] then
        _rooms[roomName][clientId] = nil
    end
end

--- Returns a list of client IDs currently in the given room.
---@param roomName string Name of the room to query
---@return number[] list List of client IDs in the room, or empty list if room doesn't exist
function server.getRoomClients(roomName)
    local list = {}
    if _rooms[roomName] then
        for id in pairs(_rooms[roomName]) do
            list[#list + 1] = id
        end
    end
    return list
end

--- Returns a list of room names the given client is a member of.
---@param clientId number Client ID to query
---@return string[] list List of room names the client is a member of
function server.getClientRooms(clientId)
    local list = {}
    for roomName, members in pairs(_rooms) do
        if members[clientId] then
            list[#list + 1] = roomName
        end
    end
    return list
end

-- ─── Messaging ────────────────────────────────────────────────────────────────

--- Send a typed message to a specific client.
---@param clientId number Client ID of the recipient
---@param msgType string Message type identifier
---@param data? table Optional message data payload
---@return boolean success True if the message was sent successfully, false if the client is not connected or network is closed
function server.send(clientId, msgType, data)
    if not network.isOpen then return false end
    local pkt = makePacket(msgType, data)
    rednet.send(clientId, pkt, _protocol)
    return true
end

--- Broadcast a typed message to all connected clients.
---@param msgType string Message type identifier
---@param data? table Optional message data payload
---@param exceptId? number Optional client ID to skip
function server.broadcast(msgType, data, exceptId)
    if not network.isOpen then return end
    local pkt = makePacket(msgType, data)
    for id in pairs(_clients) do
        if id ~= exceptId then
            rednet.send(id, pkt, _protocol)
        end
    end
end

--- Broadcast a message to all clients in a specific room.
---@param roomName string Name of the room to broadcast to
---@param msgType string Message type identifier
---@param data? table Optional message data payload
---@param exceptId? number Optional client ID to skip
function server.broadcastRoom(roomName, msgType, data, exceptId)
    if not _rooms[roomName] then return end
    local pkt = makePacket(msgType, data)
    for id in pairs(_rooms[roomName]) do
        if id ~= exceptId and _clients[id] then
            rednet.send(id, pkt, _protocol)
        end
    end
end

-- ─── Handlers & Middleware ────────────────────────────────────────────────────

--- Register a handler for a specific message type.
---@param msgType string Message type identifier
---@param fn fun(clientId: number, data: table, packet: NetworkPacket) Handler function that processes incoming messages of the specified type. Receives the client ID, message data, and the full packet as arguments.
function server.on(msgType, fn)
    _handlers[msgType] = fn
end

--- Remove a message type handler.
---@param msgType string Message type identifier
function server.off(msgType)
    _handlers[msgType] = nil
end

--- Add middleware that runs before every message handler.
---@param fn fun(clientId: number, packet: NetworkPacket, next: function) Middleware function that runs before message handlers. Receives the client ID, full packet, and a `next` function to call to continue processing. Middleware can modify the packet or perform actions before or after calling `next()`.
function server.use(fn)
    _middleware[#_middleware + 1] = fn
end

local function _dispatch(clientId, packet)
    local i = 0
    local function next()
        i = i + 1
        if i <= #_middleware then
            local ok, err = pcall(_middleware[i], clientId, packet, next)
            if not ok then
                logger.error("Server middleware error: " .. tostring(err))
            end
        else
            local handler = _handlers[packet.type]
            if handler then
                local ok, err = pcall(handler, clientId, packet.data or {}, packet)
                if not ok then
                    logger.error("Server handler error [" .. tostring(packet.type) .. "]: " .. tostring(err))
                end
            end
        end
    end
    next()
end

-- ─── Connection Callbacks ─────────────────────────────────────────────────────

--- Called when a new client connects. fn(clientId)
---@param fn fun(clientId: number) Callback function that is called when a new client connects. Receives the client ID as an argument.
function server.onConnect(fn)
    _onConnectCb = fn
end

--- Called when a client disconnects. fn(clientId)
---@param fn fun(clientId: number) Callback function that is called when a client disconnects. Receives the client ID as an argument.
function server.onDisconnect(fn)
    _onDisconnectCb = fn
end

-- ─── Built-in Auth System ─────────────────────────────────────────────────────
--
-- Opt-in auth layer. Activate with server.enableAuth(db, opts).
-- Once enabled, the server automatically handles LOGIN, REGISTER, and LOGOUT
-- messages and exposes server.auth.* helpers for game code.
--
-- Usage:
--   local players = Engine.db.open("players", { autosave = true })
--   server.enableAuth(players, {
--       minNameLen  = 3,   -- default 3
--       maxNameLen  = 16,  -- default 16
--       minPwLen    = 4,   -- default 4
--       onLogin     = function(clientId, profile) end,   -- optional
--       onRegister  = function(clientId, profile) end,   -- optional
--       onLogout    = function(clientId, profile) end,   -- optional
--   })
--
-- After login/register, game handlers can guard with:
--   if not server.auth.isLoggedIn(clientId) then
--       server.send(clientId, "AUTH_REQUIRED", {}); return
--   end

--- Auth config structure
---@class AuthOptions
---@field minNameLen? number Minimum allowed username length (default 3)
---@field maxNameLen? number Maximum allowed username length (default 16)
---@field minPwLen? number Minimum allowed password length (default 4)
---@field onLogin? fun(clientId: number, profile: ServerProfile) Optional callback fired after successful login
---@field onRegister? fun(clientId: number, profile: ServerProfile) Optional callback fired after successful registration
---@field onLogout? fun(clientId: number, profile: ServerProfile) Optional callback fired after logout
---@field buildProfile? fun(clientId: number, data: table): table Optional function to build a complete profile on registration. Receives the client ID and original registration data, should return a table of additional profile fields to merge into the stored profile (e.g. starting stats or inventory).

--- Auth profile structure (stored in DB)
---@class AuthSystem
---@field enabled boolean Whether the auth system is enabled
---@field db Collection The Obsidian DB collection used to store user profiles
---@field sessions table Active login sessions, indexed by client ID (clientId → profile)
---@field nonces table One-time login nonces for challenge-response authentication, indexed by client ID (clientId → { nonce, name, expireAt })
---@field attempts table Failed login attempt tracking for rate limiting, indexed by client ID (clientId
---@field opts AuthOptions Configuration options for the auth system
local _auth = {
    enabled = false,
    db = nil,
    sessions = {}, -- [clientId] = profile
    nonces = {}, -- [clientId] = { nonce, name, expireAt }
    attempts = {}, -- [clientId] = { count, resetAt }
    opts = {},
}

local function _djb2(str)
    local h = 5381
    for i = 1, #str do
        h = ((h * 33) + string.byte(str, i)) % 2147483647
    end
    return tostring(h)
end

local function _safeProfile(profile)
    local out = {}
    for k, v in pairs(profile) do
        if k ~= "passwordHash" then out[k] = v end
    end
    return out
end

--- Enable the built-in auth system.
---@param db Collection An Obsidian DB collection
---@param opts? AuthOptions Optional configuration for the auth system (e.g. password requirements)
function server.enableAuth(db, opts)
    assert(db, "server.enableAuth: db must be an Obsidian DB collection")
    opts = opts or {}
    _auth.db = db
    _auth.opts = opts
    _auth.enabled = true

    local minNameLen = opts.minNameLen or 3
    local maxNameLen = opts.maxNameLen or 16
    local minPwLen = opts.minPwLen or 4

    _handlers["REGISTER"] = function(clientId, data)
        local name = tostring(data.name or "")
        local passwordHash = tostring(data.passwordHash or "")
        local class = data.class

        if #name < minNameLen or #name > maxNameLen then
            server.send(clientId, "REGISTER_FAILED",
                { message = "Name must be " .. minNameLen .. "-" .. maxNameLen .. " characters." })
            return
        end
        if name:match("[^%w_%-]") then
            server.send(clientId, "REGISTER_FAILED",
                { message = "Name may only contain letters, numbers, - and _" })
            return
        end
        if #passwordHash == 0 then
            server.send(clientId, "REGISTER_FAILED",
                { message = "Password must be at least " .. minPwLen .. " characters." })
            return
        end
        if _auth.db:findOne({ name = name }) then
            server.send(clientId, "REGISTER_FAILED", { message = "Name already taken." })
            return
        end

        local profile = {
            cid = clientId,
            name = name,
            passwordHash = passwordHash,  -- already hashed by client
            class = class,
        }
        if opts.buildProfile then
            local extra = opts.buildProfile(clientId, data) or {}
            for k, v in pairs(extra) do profile[k] = v end
        end
        _auth.db:insert(profile)
        _auth.sessions[clientId] = profile
        logger.info("Auth: '" .. name .. "' registered (client " .. clientId .. ")")
        _consolePush("Auth: '" .. name .. "' registered", "success")
        server.send(clientId, "REGISTER_SUCCESS", { profile = _safeProfile(profile) })
        if opts.onRegister then pcall(opts.onRegister, clientId, profile) end
    end

    _handlers["LOGIN_CHALLENGE_REQUEST"] = function(clientId, data)
        local now = os.epoch("utc") / 1000
        local att = _auth.attempts[clientId]
        if att and now < att.resetAt then
            server.send(clientId, "LOGIN_FAILED", { message = string.format(
                "Too many failed attempts. Try again in %ds.", math.ceil(att.resetAt - now)) })
            return
        end
        local name = tostring(data.name or "")
        math.randomseed(os.epoch("utc") + clientId)
        local nonce = tostring(math.random(10000000, 99999999)) .. tostring(os.epoch("utc") % 1000000)
        _auth.nonces[clientId] = { nonce = nonce, name = name, expireAt = now + 30 }
        server.send(clientId, "LOGIN_CHALLENGE", { nonce = nonce })
    end

    _handlers["LOGIN"] = function(clientId, data)
        local now = os.epoch("utc") / 1000
        local entry = _auth.nonces[clientId]
        local name = tostring(data.name or "")
        local response = tostring(data.response or "")

        if not entry or entry.name ~= name or now > entry.expireAt then
            _auth.nonces[clientId] = nil
            server.send(clientId, "LOGIN_FAILED", { message = "Challenge expired. Please try again." })
            return
        end
        _auth.nonces[clientId] = nil  -- one-time use

        local profile = _auth.db:findOne({ name = name })
        if not profile or _djb2(profile.passwordHash .. entry.nonce) ~= response then
            local att = _auth.attempts[clientId] or { count = 0, resetAt = 0 }
            att.count = att.count + 1
            if att.count >= 5 then
                att.resetAt = now + 60
                att.count   = 0
                _consolePush("Auth: Client #" .. clientId .. " rate-limited", "warn")
            end
            _auth.attempts[clientId] = att
            server.send(clientId, "LOGIN_FAILED", { message = "Wrong username or password." })
            _consolePush("Auth: Failed login for '" .. name .. "'", "warn")
            return
        end

        _auth.attempts[clientId] = nil
        if profile.cid ~= clientId then
            _auth.db:update({ name = name }, { cid = clientId })
            profile.cid = clientId
        end
        _auth.sessions[clientId] = profile
        logger.info("Auth: '" .. name .. "' logged in (client " .. clientId .. ")")
        _consolePush("Auth: '" .. name .. "' logged in", "success")
        server.send(clientId, "LOGIN_SUCCESS", { profile = _safeProfile(profile) })
        if opts.onLogin then pcall(opts.onLogin, clientId, profile) end
    end

    _handlers["LOGOUT"] = function(clientId)
        local profile = _auth.sessions[clientId]
        _auth.sessions[clientId] = nil
        if profile then
            logger.info("Auth: '" .. profile.name .. "' logged out (client " .. clientId .. ")")
            _consolePush("Auth: '" .. profile.name .. "' logged out", "info")
        end
        if opts.onLogout then pcall(opts.onLogout, clientId, profile) end
    end
end

server.auth = {
    --- Returns true if the client is currently logged in.
    ---@param clientId number Client ID to check
    ---@return boolean isLoggedIn True if the client has an active session, false otherwise
    isLoggedIn = function(clientId)
        return _auth.sessions[clientId] ~= nil
    end,
    --- Returns the in-memory profile for a logged-in client, or nil.
    ---@param clientId number Client ID to query
    ---@return ServerProfile|nil profile The client's profile from the active session, or nil if not logged in
    getProfile = function(clientId)
        return _auth.sessions[clientId]
    end,
    --- Manually clear a client's session (e.g. on disconnect).
    ---@param clientId number Client ID to log out
    logout = function(clientId)
        _auth.sessions[clientId] = nil
    end,
    --- Convenience guard: sends AUTH_REQUIRED and returns false if not logged in.
    ---@param clientId number Client ID to check
    ---@return boolean True if the client is logged in, false otherwise
    require = function(clientId)
        if not _auth.sessions[clientId] then
            server.send(clientId, "AUTH_REQUIRED", { message = "Please log in first." })
            return false
        end
        return true
    end,
}


-- ─── Tick System ─────────────────────────────────────────────────────────────

--- Register a callback to be called every server tick. fn(dt)
---@param fn fun(dt: number) Callback function that is called every server tick. Receives the delta time in seconds since the last tick as an argument.
function server.onTick(fn)
    _tickCbs[#_tickCbs + 1] = fn
end

--- Set the server tick rate (ticks per second, default 20).
---@param n number Desired tick rate (ticks per second). Must be a positive number; values less than 1 will be treated as 1.
function server.setTickRate(n)
    _tickRate = math.max(1, n)
end

--- Set the client timeout in seconds (0 to disable). Default 30.
---@param seconds number Desired timeout in seconds. Set to 0 to disable.
function server.setTimeout(seconds)
    _timeout = seconds
end

--- Set the heartbeat interval in seconds (0 to disable). Default 5.
---@param seconds number Desired heartbeat interval in seconds. Set to 0 to disable automatic heartbeats.
function server.setHeartbeatInterval(seconds)
    _heartbeat = seconds
end

--- Enable per-client message sequence numbers.
function server.enableSequencing()
    _seqEnabled = true
end

--- Returns the last measured ping (ms) for a client, or nil if unknown.
---@param clientId number Client ID to query
---@return number|nil ping Last measured ping in milliseconds, or nil if no heartbeat response received yet
function server.getPing(clientId)
    local c = _clients[clientId]
    return c and c.ping or nil
end

--- Send a typed message to a list of specific client IDs.
---@param idList number[] List of client IDs to send the message to
---@param msgType string Message type identifier
---@param data? table Optional message data payload
function server.sendToList(idList, msgType, data)
    if not network.isOpen then return end
    local pkt = makePacket(msgType, data)
    for _, id in ipairs(idList) do
        if _clients[id] then
            rednet.send(id, pkt, _protocol)
        end
    end
end

-- ─── Init & Lifecycle ─────────────────────────────────────────────────────────

--- Initialise the server: open modem, host protocol.
---@param protocol string Protocol name to host (must match what clients connect to)
---@param hostname string Human-readable server name (used for discovery, can be same as protocol)
---@param side? string Optional modem side to use (e.g. "back"); if not specified, will use the first available modem
---@return boolean success True if the server was successfully initialized, false if there was an error (e.g. no modem found or failed to host protocol)
function server.init(protocol, hostname, side)
    _protocol = protocol

    if not network.open(side) then
        logger.error("Server: No modem found!")
        return false
    end

    if not network.host(protocol, hostname) then
        logger.error("Server: Failed to host protocol '" .. protocol .. "'")
        return false
    end

    _hostname = hostname
    logger.info(string.format("Server: Online | protocol='%s' hostname='%s' id=%d",
        protocol, hostname, os.getComputerID()))
    return true
end

--- Shut down the server, kick all clients, and close the modem.
function server.stop()
    if not _running then return end
    _running = false
    server.broadcast("SERVER_SHUTDOWN", { reason = "Server shutting down" })
    local toRemove = {}
    for id in pairs(_clients) do toRemove[#toRemove + 1] = id end
    for _, id in ipairs(toRemove) do _clients[id] = nil end
    _rooms = {}
    network.close()
    _consolePush("Server stopped.", "system")
    _consoleRender()
    server._emit("server.stopped")
    logger.info("Server: Stopped")
end

-- ─── Internal Event Processing ───────────────────────────────────────────────

local function _handleRednet(senderId, pkt, proto)
    if proto ~= _protocol then return end

    if type(pkt) ~= "table" or not pkt.type then return end

    if type(pkt) == "table" and pkt.type == "DISCOVER" and pkt.hostname == _hostname then
        logger.info("Server: DISCOVER from " .. tostring(senderId) .. " — replying")
        rednet.send(senderId, { type = "DISCOVER_REPLY", hostname = _hostname,
                                serverId = os.getComputerID() }, proto)
        return
    end

    -- update last-seen
    if _clients[senderId] then
        _clients[senderId].lastSeen = os.epoch("utc") / 1000
    end

    -- Built-in: connection handshake
    if pkt.type == "CONNECT_REQUEST" then
        _clients[senderId] = {
            id = senderId,
            meta = {},
            joinedAt = os.epoch("utc") / 1000,
            lastSeen = os.epoch("utc") / 1000,
            ping = nil,
            heartbeatSent = nil,
            lastSeq = -1,
        }
        rednet.send(senderId, makePacket("CONNECT_ACCEPT", {
            serverId = os.getComputerID(),
            serverTime = os.epoch("utc"),
        }), _protocol)

        if _onConnectCb then pcall(_onConnectCb, senderId) end
        server._emit("server.clientConnect", senderId)
        logger.info("Server: Client " .. senderId .. " connected")
        _consolePush("Client #" .. senderId .. " connected", "success")
        return
    end

    if pkt.type == "CLIENT_LEAVE" then
        _removeClient(senderId)
        return
    end

    if not _clients[senderId] then return end

    -- The low-level Obsidian client actively pings its server. Dedicated
    -- servers use this high-level event loop instead of network.processEvent(),
    -- so they must answer that PING here themselves.
    if pkt.type == "PING" then
        local pingTime = pkt.t or (type(pkt.data) == "table" and pkt.data.t)
        rednet.send(senderId, makePacket("PONG", { t=pingTime }), _protocol)
        return
    end

    if pkt.type == "PONG" then
        local c = _clients[senderId]
        if c and c.heartbeatSent then
            c.ping = math.floor((os.epoch("utc") - c.heartbeatSent))
            c.heartbeatSent = nil
        end
        return
    end
    if _seqEnabled and pkt.seq then
        local c = _clients[senderId]
        if pkt.seq <= c.lastSeq then return end
        c.lastSeq = pkt.seq
    end

    _dispatch(senderId, pkt)
end

-- ─── Main Loop ────────────────────────────────────────────────────────────────

local _tickTimer = nil
local _lastTick  = 0

local function _runTick()
    local now = os.epoch("utc") / 1000
    local dt = now - _lastTick
    _lastTick = now

    for id, info in pairs(_clients) do
        if _timeout > 0 and now - info.lastSeen > _timeout then
            logger.warn("Server: Client " .. id .. " timed out")
            _consolePush(string.format("Client #%d timed out", id), "warn")
            server.kick(id, "Timed out")
        elseif _heartbeat > 0 and not info.heartbeatSent and
               (now - info.lastSeen) >= _heartbeat then
            info.heartbeatSent = os.epoch("utc")
            rednet.send(id, makePacket("PING", { t = info.heartbeatSent }), _protocol)
        end
    end

    for _, fn in ipairs(_tickCbs) do
        local ok, err = pcall(fn, dt)
        if not ok then
            logger.error("Server tick error: " .. tostring(err))
            _consolePush("Tick error: " .. tostring(err), "error")
        end
    end

    _con.dirty = true
    _consoleRender()
    _tickTimer = os.startTimer(1 / _tickRate)
end

--- Process a single raw OS event. Called by server.run() internally or by the
-- Engine event loop for non-blocking integrated use.
---@param rawEvent table The raw event table as returned by os.pullEventRaw()
function server.processEvent(rawEvent)
    local evName = rawEvent[1]
    if evName == "rednet_message" then
        _handleRednet(rawEvent[2], rawEvent[3], rawEvent[4])
    elseif evName == "term_resize" then
        _con.dirty = true
    elseif evName == "timer" and rawEvent[2] == _tickTimer then
        _runTick()
    end
end

--- Start the server without blocking. Events must be fed via server.processEvent()
-- or by calling server.run(). Returns false if server.init() was not called first.
---@return boolean success True if the server started successfully, false if server.init() was not called
function server.start()
    if not _protocol then
        logger.error("Server: Call server.init() before server.start()")
        return false
    end
    _running = true
    _lastTick = os.epoch("utc") / 1000
    _con.startTime = _lastTick
    _tickTimer = os.startTimer(1 / _tickRate)
    server._emit("server.started")
    logger.info("Server: Running at " .. _tickRate .. " ticks/s")
    _consolePush("Server started on " .. (_protocol or "?"), "system")
    if _con.enabled then
        local sw, sh = term.getSize()
        _rebuildLines(sw)
        _con.lastWidth  = sw
        _con.lastHeight = sh
    end
    return true
end

--- Run the server loop (blocking, for dedicated server computers).
-- Equivalent to server.start() followed by a manual os.pullEventRaw() loop.
function server.run()
    if not server.start() then return end
    while _running do
        local rawEvent = { os.pullEventRaw() }
        if rawEvent[1] == "terminate" then
            logger.info("Server: Terminate signal received")
            server.stop()
            break
        end
        server.processEvent(rawEvent)
    end
end

return server
