-- DDH Park Editor, part10_sets: sets: saving a build and placing it anywhere.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local S = PE.S
local UI = PE.UI
local V = PE.V
local clamp = PE.clamp
local len = PE.len
local localOutline = PE.localOutline
local poseOf = PE.poseOf
local rotY = PE.rotY
local say = PE.say
local select = PE.select
local snapTurned = PE.snapTurned
local startGrab = PE.startGrab
local wrap = PE.wrap

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
        local have = FN.catalogHave()
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
        local shapes, tops = {}, {}
        local ylo, yhi = math.huge, -math.huge
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
            local bx = S.itemBox[e.item]
            local top = (e.y or 0) + (bx and bx[2].y * k or 0.5)
            shapes[#shapes + 1] = w
            tops[#shapes] = top
            ylo, yhi = math.min(ylo, top), math.max(yhi, top)
        end
        -- low pieces first and dim, the highest last and brightest: the layout reads like a map
        local order = {}
        for i = 1, #shapes do order[i] = i end
        table.sort(order, function(i, j) return tops[i] < tops[j] end)
        local span = yhi - ylo
        local sw, sh = math.max(hi.x - lo.x, 0.1), math.max(hi.z - lo.z, 0.1)
        local kk = math.min((b.x - a.x) / sw, (b.y - a.y) / sh)
        local ox, oy = (a.x + b.x) / 2, (a.y + b.y) / 2
        local mx, mz = (lo.x + hi.x) / 2, (lo.z + hi.z) / 2
        local n = 0
        local base = col or "#9fd8ff"
        if #base == 9 then base = string.sub(base, 1, 7) end
        for _, si in ipairs(order) do
            local w = shapes[si]
            local f = span > 0.05 and (tops[si] - ylo) / span or 1
            local cc = base .. string.format("%02x", math.floor(110 + 145 * f))
            local sp = {}
            for i, q in ipairs(w) do sp[i] = V(ox + (q.x - mx) * kk, oy - (q.z - mz) * kk, 0) end
            if #sp >= 3 and #sp <= 8 then pcall(d.poly, d, sp, { colour = base .. string.format("%02x", math.floor(20 + 50 * f)), fill = true }) end
            for i = 1, #w do
                local p1, p2 = w[i], w[i % #w + 1]
                d:line(V(ox + (p1.x - mx) * kk, oy - (p1.z - mz) * kk, 0), V(ox + (p2.x - mx) * kk, oy - (p2.z - mz) * kk, 0), { colour = cc, thickness = 2 })
                n += 1
                if n > 600 then return end
            end
        end
    end
end)()

end
