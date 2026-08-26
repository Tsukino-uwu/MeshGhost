-- MeshGhost — Pokémon Crystal/Archipelago: put a BICYCLE in the key-item pocket
--
-- **THIS ONE WRITES TO THE GAME.** The sibling of `grant_items.lua`, which refuses on anything but
-- vanilla V1.0 -- correctly, because it writes at addresses from our own hash-verified pokecrystal
-- build and the Archipelago patch moves WRAM non-uniformly. This is that build's version, and it
-- exists for one reason: the bike is the only way to reach the FOURTH GAIT that build adds (8px a
-- tick, a tile in two frames), and nothing has ever exercised it.
--
-- CLAUDE.md permits this: nothing that SHIPS may write a save, game state or ROM, and **dev-only
-- test tooling MAY cheat -- as a probe, never as an adapter**. This is that probe.
--
-- ** READ THIS BEFORE RUNNING IT **
-- It writes WRAM. That is not the save file -- but **if you SAVE in-game afterwards, the bike is
-- permanent in that save**. It takes a savestate to SLOT 5 first, so the undo is one keypress. It
-- never touches the .sav.
--
-- HOW THE ADDRESS WAS ESTABLISHED, 2026-08-26, and why it is a measurement rather than a guess
-- The patched build enlarges the bag, so vanilla's pocket offsets do not survive and no delta from
-- a neighbouring measurement recovers them (three separate vanilla relationships have already been
-- refuted on this build). So it was found from the game's own contents:
--
--   1. `ap_bag_probe.lua` listed every pocket-shaped run in the player-data bank. Nearly all were
--      empty, and an empty pocket is `00 FF` -- which is also what zeroed RAM looks like, so it
--      carries no signature at all. Exactly ONE non-empty pocket survived that was not adjacent to
--      the already-measured coordinate block: flat 0x1989, a PAIRED pocket, count 1, entry id 02.
--   2. The user reported their bag held **one Ultra Ball and nothing else**. `ULTRA_BALL` is item
--      02 (`constants/item_constants.asm`) and balls live in their own pocket -- so 0x1989 is
--      `wNumBalls`, identified by CONTENTS against the screen rather than by shape.
--   3. `ram/wram.asm` puts the key-item pocket immediately before the ball pocket, and the only
--      clean empty pocket in that gap is flat 0x1960. That is the address below.
--
-- STEP 3 IS THE WEAK LINK AND THIS SCRIPT SAYS SO. Steps 1 and 2 are measured against the screen;
-- step 3 is the best remaining candidate in a region full of zeroes, and it has never been
-- confirmed. **That is why the savestate is taken first and why the verification below reads the
-- bag back rather than trusting the write.** If the bike does not appear in the KEY ITEMS pocket,
-- the address is wrong: load slot 5 and nothing happened. Do not write it into any address table
-- until it has been seen on screen.
--
-- HOW TO RUN
--   Add it to a dev loader target. It acts ONCE and then does nothing. Open the bag and look.

local DOMAIN = "WRAM"

-- CONFIRMED ON SCREEN 2026-08-26: a test item written here appeared in the KEY ITEMS pocket.
local W_NUM_KEY_ITEMS = 0x1960
local W_NUM_BALLS = 0x1989 -- the anchor, confirmed by contents (one Ultra Ball)
-- THE ITEM IDS ARE RENUMBERED ON THIS BUILD, and that was measured the hard way: writing 0x07 --
-- vanilla's BICYCLE -- produced a MOON STONE, which is vanilla's 0x08. Vanilla's list runs
-- 05 POKE_BALL, 06 TERU_SAMA, 07 BICYCLE, 08 MOON_STONE (constants/item_constants.asm), and
-- ULTRA_BALL is still 02 here, so exactly one entry was dropped between 02 and 08 -- almost
-- certainly TERU_SAMA, the unused placeholder. That puts BICYCLE at 06.
--
-- CONFIRMED ON SCREEN 2026-08-26: writing 06 here produced a BICYCLE in the key items pocket, and
-- the user rode it. So on this build BICYCLE is 06 and MOON_STONE is 07 -- both vanilla's value
-- minus one, and both established by looking at the bag rather than by reading a table.
--
-- **Never copy a vanilla item id onto this build.** That is what produced the Moon Stone, and it is
-- the same trap as the WRAM deltas, one table further along: the patch is a recompile, so every
-- id-indexed table it touches can shift, and a wrong id does not fail -- it hands you a different
-- item, exactly as a wrong address hands you a plausible number.
local BICYCLE = 0x06
local ULTRA_BALL = 0x02
local UNDO_SLOT = 5
-- Ids this probe has granted on a previous attempt and should clean up before granting again.
-- 0x07 is the Moon Stone the first attempt produced (see BICYCLE above).
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

	-- REFUSE ON ANYTHING THAT IS NOT THE BUILD THIS WAS MEASURED ON. Writing these offsets into
	-- vanilla's RAM would land in the middle of unrelated player data.
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

	-- RE-CHECK THE ANCHOR BEFORE WRITING ANYTHING. 0x1989 is the one address confirmed against the
	-- screen, and every other conclusion here hangs off it. If the ball pocket no longer reads as
	-- a pocket holding an Ultra Ball, the save has moved on (items used, a different file loaded)
	-- and the key-item address derived from it is no longer trustworthy either.
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

	-- THE UNDO, TAKEN BEFORE THE WRITE. Slot 5 -- slot 1 is the user's own.
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

	-- IDEMPOTENT, and it will not clobber a pocket that already has something in it. If this
	-- address is right and the pocket is non-empty, the bike is APPENDED; if the bike is already
	-- there, nothing changes. A blind "count = 1" would delete key items on a second run.
	local n = u8(W_NUM_KEY_ITEMS) or 0
	-- DROP ANYTHING THIS PROBE PUT HERE ON AN EARLIER RUN. The first attempt granted 0x07 and got
	-- a Moon Stone; without this, each corrected re-run appends another one and the pocket fills
	-- with the evidence of every wrong guess. Only ids this script itself grants are removed --
	-- a key item the PLAYER earned is never touched.
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

	-- READ IT BACK FROM THE GAME, never report the value just written. This is the whole
	-- difference between "the write happened" and "the bag has a bike in it".
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
