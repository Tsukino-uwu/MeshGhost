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
-- constructs an FVector from scratch (searched both docs/lua-api and every assets/Mods
-- script). Never a problem in practice: every FVector this script uses comes from an actor's
-- own K2_GetActorLocation() call, never freshly constructed.
--
-- Known limitation, not solved here: no despawn/cleanup logic. Restart the game between runs
-- rather than reloading this mod repeatedly, or ghosts will accumulate.
--
-- Five real bugs found across five live runs, 2026-08-12, all fixed here. The first four are
-- kept for the record (see git history for the full comments that used to be here); summary:
-- (1) spawning before the pawn's transform was placed, read back as (0,0,0) -- guarded by
-- MIN_PLAUSIBLE_DISTANCE. (2) a double-spawn race from ExecuteInGameThread's async callback --
-- guarded by the `spawning` flag. (3) suspected ghost collision/physics dragging the player --
-- disabled collision/tick on the ghost, made zero difference. (4) suspected the follow loop
-- mutating a live reference into the pawn's own transform -- rewrote it to only ever mutate a
-- vector owned by the ghost. Neither (3) nor (4) actually fixed the drag; the user was dragged
-- identically on the very next run with (4)'s fix in place, which is what triggered stopping
-- to actually diagnose instead of guessing a fifth time (see
-- agent_docs/phases/phase7.md/agent_docs/verified.md for the full history and the plan at
-- C:\Users\nyden\.claude\plans\nope-i-was-still-cryptic-horizon.md).
--
-- (5) THE REAL BUG, confirmed by a read-only diagnostic script
-- (probe_ghost/Scripts/diagnose.lua) that spawned the ghost but never called any
-- position-setting function at all: `BP_PlayerGoatMain_C` auto-possesses on spawn.
-- `UE4SS.log` showed `controller.Pawn == ghost: true` on every tick immediately after
-- spawning, with the position never moving (confirming the diagnostic itself caused zero
-- drag). Every previous "fix" moved `ghost` believing it was a separate, uncontrolled
-- placeholder -- but `ghost` WAS the actual possessed, camera-attached character the whole
-- time, because SpawnActor silently swapped `PlayerController.Pawn` to it. Moving "the ghost"
-- was always moving the real player. This also explains why no second model was ever visible
-- during a drag: there was only ever one controlled body in the world.
--
-- Fixed by capturing the original pawn and controller before spawning, then immediately
-- calling `controller:Possess(originalPawn)` after spawn to hand control back -- leaving the
-- ghost genuinely uncontrolled, as intended. `Possess` isn't in the bundled RE-UE4SS docs
-- (confirmed incomplete already), grounded via `gh api search/code` (470 hits, a completely
-- standard AController method). Also adds a defensive distance-based safety clamp
-- (MAX_TICK_DELTA) as a backstop against any future bug of this shape, per the plan above.
--
-- Confirmed live: this fix works -- an 82-second run with no dragging or forced death (versus
-- ~13s to death on every prior run). One smaller, separate issue found the same run: `Possess`
-- correctly returns input control but doesn't necessarily move the active camera view target,
-- which stayed on the ghost. Added `SetViewTargetWithBlend(pawn, 0)` right after `Possess`,
-- grounded the same way (`gh api search/code`, 218 hits). Not yet retested live.

local UEHelpers = require("UEHelpers")

local OFFSET_X = 150.0
local FOLLOW_INTERVAL_MS = 100

local ghost = nil
local spawning = false -- guards against a second spawn firing while the first's
                        -- ExecuteInGameThread callback is still pending (found live 2026-08-12:
                        -- ExecuteInGameThread queues work for a later game-thread tick, so the
                        -- next LoopAsync tick can see ghost == nil and fire a second spawn
                        -- before the first one's callback has actually run and assigned it)
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

-- MAX_TICK_DELTA: defensive backstop, not the actual fix for bug (5). Refuses to move the
-- ghost further than this in a single tick, logging instead of applying it. Normal player
-- movement between 100ms ticks is nowhere near this; a jump this large almost certainly means
-- something is wrong again (e.g. the position source is no longer what this script thinks it
-- is), and it's better to freeze the ghost in place and log loudly than repeat a runaway drag.
local MAX_TICK_DELTA = 500.0

local function safeGetPawn()
    local ok, controller = pcall(UEHelpers.GetPlayerController)
    if not ok or controller == nil or not controller:IsValid() then
        return nil, nil, "no valid PlayerController yet"
    end
    local pawn = controller.Pawn
    if pawn == nil or not pawn:IsValid() then
        return nil, controller, "PlayerController has no valid Pawn yet"
    end
    return pawn, controller, nil
end

-- offsetGhostToward writes the player's (px, py, pz) plus a fixed X offset into ghostLoc --
-- which MUST be a vector owned by the ghost (e.g. ghost:K2_GetActorLocation()), never one read
-- from the player pawn. Found live 2026-08-12, the hard way: K2_GetActorLocation() appears to
-- return a *live reference* into the actor's own transform, not a detached copy -- mutating a
-- vector read from the pawn writes directly into the real player's position. The follow loop
-- used to do exactly that every 100ms, compounding into a smooth, straight-line, never-ending
-- drift -- not a physics/collision effect at all, which is why disabling collision/tick on the
-- ghost (the previous "fix") had zero effect. Reading fields off the pawn's vector is fine and
-- unchanged elsewhere in this file; only ever writing into it is the danger.
local function offsetGhostToward(ghostLoc, px, py, pz)
    ghostLoc.X = px + OFFSET_X
    ghostLoc.Y = py
    ghostLoc.Z = pz
end

local function trySpawnGhost(pawn, controller)
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

        -- Spawn AT the player's exact position, unmodified -- no mutation here, matching
        -- SplitScreenMod's confirmed safe pattern of reusing a struct read from one actor
        -- directly on another with no in-place writes. The fixed offset is applied afterward,
        -- once the ghost exists and has its own vector to mutate (see followTick).
        ExecuteInGameThread(function()
            ghost = world:SpawnActor(class, loc, rot)
            spawning = false
            if ghost == nil or not ghost:IsValid() then
                return
            end

            -- THE REAL FIX (bug 5, see header comment): BP_PlayerGoatMain_C auto-possesses on
            -- spawn, silently swapping PlayerController.Pawn to the ghost. Hand control back to
            -- the real pawn immediately. `Possess` grounded via `gh api search/code` (470
            -- hits) -- not in the bundled docs, same as several other AActor/AController calls
            -- in this file.
            local possessOk, possessErr = pcall(function() controller:Possess(pawn) end)
            print(string.format(
                "[MeshGhostGhostProbe] re-possess original pawn after spawn: %s\n",
                possessOk and "ok" or ("FAILED: " .. tostring(possessErr))))

            -- Found live 2026-08-12: Possess() correctly reassigns control (confirmed -- no
            -- more drag, an 82s run with no forced movement) but doesn't necessarily move the
            -- active camera view target back -- a real, separate concept in UE (the camera
            -- stayed on the ghost even though input control had already returned to the real
            -- pawn). SetViewTargetWithBlend grounded via `gh api search/code` (218 hits, a
            -- standard AController/PlayerController method); not in the bundled docs.
            local viewTargetOk, viewTargetErr = pcall(function() controller:SetViewTargetWithBlend(pawn, 0) end)
            print(string.format(
                "[MeshGhostGhostProbe] re-point camera view target to original pawn: %s\n",
                viewTargetOk and "ok" or ("FAILED: " .. tostring(viewTargetErr))))

            -- Kept as a reasonable secondary safety measure even though bug 5, not
            -- collision/physics, was the actual cause of the drag -- see agent_docs/risks.md.
            local collisionOk = pcall(function() ghost:SetActorEnableCollision(false) end)
            local tickOk = pcall(function() ghost:SetActorTickEnabled(false) end)
            print(string.format(
                "[MeshGhostGhostProbe] post-spawn safety calls: SetActorEnableCollision(false) %s, SetActorTickEnabled(false) %s\n",
                collisionOk and "ok" or "FAILED", tickOk and "ok" or "FAILED"))
        end)
    end)
    if not ok then
        spawning = false
        print(string.format("[MeshGhostGhostProbe] spawn FAILED: %s\n", tostring(err)))
    end
end

local lastGhostTarget = nil -- {x, y, z} of the last position actually applied to the ghost,
                             -- for the MAX_TICK_DELTA backstop

local function followTick()
    local pawn, controller, err = safeGetPawn()
    if pawn == nil then
        if lastLoggedState ~= "waiting" then
            print("[MeshGhostGhostProbe] " .. tostring(err) .. "\n")
            lastLoggedState = "waiting"
        end
        return false
    end

    if ghost == nil then
        if not spawning then
            print("[MeshGhostGhostProbe] valid pawn found, spawning ghost...\n")
            trySpawnGhost(pawn, controller)
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
        -- Read-only on the pawn's own vectors: px/py/pz/rot are plain values or a struct we
        -- never write back into. The only mutation happens below, on ghostLoc -- a vector
        -- owned by the ghost itself, fetched fresh each tick.
        local pawnLoc = pawn:K2_GetActorLocation()
        local px, py, pz = pawnLoc.X, pawnLoc.Y, pawnLoc.Z
        local rot = pawn:K2_GetActorRotation()
        local targetX, targetY, targetZ = px + OFFSET_X, py, pz

        if lastGhostTarget ~= nil then
            local dx = targetX - lastGhostTarget.x
            local dy = targetY - lastGhostTarget.y
            local dz = targetZ - lastGhostTarget.z
            local tickDist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if tickDist > MAX_TICK_DELTA then
                print(string.format(
                    "[MeshGhostGhostProbe] refusing implausible single-tick move of %.2f units (max %.2f) -- freezing ghost in place, not applying.\n",
                    tickDist, MAX_TICK_DELTA))
                return
            end
        end
        lastGhostTarget = { x = targetX, y = targetY, z = targetZ }

        ExecuteInGameThread(function()
            if not ghost:IsValid() then
                return
            end
            local ghostLoc = ghost:K2_GetActorLocation()
            offsetGhostToward(ghostLoc, px, py, pz)
            ghost:K2_SetActorLocationAndRotation(ghostLoc, rot, false, {}, false)
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
