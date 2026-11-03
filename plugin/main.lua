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
    cam = { target = V(0, 0, 0), yaw = 0, pitch = -0.4, dist = 10, fov = 60 },
    mouse = { pos = nil, left = false }, drag = nil, hover = nil,
    screen = {}, proj = nil, size = V(1920, 1080, 0),
    held = {}, msg = "", msgUntil = 0,
}

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
    S.handleLen = nil
    S.edit = {}
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
    for _, o in ipairs(list) do now[o.id] = o end
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
        -- one new object: a drop. Many at once: a park or map loading, not something to pick.
        if #fresh == 1 then
            local o = fresh[1]
            reskate.log("Quick Drop helper: new object " .. fmt(o))
            select(o)
            if not S.open then reskate.ui.toast("Dropped " .. titleOf(o.item) .. ". F6: move, turn and size it") end
        elseif #fresh > 1 then
            reskate.log(string.format("Quick Drop helper: %d objects loaded with the park.", #fresh))
        end
        if S.sel and not now[S.sel.id] then select(nil) end
        -- moved by something else (Quick Drop again): follow it
        if S.sel and not S.dirty and not S.drag and not S.phys and S.clock - S.lastSend > 1500 then
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
-- ---------------------------------------------------------------- smooth dragging (ReSkate 2.1.4, offline)
-- While a handle is dragged, the real object is taken over by the game's object physics and pushed toward the
-- handles every frame. Its rotation is set 4 times a second. Letting go saves the place with objects.move, and
-- the object is handed back once the game has saved it. Online, or when the game refuses, dragging works as
-- before (the object follows as often as the game takes edits).
S.physUse = true
local function physApi() return reskate.objects.physics and reskate.objects.velocity and reskate.objects.motion and reskate.objects.pose end
local function yawQuat(q0, dh)
    -- rotate the starting rotation q0 about up by dh
    local s, c = math.sin(dh / 2), math.cos(dh / 2)
    local x, y, z, w = q0[1], q0[2], q0[3], q0[4]
    -- (0, s, 0, c) * (x, y, z, w)
    local q = { c * x + s * z, c * y + s * w, c * z - s * x, c * w - s * y }
    local n = math.sqrt(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2)
    return { q[1] / n, q[2] / n, q[3] / n, q[4] / n }
end
local function physRelease(reason)
    local P = S.phys
    if not P then return end
    S.phys = nil
    pcall(reskate.objects.physics, P.sid, nil)
    if reason then reskate.log("Quick Drop helper: smooth drag handed back: " .. reason) end
end
local function physStart()
    if not (S.physUse and physApi() and S.sel and S.target) then return end
    physRelease()
    local sid = string.format("%d", S.sel.id)
    local ok, res, why = pcall(reskate.objects.physics, sid, { dynamic = true, mass = 20000, surface = false })
    if not ok or res ~= true then
        local reason = tostring(ok and why or res)
        if reason ~= S.physWhy then reskate.log("Quick Drop helper: no smooth drag: " .. reason) end
        S.physWhy = reason
        return
    end
    local okm, m = pcall(reskate.objects.motion, sid)
    if not okm or not m or not m.rotation then
        pcall(reskate.objects.physics, sid, nil)
        S.physWhy = "the game gave no motion for it"
        return
    end
    S.physWhy = nil
    S.phys = { sid = sid, id = S.sel.id, q0 = m.rotation, h0 = S.target.heading, rev0 = m.edit_revision, poseAt = -1e9,
        state = "drag", from = S.clock }
end
local function physTick(sec)
    local P = S.phys
    if not P then return end
    if not S.sel or S.sel.id ~= P.id then physRelease("picked another object") return end
    local ok, m = pcall(reskate.objects.motion, P.sid)
    if not ok or not m then physRelease("the game let go of it") return end
    local t = S.target
    if P.state == "hold" then
        -- the place was sent: hand it back once the game has saved it (or after a while)
        local saved = P.accepted and (m.edit_revision ~= P.rev0 and S.clock - P.accepted > 300 or S.clock - P.accepted > 2500)
        if saved or S.clock - P.holdFrom > 6000 then physRelease() return end
    end
    if m.editing then return end
    if S.clock - P.poseAt >= 260 then
        local okp, res = pcall(reskate.objects.pose, P.sid, t.pos, yawQuat(P.q0, t.heading - P.h0))
        if okp and res == true then P.poseAt = S.clock; return end
    end
    local err = t.pos - m.position
    local v = err * 12 + V(0, 9.81 * sec, 0)
    local sp = len(v)
    if sp > 45 then v = v * (45 / sp) end
    pcall(reskate.objects.velocity, P.sid, v)
end
local function physLetGo()
    local P = S.phys
    if not P then return end
    P.state = "hold"
    P.holdFrom = S.clock
end

-- ---------------------------------------------------------------- the measured outline
-- When an object is picked, rays from above measure its shape (what you can collide with). The shape is drawn
-- where the handles are, every frame: bright while it moves, faint when it rests.
local SCAN_N = 20
local clockOk = type(os) == "table" and type(os.clock) == "function"
local function now() return clockOk and os.clock() or 0 end
local function scanStart()
    local sel, t = S.sel, S.target
    if not (sel and t) then return end
    local others = {}
    for _, o in ipairs(reskate.objects.list()) do if len(o.position - t.pos) < 30 then table.insert(others, o) end end
    S.shape = { id = sel.id, R = 3, k = 0, h = {}, pos = t.pos, heading = t.heading, scale = t.scale, others = others, tries = 0 }
end
local function scanTick()
    local sh = S.shape
    if not sh or sh.done or not S.sel or sh.id ~= S.sel.id then return end
    -- the object is moving: measure again from the start once it rests
    if S.drag or S.phys or S.dirty then S.shape = nil return end
    if sh.thin then
        local th = sh.thin
        local ca, sa = math.cos(th.a), math.sin(th.a)
        local r1, f1 = V(ca, 0, -sa), V(sa, 0, ca)
        local ch0, sh0 = math.cos(sh.heading), math.sin(sh.heading)
        local per = S.scanPer or 16
        local t0 = now()
        for _ = 1, per do
            if th.k >= th.n * th.n then break end
            if clockOk and now() - t0 > 0.006 then break end
            local i, j = th.k % th.n, math.floor(th.k / th.n)
            th.k += 1
            local at = sh.pos + r1 * (-th.R + (i + 0.5) * 2 * th.R / th.n) + f1 * (-th.R + (j + 0.5) * 2 * th.R / th.n)
            local ok, hit = pcall(reskate.world.pick, at + V(0, 12, 0), at - V(0, 3, 0))
            if not ok then S.scanPer = math.max(8, math.floor(per / 2)); th.k -= 1; break end
            if hit and hit.object then
                local op = hit.object.position or hit.position
                local best, bd = nil, 1.5
                for _, o in ipairs(sh.others) do
                    local dd = len(o.position - op)
                    if dd < bd then best, bd = o, dd end
                end
                if best and best.id == sh.id then
                    local d = hit.position - sh.pos
                    -- into the object's own frame (right, up, forward), unscaled
                    table.insert(th.pts, { (d.x * ch0 - d.z * sh0) / sh.scale, d.y / sh.scale, (d.x * sh0 + d.z * ch0) / sh.scale })
                end
            end
        end
        if th.k < th.n * th.n then return end
        sh.thin, sh.thinDone = nil, true
        local pts = th.pts
        if #pts >= 2 then
            -- the bar's direction: the main axis of the points, seen from above
            local mx, mz = 0, 0
            for _, q in ipairs(pts) do mx += q[1]; mz += q[3] end
            mx, mz = mx / #pts, mz / #pts
            local sxx, szz, sxz = 0, 0, 0
            for _, q in ipairs(pts) do
                local dx, dz = q[1] - mx, q[3] - mz
                sxx += dx * dx; szz += dz * dz; sxz += dx * dz
            end
            local ang = 0.5 * math.atan2(2 * sxz, sxx - szz)
            local ax, az = math.cos(ang), math.sin(ang)
            table.sort(pts, function(p1, p2) return p1[1] * ax + p1[3] * az < p2[1] * ax + p2[3] * az end)
            local ext, wide = 0, 0
            for _, q in ipairs(pts) do
                ext = math.max(ext, math.abs(q[1]), math.abs(q[2]), math.abs(q[3]))
                wide = math.max(wide, math.abs((q[1] - mx) * -az + (q[3] - mz) * ax))
            end
            sh.bar, sh.count, sh.ext = pts, #pts, ext
            -- not a thin bar but a small object the first rays missed: measure it again, close up
            if wide > 0.08 or ext < 0.8 then
                sh.barFallback, sh.bar = pts, nil
                sh.R = math.max(0.6, ext * sh.scale * 1.2 + 0.15)
                sh.k, sh.h, sh.tries, sh.finer, sh.prev = 0, {}, 1, 2, nil
                return
            end
        end
        sh.done = true
        sh.others = nil
        reskate.log(string.format("Quick Drop helper: measured %s (thin): %d points", tostring(S.sel.item), #pts))
        return
    end
    local ch, shh = math.cos(sh.heading), math.sin(sh.heading)
    local right, fwd = V(ch, 0, -shh), V(shh, 0, ch)
    local n = SCAN_N
    local per = S.scanPer or 16
    local t0 = now()
    for _ = 1, per do
        if sh.k >= n * n then break end
        if clockOk and now() - t0 > 0.006 then break end
        local i, j = sh.k % n, math.floor(sh.k / n)
        sh.k += 1
        local u = -sh.R + (i + 0.5) * 2 * sh.R / n
        local w = -sh.R + (j + 0.5) * 2 * sh.R / n
        local at = sh.pos + right * u + fwd * w
        local ok, hit = pcall(reskate.world.pick, at + V(0, 12, 0), at - V(0, 3, 0))
        if not ok then
            -- too many rays this tick: fewer next time
            S.scanPer = math.max(8, math.floor(per / 2))
            sh.k -= 1
            break
        end
        if hit and hit.object then
            local op = hit.object.position or hit.position
            local best, bd = nil, 1.5
            for _, o in ipairs(sh.others) do
                local dd = len(o.position - op)
                if dd < bd then best, bd = o, dd end
            end
            if best and best.id == sh.id then sh.h[sh.k] = (hit.position.y - sh.pos.y) / sh.scale end
        end
    end
    if sh.k < n * n then return end
    -- reached the edge of the measured square: measure a bigger one (twice at most)
    local edge = false
    for k, _ in pairs(sh.h) do
        local i, j = (k - 1) % n, math.floor((k - 1) / n)
        if i == 0 or j == 0 or i == n - 1 or j == n - 1 then edge = true break end
    end
    if edge and sh.tries < 2 then
        sh.tries += 1
        sh.R *= 2
        sh.k, sh.h = 0, {}
        return
    end
    sh.done = true
    sh.cell = 2 * sh.R / n / sh.scale
    local count, ext = 0, 0
    for k, y in pairs(sh.h) do
        count += 1
        local i, j = (k - 1) % n, math.floor((k - 1) / n)
        local u = (-sh.R + (i + 0.5) * 2 * sh.R / n) / sh.scale
        local w = (-sh.R + (j + 0.5) * 2 * sh.R / n) / sh.scale
        ext = math.max(ext, math.abs(u), math.abs(w), math.abs(y))
    end
    sh.count, sh.ext = count, ext
    -- small objects get few points: measure a smaller square, finer (twice at most)
    if not edge and count >= 6 and count < 60 and sh.R > 0.6 and (sh.finer or 0) < 2 then
        local newR = math.max(0.6, ext * sh.scale * 1.1 + 2 * sh.R / n)
        if newR < sh.R * 0.8 then
            sh.finer = (sh.finer or 0) + 1
            sh.prev = { h = sh.h, R = sh.R, count = count, ext = ext }
            sh.R = newR
            sh.done, sh.k, sh.h, sh.tries = false, 0, {}, 1
            return
        end
    end
    -- a finer square that lost the object: keep the one before
    if count == 0 and sh.prev then sh.h, sh.R, sh.count, sh.ext = sh.prev.h, sh.prev.R, sh.prev.count, sh.prev.ext; sh.cell = 2 * sh.R / n / sh.scale; count = sh.count end
    -- thin objects (rails) slip between the rays: a fine pass on a slanted grid, which crosses any thin bar
    if count < 6 and sh.thinDone and sh.barFallback then sh.bar, sh.count = sh.barFallback, #sh.barFallback end
    if count < 6 and not sh.thinDone then
        sh.done = false
        sh.thin = sh.thin or { k = 0, n = 48, R = count > 0 and math.max(1, ext * sh.scale * 1.3) or 3, a = sh.heading + 0.35, pts = {} }
        return
    end
    sh.others = nil
    reskate.log(string.format("Quick Drop helper: measured %s: %d points across %.1f m", tostring(S.sel.item), count, sh.R * 2))
end
local function drawShape(d, t, hot)
    local sh = S.shape
    if not (sh and sh.done and S.sel and sh.id == S.sel.id and sh.count and sh.count > 0) then return end
    local n = SCAN_N
    local ch, shh, sc = math.cos(t.heading), math.sin(t.heading), t.scale
    local right, fwd = V(ch, 0, -shh), V(shh, 0, ch)
    if sh.bar then
        -- a thin object: a line along its top, with posts down to the ground about every 0.4 m
        local col = hot and "#ffe066" or "#ffffff55"
        local th = hot and 3 or 1
        local prev, prevW, lastPost = nil, nil, -1e9
        for idx, q in ipairs(sh.bar) do
            local wpos = t.pos + (right * q[1] + fwd * q[3]) * sc
            local top = d:world_to_screen(wpos + V(0, q[2] * sc, 0))
            if top then
                if prev and prevW and len(wpos - prevW) < 0.6 * sc then d:line(prev, top, { colour = col, thickness = th }) end
                local along = len(wpos - t.pos) * (q[1] * right.x >= 0 and 1 or -1)
                if idx == 1 or idx == #sh.bar or math.abs(along - lastPost) > 0.4 * sc then
                    local g = d:world_to_screen(wpos)
                    if g and q[2] > 0.05 then d:line(top, g, { colour = col, thickness = 1 }) end
                    lastPost = along
                end
            end
            prev, prevW = top, wpos
        end
        return
    end
    local R = sh.R / sh.scale
    local pts, base = {}, {}
    for k, y in pairs(sh.h) do
        local i, j = (k - 1) % n, math.floor((k - 1) / n)
        local u = -R + (i + 0.5) * 2 * R / n
        local w = -R + (j + 0.5) * 2 * R / n
        local wp = t.pos + (right * u + fwd * w) * sc
        pts[k] = d:world_to_screen(wp + V(0, y * sc, 0))
        base[k] = { wp = wp, y = y }
    end
    local col = hot and "#ffe066" or "#ffffff55"
    local th = hot and 2 or 1
    for k, a in pairs(pts) do
        local i, j = (k - 1) % n, math.floor((k - 1) / n)
        -- along rows and columns, where the surface is continuous
        local kr, kc = k + 1, k + n
        if i < n - 1 and pts[kr] and math.abs(sh.h[kr] - sh.h[k]) < 0.6 then d:line(a, pts[kr], { colour = col, thickness = th }) end
        if j < n - 1 and pts[kc] and math.abs(sh.h[kc] - sh.h[k]) < 0.6 then d:line(a, pts[kc], { colour = col, thickness = th }) end
        -- the sides: down to the ground where the shape ends
        local edge = (i == 0 or not sh.h[k - 1]) or (i == n - 1 or not sh.h[k + 1]) or (j == 0 or not sh.h[k - n]) or (j == n - 1 or not sh.h[k + n])
        if edge and sh.h[k] > 0.05 then
            local g = d:world_to_screen(base[k].wp)
            if g then d:line(a, g, { colour = col, thickness = th }) end
        end
    end
end

-- sends the change to the game. The game takes at most 4 edits a second, counting refused tries, and one at a
-- time, so a new one only goes once the last is applied and fewer than 4 went in the last second.
-- While a handle is dragged the object follows as often as that allows; letting go sends the exact place.
local function send()
    if not (S.sel and S.dirty) then return end
    if S.phys and S.phys.state == "drag" then return end
    local t = S.target
    if sameAsSent(t) then S.dirty = false return end
    local tries = S.tries or {}
    S.tries = tries
    while tries[1] and S.clock - tries[1] > 1050 do table.remove(tries, 1) end
    if #tries >= 4 then return end
    if not lastApplied() then return end
    local gap = (S.drag and S.drag.moved) and 150 or 250
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
        if S.phys and S.phys.state == "hold" then S.phys.accepted = S.clock end
        S.lastSent = { id = S.sel.id, pos = t.pos, heading = t.heading, scale = t.scale, at = S.clock }
        -- still dragging: keep going with the next place
        S.dirty = false
    elseif BUSY[why] then
        -- the game is still busy: wait for the next free slot (every try counts toward its 4 a second)
    elseif S.phys then
        -- maybe it won't save an object that physics holds: hand it back and send the place again
        physRelease("the game refused the move while held: " .. tostring(why))
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

local function markUndo()
    if S.target then
        table.insert(S.undo, { id = S.sel.id, pos = S.target.pos, heading = S.target.heading, scale = S.target.scale })
        if #S.undo > 100 then table.remove(S.undo, 1) end
    end
end

local function undo()
    local u = table.remove(S.undo)
    if not u then say("Nothing to undo.") return end
    if not S.sel or S.sel.id ~= u.id then
        for _, o in ipairs(reskate.objects.list()) do if o.id == u.id then select(o) end end
    end
    if S.sel and S.sel.id == u.id then
        S.target = { pos = u.pos, heading = u.heading, scale = u.scale }
        S.dirty = true
    end
end

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

local function clickPick(px)
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
        say("Picked " .. titleOf(best.item))
    elseif hit.object then
        say("That is part of the map: only placed objects can be changed.")
    end
end

local function openEditor()
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
    S.open = true
    S.drag = nil
    S.mouse = { pos = nil, left = false }
    reskate.ui.open(TITLE)
end

local function closeEditor()
    if not S.open then return end
    if S.typing then S.typing = false; pcall(reskate.ui.close_dialog, "ddh_type") end
    S.drag = nil
    physLetGo()
    S.open = false
    reskate.camera.release()
    reskate.ui.close()
end

reskate.input.bind("ddh_quickdrop_plus", "F6")
reskate.on("action", function(name) if name == "ddh_quickdrop_plus" then openEditor() end end)
reskate.on("screen_closed", function(title) if title == TITLE and S.open then S.open = false; S.drag = nil; physLetGo(); reskate.camera.release() end end)
reskate.on("unload", function() physRelease(); if S.open then reskate.camera.release() end end)
reskate.on("level_loaded", function() S.phys = nil; S.shape = nil; S.listKey = nil; S.known = nil; S.blocked = nil; S.missing = nil; S.confirmRemove = nil; select(nil) end)

-- typing exact numbers: a text box with "X Y Z turn size"; change any of them
local TYPE_ID = "ddh_type"
local function openTyping()
    if not (S.sel and S.target) then return end
    local t = S.target
    local text = string.format("%.3f  %.3f  %.3f  %.1f  %.2f", t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale)
    local ok, why = pcall(reskate.ui.dialog, TYPE_ID, {
        title = "Type numbers",
        message = "X  Y  Z  Turn  Size, with spaces between.\nChange any of them, then Enter.\nTip: start a number with + to add to it: +2 moves 2 m, +-0.5 moves back 0.5 m.",
        field = { text = text, max = 120 },
        buttons = { { id = "apply", label = "Apply" }, { id = "close", label = "Cancel" } },
    })
    if not ok or why == false then say("Could not open the text box" .. (ok and "" or (": " .. tostring(why))), true) else S.typing = true end
end
local function parseTyped(str)
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
    if e.action ~= "dialog" or e.args[1] ~= TYPE_ID then return end
    local what = e.args[2]
    if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
    S.typing = false
    if what ~= "cancel" then pcall(reskate.ui.close_dialog, TYPE_ID) end
    if what ~= "apply" then return end
    if not (S.sel and S.target) then return end
    local v, err = parseTyped(e.args[3] or "")
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
local function oldPanel(ui)
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
        ui:note("X and Z (tilt): the game only turns placed objects about Y.")
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
    ui:separator()
    if ui:button("undo", "Undo (Ctrl+Z)") then undo() end
    if ui:button("straight", "Straighten and size 1") and S.target then
        markUndo(); S.target.heading = round(S.target.heading, math.pi / 2); S.target.scale = 1; S.dirty = true
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
    end
    if ui:button("close", "Done (Esc)", true) then closeEditor() end
end

-- ---------------------------------------------------------------- the new panel (ReSkate 2.1.4 widgets)
-- step sizes for the steppers: metres, degrees, size
local STEPS = {
    { m = 0.01, deg = 1, size = 0.01, name = "Fine", mf = "%.2f m", df = "%.0f°", sf = "%.2f×" },
    { m = 0.1, deg = 15, size = 0.1, name = "Normal", mf = "%.2f m", df = "%.0f°", sf = "%.2f×" },
    { m = 1, deg = 45, size = 0.5, name = "Big", mf = "%.1f m", df = "%.0f°", sf = "%.1f×" },
}
S.stepSize = 2
S.sec = { move = true, handles = false, objects = true, locked = true, help = false }
S.search, S.listFilter = "", 1
S.listAt, S.listKey = -1e9, nil
S.listObjs, S.listItems, S.listTotal = {}, {}, 0

local function section(ui, id, title, sub)
    local o = ui:section(id, title, sub, S.sec[id])
    if o ~= nil then S.sec[id] = o end
    return S.sec[id]
end

-- a number box: click it and type. What is typed is used once you stop typing for a moment.
-- "12.5" sets it, "+2" adds 2, "+-0.5" takes 0.5 off; a comma works as the decimal point too.
local function parseNum(text, cur)
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
        local v = parseNum(e.text, val)
        if v then apply(v) else say(label .. ": \"" .. e.text .. "\" is not a number", true) end
    end
end

-- the list of park objects: rebuilt twice a second, or at once when the search or filter changes
local function rebuildList()
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

local function newPanel(ui)
    local t = S.sel and S.target
    -- what is picked, and the everyday buttons
    if t then
        ui:card(titleOf(S.sel.item), string.format("%.2f, %.2f, %.2f   |   %.0f°   |   %.2fx", t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale))
    else
        ui:card("Nothing picked", "Click an object or pick one in the list")
    end
    if S.msg ~= "" and S.clock < S.msgUntil then ui:note(S.msg) end
    local b = ui:buttons("top", { "Undo", "Look at it" }, 0)
    if b == 1 then undo() end
    if b == 2 and t then S.cam.goal = t.pos end
    if ui:button("close", "Done (Esc)", true) then closeEditor() end

    -- exact numbers: click a box and type; nudge buttons below
    local st = STEPS[S.stepSize]
    if t and section(ui, "move", "Move and turn", "") then
        numBox(ui, "px", "X", t.pos.x, "%.3f", function(v) markUndo(); t.pos = V(v, t.pos.y, t.pos.z); S.dirty = true end)
        numBox(ui, "py", "Y", t.pos.y, "%.3f", function(v) markUndo(); t.pos = V(t.pos.x, v, t.pos.z); S.dirty = true end)
        numBox(ui, "pz", "Z", t.pos.z, "%.3f", function(v) markUndo(); t.pos = V(t.pos.x, t.pos.y, v); S.dirty = true end)
        numBox(ui, "ry", "Turn", math.deg(t.heading), "%.1f", function(v) markUndo(); t.heading = wrap(math.rad(v)); S.dirty = true end)
        numBox(ui, "sz", "Size", t.scale, "%.2f", function(v) markUndo(); t.scale = clamp(v, 0.1, 10); S.dirty = true end)
        ui:heading("Nudge")
        local ss = ui:buttons("stepsize", { "Fine", "Normal", "Big" }, S.stepSize)
        if ss and STEPS[ss] then S.stepSize = ss; st = STEPS[ss] end
        local n = ui:buttons("nudge", { "X -", "X +", "Y -", "Y +", "Z -", "Z +" }, 0)
        if n then
            markUndo()
            local d = ({ V(-1, 0, 0), V(1, 0, 0), V(0, -1, 0), V(0, 1, 0), V(0, 0, -1), V(0, 0, 1) })[n]
            if d then t.pos = t.pos + d * st.m; S.dirty = true; S.edit = {} end
        end
        local n2 = ui:buttons("nudge2", { "Turn -", "Turn +", "Size -", "Size +", "Straighten", "Size 1" }, 0)
        if n2 then
            markUndo()
            if n2 == 1 then t.heading = wrap(t.heading - math.rad(st.deg)) end
            if n2 == 2 then t.heading = wrap(t.heading + math.rad(st.deg)) end
            if n2 == 3 then t.scale = clamp(t.scale - st.size, 0.1, 10) end
            if n2 == 4 then t.scale = clamp(t.scale + st.size, 0.1, 10) end
            if n2 == 5 then t.heading = round(t.heading, math.pi / 2) end
            if n2 == 6 then t.scale = 1 end
            S.dirty = true; S.edit = {}
        end
    end

    -- the handles in the view
    local modes = { "Move (W)", "Turn (E)", "Size (R)" }
    if section(ui, "handles", "Handles", modes[S.mode] .. (S.snap and "  |  snap" or "")) then
        local m = ui:buttons("mode", modes, S.mode)
        if m and m ~= S.mode then S.mode = m end
        local sn = ui:toggle("snap", "Snap (G)", S.snap)
        if sn ~= nil then S.snap = sn end
        local ph = ui:toggle("phys", "Smooth drag (offline)", S.physUse)
        if ph ~= nil then S.physUse = ph end
        if S.physUse and S.physWhy then ui:note("Smooth drag off: " .. S.physWhy) end
    end

    -- every object in the park
    rebuildList()
    local sub = tostring(S.listTotal)
    if S.search ~= "" or S.listFilter ~= 1 then sub = string.format("%d / %d", S.listMatched or 0, S.listTotal) end
    if section(ui, "objects", "Objects in this park", sub) then
        local q = ui:text("search", "Search", S.search, "")
        if type(q) == "string" and q ~= S.search then S.search = q; S.listKey = nil end
        local f = ui:buttons("filter", { "All", "Near", "DDH" }, S.listFilter)
        if f and f ~= S.listFilter then S.listFilter = f; S.listKey = nil end
        rebuildList()
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
    end

    -- objects from missing mods
    local miss = S.missing or {}
    if (S.blocked or #miss > 0) and section(ui, "locked", "Park locked", string.format("%d missing", #miss)) then
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

    if section(ui, "help", "Controls", "") then
        ui:info("Click", "pick an object")
        ui:info("Drag a handle", "move / turn / size")
        ui:info("Drag empty space", "turn the view")
        ui:info("Right-drag", "slide the view")
        ui:info("Scroll", "zoom")
        ui:info("Arrows, PgUp, PgDn", "fly the view")
        ui:info("W / E / R", "move / turn / size handles")
        ui:info("G", "snap")
        ui:info("F", "look at it")
        ui:info("Ctrl+Z", "undo")
        ui:info("Shift", "bigger steps")
    end
end

-- which panel: the new one when this ReSkate has the 2.1.4 widgets, otherwise the old one
local function hasNewWidgets(ui)
    local ok, yes = pcall(function()
        return type(ui.stepper) == "function" and type(ui.section) == "function" and type(ui.list) == "function"
            and type(ui.buttons) == "function" and type(ui.text) == "function"
    end)
    return ok and yes
end

reskate.ui.screen(TITLE, function(ui)
    if S.newUI == nil then
        S.newUI = hasNewWidgets(ui)
        reskate.log("Quick Drop helper: " .. (S.newUI and "using the new panel (ReSkate 2.1.4 widgets)." or "this ReSkate has no 2.1.4 widgets; using the old panel."))
    end
    if S.newUI then
        local ok, err = pcall(newPanel, ui)
        if ok then return end
        reskate.log("Quick Drop helper: the new panel failed, going back to the old one: " .. tostring(err), "warn")
        S.newUI = false
        return
    end
    oldPanel(ui)
end, { dock = "right", width = 0.2 })

local function press(k)
    local d = reskate.input.key(k)
    local was = S.held[k]
    S.held[k] = d
    return d and not was
end

-- which handle is under the mouse (from where the last frame drew them)
local function handleAt(px)
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
    else
        for i = 1, 8 do
            if sc.cubes and sc.cubes[i] and d2(px, sc.cubes[i]) < 18 then return { kind = "size" } end
        end
        if d2(px, sc.center) < 18 then return { kind = "size" } end
    end
    return nil
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

    if not S.open then
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
            for _, k in ipairs({ "[", "]", "PageUp", "PageDown", "X", "Z", "Up", "Down", "Right", "Left", "U" }) do S.held[k] = false end
        end
        physTick(sec)
        send()
        return
    end

    -- the editor: keys (none while the text box is open)
    if S.typing then physTick(sec); send(); return end
    local ctrl = reskate.input.key("Ctrl")
    if press("W") then S.mode = 1 end
    if press("E") then S.mode = 2 end
    if press("R") then S.mode = 3 end
    if press("G") then S.snap = not S.snap end
    if press("F") and S.target then S.cam.goal = S.target.pos end
    if press("Z") and ctrl then undo() end
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

    -- the mouse
    local c = reskate.input.cursor()
    if c then
        local px = c.position
        local last = S.mouse.pos or px
        local dx, dy = px.x - last.x, px.y - last.y
        if c.wheel and c.wheel ~= 0 and not c.over_screen then
            S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (0.85 ^ c.wheel), 0.5, 300)
        end
        S.hover = (not S.drag and not c.over_screen) and handleAt(px) or nil
        if c.left and not S.mouse.left and not c.over_screen then
            local h = handleAt(px)
            if h then
                markUndo()
                local t = S.target
                h.start = { pos = t.pos, heading = t.heading, scale = t.scale, px = px }
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
                if h.kind ~= "size" then physStart() end
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
                if g.kind == "axis" then
                    local along = ((px.x - g.start.px.x) * g.dir.x + (px.y - g.start.px.y) * g.dir.y) / g.ppm
                    if S.snap then along = round(along, step) end
                    t.pos = g.start.pos + axesFor(g.start.heading)[g.axis][1] * along
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
            if S.drag and S.drag.moved then S.dirty = true end
        elseif not c.left and S.mouse.left and S.drag then
            if S.drag.kind == "click" then clickPick(px) end
            local moved = S.drag.moved
            S.drag = nil
            physLetGo()
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
    physTick(sec)
    send()
    -- measure a newly picked object once it rests
    if S.sel and S.target and (not S.shape or S.shape.id ~= S.sel.id) and not S.dirty and not S.drag and not S.phys and lastApplied() then
        pcall(scanStart)
    end
    local okScan, errScan = pcall(scanTick)
    if not okScan then reskate.log("Quick Drop helper: measuring failed: " .. tostring(errScan), "warn"); if S.shape then S.shape.done = true; S.shape.count = 0 end end
end)

-- ---------------------------------------------------------------- drawing the handles
local function colourOf(base, hot) return hot and YELLOW or base end

reskate.on("draw", function(d)
    if not S.open then return end
    S.size = d:size()
    local cpos, f, r, u = camBasis()
    local probe = d:world_to_screen(cpos + f * 10 + r * 1 + u * 1)
    if probe then
        local mx, my = (probe.x - S.size.x / 2) / 0.1, (S.size.y / 2 - probe.y) / 0.1
        if math.abs(mx) > 1 and math.abs(my) > 1 then S.proj = V(mx, my, 0) end
    end
    S.screen = {}
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
    if S.sel.bp then
        S.boundsCache = S.boundsCache or {}
        local bx = S.boundsCache[S.sel.bp]
        if bx == nil then
            local ok, a, b = false, nil, nil
            if reskate.entities then ok, a, b = pcall(reskate.entities.bounds, S.sel.bp) end
            if ok and type(a) == "table" and a.min then a, b = a.min, a.max end
            bx = (ok and a and b) and { a, b } or false
            S.boundsCache[S.sel.bp] = bx
        end
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
    end
    if not S.boxCorners then
        local sh = S.shape
        if not S.handleLen and sh and sh.done and sh.id == S.sel.id and (sh.ext or 0) > 0 then S.handleLen = clamp(sh.ext * t.scale * 0.9, 0.6, 6) end
        drawShape(d, t, S.dirty or (S.drag and S.drag.moved) or S.phys ~= nil or not lastApplied())
    end
    -- the handles keep a steady size on screen (about 130 pixels)
    local L = S.handleLen or 1.5
    L = math.max(L, 0.05)
    local hv, dg = S.hover, S.drag
    local function hot(kind, i)
        local h = dg or hv
        return h and h.kind == kind and (i == nil or h.axis == i or h.plane == i)
    end

    if S.mode == 1 then
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
    -- the object's box where it is going: shows at once while the game catches up
    if S.boxCorners and S.mode ~= 3 then
        local c = S.boxCorners
        local col = (S.dirty or (S.drag and S.drag.moved)) and "#ffe066" or "#ffffff66"
        for _, e in ipairs(BOX_EDGES) do
            d:world_line(c[e[1]], c[e[2]], { colour = col, thickness = 2 })
        end
    end
end)

reskate.on("load", function() reskate.log("Quick Drop helper ready: drop an object, then F6 (or hold Ctrl and use [ ] PgUp PgDn Z X arrows).") end)
