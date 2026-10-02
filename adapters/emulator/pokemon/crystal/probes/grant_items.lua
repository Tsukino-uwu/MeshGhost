-- Dev tool that cheats on purpose, writing the bag: SUPER_ROD and BICYCLE (on SELECT if nothing is registered),
-- MASTER_BALL, MAX_REPEL, RARE_CANDY and ESCAPE_ROPE x10, and a repel kept topped up; a second run changes nothing. It
-- writes WRAM, never the .sav, but an in-game save keeps it: savestate first. Vanilla V1.0 only; addresses from our
-- hash-verified build's .sym. Waits for the overworld, logs every pocket as read back, and re-grants after a load.

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
-- An ordinary item, so the paired pocket: an id written where a count belongs corrupts the bag.
local ESCAPE_ROPE = 0x13
-- A key item, so the key-item pocket, which has no quantity byte.
local BICYCLE = 0x07

-- The bike on SELECT, since owning it is not riding it; only when nothing is registered, so a player's own binding
-- is never silently changed. wWhichRegisteredItem: pocket bits and a 1-based slot; wRegisteredItem: the id.
local W_WHICH_REGISTERED, W_REGISTERED_ITEM = flat(0xD95B), flat(0xD95C)
local KEY_ITEM_POCKET_BITS = 0x80

-- Expected to be a step counter the engine decrements: topped up only below the floor, never written over every
-- frame. It is expected to stop only wild Pokemon below the lead's level, so raise the lead if they keep coming.
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

-- Flushed per line, unlike a per-frame probe: a dozen lines in all, readable while the probe stays loaded.
local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		pcall(function() logfile:flush() end)
	end
end

-- These addresses describe one build; a patched ROM's bag is somewhere else.
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

-- Paired pockets are (id, qty); the key-item pocket is bare ids.
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

-- Says whether it set or appended: "it is there now" is true either way.
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
	-- Read back from memory, not from what was just written.
	return string.format("registered (which=%02X item=%02X, read back)",
		u8(W_WHICH_REGISTERED) or 0, u8(W_REGISTERED_ITEM) or 0)
end

open_log()
log("=== MeshGhost Crystal item kit (THIS ONE WRITES THE BAG) ===")

local applied, waited, refused = false, 0, false
local repelSaid = false

-- The only per-frame part: the engine decrements the counter underneath it.
local function holdRepel()
	if not PERMANENT_REPEL or refused or not inOverworld() then return end
	local now = u8(W_REPEL_EFFECT)
	if not now or now >= REPEL_FLOOR then return end
	w8(W_REPEL_EFFECT, REPEL_TOPUP)
	if not repelSaid then
		repelSaid = true
		-- Read back, never the value just written.
		log(string.format("  PERMANENT REPEL: topping wRepelEffect up to %d whenever it drops "
			.. "below %d (read back: %s). Remember it only suppresses wild Pokemon BELOW your "
			.. "lead's level -- raise the lead's level if they are still appearing.",
			REPEL_TOPUP, REPEL_FLOOR, tostring(u8(W_REPEL_EFFECT))))
	end
end

-- A savestate load undoes every write here, so the kit re-arms: twice a second it checks the bike is still held, and
-- a miss grants and logs everything again, which is the log's record of the reload.
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

	-- The before-state tells a bad write from a bag that was already unusual.
	log("  BEFORE items:    " .. dump(W_NUM_ITEMS, W_ITEMS, true, MAX_ITEMS))
	log("  BEFORE balls:    " .. dump(W_NUM_BALLS, W_BALLS, true, MAX_BALLS))
	log("  BEFORE key items:" .. dump(W_NUM_KEY_ITEMS, W_KEY_ITEMS, false, MAX_KEY_ITEMS))

	log("  SUPER_ROD (key item): " .. giveKeyItem(SUPER_ROD))
	log("  BICYCLE (key item):   " .. giveKeyItem(BICYCLE))
	log("  BICYCLE on SELECT:    " .. registerBike())
	log("  MASTER_BALL x10:      " .. givePaired(W_NUM_BALLS, W_BALLS, MAX_BALLS, MASTER_BALL, 10))
	log("  MAX_REPEL x10:        " .. givePaired(W_NUM_ITEMS, W_ITEMS, MAX_ITEMS, MAX_REPEL, 10))
	log("  RARE_CANDY x10:       " .. givePaired(W_NUM_ITEMS, W_ITEMS, MAX_ITEMS, RARE_CANDY, 10))
	log("  ESCAPE_ROPE x10:      " .. givePaired(W_NUM_ITEMS, W_ITEMS, MAX_ITEMS, ESCAPE_ROPE, 10))

	-- Read back from memory, not from what was just written.
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
