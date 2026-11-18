-- DDH Park Editor, part03_tilt_parkmod: tilting, and saving the park as a park mod.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local MAX_HELD = PE.MAX_HELD
local S = PE.S
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

-- shared with the parts after this one
PE.letGo = letGo
end
