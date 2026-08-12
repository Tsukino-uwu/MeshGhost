-- MeshGhost Phase 7.4 probe: spawn a placeholder ghost in-engine at a fixed offset from the
-- local player and keep it following every tick -- no networking yet, no real anim/mesh work
-- (that's 7.6). TEVI's 6.3 analogue (agent_docs/phases/phase6.md): a deliberately crude
-- placeholder to prove SpawnActor + per-frame positioning work at all before building anything
-- real on top of it.
--
-- Deploy: copy this probe_ghost/ folder into
--   <Pseudoregalia install>\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostGhostProbe\Scripts\main.lua
-- then add "MeshGhostGhostProbe : 1" to that ue4ss\Mods\mods.txt.
--
-- Riskier than the Phase 7.2 socket probes: this spawns a real second instance of the
-- player's own gameplay Blueprint (BP_PlayerGoatMain_C, confirmed live in 7.1), not just a
-- background network connection. Possible failure modes: physics/collision behaving oddly
-- with two instances of the same pawn class in the world, or (less likely, not ruled out)
-- construction-script/auto-possession logic on that Blueprint doing something unexpected with
-- a second instance. Needs explicit go-ahead to deploy/run, same standard as Stage 2/3.
--
-- Grounded in exactly these confirmed APIs -- searched this install's own bundled docs
-- (RE-UE4SS/docs/lua-api) and bundled example mods (RE-UE4SS/assets/Mods) for each one before
-- using it, per CLAUDE.md's "no addresses/APIs from memory" rule:
--   UEHelpers.GetPlayerController()/.Pawn, UEHelpers.GetWorld()  -- confirmed live in 7.1
--   UObject:GetClass()                                            -- docs/lua-api/classes/uobject.md
--   UWorld:SpawnActor(UClass, FVector, FRotator)                  -- docs/lua-api/classes/uworld.md
--   AActor:K2_GetActorLocation()/K2_GetActorRotation()             -- confirmed live in 7.1
--   AActor:K2_SetActorLocationAndRotation(loc, rot, sweep, hit, teleport)
--       -- assets/Mods/SplitScreenMod/Scripts/main.lua's TeleportPlayers(), a real bundled mod
--   LoopAsync(intervalMs, callback)                                -- confirmed live in 7.1
--   ExecuteInGameThread(fn)                                        -- SplitScreenMod, wraps
--       every actor-affecting call in that mod; mirrored here for SpawnActor/positioning too.
--
-- NOT grounded, tried defensively: no bundled doc or example anywhere in this install
-- constructs or mutates an FVector's X/Y/Z fields directly (searched both docs/lua-api and
-- every assets/Mods script). The fixed offset below tries "loc.X = loc.X + OFFSET_X" and logs
-- once whether it actually took effect (by reading the field back), falling back to spawning
-- with zero offset -- stacked on the player -- if it silently didn't.
--
-- Known limitation, not solved here: no despawn/cleanup logic. Restart the game between runs
-- rather than reloading this mod repeatedly, or ghosts will accumulate.

local UEHelpers = require("UEHelpers")

local OFFSET_X = 150.0
local FOLLOW_INTERVAL_MS = 100

local ghost = nil
local offsetConfirmed = nil -- nil = not tried yet, true/false once known
local lastLoggedState = nil

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

-- offsetLocation tries to nudge loc.X by OFFSET_X in place and reports whether the field
-- mutation actually stuck (read back afterward) -- see the "NOT grounded" note above.
local function offsetLocation(loc)
    if offsetConfirmed ~= nil then
        if offsetConfirmed then
            pcall(function() loc.X = loc.X + OFFSET_X end)
        end
        return loc
    end
    local before = loc.X
    local ok = pcall(function() loc.X = loc.X + OFFSET_X end)
    local after = loc.X
    offsetConfirmed = ok and math.abs(after - (before + OFFSET_X)) < 0.01
    print(string.format(
        "[MeshGhostGhostProbe] FVector field mutation %s (before=%.2f, after=%.2f, wanted=%.2f)\n",
        offsetConfirmed and "CONFIRMED working" or "did NOT take effect -- spawning with zero offset instead",
        before, after, before + OFFSET_X))
    return loc
end

local function trySpawnGhost(pawn)
    local ok, err = pcall(function()
        local world = UEHelpers.GetWorld()
        if world == nil or not world:IsValid() then
            error("no valid world")
        end
        local class = pawn:GetClass()
        local loc = pawn:K2_GetActorLocation()
        local rot = pawn:K2_GetActorRotation()
        loc = offsetLocation(loc)
        ExecuteInGameThread(function()
            ghost = world:SpawnActor(class, loc, rot)
        end)
    end)
    if not ok then
        print(string.format("[MeshGhostGhostProbe] spawn FAILED: %s\n", tostring(err)))
    end
end

local function followTick()
    local pawn, err = safeGetPawn()
    if pawn == nil then
        if lastLoggedState ~= "waiting" then
            print("[MeshGhostGhostProbe] " .. err .. "\n")
            lastLoggedState = "waiting"
        end
        return false
    end

    if ghost == nil then
        print("[MeshGhostGhostProbe] valid pawn found, spawning ghost...\n")
        trySpawnGhost(pawn)
        lastLoggedState = "spawning"
        return false
    end

    if not ghost:IsValid() then
        if lastLoggedState ~= "ghost_invalid" then
            print("[MeshGhostGhostProbe] ghost became invalid (level transition?), will not respawn automatically.\n")
            lastLoggedState = "ghost_invalid"
        end
        return false
    end

    local ok, followErr = pcall(function()
        local loc = pawn:K2_GetActorLocation()
        local rot = pawn:K2_GetActorRotation()
        loc = offsetLocation(loc)
        ExecuteInGameThread(function()
            ghost:K2_SetActorLocationAndRotation(loc, rot, false, {}, false)
        end)
    end)
    if not ok and lastLoggedState ~= "follow_error" then
        print(string.format("[MeshGhostGhostProbe] follow update FAILED: %s\n", tostring(followErr)))
        lastLoggedState = "follow_error"
    elseif ok and lastLoggedState ~= "following" then
        print("[MeshGhostGhostProbe] ghost is following.\n")
        lastLoggedState = "following"
    end

    return false -- keep looping
end

print("[MeshGhostGhostProbe] Phase 7.4 placeholder-ghost probe running.\n")
LoopAsync(FOLLOW_INTERVAL_MS, followTick)
