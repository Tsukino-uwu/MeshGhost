-- Pokémon Crystal: drives one Escape Rope (Dig's animation) from a savestate: loads MESHGHOST_DIG_SLOT
-- (default 9: in a cave, the bag open on an Escape Rope), presses A twice and screenshots every 8 frames for ~14s
-- into the adapter's logs/. Holds the controller: unload it before judging anything else on screen.
-- Load fly_probe.lua beside it for the reading. A reload restarts the countdown; no leftover global can start it.
-- The window is long on purpose: a 32-tick departure spin, the map reload, then 32 ticks of arrival flicker.

local SLOT = tonumber(_G.MESHGHOST_DIG_SLOT or "") or 9

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	-- The adapter's logs/ is at its root, not beside this probe.
	dir = dir:match("^(.*)/probes$") or dir
end
local stamp = os.date("%H%M%S")

local phase, n, shot = 0, 0, 0

local function say(s)
	pcall(function() console.log("dig_drive: " .. s) end)
end

say(string.format("loading slot %d in 2s, then A twice; screenshots to logs/", SLOT))

MESHGHOST_DEV_TICK = function()
	n = n + 1
	if phase == 0 and n >= 120 then
		phase, n = 1, 0
		local ok = pcall(function() savestate.loadslot(SLOT) end)
		say(ok and ("slot " .. SLOT .. " loaded") or ("slot " .. SLOT .. " FAILED to load"))
	elseif phase == 1 and n >= 120 then
		phase, n = 2, 0
		say("pressing A (1 of 2)")
	elseif phase == 2 then
		-- Held 3 frames, not 1: the game samples input once per its own loop, not once per video frame.
		if n <= 3 then
			joypad.set({ A = true })
		end
		if n >= 90 and n <= 93 then
			joypad.set({ A = true })
			if n == 90 then
				say("pressing A (2 of 2)")
			end
		end
		if n % 8 == 0 and n <= 840 then
			shot = shot + 1
			pcall(function()
				client.screenshot(string.format("%s/logs/dig_%s_slot%d_%04d.png",
					dir, stamp, SLOT, n))
			end)
		end
		if n > 840 then
			phase, n = 3, 0
			say(string.format("done: %d screenshots taken. Unload this probe.", shot))
		end
	end
end
