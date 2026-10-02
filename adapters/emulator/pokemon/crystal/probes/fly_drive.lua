-- Pokémon Crystal: drives one Fly from a savestate and photographs the landing: loads MESHGHOST_FLY_SLOT (default 8),
-- presses A once and screenshots every 8 frames for ~10s into the adapter's logs/. Holds the controller: unload it
-- before judging anything else. The adapter's MESHGHOST_CRYSTAL_FLY_TRACE lines are the other half of the reading.

local SLOT = tonumber(_G.MESHGHOST_FLY_SLOT or "") or 8

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
	pcall(function() console.log("fly_drive: " .. s) end)
end

say(string.format("loading slot %d in 2s, then pressing A; screenshots to logs/", SLOT))

MESHGHOST_DEV_TICK = function()
	n = n + 1
	if phase == 0 and n >= 120 then
		phase, n = 1, 0
		local ok = pcall(function() savestate.loadslot(SLOT) end)
		say(ok and ("slot " .. SLOT .. " loaded") or ("slot " .. SLOT .. " FAILED to load"))
	elseif phase == 1 and n >= 120 then
		phase, n = 2, 0
		say("pressing A")
	elseif phase == 2 then
		if n <= 2 then
			joypad.set({ A = true })
		end
		if n % 8 == 0 and n <= 600 then
			shot = shot + 1
			pcall(function()
				client.screenshot(string.format("%s/logs/fly_%s_slot%d_%04d.png",
					dir, stamp, SLOT, n))
			end)
		end
		if n > 600 then
			phase, n = 3, 0
			say(string.format("done: %d screenshots taken. Unload this probe.", shot))
		end
	end
end
