-- MeshGhost — Pokémon Crystal: which sprite id is the local player wearing, over time (READ-ONLY)
--
-- Asked 2026-09-13: an Archipelago peer RUNNING showed on a vanilla client as a ghost ON A BIKE. The
-- run rows ($65/$66) differ between the two cartridges, so the receiver drops the id and falls back
-- to "this machine's own player sprite" -- which is a bike if the vanilla player is riding. This
-- settles both halves: on the Archipelago client it shows the id a runner really carries (a
-- patched-ROM fact, `UNVERIFIED.md` 2026-08-26 item 2), and on the vanilla client what the fallback
-- would have borrowed. One line on every change of sprite, plus one every 5 seconds; 60 seconds.
-- Object array per build: meshghost_crystal.lua ADDRESSES (vanilla .sym 01:d4d6; Archipelago measured).
local BUILDS = { PM_CRYSTAL = 0x14D6, AP_CRYSTAL = 0x14DC }
local title = ""
for i = 0x134, 0x13E do
	local c = memory.read_u8(i, "ROM")
	if c == 0 then break end
	title = title .. string.char(c)
end
local objects = BUILDS[title]
local logfile
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/player_sprite_%s_%s.log", dir, title:gsub("%W", ""),
		os.date("%Y%m%d_%H%M%S")), "w")
end
local frames, last = 0, nil
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	if not objects or not logfile or frames > 3600 then return end
	local spr = memory.read_u8(objects, "WRAM")
	local walking = memory.read_u8(objects + 0x07, "WRAM")
	if spr ~= last or frames % 300 == 0 then
		logfile:write(string.format("f=%d t=%s sprite=$%02X walking=$%02X%s\n", emu.framecount(),
			os.date("%H:%M:%S"), spr, walking, spr ~= last and "  (changed)" or ""))
		logfile:flush()
		last = spr
	end
end
MESHGHOST_DEV_UNLOAD = function()
	if logfile then logfile:close() logfile = nil end
end
