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

-- (functions kept in one table: the file has more of them than Luau allows locals at the top)
local FN = {}
S.FN = FN

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
    if not (o and S.sel and o.id == S.sel.id) then S.snapPick = nil end
    if S.sel and S.target and S.group and S.group[S.sel.id] and not (o and o.id == S.sel.id) then
        -- a group member stops being the held one: its place is kept for the others (and sent if it is not yet)
        local t = S.target
        S.gt[S.sel.id] = { pos = t.pos, heading = t.heading, scale = t.scale }
        local l = S.lastSent
        if l and l.id == S.sel.id and not S.dirty then S.gs[S.sel.id] = { pos = l.pos, heading = l.heading, scale = l.scale } end
    end
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
        local h = S.tiltHeld and S.tiltHeld[o.id]
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
        -- copies made in one go (rows, circles, group copies): matched by item and place
        if #S.expectMany > 0 then
            local keep = {}
            for _, o in ipairs(fresh) do
                local hit = nil
                for i, x in ipairs(S.expectMany) do
                    if x.item == o.item and len(x.pos - o.position) < 0.05 then hit = i break end
                end
                if hit then
                    local x = table.remove(S.expectMany, hit)
                    if x.tilt then S.tilt[o.id] = { x = x.tilt.x, z = x.tilt.z }; S.tiltSaveDue = true end
                    if x.rec then
                        if x.rec.cancelled then table.insert(S.q, { op = "remove", id = o.id, rec = { ids = {}, total = 1, done = 0, failed = 0, quiet = true } })
                        else
                            table.insert(x.rec.ids, o.id)
                            if x.rec.byIdx and x.idx then x.rec.byIdx[x.idx] = o.id end
                            if x.rec.onAll and #x.rec.ids >= x.rec.total - x.rec.failed and x.rec.done + x.rec.failed >= x.rec.total then
                                local f = x.rec.onAll
                                x.rec.onAll = nil
                                pcall(f, x.rec)
                            end
                        end
                    end
                else
                    table.insert(keep, o)
                end
            end
            fresh = keep
            for i = #S.expectMany, 1, -1 do if S.clock - S.expectMany[i].at > 15000 then table.remove(S.expectMany, i) end end
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
            S.droppedAt = S.clock
            if not S.open then reskate.ui.toast("Dropped " .. titleOf(o.item) .. ". F6: move, turn and size it") end
        elseif #fresh > 1 then
            reskate.log(string.format("Quick Drop helper: %d objects loaded with the park.", #fresh))
        end
        if S.sel and not now[S.sel.id] then select(nil) end
        for id in pairs(S.group) do if not now[id] then S.group[id] = nil; S.gt[id] = nil; S.gs[id] = nil end end
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

local drawShape -- (further on, with the drawing)
-- the look of what is drawn over the view
local UI = { bg = "#0d1117e0", bg2 = "#161b22f2", tile = "#ffffff12", tileHot = "#ffffff26", line = "#ffffff22",
    text = "#f0f3f6", dim = "#f0f3f699", accent = "#ffd34d", accentDim = "#ffd34d33", purple = "#c49bff", orange = "#ffa640", green = "#7dffb0" }
UI.BTN = { a = { "A", "#3fb950" }, b = { "B", "#f85149" }, x = { "X", "#4c8dff" }, y = { "Y", "#e3b341" } }
function UI.textW(d, str, size, font)
    if d.measure then
        local ok, v = pcall(d.measure, d, str, { size = size, font = font })
        if ok and type(v) == "vector" then return v.x end
        if ok and type(v) == "table" and v.x then return v.x end
    end
    return #str * size * 0.52
end
-- a controller button: A B X Y round in their colours, the rest a small light tag; its width
function UI.badgeW(d, k) return UI.BTN[k] and 24 or (UI.textW(d, k, 13, "bold") + 14) end
function UI.badge(d, x, y, k)
    local b = UI.BTN[k]
    if b then
        d:circle(V(x + 12, y, 0), 12, { colour = b[2], fill = true })
        d:text(V(x + 12, y - 9, 0), b[1], { size = 16, colour = "#0d1117", font = "bold", align = "centre" })
        return 24
    end
    local w = UI.badgeW(d, k)
    d:rect(V(x, y - 11, 0), V(x + w, y + 11, 0), { colour = "#e6e9ef", fill = true, rounding = 6 })
    d:text(V(x + w / 2, y - 8, 0), k, { size = 13, colour = "#0d1117", font = "bold", align = "centre" })
    return w
end
-- a row of button prompts ({ button, what }) in a dark pill, centred on x
function UI.promptRow(d, cx, y, items)
    local ws, total = {}, 0
    for i, it in ipairs(items) do
        ws[i] = { UI.badgeW(d, it[1]), UI.textW(d, it[2], 16) }
        total += ws[i][1] + 8 + ws[i][2] + (i < #items and 26 or 0)
    end
    local x = cx - total / 2
    d:rect(V(x - 18, y - 22, 0), V(x + total + 18, y + 22, 0), { colour = UI.bg, fill = true, rounding = 22 })
    for i, it in ipairs(items) do
        UI.badge(d, x, y, it[1])
        x += ws[i][1] + 8
        d:text(V(x, y - 10, 0), it[2], { size = 16, colour = UI.text })
        x += ws[i][2] + 26
    end
end
-- a small rounded label with a coloured dot; its width
function UI.chipW(d, str) return UI.textW(d, str, 15) + 30 end
function UI.chip(d, x, y, str, col)
    local w = UI.chipW(d, str)
    d:rect(V(x, y, 0), V(x + w, y + 28, 0), { colour = UI.bg, fill = true, rounding = 14 })
    d:circle(V(x + 13, y + 14, 0), 4, { colour = col or UI.accent, fill = true })
    d:text(V(x + 22, y + 5, 0), str, { size = 15, colour = UI.text })
    return w
end
-- a window: dark rounded panel with a title bar
function UI.panelBox(d, a, b, title)
    d:rect(a + V(0, 4, 0), b + V(0, 4, 0), { colour = "#00000055", fill = true, rounding = 14 })
    d:rect(a, b, { colour = UI.bg2, fill = true, rounding = 14 })
    d:rect(a, V(b.x, a.y + 52, 0), { colour = "#ffffff0a", fill = true, rounding = 14 })
    d:text(a + V(20, 13, 0), title, { size = 24, colour = UI.text, font = "heading" })
    d:line(V(a.x + 16, a.y + 52, 0), V(b.x - 16, a.y + 52, 0), { colour = UI.line, thickness = 1 })
end
-- button prompts along the bottom of a window
function UI.footer(d, a, b, items)
    local x, y = a.x + 20, b.y - 26
    for _, it in ipairs(items) do
        local w = UI.badge(d, x, y, it[1])
        x += w + 7
        d:text(V(x, y - 9, 0), it[2], { size = 15, colour = UI.dim })
        x += UI.textW(d, it[2], 15) + 22
    end
end
-- ---------------------------------------------------------------- several objects at once (a group)
-- RB (or Ctrl+click) puts objects in a group. Picking up one of them takes the rest along: each keeps its place
-- and turn next to the one held (the leader). While held, the others show as outlines; they are moved once it is
-- put down (the game takes 4 edits a second, so they go one after another).
S.group = {}         -- id -> true
S.gt = {}            -- id -> { pos, heading, scale }: where a follower is going
S.gs = {}            -- id -> what was last sent for it
S.q = {}             -- copies to place and objects to remove, waiting for a free edit
S.expectMany = {}    -- copies placed, waiting to show up in the game's list
S.gbase = nil        -- { leader = id, m = { id -> { off, dh, sr } } }: the followers, seen from the leader
local function groupCount() local n = 0; for _ in pairs(S.group) do n += 1 end; return n end
-- turning about the up axis, the way headings go
local function rotY(v, a)
    local c, s = math.cos(a), math.sin(a)
    return V(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
end
local function poseOf(id)
    local g = S.gt[id]
    if g then return g end
    local o = S.known and S.known[id]
    if o then return { pos = o.position, heading = o.heading or 0, scale = o.scale or 1 } end
    return nil
end
-- is this object being taken along with the held one?
local function follower(id)
    local b = S.gbase
    return b ~= nil and S.sel ~= nil and b.leader == S.sel.id and b.m[id] ~= nil
end
local function groupBase()
    S.gbase = nil
    if not (S.sel and S.target and S.group[S.sel.id]) then return end
    local L = S.target
    local m, n = {}, 0
    for id in pairs(S.group) do
        if id ~= S.sel.id then
            local p = poseOf(id)
            if p then
                m[id] = { off = rotY(p.pos - L.pos, -L.heading) / L.scale, dh = wrap(p.heading - L.heading), sr = p.scale / L.scale }
                n += 1
            end
        end
    end
    if n > 0 then S.gbase = { leader = S.sel.id, m = m } end
end

-- ---------------------------------------------------------------- undo and redo
-- Entries: a pose (an object, with its group's poses), "placed" (copies / sets made in one go: undo takes them
-- away), "removed" (objects removed: undo puts them back). Every undo makes the matching redo entry, and back.
S.redo = {}
local function poseEntry(id)
    local p = (S.sel and S.sel.id == id and S.target) or poseOf(id)
    if not p then return nil end
    local tl = S.tilt[id]
    local u = { id = id, pos = p.pos, heading = p.heading, scale = p.scale, tilt = tl and { x = tl.x, z = tl.z } or nil }
    if S.group[id] then
        u.group = {}
        for gid in pairs(S.group) do
            if gid ~= id then
                local q = poseOf(gid)
                if q then u.group[gid] = { pos = q.pos, heading = q.heading, scale = q.scale } end
            end
        end
    end
    return u
end
local function pushUndo(u, keepRedo)
    table.insert(S.undo, u)
    if #S.undo > 100 then table.remove(S.undo, 1) end
    if not keepRedo then S.redo = {} end
end
S.pushUndo = pushUndo
local function markUndo()
    if S.target and S.sel then
        local u = poseEntry(S.sel.id)
        if u then pushUndo(u) end
    end
end
-- what objects are, to put them back later
local function itemsOf(ids)
    local out = {}
    for _, id in ipairs(ids) do
        local o = S.known and S.known[id]
        local p = (S.sel and S.sel.id == id and S.target) or poseOf(id)
        if o and p then
            local tl = S.tilt[id]
            out[#out + 1] = { item = o.item, pos = p.pos, heading = p.heading, scale = p.scale, tilt = tl and { x = tl.x, z = tl.z } or nil }
        end
    end
    return out
end
S.itemsOf = itemsOf
-- place objects again (one after another) / remove them; both give the record of what was done
local function queuePlace(items, label)
    local rec = { ids = {}, byIdx = {}, total = 0, done = 0, failed = 0, label = label, items = items, quiet = true }
    for i, c in ipairs(items) do
        table.insert(S.q, { op = "place", item = c.item, pos = c.pos, heading = c.heading, scale = c.scale, tilt = c.tilt, rec = rec, idx = i })
        rec.total += 1
    end
    return rec
end
local function queueRemove(ids, label)
    local rec = { ids = {}, total = 0, done = 0, failed = 0, label = label, quiet = true }
    for _, id in ipairs(ids) do
        S.group[id] = nil
        if S.gbase and (S.gbase.m[id] or S.gbase.leader == id) then S.gbase = nil end
        table.insert(S.q, { op = "remove", id = id, rec = rec }); rec.total += 1
    end
    return rec
end
-- remove objects so that undo can bring them back
function S.removeUndoable(ids, label)
    local items = itemsOf(ids)
    local rec = queueRemove(ids, label or "Removed")
    rec.quiet = false
    pushUndo({ kind = "removed", items = items })
    return rec
end
local function restorePose(u)
    if not S.sel or S.sel.id ~= u.id then
        for _, o in ipairs(reskate.objects.list()) do if o.id == u.id then select(o) end end
    end
    if S.sel and S.sel.id == u.id then
        S.target = { pos = u.pos, heading = u.heading, scale = u.scale }
        S.tilt[u.id] = u.tilt
        S.tiltSaveDue = true
        S.dirty = true
        if u.group then
            S.gbase = nil
            for id, p in pairs(u.group) do if S.known and S.known[id] then S.gt[id] = { pos = p.pos, heading = p.heading, scale = p.scale } end end
            groupBase()
        end
        return true
    end
    return false
end
-- one step of undo (from = S.undo, to = S.redo) or redo (the other way)
local function step(from, to, word)
    local u = table.remove(from)
    if not u then say("Nothing to " .. word .. ".") return end
    if u.kind == "placed" then
        -- made in one go: take them away (what they were is kept, to make them again)
        local r = u.rec
        r.cancelled = true
        for i = #S.q, 1, -1 do if S.q[i].rec == r then table.remove(S.q, i) end end
        local items = #r.ids > 0 and itemsOf(r.ids) or (r.items or {})
        local n = #r.ids
        queueRemove(r.ids, word)
        r.ids = {}
        table.insert(to, { kind = "unplaced", items = items })
        say(string.format("%s: taking away %d object%s.", word == "undo" and "Undo" or "Redo", n, n == 1 and "" or "s"))
    elseif u.kind == "unplaced" or u.kind == "removed" then
        -- put back: they come again as a group
        local rec = queuePlace(u.items, word)
        rec.onAll = function(r)
            S.group = {}
            for _, id in ipairs(r.ids) do S.group[id] = true end
            S.gbase = nil
        end
        table.insert(to, u.kind == "removed" and { kind = "unremoved", rec = rec } or { kind = "placed", rec = rec })
        say(string.format("%s: putting back %d object%s.", word == "undo" and "Undo" or "Redo", #u.items, #u.items == 1 and "" or "s"))
    elseif u.kind == "unremoved" then
        local r = u.rec
        for i = #S.q, 1, -1 do if S.q[i].rec == r then table.remove(S.q, i) end end
        local items = itemsOf(r.ids)
        queueRemove(r.ids, word)
        r.ids = {}
        table.insert(to, { kind = "removed", items = items })
        say(string.format("%s: removing %d object%s again.", word == "undo" and "Undo" or "Redo", #items, #items == 1 and "" or "s"))
    else
        local cur = poseEntry(u.id)
        if restorePose(u) then
            if cur then table.insert(to, cur) end
        else
            say("That object is gone: nothing to " .. word .. ".")
        end
    end
    if #to > 100 then table.remove(to, 1) end
end
local function undo() step(S.undo, S.redo, "undo") end
local function redo() step(S.redo, S.undo, "redo") end
S.redoFn = redo

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
local LEVEL_NEAR = 1.0   -- metres apart at most for lining up with any but the nearest object
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

-- Moves pos so the picked object's faces meet or line up with the faces of the objects near it (tilted or not).
-- allow(direction, metres) answers how such a move may be made for the handle in use: the move as a vector and
-- the direction it goes along, or nil when that handle cannot go that way.
-- Returns the place, and what it snapped to (a list of { o, nb, kind }) or nil.
-- snapping to: "auto" (the nearest), one chosen object (L3 tap / Tab cycles), or "off"
S.snapPick = nil
function FN.snapAllowed(id)
    if follower(id) then return false end
    local sp = S.snapPick
    if sp == nil then return true end
    if sp == "off" then return false end
    return id == sp
end
local function objSnap(pos, heading, scale, allow, tl)
    if not (S.osnap and S.sel and S.known) then return pos, nil end
    if S.snapPick == "off" then return pos, nil end
    local thr = clamp(S.cam.dist * 0.03, 0.12, 0.5)
    local me = worldSolid(S.sel.item, pos, heading, scale, tl)
    local mc = cornersOf(me)
    local reach = SNAP_REACH + len(me.hi - me.lo)
    local near = {}
    for id, o in pairs(S.known) do
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
function FN.supportY(item, pos, heading, scale, selfId)
    local b = S.itemBox[item]
    local lo, hi = V(-0.3, 0, -0.3), V(0.3, 1, 0.3)
    if b then lo, hi = b[1] * scale, b[2] * scale end
    local bottom = pos.y + lo.y
    local ax, az = V(math.cos(heading), 0, -math.sin(heading)), V(math.sin(heading), 0, math.cos(heading))
    local mx, mz = (lo.x + hi.x) / 2, (lo.z + hi.z) / 2
    local wx, wz = (hi.x - lo.x) * 0.4, (hi.z - lo.z) * 0.4
    local me = selfId and S.known and S.known[selfId]
    local mine = { me and me.position, S.lastSent and S.lastSent.id == selfId and S.lastSent.pos or nil }
    -- (and the ones it takes along)
    if S.gbase and S.gbase.leader == selfId then
        for fid in pairs(S.gbase.m) do local fo = S.known and S.known[fid]; if fo then mine[#mine + 1] = fo.position end end
    end
    -- the first thing (not mine) straight down from a point
    local function down(x, z)
        local wpt = pos + ax * x + az * z
        local from, to = V(wpt.x, bottom + 1.5, wpt.z), V(wpt.x, bottom - 40, wpt.z)
        for _ = 1, 3 do
            local ok, hit = pcall(reskate.world.pick, from, to)
            if not (ok and type(hit) == "table" and hit.position) then return nil end
            if hit.position.y <= to.y + 1e-3 then return nil end   -- (the end of the ray: nothing there)
            local own = false
            if hit.object and hit.object.position then
                for _, mp in pairs(mine) do if mp and len(hit.object.position - mp) < 0.05 then own = true end end
            end
            if not own then return hit.position.y end
            from = hit.position - V(0, 0.02, 0)
        end
        return nil
    end
    -- (its middle decides: pushed against something it meets it side on; pushed on over it, it climbs on top)
    local best = down(mx, mz)
    -- but it only steps down once it is off what it stands on: while a corner (a little in) still rests on it,
    -- it stays up there (else a box on top of another drops off as soon as its middle passes the edge)
    if best and best < bottom - 0.03 then
        for _, c in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
            local y = down(mx + wx * c[1], mz + wz * c[2])
            if y and math.abs(y - bottom) <= 0.03 then best = bottom; break end
        end
    end
    if not best then return nil end
    return best - lo.y
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
    for id, o in pairs(S.known) do
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
function FN.standsLike(h, tl)
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
        if id ~= S.sel.id and FN.snapAllowed(id) and S.itemBox[o.item] then
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
            local opts = FN.standsLike(n.o.heading or 0, ntl)
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
local function snapTurned(pos, base, scale, allow, baseTilt)
    local ok, p, h, g, tl = pcall(alignSnap, pos, base, scale, allow, baseTilt)
    if ok then
        S.snapLock = (g and g[1] and g[1].o) and g[1].o.id or nil
        return p, h, g, tl
    end
    if not S.snapWarned then S.snapWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(p), "warn") end
    return pos, base, nil, baseTilt
end
function FN.turnTo(hd)
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
function FN.heldCount() local n = 0; for _ in pairs(S.tiltHeld) do n += 1 end; return n end
local function letGo(id)
    if S.tiltHeld[id] then
        pcall(reskate.objects.physics, id, nil)
        S.tiltHeld[id] = nil
    end
end
-- holds an object (if not yet) and gives it its tilt; o is the object as placed
function FN.holdTilted(o)
    local tl = S.tilt[o.id]
    local h = S.tiltHeld[o.id]
    if not h then
        if S.clock < (S.tiltAt[o.id] or 0) then return end
        -- where it is placed now, from the game (it is not held yet, so that is its placed spot)
        for _, q in ipairs(reskate.objects.list()) do if q.id == o.id then o = q break end end
        if FN.heldCount() >= MAX_HELD then S.tiltWhy = "at most 32 tilted objects at once" return end
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
        S.tiltHeld[o.id] = h
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
function FN.mapName()
    local ok, l = pcall(function() return reskate.level and reskate.level.current() end)
    return (ok and type(l) == "table" and l.name) or S.level or "?"
end
function FN.loadTilts()
    local ok, t = pcall(reskate.storage.get, "tilts")
    S.tiltStore = (ok and type(t) == "table") and t or {}
end
function FN.saveTilts()
    S.tiltStore = S.tiltStore or {}
    local map = FN.mapName()
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
function FN.matchTilts()
    if not (S.known and S.tiltStore) then return end
    for _, e in ipairs(S.tiltStore[FN.mapName()] or {}) do
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
function FN.tiltTick()
    if not S.tiltStore then FN.loadTilts() end
    if S.clock - (S.tiltMatchAt or -1e9) > 1000 then
        S.tiltMatchAt = S.clock
        FN.matchTilts()
        -- objects gone from the park: forget them
        for id in pairs(S.tiltHeld) do if not (S.known and S.known[id]) then S.tiltHeld[id] = nil end end
        for id in pairs(S.tilt) do if S.known and not S.known[id] then S.tilt[id] = nil end end
    end
    -- levelled again: let go
    for id in pairs(S.tiltHeld) do if not tilted(id) then letGo(id) end end
    for id, tl in pairs(S.tilt) do
        local o = S.known and S.known[id]
        local mine = S.sel and S.sel.id == id
        local busy = mine and (S.dirty or ((S.drag and S.drag.moved) and S.drag.kind ~= "tilt") or S.padMoving or not lastApplied())
        if not tilted(id) or not o or busy then
            if S.tiltHeld[id] then letGo(id) end
            if busy then S.tiltSaveDue = true end
        else
            local h = S.tiltHeld[id]
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
                            S.tiltHeld[id] = nil; h = nil
                        end
                    else
                        h.gone = 0
                    end
                end
            end
            if h then FN.holdTilted({ id = id, item = o.item, position = h.pos, heading = h.heading, scale = o.scale })
            else FN.holdTilted(o) end
        end
    end
    if S.tiltSaveDue and not S.dirty and not S.drag and lastApplied() and S.clock - S.lastSend > 600 then
        S.tiltSaveDue = false
        FN.saveTilts()
    end
end

-- ---------------------------------------------------------------- the park as a park mod (tilts and all)
-- Online, the game won't let a plugin hold objects, so tilts made here can't show there. A park mod can: it lists
-- every object with its whole turn, and in multiplayer the host loads it (Build > Park mods) for everyone. The
-- plugin may only write in its own data folder, so the park mod is made there and the folder opened, to be copied
-- into ReSkate's Mods folder. Park mods are only for the game's own maps.
FN.MAP_KEYS = { { "bam_levelroot", "bam" }, { "isle_of_grom", "grom" }, { "dingolevel_mpr", "mpr" },
    { "sdm_int_001", "stadium_1" }, { "sdm_int_002", "stadium_2" }, { "ftue", "ftue" } }
local function parkKey(name)
    local l = string.lower(tostring(name or ""))
    for _, k in ipairs(FN.MAP_KEYS) do if string.find(l, k[1], 1, true) then return k[2] end end
    return nil
end
local function r6(x) return math.floor(x * 1e6 + 0.5) / 1e6 end
local function saveParkMod()
    local key = parkKey(FN.mapName())
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
function FN.saveParkModSay()
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
FN.TIGHT_RAYS = 24
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
function FN.fitSide(o, d, delta)
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

function FN.tightenJob(job, me, objs)
    local p = me.position
    local myBox = worldShape(me.item, p, me.heading or 0, me.scale or 1)
    local function ray(q, top, bottom, nbPos)
        if S.tRays >= FN.TIGHT_RAYS or os.clock() - S.tT0 > 0.002 then coroutine.yield() end
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
                FN.fitSide(me, n, mine - s0)
                FN.fitSide(nbo, n * -1, nlo - theirs)
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

function FN.stepTighten()
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
        j.co = coroutine.create(FN.tightenJob)
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

function FN.clickPick(px, toGroup)
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
        if toGroup and S.toggleGroup then S.toggleGroup(best) else say("Picked " .. titleOf(best.item)) end
    elseif hit.object then
        say("That is part of the map: only placed objects can be changed.")
    end
end

-- set later, with the controller code
local padCaptureOn, padCaptureOff = function() end, function() end

function FN.openEditor()
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
    -- coming back: nothing picked, unless something was dropped with Quick Drop since leaving
    if S.sel and S.closedAt and not (S.droppedAt and S.droppedAt > S.closedAt) then send(); select(nil) end
    S.open = true
    S.drag = nil
    S.mouse = { pos = nil, left = false }
    S.padWait, S.padBurst, S.padMoving, S.padRep, S.padHeld = true, false, false, {}, {}
    reskate.ui.open(TITLE)
    padCaptureOn()
end

local function closeEditor()
    S.aHold, S.yHold = nil, nil
    S.carry = nil
    S.controlsOpen = false
    if S.grab then S.grab = nil end
    S.closedAt = S.clock
    S.picker = nil
    S.toolsWin = nil
    if not S.open then return end
    if S.typing then S.typing = false; pcall(reskate.ui.close_dialog, "ddh_type") end
    S.drag = nil
    S.open = false
    padCaptureOff()
    reskate.camera.release()
    reskate.ui.close()
end

reskate.input.bind("ddh_quickdrop_plus", "F6")
-- (the controller opens it with LB + D-pad right: watched in the tick, see padOpenTick)
reskate.on("action", function(name)
    if name == "ddh_quickdrop_plus" or name == "ddh_quickdrop_plus_pad" then FN.openEditor() end
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
    S.tiltHeld, S.tilt, S.tiltAt, S.tiltSrc, S.level = {}, {}, {}, {}, nil
    S.group, S.gt, S.gs, S.q, S.expectMany, S.gbase, S.toolsWin = {}, {}, {}, {}, {}, nil, nil
end)

-- typing exact numbers: a text box with "X Y Z turn size"; change any of them
FN.TYPE_ID = "ddh_type"
function FN.openTyping()
    if not (S.sel and S.target) then return end
    local t = S.target
    local text = string.format("%.3f  %.3f  %.3f  %.1f  %.2f", t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale)
    local ok, why = pcall(reskate.ui.dialog, FN.TYPE_ID, {
        title = "Type numbers",
        message = "X  Y  Z  Turn  Size, with spaces between.\nChange any of them, then Enter.\nTip: start a number with + to add to it: +2 moves 2 m, +-0.5 moves back 0.5 m.",
        field = { text = text, max = 120 },
        buttons = { { id = "apply", label = "Apply" }, { id = "close", label = "Cancel" } },
    })
    if not ok or why == false then say("Could not open the text box" .. (ok and "" or (": " .. tostring(why))), true) else S.typing = true end
end
function FN.parseTyped(str)
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
    if e.action ~= "dialog" or e.args[1] ~= FN.TYPE_ID then return end
    local what = e.args[2]
    if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
    S.typing = false
    if what ~= "cancel" then pcall(reskate.ui.close_dialog, FN.TYPE_ID) end
    if what ~= "apply" then return end
    if not (S.sel and S.target) then return end
    local v, err = FN.parseTyped(e.args[3] or "")
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
function FN.oldPanel(ui)
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
        if tilted(S.sel.id) and S.tiltWhy and not S.tiltHeld[S.sel.id] then ui:note("Tilt waits: " .. S.tiltWhy) end
        if ui:button("parkmod", "Save as park mod (for online)") then FN.saveParkModSay() end
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
        ui:info("Controller", "LB + D-pad right opens")
        ui:info("Left stick", "fly (holding: move it)")
        ui:info("A", "pick up what the cross is on / put down")
        ui:info("B", "cancel (back where it was) / close")
        ui:info("X", "copy (holding: drop a copy)")
        ui:info("Y twice", "remove (what the cross is on)")
        ui:info("RT / LT", "raise / lower")
        ui:info("LB / RB", "turn (holding)")
        ui:info("D-pad up / down", "size (holding) / zoom")
        ui:info("D-pad left / right", "next object (holding: zoom)")
        ui:info("Hold A", "select: sweep the cross over objects")
        ui:info("Y on a selected one", "out of the group (hold Y and sweep for more)")
        ui:info("RB / LB", "group: add or take out / clear")
        ui:info("Right stick / R3", "turn the view / look at it (holding: copy tools)")
        ui:info("Ctrl+click", "group: add or take out")
        ui:info("Tab / tap L3", "snap: auto / one object / off")
        ui:info("View / Menu", "undo / Fine-Normal-Big")
        ui:info("Hold L3", "Fine while held")
    end
    if ui:button("close", "Done (Esc)", true) then closeEditor() end
end

-- ---------------------------------------------------------------- the new panel (ReSkate 2.1.4 widgets)
-- step sizes for the steppers: metres, degrees, size
-- (speed: how fast the controller slides a held object, m/s; fly: how fast the free view flies, times)
function FN.snapLabelP()
    local sp = S.snapPick
    if sp == nil then return "auto (nearest)" end
    if sp == "off" then return "off" end
    local o = S.known and S.known[sp]
    return o and titleOf(o.item) or "auto (nearest)"
end
FN.GRID_NAMES_P = { "Off", "0.25 m", "0.5 m", "1 m", "2 m" }
local STEPS = {
    { m = 0.01, deg = 1, size = 0.01, speed = 0.4, fly = 0.3, name = "Fine", mf = "%.2f m", df = "%.0f°", sf = "%.2f×" },
    { m = 0.1, deg = 15, size = 0.1, speed = 2.5, fly = 1.0, name = "Normal", mf = "%.2f m", df = "%.0f°", sf = "%.2f×" },
    { m = 1, deg = 45, size = 0.5, speed = 6.0, fly = 2.5, name = "Big", mf = "%.1f m", df = "%.0f°", sf = "%.1f×" },
}
S.stepSize = 2
S.sec = { move = true, handles = false, objects = true, locked = true, help = false }
S.search, S.listFilter = "", 1
S.listAt, S.listKey = -1e9, nil
S.listObjs, S.listItems, S.listTotal = {}, {}, 0

function FN.section(ui, id, title, sub)
    local o = ui:section(id, title, sub, S.sec[id])
    if o ~= nil then S.sec[id] = o end
    return S.sec[id]
end

-- a number box: click it and type. What is typed is used once you stop typing for a moment.
-- "12.5" sets it, "+2" adds 2, "+-0.5" takes 0.5 off; a comma works as the decimal point too.
function FN.parseNum(text, cur)
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
        local v = FN.parseNum(e.text, val)
        if v then apply(v) else say(label .. ": \"" .. e.text .. "\" is not a number", true) end
    end
end

-- the list of park objects: rebuilt twice a second, or at once when the search or filter changes
function FN.rebuildList()
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

FN.PANEL_TABS = { "Object", "Snapping", "Park", "Help" }
function FN.newPanel(ui)
    local t = S.sel and S.target
    local ng = groupCount()
    -- what is picked
    if t then
        local sub = string.format("%.0f°   ·   size %.2f", math.deg(t.heading), t.scale)
        if S.group[S.sel.id] and ng > 1 then sub = sub .. string.format("   ·   group of %d", ng) end
        ui:card(titleOf(S.sel.item), sub)
    elseif ng > 0 then
        ui:card(string.format("Group of %d", ng), "Pick one of them up to move them all")
    else
        ui:card("Nothing picked", "Click an object (or aim the cross and press A)")
    end
    -- the park is locked: say so first
    local miss = S.missing or {}
    if S.blocked or #miss > 0 then ui:warn(string.format("Park locked: %d object(s) from a missing mod. See Park.", #miss)) end
    if S.msg ~= "" and S.clock < S.msgUntil then ui:note(S.msg) end
    local b = ui:buttons("top", { "Add object", "Undo", "Done" }, 0)
    if b == 1 and S.openPicker then S.openPicker() end
    if b == 2 then undo() end
    if b == 3 then closeEditor() return end

    S.ptab = S.ptab or 1
    local tb = ui:buttons("ptabs", FN.PANEL_TABS, S.ptab)
    if tb and FN.PANEL_TABS[tb] then S.ptab = tb end
    local st = STEPS[S.stepSize]

    if S.ptab == 1 then
        -- ---------------------------------------------------------------- the picked object
        if not t then
            ui:note("Nothing picked yet.")
        else
            local modes = { "Move", "Turn", "Size" }
            local m = ui:buttons("mode", modes, S.mode)
            if m and m ~= S.mode then S.mode = m end
            ui:heading("Position")
            numBox(ui, "px", "X", t.pos.x, "%.3f", function(v) markUndo(); t.pos = V(v, t.pos.y, t.pos.z); S.dirty = true end)
            numBox(ui, "py", "Y (height)", t.pos.y, "%.3f", function(v) markUndo(); t.pos = V(t.pos.x, v, t.pos.z); S.dirty = true end)
            numBox(ui, "pz", "Z", t.pos.z, "%.3f", function(v) markUndo(); t.pos = V(t.pos.x, t.pos.y, v); S.dirty = true end)
            ui:heading("Turn and size")
            numBox(ui, "ry", "Turn °", math.deg(t.heading), "%.1f", function(v) markUndo(); t.heading = wrap(math.rad(v)); S.dirty = true end)
            numBox(ui, "sz", "Size", t.scale, "%.2f", function(v) markUndo(); t.scale = clamp(v, 0.1, 10); S.dirty = true end)
            local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
            numBox(ui, "tx", "Tilt forward °", math.deg(tl.x), "%.1f", function(v) markUndo(); S.tilt[S.sel.id] = { x = wrap(math.rad(v)), z = tl.z }; S.tiltSaveDue = true end)
            numBox(ui, "tz", "Tilt sideways °", math.deg(tl.z), "%.1f", function(v) markUndo(); S.tilt[S.sel.id] = { x = tl.x, z = wrap(math.rad(v)) }; S.tiltSaveDue = true end)
            if tilted(S.sel.id) and S.tiltWhy and not S.tiltHeld[S.sel.id] then ui:note("Tilt waits: " .. S.tiltWhy) end
            local q = ui:buttons("quick", { "Straighten", "Size 1", "Look at it" }, 0)
            if q == 1 then markUndo(); t.heading = round(t.heading, math.pi / 2); if S.tilt[S.sel.id] then S.tilt[S.sel.id] = nil; S.tiltSaveDue = true end; S.dirty = true; S.edit = {} end
            if q == 2 then markUndo(); t.scale = 1; S.dirty = true; S.edit = {} end
            if q == 3 then S.cam.goal = t.pos end
        end
        ui:heading("Step size")
        local ss = ui:buttons("stepsize", { "Fine", "Normal", "Big" }, S.stepSize)
        if ss and STEPS[ss] then S.stepSize = ss; st = STEPS[ss] end
        ui:note(string.format("%s: %s, %s, size %s", st.name, string.format(st.mf, st.m), string.format(st.df, st.deg), string.format(st.sf, st.size)))
    elseif S.ptab == 2 then
        -- ---------------------------------------------------------------- snapping
        local ob = ui:toggle("osnap", "Snap to objects  (T)", S.osnap)
        if ob ~= nil then S.osnap = ob end
        if S.osnap then
            ui:info("Snapping to", FN.snapLabelP())
            local sb = ui:buttons("snappick", { "Auto", "Next object", "Off" }, S.snapPick == nil and 1 or (S.snapPick == "off" and 3 or 2))
            if sb == 1 then S.snapPick = nil; S.snapLock = nil end
            if sb == 2 and S.cycleSnap then if S.snapPick == "off" then S.snapPick = nil end; S.cycleSnap(); if S.snapPick == nil then S.cycleSnap() end end
            if sb == 3 then S.snapPick = "off"; S.guides = nil end
            ui:note("Tab or tap L3 to switch while moving.")
        end
        ui:heading("Grid")
        local gi = ui:buttons("gridsz", FN.GRID_NAMES_P, S.gridI or 1)
        if gi and gi ~= S.gridI then S.gridI = gi end
        local sn = ui:toggle("snap", "Drag in steps  (G)", S.snap)
        if sn ~= nil then S.snap = sn end
    elseif S.ptab == 3 then
        -- ---------------------------------------------------------------- the park: group, copies, every object
        ui:heading(ng > 0 and string.format("Group  (%d)", ng) or "Group")
        local gb = ui:buttons("grp", { "Add / remove picked", "Clear" }, 0)
        if gb == 1 and S.sel and S.known and S.known[S.sel.id] and S.toggleGroup then S.toggleGroup(S.known[S.sel.id]) end
        if gb == 2 and S.clearGroup then S.clearGroup() end
        if ui:button("tools", "Copy tools  (row, circle, grid)") and S.openTools then S.openTools() end
        FN.rebuildList()
        local sub = tostring(S.listTotal)
        if S.search ~= "" or S.listFilter ~= 1 then sub = string.format("%d of %d", S.listMatched or 0, S.listTotal) end
        ui:heading("Objects  (" .. sub .. ")")
        local q = ui:text("search", "Search", S.search, "")
        if type(q) == "string" and q ~= S.search then S.search = q; S.listKey = nil end
        local f = ui:buttons("filter", { "All", "Near", "DDH" }, S.listFilter)
        if f and f ~= S.listFilter then S.listFilter = f; S.listKey = nil end
        FN.rebuildList()
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
        if ui:button("parkmod", "Save as park mod (for online)") then FN.saveParkModSay() end
        if S.blocked or #miss > 0 then
            ui:heading("Park locked")
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
    else
        -- ---------------------------------------------------------------- help
        ui:heading("Controller")
        local iy = ui:toggle("invy2", "Invert look up / down", S.lookInvY or false)
        if iy ~= nil and iy ~= (S.lookInvY or false) then S.lookInvY = iy; saveLook() end
        local ix = ui:toggle("invx2", "Invert look left / right", S.lookInvX or false)
        if ix ~= nil and ix ~= (S.lookInvX or false) then S.lookInvX = ix; saveLook() end
        ui:info("LB + D-pad right", "open")
        ui:info("A  /  hold A", "pick up, put down  /  select")
        ui:info("B", "cancel  /  close")
        ui:info("X  /  Y twice", "copy  /  remove")
        ui:info("RB  /  LB", "group add  /  clear")
        ui:info("Sticks, RT / LT", "move, look, up / down")
        ui:info("LB / RB (holding)", "turn")
        ui:info("D-pad (holding)", "size, zoom")
        ui:info("R3 / L3 (holding)", "copy tools / snap target")
        ui:info("Menu  /  View", "step size  /  undo")
        ui:heading("Mouse and keys")
        ui:info("Click  /  Ctrl+click", "pick  /  group")
        ui:info("Drag a handle", "move, turn, size")
        ui:info("Drag  /  right-drag", "turn  /  slide the view")
        ui:info("W  E  R", "move / turn / size handles")
        ui:info("T  /  Tab  /  G", "snapping / snap target / steps")
        ui:info("Hold Ctrl", "drag without snapping")
        ui:info("F  /  Ctrl+Z  /  Esc", "look at it / undo / done")
    end
end

-- which panel: the new one when this ReSkate has the 2.1.4 widgets, otherwise the old one
function FN.hasNewWidgets(ui)
    local ok, yes = pcall(function()
        return type(ui.stepper) == "function" and type(ui.section) == "function" and type(ui.list) == "function"
            and type(ui.buttons) == "function" and type(ui.text) == "function"
    end)
    return ok and yes
end

function FN.dockedPanel(ui)
    if S.newUI == nil then
        S.newUI = FN.hasNewWidgets(ui)
        reskate.log("Quick Drop helper: " .. (S.newUI and "using the new panel (ReSkate 2.1.4 widgets)." or "this ReSkate has no 2.1.4 widgets; using the old panel."))
    end
    if S.newUI then
        local ok, err = pcall(FN.newPanel, ui)
        if ok then return end
        reskate.log("Quick Drop helper: the new panel failed, going back to the old one: " .. tostring(err), "warn")
        S.newUI = false
        return
    end
    FN.oldPanel(ui)
end
do
    -- a screen without ReSkate's panel (panel = false): the editor draws its own
    -- (ReSkate still calls the function with panel = false, but shows nothing of it: it is left empty)
    local ok, why = pcall(reskate.ui.screen, TITLE, function(ui) end, { panel = false })
    if ok then
        S.ownPanel = true
        reskate.log("Quick Drop helper: using its own drawn panel.")
    else
        reskate.log("Quick Drop helper: a screen without a panel is not possible here (" .. tostring(why) .. "); using ReSkate's panel.")
        reskate.ui.screen(TITLE, FN.dockedPanel, { dock = "right", width = 0.2 })
    end
end

local function press(k)
    local d = reskate.input.key(k)
    local was = S.held[k]
    S.held[k] = d
    return d and not was
end

-- which handle is under the mouse (from where the last frame drew them)
function FN.handleAt(px)
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

function FN.readPad()
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

function FN.padCapture(on)
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

padCaptureOn = function() FN.padCapture(true) end
padCaptureOff = function() FN.padCapture(false) end

-- the open editor with a controller
-- the object under the cross in the middle of the view (aiming with the controller)
function FN.aimedObject()
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
    S.snapPick = nil
    markUndo()
    if S.group[S.sel.id] then groupBase() else S.gbase = nil end
    S.cam.goal = t.pos
    local n = S.gbase and groupCount() or 1
    if n > 1 then
        say(string.format("Holding %d objects.  A: put down   B: cancel   X: copy them   D-pad left/right: zoom", n))
    else
        say("Holding " .. titleOf(S.sel.item) .. ".  A: put down   B: cancel   X: copy   D-pad left/right: zoom")
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
    say(string.format("Snap: %s  (%d of %d, L3: the next)", titleOf(S.known[id].item), i, n))
end
-- carrying a set: what it snaps to, nearest to the set first
function FN.nextCarrySnap()
    local c = S.carry
    if not c then return end
    local id, i, n = FN.l3Cycle("carry", function() return FN.nearestTo(c.pos, 8) end)
    if not id then say("Nothing near to snap to.") return end
    S.snapPick = id
    c.guides = nil
    say(string.format("Snap: %s  (%d of %d, L3: the next)", titleOf(S.known[id].item), i, n))
end
-- free: what the cross is on (A picks it up), nearest to where the cross points first
function FN.nextAimObject()
    local at = FN.crossPoint()
    local id, i, n = FN.l3Cycle("aim", function() return FN.nearestTo(at, 8) end)
    if not id then say("Nothing near.") return end
    S.aimLock, S.aimLockAt = id, S.clock
    S.aim = S.known[id]
    say(string.format("%s  (%d of %d, L3: the next, A: pick up)", titleOf(S.known[id].item), i, n))
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
    else say("Snap: one object, " .. titleOf(S.known[sp].item) .. "  (L3: the next one)") end
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
        say(string.format("Copied %d objects in place: you're holding the group. B takes the copies away.", #list))
        return
    end
    S.copyQ = { item = o.item, pos = o.position, heading = o.heading or 0, scale = o.scale or 1, tilt = S.tilt[o.id], until_ = S.clock + 3000, grab = true }
end
-- D-pad left / right while holding: a copy stays here and the held one (with its group) steps one width along
function FN.rowStep(sign)
    if not (S.sel and S.target) then return end
    local list = FN.heldList()
    local h = S.target.heading
    local dir = V(math.cos(h), 0, -math.sin(h)) * sign
    local step = extentAlong(list, dir) + (S.tools and S.tools.gap or 0)
    queueCopies(list, "Row")
    S.target.pos += dir * step
    S.padRaw = nil
    S.dirty = true
    S.cam.goal = (S.cam.goal or S.cam.target) + dir * step
    S.cam.target += dir * step
    say(string.format("Copy left behind; moved %.2f m %s.", step, sign > 0 and "right" or "left"))
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
        say(q.grab and "Copy made: you're holding it." or "Copy made. Move on and press X for another.")
    elseif not BUSY[why] then
        S.copyQ = nil
        say("No copy: " .. tostring(why), true)
    end
end
-- Y twice: remove it (a group member: the whole group)
function FN.deletePress(o)
    o = o or (S.sel and { id = S.sel.id, item = S.sel.item })
    if not o then say("Aim the cross at an object, then Y twice.") return end
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
            say(string.format("Removing %d objects... (View: undo)", rec.total))
        else
            S.delAsk = { id = id, at = S.clock, all = true }
            say(string.format("Press Y again to remove all %d objects in the group.", n))
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
            say("Removed " .. name .. ".  (View: undo)")
        else
            say("Not removed: " .. tostring(why), true)
        end
    else
        S.delAsk = { id = id, at = S.clock }
        say("Press Y again to remove " .. titleOf(o.item) .. ".")
    end
end

startGrabRef = startGrab

function FN.toggleGroup(o)
    if not o then say("Aim the cross at an object, then RB puts it in the group.") return end
    if S.group[o.id] then S.group[o.id] = nil else S.group[o.id] = true end
    S.gbase = nil
    local n = groupCount()
    if n == 0 then say("Group cleared.")
    else say(string.format("Group: %d object%s.  RB: add / take out   LB: clear   A on one: move them all", n, n == 1 and "" or "s")) end
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
        if not (S.known and S.known[e.id]) then ok = true else letGo(e.id); ok, why = reskate.objects.remove(e.id) end
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

-- ---------------------------------------------------------------- arranging a group: mirror, line up, space, level
-- Seen from the picked one (its turn gives "left / right" and "front / back"); one undo puts them all back.
function S.arrange(kind)
    if not S.sel then
        for id in pairs(S.group) do local o = S.known and S.known[id]; if o then select(o) break end end
    end
    if not (S.sel and S.target) then say("Pick objects first (hold A and sweep, or Ctrl+click).", true) return end
    S.group[S.sel.id] = true
    local ids = {}
    for id in pairs(S.group) do if S.known and S.known[id] then ids[#ids + 1] = id end end
    if #ids < 2 then say("Select two or more objects to arrange them.", true) return end
    markUndo()
    S.gbase = nil
    local h0 = S.target.heading
    local poses = {}
    local cx, cz, n = 0, 0, 0
    for _, id in ipairs(ids) do
        local p = (id == S.sel.id) and S.target or poseOf(id)
        poses[id] = { pos = p.pos, heading = p.heading, scale = p.scale }
        cx += p.pos.x; cz += p.pos.z; n += 1
    end
    local C = V(cx / n, 0, cz / n)
    local function loc(p) return rotY(V(p.x - C.x, 0, p.z - C.z), -h0) end
    local function wld(l, y) local w = rotY(l, h0); return V(C.x + w.x, y, C.z + w.z) end
    local L = loc(S.target.pos)
    if kind == "space" then
        table.sort(ids, function(a, b) return loc(poses[a].pos).x < loc(poses[b].pos).x end)
    end
    local x0, x1 = math.huge, -math.huge
    for _, id in ipairs(ids) do local l = loc(poses[id].pos); x0 = math.min(x0, l.x); x1 = math.max(x1, l.x) end
    for i, id in ipairs(ids) do
        local p = poses[id]
        local l = loc(p.pos)
        local a = wrap(p.heading - h0)
        local np, nh = p.pos, p.heading
        if kind == "mirrorX" then np = wld(V(-l.x, 0, l.z), p.pos.y); nh = wrap(h0 - a)
        elseif kind == "mirrorZ" then np = wld(V(l.x, 0, -l.z), p.pos.y); nh = wrap(h0 + math.pi - a)
        elseif kind == "lineup" then np = wld(V(l.x, 0, L.z), p.pos.y)
        elseif kind == "space" then np = wld(V(x0 + (x1 - x0) * (i - 1) / (#ids - 1), 0, l.z), p.pos.y)
        elseif kind == "level" then np = V(p.pos.x, S.target.pos.y, p.pos.z) end
        if id == S.sel.id then
            S.target = { pos = np, heading = nh, scale = p.scale }
            S.dirty = true
        else
            S.gt[id] = { pos = np, heading = nh, scale = p.scale }
        end
    end
    local words = { mirrorX = "Mirrored left / right", mirrorZ = "Mirrored front / back", lineup = "Lined up", space = "Spaced evenly", level = "Same height" }
    say(string.format("%s: %d objects.  (Undo puts them back)", words[kind] or kind, #ids))
end

-- ---------------------------------------------------------------- grid snapping
FN.GRIDS = { 0, 0.25, 0.5, 1, 2 }
FN.GRID_NAMES = { "Off", "0.25 m", "0.5 m", "1 m", "2 m" }
S.gridI = 1
function FN.gridSize() return FN.GRIDS[S.gridI] or 0 end
-- on the ground grid (x and z), when nothing else is snapped to
function FN.gridSnap(p, guides)
    local g = FN.gridSize()
    if g <= 0 or (guides and #guides > 0) then return p end
    return V(round(p.x, g), p.y, round(p.z, g))
end

-- ---------------------------------------------------------------- copy tools: a row, a circle or a grid of copies
S.tools = { kind = 1, count = 5, count2 = 3, dir = 1, gap = 0, radius = 5, face = 1 }
FN.KINDS = { "Row", "Circle", "Grid" }
FN.DIRS = { "Sideways", "Forward", "Up" }
FN.FACES = { "To the middle", "Same way" }
local function cyc(v, n, d) return (v - 1 + d) % n + 1 end
function FN.planCopies()
    if not (S.sel and S.target) then return {} end
    local T = S.tools
    local list = FN.heldList()
    local L = S.target
    local X = V(math.cos(L.heading), 0, -math.sin(L.heading))
    local Z = V(math.sin(L.heading), 0, math.cos(L.heading))
    local out = {}
    local function add(off, turn, about, keepHeading)
        for _, s in ipairs(list) do
            local p, h = s.pos, s.heading
            if turn ~= 0 then
                p = about + rotY(p - about, turn)
                if not keepHeading then h = wrap(h + turn) end
            end
            out[#out + 1] = { item = s.item, pos = p + off, heading = h, scale = s.scale, tilt = s.tilt }
        end
    end
    if T.kind == 1 then
        local dir = ({ X, Z, UP })[T.dir]
        local step = extentAlong(list, dir) + T.gap
        for i = 1, T.count - 1 do add(dir * (step * i), 0) end
    elseif T.kind == 2 then
        local c = L.pos - Z * T.radius
        for i = 1, T.count - 1 do add(V(0, 0, 0), i * 2 * math.pi / T.count, c, T.face == 2) end
    else
        local sx, sz = extentAlong(list, X) + T.gap, extentAlong(list, Z) + T.gap
        for i = 0, T.count - 1 do
            for j = 0, T.count2 - 1 do
                if i > 0 or j > 0 then add(X * (sx * i) + Z * (sz * j), 0) end
            end
        end
    end
    return out
end
function FN.toolsRows()
    local T = S.tools
    local st = STEPS[S.stepSize] or STEPS[2]
    local rows = {}
    rows[#rows + 1] = { "Make", FN.KINDS[T.kind], function(d) T.kind = cyc(T.kind, 3, d) end }
    rows[#rows + 1] = { T.kind == 3 and "Across" or "How many", tostring(T.count), function(d) T.count = clamp(T.count + d, 2, 50) end }
    if T.kind == 1 then
        rows[#rows + 1] = { "Which way", FN.DIRS[T.dir], function(d) T.dir = cyc(T.dir, 3, d) end }
        rows[#rows + 1] = { "Gap", string.format("%.2f m", T.gap), function(d) T.gap = clamp(round(T.gap + d * st.m, 0.01), -10, 50) end }
    elseif T.kind == 2 then
        rows[#rows + 1] = { "Size (radius)", string.format("%.2f m", T.radius), function(d) T.radius = clamp(round(T.radius + d * st.m * 5, 0.01), 0.25, 200) end }
        rows[#rows + 1] = { "Facing", FN.FACES[T.face], function(d) T.face = cyc(T.face, 2, d) end }
    else
        rows[#rows + 1] = { "Deep", tostring(T.count2), function(d) T.count2 = clamp(T.count2 + d, 1, 20) end }
        rows[#rows + 1] = { "Gap", string.format("%.2f m", T.gap), function(d) T.gap = clamp(round(T.gap + d * st.m, 0.01), -10, 50) end }
    end
    rows[#rows + 1] = { "Grid snap", FN.GRID_NAMES[S.gridI], function(d) S.gridI = cyc(S.gridI, #FN.GRIDS, d) end }
    rows[#rows + 1] = { "make" }
    return rows
end
function FN.makeCopies()
    local plan = FN.planCopies()
    if #plan == 0 then say("Pick an object first.") return end
    queueCopies(plan, FN.KINDS[S.tools.kind])
    S.toolsWin = nil
    say(string.format("Making %d copies (%s)...", math.min(#plan, MAX_COPIES), FN.KINDS[S.tools.kind]))
end
function FN.openTools()
    if not (S.sel and S.target) then say("Pick an object first, then open the copy tools.") return end
    S.toolsWin = { row = 1 }
end
S.openTools = FN.openTools
-- the controller in the window: D-pad up / down choose, left / right change, A makes them, B closes
function FN.toolsPad(p)
    local W = S.toolsWin
    local rows = FN.toolsRows()
    W.row = clamp(W.row, 1, #rows)
    if padPress("b", p.b) then S.toolsWin = nil return end
    if padPress("a", p.a) then FN.makeCopies() return end
    if padStep("tu", p.up) then W.row = clamp(W.row - 1, 1, #rows) end
    if padStep("td", p.down) then W.row = clamp(W.row + 1, 1, #rows) end
    local f = rows[W.row][3]
    if f and padStep("tl", p.left) then f(-1) end
    if f and padStep("tr", p.right) then f(1) end
end
-- the mouse in the window: < and > change a row, the button makes them; true when the click was the window's
function FN.toolsMouse(c)
    local box = S.screen and S.screen.toolsBox
    if not (S.toolsWin and box) then return false end
    local px = c.position
    local inside = px.x >= box.a.x and px.x <= box.b.x and px.y >= box.a.y and px.y <= box.b.y
    if not inside then return false end
    if c.left and not S.mouse.left then
        local rows = FN.toolsRows()
        for _, t in ipairs(S.screen.toolsTiles or {}) do
            if px.x >= t.a.x and px.x <= t.b.x and px.y >= t.a.y and px.y <= t.b.y then
                if t.make then FN.makeCopies()
                elseif t.close then S.toolsWin = nil
                elseif rows[t.row] and rows[t.row][3] then S.toolsWin.row = t.row; rows[t.row][3](t.d) end
                break
            end
        end
    end
    return true
end
function FN.drawTools(d)
    local W = S.toolsWin
    if not W then return end
    local plan = FN.planCopies()
    -- where the copies will go
    for i, c in ipairs(plan) do
        if i > MAX_COPIES then break end
        if S.itemBox[c.item] then
            drawShape(d, worldShape(c.item, c.pos, c.heading, c.scale), UI.green, 2)
        else
            d:world_line(c.pos - V(0.4, 0, 0), c.pos + V(0.4, 0, 0), { colour = UI.green, thickness = 2 })
            d:world_line(c.pos - V(0, 0, 0.4), c.pos + V(0, 0, 0.4), { colour = UI.green, thickness = 2 })
        end
    end
    local rows = FN.toolsRows()
    W.row = clamp(W.row, 1, #rows)
    local rh, w = 44, 420
    local a = V(32, math.floor(S.size.y * 0.2), 0)
    local b = a + V(w, 52 + 14 + #rows * rh + 56, 0)
    S.screen.toolsBox = { a = a, b = b }
    S.screen.toolsTiles = {}
    UI.panelBox(d, a, b, "Copy tools")
    local ca, cb = V(b.x - 44, a.y + 10, 0), V(b.x - 12, a.y + 42, 0)
    d:text(V((ca.x + cb.x) / 2, ca.y + 4, 0), "×", { size = 22, colour = UI.dim, align = "centre" })
    table.insert(S.screen.toolsTiles, { a = ca, b = cb, close = true })
    for i, r in ipairs(rows) do
        local ra = V(a.x + 14, a.y + 62 + (i - 1) * rh, 0)
        local rb = V(b.x - 14, ra.y + rh - 6, 0)
        local selected = i == W.row
        if r[1] == "make" then
            d:rect(ra, rb, { colour = selected and UI.accent or UI.tileHot, fill = true, rounding = 10 })
            local n = math.min(#plan, MAX_COPIES)
            d:text(V((ra.x + rb.x) / 2, ra.y + 9, 0), string.format("Make %d cop%s", n, n == 1 and "y" or "ies"), { size = 17, colour = selected and "#0d1117" or UI.text, font = "bold", align = "centre" })
            table.insert(S.screen.toolsTiles, { a = ra, b = rb, make = true })
        else
            d:rect(ra, rb, { colour = selected and UI.accentDim or UI.tile, fill = true, rounding = 10 })
            if selected then d:rect(V(ra.x, ra.y + 8, 0), V(ra.x + 3, rb.y - 8, 0), { colour = UI.accent, fill = true, rounding = 2 }) end
            d:text(ra + V(16, 10, 0), r[1], { size = 16, colour = UI.dim })
            -- the value between < and >
            local vx0, vx1 = ra.x + 170, rb.x - 10
            local la, lb2 = V(vx0, ra.y, 0), V(vx0 + 30, rb.y, 0)
            local ga, gb = V(vx1 - 30, ra.y, 0), V(vx1, rb.y, 0)
            local col = selected and UI.accent or UI.dim
            d:text(V(la.x + 15, ra.y + 8, 0), "<", { size = 20, colour = col, align = "centre" })
            d:text(V((vx0 + vx1) / 2, ra.y + 10, 0), r[2], { size = 16, colour = selected and UI.text or UI.text, font = selected and "bold" or nil, align = "centre" })
            d:text(V(ga.x + 15, ra.y + 8, 0), ">", { size = 20, colour = col, align = "centre" })
            table.insert(S.screen.toolsTiles, { a = la, b = lb2, row = i, d = -1 })
            table.insert(S.screen.toolsTiles, { a = ga, b = gb, row = i, d = 1 })
        end
    end
    UI.footer(d, a, b, { { "D-pad", "Choose" }, { "a", "Make" }, { "b", "Close" } })
end

-- the group as it is (and where its followers are going)
function FN.drawGroup(d)
    for id in pairs(S.group) do
        local o = S.known and S.known[id]
        if o and not (S.sel and S.sel.id == id and S.grab) then
            local g = S.gt[id]
            if g and S.itemBox[o.item] then
                local tl = tilted(id) and S.tilt[id] or nil
                local xf = tl and function(v) return tiltPoint(g.pos, g.heading, tl, v) end or nil
                drawShape(d, worldShape(o.item, g.pos, g.heading, g.scale), "#c49bff", 3, xf)
            else
                local so = placedSolid(o)
                if not drawShape(d, so.shape or so, "#c49bff", 3, so.xf) then
                    local q = o.position
                    d:world_line(q - V(0.4, 0, 0), q + V(0.4, 0, 0), { colour = "#c49bff", thickness = 3 })
                    d:world_line(q - V(0, 0, 0.4), q + V(0, 0, 0.4), { colour = "#c49bff", thickness = 3 })
                end
            end
        end
    end
end
-- a few lines of the ground grid round the held object
function FN.drawGrid(d)
    local g = FN.gridSize()
    if g <= 0 or not S.target then return end
    local p = S.target.pos
    local cx, cz = round(p.x, g), round(p.z, g)
    local n = 6
    for i = -n, n do
        d:world_line(V(cx + i * g, p.y, cz - n * g), V(cx + i * g, p.y, cz + n * g), { colour = "#ffffff30", thickness = 1 })
        d:world_line(V(cx - n * g, p.y, cz + i * g), V(cx + n * g, p.y, cz + i * g), { colour = "#ffffff30", thickness = 1 })
    end
end


-- ---------------------------------------------------------------- the add window (A with nothing under the cross)
-- A grid of every Quick Drop object, with pictures of the Object Maker's ones (thumbs.lua: sheets of 4 x 4 in
-- plugin/thumbs), by category. A places the chosen one where the cross is and hands it over to be moved.
local THUMBS = {}
do
    local ok, t = pcall(function() return require("thumbs") end)
    if ok and type(t) == "table" then THUMBS = t end
    -- pictures saved by DDH Get Thumbnails (the game's own objects and the rest): sheets of 6 x 6 at 85 px
    local ok2, g = pcall(function() return require("gthumbs") end)
    if ok2 and type(g) == "table" then
        local n = 0
        for k, v in pairs(g) do
            if not THUMBS[k] then THUMBS[k] = { v[1], v[2], v[3], g = true }; n += 1 end
        end
        reskate.log(string.format("Quick Drop helper: %d more pictures from DDH Get Thumbnails.", n))
    end
end
-- a picture's sheet and its corner and size on it
function UI.thumbOf(key)
    local th = THUMBS[key]
    if not th then return nil end
    if th.g then
        local k = 85 / 512
        return string.format("plugin/thumbs/g%02d.png", th[1]), th[2] * k, th[3] * k, k
    end
    return string.format("plugin/thumbs/sheet%02d.png", th[1]), th[2] / 4, th[3] / 4, 0.25
end
local PICK_COLS, PICK_ROWS = 6, 3
function FN.pickerTabs()
    local ok, cat = pcall(reskate.objects.catalog)
    if not ok or type(cat) ~= "table" then cat = {} end
    local tabs, byName = {}, {}
    local mine = { name = "DDH", items = {} }
    for _, it in ipairs(cat) do
        if string.find(string.lower(it.key), "bkddh", 1, true) then table.insert(mine.items, it) end
    end
    if #mine.items > 0 then tabs[1] = mine end
    if S.loadSets then
        local sets = S.loadSets()
        if #sets > 0 then
            local st = { name = "Sets", items = {} }
            for _, set in ipairs(sets) do st.items[#st.items + 1] = { key = "set:" .. set.file, title = set.name, set = set } end
            tabs[#tabs + 1] = st
        end
    end
    for _, it in ipairs(cat) do
        local c = tostring(it.category or "Other")
        if not byName[c] then byName[c] = { name = c, items = {} }; tabs[#tabs + 1] = byName[c] end
        table.insert(byName[c].items, it)
    end
    for _, t in ipairs(tabs) do
        table.sort(t.items, function(a, b) return tostring(a.title or a.key) < tostring(b.title or b.key) end)
    end
    return tabs
end
function FN.openPicker()
    local tabs = FN.pickerTabs()
    if not S.loggedPics then
        S.loggedPics = true
        local none, ddh = 0, {}
        for _, t in ipairs(tabs) do
            if t.name ~= "DDH" then
                for _, it in ipairs(t.items) do
                    if not THUMBS[it.key] then
                        none += 1
                        if string.find(string.lower(it.key), "bkddh", 1, true) then table.insert(ddh, it.key) end
                    end
                end
            end
        end
        reskate.log(string.format("Quick Drop helper: add window: %d objects have no picture (%d of them DDH)%s", none, #ddh, #ddh > 0 and (": " .. table.concat(ddh, ", ")) or ""))
    end
    if #tabs == 0 then say("The game lists no objects to add.", true) return end
    S.picker = { tabs = tabs, tab = 1, sel = 1, top = 0 }
    S.padWait = true
end
local function closePicker() S.picker = nil; S.padWait = true end
S.openPicker = FN.openPicker
-- where the cross is: the ground (or anything) it points at, else in front of the view
function FN.crossPoint()
    local cpos, f = camBasis()
    local ok, hit = pcall(reskate.world.pick, cpos, cpos + f * 200)
    if ok and type(hit) == "table" and hit.position and len(hit.position - (cpos + f * 200)) > 0.5 then return hit.position end
    return S.cam.target
end
function FN.pickerPlace()
    local pk = S.picker
    local tab = pk and pk.tabs[pk.tab]
    local it = tab and tab.items[pk.sel]
    if not it then return end
    local at = FN.crossPoint()
    if it.set then
        closePicker()
        S.carrySet(it.set, at, wrap(S.cam.yaw + math.pi))
        return
    end
    -- facing the view, as Quick Drop does
    S.copyQ = { item = it.key, pos = at, heading = wrap(S.cam.yaw + math.pi), scale = 1, until_ = S.clock + 3000, grab = true }
    closePicker()
    say("Adding " .. tostring(it.title or it.key) .. "...")
end
local function pickerMove(dc, dr)
    local pk = S.picker
    local n = #pk.tabs[pk.tab].items
    if n == 0 then return end
    local i = pk.sel - 1 + dc + dr * PICK_COLS
    i = clamp(i, 0, n - 1)
    pk.sel = i + 1
    local row = math.floor(i / PICK_COLS)
    if row < pk.top then pk.top = row end
    if row >= pk.top + PICK_ROWS then pk.top = row - PICK_ROWS + 1 end
end
function FN.pickerTab(d)
    local pk = S.picker
    pk.tab = (pk.tab - 1 + d) % #pk.tabs + 1
    pk.sel, pk.top = 1, 0
end
-- the controller in the window
function FN.pickerPad(p)
    if padPress("b", p.b) then closePicker() return end
    if padPress("a", p.a) then FN.pickerPlace() return end
    if padPress("lb", p.lb) then FN.pickerTab(-1) end
    if padPress("rb", p.rb) then FN.pickerTab(1) end
    local lx, ly = stick(p.lx, p.ly)
    if padStep("pl", p.left or lx < -0.5) then pickerMove(-1, 0) end
    if padStep("pr", p.right or lx > 0.5) then pickerMove(1, 0) end
    if padStep("pu", p.up or ly > 0.5) then pickerMove(0, -1) end
    if padStep("pd", p.down or ly < -0.5) then pickerMove(0, 1) end
end
-- the mouse in the window: click a picture to add it, scroll the wheel, click outside to close
function FN.pickerMouse(c)
    local pk = S.picker
    local px = c.position
    if c.wheel and c.wheel ~= 0 then
        local n = #pk.tabs[pk.tab].items
        local rows = math.ceil(n / PICK_COLS)
        pk.top = clamp(pk.top - c.wheel, 0, math.max(0, rows - PICK_ROWS))
    end
    local hov = nil
    for _, t in ipairs((S.screen and S.screen.pickTiles) or {}) do
        if px.x >= t.a.x and px.x <= t.b.x and px.y >= t.a.y and px.y <= t.b.y then hov = t end
    end
    pk.hover = hov and hov.i or nil
    if c.left and not S.mouse.left then
        if hov then
            if hov.tab then FN.pickerTab(hov.tab - pk.tab) else pk.sel = hov.i; FN.pickerPlace() end
        else
            local box = S.screen and S.screen.pickBox
            if box and not (px.x >= box.a.x and px.x <= box.b.x and px.y >= box.a.y and px.y <= box.b.y) then closePicker() end
        end
    end
end
-- an object with no picture but a known shape: its outline seen from above, filling the tile
function UI.drawFootprint(d, item, a, b)
    S.footDrawn = false
    local pts = localOutline(item)
    if not pts or #pts < 3 then return end
    local lo, hi = V(math.huge, 0, math.huge), V(-math.huge, 0, -math.huge)
    for _, q in ipairs(pts) do lo = V(math.min(lo.x, q.x), 0, math.min(lo.z, q.z)); hi = V(math.max(hi.x, q.x), 0, math.max(hi.z, q.z)) end
    local w, h = math.max(hi.x - lo.x, 1e-3), math.max(hi.z - lo.z, 1e-3)
    local k = math.min((b.x - a.x) / w, (b.y - a.y) / h)
    local ox, oy = (a.x + b.x) / 2, (a.y + b.y) / 2
    local sp = {}
    for i, q in ipairs(pts) do sp[i] = V(ox + (q.x - (lo.x + hi.x) / 2) * k, oy - (q.z - (lo.z + hi.z) / 2) * k, 0) end
    for i = 1, #sp do d:line(sp[i], sp[i % #sp + 1], { colour = "#9fd8ff", thickness = 2 }) end
    S.footDrawn = true
end
function FN.shortTitle(t, n) t = tostring(t); if #t > n then return string.sub(t, 1, n - 1) .. "…" end return t end
-- drawing it
function FN.drawPicker(d)
    local pk = S.picker
    if not pk then return end
    local W, H = S.size.x, S.size.y
    local tile, gap = 148, 16
    local pw = PICK_COLS * tile + (PICK_COLS - 1) * gap + 48
    local ph = 52 + 58 + PICK_ROWS * (tile + 34) + 60
    local a = V(math.floor((W - pw) / 2), math.floor((H - ph) / 2), 0)
    local b = a + V(pw, ph, 0)
    S.screen.pickBox = { a = a, b = b }
    S.screen.pickTiles = {}
    d:rect(V(0, 0, 0), V(W, H, 0), { colour = "#00000066", fill = true })
    UI.panelBox(d, a, b, "Add object")
    local items = pk.tabs[pk.tab].items
    local rows = math.ceil(#items / PICK_COLS)
    d:text(V(b.x - 20, a.y + 17, 0), string.format("%d objects", #items), { size = 15, colour = UI.dim, align = "right" })
    -- the categories: pills, the chosen one in the accent colour
    local x = a.x + 20
    for i, t in ipairs(pk.tabs) do
        local label = string.format("%s  %d", FN.shortTitle(t.name, 18), #t.items)
        local w = UI.textW(d, label, 15) + 26
        if x + w > b.x - 20 then break end
        local ta, tb = V(x, a.y + 66, 0), V(x + w, a.y + 96, 0)
        local on = i == pk.tab
        d:rect(ta, tb, { colour = on and UI.accent or UI.tile, fill = true, rounding = 15 })
        d:text(ta + V(13, 6, 0), label, { size = 15, colour = on and "#0d1117" or UI.text, font = on and "bold" or nil })
        table.insert(S.screen.pickTiles, { a = ta, b = tb, tab = i })
        x = x + w + 8
    end
    -- the pictures
    local top = a.y + 52 + 58
    for r = 0, PICK_ROWS - 1 do
        for cI = 0, PICK_COLS - 1 do
            local i = (pk.top + r) * PICK_COLS + cI + 1
            local it = items[i]
            if it then
                local ta = V(a.x + 24 + cI * (tile + gap), top + r * (tile + 34), 0)
                local tb = ta + V(tile, tile, 0)
                local selected, hovered = i == pk.sel, i == pk.hover
                d:rect(ta, tb, { colour = selected and UI.accentDim or (hovered and UI.tileHot or UI.tile), fill = true, rounding = 10 })
                local path, u0, v0, k = UI.thumbOf(it.key)
                if it.set then
                    pcall(UI.drawSetPreview, d, it.set, ta + V(16, 16, 0), tb - V(16, 30, 0), UI.purple)
                    d:text(V((ta.x + tb.x) / 2, tb.y - 24, 0), string.format("%d objects", #it.set.objects), { size = 13, colour = UI.dim, align = "centre" })
                elseif path then
                    d:image(path, ta + V(8, 8, 0), tb - V(8, 8, 0), { uv = { u0, v0, u0 + k, v0 + k } })
                elseif not pcall(UI.drawFootprint, d, it.key, ta + V(22, 22, 0), tb - V(22, 22, 0)) or not S.footDrawn then
                    -- no picture and no known shape: its initials, big
                    local name = tostring(it.title or it.key)
                    local ini = string.upper(string.sub(name, 1, 1)) .. (string.match(name, "%s(%w)") or "")
                    d:text(V((ta.x + tb.x) / 2, ta.y + tile / 2 - 22, 0), ini, { size = 40, colour = "#ffffff40", font = "title", align = "centre" })
                end
                if selected then d:rect(ta, tb, { colour = UI.accent, rounding = 10, thickness = 3 }) end
                d:text(V((ta.x + tb.x) / 2, tb.y + 7, 0), FN.shortTitle(it.title or it.key, 19), { size = 14, colour = selected and UI.accent or UI.dim, align = "centre" })
                table.insert(S.screen.pickTiles, { a = ta, b = tb, i = i })
            end
        end
    end
    -- where in the list: a slim bar on the right
    if rows > PICK_ROWS then
        local y0, y1 = top, top + PICK_ROWS * (tile + 34) - 34
        local x0 = b.x - 12
        d:rect(V(x0, y0, 0), V(x0 + 4, y1, 0), { colour = UI.tile, fill = true, rounding = 2 })
        local f0, f1 = pk.top / rows, math.min(1, (pk.top + PICK_ROWS) / rows)
        d:rect(V(x0, y0 + (y1 - y0) * f0, 0), V(x0 + 4, y0 + (y1 - y0) * f1, 0), { colour = UI.accent, fill = true, rounding = 2 })
    end
    UI.footer(d, a, b, { { "a", "Add" }, { "b", "Close" }, { "LB RB", "Category" }, { "D-pad", "Choose" } })
end

-- ---------------------------------------------------------------- sets: a group saved to place again later (any map, any server)
-- Saved as files in the plugin's data folder ("sets/<name>.json"), so they can be shared: send the file, a friend
-- puts it in their own sets folder. Each object: its item, place and turn next to the set's middle, size and tilt.
;(function()
    local FOLDER = "sets"
    local function safeName(n)
        n = string.gsub(tostring(n), "[^%w%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #n > 40 then n = string.sub(n, 1, 40) end
        return n
    end
    function S.loadSets()
        local out = {}
        local ok, lst = pcall(reskate.files.list, FOLDER)
        if ok and type(lst) == "table" then
            for _, e in ipairs(lst) do
                local name = type(e) == "table" and (e.name or e.path) or e
                name = tostring(name)
                local base = string.match(name, "([^/\\]+)$") or name
                if string.lower(string.sub(base, -5)) == ".json" then
                    local okr, txt = pcall(reskate.files.read, FOLDER .. "/" .. base)
                    if okr and type(txt) == "string" then
                        local okd, data = pcall(reskate.json.decode, txt)
                        if okd and type(data) == "table" and type(data.objects) == "table" and #data.objects > 0 then
                            out[#out + 1] = { name = tostring(data.name or string.sub(base, 1, -6)), file = base, objects = data.objects }
                        end
                    end
                end
            end
        end
        table.sort(out, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
        S.sets = out
        S.setsAt = S.clock
        return out
    end
    -- what would be saved: the group (with the picked one), or just the picked object
    local function members()
        local list = {}
        local seen = {}
        local function add(id, p)
            local o = S.known and S.known[id]
            if o and p and not seen[id] then
                seen[id] = true
                local tl = S.tilt[id]
                list[#list + 1] = { id = id, item = o.item, pos = p.pos, heading = p.heading, scale = p.scale, tilt = tl }
            end
        end
        if S.sel and S.target then add(S.sel.id, S.target) end
        for id in pairs(S.group) do add(id, poseOf(id)) end
        return list
    end
    S.setMembers = members
    function S.saveSet(name)
        local list = members()
        if #list == 0 then say("Pick an object or make a group first, then save it as a set.", true) return end
        name = safeName(name)
        if name == "" then say("A set needs a name.", true) return end
        -- the middle (x, z) at the lowest point, turned like the first one
        local lo, hi, ymin = V(math.huge, 0, math.huge), V(-math.huge, 0, -math.huge), math.huge
        for _, m in ipairs(list) do
            lo = V(math.min(lo.x, m.pos.x), 0, math.min(lo.z, m.pos.z)); hi = V(math.max(hi.x, m.pos.x), 0, math.max(hi.z, m.pos.z))
            ymin = math.min(ymin, m.pos.y)
        end
        local O = V((lo.x + hi.x) / 2, ymin, (lo.z + hi.z) / 2)
        local h0 = list[1].heading
        local objs = {}
        for _, m in ipairs(list) do
            local off = rotY(m.pos - O, -h0)
            local e = { item = m.item, x = math.floor(off.x * 1000 + 0.5) / 1000, y = math.floor(off.y * 1000 + 0.5) / 1000, z = math.floor(off.z * 1000 + 0.5) / 1000,
                h = math.floor(wrap(m.heading - h0) * 1e5 + 0.5) / 1e5, s = math.floor(m.scale * 1000 + 0.5) / 1000 }
            if m.tilt then e.tx, e.tz = m.tilt.x, m.tilt.z end
            objs[#objs + 1] = e
        end
        local data = { format = "ddh-park-set", version = 1, name = name, objects = objs }
        local file = string.gsub(name, " ", "_") .. ".json"
        local ok, why = pcall(reskate.files.write, FOLDER .. "/" .. file, reskate.json.encode(data, true))
        if not ok or why == false then say("Set not saved: " .. tostring(why), true) return end
        S.loadSets()
        say(string.format("Saved the set \"%s\" (%d object%s). Find it under Sets, or in Add object.", name, #objs, #objs == 1 and "" or "s"))
        reskate.log(string.format("Quick Drop helper: saved set %s with %d objects", file, #objs))
    end
    function S.renameSetFn(set, newName)
        newName = safeName(newName)
        if newName == "" then say("A set needs a name.", true) return end
        local data = { format = "ddh-park-set", version = 1, name = newName, objects = set.objects }
        local file = string.gsub(newName, " ", "_") .. ".json"
        local ok, why = pcall(reskate.files.write, FOLDER .. "/" .. file, reskate.json.encode(data, true))
        if not ok or why == false then say("Not renamed: " .. tostring(why), true) return end
        if file ~= set.file then pcall(reskate.files.remove, FOLDER .. "/" .. set.file) end
        S.loadSets()
        say("Renamed to \"" .. newName .. "\".")
    end
    function S.deleteSet(set)
        local ok = pcall(reskate.files.remove, FOLDER .. "/" .. set.file)
        S.loadSets()
        say(ok and ("Deleted the set \"" .. set.name .. "\".") or "Could not delete it.", not ok)
    end
    function S.openSetsFolder()
        pcall(reskate.files.write, FOLDER .. "/READ ME.txt", "Sets saved with the DDH Park Editor. Share a set by sending its .json file; put sets you get here.\n")
        pcall(reskate.files.reveal, FOLDER)
    end
    -- place a set: its middle where the cross is, facing the view; then it is held (controller) or picked as a group
    function S.placeSet(set, at, heading, dropped)
        local have = {}
        for _, it in ipairs(reskate.objects.catalog()) do have[it.key] = true end
        at = at or (S.cam and S.cam.target) or V(0, 0, 0)
        heading = heading or wrap(S.cam.yaw + math.pi)
        local list, missing = {}, 0
        for i, e in ipairs(set.objects) do
            if have[e.item] then
                local off = rotY(V(e.x or 0, e.y or 0, e.z or 0), heading)
                list[#list + 1] = { item = e.item, pos = at + off, heading = wrap(heading + (e.h or 0)), scale = clamp(e.s or 1, 0.1, 10),
                    tilt = (e.tx or e.tz) and { x = e.tx or 0, z = e.tz or 0 } or nil, first = i == 1 }
            else
                missing += 1
            end
        end
        if #list == 0 then say("None of this set's objects are installed (their mods are missing).", true) return end
        local rec = { ids = {}, byIdx = {}, total = 0, done = 0, failed = 0, label = "Set \"" .. set.name .. "\"" }
        for i, c in ipairs(list) do
            if i > 200 then break end
            table.insert(S.q, { op = "place", item = c.item, pos = c.pos, heading = c.heading, scale = c.scale, tilt = c.tilt, rec = rec, idx = i })
            rec.total += 1
        end
        rec.items = list
        S.pushUndo({ kind = "placed", rec = rec })
        -- all there: they become the group; the first is picked (and held, with the controller)
        rec.onAll = function(r)
            S.group = {}
            for _, id in ipairs(r.ids) do S.group[id] = true end
            S.gbase = nil
            local lead = S.known and S.known[r.byIdx[1] or r.ids[1]]
            if lead and S.open then
                select(lead)
                local padMode = S.padUsedAt and (not S.mouseUsedAt or S.padUsedAt >= S.mouseUsedAt)
                if padMode and not dropped then
                    startGrab()
                    if S.grab then S.grab.copyRec = r end
                end
            end
            say(string.format("Placed the set \"%s\": %d objects (picked as a group).%s", set.name, #r.ids, missing > 0 and string.format(" %d left out (mod missing).", missing) or ""))
        end
        say(string.format("Placing the set \"%s\" (%d objects)...%s", set.name, rec.total, missing > 0 and string.format(" %d left out: their mod is missing.", missing) or ""), missing > 0)
    end
    -- carrying a set before it is placed: it follows the cross (or the mouse) as outlines; A / click puts it down
    function S.carrySet(set, at, heading)
        S.carry = { set = set, pos = at or (S.cam and S.cam.target) or V(0, 0, 0), heading = heading or wrap(S.cam.yaw + math.pi) }
        S.grab = nil
        S.padWait = true
        S.cam.goal = S.carry.pos
        say("Carrying \"" .. set.name .. "\": move it, A puts it down, B cancels.")
    end
    function S.carryPlaces()
        local c = S.carry
        if not c then return {} end
        local out = {}
        local H = c.snapH or c.heading
        for _, e in ipairs(c.set.objects) do
            out[#out + 1] = { item = e.item, pos = c.pos + rotY(V(e.x or 0, e.y or 0, e.z or 0), H), heading = wrap(H + (e.h or 0)), scale = clamp(e.s or 1, 0.1, 10) }
        end
        return out
    end
    -- where the carried set snaps to: each of its pieces is tried as if it were the held object; the smallest
    -- move that meets something wins, and the whole set takes it
    function S.carrySnap(at, allow)
        local c = S.carry
        if not (c and S.osnap and S.known) or S.snapPick == "off" then return nil end
        local saveSel, saveT = S.sel, S.target
        local best, bestG, bestCost, bestH = nil, nil, math.huge, nil
        for i, e in ipairs(c.set.objects) do
            if i > 40 then break end
            local off = V(e.x or 0, e.y or 0, e.z or 0)
            local p = at + rotY(off, c.heading)
            local h = wrap(c.heading + (e.h or 0))
            local sc = clamp(e.s or 1, 0.1, 10)
            if S.itemBox[e.item] then
                S.sel = { id = "__carry", item = e.item }
                S.target = { pos = p, heading = h, scale = sc }
                -- (like one held object: it meets faces, and turns to meet a turned neighbour flat)
                local ok, np, nh, g = pcall(snapTurned, p, h, sc, allow, nil)
                if ok and g and #g > 0 then
                    local dh = wrap(nh - h)
                    local setH = wrap(c.heading + dh)
                    local setPos = np - rotY(off, setH)
                    local cost = len(np - p) + math.abs(dh) * 0.5 - (g[1].kind == "touch" and 0.05 or 0)
                    if cost < bestCost then best, bestG, bestCost, bestH = setPos, g, cost, setH end
                end
            end
        end
        S.sel, S.target = saveSel, saveT
        return best, bestG, bestH
    end
    function S.carryDrop()
        local c = S.carry
        if not c then return end
        S.carry = nil
        S.placeSet(c.set, c.pos, c.snapH or c.heading, true)
    end
    function S.carryCancel()
        if not S.carry then return end
        S.carry = nil
        say("Cancelled: nothing placed.")
    end
    -- a set seen from above: every object's outline, fitted into a box
    function UI.drawSetPreview(d, set, a, b, col)
        local shapes = {}
        local lo, hi = V(math.huge, 0, math.huge), V(-math.huge, 0, -math.huge)
        for _, e in ipairs(set.objects) do
            local pts = localOutline(e.item)
            local c, s, k = math.cos(e.h or 0), math.sin(e.h or 0), e.s or 1
            local w = {}
            if pts and #pts >= 3 then
                for i, q in ipairs(pts) do
                    local x, z = q.x * k, q.z * k
                    w[i] = V((e.x or 0) + x * c + z * s, 0, (e.z or 0) - x * s + z * c)
                end
            else
                local p = V(e.x or 0, 0, e.z or 0)
                w = { p + V(-0.4, 0, -0.4), p + V(0.4, 0, -0.4), p + V(0.4, 0, 0.4), p + V(-0.4, 0, 0.4) }
            end
            for _, q in ipairs(w) do lo = V(math.min(lo.x, q.x), 0, math.min(lo.z, q.z)); hi = V(math.max(hi.x, q.x), 0, math.max(hi.z, q.z)) end
            shapes[#shapes + 1] = w
        end
        local sw, sh = math.max(hi.x - lo.x, 0.1), math.max(hi.z - lo.z, 0.1)
        local kk = math.min((b.x - a.x) / sw, (b.y - a.y) / sh)
        local ox, oy = (a.x + b.x) / 2, (a.y + b.y) / 2
        local mx, mz = (lo.x + hi.x) / 2, (lo.z + hi.z) / 2
        local n = 0
        for _, w in ipairs(shapes) do
            for i = 1, #w do
                local p1, p2 = w[i], w[i % #w + 1]
                d:line(V(ox + (p1.x - mx) * kk, oy - (p1.z - mz) * kk, 0), V(ox + (p2.x - mx) * kk, oy - (p2.z - mz) * kk, 0), { colour = col or "#9fd8ff", thickness = 2 })
                n += 1
                if n > 600 then return end
            end
        end
    end
end)()

function FN.padEditor(sec)
    local p = FN.readPad()
    if not p then return end
    if S.padWait then
        for k in pairs(FN.PADNAMES) do if p[k] then return end end
        if p.lt > 0.3 or p.rt > 0.3 then return end
        S.padWait = false
    end
    -- the controller is in use: the aiming cross shows
    -- (a clear push only: a resting stick or trigger does not count, so the mouse keeps its handles)
    local anyIn = math.abs(p.lx) > 0.5 or math.abs(p.ly) > 0.5 or math.abs(p.rx) > 0.5 or math.abs(p.ry) > 0.5 or p.lt > 0.5 or p.rt > 0.5
    S.padPrevB = S.padPrevB or {}
    for k in pairs(FN.PADNAMES) do
        if p[k] and not S.padPrevB[k] then anyIn = true end
        S.padPrevB[k] = p[k]
    end
    if anyIn then S.padUsedAt = S.clock end

    if S.picker then FN.pickerPad(p) return end
    if S.controlsOpen then
        if padPress("b", p.b) or padPress("a", p.a) then S.controlsOpen = false end
        return
    end
    if S.carry then
        -- carrying a set: left stick moves it, RT / LT up / down, LB / RB turn, right stick circles round it,
        -- L3 tapped: snap to the nearest object, then the next
        local c = S.carry
        if p.ls and not S.l3At then S.l3At = S.clock end
        if not p.ls and S.l3At then
            if S.clock - S.l3At < 300 then FN.nextCarrySnap() end
            S.l3At = nil
        end
        if padPress("a", p.a) then S.carryDrop() return end
        if padPress("b", p.b) then S.carryCancel() return end
        local st = STEPS[S.stepSize] or STEPS[2]
        if p.ls then st = STEPS[1] end
        local rx, ry = stick(p.rx, p.ry)
        if S.lookInvX then rx = -rx end
        if S.lookInvY then ry = -ry end
        S.cam.yaw -= rx * 2.4 * sec
        S.cam.pitch = clamp(S.cam.pitch - ry * 1.6 * sec, -1.45, 1.45)
        local _, f, r = camBasis()
        local lx, ly = stick(p.lx, p.ly)
        local up = p.rt - p.lt
        if math.abs(up) < 0.15 then up = 0 end
        if lx ~= 0 or ly ~= 0 or up ~= 0 then
            local mv = (flat(f) * ly + flat(r) * lx) * st.speed * sec + V(0, up * st.speed * 0.6 * sec, 0)
            c.raw = (c.raw or c.pos) + mv
            -- snapping, like one object: the set moves as one to where its nearest piece meets something
            local spos, guides, sh = nil, nil, nil
            local okS, p1, g1, h1 = pcall(S.carrySnap, c.raw, allowFree(lx ~= 0 or ly ~= 0, up ~= 0))
            if okS then spos, guides, sh = p1, g1, h1 end
            c.guides = guides
            if spos then c.pos, c.snapH = spos, sh else c.pos, c.snapH = FN.gridSnap(c.raw), nil end
        else
            c.raw = nil
        end
        local tstep = math.rad(st.deg)
        if padStep("lb", p.lb) then c.heading = wrap(round((c.snapH or c.heading) + tstep, tstep)); c.snapH = nil end
        if padStep("rb", p.rb) then c.heading = wrap(round((c.snapH or c.heading) - tstep, tstep)); c.snapH = nil end
        S.cam.goal = c.pos
        return
    end
    local fine = p.ls
    local t = S.target
    if S.grab and not (S.sel and S.sel.id == S.grab.id) then S.grab = nil end
    local holding = S.grab ~= nil
    if holding then S.bump = nil end
    if S.toolsWin then
        if not (S.sel and S.target) then S.toolsWin = nil else FN.toolsPad(p) end
    end

    if padPress("b", p.b) then
        if holding then FN.cancelGrab() else closeEditor() end
        return
    end
    if padPress("start", p.start) then
        S.stepSize = S.stepSize % #STEPS + 1
        say("Steps: " .. STEPS[S.stepSize].name)
    end
    -- L3 tapped while holding: what it snaps to (auto, each nearby object, off); held: Fine
    if p.ls and not S.l3At then S.l3At = S.clock end
    if not p.ls and S.l3At then
        if S.clock - S.l3At < 300 then
            if holding then FN.nextSnapObject() else FN.nextAimObject() end
        end
        S.l3At = nil
    end
    -- the step size chosen (Fine / Normal / Big); L3 held: Fine
    local st = STEPS[S.stepSize] or STEPS[2]
    if p.ls then st = STEPS[1] end
    if padPress("back", p.back) then
        -- View: snapping auto / one object / off; LB + View: undo; RB + View: redo
        if p.lb or p.rb then
            if holding and S.bumpTurn and S.target then S.target.heading = S.bumpTurn.h; S.dirty = true end
            S.bumpTurn = nil
            if holding then S.grab = nil; endHoldMove() end
            if p.rb then redo() else undo() end
            t = S.target; holding = false
        else
            FN.snapMode()
        end
    end
    if padPress("rs", p.rs) then
        -- holding: the copy tools; free: look at the picked object
        if holding then
            if S.toolsWin then S.toolsWin = nil else FN.openTools() end
        elseif t then
            S.cam.goal = t.pos
        end
    end
    if padPress("y", p.y) then
        -- holding: the held one (a group: all of it). Free, with objects selected: Y twice quickly removes every
        -- selected one; Y once on a selected one takes it out of the selection (held down: sweep to take more out).
        -- Free otherwise: Y twice removes the one under the cross.
        local yt = S.yTap
        if holding then
            FN.deletePress()
        elseif yt and S.clock - yt.at < 450 and groupCount() > 0 and (yt.sel or not S.aim or S.group[S.aim.id]) then
            -- the second Y: every selected object goes
            S.yTap, S.yHold = nil, nil
            if S.grab then S.grab = nil; endHoldMove() end
            local ids = {}
            for gid in pairs(S.group) do ids[#ids + 1] = gid end
            local rec = S.removeUndoable(ids, "Removed")
            S.group, S.gbase = {}, nil
            S.aim = nil
            say(string.format("Removing %d selected objects... (View: undo)", rec.total))
        elseif groupCount() > 0 and (not S.aim or S.group[S.aim.id]) then
            -- the first Y with a selection: wait a moment for a second one
            S.yTap = { at = S.clock, id = S.aim and S.aim.id or nil, sel = true }
            S.yHold = { n = 0, at = S.clock }
            say(string.format("Y again: remove all %d selected.%s", groupCount(), S.aim and "  (once: take this one out)" or ""))
        else
            FN.deletePress(S.aim)
        end
        t = S.target; holding = S.grab ~= nil
    end
    -- one Y on a selected object (no second one came): it leaves the selection
    if S.yTap and S.clock - S.yTap.at >= 450 then
        local yt = S.yTap
        S.yTap = nil
        if yt.id and S.group[yt.id] then
            S.group[yt.id] = nil
            S.gbase = nil
            if S.yHold then S.yHold.n += 1 end
        end
    end
    if S.yHold and not p.y and not S.yTap then
        if S.yHold.n > 0 then
            say(string.format("Taken out of the selection: %d.  %d left.", S.yHold.n, groupCount()))
        end
        S.yHold = nil
    end
    if padPress("a", p.a) then
        if holding then
            FN.placeGrab(); holding = false
        else
            -- not holding: a tap picks up (or opens the add window) when A comes up; held, it selects (below)
            S.aHold = { at = S.clock, first = S.aim and S.aim.id or nil, sweep = false, added = 0 }
        end
    end
    if S.aHold and not p.a then
        local ah = S.aHold
        S.aHold = nil
        if ah.sweep then
            local n = groupCount()
            say(string.format("Group: %d object%s.  A on one: move them all   LB: clear   RB: add / take out", n, n == 1 and "" or "s"))
        elseif not holding then
            local o = ah.first and S.known and S.known[ah.first]
            if o then
                -- the object under the cross: pick it up
                if not (S.sel and S.sel.id == o.id) then send(); select(o); t = S.target end
                startGrab(); holding = true
            else
                -- nothing under the cross: the add window, like Quick Drop's Add Object
                FN.openPicker()
                return
            end
        end
    end
    if padPress("x", p.x) then
        if holding then FN.copyHeld()
        elseif S.aim then FN.copyAimed(S.aim)
        else say("Aim the cross at an object, then X copies it.") end
    end
    if not holding then
        if padStep("left", p.left) then FN.pickNext(-1) t = S.target end
        if padStep("right", p.right) then FN.pickNext(1) t = S.target end
        -- the group: RB puts the object under the cross in (or takes it out), LB clears it
        -- (on letting go, and only when no other button went with it: LB + View is undo, RB + View redo)
        for _, k in ipairs({ "lb", "rb" }) do
            S.bump = S.bump or {}
            if p[k] and not S.bump[k] then S.bump[k] = { used = false, aim = S.aim } end
            if p[k] and S.bump[k] and (p.back or p.a or p.x or p.y or p.right or p.left or p.up or p.down or p.lb and p.rb) then S.bump[k].used = true end
            if not p[k] and S.bump[k] then
                local b = S.bump[k]
                S.bump[k] = nil
                if not b.used then
                    if k == "rb" then FN.toggleGroup(b.aim or S.aim) else FN.clearGroup() end
                end
            end
        end
    elseif not S.toolsWin then
        -- holding: D-pad right zooms in, left zooms out (like the mouse wheel)
        if p.right then S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (1 - 1.5 * sec), 0.5, 300) end
        if p.left then S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (1 + 1.5 * sec), 0.5, 300) end
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
        local sp = math.max(S.cam.dist, 3) * st.fly * sec
        if lx ~= 0 or ly ~= 0 or up ~= 0 then
            S.cam.goal = (S.cam.goal or S.cam.target) + (ff * ly + rr * lx) * sp + V(0, up * sp * 0.6, 0)
        end
        if p.up then S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (1 - 1.5 * sec), 0.5, 300) end
        if p.down then S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (1 + 1.5 * sec), 0.5, 300) end
        -- what A would pick up
        S.aim = FN.aimedObject()
        if S.aimLock then
            local o = S.known and S.known[S.aimLock]
            if o and S.clock - (S.aimLockAt or 0) < 6000 and lx == 0 and ly == 0 and up == 0 then S.aim = o else S.aimLock = nil end
        end
        -- A held down: every object the cross passes over goes in the group
        local ah = S.aHold
        if ah and p.a and not ah.sweep and S.clock - ah.at > 300 then
            ah.sweep = true
            if ah.first and S.known and S.known[ah.first] and not S.group[ah.first] then S.group[ah.first] = true; ah.added += 1; S.gbase = nil end
            say("Selecting: move the cross over objects, let go of A when done.")
        end
        -- Y held (started on a group member): every member the cross passes over leaves the group
        if S.yHold and p.y and S.clock - (S.yHold.at or 0) > 300 and S.aim and S.group[S.aim.id] then
            S.group[S.aim.id] = nil
            S.gbase = nil
            S.yHold.n += 1
        end
        if ah and ah.sweep and S.aim and not S.group[S.aim.id] then
            S.group[S.aim.id] = true
            ah.added += 1
            S.gbase = nil
            if reskate.audio and reskate.audio.play_ui then pcall(reskate.audio.play_ui, "navigate") end
        end
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
        local step = st.m
        local function nudge(key, on, v)
            if padStep(key, on) then begin(); t.pos += v * step; S.cam.goal = (S.cam.goal or S.cam.target) + v * step end
        end
        nudge("fwd", p.ly > 0.5, ff); nudge("back_", p.ly < -0.5, ff * -1)
        nudge("rgt", p.lx > 0.5, rr); nudge("lft", p.lx < -0.5, rr * -1)
        nudge("rise", up > 0.5, V(0, 1, 0)); nudge("fall", up < -0.5, V(0, -1, 0))
        if p.ly > 0.5 or p.ly < -0.5 or p.lx > 0.5 or p.lx < -0.5 or math.abs(up) > 0.5 then active = true end
    elseif lx ~= 0 or ly ~= 0 or up ~= 0 then
        begin()
        local sp = st.speed * sec
        local mv = (ff * ly + rr * lx) * sp + V(0, up * st.speed * 0.6 * sec, 0)
        -- where the stick has taken it, and from that where it snaps to: the stick can always pull it free again
        if not S.padRaw then
            S.padHd0 = t.heading
            local tl0 = S.tilt[S.sel.id]
            S.padTilt0 = tl0 and { x = tl0.x, z = tl0.z } or nil
        end
        S.padRaw = (S.padRaw or t.pos) + mv
        if S.landOn and up == 0 and (lx ~= 0 or ly ~= 0) and not tilted(S.sel.id) then
            if S.clock - (S.landAt or -1e9) > 70 then
                S.landAt = S.clock
                local okL, y = pcall(FN.supportY, S.sel.item, S.padRaw, S.padHd0 or t.heading, t.scale, S.sel.id)
                S.landY = okL and y or nil
            end
            if S.landY then S.padRaw = V(S.padRaw.x, S.landY, S.padRaw.z) end
        else
            S.landY = nil
        end
        local ntl
        t.pos, t.heading, S.guides, ntl = snapTurned(S.padRaw, S.padHd0 or t.heading, t.scale, allowFree(lx ~= 0 or ly ~= 0, up ~= 0), S.padTilt0)
        t.pos = FN.gridSnap(t.pos, S.guides)
        S.tilt[S.sel.id] = ntl
        S.cam.goal = (S.cam.goal or S.cam.target) + mv
        S.cam.target += mv
    else
        if S.padRaw then armTighten(S.guides); S.guides = nil; S.snapLock = nil end
        S.padRaw = nil
    end

    -- turn: bumpers, by the step size (Fine 1°, Normal 15°, Big 45°)
    local tstep = math.rad(st.deg)
    -- (the turn a bumper made is taken back if View follows: LB + View is undo, RB + View redo)
    if (p.lb or p.rb) and not S.bumpTurn then S.bumpTurn = { h = t.heading, at = S.clock } end
    if not (p.lb or p.rb) then S.bumpTurn = nil end
    if padStep("lb", p.lb) then begin(); t.heading = wrap(round(t.heading + tstep, tstep)) end
    if padStep("rb", p.rb) then begin(); t.heading = wrap(round(t.heading - tstep, tstep)) end
    if p.lb or p.rb then active = true end
    if (p.lb or p.rb) and S.padRaw then S.padHd0 = t.heading end

    -- size: D-pad up / down, by the step size
    local sstep = st.size
    if not S.toolsWin then
        if padStep("up", p.up) then begin(); t.scale = clamp(round(t.scale + sstep, sstep), 0.1, 10) end
        if padStep("down", p.down) then begin(); t.scale = clamp(round(t.scale - sstep, sstep), 0.1, 10) end
        if p.up or p.down then active = true end
    end

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
        local okc, errc = pcall(FN.copyTick)
        if not okc then S.copyQ = nil; reskate.log("Quick Drop helper: copy: " .. tostring(errc), "warn") end
    end
    do
        local okg, errg = pcall(function() FN.followTick(); FN.sendGroup(); FN.qTick() end)
        if not okg then
            if #S.q > 0 then table.remove(S.q, 1) end
            if not S.groupWarned then S.groupWarned = true; reskate.log("Quick Drop helper: group: " .. tostring(errg), "warn") end
        end
    end
    do
        local ok, err = pcall(FN.tiltTick)
        if not ok and not S.tiltWarned then S.tiltWarned = true; reskate.log("Quick Drop helper: tilt: " .. tostring(err), "warn") end
    end

    if not S.open then
        -- the controller: hold LB and press D-pad right to open the editor
        local pd = FN.readPad()
        if pd then
            local rightNow = pd.right == true
            if pd.lb and rightNow and not S.padOpenRight and S.clock - (S.closedAt or -1e9) > 400 then
                S.padOpenRight = true
                FN.openEditor()
                return
            end
            S.padOpenRight = rightNow
        end
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
            for _, k in ipairs({ "[", "]", "PageUp", "PageDown", "X", "Z", "Up", "Down", "Right", "Left", "U" }) do S.tiltHeld[k] = false end
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
    if press("Tab") and S.sel then FN.cycleSnap() end
    if press("F") and S.target then S.cam.goal = S.target.pos end
    if press("Z") and ctrl then if reskate.input.key("Shift") then redo() else undo() end end
    if press("Y") and ctrl then redo() end
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
        ok, err = pcall(FN.stepTighten)
        if not ok then S.tighten = nil; if not S.tightWarned then S.tightWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(err), "warn") end end
    end
    do
        local ok, err = pcall(FN.padEditor, sec)
        if not ok then reskate.log("Quick Drop helper: controller: " .. tostring(err), "warn") end
        if not S.open then return end
    end

    -- the mouse
    local c = reskate.input.cursor()
    if c and ((S.mouse.pos and d2(c.position, S.mouse.pos) > 3) or c.left or c.right or (c.wheel and c.wheel ~= 0)) then S.mouseUsedAt = S.clock end
    if c and S.controlsOpen then
        pcall(UI.controlsMouse, c)
        S.mouse = { pos = c.position, left = c.left }
        c = nil
    end
    if c and S.ownPanel and not S.picker and not S.drag then
        local okp, used = pcall(UI.panelMouse, c)
        if okp and used then
            S.mouse = { pos = c.position, left = c.left }
            S.hover = nil
            c = nil
        end
    end
    if c and S.toolsWin and not S.drag and not c.over_screen then
        local okt, used = pcall(FN.toolsMouse, c)
        if okt and used then
            S.mouse = { pos = c.position, left = c.left }
            c = nil
        end
    end
    if c and S.picker then
        pcall(FN.pickerMouse, c)
        S.mouse = { pos = c.position, left = c.left }
        c = nil
    end
    if c then
        local px = c.position
        local last = S.mouse.pos or px
        if (S.mouse.pos and d2(px, S.mouse.pos) > 3) or c.left or c.right or (c.wheel and c.wheel ~= 0) then S.mouseUsedAt = S.clock end
        local dx, dy = px.x - last.x, px.y - last.y
        if c.wheel and c.wheel ~= 0 and not c.over_screen then
            S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (0.85 ^ c.wheel), 0.5, 300)
        end
        S.hover = (not S.drag and not c.over_screen) and FN.handleAt(px) or nil
        if c.left and not S.mouse.left and not c.over_screen then
            local h = FN.handleAt(px)
            if h then
                markUndo()
                local t = S.target
                local tl0 = S.tilt[S.sel.id]
                h.start = { pos = t.pos, heading = t.heading, scale = t.scale, px = px, tilt = tl0 and { x = tl0.x, z = tl0.z } or nil }
                if S.group[S.sel.id] then groupBase() else S.gbase = nil end
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
                        if S.landOn and math.abs(g.n.y) > 0.9 and not tilted(S.sel.id) then
                            local okL, y = pcall(FN.supportY, S.sel.item, t.pos, g.start.heading, t.scale, S.sel.id)
                            if okL and y then t.pos = V(t.pos.x, y, t.pos.z) end
                        end
                        local ntl
                        if toObjects then t.pos, t.heading, S.guides, ntl = snapTurned(t.pos, g.start.heading, t.scale, allowIn(g.n), g.start.tilt) else t.heading, ntl = g.start.heading, g.start.tilt end
                        if math.abs(g.n.y) > 0.9 then t.pos = FN.gridSnap(t.pos, S.guides) end
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
                        if toObjects then hd, S.guides = FN.turnTo(hd) end
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
            if S.drag.kind == "click" then FN.clickPick(px, reskate.input.key("Ctrl")) end
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

function UI.drawPadHud(d)
    local W, H = S.size.x, S.size.y
    local c = V(W / 2, H / 2, 0)
    local ng = groupCount()
    local selecting = S.aHold and S.aHold.sweep
    -- the cross
    if not S.grab then
        local col = selecting and UI.purple or (S.aim and UI.accent or "#ffffffd0")
        d:circle(c, 3, { colour = col, fill = true })
        d:circle(c, 13, { colour = col, thickness = 2 })
        if S.aim then
            local so = placedSolid(S.aim)
            drawShape(d, so.shape or so, S.group[S.aim.id] and UI.purple or "#ffffff", 3, so.xf)
            local name = titleOf(S.aim.item)
            local w = UI.textW(d, name, 15) + 22
            d:rect(V(c.x - w / 2, c.y + 24, 0), V(c.x + w / 2, c.y + 50, 0), { colour = UI.bg, fill = true, rounding = 13 })
            d:text(V(c.x, c.y + 28, 0), name, { size = 15, colour = UI.text, align = "centre" })
        end
    end
    -- what is set, along the top
    local chips = {}
    if selecting then chips[#chips + 1] = { string.format("Selecting  %d", ng), UI.purple }
    elseif ng > 0 then chips[#chips + 1] = { string.format("Group  %d", ng), UI.purple } end
    chips[#chips + 1] = { "Steps  " .. (STEPS[S.stepSize] or STEPS[2]).name, UI.accent }
    if S.grab then chips[#chips + 1] = { "Snap  " .. FN.snapLabel(), S.snapPick and UI.orange or "#35e0ff" } end
    if FN.gridSize() > 0 then chips[#chips + 1] = { "Grid  " .. FN.GRID_NAMES[S.gridI], UI.green } end
    local tot = 0
    for _, ch in ipairs(chips) do tot += UI.chipW(d, ch[1]) + 8 end
    local x = W / 2 - (tot - 8) / 2
    for _, ch in ipairs(chips) do x += UI.chip(d, x, 24, ch[1], ch[2]) + 8 end
    -- the last message, above the prompts
    if S.msg ~= "" and S.clock < S.msgUntil then
        local msg = S.msg
        if #msg > 90 then msg = string.sub(msg, 1, 88) .. "…" end
        local w = UI.textW(d, msg, 15) + 28
        d:rect(V(W / 2 - w / 2, H - 112, 0), V(W / 2 + w / 2, H - 84, 0), { colour = "#0d1117b0", fill = true, rounding = 14 })
        d:text(V(W / 2, H - 107, 0), msg, { size = 15, colour = UI.dim, align = "centre" })
    end
    -- the buttons for what can be done now
    local items
    if S.toolsWin then
        items = nil
    elseif selecting then
        items = { { "a", "Let go: done" } }
    elseif S.grab then
        items = { { "a", "Put down" }, { "b", "Cancel" }, { "x", "Copy" }, { "LB RB", "Turn" }, { "D-pad L R", "Zoom" }, { "R3", "Copy tools" }, { "View L3", "Snap" } }
    elseif S.aim and S.group[S.aim.id] then
        items = { { "a", "Pick up all" }, { "x", "Copy all" }, { "y", "Take out  ·  twice: delete all" }, { "LB", "Clear group" } }
    elseif S.aim then
        items = { { "a", "Pick up" }, { "Hold A", "Select" }, { "x", "Copy" }, { "y", "Remove" }, { "RB", "Group" } }
    else
        items = { { "a", "Add object" }, { "Hold A", "Select" }, { "Menu", "Steps" }, { "b", "Close" } }
    end
    if items then UI.promptRow(d, W / 2, H - 48, items) end
end

-- an outline as it stands: round its base, round its top, and up its corners
FN.COS25 = math.cos(math.rad(25))
drawShape = function(d, sh, col, th, xf)
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
        if n <= 8 or dot(norm(b - a), norm(c - b)) < FN.COS25 then
            d:world_line(xf(b + base), xf(b + base + up), { colour = col, thickness = th })
        end
    end
    return true
end


-- ---------------------------------------------------------------- the panel on the right, drawn over the view
-- (a screen without ReSkate's own panel: everything here is drawn, and clicks on it are kept from the view)
-- (in a function of its own: its many locals don't count against the file's limit)
;(function()
    local PW = 384
    local tiles = {}
    local function hot(a, b)
        local m = S.mouse and S.mouse.pos
        return m ~= nil and m.x >= a.x and m.x <= b.x and m.y >= a.y and m.y <= b.y
    end
    local function tileAdd(a, b, fn) tiles[#tiles + 1] = { a = a, b = b, fn = fn } end
    local function btn(d, a, b, label, fn, style)
        local h = hot(a, b)
        local col = style == "primary" and (h and "#ffe27a" or UI.accent) or (style == "on" and (h and "#ffffff40" or "#ffffff33") or (h and UI.tileHot or UI.tile))
        d:rect(a, b, { colour = col, fill = true, rounding = 9 })
        if style == "on" then d:rect(a, b, { colour = UI.accent, rounding = 9, thickness = 2 }) end
        d:text(V((a.x + b.x) / 2, (a.y + b.y) / 2 - 9, 0), label, { size = 15, colour = style == "primary" and "#0d1117" or UI.text, font = (style == "primary" or style == "on") and "bold" or nil, align = "centre" })
        if fn then tileAdd(a, b, fn) end
    end
    -- a row of choices, one of them on
    local function seg(d, x, y, w, labels, cur, fn)
        local n = #labels
        d:rect(V(x, y, 0), V(x + w, y + 34, 0), { colour = "#00000040", fill = true, rounding = 10 })
        local cw = (w - 4) / n
        for i, l in ipairs(labels) do
            local a, b = V(x + 2 + (i - 1) * cw, y + 2, 0), V(x + 2 + i * cw, y + 32, 0)
            local on = i == cur
            local h = hot(a, b)
            if on then d:rect(a, b, { colour = UI.accent, fill = true, rounding = 8 })
            elseif h then d:rect(a, b, { colour = UI.tile, fill = true, rounding = 8 }) end
            d:text(V((a.x + b.x) / 2, y + 8, 0), l, { size = 14, colour = on and "#0d1117" or UI.dim, font = on and "bold" or nil, align = "centre" })
            tileAdd(a, b, function() fn(i) end)
        end
        return y + 34
    end
    local function switch(d, x, y, w, label, on, fn)
        local a, b = V(x, y, 0), V(x + w, y + 34, 0)
        if hot(a, b) then d:rect(a, b, { colour = UI.tile, fill = true, rounding = 9 }) end
        d:text(V(x + 10, y + 8, 0), label, { size = 15, colour = UI.text })
        local sx = x + w - 52
        d:rect(V(sx, y + 7, 0), V(sx + 40, y + 27, 0), { colour = on and UI.accent or "#ffffff2a", fill = true, rounding = 10 })
        d:circle(V(on and sx + 30 or sx + 10, y + 17, 0), 8, { colour = on and "#0d1117" or "#e6e9ef", fill = true })
        tileAdd(a, b, fn)
        return y + 34
    end
    -- label   [-]  value  [+]   (click the value to type it)
    local function stepRow(d, x, y, w, label, value, dec, inc, edit)
        d:text(V(x + 4, y + 8, 0), label, { size = 14, colour = UI.dim })
        local bx = x + w - 196
        local m1a, m1b = V(bx, y + 2, 0), V(bx + 30, y + 30, 0)
        local va, vb = V(bx + 34, y + 2, 0), V(bx + 162, y + 30, 0)
        local p1a, p1b = V(bx + 166, y + 2, 0), V(bx + 196, y + 30, 0)
        d:rect(m1a, m1b, { colour = hot(m1a, m1b) and UI.tileHot or UI.tile, fill = true, rounding = 7 })
        d:text(V(bx + 15, y + 5, 0), "-", { size = 18, colour = UI.text, align = "centre" })
        d:rect(va, vb, { colour = hot(va, vb) and "#ffffff1c" or "#00000040", fill = true, rounding = 7 })
        d:text(V((va.x + vb.x) / 2, y + 7, 0), value, { size = 15, colour = UI.text, align = "centre" })
        d:rect(p1a, p1b, { colour = hot(p1a, p1b) and UI.tileHot or UI.tile, fill = true, rounding = 7 })
        d:text(V(bx + 181, y + 5, 0), "+", { size = 18, colour = UI.text, align = "centre" })
        tileAdd(m1a, m1b, dec); tileAdd(p1a, p1b, inc); tileAdd(va, vb, edit)
        return y + 34
    end
    local function label(d, x, y, str)
        d:text(V(x + 2, y, 0), string.upper(str), { size = 12, colour = "#f0f3f670", font = "bold" })
        return y + 20
    end

    -- typing one number: a text box; "+2" adds 2
    local TYPE1 = "ddh_type1"
    local function typeOne(title, cur, fmtS, apply)
        S.typeOne = { apply = apply, cur = cur }
        local ok, why = pcall(reskate.ui.dialog, TYPE1, {
            title = title, message = "Type a number, then Enter. Start with + to add to it (+2, +-0.5).",
            field = { text = string.format(fmtS, cur), max = 40 },
            buttons = { { id = "apply", label = "Apply" }, { id = "close", label = "Cancel" } },
        })
        if not ok or why == false then S.typeOne = nil; say("Could not open the text box", true) else S.typing = true end
    end
    UI.typeOne = typeOne
    reskate.on("throwdown_ui", function(e)
        if e.action ~= "dialog" or e.args[1] ~= TYPE1 then return end
        local what = e.args[2]
        if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
        S.typing = false
        if what ~= "cancel" then pcall(reskate.ui.close_dialog, TYPE1) end
        local tw = S.typeOne
        S.typeOne = nil
        if what ~= "apply" or not tw then return end
        local str = string.gsub(tostring(e.args[3] or ""), ",", ".")
        str = string.gsub(str, "^%s+", ""):gsub("%s+$", ""):gsub("[m°x×]+$", "")
        local v
        if string.sub(str, 1, 1) == "+" then v = tonumber(string.sub(str, 2)); if v then v = tw.cur + v end else v = tonumber(str) end
        if v == nil then say("Not a number: " .. str, true) return end
        tw.apply(v)
    end)

    local TABS = { "Edit", "Snap", "Park", "Sets" }
    function UI.sidePanel(d)
        tiles = {}
        local W, H = S.size.x, S.size.y
        local a = V(W - PW - 14, 14, 0)
        local b = V(W - 14, H - 14, 0)
        S.screen.panelBox = { a = a, b = b }
        d:rect(a + V(0, 4, 0), b + V(0, 4, 0), { colour = "#00000055", fill = true, rounding = 16 })
        d:rect(a, b, { colour = UI.bg2, fill = true, rounding = 16 })
        local x, w = a.x + 16, PW - 32
        local y = a.y + 16
        -- title and Done
        d:text(V(x, y, 0), "DDH Park Editor", { size = 22, colour = UI.text, font = "heading" })
        d:text(V(x, y + 27, 0), "Quick Drop+", { size = 13, colour = UI.dim })
        btn(d, V(b.x - 16 - 86, y + 2, 0), V(b.x - 16, y + 34, 0), "Done", function() closeEditor() end)
        y += 54
        -- what is picked
        local t = S.sel and S.target
        local ng = groupCount()
        d:rect(V(x, y, 0), V(x + w, y + 64, 0), { colour = "#ffffff0c", fill = true, rounding = 12 })
        local title, sub, dot = "Nothing picked", "Click an object, or aim the cross and press A", "#ffffff40"
        if t then
            title = titleOf(S.sel.item)
            sub = string.format("%.0f°   ·   size %.2f", math.deg(t.heading), t.scale)
            dot = UI.accent
            if S.group[S.sel.id] and ng > 1 then sub = sub .. string.format("   ·   group of %d", ng); dot = UI.purple end
        elseif ng > 0 then
            title, sub, dot = string.format("Group of %d", ng), "Pick one of them up to move them all", UI.purple
        end
        if #title > 30 then title = string.sub(title, 1, 29) .. "…" end
        d:circle(V(x + 18, y + 22, 0), 5, { colour = dot, fill = true })
        d:text(V(x + 32, y + 11, 0), title, { size = 17, colour = UI.text, font = "bold" })
        d:text(V(x + 32, y + 36, 0), sub, { size = 13, colour = UI.dim })
        y += 76
        -- warnings and the last message
        local miss = S.missing or {}
        if S.blocked or #miss > 0 then
            d:rect(V(x, y, 0), V(x + w, y + 30, 0), { colour = "#f8514933", fill = true, rounding = 9 })
            d:text(V(x + 12, y + 7, 0), string.format("Park locked: %d from a missing mod (see Park)", #miss), { size = 13, colour = "#ffb3ad" })
            y += 38
        end
        -- the everyday buttons
        local bw = (w - 18) / 4
        btn(d, V(x, y, 0), V(x + bw, y + 36, 0), "+ Add", function() if S.openPicker then S.openPicker() end end, "primary")
        btn(d, V(x + bw + 6, y, 0), V(x + 2 * bw + 6, y + 36, 0), "Undo", function() undo() end)
        btn(d, V(x + 2 * bw + 12, y, 0), V(x + 3 * bw + 12, y + 36, 0), "Redo", function() if S.redoFn then S.redoFn() end end)
        btn(d, V(x + 3 * bw + 18, y, 0), V(x + w, y + 36, 0), "Controls", function() S.controlsOpen = true end)
        y += 48
        -- tabs
        S.ptab = S.ptab or 1
        if S.ptab > #TABS then S.ptab = 1 end
        local tw = w / #TABS
        for i, n in ipairs(TABS) do
            local ta, tb = V(x + (i - 1) * tw, y, 0), V(x + i * tw, y + 34, 0)
            local on = i == S.ptab
            d:text(V((ta.x + tb.x) / 2, y + 7, 0), n, { size = 16, colour = on and UI.text or UI.dim, font = on and "bold" or nil, align = "centre" })
            d:rect(V(ta.x + 6, y + 31, 0), V(tb.x - 6, y + 34, 0), { colour = on and UI.accent or "#ffffff14", fill = true, rounding = 2 })
            tileAdd(ta, tb, function() S.ptab = i end)
        end
        y += 48
        local st = STEPS[S.stepSize] or STEPS[2]
        if S.ptab == 1 then
            if not t then
                d:text(V(x + 4, y, 0), "Pick an object to change it here.", { size = 14, colour = UI.dim })
                y += 30
            else
                y = label(d, x, y, "Handles")
                y = seg(d, x, y, w, { "Move", "Turn", "Size" }, S.mode, function(i) S.mode = i end) + 14
                y = label(d, x, y, "Position")
                local function setP(px, py, pz) markUndo(); t.pos = V(px, py, pz); S.dirty = true end
                y = stepRow(d, x, y, w, "X", string.format("%.3f", t.pos.x), function() setP(t.pos.x - st.m, t.pos.y, t.pos.z) end, function() setP(t.pos.x + st.m, t.pos.y, t.pos.z) end,
                    function() typeOne("X", t.pos.x, "%.3f", function(v) setP(v, t.pos.y, t.pos.z) end) end) + 4
                y = stepRow(d, x, y, w, "Height", string.format("%.3f", t.pos.y), function() setP(t.pos.x, t.pos.y - st.m, t.pos.z) end, function() setP(t.pos.x, t.pos.y + st.m, t.pos.z) end,
                    function() typeOne("Height", t.pos.y, "%.3f", function(v) setP(t.pos.x, v, t.pos.z) end) end) + 4
                y = stepRow(d, x, y, w, "Z", string.format("%.3f", t.pos.z), function() setP(t.pos.x, t.pos.y, t.pos.z - st.m) end, function() setP(t.pos.x, t.pos.y, t.pos.z + st.m) end,
                    function() typeOne("Z", t.pos.z, "%.3f", function(v) setP(t.pos.x, t.pos.y, v) end) end) + 12
                y = label(d, x, y, "Turn, size, tilt")
                local function setH(v) markUndo(); t.heading = wrap(v); S.dirty = true end
                local function setS(v) markUndo(); t.scale = clamp(v, 0.1, 10); S.dirty = true end
                y = stepRow(d, x, y, w, "Turn", string.format("%.1f°", math.deg(t.heading)), function() setH(t.heading + math.rad(st.deg)) end, function() setH(t.heading - math.rad(st.deg)) end,
                    function() typeOne("Turn (degrees)", math.deg(t.heading), "%.1f", function(v) setH(math.rad(v)) end) end) + 4
                y = stepRow(d, x, y, w, "Size", string.format("%.2f×", t.scale), function() setS(t.scale - st.size) end, function() setS(t.scale + st.size) end,
                    function() typeOne("Size", t.scale, "%.2f", setS) end) + 4
                local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
                local function setT(tx, tz) markUndo(); S.tilt[S.sel.id] = (math.abs(tx) < 1e-6 and math.abs(tz) < 1e-6) and nil or { x = wrap(tx), z = wrap(tz) }; S.tiltSaveDue = true end
                local dd = math.rad(st.deg)
                y = stepRow(d, x, y, w, "Tilt forward", string.format("%.1f°", math.deg(tl.x)), function() setT(tl.x - dd, tl.z) end, function() setT(tl.x + dd, tl.z) end,
                    function() typeOne("Tilt forward (degrees)", math.deg(tl.x), "%.1f", function(v) setT(math.rad(v), tl.z) end) end) + 4
                y = stepRow(d, x, y, w, "Tilt sideways", string.format("%.1f°", math.deg(tl.z)), function() setT(tl.x, tl.z - dd) end, function() setT(tl.x, tl.z + dd) end,
                    function() typeOne("Tilt sideways (degrees)", math.deg(tl.z), "%.1f", function(v) setT(tl.x, math.rad(v)) end) end) + 10
                if tilted(S.sel.id) and S.tiltWhy and not S.tiltHeld[S.sel.id] then
                    d:text(V(x + 4, y, 0), "Tilt waits: " .. S.tiltWhy, { size = 13, colour = UI.orange }); y += 22
                end
                local qw = (w - 16) / 3
                btn(d, V(x, y, 0), V(x + qw, y + 34, 0), "Straighten", function() markUndo(); t.heading = round(t.heading, math.pi / 2); if S.tilt[S.sel.id] then S.tilt[S.sel.id] = nil; S.tiltSaveDue = true end; S.dirty = true end)
                btn(d, V(x + qw + 8, y, 0), V(x + 2 * qw + 8, y + 34, 0), "Size 1", function() markUndo(); t.scale = 1; S.dirty = true end)
                btn(d, V(x + 2 * qw + 16, y, 0), V(x + w, y + 34, 0), "Look at it", function() S.cam.goal = t.pos end)
                y += 48
            end
            y = label(d, x, y, "Step size")
            y = seg(d, x, y, w, { "Fine", "Normal", "Big" }, S.stepSize, function(i) S.stepSize = i end) + 6
            d:text(V(x + 4, y, 0), string.format("%s m  ·  %s  ·  size %s", string.format("%.2f", st.m), string.format(st.df, st.deg), string.format("%.2f", st.size)), { size = 13, colour = UI.dim })
        elseif S.ptab == 2 then
            y = switch(d, x, y, w, "Snap to objects   (T)", S.osnap, function() S.osnap = not S.osnap end) + 10
            if S.osnap then
                y = label(d, x, y, "Snapping to:  " .. FN.snapLabelP())
                local cur = S.snapPick == nil and 1 or (S.snapPick == "off" and 3 or 2)
                y = seg(d, x, y, w, { "Auto", "Next object", "Off" }, cur, function(i)
                    if i == 1 then S.snapPick = nil; S.snapLock = nil
                    elseif i == 2 and S.nextSnap then S.nextSnap()
                    elseif i == 3 then S.snapPick = "off"; S.guides = nil end
                end) + 6
                d:text(V(x + 4, y, 0), "Tab, or tap L3 while holding, switches it.", { size = 13, colour = UI.dim })
                y += 30
            end
            y = label(d, x, y, "Grid")
            y = seg(d, x, y, w, FN.GRID_NAMES_P, S.gridI or 1, function(i) S.gridI = i end) + 14
            y = switch(d, x, y, w, "Drag in steps   (G)", S.snap, function() S.snap = not S.snap end) + 8
            y = switch(d, x, y, w, "Land on what is under it", S.landOn, function() S.landOn = not S.landOn end)
        elseif S.ptab == 4 then
            -- ---------------------------------------------------------------- sets
            local nm = #(S.setMembers and S.setMembers() or {})
            d:text(V(x + 4, y, 0), nm > 0 and string.format("Saves the %s (%d object%s)", nm > 1 and "group" or "picked object", nm, nm == 1 and "" or "s")
                or "Pick an object or make a group,", { size = 13, colour = UI.dim })
            d:text(V(x + 4, y + 18, 0), nm > 0 and "to place again on any map or server." or "then save it here.", { size = 13, colour = UI.dim })
            y += 42
            btn(d, V(x, y, 0), V(x + w, y + 38, 0), nm > 0 and string.format("Save as a set  (%d)", nm) or "Save as a set", function()
                if nm == 0 then say("Pick an object or make a group first.", true) return end
                local ok = pcall(reskate.ui.dialog, "ddh_setname", { title = "Save as a set", message = "A name for it (letters, numbers, spaces).", field = { text = "My set", max = 40 },
                    buttons = { { id = "apply", label = "Save" }, { id = "close", label = "Cancel" } } })
                if ok then S.typing = true end
            end, nm > 0 and "primary" or nil)
            y += 52
            if not S.sets or S.clock - (S.setsAt or -1e9) > 5000 then S.loadSets() end
            y = label(d, x, y, string.format("Saved sets  ·  %d", #S.sets))
            if #S.sets == 0 then
                d:text(V(x + 4, y, 0), "None yet.", { size = 14, colour = UI.dim }); y += 26
            end
            local rowH = 76
            local maxRows = math.max(2, math.floor((b.y - 120 - y) / rowH))
            for i, set in ipairs(S.sets) do
                if i > maxRows then
                    d:text(V(x + 4, y, 0), string.format("+%d more (in Add object > Sets)", #S.sets - maxRows), { size = 13, colour = UI.dim }); y += 24
                    break
                end
                local ra, rb = V(x, y, 0), V(x + w, y + rowH - 6, 0)
                d:rect(ra, rb, { colour = UI.tile, fill = true, rounding = 9 })
                -- its layout from above
                local pa, pb2 = V(x + 6, y + 6, 0), V(x + 58, y + 34, 0)
                d:rect(pa, pb2, { colour = "#00000040", fill = true, rounding = 6 })
                pcall(UI.drawSetPreview, d, set, pa + V(3, 3, 0), pb2 - V(3, 3, 0), UI.purple)
                local nmS = set.name
                if #nmS > 22 then nmS = string.sub(nmS, 1, 21) .. "…" end
                d:text(V(x + 66, y + 5, 0), nmS, { size = 15, colour = UI.text, font = "bold" })
                d:text(V(x + 66, y + 23, 0), string.format("%d objects", #set.objects), { size = 12, colour = UI.dim })
                local by = y + 38
                local bw4 = (w - 12 - 18) / 4
                local bx = x + 6
                btn(d, V(bx, by, 0), V(bx + bw4, by + 28, 0), "Place", function() S.carrySet(set, FN.crossPoint(), wrap(S.cam.yaw + math.pi)) end, "primary")
                btn(d, V(bx + bw4 + 6, by, 0), V(bx + 2 * bw4 + 6, by + 28, 0), "Rename", function()
                    S.renameSet = set
                    local ok = pcall(reskate.ui.dialog, "ddh_setrename", { title = "Rename set", message = "A new name.", field = { text = set.name, max = 40 },
                        buttons = { { id = "apply", label = "Rename" }, { id = "close", label = "Cancel" } } })
                    if ok then S.typing = true end
                end)
                btn(d, V(bx + 2 * bw4 + 12, by, 0), V(bx + 3 * bw4 + 12, by + 28, 0), "Update", function()
                    if S.updSetAsk == set.file and S.clock - (S.updSetAt or 0) < 3000 then
                        S.updSetAsk = nil
                        S.saveSet(set.name)
                    else
                        local nm2 = #(S.setMembers and S.setMembers() or {})
                        if nm2 == 0 then say("Pick an object or make a group first: Update saves it over this set.", true) return end
                        S.updSetAsk, S.updSetAt = set.file, S.clock
                        say(string.format("Click Update again to save the %d selected over \"%s\".", nm2, set.name))
                    end
                end)
                btn(d, V(bx + 3 * bw4 + 18, by, 0), V(rb.x - 6, by + 28, 0), "Delete", function()
                    if S.delSetAsk == set.file and S.clock - (S.delSetAt or 0) < 3000 then S.delSetAsk = nil; S.deleteSet(set)
                    else S.delSetAsk, S.delSetAt = set.file, S.clock; say("Click Delete again to delete \"" .. set.name .. "\".") end
                end)
                y += rowH
            end
            local pb = b.y - 56
            btn(d, V(x, pb, 0), V(x + w, pb + 34, 0), "Open the sets folder  (to share them)", function() S.openSetsFolder() end)
        else
            y = label(d, x, y, ng > 0 and string.format("Group  ·  %d objects", ng) or "Group")
            local gw = (w - 8) / 2
            btn(d, V(x, y, 0), V(x + gw, y + 34, 0), "Add / remove picked", function() if S.sel and S.known and S.known[S.sel.id] and S.toggleGroup then S.toggleGroup(S.known[S.sel.id]) end end)
            btn(d, V(x + gw + 8, y, 0), V(x + w, y + 34, 0), "Clear group", function() if S.clearGroup then S.clearGroup() end end)
            y += 42
            btn(d, V(x, y, 0), V(x + w, y + 34, 0), "Copy tools   (row, circle, grid)", function() if S.openTools then S.openTools() end end)
            y += 46
            y = label(d, x, y, "Arrange the group")
            local aw = (w - 8) / 2
            btn(d, V(x, y, 0), V(x + aw, y + 30, 0), "Mirror left / right", function() S.arrange("mirrorX") end)
            btn(d, V(x + aw + 8, y, 0), V(x + w, y + 30, 0), "Mirror front / back", function() S.arrange("mirrorZ") end)
            y += 36
            local a3 = (w - 12) / 3
            btn(d, V(x, y, 0), V(x + a3, y + 30, 0), "Line up", function() S.arrange("lineup") end)
            btn(d, V(x + a3 + 6, y, 0), V(x + 2 * a3 + 6, y + 30, 0), "Space evenly", function() S.arrange("space") end)
            btn(d, V(x + 2 * a3 + 12, y, 0), V(x + w, y + 30, 0), "Same height", function() S.arrange("level") end)
            y += 50
            FN.rebuildList()
            y = label(d, x, y, string.format("Objects in this park  ·  %d", S.listMatched or 0))
            local sa, sb = V(x, y, 0), V(x + w, y + 32, 0)
            d:rect(sa, sb, { colour = hot(sa, sb) and "#ffffff1c" or "#00000040", fill = true, rounding = 8 })
            d:text(V(x + 12, y + 7, 0), S.search ~= "" and ("Search:  " .. S.search) or "Search…", { size = 14, colour = S.search ~= "" and UI.text or UI.dim })
            tileAdd(sa, sb, function()
                S.typeSearch = true
                local ok = pcall(reskate.ui.dialog, "ddh_search", { title = "Search objects", message = "Part of a name (empty: all).", field = { text = S.search, max = 40 },
                    buttons = { { id = "apply", label = "Search" }, { id = "close", label = "Cancel" } } })
                if ok then S.typing = true end
            end)
            y += 40
            y = seg(d, x, y, w, { "All", "Near", "DDH" }, S.listFilter, function(i) S.listFilter = i; S.listKey = nil; S.listTop = 0 end) + 8
            -- the list: as many rows as fit, the wheel scrolls it
            local rowH = 30
            local bottom = b.y - 70
            local rows = math.max(3, math.floor((bottom - y) / rowH))
            local n = #(S.listObjs or {})
            S.listTop = clamp(S.listTop or 0, 0, math.max(0, n - rows))
            S.screen.listBox = { a = V(x, y, 0), b = V(x + w, y + rows * rowH, 0), rows = rows, n = n }
            for r = 1, rows do
                local i = S.listTop + r
                local o = S.listObjs and S.listObjs[i]
                if not o then break end
                local ra, rb = V(x, y + (r - 1) * rowH, 0), V(x + w, y + r * rowH - 2, 0)
                local on = S.sel and S.sel.id == o.id
                if on then d:rect(ra, rb, { colour = UI.accentDim, fill = true, rounding = 7 })
                elseif hot(ra, rb) then d:rect(ra, rb, { colour = UI.tile, fill = true, rounding = 7 }) end
                local name = titleOf(o.item)
                if #name > 30 then name = string.sub(name, 1, 29) .. "…" end
                if S.group[o.id] then d:circle(V(x + 10, ra.y + 14, 0), 4, { colour = UI.purple, fill = true }) end
                d:text(V(x + 20, ra.y + 6, 0), name, { size = 14, colour = on and UI.accent or UI.text })
                d:text(V(rb.x - 8, ra.y + 6, 0), string.format("%.0f m", len(o.position - (S.cam.target or o.position))), { size = 13, colour = UI.dim, align = "right" })
                tileAdd(ra, rb, function()
                    send(); select(o); S.cam.goal = o.position; S.listKey = nil; say("Picked " .. titleOf(o.item))
                end)
            end
            if n > rows then
                local la, lb2 = S.screen.listBox.a, S.screen.listBox.b
                local f0, f1 = S.listTop / n, math.min(1, (S.listTop + rows) / n)
                d:rect(V(lb2.x + 4, la.y + (lb2.y - la.y) * f0, 0), V(lb2.x + 7, la.y + (lb2.y - la.y) * f1, 0), { colour = UI.accent, fill = true, rounding = 2 })
            end
            local pb = b.y - 56
            btn(d, V(x, pb, 0), V(x + w, pb + 34, 0), "Save as park mod  (for online)", function() FN.saveParkModSay() end)
            if S.blocked or #miss > 0 then
                btn(d, V(x, pb - 42, 0), V(x + w, pb - 8, 0), "Park locked: check again", function()
                    S.blocked = nil; pcall(findMissing)
                    if #(S.missing or {}) == 0 then say("No missing objects found. Try moving something again.") else say("Fix: run Clean out park.exe with the game closed.", true) end
                end)
            end
        end
        -- the last message, along the bottom
        if S.msg ~= "" and S.clock < S.msgUntil and S.ptab ~= 3 and S.ptab ~= 4 then
            local msg = S.msg
            if #msg > 52 then msg = string.sub(msg, 1, 50) .. "…" end
            d:text(V(x + 4, b.y - 30, 0), msg, { size = 13, colour = UI.dim })
        end
    end
    reskate.on("throwdown_ui", function(e)
        if e.action ~= "dialog" or e.args[1] ~= "ddh_setrename" then return end
        local what = e.args[2]
        if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
        S.typing = false
        if what ~= "cancel" then pcall(reskate.ui.close_dialog, "ddh_setrename") end
        if what == "apply" and S.renameSet and S.renameSetFn then S.renameSetFn(S.renameSet, tostring(e.args[3] or "")) end
        S.renameSet = nil
    end)
    reskate.on("throwdown_ui", function(e)
        if e.action ~= "dialog" or e.args[1] ~= "ddh_setname" then return end
        local what = e.args[2]
        if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
        S.typing = false
        if what ~= "cancel" then pcall(reskate.ui.close_dialog, "ddh_setname") end
        if what == "apply" and S.saveSet then S.saveSet(tostring(e.args[3] or "")) end
    end)
    reskate.on("throwdown_ui", function(e)
        if e.action ~= "dialog" or e.args[1] ~= "ddh_search" then return end
        local what = e.args[2]
        if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
        S.typing = false
        if what ~= "cancel" then pcall(reskate.ui.close_dialog, "ddh_search") end
        if what == "apply" then S.search = tostring(e.args[3] or ""); S.listKey = nil; S.listTop = 0 end
    end)
    -- the mouse on the panel: true when it is there (then the view does nothing with it)
    function UI.panelMouse(c)
        local box = S.screen and S.screen.panelBox
        if not box then return false end
        local px = c.position
        if not (px.x >= box.a.x and px.x <= box.b.x and px.y >= box.a.y and px.y <= box.b.y) then return false end
        if c.wheel and c.wheel ~= 0 then
            local lb = S.screen.listBox
            if lb and S.ptab == 3 then S.listTop = clamp((S.listTop or 0) - c.wheel * 3, 0, math.max(0, lb.n - lb.rows)) end
        end
        if c.left and not S.mouse.left then
            for i = #tiles, 1, -1 do
                local tt = tiles[i]
                if px.x >= tt.a.x and px.x <= tt.b.x and px.y >= tt.a.y and px.y <= tt.b.y then
                    if reskate.audio and reskate.audio.play_ui then pcall(reskate.audio.play_ui, "select") end
                    tt.fn()
                    break
                end
            end
        end
        return true
    end

    -- ---------------------------------------------------------------- the controls window: a controller and the keys
    local PAD_BODY = { 0,-92,7.6,-92.2,18.3,-92.5,30.7,-92.8,43.4,-93.3,55,-94,65.4,-95,75.6,-96.2,85.6,-97.6,95.4,-98.9,105,-100,114.4,-101.2,123.7,-102.5,132.7,-103.6,141.5,-104.3,150,-104,158.3,-102.9,166.4,-101.2,174.1,-98.9,181.4,-95.8,188,-92,193.9,-87.5,199.1,-82.4,203.8,-76.4,208.1,-69.7,212,-62,215.5,-53.1,218.5,-43.2,221.2,-32.4,223.6,-21.3,226,-10,228.3,1.6,230.4,13.7,232.3,26,234.2,38.2,236,50,237.9,61.6,239.9,73.3,241.8,84.7,243.2,95.4,244,105,244.2,113.5,243.8,121.1,243,127.9,241.8,134.2,240,140,237.7,145.5,234.9,150.6,231.7,155.1,228,159,224,162,219.4,164.3,214.3,165.9,208.9,166.7,203.4,166.8,198,166,192.7,164.2,187.4,161.5,182.1,158.1,176.9,154.2,172,150,167.4,145.3,163,139.9,158.8,134.3,154.5,128.8,150,124,145.5,119.7,141,115.7,136.4,112.1,131.5,108.8,126,106,120,103.7,113.7,101.8,107,100.4,99.8,99.1,92,98,83.4,97,74,96.3,64.3,95.8,54.5,95.4,45,95,35.2,94.7,24.7,94.4,14.7,94.2,6.1,94.1,0,94,-6.1,94.1,-14.7,94.2,-24.7,94.4,-35.2,94.7,-45,95,-54.5,95.4,-64.3,95.8,-74,96.3,-83.4,97,-92,98,-99.8,99.1,-107,100.4,-113.7,101.8,-120,103.7,-126,106,-131.5,108.8,-136.4,112.1,-141,115.7,-145.5,119.7,-150,124,-154.5,128.8,-158.8,134.3,-163,139.9,-167.4,145.3,-172,150,-176.9,154.2,-182.1,158.1,-187.4,161.5,-192.7,164.2,-198,166,-203.4,166.8,-208.9,166.7,-214.3,165.9,-219.4,164.3,-224,162,-228,159,-231.7,155.1,-234.9,150.6,-237.7,145.5,-240,140,-241.8,134.2,-243,127.9,-243.8,121.1,-244.2,113.5,-244,105,-243.2,95.4,-241.8,84.7,-239.9,73.3,-237.9,61.6,-236,50,-234.2,38.2,-232.3,26,-230.4,13.7,-228.3,1.6,-226,-10,-223.6,-21.3,-221.2,-32.4,-218.5,-43.2,-215.5,-53.1,-212,-62,-208.1,-69.7,-203.8,-76.4,-199.1,-82.4,-193.9,-87.5,-188,-92,-181.4,-95.8,-174.1,-98.9,-166.4,-101.2,-158.3,-102.9,-150,-104,-141.5,-104.3,-132.7,-103.6,-123.7,-102.5,-114.4,-101.2,-105,-100,-95.4,-98.9,-85.6,-97.6,-75.6,-96.2,-65.4,-95,-55,-94,-43.4,-93.3,-30.7,-92.8,-18.3,-92.5,-7.6,-92.2,-0,-92 }
    local PAD_INNER = { 0,84,3.5,84.1,8,84.1,13.5,84.2,19.6,84.3,26,84.4,32.6,84.6,39,84.8,45,85,50.9,85.2,57,85.5,63.1,85.8,69.3,86.1,75.4,86.4,81.3,86.9,86.8,87.4,92,88,96.8,88.7,101.3,89.4,105.5,90.2,109.6,91.1,113.4,92,117.1,93.2,120.6,94.5,124,96,127.3,97.8,130.4,99.8,133.3,102,136.1,104.4,138.8,106.8,141.3,109.3,143.7,111.7,146,114,148.2,116.3,150.2,118.6,152,120.9,153.8,123.2,155.4,125.5,157,127.8,158.5,129.9,160,132,161.5,134,163,136.1,164.5,138.2,165.9,140.1,167.2,142,168.3,143.6,169.3,144.9,170,146 }
    local PAD_BUMP = { 98,-104,99.4,-105.1,101.1,-106.8,103.1,-108.7,105.4,-110.8,108,-112.9,111,-114.9,114.3,-116.6,118,-118,122.3,-119.1,127.2,-120,132.6,-120.8,138.2,-121.5,144,-122,149.7,-122.2,155.1,-122.2,160,-122,164.6,-121.5,169.2,-120.6,173.6,-119.5,177.9,-118.2,181.9,-116.8,185.6,-115.2,189,-113.6,192,-112,194.5,-110.2,196.7,-108,198.5,-105.7,200,-103.4,201.3,-101.1,202.3,-99,203.2,-97.3,204,-96 }
    local PAD_TRIG = { 112,-118,113.3,-120.1,115,-123.1,117,-126.6,119.5,-130.2,122.5,-133.5,126,-136,130.4,-137.9,135.6,-139.5,141.2,-140.8,147.1,-141.6,152.8,-142.1,158,-142,162.9,-141.4,167.7,-140.2,172.4,-138.6,176.7,-136.7,180.7,-134.4,184,-132,186.7,-129,188.9,-125.3,190.6,-121.4,192,-117.6,193.1,-114.3,194,-112 }
    local ctiles = {}
    local function keycap(d, x, y, k, wide)
        local w = wide or math.max(34, UI.textW(d, k, 13, "bold") + 18)
        d:rect(V(x, y + 3, 0), V(x + w, y + 33, 0), { colour = "#00000080", fill = true, rounding = 7 })
        d:rect(V(x, y, 0), V(x + w, y + 30, 0), { colour = "#e6e9ef", fill = true, rounding = 7 })
        d:text(V(x + w / 2, y + 7, 0), k, { size = 13, colour = "#0d1117", font = "bold", align = "centre" })
        return w
    end
    local limL, limR = 0, 1e9   -- the text keeps inside these (smaller when it would not fit)
    local function callout(d, from, to, text, right)
        d:line(from, to, { colour = "#ffffff2e", thickness = 1 })
        d:circle(to, 3, { colour = UI.accent, fill = true })
        local size = 14
        local room = right and (limR - to.x - 10) or (to.x - 10 - limL)
        local w = UI.textW(d, text, size)
        if w > room and room > 40 then size = math.max(10, math.floor(size * room / w)) end
        d:text(V(right and to.x + 10 or to.x - 10, to.y - size * 0.62, 0), text, { size = size, colour = UI.text, align = right and "left" or "right" })
    end
    function UI.controlsWin(d)
        ctiles = {}
        local W, H = S.size.x, S.size.y
        local pw, ph = math.min(1500, W - 80), math.min(800, H - 80)
        local a = V(math.floor((W - pw) / 2), math.floor((H - ph) / 2), 0)
        local b = a + V(pw, ph, 0)
        S.screen.controlsBox = { a = a, b = b }
        d:rect(V(0, 0, 0), V(W, H, 0), { colour = "#00000080", fill = true })
        UI.panelBox(d, a, b, "Controls")
        local ca, cb = V(b.x - 48, a.y + 10, 0), V(b.x - 12, a.y + 44, 0)
        d:text(V((ca.x + cb.x) / 2, ca.y + 4, 0), "×", { size = 24, colour = UI.dim, align = "centre" })
        ctiles[#ctiles + 1] = { a = ca, b = cb, fn = function() S.controlsOpen = false end }
        -- the controller, drawn (what each button does first, so the pad sits on top of the lines)
        local half = pw * 0.64
        local cx, cy = a.x + half / 2, a.y + 52 + (ph - 52) * 0.45
        d:text(V(a.x + 24, a.y + 68, 0), "CONTROLLER", { size = 13, colour = "#f0f3f680", font = "bold" })
        -- laid out like an Xbox pad: left stick high, d-pad low; right stick low, A B X Y high
        local ls, rs = V(cx - 140, cy - 35, 0), V(cx + 70, cy + 48, 0)
        local dp, ab = V(cx - 70, cy + 48, 0), V(cx + 140, cy - 38, 0)
        local vw, mn = V(cx - 42, cy - 38, 0), V(cx + 42, cy - 38, 0)
        local BP = { y = V(0, -26, 0), x = V(-26, 0, 0), b = V(26, 0, 0), a = V(0, 26, 0) }
        local lx, rx = cx - 255, cx + 255
        limL, limR = a.x + 16, a.x + half - 14
        callout(d, V(cx - 150, cy - 141, 0), V(lx, cy - 205, 0), "LT   lower", false)
        callout(d, V(cx - 125, cy - 112, 0), V(lx, cy - 150, 0), "LB   turn  ·  clear group", false)
        callout(d, ls, V(lx, cy - 70, 0), "L-stick   move  ·  L3 next snap", false)
        callout(d, vw, V(lx, cy + 5, 0), "View   snap: auto / one / off", false)
        callout(d, dp, V(lx, cy + 80, 0), "D-pad   size  ·  zoom", false)
        callout(d, V(cx + 150, cy - 141, 0), V(rx, cy - 205, 0), "RT   raise", true)
        callout(d, V(cx + 125, cy - 112, 0), V(rx, cy - 160, 0), "RB   turn  ·  add to group", true)
        callout(d, ab + BP.y, V(rx, cy - 115, 0), "Y   remove  ·  ungroup", true)
        callout(d, ab + BP.b, V(rx, cy - 75, 0), "B   cancel  /  close", true)
        callout(d, ab + BP.x, V(rx, cy - 35, 0), "X   copy", true)
        callout(d, ab + BP.a, V(rx, cy + 5, 0), "A   pick up  ·  hold select", true)
        callout(d, mn, V(rx, cy + 45, 0), "Menu   step size", true)
        callout(d, rs, V(rx, cy + 85, 0), "R-stick   look  ·  R3 tools", true)
        -- the pad as a line drawing (its outline traced like the usual Xbox pad)
        local LC, LC2 = "#45c8e4", "#45c8e499"
        local function path(pts, sx, col, th)
            local px, py = nil, nil
            for i = 1, #pts, 2 do
                local x, y = cx + pts[i] * sx, cy + pts[i + 1]
                if px then d:line(V(px, py, 0), V(x, y, 0), { colour = col, thickness = th }) end
                px, py = x, y
            end
        end
        path(PAD_BODY, 1, LC, 3)
        path(PAD_INNER, 1, LC2, 2); path(PAD_INNER, -1, LC2, 2)
        path(PAD_BUMP, 1, LC, 3); path(PAD_BUMP, -1, LC, 3)
        path(PAD_TRIG, 1, LC2, 2); path(PAD_TRIG, -1, LC2, 2)
        d:text(V(cx - 153, cy - 162, 0), "LT", { size = 12, colour = LC, font = "bold", align = "centre" })
        d:text(V(cx + 153, cy - 162, 0), "RT", { size = 12, colour = LC, font = "bold", align = "centre" })
        d:text(V(cx - 222, cy - 118, 0), "LB", { size = 12, colour = LC, font = "bold", align = "centre" })
        d:text(V(cx + 222, cy - 118, 0), "RB", { size = 12, colour = LC, font = "bold", align = "centre" })
        for _, st2 in ipairs({ ls, rs }) do
            d:circle(st2, 30, { colour = LC, thickness = 3 })
            d:circle(st2, 20, { colour = LC2, thickness = 2 })
        end
        d:circle(dp, 32, { colour = LC2, thickness = 2 })
        local cr = { -8, -26, 8, -26, 8, -8, 26, -8, 26, 8, 8, 8, 8, 26, -8, 26, -8, 8, -26, 8, -26, -8, -8, -8, -8, -26 }
        for i = 1, #cr - 2, 2 do d:line(dp + V(cr[i], cr[i + 1], 0), dp + V(cr[i + 2], cr[i + 3], 0), { colour = LC, thickness = 3 }) end
        for k, off in pairs(BP) do
            d:circle(ab + off, 12, { colour = UI.BTN[k][2], thickness = 3 })
            d:text(ab + off - V(0, 9, 0), UI.BTN[k][1], { size = 14, colour = UI.BTN[k][2], font = "bold", align = "centre" })
        end
        d:circle(vw, 8, { colour = LC, thickness = 2 }); d:circle(mn, 8, { colour = LC, thickness = 2 })
        d:circle(V(cx, cy - 72, 0), 16, { colour = LC, thickness = 3 })
        d:text(V(cx, b.y - 70, 0), "LB + D-pad right opens  ·  B closes  ·  LB + View undo  ·  RB + View redo", { size = 14, colour = UI.dim, align = "centre" })
        -- the keyboard and mouse
        local kx = a.x + half + 20
        local ky = a.y + 68
        d:line(V(a.x + half, a.y + 70, 0), V(a.x + half, b.y - 40, 0), { colour = UI.line, thickness = 1 })
        d:text(V(kx, ky, 0), "KEYBOARD AND MOUSE", { size = 13, colour = "#f0f3f680", font = "bold" })
        ky += 34
        local rows = {
            { { "W" }, { "E" }, { "R" }, "move / turn / size handles" },
            { { "T" }, "snap to objects on / off" },
            { { "Tab" }, "snap target: auto, one object, off" },
            { { "G" }, "drag in steps" },
            { { "F" }, "look at the picked object" },
            { { "Ctrl" }, { "Z" }, "undo        Ctrl + Y: redo" },
            { { "Shift" }, "bigger steps" },
            { { "Ctrl" }, "hold while dragging: no snapping" },
            { { "Arrows" }, { "PgUp" }, { "PgDn" }, "fly the view" },
            { { "Esc" }, "done" },
        }
        for _, r in ipairs(rows) do
            local x = kx
            for _, part in ipairs(r) do
                if type(part) == "table" then x += keycap(d, x, ky, part[1]) + 6
                else d:text(V(x + 8, ky + 6, 0), part, { size = 15, colour = UI.text }) end
            end
            ky += 40
        end
        -- the mouse
        local mx, my = kx + 40, ky + 30
        local tx = mx + 120
        limL, limR = a.x + half + 10, b.x - 18
        callout(d, V(mx + 16, my + 20, 0), V(tx, my - 6, 0), "Left click   pick  ·  drag a handle", true)
        callout(d, V(mx + 18, my + 30, 0), V(tx, my + 26, 0), "Left drag (empty)   turn the view", true)
        callout(d, V(mx + 35, my + 22, 0), V(tx, my + 58, 0), "Wheel   zoom", true)
        callout(d, V(mx + 54, my + 20, 0), V(tx, my + 90, 0), "Right drag   slide the view", true)
        d:rect(V(mx, my, 0), V(mx + 70, my + 110, 0), { colour = "#45c8e4", rounding = 35, thickness = 3 })
        d:line(V(mx + 35, my + 3, 0), V(mx + 35, my + 46, 0), { colour = "#45c8e499", thickness = 2 })
        d:line(V(mx + 4, my + 46, 0), V(mx + 66, my + 46, 0), { colour = "#45c8e499", thickness = 2 })
        d:rect(V(mx + 31, my + 12, 0), V(mx + 39, my + 32, 0), { colour = "#45c8e4", rounding = 4, thickness = 2 })
        d:text(V(tx + 10, my + 113, 0), "Ctrl + click   group add / remove", { size = 14, colour = UI.text })
        UI.footer(d, a, b, { { "b", "Close" } })
    end
    function UI.controlsMouse(c)
        if not S.controlsOpen then return false end
        if c.left and not S.mouse.left then
            local px = c.position
            local box = S.screen.controlsBox
            local used = false
            for _, tt in ipairs(ctiles) do
                if px.x >= tt.a.x and px.x <= tt.b.x and px.y >= tt.a.y and px.y <= tt.b.y then tt.fn(); used = true end
            end
            if not used and box and not (px.x >= box.a.x and px.x <= box.b.x and px.y >= box.a.y and px.y <= box.b.y) then S.controlsOpen = false end
        end
        return true
    end
end)()

function FN.drawMain(d)
    S.size = d:size()
    local cpos, f, r, u = camBasis()
    local probe = d:world_to_screen(cpos + f * 10 + r * 1 + u * 1)
    if probe then
        local mx, my = (probe.x - S.size.x / 2) / 0.1, (S.size.y / 2 - probe.y) / 0.1
        if math.abs(mx) > 1 and math.abs(my) > 1 then S.proj = V(mx, my, 0) end
    end
    S.screen = {}
    if S.picker then return end
    pcall(FN.drawGroup, d)
    pcall(FN.drawGrid, d)
    if S.carry then
        pcall(function()
            for i, c in ipairs(S.carryPlaces()) do
                if i > 200 then break end
                if S.itemBox[c.item] then
                    drawShape(d, worldShape(c.item, c.pos, c.heading, c.scale), UI.purple, 3)
                else
                    d:world_line(c.pos - V(0.4, 0, 0), c.pos + V(0.4, 0, 0), { colour = UI.purple, thickness = 3 })
                    d:world_line(c.pos - V(0, 0, 0.4), c.pos + V(0, 0, 0.4), { colour = UI.purple, thickness = 3 })
                    d:world_line(c.pos, c.pos + V(0, 1, 0), { colour = UI.purple, thickness = 3 })
                end
            end
            for _, gd in ipairs(S.carry.guides or {}) do
                if gd.nb then drawShape(d, gd.nb.shape or gd.nb, "#35e0ff", 3, gd.nb.xf) end
            end
            local W, H = S.size.x, S.size.y
            UI.chip(d, W / 2 - 120, 24, "Carrying  " .. S.carry.set.name, UI.purple)
            UI.promptRow(d, W / 2, H - 48, { { "a", "Put down" }, { "b", "Cancel" }, { "LB RB", "Turn" }, { "RT LT", "Up / down" }, { "L3", "Snap to next" } })
        end)
        return
    end
    if S.toolsWin then
        local okt, errt = pcall(FN.drawTools, d)
        if not okt then reskate.log("Quick Drop helper: copy tools: " .. tostring(errt), "warn"); S.toolsWin = nil end
    end
    -- the controller's view (when the controller was used last): aiming cross, what it is on, prompts along the bottom
    local padMode = S.padUsedAt ~= nil and (not S.mouseUsedAt or S.padUsedAt > S.mouseUsedAt) and S.clock - S.padUsedAt < 60000
    if padMode then pcall(UI.drawPadHud, d) end
    if padMode and not S.grab and not S.drag then return end
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

    if padMode then
        -- the controller: no handles (like Quick Drop), only its outline where it is going
        S.screen.axis, S.screen.unit, S.screen.planes, S.screen.ring, S.screen.cubes = {}, {}, {}, {}, {}
    elseif S.mode == 1 then
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
    -- what it snaps to, when chosen (L3 tap / Tab): that object in orange
    if S.snapPick then
        local o = S.snapPick ~= "off" and S.known and S.known[S.snapPick]
        if o then
            local so = placedSolid(o)
            drawShape(d, so.shape or so, "#ffa640", 4, so.xf)
        end
        d:text(center + V(14, 8, 0), "snap: " .. FN.snapLabel(), { size = 16, colour = "#ffa640", shadow = true })
    end
    -- what it is snapped to: that object's box (or its point), and how
    if S.guides then
        local WORDS = { touch = "touching", level = "lined up", turn = "same turn", match = "same size" }
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
    if S.boxCorners and (S.mode ~= 3 or padMode) then
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
end

reskate.on("draw", function(d)
    if not S.open then return end
    local ok, err = pcall(FN.drawMain, d)
    if not ok and not S.drawWarned then S.drawWarned = true; reskate.log("Quick Drop helper: draw: " .. tostring(err), "warn") end
    if S.ownPanel and not S.picker then
        local okp, errp = pcall(UI.sidePanel, d)
        if not okp and not S.panelWarned then S.panelWarned = true; reskate.log("Quick Drop helper: panel: " .. tostring(errp), "warn") end
    end
    if S.picker then
        local okk, errk = pcall(FN.drawPicker, d)
        if not okk then reskate.log("Quick Drop helper: add window: " .. tostring(errk), "warn"); S.picker = nil end
    end
    if S.controlsOpen then
        local okc, errc = pcall(UI.controlsWin, d)
        if not okc then reskate.log("Quick Drop helper: controls: " .. tostring(errc), "warn"); S.controlsOpen = false end
    end
end)

reskate.on("load", function() reskate.log("Quick Drop helper ready: drop an object, then F6 (or hold Ctrl and use [ ] PgUp PgDn Z X arrows).") end)
