-- MeshGhost -- does joypad.set actually reach this game right now? (DEV TOOL, never shipped)
--
-- WHY. `use_acro` registered the Acro Bike (measured: registeredItem = 272, and it is in the bag)
-- and pressed SELECT twice, and the player stayed on foot with no menu on screen. That leaves two
-- candidates -- the press is not landing at all, or the game is refusing the bike here -- and a
-- press of START tells them apart: START opens the menu anywhere the overworld accepts input.
local shots = "C:/dev/MeshGhost/dev-scripts/shots/emerald/"
local n = 0
local function tick()
    n = n + 1
    -- START held for six frames, then a screenshot once the menu would be fully open, then SELECT
    -- the same way with its own shot. Two presses, two pictures, no interpretation needed.
    if n >= 30 and n <= 35 then joypad.set({ Start = true })
    elseif n == 36 then joypad.set({})
    elseif n == 90 then client.screenshot(shots .. "input-start.png") console.log("input_test: START shot")
    elseif n >= 100 and n <= 105 then joypad.set({ Start = true })   -- close the menu again
    elseif n == 106 then joypad.set({})
    elseif n >= 160 and n <= 165 then joypad.set({ Select = true })
    elseif n == 166 then joypad.set({})
    elseif n == 220 then client.screenshot(shots .. "input-select.png") console.log("input_test: SELECT shot")
    end
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else while true do tick() emu.frameadvance() end end
