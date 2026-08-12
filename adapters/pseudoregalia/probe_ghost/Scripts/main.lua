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
-- Three real bugs found across three live runs, 2026-08-12, all fixed here:
--
-- (1) Spawning on the very first tick the pawn becomes non-nil read K2_GetActorLocation() back
-- as (0,0,0) -- the pawn object existing doesn't mean its transform has been placed yet during
-- the level-load sequence, so the ghost spawned near world origin instead of next to the
-- player and was never visible. Guarded by MIN_PLAUSIBLE_DISTANCE below.
--
-- (2) ExecuteInGameThread queues its callback for a later game-thread tick, so checking
-- `ghost == nil` on the very next LoopAsync tick (100ms later) could still see nil and fire a
-- second, redundant spawn before the first callback had run. Guarded by the `spawning` flag.
--
-- (3) The real one: after fixing (1) and (2), the user was physically dragged/pulled toward
-- another location at high speed on two separate runs, in a straight line, until dying. First
-- suspected collision/physics from the unstripped Blueprint clone -- SetActorEnableCollision(false)
-- and SetActorTickEnabled(false) were added, and made ZERO difference on the second dragged
-- run, ruling that theory out. Actual cause, found by re-reading the code rather than guessing
-- again: the old follow loop read `pawn:K2_GetActorLocation()` fresh each tick and mutated its
-- X field in place before handing that same object to the ghost's position setter.
-- K2_GetActorLocation() appears to return a *live reference* into the actor's own transform,
-- not a detached copy -- so that mutation was writing directly into the REAL PLAYER's position,
-- +150 units roughly every 100ms, compounding forever. A smooth, straight-line, never-ending
-- drift is exactly what a runaway position write looks like. Fixed by never mutating anything
-- read from the pawn -- offsetGhostToward below only ever writes into a vector owned by the
-- ghost itself. Left the collision/tick calls in place since they're still a reasonable safety
-- measure even though they weren't the actual fix.

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
            -- Found live 2026-08-12: an unstripped spawned copy of the player's own gameplay
            -- Blueprint physically dragged the real player around via what's suspected to be
            -- collision -- see agent_docs/risks.md and agent_docs/verified.md. Neither call
            -- below is documented in this install's bundled RE-UE4SS docs (that doc set is
            -- confirmed incomplete -- K2_SetActorLocationAndRotation isn't there either, yet
            -- works), so grounded instead via `gh api search/code` confirming both as real,
            -- commonly-used AActor functions across independent UE-Lua-modding projects
            -- (SetActorEnableCollision: 172 hits, SetActorTickEnabled: 138 hits) -- not read
            -- from any single project's source, just confirmed the names are real. Tried
            -- defensively, each logged, not assumed to work.
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
        -- Read-only on the pawn's own vectors: px/py/pz/rot are plain values or a struct we
        -- never write back into. The only mutation happens below, on ghostLoc -- a vector
        -- owned by the ghost itself, fetched fresh each tick.
        local pawnLoc = pawn:K2_GetActorLocation()
        local px, py, pz = pawnLoc.X, pawnLoc.Y, pawnLoc.Z
        local rot = pawn:K2_GetActorRotation()
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
