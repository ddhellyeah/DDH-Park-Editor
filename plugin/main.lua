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
--
-- 3.0.0: the code is split over this file and part01 ... part14 beside it (it used to be one 6,000-line file).
-- This file has the shared state and helpers and loads the parts in order at the end; each part says at its top
-- what it holds. Nothing works differently in game.

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

-- PE: what the parts share (main.lua loads part01 ... part14 in order at the end, and each one gets PE)
local PE = {}

local function say(text, warn)
    S.msg = text
    S.msgUntil = S.clock + 4000
    if warn or not S.open then reskate.ui.toast(text, warn and "warn" or "info") end
end

-- The game's list of placeable objects (the catalog), asked for once and kept: before, it was fetched again
-- every time it was needed (the Park list twice a second, every name not found...). Asked for again when a map
-- loads. An empty or failed answer isn't kept, so it is tried again next time.
local CAT = { list = nil, have = nil }
function FN.catalog()
    if CAT.list then return CAT.list end
    local ok, l = pcall(reskate.objects.catalog)
    if not ok or type(l) ~= "table" then return {} end
    if #l == 0 then return l end
    local have = {}
    for _, it in ipairs(l) do
        have[it.key] = true
        S.titles[it.key] = it.title or it.key
    end
    CAT.list, CAT.have = l, have
    return l
end
-- item key -> true for every item the game has
function FN.catalogHave()
    FN.catalog()
    return CAT.have or {}
end
function FN.catalogReset()
    CAT.list, CAT.have = nil, nil
    for k, v in pairs(S.titles) do if v == false then S.titles[k] = nil end end
end

local function titleOf(key)
    local t = S.titles[key]
    if t then return t end
    if t == false then return key end
    FN.catalog()
    if S.titles[key] then return S.titles[key] end
    -- not in the catalog (from a mod that is off or missing): remembered, so it isn't searched for again
    if CAT.list then S.titles[key] = false end
    return key
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
    local have = FN.catalogHave()
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

-- Online, a tilted object is shown by a tilted copy, and the game's flat one is kept this far underground
-- (see tilting, in part03)
FN.BURY = 30
FN.BURYV = V(0, FN.BURY, 0)
S.buried = {}
-- an object as the editor sees it: a tilted one where it was placed, not where the game has it (its tilted body
-- offline, or underground online)
function FN.realObject(o)
    local h = S.tiltHeld and S.tiltHeld[o.id]
    if h then
        h.reported, h.reportedHeading = o.position, o.heading
        return { id = o.id, item = o.item, position = h.pos, heading = h.heading, scale = o.scale }
    end
    local b = S.buried[o.id]
    if b then
        if len(o.position - (b.pos - FN.BURYV)) < 0.05 then
            return { id = o.id, item = o.item, position = b.pos, heading = o.heading, scale = o.scale }
        end
        -- no longer underground (put back, or moved by something else), unless it is just being put there
        if S.clock > (b.wait or 0) then S.buried[o.id] = nil end
    end
    return o
end
-- the park objects, as the editor sees them
function FN.objectsNow()
    local out = {}
    for i, o in ipairs(reskate.objects.list()) do out[i] = FN.realObject(o) end
    return out
end

-- new objects (from Quick Drop or anything else) become the picked one
local function scan()
    local list = reskate.objects.list()
    local now = {}
    for _, o in ipairs(list) do
        -- an object held tilted: where it was placed (not where its tilted body is, or underground)
        o = FN.realObject(o)
        now[o.id] = o
    end
    if S.known == nil then
        reskate.log(string.format("Quick Drop helper: %d park objects on this map.", #list))
        pcall(findMissing)
        if not S.loggedCat then
            S.loggedCat = true
            local n, ddh = 0, {}
            for _, it in ipairs(FN.catalog()) do
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

-- PE.drawShape: shared with the other parts, (further on, with the drawing)
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

-- ---------------------------------------------------------------- loading the other parts
-- The editor is split over the part files beside this one. Each one gets PE, adds what it makes that
-- the parts after it use, and runs in this order (the same order the code had in one file).
PE.BOX_EDGES = BOX_EDGES
PE.BUSY = BUSY
PE.FN = FN
PE.GREEN = GREEN
PE.PLANES = PLANES
PE.S = S
PE.TITLE = TITLE
PE.UI = UI
PE.V = V
PE.YELLOW = YELLOW
PE.axesFor = axesFor
PE.clamp = clamp
PE.cross = cross
PE.d2 = d2
PE.dot = dot
PE.findMissing = findMissing
PE.flat = flat
PE.inPoly = inPoly
PE.lastApplied = lastApplied
PE.len = len
PE.norm = norm
PE.round = round
PE.sameAsSent = sameAsSent
PE.say = say
PE.scan = scan
PE.segDist = segDist
PE.select = select
PE.send = send
PE.titleOf = titleOf
PE.wrap = wrap

local PARTS = {
    "part01_groups_undo",
    "part02_snap",
    "part03_tilt_parkmod",
    "part04_tighten",
    "part05_editor",
    "part06_panel",
    "part07_controller",
    "part08_arrange_copytools",
    "part09_addwindow",
    "part10_sets",
    "part11_pad_editor",
    "part12_tick",
    "part13_hud",
    "part14_panel_draw",
}
for _, name in ipairs(PARTS) do
    local ok, part = pcall(function() return require(name) end)
    if not ok or type(part) ~= "function" then
        local why = "DDH Park Editor: could not load " .. name .. ".lua: " .. tostring(part)
        reskate.log(why, "warn")
        pcall(reskate.ui.toast, "DDH Park Editor: " .. name .. ".lua is missing or broken (see the ReSkate log)", "warn")
        error(why, 0)
    end
    local ok2, err = pcall(part, PE)
    if not ok2 then
        reskate.log("DDH Park Editor: error in " .. name .. ".lua: " .. tostring(err), "warn")
        pcall(reskate.ui.toast, "DDH Park Editor: error in " .. name .. ".lua (see the ReSkate log)", "warn")
        error(err, 0)
    end
end
