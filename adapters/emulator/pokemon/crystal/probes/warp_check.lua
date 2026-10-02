-- Read-only, one shot after MESHGHOST_WARPCHECK_WAIT frames: where a warp put us, as the map bytes and a screenshot,
-- because a grey screen is a rendering symptom and the memory may be fine. Flushes and closes at once, so its output
-- exists whatever happens next.

local DIR
do
	DIR = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		DIR = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
end

local function u8(a) return memory.read_u8(a, "System Bus") or 0 end

-- meshghost_crystal.lua's vanilla V1.0 addresses, from a hash-verified build.
local W_MAPGROUP, W_MAPNUM, W_YCOORD, W_XCOORD = 0xDCB5, 0xDCB6, 0xDCB7, 0xDCB8
local W_MAPSTATUS, W_BATTLEMODE = 0xD432, 0xD22D
local OBJ = 0xD4D6
local F = { sprite = 0x00, tile = 0x02, mx = 0x10, my = 0x11, sx = 0x17, sy = 0x18 }
-- wStatusFlags in our build's .sym, which holds the Flash bit; printed raw, not interpreted.
local W_STATUSFLAGS = 0xD84C

local n, done = 0, false
local WAIT = tonumber(MESHGHOST_WARPCHECK_WAIT) or 240
local TAG = tostring(MESHGHOST_WARPCHECK_TAG or "warp")

MESHGHOST_DEV_TICK = function()
	if done then return end
	n = n + 1
	if n < WAIT then return end
	done = true

	local f = io.open(DIR .. "/warp_check_" .. TAG .. ".log", "w")
	if not f then
		console.log("warp_check: could not open its log")
		return
	end
	f:write(string.format("=== warp_check [%s] at frame %d (waited %d) ===\n",
		TAG, emu.framecount(), WAIT))
	f:write(string.format("map        = %d:%d\n", u8(W_MAPGROUP), u8(W_MAPNUM)))
	f:write(string.format("wX,wY      = %d,%d   (window origin, NOT the player -- documentation.md)\n",
		u8(W_XCOORD), u8(W_YCOORD)))
	f:write(string.format("mapStatus  = %d   (2 = HANDLE, the steady overworld state)\n",
		u8(W_MAPSTATUS)))
	f:write(string.format("battleMode = %d\n", u8(W_BATTLEMODE)))
	f:write(string.format("statusFlags= %02X  (raw; the FLASH bit lives in here)\n",
		u8(W_STATUSFLAGS)))
	f:write(string.format("player obj : sprite=%d tilebase=%02X map=%d,%d screen=%d,%d\n",
		u8(OBJ + F.sprite), u8(OBJ + F.tile), u8(OBJ + F.mx), u8(OBJ + F.my),
		u8(OBJ + F.sx), u8(OBJ + F.sy)))

	-- Zero live sprites (a full-screen menu shows 0) separates a dark map from nothing being drawn.
	local live = 0
	for e = 0, 39 do
		local y = memory.read_u8(e * 4, "OAM") or 0
		if y ~= 0 and y < 160 then live = live + 1 end
	end
	f:write(string.format("live OAM   = %d   (0 means the overworld is not being drawn)\n", live))

	-- A first tilemap row of one value is a blank screen, what a grey frame looks like from memory.
	local same, first = true, memory.read_u8(0x9800, "System Bus")
	for i = 1, 19 do
		if memory.read_u8(0x9800 + i, "System Bus") ~= first then same = false break end
	end
	f:write(string.format("BG row 0   = %s (first tile %02X)\n",
		same and "ALL ONE TILE -- blank screen" or "varied -- a real map is drawn",
		first or 0))
	f:flush()
	f:close()
	pcall(function() client.screenshot(DIR .. "/warp_check_" .. TAG .. ".png") end)
	console.log("warp_check[" .. TAG .. "]: dumped + screenshot")
end
