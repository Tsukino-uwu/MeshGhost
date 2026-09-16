-- MeshGhost — Pokémon Emerald: the party, the bag, money and badge flags, raw (DEV TOOL, READ-ONLY,
-- never shipped) -- 2026-09-16
--
-- WHY THIS EXISTS. autoplay's Phase 1 wants `observe` to say what this SAVE has -- its party, bag and
-- badges (`agent_docs/phases/phase13.md`; the play-game skill's "check what this save has"). What each
-- byte means is to be measured: this logs them raw whenever any of them changes, so a dump can be read
-- against captures of the party menu, the summary pages, the bag and the trainer card.
--
-- ADDRESSES: a pokeemerald build whose ROM hashed identical to the vanilla ROM this runs on (SHA-1
-- compared 2026-09-16) proves where each lives, not what its bytes mean. Vanilla only. The decomp's
-- struct layouts said where to look inside them; every candidate below is printed NEXT TO its raw
-- bytes, so a wrong guess shows as a decode that disagrees with the screen.
--
-- WHAT IT LOGS (party_bag_probe_<target>_<time>.log beside this file; gitignored), on change only:
--   KEY    the save pointers and SaveBlock2 +0xAC (the word the decomp names encryptionKey)
--   MON n  each of the 6 slots named gPlayerParty (0x64 bytes): raw hex in three parts (+0x00 32
--          bytes, +0x20 48 bytes, +0x50 20 bytes); the +0x08 name decoded; the 48 bytes XORed per
--          word with (+0x00 ^ +0x04) and split into four 12-byte blocks, raw; the u16 sum of those
--          decrypted words beside +0x1C; each block's words read as a species id and as move ids
--          against the ROM's name tables (candidates only); whether SaveBlock1's copy at +0x238
--          matches the live slot
--   POCKET every non-empty slot of the five SaveBlock1 pockets and the PC's: id, quantity raw and XOR
--          the key's low half, and the ROM item-table entry at 44 bytes per id (its name, then
--          +0x0E..+0x1B raw)
--   MONEY  SaveBlock1 +0x490 raw and XOR the key; +0x494 raw and XOR the key's low half; +0x496
--   FLAGS  SaveBlock1 +0x1270's bytes 0x100-0x11F (flag ids 0x800-0x8FF if a flag is a bit per id)
-- WHAT IT CANNOT SEE: which block is which (the dump does not assume an order); anything the game
-- computes rather than stores (stats shown on a page it has not drawn, a menu's own copies); flags
-- outside the logged range; a patched ROM.

local BUS = "System Bus"
local SB1PTR, SB2PTR = 0x03005d8c, 0x03005d90
local PARTY_COUNT, PARTY, MON_SIZE = 0x020244e9, 0x020244ec, 0x64
local SPECIES_NAMES, SPECIES_LEN, SPECIES_COUNT = 0x083185c8, 11, 412
local MOVE_NAMES, MOVE_LEN, MOVE_COUNT = 0x0831977c, 13, 355
local ITEMS, ITEM_SIZE, ITEM_COUNT = 0x085839a0, 44, 377
local POCKETS = {
	{ "items", 0x560, 30 }, { "key_items", 0x5D8, 30 }, { "balls", 0x650, 16 },
	{ "tmhm", 0x690, 64 }, { "berries", 0x790, 46 }, { "pc", 0x498, 50 },
}

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local target = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "default"):gsub("[^%w_%-]", "_")
local logf = io.open(string.format("%s/party_bag_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
local pending = {}
local function log(s) pending[#pending + 1] = string.format("f%d %s", emu.framecount(), s) end
local function flush()
	if logf and #pending > 0 then
		logf:write(table.concat(pending, "\n"), "\n")
		logf:flush() -- on a change or a timer, never per frame
		pending = {}
	end
end

local function r8(a) return memory.read_u8(a, BUS) end
local function r16(a) return memory.read_u16_le(a, BUS) end
local function r32(a) return memory.read_u32_le(a, BUS) end
local function bytes(a, n) return memory.read_bytes_as_array(a, n, BUS) end
local function hexOf(b, from, to)
	local out = {}
	for i = from, to do out[#out + 1] = string.format("%02X", b[i]) end
	return table.concat(out)
end

-- Letters, digits and the space only (emerald/MEASURED.md, the encoding entry); everything else raw.
local function decode(b, from, to)
	local out = {}
	for i = from, to do
		local c = b[i]
		if c == 0xFF then break end
		if c >= 0xBB and c <= 0xD4 then
			out[#out + 1] = string.char(0x41 + c - 0xBB)
		elseif c >= 0xD5 and c <= 0xEE then
			out[#out + 1] = string.char(0x61 + c - 0xD5)
		elseif c >= 0xA1 and c <= 0xAA then
			out[#out + 1] = tostring(c - 0xA1)
		elseif c == 0x00 then
			out[#out + 1] = " "
		else
			out[#out + 1] = string.format("{%02X}", c)
		end
	end
	return table.concat(out)
end
local function romName(tbl, len, count, id)
	if id < 1 or id >= count then return nil end
	return decode(bytes(tbl + id * len, len), 1, len)
end

local function u32of(b, i) return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24) end
local function u16of(b, i) return b[i] | (b[i + 1] << 8) end

local function dumpMon(slot, sb1)
	local at = PARTY + slot * MON_SIZE
	local b = bytes(at, MON_SIZE)
	local personality, otId = u32of(b, 1), u32of(b, 5)
	local copy = bytes(sb1 + 0x238 + slot * MON_SIZE, MON_SIZE)
	local same = true
	for i = 1, MON_SIZE do
		if copy[i] ~= b[i] then same = false end
	end
	log(string.format("MON %d @%08X pers=%08X otid=%08X name=%q sb1copy=%s", slot, at, personality, otId,
		decode(b, 9, 18), same and "same" or "differs"))
	log(string.format("MON %d raw00 %s", slot, hexOf(b, 1, 32)))
	log(string.format("MON %d raw20 %s", slot, hexOf(b, 33, 80)))
	log(string.format("MON %d raw50 %s", slot, hexOf(b, 81, 100)))
	if personality == 0 and otId == 0 then return end
	local key = personality ~ otId
	local dec, sum = {}, 0
	for w = 0, 11 do
		local v = u32of(b, 33 + w * 4) ~ key
		for k = 0, 3 do dec[#dec + 1] = (v >> (8 * k)) & 0xFF end
		sum = (sum + (v & 0xFFFF) + (v >> 16)) & 0xFFFF
	end
	log(string.format("MON %d decrypted-sum=%04X field1C=%04X", slot, sum, u16of(b, 29)))
	for blk = 0, 3 do
		local o = blk * 12
		local w = {}
		for k = 0, 5 do w[#w + 1] = u16of(dec, o + 1 + k * 2) end
		local species = romName(SPECIES_NAMES, SPECIES_LEN, SPECIES_COUNT, w[1])
		local moves = {}
		for k = 1, 4 do moves[#moves + 1] = romName(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, w[k]) or "-" end
		log(string.format("MON %d block%d %s | species? %s | moves? %s | item? %s", slot, blk, hexOf(dec, o + 1, o + 12),
			species or "-", table.concat(moves, ","), romName(ITEMS, ITEM_SIZE, ITEM_COUNT, w[2]) or "-"))
	end
	log(string.format("MON %d tail status=%08X level=%d mail=%02X hp=%d maxhp=%d atk=%d def=%d spe=%d spa=%d spd=%d",
		slot, u32of(b, 81), b[85], b[86], u16of(b, 87), u16of(b, 89), u16of(b, 91), u16of(b, 93), u16of(b, 95),
		u16of(b, 97), u16of(b, 99)))
end

local function dump()
	local sb1, sb2 = r32(SB1PTR), r32(SB2PTR)
	local key = r32(sb2 + 0xAC)
	log(string.format("KEY sb1=%08X sb2=%08X sb2+AC=%08X partycount=%d sb1+234=%d", sb1, sb2, key, r8(PARTY_COUNT),
		r8(sb1 + 0x234)))
	for slot = 0, 5 do dumpMon(slot, sb1) end
	for _, p in ipairs(POCKETS) do
		local b = bytes(sb1 + p[2], p[3] * 4)
		local n = 0
		for i = 0, p[3] - 1 do
			local id, q = u16of(b, i * 4 + 1), u16of(b, i * 4 + 3)
			if id ~= 0 then
				n = n + 1
				local e = (id < ITEM_COUNT) and bytes(ITEMS + id * ITEM_SIZE, ITEM_SIZE) or nil
				log(string.format("POCKET %s[%d] id=%d qraw=%04X q^key=%d | table %q %s", p[1], i, id, q, q ~ (key & 0xFFFF),
					e and decode(e, 1, 14) or "-", e and hexOf(e, 15, 28) or "-"))
			end
		end
		log(string.format("POCKET %s: %d non-empty of %d", p[1], n, p[3]))
	end
	local money, coins = r32(sb1 + 0x490), r16(sb1 + 0x494)
	log(string.format("MONEY raw=%08X ^key=%d coins raw=%04X ^key=%d registered=%d", money, money ~ key, coins,
		coins ~ (key & 0xFFFF), r16(sb1 + 0x496)))
	local f = bytes(sb1 + 0x1270 + 0x100, 0x20)
	local set = {}
	for i = 0x60, 0x7F do
		if (f[(i >> 3) + 1] >> (i & 7)) & 1 == 1 then set[#set + 1] = string.format("%03X", 0x800 + i) end
	end
	log(string.format("FLAGS bytes100-11F %s | bits set in 860-87F: %s", hexOf(f, 1, 0x20), table.concat(set, " ")))
	flush()
end

-- The change key: everything dumped, as one string.
local function state()
	local sb1 = r32(SB1PTR)
	local parts = {
		string.char(r8(PARTY_COUNT)),
		string.char(table.unpack(bytes(PARTY, 0x258))),
		string.char(table.unpack(bytes(sb1 + 0x490, 0x3B8))),
		string.char(table.unpack(bytes(sb1 + 0x1370, 0x20))),
	}
	return table.concat(parts)
end

local last, frames = nil, 0
log("party_bag_probe loaded")
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	if frames % 30 == 0 then
		local s = state()
		if s ~= last then
			last = s
			dump()
		end
	end
	if frames % 120 == 0 then flush() end
end
MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	flush()
	if logf then logf:close() end
	logf = nil
end
