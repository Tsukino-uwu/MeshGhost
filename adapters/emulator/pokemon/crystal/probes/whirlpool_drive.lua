-- Pokémon Crystal: what the player's object, and every other occupied slot, does when a whirlpool spins the player,
-- driven from savestate MESHGHOST_WHIRL_SLOT (default 10: one tile below a whirlpool, where Up re-enters it) or,
-- with MESHGHOST_WHIRL_NOLOAD set, from where you stand. It logs, run-length, which action byte a spin is, how long
-- each facing holds in video frames and engine ticks, and whether any frame draws nothing. Writes no game memory but
-- loads the savestate and holds the d-pad: unload it before judging anything on screen.

local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	f = io.open(dir .. "/whirlpool.log", "w")
	-- Buffered, flushed on a timer: a console line plus a flush stalls the emulator's thread for frames.
	if f then f:setvbuf("full", 1 << 16) end
end

local function u8(a) return memory.read_u8(a, "System Bus") or 0 end

local OBJ, STRIDE, NSTRUCTS = 0xD4D6, 0x28, 13
local F = { tile = 0x02, flags1 = 0x04, flags2 = 0x05, pal = 0x06, walking = 0x07, dir = 0x08,
	steptype = 0x09, act = 0x0B, stepframe = 0x0C, face = 0x0D, mx = 0x10, my = 0x11,
	sx = 0x17, sy = 0x18, yoff = 0x1A }
local W_MAPGROUP, W_MAPNUM, W_YCOORD, W_XCOORD = 0xDCB5, 0xDCB6, 0xDCB7, 0xDCB8

-- Action and facing values print raw: an unknown one is a result here.
local function faceName(v)
	return string.format("0x%02X", v)
end

-- How many of the 40 hardware entries are live. Never read OAM entries 0-3 as the player's: InitSprites emits by
-- priority.
local function oamLive()
	local live = 0
	for e = 0, 39 do
		local ey = memory.read_u8(e * 4, "OAM") or 0
		if ey ~= 0 and ey < 160 then live = live + 1 end
	end
	return live
end

-- Run-length, not a line per frame: the question is the cadence. A run counts video frames, and the increments of
-- OBJECT_STEP_FRAME inside it are engine ticks.
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

-- Every occupied slot, change-only: the "!" emote and the Fly landing both live on something other than the
-- character.
local lastCensus = nil
local function census(frame)
	local parts = {}
	for i = 1, NSTRUCTS - 1 do
		local b = OBJ + i * STRIDE
		local spr = u8(b + F.tile)
		local act, face = u8(b + F.act), u8(b + F.face)
		if not (spr == 0 and act == 0 and face == 0) then
			-- Walking, step type and duration as well as the pose: a pose cannot answer a question about movement.
			parts[#parts + 1] = string.format("[%d spr=%02X act=%s face=%02X %d,%d walk=%d stype=%d dur=%d]",
				i, spr, tostring(act), face, u8(b + F.mx), u8(b + F.my),
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

	-- The savestate load happens once, after the loader has settled, and is announced. Slot 1 is never touched.
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
					-- What it saw, and what it did not: a class absent here was never produced, which is not the
					-- same as never happening.
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
								"\n  NOT SEEN: action %d never appeared on the player.\n", a))
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
		-- Up, a pause, then Up again: the failing case. Held continuously, the ghost follows and spins; after a pause
		-- it has walked down to the player's tile and never reaches the whirlpool. The pause is part of the case.
		local cyc = frame % 300
		local input = {}
		if cyc < 120 then input.Up = true end -- approach + spin + push-back
		if (cyc % 47) < 2 then input.B = true end -- clear any text box; B never confirms
		joypad.set(input)
	end

	local act = u8(OBJ + F.act)
	local face = u8(OBJ + F.face)
	local sf = u8(OBJ + F.stepframe)
	local name = tostring(act)
	totals[name] = (totals[name] or 0) + 1
	faceTotals[face] = (faceTotals[face] or 0) + 1
	sawAct[act] = true

	-- Everything, unfiltered: ordinary standing and stepping collapse into their own runs, so the spins stay visible.
	record(string.format(
		"act=%-12s face=%02X %-20s tile=%02X dir=%d walk=%3d stype=%2d yoff=%4d map=%d,%d spr=%d,%d oam=%d",
		name, face, faceName(face), u8(OBJ + F.tile), u8(OBJ + F.dir), u8(OBJ + F.walking),
		u8(OBJ + F.steptype), ((u8(OBJ + F.yoff) + 128) % 256) - 128,
		u8(OBJ + F.mx), u8(OBJ + F.my), u8(OBJ + F.sx), u8(OBJ + F.sy), oamLive()), sf, frame)

	census(frame)
	if frame % 120 == 0 and f then f:flush() end
end
