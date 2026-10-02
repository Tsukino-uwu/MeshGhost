-- MeshGhost — Pokémon Emerald: does joypad.set reach the game right now? (dev tool, presses buttons, never shipped)
-- Presses START, then SELECT, and screenshots each into dev-scripts/shots/emerald/. START opens the start menu
-- wherever the overworld takes input, so no start menu in its shot means the press is not landing.
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local shots = MESHGHOST_DIR .. "/../../../../../dev-scripts/shots/emerald/"
local n = 0
local function tick()
    n = n + 1
    if n >= 30 and n <= 35 then joypad.set({ Start = true })
    elseif n == 36 then joypad.set({})
    elseif n == 90 then client.screenshot(shots .. "input-start.png") console.log("input_test: START shot")
    elseif n >= 100 and n <= 105 then joypad.set({ Start = true })   -- close the start menu again
    elseif n == 106 then joypad.set({})
    elseif n >= 160 and n <= 165 then joypad.set({ Select = true })
    elseif n == 166 then joypad.set({})
    elseif n == 220 then client.screenshot(shots .. "input-select.png") console.log("input_test: SELECT shot")
    end
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else while true do tick() emu.frameadvance() end end
