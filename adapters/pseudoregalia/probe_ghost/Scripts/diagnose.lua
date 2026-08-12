-- MeshGhost Phase 7.4 diagnostic: NOT a fix attempt. After three straight fix-and-retest
-- cycles that each failed to stop the player being dragged (see the "Three real bugs" / the
-- fourth-bug history in main.lua and agent_docs/phases/phase7.md), this script gathers
-- evidence instead of guessing a fourth time, per CLAUDE.md's "it ran without errors is not
-- evidence" standard.
--
-- Leading theory: BP_PlayerGoatMain_C may have "Auto Possess Player" set to Player 0 (a common
-- default on player pawn Blueprints). If so, the moment SpawnActor creates a second instance,
-- the existing PlayerController may silently possess IT instead, swapping
-- PlayerController.Pawn away from the original pawn. Every previous fix assumed the
-- *positioning math* was wrong; none of them could have helped if the object being "followed"
-- and the object being "moved" quietly became the same actor the whole time -- which would
-- also explain why no second ghost model was ever seen.
--
-- This script spawns the ghost (same guarded logic as main.lua: MIN_PLAUSIBLE_DISTANCE,
-- `spawning` flag) but performs ZERO repositioning -- no K2_SetActorLocationAndRotation call
-- anywhere. It only logs object addresses (UObject:GetAddress(), confirmed real:
-- RE-UE4SS/docs/lua-api/classes/uobject.md) every tick, comparing the *original* pawn's
-- address, the ghost's address, and the PlayerController's *current* Pawn address (re-fetched
-- fresh every tick, not cached) -- if the last two ever become equal, that's direct proof of
-- an auto-possession swap. Also tries reading ghost.AutoPossessPlayer (a plain, non-mutating
-- property read, same reflection mechanism already proven safe elsewhere) and logs its
-- type/value once.
--
-- Deploy: swap this in as main.lua in the deployed mod folder, same as Stage 2/3's pattern --
-- back up whatever's currently there first. Needs its own go-ahead: it still spawns a real
-- second gameplay Blueprint instance, but does nothing that should be able to move the real
-- player, since it never calls any position-setting function at all.

local UEHelpers = require("UEHelpers")

local TICK_INTERVAL_MS = 250 -- slower than main.lua's 100ms; this is observation, not a
                              -- responsive follow loop, and slower ticking means fewer log lines

local ghost = nil
local originalPawnAddr = nil
local spawning = false
local lastLoggedState = nil

local MIN_PLAUSIBLE_DISTANCE = 100.0

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

local function addrOf(obj)
    if obj == nil then return "<nil>" end
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if not ok then return "<GetAddress failed>" end
    return string.format("0x%X", addr)
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
                "[MeshGhostDiagnose] pawn location looks implausible (%.2f, %.2f, %.2f), skipping this tick.\n",
                loc.X, loc.Y, loc.Z))
            spawning = false
            return
        end

        originalPawnAddr = addrOf(pawn)

        ExecuteInGameThread(function()
            ghost = world:SpawnActor(class, loc, rot)
            spawning = false
            if ghost == nil or not ghost:IsValid() then
                print("[MeshGhostDiagnose] SpawnActor returned nil/invalid.\n")
                return
            end
            print(string.format(
                "[MeshGhostDiagnose] SPAWNED. original pawn addr=%s  ghost addr=%s  (same=%s)\n",
                originalPawnAddr, addrOf(ghost), tostring(originalPawnAddr == addrOf(ghost))))

            local apOk, apVal = pcall(function() return ghost.AutoPossessPlayer end)
            print(string.format(
                "[MeshGhostDiagnose] ghost.AutoPossessPlayer read %s: type=%s value=%s\n",
                apOk and "OK" or "FAILED", type(apVal), tostring(apVal)))
        end)
    end)
    if not ok then
        spawning = false
        print(string.format("[MeshGhostDiagnose] spawn FAILED: %s\n", tostring(err)))
    end
end

local function diagnosticTick()
    local pawn, controller, err = safeGetPawn()
    if pawn == nil then
        if lastLoggedState ~= "waiting" then
            print("[MeshGhostDiagnose] " .. tostring(err) .. "\n")
            lastLoggedState = "waiting"
        end
        return false
    end

    if ghost == nil then
        if not spawning then
            print("[MeshGhostDiagnose] valid pawn found, spawning ghost (read-only, no repositioning)...\n")
            trySpawnGhost(pawn)
            lastLoggedState = "spawning"
        end
        return false
    end

    -- Once the ghost exists: every tick, log the CURRENT controller.Pawn address (fresh, not
    -- cached) next to the ghost's address and the original pawn's address. Read-only --
    -- no position is ever set here.
    local ok, logErr = pcall(function()
        local currentPawnAddr = "<no pawn>"
        if controller ~= nil and controller:IsValid() and controller.Pawn ~= nil and controller.Pawn:IsValid() then
            currentPawnAddr = addrOf(controller.Pawn)
        end
        local ghostAddr = ghost:IsValid() and addrOf(ghost) or "<ghost invalid>"
        local playerPos = "<no pawn>"
        if controller ~= nil and controller:IsValid() and controller.Pawn ~= nil and controller.Pawn:IsValid() then
            local loc = controller.Pawn:K2_GetActorLocation()
            playerPos = string.format("(%.2f, %.2f, %.2f)", loc.X, loc.Y, loc.Z)
        end
        print(string.format(
            "[MeshGhostDiagnose] tick: original=%s  ghost=%s  controller.Pawn=%s  (pawn==ghost: %s)  controller.Pawn pos=%s\n",
            originalPawnAddr, ghostAddr, currentPawnAddr, tostring(currentPawnAddr == ghostAddr), playerPos))
    end)
    if not ok then
        print(string.format("[MeshGhostDiagnose] tick logging FAILED: %s\n", tostring(logErr)))
    end

    return false -- keep looping
end

print("[MeshGhostDiagnose] Phase 7.4 diagnostic running -- read-only, no repositioning.\n")
LoopAsync(TICK_INTERVAL_MS, diagnosticTick)
