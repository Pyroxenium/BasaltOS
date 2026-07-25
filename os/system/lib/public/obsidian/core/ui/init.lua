--- ui/init.lua
--- UI context factory. Loaded as `require("core.ui")`.
---
--- Usage:
---   local UI  = require("core.ui")
---   local ctx = UI.new(Engine.buffer)
---
---   ctx:button("btnOk", 5, 3, { w=8, h=3, text="OK", onClick=function() end })
---   ctx:input("name",   2, 5, { w=20, onConfirm=function(v) end })
---
---   -- In your draw loop:
---   ctx:draw(0, 0)
---
---   -- In your event loop:
---   ctx:handleEvent({ os.pullEvent() })

local element = require("core.ui.element")
local render  = require("core.ui.render")
local events  = require("core.ui.events")

local UI = {}

---@class UIModule

---@class UIContext
---@field buf BufferInstance
---@field elements table<string, table>
---@field sorted table[]
---@field dirty boolean
---@field pressedElement table|nil
---@field pressedAbsX number|nil
---@field pressedAbsY number|nil
---@field focusedElement table|nil

--- Create a new UI context bound to a Buffer instance.
-- @param buf  Buffer   A Buffer.new() instance
-- @return     context table
---@param buf BufferInstance A Buffer.new() instance
---@return UIContext
function UI.new(buf)
    assert(buf, "UI.new: a Buffer instance is required")

    local ctx = {
        buf            = buf,
        elements       = {},
        sorted         = {},
        dirty          = true,
        pressedElement = nil,
        pressedAbsX    = nil,
        pressedAbsY    = nil,
        focusedElement = nil,
    }

    -- ─── Internal ─────────────────────────────────────────────────────────────

    --- Rebuild and sort the flat element list by z-order.
    function ctx:_sort()
        self.sorted = {}
        for _, el in pairs(self.elements) do table.insert(self.sorted, el) end
        table.sort(self.sorted, function(a, b) return a.z < b.z end)
        self.dirty = false
    end

    --- Insert an element and mark the sort as stale.
    function ctx:_insert(el)
        self.elements[el.name] = el
        self.dirty = true
        return el
    end

    -- ─── Typed element constructors ───────────────────────────────────────────
    -- Preferred over the generic ctx:add(); each maps directly to a widget type.

    --- Generic constructor. Prefer the typed methods below.
    ---@param self UIContext
    ---@param name string
    ---@param type_ string
    ---@param x number
    ---@param y number
    ---@param config table|nil
    ---@return table element
    function ctx:add(name, type_, x, y, config)
        return self:_insert(element.make(name, type_, x, y, config))
    end

    --- Typed convenience constructors
    ---@param self UIContext
    ---@param name string
    ---@param x number
    ---@param y number
    ---@param config table|nil
    function ctx:button(name, x, y, config)   return self:add(name, "button",   x, y, config) end
    function ctx:text(name, x, y, config)     return self:add(name, "text",     x, y, config) end
    function ctx:input(name, x, y, config)    return self:add(name, "input",    x, y, config) end
    function ctx:checkbox(name, x, y, config) return self:add(name, "checkbox", x, y, config) end
    function ctx:dropdown(name, x, y, config) return self:add(name, "dropdown", x, y, config) end
    function ctx:progress(name, x, y, config) return self:add(name, "progress", x, y, config) end
    function ctx:slider(name, x, y, config)    return self:add(name, "slider",    x, y, config) end
    function ctx:list(name, x, y, config)      return self:add(name, "list",      x, y, config) end
    function ctx:rect(name, x, y, config)      return self:add(name, "rect",      x, y, config) end
    function ctx:sprite(name, x, y, config)    return self:add(name, "sprite",    x, y, config) end
    --- Multi-line word-wrapped label. Height is auto-computed from text+width if not set.
    -- config.align = "left"|"center"|"right"
    function ctx:multiline(name, x, y, config) return self:add(name, "multiline", x, y, config) end
    function ctx:label(name, x, y, config)     return self:multiline(name, x, y, config) end

    --- Add a container (panel). w and h are required.
    function ctx:container(name, x, y, w, h, config)
        return self:_insert(element.makeContainer(name, x, y, w, h, config))
    end

    -- ─── Element management ───────────────────────────────────────────────────

    --- Remove a top-level element by name.
    ---@param self UIContext
    ---@param name string
    function ctx:remove(name)
        if self.elements[name] then
            self.elements[name] = nil
            self.dirty = true
        end
    end

    --- Add a child element to an existing container.
    ---@param self UIContext
    ---@param containerName string
    ---@param childName string
    ---@param childType string
    ---@param x number
    ---@param y number
    ---@param config table|nil
    ---@return table|nil child
    function ctx:addToContainer(containerName, childName, childType, x, y, config)
        local con = self.elements[containerName]
        if not con or con.type ~= "container" then return nil end
        local child = element.make(childName, childType, x, y, config or {})
        con.children[childName] = child
        con.childrenDirty = true
        return child
    end

    --- Remove a child from a container.
    ---@param self UIContext
    ---@param containerName string
    ---@param childName string
    function ctx:removeFromContainer(containerName, childName)
        local con = self.elements[containerName]
        if con and con.type == "container" then
            con.children[childName] = nil
            con.childrenDirty = true
        end
    end

    --- Update fields of a top-level element.
    -- Layout fields (x, y, z, w, h, …) update the element directly.
    -- Unknown keys are forwarded into element.config.
    ---@param self UIContext
    ---@param name string
    ---@param config table
    function ctx:update(name, config)
        local el = self.elements[name]
        if not el then return end
        for k, v in pairs(config) do
            if element.ELEMENT_FIELDS[k] then
                el[k] = v
                if element.DIRTY_FIELDS[k] then self.dirty = true end
            else
                el.config[k] = v
            end
        end
        if el.type == "text" and config.text then el.w = #config.text end
    end

    --- Update fields of a child element inside a container.
    ---@param self UIContext
    ---@param containerName string
    ---@param childName string
    ---@param config table
    function ctx:updateInContainer(containerName, childName, config)
        local con = self.elements[containerName]
        if not con or con.type ~= "container" then return end
        local child = con.children[childName]
        if not child then return end
        for k, v in pairs(config) do
            if element.ELEMENT_FIELDS[k] then
                child[k] = v
                if element.DIRTY_FIELDS[k] then con.childrenDirty = true end
            else
                child.config[k] = v
            end
        end
        if child.type == "text" and config.text then child.w = #config.text end
    end

    --- Read the current logical value of an element.
    -- Returns: text for button/input/text, boolean for checkbox,
    --          (index, value) for dropdown/list, number for progress/slider.
    ---@param self UIContext
    ---@param name string
    ---@return any
    function ctx:get(name)
        local el = self.elements[name]
        if not el then return nil end
        local t = el.type
        if t == "input" or t == "button" or t == "text" then
            return el.config.text
        elseif t == "checkbox" then
            return el.config.checked
        elseif t == "dropdown" or t == "list" then
            local idx = el.config.selectedIndex
            return idx, idx and el.config.options and el.config.options[idx]
        elseif t == "progress" then
            return el.config.progress
        elseif t == "slider" then
            return el.config.value or el.config.min or 0
        end
        return nil
    end

    -- ─── Layout ───────────────────────────────────────────────────────────────

    --- Resolve an element's absolute (rx, ry) given the context offset.
    ---@param self UIContext
    ---@param el table
    ---@param ox number
    ---@param oy number
    ---@return number rx
    ---@return number ry
    function ctx:getAbsolutePos(el, ox, oy)
        local tw, th = self.buf:getSize()
        local rx, ry = el.x + ox, el.y + oy
        local cx = ox + math.floor((tw - ox * 2) / 2) - math.floor(el.w / 2) + el.x
        local cy = oy + math.floor((th - oy * 2) / 2) - math.floor(el.h / 2) + el.y
        local bx = (tw - ox) - el.w - el.x
        local by = (th - oy) - el.h - el.y
        local a  = el.anchor
        if     a == "top-center"    then rx = cx
        elseif a == "top-right"     then rx = bx
        elseif a == "center-left"   then ry = cy
        elseif a == "center"        then rx = cx ; ry = cy
        elseif a == "center-right"  then rx = bx ; ry = cy
        elseif a == "bottom-left"   then ry = by
        elseif a == "bottom-center" then rx = cx ; ry = by
        elseif a == "bottom-right"  then rx = bx ; ry = by
        end
        return rx, ry
    end

    -- ─── Events ───────────────────────────────────────────────────────────────

    --- Dispatch a CC:Tweaked event to the UI context.
    ---@param self UIContext
    ---@param event table { os.pullEvent() } unpacked into a table
    ---@param ox number|nil X offset (default 0)
    ---@param oy number|nil Y offset (default 0)
    ---@return boolean consumed True if the event was consumed
    function ctx:handleEvent(event, ox, oy)
        return events.handle(self, self.buf, event, ox or 0, oy or 0)
    end

    -- ─── Rendering ────────────────────────────────────────────────────────────

    --- Draw all visible elements into the bound buffer.
    -- Call buf:present() afterwards to flush to the terminal.
    ---@param self UIContext
    ---@param ox number|nil X offset (default 0)
    ---@param oy number|nil Y offset (default 0)
    ---@param rowsToRestore table|nil Optional; populated with every row index touched
    ---@return table rowsToRestore
    function ctx:draw(ox, oy, rowsToRestore)
        ox = ox or 0
        oy = oy or 0
        rowsToRestore = rowsToRestore or {}
        if self.dirty then self:_sort() end
        for _, el in ipairs(self.sorted) do
            if el.visible then
                local rx, ry = self:getAbsolutePos(el, ox, oy)
                if el.type == "container" then
                    render.drawContainer(self.buf, el, rx, ry, self, rowsToRestore)
                else
                    render.drawEl(self.buf, el, rx, ry,
                                  self.pressedElement, self.focusedElement, rowsToRestore)
                end
            end
        end
        return rowsToRestore
    end

    return ctx
end

--- Alias retained for compatibility with old call sites.
UI.createContext = UI.new

return UI
