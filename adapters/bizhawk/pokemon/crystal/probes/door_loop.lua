-- MeshGhost — Pokémon Crystal: walk in and out of a door, forever (DEV TOOL)
--
-- The user's own test setup, 2026-08-21: stand outside a house, one tile up goes in, one tile down
-- comes out. Looping it is how the painted tier's behaviour DURING a map transition gets watched
-- often enough to measure, without a person holding the d-pad for ten minutes.
--
-- It presses only Up and Down, and waits between them so each transition completes.
local HOLD, WAIT = 20, 90
local phase, timer = "up", 0
MESHGHOST_DEV_TICK = function()
	timer = timer + 1
	if phase == "up" then
		joypad.set({ Up = true })
		if timer > HOLD then phase, timer = "wait1", 0 end
	elseif phase == "wait1" then
		if timer > WAIT then phase, timer = "down", 0 end
	elseif phase == "down" then
		joypad.set({ Down = true })
		if timer > HOLD then phase, timer = "wait2", 0 end
	else
		if timer > WAIT then phase, timer = "up", 0 end
	end
end
