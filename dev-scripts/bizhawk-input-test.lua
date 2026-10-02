-- Can a script move the player? Checkpoints to slot 3, holds RIGHT, reports the coordinate delta and restores the
-- slot. The coordinates are the witness: a call that raised no error proves only that the call happened.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local CHECKPOINT_SLOT = 3
local HOLD_FRAMES = 40

local function pos()
    local sb1 = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then return nil end
    return memory.read_s16_le(sb1 + 0x00), memory.read_s16_le(sb1 + 0x02)
end

local logfile = io.open("bizhawk-input-test.log", "w")
local function log(msg)
    console.log(msg)
    if logfile then logfile:write(msg, "\n") logfile:flush() end
end

local frames, phase = 0, "checkpoint"
local startX, startY

MESHGHOST_DEV_TICK = function()
    frames = frames + 1

    if phase == "checkpoint" then
        local ok = pcall(function() savestate.saveslot(CHECKPOINT_SLOT) end)
        startX, startY = pos()
        log(string.format("checkpoint to slot %d -> %s; player at (%s,%s)",
            CHECKPOINT_SLOT, tostring(ok), tostring(startX), tostring(startY)))
        if not startX then
            log("no save loaded; aborting")
            phase = "done"
            return
        end
        phase, frames = "hold", 0
        return
    end

    if phase == "hold" then
        -- Re-issued every frame: joypad.set affects only the frame about to run.
        pcall(function() joypad.set({ Right = true }, 1) end)
        if frames >= HOLD_FRAMES then
            local endX, endY = pos()
            log(string.format("held RIGHT for %d frames: (%d,%d) -> (%s,%s)  delta=(%s,%s)",
                HOLD_FRAMES, startX, startY, tostring(endX), tostring(endY),
                tostring((endX or startX) - startX), tostring((endY or startY) - startY)))
            if endX and endX ~= startX then
                log("RESULT: joypad.set DRIVES THE GAME -- the player moved.")
            else
                log("RESULT: no movement. Either input is not drivable this way, or the player")
                log("        was blocked; re-run somewhere with clear ground to the right.")
            end
            phase, frames = "restore", 0
        end
        return
    end

    if phase == "restore" and frames > 5 then
        local ok = pcall(function() savestate.loadslot(CHECKPOINT_SLOT) end)
        log(string.format("restored slot %d -> %s; session left as it started",
            CHECKPOINT_SLOT, tostring(ok)))
        phase = "done"
        if logfile then logfile:close() logfile = nil end
    end
end
