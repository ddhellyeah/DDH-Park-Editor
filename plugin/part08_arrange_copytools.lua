-- DDH Park Editor, part08_arrange_copytools: arranging a group, grid snapping, copy tools (row / circle / grid).
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local MAX_COPIES = PE.MAX_COPIES
local S = PE.S
local STEPS = PE.STEPS
local UI = PE.UI
local UP = PE.UP
local V = PE.V
local clamp = PE.clamp
local extentAlong = PE.extentAlong
local markUndo = PE.markUndo
local padPress = PE.padPress
local padStep = PE.padStep
local placedSolid = PE.placedSolid
local poseOf = PE.poseOf
local queueCopies = PE.queueCopies
local rotY = PE.rotY
local round = PE.round
local say = PE.say
local select = PE.select
local tiltPoint = PE.tiltPoint
local tilted = PE.tilted
local worldShape = PE.worldShape
local wrap = PE.wrap

-- ---------------------------------------------------------------- arranging a group: mirror, line up, space, level
-- Seen from the picked one (its turn gives "left / right" and "front / back"); one undo puts them all back.
function S.arrange(kind)
    if not S.sel then
        for id in pairs(S.group) do local o = S.known and S.known[id]; if o then select(o) break end end
    end
    if not (S.sel and S.target) then say("Pick objects first (hold A and sweep, or Ctrl+click).", true) return end
    S.group[S.sel.id] = true
    local ids = {}
    for id in pairs(S.group) do if S.known and S.known[id] then ids[#ids + 1] = id end end
    if #ids < 2 then say("Select two or more objects to arrange them.", true) return end
    markUndo()
    S.gbase = nil
    local h0 = S.target.heading
    local poses = {}
    local cx, cz, n = 0, 0, 0
    for _, id in ipairs(ids) do
        local p = (id == S.sel.id) and S.target or poseOf(id)
        poses[id] = { pos = p.pos, heading = p.heading, scale = p.scale }
        cx += p.pos.x; cz += p.pos.z; n += 1
    end
    local C = V(cx / n, 0, cz / n)
    local function loc(p) return rotY(V(p.x - C.x, 0, p.z - C.z), -h0) end
    local function wld(l, y) local w = rotY(l, h0); return V(C.x + w.x, y, C.z + w.z) end
    local L = loc(S.target.pos)
    if kind == "space" then
        table.sort(ids, function(a, b) return loc(poses[a].pos).x < loc(poses[b].pos).x end)
    end
    local x0, x1 = math.huge, -math.huge
    for _, id in ipairs(ids) do local l = loc(poses[id].pos); x0 = math.min(x0, l.x); x1 = math.max(x1, l.x) end
    for i, id in ipairs(ids) do
        local p = poses[id]
        local l = loc(p.pos)
        local a = wrap(p.heading - h0)
        local np, nh = p.pos, p.heading
        if kind == "mirrorX" then np = wld(V(-l.x, 0, l.z), p.pos.y); nh = wrap(h0 - a)
        elseif kind == "mirrorZ" then np = wld(V(l.x, 0, -l.z), p.pos.y); nh = wrap(h0 + math.pi - a)
        elseif kind == "lineup" then np = wld(V(l.x, 0, L.z), p.pos.y)
        elseif kind == "space" then np = wld(V(x0 + (x1 - x0) * (i - 1) / (#ids - 1), 0, l.z), p.pos.y)
        elseif kind == "level" then np = V(p.pos.x, S.target.pos.y, p.pos.z) end
        if id == S.sel.id then
            S.target = { pos = np, heading = nh, scale = p.scale }
            S.dirty = true
        else
            S.gt[id] = { pos = np, heading = nh, scale = p.scale }
        end
    end
    local words = { mirrorX = "Mirrored left / right", mirrorZ = "Mirrored front / back", lineup = "Lined up", space = "Spaced evenly", level = "Same height" }
    say(string.format("%s: %d objects.  (Undo puts them back)", words[kind] or kind, #ids))
end

-- ---------------------------------------------------------------- grid snapping
FN.GRIDS = { 0, 0.25, 0.5, 1, 2 }
FN.GRID_NAMES = { "Off", "0.25 m", "0.5 m", "1 m", "2 m" }
S.gridI = 1
function FN.gridSize() return FN.GRIDS[S.gridI] or 0 end
-- on the ground grid (x and z), when nothing else is snapped to
function FN.gridSnap(p, guides)
    local g = FN.gridSize()
    if g <= 0 or (guides and #guides > 0) then return p end
    return V(round(p.x, g), p.y, round(p.z, g))
end

-- ---------------------------------------------------------------- copy tools: a row, a circle or a grid of copies
S.tools = { kind = 1, count = 5, count2 = 3, dir = 1, gap = 0, radius = 5, face = 1 }
FN.KINDS = { "Row", "Circle", "Grid" }
FN.DIRS = { "Sideways", "Forward", "Up" }
FN.FACES = { "To the middle", "Same way" }
local function cyc(v, n, d) return (v - 1 + d) % n + 1 end
function FN.planCopies()
    if not (S.sel and S.target) then return {} end
    local T = S.tools
    local list = FN.heldList()
    local L = S.target
    local X = V(math.cos(L.heading), 0, -math.sin(L.heading))
    local Z = V(math.sin(L.heading), 0, math.cos(L.heading))
    local out = {}
    local function add(off, turn, about, keepHeading)
        for _, s in ipairs(list) do
            local p, h = s.pos, s.heading
            if turn ~= 0 then
                p = about + rotY(p - about, turn)
                if not keepHeading then h = wrap(h + turn) end
            end
            out[#out + 1] = { item = s.item, pos = p + off, heading = h, scale = s.scale, tilt = s.tilt }
        end
    end
    if T.kind == 1 then
        local dir = ({ X, Z, UP })[T.dir]
        local step = extentAlong(list, dir) + T.gap
        for i = 1, T.count - 1 do add(dir * (step * i), 0) end
    elseif T.kind == 2 then
        local c = L.pos - Z * T.radius
        for i = 1, T.count - 1 do add(V(0, 0, 0), i * 2 * math.pi / T.count, c, T.face == 2) end
    else
        local sx, sz = extentAlong(list, X) + T.gap, extentAlong(list, Z) + T.gap
        for i = 0, T.count - 1 do
            for j = 0, T.count2 - 1 do
                if i > 0 or j > 0 then add(X * (sx * i) + Z * (sz * j), 0) end
            end
        end
    end
    return out
end
function FN.toolsRows()
    local T = S.tools
    local st = STEPS[S.stepSize] or STEPS[2]
    local rows = {}
    rows[#rows + 1] = { "Make", FN.KINDS[T.kind], function(d) T.kind = cyc(T.kind, 3, d) end }
    rows[#rows + 1] = { T.kind == 3 and "Across" or "How many", tostring(T.count), function(d) T.count = clamp(T.count + d, 2, 50) end }
    if T.kind == 1 then
        rows[#rows + 1] = { "Which way", FN.DIRS[T.dir], function(d) T.dir = cyc(T.dir, 3, d) end }
        rows[#rows + 1] = { "Gap", string.format("%.2f m", T.gap), function(d) T.gap = clamp(round(T.gap + d * st.m, 0.01), -10, 50) end }
    elseif T.kind == 2 then
        rows[#rows + 1] = { "Size (radius)", string.format("%.2f m", T.radius), function(d) T.radius = clamp(round(T.radius + d * st.m * 5, 0.01), 0.25, 200) end }
        rows[#rows + 1] = { "Facing", FN.FACES[T.face], function(d) T.face = cyc(T.face, 2, d) end }
    else
        rows[#rows + 1] = { "Deep", tostring(T.count2), function(d) T.count2 = clamp(T.count2 + d, 1, 20) end }
        rows[#rows + 1] = { "Gap", string.format("%.2f m", T.gap), function(d) T.gap = clamp(round(T.gap + d * st.m, 0.01), -10, 50) end }
    end
    rows[#rows + 1] = { "Grid snap", FN.GRID_NAMES[S.gridI], function(d) S.gridI = cyc(S.gridI, #FN.GRIDS, d) end }
    rows[#rows + 1] = { "make" }
    return rows
end
function FN.makeCopies()
    local plan = FN.planCopies()
    if #plan == 0 then say("Pick an object first.") return end
    queueCopies(plan, FN.KINDS[S.tools.kind])
    S.toolsWin = nil
    say(string.format("Making %d copies (%s)...", math.min(#plan, MAX_COPIES), FN.KINDS[S.tools.kind]))
end
function FN.openTools()
    if not (S.sel and S.target) then say("Pick an object first, then open the copy tools.") return end
    S.toolsWin = { row = 1 }
end
S.openTools = FN.openTools
-- the controller in the window: D-pad up / down choose, left / right change, A makes them, B closes
function FN.toolsPad(p)
    local W = S.toolsWin
    local rows = FN.toolsRows()
    W.row = clamp(W.row, 1, #rows)
    if padPress("b", p.b) then S.toolsWin = nil return end
    if padPress("a", p.a) then FN.makeCopies() return end
    if padStep("tu", p.up) then W.row = clamp(W.row - 1, 1, #rows) end
    if padStep("td", p.down) then W.row = clamp(W.row + 1, 1, #rows) end
    local f = rows[W.row][3]
    if f and padStep("tl", p.left) then f(-1) end
    if f and padStep("tr", p.right) then f(1) end
end
-- the mouse in the window: < and > change a row, the button makes them; true when the click was the window's
function FN.toolsMouse(c)
    local box = S.screen and S.screen.toolsBox
    if not (S.toolsWin and box) then return false end
    local px = c.position
    local inside = px.x >= box.a.x and px.x <= box.b.x and px.y >= box.a.y and px.y <= box.b.y
    if not inside then return false end
    if c.left and not S.mouse.left then
        local rows = FN.toolsRows()
        for _, t in ipairs(S.screen.toolsTiles or {}) do
            if px.x >= t.a.x and px.x <= t.b.x and px.y >= t.a.y and px.y <= t.b.y then
                if t.make then FN.makeCopies()
                elseif t.close then S.toolsWin = nil
                elseif rows[t.row] and rows[t.row][3] then S.toolsWin.row = t.row; rows[t.row][3](t.d) end
                break
            end
        end
    end
    return true
end
function FN.drawTools(d)
    local W = S.toolsWin
    if not W then return end
    local plan = FN.planCopies()
    -- where the copies will go
    for i, c in ipairs(plan) do
        if i > MAX_COPIES then break end
        if S.itemBox[c.item] then
            PE.drawShape(d, worldShape(c.item, c.pos, c.heading, c.scale), UI.green, 2)
        else
            d:world_line(c.pos - V(0.4, 0, 0), c.pos + V(0.4, 0, 0), { colour = UI.green, thickness = 2 })
            d:world_line(c.pos - V(0, 0, 0.4), c.pos + V(0, 0, 0.4), { colour = UI.green, thickness = 2 })
        end
    end
    local rows = FN.toolsRows()
    W.row = clamp(W.row, 1, #rows)
    local rh, w = 44, 420
    local a = V(32, math.floor(S.size.y * 0.2), 0)
    local b = a + V(w, 52 + 14 + #rows * rh + 56, 0)
    S.screen.toolsBox = { a = a, b = b }
    S.screen.toolsTiles = {}
    UI.panelBox(d, a, b, "Copy tools")
    local ca, cb = V(b.x - 44, a.y + 10, 0), V(b.x - 12, a.y + 42, 0)
    d:text(V((ca.x + cb.x) / 2, ca.y + 4, 0), "×", { size = 22, colour = UI.dim, align = "centre" })
    table.insert(S.screen.toolsTiles, { a = ca, b = cb, close = true })
    for i, r in ipairs(rows) do
        local ra = V(a.x + 14, a.y + 62 + (i - 1) * rh, 0)
        local rb = V(b.x - 14, ra.y + rh - 6, 0)
        local selected = i == W.row
        if r[1] == "make" then
            d:rect(ra, rb, { colour = selected and UI.accent or UI.tileHot, fill = true, rounding = 10 })
            local n = math.min(#plan, MAX_COPIES)
            d:text(V((ra.x + rb.x) / 2, ra.y + 9, 0), string.format("Make %d cop%s", n, n == 1 and "y" or "ies"), { size = 17, colour = selected and "#0d1117" or UI.text, font = "bold", align = "centre" })
            table.insert(S.screen.toolsTiles, { a = ra, b = rb, make = true })
        else
            d:rect(ra, rb, { colour = selected and UI.accentDim or UI.tile, fill = true, rounding = 10 })
            if selected then d:rect(V(ra.x, ra.y + 8, 0), V(ra.x + 3, rb.y - 8, 0), { colour = UI.accent, fill = true, rounding = 2 }) end
            d:text(ra + V(16, 10, 0), r[1], { size = 16, colour = UI.dim })
            -- the value between < and >
            local vx0, vx1 = ra.x + 170, rb.x - 10
            local la, lb2 = V(vx0, ra.y, 0), V(vx0 + 30, rb.y, 0)
            local ga, gb = V(vx1 - 30, ra.y, 0), V(vx1, rb.y, 0)
            local col = selected and UI.accent or UI.dim
            d:text(V(la.x + 15, ra.y + 8, 0), "<", { size = 20, colour = col, align = "centre" })
            d:text(V((vx0 + vx1) / 2, ra.y + 10, 0), r[2], { size = 16, colour = selected and UI.text or UI.text, font = selected and "bold" or nil, align = "centre" })
            d:text(V(ga.x + 15, ra.y + 8, 0), ">", { size = 20, colour = col, align = "centre" })
            table.insert(S.screen.toolsTiles, { a = la, b = lb2, row = i, d = -1 })
            table.insert(S.screen.toolsTiles, { a = ga, b = gb, row = i, d = 1 })
        end
    end
    UI.footer(d, a, b, { { "D-pad", "Choose" }, { "a", "Make" }, { "b", "Close" } })
end

-- the group as it is (and where its followers are going)
function FN.drawGroup(d)
    for id in pairs(S.group) do
        local o = S.known and S.known[id]
        if o and not (S.sel and S.sel.id == id and S.grab) then
            local g = S.gt[id]
            if g and S.itemBox[o.item] then
                local tl = tilted(id) and S.tilt[id] or nil
                local xf = tl and function(v) return tiltPoint(g.pos, g.heading, tl, v) end or nil
                PE.drawShape(d, worldShape(o.item, g.pos, g.heading, g.scale), "#c49bff", 3, xf)
            else
                local so = placedSolid(o)
                if not PE.drawShape(d, so.shape or so, "#c49bff", 3, so.xf) then
                    local q = o.position
                    d:world_line(q - V(0.4, 0, 0), q + V(0.4, 0, 0), { colour = "#c49bff", thickness = 3 })
                    d:world_line(q - V(0, 0, 0.4), q + V(0, 0, 0.4), { colour = "#c49bff", thickness = 3 })
                end
            end
        end
    end
end
-- a few lines of the ground grid round the held object
function FN.drawGrid(d)
    local g = FN.gridSize()
    if g <= 0 or not S.target then return end
    local p = S.target.pos
    local cx, cz = round(p.x, g), round(p.z, g)
    local n = 6
    for i = -n, n do
        d:world_line(V(cx + i * g, p.y, cz - n * g), V(cx + i * g, p.y, cz + n * g), { colour = "#ffffff30", thickness = 1 })
        d:world_line(V(cx - n * g, p.y, cz + i * g), V(cx + n * g, p.y, cz + i * g), { colour = "#ffffff30", thickness = 1 })
    end
end

end
