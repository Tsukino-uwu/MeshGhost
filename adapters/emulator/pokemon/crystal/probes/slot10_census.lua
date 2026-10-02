-- Who is on this map and what sprite each wears: a one-shot census after loading savestate MESHGHOST_CENSUS_SLOT
-- (default 10; MESHGHOST_CENSUS_NOLOAD skips it), with a screenshot in the same frame. Run it without the adapter and
-- with it (MESHGHOST_CENSUS_TAG names each run): identical dumps mean the savestate carries the fault. Read-only apart
-- from the load; the screenshot shows a spawned ghost, never a drawn one. Vanilla V1.0.

local TAG = tostring(MESHGHOST_CENSUS_TAG or "census")
local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	f = io.open(dir .. "/slot10_census_" .. TAG .. ".log", "w")
end

local function u8(a) return memory.read_u8(a, "System Bus") or 0 end

local OBJ, OSTRIDE, NSTRUCTS = 0xD4D6, 0x28, 13
local MAPOBJ, MSTRIDE, NMAPOBJ = 0xD71E, 16, 16
local W_MAPGROUP, W_MAPNUM = 0xDCB5, 0xDCB6
-- Map object bytes: struct id, sprite, y, x, movement, radius, 2x time-of-day, palette|type, sight, script, flag.
local M = { st = 0, sprite = 1, y = 2, x = 3, movement = 4, radius = 5, paltype = 8, sight = 9 }
local F = { sprite = 0x00, moidx = 0x01, tile = 0x02, flags1 = 0x04, pal = 0x06, act = 0x0B,
	face = 0x0D, mx = 0x10, my = 0x11 }
local TYPE_NAMES = { [0] = "script", "itemball", "TRAINER", "dummy3", "dummy4", "dummy5", "dummy6" }

local SLOT = tonumber(MESHGHOST_CENSUS_SLOT) or 10
local n, loaded, dumped = 0, false, false

MESHGHOST_DEV_TICK = function()
	n = n + 1
	if n < 30 or dumped then return end

	if not loaded then
		loaded = true
		if not MESHGHOST_CENSUS_NOLOAD then
			savestate.loadslot(SLOT)
			console.log("slot10_census[" .. TAG .. "]: loaded slot " .. SLOT)
		end
		n = 0 -- give the map two seconds to finish coming up before reading anything
		return
	end
	if n < 120 then return end
	dumped = true

	if not f then
		console.log("slot10_census: could not open its log")
		return
	end

	f:write(string.format("=== slot10_census [%s] slot %s, map %d:%d, frame %d ===\n",
		TAG, MESHGHOST_CENSUS_NOLOAD and "(none)" or tostring(SLOT),
		u8(W_MAPGROUP), u8(W_MAPNUM), emu.framecount()))
	f:write("\n-- MAP OBJECTS (what the MAP defines; slot 0 is the player) --\n")
	for i = 0, NMAPOBJ - 1 do
		local b = MAPOBJ + i * MSTRIDE
		local spr = u8(b + M.sprite)
		if spr ~= 0 or u8(b + M.st) ~= 0xFF then
			local pt = u8(b + M.paltype)
			f:write(string.format(
				"  mo%-2d sprite=%3d  struct=%3d  at %3d,%3d  move=%3d  pal=%d type=%d(%s) sight=%d\n",
				i, spr, u8(b + M.st), u8(b + M.x), u8(b + M.y), u8(b + M.movement),
				pt >> 4, pt & 0x0F, TYPE_NAMES[pt & 0x0F] or "?", u8(b + M.sight)))
		end
	end

	f:write("\n-- OBJECT STRUCTS (what the engine is driving) --\n")
	for i = 0, NSTRUCTS - 1 do
		local b = OBJ + i * OSTRIDE
		local spr = u8(b + F.sprite)
		if spr ~= 0 or u8(b + F.act) ~= 0 then
			f:write(string.format(
				"  st%-2d sprite=%3d  mapobj=%3d  tile=%02X  flags1=%02X pal=%02X  act=%2d face=%02X  at %3d,%3d\n",
				i, spr, u8(b + F.moidx), u8(b + F.tile), u8(b + F.flags1), u8(b + F.pal),
				u8(b + F.act), u8(b + F.face), u8(b + F.mx), u8(b + F.my)))
		end
	end

	-- How to read it, in the file itself.
	f:write("\n-- how to read this --\n")
	f:write("  Diff this against the run with the other TAG. A `sprite=` that differs on a map\n")
	f:write("  object the MAP defines is the corruption, and the slot number names it. Identical\n")
	f:write("  output means the savestate already carries it and no adapter is involved.\n")
	f:write("  A struct wearing the PLAYER's sprite id with flags1 bit 1 (WONT_DELETE, 0x02) set\n")
	f:write("  and no matching map object is one of ours left behind.\n")
	f:close()

	-- Same frame as the dump, deliberately.
	local ok = pcall(function()
		client.screenshot(string.format("%s/slot10_census_%s.png",
			(debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$") or "."), TAG))
	end)
	console.log("slot10_census[" .. TAG .. "]: dumped" .. (ok and " + screenshot" or ""))
end
