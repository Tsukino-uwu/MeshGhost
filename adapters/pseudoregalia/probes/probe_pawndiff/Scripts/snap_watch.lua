-- MeshGhost SNAP WATCH (2026-09-09): READ-ONLY, hot-loaded over the scratch slot. The driven
-- ghost on a clip with two wall clings snaps ~8 times per loop (the user: *"it was snapping a
-- lot"*; the rig: 8 corrections per 10 s, max drift 154 against a 150 snap). The rig only counts
-- corrections; this watches the DRIVEN pawn at 50 ms and logs every tick where it moved more than
-- SNAP_UNITS in one step -- a correction, or a fall -- with a window of the last 8 samples: location,
-- velocity, moveState, MovementMode, `wallRideButtonHeld?`, `jumpButtonHeld?`, `hasMovementInput?`.
-- Which way the ghost was drifting before each snap (up the wall, off the wall, behind on the
-- ground) is the question; the direction of the snap answers it. Named reads only.

local TAG = "[MeshGhostSnapWatch]"
local SNAP_UNITS = 100.0
local WINDOW = 8

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
local function log(line) print(TAG .. " " .. line .. "\n") end

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

local function vec3(v)
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if type(x) ~= "number" then return nil end
    return { x = x, y = y, z = z }
end

local function sample(pawn, t)
    local loc = nil
    pcall(function() loc = vec3(pawn:K2_GetActorLocation()) end)
    local vel = nil
    pcall(function() vel = vec3(pawn:GetVelocity()) end)
    local mv = prop(pawn, "CharacterMovement")
    local mm = mv and tostring(prop(mv, "MovementMode")) or "?"
    return {
        t = t, loc = loc, vel = vel,
        ms = tostring(prop(pawn, "moveState")), as = tostring(prop(pawn, "actionState")), mm = mm,
        wall = tostring(prop(pawn, "wallRideButtonHeld?")), jump = tostring(prop(pawn, "jumpButtonHeld?")),
        input = tostring(prop(pawn, "hasMovementInput?")),
    }
end
local function fmt(s)
    local l = s.loc and string.format("%.0f,%.0f,%.0f", s.loc.x, s.loc.y, s.loc.z) or "?"
    local v = s.vel and string.format("%.0f,%.0f,%.0f", s.vel.x, s.vel.y, s.vel.z) or "?"
    return string.format("t=%6.2f loc=%s vel=%s move=%s action=%s mode=%s wall=%s jump=%s input=%s", s.t, l, v, s.ms, s.as, s.mm, s.wall, s.jump, s.input)
end

local driven, driven_addr = nil, nil
local window = {}
local ticks = 0
local t_start = os.clock()
local snaps = 0
log("loaded -- watching the driven pawn for single-tick moves over " .. SNAP_UNITS .. " units")

LoopAsync(50, function()
    ticks = ticks + 1
    if ticks % 20 == 1 or not (driven and valid(driven)) then
        local me = player_pawn()
        if me then
            local my_class = "?"
            pcall(function() my_class = me:GetClass():GetFName():ToString() end)
            local my_addr = addr_of(me)
            local found = nil
            for _, p in pairs(FindAllOf(my_class) or {}) do
                if valid(p) and addr_of(p) ~= my_addr and prop(p, "bActorIsBeingDestroyed") ~= true then
                    local ctl = prop(p, "Controller")
                    local cn = "<none>"
                    if ctl ~= nil and valid(ctl) then pcall(function() cn = ctl:GetClass():GetFName():ToString() end) end
                    if cn:find("AIController") then found = p end
                end
            end
            if found and addr_of(found) ~= driven_addr then
                driven, driven_addr, window = found, addr_of(found), {}
                log("watching driven pawn " .. fname_str(found))
            elseif not found then
                driven, driven_addr = nil, nil
            end
        end
    end
    if not (driven and valid(driven)) then return false end
    local s = sample(driven, os.clock() - t_start)
    local prev = window[#window]
    if prev and prev.loc and s.loc then
        local dx, dy, dz = s.loc.x - prev.loc.x, s.loc.y - prev.loc.y, s.loc.z - prev.loc.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d > SNAP_UNITS then
            snaps = snaps + 1
            log(string.format("SNAP #%d: %.0f units in one tick, delta=(%.0f,%.0f,%.0f); the %d samples before:", snaps, d, dx, dy, dz, #window))
            for _, w in ipairs(window) do log("   " .. fmt(w)) end
            log(" after: " .. fmt(s))
        end
    end
    window[#window + 1] = s
    if #window > WINDOW then table.remove(window, 1) end
    return false
end)
