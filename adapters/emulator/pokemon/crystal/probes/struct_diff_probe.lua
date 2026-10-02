-- Diffs an object built by hand beside the player, field by field, against an NPC the engine built. Writes game RAM
-- (one object), vanilla V1.0 only. Run on a map with a visible NPC, then walk; logs struct_diff_<timestamp>.log.

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
local FLAG1_INVISIBLE, FLAG1_WONT_DELETE = 0x01, 0x02
local F_MAP_X, F_MAP_Y = 0x10, 0x11
local F_LAST_MAP_X, F_LAST_MAP_Y = 0x12, 0x13
local F_INIT_X, F_INIT_Y = 0x14, 0x15
local F_SPRITE_X, F_SPRITE_Y = 0x17, 0x18

-- Empty on purpose: the diff names offsets only.
local FIELD = {}

-- Offsets that differ only because the two are different characters in different places.
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
	-- Buffered, never flushed per line: a flush is a synchronous disk write on the emulator's own thread.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- console.log is a GUI append on the emulator's own thread and costs frames: it gets the first lines and one in twenty.
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
		-- Every 20 lines, never per line: bounded cost, and the log stays live through a run.
		flushEvery = (flushEvery or 0) + 1
		if flushEvery >= 20 then
			flushEvery = 0
			pcall(function() logfile:flush() end)
		end
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

-- A struct id alone does not mean the engine built it: a candidate wearing the player's sprite is a ghost from
-- another script, so it is skipped with a warning (a heuristic; run one writer at a time).
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
		-- The control: the engine's object should move and ours should not; if neither moves, discard the run.
		-- Deleted (sprite 0) and invisible (FLAGS1 bit 0) are the two ways ours can vanish. Printed on change.
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

	-- Built the way spawn_test4.lua builds it, so the diff describes that approach.
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
