-- DDH Park Editor, part18_modshapes: the exact shapes the DDH Object Maker writes into the mods it builds
-- (ddh_shapes/ in each mod: index.json with each object's box and outline seen from above, and one file per object
-- with its model's edges, in millimetres). Read from the installed mods with ReSkate's mods.read_content (the
-- plugin's manifest names "ddh_shapes" in its "content"), so any player with an Object Maker mod gets its objects'
-- real outlines and snapping. They win over the built-in sizes.lua / wires.lua (made once, from older models).
-- Loaded by main.lua in order. PE holds what the parts share.
return function(PE)

local FN = PE.FN
local S = PE.S
local V = PE.V
local UI = PE.UI
local UP = PE.UP or V(0, 1, 0)

local DIR = "ddh_shapes"
S.modShape = {}    -- item -> { mod = folder }: its edges are read from that mod the first time they are drawn
S.modWire = {}     -- item -> its edges (metres), or false when they could not be read
local SHOWN = 0

local function log(msg, level) reskate.log("Quick Drop helper: mod outlines: " .. msg, level) end

-- a file in a mod's ddh_shapes folder, as text. ReSkate's mods.read_content(mod, "ddh_shapes", path) (path inside
-- that folder, as mods.content lists them); other ways of calling it tried once each, the one that works kept
local FORMS = {
    function(mod, path) return reskate.mods.read_content(mod, DIR, path) end,
    function(mod, path) return reskate.mods.read_content(DIR, path, mod) end,
    function(mod, path) return reskate.mods.read_content({ mod = mod, path = path }) end,
    function(mod, path) return reskate.mods.read_content(DIR, mod, path) end,
}
local form = nil
local function readText(mod, path)
    if not (reskate.mods and reskate.mods.read_content) then return nil, "this ReSkate can't read mods" end
    local function try(f)
        local ok, a, b = pcall(f, mod, path)
        if not ok then return nil, tostring(a) end
        if type(a) == "string" then return a end
        if type(b) == "string" and a ~= false and a ~= nil then return b end
        if type(a) == "table" and type(a.text or a.data) == "string" then return a.text or a.data end
        return nil, tostring(b or a)
    end
    if form then return try(FORMS[form]) end
    local why = {}
    for i, f in ipairs(FORMS) do
        local txt, w = try(f)
        if txt then
            form = i
            log("reading with form " .. i)
            return txt
        end
        why[#why + 1] = w
    end
    return nil, table.concat(why, " | ")
end

local function decode(txt)
    if type(txt) ~= "string" then return nil end
    local ok, t = pcall(reskate.json.decode, txt)
    if ok and type(t) == "table" then return t end
    return nil
end

-- the mods with a ddh_shapes folder (mods.content: { mod, path, size, title } for every file in one)
local function modFolders()
    local out, seen = {}, {}
    if not (reskate.mods and reskate.mods.content) then return out end
    local ok, t = pcall(reskate.mods.content, DIR)
    if not ok then log("content: " .. tostring(t), "warn") return out end
    if type(t) ~= "table" then return out end
    for _, e in pairs(t) do
        local m = type(e) == "table" and e.mod
        if type(m) == "string" and not seen[m] and e.path == "index.json" then
            seen[m] = true
            out[#out + 1] = m
        end
    end
    return out
end

local function applyOne(mod, item, d)
    do
        local b = type(d) == "table" and d.box
        if type(item) == "string" and type(b) == "table" and #b == 6 then
            local lo, hi = V(b[1], b[2], b[3]), V(b[4], b[5], b[6])
            S.itemBox[item] = { lo, hi }
            S.exactBox[item] = S.itemBox[item]
            S.exact[item] = true
            local ol = d.outline
            if type(ol) == "table" and #ol >= 6 then
                local pts = {}
                for i = 1, #ol - 1, 2 do pts[#pts + 1] = V(ol[i], 0, ol[i + 1]) end
                S.itemShape[item] = pts
            end
            S.modShape[item] = { mod = mod }
            S.modWire[item] = nil
            if S.wireCache then S.wireCache[item] = nil end
            return true
        end
    end
    return false
end

-- Loading, a little each frame (ReSkate allows a plugin 50 ms to start and about 6 ms a frame): first which mods
-- have shapes, then one mod's index read per frame, then its objects taken in, 20 a frame.
local job = nil
function FN.loadModShapes()
    if not (reskate.mods and reskate.mods.read_content) then
        log("this ReSkate can't read other mods' files: the built-in outlines are used")
        return
    end
    job = { at = 1, found = 0, objs = 0, errs = {} }
end
local function loadStep()
    local j = job
    if not j then return end
    if not j.mods then j.mods = modFolders() return end
    if j.items then
        -- taking in the objects of the mod just read
        local k = 0
        while k < 20 and j.items[j.ii] do
            local e = j.items[j.ii]
            if applyOne(j.mod, e[1], e[2]) then j.n += 1 end
            j.ii += 1
            k += 1
        end
        if not j.items[j.ii] then
            log(string.format("%d objects from %s", j.n, j.mod))
            j.found += 1
            j.objs += j.n
            j.items = nil
        end
        return
    end
    local mod = j.mods[j.at]
    if not mod then
        log(string.format("%d objects from %d mods (of %d looked at)", j.objs, j.found, #j.mods))
        if j.found == 0 and #j.errs > 0 then log("could not read: " .. table.concat(j.errs, " | "), "warn") end
        job = nil
        return
    end
    j.at += 1
    local txt, why = readText(mod, "index.json")
    if not txt and #j.errs < 3 then j.errs[#j.errs + 1] = mod .. ": " .. tostring(why) end
    local t = decode(txt)
    if t and t.format == "ddh-shapes" and type(t.items) == "table" then
        j.mod, j.items, j.ii, j.n = mod, {}, 1, 0
        for item, d in pairs(t.items) do j.items[#j.items + 1] = { item, d } end
    end
end
-- (called from the tick, part12)
function FN.modShapesTick()
    if job then
        local ok, err = pcall(loadStep)
        if not ok then log(tostring(err), "warn"); job = nil end
    end
end

-- an object's file from its mod, read the first time it is drawn: its edges (metres, as wires.lua's) and its
-- slimmed model (corners and triangles, with which edge has which faces: for the silhouette)
S.modMesh = {}     -- item -> { v = { V... }, t = { {a,b,c}... }, e = { {a,b,f1,f2...}... } }, or false
local function readItem(item, src)
    if S.modWire[item] ~= nil then return end
    local t = decode((readText(src.mod, item .. ".json")))
    local str = t and t.edges
    if type(str) ~= "string" or str == "" then
        S.modWire[item], S.modMesh[item] = false, false
        if SHOWN < 5 then SHOWN += 1; log("no edges for " .. item .. " in " .. src.mod, "warn") end
        return
    end
    local a = {}
    for num in string.gmatch(str, "-?%d+") do a[#a + 1] = tonumber(num) * 0.001 end
    S.modWire[item] = #a >= 6 and a or false
    -- the model: corners (mm) and triangles
    local vs, ts = t.verts, t.tris
    S.modMesh[item] = false
    if type(vs) == "string" and type(ts) == "string" and vs ~= "" and ts ~= "" then
        local nums, vv, tt = {}, {}, {}
        for num in string.gmatch(vs, "-?%d+") do nums[#nums + 1] = tonumber(num) * 0.001 end
        for i = 1, #nums - 2, 3 do vv[#vv + 1] = V(nums[i], nums[i + 1], nums[i + 2]) end
        local ids = {}
        for num in string.gmatch(ts, "%d+") do ids[#ids + 1] = tonumber(num) + 1 end
        local nv = #vv
        for i = 1, #ids - 2, 3 do
            local x, y, z = ids[i], ids[i + 1], ids[i + 2]
            if x <= nv and y <= nv and z <= nv then tt[#tt + 1] = { x, y, z } end
        end
        if #tt > 0 then
            -- each edge once, with the triangles on it
            local eid, edges = {}, {}
            for fi, tr in ipairs(tt) do
                for k = 1, 3 do
                    local p, q = tr[k], tr[k % 3 + 1]
                    if p > q then p, q = q, p end
                    local key = p * 65536 + q
                    local e = eid[key]
                    if not e then e = { p, q }; eid[key] = e; edges[#edges + 1] = e end
                    e[#e + 1] = fi
                end
            end
            S.modMesh[item] = { v = vv, t = tt, e = edges }
        end
    end
end
local baseWire = FN.wireOf
function FN.wireOf(item)
    local src = item and S.modShape[item]
    if not src then return baseWire(item) end
    readItem(item, src)
    return S.modWire[item] or baseWire(item)
end
function FN.meshOf(item)
    local src = item and S.modShape[item]
    if not src then return nil end
    readItem(item, src)
    return S.modMesh[item] or nil
end

-- ---------------------------------------------------------------- the silhouette, drawn like Quick Drop's
-- The game outlines an object from its model as seen from the camera (a line round its shape, and over a held one a
-- see-through fill). The same here, from the slimmed model: the lines are the edges where the model turns from
-- facing the camera to facing away (and its open edges); the fill is its faces towards the camera.
-- Triangles worked through in one frame at most (past it, the rest are drawn as before)
local SIL_BUDGET = 9000
local silAt, silUsed = -1, 0
local polyOk = true
local function fillColour(col)
    local c = tostring(col or "#ffffff")
    return string.sub(c, 1, 7) .. "38"
end
local function drawSilhouette(d, sh, col, th, xf)
    local m = FN.meshOf(sh.item)
    if not (m and sh.p and sh.ax and sh.az) then return false end
    local nt = #m.t
    if silAt ~= S.clock then silAt, silUsed = S.clock, 0 end
    if silUsed + nt > SIL_BUDGET then return false end
    silUsed += nt
    local sc = sh.scale or 1
    local p, X, Y, Z = sh.p, sh.ax * sc, UP * sc, sh.az * sc
    local cam = PE.camBasis()
    -- the corners where they are now
    local w = {}
    for i, v in ipairs(m.v) do
        local q = p + X * v.x + Y * v.y + Z * v.z
        if xf then q = xf(q) end
        w[i] = q
    end
    -- which triangles face the camera
    local front = {}
    for i, tr in ipairs(m.t) do
        local a, b, c = w[tr[1]], w[tr[2]], w[tr[3]]
        local u, v2 = b - a, c - a
        local n = V(u.y * v2.z - u.z * v2.y, u.z * v2.x - u.x * v2.z, u.x * v2.y - u.y * v2.x)
        local to = cam - a
        front[i] = (n.x * to.x + n.y * to.y + n.z * to.z) > 0
    end
    -- the see-through fill (a held object): its faces towards the camera
    if sh.fill and polyOk then
        local scr = {}
        local style = { colour = fillColour(col), fill = true }
        for i, tr in ipairs(m.t) do
            if front[i] then
                local pts = {}
                for k = 1, 3 do
                    local vi = tr[k]
                    local s2 = scr[vi]
                    if s2 == nil then s2 = d:world_to_screen(w[vi]) or false; scr[vi] = s2 end
                    pts[k] = s2
                end
                if pts[1] and pts[2] and pts[3] then
                    local ok = pcall(d.poly, d, pts, style)
                    if not ok then polyOk = false break end
                end
            end
        end
    end
    -- the outline
    local style = { colour = col, thickness = th }
    for _, e in ipairs(m.e) do
        local f1 = e[3]
        local edge = #e == 3   -- (an open edge: one triangle)
        if not edge then
            local f = front[f1]
            for k = 4, #e do if front[e[k]] ~= f then edge = true break end end
        end
        if edge then d:world_line(w[e[1]], w[e[2]], style) end
    end
    return true
end
do
    local baseDraw = PE.drawShape
    PE.drawShape = function(d, sh, col, th, xf)
        if sh and sh.item and S.modShape[sh.item] then
            local ok, done = pcall(drawSilhouette, d, sh, col, th, xf)
            if ok and done then return true end
            if not ok and SHOWN < 8 then SHOWN += 1; log("drawing: " .. tostring(done), "warn") end
        end
        return baseDraw(d, sh, col, th, xf)
    end
end

do
    local ok, err = pcall(FN.loadModShapes)
    if not ok then log(tostring(err), "warn") end
end

end
