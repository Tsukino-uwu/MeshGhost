-- MeshGhost — Pokémon Crystal: grant the badges, the HMs and the field moves needed to test
--
-- DEVELOPMENT TOOL. **THIS ONE CHEATS, DELIBERATELY, AND IT IS ALLOWED TO.** CLAUDE.md's rule is
-- that nothing which SHIPS may write a save, a game state or a ROM -- and that dev-only test
-- tooling MAY cheat, as a PROBE, never as an adapter. This is that probe. It is not loaded by the
-- adapter, is not packaged in a release, and exists so a test session can reach water, ledges,
-- dark caves and the sky without first playing through the game.
--
-- ** READ THIS BEFORE RUNNING IT **
-- It writes into the player's party and inventory in WRAM. That is not the same as writing the
-- save file -- but **if you SAVE in-game afterwards, these changes become permanent in that save**.
-- The safe way to use it: make a savestate first (savestates are not in-game saves), run this, do
-- the testing, and load the savestate afterwards. It never touches the .sav file itself, and it
-- never writes a savestate.
--
-- WHAT IT DOES, once, and then it goes quiet:
--   * all 16 badges (8 Johto + 8 Kanto)
--   * one of every HM in the TM/HM pocket
--   * the field moves put onto your party Pokemon, because in this game a badge and the HM in the
--     bag are NOT enough -- a party Pokemon has to KNOW the move. Party slot 1 gets the four that
--     matter for getting around (SURF, FLY, STRENGTH, WATERFALL); slot 2, if you have one, gets
--     the rest (WHIRLPOOL, CUT, FLASH).
--
-- It does NOT give items, money, Pokemon, or anything else -- narrow on purpose, so what it
-- changed is always obvious.
--
-- HOW TO RUN
--   Load it beside the adapter (dev-scripts/bizhawk-dev-loader.lua takes several targets), or on
--   its own from the Lua Console. It waits until you are actually in the overworld, applies
--   everything once, prints what it wrote AS READ BACK FROM MEMORY, and then does nothing further.
--   Log: grant_test_kit_<timestamp>.log beside this file.
--
-- WHERE THE NUMBERS COME FROM
-- Every address is from our own hash-verified pokecrystal build's pokecrystal.sym, and every
-- layout fact from constants/pokemon_data_constants.asm and constants/item_constants.asm. The
-- arithmetic that is not a bare symbol is shown at its definition below so it can be checked.
-- VANILLA V1.0 ONLY -- it refuses on anything else rather than writing a patched build's RAM at
-- vanilla's addresses.

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- pokecrystal.sym
local W_JOHTO_BADGES = flat(0xD857) -- wJohtoBadges
local W_KANTO_BADGES = flat(0xD858) -- wKantoBadges
local W_TMSHMS = flat(0xD859) -- wTMsHMs
local W_PARTY_COUNT = flat(0xDCD7) -- wPartyCount
local W_PARTY_MON1 = flat(0xDCDF) -- wPartyMon1
local W_MAPSTATUS = flat(0xD432) -- wMapStatus, the same address the adapter uses
local W_MAPGROUP = flat(0xDCB5) -- wMapGroup, as used by the adapter

-- constants/pokemon_data_constants.asm, party_struct. Each is confirmed against pokecrystal.sym
-- rather than trusted from the macro: wPartyMon2 - wPartyMon1 = 0xDD0F - 0xDCDF = 0x30, and
-- wPartyMon1PP - wPartyMon1 = 0xDCF6 - 0xDCDF = 0x17.
local PARTYMON_STRUCT_LENGTH = 0x30
local MON_MOVES = 0x02
local MON_PP = 0x17

-- constants/item_constants.asm. wTMsHMs is one count byte per TM then per HM, and the HMs start
-- after the TMs. NUM_TMS is not a literal in the source (it is computed by a macro), so it is
-- derived from the symbol table instead: wNumItems - wTMsHMs = 0xD892 - 0xD859 = 0x39 = 57 bytes
-- for NUM_TMS + NUM_HMS, and NUM_HMS is 7 (the add_hm list) -- so NUM_TMS is 50.
local NUM_TMS = 50
local NUM_HMS = 7

-- constants/move_constants.asm, counted from const_def.
local MOVE = {
	CUT = 15, FLY = 19, SURF = 57, STRENGTH = 70, WATERFALL = 127, FLASH = 148, WHIRLPOOL = 250,
}

-- Four slots per Pokemon and seven HMs, so they have to be split. Slot 1 gets the ones that open
-- up the map; slot 2 gets the rest.
local LOADOUT = {
	{ "SURF", "FLY", "STRENGTH", "WATERFALL" },
	{ "WHIRLPOOL", "CUT", "FLASH" },
}

-- The PP byte is current PP in the low 6 bits and PP-Up count in the top 2
-- (constants/pokemon_data_constants.asm). 15 is at or above the field moves' real maximum, and a
-- field move that cannot be used because it is out of PP is a confusing way to fail a test.
local PP_VALUE = 15

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/grant_test_kit_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
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

-- Vanilla only, and asked of the cartridge header rather than of RAM, because RAM is exactly what
-- would be wrong on a build these addresses do not describe.
local function romTitle()
	local out = {}
	for i = 0x134, 0x142 do
		local ok, b = pcall(memory.read_u8, i, "ROM")
		if not ok or b == nil or b == 0 then
			break
		end
		out[#out + 1] = string.char(b)
	end
	return table.concat(out)
end

local function inOverworld()
	local status = u8(W_MAPSTATUS)
	local group = u8(W_MAPGROUP)
	local count = u8(W_PARTY_COUNT)
	return status == 2 and group ~= nil and group ~= 0 and count ~= nil and count > 0
end

open_log()
log("=== MeshGhost Crystal test kit (THIS ONE WRITES TO THE GAME) ===")
log("Badges, HMs and field moves. It does NOT write your .sav -- but saving in-game afterwards")
log("would make these permanent. Make a savestate first if you care about this file.")

local title = romTitle()
local applied = false
local waited = 0

local function apply()
	-- Badges: two bitfields of 8 (pokecrystal.sym; wJohtoBadges, wKantoBadges).
	w8(W_JOHTO_BADGES, 0xFF)
	w8(W_KANTO_BADGES, 0xFF)

	-- One of each HM in the pocket.
	for n = 1, NUM_HMS do
		w8(W_TMSHMS + NUM_TMS + (n - 1), 1)
	end

	local partyCount = u8(W_PARTY_COUNT) or 0
	local taught = {}
	for slot = 1, math.min(#LOADOUT, partyCount) do
		local base = W_PARTY_MON1 + (slot - 1) * PARTYMON_STRUCT_LENGTH
		local moves = LOADOUT[slot]
		for i = 1, #moves do
			w8(base + MON_MOVES + (i - 1), MOVE[moves[i]])
			w8(base + MON_PP + (i - 1), PP_VALUE)
		end
		taught[#taught + 1] = string.format("party %d: %s", slot, table.concat(moves, ", "))
	end

	-- READ BACK, and read back something we did not just hand ourselves: the values are re-read
	-- out of the game's memory rather than echoed from the locals above, because a log line that
	-- repeats what was written proves only that the code ran (CLAUDE.md).
	log("")
	log("Applied. Read back from the game's own memory:")
	log(string.format("  badges: johto 0x%02X, kanto 0x%02X (0xFF each means all eight)",
		u8(W_JOHTO_BADGES) or 0, u8(W_KANTO_BADGES) or 0))
	local counts = {}
	for n = 1, NUM_HMS do
		counts[#counts + 1] = tostring(u8(W_TMSHMS + NUM_TMS + (n - 1)) or 0)
	end
	log(string.format("  HM01-HM%02d in the pocket: %s", NUM_HMS, table.concat(counts, " ")))
	if partyCount == 0 then
		log("  party is EMPTY, so no field moves were taught. Catch something and re-run this.")
	end
	for slot = 1, math.min(#LOADOUT, partyCount) do
		local base = W_PARTY_MON1 + (slot - 1) * PARTYMON_STRUCT_LENGTH
		local ids, pps = {}, {}
		for i = 0, 3 do
			ids[#ids + 1] = tostring(u8(base + MON_MOVES + i) or 0)
			pps[#pps + 1] = tostring(u8(base + MON_PP + i) or 0)
		end
		log(string.format("  party %d move ids: %s   PP: %s", slot,
			table.concat(ids, " "), table.concat(pps, " ")))
	end
	log("")
	log("  " .. table.concat(taught, "  |  "))
	log("  Open the party menu to confirm on screen -- these are memory reads, not a screenshot.")
	log("  Fly needs a town you have already visited; the rest work immediately.")
	log("Done. This probe will not write anything else.")
end

local function tick()
	if applied then
		return
	end
	if not title:find("PM_CRYSTAL", 1, true) then
		log(string.format("REFUSING: cartridge header says \"%s\", and every address here is from "
			.. "the vanilla V1.0 build. Writing them into another build's RAM would corrupt "
			.. "whatever lives there instead.", title))
		applied = true -- refuse once, then stay quiet
		return
	end
	if not inOverworld() then
		waited = waited + 1
		if waited % 180 == 0 then
			log("  waiting: load your save and step into the overworld (this needs a party too).")
		end
		return
	end
	applied = true
	apply()
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
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
