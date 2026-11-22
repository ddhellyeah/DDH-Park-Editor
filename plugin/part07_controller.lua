-- DDH Park Editor, part07_controller: the controller: reading the pad, holding, copying, choosing what it snaps to, the edit queue.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local BUSY = PE.BUSY
local FN = PE.FN
local S = PE.S
local SNAP_REACH = PE.SNAP_REACH
local V = PE.V
local apart3 = PE.apart3
local armTighten = PE.armTighten
local camBasis = PE.camBasis
local clamp = PE.clamp
local cornersOf = PE.cornersOf
local dot = PE.dot
local follower = PE.follower
local groupBase = PE.groupBase
local groupCount = PE.groupCount
local lastApplied = PE.lastApplied
local len = PE.len
local letGo = PE.letGo
local markUndo = PE.markUndo
local placedSolid = PE.placedSolid
local poseOf = PE.poseOf
local rotY = PE.rotY
local sameAsSent = PE.sameAsSent
local say = PE.say
local select = PE.select
local send = PE.send
local titleOf = PE.titleOf
local worldBox = PE.worldBox
local worldSolid = PE.worldSolid
local wrap = PE.wrap

-- ---------------------------------------------------------------- the controller
-- Reads the pad through reskate.input.gamepad(). Button names are read from its buttons table (several spellings),
-- or from the XInput bit mask (reskate.input.pad_bits) when the table has none. The first time the editor opens
-- with a pad, what the pad sends is written to ReSkate.log once, so the names can be checked.
FN.XBITS = { up = 0x0001, down = 0x0002, left = 0x0004, right = 0x0008, start = 0x0010, back = 0x0020,
    ls = 0x0040, rs = 0x0080, lb = 0x0100, rb = 0x0200, a = 0x1000, b = 0x2000, x = 0x4000, y = 0x8000 }
FN.PADNAMES = {
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

function FN.band(a, b)
    if bit32 and bit32.band then return bit32.band(a, b) end
    local r, k = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r += k end
        a, b, k = math.floor(a / 2), math.floor(b / 2), k * 2
    end
    return r
end

function FN.describe(v, depth)
    depth = depth or 0
    if type(v) ~= "table" or depth > 2 then return tostring(v) end
    local parts = {}
    for k, x in pairs(v) do table.insert(parts, tostring(k) .. "=" .. FN.describe(x, depth + 1)) end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function axis(v, full)
    v = tonumber(v) or 0
    if math.abs(v) > 1.5 then v = v / full end
    return clamp(v, -1, 1)
end

-- the pad by job: the buttons as moved in Settings (part17_keys); FN.readPadRaw is the pad as it is
function FN.readPad()
    local p = FN.readPadRaw()
    if p and FN.padRemap then p = FN.padRemap(p) end
    return p
end
function FN.readPadRaw()
    if not (reskate.input and reskate.input.gamepad) then return nil end
    local ok, g = pcall(reskate.input.gamepad)
    if not ok then
        if not S.padErr then S.padErr = true; reskate.log("Quick Drop helper: controller read failed: " .. tostring(g), "warn") end
        return nil
    end
    if type(g) ~= "table" then return nil end
    -- (a PlayStation pad: its buttons are shown as Cross, Circle, L1... when Settings says Auto)
    S.padPS = g.playstation == true or (type(g.buttons) == "table" and g.buttons.cross ~= nil)
    -- (first seen while the editor holds the controller: hidden from the game now)
    if S.padPS and S.padCaptured and not S.psHidden and FN.hidePS then FN.hidePS(true) end
    local bits = nil
    local bt = g.buttons
    if type(bt) == "number" then bits = bt end
    if type(bt) ~= "table" and reskate.input.pad_bits then
        local ok2, pb = pcall(reskate.input.pad_bits)
        if ok2 and type(pb) == "number" then bits = bits or pb end
    end
    if not S.padLogged then
        S.padLogged = true
        reskate.log("Quick Drop helper: controller sends " .. FN.describe(g) .. (bits and string.format(" bits=0x%04x", bits) or ""))
    end
    local p = {
        lx = axis(g.left_x, 32767), ly = axis(g.left_y, 32767),
        rx = axis(g.right_x, 32767), ry = axis(g.right_y, 32767),
        lt = clamp(axis(g.left_trigger, 255), 0, 1), rt = clamp(axis(g.right_trigger, 255), 0, 1),
    }
    for key, names in pairs(FN.PADNAMES) do
        local down = false
        if type(bt) == "table" then
            for _, n in ipairs(names) do if bt[n] then down = true break end end
        end
        if not down and bits then down = FN.band(bits, FN.XBITS[key]) ~= 0 end
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

function FN.pickNext(dir)
    local list = FN.objectsNow()
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

-- (ReSkate's capture keeps the first Xbox-style controller from the game; a PlayStation pad, which ReSkate reads
-- by itself, is named "playstation" and is kept from the game too, or the skater moves with it)
local PS_FORMS = {
    function(on) return reskate.input.capture(on, "playstation") end,
    function(on) return reskate.input.capture("playstation", on) end,
}
local psForm = nil
local function capturePS(on)
    if psForm == false then return end
    if psForm then pcall(PS_FORMS[psForm], on) return end
    local why = {}
    for i, f in ipairs(PS_FORMS) do
        local ok, err = pcall(f, on)
        if ok then
            psForm = i
            reskate.log("Quick Drop helper: the PlayStation controller is kept from the game too (form " .. i .. ")")
            return
        end
        why[#why + 1] = tostring(err)
    end
    psForm = false
    reskate.log("Quick Drop helper: could not keep a PlayStation controller from the game: " .. table.concat(why, " | "), "warn")
end
-- a PlayStation pad's sticks, triggers and buttons hidden from the game (on) or given back (off). Done again when
-- a PlayStation pad is first seen while the editor is open: the pad may not have been read yet when it opened,
-- and before, the hiding was then skipped for the whole time it was open (the skater moved with the pad)
local function hidePS(on)
    if not reskate.input.hide then return end
    if on and (S.psHidden or S.psHideFailed) then return end
    if not on and not S.psHidden then return end
    local ok2, err2
    if on then
        ok2, err2 = pcall(reskate.input.hide, { left_x = true, left_y = true, right_x = true, right_y = true, left_trigger = true,
            right_trigger = true, buttons = true, left_stick_click = true, right_stick_click = true })
    else
        ok2, err2 = pcall(reskate.input.hide, nil)
        if not ok2 then ok2, err2 = pcall(reskate.input.hide, {}) end
    end
    S.psHidden = on and ok2 or nil
    if on and not ok2 then S.psHideFailed = true end
    reskate.log("Quick Drop helper: " .. (on and "hiding the PlayStation controller from the game: " or "PlayStation controller given back to the game: ")
        .. (ok2 and "done" or tostring(err2)), ok2 and "info" or "warn")
end
FN.hidePS = hidePS
function FN.padCapture(on)
    if not (reskate.input and reskate.input.capture) then return end
    -- (is it a PlayStation pad? read it now, if not read yet)
    if on and S.padPS == nil and FN.readPadRaw then pcall(FN.readPadRaw) end
    if S.padCaptured ~= on then
        local ok, why = pcall(reskate.input.capture, on)
        if ok then
            S.padCaptured = on
        elseif on and not S.captureErr then
            S.captureErr = true
            reskate.log("Quick Drop helper: could not keep the controller from the game: " .. tostring(why), "warn")
        end
        capturePS(on)
    end
    if on then
        if S.padPS then hidePS(true) end
    else
        hidePS(false)
    end
end

PE.padCaptureOn = function() FN.padCapture(true) end
PE.padCaptureOff = function() FN.padCapture(false) end

-- the open editor with a controller
-- the placed object a ray hit is really on: where it hit is on (or within a hand's width of) its box. The one
-- the ray says it hit comes first; else the one whose box is nearest the hit (objects standing in each other).
-- A hit on the ground or the map's own pieces next to an object is not that object.
function FN.objectAtHit(hit, list)
    if not (type(hit) == "table" and hit.position) then return nil end
    local hp = hit.position
    local op = hit.object and hit.object.position
    local best, bs = nil, math.huge
    for _, ob in pairs(list or S.known or {}) do
        local dd
        if S.itemBox[ob.item] then
            local so = placedSolid(ob)
            if so.x0 and so.x0 < math.huge then
                local dx = math.max(so.x0 - hp.x, 0, hp.x - so.x1)
                local dy = math.max(so.y0 - hp.y, 0, hp.y - so.y1)
                local dz = math.max(so.z0 - hp.z, 0, hp.z - so.z1)
                dd = math.sqrt(dx * dx + dy * dy + dz * dz)
            end
        end
        -- (size unknown: its middle near the hit)
        if not dd then dd = math.max(0, len(ob.position - hp) - 0.75) end
        if dd <= 0.15 then
            local score = dd
            if op and len(ob.position - op) < 0.05 then score -= 1 end
            if score < bs then best, bs = ob, score end
        end
    end
    return best
end
-- the object under the cross in the middle of the view (aiming with the controller)
function FN.aimedObject()
    local cpos, f = camBasis()
    local ok, hit = pcall(reskate.world.pick, cpos, cpos + f * 300)
    if not ok then return nil end
    return FN.objectAtHit(hit)
end

-- holding an object with the controller (like Quick Drop): A picks it up, A puts it down, B puts it back
local function startGrab()
    if not (S.sel and S.target) then return end
    local t = S.target
    local tl = S.tilt[S.sel.id]
    S.grab = { id = S.sel.id, pos = t.pos, heading = t.heading, scale = t.scale, tilt = tl and { x = tl.x, z = tl.z } or nil }
    S.snapPick = nil
    markUndo()
    if S.group[S.sel.id] then groupBase() else S.gbase = nil end
    S.cam.goal = t.pos
    local n = S.gbase and groupCount() or 1
    if n > 1 then
        say(string.format(FN.padText("Holding %d objects.  A: put down   B: cancel   X: copy them   D-pad left/right: zoom"), n))
    else
        say("Holding " .. titleOf(S.sel.item) .. FN.padText(".  A: put down   B: cancel   X: copy   D-pad left/right: zoom"))
    end
end
S.startGrab = startGrab
local function endHoldMove()
    if S.padRaw then armTighten(S.guides) end
    S.padRaw, S.guides, S.snapLock = nil, nil, nil
end
function FN.placeGrab()
    endHoldMove()
    S.grab = nil
    S.snapPick = nil
    S.dirty = true
    if S.target and not sameAsSent(S.target) then S.lastSend = math.min(S.lastSend, S.clock - 250) end
    say("Put down.")
end
function FN.cancelGrab()
    local g = S.grab
    S.grab = nil
    S.snapPick = nil
    S.toolsWin = nil
    S.padRaw, S.guides, S.snapLock, S.tighten = nil, nil, nil, nil
    if g and g.copyRec then
        -- the group was copied in place and picked up: the copies go again, the group goes back
        local r = g.copyRec
        r.cancelled = true
        for i = #S.q, 1, -1 do if S.q[i].rec == r then table.remove(S.q, i) end end
        for _, id in ipairs(r.ids) do table.insert(S.q, { op = "remove", id = id, rec = { ids = {}, total = 1, done = 0, failed = 0, quiet = true } }) end
        r.ids = {}
        for i = #S.undo, 1, -1 do if S.undo[i].rec == r then table.remove(S.undo, i) break end end
    end
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
-- the held object and the ones it takes along, as they are now
function FN.heldList()
    local L = S.target
    local out = { { id = S.sel.id, item = S.sel.item, pos = L.pos, heading = L.heading, scale = L.scale, tilt = S.tilt[S.sel.id] } }
    local b = S.gbase
    if b and b.leader == S.sel.id then
        for id in pairs(b.m) do
            local p, o = poseOf(id), S.known and S.known[id]
            if p and o then out[#out + 1] = { id = id, item = o.item, pos = p.pos, heading = p.heading, scale = p.scale, tilt = S.tilt[id] } end
        end
    end
    return out
end
-- how long a set of objects is along a direction (their boxes; 1 m for one of unknown size)
local function extentAlong(list, dir)
    local lo, hi = math.huge, -math.huge
    for _, s in ipairs(list) do
        local bx = worldBox(s.item, s.pos, s.heading, s.scale)
        local cs = cornersOf(bx)
        if #cs == 1 then
            local k = dot(s.pos, dir)
            lo, hi = math.min(lo, k - 0.5), math.max(hi, k + 0.5)
        else
            for _, c in ipairs(cs) do local k = dot(c, dir); lo, hi = math.min(lo, k), math.max(hi, k) end
        end
    end
    if lo > hi then return 1 end
    return math.max(hi - lo, 0.05)
end
function FN.newRec(label) return { ids = {}, total = 0, done = 0, failed = 0, label = label } end
-- copies to make (each: item, pos, heading, scale, tilt), one after another; one undo step takes them all away
local MAX_COPIES = 200
local function queueCopies(list, label)
    local rec = FN.newRec(label)
    for i, c in ipairs(list) do
        if i > MAX_COPIES then break end
        table.insert(S.q, { op = "place", item = c.item, pos = c.pos, heading = c.heading, scale = c.scale, tilt = c.tilt, rec = rec })
        rec.total += 1
    end
    rec.items = list
    if rec.total > 0 then S.pushUndo({ kind = "placed", rec = rec }) end
    if #list > MAX_COPIES then say(string.format("Only the first %d copies are made.", MAX_COPIES), true) end
    return rec
end
-- X: a copy where the held object is now (tilt and all); the original stays in hand
function FN.copyHeld()
    local t = S.target
    if not (S.sel and t) then return end
    if S.gbase and S.gbase.leader == S.sel.id then
        local list = FN.heldList()
        queueCopies(list, "Copies")
        say(string.format("Copying %d objects...", #list))
        return
    end
    S.copyQ = { item = S.sel.item, pos = t.pos, heading = t.heading, scale = t.scale, tilt = S.tilt[S.sel.id], until_ = S.clock + 3000 }
end
-- the objects near the held one, nearest first (for choosing what it snaps to)
function FN.snapChoices()
    local out = {}
    if not (S.sel and S.target and S.known) then return out end
    local t = S.target
    local me = worldSolid(S.sel.item, t.pos, t.heading, t.scale, S.tilt[S.sel.id])
    for id, o in pairs(S.known) do
        if id ~= S.sel.id and not follower(id) then
            local d = len(o.position - t.pos)
            if d < 30 then
                local nb = placedSolid(o)
                local gap = (me.x0 and nb.x0) and apart3(me, nb) or d
                if gap < SNAP_REACH then out[#out + 1] = { id = id, gap = gap, d = d } end
            end
        end
    end
    table.sort(out, function(a, b) if math.abs(a.gap - b.gap) > 1e-4 then return a.gap < b.gap end return a.d < b.d end)
    while #out > 6 do table.remove(out) end
    return out
end
-- auto -> the nearest -> the next ... -> off -> auto
function FN.cycleSnap()
    local ch = FN.snapChoices()
    local cur = S.snapPick
    local nxt
    if cur == nil then
        nxt = ch[1] and ch[1].id or "off"
    elseif cur == "off" then
        nxt = nil
    else
        local at = 0
        for i, c in ipairs(ch) do if c.id == cur then at = i end end
        nxt = ch[at + 1] and ch[at + 1].id or "off"
    end
    S.snapPick = nxt
    S.snapLock, S.guides = nil, nil
    if nxt == nil then say("Snap: auto (the nearest object)")
    elseif nxt == "off" then say("Snap: off")
    else say("Snap: only to " .. titleOf(S.known[nxt].item) .. "  (again: the next one)") end
end
S.cycleSnap = FN.cycleSnap
S.nextSnap = function() FN.nextSnapObject() end
-- L3: the nearest object first, then the next nearest, and round again. The order is taken at the first press and
-- kept while L3 keeps being tapped (within 3 s), so it does not jump about as things move.
function FN.l3Cycle(kind, makeList)
    local cyc = S.l3Cycle
    if not (cyc and cyc.kind == kind and S.clock - cyc.at < 3000 and #cyc.ids > 0) then
        local list = makeList()
        if #list == 0 then return nil end
        cyc = { kind = kind, ids = list, i = 0 }
        S.l3Cycle = cyc
    end
    cyc.at = S.clock
    for _ = 1, #cyc.ids do
        cyc.i = cyc.i % #cyc.ids + 1
        local id = cyc.ids[cyc.i]
        if S.known and S.known[id] then return id, cyc.i, #cyc.ids end
    end
    return nil
end
-- objects near a point, nearest first (their boxes' distance)
function FN.nearestTo(p, maxN, skip)
    local out = {}
    for id, o in pairs(S.known or {}) do
        if not (skip and skip[id]) then
            local d = len(o.position - p)
            if d < 40 then
                local b = S.itemBox[o.item]
                local gap = d - (b and len((b[2] - b[1]) * (o.scale or 1)) / 2 or 0)
                out[#out + 1] = { id = id, gap = math.max(gap, 0), d = d }
            end
        end
    end
    table.sort(out, function(a, b) if math.abs(a.gap - b.gap) > 1e-3 then return a.gap < b.gap end return a.d < b.d end)
    local ids = {}
    for i, e in ipairs(out) do if i > (maxN or 8) then break end; ids[i] = e.id end
    return ids
end
-- held: what it snaps to
function FN.nextSnapObject()
    local id, i, n = FN.l3Cycle("snap", function()
        local ids = {}
        for k, c in ipairs(FN.snapChoices()) do ids[k] = c.id end
        return ids
    end)
    if not id then say("Nothing near to snap to.") return end
    S.snapPick = id
    S.snapLock, S.guides = nil, nil
    say(string.format(FN.padText("Snap: %s  (%d of %d, L3: the next)"), titleOf(S.known[id].item), i, n))
end
-- carrying a set: what it snaps to, nearest to the set first
function FN.nextCarrySnap()
    local c = S.carry
    if not c then return end
    local id, i, n = FN.l3Cycle("carry", function() return FN.nearestTo(c.pos, 8) end)
    if not id then say("Nothing near to snap to.") return end
    S.snapPick = id
    c.guides = nil
    say(string.format(FN.padText("Snap: %s  (%d of %d, L3: the next)"), titleOf(S.known[id].item), i, n))
end
-- free: what the cross is on (A picks it up), nearest to where the cross points first
function FN.nextAimObject()
    local at = FN.crossPoint()
    local id, i, n = FN.l3Cycle("aim", function() return FN.nearestTo(at, 8) end)
    if not id then say("Nothing near.") return end
    S.aimLock, S.aimLockAt = id, S.clock
    S.aim = S.known[id]
    say(string.format(FN.padText("%s  (%d of %d, L3: the next, A: pick up)"), titleOf(S.known[id].item), i, n))
end
-- View: the snapping mode, auto -> one object (the nearest) -> off -> auto
function FN.snapMode()
    local cur = S.snapPick
    if cur == nil then
        local ch = FN.snapChoices()
        if ch[1] then S.snapPick = ch[1].id else S.snapPick = "off" end
    elseif cur == "off" then
        S.snapPick = nil
    else
        S.snapPick = "off"
    end
    S.snapLock, S.guides = nil, nil
    local sp = S.snapPick
    if sp == nil then say("Snap: auto (the nearest object)")
    elseif sp == "off" then say("Snap: off")
    else say("Snap: one object, " .. titleOf(S.known[sp].item) .. FN.padText("  (L3: the next one)")) end
end
function FN.snapLabel()
    local sp = S.snapPick
    if sp == nil then return "auto" end
    if sp == "off" then return "off" end
    local o = S.known and S.known[sp]
    return o and titleOf(o.item) or "auto"
end

local startGrabRef
-- X in free view: a copy of the object under the cross, in the same place, picked up to be moved away
function FN.copyAimed(o)
    if S.group[o.id] and groupCount() > 1 then
        -- a group: copies stay where they are, and the group itself is picked up (the same thing, seen from here)
        send()
        if not (S.sel and S.sel.id == o.id) then select(o) end
        local list = {}
        for id in pairs(S.group) do
            local p, ob = poseOf(id), S.known and S.known[id]
            if id == S.sel.id and S.target then p = S.target end
            if p and ob then list[#list + 1] = { item = ob.item, pos = p.pos, heading = p.heading, scale = p.scale, tilt = S.tilt[id] } end
        end
        local rec = queueCopies(list, "Copies")
        startGrabRef()
        if S.grab then S.grab.copyRec = rec end
        say(string.format(FN.padText("Copied %d objects in place: you're holding the group. B takes the copies away."), #list))
        return
    end
    S.copyQ = { item = o.item, pos = o.position, heading = o.heading or 0, scale = o.scale or 1, tilt = S.tilt[o.id], until_ = S.clock + 3000, grab = true }
end
function FN.copyTick()
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
        say(q.grab and "Copy made: you're holding it." or FN.padText("Copy made. Move on and press X for another."))
    elseif not BUSY[why] then
        S.copyQ = nil
        say("No copy: " .. tostring(why), true)
    end
end
-- Y twice: remove it (a group member: the whole group)
function FN.deletePress(o)
    o = o or (S.sel and { id = S.sel.id, item = S.sel.item })
    if not o then say(FN.padText("Aim the cross at an object, then Y twice.")) return end
    local id = o.id
    local n = groupCount()
    if S.group[id] and n > 1 then
        if S.delAsk and S.delAsk.id == id and S.delAsk.all and S.clock - S.delAsk.at < 2500 then
            S.delAsk = nil
            if S.grab then S.grab = nil; endHoldMove() end
            local ids = {}
            for gid in pairs(S.group) do ids[#ids + 1] = gid end
            local rec = S.removeUndoable(ids, "Removed")
            S.group, S.gbase = {}, nil
            S.aim = nil
            say(string.format(FN.padText("Removing %d objects... (View: undo)"), rec.total))
        else
            S.delAsk = { id = id, at = S.clock, all = true }
            say(string.format(FN.padText("Press Y again to remove all %d objects in the group."), n))
        end
        return
    end
    if S.delAsk and S.delAsk.id == id and S.clock - S.delAsk.at < 2500 then
        S.delAsk = nil
        local name = titleOf(o.item)
        if S.grab and S.grab.id == id then S.grab = nil; endHoldMove() end
        local keep = S.itemsOf({ id })
        letGo(id)
        local ok, why = reskate.objects.remove(id)
        if ok then
            if #keep > 0 then S.pushUndo({ kind = "removed", items = keep }) end
            S.tilt[id] = nil
            S.tiltSaveDue = true
            if S.sel and S.sel.id == id then select(nil) end
            S.aim = nil
            S.lastScan = -1e9
            say("Removed " .. name .. FN.padText(".  (View: undo)"))
        elseif BUSY[why] then
            -- the game is busy with an edit: removed as soon as it is free
            if #keep > 0 then S.pushUndo({ kind = "removed", items = keep }) end
            table.insert(S.q, { op = "remove", id = id, rec = { done = 0, failed = 0, total = 1, label = "Remove", quiet = true } })
            S.aim = nil
            say("Removing " .. name .. FN.padText("...  (View: undo)"))
        else
            say("Not removed: " .. tostring(why), true)
        end
    else
        S.delAsk = { id = id, at = S.clock }
        say(FN.padText("Press Y again to remove ") .. titleOf(o.item) .. ".")
    end
end

startGrabRef = startGrab

function FN.toggleGroup(o)
    if not o then say(FN.padText("Aim the cross at an object, then RB puts it in the group.")) return end
    if S.group[o.id] then S.group[o.id] = nil else S.group[o.id] = true end
    S.gbase = nil
    local n = groupCount()
    if n == 0 then say("Group cleared.")
    else say(string.format(FN.padText("Group: %d object%s.  RB: add / take out   LB: clear   A on one: move them all"), n, n == 1 and "" or "s")) end
end
function FN.clearGroup()
    if groupCount() == 0 then return end
    S.group, S.gbase = {}, nil
    say("Group cleared.")
end
S.toggleGroup, S.clearGroup = FN.toggleGroup, FN.clearGroup

-- each tick: where the followers go, from where the leader is going
function FN.followTick()
    local b = S.gbase
    if not (b and S.sel and S.target and b.leader == S.sel.id) then return end
    local L = S.target
    for id, m in pairs(b.m) do
        if S.known and S.known[id] and S.group[id] then
            S.gt[id] = { pos = L.pos + rotY(m.off * L.scale, L.heading), heading = wrap(L.heading + m.dh), scale = clamp(m.sr * L.scale, 0.1, 10) }
        else
            b.m[id] = nil
        end
    end
end
function FN.samePose(a, b)
    return a ~= nil and b ~= nil and len(a.pos - b.pos) < 1e-4 and math.abs(wrap(a.heading - b.heading)) < 1e-5 and math.abs(a.scale - b.scale) < 1e-5
end
function FN.freeSlot(keep)
    local tries = S.tries or {}
    S.tries = tries
    while tries[1] and S.clock - tries[1] > 1050 do table.remove(tries, 1) end
    return #tries < 4 - (keep or 0)
end
-- the followers' moves: once the held one is put down (and its own move is sent)
function FN.sendGroup()
    if S.grab or (S.drag and S.drag.moved) or S.dirty or S.copyQ then return end
    if S.clock - (S.gLast or -1e9) < 120 then return end
    if not lastApplied() then return end
    for id, g in pairs(S.gt) do
        local o = S.known and S.known[id]
        if not o or (S.sel and id == S.sel.id) then
            S.gt[id], S.gs[id] = nil, nil
        elseif FN.samePose(g, S.gs[id]) then
            -- arrived: no longer needed unless it is still being taken along
            if not follower(id) and len(o.position - g.pos) < 0.01 then S.gt[id], S.gs[id] = nil, nil end
        else
            if not FN.freeSlot() then return end
            table.insert(S.tries, S.clock)
            S.gLast = S.clock
            local hd = nil
            if math.abs(wrap(g.heading - (o.heading or 0))) > 1e-5 then hd = g.heading end
            local ok, why = reskate.objects.move(id, g.pos, hd, g.scale)
            if ok then
                S.gs[id] = { pos = g.pos, heading = g.heading, scale = g.scale }
                S.lastSent = { id = id, pos = g.pos, heading = g.heading, scale = g.scale, at = S.clock }
            elseif not BUSY[why] then
                S.gs[id] = { pos = g.pos, heading = g.heading, scale = g.scale }
                say("One of the group could not be moved: " .. tostring(why), true)
            end
            return
        end
    end
end
-- copies and removals, one after another (leaving room for the held object's own moves)
function FN.qTick()
    local e = S.q[1]
    if not e then return end
    if S.clock - (S.qLast or -1e9) < 120 then return end
    if not FN.freeSlot((S.dirty or S.grab) and 1 or 0) then return end
    table.insert(S.tries, S.clock)
    S.qLast = S.clock
    local ok, why
    if e.op == "place" then
        ok, why = reskate.objects.place(e.item, e.pos, e.heading, e.scale)
    else
        if not (S.known and S.known[e.id]) then ok = true else S.buried[e.id] = nil; letGo(e.id); ok, why = reskate.objects.remove(e.id) end
    end
    local r = e.rec
    if ok then
        table.remove(S.q, 1)
        r.done += 1
        if e.op == "place" then
            table.insert(S.expectMany, { item = e.item, pos = e.pos, tilt = e.tilt, rec = r, at = S.clock, idx = e.idx })
        else
            S.tilt[e.id] = nil
            S.tiltSaveDue = true
            S.group[e.id], S.gt[e.id], S.gs[e.id] = nil, nil, nil
            if S.sel and S.sel.id == e.id then select(nil) end
        end
        S.lastScan = math.min(S.lastScan, S.clock - 350)
    elseif BUSY[why] then
        return
    else
        table.remove(S.q, 1)
        r.failed += 1
        reskate.log("Quick Drop helper: " .. (e.op == "place" and "copy" or "remove") .. " refused: " .. tostring(why), "warn")
    end
    if r.done + r.failed >= r.total and not r.quiet then
        if r.failed > 0 then say(string.format("%s: %d done, %d refused by the game (see ReSkate.log).", r.label, r.done, r.failed), true)
        else say(string.format("%s: %d done.", r.label, r.done)) end
    elseif not r.quiet and r.total > 4 and r.done % 5 == 0 then
        say(string.format("%s: %d of %d...", r.label, r.done, r.total))
    end
end

-- shared with the parts after this one
PE.MAX_COPIES = MAX_COPIES
PE.endHoldMove = endHoldMove
PE.extentAlong = extentAlong
PE.padPress = padPress
PE.padStep = padStep
PE.queueCopies = queueCopies
PE.startGrab = startGrab
PE.stick = stick
end
