-- /apps/architect/main.lua
-- Architect: Visual UI Builder for Basalt

local basalt = require("basalt")

local main = basalt.getMainFrame()
main:setBackground(colors.gray)

-- ── Constants ─────────────────────────────────────────────────────────────────

local PALETTE_W = 13
local PROPS_W   = 19

local ELEMENT_TYPES = { "Label", "Button", "Input", "CheckBox", "Frame", "ProgressBar" }

local CC_COLORS = {
    "white", "orange", "magenta", "lightBlue", "yellow", "lime",
    "pink", "gray", "lightGray", "cyan", "purple", "blue",
    "brown", "green", "red", "black",
}

local function colorIdx(name)
    for i, n in ipairs(CC_COLORS) do if n == name then return i end end
    return 16
end

local DEFAULTS = {
    Label       = { w=10, h=1, text="Label",  bg="black", fg="white" },
    Button      = { w=10, h=1, text="Button", bg="blue",  fg="white" },
    Input       = { w=12, h=1, text="",       bg="white", fg="black" },
    CheckBox    = { w=4,  h=1, text="",       bg="black", fg="lime"  },
    Frame       = { w=12, h=4, text="",       bg="gray",  fg="white" },
    ProgressBar = { w=12, h=1, text="",       bg="gray",  fg="lime"  },
}

-- ── State ─────────────────────────────────────────────────────────────────────

local placed      = {}   -- [id] = { id, etype, props={x,y,w,h,text,bg,fg}, elem }
local next_id     = 1
local selected_id = nil
local is_loading  = false
local sel_markers = {}   -- corner VisualElements showing current selection

-- ── Forward declarations ──────────────────────────────────────────────────────

local addElement, selectElement, loadProps, applyPropsToElem, createElement

-- ── Selection marker helpers ──────────────────────────────────────────────────

local function clearSelectionMarkers()
    for _, m in ipairs(sel_markers) do m:destroy() end
    sel_markers = {}
end

local function showSelectionMarkers(props)
    clearSelectionMarkers()
    local x, y, w, h = props.x, props.y, props.w, props.h
    local corners = {
        { x,         y         },
        { x + w - 1, y         },
        { x,         y + h - 1 },
        { x + w - 1, y + h - 1 },
    }
    -- deduplicate for small elements
    local seen = {}
    for _, c in ipairs(corners) do
        local key = c[1] .. "," .. c[2]
        if not seen[key] then
            seen[key] = true
            table.insert(sel_markers, canvas:addVisualElement({
                x=c[1], y=c[2], width=1, height=1,
                background=colors.cyan,
            }))
        end
    end
end

-- ── UI: Header ────────────────────────────────────────────────────────────────

local hdr = main:addFrame({ x=1, y=1, width="{parent.width}", height=1, background=colors.blue })
hdr:addLabel({ x=2, y=1, text="Architect  \x10  UI Builder", foreground=colors.white, background=colors.blue })

-- ── UI: Palette ───────────────────────────────────────────────────────────────

local palette = main:addFrame({
    x=1, y=2, width=PALETTE_W, height="{parent.height - 1}",
    background=colors.lightGray,
})
palette:addLabel({ x=2, y=1, text="Elements", foreground=colors.black, background=colors.lightGray })
palette:addLabel({ x=1, y=2, text=string.rep("\140", PALETTE_W), foreground=colors.gray, background=colors.lightGray })

for i, etype in ipairs(ELEMENT_TYPES) do
    local btn = palette:addButton({
        x=1, y=2+i, width=PALETTE_W, height=1,
        text=" " .. etype,
        background=colors.lightGray, foreground=colors.black,
    })
    btn:setBackgroundState("hover", colors.cyan)
    btn:setForegroundState("hover", colors.black)
    btn:onClick(function() addElement(etype) end)
end

-- ── UI: Canvas ────────────────────────────────────────────────────────────────

local canvas_outer = main:addFrame({
    x = PALETTE_W + 1,
    y = 2,
    width  = "{parent.width - " .. (PALETTE_W + PROPS_W) .. "}",
    height = "{parent.height - 2}",
    background = colors.black,
})
canvas_outer:addBorder(colors.blue, { top=true, bottom=true, left=true, right=true })

local canvas = canvas_outer:addFrame({
    x=2, y=2,
    width  = "{parent.width - 2}",
    height = "{parent.height - 2}",
    background = colors.black,
})
canvas:onClick(function() selectElement(nil) end)

-- ── UI: Toolbar ───────────────────────────────────────────────────────────────

local toolbar = main:addFrame({
    x = PALETTE_W + 1,
    y = "{parent.height}",
    width  = "{parent.width - " .. (PALETTE_W + PROPS_W) .. "}",
    height = 1,
    background = colors.blue,
})

local sel_label = toolbar:addLabel({
    x=2, y=1, text="Nothing selected",
    foreground=colors.white, background=colors.blue,
})

local export_btn = toolbar:addButton({
    x="{parent.width - 11}", y=1, width=11, height=1,
    text="Export Code",
    background=colors.lime, foreground=colors.black,
})

-- ── UI: Properties Panel ──────────────────────────────────────────────────────

local props_panel = main:addScrollFrame({
    x = "{parent.width - " .. (PROPS_W - 1) .. "}",
    y = 2,
    width  = PROPS_W,
    height = "{parent.height - 1}",
    background = colors.lightGray,
})
props_panel:addLabel({ x=2, y=1, text="Properties", foreground=colors.black, background=colors.lightGray })
props_panel:addLabel({ x=1, y=2, text=string.rep("\140", PROPS_W), foreground=colors.gray, background=colors.lightGray })

local p_type = props_panel:addLabel({ x=2, y=3, text="No selection", foreground=colors.gray, background=colors.lightGray })

-- Position row
props_panel:addLabel({ x=2, y=4, text="x:", foreground=colors.black, background=colors.lightGray })
local p_x = props_panel:addInput({ x=5, y=4, width=4, height=1, background=colors.white, foreground=colors.black })
props_panel:addLabel({ x=10, y=4, text="y:", foreground=colors.black, background=colors.lightGray })
local p_y = props_panel:addInput({ x=13, y=4, width=4, height=1, background=colors.white, foreground=colors.black })

-- Size row
props_panel:addLabel({ x=2, y=5, text="w:", foreground=colors.black, background=colors.lightGray })
local p_w = props_panel:addInput({ x=5, y=5, width=4, height=1, background=colors.white, foreground=colors.black })
props_panel:addLabel({ x=10, y=5, text="h:", foreground=colors.black, background=colors.lightGray })
local p_h = props_panel:addInput({ x=13, y=5, width=4, height=1, background=colors.white, foreground=colors.black })

props_panel:addLabel({ x=1, y=6, text=string.rep("\140", PROPS_W), foreground=colors.gray, background=colors.lightGray })

-- Text row
props_panel:addLabel({ x=2, y=7, text="Text:", foreground=colors.black, background=colors.lightGray })
local p_text = props_panel:addInput({ x=2, y=8, width=PROPS_W-3, height=1, background=colors.white, foreground=colors.black })

props_panel:addLabel({ x=1, y=9, text=string.rep("\140", PROPS_W), foreground=colors.gray, background=colors.lightGray })

-- BG color
props_panel:addLabel({ x=2, y=10, text="BG:", foreground=colors.black, background=colors.lightGray })
local p_bg = props_panel:addDropDown({ x=2, y=11, width=PROPS_W-3, height=1, background=colors.white, foreground=colors.black })
for _, c in ipairs(CC_COLORS) do p_bg:addItem(c) end

-- FG color
props_panel:addLabel({ x=2, y=12, text="FG:", foreground=colors.black, background=colors.lightGray })
local p_fg = props_panel:addDropDown({ x=2, y=13, width=PROPS_W-3, height=1, background=colors.white, foreground=colors.black })
for _, c in ipairs(CC_COLORS) do p_fg:addItem(c) end

props_panel:addLabel({ x=1, y=14, text=string.rep("\140", PROPS_W), foreground=colors.gray, background=colors.lightGray })

local p_delete = props_panel:addButton({
    x=2, y=15, width=PROPS_W-3, height=1,
    text="Delete",
    background=colors.red, foreground=colors.white,
})
p_delete:setVisible(false)

-- ── Logic: Apply props to live element ────────────────────────────────────────

applyPropsToElem = function(item)
    local e, p, etype = item.elem, item.props, item.etype
    if not e then return end
    e:setPosition(p.x, p.y)
    if etype ~= "CheckBox" and e.setSize then
        e:setSize(math.max(1, p.w), math.max(1, p.h))
    end
    if (etype == "Label" or etype == "Button") and e.setText then
        e:setText(p.text or "")
    end
    if e.setBackground then e:setBackground(colors[p.bg] or colors.black) end
    if etype ~= "Frame" and e.setForeground then
        e:setForeground(colors[p.fg] or colors.white)
    end
    if selected_id == item.id then
        showSelectionMarkers(p)
    end
end

-- ── Logic: Load props into panel ──────────────────────────────────────────────

loadProps = function(item)
    is_loading = true
    p_type:setText("Type: " .. item.etype)
    p_x:setText(tostring(item.props.x))
    p_y:setText(tostring(item.props.y))
    p_w:setText(tostring(item.props.w))
    p_h:setText(tostring(item.props.h))
    p_text:setText(item.props.text or "")
    p_bg:selectItem(colorIdx(item.props.bg))
    p_fg:selectItem(colorIdx(item.props.fg))
    p_delete:setVisible(true)
    is_loading = false
end

-- ── Logic: Select element ─────────────────────────────────────────────────────

selectElement = function(id)
    selected_id = id
    if id and placed[id] then
        loadProps(placed[id])
        sel_label:setText("Selected: " .. placed[id].etype .. " #" .. id)
        showSelectionMarkers(placed[id].props)
    else
        p_type:setText("No selection")
        p_x:setText("") p_y:setText("") p_w:setText("") p_h:setText("")
        p_text:setText("")
        p_delete:setVisible(false)
        sel_label:setText("Nothing selected")
        clearSelectionMarkers()
    end
end

-- ── Logic: Apply single prop change ───────────────────────────────────────────

local function applyProp(key, value)
    if is_loading or not selected_id then return end
    local item = placed[selected_id]
    if not item then return end
    if key == "x" or key == "y" or key == "w" or key == "h" then
        local n = tonumber(value)
        if not n then return end
        item.props[key] = math.max(1, math.floor(n))
    else
        item.props[key] = value
    end
    applyPropsToElem(item)
end

p_x:onChange("text",    function(_, v) applyProp("x", v) end)
p_y:onChange("text",    function(_, v) applyProp("y", v) end)
p_w:onChange("text",    function(_, v) applyProp("w", v) end)
p_h:onChange("text",    function(_, v) applyProp("h", v) end)
p_text:onChange("text", function(_, v) applyProp("text", v) end)
p_bg:onChange("selectedItem", function(_, item) if item then applyProp("bg", item.text) end end)
p_fg:onChange("selectedItem", function(_, item) if item then applyProp("fg", item.text) end end)

-- ── Logic: Delete ─────────────────────────────────────────────────────────────

p_delete:onClick(function()
    if not selected_id then return end
    local item = placed[selected_id]
    if item and item.elem then item.elem:destroy() end
    placed[selected_id] = nil
    selectElement(nil)
end)

-- ── Logic: Create element on canvas ───────────────────────────────────────────

createElement = function(etype, props)
    local args = {
        x = props.x, y = props.y,
        width = props.w, height = props.h,
        background = colors[props.bg] or colors.black,
    }
    if etype == "Label" then
        args.text = props.text
        args.foreground = colors[props.fg] or colors.white
        return canvas:addLabel(args)
    elseif etype == "Button" then
        args.text = props.text
        args.foreground = colors[props.fg] or colors.white
        return canvas:addButton(args)
    elseif etype == "Input" then
        args.defaultText = props.text
        args.foreground = colors[props.fg] or colors.white
        return canvas:addInput(args)
    elseif etype == "CheckBox" then
        args.foreground = colors[props.fg] or colors.white
        return canvas:addCheckBox(args)
    elseif etype == "Frame" then
        return canvas:addFrame(args)
    elseif etype == "ProgressBar" then
        args.foreground = colors[props.fg] or colors.white
        args.progress = 50
        args.maxProgress = 100
        return canvas:addProgressBar(args)
    end
end

-- ── Logic: Add element ────────────────────────────────────────────────────────

addElement = function(etype)
    local def = DEFAULTS[etype] or { w=8, h=1, text="", bg="black", fg="white" }
    local props = { x=3, y=3, w=def.w, h=def.h, text=def.text, bg=def.bg, fg=def.fg }

    local id = next_id
    next_id = next_id + 1

    local elem = createElement(etype, props)
    if not elem then return end

    if elem.onClick then
        elem:onClick(function() selectElement(id) end)
    end

    placed[id] = { id=id, etype=etype, props=props, elem=elem }
    selectElement(id)
end

-- ── Logic: Code generation ────────────────────────────────────────────────────

local function generateCode()
    local lines = {
        'local basalt = require("basalt")',
        'local main = basalt.getMainFrame()',
        '',
    }
    for _, item in pairs(placed) do
        local p, etype = item.props, item.etype
        local parts = { string.format("x=%d, y=%d", p.x, p.y) }
        if etype ~= "CheckBox" then
            parts[#parts+1] = string.format("width=%d, height=%d", p.w, p.h)
        end
        if (etype == "Label" or etype == "Button") and (p.text or "") ~= "" then
            parts[#parts+1] = string.format('text="%s"', p.text:gsub('"', '\\"'))
        end
        parts[#parts+1] = string.format("background=colors.%s", p.bg)
        if etype ~= "Frame" then
            parts[#parts+1] = string.format("foreground=colors.%s", p.fg)
        end
        lines[#lines+1] = string.format("main:add%s({%s})", etype, table.concat(parts, ", "))
    end
    lines[#lines+1] = ''
    lines[#lines+1] = 'basalt.run()'
    return table.concat(lines, "\n")
end

-- ── Export overlay ────────────────────────────────────────────────────────────

export_btn:onClick(function()
    local code = generateCode()

    local overlay = main:addFrame({
        x=4, y=3,
        width  = "{parent.width - 6}",
        height = "{parent.height - 4}",
        background = colors.gray,
    })
    overlay:setZ(200)
    overlay:addBorder(colors.blue, { top=true, bottom=true, left=true, right=true })
    overlay:addVisualElement({ x=1, y=1, width="{parent.width}", height=1, background=colors.blue })
    overlay:addLabel({ x=2, y=1, text="Generated Code", foreground=colors.white, background=colors.blue })
    overlay:addButton({
        x="{parent.width - 1}", y=1, width=1, height=1,
        text="X", background=colors.red, foreground=colors.white,
    }):onClick(function() overlay:destroy() end)

    local code_list = overlay:addList({
        x=2, y=2,
        width  = "{parent.width - 2}",
        height = "{parent.height - 3}",
        background = colors.black, foreground = colors.lime,
    })
    code_list:setSelectionColor(colors.black, colors.lime)
    for line in (code .. "\n"):gmatch("([^\n]*)\n") do
        code_list:addItem(line, nil, colors.lime, colors.black)
    end
end)

-- ── Toolbar: Clear All ────────────────────────────────────────────────────────

toolbar:addButton({
    x=2, y=1, width=9, height=1,
    text="Clear All",
    background=colors.red, foreground=colors.white,
}):onClick(function()
    for _, item in pairs(placed) do
        if item.elem then item.elem:destroy() end
    end
    placed = {}
    clearSelectionMarkers()
    selectElement(nil)
end)

-- ── Run ───────────────────────────────────────────────────────────────────────

basalt.run()
