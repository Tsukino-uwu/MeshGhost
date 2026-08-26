-- DRIVE ONE FLY FROM A PREPARED SAVESTATE, and photograph the landing. -- 2026-08-26
--
-- INPUT-DRIVING PROBE: loads a savestate and presses A once. Unload it before judging anything
-- else on screen. Built because the user handed over two prepared states -- slot 8 "same town,
-- press A to fly", slot 9 "different town, press A to fly" -- which turns each fly-landing
-- iteration from a request on the user's time into something this rig can run itself.
--
-- WHAT IT DOES, on a fixed countdown (endurance, not timing):
--   1. waits 2s, loads MESHGHOST_FLY_SLOT (default 8),
--   2. waits 2s for the adapter to re-sync to the loaded world,
--   3. presses A once,
--   4. screenshots every 8 frames for the next ~10s into the log folder, numbered by frame.
--
-- The adapter's own MESHGHOST_CRYSTAL_FLY_TRACE lines are the other half of the reading: this
-- probe supplies the eyes (did the POKEMON appear during the descent?), the trace supplies the
-- envelope (did the drop arm, what species was held, did the icon resolve).
--
-- Screenshots go beside the logs so a session's evidence stays in one place; the folder is
-- gitignored the same way logs are.

local SLOT = tonumber(_G.MESHGHOST_FLY_SLOT or "") or 8

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	-- The adapter's logs/ lives at the ADAPTER root, not beside this probe -- the first run wrote
	-- 75 screenshots into probes/logs/, which does not exist, and the pcall swallowed every one.
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
