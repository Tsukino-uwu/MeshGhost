-- MeshGhost — Pokémon Crystal: clear characters this adapter left behind (DEV TOOL, WRITES)
--
-- **THIS ONE WRITES TO THE GAME**, which every other file in this folder except grant_test_kit.lua
-- does not. It clears map objects and object structs -- the same bytes the adapter clears when it
-- despawns a ghost -- so read the safety rules below before loading it.
--
-- WHY THIS EXISTS
-- The user, 2026-08-21: *"it still has the 'static ghost' glued on top of it. can you separate
-- them apart from each other already?"*
--
-- The adapter deliberately FORGETS a ghost whose identity no longer checks out rather than zeroing
-- its slot, because zeroing a slot the game has since reused would delete one of the game's own
-- NPCs. The cost of that rule is a character we made, that nothing is tracking, carrying
-- FLAG1_WONT_DELETE so the engine will not reclaim it either. It stands still forever. A map
-- change clears it (both arrays are rebuilt from ROM), but that means leaving the room to tidy up.
--
-- WHAT IT CLEARS, and it is deliberately narrow. All of these must hold:
--   * not the player (struct 0 is never touched), and
--   * wearing the LOCAL PLAYER's sprite id -- what the adapter gives a ghost, and what a map's own
--     NPCs do not wear, and
--   * FLAG1_WONT_DELETE set -- the adapter sets it on every ghost, and
--   * standing on the same tile, not animating, for HOLD_SECONDS -- longer than the adapter's own
--     five-second rule, past which a ghost it still tracked would already have been released to
--     the drawn tier. So anything still here is not being tracked by anyone.
--
-- The last condition is what makes this safe to run beside a live session: the ghost the adapter is
-- actually driving resets its timer every time its peer moves, so it is never a candidate.
--
-- IT WILL NOT CLEAR a character that is merely idle for a moment, one wearing any other sprite, or
-- anything without WONT_DELETE. If nothing matches it says so and does nothing, which is the
-- expected result in a healthy session.
--
-- HOW TO RUN
--   Add it to the loader's target file. It reports every sweep to orphan_sweep_<timestamp>.log
--   beside this file, naming every object it clears and every field it read to decide. Remove the
--   line when finished -- there is no reason to leave a writing tool loaded.

local DOMAIN = "WRAM"
local HOLD_SECONDS = 8 -- comfortably past the adapter's own 300-frame release rule

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- Vanilla V1.0, the same addresses the adapter's vanilla table uses.
local OBJECT_STRUCTS = flat(0xD4D6)
local MAP_OBJECTS = flat(0xD71E)
local OBJECT_LENGTH, MAPOBJECT_LENGTH = 0x28, 0x10
local NUM_OBJECT_STRUCTS, NUM_MAP_OBJECTS = 13, 16

local M_STRUCT_ID = 0x00
local F_SPRITE, F_MAP_OBJECT_INDEX, F_FLAGS1 = 0x00, 0x01, 0x04
local F_WALKING, F_ACTION, F_MAP_X, F_MAP_Y = 0x07, 0x0B, 0x10, 0x11
local FLAG1_WONT_DELETE = 0x02
local UNASSIGNED, STANDING = 0xFF, 255

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/orphan_sweep_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
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

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

local function w8(addr, value)
	pcall(memory.write_u8, addr, value & 0xFF, DOMAIN)
end

open_log()
log("=== MeshGhost Crystal orphan sweep (THIS ONE WRITES) ===")
log(string.format("Clears characters wearing the player's sprite with WONT_DELETE that have not "
	.. "moved for %d seconds.", HOLD_SECONDS))
log("A ghost the adapter is driving resets that timer constantly and is never a candidate.")

local frames, cleared = 0, 0
local seen = {} -- struct slot -> { x, y, stillFrames }

local function tick()
	frames = frames + 1

	local playerSprite = u8(OBJECT_STRUCTS + F_SPRITE)
	if not playerSprite or playerSprite == 0 then
		return
	end

	for st = 1, NUM_OBJECT_STRUCTS - 1 do
		local base = OBJECT_STRUCTS + st * OBJECT_LENGTH
		local sprite = u8(base + F_SPRITE)
		if not sprite or sprite == 0 then
			seen[st] = nil
		else
			local x, y = u8(base + F_MAP_X) or 0, u8(base + F_MAP_Y) or 0
			local moving = (u8(base + F_WALKING) or STANDING) ~= STANDING
			local action = u8(base + F_ACTION) or 0
			local animating = not (action == 0 or action == 1 or action == 2)
			local s = seen[st]
			if not s or s.x ~= x or s.y ~= y or moving or animating then
				seen[st] = { x = x, y = y, stillFrames = 0 }
			else
				s.stillFrames = s.stillFrames + 1
			end

			s = seen[st]
			local wontDelete = ((u8(base + F_FLAGS1) or 0) & FLAG1_WONT_DELETE) ~= 0
			if sprite == playerSprite and wontDelete and s.stillFrames > HOLD_SECONDS * 60 then
				local mo = u8(base + F_MAP_OBJECT_INDEX)
				log(string.format("  clearing struct %d (map object %s), sprite %d, sat at %d,%d "
					.. "for %ds without moving -- nothing was driving it.",
					st, tostring(mo), sprite, x, y, s.stillFrames // 60))

				-- The same two writes the adapter's own despawn does, in the same order: blank the
				-- struct's sprite so the engine stops drawing it, then zero the map object so
				-- nothing re-adopts the slot.
				w8(base + F_SPRITE, 0)
				if mo and mo ~= UNASSIGNED and mo < NUM_MAP_OBJECTS then
					local moBase = MAP_OBJECTS + mo * MAPOBJECT_LENGTH
					if u8(moBase + M_STRUCT_ID) == st then
						for off = 0, MAPOBJECT_LENGTH - 1 do
							w8(moBase + off, 0)
						end
					else
						log("    (its map object no longer points back at it, so that was left "
							.. "alone -- it belongs to the game now.)")
					end
				end

				-- Read back rather than trusting the write: the sprite byte is what decides whether
				-- the engine draws anything at all.
				log(string.format("    read back: struct %d sprite is now %s", st,
					tostring(u8(base + F_SPRITE))))
				cleared = cleared + 1
				seen[st] = nil
			end
		end
	end

	if frames % 600 == 0 and cleared == 0 then
		log(string.format("  [%ds] nothing to clear.", frames // 60))
	end
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
	log(string.format("  --- stopping. Cleared %d leftover character%s this session. ---",
		cleared, (cleared == 1) and "" or "s"))
	if logfile then
		pcall(function() logfile:flush() end)
		logfile:close()
		logfile = nil
	end
end

-- A registered callback outlives its script under BizHawk, which is why this is a loop and not
-- event.onframeend (pitfalls.md).
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
