-- MeshGhost — Pokémon Crystal: spawn test 5, built from an NPC instead of from the player
--
-- *** WRITES GAME RAM. *** Same rules as the 2026-08-17 ADR: object RAM only, never a save,
-- cosmetic only, vanilla Crystal V1.0 only.
--
-- WHAT THE DIFF SHOWED (2026-08-18, verified.md)
-- Comparing a hand-built object against a real engine-driven NPC, with a working control, gave
-- nine field differences. Two of them explain the behaviour, and both come from one decision --
-- every previous test copied THE PLAYER as its template:
--
--   MOVEMENT_TYPE  engine NPC 3, ours 11.  11 is SPRITEMOVEDATA_PLAYER: "this object is driven by
--                                          the player's input system". So the engine does not
--                                          drive it. This is the strongest single candidate.
--   SPRITE_TILE    engine NPC 24, ours 0.  The per-map VRAM tile allocation. Ours has no graphics
--                                          slot at all.
--
-- and the rest follow from the same mistake: RADIUS 0 (an NPC's wander radius), JUMP_HEIGHT and
-- OBJECT_1D carrying player state that means nothing on an NPC, and the step fields describing a
-- stopped object rather than a live one.
--
-- WHAT THIS TEST DOES
-- Copies a REAL NPC on the current map -- both its map object and its object struct -- and changes
-- only position. Everything else, including MOVEMENT_TYPE, RADIUS and SPRITE_TILE, is inherited
-- from something the engine is demonstrably driving right now.
--
-- **The ghost will therefore look like that NPC, not like the player. That is deliberate.** This
-- test asks ONE question and appearance is not it:
--
--     "Does the engine drive an object built from an NPC template?"
--
-- Making it look like the player is the NEXT problem, and a harder one: SPRITE_TILE is an
-- allocation, not a value, so wearing the player's face means the player's sprite must have tiles
-- loaded for this map. Copying an NPC's tile index would just draw that NPC. One variable at a
-- time -- ownership first, appearance second.
--
-- HOW SUCCESS IS JUDGED
-- The same control that finally worked: watch the source NPC and our copy side by side. If ours
-- now tracks the way the NPC does, the engine has taken it. If ours still sits frozen while the
-- NPC moves, the template was not the problem and the answer is the ADR's call-the-routine branch.
--
-- HOW TO RUN
--   1. STOP EVERY OTHER MESHGHOST SCRIPT. Running two writers is what invalidated an earlier run.
--   2. Stand in the overworld somewhere with a visible NPC -- Elm's lab works, its aides pace
--      about, and a moving reference is all the control needs.
--   3. Lua Console -> Script -> Open, pick this file. Wait ~2 seconds, then walk around.
--      Log: spawn_test5_<timestamp>.log beside this script.

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
local W_MAPGROUP, W_MAPNUMBER = flat(0xDCB5), flat(0xDCB6)
local W_MAPSTATUS, W_BATTLEMODE = flat(0xD432), flat(0xD22D)

local OBJECT_LENGTH = 0x28
local MAPOBJECT_LENGTH = 0x10
local NUM_OBJECT_STRUCTS = 13
local NUM_MAP_OBJECTS = 16

local M_OBJECT_STRUCT_ID, M_SPRITE, M_Y_COORD, M_X_COORD = 0x00, 0x01, 0x02, 0x03
local F_SPRITE, F_MAP_OBJECT_INDEX = 0x00, 0x01
local F_FLAGS1, F_STEP_FRAME = 0x04, 0x0C
local F_MAP_X, F_MAP_Y = 0x10, 0x11
local F_LAST_MAP_X, F_LAST_MAP_Y = 0x12, 0x13
local F_INIT_X, F_INIT_Y = 0x14, 0x15
local F_SPRITE_X, F_SPRITE_Y = 0x17, 0x18

local FLAG1_WONT_DELETE = 0x02
local SPAWN_AFTER_FRAMES = 120
local UNASSIGNED = 0xFF
local MAPSTATUS_HANDLE = 2

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/spawn_test5_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
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
		-- Flush every 20 LINES: bounded cost, live log. The buffering sweep removed the per-line
		-- flush and a probe then reported NOTHING for a whole run (pitfalls.md: an empty log reads
		-- exactly like "nothing happened").
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

-- Same identity guard as the diff probe: an object using the player's sprite is one of ours from
-- another script, not an engine NPC. Rejecting it loudly rather than silently.
local function find_source_npc()
	local player_sprite = u8(OBJECT_STRUCTS + F_SPRITE)
	for i = 1, NUM_MAP_OBJECTS - 1 do
		local base = MAP_OBJECTS + (i * MAPOBJECT_LENGTH)
		local sprite = u8(base + M_SPRITE) or 0
		local id = u8(base + M_OBJECT_STRUCT_ID)
		if sprite ~= 0 and id and id ~= UNASSIGNED and id < NUM_OBJECT_STRUCTS then
			if sprite == player_sprite then
				log(string.format("!! map object %d uses the player's sprite — another MeshGhost", i))
				log("!! script is still running. Stop it; this run cannot be trusted.")
			else
				return i, id
			end
		end
	end
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
	for _, d in ipairs({ { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 }, { 1, 1 }, { -1, -1 } }) do
		local x, y = px + d[1], py + d[2]
		if x >= 0 and y >= 0 and not tile_occupied(x, y) then
			return x, y
		end
	end
end

open_log()
log("=== MeshGhost Crystal spawn test 5 — NPC as template (WRITES RAM) ===")

local ok, why = rom_is_vanilla_v1()
if not ok then
	log("REFUSING TO WRITE: " .. why)
	return
end
log("ROM guard passed: " .. why)

local frames, written = 0, false
local src_st_base, our_st_base, our_mo_base, mine, last_key

local function tick()
	frames = frames + 1

	if not written then
		if frames < SPAWN_AFTER_FRAMES then
			return
		end
		if u8(W_MAPSTATUS) ~= MAPSTATUS_HANDLE or u8(W_BATTLEMODE) ~= 0 then
			return
		end

		local src_mo, src_st = find_source_npc()
		if not src_mo then
			log("No engine-driven NPC on this map to copy. Move somewhere with a person.")
			written = true
			return
		end

		local mo, st = free_map_object(), free_struct()
		local px, py = u8(W_XCOORD) or 0, u8(W_YCOORD) or 0
		local gx, gy = pick_spot(px, py)
		if not mo or not st or not gx then
			log("No free slot or clear tile. Move somewhere more open.")
			written = true
			return
		end

		local src_mo_base = MAP_OBJECTS + (src_mo * MAPOBJECT_LENGTH)
		src_st_base = OBJECT_STRUCTS + (src_st * OBJECT_LENGTH)
		our_mo_base = MAP_OBJECTS + (mo * MAPOBJECT_LENGTH)
		our_st_base = OBJECT_STRUCTS + (st * OBJECT_LENGTH)

		log(string.format("Template: NPC map object %d -> struct %d (sprite %d), engine-driven.",
			src_mo, src_st, u8(src_mo_base + M_SPRITE) or -1))

		-- Copy the NPC wholesale, both halves.
		for off = 0, MAPOBJECT_LENGTH - 1 do
			w8(our_mo_base + off, u8(src_mo_base + off) or 0)
		end
		for off = 0, OBJECT_LENGTH - 1 do
			w8(our_st_base + off, u8(src_st_base + off) or 0)
		end

		-- Then change ONLY position and the cross-references.
		w8(our_mo_base + M_X_COORD, gx)
		w8(our_mo_base + M_Y_COORD, gy)
		w8(our_mo_base + M_OBJECT_STRUCT_ID, st)
		w8(our_st_base + F_MAP_OBJECT_INDEX, mo)
		for _, off in ipairs({ F_MAP_X, F_LAST_MAP_X, F_INIT_X }) do
			w8(our_st_base + off, gx)
		end
		for _, off in ipairs({ F_MAP_Y, F_LAST_MAP_Y, F_INIT_Y }) do
			w8(our_st_base + off, gy)
		end

		-- Keep WONT_DELETE, since the engine culls objects whose current AND spawn tiles leave the
		-- visible window -- the mechanic behind the ghost vanishing at the bottom of Elm's lab.
		local flags = u8(our_st_base + F_FLAGS1) or 0
		w8(our_st_base + F_FLAGS1, flags | FLAG1_WONT_DELETE)

		written = true
		mine = { sprite = u8(our_st_base + F_SPRITE), group = u8(W_MAPGROUP), number = u8(W_MAPNUMBER) }
		log(string.format("Ours: map object %d <-> struct %d at %d,%d (player at %d,%d).",
			mo, st, gx, gy, px, py))
		log("It will look like that NPC, not like you. Appearance is the next problem, not this one.")
		log(">>> WALK AROUND. <<< Watch the two columns below: if ours starts tracking the way the")
		log("NPC does, the engine has taken it.")
		return
	end

	if not mine then
		return
	end

	-- OWNERSHIP TEST, third attempt at choosing one, and the first that can actually distinguish.
	--
	-- The two previous choices were both wrong in the same way. OBJECT_SPRITE_X/Y are SCREEN
	-- coordinates, and ApplyBGMapAnchorToObjects only ADDS A DELTA to them -- which is zero in a
	-- room whose camera does not move. The template NPC's changed because the NPC WALKS, not
	-- because it is owned. A stationary object's screen coordinates stay put whether the engine
	-- owns it or not, so that comparison never distinguished anything.
	--
	-- What does distinguish: the template NPC wanders (MOVEMENT_TYPE 3, RADIUS 17). If the engine
	-- owns our copy, it will wander too -- so its MAP coordinates will change ON THEIR OWN, and its
	-- STEP_FRAME will advance as it animates. Neither can happen to an object nobody is driving.
	local gone = u8(W_MAPGROUP) ~= mine.group or u8(W_MAPNUMBER) ~= mine.number
		or (u8(our_st_base + F_SPRITE) or 0) == 0
	local omx, omy = u8(our_st_base + F_MAP_X), u8(our_st_base + F_MAP_Y)
	local ostep = u8(our_st_base + F_STEP_FRAME)
	local nmx, nmy = u8(src_st_base + F_MAP_X), u8(src_st_base + F_MAP_Y)
	local nstep = u8(src_st_base + F_STEP_FRAME)
	local key = string.format("%s|%s,%s,%s|%s,%s,%s", tostring(gone),
		tostring(omx), tostring(omy), tostring(ostep),
		tostring(nmx), tostring(nmy), tostring(nstep))
	if key == last_key then
		return
	end
	last_key = key

	if gone then
		log(string.format("  f=%-6d ours GONE (culled, map change, or slot reused).", frames))
		return
	end
	if mine.mx == nil then
		mine.mx, mine.my = omx, omy
	end
	local moved = (omx ~= mine.mx or omy ~= mine.my) and "  <<< OURS MOVED ON ITS OWN" or ""
	log(string.format(
		"  f=%-6d ours: map=%s,%s step=%-3s   |   template NPC: map=%s,%s step=%-3s%s",
		frames, tostring(omx), tostring(omy), tostring(ostep),
		tostring(nmx), tostring(nmy), tostring(nstep), moved
	))
end

event.onexit(function()
	pcall(function()
		if our_st_base then
			w8(our_st_base + F_SPRITE, 0)
		end
		if our_mo_base then
			for off = 0, MAPOBJECT_LENGTH - 1 do
				w8(our_mo_base + off, 0)
			end
		end
	end)
end)

while true do
	tick()
	emu.frameadvance()
end
