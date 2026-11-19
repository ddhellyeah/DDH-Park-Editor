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

reskate.on("tick", function(dt)
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

    if not S.open then
        -- the controller: hold LB and press D-pad right to open the editor
        local pd = FN.readPad()
        if pd then
            local rightNow = pd.right == true
            if pd.lb and rightNow and not S.padOpenRight and S.clock - (S.closedAt or -1e9) > 400 then
                S.padOpenRight = true
                FN.openEditor()
                return
            end
            S.padOpenRight = rightNow
        end
        -- quick keys while skating: hold Ctrl
        if reskate.input.allowed() and reskate.input.key("Ctrl") and S.target then
            local fine = reskate.input.key("Shift")
            local v = reskate.camera.get()
            local f = v and flat(v.forward) or V(0, 0, 1)
            local r = V(-f.z, 0, f.x) * -1
            if v and v.right then r = flat(v.right) end
            local t = S.target
            local function ch(fn) markUndo(); fn(); S.dirty = true end
            local st = fine and 0.01 or 0.1
            if press("[") then ch(function() local s = math.rad(fine and 1 or 15); t.heading = wrap(round(t.heading + s, s)) end) end
            if press("]") then ch(function() local s = math.rad(fine and 1 or 15); t.heading = wrap(round(t.heading - s, s)) end) end
            if press("PageUp") then ch(function() t.pos += V(0, fine and 0.01 or 0.05, 0); FN.markLifted() end) end
            if press("PageDown") then ch(function() t.pos -= V(0, fine and 0.01 or 0.05, 0); FN.markLifted() end) end
            if press("X") then ch(function() t.scale = clamp(t.scale + (fine and 0.01 or 0.1), 0.1, 10) end) end
            if press("Z") then ch(function() t.scale = clamp(t.scale - (fine and 0.01 or 0.1), 0.1, 10) end) end
            if press("Up") then ch(function() t.pos += f * st end) end
            if press("Down") then ch(function() t.pos -= f * st end) end
            if press("Right") then ch(function() t.pos += r * st end) end
            if press("Left") then ch(function() t.pos -= r * st end) end
            if press("U") then undo() end
        else
            for _, k in ipairs({ "[", "]", "PageUp", "PageDown", "X", "Z", "Up", "Down", "Right", "Left", "U" }) do S.held[k] = false end
        end
        send()
        return
    end

    -- the editor: keys (none while the text box is open)
    if S.typing then send(); return end
    local ctrl = reskate.input.key("Ctrl")
    if press("W") then S.mode = 1 end
    if press("E") then S.mode = 2 end
    if press("R") then S.mode = 3 end
    if press("G") then S.snap = not S.snap end
    if press("T") then S.osnap = not S.osnap; say(S.osnap and "Snap to objects on" or "Snap to objects off") end
    if press("Tab") and S.sel then FN.cycleSnap() end
    if press("F") and S.target then S.cam.goal = S.target.pos end
    if press("Z") and ctrl then if reskate.input.key("Shift") then redo() else undo() end end
    if press("Y") and ctrl then redo() end
    do -- the view: arrows and PageUp / PageDown slide it
        local _, f, r = camBasis()
        local sp = math.max(S.cam.dist, 3) * (reskate.input.key("Shift") and 2.5 or 0.8) * sec
        local mv = V(0, 0, 0)
        if reskate.input.key("Up") then mv += flat(f) end
        if reskate.input.key("Down") then mv -= flat(f) end
        if reskate.input.key("Right") then mv += flat(r) end
        if reskate.input.key("Left") then mv -= flat(r) end
        if reskate.input.key("PageUp") then mv += V(0, 1, 0) end
        if reskate.input.key("PageDown") then mv -= V(0, 1, 0) end
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
    if c and ((S.mouse.pos and d2(c.position, S.mouse.pos) > 3) or c.left or c.right or (c.wheel and c.wheel ~= 0)) then S.mouseUsedAt = S.clock end
    if c and S.controlsOpen then
        pcall(UI.controlsMouse, c)
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
                local step = reskate.input.key("Shift") and 1 or 0.25
                local toObjects = S.osnap and not reskate.input.key("Ctrl")
                S.guides = nil
                if g.kind == "axis" then
                    local along = ((px.x - g.start.px.x) * g.dir.x + (px.y - g.start.px.y) * g.dir.y) / g.ppm
                    if S.snap then along = round(along, step) end
                    local way = axesFor(g.start.heading)[g.axis][1]
                    t.pos = g.start.pos + way * along
                    if math.abs(way.y) > 0.9 then
                        -- the up arrow: lifted by hand, it stays at that height
                        if math.abs(along) > 0.005 then FN.markLifted() end
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
                        if math.abs(g.n.y) <= 0.9 and math.abs(off.y) > 0.005 then FN.markLifted() end
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
                        if S.snap then v = round(v, math.rad(reskate.input.key("Shift") and 45 or 15)) end
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
                        if S.snap then hd = round(hd, math.rad(reskate.input.key("Shift") and 45 or 15)) end
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
            if S.drag.kind == "click" then FN.clickPick(px, reskate.input.key("Ctrl")) end
            local moved = S.drag.moved
            local wasTilt = S.drag.kind == "tilt"
            S.snapLock = nil
            S.drag = nil
            if wasTilt then
                if moved then S.tiltSaveDue = true end
                moved = false
            end
            if moved and S.osnap and not reskate.input.key("Ctrl") then armTighten(S.guides) end
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
end)

end
