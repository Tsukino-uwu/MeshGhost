-- Saves or loads one savestate slot once, then stops: edit ACTION and SLOT and point the dev loader at it. Slot 1
-- belongs to whoever plays and is never written; 2..10 are agent checkpoints. Say which slot, and what a load
-- discards. A savestate is not an in-game save: it holds RAM, and nothing in it reaches the .sav until the game saves.

local ACTION = "load" -- "save" or "load"
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
