-- MeshGhost — Pokémon Crystal/Archipelago: force wPlayerState, to CONFIRM it and to reach surf
--
-- **THIS ONE WRITES TO THE GAME.** One byte, and it takes a savestate to SLOT 6 first.
--
-- TWO JOBS, ONE WRITE
--
-- 1. CONFIRM THE ADDRESS. `ap_playerstate_probe.lua` reversed a bike toggle and found flat 0x1A17
--    (CPU $DA17) going 0 on foot -> 1 on the bike, which is vanilla's PLAYER_NORMAL/PLAYER_BIKE
--    encoding exactly. That is TWO states, and two states cannot tell a state byte from a bike
--    flag -- this adapter already carries an address that fit two samples and failed the third
--    (`W_MAPSTATUS`, refuted by a trainer battle after surviving two snapshot runs). A third value
--    is what settles it, and writing one is far cheaper than earning it: surf otherwise needs a
--    badge and a party Pokemon that knows the move, neither of which has a measured address on
--    this build.
--
-- 2. REACH SURF AT ALL. The surf state is the last unexercised piece of this adapter's
--    cross-build appearance work: a surfing peer wears a different sprite, and whether that
--    crosses to a vanilla client is untested. This puts a client into it on demand.
--
-- WHAT SUCCESS LOOKS LIKE: the player's own character becomes the surf blob. That is the ENGINE
-- drawing it, from a byte we only wrote -- so it confirms the address by its effect rather than by
-- reading back what we put there.
--
-- WHAT FAILURE LOOKS LIKE, and it is not a crash: nothing visible changes. `UpdatePlayerSprite`
-- is what turns a state into a sprite and it runs on a state CHANGE, not every frame -- so take a
-- step, or turn, before concluding it did nothing. If the character never changes, 0x1A17 is not
-- wPlayerState and the candidate is refuted, which is a result worth having.
--
-- ** ON LAND, THIS IS A CHEAT AND IT LOOKS LIKE ONE. ** Surfing over grass is not a state the game
-- reaches on its own. It is fine for confirming the address and for putting a sprite on the wire;
-- it is NOT a test of how surfing behaves. Load slot 6 when done.
--
-- MESHGHOST_AP_FORCE_STATE picks the value; default 4. Vanilla's encoding is 0 normal, 1 bike,
-- 2 skate, 4 surf, 8 surfing Pikachu -- reported as the shape to expect, never assumed, since this
-- build renumbers other id spaces (its BICYCLE is 06 where vanilla's is 07).

local DOMAIN = "WRAM"
local W_PLAYER_STATE = 0x1A17 -- CANDIDATE (see above). Confirmed on screen: not yet.
local WANT = tonumber(MESHGHOST_AP_FORCE_STATE) or 4
local UNDO_SLOT = 6

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

local logfile = io.open(string.format("%s/ap_force_state_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function say(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		pcall(function() logfile:flush() end)
	end
end

local done = false

local function act()
	done = true
	say("=== MeshGhost Crystal/AP: force wPlayerState (WRITES GAME RAM) ===")

	local t = {}
	for i = 0, 9 do
		local c = memory.read_u8(0x134 + i, "ROM")
		t[#t + 1] = c and string.char(c) or "?"
	end
	if table.concat(t):sub(1, 3) ~= "AP_" then
		say(string.format("REFUSING: ROM title %q is not an Archipelago build; 0x%04X was measured "
			.. "on that patch and means nothing here.", table.concat(t), W_PLAYER_STATE))
		return
	end

	if not pcall(savestate.saveslot, UNDO_SLOT) then
		say(string.format("REFUSING: could not write the undo savestate to slot %d, and writing "
			.. "without a way back is not worth one measurement.", UNDO_SLOT))
		return
	end
	say(string.format("savestate written to SLOT %d -- load it to undo this", UNDO_SLOT))

	-- THE PLAYER'S OWN SPRITE, BEFORE. Read from the object the engine draws, not from the state
	-- byte: the whole point is to watch the engine ACT on the write, and the sprite id is where
	-- that shows. OBJECT_STRUCTS on this build is 0x14DC, sprite at offset 0.
	local before = memory.read_u8(0x14DC, DOMAIN)
	local was = memory.read_u8(W_PLAYER_STATE, DOMAIN)
	memory.write_u8(W_PLAYER_STATE, WANT, DOMAIN)
	say(string.format("0x%04X: %s -> %d   (player sprite was %s)",
		W_PLAYER_STATE, tostring(was), WANT, tostring(before)))
	say("TAKE A STEP OR TURN -- UpdatePlayerSprite runs on a state CHANGE, not every frame.")
	say("  character becomes the surf blob -> 0x" .. string.format("%04X", W_PLAYER_STATE)
		.. " IS wPlayerState, confirmed by its effect. A third value, so it is a state byte and")
	say("  not a bike flag -- it can go in the address table.")
	say("  nothing changes -> the candidate is REFUTED. Load savestate slot " .. UNDO_SLOT
		.. " and do not record the address.")
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
