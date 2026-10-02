-- Pokémon Crystal: grants all 16 badges, one of each HM and the field moves (a party Pokémon must know the move:
-- Surf, Fly, Strength and Waterfall to slot 1, Whirlpool, Cut and Flash to slot 2), once, so a test session can reach
-- water, ledges, dark caves and the sky. Vanilla V1.0 only. Writes WRAM, never the .sav or a savestate: an in-game
-- save afterwards makes it permanent, so savestate first and load it after.

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- Addresses from our build's .sym.
local W_JOHTO_BADGES = flat(0xD857) -- wJohtoBadges
local W_KANTO_BADGES = flat(0xD858) -- wKantoBadges
local W_TMSHMS = flat(0xD859) -- wTMsHMs
local W_PARTY_COUNT = flat(0xDCD7) -- wPartyCount
local W_PARTY_MON1 = flat(0xDCDF) -- wPartyMon1
local W_MAPSTATUS = flat(0xD432) -- wMapStatus, the same address the adapter uses
local W_MAPGROUP = flat(0xDCB5) -- wMapGroup, as used by the adapter

-- Checked against the .sym: wPartyMon2 - wPartyMon1 = 0x30, wPartyMon1PP - wPartyMon1 = 0x17.
local PARTYMON_STRUCT_LENGTH = 0x30
local MON_MOVES = 0x02
local MON_PP = 0x17

-- One count byte per TM, then per HM: wNumItems - wTMsHMs is 57 bytes, and 7 HMs leave 50 TMs.
local NUM_TMS = 50
local NUM_HMS = 7

-- constants/move_constants.asm, counted from const_def.
local MOVE = {
	CUT = 15, FLY = 19, SURF = 57, STRENGTH = 70, WATERFALL = 127, FLASH = 148, WHIRLPOOL = 250,
}

-- Four move slots and seven HMs: slot 1 gets the ones that open up the map.
local LOADOUT = {
	{ "SURF", "FLY", "STRENGTH", "WATERFALL" },
	{ "WHIRLPOOL", "CUT", "FLASH" },
}

-- PP is the low 6 bits (PP-Ups the top 2). 15 is at or above the field moves' maximum: an empty one fails a test.
local PP_VALUE = 15

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/grant_test_kit_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, never flushed per line: a console line plus a flush stalls the emulator's thread for frames.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
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

-- Asked of the cartridge header, not RAM: RAM is exactly what would be wrong on another build.
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
	-- Badges: two bitfields of eight.
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

	-- Read back from the game's memory, not echoed from the locals: an echo proves only that the code ran.
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

-- A registered callback outlives its script under BizHawk, hence a loop rather than event.onframeend.
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
