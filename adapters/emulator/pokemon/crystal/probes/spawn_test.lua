-- Pokémon Crystal: the first spawn test. Can an object put into a free slot be drawn by the game's own engine?
-- It copies the player's own struct (slot 0, a known-good object) into slot 1, two tiles to the right, so a failure
-- is the approach rather than field values. Writes object-struct RAM only, never a save; vanilla V1.0 only, since a
-- patched build moves WRAM. Stand in the overworld and open it in the Lua Console; stopping it clears the slot.

local DOMAIN = "WRAM"
local ROM_DOMAIN = "ROM"

local function flat(cpu_addr)
	return 0x1000 + (cpu_addr - 0xD000)
end

local OBJECT_STRUCTS = flat(0xD4D6)
local OBJECT_LENGTH = 0x28
local SRC_SLOT = 0 -- the player
local DST_SLOT = 1 -- first non-player slot
local TILE_OFFSET_X = 2 -- beside the player, never on top of them

local F_SPRITE = 0x00
local F_MAP_X, F_MAP_Y = 0x10, 0x11
local F_LAST_MAP_X, F_LAST_MAP_Y = 0x12, 0x13
local F_INIT_X, F_INIT_Y = 0x14, 0x15
local F_SPRITE_X, F_SPRITE_Y = 0x17, 0x18

local SPAWN_AFTER_FRAMES = 120 -- let the map settle before touching anything

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	local f = io.open(string.format("%s/spawn_test_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	logfile = f
end

-- The console gets the first lines and one in twenty; the file gets every line.
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
		-- Flushed every 20 lines: bounded cost, and a live log (an unflushed one reads as nothing happened).
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
	local ok = pcall(memory.write_u8, addr, value, DOMAIN)
	return ok
end

-- Refuses unless this is the exact ROM the addresses come from: title PM_CRYSTAL, global checksum 0x129F.
local function rom_is_vanilla_v1()
	local title = {}
	for i = 0, 9 do
		local c = u8(0x134 + i, ROM_DOMAIN)
		if not c then
			return false, "could not read the ROM domain at all"
		end
		title[#title + 1] = string.char(c)
	end
	local got = table.concat(title)
	if got ~= "PM_CRYSTAL" then
		return false, string.format("ROM title is %q, expected \"PM_CRYSTAL\"", got)
	end
	local hi, lo = u8(0x14E, ROM_DOMAIN), u8(0x14F, ROM_DOMAIN)
	if hi ~= 0x12 or lo ~= 0x9F then
		return false, string.format(
			"global checksum is %02X%02X, expected 129F (vanilla V1.0). A patched or "
				.. "different-revision ROM moves WRAM -- writing would corrupt it.",
			hi or 0, lo or 0
		)
	end
	return true, "vanilla Crystal V1.0"
end

open_log()
log("=== MeshGhost Crystal spawn test (WRITES RAM) ===")

local ok, why = rom_is_vanilla_v1()
if not ok then
	log("REFUSING TO WRITE: " .. why)
	log("This is the ADR's required guard, not a bug. Nothing was written.")
	return
end
log("ROM guard passed: " .. why)
log(string.format("Will copy slot %d -> slot %d, offset +%d tiles in x.", SRC_SLOT, DST_SLOT, TILE_OFFSET_X))

local src = OBJECT_STRUCTS + (SRC_SLOT * OBJECT_LENGTH)
local dst = OBJECT_STRUCTS + (DST_SLOT * OBJECT_LENGTH)

local frames = 0
local spawned = false
local spawned_at = 0

local function clear_slot()
	-- A zero sprite byte is what this probe treats as unused; the struct is transient RAM regardless.
	w8(dst + F_SPRITE, 0)
end

local function tick()
	frames = frames + 1

	if not spawned then
		if frames < SPAWN_AFTER_FRAMES then
			return
		end

		local occupant = u8(dst + F_SPRITE)
		if occupant == nil then
			log("Could not read the destination slot; not writing.")
			spawned = true
			return
		end
		if occupant ~= 0 then
			-- Refuse rather than clobber an NPC the map placed: overwriting the game's own object is not creating one.
			log(string.format(
				"Slot %d is already in use (sprite=%d). Not writing -- move somewhere quieter.",
				DST_SLOT, occupant
			))
			spawned = true
			return
		end

		for off = 0, OBJECT_LENGTH - 1 do
			w8(dst + off, u8(src + off) or 0)
		end

		-- F_LAST_* and F_INIT_* match, so the engine does not think it is mid-step from somewhere else.
		local px, py = u8(src + F_MAP_X) or 0, u8(src + F_MAP_Y) or 0
		local gx = px + TILE_OFFSET_X
		w8(dst + F_MAP_X, gx)
		w8(dst + F_MAP_Y, py)
		w8(dst + F_LAST_MAP_X, gx)
		w8(dst + F_LAST_MAP_Y, py)
		w8(dst + F_INIT_X, gx)
		w8(dst + F_INIT_Y, py)

		spawned = true
		spawned_at = frames
		log(string.format("Wrote slot %d at frame %d (player at %d,%d -> ghost at %d,%d).",
			DST_SLOT, frames, px, py, gx, py))
		log("LOOK AT THE SCREEN: is there a second character beside you?")
		return
	end

	-- Verified by OBJECT_SPRITE_X/Y, which the engine maintains, never by reading back our write: if they change
	-- on their own, the game is driving the object.
	local n = frames - spawned_at
	if n == 1 or n == 30 or n == 120 then
		log(string.format(
			"  +%3d frames: engine-maintained sprite_x=%s sprite_y=%s (moving = the game owns it)",
			n, tostring(u8(dst + F_SPRITE_X)), tostring(u8(dst + F_SPRITE_Y))
		))
	end
end

-- Registered before the loop, which never returns. Wrapped whole: an error in onexit can wedge the Lua Console, and
-- memory domains may be invalid during teardown.
event.onexit(function()
	pcall(clear_slot)
end)

while true do
	tick()
	emu.frameadvance()
end
