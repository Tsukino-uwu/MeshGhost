-- MeshGhost — the idle bike pose, facing up (dev tool, presses the pad, vanilla only, never shipped).
-- Start on the bike in the overworld: it rides up for about a second, lets go, and once the pose has settled saves
-- dev-scripts/shots/emerald/pose-north.png. Facing up or down shows the idle pose; the side-on frames hide it.
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
