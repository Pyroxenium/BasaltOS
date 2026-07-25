-- /services/dragdrop.lua
-- OS-wide file Drag & Drop broker shared by Desktop, Filely and future apps.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")
local config = require("core.config")

local api = api_factory.new()

local targets = {}
local active = nil
local registration_counter = 0
local ctrl_down = false
local desktop_frame = nil
local overlay = nil
local overlay_label = nil

local function theme(key, fallback)
    return config.get("theme." .. key) or fallback
end

local function canonicalPath(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("\\", "/"):gsub("^/+", "")
    local ok, combined = pcall(fs.combine, value, "")
    if not ok then return nil end
    return combined == "" and "/" or combined
end

local function clonePaths(paths)
    local result = {}
    for index, path in ipairs(paths or {}) do result[index] = path end
    return result
end

local function snapshot(drag)
    if not drag then return nil end
    return {
        type=drag.type,
        paths=clonePaths(drag.paths),
        label=drag.label,
        source_id=drag.source_id,
        requested_operation=drag.requested_operation,
        operation=drag.requested_operation == "auto"
            and (ctrl_down and "copy" or "move") or drag.requested_operation,
        x=drag.x,
        y=drag.y,
        target_id=drag.target_id,
        destination=drag.destination,
    }
end

local function currentOperation()
    if not active then return nil end
    if active.requested_operation == "auto" then
        return ctrl_down and "copy" or "move"
    end
    return active.requested_operation
end

local function hideOverlay()
    if overlay then overlay:setVisible(false) end
end

local function buildOverlay()
    if overlay then overlay:destroy() end
    overlay, overlay_label = nil, nil
    local ui = service.getService("ui")
    desktop_frame = ui and ui.getScreen("desktop") or nil
    if not desktop_frame then return end

    overlay = desktop_frame:addFrame({
        x=1, y=1, width=18, height=1,
        background=theme("primary", colors.blue),
        visible=false, disabled=true, z=1800,
    })
    overlay_label = overlay:addLabel({
        x=1, y=1, width=18, height=1, text="",
        foreground=theme("text", colors.white),
        background=theme("primary", colors.blue),
        disabled=true,
    })
end

local function pointInElement(element, x, y)
    if not element or not element.getAbsolutePosition or not element.getSize then
        return false
    end
    if element.getVisible and not element:getVisible() then return false end
    local left, top = element:getAbsolutePosition()
    local width, height = element:getSize()
    return x >= left and x < left + width and y >= top and y < top + height,
        x - left + 1, y - top + 1
end

local function targetHit(target, x, y, payload)
    local local_x, local_y = x, y
    local rank = tonumber(target.priority) or 0

    if target.window_id then
        local wm = service.getService("wm")
        local window = wm and wm.getWindow(target.window_id) or nil
        if not window or not window.frame or not window.program_element
            or window.state == "closing" or window.state == "minimized"
            or window.state == "minimizing"
            or not window.frame:getVisible() then
            return false
        end
        local inside
        inside, local_x, local_y = pointInElement(window.program_element, x, y)
        if not inside then return false end
        rank = 100000 + (tonumber(window.frame.z) or 0) + rank
    elseif target.element then
        local inside
        inside, local_x, local_y = pointInElement(target.element, x, y)
        if not inside then return false end
    elseif target.contains then
        local ok, inside = pcall(target.contains, x, y, payload)
        if not ok or not inside then return false end
    else
        return false
    end

    if target.window_id and target.contains then
        local ok, inside = pcall(target.contains, local_x, local_y, payload)
        if not ok or not inside then return false end
    end
    return true, local_x, local_y, rank
end

local function resolveTarget(x, y)
    if not active then return nil end
    local payload = snapshot(active)
    local hits = {}
    for _, target in pairs(targets) do
        local hit, local_x, local_y, rank = targetHit(target, x, y, payload)
        if hit then
            hits[#hits + 1] = {
                target=target, x=local_x, y=local_y, rank=rank,
            }
        end
    end
    table.sort(hits, function(left, right)
        if left.rank == right.rank then
            return left.target.order > right.target.order
        end
        return left.rank > right.rank
    end)

    local hit = hits[1]
    if not hit then return nil end
    local ok, destination, message = pcall(
        hit.target.resolve, hit.x, hit.y, payload
    )
    if not ok then
        return hit.target, nil, tostring(destination)
    end
    destination = canonicalPath(destination)
    if not destination then
        return hit.target, nil, message or "This location cannot accept the item"
    end
    return hit.target, destination, message
end

local function updateOverlay(x, y)
    if not active then return end
    active.x, active.y = x, y
    local target, destination, message = resolveTarget(x, y)
    active.target_id = target and target.id or nil
    active.destination = destination

    if not overlay or not desktop_frame then return end
    local operation = currentOperation()
    local verb = operation == "copy" and "Copy" or "Move"
    local text = verb .. ": " .. tostring(active.label or fs.getName(active.paths[1]))
    if target and not destination and message then text = "Cannot drop here" end

    local desktop_x, desktop_y = desktop_frame:getAbsolutePosition()
    local width, height = desktop_frame:getSize()
    local overlay_width = math.max(10, math.min(#text + 2, math.max(10, width - 2)))
    local local_x = x - desktop_x + 2
    local local_y = y - desktop_y + 2
    local_x = math.max(1, math.min(local_x, width - overlay_width + 1))
    local_y = math.max(1, math.min(local_y, height))

    local background = destination
        and theme("success", colors.green)
        or theme("danger", colors.red)
    overlay:setPosition(local_x, local_y)
    overlay:setSize(overlay_width, 1)
    overlay:setBackground(background)
    overlay_label:setSize(overlay_width, 1)
    overlay_label:setText(" " .. text)
    overlay_label:setBackground(background)
    overlay:setVisible(true)
end

local function notifyFailure(message)
    local notification = service.getService("notification")
    if notification and notification.error then
        notification.error("Drag & Drop", tostring(message))
    end
end

local function notifySuccess(result)
    local notification = service.getService("notification")
    if not notification or not notification.success then return end
    local verb = result.operation == "copy" and "Copied" or "Moved"
    notification.success("Drag & Drop",
        verb .. " " .. tostring(result.count or 0)
        .. ((result.count or 0) == 1 and " item" or " items"))
end

local function sameDirectory(paths, destination)
    destination = canonicalPath(destination)
    for _, source in ipairs(paths) do
        if canonicalPath(fs.getDir(source)) ~= destination then return false end
    end
    return true
end

function api.public.init()
    event.on("desktop.created", buildOverlay)
    event.on("theme.changed", function()
        if desktop_frame then buildOverlay() end
    end)
    event.on("user.logout", function()
        api.public.cancel("logout")
        targets = {}
        desktop_frame = nil
        overlay, overlay_label = nil, nil
        ctrl_down = false
    end)
    event.onRaw(api.private.handleRawEvent)
    log.info("DRAGDROP", "Service initialized")
end

-- Registers a file drop target.
-- Window targets receive app-local coordinates; element/global targets receive
-- their own local or screen coordinates. resolve(x, y, payload) returns a
-- destination directory or nil plus an explanatory message.
function api.public.registerTarget(id, options)
    if type(id) ~= "string" or id == "" then return nil, "Target ID is required" end
    if type(options) ~= "table" or type(options.resolve) ~= "function" then
        return nil, "Drop target requires a resolver"
    end

    registration_counter = registration_counter + 1
    local target = {
        id=id,
        window_id=options.window_id,
        element=options.element,
        contains=options.contains,
        resolve=options.resolve,
        priority=options.priority,
        order=registration_counter,
    }
    targets[id] = target

    local controller = {}
    function controller:destroy()
        if targets[id] == target then targets[id] = nil end
    end
    return controller
end

function api.public.beginFiles(paths, options)
    options = options or {}
    if active then api.public.cancel("replaced") end

    local values = type(paths) == "table" and paths or {paths}
    local normalized, seen = {}, {}
    for _, value in ipairs(values) do
        local path = canonicalPath(value)
        if not path or path == "/" or not fs.exists(path) then
            return false, "Invalid drag source: " .. tostring(value)
        end
        if not seen[path] then
            seen[path] = true
            normalized[#normalized + 1] = path
        end
    end
    if #normalized == 0 then return false, "No files selected" end

    local requested = options.operation or "auto"
    if requested ~= "auto" and requested ~= "move" and requested ~= "copy" then
        return false, "Invalid drag operation: " .. tostring(requested)
    end
    active = {
        type="files",
        paths=normalized,
        label=options.label or (#normalized == 1 and fs.getName(normalized[1])
            or tostring(#normalized) .. " items"),
        source_id=options.source_id,
        requested_operation=requested,
    }
    event.dispatch("dragdrop.started", snapshot(active))
    return true, snapshot(active)
end

function api.public.cancel(reason)
    if not active then return false end
    local cancelled = snapshot(active)
    active = nil
    hideOverlay()
    event.dispatch("dragdrop.cancelled", reason or "cancelled", cancelled)
    return true
end

function api.public.isDragging()
    return active ~= nil
end

function api.public.getState()
    return snapshot(active)
end

function api.private.completeDrop(x, y)
    if not active then return false end
    updateOverlay(x, y)
    local target, destination, message = resolveTarget(x, y)
    if not target then
        api.public.cancel("no_target")
        return false
    end
    if not destination then
        notifyFailure(message or "This location cannot accept the item")
        api.public.cancel("invalid_target")
        return false
    end

    local drag = active
    local operation = currentOperation()
    if operation == "move" and sameDirectory(drag.paths, destination) then
        api.public.cancel("same_location")
        return true
    end

    active = nil
    hideOverlay()
    local fileops = service.getService("fileops")
    if not fileops or not fileops.transfer then
        local err = "File operation service unavailable"
        notifyFailure(err)
        event.dispatch("dragdrop.failed", err, snapshot(drag))
        return false, err
    end

    local ok, result = fileops.transfer(drag.paths, destination, operation)
    if not ok then
        notifyFailure(result or "Could not complete the drop")
        event.dispatch("dragdrop.failed", result, snapshot(drag))
        return false, result
    end
    event.dispatch("dragdrop.completed", result, target.id, snapshot(drag))
    notifySuccess(result)
    return true, result
end

function api.private.handleRawEvent(event_name, a, b, c)
    if keys then
        if event_name == "key" and (a == keys.leftCtrl or a == keys.rightCtrl) then
            ctrl_down = true
            if active and active.x then updateOverlay(active.x, active.y) end
        elseif event_name == "key_up" and (a == keys.leftCtrl or a == keys.rightCtrl) then
            ctrl_down = false
            if active and active.x then updateOverlay(active.x, active.y) end
        end
    end

    if not active then return end
    if event_name == "mouse_drag" and a == 1 then
        updateOverlay(b, c)
    elseif event_name == "mouse_up" and a == 1 then
        api.private.completeDrop(b, c)
    elseif event_name == "terminate" then
        api.public.cancel("terminate")
    end
end

return api
