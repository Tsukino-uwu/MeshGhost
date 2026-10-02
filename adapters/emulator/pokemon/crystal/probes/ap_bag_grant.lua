-- Writes the game: puts a BICYCLE in the key-item pocket of an Archipelago-patched Crystal, whose bag is enlarged
-- and whose item ids are renumbered, to reach the fourth gait that build adds. Acts once, refuses any other ROM,
-- re-checks its anchor (the ball pocket holding one Ultra Ball) and saves slot 5 before writing; an in-game save
-- afterwards makes the bike permanent. Open the bag and look.

local DOMAIN = "WRAM"

local W_NUM_KEY_ITEMS = 0x1960
local W_NUM_BALLS = 0x1989 -- the anchor, confirmed by contents (one Ultra Ball)
-- Item ids are renumbered on this build, so a vanilla id hands you a different item rather than failing.
local BICYCLE = 0x06
local ULTRA_BALL = 0x02
local UNDO_SLOT = 5
-- Ids an earlier run of this probe granted, removed before granting again: 0x07 was a Moon Stone.
local GRANTED_BEFORE = { 0x07 }

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		local d = info.source:sub(2):match("^(.*)[/\\]")
		if d and #d > 0 then
			return d
		end
	end
	return "."
end

local logfile = io.open(string.format("%s/ap_bag_grant_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function say(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		pcall(function() logfile:flush() end)
	end
end

local function u8(a)
	local ok, v = pcall(memory.read_u8, a, DOMAIN)
	return (ok and type(v) == "number") and v or nil
end

local done = false

local function act()
	done = true
	say("=== MeshGhost Crystal/AP: grant BICYCLE (WRITES GAME RAM) ===")

	-- Refuse anything but the build this was measured on: on vanilla these offsets are unrelated player data.
	local t = {}
	for i = 0, 9 do
		local c = memory.read_u8(0x134 + i, "ROM")
		t[#t + 1] = c and string.char(c) or "?"
	end
	local title = table.concat(t)
	if title:sub(1, 3) ~= "AP_" then
		say(string.format("REFUSING: ROM title %q is not an Archipelago build. These addresses were "
			.. "measured on that patch and mean nothing here. Use grant_items.lua on vanilla.", title))
		return
	end

	-- Re-check the anchor first: every address here hangs off it, and a save that moved on invalidates them.
	local nBalls, ballId = u8(W_NUM_BALLS), u8(W_NUM_BALLS + 1)
	if nBalls ~= 1 or ballId ~= ULTRA_BALL then
		say(string.format("REFUSING: the anchor at 0x%04X no longer reads as one Ultra Ball "
			.. "(count=%s id=%s). Everything here was located from that, so it must be re-measured "
			.. "before anything writes. Run ap_bag_probe.lua again.",
			W_NUM_BALLS, tostring(nBalls), tostring(ballId)))
		return
	end
	say(string.format("anchor OK: ball pocket at 0x%04X holds %d x item %02X", W_NUM_BALLS,
		nBalls, ballId))

	-- The undo, before the write; slot 1 is never ours.
	local okState = pcall(savestate.saveslot, UNDO_SLOT)
	say(okState
		and string.format("savestate written to SLOT %d -- load it to undo everything below",
			UNDO_SLOT)
		or string.format("WARNING: could not write the undo savestate to slot %d. Writing anyway "
			.. "would leave no way back; refusing instead.", UNDO_SLOT))
	if not okState then
		return
	end

	local before = { u8(W_NUM_KEY_ITEMS), u8(W_NUM_KEY_ITEMS + 1), u8(W_NUM_KEY_ITEMS + 2) }
	say(string.format("key-item pocket candidate 0x%04X before: %02X %02X %02X",
		W_NUM_KEY_ITEMS, before[1] or 0, before[2] or 0, before[3] or 0))

	-- Idempotent: the bike is appended to a non-empty pocket, and a second run changes nothing.
	local n = u8(W_NUM_KEY_ITEMS) or 0
	-- Drop what an earlier run of this probe put here, never a key item the player earned.
	for _, junk in ipairs(GRANTED_BEFORE) do
		local w = 0
		for i = 0, n - 1 do
			local id = u8(W_NUM_KEY_ITEMS + 1 + i)
			if id ~= junk then
				memory.write_u8(W_NUM_KEY_ITEMS + 1 + w, id, DOMAIN)
				w = w + 1
			end
		end
		if w ~= n then
			memory.write_u8(W_NUM_KEY_ITEMS + 1 + w, 0xFF, DOMAIN)
			memory.write_u8(W_NUM_KEY_ITEMS, w, DOMAIN)
			say(string.format("removed item %02X left by an earlier run of this probe", junk))
			n = w
		end
	end
	local already = false
	for i = 0, n - 1 do
		if u8(W_NUM_KEY_ITEMS + 1 + i) == BICYCLE then
			already = true
		end
	end
	if already then
		say("the pocket already contains a BICYCLE -- nothing written.")
	else
		memory.write_u8(W_NUM_KEY_ITEMS + 1 + n, BICYCLE, DOMAIN)
		memory.write_u8(W_NUM_KEY_ITEMS + 2 + n, 0xFF, DOMAIN) -- terminator moves with the count
		memory.write_u8(W_NUM_KEY_ITEMS, n + 1, DOMAIN)
	end

	-- Read it back from the game, never the value just written.
	local after = { u8(W_NUM_KEY_ITEMS), u8(W_NUM_KEY_ITEMS + 1), u8(W_NUM_KEY_ITEMS + 2) }
	say(string.format("key-item pocket candidate 0x%04X after : %02X %02X %02X",
		W_NUM_KEY_ITEMS, after[1] or 0, after[2] or 0, after[3] or 0))
	say("NOW OPEN THE BAG AND LOOK AT THE KEY ITEMS POCKET.")
	say("  a BICYCLE there -> the address is right, and it can go in the address table.")
	say(string.format("  nothing there -> 0x%04X is NOT the key-item pocket. Load savestate slot "
		.. "%d; nothing happened. Do not record the address.", W_NUM_KEY_ITEMS, UNDO_SLOT))
end

if MESHGHOST_DEV_LOADER then
	MESHGHOST_DEV_TICK = function()
		if not done then
			act()
		end
	end
else
	act()
end
