-- grant_all_ap.lua -- **THIS ONE WRITES THE GAME.** Every badge, every HM, a Bicycle and a Super
-- Rod, once, on an ARCHIPELAGO-patched Crystal (either base revision). Refuses any other ROM.
-- The vanilla-family sibling is grant_all_vanilla.lua; the two are separate because this build's
-- bag is enlarged, its WRAM is rearranged and its item ids are renumbered, so nothing carries over.
--
-- CLAUDE.md permits this as dev-only test tooling: a probe, never an adapter. It writes WRAM, not
-- the save -- an in-game save afterwards makes it permanent. It saves a state to SLOT 6 first.
-- Note it hands the player things Archipelago's own logic expects to GRANT; use it in a throwaway
-- AP game, never one whose multiworld matters.
--
-- HOW THE ADDRESSES WERE MEASURED, 2026-09-09 -- from the cartridge, never derived from vanilla:
--   * the pack menu headers (`engine/items/pack.asm` in pokecrystal: `db 5, 8 ; rows, columns`,
--     `db SCROLLINGMENU_ITEMS_QUANTITY`, `dbw 0, <pocket count address>`) were scanned for across
--     the whole ROM. On vanilla V1.0 and Speedchoice the scan returns exactly the `.sym`'s three
--     pockets (D892 / D8BC / D8D7), which is what makes it trustworthy; on both AP ROMs it returns
--     D866 / D960 / D989 -- and D960 and D989 are the two addresses ap_bag_grant.lua had already
--     confirmed ON SCREEN (a bike appeared; one Ultra Ball counted), so the third is the items
--     pocket, and the key-item pocket is 39 deep (D960..D989, less count and terminator).
--   * the engine-flag table (`data/events/engine_flags.asm`: `dwb address, bit`) has a signature
--     nothing else in the ROM has -- eight entries on one address with bits 1,2,4..128, then eight
--     on address+1 -- and its first hit is the badge pair on vanilla (D857/D858, the `.sym`) and
--     on Speedchoice. On both AP ROMs the first hit is D82B/D82C.
--   * wTMsHMs sits between the badges and the items pocket on every build (`ram/wram.asm`):
--     D82D..D865 on AP is 57 bytes, exactly NUM_TMS 50 + NUM_HMS 7, the same as vanilla -- the
--     apworld's own `tmhm` table lists 50 TMs and 7 HMs (its extra entries are move tutors).
--   * item ids from the apworld's `data.json` `items` table (MIT, `agent_docs/licensing.md`):
--     BICYCLE 6 -- confirmed on screen 2026-08-26 -- and SUPER_ROD 56 ($38). The HM ITEM ids
--     there (F8..FE) do not matter here: the HM pocket is indexed by HM number, not item id.
--   Not measured, so NOT done here: the Select-registration pair. Register the bike by hand.
-- Everything written is read back through the same reads and logged.
--
-- Dev-loader contract; acts once in the overworld. TAKE IT OFF THE TARGET AFTERWARDS.
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
