-- What the player's object does when not walking: action, facing, step frame and drawn tile, run-length encoded so
-- each facing's hold, the object clock and the live OAM count show. Two driven phases, then a free one, counted down.
-- Offsets as in meshghost_crystal.lua; stepframe and yoff are the decompilation's struct layout, unused there.
-- The log goes beside this script by its own path: an absolute one would be a personal path in a public repo.
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

-- Raw numbers: a value's meaning is what a run shows, not what a table says.
local function faceName(v)
	return string.format("0x%02X", v)
end

-- Live OAM entries, and the player's art offset (tile - base) & 0xFF, the adapter's frame-learner arithmetic:
-- 0x00-0x0B a standing view, 0x80-0x8B a stepping one, anything else not this character's art.
local function drawn()
	local base = u8(OBJ + F.tile)
	local live = 0
	for e = 0, 39 do
		local ey = memory.read_u8(e * 4, "OAM") or 0
		if ey ~= 0 and ey < 160 then live = live + 1 end
	end
	return ((memory.read_u8(2, "OAM") or 0) - base) & 0xFF, live
end

-- A run is video frames, and OBJECT_STEP_FRAME's increments inside it are engine ticks.
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

	-- Phase bookkeeping first, so a phase change flushes the run before the new phase's data lands in it.
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

	if phaseLeft % (5 * FPS) == 0 and phaseLeft > 0 then
		console.log(string.format("action_probe: %s -- %ds left", p.name, phaseLeft // FPS))
	end

	if p.name == "turn" then
		-- A tap turns in place without stepping; three seconds each, so the turn and the idle after it both show.
		local dirs = { "Down", "Left", "Up", "Right" }
		local i = (((p.secs * FPS - phaseLeft) // (3 * FPS)) % 4) + 1
		if (phaseLeft % (3 * FPS)) > (3 * FPS - 3) then
			joypad.set({ [dirs[i]] = true })
		end
	elseif p.name == "bump" then
		-- Six seconds a direction: walls bump, open sides just walk, and the log says which.
		local dirs = { "Down", "Left", "Up", "Right" }
		local i = (((p.secs * FPS - phaseLeft) // (6 * FPS)) % 4) + 1
		joypad.set({ [dirs[i]] = true })
	end

	local act = u8(OBJ + F.act)
	local face = u8(OBJ + F.face)
	local sf = u8(OBJ + F.stepframe)
	local name = tostring(act)
	totals[name] = (totals[name] or 0) + 1

	-- Actions 0-2 are standing and ordinary steps, which the adapter renders from position: one collapsed run.
	if act == 0 or act == 1 or act == 2 then
		record("(walking/standing)", sf)
		return
	end

	local off, live = drawn()
	record(string.format("act=%-13s face=0x%02X %-20s tile_off=0x%02X yoff=%4d oam=%d steptype=%d",
		name, face, faceName(face), off, ((u8(OBJ + F.yoff) + 128) % 256) - 128, live,
		u8(OBJ + F.steptype)), sf)
end
