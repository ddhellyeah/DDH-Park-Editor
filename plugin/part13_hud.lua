-- DDH Park Editor, part13_hud: the controller view, height and gap, drawing the handles.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local S = PE.S
local STEPS = PE.STEPS
local UI = PE.UI
local UP = PE.UP
local V = PE.V
local YELLOW = PE.YELLOW
local clamp = PE.clamp
local dot = PE.dot
local groupCount = PE.groupCount
local norm = PE.norm
local placedSolid = PE.placedSolid
local titleOf = PE.titleOf
local worldShape = PE.worldShape

-- ---------------------------------------------------------------- drawing the handles
local function colourOf(base, hot) return hot and YELLOW or base end

function UI.drawPadHud(d)
    local W, H = S.size.x, S.size.y
    -- (the picked object's numbers go along the bottom, under the prompts: those move up to make room)
    local rowsH = UI.padRowsSpace and UI.padRowsSpace() or 0
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
            PE.drawShape(d, so.shape or so, S.group[S.aim.id] and UI.purple or "#ffffff", 3, so.xf)
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
    if S.grab then
        if S.noSnap then chips[#chips + 1] = { "Snap  off (R3 held)", UI.orange }
        else chips[#chips + 1] = { "Snap  " .. FN.snapLabel(), S.snapPick and UI.orange or "#35e0ff" } end
    end
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
        d:rect(V(W / 2 - w / 2, H - 112 - rowsH, 0), V(W / 2 + w / 2, H - 84 - rowsH, 0), { colour = "#0d1117b0", fill = true, rounding = 14 })
        d:text(V(W / 2, H - 107 - rowsH, 0), msg, { size = 15, colour = UI.dim, align = "centre" })
    end
    -- the buttons for what can be done now
    local items
    if S.toolsWin then
        items = nil
    elseif selecting then
        items = { { "a", "Let go: done" } }
    elseif S.grab then
        items = { { "a", "Put down" }, { "b", "Cancel" }, { "x", "Copy" }, { "LB RB", "Turn" }, { "D-pad L R", "Zoom" }, { "R3", "Tools" }, { "Hold R3", "No snap" }, { "View L3", "Snap" } }
    elseif S.aim and S.group[S.aim.id] then
        items = { { "a", "Pick up all" }, { "x", "Copy all" }, { "y", "Take out  ·  twice: delete all" }, { "LB", "Clear group" } }
    elseif S.aim then
        items = { { "a", "Pick up" }, { "Hold A", "Select" }, { "x", "Copy" }, { "y", "Remove" }, { "RB", "Group" } }
    else
        items = { { "a", "Add object" }, { "Hold A", "Select" }, { "Menu", "Steps" }, { "b", "Close" } }
    end
    if items then UI.promptRow(d, W / 2, H - 48 - rowsH, items) end
    if rowsH > 0 then UI.padRows(d) else S.padRowsAt = nil end
end

-- ---------------------------------------------------------------- height and gap while holding
-- how far one outline is from another seen from above (0 when they overlap)
function FN.polyGap(A, B)
    local function inside(q, P)
        local c = false
        local n = #P
        for i = 1, n do
            local a, b = P[i], P[i % n + 1]
            if (a.z > q.z) ~= (b.z > q.z) and q.x < a.x + (q.z - a.z) / (b.z - a.z) * (b.x - a.x) then c = not c end
        end
        return c
    end
    local function segD(q, a, b)
        local ab = V(b.x - a.x, 0, b.z - a.z)
        local l2 = ab.x * ab.x + ab.z * ab.z
        local k = l2 > 1e-12 and clamp(((q.x - a.x) * ab.x + (q.z - a.z) * ab.z) / l2, 0, 1) or 0
        local dx, dz = q.x - (a.x + ab.x * k), q.z - (a.z + ab.z * k)
        return math.sqrt(dx * dx + dz * dz)
    end
    for _, q in ipairs(A) do if inside(q, B) then return 0 end end
    for _, q in ipairs(B) do if inside(q, A) then return 0 end end
    local best = math.huge
    for _, P in ipairs({ { A, B }, { B, A } }) do
        local X, Y = P[1], P[2]
        for _, q in ipairs(X) do
            for i = 1, #Y do best = math.min(best, segD(q, Y[i], Y[i % #Y + 1])) end
        end
    end
    return best
end
S.readoutOn = true
-- what the held object is over (its height above it) and the nearest object beside it (the gap): looked at 10 times a second
function FN.readout()
    local t, sel = S.target, S.sel
    if not (t and sel) then S.ro = nil return nil end
    if S.ro and S.ro.id == sel.id and S.clock - S.ro.at < 250 then return S.ro end
    local ro = { id = sel.id, at = S.clock }
    local okL, y = pcall(FN.supportY, sel.item, t.pos, t.heading, t.scale, sel.id)
    if okL and y then ro.h = t.pos.y - y; ro.groundY = y end
    if S.itemBox[sel.item] then
        local me = worldShape(sel.item, t.pos, t.heading, t.scale)
        if me.pts and #me.pts >= 3 then
            local skip = { [sel.id] = true }
            for id in pairs(S.group) do skip[id] = true end
            for _, id in ipairs(FN.nearestTo(t.pos, 6, skip)) do
                local o = S.known and S.known[id]
                if o and S.itemBox[o.item] then
                    local sh = worldShape(o.item, o.position, o.heading or 0, o.scale or 1)
                    -- only beside it (at the same height somewhere)
                    if sh.pts and #sh.pts >= 3 and sh.ylo < me.yhi - 0.02 and sh.yhi > me.ylo + 0.02 then
                        local g = FN.polyGap(me.pts, sh.pts)
                        if g < 8 and (not ro.gap or g < ro.gap) then ro.gap, ro.gapName = g, titleOf(o.item) end
                    end
                end
            end
        end
    end
    S.ro = ro
    return ro
end

-- an outline seen from above (points going round) cut into triangles, so a curved or L-shaped top fills
-- right. Gives triangles as three point numbers each.
function FN.outlineTriangles(pts)
    local n = #pts
    local idx = {}
    for i = 1, n do idx[i] = i end
    local area = 0
    for i = 1, n do
        local a, b = pts[i], pts[i % n + 1]
        area += a.x * b.z - b.x * a.z
    end
    local sgn = area >= 0 and 1 or -1
    local function turn(a, b, c) return ((b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)) * sgn end
    local tris = {}
    local guard = 0
    while #idx > 3 and guard < 4 * n do
        guard += 1
        local m = #idx
        local cut = false
        for i = 1, m do
            local ia, ib, ic = idx[(i - 2) % m + 1], idx[i], idx[i % m + 1]
            local a, b, c = pts[ia], pts[ib], pts[ic]
            local tb = turn(a, b, c)
            if math.abs(tb) < 1e-9 then
                -- a point on a straight side: no triangle, just leave it out
                table.remove(idx, i); cut = true; break
            elseif tb > 0 then
                local free = true
                for _, j in ipairs(idx) do
                    if j ~= ia and j ~= ib and j ~= ic then
                        local q = pts[j]
                        if turn(a, b, q) >= 0 and turn(b, c, q) >= 0 and turn(c, a, q) >= 0 then free = false break end
                    end
                end
                if free then
                    tris[#tris + 1] = { ia, ib, ic }
                    table.remove(idx, i); cut = true; break
                end
            end
        end
        if not cut then break end
    end
    -- what is left (3 points, or an outline too odd to cut): a fan
    for i = 2, #idx - 1 do tris[#tris + 1] = { idx[1], idx[i], idx[i + 1] } end
    return tris
end

-- the see-through copy, its shadow and the height / gap, while holding
function FN.drawGhost(d, c, sh, p, center, moving, xf)
    local holdingIt = S.grab or (S.drag and S.drag.moved)
    -- a see-through copy where it is going (while the game is still catching up). Drawn from the same outline as
    -- the yellow lines, so the two always match; only an object with no outline uses its box.
    -- (an object drawn from its model's edges needs none: its yellow lines already show it exactly)
    local exact = nil
    if sh then if FN.outlineOf then exact = FN.outlineOf(sh.item) else exact = FN.wireOf(sh.item) end end
    if moving and holdingIt and not exact then
        local FILL = { colour = "#ffe0662a", fill = true }
        local pts = sh and sh.pts
        if pts and #pts >= 3 then
            local W = xf or function(v) return v end
            local n = #pts
            local base, up = UP * (sh.ylo - p.y), UP * (sh.yhi - sh.ylo)
            local lo, hi = {}, {}
            for i = 1, n do
                lo[i] = d:world_to_screen(W(pts[i] + base))
                hi[i] = d:world_to_screen(W(pts[i] + base + up))
            end
            -- the sides
            for i = 1, n do
                local j = i % n + 1
                if lo[i] and lo[j] and hi[j] and hi[i] then d:poly({ lo[i], lo[j], hi[j], hi[i] }, FILL) end
            end
            -- the top and the bottom (the triangles are worked out once per object and kept)
            S.ghostTris = S.ghostTris or {}
            local key = S.sel and S.sel.item or ""
            local gt = S.ghostTris[key]
            if not (gt and gt.n == n) then
                local ok, tris = pcall(FN.outlineTriangles, pts)
                gt = { n = n, tris = ok and tris or {} }
                S.ghostTris[key] = gt
            end
            for _, tr in ipairs(gt.tris) do
                local a, b, e = hi[tr[1]], hi[tr[2]], hi[tr[3]]
                if a and b and e then d:poly({ a, b, e }, FILL) end
                a, b, e = lo[tr[1]], lo[tr[2]], lo[tr[3]]
                if a and b and e then d:poly({ a, b, e }, FILL) end
            end
        else
            local FACES = { { 0, 2, 6, 4 }, { 1, 3, 7, 5 }, { 0, 1, 5, 4 }, { 2, 3, 7, 6 }, { 0, 1, 3, 2 }, { 4, 5, 7, 6 } }
            for _, fc in ipairs(FACES) do
                local sp = {}
                for k = 1, 4 do sp[k] = d:world_to_screen(c[fc[k]]) end
                if sp[1] and sp[2] and sp[3] and sp[4] then d:poly(sp, FILL) end
            end
        end
    end
    -- its shadow on what is under it, with a line down to it when it is in the air; and the height and gap
    if holdingIt and S.readoutOn then
        local okR, ro = pcall(FN.readout)
        if okR and ro then
            local lines = {}
            if ro.h and ro.groundY then
                if ro.h > 0.02 and sh and sh.pts and #sh.pts >= 3 then
                    local gy = V(0, ro.groundY - (p.y + (sh.ylo - p.y)), 0)
                    local n = #sh.pts
                    for i = 1, n do
                        local a2, b2 = sh.pts[i] + V(0, sh.ylo - p.y, 0) + gy, sh.pts[i % n + 1] + V(0, sh.ylo - p.y, 0) + gy
                        d:world_line(a2, b2, { colour = "#ffffff55", thickness = 2 })
                    end
                    local bc = V(p.x, sh.ylo, p.z)
                    d:world_line(bc, V(p.x, ro.groundY, p.z), { colour = "#ffffff70", thickness = 2 })
                end
                lines[#lines + 1] = ro.h > 0.005 and string.format("height %.2f m", ro.h) or "resting"
            end
            if ro.gap then
                lines[#lines + 1] = ro.gap < 0.005 and ("touching " .. FN.shortTitle(ro.gapName, 18)) or string.format("gap %.2f m to %s", ro.gap, FN.shortTitle(ro.gapName, 18))
            end
            if #lines > 0 then
                d:text(center + V(16, 34, 0), table.concat(lines, "   ·   "), { size = 15, colour = "#ffffff", shadow = true })
            end
        end
    end
end

-- an outline as it stands: round its base, round its top, and up its corners
FN.COS25 = math.cos(math.rad(25))
-- The real edges of the Object Maker's objects (wires.lua beside this file, made from their models): their outlines
-- are drawn from these, so they show the object as it is (a rail's tube and legs, a ramp's curve), not a box.
-- Each object's list (x1, y1, z1, x2, y2, z2, ... in metres, from the middle of its base, unturned) is read the
-- first time it is drawn. The game's own objects have none and keep their box.
S.wireCache = {}
function FN.wireOf(item)
    if not item then return nil end
    local c = S.wireCache[item]
    if c ~= nil then return c or nil end
    if S.wires == nil then
        local ok, t = pcall(function() return require("wires") end)
        S.wires = (ok and type(t) == "table") and t or false
        if not S.wires then reskate.log("Quick Drop helper: no wires.lua: outlines are boxes", "warn") end
    end
    local str = S.wires and S.wires[item]
    if type(str) ~= "string" or str == "" then S.wireCache[item] = false return nil end
    local a = {}
    for num in string.gmatch(str, "-?%d+") do a[#a + 1] = tonumber(num) * 0.01 end
    if #a < 6 then S.wireCache[item] = false return nil end
    S.wireCache[item] = a
    return a
end
-- lines drawn from models in one frame at most (past it, the rest get their boxes: a big group stays quick)
local WIRE_BUDGET = 2500
local function drawWire(d, sh, col, th, xf)
    local w
    if FN.outlineOf then w = FN.outlineOf(sh.item) else w = FN.wireOf(sh.item) end
    if not (w and sh.p and sh.ax and sh.az) then return false end
    local n = #w // 6
    if S.wireAt ~= S.clock then S.wireAt, S.wireUsed = S.clock, 0 end
    if S.wireUsed + n > WIRE_BUDGET then return false end
    S.wireUsed += n
    local sc = sh.scale or 1
    local p, X, Y, Z = sh.p, sh.ax * sc, UP * sc, sh.az * sc
    local style = { colour = col, thickness = n > 80 and math.min(th, 2) or th }
    for i = 1, #w - 5, 6 do
        local a = p + X * w[i] + Y * w[i + 1] + Z * w[i + 2]
        local b = p + X * w[i + 3] + Y * w[i + 4] + Z * w[i + 5]
        if xf then a, b = xf(a), xf(b) end
        d:world_line(a, b, style)
    end
    return true
end
PE.drawShape = function(d, sh, col, th, xf)
    if sh.item and drawWire(d, sh, col, th, xf) then return true end
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

-- shared with the parts after this one
PE.colourOf = colourOf
end
