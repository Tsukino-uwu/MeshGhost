-- MeshGhost — Pokémon Crystal: diff our hand-built object against one the ENGINE built
--
-- *** WRITES GAME RAM (one object). *** Same rules as the 2026-08-17 ADR: object RAM only, never
-- a save, cosmetic only, vanilla Crystal V1.0 only.
--
-- WHY THIS EXISTS
-- Two attempts to build an object by hand produced the same half-owned result: collision follows
-- the map coordinates we set, while the sprite sits frozen at whatever screen coordinates were
-- copied in. Once from a bare struct (test 1), once with the map-object/struct cross-link fully in
-- place (test 4). Two failures with an identical symptom means stop guessing and isolate.
--
-- THE ISOLATION
-- The map already contains objects the ENGINE built and drives — every NPC with a struct id that
-- is not 255. So a known-good example is sitting right there, no adoption needed. This dumps one
-- of those, builds ours next to the player, and prints a FIELD-BY-FIELD DIFF.
--
-- Two outcomes, both worth having:
--   * A field differs that we are not setting -> set it, and the imitation approach works.
--   * Nothing meaningful differs -> adoption does something beyond writing field values, and
--     reproducing it by hand cannot work. That settles the ADR's open question toward calling the
--     engine's own routine instead.
--
-- IT CARRIES ITS OWN CONTROL, which the template argues every probe should:
-- the NPC is watched alongside ours. If the NPC's engine-maintained screen coordinates move while
-- ours stay frozen, the comparison is meaningful. If NEITHER moves, the probe is measuring nothing
-- (e.g. nobody is walking) and the run should be discarded rather than believed.
--
-- HOW TO RUN
--   1. Load a save, stand in the overworld ON A MAP WITH AT LEAST ONE VISIBLE NPC, with a clear
--      tile or two beside you. An indoor room with a person in it, or a route with trainers.
--   2. Lua Console -> Script -> Open, pick this file. Wait ~2 seconds.
--   3. Walk around a bit so both objects have a chance to be updated.
--      Log: struct_diff_<timestamp>.log beside this script.

local DOMAIN = "WRAM"
local ROM_DOMAIN = "ROM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

local OBJECT_STRUCTS = flat(0xD4D6)
local MAP_OBJECTS = flat(0xD71E)
local W_YCOORD, W_XCOORD = flat(0xDCB7), flat(0xDCB8)
local W_MAPSTATUS, W_BATTLEMODE = flat(0xD432), flat(0xD22D)

local OBJECT_LENGTH = 0x28
local MAPOBJECT_LENGTH = 0x10
local NUM_OBJECT_STRUCTS = 13
local NUM_MAP_OBJECTS = 16

local M_OBJECT_STRUCT_ID, M_SPRITE, M_Y_COORD, M_X_COORD = 0x00, 0x01, 0x02, 0x03
local F_SPRITE, F_MAP_OBJECT_INDEX = 0x00, 0x01
local F_FLAGS1, F_FLAGS2 = 0x04, 0x05
-- OBJECT_FLAGS1 bits (constants/map_object_constants.asm):
--   0 INVISIBLE  1 WONT_DELETE  2 FIXED_FACING  3 SLIDING
--   4 NOCLIP_TILES  5 MOVE_ANYWHERE  6 NOCLIP_OBJS  7 EMOTE_OBJECT
local FLAG1_INVISIBLE, FLAG1_WONT_DELETE = 0x01, 0x02
local F_MAP_X, F_MAP_Y = 0x10, 0x11
local F_LAST_MAP_X, F_LAST_MAP_Y = 0x12, 0x13
local F_INIT_X, F_INIT_Y = 0x14, 0x15
local F_SPRITE_X, F_SPRITE_Y = 0x17, 0x18

-- Names from pokecrystal's constants/map_object_constants.asm, so the diff reads as fields
-- rather than as offsets.
local FIELD = {
	[0x00] = "SPRITE", [0x01] = "MAP_OBJECT_INDEX", [0x02] = "SPRITE_TILE",
	[0x03] = "MOVEMENT_TYPE", [0x04] = "FLAGS1", [0x05] = "FLAGS2", [0x06] = "PALETTE",
	[0x07] = "WALKING", [0x08] = "DIRECTION", [0x09] = "STEP_TYPE", [0x0A] = "STEP_DURATION",
	[0x0B] = "ACTION", [0x0C] = "STEP_FRAME", [0x0D] = "FACING", [0x0E] = "TILE_COLLISION",
	[0x0F] = "LAST_TILE", [0x10] = "MAP_X", [0x11] = "MAP_Y", [0x12] = "LAST_MAP_X",
	[0x13] = "LAST_MAP_Y", [0x14] = "INIT_X", [0x15] = "INIT_Y", [0x16] = "RADIUS",
	[0x17] = "SPRITE_X", [0x18] = "SPRITE_Y", [0x19] = "SPRITE_X_OFFSET",
	[0x1A] = "SPRITE_Y_OFFSET", [0x1B] = "MOVEMENT_INDEX", [0x1C] = "STEP_INDEX",
	[0x1D] = "OBJECT_1D", [0x1E] = "OBJECT_1E", [0x1F] = "JUMP_HEIGHT", [0x20] = "RANGE",
}

-- Offsets expected to differ simply because the two objects are different characters standing in
-- different places. Called out so the diff highlights what is actually interesting.
local EXPECTED = {
	[F_SPRITE] = true, [F_MAP_OBJECT_INDEX] = true,
	[F_MAP_X] = true, [F_MAP_Y] = true, [F_LAST_MAP_X] = true, [F_LAST_MAP_Y] = true,
	[F_INIT_X] = true, [F_INIT_Y] = true, [F_SPRITE_X] = true, [F_SPRITE_Y] = true,
	[0x06] = true, -- PALETTE: a different character
}

local SPAWN_AFTER_FRAMES = 120
local MAPSTATUS_HANDLE = 2
local UNASSIGNED = 0xFF

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/struct_diff_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, and never flushed per line: a console.log plus a flush is a synchronous disk
	-- write on the emulator's own thread, measured at 63-83ms -- four to five frames, every time
	-- (pitfalls.md, "ONE console line a second cost 7.4 fps"). A probe that stalls the game is a
	-- probe that changes what it measures.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- THE CONSOLE IS THE EXPENSIVE HALF. `console.log` appends to BizHawk's GUI console window, on the
-- emulator's own thread; pitfalls.md measured ONE such line a second costing 7.4fps, and removing
-- the per-line disk flush alone left 87-175ms hitches still there (2026-08-21). So the console gets
-- the opening lines and then one in twenty, while the FILE gets every line -- the log is the record,
-- the console is only a glance.
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
	end
end

local function u8(addr, domain)
	local ok, v = pcall(memory.read_u8, addr, domain or DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

local function w8(addr, value)
	pcall(memory.write_u8, addr, value, DOMAIN)
end

local function rom_is_vanilla_v1()
	local t = {}
	for i = 0, 9 do
		local c = u8(0x134 + i, ROM_DOMAIN)
		if not c then
			return false, "could not read the ROM domain"
		end
		t[#t + 1] = string.char(c)
	end
	if table.concat(t) ~= "PM_CRYSTAL" then
		return false, string.format("ROM title is %q", table.concat(t))
	end
	if u8(0x14E, ROM_DOMAIN) ~= 0x12 or u8(0x14F, ROM_DOMAIN) ~= 0x9F then
		return false, "global checksum is not 129F (vanilla V1.0)"
	end
	return true, "vanilla Crystal V1.0"
end

local function struct_bytes(i)
	local base = OBJECT_STRUCTS + (i * OBJECT_LENGTH)
	local b = {}
	for off = 0, OBJECT_LENGTH - 1 do
		b[off] = u8(base + off) or 0
	end
	return b
end

-- An NPC the engine built and is driving.
--
-- "Has a struct id that is not 255" is NOT the same claim as "the engine made this", and treating
-- them as equivalent invalidated an entire run on 2026-08-18: another MeshGhost script was still
-- loaded, its hand-built ghost satisfied the test, and the probe compared our object against our
-- own other object. The diff came back clean because both sides were built the same way.
--
-- So a candidate is rejected if its sprite matches the player's. Every ghost this project builds
-- copies the player's sprite id, and no real NPC uses it. That is a heuristic rather than a proof
-- -- the real discipline is running one writer at a time -- so it warns loudly rather than
-- silently skipping.
local function find_engine_object()
	local player_sprite = u8(OBJECT_STRUCTS + F_SPRITE)
	for i = 1, NUM_MAP_OBJECTS - 1 do
		local base = MAP_OBJECTS + (i * MAPOBJECT_LENGTH)
		local sprite = u8(base + M_SPRITE) or 0
		local id = u8(base + M_OBJECT_STRUCT_ID)
		if sprite ~= 0 and id and id ~= UNASSIGNED and id < NUM_OBJECT_STRUCTS then
			if sprite == player_sprite then
				log(string.format(
					"!! map object %d uses the PLAYER's sprite (%d) — that is almost certainly a",
					i, sprite
				))
				log("!! ghost from another MeshGhost script, not an engine-built NPC. Skipping it.")
				log("!! Stop every other MeshGhost script before trusting this run.")
			else
				return i, id
			end
		end
	end
	return nil
end

local function free_map_object()
	for i = 1, NUM_MAP_OBJECTS - 1 do
		if u8(MAP_OBJECTS + (i * MAPOBJECT_LENGTH) + M_SPRITE) == 0 then
			return i
		end
	end
end

local function free_struct()
	for i = 1, NUM_OBJECT_STRUCTS - 1 do
		if u8(OBJECT_STRUCTS + (i * OBJECT_LENGTH) + F_SPRITE) == 0 then
			return i
		end
	end
end

local function tile_occupied(x, y)
	for i = 0, NUM_MAP_OBJECTS - 1 do
		local base = MAP_OBJECTS + (i * MAPOBJECT_LENGTH)
		if (u8(base + M_SPRITE) or 0) ~= 0
			and u8(base + M_X_COORD) == x and u8(base + M_Y_COORD) == y then
			return true
		end
	end
	return false
end

local function pick_spot(px, py)
	for _, d in ipairs({ { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 }, { 3, 0 }, { -3, 0 } }) do
		local x, y = px + d[1], py + d[2]
		if x >= 0 and y >= 0 and not tile_occupied(x, y) then
			return x, y
		end
	end
end

open_log()
log("=== MeshGhost Crystal struct diff — ours vs one the engine built (WRITES RAM) ===")

local ok, why = rom_is_vanilla_v1()
if not ok then
	log("REFUSING TO WRITE: " .. why)
	return
end
log("ROM guard passed: " .. why)

local frames, done = 0, false
local ref_struct, our_struct, ref_base, our_base
local last_watch = nil

local function tick()
	frames = frames + 1
	if done then
		-- The control, and the measurement, on one line. If the reference's engine-maintained
		-- screen coordinates move and ours do not, the diff above is describing a real difference.
		-- If NEITHER moves, this run measured nothing and should be discarded.
		-- Also watch FLAGS1 and SPRITE, because "the ghost disappeared" has two distinct causes in
		-- Crystal and they need telling apart (user observed it 2026-08-18, walking toward a door):
		--   * DELETED — the engine culls objects that leave visible range, unless OBJECT_FLAGS1
		--     bit 1 (WONT_DELETE) is set. A deleted object's SPRITE goes to 0.
		--   * INVISIBLE — OBJECT_FLAGS1 bit 0 set. Still there, simply not drawn.
		-- Printing only on change, so the moment it happens is a single obvious line.
		local ours_sprite = u8(our_base + F_SPRITE) or 0
		local ours_flags = u8(our_base + F_FLAGS1) or 0
		local key = string.format("%d|%d|%s|%s", ours_sprite, ours_flags,
			tostring(u8(our_base + F_SPRITE_X)), tostring(u8(ref_base + F_SPRITE_X)))
		if key ~= last_watch then
			last_watch = key
			local state
			if ours_sprite == 0 then
				state = "DELETED (sprite=0) — culled for leaving visible range"
			elseif (ours_flags & FLAG1_INVISIBLE) ~= 0 then
				state = "INVISIBLE flag set (still exists, not drawn)"
			else
				state = "present and visible"
			end
			log(string.format(
				"  f=%-6d ours: %s  flags1=0x%02X%s  sprite_x=%-3s | engine object sprite_x=%-3s",
				frames, state, ours_flags,
				((ours_flags & FLAG1_WONT_DELETE) ~= 0) and " [WONT_DELETE]" or " [deletable]",
				tostring(u8(our_base + F_SPRITE_X)), tostring(u8(ref_base + F_SPRITE_X))
			))
		end
		return
	end

	if frames < SPAWN_AFTER_FRAMES then
		return
	end
	if u8(W_MAPSTATUS) ~= MAPSTATUS_HANDLE or u8(W_BATTLEMODE) ~= 0 then
		return
	end

	local ref_mo, ref_id = find_engine_object()
	if not ref_mo then
		log("No engine-driven NPC on this map to compare against.")
		log("Move somewhere with a visible person and restart the script.")
		done = true
		return
	end

	local mo, st = free_map_object(), free_struct()
	local px, py = u8(W_XCOORD) or 0, u8(W_YCOORD) or 0
	local gx, gy = pick_spot(px, py)
	if not mo or not st or not gx then
		log("No free slot or clear tile here. Move somewhere more open and restart.")
		done = true
		return
	end

	ref_base = OBJECT_STRUCTS + (ref_id * OBJECT_LENGTH)
	our_base = OBJECT_STRUCTS + (st * OBJECT_LENGTH)
	ref_struct = struct_bytes(ref_id)

	log(string.format("Reference: map object %d -> struct %d, built and driven by the engine.",
		ref_mo, ref_id))

	-- Build ours exactly as test 4 did, so the diff describes THAT approach.
	local mo_base = MAP_OBJECTS + (mo * MAPOBJECT_LENGTH)
	for off = 0, MAPOBJECT_LENGTH - 1 do
		w8(mo_base + off, u8(MAP_OBJECTS + off) or 0)
	end
	for off = 0, OBJECT_LENGTH - 1 do
		w8(our_base + off, u8(OBJECT_STRUCTS + off) or 0)
	end
	w8(mo_base + M_X_COORD, gx)
	w8(mo_base + M_Y_COORD, gy)
	w8(mo_base + M_OBJECT_STRUCT_ID, st)
	w8(our_base + F_MAP_OBJECT_INDEX, mo)
	for _, off in ipairs({ F_MAP_X, F_LAST_MAP_X, F_INIT_X }) do
		w8(our_base + off, gx)
	end
	for _, off in ipairs({ F_MAP_Y, F_LAST_MAP_Y, F_INIT_Y }) do
		w8(our_base + off, gy)
	end

	our_struct = struct_bytes(st)
	log(string.format("Ours: map object %d <-> struct %d at %d,%d.", mo, st, gx, gy))
	log("")
	log("FIELD DIFF — engine-built vs ours (offsets expected to differ are marked 'expected'):")

	local interesting = 0
	for off = 0, OBJECT_LENGTH - 1 do
		local a, b = ref_struct[off], our_struct[off]
		if a ~= b then
			local name = FIELD[off] or string.format("unnamed_%02X", off)
			if EXPECTED[off] then
				log(string.format("    %02X %-18s engine=%3d ours=%3d   (expected)", off, name, a, b))
			else
				interesting = interesting + 1
				log(string.format(">>> %02X %-18s engine=%3d ours=%3d   <<< INTERESTING", off, name, a, b))
			end
		end
	end
	if interesting == 0 then
		log("    No unexpected differences. Every field we do not set matches the engine's own.")
		log("    That points AWAY from a missing field and toward adoption doing something")
		log("    beyond writing values — see the ADR's call-the-routine branch.")
	else
		log(string.format("    %d unexpected difference(s) above are the candidates.", interesting))
	end
	log("")
	log("Now WALK. The line below is the control: the engine's object should move, ours should not.")
	done = true
end

event.onexit(function()
	pcall(function()
		if our_base then
			w8(our_base + F_SPRITE, 0)
		end
	end)
end)

while true do
	tick()
	emu.frameadvance()
end
