-- Read-only: the loopback ghost's walk against the player's, frame by frame, to tell which of four causes makes it
-- look off: lag (a constant error during a step, zero between), speed (an error that grows across a step), phase
-- (position right, stride wrong) or accumulation (an error that never returns to zero). Errors are pixels after
-- subtracting the resting offset, measured while both stand. Walk left and right, then up and down.

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- Vanilla V1.0, from our hash-verified build's .sym: a patched build would add a variable for no gain.
local OBJECT_STRUCTS = flat(0xD4D6) -- wObjectStructs
local OBJECT_LENGTH = 0x28
local NUM_OBJECT_STRUCTS = 13

local F_SPRITE, F_WALKING, F_DIRECTION = 0x00, 0x07, 0x08
local F_STEP_TYPE, F_STEP_DURATION = 0x09, 0x0A
local F_ACTION, F_STEP_FRAME, F_FACING = 0x0B, 0x0C, 0x0D
local F_MAP_X, F_MAP_Y, F_SPRITE_X, F_SPRITE_Y = 0x10, 0x11, 0x17, 0x18

local STANDING = 255

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/posediff_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, never flushed per line: a flush is a synchronous disk write on the emulator's own thread.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- The console is a GUI append on the emulator's thread, so it gets the first lines and one in twenty; the file all.
local rawConsole, consoleLines = console.log, 0
local function raw_log(msg)
	consoleLines = consoleLines + 1
	if consoleLines <= 4 or consoleLines % 20 == 0 then
		rawConsole(msg)
	end
end
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		-- Flush every 20 lines: a bounded cost, and a log that is never empty for a whole run.
		flushEvery = (flushEvery or 0) + 1
		if flushEvery >= 20 then
			flushEvery = 0
			pcall(function() logfile:flush() end)
		end
	end
end

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

local function readObj(base)
	return {
		sprite = u8(base + F_SPRITE),
		walking = u8(base + F_WALKING),
		direction = u8(base + F_DIRECTION),
		steptype = u8(base + F_STEP_TYPE),
		stepdur = u8(base + F_STEP_DURATION),
		action = u8(base + F_ACTION),
		stepframe = u8(base + F_STEP_FRAME),
		facing = u8(base + F_FACING),
		mx = u8(base + F_MAP_X),
		my = u8(base + F_MAP_Y),
		sx = u8(base + F_SPRITE_X),
		sy = u8(base + F_SPRITE_Y),
	}
end

-- Sprite coordinates are a byte and wrap: 254 is -2.
local function signedDelta(a, b)
	if a == nil or b == nil then
		return nil
	end
	local d = (a - b) & 0xFF
	if d > 127 then
		d = d - 256
	end
	return d
end

-- Which struct is the ghost, found here rather than asked of the adapter under test: the adapter's marker, and a
-- tile offset from the player that holds while the player walks. Until then the probe says it is still looking.
local LOCK_TILES = 3 -- player tile-changes required before a lock is trusted

local watching = {} -- slot -> { dx, dy, stable, base }
local lockTiles = 0
local lastPlayerTile = nil

local function observeCandidates(player)
	local playerMoved = false
	local tile = string.format("%d,%d", player.mx, player.my)
	if lastPlayerTile ~= nil and tile ~= lastPlayerTile then
		playerMoved = true
		lockTiles = lockTiles + 1
	end
	lastPlayerTile = tile

	for i = 1, NUM_OBJECT_STRUCTS - 1 do
		local base = OBJECT_STRUCTS + i * OBJECT_LENGTH
		local o = readObj(base)
		-- Identity first: the adapter's ghosts carry WONT_DELETE and the local player's sprite.
		local flags1 = u8(base + 0x04) or 0
		local isOurs = (flags1 & 0x02) ~= 0 and o.sprite == player.sprite
		if isOurs and o.sprite and o.sprite ~= 0 and o.mx and o.my then
			local dx, dy = o.mx - player.mx, o.my - player.my
			local w = watching[i]
			if not w then
				watching[i] = { dx = dx, dy = dy, stable = 0, base = base }
			elseif playerMoved then
				-- Judged only as the player changes tile, within a tile of the baseline: a following ghost is
				-- legitimately a tile behind then, a wandering NPC drifts further in a few steps.
				if math.abs(dx - w.dx) <= 1 and math.abs(dy - w.dy) <= 1 then
					w.stable = w.stable + 1
				else
					w.dx, w.dy, w.stable = dx, dy, 0
				end
			end
		else
			watching[i] = nil -- the slot emptied; whatever it was, it is not there now
		end
	end

	if lockTiles < LOCK_TILES then
		return nil
	end
	local best = nil
	for slot, w in pairs(watching) do
		if w.stable >= LOCK_TILES and (not best or w.stable > best.w.stable) then
			best = { slot = slot, w = w }
		end
	end
	if not best then
		return nil
	end
	return { slot = best.slot, base = best.w.base, dx = best.w.dx, dy = best.w.dy }
end

open_log()
log("=== MeshGhost Crystal pose diff (READ-ONLY) ===")
log("Walk left and right for a few seconds, then up and down. No timing to hit.")
log("Every number below is the GHOST minus the PLAYER, with the standing offset subtracted:")
log("  0 = the ghost is exactly where the player is. Positive = ahead. Negative = behind.")

local frames = 0
local ghost = nil -- { slot, base }
local ambiguousSaid = false
local restOffsetX, restOffsetY = nil, nil

-- Per-step bookkeeping.
local playerStepStart, ghostStepStart = nil, nil
local stepPeakErr, stepErrAtEnd = 0, 0
local steps = 0
local lags = {}
local peaks = {}
local residuals = {}
local prevP, prevG = {}, {}

local function summarise()
	local function stats(t)
		if #t == 0 then
			return "n/a"
		end
		local lo, hi, sum = t[1], t[1], 0
		for _, v in ipairs(t) do
			lo = math.min(lo, v)
			hi = math.max(hi, v)
			sum = sum + v
		end
		return string.format("min %d, max %d, mean %.1f", lo, hi, sum / #t)
	end
	log("")
	log(string.format("  ---- after %d steps ----", steps))
	log(string.format("  START LAG (frames the ghost begins its step late): %s", stats(lags)))
	log(string.format("  PEAK ERROR during a step (px):                    %s", stats(peaks)))
	log(string.format("  RESIDUAL ERROR once both are standing (px):       %s", stats(residuals)))
	log("  Reading it: lag>0 with residual 0 is LATENCY. Residual growing is ACCUMULATION.")
	log("  Peak much larger than lag*2 is a SPEED mismatch (2px per frame at normal speed).")
	log("")
end

local function tick()
	frames = frames + 1

	-- Also flushed on time: this log can stay under 20 lines for a whole run.
	if logfile and frames % 300 == 0 then
		pcall(function() logfile:flush() end)
	end

	local player = readObj(OBJECT_STRUCTS)
	if not player.mx or not player.sprite or player.sprite == 0 then
		return -- not in the overworld
	end

	if not ghost then
		ghost = observeCandidates(player)
		if not ghost then
			if frames % 300 == 0 and not ambiguousSaid then
				log(string.format("  f=%-7d still looking: walk a few tiles so the character that "
					.. "FOLLOWS you can be told from the ones that do not.", frames))
			end
			return
		end
		log(string.format("  f=%-7d locked on: struct %d, holding a constant offset of %+d,%+d "
			.. "tiles across %d of the player's tile changes. That is the ghost.",
			frames, ghost.slot, ghost.dx, ghost.dy, LOCK_TILES))
		ambiguousSaid = true
	end

	local g = readObj(ghost.base)
	if not g.mx or g.sprite == 0 then
		-- Gone (a map change, a despawn): start the lock-on over rather than trust the slot.
		ghost, watching, lockTiles, lastPlayerTile = nil, {}, 0, nil
		return
	end

	local pStanding = (player.walking or STANDING) == STANDING
	local gStanding = (g.walking or STANDING) == STANDING

	-- Re-measured whenever both stand, so a teleport or a respawn cannot leave a stale baseline.
	if pStanding and gStanding then
		restOffsetX = signedDelta(g.sx, player.sx)
		restOffsetY = signedDelta(g.sy, player.sy)
	end

	local errX = signedDelta(g.sx, player.sx)
	local errY = signedDelta(g.sy, player.sy)
	if errX and restOffsetX then errX = errX - restOffsetX end
	if errY and restOffsetY then errY = errY - restOffsetY end
	local err = ((errX or 0) ~= 0) and errX or (errY or 0)

	-- Step boundaries.
	local pStarted = (prevP.walking ~= nil) and (prevP.walking == STANDING) and not pStanding
	local gStarted = (prevG.walking ~= nil) and (prevG.walking == STANDING) and not gStanding

	if pStarted then
		playerStepStart, ghostStepStart = frames, nil
		stepPeakErr = 0
		-- The step vector each chose; if these ever differ, the answer is speed.
		log(string.format("  f=%-7d step %d starts: player WALKING=%s (speed nibble %d)",
			frames, steps + 1, tostring(player.walking), (player.walking or 0) & 0x0F))
	end
	if gStarted and playerStepStart then
		ghostStepStart = frames
		local lag = frames - playerStepStart
		lags[#lags + 1] = lag
		log(string.format("  f=%-7d          ghost WALKING=%s (speed nibble %d) -- %d frame%s late",
			frames, tostring(g.walking), (g.walking or 0) & 0x0F, lag, (lag == 1) and "" or "s"))
	end

	if not pStanding or not gStanding then
		if math.abs(err) > math.abs(stepPeakErr) then
			stepPeakErr = err
		end
		-- Per-frame rows only while something moves and the error or the stride phase changes.
		if err ~= (prevP.err or 0) or g.stepframe ~= prevG.stepframe then
			-- Action and flags1 beside the symptom: the decompilation's two causes of a step frame stuck at 0 are a
			-- non-step action and SLIDING (flags1 bit 3).
			log(string.format("  f=%-7d err %+4dpx  |  P dur=%s frame=%s facing=%s act=%s"
				.. "  |  G dur=%s frame=%s facing=%s act=%s st=%s flags1=%s walk=%s",
				frames, err, tostring(player.stepdur), tostring(player.stepframe),
				tostring(player.facing), tostring(player.action),
				tostring(g.stepdur), tostring(g.stepframe), tostring(g.facing),
				tostring(g.action), tostring(g.steptype), tostring(u8(ghost.base + 0x04)),
				tostring(g.walking)))
		end
	end

	-- Both standing again: the step is over, so bank what it cost.
	if pStanding and gStanding and playerStepStart then
		steps = steps + 1
		peaks[#peaks + 1] = stepPeakErr
		residuals[#residuals + 1] = err
		log(string.format("  f=%-7d step %d done: peak %+dpx, residual %+dpx", frames, steps,
			stepPeakErr, err))
		playerStepStart, ghostStepStart = nil, nil
		if steps % 10 == 0 then
			summarise()
		end
	end

	prevP = player
	prevP.err = err
	prevG = g
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
	if steps > 0 then
		summarise()
	end
	if logfile then
		pcall(function() logfile:flush() end)
		logfile:close()
		logfile = nil
	end
end

-- Standalone, its own loop: a registered callback outlives its script under BizHawk.
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
