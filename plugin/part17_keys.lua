-- DDH Park Editor, part17_keys: the keys and the controller's buttons, and the Settings window where the player
-- changes them (two tabs: Keyboard, Controller).
-- Every keyboard key the editor uses is an action here with up to two keys each (a key, or a combo like Ctrl+Z).
-- The tick asks FN.kbPress(id) (pressed this frame) and FN.kbDown(id) (held) instead of naming keys itself.
-- What the player changes is kept between games (storage "keys": only what differs from the default).
-- Settings window: click a key box, then press a key or a combo (Ctrl, Shift, Alt + a key); click the box again
-- to clear it, anywhere else to cancel. Controller: D-pad moves, A changes (then press a key on the keyboard),
-- X clears, Y puts the row back to its default, LB / RB the other tab, B cancels / closes.
-- Controller tab: each controller job can go on another button (see "the controller's buttons" below).
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

-- ---------------------------------------------------------------- the actions and their default keys
-- ctx: "ed" in the editor, "any" also with the editor closed (only the key that opens it). hold: a key held down (one key, no combo).
local ACTIONS = {
    { head = "In the editor" },
    { id = "open", name = "Open the editor", ctx = "any", def = { "F6" } },
    { id = "modeMove", name = "Move handles", def = { "W" } },
    { id = "modeTurn", name = "Turn handles", def = { "E" } },
    { id = "modeSize", name = "Size handles", def = { "R" } },
    { id = "osnap", name = "Snap to objects on / off", def = { "T" } },
    { id = "snapTarget", name = "Snap target: auto, one, off", def = { "Tab" } },
    { id = "grid", name = "Drag in steps", def = { "G" } },
    { id = "look", name = "Look at the picked object", def = { "F" } },
    { id = "measure", name = "Measure on / off", def = { "M" } },
    { id = "undo", name = "Undo", def = { "Ctrl+Z" } },
    { id = "redo", name = "Redo", def = { "Ctrl+Y", "Ctrl+Shift+Z" } },
    { id = "bigger", name = "Bigger steps (hold)", hold = true, def = { "Shift" } },
    { id = "noSnap", name = "No snapping (hold)", hold = true, def = { "Ctrl" } },
    { id = "multi", name = "Group add / remove (hold, click)", hold = true, def = { "Ctrl" } },
    { head = "Fly the view", col = 2 },
    { id = "flyF", name = "Forward", hold = true, def = { "Up" } },
    { id = "flyB", name = "Back", hold = true, def = { "Down" } },
    { id = "flyL", name = "Left", hold = true, def = { "Left" } },
    { id = "flyR", name = "Right", hold = true, def = { "Right" } },
    { id = "flyU", name = "Up", hold = true, def = { "PageUp" } },
    { id = "flyD", name = "Down", hold = true, def = { "PageDown" } },
    { head = "Objects" },
    { id = "toGround", name = "Drop onto the ground", def = {} },
    { head = "Placing a set" },
    { id = "setDrop", name = "Put the set down", def = { "Enter" } },
    { id = "setCancel", name = "Cancel placing it", def = { "Backspace" } },
}
local BYID = {}
for _, a in ipairs(ACTIONS) do if a.id then a.ctx = a.ctx or "ed"; BYID[a.id] = a end end
-- (these may share a key: both are held with a click or a drag)
local SHARE = { noSnap = true, multi = true }

-- the keys a key box can take (Esc closes the screen and Insert opens ReSkate's menu: not offered)
local MODS = { "Ctrl", "Shift", "Alt" }
local ISMOD = { Ctrl = true, Shift = true, Alt = true }
local CAND = {}
for c in string.gmatch("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", ".") do CAND[#CAND + 1] = c end
for i = 1, 12 do CAND[#CAND + 1] = "F" .. i end
for _, k in ipairs({ "Tab", "Space", "Enter", "Backspace", "Delete", "Home", "End", "PageUp", "PageDown", "Up", "Down", "Left", "Right",
    "[", "]", ";", "'", ",", ".", "/", "\\", "-", "=", "`", "Ctrl", "Shift", "Alt" }) do CAND[#CAND + 1] = k end
-- (a name ReSkate doesn't know is left out, the first time it is asked about)
local bad = {}
local function rawDown(k)
    if bad[k] then return false end
    local ok, v = pcall(reskate.input.key, k)
    if not ok then bad[k] = true; return false end
    return v == true
end
local ORANGE = "#ffa640"
local SHOW = { PageUp = "PgUp", PageDown = "PgDn", Backspace = "Bksp", Delete = "Del" }

-- ---------------------------------------------------------------- the keys as set: strings, and read apart
-- a binding: "Ctrl+Shift+Z" -> { key = "Z", ctrl = true, shift = true, n = 2, s = "Ctrl+Shift+Z" }
local function parse(str)
    if type(str) ~= "string" or str == "" then return nil end
    local parts = {}
    -- (split at "+", but a "+" never comes alone here: the key itself is never "+")
    for p in string.gmatch(str, "[^+]+") do parts[#parts + 1] = p end
    if #parts == 0 then return nil end
    local b = { key = parts[#parts], n = 0, s = str }
    for i = 1, #parts - 1 do
        local m = parts[i]
        if m == "Ctrl" then b.ctrl = true elseif m == "Shift" then b.shift = true elseif m == "Alt" then b.alt = true else return nil end
        b.n += 1
    end
    return b
end
local function compose(key, ctrl, shift, alt)
    local t = {}
    if ctrl and key ~= "Ctrl" then t[#t + 1] = "Ctrl" end
    if shift and key ~= "Shift" then t[#t + 1] = "Shift" end
    if alt and key ~= "Alt" then t[#t + 1] = "Alt" end
    t[#t + 1] = key
    return table.concat(t, "+")
end

local SET = {}      -- id -> { "str1", "str2" } (missing or "" = none)
local B = {}        -- id -> parsed bindings (a list)
local conflict = {} -- id .. "|" .. slot -> names of the other actions on the same key
local function rebuild()
    for _, a in ipairs(ACTIONS) do
        if a.id then
            local l = {}
            for slot = 1, 2 do
                local b = parse(SET[a.id][slot])
                if b then b.slot = slot; l[#l + 1] = b end
            end
            B[a.id] = l
        end
    end
    -- the same key on two actions that can happen at once
    conflict = {}
    local function overlap(c1, c2) return c1 == "any" or c2 == "any" or c1 == c2 end
    for _, a in ipairs(ACTIONS) do
        if a.id then
            for _, b in ipairs(B[a.id]) do
                for _, a2 in ipairs(ACTIONS) do
                    if a2.id and a2 ~= a and overlap(a.ctx, a2.ctx) and not (SHARE[a.id] and SHARE[a2.id]) then
                        for _, b2 in ipairs(B[a2.id]) do
                            if b2.s == b.s then
                                local k = a.id .. "|" .. b.slot
                                conflict[k] = conflict[k] or {}
                                table.insert(conflict[k], a2.name)
                            end
                        end
                    end
                end
            end
        end
    end
end
local function resetAll()
    for _, a in ipairs(ACTIONS) do if a.id then SET[a.id] = { a.def[1] or "", a.def[2] or "" } end end
end
resetAll()
do
    local ok, saved = pcall(reskate.storage.get, "keys")
    if ok and type(saved) == "table" then
        for id, l in pairs(saved) do
            if BYID[id] and type(l) == "table" then
                for slot = 1, 2 do
                    local v = l[slot]
                    if v == "" or parse(v) then SET[id][slot] = v end
                end
            end
        end
    end
end
rebuild()
local function save()
    local out = {}
    for _, a in ipairs(ACTIONS) do
        if a.id then
            local s1, s2 = SET[a.id][1] or "", SET[a.id][2] or ""
            if s1 ~= (a.def[1] or "") or s2 ~= (a.def[2] or "") then out[a.id] = { s1, s2 } end
        end
    end
    pcall(reskate.storage.set, "keys", out)
end

-- ---------------------------------------------------------------- reading them each frame
local was, edge, now = {}, {}, {}
-- once a tick, before anything asks: which keys went down this frame
function FN.kbBegin()
    local want = {}
    for _, m in ipairs(MODS) do want[m] = true end
    for _, l in pairs(B) do for _, b in ipairs(l) do want[b.key] = true end end
    if S.keysWin and S.keysWin.listen then for _, k in ipairs(CAND) do want[k] = true end end
    edge, now = {}, {}
    for k in pairs(want) do
        local d = rawDown(k)
        now[k] = d
        edge[k] = d and not was[k]
    end
    was = now
end
local function modsOk(b)
    -- (Alt held only counts for a key set with Alt: else Alt+Tab, going to another window, cycled the snap target
    -- with Tab, and snapping seemed to stop)
    return (not b.ctrl or now.Ctrl) and (not b.shift or now.Shift) and (not b.alt or now.Alt) and (b.alt or not now.Alt or b.key == "Alt")
end
-- held: one of its keys down (with its Ctrl / Shift / Alt, if it has them)
function FN.kbDown(id)
    for _, b in ipairs(B[id] or {}) do
        if now[b.key] and modsOk(b) then return true end
    end
    return false
end
-- pressed this frame; a combo wins over the same key with fewer modifiers (Ctrl+Shift+Z over Ctrl+Z over Z)
function FN.kbPress(id)
    local a = BYID[id]
    if not a then return false end
    for _, b in ipairs(B[id] or {}) do
        if edge[b.key] and modsOk(b) then
            local beaten = false
            for _, a2 in ipairs(ACTIONS) do
                if a2.id and a2 ~= a and not a2.hold and (a2.ctx == a.ctx or a2.ctx == "any" or a.ctx == "any") then
                    for _, b2 in ipairs(B[a2.id]) do
                        if b2.key == b.key and b2.n > b.n and modsOk(b2) then beaten = true end
                    end
                end
            end
            if not beaten then return true end
        end
    end
    return false
end
-- how a binding reads: "Ctrl+Z", "PgUp"; "none" when it has no key
local function show(str)
    if not str or str == "" then return "none" end
    local t = {}
    for p in string.gmatch(str, "[^+]+") do t[#t + 1] = SHOW[p] or p end
    return table.concat(t, "+")
end
function FN.kbLabel(id, slot)
    local l = SET[id]
    if not l then return "?" end
    return show(l[slot or 1])
end
-- the parts of its first key, each its own keycap ({ "Ctrl", "Z" }); its second key when the first is empty
function FN.kbCaps(id)
    local l = SET[id]
    if not l then return { "?" } end
    local s = (l[1] ~= "" and l[1]) or l[2]
    if not s or s == "" then return { "none" } end
    local t = {}
    for p in string.gmatch(s, "[^+]+") do t[#t + 1] = SHOW[p] or p end
    return t
end
-- whether an action still has its default keys
function FN.kbIsDefault(id)
    local a, l = BYID[id], SET[id]
    return a and l and (l[1] or "") == (a.def[1] or "") and (l[2] or "") == (a.def[2] or "")
end

-- ---------------------------------------------------------------- the key that opens the editor
-- ReSkate's own key binding for each key it is set to (an action name per key: one bound earlier for another key
-- stays bound until the game restarts, so the name says which key it was and only the ones set now open it);
-- the tick also watches the keys itself (FN.kbOpenTick), in case a binding was refused
local bound = {}
local function bindOpen()
    for _, b in ipairs(B.open or {}) do
        local safe = string.gsub(b.key, "%W", function(c) return string.format("x%02x", string.byte(c)) end)
        local nm = "ddh_qdp_open_" .. string.lower(safe)
        if bound[nm] == nil then
            local ok = pcall(reskate.input.bind, nm, b.key)
            bound[nm] = ok and b.key or false
        end
    end
end
bindOpen()
reskate.on("action", function(name)
    if name == "ddh_quickdrop_plus_pad" then FN.openEditor() return end
    local key = bound[name]
    if not key then return end
    for _, b in ipairs(B.open or {}) do
        if b.key == key and (b.n == 0 or (FN.kbHeld(b))) then FN.openEditor() return end
    end
end)
-- (modifiers asked for at once: the action can come before the tick has read the keys)
function FN.kbHeld(b)
    return (not b.ctrl or rawDown("Ctrl")) and (not b.shift or rawDown("Shift")) and (not b.alt or rawDown("Alt"))
end
function FN.kbOpenTick()
    if FN.kbPress("open") and reskate.input.allowed() then FN.openEditor() return true end
    return false
end

-- ---------------------------------------------------------------- changing them
local function setKey(id, slot, str)
    SET[id][slot] = str or ""
    -- (the second key the same as the first: just the one)
    if SET[id][1] == SET[id][2] then SET[id][2] = "" end
    -- (the editor always has a key that opens it)
    if id == "open" and SET.open[1] == "" and SET.open[2] == "" then
        SET.open[1] = BYID.open.def[1]
        say("The editor needs a key to open it: back to " .. show(SET.open[1]) .. ".", true)
    end
    rebuild()
    save()
    if id == "open" then bindOpen() end
end


-- ---------------------------------------------------------------- the controller's buttons
-- Each of the editor's controller jobs (shown by its usual button) can be moved to another button. FN.readPad gives
-- the other parts the buttons by job, so everything follows: the editor, its windows and the button prompts.
-- Choosing a button another job has swaps the two, so every job always has a button (and B / A always exist
-- somewhere to close and choose). The two sticks can swap too.
local PHYS = { "a", "b", "x", "y", "lb", "rb", "lt", "rt", "up", "down", "left", "right", "back", "start", "ls", "rs" }
local ISPHYS = {}
for _, k in ipairs(PHYS) do ISPHYS[k] = true end
local PADSHOW = { a = "A", b = "B", x = "X", y = "Y", lb = "LB", rb = "RB", lt = "LT", rt = "RT", up = "D-pad up", down = "D-pad down",
    left = "D-pad left", right = "D-pad right", back = "View", start = "Menu", ls = "L3", rs = "R3" }
local PSSHOW = { a = "Cross", b = "Circle", x = "Square", y = "Triangle", lb = "L1", rb = "R1", lt = "L2", rt = "R2", up = "D-pad up",
    down = "D-pad down", left = "D-pad left", right = "D-pad right", back = "Create", start = "Options", ls = "L3", rs = "R3" }
-- which names and symbols the buttons are shown with: "auto" (a PlayStation pad when one is read, see part07),
-- "xbox" or "ps"; kept between games
local STYLE = "auto"
do
    local ok, v = pcall(reskate.storage.get, "padStyle")
    if ok and (v == "auto" or v == "xbox" or v == "ps") then STYLE = v end
end
local function isPS()
    if STYLE == "ps" then return true elseif STYLE == "xbox" then return false end
    return S.padPS == true
end
UI.padIsPS = isPS
local function setStyle(v)
    STYLE = v
    pcall(reskate.storage.set, "padStyle", v)
end
local function nameOf(ph) return (isPS() and PSSHOW or PADSHOW)[ph] or tostring(ph) end
-- a button's own name as shown now ("LT", or "L2" on PlayStation)
function FN.padPhysName(ph) return nameOf(ph) end
local JOBSHORT = { a = "pick up  ·  hold select", b = "cancel  /  close", x = "copy", y = "remove  ·  ungroup", lb = "turn  ·  clear group",
    rb = "turn  ·  add to group", lt = "lower", rt = "raise", up = "bigger  ·  zoom in", down = "smaller  ·  zoom out",
    left = "last object  ·  zoom out", right = "next object  ·  zoom in", back = "snap: auto / one / off", start = "step size",
    ls = "next snap  ·  hold fine", rs = "tools  ·  hold: no snap" }
local PADROWS = {
    { head = "Buttons" },
    { id = "a", name = "Pick up / put down (hold: select)" },
    { id = "b", name = "Cancel / close" },
    { id = "x", name = "Copy" },
    { id = "y", name = "Remove / take out of group" },
    { id = "lb", name = "Turn / clear group" },
    { id = "rb", name = "Turn back / add to group" },
    { id = "lt", name = "Lower" },
    { id = "rt", name = "Raise" },
    { head = "Sticks" },
    { id = "stickMove", name = "Move", stick = true, def = "l" },
    { id = "stickLook", name = "Look around", stick = true, def = "r" },
    { head = "D-pad and the rest", col = 2 },
    { id = "up", name = "Bigger / zoom in" },
    { id = "down", name = "Smaller / zoom out" },
    { id = "left", name = "Last object / zoom out" },
    { id = "right", name = "Next object / zoom in" },
    { id = "back", name = "Snap: auto, one, off" },
    { id = "start", name = "Step size" },
    { id = "ls", name = "Next snap target (hold: fine)" },
    { id = "rs", name = "Tools, look at it (hold: no snap)" },
    { head = "Opening the editor" },
    { id = "open", name = "Open the editor", combo = true },
}
local PADBYID = {}
for _, r in ipairs(PADROWS) do if r.id then if not r.combo then r.def = r.def or r.id end; PADBYID[r.id] = r end end

local PMAP = {}   -- job -> the button doing it ("l" / "r" for the sticks)
local padDefault = true
local function padCheck()
    padDefault = true
    for _, r in ipairs(PADROWS) do if r.id and not r.combo and PMAP[r.id] ~= r.def then padDefault = false end end
end
local function padDefaults()
    for _, r in ipairs(PADROWS) do if r.id and not r.combo then PMAP[r.id] = r.def end end
    padCheck()
end
padDefaults()
do
    local ok, saved = pcall(reskate.storage.get, "pad")
    if ok and type(saved) == "table" then
        for _, r in ipairs(PADROWS) do
            local v = r.id and not r.combo and saved[r.id]
            if v ~= nil then
                if r.stick then if v == "l" or v == "r" then PMAP[r.id] = v end
                elseif ISPHYS[v] then PMAP[r.id] = v end
            end
        end
        -- (every button used once, the sticks one each: else back to the usual)
        local seen, okAll = {}, PMAP.stickMove ~= PMAP.stickLook
        for _, k in ipairs(PHYS) do
            if seen[PMAP[k]] then okAll = false end
            seen[PMAP[k]] = true
        end
        if not okAll then padDefaults() end
        padCheck()
    end
end
local function padSave()
    local out = {}
    for _, r in ipairs(PADROWS) do if r.id and not r.combo and PMAP[r.id] ~= r.def then out[r.id] = PMAP[r.id] end end
    pcall(reskate.storage.set, "pad", out)
end

-- ---- the buttons that open the editor (with it closed): one or two buttons held together, or none. The
-- buttons themselves, as the pad has them (not the editor's jobs). Kept between games (storage "padOpen")
local OPEN_DEF = { "lb", "right" }
local OPEN = { "lb", "right" }
do
    local ok, v = pcall(reskate.storage.get, "padOpen")
    if ok and type(v) == "table" then
        local l, good = {}, true
        for i = 1, math.min(#v, 2) do if ISPHYS[v[i]] then l[#l + 1] = v[i] else good = false end end
        if good and (#l > 0 or v.none) then OPEN = l end
    end
end
local function openIsDefault() return #OPEN == 2 and OPEN[1] == OPEN_DEF[1] and OPEN[2] == OPEN_DEF[2] end
local function setOpen(l)
    OPEN = l
    if #l == 0 then pcall(reskate.storage.set, "padOpen", { none = true })
    else pcall(reskate.storage.set, "padOpen", { l[1], l[2] }) end
end

local function dig(p, ph)
    local v = p[ph]
    if ph == "lt" or ph == "rt" then return (tonumber(v) or 0) > 0.5 end
    return v == true
end
local function stickMag(p, side)
    local x, y = side == "l" and p.lx or p.rx, side == "l" and p.ly or p.ry
    return math.sqrt((x or 0) ^ 2 + (y or 0) ^ 2)
end
-- the buttons that open the editor, written ("LB + D-pad right"), or nil when none are set
function FN.padOpenLabel()
    if #OPEN == 0 then return nil end
    local t = {}
    for i, ph in ipairs(OPEN) do t[i] = nameOf(ph) end
    return table.concat(t, " + ")
end
-- with the editor closed, once a tick: the buttons that open it just pressed together (raw: the pad as it is)
local openWas = false
function FN.padOpenPressed(raw)
    if not raw or #OPEN == 0 then openWas = false return false end
    local all = true
    for _, ph in ipairs(OPEN) do if not dig(raw, ph) then all = false end end
    local fire = all and not openWas
    openWas = all
    return fire
end
-- the pad as read, given by job (FN.readPad, part07, calls this)
function FN.padRemap(p)
    if padDefault then return p end
    local q = {}
    local L = PMAP.stickMove == "l"
    if L then q.lx, q.ly, q.rx, q.ry = p.lx, p.ly, p.rx, p.ry else q.lx, q.ly, q.rx, q.ry = p.rx, p.ry, p.lx, p.ly end
    for _, lg in ipairs(PHYS) do
        local ph = PMAP[lg]
        local dn = dig(p, ph)
        if lg == "lt" or lg == "rt" then
            if ph == "lt" or ph == "rt" then q[lg] = tonumber(p[ph]) or 0 else q[lg] = dn and 1 or 0 end
        else
            q[lg] = dn
        end
    end
    return q
end
-- the button doing a job, as written ("A", "LB", "View")
function FN.padName(job) return nameOf(PMAP[job]) end
-- the job a button does
local function jobOf(ph)
    for _, k in ipairs(PHYS) do if PMAP[k] == ph then return k end end
    return ph
end
-- the controls window's lines for a button (nil while every button does its usual job: it keeps its own)
function FN.padCallout(which)
    if padDefault and not isPS() then return nil end
    if which == "lstick" or which == "rstick" then
        local side = which == "lstick" and "l" or "r"
        local move = PMAP.stickMove == side
        local click = which == "lstick" and "ls" or "rs"
        return string.format("%s   %s  ·  %s %s", which == "lstick" and "L-stick" or "R-stick", move and "move" or "look",
            which == "lstick" and "L3" or "R3", JOBSHORT[jobOf(click)])
    elseif which == "dpad" then
        local same = true
        for _, k in ipairs({ "up", "down", "left", "right" }) do
            local j = jobOf(k)
            if j ~= "up" and j ~= "down" and j ~= "left" and j ~= "right" then same = false end
        end
        if same then return "D-pad   size  ·  zoom" end
        local t = {}
        for _, k in ipairs({ "up", "down", "left", "right" }) do t[#t + 1] = JOBSHORT[jobOf(k)] end
        return "D-pad   " .. table.concat(t, "  ·  ")
    end
    return nameOf(which) .. "   " .. JOBSHORT[jobOf(which)]
end
-- a button prompt: the job's button as it is now (round A B X Y, the rest written; words like "LB RB" each swapped)
local TOK = { A = "a", B = "b", X = "x", Y = "y", LB = "lb", RB = "rb", LT = "lt", RT = "rt", View = "back", Menu = "start", L3 = "ls", R3 = "rs" }
function UI.padShow(k)
    if (padDefault and not isPS()) or type(k) ~= "string" then return k end
    if k == "a" or k == "b" or k == "x" or k == "y" then
        local ph = PMAP[k]
        if ph == "a" or ph == "b" or ph == "x" or ph == "y" then return ph end
        return nameOf(ph)
    end
    local out = {}
    for wd in string.gmatch(k, "%S+") do
        local lg = TOK[wd]
        out[#out + 1] = lg and nameOf(PMAP[lg]) or wd
    end
    return table.concat(out, " ")
end

-- a message's button names ("A: put down", "View: undo", "D-pad left/right") as the buttons doing those jobs now
function FN.padText(s)
    if type(s) ~= "string" or (padDefault and not isPS()) then return s end
    s = string.gsub(s, "%w+", function(wd)
        local lg = TOK[wd]
        if lg then return nameOf(PMAP[lg]) end
        return nil
    end)
    if PMAP.left ~= "left" or PMAP.right ~= "right" then
        s = string.gsub(s, "D%-pad left/right", function() return nameOf(PMAP.left) .. " / " .. nameOf(PMAP.right) end)
    end
    return s
end

-- choosing: the job takes the button, and whatever job had it takes this job's old one
local function padAssign(id, val)
    local old = PMAP[id]
    if old == val then return end
    local r = PADBYID[id]
    for _, r2 in ipairs(PADROWS) do
        if r2.id and r2 ~= r and (not r2.stick) == (not r.stick) and PMAP[r2.id] == val then
            PMAP[r2.id] = old
            say(string.format("Swapped: %s is now on %s.", r2.name, r2.stick and (old == "l" and "the left stick" or "the right stick") or nameOf(old)))
        end
    end
    PMAP[id] = val
    padCheck()
    padSave()
end

-- ---------------------------------------------------------------- the Settings window: its two tabs
S.keysWin = nil   -- open: { tab = "keys" / "pad", focus = n, slot, top, listen = { id, slot, mods } or { pad = true, id, base, at } }
-- the rows the controller moves through (no headings), each one's number there, and its place in its column
-- (headings counted: the column's rows scroll together)
local function indexOf(list)
    local rows, ridx, cidx = {}, {}, {}
    local col, idx = 1, 0
    for _, a in ipairs(list) do
        if a.col and a.col ~= col then col, idx = a.col, 0 end
        idx += 1
        if a.id then rows[#rows + 1] = a; ridx[a] = #rows; cidx[a] = idx end
    end
    return { rows = rows, ridx = ridx, cidx = cidx, list = list }
end
local TABS = { keys = indexOf(ACTIONS), pad = indexOf(PADROWS) }
local function tabOf(w) return TABS[w.tab] or TABS.keys end

function FN.openKeys(tab)
    S.controlsOpen = false
    if S.colours and FN.closeColours then FN.closeColours() end
    S.keysWin = { tab = tab == "pad" and "pad" or (S.keysTab or "keys"), focus = 1, slot = 1, top = 0 }
end
local function closeKeys()
    if S.keysWin then S.keysTab = S.keysWin.tab end
    S.keysWin = nil
end
FN.closeKeys = closeKeys
local function setTab(w, tab)
    if w.tab == tab then return end
    w.tab, w.focus, w.slot, w.top, w.listen = tab, 1, 1, 0, nil
end

local function listenOn(id, slot)
    local w = S.keysWin
    -- (keys already down don't count: the next press does)
    for _, k in ipairs(CAND) do was[k] = rawDown(k) end
    w.listen = { id = id, slot = slot, mods = {} }
end
-- a controller job waiting for a button: what is down now doesn't count until let go
local function listenPad(id)
    local w = S.keysWin
    local base = {}
    local raw = FN.readPadRaw and FN.readPadRaw()
    if raw then
        for _, ph in ipairs(PHYS) do base[ph] = dig(raw, ph) end
        base.l, base.r = stickMag(raw, "l") > 0.5, stickMag(raw, "r") > 0.5
    end
    w.listen = { pad = true, id = id, base = base, at = S.clock }
end
-- while listening: the first key pressed (with Ctrl / Shift / Alt held, a combo); a modifier pressed and let go by
-- itself is taken alone
function FN.keysTick()
    local w = S.keysWin
    if not (w and w.listen) then return end
    local L = w.listen
    if L.pad then
        -- (nothing pressed for a while: not listening any more)
        if S.clock - (L.at or 0) > 8000 then w.listen = nil end
        return
    end
    local a = BYID[L.id]
    for _, k in ipairs(CAND) do
        if edge[k] and not ISMOD[k] then
            local str = a.hold and k or compose(k, now.Ctrl, now.Shift, now.Alt)
            w.listen = nil
            setKey(L.id, L.slot, str)
            return
        end
    end
    for _, m in ipairs(MODS) do
        if edge[m] then
            if a.hold then w.listen = nil; setKey(L.id, L.slot, m) return end
            L.mods[m] = true
        elseif L.mods[m] and not now[m] then
            w.listen = nil
            setKey(L.id, L.slot, m)
            return
        end
    end
end
-- the controller job waiting: the first button pressed (or stick pushed, for a stick)
local function padCapture(w)
    local raw = FN.readPadRaw and FN.readPadRaw()
    if not raw then return end
    local L = w.listen
    local r = PADBYID[L.id]
    if L.combo then
        -- (buttons pressed, at most two, in the order pressed; set once they are all let go)
        local any = false
        for _, ph in ipairs(PHYS) do
            local dn = dig(raw, ph)
            if dn then any = true end
            if dn and not L.base[ph] then
                local have = false
                for _, g in ipairs(L.got) do if g == ph then have = true end end
                if not have and #L.got < 2 then L.got[#L.got + 1] = ph end
            end
            if not dn then L.base[ph] = false end
        end
        if not any and #L.got > 0 then
            w.listen = nil; w.padRelease = true
            setOpen(L.got)
            local lab = FN.padOpenLabel()
            if #L.got == 1 then say("Opens the editor: " .. lab .. ". One button alone also opens it whenever it is pressed while skating.", true)
            else say("Opens the editor: " .. lab .. ".") end
        end
        return
    end
    if r.stick then
        for _, side in ipairs({ "l", "r" }) do
            local on = stickMag(raw, side) > 0.7
            if on and not L.base[side] then w.listen = nil; w.padRelease = true; padAssign(L.id, side) return end
            if not on then L.base[side] = false end
        end
        return
    end
    for _, ph in ipairs(PHYS) do
        local dn = dig(raw, ph)
        if dn and not L.base[ph] then w.listen = nil; w.padRelease = true; padAssign(L.id, ph) return end
        if not dn then L.base[ph] = false end
    end
end

-- ---------------------------------------------------------------- drawing
local tiles = {}
local function tileAdd(a, b, fn) tiles[#tiles + 1] = { a = a, b = b, fn = fn } end
local function hot(a, b)
    local m = S.mouse and S.mouse.pos
    return m and m.x >= a.x and m.x <= b.x and m.y >= a.y and m.y <= b.y
end
local function edgeBox(d, a, b, r) d:rect(a, b, { colour = UI.border, rounding = r or 6, thickness = 1 }) end
local function ring(d, a, b, r) d:rect(a - V(4, 4, 0), b + V(4, 4, 0), { colour = UI.text, rounding = (r or 6) + 4, thickness = 2 }) end

local function cellClick(id, slot)
    local w = S.keysWin
    local L = w.listen
    if L and not L.pad and L.id == id and L.slot == slot then
        -- clicked again while listening: no key
        w.listen = nil
        setKey(id, slot, "")
        return
    end
    listenOn(id, slot)
end
local function padClick(id)
    local w = S.keysWin
    local L = w.listen
    if L and L.pad and L.id == id then w.listen = nil return end
    listenPad(id)
    if PADBYID[id] and PADBYID[id].combo then w.listen.combo, w.listen.got = true, {} end
end
local function openNone() setOpen({}); say("The controller doesn't open the editor now (the key still does).") end
local function openReset() setOpen({ OPEN_DEF[1], OPEN_DEF[2] }); say("The controller opens the editor with " .. FN.padOpenLabel() .. " again.") end
local function resetRow(id)
    local a = BYID[id]
    SET[id] = { a.def[1] or "", a.def[2] or "" }
    rebuild(); save()
    if id == "open" then bindOpen() end
end
local function resetPadRow(id) padAssign(id, PADBYID[id].def) end
local function resetAllKeys() resetAll(); rebuild(); save(); bindOpen(); say("Keys back to how they were") end
local function resetAllPad() padDefaults(); padSave(); setOpen({ OPEN_DEF[1], OPEN_DEF[2] }); say("Controller buttons back to how they were") end

-- a box: a key or a button (listening: accent edge; a clash: orange edge)
local function box(d, ka, kb, label, faint, listening, clash, fsize)
    d:rect(ka, kb, { colour = listening and UI.accentDim or (hot(ka, kb) and UI.fieldHot or UI.field), fill = true, rounding = 6 })
    if listening then d:rect(ka, kb, { colour = UI.accent, rounding = 6, thickness = 2 })
    elseif clash then d:rect(ka, kb, { colour = ORANGE, rounding = 6, thickness = 2 })
    else edgeBox(d, ka, kb, 6) end
    UI.textIn(d, ka, kb, label, { size = fsize - 1, colour = faint and UI.faint or UI.text, font = (not faint and not listening) and "bold" or nil, align = "centre" }, 6)
end
local function resetBtn(d, ra, rb, fsize, fn)
    d:rect(ra, rb, { colour = hot(ra, rb) and UI.fieldHot or UI.field, fill = true, rounding = 6 })
    edgeBox(d, ra, rb, 6)
    UI.textIn(d, ra, rb, "Reset", { size = fsize - 2, colour = UI.dim, align = "centre" }, 4)
    tileAdd(ra, rb, fn)
end

-- the rows in two columns (scrolled together when they don't fit); rowFn draws one row
local function columns(d, w, T, x0, y0, inner, avail, rowFn)
    local gap = 28
    local colW = (inner - gap) / 2
    local cols = { {}, {} }
    local col = 1
    for _, it in ipairs(T.list) do
        if it.col then col = it.col end
        table.insert(cols[col], it)
    end
    local most = math.max(#cols[1], #cols[2], 1)
    local rh = clamp(math.floor(avail / most), 24, 34)
    w.maxTop = math.max(0, most - math.floor(avail / rh))
    w.top = clamp(w.top or 0, 0, w.maxTop)
    w.shown = math.max(1, math.floor(avail / rh))
    local fsize = rh >= 30 and 15 or 13
    for ci = 1, 2 do
        local cx = x0 + (ci - 1) * (colW + gap)
        local y = y0
        for ri, it in ipairs(cols[ci]) do
            if ri > w.top and y + rh <= y0 + avail + 0.5 then
                if it.head then
                    UI.fitText(d, cx, y + rh - 20, string.upper(it.head), colW, { size = 13, colour = UI.dim, font = "bold" })
                    d:line(V(cx, y + rh - 2, 0), V(cx + colW, y + rh - 2, 0), { colour = UI.border, thickness = 1 })
                else
                    rowFn(it, cx, y, colW, rh, fsize, w.pad and w.focus == T.ridx[it])
                end
                y += rh
            end
        end
    end
end

local function keysRow(d, w)
    return function(it, cx, y, colW, rh, fsize, rowFocus)
        local id = it.id
        local kw = clamp(math.floor(colW * 0.24), 84, 132)
        local rw2 = 60
        local nameW = colW - 2 * kw - rw2 - 3 * 8
        UI.fitText(d, cx + 2, y + (rh - fsize * 1.25) / 2, it.name, nameW, { size = fsize, colour = UI.text })
        for slot = 1, 2 do
            local ka = V(cx + nameW + 8 + (slot - 1) * (kw + 8), y + 3, 0)
            local kb = V(ka.x + kw, y + rh - 3, 0)
            local L = w.listen
            local listening = L and not L.pad and L.id == id and L.slot == slot
            local str = SET[id][slot]
            box(d, ka, kb, listening and "Press a key" or (str ~= "" and show(str) or "-"), str == "" and not listening, listening,
                conflict[id .. "|" .. slot], fsize)
            if rowFocus and w.slot == slot then ring(d, ka, kb) end
            tileAdd(ka, kb, function() cellClick(id, slot) end)
        end
        local ra, rb = V(cx + colW - rw2, y + 3, 0), V(cx + colW, y + rh - 3, 0)
        if not FN.kbIsDefault(id) then resetBtn(d, ra, rb, fsize, function() resetRow(id) end) end
        if rowFocus and w.slot == 3 then ring(d, ra, rb) end
    end
end
local function padRow(d, w)
    return function(it, cx, y, colW, rh, fsize, rowFocus)
        local id = it.id
        if it.combo then
            -- the buttons that open it: a box (click, then press one or two buttons together), None, Reset
            local kw = clamp(math.floor(colW * 0.3), 110, 180)
            local rw2 = 60
            local nameW = colW - kw - 2 * rw2 - 3 * 8
            UI.fitText(d, cx + 2, y + (rh - fsize * 1.25) / 2, it.name, nameW, { size = fsize, colour = UI.text })
            local ka = V(cx + nameW + 8, y + 3, 0)
            local kb = V(ka.x + kw, y + rh - 3, 0)
            local L = w.listen
            local listening = L and L.pad and L.id == id
            local lab = FN.padOpenLabel()
            if listening then
                local t = {}
                for i, ph in ipairs(L.got or {}) do t[i] = nameOf(ph) end
                lab = #t > 0 and table.concat(t, " + ") or "Press 1 or 2 buttons"
            end
            box(d, ka, kb, lab or "None", lab == nil and not listening, listening, false, fsize)
            if rowFocus and w.slot == 1 then ring(d, ka, kb) end
            tileAdd(ka, kb, function() padClick(id) end)
            local na, nb = V(kb.x + 8, y + 3, 0), V(kb.x + 8 + rw2, y + rh - 3, 0)
            d:rect(na, nb, { colour = hot(na, nb) and UI.fieldHot or UI.field, fill = true, rounding = 6 })
            edgeBox(d, na, nb, 6)
            UI.textIn(d, na, nb, "None", { size = fsize - 2, colour = UI.dim, align = "centre" }, 4)
            tileAdd(na, nb, openNone)
            if rowFocus and w.slot == 2 then ring(d, na, nb) end
            local ra, rb = V(cx + colW - rw2, y + 3, 0), V(cx + colW, y + rh - 3, 0)
            if not openIsDefault() then resetBtn(d, ra, rb, fsize, openReset) end
            if rowFocus and w.slot == 3 then ring(d, ra, rb) end
            return
        end
        local kw = clamp(math.floor(colW * 0.3), 110, 180)
        local rw2 = 60
        local nameW = colW - kw - rw2 - 2 * 8
        UI.fitText(d, cx + 2, y + (rh - fsize * 1.25) / 2, it.name, nameW, { size = fsize, colour = UI.text })
        local ka = V(cx + nameW + 8, y + 3, 0)
        local kb = V(ka.x + kw, y + rh - 3, 0)
        local L = w.listen
        local listening = L and L.pad and L.id == id
        local v = PMAP[id]
        local face = not it.stick and not listening and (v == "a" or v == "b" or v == "x" or v == "y")
        local label = it.stick and (v == "l" and "Left stick" or "Right stick") or nameOf(v)
        if listening then label = it.stick and "Push a stick" or "Press a button" end
        if face then
            -- A B X Y in their colours (PlayStation: the symbol in its colour, and its name)
            box(d, ka, kb, "", false, false, false, fsize)
            local r = math.max(8, math.floor((kb.y - ka.y) / 2) - 2)
            local cy = (ka.y + kb.y) / 2
            if isPS() then
                local tw = UI.textW(d, label, fsize - 1, "bold")
                local x1 = (ka.x + kb.x) / 2 - (2 * r + 8 + tw) / 2
                UI.faceGlyph(d, V(x1 + r, cy, 0), v, r)
                UI.textIn(d, V(x1 + 2 * r + 4, ka.y, 0), kb, label, { size = fsize - 1, colour = UI.text, font = "bold" }, 4)
            else
                UI.faceGlyph(d, V((ka.x + kb.x) / 2, cy, 0), v, r)
            end
        else
            box(d, ka, kb, label, false, listening, false, fsize)
        end
        if rowFocus and w.slot == 1 then ring(d, ka, kb) end
        tileAdd(ka, kb, function() padClick(id) end)
        local ra, rb = V(cx + colW - rw2, y + 3, 0), V(cx + colW, y + rh - 3, 0)
        if v ~= it.def then resetBtn(d, ra, rb, fsize, function() resetPadRow(id) end) end
        if rowFocus and w.slot == 2 then ring(d, ra, rb) end
    end
end

-- the buttons along the bottom of each tab
local function bottomButtons(w)
    if w.tab == "pad" then
        return {
            { "Appearance", function() closeKeys(); if FN.openColours then FN.openColours() end end },
            { "Reset all buttons", resetAllPad },
            { "Done", closeKeys, true },
        }
    end
    return {
        { "Appearance", function() closeKeys(); if FN.openColours then FN.openColours() end end },
        { "Reset all keys", resetAllKeys },
        { "Done", closeKeys, true },
    }
end

function UI.keysWin(d)
    local w = S.keysWin
    if not w then return end
    tiles = {}
    local fit, tin = UI.fitText, UI.textIn
    local W, H = S.size.x, S.size.y
    local pw, ph = math.min(1240, W - 20), math.min(900, H - 20)
    local a = V(math.floor((W - pw) / 2), math.floor((H - ph) / 2), 0)
    local b = a + V(pw, ph, 0)
    S.screen.keysBox = { a = a, b = b }
    d:rect(V(0, 0, 0), V(W, H, 0), { colour = "#00000080", fill = true })
    UI.panelBox(d, a, b, "Settings")
    local ca, cb = V(b.x - 48, a.y + 10, 0), V(b.x - 12, a.y + 44, 0)
    d:text(V((ca.x + cb.x) / 2, ca.y + 4, 0), "×", { size = 24, colour = UI.dim, align = "centre" })
    tileAdd(ca, cb, closeKeys)
    local x0 = a.x + 20
    local inner = pw - 40
    -- the tabs
    local ty = a.y + 64
    local tabW = 170
    d:rect(V(x0 - 2, ty - 2, 0), V(x0 + 2 * tabW + 2, ty + 36, 0), { colour = UI.field, fill = true, rounding = 8 })
    for i, tb in ipairs({ { "keys", "Keyboard" }, { "pad", "Controller" } }) do
        local ta, tb2 = V(x0 + (i - 1) * tabW, ty, 0), V(x0 + i * tabW, ty + 34, 0)
        local on = w.tab == tb[1]
        if on then d:rect(V(ta.x + 2, ty, 0), V(tb2.x - 2, tb2.y, 0), { colour = UI.accent, fill = true, rounding = 6 })
        elseif hot(ta, tb2) then d:rect(V(ta.x + 2, ty, 0), V(tb2.x - 2, tb2.y, 0), { colour = UI.fieldHot, fill = true, rounding = 6 }) end
        tin(d, ta, tb2, tb[2], { size = 15, colour = on and UI.onAccent or UI.dim, font = "bold", align = "centre" }, 6)
        tileAdd(ta, tb2, function() setTab(w, tb[1]) end)
    end
    if w.tab == "pad" then
        -- which names the buttons go by
        local opts = { { "auto", "Auto" }, { "xbox", "Xbox" }, { "ps", "PlayStation" } }
        local ow = 120
        local ox = b.x - 20 - 3 * ow
        fit(d, ox - 150, ty + 9, "Button names", 140, { size = 14, colour = UI.dim, align = nil })
        d:rect(V(ox - 2, ty - 2, 0), V(ox + 3 * ow + 2, ty + 36, 0), { colour = UI.field, fill = true, rounding = 8 })
        for i, o in ipairs(opts) do
            local oa, ob = V(ox + (i - 1) * ow, ty, 0), V(ox + i * ow, ty + 34, 0)
            local on = STYLE == o[1]
            if on then d:rect(V(oa.x + 2, ty, 0), V(ob.x - 2, ob.y, 0), { colour = UI.accent, fill = true, rounding = 6 })
            elseif hot(oa, ob) then d:rect(V(oa.x + 2, ty, 0), V(ob.x - 2, ob.y, 0), { colour = UI.fieldHot, fill = true, rounding = 6 }) end
            local lab = o[2]
            if o[1] == "auto" and on then lab = S.padPS and "Auto (PS)" or "Auto (Xbox)" end
            tin(d, oa, ob, lab, { size = 14, colour = on and UI.onAccent or UI.dim, font = "bold", align = "centre" }, 6)
            tileAdd(oa, ob, function() setStyle(o[1]) end)
        end
    end
    local y0 = ty + 50
    local T = tabOf(w)
    local bottomH = 128
    local avail = (b.y - bottomH) - y0
    if w.tab == "pad" then columns(d, w, T, x0, y0, inner, avail, padRow(d, w))
    else columns(d, w, T, x0, y0, inner, avail, keysRow(d, w)) end
    -- what is happening, or what clashes
    local by = b.y - bottomH + 10
    local msg, mcol = "Click a box, then press a key or a combo (Ctrl, Shift or Alt with a key).", UI.dim
    if w.tab == "pad" then
        msg = "Click a box, then press the button for it. A button another job has: the two swap."
        if w.listen then msg, mcol = "Press a button on the controller now (a stick: push it). Click anywhere to cancel.", UI.accent end
    elseif w.listen then
        msg, mcol = "Press a key or a combo now. Click the box again for no key, anywhere else to cancel.", UI.accent
        if w.pad then msg = "Press a key or a combo on the keyboard now.  B: cancel,  X: no key." end
    else
        local f = w.pad and T.rows[w.focus]
        local cl = f and (conflict[f.id .. "|1"] or conflict[f.id .. "|2"])
        if not cl then
            f = nil
            for _, r in ipairs(T.rows) do
                cl = conflict[r.id .. "|1"] or conflict[r.id .. "|2"]
                if cl then f = r break end
            end
        end
        if cl and f then msg, mcol = string.format("Careful: %s shares a key with %s.", f.name, table.concat(cl, ", ")), ORANGE end
    end
    fit(d, x0, by, msg, inner, { size = 14, colour = mcol })
    -- the buttons
    local btns = bottomButtons(w)
    local bw = math.min(220, (inner - 16) / 3)
    local bx = b.x - 20 - 3 * bw - 16
    if w.tab == "pad" then
        fit(d, x0, by + 39, FN.padOpenLabel() and ("Opens the editor: " .. FN.padOpenLabel()) or "The controller doesn't open the editor", math.max(40, bx - x0 - 12), { size = 14, colour = UI.dim })
    end
    for i, bt in ipairs(btns) do
        local ta = V(bx + (i - 1) * (bw + 8), by + 30, 0)
        local tb = ta + V(bw, 36, 0)
        local prim = bt[3]
        d:rect(ta, tb, { colour = prim and (hot(ta, tb) and UI.accentHot or UI.accent) or (hot(ta, tb) and UI.fieldHot or UI.field), fill = true, rounding = 6 })
        if not prim then edgeBox(d, ta, tb, 6) end
        tin(d, ta, tb, bt[1], { size = 14, colour = prim and UI.onAccent or UI.text, font = prim and "bold" or nil, align = "centre" }, 6)
        if w.pad and w.focus == #T.rows + 1 and w.slot == i then ring(d, ta, tb) end
        tileAdd(ta, tb, bt[2])
    end
    if w.listen and w.listen.pad then
        UI.footer(d, a, b, {})
    elseif w.listen then
        UI.footer(d, a, b, { { "b", "Cancel" }, { "x", "No key" } })
    elseif w.tab == "pad" then
        UI.footer(d, a, b, { { "D-pad", "Move" }, { "a", "Change" }, { "y", "Default" }, { "Menu", "Names" }, { "LB RB", "Tab" }, { "b", "Close" } })
    else
        UI.footer(d, a, b, { { "D-pad", "Move" }, { "a", "Change" }, { "x", "No key" }, { "y", "Default" }, { "LB RB", "Tab" }, { "b", "Close" } })
    end
end

-- ---- the mouse: true while the window is open (it takes the mouse)
function UI.keysMouse(cm)
    local w = S.keysWin
    if not w then return false end
    local px = cm.position
    if cm.wheel and cm.wheel ~= 0 then w.top = clamp((w.top or 0) - cm.wheel, 0, w.maxTop or 0) end
    if cm.left and not S.mouse.left then
        w.pad = false
        local box2 = S.screen.keysBox
        if box2 and not (px.x >= box2.a.x and px.x <= box2.b.x and px.y >= box2.a.y and px.y <= box2.b.y) then
            if w.listen then w.listen = nil else closeKeys() end
            return true
        end
        local hit = false
        for i = #tiles, 1, -1 do
            local tt = tiles[i]
            if px.x >= tt.a.x and px.x <= tt.b.x and px.y >= tt.a.y and px.y <= tt.b.y then
                if reskate.audio and reskate.audio.play_ui then pcall(reskate.audio.play_ui, "select") end
                local L = w.listen
                tt.fn()
                -- (another box or button clicked while listening: that stops the listening, unless it started one)
                if L and w.listen == L then w.listen = nil end
                hit = true
                break
            end
        end
        if not hit and w.listen then w.listen = nil end
    end
    return true
end

-- ---- the controller
local function anyDown(raw)
    if not raw then return false end
    for _, ph in ipairs(PHYS) do if dig(raw, ph) then return true end end
    return stickMag(raw, "l") > 0.5 or stickMag(raw, "r") > 0.5
end
function FN.keysPad(p)
    local w = S.keysWin
    if not w then return end
    -- a button just chosen: nothing until everything is let go (it may now do another job)
    if w.padRelease then
        if anyDown(FN.readPadRaw and FN.readPadRaw()) then return end
        w.padRelease = nil
        S.padHeld, S.padRep = {}, {}
        return
    end
    if w.listen and w.listen.pad then padCapture(w) return end
    w.pad = true
    if w.listen then
        if padPress("b", p.b) then w.listen = nil end
        if w.listen and padPress("x", p.x) then local L = w.listen; w.listen = nil; setKey(L.id, L.slot, "") end
        return
    end
    if padPress("b", p.b) then closeKeys() return end
    if padPress("lb", p.lb) or padPress("rb", p.rb) then setTab(w, w.tab == "pad" and "keys" or "pad") return end
    if w.tab == "pad" and padPress("start", p.start) then
        setStyle(STYLE == "auto" and "xbox" or (STYLE == "xbox" and "ps" or "auto"))
        return
    end
    local T = tabOf(w)
    local maxSlot = w.tab == "pad" and 2 or 3
    local lx, ly = stick(p.lx, p.ly)
    local up, dn = padStep("ku", p.up or ly > 0.5), padStep("kd", p.down or ly < -0.5)
    local left, right = padStep("kl", p.left or lx < -0.5), padStep("kr", p.right or lx > 0.5)
    local n = #T.rows + 1
    if up then w.focus = math.max(1, w.focus - 1) end
    if dn then w.focus = math.min(n, w.focus + 1) end
    local r = T.rows[w.focus]
    local lim = r and (r.combo and 3 or maxSlot) or 3
    if left then w.slot = math.max(1, w.slot - 1) end
    if right then w.slot = math.min(lim, w.slot + 1) end
    w.slot = math.min(w.slot, lim)
    -- (the row kept in view)
    if r and (up or dn) then
        local idx = T.cidx[r]
        -- (its heading shown with the first row under it)
        if idx - 1 <= (w.top or 0) then w.top = math.max(0, idx - 2) end
        if idx > (w.top or 0) + (w.shown or 1e9) then w.top = idx - (w.shown or 1) end
        w.top = clamp(w.top, 0, w.maxTop or 0)
    end
    if padPress("a", p.a) then
        if r then
            if w.tab == "pad" and r.combo then
                if w.slot == 1 then padClick(r.id) elseif w.slot == 2 then openNone() else openReset() end
            elseif w.tab == "pad" then
                if w.slot == 1 then listenPad(r.id) else resetPadRow(r.id) end
            elseif w.slot <= 2 then listenOn(r.id, w.slot) else resetRow(r.id) end
        else
            local bt = bottomButtons(w)[w.slot]
            if bt then bt[2]() end
        end
        return
    end
    if r and w.tab ~= "pad" and padPress("x", p.x) and w.slot <= 2 then setKey(r.id, w.slot, "") end
    if r and w.tab == "pad" and r.combo and padPress("x", p.x) then openNone() end
    if r and padPress("y", p.y) then
        if w.tab == "pad" and r.combo then openReset() elseif w.tab == "pad" then resetPadRow(r.id) else resetRow(r.id) end
    end
end

end
