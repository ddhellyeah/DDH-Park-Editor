-- DDH Park Editor, part09_addwindow: the add window, replace, park at a glance, stacked duplicates.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local S = PE.S
local UI = PE.UI
local V = PE.V
local camBasis = PE.camBasis
local clamp = PE.clamp
local endHoldMove = PE.endHoldMove
local groupCount = PE.groupCount
local itemsOf = PE.itemsOf
local len = PE.len
local localOutline = PE.localOutline
local padPress = PE.padPress
local padStep = PE.padStep
local pushUndo = PE.pushUndo
local queuePlace = PE.queuePlace
local queueRemove = PE.queueRemove
local say = PE.say
local send = PE.send
local stick = PE.stick
local wrap = PE.wrap

-- ---------------------------------------------------------------- the add window (A with nothing under the cross)
-- A grid of every Quick Drop object, with pictures of the Object Maker's ones (thumbs.lua: sheets of 4 x 4 in
-- plugin/thumbs), by category. A places the chosen one where the cross is and hands it over to be moved.
local THUMBS = {}
do
    local ok, t = pcall(function() return require("thumbs") end)
    if ok and type(t) == "table" then THUMBS = t end
    -- pictures saved by DDH Get Thumbnails (the game's own objects and the rest): sheets of 6 x 6 at 85 px
    local ok2, g = pcall(function() return require("gthumbs") end)
    if ok2 and type(g) == "table" then
        local n = 0
        for k, v in pairs(g) do
            if not THUMBS[k] then THUMBS[k] = { v[1], v[2], v[3], g = true }; n += 1 end
        end
        reskate.log(string.format("Quick Drop helper: %d more pictures from DDH Get Thumbnails.", n))
    end
end
-- a picture's sheet and its corner and size on it
function UI.thumbOf(key)
    local th = THUMBS[key]
    if not th then return nil end
    if th.g then
        local k = 85 / 512
        return string.format("plugin/thumbs/g%02d.png", th[1]), th[2] * k, th[3] * k, k
    end
    return string.format("plugin/thumbs/sheet%02d.png", th[1]), th[2] / 4, th[3] / 4, 0.25
end
local PICK_COLS, PICK_ROWS = 6, 3
function FN.pickerTabs()
    local cat = FN.catalog()
    local tabs, byName = {}, {}
    local mine = { name = "DDH", items = {} }
    for _, it in ipairs(cat) do
        if string.find(string.lower(it.key), "bkddh", 1, true) then table.insert(mine.items, it) end
    end
    if #mine.items > 0 then tabs[1] = mine end
    if S.loadSets then
        local sets = S.loadSets()
        if #sets > 0 then
            local st = { name = "Sets", items = {} }
            for _, set in ipairs(sets) do st.items[#st.items + 1] = { key = "set:" .. set.file, title = set.name, set = set } end
            tabs[#tabs + 1] = st
        end
    end
    for _, it in ipairs(cat) do
        local c = tostring(it.category or "Other")
        if not byName[c] then byName[c] = { name = c, items = {} }; tabs[#tabs + 1] = byName[c] end
        table.insert(byName[c].items, it)
    end
    for _, t in ipairs(tabs) do
        table.sort(t.items, function(a, b) return tostring(a.title or a.key) < tostring(b.title or b.key) end)
    end
    return tabs
end
function FN.openPicker()
    local tabs = FN.pickerTabs()
    if not S.loggedPics then
        S.loggedPics = true
        local none, ddh = 0, {}
        for _, t in ipairs(tabs) do
            if t.name ~= "DDH" then
                for _, it in ipairs(t.items) do
                    if not THUMBS[it.key] then
                        none += 1
                        if string.find(string.lower(it.key), "bkddh", 1, true) then table.insert(ddh, it.key) end
                    end
                end
            end
        end
        reskate.log(string.format("Quick Drop helper: add window: %d objects have no picture (%d of them DDH)%s", none, #ddh, #ddh > 0 and (": " .. table.concat(ddh, ", ")) or ""))
    end
    if #tabs == 0 then say("The game lists no objects to add.", true) return end
    S.picker = { tabs = tabs, tab = 1, sel = 1, top = 0 }
    S.padWait = true
end
local function closePicker() S.picker = nil; S.padWait = true end
S.openPicker = FN.openPicker
-- where the cross is: the ground (or anything) it points at, else in front of the view
function FN.crossPoint()
    local cpos, f = camBasis()
    local ok, hit = pcall(reskate.world.pick, cpos, cpos + f * 200)
    if ok and type(hit) == "table" and hit.position and len(hit.position - (cpos + f * 200)) > 0.5 then return hit.position end
    return S.cam.target
end
-- ---------------------------------------------------------------- the park at a glance, and stacked duplicates
-- duplicates: the same object in the same place, turn and size as another (easy to make by copying twice);
-- the first one stays
function FN.parkStats()
    if S.stats and S.stats.known == S.known and S.clock - S.stats.at < 700 then return S.stats end
    local st = { at = S.clock, known = S.known, n = 0, kinds = 0, top = nil, topN = 0, dups = {} }
    local by, cells = {}, {}
    local ids = {}
    for id in pairs(S.known or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local o = S.known[id]
        st.n += 1
        if not by[o.item] then by[o.item] = 0; st.kinds += 1 end
        by[o.item] += 1
        if by[o.item] > st.topN then st.top, st.topN = o.item, by[o.item] end
        local p = o.position
        local key = string.format("%s|%d|%d|%d", o.item, math.floor(p.x * 20 + 0.5), math.floor(p.y * 20 + 0.5), math.floor(p.z * 20 + 0.5))
        local first = cells[key]
        if first then
            local dh = math.abs(wrap((first.heading or 0) - (o.heading or 0)))
            if len(first.position - p) < 0.02 and dh < math.rad(1) and math.abs((first.scale or 1) - (o.scale or 1)) < 0.01 then
                st.dups[#st.dups + 1] = id
            end
        else
            cells[key] = o
        end
    end
    S.stats = st
    return st
end
function FN.removeDuplicates()
    S.stats = nil
    local st = FN.parkStats()
    if #st.dups == 0 then say("No stacked duplicates in this park.") return end
    local rec = S.removeUndoable(st.dups, "Duplicates removed")
    S.stats = nil
    say(string.format("Removing %d stacked duplicate%s... (undo puts them back)", rec.total, rec.total == 1 and "" or "s"))
end

-- replace: what would be replaced (the group, else the picked object)
function FN.replaceTargets()
    local ids = {}
    local ng = groupCount()
    if ng > 0 and (not S.sel or S.group[S.sel.id] or ng >= 2) then
        for id in pairs(S.group) do if S.known and S.known[id] then ids[#ids + 1] = id end end
    elseif S.sel and S.known and S.known[S.sel.id] then
        ids[1] = S.sel.id
    end
    table.sort(ids)
    return ids
end
-- swap them for another object: same place, turn, size and tilt; one undo swaps them back
function FN.replaceWith(key, title)
    local ids = FN.replaceTargets()
    if #ids == 0 then say("Pick an object (or make a group) first, then replace it.", true) return false end
    send()
    if S.grab then S.grab = nil; endHoldMove() end
    local old = itemsOf(ids)
    local new = {}
    for i, c in ipairs(old) do new[i] = { item = key, pos = c.pos, heading = c.heading, scale = c.scale, tilt = c.tilt } end
    local rec = queuePlace(new, "Replaced")
    rec.quiet = false
    rec.onAll = function(r)
        if #r.ids > 1 then S.group = {}; for _, id in ipairs(r.ids) do S.group[id] = true end; S.gbase = nil end
    end
    queueRemove(ids, "Replaced")
    pushUndo({ kind = "swap", rec = rec, items = old })
    say(string.format("Replacing %d with %s...  (undo swaps back)", #ids, tostring(title or key)))
    return true
end
function FN.openReplace()
    if #FN.replaceTargets() == 0 then say("Pick an object (or make a group) first, then replace it.", true) return end
    FN.openPicker()
    if S.picker then S.picker.replace = true end
end
S.openReplace = FN.openReplace
function FN.pickerPlace(asReplace)
    local pk = S.picker
    local tab = pk and pk.tabs[pk.tab]
    local it = tab and tab.items[pk.sel]
    if not it then return end
    if (asReplace or pk.replace) and it.set then say("A set can't replace an object: choose an object.", true) return end
    if (asReplace or pk.replace) and not it.set then
        closePicker()
        FN.replaceWith(it.key, it.title)
        return
    end
    local at = FN.crossPoint()
    if it.set then
        closePicker()
        S.carrySet(it.set, at, wrap(S.cam.yaw + math.pi))
        return
    end
    -- facing the view, as Quick Drop does
    S.copyQ = { item = it.key, pos = at, heading = wrap(S.cam.yaw + math.pi), scale = 1, until_ = S.clock + 3000, grab = true }
    closePicker()
    say("Adding " .. tostring(it.title or it.key) .. "...")
end
local function pickerMove(dc, dr)
    local pk = S.picker
    local n = #pk.tabs[pk.tab].items
    if n == 0 then return end
    local i = pk.sel - 1 + dc + dr * PICK_COLS
    i = clamp(i, 0, n - 1)
    pk.sel = i + 1
    local row = math.floor(i / PICK_COLS)
    if row < pk.top then pk.top = row end
    if row >= pk.top + PICK_ROWS then pk.top = row - PICK_ROWS + 1 end
end
function FN.pickerTab(d)
    local pk = S.picker
    pk.tab = (pk.tab - 1 + d) % #pk.tabs + 1
    pk.sel, pk.top = 1, 0
end
-- the controller in the window
function FN.pickerPad(p)
    if padPress("b", p.b) then closePicker() return end
    if padPress("a", p.a) then FN.pickerPlace() return end
    if padPress("y", p.y) then
        if #FN.replaceTargets() > 0 then FN.pickerPlace(true) else say("Select objects first (hold A over them), then Y here replaces them.", true) end
        return
    end
    if padPress("lb", p.lb) then FN.pickerTab(-1) end
    if padPress("rb", p.rb) then FN.pickerTab(1) end
    local lx, ly = stick(p.lx, p.ly)
    if padStep("pl", p.left or lx < -0.5) then pickerMove(-1, 0) end
    if padStep("pr", p.right or lx > 0.5) then pickerMove(1, 0) end
    if padStep("pu", p.up or ly > 0.5) then pickerMove(0, -1) end
    if padStep("pd", p.down or ly < -0.5) then pickerMove(0, 1) end
end
-- the mouse in the window: click a picture to add it, scroll the wheel, click outside to close
function FN.pickerMouse(c)
    local pk = S.picker
    local px = c.position
    if c.wheel and c.wheel ~= 0 then
        local n = #pk.tabs[pk.tab].items
        local rows = math.ceil(n / PICK_COLS)
        pk.top = clamp(pk.top - c.wheel, 0, math.max(0, rows - PICK_ROWS))
    end
    local hov = nil
    for _, t in ipairs((S.screen and S.screen.pickTiles) or {}) do
        if px.x >= t.a.x and px.x <= t.b.x and px.y >= t.a.y and px.y <= t.b.y then hov = t end
    end
    pk.hover = hov and hov.i or nil
    if c.left and not S.mouse.left then
        if hov then
            if hov.tab then FN.pickerTab(hov.tab - pk.tab) else pk.sel = hov.i; FN.pickerPlace() end
        else
            local box = S.screen and S.screen.pickBox
            if box and not (px.x >= box.a.x and px.x <= box.b.x and px.y >= box.a.y and px.y <= box.b.y) then closePicker() end
        end
    end
end
-- an object with no picture but a known shape: its outline seen from above, filling the tile
function UI.drawFootprint(d, item, a, b)
    S.footDrawn = false
    local pts = localOutline(item)
    if not pts or #pts < 3 then return end
    local lo, hi = V(math.huge, 0, math.huge), V(-math.huge, 0, -math.huge)
    for _, q in ipairs(pts) do lo = V(math.min(lo.x, q.x), 0, math.min(lo.z, q.z)); hi = V(math.max(hi.x, q.x), 0, math.max(hi.z, q.z)) end
    local w, h = math.max(hi.x - lo.x, 1e-3), math.max(hi.z - lo.z, 1e-3)
    local k = math.min((b.x - a.x) / w, (b.y - a.y) / h)
    local ox, oy = (a.x + b.x) / 2, (a.y + b.y) / 2
    local sp = {}
    for i, q in ipairs(pts) do sp[i] = V(ox + (q.x - (lo.x + hi.x) / 2) * k, oy - (q.z - (lo.z + hi.z) / 2) * k, 0) end
    for i = 1, #sp do d:line(sp[i], sp[i % #sp + 1], { colour = "#9fd8ff", thickness = 2 }) end
    S.footDrawn = true
end
function FN.shortTitle(t, n) t = tostring(t); if #t > n then return string.sub(t, 1, n - 1) .. "…" end return t end
-- drawing it
function FN.drawPicker(d)
    local pk = S.picker
    if not pk then return end
    local W, H = S.size.x, S.size.y
    local tile, gap = 148, 16
    local pw = PICK_COLS * tile + (PICK_COLS - 1) * gap + 48
    local ph = 52 + 58 + PICK_ROWS * (tile + 34) + 60
    local a = V(math.floor((W - pw) / 2), math.floor((H - ph) / 2), 0)
    local b = a + V(pw, ph, 0)
    S.screen.pickBox = { a = a, b = b }
    S.screen.pickTiles = {}
    d:rect(V(0, 0, 0), V(W, H, 0), { colour = "#00000066", fill = true })
    local nRep = #FN.replaceTargets()
    UI.panelBox(d, a, b, pk.replace and string.format("Replace %d with…", nRep) or "Add object")
    local items = pk.tabs[pk.tab].items
    local rows = math.ceil(#items / PICK_COLS)
    d:text(V(b.x - 20, a.y + 17, 0), string.format("%d objects", #items), { size = 15, colour = UI.dim, align = "right" })
    -- the categories: pills, the chosen one in the accent colour
    local x = a.x + 20
    for i, t in ipairs(pk.tabs) do
        local label = string.format("%s  %d", FN.shortTitle(t.name, 18), #t.items)
        local w = UI.textW(d, label, 15) + 26
        if x + w > b.x - 20 then break end
        local ta, tb = V(x, a.y + 66, 0), V(x + w, a.y + 96, 0)
        local on = i == pk.tab
        d:rect(ta, tb, { colour = on and UI.accent or UI.tile, fill = true, rounding = 15 })
        d:text(ta + V(13, 6, 0), label, { size = 15, colour = on and "#0d1117" or UI.text, font = on and "bold" or nil })
        table.insert(S.screen.pickTiles, { a = ta, b = tb, tab = i })
        x = x + w + 8
    end
    -- the pictures
    local top = a.y + 52 + 58
    for r = 0, PICK_ROWS - 1 do
        for cI = 0, PICK_COLS - 1 do
            local i = (pk.top + r) * PICK_COLS + cI + 1
            local it = items[i]
            if it then
                local ta = V(a.x + 24 + cI * (tile + gap), top + r * (tile + 34), 0)
                local tb = ta + V(tile, tile, 0)
                local selected, hovered = i == pk.sel, i == pk.hover
                d:rect(ta, tb, { colour = selected and UI.accentDim or (hovered and UI.tileHot or UI.tile), fill = true, rounding = 10 })
                local path, u0, v0, k = UI.thumbOf(it.key)
                if it.set then
                    pcall(UI.drawSetPreview, d, it.set, ta + V(16, 16, 0), tb - V(16, 30, 0), UI.purple)
                    d:text(V((ta.x + tb.x) / 2, tb.y - 24, 0), string.format("%d objects", #it.set.objects), { size = 13, colour = UI.dim, align = "centre" })
                elseif path then
                    d:image(path, ta + V(8, 8, 0), tb - V(8, 8, 0), { uv = { u0, v0, u0 + k, v0 + k } })
                elseif not pcall(UI.drawFootprint, d, it.key, ta + V(22, 22, 0), tb - V(22, 22, 0)) or not S.footDrawn then
                    -- no picture and no known shape: its initials, big
                    local name = tostring(it.title or it.key)
                    local ini = string.upper(string.sub(name, 1, 1)) .. (string.match(name, "%s(%w)") or "")
                    d:text(V((ta.x + tb.x) / 2, ta.y + tile / 2 - 22, 0), ini, { size = 40, colour = "#ffffff40", font = "title", align = "centre" })
                end
                if selected then d:rect(ta, tb, { colour = UI.accent, rounding = 10, thickness = 3 }) end
                d:text(V((ta.x + tb.x) / 2, tb.y + 7, 0), FN.shortTitle(it.title or it.key, 19), { size = 14, colour = selected and UI.accent or UI.dim, align = "centre" })
                table.insert(S.screen.pickTiles, { a = ta, b = tb, i = i })
            end
        end
    end
    -- where in the list: a slim bar on the right
    if rows > PICK_ROWS then
        local y0, y1 = top, top + PICK_ROWS * (tile + 34) - 34
        local x0 = b.x - 12
        d:rect(V(x0, y0, 0), V(x0 + 4, y1, 0), { colour = UI.tile, fill = true, rounding = 2 })
        local f0, f1 = pk.top / rows, math.min(1, (pk.top + PICK_ROWS) / rows)
        d:rect(V(x0, y0 + (y1 - y0) * f0, 0), V(x0 + 4, y0 + (y1 - y0) * f1, 0), { colour = UI.accent, fill = true, rounding = 2 })
    end
    if pk.replace then
        UI.footer(d, a, b, { { "a", "Replace" }, { "b", "Close" }, { "LB RB", "Category" }, { "D-pad", "Choose" } })
    elseif nRep > 0 then
        UI.footer(d, a, b, { { "a", "Add" }, { "y", string.format("Replace %d", nRep) }, { "b", "Close" }, { "LB RB", "Category" }, { "D-pad", "Choose" } })
    else
        UI.footer(d, a, b, { { "a", "Add" }, { "b", "Close" }, { "LB RB", "Category" }, { "D-pad", "Choose" } })
    end
end

end
