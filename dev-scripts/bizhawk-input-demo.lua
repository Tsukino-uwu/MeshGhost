-- Can a script move the player? Checkpoints to slot 4, holds Down, reports the coordinate delta and restores the
-- slot; the screenshots either side are for looking at, not proof.

local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local SLOT = 4
local HOLD = 48 -- 3 tiles at 16 frames per walked tile
local DIR = "Down"

local function pos()
    local sb1 = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then return nil end
    return memory.read_s16_le(sb1 + 0x00), memory.read_s16_le(sb1 + 0x02)
end

local logfile = io.open(MESHGHOST_DIR .. "/../dev-logs/input-demo.log", "w")
local function log(m)
    console.log(m)
    if logfile then logfile:write(m, "\n") logfile:flush() end
end

local phase, frames, sx, sy = "start", 0, nil, nil

MESHGHOST_DEV_TICK = function()
    frames = frames + 1

    if phase == "start" then
        sx, sy = pos()
        if not sx then return end -- wait for a save to be loaded
        pcall(function() savestate.saveslot(SLOT) end)
        pcall(function() client.screenshot(MESHGHOST_DIR .. "/shots/emerald/shot-before.png") end)
        log(string.format("start: player at (%d,%d); checkpointed to slot %d", sx, sy, SLOT))
        phase, frames = "hold", 0
        return
    end

    if phase == "hold" then
        -- Every frame (joypad.set covers the next frame only), with no controller index: this core's buttons are
        -- bare names ("Down", not "P1 Down"), and an index makes the call succeed and do nothing.
        pcall(function() joypad.set({ [DIR] = true }) end)
        if frames >= HOLD then
            local ex, ey = pos()
            pcall(function() client.screenshot(MESHGHOST_DIR .. "/shots/emerald/shot-after.png") end)
            log(string.format("held %s for %d frames: (%d,%d) -> (%s,%s), delta=(%s,%s)",
                DIR, HOLD, sx, sy, tostring(ex), tostring(ey),
                tostring((ex or sx) - sx), tostring((ey or sy) - sy)))
            -- Both axes: a run that moved only down still moved.
            local moved = ex and ey and (ex ~= sx or ey ~= sy)
            log(moved and "RESULT: input works -- the script moved the player."
                or "RESULT: no movement (blocked, or input is not drivable this way).")
            phase, frames = "restore", 0
        end
        return
    end

    if phase == "restore" and frames > 5 then
        pcall(function() savestate.loadslot(SLOT) end)
        log("restored slot " .. SLOT .. "; session left as it was")
        phase = "done"
        if logfile then logfile:close() logfile = nil end
    end
end
