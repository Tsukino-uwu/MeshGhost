-- MeshGhost — Pokémon Crystal: whether the tiles text is read from hold the font right now
-- (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-17
--
-- READ-ONLY. Load it beside the autoplay driver; restore or reach each state and let it log.
--
-- WHY. autoplay reads Crystal's text off the tile buffer, where ids 0x80-0xFF are letters -- while the font is
-- in those tiles. Elm's lab showed a Pokémon's picture drawn with the same ids (0x80-0xB0 in a framed box), and
-- `screen_text` read it as "AHOV:dk". What a tile id DRAWS is in video RAM, so this logs a checksum of the tiles
-- the letters use, to see whether one value holds on every screen whose text was read correctly and another
-- while a picture is up.
--
-- WHAT IT LOGS, on change: LCDC (FF40), and for tiles 0x80-0xB9 (A-Z, the six marks after it, a-z) a 32-bit
-- FNV-1a checksum of their 16 bytes a tile, and of tile 0x80 alone, in VRAM bank 0 and bank 1 at offset
-- 0x0800 + (id - 0x80) * 16 -- where tile ids 0x80-0xFF sit whichever way LCDC bit 4 is set. Which bank follows
-- the text is the reading. What it cannot see: which bank a given cell uses (the attribute map, not read here).
--
-- COST. Two 928-byte VRAM reads a frame. Log: crystal/logs/autoplay_font_<port>_<timestamp>.log.

local dir, port = ".", tostring(AUTOPLAY_PORT or os.getenv("AUTOPLAY_PORT") or "na")
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logdir = (dir:match("^(.*)/probes$") or dir) .. "/logs"
local logf = io.open(string.format("%s/autoplay_font_%s_%s.log", logdir, port, os.date("%Y%m%d_%H%M%S")), "w")
if logf then logf:setvbuf("full", 16384) end
local function log(s)
	if logf then logf:write(string.format("[%s f%d] %s\n", os.date("%H:%M:%S"), emu.framecount(), s)) end
end

local FIRST, COUNT = 0x80, 0x3A

local function fnv(bytes, from, to)
	local h = 0x811C9DC5
	for i = from, to do
		h = ((h ~ bytes[i]) * 0x01000193) & 0xFFFFFFFF
	end
	return h
end

local function sums(base)
	local b = memory.read_bytes_as_array(base, COUNT * 16, "VRAM")
	return string.format("%08X/%08X", fnv(b, 1, #b), fnv(b, 1, 16))
end

local last, frames = nil, 0
log("loaded")

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local lcdc = memory.read_u8(0xFF40, "System Bus")
	-- Tiles 0x60-0x7F sit at 0x1000 + id * 16 with LCDC bit 4 clear (it read E3 on every screen so far), 0xBA-0xFF
	-- at 0x0800 + (id - 0x80) * 16.
	local low = memory.read_bytes_as_array(0x1000 + 0x60 * 16, 0x20 * 16, "VRAM")
	local high = memory.read_bytes_as_array(0x0800 + 0x3A * 16, 0x46 * 16, "VRAM")
	local line = string.format("lcdc %02X bank0@0800 %s bank1@2800 %s low60-7F %08X high BA-FF %08X", lcdc,
		sums(0x0800), sums(0x2800), fnv(low, 1, #low), fnv(high, 1, #high))
	if line ~= last then
		log(line)
		last = line
	end
	if logf and frames % 120 == 0 then logf:flush() end
end

MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	if logf then
		logf:flush()
		logf:close()
	end
	logf = nil
end
