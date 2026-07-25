-- Obsidian Engine: Database Module
-- In-memory key-value store with collection support and optional persistence.
-- Writes directly to disk under its own directory (default: "db/").
---@diagnostic disable: undefined-global

local logger  = require("core.logger")

---@class DatabaseModule
local DatabaseModule = {}

---@class Collection
---@field _name string Collection name (also used as filename on disk)
---@field _dir string Directory for storing collection files (default "db/")
---@field _autosave boolean Whether to flush to disk after every write operation (default true)
---@field _records table List of records (tables with arbitrary fields, must include unique _id)
---@field _nextId number Auto-incrementing ID counter for new records
local Collection = {}
Collection.__index = Collection

local function _matches(record, filter)
    for k, v in pairs(filter) do
        local rv = record[k]
        if type(v) == "function" then
            if not v(rv) then return false end
        else
            if rv ~= v then return false end
        end
    end
    return true
end

local function _copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        out[k] = _copy(v)
    end
    return out
end

--- Create or load a collection.
---@param name string Collection name (used as filename on disk)
---@param opts? table Optional table: { autosave = true, dir = "db/" }
---@return Collection collection instance
function DatabaseModule.open(name, opts)
    opts = opts or {}
    local self = setmetatable({}, Collection)
    ---@cast self Collection
    self._name = name
    self._dir = opts.dir or "db/"
    self._autosave = (opts.autosave ~= false)
    self._records = {}
    self._nextId = 1

    local path = fs.combine(self._dir, name .. ".dat")
    if fs.exists(path) then
        local file = fs.open(path, "r")
        if file then
            local ok, saved = pcall(textutils.unserialize, file.readAll())
            file.close()
            if ok and saved then
                self._records = saved.records or {}
                self._nextId  = saved.nextId  or 1
                logger.info("DB: Loaded collection '" .. name .. "' (" .. #self._records .. " records)")
            else
                logger.error("DB: Failed to parse '" .. path .. "'")
            end
        end
    end

    return self
end

-- ─── Write Operations ─────────────────────────────────────────────────────────

--- Insert a new record. Automatically assigns an `_id` if not present.
---@param self Collection
---@param record table New record to insert (table of key-value pairs)
---@return table insertedRecord Copy of the inserted record, including assigned _id
function Collection:insert(record)
    local r = _copy(record)
    if r._id == nil then
        r._id = self._nextId
        self._nextId = self._nextId + 1
    else
        if type(r._id) == "number" and r._id >= self._nextId then
            self._nextId = r._id + 1
        end
    end
    table.insert(self._records, r)
    if self._autosave then self:flush() end
    return _copy(r)
end

--- Insert multiple records at once.
---@param self Collection
---@param list table[] List of records to insert
---@return table[] insertedRecords List of inserted records with assigned _id fields
function Collection:insertMany(list)
    local out = {}
    for _, rec in ipairs(list) do
        out[#out + 1] = self:insert(rec)
    end
    return out
end

--- Update all records matching `filter` with the fields in `patch`.
--- Patch values overwrite existing fields; other fields are untouched.
---@param self Collection
---@param filter table Filter to match records (e.g. { type = "enemy" })
---@param patch table Fields to update (e.g. { hp = 100 })
---@return number updatedCount Number of records updated
function Collection:update(filter, patch)
    local count = 0
    for _, rec in ipairs(self._records) do
        if _matches(rec, filter) then
            for k, v in pairs(patch) do
                if k ~= "_id" then
                    rec[k] = _copy(v)
                end
            end
            count = count + 1
        end
    end
    if count > 0 and self._autosave then self:flush() end
    return count
end

--- Upsert: update if exists, insert if not.
---@param self Collection
---@param filter table Filter to match records (e.g. { type = "enemy" })
---@param data table Fields to update or insert (e.g. { hp = 100 })
---@return string "updated"|"inserted"
function Collection:upsert(filter, data)
    local existing = self:findOne(filter)
    if existing then
        self:update({ _id = existing._id }, data)
        return "updated"
    else
        self:insert(data)
        return "inserted"
    end
end

--- Delete all records matching `filter`.
---@param self Collection
---@param filter table Filter to match records (e.g. { type = "enemy" })
---@return number deletedCount Number of records deleted
function Collection:delete(filter)
    local kept  = {}
    local count = 0
    for _, rec in ipairs(self._records) do
        if _matches(rec, filter) then
            count = count + 1
        else
            kept[#kept + 1] = rec
        end
    end
    self._records = kept
    if count > 0 and self._autosave then self:flush() end
    return count
end

--- Delete all records in the collection.
---@param self Collection
---@return number deletedCount Number of records deleted
function Collection:clear()
    local count = #self._records
    self._records = {}
    self._nextId  = 1
    if self._autosave then self:flush() end
    return count
end

-- ─── Read Operations ──────────────────────────────────────────────────────────

--- Return all records matching `filter` (or all records if filter is nil).
---@param self Collection
---@param filter? table Filter to match records (e.g. { type = "enemy" })
---@param opts? table Optional query options: { orderBy = "fieldName", desc = true, offset = n, limit = m }
---@return table[] results List of matching records (copies of the stored records)
function Collection:find(filter, opts)
    opts = opts or {}
    local results = {}

    for _, rec in ipairs(self._records) do
        if not filter or _matches(rec, filter) then
            results[#results + 1] = _copy(rec)
        end
    end

    if opts.orderBy then
        local field = opts.orderBy
        local desc  = opts.desc == true
        table.sort(results, function(a, b)
            local av, bv = a[field], b[field]
            if av == nil then return false end
            if bv == nil then return true  end
            if desc then return av > bv else return av < bv end
        end)
    end

    if opts.offset or opts.limit then
        local start = (opts.offset or 0) + 1
        local stop  = opts.limit and (start + opts.limit - 1) or #results
        local sliced = {}
        for i = start, math.min(stop, #results) do
            sliced[#sliced + 1] = results[i]
        end
        return sliced
    end

    return results
end

--- Return the first record matching `filter`, or nil.
---@param self Collection
---@param filter? table Filter to match records (e.g. { type = "enemy" })
---@return table|nil result Copy of the first matching record, or nil if no match
function Collection:findOne(filter)
    for _, rec in ipairs(self._records) do
        if not filter or _matches(rec, filter) then
            return _copy(rec)
        end
    end
    return nil
end

--- Return the record with the given `_id`, or nil.
---@param self Collection
---@param id number Record ID
---@return table|nil result Copy of the matching record, or nil if no match
function Collection:findById(id)
    return self:findOne({ _id = id })
end

--- Return the number of records matching `filter` (or total count if nil).
---@param self Collection
---@param filter? table Filter to match records (e.g. { type = "enemy" })
---@return number count Number of matching records
function Collection:count(filter)
    if not filter then return #self._records end
    local n = 0
    for _, rec in ipairs(self._records) do
        if _matches(rec, filter) then n = n + 1 end
    end
    return n
end

-- ─── Persistence ─────────────────────────────────────────────────────────────

--- Write the collection to disk immediately.
---@param self Collection
---@return boolean success True if flush succeeded, false if an error occurred
function Collection:flush()
    if not fs.exists(self._dir) then fs.makeDir(self._dir) end
    local path = fs.combine(self._dir, self._name .. ".dat")
    local file = fs.open(path, "w")
    if not file then
        logger.error("DB: Failed to open '" .. path .. "' for writing")
        return false
    end
    local ok, err = pcall(function()
        file.write(textutils.serialize({ records = self._records, nextId = self._nextId }))
    end)
    file.close()
    if not ok then
        logger.error("DB: Failed to flush '" .. self._name .. "': " .. tostring(err))
    end
    return ok
end

--- Drop the collection from disk and clear in-memory data.
---@param self Collection
function Collection:drop()
    self:clear()
    local path = fs.combine(self._dir, self._name .. ".dat")
    if fs.exists(path) then fs.delete(path) end
    logger.info("DB: Dropped collection '" .. self._name .. "'")
end

--- Disable automatic flushing (useful for bulk ops — call flush() manually after).
---@param self Collection
function Collection:disableAutosave()
    self._autosave = false
end

--- Re-enable automatic flushing.
---@param self Collection
function Collection:enableAutosave()
    self._autosave = true
end

return DatabaseModule
