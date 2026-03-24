-- /services/arg_collector.lua
-- Arg Collector: Shows a dynamic form to collect missing program arguments before launch.
-- Supports: text, file, fixed (invisible), select (with nested sub-args per option).

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")

local api = api_factory.new()

local DIALOG_WIDTH = 42
local PAD = 2

function api.public.init()
    log.info("ARG_COLLECTOR", "Service initialized")
end

-- Flatten arg_defs + state into ordered flat args list
local function flattenArgs(arg_defs, state)
    local result = {}
    for _, def in ipairs(arg_defs or {}) do
        if def.type == "fixed" then
            table.insert(result, def.value)
        elseif def.type == "text" or def.type == "file" then
            table.insert(result, state[def.name] or "")
        elseif def.type == "select" then
            local val = state[def.name] or ""
            table.insert(result, val)
            for _, opt in ipairs(def.options or {}) do
                if opt.value == val and opt.args then
                    for _, v in ipairs(flattenArgs(opt.args, state)) do
                        table.insert(result, v)
                    end
                    break
                end
            end
        end
    end
    return result
end

-- Count rows needed to render arg_defs (picks largest option branch for selects)
local function countRows(arg_defs)
    if not arg_defs then return 0 end
    local h = 0
    for _, def in ipairs(arg_defs) do
        if def.type == "text" or def.type == "file" then
            h = h + 3  -- label row, input row, blank gap
        elseif def.type == "select" then
            h = h + 3  -- label row, buttons row, blank gap
            local max_sub = 0
            for _, opt in ipairs(def.options or {}) do
                local s = countRows(opt.args)
                if s > max_sub then max_sub = s end
            end
            h = h + max_sub
        end
    end
    return h
end

-- Build all form widgets into overlay starting at start_y.
-- Calls on_change() when a select option is picked (triggers full rebuild).
-- Returns the next free y position.
local function buildForm(overlay, arg_defs, state, on_change, start_y)
    local y = start_y
    for _, def in ipairs(arg_defs) do
        if def.type == "text" or def.type == "file" then
            if state[def.name] == nil then
                state[def.name] = def.default or ""
            end
            overlay:addLabel({
                x = PAD, y = y,
                width = DIALOG_WIDTH - PAD,
                height = 1,
                text = (def.label or def.name) .. (def.required and " *" or ""),
                foreground = colors.lightGray,
                background = colors.gray
            })
            y = y + 1
            local inp = overlay:addInput({
                x = PAD, y = y,
                width = DIALOG_WIDTH - PAD * 2,
                height = 1,
                background = colors.black,
                foreground = colors.white
            })
            -- Set initial value
            if state[def.name] ~= "" then
                inp:setValue(state[def.name])
            end
            local cap_name = def.name
            inp:onChange("text", function(self, val)
                state[cap_name] = val
            end)
            y = y + 2

        elseif def.type == "select" then
            if state[def.name] == nil then
                state[def.name] = def.options and def.options[1] and def.options[1].value
            end
            overlay:addLabel({
                x = PAD, y = y,
                width = DIALOG_WIDTH - PAD,
                height = 1,
                text = (def.label or def.name) .. (def.required and " *" or ""),
                foreground = colors.lightGray,
                background = colors.gray
            })
            y = y + 1
            local btn_x = PAD
            for _, opt in ipairs(def.options or {}) do
                local lbl = opt.label or opt.value
                local w = #lbl + 2
                local is_sel = (state[def.name] == opt.value)
                local cap_def = def
                local cap_opt = opt
                overlay:addButton({
                    x = btn_x, y = y,
                    width = w, height = 1,
                    text = lbl,
                    foreground = colors.white,
                    background = is_sel and colors.blue or colors.lightGray
                }):onClick(function()
                    state[cap_def.name] = cap_opt.value
                    on_change()
                end)
                btn_x = btn_x + w + 1
            end
            y = y + 2
            -- Recurse into selected option's sub-args
            local sel = state[def.name]
            for _, opt in ipairs(def.options or {}) do
                if opt.value == sel and opt.args and #opt.args > 0 then
                    y = buildForm(overlay, opt.args, state, on_change, y)
                    break
                end
            end
        end
        -- fixed: no widget rendered
    end
    return y
end

-- Show arg collection form. Calls callback(args_table) on confirm, callback(nil) on cancel.
-- Skips UI if provided args are non-empty.
function api.public.collect(program, provided, callback)
    local arg_defs = program.args
    if not arg_defs or #arg_defs == 0 then
        callback(provided or {})
        return
    end
    if provided and #provided > 0 then
        callback(provided)
        return
    end

    local ui = service.getService("ui")
    if not ui then callback(provided or {}) return end
    local main_frame = ui.getMainFrame()
    if not main_frame then callback(provided or {}) return end

    local screen_w, screen_h = term.getSize()
    local form_rows   = countRows(arg_defs)
    local inner_h     = 1 + form_rows          -- title + form
    local dialog_h    = math.min(inner_h + 2, screen_h - 2)  -- +2 for button row + gap
    local dialog_x    = math.floor((screen_w - DIALOG_WIDTH) / 2) + 1
    local dialog_y    = math.floor((screen_h - dialog_h)     / 2) + 1

    local overlay = main_frame:addFrame({
        x = dialog_x, y = dialog_y,
        width = DIALOG_WIDTH, height = dialog_h,
        background = colors.gray
    })
    overlay:prioritize()

    -- Title bar
    overlay:addVisualElement({
        x = 1, y = 1,
        width = "{parent.width}", height = 1,
        background = colors.blue
    })
    overlay:addLabel({
        x = 2, y = 1,
        text = program.name,
        foreground = colors.white,
        background = colors.blue
    })

    local state = {}

    -- Rebuild clears old widgets (except title) and redraws form + buttons
    local function rebuild()
        -- destroy and recreate the overlay to get a clean slate, preserving title
        overlay:destroy()
        overlay = main_frame:addFrame({
            x = dialog_x, y = dialog_y,
            width = DIALOG_WIDTH, height = dialog_h,
            background = colors.gray
        })
        overlay:prioritize()
        overlay:addVisualElement({
            x = 1, y = 1,
            width = "{parent.width}", height = 1,
            background = colors.blue
        })
        overlay:addLabel({
            x = 2, y = 1,
            text = program.name,
            foreground = colors.white,
            background = colors.blue
        })
        buildForm(overlay, arg_defs, state, rebuild, 2)
        -- Cancel button
        overlay:addButton({
            x = DIALOG_WIDTH - 14, y = dialog_h,
            width = 8, height = 1,
            text = "Cancel",
            foreground = colors.white,
            background = colors.red
        }):onClick(function()
            overlay:destroy()
            callback(nil)
        end)
        -- Open/Confirm button
        overlay:addButton({
            x = DIALOG_WIDTH - 5, y = dialog_h,
            width = 6, height = 1,
            text = "Open",
            foreground = colors.white,
            background = colors.green
        }):onClick(function()
            local collected = flattenArgs(arg_defs, state)
            overlay:destroy()
            callback(collected)
        end)
    end

    rebuild()
end

return api

