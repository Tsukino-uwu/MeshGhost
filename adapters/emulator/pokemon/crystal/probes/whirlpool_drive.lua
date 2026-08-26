-- WHAT THE PLAYER'S OBJECT DOES WHEN A WHIRLPOOL SPINS IT -- driven from a prepared savestate, so
-- the spin can be produced on demand instead of waited for.
--
-- WHY THIS EXISTS. `action_probe.lua` drives a turn and a bump itself and then opens a free phase
-- asking a human to find a spin tile, use Dig, use Teleport. That is the one class this adapter
-- has never seen: SPIN (OBJECT_ACTION_SPIN, 4) and its flicker partner (5). The user prepared
-- savestate 10 sitting one tile below a whirlpool, where HOLDING UP re-enters it over and over --
-- *"when surfing into the whirlpool, the player spins around"* -- which turns "wait for a spin"
-- into a driveable, repeatable phase. Slot 10 is the whole reason this is a separate probe.
--
-- WHAT IT ANSWERS
--   * which action byte a whirlpool spin actually is -- SPIN, SPIN_FLICKER, BUMP, or something
--     this adapter has no branch for at all. NOT ASSUMED: the decomp's whirlpool path
--     (`TryWhirlpoolOW`, `engine/events/overworld.asm`) is a text box and a block swap with no
--     character animation in it, so whatever spins the player is somewhere else and the byte is
--     the thing that names it;
--   * how long each facing holds, in video frames, and how many engine ticks that is -- the
--     cadence a 1:1 ghost has to match, which no still frame can show;
--   * whether any frame draws nothing (SPIN_FLICKER sets OBJECT_FACING to STANDING = 0xFF and the
--     engine skips the object), which is what the Dig/Teleport flicker is made of;
--   * whether the spin is on the character at all, or is a separate object the way the "!" emote
--     and the Fly cutscene both turned out to be -- so EVERY occupied object slot is logged, not
--     just the player's.
--
-- READ-ONLY except for the savestate load and the controller. It writes no game memory.
--
-- ENDURANCE, NOT TIMING. Fixed phases with a spoken countdown; there is no moment to hit and
-- nothing is asked of whoever is watching.
--
-- UNLOAD IT BEFORE JUDGING ANYTHING ON SCREEN. It holds the d-pad, and in a loopback session the
-- ghost IS the local player echoed, so a probe steering the player steers the ghost too -- which
-- has already cost this adapter a round of diagnosis once (`probes/README.md`).
--
-- Addresses are vanilla V1.0, from meshghost_crystal.lua's own table (itself from a hash-verified
-- local `pokecrystal` build): OBJECT_STRUCTS 0xD4D6, stride 0x28. Field offsets from the decomp's
-- struct listing (constants/map_object_constants.asm).
--
-- Switches (Lua globals, so they can be set into an already-running emulator):
--   MESHGHOST_WHIRL_SLOT   savestate slot to load (default 10)
--   MESHGHOST_WHIRL_NOLOAD set to skip the savestate load entirely and probe where you are

local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	f = io.open(dir .. "/whirlpool.log", "w")
	-- Buffered, flushed on a timer rather than per line: one console.log plus one flush was
	-- measured at 63-83ms on this host (`adapters/emulator/CLAUDE.md`).
	if f then f:setvbuf("full", 1 << 16) end
end

local function u8(a) return memory.read_u8(a, "System Bus") or 0 end

local OBJ, STRIDE, NSTRUCTS = 0xD4D6, 0x28, 13
local F = { tile = 0x02, flags1 = 0x04, flags2 = 0x05, pal = 0x06, walking = 0x07, dir = 0x08,
	steptype = 0x09, act = 0x0B, stepframe = 0x0C, face = 0x0D, mx = 0x10, my = 0x11,
	sx = 0x17, sy = 0x18, yoff = 0x1A }
local W_MAPGROUP, W_MAPNUM, W_YCOORD, W_XCOORD = 0xDCB5, 0xDCB6, 0xDCB7, 0xDCB8

-- Names for the log only. Values from constants/map_object_constants.asm; anything not listed
-- prints as a number rather than being guessed at -- an unknown action is a RESULT here, since
-- the whole question is which one this is.
local ACT_NAMES = { [0] = "00", [1] = "STAND", [2] = "STEP", [3] = "BUMP", [4] = "SPIN",
	[5] = "SPIN_FLICKER", [6] = "FISHING", [7] = "SHADOW", [8] = "EMOTE", [9] = "BIG_DOLL_SYM",
	[10] = "BOUNCE", [11] = "WEIRD_TREE", [12] = "BIG_DOLL_ASYM", [13] = "BIG_DOLL",
	[14] = "BOULDER_DUST", [15] = "GRASS_SHAKE", [16] = "SKYFALL" }

local function faceName(v)
	if v == 0xFF then return "STANDING(not drawn)" end
	if v < 0x10 then
		return string.format("STEP_%s_%d", ({ [0] = "DOWN", "UP", "LEFT", "RIGHT" })[v // 4], v & 3)
	end
	if v <= 0x13 then
		return "FISH_" .. ({ [0] = "DOWN", "UP", "LEFT", "RIGHT" })[v - 0x10]
	end
	if v == 0x14 then return "EMOTE" end
	if v == 0x15 then return "SHADOW" end
	return string.format("0x%02X(scenery)", v)
end

-- The player's own art offset, and how many of the 40 hardware entries are live. The offset is
-- `(tile - base) & 0xFF`, the same arithmetic the adapter's frame learner uses: 0x00-0x0B is a
-- standing view, 0x80-0x8B a stepping one, anything else is not this character's art.
-- Deliberately NOT read from OAM entries 0-3 as "the player" -- InitSprites emits by PRIORITY,
-- so those belong to the highest-priority object with a sprite, which cost this adapter a
-- whole-tile error once (`pitfalls/by-lesson.md`, 2026-08-26).
local function oamLive()
	local live = 0
	for e = 0, 39 do
		local ey = memory.read_u8(e * 4, "OAM") or 0
		if ey ~= 0 and ey < 160 then live = live + 1 end
	end
	return live
end

-- RUN-LENGTH, never one line per frame. The question is the CADENCE, and a hundred identical
-- lines hide it while a run length states it. It is also how the tick rate gets measured: a run
-- counts video frames, and OBJECT_STEP_FRAME's own increments inside it are engine ticks.
local run = { key = nil, n = 0, sfFirst = nil, sfLast = nil, sfSteps = 0, at = 0 }
local totals, faceTotals = {}, {}

local function flush()
	if not run.key or not f then return end
	f:write(string.format("  f%-7d %s   x%d frames (step_frame %d..%d = %d ticks)\n",
		run.at, run.key, run.n, run.sfFirst or -1, run.sfLast or -1, run.sfSteps))
	run.key = nil
end

local function record(key, sf, frame)
	if key ~= run.key then
		flush()
		run.key, run.n, run.sfFirst, run.sfLast, run.sfSteps, run.at = key, 0, sf, sf, 0, frame
	end
	run.n = run.n + 1
	if sf ~= run.sfLast then
		run.sfSteps = run.sfSteps + 1
		run.sfLast = sf
	end
end

-- EVERY OCCUPIED SLOT, not just the player's. The "!" emote and the Fly landing both turned out
-- to live on something other than the character, so "the player's object shows nothing" is only
-- half an answer -- the other half is whether anything ELSE appeared at the same moment. Logged
-- as a change-only census so a static cast reports itself once and then stays quiet.
local lastCensus = nil
local function census(frame)
	local parts = {}
	for i = 1, NSTRUCTS - 1 do
		local b = OBJ + i * STRIDE
		local spr = u8(b + F.tile)
		local act, face = u8(b + F.act), u8(b + F.face)
		if not (spr == 0 and act == 0 and face == 0) then
			-- WALKING / STEP TYPE / DURATION as well as the pose. Added 2026-08-26 after the
			-- open-water CONTROL run showed `apply spread 0 wide, 0 frames blocked` against the
			-- whirlpool's `8 wide, 37-133 blocked`: the ghost is stuck mid-step (walking is not
			-- STANDING) far longer than one 16-frame step, and the first census could not say
			-- which of the three fields was holding it there. A pose alone cannot answer a
			-- question about movement.
			parts[#parts + 1] = string.format("[%d spr=%02X act=%s face=%02X %d,%d walk=%d stype=%d dur=%d]",
				i, spr, ACT_NAMES[act] or tostring(act), face, u8(b + F.mx), u8(b + F.my),
				u8(b + 0x07), u8(b + 0x09), u8(b + 0x0A))
		end
	end
	local line = #parts > 0 and table.concat(parts, " ") or "(no other objects)"
	if line ~= lastCensus then
		lastCensus = line
		if f then f:write(string.format("  f%-7d OTHERS %s\n", frame, line)) end
	end
end

local FPS = 60
local SLOT = tonumber(MESHGHOST_WHIRL_SLOT) or 10
local PHASES = {
	{ name = "asloaded", secs = 3,
		say = "savestate " .. SLOT .. " loaded -- recording the state as it arrives, no input" },
	{ name = "intowhirl", secs = 40,
		say = "DRIVEN: holding UP into the whirlpool, tapping B to clear any text box" },
	{ name = "after", secs = 5, say = "released -- recording what it settles back to" },
}

local phase, phaseLeft, done, n, frame = 0, 0, false, 0, 0
local loaded = false
local sawAct = {}

MESHGHOST_DEV_TICK = function()
	n = n + 1
	if n < 30 then return end

	-- The savestate load happens ONCE, after the loader has settled, and is announced. Slot 1 is
	-- the user's on every instance and is never touched (`playing.md`).
	if not loaded then
		loaded = true
		if not MESHGHOST_WHIRL_NOLOAD then
			savestate.loadslot(SLOT)
			console.log("whirlpool_drive: loaded savestate slot " .. SLOT)
		end
		if f then
			f:write(string.format("=== whirlpool_drive, slot %s ===\n",
				MESHGHOST_WHIRL_NOLOAD and "(not loaded)" or tostring(SLOT)))
		end
		return
	end

	frame = frame + 1

	if phaseLeft <= 0 then
		flush()
		phase = phase + 1
		if phase > #PHASES then
			if not done then
				done = true
				flush()
				if f then
					f:write("\n=== done ===\n")
					-- WHAT IT SAW, and equally what it did NOT: an instrument reports its own
					-- coverage, not only its findings. A class absent from this list was never
					-- produced, which is a different statement from "it does not happen".
					local keys = {}
					for k in pairs(totals) do keys[#keys + 1] = k end
					table.sort(keys)
					for _, k in ipairs(keys) do
						f:write(string.format("  action %-14s on %d frames\n", k, totals[k]))
					end
					f:write("\n  facings seen:\n")
					local fk = {}
					for k in pairs(faceTotals) do fk[#fk + 1] = k end
					table.sort(fk)
					for _, k in ipairs(fk) do
						f:write(string.format("    0x%02X %-20s on %d frames\n",
							k, faceName(k), faceTotals[k]))
					end
					for _, a in ipairs({ 4, 5 }) do
						if not sawAct[a] then
							f:write(string.format(
								"\n  NOT SEEN: action %d (%s) never appeared on the player.\n",
								a, ACT_NAMES[a]))
						end
					end
					f:flush()
				end
				console.log("whirlpool_drive: done -- see whirlpool.log beside the script.")
			end
			return
		end
		local p = PHASES[phase]
		phaseLeft = p.secs * FPS
		console.log(string.format("whirlpool_drive [%d/%d] %s (%ds): %s",
			phase, #PHASES, p.name, p.secs, p.say))
		if f then
			f:write(string.format("\n=== phase %s, %ds ===  map %d:%d  window %d,%d\n",
				p.name, p.secs, u8(W_MAPGROUP), u8(W_MAPNUM), u8(W_XCOORD), u8(W_YCOORD)))
		end
	end
	phaseLeft = phaseLeft - 1
	local p = PHASES[phase]

	if phaseLeft % (10 * FPS) == 0 and phaseLeft > 0 then
		console.log(string.format("whirlpool_drive: %s -- %ds left", p.name, phaseLeft // FPS))
	end

	if p.name == "intowhirl" then
		-- UP, THEN PAUSE, THEN UP AGAIN -- the FAILING repro, not the passing one.
		--
		-- This held Up continuously until 2026-08-26, which is the user's *"twice in a row"* case
		-- and the one that WORKS: *"the spawned ghost follows properly and spins the 2nd time"*.
		-- A whole session was spent measuring the passing configuration and calling the result a
		-- fault. The case that actually fails is *"go up into the whirlpool/spin, get pushed down,
		-- WAIT A BIT, and then go up again"* -- where the ghost, a move behind, spends the pause
		-- walking DOWN to the tile the player is on and is therefore in the wrong place when the
		-- player sets off again: *"it never reaches the whirlpool to begin with"*.
		--
		-- So the drive is a cycle: hold Up long enough for one approach and push-back, then release
		-- for a pause long enough that the ghost demonstrably closes the gap. `probes.md`'s rule --
		-- a probe must reproduce the reported case, and an idle phase is part of the case, not dead
		-- air between measurements.
		local cyc = frame % 300
		local input = {}
		if cyc < 120 then input.Up = true end -- approach + spin + push-back
		if (cyc % 47) < 2 then input.B = true end -- clear any text box; B never confirms
		joypad.set(input)
	end

	local act = u8(OBJ + F.act)
	local face = u8(OBJ + F.face)
	local sf = u8(OBJ + F.stepframe)
	local name = ACT_NAMES[act] or tostring(act)
	totals[name] = (totals[name] or 0) + 1
	faceTotals[face] = (faceTotals[face] or 0) + 1
	sawAct[act] = true

	-- Everything, every run -- no filtering by "interesting", because a filter chosen before
	-- looking is a guess about the answer. Ordinary standing/stepping still collapses into its
	-- own runs, so the gaps between spins stay visible without drowning them.
	record(string.format(
		"act=%-12s face=%02X %-20s tile=%02X dir=%d walk=%3d stype=%2d yoff=%4d map=%d,%d spr=%d,%d oam=%d",
		name, face, faceName(face), u8(OBJ + F.tile), u8(OBJ + F.dir), u8(OBJ + F.walking),
		u8(OBJ + F.steptype), ((u8(OBJ + F.yoff) + 128) % 256) - 128,
		u8(OBJ + F.mx), u8(OBJ + F.my), u8(OBJ + F.sx), u8(OBJ + F.sy), oamLive()), sf, frame)

	census(frame)
	if frame % 120 == 0 and f then f:flush() end
end
