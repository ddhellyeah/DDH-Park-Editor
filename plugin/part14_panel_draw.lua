-- DDH Park Editor, part14_panel_draw: the panel on the right drawn over the view, and the draw hook.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local BOX_EDGES = PE.BOX_EDGES
local FN = PE.FN
local GREEN = PE.GREEN
local PLANES = PE.PLANES
local S = PE.S
local STEPS = PE.STEPS
local UI = PE.UI
local V = PE.V
local axesFor = PE.axesFor
local camBasis = PE.camBasis
local clamp = PE.clamp
local closeEditor = PE.closeEditor
local colourOf = PE.colourOf
local cornersOf = PE.cornersOf
local endHoldMove = PE.endHoldMove
local findMissing = PE.findMissing
local groupCount = PE.groupCount
local lastApplied = PE.lastApplied
local len = PE.len
local markUndo = PE.markUndo
local placedSolid = PE.placedSolid
local round = PE.round
local say = PE.say
local select = PE.select
local send = PE.send
local tiltPoint = PE.tiltPoint
local tilted = PE.tilted
local titleOf = PE.titleOf
local undo = PE.undo
local worldShape = PE.worldShape
local wrap = PE.wrap

-- ---------------------------------------------------------------- the panel on the right, drawn over the view
-- (a screen without ReSkate's own panel: everything here is drawn, and clicks on it are kept from the view)
-- (in a function of its own: its many locals don't count against the file's limit)
;(function()
    local PW = 384
    local tiles = {}
    local function hot(a, b)
        local m = S.mouse and S.mouse.pos
        return m ~= nil and m.x >= a.x and m.x <= b.x and m.y >= a.y and m.y <= b.y
    end
    local function tileAdd(a, b, fn) tiles[#tiles + 1] = { a = a, b = b, fn = fn } end
    -- ---- text that fits: measured with the game's own font (kept, as measuring every frame costs), made smaller
    -- (to 10 px) when it would not fit its room, then shortened with "…"; and set in the middle of its box's height
    local mcache, mcount = {}, 0
    local function measure(d, str, size, font)
        local k = str .. "\1" .. size .. "\1" .. tostring(font)
        local m = mcache[k]
        if m then return m end
        local ok, v = pcall(function() return d:measure(str, { size = size, font = font }) end)
        if ok and v and v.x then m = { v.x, v.y } else m = { #str * size * 0.55, size * 1.25 } end
        mcount += 1
        if mcount > 4000 then mcache, mcount = {}, 0 end
        mcache[k] = m
        return m
    end
    local function fitted(d, str, size, font, maxW)
        str = tostring(str)
        local m = measure(d, str, size, font)
        if m[1] <= maxW then return str, size, m end
        size = math.max(10, math.floor(size * maxW / m[1] * 10) / 10)
        m = measure(d, str, size, font)
        local base = str
        while m[1] > maxW and (utf8.len(base) or 0) > 1 do
            base = string.sub(base, 1, (utf8.offset(base, -1) or #base) - 1)
            str = base .. "…"
            m = measure(d, str, size, font)
        end
        return str, size, m
    end
    -- text at x, y (its top), at most maxW wide
    -- text over several lines: split at spaces so each line measures within maxW (a word too long by itself is
    -- fitted on its own line); returns the lines, the widest line's width and the line height
    local function wrapLines(d, str, size, font, maxW)
        local lines, cur = {}, nil
        for word in string.gmatch(tostring(str), "%S+") do
            local try = cur and (cur .. " " .. word) or word
            if cur and measure(d, try, size, font)[1] > maxW then
                lines[#lines + 1] = cur
                cur = word
            else
                cur = try
            end
        end
        if cur then lines[#lines + 1] = cur end
        local wmax, lh = 0, measure(d, "Ag", size, font)[2]
        for i, l in ipairs(lines) do
            local s2, _, m = fitted(d, l, size, font, maxW)
            lines[i] = s2
            wmax = math.max(wmax, m[1])
        end
        return lines, wmax, lh
    end
    local function fitText(d, x, y, str, maxW, st)
        local s2, size = fitted(d, str, st.size or 18, st.font, maxW)
        d:text(V(x, y, 0), s2, { size = size, colour = st.colour, font = st.font, align = st.align, shadow = st.shadow })
    end
    -- text in a box: fitted to its width less pad each side, in the middle of its height; align left, centre or right
    local function textIn(d, a, b, str, st, pad)
        pad = pad or 8
        local s2, size, m = fitted(d, str, st.size or 18, st.font, (b.x - a.x) - 2 * pad)
        local ty = a.y + ((b.y - a.y) - m[2]) / 2
        local al = st.align or "left"
        local tx = al == "centre" and (a.x + b.x) / 2 or (al == "right" and b.x - pad or a.x + pad)
        d:text(V(tx, ty, 0), s2, { size = size, colour = st.colour, font = st.font, align = al, shadow = st.shadow })
    end
    UI.fitText, UI.textIn = fitText, textIn
    -- an edge in the border colour
    local function edge(d, a, b, r) d:rect(a, b, { colour = UI.border, rounding = r or 6, thickness = 1 }) end
    UI.edge = edge
    local function btn(d, a, b, label, fn, style)
        local h = hot(a, b)
        local col = style == "primary" and (h and UI.accentHot or UI.accent) or (h and UI.fieldHot or UI.field)
        if style == "danger" then col = h and "#c93c37" or "#9e2f2b" end
        d:rect(a, b, { colour = col, fill = true, rounding = 6 })
        if style == "on" then d:rect(a, b, { colour = UI.accent, rounding = 6, thickness = 2 })
        elseif style ~= "primary" and style ~= "danger" then edge(d, a, b, 6) end
        local tc = style == "primary" and UI.onAccent or (style == "danger" and "#ffffff" or UI.text)
        textIn(d, a, b, label, { size = 14, colour = tc, font = (style == "primary" or style == "on") and "bold" or nil, align = "centre" }, 6)
        if fn then tileAdd(a, b, fn) end
    end
    -- ---- hiding the panels: an arrow tab on a panel's inner edge folds it away; a small tab stays to bring it back.
    -- Which are hidden is kept between games.
    S.hide = S.hide or {}
    do
        local okH, hd = pcall(reskate.storage.get, "panelsHidden")
        if okH and type(hd) == "table" then S.hide = hd end
    end
    local function toggleHide(key)
        S.hide[key] = not S.hide[key]
        pcall(reskate.storage.set, "panelsHidden", S.hide)
    end
    -- a small tab with an arrow pointing dir ("left", "right", "up", "down"); counted as part of the panels for the
    -- mouse unless noBox
    local function arrowTab(d, a, b, dir, fn, noBox)
        local h = hot(a, b)
        d:rect(a, b, { colour = h and UI.fieldHot or UI.panel, fill = true, rounding = 6 })
        edge(d, a, b, 6)
        local cx, cy, r = (a.x + b.x) / 2, (a.y + b.y) / 2, 6
        local pts
        if dir == "left" then pts = { V(cx + r * 0.6, cy - r, 0), V(cx + r * 0.6, cy + r, 0), V(cx - r * 0.7, cy, 0) }
        elseif dir == "right" then pts = { V(cx - r * 0.6, cy - r, 0), V(cx - r * 0.6, cy + r, 0), V(cx + r * 0.7, cy, 0) }
        elseif dir == "up" then pts = { V(cx - r, cy + r * 0.6, 0), V(cx + r, cy + r * 0.6, 0), V(cx, cy - r * 0.7, 0) }
        else pts = { V(cx - r, cy - r * 0.6, 0), V(cx + r, cy - r * 0.6, 0), V(cx, cy + r * 0.7, 0) } end
        d:poly(pts, { colour = h and UI.accent or UI.dim, fill = true })
        tileAdd(a, b, fn)
        if not noBox then S.screen.tabs = S.screen.tabs or {}; S.screen.tabs[#S.screen.tabs + 1] = { a = a, b = b } end
    end
    -- a row of choices, one of them on
    local function seg(d, x, y, w, labels, cur, fn)
        local n = #labels
        d:rect(V(x, y, 0), V(x + w, y + 34, 0), { colour = UI.field, fill = true, rounding = 8 })
        edge(d, V(x, y, 0), V(x + w, y + 34, 0), 8)
        local cw = (w - 6) / n
        for i, l in ipairs(labels) do
            local a, b = V(x + 3 + (i - 1) * cw, y + 3, 0), V(x + 3 + i * cw, y + 31, 0)
            local on = i == cur
            local h = hot(a, b)
            if on then d:rect(a, b, { colour = h and UI.accentHot or UI.accent, fill = true, rounding = 6 })
            elseif h then d:rect(a, b, { colour = UI.fieldHot, fill = true, rounding = 6 }) end
            textIn(d, a, b, l, { size = 14, colour = on and UI.onAccent or UI.text, font = on and "bold" or nil, align = "centre" }, 4)
            tileAdd(a, b, function() fn(i) end)
        end
        return y + 34
    end
    local function switch(d, x, y, w, label, on, fn)
        local a, b = V(x, y, 0), V(x + w, y + 34, 0)
        if hot(a, b) then d:rect(a, b, { colour = UI.field, fill = true, rounding = 6 }) end
        local sx = x + w - 48
        textIn(d, V(x + 2, y, 0), V(sx - 4, y + 34, 0), label, { size = 14, colour = UI.text })
        local ka, kb = V(sx, y + 6, 0), V(sx + 44, y + 28, 0)
        d:rect(ka, kb, { colour = on and UI.accent or UI.field, fill = true, rounding = 11 })
        if not on then edge(d, ka, kb, 11) end
        d:circle(V(on and sx + 33 or sx + 11, y + 17, 0), 8, { colour = on and UI.onAccent or UI.dim, fill = true })
        tileAdd(a, b, fn)
        return y + 34
    end
    -- label   [-]  value  [+]   (click the value to type it)
    local function stepRow(d, x, y, w, label, value, dec, inc, edit, off)
        -- (off: shown crossed out and doing nothing, as tilt online)
        if off then
            local bx = x + w - 196
            textIn(d, V(x, y + 2, 0), V(bx - 4, y + 30, 0), label, { size = 14, colour = UI.faint }, 4)
            d:rect(V(bx, y + 2, 0), V(bx + 196, y + 30, 0), { colour = UI.field, fill = true, rounding = 6 })
            textIn(d, V(bx, y + 2, 0), V(bx + 196, y + 30, 0), value, { size = 15, colour = UI.faint, align = "centre" })
            d:line(V(x + 2, y + 16, 0), V(x + w - 2, y + 16, 0), { colour = "#f85149b0", thickness = 2 })
            return y + 34
        end
        local bx = x + w - 196
        textIn(d, V(x, y + 2, 0), V(bx - 4, y + 30, 0), label, { size = 14, colour = UI.dim }, 4)
        local m1a, m1b = V(bx, y + 2, 0), V(bx + 30, y + 30, 0)
        local va, vb = V(bx + 34, y + 2, 0), V(bx + 162, y + 30, 0)
        local p1a, p1b = V(bx + 166, y + 2, 0), V(bx + 196, y + 30, 0)
        d:rect(m1a, m1b, { colour = hot(m1a, m1b) and UI.fieldHot or UI.field, fill = true, rounding = 6 }); edge(d, m1a, m1b, 6)
        textIn(d, m1a, m1b, "-", { size = 18, colour = UI.text, align = "centre" }, 2)
        d:rect(va, vb, { colour = hot(va, vb) and UI.fieldHot or UI.field, fill = true, rounding = 6 }); edge(d, va, vb, 6)
        textIn(d, va, vb, value, { size = 15, colour = UI.text, align = "centre" }, 6)
        d:rect(p1a, p1b, { colour = hot(p1a, p1b) and UI.fieldHot or UI.field, fill = true, rounding = 6 }); edge(d, p1a, p1b, 6)
        textIn(d, p1a, p1b, "+", { size = 18, colour = UI.text, align = "centre" }, 2)
        tileAdd(m1a, m1b, dec); tileAdd(p1a, p1b, inc); tileAdd(va, vb, edit)
        return y + 34
    end
    local labelW = PW - 36
    local function label(d, x, y, str)
        fitText(d, x + 2, y, string.upper(str), labelW, { size = 13, colour = UI.dim, font = "bold" })
        return y + 21
    end

    -- typing one number: a text box; "+2" adds 2
    local TYPE1 = "ddh_type1"
    local function typeOne(title, cur, fmtS, apply)
        S.typeOne = { apply = apply, cur = cur }
        local ok, why = pcall(reskate.ui.dialog, TYPE1, {
            title = title, message = "Type a number, then Enter. Start with + to add to it (+2, +-0.5).",
            field = { text = string.format(fmtS, cur), max = 40 },
            buttons = { { id = "apply", label = "Apply" }, { id = "close", label = "Cancel" } },
        })
        if not ok or why == false then S.typeOne = nil; say("Could not open the text box", true) else S.typing = true end
    end
    UI.typeOne = typeOne
    reskate.on("throwdown_ui", function(e)
        if e.action ~= "dialog" or e.args[1] ~= TYPE1 then return end
        local what = e.args[2]
        if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
        S.typing = false
        if what ~= "cancel" then pcall(reskate.ui.close_dialog, TYPE1) end
        local tw = S.typeOne
        S.typeOne = nil
        if what ~= "apply" or not tw then return end
        local str = string.gsub(tostring(e.args[3] or ""), ",", ".")
        str = string.gsub(str, "^%s+", ""):gsub("%s+$", ""):gsub("[m°x×]+$", "")
        local v
        if string.sub(str, 1, 1) == "+" then v = tonumber(string.sub(str, 2)); if v then v = tw.cur + v end else v = tonumber(str) end
        if v == nil then say("Not a number: " .. str, true) return end
        tw.apply(v)
    end)

    -- what a snap did, in words: from By Sides' own words, else from Classic's guides
    function FN.snapWords(guides)
        local g = guides and guides[1]
        if not g then return nil end
        if g.label then return g.label end
        local main, height, lined = nil, nil, false
        for _, q in ipairs(guides) do
            if q.height then height = q.height
            elseif q.kind == "touch" and not main then main = q.corner and "Corner on its side" or "Side to side"
            elseif q.kind == "match" and not main then main = "Same size, edges together"
            elseif q.kind == "turn" then main = main or "Same turn"
            elseif q.kind == "level" then lined = true end
        end
        main = main or (lined and "Lined up" or "Snapped")
        if lined and main ~= "Lined up" then main = main .. "  ·  lined up" end
        if height then main = main .. "  ·  " .. height .. " level" end
        return main
    end
    -- ---- the park's list in groups: DDH's objects by Quick Drop's families (groups.lua), the others by their
    -- category in the catalog; groups in the families' order, then the categories A to Z. Each group: a heading
    -- ({ head, n, open }), then its objects ({ o, indent }) unless folded (S.listFold, by name). Not grouped:
    -- the objects as they are.
    local famOf = nil
    local famOrder = {}
    local categoryOf
    local groupsMade = nil
    function UI.listGroups(objs, grouped)
        -- (made again only when the list or a fold changes, not every frame)
        local gm = groupsMade
        if gm and gm.objs == objs and gm.grouped == grouped and gm.foldV == S.listFoldV then return gm.out end
        local out = UI.makeListGroups(objs, grouped)
        groupsMade = { objs = objs, grouped = grouped, foldV = S.listFoldV, out = out }
        return out
    end
    function UI.makeListGroups(objs, grouped)
        if not grouped then
            local out = {}
            for i, o in ipairs(objs) do out[i] = { o = o } end
            return out
        end
        if not famOf then
            famOf = {}
            local okG, g = pcall(function() return require("groups") end)
            if okG and type(g) == "table" and type(g.families) == "table" then
                for i, f in ipairs(g.families) do
                    famOrder[f.title] = i
                    for _, k in ipairs(f.keys) do famOf[k] = f.title end
                end
            end
        end
        local by, names = {}, {}
        for _, o in ipairs(objs) do
            local nm = famOf[o.item] or categoryOf(o.item) or "Other"
            if not by[nm] then by[nm] = {}; names[#names + 1] = nm end
            table.insert(by[nm], o)
        end
        table.sort(names, function(a, b2)
            local fa, fb = famOrder[a], famOrder[b2]
            if fa and fb then return fa < fb elseif fa then return true elseif fb then return false end
            if a == "Other" then return false elseif b2 == "Other" then return true end
            return a < b2
        end)
        local out = {}
        S.listFold = S.listFold or {}
        for _, nm in ipairs(names) do
            local open = not S.listFold[nm]
            out[#out + 1] = { head = nm, n = #by[nm], open = open }
            if open then for _, o in ipairs(by[nm]) do out[#out + 1] = { o = o, indent = true } end end
        end
        return out
    end
    -- an item's category in the catalog (kept once read)
    local catOf = nil
    function categoryOf(item)
        if not catOf then
            local l = FN.catalog and FN.catalog() or {}
            if #l == 0 then return nil end
            catOf = {}
            for _, it in ipairs(l) do catOf[it.key] = it.category and tostring(it.category) or nil end
        end
        return catOf[item]
    end

    -- ---------------------------------------------------------------- the park, in a panel on the left: the group,
    -- arranging it, the park's objects (search, pick, delete) and saving it as a park mod
    -- the layout (as drawn on the design canvas): the Park panel in the top-left corner, the main panel in the
    -- top-right, both against the screen's edges; the snap bar along the top between them; the rows at the bottom
    -- Their sizes can be changed: drag a panel's inner edge (or its bottom edge) with the mouse. Kept between games,
    -- and kept within limits so what is in them always fits (the lowest widths are the ones the panels are laid out
    -- for: narrower, their labels would have to shrink).
    local SIZE_DEF = { lw = 203, lh = 847, rw = 243, rh = 880, sw = 1296, bw = 720 }
    local SIZE_LIM = { lw = { 190, 460 }, lh = { 640, 4000 }, rw = { 230, 480 }, rh = { 640, 4000 }, sw = { 640, 4000 }, bw = { 600, 1200 } }
    S.uiSize = {}
    do
        local okZ, z = pcall(reskate.storage.get, "panelSizes")
        if okZ and type(z) == "table" then for k, v in pairs(z) do if SIZE_DEF[k] and type(v) == "number" then S.uiSize[k] = v end end end
    end
    local function size(k)
        local lim = SIZE_LIM[k]
        return clamp(S.uiSize[k] or SIZE_DEF[k], lim[1], lim[2])
    end
    function UI.setSize(k, v, save)
        local lim = SIZE_LIM[k]
        S.uiSize[k] = clamp(math.floor(v + 0.5), lim[1], lim[2])
        if save then pcall(reskate.storage.set, "panelSizes", S.uiSize) end
    end
    -- where each is (moved by dragging its title, or the dotted handle): kept between games, always on the screen
    S.uiPos = {}
    do
        local okP, z = pcall(reskate.storage.get, "panelPos")
        if okP and type(z) == "table" then
            for k, v in pairs(z) do if type(v) == "table" and type(v.x) == "number" and type(v.y) == "number" then S.uiPos[k] = { x = v.x, y = v.y } end end
        end
    end
    local function place(key, w, h, dx, dy)
        local W, H = S.size.x, S.size.y
        local p = S.uiPos[key]
        local x, y = dx, dy
        if p then x, y = p.x, p.y end
        return clamp(x, 0, math.max(0, W - w)), clamp(y, 0, math.max(0, H - h))
    end
    local function savePlaces()
        pcall(reskate.storage.set, "panelSizes", S.uiSize)
        pcall(reskate.storage.set, "panelPos", S.uiPos)
    end
    function UI.resetSizes() S.uiSize, S.uiPos = {}, {}; savePlaces() end
    -- the handles (built as the panels are drawn): moving ones, and the resize arrows in the bottom corners
    local handles = {}
    local function mover(d, key, a, b, box, dots)
        handles[#handles + 1] = { kind = "move", key = key, a = a, b = b, box = box }
        if dots then
            local on = (S.resize and S.resize.key == key and S.resize.kind == "move") or hot(a, b)
            local cx, cy = (a.x + b.x) / 2, (a.y + b.y) / 2
            for i = -1, 1 do for j = -1, 0 do
                d:circle(V(cx + j * 5 + 2.5, cy + i * 6, 0), 1.6, { colour = on and UI.accent or UI.dim, fill = true })
            end end
        end
    end
    -- side "l" or "r": that bottom corner; wkey the width it changes, hkey the height (nil: the height follows what is in it)
    local function corner(d, key, box, side, wkey, hkey)
        local a, b = box.a, box.b
        local ga = side == "r" and V(b.x - 20, b.y - 20, 0) or V(a.x, b.y - 20, 0)
        local gb = side == "r" and V(b.x, b.y, 0) or V(a.x + 20, b.y, 0)
        handles[#handles + 1] = { kind = "corner", key = key, side = side, wkey = wkey, hkey = hkey, a = ga, b = gb, box = box }
        local rz = S.resize
        local on = (rz and rz.kind == "corner" and rz.key == key and rz.side == side) or hot(ga, gb)
        local col = on and UI.accent or UI.dim
        -- a small arrow pointing out of the corner
        if side == "r" then d:poly({ V(b.x - 4, b.y - 13, 0), V(b.x - 4, b.y - 4, 0), V(b.x - 13, b.y - 4, 0) }, { colour = col, fill = true })
        else d:poly({ V(a.x + 4, b.y - 13, 0), V(a.x + 13, b.y - 4, 0), V(a.x + 4, b.y - 4, 0) }, { colour = col, fill = true }) end
    end
    -- the mouse on a handle: moves or resizes (true while it does, so nothing else takes the mouse)
    function UI.gripMouse(c)
        local px = c.position
        local rz = S.resize
        if rz then
            if not c.left then S.resize = nil; savePlaces() return true end
            local dx, dy = px.x - rz.from.x, px.y - rz.from.y
            if rz.kind == "move" then
                S.uiPos[rz.key] = { x = rz.pos.x + dx, y = rz.pos.y + dy }
            else
                -- (its place is fixed first, so it grows from the other corner)
                local w0 = rz.w0
                UI.setSize(rz.wkey, rz.side == "r" and (w0 + dx) or (w0 - dx))
                local nw = size(rz.wkey)
                if rz.hkey then UI.setSize(rz.hkey, rz.h0 + dy) end
                S.uiPos[rz.key] = { x = rz.side == "r" and rz.pos.x or (rz.pos.x + w0 - nw), y = rz.pos.y }
            end
            return true
        end
        if c.left and not S.mouse.left then
            for i = #handles, 1, -1 do
                local g = handles[i]
                if px.x >= g.a.x and px.x <= g.b.x and px.y >= g.a.y and px.y <= g.b.y then
                    S.resize = { kind = g.kind, key = g.key, side = g.side, wkey = g.wkey, hkey = g.hkey, from = px, pos = { x = g.box.a.x, y = g.box.a.y },
                        w0 = g.wkey and size(g.wkey) or 0, h0 = g.hkey and (g.box.b.y - g.box.a.y) or 0 }
                    return true
                end
            end
        end
        return false
    end
    function UI.gripsClear() handles = {} end
    local function parkPanel(d)
        local W, H = S.size.x, S.size.y
        if S.hide.left then
            local ta, tb = V(0, H / 2 - 40, 0), V(26, H / 2 + 40, 0)
            S.screen.leftBox, S.screen.leftEdge, S.screen.listBox = nil, tb.x, nil
            arrowTab(d, ta, tb, "right", function() toggleHide("left") end)
            return
        end
        local LW, LH = size("lw"), size("lh")
        local hh = math.min(LH, H - 2)
        local a = (function() local px, py = place("left", LW, hh, 0, 0); return V(px, py, 0) end)()
        local b = V(a.x + LW, a.y + hh, 0)
        S.screen.leftBox = { a = a, b = b }
        S.screen.leftEdge = b.x + 30
        d:rect(a, b, { colour = UI.panel, fill = true, rounding = 8 })
        edge(d, a, b, 8)
        arrowTab(d, V(b.x + 4, (a.y + b.y) / 2 - 40, 0), V(b.x + 26, (a.y + b.y) / 2 + 40, 0), "left", function() toggleHide("left") end)
        mover(d, "left", a, V(b.x, a.y + 40, 0), { a = a, b = b })
        corner(d, "left", { a = a, b = b }, "l", "lw", "lh")
        corner(d, "left", { a = a, b = b }, "r", "lw", "lh")
        local x, w = a.x + 16, LW - 32
        labelW = w - 4
        local y = a.y + 14
        d:text(V(x, y, 0), "Park", { size = 20, colour = UI.text, font = "heading" })
        y += 34
        local ng = groupCount()
        local miss = S.missing or {}
            y = label(d, x, y, ng > 0 and string.format("Group  ·  %d", ng) or "Group")
            local gw = (w - 6) / 2
            btn(d, V(x, y, 0), V(x + w, y + 32, 0), "Add / remove picked", function() if S.sel and S.known and S.known[S.sel.id] and S.toggleGroup then S.toggleGroup(S.known[S.sel.id]) end end)
            y += 38
            btn(d, V(x, y, 0), V(x + gw, y + 32, 0), "Clear", function() if S.clearGroup then S.clearGroup() end end)
            btn(d, V(x + gw + 6, y, 0), V(x + w, y + 32, 0), "Copy tools", function() if S.openTools then S.openTools() end end)
            y += 42
            y = label(d, x, y, "Arrange the group")
            btn(d, V(x, y, 0), V(x + gw, y + 30, 0), "Mirror L/R", function() S.arrange("mirrorX") end)
            btn(d, V(x + gw + 6, y, 0), V(x + w, y + 30, 0), "Mirror F/B", function() S.arrange("mirrorZ") end)
            y += 36
            btn(d, V(x, y, 0), V(x + gw, y + 30, 0), "Line up", function() S.arrange("lineup") end)
            btn(d, V(x + gw + 6, y, 0), V(x + w, y + 30, 0), "Even gaps", function() S.arrange("space") end)
            y += 36
            btn(d, V(x, y, 0), V(x + w, y + 30, 0), "Same height", function() S.arrange("level") end)
            y += 40
            -- the park at a glance
            local okS, ps = pcall(FN.parkStats)
            if okS and ps then
                local line = string.format("%d object%s  ·  %d kind%s", ps.n, ps.n == 1 and "" or "s", ps.kinds, ps.kinds == 1 and "" or "s")
                fitText(d, x + 2, y, line, w - 4, { size = 13, colour = UI.dim })
                y += 22
                if #ps.dups > 0 then
                    local lbl = string.format("Remove %d stacked", #ps.dups)
                    if S.dupAsk and S.clock - S.dupAsk < 3000 then lbl = "Click again" end
                    btn(d, V(x, y, 0), V(x + w, y + 30, 0), lbl, function()
                        if S.dupAsk and S.clock - S.dupAsk < 3000 then S.dupAsk = nil; FN.removeDuplicates()
                        else S.dupAsk = S.clock; say(string.format("%d object%s sit exactly on top of the same object. Click again to remove them.", #ps.dups, #ps.dups == 1 and "" or "s")) end
                    end)
                    y += 38
                end
            end
            y += 4
            FN.rebuildList()
            y = label(d, x, y, string.format("Objects  ·  %d", S.listMatched or 0))
            local sa, sb = V(x, y, 0), V(x + w, y + 32, 0)
            d:rect(sa, sb, { colour = hot(sa, sb) and UI.fieldHot or UI.field, fill = true, rounding = 6 })
            edge(d, sa, sb, 6)
            textIn(d, sa, sb, S.search ~= "" and ("Search:  " .. S.search) or "Search the park", { size = 14, colour = S.search ~= "" and UI.text or UI.dim }, 10)
            tileAdd(sa, sb, function()
                S.typeSearch = true
                local ok = pcall(reskate.ui.dialog, "ddh_search", { title = "Search objects", message = "Part of a name (empty: all).", field = { text = S.search, max = 40 },
                    buttons = { { id = "apply", label = "Search" }, { id = "close", label = "Cancel" } } })
                if ok then S.typing = true end
            end)
            y += 40
            y = seg(d, x, y, w, { "All", "Near", "DDH" }, S.listFilter, function(i) S.listFilter = i; S.listKey = nil; S.listTop = 0 end) + 8
            -- the list, in groups (DDH's objects by Quick Drop's families, the rest by category; Near: by distance,
            -- not grouped): a group's heading folds it; as many rows as fit, the wheel scrolls it
            local disp = UI.listGroups(S.listObjs or {}, S.listFilter ~= 2)
            local rowH = 30
            local bottom = b.y - ((S.blocked or #miss > 0) and 132 or 92)
            local rows = math.max(3, math.floor((bottom - y) / rowH))
            local n = #disp
            S.listTop = clamp(S.listTop or 0, 0, math.max(0, n - rows))
            S.screen.listBox = { a = V(x, y, 0), b = V(x + w, y + rows * rowH, 0), rows = rows, n = n }
            for r = 1, rows do
                local i = S.listTop + r
                local row = disp[i]
                if not row then break end
                local ra, rb = V(x, y + (r - 1) * rowH, 0), V(x + w, y + r * rowH - 2, 0)
                if row.head then
                    -- a group's heading: its name and how many, a triangle (down: open, right: folded)
                    if hot(ra, rb) then d:rect(ra, rb, { colour = UI.field, fill = true, rounding = 6 }) end
                    local cx, cy = x + 9, ra.y + 14
                    if row.open then d:poly({ V(cx - 5, cy - 3, 0), V(cx + 5, cy - 3, 0), V(cx, cy + 3, 0) }, { colour = UI.dim, fill = true })
                    else d:poly({ V(cx - 3, cy - 5, 0), V(cx + 3, cy, 0), V(cx - 3, cy + 5, 0) }, { colour = UI.dim, fill = true }) end
                    fitText(d, x + 22, ra.y + 7, string.upper(row.head), w - 56, { size = 12, colour = UI.dim, font = "bold" })
                    d:text(V(rb.x - 6, ra.y + 7, 0), tostring(row.n), { size = 12, colour = UI.dim, align = "right" })
                    local hname = row.head
                    tileAdd(ra, rb, function() S.listFold = S.listFold or {}; S.listFold[hname] = row.open; S.listFoldV = (S.listFoldV or 0) + 1 end)
                else
                local o = row.o
                local ind = row.indent and 12 or 0
                local on = S.sel and S.sel.id == o.id
                if on then d:rect(ra, rb, { colour = UI.accent, fill = true, rounding = 6 })
                elseif S.group[o.id] then d:rect(ra, rb, { colour = UI.mix(UI.purple, UI.panel, 0.78), fill = true, rounding = 6 })
                elseif hot(ra, rb) then d:rect(ra, rb, { colour = UI.field, fill = true, rounding = 6 }) end
                local name = titleOf(o.item)
                if S.group[o.id] then d:circle(V(x + 7 + ind, ra.y + 14, 0), 3, { colour = UI.purple, fill = true }) end
                local distS = string.format("%.0f m", len(o.position - (S.cam.target or o.position)))
                local dw = measure(d, distS, 12, nil)[1] + 8
                fitText(d, x + 14 + ind, ra.y + 6, name, w - 20 - ind - dw, { size = 14, colour = on and UI.onAccent or UI.text, font = on and "bold" or nil })
                d:text(V(rb.x - 5, ra.y + 7, 0), distS, { size = 12, colour = on and UI.onAccent or UI.dim, align = "right" })
                tileAdd(ra, rb, function()
                    if FN.kbDown("multi") then
                        -- Ctrl+click (or the key set for it): in or out of the selection (the picked one joins first)
                        if S.sel and not S.group[S.sel.id] and groupCount() == 0 and S.sel.id ~= o.id then S.group[S.sel.id] = true end
                        if S.group[o.id] then S.group[o.id] = nil else S.group[o.id] = true end
                        S.gbase = nil
                        local n = groupCount()
                        say(n > 0 and string.format("%d selected  (%s+click adds or removes)", n, FN.kbLabel("multi")) or "Nothing selected.")
                        return
                    end
                    send(); select(o); S.cam.goal = o.position; S.listKey = nil; say("Picked " .. titleOf(o.item))
                end)
                end
            end
            if n > rows then
                local la, lb2 = S.screen.listBox.a, S.screen.listBox.b
                local f0, f1 = S.listTop / n, math.min(1, (S.listTop + rows) / n)
                d:rect(V(lb2.x + 4, la.y + (lb2.y - la.y) * f0, 0), V(lb2.x + 7, la.y + (lb2.y - la.y) * f1, 0), { colour = UI.accent, fill = true, rounding = 2 })
            end
            local pb = b.y - 46
            -- delete the selected ones (the group, else the picked one): click twice; undo puts them back
            local delIds = FN.replaceTargets()
            local nd = #delIds
            local dl = nd > 1 and string.format("Delete %d", nd) or (nd == 1 and "Delete picked" or "Delete")
            if nd > 0 and S.listDelAsk and S.clock - S.listDelAsk < 3000 then dl = "Click again" end
            btn(d, V(x, pb - 40, 0), V(x + w, pb - 6, 0), dl, function()
                if nd == 0 then say("Pick an object, or " .. FN.kbLabel("multi") .. "+click objects in the list, then Delete.", true) return end
                if S.listDelAsk and S.clock - S.listDelAsk < 3000 then
                    S.listDelAsk = nil
                    if S.grab then S.grab = nil; endHoldMove() end
                    local rec = S.removeUndoable(delIds, "Deleted")
                    S.group, S.gbase = {}, nil
                    say(string.format("Deleting %d object%s...  (Undo puts them back)", rec.total, rec.total == 1 and "" or "s"))
                else
                    S.listDelAsk = S.clock
                    say(string.format("Click Delete again to delete %d object%s.", nd, nd == 1 and "" or "s"))
                end
            end, nd > 0 and "danger" or nil)
            btn(d, V(x, pb, 0), V(x + w, pb + 34, 0), "Save as park mod", function() FN.saveParkModSay() end, "primary")
            if S.blocked or #miss > 0 then
                btn(d, V(x, pb - 80, 0), V(x + w, pb - 46, 0), "Locked: check again", function()
                    S.blocked = nil; pcall(findMissing)
                    if #(S.missing or {}) == 0 then say("No missing objects found. Try moving something again.") else say("Fix: run Clean out park.exe with the game closed.", true) end
                end)
            end
    end

    -- ---------------------------------------------------------------- snapping, in a thin bar along the top between the
    -- panels: snap on or off, by matching sides or classic, to what, how strongly, the grid, and three switches
    -- a small switch shown as a pill: lit when on
    local function pill(d, a, b, labelS, on, fn)
        local h = hot(a, b)
        d:rect(a, b, { colour = on and (h and UI.accentHot or UI.accent) or (h and UI.fieldHot or UI.field), fill = true, rounding = 8 })
        if not on then edge(d, a, b, 8) end
        textIn(d, a, b, labelS, { size = 14, colour = on and UI.onAccent or UI.text, font = on and "bold" or nil, align = "centre" }, 6)
        tileAdd(a, b, fn)
    end
    -- a choice row with a small caption before it
    local function capW(d, cap) return measure(d, cap, 13, nil)[1] + 10 end
    local function capSeg(d, x, y, w, cap, labels, cur, fn)
        local cw = capW(d, cap)
        textIn(d, V(x, y, 0), V(x + cw, y + 34, 0), cap, { size = 13, colour = UI.dim }, 2)
        seg(d, x + cw, y, w - cw, labels, cur, fn)
    end
    local function snapBar(d)
        local W = S.size.x
        -- (1296 wide in the middle of the screen, along its top edge, and never over the panels)
        local half = size("sw") / 2
        local left = math.max(W / 2 - half, S.screen.leftEdge or 14)
        local right = math.min(W / 2 + half, S.screen.rightEdge or (W - 14))
        local top = 0
        -- (moved: where it was put, as wide as set)
        if S.uiPos.snap then
            local sw2 = math.min(size("sw"), W)
            left, top = place("snap", sw2, 60, left, 0)
            right = left + sw2
        end
        local cx = (left + right) / 2
        if S.hide.snap then
            S.screen.snapBox = nil
            arrowTab(d, V(cx - 40, 0, 0), V(cx + 40, 24, 0), "down", function() toggleHide("snap") end)
            return
        end
        local a, b = V(left, top, 0), V(right, top + 46, 0)
        -- the pieces and their share of the width
        local cur = S.snapPick == nil and 1 or (S.snapPick == "off" and 3 or 2)
        local nextName = "Next"
        if cur == 2 then
            local o = S.known and S.known[S.snapPick]
            if o then nextName = FN.shortTitle(titleOf(o.item), 14) end
        end
        local k = S.snapStrength or 1
        local parts = {
            { 100, function(x, y, w) pill(d, V(x, y, 0), V(x + w, y + 34, 0), "Snap  (T)", S.osnap, function() S.osnap = not S.osnap end) end,
                "Snap to objects: its sides go flat against other objects' sides when brought near.  T" },
            { 175, function(x, y, w) capSeg(d, x, y, w, "By", { "Sides", "Classic" }, S.snapStyle == "classic" and 2 or 1, function(i) FN.setSnapStyle(i == 2 and "classic" or "match") end) end,
                "Sides: a side snaps flat to a side of about the same size, lined up at its ends or middle. Classic: sides meet and line up with anything near." },
            { 205, function(x, y, w)
                local cur = ({ auto = 1, bottoms = 2, tops = 3 })[S.snapLevel or "auto"] or 1
                capSeg(d, x, y, w, "Level", { "Auto", "Bottoms", "Tops" }, cur, function(i) FN.setSnapLevel(({ "auto", "bottoms", "tops" })[i]) end)
            end,
                "Heights when sides meet. Bottoms: bottoms level. Tops: tops level, so you skate from one onto the other (a ledge's low end onto a platform). Auto: bottoms, or tops when lifted and nearer." },
            { 205, function(x, y, w) capSeg(d, x, y, w, "To", { "Auto", nextName, "Off" }, cur, function(i)
                if i == 1 then S.snapPick = nil; S.snapLock = nil
                elseif i == 2 and S.nextSnap then S.nextSnap()
                elseif i == 3 then S.snapPick = "off"; S.guides = nil end
            end) end,
                "What it snaps to: the nearest object, one object you choose (Next picks the next one near), or nothing.  " .. FN.kbLabel("snapTarget") .. FN.padText(", or tap L3 while holding") },
            { 190, function(x, y, w)
                -- how strongly: - / +, and the bar (click or drag on it), its % on it
                btn(d, V(x, y + 4, 0), V(x + 24, y + 30, 0), "-", function() FN.setSnapStrength(k - 0.1, true) end)
                btn(d, V(x + w - 24, y + 4, 0), V(x + w, y + 30, 0), "+", function() FN.setSnapStrength(k + 0.1, true) end)
                local ba, bb = V(x + 30, y + 6, 0), V(x + w - 30, y + 28, 0)
                local f = (k - 0.2) / 1.8
                d:rect(ba, bb, { colour = UI.field, fill = true, rounding = 6 })
                d:rect(ba, V(ba.x + (bb.x - ba.x) * f, bb.y, 0), { colour = UI.accentDim, fill = true, rounding = 6 })
                edge(d, ba, bb, 6)
                local mark = ba.x + (bb.x - ba.x) * (0.8 / 1.8)
                d:rect(V(mark - 1, ba.y - 2, 0), V(mark + 1, bb.y + 2, 0), { colour = UI.dim, fill = true })
                textIn(d, ba, bb, string.format("Strength %d%%", math.floor(k * 100 + 0.5)), { size = 13, colour = UI.text, align = "centre" }, 4)
                local function setFromMouse()
                    local m = S.mouse and S.mouse.pos
                    if m then FN.setSnapStrength(0.2 + 1.8 * clamp((m.x - ba.x) / (bb.x - ba.x), 0, 1), true) end
                end
                tileAdd(V(ba.x, ba.y - 4, 0), V(bb.x, bb.y + 4, 0), function() setFromMouse(); S.snapSliderDrag = setFromMouse end)
                if S.snapSliderDrag and S.mouse and S.mouse.left then S.snapSliderDrag() else S.snapSliderDrag = nil end
            end,
                "How far it reaches to snap. Lower: only snaps right up against things. Higher: from further away. The mark is 100%." },
            { 260, function(x, y, w) capSeg(d, x, y, w, "Grid m", { "Off", "0.25", "0.5", "1", "2" }, S.gridI or 1, function(i) S.gridI = i end) end,
                "The grid's step in metres: moving across the ground, with the mouse or the controller, lands on it when not snapped to an object. Off: free." },
            { 100, function(x, y, w) pill(d, V(x, y, 0), V(x + w, y + 34, 0), "Steps  (G)", S.snap, function() S.snap = not S.snap end) end,
                "Drag in steps with the mouse: moving by 0.25 m (1 m with Shift), turning by 15 degrees (45 with Shift).  G" },
            { 80, function(x, y, w) pill(d, V(x, y, 0), V(x + w, y + 34, 0), "Land", S.landOn, function() S.landOn = not S.landOn end) end,
                "Land on what is under it: dragged along, it sits on the ground or whatever is below it." },
            { 115, function(x, y, w) pill(d, V(x, y, 0), V(x + w, y + 34, 0), "Height / gap", S.readoutOn, function() S.readoutOn = not S.readoutOn end) end,
                "While moving: its height above what is under it, and the gap to the nearest object, next to it." },
        }
        -- the width each piece needs for its text (measured, bold: a chosen one is drawn bold), and the room left
        -- over shared out by the pieces' weights; when even that is too wide, each gets its share of what there is
        local function pillNeed(l) return measure(d, l, 14, "bold")[1] + 28 end
        local function segNeed(cap, labels)
            local m = 0
            for _, l in ipairs(labels) do m = math.max(m, measure(d, l, 14, "bold")[1]) end
            return capW(d, cap) + #labels * (m + 16) + 4
        end
        local needs = {
            pillNeed("Snap  (T)"),
            segNeed("By", { "Sides", "Classic" }),
            segNeed("Level", { "Auto", "Bottoms", "Tops" }),
            segNeed("To", { "Auto", nextName, "Off" }),
            measure(d, "Strength 100%", 13, nil)[1] + 80,
            segNeed("Grid m", { "Off", "0.25", "0.5", "1", "2" }),
            pillNeed("Steps  (G)"),
            pillNeed("Land"),
            pillNeed("Height / gap"),
        }
        -- in rows: as many pieces as fit on a row at their own width, the rest on the next row; each row's spare
        -- room shared out by the pieces' weights (so nothing is ever squeezed: the bar grows a row instead)
        local gap = 8
        local room = (right - left) - 16 - 14
        local rowsL, rowN, rowW = {}, {}, 0
        for i in ipairs(parts) do
            local add = (#rowN > 0 and gap or 0) + needs[i]
            if #rowN > 0 and rowW + add > room then rowsL[#rowsL + 1] = rowN; rowN, rowW = {}, 0; add = needs[i] end
            rowN[#rowN + 1] = i; rowW += add
        end
        rowsL[#rowsL + 1] = rowN
        -- (then shared out evenly over that many rows, in order: so no row is left with two pieces stretched wide)
        if #rowsL > 1 then
            local total = 0
            for i in ipairs(parts) do total += needs[i] + gap end
            local target = total / #rowsL
            local even, cur, cw2 = {}, {}, 0
            for i in ipairs(parts) do
                local left2 = #parts - i + 1
                local rowsLeft = #rowsL - #even
                if #cur > 0 and ((cw2 + needs[i] > target and rowsLeft > 1) or cw2 + gap + needs[i] > room or left2 < rowsLeft) then
                    even[#even + 1] = cur; cur, cw2 = {}, 0
                end
                cur[#cur + 1] = i; cw2 += needs[i] + gap
            end
            even[#even + 1] = cur
            local ok2 = #even == #rowsL
            for _, r in ipairs(even) do
                local wsum2 = -gap
                for _, i in ipairs(r) do wsum2 += needs[i] + gap end
                if wsum2 > room then ok2 = false end
            end
            if ok2 then rowsL = even end
        end
        local ROW = 40
        b = V(right, top + 12 + ROW * #rowsL - (ROW - 34), 0)
        S.screen.snapBox = { a = a, b = b }
        d:rect(a, b, { colour = UI.panel, fill = true, rounding = 8 })
        edge(d, a, b, 8)
        mover(d, "snap", V(a.x + 2, a.y + 4, 0), V(a.x + 18, b.y - 4, 0), { a = a, b = b }, true)
        corner(d, "snap", { a = a, b = b }, "l", "sw", nil)
        corner(d, "snap", { a = a, b = b }, "r", "sw", nil)
        arrowTab(d, V(cx - 36, b.y + 4, 0), V(cx + 36, b.y + 24, 0), "up", function() toggleHide("snap") end)
        local hint, hx = nil, 0
        for r, row in ipairs(rowsL) do
            local need, wsum = gap * (#row - 1), 0
            for _, i in ipairs(row) do need += needs[i]; wsum += parts[i][1] end
            local spare = room - need
            local x = a.x + 8 + 14
            local y = a.y + 6 + (r - 1) * ROW
            for _, i in ipairs(row) do
                local pt = parts[i]
                local w = spare >= 0 and (needs[i] + spare * pt[1] / wsum) or (needs[i] * (room - gap * (#row - 1)) / (need - gap * (#row - 1)))
                pt[2](x, y, w)
                if pt[3] and hot(V(x, y - 6, 0), V(x + w, y + 34, 0)) then hint, hx = pt[3], x + w / 2 end
                x += w + gap
            end
        end
        -- what the control under the mouse does: a box under the bar, by it
        if hint then
            -- (wrapped here, line by line, each measured: the box is as wide as its widest line, so all of it fits)
            local lines, tw, lh = wrapLines(d, hint, 14, "body", 360)
            local lgap = math.ceil(lh * 0.25)
            local hw = math.ceil(tw) + 30
            local hh = #lines * lh + (#lines - 1) * lgap + 18
            local hx0 = math.max(a.x, math.min(b.x - hw, hx - hw / 2))
            local ha, hb = V(hx0, b.y + 30, 0), V(hx0 + hw, b.y + 30 + hh, 0)
            d:rect(ha, hb, { colour = UI.panel, fill = true, rounding = 8 })
            edge(d, ha, hb, 8)
            d:rect(V(ha.x, ha.y + 6, 0), V(ha.x + 3, hb.y - 6, 0), { colour = UI.accent, fill = true, rounding = 2 })
            for i, l in ipairs(lines) do
                d:text(V(ha.x + 16, ha.y + 9 + (i - 1) * (lh + lgap), 0), l, { size = 14, colour = UI.text, font = "body" })
            end
        end
    end

    -- (the tabs, and the number each stands for in S.ptab: the park has its own panel on the left, snapping a bar
    -- along the top)
    local TABS, TAB_IDS = { "Edit", "Sets", "History" }, { 1, 4, 5 }
    -- the plugin's version, from its manifest (read once)
    local version = nil
    do
        local okV, m = pcall(function() return reskate.package.read_json("manifest.json") end)
        if okV and type(m) == "table" and m.version_number then version = tostring(m.version_number) end
    end
    function UI.sidePanel(d)
        tiles = {}
        S.screen.tabs = {}
        local W, H = S.size.x, S.size.y
        if S.hide.right then
            -- (hidden: only a tab at the screen's edge, to bring it back)
            local ta, tb = V(W - 26, H / 2 - 40, 0), V(W, H / 2 + 40, 0)
            S.screen.panelBox, S.screen.rightEdge = nil, ta.x
            arrowTab(d, ta, tb, "left", function() toggleHide("right") end)
            parkPanel(d)
            snapBar(d)
            return
        end
        local RW, RH = size("rw"), size("rh")
        local hh = math.min(RH, H - 2)
        local a = (function() local px, py = place("right", RW, hh, W - RW, 0); return V(px, py, 0) end)()
        local b = V(a.x + RW, a.y + hh, 0)
        S.screen.panelBox = { a = a, b = b }
        S.screen.rightEdge = a.x - 30
        d:rect(a, b, { colour = UI.panel, fill = true, rounding = 8 })
        edge(d, a, b, 8)
        arrowTab(d, V(a.x - 26, (a.y + b.y) / 2 - 40, 0), V(a.x - 4, (a.y + b.y) / 2 + 40, 0), "right", function() toggleHide("right") end)
        mover(d, "right", a, V(b.x, a.y + 40, 0), { a = a, b = b })
        corner(d, "right", { a = a, b = b }, "l", "rw", "rh")
        corner(d, "right", { a = a, b = b }, "r", "rw", "rh")
        local x, w = a.x + 16, RW - 32
        labelW = w - 4
        local y = a.y + 14
        -- title; the version, Colours and Done
        fitText(d, x, y, "DDH Park Editor", w, { size = 20, colour = UI.text, font = "heading" })
        -- (the version beside the title, when the panel is wide enough for both)
        if version then
            local tw2 = measure(d, "DDH Park Editor", 20, "heading")[1]
            local vS = "v" .. version
            local vw = measure(d, vS, 13, nil)[1]
            if tw2 + 10 + vw <= w then d:text(V(x + w, y + 6, 0), vS, { size = 13, colour = UI.dim, align = "right" }) end
        end
        y += 32
        local dw = math.floor((w - 6) * 0.36)
        btn(d, V(x, y, 0), V(x + w - dw - 6, y + 30, 0), "Settings", function() if FN.openKeys then FN.openKeys() end end)
        btn(d, V(x + w - dw, y, 0), V(x + w, y + 30, 0), "Done", function() closeEditor() end)
        y += 42
        -- what is picked
        local t = S.sel and S.target
        local ng = groupCount()
        d:rect(V(x, y, 0), V(x + w, y + 60, 0), { colour = UI.field, fill = true, rounding = 6 })
        local title, sub, dot = "Nothing picked", FN.padText("Click an object, or aim and press A"), UI.faint
        if t then
            title = titleOf(S.sel.item)
            sub = string.format("%.0f°  ·  size %.2f", math.deg(t.heading), t.scale)
            dot = UI.accent
            if S.group[S.sel.id] and ng > 1 then sub = sub .. string.format("  ·  group %d", ng); dot = UI.purple end
        elseif ng > 0 then
            title, sub, dot = string.format("Group of %d", ng), "Pick one up to move them all", UI.purple
        end
        d:circle(V(x + 13, y + 20, 0), 4, { colour = dot, fill = true })
        fitText(d, x + 24, y + 10, title, w - 32, { size = 15, colour = UI.text, font = "bold" })
        fitText(d, x + 24, y + 33, sub, w - 32, { size = 13, colour = UI.dim })
        y += 70
        -- warnings and the last message
        local miss = S.missing or {}
        if S.blocked or #miss > 0 then
            d:rect(V(x, y, 0), V(x + w, y + 30, 0), { colour = "#5c1d1b", fill = true, rounding = 6 })
            fitText(d, x + 10, y + 7, string.format("Park locked: %d missing (see Park)", #miss), w - 16, { size = 13, colour = "#ffd2cf" })
            y += 38
        end
        -- the everyday buttons, two by two
        local bw = (w - 6) / 2
        btn(d, V(x, y, 0), V(x + bw, y + 32, 0), "+ Add", function() if S.openPicker then S.openPicker() end end, "primary")
        btn(d, V(x + bw + 6, y, 0), V(x + w, y + 32, 0), "Controls", function() S.controlsOpen = true end)
        y += 38
        btn(d, V(x, y, 0), V(x + bw, y + 32, 0), "Undo", function() undo() end)
        btn(d, V(x + bw + 6, y, 0), V(x + w, y + 32, 0), "Redo", function() if S.redoFn then S.redoFn() end end)
        y += 44
        -- tabs
        S.ptab = S.ptab or 1
        if S.ptab ~= 1 and S.ptab ~= 4 and S.ptab ~= 5 then S.ptab = 1 end
        local tw = w / #TABS
        d:rect(V(x - 2, y - 2, 0), V(x + w + 2, y + 36, 0), { colour = UI.field, fill = true, rounding = 8 })
        for i, n in ipairs(TABS) do
            local ta, tb = V(x + (i - 1) * tw, y, 0), V(x + i * tw, y + 34, 0)
            local on = TAB_IDS[i] == S.ptab
            if on then d:rect(V(ta.x + 2, y, 0), V(tb.x - 2, tb.y, 0), { colour = UI.accent, fill = true, rounding = 6 })
            elseif hot(ta, tb) then d:rect(V(ta.x + 2, y, 0), V(tb.x - 2, tb.y, 0), { colour = UI.fieldHot, fill = true, rounding = 6 }) end
            textIn(d, ta, tb, n, { size = 15, colour = on and UI.onAccent or UI.dim, font = "bold", align = "centre" }, 4)
            tileAdd(ta, tb, function() S.ptab = TAB_IDS[i] end)
        end
        y += 44
        local st = STEPS[S.stepSize] or STEPS[2]
        if S.ptab == 1 then
            if not t then
                fitText(d, x + 4, y, "Pick an object to change it here.", w - 8, { size = 14, colour = UI.dim })
                y += 30
            else
                y = label(d, x, y, "Handles")
                y = seg(d, x, y, w, { "Move", "Turn", "Size" }, S.mode, function(i) S.mode = i end) + 14
                -- (its position, turn, size and tilt: in the rows along the bottom of the screen, see UI.padRows)
                if tilted(S.sel.id) and S.tiltWhy and not S.tiltHeld[S.sel.id] then
                    fitText(d, x + 4, y, "Tilt waits: " .. S.tiltWhy, w - 8, { size = 13, colour = UI.orange }); y += 22
                end
                local qw = (w - 6) / 2
                btn(d, V(x, y, 0), V(x + qw, y + 32, 0), "Straighten", function() markUndo(); t.heading = round(t.heading, math.pi / 2); if S.tilt[S.sel.id] then S.tilt[S.sel.id] = nil; S.tiltSaveDue = true end; S.dirty = true end)
                btn(d, V(x + qw + 6, y, 0), V(x + w, y + 32, 0), "Size 1", function() markUndo(); t.scale = 1; S.dirty = true end)
                y += 38
                btn(d, V(x, y, 0), V(x + w, y + 32, 0), "Look at it", function() S.cam.goal = t.pos end)
                y += 40
                y = switch(d, x, y, w, "Measure   (M)", S.measureOn, function() FN.toggleMeasure() end) + 8
                local nr = #FN.replaceTargets()
                btn(d, V(x, y, 0), V(x + w, y + 32, 0), nr > 1 and string.format("Replace all %d…", nr) or "Replace with…", function() FN.openReplace() end)
                y += 44
            end
            y = label(d, x, y, "Step size")
            y = seg(d, x, y, w, { "Fine", "Normal", "Big" }, S.stepSize, function(i) S.stepSize = i end) + 6
            fitText(d, x + 2, y, string.format("%s m  ·  %s  ·  ×%s", string.format("%.2f", st.m), string.format(st.df, st.deg), string.format("%.2f", st.size)), w - 4, { size = 13, colour = UI.dim })
        elseif S.ptab == 4 then
            -- ---------------------------------------------------------------- sets
            local nm = #(S.setMembers and S.setMembers() or {})
            fitText(d, x + 2, y, nm > 0 and string.format("Saves the %s (%d)", nm > 1 and "group" or "picked one", nm)
                or "Pick an object or a group,", w - 4, { size = 13, colour = UI.dim })
            fitText(d, x + 2, y + 18, nm > 0 and "to place on any map or server." or "then save it here.", w - 4, { size = 13, colour = UI.dim })
            y += 42
            btn(d, V(x, y, 0), V(x + w, y + 34, 0), nm > 0 and string.format("Save as a set  (%d)", nm) or "Save as a set", function()
                if nm == 0 then say("Pick an object or make a group first.", true) return end
                local ok = pcall(reskate.ui.dialog, "ddh_setname", { title = "Save as a set", message = "A name for it (letters, numbers, spaces).", field = { text = "My set", max = 40 },
                    buttons = { { id = "apply", label = "Save" }, { id = "close", label = "Cancel" } } })
                if ok then S.typing = true end
            end, nm > 0 and "primary" or nil)
            y += 46
            if not S.sets or S.clock - (S.setsAt or -1e9) > 5000 then S.loadSets() end
            y = label(d, x, y, string.format("Saved sets  ·  %d", #S.sets))
            if #S.sets == 0 then
                fitText(d, x + 4, y, "None yet.", w - 8, { size = 14, colour = UI.dim }); y += 26
            end
            local rowH = 164
            local maxRows = math.max(2, math.floor((b.y - 100 - y) / rowH))
            for i, set in ipairs(S.sets) do
                if i > maxRows then
                    fitText(d, x + 2, y, string.format("+%d more (Add > Sets)", #S.sets - maxRows), w - 4, { size = 13, colour = UI.dim }); y += 24
                    break
                end
                local ra, rb = V(x, y, 0), V(x + w, y + rowH - 6, 0)
                d:rect(ra, rb, { colour = UI.field, fill = true, rounding = 6 })
                edge(d, ra, rb, 6)
                -- its layout from above
                local pa, pb2 = V(x + 6, y + 6, 0), V(x + 76, y + 58, 0)
                d:rect(pa, pb2, { colour = UI.panel, fill = true, rounding = 4 })
                pcall(UI.drawSetPreview, d, set, pa + V(4, 4, 0), pb2 - V(4, 4, 0), UI.purple)
                local nmS = set.name
                fitText(d, x + 84, y + 10, nmS, w - 90, { size = 14, colour = UI.text, font = "bold" })
                local mn, mshort = 0, ""
                if S.setMissing then local _; _, mn, mshort = S.setMissing(set) end
                if mn > 0 then
                    fitText(d, x + 84, y + 28, string.format("%d objects, %d missing:", #set.objects, mn), w - 90, { size = 13, colour = UI.orange })
                    fitText(d, x + 84, y + 44, mshort, w - 90, { size = 12, colour = UI.dim })
                else
                    fitText(d, x + 84, y + 32, string.format("%d objects", #set.objects), w - 90, { size = 13, colour = UI.dim })
                end
                local by = y + 64
                local bw2 = (w - 12 - 6) / 2
                local bx = x + 6
                btn(d, V(bx, by, 0), V(bx + bw2, by + 28, 0), "Place", function() S.carrySet(set, FN.crossPoint(), wrap(S.cam.yaw + math.pi)) end, "primary")
                btn(d, V(bx + bw2 + 6, by, 0), V(bx + 2 * bw2 + 6, by + 28, 0), "Rename", function()
                    S.renameSet = set
                    local ok = pcall(reskate.ui.dialog, "ddh_setrename", { title = "Rename set", message = "A new name.", field = { text = set.name, max = 40 },
                        buttons = { { id = "apply", label = "Rename" }, { id = "close", label = "Cancel" } } })
                    if ok then S.typing = true end
                end)
                by += 32
                btn(d, V(bx, by, 0), V(bx + bw2, by + 28, 0), "Update", function()
                    if S.updSetAsk == set.file and S.clock - (S.updSetAt or 0) < 3000 then
                        S.updSetAsk = nil
                        S.saveSet(set.name)
                    else
                        local nm2 = #(S.setMembers and S.setMembers() or {})
                        if nm2 == 0 then say("Pick an object or make a group first: Update saves it over this set.", true) return end
                        S.updSetAsk, S.updSetAt = set.file, S.clock
                        say(string.format("Click Update again to save the %d selected over \"%s\".", nm2, set.name))
                    end
                end)
                btn(d, V(bx + bw2 + 6, by, 0), V(rb.x - 6, by + 28, 0), "Delete", function()
                    if S.delSetAsk == set.file and S.clock - (S.delSetAt or 0) < 3000 then S.delSetAsk = nil; S.deleteSet(set)
                    else S.delSetAsk, S.delSetAt = set.file, S.clock; say("Click Delete again to delete \"" .. set.name .. "\".") end
                end)
                by += 32
                -- its code, to send to a friend
                btn(d, V(bx, by, 0), V(rb.x - 6, by + 28, 0), "Share code", function() if S.shareSet then S.shareSet(set) end end)
                y += rowH
            end
            local pb = b.y - 46
            local hw = (w - 6) / 2
            btn(d, V(x, pb, 0), V(x + hw, pb + 34, 0), "Import code", function() if S.askImportCode then S.askImportCode() end end)
            btn(d, V(x + hw + 6, pb, 0), V(x + w, pb + 34, 0), "Open folder", function() S.openSetsFolder() end)
        end
        if S.ptab == 5 then
            -- ---------------------------------------------------------------- history: the steps undo goes back
            -- through, newest first; clicking one undoes back to before it (one step at a time)
            local list = S.undo or {}
            fitText(d, x + 2, y, "Click a step to undo to it.", w - 4, { size = 13, colour = UI.dim })
            y += 24
            if (S.undoLeft or 0) > 0 then
                fitText(d, x + 4, y, string.format("Undoing...  %d to go", S.undoLeft), w - 8, { size = 13, colour = UI.accent }); y += 22
            end
            y = label(d, x, y, string.format("Steps  ·  %d", #list))
            if #list == 0 then fitText(d, x + 4, y, "Nothing to undo yet.", w - 8, { size = 14, colour = UI.dim }); y += 26 end
            local rowH = 46
            local maxRows = math.max(3, math.floor((b.y - 90 - y) / rowH))
            for k = 1, math.min(#list, maxRows) do
                local idx = #list - k + 1
                local u = list[idx]
                local ra, rb = V(x, y, 0), V(x + w, y + rowH - 4, 0)
                local h = hot(ra, rb)
                d:rect(ra, rb, { colour = h and UI.fieldHot or UI.field, fill = true, rounding = 6 })
                edge(d, ra, rb, 6)
                local ago = u.at and math.max(0, (S.clock - u.at) / 1000) or nil
                local agoS = ago and (ago < 60 and string.format("%.0f s", ago) or (ago < 3600 and string.format("%.0f min", ago / 60) or string.format("%.0f h", ago / 3600))) or ""
                local okN, nmS = pcall(FN.undoName, u)
                fitText(d, x + 10, y + 5, (okN and nmS) or "A step", w - 20, { size = 14, colour = UI.text })
                fitText(d, x + 10, y + 23, agoS ~= "" and (agoS .. " ago") or "", w - 20, { size = 12, colour = UI.dim })
                tileAdd(ra, rb, function() FN.undoSteps(k) end)
                y += rowH
            end
            if #list > maxRows then fitText(d, x + 2, y, string.format("+%d older", #list - maxRows), w - 4, { size = 13, colour = UI.dim }); y += 22 end
            local nr = #(S.redo or {})
            if nr > 0 then
                y += 6
                fitText(d, x + 2, y, string.format("%d can be redone (Redo)", nr), w - 4, { size = 13, colour = UI.dim })
            end
        end
        -- the last message, along the bottom
        if S.msg ~= "" and S.clock < S.msgUntil and S.ptab ~= 3 and S.ptab ~= 4 and S.ptab ~= 5 then
            local msg = S.msg
            fitText(d, x + 2, b.y - 28, msg, w - 4, { size = 13, colour = UI.dim })
        end
        parkPanel(d)
        snapBar(d)
    end
    reskate.on("throwdown_ui", function(e)
        if e.action ~= "dialog" or e.args[1] ~= "ddh_setrename" then return end
        local what = e.args[2]
        if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
        S.typing = false
        if what ~= "cancel" then pcall(reskate.ui.close_dialog, "ddh_setrename") end
        if what == "apply" and S.renameSet and S.renameSetFn then S.renameSetFn(S.renameSet, tostring(e.args[3] or "")) end
        S.renameSet = nil
    end)
    reskate.on("throwdown_ui", function(e)
        if e.action ~= "dialog" or e.args[1] ~= "ddh_setname" then return end
        local what = e.args[2]
        if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
        S.typing = false
        if what ~= "cancel" then pcall(reskate.ui.close_dialog, "ddh_setname") end
        if what == "apply" and S.saveSet then S.saveSet(tostring(e.args[3] or "")) end
    end)
    reskate.on("throwdown_ui", function(e)
        if e.action ~= "dialog" or e.args[1] ~= "ddh_search" then return end
        local what = e.args[2]
        if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
        S.typing = false
        if what ~= "cancel" then pcall(reskate.ui.close_dialog, "ddh_search") end
        if what == "apply" then S.search = tostring(e.args[3] or ""); S.listKey = nil; S.listTop = 0 end
    end)
    -- ---------------------------------------------------------------- the picked object's numbers under the controller's
    -- prompts: position on the left, turn, size and tilt on the right, the same rows as the panel's Edit tab (the
    -- mouse can use them without leaving the controller's view)
    local padTiles = {}
    UI.PAD_ROWS_H = 86
    UI.PROMPT_H = 40
    -- (the room they take at the bottom of the screen, above the prompts)
    function UI.padRowsSpace()
        if not (S.sel and S.target) then return 0 end
        return S.hide.rows and 28 or UI.PAD_ROWS_H + 2
    end
    -- one cell: name  [-] value [+]  (click the value to type it; click the name to switch, where it can)
    local function cell(d, x, y, w, name, value, dec, inc, edit, off, nameFn)
        local nw = 40
        local na, nb = V(x, y, 0), V(x + nw, y + 30, 0)
        textIn(d, na, nb, name, { size = 13, colour = off and UI.faint or (nameFn and UI.accent or UI.dim), font = nameFn and "bold" or nil }, 1)
        if nameFn then tileAdd(na, nb, nameFn) end
        local m1a, m1b = V(x + nw, y, 0), V(x + nw + 30, y + 30, 0)
        local p1a, p1b = V(x + w - 30, y, 0), V(x + w, y + 30, 0)
        local va, vb = V(m1b.x + 4, y, 0), V(p1a.x - 4, y + 30, 0)
        for _, bx in ipairs({ { m1a, m1b, "-", dec }, { va, vb, value, edit }, { p1a, p1b, "+", inc } }) do
            local h = not off and hot(bx[1], bx[2])
            d:rect(bx[1], bx[2], { colour = h and UI.fieldHot or UI.field, fill = true, rounding = 6 })
            edge(d, bx[1], bx[2], 6)
            textIn(d, bx[1], bx[2], bx[3], { size = bx[3] == value and 14 or 17, colour = off and UI.faint or UI.text, align = "centre" }, 3)
            if not off and bx[4] then tileAdd(bx[1], bx[2], bx[4]) end
        end
        if off then d:line(V(x + 2, y + 15, 0), V(x + w - 2, y + 15, 0), { colour = "#f85149b0", thickness = 2 }) end
    end
    function UI.padRows(d, inMouseView)
        local t = S.sel and S.target
        if not t then S.padRowsAt = nil return end
        local saved = tiles
        tiles = {}
        local W, H = S.size.x, S.size.y
        local tw = size("bw")
        local cx = W / 2
        S.padRowsAt = S.clock
        -- (right on the prompts at the bottom: in the mouse view there are none, so at the very bottom)
        local bottom = inMouseView and H or (H - UI.PROMPT_H)
        if S.hide.rows then
            -- (hidden: only a tab, to bring them back)
            local ta, tb = V(cx - 40, bottom - 26, 0), V(cx + 40, bottom - 2, 0)
            S.screen.padRows = { a = ta, b = tb }
            arrowTab(d, ta, tb, "up", function() toggleHide("rows") end, true)
            padTiles = tiles
            tiles = saved
            return
        end
        local a = (function() local px, py = place("rows", tw, UI.PAD_ROWS_H, math.floor(cx - tw / 2), bottom - 2 - UI.PAD_ROWS_H); return V(px, py, 0) end)()
        local b = V(a.x + tw, a.y + UI.PAD_ROWS_H, 0)
        cx = (a.x + b.x) / 2
        S.screen.padRows = { a = V(a.x, a.y - 24, 0), b = b }
        d:rect(a, b, { colour = UI.panel, fill = true, rounding = 8 })
        edge(d, a, b, 8)
        mover(d, "rows", V(a.x + 2, a.y + 4, 0), V(a.x + 18, b.y - 4, 0), { a = a, b = b }, true)
        corner(d, "rows", { a = a, b = b }, "l", "bw", nil)
        corner(d, "rows", { a = a, b = b }, "r", "bw", nil)
        arrowTab(d, V(cx - 36, a.y - 22, 0), V(cx + 36, a.y - 2, 0), "down", function() toggleHide("rows") end, true)
        local st = STEPS[S.stepSize] or STEPS[2]
        local gap, pad = 14, 12
        local cw = (tw - 2 * pad - 14 - 2 * gap) / 3
        local function cx0(i) return a.x + pad + 14 + (i - 1) * (cw + gap) end
        local y1, y2 = a.y + 10, a.y + 46
        local function setP(px, py, pz) markUndo(); t.pos = V(px, py, pz); S.dirty = true end
        cell(d, cx0(1), y1, cw, "X", string.format("%.2f", t.pos.x), function() setP(t.pos.x - st.m, t.pos.y, t.pos.z) end, function() setP(t.pos.x + st.m, t.pos.y, t.pos.z) end,
            function() typeOne("X", t.pos.x, "%.3f", function(v) setP(v, t.pos.y, t.pos.z) end) end)
        cell(d, cx0(2), y1, cw, "Y", string.format("%.2f", t.pos.y), function() setP(t.pos.x, FN.heightStep(t.pos.y, t.pos.y - st.m), t.pos.z) end, function() setP(t.pos.x, FN.heightStep(t.pos.y, t.pos.y + st.m), t.pos.z) end,
            function() typeOne("Height", t.pos.y, "%.3f", function(v) FN.markLifted(); setP(t.pos.x, v, t.pos.z) end) end)
        cell(d, cx0(3), y1, cw, "Z", string.format("%.2f", t.pos.z), function() setP(t.pos.x, t.pos.y, t.pos.z - st.m) end, function() setP(t.pos.x, t.pos.y, t.pos.z + st.m) end,
            function() typeOne("Z", t.pos.z, "%.3f", function(v) setP(t.pos.x, t.pos.y, v) end) end)
        local function setH(v) markUndo(); t.heading = wrap(v); S.dirty = true end
        local function setS(v) markUndo(); t.scale = clamp(v, 0.1, 10); S.dirty = true end
        cell(d, cx0(1), y2, cw, "Turn", string.format("%.1f°", math.deg(t.heading)), function() setH(t.heading + math.rad(st.deg)) end, function() setH(t.heading - math.rad(st.deg)) end,
            function() typeOne("Turn (degrees)", math.deg(t.heading), "%.1f", function(v) setH(math.rad(v)) end) end)
        cell(d, cx0(2), y2, cw, "Size", string.format("%.2f", t.scale), function() setS(t.scale - st.size) end, function() setS(t.scale + st.size) end,
            function() typeOne("Size", t.scale, "%.2f", setS) end)
        -- tilt: forward or sideways, one at a time (click its name to switch)
        local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
        local function setT(tx, tz) markUndo(); if math.abs(tx) < 1e-6 and math.abs(tz) < 1e-6 then S.tilt[S.sel.id] = nil else S.tilt[S.sel.id] = { x = wrap(tx), z = wrap(tz) } end; S.tiltSaveDue = true end
        local dd = math.rad(st.deg)
        local online = FN.online and FN.online()
        local side = S.tiltSide
        local nm = side and "Tilt S" or "Tilt F"
        local val = side and tl.z or tl.x
        cell(d, cx0(3), y2, cw, nm, string.format("%.1f°", math.deg(val)),
            function() if side then setT(tl.x, tl.z - dd) else setT(tl.x - dd, tl.z) end end,
            function() if side then setT(tl.x, tl.z + dd) else setT(tl.x + dd, tl.z) end end,
            function() typeOne(side and "Tilt sideways (degrees)" or "Tilt forward (degrees)", math.deg(val), "%.1f", function(v) if side then setT(tl.x, math.rad(v)) else setT(math.rad(v), tl.z) end end) end,
            online, not online and function() S.tiltSide = not S.tiltSide end or nil)
        padTiles = tiles
        tiles = saved
    end
    -- the mouse over those rows: true when it is there (then it stays the controller's view, and the view does
    -- nothing with the mouse)
    function UI.padRowsMouse(c)
        local box = S.screen and S.screen.padRows
        if not (box and S.padRowsAt and S.clock - S.padRowsAt < 250) then return false end
        local px = c.position
        if not (px.x >= box.a.x and px.x <= box.b.x and px.y >= box.a.y and px.y <= box.b.y) then return false end
        if c.left and not S.mouse.left then
            for i = #padTiles, 1, -1 do
                local tt = padTiles[i]
                if px.x >= tt.a.x and px.x <= tt.b.x and px.y >= tt.a.y and px.y <= tt.b.y then
                    if reskate.audio and reskate.audio.play_ui then pcall(reskate.audio.play_ui, "select") end
                    tt.fn()
                    break
                end
            end
        end
        return true
    end

    -- the mouse on the panel: true when it is there (then the view does nothing with it)
    function UI.panelMouse(c)
        local px = c.position
        local function inside(box) return box and px.x >= box.a.x and px.x <= box.b.x and px.y >= box.a.y and px.y <= box.b.y end
        local onLeft = inside(S.screen and S.screen.leftBox)
        local onTab = false
        for _, tb in ipairs(S.screen and S.screen.tabs or {}) do if inside(tb) then onTab = true end end
        if not (onLeft or onTab or inside(S.screen and S.screen.panelBox) or inside(S.screen and S.screen.snapBox)) then return false end
        if c.wheel and c.wheel ~= 0 then
            local lb = S.screen.listBox
            if lb and onLeft then S.listTop = clamp((S.listTop or 0) - c.wheel * 3, 0, math.max(0, lb.n - lb.rows)) end
        end
        if c.left and not S.mouse.left then
            for i = #tiles, 1, -1 do
                local tt = tiles[i]
                if px.x >= tt.a.x and px.x <= tt.b.x and px.y >= tt.a.y and px.y <= tt.b.y then
                    if reskate.audio and reskate.audio.play_ui then pcall(reskate.audio.play_ui, "select") end
                    tt.fn()
                    break
                end
            end
        end
        return true
    end

    -- ---------------------------------------------------------------- the controls window: a controller and the keys
    local PAD_BODY = { 0,-92,7.6,-92.2,18.3,-92.5,30.7,-92.8,43.4,-93.3,55,-94,65.4,-95,75.6,-96.2,85.6,-97.6,95.4,-98.9,105,-100,114.4,-101.2,123.7,-102.5,132.7,-103.6,141.5,-104.3,150,-104,158.3,-102.9,166.4,-101.2,174.1,-98.9,181.4,-95.8,188,-92,193.9,-87.5,199.1,-82.4,203.8,-76.4,208.1,-69.7,212,-62,215.5,-53.1,218.5,-43.2,221.2,-32.4,223.6,-21.3,226,-10,228.3,1.6,230.4,13.7,232.3,26,234.2,38.2,236,50,237.9,61.6,239.9,73.3,241.8,84.7,243.2,95.4,244,105,244.2,113.5,243.8,121.1,243,127.9,241.8,134.2,240,140,237.7,145.5,234.9,150.6,231.7,155.1,228,159,224,162,219.4,164.3,214.3,165.9,208.9,166.7,203.4,166.8,198,166,192.7,164.2,187.4,161.5,182.1,158.1,176.9,154.2,172,150,167.4,145.3,163,139.9,158.8,134.3,154.5,128.8,150,124,145.5,119.7,141,115.7,136.4,112.1,131.5,108.8,126,106,120,103.7,113.7,101.8,107,100.4,99.8,99.1,92,98,83.4,97,74,96.3,64.3,95.8,54.5,95.4,45,95,35.2,94.7,24.7,94.4,14.7,94.2,6.1,94.1,0,94,-6.1,94.1,-14.7,94.2,-24.7,94.4,-35.2,94.7,-45,95,-54.5,95.4,-64.3,95.8,-74,96.3,-83.4,97,-92,98,-99.8,99.1,-107,100.4,-113.7,101.8,-120,103.7,-126,106,-131.5,108.8,-136.4,112.1,-141,115.7,-145.5,119.7,-150,124,-154.5,128.8,-158.8,134.3,-163,139.9,-167.4,145.3,-172,150,-176.9,154.2,-182.1,158.1,-187.4,161.5,-192.7,164.2,-198,166,-203.4,166.8,-208.9,166.7,-214.3,165.9,-219.4,164.3,-224,162,-228,159,-231.7,155.1,-234.9,150.6,-237.7,145.5,-240,140,-241.8,134.2,-243,127.9,-243.8,121.1,-244.2,113.5,-244,105,-243.2,95.4,-241.8,84.7,-239.9,73.3,-237.9,61.6,-236,50,-234.2,38.2,-232.3,26,-230.4,13.7,-228.3,1.6,-226,-10,-223.6,-21.3,-221.2,-32.4,-218.5,-43.2,-215.5,-53.1,-212,-62,-208.1,-69.7,-203.8,-76.4,-199.1,-82.4,-193.9,-87.5,-188,-92,-181.4,-95.8,-174.1,-98.9,-166.4,-101.2,-158.3,-102.9,-150,-104,-141.5,-104.3,-132.7,-103.6,-123.7,-102.5,-114.4,-101.2,-105,-100,-95.4,-98.9,-85.6,-97.6,-75.6,-96.2,-65.4,-95,-55,-94,-43.4,-93.3,-30.7,-92.8,-18.3,-92.5,-7.6,-92.2,-0,-92 }
    local PAD_INNER = { 0,84,3.5,84.1,8,84.1,13.5,84.2,19.6,84.3,26,84.4,32.6,84.6,39,84.8,45,85,50.9,85.2,57,85.5,63.1,85.8,69.3,86.1,75.4,86.4,81.3,86.9,86.8,87.4,92,88,96.8,88.7,101.3,89.4,105.5,90.2,109.6,91.1,113.4,92,117.1,93.2,120.6,94.5,124,96,127.3,97.8,130.4,99.8,133.3,102,136.1,104.4,138.8,106.8,141.3,109.3,143.7,111.7,146,114,148.2,116.3,150.2,118.6,152,120.9,153.8,123.2,155.4,125.5,157,127.8,158.5,129.9,160,132,161.5,134,163,136.1,164.5,138.2,165.9,140.1,167.2,142,168.3,143.6,169.3,144.9,170,146 }
    local PAD_BUMP = { 98,-104,99.4,-105.1,101.1,-106.8,103.1,-108.7,105.4,-110.8,108,-112.9,111,-114.9,114.3,-116.6,118,-118,122.3,-119.1,127.2,-120,132.6,-120.8,138.2,-121.5,144,-122,149.7,-122.2,155.1,-122.2,160,-122,164.6,-121.5,169.2,-120.6,173.6,-119.5,177.9,-118.2,181.9,-116.8,185.6,-115.2,189,-113.6,192,-112,194.5,-110.2,196.7,-108,198.5,-105.7,200,-103.4,201.3,-101.1,202.3,-99,203.2,-97.3,204,-96 }
    local PAD_TRIG = { 112,-118,113.3,-120.1,115,-123.1,117,-126.6,119.5,-130.2,122.5,-133.5,126,-136,130.4,-137.9,135.6,-139.5,141.2,-140.8,147.1,-141.6,152.8,-142.1,158,-142,162.9,-141.4,167.7,-140.2,172.4,-138.6,176.7,-136.7,180.7,-134.4,184,-132,186.7,-129,188.9,-125.3,190.6,-121.4,192,-117.6,193.1,-114.3,194,-112 }
    local ctiles = {}
    local function keycap(d, x, y, k, wide)
        local w = wide or math.max(34, UI.textW(d, k, 13, "bold") + 18)
        d:rect(V(x, y + 3, 0), V(x + w, y + 33, 0), { colour = "#00000080", fill = true, rounding = 7 })
        d:rect(V(x, y, 0), V(x + w, y + 30, 0), { colour = "#e6e9ef", fill = true, rounding = 7 })
        d:text(V(x + w / 2, y + 7, 0), k, { size = 13, colour = "#0d1117", font = "bold", align = "centre" })
        return w
    end
    local limL, limR = 0, 1e9   -- the text keeps inside these (smaller when it would not fit)
    local function callout(d, from, to, text, right)
        d:line(from, to, { colour = "#ffffff2e", thickness = 1 })
        d:circle(to, 3, { colour = UI.accent, fill = true })
        local size = 14
        local room = right and (limR - to.x - 10) or (to.x - 10 - limL)
        local w = UI.textW(d, text, size)
        if w > room and room > 40 then size = math.max(10, math.floor(size * room / w)) end
        d:text(V(right and to.x + 10 or to.x - 10, to.y - size * 0.62, 0), text, { size = size, colour = UI.text, align = right and "left" or "right" })
    end
    function UI.controlsWin(d)
        ctiles = {}
        local W, H = S.size.x, S.size.y
        local pw, ph = math.min(1500, W - 80), math.min(800, H - 80)
        local a = V(math.floor((W - pw) / 2), math.floor((H - ph) / 2), 0)
        local b = a + V(pw, ph, 0)
        S.screen.controlsBox = { a = a, b = b }
        d:rect(V(0, 0, 0), V(W, H, 0), { colour = "#00000080", fill = true })
        UI.panelBox(d, a, b, "Controls")
        local ca, cb = V(b.x - 48, a.y + 10, 0), V(b.x - 12, a.y + 44, 0)
        d:text(V((ca.x + cb.x) / 2, ca.y + 4, 0), "×", { size = 24, colour = UI.dim, align = "centre" })
        ctiles[#ctiles + 1] = { a = ca, b = cb, fn = function() S.controlsOpen = false end }
        -- changing the keys (the Settings window)
        do
            local ka, kb = V(ca.x - 170, a.y + 11, 0), V(ca.x - 10, a.y + 43, 0)
            btn(d, ka, kb, "Change keys", nil)
            ctiles[#ctiles + 1] = { a = ka, b = kb, fn = function() if FN.openKeys then FN.openKeys() end end }
        end
        -- the controller, drawn (what each button does first, so the pad sits on top of the lines)
        local half = pw * 0.64
        local cx, cy = a.x + half / 2, a.y + 52 + (ph - 52) * 0.45
        d:text(V(a.x + 24, a.y + 68, 0), "CONTROLLER", { size = 13, colour = UI.dim, font = "bold" })
        -- laid out like an Xbox pad: left stick high, d-pad low; right stick low, A B X Y high
        local ls, rs = V(cx - 140, cy - 35, 0), V(cx + 70, cy + 48, 0)
        local dp, ab = V(cx - 70, cy + 48, 0), V(cx + 140, cy - 38, 0)
        local vw, mn = V(cx - 42, cy - 38, 0), V(cx + 42, cy - 38, 0)
        local BP = { y = V(0, -26, 0), x = V(-26, 0, 0), b = V(26, 0, 0), a = V(0, 26, 0) }
        local lx, rx = cx - 255, cx + 255
        limL, limR = a.x + 16, a.x + half - 14
        -- (each button's line: what it does now, when buttons were moved in Settings)
        local function job(which, usual) return (FN.padCallout and FN.padCallout(which)) or usual end
        callout(d, V(cx - 150, cy - 141, 0), V(lx, cy - 205, 0), job("lt", "LT   lower"), false)
        callout(d, V(cx - 125, cy - 112, 0), V(lx, cy - 150, 0), job("lb", "LB   turn  ·  clear group"), false)
        callout(d, ls, V(lx, cy - 70, 0), job("lstick", "L-stick   move  ·  L3 next snap"), false)
        callout(d, vw, V(lx, cy + 5, 0), job("back", "View   snap: auto / one / off"), false)
        callout(d, dp, V(lx, cy + 80, 0), job("dpad", "D-pad   size  ·  zoom"), false)
        callout(d, V(cx + 150, cy - 141, 0), V(rx, cy - 205, 0), job("rt", "RT   raise"), true)
        callout(d, V(cx + 125, cy - 112, 0), V(rx, cy - 160, 0), job("rb", "RB   turn  ·  add to group"), true)
        callout(d, ab + BP.y, V(rx, cy - 115, 0), job("y", "Y   remove  ·  ungroup"), true)
        callout(d, ab + BP.b, V(rx, cy - 75, 0), job("b", "B   cancel  /  close"), true)
        callout(d, ab + BP.x, V(rx, cy - 35, 0), job("x", "X   copy"), true)
        callout(d, ab + BP.a, V(rx, cy + 5, 0), job("a", "A   pick up  ·  hold select"), true)
        callout(d, mn, V(rx, cy + 45, 0), job("start", "Menu   step size"), true)
        callout(d, rs, V(rx, cy + 85, 0), job("rstick", "R-stick look · R3 tools, hold: no snap"), true)
        -- the pad as a line drawing (its outline traced like the usual Xbox pad)
        local LC, LC2 = "#45c8e4", "#45c8e499"
        local function path(pts, sx, col, th)
            local px, py = nil, nil
            for i = 1, #pts, 2 do
                local x, y = cx + pts[i] * sx, cy + pts[i + 1]
                if px then d:line(V(px, py, 0), V(x, y, 0), { colour = col, thickness = th }) end
                px, py = x, y
            end
        end
        path(PAD_BODY, 1, LC, 3)
        path(PAD_INNER, 1, LC2, 2); path(PAD_INNER, -1, LC2, 2)
        path(PAD_BUMP, 1, LC, 3); path(PAD_BUMP, -1, LC, 3)
        path(PAD_TRIG, 1, LC2, 2); path(PAD_TRIG, -1, LC2, 2)
        -- (the buttons' own names: LT / L2 and so on, see part17_keys)
        local pn = FN.padPhysName or function(k) return string.upper(k) end
        d:text(V(cx - 153, cy - 162, 0), pn("lt"), { size = 12, colour = LC, font = "bold", align = "centre" })
        d:text(V(cx + 153, cy - 162, 0), pn("rt"), { size = 12, colour = LC, font = "bold", align = "centre" })
        d:text(V(cx - 222, cy - 118, 0), pn("lb"), { size = 12, colour = LC, font = "bold", align = "centre" })
        d:text(V(cx + 222, cy - 118, 0), pn("rb"), { size = 12, colour = LC, font = "bold", align = "centre" })
        for _, st2 in ipairs({ ls, rs }) do
            d:circle(st2, 30, { colour = LC, thickness = 3 })
            d:circle(st2, 20, { colour = LC2, thickness = 2 })
        end
        d:circle(dp, 32, { colour = LC2, thickness = 2 })
        local cr = { -8, -26, 8, -26, 8, -8, 26, -8, 26, 8, 8, 8, 8, 26, -8, 26, -8, 8, -26, 8, -26, -8, -8, -8, -8, -26 }
        for i = 1, #cr - 2, 2 do d:line(dp + V(cr[i], cr[i + 1], 0), dp + V(cr[i + 2], cr[i + 3], 0), { colour = LC, thickness = 3 }) end
        for k, off in pairs(BP) do
            UI.faceGlyph(d, ab + off, k, 12, true)
        end
        d:circle(vw, 8, { colour = LC, thickness = 2 }); d:circle(mn, 8, { colour = LC, thickness = 2 })
        d:circle(V(cx, cy - 72, 0), 16, { colour = LC, thickness = 3 })
        do
            local nm = FN.padName or function(k) return k end
            local op = FN.padOpenLabel and FN.padOpenLabel()
            local line = string.format("%s%s closes  ·  %s + %s undo  ·  %s + %s redo", op and (op .. " opens  ·  ") or "", nm("b"), nm("lb"), nm("back"), nm("rb"), nm("back"))
            UI.textIn(d, V(a.x + 16, b.y - 76, 0), V(a.x + half - 14, b.y - 52, 0), line, { size = 14, colour = UI.dim, align = "centre" }, 0)
        end
        -- the keyboard and mouse
        local kx = a.x + half + 20
        local ky = a.y + 68
        d:line(V(a.x + half, a.y + 70, 0), V(a.x + half, b.y - 40, 0), { colour = UI.line, thickness = 1 })
        d:text(V(kx, ky, 0), "KEYBOARD AND MOUSE", { size = 13, colour = UI.dim, font = "bold" })
        ky += 34
        -- (the keys as set in Settings: each row its keycaps, then what they do)
        local K = FN.kbCaps or function(_) return { "?" } end
        local function caps(row, ...)
            for _, id in ipairs({ ... }) do for _, c in ipairs(K(id)) do row[#row + 1] = { c } end end
            return row
        end
        local function one(id) local t = K(id); return #t == 1 and t[1] or nil end
        local flyRow
        if one("flyF") == "Up" and one("flyB") == "Down" and one("flyL") == "Left" and one("flyR") == "Right" then
            flyRow = { { "Arrows" } }
            caps(flyRow, "flyU", "flyD")
        else
            flyRow = caps({}, "flyF", "flyL", "flyB", "flyR", "flyU", "flyD")
        end
        flyRow[#flyRow + 1] = "fly the view"
        local redoS = FN.kbLabel and FN.kbLabel("redo") or "Ctrl+Y"
        local rows = {
            caps({}, "modeMove", "modeTurn", "modeSize"),
            caps({}, "osnap"),
            caps({}, "snapTarget"),
            caps({}, "grid"),
            caps({}, "look"),
            caps({}, "undo"),
            caps({}, "bigger"),
            caps({}, "noSnap"),
            flyRow,
            { { "Esc" }, "done" },
        }
        local said = { "move / turn / size handles", "snap to objects on / off", "snap target: auto, one object, off", "drag in steps",
            "look at the picked object", "undo        " .. redoS .. ": redo", "bigger steps", "hold while dragging: no snapping" }
        for i, t in ipairs(said) do rows[i][#rows[i] + 1] = t end
        local kRight = b.x - 18
        for _, r in ipairs(rows) do
            local x = kx
            for _, part in ipairs(r) do
                if type(part) == "table" then x += keycap(d, x, ky, part[1]) + 6
                else UI.fitText(d, x + 8, ky + 6, part, math.max(40, kRight - x - 8), { size = 15, colour = UI.text }) end
            end
            ky += 40
        end
        -- the mouse
        local mx, my = kx + 40, ky + 30
        local tx = mx + 120
        limL, limR = a.x + half + 10, b.x - 18
        callout(d, V(mx + 16, my + 20, 0), V(tx, my - 6, 0), "Left click   pick  ·  drag a handle", true)
        callout(d, V(mx + 18, my + 30, 0), V(tx, my + 26, 0), "Left drag (empty)   turn the view", true)
        callout(d, V(mx + 35, my + 22, 0), V(tx, my + 58, 0), "Wheel   zoom", true)
        callout(d, V(mx + 54, my + 20, 0), V(tx, my + 90, 0), "Right drag   slide the view", true)
        d:rect(V(mx, my, 0), V(mx + 70, my + 110, 0), { colour = "#45c8e4", rounding = 35, thickness = 3 })
        d:line(V(mx + 35, my + 3, 0), V(mx + 35, my + 46, 0), { colour = "#45c8e499", thickness = 2 })
        d:line(V(mx + 4, my + 46, 0), V(mx + 66, my + 46, 0), { colour = "#45c8e499", thickness = 2 })
        d:rect(V(mx + 31, my + 12, 0), V(mx + 39, my + 32, 0), { colour = "#45c8e4", rounding = 4, thickness = 2 })
        UI.fitText(d, tx + 10, my + 113, (FN.kbLabel and FN.kbLabel("multi") or "Ctrl") .. " + click   group add / remove", math.max(40, b.x - 18 - tx - 10), { size = 14, colour = UI.text })
        UI.footer(d, a, b, { { "x", "Change buttons" }, { "b", "Close" } })
    end
    function UI.controlsMouse(c)
        if not S.controlsOpen then return false end
        if c.left and not S.mouse.left then
            local px = c.position
            local box = S.screen.controlsBox
            local used = false
            for _, tt in ipairs(ctiles) do
                if px.x >= tt.a.x and px.x <= tt.b.x and px.y >= tt.a.y and px.y <= tt.b.y then tt.fn(); used = true end
            end
            if not used and box and not (px.x >= box.a.x and px.x <= box.b.x and px.y >= box.a.y and px.y <= box.b.y) then S.controlsOpen = false end
        end
        return true
    end
end)()

function FN.drawMain(d)
    S.size = d:size()
    local cpos, f, r, u = camBasis()
    local probe = d:world_to_screen(cpos + f * 10 + r * 1 + u * 1)
    if probe then
        local mx, my = (probe.x - S.size.x / 2) / 0.1, (S.size.y / 2 - probe.y) / 0.1
        if math.abs(mx) > 1 and math.abs(my) > 1 then S.proj = V(mx, my, 0) end
    end
    S.screen = {}
    if S.picker then return end
    pcall(FN.drawGroup, d)
    pcall(FN.drawGrid, d)
    if S.carry then
        pcall(function()
            for i, c in ipairs(S.carryPlaces()) do
                if i > 200 then break end
                if S.itemBox[c.item] then
                    local sh = worldShape(c.item, c.pos, c.heading, c.scale)
                    sh.cut = "ray"
                    PE.drawShape(d, sh, UI.oSet, 3)
                else
                    d:world_line(c.pos - V(0.4, 0, 0), c.pos + V(0.4, 0, 0), { colour = UI.oSet, thickness = 3 })
                    d:world_line(c.pos - V(0, 0, 0.4), c.pos + V(0, 0, 0.4), { colour = UI.oSet, thickness = 3 })
                    d:world_line(c.pos, c.pos + V(0, 1, 0), { colour = UI.oSet, thickness = 3 })
                end
            end
            for _, gd in ipairs(S.carry.guides or {}) do
                if gd.nb then PE.drawShape(d, gd.nb.shape or gd.nb, UI.oSnap, 3, gd.nb.xf) end
            end
            local W, H = S.size.x, S.size.y
            UI.chip(d, W / 2 - 120, 24, "Carrying  " .. S.carry.set.name, UI.purple)
            UI.promptRow(d, W / 2, H - 48, { { "a", "Put down" }, { "b", "Cancel" }, { "LB RB", "Turn" }, { "RT LT", "Up / down" }, { "L3", "Snap to next" }, { "Hold R3", "No snap" } })
        end)
        return
    end
    if S.toolsWin then
        local okt, errt = pcall(FN.drawTools, d)
        if not okt then reskate.log("Quick Drop helper: copy tools: " .. tostring(errt), "warn"); S.toolsWin = nil end
    end
    -- the controller's view (when the controller was used last): aiming cross, what it is on, prompts along the bottom
    local padMode = S.padUsedAt ~= nil and (not S.mouseUsedAt or S.padUsedAt > S.mouseUsedAt) and S.clock - S.padUsedAt < 60000
    if padMode then pcall(UI.drawPadHud, d) end
    if padMode and not S.grab and not S.drag then return end
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
    local bx = nil
    if S.sel.bp then
        S.boundsCache = S.boundsCache or {}
        bx = S.boundsCache[S.sel.bp]
        if bx == nil then
            local ok, a, b = false, nil, nil
            if reskate.entities then ok, a, b = pcall(reskate.entities.bounds, S.sel.bp) end
            if ok and type(a) == "table" and a.min then a, b = a.min, a.max end
            bx = (ok and a and b) and { a, b } or false
            S.boundsCache[S.sel.bp] = bx
        end
        -- the same size serves snapping
        if bx and S.itemBox[S.sel.item] == nil then S.itemBox[S.sel.item] = bx end
    end
    if not bx and S.itemBox[S.sel.item] then bx = S.itemBox[S.sel.item] end
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
    -- the handles keep a steady size on screen (about 130 pixels)
    local L = S.handleLen or 1.5
    L = math.max(L, 0.05)
    local hv, dg = S.hover, S.drag
    local function hot(kind, i)
        local h = dg or hv
        return h and h.kind == kind and (i == nil or h.axis == i or h.plane == i)
    end

    if padMode then
        -- the controller: no handles (like Quick Drop), only its outline where it is going
        S.screen.axis, S.screen.unit, S.screen.planes, S.screen.ring, S.screen.cubes = {}, {}, {}, {}, {}
    elseif S.mode == 1 then
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
        -- the tilt rings: red tips it forward and back (about its x), blue to the side (about its z)
        -- (none online, where tilt is off: then they can't be grabbed either)
        local AX = axesFor(t.heading)
        local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
        S.screen.tiltx, S.screen.tiltz = {}, {}
        for _, w in ipairs((FN.online and FN.online()) and {} or { { "x", AX[1], AX[2][1], AX[3][1] }, { "z", AX[3], AX[2][1], AX[1][1] } }) do
            local key, axc, u, v = w[1], w[2], w[3], w[4]
            local tp = {}
            for i = 0, 48 do
                local a = i / 48 * 2 * math.pi
                tp[i + 1] = d:world_to_screen(p + (u * math.cos(a) + v * math.sin(a)) * (L * 0.8))
            end
            local tcol = colourOf(axc[2], hot("tilt") and (S.drag or S.hover).axis == key)
            for i = 1, 48 do
                if tp[i] and tp[i + 1] then d:line(tp[i], tp[i + 1], { colour = tcol, thickness = 4 }) end
            end
            S.screen["tilt" .. key] = tp
        end
        if math.abs(tl.x) > 1e-4 or math.abs(tl.z) > 1e-4 then
            d:text(center + V(14, -52, 0), string.format("tilt %.0f°, %.0f°", math.deg(tl.x), math.deg(tl.z)), { size = 16, colour = "#ffffff", shadow = true })
        end
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
    -- what it snaps to, when chosen (L3 tap / Tab): that object in orange
    if S.snapPick then
        local o = S.snapPick ~= "off" and S.known and S.known[S.snapPick]
        if o then
            local so = placedSolid(o)
            pcall(PE.drawShape, d, so.shape or so, UI.oHalo, 7, so.xf)
            PE.drawShape(d, so.shape or so, UI.oPick, 4, so.xf)
        end
        d:text(center + V(14, 8, 0), "snap: " .. FN.snapLabel(), { size = 16, colour = UI.oPick, shadow = true })
    end
    -- what it is snapped to: that object's box (or its point), and how; and the sides that meet lit up
    if S.guides then
        pcall(FN.drawMeeting, d, p, t)
        local seen = {}
        for _, gd in ipairs(S.guides) do
            local id = gd.o.id
            if not seen[id] then
                seen[id] = true
                local nc = cornersOf(gd.nb)
                pcall(PE.drawShape, d, gd.nb.shape or gd.nb, UI.oHalo, 6, gd.nb.xf)
                if PE.drawShape(d, gd.nb.shape or gd.nb, UI.oSnap, 3, gd.nb.xf) then
                    -- drawn
                elseif #nc == 8 then
                    for _, e in ipairs(BOX_EDGES) do d:world_line(nc[e[1] + 1], nc[e[2] + 1], { colour = UI.oSnap, thickness = 3 }) end
                else
                    local q = gd.nb.p
                    d:world_line(q - V(0.4, 0, 0), q + V(0.4, 0, 0), { colour = UI.oSnap, thickness = 3 })
                    d:world_line(q - V(0, 0, 0.4), q + V(0, 0, 0.4), { colour = UI.oSnap, thickness = 3 })
                    d:world_line(q, q + V(0, 0.8, 0), { colour = UI.oSnap, thickness = 3 })
                end
            end
        end
        -- how it snapped, in words, in a tag by the held object
        local words = FN.snapWords(S.guides)
        if words then
            local okM, mm = pcall(function() return d:measure(words, { size = 14, font = "bold" }) end)
            local mw, mh = (okM and mm and mm.x) or #words * 8, (okM and mm and mm.y) or 18
            local ta = center + V(16, 58, 0)
            local tb = ta + V(mw + 24, mh + 10, 0)
            d:rect(ta, tb, { colour = UI.panel, fill = true, rounding = 6 })
            UI.edge(d, ta, tb, 6)
            d:rect(V(ta.x + 5, ta.y + 6, 0), V(ta.x + 8, tb.y - 6, 0), { colour = UI.accent, fill = true, rounding = 2 })
            d:text(V(ta.x + 14, ta.y + 5, 0), words, { size = 14, colour = UI.text, font = "bold" })
        end
    end
    -- measuring: to the objects selected with it, or the nearest
    if S.measureOn and FN.drawMeasure then FN.drawMeasure(d) end
    -- the object's box where it is going: shows at once while the game catches up
    if S.boxCorners and (S.mode ~= 3 or padMode) then
        local c = S.boxCorners
        local moving = S.dirty or (S.drag and S.drag.moved) or not lastApplied()
        local col = moving and UI.oHeld or UI.oRest
        local sh = S.itemBox[S.sel.item] and worldShape(S.sel.item, p, t.heading, t.scale) or nil
        local tl = tilted(S.sel.id) and S.tilt[S.sel.id] or nil
        local xf = tl and function(v) return tiltPoint(p, t.heading, tl, v) end or nil
        if xf then for i = 0, 7 do c[i] = xf(c[i]) end end
        pcall(FN.drawGhost, d, c, sh, p, center, moving, xf)
        if sh then sh.cut = "held" end
        if sh then pcall(PE.drawShape, d, sh, UI.oHalo, 6, xf) end
        -- (the held one: with a see-through fill, as Quick Drop's, where its model is known)
        if sh then sh.fill = true end
        if not (sh and PE.drawShape(d, sh, col, 3, xf)) then
            for _, e in ipairs(BOX_EDGES) do
                d:world_line(c[e[1]], c[e[2]], { colour = col, thickness = 2 })
            end
        end
    end
end

-- The sides that meet while holding: where a side of the held object lies against a side of what it snapped to
-- (the two facing each other, at most 3 cm apart, overlapping along their length), that stretch is lit on both,
-- from the higher of the two bottoms to the lower of the two tops. Set on top of it (or it on top): where their
-- outlines overlap seen from above, lit at that height.
-- (its colour: UI.oMeet, the player's choice)
local function dot3(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
function FN.drawMeeting(d, p, t)
    if not (S.sel and S.itemBox[S.sel.item]) or tilted(S.sel.id) then return end
    local me = worldShape(S.sel.item, p, t.heading, t.scale)
    if not (me.edges and #me.edges > 0) then return end
    local done = {}
    for _, gd in ipairs(S.guides or {}) do
        local nb = gd.nb
        if nb and nb.edges and gd.o and not done[gd.o.id] and not tilted(gd.o.id) then
            done[gd.o.id] = true
            local ylo, yhi = math.max(me.ylo, nb.ylo), math.min(me.yhi, nb.yhi)
            -- side by side
            if yhi - ylo > 0.02 then
                for _, e1 in ipairs(me.edges) do
                    for _, e2 in ipairs(nb.edges) do
                        if dot3(e1.n, e2.n) < -0.995 and math.abs(dot3(e2.a - e1.a, e1.n)) < 0.03 then
                            local t0, t1 = dot3(e2.a - e1.a, e1.e), dot3(e2.b - e1.a, e1.e)
                            if t0 > t1 then t0, t1 = t1, t0 end
                            local u0, u1 = math.max(0, t0), math.min(e1.len, t1)
                            if u1 - u0 > 0.03 then
                                local a0, a1 = e1.a + e1.e * u0, e1.a + e1.e * u1
                                local c1, c2 = V(a0.x, ylo, a0.z), V(a1.x, ylo, a1.z)
                                local c3, c4 = V(a1.x, yhi, a1.z), V(a0.x, yhi, a0.z)
                                local s1, s2, s3, s4 = d:world_to_screen(c1), d:world_to_screen(c2), d:world_to_screen(c3), d:world_to_screen(c4)
                                if s1 and s2 and s3 and s4 then d:poly({ s1, s2, s3, s4 }, { colour = string.sub(UI.oMeet, 1, 7) .. "40", fill = true }) end
                                d:world_line(c1, c2, { colour = UI.oMeet, thickness = 4 })
                                d:world_line(c4, c3, { colour = UI.oMeet, thickness = 4 })
                                d:world_line(c1, c4, { colour = UI.oMeet, thickness = 3 })
                                d:world_line(c2, c3, { colour = UI.oMeet, thickness = 3 })
                            end
                        end
                    end
                end
            end
            -- one on top of the other: the held one's outline where it rests (or where the other rests on it)
            local onTop = math.abs(me.ylo - nb.yhi) < 0.03
            local under = math.abs(me.yhi - nb.ylo) < 0.03
            if (onTop or under) and me.pts and #me.pts >= 3 and nb.pts and #nb.pts >= 3 then
                local yy = onTop and me.ylo or me.yhi
                -- (the overlap seen from above, roughly: the held one's corners inside the other's box, else the
                -- other's corners inside its box: the smaller one's outline)
                local small = (me.x1 - me.x0) * (me.z1 - me.z0) <= (nb.x1 - nb.x0) * (nb.z1 - nb.z0) and me or nb
                local n = #small.pts
                for i = 1, n do
                    local a, b = small.pts[i], small.pts[i % n + 1]
                    d:world_line(V(a.x, yy, a.z), V(b.x, yy, b.z), { colour = UI.oMeet, thickness = 4 })
                end
            end
        end
    end
end

reskate.on("draw", function(d)
    if not S.open then return end
    if UI.gripsClear then UI.gripsClear() end
    local ok, err = pcall(FN.drawMain, d)
    if not ok then FN.problem("drawing", err) end
    if S.ownPanel and not S.picker then
        local okp, errp = pcall(UI.sidePanel, d)
        if not okp then FN.problem("the panel", errp) end
        -- the picked object's position, turn, size and tilt along the bottom (the controller's view draws them under
        -- its prompts itself)
        local padView = S.padUsedAt ~= nil and (not S.mouseUsedAt or S.padUsedAt > S.mouseUsedAt) and S.clock - S.padUsedAt < 60000
        if not padView then
            local okr, errr = pcall(UI.padRows, d, true)
            if not okr then FN.problem("the bottom rows", errr) end
        end
    end
    if S.picker then
        local okk, errk = pcall(FN.drawPicker, d)
        if not okk then FN.problem("the add window", errk); S.picker = nil end
    end
    if S.controlsOpen then
        local okc, errc = pcall(UI.controlsWin, d)
        if not okc then FN.problem("the controls window", errc); S.controlsOpen = false end
    end
    if S.colours and UI.coloursWin then
        local okw, errw = pcall(UI.coloursWin, d)
        if not okw then FN.problem("the colours window", errw); S.colours = nil end
    end
    if S.keysWin and UI.keysWin then
        local okk2, errk2 = pcall(UI.keysWin, d)
        if not okk2 then FN.problem("the settings window", errk2); S.keysWin = nil end
    end
end)

reskate.on("load", function()
    local k = FN.kbLabel or function(_, _) return "?" end
    reskate.log(string.format("Quick Drop helper ready: drop an object, then %s (Settings changes the keys).", k("open")))
end)

end
