-- WHAT ACTUALLY DISTINGUISHES "A MENU IS ON SCREEN" FROM "A MENU WAS ON SCREEN" -- a table, not
-- a guess. 2026-08-26.
--
-- INPUT-DRIVING PROBE (it presses START, then B). Unload it before judging anything on screen.
--
-- WHY. Two candidate signals have now failed, and the rule after two is to stop guessing and
-- tabulate (CLAUDE.md):
--   1. `wMenuBorderBottom/Right non-zero` -- FAILED. Nothing in the game clears those coordinates
--      when a menu closes, so after a Fly a stale right-half rectangle hid painted peers forever.
--   2. `the menu frame's corner tile is in the tilemap` -- FAILED, measured today. The corner
--      survives the menu closing: 87 consecutive samples said `liveCorner=true`, straight through
--      a START menu being opened AND closed by this probe's own button presses.
--
-- So this probe stops proposing tests and just records every cheap display-state byte across three
-- states it drives itself, and prints one table. The discriminator gets CHOSEN from that table, or
-- the table shows there is not one and the adapter needs a different mechanism entirely.
--
-- WHAT IT RECORDS, per phase, as the SET of distinct values seen (a set, because these registers
-- strobe -- the reason WY alone failed as a signal back on 2026-08-19, and the reason a single
-- sample of any of them is worthless):
--   LCDC ($FF40)  -- bit 5 is window enable, bit 6 the window's tilemap, bit 3 the BG's
--   WY   ($FF4A)  -- the window's top line; 144 parks it off the bottom
--   WX   ($FF4B)
--   the menu rectangle ($cf82-$cf85), and whether the frame corner is in the tilemap
--
-- ENDURANCE, NOT TIMING: three fixed phases on a countdown, driven by the probe.
--
-- Addresses from the decompilation (pokecrystal.sym: wMenuBorderTopCoord $cf82) and the Game Boy's
-- own register map. Log beside this script.

local DOMAIN = "WRAM"
local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end
local MENUBOX = { top = flat(0xCF82), left = flat(0xCF83), bottom = flat(0xCF84), right = flat(0xCF85) }
local CORNER, EDGE = 121, 122

local function u8(a)
	local ok, v = pcall(memory.read_u8, a, DOMAIN)
	return (ok and v) or 0
end
local function io8(a) return memory.read_u8(a, "System Bus") or 0 end

local function cornerAt(row, col)
	if row < 0 or row > 17 or col < 0 or col > 19 then
		return false
	end
	local at = (((io8(0xFF40) & 0x08) ~= 0) and 0x1C00 or 0x1800) + row * 32 + col
	return (memory.read_u8(at, "VRAM") or 0) == CORNER
		and (memory.read_u8(at + 1, "VRAM") or 0) == EDGE
end

local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	f = io.open(string.format("%s/menu_state_table_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	if f then f:setvbuf("full", 1 << 12) end
end
local function say(s)
	if f then f:write(s .. "\n"); f:flush() end
	pcall(function() console.log("menu_state_table: " .. s) end)
end

local PHASES = {
	[0] = "A: overworld, no menu (before this probe touches anything)",
	[1] = "B: START menu OPEN",
	[2] = "C: menu CLOSED again (the state the adapter gets wrong)",
}
local phase, n, seen = 0, 0, {}
local lastRect = nil

local function note(k, v)
	seen[phase] = seen[phase] or {}
	seen[phase][k] = seen[phase][k] or {}
	seen[phase][k][tostring(v)] = (seen[phase][k][tostring(v)] or 0) + 1
end

local function report(p)
	local s = seen[p]
	say("")
	say("=== phase " .. PHASES[p] .. " ===")
	if not s then
		say("  (nothing sampled)")
		return
	end
	for _, k in ipairs({ "LCDC", "win_enable", "WY", "WX", "rect", "corner" }) do
		local parts = {}
		if s[k] then
			for v, c in pairs(s[k]) do
				parts[#parts + 1] = string.format("%s x%d", v, c)
			end
			table.sort(parts)
		end
		say(string.format("  %-11s %s", k, (#parts > 0) and table.concat(parts, "   ") or "-"))
	end
end

say("phase A: sampling the overworld for 3s before pressing anything")

MESHGHOST_DEV_TICK = function()
	n = n + 1

	local lcdc = io8(0xFF40)
	note("LCDC", string.format("%02X", lcdc))
	note("win_enable", ((lcdc & 0x20) ~= 0) and "on" or "off")
	note("WY", io8(0xFF4A))
	note("WX", io8(0xFF4B))
	local t, l, b, r = u8(MENUBOX.top), u8(MENUBOX.left), u8(MENUBOX.bottom), u8(MENUBOX.right)
	local rect = string.format("%d,%d,%d,%d", t, l, b, r)
	note("rect", rect)
	note("corner", tostring(cornerAt(t, l)))

	-- WHEN each change happened, not just how many. The whole design question is whether a live
	-- menu keeps PULSING this rectangle for as long as it is open, or writes it once at draw time
	-- and never again -- and a count of 7 out of 240 cannot tell those apart while a rule built on
	-- the difference would be wrong half the time.
	if rect ~= lastRect then
		say(string.format("    rect change at phase %s frame %d: %s -> %s", tostring(phase), n,
			tostring(lastRect), rect))
		lastRect = rect
	end

	if phase == 0 and n >= 180 then
		report(0)
		phase, n = 1, 0
		say("phase B: pressing START")
	elseif phase == 1 then
		if n <= 2 then
			joypad.set({ Start = true })
		end
		if n >= 240 then
			report(1)
			phase, n = 2, 0
			say("phase C: pressing B to close the menu")
		end
	elseif phase == 2 then
		if n <= 2 then
			joypad.set({ B = true })
		end
		if n >= 240 then
			report(2)
			phase, n = 3, 0
			say("")
			say("DONE. Compare phase B against phases A and C: any row whose value set in B does"
				.. " not overlap A and C is a usable discriminator. A row identical across all"
				.. " three is not, however plausible it looks. UNLOAD THIS PROBE NOW.")
		end
	end
end
