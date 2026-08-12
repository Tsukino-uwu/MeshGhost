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
--
-- First live run (2026-08-12) found two real bugs, both fixed here, neither a socket/spawn-API
-- problem: (1) spawning on the very first tick the pawn becomes non-nil read
-- K2_GetActorLocation() back as (0,0,0) -- the pawn object existing doesn't mean its transform
-- has been placed yet during the level-load sequence, so the ghost spawned near world origin
-- instead of next to the player and was never actually visible on screen. Now guarded by
-- MIN_PLAUSIBLE_DISTANCE below. (2) ExecuteInGameThread queues its callback for a later
-- game-thread tick, so checking `ghost == nil` on the very next LoopAsync tick (100ms later)
-- could still see nil and fire a second, redundant spawn before the first callback had run --
-- now guarded by the `spawning` flag.

local UEHelpers = require("UEHelpers")

local OFFSET_X = 150.0
local FOLLOW_INTERVAL_MS = 100

local ghost = nil
local spawning = false -- guards against a second spawn firing while the first's
                        -- ExecuteInGameThread callback is still pending (found live 2026-08-12:
                        -- ExecuteInGameThread queues work for a later game-thread tick, so the
                        -- next LoopAsync tick can see ghost == nil and fire a second spawn
                        -- before the first one's callback has actually run and assigned it)
local offsetConfirmed = nil -- nil = not tried yet, true/false once known
local lastLoggedState = nil

-- MIN_PLAUSIBLE_DISTANCE: found live 2026-08-12 -- spawning on the very first tick a pawn
-- becomes non-nil read back K2_GetActorLocation() as (0,0,0), even though 7.1 already
-- confirmed real positions here are in the thousands (e.g. 4900.00, 8450.00, -732.85). The
-- pawn object existing doesn't mean its transform has been placed yet during the level-load
-- sequence -- 7.1 never caught this because it only logs on value *change*, so its own
-- first-ever zero reading (if there was one) was silently overwritten before being printed.
-- Guard against spawning at a bogus near-origin location by waiting for a position that isn't
-- suspiciously close to (0,0,0).
local MIN_PLAUSIBLE_DISTANCE = 100.0

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
    spawning = true
    local ok, err = pcall(function()
        local world = UEHelpers.GetWorld()
        if world == nil or not world:IsValid() then
            error("no valid world")
        end
        local class = pawn:GetClass()
        local loc = pawn:K2_GetActorLocation()
        local rot = pawn:K2_GetActorRotation()

        local dist = math.sqrt(loc.X * loc.X + loc.Y * loc.Y + loc.Z * loc.Z)
        if dist < MIN_PLAUSIBLE_DISTANCE then
            print(string.format(
                "[MeshGhostGhostProbe] pawn location looks implausible (%.2f, %.2f, %.2f), distance %.2f from origin -- transform likely not placed yet, skipping this tick.\n",
                loc.X, loc.Y, loc.Z, dist))
            spawning = false
            return
        end

        loc = offsetLocation(loc)
        ExecuteInGameThread(function()
            ghost = world:SpawnActor(class, loc, rot)
            spawning = false
        end)
    end)
    if not ok then
        spawning = false
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
        if not spawning then
            print("[MeshGhostGhostProbe] valid pawn found, spawning ghost...\n")
            trySpawnGhost(pawn)
            lastLoggedState = "spawning"
        end
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
