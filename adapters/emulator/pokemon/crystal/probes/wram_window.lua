-- MeshGhost — Pokémon Crystal: dump a window of WRAM as hex, and nothing else
--
-- READ-ONLY. The bluntest instrument in this folder, and the one to reach for when a signature
-- scan has just produced a confident wrong answer.
--
-- WHY IT EXISTS. `ap_bag_probe.lua` searched the Archipelago build for the bag by its own shape --
-- three pockets in a row, each a count, its entries and a terminator -- and returned exactly one
-- hit, in a region the game does not keep player data in, whose "key items" were `7F 5F 50 7F ...`
-- repeating. A validator that accepts something is not a validator that found the right thing, and
-- the sensible next move is not a cleverer filter: it is to look at the bytes. (`probes.md`, the
-- lesson this session paid for three times: dump everything, filter afterwards.)
--
-- Set the window with the globals below before loading, or edit the defaults. Flat WRAM offsets,
-- the same space the adapter's address tables use: 0x0000-0x0FFF is bank 0 (CPU $C000-$CFFF) and
-- 0x1000 upward is bank 1 (CPU $D000+), which is where the player's own data lives.
--
--   MESHGHOST_WRAM_FROM = 0x1800
--   MESHGHOST_WRAM_TO   = 0x1A00
--
-- Prints 16 bytes a line with the flat offset and the CPU address, once, to the log only -- a hex
-- dump is far too much for the emulator's console (`emulator/CLAUDE.md`: the console is a GUI
-- append, and one line a second already costs frames).

local DOMAIN = "WRAM"
local FROM = tonumber(MESHGHOST_WRAM_FROM) or 0x1800
local TO = tonumber(MESHGHOST_WRAM_TO) or 0x1A00

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

local logfile = io.open(string.format("%s/wram_window_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function w(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end

-- CPU address for a flat offset, so a dump can be read against pokecrystal's own symbols without
-- anyone doing the arithmetic in their head. The inverse of the adapter's `flat()`.
local function cpu(off)
	if off < 0x1000 then
		return 0xC000 + off
	end
	return 0xD000 + (off - 0x1000)
end

console.log(string.format("MeshGhost: dumping WRAM 0x%04X-0x%04X to the log file.", FROM, TO))
w(string.format("=== WRAM window 0x%04X-0x%04X (flat) ===", FROM, TO))
local t = {}
for i = 0, 9 do
	local c = memory.read_u8(0x134 + i, "ROM")
	t[#t + 1] = c and string.char(c) or "?"
end
w(string.format("ROM title %q", table.concat(t)))

for base = FROM, TO - 1, 16 do
	local bytes, ascii = {}, {}
	for i = 0, 15 do
		local v = memory.read_u8(base + i, DOMAIN) or 0
		bytes[#bytes + 1] = string.format("%02X", v)
		-- A crude printable column: item ids and counts mean nothing as text, but a run of names
		-- or a block of zeroes is instantly recognisable and costs one character per byte.
		ascii[#ascii + 1] = (v >= 32 and v < 127) and string.char(v) or "."
	end
	w(string.format("%04X (%04X)  %s  %s", base, cpu(base),
		table.concat(bytes, " "), table.concat(ascii)))
end
if logfile then
	pcall(function() logfile:flush() end)
end
console.log("MeshGhost: dump written.")

if MESHGHOST_DEV_LOADER then
	MESHGHOST_DEV_TICK = function() end
end
