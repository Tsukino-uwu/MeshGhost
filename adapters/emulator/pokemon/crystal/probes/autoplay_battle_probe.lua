-- MeshGhost — Pokémon Crystal: the battlers, their moves and the move data, for autoplay's `battle`
-- (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-17
--
-- READ-ONLY. Load it beside the autoplay driver (one path a line in the loader's control file), then play a battle
-- with the driver's tools and read this log against `observe` and captures of the battle screen.
--
-- WHY. autoplay's `battle` can only RUN on Crystal: nothing says which Pokémon are fighting, what moves they know or
-- what those moves do. Our V1.0 build's .sym names the blocks (wBattleMon, wEnemyMon, the two move structs, the ROM
-- tables Moves, MoveNames, PokemonNames and TypeNames); what each byte MEANS is what this log, read against the
-- screen, shows.
--
-- WHAT IT LOGS, each group on change, every frame:
--   state   battle mode and type, result, ended, current battler indices, current moves, missed, damage, turns
--           taken, trainer class and id, battle actions, menu cursor, wScriptRunning, hJoyDown.
--   player  wBattleMon (0x20 bytes from C62C) and wBattleMonNickname (11 from C621), hex.
--   enemy   wEnemyMon (0x20 from D206) and wEnemyMonNickname (11 from C616), hex.
--   pmove   wPlayerMoveStruct (7 from C60F); emove wEnemyMoveStruct (7 from C608).
--   party   wPartyCount and its species list, wPartyMon1 (0x30 from DCDF), its nickname; partyN each later slot, 0x30
--           on, and 11 bytes on for its nickname; money wMoney (3 bytes).
--   ot      wOTPartyCount and species list, wOTPartyMon1 (0x30 from D288).
-- And ONCE per id met in any battler, move struct or party slot 1 (so a byte is only named once it is seen):
--   move N  its 7 bytes in the table at 10:5AFB (entry N-1), and the Nth '@'-ended string from 72:5F29, raw and
--           spelled with the letters MEASURED.md names (A-Z 0x80-0x99, space 0x7F, digits, "-" 0xE3; anything else {XX}).
--   species N  10 bytes at 14:7384 + (N-1)*10, raw and spelled.
--   type N  the pointer at 14:497B + N*2 and the string it points at in bank 14, raw and spelled.
-- What it cannot see: the screen (read it with observe and captures), anything that happens inside a frame, move ids
-- no battler or struct ever held.
--
-- COST. About 200 bytes of WRAM reads a frame and a few ROM reads the first time an id is met.
-- Log: crystal/logs/autoplay_battle_<port>_<timestamp>.log.

local dir, port = ".", tostring(AUTOPLAY_PORT or os.getenv("AUTOPLAY_PORT") or "na")
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logdir = (dir:match("^(.*)/probes$") or dir) .. "/logs"
local logf = io.open(string.format("%s/autoplay_battle_%s_%s.log", logdir, port, os.date("%Y%m%d_%H%M%S")), "w")
if logf then logf:setvbuf("full", 16384) end
local function log(s)
	if logf then logf:write(string.format("[%s f%d] %s\n", os.date("%H:%M:%S"), emu.framecount(), s)) end
end

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local function u8(cpu) return memory.read_u8(flat(cpu), "WRAM") end
local function wram(cpu, n) return memory.read_bytes_as_array(flat(cpu), n, "WRAM") end
local function rom(bank, ptr, n) return memory.read_bytes_as_array(bank * 0x4000 + (ptr - 0x4000), n, "ROM") end

local function hex(b)
	local out = {}
	for i = 1, #b do out[i] = string.format("%02X", b[i]) end
	return table.concat(out, " ")
end

-- The letters MEASURED.md, "Text on screen", names; used only to make the log readable.
local function spell(b)
	local out = {}
	for i = 1, #b do
		local c = b[i]
		if c == 0x50 then break end
		if c >= 0x80 and c <= 0x99 then out[#out + 1] = string.char(0x41 + c - 0x80)
		elseif c >= 0xA0 and c <= 0xB9 then out[#out + 1] = string.char(0x61 + c - 0xA0)
		elseif c >= 0xF6 then out[#out + 1] = tostring(c - 0xF6)
		elseif c == 0x7F then out[#out + 1] = " "
		elseif c == 0xE3 then out[#out + 1] = "-"
		else out[#out + 1] = string.format("{%02X}", c) end
	end
	return table.concat(out)
end

local seenMove, seenSpecies, seenType = {}, {}, {}

local function logType(t)
	if seenType[t] or t > 0x1F then return end
	seenType[t] = true
	local p = rom(0x14, 0x497B + t * 2, 2)
	local ptr = p[1] | (p[2] << 8)
	if ptr < 0x4000 or ptr > 0x7FFF then
		log(string.format("type %d ptr %04X (outside the bank)", t, ptr))
		return
	end
	local s = rom(0x14, ptr, 12)
	log(string.format("type %d ptr %04X bytes %s spelled %s", t, ptr, hex(s), spell(s)))
end

-- The Nth '@'-ended string from 72:5F29, walking the list the way its layout suggests; the log shows the raw bytes
-- so a wrong walk is visible.
local function moveName(id)
	local ptr, n = 0x5F29, 1
	while n < id do
		local b = rom(0x72, ptr, 1)[1]
		ptr = ptr + 1
		if b == 0x50 then n = n + 1 end
		if ptr > 0x7FFF then return {} end
	end
	return rom(0x72, ptr, 13)
end

local function logMove(id)
	if id == 0 or seenMove[id] then return end
	seenMove[id] = true
	local e = rom(0x10, 0x5AFB + (id - 1) * 7, 7)
	local name = moveName(id)
	log(string.format("move %d entry %s name %s spelled %s", id, hex(e), hex(name), spell(name)))
	logType(e[4])
end

local function logSpecies(id)
	if id == 0 or id == 0xFF or seenSpecies[id] then return end
	seenSpecies[id] = true
	local s = rom(0x14, 0x7384 + (id - 1) * 10, 10)
	log(string.format("species %d bytes %s spelled %s", id, hex(s), spell(s)))
end

local last = {}
local function changed(key, line)
	if last[key] ~= line then
		last[key] = line
		log(key .. " " .. line)
	end
end

log("loaded")
local frames = 0

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local dmg = wram(0xD256, 2)
	changed("state", string.format(
		"mode %d type %d result %d ended %d curmon %d curot %d otcount %d curpmove %d curemove %d missed %d damage %d " ..
		"pturns %d eturns %d tclass %d otherclass %d otherid %d action %d paction %d cursorY %d script %d joy %02X",
		u8(0xD22D), u8(0xD230), u8(0xD0EE), u8(0xC734), u8(0xD0D4), u8(0xC663), u8(0xD280), u8(0xC6E3), u8(0xC6E4),
		u8(0xC667), (dmg[1] << 8) | dmg[2], u8(0xC6DD), u8(0xC6DC), u8(0xD233), u8(0xD22F), u8(0xD231), u8(0xD430),
		u8(0xD0EC), u8(0xCFA9), u8(0xD438), memory.read_u8(0xFFA8, "System Bus")))

	local pm, em = wram(0xC62C, 0x20), wram(0xD206, 0x20)
	changed("player", hex(pm) .. " | " .. hex(wram(0xC621, 11)))
	changed("enemy", hex(em) .. " | " .. hex(wram(0xC616, 11)))
	local ps, es = wram(0xC60F, 7), wram(0xC608, 7)
	changed("pmove", hex(ps))
	changed("emove", hex(es))
	local party = wram(0xDCDF, 0x30)
	changed("party", string.format("count %d species %s mon1 %s | %s", u8(0xDCD7), hex(wram(0xDCD8, 7)), hex(party),
		hex(wram(0xDE41, 11))))
	-- Every later slot too, 0x30 bytes apart from the first and its nickname 11 bytes after the first's (2026-09-17:
	-- the addresses a second Pokémon would sit at if the slots are evenly spaced, which this log is to check).
	for k = 1, math.min(u8(0xDCD7), 6) - 1 do
		changed("party" .. (k + 1), string.format("mon%d %s | %s", k + 1, hex(wram(0xDCDF + k * 0x30, 0x30)),
			hex(wram(0xDE41 + k * 11, 11))))
	end
	changed("money", hex(wram(0xD84E, 3)))
	changed("ot", string.format("count %d species %s mon1 %s", u8(0xD280), hex(wram(0xD281, 7)), hex(wram(0xD288, 0x30))))

	logSpecies(pm[1]); logSpecies(em[1]); logSpecies(party[1])
	for k = 0, 3 do
		logMove(pm[3 + k]); logMove(em[3 + k]); logMove(party[3 + k])
	end
	logMove(ps[1]); logMove(es[1])

	if logf and frames % 120 == 0 then logf:flush() end
end

MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	if logf then
		logf:flush()
		logf:close()
	end
	logf = nil
end
