-- DDH Quick Drop helper: works alongside Skate's own Quick Drop.
--
-- Drop objects with Quick Drop as normal. Then press F6 to fine-tune them with the same handles as the Object
-- Maker's 3D maker: W move (arrows, and squares to slide along a plane), E turn (the ring), R size (the cubes).
-- Click another placed object to pick it. Drag empty space to turn the view, right-drag to slide it, scroll to
-- zoom, W A S D Q E... (see the panel). Esc closes it.
--
-- Without opening it: hold Ctrl and use [ ] (turn), PageUp / PageDown (height), Z / X (size), arrows (slide)
-- on the last dropped object.
--
-- The game's park objects only turn about the up axis and only size evenly, so the turn handle is one ring and
-- every size cube sizes the whole object.

local V = vector.create
local function len(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
local function norm(v) local l = len(v); if l < 1e-9 then return V(0, 0, 1) end; return v * (1 / l) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function flat(v) return norm(V(v.x, 0, v.z)) end
local function wrap(a)
    while a > math.pi do a -= 2 * math.pi end
    while a < -math.pi do a += 2 * math.pi end
    return a
end
local function round(x, step) return math.floor(x / step + 0.5) * step end
local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function segDist(p, a, b)
    local abx, aby = b.x - a.x, b.y - a.y
    local l2 = abx * abx + aby * aby
    local t = l2 > 0 and clamp(((p.x - a.x) * abx + (p.y - a.y) * aby) / l2, 0, 1) or 0
    return math.sqrt((a.x + abx * t - p.x) ^ 2 + (a.y + aby * t - p.y) ^ 2)
end
local function inPoly(p, pts)
    local inside = false
    local j = #pts
    for i = 1, #pts do
        local a, b = pts[i], pts[j]
        if ((a.y > p.y) ~= (b.y > p.y)) and (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) then inside = not inside end
        j = i
    end
    return inside
end

local TITLE = "Quick Drop+"
local RED, GREEN, BLUE, YELLOW = "#ff3b3b", "#2bea2b", "#2f6bff", "#ffe066"
local AXES = { { V(1, 0, 0), RED }, { V(0, 1, 0), GREEN }, { V(0, 0, 1), BLUE } }
-- plane handles: the plane's normal axis, and the two axes it spans (coloured like three.js: by its normal)
-- the object's own directions: right (red), up (green), forward (blue), turned with it
local function axesFor(h)
    return { { V(math.cos(h), 0, -math.sin(h)), RED }, { V(0, 1, 0), GREEN }, { V(math.sin(h), 0, math.cos(h)), BLUE } }
end
local BOX_EDGES = { { 0, 1 }, { 2, 3 }, { 4, 5 }, { 6, 7 }, { 0, 2 }, { 1, 3 }, { 4, 6 }, { 5, 7 }, { 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 } }
local PLANES = { { n = 3, a = 1, b = 2 }, { n = 1, a = 2, b = 3 }, { n = 2, a = 1, b = 3 } }

local S = {
    clock = 0,
    -- objects on the map, to notice Quick Drop's new ones
    known = nil, lastScan = 0, titles = {},
    -- the object being changed
    sel = nil, target = nil, dirty = false, lastSend = 0, undo = {},
    -- the editor
    open = false, mode = 1, snap = false,
    -- snapping to other objects: on or off, each item's size once known ({ low corner, high corner }, false when
    -- the game gives none), and what the picked object is snapped to right now (drawn in the view)
    osnap = true, itemBox = {}, boxTries = {}, boxNext = {}, boxLogged = 0, guides = nil, measure = nil, mRays = 0, mT0 = 0,
    cam = { target = V(0, 0, 0), yaw = 0, pitch = -0.4, dist = 10, fov = 60 },
    mouse = { pos = nil, left = false }, drag = nil, hover = nil,
    screen = {}, proj = nil, size = V(1920, 1080, 0),
    held = {}, msg = "", msgUntil = 0,
}

local function say(text, warn)
    S.msg = text
    S.msgUntil = S.clock + 4000
    if warn or not S.open then reskate.ui.toast(text, warn and "warn" or "info") end
end

local function titleOf(key)
    if S.titles[key] then return S.titles[key] end
    for _, it in ipairs(reskate.objects.catalog()) do S.titles[it.key] = it.title or it.key end
    return S.titles[key] or key
end

local function select(o, blueprint)
    S.handleLen = nil
    S.edit = {}
    S.guides, S.padRaw, S.tighten = nil, nil, nil
    if not o then S.sel, S.target, S.dirty = nil, nil, false return end
    S.sel = { id = o.id, item = o.item, bp = blueprint, pos0 = o.position, h0 = o.heading or 0 }
    if S.open and S.cam.goal then S.cam.goal = o.position end
    S.target = { pos = o.position, heading = o.heading or 0, scale = o.scale or 1 }
    S.dirty = false
end

local function fmt(o)
    return string.format("%s id=%s at %.2f,%.2f,%.2f turn %.1f size %.2f", o.item, tostring(o.id), o.position.x, o.position.y,
        o.position.z, math.deg(o.heading or 0), o.scale or 1)
end

-- park objects whose item is not in the catalog: from a mod that is off, missing, or rebuilt with new names.
-- While the park has any, the game refuses every change to it.
local function findMissing(blockedKey)
    local have = {}
    for _, it in ipairs(reskate.objects.catalog()) do have[it.key] = true end
    local out = {}
    for _, o in ipairs(reskate.objects.list()) do
        if not have[o.item] or (blockedKey and o.item == blockedKey) then table.insert(out, o) end
    end
    S.missing = out
    if #out > 0 then
        reskate.log(string.format("Quick Drop helper: %d park object(s) are from a mod that is off or not installed:", #out), "warn")
        for _, o in ipairs(out) do reskate.log("Quick Drop helper:   missing " .. fmt(o), "warn") end
        -- for the "Clean out park" tool: it removes exactly these from the park save, with the game closed
        for _, o in ipairs(out) do reskate.log("DDH-CLEANOUT " .. tostring(o.id) .. " " .. tostring(o.item)) end
    end
    return out
end

-- new objects (from Quick Drop or anything else) become the picked one
local function scan()
    local list = reskate.objects.list()
    local now = {}
    for _, o in ipairs(list) do now[o.id] = o end
    if S.known == nil then
        reskate.log(string.format("Quick Drop helper: %d park objects on this map.", #list))
        pcall(findMissing)
        if not S.loggedCat then
            S.loggedCat = true
            local n, ddh = 0, {}
            for _, it in ipairs(reskate.objects.catalog()) do
                n += 1
                if string.find(string.lower(it.key), "ddh", 1, true) then table.insert(ddh, it.key .. " = " .. tostring(it.title)) end
            end
            reskate.log(string.format("Quick Drop helper: catalog has %d items; with ddh: %s", n, table.concat(ddh, "; ")))
        end
    else
        local fresh = {}
        for id, o in pairs(now) do
            if not S.known[id] then table.insert(fresh, o) end
        end
        -- one new object: a drop. Many at once: a park or map loading, not something to pick.
        if #fresh == 1 then
            local o = fresh[1]
            reskate.log("Quick Drop helper: new object " .. fmt(o))
            select(o)
            if not S.open then reskate.ui.toast("Dropped " .. titleOf(o.item) .. ". F6: move, turn and size it") end
        elseif #fresh > 1 then
            reskate.log(string.format("Quick Drop helper: %d objects loaded with the park.", #fresh))
        end
        if S.sel and not now[S.sel.id] then select(nil) end
        -- moved by something else (Quick Drop again): follow it
        if S.sel and not S.dirty and not S.drag and S.clock - S.lastSend > 1500 then
            local o = now[S.sel.id]
            S.target = { pos = o.position, heading = o.heading or 0, scale = o.scale or 1 }
        end
    end
    S.known = now
end

local BUSY = { ["the last edit is still being applied"] = true, ["more than 4 edits in a second"] = true }
local function sameAsSent(t)
    local l = S.lastSent
    return l and l.id == S.sel.id and len(l.pos - t.pos) < 1e-4 and math.abs(wrap(l.heading - t.heading)) < 1e-5
        and math.abs(l.scale - t.scale) < 1e-5
end
-- has the game put the object where we last sent it? (it takes a moment to apply each edit)
local function lastApplied()
    local l = S.lastSent
    if not l or S.clock - l.at > 1500 then return true end
    if l.applied then return true end
    if S.clock - (S.appliedCheckAt or -1e9) < 50 then return false end
    S.appliedCheckAt = S.clock
    l.applied = true
    for _, o in ipairs(reskate.objects.list()) do
        if o.id == l.id then
            l.applied = len(o.position - l.pos) < 0.005 and math.abs((o.scale or 1) - l.scale) < 0.005
            break
        end
    end
    return l.applied
end
-- sends the change to the game. The game takes at most 4 edits a second, counting refused tries, and one at a
-- time, so a new one only goes once the last is applied and fewer than 4 went in the last second.
-- While a handle is dragged the object follows as often as that allows; letting go sends the exact place.
local function send()
    if not (S.sel and S.dirty) then return end
    local t = S.target
    if sameAsSent(t) then S.dirty = false return end
    local tries = S.tries or {}
    S.tries = tries
    while tries[1] and S.clock - tries[1] > 1050 do table.remove(tries, 1) end
    if #tries >= 4 then return end
    if not lastApplied() then return end
    local gap = ((S.drag and S.drag.moved) or S.padMoving) and 150 or 250
    if S.clock - S.lastSend < gap then return end
    table.insert(tries, S.clock)
    local hd = nil
    if S.sel.h0 == nil or math.abs(wrap(t.heading - S.sel.h0)) > 1e-5 then hd = t.heading end
    local ok, why = reskate.objects.move(S.sel.id, t.pos, hd, t.scale)
    if S.dragStats then
        local st = S.dragStats
        if ok then st.sent += 1 elseif BUSY[why] then st[why] = (st[why] or 0) + 1 else st.other = (st.other or 0) + 1 end
    end
    if ok then S.sel.h0 = t.heading end
    S.lastSend = S.clock
    if ok then
        S.lastSent = { id = S.sel.id, pos = t.pos, heading = t.heading, scale = t.scale, at = S.clock }
        -- still dragging: keep going with the next place
        S.dirty = false
    elseif BUSY[why] then
        -- the game is still busy: wait for the next free slot (every try counts toward its 4 a second)
    else
        reskate.log("Quick Drop helper: the game refused the change: " .. tostring(why), "warn")
        if string.find(tostring(why), "not installed", 1, true) then
            local first = S.blocked == nil
            S.blocked = tostring(why):match("installed:%s*(%S+)") or "?"
            if first then pcall(findMissing, S.blocked) end
            local n = S.missing and #S.missing or 0
            say(n > 0 and string.format("Park locked: %d object(s) from a missing mod. See the F6 panel.", n)
                or "Park locked: an object from a missing mod. See the F6 panel.", S.clock - (S.lastWarn or -1e9) > 5000)
        else
            say("Could not change it: " .. tostring(why), S.clock - (S.lastWarn or -1e9) > 5000)
        end
        S.lastWarn = S.clock
        S.dirty = false
    end
end

local function markUndo()
    if S.target then
        table.insert(S.undo, { id = S.sel.id, pos = S.target.pos, heading = S.target.heading, scale = S.target.scale })
        if #S.undo > 100 then table.remove(S.undo, 1) end
    end
end

local function undo()
    local u = table.remove(S.undo)
    if not u then say("Nothing to undo.") return end
    if not S.sel or S.sel.id ~= u.id then
        for _, o in ipairs(reskate.objects.list()) do if o.id == u.id then select(o) end end
    end
    if S.sel and S.sel.id == u.id then
        S.target = { pos = u.pos, heading = u.heading, scale = u.scale }
        S.dirty = true
    end
end

-- ---------------------------------------------------------------- the view
local function camGlide(sec)
    local c = S.cam
    c.goal = c.goal or c.target
    c.goalDist = c.goalDist or c.dist
    local k = 1 - math.exp(-sec * 14)
    c.target = c.target + (c.goal - c.target) * k
    c.dist = c.dist + (c.goalDist - c.dist) * k
end

local function camBasis()
    local c = S.cam
    local f = V(math.sin(c.yaw) * math.cos(c.pitch), math.sin(c.pitch), math.cos(c.yaw) * math.cos(c.pitch))
    local r = norm(cross(f, V(0, 1, 0)))
    local u = cross(r, f)
    return c.target - f * c.dist, f, r, u
end

local function rayAt(px)
    local pos, f, r, u = camBasis()
    local w, h = S.size.x, S.size.y
    local my = (h / 2) / math.tan(math.rad(S.cam.fov) / 2)
    local mx = my
    return pos, norm(f + r * ((px.x - w / 2) / mx) + u * ((h / 2 - px.y) / my))
end

local function planeHit(o, d, at, n)
    local den = dot(d, n)
    if math.abs(den) < 1e-5 then return nil end
    local t = dot(at - o, n) / den
    if t <= 0 or t > 3000 then return nil end
    return o + d * t
end

-- ---------------------------------------------------------------- snapping to other objects
-- The game says where a placed object is, how it is turned and its size factor, but not how big it is. Its size
-- comes from the box of its model (reskate.entities.bounds of the blueprint a ray finds on it), remembered per
-- item. An object with no known size snaps by its own point only.
local UP = V(0, 1, 0)
local SNAP_REACH = 4     -- metres past the boxes within which sides line up
local SNAP_TOUCH = 0.5   -- metres apart sideways at most for two sides to meet
local SNAP_MAX = 12      -- nearest objects looked at
local SNAP_TURN = math.rad(5)

local function boxLog(text)
    if S.boxLogged < 40 then S.boxLogged += 1; reskate.log("Quick Drop helper: snap: " .. text) end
end

-- Sizes known before any measuring: the Object Maker's objects (sizes.lua beside this file, measured from their
-- models: item = { wide, high, deep }, standing on its base, centred), then every object this plugin has
-- measured before (kept between launches, so each item is measured once).
S.exact, S.saved, S.exactBox = {}, {}, {}
local function loadSizes()
    local ok, t = pcall(function() return require("sizes") end)
    local n, m = 0, 0
    if ok and type(t) == "table" then
        for item, d in pairs(t) do
            if type(d) == "table" and tonumber(d[1]) and tonumber(d[2]) and tonumber(d[3]) then
                S.itemBox[item] = { V(-d[1] / 2, 0, -d[3] / 2), V(d[1] / 2, d[2], d[3] / 2) }
                S.exactBox[item] = S.itemBox[item]
                S.exact[item] = true
                n += 1
            end
        end
    end
    local ok2, st = pcall(reskate.storage.get, "sizes")
    if ok2 and type(st) == "table" then
        for item, d in pairs(st) do
            if type(d) == "table" and #d == 6 then
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
local function saveSize(item, a, b, fitted)
    if S.exact[item] and not fitted then return end
    S.saved[item] = { r3(a.x), r3(a.y), r3(a.z), r3(b.x), r3(b.y), r3(b.z) }
    local ok, err = pcall(reskate.storage.set, "sizes", S.saved)
    if not ok then boxLog("size not kept: " .. tostring(err)) end
end
local function forgetSize(item)
    if S.exact[item] and not S.saved[item] then return false end
    S.saved[item] = nil
    pcall(reskate.storage.set, "sizes", S.saved)
    S.itemBox[item], S.boxTries[item], S.boxNext[item] = S.exactBox[item], nil, nil
    if S.measure and S.measure.o.item == item then S.measure = nil end
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
    saveSize(o.item, a, b)
    boxLog(string.format("%s is %.2f x %.2f x %.2f m", titleOf(o.item), b.x - a.x, b.y - a.y, b.z - a.z))
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
        for _ = 1, 16 do
            if math.abs(b - a) <= 0.003 then break end
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
        for _, q in ipairs(reskate.objects.list()) do now[q.id] = q end
        if not stillThere(o, now) then S.boxNext[o.item] = S.clock + 800 return end
        S.itemBox[o.item] = { lo, hi }
        saveSize(o.item, lo, hi)
        boxLog(string.format("%s measured: %.2f x %.2f x %.2f m (%d rays)", titleOf(o.item), hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, rays or 0))
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
    for _, o in pairs(S.known) do
        if S.itemBox[o.item] == nil and S.clock >= (S.boxNext[o.item] or 0) then
            local d = len(o.position - S.target.pos)
            local mine = S.sel and o.id == S.sel.id
            if d < bd and not (mine and (moving or d > 0.05)) then best, bd = o, d end
        end
    end
    if not best then return end
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

-- Moves pos so the picked object's box meets or lines up with the boxes of the objects near it.
-- allow(direction, metres) answers how such a move may be made for the handle in use: the move as a vector and
-- the direction it goes along, or nil when that handle cannot go that way.
-- Returns the place, and what it snapped to (a list of { o, nb, kind }) or nil.
local function objSnap(pos, heading, scale, allow)
    if not (S.osnap and S.sel and S.known) then return pos, nil end
    local thr = clamp(S.cam.dist * 0.03, 0.12, 0.5)
    local me = worldBox(S.sel.item, pos, heading, scale)
    local mc = cornersOf(me)
    local reach = SNAP_REACH + len(me.hi - me.lo)
    local near = {}
    for id, o in pairs(S.known) do
        if id ~= S.sel.id then
            local d = len(o.position - pos)
            local b = S.itemBox[o.item]
            if d < reach + (b and len((b[2] - b[1]) * (o.scale or 1)) or 0) then near[#near + 1] = { o = o, d = d } end
        end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    local cands = {}
    for i = 1, math.min(#near, SNAP_MAX) do
        local o = near[i].o
        local nb = worldBox(o.item, o.position, o.heading or 0, o.scale or 1)
        local axes = { nb.ax, UP, nb.az }
        local nlo, nhi = { nb.lo.x, nb.lo.y, nb.lo.z }, { nb.hi.x, nb.hi.y, nb.hi.z }
        -- the picked object's box, measured along this object's directions
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
            ov[k] = math.min(mhi[k], nhi[k]) - math.max(mlo[k], nlo[k])   -- how far the two overlap along it
        end
        for k = 1, 3 do
            local g = math.max(gap[k % 3 + 1], gap[(k + 1) % 3 + 1])   -- how far apart the two are sideways
            local opts = {}
            -- a real side against side (they overlap across the other two ways), not just corner to corner
            local face = math.min(ov[k % 3 + 1], ov[(k + 1) % 3 + 1]) > 0.02
            if g <= SNAP_TOUCH then
                opts[#opts + 1] = { nhi[k] - mlo[k], "touch", axes[k] * -1 }
                opts[#opts + 1] = { nlo[k] - mhi[k], "touch", axes[k] }
            end
            if g <= SNAP_REACH then
                opts[#opts + 1] = { nlo[k] - mlo[k], "level" }
                opts[#opts + 1] = { nhi[k] - mhi[k], "level" }
            end
            for _, op in ipairs(opts) do
                if math.abs(op[1]) <= thr then
                    local mv, dir = allow(axes[k], op[1])
                    -- sides that really meet come first, then lining up, then corners that only just meet
                    local rank = (op[2] == "touch" and face) and 0 or (op[2] == "level" and 1 or 2)
                    if mv then cands[#cands + 1] = { mv = mv, dir = dir, cost = len(mv), rank = rank, o = o, nb = nb, kind = op[2], n = op[3] } end
                end
            end
        end
    end
    if #cands == 0 then return pos, nil end
    table.sort(cands, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.cost < b.cost
    end)
    -- the nearest snap, then others that go squarely across it (so each one stays exact)
    local picked, out = {}, pos
    for _, c in ipairs(cands) do
        local ok = true
        for _, q in ipairs(picked) do
            if math.abs(dot(c.dir, q.dir)) > 0.05 then ok = false break end
        end
        if ok then
            picked[#picked + 1] = c
            out = out + c.mv
            if #picked == 3 then break end
        end
    end
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
local function allowIn(n)      -- a square: only across its plane
    return function(ax, m)
        if math.abs(dot(ax, n)) > 0.05 then return nil end
        return ax * m, ax
    end
end
local function allowFree(level, updown)   -- the controller: the ways it is being moved right now
    return function(ax, m)
        local vertical = math.abs(ax.y) > 0.5
        if (vertical and not updown) or (not vertical and not level) then return nil end
        return ax * m, ax
    end
end

-- turning: the same way as the nearest object, or square to it
local function turnSnap(hd)
    if not (S.osnap and S.sel and S.known and S.target) then return hd, nil end
    local best, bd = nil, SNAP_REACH + 4
    for id, o in pairs(S.known) do
        if id ~= S.sel.id then
            local d = len(o.position - S.target.pos)
            if d < bd then best, bd = o, d end
        end
    end
    if not best then return hd, nil end
    local bh = best.heading or 0
    local rel = wrap(hd - bh)
    local k = round(rel, math.pi / 2)
    if math.abs(rel - k) > SNAP_TURN then return hd, nil end
    return wrap(bh + k), { { o = best, nb = worldBox(best.item, best.position, bh, best.scale or 1), kind = "turn" } }
end

-- snapping must never get in the way of moving: on a fault the place is left as it was (said once in the log)
local function snapTo(pos, heading, scale, allow)
    local ok, p, g = pcall(objSnap, pos, heading, scale, allow)
    if ok then return p, g end
    if not S.snapWarned then S.snapWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(p), "warn") end
    return pos, nil
end
-- Moving with a turn: when the picked object comes to meet a nearby object that is turned differently, it
-- takes that object's turn (or the nearest quarter turn of it) so the two sides meet flat. base is the turn it
-- had when the move began, so pulling it away again gives that turn back.
local function alignSnap(pos, base, scale, allow)
    local p1, g1 = objSnap(pos, base, scale, allow)
    if not (S.osnap and S.sel and S.known) then return p1, base, g1 end
    local near = {}
    for id, o in pairs(S.known) do
        if id ~= S.sel.id and S.itemBox[o.item] then
            local rel = wrap(base - (o.heading or 0))
            local k = round(rel, math.pi / 2)
            if math.abs(rel - k) > 1e-3 then
                local b = S.itemBox[o.item]
                local d = len(o.position - pos) - len((b[2] - b[1]) * (o.scale or 1)) / 2
                if d < SNAP_REACH + 2 then near[#near + 1] = { o = o, d = d, hd = wrap((o.heading or 0) + k) } end
            end
        end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#near, 3) do
        local n = near[i]
        local p2, g2 = objSnap(pos, n.hd, scale, allow)
        for _, q in ipairs(g2 or {}) do
            if q.o.id == n.o.id and q.kind == "touch" then
                table.insert(g2, { o = n.o, nb = q.nb, kind = "turn" })
                return p2, n.hd, g2
            end
        end
    end
    return p1, base, g1
end
local function snapTurned(pos, base, scale, allow)
    local ok, p, h, g = pcall(alignSnap, pos, base, scale, allow)
    if ok then return p, h, g end
    if not S.snapWarned then S.snapWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(p), "warn") end
    return pos, base, nil
end
local function turnTo(hd)
    local ok, h, g = pcall(turnSnap, hd)
    if ok then return h, g end
    if not S.snapWarned then S.snapWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(h), "warn") end
    return hd, nil
end

-- ---------------------------------------------------------------- closing the last gap
-- Sizes are boxes (rounded, measured, or from a copy of the project), so two objects that "touch" can still be
-- a few millimetres apart, or into each other. After a snap that touched, once the game has put the object
-- there, rays straight down across each seam find where the two objects really end, and the picked object is
-- moved by the smallest gap found so the two meet. Works the same for any object the rays can hit.
local TIGHT_RAYS = 24
local function armTighten(guides)
    local list = {}
    for _, g in ipairs(guides or {}) do
        if g.kind == "touch" and g.n and math.abs(g.n.y) < 0.5 then
            local dup = false
            for _, q in ipairs(list) do
                if q.id == g.o.id and dot(q.n, g.n) > 0.9 then dup = true end
            end
            if not dup then list[#list + 1] = { id = g.o.id, n = g.n } end
        end
    end
    if #list > 0 and S.sel then
        S.tighten = { id = S.sel.id, touches = list, at = S.clock, pass = 1 }
    else
        S.tighten = nil
    end
end

-- moves one side of an item's outline by delta metres outward (world direction d), when d is square to it
local function fitSide(o, d, delta)
    if math.abs(delta) < 0.001 or math.abs(delta) > 0.1 then return end
    local b = S.itemBox[o.item]
    if not b then return end
    local h, sc = o.heading or 0, o.scale or 1
    if sc <= 0 then sc = 1 end
    local ax, az = V(math.cos(h), 0, -math.sin(h)), V(math.sin(h), 0, math.cos(h))
    local lo, hi = b[1], b[2]
    local cx, cz, k = dot(d, ax), dot(d, az), delta / sc
    if cx > 0.999 then hi = V(hi.x + k, hi.y, hi.z)
    elseif cx < -0.999 then lo = V(lo.x - k, lo.y, lo.z)
    elseif cz > 0.999 then hi = V(hi.x, hi.y, hi.z + k)
    elseif cz < -0.999 then lo = V(lo.x, lo.y, lo.z - k)
    else return end
    if hi.x - lo.x < 0.02 or hi.z - lo.z < 0.02 then return end
    S.itemBox[o.item] = { lo, hi }
    saveSize(o.item, lo, hi, true)
    boxLog(string.format("outline of %s fitted %+.0f mm", titleOf(o.item), delta * 1000))
end

local function tightenJob(job, me, objs)
    local p = me.position
    local myBox = worldBox(me.item, p, me.heading or 0, me.scale or 1)
    local function ray(q, top, bottom, nbPos)
        if S.tRays >= TIGHT_RAYS or os.clock() - S.tT0 > 0.002 then coroutine.yield() end
        S.tRays += 1
        local ok, hit = pcall(reskate.world.pick, V(q.x, top, q.z), V(q.x, bottom, q.z))
        if not ok then coroutine.yield(); S.tRays += 1; ok, hit = pcall(reskate.world.pick, V(q.x, top, q.z), V(q.x, bottom, q.z)) end
        local ho = ok and type(hit) == "table" and hit.object or nil
        if not (ho and ho.position) then return nil end
        if len(ho.position - p) < 0.01 then return "me" end
        if len(ho.position - nbPos) < 0.01 then return "nb" end
        return nil
    end
    local corr, said = V(0, 0, 0), {}
    for _, tc in ipairs(job.touches) do
        local nbo = objs[tc.id]
        if nbo and S.itemBox[nbo.item] ~= nil then
            local n = vnorm(V(tc.n.x, 0, tc.n.z))
            local tg = V(-n.z, 0, n.x)
            local nb = worldBox(nbo.item, nbo.position, nbo.heading or 0, nbo.scale or 1)
            local mc, nc = cornersOf(myBox), cornersOf(nb)
            local function span(cs, ax)
                local lo, hi = math.huge, -math.huge
                for _, c in ipairs(cs) do local v = dot(c - p, ax); lo = math.min(lo, v); hi = math.max(hi, v) end
                return lo, hi
            end
            local a1, b1 = span(mc, tg)
            local a2, b2 = span(nc, tg)
            local u0, u1 = math.max(a1, a2), math.min(b1, b2)
            local _, s0 = span(mc, n)
            local top = p.y + math.max(myBox.hi.y, (nbo.position.y - p.y) + nb.hi.y) + 3
            local bottom = math.min(p.y + myBox.lo.y, nbo.position.y + nb.lo.y) - 1
            local gaps, edges = {}, {}
            if u1 - u0 > 0.04 then
                for _, f in ipairs({ 0.08, 0.3, 0.5, 0.7, 0.92 }) do
                    local u = u0 + (u1 - u0) * f
                    local function at(sv) return p + tg * u + n * sv end
                    local function cls(sv) return ray(at(sv), top, bottom, nbo.position) end
                    -- a point on the picked object, near its side
                    local a = nil
                    for _, w in ipairs({ 0.04, 0.12, 0.3 }) do
                        if cls(s0 - w) == "me" then a = s0 - w break end
                    end
                    local b = s0 + 0.35
                    if a and cls(b) ~= "me" then
                        for _ = 1, 12 do
                            if b - a <= 0.0015 then break end
                            local m = (a + b) / 2
                            if cls(m) == "me" then a = m else b = m end
                        end
                        local myEdge = (a + b) / 2
                        -- a point on the other object, past the seam
                        local d = nil
                        for _, w in ipairs({ 0.01, 0.05, 0.15, 0.35 }) do
                            if cls(myEdge + w) == "nb" then d = myEdge + w break end
                        end
                        if d then
                            local c = myEdge
                            for _ = 1, 12 do
                                if d - c <= 0.0015 then break end
                                local m = (c + d) / 2
                                if cls(m) == "nb" then d = m else c = m end
                            end
                            gaps[#gaps + 1] = (c + d) / 2 - myEdge
                            edges[#edges + 1] = { myEdge, (c + d) / 2 }
                        end
                    end
                end
            end
            if #edges >= 2 then
                -- the outlines are moved onto the real sides found, so they show (and snap by) the objects
                local mine, theirs = -math.huge, math.huge
                for _, e in ipairs(edges) do mine = math.max(mine, e[1]); theirs = math.min(theirs, e[2]) end
                local nlo = span(nc, n)
                fitSide(me, n, mine - s0)
                fitSide(nbo, n * -1, nlo - theirs)
            end
            if #gaps >= 2 then
                local g = math.huge
                for _, v in ipairs(gaps) do g = math.min(g, v) end
                local mm = {}
                for _, v in ipairs(gaps) do mm[#mm + 1] = string.format("%.0f", v * 1000) end
                if math.abs(g) > 0.0015 and g < 0.35 then
                    corr += n * g
                    said[#said + 1] = string.format("%s %.0f mm (seam %s mm)", titleOf(nbo.item), g * 1000, table.concat(mm, ","))
                end
            end
        end
    end
    return corr, said
end

local function stepTighten()
    local j = S.tighten
    if not j then return end
    if not (S.sel and S.sel.id == j.id and S.target and S.osnap) then S.tighten = nil return end
    if (S.drag and S.drag.moved) or S.padMoving then S.tighten = nil return end
    if not j.co then
        if S.dirty or S.clock - j.at < 350 or not lastApplied() then return end
        local objs = {}
        for _, o in ipairs(reskate.objects.list()) do objs[o.id] = o end
        local me = objs[j.id]
        if not me or len(me.position - S.target.pos) > 0.002 then return end
        j.co = coroutine.create(tightenJob)
        j.me, j.objs = me, objs
    end
    S.tRays, S.tT0 = 0, os.clock()
    local ok, corr, said = coroutine.resume(j.co, j, j.me, j.objs)
    if not ok then
        S.tighten = nil
        boxLog("closing the gap failed: " .. tostring(corr))
        return
    end
    if coroutine.status(j.co) ~= "dead" then return end
    if corr and len(corr) > 0.0015 and len(corr) < 0.4 then
        S.target.pos += corr
        S.dirty = true
        S.lastSend = math.min(S.lastSend, S.clock - 250)
        boxLog("closed the gap: " .. table.concat(said, "; "))
        if j.pass < 2 then
            S.tighten = { id = j.id, touches = j.touches, at = S.clock, pass = j.pass + 1 }
            return
        end
    end
    S.tighten = nil
end

local function clickPick(px)
    local o, d = rayAt(px)
    local hit = reskate.world.pick(o, o + d * 300)
    if not hit then return end
    local at = (hit.object and hit.object.position) or hit.position
    local best, bd = nil, hit.object and 1.5 or 0
    for _, ob in ipairs(reskate.objects.list()) do
        local dd = len(ob.position - at)
        if dd < bd then best, bd = ob, dd end
    end
    if not best and hit.object then
        bd = 6
        for _, ob in ipairs(reskate.objects.list()) do
            local dd = len(ob.position - hit.position)
            if dd < bd then best, bd = ob, dd end
        end
    end
    if best then
        send()
        select(best, hit.object and hit.object.blueprint)
        say("Picked " .. titleOf(best.item))
    elseif hit.object then
        say("That is part of the map: only placed objects can be changed.")
    end
end

-- set later, with the controller code
local padCaptureOn, padCaptureOff = function() end, function() end

local function openEditor()
    if S.open then return end
    local v = reskate.camera.get()
    if v then
        local f = v.forward
        S.cam.yaw = math.atan2(f.x, f.z)
        S.cam.pitch = clamp(math.asin(clamp(f.y, -1, 1)), -1.45, 1.45)
        S.cam.fov = v.fov or 60
        if S.target then
            S.cam.dist = clamp(len(S.target.pos - v.position), 3, 30)
            S.cam.target = S.target.pos
            -- keep the camera where it is, looking at the object
            local d = norm(S.target.pos - v.position)
            S.cam.yaw = math.atan2(d.x, d.z)
            S.cam.pitch = clamp(math.asin(clamp(d.y, -1, 1)), -1.45, 1.45)
        else
            local hit = reskate.world.raycast(v.position, v.position + f * 40)
            S.cam.dist = hit and clamp(len(hit - v.position), 3, 40) or 10
            S.cam.target = v.position + f * S.cam.dist
        end
    end
    S.cam.goal, S.cam.goalDist = S.cam.target, S.cam.dist
    S.open = true
    S.drag = nil
    S.mouse = { pos = nil, left = false }
    S.padWait, S.padBurst, S.padMoving, S.padRep, S.padHeld = true, false, false, {}, {}
    reskate.ui.open(TITLE)
    padCaptureOn()
end

local function closeEditor()
    if not S.open then return end
    if S.typing then S.typing = false; pcall(reskate.ui.close_dialog, "ddh_type") end
    S.drag = nil
    S.open = false
    padCaptureOff()
    reskate.camera.release()
    reskate.ui.close()
end

reskate.input.bind("ddh_quickdrop_plus", "F6")
do
    local ok, why = pcall(reskate.input.bind, "ddh_quickdrop_plus_pad", "Pad.LB+Pad.RB")
    if not ok then reskate.log("Quick Drop helper: could not bind LB+RB: " .. tostring(why), "warn") end
end
reskate.on("action", function(name)
    if name == "ddh_quickdrop_plus" or name == "ddh_quickdrop_plus_pad" then openEditor() end
end)
reskate.on("screen_closed", function(title) if title == TITLE and S.open then S.open = false; S.drag = nil; padCaptureOff(); reskate.camera.release() end end)
reskate.on("unload", function() padCaptureOff(); if S.open then reskate.camera.release() end end)
reskate.on("level_loaded", function()
    S.listKey = nil; S.known = nil; S.blocked = nil; S.missing = nil; S.confirmRemove = nil; select(nil)
    -- sizes stay known; the items the game gave none for get another try on this map
    for k, v in pairs(S.itemBox) do if v == false then S.itemBox[k] = nil end end
    S.boxTries, S.boxNext = {}, {}
    S.measure = nil
end)

-- typing exact numbers: a text box with "X Y Z turn size"; change any of them
local TYPE_ID = "ddh_type"
local function openTyping()
    if not (S.sel and S.target) then return end
    local t = S.target
    local text = string.format("%.3f  %.3f  %.3f  %.1f  %.2f", t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale)
    local ok, why = pcall(reskate.ui.dialog, TYPE_ID, {
        title = "Type numbers",
        message = "X  Y  Z  Turn  Size, with spaces between.\nChange any of them, then Enter.\nTip: start a number with + to add to it: +2 moves 2 m, +-0.5 moves back 0.5 m.",
        field = { text = text, max = 120 },
        buttons = { { id = "apply", label = "Apply" }, { id = "close", label = "Cancel" } },
    })
    if not ok or why == false then say("Could not open the text box" .. (ok and "" or (": " .. tostring(why))), true) else S.typing = true end
end
local function parseTyped(str)
    local t = S.target
    local cur = { t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale }
    local out, i = {}, 0
    local clean = string.gsub(str, ",", " ")
    for w in string.gmatch(clean, "%S+") do
        i += 1
        if i > 5 then break end
        local v = tonumber(w:sub(1, 1) == "+" and w:sub(2) or w)
        if v == nil then return nil, "\"" .. w .. "\" is not a number" end
        if w:sub(1, 1) == "+" then v = cur[i] + v end
        out[i] = v
    end
    if i == 0 then return nil, "nothing typed" end
    for k = 1, 5 do if out[k] == nil then out[k] = cur[k] end end
    return out
end
reskate.on("throwdown_ui", function(e)
    if e.action ~= "dialog" or e.args[1] ~= TYPE_ID then return end
    local what = e.args[2]
    if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
    S.typing = false
    if what ~= "cancel" then pcall(reskate.ui.close_dialog, TYPE_ID) end
    if what ~= "apply" then return end
    if not (S.sel and S.target) then return end
    local v, err = parseTyped(e.args[3] or "")
    if not v then say("Typed numbers: " .. err, true); return end
    markUndo()
    local t = S.target
    t.pos = V(v[1], v[2], v[3])
    t.heading = wrap(math.rad(v[4]))
    t.scale = clamp(v[5], 0.1, 10)
    S.sel.anchor = t.pos
    S.dirty = true
    say(string.format("Set to %.2f, %.2f, %.2f  ·  %.1f°  ·  %.2f×", t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale))
end)

-- the old panel (ReSkate 2.1.3 and older)
local function oldPanel(ui)
    if S.sel then
        local t = S.target
        ui:card(titleOf(S.sel.item), string.format("%.2f, %.2f, %.2f   ·   %.0f°   ·   %.2f×", t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale))
    else
        ui:card("Nothing picked", "Click an object, or drop one with Quick Drop")
    end
    if S.sel and S.target then
        local t = S.target
        local a = S.sel.anchor
        if not a or len(t.pos - a) > 9 then a = t.pos; S.sel.anchor = a end
        local function num(id, label, val, lo, hi, fmt)
            local v = ui:slider(id, label, val, lo, hi, fmt)
            return v ~= nil and math.abs(v - val) > 1e-4 and v or nil
        end
        ui:heading("Position")
        local x = num("px", "X", t.pos.x, a.x - 10, a.x + 10, "%.3f m")
        local y = num("py", "Y", t.pos.y, a.y - 10, a.y + 10, "%.3f m")
        local z = num("pz", "Z", t.pos.z, a.z - 10, a.z + 10, "%.3f m")
        if x or y or z then
            if not S.sliding then markUndo(); S.sliding = true end
            t.pos = V(x or t.pos.x, y or t.pos.y, z or t.pos.z); S.dirty = true
        end
        ui:heading("Turn")
        local ty = num("ry", "Y", math.deg(t.heading), -180, 180, "%.1f°")
        if ty then
            if not S.sliding then markUndo(); S.sliding = true end
            t.heading = wrap(math.rad(ty)); S.dirty = true
        end
        ui:note("X and Z (tilt): the game only turns placed objects about Y.")
        local sz = num("sz", "Size", t.scale, 0.1, 10, "%.2f×")
        if sz then
            if not S.sliding then markUndo(); S.sliding = true end
            t.scale = sz; S.dirty = true
        end
        if not (x or y or z or ty or sz) then S.sliding = false end
        ui:separator()
    end
    local m = ui:tabs("mode", { "Move (W)", "Turn (E)", "Size (R)" }, S.mode)
    if m and m ~= S.mode then S.mode = m end
    local sn = ui:toggle("snap", "Steps: 0.25 m, 15°, 0.1 (G)", S.snap)
    if sn ~= nil then S.snap = sn end
    local ob = ui:toggle("osnap", "Snap to objects (T)", S.osnap)
    if ob ~= nil then S.osnap = ob end
    if S.osnap and S.sel and S.itemBox[S.sel.item] and (S.saved[S.sel.item] or not S.exact[S.sel.item]) then
        if ui:button("remeasure", "Measure it again") then
            forgetSize(S.sel.item)
            say("Measuring " .. titleOf(S.sel.item) .. " again: keep it still a moment")
        end
    end
    ui:separator()
    if ui:button("undo", "Undo (Ctrl+Z)") then undo() end
    if ui:button("straight", "Straighten and size 1") and S.target then
        markUndo(); S.target.heading = round(S.target.heading, math.pi / 2); S.target.scale = 1; S.dirty = true
    end
    if ui:button("focus", "Look at it (F)") and S.target then S.cam.goal = S.target.pos end
    local miss = S.missing or {}
    if S.blocked or #miss > 0 then
        ui:separator()
        ui:heading("Park locked")
        ui:warn("The game won't change this park.")
        ui:note("It has objects from a mod that is")
        ui:note("off, not installed, or rebuilt with")
        ui:note("new object names.")
        if S.blocked and S.blocked ~= "?" then ui:info("Game says", S.blocked) end
        for i, o in ipairs(miss) do
            if i > 8 then ui:note(string.format("...and %d more (all in ReSkate.log)", #miss - 8)) break end
            ui:info(titleOf(o.item), string.format("%.0f, %.0f, %.0f", o.position.x, o.position.y, o.position.z))
            if ui:button("go" .. i, "Look at it") then S.cam.goal = o.position end
        end
        ui:note("To clean them out: close the game,")
        ui:note("then run \"Clean out park.exe\"")
        ui:note("(MOD SKATE\\DDH_Park_Editor).")
        if ui:button("recheck", "Check again") then
            S.blocked = nil
            pcall(findMissing)
            if #(S.missing or {}) == 0 then say("No missing objects found. Try moving something again.") end
        end
    end
    if S.msg ~= "" and S.clock < S.msgUntil then ui:note(S.msg) end
    ui:separator()
    local h = ui:toggle("help", "Show the controls", S.help or false)
    if h ~= nil then S.help = h end
    if S.help then
        ui:info("Click", "pick an object")
        ui:info("Drag a handle", "move / turn / size")
        ui:info("Drag empty space", "turn the view")
        ui:info("Right-drag", "slide the view")
        ui:info("Scroll", "zoom")
        ui:info("Arrows, PgUp, PgDn", "fly the view")
        ui:info("Shift", "bigger steps")
        ui:info("Controller", "LB+RB opens, B closes")
        ui:info("Left stick", "slide it")
        ui:info("RT / LT", "raise / lower")
        ui:info("LB / RB", "turn")
        ui:info("D-pad up / down", "size")
        ui:info("D-pad left / right", "pick another object")
        ui:info("Right stick", "turn the view (hold Y: zoom)")
        ui:info("R3", "look at it")
        ui:info("A / View", "snap / undo")
        ui:info("Hold X", "fine steps")
    end
    if ui:button("close", "Done (Esc)", true) then closeEditor() end
end

-- ---------------------------------------------------------------- the new panel (ReSkate 2.1.4 widgets)
-- step sizes for the steppers: metres, degrees, size
local STEPS = {
    { m = 0.01, deg = 1, size = 0.01, name = "Fine", mf = "%.2f m", df = "%.0f°", sf = "%.2f×" },
    { m = 0.1, deg = 15, size = 0.1, name = "Normal", mf = "%.2f m", df = "%.0f°", sf = "%.2f×" },
    { m = 1, deg = 45, size = 0.5, name = "Big", mf = "%.1f m", df = "%.0f°", sf = "%.1f×" },
}
S.stepSize = 2
S.sec = { move = true, handles = false, objects = true, locked = true, help = false }
S.search, S.listFilter = "", 1
S.listAt, S.listKey = -1e9, nil
S.listObjs, S.listItems, S.listTotal = {}, {}, 0

local function section(ui, id, title, sub)
    local o = ui:section(id, title, sub, S.sec[id])
    if o ~= nil then S.sec[id] = o end
    return S.sec[id]
end

-- a number box: click it and type. What is typed is used once you stop typing for a moment.
-- "12.5" sets it, "+2" adds 2, "+-0.5" takes 0.5 off; a comma works as the decimal point too.
local function parseNum(text, cur)
    local s = string.gsub(text, "^%s+", ""):gsub("%s+$", "")
    s = string.gsub(s, ",", ".")
    s = string.gsub(s, "[mx×°]+$", ""):gsub("%s+$", "")
    if s == "" then return nil end
    if string.sub(s, 1, 1) == "+" then
        local v = tonumber(string.sub(s, 2))
        return v and cur + v or nil
    end
    return tonumber(s)
end
S.edit = {}
local function numBox(ui, id, label, val, fmt, apply)
    local shown = string.format(fmt, val)
    local e = S.edit[id]
    local pass = e and e.text or shown
    local q = ui:text(id, label, pass, "")
    if type(q) ~= "string" then return end
    if q ~= pass then
        -- still typing
        S.edit[id] = { text = q, at = S.clock }
        return
    end
    if e and S.clock - e.at > 700 then
        S.edit[id] = nil
        if e.text == shown then return end
        local v = parseNum(e.text, val)
        if v then apply(v) else say(label .. ": \"" .. e.text .. "\" is not a number", true) end
    end
end

-- the list of park objects: rebuilt twice a second, or at once when the search or filter changes
local function rebuildList()
    local key = S.search .. "|" .. S.listFilter .. "|" .. tostring(S.sel and S.sel.id)
    if key == S.listKey and S.clock - S.listAt < 500 then return end
    S.listKey, S.listAt = key, S.clock
    local have = {}
    for _, it in ipairs(reskate.objects.catalog()) do have[it.key] = true end
    local q = string.lower(S.search or "")
    local from = S.cam.target or V(0, 0, 0)
    local rows = {}
    local all = reskate.objects.list()
    S.listTotal = #all
    for _, o in ipairs(all) do
        local title = titleOf(o.item)
        local ok = true
        if q ~= "" then
            ok = string.find(string.lower(title), q, 1, true) or string.find(string.lower(o.item), q, 1, true)
                or string.find(tostring(o.id), q, 1, true)
        end
        local dist = len(o.position - from)
        if ok and S.listFilter == 2 and dist > 30 then ok = false end
        if ok and S.listFilter == 3 and not string.find(string.lower(o.item), "ddh", 1, true) then ok = false end
        if ok then table.insert(rows, { o = o, title = title, dist = dist, missing = not have[o.item] }) end
    end
    if S.listFilter == 2 then
        table.sort(rows, function(a, b) return a.dist < b.dist end)
    else
        table.sort(rows, function(a, b)
            if a.title ~= b.title then return a.title < b.title end
            return tostring(a.o.id) < tostring(b.o.id)
        end)
    end
    S.listObjs, S.listItems, S.listMatched = {}, {}, #rows
    for i, r in ipairs(rows) do
        if i > 200 then break end
        S.listObjs[i] = r.o
        local label = string.format("%s%s  |  %.0f m", r.title, r.missing and " (missing)" or "", r.dist)
        if #label > 80 then label = string.sub(label, 1, 77) .. "..." end
        S.listItems[i] = label
    end
end

local function newPanel(ui)
    local t = S.sel and S.target
    -- what is picked, and the everyday buttons
    if t then
        ui:card(titleOf(S.sel.item), string.format("%.2f, %.2f, %.2f   |   %.0f°   |   %.2fx", t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale))
    else
        ui:card("Nothing picked", "Click an object or pick one in the list")
    end
    if S.msg ~= "" and S.clock < S.msgUntil then ui:note(S.msg) end
    local b = ui:buttons("top", { "Undo", "Look at it" }, 0)
    if b == 1 then undo() end
    if b == 2 and t then S.cam.goal = t.pos end
    if ui:button("close", "Done (Esc)", true) then closeEditor() end

    -- exact numbers: click a box and type; nudge buttons below
    local st = STEPS[S.stepSize]
    if t and section(ui, "move", "Move and turn", "") then
        numBox(ui, "px", "X", t.pos.x, "%.3f", function(v) markUndo(); t.pos = V(v, t.pos.y, t.pos.z); S.dirty = true end)
        numBox(ui, "py", "Y", t.pos.y, "%.3f", function(v) markUndo(); t.pos = V(t.pos.x, v, t.pos.z); S.dirty = true end)
        numBox(ui, "pz", "Z", t.pos.z, "%.3f", function(v) markUndo(); t.pos = V(t.pos.x, t.pos.y, v); S.dirty = true end)
        numBox(ui, "ry", "Turn", math.deg(t.heading), "%.1f", function(v) markUndo(); t.heading = wrap(math.rad(v)); S.dirty = true end)
        numBox(ui, "sz", "Size", t.scale, "%.2f", function(v) markUndo(); t.scale = clamp(v, 0.1, 10); S.dirty = true end)
        ui:heading("Nudge")
        local ss = ui:buttons("stepsize", { "Fine", "Normal", "Big" }, S.stepSize)
        if ss and STEPS[ss] then S.stepSize = ss; st = STEPS[ss] end
        local n = ui:buttons("nudge", { "X -", "X +", "Y -", "Y +", "Z -", "Z +" }, 0)
        if n then
            markUndo()
            local d = ({ V(-1, 0, 0), V(1, 0, 0), V(0, -1, 0), V(0, 1, 0), V(0, 0, -1), V(0, 0, 1) })[n]
            if d then t.pos = t.pos + d * st.m; S.dirty = true; S.edit = {} end
        end
        local n2 = ui:buttons("nudge2", { "Turn -", "Turn +", "Size -", "Size +", "Straighten", "Size 1" }, 0)
        if n2 then
            markUndo()
            if n2 == 1 then t.heading = wrap(t.heading - math.rad(st.deg)) end
            if n2 == 2 then t.heading = wrap(t.heading + math.rad(st.deg)) end
            if n2 == 3 then t.scale = clamp(t.scale - st.size, 0.1, 10) end
            if n2 == 4 then t.scale = clamp(t.scale + st.size, 0.1, 10) end
            if n2 == 5 then t.heading = round(t.heading, math.pi / 2) end
            if n2 == 6 then t.scale = 1 end
            S.dirty = true; S.edit = {}
        end
    end

    -- the handles in the view
    local modes = { "Move (W)", "Turn (E)", "Size (R)" }
    if section(ui, "handles", "Handles", modes[S.mode] .. (S.snap and "  |  steps" or "") .. (S.osnap and "  |  objects" or "")) then
        local m = ui:buttons("mode", modes, S.mode)
        if m and m ~= S.mode then S.mode = m end
        local sn = ui:toggle("snap", "Steps (G)", S.snap)
        if sn ~= nil then S.snap = sn end
        local ob = ui:toggle("osnap", "Snap to objects (T)", S.osnap)
        if ob ~= nil then S.osnap = ob end
    end

    -- every object in the park
    rebuildList()
    local sub = tostring(S.listTotal)
    if S.search ~= "" or S.listFilter ~= 1 then sub = string.format("%d / %d", S.listMatched or 0, S.listTotal) end
    if section(ui, "objects", "Objects in this park", sub) then
        local q = ui:text("search", "Search", S.search, "")
        if type(q) == "string" and q ~= S.search then S.search = q; S.listKey = nil end
        local f = ui:buttons("filter", { "All", "Near", "DDH" }, S.listFilter)
        if f and f ~= S.listFilter then S.listFilter = f; S.listKey = nil end
        rebuildList()
        if #S.listItems == 0 then
            ui:note(S.listTotal == 0 and "No objects." or "Nothing found.")
        else
            local cur = 0
            if S.sel then
                for i, o in ipairs(S.listObjs) do if o.id == S.sel.id then cur = i break end end
            end
            local c = ui:list("objlist", "", S.listItems, cur, 8)
            if type(c) == "number" and c > 0 and c ~= cur and S.listObjs[c] then
                local o = S.listObjs[c]
                send()
                select(o)
                S.cam.goal = o.position
                S.listKey = nil
                say("Picked " .. titleOf(o.item))
            end
            if (S.listMatched or 0) > 200 then ui:note("First 200 shown.") end
        end
    end

    -- objects from missing mods
    local miss = S.missing or {}
    if (S.blocked or #miss > 0) and section(ui, "locked", "Park locked", string.format("%d missing", #miss)) then
        ui:warn("The game won't change this park.")
        if S.blocked and S.blocked ~= "?" then ui:info("Game says", S.blocked) end
        for i, o in ipairs(miss) do
            if i > 8 then ui:note(string.format("+%d more", #miss - 8)) break end
            ui:info(titleOf(o.item), string.format("%.0f, %.0f, %.0f", o.position.x, o.position.y, o.position.z))
            if ui:button("go" .. i, "Look at it") then S.cam.goal = o.position end
        end
        ui:note("Fix: Clean out park.exe (game closed)")
        if ui:button("recheck", "Check again") then
            S.blocked = nil
            pcall(findMissing)
            if #(S.missing or {}) == 0 then say("No missing objects found. Try moving something again.") end
        end
    end

    if section(ui, "help", "Controls", "") then
        ui:info("Click", "pick an object")
        ui:info("Drag a handle", "move / turn / size")
        ui:info("Drag empty space", "turn the view")
        ui:info("Right-drag", "slide the view")
        ui:info("Scroll", "zoom")
        ui:info("Arrows, PgUp, PgDn", "fly the view")
        ui:info("W / E / R", "move / turn / size handles")
        ui:info("G", "steps")
        ui:info("T", "snap to objects")
        ui:info("Hold Ctrl", "no snapping while dragging")
        ui:info("F", "look at it")
        ui:info("Ctrl+Z", "undo")
        ui:info("Shift", "bigger steps")
        ui:info("Controller", "LB+RB opens, B closes")
        ui:info("Left stick", "slide it")
        ui:info("RT / LT", "raise / lower")
        ui:info("LB / RB", "turn")
        ui:info("D-pad up / down", "size")
        ui:info("D-pad left / right", "pick another object")
        ui:info("Right stick", "turn the view (hold Y: zoom)")
        ui:info("R3", "look at it")
        ui:info("A / View", "snap / undo")
        ui:info("Hold X", "fine steps")
    end
end

-- which panel: the new one when this ReSkate has the 2.1.4 widgets, otherwise the old one
local function hasNewWidgets(ui)
    local ok, yes = pcall(function()
        return type(ui.stepper) == "function" and type(ui.section) == "function" and type(ui.list) == "function"
            and type(ui.buttons) == "function" and type(ui.text) == "function"
    end)
    return ok and yes
end

reskate.ui.screen(TITLE, function(ui)
    if S.newUI == nil then
        S.newUI = hasNewWidgets(ui)
        reskate.log("Quick Drop helper: " .. (S.newUI and "using the new panel (ReSkate 2.1.4 widgets)." or "this ReSkate has no 2.1.4 widgets; using the old panel."))
    end
    if S.newUI then
        local ok, err = pcall(newPanel, ui)
        if ok then return end
        reskate.log("Quick Drop helper: the new panel failed, going back to the old one: " .. tostring(err), "warn")
        S.newUI = false
        return
    end
    oldPanel(ui)
end, { dock = "right", width = 0.2 })

local function press(k)
    local d = reskate.input.key(k)
    local was = S.held[k]
    S.held[k] = d
    return d and not was
end

-- which handle is under the mouse (from where the last frame drew them)
local function handleAt(px)
    local sc = S.screen
    if not (S.target and sc.center) then return nil end
    if sc.mode ~= S.mode then return nil end
    if S.mode == 1 then
        for i, pl in ipairs(PLANES) do
            if sc.planes and sc.planes[i] and inPoly(px, sc.planes[i]) then return { kind = "plane", plane = i } end
        end
        local best, bd = nil, 16
        for i = 1, 3 do
            if sc.axis and sc.axis[i] then
                local dd = segDist(px, sc.center, sc.axis[i])
                if dd < bd then best, bd = i, dd end
            end
        end
        if best then return { kind = "axis", axis = best } end
    elseif S.mode == 2 then
        local pts = sc.ring or {}
        for i = 1, #pts - 1 do
            if pts[i] and pts[i + 1] and segDist(px, pts[i], pts[i + 1]) < 16 then return { kind = "turn" } end
        end
    else
        for i = 1, 8 do
            if sc.cubes and sc.cubes[i] and d2(px, sc.cubes[i]) < 18 then return { kind = "size" } end
        end
        if d2(px, sc.center) < 18 then return { kind = "size" } end
    end
    return nil
end


-- ---------------------------------------------------------------- the controller
-- Reads the pad through reskate.input.gamepad(). Button names are read from its buttons table (several spellings),
-- or from the XInput bit mask (reskate.input.pad_bits) when the table has none. The first time the editor opens
-- with a pad, what the pad sends is written to ReSkate.log once, so the names can be checked.
local XBITS = { up = 0x0001, down = 0x0002, left = 0x0004, right = 0x0008, start = 0x0010, back = 0x0020,
    ls = 0x0040, rs = 0x0080, lb = 0x0100, rb = 0x0200, a = 0x1000, b = 0x2000, x = 0x4000, y = 0x8000 }
local PADNAMES = {
    a = { "a", "A", "cross", "face_down", "south" },
    b = { "b", "B", "circle", "face_right", "east" },
    x = { "x", "X", "square", "face_left", "west" },
    y = { "y", "Y", "triangle", "face_up", "north" },
    lb = { "lb", "LB", "l1", "left_shoulder", "left_bumper" },
    rb = { "rb", "RB", "r1", "right_shoulder", "right_bumper" },
    up = { "up", "dpad_up", "d_up" },
    down = { "down", "dpad_down", "d_down" },
    left = { "left", "dpad_left", "d_left" },
    right = { "right", "dpad_right", "d_right" },
    start = { "start", "menu", "options" },
    back = { "back", "view", "select", "share" },
    ls = { "left_stick", "ls", "l3", "left_thumb", "left_stick_click" },
    rs = { "right_stick", "rs", "r3", "right_thumb", "right_stick_click" },
}

local function band(a, b)
    if bit32 and bit32.band then return bit32.band(a, b) end
    local r, k = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r += k end
        a, b, k = math.floor(a / 2), math.floor(b / 2), k * 2
    end
    return r
end

local function describe(v, depth)
    depth = depth or 0
    if type(v) ~= "table" or depth > 2 then return tostring(v) end
    local parts = {}
    for k, x in pairs(v) do table.insert(parts, tostring(k) .. "=" .. describe(x, depth + 1)) end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function axis(v, full)
    v = tonumber(v) or 0
    if math.abs(v) > 1.5 then v = v / full end
    return clamp(v, -1, 1)
end

local function readPad()
    if not (reskate.input and reskate.input.gamepad) then return nil end
    local ok, g = pcall(reskate.input.gamepad)
    if not ok then
        if not S.padErr then S.padErr = true; reskate.log("Quick Drop helper: controller read failed: " .. tostring(g), "warn") end
        return nil
    end
    if type(g) ~= "table" then return nil end
    local bits = nil
    local bt = g.buttons
    if type(bt) == "number" then bits = bt end
    if type(bt) ~= "table" and reskate.input.pad_bits then
        local ok2, pb = pcall(reskate.input.pad_bits)
        if ok2 and type(pb) == "number" then bits = bits or pb end
    end
    if not S.padLogged then
        S.padLogged = true
        reskate.log("Quick Drop helper: controller sends " .. describe(g) .. (bits and string.format(" bits=0x%04x", bits) or ""))
    end
    local p = {
        lx = axis(g.left_x, 32767), ly = axis(g.left_y, 32767),
        rx = axis(g.right_x, 32767), ry = axis(g.right_y, 32767),
        lt = clamp(axis(g.left_trigger, 255), 0, 1), rt = clamp(axis(g.right_trigger, 255), 0, 1),
    }
    for key, names in pairs(PADNAMES) do
        local down = false
        if type(bt) == "table" then
            for _, n in ipairs(names) do if bt[n] then down = true break end end
        end
        if not down and bits then down = band(bits, XBITS[key]) ~= 0 end
        p[key] = down
    end
    -- log a pressed button's real name once each, to check the spellings
    if type(bt) == "table" then
        S.padSeen = S.padSeen or {}
        for k, v in pairs(bt) do
            if v == true and not S.padSeen[k] then
                S.padSeen[k] = true
                reskate.log("Quick Drop helper: controller button pressed: " .. tostring(k))
            end
        end
    end
    return p
end

-- radial dead zone, then a curve so small pushes are fine
local function stick(x, y)
    local m = math.sqrt(x * x + y * y)
    if m < 0.2 then return 0, 0 end
    local k = ((math.min(m, 1) - 0.2) / 0.8) ^ 1.6 / m
    return x * k, y * k
end

-- a button that steps once, then repeats while held
local function padStep(key, down)
    S.padRep = S.padRep or {}
    local r = S.padRep[key]
    if not down then S.padRep[key] = nil return false end
    if not r then S.padRep[key] = { next = S.clock + 350 } return true end
    if S.clock >= r.next then r.next = S.clock + 110 return true end
    return false
end

local function padPress(key, down)
    S.padHeld = S.padHeld or {}
    local was = S.padHeld[key]
    S.padHeld[key] = down
    return down and not was
end

local function pickNext(dir)
    local list = reskate.objects.list()
    if #list == 0 then say("No placed objects in this park.") return end
    table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
    local at = 0
    for i, o in ipairs(list) do if S.sel and o.id == S.sel.id then at = i end end
    local i = at + dir
    if i < 1 then i = #list elseif i > #list then i = 1 end
    send()
    select(list[i])
    S.cam.goal = list[i].position
    say(string.format("Picked %s (%d of %d)", titleOf(list[i].item), i, #list))
end

local function padCapture(on)
    if S.padCaptured == on then return end
    if not (reskate.input and reskate.input.capture) then return end
    local ok, why = pcall(reskate.input.capture, on)
    if ok then
        S.padCaptured = on
    elseif on and not S.captureErr then
        S.captureErr = true
        reskate.log("Quick Drop helper: could not keep the controller from the game: " .. tostring(why), "warn")
    end
end

padCaptureOn = function() padCapture(true) end
padCaptureOff = function() padCapture(false) end

-- the open editor with a controller
local function padEditor(sec)
    local p = readPad()
    if not p then return end
    if S.padWait then
        for k in pairs(PADNAMES) do if p[k] then return end end
        if p.lt > 0.3 or p.rt > 0.3 then return end
        S.padWait = false
    end
    local fine = p.x
    local t = S.target

    if padPress("b", p.b) then closeEditor() return end
    if padPress("a", p.a) then S.snap = not S.snap; say(S.snap and "Snap on" or "Snap off") end
    if padPress("back", p.back) then undo() t = S.target end
    if padPress("rs", p.rs) and t then S.cam.goal = t.pos end
    if padStep("left", p.left) then pickNext(-1) t = S.target end
    if padStep("right", p.right) then pickNext(1) t = S.target end

    -- the view: right stick turns it; hold Y and the right stick zooms
    local rx, ry = stick(p.rx, p.ry)
    if p.y then
        if ry ~= 0 then S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (1 - ry * 1.6 * sec), 0.5, 300) end
    else
        S.cam.yaw -= rx * 2.4 * sec
        S.cam.pitch = clamp(S.cam.pitch + ry * 1.6 * sec, -1.45, 1.45)
    end

    if not t then
        local any = math.abs(p.lx) > 0.3 or math.abs(p.ly) > 0.3 or p.lt > 0.3 or p.rt > 0.3 or p.lb or p.rb or p.up or p.down
        if any and S.clock - (S.padHintAt or -1e9) > 4000 then
            S.padHintAt = S.clock
            say("Pick an object first: D-pad left / right.")
        end
        return
    end

    -- the object: one undo step per burst of changes
    local active = false
    local function begin()
        if not S.padBurst then markUndo(); S.padBurst = true end
        active = true
    end

    local _, f, r = camBasis()
    local ff, rr = flat(f), flat(r)
    local lx, ly = stick(p.lx, p.ly)
    local up = p.rt - p.lt
    if math.abs(up) < 0.15 then up = 0 end
    if S.snap then
        S.padRaw = nil
        local step = fine and 0.05 or 0.25
        local function nudge(key, on, v)
            if padStep(key, on) then begin(); t.pos += v * step; S.cam.goal = (S.cam.goal or S.cam.target) + v * step end
        end
        nudge("fwd", p.ly > 0.5, ff); nudge("back_", p.ly < -0.5, ff * -1)
        nudge("rgt", p.lx > 0.5, rr); nudge("lft", p.lx < -0.5, rr * -1)
        nudge("rise", up > 0.5, V(0, 1, 0)); nudge("fall", up < -0.5, V(0, -1, 0))
        if p.ly > 0.5 or p.ly < -0.5 or p.lx > 0.5 or p.lx < -0.5 or math.abs(up) > 0.5 then active = true end
    elseif lx ~= 0 or ly ~= 0 or up ~= 0 then
        begin()
        local sp = (fine and 0.4 or 2.5) * sec
        local mv = (ff * ly + rr * lx) * sp + V(0, up * (fine and 0.25 or 1.5) * sec, 0)
        -- where the stick has taken it, and from that where it snaps to: the stick can always pull it free again
        if not S.padRaw then S.padHd0 = t.heading end
        S.padRaw = (S.padRaw or t.pos) + mv
        t.pos, t.heading, S.guides = snapTurned(S.padRaw, S.padHd0 or t.heading, t.scale, allowFree(lx ~= 0 or ly ~= 0, up ~= 0))
        S.cam.goal = (S.cam.goal or S.cam.target) + mv
        S.cam.target += mv
    else
        if S.padRaw then armTighten(S.guides); S.guides = nil end
        S.padRaw = nil
    end

    -- turn: bumpers, 15 degrees (X held: 1)
    local tstep = math.rad(fine and 1 or 15)
    if padStep("lb", p.lb) then begin(); t.heading = wrap(round(t.heading + tstep, tstep)) end
    if padStep("rb", p.rb) then begin(); t.heading = wrap(round(t.heading - tstep, tstep)) end
    if p.lb or p.rb then active = true end
    if (p.lb or p.rb) and S.padRaw then S.padHd0 = t.heading end

    -- size: D-pad up / down, 0.1 (X held: 0.01)
    local sstep = fine and 0.01 or 0.1
    if padStep("up", p.up) then begin(); t.scale = clamp(round(t.scale + sstep, sstep), 0.1, 10) end
    if padStep("down", p.down) then begin(); t.scale = clamp(round(t.scale - sstep, sstep), 0.1, 10) end
    if p.up or p.down then active = true end

    if active then
        S.dirty = true
        S.padMoving = true
    elseif S.padBurst then
        -- let go: send the exact place soon
        S.padBurst = false
        S.padMoving = false
        S.dirty = true
        if not sameAsSent(t) then S.lastSend = math.min(S.lastSend, S.clock - 250) end
    end
end

reskate.on("tick", function(dt)
    S.clock += dt
    local sec = dt / 1000
    if S.clock - S.lastScan > 500 then
        S.lastScan = S.clock
        local ok, err = pcall(scan)
        if not ok then reskate.log("Quick Drop helper: " .. tostring(err), "warn") end
    end

    if S.cleanup and #S.cleanup > 0 and S.clock - (S.cleanupAt or 0) > 1000 then
        S.cleanupAt = S.clock
        local id = S.cleanup[1]
        local ok, why = reskate.objects.remove(id)
        reskate.log("Quick Drop helper: removing a leftover object (" .. tostring(id) .. "): " .. (ok and "done" or tostring(why)))
        if ok or (why ~= "the last edit is still being applied" and why ~= "more than 4 edits in a second") then
            table.remove(S.cleanup, 1)
            if not ok then S.cleanupFailed = (S.cleanupFailed or 0) + 1 end
            if #S.cleanup == 0 then
                S.blocked = nil
                pcall(findMissing)
                if (S.cleanupFailed or 0) > 0 then
                    say("The game refused to remove " .. S.cleanupFailed .. " of them. Turn the mod back on instead (see ReSkate.log).", true)
                else
                    say("Done. The park can be changed again.", true)
                end
                S.cleanupFailed = nil
            end
        end
    end

    if not S.open then
        -- quick keys while skating: hold Ctrl
        if reskate.input.allowed() and reskate.input.key("Ctrl") and S.target then
            local fine = reskate.input.key("Shift")
            local v = reskate.camera.get()
            local f = v and flat(v.forward) or V(0, 0, 1)
            local r = V(-f.z, 0, f.x) * -1
            if v and v.right then r = flat(v.right) end
            local t = S.target
            local function ch(fn) markUndo(); fn(); S.dirty = true end
            local st = fine and 0.01 or 0.1
            if press("[") then ch(function() local s = math.rad(fine and 1 or 15); t.heading = wrap(round(t.heading + s, s)) end) end
            if press("]") then ch(function() local s = math.rad(fine and 1 or 15); t.heading = wrap(round(t.heading - s, s)) end) end
            if press("PageUp") then ch(function() t.pos += V(0, fine and 0.01 or 0.05, 0) end) end
            if press("PageDown") then ch(function() t.pos -= V(0, fine and 0.01 or 0.05, 0) end) end
            if press("X") then ch(function() t.scale = clamp(t.scale + (fine and 0.01 or 0.1), 0.1, 10) end) end
            if press("Z") then ch(function() t.scale = clamp(t.scale - (fine and 0.01 or 0.1), 0.1, 10) end) end
            if press("Up") then ch(function() t.pos += f * st end) end
            if press("Down") then ch(function() t.pos -= f * st end) end
            if press("Right") then ch(function() t.pos += r * st end) end
            if press("Left") then ch(function() t.pos -= r * st end) end
            if press("U") then undo() end
        else
            for _, k in ipairs({ "[", "]", "PageUp", "PageDown", "X", "Z", "Up", "Down", "Right", "Left", "U" }) do S.held[k] = false end
        end
        send()
        return
    end

    -- the editor: keys (none while the text box is open)
    if S.typing then send(); return end
    local ctrl = reskate.input.key("Ctrl")
    if press("W") then S.mode = 1 end
    if press("E") then S.mode = 2 end
    if press("R") then S.mode = 3 end
    if press("G") then S.snap = not S.snap end
    if press("T") then S.osnap = not S.osnap; say(S.osnap and "Snap to objects on" or "Snap to objects off") end
    if press("F") and S.target then S.cam.goal = S.target.pos end
    if press("Z") and ctrl then undo() end
    do -- the view: arrows and PageUp / PageDown slide it
        local _, f, r = camBasis()
        local sp = math.max(S.cam.dist, 3) * (reskate.input.key("Shift") and 2.5 or 0.8) * sec
        local mv = V(0, 0, 0)
        if reskate.input.key("Up") then mv += flat(f) end
        if reskate.input.key("Down") then mv -= flat(f) end
        if reskate.input.key("Right") then mv += flat(r) end
        if reskate.input.key("Left") then mv -= flat(r) end
        if reskate.input.key("PageUp") then mv += V(0, 1, 0) end
        if reskate.input.key("PageDown") then mv -= V(0, 1, 0) end
        S.cam.goal = (S.cam.goal or S.cam.target) + mv * sp
    end
    do
        local ok, err = pcall(learnNear)
        if not ok and not S.learnWarned then S.learnWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(err), "warn") end
        ok, err = pcall(stepTighten)
        if not ok then S.tighten = nil; if not S.tightWarned then S.tightWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(err), "warn") end end
    end
    do
        local ok, err = pcall(padEditor, sec)
        if not ok then reskate.log("Quick Drop helper: controller: " .. tostring(err), "warn") end
        if not S.open then return end
    end

    -- the mouse
    local c = reskate.input.cursor()
    if c then
        local px = c.position
        local last = S.mouse.pos or px
        local dx, dy = px.x - last.x, px.y - last.y
        if c.wheel and c.wheel ~= 0 and not c.over_screen then
            S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (0.85 ^ c.wheel), 0.5, 300)
        end
        S.hover = (not S.drag and not c.over_screen) and handleAt(px) or nil
        if c.left and not S.mouse.left and not c.over_screen then
            local h = handleAt(px)
            if h then
                markUndo()
                local t = S.target
                h.start = { pos = t.pos, heading = t.heading, scale = t.scale, px = px }
                local o, d = rayAt(px)
                if h.kind == "axis" then
                    local s0, s1 = S.screen.center, S.screen.unit[h.axis]
                    local ppm = s1 and d2(s0, s1) or 0
                    h.dir = ppm > 1 and V((s1.x - s0.x) / ppm, (s1.y - s0.y) / ppm, 0) or V(1, 0, 0)
                    h.ppm = math.max(ppm, 1)
                elseif h.kind == "plane" then
                    h.n = axesFor(t.heading)[PLANES[h.plane].n][1]
                    h.hit0 = planeHit(o, d, t.pos, h.n)
                    if not h.hit0 then h = nil end
                elseif h.kind == "size" then
                    h.c0 = S.screen.center
                    h.d0 = math.max(d2(px, h.c0), 12)
                elseif h.kind == "turn" then
                    local c0 = S.screen.center
                    h.lastA = math.atan2(-(px.y - c0.y), px.x - c0.x)
                    h.acc = 0
                    -- seen from above, turning the mouse anticlockwise turns the object anticlockwise
                    local _, cf = camBasis()
                    h.sign = cf.y <= 0 and 1 or -1
                end
                S.drag = h
                S.dragStats = { sent = 0, from = S.clock }
            else
                S.drag = { kind = "click", start = { px = px } }
            end
        elseif c.left and S.drag then
            local g, t = S.drag, S.target
            if g.kind == "click" or g.kind == "view" then
                if g.kind == "click" and d2(px, g.start.px) > 4 then g.kind = "view" end
                if g.kind == "view" then
                    S.cam.yaw -= dx * 0.005
                    S.cam.pitch = clamp(S.cam.pitch - dy * 0.005, -1.45, 1.45)
                end
            elseif t then
                local step = reskate.input.key("Shift") and 1 or 0.25
                local toObjects = S.osnap and not reskate.input.key("Ctrl")
                S.guides = nil
                if g.kind == "axis" then
                    local along = ((px.x - g.start.px.x) * g.dir.x + (px.y - g.start.px.y) * g.dir.y) / g.ppm
                    if S.snap then along = round(along, step) end
                    local way = axesFor(g.start.heading)[g.axis][1]
                    t.pos = g.start.pos + way * along
                    if toObjects then t.pos, t.heading, S.guides = snapTurned(t.pos, g.start.heading, t.scale, allowAlong(way)) else t.heading = g.start.heading end
                    g.moved = true
                elseif g.kind == "plane" then
                    local o, d = rayAt(px)
                    local hh = planeHit(o, d, g.start.pos, g.n)
                    if hh then
                        local off = hh - g.hit0
                        off = off - g.n * dot(off, g.n)
                        if S.snap then
                            local ax = axesFor(g.start.heading)
                            local o2 = V(0, 0, 0)
                            for i = 1, 3 do o2 += ax[i][1] * round(dot(off, ax[i][1]), step) end
                            off = o2
                        end
                        t.pos = g.start.pos + off
                        if toObjects then t.pos, t.heading, S.guides = snapTurned(t.pos, g.start.heading, t.scale, allowIn(g.n)) else t.heading = g.start.heading end
                        g.moved = true
                    end
                elseif g.kind == "turn" then
                    local c0 = S.screen.center or g.start.px
                    if d2(px, c0) > 6 then
                        local a = math.atan2(-(px.y - c0.y), px.x - c0.x)
                        g.acc += wrap(a - g.lastA) * g.sign
                        g.lastA = a
                        local hd = g.start.heading + g.acc
                        if S.snap then hd = round(hd, math.rad(reskate.input.key("Shift") and 45 or 15)) end
                        if toObjects then hd, S.guides = turnTo(hd) end
                        t.heading = wrap(hd)
                        g.moved = true
                    end
                elseif g.kind == "size" then
                    local k = d2(px, g.c0) / g.d0
                    local s = g.start.scale * k
                    if S.snap then s = round(s, 0.1) end
                    t.scale = clamp(s, 0.1, 10)
                    g.moved = true
                end
            end
            if S.drag and S.drag.moved then S.dirty = true end
        elseif not c.left and S.mouse.left and S.drag then
            if S.drag.kind == "click" then clickPick(px) end
            local moved = S.drag.moved
            S.drag = nil
            if moved and S.osnap and not reskate.input.key("Ctrl") then armTighten(S.guides) end
            S.guides = nil
            local st = S.dragStats
            if st and moved then
                S.dragStats = nil
                reskate.log(string.format("Quick Drop helper: drag of %.1f s: %d moves taken, %d refused as still applying, %d as more than 4 a second, %d other",
                    (S.clock - st.from) / 1000, st.sent, st["the last edit is still being applied"] or 0, st["more than 4 edits in a second"] or 0, st.other or 0))
            end
            if moved then S.dirty = true; if not sameAsSent(S.target) then S.lastSend = math.min(S.lastSend, S.clock - 250) end end
        end
        if (c.right or c.middle) and not c.over_screen and S.mouse.pos then
            local _, _, r, u = camBasis()
            local k = S.cam.dist * 0.0014
            S.cam.goal = (S.cam.goal or S.cam.target) + r * (-dx * k) + u * (dy * k)
            S.cam.target += r * (-dx * k) + u * (dy * k)
        end
        S.mouse = { pos = px, left = c.left }
    end

    camGlide(sec)
    local pos, f, _, u = camBasis()
    reskate.camera.set(pos, f, u, S.cam.fov)
    send()
end)

-- ---------------------------------------------------------------- drawing the handles
local function colourOf(base, hot) return hot and YELLOW or base end

reskate.on("draw", function(d)
    if not S.open then return end
    S.size = d:size()
    local cpos, f, r, u = camBasis()
    local probe = d:world_to_screen(cpos + f * 10 + r * 1 + u * 1)
    if probe then
        local mx, my = (probe.x - S.size.x / 2) / 0.1, (S.size.y / 2 - probe.y) / 0.1
        if math.abs(mx) > 1 and math.abs(my) > 1 then S.proj = V(mx, my, 0) end
    end
    S.screen = {}
    if not S.target then return end
    local t = S.target
    local p = t.pos
    local center = d:world_to_screen(p)
    if not center then return end
    S.screen.center = center
    S.screen.mode = S.mode
    S.boxCorners = nil
    if S.sel.bp == nil and not S.sel.bpTried then
        S.sel.bpTried = true
        local ok, hit = pcall(reskate.world.pick, p + V(0, 6, 0), p - V(0, 1, 0))
        if ok and hit and hit.object and hit.object.position and len(hit.object.position - S.sel.pos0) < 0.5 then S.sel.bp = hit.object.blueprint end
    end
    local bx = nil
    if S.sel.bp then
        S.boundsCache = S.boundsCache or {}
        bx = S.boundsCache[S.sel.bp]
        if bx == nil then
            local ok, a, b = false, nil, nil
            if reskate.entities then ok, a, b = pcall(reskate.entities.bounds, S.sel.bp) end
            if ok and type(a) == "table" and a.min then a, b = a.min, a.max end
            bx = (ok and a and b) and { a, b } or false
            S.boundsCache[S.sel.bp] = bx
        end
        -- the same size serves snapping
        if bx and S.itemBox[S.sel.item] == nil then S.itemBox[S.sel.item] = bx end
    end
    if not bx and S.itemBox[S.sel.item] then bx = S.itemBox[S.sel.item] end
    if bx then
        local lo, hi = bx[1], bx[2]
        local ext = math.max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z) * t.scale
        S.handleLen = clamp(ext * 0.55, 0.6, 6)
        local ch, sh, sc = math.cos(t.heading), math.sin(t.heading), t.scale
        local function W(x, y, z) return p + V(x * ch + z * sh, y, -x * sh + z * ch) * sc end
        local c = {}
        for i = 0, 7 do
            c[i] = W(i % 2 == 0 and lo.x or hi.x, math.floor(i / 2) % 2 == 0 and lo.y or hi.y, i < 4 and lo.z or hi.z)
        end
        S.boxCorners = c
    end
    -- the handles keep a steady size on screen (about 130 pixels)
    local L = S.handleLen or 1.5
    L = math.max(L, 0.05)
    local hv, dg = S.hover, S.drag
    local function hot(kind, i)
        local h = dg or hv
        return h and h.kind == kind and (i == nil or h.axis == i or h.plane == i)
    end

    if S.mode == 1 then
        S.screen.axis, S.screen.unit, S.screen.planes = {}, {}, {}
        local AXES = axesFor(t.heading)
        -- plane squares (like the 3D maker's small triangles between two arrows)
        for i, pl in ipairs(PLANES) do
            local a, b = AXES[pl.a][1], AXES[pl.b][1]
            local q = { p + (a * 0.22 + b * 0.22) * L, p + (a * 0.48 + b * 0.22) * L, p + (a * 0.48 + b * 0.48) * L, p + (a * 0.22 + b * 0.48) * L }
            local sp = {}
            for k = 1, 4 do sp[k] = d:world_to_screen(q[k]) end
            if sp[1] and sp[2] and sp[3] and sp[4] then
                d:poly(sp, { colour = colourOf(AXES[pl.n][2], hot("plane", i)) .. "c0", fill = true })
                S.screen.planes[i] = sp
            end
        end
        for i, a in ipairs(AXES) do
            local e = p + a[1] * L
            local col = colourOf(a[2], hot("axis", i))
            d:world_line(p, e, { colour = col, thickness = 5 })
            local se = d:world_to_screen(e)
            S.screen.axis[i] = se
            S.screen.unit[i] = d:world_to_screen(p + a[1])
            -- the arrow head
            local tip = d:world_to_screen(p + a[1] * (L * 1.22))
            if se and tip then
                local dx, dy = tip.x - se.x, tip.y - se.y
                local l = math.max(math.sqrt(dx * dx + dy * dy), 1)
                local nx, ny = -dy / l * 10, dx / l * 10
                d:poly({ tip, V(se.x + nx, se.y + ny, 0), V(se.x - nx, se.y - ny, 0) }, { colour = col, fill = true })
                S.screen.axis[i] = tip
            end
        end
    elseif S.mode == 2 then
        -- the turn ring: about the up axis (the only way park objects turn)
        local pts = {}
        for i = 0, 64 do
            local a = i / 64 * 2 * math.pi
            pts[i + 1] = d:world_to_screen(p + V(math.sin(a), 0, math.cos(a)) * L)
        end
        local col = colourOf(GREEN, hot("turn"))
        for i = 1, 64 do
            if pts[i] and pts[i + 1] then d:line(pts[i], pts[i + 1], { colour = col, thickness = 5 }) end
        end
        S.screen.ring = pts
        local fw = d:world_to_screen(p + V(math.sin(t.heading), 0, math.cos(t.heading)) * L)
        if fw then d:line(center, fw, { colour = col, thickness = 2 }) end
        d:text(center + V(14, -30, 0), string.format("%.0f°", math.deg(t.heading)), { size = 18, colour = "#ffffff", shadow = true })
    else
        S.screen.cubes = {}
        local AXES = axesFor(t.heading)
        if S.boxCorners then
            local c = S.boxCorners
            local col = colourOf("#2bea2b", hot("size"))
            for _, e in ipairs(BOX_EDGES) do d:world_line(c[e[1]], c[e[2]], { colour = col, thickness = 3 }) end
            for i = 0, 7 do
                local sp = d:world_to_screen(c[i])
                if sp then
                    d:rect(sp - V(8, 8, 0), sp + V(8, 8, 0), { colour = col, fill = true, rounding = 2 })
                    S.screen.cubes[i + 1] = sp
                end
            end
            AXES = {}
        end
        for i, a in ipairs(AXES) do
            local e = p + a[1] * L
            local col = colourOf(a[2], hot("size"))
            d:world_line(p, e, { colour = col, thickness = 5 })
            local se = d:world_to_screen(e)
            if se then
                d:rect(se - V(10, 10, 0), se + V(10, 10, 0), { colour = col, fill = true, rounding = 2 })
                S.screen.cubes[i] = se
            end
        end
        d:text(center + V(14, -30, 0), string.format("%.2f×", t.scale), { size = 18, colour = "#ffffff", shadow = true })
    end
    d:circle(center, 4, { colour = "#ffffff", fill = true })
    -- what it is snapped to: that object's box (or its point), and how
    if S.guides then
        local WORDS = { touch = "touching", level = "lined up", turn = "same turn" }
        local seen = {}
        for _, gd in ipairs(S.guides) do
            local id = gd.o.id
            if not seen[id] then
                seen[id] = true
                local nc = cornersOf(gd.nb)
                if #nc == 8 then
                    for _, e in ipairs(BOX_EDGES) do d:world_line(nc[e[1] + 1], nc[e[2] + 1], { colour = "#35e0ff", thickness = 3 }) end
                else
                    local q = gd.nb.p
                    d:world_line(q - V(0.4, 0, 0), q + V(0.4, 0, 0), { colour = "#35e0ff", thickness = 3 })
                    d:world_line(q - V(0, 0, 0.4), q + V(0, 0, 0.4), { colour = "#35e0ff", thickness = 3 })
                    d:world_line(q, q + V(0, 0.8, 0), { colour = "#35e0ff", thickness = 3 })
                end
                local sp = d:world_to_screen(gd.nb.p)
                if sp then d:text(sp + V(10, -12, 0), WORDS[gd.kind] or "snap", { size = 16, colour = "#35e0ff", shadow = true }) end
            end
        end
    end
    -- the object's box where it is going: shows at once while the game catches up
    if S.boxCorners and S.mode ~= 3 then
        local c = S.boxCorners
        local col = (S.dirty or (S.drag and S.drag.moved) or not lastApplied()) and "#ffe066" or "#ffffff66"
        for _, e in ipairs(BOX_EDGES) do
            d:world_line(c[e[1]], c[e[2]], { colour = col, thickness = 2 })
        end
    end
end)

reskate.on("load", function() reskate.log("Quick Drop helper ready: drop an object, then F6 (or hold Ctrl and use [ ] PgUp PgDn Z X arrows).") end)
