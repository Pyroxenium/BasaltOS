-- Obsidian Engine: Low-level Network (Rednet Wrapper)

---@diagnostic disable: undefined-global

local logger = require("core.logger")

--- Network Client class representing a connected client on the host.
---@class NetworkClient
---@field id number Computer ID
---@field connectedAt number Timestamp (epoch ms)
---@field lastPing number Last received ping timestamp

--- Network Module providing high-level APIs for hosting, connecting, and messaging over rednet.
---@class NetworkModule
---@field modemSide string|nil The side the modem is on (if any)
---@field isOpen boolean Whether the modem is open
---@field isHost boolean Whether this computer is currently hosting a protocol
---@field serverId number|nil The server ID this client is connected to (if any)
---@field clients table<number, NetworkClient> Table of connected clients (host only)
---@field _protocol string|nil The protocol currently in use for hosting/connecting
---@field _hostname string|nil The hostname this computer is hosting as (if any)
---@field _connecting boolean Internal flag indicating if a connection attempt is in progress
---@field _emit any Event emitter function (set by Engine) for emitting network events
---@field _heartbeatInterval number Seconds between heartbeat pings (default: 10)
---@field _heartbeatTimeout number Seconds before client is considered dead (default: 30)
---@field _lastPingTime table<number, number> Last ping time per client/server
---@field _heartbeatThread Thread|nil Thread ID for heartbeat system
local network = {
    modemSide = nil,
    isOpen = false,
    isHost = false,
    serverId = nil,
    clients = {},
    _protocol = nil,
    _hostname = nil,
    _connectCallback = nil,
    _connecting = false,
    _emit = function() end,
    _heartbeatInterval = 10,
    _heartbeatTimeout = 30,
    _lastPingTime = {},
    _heartbeatThread = nil
}

local _anyMessageHandlers = {}
local _msgTypeHandlers = {}

--- Register a handler that receives all incoming messages.
---@param fn fun(sender:number, message:any, protocol?:string)
---@return fun() unsubscribe Unsubscribe the handler
function network.onMessage(fn)
    table.insert(_anyMessageHandlers, fn)
    return function()
        for i, h in ipairs(_anyMessageHandlers) do
            if h == fn then table.remove(_anyMessageHandlers, i); break end
        end
    end
end

--- Remove a handler previously registered with `onMessage`.
---@param fn function The handler function to remove
function network.offMessage(fn)
    for i, h in ipairs(_anyMessageHandlers) do
        if h == fn then table.remove(_anyMessageHandlers, i); break end
    end
end

--- Register a handler for a given message.type.
---@param typeName string The message.type to handle
---@param fn fun(sender:number, message:any, protocol?:string)
---@return fun() unsubscribe Unsubscribe the handler
function network.onMessageType(typeName, fn)
    if not _msgTypeHandlers[typeName] then _msgTypeHandlers[typeName] = {} end
    table.insert(_msgTypeHandlers[typeName], fn)
    return function()
        local bucket = _msgTypeHandlers[typeName]
        if not bucket then return end
        for i, h in ipairs(bucket) do
            if h == fn then table.remove(bucket, i); break end
        end
    end
end

--- Remove a previously-registered message.type handler.
--- Note: Only removes the first occurrence if the function was registered multiple times.
---@param typeName string The message.type to handle
---@param fn function The handler function to remove
function network.offMessageType(typeName, fn)
    local bucket = _msgTypeHandlers[typeName]
    if not bucket then return end
    for i, h in ipairs(bucket) do
        if h == fn then table.remove(bucket, i); break end
    end
end

local function _startHeartbeat()
    if network._heartbeatThread then return end -- already running

    local thread = require("core.thread")
    network._heartbeatThread = thread.start(function()
        while network.isOpen and (network.isHost or network.serverId) do
            local now = os.epoch("utc")

            if network.isHost then
                local deadClients = {}
                for clientId, client in pairs(network.clients) do
                    local lastPing = client.lastPing or client.connectedAt
                    if (now - lastPing) > (network._heartbeatTimeout * 1000) then
                        logger.warn("Network: Client " .. clientId .. " timed out (no ping for " .. 
                                  math.floor((now - lastPing) / 1000) .. "s)")
                        table.insert(deadClients, clientId)
                    else
                        network.send(clientId, { type = "PING", t = now }, network._protocol)
                    end
                end

                for _, clientId in ipairs(deadClients) do
                    network.clients[clientId] = nil
                    network._emit("network.clientTimeout", clientId)
                end

            elseif network.serverId then
                -- Client: ping server and check for timeout
                local lastPing = network._lastPingTime[network.serverId]
                if lastPing and (now - lastPing) > (network._heartbeatTimeout * 1000) then
                    logger.warn("Network: Server " .. network.serverId .. " timed out")
                    local oldServerId = network.serverId
                    network.serverId = nil
                    network._emit("network.serverTimeout", oldServerId)
                    break -- stop heartbeat
                else
                    network.send(network.serverId, { type = "PING", t = now }, network._protocol)
                end
            end

            sleep(network._heartbeatInterval)
        end

        network._heartbeatThread = nil
        logger.info("Network: Heartbeat thread stopped")
    end)
end

local function _stopHeartbeat()
    if network._heartbeatThread then
        local thread = require("core.thread")
        thread.stop(network._heartbeatThread)
        network._heartbeatThread = nil
        logger.info("Network: Heartbeat stopped")
    end
end

--- Open one or more modems.
---@param side? string Specific side to open. If nil, searches all sides.
---@return boolean success True if at least one modem was opened successfully.
function network.open(side)
    if side then
        if peripheral.getType(side) == "modem" then
            rednet.open(side)
            network.modemSide = side
            network.isOpen = true
            logger.info("Network: Modem opened on side " .. side .. " (ID: " .. os.getComputerID() .. ")")
            return true
        end
    else
        local modems = { peripheral.find("modem") }
        if #modems > 0 then
            for _, m in ipairs(modems) do
                local s = peripheral.getName(m)
                rednet.open(s)
                network.modemSide = s
            end
            network.isOpen = true
            logger.info("Network: " .. #modems .. " modem(s) opened. Local ID: " .. os.getComputerID())
            return true
        end
    end
    return false
end

--- Close all open modems.
function network.close()
    if network.isOpen then
        _stopHeartbeat()
        local modems = { peripheral.find("modem") }
        for _, m in ipairs(modems) do
            rednet.close(peripheral.getName(m))
        end
        network.isOpen = false
        logger.info("Network: All modems closed")
    end
end

--- Disconnect from current session and close modems.
--- Sends SERVER_SHUTDOWN if host, or CLIENT_LEAVE if client.
function network.disconnect()
    if not network.isOpen then return end
    local protocol = network._protocol
    if network.isHost then
        network.broadcast({ type = "SERVER_SHUTDOWN" }, protocol)
    elseif network.serverId then
        network.send(network.serverId, { type = "CLIENT_LEAVE" }, protocol)
    end

    network.isHost = false
    network.serverId = nil
    network._protocol = nil
    network._hostname = nil
    network.clients = {}
    network._lastPingTime = {}
    network.close()
end

--- Send a message to a specific target.
---@param targetId number Computer ID of the target
---@param message any Message to send (can be any serializable value)
---@param protocol? string Optional protocol to send on (defaults to current protocol)
---@return boolean success True if the message was sent successfully
function network.send(targetId, message, protocol)
    if not network.isOpen then return false end

    local proto = protocol or network._protocol
    if not proto then
        logger.warn("Network: send() called with no protocol specified and no default set")
        return false
    end

    rednet.send(targetId, message, proto)
    return true
end

--- Broadcast a message to all reachable computers on the protocol.
---@param message any Message to broadcast (can be any serializable value)
---@param protocol? string Optional protocol to broadcast on (defaults to current protocol)
---@return boolean success True if the message was broadcast successfully
function network.broadcast(message, protocol)
    if not network.isOpen then return false end

    local proto = protocol or network._protocol
    if not proto then
        logger.warn("Network: broadcast() called with no protocol specified and no default set")
        return false
    end

    rednet.broadcast(message, proto)
    return true
end

--- Connect to a server.
---@param protocol string Protocol to connect on
---@param hostname string Hostname to connect to
---@param callback? fun(ok: boolean, reason: number|string) result callback
---@param timeout? number Seconds to wait (default 5)
---@return boolean ok True if the connection process started successfully, false if there was an immediate error (e.g. no modem, already connecting)
---@return string? reason Error reason if the connection process failed to start, or if an immediate error occurred. Note that connection failures after starting will be reported via the callback and "network.connectionFailed" event, not this return value.
function network.connect(protocol, hostname, callback, timeout)
    timeout = timeout or 5
    logger.info("Network: connect() called — protocol='" .. tostring(protocol) .. "' hostname='" .. tostring(hostname) .. "' timeout=" .. tostring(timeout))

    if not network.isOpen then
        logger.info("Network: modem not open, attempting auto-open")
        local opened = network.open()
        if not opened then
            local err = "No modem found"
            logger.warn("Network: connect() failed — " .. err)
            if callback then callback(false, err) end
            return false, err
        end
    end

    if network._connecting then
        local err = "Already connecting"
        logger.warn("Network: connect() rejected — " .. err)
        if callback then callback(false, err) end
        return false, err
    end

    network._connecting      = true
    network._connectCallback = callback
    network._protocol        = protocol
    logger.info("Network: starting connect thread")

    local function _cleanup(ok, reason)
        local cb = network._connectCallback
        network._connectCallback = nil
        network._connecting = false
        if cb then cb(ok, reason) end
    end

    local thread = require("core.thread")
    thread.start(function()
        local success, err = pcall(function()
            logger.info("Network: [thread] looking up '" .. tostring(hostname) .. "' on protocol '" .. tostring(protocol) .. "'")
            local lookupOk, id_or_err = pcall(rednet.lookup, protocol, hostname)
            local id = lookupOk and id_or_err or nil
            logger.info("Network: [thread] lookup result — ok=" .. tostring(lookupOk) .. " id=" .. tostring(id))

            if not id then
                logger.info("Network: [thread] DNS lookup failed, trying broadcast DISCOVER")
                rednet.broadcast({ type = "DISCOVER", hostname = hostname }, protocol)
                local discoverTimer = os.startTimer(3)
                while true do
                    local ev, p1, p2, p3 = os.pullEvent()
                    if ev == "rednet_message" then
                        local msg, proto2 = p2, p3
                        if type(msg) == "table" and msg.type == "DISCOVER_REPLY"
                                and msg.hostname == hostname and proto2 == protocol then
                            id = p1
                            logger.info("Network: [thread] DISCOVER_REPLY from " .. tostring(id))
                            os.cancelTimer(discoverTimer)
                            break
                        end
                    elseif ev == "timer" and p1 == discoverTimer then
                        logger.warn("Network: [thread] broadcast discovery timed out")
                        break
                    end
                end
            end

            if not id then
                local errMsg = (not lookupOk) and tostring(id_or_err) or "Server not found"
                logger.warn("Network: [thread] connect failed — " .. errMsg)
                _cleanup(false, errMsg)
                network._emit("network.connectionFailed", protocol, hostname)
                return
            end

            logger.info("Network: [thread] sending CONNECT_REQUEST to server ID " .. tostring(id))
            rednet.send(id, { type = "CONNECT_REQUEST" }, protocol)

            logger.info("Network: [thread] waiting up to " .. timeout .. "s for CONNECT_ACCEPT")
            local t = os.startTimer(timeout)
            local connectionEvent = "network_connect_" .. tostring(id)

            while true do
                local ev, p1 = os.pullEvent()
                if ev == "timer" and p1 == t then
                    if network._connecting then
                        logger.warn("Network: [thread] timed out waiting for CONNECT_ACCEPT")
                        _cleanup(false, "Connection timed out")
                        network._emit("network.connectionFailed", protocol, hostname)
                    end
                    break
                elseif ev == connectionEvent then
                    -- Connection was accepted (fired by processEvent)
                    os.cancelTimer(t)
                    logger.info("Network: [thread] connection established")
                    _cleanup(true, id)
                    break
                elseif not network._connecting then
                    os.cancelTimer(t)
                    -- processEvent handles CONNECT_ACCEPT before the cooperative
                    -- connection thread sees the same rednet event. It therefore
                    -- clears _connecting and records serverId first. Treat that
                    -- state as a successful handshake so the caller's callback
                    -- still runs instead of remaining stuck on "connecting".
                    if network.serverId == id then
                        logger.info("Network: [thread] connection established by processEvent")
                        _cleanup(true, id)
                    else
                        logger.info("Network: [thread] _connecting cleared externally, exiting wait")
                    end
                    break
                end
            end
        end)

        if not success then
            logger.error("Network: [thread] crashed: " .. tostring(err))
            _cleanup(false, "Internal error: " .. tostring(err))
            network._emit("network.connectionFailed", protocol, hostname)
        end
    end)
    return true
end

--- Cancel an in-flight connection attempt.
---@param reason? string Reason for cancellation
function network.cancelConnect(reason)
    if not network._connecting then return end
    local cb = network._connectCallback
    network._connectCallback = nil
    network._connecting = false
    if cb then cb(false, reason or "Cancelled") end
    logger.info("Network: Connection cancelled — " .. (reason or "No reason"))
end

--- Host a protocol as a specific name.
---@param protocol string Protocol to host
---@param hostname string Hostname to host as
---@return boolean success True if hosting started successfully, false if there was an immediate error (e.g. no modem, already hosting)
function network.host(protocol, hostname)
    if not network.isOpen then 
        logger.warn("Network: Cannot host, modem not open")
        return false 
    end

    rednet.host(protocol, hostname)
    network.isHost    = true
    network._protocol = protocol
    network._hostname = hostname
    logger.info("Network: Now hosting protocol '" .. protocol .. "' as '" .. hostname .. "'")

    _startHeartbeat()
    return true
end

--- Find a computer ID by hostname and protocol.
---@param protocol string Protocol to look up
---@param hostname string Hostname to look up
---@return number|nil id Computer ID if found, or nil if not found or if network is not open
function network.lookup(protocol, hostname)
    if not network.isOpen then return nil end
    return rednet.lookup(protocol, hostname)
end

--- Configure heartbeat settings.
---@param interval? number Seconds between pings (default: 10)
---@param timeout? number Seconds before connection is considered dead (default: 30)
function network.setHeartbeat(interval, timeout)
    if interval then network._heartbeatInterval = interval end
    if timeout then network._heartbeatTimeout = timeout end
    logger.info("Network: Heartbeat configured — interval=" .. network._heartbeatInterval .. "s, timeout=" .. network._heartbeatTimeout .. "s")
end

--- Process raw OS events for network logic.
--- This is called by the engine's main event loop and should not be called directly.
---@param eventData table Raw event data from os.pullEvent
function network.processEvent(eventData)
    if eventData[1] ~= "rednet_message" then return end

    local senderID, message, protocol = eventData[2], eventData[3], eventData[4]

    -- Any packet on the active protocol from the connected server proves that
    -- the connection is alive. The high-level server suppresses PING while it
    -- receives regular client traffic, so requiring a dedicated PING/PONG here
    -- would disconnect active clients after the timeout interval.
    if senderID == network.serverId and protocol == network._protocol then
        network._lastPingTime[senderID] = os.epoch("utc")
    end

    if type(message) ~= "table" then
        network._emit("network.message", senderID, message, protocol)
        -- call any registered generic message handlers
        for _, h in ipairs(_anyMessageHandlers) do
            local ok, err = pcall(h, senderID, message, protocol)
            if not ok then logger.error("Network handler failed: " .. tostring(err)) end
        end
        return
    end

    local msgType = message.type

    if msgType == "DISCOVER" and network.isHost then
        if message.hostname == network._hostname then
            network.send(senderID, { type = "DISCOVER_REPLY", hostname = network._hostname }, protocol)
        end
        return
    end

    if msgType == "CONNECT_REQUEST" and network.isHost then
        logger.info("Network: CONNECT_REQUEST from ID " .. senderID)
        network.clients[senderID] = { 
            id = senderID, 
            connectedAt = os.epoch("utc"),
            lastPing = os.epoch("utc")
        }
        network.send(senderID, { type = "CONNECT_ACCEPT" }, protocol)
        network._emit("network.clientConnect", senderID)
        return
    end

    if msgType == "CONNECT_ACCEPT" then
        logger.info("Network: connected to server " .. senderID)
        network.serverId    = senderID
        network._connecting = false
        network._lastPingTime[senderID] = os.epoch("utc")

        os.queueEvent("network_connect_" .. tostring(senderID))

        network._emit("network.connected", senderID)
        _startHeartbeat()
        return
    end

    if msgType == "PING" then
        -- Update last ping time
        if network.isHost and network.clients[senderID] then
            network.clients[senderID].lastPing = os.epoch("utc")
        elseif senderID == network.serverId then
            network._lastPingTime[senderID] = os.epoch("utc")
        end

        network.send(senderID, { type = "PONG", t = message.t }, protocol)
        return
    end

    if msgType == "PONG" then
        -- Update last ping time
        if network.isHost and network.clients[senderID] then
            network.clients[senderID].lastPing = os.epoch("utc")
        elseif senderID == network.serverId then
            network._lastPingTime[senderID] = os.epoch("utc")
        end
        return
    end

    if msgType == "CLIENT_LEAVE" and network.isHost then
        network.clients[senderID] = nil
        network._emit("network.clientDisconnect", senderID)
        return
    end

    if msgType == "SERVER_SHUTDOWN" and not network.isHost then
        network.serverId = nil
        _stopHeartbeat()
        network._emit("network.serverShutdown", senderID)
        return
    end

    network._emit("network.message", senderID, message, protocol)

    for _, h in ipairs(_anyMessageHandlers) do
        local ok, err = pcall(h, senderID, message, protocol)
        if not ok then logger.error("Network handler failed: " .. tostring(err)) end
    end

    if msgType and _msgTypeHandlers[msgType] then
        for _, h in ipairs(_msgTypeHandlers[msgType]) do
            local ok, err = pcall(h, senderID, message, protocol)
            if not ok then logger.error("Network type handler failed: " .. tostring(err)) end
        end
    end
end

return network
