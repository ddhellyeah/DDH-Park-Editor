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
    S.guides, S.padRaw, S.tighten, S.snapLock = nil, nil, nil, nil
    if S.grab and not (o and o.id == S.grab.id) then S.grab = nil end
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
    for _, o in ipairs(list) do
        -- an object held tilted: where it was placed (not where its tilted body is)
        local h = S.held and S.held[o.id]
        if h then
            h.reported, h.reportedHeading = o.position, o.heading
            o = { id = o.id, item = o.item, position = h.pos, heading = h.heading, scale = o.scale }
        end
        now[o.id] = o
    end
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
        local ec = S.expectCopy
        if #fresh == 1 and ec and fresh[1].item == ec.item and len(fresh[1].position - ec.pos) < 0.05 then
            -- the copy made with X: it keeps the tilt, and the held object stays picked
            local o = fresh[1]
            reskate.log("Quick Drop helper: copy made " .. fmt(o))
            if ec.tilt then S.tilt[o.id] = { x = ec.tilt.x, z = ec.tilt.z }; S.tiltSaveDue = true end
            S.expectCopy = nil
            if ec.grab and S.open then
                select(o)
                if S.startGrab then S.startGrab(); if S.grab then S.grab.fresh = true end end
            end
        elseif #fresh == 1 then
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
        local tl = S.tilt[S.sel.id]
        table.insert(S.undo, { id = S.sel.id, pos = S.target.pos, heading = S.target.heading, scale = S.target.scale, tilt = tl and { x = tl.x, z = tl.z } or nil })
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
        S.tilt[u.id] = u.tilt
        S.tiltSaveDue = true
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
local HEIGHT_FIT = 1.0   -- metres up or down at most that an object goes to take the height of one it meets

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
local function tryNamed(o)
    local key = string.lower(o.item)
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
        for _, q in ipairs(reskate.objects.list()) do now[q.id] = q end
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
    for _, o in pairs(S.known) do
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
S.tilt, S.held, S.tiltWhy, S.tiltAt, S.tiltSrc = {}, {}, nil, {}, {}
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
local function placedShape(o)
    local c = S.shapeCache[o.id]
    local box = S.itemBox[o.item]
    local h, sc = o.heading or 0, o.scale or 1
    if c and c.box == box and c.h == h and c.sc == sc and c.pos == o.position then return c.shape end
    local sh = worldShape(o.item, o.position, h, sc)
    S.shapeCache[o.id] = { box = box, h = h, sc = sc, pos = o.position, shape = sh }
    return sh
end
local COS1 = math.cos(math.rad(1))

-- An object as it stands, tilt and all: its corners and its flat faces (each side of its outline, its top and its
-- bottom), each face with a corner o, its outward direction n and two directions u, v across it (ulen, vlen long).
local function faceBox(f)
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
        so.faces[#so.faces + 1] = faceBox({ o = xf(E.a + UP * base), n = rv(E.n), u = rv(E.e), v = up, ulen = E.len, vlen = top - base, long = i <= 8, side = true })
    end
    -- top and bottom: the outline's extent along the object's own x and z
    local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    for _, q in ipairs(sh.pts) do
        local a, b = dot(q - pos, sh.ax), dot(q - pos, sh.az)
        x0 = math.min(x0, a); x1 = math.max(x1, a); z0 = math.min(z0, b); z1 = math.max(z1, b)
    end
    local ax, az = rv(sh.ax), rv(sh.az)
    so.faces[#so.faces + 1] = faceBox({ o = xf(pos + UP * top + sh.ax * x0 + sh.az * z0), n = up, u = ax, v = az, ulen = x1 - x0, vlen = z1 - z0, long = true })
    so.faces[#so.faces + 1] = faceBox({ o = xf(pos + UP * base + sh.ax * x0 + sh.az * z0), n = up * -1, u = ax, v = az, ulen = x1 - x0, vlen = z1 - z0, long = true })
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

-- Moves pos so the picked object's faces meet or line up with the faces of the objects near it (tilted or not).
-- allow(direction, metres) answers how such a move may be made for the handle in use: the move as a vector and
-- the direction it goes along, or nil when that handle cannot go that way.
-- Returns the place, and what it snapped to (a list of { o, nb, kind }) or nil.
local function objSnap(pos, heading, scale, allow, tl)
    if not (S.osnap and S.sel and S.known) then return pos, nil end
    local thr = clamp(S.cam.dist * 0.03, 0.12, 0.5)
    local me = worldSolid(S.sel.item, pos, heading, scale, tl)
    local mc = cornersOf(me)
    local reach = SNAP_REACH + len(me.hi - me.lo)
    local near = {}
    for id, o in pairs(S.known) do
        if id ~= S.sel.id then
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
        local function add(axis, m, kind, rank, n, corner, fit)
            if math.abs(m) > thr then return end
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
                        if c < -COS1 or c > COS1 then
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
                                if c < 0 then
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
                                    end
                                elseif math.max(0, -ovu, -ovv) <= SNAP_REACH then
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
                    if du > -0.02 and du < E.ulen + 0.02 and dv > -0.02 and dv < E.vlen + 0.02 then
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
    if first and first.kind == "touch" and first.fit and not first.corner then
        local f = first.fit
        local m = math.abs(f.bottom) <= math.abs(f.top) and f.bottom or f.top
        if math.abs(m) > 1e-4 and math.abs(m) <= HEIGHT_FIT then
            local c = { mv = f.v * m, dir = f.v, cost = math.abs(m), rank = 1, o = first.o, nb = first.nb, kind = "level", near = first.near }
            picked[1] = c
            out = out + c.mv
        end
    end
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
local function turnsToMeet(me, nb, maxTurn)
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
    for id, o in pairs(S.known) do
        if id ~= S.sel.id then
            local d = len(o.position - S.target.pos)
            if d < bd then best, bd = o, d end
        end
    end
    if not best then return hd, nil end
    if tiltOf(S.sel.id) or tiltOf(best.id) then return hd, nil end
    local me = worldShape(S.sel.item, S.target.pos, hd, S.target.scale)
    local nb = placedShape(best)
    if #me.edges > 0 and #nb.edges > 0 then
        local t = turnsToMeet(me, nb, SNAP_TURN)
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
    local ok, p, g = pcall(objSnap, pos, heading, scale, allow)
    if ok then
        S.snapLock = (g and g[1] and g[1].o) and g[1].o.id or nil
        return p, g
    end
    if not S.snapWarned then S.snapWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(p), "warn") end
    return pos, nil
end
-- Moving with a turn: when the picked object comes to meet a nearby object that is turned differently, it
-- takes that object's turn (or the nearest quarter turn of it) so the two sides meet flat. base is the turn it
-- had when the move began, so pulling it away again gives that turn back.
-- the ways of standing exactly like a tilted object, about up by quarter turns (when they can be written as a turn
-- about up then a tilt about x then z)
local function standsLike(h, tl)
    local out = { { h = h, tl = { x = tl.x, z = tl.z } }, { h = wrap(h + math.pi), tl = { x = -tl.x, z = -tl.z } } }
    if math.abs(tl.x) < 1e-4 then
        out[#out + 1] = { h = wrap(h + math.pi / 2), tl = { x = -tl.z, z = 0 } }
        out[#out + 1] = { h = wrap(h - math.pi / 2), tl = { x = tl.z, z = 0 } }
    elseif math.abs(tl.z) < 1e-4 then
        out[#out + 1] = { h = wrap(h + math.pi / 2), tl = { x = 0, z = tl.x } }
        out[#out + 1] = { h = wrap(h - math.pi / 2), tl = { x = 0, z = -tl.x } }
    end
    return out
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
    for id, o in pairs(S.known) do
        if id ~= S.sel.id and S.itemBox[o.item] then
            local b = S.itemBox[o.item]
            local d = len(o.position - pos) - len((b[2] - b[1]) * (o.scale or 1)) / 2
            if d < SNAP_REACH + 2 then near[#near + 1] = { o = o, d = d } end
        end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    local tries, tried = 0, {}
    local thr = clamp(S.cam.dist * 0.03, 0.12, 0.5)
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
            -- a tilted one: stand like it
            local opts = standsLike(n.o.heading or 0, ntl)
            table.sort(opts, function(a, b) return turnApart(a.h, a.tl, base, bt) < turnApart(b.h, b.tl, base, bt) end)
            for _, op in ipairs(opts) do
                if turnApart(op.h, op.tl, base, bt) > 1e-3 and turnApart(op.h, op.tl, base, bt) <= math.rad(100) then
                    tries += 1
                    if tries > 6 then break end
                    local p2, g2 = try(n, op.h, op.tl)
                    if p2 then return p2, op.h, g2, op.tl end
                end
            end
        elseif not bt then
            -- both flat: a turn about up that sets two long sides together
            local me = worldShape(S.sel.item, pos, base, scale)
            local nb = placedShape(n.o)
            if #me.edges > 0 and #nb.edges > 0 then
                for _, tm in ipairs(turnsToMeet(me, nb, math.rad(90))) do
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
local function snapTurned(pos, base, scale, allow, baseTilt)
    local ok, p, h, g, tl = pcall(alignSnap, pos, base, scale, allow, baseTilt)
    if ok then
        S.snapLock = (g and g[1] and g[1].o) and g[1].o.id or nil
        return p, h, g, tl
    end
    if not S.snapWarned then S.snapWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(p), "warn") end
    return pos, base, nil, baseTilt
end
local function turnTo(hd)
    local ok, h, g = pcall(turnSnap, hd)
    if ok then return h, g end
    if not S.snapWarned then S.snapWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(h), "warn") end
    return hd, nil
end

-- ---------------------------------------------------------------- tilting
-- The game keeps only a turn about up for a placed object. To tilt one (forward, or to the side), this plugin
-- holds it with the game's object physics, fixed in place and still skateable, and gives it its full turn.
-- The game never saves that, so the plugin keeps every tilt itself (per map, by the object's item and place) and
-- puts it back whenever the park is loaded. While an object is moved, turned or sized it is let go (the game
-- shows it flat for that moment), and tilted again once the game has it in its new place. Offline only, and at
-- most 32 tilted objects at once (the game's limit for one plugin).
local function heldCount() local n = 0; for _ in pairs(S.held) do n += 1 end; return n end
local function letGo(id)
    if S.held[id] then
        pcall(reskate.objects.physics, id, nil)
        S.held[id] = nil
    end
end
-- holds an object (if not yet) and gives it its tilt; o is the object as placed
local function holdTilted(o)
    local tl = S.tilt[o.id]
    local h = S.held[o.id]
    if not h then
        if S.clock < (S.tiltAt[o.id] or 0) then return end
        -- where it is placed now, from the game (it is not held yet, so that is its placed spot)
        for _, q in ipairs(reskate.objects.list()) do if q.id == o.id then o = q break end end
        if heldCount() >= MAX_HELD then S.tiltWhy = "at most 32 tilted objects at once" return end
        local ok, r1, r2 = pcall(reskate.objects.physics, o.id, { dynamic = false, surface = true })
        if not ok or r1 == false then
            local why = tostring(ok and (r2 or "refused") or r1)
            S.tiltAt[o.id] = S.clock + 2000
            -- in plain words: what to do so it shows
            local plain = why
            if string.find(why, "editing", 1, true) or string.find(why, "menu", 1, true) then
                plain = "leave Quick Drop (and close menus) and it tilts"
            elseif string.find(why, "offline", 1, true) then
                plain = "only in offline play"
            end
            if S.tiltWhy ~= plain then
                reskate.log("Quick Drop helper: tilt: the game won't hold " .. titleOf(o.item) .. ": " .. why)
                pcall(reskate.ui.toast, "Tilt: " .. plain)
            end
            S.tiltWhy = plain
            return
        end
        local ok2, m = pcall(reskate.objects.motion, o.id)
        if not (ok2 and type(m) == "table" and m.position and m.rotation) then
            pcall(reskate.objects.physics, o.id, nil)
            S.tiltAt[o.id] = S.clock + 2000
            return
        end
        local r = m.rotation
        h = { off = m.position - o.position, q0 = { r.x or r[1], r.y or r[2], r.z or r[3], r.w or r[4] }, at = -1e9, pos = o.position, heading = o.heading or 0,
            rev = m.edit_revision, gen = m.generation, checkAt = S.clock }
        S.tiltGrabs = (S.tiltGrabs or 0) + 1
        if S.tiltGrabs <= 30 then reskate.log(string.format("Quick Drop helper: tilt: holding %s (%d)", titleOf(o.item), S.tiltGrabs)) end
        S.held[o.id] = h
        S.tiltWhy = nil
    end
    if S.clock - h.at < 320 then return end
    local q = fullTurn(h.heading, tl)
    local rel = qmul(q, qconj(h.q0))
    local at = h.pos + qrot(rel, h.off)
    local key = string.format("%.5f %.5f %.5f %.5f", q[1], q[2], q[3], q[4])
    if h.key == key then return end
    local ok, r1, r2 = pcall(reskate.objects.pose, o.id, at, q)
    h.at = S.clock
    if ok and r1 ~= false then
        h.key = key
        h.posed = at
        h.ref = nil   -- where the game reports it is learnt again once it has settled
    elseif not h.warned and not string.find(tostring(ok and r2 or r1), "rate limit", 1, true) then
        -- (too soon after the last one: simply tried again a moment later)
        h.warned = true
        reskate.log("Quick Drop helper: tilt: the game refused the turn for " .. titleOf(o.item) .. ": " .. tostring(ok and r2 or r1))
    end
end

-- kept tilts: storage "tilts" = { [map] = { { item, x, y, z, turn, tilt x, tilt z }, ... } }
local function mapName()
    local ok, l = pcall(function() return reskate.level and reskate.level.current() end)
    return (ok and type(l) == "table" and l.name) or S.level or "?"
end
local function loadTilts()
    local ok, t = pcall(reskate.storage.get, "tilts")
    S.tiltStore = (ok and type(t) == "table") and t or {}
end
local function saveTilts()
    S.tiltStore = S.tiltStore or {}
    local map = mapName()
    local keep = {}
    local mine = {}
    for _, e in pairs(S.tiltSrc) do mine[e] = true end
    -- tilts of objects not on the map right now stay as they were (the ones of objects here are written anew)
    for _, e in ipairs(S.tiltStore[map] or {}) do
        local found = mine[e] == true
        for _, o in pairs(S.known or {}) do
            if o.item == e[1] and math.abs(o.position.x - e[2]) < 0.02 and math.abs(o.position.y - e[3]) < 0.02 and math.abs(o.position.z - e[4]) < 0.02 then found = true break end
        end
        if not found then keep[#keep + 1] = e end
    end
    S.tiltSrc = {}
    for id, tl in pairs(S.tilt) do
        local o = S.known and S.known[id]
        if o and tilted(id) then
            S.tiltSrc[id] = { o.item, r3(o.position.x), r3(o.position.y), r3(o.position.z), math.floor((o.heading or 0) * 1e5 + 0.5) / 1e5,
                math.floor(tl.x * 1e5 + 0.5) / 1e5, math.floor(tl.z * 1e5 + 0.5) / 1e5 }
            keep[#keep + 1] = S.tiltSrc[id]
        end
    end
    while #keep > 600 do table.remove(keep, 1) end
    S.tiltStore[map] = keep
    local ok, err = pcall(reskate.storage.set, "tilts", S.tiltStore)
    if not ok then reskate.log("Quick Drop helper: tilt: not kept: " .. tostring(err)) end
end
-- the kept tilts of the objects on this map
local function matchTilts()
    if not (S.known and S.tiltStore) then return end
    for _, e in ipairs(S.tiltStore[mapName()] or {}) do
        for id, o in pairs(S.known) do
            if not S.tilt[id] and o.item == e[1] and math.abs(o.position.x - e[2]) < 0.02 and math.abs(o.position.y - e[3]) < 0.02
                and math.abs(o.position.z - e[4]) < 0.02 and math.abs(wrap((o.heading or 0) - e[5])) < 0.01 then
                S.tilt[id] = { x = e[6], z = e[7] }
                S.tiltSrc[id] = e
                break
            end
        end
    end
end

-- every tick: the picked object is let go while it is being moved; every other tilted object is held tilted
local function tiltTick()
    if not S.tiltStore then loadTilts() end
    if S.clock - (S.tiltMatchAt or -1e9) > 1000 then
        S.tiltMatchAt = S.clock
        matchTilts()
        -- objects gone from the park: forget them
        for id in pairs(S.held) do if not (S.known and S.known[id]) then S.held[id] = nil end end
        for id in pairs(S.tilt) do if S.known and not S.known[id] then S.tilt[id] = nil end end
    end
    -- levelled again: let go
    for id in pairs(S.held) do if not tilted(id) then letGo(id) end end
    for id, tl in pairs(S.tilt) do
        local o = S.known and S.known[id]
        local mine = S.sel and S.sel.id == id
        local busy = mine and (S.dirty or ((S.drag and S.drag.moved) and S.drag.kind ~= "tilt") or S.padMoving or not lastApplied())
        if not tilted(id) or not o or busy then
            if S.held[id] then letGo(id) end
            if busy then S.tiltSaveDue = true end
        else
            local h = S.held[id]
            -- really changed by the game (Quick Drop, the park editor, replaced): hold it again from its new place
            if h and S.clock - h.checkAt > 500 then
                h.checkAt = S.clock
                -- moved by something else (Quick Drop): the game reports it neither where it was placed nor
                -- where it was put tilted
                local rp = h.reported
                -- a held object stands still: once settled, where the game reports it stays the same
                if rp and not h.ref and h.key and S.clock - h.at > 400 then h.ref = rp end
                if rp and h.ref and len(rp - h.ref) > 0.05 and len(rp - h.pos) > 0.05 then
                    reskate.log(string.format("Quick Drop helper: tilt: %s was moved (to %.2f, %.2f, %.2f): holding it again", titleOf(o.item), rp.x, rp.y, rp.z))
                    letGo(id); h = nil
                else
                    -- no longer held (the game let go: a level change, the plugin stopping): only after it says so
                    -- three times running (it can miss a read now and then)
                    local ok, m = pcall(reskate.objects.motion, id)
                    if ok and m == nil then
                        h.gone = (h.gone or 0) + 1
                        if h.gone >= 3 then
                            reskate.log("Quick Drop helper: tilt: the game let go of " .. titleOf(o.item) .. ": holding it again")
                            S.held[id] = nil; h = nil
                        end
                    else
                        h.gone = 0
                    end
                end
            end
            if h then holdTilted({ id = id, item = o.item, position = h.pos, heading = h.heading, scale = o.scale })
            else holdTilted(o) end
        end
    end
    if S.tiltSaveDue and not S.dirty and not S.drag and lastApplied() and S.clock - S.lastSend > 600 then
        S.tiltSaveDue = false
        saveTilts()
    end
end

-- ---------------------------------------------------------------- the park as a park mod (tilts and all)
-- Online, the game won't let a plugin hold objects, so tilts made here can't show there. A park mod can: it lists
-- every object with its whole turn, and in multiplayer the host loads it (Build > Park mods) for everyone. The
-- plugin may only write in its own data folder, so the park mod is made there and the folder opened, to be copied
-- into ReSkate's Mods folder. Park mods are only for the game's own maps.
local MAP_KEYS = { { "bam_levelroot", "bam" }, { "isle_of_grom", "grom" }, { "dingolevel_mpr", "mpr" },
    { "sdm_int_001", "stadium_1" }, { "sdm_int_002", "stadium_2" }, { "ftue", "ftue" } }
local function parkKey(name)
    local l = string.lower(tostring(name or ""))
    for _, k in ipairs(MAP_KEYS) do if string.find(l, k[1], 1, true) then return k[2] end end
    return nil
end
local function r6(x) return math.floor(x * 1e6 + 0.5) / 1e6 end
local function saveParkMod()
    local key = parkKey(mapName())
    if not key then return false, "park mods only work on the game's own maps (San Vansterdam, Grom, Mega Resort, the stadiums)" end
    local list = reskate.objects.list()
    if #list == 0 then return false, "there are no objects on this map" end
    local objs, scales, n = {}, {}, 0
    for _, o in ipairs(list) do
        n += 1
        local q = fullTurn(o.heading or 0, tiltOf(o.id))
        objs[#objs + 1] = { id = n, item = o.item, position = { r6(o.position.x), r6(o.position.y), r6(o.position.z) },
            rotation = { r6(q[1]), r6(q[2]), r6(q[3]), r6(q[4]) } }
        if math.abs((o.scale or 1) - 1) > 1e-4 then scales[tostring(n)] = r6(o.scale or 1) end
    end
    local park = { format = "reskate-park", schema_version = 1, revision = 1, maps = { [key] = objs } }
    if next(scales) then park.object_scales = { [key] = scales } end
    local folder = "park mods/DDH Park " .. key
    local man = { name = "DDH Park " .. key, author = "DDH", version_number = "1.0.0", website_url = "",
        description = "Saved from the DDH Park Editor (with tilts).", dependencies = {} }
    local ok1, why1 = reskate.files.write(folder .. "/manifest.json", reskate.json.encode(man, true))
    if not ok1 then return false, tostring(why1) end
    local ok2, why2 = reskate.files.write(folder .. "/parks/" .. key .. ".park.json", reskate.json.encode(park, true))
    if not ok2 then return false, tostring(why2) end
    pcall(reskate.files.reveal, "park mods")
    reskate.log(string.format("Quick Drop helper: saved %d objects as the park mod \"DDH Park %s\" (in the plugin's data folder, park mods)", n, key))
    return true, n, key
end
local function saveParkModSay()
    local ok, done, n, key = pcall(saveParkMod)
    if not ok then say("Not saved: " .. tostring(done), true) return end
    if done then
        say(string.format("Saved %d objects. Copy the folder \"DDH Park %s\" (just opened) into ReSkate's Mods folder, then Build > Park mods > Load. Online, the host loads it.", n, key), true)
    else
        say("Not saved: " .. tostring(n), true)
    end
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
    if #list > 0 and S.sel and not tiltOf(S.sel.id) then
        S.tighten = { id = S.sel.id, touches = list, at = S.clock, pass = 1 }
    else
        S.tighten = nil
    end
end

-- moves one side of an item's outline by delta metres outward (world direction d), when d is square to it
local function fitSide(o, d, delta)
    if S.exact[o.item] then return end
    if math.abs(delta) < 0.0005 or math.abs(delta) > 0.1 then return end
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
    saveSize(o.item, lo, hi)
    boxLog(string.format("outline of %s fitted %+.0f mm", titleOf(o.item), delta * 1000))
end

local function tightenJob(job, me, objs)
    local p = me.position
    local myBox = worldShape(me.item, p, me.heading or 0, me.scale or 1)
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
        if nbo and S.itemBox[nbo.item] ~= nil and not (S.exact[me.item] and S.exact[nbo.item]) and not tiltOf(nbo.id) then
            local n = norm(V(tc.n.x, 0, tc.n.z))
            local tg = V(-n.z, 0, n.x)
            local nb = worldShape(nbo.item, nbo.position, nbo.heading or 0, nbo.scale or 1)
            local mc, nc = myBox.pts, nb.pts
            if #mc == 0 then mc = cornersOf(myBox) end
            if #nc == 0 then nc = cornersOf(nb) end
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
                        for _ = 1, 14 do
                            if b - a <= 0.0005 then break end
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
                            for _ = 1, 14 do
                                if d - c <= 0.0005 then break end
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
                if math.abs(g) > 0.0005 and g < 0.35 then
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
    if corr and len(corr) > 0.0005 and len(corr) < 0.4 then
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
    S.bpNames = nil
    S.held, S.tilt, S.tiltAt, S.tiltSrc, S.level = {}, {}, {}, {}, nil
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
        local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
        local tx = num("tx", "Tilt X", math.deg(tl.x), -180, 180, "%.1f°")
        local tz = num("tz", "Tilt Z", math.deg(tl.z), -180, 180, "%.1f°")
        if tx or tz then
            if not S.sliding then markUndo(); S.sliding = true end
            S.tilt[S.sel.id] = { x = tx and math.rad(tx) or tl.x, z = tz and math.rad(tz) or tl.z }
            S.tiltSaveDue = true
        end
        if tilted(S.sel.id) and S.tiltWhy and not S.held[S.sel.id] then ui:note("Tilt waits: " .. S.tiltWhy) end
        if ui:button("parkmod", "Save as park mod (for online)") then saveParkModSay() end
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
    if S.osnap and S.sel and S.itemBox[S.sel.item] and not S.exact[S.sel.item] then
        if ui:button("remeasure", "Measure it again") then
            forgetSize(S.sel.item)
            say("Measuring " .. titleOf(S.sel.item) .. " again: keep it still a moment")
        end
    end
    ui:separator()
    if ui:button("undo", "Undo (Ctrl+Z)") then undo() end
    if ui:button("straight", "Straighten and size 1") and S.target then
        markUndo(); S.target.heading = round(S.target.heading, math.pi / 2); S.target.scale = 1; S.dirty = true
        if S.tilt[S.sel.id] then S.tilt[S.sel.id] = nil; S.tiltSaveDue = true end
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
    local lx_ = ui:toggle("invy", "Invert look up/down (controller)", S.lookInvY or false)
    if lx_ ~= nil and lx_ ~= (S.lookInvY or false) then S.lookInvY = lx_; saveLook() end
    local ly_ = ui:toggle("invx", "Invert look left/right (controller)", S.lookInvX or false)
    if ly_ ~= nil and ly_ ~= (S.lookInvX or false) then S.lookInvX = ly_; saveLook() end
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
        ui:info("Controller", "LB+RB opens")
        ui:info("Left stick", "fly (holding: move it)")
        ui:info("A", "pick up what the cross is on / put down")
        ui:info("B", "cancel (back where it was) / close")
        ui:info("X", "copy (holding: drop a copy)")
        ui:info("Y twice", "remove (what the cross is on)")
        ui:info("RT / LT", "raise / lower")
        ui:info("LB / RB", "turn (holding)")
        ui:info("D-pad up / down", "size (holding) / zoom")
        ui:info("D-pad left / right", "next object")
        ui:info("Right stick / R3", "turn the view / look at it")
        ui:info("View / Menu", "undo / steps")
        ui:info("Hold L3", "fine")
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
        local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
        numBox(ui, "tx", "Tilt X", math.deg(tl.x), "%.1f", function(v) markUndo(); S.tilt[S.sel.id] = { x = wrap(math.rad(v)), z = tl.z }; S.tiltSaveDue = true end)
        numBox(ui, "tz", "Tilt Z", math.deg(tl.z), "%.1f", function(v) markUndo(); S.tilt[S.sel.id] = { x = tl.x, z = wrap(math.rad(v)) }; S.tiltSaveDue = true end)
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
            if n2 == 5 then t.heading = round(t.heading, math.pi / 2); if S.tilt[S.sel.id] then S.tilt[S.sel.id] = nil; S.tiltSaveDue = true end end
            if n2 == 6 then t.scale = 1 end
            S.dirty = true; S.edit = {}
        end
        local n3 = ui:buttons("nudge3", { "Tilt X -", "Tilt X +", "Tilt Z -", "Tilt Z +", "Level" }, 0)
        if n3 then
            markUndo()
            local tl2 = S.tilt[S.sel.id] or { x = 0, z = 0 }
            local dd = math.rad(st.deg)
            if n3 == 1 then tl2 = { x = wrap(tl2.x - dd), z = tl2.z } end
            if n3 == 2 then tl2 = { x = wrap(tl2.x + dd), z = tl2.z } end
            if n3 == 3 then tl2 = { x = tl2.x, z = wrap(tl2.z - dd) } end
            if n3 == 4 then tl2 = { x = tl2.x, z = wrap(tl2.z + dd) } end
            if n3 == 5 then tl2 = nil end
            S.tilt[S.sel.id] = tl2
            S.tiltSaveDue = true
        end
        if tilted(S.sel.id) and S.tiltWhy and not S.held[S.sel.id] then ui:note("Tilt waits: " .. S.tiltWhy) end
        if ui:button("parkmod", "Save as park mod (for online)") then saveParkModSay() end
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
        local iy = ui:toggle("invy2", "Invert look up/down (controller)", S.lookInvY or false)
        if iy ~= nil and iy ~= (S.lookInvY or false) then S.lookInvY = iy; saveLook() end
        local ix = ui:toggle("invx2", "Invert look left/right (controller)", S.lookInvX or false)
        if ix ~= nil and ix ~= (S.lookInvX or false) then S.lookInvX = ix; saveLook() end
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
        ui:info("Controller", "LB+RB opens")
        ui:info("Left stick", "fly (holding: move it)")
        ui:info("A", "pick up what the cross is on / put down")
        ui:info("B", "cancel (back where it was) / close")
        ui:info("X", "copy (holding: drop a copy)")
        ui:info("Y twice", "remove (what the cross is on)")
        ui:info("RT / LT", "raise / lower")
        ui:info("LB / RB", "turn (holding)")
        ui:info("D-pad up / down", "size (holding) / zoom")
        ui:info("D-pad left / right", "next object")
        ui:info("Right stick / R3", "turn the view / look at it")
        ui:info("View / Menu", "undo / steps")
        ui:info("Hold L3", "fine")
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
        for _, w in ipairs({ "x", "z" }) do
            local tp = sc["tilt" .. w] or {}
            for i = 1, #tp - 1 do
                if tp[i] and tp[i + 1] and segDist(px, tp[i], tp[i + 1]) < 14 then return { kind = "tilt", axis = w } end
            end
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
-- the object under the cross in the middle of the view (aiming with the controller)
local function aimedObject()
    local cpos, f = camBasis()
    local ok, hit = pcall(reskate.world.pick, cpos, cpos + f * 300)
    if not (ok and type(hit) == "table") then return nil end
    local at = (hit.object and hit.object.position) or hit.position
    if not at then return nil end
    local best, bd = nil, hit.object and 1.5 or 0
    for _, ob in pairs(S.known or {}) do
        local dd = len(ob.position - at)
        if dd < bd then best, bd = ob, dd end
    end
    if not best and hit.object and hit.position then
        bd = 6
        for _, ob in pairs(S.known or {}) do
            local dd = len(ob.position - hit.position)
            if dd < bd then best, bd = ob, dd end
        end
    end
    return best
end

-- holding an object with the controller (like Quick Drop): A picks it up, A puts it down, B puts it back
local function startGrab()
    if not (S.sel and S.target) then return end
    local t = S.target
    local tl = S.tilt[S.sel.id]
    S.grab = { id = S.sel.id, pos = t.pos, heading = t.heading, scale = t.scale, tilt = tl and { x = tl.x, z = tl.z } or nil }
    markUndo()
    S.cam.goal = t.pos
    say("Holding " .. titleOf(S.sel.item) .. ".  A: put down   B: cancel   X: copy")
end
S.startGrab = startGrab
local function endHoldMove()
    if S.padRaw then armTighten(S.guides) end
    S.padRaw, S.guides, S.snapLock = nil, nil, nil
end
local function placeGrab()
    endHoldMove()
    S.grab = nil
    S.dirty = true
    if S.target and not sameAsSent(S.target) then S.lastSend = math.min(S.lastSend, S.clock - 250) end
    say("Put down.")
end
local function cancelGrab()
    local g = S.grab
    S.grab = nil
    S.padRaw, S.guides, S.snapLock, S.tighten = nil, nil, nil, nil
    if g and g.fresh and S.sel and S.sel.id == g.id then
        -- a copy just made: cancelling takes it away again
        S.dirty = false
        letGo(g.id)
        local ok, why = reskate.objects.remove(g.id)
        if ok then
            S.tilt[g.id] = nil
            S.tiltSaveDue = true
            select(nil)
            S.lastScan = -1e9
            say("Cancelled: copy taken away.")
        else
            say("Copy not taken away: " .. tostring(why), true)
        end
        return
    end
    if g and S.sel and S.sel.id == g.id then
        S.target = { pos = g.pos, heading = g.heading, scale = g.scale }
        S.tilt[g.id] = g.tilt
        S.tiltSaveDue = true
        S.dirty = true
        S.lastSend = math.min(S.lastSend, S.clock - 250)
    end
    say("Cancelled: back where it was.")
end
-- X: a copy where the held object is now (tilt and all); the original stays in hand
local function copyHeld()
    local t = S.target
    if not (S.sel and t) then return end
    S.copyQ = { item = S.sel.item, pos = t.pos, heading = t.heading, scale = t.scale, tilt = S.tilt[S.sel.id], until_ = S.clock + 3000 }
end
-- X in free view: a copy of the object under the cross, in the same place, picked up to be moved away
local function copyAimed(o)
    S.copyQ = { item = o.item, pos = o.position, heading = o.heading or 0, scale = o.scale or 1, tilt = S.tilt[o.id], until_ = S.clock + 3000, grab = true }
end
local function copyTick()
    local q = S.copyQ
    if not q then return end
    if S.clock > q.until_ then S.copyQ = nil; say("The game was busy: no copy made. Try again.", true) return end
    if not lastApplied() then return end
    local tries = S.tries or {}
    S.tries = tries
    while tries[1] and S.clock - tries[1] > 1050 do table.remove(tries, 1) end
    if #tries >= 4 then return end
    table.insert(tries, S.clock)
    local ok, why = reskate.objects.place(q.item, q.pos, q.heading, q.scale)
    if ok then
        S.expectCopy = { item = q.item, pos = q.pos, tilt = q.tilt and { x = q.tilt.x, z = q.tilt.z } or nil, grab = q.grab }
        S.copyQ = nil
        S.lastScan = -1e9
        say(q.grab and "Copy made: you're holding it." or "Copy made. Move on and press X for another.")
    elseif not BUSY[why] then
        S.copyQ = nil
        say("No copy: " .. tostring(why), true)
    end
end
-- Y twice: remove it
local function deletePress(o)
    o = o or (S.sel and { id = S.sel.id, item = S.sel.item })
    if not o then say("Aim the cross at an object, then Y twice.") return end
    local id = o.id
    if S.delAsk and S.delAsk.id == id and S.clock - S.delAsk.at < 2500 then
        S.delAsk = nil
        local name = titleOf(o.item)
        if S.grab and S.grab.id == id then S.grab = nil; endHoldMove() end
        letGo(id)
        local ok, why = reskate.objects.remove(id)
        if ok then
            S.tilt[id] = nil
            S.tiltSaveDue = true
            if S.sel and S.sel.id == id then select(nil) end
            S.aim = nil
            S.lastScan = -1e9
            say("Removed " .. name .. ".")
        else
            say("Not removed: " .. tostring(why), true)
        end
    else
        S.delAsk = { id = id, at = S.clock }
        say("Press Y again to remove " .. titleOf(o.item) .. ".")
    end
end

local function padEditor(sec)
    local p = readPad()
    if not p then return end
    if S.padWait then
        for k in pairs(PADNAMES) do if p[k] then return end end
        if p.lt > 0.3 or p.rt > 0.3 then return end
        S.padWait = false
    end
    -- the controller is in use: the aiming cross shows
    local anyIn = math.abs(p.lx) > 0.2 or math.abs(p.ly) > 0.2 or math.abs(p.rx) > 0.2 or math.abs(p.ry) > 0.2 or p.lt > 0.2 or p.rt > 0.2
    for k in pairs(PADNAMES) do if p[k] then anyIn = true end end
    if anyIn then S.padUsedAt = S.clock end

    local fine = p.ls
    local t = S.target
    if S.grab and not (S.sel and S.sel.id == S.grab.id) then S.grab = nil end
    local holding = S.grab ~= nil

    if padPress("b", p.b) then
        if holding then cancelGrab() else closeEditor() end
        return
    end
    if padPress("start", p.start) then S.snap = not S.snap; say(S.snap and "Steps on" or "Steps off") end
    if padPress("back", p.back) then
        if holding then S.grab = nil; endHoldMove() end
        undo(); t = S.target; holding = false
    end
    if padPress("rs", p.rs) and t then S.cam.goal = t.pos end
    if padPress("y", p.y) then
        -- holding: the held one; free: the one under the cross (or the picked one)
        if holding then deletePress() else deletePress(S.aim) end
        t = S.target; holding = S.grab ~= nil
    end
    if padPress("a", p.a) then
        if holding then
            placeGrab(); holding = false
        else
            local o = S.aim
            if o and not (S.sel and S.sel.id == o.id) then send(); select(o); t = S.target end
            if S.sel then startGrab(); holding = true else say("Aim the cross at an object, then A.") end
        end
    end
    if padPress("x", p.x) then
        if holding then copyHeld()
        elseif S.aim then copyAimed(S.aim)
        else say("Aim the cross at an object, then X copies it.") end
    end
    if not holding then
        if padStep("left", p.left) then pickNext(-1) t = S.target end
        if padStep("right", p.right) then pickNext(1) t = S.target end
    end

    -- the view: right stick turns it
    local rx, ry = stick(p.rx, p.ry)
    if S.lookInvX then rx = -rx end
    if S.lookInvY then ry = -ry end
    if holding then
        -- holding: the right stick circles round the object (up: from higher up)
        S.cam.yaw -= rx * 2.4 * sec
        S.cam.pitch = clamp(S.cam.pitch - ry * 1.6 * sec, -1.45, 1.45)
    elseif rx ~= 0 or ry ~= 0 then
        -- free, like Quick Drop: the view turns where it stands (up: look up, right: look right)
        local cpos = camBasis()
        S.cam.yaw -= rx * 2.4 * sec
        S.cam.pitch = clamp(S.cam.pitch + ry * 1.6 * sec, -1.45, 1.45)
        local _, f2 = camBasis()
        -- (keeping where the left stick is flying it: the goal moves with the view)
        local ahead = (S.cam.goal or S.cam.target) - S.cam.target
        S.cam.target = cpos + f2 * S.cam.dist
        S.cam.goal = S.cam.target + ahead
    end

    local _, f, r = camBasis()
    local ff, rr = flat(f), flat(r)
    local lx, ly = stick(p.lx, p.ly)
    local up = p.rt - p.lt
    if math.abs(up) < 0.15 then up = 0 end

    if not holding then
        -- free: the left stick flies the view, RT / LT raise and lower it, D-pad up / down zoom
        local sp = math.max(S.cam.dist, 3) * (fine and 0.3 or 1.0) * sec
        if lx ~= 0 or ly ~= 0 or up ~= 0 then
            S.cam.goal = (S.cam.goal or S.cam.target) + (ff * ly + rr * lx) * sp + V(0, up * sp * 0.6, 0)
        end
        if p.up then S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (1 - 1.5 * sec), 0.5, 300) end
        if p.down then S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (1 + 1.5 * sec), 0.5, 300) end
        -- what A would pick up
        S.aim = aimedObject()
        if S.padBurst then
            S.padBurst = false
            S.padMoving = false
        end
        return
    end
    S.aim = nil
    if not t then return end

    -- holding: one undo step for the whole hold (made when it was picked up)
    local active = false
    local function begin() active = true; S.padBurst = true end

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
        if not S.padRaw then
            S.padHd0 = t.heading
            local tl0 = S.tilt[S.sel.id]
            S.padTilt0 = tl0 and { x = tl0.x, z = tl0.z } or nil
        end
        S.padRaw = (S.padRaw or t.pos) + mv
        local ntl
        t.pos, t.heading, S.guides, ntl = snapTurned(S.padRaw, S.padHd0 or t.heading, t.scale, allowFree(lx ~= 0 or ly ~= 0, up ~= 0), S.padTilt0)
        S.tilt[S.sel.id] = ntl
        S.cam.goal = (S.cam.goal or S.cam.target) + mv
        S.cam.target += mv
    else
        if S.padRaw then armTighten(S.guides); S.guides = nil; S.snapLock = nil end
        S.padRaw = nil
    end

    -- turn: bumpers, 15 degrees (L3 held: 1)
    local tstep = math.rad(fine and 1 or 15)
    if padStep("lb", p.lb) then begin(); t.heading = wrap(round(t.heading + tstep, tstep)) end
    if padStep("rb", p.rb) then begin(); t.heading = wrap(round(t.heading - tstep, tstep)) end
    if p.lb or p.rb then active = true end
    if (p.lb or p.rb) and S.padRaw then S.padHd0 = t.heading end

    -- size: D-pad up / down, 0.1 (L3 held: 0.01)
    local sstep = fine and 0.01 or 0.1
    if padStep("up", p.up) then begin(); t.scale = clamp(round(t.scale + sstep, sstep), 0.1, 10) end
    if padStep("down", p.down) then begin(); t.scale = clamp(round(t.scale - sstep, sstep), 0.1, 10) end
    if p.up or p.down then active = true end

    if active then
        S.dirty = true
        S.padMoving = true
    elseif S.padBurst then
        -- let go of the stick: send the exact place soon (still held)
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

    do
        local okc, errc = pcall(copyTick)
        if not okc then S.copyQ = nil; reskate.log("Quick Drop helper: copy: " .. tostring(errc), "warn") end
    end
    do
        local ok, err = pcall(tiltTick)
        if not ok and not S.tiltWarned then S.tiltWarned = true; reskate.log("Quick Drop helper: tilt: " .. tostring(err), "warn") end
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
                local tl0 = S.tilt[S.sel.id]
                h.start = { pos = t.pos, heading = t.heading, scale = t.scale, px = px, tilt = tl0 and { x = tl0.x, z = tl0.z } or nil }
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
                elseif h.kind == "tilt" then
                    local c0 = S.screen.center
                    h.lastA = math.atan2(-(px.y - c0.y), px.x - c0.x)
                    h.acc = 0
                    local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
                    h.t0 = { x = tl.x, z = tl.z }
                    local AX = axesFor(t.heading)
                    local A = h.axis == "x" and AX[1][1] or AX[3][1]
                    local _, cf = camBasis()
                    h.sign = dot(cf, A) <= 0 and 1 or -1
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
                    local ntl
                    if toObjects then t.pos, t.heading, S.guides, ntl = snapTurned(t.pos, g.start.heading, t.scale, allowAlong(way), g.start.tilt) else t.heading, ntl = g.start.heading, g.start.tilt end
                    S.tilt[S.sel.id] = ntl
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
                        local ntl
                        if toObjects then t.pos, t.heading, S.guides, ntl = snapTurned(t.pos, g.start.heading, t.scale, allowIn(g.n), g.start.tilt) else t.heading, ntl = g.start.heading, g.start.tilt end
                        S.tilt[S.sel.id] = ntl
                        g.moved = true
                    end
                elseif g.kind == "tilt" then
                    local c0 = S.screen.center or g.start.px
                    if d2(px, c0) > 6 then
                        local a = math.atan2(-(px.y - c0.y), px.x - c0.x)
                        g.acc += wrap(a - g.lastA) * g.sign
                        g.lastA = a
                        local v = wrap(g.t0[g.axis] + g.acc)
                        if S.snap then v = round(v, math.rad(reskate.input.key("Shift") and 45 or 15)) end
                        -- level again (or a quarter turn) when close to it
                        if toObjects and math.abs(v - round(v, math.pi / 2)) < SNAP_TURN then v = round(v, math.pi / 2) end
                        local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
                        S.tilt[S.sel.id] = { x = g.axis == "x" and v or tl.x, z = g.axis == "z" and v or tl.z }
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
            if S.drag and S.drag.moved and S.drag.kind ~= "tilt" then S.dirty = true end
        elseif not c.left and S.mouse.left and S.drag then
            if S.drag.kind == "click" then clickPick(px) end
            local moved = S.drag.moved
            local wasTilt = S.drag.kind == "tilt"
            S.snapLock = nil
            S.drag = nil
            if wasTilt then
                if moved then S.tiltSaveDue = true end
                moved = false
            end
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

-- an outline as it stands: round its base, round its top, and up its corners
local COS25 = math.cos(math.rad(25))
local function drawShape(d, sh, col, th, xf)
    local pts = sh.pts
    local n = #pts
    if n < 3 then return false end
    xf = xf or function(v) return v end
    local base, up = UP * (sh.ylo - sh.p.y), UP * (sh.yhi - sh.ylo)
    for i = 1, n do
        local a, b = pts[i] + base, pts[i % n + 1] + base
        d:world_line(xf(a), xf(b), { colour = col, thickness = th })
        d:world_line(xf(a + up), xf(b + up), { colour = col, thickness = th })
    end
    for i = 1, n do
        local a, b, c = pts[(i - 2) % n + 1], pts[i], pts[i % n + 1]
        if n <= 8 or dot(norm(b - a), norm(c - b)) < COS25 then
            d:world_line(xf(b + base), xf(b + base + up), { colour = col, thickness = th })
        end
    end
    return true
end

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
    -- the controller's aiming cross, and the object it is on (what A picks up)
    if S.padUsedAt and S.clock - S.padUsedAt < 15000 then
        local c = V(S.size.x / 2, S.size.y / 2, 0)
        if S.grab then
            d:text(c + V(-170, 150, 0), "A put down    B cancel    X copy", { size = 18, colour = "#ffffff", shadow = true })
        else
            d:circle(c, 8, { colour = "#ffffffcc", thickness = 2 })
            d:line(c - V(16, 0, 0), c - V(10, 0, 0), { colour = "#ffffffcc", thickness = 2 })
            d:line(c + V(10, 0, 0), c + V(16, 0, 0), { colour = "#ffffffcc", thickness = 2 })
            d:line(c - V(0, 16, 0), c - V(0, 10, 0), { colour = "#ffffffcc", thickness = 2 })
            d:line(c + V(0, 10, 0), c + V(0, 16, 0), { colour = "#ffffffcc", thickness = 2 })
            if S.aim then
                local so = placedSolid(S.aim)
                drawShape(d, so.shape or so, "#ffffff", 3, so.xf)
                d:text(c + V(14, 14, 0), titleOf(S.aim.item) .. "   A pick up   X copy   Y remove", { size = 16, colour = "#ffffff", shadow = true })
            end
        end
    end
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
        -- the tilt rings: red tips it forward and back (about its x), blue to the side (about its z)
        local AX = axesFor(t.heading)
        local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
        for _, w in ipairs({ { "x", AX[1], AX[2][1], AX[3][1] }, { "z", AX[3], AX[2][1], AX[1][1] } }) do
            local key, axc, u, v = w[1], w[2], w[3], w[4]
            local tp = {}
            for i = 0, 48 do
                local a = i / 48 * 2 * math.pi
                tp[i + 1] = d:world_to_screen(p + (u * math.cos(a) + v * math.sin(a)) * (L * 0.8))
            end
            local tcol = colourOf(axc[2], hot("tilt") and (S.drag or S.hover).axis == key)
            for i = 1, 48 do
                if tp[i] and tp[i + 1] then d:line(tp[i], tp[i + 1], { colour = tcol, thickness = 4 }) end
            end
            S.screen["tilt" .. key] = tp
        end
        if math.abs(tl.x) > 1e-4 or math.abs(tl.z) > 1e-4 then
            d:text(center + V(14, -52, 0), string.format("tilt %.0f°, %.0f°", math.deg(tl.x), math.deg(tl.z)), { size = 16, colour = "#ffffff", shadow = true })
        end
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
                if drawShape(d, gd.nb.shape or gd.nb, "#35e0ff", 3, gd.nb.xf) then
                    -- drawn
                elseif #nc == 8 then
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
        local sh = S.itemBox[S.sel.item] and worldShape(S.sel.item, p, t.heading, t.scale) or nil
        local tl = tilted(S.sel.id) and S.tilt[S.sel.id] or nil
        local xf = tl and function(v) return tiltPoint(p, t.heading, tl, v) end or nil
        if xf then for i = 0, 7 do c[i] = xf(c[i]) end end
        if not (sh and drawShape(d, sh, col, 2, xf)) then
            for _, e in ipairs(BOX_EDGES) do
                d:world_line(c[e[1]], c[e[2]], { colour = col, thickness = 2 })
            end
        end
    end
end)

reskate.on("load", function() reskate.log("Quick Drop helper ready: drop an object, then F6 (or hold Ctrl and use [ ] PgUp PgDn Z X arrows).") end)
