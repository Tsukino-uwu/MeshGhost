-- MeshGhost Phase 7.1 read-only discovery probe. Not the real adapter — a throwaway UE4SS
-- Lua mod whose only job is to confirm, live on screen, where Pseudoregalia's local player
-- pawn, position, rotation, and level name actually live, before any of it gets ported into
-- the real C++ adapter (adapters/pseudoregalia/MeshGhostPseudo/, not yet started).
-- Never writes memory, never touches the network.
--
-- Deploy: copy this Scripts/main.lua (and this probe/ folder's structure) into
--   <Pseudoregalia install>\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostProbe\Scripts\main.lua
-- then add "MeshGhostProbe : 1" to that ue4ss\Mods\mods.txt (see agent_docs/phases/phase7.md
-- for the confirmed install path and UE4SS version, v3.0.1 Beta / SHA 733e5969).
--
-- API source: UEHelpers (docs.ue4ss.com; also read directly and confirmed present as
-- ue4ss\Mods\shared\UEHelpers\UEHelpers.lua on this install, part of RE-UE4SS itself, MIT --
-- see agent_docs/licensing.md). GetPlayerController()/.Pawn/K2_GetActorLocation() usage
-- pattern confirmed against this same install's own bundled example mod,
-- ue4ss\Mods\LineTraceMod\Scripts\main.lua, which already uses UEHelpers.GetPlayerController()
-- and PlayerController.Pawn successfully in this exact game/UE4SS build -- not assumed from
-- generic UE4SS docs alone. No pseudoregalia-archipelago source was read to write this file
-- (see agent_docs/licensing.md's no-license entry for that repo -- facts only, and this
-- script's facts come from UE4SS's own bundled code, not that repo).
--
-- Everything below is UNCONFIRMED until watched on screen -- this file exists to produce that
-- confirmation, not to assume it. Record results in agent_docs/verified.md only after the
-- user has watched values change correctly walking, jumping, and changing rooms.

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
    -- GetFullName()/GetName() are standard UObject methods available on any valid UE4SS
    -- RemoteObject; the exact level-name shape (e.g. whether it includes a package path
    -- prefix) is one of the things this probe exists to confirm on screen, not assumed here.
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
        -- UE is Z-up, centimetres. Position/rotation shape here is exactly what would become
        -- the adapter's position/orientation fields (contract.md: position is variable-length,
        -- orientation is opaque JSON of any shape) -- not decided yet, just observed.
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
