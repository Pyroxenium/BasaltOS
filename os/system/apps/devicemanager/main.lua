-- /system/apps/devicemanager/main.lua
-- Device inventory and safe peripheral controls backed by app.devices.

local basalt = require("basalt")
local app = require("app")
local devices = app.devices

if not devices then error("Device service not available") end

local function theme(key, fallback)
    return app.theme(key, fallback)
end

local C = {
    background=theme("menu_bg", colors.white),
    foreground=theme("menu_fg", colors.black),
    muted=theme("menu_muted", colors.gray),
    surface=theme("surface", colors.lightGray),
    primary=theme("primary", colors.blue),
    text=theme("text", colors.white),
    success=theme("success", colors.green),
    warning=theme("warning", colors.orange),
    danger=theme("danger", colors.red),
    border=theme("border", colors.gray),
    pressed=theme("btn_clicked", colors.cyan),
}

local main = basalt.getMainFrame()
main:setBackground(C.background)

local header = main:addFrame({
    x=1, y=1, width="{parent.width}", height=1,
    background=C.primary,
})
header:addLabel({
    x=2, y=1, width=17, height=1, text="Device Manager",
    foreground=C.text, background=C.primary, disabled=true,
})

local count_label = header:addLabel({
    x=19, y=1, width="{parent.width - 30}", height=1, text="",
    foreground=C.text, background=C.primary, disabled=true,
})

local refresh_button = header:addButton({
    x="{parent.width - 9}", y=1, width=8, height=1, text="Refresh",
    foreground=C.text, background=C.primary,
})
refresh_button:setStateStyle("hover", {background=C.pressed, foreground=C.text})

local sidebar = main:addFrame({
    x=1, y=2, width=19, height="{parent.height - 1}",
    background=C.surface,
})
sidebar:addLabel({
    x=2, y=1, width=16, height=1, text="Peripherals",
    foreground=C.foreground, background=C.surface, disabled=true,
})

local device_list = sidebar:addList({
    x=1, y=2, width=19, height="{parent.height - 1}",
    background=C.surface, foreground=C.foreground,
    selectionBackground=C.primary, selectionForeground=C.text,
    scrollbar="auto", scrollbarColor=C.border,
    scrollbarThumbColor=C.primary,
    emptyText="No devices", emptyTextColor=C.muted,
})

local details = main:addFrame({
    x=20, y=2, width="{parent.width - 19}", height="{parent.height - 1}",
    background=C.background,
})

local name_label = details:addLabel({
    x=2, y=1, width="{parent.width - 3}", height=1,
    text="Select a device", foreground=C.foreground,
    background=C.background, disabled=true,
})
local type_label = details:addLabel({
    x=2, y=2, width="{parent.width - 3}", height=1,
    text="", foreground=C.muted, background=C.background, disabled=true,
})
local info_label = details:addLabel({
    x=2, y=3, width="{parent.width - 3}", height=1,
    text="", foreground=C.muted, background=C.background, disabled=true,
})

details:addFrame({
    x=1, y=4, width="{parent.width}", height=1,
    background=C.border, disabled=true,
})

details:addLabel({
    x=2, y=5, width=18, height=1, text="Available methods",
    foreground=C.foreground, background=C.background, disabled=true,
})

local methods_list = details:addList({
    x=2, y=6, width="{parent.width - 3}", height="{parent.height - 9}",
    background=C.background, foreground=C.muted,
    selectionBackground=C.background, selectionForeground=C.muted,
    scrollbar="auto", scrollbarColor=C.surface,
    scrollbarThumbColor=C.primary,
    emptyText="No methods reported", emptyTextColor=C.muted,
})

local primary_button = details:addButton({
    x=2, y="{parent.height - 2}", width=13, height=1,
    text="", foreground=C.text, background=C.primary, visible=false,
})
primary_button:setStateStyle("hover", {background=C.pressed, foreground=C.text})

local secondary_button = details:addButton({
    x=16, y="{parent.height - 2}", width="{min(13, parent.width - 16)}", height=1,
    text="", foreground=C.foreground, background=C.surface, visible=false,
})
secondary_button:setStateStyle("hover", {background=C.primary, foreground=C.text})

local status_label = details:addLabel({
    x=2, y="{parent.height}", width="{parent.width - 3}", height=1,
    text="Ready", foreground=C.muted, background=C.background, disabled=true,
})

local selected_name = nil
local primary_action = nil
local secondary_action = nil

local function setStatus(text, color)
    status_label:setText(tostring(text or ""))
    status_label:setForeground(color or C.muted)
end

local function hasType(device, wanted)
    for _, device_type in ipairs(device and device.types or {}) do
        if device_type == wanted then return true end
    end
    return false
end

local function hasMethod(device, wanted)
    for _, method in ipairs(device and device.methods or {}) do
        if method == wanted then return true end
    end
    return false
end

local function callValue(name, method, ...)
    local result = table.pack(devices.call(name, method, ...))
    if not result[1] then return nil, result[2] end
    return table.unpack(result, 2, result.n)
end

local function deviceSummary(device)
    if hasType(device, "modem") then
        local wireless = callValue(device.name, "isWireless")
        local kind = wireless == true and "wireless" or "wired"
        local state = devices.isRednetOpen(device.name) and "Rednet open" or "Rednet closed"
        return kind .. " modem - " .. state
    end

    if hasType(device, "monitor") then
        local width, height = callValue(device.name, "getSize")
        local color = callValue(device.name, "isColor")
        if width and height then
            return string.format("%dx%d%s", width, height, color == false and " monochrome" or " color")
        end
        return "Monitor ready"
    end

    if hasType(device, "drive") then
        local present = callValue(device.name, "isDiskPresent")
        if present == false then return "No disk inserted" end
        local label = callValue(device.name, "getDiskLabel")
        return label and ("Disk: " .. tostring(label)) or "Disk inserted"
    end

    if hasType(device, "printer") then
        local paper = callValue(device.name, "getPaperLevel")
        local ink = callValue(device.name, "getInkLevel")
        if paper ~= nil and ink ~= nil then
            return string.format("Paper %s - Ink %s", tostring(paper), tostring(ink))
        end
    end

    if hasType(device, "speaker") then return "Speaker ready" end
    return tostring(#device.methods) .. " methods available"
end

local function configureButton(button, text, action)
    button:setText(text or "")
    button:setVisible(action ~= nil)
    button:setDisabled(action == nil)
    return action
end

local renderDetails

local function configureActions(device)
    primary_action, secondary_action = nil, nil

    if hasType(device, "modem") then
        if devices.isRednetOpen(device.name) then
            primary_action = function()
                local ok, err = devices.closeModem(device.name)
                setStatus(ok and "Modem closed" or err, ok and C.success or C.danger)
                renderDetails(devices.get(device.name))
            end
            configureButton(primary_button, "Close modem", primary_action)
        else
            primary_action = function()
                local ok, err = devices.openModem(device.name)
                setStatus(ok and "Modem opened" or err, ok and C.success or C.danger)
                renderDetails(devices.get(device.name))
            end
            configureButton(primary_button, "Open modem", primary_action)
        end
        secondary_action = function()
            local ok, value = devices.ensureRednet()
            setStatus(ok and "Rednet enabled" or value, ok and C.success or C.danger)
            renderDetails(devices.get(device.name))
        end
        configureButton(secondary_button, "Enable all", secondary_action)
        return
    end

    if hasType(device, "speaker") and hasMethod(device, "playNote") then
        primary_action = function()
            local ok, played_or_error = devices.call(device.name, "playNote", "pling", 1, 12)
            local played = ok and played_or_error ~= false
            setStatus(played and "Test note played" or (played_or_error or "Speaker busy"),
                played and C.success or C.warning)
        end
        configureButton(primary_button, "Test speaker", primary_action)
        configureButton(secondary_button, nil, nil)
        return
    end

    if hasType(device, "drive") and hasMethod(device, "ejectDisk") then
        primary_action = function()
            local ok, err = devices.call(device.name, "ejectDisk")
            setStatus(ok and "Disk ejected" or err, ok and C.success or C.danger)
            renderDetails(devices.get(device.name))
        end
        configureButton(primary_button, "Eject disk", primary_action)
        configureButton(secondary_button, nil, nil)
        return
    end

    configureButton(primary_button, nil, nil)
    configureButton(secondary_button, nil, nil)
end

renderDetails = function(device)
    methods_list:clear()
    if not device then
        name_label:setText("Select a device")
        type_label:setText("")
        info_label:setText("")
        configureButton(primary_button, nil, nil)
        configureButton(secondary_button, nil, nil)
        return
    end

    name_label:setText(device.name)
    type_label:setText("Types: " .. table.concat(device.types, ", "))
    info_label:setText(deviceSummary(device))
    for _, method in ipairs(device.methods) do
        methods_list:addItem({text=method, fg=C.muted, bg=C.background, selectable=false})
    end
    configureActions(device)
end

local function refreshList(preferred_name)
    preferred_name = preferred_name or selected_name
    local inventory = devices.list()
    device_list:clear()
    count_label:setText(tostring(#inventory) .. (#inventory == 1 and " device" or " devices"))

    local selected_index = nil
    for index, device in ipairs(inventory) do
        local marker = device.isModem and "M" or device.type:sub(1, 1):upper()
        device_list:addItem({
            text=string.format("[%s] %s", marker, device.name),
            deviceName=device.name,
            fg=C.foreground, bg=C.surface,
        })
        if device.name == preferred_name then selected_index = index end
    end

    if not selected_index and #inventory > 0 then selected_index = 1 end
    if selected_index then
        selected_name = inventory[selected_index].name
        device_list:selectItem(selected_index, false)
        renderDetails(inventory[selected_index])
    else
        selected_name = nil
        renderDetails(nil)
    end
end

device_list:onSelect(function(_, _, item)
    selected_name = item and item.deviceName or nil
    renderDetails(selected_name and devices.get(selected_name) or nil)
end)

refresh_button:onClickUp(function(_, button)
    if button ~= 1 then return end
    local result = devices.refresh()
    refreshList(selected_name)
    setStatus(string.format("Refreshed - %d devices", result.total), C.success)
end)

primary_button:onClickUp(function(_, button)
    if button == 1 and primary_action then primary_action() end
end)

secondary_button:onClickUp(function(_, button)
    if button == 1 and secondary_action then secondary_action() end
end)

basalt.schedule(function()
    while true do
        local event_name = os.pullEventRaw()
        if event_name == "devices.changed" or event_name == "devices.rednet_changed" then
            refreshList(selected_name)
        end
    end
end)

refreshList()
basalt.run()
