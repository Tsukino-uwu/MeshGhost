-- Writes the game: every badge, every HM, a Bicycle and a Super Rod, once, on an Archipelago-patched Crystal (either
-- base); refuses any other ROM. Its bag is enlarged, its WRAM rearranged and its item ids renumbered, so every
-- address here was measured from the cartridge. Saves slot 6 first and reads everything back; an in-game save
-- afterwards makes it permanent, and it hands out what Archipelago's logic expects to grant, so use a throwaway game.
-- The Select-registration pair is not measured: register the bike by hand. Take it off the target afterwards.
local DOMAIN = "WRAM"
local W_JOHTO_BADGES, W_KANTO_BADGES, W_TMSHMS = 0x182B, 0x182C, 0x182D
local NUM_TMS, NUM_HMS = 50, 7
local W_NUM_KEY_ITEMS, W_KEY_ITEMS, MAX_KEY_ITEMS = 0x1960, 0x1961, 39
local W_NUM_ITEMS, W_NUM_BALLS = 0x1866, 0x1989 -- read only, for the coverage line
local W_MAPSTATUS, W_MAPGROUP = 0x1439, 0x1CBC -- the adapter's measured AP table
local BICYCLE, SUPER_ROD, TERMINATOR = 0x06, 0x38, 0xFF
local UNDO_SLOT = 6
local function u8(a) return memory.read_u8(a, DOMAIN) end
local function w8(a, v) memory.write_u8(a, v, DOMAIN) end
local function isAP()
	local t = {}
	for i = 0, 2 do t[#t + 1] = string.char(memory.read_u8(0x134 + i, "ROM") or 0) end
	return table.concat(t) == "AP_", memory.read_u8(0x14C, "ROM") or 0
end
local port = os.getenv("MESHGHOST_BRIDGE_PORT") or "noport"
local logfile = io.open(string.format("%s/grant_all_ap_%s_%s.log", (io.popen("cd"):read("*l") or "."), os.date("%Y%m%d_%H%M%S"), port), "w")
local function log(s) console.log(s); if logfile then logfile:write(s, "\n"); logfile:flush() end end
local function giveKeyItem(id, name)
	local n = u8(W_NUM_KEY_ITEMS) or 0
	if n > MAX_KEY_ITEMS then return name .. ": REFUSED (count above pocket size, bag looks corrupt)" end
	for i = 0, n - 1 do if u8(W_KEY_ITEMS + i) == id then return name .. ": already held" end end
	if n >= MAX_KEY_ITEMS then return name .. ": REFUSED (pocket full)" end
	w8(W_KEY_ITEMS + n, id); w8(W_KEY_ITEMS + n + 1, TERMINATOR); w8(W_NUM_KEY_ITEMS, n + 1)
	return string.format("%s: appended at slot %d (read back id %02X, count %d)", name, n + 1, u8(W_KEY_ITEMS + n) or 0, u8(W_NUM_KEY_ITEMS) or 0)
end
local frames, done = 0, false
local function tick()
	frames = frames + 1
	if done or frames < 60 then return end
	if (u8(W_MAPSTATUS) ~= 2) or (u8(W_MAPGROUP) or 0) == 0 then return end
	done = true
	local ap, rev = isAP()
	if not ap then log("grant_all_ap: REFUSING -- not an Archipelago ROM"); return end
	savestate.saveslot(UNDO_SLOT)
	log(string.format("grant_all_ap on an Archipelago ROM (V1.%d base) -- undo is savestate slot %d", rev, UNDO_SLOT))
	log(string.format("coverage: items count %d, key items count %d, balls count %d, TM/HM bytes %02X..%02X",
		u8(W_NUM_ITEMS) or -1, u8(W_NUM_KEY_ITEMS) or -1, u8(W_NUM_BALLS) or -1, u8(W_TMSHMS) or 0, u8(W_TMSHMS + NUM_TMS + NUM_HMS - 1) or 0))
	local before = string.format("%02X %02X", u8(W_JOHTO_BADGES) or 0, u8(W_KANTO_BADGES) or 0)
	w8(W_JOHTO_BADGES, 0xFF); w8(W_KANTO_BADGES, 0xFF)
	log(string.format("badges: johto/kanto were %s, read back %02X %02X", before, u8(W_JOHTO_BADGES) or 0, u8(W_KANTO_BADGES) or 0))
	local hm = {}
	for i = 0, NUM_HMS - 1 do
		local a = W_TMSHMS + NUM_TMS + i
		if (u8(a) or 0) == 0 then w8(a, 1) end
		hm[#hm + 1] = string.format("HM%02d=%d", i + 1, u8(a) or 0)
	end
	log("HMs (read back): " .. table.concat(hm, " "))
	log(giveKeyItem(BICYCLE, "Bicycle"))
	log(giveKeyItem(SUPER_ROD, "Super Rod"))
	local n = u8(W_NUM_KEY_ITEMS) or 0
	local ids = {}
	for i = 0, math.min(n, MAX_KEY_ITEMS) - 1 do ids[#ids + 1] = string.format("%02X", u8(W_KEY_ITEMS + i) or 0) end
	log(string.format("key items now: count %d [%s] terminator %02X", n, table.concat(ids, " "), u8(W_KEY_ITEMS + n) or 0))
end
MESHGHOST_DEV_TICK = tick
if not MESHGHOST_DEV_LOADER then while true do tick(); emu.frameadvance() end end
