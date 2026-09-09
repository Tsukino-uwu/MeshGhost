-- MeshGhost WALL-RUN ENTRY (2026-09-09): READ-ONLY, hot-loaded over the scratch slot. The driven
-- ghost's wall run starts ~15% slower than the recording's (DRIVE CLING trace 12:32: the clip's
-- entry h=1000 v=+186, the ghost's h=847 v=+7; the jump launches before the wall are equal) and
-- the difference is not in any plain pawn field the 00:29 diff saw. So: on EVERY transition into
-- `moveState` 4 -- the player's and the driven ghost's -- snapshot every plain-valued property of
-- the pawn AND of its CharacterMovement component, plus velocity, at the sample BEFORE the entry
-- (kept from the last tick), at entry, and 250 ms later, to `wallrun-<HHMMSS>.log` beside the mod.
-- Filter while reading: the file holds everything. Named reads only.

local TAG = "[MeshGhostWallRun]"
local PLAIN = { BoolProperty = true, IntProperty = true, FloatProperty = true, DoubleProperty = true,
                ByteProperty = true, EnumProperty = true, NameProperty = true, StrProperty = true,
                Int64Property = true, UInt32Property = true, Int8Property = true, Int16Property = true, UInt16Property = true }

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../wallrun-" .. os.date("%H%M%S") .. ".log"
local out = io.open(OUT_PATH, "a")
local function log(line) print(TAG .. " " .. line .. "\n") end
local function fout(line) if out then out:write(line, "\n"); out:flush() end end

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function fname_str(x)
    local s
    pcall(function() s = x:GetFName():ToString() end)
    return s or "?"
end
local function addr_of(x)
    local a
    pcall(function() a = x:GetAddress() end)
    return a
end
local function prop(obj, name)
    local v
    if not obj or not pcall(function() v = obj[name] end) then return nil end
    return v
end
local function plain(value)
    local t = type(value)
    if t == "boolean" or t == "number" or t == "string" or t == "nil" then return value end
    if t == "userdata" then
        local got
        if pcall(function() got = value:get() end) and got ~= nil and type(got) ~= "userdata" then return got end
        local s
        if pcall(function() s = value:ToString() end) and type(s) == "string" then return s end
        return "<userdata>"
    end
    return "<" .. t .. ">"
end
local function fmt(v)
    if type(v) == "number" then return string.format("%.4g", v) end
    return tostring(v)
end

local function plain_props(obj)
    local list = {}
    local cls = obj:GetClass()
    while cls and cls:IsValid() do
        local cname = fname_str(cls)
        cls:ForEachProperty(function(p)
            local pclass, pname = "?", "?"
            pcall(function() pclass = p:GetClass():GetFName():ToString() end)
            pcall(function() pname = p:GetFName():ToString() end)
            if PLAIN[pclass] then list[#list + 1] = { key = cname .. "." .. pname, name = pname } end
        end)
        local sup = nil
        pcall(function() sup = cls:GetSuperStruct() end)
        if sup and sup ~= cls and sup:IsValid() then cls = sup else cls = nil end
    end
    return list
end
local function read_all(obj, props, prefix)
    local vals = {}
    for _, p in ipairs(props) do
        local ok, v = pcall(function() return plain(obj[p.name]) end)
        vals[prefix .. p.key] = ok and v or "<error>"
    end
    return vals
end
local function vec_text(v)
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if type(x) ~= "number" then return "?" end
    return string.format("%.1f,%.1f,%.1f", x, y, z or 0)
end

local function player_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn = prop(pc, field)
                if pawn ~= nil and valid(pawn) then return pawn end
            end
        end
    end
    return nil
end

local pawn_props, move_props = nil, nil
local function snapshot(pawn, label)
    if not pawn_props then pawn_props = plain_props(pawn) end
    local mv = prop(pawn, "CharacterMovement")
    if mv ~= nil and valid(mv) and not move_props then move_props = plain_props(mv) end
    local vals = read_all(pawn, pawn_props, "PAWN ")
    if mv ~= nil and valid(mv) and move_props then
        for k, v in pairs(read_all(mv, move_props, "MOVE ")) do vals[k] = v end
        pcall(function() vals["MOVE Velocity"] = vec_text(mv.Velocity) end)
    end
    pcall(function() vals["PAWN Location"] = vec_text(pawn:K2_GetActorLocation()) end)
    pcall(function() vals["PAWN GetVelocity"] = vec_text(pawn:GetVelocity()) end)
    pcall(function() vals["PAWN inputVectorWorld"] = vec_text(pawn.inputVectorWorld) end)
    vals["__label"] = label
    return vals
end
local function write_snapshot(header, vals)
    fout("--- " .. header)
    local keys = {}
    for k in pairs(vals) do if k ~= "__label" then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do fout("  " .. k .. " = " .. fmt(vals[k])) end
end

-- Per watched pawn: last moveState, last snapshot (the "before"), pending after-reads.
local watch = {}   -- addr -> { pawn=, who=, last_ms=, before= }
local pending = {}
local ticks = 0
local t_start = os.clock()
log("loaded -- snapshots of pawn + CharacterMovement on every entry into moveState 4, to " .. OUT_PATH)
fout("wallrun entry started " .. os.date("%H:%M:%S"))

LoopAsync(50, function()
    ticks = ticks + 1
    local me = player_pawn()
    if not me then return false end
    local me_addr = addr_of(me)
    local my_class = "?"
    pcall(function() my_class = me:GetClass():GetFName():ToString() end)
    if not my_class:find("^BP_") then return false end
    -- (Re)build the watch list once a second: the player and every AI-steered live pawn.
    if ticks % 20 == 1 then
        local seen = {}
        for _, p in pairs(FindAllOf(my_class) or {}) do
            if valid(p) and prop(p, "bActorIsBeingDestroyed") ~= true then
                local a = addr_of(p)
                local who = nil
                if a == me_addr then who = "PLAYER" else
                    local ctl = prop(p, "Controller")
                    local cn = "<none>"
                    if ctl ~= nil and valid(ctl) then pcall(function() cn = ctl:GetClass():GetFName():ToString() end) end
                    if cn:find("AIController") then who = "GHOST" end
                end
                if who then
                    seen[a] = true
                    if not watch[a] then
                        watch[a] = { pawn = p, who = who, last_ms = nil, before = nil }
                        log("watching " .. who .. " " .. fname_str(p))
                    end
                end
            end
        end
        for a in pairs(watch) do if not seen[a] then watch[a] = nil end end
    end
    -- Deferred after-reads.
    local keep = {}
    for _, d in ipairs(pending) do
        if ticks >= d.at_tick then
            if valid(d.pawn) then write_snapshot(d.header, snapshot(d.pawn, d.header)) end
        else
            keep[#keep + 1] = d
        end
    end
    pending = keep
    for a, w in pairs(watch) do
        if valid(w.pawn) then
            local ms = prop(w.pawn, "moveState")
            local t = os.clock() - t_start
            -- Coverage line: what this probe reads off each watched pawn, every 2 s -- a ghost whose
            -- entries never log has to show here as a type or a read that is not what the player's is.
            if ticks % 40 == 0 then
                -- `respawnTransform` (a Transform on the pawn, the player dump 2026-09-06): the
                -- safe spot a pit death returns the character to. The driven ghost returned to the
                -- world origin (12:39), so this reads both pawns' every 2 s -- does the clone's
                -- ever move off zero while it walks the route?
                local rt = "?"
                pcall(function()
                    local tr = w.pawn.respawnTransform
                    local tl = tr.Translation
                    rt = string.format("%.0f,%.0f,%.0f", tl.X, tl.Y, tl.Z)
                end)
                local here = "?"
                pcall(function() here = vec_text(w.pawn:K2_GetActorLocation()) end)
                log(string.format("%s %s moveState=%s respawnTransform=%s at %s", w.who, fname_str(w.pawn), tostring(ms), rt, here))
            end
            -- Two entries are snapshotted: moveState 4 (the wall) and actionState 6 (the plunge,
            -- Sunsetter: the recording drops at 2000 units/s, the driven ghost at ~200, 12:39).
            local as = prop(w.pawn, "actionState")
            local entered = nil
            if w.last_ms ~= nil and ms == 4 and w.last_ms ~= 4 then entered = "moveState 4 (wall)" end
            if w.last_as ~= nil and as == 6 and w.last_as ~= 6 then entered = "actionState 6 (plunge)" end
            -- The crouch slide (13:3x): the recording holds actionState 18 for ~0.2 s and jumps out
            -- of it at 1100; the driven ghost's 18 lasts one tick. Both entries AND the exit.
            if w.last_as ~= nil and as == 18 and w.last_as ~= 18 then entered = "actionState 18 (slide)" end
            if w.last_as == 18 and as ~= 18 then entered = "LEFT actionState 18 (slide) -> " .. tostring(as) end
            -- The crouch itself (moveState 2), for the side that crouches without sliding.
            if w.last_ms ~= nil and ms == 2 and w.last_ms ~= 2 then entered = "moveState 2 (crouch)" end
            if entered then
                local tag = string.format("%s %s t=%.2f", w.who, fname_str(w.pawn), t)
                if w.before then write_snapshot(tag .. " BEFORE (last tick, moveState " .. tostring(w.last_ms) .. " actionState " .. tostring(w.last_as) .. ")", w.before) end
                local now = snapshot(w.pawn, tag)
                write_snapshot(tag .. " ENTRY " .. entered, now)
                pending[#pending + 1] = { at_tick = ticks + 5, pawn = w.pawn, header = tag .. " +250ms after " .. entered }
                pending[#pending + 1] = { at_tick = ticks + 10, pawn = w.pawn, header = tag .. " +500ms after " .. entered }
                log(string.format("%s entered %s: velocity before=%s at entry=%s", tag, entered, tostring(w.before and w.before["PAWN GetVelocity"]), tostring(now["PAWN GetVelocity"])))
            end
            w.last_as = as
            -- The "before" is LIGHT (a full snapshot is ~800 reads; at 20 Hz per pawn that is the
            -- probe changing what it measures): velocity, location, the input fields, the states.
            do
                local b = {}
                pcall(function() b["PAWN GetVelocity"] = vec_text(w.pawn:GetVelocity()) end)
                pcall(function() b["PAWN Location"] = vec_text(w.pawn:K2_GetActorLocation()) end)
                pcall(function() b["PAWN inputVectorWorld"] = vec_text(w.pawn.inputVectorWorld) end)
                b["PAWN moveInputAmount"] = fmt(plain(prop(w.pawn, "moveInputAmount")))
                b["PAWN hasMovementInput?"] = fmt(plain(prop(w.pawn, "hasMovementInput?")))
                b["PAWN horizontalSpeed"] = fmt(plain(prop(w.pawn, "horizontalSpeed")))
                b["PAWN moveState"] = fmt(plain(ms))
                b["PAWN actionState"] = fmt(plain(prop(w.pawn, "actionState")))
                b["PAWN wallRideButtonHeld?"] = fmt(plain(prop(w.pawn, "wallRideButtonHeld?")))
                b["PAWN jumpButtonHeld?"] = fmt(plain(prop(w.pawn, "jumpButtonHeld?")))
                w.before = b
            end
            w.last_ms = ms
        end
    end
    return false
end)
