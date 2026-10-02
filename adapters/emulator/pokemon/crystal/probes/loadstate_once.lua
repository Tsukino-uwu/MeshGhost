-- One-shot: loads savestate slot MESHGHOST_LOADSTATE_SLOT (default 3) two seconds after attach and logs the player's
-- tile before and after. Take it off the target after use, or every reload fires it again.

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
