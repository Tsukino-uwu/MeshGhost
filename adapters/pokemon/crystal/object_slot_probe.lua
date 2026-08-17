-- MeshGhost — Pokémon Crystal: object-slot probe
--
-- READ-ONLY DIAGNOSTIC. Writes nothing, sends nothing, draws nothing.
-- This probe deliberately performs NO memory writes. Spawning a real object event requires
-- writes, which agent_docs/plans.md gates behind an Archipelago-coexistence test and an ADR in
-- agent_docs/architecture.md. This is the evidence-gathering step that must come first.
--
-- WHY THIS EXISTS
-- The plan for Crystal is to spawn a peer as a real in-game object event rather than draw an
-- overlay, so the game's own renderer handles palettes, occlusion and animation -- see the ADR.
-- Before anything can be spawned, three things have to be observed rather than assumed:
--
--   1. Which object slots are actually free during normal play. There are 13
--      (NUM_OBJECT_STRUCTS), the player is slot 0, but how many the game itself uses at once --
--      NPCs, followers -- is a property of the map, not a constant.
--   2. Whether a slot stays free, or gets reclaimed as NPCs come and go.
--   3. What happens across a map transition. Object state is per-map, so a spawned ghost almost
--      certainly needs re-spawning on every load -- this confirms it and shows the timing.
--
-- ADDRESSES, all from our own hash-verified pokecrystal build (agent_docs/verified.md):
--   wObjectStructs   01:d4d6, 13 entries of OBJECT_LENGTH (0x28) bytes
--   wMapGroup        01:dcb5   wMapNumber 01:dcb6
-- Field offsets from pokecrystal's constants/map_object_constants.asm.
--
-- HOW TO RUN
--   1. Open BizHawk, load the Crystal ROM, be in the overworld.
--   2. Lua Console -> Script -> Open, pick this file.
--   3. Walk around, enter and leave a building, and pass some NPCs.
--      Output also goes to object_slot_probe_<timestamp>.log beside this script.

local DOMAIN = "WRAM" -- preferred over "System Bus": addresses bank 1 unconditionally,
-- rather than following whatever bank is currently selected.
-- Confirmed 2026-08-17 that both expose the same bytes; see verified.md.

local function flat(cpu_addr) -- CPU 0xD000-0xDFFF -> flat WRAM offset for bank 1
	return 0x1000 + (cpu_addr - 0xD000)
end

local OBJECT_STRUCTS = flat(0xD4D6)
local MAP_GROUP = flat(0xDCB5)
local OBJECT_LENGTH = 0x28
local NUM_OBJECT_STRUCTS = 13

-- Field offsets within one object struct (constants/map_object_constants.asm).
local F_SPRITE = 0x00
local F_MAP_OBJECT_INDEX = 0x01
local F_PALETTE = 0x06
local F_DIRECTION = 0x08
local F_MAP_X = 0x10
local F_MAP_Y = 0x11

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	local path = string.format("%s/object_slot_probe_%s.log", dir, os.date("%Y%m%d_%H%M%S"))
	local f = io.open(path, "w")
	if f then
		logfile = f
		return path
	end
	return nil
end

local raw_log = console.log
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
	end
end

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

local function slot(i)
	local base = OBJECT_STRUCTS + (i * OBJECT_LENGTH)
	return {
		sprite = u8(base + F_SPRITE),
		map_object = u8(base + F_MAP_OBJECT_INDEX),
		palette = u8(base + F_PALETTE),
		direction = u8(base + F_DIRECTION),
		x = u8(base + F_MAP_X),
		y = u8(base + F_MAP_Y),
	}
end

-- A slot with sprite 0 is unused. This is the one inference in the probe, so it is reported
-- rather than relied on: the full occupancy string is printed every time, so a wrong reading of
-- "free" is visible in the log instead of hidden behind a count.
local function occupancy()
	local marks, used = {}, 0
	for i = 0, NUM_OBJECT_STRUCTS - 1 do
		local s = slot(i)
		if s.sprite and s.sprite ~= 0 then
			marks[#marks + 1] = "X"
			used = used + 1
		else
			marks[#marks + 1] = "."
		end
	end
	return table.concat(marks), used
end

local log_path = open_log()
log("=== MeshGhost Crystal object-slot probe (READ-ONLY) ===")
if log_path then
	log("Logging to " .. log_path)
end
log(string.format(
	"%d slots of %d bytes at flat 0x%04X (01:d4d6). Slot 0 is the player.",
	NUM_OBJECT_STRUCTS, OBJECT_LENGTH, OBJECT_STRUCTS
))
log("Walk around, pass NPCs, and enter/leave a building.")

local last_key = nil
local last_map = nil
local frames = 0

event.onframeend(function()
	frames = frames + 1
	if frames % 10 ~= 0 then -- 6Hz is plenty, and keeps this off the critical path
		return
	end

	local group, number = u8(MAP_GROUP), u8(MAP_GROUP + 1)
	local marks, used = occupancy()
	local map_key = string.format("%d/%d", group or -1, number or -1)
	local key = map_key .. " " .. marks

	if key ~= last_key then
		if map_key ~= last_map then
			log(string.format("--- map changed -> group=%s ---", map_key))
			last_map = map_key
		end
		log(string.format("slots [%s]  %d used, %d free", marks, used, NUM_OBJECT_STRUCTS - used))
		for i = 0, NUM_OBJECT_STRUCTS - 1 do
			local s = slot(i)
			if s.sprite and s.sprite ~= 0 then
				log(string.format(
					"  slot %2d: sprite=%3d mapobj=%3d pal=%3d dir=%d x=%3d y=%3d%s",
					i, s.sprite, s.map_object or -1, s.palette or -1,
					s.direction or -1, s.x or -1, s.y or -1,
					(i == 0) and "   <- player" or ""
				))
			end
		end
		last_key = key
	end
end)
