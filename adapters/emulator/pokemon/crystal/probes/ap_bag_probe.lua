-- MeshGhost — Pokémon Crystal/Archipelago: find the BAG (item, key-item and ball pockets)
--
-- READ-ONLY. Writes nothing. Its output is what `ap_bag_grant.lua` needs before it may write.
--
-- WHY
-- `grant_items.lua` refuses on anything but vanilla V1.0, and that refusal is correct: it writes
-- the bag at addresses from our own hash-verified pokecrystal build, and the Archipelago patch
-- moves WRAM non-uniformly (+7 for the coordinate block, +6 for the object array, -0x2A for the
-- map-object table -- three different deltas, none recoverable from another). Writing vanilla's
-- bag offsets into that build's RAM would corrupt whatever actually lives there. So the bike --
-- which is the only way to reach that build's FOURTH GAIT, its faster bike -- needs this address
-- measured first.
--
-- THE SIGNATURE, and it is a strong one because it is three pockets in a row
-- `ram/wram.asm` lays the bag out as three consecutive pockets, each a count byte followed by its
-- entries and a terminator:
--
--   wNumItems    db          wItems     ds MAX_ITEMS * 2 + 1    (id, quantity) pairs
--   wNumKeyItems db          wKeyItems  ds MAX_KEY_ITEMS + 1    bare ids, NO quantity byte
--   wNumBalls    db          wBalls     ds MAX_BALLS * 2 + 1    (id, quantity) pairs
--
-- **The key-item pocket having no quantity byte is the one difference that would corrupt the bag
-- if assumed away**, which is why it is cited rather than remembered. Vanilla's capacities are 20
-- items, 25 key items and 12 balls (`constants/item_data_constants.asm`).
--
-- THE STRIDES ARE SEARCHED, NOT ASSUMED, and that is deliberate. A patch is free to change the
-- capacities, which moves every pocket after the first -- so this probe finds an item pocket, then
-- looks FORWARD for a key-item pocket, then forward again for a ball pocket, and REPORTS the gaps
-- it found. An assumed stride would silently land in the middle of a resized pocket and produce a
-- confident wrong address, which is the exact failure mode the three refuted WRAM deltas above
-- already cost this build once.
--
-- Each pocket is validated by its own shape: the count is within capacity, every entry has a
-- non-zero id, every quantity is 1-99 where the pocket has quantities, and the byte immediately
-- past the last entry is the $FF terminator. Three of those in sequence is not something unrelated
-- RAM does by accident.
--
-- HOW TO RUN -- instant, nothing to time, no input
--   Add it to a dev loader target, or open it in the Lua Console. It scans once, reports, and then
--   does nothing for the rest of the session. Log: ap_bag_<timestamp>.log beside this file.
--
--   It is safe on ANY build -- run it on vanilla too, where it must find the pocket at the address
--   this repo already knows (wNumItems 0xD892 -> flat 0x1892). **That is the check that makes a
--   hit on the patched build worth trusting**, and it costs one extra run.

local DOMAIN = "WRAM"
local WRAM_SIZE = 0x8000

-- Generous upper bounds, not vanilla's exact capacities: the point is to accept a resized pocket
-- rather than to insist on the size we already know. A count past these is not a pocket.
local MAX_COUNT = 200
local MAX_GAP = 0x400 -- how far past one pocket to look for the next

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		local d = info.source:sub(2):match("^(.*)[/\\]")
		if d and #d > 0 then
			return d
		end
	end
	return "."
end

local logfile = io.open(string.format("%s/ap_bag_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function say(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		pcall(function() logfile:flush() end)
	end
end

local function u8(a)
	local ok, v = pcall(memory.read_u8, a, DOMAIN)
	return (ok and type(v) == "number") and v or nil
end

-- Validate one pocket at `a`. `paired` says whether entries carry a quantity byte.
-- Returns the entry count and the total byte length (count byte + entries + terminator), or nil.
local function pocketAt(a, paired)
	local n = u8(a)
	if not n or n > MAX_COUNT then
		return nil
	end
	local stride = paired and 2 or 1
	for i = 0, n - 1 do
		local id = u8(a + 1 + i * stride)
		if not id or id == 0 or id == 0xFF then
			return nil -- a live entry is never empty and never the terminator
		end
		if paired then
			local q = u8(a + 2 + i * stride)
			if not q or q == 0 or q > 99 then
				return nil
			end
		end
	end
	if u8(a + 1 + n * stride) ~= 0xFF then
		return nil -- the terminator must sit immediately past the last entry
	end
	return n, 1 + n * stride + 1
end

local function contents(a, n, paired, cap)
	local out, stride = {}, paired and 2 or 1
	for i = 0, math.min(n, cap) - 1 do
		local id = u8(a + 1 + i * stride)
		if paired then
			out[#out + 1] = string.format("%02X x%d", id, u8(a + 2 + i * stride) or 0)
		else
			out[#out + 1] = string.format("%02X", id)
		end
	end
	return table.concat(out, " ") .. (n > cap and " ..." or "")
end

say("=== MeshGhost Crystal/AP bag probe (READ-ONLY) ===")
local t = {}
for i = 0, 9 do
	local c = memory.read_u8(0x134 + i, "ROM")
	t[#t + 1] = c and string.char(c) or "?"
end
say(string.format("ROM title %q", table.concat(t)))
say("Looking for three consecutive pockets: items (paired), key items (BARE ids), balls (paired).")

-- LIST EVERY POCKET-SHAPED THING IN THE PLAYER-DATA BANK, both kinds, and let a human match them
-- against the in-game bag. The triple-in-a-row search this replaces returned exactly one hit, at
-- flat 0x636B -- a region the game does not keep player data in, whose "key items" were 7F 5F 50
-- 7F ... repeating. It validated something; it did not find the bag. Requiring three pockets in
-- sequence assumed strides that a build which RESIZES its pockets does not have, and the failure
-- was silent and confident, which is the worst combination.
--
-- Bounded to flat 0x1000-0x2800 -- CPU $D000-$E800, bank 1, where the player's own data lives.
-- Vanilla's bag sits at 0x1892 for reference, so the real one is somewhere in this window on any
-- build that has not moved it to another bank entirely.
--
-- EMPTY POCKETS ARE LISTED TOO (`00 FF` is a real, valid, empty pocket) but marked, because they
-- are also what unrelated zeroed RAM looks like -- there will be many, and none of them can be
-- told apart by shape. Only a pocket with CONTENTS can be matched against the screen.
local LO, HI = 0x1000, 0x2800
local hits = 0
say(string.format("listing every pocket-shaped run in 0x%04X-0x%04X (bank 1, player data)", LO, HI))
for a = LO, HI do
	for _, paired in ipairs({ true, false }) do
		local n, len = pocketAt(a, paired)
		if n and len then
			local kind = paired and "paired (items/balls)" or "bare   (key items) "
			if n == 0 then
				-- Counted, not printed: dozens of these are just zeroed RAM and printing them all
				-- would bury the handful that carry anything.
				hits = hits + 0
			else
				hits = hits + 1
				say(string.format("  0x%04X (CPU $%04X) %s count=%-3d len=%-4d : %s",
					a, (a < 0x1000) and (0xC000 + a) or (0xD000 + a - 0x1000),
					kind, n, len, contents(a, n, paired, 24)))
			end
		end
	end
end
say(string.format("%d non-empty pocket-shaped run(s). Match one against the BAG ON SCREEN before "
	.. "anything writes to it -- shape alone cannot identify the real one.", hits))

-- Scans once. Nothing per frame, so the tick does nothing at all.
if MESHGHOST_DEV_LOADER then
	MESHGHOST_DEV_TICK = function() end
end
