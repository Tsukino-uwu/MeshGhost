-- Read-only: what the engine draws across one step, per direction: how many distinct mid-step arrangements each has,
-- and whether the stride follows step progress (extras.prog) rather than a timer. OAM is what the engine drew last
-- frame, so each arrangement is paired with the previous frame's struct. Pair it with square_drive.lua.

local DOMAIN = "WRAM"

local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

-- Vanilla V1.0 only: how the engine animates a sprite is not something a ROM patch changes.
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

-- The file is the record; the console gets the headline and the summaries.
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

-- Frames this probe threw away, and why: the one place a probe can silently agree with the code it audits.
local rejects = { notfound = 0, extra = 0, notAtZero = 0 }
-- Which OAM index the player's entries were found at; anything but 0 is a frame the adapter reads wrong.
local foundAt = {}

-- The player found by its graphics among all forty entries, never assumed at 0-3: entries whose tiles are its
-- standing views (base + 0..11) or stepping views (base + 0x80 + 0..11), normalised as the adapter's
-- readPlayerOamFrame does (offsets within its graphics, positions from the frame's top-left, since entry 0 mirrors).
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
		-- Counted, not rejected: with no adapter loaded nobody else wears the player's graphics, so any count is a
		-- finding.
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

-- An arrangement says which tiles, not what is in them: a sum over the 64 bytes they name shows pixels changing
-- under a fixed arrangement, the engine animating in VRAM.
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

-- Per direction, the distinct arrangements in first-seen order, with the progress values and facing bytes that
-- drew each: a derivable stride has one arrangement per progress band.
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

-- The headline, written as a verdict rather than a dump.
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
	-- The adapter's own derivation: a normal step is 8 frames at 2px, and OBJECT_STEP_DURATION counts down through it.
	local prog = 0
	if walking then
		prog = (8 - dur) * 2
		if prog < 0 then prog = 0 end
		if prog > 16 then prog = 16 end
	end
	local sig, parts = arrangement()
	local pixels = parts and tilePixels(parts) or 0

	-- OAM read this frame was built from last frame's struct; a gap means the halves describe different moments.
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
		-- Standing frames only when the image changes, or 60 identical rows a second bury the steps.
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

-- Its own frame loop only when opened directly: inside the loader a loop never returns and freezes the rest.
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
