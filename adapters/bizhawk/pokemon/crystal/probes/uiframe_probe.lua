-- MeshGhost — Crystal: WHERE does this game draw a UI frame, and is it actually on screen?
--
-- READ-ONLY. Writes nothing, spawns nothing.
--
-- WHY
-- The drawn tier clips a peer against two things: the bottom text box, found by looking for the
-- frame's corner tile at ROW 12 ONLY, and the rectangle a MENU publishes in wMenuBorder*. The
-- user reported a third panel on 2026-08-19 -- the box an incoming PHONE CALL puts at the TOP of
-- the screen -- which neither test can see: it is not on row 12, and a text box was measured the
-- same day not to publish a menu rectangle.
--
-- Before generalising the row-12 test to every row, two things have to be measured rather than
-- assumed: which rows a frame actually appears on, and whether "frame tiles are in the tilemap"
-- means "a panel is on screen". This probe answers both.
--
-- WHAT IT FOUND ALREADY (2026-08-19, vanilla, New Bark Town)
-- Frame tiles at BG row 12 with WY parked at 144 -- i.e. the tiles were still in the tilemap
-- while NO panel was displayed, and they cleared a few seconds later as the camera scrolled
-- different terrain into that row. So a naive "scan every row for the corner tile" WILL fire with
-- nothing on screen, and would hide drawn peers for no reason -- the same shape as the bug that
-- emptied the bottom half of the screen earlier that day. Any generalised test needs the
-- visibility half too: LCDC bit 5 (window enabled) and WY <= 143 / WX <= 166.
--
-- HOW TO RUN
--   1. Load Crystal, stand in the overworld.
--   2. Lua Console -> Script -> Open, pick this file (or add it to a dev-loader control file).
--   3. Play. Open a text box, open the START menu, cross a map boundary for the location banner,
--      and -- the case this exists for -- let a phone call come in.
--      Log: uiframe_<timestamp>.log beside this script. It writes a line only when the set of
--      frames on screen CHANGES, so a quiet session stays short.

local CORNER, EDGE = 121, 122 -- LoadFrame copies the six frame tiles to vTiles2 tile $79 = 121,
-- so the top-left corner is 121 and the edge beside it 122, whichever of the nine frame STYLES
-- the player picked (the style changes the graphics at those ids, not the ids).
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
	-- BOTH tilemaps, and say which one. LCDC bit 3 selects the BACKGROUND's map and bit 6 the
	-- WINDOW's; they are often different maps, so reading only one can find a panel that is not
	-- on screen or miss one that is.
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
	-- The window layer is only VISIBLE where WY <= 143 and WX <= 166, and this game parks WY at
	-- 144 to hide a panel rather than erasing its tiles. "Frame tiles exist" and "a panel is on
	-- screen" are therefore different questions, and only the second should ever hide a ghost.
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
