-- MeshGhost component-LEAK counter. The user's question, 2026-09-04: the ground looks clean after a
-- ghost despawns, *"but might be the same like ghosts being stuck in garbagecollection after
-- leaving?"*
--
-- WHY IT IS THE RIGHT QUESTION. The adapter's despawn cleanup hides, stops, then destroys each
-- world-spawned effect. HIDING is what removes it from the screen, so a clean-looking floor proves
-- only the first step ran. The adapter's own log said `0 world-spawned component(s) destroyed` on
-- every despawn of that session, which means either the destroy never resolved on this build or the
-- counter was blind -- and in both cases the components could still be sitting in memory, exactly
-- like a ghost the engine has not collected yet.
--
-- WHAT SETTLES IT: the population over time, across despawns. A count that climbs by a few every
-- time a ghost leaves and never comes back down is a leak. A count that returns to its baseline is
-- not, whatever the log says. This asks the ENGINE how many exist rather than asking our own
-- bookkeeping, which is the whole point -- our bookkeeping is what is in doubt.
--
-- HOW TO DRIVE IT (agent side, no game restart): kill meshghost.exe. The adapter respawns it, the
-- replays reload, ghosts despawn and respawn. Each cycle is one despawn per ghost.
--
-- WHAT THIS CANNOT SEE:
--   * It counts a CLASS, not ownership. A count that rises while the local player is walking
--     through their own dust is the game's, not ours -- which is why the baseline matters more than
--     any single reading, and why it prints the peak and the trough rather than one number.
--   * UE frees on its own schedule, so a count that stays high for a few seconds is not yet a leak.
--     A count that stays high across several despawn cycles is.
--   * It cannot tell WHICH component is ours. If this says "leak", the next instrument names them.
--
-- Read-only: no UFunction is called on anything FindAllOf returned, no property is written.
-- Dev-only tooling; never ships.

local TAG = "[MeshGhostLeakCount]"
local INTERVAL_MS = 1000
local CLASSES = { "NiagaraComponent", "BP_PlayerGoatMain_C" }

local peak = {}
local trough = {}
local last = {}
local samples = 0

local function count_of(class_name)
    local objs = FindAllOf(class_name)
    if not objs then return 0 end
    local n = 0
    for _ in pairs(objs) do n = n + 1 end
    return n
end

local function sample()
    samples = samples + 1
    local parts = {}
    local changed = false
    for _, class_name in ipairs(CLASSES) do
        local n = count_of(class_name)
        if peak[class_name] == nil or n > peak[class_name] then peak[class_name] = n end
        if trough[class_name] == nil or n < trough[class_name] then trough[class_name] = n end
        if last[class_name] ~= n then changed = true end
        last[class_name] = n
        -- Peak and trough travel with every line: the peak is what a leak pushes up and the trough
        -- is the number that must come back down. One current value cannot show either.
        parts[#parts + 1] = string.format("%s=%d (peak %d, low %d)", class_name, n, peak[class_name], trough[class_name])
    end
    if changed or samples % 30 == 1 then
        print(string.format("%s %s  s=%d\n", TAG, table.concat(parts, "  "), samples))
    end
end

LoopAsync(INTERVAL_MS, function()
    ExecuteInGameThread(sample)
    return false
end)

print(string.format("%s loaded -- watching component population across despawns. A trough that never returns to its starting value is the leak.\n", TAG))
