-- DDH Park Editor, part05_editor: clicking objects, opening / closing the editor (F6), game events, typing numbers, the old panel.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local S = PE.S
local TITLE = PE.TITLE
local V = PE.V
local clamp = PE.clamp
local findMissing = PE.findMissing
local forgetSize = PE.forgetSize
local len = PE.len
local markUndo = PE.markUndo
local norm = PE.norm
local rayAt = PE.rayAt
local round = PE.round
local saveLook = PE.saveLook
local say = PE.say
local select = PE.select
local send = PE.send
local tilted = PE.tilted
local titleOf = PE.titleOf
local undo = PE.undo
local wrap = PE.wrap

function FN.clickPick(px, toGroup)
    local o, d = rayAt(px)
    local hit = reskate.world.pick(o, o + d * 300)
    if not hit then return end
    local best = FN.objectAtHit(hit, FN.objectsNow())
    if best then
        send()
        select(best, hit.object and hit.object.blueprint)
        if toGroup and S.toggleGroup then S.toggleGroup(best) else say("Picked " .. titleOf(best.item)) end
    elseif hit.object then
        say("That is part of the map: only placed objects can be changed.")
    end
end

-- set later, with the controller code
PE.padCaptureOn, PE.padCaptureOff = function() end, function() end

function FN.openEditor()
    if S.open then return end
    local v = reskate.camera.get()
    if v then
        local f = v.forward
        S.cam.yaw = math.atan2(f.x, f.z)
        S.cam.pitch = clamp(math.asin(clamp(f.y, -1, 1)), -1.45, 1.45)
        S.cam.fov = v.fov or 60
        if S.target then
            S.cam.dist = clamp(len(S.target.pos - v.position), 3, 30)
            S.cam.target = S.target.pos
            -- keep the camera where it is, looking at the object
            local d = norm(S.target.pos - v.position)
            S.cam.yaw = math.atan2(d.x, d.z)
            S.cam.pitch = clamp(math.asin(clamp(d.y, -1, 1)), -1.45, 1.45)
        else
            local hit = reskate.world.raycast(v.position, v.position + f * 40)
            S.cam.dist = hit and clamp(len(hit - v.position), 3, 40) or 10
            S.cam.target = v.position + f * S.cam.dist
        end
    end
    S.cam.goal, S.cam.goalDist = S.cam.target, S.cam.dist
    -- coming back: nothing picked, unless something was dropped with Quick Drop since leaving
    if S.sel and S.closedAt and not (S.droppedAt and S.droppedAt > S.closedAt) then send(); select(nil) end
    S.open = true
    S.drag = nil
    S.mouse = { pos = nil, left = false }
    S.padWait, S.padBurst, S.padMoving, S.padRep, S.padHeld = true, false, false, {}, {}
    reskate.ui.open(TITLE)
    PE.padCaptureOn()
end

local function closeEditor()
    S.aHold, S.yHold = nil, nil
    S.carry = nil
    S.controlsOpen = false
    if S.grab then S.grab = nil end
    S.closedAt = S.clock
    S.picker = nil
    S.toolsWin = nil
    if not S.open then return end
    if S.typing then S.typing = false; pcall(reskate.ui.close_dialog, "ddh_type") end
    S.drag = nil
    S.open = false
    PE.padCaptureOff()
    reskate.camera.release()
    reskate.ui.close()
end

reskate.input.bind("ddh_quickdrop_plus", "F6")
-- (the controller opens it with LB + D-pad right: watched in the tick, see padOpenTick)
reskate.on("action", function(name)
    if name == "ddh_quickdrop_plus" or name == "ddh_quickdrop_plus_pad" then FN.openEditor() end
end)
reskate.on("screen_closed", function(title) if title == TITLE and S.open then S.open = false; S.drag = nil; PE.padCaptureOff(); reskate.camera.release() end end)
reskate.on("unload", function() PE.padCaptureOff(); if S.open then reskate.camera.release() end end)
reskate.on("level_loaded", function()
    FN.catalogReset()
    S.listKey = nil; S.known = nil; S.blocked = nil; S.missing = nil; S.confirmRemove = nil; select(nil)
    -- sizes stay known; the items the game gave none for get another try on this map
    for k, v in pairs(S.itemBox) do if v == false then S.itemBox[k] = nil end end
    S.boxTries, S.boxNext = {}, {}
    S.measure = nil
    S.bpNames = nil
    S.tiltHeld, S.tilt, S.tiltAt, S.tiltSrc, S.level = {}, {}, {}, {}, nil
    -- (online tilts: the game takes the tilted copies away with the level)
    S.buried, S.buryQ, S.tiltRemote, S.entOf, S.modelOf, S.netParts, S.noBury = {}, {}, {}, {}, {}, {}, {}
    S.bkModel, S.allBp = {}, nil
    S.netDue = true
    S.group, S.gt, S.gs, S.q, S.expectMany, S.gbase, S.toolsWin = {}, {}, {}, {}, {}, nil, nil
end)

-- typing exact numbers: a text box with "X Y Z turn size"; change any of them
FN.TYPE_ID = "ddh_type"
function FN.openTyping()
    if not (S.sel and S.target) then return end
    local t = S.target
    local text = string.format("%.3f  %.3f  %.3f  %.1f  %.2f", t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale)
    local ok, why = pcall(reskate.ui.dialog, FN.TYPE_ID, {
        title = "Type numbers",
        message = "X  Y  Z  Turn  Size, with spaces between.\nChange any of them, then Enter.\nTip: start a number with + to add to it: +2 moves 2 m, +-0.5 moves back 0.5 m.",
        field = { text = text, max = 120 },
        buttons = { { id = "apply", label = "Apply" }, { id = "close", label = "Cancel" } },
    })
    if not ok or why == false then say("Could not open the text box" .. (ok and "" or (": " .. tostring(why))), true) else S.typing = true end
end
function FN.parseTyped(str)
    local t = S.target
    local cur = { t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale }
    local out, i = {}, 0
    local clean = string.gsub(str, ",", " ")
    for w in string.gmatch(clean, "%S+") do
        i += 1
        if i > 5 then break end
        local v = tonumber(w:sub(1, 1) == "+" and w:sub(2) or w)
        if v == nil then return nil, "\"" .. w .. "\" is not a number" end
        if w:sub(1, 1) == "+" then v = cur[i] + v end
        out[i] = v
    end
    if i == 0 then return nil, "nothing typed" end
    for k = 1, 5 do if out[k] == nil then out[k] = cur[k] end end
    return out
end
reskate.on("throwdown_ui", function(e)
    if e.action ~= "dialog" or e.args[1] ~= FN.TYPE_ID then return end
    local what = e.args[2]
    if what ~= "apply" and what ~= "cancel" and what ~= "close" then return end
    S.typing = false
    if what ~= "cancel" then pcall(reskate.ui.close_dialog, FN.TYPE_ID) end
    if what ~= "apply" then return end
    if not (S.sel and S.target) then return end
    local v, err = FN.parseTyped(e.args[3] or "")
    if not v then say("Typed numbers: " .. err, true); return end
    markUndo()
    local t = S.target
    t.pos = V(v[1], v[2], v[3])
    t.heading = wrap(math.rad(v[4]))
    t.scale = clamp(v[5], 0.1, 10)
    S.sel.anchor = t.pos
    S.dirty = true
    say(string.format("Set to %.2f, %.2f, %.2f  ·  %.1f°  ·  %.2f×", t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale))
end)

-- the old panel (ReSkate 2.1.3 and older)
function FN.oldPanel(ui)
    if S.sel then
        local t = S.target
        ui:card(titleOf(S.sel.item), string.format("%.2f, %.2f, %.2f   ·   %.0f°   ·   %.2f×", t.pos.x, t.pos.y, t.pos.z, math.deg(t.heading), t.scale))
    else
        ui:card("Nothing picked", "Click an object, or drop one with Quick Drop")
    end
    if S.sel and S.target then
        local t = S.target
        local a = S.sel.anchor
        if not a or len(t.pos - a) > 9 then a = t.pos; S.sel.anchor = a end
        local function num(id, label, val, lo, hi, fmt)
            local v = ui:slider(id, label, val, lo, hi, fmt)
            return v ~= nil and math.abs(v - val) > 1e-4 and v or nil
        end
        ui:heading("Position")
        local x = num("px", "X", t.pos.x, a.x - 10, a.x + 10, "%.3f m")
        local y = num("py", "Y", t.pos.y, a.y - 10, a.y + 10, "%.3f m")
        local z = num("pz", "Z", t.pos.z, a.z - 10, a.z + 10, "%.3f m")
        if x or y or z then
            if not S.sliding then markUndo(); S.sliding = true end
            t.pos = V(x or t.pos.x, y or t.pos.y, z or t.pos.z); S.dirty = true
        end
        ui:heading("Turn")
        local ty = num("ry", "Y", math.deg(t.heading), -180, 180, "%.1f°")
        if ty then
            if not S.sliding then markUndo(); S.sliding = true end
            t.heading = wrap(math.rad(ty)); S.dirty = true
        end
        local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
        local tx = num("tx", "Tilt X", math.deg(tl.x), -180, 180, "%.1f°")
        local tz = num("tz", "Tilt Z", math.deg(tl.z), -180, 180, "%.1f°")
        if tx or tz then
            if not S.sliding then markUndo(); S.sliding = true end
            S.tilt[S.sel.id] = { x = tx and math.rad(tx) or tl.x, z = tz and math.rad(tz) or tl.z }
            S.tiltSaveDue = true
        end
        if tilted(S.sel.id) and S.tiltWhy and not S.tiltHeld[S.sel.id] then ui:note("Tilt waits: " .. S.tiltWhy) end
        if ui:button("parkmod", "Save as park mod (for online)") then FN.saveParkModSay() end
        local sz = num("sz", "Size", t.scale, 0.1, 10, "%.2f×")
        if sz then
            if not S.sliding then markUndo(); S.sliding = true end
            t.scale = sz; S.dirty = true
        end
        if not (x or y or z or ty or sz) then S.sliding = false end
        ui:separator()
    end
    local m = ui:tabs("mode", { "Move (W)", "Turn (E)", "Size (R)" }, S.mode)
    if m and m ~= S.mode then S.mode = m end
    local sn = ui:toggle("snap", "Steps: 0.25 m, 15°, 0.1 (G)", S.snap)
    if sn ~= nil then S.snap = sn end
    local ob = ui:toggle("osnap", "Snap to objects (T)", S.osnap)
    if ob ~= nil then S.osnap = ob end
    if S.osnap and S.sel and S.itemBox[S.sel.item] and not S.exact[S.sel.item] then
        if ui:button("remeasure", "Measure it again") then
            forgetSize(S.sel.item)
            say("Measuring " .. titleOf(S.sel.item) .. " again: keep it still a moment")
        end
    end
    ui:separator()
    if ui:button("undo", "Undo (Ctrl+Z)") then undo() end
    if ui:button("straight", "Straighten and size 1") and S.target then
        markUndo(); S.target.heading = round(S.target.heading, math.pi / 2); S.target.scale = 1; S.dirty = true
        if S.tilt[S.sel.id] then S.tilt[S.sel.id] = nil; S.tiltSaveDue = true end
    end
    if ui:button("focus", "Look at it (F)") and S.target then S.cam.goal = S.target.pos end
    local miss = S.missing or {}
    if S.blocked or #miss > 0 then
        ui:separator()
        ui:heading("Park locked")
        ui:warn("The game won't change this park.")
        ui:note("It has objects from a mod that is")
        ui:note("off, not installed, or rebuilt with")
        ui:note("new object names.")
        if S.blocked and S.blocked ~= "?" then ui:info("Game says", S.blocked) end
        for i, o in ipairs(miss) do
            if i > 8 then ui:note(string.format("...and %d more (all in ReSkate.log)", #miss - 8)) break end
            ui:info(titleOf(o.item), string.format("%.0f, %.0f, %.0f", o.position.x, o.position.y, o.position.z))
            if ui:button("go" .. i, "Look at it") then S.cam.goal = o.position end
        end
        ui:note("To clean them out: close the game,")
        ui:note("then run \"Clean out park.exe\"")
        ui:note("(MOD SKATE\\DDH_Park_Editor).")
        if ui:button("recheck", "Check again") then
            S.blocked = nil
            pcall(findMissing)
            if #(S.missing or {}) == 0 then say("No missing objects found. Try moving something again.") end
        end
    end
    if S.msg ~= "" and S.clock < S.msgUntil then ui:note(S.msg) end
    ui:separator()
    local lx_ = ui:toggle("invy", "Invert look up/down (controller)", S.lookInvY or false)
    if lx_ ~= nil and lx_ ~= (S.lookInvY or false) then S.lookInvY = lx_; saveLook() end
    local ly_ = ui:toggle("invx", "Invert look left/right (controller)", S.lookInvX or false)
    if ly_ ~= nil and ly_ ~= (S.lookInvX or false) then S.lookInvX = ly_; saveLook() end
    local h = ui:toggle("help", "Show the controls", S.help or false)
    if h ~= nil then S.help = h end
    if S.help then
        ui:info("Click", "pick an object")
        ui:info("Drag a handle", "move / turn / size")
        ui:info("Drag empty space", "turn the view")
        ui:info("Right-drag", "slide the view")
        ui:info("Scroll", "zoom")
        ui:info("Arrows, PgUp, PgDn", "fly the view")
        ui:info("Shift", "bigger steps")
        ui:info("Controller", "LB + D-pad right opens")
        ui:info("Left stick", "fly (holding: move it)")
        ui:info("A", "pick up what the cross is on / put down")
        ui:info("B", "cancel (back where it was) / close")
        ui:info("X", "copy (holding: drop a copy)")
        ui:info("Y twice", "remove (what the cross is on)")
        ui:info("RT / LT", "raise / lower")
        ui:info("LB / RB", "turn (holding)")
        ui:info("D-pad up / down", "size (holding) / zoom")
        ui:info("D-pad left / right", "next object (holding: zoom)")
        ui:info("Hold A", "select: sweep the cross over objects")
        ui:info("Y on a selected one", "out of the group (hold Y and sweep for more)")
        ui:info("RB / LB", "group: add or take out / clear")
        ui:info("Right stick / R3", "turn the view / look at it (holding: copy tools)")
        ui:info("Ctrl+click", "group: add or take out")
        ui:info("Tab / tap L3", "snap: auto / one object / off")
        ui:info("View / Menu", "undo / Fine-Normal-Big")
        ui:info("Hold L3", "Fine while held")
    end
    if ui:button("close", "Done (Esc)", true) then closeEditor() end
end

-- shared with the parts after this one
PE.closeEditor = closeEditor
end
