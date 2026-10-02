-- Pokémon Crystal: teaches Surf, Fly, Strength and Waterfall to party slot 1 (Whirlpool, Cut, Flash to slot 2), once,
-- on any of the five recognised builds; on a vanilla-family build with an empty party it first creates a level-5
-- Cyndaquil with the player's name and ID as trainer. Writes WRAM, never the save; undo state to slot 6 first.
-- Fly still needs a visited town and the field moves the badges (grant_all_*.lua). Take it off the target afterwards.
-- On Archipelago the nickname and OT blocks are unmeasured, so there it only teaches moves. Names are 11 bytes in the
-- game's charset (A = $80, terminator $50). Everything written is read back and logged.
local DOMAIN = "WRAM"
local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local function u8(a) return memory.read_u8(a, DOMAIN) end
local function w8(a, v) memory.write_u8(a, v & 0xFF, DOMAIN) end
local MON_MOVES, MON_PP, MON_LEVEL, STRUCT, NAME_LEN = 0x02, 0x17, 0x1F, 0x30, 11
local MOVE = { CUT = 0x0F, FLY = 0x13, SURF = 0x39, STRENGTH = 0x46, WATERFALL = 0x7F, FLASH = 0x94, WHIRLPOOL = 0xFA }
local LOADOUT = { { "SURF", "FLY", "STRENGTH", "WATERFALL" }, { "WHIRLPOOL", "CUT", "FLASH" } }
local PP = 15
local UNDO_SLOT = 6
local CYNDAQUIL = 0x9B
-- The AP window's own level-5 Cyndaquil, held item cleared; its moves and PP get overwritten.
local TEMPLATE = { 0x9B, 0x00, 0x21, 0x2B, 0x00, 0x00, 0x6E, 0x93, 0x00, 0x00, 0x7D,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x36, 0x96, 0x23, 0x1E, 0x00, 0x00, 0x42, 0x00, 0x45, 0x30, 0x05,
	0x00, 0x00, 0x00, 0x13, 0x00, 0x13, 0x00, 0x0A, 0x00, 0x09, 0x00, 0x0C, 0x00, 0x0B, 0x00, 0x0A }
local NICK = { 0x82, 0x98, 0x8D, 0x83, 0x80, 0x90, 0x94, 0x88, 0x8B, 0x50, 0x50 } -- CYNDAQUIL

local function build()
	local t = {}
	for i = 0, 9 do t[#t + 1] = string.char(memory.read_u8(0x134 + i, "ROM") or 0) end
	local title, ver = table.concat(t), memory.read_u8(0x14C, "ROM") or 0
	local ck = string.format("%02X%02X", memory.read_u8(0x14E, "ROM") or 0, memory.read_u8(0x14F, "ROM") or 0)
	local V = { count = flat(0xDCD7), species = flat(0xDCD8), mon1 = flat(0xDCDF), ots = flat(0xDDFF), nicks = flat(0xDE41),
		pid = flat(0xD47B), pname = flat(0xD47D), status = flat(0xD432), group = flat(0xDCB5), canCreate = true }
	if title:sub(1, 3) == "AP_" then
		return string.format("Archipelago (V1.%d base)", ver), { count = 0x1CDE, species = 0x1CDF, mon1 = 0x1CE6,
			status = 0x1439, group = 0x1CBC, canCreate = false }
	end
	if title == "PM_CRYSTAL" and ck == "129F" then return "vanilla V1.0", V end
	if title == "PM_CRYSTAL" and ver == 1 and ck == "18D2" then return "vanilla V1.1", V end
	if title == "PM_CRYSTAL" and ver == 6 and ck == "99A8" then
		return "Speedchoice v8.1", { count = flat(0xDCD8), species = flat(0xDCD9), mon1 = flat(0xDCE0), ots = flat(0xDE00),
			nicks = flat(0xDE42), pid = flat(0xD47B), pname = flat(0xD47D), status = flat(0xD432), group = flat(0xDCB6), canCreate = true }
	end
	return nil, string.format("title %q ver %d checksum %s", title, ver, ck)
end

local port = os.getenv("MESHGHOST_BRIDGE_PORT") or "noport"
local logfile = io.open(string.format("%s/grant_party_%s_%s.log", (io.popen("cd"):read("*l") or "."), os.date("%Y%m%d_%H%M%S"), port), "w")
local function log(s) console.log(s); if logfile then logfile:write(s, "\n"); logfile:flush() end end

local function createCyndaquil(A)
	for i, b in ipairs(TEMPLATE) do w8(A.mon1 + i - 1, b) end
	w8(A.mon1 + 6, u8(A.pid) or 0); w8(A.mon1 + 7, u8(A.pid + 1) or 0) -- OT id = the player's
	for i = 0, NAME_LEN - 1 do w8(A.nicks + i, NICK[i + 1]); w8(A.ots + i, u8(A.pname + i) or 0x50) end
	w8(A.species, CYNDAQUIL); w8(A.species + 1, 0xFF); w8(A.count, 1)
	return string.format("created a Cyndaquil: count %d, species list %02X %02X, struct species %02X level %d hp %d/%d",
		u8(A.count) or 0, u8(A.species) or 0, u8(A.species + 1) or 0, u8(A.mon1) or 0, u8(A.mon1 + MON_LEVEL) or 0,
		(u8(A.mon1 + 0x22) or 0) * 256 + (u8(A.mon1 + 0x23) or 0), (u8(A.mon1 + 0x24) or 0) * 256 + (u8(A.mon1 + 0x25) or 0))
end

local frames, done = 0, false
local function tick()
	frames = frames + 1
	if done or frames < 60 then return end
	local b, A = build()
	if not b then done = true; log("grant_party: REFUSING on " .. tostring(A)); return end
	if (u8(A.status) ~= 2) or (u8(A.group) or 0) == 0 then return end
	done = true
	savestate.saveslot(UNDO_SLOT)
	log(string.format("grant_party on %s -- undo is savestate slot %d", b, UNDO_SLOT))
	local n = u8(A.count) or 0
	log(string.format("party count before: %d (species list starts %02X)", n, u8(A.species) or 0))
	if n == 0 then
		if A.canCreate then log(createCyndaquil(A)); n = u8(A.count) or 0
		else log("party EMPTY and this build's nickname/OT blocks are unmeasured: nothing created, nothing taught") end
	end
	for slot = 1, math.min(#LOADOUT, n) do
		local base = A.mon1 + (slot - 1) * STRUCT
		local moves = LOADOUT[slot]
		for i = 1, 4 do
			local m = moves[i]
			w8(base + MON_MOVES + i - 1, m and MOVE[m] or 0); w8(base + MON_PP + i - 1, m and PP or 0)
		end
		local ids = {}
		for i = 0, 3 do ids[#ids + 1] = string.format("%02X/pp%d", u8(base + MON_MOVES + i) or 0, u8(base + MON_PP + i) or 0) end
		log(string.format("slot %d (species %02X, L%d): moves read back %s = %s", slot, u8(base) or 0, u8(base + MON_LEVEL) or 0,
			table.concat(ids, " "), table.concat(moves, "/")))
	end
end
MESHGHOST_DEV_TICK = tick
if not MESHGHOST_DEV_LOADER then while true do tick(); emu.frameadvance() end end
