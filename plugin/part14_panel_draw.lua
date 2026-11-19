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
    local function btn(d, a, b, label, fn, style)
        local h = hot(a, b)
        local col = style == "primary" and (h and "#ffe27a" or UI.accent) or (style == "on" and (h and "#ffffff40" or "#ffffff33") or (h and UI.tileHot or UI.tile))
        if style == "danger" then col = h and "#f85149cc" or "#f8514966" end
        d:rect(a, b, { colour = col, fill = true, rounding = 9 })
        if style == "on" then d:rect(a, b, { colour = UI.accent, rounding = 9, thickness = 2 }) end
        textIn(d, a, b, label, { size = 15, colour = style == "primary" and "#0d1117" or UI.text, font = (style == "primary" or style == "on") and "bold" or nil, align = "centre" })
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
        d:rect(a, b, { colour = h and "#2a313bf8" or UI.bg2, fill = true, rounding = 8 })
        local cx, cy, r = (a.x + b.x) / 2, (a.y + b.y) / 2, 6
        local pts
        if dir == "left" then pts = { V(cx + r * 0.6, cy - r, 0), V(cx + r * 0.6, cy + r, 0), V(cx - r * 0.7, cy, 0) }
        elseif dir == "right" then pts = { V(cx - r * 0.6, cy - r, 0), V(cx - r * 0.6, cy + r, 0), V(cx + r * 0.7, cy, 0) }
        elseif dir == "up" then pts = { V(cx - r, cy + r * 0.6, 0), V(cx + r, cy + r * 0.6, 0), V(cx, cy - r * 0.7, 0) }
        else pts = { V(cx - r, cy - r * 0.6, 0), V(cx + r, cy - r * 0.6, 0), V(cx, cy + r * 0.7, 0) } end
        d:poly(pts, { colour = h and UI.accent or "#f0f3f6c0", fill = true })
        tileAdd(a, b, fn)
        if not noBox then S.screen.tabs = S.screen.tabs or {}; S.screen.tabs[#S.screen.tabs + 1] = { a = a, b = b } end
    end
    -- a row of choices, one of them on
    local function seg(d, x, y, w, labels, cur, fn)
        local n = #labels
        d:rect(V(x, y, 0), V(x + w, y + 34, 0), { colour = "#00000040", fill = true, rounding = 10 })
        local cw = (w - 4) / n
        for i, l in ipairs(labels) do
            local a, b = V(x + 2 + (i - 1) * cw, y + 2, 0), V(x + 2 + i * cw, y + 32, 0)
            local on = i == cur
            local h = hot(a, b)
            if on then d:rect(a, b, { colour = UI.accent, fill = true, rounding = 8 })
            elseif h then d:rect(a, b, { colour = UI.tile, fill = true, rounding = 8 }) end
            textIn(d, a, b, l, { size = 14, colour = on and "#0d1117" or UI.dim, font = on and "bold" or nil, align = "centre" }, 4)
            tileAdd(a, b, function() fn(i) end)
        end
        return y + 34
    end
    local function switch(d, x, y, w, label, on, fn)
        local a, b = V(x, y, 0), V(x + w, y + 34, 0)
        if hot(a, b) then d:rect(a, b, { colour = UI.tile, fill = true, rounding = 9 }) end
        local sx = x + w - 52
        textIn(d, V(x + 2, y, 0), V(sx - 4, y + 34, 0), label, { size = 15, colour = UI.text })
        d:rect(V(sx, y + 7, 0), V(sx + 40, y + 27, 0), { colour = on and UI.accent or "#ffffff2a", fill = true, rounding = 10 })
        d:circle(V(on and sx + 30 or sx + 10, y + 17, 0), 8, { colour = on and "#0d1117" or "#e6e9ef", fill = true })
        tileAdd(a, b, fn)
        return y + 34
    end
    -- label   [-]  value  [+]   (click the value to type it)
    local function stepRow(d, x, y, w, label, value, dec, inc, edit, off)
        -- (off: shown crossed out and doing nothing, as tilt online)
        if off then
            local bx = x + w - 196
            textIn(d, V(x, y + 2, 0), V(bx - 4, y + 30, 0), label, { size = 14, colour = "#f0f3f640" }, 4)
            d:rect(V(bx, y + 2, 0), V(bx + 196, y + 30, 0), { colour = "#00000030", fill = true, rounding = 7 })
            textIn(d, V(bx, y + 2, 0), V(bx + 196, y + 30, 0), value, { size = 15, colour = "#f0f3f640", align = "centre" })
            d:line(V(x + 2, y + 16, 0), V(x + w - 2, y + 16, 0), { colour = "#f85149b0", thickness = 2 })
            return y + 34
        end
        local bx = x + w - 196
        textIn(d, V(x, y + 2, 0), V(bx - 4, y + 30, 0), label, { size = 14, colour = UI.dim }, 4)
        local m1a, m1b = V(bx, y + 2, 0), V(bx + 30, y + 30, 0)
        local va, vb = V(bx + 34, y + 2, 0), V(bx + 162, y + 30, 0)
        local p1a, p1b = V(bx + 166, y + 2, 0), V(bx + 196, y + 30, 0)
        d:rect(m1a, m1b, { colour = hot(m1a, m1b) and UI.tileHot or UI.tile, fill = true, rounding = 7 })
        textIn(d, m1a, m1b, "-", { size = 18, colour = UI.text, align = "centre" }, 2)
        d:rect(va, vb, { colour = hot(va, vb) and "#ffffff1c" or "#00000040", fill = true, rounding = 7 })
        textIn(d, va, vb, value, { size = 15, colour = UI.text, align = "centre" }, 6)
        d:rect(p1a, p1b, { colour = hot(p1a, p1b) and UI.tileHot or UI.tile, fill = true, rounding = 7 })
        textIn(d, p1a, p1b, "+", { size = 18, colour = UI.text, align = "centre" }, 2)
        tileAdd(m1a, m1b, dec); tileAdd(p1a, p1b, inc); tileAdd(va, vb, edit)
        return y + 34
    end
    local function label(d, x, y, str)
        fitText(d, x + 2, y, string.upper(str), PW - 36, { size = 12, colour = "#f0f3f670", font = "bold" })
        return y + 20
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

    -- ---------------------------------------------------------------- the park, in a panel on the left: the group,
    -- arranging it, the park's objects (search, pick, delete) and saving it as a park mod
    local function parkPanel(d)
        local W, H = S.size.x, S.size.y
        if S.hide.left then
            local ta, tb = V(14, H / 2 - 40, 0), V(42, H / 2 + 40, 0)
            S.screen.leftBox, S.screen.leftEdge, S.screen.listBox = nil, tb.x, nil
            arrowTab(d, ta, tb, "right", function() toggleHide("left") end)
            return
        end
        local a = V(14, 14, 0)
        local b = V(14 + PW, H - 14, 0)
        S.screen.leftBox = { a = a, b = b }
        S.screen.leftEdge = b.x + 30
        d:rect(a + V(0, 4, 0), b + V(0, 4, 0), { colour = "#00000055", fill = true, rounding = 16 })
        d:rect(a, b, { colour = UI.bg2, fill = true, rounding = 16 })
        arrowTab(d, V(b.x + 4, H / 2 - 40, 0), V(b.x + 28, H / 2 + 40, 0), "left", function() toggleHide("left") end)
        local x, w = a.x + 16, PW - 32
        local y = a.y + 16
        d:text(V(x, y, 0), "Park", { size = 22, colour = UI.text, font = "heading" })
        y += 40
        local ng = groupCount()
        local miss = S.missing or {}
            y = label(d, x, y, ng > 0 and string.format("Group  ·  %d objects", ng) or "Group")
            local gw = (w - 8) / 2
            btn(d, V(x, y, 0), V(x + gw, y + 34, 0), "Add / remove picked", function() if S.sel and S.known and S.known[S.sel.id] and S.toggleGroup then S.toggleGroup(S.known[S.sel.id]) end end)
            btn(d, V(x + gw + 8, y, 0), V(x + w, y + 34, 0), "Clear group", function() if S.clearGroup then S.clearGroup() end end)
            y += 42
            btn(d, V(x, y, 0), V(x + w, y + 34, 0), "Copy tools   (row, circle, grid)", function() if S.openTools then S.openTools() end end)
            y += 46
            y = label(d, x, y, "Arrange the group")
            local aw = (w - 8) / 2
            btn(d, V(x, y, 0), V(x + aw, y + 30, 0), "Mirror left / right", function() S.arrange("mirrorX") end)
            btn(d, V(x + aw + 8, y, 0), V(x + w, y + 30, 0), "Mirror front / back", function() S.arrange("mirrorZ") end)
            y += 36
            local a3 = (w - 12) / 3
            btn(d, V(x, y, 0), V(x + a3, y + 30, 0), "Line up", function() S.arrange("lineup") end)
            btn(d, V(x + a3 + 6, y, 0), V(x + 2 * a3 + 6, y + 30, 0), "Space evenly", function() S.arrange("space") end)
            btn(d, V(x + 2 * a3 + 12, y, 0), V(x + w, y + 30, 0), "Same height", function() S.arrange("level") end)
            y += 40
            -- the park at a glance
            local okS, ps = pcall(FN.parkStats)
            if okS and ps then
                local line = string.format("%d object%s  ·  %d kind%s", ps.n, ps.n == 1 and "" or "s", ps.kinds, ps.kinds == 1 and "" or "s")
                if ps.top and ps.topN > 1 then line = line .. string.format("  ·  most: %s ×%d", FN.shortTitle(titleOf(ps.top), 14), ps.topN) end
                fitText(d, x + 4, y, line, w - 8, { size = 13, colour = UI.dim })
                y += 22
                if #ps.dups > 0 then
                    local lbl = string.format("Remove %d stacked duplicate%s", #ps.dups, #ps.dups == 1 and "" or "s")
                    if S.dupAsk and S.clock - S.dupAsk < 3000 then lbl = "Click again to remove them" end
                    btn(d, V(x, y, 0), V(x + w, y + 30, 0), lbl, function()
                        if S.dupAsk and S.clock - S.dupAsk < 3000 then S.dupAsk = nil; FN.removeDuplicates()
                        else S.dupAsk = S.clock; say(string.format("%d object%s sit exactly on top of the same object. Click again to remove them.", #ps.dups, #ps.dups == 1 and "" or "s")) end
                    end)
                    y += 38
                end
            end
            y += 6
            FN.rebuildList()
            y = label(d, x, y, string.format("Objects in this park  ·  %d", S.listMatched or 0))
            local sa, sb = V(x, y, 0), V(x + w, y + 32, 0)
            d:rect(sa, sb, { colour = hot(sa, sb) and "#ffffff1c" or "#00000040", fill = true, rounding = 8 })
            textIn(d, sa, sb, S.search ~= "" and ("Search:  " .. S.search) or "Search…", { size = 14, colour = S.search ~= "" and UI.text or UI.dim }, 12)
            tileAdd(sa, sb, function()
                S.typeSearch = true
                local ok = pcall(reskate.ui.dialog, "ddh_search", { title = "Search objects", message = "Part of a name (empty: all).", field = { text = S.search, max = 40 },
                    buttons = { { id = "apply", label = "Search" }, { id = "close", label = "Cancel" } } })
                if ok then S.typing = true end
            end)
            y += 40
            y = seg(d, x, y, w, { "All", "Near", "DDH" }, S.listFilter, function(i) S.listFilter = i; S.listKey = nil; S.listTop = 0 end) + 8
            -- the list: as many rows as fit, the wheel scrolls it
            local rowH = 30
            local bottom = b.y - 112
            local rows = math.max(3, math.floor((bottom - y) / rowH))
            local n = #(S.listObjs or {})
            S.listTop = clamp(S.listTop or 0, 0, math.max(0, n - rows))
            S.screen.listBox = { a = V(x, y, 0), b = V(x + w, y + rows * rowH, 0), rows = rows, n = n }
            for r = 1, rows do
                local i = S.listTop + r
                local o = S.listObjs and S.listObjs[i]
                if not o then break end
                local ra, rb = V(x, y + (r - 1) * rowH, 0), V(x + w, y + r * rowH - 2, 0)
                local on = S.sel and S.sel.id == o.id
                if on then d:rect(ra, rb, { colour = UI.accentDim, fill = true, rounding = 7 })
                elseif S.group[o.id] then d:rect(ra, rb, { colour = "#c49bff2a", fill = true, rounding = 7 })
                elseif hot(ra, rb) then d:rect(ra, rb, { colour = UI.tile, fill = true, rounding = 7 }) end
                local name = titleOf(o.item)
                if S.group[o.id] then d:circle(V(x + 10, ra.y + 14, 0), 4, { colour = UI.purple, fill = true }) end
                fitText(d, x + 20, ra.y + 6, name, w - 80, { size = 14, colour = on and UI.accent or UI.text })
                d:text(V(rb.x - 8, ra.y + 6, 0), string.format("%.0f m", len(o.position - (S.cam.target or o.position))), { size = 13, colour = UI.dim, align = "right" })
                tileAdd(ra, rb, function()
                    if reskate.input.key("Ctrl") then
                        -- Ctrl+click: in or out of the selection (the picked one joins first)
                        if S.sel and not S.group[S.sel.id] and groupCount() == 0 and S.sel.id ~= o.id then S.group[S.sel.id] = true end
                        if S.group[o.id] then S.group[o.id] = nil else S.group[o.id] = true end
                        S.gbase = nil
                        local n = groupCount()
                        say(n > 0 and string.format("%d selected  (Ctrl+click adds or removes)", n) or "Nothing selected.")
                        return
                    end
                    send(); select(o); S.cam.goal = o.position; S.listKey = nil; say("Picked " .. titleOf(o.item))
                end)
            end
            if n > rows then
                local la, lb2 = S.screen.listBox.a, S.screen.listBox.b
                local f0, f1 = S.listTop / n, math.min(1, (S.listTop + rows) / n)
                d:rect(V(lb2.x + 4, la.y + (lb2.y - la.y) * f0, 0), V(lb2.x + 7, la.y + (lb2.y - la.y) * f1, 0), { colour = UI.accent, fill = true, rounding = 2 })
            end
            local pb = b.y - 56
            -- delete the selected ones (the group, else the picked one): click twice; undo puts them back
            local delIds = FN.replaceTargets()
            local nd = #delIds
            local dl = nd > 1 and string.format("Delete %d selected", nd) or (nd == 1 and "Delete picked" or "Delete  (pick or Ctrl+click objects)")
            if nd > 0 and S.listDelAsk and S.clock - S.listDelAsk < 3000 then dl = string.format("Click again to delete %d", nd) end
            btn(d, V(x, pb - 42, 0), V(x + w, pb - 8, 0), dl, function()
                if nd == 0 then say("Pick an object, or Ctrl+click objects in the list, then Delete.", true) return end
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
            btn(d, V(x, pb, 0), V(x + w, pb + 34, 0), "Save as park mod  (for online)", function() FN.saveParkModSay() end)
            if S.blocked or #miss > 0 then
                btn(d, V(x, pb - 84, 0), V(x + w, pb - 50, 0), "Park locked: check again", function()
                    S.blocked = nil; pcall(findMissing)
                    if #(S.missing or {}) == 0 then say("No missing objects found. Try moving something again.") else say("Fix: run Clean out park.exe with the game closed.", true) end
                end)
            end
    end

    -- (the tabs, and the number each stands for in S.ptab: the park has its own panel on the left)
    local TABS, TAB_IDS = { "Edit", "Snap", "Sets" }, { 1, 2, 4 }
    function UI.sidePanel(d)
        tiles = {}
        S.screen.tabs = {}
        local W, H = S.size.x, S.size.y
        if S.hide.right then
            -- (hidden: only a tab at the screen's edge, to bring it back)
            local ta, tb = V(W - 14 - 28, H / 2 - 40, 0), V(W - 14, H / 2 + 40, 0)
            S.screen.panelBox, S.screen.rightEdge = nil, ta.x
            arrowTab(d, ta, tb, "left", function() toggleHide("right") end)
            parkPanel(d)
            return
        end
        local a = V(W - PW - 14, 14, 0)
        local b = V(W - 14, H - 14, 0)
        S.screen.panelBox = { a = a, b = b }
        S.screen.rightEdge = a.x - 30
        d:rect(a + V(0, 4, 0), b + V(0, 4, 0), { colour = "#00000055", fill = true, rounding = 16 })
        d:rect(a, b, { colour = UI.bg2, fill = true, rounding = 16 })
        arrowTab(d, V(a.x - 28, H / 2 - 40, 0), V(a.x - 4, H / 2 + 40, 0), "right", function() toggleHide("right") end)
        local x, w = a.x + 16, PW - 32
        local y = a.y + 16
        -- title and Done
        d:text(V(x, y, 0), "DDH Park Editor", { size = 22, colour = UI.text, font = "heading" })
        d:text(V(x, y + 27, 0), "Quick Drop+", { size = 13, colour = UI.dim })
        btn(d, V(b.x - 16 - 86, y + 2, 0), V(b.x - 16, y + 34, 0), "Done", function() closeEditor() end)
        y += 54
        -- what is picked
        local t = S.sel and S.target
        local ng = groupCount()
        d:rect(V(x, y, 0), V(x + w, y + 64, 0), { colour = "#ffffff0c", fill = true, rounding = 12 })
        local title, sub, dot = "Nothing picked", "Click an object, or aim the cross and press A", "#ffffff40"
        if t then
            title = titleOf(S.sel.item)
            sub = string.format("%.0f°   ·   size %.2f", math.deg(t.heading), t.scale)
            dot = UI.accent
            if S.group[S.sel.id] and ng > 1 then sub = sub .. string.format("   ·   group of %d", ng); dot = UI.purple end
        elseif ng > 0 then
            title, sub, dot = string.format("Group of %d", ng), "Pick one of them up to move them all", UI.purple
        end
        d:circle(V(x + 18, y + 22, 0), 5, { colour = dot, fill = true })
        fitText(d, x + 32, y + 11, title, w - 44, { size = 17, colour = UI.text, font = "bold" })
        fitText(d, x + 32, y + 36, sub, w - 44, { size = 13, colour = UI.dim })
        y += 76
        -- warnings and the last message
        local miss = S.missing or {}
        if S.blocked or #miss > 0 then
            d:rect(V(x, y, 0), V(x + w, y + 30, 0), { colour = "#f8514933", fill = true, rounding = 9 })
            fitText(d, x + 12, y + 7, string.format("Park locked: %d from a missing mod (see Park)", #miss), w - 20, { size = 13, colour = "#ffb3ad" })
            y += 38
        end
        -- the everyday buttons
        local bw = (w - 18) / 4
        btn(d, V(x, y, 0), V(x + bw, y + 36, 0), "+ Add", function() if S.openPicker then S.openPicker() end end, "primary")
        btn(d, V(x + bw + 6, y, 0), V(x + 2 * bw + 6, y + 36, 0), "Undo", function() undo() end)
        btn(d, V(x + 2 * bw + 12, y, 0), V(x + 3 * bw + 12, y + 36, 0), "Redo", function() if S.redoFn then S.redoFn() end end)
        btn(d, V(x + 3 * bw + 18, y, 0), V(x + w, y + 36, 0), "Controls", function() S.controlsOpen = true end)
        y += 48
        -- tabs
        S.ptab = S.ptab or 1
        if S.ptab ~= 1 and S.ptab ~= 2 and S.ptab ~= 4 then S.ptab = 1 end
        local tw = w / #TABS
        for i, n in ipairs(TABS) do
            local ta, tb = V(x + (i - 1) * tw, y, 0), V(x + i * tw, y + 34, 0)
            local on = TAB_IDS[i] == S.ptab
            textIn(d, ta, V(tb.x, tb.y - 4, 0), n, { size = 16, colour = on and UI.text or UI.dim, font = on and "bold" or nil, align = "centre" }, 4)
            d:rect(V(ta.x + 6, y + 31, 0), V(tb.x - 6, y + 34, 0), { colour = on and UI.accent or "#ffffff14", fill = true, rounding = 2 })
            tileAdd(ta, tb, function() S.ptab = TAB_IDS[i] end)
        end
        y += 48
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
                local qw = (w - 16) / 3
                btn(d, V(x, y, 0), V(x + qw, y + 34, 0), "Straighten", function() markUndo(); t.heading = round(t.heading, math.pi / 2); if S.tilt[S.sel.id] then S.tilt[S.sel.id] = nil; S.tiltSaveDue = true end; S.dirty = true end)
                btn(d, V(x + qw + 8, y, 0), V(x + 2 * qw + 8, y + 34, 0), "Size 1", function() markUndo(); t.scale = 1; S.dirty = true end)
                btn(d, V(x + 2 * qw + 16, y, 0), V(x + w, y + 34, 0), "Look at it", function() S.cam.goal = t.pos end)
                y += 42
                local nr = #FN.replaceTargets()
                btn(d, V(x, y, 0), V(x + w, y + 34, 0), nr > 1 and string.format("Replace all %d with another object…", nr) or "Replace with another object…", function() FN.openReplace() end)
                y += 48
            end
            y = label(d, x, y, "Step size")
            y = seg(d, x, y, w, { "Fine", "Normal", "Big" }, S.stepSize, function(i) S.stepSize = i end) + 6
            fitText(d, x + 4, y, string.format("%s m  ·  %s  ·  size %s", string.format("%.2f", st.m), string.format(st.df, st.deg), string.format("%.2f", st.size)), w - 8, { size = 13, colour = UI.dim })
        elseif S.ptab == 2 then
            y = switch(d, x, y, w, "Snap to objects   (T)", S.osnap, function() S.osnap = not S.osnap end) + 10
            if S.osnap then
                y = label(d, x, y, "Snap by")
                y = seg(d, x, y, w, { "Matching sides", "Classic" }, S.snapStyle == "classic" and 2 or 1, function(i) FN.setSnapStyle(i == 2 and "classic" or "match") end) + 4
                fitText(d, x + 4, y, S.snapStyle == "classic" and "Sides meet and line up with anything near." or "A side snaps flat to a side of about the same size.", w - 8, { size = 13, colour = UI.dim })
                y += 26
                y = label(d, x, y, "Snapping to:  " .. FN.snapLabelP())
                local cur = S.snapPick == nil and 1 or (S.snapPick == "off" and 3 or 2)
                y = seg(d, x, y, w, { "Auto", "Next object", "Off" }, cur, function(i)
                    if i == 1 then S.snapPick = nil; S.snapLock = nil
                    elseif i == 2 and S.nextSnap then S.nextSnap()
                    elseif i == 3 then S.snapPick = "off"; S.guides = nil end
                end) + 6
                fitText(d, x + 4, y, "Tab, or tap L3 while holding, switches it.", w - 8, { size = 13, colour = UI.dim })
                y += 30
                -- how strongly it snaps: click anywhere on the bar (or hold and drag), or use - / +
                local k = S.snapStrength or 1
                y = label(d, x, y, string.format("Snap strength:  %d%%", math.floor(k * 100 + 0.5)))
                local ba, bb = V(x + 40, y + 6, 0), V(x + w - 40, y + 26, 0)
                local f = (k - 0.2) / 1.8
                d:rect(ba, bb, { colour = "#00000040", fill = true, rounding = 10 })
                d:rect(ba, V(ba.x + (bb.x - ba.x) * f, bb.y, 0), { colour = UI.accent, fill = true, rounding = 10 })
                local mark = ba.x + (bb.x - ba.x) * (0.8 / 1.8)
                d:rect(V(mark - 1, ba.y - 3, 0), V(mark + 1, bb.y + 3, 0), { colour = "#ffffff55", fill = true })
                d:circle(V(ba.x + (bb.x - ba.x) * f, (ba.y + bb.y) / 2, 0), 11, { colour = "#e6e9ef", fill = true })
                local function setFromMouse()
                    local m = S.mouse and S.mouse.pos
                    if m then FN.setSnapStrength(0.2 + 1.8 * clamp((m.x - ba.x) / (bb.x - ba.x), 0, 1), true) end
                end
                tileAdd(V(ba.x - 12, ba.y - 8, 0), V(bb.x + 12, bb.y + 8, 0), function() setFromMouse(); S.snapSliderDrag = setFromMouse end)
                if S.snapSliderDrag and S.mouse and S.mouse.left then S.snapSliderDrag() else S.snapSliderDrag = nil end
                local ma, mb = V(x, y + 2, 0), V(x + 30, y + 30, 0)
                local pa, pb = V(x + w - 30, y + 2, 0), V(x + w, y + 30, 0)
                btn(d, ma, mb, "-", function() FN.setSnapStrength(k - 0.1, true) end)
                btn(d, pa, pb, "+", function() FN.setSnapStrength(k + 0.1, true) end)
                y += 36
                fitText(d, x + 4, y, "Lower: only snaps right up against things. Higher: from further away.", w - 8, { size = 13, colour = UI.dim })
                y += 30
            end
            y = label(d, x, y, "Grid")
            y = seg(d, x, y, w, FN.GRID_NAMES_P, S.gridI or 1, function(i) S.gridI = i end) + 14
            y = switch(d, x, y, w, "Drag in steps   (G)", S.snap, function() S.snap = not S.snap end) + 8
            y = switch(d, x, y, w, "Land on what is under it", S.landOn, function() S.landOn = not S.landOn end) + 8
            y = switch(d, x, y, w, "Show height and gap", S.readoutOn, function() S.readoutOn = not S.readoutOn end) + 6
            fitText(d, x + 4, y, "Hold R3 (or Ctrl) to move without snapping.", w - 8, { size = 13, colour = UI.dim })
            y += 26
        elseif S.ptab == 4 then
            -- ---------------------------------------------------------------- sets
            local nm = #(S.setMembers and S.setMembers() or {})
            fitText(d, x + 4, y, nm > 0 and string.format("Saves the %s (%d object%s)", nm > 1 and "group" or "picked object", nm, nm == 1 and "" or "s")
                or "Pick an object or make a group,", w - 8, { size = 13, colour = UI.dim })
            fitText(d, x + 4, y + 18, nm > 0 and "to place again on any map or server." or "then save it here.", w - 8, { size = 13, colour = UI.dim })
            y += 42
            btn(d, V(x, y, 0), V(x + w, y + 38, 0), nm > 0 and string.format("Save as a set  (%d)", nm) or "Save as a set", function()
                if nm == 0 then say("Pick an object or make a group first.", true) return end
                local ok = pcall(reskate.ui.dialog, "ddh_setname", { title = "Save as a set", message = "A name for it (letters, numbers, spaces).", field = { text = "My set", max = 40 },
                    buttons = { { id = "apply", label = "Save" }, { id = "close", label = "Cancel" } } })
                if ok then S.typing = true end
            end, nm > 0 and "primary" or nil)
            y += 52
            if not S.sets or S.clock - (S.setsAt or -1e9) > 5000 then S.loadSets() end
            y = label(d, x, y, string.format("Saved sets  ·  %d", #S.sets))
            if #S.sets == 0 then
                fitText(d, x + 4, y, "None yet.", w - 8, { size = 14, colour = UI.dim }); y += 26
            end
            local rowH = 100
            local maxRows = math.max(2, math.floor((b.y - 120 - y) / rowH))
            for i, set in ipairs(S.sets) do
                if i > maxRows then
                    fitText(d, x + 4, y, string.format("+%d more (in Add object > Sets)", #S.sets - maxRows), w - 8, { size = 13, colour = UI.dim }); y += 24
                    break
                end
                local ra, rb = V(x, y, 0), V(x + w, y + rowH - 6, 0)
                d:rect(ra, rb, { colour = UI.tile, fill = true, rounding = 9 })
                -- its layout from above
                local pa, pb2 = V(x + 6, y + 6, 0), V(x + 104, y + 58, 0)
                d:rect(pa, pb2, { colour = "#00000040", fill = true, rounding = 6 })
                pcall(UI.drawSetPreview, d, set, pa + V(4, 4, 0), pb2 - V(4, 4, 0), UI.purple)
                local nmS = set.name
                fitText(d, x + 114, y + 9, nmS, w - 120, { size = 15, colour = UI.text, font = "bold" })
                fitText(d, x + 114, y + 29, string.format("%d objects", #set.objects), w - 120, { size = 12, colour = UI.dim })
                local by = y + 64
                local bw4 = (w - 12 - 18) / 4
                local bx = x + 6
                btn(d, V(bx, by, 0), V(bx + bw4, by + 28, 0), "Place", function() S.carrySet(set, FN.crossPoint(), wrap(S.cam.yaw + math.pi)) end, "primary")
                btn(d, V(bx + bw4 + 6, by, 0), V(bx + 2 * bw4 + 6, by + 28, 0), "Rename", function()
                    S.renameSet = set
                    local ok = pcall(reskate.ui.dialog, "ddh_setrename", { title = "Rename set", message = "A new name.", field = { text = set.name, max = 40 },
                        buttons = { { id = "apply", label = "Rename" }, { id = "close", label = "Cancel" } } })
                    if ok then S.typing = true end
                end)
                btn(d, V(bx + 2 * bw4 + 12, by, 0), V(bx + 3 * bw4 + 12, by + 28, 0), "Update", function()
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
                btn(d, V(bx + 3 * bw4 + 18, by, 0), V(rb.x - 6, by + 28, 0), "Delete", function()
                    if S.delSetAsk == set.file and S.clock - (S.delSetAt or 0) < 3000 then S.delSetAsk = nil; S.deleteSet(set)
                    else S.delSetAsk, S.delSetAt = set.file, S.clock; say("Click Delete again to delete \"" .. set.name .. "\".") end
                end)
                y += rowH
            end
            local pb = b.y - 56
            btn(d, V(x, pb, 0), V(x + w, pb + 34, 0), "Open the sets folder  (to share them)", function() S.openSetsFolder() end)
        end
        -- the last message, along the bottom
        if S.msg ~= "" and S.clock < S.msgUntil and S.ptab ~= 3 and S.ptab ~= 4 then
            local msg = S.msg
            fitText(d, x + 4, b.y - 30, msg, w - 8, { size = 13, colour = UI.dim })
        end
        parkPanel(d)
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
    UI.PAD_ROWS_H = 186
    -- (the room they take at the bottom of the screen, for the controller's prompts above them)
    function UI.padRowsSpace()
        if not (S.sel and S.target) then return 0 end
        return S.hide.rows and 40 or UI.PAD_ROWS_H + 12
    end
    function UI.padRows(d, inMouseView)
        local t = S.sel and S.target
        if not t then S.padRowsAt = nil return end
        local saved = tiles
        tiles = {}
        local W, H = S.size.x, S.size.y
        local bw, gap = 380, 14
        local tw = 2 * bw + 3 * gap
        -- (in the mouse view, centred in the room between the panels)
        local cx = W / 2
        if inMouseView then
            local left, right = S.screen.leftEdge or 0, S.screen.rightEdge or W
            cx = math.max(tw / 2 + 14, (left + right) / 2)
        end
        S.padRowsAt = S.clock
        if S.hide.rows then
            -- (hidden: only a tab at the bottom, to bring them back)
            local ta, tb = V(cx - 40, H - 14 - 26, 0), V(cx + 40, H - 14, 0)
            S.screen.padRows = { a = ta, b = tb }
            arrowTab(d, ta, tb, "up", function() toggleHide("rows") end, true)
            padTiles = tiles
            tiles = saved
            return
        end
        local a = V(math.floor(cx - tw / 2), H - 14 - UI.PAD_ROWS_H, 0)
        local b = V(a.x + tw, H - 14, 0)
        S.screen.padRows = { a = V(a.x, a.y - 24, 0), b = b }
        d:rect(a, b, { colour = UI.bg, fill = true, rounding = 16 })
        arrowTab(d, V(cx - 40, a.y - 24, 0), V(cx + 40, a.y - 2, 0), "down", function() toggleHide("rows") end, true)
        local st = STEPS[S.stepSize] or STEPS[2]
        -- position
        local x, y = a.x + gap, a.y + 12
        y = label(d, x, y, "Position")
        local function setP(px, py, pz) markUndo(); t.pos = V(px, py, pz); S.dirty = true end
        y = stepRow(d, x, y, bw, "X", string.format("%.3f", t.pos.x), function() setP(t.pos.x - st.m, t.pos.y, t.pos.z) end, function() setP(t.pos.x + st.m, t.pos.y, t.pos.z) end,
            function() typeOne("X", t.pos.x, "%.3f", function(v) setP(v, t.pos.y, t.pos.z) end) end) + 4
        y = stepRow(d, x, y, bw, "Height", string.format("%.3f", t.pos.y), function() setP(t.pos.x, FN.heightStep(t.pos.y, t.pos.y - st.m), t.pos.z) end, function() setP(t.pos.x, FN.heightStep(t.pos.y, t.pos.y + st.m), t.pos.z) end,
            function() typeOne("Height", t.pos.y, "%.3f", function(v) FN.markLifted(); setP(t.pos.x, v, t.pos.z) end) end) + 4
        y = stepRow(d, x, y, bw, "Z", string.format("%.3f", t.pos.z), function() setP(t.pos.x, t.pos.y, t.pos.z - st.m) end, function() setP(t.pos.x, t.pos.y, t.pos.z + st.m) end,
            function() typeOne("Z", t.pos.z, "%.3f", function(v) setP(t.pos.x, t.pos.y, v) end) end) + 4
        -- turn, size, tilt
        x, y = a.x + 2 * gap + bw, a.y + 12
        y = label(d, x, y, "Turn, size, tilt")
        local function setH(v) markUndo(); t.heading = wrap(v); S.dirty = true end
        local function setS(v) markUndo(); t.scale = clamp(v, 0.1, 10); S.dirty = true end
        y = stepRow(d, x, y, bw, "Turn", string.format("%.1f°", math.deg(t.heading)), function() setH(t.heading + math.rad(st.deg)) end, function() setH(t.heading - math.rad(st.deg)) end,
            function() typeOne("Turn (degrees)", math.deg(t.heading), "%.1f", function(v) setH(math.rad(v)) end) end) + 4
        y = stepRow(d, x, y, bw, "Size", string.format("%.2f×", t.scale), function() setS(t.scale - st.size) end, function() setS(t.scale + st.size) end,
            function() typeOne("Size", t.scale, "%.2f", setS) end) + 4
        local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
        local function setT(tx, tz) markUndo(); if math.abs(tx) < 1e-6 and math.abs(tz) < 1e-6 then S.tilt[S.sel.id] = nil else S.tilt[S.sel.id] = { x = wrap(tx), z = wrap(tz) } end; S.tiltSaveDue = true end
        local dd = math.rad(st.deg)
        local online = FN.online and FN.online()
        y = stepRow(d, x, y, bw, "Tilt forward", string.format("%.1f°", math.deg(tl.x)), function() setT(tl.x - dd, tl.z) end, function() setT(tl.x + dd, tl.z) end,
            function() typeOne("Tilt forward (degrees)", math.deg(tl.x), "%.1f", function(v) setT(math.rad(v), tl.z) end) end, online) + 4
        y = stepRow(d, x, y, bw, "Tilt sideways", string.format("%.1f°", math.deg(tl.z)), function() setT(tl.x, tl.z - dd) end, function() setT(tl.x, tl.z + dd) end,
            function() typeOne("Tilt sideways (degrees)", math.deg(tl.z), "%.1f", function(v) setT(tl.x, math.rad(v)) end) end, online)
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
        if not (onLeft or onTab or inside(S.screen and S.screen.panelBox)) then return false end
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
        -- the controller, drawn (what each button does first, so the pad sits on top of the lines)
        local half = pw * 0.64
        local cx, cy = a.x + half / 2, a.y + 52 + (ph - 52) * 0.45
        d:text(V(a.x + 24, a.y + 68, 0), "CONTROLLER", { size = 13, colour = "#f0f3f680", font = "bold" })
        -- laid out like an Xbox pad: left stick high, d-pad low; right stick low, A B X Y high
        local ls, rs = V(cx - 140, cy - 35, 0), V(cx + 70, cy + 48, 0)
        local dp, ab = V(cx - 70, cy + 48, 0), V(cx + 140, cy - 38, 0)
        local vw, mn = V(cx - 42, cy - 38, 0), V(cx + 42, cy - 38, 0)
        local BP = { y = V(0, -26, 0), x = V(-26, 0, 0), b = V(26, 0, 0), a = V(0, 26, 0) }
        local lx, rx = cx - 255, cx + 255
        limL, limR = a.x + 16, a.x + half - 14
        callout(d, V(cx - 150, cy - 141, 0), V(lx, cy - 205, 0), "LT   lower", false)
        callout(d, V(cx - 125, cy - 112, 0), V(lx, cy - 150, 0), "LB   turn  ·  clear group", false)
        callout(d, ls, V(lx, cy - 70, 0), "L-stick   move  ·  L3 next snap", false)
        callout(d, vw, V(lx, cy + 5, 0), "View   snap: auto / one / off", false)
        callout(d, dp, V(lx, cy + 80, 0), "D-pad   size  ·  zoom", false)
        callout(d, V(cx + 150, cy - 141, 0), V(rx, cy - 205, 0), "RT   raise", true)
        callout(d, V(cx + 125, cy - 112, 0), V(rx, cy - 160, 0), "RB   turn  ·  add to group", true)
        callout(d, ab + BP.y, V(rx, cy - 115, 0), "Y   remove  ·  ungroup", true)
        callout(d, ab + BP.b, V(rx, cy - 75, 0), "B   cancel  /  close", true)
        callout(d, ab + BP.x, V(rx, cy - 35, 0), "X   copy", true)
        callout(d, ab + BP.a, V(rx, cy + 5, 0), "A   pick up  ·  hold select", true)
        callout(d, mn, V(rx, cy + 45, 0), "Menu   step size", true)
        callout(d, rs, V(rx, cy + 85, 0), "R-stick look · R3 tools, hold: no snap", true)
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
        d:text(V(cx - 153, cy - 162, 0), "LT", { size = 12, colour = LC, font = "bold", align = "centre" })
        d:text(V(cx + 153, cy - 162, 0), "RT", { size = 12, colour = LC, font = "bold", align = "centre" })
        d:text(V(cx - 222, cy - 118, 0), "LB", { size = 12, colour = LC, font = "bold", align = "centre" })
        d:text(V(cx + 222, cy - 118, 0), "RB", { size = 12, colour = LC, font = "bold", align = "centre" })
        for _, st2 in ipairs({ ls, rs }) do
            d:circle(st2, 30, { colour = LC, thickness = 3 })
            d:circle(st2, 20, { colour = LC2, thickness = 2 })
        end
        d:circle(dp, 32, { colour = LC2, thickness = 2 })
        local cr = { -8, -26, 8, -26, 8, -8, 26, -8, 26, 8, 8, 8, 8, 26, -8, 26, -8, 8, -26, 8, -26, -8, -8, -8, -8, -26 }
        for i = 1, #cr - 2, 2 do d:line(dp + V(cr[i], cr[i + 1], 0), dp + V(cr[i + 2], cr[i + 3], 0), { colour = LC, thickness = 3 }) end
        for k, off in pairs(BP) do
            d:circle(ab + off, 12, { colour = UI.BTN[k][2], thickness = 3 })
            d:text(ab + off - V(0, 9, 0), UI.BTN[k][1], { size = 14, colour = UI.BTN[k][2], font = "bold", align = "centre" })
        end
        d:circle(vw, 8, { colour = LC, thickness = 2 }); d:circle(mn, 8, { colour = LC, thickness = 2 })
        d:circle(V(cx, cy - 72, 0), 16, { colour = LC, thickness = 3 })
        d:text(V(cx, b.y - 70, 0), "LB + D-pad right opens  ·  B closes  ·  LB + View undo  ·  RB + View redo", { size = 14, colour = UI.dim, align = "centre" })
        -- the keyboard and mouse
        local kx = a.x + half + 20
        local ky = a.y + 68
        d:line(V(a.x + half, a.y + 70, 0), V(a.x + half, b.y - 40, 0), { colour = UI.line, thickness = 1 })
        d:text(V(kx, ky, 0), "KEYBOARD AND MOUSE", { size = 13, colour = "#f0f3f680", font = "bold" })
        ky += 34
        local rows = {
            { { "W" }, { "E" }, { "R" }, "move / turn / size handles" },
            { { "T" }, "snap to objects on / off" },
            { { "Tab" }, "snap target: auto, one object, off" },
            { { "G" }, "drag in steps" },
            { { "F" }, "look at the picked object" },
            { { "Ctrl" }, { "Z" }, "undo        Ctrl + Y: redo" },
            { { "Shift" }, "bigger steps" },
            { { "Ctrl" }, "hold while dragging: no snapping" },
            { { "Arrows" }, { "PgUp" }, { "PgDn" }, "fly the view" },
            { { "Esc" }, "done" },
        }
        for _, r in ipairs(rows) do
            local x = kx
            for _, part in ipairs(r) do
                if type(part) == "table" then x += keycap(d, x, ky, part[1]) + 6
                else d:text(V(x + 8, ky + 6, 0), part, { size = 15, colour = UI.text }) end
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
        d:text(V(tx + 10, my + 113, 0), "Ctrl + click   group add / remove", { size = 14, colour = UI.text })
        UI.footer(d, a, b, { { "b", "Close" } })
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
                    PE.drawShape(d, worldShape(c.item, c.pos, c.heading, c.scale), UI.purple, 3)
                else
                    d:world_line(c.pos - V(0.4, 0, 0), c.pos + V(0.4, 0, 0), { colour = UI.purple, thickness = 3 })
                    d:world_line(c.pos - V(0, 0, 0.4), c.pos + V(0, 0, 0.4), { colour = UI.purple, thickness = 3 })
                    d:world_line(c.pos, c.pos + V(0, 1, 0), { colour = UI.purple, thickness = 3 })
                end
            end
            for _, gd in ipairs(S.carry.guides or {}) do
                if gd.nb then PE.drawShape(d, gd.nb.shape or gd.nb, "#35e0ff", 3, gd.nb.xf) end
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
            PE.drawShape(d, so.shape or so, "#ffa640", 4, so.xf)
        end
        d:text(center + V(14, 8, 0), "snap: " .. FN.snapLabel(), { size = 16, colour = "#ffa640", shadow = true })
    end
    -- what it is snapped to: that object's box (or its point), and how
    if S.guides then
        local WORDS = { touch = "touching", level = "lined up", turn = "same turn", match = S.snapStyle == "classic" and "same size" or "sides match" }
        local seen = {}
        for _, gd in ipairs(S.guides) do
            local id = gd.o.id
            if not seen[id] then
                seen[id] = true
                local nc = cornersOf(gd.nb)
                if PE.drawShape(d, gd.nb.shape or gd.nb, "#35e0ff", 3, gd.nb.xf) then
                    -- drawn
                elseif #nc == 8 then
                    for _, e in ipairs(BOX_EDGES) do d:world_line(nc[e[1] + 1], nc[e[2] + 1], { colour = "#35e0ff", thickness = 3 }) end
                else
                    local q = gd.nb.p
                    d:world_line(q - V(0.4, 0, 0), q + V(0.4, 0, 0), { colour = "#35e0ff", thickness = 3 })
                    d:world_line(q - V(0, 0, 0.4), q + V(0, 0, 0.4), { colour = "#35e0ff", thickness = 3 })
                    d:world_line(q, q + V(0, 0.8, 0), { colour = "#35e0ff", thickness = 3 })
                end
                local sp = d:world_to_screen(gd.nb.p)
                if sp then d:text(sp + V(10, -12, 0), WORDS[gd.kind] or "snap", { size = 16, colour = "#35e0ff", shadow = true }) end
            end
        end
    end
    -- the object's box where it is going: shows at once while the game catches up
    if S.boxCorners and (S.mode ~= 3 or padMode) then
        local c = S.boxCorners
        local moving = S.dirty or (S.drag and S.drag.moved) or not lastApplied()
        local col = moving and "#ffe066" or "#ffffff66"
        local sh = S.itemBox[S.sel.item] and worldShape(S.sel.item, p, t.heading, t.scale) or nil
        local tl = tilted(S.sel.id) and S.tilt[S.sel.id] or nil
        local xf = tl and function(v) return tiltPoint(p, t.heading, tl, v) end or nil
        if xf then for i = 0, 7 do c[i] = xf(c[i]) end end
        pcall(FN.drawGhost, d, c, sh, p, center, moving, xf)
        if not (sh and PE.drawShape(d, sh, col, 2, xf)) then
            for _, e in ipairs(BOX_EDGES) do
                d:world_line(c[e[1]], c[e[2]], { colour = col, thickness = 2 })
            end
        end
    end
end

reskate.on("draw", function(d)
    if not S.open then return end
    local ok, err = pcall(FN.drawMain, d)
    if not ok and not S.drawWarned then S.drawWarned = true; reskate.log("Quick Drop helper: draw: " .. tostring(err), "warn") end
    if S.ownPanel and not S.picker then
        local okp, errp = pcall(UI.sidePanel, d)
        if not okp and not S.panelWarned then S.panelWarned = true; reskate.log("Quick Drop helper: panel: " .. tostring(errp), "warn") end
        -- the picked object's position, turn, size and tilt along the bottom (the controller's view draws them under
        -- its prompts itself)
        local padView = S.padUsedAt ~= nil and (not S.mouseUsedAt or S.padUsedAt > S.mouseUsedAt) and S.clock - S.padUsedAt < 60000
        if not padView then
            local okr, errr = pcall(UI.padRows, d, true)
            if not okr and not S.rowsWarned then S.rowsWarned = true; reskate.log("Quick Drop helper: rows: " .. tostring(errr), "warn") end
        end
    end
    if S.picker then
        local okk, errk = pcall(FN.drawPicker, d)
        if not okk then reskate.log("Quick Drop helper: add window: " .. tostring(errk), "warn"); S.picker = nil end
    end
    if S.controlsOpen then
        local okc, errc = pcall(UI.controlsWin, d)
        if not okc then reskate.log("Quick Drop helper: controls: " .. tostring(errc), "warn"); S.controlsOpen = false end
    end
end)

reskate.on("load", function() reskate.log("Quick Drop helper ready: drop an object, then F6 (or hold Ctrl and use [ ] PgUp PgDn Z X arrows).") end)

end
