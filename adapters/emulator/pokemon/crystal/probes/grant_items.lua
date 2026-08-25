-- MeshGhost — Pokémon Crystal: grant test items (rods, balls, repels)
--
-- DEVELOPMENT TOOL. **THIS ONE CHEATS, DELIBERATELY, AND IT IS ALLOWED TO.** CLAUDE.md's rule is
-- that nothing which SHIPS may write a save, a game state or a ROM -- and that dev-only test
-- tooling MAY cheat, as a PROBE, never as an adapter. This is that probe.
--
-- THE SIBLING OF grant_test_kit.lua, which is narrow on purpose: that one does badges, HMs and
-- field moves and says outright that it gives no items. This is the items half, kept separate for
-- the same reason -- what each one changed stays obvious.
--
-- ** READ THIS BEFORE RUNNING IT **
-- It writes the bag in WRAM. That is not the save file -- but **if you SAVE in-game afterwards,
-- these items are permanent in that save**. Savestate first, test, load the savestate after. It
-- never touches the .sav and never writes a savestate.
--
-- WHAT IT GIVES, and nothing else:
--   * SUPER_ROD in the key-item pocket -- the reason this file exists. Fishing is one of the
--     drawn tier's action classes (`documentation.md`), and it cannot be watched without a rod.
--   * MASTER_BALL x10 in the ball pocket
--   * MAX_REPEL x10 and RARE_CANDY x10 in the item pocket -- repels because wild encounters
--     interrupt a movement test, candies because a level is sometimes the cheapest way to reach
--     a state.
--
-- IT IS IDEMPOTENT: an item already in a pocket has its quantity SET, not added, and the key item
-- is not duplicated. Running it twice does the same thing as running it once.
--
-- WHERE THE NUMBERS COME FROM -- every one traceable, none from memory:
--   * Pocket addresses: our own hash-verified pokecrystal build's `pokecrystal.sym` --
--     `01:d892 wNumItems`, `01:d8bc wNumKeyItems`, `01:d8d7 wNumBalls`.
--   * Pocket LAYOUT: `ram/wram.asm` -- `wItems:: ds MAX_ITEMS * 2 + 1` and
--     `wBalls:: ds MAX_BALLS * 2 + 1` are (id, quantity) pairs plus a terminator, while
--     `wKeyItems:: ds MAX_KEY_ITEMS + 1` is bare ids plus a terminator. **The key-item pocket
--     having no quantity byte is the one difference that would corrupt the bag if assumed away**,
--     which is why it is cited rather than remembered.
--   * Capacities: `constants/item_data_constants.asm` -- MAX_ITEMS 20, MAX_BALLS 12,
--     MAX_KEY_ITEMS 25.
--   * Item ids: `constants/item_constants.asm` -- MASTER_BALL 01, RARE_CANDY 20, MAX_REPEL 2b,
--     SUPER_ROD 3d.
--
-- VANILLA V1.0 ONLY -- it refuses on anything else rather than writing a patched build's RAM at
-- vanilla's addresses.
--
-- HOW TO RUN
--   Add it to dev-scripts/bizhawk-dev-loader-crystal.target. It waits until you are in the
--   overworld, writes once, reports every pocket AS READ BACK FROM MEMORY, and goes quiet.
--   Log: grant_items_<timestamp>.log beside this file.

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- pokecrystal.sym
local W_NUM_ITEMS, W_ITEMS = flat(0xD892), flat(0xD893)
local W_NUM_KEY_ITEMS, W_KEY_ITEMS = flat(0xD8BC), flat(0xD8BD)
local W_NUM_BALLS, W_BALLS = flat(0xD8D7), flat(0xD8D8)
local W_MAPSTATUS, W_MAPGROUP = flat(0xD432), flat(0xDCB5)

-- constants/item_data_constants.asm
local MAX_ITEMS, MAX_BALLS, MAX_KEY_ITEMS = 20, 12, 25

-- constants/item_constants.asm
local MASTER_BALL, RARE_CANDY, MAX_REPEL, SUPER_ROD = 0x01, 0x20, 0x2B, 0x3D

local TERMINATOR = 0xFF

local function u8(a) return memory.read_u8(a, DOMAIN) end
local function w8(a, v) memory.write_u8(a, v, DOMAIN) end

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/grant_items_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
end

-- FLUSHED PER LINE, and that is right HERE where it is wrong in a per-frame probe: this file
-- writes about a dozen lines in total and then stops forever, so the flush cost is paid once and
-- the log is readable the instant it is written. grant_test_kit.lua batches its flush every 20
-- lines and closes on unload, so on 2026-08-25 its log sat at 0 bytes for as long as it stayed
-- loaded -- the content did arrive, on unload, so nothing was lost, but a probe that writes a
-- dozen lines and stops is unreadable exactly while you are waiting to read it.
local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		pcall(function() logfile:flush() end)
	end
end

-- VANILLA ONLY. Same check grant_test_kit.lua makes, and for the same reason: these addresses
-- describe one build, and a patched ROM's bag is somewhere else.
local function isVanillaV10()
	local t = {}
	for i = 0, 9 do
		local c = memory.read_u8(0x134 + i, "ROM")
		if not c then return false end
		t[#t + 1] = string.char(c)
	end
	return table.concat(t) == "PM_CRYSTAL"
		and memory.read_u8(0x14E, "ROM") == 0x12 and memory.read_u8(0x14F, "ROM") == 0x9F
end

local function inOverworld()
	local status, group = u8(W_MAPSTATUS), u8(W_MAPGROUP)
	return status == 2 and group ~= nil and group ~= 0
end

-- Read a pocket back as text. PAIRED pockets are (id, qty); the key-item pocket is bare ids.
local function dump(countAddr, listAddr, paired, cap)
	local n = u8(countAddr) or 0
	local out = {}
	if n > cap then
		return string.format("count=%d (ABOVE the pocket's %d -- not reading further)", n, cap)
	end
	for i = 0, n - 1 do
		if paired then
			out[#out + 1] = string.format("%02X x%d", u8(listAddr + i * 2) or 0,
				u8(listAddr + i * 2 + 1) or 0)
		else
			out[#out + 1] = string.format("%02X", u8(listAddr + i) or 0)
		end
	end
	local term = paired and u8(listAddr + n * 2) or u8(listAddr + n)
	return string.format("count=%d [%s] terminator=%02X", n, table.concat(out, " "), term or 0)
end

-- Set an item's quantity, appending it if the pocket does not already hold it. Returns a word for
-- the log saying which of the two happened, because "it is there now" is true either way and the
-- difference is the whole question when something looks wrong afterwards.
local function givePaired(countAddr, listAddr, cap, id, qty)
	local n = u8(countAddr) or 0
	if n > cap then return "REFUSED (count above pocket size -- bag looks corrupt, writing nothing)" end
	for i = 0, n - 1 do
		if u8(listAddr + i * 2) == id then
			w8(listAddr + i * 2 + 1, qty)
			return "already held, quantity set"
		end
	end
	if n >= cap then return "REFUSED (pocket full)" end
	w8(listAddr + n * 2, id)
	w8(listAddr + n * 2 + 1, qty)
	w8(listAddr + (n + 1) * 2, TERMINATOR)
	w8(countAddr, n + 1)
	return "appended"
end

local function giveKeyItem(id)
	local n = u8(W_NUM_KEY_ITEMS) or 0
	if n > MAX_KEY_ITEMS then return "REFUSED (count above pocket size -- writing nothing)" end
	for i = 0, n - 1 do
		if u8(W_KEY_ITEMS + i) == id then return "already held" end
	end
	if n >= MAX_KEY_ITEMS then return "REFUSED (pocket full)" end
	w8(W_KEY_ITEMS + n, id)
	w8(W_KEY_ITEMS + n + 1, TERMINATOR)
	w8(W_NUM_KEY_ITEMS, n + 1)
	return "appended"
end

open_log()
log("=== MeshGhost Crystal item kit (THIS ONE WRITES THE BAG) ===")

local applied, waited = false, 0

local function tick()
	if applied then return end
	if not isVanillaV10() then
		applied = true
		log("REFUSED: this is not vanilla Crystal V1.0, and these addresses describe only that build.")
		return
	end
	if not inOverworld() then
		waited = waited + 1
		if waited % 300 == 0 then
			log(string.format("  waiting for the overworld (mapstatus=%s) -- %ds so far",
				tostring(u8(W_MAPSTATUS)), waited // 60))
		end
		return
	end
	applied = true

	-- LOOK FIRST. If anything below goes wrong, the before-state is the only way to tell a bad
	-- write from a bag that was already unusual.
	log("  BEFORE items:    " .. dump(W_NUM_ITEMS, W_ITEMS, true, MAX_ITEMS))
	log("  BEFORE balls:    " .. dump(W_NUM_BALLS, W_BALLS, true, MAX_BALLS))
	log("  BEFORE key items:" .. dump(W_NUM_KEY_ITEMS, W_KEY_ITEMS, false, MAX_KEY_ITEMS))

	log("  SUPER_ROD (key item): " .. giveKeyItem(SUPER_ROD))
	log("  MASTER_BALL x10:      " .. givePaired(W_NUM_BALLS, W_BALLS, MAX_BALLS, MASTER_BALL, 10))
	log("  MAX_REPEL x10:        " .. givePaired(W_NUM_ITEMS, W_ITEMS, MAX_ITEMS, MAX_REPEL, 10))
	log("  RARE_CANDY x10:       " .. givePaired(W_NUM_ITEMS, W_ITEMS, MAX_ITEMS, RARE_CANDY, 10))

	-- READ BACK, from memory, not from what was just written -- CLAUDE.md's rule.
	log("  AFTER items:     " .. dump(W_NUM_ITEMS, W_ITEMS, true, MAX_ITEMS))
	log("  AFTER balls:     " .. dump(W_NUM_BALLS, W_BALLS, true, MAX_BALLS))
	log("  AFTER key items: " .. dump(W_NUM_KEY_ITEMS, W_KEY_ITEMS, false, MAX_KEY_ITEMS))
	log("  Done. Open the bag to see them. None of this reaches the .sav unless you save in-game.")
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
