-- Pokémon Crystal: dumps a window of flat WRAM as hex, once, to the log only. Read-only; the instrument for when a
-- signature scan has just produced a confident wrong answer. Set MESHGHOST_WRAM_FROM and _TO first: flat offsets,
-- 0x0000-0x0FFF being bank 0 (CPU $C000) and 0x1000 up bank 1 (CPU $D000), where the player's data lives.

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

-- CPU address for a flat offset, the inverse of the adapter's flat(), so a dump reads against the .sym.
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
		-- A crude printable column: a run of names or a block of zeros shows at a glance.
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
