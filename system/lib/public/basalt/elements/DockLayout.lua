local elementManager = require("elementManager")
local VisualElement = require("elements/VisualElement")
local Container = elementManager.getElement("Container")
local tHex = require("libraries/colorHex")
---@configDescription A DockLayout element with dockable panels that automatically split and resize.
---@configDefault false

--- The DockLayout provides a docking system where panels can be docked and automatically resize
---@class DockLayout : Container
local DockLayout = setmetatable({}, Container)
DockLayout.__index = DockLayout

---@property rootNode table nil The root node of the layout tree
DockLayout.defineProperty(DockLayout, "rootNode", {default = nil, type = "table", allowNil = true})
---@property panels table {} List of all panels
DockLayout.defineProperty(DockLayout, "panels", {default = {}, type = "table"})
---@property draggedPanel table nil Currently dragged panel
DockLayout.defineProperty(DockLayout, "draggedPanel", {default = nil, type = "table", allowNil = true})
---@property hoverDockZone table nil Current hover dock zone
DockLayout.defineProperty(DockLayout, "hoverDockZone", {default = nil, type = "table", allowNil = true})

---@property panelHeaderHeight number 1 Height of panel headers
DockLayout.defineProperty(DockLayout, "panelHeaderHeight", {default = 1, type = "number", canTriggerRender = true})
---@property panelHeaderBackground color gray Background color for panel headers
DockLayout.defineProperty(DockLayout, "panelHeaderBackground", {default = colors.gray, type = "color", canTriggerRender = true})
---@property panelHeaderTextColor color white Text color for panel headers
DockLayout.defineProperty(DockLayout, "panelHeaderTextColor", {default = colors.white, type = "color", canTriggerRender = true})
---@property dockZoneColor color lightBlue Color for dock zone preview
DockLayout.defineProperty(DockLayout, "dockZoneColor", {default = colors.lightBlue, type = "color", canTriggerRender = true})

DockLayout.defineEvent(DockLayout, "mouse_click")
DockLayout.defineEvent(DockLayout, "mouse_drag")
DockLayout.defineEvent(DockLayout, "mouse_up")
DockLayout.defineEvent(DockLayout, "panelDocked")

--- @shortDescription Creates a new DockLayout instance
--- @return DockLayout self The created instance
--- @private
function DockLayout.new()
    local self = setmetatable({}, DockLayout):__init()
    self.class = DockLayout
    self.set("width", 40)
    self.set("height", 20)
    self.set("z", 10)
    return self
end

--- @shortDescription Initializes the DockLayout instance
--- @param props table The properties to initialize the element with
--- @param basalt table The basalt instance
--- @protected
function DockLayout:init(props, basalt)
    Container.init(self, props, basalt)
    self.set("type", "DockLayout")
end

--- Creates a new panel in the dock layout
--- @shortDescription Creates a new dockable panel
--- @param title string The title of the panel
--- @return table panelAPI The panel API object
function DockLayout:addPanel(title)
    local panels = self.getResolved("panels")
    local panelId = #panels + 1

    local panelContainer = self:addContainer()
    panelContainer.set("ignoreOffset", true)

    local panelData = {
        id = panelId,
        title = tostring(title or ("Panel " .. panelId)),
        container = panelContainer,
        x = 1,
        y = 1,
        width = 10,
        height = 10
    }

    table.insert(panels, panelData)

    if not self.getResolved("rootNode") then
        self.set("rootNode", {
            type = "panel",
            panel = panelData
        })
        self:updateLayout()
    end

    local panelAPI = {
        container = panelContainer,
        setTitle = function(_, newTitle)
            panelData.title = newTitle
            self:updateRender()
            return panelAPI
        end,
        dockTo = function(_, targetPanel, direction)
            self:dockPanel(panelData, targetPanel, direction)
            return panelAPI
        end
    }

    return panelAPI
end

--- @shortDescription Docks a panel to a target panel in a direction
--- @param sourcePanel table The panel to dock
--- @param targetPanel table The target panel (or nil for root)
--- @param direction string Direction: "top", "bottom", "left", "right"
function DockLayout:dockPanel(sourcePanel, targetPanel, direction)
    local rootNode = self.getResolved("rootNode")

    if not rootNode then
        -- First panel becomes root
        self.set("rootNode", {
            type = "panel",
            panel = sourcePanel
        })
        self:updateLayout()
        return
    end
    
    -- Find the target node
    local targetNode = targetPanel and self:findPanelNode(rootNode, targetPanel) or rootNode
    
    if not targetNode then return end
    
    -- Create new split node
    local isHorizontal = direction == "left" or direction == "right"
    local isVertical = direction == "top" or direction == "bottom"
    
    local newSplit = {
        type = "split",
        orientation = isHorizontal and "horizontal" or "vertical",
        ratio = 0.5, -- 50/50 split
        first = nil,
        second = nil
    }
    
    local newPanelNode = {
        type = "panel",
        panel = sourcePanel
    }
    
    -- Determine order based on direction
    if direction == "left" or direction == "top" then
        newSplit.first = newPanelNode
        newSplit.second = targetNode
    else
        newSplit.first = targetNode
        newSplit.second = newPanelNode
    end
    
    -- Replace target node with new split
    if targetNode == rootNode then
        self.set("rootNode", newSplit)
    else
        -- Find and replace target node in tree
        self:replaceNode(rootNode, targetNode, newSplit)
    end
    
    self:updateLayout()
    self:dispatchEvent("panelDocked", sourcePanel.id, targetPanel and targetPanel.id or nil, direction)
end

--- @shortDescription Finds a panel node in the tree
--- @param node table The current node
--- @param panel table The panel to find
--- @return table? node The found node or nil
--- @private
function DockLayout:findPanelNode(node, panel)
    if node.type == "panel" and node.panel == panel then
        return node
    elseif node.type == "split" then
        local found = self:findPanelNode(node.first, panel)
        if found then return found end
        return self:findPanelNode(node.second, panel)
    end
    return nil
end

--- @shortDescription Replaces a node in the tree
--- @param parent table The parent node
--- @param oldNode table The node to replace
--- @param newNode table The new node
--- @private
function DockLayout:replaceNode(parent, oldNode, newNode)
    if parent.type == "split" then
        if parent.first == oldNode then
            parent.first = newNode
            return true
        elseif parent.second == oldNode then
            parent.second = newNode
            return true
        else
            local replaced = self:replaceNode(parent.first, oldNode, newNode)
            if replaced then return true end
            return self:replaceNode(parent.second, oldNode, newNode)
        end
    end
    return false
end

--- @shortDescription Updates the entire layout by calculating positions
--- @private
function DockLayout:updateLayout()
    local rootNode = self.getResolved("rootNode")
    if not rootNode then return end
    
    local width = self.getResolved("width")
    local height = self.getResolved("height")
    
    -- Calculate layout recursively
    self:calculateNodeLayout(rootNode, 1, 1, width, height)
    self:updateRender()
end

--- @shortDescription Calculates layout for a node and its children
--- @param node table The node to calculate
--- @param x number X position
--- @param y number Y position
--- @param width number Available width
--- @param height number Available height
--- @private
function DockLayout:calculateNodeLayout(node, x, y, width, height)
    if node.type == "panel" then
        -- Update panel position and size
        local panel = node.panel
        local headerHeight = self.getResolved("panelHeaderHeight")
        
        panel.x = x
        panel.y = y
        panel.width = width
        panel.height = height
        
        -- Update container
        panel.container.set("x", x)
        panel.container.set("y", y + headerHeight)
        panel.container.set("width", width)
        panel.container.set("height", math.max(1, height - headerHeight))
        panel.container.set("visible", true)
        
    elseif node.type == "split" then
        local ratio = node.ratio or 0.5
        
        if node.orientation == "horizontal" then
            -- Split left/right
            local leftWidth = math.floor(width * ratio)
            local rightWidth = width - leftWidth
            
            self:calculateNodeLayout(node.first, x, y, leftWidth, height)
            self:calculateNodeLayout(node.second, x + leftWidth, y, rightWidth, height)
            
        else -- vertical
            -- Split top/bottom
            local topHeight = math.floor(height * ratio)
            local bottomHeight = height - topHeight
            
            self:calculateNodeLayout(node.first, x, y, width, topHeight)
            self:calculateNodeLayout(node.second, x, y + topHeight, width, bottomHeight)
        end
    end
end

--- @shortDescription Gets panel at position
--- @param x number X position
--- @param y number Y position
--- @return table? panel The panel at position or nil
--- @private
function DockLayout:getPanelAt(x, y)
    local panels = self.getResolved("panels")
    
    for _, panel in ipairs(panels) do
        if x >= panel.x and x < panel.x + panel.width and
           y >= panel.y and y < panel.y + panel.height then
            return panel
        end
    end
    
    return nil
end

--- @shortDescription Checks if position is on panel header
--- @param panel table The panel
--- @param x number X position
--- @param y number Y position
--- @return boolean onHeader
--- @private
function DockLayout:isOnPanelHeader(panel, x, y)
    local headerHeight = self.getResolved("panelHeaderHeight")
    return x >= panel.x and x < panel.x + panel.width and
           y >= panel.y and y < panel.y + headerHeight
end

--- @shortDescription Calculates dock zone at position
--- @param panel table The target panel
--- @param x number X position
--- @param y number Y position
--- @return table? dockZone The dock zone info or nil
--- @private
function DockLayout:getDockZone(panel, x, y)
    if not panel then return nil end
    
    -- Calculate relative position in panel
    local relX = x - panel.x
    local relY = y - panel.y
    local w = panel.width
    local h = panel.height
    
    -- Define dock zones (20% of each edge)
    local edgeSize = math.max(2, math.min(w, h) * 0.2)
    
    -- Top
    if relY < edgeSize then
        return {
            direction = "top",
            x = panel.x,
            y = panel.y,
            width = w,
            height = math.floor(h / 2)
        }
    end
    
    -- Bottom
    if relY >= h - edgeSize then
        return {
            direction = "bottom",
            x = panel.x,
            y = panel.y + math.floor(h / 2),
            width = w,
            height = math.ceil(h / 2)
        }
    end
    
    -- Left
    if relX < edgeSize then
        return {
            direction = "left",
            x = panel.x,
            y = panel.y,
            width = math.floor(w / 2),
            height = h
        }
    end
    
    -- Right
    if relX >= w - edgeSize then
        return {
            direction = "right",
            x = panel.x + math.floor(w / 2),
            y = panel.y,
            width = math.ceil(w / 2),
            height = h
        }
    end
    
    return nil
end

--- @shortDescription Handles mouse click events
--- @protected
function DockLayout:mouse_click(button, x, y)
    if not VisualElement.mouse_click(self, button, x, y) then
        return false
    end

    local relX, relY = VisualElement.getRelativePosition(self, x, y)
    local panel = self:getPanelAt(relX, relY)
    
    if panel and self:isOnPanelHeader(panel, relX, relY) then
        -- Start dragging panel
        self.set("draggedPanel", panel)
        return true
    end
    
    return Container.mouse_click(self, button, x, y)
end

--- @shortDescription Handles mouse drag events
--- @protected
function DockLayout:mouse_drag(button, x, y)
    local draggedPanel = self.getResolved("draggedPanel")
    
    if draggedPanel then
        local relX, relY = VisualElement.getRelativePosition(self, x, y)
        local targetPanel = self:getPanelAt(relX, relY)
        
        if targetPanel and targetPanel ~= draggedPanel then
            local dockZone = self:getDockZone(targetPanel, relX, relY)
            self.set("hoverDockZone", dockZone)
        else
            self.set("hoverDockZone", nil)
        end
        
        self:updateRender()
        return true
    end
    
    return Container.mouse_drag(self, button, x, y)
end

--- @shortDescription Handles mouse up events
--- @protected
function DockLayout:mouse_up(button, x, y)
    local draggedPanel = self.getResolved("draggedPanel")
    local hoverDockZone = self.getResolved("hoverDockZone")
    
    if draggedPanel and hoverDockZone then
        local relX, relY = VisualElement.getRelativePosition(self, x, y)
        local targetPanel = self:getPanelAt(relX, relY)
        
        if targetPanel and targetPanel ~= draggedPanel then
            self:dockPanel(draggedPanel, targetPanel, hoverDockZone.direction)
        end
    end
    
    self.set("draggedPanel", nil)
    self.set("hoverDockZone", nil)
    self:updateRender()
    
    return Container.mouse_up(self, button, x, y)
end

--- @shortDescription Renders the DockLayout
--- @protected
function DockLayout:render()
    VisualElement.render(self)
    
    local panels = self.getResolved("panels")
    local headerHeight = self.getResolved("panelHeaderHeight")
    local hoverDockZone = self.getResolved("hoverDockZone")
    
    -- Render dock zone preview
    if hoverDockZone then
        local zone = hoverDockZone
        for y = zone.y, zone.y + zone.height - 1 do
            VisualElement.multiBlit(
                self,
                zone.x,
                y,
                zone.width,
                1,
                " ",
                tHex[colors.white],
                tHex[self.getResolved("dockZoneColor")]
            )
        end
    end
    
    -- Render panel headers
    for _, panel in ipairs(panels) do
        if panel.container.get("visible") then
            -- Draw header
            VisualElement.multiBlit(
                self,
                panel.x,
                panel.y,
                panel.width,
                headerHeight,
                " ",
                tHex[self.getResolved("panelHeaderTextColor")],
                tHex[self.getResolved("panelHeaderBackground")]
            )
            
            -- Draw title
            local title = panel.title
            if #title > panel.width - 2 then
                title = title:sub(1, panel.width - 2)
            end
            VisualElement.textFg(self, panel.x + 1, panel.y, title, self.getResolved("panelHeaderTextColor"))
        end
    end
    
    -- Render panel containers
    if not self.getResolved("childrenSorted") then
        self:sortChildren()
    end
    if not self.getResolved("childrenEventsSorted") then
        for eventName in pairs(self._values.childrenEvents or {}) do
            self:sortChildrenEvents(eventName)
        end
    end

    for _, child in ipairs(self.getResolved("visibleChildren") or {}) do
        if child == self then 
            error("CIRCULAR REFERENCE DETECTED!") 
            return 
        end
        child:render()
        child:postRender()
    end
end

return DockLayout