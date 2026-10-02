-- Pokémon Crystal: which screen rows a UI frame appears on, and whether frame tiles in the tilemap mean a panel is
-- on screen. Read-only; play through a text box, the START menu, a location banner and a phone call. A line is
-- logged only when the set of frames on screen changes.

local CORNER, EDGE = 121, 122 -- the frame's corner and edge tile ids, whichever frame style the player picked
local BGMAP_LO, BGMAP_HI = 0x1800, 0x1C00 -- 0x9800 / 0x9C00
local SAMPLE_EVERY = 10

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end

local logfile = io.open(string.format("%s/uiframe_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")
local function log(m)
	console.log(m)
	if logfile then logfile:write(os.date("%H:%M:%S ") .. m .. "\n") logfile:flush() end
end

local frames, lastSig = 0, nil

local function scan()
	local lcdc = memory.read_u8(0xFF40, "System Bus") or 0
	-- Both tilemaps: LCDC bit 3 selects the background's map and bit 6 the window's, and they often differ.
	local maps = {
		{ name = "bg", addr = ((lcdc & 0x08) ~= 0) and BGMAP_HI or BGMAP_LO },
		{ name = "win", addr = ((lcdc & 0x40) ~= 0) and BGMAP_HI or BGMAP_LO },
	}
	local hits = {}
	for mi = 1, #maps do
		local base0 = maps[mi].addr
		for row = 0, 17 do
			local base = base0 + row * 32
			for col = 0, 19 do
				local a = memory.read_u8(base + col, "VRAM") or 0
				local b = memory.read_u8(base + col + 1, "VRAM") or 0
				if a == CORNER and b == EDGE then
					local w = 0
					while col + 1 + w <= 19
						and (memory.read_u8(base + col + 1 + w, "VRAM") or 0) == EDGE do
						w = w + 1
					end
					hits[#hits + 1] = string.format("%s row=%d col=%d edgerun=%d",
						maps[mi].name, row, col, w)
				end
			end
		end
	end
	-- The window shows only where WY <= 143 and WX <= 166, and this game parks WY at 144 rather than erasing a
	-- panel's tiles: only a panel actually on screen should hide a ghost.
	local wy = memory.read_u8(0xFF4A, "System Bus") or 0
	local wx = memory.read_u8(0xFF4B, "System Bus") or 0
	hits[#hits + 1] = string.format("lcdc=%02X winon=%s wy=%d wx=%d",
		lcdc, ((lcdc & 0x20) ~= 0) and "yes" or "no", wy, wx)
	return hits
end

local function tick()
	frames = frames + 1
	if frames % SAMPLE_EVERY ~= 0 then return end
	local sig = table.concat(scan(), " | ")
	if sig ~= lastSig then
		lastSig = sig
		log(sig)
	end
end

log("uiframe probe: scanning both tilemaps for frame corner " .. CORNER .. " on every row")

if MESHGHOST_DEV_LOADER then
	MESHGHOST_DEV_TICK = tick
	MESHGHOST_DEV_UNLOAD = function()
		log("uiframe probe unloaded")
		if logfile then logfile:close() logfile = nil end
	end
else
	while true do
		tick()
		emu.frameadvance()
	end
end
