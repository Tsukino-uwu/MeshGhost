-- MeshGhost — Pokémon Crystal: is that extra character ours, and how did it get left behind?
--
-- READ-ONLY DIAGNOSTIC. Writes nothing, deletes nothing, spawns nothing. It only names what is
-- already in the game's object arrays.
--
-- WHY THIS EXISTS
-- The user, 2026-08-21: *"i have a weird 'static' ghost that appear sometimes, im not sure if that
-- is from your scripts or something else"*. That question has an exact answer, because a ghost
-- this adapter spawned carries a fingerprint no NPC placed by the map has:
--
--   * it wears the LOCAL PLAYER's sprite id (the adapter borrows it at spawn), and
--   * FLAG1_WONT_DELETE is set on it (the adapter sets it so the engine does not cull the ghost
--     when it leaves the visible window), and
--   * since 2026-08-21 its movement type is pinned to SPRITEMOVEDATA_STANDING_DOWN.
--
-- A map's own NPC can have any one of those. Having all three, while not being the player, is us.
--
-- HOW ONE GETS ORPHANED, which is the thing worth confirming rather than assuming: despawnGhost()
-- refuses to clear a slot whose identity no longer checks out -- it FORGETS the entry instead.
-- That rule is deliberate and correct (zeroing a slot the game has reused would delete one of the
-- game's own NPCs), but its cost is exactly this: an object we made, that we are no longer
-- tracking, wearing WONT_DELETE so the engine will not reclaim it either. It stands still forever
-- because nothing is driving it.
--
-- Reloading the adapter repeatedly during development is the situation that produces it most
-- often, so a static ghost after a working session is more likely a development artifact than a
-- bug a player would ever see. This probe is how to tell the two apart.
--
-- HOW TO RUN
--   Load it beside the adapter (dev-scripts/bizhawk-dev-loader.lua takes several targets), or on
--   its own. It reports once a second, and only when something changed, so a clean map is silent.
--   Log: orphan_<timestamp>.log beside this file.
--
--   To CLEAR one: a map change rebuilds both arrays from ROM, so walking through any door or
--   loading a savestate removes it. Nothing here writes to the game.

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- Vanilla V1.0, the same addresses the adapter's vanilla table uses.
local OBJECT_STRUCTS = flat(0xD4D6)
local MAP_OBJECTS = flat(0xD71E)
local OBJECT_LENGTH, MAPOBJECT_LENGTH = 0x28, 0x10
local NUM_OBJECT_STRUCTS, NUM_MAP_OBJECTS = 13, 16

local M_STRUCT_ID, M_SPRITE, M_Y, M_X, M_MOVEMENT = 0x00, 0x01, 0x02, 0x03, 0x04
local F_SPRITE, F_MAP_OBJECT_INDEX = 0x00, 0x01
local F_MOVEMENT_TYPE, F_FLAGS1 = 0x03, 0x04
local F_WALKING, F_DIRECTION, F_ACTION = 0x07, 0x08, 0x0B
local F_STEP_TYPE, F_STEP_DURATION = 0x09, 0x0A
local F_SPRITE_X, F_SPRITE_Y = 0x17, 0x18
local F_MAP_X, F_MAP_Y = 0x10, 0x11

local FLAG1_WONT_DELETE = 0x02
local SPRITEMOVEDATA_STANDING = 0x06
local STEP_TYPE_NPC_WALK = 0x02
local UNASSIGNED = 0xFF
local STANDING = 255

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/orphan_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, and never flushed per line: a console.log plus a flush is a synchronous disk
	-- write on the emulator's own thread, measured at 63-83ms -- four to five frames, every time
	-- (pitfalls.md, "ONE console line a second cost 7.4 fps"). A probe that stalls the game is a
	-- probe that changes what it measures.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- THE CONSOLE IS THE EXPENSIVE HALF. `console.log` appends to BizHawk's GUI console window, on the
-- emulator's own thread; pitfalls.md measured ONE such line a second costing 7.4fps, and removing
-- the per-line disk flush alone left 87-175ms hitches still there (2026-08-21). So the console gets
-- the opening lines and then one in twenty, while the FILE gets every line -- the log is the record,
-- the console is only a glance.
local rawConsole, consoleLines = console.log, 0
local function raw_log(msg)
	consoleLines = consoleLines + 1
	if consoleLines <= 4 or consoleLines % 20 == 0 then
		rawConsole(msg)
	end
end
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		-- Flush every 20 LINES: bounded cost, live log. The buffering sweep removed the per-line
		-- flush and a probe then reported NOTHING for a whole run (pitfalls.md: an empty log reads
		-- exactly like "nothing happened").
		flushEvery = (flushEvery or 0) + 1
		if flushEvery >= 20 then
			flushEvery = 0
			pcall(function() logfile:flush() end)
		end
	end
end

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

open_log()
log("=== MeshGhost Crystal orphan check (READ-ONLY) ===")
log("Looking for characters carrying this adapter's fingerprint that nothing is driving.")
log("Silent while nothing changes. A map change clears any orphan by rebuilding the arrays.")

local frames = 0
local lastReport = nil

-- A character is judged STILL only by watching it: one that has not changed tile or animation
-- state across the whole observation window is standing there doing nothing, which is what an
-- orphan looks like and what a scripted NPC that happens to be idle also looks like. So stillness
-- alone is never the verdict -- it is reported alongside the fingerprint, not instead of it.
local seen = {} -- struct slot -> { x, y, stillFor }
local flagged = {} -- struct slot -> already reported, so a runaway is said once
local trace = {} -- struct slot -> ring buffer of the last ten frames of step fields

local function tick()
	frames = frames + 1

	-- The buffering sweep removed per-line flushes, which is right for cost -- but a report that
	-- sits in a buffer reads exactly like "nothing found" (pitfalls.md: an empty log reads exactly
	-- like the game did nothing). One flush every five seconds keeps the log honest for one frame's
	-- cost that often.
	if logfile and frames % 300 == 0 then
		pcall(function() logfile:flush() end)
	end

	local playerSprite = u8(OBJECT_STRUCTS + F_SPRITE)
	if not playerSprite or playerSprite == 0 then
		return -- not in the overworld
	end

	-- ONE pass per frame over the structs, not two. The first version scanned twice (stillness,
	-- then flying) which is ~240 guarded memory reads a frame -- enough to cost frame rate, and a
	-- probe that costs frame rate changes what it is measuring (_template/probes.md).
	for st = 1, NUM_OBJECT_STRUCTS - 1 do
		local base = OBJECT_STRUCTS + st * OBJECT_LENGTH
		local sprite = u8(base + F_SPRITE)
		if not sprite or sprite == 0 then
			seen[st], trace[st] = nil, nil
		else
			local x, y = u8(base + F_MAP_X) or 0, u8(base + F_MAP_Y) or 0
			local walking = u8(base + F_WALKING) or STANDING
			local s = seen[st]
			if not s or s.x ~= x or s.y ~= y or walking ~= STANDING then
				seen[st] = { x = x, y = y, stillFor = 0 }
			else
				s.stillFor = s.stillFor + 1
			end

			if sprite == playerSprite then
				local stepType = u8(base + F_STEP_TYPE) or 0
				local dur = u8(base + F_STEP_DURATION) or 0
				local sy, sx = u8(base + F_SPRITE_Y) or 0, u8(base + F_SPRITE_X) or 0

				-- A ten-frame history of the four fields that decide whether the engine walks this
				-- object, kept so the runaway can be read BACKWARDS from the frame it started. Which
				-- field changed first, and in which frame, is the whole question -- a snapshot taken
				-- once the object is already flying cannot answer it.
				local t = trace[st]
				if not t then
					t = { n = 0 }
					trace[st] = t
				end
				t.n = t.n + 1
				t[(t.n % 10) + 1] = string.format("f%d w=%d st=%d dur=%d sx=%d sy=%d",
					frames, walking, stepType, dur, sx, sy)

				local badWalk = walking ~= STANDING and (walking & 0x0F) > 11
				local stranded = walking == STANDING and stepType == STEP_TYPE_NPC_WALK and dur > 0
				if (badWalk or stranded) and not flagged[st] then
					flagged[st] = true
					log(string.format("  f=%-7d *** RUNAWAY on struct %d: %s ***", frames, st,
						stranded and "WALKING says STANDING while STEP_TYPE still says NPC_WALK"
						or "WALKING's low nibble is past StepVectors' 12 entries"))
					log(string.format("      map=%d,%d screen=%d,%d action=%d facing=%d dir=%d "
						.. "flags1=0x%02X movement=%d map_object=%s",
						x, y, sx, sy, u8(base + F_ACTION) or 0, u8(base + 0x0D) or 0,
						u8(base + F_DIRECTION) or 0, u8(base + F_FLAGS1) or 0,
						u8(base + F_MOVEMENT_TYPE) or 0, tostring(u8(base + F_MAP_OBJECT_INDEX))))
					log("      the ten frames leading up to it, oldest first:")
					for i = 1, 10 do
						local line = t[((t.n + i) % 10) + 1]
						if line then
							log("        " .. line)
						end
					end
				elseif not (badWalk or stranded) then
					flagged[st] = nil
				end
			end
		end
	end

	if frames % 60 ~= 0 then
		return
	end

	local rows = {}
	for st = 1, NUM_OBJECT_STRUCTS - 1 do
		local base = OBJECT_STRUCTS + st * OBJECT_LENGTH
		local sprite = u8(base + F_SPRITE)
		if sprite and sprite ~= 0 then
			local mo = u8(base + F_MAP_OBJECT_INDEX)
			local flags1 = u8(base + F_FLAGS1) or 0
			local movement = u8(base + F_MOVEMENT_TYPE)
			local wontDelete = (flags1 & FLAG1_WONT_DELETE) ~= 0

			-- The cross-link, both ways -- the same identity test the adapter's stillOurs() uses.
			-- A BROKEN link is the interesting case: it is what makes the adapter forget an object
			-- instead of clearing it, so it is the mechanism by which an orphan is created.
			local linkOk = false
			if mo and mo ~= UNASSIGNED and mo < NUM_MAP_OBJECTS then
				linkOk = u8(MAP_OBJECTS + mo * MAPOBJECT_LENGTH + M_STRUCT_ID) == st
			end

			local marks = {}
			if sprite == playerSprite then marks[#marks + 1] = "wears the PLAYER's sprite" end
			if wontDelete then marks[#marks + 1] = "WONT_DELETE" end
			if movement == SPRITEMOVEDATA_STANDING then marks[#marks + 1] = "movement pinned" end
			if not linkOk then marks[#marks + 1] = "CROSS-LINK BROKEN" end

			local s = seen[st]
			local stillSecs = s and (s.stillFor // 60) or 0

			-- Ours if it carries the two fingerprints the adapter always sets. The movement pin is
			-- reported but not required, because a ghost spawned before 2026-08-21 will not have
			-- it and is exactly the kind of leftover worth catching.
			local looksOurs = (sprite == playerSprite) and wontDelete

			-- THE VERDICT, and it comes from the adapter's own rule rather than from a hunch about
			-- how long is too long. A ghost the adapter is still tracking cannot stand on one tile
			-- for long: IDLE_FRAMES_BEFORE_PASSABLE is 300 frames, and at that point the peer stops
			-- blocking and is handed to the drawn tier, which despawns the spawned object. So one
			-- of OUR objects still sitting in the array well past that is, by construction, one
			-- nothing is tracking any more.
			--
			-- The one legitimate exception is a peer playing an animation in place -- fishing, an
			-- emote -- which as of 2026-08-21 deliberately keeps its spawned slot. So the action
			-- byte is checked too: only a character doing NOTHING for that long is an orphan.
			local action = u8(base + F_ACTION) or 0
			local idleAction = (action == 0 or action == 1 or action == 2)
			local orphan = looksOurs and idleAction and stillSecs > 6

			if orphan then
				marks[#marks + 1] = "ORPHAN: past the 5s the adapter would have released it"
			end

			if looksOurs or not linkOk then
				rows[#rows + 1] = string.format(
					"    struct %-2d -> map object %-3s  sprite %-3d at %d,%d  still for %ds  [%s]%s",
					st, tostring(mo), sprite, u8(base + F_MAP_X) or 0, u8(base + F_MAP_Y) or 0,
					stillSecs,
					(#marks > 0) and table.concat(marks, ", ") or "no fingerprint",
					orphan and "  <== LEFT BEHIND BY US"
						or (looksOurs and "  <== ours, and being driven" or ""))
			end
		end
	end

	local report = table.concat(rows, "\n")
	if report == (lastReport or "") then
		return -- nothing changed; stay quiet
	end
	lastReport = report

	if #rows == 0 then
		log(string.format("  [%ds] nothing carrying our fingerprint is in the arrays.", frames // 60))
		return
	end
	log(string.format("  [%ds] characters worth explaining:", frames // 60))
	log(report)
	log("    (\"still for\" counts seconds without changing tile. A ghost the adapter is driving")
	log("     resets that every time its peer moves; an ORPHAN's just keeps climbing.)")
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
	if logfile then
		pcall(function() logfile:flush() end)
		logfile:close()
		logfile = nil
	end
end

-- A registered callback outlives its script under BizHawk, which is why this is a loop and not
-- event.onframeend (pitfalls.md).
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
