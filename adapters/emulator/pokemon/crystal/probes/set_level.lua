-- MeshGhost — Pokémon Crystal: set a party Pokémon's level, properly
--
-- DEVELOPMENT TOOL. **THIS ONE CHEATS, DELIBERATELY, AND IT IS ALLOWED TO** -- CLAUDE.md allows a
-- dev-only PROBE to cheat, never an adapter. Sibling of grant_test_kit.lua (badges/HMs/moves) and
-- grant_items.lua (bag). This one is levels.
--
-- ** WHY THIS IS NOT A ONE-BYTE WRITE **
-- Writing MON_LEVEL alone gives a Pokémon that DISPLAYS level 99 and still has its old stats and
-- its old experience -- and the next experience it earns recalculates the level from that stale
-- EXP and drops it back. Three things have to agree: the level byte, the experience, and the six
-- stored stats. So this writes all three, using the GAME'S OWN arithmetic and the GAME'S OWN data.
--
-- ** NOTHING HERE IS A HARDCODED STAT TABLE. ** The species' base stats are read out of the
-- cartridge at run time, so this works for whatever is in the slot rather than for a list somebody
-- typed in. That is the same principle the adapter follows for the fishing rod.
--
-- ** READ THIS BEFORE RUNNING IT **
-- It writes WRAM, not the save file -- but **if you SAVE in-game afterwards it is permanent**.
-- Savestate first, test, load the savestate after.
--
-- WHERE THE NUMBERS COME FROM -- every one traceable, none from memory:
--   * `pokecrystal.sym`: `01:dcd7 wPartyCount`, `01:dcdf wPartyMon1`, `14:5424 BaseData`.
--   * Party struct offsets: `constants/pokemon_data_constants.asm` party_struct members --
--     MON_SPECIES 0, MON_EXP 8 (3 bytes), MON_STAT_EXP 11 (5 x 2), MON_DVS 21 (2),
--     MON_LEVEL 31, MON_HP 34, MON_MAXHP 36, MON_STATS 38, struct length 48.
--   * Base data offsets: same file -- BASE_HP 1, ATK 2, DEF 3, SPD 4, SAT 5, SDF 6,
--     BASE_GROWTH_RATE **22**. Count the `rs` directives; do not eyeball it. The first version of
--     this file said 27, read a growth rate of 204, and REFUSED to write -- which is the guard
--     below doing its job. Verified against `data/pokemon/base_stats/cyndaquil.asm`, where the
--     bytes count out as dex(0) stats(1-6) types(7-8) catch(9) exp(10) items(11-12) gender(13)
--     unknown(14) hatch(15) unknown(16) picsize(17) two dw NULL(18-21) growth(22).
--   * **Base-data entry stride: 32 bytes, VERIFIED AGAINST THE ROM rather than derived** --
--     BASE_DATA_SIZE is macro-computed from NUM_TMS/NUM_HMS and cannot simply be read. The check
--     is self-evident and this file re-runs it: the first byte of each entry is the dex number, so
--     the correct stride makes consecutive entries read 1, 2, 3, ... It refuses to write if that
--     does not hold, rather than trusting a constant that was true once.
--   * Stat formula: `engine/pokemon/move_mon.asm`, CalcMonStatC --
--     stat = ((base + DV) * 2 + floor(sqrt(statexp)) / 4) * level / 100, then + 5, and for HP
--     + level + 10 instead (STAT_MIN_NORMAL 5, STAT_MIN_HP 10, capped at MAX_STAT_VALUE 999 --
--     `constants/battle_constants.asm`).
--   * HP DV is not stored: `DV_HP = (DV_ATK & 1) << 3 | (DV_DEF & 1) << 2 | (DV_SPD & 1) << 1 |
--     (DV_SPC & 1)`, quoted from the same routine.
--   * EXP formula: `engine/pokemon/experience.asm`, CalcExpAtLevel -- (a/b)*n^3 + c*n^2 + d*n - e,
--     with the per-rate coefficients from `data/growth_rates.asm`.
--
-- VANILLA V1.0 ONLY.
--
-- HOW TO RUN
--   Set MESHGHOST_LEVEL (default 99) and MESHGHOST_LEVEL_SLOT (default 1) as globals before
--   loading, or edit the defaults. Add it to dev-scripts/bizhawk-dev-loader-crystal.target. It
--   waits for the overworld, writes once, reports everything AS READ BACK FROM MEMORY, stops.
--   Log: set_level_<timestamp>.log beside this file.

local DOMAIN = "WRAM"
local WANT_LEVEL = tonumber(MESHGHOST_LEVEL) or 99
local WANT_SLOT = tonumber(MESHGHOST_LEVEL_SLOT) or 1

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- pokecrystal.sym
local W_PARTY_COUNT, W_PARTY_MON1 = flat(0xDCD7), flat(0xDCDF)
local W_MAPSTATUS, W_MAPGROUP = flat(0xD432), flat(0xDCB5)

-- BaseData is 14:5424. A banked ROM address is bank * 0x4000 + (addr - 0x4000) in the flat
-- address space BizHawk exposes as the "ROM" domain.
local BASE_DATA = 0x14 * 0x4000 + (0x5424 - 0x4000)
local BASE_STRIDE = 32 -- asserted below against the dex numbers, never assumed

-- constants/pokemon_data_constants.asm
local MON_SPECIES, MON_EXP, MON_STAT_EXP, MON_DVS = 0, 8, 11, 21
local MON_LEVEL, MON_HP, MON_MAXHP, MON_STATS = 31, 34, 36, 38
local PARTYMON_STRUCT_LENGTH = 48
local BASE_HP, BASE_GROWTH_RATE = 1, 22

-- constants/battle_constants.asm
local STAT_MIN_NORMAL, STAT_MIN_HP, MAX_STAT_VALUE = 5, 10, 999

-- data/growth_rates.asm -- {a, b, c, d, e} for (a/b)*n^3 + c*n^2 + d*n - e
local GROWTH_RATES = {
	[0] = { 1, 1, 0, 0, 0 },     -- Medium Fast
	[1] = { 3, 4, 10, 0, 30 },   -- Slightly Fast
	[2] = { 3, 4, 20, 0, 70 },   -- Slightly Slow
	[3] = { 6, 5, -15, 100, 140 }, -- Medium Slow
	[4] = { 4, 5, 0, 0, 0 },     -- Fast
	[5] = { 5, 4, 0, 0, 0 },     -- Slow
}

local function u8(a) return memory.read_u8(a, DOMAIN) end
local function w8(a, v) memory.write_u8(a, v, DOMAIN) end
local function rom8(a) return memory.read_u8(a, "ROM") end

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/set_level_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
end

-- Flushed per line: this writes a dozen lines once and stops, so the cost is paid once and the log
-- is readable immediately. grant_test_kit.lua's batched flush left a 0-byte log on 2026-08-25,
-- which reads exactly like "the probe never ran".
local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		pcall(function() logfile:flush() end)
	end
end

local function isVanillaV10()
	local t = {}
	for i = 0, 9 do
		local c = rom8(0x134 + i)
		if not c then return false end
		t[#t + 1] = string.char(c)
	end
	return table.concat(t) == "PM_CRYSTAL" and rom8(0x14E) == 0x12 and rom8(0x14F) == 0x9F
end

local function inOverworld()
	local status, group = u8(W_MAPSTATUS), u8(W_MAPGROUP)
	return status == 2 and group ~= nil and group ~= 0
end

-- THE STRIDE CHECK. Consecutive base-data entries begin with consecutive dex numbers, so this is
-- the assumption testing itself against the cartridge on every run.
local function strideHolds()
	for i = 0, 7 do
		if rom8(BASE_DATA + i * BASE_STRIDE) ~= i + 1 then return false end
	end
	return true
end

local function isqrt(n)
	if n <= 0 then return 0 end
	local r = math.floor(math.sqrt(n))
	while (r + 1) * (r + 1) <= n do r = r + 1 end
	while r * r > n do r = r - 1 end
	return r
end

-- engine/pokemon/experience.asm, CalcExpAtLevel. The asm cubes the level, multiplies by a and
-- divides by b with integer division, then adds the quadratic and linear terms.
local function expAtLevel(rate, n)
	local g = GROWTH_RATES[rate]
	if not g then return nil end
	local a, b, c, d, e = g[1], g[2], g[3], g[4], g[5]
	local v = math.floor(n * n * n * a / b) + c * n * n + d * n - e
	if v < 0 then v = 0 end
	if v > 0xFFFFFF then v = 0xFFFFFF end
	return math.floor(v)
end

-- engine/pokemon/move_mon.asm, CalcMonStatC.
local function calcStat(base, dv, statexp, level, isHP)
	local v = (base + dv) * 2 + math.floor(isqrt(statexp) / 4)
	v = math.floor(v * level / 100)
	if isHP then
		v = v + level + STAT_MIN_HP
	else
		v = v + STAT_MIN_NORMAL
	end
	if v > MAX_STAT_VALUE then v = MAX_STAT_VALUE end
	return v
end

open_log()
log(string.format("=== MeshGhost Crystal level setter (THIS ONE WRITES YOUR POKEMON) === "
	.. "slot %d to level %d", WANT_SLOT, WANT_LEVEL))

local applied, waited = false, 0

local function tick()
	if applied then return end
	if not isVanillaV10() then
		applied = true
		log("REFUSED: not vanilla Crystal V1.0; these addresses describe only that build.")
		return
	end
	if WANT_LEVEL < 1 or WANT_LEVEL > 100 then
		applied = true
		log("REFUSED: level must be 1-100.")
		return
	end
	if not inOverworld() then
		waited = waited + 1
		if waited % 300 == 0 then
			log(string.format("  waiting for the overworld (mapstatus=%s)", tostring(u8(W_MAPSTATUS))))
		end
		return
	end
	applied = true

	local count = u8(W_PARTY_COUNT) or 0
	if WANT_SLOT < 1 or WANT_SLOT > count then
		log(string.format("REFUSED: slot %d, but the party holds %d.", WANT_SLOT, count))
		return
	end
	if not strideHolds() then
		log("REFUSED: the base-data stride check failed -- the first eight entries do not read as "
			.. "dex numbers 1..8, so BaseData is not where or what this file thinks. Writing nothing.")
		return
	end

	local mon = W_PARTY_MON1 + (WANT_SLOT - 1) * PARTYMON_STRUCT_LENGTH
	local species = u8(mon + MON_SPECIES) or 0
	local entry = BASE_DATA + (species - 1) * BASE_STRIDE
	local rate = rom8(entry + BASE_GROWTH_RATE) or 0

	log(string.format("  BEFORE: species=%d level=%d exp=%d,%d,%d maxhp=%d",
		species, u8(mon + MON_LEVEL) or 0,
		u8(mon + MON_EXP) or 0, u8(mon + MON_EXP + 1) or 0, u8(mon + MON_EXP + 2) or 0,
		(u8(mon + MON_MAXHP) or 0) * 256 + (u8(mon + MON_MAXHP + 1) or 0)))

	-- DVs: two bytes, four nibbles. HP's DV is not stored -- it is assembled from the low bit of
	-- each of the other four (quoted at the top).
	local dv1, dv2 = u8(mon + MON_DVS) or 0, u8(mon + MON_DVS + 1) or 0
	local dvAtk, dvDef = (dv1 >> 4) & 0xF, dv1 & 0xF
	local dvSpd, dvSpc = (dv2 >> 4) & 0xF, dv2 & 0xF
	local dvHP = ((dvAtk & 1) << 3) | ((dvDef & 1) << 2) | ((dvSpd & 1) << 1) | (dvSpc & 1)

	local function statExp(i) -- i = 0..4 (HP, Atk, Def, Spd, Spc)
		return (u8(mon + MON_STAT_EXP + i * 2) or 0) * 256 + (u8(mon + MON_STAT_EXP + i * 2 + 1) or 0)
	end

	local baseHP = rom8(entry + BASE_HP) or 0
	local baseAtk, baseDef = rom8(entry + BASE_HP + 1) or 0, rom8(entry + BASE_HP + 2) or 0
	local baseSpd, baseSat = rom8(entry + BASE_HP + 3) or 0, rom8(entry + BASE_HP + 4) or 0
	local baseSdf = rom8(entry + BASE_HP + 5) or 0

	local hp = calcStat(baseHP, dvHP, statExp(0), WANT_LEVEL, true)
	local atk = calcStat(baseAtk, dvAtk, statExp(1), WANT_LEVEL, false)
	local def = calcStat(baseDef, dvDef, statExp(2), WANT_LEVEL, false)
	local spd = calcStat(baseSpd, dvSpd, statExp(3), WANT_LEVEL, false)
	-- Special Attack and Special Defence share ONE stat-exp entry and ONE DV in this generation.
	local sat = calcStat(baseSat, dvSpc, statExp(4), WANT_LEVEL, false)
	local sdf = calcStat(baseSdf, dvSpc, statExp(4), WANT_LEVEL, false)

	local exp = expAtLevel(rate, WANT_LEVEL)
	if not exp then
		log(string.format("REFUSED: growth rate %d is not one of the six in data/growth_rates.asm.", rate))
		return
	end

	local function w16(off, v)
		w8(mon + off, (v >> 8) & 0xFF)
		w8(mon + off + 1, v & 0xFF)
	end

	w8(mon + MON_LEVEL, WANT_LEVEL)
	w8(mon + MON_EXP, (exp >> 16) & 0xFF)
	w8(mon + MON_EXP + 1, (exp >> 8) & 0xFF)
	w8(mon + MON_EXP + 2, exp & 0xFF)
	w16(MON_MAXHP, hp)
	w16(MON_HP, hp) -- healed to the new maximum; a level-up in this game does the same
	w16(MON_STATS + 0, atk)
	w16(MON_STATS + 2, def)
	w16(MON_STATS + 4, spd)
	w16(MON_STATS + 6, sat)
	w16(MON_STATS + 8, sdf)

	log(string.format("  base stats from the cartridge: HP=%d Atk=%d Def=%d Spd=%d SAtk=%d SDef=%d "
		.. "(growth rate %d)", baseHP, baseAtk, baseDef, baseSpd, baseSat, baseSdf, rate))
	log(string.format("  DVs: HP=%d Atk=%d Def=%d Spd=%d Spc=%d", dvHP, dvAtk, dvDef, dvSpd, dvSpc))
	log(string.format("  computed: exp=%d hp=%d atk=%d def=%d spd=%d sat=%d sdf=%d",
		exp, hp, atk, def, spd, sat, sdf))

	-- READ BACK from memory, not from the locals just written.
	local function r16(off) return (u8(mon + off) or 0) * 256 + (u8(mon + off + 1) or 0) end
	log(string.format("  AFTER (read back): level=%d exp=%d hp=%d/%d atk=%d def=%d spd=%d sat=%d sdf=%d",
		u8(mon + MON_LEVEL) or 0,
		((u8(mon + MON_EXP) or 0) << 16) + ((u8(mon + MON_EXP + 1) or 0) << 8) + (u8(mon + MON_EXP + 2) or 0),
		r16(MON_HP), r16(MON_MAXHP), r16(MON_STATS + 0), r16(MON_STATS + 2),
		r16(MON_STATS + 4), r16(MON_STATS + 6), r16(MON_STATS + 8)))
	log("  Done. Open the party screen to confirm -- the game recomputes nothing here, so what the "
		.. "screen shows IS what was written. None of it reaches the .sav unless you save in-game.")
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
	if logfile then
		pcall(function() logfile:flush() end)
		logfile:close()
		logfile = nil
	end
end

if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
