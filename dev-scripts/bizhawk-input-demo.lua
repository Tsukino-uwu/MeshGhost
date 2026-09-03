-- MeshGhost — BizHawk input demo: can a script actually move the player?
--
-- joypad.set being "callable" is not the same as it working -- this build already has one API
-- whose doc string exists while the function is nil at runtime. So the test is behavioural:
-- read the player's coordinates, hold a direction, read them again, and report the DELTA.
-- Screenshots either side are for looking at, NOT for proof (see agent_docs/testing.md).
--
-- Checkpoints to slot 4 first and restores it at the end, so the session is left untouched.

-- Resolve this script's own directory instead of hardcoding one developer's
-- checkout. A tracked absolute path is unusable on anyone else's machine and is
-- the class of leak .githooks/pre-commit now refuses (pitfalls.md).
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
        -- Must be re-issued every frame: joypad.set applies only to the frame about to run.
        -- NO controller index. joypad.get() reports this core's buttons as bare names ("Right",
        -- not "P1 Right"), and passing a player number makes BizHawk look for the prefixed form,
        -- which does not exist here -- so the call succeeds and does nothing.
        pcall(function() joypad.set({ [DIR] = true }) end)
        if frames >= HOLD then
            local ex, ey = pos()
            pcall(function() client.screenshot(MESHGHOST_DIR .. "/shots/emerald/shot-after.png") end)
            log(string.format("held %s for %d frames: (%d,%d) -> (%s,%s), delta=(%s,%s)",
                DIR, HOLD, sx, sy, tostring(ex), tostring(ey),
                tostring((ex or sx) - sx), tostring((ey or sy) - sy)))
            -- Check BOTH axes. The first version tested x only and reported "no movement" for a
            -- run that had moved three tiles down -- the data was right and the verdict was wrong,
            -- which is the same shape as every "the log looked healthy" bug this project has hit.
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
