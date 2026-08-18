-- MeshGhost — Pokémon Emerald: test-state kit (DEVELOPMENT TOOL, never shipped)
--
-- WHAT THIS IS FOR
-- The open Emerald item is surf / Mach Bike / Acro Bike / ledges (agent_docs/phases/phase8.md):
-- the ghost snaps badly on all of them because the adapter only classifies walking, running and
-- idle. Testing that needs a save that HAS a bike and can surf, which is an hour of play per
-- attempt on a fresh file. This puts the game into those states in one second.
--
-- WHY NOT CHEAT CODES. Tried first, 2026-08-18, and it failed in a way worth remembering:
-- BizHawk accepted Emerald GameShark codes without error, decoded them to nonsense (address
-- 0x0000000E), and marked them ACTIVE, writing garbage every frame. The popular Emerald codes are
-- GameShark v3 / CodeBreaker, both encrypted, and this build decrypts neither. Even the ones that
-- look decodable are not verifiable: `82005274 0YYY` is `gHeap + 0x5274`, an unnamed heap offset.
-- See agent_docs/pitfalls.md. Everything below instead writes the real save structure at offsets
-- that come from our own make-compare-verified pokeemerald build, so each one can be checked.
--
-- THIS IS A CHEAT, AND IT PERSISTS IF YOU SAVE.
-- MeshGhost itself never does any of this -- the adapter's writes are cosmetic object RAM only,
-- and that boundary is the point of the spawn ADR. This is a tester's tool, deliberately a
-- separate file, and it is never part of a release. But be clear-eyed: unlike the adapter's live
-- RAM writes, these land in SaveBlock1, so **saving the game afterwards makes them permanent**.
-- Use a save file you do not mind changing.
--
-- ADDRESSES, all from pokeemerald (include/global.h's /*0xNNN*/ offsets, include/constants):
--   gSaveBlock1Ptr  0x03005D8C   gSaveBlock2Ptr  0x03005D90
--   SaveBlock2 +0xAC   encryptionKey (u32)
--   SaveBlock1 +0x560  bagPocket_Items[30]     -- struct ItemSlot { u16 itemId; u16 quantity; }
--   SaveBlock1 +0x5D8  bagPocket_KeyItems[30]
--   SaveBlock1 +0x1270 flags[]                 -- FLAG_BADGE01_GET = SYSTEM_FLAGS + 7 = 0x867
--   Item ids: ITEM_MACH_BIKE 259, ITEM_ACRO_BIKE 272, ITEM_SUPER_ROD 264
-- **A bag quantity is XOR-encrypted with SaveBlock2's encryptionKey** (item.c's
-- SetBagItemQuantity) -- writing a plain 1 there gives an item with a nonsense count.
--
-- HOW TO RUN
--   Edit WANTED below, then point dev-scripts/bizhawk-dev-loader.target at this file. It counts
--   down, applies once, reads everything back independently, and stops.

-- ---------------------------------------------------------------------------------------------
-- What to give. Set to false to skip.
-- ---------------------------------------------------------------------------------------------
local WANTED = {
	mach_bike = true,   -- ITEM_MACH_BIKE  259 (0x103)
	acro_bike = true,   -- ITEM_ACRO_BIKE  272 (0x110)
	super_rod = true,   -- ITEM_SUPER_ROD  264 (0x108)
	badges = true,      -- all 8, so HM moves are usable outside battle
}

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GSAVEBLOCK2PTR_ADDR = 0x03005d90
local SB2_ENCRYPTIONKEY = 0xac
local SB1_BAG_ITEMS = 0x560
local SB1_BAG_KEYITEMS = 0x5d8
local SB1_FLAGS = 0x1270
local BAG_KEYITEMS_COUNT = 30
local ITEM_SLOT_SIZE = 4

local FLAG_BADGE01_GET = 0x867 -- SYSTEM_FLAGS (0x860) + 7
local NUM_BADGES = 8

local KEY_ITEMS = {
	{ key = "mach_bike", id = 259, name = "Mach Bike" },
	{ key = "acro_bike", id = 272, name = "Acro Bike" },
	{ key = "super_rod", id = 264, name = "Super Rod" },
}

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local CB2_OVERWORLD_ARCHIPELAGO_ADDR = 0x080867f1

local logfile
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/testkit_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
end

local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
	end
end

local function u8(a) return memory.read_u8(a) end
local function u16(a) return memory.read_u16_le(a) end
local function u32(a) return memory.read_u32_le(a) end
local function w8(a, v) memory.write_u8(a, v & 0xff) end
local function w16(a, v) memory.write_u16_le(a, v & 0xffff) end

local function inOverworld()
	local cb = u32(GMAIN_CALLBACK2_ADDR)
	return cb == CB2_OVERWORLD_ADDR or cb == CB2_OVERWORLD_ADDR + 1
		or cb == CB2_OVERWORLD_ARCHIPELAGO_ADDR or cb == CB2_OVERWORLD_ARCHIPELAGO_ADDR + 1
end

-- Both save blocks are reached through pointers the game keeps in IWRAM, so this works on a
-- relocated (Archipelago) ROM too -- the pointer moves the data, not the pointer's own address.
-- Still checked rather than assumed: a pointer that is not in EWRAM means no save is loaded yet.
local function saveBlocks()
	local sb1, sb2 = u32(GSAVEBLOCK1PTR_ADDR), u32(GSAVEBLOCK2PTR_ADDR)
	local function plausible(p) return p >= 0x02000000 and p < 0x02040000 end
	if not plausible(sb1) or not plausible(sb2) then return nil end
	return sb1, sb2
end

local function keyItemSlotAddr(sb1, i) return sb1 + SB1_BAG_KEYITEMS + i * ITEM_SLOT_SIZE end

local function findKeyItem(sb1, itemId)
	for i = 0, BAG_KEYITEMS_COUNT - 1 do
		if u16(keyItemSlotAddr(sb1, i)) == itemId then return i end
	end
	return nil
end

local function firstFreeKeyItemSlot(sb1)
	for i = 0, BAG_KEYITEMS_COUNT - 1 do
		if u16(keyItemSlotAddr(sb1, i)) == 0 then return i end
	end
	return nil
end

local function giveKeyItem(sb1, key, itemId, name)
	if findKeyItem(sb1, itemId) then
		log(string.format("  %-10s already in the bag, left alone.", name))
		return
	end
	local slot = firstFreeKeyItemSlot(sb1)
	if not slot then
		log(string.format("  %-10s NOT GIVEN: the key items pocket is full.", name))
		return
	end
	local addr = keyItemSlotAddr(sb1, slot)
	w16(addr, itemId)
	-- The quantity is XOR-encrypted with SaveBlock2's key (item.c's SetBagItemQuantity). A plain
	-- 1 here shows up as a nonsense count and the item can behave as if absent.
	w16(addr + 2, 1 ~ key)
	log(string.format("  %-10s -> key item slot %d (id %d)", name, slot, itemId))
end

local function setBadges(sb1)
	for b = 0, NUM_BADGES - 1 do
		local flagId = FLAG_BADGE01_GET + b
		local addr = sb1 + SB1_FLAGS + (flagId // 8)
		w8(addr, u8(addr) | (1 << (flagId % 8)))
	end
	log("  badges     -> all 8 set")
end

-- ---------------------------------------------------------------------------------------------

log("=== MeshGhost Emerald test-state kit (WRITES SAVE DATA -- persists if you save) ===")
if not memory.usememorydomain("System Bus") then
	log("FATAL: could not select the System Bus memory domain.")
	MESHGHOST_DEV_TICK = function() end
	return
end

local COUNTDOWN_FRAMES = 300
local frames, done = 0, false

local function apply()
	local sb1, sb2 = saveBlocks()
	if not sb1 then
		log("REFUSING: no save loaded yet (save block pointers are not EWRAM addresses).")
		return false
	end
	local key = u32(sb2 + SB2_ENCRYPTIONKEY)
	log(string.format("SaveBlock1 0x%08X  SaveBlock2 0x%08X  encryptionKey 0x%08X", sb1, sb2, key))

	for _, item in ipairs(KEY_ITEMS) do
		if WANTED[item.key] then giveKeyItem(sb1, key, item.id, item.name) end
	end
	if WANTED.badges then setBadges(sb1) end

	-- Read back through the same decode the GAME uses, not the values just written: an echo of
	-- our own write proves the write landed, not that the game will agree with it.
	log("verifying, by reading the bag back and decrypting quantities the way item.c does:")
	for i = 0, BAG_KEYITEMS_COUNT - 1 do
		local addr = keyItemSlotAddr(sb1, i)
		local id = u16(addr)
		if id ~= 0 then
			log(string.format("  key slot %2d: item %3d x%d", i, id, u16(addr + 2) ~ key))
		end
	end
	if WANTED.badges then
		local got = 0
		for b = 0, NUM_BADGES - 1 do
			local flagId = FLAG_BADGE01_GET + b
			if (u8(sb1 + SB1_FLAGS + (flagId // 8)) >> (flagId % 8)) & 1 == 1 then got = got + 1 end
		end
		log(string.format("  badges set: %d of %d", got, NUM_BADGES))
	end
	log("Done. Open the bag to confirm on screen -- a count read back correctly here still only")
	log("proves the bytes agree with item.c's decode, not that the game shows the item.")
	return true
end

MESHGHOST_DEV_TICK = function()
	if done then return end
	frames = frames + 1
	if not inOverworld() then
		if frames % 300 == 0 then log("waiting: not in the overworld with a save loaded yet.") end
		return
	end
	if frames % 60 == 0 and frames < COUNTDOWN_FRAMES then
		log(string.format("applying in %d...", (COUNTDOWN_FRAMES - frames) // 60))
	end
	if frames >= COUNTDOWN_FRAMES then
		done = true
		apply()
	end
end

if not MESHGHOST_DEV_LOADER then
	while true do
		local ok, err = pcall(MESHGHOST_DEV_TICK)
		if not ok then log("testkit error: " .. tostring(err)) end
		emu.frameadvance()
	end
end
