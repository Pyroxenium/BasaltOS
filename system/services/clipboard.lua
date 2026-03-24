-- /services/clipboard.lua
-- Clipboard Service: System-wide clipboard for any data type

local api_factory = require("core.api")
local event = require("core.event")
local log = require("core.log")

local api = api_factory.new()

local clipboard_data = nil

function api.public.init()
    -- When the user presses Ctrl+V, CC fires a "paste" event with the host clipboard text.
    -- We write it into the system clipboard and fire clipboard.paste so apps can react.
    event.on("paste", function(text)
        clipboard_data = text
        log.debug("CLIPBOARD", "Host paste received", {length = #text})
        event.dispatch("clipboard.paste", clipboard_data)
        event.dispatch("clipboard.changed", clipboard_data)
    end)

    log.debug("CLIPBOARD", "Clipboard service initialized")
end

function api.public.set(data)
    clipboard_data = data
    log.debug("CLIPBOARD", "Clipboard set", {type = type(data)})
    event.dispatch("clipboard.changed", clipboard_data)
end

function api.public.get()
    return clipboard_data
end

function api.public.clear()
    clipboard_data = nil
    event.dispatch("clipboard.changed", nil)
    log.debug("CLIPBOARD", "Clipboard cleared")
end

function api.public.isEmpty()
    return clipboard_data == nil
end

return api
