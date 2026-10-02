-- Auto-possess diagnostic: spawns one ghost and never repositions anything, then logs every tick the original pawn's,
-- the ghost's and the controller's current Pawn's addresses; controller.Pawn equal to the ghost is a possession swap.
-- Also reads ghost.AutoPossessPlayer once. It still spawns a real gameplay Blueprint, so it needs its own go-ahead.
-- Deploy by copying it over the deployed mod's main.lua, after backing that up.

local UEHelpers = require("UEHelpers")

local TICK_INTERVAL_MS = 250 -- observation, not a follow loop: fewer log lines

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

    -- controller.Pawn is re-read every tick, never cached.
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
