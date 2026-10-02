-- Pokémon Crystal: walks in and out of a door forever (one tile up goes in, one down comes out), waiting between
-- presses so each transition completes. Holds the d-pad: unload it before anyone plays by hand, since in a loopback
-- session a jittering player is a jittering ghost, which reads as a rendering fault.
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
