-- DDH Park Editor, part12_tick: the tick: everything that runs every frame.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local PLANES = PE.PLANES
local S = PE.S
local SNAP_TURN = PE.SNAP_TURN
local UI = PE.UI
local V = PE.V
local allowAlong = PE.allowAlong
local allowIn = PE.allowIn
local armTighten = PE.armTighten
local axesFor = PE.axesFor
local camBasis = PE.camBasis
local camGlide = PE.camGlide
local clamp = PE.clamp
local d2 = PE.d2
local dot = PE.dot
local findMissing = PE.findMissing
local flat = PE.flat
local groupBase = PE.groupBase
local learnNear = PE.learnNear
local markUndo = PE.markUndo
local planeHit = PE.planeHit
local press = PE.press
local rayAt = PE.rayAt
local redo = PE.redo
local round = PE.round
local sameAsSent = PE.sameAsSent
local say = PE.say
local scan = PE.scan
local send = PE.send
local snapTurned = PE.snapTurned
local undo = PE.undo
local wrap = PE.wrap

local function tickBody(dt)
    S.clock += dt
    local sec = dt / 1000
    if S.clock - S.lastScan > 500 then
        S.lastScan = S.clock
        local ok, err = pcall(scan)
        if not ok then reskate.log("Quick Drop helper: " .. tostring(err), "warn") end
    end

    if S.cleanup and #S.cleanup > 0 and S.clock - (S.cleanupAt or 0) > 1000 then
        S.cleanupAt = S.clock
        local id = S.cleanup[1]
        local ok, why = reskate.objects.remove(id)
        reskate.log("Quick Drop helper: removing a leftover object (" .. tostring(id) .. "): " .. (ok and "done" or tostring(why)))
        if ok or (why ~= "the last edit is still being applied" and why ~= "more than 4 edits in a second") then
            table.remove(S.cleanup, 1)
            if not ok then S.cleanupFailed = (S.cleanupFailed or 0) + 1 end
            if #S.cleanup == 0 then
                S.blocked = nil
                pcall(findMissing)
                if (S.cleanupFailed or 0) > 0 then
                    say("The game refused to remove " .. S.cleanupFailed .. " of them. Turn the mod back on instead (see ReSkate.log).", true)
                else
                    say("Done. The park can be changed again.", true)
                end
                S.cleanupFailed = nil
            end
        end
    end

    do
        local okc, errc = pcall(FN.copyTick)
        if not okc then S.copyQ = nil; reskate.log("Quick Drop helper: copy: " .. tostring(errc), "warn") end
    end
    do
        local okg, errg = pcall(function() FN.followTick(); FN.sendGroup(); FN.qTick() end)
        if not okg then
            if #S.q > 0 then table.remove(S.q, 1) end
            if not S.groupWarned then S.groupWarned = true; reskate.log("Quick Drop helper: group: " .. tostring(errg), "warn") end
        end
    end
    do
        local ok, err = pcall(FN.tiltTick)
        if not ok and not S.tiltWarned then S.tiltWarned = true; reskate.log("Quick Drop helper: tilt: " .. tostring(err), "warn") end
    end
    if FN.modShapesTick then FN.modShapesTick() end
    if FN.scanTick then
        local ok, err = pcall(FN.scanTick)
        if not ok then S.scanJob = nil; if not S.scanWarned then S.scanWarned = true; reskate.log("Quick Drop helper: scan: " .. tostring(err), "warn") end end
    end

    -- the keys (as set in Settings): what went down this frame
    FN.kbBegin()

    if not S.open then
        -- the key that opens it (ReSkate's own binding opens it too: whichever comes first)
        if FN.kbOpenTick() then return end
        -- the controller: the buttons set in Settings (LB + D-pad right unless changed; none: it doesn't open it)
        local raw = FN.readPadRaw and FN.readPadRaw()
        if FN.padOpenPressed and FN.padOpenPressed(raw) and S.clock - (S.closedAt or -1e9) > 400 then
            FN.openEditor()
            return
        end
        -- (the keyboard does nothing to objects with the editor closed)
        send()
        return
    end

    -- the editor: keys (none while the text box is open)
    if S.typing then send(); return end
    if FN.undoStepTick then FN.undoStepTick() end
    if FN.coloursTick then FN.coloursTick() end
    if S.keysWin then
        -- the Settings window: the keys are being changed, so they do nothing else (a key pressed is taken as the
        -- new key while a box waits for one)
        FN.keysTick()
    else
        local kp = FN.kbPress
        if kp("modeMove") then S.mode = 1 end
        if kp("modeTurn") then S.mode = 2 end
        if kp("modeSize") then S.mode = 3 end
        if kp("grid") then S.snap = not S.snap end
        if kp("osnap") then S.osnap = not S.osnap; say(S.osnap and "Snap to objects on" or "Snap to objects off") end
        if kp("snapTarget") and S.sel then FN.cycleSnap() end
        if kp("look") and S.target then S.cam.goal = S.target.pos end
        if kp("measure") then FN.toggleMeasure() end
        if kp("undo") then undo() end
        if kp("redo") then redo() end
        if kp("toGround") then FN.dropToGround() end
        -- the view: arrows and PageUp / PageDown slide it (or the keys set for it)
        local _, f, r = camBasis()
        local kd = FN.kbDown
        local sp = math.max(S.cam.dist, 3) * (kd("bigger") and 2.5 or 0.8) * sec
        local mv = V(0, 0, 0)
        if kd("flyF") then mv += flat(f) end
        if kd("flyB") then mv -= flat(f) end
        if kd("flyR") then mv += flat(r) end
        if kd("flyL") then mv -= flat(r) end
        if kd("flyU") then mv += V(0, 1, 0) end
        if kd("flyD") then mv -= V(0, 1, 0) end
        S.cam.goal = (S.cam.goal or S.cam.target) + mv * sp
    end
    do
        local ok, err = pcall(learnNear)
        if not ok and not S.learnWarned then S.learnWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(err), "warn") end
        ok, err = pcall(FN.stepTighten)
        if not ok then S.tighten = nil; if not S.tightWarned then S.tightWarned = true; reskate.log("Quick Drop helper: snap: " .. tostring(err), "warn") end end
    end
    do
        local ok, err = pcall(FN.padEditor, sec)
        if not ok then reskate.log("Quick Drop helper: controller: " .. tostring(err), "warn") end
        if not S.open then return end
    end

    -- the mouse
    local c = reskate.input.cursor()
    -- (over the picked object's numbers under the controller's prompts: they take the mouse, and it stays the
    -- controller's view)
    -- a panel's edge being dragged to resize it (first: it keeps the mouse until let go)
    if c and S.ownPanel and UI.gripMouse and not S.drag and not S.colours and not S.keysWin and not S.picker and not S.controlsOpen then
        local okg, usedG = pcall(UI.gripMouse, c)
        if okg and usedG then
            S.mouse = { pos = c.position, left = c.left }
            S.hover = nil
            c = nil
        end
    end
    if c and UI.padRowsMouse and not S.drag and not S.keysWin then
        local okr, usedR = pcall(UI.padRowsMouse, c)
        if okr and usedR then
            S.mouse = { pos = c.position, left = c.left }
            c = nil
        end
    end
    if c and ((S.mouse.pos and d2(c.position, S.mouse.pos) > 3) or c.left or c.right or (c.wheel and c.wheel ~= 0)) then S.mouseUsedAt = S.clock end
    if c and S.controlsOpen then
        pcall(UI.controlsMouse, c)
        S.mouse = { pos = c.position, left = c.left }
        c = nil
    end
    if c and S.keysWin and UI.keysMouse then
        pcall(UI.keysMouse, c)
        S.mouse = { pos = c.position, left = c.left }
        c = nil
    end
    if c and S.colours and UI.coloursMouse then
        pcall(UI.coloursMouse, c)
        S.mouse = { pos = c.position, left = c.left }
        c = nil
    end
    if c and S.ownPanel and not S.picker and not S.drag then
        local okp, used = pcall(UI.panelMouse, c)
        if okp and used then
            S.mouse = { pos = c.position, left = c.left }
            S.hover = nil
            c = nil
        end
    end
    if c and S.toolsWin and not S.drag and not c.over_screen then
        local okt, used = pcall(FN.toolsMouse, c)
        if okt and used then
            S.mouse = { pos = c.position, left = c.left }
            c = nil
        end
    end
    if c and S.picker then
        pcall(FN.pickerMouse, c)
        S.mouse = { pos = c.position, left = c.left }
        c = nil
    end
    if c then
        local px = c.position
        local last = S.mouse.pos or px
        if (S.mouse.pos and d2(px, S.mouse.pos) > 3) or c.left or c.right or (c.wheel and c.wheel ~= 0) then S.mouseUsedAt = S.clock end
        local dx, dy = px.x - last.x, px.y - last.y
        if c.wheel and c.wheel ~= 0 and not c.over_screen then
            S.cam.goalDist = clamp((S.cam.goalDist or S.cam.dist) * (0.85 ^ c.wheel), 0.5, 300)
        end
        S.hover = (not S.drag and not c.over_screen) and FN.handleAt(px) or nil
        if c.left and not S.mouse.left and not c.over_screen then
            local h = FN.handleAt(px)
            if h then
                markUndo()
                local t = S.target
                local tl0 = S.tilt[S.sel.id]
                h.start = { pos = t.pos, heading = t.heading, scale = t.scale, px = px, tilt = tl0 and { x = tl0.x, z = tl0.z } or nil }
                if S.group[S.sel.id] then groupBase() else S.gbase = nil end
                local o, d = rayAt(px)
                if h.kind == "axis" then
                    local s0, s1 = S.screen.center, S.screen.unit[h.axis]
                    local ppm = s1 and d2(s0, s1) or 0
                    h.dir = ppm > 1 and V((s1.x - s0.x) / ppm, (s1.y - s0.y) / ppm, 0) or V(1, 0, 0)
                    h.ppm = math.max(ppm, 1)
                elseif h.kind == "plane" then
                    h.n = axesFor(t.heading)[PLANES[h.plane].n][1]
                    h.hit0 = planeHit(o, d, t.pos, h.n)
                    if not h.hit0 then h = nil end
                elseif h.kind == "size" then
                    h.c0 = S.screen.center
                    h.d0 = math.max(d2(px, h.c0), 12)
                elseif h.kind == "tilt" then
                    local c0 = S.screen.center
                    h.lastA = math.atan2(-(px.y - c0.y), px.x - c0.x)
                    h.acc = 0
                    local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
                    h.t0 = { x = tl.x, z = tl.z }
                    local AX = axesFor(t.heading)
                    local A = h.axis == "x" and AX[1][1] or AX[3][1]
                    local _, cf = camBasis()
                    h.sign = dot(cf, A) <= 0 and 1 or -1
                elseif h.kind == "turn" then
                    local c0 = S.screen.center
                    h.lastA = math.atan2(-(px.y - c0.y), px.x - c0.x)
                    h.acc = 0
                    -- seen from above, turning the mouse anticlockwise turns the object anticlockwise
                    local _, cf = camBasis()
                    h.sign = cf.y <= 0 and 1 or -1
                end
                S.drag = h
                S.dragStats = { sent = 0, from = S.clock }
            else
                S.drag = { kind = "click", start = { px = px } }
            end
        elseif c.left and S.drag then
            local g, t = S.drag, S.target
            if g.kind == "click" or g.kind == "view" then
                if g.kind == "click" and d2(px, g.start.px) > 4 then g.kind = "view" end
                if g.kind == "view" then
                    S.cam.yaw -= dx * 0.005
                    S.cam.pitch = clamp(S.cam.pitch - dy * 0.005, -1.45, 1.45)
                end
            elseif t then
                local step = FN.kbDown("bigger") and 1 or 0.25
                local toObjects = S.osnap and not FN.kbDown("noSnap")
                S.guides = nil
                if g.kind == "axis" then
                    local along = ((px.x - g.start.px.x) * g.dir.x + (px.y - g.start.px.y) * g.dir.y) / g.ppm
                    if S.snap then along = round(along, step) end
                    local way = axesFor(g.start.heading)[g.axis][1]
                    t.pos = g.start.pos + way * along
                    if math.abs(way.y) > 0.9 then
                        -- the up arrow: lifted by hand, it stays at that height
                        -- (it catches on the ground when brought near it)
                        if math.abs(along) > 0.005 then t.pos = V(t.pos.x, FN.heightNear(t.pos.y), t.pos.z) end
                    elseif S.landOn and FN.mayLand(S.sel.id) and toObjects then
                        -- a level arrow: it sits on what is under it, like dragging it over the ground
                        if g.landTrust == nil then g.landTrust = FN.landTrust(S.sel.item, g.start.pos, g.start.heading, t.scale, S.sel.id) end
                        local okL, y = pcall(FN.supportY, S.sel.item, t.pos, g.start.heading, t.scale, S.sel.id)
                        if okL and y then
                            local ny, tr = FN.landTo(g.landTrust, t.pos.y, y)
                            t.pos = V(t.pos.x, ny, t.pos.z)
                        end
                    end
                    local ntl
                    if toObjects then t.pos, t.heading, S.guides, ntl = snapTurned(t.pos, g.start.heading, t.scale, allowAlong(way), g.start.tilt) else t.heading, ntl = g.start.heading, g.start.tilt end
                    S.tilt[S.sel.id] = ntl
                    g.moved = true
                elseif g.kind == "plane" then
                    local o, d = rayAt(px)
                    local hh = planeHit(o, d, g.start.pos, g.n)
                    if hh then
                        local off = hh - g.hit0
                        off = off - g.n * dot(off, g.n)
                        if S.snap then
                            local ax = axesFor(g.start.heading)
                            local o2 = V(0, 0, 0)
                            for i = 1, 3 do o2 += ax[i][1] * round(dot(off, ax[i][1]), step) end
                            off = o2
                        end
                        t.pos = g.start.pos + off
                        if math.abs(g.n.y) <= 0.9 and math.abs(off.y) > 0.005 then t.pos = V(t.pos.x, FN.heightNear(t.pos.y), t.pos.z) end
                        if S.landOn and math.abs(g.n.y) > 0.9 and FN.mayLand(S.sel.id) and toObjects then
                            if g.landTrust == nil then g.landTrust = FN.landTrust(S.sel.item, g.start.pos, g.start.heading, t.scale, S.sel.id) end
                            local okL, y, sl = pcall(FN.supportY, S.sel.item, t.pos, g.start.heading, t.scale, S.sel.id, true)
                            local tr = false
                            if okL and y then y, tr = FN.landTo(g.landTrust, t.pos.y, y) end
                            if tr then g.landTrust = true end
                            if okL and y and (g.landTrust or tr or y >= t.pos.y - 0.01) then
                                t.pos = V(t.pos.x, y, t.pos.z)
                                if g.landTrust then FN.takeSlope(S.sel.id, sl, function(v) g.start.tilt = v end) end
                            end
                        end
                        local ntl
                        if toObjects then t.pos, t.heading, S.guides, ntl = snapTurned(t.pos, g.start.heading, t.scale, allowIn(g.n), g.start.tilt) else t.heading, ntl = g.start.heading, g.start.tilt end
                        if math.abs(g.n.y) > 0.9 then t.pos = FN.gridSnap(t.pos, S.guides) end
                        S.tilt[S.sel.id] = ntl
                        g.moved = true
                    end
                elseif g.kind == "tilt" then
                    local c0 = S.screen.center or g.start.px
                    if d2(px, c0) > 6 then
                        local a = math.atan2(-(px.y - c0.y), px.x - c0.x)
                        g.acc += wrap(a - g.lastA) * g.sign
                        g.lastA = a
                        local v = wrap(g.t0[g.axis] + g.acc)
                        if S.snap then v = round(v, math.rad(FN.kbDown("bigger") and 45 or 15)) end
                        -- level again (or a quarter turn) when close to it
                        if toObjects and math.abs(v - round(v, math.pi / 2)) < SNAP_TURN then v = round(v, math.pi / 2) end
                        local tl = S.tilt[S.sel.id] or { x = 0, z = 0 }
                        S.tilt[S.sel.id] = { x = g.axis == "x" and v or tl.x, z = g.axis == "z" and v or tl.z }
                        g.moved = true
                    end
                elseif g.kind == "turn" then
                    local c0 = S.screen.center or g.start.px
                    if d2(px, c0) > 6 then
                        local a = math.atan2(-(px.y - c0.y), px.x - c0.x)
                        g.acc += wrap(a - g.lastA) * g.sign
                        g.lastA = a
                        local hd = g.start.heading + g.acc
                        if S.snap then hd = round(hd, math.rad(FN.kbDown("bigger") and 45 or 15)) end
                        if toObjects then hd, S.guides = FN.turnTo(hd) end
                        t.heading = wrap(hd)
                        g.moved = true
                    end
                elseif g.kind == "size" then
                    local k = d2(px, g.c0) / g.d0
                    local s = g.start.scale * k
                    if S.snap then s = round(s, 0.1) end
                    t.scale = clamp(s, 0.1, 10)
                    g.moved = true
                end
            end
            if S.drag and S.drag.moved and S.drag.kind ~= "tilt" then S.dirty = true end
        elseif not c.left and S.mouse.left and S.drag then
            if S.drag.kind == "click" then FN.clickPick(px, FN.kbDown("multi")) end
            local moved = S.drag.moved
            local wasTilt = S.drag.kind == "tilt"
            S.snapLock = nil
            S.drag = nil
            if wasTilt then
                if moved then S.tiltSaveDue = true end
                moved = false
            end
            if moved and S.osnap and not FN.kbDown("noSnap") then armTighten(S.guides) end
            S.guides = nil
            local st = S.dragStats
            if st and moved then
                S.dragStats = nil
                reskate.log(string.format("Quick Drop helper: drag of %.1f s: %d moves taken, %d refused as still applying, %d as more than 4 a second, %d other",
                    (S.clock - st.from) / 1000, st.sent, st["the last edit is still being applied"] or 0, st["more than 4 edits in a second"] or 0, st.other or 0))
            end
            if moved then S.dirty = true; if not sameAsSent(S.target) then S.lastSend = math.min(S.lastSend, S.clock - 250) end end
        end
        if (c.right or c.middle) and not c.over_screen and S.mouse.pos then
            local _, _, r, u = camBasis()
            local k = S.cam.dist * 0.0014
            S.cam.goal = (S.cam.goal or S.cam.target) + r * (-dx * k) + u * (dy * k)
            S.cam.target += r * (-dx * k) + u * (dy * k)
        end
        S.mouse = { pos = px, left = c.left }
    end

    camGlide(sec)
    local pos, f, _, u = camBasis()
    reskate.camera.set(pos, f, u, S.cam.fov)
    send()
end

-- Problems, said in the game as well as in the log: a fault (each kind written to the log once, with how often it
-- came again; a notice on screen at most every 20 s), and running close to ReSkate's time limit (a notice at most
-- once a minute), so it is seen before ReSkate stops the plugin.
S.problems = {}
function FN.problem(where, err)
    local key = where .. ": " .. tostring(err)
    local p = S.problems[key]
    if p then p.n += 1; return end
    S.problems[key] = { n = 1 }
    reskate.log("Quick Drop helper: " .. key, "warn")
    local now = S.clock or 0
    if now - (S.problemSaidAt or -1e9) > 20000 then
        S.problemSaidAt = now
        pcall(reskate.ui.toast, "DDH Park Editor: a problem in " .. where .. ". It keeps running; details are in ReSkate.log.", "warn")
    end
end
local BUSY_MS = 4.8          -- of the 6 ms a tick ReSkate allows on average
-- the tick, timed: how long the editor's own work takes (the tick less the scanning), so scanning can use what
-- is left of ReSkate's 6 ms a tick (see part15_scan)
local okClock = pcall(function() return os.clock() end)
reskate.on("tick", function(dt)
    if not okClock then
        local ok, err = pcall(tickBody, dt)
        if not ok then FN.problem("the tick", err) end
        return
    end
    local t0 = os.clock()
    S.scanMsTick = 0
    local ok, err = pcall(tickBody, dt)
    if not ok then FN.problem("the tick", err) end
    local all = (os.clock() - t0) * 1000
    local other = all - (S.scanMsTick or 0)
    -- (an average over a few ticks, and a spike counted at once)
    S.otherMs = math.max(other, (S.otherMs or other) * 0.9 + other * 0.1)
    -- the whole tick over about 3 s, scanning and all: close to the limit, said once a minute
    S.avgMs = (S.avgMs or 0) * 0.98 + all * 0.02
    if S.avgMs > BUSY_MS and (S.clock or 0) - (S.busySaidAt or -1e9) > 60000 then
        S.busySaidAt = S.clock or 0
        reskate.log(string.format("Quick Drop helper: busy: %.1f ms a tick on average (ReSkate stops a plugin past 6)", S.avgMs), "warn")
        pcall(reskate.ui.toast, string.format("DDH Park Editor is busy: %.1f ms a tick of the 6 allowed. Fewer objects in view or in the group helps.", S.avgMs), "warn")
    end
end)

end
