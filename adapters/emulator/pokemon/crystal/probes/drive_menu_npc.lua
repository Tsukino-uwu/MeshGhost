-- drive_menu_npc.lua -- INPUT-DRIVING, one-shot, any build: waits until some non-player OAM sprite
-- sits in the right half of the screen (where the START menu opens), presses START, and for two
-- seconds logs every live OAM entry plus the CGB attribute of a menu tile -- then presses B.
-- The question (2026-09-09, the five-build room): does THIS build draw a character that stands
-- under its START menu, or hide it? Vanilla clears the sprite engine and OAM for the menu;
-- Archipelago and Speedchoice keep sprites on, so the answer has to be read off their OAM.
-- Reads OAM and LCD registers only; needs no per-build address. Dev-loader contract; take it off
-- the target afterwards.
local port = os.getenv("MESHGHOST_BRIDGE_PORT") or "noport"
local f = io.open(string.format("%s/drive_menu_npc_%s_%s.log", (io.popen("cd"):read("*l") or "."), os.date("%Y%m%d_%H%M%S"), port), "w")
local function log(s) console.log(s); if f then f:write(os.date("%H:%M:%S "), s, "\n"); f:flush() end end
local function oam()
	local out, live = {}, 0
	for i = 0, 39 do
		local y, x, tile, attr = memory.read_u8(i * 4, "OAM"), memory.read_u8(i * 4 + 1, "OAM"), memory.read_u8(i * 4 + 2, "OAM"), memory.read_u8(i * 4 + 3, "OAM")
		if y > 0 and y < 160 then live = live + 1; out[#out + 1] = string.format("#%d:%d,%d/%02X/%02X", i, x, y, tile, attr) end
	end
	return live, table.concat(out, " ")
end
local function menuAttr()
	local lcdc = memory.read_u8(0xFF40, "System Bus") or 0
	local map = ((lcdc & 0x08) ~= 0) and 0x1C00 or 0x1800
	-- the START menu box: top-right, from column 10; read row 2 column 12 and its tile id
	return string.format("LCDC=%02X WY=%d WX=%d row2col12 tile %02X attr %02X", lcdc,
		memory.read_u8(0xFF4A, "System Bus") or 0, memory.read_u8(0xFF4B, "System Bus") or 0,
		memory.read_u8(map + 2 * 32 + 12, "VRAM") or 0, memory.read_u8(0x2000 + map + 2 * 32 + 12, "VRAM") or 0)
end
local frames, phase, waited = 0, "wait", 0
local function tick()
	frames = frames + 1
	if phase == "done" or frames < 30 then return end
	if phase == "wait" then
		waited = waited + 1
		local live, s = oam()
		local npcRight = false
		for i = 4, 39 do
			local y, x = memory.read_u8(i * 4, "OAM"), memory.read_u8(i * 4 + 1, "OAM")
			if y > 0 and y < 160 and x >= 88 and x < 168 then npcRight = true end
		end
		if npcRight or waited > 60 * 45 then
			log(string.format("opening START after %d frames (npc on the right: %s); OAM before: live=%d %s", waited, tostring(npcRight), live, s))
			joypad.set({ Start = true })
			phase, waited = "open", 0
		end
	elseif phase == "open" then
		waited = waited + 1
		if waited < 6 then joypad.set({ Start = true }) end
		if waited % 20 == 0 then local live, s = oam(); log(string.format("menu +%df: %s | live=%d %s", waited, menuAttr(), live, s)) end
		if waited >= 120 then phase, waited = "close", 0 end
	elseif phase == "close" then
		waited = waited + 1
		if waited < 6 then joypad.set({ B = true }) end
		if waited >= 30 then phase = "done"; local live, s = oam(); log(string.format("closed; live=%d %s", live, s)); log("done") end
	end
end
MESHGHOST_DEV_TICK = tick
if not MESHGHOST_DEV_LOADER then while true do tick(); emu.frameadvance() end end
