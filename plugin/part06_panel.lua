-- DDH Park Editor, part06_panel: the panel (ReSkate 2.1.4 widgets).
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local PLANES = PE.PLANES
local S = PE.S
local TITLE = PE.TITLE
local V = PE.V
local clamp = PE.clamp
local closeEditor = PE.closeEditor
local d2 = PE.d2
local findMissing = PE.findMissing
local groupCount = PE.groupCount
local inPoly = PE.inPoly
local len = PE.len
local markUndo = PE.markUndo
local round = PE.round
local saveLook = PE.saveLook
local say = PE.say
local segDist = PE.segDist
local select = PE.select
local send = PE.send
local tilted = PE.tilted
local titleOf = PE.titleOf
local undo = PE.undo
local wrap = PE.wrap

-- ---------------------------------------------------------------- the new panel (ReSkate 2.1.4 widgets)
-- step sizes for the steppers: metres, degrees, size
-- (speed: how fast the controller slides a held object, m/s; fly: how fast the free view flies, times)
function FN.snapLabelP()
    local sp = S.snapPick
    if sp == nil then return "auto (nearest)" end
    if sp == "off" then return "off" end
    local o = S.known and S.known[sp]
    return o and titleOf(o.item) or "auto (nearest)"
end
FN.GRID_NAMES_P = { "Off", "0.25 m", "0.5 m", "1 m", "2 m" }
local STEPS = {
    { m = 0.01, deg = 1, size = 0.01, speed = 0.4, fly = 0.3, name = "Fine", mf = "%.2f m", df = "%.0f°", sf = "%.2f×" },
    { m = 0.1, deg = 15, size = 0.1, speed = 2.5, fly = 1.0, name = "Normal", mf = "%.2f m", df = "%.0f°", sf = "%.2f×" },
    { m = 1, deg = 45, size = 0.5, speed = 6.0, fly = 2.5, name = "Big", mf = "%.1f m", df = "%.0f°", sf = "%.1f×" },
}
S.stepSize = 2
S.sec = { move = true, handles = false, objects = true, locked = true, help = false }
S.search, S.listFilter = "", 1
S.listAt, S.listKey = -1e9, nil
S.listObjs, S.listItems, S.listTotal = {}, {}, 0

function FN.section(ui, id, title, sub)
    local o = ui:section(id, title, sub, S.sec[id])
    if o ~= nil then S.sec[id] = o end
    return S.sec[id]
end

-- a number box: click it and type. What is typed is used once you stop typing for a moment.
-- "12.5" sets it, "+2" adds 2, "+-0.5" takes 0.5 off; a comma works as the decimal point too.
function FN.parseNum(text, cur)
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
        local v = FN.parseNum(e.text, val)
        if v then apply(v) else say(label .. ": \"" .. e.text .. "\" is not a number", true) end
    end
end

-- the list of park objects: rebuilt twice a second, or at once when the search or filter changes
function FN.rebuildList()
    local key = S.search .. "|" .. S.listFilter .. "|" .. tostring(S.sel and S.sel.id)
    if key == S.listKey and S.clock - S.listAt < 500 then return end
    S.listKey, S.listAt = key, S.clock
    local have = FN.catalogHave()
    local q = string.lower(S.search or "")
    local from = S.cam.target or V(0, 0, 0)
    local rows = {}
    -- (the objects as last read from the game, twice a second: not asked for again here)
    local all
    if S.known then
        all = {}
        for _, o in pairs(S.known) do all[#all + 1] = o end
    else
        all = FN.objectsNow()
    end
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
    -- (every match goes in the list, so its groups are whole; the game's own list shows the first 200)
    for i, r in ipairs(rows) do
        S.listObjs[i] = r.o
    end
    for i, r in ipairs(rows) do
        if i > 200 then break end
        local label = string.format("%s%s  |  %.0f m", r.title, r.missing and " (missing)" or "", r.dist)
        if #label > 80 then label = string.sub(label, 1, 77) .. "..." end
        S.listItems[i] = label
    end
end

FN.PANEL_TABS = { "Object", "Snapping", "Park", "Help" }
function FN.newPanel(ui)
    local t = S.sel and S.target
    local ng = groupCount()
    -- what is picked
    if t then
        local sub = string.format("%.0f°   ·   size %.2f", math.deg(t.heading), t.scale)
        if S.group[S.sel.id] and ng > 1 then sub = sub .. string.format("   ·   group of %d", ng) end
        ui:card(titleOf(S.sel.item), sub)
    elseif ng > 0 then
        ui:card(string.format("Group of %d", ng), "Pick one of them up to move them all")
    else
        ui:card("Nothing picked", "Click an object (or aim the cross and press A)")
    end
    -- the park is locked: say so first
    local miss = S.missing or {}
    if S.blocked or #miss > 0 then ui:warn(string.format("Park locked: %d object(s) from a missing mod. See Park.", #miss)) end
    if S.msg ~= "" and S.clock < S.msgUntil then ui:note(S.msg) end
    local b = ui:buttons("top", { "Add object", "Undo", "Done" }, 0)
    if b == 1 and S.openPicker then S.openPicker() end
    if b == 2 then undo() end
    if b == 3 then closeEditor() return end

    S.ptab = S.ptab or 1
    local tb = ui:buttons("ptabs", FN.PANEL_TABS, S.ptab)
    if tb and FN.PANEL_TABS[tb] then S.ptab = tb end
    local st = STEPS[S.stepSize]

    if S.ptab == 1 then
        -- ---------------------------------------------------------------- the picked object
        if not t then
            ui:note("Nothing picked yet.")
        else
            local modes = { "Move", "Turn", "Size" }
            local m = ui:buttons("mode", modes, S.mode)
            if m and m ~= S.mode then S.mode = m end
            ui:heading("Position")
            numBox(ui, "px", "X", t.pos.x, "%.3f", function(v) markUndo(); t.pos = V(v, t.pos.y, t.pos.z); S.dirty = true end)
            numBox(ui, "py", "Y (height)", t.pos.y, "%.3f", function(v) markUndo(); FN.markLifted(); t.pos = V(t.pos.x, v, t.pos.z); S.dirty = true end)
            numBox(ui, "pz", "Z", t.pos.z, "%.3f", function(v) markUndo(); t.pos = V(t.pos.x, t.pos.y, v); S.dirty = true end)
            ui:heading("Turn and size")
            numBox(ui, "ry", "Turn °", math.deg(t.heading), "%.1f", function(v) markUndo(); t.heading = wrap(math.rad(v)); S.dirty = true end)
            numBox(ui, "sz", "Size", t.scale, "%.2f", function(v) markUndo(); t.scale = clamp(v, 0.1, 10); S.dirty = true end)
            local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
            numBox(ui, "tx", "Tilt forward °", math.deg(tl.x), "%.1f", function(v) markUndo(); S.tilt[S.sel.id] = { x = wrap(math.rad(v)), z = tl.z }; S.tiltSaveDue = true end)
            numBox(ui, "tz", "Tilt sideways °", math.deg(tl.z), "%.1f", function(v) markUndo(); S.tilt[S.sel.id] = { x = tl.x, z = wrap(math.rad(v)) }; S.tiltSaveDue = true end)
            if tilted(S.sel.id) and S.tiltWhy and not S.tiltHeld[S.sel.id] then ui:note("Tilt waits: " .. S.tiltWhy) end
            local q = ui:buttons("quick", { "Straighten", "Size 1", "Look at it" }, 0)
            if q == 1 then markUndo(); t.heading = round(t.heading, math.pi / 2); if S.tilt[S.sel.id] then S.tilt[S.sel.id] = nil; S.tiltSaveDue = true end; S.dirty = true; S.edit = {} end
            if q == 2 then markUndo(); t.scale = 1; S.dirty = true; S.edit = {} end
            if q == 3 then S.cam.goal = t.pos end
        end
        ui:heading("Step size")
        local ss = ui:buttons("stepsize", { "Fine", "Normal", "Big" }, S.stepSize)
        if ss and STEPS[ss] then S.stepSize = ss; st = STEPS[ss] end
        ui:note(string.format("%s: %s, %s, size %s", st.name, string.format(st.mf, st.m), string.format(st.df, st.deg), string.format(st.sf, st.size)))
    elseif S.ptab == 2 then
        -- ---------------------------------------------------------------- snapping
        local ob = ui:toggle("osnap", "Snap to objects  (T)", S.osnap)
        if ob ~= nil then S.osnap = ob end
        if S.osnap then
            ui:info("Snapping to", FN.snapLabelP())
            local sb = ui:buttons("snappick", { "Auto", "Next object", "Off" }, S.snapPick == nil and 1 or (S.snapPick == "off" and 3 or 2))
            if sb == 1 then S.snapPick = nil; S.snapLock = nil end
            if sb == 2 and S.cycleSnap then if S.snapPick == "off" then S.snapPick = nil end; S.cycleSnap(); if S.snapPick == nil then S.cycleSnap() end end
            if sb == 3 then S.snapPick = "off"; S.guides = nil end
            ui:note("Tab or tap L3 to switch while moving.")
        end
        ui:heading("Grid")
        local gi = ui:buttons("gridsz", FN.GRID_NAMES_P, S.gridI or 1)
        if gi and gi ~= S.gridI then S.gridI = gi end
        local sn = ui:toggle("snap", "Drag in steps  (G)", S.snap)
        if sn ~= nil then S.snap = sn end
    elseif S.ptab == 3 then
        -- ---------------------------------------------------------------- the park: group, copies, every object
        ui:heading(ng > 0 and string.format("Group  (%d)", ng) or "Group")
        local gb = ui:buttons("grp", { "Add / remove picked", "Clear" }, 0)
        if gb == 1 and S.sel and S.known and S.known[S.sel.id] and S.toggleGroup then S.toggleGroup(S.known[S.sel.id]) end
        if gb == 2 and S.clearGroup then S.clearGroup() end
        if ui:button("tools", "Copy tools  (row, circle, grid)") and S.openTools then S.openTools() end
        FN.rebuildList()
        local sub = tostring(S.listTotal)
        if S.search ~= "" or S.listFilter ~= 1 then sub = string.format("%d of %d", S.listMatched or 0, S.listTotal) end
        ui:heading("Objects  (" .. sub .. ")")
        local q = ui:text("search", "Search", S.search, "")
        if type(q) == "string" and q ~= S.search then S.search = q; S.listKey = nil end
        local f = ui:buttons("filter", { "All", "Near", "DDH" }, S.listFilter)
        if f and f ~= S.listFilter then S.listFilter = f; S.listKey = nil end
        FN.rebuildList()
        if #S.listItems == 0 then
            ui:note(S.listTotal == 0 and "No objects." or "Nothing found.")
        else
            local cur = 0
            if S.sel then
                for i, o in ipairs(S.listObjs) do if i > #S.listItems then break end if o.id == S.sel.id then cur = i break end end
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
        if ui:button("parkmod", "Save as park mod (for online)") then FN.saveParkModSay() end
        if S.blocked or #miss > 0 then
            ui:heading("Park locked")
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
    else
        -- ---------------------------------------------------------------- help
        ui:heading("Controller")
        local iy = ui:toggle("invy2", "Invert look up / down", S.lookInvY or false)
        if iy ~= nil and iy ~= (S.lookInvY or false) then S.lookInvY = iy; saveLook() end
        local ix = ui:toggle("invx2", "Invert look left / right", S.lookInvX or false)
        if ix ~= nil and ix ~= (S.lookInvX or false) then S.lookInvX = ix; saveLook() end
        ui:info("LB + D-pad right", "open")
        ui:info("A  /  hold A", "pick up, put down  /  select")
        ui:info("B", "cancel  /  close")
        ui:info("X  /  Y twice", "copy  /  remove")
        ui:info("RB  /  LB", "group add  /  clear")
        ui:info("Sticks, RT / LT", "move, look, up / down")
        ui:info("LB / RB (holding)", "turn")
        ui:info("D-pad (holding)", "size, zoom")
        ui:info("R3 / L3 (holding)", "copy tools (hold: no snap) / snap target")
        ui:info("Menu  /  View", "step size  /  undo")
        ui:heading("Mouse and keys")
        ui:info("Click  /  Ctrl+click", "pick  /  group")
        ui:info("Drag a handle", "move, turn, size")
        ui:info("Drag  /  right-drag", "turn  /  slide the view")
        ui:info("W  E  R", "move / turn / size handles")
        ui:info("T  /  Tab  /  G", "snapping / snap target / steps")
        ui:info("Hold Ctrl", "drag without snapping")
        ui:info("F  /  Ctrl+Z  /  Esc", "look at it / undo / done")
    end
end

-- which panel: the new one when this ReSkate has the 2.1.4 widgets, otherwise the old one
function FN.hasNewWidgets(ui)
    local ok, yes = pcall(function()
        return type(ui.stepper) == "function" and type(ui.section) == "function" and type(ui.list) == "function"
            and type(ui.buttons) == "function" and type(ui.text) == "function"
    end)
    return ok and yes
end

function FN.dockedPanel(ui)
    if S.newUI == nil then
        S.newUI = FN.hasNewWidgets(ui)
        reskate.log("Quick Drop helper: " .. (S.newUI and "using the new panel (ReSkate 2.1.4 widgets)." or "this ReSkate has no 2.1.4 widgets; using the old panel."))
    end
    if S.newUI then
        local ok, err = pcall(FN.newPanel, ui)
        if ok then return end
        reskate.log("Quick Drop helper: the new panel failed, going back to the old one: " .. tostring(err), "warn")
        S.newUI = false
        return
    end
    FN.oldPanel(ui)
end
do
    -- a screen without ReSkate's panel (panel = false): the editor draws its own
    -- (ReSkate still calls the function with panel = false, but shows nothing of it: it is left empty)
    local ok, why = pcall(reskate.ui.screen, TITLE, function(ui) end, { panel = false })
    if ok then
        S.ownPanel = true
        reskate.log("Quick Drop helper: using its own drawn panel.")
    else
        reskate.log("Quick Drop helper: a screen without a panel is not possible here (" .. tostring(why) .. "); using ReSkate's panel.")
        reskate.ui.screen(TITLE, FN.dockedPanel, { dock = "right", width = 0.2 })
    end
end

local function press(k)
    local d = reskate.input.key(k)
    local was = S.held[k]
    S.held[k] = d
    return d and not was
end

-- which handle is under the mouse (from where the last frame drew them)
function FN.handleAt(px)
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
        for _, w in ipairs({ "x", "z" }) do
            local tp = sc["tilt" .. w] or {}
            for i = 1, #tp - 1 do
                if tp[i] and tp[i + 1] and segDist(px, tp[i], tp[i + 1]) < 14 then return { kind = "tilt", axis = w } end
            end
        end
    else
        for i = 1, 8 do
            if sc.cubes and sc.cubes[i] and d2(px, sc.cubes[i]) < 18 then return { kind = "size" } end
        end
        if d2(px, sc.center) < 18 then return { kind = "size" } end
    end
    return nil
end

-- shared with the parts after this one
PE.STEPS = STEPS
PE.press = press
end
