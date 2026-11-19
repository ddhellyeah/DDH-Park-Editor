-- DDH Park Editor, part15_scan: scanning an object's shape with rays, for its outline.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local S = PE.S
local V = PE.V
local UP = PE.UP
local dot = PE.dot
local len = PE.len
local say = PE.say
local titleOf = PE.titleOf

-- An object the editor has no model edges for gets its shape by looking at it: a grid of rays straight down over
-- its box, each giving the height of what is there (its collision: what can be skated or bumped into). From those
-- heights come lines across it both ways (its top: a ramp's curve, a ledge, steps), its edges down to the ground
-- and its footprint on the ground. Done once per kind of object while one stands near (the game has collision
-- only near the skater), a few rays a tick (the game takes at most 64 a tick from a plugin, and the editor
-- casts its own as well). The result is kept like the model edges: x1, y1, z1, x2, y2, z2, ... in metres from the
-- middle of its base, as it stands unturned at size 1.

-- Outlines: an object's model edges when the editor has them (wires.lua: the Object Maker's objects), else its
-- scan.
FN.scans = {}               -- item -> lines, or false (could not be scanned: tried again later)
-- (rays: a raycast gives only where a ray first meets something, and costs about 0.02 ms; a pick also says what
-- it met, and costs about 2 ms. So the shape comes from raycasts on a fine grid, and picks only tell whose each
-- surface found is: a few for each)
local RAYS_A_TICK = 40      -- rays a tick (the game takes at most 64 a tick from a plugin, the editor's own too)
local STEP = 0.05           -- metres between rays at the finest (wider for big objects, see below)
local MAX_SIDE = 72         -- at most this many rays along a side
local GRID_RAYS = 2500      -- about this many grid rays at most
local EDGE_STEPS = 4        -- rays to find each edge exactly between two grid rays (to 1/16 of their spacing)
local CLIFF = 0.3           -- a height jump between neighbouring rays bigger than this is a wall, not a slope
-- time: scanning takes at most SCAN_MS of a tick, checked before every ray (a ray costs about 1 ms in a big
-- map, and ReSkate stops the plugin past 6 ms a tick on average over 5 s), and goes on the next tick. Without a clock, by count: RAYS_A_TICK rays, and the
-- lines worked out in steps of PACE_STEPS.
local SCAN_MS = 3
-- (when the tick is timed (part12): what the editor's own work leaves of TICK_MS, between SCAN_MS_MIN and _MAX;
-- ReSkate stops a plugin past 6 ms a tick on average)
local TICK_MS, SCAN_MS_MIN, SCAN_MS_MAX = 5, 1.5, 4.5
local scanMs = SCAN_MS
local PACE_STEPS = 400
local nowMs = nil
do
    local okc, t = pcall(function() return os.clock() end)
    if okc and type(t) == "number" then nowMs = function() return os.clock() * 1000 end end
end
local tickStart = 0
local function overTime(extra) return nowMs ~= nil and nowMs() - tickStart + (extra or 0) > scanMs end
-- (inside the working out, which runs as a coroutine: a pause till the next tick once this tick's time is used)
local paceN = 0
local function pace()
    paceN += 1
    if nowMs then
        if paceN % 32 ~= 0 or not overTime() then return end
    elseif paceN % PACE_STEPS ~= 0 then return end
    if coroutine.isyieldable() then coroutine.yield() end
end
-- scans are kept between games (each kind of object is scanned once); the number changes when scanning does
local SKEY = "scan8:"
FN.scanLoaded = {}
-- (forgetting every saved scan: a new generation of keys)
local function skey(item)
    local okg, gen = pcall(reskate.storage.get, "scanGen")
    return SKEY .. tostring((okg and tonumber(gen)) or 0) .. ":" .. item
end

function FN.scanOf(item)
    local s = FN.scans[item]
    if s then return s end
    if s == nil and item and not FN.scanLoaded[item] then
        FN.scanLoaded[item] = true
        local ok, str = pcall(reskate.storage.get, skey(item))
        if ok and type(str) == "string" and #str > 0 then
            local a = {}
            for num in string.gmatch(str, "-?%d+") do a[#a + 1] = tonumber(num) * 0.01 end
            if #a >= 6 and #a % 6 == 0 then FN.scans[item] = a; return a end
        end
    end
    return nil
end
local function saveScan(item, lines)
    local t = {}
    for i, v in ipairs(lines) do t[i] = tostring(math.floor(v * 100 + 0.5)) end
    pcall(reskate.storage.set, skey(item), table.concat(t, ","))
end
-- the outline lines for an object: its model's edges, else its scan
function FN.outlineOf(item)
    return FN.wireOf(item) or FN.scanOf(item)
end
-- does this kind of object need a scan? (no model edges and no scan yet)
local function needsScan(item)
    return not FN.wireOf(item) and not FN.scanOf(item)
end

-- whose is a ray's hit? "own": the object being scanned (the game gives the hit object's place, and it is this
-- one's); "loose": inside its box, but the game gives no place for what was hit or another place (the map's
-- own ground, steps or decks, or a piece of collision placed apart); nil: not on its box, or nearer another
-- placed object. Loose hits are kept only when a scan gets no own hits at all (see the grid's end).
local function hitKind(job, hit)
    if not (type(hit) == "table" and hit.position and hit.object) then return nil end
    local d = hit.position - job.pos
    local x, y, z = dot(d, job.ax) / job.sc, d.y / job.sc, dot(d, job.az) / job.sc
    local m = 0.05 / job.sc
    local lo, hi = job.lo, job.hi
    if x < lo.x - m or x > hi.x + m or y < lo.y - m or y > hi.y + m or z < lo.z - m or z > hi.z + m then return nil end
    local ob = hit.object
    local okp, op = pcall(function() return ob.position end)
    if not okp then op = nil end
    if op and len(op - job.pos) <= 0.05 then return "own" end
    if op then
        local dj = len(job.pos - op) - 0.01
        for _, o in ipairs(FN.nearObjects and FN.nearObjects(op, dj) or {}) do
            if o.id ~= job.id and len(o.position - op) < dj then return nil end
        end
    end
    -- (once per scan, what the game says about such a hit, to learn what it is)
    if not job.looseSaid then
        job.looseSaid = true
        local parts = {}
        local okk = pcall(function()
            for k, v in pairs(ob) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
        end)
        if not okk or #parts == 0 then parts = { "(" .. typeof(ob) .. ") " .. tostring(ob) } end
        table.sort(parts)
        reskate.log(string.format("Quick Drop helper: scan %s: a hit on something else at height %.2f: %s", tostring(job.item),
            y * job.sc, table.concat(parts, ", ")))
    end
    return "loose"
end

-- the next object to scan: for the kind of object held, picked, aimed at or in the group, when that kind has no
-- scan yet. One that stands still is scanned (rays need it to stay put): another of the same kind if there is
-- one (the one a copy was made from), else the held one itself once it has been left still for a moment.
local function still(o)
    if not (S.sel and o.id == S.sel.id) then return true end
    if S.grab or S.drag or S.dirty or S.padRaw then
        -- held: still once it has not moved for 0.6 s and the game has it where it was sent
        local t = S.target
        if not (t and len(t.pos - o.position) < 0.01) then S.stillSince = nil return false end
        if S.drag and S.drag.moved then S.stillSince = nil return false end
        S.stillSince = S.stillSince or S.clock
        return S.clock - S.stillSince > 600
    end
    return true
end
local function nextJob()
    local items, order = {}, {}
    local function want(o)
        if o and o.item and not items[o.item] then items[o.item] = true; order[#order + 1] = o.item end
    end
    if S.sel and S.known then want(S.known[S.sel.id]) end
    want(S.aim)
    for id in pairs(S.group or {}) do if S.known then want(S.known[id]) end end
    for _, item in ipairs(order) do
        local b = S.itemBox[item]
        local st = FN.scans[item]
        local again = st == false and S.clock - (S.scanFailAt[item] or -1e9) < 8000
        if b and needsScan(item) and not again then
            -- one of this kind standing still (not tilted), the nearest to the view first
            local best, bd = nil, math.huge
            local cam = reskate.camera.get()
            local cp = cam and cam.position
            for _, o in pairs(S.known or {}) do
                if o.item == item and still(o) and not (PE.tiltOf and PE.tiltOf(o.id)) then
                    local d = cp and len(o.position - cp) or 0
                    if S.sel and o.id == S.sel.id then d += 1000 end
                    if d < bd then best, bd = o, d end
                end
            end
            if best then return best, b end
        end
    end
    return nil
end
S.scanFailAt = {}

local function startJob(o, b)
    local sc = o.scale or 1
    local h = o.heading or 0
    local lo, hi = b[1], b[2]
    local w, dz = hi.x - lo.x, hi.z - lo.z
    local step = math.max(STEP, math.sqrt(w * sc * dz * sc / GRID_RAYS))
    -- (the spacing at size 1: the grid is in the object's own measures)
    step = step / sc
    local nx = math.max(3, math.min(MAX_SIDE, math.floor(w / step) + 1))
    local nz = math.max(3, math.min(MAX_SIDE, math.floor(dz / step) + 1))
    -- (an odd number: one ray goes down the middle, so a thin rail is still met)
    if nx % 2 == 0 then nx += 1 end
    if nz % 2 == 0 then nz += 1 end
    -- (the outermost rays a little in from the box's sides, so they meet the object and not its edge)
    local e = math.min(0.02 / sc, w * 0.05, dz * 0.05)
    local xs, zs = {}, {}
    for i = 1, nx do xs[i] = lo.x + e + (w - 2 * e) * (i - 1) / (nx - 1) end
    for j = 1, nz do zs[j] = lo.z + e + (dz - 2 * e) * (j - 1) / (nz - 1) end
    S.scanJob = { id = o.id, item = o.item, pos = o.position, sc = sc, ax = V(math.cos(h), 0, -math.sin(h)), az = V(math.sin(h), 0, math.cos(h)),
        lo = lo, hi = hi, xs = xs, zs = zs, nx = nx, nz = nz, k = 0, H = {}, hits = 0, SX = {}, SZ = {}, hard = {},
        L = {}, cross = {}, own = 0, loose = 0, rays = 0, ticks = 0, tickRays = 0, filled = 0,
        picks = 0, casts = 0, surfaces = 0, mixed = 0, multi = 0, refused = 0,
        gx = (xs[2] - xs[1]), gz = (zs[2] - zs[1]),
        top = o.position.y + hi.y * sc + 1, bottom = o.position.y + lo.y * sc - 0.5 }
    if not S.scanSaid then S.scanSaid = true; say("Scanning the shape of " .. titleOf(o.item) .. "...") end
end

-- the heights found, as lines
local function dp(pts, a, b, tol, out)
    local pa, pb = pts[a], pts[b]
    local ab = pb - pa
    local l = len(ab)
    local k, kd = nil, tol
    for i = a + 1, b - 1 do
        local d
        if l < 1e-9 then d = len(pts[i] - pa) else
            local t = math.max(0, math.min(1, dot(pts[i] - pa, ab) / (l * l)))
            d = len(pts[i] - (pa + ab * t))
        end
        if d > kd then k, kd = i, d end
    end
    if k then dp(pts, a, k, tol, out); dp(pts, k, b, tol, out) else out[#out + 1] = { pa, pb } end
end
-- the outline from the heights: a surface is made of them (two triangles between each four neighbours, with walls
-- down to the ground round its edge), and only its sharp edges are kept (where it bends 20 degrees or more: a
-- pyramid's ridges, a top's rim, a wall's corners) and its footprint. Flat and gently curved parts get no lines.
-- A jagged run of edges (a curved seam crossing the grid) is trimmed of its loose ends and smoothed into a line.
local nearAt -- (below: a ray near a part known to be the object's; the outline's edges cast a few more)
local CREASE = math.cos(math.rad(20))
local CORNER = math.cos(math.rad(50))
local function ekey(a, b) if a > b then a, b = b, a end return a .. ":" .. b end
local function triN(P, a, b, c)
    local u, v = P[b] - P[a], P[c] - P[a]
    local n = V(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
    local l = len(n)
    if l < 1e-12 then return nil end
    return n * (1 / l)
end
local function finish(job)
    local H, nx, nz, xs, zs = job.H, job.nx, job.nz, job.xs, job.zs
    local g = math.max(job.gx, job.gz)
    local P, tris = {}, {}
    local function top(i, j)
        local k = (j - 1) * nx + i
        local y = H[k]
        if not y then return nil end
        if not P[k] then P[k] = V(xs[i] + (job.SX[k] or 0), y, zs[j] + (job.SZ[k] or 0)) end
        return k
    end
    local G = {}
    local function ground(k)
        local gk = G[k]
        if not gk then gk = -k; G[k] = gk; P[gk] = V(P[k].x, 0, P[k].z) end
        return gk
    end
    -- the top: a square between four neighbours that were all hit (not across a wall), cut along the diagonal
    -- that bends most (so a ridge running corner to corner is followed, not crossed)
    local qedge, quadsides, cliff, used = {}, {}, {}, {}
    for j = 1, nz - 1 do
        for i = 1, nx - 1 do
            pace()
            local a, b, c, d = top(i, j), top(i + 1, j), top(i + 1, j + 1), top(i, j + 1)
            if a and b and c and d then
                local sides = { { a, b }, { b, c }, { c, d }, { d, a } }
                local wall = false
                for _, e in ipairs(sides) do if job.hard[ekey(e[1], e[2])] then wall = true end end
                if wall then
                    for _, e in ipairs(sides) do cliff[ekey(e[1], e[2])] = true end
                else
                    local n1, n2, n3, n4 = triN(P, a, b, c), triN(P, a, c, d), triN(P, a, b, d), triN(P, b, c, d)
                    local f1 = (n1 and n2) and math.abs(dot(n1, n2)) or 1
                    local f2 = (n3 and n4) and math.abs(dot(n3, n4)) or 1
                    if f1 <= f2 then
                        tris[#tris + 1] = { a, b, c }; tris[#tris + 1] = { a, c, d }
                    else
                        tris[#tris + 1] = { a, b, d }; tris[#tris + 1] = { b, c, d }
                    end
                    used[a], used[b], used[c], used[d] = true, true, true, true
                    for _, e in ipairs(sides) do
                        local kk = ekey(e[1], e[2])
                        qedge[kk] = (qedge[kk] or 0) + 1
                        quadsides[#quadsides + 1] = { e[1], e[2], kk }
                    end
                end
            end
        end
    end
    -- the squares with some corners hit and some not (along a footprint's or a hole's edge): the part over the
    -- hit corners, cut off where the edge crosses each side (found by the edge rays; halfway when not known).
    -- Each crossing is one point, shared by the two squares either side of it, so the edge is one smooth line.
    local crossId, nextId = {}, nx * nz
    local function crossing(kh, km, ih, jh, im, jm)
        local kk = ekey(kh, km)
        local id = crossId[kk]
        if id then return id end
        local c = job.cross[kk]
        local e = (c and c.from == kh) and c.e or 0.5
        nextId += 1; id = nextId; crossId[kk] = id
        local x = xs[ih] + (job.SX[kh] or 0) + (xs[im] - xs[ih]) * e
        local z = zs[jh] + (job.SZ[kh] or 0) + (zs[jm] - zs[jh]) * e
        -- (its height: the surface carried on that far, by the slope from the grid point behind the hit one; on a
        -- curve, the edge then runs smoothly along it and not in steps)
        local y = P[kh].y
        local ib, jb = 2 * ih - im, 2 * jh - jm
        if c and c.from == kh and c.h then
            -- (measured by the edge rays, just inside the edge)
            y = c.h
        elseif ib >= 1 and ib <= nx and jb >= 1 and jb <= nz then
            local kb = (jb - 1) * nx + ib
            local hb = H[kb]
            if hb and not job.hard[ekey(kh, kb)] then y = math.max(0, y + (y - hb) * e) end
        end
        P[id] = V(x, y, z)
        return id
    end
    for j = 1, nz - 1 do
        for i = 1, nx - 1 do
            pace()
            local cs = { { i, j }, { i + 1, j }, { i + 1, j + 1 }, { i, j + 1 } }
            local ks, nhit = {}, 0
            for c = 1, 4 do ks[c] = top(cs[c][1], cs[c][2]); if ks[c] then nhit += 1 end end
            local wall = false
            for c = 1, 4 do
                local c2 = c % 4 + 1
                if ks[c] and ks[c2] and job.hard[ekey(ks[c], ks[c2])] then wall = true end
            end
            if nhit >= 1 and nhit <= 3 and not wall then
                -- (two hit corners across a diagonal: two separate corners, each cut off on its own)
                local diag = nhit == 2 and ((ks[1] and ks[3]) or (ks[2] and ks[4]))
                local polys = {}
                if diag then
                    for c = 1, 4 do
                        if ks[c] then
                            local cp, cn = (c + 2) % 4 + 1, c % 4 + 1
                            local kc = ks[c]
                            local idp = crossing(kc, (cs[cp][2] - 1) * nx + cs[cp][1], cs[c][1], cs[c][2], cs[cp][1], cs[cp][2])
                            local idn = crossing(kc, (cs[cn][2] - 1) * nx + cs[cn][1], cs[c][1], cs[c][2], cs[cn][1], cs[cn][2])
                            polys[#polys + 1] = { idp, kc, idn }
                        end
                    end
                else
                    local poly = {}
                    for c = 1, 4 do
                        local c2 = c % 4 + 1
                        if ks[c] then poly[#poly + 1] = ks[c] end
                        if (ks[c] ~= nil) ~= (ks[c2] ~= nil) then
                            local h, m = c, c2
                            if not ks[c] then h, m = c2, c end
                            poly[#poly + 1] = crossing(ks[h], (cs[m][2] - 1) * nx + cs[m][1], cs[h][1], cs[h][2], cs[m][1], cs[m][2])
                        end
                    end
                    polys[1] = poly
                end
                for _, poly in ipairs(polys) do
                    for t = 2, #poly - 1 do tris[#tris + 1] = { poly[1], poly[t], poly[t + 1] } end
                    for t = 1, #poly do
                        local a, b = poly[t], poly[t % #poly + 1]
                        local kk = ekey(a, b)
                        qedge[kk] = (qedge[kk] or 0) + 1
                        quadsides[#quadsides + 1] = { a, b, kk }
                        if a <= nx * nz then used[a] = true end
                    end
                end
            end
        end
    end
    -- walls down to the ground along its edge (a side of only one square, not at a wall), where it stands above
    -- the ground; on the ground already, that side is part of the footprint
    local foot, rimEdge, upright = {}, {}, {}
    local function side(a, b)
        rimEdge[ekey(a, b)] = true
        if P[a].y > 0.02 or P[b].y > 0.02 then
            local ga, gb = ground(a), ground(b)
            upright[ekey(a, ga)] = true; upright[ekey(b, gb)] = true
            tris[#tris + 1] = { a, b, gb }; tris[#tris + 1] = { a, gb, ga }
        else
            foot[ekey(a, b)] = true
        end
    end
    -- an edge piece between two crossings (a footprint's or a hole's edge, between grid lines): rays across its
    -- middle find where the edge really is there, and the piece is split there (a round arch comes out round).
    -- A piece found straight is left as it is.
    local function refine(a, b, depth)
        local pa, pb = P[a], P[b]
        local dx, dz = pb.x - pa.x, pb.z - pa.z
        local l = math.sqrt(dx * dx + dz * dz)
        -- (its height there taken as between its ends': a ray meeting something well off that is off the object. Not along the ground, where the object and the ground can't be told apart by height)
        local ref = (pa.y + pb.y) / 2
        if depth > 0 and l > 0.03 and ref > 0.05 then
            local mx, mz = (pa.x + pb.x) / 2, (pa.z + pb.z) / 2
            local nxv, nzv = -dz / l, dx / l
            local r = 0.5 * g
            -- (within half its height counts as on it: a steep top changes a lot in a few cm, and what lies off a
            -- hole's or a footprint's edge is the ground, well below)
            local tol = math.max(0.1, 0.5 * ref)
            local h1 = nearAt(job, mx + nxv * r, mz + nzv * r, ref, tol)
            local h2 = nearAt(job, mx - nxv * r, mz - nzv * r, ref, tol)
            if (h1 ~= nil) ~= (h2 ~= nil) then
                -- (from the side on it, s = 1, to the side off it, s = -1)
                local sIn = h1 and 1 or -1
                local lo, hi, hIn = 0, 1, h1 or h2
                for _ = 1, EDGE_STEPS do
                    local t = (lo + hi) / 2
                    local sOff = sIn * r * (1 - 2 * t)
                    local h = nearAt(job, mx + nxv * sOff, mz + nzv * sOff, ref, tol)
                    if h then lo = t; hIn = h else hi = t end
                end
                local sOff = sIn * r * (1 - (lo + hi))
                local m = V(mx + nxv * sOff, hIn, mz + nzv * sOff)
                -- (off the straight line by more than 1 cm: kept, and both halves looked at again)
                if math.abs((m.x - pa.x) * nxv + (m.z - pa.z) * nzv) > 0.01 then
                    nextId += 1
                    local id = nextId
                    P[id] = m
                    tris[#tris + 1] = { a, id, b }
                    refine(a, id, depth - 1)
                    refine(id, b, depth - 1)
                    return
                end
            end
        end
        side(a, b)
    end
    local rim = {}
    for _, q in ipairs(quadsides) do
        pace()
        if qedge[q[3]] == 1 and not cliff[q[3]] then
            if q[1] > nx * nz and q[2] > nx * nz then rim[#rim + 1] = q else side(q[1], q[2]) end
        end
    end
    for _, q in ipairs(rim) do refine(q[1], q[2], 1) end
    -- (the rays are done: the object may move now)
    job.phase = "lines"
    -- every edge with the triangles on it
    local edges, normal = {}, {}
    for t, tr in ipairs(tris) do
        pace()
        local n = triN(P, tr[1], tr[2], tr[3])
        if n then
            normal[t] = n
            for _, e in ipairs({ { tr[1], tr[2] }, { tr[2], tr[3] }, { tr[3], tr[1] } }) do
                local kk = ekey(e[1], e[2])
                local E = edges[kk]
                if not E then E = { math.min(e[1], e[2]), math.max(e[1], e[2]), {} }; edges[kk] = E end
                table.insert(E[3], t)
            end
        end
    end
    -- the sharp ones, and those with one triangle (the footprint, a wall's rim and foot)
    local keep = {}
    for kk, E in pairs(edges) do
        pace()
        local f = E[3]
        -- (an edge of its top down to the ground is always drawn, however steep the top is there)
        if #f ~= 2 or foot[kk] then keep[#keep + 1] = { E[1], E[2], false }
        elseif upright[kk] then
            -- (a wall's upright edge, down from its rim to the ground: only at a real corner of it, where the rim
            -- turns 50 degrees or more; a curved rim's small turns draw no lines down)
            if math.abs(dot(normal[f[1]], normal[f[2]])) < CORNER then keep[#keep + 1] = { E[1], E[2], false } end
        -- (a bend in its top is not taken from the triangles, whose edges zigzag across a curved bend: see creases)
        elseif rimEdge[kk] then keep[#keep + 1] = { E[1], E[2], false } end
    end
    -- loose ends of bends (short, touching nothing at one end) trimmed, twice over
    for _ = 1, 2 do
        local deg = {}
        for _, e in ipairs(keep) do deg[e[1]] = (deg[e[1]] or 0) + 1; deg[e[2]] = (deg[e[2]] or 0) + 1 end
        local nk = {}
        for _, e in ipairs(keep) do
            if not (e[3] and (deg[e[1]] == 1 or deg[e[2]] == 1) and len(P[e[1]] - P[e[2]]) < 1.5 * g) then nk[#nk + 1] = e end
        end
        keep = nk
    end
    -- joined into lines through points where two meet; a line of bends only is smoothed (a jagged seam becomes
    -- its curve) and dropped when very short; each straightened (within 1.5 cm for bends, 3 cm else)
    local adj = {}
    for si, e in ipairs(keep) do
        adj[e[1]] = adj[e[1]] or {}; table.insert(adj[e[1]], si)
        adj[e[2]] = adj[e[2]] or {}; table.insert(adj[e[2]], si)
    end
    local done, lines = {}, {}
    local function seg(a, b)
        lines[#lines + 1] = a.x; lines[#lines + 1] = a.y; lines[#lines + 1] = a.z
        lines[#lines + 1] = b.x; lines[#lines + 1] = b.y; lines[#lines + 1] = b.z
    end
    for s0 = 1, #keep do
        pace()
        if not done[s0] then
            done[s0] = true
            local chain = { keep[s0][1], keep[s0][2] }
            local allBend = keep[s0][3]
            for side = 1, 2 do
                while true do
                    local v = side == 1 and chain[#chain] or chain[1]
                    local nb = adj[v]
                    if not nb or #nb ~= 2 then break end
                    local nxt = nil
                    for _, si in ipairs(nb) do if not done[si] then nxt = si end end
                    if not nxt then break end
                    done[nxt] = true
                    local E = keep[nxt]
                    allBend = allBend and E[3]
                    local u = E[1] == v and E[2] or E[1]
                    if side == 1 then chain[#chain + 1] = u else table.insert(chain, 1, u) end
                end
            end
            local pts = {}
            for i, k in ipairs(chain) do pts[i] = P[k] end
            local L = 0
            for i = 1, #pts - 1 do L += len(pts[i + 1] - pts[i]) end
            if not (allBend and L < 2 * g) then
                if allBend and #pts > 2 then
                    for _ = 1, 4 do
                        local np = { pts[1] }
                        for i = 2, #pts - 1 do np[i] = pts[i - 1] * 0.25 + pts[i] * 0.5 + pts[i + 1] * 0.25 end
                        np[#pts] = pts[#pts]
                        pts = np
                    end
                end
                local out = {}
                dp(pts, 1, #pts, allBend and 0.015 or 0.03, out)
                for _, sg in ipairs(out) do if len(sg[2] - sg[1]) > 1e-4 then seg(sg[1], sg[2]) end end
            end
        end
    end
    -- the bends in its top (a coping, a ridge, where a slope meets a deck): along every row and every column of
    -- the grid, where its slope turns 20 degrees or more, the bend is where the straight slope before it and the
    -- straight slope after it meet (found well within a grid step, even for a bend running slantwise or round).
    -- Those points, joined to their neighbours along the bend, smoothed a little, are its lines.
    local cpts = {}
    local function bendsAlong(n, at, coord, put)
        -- at(i): the height at the i-th point along the line, or nil; coord(i): its x or z
        local str = {}
        local function strength(i)
            if i < 3 or i > n - 2 then return 0 end
            local h0, h1, h3, h4, h2 = at(i - 2), at(i - 1), at(i + 1), at(i + 2), at(i)
            if not (h0 and h1 and h2 and h3 and h4) then return 0 end
            -- (not across a wall: walls are drawn as walls)
            if math.max(math.abs(h1 - h0), math.abs(h2 - h1), math.abs(h3 - h2), math.abs(h4 - h3)) > CLIFF then return 0 end
            local dx = coord(i) - coord(i - 1)
            local sl, sr = (h1 - h0) / dx, (h4 - h3) / dx
            local c = (1 + sl * sr) / math.sqrt((1 + sl * sl) * (1 + sr * sr))
            return 1 - c, sl, sr, h1, h3
        end
        for i = 1, n do str[i] = strength(i) end
        for i = 3, n - 2 do
            local st, sl, sr, h1, h3 = strength(i)
            if st > 1 - CREASE and st >= str[i - 1] and st > str[i + 1] then
                -- (the two slopes' lines meet: left one through i-1, right one through i+1)
                local x1, x3 = coord(i - 1), coord(i + 1)
                local x = (h3 - h1 + sl * x1 - sr * x3) / (sl - sr)
                if x ~= x then x = coord(i) end
                x = math.max(x1, math.min(x3, x))
                put(x, h1 + sl * (x - x1))
            end
        end
    end
    for j = 1, nz do
        pace()
        bendsAlong(nx, function(i) return H[(j - 1) * nx + i] end, function(i) return xs[i] end,
            function(x, y) cpts[#cpts + 1] = V(x, y, zs[j]) end)
    end
    for i = 1, nx do
        pace()
        bendsAlong(nz, function(j) return H[(j - 1) * nx + i] end, function(j) return zs[j] end,
            function(z, y) cpts[#cpts + 1] = V(xs[i], y, z) end)
    end
    -- (a bend found both along a row and along a column: one point)
    local merged = {}
    for _, p in ipairs(cpts) do
        pace()
        local near = nil
        for _, m in ipairs(merged) do
            if math.abs(m.p.x - p.x) < 0.6 * g and math.abs(m.p.z - p.z) < 0.6 * g and math.abs(m.p.y - p.y) < 0.1 then near = m break end
        end
        if near then
            near.n += 1
            near.p = near.p + (p - near.p) * (1 / near.n)
        else
            merged[#merged + 1] = { p = p, n = 1 }
        end
    end
    -- (joined into lines: from each end, on to the nearest point not yet used within 1.8 grid steps that goes on
    -- about the same way, turning less than 45 degrees; a sharper turn, as at a pyramid's top, ends the line)
    local usedP, bendLines = {}, {}
    local R = 1.8 * g
    local function nearestFrom(p, dir)
        local best, bd = nil, R
        for mi, m in ipairs(merged) do
            if not usedP[mi] then
                local d = m.p - p
                local dl = math.sqrt(d.x * d.x + d.z * d.z)
                if dl < bd and dl > 1e-6 then
                    local ok = true
                    if dir then ok = (d.x * dir.x + d.z * dir.z) / dl > 0.7 end
                    if ok then best, bd = mi, dl end
                end
            end
        end
        return best
    end
    for si = 1, #merged do
        pace()
        if not usedP[si] then
            usedP[si] = true
            local chain = { merged[si].p }
            for side = 1, 2 do
                while true do
                    local a = side == 1 and chain[#chain] or chain[1]
                    local b = side == 1 and chain[#chain - 1] or chain[2]
                    local dir = nil
                    if b then local d = a - b; local dl = math.sqrt(d.x * d.x + d.z * d.z); if dl > 1e-6 then dir = V(d.x / dl, 0, d.z / dl) end end
                    local ni = nearestFrom(a, dir)
                    if not ni then break end
                    usedP[ni] = true
                    if side == 1 then chain[#chain + 1] = merged[ni].p else table.insert(chain, 1, merged[ni].p) end
                end
            end
            -- (split where it turns sharply, measured over about two grid steps each way: a pyramid's ridges
            -- meeting at its top are separate lines, joined again at one point below)
            local pieces, startI = {}, 1
            local function far(i, dirn)
                local k = i
                while k + dirn >= 1 and k + dirn <= #chain do
                    k += dirn
                    local d = chain[k] - chain[i]
                    if d.x * d.x + d.z * d.z >= (1.6 * g) ^ 2 then break end
                end
                return k
            end
            local turnAt = {}
            for i = 2, #chain - 1 do
                local a, b = chain[far(i, -1)] - chain[i], chain[far(i, 1)] - chain[i]
                local la, lb = math.sqrt(a.x * a.x + a.z * a.z), math.sqrt(b.x * b.x + b.z * b.z)
                -- (cos of the angle between going in and going out: 1 straight on, -1 turning back)
                turnAt[i] = (la > 1e-6 and lb > 1e-6) and -(a.x * b.x + a.z * b.z) / (la * lb) or 1
            end
            for i = 2, #chain - 1 do
                if turnAt[i] < 0.6 and turnAt[i] <= (turnAt[i - 1] or 1) and turnAt[i] < (turnAt[i + 1] or 1) then
                    pieces[#pieces + 1] = { table.unpack(chain, startI, i) }
                    startI = i
                end
            end
            pieces[#pieces + 1] = { table.unpack(chain, startI, #chain) }
            for _, piece in ipairs(pieces) do
            chain = piece
            if #chain >= 3 then
                local pts = chain
                for _ = 1, 2 do
                    local np = { pts[1] }
                    for i = 2, #pts - 1 do np[i] = pts[i - 1] * 0.25 + pts[i] * 0.5 + pts[i + 1] * 0.25 end
                    np[#pts] = pts[#pts]
                    pts = np
                end
                local L = 0
                for i = 1, #pts - 1 do L += len(pts[i + 1] - pts[i]) end
                -- (a scrap of a few cm, as found right at a peak, is no line of its own)
                if L >= 1.5 * g then bendLines[#bendLines + 1] = pts end
            end
            end
        end
    end
    -- (ends of bend lines close together, as where a pyramid's ridges meet at its top: one point, where the lines
    -- run on to, each carried straight on from its last stretch and the meeting point their average)
    local ends = {}
    for li, pts in ipairs(bendLines) do
        ends[#ends + 1] = { li = li, first = true, p = pts[1], dir = pts[1] - pts[math.min(#pts, 3)] }
        ends[#ends + 1] = { li = li, first = false, p = pts[#pts], dir = pts[#pts] - pts[math.max(1, #pts - 2)] }
    end
    local joined = {}
    for a = 1, #ends do
        if not joined[a] then
            local group = { a }
            for b = a + 1, #ends do
                if not joined[b] and ends[b].li ~= ends[a].li and len(ends[b].p - ends[a].p) < 2.5 * g then group[#group + 1] = b end
            end
            if #group >= 2 then
                local c = V(0, 0, 0)
                for _, e in ipairs(group) do joined[e] = true; c = c + ends[e].p end
                c = c * (1 / #group)
                -- (its height: the highest the lines reach there, carried on, for a peak; else the average)
                local top = -math.huge
                for _, e in ipairs(group) do
                    local E = ends[e]
                    local dl = math.sqrt(E.dir.x * E.dir.x + E.dir.z * E.dir.z)
                    if dl > 1e-6 then
                        local t = ((c.x - E.p.x) * E.dir.x + (c.z - E.p.z) * E.dir.z) / (dl * dl)
                        top = math.max(top, E.p.y + E.dir.y * t)
                    end
                end
                if top > c.y and top - c.y < 0.5 then c = V(c.x, top, c.z) end
                for _, e in ipairs(group) do
                    local E = ends[e]
                    local pts = bendLines[E.li]
                    -- (its end moved there when close by, else a short line on to it)
                    local iEnd = E.first and 1 or #pts
                    if len(pts[iEnd] - c) < 1.2 * g and #pts > 2 then pts[iEnd] = c
                    elseif E.first then table.insert(pts, 1, c) else pts[#pts + 1] = c end
                end
            end
        end
    end
    for _, pts in ipairs(bendLines) do
        local L = 0
        for i = 1, #pts - 1 do L += len(pts[i + 1] - pts[i]) end
        local out = {}
        if L >= 1.5 * g then dp(pts, 1, #pts, 0.015, out) end
        for _, sg in ipairs(out) do if len(sg[2] - sg[1]) > 1e-4 then seg(sg[1], sg[2]) end end
    end

    -- a thin piece only one ray wide (a rail): its line of heights along the grid, with its ends down to the ground
    local function strip(list)
        if #list < 2 then return end
        local out = {}
        dp(list, 1, #list, 0.03, out)
        for _, sg in ipairs(out) do seg(sg[1], sg[2]) end
        for _, q in ipairs({ list[1], list[#list] }) do if q.y > 0.02 then seg(q, V(q.x, 0, q.z)) end end
    end
    for j = 1, nz do
        local run = {}
        pace()
        for i = 1, nx do
            local k = top(i, j)
            if k and not used[k] then run[#run + 1] = P[k] else strip(run); run = {} end
        end
        strip(run)
    end
    for i = 1, nx do
        pace()
        local run = {}
        for j = 1, nz do
            local k = top(i, j)
            if k and not used[k] then run[#run + 1] = P[k] else strip(run); run = {} end
        end
        strip(run)
    end
    return lines
end

-- rays (the whole scan runs as a coroutine: before each ray, a pause till the next tick once this tick's rays or
-- time are used; a ray is started only when it should end within the tick's time, going by what such rays cost)
local function gate(job, cost)
    while job.tickRays >= RAYS_A_TICK or (job.tickRays > 0 and overTime(cost)) do coroutine.yield() end
    job.tickRays += 1
    job.rays += 1
end
-- (a ray the game refuses, as when the editor's other rays used up this tick's 64: again next tick, not taken
-- for nothing there)
local function pick(job, from, to)
    local ok, hit
    for _ = 1, 4 do
        gate(job, job.pickMs and job.picks > 0 and job.pickMs / job.picks or 2)
        job.picks += 1
        local t0 = nowMs and nowMs()
        ok, hit = pcall(reskate.world.pick, from, to)
        if t0 then job.pickMs = (job.pickMs or 0) + (nowMs() - t0) end
        if ok then return ok, hit end
        job.refused += 1
        job.tickRays = RAYS_A_TICK
    end
    return ok, hit
end
local function cast(job, from, to)
    for _ = 1, 4 do
        gate(job, job.castMs and job.casts > 0 and job.castMs / job.casts or 0.1)
        job.casts += 1
        local t0 = nowMs and nowMs()
        local ok, p = pcall(reskate.world.raycast, from, to)
        if t0 then job.castMs = (job.castMs or 0) + (nowMs() - t0) end
        if ok then return p end
        job.refused += 1
        job.tickRays = RAYS_A_TICK
    end
    return nil
end
-- a point of the object (its own x, z at size 1) in the world
local function worldAt(job, x, z) return job.pos + job.ax * (x * job.sc) + job.az * (z * job.sc) end
-- the object's height at a point near a part already known to be its own, at height ref: a raycast from a little
-- above ref (so under anything lying over the object higher up), counted as its own when within tol of ref. Gives
-- its height or nil, and the height met whatever it was.
nearAt = function(job, x, z, ref, tol)
    local wp = worldAt(job, x, z)
    local fromY = math.min(job.top, job.pos.y + (ref + 0.5) * job.sc)
    local p = cast(job, V(wp.x, fromY, wp.z), V(wp.x, job.bottom, wp.z))
    if not p then return nil, nil end
    local h = (p.y - job.pos.y) / job.sc
    if math.abs(h - ref) <= tol then return h, h end
    return nil, h
end
-- after the grid: where its edges really are. Between a ray that hit and one beside it that missed (its
-- footprint's edge), and between two that hit at very different heights (a wall, a coping), a few rays in
-- between find the edge; the grid points there are moved onto it, so its edges come out straight and in place.
local function edgeTasks(job)
    local T = {}
    local H, nx, nz = job.H, job.nx, job.nz
    for j = 1, nz do
        for i = 1, nx do
            pace()
            local k = (j - 1) * nx + i
            local h = H[k]
            if h then
                for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                    local i2, j2 = i + d[1], j + d[2]
                    if i2 >= 1 and i2 <= nx and j2 >= 1 and j2 <= nz then
                        local k2 = (j2 - 1) * nx + i2
                        local h2 = H[k2]
                        if not h2 then
                            T[#T + 1] = { k = k, i = i, j = j, di = d[1], dj = d[2], miss = true, lo = 0, hi = 1, n = 0, hk = h }
                        elseif h - h2 > CLIFF then
                            -- (a steep slope: the steps either side about as big, as on a ramp's curve; a wall's jump
                            -- stands alone, with flat or gentle either side)
                            local function hAt(ii, jj) if ii >= 1 and ii <= nx and jj >= 1 and jj <= nz then return H[(jj - 1) * nx + ii] end end
                            local hb, ha = hAt(i - d[1], j - d[2]), hAt(i2 + d[1], j2 + d[2])
                            local around = math.max(hb and math.abs(hb - h) or 0, ha and math.abs(h2 - ha) or 0)
                            if around < 0.5 * (h - h2) then
                            T[#T + 1] = { k = k, k2 = k2, i = i, j = j, di = d[1], dj = d[2], lo = 0, hi = 1, n = 0, hk = h, h2 = h2 }
                            end
                        end
                    end
                end
            end
        end
    end
    return T
end
-- a grid point moved along one way (x or z) onto an edge; moved both ways along the same line (a thin piece
-- with an edge each side), it stays where it was
local function shift(job, k, axis, v)
    local tab, bad = axis == "x" and job.SX or job.SZ, axis == "x" and "bx" or "bz"
    job[bad] = job[bad] or {}
    if job[bad][k] then return end
    local was = tab[k]
    if was and (was > 0) ~= (v > 0) then tab[k] = nil; job[bad][k] = true return end
    if not was or math.abs(v) > math.abs(was) then tab[k] = v end
end
local function edgeDone(job, t)
    local e = (t.lo + t.hi) / 2
    -- (an edge to nothing there, a footprint's or a hole's: where it crosses between the two grid points, for the
    -- outline to run through (see finish); the grid point stays, so a slanting or curved edge comes out smooth)
    if t.miss then
        local k2 = (t.j + t.dj - 1) * job.nx + t.i + t.di
        job.cross[ekey(t.k, k2)] = { from = t.k, e = e, h = t.hIn }
        return
    end
    local axis, g, dir = t.di ~= 0 and "x" or "z", t.di ~= 0 and job.gx or job.gz, t.di ~= 0 and t.di or t.dj
    shift(job, t.k, axis, dir * e * g)
    -- (a wall: the lower point comes up to its foot, so the wall stands straight)
    if t.k2 then
        shift(job, t.k2, axis, -dir * (1 - e) * g)
        local a, b = t.k, t.k2
        if a > b then a, b = b, a end
        job.hard[a .. ":" .. b] = true
    end
end

-- what the rays saw, for checking scans: the grid's heights in cm row by row (a row a line, as the log cuts long
-- lines), - for nothing there, and * after a height that was something else's (left out when own hits exist)
local function logGrid(job)
    reskate.log(string.format("Quick Drop helper: scan grid %s %dx%d x %.3f..%.3f z %.3f..%.3f (rows along z, %s)", tostring(job.item),
        job.nx, job.nz, job.xs[1], job.xs[job.nx], job.zs[1], job.zs[job.nz],
        job.strict and "* = something else's, left out; ~ = covered by something else, filled in from its neighbours" or "* = something else's, kept: no own hits")
        .. ((job.nx > 40 or job.nz > 40) and string.format("; every %d rays shown", math.max(math.ceil(job.nx / 40), math.ceil(job.nz / 40))) or ""))
    -- (a fine grid every so many rays, to keep the log readable)
    local sx, sz = math.max(1, math.ceil(job.nx / 40)), math.max(1, math.ceil(job.nz / 40))
    for j = 1, job.nz, sz do
        local r = {}
        for i = 1, job.nx, sx do
            local k = (j - 1) * job.nx + i
            local h = job.H0[k]
            r[#r + 1] = h and (tostring(math.floor(h * 100 + 0.5)) .. (job.L[k] and (job.strict and job.H[k] and "~" or "*") or "")) or "-"
        end
        reskate.log(string.format("Quick Drop helper: scan grid row %02d: %s", j, table.concat(r, ",")))
    end
end

local function failJob(job, why)
    S.scanJob = nil
    FN.scans[job.item] = false
    S.scanFailAt[job.item] = S.clock
    if why then reskate.log("Quick Drop helper: scan: " .. why, "warn") end
end

-- the end of the grid: whose hits count. When some of the object's own were seen, hits on other things (the
-- map's ground, steps, a deck) are not its shape, and the edge rays leave them out too.
local function settleGrid(job)
    job.H0 = table.clone(job.H)
    if job.own >= 2 then
        job.strict = true
        for k in pairs(job.L) do job.H[k] = nil end
        job.hits = job.own
        -- a cell where something else lies over the object (the rays found none of its own under it): its height
        -- from its own neighbours, straight across between them along x or z. Only when that something lies above
        -- them: a hole in the object (the ground seen through a doorway) stays a hole.
        local nx, nz, H = job.nx, job.nz, job.H
        local fill = {}
        for k in pairs(job.L) do
            pace()
            local i, j = (k - 1) % nx + 1, (k - 1) // nx + 1
            local function across(di, dj)
                local a, b
                for s = 1, math.max(nx, nz) do
                    local i2, j2 = i - di * s, j - dj * s
                    if i2 < 1 or j2 < 1 or i2 > nx or j2 > nz then break end
                    local h = H[(j2 - 1) * nx + i2]; if h then a = { h, s } break end
                end
                for s = 1, math.max(nx, nz) do
                    local i2, j2 = i + di * s, j + dj * s
                    if i2 < 1 or j2 < 1 or i2 > nx or j2 > nz then break end
                    local h = H[(j2 - 1) * nx + i2]; if h then b = { h, s } break end
                end
                if a and b then return a[1] + (b[1] - a[1]) * a[2] / (a[2] + b[2]), true end
                -- (at the grid's side: the nearest one, when only a cell or two away)
                local c = a or b
                if c and c[2] <= 2 then return c[1], false end
                return nil
            end
            -- (between two of its own heights when it can be, else the nearest)
            local hx, bx = across(1, 0)
            local hz, bz = across(0, 1)
            if bx and not bz then hz = nil elseif bz and not bx then hx = nil end
            local est = hx and hz and (hx + hz) / 2 or hx or hz
            if est and job.H0[k] > est + 0.05 then fill[k] = est end
        end
        for k, h in pairs(fill) do H[k] = h; job.hits += 1; job.filled += 1 end
    end
end

local function doneJob(job, lines)
    S.scanJob = nil
    FN.scans[job.item] = lines
    saveScan(job.item, lines)
    logGrid(job)
    reskate.log(string.format("Quick Drop helper: scanned %s: %d of %d grid rays hit it (%d on something else%s), %d edges found, %d lines; %d rays over %d ticks%s",
        tostring(job.item), job.hits, job.nx * job.nz, job.loose, job.strict and string.format(", left out; %d covered cells filled in", job.filled) or ", kept",
        job.edges and #job.edges or 0, #lines // 6, job.rays, job.ticks,
        string.format(" (%d raycasts at %.3f ms, %d picks at %.2f ms; %d surfaces, %d of them mixed)", job.casts, (job.castMs or 0) / math.max(1, job.casts),
            job.picks, (job.pickMs or 0) / math.max(1, job.picks), job.surfaces, job.mixed))
        .. string.format("; longest tick %.1f ms, editor's own work %.1f ms a tick; %d of its points under something else; %d rays refused and cast again", job.maxMs or 0, S.otherMs or -1, job.multi, job.refused))
end


-- one layer of the grid: whose is each height met. Neighbouring heights that run on smoothly (and alike in being
-- on the ground or not) make one surface; a few picks on each tell whose it is. A surface found partly the
-- object's and partly not (the object running smoothly into something else) has each point given by the nearest
-- picked one, and the points along the line between the two kinds picked too, until that line holds still.
local function classify(job, hit, fromY)
    local nx, nz = job.nx, job.nz
    local total = nx * nz
    local T = math.max(0.05, 2.5 * math.max(job.gx, job.gz))
    -- (and no crease between them: the step to the next point about the step from the one before, so a flat
    -- deck and a slope meeting it at the same height are two surfaces)
    local C = math.max(0.02, 0.6 * math.max(job.gx, job.gz))
    local function onGround(h) return math.abs(h) < 0.015 end
    local comp, comps = {}, {}
    for k0 = 1, total do
        if hit[k0] and not comp[k0] then
            pace()
            local c = { k0 }
            comp[k0] = c
            local q = 1
            while q <= #c do
                pace()
                local k = c[q]; q += 1
                local i, j = (k - 1) % nx + 1, (k - 1) // nx + 1
                for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                    local i2, j2 = i + d[1], j + d[2]
                    if i2 >= 1 and i2 <= nx and j2 >= 1 and j2 <= nz then
                        local k2 = (j2 - 1) * nx + i2
                        local i0, j0 = i - d[1], j - d[2]
                        local hb = (i0 >= 1 and i0 <= nx and j0 >= 1 and j0 <= nz) and hit[(j0 - 1) * nx + i0] or nil
                        local i3, j3 = i2 + d[1], j2 + d[2]
                        local ha = (i3 >= 1 and i3 <= nx and j3 >= 1 and j3 <= nz) and hit[(j3 - 1) * nx + i3] or nil
                        local smooth = (not hb or math.abs((hit[k2] or 0) - 2 * hit[k] + hb) < C)
                            and (not ha or not hit[k2] or math.abs(ha - 2 * hit[k2] + hit[k]) < C)
                        if hit[k2] and not comp[k2] and math.abs(hit[k2] - hit[k]) < T and smooth and onGround(hit[k2]) == onGround(hit[k]) then
                            comp[k2] = c; c[#c + 1] = k2
                        end
                    end
                end
            end
            comps[#comps + 1] = c
        end
    end
    local kind = {}
    local function pickAt(k)
        local i, j = (k - 1) % nx + 1, (k - 1) // nx + 1
        local wp = worldAt(job, job.xs[i], job.zs[j])
        local ok, h = pick(job, V(wp.x, fromY[k], wp.z), V(wp.x, job.bottom, wp.z))
        local kd = ok and type(h) == "table" and h.position and hitKind(job, h)
        kind[k] = kd == "own" and "own" or "else"
        return kind[k]
    end
    for _, c in ipairs(comps) do
        job.surfaces += 1
        -- (first, middle and last of it)
        local samples = {}
        for _, n in ipairs({ 1, math.floor((#c + 1) / 2), #c }) do
            if not kind[c[n]] then pickAt(c[n]); samples[#samples + 1] = c[n] end
        end
        local first = kind[samples[1]]
        local same = true
        for _, k in ipairs(samples) do if kind[k] ~= first then same = false end end
        if same then
            for _, k in ipairs(c) do kind[k] = first end
        else
            job.mixed += 1
            -- (more picks spread over it, each point given the nearest picked one's kind)
            for n = 1, 24 do
                local k = c[math.max(1, math.floor(n * #c / 25))]
                if not kind[k] then pickAt(k); samples[#samples + 1] = k end
            end
            local picked = {}
            for _, k in ipairs(samples) do picked[k] = true end
            for _, k in ipairs(c) do
                pace()
                if not picked[k] then
                    local i, j = (k - 1) % nx + 1, (k - 1) // nx + 1
                    local best, bd = nil, math.huge
                    for _, s2 in ipairs(samples) do
                        local i2, j2 = (s2 - 1) % nx + 1, (s2 - 1) // nx + 1
                        local dd = (i - i2) ^ 2 + (j - j2) ^ 2
                        if dd < bd then best, bd = s2, dd end
                    end
                    kind[k] = kind[best]
                end
            end
            -- (the points beside one of the other kind, picked, over again till none changes; at most 600 picks)
            local budget = 600
            for _ = 1, 40 do
                local changed = false
                for _, k in ipairs(c) do
                    pace()
                    if not picked[k] and budget > 0 then
                        local i, j = (k - 1) % nx + 1, (k - 1) // nx + 1
                        local edge = false
                        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                            local i2, j2 = i + d[1], j + d[2]
                            if i2 >= 1 and i2 <= nx and j2 >= 1 and j2 <= nz then
                                local k2 = (j2 - 1) * nx + i2
                                if comp[k2] == c and kind[k2] ~= kind[k] then edge = true end
                            end
                        end
                        if edge then
                            local was = kind[k]
                            picked[k] = true; budget -= 1
                            if pickAt(k) ~= was then changed = true end
                        end
                    end
                end
                if not changed then break end
            end
        end
    end
    return kind
end

-- the whole scan, run a little each tick: the grid (raycasts, and picks to tell whose), the edges, the lines
local function runJob(job)
    local nx, nz = job.nx, job.nz
    local total = nx * nz
    local fromY, lastY, firstElse = {}, {}, {}
    local active = {}
    for k = 1, total do fromY[k] = job.top; active[k] = k end
    for layer = 1, 4 do
        local hit = {}
        local m = 0.05 / job.sc
        for ai, k in ipairs(active) do
            -- (how far along, for the panel: the first look over the grid is most of it)
            job.prog = (layer == 1 and 0.6 or 0.65) * ai / #active
            local i, j = (k - 1) % nx + 1, (k - 1) // nx + 1
            local wp = worldAt(job, job.xs[i], job.zs[j])
            local p = cast(job, V(wp.x, fromY[k], wp.z), V(wp.x, job.bottom, wp.z))
            -- (the same thing met again just under where it was met: a little further down)
            if p and lastY[k] and lastY[k] - p.y < 0.01 then
                fromY[k] = lastY[k] - 0.05
                p = cast(job, V(wp.x, fromY[k], wp.z), V(wp.x, job.bottom, wp.z))
            end
            if p then
                lastY[k] = p.y
                hit[k] = (p.y - job.pos.y) / job.sc
                -- (above or under the object's box: something else, no pick needed)
                if hit[k] > job.hi.y + m or hit[k] < job.lo.y - m then hit[k] = nil; firstElse[k] = firstElse[k] or (p.y - job.pos.y) / job.sc end
            end
        end
        local kind = classify(job, hit, fromY)
        local nextActive = {}
        for _, k in ipairs(active) do
            local h = hit[k]
            if h and kind[k] == "own" then
                job.H[k] = h; job.own += 1
                if layer > 1 then job.multi += 1 end
            elseif lastY[k] and (h or firstElse[k]) then
                if h then firstElse[k] = firstElse[k] or h end
                fromY[k] = lastY[k] - 0.005
                if fromY[k] > job.bottom then nextActive[#nextActive + 1] = k end
            end
        end
        active = nextActive
        if #active == 0 then break end
    end
    -- (points with nothing of its own under something else: as before, that something's height, marked)
    for k, h in pairs(firstElse) do
        if not job.H[k] then job.H[k] = h; job.L[k] = true; job.loose += 1 end
    end
    job.hits = 0
    for _ in pairs(job.H) do job.hits += 1 end
    pace()
    settleGrid(job)
    if job.hits < 2 then return "none" end
    -- the edges: raycasts near its own heights
    job.edges = edgeTasks(job)
    for ei, t in ipairs(job.edges) do
        job.prog = 0.7 + 0.2 * ei / #job.edges
        -- (an edge to nothing on the ground: the object and the ground can't be told apart by height; halfway)
        if not (t.miss and t.hk < 0.05) then
            for _ = 1, EDGE_STEPS do
                local mm = (t.lo + t.hi) / 2
                local x, z = job.xs[t.i] + t.di * mm * job.gx, job.zs[t.j] + t.dj * mm * job.gz
                local onUpper, h
                if t.miss then
                    h = nearAt(job, x, z, t.hk, math.max(0.1, 0.5 * t.hk))
                    onUpper = h ~= nil
                else
                    local _, raw = nearAt(job, x, z, t.hk, math.huge)
                    h = raw
                    onUpper = h ~= nil and math.abs(h - t.hk) < math.abs(h - t.h2)
                    -- (a height well between the two: it climbs there smoothly, a steep slope and not a wall)
                    if h and math.min(math.abs(h - t.hk), math.abs(h - t.h2)) > 0.2 * (t.hk - t.h2) then t.soft = true end
                end
                if onUpper then t.lo = mm; if h then t.hIn = h end else t.hi = mm end
            end
            if not t.soft then edgeDone(job, t) end
        end
    end
    job.phase = "rim"
    job.prog = 0.92
    return finish(job)
end


function FN.scanTick()
    if not S.open then return end
    local job = S.scanJob
    if not job then
        local o, b = nextJob()
        if o then startJob(o, b) end
        return
    end
    tickStart = nowMs and nowMs() or 0
    scanMs = S.otherMs and math.max(SCAN_MS_MIN, math.min(SCAN_MS_MAX, TICK_MS - S.otherMs)) or SCAN_MS
    job.ticks += 1
    job.tickRays = 0
    -- moved, removed or picked up while its rays are cast: start over later
    if job.phase ~= "lines" then
        local o = S.known and S.known[job.id]
        if not o or len(o.position - job.pos) > 0.01 or not still(o) then S.scanJob = nil return end
    end
    job.co = job.co or coroutine.create(runJob)
    local ok, res = coroutine.resume(job.co, job)
    if nowMs then
        local took = nowMs() - tickStart
        job.maxMs = math.max(job.maxMs or 0, took)
        S.scanMsTick = took
    end
    if not ok then failJob(job, tostring(res)) return end
    if coroutine.status(job.co) ~= "dead" then return end
    if res == "none" then
        -- nothing seen (too far from the skater, or the rays pass through it): tried again later
        failJob(job, nil)
        reskate.log("Quick Drop helper: scan: nothing seen on " .. tostring(job.item) .. " (" .. (job.nx * job.nz) .. " rays)")
    elseif type(res) == "table" and #res >= 6 then
        doneJob(job, res)
    else
        failJob(job, nil)
    end
end

end
