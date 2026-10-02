-- Writes one game byte, after a savestate to slot 6: forces the Archipelago wPlayerState candidate to a third value,
-- which tells a state byte from a bike flag. Success is the engine turning the player into the surf blob; step or turn
-- before concluding nothing changed. On land this is a cheat, not a test of surfing: load slot 6 after.
-- MESHGHOST_AP_FORCE_STATE picks the value (default 4, vanilla's surf); this build renumbers other id spaces.

local DOMAIN = "WRAM"
local W_PLAYER_STATE = 0x1A17 -- the candidate, refuted: writing 4 changed nothing on screen
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

	-- The player's sprite, from the object the engine draws (wObjectStructs + 0), where the write's effect shows.
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
