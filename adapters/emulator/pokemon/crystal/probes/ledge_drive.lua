-- Drives one ledge hop from a prepared savestate: loads MESHGHOST_LEDGE_SLOT (default 9, one tile above a ledge),
-- waits 2s for the adapter to re-sync, holds Down 40 frames, then screenshots every 4 frames for ~6s, because a hop
-- is over in about 32 frames and its arc changes every tick. The reading is fly_probe.lua's, loaded beside it.
-- Unload it before judging anything else on screen.

local SLOT = tonumber(_G.MESHGHOST_LEDGE_SLOT or "") or 9

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	-- The adapter's logs/ is at the adapter root, not beside this probe.
	dir = dir:match("^(.*)/probes$") or dir
end
local stamp = os.date("%H%M%S")

local phase, n, shot = 0, 0, 0

local function say(s)
	pcall(function() console.log("ledge_drive: " .. s) end)
end

say(string.format("loading slot %d in 2s, then holding Down; screenshots to logs/", SLOT))

MESHGHOST_DEV_TICK = function()
	n = n + 1
	if phase == 0 and n >= 120 then
		phase, n = 1, 0
		local ok = pcall(function() savestate.loadslot(SLOT) end)
		say(ok and ("slot " .. SLOT .. " loaded") or ("slot " .. SLOT .. " FAILED to load"))
	elseif phase == 1 and n >= 120 then
		phase, n = 2, 0
		say("holding Down")
	elseif phase == 2 then
		if n <= 40 then
			joypad.set({ Down = true })
		end
		if n % 4 == 0 and n <= 360 then
			shot = shot + 1
			pcall(function()
				client.screenshot(string.format("%s/logs/ledge_%s_slot%d_%04d.png",
					dir, stamp, SLOT, n))
			end)
		end
		if n > 360 then
			phase, n = 3, 0
			say(string.format("done: %d screenshots taken. Unload this probe.", shot))
		end
	end
end
