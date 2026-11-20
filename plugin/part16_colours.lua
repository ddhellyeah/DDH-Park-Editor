-- DDH Park Editor: the Appearance window. The player picks the editor's look: a ready-made one, or each of its four
-- colours (panels, fields, borders, the accent) with a colour picker: a square for how strong and how bright, a bar
-- for the hue, a bar for how see-through, the code (#RRGGBB, click to type one), and ready swatches beside it. Text
-- colours follow by themselves (main.lua, UI.applyTheme), so it always reads; a line says when a choice is hard to
-- see. Opened with Appearance in the panel. Mouse: click and drag. Controller: D-pad moves, left / right change a
-- bar, A chooses (on the square: A, then the D-pad moves its mark, A or B again to stop), LB / RB the colour, B closes.
return function(PE)

local FN = PE.FN
local S = PE.S
local UI = PE.UI
local V = PE.V
local clamp = PE.clamp
local say = PE.say
local padPress = PE.padPress
local padStep = PE.padStep
local stick = PE.stick

local SLOTS = {
    { key = "panel", name = "Panels" },
    { key = "field", name = "Fields" },
    { key = "border", name = "Borders" },
    { key = "accent", name = "Accent" },
}
local NPANEL = #SLOTS
-- (then every outline drawn in the world, each its own colour)
for _, o in ipairs(UI.OUTLINES or {}) do SLOTS[#SLOTS + 1] = { key = o.key, name = o.name, outline = true } end
-- 24 ready colours for each
local SWATCH = {
    panel = { "#000000", "#0d0d0d", "#121212", "#1a1a1a", "#222222", "#2a2a2a", "#333333", "#3d3d3d", "#0d1117", "#101a2b", "#0f1f19", "#1f1830",
        "#2a1a14", "#34312d", "#1a1a2e", "#3a2a1a", "#ffffff", "#f2f2f2", "#e6e6e6", "#d9d9d9", "#f4efe6", "#e8f0f8", "#fff7e6", "#eef6ee" },
    field = { "#000000", "#141414", "#1e1e1e", "#252525", "#2d2d2d", "#373737", "#424242", "#4d4d4d", "#161b22", "#17263a", "#173027", "#2d2445",
        "#3b2a20", "#423e39", "#26263f", "#4a3826", "#ffffff", "#f2f2f2", "#e9e9e9", "#dddddd", "#ece5d8", "#dce6f0", "#f5ead0", "#e0ece0" },
    border = { "#000000", "#333333", "#4a4a4a", "#5a5a5a", "#646464", "#7a7a7a", "#8a8a8a", "#9a9a9a", "#b0b0b0", "#cccccc", "#e6e6e6", "#ffffff",
        "#c64c00", "#ffb020", "#e6ff3a", "#a3e635", "#5ef2a0", "#3dd6f5", "#2563eb", "#b69cff", "#ff6fb5", "#ff5a3c", "#5a6a7a", "#7a6a5a" },
    accent = { "#c64c00", "#ff5a3c", "#ff7a5c", "#ffb020", "#ffd34d", "#e6ff3a", "#a3e635", "#5ef2a0", "#2ee6a8", "#3dd6f5", "#4c8dff", "#2563eb",
        "#b69cff", "#c49bff", "#ff6fb5", "#ff3fa4", "#f85149", "#e3b341", "#45c8e4", "#7dffb0", "#f2f2f2", "#ffffff", "#9e9e9e", "#111111" },
}

-- ---- colours: "#rrggbb" or "#rrggbbaa" (aa: how solid); as hue (0..360), colour amount and brightness (0..1)
local function split(h)
    h = tostring(h or ""):gsub("#", "")
    local a = 1
    if #h >= 8 then a = (tonumber(h:sub(7, 8), 16) or 255) / 255 end
    return "#" .. h:sub(1, 6), a
end
local function join(rgbHex, a)
    if a >= 0.995 then return rgbHex end
    return rgbHex .. string.format("%02x", math.floor(clamp(a, 0, 1) * 255 + 0.5))
end
local function toHsv(h)
    local r, g, b = UI.rgb(h)
    r, g, b = r / 255, g / 255, b / 255
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local dd = mx - mn
    local hue = 0
    if dd > 1e-6 then
        if mx == r then hue = 60 * (((g - b) / dd) % 6)
        elseif mx == g then hue = 60 * ((b - r) / dd + 2)
        else hue = 60 * ((r - g) / dd + 4) end
    end
    return hue, mx > 0 and dd / mx or 0, mx
end
local function fromHsv(hue, sat, val)
    hue = hue % 360
    local c = val * sat
    local x = c * (1 - math.abs((hue / 60) % 2 - 1))
    local m = val - c
    local r, g, b
    if hue < 60 then r, g, b = c, x, 0 elseif hue < 120 then r, g, b = x, c, 0 elseif hue < 180 then r, g, b = 0, c, x
    elseif hue < 240 then r, g, b = 0, x, c elseif hue < 300 then r, g, b = x, 0, c else r, g, b = c, 0, x end
    return UI.hex((r + m) * 255, (g + m) * 255, (b + m) * 255)
end

-- ---- choosing
S.colours = nil   -- open: { slot = 1..4, focus = { row, col }, hsv = { h, s, v }, alpha, saveAt, sqEdit, pad }
local function colourOf(key) return UI.theme[key] or UI[key] end
local function cur() return colourOf(SLOTS[S.colours.slot].key) end
local function swatchesFor(key)
    if SWATCH[key] then return SWATCH[key] end
    -- (outlines: bright colours, white and black)
    local t = {}
    for i, c in ipairs(SWATCH.accent) do t[i] = c end
    t[#t] = "#000000"
    return t
end
local function syncHsv()
    local rgbHex, a = split(cur())
    local h, s2, v = toHsv(rgbHex)
    local old = S.colours.hsv
    -- (a grey has no hue, and black no colour amount: keep what they were, so the marks don't jump)
    if old and s2 < 0.01 then h = old[1] end
    if old and v < 0.01 then s2 = old[2] end
    S.colours.hsv = { h, s2, v }
    S.colours.alpha = a
end
local function setSlot(key, col, keepHsv)
    local th = {}
    for k, v in pairs(UI.theme) do th[k] = v end
    th[key] = col
    UI.applyTheme(th)
    S.colours.saveAt = S.clock + 600
    if not keepHsv then syncHsv() end
end
local function setPreset(p, all)
    -- (a ready-made look changes the four panel colours; the outlines stay as chosen, unless all)
    local th = { panel = p.panel, field = p.field, border = p.border, accent = p.accent }
    if not all then for _, o in ipairs(UI.OUTLINES or {}) do th[o.key] = UI.theme[o.key] end end
    UI.applyTheme(th)
    S.colours.saveAt = S.clock
    syncHsv()
    say("Appearance: " .. p.name)
end
local function setFromHsv()
    local c = S.colours
    local hv = c.hsv
    setSlot(SLOTS[c.slot].key, join(fromHsv(hv[1], clamp(hv[2], 0, 1), clamp(hv[3], 0, 1)), c.alpha or 1), true)
end
function FN.openColours()
    S.colours = { slot = 4, focus = { 3, 4 } }
    syncHsv()
    S.controlsOpen = false
end
local function closeColours()
    if S.colours and S.colours.saveAt then UI.saveTheme() end
    S.colours = nil
end
FN.closeColours = closeColours
-- (saved a moment after the last change, so a mark being dragged isn't saved every frame)
function FN.coloursTick()
    local c = S.colours
    if c and c.saveAt and S.clock >= c.saveAt then UI.saveTheme(); c.saveAt = nil end
end
-- typing a colour's code
local HEX_DLG = "ddh_hex"
local function typeHex()
    local c = S.colours
    local ok = pcall(reskate.ui.dialog, HEX_DLG, { title = SLOTS[c.slot].name .. " colour", message = "Its code: #RRGGBB (or #RRGGBBAA to make it see-through).",
        field = { text = string.upper(cur()), max = 12 }, buttons = { { id = "apply", label = "Use it" }, { id = "close", label = "Cancel" } } })
    if ok then S.typing = true end
end
reskate.on("throwdown_ui", function(e)
    if e.action ~= "dialog" or e.args[1] ~= HEX_DLG then return end
    local what = e.args[2]
    if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
    S.typing = false
    if what ~= "cancel" then pcall(reskate.ui.close_dialog, HEX_DLG) end
    if what == "apply" and S.colours then
        local t = tostring(e.args[3] or ""):gsub("%s", ""):gsub("#", "")
        if t:match("^%x%x%x%x%x%x$") or t:match("^%x%x%x%x%x%x%x%x$") then
            setSlot(SLOTS[S.colours.slot].key, "#" .. string.lower(t))
        else
            say("Not a colour code: use 6 letters and numbers, like #C64C00.", true)
        end
    end
end)

-- what can be reached, row by row (for the controller)
local ROWS = { { kind = "preset", from = 1, n = 4 }, { kind = "preset", from = 5, n = 4 }, { kind = "slot", n = #SLOTS },
    { kind = "square", n = 1 }, { kind = "bar", i = 1, n = 1 }, { kind = "bar", i = 4, n = 1 }, { kind = "hex", n = 1 },
    { kind = "swatch", from = 1, n = 6 }, { kind = "swatch", from = 7, n = 6 }, { kind = "swatch", from = 13, n = 6 }, { kind = "swatch", from = 19, n = 6 },
    { kind = "button", n = 3 } }

local function activate(row, col)
    local c = S.colours
    local r = ROWS[row]
    if r.kind == "preset" then local p = UI.PRESETS[r.from + col - 1]; if p then setPreset(p) end
    elseif r.kind == "slot" then c.slot = col; syncHsv()
    elseif r.kind == "square" then c.sqEdit = not c.sqEdit
    elseif r.kind == "hex" then typeHex()
    elseif r.kind == "swatch" then
        local sw = swatchesFor(SLOTS[c.slot].key)[r.from + col - 1]
        if sw then setSlot(SLOTS[c.slot].key, join(sw, c.alpha or 1)) end
    elseif r.kind == "button" then
        if col == 1 then setPreset(UI.PRESETS[1], true) elseif col == 2 then UI.resetSizes(); say("Panel sizes back to how they were") else closeColours() end
    end
end
local function nudgeBar(i, dir)
    local c = S.colours
    if i == 1 then c.hsv[1] = (c.hsv[1] + dir * 6) % 360
    else c.alpha = clamp((c.alpha or 1) + dir * 0.05, 0.2, 1) end
    setFromHsv()
end

-- ---- drawing
local tiles = {}
local function tileAdd(a, b, fn, drag) tiles[#tiles + 1] = { a = a, b = b, fn = fn, drag = drag } end
local function hot(a, b)
    local m = S.mouse and S.mouse.pos
    return m and m.x >= a.x and m.x <= b.x and m.y >= a.y and m.y <= b.y
end
-- the controller's cursor: a ring with a gap round what it is on
local function ring(d, a, b, r)
    d:rect(a - V(4, 4, 0), b + V(4, 4, 0), { colour = UI.text, rounding = (r or 6) + 4, thickness = 2 })
end
local function edge(d, a, b, r) d:rect(a, b, { colour = UI.border, rounding = r or 6, thickness = 1 }) end
local function focused(row, col)
    local f = S.colours.focus
    return S.colours.pad and f[1] == row and f[2] == col
end
local function mark(d, p, r)
    d:circle(p, r + 2, { colour = "#000000", fill = true })
    d:circle(p, r, { colour = "#ffffff", fill = true })
    d:circle(p, r - 3, { colour = fromHsv(S.colours.hsv[1], S.colours.hsv[2], S.colours.hsv[3]), fill = true })
end
local function checker(d, a, b, sq)
    local light = true
    local x = a.x
    while x < b.x do
        local y = a.y
        local l2 = light
        while y < b.y do
            d:rect(V(x, y, 0), V(math.min(x + sq, b.x), math.min(y + sq, b.y), 0), { colour = l2 and "#d9d9d9" or "#9a9a9a", fill = true })
            l2 = not l2
            y += sq
        end
        light = not light
        x += sq
    end
end

function UI.coloursWin(d)
    local c = S.colours
    if not c then return end
    tiles = {}
    local W, H = S.size.x, S.size.y
    local pw, ph = math.min(980, W - 20), math.min(860, H - 20)
    local a = V(math.floor((W - pw) / 2), math.floor((H - ph) / 2), 0)
    local b = a + V(pw, ph, 0)
    S.screen.coloursBox = { a = a, b = b }
    d:rect(V(0, 0, 0), V(W, H, 0), { colour = "#00000080", fill = true })
    UI.panelBox(d, a, b, "Appearance")
    local fit, tin = UI.fitText, UI.textIn
    local x, w = a.x + 20, pw - 40
    local y = a.y + 66
    local function head(str, hx, hw)
        fit(d, hx or x, y, string.upper(str), hw or w, { size = 13, colour = UI.dim, font = "bold" })
    end
    -- ready-made looks
    head("Ready-made"); y += 22
    local pwid = (w - 3 * 8) / 4
    for i, p in ipairs(UI.PRESETS) do
        local row, col = i <= 4 and 1 or 2, (i - 1) % 4 + 1
        local ta = V(x + (col - 1) * (pwid + 8), y + (row - 1) * 42, 0)
        local tb = ta + V(pwid, 34, 0)
        local same = UI.theme.panel == p.panel and UI.theme.field == p.field and UI.theme.border == p.border and UI.theme.accent == p.accent
        d:rect(ta, tb, { colour = hot(ta, tb) and UI.fieldHot or UI.field, fill = true, rounding = 6 })
        if same then d:rect(ta, tb, { colour = UI.accent, rounding = 6, thickness = 2 }) else edge(d, ta, tb, 6) end
        local sa, sb = ta + V(8, 7, 0), ta + V(28, 27, 0)
        d:rect(sa, sb, { colour = p.panel, fill = true, rounding = 4 })
        d:rect(sa, sb, { colour = p.border, rounding = 4, thickness = 1 })
        d:circle(V(sa.x + 10, sa.y + 10, 0), 5, { colour = p.accent, fill = true })
        tin(d, V(ta.x + 32, ta.y, 0), tb, p.name, { size = 14, colour = UI.text, font = same and "bold" or nil }, 4)
        if focused(row, col) then ring(d, ta, tb) end
        tileAdd(ta, tb, function() setPreset(p) end)
    end
    y += 90
    -- the colours, in a list: the panels' four, then the outlines
    local lw0 = 230
    local ly = y
    local function slotRow(i, sl)
        local ta, tb = V(x, ly, 0), V(x + lw0, ly + 27, 0)
        local on = c.slot == i
        d:rect(ta, tb, { colour = on and UI.accent or (hot(ta, tb) and UI.fieldHot or UI.field), fill = true, rounding = 5 })
        if not on then edge(d, ta, tb, 5) end
        local sa, sb = ta + V(6, 5, 0), ta + V(23, 22, 0)
        checker(d, sa, sb, 4)
        d:rect(sa, sb, { colour = colourOf(sl.key), fill = true, rounding = 3 })
        d:rect(sa, sb, { colour = on and UI.onAccent or UI.border, rounding = 3, thickness = 1 })
        tin(d, V(ta.x + 28, ta.y, 0), tb, sl.name, { size = 13, colour = on and UI.onAccent or UI.text, font = on and "bold" or nil }, 4)
        if c.pad and c.focus[1] == 3 and on then ring(d, ta, tb, 5) end
        tileAdd(ta, tb, function() c.slot = i; syncHsv() end)
        ly += 30
    end
    fit(d, x, ly, "PANELS", lw0, { size = 13, colour = UI.dim, font = "bold" }); ly += 20
    for i = 1, NPANEL do slotRow(i, SLOTS[i]) end
    ly += 6
    fit(d, x, ly, "OUTLINES", lw0, { size = 13, colour = UI.dim, font = "bold" }); ly += 20
    for i = NPANEL + 1, #SLOTS do slotRow(i, SLOTS[i]) end
    -- (the picker and the swatches to the right of the list)
    x = x + lw0 + 20
    w = w - lw0 - 20
    -- the picker (left) and the swatches (right)
    local key = SLOTS[c.slot].key
    local hv = c.hsv
    local lw = 330
    local rx = x + lw + 20
    local rw = w - lw - 20
    -- the square: across, how much colour; down, how bright
    local qa, qb = V(x, y, 0), V(x + lw, y + 200, 0)
    local NX, NY = 22, 14
    for i = 0, NX - 1 do
        for j = 0, NY - 1 do
            local sx = (i + 0.5) / NX
            local vy = 1 - (j + 0.5) / NY
            local x0 = qa.x + (qb.x - qa.x) * i / NX
            local y0 = qa.y + (qb.y - qa.y) * j / NY
            local x1 = qa.x + (qb.x - qa.x) * (i + 1) / NX
            local y1 = qa.y + (qb.y - qa.y) * (j + 1) / NY
            d:rect(V(x0, y0, 0), V(x1 + 0.6, y1 + 0.6, 0), { colour = fromHsv(hv[1], sx, vy), fill = true })
        end
    end
    edge(d, qa, qb, 4)
    mark(d, V(qa.x + (qb.x - qa.x) * clamp(hv[2], 0, 1), qa.y + (qb.y - qa.y) * (1 - clamp(hv[3], 0, 1)), 0), 9)
    if focused(4, 1) then ring(d, qa, qb, 4) end
    if c.sqEdit and c.pad then d:rect(qa - V(2, 2, 0), qb + V(2, 2, 0), { colour = UI.accent, rounding = 6, thickness = 3 }) end
    local function fromSquare()
        local m = S.mouse and S.mouse.pos
        if not m then return end
        hv[2] = clamp((m.x - qa.x) / (qb.x - qa.x), 0, 1)
        hv[3] = clamp(1 - (m.y - qa.y) / (qb.y - qa.y), 0, 1)
        setFromHsv()
    end
    tileAdd(qa, qb, fromSquare, fromSquare)
    local py = qb.y + 14
    -- the hue bar
    local ha, hb = V(x, py, 0), V(x + lw, py + 16, 0)
    local NH = 36
    for k = 0, NH - 1 do
        local x0 = ha.x + (hb.x - ha.x) * k / NH
        local x1 = ha.x + (hb.x - ha.x) * (k + 1) / NH
        d:rect(V(x0, ha.y, 0), V(x1 + 0.6, hb.y, 0), { colour = fromHsv((k + 0.5) / NH * 360, 1, 1), fill = true })
    end
    edge(d, ha, hb, 3)
    mark(d, V(ha.x + (hb.x - ha.x) * (hv[1] % 360) / 360, (ha.y + hb.y) / 2, 0), 8)
    if focused(5, 1) then ring(d, ha, hb, 3) end
    local function fromHue()
        local m = S.mouse and S.mouse.pos
        if not m then return end
        hv[1] = clamp((m.x - ha.x) / (hb.x - ha.x), 0, 0.9999) * 360
        setFromHsv()
    end
    tileAdd(V(ha.x, ha.y - 6, 0), V(hb.x, hb.y + 6, 0), fromHue, fromHue)
    py += 30
    -- how solid (see-through to the left)
    local oa, ob = V(x, py, 0), V(x + lw, py + 16, 0)
    checker(d, oa, ob, 8)
    local solid = fromHsv(hv[1], hv[2], hv[3])
    local NO = 24
    for k = 0, NO - 1 do
        local x0 = oa.x + (ob.x - oa.x) * k / NO
        local x1 = oa.x + (ob.x - oa.x) * (k + 1) / NO
        d:rect(V(x0, oa.y, 0), V(x1 + 0.6, ob.y, 0), { colour = join(solid, (k + 0.5) / NO), fill = true })
    end
    edge(d, oa, ob, 3)
    mark(d, V(oa.x + (ob.x - oa.x) * (c.alpha or 1), (oa.y + ob.y) / 2, 0), 8)
    if focused(6, 1) then ring(d, oa, ob, 3) end
    local function fromAlpha()
        local m = S.mouse and S.mouse.pos
        if not m then return end
        c.alpha = clamp((m.x - oa.x) / (ob.x - oa.x), 0.2, 1)
        setFromHsv()
    end
    tileAdd(V(oa.x, oa.y - 6, 0), V(ob.x, ob.y + 6, 0), fromAlpha, fromAlpha)
    py += 30
    -- the code (click to type one) and how solid in %
    local xa, xb = V(x, py, 0), V(x + lw - 76, py + 34, 0)
    d:rect(xa, xb, { colour = hot(xa, xb) and UI.fieldHot or UI.field, fill = true, rounding = 6 })
    edge(d, xa, xb, 6)
    local ca, cb = xa + V(8, 8, 0), xa + V(26, 26, 0)
    checker(d, ca, cb, 5)
    d:rect(ca, cb, { colour = colourOf(key), fill = true, rounding = 3 })
    tin(d, V(xa.x + 32, xa.y, 0), xb, string.upper(split(colourOf(key))), { size = 15, colour = UI.text }, 4)
    if focused(7, 1) then ring(d, xa, xb) end
    tileAdd(xa, xb, typeHex)
    local pa, pb = V(xb.x + 8, py, 0), V(x + lw, py + 34, 0)
    d:rect(pa, pb, { colour = UI.field, fill = true, rounding = 6 })
    edge(d, pa, pb, 6)
    tin(d, pa, pb, string.format("%d%%", math.floor((c.alpha or 1) * 100 + 0.5)), { size = 15, colour = UI.text, align = "centre" }, 4)
    -- the swatches, 6 across
    head("Swatches", rx, rw)
    local cw = (rw - 5 * 6) / 6
    local list = swatchesFor(key)
    for i, col in ipairs(list) do
        local row, k = math.floor((i - 1) / 6) + 1, (i - 1) % 6 + 1
        local ta = V(rx + (k - 1) * (cw + 6), y + 22 + (row - 1) * (cw + 6), 0)
        local tb = ta + V(cw, cw, 0)
        d:rect(ta, tb, { colour = col, fill = true, rounding = 5 })
        local chosen = split(colourOf(key)) == col
        d:rect(ta, tb, { colour = chosen and UI.text or UI.border, rounding = 5, thickness = chosen and 3 or 1 })
        if hot(ta, tb) then d:rect(ta - V(2, 2, 0), tb + V(2, 2, 0), { colour = UI.text, rounding = 6, thickness = 1 }) end
        if focused(7 + row, k) then ring(d, ta, tb, 5) end
        tileAdd(ta, tb, function() setSlot(key, join(col, c.alpha or 1)) end)
    end
    y = py + 48
    -- whether it all reads
    local warn = {}
    if UI.contrast(UI.border, UI.panel) < 3 then warn[#warn + 1] = "borders are hard to see on the panels" end
    if UI.contrast(UI.accent, UI.panel) < 3 then warn[#warn + 1] = "the accent is hard to see on the panels" end
    for i = 1, NPANEL do local sl = SLOTS[i]; if select(2, split(colourOf(sl.key))) < 0.995 then warn[#warn + 1] = "see-through colours can be hard to read over the park"; break end end
    local msg = #warn == 0 and "Text and edges all read well." or ("Careful: " .. table.concat(warn, ", ") .. ".")
    fit(d, x, y, msg, w, { size = 13, colour = #warn == 0 and UI.dim or UI.orange })
    fit(d, x, y + 20, "Panels: drag a title to move, a bottom corner to resize.", w, { size = 13, colour = UI.dim })
    -- the buttons
    x, w = a.x + 20 + 250, pw - 40 - 250
    local by = b.y - 92
    local bw = (w - 16) / 3
    local btns = { { "Back to default", function() setPreset(UI.PRESETS[1], true) end }, { "Reset panel sizes", function() UI.resetSizes(); say("Panel sizes back to how they were") end },
        { "Done", function() closeColours() end, true } }
    for i, bt in ipairs(btns) do
        local ta = V(x + (i - 1) * (bw + 8), by, 0)
        local tb = ta + V(bw, 36, 0)
        local prim = bt[3]
        d:rect(ta, tb, { colour = prim and (hot(ta, tb) and UI.accentHot or UI.accent) or (hot(ta, tb) and UI.fieldHot or UI.field), fill = true, rounding = 6 })
        if not prim then edge(d, ta, tb, 6) end
        tin(d, ta, tb, bt[1], { size = 14, colour = prim and UI.onAccent or UI.text, font = prim and "bold" or nil, align = "centre" }, 6)
        if focused(12, i) then ring(d, ta, tb) end
        tileAdd(ta, tb, bt[2])
    end
    UI.footer(d, a, b, c.sqEdit and { { "D-pad", "Move the mark" }, { "a", "Done" } } or { { "D-pad", "Move" }, { "a", "Choose" }, { "LB RB", "Colour" }, { "b", "Close" } })
end

-- ---- the mouse: true while the window is open (it takes the mouse)
function UI.coloursMouse(cm)
    local c = S.colours
    if not c then return false end
    local px = cm.position
    if cm.left and not S.mouse.left then
        c.pad = false
        local box = S.screen.coloursBox
        if box and not (px.x >= box.a.x and px.x <= box.b.x and px.y >= box.a.y and px.y <= box.b.y) then closeColours() return true end
        for i = #tiles, 1, -1 do
            local tt = tiles[i]
            if px.x >= tt.a.x and px.x <= tt.b.x and px.y >= tt.a.y and px.y <= tt.b.y then
                if reskate.audio and reskate.audio.play_ui then pcall(reskate.audio.play_ui, "select") end
                tt.fn()
                c.dragFn = tt.drag
                break
            end
        end
    elseif cm.left and c.dragFn then
        c.dragFn()
    elseif not cm.left then
        c.dragFn = nil
    end
    return true
end

-- ---- the controller
function FN.coloursPad(p)
    local c = S.colours
    if not c then return end
    c.pad = true
    local lx, ly = stick(p.lx, p.ly)
    local up, dn = padStep("cu", p.up or ly > 0.5), padStep("cd", p.down or ly < -0.5)
    local left, right = padStep("cl", p.left or lx < -0.5), padStep("cr", p.right or lx > 0.5)
    if c.sqEdit then
        -- moving the square's mark
        if padPress("a", p.a) or padPress("b", p.b) then c.sqEdit = false return end
        local hv = c.hsv
        if left then hv[2] = clamp(hv[2] - 0.05, 0, 1) end
        if right then hv[2] = clamp(hv[2] + 0.05, 0, 1) end
        if up then hv[3] = clamp(hv[3] + 0.05, 0, 1) end
        if dn then hv[3] = clamp(hv[3] - 0.05, 0, 1) end
        if left or right or up or dn then setFromHsv() end
        return
    end
    if padPress("b", p.b) then closeColours() return end
    if padPress("lb", p.lb) then c.slot = (c.slot - 2) % #SLOTS + 1; syncHsv() end
    if padPress("rb", p.rb) then c.slot = c.slot % #SLOTS + 1; syncHsv() end
    local f = c.focus
    if up then f[1] = math.max(1, f[1] - 1); f[2] = math.min(f[2], ROWS[f[1]].n) end
    if dn then f[1] = math.min(#ROWS, f[1] + 1); f[2] = math.min(f[2], ROWS[f[1]].n) end
    local r = ROWS[f[1]]
    if r.kind == "bar" then
        if left then nudgeBar(r.i, -1) end
        if right then nudgeBar(r.i, 1) end
    elseif r.kind == "slot" then
        if left then c.slot = math.max(1, c.slot - 1); syncHsv() end
        if right then c.slot = math.min(#SLOTS, c.slot + 1); syncHsv() end
        f[2] = c.slot
    else
        if left then f[2] = math.max(1, f[2] - 1) end
        if right then f[2] = math.min(r.n, f[2] + 1) end
    end
    if padPress("a", p.a) then activate(f[1], f[2]) end
end

end
