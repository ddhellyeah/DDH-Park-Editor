-- DDH Park Editor, part01_groups_undo: groups (several objects at once), undo and redo, the view.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN

local S = PE.S
local V = PE.V
local cross = PE.cross
local dot = PE.dot
local norm = PE.norm
local say = PE.say
local select = PE.select
local wrap = PE.wrap

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
        for _, o in ipairs(FN.objectsNow()) do if o.id == u.id then select(o) end end
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
    elseif u.kind == "swap" then
        -- replaced: take the new ones away and put the old ones back (and the other way for redo)
        local r = u.rec
        r.cancelled = true
        for i = #S.q, 1, -1 do if S.q[i].rec == r then table.remove(S.q, i) end end
        local now = #r.ids > 0 and itemsOf(r.ids) or {}
        queueRemove(r.ids, word)
        r.ids = {}
        local rec = queuePlace(u.items, word)
        rec.onAll = function(r2)
            if #r2.ids > 1 then S.group = {}; for _, id in ipairs(r2.ids) do S.group[id] = true end; S.gbase = nil end
        end
        table.insert(to, { kind = "swap", rec = rec, items = now })
        say(string.format("%s: swapping %d object%s back.", word == "undo" and "Undo" or "Redo", #u.items, #u.items == 1 and "" or "s"))
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

-- shared with the parts after this one
PE.camBasis = camBasis
PE.camGlide = camGlide
PE.follower = follower
PE.groupBase = groupBase
PE.groupCount = groupCount
PE.itemsOf = itemsOf
PE.markUndo = markUndo
PE.planeHit = planeHit
PE.poseOf = poseOf
PE.pushUndo = pushUndo
PE.queuePlace = queuePlace
PE.queueRemove = queueRemove
PE.rayAt = rayAt
PE.redo = redo
PE.rotY = rotY
PE.undo = undo
end
