-- Leak counter, read-only: the engine's own count of each class once a second, with peak and trough, across ghost
-- despawns, because hiding is what clears the screen and the adapter's own destroy count is what is in doubt.
-- Drive it by killing meshghost.exe: the adapter restarts it and every ghost despawns and respawns. It counts a class,
-- not ownership, and UE frees on its own schedule: a count high across several cycles is a leak, one reading is not.

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
        -- A leak pushes the peak up and keeps the trough from coming back: one current value shows neither.
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
