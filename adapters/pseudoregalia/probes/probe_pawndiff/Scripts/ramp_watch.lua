-- MeshGhost RAMP WATCH (2026-09-09): READ-ONLY, hot-loaded over the scratch slot. With the bound
-- stick answered and the pawn's own Blueprint moving the driven ghost, the ghost is slower from the
-- first frame of every loop: 69 against the recording's 255 at the crouch 0.6 s in, 446 against
-- 816 at the wall (DRIVE CLING, 13:33). So: for the first 3 s after each new driven pawn appears,
-- every 50 ms -- speed, moveState, actionState, `moveInputAmount`, `hasMovementInput?`,
-- `inputVectorWorld`, `horizontalSpeed`, and once per pawn the movement component's
-- `MaxWalkSpeed`/`MaxAcceleration`/`GroundFriction`/`BrakingFrictionFactor` and the pawn's
-- `runSpeed`. The recording's own ramp is read offline from the clip's positions. Named reads only.

local TAG = "[MeshGhostRamp]"
local WINDOW_S = 3.0

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
local function vec(v)
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if type(x) ~= "number" then return nil end
    return x, y, z or 0
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

local driven, driven_addr, seen_at = nil, nil, nil
local ticks = 0
local t_start = os.clock()
log("loaded -- the driven pawn's first " .. WINDOW_S .. " s per loop at 50 ms")

LoopAsync(50, function()
    ticks = ticks + 1
    if ticks % 10 == 1 or not (driven and valid(driven)) then
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
                driven, driven_addr, seen_at = found, addr_of(found), os.clock()
                local mv = prop(found, "CharacterMovement")
                local cfg = "?"
                if mv ~= nil and valid(mv) then
                    cfg = string.format("MaxWalkSpeed=%s MaxAcceleration=%s GroundFriction=%s BrakingFrictionFactor=%s MaxWalkSpeedCrouched=%s",
                        tostring(prop(mv, "MaxWalkSpeed")), tostring(prop(mv, "MaxAcceleration")), tostring(prop(mv, "GroundFriction")),
                        tostring(prop(mv, "BrakingFrictionFactor")), tostring(prop(mv, "MaxWalkSpeedCrouched")))
                end
                log(string.format("new driven pawn %s: runSpeed=%s %s", fname_str(found), tostring(prop(found, "runSpeed")), cfg))
                local pmv = prop(me, "CharacterMovement")
                if pmv ~= nil and valid(pmv) then
                    log(string.format("   player: runSpeed=%s MaxWalkSpeed=%s MaxAcceleration=%s GroundFriction=%s", tostring(prop(me, "runSpeed")),
                        tostring(prop(pmv, "MaxWalkSpeed")), tostring(prop(pmv, "MaxAcceleration")), tostring(prop(pmv, "GroundFriction"))))
                end
            elseif not found then
                driven, driven_addr = nil, nil
            end
        end
    end
    if not (driven and valid(driven) and seen_at) then return false end
    local age = os.clock() - seen_at
    if age > WINDOW_S then return false end
    local vx, vy, vz = 0, 0, 0
    pcall(function() vx, vy, vz = vec(driven:GetVelocity()) end)
    local ix, iy, iz = 0, 0, 0
    pcall(function() ix, iy, iz = vec(driven.inputVectorWorld) end)
    log(string.format("age=%.2f speed_h=%.0f v=%.0f move=%s action=%s amount=%s input=%s ivw=(%.2f,%.2f) hs=%s",
        age, math.sqrt((vx or 0) ^ 2 + (vy or 0) ^ 2), vz or 0, tostring(prop(driven, "moveState")), tostring(prop(driven, "actionState")),
        tostring(prop(driven, "moveInputAmount")), tostring(prop(driven, "hasMovementInput?")), ix or 0, iy or 0, tostring(prop(driven, "horizontalSpeed"))))
    return false
end)
