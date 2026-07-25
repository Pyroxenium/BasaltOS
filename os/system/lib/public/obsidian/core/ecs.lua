---@diagnostic disable: undefined-global

--- The world module implements a simple Entity-Component-System (ECS) architecture for game state management.
---@class World
---@field _nextId number Next entity ID to assign
---@field _entities table<number, boolean> Set of living entity IDs
---@field _store table<string, table<number, any>> Component storage: component type -> entity ID -> data
---@field _tags table<number, table<string, boolean>> Entity tags: entity ID -> component type -> true
---@field _index table<string, table<number, boolean>> Component index: component type -> entity ID -> true
local World = {}
World.__index = World

--- Create a new World instance
---@return World
function World.new()
    local self = setmetatable({}, World)
    self._nextId = 1
    self._entities = {}
    self._store = {}
    self._tags = {}
    self._index = {}
    return self
end

-- ============================================================================
-- Entity Lifecycle
-- ============================================================================

--- Spawn a new entity
---@param self World The world instance
---@return number id New entity ID
function World:spawn()
    local id = self._nextId
    self._nextId = id + 1
    self._entities[id] = true
    self._tags[id] = {}
    return id
end

--- Check if an entity is alive
---@param self World The world instance
---@param id number Entity ID
---@return boolean True if entity exists and is alive
function World:alive(id)
    return self._entities[id] == true
end

--- Destroy an entity and all its components
---@param self World The world instance
---@param id number Entity ID
function World:despawn(id)
    if not self:alive(id) then
        logger.warn("ECS: Attempted to despawn non-existent entity " .. tostring(id))
        return
    end

    for component in pairs(self._tags[id] or {}) do
        self:detach(id, component)
    end

    self._entities[id] = nil
    self._tags[id] = nil
end

--- Get all living entity IDs
---@param self World The world instance
---@return number[] List of entity IDs
function World:entities()
    local result = {}
    for id in pairs(self._entities) do
        table.insert(result, id)
    end
    return result
end

--- Count living entities
---@param self World The world instance
---@return number Count of living entities
function World:count()
    local n = 0
    for _ in pairs(self._entities) do
        n = n + 1
    end
    return n
end

-- ============================================================================
-- Component Management
-- ============================================================================

--- Attach a component to an entity
---@param self World The world instance
---@param id number Entity ID
---@param component string Component type
---@param data any Component data
function World:attach(id, component, data)
    if id == nil then
        logger.error("ECS: attach() called with nil entity (component='" .. tostring(component) .. "')")
        return
    end
    if component == nil then
        logger.error("ECS: attach() called with nil component for entity " .. tostring(id))
        return
    end
    if not self:alive(id) then
        logger.error("ECS: attach() called on dead entity " .. tostring(id))
        return
    end

    if not self._store[component] then
        self._store[component] = {}
        self._index[component] = {}
    end

    self._store[component][id] = data
    self._tags[id][component] = true
    self._index[component][id] = true
end

--- Get a component from an entity
---@param self World The world instance
---@param id number Entity ID
---@param component string Component type
---@return any|nil Component data, or nil if entity doesn't have the component
function World:get(id, component)
    if not self:alive(id) then
        return nil
    end

    local storage = self._store[component]
    return storage and storage[id]
end

--- Check if an entity has a component
---@param self World The world instance
---@param id number Entity ID
---@param component string Component type
---@return boolean True if entity has the component, false otherwise
function World:has(id, component)
    return self._tags[id] ~= nil and self._tags[id][component] == true
end

--- Detach a component from an entity
---@param self World The world instance
---@param id number Entity ID
---@param component string Component type
function World:detach(id, component)
    if not self:alive(id) then
        return
    end
    if self._store[component] then
        self._store[component][id] = nil
    end
    if self._tags[id] then
        self._tags[id][component] = nil
    end
    if self._index[component] then
        self._index[component][id] = nil
    end
end

--- Get all components attached to an entity
---@param self World The world instance
---@param id number Entity ID
---@return table<string, any>
function World:components(id)
    if not self:alive(id) then
        return {}
    end

    local result = {}
    for component in pairs(self._tags[id] or {}) do
        result[component] = self:get(id, component)
    end
    return result
end

--- Update a component (shorthand for get + modify + attach)
---@param self World The world instance
---@param id number Entity ID
---@param component string Component type
---@param fn fun(data: any): any Updater function
function World:update(id, component, fn)
    local current = self:get(id, component)
    if current then
        local updated = fn(current)
        if updated ~= nil then
            self:attach(id, component, updated)
        end
    end
end

-- ============================================================================
-- Query System
-- ============================================================================

--- Find entities that have ALL listed components
---@param self World The world instance
---@param ... string Component types
---@return number[] Entity IDs
function World:select(...)
    local components = {...}

    if #components == 0 then
        return self:entities()
    end

    local smallest = components[1]
    local smallestSize = math.huge

    for _, comp in ipairs(components) do
        local index = self._index[comp]
        if not index then
            return {}
        end

        local size = self:countType(comp)

        if size < smallestSize then
            smallestSize = size
            smallest = comp
        end
    end

    local source = self._index[smallest]
    local results = {}

    for id in pairs(source) do
        local match = true
        local tags = self._tags[id]

        for _, comp in ipairs(components) do
            if not tags[comp] then
                match = false
                break
            end
        end

        if match then
            table.insert(results, id)
        end
    end

    return results
end

--- Find entities that have ANY of the listed components
---@param self World The world instance
---@param ... string Component types
---@return number[] Entity IDs
function World:selectAny(...)
    local components = {...}

    if #components == 0 then
        return {}
    end

    local resultSet = {}

    for _, comp in ipairs(components) do
        local index = self._index[comp]
        if index then
            for id in pairs(index) do
                resultSet[id] = true
            end
        end
    end

    local results = {}
    for id in pairs(resultSet) do
        table.insert(results, id)
    end

    return results
end

--- Find entities that have NONE of the listed components
---@param self World The world instance
---@param ... string Component types
---@return number[] Entity IDs
function World:exclude(...)
    local components = {...}
    local results = {}

    for id in pairs(self._entities) do
        local hasAny = false
        local tags = self._tags[id]

        for _, comp in ipairs(components) do
            if tags[comp] then
                hasAny = true
                break
            end
        end

        if not hasAny then
            table.insert(results, id)
        end
    end

    return results
end

--- Find the first entity that matches all components
---@param self World The world instance
---@param ... string Component types
---@return number|nil Entity ID
function World:first(...)
    local results = self:select(...)
    return results[1]
end

--- Iterate over entities with specific components
---@param self World The world instance
---@param ... string Component types
---@return fun(): (number|nil, ...) Iterator that yields entity ID and component values
function World:each(...)
    local components = {...}
    local entities = self:select(...)
    local i = 0

    return function()
        i = i + 1
        local id = entities[i]
        if not id then return nil end

        local values = {}
        for _, comp in ipairs(components) do
            table.insert(values, self:get(id, comp))
        end

        return id, table.unpack(values)
    end
end

-- ============================================================================
-- Bulk Operations
-- ============================================================================

--- Apply a function to all entities with specific components
---@param self World The world instance
---@param fn fun(id: number, ...: any) Function to apply
---@param ... string Component types to match
function World:forEach(fn, ...)
    for id in self:each(...) do
        fn(id)
    end
end

--- Count entities with specific components
---@param self World The world instance
---@param ... string Component types
---@return number
function World:countWith(...)
    return #self:select(...)
end

-- ============================================================================
-- Component Type Info
-- ============================================================================

--- Get all registered component types
---@param self World The world instance
---@return string[] List of component type names
function World:types()
    local result = {}
    for name in pairs(self._store) do
        table.insert(result, name)
    end
    return result
end

--- Count instances of a component type
---@param self World The world instance
---@param component string Component type
---@return number Count of entities with this component
function World:countType(component)
    local index = self._index[component]
    if not index then return 0 end

    local n = 0
    for _ in pairs(index) do
        n = n + 1
    end
    return n
end

-- ============================================================================
-- Utility / Debug
-- ============================================================================

--- Get statistics about the world
---@param self World The world instance
---@return table Statistics including entity count, component counts, etc.
function World:stats()
    local componentCounts = {}
    for comp, index in pairs(self._index) do
        local count = 0
        for _ in pairs(index) do
            count = count + 1
        end
        componentCounts[comp] = count
    end

    return {
        entities = self:count(),
        types = #self:types(),
        components = componentCounts,
    }
end

--- Clear all entities and components
---@param self World The world instance
function World:clear()
    self._nextId = 1
    self._entities = {}
    self._tags = {}

    for comp in pairs(self._store) do
        self._store[comp] = {}
        self._index[comp] = {}
    end
end

--- Debug print world state
---@param self World The world instance
function World:debug()
    logger.info("=== ECS World Debug ===")
    logger.info("Entities: " .. self:count())
    logger.info("Component Types: " .. #self:types())

    for _, comp in ipairs(self:types()) do
        logger.info("  - " .. comp .. ": " .. self:countType(comp) .. " instances")
    end

    for id in pairs(self._entities) do
        local comps = {}
        for comp in pairs(self._tags[id]) do
            table.insert(comps, comp)
        end
        logger.info("Entity " .. id .. ": [" .. table.concat(comps, ", ") .. "]")
    end
end

-- ============================================================================
-- Module Export
-- ============================================================================

---@class ECSModule
local ECS = {}

--- Create a new World instance
---@return World
function ECS.createWorld()
    return World.new()
end

--- Alias for createWorld
---@return World
function ECS.new()
    return World.new()
end

return ECS