-- DDH Park Editor, part10_sets: sets: saving a build and placing it anywhere.
-- Loaded by main.lua in order. PE holds what the parts share: what this part uses from the parts before it
-- is taken from PE here, and what it makes that later parts use is put in PE at the end.
return function(PE)

local FN = PE.FN
local S = PE.S
local UI = PE.UI
local V = PE.V
local clamp = PE.clamp
local len = PE.len
local localOutline = PE.localOutline
local poseOf = PE.poseOf
local rotY = PE.rotY
local say = PE.say
local select = PE.select
local snapTurned = PE.snapTurned
local startGrab = PE.startGrab
local wrap = PE.wrap

-- ---------------------------------------------------------------- sets: a group saved to place again later (any map, any server)
-- Saved as files in the plugin's data folder ("sets/<name>.json"), so they can be shared: send the file, a friend
-- puts it in their own sets folder. Each object: its item, place and turn next to the set's middle, size and tilt.
;(function()
    local FOLDER = "sets"
    local function safeName(n)
        n = string.gsub(tostring(n), "[^%w%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #n > 40 then n = string.sub(n, 1, 40) end
        return n
    end
    function S.loadSets()
        local out = {}
        local ok, lst = pcall(reskate.files.list, FOLDER)
        if ok and type(lst) == "table" then
            for _, e in ipairs(lst) do
                local name = type(e) == "table" and (e.name or e.path) or e
                name = tostring(name)
                local base = string.match(name, "([^/\\]+)$") or name
                if string.lower(string.sub(base, -5)) == ".json" then
                    local okr, txt = pcall(reskate.files.read, FOLDER .. "/" .. base)
                    if okr and type(txt) == "string" then
                        local okd, data = pcall(reskate.json.decode, txt)
                        if okd and type(data) == "table" and type(data.objects) == "table" and #data.objects > 0 then
                            out[#out + 1] = { name = tostring(data.name or string.sub(base, 1, -6)), file = base, objects = data.objects }
                        end
                    end
                end
            end
        end
        table.sort(out, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
        S.sets = out
        S.setsAt = S.clock
        return out
    end
    -- what would be saved: the group (with the picked one), or just the picked object
    local function members()
        local list = {}
        local seen = {}
        local function add(id, p)
            local o = S.known and S.known[id]
            if o and p and not seen[id] then
                seen[id] = true
                local tl = S.tilt[id]
                list[#list + 1] = { id = id, item = o.item, pos = p.pos, heading = p.heading, scale = p.scale, tilt = tl }
            end
        end
        if S.sel and S.target then add(S.sel.id, S.target) end
        for id in pairs(S.group) do add(id, poseOf(id)) end
        return list
    end
    S.setMembers = members
    function S.saveSet(name)
        local list = members()
        if #list == 0 then say("Pick an object or make a group first, then save it as a set.", true) return end
        name = safeName(name)
        if name == "" then say("A set needs a name.", true) return end
        -- the middle (x, z) at the lowest point, turned like the first one
        local lo, hi, ymin = V(math.huge, 0, math.huge), V(-math.huge, 0, -math.huge), math.huge
        for _, m in ipairs(list) do
            lo = V(math.min(lo.x, m.pos.x), 0, math.min(lo.z, m.pos.z)); hi = V(math.max(hi.x, m.pos.x), 0, math.max(hi.z, m.pos.z))
            ymin = math.min(ymin, m.pos.y)
        end
        local O = V((lo.x + hi.x) / 2, ymin, (lo.z + hi.z) / 2)
        local h0 = list[1].heading
        local objs = {}
        for _, m in ipairs(list) do
            local off = rotY(m.pos - O, -h0)
            local e = { item = m.item, x = math.floor(off.x * 1000 + 0.5) / 1000, y = math.floor(off.y * 1000 + 0.5) / 1000, z = math.floor(off.z * 1000 + 0.5) / 1000,
                h = math.floor(wrap(m.heading - h0) * 1e5 + 0.5) / 1e5, s = math.floor(m.scale * 1000 + 0.5) / 1000 }
            if m.tilt then e.tx, e.tz = m.tilt.x, m.tilt.z end
            e.mod = S.modOfItem(m.item)
            objs[#objs + 1] = e
        end
        local data = { format = "ddh-park-set", version = 1, name = name, objects = objs }
        local file = string.gsub(name, " ", "_") .. ".json"
        local ok, why = pcall(reskate.files.write, FOLDER .. "/" .. file, reskate.json.encode(data, true))
        if not ok or why == false then say("Set not saved: " .. tostring(why), true) return end
        S.loadSets()
        say(string.format("Saved the set \"%s\" (%d object%s). Find it under Sets, or in Add object.", name, #objs, #objs == 1 and "" or "s"))
        reskate.log(string.format("Quick Drop helper: saved set %s with %d objects", file, #objs))
    end
    function S.renameSetFn(set, newName)
        newName = safeName(newName)
        if newName == "" then say("A set needs a name.", true) return end
        local data = { format = "ddh-park-set", version = 1, name = newName, objects = set.objects }
        local file = string.gsub(newName, " ", "_") .. ".json"
        local ok, why = pcall(reskate.files.write, FOLDER .. "/" .. file, reskate.json.encode(data, true))
        if not ok or why == false then say("Not renamed: " .. tostring(why), true) return end
        if file ~= set.file then pcall(reskate.files.remove, FOLDER .. "/" .. set.file) end
        S.loadSets()
        say("Renamed to \"" .. newName .. "\".")
    end
    function S.deleteSet(set)
        local ok = pcall(reskate.files.remove, FOLDER .. "/" .. set.file)
        S.loadSets()
        say(ok and ("Deleted the set \"" .. set.name .. "\".") or "Could not delete it.", not ok)
    end
    -- the mod an object comes from, by name (nil when not known): the game's catalog when it says, else the mod
    -- whose Object Maker outlines have it (part18)
    local MODFIELDS = { "mod", "mod_title", "modTitle", "mod_name", "modName", "source", "package", "pack", "owner" }
    local catByKey, catLogged = nil, false
    local function cleanMod(v)
        if type(v) == "table" then v = v.title or v.name or v.id end
        if type(v) ~= "string" then return nil end
        v = string.gsub(v, "[^%w%-_ %.%(%)!&'+]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if v == "" then return nil end
        return #v > 40 and string.sub(v, 1, 40) or v
    end
    function S.modOfItem(key)
        local cl = FN.catalog()
        if catByKey == nil or catByKey.__list ~= cl then
            catByKey = { __list = cl }
            for _, it in ipairs(cl) do if type(it) == "table" and it.key then catByKey[it.key] = it end end
        end
        local it = catByKey[key]
        if it then
            if not catLogged then
                catLogged = true
                local f = {}
                for k in pairs(it) do f[#f + 1] = tostring(k) end
                table.sort(f)
                reskate.log("Quick Drop helper: a catalog item has: " .. table.concat(f, ", "))
            end
            for _, k in ipairs(MODFIELDS) do
                local m = cleanMod(it[k])
                if m then return m end
            end
        end
        local ms = S.modShape and S.modShape[key]
        if ms and ms.mod then return cleanMod((S.modTitle and S.modTitle[ms.mod]) or ms.mod) end
        return nil
    end
    -- "2 from Fixing Size, 1 from a mod not named" for the objects of a set that are not installed
    function S.missingText(objs, quiet)
        local have, by, order, n = FN.catalogHave(), {}, {}, 0
        for _, o in ipairs(objs) do
            if not have[o.item] then
                n += 1
                local m = o.mod or "?"
                if not by[m] then by[m] = 0; order[#order + 1] = m end
                by[m] += 1
            end
        end
        if n == 0 then return 0, "" end
        table.sort(order, function(a, b) if (a == "?") ~= (b == "?") then return b == "?" end return by[a] > by[b] end)
        local parts = {}
        for i, m in ipairs(order) do
            if i > 3 then parts[#parts + 1] = string.format("%d more mod%s", #order - 3, #order - 3 == 1 and "" or "s") break end
            parts[#parts + 1] = string.format("%d from %s", by[m], m == "?" and "a mod the set doesn't name" or ("\"" .. m .. "\""))
        end
        local all = {}
        for _, m in ipairs(order) do all[#all + 1] = (m == "?" and "unnamed" or m) .. " x" .. by[m] end
        if not quiet then reskate.log("Quick Drop helper: set objects missing: " .. table.concat(all, "; ")) end
        return n, table.concat(parts, ", ")
    end
    -- a set's missing objects in short ("2 from "Test Rail Pack", 1 from ..."), "" when none; worked out again when
    -- the sets are read again (or the game's objects change)
    function S.setMissing(set)
        local have = FN.catalogHave()
        if set._missFor ~= have then
            local n, text = S.missingText(set.objects, true)
            -- (and a shorter list for the Sets tab: "Test Rail Pack (2), unknown mod (1)")
            local by, order = {}, {}
            for _, o in ipairs(set.objects) do
                if not have[o.item] then
                    local m = o.mod or "unknown mod"
                    if not by[m] then by[m] = 0; order[#order + 1] = m end
                    by[m] += 1
                end
            end
            table.sort(order, function(a, b) return by[a] > by[b] end)
            local sh = {}
            for _, m in ipairs(order) do sh[#sh + 1] = m .. " (" .. by[m] .. ")" end
            set._missFor, set._missN, set._miss, set._missShort = have, n, text, table.concat(sh, ", ")
        end
        return set._miss, set._missN, set._missShort
    end
    -- ---- sharing a set as a code: one line of text to paste in a chat; Import code makes it a set again.
    -- ReSkate's text box holds 256 letters, so the code is kept short:
    -- SET2|name|item[:m],item,...|i,x,y,z,h[,s[,tx,tz]];...|mod,mod,...
    --   numbers in base 62 (0-9 a-z A-Z, "-" before negative ones, nothing for 0); positions in mm, turns and tilts
    --   in 1/100 degree, size in 1/1000 (left out when 1); m: which of the mods at the end the item comes from.
    --   Items named like the Object Maker's (own_<name>____00001, 43 letters) are written as just <name>; others
    --   start with "=" and have their runs of 3 or more "_" written ~n~.
    -- A code too long for the box goes in a text file instead: Share saves it in sets/codes, and Import takes every
    -- code file put in sets/import. (SET1 and DDHSET1 codes from before still import.)
    local BOXMAX = 256
    local CODES, INBOX = FOLDER .. "/codes", FOLDER .. "/import"
    local B62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local B62I = {}
    for i = 1, #B62 do B62I[string.sub(B62, i, i)] = i - 1 end
    local function enc(n)
        n = math.floor(n + 0.5)
        if n == 0 then return "" end
        local neg = n < 0
        if neg then n = -n end
        local t = ""
        while n > 0 do local d = n % 62; t = string.sub(B62, d + 1, d + 1) .. t; n = math.floor((n - d) / 62) end
        return neg and ("-" .. t) or t
    end
    local function dec(s)
        if s == nil or s == "" then return 0 end
        local neg = string.sub(s, 1, 1) == "-"
        if neg then s = string.sub(s, 2) end
        local n = 0
        for i = 1, #s do
            local d = B62I[string.sub(s, i, i)]
            if not d then return nil end
            n = n * 62 + d
        end
        return neg and -n or n
    end
    local function packKey(k) return (string.gsub(k, "(___+)", function(r) return "~" .. #r .. "~" end)) end
    local function unpackKey(k) return (string.gsub(k, "~(%d+)~", function(n) return string.rep("_", math.min(tonumber(n) or 0, 64)) end)) end
    local function shortKey(k)
        local name = #k == 43 and string.match(k, "^own_(.-)_+00001$")
        if name and name ~= "" and not string.find(name, "[^%w_]") and string.sub(name, -1) ~= "_" then
            local back = "own_" .. name .. string.rep("_", 38 - 4 - #name) .. "00001"
            if back == k then return name end
        end
        return "=" .. packKey(k)
    end
    local function longKey(t)
        if string.sub(t, 1, 1) == "=" then return unpackKey(string.sub(t, 2)) end
        if #t > 34 then return t end
        return "own_" .. t .. string.rep("_", 38 - 4 - #t) .. "00001"
    end
    local function r(v, k) return math.floor((tonumber(v) or 0) * k + 0.5) end
    function S.setCode(set)
        local keys, idx, parts, mods, midx = {}, {}, {}, {}, {}
        for _, e in ipairs(set.objects) do
            local key = tostring(e.item)
            if not idx[key] then
                local m = cleanMod(e.mod) or S.modOfItem(key)
                local k = shortKey(key)
                if m then
                    if not midx[m] then mods[#mods + 1] = m; midx[m] = #mods end
                    k = k .. ":" .. midx[m]
                end
                keys[#keys + 1] = k; idx[key] = #keys
            end
            local t = { enc(idx[key]), enc(r(e.x, 1000)), enc(r(e.y, 1000)), enc(r(e.z, 1000)), enc(r(math.deg(e.h or 0), 100)) }
            local s = r(e.s or 1, 1000)
            local tx, tz = r(math.deg(e.tx or 0), 100), r(math.deg(e.tz or 0), 100)
            if s ~= 1000 or tx ~= 0 or tz ~= 0 then t[6] = enc(s) end
            if tx ~= 0 or tz ~= 0 then t[7], t[8] = enc(tx), enc(tz) end
            -- (zeros at the end left out)
            while #t > 1 and t[#t] == "" do t[#t] = nil end
            parts[#parts + 1] = table.concat(t, ",")
        end
        local code = "SET2|" .. safeName(set.name) .. "|" .. table.concat(keys, ",") .. "|" .. table.concat(parts, ";")
        if #mods > 0 then code = code .. "|" .. table.concat(mods, ",") end
        return code
    end
    -- fields split on a separator, empty ones kept
    local function split(s, sep)
        local out, from = {}, 1
        while true do
            local at = string.find(s, sep, from, true)
            if not at then out[#out + 1] = string.sub(s, from) break end
            out[#out + 1] = string.sub(s, from, at - 1)
            from = at + 1
        end
        return out
    end
    -- a code back into a set (nil and why when it is not one)
    local function readCode(code)
        -- (line breaks a chat may have put in taken out; the name keeps its spaces)
        code = string.gsub(tostring(code or ""), "[\r\n\t]", "")
        code = string.gsub((string.gsub(code, "^%s+", "")), "%s+$", "")
        code = (string.gsub(code, "^DDHSET1|", "SET1|"))
        local f = split(code, "|")
        local ver = f[1]
        if (ver ~= "SET1" and ver ~= "SET2") or #f < 4 then return nil, "That is not a set code (it starts with SET2)." end
        local name, keyS, objS, modS = f[2], f[3], f[4], f[5]
        local new = ver == "SET2"
        local mods = {}
        for m in string.gmatch(modS or "", "[^,]+") do mods[#mods + 1] = cleanMod(m) or false end
        local keys, keyMod = {}, {}
        for k in string.gmatch(keyS, "[^,]+") do
            local kk, mi = string.match(k, "^(.-):(%d+)$")
            kk = kk or k
            keys[#keys + 1] = new and longKey(kk) or unpackKey(kk)
            keyMod[#keys] = mi and mods[tonumber(mi)] or nil
        end
        local objs = {}
        for e in string.gmatch(objS, "[^;]+") do
            local n, bad = {}, false
            for i, v in ipairs(split(e, ",")) do
                if new then n[i] = dec(v) else n[i] = tonumber(v) end
                if n[i] == nil then bad = true end
            end
            if new then
                for i = 2, 5 do n[i] = n[i] or 0 end
                if n[6] == nil or n[6] == 0 then n[6] = 1000 end
            end
            local key = not bad and n[1] and keys[n[1]]
            if key and n[2] and n[3] and n[4] and n[5] and n[6] then
                local o = { item = key, x = n[2] / 1000, y = n[3] / 1000, z = n[4] / 1000, h = math.rad(n[5] / 100), s = n[6] / 1000 }
                if (n[7] and n[7] ~= 0) or (n[8] and n[8] ~= 0) then o.tx, o.tz = math.rad((n[7] or 0) / 100), math.rad((n[8] or 0) / 100) end
                o.mod = keyMod[n[1]] or nil
                objs[#objs + 1] = o
            end
        end
        if #objs == 0 then return nil, "That code has no objects in it (is all of it pasted?)." end
        name = safeName(name)
        if name == "" then name = "Shared set" end
        return { name = name, objects = objs }
    end
    -- a code made a saved set; quiet: no message, just what happened (name, objects, missing count, missing text)
    local function importOne(code)
        local set, why = readCode(code)
        if not set then return nil, why end
        -- (a name not taken yet)
        S.loadSets()
        local taken = {}
        for _, s2 in ipairs(S.sets or {}) do taken[string.lower(s2.name)] = true end
        local name, n = set.name, 2
        while taken[string.lower(name)] do name = set.name .. " " .. n; n += 1 end
        local data = { format = "ddh-park-set", version = 1, name = name, objects = set.objects }
        local file = string.gsub(name, " ", "_") .. ".json"
        local ok, err = pcall(reskate.files.write, FOLDER .. "/" .. file, reskate.json.encode(data, true))
        if not ok or err == false then return nil, "Set not imported: " .. tostring(err) end
        S.loadSets()
        local missing, mtext = S.missingText(set.objects)
        reskate.log(string.format("Quick Drop helper: imported set %s with %d objects (%d missing)", file, #set.objects, missing))
        return { name = name, count = #set.objects, missing = missing, mtext = mtext }
    end
    function S.importCode(code)
        local got, why = importOne(code)
        if not got then say(why, true) return end
        say(string.format("Imported the set \"%s\" (%d object%s)%s. Find it under Sets.", got.name, got.count, got.count == 1 and "" or "s",
            got.missing > 0 and ("; missing mods: " .. got.mtext) or ""), got.missing > 0)
    end
    -- every code file in sets/import made a set (each file taken away once imported)
    local function readme(folder, text) pcall(reskate.files.write, folder .. "/READ ME.txt", text) end
    function S.importFiles()
        readme(INBOX, "Put set code files here (a .txt file with a code starting SET2 in it), then press Import code > From files in the DDH Park Editor.\n")
        local ok, lst = pcall(reskate.files.list, INBOX)
        local done, failed, names, missing = 0, 0, {}, 0
        if ok and type(lst) == "table" then
            for _, e in ipairs(lst) do
                local base = tostring(type(e) == "table" and (e.name or e.path) or e)
                base = string.match(base, "([^/\\]+)$") or base
                if string.lower(string.sub(base, -4)) == ".txt" and base ~= "READ ME.txt" then
                    local okr, txt = pcall(reskate.files.read, INBOX .. "/" .. base)
                    local got = okr and type(txt) == "string" and importOne(string.match(txt, "SET[12]|[^\r\n]*") or txt)
                    if got then
                        done += 1; names[#names + 1] = got.name; missing += got.missing
                        pcall(reskate.files.remove, INBOX .. "/" .. base)
                    else
                        failed += 1
                        reskate.log("Quick Drop helper: no set code in import/" .. base)
                    end
                end
            end
        end
        if done == 0 then
            say(failed > 0 and "The files in the import folder have no set codes in them (opened)."
                or "No code files to import: put them in the import folder (opened), then press From files again.", true)
            pcall(reskate.files.reveal, INBOX)
            return
        end
        local list = table.concat(names, "\", \"", 1, math.min(#names, 3)) .. (#names > 3 and ("\" and " .. (#names - 3) .. " more") or "\"")
        say(string.format("Imported \"%s. Find them under Sets.%s%s", list,
            missing > 0 and " Some objects are from mods you don't have (Place says which)." or "",
            failed > 0 and string.format(" %d file%s had no code.", failed, failed == 1 and "" or "s") or ""), missing > 0 or failed > 0)
    end
    -- the dialogs: the code to copy, and a box to paste one in
    local function codeDialog(id, opts)
        local ok, err = pcall(reskate.ui.dialog, id, opts)
        if ok then return true end
        reskate.log("Quick Drop helper: set code box: " .. tostring(err))
        return false
    end
    function S.shareSet(set)
        local code = S.setCode(set)
        local file = string.gsub(set.name, " ", "_") .. ".txt"
        readme(CODES, "Set codes made with Share code in the DDH Park Editor. Send a file (or the text in it); your friend puts it in their sets/import folder and presses Import code > From files.\n")
        pcall(reskate.files.write, CODES .. "/" .. file, code .. "\n")
        if #code <= BOXMAX and codeDialog("ddh_setshare", { title = "Share \"" .. set.name .. "\"",
            message = "Copy this code (click in it, Ctrl+A, Ctrl+C) and send it. A friend pastes it with Import code.",
            field = { text = code, max = BOXMAX }, buttons = { { id = "close", label = "Done" }, { id = "codes", label = "Open codes folder" } } }) then
            S.typing = true
            return
        end
        say(string.format("This set is too big for a pasted code (%d letters, the box takes %d): send the file \"%s\" from the codes folder (opened).", #code, BOXMAX, file), true)
        pcall(reskate.files.reveal, CODES)
    end
    function S.askImportCode()
        local ok = codeDialog("ddh_setimport", { title = "Import a set",
            message = "Paste a set code (it starts with SET2). Got a code file? Put it in the import folder and press From files.",
            field = { text = "", max = BOXMAX }, buttons = { { id = "apply", label = "Import" }, { id = "files", label = "From files" }, { id = "close", label = "Cancel" } } })
        if ok then S.typing = true else S.importFiles() end
    end
    reskate.on("throwdown_ui", function(e)
        if e.action ~= "dialog" or (e.args[1] ~= "ddh_setshare" and e.args[1] ~= "ddh_setimport") then return end
        local id, what = e.args[1], e.args[2]
        if what ~= "apply" and what ~= "cancel" and what ~= "close" and what ~= "codes" and what ~= "files" then return end
        S.typing = false
        if what ~= "cancel" then pcall(reskate.ui.close_dialog, id) end
        if what == "codes" then pcall(reskate.files.reveal, CODES) end
        if what == "files" then S.importFiles() end
        if id == "ddh_setimport" and what == "apply" then S.importCode(e.args[3]) end
    end)
    function S.openSetsFolder()
        pcall(reskate.files.write, FOLDER .. "/READ ME.txt", "Sets saved with the DDH Park Editor. Share a set by sending its .json file; put sets you get here.\n")
        pcall(reskate.files.reveal, FOLDER)
    end
    -- place a set: its middle where the cross is, facing the view; then it is held (controller) or picked as a group
    function S.placeSet(set, at, heading, dropped)
        local have = FN.catalogHave()
        at = at or (S.cam and S.cam.target) or V(0, 0, 0)
        heading = heading or wrap(S.cam.yaw + math.pi)
        local list, missing = {}, 0
        for i, e in ipairs(set.objects) do
            if have[e.item] then
                local off = rotY(V(e.x or 0, e.y or 0, e.z or 0), heading)
                list[#list + 1] = { item = e.item, pos = at + off, heading = wrap(heading + (e.h or 0)), scale = clamp(e.s or 1, 0.1, 10),
                    tilt = (e.tx or e.tz) and { x = e.tx or 0, z = e.tz or 0 } or nil, first = i == 1 }
            else
                missing += 1
            end
        end
        if #list == 0 then
            local _, mtext = S.missingText(set.objects)
            say("None of this set's objects are installed. Missing mods: " .. mtext, true)
            return
        end
        local rec = { ids = {}, byIdx = {}, total = 0, done = 0, failed = 0, label = "Set \"" .. set.name .. "\"" }
        for i, c in ipairs(list) do
            if i > 200 then break end
            table.insert(S.q, { op = "place", item = c.item, pos = c.pos, heading = c.heading, scale = c.scale, tilt = c.tilt, rec = rec, idx = i })
            rec.total += 1
        end
        rec.items = list
        S.pushUndo({ kind = "placed", rec = rec })
        -- all there: they become the group; the first is picked (and held, with the controller)
        rec.onAll = function(r)
            S.group = {}
            for _, id in ipairs(r.ids) do S.group[id] = true end
            S.gbase = nil
            local lead = S.known and S.known[r.byIdx[1] or r.ids[1]]
            if lead and S.open then
                select(lead)
                local padMode = S.padUsedAt and (not S.mouseUsedAt or S.padUsedAt >= S.mouseUsedAt)
                if padMode and not dropped then
                    startGrab()
                    if S.grab then S.grab.copyRec = r end
                end
            end
            say(string.format("Placed the set \"%s\": %d objects (picked as a group).%s", set.name, #r.ids, missing > 0 and string.format(" %d left out (mod missing).", missing) or ""))
        end
        say(string.format("Placing the set \"%s\" (%d objects)...%s", set.name, rec.total, missing > 0 and string.format(" %d left out, missing mods: %s.", missing, (S.setMissing(set))) or ""), missing > 0)
    end
    -- carrying a set before it is placed: it follows the cross (or the mouse) as outlines; A / click puts it down
    function S.carrySet(set, at, heading)
        S.carry = { set = set, pos = at or (S.cam and S.cam.target) or V(0, 0, 0), heading = heading or wrap(S.cam.yaw + math.pi) }
        S.grab = nil
        S.padWait = true
        S.cam.goal = S.carry.pos
        say("Carrying \"" .. set.name .. FN.padText("\": move it, A puts it down, B cancels."))
    end
    function S.carryPlaces()
        local c = S.carry
        if not c then return {} end
        local out = {}
        local H = c.snapH or c.heading
        for _, e in ipairs(c.set.objects) do
            out[#out + 1] = { item = e.item, pos = c.pos + rotY(V(e.x or 0, e.y or 0, e.z or 0), H), heading = wrap(H + (e.h or 0)), scale = clamp(e.s or 1, 0.1, 10) }
        end
        return out
    end
    -- where the carried set snaps to: each of its pieces is tried as if it were the held object; the smallest
    -- move that meets something wins, and the whole set takes it
    function S.carrySnap(at, allow)
        local c = S.carry
        if not (c and S.osnap and S.known) or S.snapPick == "off" then return nil end
        local saveSel, saveT = S.sel, S.target
        local best, bestG, bestCost, bestH = nil, nil, math.huge, nil
        for i, e in ipairs(c.set.objects) do
            if i > 40 then break end
            local off = V(e.x or 0, e.y or 0, e.z or 0)
            local p = at + rotY(off, c.heading)
            local h = wrap(c.heading + (e.h or 0))
            local sc = clamp(e.s or 1, 0.1, 10)
            if S.itemBox[e.item] then
                S.sel = { id = "__carry", item = e.item }
                S.target = { pos = p, heading = h, scale = sc }
                -- (like one held object: it meets faces, and turns to meet a turned neighbour flat)
                local ok, np, nh, g = pcall(snapTurned, p, h, sc, allow, nil)
                if ok and g and #g > 0 then
                    local dh = wrap(nh - h)
                    local setH = wrap(c.heading + dh)
                    local setPos = np - rotY(off, setH)
                    local cost = len(np - p) + math.abs(dh) * 0.5 - (g[1].kind == "touch" and 0.05 or 0)
                    if cost < bestCost then best, bestG, bestCost, bestH = setPos, g, cost, setH end
                end
            end
        end
        S.sel, S.target = saveSel, saveT
        return best, bestG, bestH
    end
    function S.carryDrop()
        local c = S.carry
        if not c then return end
        S.carry = nil
        S.placeSet(c.set, c.pos, c.snapH or c.heading, true)
    end
    function S.carryCancel()
        if not S.carry then return end
        S.carry = nil
        say("Cancelled: nothing placed.")
    end
    -- a set seen from above: every object's outline, fitted into a box
    function UI.drawSetPreview(d, set, a, b, col)
        local shapes, tops = {}, {}
        local ylo, yhi = math.huge, -math.huge
        local lo, hi = V(math.huge, 0, math.huge), V(-math.huge, 0, -math.huge)
        for _, e in ipairs(set.objects) do
            local pts = localOutline(e.item)
            local c, s, k = math.cos(e.h or 0), math.sin(e.h or 0), e.s or 1
            local w = {}
            if pts and #pts >= 3 then
                for i, q in ipairs(pts) do
                    local x, z = q.x * k, q.z * k
                    w[i] = V((e.x or 0) + x * c + z * s, 0, (e.z or 0) - x * s + z * c)
                end
            else
                local p = V(e.x or 0, 0, e.z or 0)
                w = { p + V(-0.4, 0, -0.4), p + V(0.4, 0, -0.4), p + V(0.4, 0, 0.4), p + V(-0.4, 0, 0.4) }
            end
            for _, q in ipairs(w) do lo = V(math.min(lo.x, q.x), 0, math.min(lo.z, q.z)); hi = V(math.max(hi.x, q.x), 0, math.max(hi.z, q.z)) end
            local bx = S.itemBox[e.item]
            local top = (e.y or 0) + (bx and bx[2].y * k or 0.5)
            shapes[#shapes + 1] = w
            tops[#shapes] = top
            ylo, yhi = math.min(ylo, top), math.max(yhi, top)
        end
        -- low pieces first and dim, the highest last and brightest: the layout reads like a map
        local order = {}
        for i = 1, #shapes do order[i] = i end
        table.sort(order, function(i, j) return tops[i] < tops[j] end)
        local span = yhi - ylo
        local sw, sh = math.max(hi.x - lo.x, 0.1), math.max(hi.z - lo.z, 0.1)
        local kk = math.min((b.x - a.x) / sw, (b.y - a.y) / sh)
        local ox, oy = (a.x + b.x) / 2, (a.y + b.y) / 2
        local mx, mz = (lo.x + hi.x) / 2, (lo.z + hi.z) / 2
        local n = 0
        local base = col or "#9fd8ff"
        if #base == 9 then base = string.sub(base, 1, 7) end
        for _, si in ipairs(order) do
            local w = shapes[si]
            local f = span > 0.05 and (tops[si] - ylo) / span or 1
            local cc = base .. string.format("%02x", math.floor(110 + 145 * f))
            local sp = {}
            for i, q in ipairs(w) do sp[i] = V(ox + (q.x - mx) * kk, oy - (q.z - mz) * kk, 0) end
            if #sp >= 3 and #sp <= 8 then pcall(d.poly, d, sp, { colour = base .. string.format("%02x", math.floor(20 + 50 * f)), fill = true }) end
            for i = 1, #w do
                local p1, p2 = w[i], w[i % #w + 1]
                d:line(V(ox + (p1.x - mx) * kk, oy - (p1.z - mz) * kk, 0), V(ox + (p2.x - mx) * kk, oy - (p2.z - mz) * kk, 0), { colour = cc, thickness = 2 })
                n += 1
                if n > 600 then return end
            end
        end
    end
end)()

end
