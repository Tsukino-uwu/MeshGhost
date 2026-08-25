-- MeshGhost — Pokémon Crystal: walk in and out of a door, forever (DEV TOOL)
--
-- The user's own test setup, 2026-08-21: stand outside a house, one tile up goes in, one tile down
-- comes out. Looping it is how the painted tier's behaviour DURING a map transition gets watched
-- often enough to measure, without a person holding the d-pad for ten minutes.
--
-- It presses only Up and Down, and waits between them so each transition completes.
--
-- THIS PROBE HOLDS THE CONTROLLER. Unload it before handing the game back to anyone: while it is
-- loaded it presses the d-pad alongside whoever else is playing, and the two fight. In a loopback
-- session the ghost IS the local player echoed, so a probe jittering the player jitters the ghost
-- and it reads as a RENDERING fault in whatever is being tested. Left loaded during a hand test on
-- 2026-08-22, it became a suspect for a ghost wiggle and cost a round of diagnosis -- it was
-- innocent, which is the point: an uncontrolled instrument does not have to cause a fault to cost
-- you the investigation. See adapters/_template/probes.md.
local HOLD, WAIT = 20, 90
local phase, timer = "up", 0
if console and console.log then
	console.log("door_loop: THIS PROBE IS PRESSING UP/DOWN -- unload it before playing by hand")
end

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
