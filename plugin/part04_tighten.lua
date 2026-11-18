-- DDH Park Editor, part04_tighten: closing the last gap after a snap.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local S = PE.S
local V = PE.V
local boxLog = PE.boxLog
local cornersOf = PE.cornersOf
local dot = PE.dot
local lastApplied = PE.lastApplied
local len = PE.len
local norm = PE.norm
local saveSize = PE.saveSize
local tiltOf = PE.tiltOf
local titleOf = PE.titleOf
local worldShape = PE.worldShape

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
        for _, o in ipairs(FN.objectsNow()) do objs[o.id] = o end
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

-- shared with the parts after this one
PE.armTighten = armTighten
end
