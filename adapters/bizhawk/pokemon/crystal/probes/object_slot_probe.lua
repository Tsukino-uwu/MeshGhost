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

-- Spawn watch. The single most valuable thing this probe can capture is the moment the game
-- populates an object slot itself -- loading a save runs Crystal's own SpawnPlayer, which is the
-- exact routine the adapter intends to reuse. So rather than sample at 6Hz and blur it, check
-- occupancy EVERY frame (13 single-byte reads, cheap) and, the frame a slot goes from empty to
-- occupied, dump the whole struct.
--
-- That dump is the deliverable: it is ground truth for what a correctly-spawned object looks
-- like. If the engine routine can be called, it is what to verify against; if it has to be
-- imitated, it is what to imitate. See the ADR's call-vs-imitate question.
local occupied = {}
local pending = {} -- follow-up dumps, so a settling struct is visible rather than guessed at
local spawn_frame = {}

local function dump_struct(i, why)
	local base = OBJECT_STRUCTS + (i * OBJECT_LENGTH)
	local bytes = {}
	for off = 0, OBJECT_LENGTH - 1 do
		bytes[#bytes + 1] = string.format("%02X", u8(base + off) or 0)
	end
	log(string.format("*** %s: slot %d at frame %d ***", why, i, frames))
	-- Raw first, so nothing depends on my field offsets being right.
	log("    raw: " .. table.concat(bytes, " "))
	local s = slot(i)
	log(string.format(
		"    sprite=%d mapobj=%d pal=%d dir=%d x=%d y=%d",
		s.sprite or -1, s.map_object or -1, s.palette or -1,
		s.direction or -1, s.x or -1, s.y or -1
	))
end

local function tick()
	frames = frames + 1

	-- Every frame: has any slot just been populated or cleared?
	for i = 0, NUM_OBJECT_STRUCTS - 1 do
		local sprite = u8(OBJECT_STRUCTS + (i * OBJECT_LENGTH) + F_SPRITE)
		local now = (sprite ~= nil and sprite ~= 0)
		if now ~= (occupied[i] or false) then
			if now then
				-- The first frame a slot is non-zero is DURING initialisation, not after it.
				-- Two runs on 2026-08-17 produced different bytes for the same event, because
				-- they caught different sub-steps. So schedule follow-up dumps and let the log
				-- show when the struct stops changing, rather than trusting the first sight of
				-- it. The settled dump is the one that describes a real object.
				spawn_frame[i] = frames
				dump_struct(i, "SPAWNED (first frame, still initialising)")
				pending[#pending + 1] = { slot = i, at = frames + 1 }
				pending[#pending + 1] = { slot = i, at = frames + 4 }
				pending[#pending + 1] = { slot = i, at = frames + 16 }
				pending[#pending + 1] = { slot = i, at = frames + 64 }
			else
				log(string.format("*** CLEARED: slot %d at frame %d ***", i, frames))
			end
			occupied[i] = now
		end
	end

	for n = #pending, 1, -1 do
		if frames >= pending[n].at then
			dump_struct(pending[n].slot, string.format("+%d frames", frames - spawn_frame[pending[n].slot]))
			table.remove(pending, n)
		end
	end

	if frames % 10 ~= 0 then -- the summary view below stays at 6Hz; the watch above is per-frame
		return
	end

	local group, number = u8(MAP_GROUP), u8(MAP_GROUP + 1)
	local marks, used = occupancy()
	local map_key = string.format("%d/%d", group or -1, number or -1)
	local key = map_key .. " " .. marks

	-- Heartbeat. Without this, a run in a quiet map (the player's bedroom has no NPCs at all)
	-- produces one line and looks like a broken probe rather than an empty room. Found live
	-- 2026-08-17 on this probe's first run.
	if frames % 300 == 0 and key == last_key then
		local p = slot(0)
		log(string.format(
			"  [alive] map=%s slots [%s] %d used   player x=%d y=%d",
			map_key, marks, used, p.x or -1, p.y or -1
		))
	end

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
end

while true do
	tick()
	emu.frameadvance()
end
