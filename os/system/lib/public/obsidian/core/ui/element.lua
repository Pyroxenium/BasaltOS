--- ui/element.lua
--- Shared element-factory and field-metadata used by the UI context.

local M = {}

--- Fields that live directly on the element table (not inside .config).
M.ELEMENT_FIELDS = {
    x=true, y=true, z=true, w=true, h=true,
    visible=true, sprite=true, disabled=true,
    fore=true, back=true, borderColor=true, anchor=true, interactive=true,
    borderTop=true, borderBottom=true, borderLeft=true, borderRight=true,
}

--- Subset of ELEMENT_FIELDS that require a z-sort / size-recalc on change.
M.DIRTY_FIELDS = { z=true, sprite=true, w=true, h=true }

--- Word-wrap `text` to fit within `maxW` columns.
-- Splits on explicit newlines first, then wraps long paragraphs by word.
-- @return table of line strings
function M.wrapText(text, maxW)
    local lines = {}
    -- Split into paragraphs on \n
    for para in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        if #para == 0 then
            table.insert(lines, "")
        elseif maxW <= 0 or #para <= maxW then
            table.insert(lines, para)
        else
            local words = {}
            for w in para:gmatch("%S+") do table.insert(words, w) end
            local cur = ""
            for _, word in ipairs(words) do
                if #cur == 0 then
                    cur = word
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

-- Resolves the four individual border flags from a config table.
-- `config.border = false` disables all four; individual keys always win.
local function resolveBorders(cfg)
    local def = cfg.border ~= false
    return
        cfg.borderTop    ~= nil and cfg.borderTop    or def,
        cfg.borderBottom ~= nil and cfg.borderBottom or def,
        cfg.borderLeft   ~= nil and cfg.borderLeft   or def,
        cfg.borderRight  ~= nil and cfg.borderRight  or def
end

--- Build a flat element table from common parameters.
-- @param name    string   Unique element name
-- @param type_   string   Widget type ("button", "text", "input", …)
-- @param x       number
-- @param y       number
-- @param config  table    Caller-supplied options
-- @return element table
function M.make(name, type_, x, y, config)
    local cfg = config or {}
    local bTop, bBot, bLeft, bRight = resolveBorders(cfg)
    local el = {
        name        = name,
        type        = type_,
        x           = x,
        y           = y,
        w           = cfg.w or (cfg.text and #cfg.text or 0),
        h           = cfg.h or 1,
        z           = cfg.z or 0,
        config      = cfg,
        visible     = (cfg.visible ~= false) and (cfg.hidden ~= true),
        anchor      = cfg.anchor or "top-left",
        interactive = (type_ ~= "text" and type_ ~= "rect" and type_ ~= "sprite"
                        and type_ ~= "multiline")
                      or (cfg.interactive == true)
                      or (cfg.onClick ~= nil),
        sprite      = cfg.sprite,
        borderTop    = bTop,
        borderBottom = bBot,
        borderLeft   = bLeft,
        borderRight  = bRight,
        fore        = cfg.fore or "0",
        back        = cfg.back or "7",
        borderColor = cfg.borderColor or "8",
        disabled    = cfg.disabled == true,
    }
    if cfg.sprite then
        el.w = cfg.sprite.width
        el.h = cfg.sprite.height
    end
    -- Auto-compute height for multiline from wrapped line count
    if type_ == "multiline" and not cfg.h then
        el.h = #M.wrapText(cfg.text or "", el.w)
    end
    return el
end

--- Build a container element table.
-- @param name    string
-- @param x,y     number   Position
-- @param w,h     number   Size (required for containers)
-- @param config  table
function M.makeContainer(name, x, y, w, h, config)
    local cfg = config or {}
    local bTop, bBot, bLeft, bRight = resolveBorders(cfg)
    return {
        name    = name,
        type    = "container",
        x       = x,
        y       = y,
        w       = w,
        h       = h,
        z           = cfg.z or 0,
        config      = cfg,
        visible     = (cfg.visible ~= false) and (cfg.hidden ~= true),
        anchor      = cfg.anchor or "top-left",
        interactive = true,
        fore        = cfg.fore or "0",
        back        = cfg.back or "7",
        borderColor = cfg.borderColor or "8",
        borderTop    = bTop,
        borderBottom = bBot,
        borderLeft   = bLeft,
        borderRight  = bRight,
        disabled       = cfg.disabled == true,
        children       = {},
        sortedChildren = {},
        childrenDirty  = true,
        scrollOffset   = 0,
    }
end

return M
