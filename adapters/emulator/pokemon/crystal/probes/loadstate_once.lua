-- loadstate_once.lua -- ONE-SHOT: load savestate slot N (default 3) two seconds after attach, log
-- the player's tile before and after, then do nothing. A reproduction tool for 2026-09-09's
-- five-build finding: a window's ghost vanished from every other window after that window loaded
-- a savestate. Dev-loader contract; unload it before judging anything else.
local SLOT = tonumber(os.getenv("MESHGHOST_LOADSTATE_SLOT") or "") or 3
local frames, done = 0, false
local function tile() return memory.read_u8(0x14E6, "WRAM"), memory.read_u8(0x14E7, "WRAM") end
local function tick()
	frames = frames + 1
	if done or frames < 120 then return end
	done = true
	local x, y = tile()
	console.log(string.format("loadstate_once: before slot %d, tile %d,%d frame %d", SLOT, x, y, emu.framecount()))
	savestate.loadslot(SLOT)
	local x2, y2 = tile()
	console.log(string.format("loadstate_once: after slot %d, tile %d,%d frame %d", SLOT, x2, y2, emu.framecount()))
end
MESHGHOST_DEV_TICK = tick
if not MESHGHOST_DEV_LOADER then while true do tick(); emu.frameadvance() end end
