-- MeshGhost world-fingerprint probe. 2026-08-31.
--
-- THE QUESTION, now that the trigger is proven: spawning a second player pawn into a world produced
-- by "reset to last save" kills the game, while the same spawn after a ZONE CHANGE is fine. Both
-- are freshly loaded worlds. So what is different about the one a reset makes?
--
-- Established first, so this probe is not chasing a guess (`../../UNVERIFIED.md`):
--   * the crash follows the SPAWN, not the reset -- holding the respawn 2s, 6s and 30s moved the
--     crash with it, and with the 30s hold the game ran quietly for fourteen seconds and died in
--     the same second the ghosts returned
--   * it is SpawnActor itself, not our setup -- a ghost spawned and left completely untouched
--     crashed identically
--
-- So this prints a FINGERPRINT of the world, every 2s and on change: the things most likely to
-- differ between a save-reset reload and a zone transition. Do a zone change, then a reset, and the
-- two fingerprints can be diffed line for line.
--
-- Property reads and cheap lookups only -- no UFunction calls into the Blueprint VM, which is where
-- the fault lives. It also stays quiet unless something changes, so it adds nothing while playing.

local POLL_MS = 2000
local last_print = nil

local function log(msg)
    print("[MeshGhostWorldFP] " .. msg .. "\n")
end

local function safe(fn, default)
    local ok, v = pcall(fn)
    if ok and v ~= nil then
        return v
    end
    return default
end

local function name_of(o)
    if not o then
        return "<nil>"
    end
    local ok, n = pcall(function() return o:GetFullName() end)
    if ok and n then
        return n
    end
    return "<unnamed>"
end

local function first_live(class_name)
    local all = FindAllOf(class_name)
    if not all then
        return nil
    end
    for _, o in ipairs(all) do
        if o:IsValid() and not name_of(o):find("Default__") then
            return o
        end
    end
    return nil
end

local function count_live(class_name)
    local all = FindAllOf(class_name)
    if not all then
        return 0
    end
    local n = 0
    for _, o in ipairs(all) do
        if o:IsValid() and not name_of(o):find("Default__") then
            n = n + 1
        end
    end
    return n
end

LoopAsync(POLL_MS, function()
    local pc = first_live("PlayerController")
    local ws = first_live("WorldSettings")
    local gm = first_live("GameModeBase") or first_live("AGameModeBase")
    local gs = first_live("GameStateBase")

    local pawn = pc and safe(function() return pc.Pawn end, nil) or nil
    local pauser = ws and safe(function() return ws.Pauser end, nil) or nil

    -- The fingerprint. Anything that could plausibly differ between a reset reload and a zone load,
    -- and nothing that needs a function call to obtain.
    local fp = table.concat({
        "world=" .. name_of(pc and safe(function() return pc:GetWorld() end, nil)),
        "pc=" .. (pc and "yes" or "NO"),
        "pawn=" .. (pawn and pawn:IsValid() and "yes" or "NO"),
        "pawnName=" .. (pawn and pawn:IsValid() and name_of(pawn):gsub(".*[%.:]", "") or "-"),
        "paused=" .. tostring(pauser ~= nil and pauser:IsValid()),
        "cursor=" .. tostring(safe(function() return pc and pc.bShowMouseCursor end, "?")),
        "gameMode=" .. (gm and name_of(gm):gsub(".*[%.:]", "") or "NO"),
        "gameState=" .. (gs and name_of(gs):gsub(".*[%.:]", "") or "NO"),
        "playerPawns=" .. count_live("BP_PlayerGoatMain_C"),
        "hpHitables=" .. count_live("BP_HpHitable_C"),
        "lightMgrs=" .. count_live("BP_LightManager_C"),
        "savePoints=" .. count_live("BP_SavePoint_C"),
    }, "  ")

    if fp ~= last_print then
        log(fp)
        last_print = fp
    end
    return false
end)

log("armed -- world fingerprint on change, every " .. POLL_MS .. "ms. Do a ZONE CHANGE, then a RESET, and diff.")
