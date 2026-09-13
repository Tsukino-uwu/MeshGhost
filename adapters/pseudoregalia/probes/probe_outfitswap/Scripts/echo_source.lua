-- MeshGhost OUTFIT ECHO SOURCE (2026-09-13). DRIVES A GHOST'S MESH -- never the player's.
--
-- Measured already (echo_watch.lua): every ghost SPAWN re-runs costume setup on the LOCAL player
-- (its dynamicEyesMat is rebuilt, five of five), and after a peer's swap the player comes out of
-- that re-run wearing the peer's costume. Reproduced on a fresh v1.2.9 install with only the
-- costume paks. The adapter never writes the player's mesh, so the question is where the re-run
-- READS the costume from.
--
-- The experiment: with no human swapping anything, set the LIVE peer ghost's body to a costume
-- nobody is wearing (the same SetSkeletalMeshAsset the adapter uses), then wait for the replay
-- loop's next respawn and see what the player comes out wearing.
--   player -> that costume    : the re-run reads a GHOST's current mesh. No network involved.
--   player unchanged          : the source is not a ghost's mesh; widen (save object, peer data).
-- Then the ghost is put back, and one more respawn shows whether the player follows it back.
--
-- Every sample records every player-class pawn in FindAllOf's own ORDER, because "the first actor
-- of the class" is the leading suspect for how a lookup for the player lands on a ghost, and the
-- order at the moment of each spawn is what would show it. The controller's pawn is recorded too,
-- in case a spawn briefly hands the controller to a ghost.
--
-- Endurance, not timing: nothing to press. The replay loop must be running (shift+2). Your own
-- character may end up in the test costume; re-pick your outfit in the game's menu afterwards.
-- Dev-only tooling; never ships.

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
    -- Prefer a costume that is not the game's own default, so a reset-to-default is not mistaken
    -- for a copy.
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
            -- The live peer ghost is the non-player pawn that has existed the longest: the replay
            -- ghost is replaced at every loop, so it is never the oldest.
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
