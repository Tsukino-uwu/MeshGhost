-- MeshGhost — BizHawk savestate helper (DEVELOPMENT TOOL, never shipped)
--
-- Saves or loads one savestate slot, once, then does nothing. Edit ACTION/SLOT and point
-- dev-scripts/bizhawk-dev-loader.target at this file; it fires on load and stops.
--
-- WHY THIS MATTERS FOR TESTING
-- Reaching a test state costs the user real playing time -- walking back to a route, re-catching
-- a Pokemon, replaying an intro. A checkpoint turns that into an instant restore, so a risky or
-- repeated test becomes cheap. The user gave standing permission to use these freely
-- (2026-08-18); BizHawk exposes savestate.save/load/saveslot/loadslot to Lua, all confirmed
-- callable the same day.
--
-- SLOT CONVENTION
--   1        the USER's own slot -- never write to it
--   2..10    agent checkpoints (BizHawk has ten)
-- Say which slot is being written or read, and what a load will discard, since loading throws
-- away everything since that point.
--
-- A savestate is NOT an in-game save. It captures RAM, so anything a test kit wrote (badges,
-- items, repel) is inside it -- but none of that reaches the .sav file until the game itself
-- saves. The two were confused once already, and an emulator relaunch lost the user's place.

local ACTION = "save" -- "save" or "load"
local SLOT = 2

local done = false
MESHGHOST_DEV_TICK = function()
    if done then return end
    done = true
    local ok, err = pcall(function()
        if ACTION == "save" then
            savestate.saveslot(SLOT)
        else
            savestate.loadslot(SLOT)
        end
    end)
    console.log(string.format("MeshGhost: savestate %s slot %d -> %s%s",
        ACTION, SLOT, tostring(ok), (not ok) and (" (" .. tostring(err) .. ")") or ""))
end
