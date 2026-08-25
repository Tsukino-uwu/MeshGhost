-- MeshGhost -- the idle bike pose, ridden into and then held (DEV TOOL, never shipped)
--
-- WHY. The user, 2026-08-20: *"face up/down when checking the pose, left/right won't show it
-- properly"*. The side-on frames of the Acro Bike hide the difference between standing still on it
-- and rolling along on it; the front and back views do not. So the ride is driven to face each of
-- them, held still long enough to settle, and shot.
-- Resolve this script's own directory instead of hardcoding one developer's
-- checkout. A tracked absolute path is unusable on anyone else's machine and is
-- the class of leak .githooks/pre-commit now refuses (pitfalls.md).
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local shots = MESHGHOST_DIR .. "/../../../../../dev-scripts/shots/emerald/"
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GPLAYERAVATAR_ADDR = 0x02037590
local n = 0
local function tick()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or memory.read_u8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then joypad.set({}) return end
    n = n + 1
    if n >= 20 and n <= 80 then joypad.set({ Up = true })
    elseif n == 81 then joypad.set({})
    elseif n == 280 then client.screenshot(shots .. "pose-north.png") console.log("poseshot: north idle")
    end
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else while true do tick() emu.frameadvance() end end
