-- grant_all_vanilla.lua -- **THIS ONE WRITES THE GAME.** Every badge, every HM, a Bicycle and a
-- Super Rod, once, on a VANILLA-FAMILY build: Crystal V1.0, V1.1 or Speedchoice v8.1. It refuses
-- anything else -- an Archipelago build has its own script (grant_all_ap.lua), because its bag is
-- enlarged, its addresses are measured and its item ids are renumbered.
--
-- CLAUDE.md permits this as dev-only test tooling: a probe, never an adapter. It writes WRAM, not
-- the save -- but **an in-game save afterwards makes it permanent in that save**. It saves a state
-- to SLOT 6 first (slots 2+ are the agent's; 1 and 3 are the user's), so the undo is one keypress.
--
-- Every address below is read from a hash-verified `.sym` (`pokecrystal.sym`, `pokecrystal11.sym`,
-- `crystal-speedchoice.sym`, all three checked equal 2026-09-09) and every item id from that
-- build's own `constants/item_constants.asm`:
--   wJohtoBadges 01:d857   wKantoBadges 01:d858   wTMsHMs 01:d859 (NUM_TMS 50 + NUM_HMS 7 = 57
--   bytes, one count each; HMs are the last seven)   wNumKeyItems 01:d8bc   wKeyItems 01:d8bd
--   (MAX_KEY_ITEMS 25)   wWhichRegisteredItem 01:d95b   wRegisteredItem 01:d95c
--   BICYCLE $07   SUPER_ROD $3d (a KEY item in Crystal)
-- Nothing is trusted written: every field is read back through the same reads and logged.
--
-- Dev-loader contract. Add it as a line of the window's target file; it acts once the player is
-- in the overworld, then does nothing. TAKE IT OFF THE TARGET AFTERWARDS or a reload fires it again.
local DOMAIN = "WRAM"
local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local W_JOHTO_BADGES, W_KANTO_BADGES, W_TMSHMS = flat(0xD857), flat(0xD858), flat(0xD859)
local NUM_TMS, NUM_HMS = 50, 7
local W_NUM_KEY_ITEMS, W_KEY_ITEMS, MAX_KEY_ITEMS = flat(0xD8BC), flat(0xD8BD), 25
local W_WHICH_REGISTERED, W_REGISTERED_ITEM = flat(0xD95B), flat(0xD95C)
local W_MAPSTATUS, W_MAPGROUP = flat(0xD432), flat(0xDCB5) -- vanilla's; speedchoice's group is +1 but is only tested ~= 0 here
local BICYCLE, SUPER_ROD, TERMINATOR = 0x07, 0x3D, 0xFF
local UNDO_SLOT = 6
local function u8(a) return memory.read_u8(a, DOMAIN) end
local function w8(a, v) memory.write_u8(a, v, DOMAIN) end

local function build()
	local t = {}
	for i = 0, 9 do t[#t + 1] = string.char(memory.read_u8(0x134 + i, "ROM") or 0) end
	local title, ver = table.concat(t), memory.read_u8(0x14C, "ROM") or 0
	local ck = string.format("%02X%02X", memory.read_u8(0x14E, "ROM") or 0, memory.read_u8(0x14F, "ROM") or 0)
	if title == "PM_CRYSTAL" and ck == "129F" then return "vanilla V1.0" end
	if title == "PM_CRYSTAL" and ver == 1 and ck == "18D2" then return "vanilla V1.1" end
	if title == "PM_CRYSTAL" and ver == 6 and ck == "99A8" then return "Speedchoice v8.1" end
	return nil, string.format("title %q ver %d checksum %s", title, ver, ck)
end

local port = os.getenv("MESHGHOST_BRIDGE_PORT") or "noport"
local logfile = io.open(string.format("%s/grant_all_%s_%s.log", (io.popen("cd"):read("*l") or "."), os.date("%Y%m%d_%H%M%S"), port), "w")
local function log(s) console.log(s); if logfile then logfile:write(s, "\n"); logfile:flush() end end

local function giveKeyItem(id, name)
	local n = u8(W_NUM_KEY_ITEMS) or 0
	if n > MAX_KEY_ITEMS then return name .. ": REFUSED (count above pocket size, bag looks corrupt)" end
	for i = 0, n - 1 do if u8(W_KEY_ITEMS + i) == id then return name .. ": already held" end end
	if n >= MAX_KEY_ITEMS then return name .. ": REFUSED (pocket full)" end
	w8(W_KEY_ITEMS + n, id); w8(W_KEY_ITEMS + n + 1, TERMINATOR); w8(W_NUM_KEY_ITEMS, n + 1)
	return string.format("%s: appended at slot %d (read back id %02X, count %d)", name, n + 1, u8(W_KEY_ITEMS + n) or 0, u8(W_NUM_KEY_ITEMS) or 0)
end
local function registerBike()
	if (u8(W_WHICH_REGISTERED) or 0) ~= 0 then return "Select: left alone (something is already registered)" end
	for i = 0, (u8(W_NUM_KEY_ITEMS) or 0) - 1 do
		if u8(W_KEY_ITEMS + i) == BICYCLE then
			w8(W_WHICH_REGISTERED, 0x80 | ((i + 1) & 0x3F)); w8(W_REGISTERED_ITEM, BICYCLE)
			return string.format("Select: bike registered (which=%02X item=%02X, read back)", u8(W_WHICH_REGISTERED) or 0, u8(W_REGISTERED_ITEM) or 0)
		end
	end
	return "Select: bike not found in the pocket"
end

local frames, done = 0, false
local function tick()
	frames = frames + 1
	if done or frames < 60 then return end
	if (u8(W_MAPSTATUS) ~= 2) or (u8(W_MAPGROUP) or 0) == 0 then return end -- wait for the overworld
	done = true
	local b, why = build()
	if not b then log("grant_all_vanilla: REFUSING on " .. why .. " -- not a vanilla-family build"); return end
	savestate.saveslot(UNDO_SLOT)
	log(string.format("grant_all_vanilla on %s -- undo is savestate slot %d", b, UNDO_SLOT))
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
	log(registerBike())
	local n = u8(W_NUM_KEY_ITEMS) or 0
	local ids = {}
	for i = 0, math.min(n, MAX_KEY_ITEMS) - 1 do ids[#ids + 1] = string.format("%02X", u8(W_KEY_ITEMS + i) or 0) end
	log(string.format("key items now: count %d [%s] terminator %02X", n, table.concat(ids, " "), u8(W_KEY_ITEMS + n) or 0))
end
MESHGHOST_DEV_TICK = tick
if not MESHGHOST_DEV_LOADER then while true do tick(); emu.frameadvance() end end
