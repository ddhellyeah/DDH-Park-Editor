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
        d:rect(V(W / 2 - w / 2, H - 112, 0), V(W / 2 + w / 2, H - 84, 0), { colour = "#0d1117b0", fill = true, rounding = 14 })
        d:text(V(W / 2, H - 107, 0), msg, { size = 15, colour = UI.dim, align = "centre" })
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
    if items then UI.promptRow(d, W / 2, H - 48, items) end
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
    if S.ro and S.ro.id == sel.id and S.clock - S.ro.at < 100 then return S.ro end
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

-- the see-through copy, its shadow and the height / gap, while holding
function FN.drawGhost(d, c, sh, p, center, moving)
    local holdingIt = S.grab or (S.drag and S.drag.moved)
    -- a see-through copy where it is going (while the game is still catching up)
    if moving and holdingIt then
        local FACES = { { 0, 2, 6, 4 }, { 1, 3, 7, 5 }, { 0, 1, 5, 4 }, { 2, 3, 7, 6 }, { 0, 1, 3, 2 }, { 4, 5, 7, 6 } }
        for _, fc in ipairs(FACES) do
            local sp = {}
            for k = 1, 4 do sp[k] = d:world_to_screen(c[fc[k]]) end
            if sp[1] and sp[2] and sp[3] and sp[4] then d:poly(sp, { colour = "#ffe0662a", fill = true }) end
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
PE.drawShape = function(d, sh, col, th, xf)
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
