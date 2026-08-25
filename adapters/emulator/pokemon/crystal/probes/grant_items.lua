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
--   * SUPER_ROD and BICYCLE in the key-item pocket -- the reason this file exists. Fishing and
--     riding are two of the drawn tier's action classes (`documentation.md`), and neither can be
--     watched without the item. The bike is also the game's other GAIT: the adapter's own model
--     carries a 4px-per-beat bike stride beside the 2px walk, and nothing has ever exercised it.
--   * MASTER_BALL x10 in the ball pocket
--   * MAX_REPEL x10 and RARE_CANDY x10 in the item pocket -- repels because wild encounters
--     interrupt a movement test, candies because a level is sometimes the cheapest way to reach
--     a state.
--   * PERMANENT REPEL, maintained every frame -- the one thing here that is not a one-shot write.
--     The user's request, 2026-08-25, "similar to how emerald does it": Emerald's testkit.lua
--     keeps VAR_REPEL_STEP_COUNT topped up for exactly the same reason, and this is Crystal's
--     equivalent counter. See "WHAT PERMANENT REPEL ACTUALLY DOES" below -- it is NOT
--     "no wild encounters", and the difference decides whether a test session gets interrupted.
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
-- BICYCLE is 07 and is a KEY_ITEM (`data/items/attributes.asm`, the entry commented `; BICYCLE`),
-- so it goes in the key-item pocket -- which has no quantity byte -- and not beside the balls.
local BICYCLE = 0x07

-- REGISTERING IT TO SELECT, because owning the bike and being able to GET ON it are two different
-- things and only the second one is testable. `SelectMenu` (engine/overworld/select_menu.asm)
-- reads two bytes:
--   * wWhichRegisteredItem (01:d95b) -- pocket in bits 7-6 (REGISTERED_POCKET %11000000, then
--     `rlca rlca` into a jump-table index, so KEY_ITEM_POCKET = 2 sits as %10 = 0x80), and the
--     1-based slot number in bits 5-0. **Zero here means "nothing registered" and is checked
--     first**, which is why the byte cannot simply be left alone.
--   * wRegisteredItem (01:d95c) -- the item id, which .CheckKeyItem then looks up in wKeyItems
--     with IsInArray. The key-item branch never reads the slot number, but it is written
--     correctly anyway rather than relying on a branch that could change.
--
-- ONLY WHEN NOTHING IS REGISTERED. Overwriting a registration is a change to how the player's own
-- controller behaves, and a probe that silently rebinds Select is worse than one that says it did
-- not. Idempotent by construction: run it twice and the second run finds the bike already there.
local W_WHICH_REGISTERED, W_REGISTERED_ITEM = flat(0xD95B), flat(0xD95C)
local KEY_ITEM_POCKET_BITS = 0x80

-- WHAT PERMANENT REPEL ACTUALLY DOES, read off the decompilation rather than assumed, because the
-- assumption ("no wild battles") is wrong in a way that wastes a whole test session:
--
--   * `wRepelEffect` (01:dca1) is a STEP COUNTER, not a flag. `DoRepelStep`
--     (engine/overworld/events.asm:937) decrements it once per step and, on reaching zero, runs
--     RepelWoreOffScript. Keeping it topped up is therefore what "permanent" means -- and it also
--     means the "wore off" prompt can never fire, since that fires exactly at zero.
--   * `CheckRepelEffect` (engine/overworld/wildmons.asm:349) then compares the WILD level against
--     the level of the first party Pokemon that is not fainted, and lets the encounter through
--     when the wild one is GREATER OR EQUAL. So a repel suppresses what is BENEATH your lead, not
--     everything. On a low-level lead this probe will look like it is doing nothing; pair it with
--     probes/set_level.lua and the encounters stop.
--
-- Topped up only when it drops below the threshold rather than written every frame -- one byte
-- either way, but there is no reason to write over the engine's own decrement 60 times a second.
local W_REPEL_EFFECT = flat(0xDCA1)
local REPEL_TOPUP, REPEL_FLOOR = 0xFF, 0x80

-- Set false to leave the counter alone -- e.g. to test what a wild encounter does to a ghost.
local PERMANENT_REPEL = true

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

-- Bind the bike to SELECT, if and only if nothing is bound. Returns a word for the log.
local function registerBike()
	local which = u8(W_WHICH_REGISTERED) or 0
	if which ~= 0 then
		if u8(W_REGISTERED_ITEM) == BICYCLE then
			return "already registered"
		end
		return string.format("LEFT ALONE (item %s is already on Select -- not rebinding it)",
			tostring(u8(W_REGISTERED_ITEM)))
	end
	local n = u8(W_NUM_KEY_ITEMS) or 0
	local slot = nil
	for i = 0, n - 1 do
		if u8(W_KEY_ITEMS + i) == BICYCLE then
			slot = i + 1 -- the field holds a 1-based slot number
			break
		end
	end
	if not slot then
		return "REFUSED (the bike is not in the key-item pocket)"
	end
	w8(W_WHICH_REGISTERED, KEY_ITEM_POCKET_BITS | (slot & 0x3F))
	w8(W_REGISTERED_ITEM, BICYCLE)
	-- READ BACK, from memory, not from what was just written -- CLAUDE.md's rule.
	return string.format("registered (which=%02X item=%02X, read back)",
		u8(W_WHICH_REGISTERED) or 0, u8(W_REGISTERED_ITEM) or 0)
end

open_log()
log("=== MeshGhost Crystal item kit (THIS ONE WRITES THE BAG) ===")

local applied, waited, refused = false, 0, false
local repelSaid = false

-- The only per-frame part of this file. Everything else is written once and goes quiet; this has
-- to keep running, because the engine is decrementing the counter underneath it.
local function holdRepel()
	if not PERMANENT_REPEL or refused or not inOverworld() then return end
	local now = u8(W_REPEL_EFFECT)
	if not now or now >= REPEL_FLOOR then return end
	w8(W_REPEL_EFFECT, REPEL_TOPUP)
	if not repelSaid then
		repelSaid = true
		-- READ BACK, never the value just written -- CLAUDE.md's rule, and it costs one read here.
		log(string.format("  PERMANENT REPEL: topping wRepelEffect up to %d whenever it drops "
			.. "below %d (read back: %s). Remember it only suppresses wild Pokemon BELOW your "
			.. "lead's level -- probes/set_level.lua if they are still appearing.",
			REPEL_TOPUP, REPEL_FLOOR, tostring(u8(W_REPEL_EFFECT))))
	end
end

-- A SAVESTATE LOAD UNDOES EVERY WRITE HERE, and "applied once, now quiet" is the wrong shape for
-- a workflow built on savestates -- which this one is (`environment.md`: slot 1 is the user's,
-- higher slots are the agent's, and loading them is standing practice). Found live 2026-08-25:
-- the bag was granted, the user reloaded a state to get back to the test spot, and the next probe
-- along reported the bike missing -- correctly, because it WAS missing again.
--
-- So the kit re-arms itself. Checked twice a second rather than every frame, on the cheapest
-- possible witness -- is the bike still in the key-item pocket -- and a miss simply puts the file
-- back in its "apply on the next overworld frame" state, which then logs the whole grant again.
-- That repeated block IS the record of a reload, so it is deliberately not suppressed.
local recheck = 0
local function undone()
	local n = u8(W_NUM_KEY_ITEMS) or 0
	if n > MAX_KEY_ITEMS then return false end -- mid-load garbage; say nothing, look again shortly
	for i = 0, n - 1 do
		if u8(W_KEY_ITEMS + i) == BICYCLE then return false end
	end
	return true
end

local function tick()
	if applied then
		holdRepel()
		if refused then return end
		recheck = recheck + 1
		if recheck >= 30 and inOverworld() then
			recheck = 0
			if undone() then
				applied, repelSaid = false, false
				log("  -- the bag no longer holds what this probe wrote (a savestate load, most "
					.. "likely). Granting it again:")
			end
		end
		return
	end
	if not isVanillaV10() then
		refused = true
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
	log("  BICYCLE (key item):   " .. giveKeyItem(BICYCLE))
	log("  BICYCLE on SELECT:    " .. registerBike())
	log("  MASTER_BALL x10:      " .. givePaired(W_NUM_BALLS, W_BALLS, MAX_BALLS, MASTER_BALL, 10))
	log("  MAX_REPEL x10:        " .. givePaired(W_NUM_ITEMS, W_ITEMS, MAX_ITEMS, MAX_REPEL, 10))
	log("  RARE_CANDY x10:       " .. givePaired(W_NUM_ITEMS, W_ITEMS, MAX_ITEMS, RARE_CANDY, 10))

	-- READ BACK, from memory, not from what was just written -- CLAUDE.md's rule.
	log("  AFTER items:     " .. dump(W_NUM_ITEMS, W_ITEMS, true, MAX_ITEMS))
	log("  AFTER balls:     " .. dump(W_NUM_BALLS, W_BALLS, true, MAX_BALLS))
	log("  AFTER key items: " .. dump(W_NUM_KEY_ITEMS, W_KEY_ITEMS, false, MAX_KEY_ITEMS))
	log("  Done. Open the bag to see them. None of this reaches the .sav unless you save in-game.")
	if PERMANENT_REPEL then
		holdRepel()
	else
		log("  PERMANENT REPEL is off in this copy of the probe -- wild encounters are normal.")
	end
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
