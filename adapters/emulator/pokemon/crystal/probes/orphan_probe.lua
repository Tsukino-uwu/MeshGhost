-- Read-only: names whether an extra, static character is one this adapter left behind, by the fingerprint no
-- map-placed NPC carries: the local player's sprite id plus WONT_DELETE. despawnGhost() forgets a slot whose identity
-- no longer checks out rather than zeroing one the game may have reused, so an object we made can be left untracked,
-- and WONT_DELETE keeps the engine from reclaiming it. Reports once a second, only on a change. A map change or a
-- savestate load clears any orphan, since both arrays are rebuilt.

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- Per build, from the adapter's measured tables, chosen by the ROM header title as classifyRom() does.
local function romTitle()
	local t = {}
	for i = 0, 9 do
		local c = memory.read_u8(0x134 + i, "ROM")
		if not c then
			return ""
		end
		t[#t + 1] = string.char(c)
	end
	return table.concat(t)
end

local OBJECT_STRUCTS, MAP_OBJECTS = flat(0xD4D6), flat(0xD71E)
local BUILD = "vanilla"
if romTitle():sub(1, 3) == "AP_" then
	OBJECT_STRUCTS, MAP_OBJECTS = 0x14DC, 0x16F4
	BUILD = "Archipelago"
end
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
	-- Buffered, never flushed per line: a flush is a synchronous disk write on the emulator's own thread.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- The console is a GUI append on the emulator's thread, so it gets the first lines and one in twenty; the file all.
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
		-- Flush every 20 lines: a bounded cost, and a log that is never empty for a whole run.
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
-- Which build and where it looks: an empty log from a blind instrument reads like a clean map.
log(string.format("build: %s -- object structs at 0x%04X, map objects at 0x%04X (title %q)",
	BUILD, OBJECT_STRUCTS, MAP_OBJECTS, romTitle()))

local frames = 0
local lastReport = nil

-- Stillness alone is never the verdict (an idle scripted NPC is still too); it is reported beside the fingerprint.
local seen = {} -- struct slot -> { x, y, stillFor }
local flagged = {} -- struct slot -> already reported, so a runaway is said once
local trace = {} -- struct slot -> ring buffer of the last ten frames of step fields

local function tick()
	frames = frames + 1

	-- A flush every five seconds: a report sitting in a buffer reads like nothing found.
	if logfile and frames % 300 == 0 then
		pcall(function() logfile:flush() end)
	end

	local playerSprite = u8(OBJECT_STRUCTS + F_SPRITE)
	if not playerSprite or playerSprite == 0 then
		return -- not in the overworld
	end

	-- One pass a frame over the structs: a probe that costs frame rate changes what it measures.
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

				-- Ten frames of the fields that decide whether the engine walks it, to read a runaway backwards.
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

			-- The cross-link both ways, as the adapter's stillOurs() tests it: a broken link is how an orphan is made.
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

			-- The two fingerprints the adapter always sets; the movement pin is reported but not required.
			local looksOurs = (sprite == playerSprite) and wontDelete

			-- Past the adapter's idle rule (3600 frames) a tracked ghost is handed to the drawn tier and despawned, so
			-- one of ours standing well past it is untracked; a peer animating in place keeps its slot, so idle only.
			local action = u8(base + F_ACTION) or 0
			local idleAction = (action == 0 or action == 1 or action == 2)
			local orphan = looksOurs and idleAction and stillSecs > 75

			if orphan then
				marks[#marks + 1] = "ORPHAN: past the 5s the adapter would have released it"
			end

			-- Every character in the array, not only fingerprinted ones, so the count can be held against the screen.
			do
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
		log(string.format("  [%ds] the object array holds no characters at all besides the player.",
			frames // 60))
		return
	end
	-- Counted, so the log can be held against the screen without counting rows.
	log(string.format("  [%ds] %d character(s) in the array besides the player:",
		frames // 60, #rows))
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

-- Standalone, its own loop: a registered callback outlives its script under BizHawk.
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
