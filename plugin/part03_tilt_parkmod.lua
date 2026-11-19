-- DDH Park Editor, part03_tilt_parkmod: tilting, and saving the park as a park mod.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local MAX_HELD = PE.MAX_HELD
local S = PE.S
local V = PE.V
local fullTurn = PE.fullTurn
local lastApplied = PE.lastApplied
local len = PE.len
local qconj = PE.qconj
local qmul = PE.qmul
local qrot = PE.qrot
local r3 = PE.r3
local say = PE.say
local tiltOf = PE.tiltOf
local tilted = PE.tilted
local titleOf = PE.titleOf
local wrap = PE.wrap

-- ---------------------------------------------------------------- tilting
-- The game keeps only a turn about up for a placed object. The plugin keeps every tilt itself (per map, by the
-- object's item and place) and puts it back whenever the park is loaded. It shows a tilt in one of two ways:
--
-- Offline: it holds the object with the game's object physics, fixed in place and still skateable, and gives it
-- its full turn. At most 32 tilted objects at once (the game's limit for one plugin).
--
-- Online (the game refuses object physics there): it puts a tilted copy of the object in its place (a world object
-- of the plugin's own, solid and skateable, at most 512), and moves the game's flat object 30 m underground so the
-- two don't collide. It sends its tilts to everyone else in the session who has this plugin, and shows theirs the
-- same way. Players without the plugin don't see a tilted object at all (it is underground for them).
--
-- Either way: while an object is moved, turned or sized it is let go (shown flat, back in its place, for that
-- moment), and tilted again once the game has it in its new place.
local MAX_ENTITIES = 500
-- objects held with physics (offline), counted against the game's 32
function FN.heldCount()
    local n = 0
    for _, h in pairs(S.tiltHeld) do if type(h) == "table" and h.mode ~= "entity" then n += 1 end end
    return n
end
function FN.entityCount()
    local n = 0
    for _, h in pairs(S.tiltHeld) do if type(h) == "table" and h.mode == "entity" then n += 1 end end
    return n
end
-- online: in a multiplayer session (asked twice a second)
function FN.online()
    if S.clock - (S.onlineAt or -1e9) > 500 then
        S.onlineAt = S.clock
        local ok, a = pcall(function() return reskate.session and reskate.session.active() end)
        S.isOnline = ok and a == true
    end
    return S.isOnline
end

-- moving the game's flat object underground and back (online): one move at a time, sharing the game's 4 edits
-- a second with the editor (which always keeps a slot)
S.buryQ = S.buryQ or {}
function FN.queueBury(id, pos, up)
    for i = #S.buryQ, 1, -1 do if S.buryQ[i].id == id then table.remove(S.buryQ, i) end end
    S.buryQ[#S.buryQ + 1] = { id = id, pos = pos, up = up }
end
function FN.buryTick()
    local e = S.buryQ[1]
    if not e then return end
    if S.dirty or S.grab or (S.drag and S.drag.moved) or S.padMoving then return end
    if S.clock - (S.buryLast or -1e9) < 300 then return end
    if not (FN.freeSlot and FN.freeSlot(1)) then return end
    if not (S.known and S.known[e.id]) then table.remove(S.buryQ, 1) return end
    S.tries = S.tries or {}
    table.insert(S.tries, S.clock)
    S.buryLast = S.clock
    local ok, r1, r2 = pcall(reskate.objects.move, e.id, e.pos)
    local why = ok and r2 or r1
    if ok and r1 then
        table.remove(S.buryQ, 1)
        local b = S.buried[e.id]
        if b then b.wait = S.clock + 3000 end
        S.lastScan = math.min(S.lastScan, S.clock - 350)
    elseif ok and S.BUSY_WHY[tostring(why)] then
        -- the game is still busy: tried again shortly
    else
        table.remove(S.buryQ, 1)
        reskate.log("Quick Drop helper: tilt: the game won't move " .. tostring(e.id) .. (e.up and " back up: " or " underground: ") .. tostring(why), "warn")
        if not e.up then
            -- can't hide the flat one (another player's object?): no tilted copy over it
            S.buried[e.id] = nil
            S.noBury = S.noBury or {}
            S.noBury[e.id] = S.clock + 15000
            local h = S.tiltHeld[e.id]
            if h and h.mode == "entity" then
                pcall(reskate.entities.remove, h.eid)
                S.tiltHeld[e.id] = nil
            end
            local plain = "online, the game wouldn't move " .. titleOf(S.known[e.id] and S.known[e.id].item or "") .. " out of the way (only your own objects can be tilted online)"
            if S.tiltWhy ~= plain then pcall(reskate.ui.toast, "Tilt: " .. plain) end
            S.tiltWhy = plain
        end
    end
end
S.BUSY_WHY = { ["the last edit is still being applied"] = true, ["more than 4 edits in a second"] = true }

local function letGo(id)
    local h = S.tiltHeld[id]
    if type(h) ~= "table" then S.tiltHeld[id] = nil return end
    S.tiltHeld[id] = nil
    if h.mode == "entity" then
        pcall(reskate.entities.remove, h.eid)
        -- the flat one back in its place (unless it is another player's: theirs puts it back)
        if h.remote then return end
        local b = S.buried[id]
        if b then
            b.wait = S.clock + 3000
            if S.sel and S.sel.id == id then
                -- picked: the editor's next edit puts it where it is meant to go (back up, or where it's dragged)
                for i = #S.buryQ, 1, -1 do if S.buryQ[i].id == id then table.remove(S.buryQ, i) end end
                S.buried[id] = nil
                if S.lastSent and S.lastSent.id == id then S.lastSent = nil end
                if S.target then S.dirty = true end
            else
                FN.queueBury(id, b.pos, true)
            end
        end
    else
        pcall(reskate.objects.physics, id, nil)
    end
end

-- the world object number for each tilted object (online)
S.entOf = S.entOf or {}
S.entNext = S.entNext or 0
local function entityId(id)
    local e = S.entOf[id]
    if not e then
        S.entNext += 1
        e = S.entNext
        S.entOf[id] = e
    end
    return e
end
local function axesOf(pos, q, scale)
    return { position = pos, right = qrot(q, V(1, 0, 0)) * scale, up = qrot(q, V(0, 1, 0)) * scale, forward = qrot(q, V(0, 0, 1)) * scale }
end

-- The model (blueprint) to make a tilted copy from. Quick Drop objects aren't among the models the game lists
-- with a mesh, so: that list by name first, then what a ray straight down onto the object hits, then every
-- blueprint the game has (with or without a mesh) by name. What's found (or not) is written to the log.
S.bkModel = S.bkModel or {}
function FN.modelForOnline(o)
    local m = FN.modelFor and FN.modelFor(o.item)
    if m then return m end
    local c = S.bkModel[o.item]
    if c ~= nil then return c end
    local key = string.lower(o.item)
    local p = o.position
    local okP, hit = pcall(reskate.world.pick, p + V(0, 6, 0), p - V(0, 1, 0))
    local ho = okP and type(hit) == "table" and hit.object or nil
    local picked = ho and ho.blueprint or nil
    if picked and ho.position and len(ho.position - p) < 0.5 then
        S.bkModel[o.item] = picked
        reskate.log("Quick Drop helper: tilt: model for " .. o.item .. " (from a ray onto it): " .. picked)
        return picked
    end
    if not S.allBp then
        S.allBp = {}
        local seen = {}
        for _, pre in ipairs({ "items/bk", "" }) do
            local okB, l = pcall(reskate.entities.blueprints, pre ~= "" and pre or nil, false)
            if okB and type(l) == "table" then
                for _, nm in ipairs(l) do if not seen[nm] then seen[nm] = true; S.allBp[#S.allBp + 1] = nm end end
            end
        end
    end
    local hits, near = {}, {}
    for _, nm in ipairs(S.allBp) do
        local l = string.lower(nm)
        if string.find(l, key, 1, true) then hits[#hits + 1] = nm
        elseif #near < 8 and (string.find(l, "bkddh", 1, true) or string.find(l, "own_bk", 1, true)) then near[#near + 1] = nm end
    end
    if #hits > 0 then
        -- the one with a mesh rather than only a collision shape, when there are several
        local best = hits[1]
        for _, nm in ipairs(hits) do if not string.find(string.lower(nm), "physics", 1, true) then best = nm break end end
        S.bkModel[o.item] = best
        reskate.log("Quick Drop helper: tilt: model for " .. o.item .. ": " .. best .. (#hits > 1 and (" (also: " .. table.concat(hits, " | ", 2, math.min(#hits, 5)) .. ")") or ""))
        return best
    end
    -- (only remembered once the game listed anything, so it is looked for again otherwise)
    if #S.allBp > 0 then S.bkModel[o.item] = false end
    reskate.log(string.format("Quick Drop helper: tilt: no model for %s. Ray onto it: %s. Blueprints listed: %d. Build Kit-like names: %s",
        o.item, tostring(picked or (ho and "an object with no blueprint") or (hit and "the ground") or "nothing"), #S.allBp,
        #near > 0 and table.concat(near, " | ") or "none"), "warn")
    return false
end

-- online: a tilted copy in its place, the game's flat one underground; o is the object where it is placed
function FN.holdEntity(o)
    local id = o.id
    local tl = S.tilt[id]
    local h = S.tiltHeld[id]
    local remote = S.tiltRemote and S.tiltRemote[id] ~= nil
    if not h then
        if S.clock < (S.tiltAt[id] or 0) then return end
        if S.noBury and S.clock < (S.noBury[id] or 0) then return end
        if FN.entityCount() >= MAX_ENTITIES then S.tiltWhy = "at most " .. MAX_ENTITIES .. " tilted objects online" return end
        local bp = FN.modelForOnline(o)
        if not bp then
            S.tiltAt[id] = S.clock + 5000
            local plain = "online, " .. titleOf(o.item) .. " can't be tilted (its model wasn't found)"
            if S.tiltWhy ~= plain then
                reskate.log("Quick Drop helper: tilt: no model found for " .. o.item .. ", so it can't be shown tilted online")
            end
            S.tiltWhy = plain
            return
        end
        h = { mode = "entity", eid = entityId(id), bp = bp, pos = o.position, heading = o.heading or 0, at = -1e9, checkAt = S.clock, remote = remote }
        S.tiltHeld[id] = h
        S.tiltWhy = nil
        -- the flat one underground (one's own; another player's is put there by their game)
        if not remote and not S.buried[id] then
            S.buried[id] = { pos = o.position, wait = S.clock + 6000 }
            FN.queueBury(id, o.position - FN.BURYV, false)
        end
        S.tiltGrabs = (S.tiltGrabs or 0) + 1
        if S.tiltGrabs <= 30 then reskate.log(string.format("Quick Drop helper: tilt: showing %s tilted online (%s)", titleOf(o.item), bp)) end
    end
    if S.clock - h.at < 120 then return end
    local q = fullTurn(h.heading, tl)
    local sc = o.scale or 1
    local key = string.format("%.5f %.5f %.5f %.5f %.3f", q[1], q[2], q[3], q[4], sc)
    if h.key == key then return end
    h.at = S.clock
    local ok, r1, r2 = pcall(reskate.entities.set, h.eid, h.bp, axesOf(h.pos, q, sc))
    if ok and r1 ~= false then
        h.key = key
    elseif not h.warned then
        h.warned = true
        reskate.log("Quick Drop helper: tilt: the tilted copy of " .. titleOf(o.item) .. " was refused: " .. tostring(ok and r2 or r1), "warn")
    end
end

-- offline: holds an object with physics (if not yet) and gives it its tilt; o is the object as placed
function FN.holdPhysics(o)
    local tl = S.tilt[o.id]
    local h = S.tiltHeld[o.id]
    if not h then
        if S.clock < (S.tiltAt[o.id] or 0) then return end
        -- still underground from playing online: put back up first
        if S.buried[o.id] then return end
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
        h = { mode = "physics", off = m.position - o.position, q0 = { r.x or r[1], r.y or r[2], r.z or r[3], r.w or r[4] }, at = -1e9, pos = o.position, heading = o.heading or 0,
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
-- Online tilted copies (world objects) are switched off: after testing them, players in the session stopped
-- seeing each other's Quick Drop objects until the game was restarted. Online, tilts show through a park mod.
FN.ONLINE_COPIES = false
function FN.holdTilted(o)
    if FN.online() then
        if FN.ONLINE_COPIES then FN.holdEntity(o) return end
        local plain = "online, tilts show for everyone only through a park mod (Park tab: Save as park mod)"
        if S.tiltWhy ~= plain then
            reskate.log("Quick Drop helper: tilt: " .. plain)
            pcall(reskate.ui.toast, "Tilt: " .. plain)
        end
        S.tiltWhy = plain
        return
    end
    FN.holdPhysics(o)
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
    S.netDue = true
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
        -- (other players' tilts are theirs to keep)
        if o and tilted(id) and not S.tiltRemote[id] then
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
-- the object e (item, x, y, z, turn) stands for: where it was placed, or 30 m under it (hidden while online)
local function findPlaced(list, e, taken)
    for _, o in ipairs(list) do
        if not taken[o.id] and o.item == e[1] and math.abs(wrap((o.heading or 0) - e[5])) < 0.01
            and math.abs(o.position.x - e[2]) < 0.02 and math.abs(o.position.z - e[4]) < 0.02 then
            if math.abs(o.position.y - e[3]) < 0.02 then return o, false end
            if math.abs(o.position.y - (e[3] - FN.BURY)) < 0.02 then return o, true end
        end
    end
    return nil
end
-- the kept tilts of the objects on this map
function FN.matchTilts()
    if not (S.known and S.tiltStore) then return end
    local list = nil
    for _, e in ipairs(S.tiltStore[FN.mapName()] or {}) do
        local hit = false
        for id, o in pairs(S.known) do
            if not S.tilt[id] and o.item == e[1] and math.abs(o.position.x - e[2]) < 0.02 and math.abs(o.position.y - e[3]) < 0.02
                and math.abs(o.position.z - e[4]) < 0.02 and math.abs(wrap((o.heading or 0) - e[5])) < 0.01 then
                S.tilt[id] = { x = e[6], z = e[7] }
                S.tiltSrc[id] = e
                hit = true
                break
            end
        end
        -- not found where it was placed: maybe still underground from playing online (the plugin stopped, or
        -- the game closed, before it was put back)
        if not hit then
            list = list or reskate.objects.list()
            local o, under = findPlaced(list, e, S.tilt)
            if o and under then
                local real = V(e[2], e[3], e[4])
                S.buried[o.id] = { pos = real, wait = S.clock + 3000 }
                S.tilt[o.id] = { x = e[6], z = e[7] }
                S.tiltSrc[o.id] = e
                reskate.log("Quick Drop helper: tilt: found " .. titleOf(o.item) .. " still underground")
                if not FN.online() then FN.queueBury(o.id, real, true) end
                S.lastScan = math.min(S.lastScan, S.clock - 350)
            end
        end
    end
end

-- ---- sharing tilts online (reskate.net): each game sends the tilts of its own objects to the others
-- A message: { k = "ddh_tilts", v = 1, map, seq, part, parts, list = { { item, x, y, z, turn, tilt x, tilt z }, ... } }
S.tiltRemote = S.tiltRemote or {}   -- object id -> the player whose tilt it is
S.remoteSets = S.remoteSets or {}   -- player id -> { map, list }
S.netParts = S.netParts or {}
local NET_KEY = "ddh_tilts"
function FN.myTiltList()
    local list = {}
    for id, tl in pairs(S.tilt) do
        local o = S.known and S.known[id]
        if o and tilted(id) and not S.tiltRemote[id] then
            list[#list + 1] = { o.item, r3(o.position.x), r3(o.position.y), r3(o.position.z), math.floor((o.heading or 0) * 1e5 + 0.5) / 1e5,
                math.floor(tl.x * 1e5 + 0.5) / 1e5, math.floor(tl.z * 1e5 + 0.5) / 1e5 }
        end
    end
    return list
end
function FN.netSendTilts(to)
    if not (reskate.net and reskate.net.send) then return end
    local list = FN.myTiltList()
    S.netSeq = (S.netSeq or 0) + 1
    -- in parts small enough for one message each (at most 4082 bytes)
    local chunks, cur = {}, {}
    for _, e in ipairs(list) do
        cur[#cur + 1] = e
        if #cur >= 25 then chunks[#chunks + 1] = cur; cur = {} end
    end
    if #cur > 0 or #chunks == 0 then chunks[#chunks + 1] = cur end
    for i, c in ipairs(chunks) do
        local msg = { k = NET_KEY, v = 1, map = FN.mapName(), seq = S.netSeq, part = i, parts = #chunks, list = c }
        local okE, text = pcall(reskate.json.encode, msg)
        if okE and type(text) == "string" and #text <= 4000 then
            pcall(reskate.net.send, to or "all", text)
        end
    end
    S.netAt = S.clock
end
local function num(x, lim) return type(x) == "number" and x == x and math.abs(x) <= lim end
function FN.netReceive(from, message)
    if type(message) ~= "string" or #message > 4082 or not string.find(message, NET_KEY, 1, true) then return end
    local ok, m = pcall(reskate.json.decode, message)
    if not (ok and type(m) == "table" and m.k == NET_KEY and m.v == 1 and type(m.list) == "table") then return end
    local who = type(from) == "table" and tostring(from.id or from.name or "?") or tostring(from)
    if not (num(m.seq, 1e9) and num(m.part, 100) and num(m.parts, 100) and m.part >= 1 and m.part <= m.parts) then return end
    local clean = {}
    for _, e in ipairs(m.list) do
        if type(e) == "table" and type(e[1]) == "string" and #e[1] <= 255 and num(e[2], 1e5) and num(e[3], 1e5) and num(e[4], 1e5)
            and num(e[5], 10) and num(e[6], 4) and num(e[7], 4) and #clean < 200 then
            clean[#clean + 1] = { e[1], e[2], e[3], e[4], e[5], e[6], e[7] }
        end
    end
    local p = S.netParts[who]
    if not p or p.seq ~= m.seq then p = { seq = m.seq, parts = m.parts, got = 0, lists = {} }; S.netParts[who] = p end
    if not p.lists[m.part] then p.lists[m.part] = clean; p.got += 1 end
    if p.got < p.parts then return end
    local all = {}
    for i = 1, p.parts do for _, e in ipairs(p.lists[i] or {}) do all[#all + 1] = e end end
    S.netParts[who] = nil
    S.remoteSets[who] = { map = tostring(m.map or ""), list = all }
    S.remoteDirty = true
end
-- other players' tilts on the objects here
function FN.applyRemote()
    S.remoteDirty = false
    local list = reskate.objects.list()
    local map = FN.mapName()
    local taken, now = {}, {}
    -- one's own tilted objects are never someone else's
    for id in pairs(S.tilt) do if not S.tiltRemote[id] then taken[id] = true end end
    for who, set in pairs(S.remoteSets) do
        if set.map == map then
            for _, e in ipairs(set.list) do
                local o, under = findPlaced(list, e, taken)
                if o then
                    taken[o.id] = true
                    now[o.id] = who
                    local real = V(e[2], e[3], e[4])
                    local old = S.tilt[o.id]
                    if not old or math.abs(old.x - e[6]) > 1e-4 or math.abs(old.z - e[7]) > 1e-4 then S.tilt[o.id] = { x = e[6], z = e[7] } end
                    S.tiltRemote[o.id] = who
                    if under then S.buried[o.id] = { pos = real, wait = S.clock + 3000 } end
                    local h = S.tiltHeld[o.id]
                    if h and h.mode == "entity" and len(h.pos - real) > 0.01 then letGo(o.id) end
                end
            end
        end
    end
    -- tilts the others no longer have
    for id in pairs(S.tiltRemote) do
        if not now[id] then
            if S.tiltHeld[id] then letGo(id) end
            S.tilt[id] = nil
            S.tiltRemote[id] = nil
            S.buried[id] = nil
        end
    end
end
function FN.netTick()
    if not FN.ONLINE_COPIES then return end
    if not FN.online() then
        if next(S.remoteSets) then S.remoteSets = {}; S.remoteDirty = true end
    else
        -- one's own tilts: when they change, and every 15 seconds (for anyone who missed them)
        if (S.netDue and S.clock - (S.netAt or -1e9) > 1000) or (S.clock - (S.netAt or -1e9) > 15000 and next(FN.myTiltList()) ~= nil) then
            S.netDue = false
            FN.netSendTilts("all")
        end
    end
    if S.remoteDirty or (next(S.remoteSets) and S.clock - (S.remoteAt or -1e9) > 1000) then
        S.remoteAt = S.clock
        FN.applyRemote()
    end
end
-- (messages from other players only for the online tilted copies, which are switched off: no need to listen)
if FN.ONLINE_COPIES then pcall(reskate.on, "message", function(from, message) pcall(FN.netReceive, from, message) end) end
pcall(reskate.on, "player_joined", function(p) S.netDue = true end)
pcall(reskate.on, "player_left", function(p)
    local who = type(p) == "table" and tostring(p.id or p.name or "?") or tostring(p)
    if S.remoteSets[who] then S.remoteSets[who] = nil; S.remoteDirty = true end
end)

-- every tick: the picked object is let go while it is being moved; every other tilted object is held tilted
function FN.tiltTick()
    if not S.tiltStore then FN.loadTilts() end
    -- online or offline changed: let go of everything and hold it again the other way
    local mode = FN.online() and "entity" or "physics"
    if S.tiltMode ~= mode then
        if S.tiltMode then
            reskate.log("Quick Drop helper: tilt: now " .. (mode == "entity" and "online (tilted copies)" or "offline (physics)"))
            for id in pairs(S.tiltHeld) do letGo(id) end
        end
        S.tiltMode = mode
        S.tiltWhy = nil
        S.tiltAt = {}
    end
    pcall(FN.netTick)
    FN.buryTick()
    if S.clock - (S.tiltMatchAt or -1e9) > 1000 then
        S.tiltMatchAt = S.clock
        FN.matchTilts()
        -- objects gone from the park: forget them
        for id, h in pairs(S.tiltHeld) do
            if not (S.known and S.known[id]) then
                if type(h) == "table" and h.mode == "entity" then pcall(reskate.entities.remove, h.eid) end
                S.tiltHeld[id] = nil
            end
        end
        for id in pairs(S.tilt) do if S.known and not S.known[id] then S.tilt[id] = nil; S.tiltRemote[id] = nil end end
        -- offline: anything still underground goes back up
        if mode == "physics" then
            for id, b in pairs(S.buried) do
                local queued = false
                for _, e in ipairs(S.buryQ) do if e.id == id then queued = true end end
                if not queued and S.clock > (b.wait or 0) and S.known and S.known[id] and not S.tiltRemote[id] then
                    b.wait = S.clock + 3000
                    FN.queueBury(id, b.pos, true)
                end
            end
        end
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
            if h and h.mode == "entity" then
                -- online: moved by something else (Quick Drop), or the game lost the copy
                if S.clock - h.checkAt > 500 then
                    h.checkAt = S.clock
                    local b = S.buried[id]
                    local rp = h.reported
                    if not h.remote and b and rp and S.clock > (b.wait or 0) and len(rp - (b.pos - FN.BURYV)) > 0.05 then
                        local queued = false
                        for _, e in ipairs(S.buryQ) do if e.id == id then queued = true end end
                        if len(rp - b.pos) < 0.05 then
                            -- still up where it was placed: put it underground (again)
                            if not queued then
                                b.wait = S.clock + 6000
                                FN.queueBury(id, b.pos - FN.BURYV, false)
                            end
                        elseif not queued then
                            -- moved by something else (Quick Drop): hold it again from its new place
                            reskate.log(string.format("Quick Drop helper: tilt: %s was moved (to %.2f, %.2f, %.2f): showing it again", titleOf(o.item), rp.x, rp.y, rp.z))
                            pcall(reskate.entities.remove, h.eid)
                            S.buried[id] = nil
                            S.tiltHeld[id] = nil; h = nil
                        end
                    end
                    if h then
                        local okS, st = pcall(reskate.entities.status, h.eid)
                        if okS and st == "missing" and not h.missingLogged then
                            h.missingLogged = true
                            reskate.log("Quick Drop helper: tilt: the model " .. h.bp .. " isn't loaded on this map, so its tilted copy can't show", "warn")
                        elseif okS and st == nil and h.key then
                            h.key = nil   -- (taken away by the game: made again)
                        end
                    end
                end
            elseif h and S.clock - h.checkAt > 500 then
                -- really changed by the game (Quick Drop, the park editor, replaced): hold it again from its new place
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
-- Online, tilts made here show only for players who have this plugin (see tilting). A park mod shows them for
-- everyone: it lists every object with its whole turn, and in multiplayer the host loads it (Build > Park mods). The
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
    -- (as the editor sees them: a tilted object where it was placed, not underground or where its body is)
    local list = FN.objectsNow()
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

-- shared with the parts after this one
PE.letGo = letGo
end
