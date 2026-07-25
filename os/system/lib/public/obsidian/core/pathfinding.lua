-- Obsidian Engine: Pathfinding Module
-- Efficient A* implementation with Min-Heap and LOS smoothing.

---@diagnostic disable: undefined-global

local mathUtils = require("core.math")
local logger = require("core.logger")

local m_floor = math.floor
local m_abs = math.abs
local m_min = math.min

--- The main pathfinding module with the `findPath` function.
---@class PathfindingModule 
---@field MAX_ITERATIONS number Maximum A* node expansions before giving up.  Raise for bigger maps.
local Pathfinding = {}
Pathfinding.MAX_ITERATIONS = 4000

-- ===========================================================================
-- Min-heap (closure style — no :method dispatch, data is an upvalue)
-- ===========================================================================

local function createHeap()
    local data = {}
    local size = 0

    local function push(node, priority)
        size = size + 1
        data[size] = { node = node, priority = priority }
        local i = size
        while i > 1 do
            local p = m_floor(i / 2)
            if data[i].priority < data[p].priority then
                data[i], data[p] = data[p], data[i]
                i = p
            else break end
        end
    end

    local function pop()
        if size == 0 then return nil end
        local root = data[1].node
        data[1]    = data[size]
        data[size] = nil
        size       = size - 1
        local i = 1
        while true do
            local l, r, s = i * 2, i * 2 + 1, i
            if l <= size and data[l].priority < data[s].priority then s = l end
            if r <= size and data[r].priority < data[s].priority then s = r end
            if s ~= i then
                data[i], data[s] = data[s], data[i]
                i = s
            else break end
        end
        return root
    end

    local function isEmpty() return size == 0 end

    return { push = push, pop = pop, isEmpty = isEmpty }
end

-- ===========================================================================
-- Node key helpers
-- ===========================================================================
-- Integer keys avoid string concatenation ("..",",") on every hash access.
-- KEY_W must exceed the widest possible map.  10 000 covers any CC terminal.

local KEY_W = 10000
local function nodeKey(x, y) return y * KEY_W + x end
local function keyToX(k) return k % KEY_W end
local function keyToY(k) return m_floor(k / KEY_W) end

-- ===========================================================================
-- Heuristic
-- ===========================================================================
-- Octile distance — admissible and consistent for 8-directional movement.

local CARD = 1
local DIAG = 1.414
local DIAG_ADJ = DIAG - 2 * CARD

local function heuristic(ax, ay, bx, by)
    local dx = m_abs(ax - bx)
    local dy = m_abs(ay - by)
    return CARD * (dx + dy) + DIAG_ADJ * m_min(dx, dy)
end

-- ===========================================================================
-- Pre-allocated neighbor buffer
-- ===========================================================================
local _nb = {
    { dx =  1, dy =  0, cost = CARD },
    { dx = -1, dy =  0, cost = CARD },
    { dx =  0, dy =  1, cost = CARD },
    { dx =  0, dy = -1, cost = CARD },
    { dx =  1, dy =  1, cost = DIAG },
    { dx = -1, dy =  1, cost = DIAG },
    { dx =  1, dy = -1, cost = DIAG },
    { dx = -1, dy = -1, cost = DIAG },
}

-- ===========================================================================
-- Collision helpers
-- ===========================================================================
local A_PAD = 0

local function isBlocked(scene, nx, ny, cw, ch, ignoreId, mask)
    return scene:isAreaBlocked(
        nx - A_PAD, ny - A_PAD,
        cw + A_PAD * 2, ch + A_PAD * 2,
        ignoreId, mask)
end

-- ===========================================================================
-- LOS smoothing (greedy string-pull)
-- ===========================================================================
local function hasLOS(scene, ax, ay, bx, by, cw, ch, ignoreId, mask)
    return scene:hasLOS(ax, ay, bx, by, cw, ch, ignoreId, mask)
end

local function smoothPath(scene, path, cw, ch, ignoreId, mask)
    if #path <= 2 then return path end
    local out    = { path[1] }
    local anchor = 1
    while anchor < #path do
        local far = anchor + 1
        for i = #path, anchor + 2, -1 do
            local a, b = path[anchor], path[i]
            if hasLOS(scene, a.x, a.y, b.x, b.y, cw, ch, ignoreId, mask) then
                far = i
                break
            end
        end
        table.insert(out, path[far])
        anchor = far
    end
    return out
end

-- ===========================================================================
-- A* search
-- ===========================================================================

--- Find a walkable path from `startPos` to `endPos` on `scene`.
--- @param scene SceneInstance Active scene
--- @param startPos Vec2 World start position
--- @param endPos Vec2 World goal position
--- @param collider table? { w, h } entity size (default {w=1,h=1})
--- @param ignoreId number? Entity ID excluded from collision checks
--- @param layerMask number? Collision layer bitmask
--- @param smooth boolean? Apply LOS waypoint reduction (default true)
--- @param maxIterations number? Max A* expansions before giving up (default Pathfinding.MAX_ITERATIONS)
--- @return Vec2[]|nil  Ordered waypoints start→goal, or nil if unreachable
function Pathfinding.findPath(scene, startPos, endPos, collider, ignoreId, layerMask, smooth, maxIterations)
    if not startPos or not endPos then
        logger.error("[pathfinding] findPath: startPos or endPos is nil")
        return nil
    end

    collider = collider or { w = 1, h = 1 }
    local cw, ch = collider.w, collider.h
    smooth = smooth ~= false

    local sx, sy = m_floor(startPos.x), m_floor(startPos.y)
    local gx, gy = m_floor(endPos.x),   m_floor(endPos.y)

    if sx == gx and sy == gy then
        return { mathUtils.vec2(sx, sy) }
    end

    local openSet  = createHeap()
    local gScore   = {}
    local cameFrom = {}
    local closed   = {}

    local startKey = nodeKey(sx, sy)
    local goalKey  = nodeKey(gx, gy)
    gScore[startKey] = 0
    openSet.push({ x = sx, y = sy }, heuristic(sx, sy, gx, gy))

    local iters   = 0
    local maxIter = maxIterations or Pathfinding.MAX_ITERATIONS

    while not openSet.isEmpty() do
        local cur    = openSet.pop()
        local cx, cy = cur.x, cur.y
        local ck     = nodeKey(cx, cy)

        if not closed[ck] then
            closed[ck] = true
            iters = iters + 1

            if iters > maxIter then
                logger.error("[pathfinding] MAX_ITERATIONS (" .. maxIter .. ") exceeded — map may be too large or goal unreachable")
                return nil
            end

            if cx == gx and cy == gy then
                local raw = {}
                local k   = ck
                while k ~= nil do
                    table.insert(raw, mathUtils.vec2(keyToX(k), keyToY(k)))
                    k = cameFrom[k]
                end
                local lo, hi = 1, #raw
                while lo < hi do
                    raw[lo], raw[hi] = raw[hi], raw[lo]
                    lo = lo + 1; hi = hi - 1
                end
                if smooth then
                    return smoothPath(scene, raw, cw, ch, ignoreId, layerMask)
                end
                return raw
            end

            local cg = gScore[ck]
            for i = 1, 8 do
                local nb = _nb[i]
                local nx = cx + nb.dx
                local ny = cy + nb.dy
                local nk = nodeKey(nx, ny)

                local isGoal = (nk == goalKey)
                if not closed[nk]
                and (isGoal or not isBlocked(scene, nx, ny, cw, ch, ignoreId, layerMask)) then
                    local ok = true
                    if not isGoal and nb.dx ~= 0 and nb.dy ~= 0 then
                        if isBlocked(scene, nx, cy, cw, ch, ignoreId, layerMask)
                        or isBlocked(scene, cx, ny, cw, ch, ignoreId, layerMask) then
                            ok = false
                        end
                    end

                    if ok then
                        local tg = cg + nb.cost
                        if not gScore[nk] or tg < gScore[nk] then
                            gScore[nk]   = tg
                            cameFrom[nk] = ck   -- integer parent key — no table needed
                            openSet.push({ x = nx, y = ny },
                                tg + heuristic(nx, ny, gx, gy))
                        end
                    end
                end
            end
        end
    end
end

return Pathfinding