-- MeshGhost — Pokémon Crystal: the ghost's walk against the player's, frame by frame
--
-- READ-ONLY DIAGNOSTIC. Writes nothing, spawns nothing, changes nothing on screen.
--
-- WHY THIS EXISTS
-- The user, 2026-08-21: *"even just walking left/right feels a bit off with the ghost compared to
-- the player in crystal. not 1:1"*. "A bit off" has at least four distinct causes and they need
-- different fixes, so this measures which one it is instead of guessing:
--
--   * LAG -- the ghost starts each step N frames after the player and stays N frames behind. The
--     px error would then be roughly constant DURING a step and zero between steps.
--   * SPEED -- the two use different step vectors. The error would grow across a step and snap
--     back at the end. (StepVectors, engine/overworld/map_objects.asm: the low nibble of
--     OBJECT_WALKING picks slow/normal/fast, 1/2/4 px per frame. Both should be `normal`.)
--   * PHASE -- position matches but the stride does not, because OBJECT_STEP_FRAME is counting
--     from a different place. That looks wrong while measuring perfect.
--   * ACCUMULATION -- the error does not return to zero between steps, so it grows over a walk.
--     That is the ±2px first-step compensation (BANDAGES.md) being wrong by a frame.
--
-- THE MEASUREMENT
-- The loopback ghost is spawned a fixed number of tiles to the side, so at rest its sprite sits
-- exactly `MESHGHOST_LOOPBACK_OFFSET_X * 16` pixels from the player's. Everything here is
-- reported as the error AFTER subtracting that: 0 means the ghost is exactly where the player is,
-- allowing for the offset. The offset is not assumed -- it is MEASURED while both are standing
-- still, so this probe is correct whatever the offset is set to, and says what it measured.
--
-- HOW TO RUN
--   Load it beside the adapter (dev-scripts/bizhawk-dev-loader.lua takes several targets). Walk
--   left and right for a few seconds, then up and down. Log: posediff_<timestamp>.log beside this
--   file. It prints a per-step summary line and a table every 10 steps, so the answer is readable
--   without scrolling through per-frame rows.
--
--   No timing to hit, no window to catch. Just walk.

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- Vanilla V1.0, from our own hash-verified pokecrystal build's pokecrystal.sym. Vanilla only on
-- purpose: this is a question about a difference between two characters in one session, and a
-- patched build would add a second variable for no gain.
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
end

local raw_log = console.log
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
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

-- Sprite coordinates are a byte and wrap. A raw subtraction reports 254 where the answer is -2,
-- which would read as a catastrophic error instead of a two-pixel one.
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

-- Which of the other 12 structs is the ghost?
--
-- Deliberately NOT asked of the adapter: a probe that reads the thing being measured out of the
-- code being measured cannot catch that code pointing at the wrong slot.
--
-- Proximity alone is not enough and the first version proved it -- it locked onto an NPC standing
-- in the same room. So the ghost is identified by BEHAVIOUR instead, which is the one thing no NPC
-- does: **its tile offset from the player stays constant while the player walks.** A wandering
-- NPC's offset changes; a stationary NPC's offset changes as the player moves; only something
-- following the player keeps the same delta across many tiles.
--
-- LOCK-ON: watch every candidate over a window of player movement, and pick the one whose delta
-- never changed while the player covered at least a few tiles. Until that happens the probe says
-- it is still looking rather than measuring the wrong character.
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
		if o.sprite and o.sprite ~= 0 and o.mx and o.my then
			local dx, dy = o.mx - player.mx, o.my - player.my
			local w = watching[i]
			if not w then
				watching[i] = { dx = dx, dy = dy, stable = 0, base = base }
			elseif playerMoved then
				-- Only judged at the moment the PLAYER changes tile: mid-step the ghost is
				-- legitimately a tile behind for a few frames, and judging then would rule out
				-- the very thing being looked for.
				if w.dx == dx and w.dy == dy then
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
		-- It went away (map change, despawn). Start the lock-on over rather than assuming the
		-- slot will come back holding the same character.
		ghost, watching, lockTiles, lastPlayerTile = nil, {}, 0, nil
		return
	end

	local pStanding = (player.walking or STANDING) == STANDING
	local gStanding = (g.walking or STANDING) == STANDING

	-- The resting offset, measured rather than assumed. Re-measured whenever both are standing,
	-- so a teleport or a re-spawn cannot leave a stale baseline behind.
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
		-- The step VECTOR each of them chose, printed once per step. If these ever differ the
		-- answer is "speed" and nothing else in this log matters.
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
		-- Per-frame detail, but only while something is actually moving, and only when the error
		-- or the stride phase changes -- a row per frame of a quiet walk is unreadable.
		if err ~= (prevP.err or 0) or g.stepframe ~= prevG.stepframe then
			log(string.format("  f=%-7d err %+4dpx  |  player dur=%s frame=%s facing=%s"
				.. "  |  ghost dur=%s frame=%s facing=%s",
				frames, err, tostring(player.stepdur), tostring(player.stepframe),
				tostring(player.facing), tostring(g.stepdur), tostring(g.stepframe),
				tostring(g.facing)))
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
		logfile:close()
		logfile = nil
	end
end

-- A registered callback outlives its script under BizHawk, which is why this is a loop and not
-- event.onframeend (pitfalls.md).
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
