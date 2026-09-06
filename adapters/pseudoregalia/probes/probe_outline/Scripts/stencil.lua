-- MeshGhost OUTLINE probe, stage 3 -- do ghosts on a DIFFERENT custom-depth stencil stop occluding
-- the player's outline WITHOUT drawing their own silhouette through walls? **THIS ONE WRITES** to
-- ghost meshes (never the player's) for as long as it runs, and puts them back when it ends.
--
-- THE OTHER HALF OF THE 2026-09-05 REPORT: with ghosts stripped of custom depth (shipped), a ghost
-- standing between camera and player is opaque scene depth that writes no custom depth, so the
-- outline pass sees the player as "behind something" and draws the blue silhouette on them.
-- Measured the same day with `keep_custom_depth.txt`: ghosts WRITING custom depth (stencil 0, the
-- player's value) removes that -- and gives every ghost the player's through-walls silhouette.
--
-- THE QUESTION: does the game's outline post-process key on the STENCIL value? If it draws only
-- stencil 0, ghost meshes on stencil 1 would still win the custom-depth pass where they overlap the
-- player (no outline on the player behind a ghost) while never being drawn as a silhouette
-- themselves (no ghost through walls). If it ignores stencil, both come back together and the
-- trade-off is the user's to choose. Only the screen can answer; this sets the state up.
--
-- WHAT IT DOES, every 500 ms for 180 s from the moment the player pawn exists:
--   for every GHOST pawn (a BP_PlayerGoatMain_C that is not the controller's pawn), on
--   VisualMesh and WeaponMesh: SetCustomDepthStencilValue(STENCIL) and SetRenderCustomDepth(true),
--   re-asserted each sample because the shipping mod holds custom depth OFF on ghosts every tick
--   (arm `keep_custom_depth.txt` beside the DLL first, or the two fight and the screen flickers).
--   Readback printed on change per mesh. The PLAYER's meshes are written ONCE at start -- custom depth
--   back ON, the fresh-pawn state, because the shipping sweep may have stripped the body -- then only read. At the end: stencil back to 0 on every mesh it touched, custom depth left to the
--   shipping hold. Countdown at 120/60/30/10 s.
--
-- Grounded APIs: UPrimitiveComponent::SetCustomDepthStencilValue(int32) and SetRenderCustomDepth
-- (bool) (docs.unrealengine.com); UE4SS Lua FindAllOf/IsValid/GetFullName/LoopAsync (vendored
-- RE-UE4SS/docs/lua-api). Dev-only tooling; never ships. Unload before judging anything else.

local TAG = "[MeshGhostOutlineProbe3]"
local PAWN_CLASS = "BP_PlayerGoatMain_C"
local STENCIL = 255
local INTERVAL_MS = 500
local DURATION_S = 180
local MESHES = { "VisualMesh", "WeaponMesh" }

local samples, clock_samples = 0, 0
local ended = false
local last_line = {}
local touched = {}   -- full name -> component

local function full_name(obj) local n; pcall(function() n = obj:GetFullName() end); return n or "?" end
local function short(name) return (tostring(name):gsub("^.*[/%.]([^/%.]+%.[^/%.]+)$", "%1")) end
local function valid(obj) local ok, v = pcall(function() return obj:IsValid() end); return ok and v == true end
local function prop(obj, name) local v; if not pcall(function() v = obj[name] end) then return nil end; return v end
local function is_default(obj) return full_name(obj):find("Default__", 1, true) ~= nil end
local function emit(key, line)
    if last_line[key] ~= line then last_line[key] = line; print(string.format("%s #%d %s\n", TAG, samples, line)) end
end

local function player_pawn()
    for _, pc in pairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn = prop(pc, field)
                if pawn ~= nil and valid(pawn) then return pawn end
            end
        end
    end
    return nil
end

local function readback(c)
    return string.format("customdepth=%s stencil=%s", tostring(prop(c, "bRenderCustomDepth")), tostring(prop(c, "CustomDepthStencilValue")))
end

local function sample()
    samples = samples + 1
    local player = player_pawn()
    if not player then return end
    clock_samples = clock_samples + 1
    local pn = full_name(player)
    if clock_samples == 1 then
        print(string.format("%s START: player=%s; ghost meshes -> stencil %d, custom depth ON, re-asserted every sample.\n", TAG, short(pn), STENCIL))
        -- ONE write to the player, once: put the body and sword back to the fresh-pawn state (both
        -- custom depth ON, stage 1), because the shipping mod's afterimage sweep may have stripped
        -- the body since the last slide or attack (stage 2) -- a stripped body cannot be outlined
        -- behind a ghost, and this run has to be able to tell stencil from that.
        for _, m in ipairs(MESHES) do
            local c = prop(player, m)
            if c ~= nil and type(c) ~= "boolean" and type(c) ~= "number" and valid(c) then
                local before = prop(c, "bRenderCustomDepth")
                pcall(function() c:SetRenderCustomDepth(true) end)
                print(string.format("%s   player %s custom depth: was %s, now reads %s (restored once so the test is valid)\n", TAG, m, tostring(before), tostring(prop(c, "bRenderCustomDepth"))))
            end
        end
    end
    for _, m in ipairs(MESHES) do
        local c = prop(player, m)
        if c ~= nil and type(c) ~= "boolean" and type(c) ~= "number" and valid(c) then
            emit("player/" .. m, string.format("PLAYER %s: %s (read only)", m, readback(c)))
        end
    end
    for _, pawn in pairs(FindAllOf(PAWN_CLASS) or {}) do
        if valid(pawn) and not is_default(pawn) and full_name(pawn) ~= pn then
            for _, m in ipairs(MESHES) do
                local c = prop(pawn, m)
                if c ~= nil and type(c) ~= "boolean" and type(c) ~= "number" and valid(c) then
                    pcall(function() c:SetCustomDepthStencilValue(STENCIL) end)
                    pcall(function() c:SetRenderCustomDepth(true) end)
                    touched[full_name(c)] = c
                    emit("ghost/" .. full_name(c), string.format("GHOST %s.%s: %s", short(full_name(pawn)), m, readback(c)))
                end
            end
        end
    end
    local left = DURATION_S - (clock_samples * INTERVAL_MS) / 1000
    if left == 120 or left == 60 or left == 30 or left == 10 then print(string.format("%s %ds left.\n", TAG, left)) end
    if left <= 0 and not ended then
        ended = true
        local n = 0
        for _, c in pairs(touched) do
            if valid(c) then pcall(function() c:SetCustomDepthStencilValue(0) end); n = n + 1 end
        end
        print(string.format("%s END: stencil back to 0 on %d mesh(es); custom depth left to the shipping hold. Stopped; nothing left running.\n", TAG, n))
    end
end

LoopAsync(INTERVAL_MS, function()
    if ended then return true end
    local ok, err = pcall(sample)
    if not ok then print(string.format("%s sample error: %s\n", TAG, tostring(err))) end
    return false
end)
print(string.format("%s loaded: ghosts to stencil %d for %d s. Arm keep_custom_depth.txt first.\n", TAG, STENCIL, DURATION_S))
