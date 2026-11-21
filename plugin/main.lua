-- DDH Quick Drop helper: works alongside Skate's own Quick Drop.
--
-- Drop objects with Quick Drop as normal. Then press F6 to fine-tune them with the same handles as the Object
-- Maker's 3D maker: W move (arrows, and squares to slide along a plane), E turn (the ring), R size (the cubes).
-- Click another placed object to pick it. Drag empty space to turn the view, right-drag to slide it, scroll to
-- zoom, W A S D Q E... (see the panel). Esc closes it.
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

-- a message naming controller buttons by their usual names, given the buttons doing those jobs now (part17_keys)
function FN.padText(s) return s end

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
    if not o then S.sel, S.target, S.dirty = nil, nil, false; S.snapIgnore = {} return end
    local same = S.sel and S.sel.id == o.id
    S.sel = { id = o.id, item = o.item, bp = blueprint, pos0 = o.position, h0 = o.heading or 0 }
    if S.open and S.cam.goal then S.cam.goal = o.position end
    S.target = { pos = o.position, heading = o.heading or 0, scale = o.scale or 1 }
    S.dirty = false
    -- a newly picked object doesn't snap onto what it stands inside of (a stack of the same object, its original)
    if not same then
        S.snapIgnore = {}
        if FN.ignoreOverlapping then pcall(FN.ignoreOverlapping) end
    end
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
                    -- copies made where the held objects are: not snapped onto until moved clear of them
                    if S.sel and S.snapIgnore then S.snapIgnore[o.id] = true end
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
            elseif S.sel and S.snapIgnore then
                -- dropped where the held one was: the held one doesn't snap back onto it until moved clear
                S.snapIgnore[o.id] = true
            end
        elseif #fresh == 1 then
            local o = fresh[1]
            reskate.log("Quick Drop helper: new object " .. fmt(o))
            select(o)
            S.droppedAt = S.clock
            if not S.open then reskate.ui.toast("Dropped " .. titleOf(o.item) .. ". " .. (FN.kbLabel and FN.kbLabel("open") or "F6") .. ": move, turn and size it") end
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
-- the game is busy with an edit (it says so in a few ways): try again in the next free slot. BUSY[why] knows
-- them all, here and in the other parts (group moves, copies, removals)
setmetatable(BUSY, { __index = function(_, why)
    local w = string.lower(tostring(why))
    return string.find(w, "wait for the current edit", 1, true) ~= nil or string.find(w, "unacknowledged", 1, true) ~= nil
end })
local function isBusy(why) return BUSY[why] == true end
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
    -- (while moving, evenly spaced at the fastest steady pace the game allows: 4 in 1.05 s. Faster, it went in
    -- bursts of 4 and then stood still until a second had passed, which felt like lag)
    local gap = ((S.drag and S.drag.moved) or S.padMoving) and 265 or 250
    if S.clock - S.lastSend < gap then return end
    table.insert(tries, S.clock)
    local hd = nil
    if S.sel.h0 == nil or math.abs(wrap(t.heading - S.sel.h0)) > 1e-5 then hd = t.heading end
    local ok, why = reskate.objects.move(S.sel.id, t.pos, hd, t.scale)
    if S.dragStats then
        local st = S.dragStats
        if ok then st.sent += 1 elseif isBusy(why) then st[why] = (st[why] or 0) + 1 else st.other = (st.other or 0) + 1 end
    end
    if ok then S.sel.h0 = t.heading end
    S.lastSend = S.clock
    if ok then
        S.lastSent = { id = S.sel.id, pos = t.pos, heading = t.heading, scale = t.scale, at = S.clock }
        -- the places it was sent to lately: while the game catches up, the object can be at any of them (and
        -- must not be mistaken for another object, or it lands on top of itself)
        S.sentHist = S.sentHist or {}
        local hist = S.sentHist
        if hist.id ~= S.sel.id then hist = { id = S.sel.id }; S.sentHist = hist end
        hist[#hist + 1] = { pos = t.pos, at = S.clock }
        while #hist > 16 or (hist[1] and S.clock - hist[1].at > 4000) do table.remove(hist, 1) end
        -- still dragging: keep going with the next place
        S.dirty = false
        S.busySince, S.busyLogged = nil, nil
    elseif isBusy(why) then
        -- the game is still busy: wait for the next free slot (every try counts toward its 4 a second); said
        -- once in the log when it stays busy a long while
        S.busySince = S.busySince or S.clock
        if S.clock - S.busySince > 3000 and not S.busyLogged then
            S.busyLogged = true
            reskate.log("Quick Drop helper: the game has been busy with an edit for a while: " .. tostring(why), "warn")
        end
    else
        reskate.log("Quick Drop helper: the game refused the change: " .. tostring(why), "warn")
        if string.find(tostring(why), "not installed", 1, true) then
            local first = S.blocked == nil
            S.blocked = tostring(why):match("installed:%s*(%S+)") or "?"
            if first then pcall(findMissing, S.blocked) end
            local n = S.missing and #S.missing or 0
            say(n > 0 and string.format("Park locked: %d object(s) from a missing mod. See the editor's panel.", n)
                or "Park locked: an object from a missing mod. See the editor's panel.", S.clock - (S.lastWarn or -1e9) > 5000)
        else
            say("Could not change it: " .. tostring(why), S.clock - (S.lastWarn or -1e9) > 5000)
        end
        S.lastWarn = S.clock
        S.dirty = false
    end
end

-- PE.drawShape: shared with the other parts, (further on, with the drawing)
-- the look of what is drawn over the view
local UI = { purple = "#c49bff", orange = "#ffa640", green = "#7dffb0" }
-- ---------------------------------------------------------------- the look: four colours the player can choose
-- (the colours window, part16): panels, fields (buttons, boxes), borders and the accent. Everything else is worked
-- out from them, so text always reads: light or dark text for the panels, black or white on the accent, and the dim
-- text and hover shades in between. Kept between games.
do
    local function rgb(h)
        h = tostring(h or ""):gsub("#", "")
        if #h < 6 then return 0, 0, 0 end
        return tonumber(h:sub(1, 2), 16) or 0, tonumber(h:sub(3, 4), 16) or 0, tonumber(h:sub(5, 6), 16) or 0
    end
    local function hex(r, g, b)
        local function c(v) return math.max(0, math.min(255, math.floor(v + 0.5))) end
        return string.format("#%02x%02x%02x", c(r), c(g), c(b))
    end
    local function lum(h)
        local r, g, b = rgb(h)
        local function f(v) v = v / 255; return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4 end
        return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    end
    local function contrast(a, b)
        local la, lb = lum(a), lum(b)
        if la < lb then la, lb = lb, la end
        return (la + 0.05) / (lb + 0.05)
    end
    local function mix(a, b, k)
        local r1, g1, b1 = rgb(a)
        local r2, g2, b2 = rgb(b)
        return hex(r1 + (r2 - r1) * k, g1 + (g2 - g1) * k, b1 + (b2 - b1) * k)
    end
    UI.rgb, UI.hex, UI.lum, UI.contrast, UI.mix = rgb, hex, lum, contrast, mix
    -- the ready-made looks (the first is the default)
    UI.PRESETS = {
        { name = "Burnt orange", panel = "#121212", field = "#1e1e1e", border = "#646464", accent = "#c64c00" },
        { name = "Mono", panel = "#121212", field = "#1e1e1e", border = "#646464", accent = "#f2f2f2" },
        { name = "Amber", panel = "#121212", field = "#1e1e1e", border = "#646464", accent = "#ffb020" },
        { name = "Cyan", panel = "#121212", field = "#1e1e1e", border = "#646464", accent = "#3dd6f5" },
        { name = "Lime", panel = "#121212", field = "#1e1e1e", border = "#646464", accent = "#a3e635" },
        { name = "Pink", panel = "#121212", field = "#1e1e1e", border = "#646464", accent = "#ff6fb5" },
        { name = "Graphite", panel = "#2a2a2a", field = "#373737", border = "#7a7a7a", accent = "#f5f5f5" },
        { name = "Light", panel = "#ffffff", field = "#f2f2f2", border = "#8a8a8a", accent = "#111111" },
    }
    -- the outlines drawn in the world, each its own colour
    UI.OUTLINES = {
        { key = "oHeld", name = "Held object", def = "#ff8a1f" },
        { key = "oRest", name = "Held, resting", def = "#a6560f" },
        { key = "oSnap", name = "Snapped to", def = "#35e0ff" },
        { key = "oMeet", name = "Meeting sides", def = "#7dffb0" },
        { key = "oGroup", name = "Group", def = "#c49bff" },
        { key = "oAim", name = "Aimed at", def = "#ffffff" },
        { key = "oPick", name = "Snap target", def = "#ffa640" },
        { key = "oSet", name = "Set being placed", def = "#c49bff" },
        { key = "oCopy", name = "Copies preview", def = "#7dffb0" },
        { key = "oMeasure", name = "Measure", def = "#c49bff" },
        { key = "oGrid", name = "Grid", def = "#ffffff" },
        { key = "oHalo", name = "Outline edge", def = "#000000" },
    }
    -- the colours used everywhere, from the four chosen ones
    function UI.applyTheme(th)
        local d0 = UI.PRESETS[1]
        th = th or {}
        local panel, field = th.panel or d0.panel, th.field or d0.field
        local border, accent = th.border or d0.border, th.accent or d0.accent
        UI.theme = { panel = panel, field = field, border = border, accent = accent }
        -- (the outlines: the chosen ones kept, the rest their own default)
        for _, o in ipairs(UI.OUTLINES) do
            if th[o.key] then UI.theme[o.key] = th[o.key] end
        end
        for _, o in ipairs(UI.OUTLINES) do
            if o.def then UI[o.key] = th[o.key] or o.def end
        end
        UI.purple = UI.oGroup
        local dark = lum(panel) < 0.35
        local text = dark and "#f2f2f2" or "#111111"
        -- (dim text: between the text and the panel, but always at least 4.5 : 1 on the panels and the fields)
        local dim = text
        for k = 0.45, 0, -0.05 do
            local c = mix(text, panel, k)
            if contrast(c, panel) >= 4.5 and contrast(c, field) >= 4.5 then dim = c break end
        end
        UI.panel, UI.field, UI.border, UI.accent = panel, field, border, accent
        UI.text, UI.dim = text, dim
        UI.faint = mix(text, panel, 0.6)
        UI.fieldHot = mix(field, text, 0.12)
        UI.onAccent = contrast("#121212", accent) >= contrast("#ffffff", accent) and "#121212" or "#ffffff"
        UI.accentHot = mix(accent, UI.onAccent == "#121212" and "#ffffff" or "#000000", 0.18)
        UI.accentDim = mix(accent, panel, 0.72)
        -- (the old names, for the parts that use them)
        UI.bg, UI.bg2, UI.tile, UI.tileHot, UI.line = panel, panel, field, UI.fieldHot, border
    end
    UI.applyTheme(nil)
    local okT, saved = pcall(reskate.storage.get, "theme")
    if okT and type(saved) == "table" then UI.applyTheme(saved) end
    function UI.saveTheme()
        pcall(reskate.storage.set, "theme", UI.theme)
    end
end
UI.BTN = { a = { "A", "#3fb950" }, b = { "B", "#f85149" }, x = { "X", "#4c8dff" }, y = { "Y", "#e3b341" } }
function UI.textW(d, str, size, font)
    if d.measure then
        local ok, v = pcall(d.measure, d, str, { size = size, font = font })
        if ok and type(v) == "vector" then return v.x end
        if ok and type(v) == "table" and v.x then return v.x end
    end
    return #str * size * 0.52
end
-- PlayStation's face buttons (the same places as A B X Y): their colours; the symbols are drawn
UI.PSBTN = { a = "#7aa6ff", b = "#ff6b6b", x = "#e88bd3", y = "#3fd0b0" }
-- a face button's symbol at c, r its button's radius: a letter (Xbox) or a drawn cross, circle, square, triangle
-- (PlayStation, UI.padIsPS: set in part17_keys); ring: only the outline of the button, in its colour
function UI.faceGlyph(d, c, k, r, ring)
    if UI.padIsPS and UI.padIsPS() then
        local col = UI.PSBTN[k]
        if ring then d:circle(c, r, { colour = col, thickness = 3 })
        else d:circle(c, r, { colour = "#1d222b", fill = true }); d:circle(c, r, { colour = col, thickness = 1.5 }) end
        local s = r * 0.48
        local th = math.max(2, r * 0.17)
        if k == "a" then
            d:line(c + V(-s, -s, 0), c + V(s, s, 0), { colour = col, thickness = th })
            d:line(c + V(-s, s, 0), c + V(s, -s, 0), { colour = col, thickness = th })
        elseif k == "b" then
            d:circle(c, s * 1.05, { colour = col, thickness = th })
        elseif k == "x" then
            d:rect(c - V(s * 0.9, s * 0.9, 0), c + V(s * 0.9, s * 0.9, 0), { colour = col, thickness = th })
        else
            local p1, p2, p3 = c + V(0, -s * 1.1, 0), c + V(s * 1.05, s * 0.75, 0), c + V(-s * 1.05, s * 0.75, 0)
            d:line(p1, p2, { colour = col, thickness = th }); d:line(p2, p3, { colour = col, thickness = th }); d:line(p3, p1, { colour = col, thickness = th })
        end
        return
    end
    local b = UI.BTN[k]
    -- (the letter's middle sits about three quarters of its size below where it is drawn from)
    local size = math.floor(r * (ring and 1.17 or 1.33) + 0.5)
    local at = c - V(0, size * 0.75, 0)
    if ring then
        d:circle(c, r, { colour = b[2], thickness = 3 })
        d:text(at, b[1], { size = size, colour = b[2], font = "bold", align = "centre" })
    else
        d:circle(c, r, { colour = b[2], fill = true })
        d:text(at, b[1], { size = size, colour = "#0d1117", font = "bold", align = "centre" })
    end
end
-- a controller button: A B X Y round in their colours (PlayStation: its symbols), the rest a small light tag; its width
-- (k names the job's usual button: shown as the button doing that job now, see part17_keys; raw: k is the button
-- itself)
function UI.badgeW(d, k, raw)
    if UI.padShow and not raw then k = UI.padShow(k) end
    return UI.BTN[k] and 24 or (UI.textW(d, k, 13, "bold") + 14)
end
function UI.badge(d, x, y, k, raw)
    if UI.padShow and not raw then k = UI.padShow(k) end
    if UI.BTN[k] then
        UI.faceGlyph(d, V(x + 12, y, 0), k, 12)
        return 24
    end
    local w = UI.badgeW(d, k, true)
    d:rect(V(x, y - 11, 0), V(x + w, y + 11, 0), { colour = "#e6e9ef", fill = true, rounding = 6 })
    d:text(V(x + w / 2, y - 8, 0), k, { size = 13, colour = "#0d1117", font = "bold", align = "centre" })
    return w
end
-- a row of button prompts ({ button, what }) in a dark pill, centred on x
function UI.promptRow(d, cx, y, items)
    -- (a bar 40 high, its middle at y: at least 800 wide, wider when the buttons need it)
    local ws, total = {}, 0
    for i, it in ipairs(items) do
        ws[i] = { UI.badgeW(d, it[1]), UI.textW(d, it[2], 14) }
        total += ws[i][1] + 6 + ws[i][2] + (i < #items and 20 or 0)
    end
    local bw = math.max(800, total + 40)
    local a, b = V(cx - bw / 2, y - 20, 0), V(cx + bw / 2, y + 20, 0)
    d:rect(a, b, { colour = UI.panel, fill = true, rounding = 8 })
    d:rect(a, b, { colour = UI.border, rounding = 8, thickness = 1 })
    local x = cx - total / 2
    for i, it in ipairs(items) do
        UI.badge(d, x, y, it[1])
        x += ws[i][1] + 6
        d:text(V(x, y - 9, 0), it[2], { size = 14, colour = UI.text })
        x += ws[i][2] + 20
    end
end
-- a small rounded label with a coloured dot; its width
function UI.chipW(d, str) return UI.textW(d, str, 15) + 30 end
function UI.chip(d, x, y, str, col)
    local w = UI.chipW(d, str)
    d:rect(V(x, y, 0), V(x + w, y + 28, 0), { colour = UI.panel, fill = true, rounding = 8 })
    d:rect(V(x, y, 0), V(x + w, y + 28, 0), { colour = UI.border, rounding = 8, thickness = 1 })
    d:circle(V(x + 13, y + 14, 0), 4, { colour = col or UI.accent, fill = true })
    d:text(V(x + 22, y + 5, 0), str, { size = 15, colour = UI.text })
    return w
end
-- a window: dark rounded panel with a title bar
function UI.panelBox(d, a, b, title)
    d:rect(a, b, { colour = UI.panel, fill = true, rounding = 8 })
    d:rect(a, b, { colour = UI.border, rounding = 8, thickness = 1 })
    d:text(a + V(20, 13, 0), title, { size = 24, colour = UI.text, font = "heading" })
    d:line(V(a.x + 16, a.y + 52, 0), V(b.x - 16, a.y + 52, 0), { colour = UI.border, thickness = 1 })
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
    "part15_scan",
    "part16_colours",
    "part17_keys",
    "part18_modshapes",
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
