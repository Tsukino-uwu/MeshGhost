-- MeshGhost — Pokémon Crystal: walk test — make a spawned ghost WALK, the way the game does
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
-- Spawning is finished (phase9.md): a player-looking character appears where we ask, drawn and
-- animated by the game. This adds MOVEMENT, using the step anatomy captured from a real NPC.
--
-- A step is initiated in ONE frame; the engine plays out the remaining ~16 by itself. The map
-- coordinate is the DESTINATION, written at the start, with the sprite sliding to catch up --
-- the opposite of what was assumed when this was planned.
--
-- The ghost paces four tiles right, then four left, so the walk is visible and it returns to
-- where it began.
--
-- HOW SUCCESS IS JUDGED
-- The screen: does it WALK, with a proper step animation, or does it jump between tiles? A
-- character that teleports while animating means the initiation set is incomplete.
--
-- HOW TO RUN
--   1. STOP EVERY OTHER MESHGHOST SCRIPT. Running two writers is what invalidated an earlier run.
--   2. Stand in the overworld somewhere with a visible NPC -- Elm's lab works, its aides pace
--      about, and a moving reference is all the control needs.
--   3. Lua Console -> Script -> Open, pick this file. Wait ~2 seconds, then walk around.
--      Log: walk_test_<timestamp>.log beside this script.

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
-- wPlayerBGMapOffsetX/Y (01:d14c / 01:d14d) — the sub-tile scroll, needed to compute an
-- object's screen position the way CopyTempObjectToObjectStruct does.
local W_BGMAPOFFSETX, W_BGMAPOFFSETY = flat(0xD14C), flat(0xD14D)

local OBJECT_LENGTH = 0x28
local MAPOBJECT_LENGTH = 0x10
local NUM_OBJECT_STRUCTS = 13
local NUM_MAP_OBJECTS = 16

local M_OBJECT_STRUCT_ID, M_SPRITE, M_Y_COORD, M_X_COORD = 0x00, 0x01, 0x02, 0x03
local F_SPRITE, F_MAP_OBJECT_INDEX = 0x00, 0x01
local F_FLAGS1, F_STEP_FRAME = 0x04, 0x0C
local F_SPRITE_TILE, F_PALETTE = 0x02, 0x06
local F_WALKING, F_DIRECTION, F_STEP_TYPE = 0x07, 0x08, 0x09
local F_STEP_DURATION, F_ACTION, F_FACING = 0x0A, 0x0B, 0x0D
local F_MAP_X, F_MAP_Y = 0x10, 0x11
local F_LAST_MAP_X, F_LAST_MAP_Y = 0x12, 0x13
local F_INIT_X, F_INIT_Y = 0x14, 0x15
local F_SPRITE_X, F_SPRITE_Y = 0x17, 0x18

local FLAG1_WONT_DELETE = 0x02

-- PROBE FLAG, default OFF. Keeps the template NPC's script pointer so the ghost can be talked to.
-- Off means the ghost is silent, which is correct behaviour; on means it speaks whichever NPC it
-- was copied from, which is wrong but demonstrates that interaction is possible at all.
-- See agent_docs/ideas.md, "Crystal: a ghost you can talk to".
local KEEP_TEMPLATE_SCRIPT = false
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
	logfile = io.open(string.format("%s/walk_test_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
end

local raw_log = console.log
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
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
log("=== MeshGhost Crystal walk test — initiate real steps (WRITES RAM) ===")

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

		-- TWO DIFFERENT QUANTITIES, conflated all session until 2026-08-18:
		--   wXCoord/wYCoord    = the origin of the VISIBLE WINDOW. Used by the engine's own range
		--                        checks, and by the screen-coordinate formula below.
		--   player struct MAP_X/MAP_Y = where the PLAYER actually stands on the map.
		-- Placing at "wXCoord + 2" put a ghost two tiles from the top-left of the screen, which is
		-- how test 6's first run spawned next to Professor Elm instead of next to the player.
		local win_x, win_y = u8(W_XCOORD) or 0, u8(W_YCOORD) or 0
		local px = u8(OBJECT_STRUCTS + F_MAP_X) or 0
		local py = u8(OBJECT_STRUCTS + F_MAP_Y) or 0
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

		-- THE TEMPLATE'S SCRIPT. Copying an NPC wholesale copies its MAPOBJECT_SCRIPT_POINTER and
		-- MAPOBJECT_EVENT_FLAG too, so the ghost inherits that NPC's dialogue and can be talked to
		-- — found live 2026-08-18, when talking to a ghost produced an aide's line about the
		-- player's Pokémon.
		--
		-- That is a bug as it stands (a peer's ghost should not speak someone else's lines) and
		-- simultaneously the discovery that **a ghost can be INTERACTED WITH AT ALL**, which is a
		-- door to talking to a peer, and eventually to battling one. See `agent_docs/ideas.md`.
		-- So it is a switch, not a deletion, and the default is off.
		if not KEEP_TEMPLATE_SCRIPT then
			for _, off in ipairs({ 0x0A, 0x0B, 0x0C, 0x0D }) do
				w8(our_mo_base + off, 0)
			end
		else
			log("KEEP_TEMPLATE_SCRIPT is on — the ghost will speak the template NPC's lines.")
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

		-- THE ONE NEW THING IN TEST 6, and the reason it exists.
		--
		-- Test 5 showed the engine IS processing our object: its STEP_FRAME advanced 1 -> 2 -> 3
		-- with nothing of ours touching it. So it was never unowned -- it was INVISIBLE, drawn at
		-- sprite_y 176, below a 144-pixel screen, because we copied the template NPC's screen
		-- coordinates instead of computing our own.
		--
		-- Adoption does not inherit them either. CopyTempObjectToObjectStruct computes them from
		-- the map position (engine/overworld/player_object.asm, .InitYCoord / .InitXCoord):
		--
		--     OBJECT_SPRITE_Y = ((map_y - wYCoord) & $0F) * 16 - wPlayerBGMapOffsetY
		--     OBJECT_SPRITE_X = ((map_x - wXCoord) & $0F) * 16 - wPlayerBGMapOffsetX
		--
		-- ANDing to the low nibble is what makes it a position within the visible window rather
		-- than an absolute map coordinate, and the BG map offset is the sub-tile scroll.
		local bg_x = u8(W_BGMAPOFFSETX) or 0
		local bg_y = u8(W_BGMAPOFFSETY) or 0
		-- Relative to the WINDOW origin, not the player -- that is what the engine's formula uses.
		local sx = (((gx - win_x) & 0x0F) * 16 - bg_x) & 0xFF
		local sy = (((gy - win_y) & 0x0F) * 16 - bg_y) & 0xFF
		w8(our_st_base + F_SPRITE_X, sx)
		w8(our_st_base + F_SPRITE_Y, sy)
		log(string.format(
			"Computed screen coords: sprite_x=%d sprite_y=%d (bg offset %d,%d) — NOT copied.",
			sx, sy, bg_x, bg_y
		))

		-- THE ONE NEW THING IN TEST 7: wear the PLAYER's face while keeping the NPC's behaviour.
		--
		-- The obstacle to appearance is OBJECT_SPRITE_TILE, which is not a value but a per-map VRAM
		-- allocation: wUsedSprites is built at map load from the objects that map defines, and a
		-- sprite with no tiles loaded cannot be drawn. Injecting a new sprite id would mean
		-- extending that allocation, which is what disturbed other objects' graphics earlier.
		--
		-- The way around it needs no allocation at all: **the player's sprite is resident on every
		-- map by construction**, because the player is always there. So copy the player's SPRITE
		-- and its already-valid SPRITE_TILE, and leave everything else as the NPC's.
		--
		-- GENDER COMES FREE, and this is the reason it is the right approach rather than merely a
		-- convenient one. Crystal picks the player's sprite from ChrisStateSprites/KrisStateSprites
		-- keyed on wPlayerState, so whichever of Chris or Kris this save is, THAT is the sprite
		-- already loaded and already in the player's struct. Copying it inherits the correct
		-- gender without reading wPlayerGender or knowing which table was used.
		--
		-- The limit, stated plainly: this makes a ghost look like THIS machine's player, not like
		-- the peer it represents. Showing a peer's own gender needs their sprite loaded on our map,
		-- which is the allocation problem again -- deferred, not solved.
		local player_sprite = u8(OBJECT_STRUCTS + F_SPRITE)
		local player_tile = u8(OBJECT_STRUCTS + F_SPRITE_TILE)
		local player_palette = u8(OBJECT_STRUCTS + F_PALETTE)
		w8(our_st_base + F_SPRITE, player_sprite or 0)
		w8(our_st_base + F_SPRITE_TILE, player_tile or 0)
		w8(our_st_base + F_PALETTE, player_palette or 0)
		w8(our_mo_base + M_SPRITE, player_sprite or 0)
		log(string.format(
			"Wearing the player's face: sprite=%s tile=%s palette=%s (gender inherited, not chosen).",
			tostring(player_sprite), tostring(player_tile), tostring(player_palette)
		))

		written = true
		mine = { sprite = u8(our_st_base + F_SPRITE), group = u8(W_MAPGROUP), number = u8(W_MAPNUMBER),
			st_base = our_st_base, next_step = frames + 60 }
		log(string.format("Ours: map object %d <-> struct %d at map %d,%d (player at map %d,%d; window origin %d,%d).",
			mo, st, gx, gy, px, py, win_x, win_y))
		log("It will look like that NPC, not like you. Appearance is the next problem, not this one.")
		log(">>> WALK AROUND. <<< Watch the two columns below: if ours starts tracking the way the")
		log("NPC does, the engine has taken it.")
		return
	end

	if not mine then
		return
	end

	-- WALKING THE GHOST.
	--
	-- Captured from a real step (verified.md, 2026-08-18): a step is initiated in ONE frame and
	-- the engine plays out the remaining ~16 by itself — the duration countdown, the walk
	-- animation, and the 2px-per-2-frames slide that carries the sprite one tile.
	--
	-- The map coordinate is the DESTINATION and is written at the START. That was the opposite of
	-- what was assumed when this work was planned.
	--
	-- Direction encoding, derived from InitStep rather than guessed: it stores the value in
	-- OBJECT_WALKING and computes DIRECTION = (walking << 2) & $0C. All three captured steps agree
	-- — player down walking=4 -> dir 0, NPC left 6 -> 8, NPC right 7 -> 12. So:
	--     WALKING = 4 + dir,  DIRECTION = FACING = dir * 4,  dir: 0 down, 1 up, 2 left, 3 right.
	--
	-- Only initiate when the ghost is idle (STEP_DURATION back to 0), or we would interrupt a step
	-- half-played and produce exactly the teleporting-while-animating artefact this avoids.
	if (u8(mine.st_base + F_STEP_DURATION) or 0) ~= 0 then
		return
	end
	if frames < (mine.next_step or 0) then
		return
	end

	-- Pace back and forth so the walk is obvious on screen and returns to where it started.
	mine.leg = (mine.leg or 0) + 1
	local dir = (mine.leg % 8 < 4) and 3 or 2 -- right for four steps, then left for four
	local dx = (dir == 3) and 1 or -1

	local x = (u8(mine.st_base + F_MAP_X) or 0) + dx
	local y = u8(mine.st_base + F_MAP_Y) or 0

	w8(mine.st_base + F_WALKING, 4 + dir)
	w8(mine.st_base + F_DIRECTION, dir * 4)
	w8(mine.st_base + F_FACING, dir * 4)
	w8(mine.st_base + F_STEP_TYPE, 2) -- the NPC step type seen in the capture
	w8(mine.st_base + F_STEP_DURATION, 7)
	w8(mine.st_base + F_ACTION, 2)
	w8(mine.st_base + F_MAP_X, x)
	w8(mine.st_base + F_MAP_Y, y)

	mine.next_step = frames + 24 -- a step takes ~16 frames; leave a beat between them
	log(string.format("  f=%-6d initiated step %s -> map %d,%d (walking=%d dir=%d)",
		frames, (dir == 3) and "right" or "left", x, y, 4 + dir, dir * 4))

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
