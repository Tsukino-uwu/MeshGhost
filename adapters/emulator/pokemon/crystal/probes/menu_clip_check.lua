-- DOES A REAL MENU STILL CLIP A DRAWN GHOST, after the stale-rectangle fix? -- 2026-08-26
--
-- INPUT-DRIVING PROBE. It presses START, holds the menu open, then presses B to close it. Unload
-- it before judging anything else -- probes.md, "an input-driving probe is not a passive
-- instrument". Two button presses, both reversible, nothing written to memory.
--
-- WHY IT EXISTS. `TEXTBOX.cornerAt` now requires a menu's frame corner to be present in the
-- tilemap before the adapter trusts `wMenuBorder*`, because those coordinates are never cleared
-- when a menu closes and a Fly left a stale right-half rectangle hiding painted peers forever
-- (2026-08-26). The fix removes the false positive; this asks the other half of the question,
-- which is the one that could REGRESS something already confirmed on screen: with a genuine menu
-- open, does the corner test still say `true`?
--
-- If it does not, menu clipping is broken by that fix and it comes straight back out -- a drawn
-- ghost painting over the START menu is a bug the user reported on 2026-08-19 and it was fixed.
--
-- ENDURANCE, NOT TIMING: fixed phases on a countdown, nothing to catch. Read the result in the
-- ADAPTER's log (MESHGHOST_CRYSTAL_UI_DEBUG must be on): the `UI DEBUG` lines carry
-- `liveCorner=` and the raw `coords=`, and the phase markers below say which lines were taken
-- with the menu open.

local phase, n = 0, 0
local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	f = io.open(string.format("%s/menu_clip_check_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	if f then f:setvbuf("full", 1 << 12) end
end

local function say(s)
	if f then f:write(s .. "\n"); f:flush() end
	pcall(function() console.log("menu_clip_check: " .. s) end)
end

say("phase 1: waiting 3s before touching anything")

MESHGHOST_DEV_TICK = function()
	n = n + 1
	if phase == 0 and n >= 180 then
		phase, n = 1, 0
		say("phase 2: pressing START -- the adapter's UI DEBUG lines from here should say"
			.. " liveCorner=true while the menu is up")
	elseif phase == 1 then
		if n <= 2 then
			joypad.set({ Start = true })
		end
		if n >= 240 then
			phase, n = 2, 0
			say("phase 3: menu has been open ~4s; pressing B to close it")
		end
	elseif phase == 2 then
		if n <= 2 then
			joypad.set({ B = true })
		end
		if n >= 180 then
			phase, n = 3, 0
			say("phase 4: done, menu closed. liveCorner should be false again."
				.. " UNLOAD THIS PROBE before judging anything on screen.")
		end
	end
end
