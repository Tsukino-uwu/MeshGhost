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
-- DESIGN HISTORY (full blow-by-blow in git history and agent_docs/phases/phase7.md -- this is
-- the short version of how the file arrived here):
--
-- 1. First design spawned a second BP_PlayerGoatMain_C (the player's own Blueprint) via
--    world:SpawnActor. It rendered fine, but auto-possessed itself on spawn (a real Blueprint
--    default) and its camera stayed stuck on it even after re-possessing the real player --
--    five straight fixes (Possess, SetViewTargetWithBlend in three shapes,
--    CameraComponent:Activate/:Deactivate) all failed or had zero visible effect.
-- 2. Pivoted to a plain, non-Pawn StaticMeshActor to sidestep the whole bug class structurally.
--    It never auto-possesses and has no CameraComponent -- but across five live runs, a
--    freshly-SpawnActor'd StaticMeshActor was NEVER visible on screen, despite position,
--    mobility, and mesh assignment all independently confirmed correct via direct log evidence
--    (an honest intended-vs-actual position readback, a real cooked mesh borrowed from a
--    definitely-rendering level prop). Hijacking an *existing* level actor (FindAllOf +
--    reposition, no SpawnActor at all) rendered and moved correctly every time -- proving the
--    bug is specific to actors spawned at runtime via SpawnActor, not positioning/mesh/mobility.
--    Root cause never fully explained (the private RE-UE4SS `Unreal`/UEPseudo submodule blocks
--    reading the actual engine source), but the practical fact is directly observed.
-- 3. Went back to spawning BP_PlayerGoatMain_C (confirmed to actually render) instead of
--    fighting the StaticMeshActor rendering mystery. The camera bug resurfaced as expected.
--    RegisterHook("/Script/Engine.PlayerController:SetViewTargetWithBlend") revealed the real
--    mechanism: this game uses dedicated, pre-placed BP_PlayerCam_C camera-rig actors switched
--    between by a custom MainPlayerController_C -- not a simple pawn-owns-its-camera system.
--    Spawning the ghost at the player's exact location triggers the game's OWN camera-rig
--    switching logic to re-fire (almost certainly an overlap/proximity trigger, since the ghost
--    briefly shares the player's collision before SetActorEnableCollision(false) can run --
--    SpawnActor is a synchronous, non-deferred spawn per RE-UE4SS's own LuaUWorld.cpp source).
-- 4. FIX: since the unwanted re-target goes through a function already being hooked, the hook's
--    post-callback fights back -- remembers the last known-good ViewTarget before any ghost
--    exists, and if the game changes it away from that while a ghost exists, immediately calls
--    SetViewTargetWithBlend again to force it back. Confirmed working live, twice, across a
--    level transition (agent_docs/phases/phase7.md, agent_docs/verified.md).
--
-- Grounded APIs (bundled RE-UE4SS docs first, `gh api search/code` fallback, per CLAUDE.md):
--   UEHelpers.GetPlayerController()/.Pawn, UEHelpers.GetWorld()  -- confirmed live in 7.1
--   UWorld:SpawnActor(UClass, FVector, FRotator)                 -- docs/lua-api/classes/uworld.md
--   AActor:K2_GetActorLocation()/K2_GetActorRotation()            -- confirmed live in 7.1
--   AActor:K2_SetActorLocationAndRotation(...)                    -- SplitScreenMod, a bundled mod
--   AActor:GetComponentByClass(UClass)                            -- gh api search/code, 339 hits
--   AActor:SetActorEnableCollision(bool)                          -- gh api search/code, 172 hits
--   AActor:GetClass(), Controller:Possess(pawn)                   -- confirmed live this phase
--   RegisterHook(path, preFn, postFn)                             -- docs/lua-api/global-functions/registerhook.md
--   Direct UPROPERTY reads/writes (.bIsActive, controller.PlayerCameraManager.ViewTarget.Target)
--     -- this build's UFunction reflection is noticeably incomplete relative to the bundled docs
--     (confirmed: GetStaticMesh, IsHidden, SetVisibility, MarkRenderStateDirty, DestroyComponent,
--     CameraComponent:Activate, UStruct:ForEachProperty all fail live despite being documented or
--     present in RE-UE4SS's own source at the matching commit) -- direct property access has
--     been the one reliably working mechanism throughout this investigation.

local UEHelpers = require("UEHelpers")

local OFFSET_X = -150.0
local FOLLOW_INTERVAL_MS = 100
local SPAWN_DELAY_TICKS = 50 -- ~5s at FOLLOW_INTERVAL_MS -- not required for correctness (the
                              -- camera-hook fix works regardless of spawn timing, confirmed
                              -- live), kept as a deliberate buffer so the player's own camera is
                              -- unambiguously settled before any ghost exists.

local ghost = nil
local spawning = false -- guards against a second spawn firing while the first's
                        -- ExecuteInGameThread callback is still pending
local lastLoggedState = nil
local ticksSincePawnValid = 0

-- MIN_PLAUSIBLE_DISTANCE: spawning on the very first tick a pawn becomes non-nil can read back
-- K2_GetActorLocation() as (0,0,0) -- the pawn object existing doesn't mean its transform has
-- been placed yet during the level-load sequence (confirmed live in 7.1, real positions here are
-- in the thousands). Guard against spawning at a bogus near-origin location.
local MIN_PLAUSIBLE_DISTANCE = 100.0

-- MAX_TICK_DELTA / REFUSAL_RESYNC_LIMIT: defensive backstop for the follow loop. A single tick
-- moving further than this is refused and logged rather than applied -- normal player movement
-- between 100ms ticks is nowhere near this. But a real displacement (a dash, or a level
-- transition teleporting the player) can persist for several ticks in a row; refusing forever
-- would freeze the ghost far from the player permanently (confirmed live: refused an
-- ever-growing gap for an entire run once). After REFUSAL_RESYNC_LIMIT consecutive refusals, the
-- ghost resyncs straight to the target instead of freezing forever.
local MAX_TICK_DELTA = 500.0
local REFUSAL_RESYNC_LIMIT = 5

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
-- from the player pawn. K2_GetActorLocation() appears to return a live reference into the
-- actor's own transform, not a detached copy -- mutating a vector read from the pawn writes
-- directly into the real player's position (found live, the hard way, earlier this phase).
-- Reading fields off the pawn's vector is fine; only ever writing into it is the danger.
local function offsetGhostToward(ghostLoc, px, py, pz)
    ghostLoc.X = px + OFFSET_X
    ghostLoc.Y = py
    ghostLoc.Z = pz
end

-- lastKnownGoodViewTarget: captured the first time the camera hook fires while no ghost exists
-- -- i.e. the game's own natural, uninterfered-with camera choice (a BP_PlayerCam_C rig actor,
-- not the pawn -- see the design history above). The hook's post-callback fights back: if the
-- target changes away from this while a ghost exists, it's the game's own overlap/proximity
-- trigger reacting to the ghost, and gets forced back immediately.
local lastKnownGoodViewTarget = nil

local function tryHookCameraCalls()
    local svtwbOk, svtwbErr = pcall(function()
        RegisterHook("/Script/Engine.PlayerController:SetViewTargetWithBlend",
            function(Context, NewViewTarget)
                local ctx = Context:get()
                local target = NewViewTarget:get()
                print(string.format(
                    "[MeshGhostGhostProbe] HOOK: SetViewTargetWithBlend called on %s -> NewViewTarget=%s\n",
                    (ctx ~= nil and ctx:IsValid()) and ctx:GetFullName() or "nil/invalid",
                    (target ~= nil and target:IsValid()) and target:GetFullName() or "nil/invalid"))
            end,
            function(Context, NewViewTarget)
                local ctxOk, ctx = pcall(function() return Context:get() end)
                local targetOk, target = pcall(function() return NewViewTarget:get() end)
                if not ctxOk or not targetOk or ctx == nil or not ctx:IsValid() or target == nil or not target:IsValid() then
                    return
                end

                if ghost == nil then
                    -- No ghost yet -- this is the game's own natural choice, remember it.
                    lastKnownGoodViewTarget = target
                    return
                end

                if lastKnownGoodViewTarget == nil or not lastKnownGoodViewTarget:IsValid() then
                    return -- nothing to restore
                end

                if target:GetAddress() == lastKnownGoodViewTarget:GetAddress() then
                    return -- already correct, nothing to fight
                end

                print(string.format(
                    "[MeshGhostGhostProbe] HOOK: FIGHTING BACK -- ghost exists and target changed to %s, forcing back to %s\n",
                    target:GetFullName(), lastKnownGoodViewTarget:GetFullName()))
                -- Deferred via ExecuteInGameThread rather than called directly from inside this
                -- hook's own call stack -- no grounding either way for whether re-entrantly
                -- calling the same UFunction from within its own hook is safe on this build, so
                -- defaulting to the more cautious option. The corrective call re-triggers this
                -- same hook, but since it restores the exact captured target, the check above
                -- short-circuits it without recursing further -- confirmed live, no runaway loop.
                local restoreTarget = lastKnownGoodViewTarget
                ExecuteInGameThread(function()
                    if not restoreTarget:IsValid() or not ctx:IsValid() then
                        return
                    end
                    local fightOk, fightErr = pcall(function()
                        ctx:SetViewTargetWithBlend(restoreTarget, 0.0, 0, 0.0, false)
                    end)
                    print(string.format("[MeshGhostGhostProbe] HOOK: SetViewTargetWithBlend override: %s\n",
                        fightOk and "ok" or ("FAILED: " .. tostring(fightErr))))
                end)
            end)
    end)
    print(string.format("[MeshGhostGhostProbe] HOOK: registered SetViewTargetWithBlend hook: %s\n",
        svtwbOk and "ok" or ("FAILED: " .. tostring(svtwbErr))))
end

local function trySpawnGhost(pawn, controller)
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

        ExecuteInGameThread(function()
            local classOk, pawnClass = pcall(function() return pawn:GetClass() end)
            if not classOk or pawnClass == nil or not pawnClass:IsValid() then
                spawning = false
                print("[MeshGhostGhostProbe] pawn:GetClass() FAILED.\n")
                return
            end
            ghost = world:SpawnActor(pawnClass, loc, rot)
            spawning = false
            if ghost == nil or not ghost:IsValid() then
                print("[MeshGhostGhostProbe] SpawnActor(pawn's own class) returned nil/invalid.\n")
                return
            end
            print("[MeshGhostGhostProbe] ghost spawned (pawn's own class).\n")

            -- BP_PlayerGoatMain_C auto-possesses on spawn (a real Blueprint default) -- hand
            -- control back immediately. Confirmed live: an 82-second run with no dragging once
            -- this fix was in place, versus ~13s to death on every dragged run before it.
            local possessOk = pcall(function() controller:Possess(pawn) end)
            print(string.format("[MeshGhostGhostProbe] re-possess original pawn: %s\n",
                possessOk and "ok" or "FAILED"))

            -- bIsActive=false on the ghost's own camera is not the actual fix (the hook above
            -- is) -- confirmed live to apply correctly and still have zero visual effect on its
            -- own. Left in as a harmless, cheap extra rather than ripped out.
            local cameraComponentClass = StaticFindObject("/Script/Engine.CameraComponent")
            local camOk, camErr = pcall(function()
                if cameraComponentClass == nil or not cameraComponentClass:IsValid() then
                    error("CameraComponent class not found via StaticFindObject")
                end
                local ghostCamera = ghost:GetComponentByClass(cameraComponentClass)
                if ghostCamera == nil or not ghostCamera:IsValid() then
                    error("ghost has no CameraComponent")
                end
                ghostCamera.bIsActive = false
            end)
            if not camOk then
                print(string.format("[MeshGhostGhostProbe] ghost camera bIsActive=false FAILED: %s\n", tostring(camErr)))
            end

            local collisionOk = pcall(function() ghost:SetActorEnableCollision(false) end)
            print(string.format("[MeshGhostGhostProbe] SetActorEnableCollision(false): %s\n",
                collisionOk and "ok" or "FAILED"))
        end)
    end)
    if not ok then
        spawning = false
        print(string.format("[MeshGhostGhostProbe] spawn FAILED: %s\n", tostring(err)))
    end
end

local lastGhostTarget = nil -- {x, y, z} of the last position actually applied to the ghost,
                             -- for the MAX_TICK_DELTA backstop
local POSITION_LOG_INTERVAL_TICKS = 20 -- ~2s at FOLLOW_INTERVAL_MS=100
local followTickCount = 0
local consecutiveRefusals = 0

local function followTick()
    local pawn, controller, err = safeGetPawn()
    if pawn == nil then
        if lastLoggedState ~= "waiting" then
            print("[MeshGhostGhostProbe] " .. tostring(err) .. "\n")
            lastLoggedState = "waiting"
        end
        return false
    end

    -- Safety backstop: if controller.Pawn is ever the ghost itself (e.g. a future auto-possess
    -- regression), refuse to move anything rather than silently dragging the player again --
    -- found live earlier this phase when a second diagnostic ghost auto-possessed itself and
    -- this function's fresh-every-tick pawn re-fetch meant "pawn" silently became a ghost.
    if ghost ~= nil and ghost:IsValid() and pawn:GetAddress() == ghost:GetAddress() then
        if lastLoggedState ~= "pawn_is_ghost" then
            print("[MeshGhostGhostProbe] SAFETY: controller.Pawn is currently the ghost -- refusing to move anything this tick.\n")
            lastLoggedState = "pawn_is_ghost"
        end
        return false
    end

    if ghost == nil then
        ticksSincePawnValid = ticksSincePawnValid + 1
        if ticksSincePawnValid < SPAWN_DELAY_TICKS then
            if lastLoggedState ~= "delaying" then
                print(string.format("[MeshGhostGhostProbe] valid pawn found, delaying ghost spawn for %d more ticks...\n",
                    SPAWN_DELAY_TICKS - ticksSincePawnValid))
                lastLoggedState = "delaying"
            end
            return false
        end
        if not spawning then
            print("[MeshGhostGhostProbe] delay elapsed, spawning ghost...\n")
            trySpawnGhost(pawn, controller)
            lastLoggedState = "spawning"
        end
        return false
    end

    if not ghost:IsValid() then
        -- Exiting to the main menu or a level transition can invalidate the ghost -- reset all
        -- ghost-scoped state so the next tick naturally attempts a fresh spawn once a valid pawn
        -- exists again, rather than staying permanently stuck on a stale reference.
        print("[MeshGhostGhostProbe] ghost became invalid (level transition or main menu?), will attempt to respawn.\n")
        ghost = nil
        lastGhostTarget = nil
        lastLoggedState = nil
        return false
    end

    local ok, followErr = pcall(function()
        -- Read-only on the pawn's own vectors: px/py/pz/rot are plain values or a struct we
        -- never write back into. The only mutation happens below, on ghostLoc -- a vector owned
        -- by the ghost itself, fetched fresh each tick.
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
                consecutiveRefusals = consecutiveRefusals + 1
                if consecutiveRefusals < REFUSAL_RESYNC_LIMIT then
                    print(string.format(
                        "[MeshGhostGhostProbe] refusing implausible single-tick move of %.2f units (max %.2f) -- freezing ghost in place, not applying (%d/%d consecutive).\n",
                        tickDist, MAX_TICK_DELTA, consecutiveRefusals, REFUSAL_RESYNC_LIMIT))
                    return
                end
                print(string.format(
                    "[MeshGhostGhostProbe] %d consecutive refused moves -- treating as a real displacement, resyncing ghost straight to target instead of freezing forever.\n",
                    consecutiveRefusals))
            end
        end
        consecutiveRefusals = 0
        lastGhostTarget = { x = targetX, y = targetY, z = targetZ }

        ExecuteInGameThread(function()
            if not ghost:IsValid() then
                return
            end
            local ghostLoc = ghost:K2_GetActorLocation()
            offsetGhostToward(ghostLoc, px, py, pz)
            local intendedX, intendedY, intendedZ = ghostLoc.X, ghostLoc.Y, ghostLoc.Z
            ghost:K2_SetActorLocationAndRotation(ghostLoc, rot, false, {}, false)

            followTickCount = followTickCount + 1
            if followTickCount % POSITION_LOG_INTERVAL_TICKS == 0 then
                -- Fetch a genuinely fresh read here, in a separate call, rather than re-printing
                -- ghostLoc (the same table just written into) -- that would only prove what was
                -- written, not what stuck.
                local actualLoc = ghost:K2_GetActorLocation()
                print(string.format(
                    "[MeshGhostGhostProbe] pawn=(%.2f, %.2f, %.2f) intended=(%.2f, %.2f, %.2f) actual=(%.2f, %.2f, %.2f)\n",
                    px, py, pz, intendedX, intendedY, intendedZ, actualLoc.X, actualLoc.Y, actualLoc.Z))
            end
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

tryHookCameraCalls()

print("[MeshGhostGhostProbe] Phase 7.4 placeholder-ghost probe running (spawned-pawn-class + camera-hook design).\n")
LoopAsync(FOLLOW_INTERVAL_MS, followTick)
