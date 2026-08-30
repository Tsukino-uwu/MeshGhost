-- MeshGhost pause watch, third pass -- MINIMAL. 2026-08-31.
--
-- The two earlier passes were too heavy and it showed: three FindAllOf whole-object-space scans
-- every 200ms, fifteen scans a second. The crash under investigation is a RACE (it does not
-- reproduce while a heavy call trace slows the game down), and with those passes running the user
-- went from "crashes on a reset" to "crashes on the second pause-menu open, opened slowly". A probe
-- that changes how often the bug fires is not measuring the bug. CLAUDE.md says this in one line:
-- a diagnostic can break the thing it measures.
--
-- So this pass:
--   * finds each object ONCE and caches it, re-finding only if the handle goes invalid
--   * reads PROPERTIES only -- never calls a UFunction, because the fault is inside the Blueprint VM
--   * polls twice a second instead of five times
--   * watches exactly one question: WHAT FLIPS WHEN THE GAME PAUSES?
--
-- Why that question: pausing stops the game's actors ticking, while MeshGhost's own tick keeps
-- running and calling into those pawns. The mod already goes silent across a level teardown; pause
-- was never considered. `AWorldSettings.Pauser` is the engine's own pause flag (it holds the
-- PlayerState that paused the game, and is null otherwise) and reading it costs one property read.

local POLL_MS = 500

local cached_world_settings = nil
local cached_pc = nil
local last = {}

local function log(msg)
    print("[MeshGhostMenuWatch] " .. msg .. "\n")
end

local function on_change(key, value)
    local v = tostring(value)
    if last[key] ~= v then
        log(key .. " : " .. tostring(last[key]) .. " -> " .. v)
        last[key] = v
    end
end

local function safe(fn, default)
    local ok, v = pcall(fn)
    if ok then
        return v
    end
    return default
end

--- Finds an object once and keeps it. The scan only runs again if the handle dies.
local function cached(current, class_name)
    if current and current:IsValid() then
        return current
    end
    local found = FindAllOf(class_name)
    if not found then
        return nil
    end
    for _, o in ipairs(found) do
        if o:IsValid() and not o:GetFullName():find("Default__") then
            return o
        end
    end
    return nil
end

LoopAsync(POLL_MS, function()
    cached_world_settings = cached(cached_world_settings, "WorldSettings")
    if cached_world_settings then
        -- Pauser is set to the pausing PlayerState and cleared on resume: the engine's own answer
        -- to "is the game paused", with no function call and no scan.
        local pauser = safe(function() return cached_world_settings.Pauser end, nil)
        local paused = pauser ~= nil and pauser:IsValid()
        on_change("game.paused", paused)
    end

    cached_pc = cached(cached_pc, "PlayerController")
    if cached_pc then
        on_change("pc.bShowMouseCursor", safe(function() return cached_pc.bShowMouseCursor end, "?"))
    end

    return false
end)

log("armed (minimal pass) -- one property poll every " .. POLL_MS .. "ms, no scans, no calls")
