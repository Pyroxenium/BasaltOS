--- Obsidian Input Mapper
-- Provides a simple way to bind action names to multiple keys and check their state.
---@diagnostic disable: undefined-global

local input = require("core.input")

---@class InputMapperModule
---@field mappings table<string, (number|string)[]> Mapping of action names to lists of keys
local InputMapper = {
    mappings = {}
}

--- Bind an action name to one or more keys.
---@param actionName string Name of the action to bind (e.g. "jump", "moveLeft")
---@param keysTable number|string|table A key code, key name, or list of key codes/names to bind to the action
function InputMapper.bind(actionName, keysTable)
    if type(keysTable) ~= "table" then keysTable = {keysTable} end
    InputMapper.mappings[actionName] = keysTable
end

--- Check whether an action mapping is currently active (any bound key down).
---@param actionName string Name of the action to check (e.g. "jump", "moveLeft")
---@return boolean True if any key bound to the action is currently pressed, false otherwise
function InputMapper.isActive(actionName)
    local keysToCheck = InputMapper.mappings[actionName]
    if not keysToCheck then return false end

    for _, key in ipairs(keysToCheck) do
        if input.isKeyDown(key) then return true end
    end
    return false
end

--- Populate standard WASD bindings (calls `InputMapper.bind` internally).
function InputMapper.loadDefaultWASD()
    InputMapper.bind("up",    {keys.w, keys.up})
    InputMapper.bind("down",  {keys.s, keys.down})
    InputMapper.bind("left",  {keys.a, keys.left})
    InputMapper.bind("right", {keys.d, keys.right})
    InputMapper.bind("jump",  {keys.space})
    InputMapper.bind("use",   {keys.e, keys.enter})
end

return InputMapper