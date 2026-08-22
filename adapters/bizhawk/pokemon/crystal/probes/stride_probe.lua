-- MeshGhost — Pokémon Crystal: what the engine DRAWS across one step, per direction
--
-- READ-ONLY DIAGNOSTIC. Writes nothing, spawns nothing, presses nothing, changes nothing on
-- screen. Pair it with `square_drive.lua` and it needs nobody at all.
--
-- WHY THIS EXISTS
-- `phases/phase9.md`, 2026-08-22, first of the open items: *"The drawn tier's stride animation has
-- never been seen running. Its summary line read `0 on a walk frame` all evening, and only one
-- frame per facing was ever captured."* The drawn tier keeps up to TWO distinct mid-step
-- arrangements per facing and alternates them on a free-running 8-frame timer
-- (`WALK_FRAME_HOLD`). Both halves of that are guesses, and neither has ever been measured:
--
--   * HOW MANY distinct images a direction actually has. `documentation.md` says a walking sprite
--     is three views of four tiles and that the walk cycle is produced by MIRRORING -- which for
--     the side view is also what says left from right. If sideways walking therefore has exactly
--     ONE image, a cache slot for a second stride can never fill, and "only one frame per facing"
--     is the game being described correctly rather than a bug.
--   * WHAT SELECTS the stride. `OBJECT_FACING` (0x0d) is a flat index into
--     `data/sprites/facings.asm` -- `STEP_DOWN_0..3` are four entries of one list, so one byte
--     says both direction and stride (`documentation.md`). The engine picks it from its own step
--     machinery. If that pick is a function of step PROGRESS, the drawn tier can derive the stride
--     instead of running a timer -- and progress is ALREADY on the wire as `extras.prog`, which
--     this adapter added for positioning and which then paid a second time by fixing the painted
--     stride. Sending the fact rather than a symptom is the same move a third time.
--
-- A free-running timer cannot be 1:1 by construction: it has no relationship to where the peer
-- actually is in its step, so it drifts against the peer's feet. Whether that is visible is a
-- question for the screen -- but which mapping to draw with is a question for this probe.
--
-- WHAT IT REPORTS
--   * one row per completed step: direction, and every frame of it as `prog|facing|arrangement`;
--   * a table, per direction, of the DISTINCT arrangements seen mid-step and which progress
--     values produced each -- the thing that says whether a stride is derivable from `prog`;
--   * the count the adapter's own cache would have held, so "only one frame per facing" can be
--     read as either a measurement or a defect instead of staying ambiguous.
--
-- THE PAIRING SKEW IS DELIBERATE AND IS THE REASON EVERY ROW CARRIES TWO MOMENTS. OAM is what the
-- engine DREW LAST FRAME; the struct is what it says THIS frame. The adapter's learner was
-- poisoned for a whole session by mixing the two (`pitfalls.md`, 2026-08-22). So every row pairs
-- the arrangement read this frame with the struct state from the PREVIOUS frame -- the state those
-- pixels actually came from -- and a non-contiguous pair is discarded rather than recorded.
--
-- HOW TO RUN
--   Add it to dev-scripts/bizhawk-dev-loader-crystal.target, ideally alongside
--   `probes/square_drive.lua`, which laps a square and so covers all four directions unattended.
--   No timing to hit, no window to catch: walk around for a while and read the table.
--   Log: stride_<timestamp>.log beside this file.

local DOMAIN = "WRAM"

local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

-- Vanilla V1.0 only, on purpose: this asks how the ENGINE animates a sprite, which no ROM patch
-- changes, so a variant table would add a way to be wrong for no gain.
local OBJECT_STRUCTS = flat(0xD4D6)
local W_MAPSTATUS = flat(0xD432)
local MAPSTATUS_HANDLE = 2
local F_SPRITE_TILE, F_WALKING, F_DIRECTION = 0x02, 0x07, 0x08
local F_STEP_DURATION, F_ACTION, F_FACING = 0x0A, 0x0B, 0x0D
local STANDING = 255
local DIR_NAMES = { [0] = "down", [1] = "up", [2] = "left", [3] = "right" }

-- The adapter's own VRAM addressing: bank 1, 16 bytes a tile (`decodeTile`).
local VRAM_BANK1 = 0x2000

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/stride_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- The file is the record; the console is a glance. ONE console line a second was measured at
-- 63-83ms on the emulator's own thread (`pitfalls.md`, 2026-08-21), so the console gets the
-- headline and the summaries, and every per-frame row goes only to the file.
local rawConsole, consoleLines = console.log, 0
local function say(msg)
	consoleLines = consoleLines + 1
	if consoleLines <= 40 then
		rawConsole(msg)
	end
	if logfile then
		logfile:write(msg, "\n")
	end
end

local function log(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end

local function u8(a)
	local ok, v = pcall(memory.read_u8, a, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

-- The player's four OAM entries, normalised exactly the way the adapter's `readPlayerOamFrame`
-- normalises them -- offsets within the sprite's own graphics, and positions measured from the
-- frame's TOP-LEFT rather than from entry 0, which mirrors with the sprite (`pitfalls.md`,
-- 2026-08-22). Same normalisation on purpose: a probe that measures its subject differently from
-- the code it is advising cannot be compared against it.
-- HOW MANY FRAMES THIS PROBE THREW AWAY, AND WHY. Counted rather than assumed, because the
-- rejection below is the one place a probe can silently agree with the code it is auditing.
local rejects = { notfound = 0, extra = 0, notAtZero = 0 }
-- Which OAM index the player's four entries were found at, and how often. If this is always 0 the
-- adapter's assumption holds; anything else is a frame the adapter reads from the wrong character.
local foundAt = {}

-- SEARCH ALL FORTY ENTRIES; DO NOT ASSUME THE PLAYER OWNS 0-3.
--
-- The first version of this probe carried the adapter's own assumption -- the local player is
-- object struct 0 and therefore holds the first four OAM entries -- and threw away 320 of ~640
-- sampled frames as "another character". Half the sample, silently, and exactly the half that
-- could have held the missing stride. `InitSprites` appends characters to the buffer in the order
-- it walks them, so the player's index is whatever that order produces on that frame, not a
-- constant.
--
-- So the player is identified by its GRAPHICS instead of by its position in the buffer: four
-- consecutive entries whose tiles fall inside its own graphics. That is the same "identity, not
-- slot state" rule `phase9.md` already had to learn once for object structs.
--
-- "INSIDE ITS OWN GRAPHICS" IS `(offset & 0x7F) < 12`, NOT `offset < 12`, AND THAT MASK IS THE
-- WHOLE FINDING OF 2026-08-22. A character's three standing views sit at its tile base + 0..11;
-- its three STEPPING views sit at base + 0x80 + 0..11. Measured on two characters at two
-- different bases in one session -- the player (base 0x00, step frames at 0x80-0x8B) and an
-- Olivine NPC (base 0x30, standing at 0x38-0x3B and stepping at 0xB8-0xBB) -- so the +0x80 is
-- relative to the character's own base and not an absolute block.
--
-- A rule of `offset < 12` therefore rejects every stepping frame as if it belonged to somebody
-- else, which is exactly what the adapter does and exactly why its drawn tier never animates.
local function arrangement()
	local base = u8(OBJECT_STRUCTS + F_SPRITE_TILE) or 0
	local at, hits = nil, 0
	for i = 0, 39 do
		local ok, y = pcall(memory.read_u8, i * 4, "OAM")
		if ok and type(y) == "number" and y ~= 0 and y < 160 then
			local offset = ((memory.read_u8(i * 4 + 2, "OAM") or 0) - base) & 0xFF
			if (offset & 0x7F) < 12 then
				hits = hits + 1
				if not at then at = i end
			end
		end
	end
	if not at or hits < 4 then
		rejects.notfound = rejects.notfound + 1
		return nil -- the player is not on screen, or is wearing tiles from somewhere else
	end
	if hits > 4 then
		-- Another character wearing the same sprite would land here. Counted rather than
		-- rejected: with no adapter loaded there is nobody else in this ROM wearing the player's
		-- graphics, so a non-zero count is itself a finding.
		rejects.extra = rejects.extra + 1
	end
	foundAt[at] = (foundAt[at] or 0) + 1
	if at ~= 0 then
		rejects.notAtZero = rejects.notAtZero + 1
	end

	local parts, minX, minY = {}, 255, 255
	for i = at, at + 3 do
		local y = memory.read_u8(i * 4, "OAM") or 0
		local tile = memory.read_u8(i * 4 + 2, "OAM") or 0
		local offset = (tile - base) & 0xFF
		local x = memory.read_u8(i * 4 + 1, "OAM") or 0
		parts[#parts + 1] = { offset = offset, tile = tile, x = x, y = y,
			xflip = ((memory.read_u8(i * 4 + 3, "OAM") or 0) & 0x20) ~= 0 }
		if x < minX then minX = x end
		if y < minY then minY = y end
	end
	local out = {}
	for i = 1, 4 do
		out[i] = string.format("%d%s@%d,%d", parts[i].offset, parts[i].xflip and "F" or "",
			parts[i].x - minX, parts[i].y - minY)
	end
	return table.concat(out, " "), parts
end

-- THE SECOND PLACE AN ANIMATION COULD LIVE, and the reason this probe reads pixels at all.
--
-- An arrangement says WHICH tiles and WHICH WAY ROUND. It says nothing about what is IN those
-- tiles. A Game Boy engine is perfectly free to animate by rewriting a fixed tile block instead of
-- by pointing at different tiles, and if Crystal does that, the arrangement is constant while the
-- character animates -- which is exactly the log this adapter already has, and would mean the
-- drawn tier's whole two-stride cache is asking a question the game does not answer.
--
-- It would also be a defect rather than a free win, and that is worth stating before the numbers
-- arrive: the drawn tier DECODES those same shared VRAM tiles, and CACHES the decode (`pitfalls`
-- has the cache being cleared only on a map load). Tiles that animate would make every drawn peer
-- animate in lockstep with the LOCAL PLAYER's feet rather than its own -- and a stale cache would
-- freeze it on whichever frame it first decoded.
--
-- So: a cheap sum over the 64 bytes the four entries actually name. Constant sum plus constant
-- arrangement means the engine drew the same picture; a changing sum means the pixels moved under
-- a fixed arrangement.
local function tilePixels(parts)
	local sum = 0
	for i = 1, 4 do
		local at = VRAM_BANK1 + parts[i].tile * 16
		for b = 0, 15 do
			sum = (sum * 31 + (memory.read_u8(at + b, "VRAM") or 0)) & 0xFFFFFF
		end
	end
	return sum
end

open_log()
say("=== MeshGhost Crystal stride probe (READ-ONLY) ===")
say("Walk around -- or let square_drive.lua lap. One row per step in the file, a table here.")

-- Per direction: distinct mid-step arrangements, in the order first seen, each with the set of
-- progress values and OBJECT_FACING bytes that produced it. The ORDER matters as much as the
-- count: a stride the adapter could derive shows one arrangement per progress band, while a
-- stride it could not shows the same arrangement under every value.
local seen = { [0] = {}, [1] = {}, [2] = {}, [3] = {} }
local stepsPer = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }

local function note(dir, sig, prog, facing, pixels)
	local bucket = seen[dir]
	for _, e in ipairs(bucket) do
		if e.sig == sig then
			e.n = e.n + 1
			e.progs[prog] = (e.progs[prog] or 0) + 1
			e.facings[facing] = (e.facings[facing] or 0) + 1
			e.pixels[pixels] = (e.pixels[pixels] or 0) + 1
			return
		end
	end
	bucket[#bucket + 1] = { sig = sig, n = 1, progs = { [prog] = 1 }, facings = { [facing] = 1 },
		pixels = { [pixels] = 1 } }
end

local function keyList(t)
	local ks = {}
	for k in pairs(t) do ks[#ks + 1] = tostring(k) end
	table.sort(ks)
	return table.concat(ks, ",")
end

local function countKeys(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

-- THE HEADLINE, and it is written as a verdict rather than a dump so the log settles the question
-- instead of handing back a symptom to characterise a second time (`_template/probes.md`).
local function summary()
	say("---- distinct arrangements the ENGINE drew, per direction, mid-step ----")
	for d = 0, 3 do
		local bucket = seen[d]
		if #bucket == 0 then
			say(string.format("  %-5s : nothing sampled yet", DIR_NAMES[d]))
		else
			say(string.format("  %-5s : %d distinct over %d steps%s", DIR_NAMES[d], #bucket,
				stepsPer[d],
				(#bucket == 1) and "   <-- ONE IMAGE: this direction has no stride to alternate"
					or ""))
			for i, e in ipairs(bucket) do
				local pix = countKeys(e.pixels)
				say(string.format(
					"        %d) [%s]  seen %d frames, prog {%s}, facing byte {%s}, %d pixel set%s%s",
					i, e.sig, e.n, keyList(e.progs), keyList(e.facings), pix,
					(pix == 1) and "" or "s",
					(pix > 1)
						and "   <-- THE TILES THEMSELVES CHANGE: the engine animates in VRAM"
						or ""))
			end
		end
	end
	local where = {}
	for i, n in pairs(foundAt) do where[#where + 1] = string.format("%d:%d", i, n) end
	table.sort(where)
	say(string.format("  the player's four entries were found at OAM index {%s}%s",
		table.concat(where, " "),
		(rejects.notAtZero > 0)
			and string.format("   <-- %d frames NOT at 0: the adapter reads 0-3 unconditionally",
				rejects.notAtZero)
			or "   (always 0, so the adapter's assumption holds)"))
	say(string.format("  discarded: %d frames with no four entries wearing this sprite; "
		.. "%d frames had MORE than four", rejects.notfound, rejects.extra))
	say("A stride is DERIVABLE from prog when each arrangement owns its own progress values;")
	say("if the prog sets overlap, progress does not select the image and something else does.")
	say("One arrangement AND one pixel set for a direction means the character does not animate")
	say("while walking that way at all -- which is an answer, not a missing measurement.")
end

local frames, steps, prev = 0, 0, nil
local current = nil
local flushAt = 0

local function tick()
	frames = frames + 1
	if (u8(W_MAPSTATUS) or 0) ~= MAPSTATUS_HANDLE then
		prev, current = nil, nil
		return
	end

	local walking = (u8(OBJECT_STRUCTS + F_WALKING) or STANDING) ~= STANDING
	local dir = ((u8(OBJECT_STRUCTS + F_DIRECTION) or 0) // 4) & 3
	local dur = u8(OBJECT_STRUCTS + F_STEP_DURATION) or 0
	local facing = u8(OBJECT_STRUCTS + F_FACING) or 0
	local action = u8(OBJECT_STRUCTS + F_ACTION) or 0
	-- The adapter's own derivation, mirrored so the two cannot drift: a normal step is 8 frames
	-- at 2px (StepVectors) and OBJECT_STEP_DURATION counts down through it.
	local prog = 0
	if walking then
		prog = (8 - dur) * 2
		if prog < 0 then prog = 0 end
		if prog > 16 then prog = 16 end
	end
	local sig, parts = arrangement()
	local pixels = parts and tilePixels(parts) or 0

	-- Pair the pixels with the state they were drawn from: OAM read this frame was built from
	-- LAST frame's struct. A gap means the two halves describe different moments, and the honest
	-- response is to record nothing rather than a plausible-looking wrong row.
	local contiguous = prev and prev.at == frames - 1
	if sig and contiguous then
		if prev.walking then
			if not current or current.dir ~= prev.dir then
				if current then
					log(string.format("  step %-4d %-5s (abandoned mid-turn)", current.at,
						DIR_NAMES[current.dir]))
				end
				steps = steps + 1
				stepsPer[prev.dir] = stepsPer[prev.dir] + 1
				current = { dir = prev.dir, rows = {}, at = steps }
			end
			current.rows[#current.rows + 1] =
				string.format("%2d|%02X|%s|px%06X", prev.prog, prev.facing, sig, pixels)
			note(prev.dir, sig, prev.prog, string.format("%02X", prev.facing), pixels)
		elseif current then
			log(string.format("  step %-4d %-5s act=%02X  %s", current.at, DIR_NAMES[current.dir],
				action, table.concat(current.rows, "  ||  ")))
			current = nil
			if steps % 8 == 0 then
				summary()
			end
		end
		-- Standing frames are worth a line too, but only when the image CHANGES: a character at
		-- rest redraws the same arrangement every frame, and 60 identical rows a second buries the
		-- steps between them.
		if not prev.walking and (prev.sig ~= sig or prev.pixels ~= pixels) then
			log(string.format("  f=%-7d STANDING %-5s facing=%02X act=%02X [%s] px%06X", frames,
				DIR_NAMES[prev.dir], prev.facing, action, sig, pixels))
		end
	end

	prev = { at = frames, walking = walking, dir = dir, prog = prog, facing = facing, sig = sig,
		pixels = pixels }

	if logfile and frames - flushAt >= 300 then
		flushAt = frames
		pcall(function() logfile:flush() end)
	end
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
	pcall(summary)
	pcall(function()
		if logfile then
			logfile:flush()
			logfile:close()
			logfile = nil
		end
	end)
end

-- Opened directly rather than through the loader, it needs its own frame loop -- but a loop of its
-- own inside the loader would never return and would freeze every other script in the shared
-- environment (`pitfalls.md`, 2026-08-19). So it runs one or the other, never both.
if not MESHGHOST_DEV_LOADER then
	event.onexit(function()
		pcall(summary)
		pcall(function()
			if logfile then
				logfile:flush()
				logfile:close()
			end
		end)
	end)
	while true do
		tick()
		emu.frameadvance()
	end
end
