-- WHAT THE PLAYER'S OBJECT DOES WHILE IT IS NOT WALKING -- every animation class, in the game's
-- own terms, and the frames actually drawn for each.
--
-- The generalisation of `bump_probe.lua`. That one answered ONE class (walking into a wall) and
-- the answer -- the facing byte alternates and the drawn tile follows it -- turned out to be the
-- shape of all of them: OBJECT_FACING is the engine's index into `Facings`, so the facing byte
-- IS the pose. This probe records that byte, the action byte that produced it, the step frame the
-- engine is counting with, and the tile it actually drew, for every non-walking action the player
-- enters. Then it says what the CADENCE was, which is the part a still frame cannot show.
--
-- WHAT IT ANSWERS
--   * how long each facing holds, in video frames, per action -- the number a 1:1 ghost must match;
--   * how fast the engine's own object clock runs (does the action handler tick every video frame,
--     or every other one?), read off OBJECT_STEP_FRAME's increments rather than assumed;
--   * whether a class draws anything at all on some frames (the Dig/Teleport flicker sets
--     OBJECT_FACING to STANDING = 0xFF, and the engine then skips the object entirely);
--   * how many OAM entries the player occupies -- four normally, FIVE while fishing, because the
--     rod is a fifth sprite.
--
-- ENDURANCE, NOT TIMING. Two driven phases the probe plays itself, then a long free phase with a
-- spoken countdown where anything you manage to do is recorded and anything you do not costs
-- nothing. There is no moment to hit.
--
-- Constants from meshghost_crystal.lua: OBJECT_STRUCTS 0xD4D6 (vanilla V1.0), F_SPRITE_TILE 0x02,
-- F_WALKING 0x07, F_DIRECTION 0x08, F_STEP_TYPE 0x09, F_ACTION 0x0B, F_FACING 0x0D, F_MAP_X 0x10,
-- F_MAP_Y 0x11. OBJECT_STEP_FRAME 0x0C and OBJECT_SPRITE_Y_OFFSET 0x1A are from the decomp's own
-- struct listing (constants/map_object_constants.asm) and are not otherwise used by the adapter.
--
-- Log beside this script, resolved from the script's own path -- never an absolute one, which is
-- a personal path in a public repo.
local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	f = io.open(dir .. "/action.log", "w")
end

local function u8(a) return memory.read_u8(a, "System Bus") or 0 end
local OBJ = 0xD4D6
local F = { tile = 0x02, walking = 0x07, dir = 0x08, steptype = 0x09, act = 0x0B,
	stepframe = 0x0C, face = 0x0D, mx = 0x10, my = 0x11, yoff = 0x1A }

-- Names for the log only. Values from constants/map_object_constants.asm; anything not listed is
-- printed as a number rather than guessed at.
local ACT_NAMES = { [0] = "00", [1] = "STAND", [2] = "STEP", [3] = "BUMP", [4] = "SPIN",
	[5] = "SPIN_FLICKER", [6] = "FISHING", [8] = "EMOTE", [16] = "SKYFALL" }

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
	return string.format("0x%02X (scenery)", v)
end

-- How many of the 40 OAM entries are live, and what the player's own art offset is. The offset is
-- `(tile - base) & 0xFF` -- the same arithmetic the adapter's frame learner uses -- so 0x00-0x0B is
-- a standing view, 0x80-0x8B a stepping one, and anything else is not this character's art.
local function drawn()
	local base = u8(OBJ + F.tile)
	local live = 0
	for e = 0, 39 do
		local ey = memory.read_u8(e * 4, "OAM") or 0
		if ey ~= 0 and ey < 160 then live = live + 1 end
	end
	return ((memory.read_u8(2, "OAM") or 0) - base) & 0xFF, live
end

-- RUN-LENGTH, never one line per frame. The question is the cadence, and a hundred identical lines
-- hide it while a run length states it directly. Also how the tick rate gets measured: a run is
-- video frames, and OBJECT_STEP_FRAME's own increments inside it are engine ticks.
local run = { key = nil, n = 0, sfFirst = nil, sfLast = nil, sfSteps = 0 }
local totals = {}

local function flush()
	if not run.key then return end
	f:write(string.format("    %s   x%d video frames (step_frame %d..%d, %d engine ticks)\n",
		run.key, run.n, run.sfFirst or -1, run.sfLast or -1, run.sfSteps))
	f:flush()
	run.key = nil
end

local function record(key, sf)
	if key ~= run.key then
		flush()
		run.key, run.n, run.sfFirst, run.sfLast, run.sfSteps = key, 0, sf, sf, 0
	end
	run.n = run.n + 1
	if sf ~= run.sfLast then
		run.sfSteps = run.sfSteps + 1
		run.sfLast = sf
	end
end

-- PHASES. Fixed lengths, a countdown, and nothing to time.
local FPS = 60
local PHASES = {
	{ name = "settle", secs = 3,
		say = "starting -- stand wherever you like, nothing is being asked of you yet" },
	{ name = "turn", secs = 12,
		say = "DRIVEN: tapping each direction to TURN IN PLACE (this is OBJECT_ACTION_SPIN)" },
	{ name = "bump", secs = 24,
		say = "DRIVEN: holding each direction -- whichever ones are walls give OBJECT_ACTION_BUMP" },
	{ name = "free", secs = 180,
		say = "FREE: do whatever of these you can, in any order, and skip any you cannot --\n"
			.. "      FISH off a ledge into water; FLY to a town and watch the landing; step on a\n"
			.. "      SPIN TILE; use DIG or TELEPORT. Anything you manage is recorded, anything\n"
			.. "      you skip costs nothing. Walking around between them is fine." },
}
local phase, phaseLeft, spoke = 0, 0, nil
local n = 0

MESHGHOST_DEV_TICK = function()
	n = n + 1
	if n < 60 then return end

	-- Phase bookkeeping first, so a phase change flushes the run before the new phase's data
	-- lands in it.
	if phaseLeft <= 0 then
		flush()
		phase = phase + 1
		if phase > #PHASES then
			if not spoke then
				spoke = true
				console.log("action_probe: done -- see action.log beside the script.")
				f:write("\n=== done ===\n")
				local keys = {}
				for k in pairs(totals) do keys[#keys + 1] = k end
				table.sort(keys)
				for _, k in ipairs(keys) do
					f:write(string.format("  action %-14s seen on %d video frames\n", k, totals[k]))
				end
				f:flush()
			end
			return
		end
		local p = PHASES[phase]
		phaseLeft = p.secs * FPS
		console.log(string.format("action_probe [%d/%d] %s (%ds): %s",
			phase, #PHASES, p.name, p.secs, p.say))
		f:write(string.format("\n=== phase %s, %d seconds ===\n", p.name, p.secs))
		f:flush()
	end
	phaseLeft = phaseLeft - 1
	local p = PHASES[phase]

	-- A countdown, spoken, so the run needs no clock-watching.
	if phaseLeft % (5 * FPS) == 0 and phaseLeft > 0 then
		console.log(string.format("action_probe: %s -- %ds left", p.name, phaseLeft // FPS))
	end

	-- DRIVEN PHASES. Both are things the probe can do to itself, which is the cheapest kind of
	-- evidence: no dependence on the player reaching water, owning Fly, or finding a spin tile.
	if p.name == "turn" then
		-- A TAP, not a hold: tapping a direction the player is not already facing turns in place
		-- without stepping, and TurningStep sets OBJECT_ACTION_SPIN for it. Three seconds each so
		-- the turn and the idle after it are both plainly visible in the run lengths.
		local dirs = { "Down", "Left", "Up", "Right" }
		local i = (((p.secs * FPS - phaseLeft) // (3 * FPS)) % 4) + 1
		if (phaseLeft % (3 * FPS)) > (3 * FPS - 3) then
			joypad.set({ [dirs[i]] = true })
		end
	elseif p.name == "bump" then
		-- Hold each direction for six seconds. Whichever ones are walls bump; whichever are open
		-- just walk, and those are simply not bumps -- the log says which happened either way.
		local dirs = { "Down", "Left", "Up", "Right" }
		local i = (((p.secs * FPS - phaseLeft) // (6 * FPS)) % 4) + 1
		joypad.set({ [dirs[i]] = true })
	end

	local act = u8(OBJ + F.act)
	local face = u8(OBJ + F.face)
	local sf = u8(OBJ + F.stepframe)
	local name = ACT_NAMES[act] or tostring(act)
	totals[name] = (totals[name] or 0) + 1

	-- ORDINARY WALKING IS NOT THE SUBJECT and would drown everything else: actions 0/1/2 are what
	-- a character does while standing or stepping normally, and the adapter already renders those
	-- from position. Recorded as one collapsed run so the gaps between the interesting stretches
	-- are still visible, but not in detail.
	if act == 0 or act == 1 or act == 2 then
		record("(walking/standing)", sf)
		return
	end

	local off, live = drawn()
	record(string.format("act=%-13s face=0x%02X %-20s tile_off=0x%02X yoff=%4d oam=%d steptype=%d",
		name, face, faceName(face), off, ((u8(OBJ + F.yoff) + 128) % 256) - 128, live,
		u8(OBJ + F.steptype)), sf)
end
