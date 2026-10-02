-- Pokémon Crystal/Archipelago: lists every pocket-shaped run in bank 1, to find the bag `ap_bag_grant.lua` writes.
-- Read-only; scans once at load. The patch moves WRAM by a different delta per block, so vanilla's address won't do.
-- Run it on vanilla too, where it must find the item pocket at flat 0x1892: that makes a patched hit worth trusting.
-- Items and balls are (id, quantity) pairs and key items bare ids; a quantity byte assumed there corrupts the bag.

local DOMAIN = "WRAM"
local WRAM_SIZE = 0x8000

-- Generous bounds, not vanilla's capacities: a resized pocket still matches, and a count past them is not a pocket.
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

-- `paired`: entries carry a quantity byte. Returns the entry count and byte length with count and terminator, or nil.
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
		return nil
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

-- Every match is listed for a person to check against the bag on screen: a build may resize its pockets, so no
-- stride between them is assumed. Bank 1 (CPU $D000-$E800) is where the player's data lives.
local LO, HI = 0x1000, 0x2800
local hits = 0
say(string.format("listing every pocket-shaped run in 0x%04X-0x%04X (bank 1, player data)", LO, HI))
for a = LO, HI do
	for _, paired in ipairs({ true, false }) do
		local n, len = pocketAt(a, paired)
		if n and len then
			local kind = paired and "paired (items/balls)" or "bare   (key items) "
			if n == 0 then
				-- Empty pockets (`00 FF`) are skipped: zeroed RAM looks the same.
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

-- The dev loader expects a tick; this probe does its work at load.
if MESHGHOST_DEV_LOADER then
	MESHGHOST_DEV_TICK = function() end
end
