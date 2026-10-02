-- Outline stage 3: does the outline pass key on the custom-depth stencil? Writes ghost meshes, never the player's:
-- every 500 ms for 180 s, each ghost's VisualMesh and WeaponMesh get SetCustomDepthStencilValue(STENCIL) and
-- SetRenderCustomDepth(true). Arm keep_custom_depth.txt beside the DLL first, or the shipping mod's hold fights
-- it and the screen flickers. Every touched stencil goes back to 0 at the end; unload it before judging anything.

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
        -- One write to the player: the afterimage sweep may have stripped the body, which then cannot be outlined.
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
