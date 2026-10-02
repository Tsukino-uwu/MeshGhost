-- Pokémon Crystal: whether the tiles text is read from hold the font right now. Read-only; load it beside the
-- autoplay driver and restore or reach each state. Text ids 0x80-0xFF are letters only while the font is in those
-- tiles, so this logs LCDC and FNV-1a checksums of the letters' tiles (0x80-0xB9, and 0x80 alone) in both VRAM
-- banks. It cannot see which bank a given cell uses: that is the attribute map.

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
	-- 0x80-0xFF sit at 0x0800 + (id - 0x80) * 16 either way; 0x00-0x7F at 0x1000 + id * 16 with LCDC bit 4 clear.
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
