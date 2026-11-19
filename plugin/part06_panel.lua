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

-- ---------------------------------------------------------------- step sizes, and the park list
-- step sizes for the steppers: metres, degrees, size
-- (speed: how fast the controller slides a held object, m/s; fly: how fast the free view flies, times)
local STEPS = {
    { m = 0.01, deg = 1, size = 0.01, speed = 0.4, fly = 0.3, name = "Fine", mf = "%.2f m", df = "%.0f°", sf = "%.2f×" },
    { m = 0.1, deg = 15, size = 0.1, speed = 2.5, fly = 1.0, name = "Normal", mf = "%.2f m", df = "%.0f°", sf = "%.2f×" },
    { m = 1, deg = 45, size = 0.5, speed = 6.0, fly = 2.5, name = "Big", mf = "%.1f m", df = "%.0f°", sf = "%.1f×" },
}
S.stepSize = 2
S.search, S.listFilter = "", 1
S.listAt, S.listKey = -1e9, nil
S.listObjs, S.listTotal = {}, 0

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
    S.listObjs, S.listMatched = {}, #rows
    -- (every match goes in the list, so its groups are whole)
    for i, r in ipairs(rows) do
        S.listObjs[i] = r.o
    end
end

do
    -- a screen without ReSkate's panel (panel = false): the editor draws its own
    -- (ReSkate still calls the function with panel = false, but shows nothing of it: it is left empty)
    local ok, why = pcall(reskate.ui.screen, TITLE, function(ui) end, { panel = false })
    if ok then
        S.ownPanel = true
        reskate.log("Quick Drop helper: using its own drawn panel.")
    else
        -- (the old docked panel for ReSkate 2.1.3 and older is gone: the editor needs a newer ReSkate)
        reskate.log("Quick Drop helper: this ReSkate can't open a screen without its own panel (" .. tostring(why) .. "); update ReSkate to use the editor.", "error")
        pcall(reskate.ui.toast, "DDH Park Editor needs a newer ReSkate: update ReSkate to use it.", "warn")
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
