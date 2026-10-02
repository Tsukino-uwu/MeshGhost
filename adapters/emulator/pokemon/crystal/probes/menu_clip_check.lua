-- Does a genuine menu still clip a drawn ghost, now that the adapter trusts wMenuBorder* only while the menu's frame
-- corner is in the tilemap? Input-driving: presses START, holds the menu open, presses B, on a countdown; writes no
-- memory. Read the adapter's own UI DEBUG lines (MESHGHOST_CRYSTAL_UI_DEBUG on): their corner= field should hold
-- while the menu is up, and this probe's phase markers say which lines those are. Unload it before judging anything.

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
