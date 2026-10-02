-- Outfit echo source, and it drives a ghost's mesh, never the player's: after a baseline, sets the live peer ghost's
-- body to a loaded costume nobody wears, waits for replay-loop respawns, then restores it, logging what the player
-- wears after each. Does the costume re-run on the player read a ghost's current mesh? Each sample records the pawns
-- in FindAllOf's own order and the controller's pawn, either of which could land a lookup for the player on a ghost.
-- Needs the replay loop running (shift+2); re-pick your outfit in the game's menu afterwards.

local TAG = "[MeshGhostEchoSource]"
local PERIOD_MS = 100
local BASELINE_MS = 25000       -- confirm the spawn -> re-run coupling first
local WAIT_MS = 45000           -- per phase; the loop respawns every ~18 s
local CHARS = "/Game/Meshes/Characters/"

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../echosource-" .. os.date("%H%M%S") .. ".log"
local out = io.open(OUT_PATH, "a")
local elapsed = 0
local function log(line) print(TAG .. " " .. line .. "\n") end
local function fout(line) if out then out:write(string.format("%s t=%06d ", os.date("%H:%M:%S"), elapsed), line, "\n") end end

local function valid(o) local ok, v = pcall(function() return o:IsValid() end) return ok and v == true end
local function prop(o, n) local v if not o or not pcall(function() v = o[n] end) then return nil end return v end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end) return (ok and a) and string.format("0x%x", a) or nil end
local function full(o) if o == nil or not valid(o) then return "none" end local s pcall(function() s = o:GetFullName() end) return s or "?" end
local function short(o) local f = full(o) return f:match("([^/]+)%.[^%.]*$") or f end
local function mesh_of(p)
    local vm = prop(p, "VisualMesh")
    return (vm ~= nil and valid(vm)) and prop(vm, "SkeletalMesh") or nil, vm
end

local phase, phase_t = "baseline", 0
local known = {}          -- pawn addr -> true
local order_prev = ""
local player_mesh_prev, eyes_prev = nil, nil
local live_ghost, live_orig, test_mesh = nil, nil, nil
local spawns_in_phase = 0

local function set_ghost_mesh(g, m, why)
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local _, vm = mesh_of(g)
            if vm == nil or not valid(vm) then fout("SET skipped: no VisualMesh") return end
            vm:SetSkeletalMeshAsset(m)
            local rb = mesh_of(g)
            fout(string.format("SET ghost %s -> %s (%s); readback %s", addr(g), short(m), why, short(rb)))
        end)
        if not ok then fout("SET failed: " .. tostring(err)) end
    end)
end

local function pick_test_mesh(worn)
    local all = nil
    pcall(function() all = FindAllOf("SkeletalMesh") end)
    local cands = {}
    for _, m in ipairs(all or {}) do
        local f = full(m)
        if valid(m) and f:find(CHARS, 1, true) and not worn[f] then cands[#cands + 1] = m end
    end
    fout("loaded costume candidates nobody wears: " .. #cands)
    for i, m in ipairs(cands) do if i <= 20 then fout("   " .. full(m)) end end
    -- Not the game's default costume, so a reset to default is not mistaken for a copy.
    for _, m in ipairs(cands) do if not full(m):find("dreamLady", 1, true) then return m end end
    return cands[1]
end

log("loaded. Needs the replay loop running (shift+2). Nothing to press. Log: " .. OUT_PATH)

LoopAsync(PERIOD_MS, function()
    elapsed = elapsed + PERIOD_MS
    local ok, err = pcall(function()
        local pc = nil
        pcall(function() pc = FindFirstOf("PlayerController") end)
        local player = (pc ~= nil and valid(pc)) and prop(pc, "Pawn") or nil
        if player == nil or not valid(player) then return end
        local pa = addr(player)

        local all = nil
        pcall(function() all = FindAllOf("BP_PlayerGoatMain_C") end)
        local order, worn, fresh = {}, {}, {}
        for i, p in ipairs(all or {}) do
            if valid(p) then
                local a = addr(p)
                local m = mesh_of(p)
                worn[full(m)] = true
                order[#order + 1] = string.format("%d:%s%s=%s", i, (a == pa) and "PLAYER" or "ghost", a, short(m))
                if not known[a] then known[a] = elapsed fresh[#fresh + 1] = a end
            end
        end
        local order_s = table.concat(order, " ")

        if #fresh > 0 and elapsed > PERIOD_MS then
            spawns_in_phase = spawns_in_phase + 1
            fout("SPAWN " .. table.concat(fresh, ",") .. "  order now: " .. order_s)
        elseif order_s ~= order_prev then
            fout("ORDER " .. order_s)
        end
        order_prev = order_s

        local pm = mesh_of(player)
        local eyes = addr(prop(player, "dynamicEyesMat"))
        if player_mesh_prev ~= nil and full(pm) ~= player_mesh_prev then
            fout(string.format("PLAYER MESH %s -> %s   [phase %s]", (player_mesh_prev:match("([^/]+)%.[^%.]*$") or player_mesh_prev), short(pm), phase))
        end
        if eyes_prev ~= nil and eyes ~= eyes_prev then fout("PLAYER costume setup re-ran (dynamicEyesMat " .. tostring(eyes) .. ")") end
        player_mesh_prev, eyes_prev = full(pm), eyes
        local ctrl_pawn = addr(prop(pc, "Pawn"))
        if ctrl_pawn ~= pa then fout("CONTROLLER holds " .. tostring(ctrl_pawn) .. " not the player") end

        local since = elapsed - phase_t
        if phase == "baseline" and since >= BASELINE_MS then
            -- The live peer ghost is the oldest non-player pawn: the replay ghost is replaced every loop.
            local oldest = nil
            for _, p in ipairs(all or {}) do
                local a = addr(p)
                if valid(p) and a ~= pa and prop(p, "bActorIsBeingDestroyed") ~= true and known[a] ~= nil and (oldest == nil or known[a] < oldest) then oldest = known[a] live_ghost = p end
            end
            if live_ghost ~= nil then fout("oldest non-player pawn first seen at t=" .. tostring(oldest)) end
            if live_ghost == nil then fout("ABORT: no long-lived ghost (is the other player in the room?)") phase = "done" return end
            live_orig = mesh_of(live_ghost)
            test_mesh = pick_test_mesh(worn)
            if test_mesh == nil then fout("ABORT: no loaded costume that nobody wears") phase = "done" return end
            fout(string.format("== PHASE test: live ghost %s wears %s; player wears %s; setting ghost to %s",
                addr(live_ghost), short(live_orig), short(pm), short(test_mesh)))
            set_ghost_mesh(live_ghost, test_mesh, "test")
            phase, phase_t, spawns_in_phase = "test", elapsed, 0
        elseif phase == "test" and (spawns_in_phase >= 2 or since >= WAIT_MS) then
            fout(string.format("== END test after %d spawn(s): player wears %s (test costume was %s)", spawns_in_phase, short(pm), short(test_mesh)))
            set_ghost_mesh(live_ghost, live_orig, "restore")
            phase, phase_t, spawns_in_phase = "restore", elapsed, 0
        elseif phase == "restore" and (spawns_in_phase >= 1 or since >= WAIT_MS) then
            fout(string.format("== END restore after %d spawn(s): player wears %s (ghost restored to %s)", spawns_in_phase, short(pm), short(live_orig)))
            phase = "done"
        end
        if out then out:flush() end
    end)
    if not ok then fout("PROBE ERROR: " .. tostring(err)) log("error: " .. tostring(err)) if out then out:flush() end return true end
    if phase == "done" then fout("DONE") if out then out:flush() end log("DONE -- " .. OUT_PATH) return true end
    return false
end)
