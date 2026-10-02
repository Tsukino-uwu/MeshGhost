-- Pokémon Crystal: what the player's object carries while gliding on ice, against a walking control: whether
-- OBJECT_FLAGS1's SLIDING bit is set on ice and clears off it. Read-only, but it holds the d-pad (left and right on
-- the ice, then up and down): unload it before judging the screen.

local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	f = io.open(dir .. "/ice.log", "w")
	if f then f:setvbuf("full", 1 << 16) end
end

local function u8(a) return memory.read_u8(a, "System Bus") or 0 end

local OBJ, STRIDE, NSTRUCTS = 0xD4D6, 0x28, 13
local F = { sprite = 0x00, tile = 0x02, flags1 = 0x04, walking = 0x07, dir = 0x08,
	steptype = 0x09, act = 0x0B, stepframe = 0x0C, face = 0x0D, tilecoll = 0x0E,
	mx = 0x10, my = 0x11 }
local SLIDING, FIXED_FACING, WONT_DELETE = 0x08, 0x04, 0x02

local function flagStr(v)
	local s = {}
	if (v & SLIDING) ~= 0 then s[#s + 1] = "SLIDING" end
	if (v & FIXED_FACING) ~= 0 then s[#s + 1] = "FIXEDFACE" end
	if (v & WONT_DELETE) ~= 0 then s[#s + 1] = "WONTDEL" end
	return #s > 0 and table.concat(s, "+") or "-"
end

local run = { key = nil, n = 0, at = 0, sfFirst = nil, sfLast = nil, sfSteps = 0 }
local function flush()
	if not run.key or not f then return end
	f:write(string.format("  f%-6d %s  x%d frames (step_frame %d..%d = %d changes)\n",
		run.at, run.key, run.n, run.sfFirst or -1, run.sfLast or -1, run.sfSteps))
	run.key = nil
end
local function record(key, sf, frame)
	if key ~= run.key then
		flush()
		run.key, run.n, run.at, run.sfFirst, run.sfLast, run.sfSteps = key, 0, frame, sf, sf, 0
	end
	run.n = run.n + 1
	if sf ~= run.sfLast then run.sfSteps, run.sfLast = run.sfSteps + 1, sf end
end

-- Ghost slots by the adapter's own marker (WONT_DELETE and the local player's sprite), never by slot number.
local function ghostLine()
	local ps = u8(OBJ + F.sprite)
	local out = {}
	for i = 1, NSTRUCTS - 1 do
		local b = OBJ + i * STRIDE
		if (u8(b + F.tile) ~= 0 or u8(b + F.act) ~= 0)
			and (u8(b + F.flags1) & WONT_DELETE) ~= 0 and u8(b + F.sprite) == ps then
			out[#out + 1] = string.format("g%d %s stype=%d frame=%2d face=%02X at %d,%d",
				i, flagStr(u8(b + F.flags1)), u8(b + F.steptype), u8(b + F.stepframe),
				u8(b + F.face), u8(b + F.mx), u8(b + F.my))
		end
	end
	return #out > 0 and table.concat(out, " | ") or "(no ghost object)"
end

local FPS = 60
local PHASES = {
	{ name = "settle", secs = 3, say = "no input -- recording where you are" },
	-- Left and right is the axis that slides from where the player stands; an axis into a wall measures a bump.
	{ name = "ice", secs = 30, say = "DRIVEN: left/right across the ice, alternating every 5s" },
	{ name = "walk", secs = 12,
		say = "DRIVEN: up/down -- THE CONTROL, to catch the bit CLEARING off the ice" },
}
local phase, phaseLeft, done, n, frame = 0, 0, false, 0, 0
local sawSliding, sawClear = false, false

MESHGHOST_DEV_TICK = function()
	if done then return end
	n = n + 1
	if n < 30 then return end
	frame = frame + 1

	if phaseLeft <= 0 then
		flush()
		phase = phase + 1
		if phase > #PHASES then
			done = true
			if f then
				f:write("\n=== done ===\n")
				f:write(string.format("  SLIDING seen SET   : %s\n", tostring(sawSliding)))
				f:write(string.format("  SLIDING seen CLEAR : %s\n", tostring(sawClear)))
				f:write("  Both true = the bit is the game's own ice signal and the adapter can\n")
				f:write("  mirror it. SET never seen = the suppression is elsewhere; do NOT invent\n")
				f:write("  a wire field from the decompilation alone.\n")
				f:flush()
			end
			console.log("ice_probe: done -- see ice.log beside the script.")
			return
		end
		local p = PHASES[phase]
		phaseLeft = p.secs * FPS
		console.log(string.format("ice_probe [%d/%d] %s (%ds): %s", phase, #PHASES, p.name,
			p.secs, p.say))
		if f then f:write(string.format("\n=== phase %s ===\n", p.name)) end
	end
	phaseLeft = phaseLeft - 1
	local p = PHASES[phase]

	if p.name == "ice" then
		joypad.set({ [((frame // (5 * FPS)) % 2 == 0) and "Left" or "Right"] = true })
	elseif p.name == "walk" then
		joypad.set({ [((frame // (3 * FPS)) % 2 == 0) and "Up" or "Down"] = true })
	end

	local fl = u8(OBJ + F.flags1)
	if (fl & SLIDING) ~= 0 then sawSliding = true else sawClear = true end

	record(string.format(
		"player %-18s walk=%3d stype=%2d act=%d face=%02X coll=%02X at %2d,%2d || %s",
		flagStr(fl), u8(OBJ + F.walking), u8(OBJ + F.steptype), u8(OBJ + F.act),
		u8(OBJ + F.face), u8(OBJ + F.tilecoll), u8(OBJ + F.mx), u8(OBJ + F.my), ghostLine()),
		u8(OBJ + F.stepframe), frame)
	if frame % 120 == 0 and f then f:flush() end
end
