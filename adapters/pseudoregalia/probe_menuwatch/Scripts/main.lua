-- MeshGhost session-residue probe. 2026-08-31.
--
-- THE QUESTION, and it is the only one left standing after ten refuted fixes: the reset crash needs
-- a ghost to have EVER EXISTED this session. Not to exist now -- ghosts have been destroyed at the
-- click, destroyed when the pause menu opens, suppressed, and left alone, and the reset still
-- crashes; only a session where no peer ever connected survives it. So a ghost's SPAWN permanently
-- changes something, and no amount of tidying up afterwards undoes it.
--
-- Two singletons were censused from C++ (the GameInstance and the light manager, arrays and object
-- references) and neither showed it. This looks everywhere instead: a count of live objects PER
-- CLASS across the whole UObject space, on demand, so two snapshots can be diffed --
--
--     one taken before any peer connects, one after a ghost has spawned AND been destroyed
--
-- Anything whose count does not come back is the residue, and it needs no theory about what the
-- class is for.
--
-- HOW TO USE (no rebuild, no relaunch -- edit and press the hot-reload key to re-arm):
--   * The probe prints a full census ~8 seconds after load, labelled BASELINE.
--   * It prints another every time the pause menu opens, labelled LATER, with a DIFF against the
--     baseline. Opening the menu is a deliberate, cheap trigger the user already performs.
--
-- ForEachUObject walks every live object once; at ~200k objects that is a fraction of a second and
-- it runs only on those two occasions, never per tick. A probe that runs continuously would change
-- the timing of a crash that is already known to be a race.

local baseline = nil
local baseline_done = false
local last_cursor = nil

local function log(msg)
    print("[MeshGhostResidue] " .. msg .. "\n")
end

--- Says out loud which whole-space walker this UE4SS build actually has. A probe that silently
--- does nothing is indistinguishable from a finding of "nothing changed", and the first version of
--- this file failed at load with no output at all.
local walker_name, walker = nil, nil
if type(ForEachUObject) == "function" then
    walker_name, walker = "ForEachUObject", ForEachUObject
elseif type(UObjectGlobals) == "table" and type(UObjectGlobals.ForEachUObject) == "function" then
    walker_name, walker = "UObjectGlobals.ForEachUObject", UObjectGlobals.ForEachUObject
end

--- class name -> number of live, non-default objects.
local function census()
    local counts = {}
    if not walker then
        return counts
    end
    local ok, err = pcall(function()
        walker(function(obj)
            if not obj or not obj:IsValid() then
                return
            end
            local ok2, cls = pcall(function() return obj:GetClass():GetFName():ToString() end)
            if ok2 and cls then
                counts[cls] = (counts[cls] or 0) + 1
            end
        end)
    end)
    if not ok then
        log("census FAILED: " .. tostring(err))
    end
    return counts
end

local function print_diff(now)
    if not baseline then
        return
    end
    local keys = {}
    for k in pairs(now) do keys[#keys + 1] = k end
    for k in pairs(baseline) do if now[k] == nil then keys[#keys + 1] = k end end
    table.sort(keys)

    local changed = 0
    for _, k in ipairs(keys) do
        local was = baseline[k] or 0
        local is = now[k] or 0
        if is ~= was then
            changed = changed + 1
            log(string.format("  %-52s %6d -> %6d  (%+d)", k, was, is, is - was))
        end
    end
    log("diff vs baseline: " .. changed .. " class(es) changed")
end

-- The baseline, once, a few seconds after load: before any peer has had time to connect.
ExecuteWithDelay(8000, function()
    baseline = census()
    baseline_done = true
    local n = 0
    for _ in pairs(baseline) do n = n + 1 end
    log("BASELINE taken: " .. n .. " distinct classes live")
end)

-- A LATER census whenever the pause menu opens -- a trigger the user already performs, and one that
-- costs nothing while playing.
LoopAsync(500, function()
    if not baseline_done then
        return false
    end
    local pcs = FindAllOf("PlayerController")
    if not pcs then
        return false
    end
    for _, pc in ipairs(pcs) do
        if pc:IsValid() and not pc:GetFullName():find("Default__") then
            local ok, cursor = pcall(function() return pc.bShowMouseCursor end)
            if ok then
                if cursor and last_cursor == false then
                    log("LATER census (pause menu opened) --")
                    print_diff(census())
                end
                last_cursor = cursor and true or false
            end
            break
        end
    end
    return false
end)

log("armed -- walker=" .. tostring(walker_name) ..
    ", ExecuteWithDelay=" .. type(ExecuteWithDelay) ..
    ", LoopAsync=" .. type(LoopAsync) ..
    ", FindAllOf=" .. type(FindAllOf))
