-- Writes the game: clears characters this adapter left behind, the same bytes its despawn clears. Only one that is
-- not the player, wears the local player's sprite id, has WONT_DELETE set and has stood on one tile without
-- animating for HOLD_SECONDS, past the adapter's idle rule; a ghost still tracked resets that timer each time its
-- peer moves, so it is never a candidate. Logs every sweep; remove it from the target when finished.

local DOMAIN = "WRAM"
local HOLD_SECONDS = 75 -- must stay above the adapter's 3600-frame idle rule, or this deletes live ghosts

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
	-- Buffered, never flushed per line: a flush is a synchronous disk write on the emulator's own thread.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- The console is a GUI append on the emulator's thread, so it gets the first lines and one in twenty; the file all.
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
		-- Flush every 20 lines: a bounded cost, and a log that is never empty for a whole run.
		flushEvery = (flushEvery or 0) + 1
		if flushEvery >= 20 then
			flushEvery = 0
			pcall(function() logfile:flush() end)
		end
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

				-- The adapter's own despawn writes, in its order: blank the sprite, then zero the map object so nothing
				-- re-adopts the slot.
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

				-- Read back: the sprite byte decides whether the engine draws anything.
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

-- Standalone, its own loop: a registered callback outlives its script under BizHawk.
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
