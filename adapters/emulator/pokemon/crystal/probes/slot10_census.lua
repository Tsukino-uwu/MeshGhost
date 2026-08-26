-- WHO IS ON THIS MAP, AND WHAT SPRITE ARE THEY WEARING -- a one-shot census, for telling a
-- corruption the ADAPTER causes from one the SAVESTATE already contains.
--
-- THE REPORT. User, 2026-08-26: after loading savestate 10 and walking up on the SAME map, a
-- trainer was drawn with the wrong sprite (*"displaying the 'rival' sprite instead of their
-- intended trainer sprites"*). That was first read as a map-change fault and it is not one, so
-- the mechanism is unknown and worth measuring rather than reasoning about.
--
-- WHAT MAKES THIS ANSWERABLE. A savestate restores the game's RAM and does NOT restore the
-- adapter's Lua state, so `ghosts` keeps slot numbers describing a world that no longer exists.
-- But there is a second possibility that looks identical on screen and needs the opposite fix:
-- the savestate may have been RECORDED while a ghost was spawned, in which case our object is
-- baked into it and every load of that state restores the corruption with no adapter involved.
--
-- SO RUN IT TWICE, and the pairing is the whole point:
--   A) with the adapter NOT in the loader's target -> nothing of ours is running
--   B) with the adapter loaded
-- Identical output means the state carries it and the adapter is innocent. Different output
-- means we do it live, and the diff says which slot changed and to what.
--
-- It is READ-ONLY apart from the savestate load, presses no buttons, and stops after one dump --
-- so it cannot itself be the thing that moves an NPC or steals a slot.
--
-- A SCREENSHOT IS TAKEN IN THE SAME FRAME as the dump. `client.screenshot` captures the emulated
-- framebuffer, which contains the engine's own sprites (so a real trainer and a SPAWNED ghost
-- both appear) and never the Lua overlay (so a DRAWN ghost never does). Taking the picture and
-- the numbers on different schedules is how an earlier comparison came to describe two different
-- scenes (`playing.md`), so both happen here with no frameadvance between them.
--
-- Addresses vanilla V1.0 from meshghost_crystal.lua's table; map-object layout and the type
-- nibble from constants/map_object_constants.asm and constants/script_constants.asm.
--
-- Switches: MESHGHOST_CENSUS_SLOT (default 10), MESHGHOST_CENSUS_NOLOAD, MESHGHOST_CENSUS_TAG
-- (a string put in the log and the png name, e.g. "A-no-adapter" / "B-with-adapter").

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
-- map object bytes: struct id, sprite, y, x, movement, radius, 2x time-of-day, palette|type,
-- sight range, script pointer, event flag.
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

	-- WHAT TO COMPARE, said in the file so a reader does not have to reconstruct the experiment.
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
