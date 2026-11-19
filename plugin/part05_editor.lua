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
    -- (the Add window open: closed the usual way, so where it was is kept)
    if S.picker and FN.closePicker then pcall(FN.closePicker) end
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

-- shared with the parts after this one
PE.closeEditor = closeEditor
end
