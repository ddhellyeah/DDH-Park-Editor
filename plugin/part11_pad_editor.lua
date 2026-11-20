-- DDH Park Editor, part11_pad_editor: what the controller does each frame in the editor.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local S = PE.S
local STEPS = PE.STEPS
local V = PE.V
local allowFree = PE.allowFree
local armTighten = PE.armTighten
local camBasis = PE.camBasis
local clamp = PE.clamp
local closeEditor = PE.closeEditor
local endHoldMove = PE.endHoldMove
local flat = PE.flat
local groupCount = PE.groupCount
local padPress = PE.padPress
local padStep = PE.padStep
local redo = PE.redo
local round = PE.round
local sameAsSent = PE.sameAsSent
local say = PE.say
local select = PE.select
local send = PE.send
local snapTurned = PE.snapTurned
local startGrab = PE.startGrab
local stick = PE.stick
local undo = PE.undo
local wrap = PE.wrap

function FN.padEditor(sec)
    local p = FN.readPad()
    if not p then return end
    if S.padWait then
        for k in pairs(FN.PADNAMES) do if p[k] then return end end
        if p.lt > 0.3 or p.rt > 0.3 then return end
        S.padWait = false
    end
    -- the controller is in use: the aiming cross shows
    -- (a clear push only: a resting stick or trigger does not count, so the mouse keeps its handles)
    local anyIn = math.abs(p.lx) > 0.5 or math.abs(p.ly) > 0.5 or math.abs(p.rx) > 0.5 or math.abs(p.ry) > 0.5 or p.lt > 0.5 or p.rt > 0.5
    S.padPrevB = S.padPrevB or {}
    for k in pairs(FN.PADNAMES) do
        if p[k] and not S.padPrevB[k] then anyIn = true end
        S.padPrevB[k] = p[k]
    end
    if anyIn then S.padUsedAt = S.clock end

    if S.picker then FN.pickerPad(p) return end
    if S.colours and FN.coloursPad then FN.coloursPad(p) return end
    if S.controlsOpen then
        if padPress("b", p.b) or padPress("a", p.a) then S.controlsOpen = false end
        return
    end
    if S.carry then
        -- carrying a set: left stick moves it, RT / LT up / down, LB / RB turn, right stick circles round it,
        -- L3 tapped: snap to the nearest object, then the next
        local c = S.carry
        if p.ls and not S.l3At then S.l3At = S.clock end
        if not p.ls and S.l3At then
            if S.clock - S.l3At < 300 then FN.nextCarrySnap() end
            S.l3At = nil
        end
        if padPress("a", p.a) then S.carryDrop() return end
        if padPress("b", p.b) then S.carryCancel() return end
        local st = STEPS[S.stepSize] or STEPS[2]
        if p.ls then st = STEPS[1] end
        local rx, ry = stick(p.rx, p.ry)
        if S.lookInvX then rx = -rx end
        if S.lookInvY then ry = -ry end
        S.cam.yaw -= rx * 2.4 * sec
        S.cam.pitch = clamp(S.cam.pitch - ry * 1.6 * sec, -1.45, 1.45)
        local _, f, r = camBasis()
        local lx, ly = stick(p.lx, p.ly)
        local up = p.rt - p.lt
        if math.abs(up) < 0.15 then up = 0 end
        if lx ~= 0 or ly ~= 0 or up ~= 0 then
            local mv = (flat(f) * ly + flat(r) * lx) * st.speed * sec + V(0, up * st.speed * 0.6 * sec, 0)
            c.raw = (c.raw or c.pos) + mv
            -- snapping, like one object: the set moves as one to where its nearest piece meets something
            local spos, guides, sh = nil, nil, nil
            if p.rs then
                -- R3 held: no snapping
                c.guides, c.pos, c.snapH = nil, c.raw, nil
            else
                local okS, p1, g1, h1 = pcall(S.carrySnap, c.raw, allowFree(lx ~= 0 or ly ~= 0, up ~= 0))
                if okS then spos, guides, sh = p1, g1, h1 end
                c.guides = guides
                if spos then c.pos, c.snapH = spos, sh else c.pos, c.snapH = FN.gridSnap(c.raw), nil end
            end
        else
            c.raw = nil
        end
        local tstep = math.rad(st.deg)
        if padStep("lb", p.lb) then c.heading = wrap(round((c.snapH or c.heading) + tstep, tstep)); c.snapH = nil end
        if padStep("rb", p.rb) then c.heading = wrap(round((c.snapH or c.heading) - tstep, tstep)); c.snapH = nil end
        S.cam.goal = c.pos
        return
    end
    local fine = p.ls
    local t = S.target
    if S.grab and not (S.sel and S.sel.id == S.grab.id) then S.grab = nil end
    local holding = S.grab ~= nil
    if holding then S.bump = nil end
    if S.toolsWin then
        if not (S.sel and S.target) then S.toolsWin = nil else FN.toolsPad(p) end
    end

    if padPress("b", p.b) then
        if holding then FN.cancelGrab() else closeEditor() end
        return
    end
    if padPress("start", p.start) then
        S.stepSize = S.stepSize % #STEPS + 1
        say("Steps: " .. STEPS[S.stepSize].name)
    end
    -- L3 tapped while holding: what it snaps to (auto, each nearby object, off); held: Fine
    if p.ls and not S.l3At then S.l3At = S.clock end
    if not p.ls and S.l3At then
        if S.clock - S.l3At < 300 then
            if holding then FN.nextSnapObject() else FN.nextAimObject() end
        end
        S.l3At = nil
    end
    -- the step size chosen (Fine / Normal / Big); L3 held: Fine
    local st = STEPS[S.stepSize] or STEPS[2]
    if p.ls then st = STEPS[1] end
    if padPress("back", p.back) then
        -- View: snapping auto / one object / off; LB + View: undo; RB + View: redo
        if p.lb or p.rb then
            if holding and S.bumpTurn and S.target then S.target.heading = S.bumpTurn.h; S.dirty = true end
            S.bumpTurn = nil
            if holding then S.grab = nil; endHoldMove() end
            if p.rb then redo() else undo() end
            t = S.target; holding = false
        else
            FN.snapMode()
        end
    end
    if padPress("rs", p.rs) then
        -- holding: tap for the copy tools, hold for no snapping (while held); free: look at the picked object
        if holding then
            S.r3 = { at = S.clock }
        elseif t then
            S.cam.goal = t.pos
        end
    end
    if S.r3 then
        if p.rs and holding then
            if S.clock - S.r3.at > 250 then S.r3.long = true end
        else
            if not S.r3.long and holding then
                if S.toolsWin then S.toolsWin = nil else FN.openTools() end
            end
            S.r3 = nil
        end
    end
    S.noSnap = (S.r3 and S.r3.long) and true or false
    if S.noSnap then S.guides = nil end
    if padPress("y", p.y) then
        -- holding: the held one (a group: all of it). Free, with objects selected: Y twice quickly removes every
        -- selected one; Y once on a selected one takes it out of the selection (held down: sweep to take more out).
        -- Free otherwise: Y twice removes the one under the cross.
        local yt = S.yTap
        if holding then
            FN.deletePress()
        elseif yt and S.clock - yt.at < 450 and groupCount() > 0 and (yt.sel or not S.aim or S.group[S.aim.id]) then
            -- the second Y: every selected object goes
            S.yTap, S.yHold = nil, nil
            if S.grab then S.grab = nil; endHoldMove() end
            local ids = {}
            for gid in pairs(S.group) do ids[#ids + 1] = gid end
            local rec = S.removeUndoable(ids, "Removed")
            S.group, S.gbase = {}, nil
            S.aim = nil
            say(string.format("Removing %d selected objects... (View: undo)", rec.total))
        elseif groupCount() > 0 and (not S.aim or S.group[S.aim.id]) then
            -- the first Y with a selection: wait a moment for a second one
            S.yTap = { at = S.clock, id = S.aim and S.aim.id or nil, sel = true }
            S.yHold = { n = 0, at = S.clock }
            say(string.format("Y again: remove all %d selected.%s", groupCount(), S.aim and "  (once: take this one out)" or ""))
        else
            FN.deletePress(S.aim)
        end
        t = S.target; holding = S.grab ~= nil
    end
    -- one Y on a selected object (no second one came): it leaves the selection
    if S.yTap and S.clock - S.yTap.at >= 450 then
        local yt = S.yTap
        S.yTap = nil
        if yt.id and S.group[yt.id] then
            S.group[yt.id] = nil
            S.gbase = nil
            if S.yHold then S.yHold.n += 1 end
        end
    end
    if S.yHold and not p.y and not S.yTap then
        if S.yHold.n > 0 then
            say(string.format("Taken out of the selection: %d.  %d left.", S.yHold.n, groupCount()))
        end
        S.yHold = nil
    end
    if padPress("a", p.a) then
        if holding then
            FN.placeGrab(); holding = false
        else
            -- not holding: a tap picks up (or opens the add window) when A comes up; held, it selects (below)
            S.aHold = { at = S.clock, first = S.aim and S.aim.id or nil, sweep = false, added = 0 }
        end
    end
    if S.aHold and not p.a then
        local ah = S.aHold
        S.aHold = nil
        if ah.sweep then
            local n = groupCount()
            say(string.format("Group: %d object%s.  A on one: move them all   LB: clear   RB: add / take out", n, n == 1 and "" or "s"))
        elseif not holding then
            local o = ah.first and S.known and S.known[ah.first]
            if o then
                -- the object under the cross: pick it up
                if not (S.sel and S.sel.id == o.id) then send(); select(o); t = S.target end
                startGrab(); holding = true
            else
                -- nothing under the cross: the add window, like Quick Drop's Add Object
                FN.openPicker()
                return
            end
        end
    end
    if padPress("x", p.x) then
        if holding then FN.copyHeld()
        elseif S.aim then FN.copyAimed(S.aim)
        else say("Aim the cross at an object, then X copies it.") end
    end
    if not holding then
        if padStep("left", p.left) then FN.pickNext(-1) t = S.target end
        if padStep("right", p.right) then FN.pickNext(1) t = S.target end
        -- the group: RB puts the object under the cross in (or takes it out), LB clears it
        -- (on letting go, and only when no other button went with it: LB + View is undo, RB + View redo)
        for _, k in ipairs({ "lb", "rb" }) do
            S.bump = S.bump or {}
            if p[k] and not S.bump[k] then S.bump[k] = { used = false, aim = S.aim } end
            if p[k] and S.bump[k] and (p.back or p.a or p.x or p.y or p.right or p.left or p.up or p.down or p.lb and p.rb) then S.bump[k].used = true end
            if not p[k] and S.bump[k] then
                local b = S.bump[k]
                S.bump[k] = nil
                if not b.used then
                    if k == "rb" then FN.toggleGroup(b.aim or S.aim) else FN.clearGroup() end
                end
            end
        end
    elseif not S.toolsWin then
        -- holding: D-pad right zooms in, left zooms out (like the mouse wheel)
        if p.right then S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (1 - 1.5 * sec), 0.5, 300) end
        if p.left then S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (1 + 1.5 * sec), 0.5, 300) end
    end

    -- the view: right stick turns it
    local rx, ry = stick(p.rx, p.ry)
    if S.lookInvX then rx = -rx end
    if S.lookInvY then ry = -ry end
    if holding then
        -- holding: the right stick circles round the object (up: from higher up)
        S.cam.yaw -= rx * 2.4 * sec
        S.cam.pitch = clamp(S.cam.pitch - ry * 1.6 * sec, -1.45, 1.45)
    elseif rx ~= 0 or ry ~= 0 then
        -- free, like Quick Drop: the view turns where it stands (up: look up, right: look right)
        local cpos = camBasis()
        S.cam.yaw -= rx * 2.4 * sec
        S.cam.pitch = clamp(S.cam.pitch + ry * 1.6 * sec, -1.45, 1.45)
        local _, f2 = camBasis()
        -- (keeping where the left stick is flying it: the goal moves with the view)
        local ahead = (S.cam.goal or S.cam.target) - S.cam.target
        S.cam.target = cpos + f2 * S.cam.dist
        S.cam.goal = S.cam.target + ahead
    end

    local _, f, r = camBasis()
    local ff, rr = flat(f), flat(r)
    local lx, ly = stick(p.lx, p.ly)
    local up = p.rt - p.lt
    if math.abs(up) < 0.15 then up = 0 end

    if not holding then
        -- free: the left stick flies the view, RT / LT raise and lower it, D-pad up / down zoom
        local sp = math.max(S.cam.dist, 3) * st.fly * sec
        if lx ~= 0 or ly ~= 0 or up ~= 0 then
            S.cam.goal = (S.cam.goal or S.cam.target) + (ff * ly + rr * lx) * sp + V(0, up * sp * 0.6, 0)
        end
        if p.up then S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (1 - 1.5 * sec), 0.5, 300) end
        if p.down then S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (1 + 1.5 * sec), 0.5, 300) end
        -- what A would pick up
        S.aim = FN.aimedObject()
        if S.aimLock then
            local o = S.known and S.known[S.aimLock]
            if o and S.clock - (S.aimLockAt or 0) < 6000 and lx == 0 and ly == 0 and up == 0 then S.aim = o else S.aimLock = nil end
        end
        -- A held down: every object the cross passes over goes in the group
        local ah = S.aHold
        if ah and p.a and not ah.sweep and S.clock - ah.at > 300 then
            ah.sweep = true
            if ah.first and S.known and S.known[ah.first] and not S.group[ah.first] then S.group[ah.first] = true; ah.added += 1; S.gbase = nil end
            say("Selecting: move the cross over objects, let go of A when done.")
        end
        -- Y held (started on a group member): every member the cross passes over leaves the group
        if S.yHold and p.y and S.clock - (S.yHold.at or 0) > 300 and S.aim and S.group[S.aim.id] then
            S.group[S.aim.id] = nil
            S.gbase = nil
            S.yHold.n += 1
        end
        if ah and ah.sweep and S.aim and not S.group[S.aim.id] then
            S.group[S.aim.id] = true
            ah.added += 1
            S.gbase = nil
            if reskate.audio and reskate.audio.play_ui then pcall(reskate.audio.play_ui, "navigate") end
        end
        if S.padBurst then
            S.padBurst = false
            S.padMoving = false
        end
        return
    end
    S.aim = nil
    if not t then return end

    -- holding: one undo step for the whole hold (made when it was picked up)
    local active = false
    local function begin() active = true; S.padBurst = true end

    if S.snap then
        S.padRaw = nil
        local step = st.m
        local function nudge(key, on, v)
            if padStep(key, on) then begin(); t.pos += v * step; S.cam.goal = (S.cam.goal or S.cam.target) + v * step end
        end
        nudge("fwd", p.ly > 0.5, ff); nudge("back_", p.ly < -0.5, ff * -1)
        nudge("rgt", p.lx > 0.5, rr); nudge("lft", p.lx < -0.5, rr * -1)
        if padStep("rise", up > 0.5) then begin(); t.pos = V(t.pos.x, FN.heightStep(t.pos.y, t.pos.y + step), t.pos.z) end
        if padStep("fall", up < -0.5) then begin(); t.pos = V(t.pos.x, FN.heightStep(t.pos.y, t.pos.y - step), t.pos.z) end
        if p.ly > 0.5 or p.ly < -0.5 or p.lx > 0.5 or p.lx < -0.5 or math.abs(up) > 0.5 then active = true end
    elseif lx ~= 0 or ly ~= 0 or up ~= 0 then
        begin()
        if up ~= 0 then FN.markLifted() end
        local sp = st.speed * sec
        local mv = (ff * ly + rr * lx) * sp + V(0, up * st.speed * 0.6 * sec, 0)
        -- where the stick has taken it, and from that where it snaps to: the stick can always pull it free again
        if not S.padRaw then
            S.padHd0 = t.heading
            local tl0 = S.tilt[S.sel.id]
            S.padTilt0 = tl0 and { x = tl0.x, z = tl0.z } or nil
            S.landTrust = FN.landTrust(S.sel.item, t.pos, t.heading, t.scale, S.sel.id)
        end
        local was = t.pos
        S.padRaw = (S.padRaw or t.pos) + mv
        if S.landOn and up == 0 and (lx ~= 0 or ly ~= 0) and FN.mayLand(S.sel.id) and not S.noSnap then
            if S.clock - (S.landAt or -1e9) > 70 then
                S.landAt = S.clock
                local okL, y, sl = pcall(FN.supportY, S.sel.item, S.padRaw, S.padHd0 or t.heading, t.scale, S.sel.id, true)
                S.landY = okL and y or nil
                if okL and y and (S.landTrust or y > S.padRaw.y + 0.01) then FN.takeSlope(S.sel.id, sl, function(v) S.padTilt0 = v end) end
            end
            if S.landY then
                local ny, tr = FN.landTo(S.landTrust, S.padRaw.y, S.landY)
                if tr then S.landTrust = true end
                S.padRaw = V(S.padRaw.x, ny, S.padRaw.z)
            end
        else
            S.landY = nil
        end
        local ntl
        if S.noSnap then
            -- R3 held: no snapping at all, it goes exactly where the stick takes it
            t.pos, t.heading, S.guides, ntl = S.padRaw, S.padHd0 or t.heading, nil, S.padTilt0
            S.snapLock = nil
        else
            t.pos, t.heading, S.guides, ntl = snapTurned(S.padRaw, S.padHd0 or t.heading, t.scale, allowFree(lx ~= 0 or ly ~= 0, up ~= 0), S.padTilt0)
            t.pos = FN.gridSnap(t.pos, S.guides)
            -- raised or lowered: it catches on the ground near it (the stick can pull it free again)
            if up ~= 0 then t.pos = V(t.pos.x, FN.heightNear(t.pos.y), t.pos.z) end
        end
        S.tilt[S.sel.id] = ntl
        -- the view goes with the object where it really went (snapped, landed, on the grid), not where the stick
        -- alone would have taken it, and settles on it again: so it never drifts off to one side
        S.cam.target += t.pos - was
        S.cam.goal = t.pos
    else
        if S.padRaw then armTighten(S.guides); S.guides = nil; S.snapLock = nil end
        S.padRaw = nil
    end

    -- turn: bumpers, by the step size (Fine 1°, Normal 15°, Big 45°)
    local tstep = math.rad(st.deg)
    -- (the turn a bumper made is taken back if View follows: LB + View is undo, RB + View redo)
    if (p.lb or p.rb) and not S.bumpTurn then S.bumpTurn = { h = t.heading, at = S.clock } end
    if not (p.lb or p.rb) then S.bumpTurn = nil end
    if padStep("lb", p.lb) then begin(); t.heading = wrap(round(t.heading + tstep, tstep)) end
    if padStep("rb", p.rb) then begin(); t.heading = wrap(round(t.heading - tstep, tstep)) end
    if p.lb or p.rb then active = true end
    if (p.lb or p.rb) and S.padRaw then S.padHd0 = t.heading end

    -- size: D-pad up / down, by the step size
    local sstep = st.size
    if not S.toolsWin then
        if padStep("up", p.up) then begin(); t.scale = clamp(round(t.scale + sstep, sstep), 0.1, 10) end
        if padStep("down", p.down) then begin(); t.scale = clamp(round(t.scale - sstep, sstep), 0.1, 10) end
        if p.up or p.down then active = true end
    end

    if active then
        S.dirty = true
        S.padMoving = true
    elseif S.padBurst then
        -- let go of the stick: send the exact place soon (still held)
        S.padBurst = false
        S.padMoving = false
        S.dirty = true
        if not sameAsSent(t) then S.lastSend = math.min(S.lastSend, S.clock - 250) end
    end
end

end
