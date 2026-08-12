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
-- PIVOTED 2026-08-12, after five straight live attempts to fix a camera-stuck-on-ghost bug on
-- an earlier design that spawned a full second instance of the player's own controllable
-- Blueprint (BP_PlayerGoatMain_C). That approach also caused a real, repeated player-dragging
-- bug (BP_PlayerGoatMain_C auto-possesses on spawn) before the camera issue was even reached.
-- Full history of both investigations -- five drag-bug fixes (two of them wrong guesses before
-- the real cause was diagnosed) and five failed-or-harmful camera fixes (Possess,
-- SetViewTargetWithBlend in three different shapes, a CameraComponent active-state fix
-- confirmed via diagnostic to have zero visible effect either way) -- is in git history for
-- this file, agent_docs/phases/phase7.md, agent_docs/verified.md, and agent_docs/risks.md.
-- Bottom line: none of the standard Unreal possession/camera APIs visibly controlled what the
-- user actually saw, which stopped being evidence-driven debugging and became guessing.
--
-- New design: spawn a plain, non-Pawn `StaticMeshActor` instead of a second player Blueprint.
-- This sidesteps the entire bug class structurally rather than patching around it -- a
-- StaticMeshActor is never a Pawn, so it can never be auto-possessed, never has a
-- PlayerController relationship, and never has a CameraComponent to compete for the view
-- target. Matches agent_docs/risks.md's own recorded mitigation and TEVI's 6.3 precedent (a
-- simple placeholder shape, not a player clone).
--
-- Grounded APIs, all confirmed the same way as before -- bundled RE-UE4SS docs first, `gh api
-- search/code` fallback (names/paths confirmed real across many independent projects, no
-- source read or copied), per CLAUDE.md:
--   UEHelpers.GetPlayerController()/.Pawn, UEHelpers.GetWorld()  -- confirmed live in 7.1
--   StaticFindObject(path)                                        -- docs/lua-api/global-functions/staticfindobject.md
--   UWorld:SpawnActor(UClass, FVector, FRotator)                  -- docs/lua-api/classes/uworld.md
--   AActor:K2_GetActorLocation()/K2_GetActorRotation()             -- confirmed live in 7.1
--   AActor:K2_SetActorLocationAndRotation(...)                     -- SplitScreenMod, a real bundled mod
--   AActor:GetComponentByClass(UClass)                             -- gh api search/code, 339 hits
--   AActor:SetActorEnableCollision(bool)                           -- gh api search/code, 172 hits
--   LoopAsync(intervalMs, callback), ExecuteInGameThread(fn)       -- confirmed live in 7.1/SplitScreenMod
-- NOT grounded, tried defensively (no bundled doc or example, and no confident gh api hit
-- count for the exact call shape -- see the load-mesh code below for what's actually tried and
-- logged): `StaticLoadObject` to force-load the basic cube mesh asset if it isn't already
-- resident in memory (StaticFindObject only finds already-loaded objects). Falls back to an
-- untextured actor (still visible as a default/placeholder shape in UE, just not a cube
-- specifically) if this fails -- logged either way, not assumed to work.

local UEHelpers = require("UEHelpers")

local OFFSET_X = 150.0
local FOLLOW_INTERVAL_MS = 100
local CUBE_MESH_PATH = "/Engine/BasicShapes/Cube.Cube" -- confirmed as a real, standard engine
                                                        -- asset path via `gh api search/code`
                                                        -- across many independent UE-Lua
                                                        -- projects, not read from any one of
                                                        -- them

local ghost = nil
local spawning = false -- guards against a second spawn firing while the first's
                        -- ExecuteInGameThread callback is still pending (found live 2026-08-12
                        -- on the earlier design; kept here since ExecuteInGameThread's async
                        -- queueing behavior is unchanged)
local lastLoggedState = nil

-- MIN_PLAUSIBLE_DISTANCE: found live 2026-08-12 on the earlier design -- spawning on the very
-- first tick a pawn becomes non-nil read back K2_GetActorLocation() as (0,0,0), even though
-- 7.1 already confirmed real positions here are in the thousands. The pawn object existing
-- doesn't mean its transform has been placed yet during the level-load sequence. Guard against
-- spawning at a bogus near-origin location by waiting for a position that isn't suspiciously
-- close to (0,0,0).
local MIN_PLAUSIBLE_DISTANCE = 100.0

-- MAX_TICK_DELTA: defensive backstop carried over from the earlier design. Refuses to move the
-- ghost further than this in a single tick, logging instead of applying it -- normal player
-- movement between 100ms ticks is nowhere near this; a jump this large means something is
-- wrong, and it's better to freeze the ghost in place and log loudly than move it somewhere
-- implausible.
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
-- from the player pawn. Found live 2026-08-12 on the earlier design, the hard way:
-- K2_GetActorLocation() appears to return a live reference into the actor's own transform, not
-- a detached copy -- mutating a vector read from the pawn writes directly into the real
-- player's position. Reading fields off the pawn's vector is fine; only ever writing into it
-- is the danger.
local function offsetGhostToward(ghostLoc, px, py, pz)
    ghostLoc.X = px + OFFSET_X
    ghostLoc.Y = py
    ghostLoc.Z = pz
end

-- tryLoadCubeMesh finds (or force-loads) the engine's default cube static mesh asset. Returns
-- the mesh object, or nil if every attempt failed -- callers must handle nil (spawn the actor
-- without a mesh assigned rather than error out).
local function tryLoadCubeMesh()
    local ok, mesh = pcall(function() return StaticFindObject(CUBE_MESH_PATH) end)
    if ok and mesh ~= nil and mesh:IsValid() then
        print("[MeshGhostGhostProbe] cube mesh already resident, found via StaticFindObject.\n")
        return mesh
    end

    -- Not already loaded -- try to force-load it. StaticLoadObject isn't in the bundled docs
    -- and this exact call shape isn't confidently grounded (see header comment); tried
    -- defensively, logged either way.
    local staticMeshClass = StaticFindObject("/Script/Engine.StaticMesh")
    local loadOk, loaded = pcall(function()
        return StaticLoadObject(staticMeshClass, nil, CUBE_MESH_PATH)
    end)
    if loadOk and loaded ~= nil and loaded:IsValid() then
        print("[MeshGhostGhostProbe] cube mesh force-loaded via StaticLoadObject.\n")
        return loaded
    end
    print(string.format(
        "[MeshGhostGhostProbe] could not find or load cube mesh (StaticFindObject miss, StaticLoadObject %s) -- ghost will spawn without an assigned mesh.\n",
        loadOk and "returned invalid" or ("errored: " .. tostring(loaded))))
    return nil
end

local function trySpawnGhost(pawn)
    spawning = true
    local ok, err = pcall(function()
        local world = UEHelpers.GetWorld()
        if world == nil or not world:IsValid() then
            error("no valid world")
        end
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

        local staticMeshActorClass = StaticFindObject("/Script/Engine.StaticMeshActor")
        if staticMeshActorClass == nil or not staticMeshActorClass:IsValid() then
            error("StaticMeshActor class not found via StaticFindObject")
        end

        -- Spawn AT the player's exact position, unmodified -- no mutation here, matching
        -- SplitScreenMod's confirmed safe pattern of reusing a struct read from one actor
        -- directly on another with no in-place writes. The fixed offset is applied afterward,
        -- once the ghost exists and has its own vector to mutate (see followTick).
        ExecuteInGameThread(function()
            ghost = world:SpawnActor(staticMeshActorClass, loc, rot)
            spawning = false
            if ghost == nil or not ghost:IsValid() then
                print("[MeshGhostGhostProbe] SpawnActor(StaticMeshActor) returned nil/invalid.\n")
                return
            end
            print("[MeshGhostGhostProbe] StaticMeshActor spawned.\n")

            -- No Possess/SetViewTargetWithBlend/CameraComponent calls anywhere in this file --
            -- StaticMeshActor is never a Pawn, so none of that machinery is relevant. This is
            -- the entire point of the pivot: the bug class this file used to work around no
            -- longer exists.
            local collisionOk = pcall(function() ghost:SetActorEnableCollision(false) end)
            print(string.format(
                "[MeshGhostGhostProbe] SetActorEnableCollision(false): %s\n",
                collisionOk and "ok" or "FAILED"))

            local meshOk, meshErr = pcall(function()
                local mesh = tryLoadCubeMesh()
                if mesh == nil then
                    return -- tryLoadCubeMesh already logged why
                end
                local staticMeshComponentClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
                if staticMeshComponentClass == nil or not staticMeshComponentClass:IsValid() then
                    error("StaticMeshComponent class not found via StaticFindObject")
                end
                local meshComponent = ghost:GetComponentByClass(staticMeshComponentClass)
                if meshComponent == nil or not meshComponent:IsValid() then
                    error("ghost has no StaticMeshComponent")
                end
                meshComponent:SetStaticMesh(mesh)
            end)
            if not meshOk then
                print(string.format("[MeshGhostGhostProbe] assigning cube mesh FAILED: %s\n", tostring(meshErr)))
            else
                print("[MeshGhostGhostProbe] cube mesh assignment attempted (see above for whether a mesh was found).\n")
            end
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
            trySpawnGhost(pawn)
            lastLoggedState = "spawning"
        end
        return false
    end

    if not ghost:IsValid() then
        -- Found live 2026-08-12 on the earlier design: exiting to the main menu and
        -- re-entering never spawned a new ghost, because `ghost` stayed a non-nil reference to
        -- the now-invalid object forever. Reset all ghost-scoped state so the next tick
        -- naturally attempts a fresh spawn once a valid pawn exists again -- covers both a
        -- real level transition and a main-menu round-trip the same way.
        print("[MeshGhostGhostProbe] ghost became invalid (level transition or main menu?), will attempt to respawn.\n")
        ghost = nil
        lastGhostTarget = nil
        lastLoggedState = nil
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

print("[MeshGhostGhostProbe] Phase 7.4 placeholder-ghost probe running (StaticMeshActor design).\n")
LoopAsync(FOLLOW_INTERVAL_MS, followTick)
