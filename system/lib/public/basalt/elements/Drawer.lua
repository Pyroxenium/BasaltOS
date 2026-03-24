local elementManager = require("elementManager")
local Container = elementManager.getElement("Container")
---@configDescription A Drawer element that slides in from the side as an overlay.
---@configDefault false

--- The Drawer is a container that appears as an overlay panel from the side
---@class Drawer : Container
local Drawer = setmetatable({}, Container)
Drawer.__index = Drawer

---@property isOpen boolean false Whether the drawer is currently open
Drawer.defineProperty(Drawer, "isOpen", {default = false, type = "boolean", canTriggerRender = true})
---@property position string right Position of the drawer ("left", "right", "top", "bottom")
Drawer.defineProperty(Drawer, "position", {default = "right", type = "string", canTriggerRender = true})
---@property drawerSize number 15 Size of the drawer (width for left/right, height for top/bottom)
Drawer.defineProperty(Drawer, "drawerSize", {default = 15, type = "number", canTriggerRender = true})

--- @shortDescription Creates a new Drawer instance
--- @return Drawer self The created instance
--- @private
function Drawer.new()
    local self = setmetatable({}, Drawer):__init()
    self.class = Drawer
    self.set("width", 30)
    self.set("height", 15)
    self.set("z", 100)
    return self
end

--- @shortDescription Initializes the Drawer instance
--- @param props table The properties to initialize the element with
--- @param basalt table The basalt instance
--- @protected
function Drawer:init(props, basalt)
    Container.init(self, props, basalt)
    self.set("type", "Drawer")
    self:updateDrawerLayout()
end

--- @shortDescription Opens the drawer
--- @return Drawer self For method chaining
function Drawer:open()
    self:updateDrawerLayout()
    return self
end

--- @shortDescription Closes the drawer
--- @return Drawer self For method chaining
function Drawer:close()
    self:updateDrawerLayout()
    return self
end

--- @shortDescription Toggles the drawer open/closed state
--- @return Drawer self For method chaining
function Drawer:toggle()
    if self.getResolved("visible") then
        return self:close()
    else
        return self:open()
    end
end

--- @shortDescription Updates the drawer content container layout
--- @private
function Drawer:updateDrawerLayout()
    local position = self.getResolved("position")
    local size = self.getResolved("drawerSize")
    local width = self.getResolved("width")
    local height = self.getResolved("height")

    self.set("visible", not self.getResolved("visible"))

    if position == "right" then
        self.set("x", width - size + 1)
        self.set("y", 1)
        self.set("width", size)
        self.set("height", height)
    elseif position == "left" then
        self.set("x", 1)
        self.set("y", 1)
        self.set("width", size)
        self.set("height", height)
    elseif position == "top" then
        self.set("x", 1)
        self.set("y", 1)
        self.set("width", width)
        self.set("height", size)
    elseif position == "bottom" then
        self.set("x", 1)
        self.set("y", height - size + 1)
        self.set("width", width)
        self.set("height", size)
    end

    self:updateRender()
end

return Drawer