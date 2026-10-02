-- Read-only discovery probe: prints the local player pawn, its position and rotation, and the level name on change.
-- Deploy as ue4ss\Mods\MeshGhostProbe\Scripts\main.lua and add "MeshGhostProbe : 1" to ue4ss\Mods\mods.txt.

local UEHelpers = require("UEHelpers")

local PRINT_INTERVAL_MS = 250
local lastLine = nil

local function safeGetPawn()
    local ok, controller = pcall(UEHelpers.GetPlayerController)
    if not ok or controller == nil or not controller:IsValid() then
        return nil, "no valid PlayerController yet"
    end
    local pawn = controller.Pawn
    if pawn == nil or not pawn:IsValid() then
        return nil, "PlayerController has no valid Pawn yet"
    end
    return pawn, nil
end

local function safeGetLevelName()
    local ok, world = pcall(UEHelpers.GetWorld)
    if not ok or world == nil or not world:IsValid() then
        return "<no world>"
    end
    local level = world.PersistentLevel
    if level == nil or not level:IsValid() then
        return "<no persistent level>"
    end
    local ok2, name = pcall(function() return level:GetFullName() end)
    if ok2 and name ~= nil then
        return name
    end
    return "<level name read failed>"
end

local function tick()
    local pawn, err = safeGetPawn()
    local line
    if pawn == nil then
        line = "waiting: " .. err
    else
        local loc = pawn:K2_GetActorLocation()
        local rot = pawn:K2_GetActorRotation()
        local levelName = safeGetLevelName()
        line = string.format(
            "pawn=%s  pos=(%.2f, %.2f, %.2f)  rot=(pitch=%.2f, yaw=%.2f, roll=%.2f)  level=%s",
            pawn:GetFullName(),
            loc.X, loc.Y, loc.Z,
            rot.Pitch, rot.Yaw, rot.Roll,
            levelName
        )
    end
    if line ~= lastLine then
        print("[MeshGhostProbe] " .. line .. "\n")
        lastLine = line
    end
    return false -- keep looping
end

print("[MeshGhostProbe] Phase 7.1 discovery probe running. Only prints when a value changes -\n")
print("[MeshGhostProbe] stand still and it will go quiet. Walk/jump/change rooms to verify.\n")

LoopAsync(PRINT_INTERVAL_MS, tick)
