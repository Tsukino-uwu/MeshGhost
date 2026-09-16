-- MeshGhost — Pokémon Crystal: measure the numbers the adapter still borrows (2026-09-16)
--
-- DEVELOPMENT TOOL, read-only. It presses nothing and writes nothing but its own log and PNGs.
--
-- WHY THIS EXISTS
-- The per-site audit (phases/phase12.md, 2026-09-16) left three VALUES in shipped code that came
-- from the decompilation alone (crystal/UNVERIFIED.md, the per-site audit entry):
--   * `facingFrames.ROD`   -- the rod tile's dx/dy and flip per fishing direction;
--   * the shadow object's spawn bytes (movement type, flags1, palette, step, facing);
--   * `emote.SHADOW_DY`    -- the shadow's y below the hopping character, per direction.
-- Each is answered by what the ENGINE builds for the PLAYER, so this probe records that and
-- leaves the comparison to whoever reads the log.
--
-- WHAT IT RECORDS. Nothing is filtered before it is written (probes.md: a filter applied before
-- you look is a guess about the answer). A WINDOW opens on any frame where the player's facing is
-- a fishing facing ($10-$13) or any object struct other than the player's holds a nonzero sprite
-- that was not there the frame before -- a spawned shadow is exactly that -- and stays open 60
-- frames after the last trigger, with 8 frames of pre-roll. Per frame in a window:
--   * the frame number, map group/number;
--   * every object struct whose sprite byte is nonzero, all 0x28 bytes in hex, slot index first;
--   * hardware OAM, all 40 entries (y x tile attr) in hex.
-- A line "WINDOW open/close" brackets each window with the reason.
--
-- WHAT IT CANNOT SEE. Only what is resident on the frames the loader ticks it (once per frame,
-- after the frame): a between-frame write is invisible. It says nothing about a GHOST -- the
-- adapter should not be loaded while it runs, so every struct in the log is the game's own.
--
-- COST. Every frame (the pre-roll ring needs it, in or out of a window): up to 13x40 + 160 bytes
-- through read_bytes_as_array, formatted to hex; written only inside a window, buffered, flushed
-- once a second. Not for judging pacing while loaded.
--
-- Dev-loader contract: add this file's absolute path to the window's target file; remove it to stop.

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
-- Vanilla V1.0 addresses, the adapter's own table (hash-verified .sym).
local OBJECT_STRUCTS, OBJECT_LENGTH, NUM_OBJECT_STRUCTS = flat(0xD4D6), 0x28, 13
local W_MAPGROUP, W_MAPNUMBER = flat(0xDCB5), flat(0xDCB6)
local F_FACING = 0x0D

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logdir = (dir:match("^(.*)/probes$") or dir) .. "/logs"
local path = logdir .. "/borrowed_values_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
local f = io.open(path, "w")
if f then f:setvbuf("full", 65536) end

local function out(s)
	if f then f:write(s, "\n") end
end

local function hex(t)
	local p = {}
	for i = 1, #t do p[i] = string.format("%02X", t[i] or 0) end
	return table.concat(p)
end

local function bytes(addr, n, domain)
	local ok, t = pcall(memory.read_bytes_as_array, addr, n, domain)
	if ok and t then
		-- BizHawk returns a 1-based array; normalise in case a build returns 0-based.
		if t[0] ~= nil and t[n] == nil then
			local s = {}
			for i = 0, n - 1 do s[i + 1] = t[i] end
			return s
		end
		return t
	end
	return {}
end

local function u8(a) return memory.read_u8(a, "WRAM") end

local occupied = {} -- slot -> sprite byte last seen there
local function snapshotOccupied()
	for i = 1, NUM_OBJECT_STRUCTS - 1 do
		occupied[i] = u8(OBJECT_STRUCTS + i * OBJECT_LENGTH)
	end
end
snapshotOccupied()

local PRE = 8
local ring, ringN = {}, 0
local open, tail, reason = false, 0, ""
local frames, lastFlush, shot = 0, 0, 0

local function frameLines()
	local L = {}
	L[#L + 1] = string.format("F %d map %d.%d", emu.framecount(), u8(W_MAPGROUP), u8(W_MAPNUMBER))
	for i = 0, NUM_OBJECT_STRUCTS - 1 do
		local base = OBJECT_STRUCTS + i * OBJECT_LENGTH
		if i == 0 or u8(base) ~= 0 then
			L[#L + 1] = string.format("  S%02d %s", i, hex(bytes(base, OBJECT_LENGTH, "WRAM")))
		end
	end
	local oam = bytes(0, 160, "OAM")
	local p = {}
	for e = 0, 39 do
		p[#p + 1] = string.format("%02X%02X%02X%02X", oam[e * 4 + 1] or 0, oam[e * 4 + 2] or 0,
			oam[e * 4 + 3] or 0, oam[e * 4 + 4] or 0)
	end
	L[#L + 1] = "  OAM " .. table.concat(p, " ")
	return L
end

local function trigger()
	local face = u8(OBJECT_STRUCTS + F_FACING)
	if face >= 0x10 and face <= 0x13 then return string.format("fishing facing %02X", face) end
	for i = 1, NUM_OBJECT_STRUCTS - 1 do
		local s = u8(OBJECT_STRUCTS + i * OBJECT_LENGTH)
		if s == 0 then
			occupied[i] = 0 -- forgotten, so the slot's next occupant triggers
		elseif s ~= occupied[i] then
			occupied[i] = s -- an EDGE: once per arrival; the 60-frame tail covers what follows
			return string.format("new sprite %02X in slot %d", s, i)
		end
	end
	return nil
end

out("borrowed_values_probe loaded frame " .. emu.framecount() .. "; log " .. path)
pcall(function() console.log("borrowed_values_probe: logging to " .. path) end)

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local why = trigger()
	local lines = (open or why) and frameLines() or nil
	if why then
		if not open then
			open, reason = true, why
			out(string.format("WINDOW open frame %d: %s", emu.framecount(), why))
			for k = 1, ringN do
				for _, l in ipairs(ring[k]) do out(l) end
			end
			ring, ringN = {}, 0
			shot = shot + 1
			pcall(function()
				client.screenshot(logdir .. string.format("/borrowed_values_%d.png", shot))
			end)
		end
		tail = 60
	end
	if open then
		for _, l in ipairs(lines) do out(l) end
		if not why then
			tail = tail - 1
			if tail <= 0 then
				open = false
				out(string.format("WINDOW close frame %d (opened by: %s)", emu.framecount(), reason))
			end
		end
	else
		-- Pre-roll: a ring of the last PRE frames' full dumps.
		ringN = ringN + 1
		ring[ringN] = frameLines()
		if ringN > PRE then
			table.remove(ring, 1)
			ringN = PRE
		end
	end
	if frames - lastFlush >= 60 and f then
		lastFlush = frames
		pcall(function() f:flush() end)
	end
end

MESHGHOST_DEV_UNLOAD = function()
	if f then
		out("unloaded frame " .. emu.framecount())
		pcall(function() f:close() end)
		f = nil
	end
end
