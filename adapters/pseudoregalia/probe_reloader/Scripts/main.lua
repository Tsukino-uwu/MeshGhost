-- MeshGhost probe reloader. Makes the Lua-probe loop fully automatic on Pseudoregalia: an
-- agent edits a probe, copies it into the install, then writes a line into this mod's trigger
-- file -- and the probe restarts inside the running game with no keystroke and no window focus.
--
-- Why not the Ctrl+R keybind (dev-scripts\pseudo-hotreload.ps1): UE4SS exposes hot reload only
-- as a keystroke at the game window, and Windows refuses the cross-process focus steal whenever
-- the user is typing somewhere else -- measured 2026-08-29, three sent reloads in a row landed
-- nowhere while the user was writing chat messages. RestartMod() (vendored RE-UE4SS docs,
-- lua-api/global-functions/modmanagement.md) restarts a named mod from Lua, so a resident
-- watcher plus a trigger file replaces the keystroke entirely.
--
-- Trigger file: reload_request.txt NEXT TO THIS SCRIPT's mod folder root, i.e.
--   ue4ss\Mods\MeshGhostProbeReloader\reload_request.txt
-- Format, one line:   <ModName> <any-nonce>
-- The nonce exists so writing the same mod name twice still triggers (content change is the
-- signal). Example:   MeshGhostNametagProbe 1756456789
--
-- This mod is deliberately dumb and edit-free: it never gets modified during an iteration, so
-- a syntax error in the probe being iterated cannot take the reload loop down with it. If the
-- probe's new code fails to load, fix the file and write the trigger again.
--
-- Dev-only tooling; never ships.

local TAG = "[MeshGhostProbeReloader]"

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    local path = src:match("^@(.*[/\\])")
    return path or "./"
end

-- Scripts/ -> the mod folder root.
local TRIGGER_PATH = scriptDir() .. "../reload_request.txt"

local lastSeen = nil

local function readTrigger()
    local f = io.open(TRIGGER_PATH, "r")
    if f == nil then return nil end
    local line = f:read("*l")
    f:close()
    return line
end

-- Prime with whatever is already there, so a stale file from a previous session does not fire
-- a restart the moment the game boots.
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
