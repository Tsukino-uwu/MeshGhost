-- Probe reloader: restarts a named mod inside the running game when its trigger file changes, with no
-- keystroke and no window focus (the Ctrl+R keybind misses whenever the game window lacks focus).
-- Trigger: ue4ss\Mods\MeshGhostProbeReloader\reload_request.txt, one line "<ModName> <nonce>"; the nonce
-- makes a repeat of the same name a content change.
-- Never edited during an iteration, so a syntax error in the probe cannot take the reload loop down.

local TAG = "[MeshGhostProbeReloader]"

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    local path = src:match("^@(.*[/\\])")
    return path or "./"
end

local TRIGGER_PATH = scriptDir() .. "../reload_request.txt"

local lastSeen = nil

local function readTrigger()
    local f = io.open(TRIGGER_PATH, "r")
    if f == nil then return nil end
    local line = f:read("*l")
    f:close()
    if line == nil then return nil end
    -- PowerShell 5.1's Set-Content -Encoding utf8 writes a BOM, which %S+ would capture into the mod name.
    line = line:gsub("^\239\187\191", "")
    return line
end

-- Primed so a trigger left from a previous session does not fire a restart at boot.
lastSeen = readTrigger()

LoopAsync(1000, function()
    local ok, err = pcall(function()
        local line = readTrigger()
        if line == nil or line == lastSeen then return end
        lastSeen = line
        local modName = line:match("^(%S+)")
        if modName == nil or modName == "" then return end
        print(string.format("%s trigger changed -> restarting mod '%s'.\n", TAG, modName))
        RestartMod(modName)
    end)
    if not ok then
        print(string.format("%s watcher error: %s\n", TAG, tostring(err)))
    end
    return false -- keep looping for the life of the session
end)

print(string.format("%s watching %s (write '<ModName> <nonce>' to restart a mod).\n", TAG, TRIGGER_PATH))
