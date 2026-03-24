local elementManager = require("elementManager")
local VisualElement = require("elements/VisualElement")
local Container = elementManager.getElement("Container")
local tHex = require("libraries/colorHex")
---@configDescription A Stepper/Wizard element that guides users through a multi-step process.
---@configDefault false

--- The Stepper is a container that provides step-by-step navigation functionality
---@class Stepper : Container
local Stepper = setmetatable({}, Container)
Stepper.__index = Stepper

---@property steps table {} List of step definitions
Stepper.defineProperty(Stepper, "steps", {default = {}, type = "table"})
---@property currentStep number 1 The currently active step (1-indexed)
Stepper.defineProperty(Stepper, "currentStep", {default = 1, type = "number", canTriggerRender = true})
---@property stepHeaderHeight number 3 Height of the step header area
Stepper.defineProperty(Stepper, "stepHeaderHeight", {default = 3, type = "number", canTriggerRender = true})
---@property allowSkipSteps boolean false Allow clicking on any step (true) or only adjacent steps (false)
Stepper.defineProperty(Stepper, "allowSkipSteps", {default = false, type = "boolean"})

---@property headerBackground color gray Background color for the step header
Stepper.defineProperty(Stepper, "headerBackground", {default = colors.gray, type = "color", canTriggerRender = true})
---@property completedStepColor color green Color for completed steps
Stepper.defineProperty(Stepper, "completedStepColor", {default = colors.green, type = "color", canTriggerRender = true})
---@property activeStepColor color lightBlue Color for the active step
Stepper.defineProperty(Stepper, "activeStepColor", {default = colors.lightBlue, type = "color", canTriggerRender = true})
---@property pendingStepColor color lightGray Color for pending steps
Stepper.defineProperty(Stepper, "pendingStepColor", {default = colors.lightGray, type = "color", canTriggerRender = true})
---@property stepTextColor color white Text color for step labels
Stepper.defineProperty(Stepper, "stepTextColor", {default = colors.white, type = "color", canTriggerRender = true})

Stepper.defineEvent(Stepper, "mouse_click")
Stepper.defineEvent(Stepper, "stepChanged")
Stepper.defineEvent(Stepper, "stepCompleted")

--- @shortDescription Creates a new Stepper instance
--- @return Stepper self The created instance
--- @private
function Stepper.new()
    local self = setmetatable({}, Stepper):__init()
    self.class = Stepper
    self.set("width", 30)
    self.set("height", 15)
    self.set("z", 10)
    return self
end

--- @shortDescription Initializes the Stepper instance
--- @param props table The properties to initialize the element with
--- @param basalt table The basalt instance
--- @protected
function Stepper:init(props, basalt)
    Container.init(self, props, basalt)
    self.set("type", "Stepper")
end

--- Creates a new step and returns the step's container
--- @shortDescription Creates a new step in the wizard
--- @param title string The title/label of the step
--- @return table stepContainer The container for this step's content
function Stepper:newStep(title)
    local steps = self.getResolved("steps") or {}
    local stepId = #steps + 1

    -- Create container for this step's content
    local stepContainer = self:addContainer()
    stepContainer.set("x", 1)
    stepContainer.set("y", 1)
    stepContainer.set("width", self.getResolved("width"))
    stepContainer.set("height", self.getResolved("height") - self.getResolved("stepHeaderHeight"))
    stepContainer.set("visible", stepId == self.getResolved("currentStep"))
    stepContainer.set("ignoreOffset", true)
    
    table.insert(steps, {
        id = stepId,
        title = tostring(title or ("Step " .. stepId)),
        completed = false,
        container = stepContainer
    })

    self.set("steps", steps)
    self:updateStepLayout()

    return stepContainer
end
Stepper.addStep = Stepper.newStep

--- @shortDescription Updates the layout and visibility of all steps
--- @private
function Stepper:updateStepLayout()
    local steps = self.getResolved("steps") or {}
    local currentStep = self.getResolved("currentStep")
    local headerHeight = self.getResolved("stepHeaderHeight")
    local width = self.getResolved("width")
    local contentHeight = self.getResolved("height") - headerHeight
    
    for _, step in ipairs(steps) do
        step.container.set("y", headerHeight + 1)
        step.container.set("width", width)
        step.container.set("height", contentHeight)
        step.container.set("visible", step.id == currentStep)
    end
    
    self:updateRender()
end

--- @shortDescription Moves to the next step
--- @return Stepper self For method chaining
function Stepper:nextStep()
    local steps = self.getResolved("steps") or {}
    local currentStep = self.getResolved("currentStep")
    
    if currentStep < #steps then
        -- Mark current step as completed
        steps[currentStep].completed = true
        
        self.set("currentStep", currentStep + 1)
        self:updateStepLayout()
        self:dispatchEvent("stepChanged", currentStep + 1, currentStep)
        self:dispatchEvent("stepCompleted", currentStep)
    end
    
    return self
end

--- @shortDescription Moves to the previous step
--- @return Stepper self For method chaining
function Stepper:previousStep()
    local currentStep = self.getResolved("currentStep")
    
    if currentStep > 1 then
        self.set("currentStep", currentStep - 1)
        self:updateStepLayout()
        self:dispatchEvent("stepChanged", currentStep - 1, currentStep)
    end
    
    return self
end

--- @shortDescription Jumps to a specific step
--- @param stepId number The step ID to jump to
--- @return Stepper self For method chaining
function Stepper:goToStep(stepId)
    local steps = self.getResolved("steps") or {}
    local currentStep = self.getResolved("currentStep")
    local allowSkip = self.getResolved("allowSkipSteps")
    
    if stepId < 1 or stepId > #steps then
        return self
    end
    
    -- Check if we can go to this step
    if not allowSkip then
        -- Only allow going to adjacent steps or completed steps
        local canGo = false
        if stepId == currentStep - 1 or stepId == currentStep + 1 then
            canGo = true
        elseif stepId < currentStep then
            -- Can go back to any previous step
            canGo = true
        end
        
        if not canGo then
            return self
        end
    end
    
    -- Mark all steps before the target as completed if moving forward
    if stepId > currentStep then
        for i = currentStep, stepId - 1 do
            steps[i].completed = true
        end
    end
    
    self.set("currentStep", stepId)
    self:updateStepLayout()
    self:dispatchEvent("stepChanged", stepId, currentStep)
    
    return self
end

--- @shortDescription Resets the stepper to the first step
--- @return Stepper self For method chaining
function Stepper:reset()
    local steps = self.getResolved("steps") or {}
    
    for _, step in ipairs(steps) do
        step.completed = false
    end
    
    self.set("currentStep", 1)
    self:updateStepLayout()
    
    return self
end

--- @shortDescription Gets a step container by ID
--- @param stepId number The step ID
--- @return table? container The step's container or nil
function Stepper:getStep(stepId)
    local steps = self.getResolved("steps") or {}
    if stepId >= 1 and stepId <= #steps then
        return steps[stepId].container
    end
    return nil
end

--- @shortDescription Calculates step header layout for rendering
--- @return table metrics Step layout information
--- @private
function Stepper:_getStepMetrics()
    local steps = self.getResolved("steps") or {}
    local width = self.getResolved("width")
    local currentStep = self.getResolved("currentStep")
    
    if #steps == 0 then
        return {positions = {}}
    end
    
    -- Calculate width for each step indicator
    local stepWidth = math.floor(width / #steps)
    local positions = {}
    
    for i, step in ipairs(steps) do
        local x1 = (i - 1) * stepWidth + 1
        local x2 = math.min(i * stepWidth, width)
        
        -- Adjust last step to fill remaining width
        if i == #steps then
            x2 = width
        end
        
        local status = "pending"
        if step.completed then
            status = "completed"
        elseif i == currentStep then
            status = "active"
        elseif i < currentStep then
            status = "completed"
        end
        
        table.insert(positions, {
            id = step.id,
            title = step.title,
            x1 = x1,
            x2 = x2,
            width = x2 - x1 + 1,
            status = status
        })
    end
    
    return {positions = positions}
end

--- @shortDescription Handles mouse click events for step navigation
--- @param button number The button that was clicked
--- @param x number The x position of the click (global)
--- @param y number The y position of the click (global)
--- @return boolean Whether the event was handled
--- @protected
function Stepper:mouse_click(button, x, y)
    if not VisualElement.mouse_click(self, button, x, y) then
        return false
    end

    local relX, relY = VisualElement.getRelativePosition(self, x, y)
    local headerHeight = self.getResolved("stepHeaderHeight")
    local metrics = self:_getStepMetrics()
    
    -- Check if click is on step header
    if relY <= headerHeight then
        for _, stepInfo in ipairs(metrics.positions) do
            if relX >= stepInfo.x1 and relX <= stepInfo.x2 then
                self:goToStep(stepInfo.id)
                return true
            end
        end
        return true
    end
    
    -- Let Container handle child events
    return Container.mouse_click(self, button, x, y)
end

--- @shortDescription Renders the Stepper (header + active step content)
--- @protected
function Stepper:render()
    VisualElement.render(self)
    
    local width = self.getResolved("width")
    local headerHeight = self.getResolved("stepHeaderHeight")
    local metrics = self:_getStepMetrics()
    
    -- Draw header background
    for y = 1, headerHeight do
        VisualElement.multiBlit(self, 1, y, width, 1, " ", tHex[self.getResolved("stepTextColor")], tHex[self.getResolved("headerBackground")])
    end
    
    -- Draw step indicators
    for _, stepInfo in ipairs(metrics.positions) do
        local bgColor
        if stepInfo.status == "completed" then
            bgColor = self.getResolved("completedStepColor")
        elseif stepInfo.status == "active" then
            bgColor = self.getResolved("activeStepColor")
        else
            bgColor = self.getResolved("pendingStepColor")
        end

        local fgColor = self.getResolved("stepTextColor")

        -- Draw step background
        for y = 1, headerHeight do
            VisualElement.multiBlit(
                self,
                stepInfo.x1,
                y,
                stepInfo.width,
                1,
                " ",
                tHex[fgColor],
                tHex[bgColor]
            )
        end
        
        -- Draw step number and title
        local stepLabel = tostring(stepInfo.id)
        if stepInfo.status == "completed" then
            stepLabel = "\7" -- checkmark character
        end
        
        -- Center the step number
        local labelY = math.floor(headerHeight / 2)
        local labelX = stepInfo.x1 + math.floor((stepInfo.width - 1) / 2)
        VisualElement.textFg(self, labelX, labelY, stepLabel, fgColor)
        
        -- Draw title (truncated if needed)
        local titleY = labelY + 1
        if titleY <= headerHeight then
            local title = stepInfo.title
            if #title > stepInfo.width - 2 then
                title = title:sub(1, stepInfo.width - 2)
            end
            local titleX = stepInfo.x1 + math.floor((stepInfo.width - #title) / 2)
            VisualElement.textFg(self, titleX, titleY, title, fgColor)
        end
        
        -- Draw connector line to next step (if not last)
        if stepInfo.id < #metrics.positions then
            local lineY = labelY
            local lineX = stepInfo.x2
            if lineX < width then
                VisualElement.textFg(self, lineX, lineY, ">", fgColor)
            end
        end
    end
    
    -- Render active step container
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

return Stepper