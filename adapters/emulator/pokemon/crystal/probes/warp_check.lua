-- WHERE DID A WARP ACTUALLY PUT US -- read-only, one dump plus a screenshot, then quiet.
--
-- WHY IT EXISTS. `goto_map.lua` warped to Ice Path 1F and the user reported *"the screen is just
-- grey"* -- and `goto_map`'s own log was EMPTY, because it buffers and only flushes every 20
-- lines, so a warp that writes a handful of lines reports nothing at all. That is `pitfalls.md`'s
-- "an empty log reads exactly like the game did nothing", in the file whose own header cites it.
-- This probe flushes and closes immediately, so its output exists whatever happens next.
--
-- A GREY SCREEN IS A RENDERING SYMPTOM AND THE MEMORY MAY BE FINE, so this prints both halves:
-- the map bytes (did we land where we asked?) and a screenshot (what is actually on screen). The
-- engine draws the map itself, so `client.screenshot` genuinely captures it -- unlike the drawn
-- ghost tier, this is a case pictures are FOR.
--
-- Read-only: no writes, no input, no savestate.

local DIR
do
	DIR = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		DIR = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
end

local function u8(a) return memory.read_u8(a, "System Bus") or 0 end

-- Addresses from meshghost_crystal.lua's vanilla V1.0 table (a hash-verified pokecrystal build).
local W_MAPGROUP, W_MAPNUM, W_YCOORD, W_XCOORD = 0xDCB5, 0xDCB6, 0xDCB7, 0xDCB8
local W_MAPSTATUS, W_BATTLEMODE = 0xD432, 0xD22D
local OBJ = 0xD4D6
local F = { sprite = 0x00, tile = 0x02, mx = 0x10, my = 0x11, sx = 0x17, sy = 0x18 }
-- wStatusFlags carries the FLASH bit; a cave without it is drawn dark, which is one of the two
-- things a "grey screen" can be. $d84c is wStatusFlags in this build's map (ram/wram.asm order:
-- it sits with the other save-block flags); printed raw and NOT interpreted as fact.
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

	-- HOW MANY SPRITES ARE LIVE. Zero is the adapter's own "is the overworld actually being
	-- drawn" test (`pitfalls.md`, 2026-08-19: a full-screen menu shows exactly 0), so it
	-- separates "the map is up and dark" from "nothing is being drawn at all".
	local live = 0
	for e = 0, 39 do
		local y = memory.read_u8(e * 4, "OAM") or 0
		if y ~= 0 and y < 160 then live = live + 1 end
	end
	f:write(string.format("live OAM   = %d   (0 means the overworld is not being drawn)\n", live))

	-- The first row of the tilemap: all one value means a blank/unloaded screen, which is what a
	-- grey frame looks like from the memory side.
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
