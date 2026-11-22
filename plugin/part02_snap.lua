-- DDH Park Editor, part02_snap: snapping to other objects (outlines, measuring, same-size pieces, landing).
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local S = PE.S
local V = PE.V
local clamp = PE.clamp
local dot = PE.dot
local follower = PE.follower
local len = PE.len
local round = PE.round
local titleOf = PE.titleOf
local wrap = PE.wrap

-- ---------------------------------------------------------------- snapping to other objects
-- The game says where a placed object is, how it is turned and its size factor, but not how big it is. Its size
-- comes from the box of its model (reskate.entities.bounds of the blueprint a ray finds on it), remembered per
-- item. An object with no known size snaps by its own point only.
local UP = V(0, 1, 0)
local SNAP_REACH = 4     -- metres past the boxes within which sides line up
local SNAP_TOUCH = 0.5   -- metres apart sideways at most for two sides to meet
local SNAP_MAX = 12      -- nearest objects looked at
local SNAP_TURN = math.rad(5)
local LEVEL_NEAR = 1.0   -- metres apart at most for lining up with any but the nearest object
local HEIGHT_FIT = 1.0   -- metres up or down at most that an object goes to take the height of one it meets
-- How strongly it snaps (the Snap tab's slider): 0.2 = only right up against things, 2 = from twice as far.
-- The distances above are for 1; the slider scales them (and the "close enough" distance on screen).
local SNAP_BASE = { reach = SNAP_REACH, touch = SNAP_TOUCH, turn = SNAP_TURN, near = LEVEL_NEAR }
local SNAP_K = 1
function FN.setSnapStrength(k, save)
    k = math.max(0.2, math.min(2, tonumber(k) or 1))
    SNAP_K = k
    SNAP_REACH, SNAP_TOUCH, SNAP_TURN, LEVEL_NEAR = SNAP_BASE.reach * k, SNAP_BASE.touch * k, SNAP_BASE.turn * k, SNAP_BASE.near * k
    S.snapStrength = k
    if save then pcall(reskate.storage.set, "snapStrength", k) end
end
do
    local ok, v = pcall(reskate.storage.get, "snapStrength")
    FN.setSnapStrength(ok and tonumber(v) or 1)
end
-- objects the player lifted on purpose (raised or lowered by hand): they are left at that height; every other
-- object sits on what is under it when it is moved
S.lifted = S.lifted or {}
function FN.markLifted(id)
    id = id or (S.sel and S.sel.id)
    if id then S.lifted[id] = true end
end

local function boxLog(text)
    if S.boxLogged < 40 then S.boxLogged += 1; reskate.log("Quick Drop helper: snap: " .. text) end
end

-- Sizes known before any measuring: the Object Maker's objects (sizes.lua beside this file, measured from their
-- models: item = { wide, high, deep }, standing on its base, centred), then every object this plugin has
-- measured before (kept between launches, so each item is measured once).
S.exact, S.saved, S.exactBox, S.itemShape = {}, {}, {}, {}
do
    local ok, v = pcall(reskate.storage.get, "look")
    if ok and type(v) == "table" then S.lookInvX, S.lookInvY = v.x == true, v.y == true end
end
local function saveLook() pcall(reskate.storage.set, "look", { x = S.lookInvX == true, y = S.lookInvY == true }) end
local function loadSizes()
    local ok, t = pcall(function() return require("sizes") end)
    local n, m = 0, 0
    if ok and type(t) == "table" then
        for item, d in pairs(t) do
            if type(d) == "table" and tonumber(d[1]) and tonumber(d[2]) and tonumber(d[3]) then
                S.itemBox[item] = { V(-d[1] / 2, 0, -d[3] / 2), V(d[1] / 2, d[2], d[3] / 2) }
                S.exactBox[item] = S.itemBox[item]
                S.exact[item] = true
                -- its outline seen from above: x, z pairs
                local ol = d[4]
                if type(ol) == "table" and #ol >= 6 then
                    local pts = {}
                    for i = 1, #ol - 1, 2 do pts[#pts + 1] = V(ol[i], 0, ol[i + 1]) end
                    S.itemShape[item] = pts
                end
                n += 1
            end
        end
    end
    pcall(reskate.storage.set, "sizes", nil)   -- older, coarser measurements: measured again
    local ok2, st = pcall(reskate.storage.get, "sizes2")
    if ok2 and type(st) == "table" then
        for item, d in pairs(st) do
            if not S.exact[item] and type(d) == "table" and #d == 6 then
                S.itemBox[item] = { V(d[1], d[2], d[3]), V(d[4], d[5], d[6]) }
                S.saved[item] = d
                m += 1
            end
        end
    end
    reskate.log(string.format("Quick Drop helper: snap: %d sizes from the Object Maker, %d measured before", n, m))
end
do
    local ok, err = pcall(loadSizes)
    if not ok then reskate.log("Quick Drop helper: snap: sizes not loaded: " .. tostring(err)) end
end
local function r3(x) return math.floor(x * 1000 + 0.5) / 1000 end
local function saveSize(item, a, b)
    if S.exact[item] then return end
    S.saved[item] = { r3(a.x), r3(a.y), r3(a.z), r3(b.x), r3(b.y), r3(b.z) }
    local ok, err = pcall(reskate.storage.set, "sizes2", S.saved)
    if not ok then boxLog("size not kept: " .. tostring(err)) end
end
local function forgetSize(item)
    if S.exact[item] then return false end
    S.saved[item] = nil
    pcall(reskate.storage.set, "sizes2", S.saved)
    S.itemBox[item], S.boxTries[item], S.boxNext[item] = S.exactBox[item], nil, nil
    if S.measure and S.measure.o.item == item then S.measure = nil end
    return true
end

-- The exact way for objects of the game and other mods: their model, found among the game's loaded models by
-- the item's name, and the box the game gives for that model.
S.bpNames, S.meshBox = nil, {}
local function modelNames()
    if S.bpNames then return S.bpNames end
    S.bpNames = {}
    if not (reskate.entities and reskate.entities.blueprints) then return S.bpNames end
    local t0, seen, own = os.clock(), {}, {}
    for _, prefix in ipairs({ "Items/", "" }) do
        local ok, list = pcall(reskate.entities.blueprints, prefix ~= "" and prefix or nil, true)
        if ok and type(list) == "table" then
            for _, nm in ipairs(list) do
                if not seen[nm] then
                    seen[nm] = true
                    S.bpNames[#S.bpNames + 1] = nm
                    if #own < 8 and string.find(string.lower(nm), "own_", 1, true) then own[#own + 1] = nm end
                end
            end
        end
    end
    boxLog(string.format("%d models loaded (%.0f ms)%s", #S.bpNames, (os.clock() - t0) * 1000,
        #own > 0 and (", such as " .. table.concat(own, " | ")) or ""))
    return S.bpNames
end
-- the model (blueprint) an item is made from, found by its name; false when none is (remembered per map)
S.modelOf = {}
function FN.modelFor(item)
    local m = S.modelOf[item]
    if m ~= nil then return m end
    local key = string.lower(item)
    local short = string.gsub(key, "_+%d+$", "")
    short = string.gsub(short, "_+$", "")
    -- its own name first; else its name without the number, when only one model has it
    local best, alt, alts = nil, nil, 0
    for _, nm in ipairs(modelNames()) do
        local l = string.lower(nm)
        if string.find(l, key, 1, true) then best = nm break end
        if #short > 8 and string.find(l, short, 1, true) then alt = nm; alts += 1 end
    end
    if not best and alts == 1 then best = alt end
    -- (an empty list means the models weren't readable yet: not remembered, so it is looked for again)
    if best or #modelNames() > 0 then S.modelOf[item] = best or false end
    return best or false
end
local function tryNamed(o)
    local best = FN.modelFor(o.item)
    if not best then return false end
    local ok, a, b = pcall(reskate.entities.bounds, best)
    if ok and type(a) == "table" and a.min then a, b = a.min, a.max end
    if not (ok and a and b) then return false end
    S.itemBox[o.item] = { a, b }
    S.meshBox[o.item] = true
    S.exact[o.item] = true
    boxLog(string.format("%s: model %s, %.4f x %.4f x %.4f m", titleOf(o.item), best, b.x - a.x, b.y - a.y, b.z - a.z))
    return true
end

-- the quick way: the box of the model the game names for it (the game names none for Quick Drop objects)
local function tryBlueprint(o)
    local p = o.position
    local ok, hit = pcall(reskate.world.pick, p + V(0, 6, 0), p - V(0, 1, 0))
    local ho = ok and type(hit) == "table" and hit.object or nil
    if not (ho and ho.position and ho.blueprint and len(ho.position - p) < 0.5) then return false end
    local ok2, a, b = false, nil, nil
    if reskate.entities then ok2, a, b = pcall(reskate.entities.bounds, ho.blueprint) end
    if ok2 and type(a) == "table" and a.min then a, b = a.min, a.max end
    if not (ok2 and a and b) then return false end
    S.itemBox[o.item] = { a, b }
    S.exact[o.item] = true
    boxLog(string.format("%s is %.4f x %.4f x %.4f m", titleOf(o.item), b.x - a.x, b.y - a.y, b.z - a.z))
    return true
end

-- Measuring an object the game gives no size for: rays straight down onto it. First a coarse grid to find
-- roughly where it is, then each of its four sides is closed in on to a few millimetres. Runs a few rays a
-- tick (the game allows 64), as a coroutine that waits for the next tick when its share is used.
local RAYS_A_TICK = 32
local function measureJob(o, others)
    local p, h = o.position, o.heading or 0
    local ax, az = V(math.cos(h), 0, -math.sin(h)), V(math.sin(h), 0, math.cos(h))
    local top, rays = 20, 0
    local ylo, yhi = math.huge, -math.huge
    -- the height where a ray down at (x, z), in the object's own directions, meets this object; nil when it
    -- meets something else or nothing
    local function ray(x, z)
        if S.mRays >= RAYS_A_TICK or os.clock() - S.mT0 > 0.0025 then coroutine.yield() end
        S.mRays += 1
        rays += 1
        local q = p + ax * x + az * z
        local ok, hit = pcall(reskate.world.pick, q + UP * top, q - UP * 3)
        if not ok then   -- the tick's rays were used up by something else: once more next tick
            coroutine.yield()
            S.mRays += 1
            hit = reskate.world.pick(q + UP * top, q - UP * 3)
        end
        local ho = type(hit) == "table" and hit.object or nil
        if not (ho and ho.position and hit.position) then return nil end
        local d = len(ho.position - p)
        if d >= 0.5 then return nil end
        for _, q2 in ipairs(others) do
            if len(ho.position - q2) < d then return nil end
        end
        local y = hit.position.y - p.y
        if y < ylo then ylo = y end
        if y > yhi then yhi = y end
        return y
    end
    -- the coarse grid: 13 x 13 rays about its point; wider while it reaches the rim
    local step, hits = 0.5, {}
    local function coarse()
        hits = {}
        for i = -6, 6 do
            for j = -6, 6 do
                if ray(i * step, j * step) then hits[#hits + 1] = { i, j } end
            end
        end
        return #hits
    end
    local found = false
    for _, from in ipairs({ 20, 8, 4 }) do   -- from well above; from lower when a roof is in the way
        top = from
        if coarse() > 0 then found = true break end
    end
    if not found then return nil, "no ray from above reached it" end
    while step < 8 do
        local rim = false
        for _, ht in ipairs(hits) do
            if math.abs(ht[1]) == 6 or math.abs(ht[2]) == 6 then rim = true break end
        end
        if not rim then break end
        step *= 2
        if coarse() == 0 then return nil, "lost it while measuring" end
    end
    local imin, imax, jmin, jmax = math.huge, -math.huge, math.huge, -math.huge
    for _, ht in ipairs(hits) do
        imin, imax = math.min(imin, ht[1]), math.max(imax, ht[1])
        jmin, jmax = math.min(jmin, ht[2]), math.max(jmax, ht[2])
    end
    -- where to look along a side: first where the grid met it on that line, then evenly across
    local function along(lo, hi, index, value, other)
        local out = {}
        for _, ht in ipairs(hits) do
            if ht[index] == value then out[#out + 1] = ht[other] * step end
        end
        for k = 0, 23 do out[#out + 1] = lo + (hi - lo) * k / 23 end
        return out
    end
    -- closing in on one side: a is on the object, a step further out is (most likely) off it
    local function side(a, sign, list, isX)
        local function test(v)
            for _, w in ipairs(list) do
                local y
                if isX then y = ray(v, w) else y = ray(w, v) end
                if y then return true end
            end
            return false
        end
        local b = a + sign * step
        local more = 0
        while more < 4 and test(b) do
            a, b = b, b + sign * step
            more += 1
        end
        for _ = 1, 20 do
            if math.abs(b - a) <= 0.0005 then break end
            local m = (a + b) / 2
            if test(m) then a = m else b = m end
        end
        return (a + b) / 2
    end
    local zl, zh = jmin * step - step, jmax * step + step
    local x1 = side(imax * step, 1, along(zl, zh, 1, imax, 2), true)
    local x0 = side(imin * step, -1, along(zl, zh, 1, imin, 2), true)
    local z1 = side(jmax * step, 1, along(x0, x1, 2, jmax, 1), false)
    local z0 = side(jmin * step, -1, along(x0, x1, 2, jmin, 1), false)
    -- a last look across the top for its height
    for i = 0, 6 do
        for j = 0, 6 do
            ray(x0 + (x1 - x0) * (i + 0.5) / 7, z0 + (z1 - z0) * (j + 0.5) / 7)
        end
    end
    local sc = o.scale or 1
    if sc <= 0 then sc = 1 end
    return V(x0, math.min(0, ylo), z0) * (1 / sc), V(x1, math.max(yhi, 0.02), z1) * (1 / sc), rays
end

local function measureFailed(item, why)
    local tries = (S.boxTries[item] or 0) + 1
    S.boxTries[item] = tries
    if tries >= 2 then
        S.itemBox[item] = false
        boxLog(string.format("no size for %s (%s): it snaps by its own point", titleOf(item), tostring(why)))
    else
        S.boxNext[item] = S.clock + 2000
    end
end

local function stillThere(o, list)
    local cur = list[o.id]
    return cur ~= nil and len(cur.position - o.position) < 1e-3 and math.abs(wrap((cur.heading or 0) - (o.heading or 0))) < 1e-4
        and math.abs((cur.scale or 1) - (o.scale or 1)) < 1e-4
end

-- one tick's worth of the measuring under way
local function stepMeasure()
    local m = S.measure
    local o = m.o
    local mine = S.sel and o.id == S.sel.id
    -- it has to stand still while it is measured: otherwise later, when it does
    if not stillThere(o, S.known) or (mine and ((S.drag and S.drag.moved) or S.padMoving or S.dirty)) then
        S.measure = nil
        S.boxNext[o.item] = S.clock + 800
        return
    end
    S.mRays, S.mT0 = 0, os.clock()
    local ok, lo, hi, rays = coroutine.resume(m.co, o, m.others)
    if not ok then
        S.measure = nil
        measureFailed(o.item, lo)
    elseif coroutine.status(m.co) == "dead" then
        S.measure = nil
        if not lo then measureFailed(o.item, hi) return end
        local now = {}
        for _, q in ipairs(FN.objectsNow()) do now[q.id] = q end
        if not stillThere(o, now) then S.boxNext[o.item] = S.clock + 800 return end
        S.itemBox[o.item] = { lo, hi }
        saveSize(o.item, lo, hi)
        boxLog(string.format("%s measured: %.4f x %.4f x %.4f m (%d rays)", titleOf(o.item), hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, rays or 0))
    end
end

-- while the editor is open: the size of one more item near the picked object, nearest first
local function learnNear()
    if not (S.osnap and S.target and S.known) then S.measure = nil return end
    if S.measure then stepMeasure() return end
    if S.clock - (S.learnAt or -1e9) < 150 then return end
    S.learnAt = S.clock
    local moving = (S.drag and S.drag.moved) or S.padMoving or S.dirty
    local best, bd = nil, 30
    for _, o in ipairs(FN.nearObjects(S.target.pos, 30)) do
        local tl = S.tilt[o.id]
        if S.itemBox[o.item] == nil and S.clock >= (S.boxNext[o.item] or 0) and not (tl and (math.abs(tl.x) > 1e-4 or math.abs(tl.z) > 1e-4)) then
            local d = len(o.position - S.target.pos)
            local mine = S.sel and o.id == S.sel.id
            if d < bd and not (mine and (moving or d > 0.05)) then best, bd = o, d end
        end
    end
    if not best then return end
    if tryNamed(best) then return end
    if tryBlueprint(best) then return end
    local others = {}
    for id, q in pairs(S.known) do
        if id ~= best.id and len(q.position - best.position) < 1 then others[#others + 1] = q.position end
    end
    S.measure = { o = best, co = coroutine.create(measureJob), others = others }
    S.boxNext[best.item] = S.clock + 3000
end

-- an object's box in the world: its point, its two level directions (up is the third), and how far the box
-- reaches along each from the point
local function worldBox(item, pos, heading, scale)
    local b = S.itemBox[item]
    local lo, hi = V(0, 0, 0), V(0, 0, 0)
    if b then lo, hi = b[1] * scale, b[2] * scale end
    local ch, sh = math.cos(heading), math.sin(heading)
    return { p = pos, ax = V(ch, 0, -sh), az = V(sh, 0, ch), lo = lo, hi = hi, sized = b and true or false }
end

local function cornersOf(bx)
    if not bx.sized then return { bx.p } end
    local c = {}
    for i = 0, 7 do
        local x = (i % 2 == 0) and bx.lo.x or bx.hi.x
        local y = (math.floor(i / 2) % 2 == 0) and bx.lo.y or bx.hi.y
        local z = (i < 4) and bx.lo.z or bx.hi.z
        c[i + 1] = bx.p + bx.ax * x + UP * y + bx.az * z
    end
    return c
end

-- turns with tilt (see tilting, further on)
S.tilt, S.tiltHeld, S.tiltWhy, S.tiltAt, S.tiltSrc = {}, {}, nil, {}, {}
S.held = S.held or {}
local MAX_HELD = 32
local function qmul(a, b)
    return { a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
             a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
             a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
             a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3] }
end
local function qconj(q) return { -q[1], -q[2], -q[3], q[4] } end
local function qrot(q, v)
    local r = qmul(qmul(q, { v.x, v.y, v.z, 0 }), qconj(q))
    return V(r[1], r[2], r[3])
end
local function qaxis(ax, a) local s2 = math.sin(a / 2); return { ax.x * s2, ax.y * s2, ax.z * s2, math.cos(a / 2) } end
-- the whole turn of an object: its turn about up, then its tilt about its own x and z
local function fullTurn(heading, tl)
    local q = qaxis(V(0, 1, 0), heading)
    if tl then q = qmul(q, qmul(qaxis(V(1, 0, 0), tl.x), qaxis(V(0, 0, 1), tl.z))) end
    return q
end
local function tilted(id)
    local tl = id and S.tilt[id]
    return tl ~= nil and (math.abs(tl.x) > 1e-4 or math.abs(tl.z) > 1e-4)
end
-- a point of an object turned with its tilt, about the object's point
local function tiltPoint(p, heading, tl, q)
    local rel = qmul(fullTurn(heading, tl), qconj(qaxis(V(0, 1, 0), heading)))
    return p + qrot(rel, q - p)
end

-- Outlines: what an object fills seen from above (its model's real outline for the Object Maker's objects, else
-- its box), standing from its base to its top. Snapping goes side to side along these outlines.
local MIN_EDGE = 0.05
local function localOutline(item)
    local sh = S.itemShape[item]
    if sh then return sh end
    local b = S.itemBox[item]
    if not b then return nil end
    local lo, hi = b[1], b[2]
    return { V(lo.x, 0, lo.z), V(hi.x, 0, lo.z), V(hi.x, 0, hi.z), V(lo.x, 0, hi.z) }
end
-- the outline in the world: its corners (at the object's height), and its sides, longest first, each with its
-- direction e and outward direction n
local function worldShape(item, pos, heading, scale)
    local bx = worldBox(item, pos, heading, scale)
    bx.ylo, bx.yhi = pos.y + bx.lo.y, pos.y + bx.hi.y
    -- (which object, so its outline can be drawn from its model's real edges)
    bx.item, bx.scale = item, scale
    bx.pts, bx.edges = {}, {}
    local lp = bx.sized and localOutline(item) or nil
    if not lp then return bx end
    local pts = bx.pts
    for i, q in ipairs(lp) do pts[i] = pos + bx.ax * (q.x * scale) + bx.az * (q.z * scale) end
    local n = #pts
    for i = 1, n do
        local a, b = pts[i], pts[i % n + 1]
        local e = b - a
        local l = len(e)
        if l >= MIN_EDGE then
            local eu = e * (1 / l)
            -- which way its outside faces, as a turn (exact: from the outline's own numbers and the object's turn)
            local la, lb = lp[i], lp[i % n + 1]
            local ang = wrap(heading + math.atan2(lb.z - la.z, -(lb.x - la.x)))
            bx.edges[#bx.edges + 1] = { a = a, b = b, e = eu, n = V(eu.z, 0, -eu.x), len = l, ang = ang,
                x0 = math.min(a.x, b.x), x1 = math.max(a.x, b.x), z0 = math.min(a.z, b.z), z1 = math.max(a.z, b.z) }
        end
    end
    table.sort(bx.edges, function(x, y) return x.len > y.len end)
    while #bx.edges > 40 do table.remove(bx.edges) end
    local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    for _, q in ipairs(pts) do x0 = math.min(x0, q.x); x1 = math.max(x1, q.x); z0 = math.min(z0, q.z); z1 = math.max(z1, q.z) end
    bx.x0, bx.x1, bx.z0, bx.z1 = x0, x1, z0, z1
    return bx
end
-- how far apart two flat boxes (x0, x1, z0, z1) are
local function apart(a, b)
    return math.max(0, a.x0 - b.x1, b.x0 - a.x1, a.z0 - b.z1, b.z0 - a.z1)
end
-- a placed object's outline, kept while it stays put
S.shapeCache = {}
function FN.placedShape(o)
    local c = S.shapeCache[o.id]
    local box = S.itemBox[o.item]
    local h, sc = o.heading or 0, o.scale or 1
    if c and c.box == box and c.h == h and c.sc == sc and c.pos == o.position then return c.shape end
    local sh = worldShape(o.item, o.position, h, sc)
    S.shapeCache[o.id] = { box = box, h = h, sc = sc, pos = o.position, shape = sh }
    return sh
end
FN.COS1 = math.cos(math.rad(1))

-- An object as it stands, tilt and all: its corners and its flat faces (each side of its outline, its top and its
-- bottom), each face with a corner o, its outward direction n and two directions u, v across it (ulen, vlen long).
function FN.faceBox(f)
    local c = { f.o, f.o + f.u * f.ulen, f.o + f.v * f.vlen, f.o + f.u * f.ulen + f.v * f.vlen }
    f.c4 = c
    f.x0, f.x1, f.y0, f.y1, f.z0, f.z1 = math.huge, -math.huge, math.huge, -math.huge, math.huge, -math.huge
    for _, q in ipairs(c) do
        f.x0 = math.min(f.x0, q.x); f.x1 = math.max(f.x1, q.x); f.y0 = math.min(f.y0, q.y); f.y1 = math.max(f.y1, q.y)
        f.z0 = math.min(f.z0, q.z); f.z1 = math.max(f.z1, q.z)
    end
    return f
end
local function apart3(a, b)
    return math.max(0, a.x0 - b.x1, b.x0 - a.x1, a.y0 - b.y1, b.y0 - a.y1, a.z0 - b.z1, b.z0 - a.z1)
end
local function worldSolid(item, pos, heading, scale, tl)
    local sh = worldShape(item, pos, heading, scale)
    local so = { sized = sh.sized, shape = sh, p = pos, lo = sh.lo, hi = sh.hi, ax = sh.ax, az = sh.az, faces = {}, corners = {}, heading = heading, tl = tl }
    if not sh.sized or #sh.pts < 3 then return so end
    local isT = tl ~= nil and (math.abs(tl.x) > 1e-4 or math.abs(tl.z) > 1e-4)
    local R = isT and qmul(fullTurn(heading, tl), qconj(qaxis(V(0, 1, 0), heading))) or nil
    local function rv(v) return R and qrot(R, v) or v end
    local function xf(v) return R and (pos + qrot(R, v - pos)) or v end
    so.xf, so.tilted = isT and xf or nil, isT
    local base, top = sh.ylo - pos.y, sh.yhi - pos.y
    local up = rv(UP)
    for _, q in ipairs(sh.pts) do
        so.corners[#so.corners + 1] = xf(q + UP * base)
        so.corners[#so.corners + 1] = xf(q + UP * top)
    end
    for i, E in ipairs(sh.edges) do
        so.faces[#so.faces + 1] = FN.faceBox({ o = xf(E.a + UP * base), n = rv(E.n), u = rv(E.e), v = up, ulen = E.len, vlen = top - base, long = i <= 8, side = true })
    end
    -- top and bottom: the outline's extent along the object's own x and z
    local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    for _, q in ipairs(sh.pts) do
        local a, b = dot(q - pos, sh.ax), dot(q - pos, sh.az)
        x0 = math.min(x0, a); x1 = math.max(x1, a); z0 = math.min(z0, b); z1 = math.max(z1, b)
    end
    local ax, az = rv(sh.ax), rv(sh.az)
    so.faces[#so.faces + 1] = FN.faceBox({ o = xf(pos + UP * top + sh.ax * x0 + sh.az * z0), n = up, u = ax, v = az, ulen = x1 - x0, vlen = z1 - z0, long = true })
    so.faces[#so.faces + 1] = FN.faceBox({ o = xf(pos + UP * base + sh.ax * x0 + sh.az * z0), n = up * -1, u = ax, v = az, ulen = x1 - x0, vlen = z1 - z0, long = true })
    so.x0, so.x1, so.y0, so.y1, so.z0, so.z1 = math.huge, -math.huge, math.huge, -math.huge, math.huge, -math.huge
    for _, q in ipairs(so.corners) do
        so.x0 = math.min(so.x0, q.x); so.x1 = math.max(so.x1, q.x); so.y0 = math.min(so.y0, q.y); so.y1 = math.max(so.y1, q.y)
        so.z0 = math.min(so.z0, q.z); so.z1 = math.max(so.z1, q.z)
    end
    return so
end
local function tiltOf(id)
    local tl = S.tilt[id]
    if tl and (math.abs(tl.x) > 1e-4 or math.abs(tl.z) > 1e-4) then return tl end
    return nil
end
-- a placed object as it stands, kept while it stays put
S.solidCache = {}
local function placedSolid(o)
    local c = S.solidCache[o.id]
    local box = S.itemBox[o.item]
    local h, sc = o.heading or 0, o.scale or 1
    local tl = tiltOf(o.id)
    local tx, tz = tl and tl.x or 0, tl and tl.z or 0
    if c and c.box == box and c.h == h and c.sc == sc and c.pos == o.position and c.tx == tx and c.tz == tz then return c.solid end
    local so = worldSolid(o.item, o.position, h, sc, tl)
    S.solidCache[o.id] = { box = box, h = h, sc = sc, pos = o.position, tx = tx, tz = tz, solid = so }
    return so
end

-- Big parks: the objects by where they are, in a grid of 4 m squares (each object in every square its box, and
-- a little more, reaches), so snapping looks only at the objects near it, not the whole park each tick. Built again
-- whenever the list of objects is (twice a second).
local CELL = 4
local grid = { known = false }
local function buildGrid()
    local cells = {}
    grid = { known = S.known, cells = cells, stamp = 0, seen = {} }
    for id, o in pairs(S.known or {}) do
        local b = S.itemBox[o.item]
        local r = (b and len((b[2] - b[1]) * (o.scale or 1)) or 1) + 0.5
        local p = o.position
        for i = math.floor((p.x - r) / CELL), math.floor((p.x + r) / CELL) do
            for k = math.floor((p.z - r) / CELL), math.floor((p.z + r) / CELL) do
                local key = i * 1000003 + k
                local c = cells[key]
                if not c then c = {}; cells[key] = c end
                c[#c + 1] = o
            end
        end
    end
end
-- the objects that may be within r metres of pos (their boxes; some further off too: the caller still checks)
function FN.nearObjects(pos, r)
    if grid.known ~= S.known then buildGrid() end
    local out = {}
    if not S.known then return out end
    grid.stamp += 1
    local st, seen, cells = grid.stamp, grid.seen, grid.cells
    for i = math.floor((pos.x - r) / CELL), math.floor((pos.x + r) / CELL) do
        for k = math.floor((pos.z - r) / CELL), math.floor((pos.z + r) / CELL) do
            local c = cells[i * 1000003 + k]
            if c then
                for _, o in ipairs(c) do
                    if seen[o.id] ~= st then seen[o.id] = st; out[#out + 1] = o end
                end
            end
        end
    end
    return out
end
local nearObjects = FN.nearObjects

-- Objects the picked one stands inside of are never snapped to, until it has been moved clear of them: a copy just
-- made of it (which the game puts there a moment later, where it was), or the one it was copied from, or a stack
-- of the same object. Otherwise it snaps back onto itself.
S.snapIgnore = {}
-- the picked object (where it is going) and o overlap: their boxes as they stand, a little shrunk
-- (the picked object's box where it is going, worked out once for each place it goes to: this is asked many
-- times a tick while snapping, and working the box out each time was too slow for the game's time limit)
local function heldSolid()
    local t = S.target
    local tl = tiltOf(S.sel.id)
    local c = S.heldSolidC
    if c and c.id == S.sel.id and c.pos == t.pos and c.h == t.heading and c.sc == t.scale and c.tl == tl then return c.ok, c.so end
    local ok, so = pcall(worldSolid, S.sel.item, t.pos, t.heading, t.scale, tl)
    S.heldSolidC = { id = S.sel.id, pos = t.pos, h = t.heading, sc = t.scale, tl = tl, ok = ok, so = so }
    return ok, so
end
-- two turned boxes overlap? (their footprints as turned rectangles, tested side by side, and their heights; each
-- shrunk by m). Boxes square to the world were compared before, and a turned wall's square box reaches far past
-- the wall: a copy put flush beside its original still "overlapped" it, so it was never snapped to.
local function footOf(item, pos, heading, scale, m)
    local b = S.itemBox[item]
    if not b then return nil end
    local lo, hi = b[1] * scale, b[2] * scale
    local ax, az = V(math.cos(heading), 0, -math.sin(heading)), V(math.sin(heading), 0, math.cos(heading))
    local x0, x1, z0, z1 = lo.x + m, hi.x - m, lo.z + m, hi.z - m
    if x0 > x1 then x0, x1 = (lo.x + hi.x) / 2, (lo.x + hi.x) / 2 end
    if z0 > z1 then z0, z1 = (lo.z + hi.z) / 2, (lo.z + hi.z) / 2 end
    return { pts = { pos + ax * x0 + az * z0, pos + ax * x1 + az * z0, pos + ax * x1 + az * z1, pos + ax * x0 + az * z1 },
        axes = { ax, az }, y0 = pos.y + lo.y + m, y1 = pos.y + hi.y - m }
end
local function footsOverlap(A, B)
    if A.y0 >= B.y1 or B.y0 >= A.y1 then return false end
    for _, F in ipairs({ A, B }) do
        for _, n in ipairs(F.axes) do
            local a0, a1, b0, b1 = math.huge, -math.huge, math.huge, -math.huge
            for _, q in ipairs(A.pts) do local d = q.x * n.x + q.z * n.z; a0 = math.min(a0, d); a1 = math.max(a1, d) end
            for _, q in ipairs(B.pts) do local d = q.x * n.x + q.z * n.z; b0 = math.min(b0, d); b1 = math.max(b1, d) end
            if a1 <= b0 or b1 <= a0 then return false end
        end
    end
    return true
end
function FN.overlapsHeld(o)
    local t = S.target
    if not (t and S.sel and o) then return false end
    if not tiltOf(S.sel.id) and not tiltOf(o.id) and S.itemBox[S.sel.item] and S.itemBox[o.item] then
        local A = footOf(S.sel.item, t.pos, t.heading or 0, t.scale or 1, 0.02)
        local B = footOf(o.item, o.position, o.heading or 0, o.scale or 1, 0.02)
        if A and B then return footsOverlap(A, B) end
    end
    local okA, a = heldSolid()
    local okB, b = pcall(placedSolid, o)
    if okA and okB and a and b and a.x0 and b.x0 and a.x0 < math.huge and b.x0 < math.huge then
        local m = 0.02
        return a.x0 < b.x1 - m and b.x0 < a.x1 - m and a.y0 < b.y1 - m and b.y0 < a.y1 - m and a.z0 < b.z1 - m and b.z0 < a.z1 - m
    end
    -- (no size known for one of them: the same spot)
    return len(o.position - t.pos) < 0.05
end
-- every object the picked one is inside of right now: not snapped to until it is clear of them
function FN.ignoreOverlapping()
    if not (S.sel and S.known) then return end
    for id, o in pairs(S.known) do
        -- (only the same kind of object: a copy, the one it was copied from, a stack of it. Anything else it
        -- pokes into, like a ledge set into a platform, is still snapped to)
        if id ~= S.sel.id and o.item == S.sel.item and FN.overlapsHeld(o) then S.snapIgnore[id] = true end
    end
end

-- Moves pos so the picked object's faces meet or line up with the faces of the objects near it (tilted or not).
-- allow(direction, metres) answers how such a move may be made for the handle in use: the move as a vector and
-- the direction it goes along, or nil when that handle cannot go that way.
-- Returns the place, and what it snapped to (a list of { o, nb, kind }) or nil.
-- snapping to: "auto" (the nearest), one chosen object (L3 tap / Tab cycles), or "off"
S.snapPick = nil
function FN.snapAllowed(id)
    if follower(id) then return false end
    if S.snapIgnore[id] then
        local o = S.known and S.known[id]
        if o and FN.overlapsHeld(o) then return false end
        S.snapIgnore[id] = nil
    end
    local sp = S.snapPick
    if sp == nil then return true end
    if sp == "off" then return false end
    return id == sp
end
local function objSnap(pos, heading, scale, allow, tl)
    if not (S.osnap and S.sel and S.known) then return pos, nil end
    if S.snapPick == "off" then return pos, nil end
    local thr = clamp(S.cam.dist * 0.03, 0.12, 0.5) * SNAP_K
    local me = worldSolid(S.sel.item, pos, heading, scale, tl)
    local mc = cornersOf(me)
    local reach = SNAP_REACH + len(me.hi - me.lo)
    local near = {}
    for _, o in ipairs(nearObjects(pos, reach)) do
        local id = o.id
        if id ~= S.sel.id and FN.snapAllowed(id) then
            local d = len(o.position - pos)
            local b = S.itemBox[o.item]
            if d < reach + (b and len((b[2] - b[1]) * (o.scale or 1)) or 0) then
                -- how far apart the two really are (their boxes as they stand), and the one it is snapped to
                -- counts as a little closer so it does not flick between two
                local nb = placedSolid(o)
                local gap = (me.x0 and nb.x0) and apart3(me, nb) or d
                if id == S.snapLock then gap -= math.max(0.05, thr * 0.5) end
                near[#near + 1] = { o = o, d = d, gap = gap, nb = nb }
            end
        end
    end
    -- the closest first
    table.sort(near, function(a, b)
        if math.abs(a.gap - b.gap) > 1e-4 then return a.gap < b.gap end
        return a.d < b.d
    end)
    local cands = {}
    local reachT = thr + SNAP_TOUCH
    for i = 1, math.min(#near, SNAP_MAX) do
        local o = near[i].o
        local nb = near[i].nb
        local farOff = i > 1 and near[i].gap > LEVEL_NEAR
        local function add(axis, m, kind, rank, n, corner, fit, tol)
            if math.abs(m) > (tol or thr) then return end
            -- in a crowd: lining up only with the nearest object, or ones within a metre
            if kind == "level" and farOff then return end
            local mv, dir = allow(axis, m)
            if mv then cands[#cands + 1] = { mv = mv, dir = dir, cost = len(mv), rank = rank, o = o, nb = nb, kind = kind, n = n, corner = corner, near = i, fit = fit } end
        end
        if #me.faces > 0 and #nb.faces > 0 then
            -- faces near enough to matter (lining up from further off: only the long ones)
            local mine, theirs = {}, {}
            for _, F in ipairs(me.faces) do if apart3(F, nb) <= (F.long and SNAP_REACH or reachT) then mine[#mine + 1] = F end end
            for _, E in ipairs(nb.faces) do if apart3(E, me) <= (E.long and SNAP_REACH or reachT) then theirs[#theirs + 1] = E end end
            for _, F in ipairs(mine) do
                for _, E in ipairs(theirs) do
                    local ap = apart3(F, E)
                    if ap <= reachT or (F.long and E.long and ap <= SNAP_REACH) then
                        local c = dot(F.n, E.n)
                        if c < -FN.COS1 or c > FN.COS1 then
                            local dline = dot(F.o - E.o, E.n)   -- how far my face is out past theirs
                            if math.abs(dline) <= thr then
                                -- where my face lies across theirs
                                local u0, u1, v0, v1 = math.huge, -math.huge, math.huge, -math.huge
                                for _, q in ipairs(F.c4) do
                                    local du, dv = dot(q - E.o, E.u), dot(q - E.o, E.v)
                                    u0 = math.min(u0, du); u1 = math.max(u1, du); v0 = math.min(v0, dv); v1 = math.max(v1, dv)
                                end
                                local ovu = math.min(u1, E.ulen) - math.max(u0, 0)
                                local ovv = math.min(v1, E.vlen) - math.max(v0, 0)
                                -- (two sides that are not at the same height at all, like one sitting on top of the
                                -- other, do not meet: else a stacked object is pulled down beside it)
                                local stacked = F.side and E.side and ovv <= 0.02
                                if c < 0 and not stacked then
                                    -- facing each other: they meet
                                    local g = math.max(0, -ovu, -ovv)
                                    if g <= SNAP_TOUCH then
                                        -- (side to side: how to take its height, bottoms level or tops level)
                                        local fit = (F.side and E.side) and { v = E.v, bottom = 0 - v0, top = E.vlen - v1 } or nil
                                        add(E.n, -dline, "touch", (ovu > 0.02 and ovv > 0.02) and 0 or 2, E.n * -1, nil, fit)
                                        -- and their edges line up, both ways across the face
                                        if ovu > -SNAP_TOUCH and ovv > -SNAP_TOUCH then
                                            add(E.u, 0 - u0, "level", 1); add(E.u, E.ulen - u1, "level", 1)
                                            add(E.u, 0 - u1, "level", 1); add(E.u, E.ulen - u0, "level", 1)
                                            add(E.v, 0 - v0, "level", 1); add(E.v, E.vlen - v1, "level", 1)
                                        end
                                        -- the same size face to face (like Skate 3's pieces): edges exactly together, from
                                        -- further off (up to half the face), so the two join without a step or a gap
                                        if math.abs((u1 - u0) - E.ulen) < 0.02 then
                                            add(E.u, 0 - u0, "match", 0.5, nil, nil, nil, math.max(thr, math.min(E.ulen * 0.5, 0.75)))
                                        end
                                        if not (F.side and E.side) and math.abs((v1 - v0) - E.vlen) < 0.02 then
                                            add(E.v, 0 - v0, "match", 0.5, nil, nil, nil, math.max(thr, math.min(E.vlen * 0.5, 0.75)))
                                        end
                                    end
                                elseif (c > 0 or not stacked) and math.max(0, -ovu, -ovv) <= SNAP_REACH then
                                    -- facing the same way: lined up flush
                                    add(E.n, -dline, "level", 1)
                                end
                            end
                        end
                    end
                end
            end
            -- a corner against a face (of the other one, or of mine), when the two are turned differently
            local function cornerOnFace(pts, E, sign)
                local best, inside = math.huge, false
                local m = thr + 0.03
                local x0, x1, y0, y1, z0, z1 = E.x0 - m, E.x1 + m, E.y0 - m, E.y1 + m, E.z0 - m, E.z1 + m
                for _, q in ipairs(pts) do
                  if q.x >= x0 and q.x <= x1 and q.y >= y0 and q.y <= y1 and q.z >= z0 and q.z <= z1 then
                    local du, dv = dot(q - E.o, E.u), dot(q - E.o, E.v)
                    -- (only a corner that lands on the face itself)
                    local vin = E.side and (dv > 0.02 and dv < E.vlen - 0.02) or (dv > -0.02 and dv < E.vlen + 0.02)
                    if du > -0.02 and du < E.ulen + 0.02 and vin then
                        local dd = dot(q - E.o, E.n)
                        if dd < best then best, inside = dd, du > 0.01 and du < E.ulen - 0.01 and dv > 0.01 and dv < E.vlen - 0.01 end
                    end
                  end
                end
                if best < math.huge and math.abs(best) <= thr then
                    -- my corner onto its face: along its face's direction; its corner onto my face: along mine
                    add(E.n * sign, -best, "touch", inside and 0 or 2, E.n * -sign, true)
                end
            end
            for _, E in ipairs(theirs) do if apart3(E, me) <= reachT then cornerOnFace(me.corners, E, 1) end end
            for _, F in ipairs(mine) do if apart3(F, nb) <= reachT then cornerOnFace(nb.corners, F, -1) end end
        else
            -- one of them has no size: by its box (or point)
            local axes = { nb.ax, UP, nb.az }
            local nlo, nhi = { nb.lo.x, nb.lo.y, nb.lo.z }, { nb.hi.x, nb.hi.y, nb.hi.z }
            local mlo, mhi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
            for _, c in ipairs(mc) do
                local rel = c - nb.p
                for k = 1, 3 do
                    local v = dot(rel, axes[k])
                    if v < mlo[k] then mlo[k] = v end
                    if v > mhi[k] then mhi[k] = v end
                end
            end
            local gap, ov = {}, {}
            for k = 1, 3 do
                gap[k] = math.max(0, mlo[k] - nhi[k], nlo[k] - mhi[k])
                ov[k] = math.min(mhi[k], nhi[k]) - math.max(mlo[k], nlo[k])
            end
            for k = 1, 3 do
                local g = math.max(gap[k % 3 + 1], gap[(k + 1) % 3 + 1])
                local face = math.min(ov[k % 3 + 1], ov[(k + 1) % 3 + 1]) > 0.02
                if g <= SNAP_TOUCH then
                    add(axes[k], nhi[k] - mlo[k], "touch", face and 0 or 2, axes[k] * -1)
                    add(axes[k], nlo[k] - mhi[k], "touch", face and 0 or 2, axes[k])
                end
                if g <= SNAP_REACH then
                    add(axes[k], nlo[k] - mlo[k], "level", 1)
                    add(axes[k], nhi[k] - mhi[k], "level", 1)
                end
            end
        end
    end
    if #cands == 0 then return pos, nil end
    table.sort(cands, function(a, b)
        -- the closest object first, then: face to face, lining up, corners; then the smallest move
        if a.near ~= b.near then return a.near < b.near end
        if a.rank ~= b.rank then return a.rank < b.rank end
        if math.abs(a.cost - b.cost) > 1e-4 then return a.cost < b.cost end
        -- the same move: face to face before corner to face
        return (not a.corner) and b.corner == true
    end)
    -- the nearest snap, then others that go squarely across it (so each one stays exact)
    local picked, out = {}, pos
    -- meeting something side to side: it takes that object's height too (bottoms level, or tops level when that
    -- is less of a move), whichever handle moves it, so the two fit together
    local first = cands[1]
    -- (only bottoms level now: tops level made a shorter object float or sink next to a taller one. And when
    -- it sits on what is under it, that decides its height, not the object beside it)
    local grounded = S.landOn and S.sel and not S.lifted[S.sel.id]
    local lvMode = S.snapLevel or "auto"
    if first and first.kind == "touch" and first.fit and not first.corner and (not grounded or lvMode ~= "auto") then
        local f = first.fit
        local m = lvMode == "tops" and f.top or f.bottom
        if math.abs(m) > 1e-4 and math.abs(m) <= HEIGHT_FIT then
            local c = { mv = f.v * m, dir = f.v, cost = math.abs(m), rank = 1, o = first.o, nb = first.nb, kind = "level", near = first.near, height = lvMode == "tops" and "tops" or "bottoms" }
            picked[1] = c
            out = out + c.mv
        end
    end
    for _, c in ipairs(cands) do
        local ok = true
        -- after the first: more of the same object, or another one it meets face to face (fitting in a gap);
        -- not lining up with other objects round about (in a crowd that pulls it the wrong way)
        if first and c.o ~= first.o and not (c.kind == "touch" and c.rank == 0) then ok = false end
        for _, q in ipairs(picked) do
            if not ok then break end
            if math.abs(dot(c.dir, q.dir)) > 0.05 then ok = false break end
        end
        if ok then
            picked[#picked + 1] = c
            out = out + c.mv
            if #picked == 3 then break end
        end
    end
    -- (the height only goes with the meeting: if that could not be done this way, nor is the height)
    if picked[1] and picked[1].kind == "level" and first and picked[1].o == first.o and picked[1].dir == (first.fit and first.fit.v) then
        local met = false
        for k = 2, #picked do if picked[k] == first then met = true end end
        if not met then out = out - picked[1].mv; table.remove(picked, 1) end
    end
    -- what it snapped to first: the object it meets
    if picked[1] and picked[1].kind == "level" and picked[2] and picked[2].kind == "touch" then picked[1], picked[2] = picked[2], picked[1] end
    return out, picked
end

-- how each handle may be moved by a snap
local function allowAlong(d)   -- an arrow: only along it
    return function(ax, m)
        local c = dot(ax, d)
        if math.abs(c) < 0.5 then return nil end
        return d * (m / c), d
    end
end
local function allowIn(n)      -- a square: only across its plane (a sloped face: the part of it across the plane)
    return function(ax, m)
        local w = ax - n * dot(ax, n)
        local l2 = dot(w, w)
        if l2 < 0.25 then return nil end
        return w * (m / l2), w * (1 / math.sqrt(l2))
    end
end
-- landing on what is under it: rays straight down at its middle and corners, from a little above its bottom (so it
-- steps up onto things up to 1.5 m higher, and down onto anything lower); the held object itself is looked through
S.landOn = true
-- (the same question asked again within a moment, by the landing and the height readout, gets the same answer
-- without casting the rays again: rays are what takes time, and the game stops a plugin that takes too long)
S.supCache = {}
function FN.supportY(item, pos, heading, scale, selfId, wantSlope)
    local key = string.format("%s|%.3f|%.3f|%.3f|%.4f|%.3f|%s|%s", item, pos.x, pos.y, pos.z, heading, scale, tostring(selfId), tostring(wantSlope and S.slopeOn))
    local c = S.supCache[key]
    if c and S.clock - c.at < 120 then return c.y, c.sl end
    -- while it is being moved, asked at most 20 times a second: in between, the last answer for that object
    -- (nearly the same spot) stands
    local l = S.supLast
    if l and l.id == selfId and l.item == item and S.clock - l.at < 50 and math.abs(l.pos.x - pos.x) < 0.3 and math.abs(l.pos.z - pos.z) < 0.3 and math.abs(l.pos.y - pos.y) < 0.3 then
        return l.y, l.sl
    end
    if S.clock - (S.supCacheAt or -1e9) > 1000 then S.supCache = {}; S.supCacheAt = S.clock end
    local y, sl = FN.supportYNow(item, pos, heading, scale, selfId, wantSlope)
    S.supCache[key] = { y = y, sl = sl, at = S.clock }
    S.supLast = { id = selfId, item = item, pos = pos, y = y, sl = sl, at = S.clock }
    return y, sl
end
function FN.supportYNow(item, pos, heading, scale, selfId, wantSlope)
    local b = S.itemBox[item]
    local lo, hi = V(-0.3, 0, -0.3), V(0.3, 1, 0.3)
    if b then lo, hi = b[1] * scale, b[2] * scale end
    local bottom = pos.y + lo.y
    local ax, az = V(math.cos(heading), 0, -math.sin(heading)), V(math.sin(heading), 0, math.cos(heading))
    local mx, mz = (lo.x + hi.x) / 2, (lo.z + hi.z) / 2
    local wx, wz = (hi.x - lo.x) * 0.4, (hi.z - lo.z) * 0.4
    local me = selfId and S.known and S.known[selfId]
    local mine = { me and me.position, S.lastSent and S.lastSent.id == selfId and S.lastSent.pos or nil }
    -- (where it was sent lately: the game may still have it at any of them; where it is held tilted; and the
    -- objects it is inside of, like a copy just made of it)
    local hist = S.sentHist
    if hist and hist.id == selfId then
        for _, e in ipairs(hist) do if S.clock - e.at < 4000 then mine[#mine + 1] = e.pos end end
    end
    local th = selfId and S.tiltHeld and S.tiltHeld[selfId]
    if type(th) == "table" and th.posed then mine[#mine + 1] = th.posed end
    if selfId == (S.sel and S.sel.id) then
        for iid in pairs(S.snapIgnore or {}) do
            local io = S.known and S.known[iid]
            if io and FN.overlapsHeld(io) then mine[#mine + 1] = io.position end
        end
    end
    -- the way it has come lately, in order: where the game had it, each place it was sent to, where it is going
    local path = {}
    if me then path[#path + 1] = me.position end
    if hist and hist.id == selfId then
        for _, e in ipairs(hist) do if S.clock - e.at < 4000 then path[#path + 1] = e.pos end end
    end
    if S.sel and S.sel.id == selfId and S.target then path[#path + 1] = S.target.pos end
    -- (and the ones it takes along)
    if S.gbase and S.gbase.leader == selfId then
        for fid in pairs(S.gbase.m) do local fo = S.known and S.known[fid]; if fo then mine[#mine + 1] = fo.position end end
    end
    -- an object standing at hp is the held one itself (or one it takes along)
    local function isOwn(hp)
        for _, mp in pairs(mine) do if mp and len(hp - mp) < 0.05 then return true end end
        -- the game moves an object to its new place over a moment, so it can be anywhere on the way between
        -- the places it was sent to: anywhere along that path counts as itself too
        for i = 1, #path - 1 do
            local a, b = path[i], path[i + 1]
            local ab = b - a
            local l2 = dot(ab, ab)
            local t = l2 > 1e-9 and clamp(dot(hp - a, ab) / l2, 0, 1) or 0
            if len(a + ab * t - hp) < 0.05 then return true end
        end
        return false
    end
    -- (not lifted by hand: it stands on something, so where it meets that is not a hit on itself)
    local grounded = not (selfId and S.lifted and S.lifted[selfId])
    -- the first thing (not mine) straight down from a point
    local function pickDown(from, to)
        for _ = 1, 3 do
            local ok, hit = pcall(reskate.world.pick, from, to)
            if not (ok and type(hit) == "table" and hit.position) then return nil end
            if hit.position.y <= to.y + 1e-3 then return nil end   -- (the end of the ray: nothing there)
            local own = hit.object and hit.object.position and isOwn(hit.object.position)
            if not own then return hit.position.y end
            -- its own bottom where it stands: the ground is right there, and stepping on past it would go through
            -- the ground as well (down to whatever is under the map), so that is what it stands on
            -- (the level it stands at, not where the ray met it: its collision may sit a little above its bottom,
            -- and taking that would lift it a little more each time)
            if grounded and math.abs(hit.position.y - (hit.object.position.y + lo.y)) < 0.06 then return hit.object.position.y + lo.y end
            from = hit.position - V(0, 0.02, 0)
        end
        return nil
    end
    local function down(x, z)
        local wpt = pos + ax * x + az * z
        local y = pickDown(V(wpt.x, bottom + 1.5, wpt.z), V(wpt.x, bottom - 40, wpt.z))
        -- the game's other ray (its physics) as well, from just above its bottom: in places (a street over
        -- water) the first one sees through the road down to the sea floor, this one stops on the road
        if reskate.world.raycast then
            local a, z2 = V(wpt.x, bottom + 0.3, wpt.z), V(wpt.x, bottom - 40, wpt.z)
            local ok, h = pcall(reskate.world.raycast, a, z2)
            local hp = ok and h or nil
            if type(hp) == "table" and hp.position then hp = hp.position end
            if hp and hp.y and hp.y <= a.y + 1e-3 and hp.y > z2.y + 1e-3 and (not y or hp.y > y + 0.02) then
                -- this ray can't tell what it hit, and it may be the held object itself (where the game still
                -- has it): ask the other ray what stands right there, and leave it out if that's the held one
                local okc, c = pcall(reskate.world.pick, V(wpt.x, hp.y + 0.05, wpt.z), V(wpt.x, hp.y - 0.05, wpt.z))
                local mineThere = okc and type(c) == "table" and c.object and c.object.position and isOwn(c.object.position)
                -- (but at its own bottom, where it stands, the ray met the ground under it)
                local atBottom = mineThere and grounded and math.abs(hp.y - (c.object.position.y + lo.y)) < 0.06
                if atBottom then
                    local yb = c.object.position.y + lo.y
                    if not y or yb > y + 0.02 then y = yb end
                elseif not mineThere then y = hp.y end
            end
        end
        return y
    end
    -- (its middle decides: pushed against something it meets it side on; pushed on over it, it climbs on top)
    local best = down(mx, mz)
    -- but it only steps down once it is off what it stands on: while a corner (a little in) still rests on it,
    -- it stays up there (else a box on top of another drops off as soon as its middle passes the edge)
    -- (asked with the game's fast ray only, from just above its bottom: is something right at its bottom under that
    -- corner. The slow one, which can tell what it met, cost up to 5 rays a corner: a hitch while moving)
    local stays = false
    if best and best < bottom - 0.03 then
        local function atBottom(x, z)
            if not reskate.world.raycast then
                local y = down(x, z)
                return y and math.abs(y - bottom) <= 0.03
            end
            local wpt = pos + ax * x + az * z
            local a, z2 = V(wpt.x, bottom + 0.05, wpt.z), V(wpt.x, bottom - 0.1, wpt.z)
            local ok, h = pcall(reskate.world.raycast, a, z2)
            local hp = ok and h or nil
            if type(hp) == "table" and hp.position then hp = hp.position end
            return hp and hp.y and hp.y <= a.y + 1e-3 and hp.y > z2.y + 1e-3 and math.abs(hp.y - bottom) <= 0.03
        end
        for _, c in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
            if atBottom(mx + wx * c[1], mz + wz * c[2]) then best = bottom; stays = true; break end
        end
    end
    if not best then return nil end
    -- the slope it stands on (asked for): the tilt that sets it flat on it, false on the level, nil when unsure
    local sl = nil
    if wantSlope and S.slopeOn and not stays then
        local dd = math.max(0.15, math.min(wx, wz, 0.5))
        local x1, x0, z1, z0 = down(mx + dd, mz), down(mx - dd, mz), down(mx, mz + dd), down(mx, mz - dd)
        if x1 and x0 and z1 and z0 and math.max(math.abs(x1 - best), math.abs(x0 - best), math.abs(z1 - best), math.abs(z0 - best)) <= dd * 1.6 then
            local gx, gz = (x1 - x0) / (2 * dd), (z1 - z0) / (2 * dd)
            local ang = math.atan(math.sqrt(gx * gx + gz * gz))
            if ang < math.rad(FN.SLOPE_MIN) then
                sl = false
            elseif ang <= math.rad(50) then
                local nn = math.sqrt(gx * gx + 1 + gz * gz)
                sl = { x = math.atan2(-gz, 1), z = math.asin(gx / nn) }
            end
        end
    end
    return best - lo.y, sl
end
FN.SLOPE_MIN = 5
-- tilting to match slopes is switched off (tilts don't show online, and it got in the way of snapping)
S.slopeOn = false
-- Landing only trusts the game's rays when they see the object resting where the hold starts: in some spots
-- (parts of a street) the rays pass through the ground, and it would drop far under it. Not trusted, it may
-- still climb onto things (and is trusted from there on), but never goes down.
function FN.landTrust(item, pos, heading, scale, id)
    -- not lifted by hand: it goes down onto what is under it too (else an object left floating stays floating)
    if S.landOn and id and not S.lifted[id] then return true end
    local ok, y = pcall(FN.supportY, item, pos, heading, scale, id)
    return ok and y ~= nil and math.abs(y - pos.y) < 0.05
end
function FN.landTo(trusted, cur, y)
    if trusted then return y, true end
    if y >= cur - 0.01 then return y, y > cur + 0.01 end
    return cur, false
end
-- Raising and lowering: it catches on the ground under it when it comes near (how near: the snap strength).
-- Back on the ground it counts as resting again (it lands on what is under it as it is moved on).
local function groundCatch() return S.osnap and S.landOn and not S.noSnap and not FN.kbDown("noSnap") end
function FN.groundReach() return math.max(0.04, 0.09 * SNAP_K) end
local function groundUnder(y)
    local sel, t = S.sel, S.target
    local ok, g = pcall(FN.supportY, sel.item, V(t.pos.x, y, t.pos.z), t.heading, t.scale, sel.id)
    return ok and g or nil
end
-- a height the hand has taken it to, dragging or with the stick (rawY): the ground's height while near it,
-- so pulling a little further frees it again
function FN.heightNear(rawY)
    local sel, t = S.sel, S.target
    if not (sel and t) then return rawY, false end
    if groundCatch() then
        local g = groundUnder(rawY)
        if g and math.abs(rawY - g) <= FN.groundReach() then S.lifted[sel.id] = nil return g, true end
    end
    FN.markLifted()
    return rawY, false
end
-- a height stepped to (a key, a button, a panel step): caught on the ground when it steps onto it or past it
function FN.heightStep(oldY, newY)
    local sel, t = S.sel, S.target
    if not (sel and t) then return newY end
    if groundCatch() then
        local g = groundUnder(oldY)
        local r = FN.groundReach()
        if g and ((oldY > g + 0.005 and newY <= g + r) or (oldY < g - 0.005 and newY >= g - r) or math.abs(newY - g) <= 0.005) then
            S.lifted[sel.id] = nil
            return g
        end
    end
    FN.markLifted()
    return newY
end
-- the held object (and its group with it) put down onto what is under it: its bottom on the ground, also when it
-- was sunk into it or floating (asked from 2 m higher up, so one sunk up to that deep is found too)
function FN.dropToGround()
    local sel, t = S.sel, S.target
    if not (sel and t) then PE.say("Pick an object first: it then drops onto the ground.", true) return end
    local ok, y = pcall(FN.supportY, sel.item, t.pos + V(0, 2, 0), t.heading, t.scale, sel.id)
    if not ok or type(y) ~= "number" then PE.say("No ground found under it.", true) return end
    local moved = y - t.pos.y
    if math.abs(moved) < 0.002 then PE.say("It is on the ground already.") return end
    PE.markUndo()
    S.lifted[sel.id] = nil
    t.pos = V(t.pos.x, y, t.pos.z)
    S.dirty = true
    PE.say(string.format("Dropped onto the ground (%s %.2f m).", moved > 0 and "up" or "down", math.abs(moved)))
end
-- the slope found while moving: tilt the held object to it (or level again when it was tilted by a slope)
function FN.takeSlope(id, sl, setTl)
    if true then return end
    if not S.slopeOn or not id then return end
    if sl then
        setTl({ x = sl.x, z = sl.z }); S.slopeTilt = id; S.tiltSaveDue = true
    elseif sl == false and S.slopeTilt == id then
        setTl(nil); S.slopeTilt = nil; S.tiltSaveDue = true
    end
end
-- landing may go on: not tilted, or tilted by a slope it stood on
function FN.mayLand(id) return not tilted(id) or (S.slopeOn and S.slopeTilt == id) end

local function allowFree(level, updown)   -- the controller: the ways it is being moved right now
    local flat = allowIn(UP)
    return function(ax, m)
        if level and updown then return ax * m, ax end
        if level then return flat(ax, m) end
        if updown and math.abs(ax.y) >= 0.5 then return UP * (m / ax.y), UP end
        return nil
    end
end

-- turning: the same way as the nearest object, or square to it
-- the turns that would set one of my long sides against (or flush with) one of its long sides
function FN.turnsToMeet(me, nb, maxTurn)
    local out = {}
    for i = 1, math.min(#me.edges, 6) do
        local F = me.edges[i]
        if F.len >= 0.25 or i == 1 then
            for j = 1, math.min(#nb.edges, 6) do
                local E = nb.edges[j]
                if E.len >= 0.25 or j == 1 then
                    local aF, aE = F.ang, E.ang
                    for _, target in ipairs({ aE + math.pi, aE }) do
                        local d = wrap(target - aF)
                        if math.abs(d) <= maxTurn then out[#out + 1] = { d = d, F = F, E = E } end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return math.abs(a.d) < math.abs(b.d) end)
    return out
end

local function turnSnap(hd)
    if not (S.osnap and S.sel and S.known and S.target) then return hd, nil end
    local best, bd = nil, SNAP_REACH + 4
    for _, o in ipairs(nearObjects(S.target.pos, SNAP_REACH + 4)) do
        local id = o.id
        if id ~= S.sel.id and FN.snapAllowed(id) then
            local d = len(o.position - S.target.pos)
            if d < bd then best, bd = o, d end
        end
    end
    if not best then return hd, nil end
    if tiltOf(S.sel.id) or tiltOf(best.id) then return hd, nil end
    local me = worldShape(S.sel.item, S.target.pos, hd, S.target.scale)
    local nb = FN.placedShape(best)
    if #me.edges > 0 and #nb.edges > 0 then
        local t = FN.turnsToMeet(me, nb, SNAP_TURN)
        if t[1] then return wrap(hd + t[1].d), { { o = best, nb = nb, kind = "turn" } } end
        if math.abs(wrap(hd - (best.heading or 0)) - round(wrap(hd - (best.heading or 0)), math.pi / 2)) > SNAP_TURN then return hd, nil end
    end
    local bh = best.heading or 0
    local rel = wrap(hd - bh)
    local k = round(rel, math.pi / 2)
    if math.abs(rel - k) > SNAP_TURN then return hd, nil end
    return wrap(bh + k), { { o = best, nb = worldShape(best.item, best.position, bh, best.scale or 1), kind = "turn" } }
end

-- snapping must never get in the way of moving: on a fault the place is left as it was (said once in the log)
local function snapTo(pos, heading, scale, allow)
    if S.snapStyle == "match" and FN.matchSnap then
        -- (here it can't turn: only sides that already face each other)
        local ok, p, _, g = pcall(FN.matchSnap, pos, heading, scale, true)
        if ok then
            S.snapLock = (g and g[1] and g[1].o) and g[1].o.id or nil
            return p, g
        end
        return pos, nil
    end
    local ok, p, g = pcall(objSnap, pos, heading, scale, allow)
    if ok then
        S.snapLock = (g and g[1] and g[1].o) and g[1].o.id or nil
        return p, g
    end
    if FN.problem then FN.problem("snapping", p) elseif not S.snapWarned then S.snapWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(p), "warn") end
    return pos, nil
end
local function turnApart(h1, t1, h2, t2)
    local a, b = fullTurn(h1, t1), fullTurn(h2, t2)
    local d = math.abs(a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4])
    return 2 * math.acos(math.min(1, d))
end

-- Moving with a turn: when the picked object comes to meet a nearby object that is turned (or tilted) differently,
-- it takes that object's turn (and tilt) so the two faces meet flat. base and baseTilt are what it had when the
-- move began, so pulling it away again gives those back.
local function alignSnap(pos, base, scale, allow, baseTilt)
    local bt = baseTilt
    if bt and math.abs(bt.x) < 1e-4 and math.abs(bt.z) < 1e-4 then bt = nil end
    local p1, g1 = objSnap(pos, base, scale, allow, bt)
    if not (S.osnap and S.sel and S.known and S.itemBox[S.sel.item]) then return p1, base, g1, bt end
    -- already meeting something face to face (not just a corner): stays as it is
    for _, q in ipairs(g1 or {}) do
        if q.kind == "touch" and not q.corner and q.rank == 0 then return p1, base, g1, bt end
    end
    local near = {}
    for _, o in ipairs(nearObjects(pos, SNAP_REACH + 2)) do
        local id = o.id
        if id ~= S.sel.id and FN.snapAllowed(id) and S.itemBox[o.item] then
            local b = S.itemBox[o.item]
            local d = len(o.position - pos) - len((b[2] - b[1]) * (o.scale or 1)) / 2
            if d < SNAP_REACH + 2 then near[#near + 1] = { o = o, d = d } end
        end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    local tries, tried = 0, {}
    local thr = clamp(S.cam.dist * 0.03, 0.12, 0.5) * SNAP_K
    local function try(n, hd, tl)
        local p2, g2 = objSnap(pos, hd, scale, allow, tl)
        for _, q in ipairs(g2 or {}) do
            if q.o.id == n.o.id and q.kind == "touch" and q.rank == 0 and not q.corner then
                table.insert(g2, { o = n.o, nb = q.nb, kind = "turn" })
                return p2, g2
            end
        end
        return nil
    end
    for i = 1, math.min(#near, 2) do
        local n = near[i]
        local ntl = tiltOf(n.o.id)
        if ntl then
            -- a tilted one: no longer taken on (an object doesn't take another's tilt when it meets it: tilts
            -- don't show online, and it got in the way of ordinary snapping)
        elseif not bt then
            -- both flat: a turn about up that sets two long sides together
            local me = worldShape(S.sel.item, pos, base, scale)
            local nb = FN.placedShape(n.o)
            if #me.edges > 0 and #nb.edges > 0 then
                for _, tm in ipairs(FN.turnsToMeet(me, nb, math.rad(90))) do
                    local d, F, E = tm.d, tm.F, tm.E
                    local v = (F.a + F.b) * 0.5 - pos
                    local cd, sd = math.cos(d), math.sin(d)
                    local m = pos + V(v.x * cd + v.z * sd, 0, -v.x * sd + v.z * cd)
                    local dist, along = dot(m - E.a, E.n), dot(m - E.a, E.e)
                    local close = math.abs(dist) <= thr + 0.05 and along > -F.len / 2 - SNAP_TOUCH and along < E.len + F.len / 2 + SNAP_TOUCH
                    local seen = false
                    for _, q in ipairs(tried) do if math.abs(q - d) < 0.003 then seen = true break end end
                    if close and not seen and math.abs(d) > 1e-3 then
                        tried[#tried + 1] = d
                        tries += 1
                        if tries > 6 then break end
                        local hd = wrap(base + d)
                        local p2, g2 = try(n, hd, nil)
                        if p2 then return p2, hd, g2, nil end
                    end
                end
            end
        end
    end
    return p1, base, g1, bt
end
-- ---- snapping by matching sides (the default): a side of the held object that is like a side of an object
-- near it (about the same width and height) and faces it, within reach, is put flat against it: turned so the
-- two sides face each other, and slid so they meet, middle to middle (so sides of the same width line up edge to
-- edge). Its height is left as it is (it sits on what is under it). The Snap tab's slider sets the reach.
S.snapStyle = "match"
do
    local ok, v = pcall(reskate.storage.get, "snapStyle")
    if ok and (v == "match" or v == "classic") then S.snapStyle = v end
end
-- how heights are matched when sides meet: "auto", "bottoms" or "tops" (kept between games)
S.snapLevel = "auto"
do
    local ok, v = pcall(reskate.storage.get, "snapLevel")
    if ok and (v == "auto" or v == "bottoms" or v == "tops") then S.snapLevel = v end
end
function FN.setSnapLevel(v)
    S.snapLevel = v
    S.matchLock = nil
    pcall(reskate.storage.set, "snapLevel", v)
end
function FN.setSnapStyle(v)
    S.snapStyle = v
    S.matchLock = nil
    pcall(reskate.storage.set, "snapStyle", v)
end
local MATCH_FACING = math.cos(math.rad(40))   -- sides turned at most this much from facing each other
local MATCH_SIMILAR = 0.45                    -- how unlike two sides may be (0 = the same size)
local function sideFaces(so, max)
    local out = {}
    for _, F in ipairs(so.faces or {}) do
        if F.side and F.ulen >= 0.12 and F.vlen >= 0.03 then
            F.c = F.o + F.u * (F.ulen * 0.5) + F.v * (F.vlen * 0.5)
            out[#out + 1] = F
            if #out >= max then break end
        end
    end
    return out
end
local function angOf(v) return math.atan2(v.x, v.z) end
local sideTop
-- how high a side's top is, where that side is: the highest point of the object's real outline (its model's
-- edges, or its scan) on that side; without an outline, its box's top
sideTop = function(F, so, item, scale)
    local top0 = F.o.y + F.vlen
    local w = FN.outlineOf and FN.outlineOf(item)
    local sh = so and so.shape
    if not (w and sh and sh.p and sh.ax) then return top0, nil end
    local p, X, Y, Z = sh.p, sh.ax * scale, UP * scale, sh.az * scale
    local best = -math.huge
    local pts = {}
    for i = 1, #w - 2, 3 do
        local q = p + X * w[i] + Y * w[i + 1] + Z * w[i + 2]
        local r = q - F.o
        local dn = dot(r, F.n)
        if dn > -0.08 and dn < 0.08 then
            local du = dot(r, F.u)
            if du > -0.03 and du < F.ulen + 0.03 then
                pts[#pts + 1] = { du, q.y }
                if q.y > best then best = q.y end
            end
        end
    end
    if best == -math.huge then return top0, nil end
    -- its lip: where along the side the top is, when the top is a point or a short stretch (a quarter pipe's
    -- coping, a bank's top edge), not the whole width (a box)
    local u0, u1 = math.huge, -math.huge
    for _, q in ipairs(pts) do
        if q[2] >= best - 0.02 then u0 = math.min(u0, q[1]); u1 = math.max(u1, q[1]) end
    end
    local lip = (u1 - u0) < F.ulen * 0.5 and (u0 + u1) * 0.5 or nil
    return best, lip
end

-- Stacking: the held object sitting on (or just above) another one's top is lined up with it: turned the same way
-- (or a quarter turn from it), and along each of that object's two ways across, centred on it or flush with
-- either edge of it, whichever is nearest. Its height is that object's top.
local stackSnap
local STACK_ABOVE = 0.06   -- how far above a top it may be (or a little into it) to count as sitting on it
stackSnap = function(me, pos, base, scale, noTurn, reach)
    local mb = me.shape and me.shape.ylo
    if not mb then return nil end
    local best, bs = nil, math.huge
    for _, o in ipairs(nearObjects(pos, reach + 1)) do
        local id = o.id
        if id ~= S.sel.id and FN.snapAllowed(id) and S.itemBox[o.item] and not tiltOf(id) then
            local b = S.itemBox[o.item]
            local their = len((b[2] - b[1]) * (o.scale or 1))
            local dxz = math.sqrt((o.position.x - pos.x) ^ 2 + (o.position.z - pos.z) ^ 2)
            if dxz <= their * 0.6 + reach then
                local nb = placedSolid(o)
                local T
                for _, f in ipairs(nb.faces) do if not f.side and f.n.y > 0.99 then T = f break end end
                if T then
                    local above = mb - T.o.y
                    if above > -STACK_ABOVE and above < STACK_ABOVE then
                        -- my middle over its top (its two ways across)
                        local du, dv = dot(pos - T.o, T.u), dot(pos - T.o, T.v)
                        local m = reach * 0.5
                        if du > -m and du < T.ulen + m and dv > -m and dv < T.vlen + m then
                            local ou = math.max(0, -du, du - T.ulen) + math.max(0, -dv, dv - T.vlen)
                            local score = ou + math.abs(above)
                            if S.matchLock and S.matchLock.id == id and S.matchLock.stack then score -= 0.2 end
                            if score < bs then bs, best = score, { o = o, T = T } end
                        end
                    end
                end
            end
        end
    end
    if not best then return nil end
    local o, T = best.o, best.T
    -- turned like it (or a quarter turn from it), when it nearly is
    local hd = base
    local rel = wrap(base - (o.heading or 0))
    local q = round(rel, math.pi / 2)
    if math.abs(rel - q) <= (noTurn and math.rad(5) or math.rad(40)) then hd = wrap((o.heading or 0) + q) end
    local me2 = (hd == base) and me or worldSolid(S.sel.item, pos, hd, scale, nil)
    -- along each way across its top: centred, or flush with either edge, whichever is nearest
    local mv = V(0, 0, 0)
    local stops = {}
    for k, dir in ipairs({ T.u, T.v }) do
        local tl = k == 1 and T.ulen or T.vlen
        local a0, a1 = math.huge, -math.huge
        for _, c in ipairs(me2.corners) do
            local a = dot(c - T.o, dir)
            a0 = math.min(a0, a); a1 = math.max(a1, a)
        end
        local mid = (a0 + a1) * 0.5
        local cands = { tl * 0.5 - mid, 0 - a0, tl - a1 }
        local bi, bd = 1, math.huge
        for i, c in ipairs(cands) do
            local dd = math.abs(c)
            local lk = S.matchLock
            if lk and lk.id == o.id and lk.stack and lk.stack[k] == i then dd -= 0.1 end
            if dd < bd then bi, bd = i, dd end
        end
        -- only when close (else it is left where it is that way)
        if math.abs(cands[bi]) <= math.max(0.15, reach * 0.5) then
            mv += dir * cands[bi]; stops[k] = bi
        end
    end
    local np = V(pos.x + mv.x, T.o.y + (pos.y - me.shape.ylo), pos.z + mv.z)
    S.stackLock = { id = o.id, stack = stops }
    local centred = (stops[1] == 1 or stops[1] == nil) and (stops[2] == 1 or stops[2] == nil)
    local edge = stops[1] and stops[1] > 1 or stops[2] and stops[2] > 1
    local how = "On top" .. (edge and "  ·  flush with an edge" or (centred and (stops[1] or stops[2]) and "  ·  centred" or ""))
    return np, hd, { { o = o, nb = FN.placedShape(o), kind = "stack", label = how } }
end
local function matchSnap(pos, base, scale, noTurn)
    if not (S.osnap and S.sel and S.known and S.itemBox[S.sel.item]) then return pos, base, nil end
    if S.snapPick == "off" then return pos, base, nil end
    local me = worldSolid(S.sel.item, pos, base, scale, nil)
    if not me.sized then return pos, base, nil end
    local mine = sideFaces(me, 16)
    if #mine == 0 then return pos, base, nil end
    local reach = 0.6 * SNAP_K                  -- how far apart the two sides may be
    local size = len(me.hi - me.lo)
    local lock = S.matchLock
    -- sitting on top of another object: lined up with it (see stackSnap)
    -- (side to side wins when there is a side to meet: then not with the one under it, and only sides at about
    -- the same height, so it is not pulled off what it sits on)
    local lock0 = S.matchLock
    local sp, sh, sg = stackSnap(me, pos, base, scale, noTurn, reach)
    local under = sg and sg[1].o.id
    S.matchLock = lock0
    local best, bs = nil, math.huge
    for _, o in ipairs(nearObjects(pos, size * 0.6 + reach + 0.5)) do
        local id = o.id
        if id ~= S.sel.id and id ~= under and FN.snapAllowed(id) and S.itemBox[o.item] and not tiltOf(id) then
            local b = S.itemBox[o.item]
            local their = len((b[2] - b[1]) * (o.scale or 1))
            if len(o.position - pos) <= (size + their) * 0.6 + reach + 0.5 then
                local nb = placedSolid(o)
                for _, E in ipairs(sideFaces(nb, 16)) do
                    for _, F in ipairs(mine) do
                        local facing = -dot(F.n, E.n)
                        if facing >= (noTurn and 0.996 or MATCH_FACING) then
                            local dc = F.c - E.c
                            local gap = dot(dc, E.n)
                            if gap > -reach and gap < reach and not (under and math.abs(E.o.y - F.o.y) > 0.3) then
                                local lat = dc - E.n * gap
                                local latLen = math.sqrt(lat.x * lat.x + lat.z * lat.z)
                                local wMax, hMax = math.max(F.ulen, E.ulen), math.max(F.vlen, E.vlen)
                                -- (sides that overlap along their length, or nearly: corner to corner counts too)
                                if latLen <= (F.ulen + E.ulen) * 0.5 + reach * 0.5 then
                                    local unlike = math.abs(F.ulen - E.ulen) / wMax + 0.5 * math.abs(F.vlen - E.vlen) / hMax
                                    -- sides not alike (a short end against a long side) still meet, at a corner,
                                    -- but alike sides come first
                                    local alike = unlike <= MATCH_SIMILAR
                                    if alike or latLen <= (F.ulen + E.ulen) * 0.5 + reach * 0.5 then
                                        local score = math.min(unlike, 1) * 2 + math.abs(gap) / reach + latLen / wMax + (1 - facing) * 3
                                        if not alike then score += 1.5 end
                                        -- keep to the side it is on (no flicking between two that are nearly as good)
                                        if lock and lock.id == id then score -= 0.4 end
                                        if score < bs then bs, best = score, { o = o, E = E, F = F, alike = alike, nb = nb } end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if not best then
        if sp then
            S.matchLock = S.stackLock
            return sp, sh, sg
        end
        S.matchLock = nil
        return pos, base, nil
    end
    local E, F = best.E, best.F
    -- turn it so its side faces the other side (about up only), then slide it so the two sides meet
    local d = noTurn and 0 or wrap(angOf(E.n * -1) - angOf(F.n))
    local hd = wrap(base + d)
    local cd, sd = math.cos(d), math.sin(d)
    local v = F.c - pos
    local fc = pos + V(v.x * cd + v.z * sd, v.y, -v.x * sd + v.z * cd)
    -- up to the other side (closing the gap)
    local m = E.n * dot(E.c - fc, E.n)
    -- and along it: to its middle, or flush with either end of it, whichever is nearest (a short piece against a
    -- long one can stop at either end); the stop it is at is kept until another is clearly nearer
    local u = V(E.u.x, 0, E.u.z)
    local ul = len(u)
    local stop = nil
    if ul > 1e-6 then
        u = u * (1 / ul)
        local at = dot(fc - E.o, u)
        local hw = F.ulen * 0.5
        -- the stops: middle to middle, flush with either end (an inside corner), or just past
        -- either end, corner to corner (an outside corner)
        local stops = { E.ulen * 0.5, hw, E.ulen - hw, -hw, E.ulen + hw }
        -- copings together: both sides have a lip (their top is a point along them): my lip where its lip is
        local _, lipE = sideTop(E, best.nb, best.o.item, best.o.scale or 1)
        local _, lipF = sideTop(F, me, S.sel.item, scale)
        if lipE and lipF then
            local lq = F.o + F.u * lipF - pos
            local lw = pos + V(lq.x * cd + lq.z * sd, lq.y, -lq.x * sd + lq.z * cd)
            stops[6] = at + (lipE - dot(lw - E.o, u))
        end
        local k, kd = 1, math.huge
        for i, c in ipairs(stops) do
            local dd = math.abs(c - at)
            if lock and lock.id == best.o.id and lock.stop == i then dd -= 0.15 end
            -- (copings together first, when about as near)
            if i == 6 then dd -= 0.1 end
            if dd < kd then k, kd = i, dd end
        end
        stop = k
        m += u * (stops[k] - at)
    end
    -- and level with it: bottoms at the same height (so copings meet without a step), when they are close already.
    -- Lifted by hand (or not landing): tops level too, whichever is nearer, each side's top where that side is
    -- (a sloped ledge's low end against a platform's side: its top goes on from the platform's top, to skate up it)
    -- (the Level choice on the snap bar: Bottoms, Tops, or Auto: bottoms, and when lifted by hand (or not
    -- landing) whichever is nearer)
    local mode = S.snapLevel or "auto"
    local db = E.o.y - F.o.y
    local function dTop() return sideTop(E, best.nb, best.o.item, best.o.scale or 1) - sideTop(F, me, S.sel.item, scale) end
    local dy, lv = 0, nil
    if mode == "bottoms" then
        if math.abs(db) <= math.max(0.3, 0.6 * SNAP_K) then dy, lv = db, "bottoms" end
    elseif mode == "tops" then
        local dt = dTop()
        if math.abs(dt) <= math.max(0.5, 1.5 * SNAP_K) then dy, lv = dt, "tops" end
    elseif stop == 6 then
        -- copings together: tops level too, so they meet without a step
        local dt = dTop()
        if math.abs(dt) <= math.max(0.5, 1.5 * SNAP_K) then dy, lv = dt, "tops" end
    else
        local lifted = (S.sel and S.lifted[S.sel.id]) or not S.landOn
        if lifted then
            local dt = dTop()
            if math.abs(dt) < math.abs(db) then dy, lv = dt, "tops" else dy, lv = db, "bottoms" end
            if math.abs(dy) > math.max(0.3, 0.6 * SNAP_K) then dy, lv = 0, nil end
        elseif math.abs(db) <= 0.3 then dy, lv = db, "bottoms" end
    end
    local np = pos + V(m.x, dy, m.z)
    S.matchLock = { id = best.o.id, stop = stop }
    -- what it did, in words (shown by the held object)
    local how = ({ "Side to side, middles", "Flush with its end", "Flush with its end", "Corner to corner", "Corner to corner", "Copings together" })[stop or 1]
    if lv then how = how .. "  ·  " .. (lv == "tops" and "tops level" or "bottoms level") end
    return np, hd, { { o = best.o, nb = FN.placedShape(best.o), kind = "match", label = how } }
end
FN.matchSnap = matchSnap

local function snapTurned(pos, base, scale, allow, baseTilt)
    if S.snapStyle == "match" then
        local ok, p, h, g = pcall(matchSnap, pos, base, scale)
        if ok then
            S.snapLock = (g and g[1] and g[1].o) and g[1].o.id or nil
            return p, h, g, baseTilt
        end
        if FN.problem then FN.problem("snapping", p) elseif not S.snapWarned then S.snapWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(p), "warn") end
        return pos, base, nil, baseTilt
    end
    local ok, p, h, g, tl = pcall(alignSnap, pos, base, scale, allow, baseTilt)
    if ok then
        S.snapLock = (g and g[1] and g[1].o) and g[1].o.id or nil
        return p, h, g, tl
    end
    if FN.problem then FN.problem("snapping", p) elseif not S.snapWarned then S.snapWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(p), "warn") end
    return pos, base, nil, baseTilt
end
function FN.turnTo(hd)
    local ok, h, g = pcall(turnSnap, hd)
    if ok then return h, g end
    if FN.problem then FN.problem("snapping", h) elseif not S.snapWarned then S.snapWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(h), "warn") end
    return hd, nil
end

-- shared with the parts after this one
PE.MAX_HELD = MAX_HELD
PE.SNAP_REACH = SNAP_REACH
PE.SNAP_TURN = SNAP_TURN
PE.UP = UP
PE.allowAlong = allowAlong
PE.allowFree = allowFree
PE.allowIn = allowIn
PE.apart3 = apart3
PE.boxLog = boxLog
PE.cornersOf = cornersOf
PE.forgetSize = forgetSize
PE.fullTurn = fullTurn
PE.learnNear = learnNear
PE.localOutline = localOutline
PE.placedSolid = placedSolid
PE.qconj = qconj
PE.qmul = qmul
PE.qrot = qrot
PE.r3 = r3
PE.saveLook = saveLook
PE.saveSize = saveSize
PE.snapTurned = snapTurned
PE.tiltOf = tiltOf
PE.tiltPoint = tiltPoint
PE.tilted = tilted
PE.worldBox = worldBox
PE.worldShape = worldShape
PE.worldSolid = worldSolid
end
