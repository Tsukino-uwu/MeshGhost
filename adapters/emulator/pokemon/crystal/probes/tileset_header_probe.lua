-- MeshGhost — Pokémon Crystal: where does THIS build keep the loaded tileset header? (READ-ONLY)
--
-- WHY. `probes/noclip.lua` redirects `wTilesetCollisionAddress`, and on vanilla that is 01:d1e0
-- (pokecrystal.sym). The Archipelago build rearranges WRAM non-uniformly -- its object array moved +6,
-- its coordinate block +7, its map-object table -0x2A (`meshghost_crystal.lua`, ADDRESSES.archipelago)
-- -- so vanilla's address is not a fact about that build, and writing it would land on something else.
--
-- HOW, WITHOUT A GUESS. The HYPOTHESIS this probe tests: the loaded header in WRAM is a byte-for-byte
-- copy of one 15-byte entry of a ROM table whose entries have three banked pointers ($4000-$7FFF)
-- and two zero bytes at offsets 11-12. So:
--   1. find the table in ROM by that SHAPE -- a run of consecutive 15-byte entries -- and report EVERY
--      run found, not just the longest;
--   2. look for any of those entries, byte for byte, in the CPU-visible WRAM window, and report every
--      match with the tileset index it matched.
-- Fifteen specific bytes matching a ROM entry is not a coincidence a plausible-looking address can
-- produce, which is the failure mode this build's table history is full of. RESULT, 2026-09-13: one
-- table and one WRAM match on each build, and vanilla's at our byte-identical build's .sym addresses
-- (`crystal/VERIFIED.md`) -- which is what turned the hypothesis into a measurement.
--
-- SELF-CHECK. On vanilla V1.0 the table must be found at ROM $4D596 (13:5596) and the header at flat
-- $11D9 (01:d1d9). The log prints both expectations beside what it found, so a run on vanilla proves
-- the method before the Archipelago answer is believed.
--
-- COST. One ROM chunk (64KB) per frame until the table is found, then one 8KB WRAM read every 60
-- frames, six times. Nothing is written. Log: tileset_header_<timestamp>.log beside this file.

local ROM, WRAM = "ROM", "WRAM"
local ENTRY = 15
local CHUNK = 0x10000

local logfile
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/tileset_header_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end
local function log(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end
local function say(msg)
	console.log(msg)
	log(msg)
end

local romSize = memory.getmemorydomainsize(ROM)
local title = ""
for i = 0x134, 0x13E do
	local c = memory.read_u8(i, ROM)
	if c == 0 then break end
	title = title .. string.char(c)
end
say(string.format("=== tileset header probe === ROM title %q, version byte %d, ROM size $%X, WRAM size $%X",
	title, memory.read_u8(0x14C, ROM), romSize, memory.getmemorydomainsize(WRAM)))
say("  vanilla V1.0 expectation: table at ROM $4D596, header at WRAM flat $11D9 (collision ptr $11E0)")

-- b is 1-based (read_bytes_as_array); e is the 0-based offset of an entry within b
local function entryShape(b, e)
	if e + ENTRY > #b then return false end
	local function at(k) return b[e + k + 1] end
	for _, p in ipairs({ 0, 3, 6 }) do
		local addr = at(p + 1) + at(p + 2) * 256
		if at(p) == 0 or at(p) > 0x7F or addr < 0x4000 or addr > 0x7FFF then
			return false
		end
	end
	return at(11) == 0 and at(12) == 0
end

local scanAt, runs = 0, {}
local entries -- list of {index, bytes-string}
local wramReads, frames = 0, 0

local function scanRom()
	local len = math.min(CHUNK + ENTRY * 40, romSize - scanAt)
	local b = memory.read_bytes_as_array(scanAt, len, ROM)
	local limit = math.min(CHUNK, len)
	local e = 0
	while e < limit do
		if entryShape(b, e) then
			local n, k = 0, e
			while entryShape(b, k) do
				n = n + 1
				k = k + ENTRY
			end
			if n >= 20 then
				runs[#runs + 1] = { at = scanAt + e, n = n }
				e = k
			else
				e = e + 1
			end
		else
			e = e + 1
		end
	end
	-- A run that started inside this chunk and ran past it has already been counted whole (the read
	-- carries 40 entries of overlap); resume after it rather than re-finding its tail as a new run.
	scanAt = scanAt + math.max(CHUNK, e)
	return scanAt >= romSize
end

local function hexs(s)
	return (s:gsub(".", function(c) return string.format("%02X ", c:byte()) end))
end

local function readWram()
	local b = memory.read_bytes_as_array(0, 0x2000, WRAM)
	local s = {}
	for i = 1, #b do s[i] = string.char(b[i]) end
	s = table.concat(s)
	local hits = {}
	for _, ent in ipairs(entries) do
		local from = 1
		while true do
			local p = s:find(ent.bytes, from, true)
			if not p then break end
			hits[#hits + 1] = string.format("flat $%04X = tileset %d (collision bank at $%04X, ptr at $%04X)",
				p - 1, ent.index, p - 1 + 6, p - 1 + 7)
			from = p + 1
		end
	end
	wramReads = wramReads + 1
	say(string.format("  WRAM read %d (frame %d): %d match(es)%s", wramReads, frames, #hits,
		#hits > 0 and (": " .. table.concat(hits, "; ")) or " -- NONE"))
end

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	if not entries then
		if not scanRom() then return end
		say(string.format("  ROM scan done: %d run(s) of >=20 tileset-shaped entries", #runs))
		for i, r in ipairs(runs) do
			say(string.format("    run %d: ROM $%05X, %d entries", i, r.at, r.n))
		end
		if #runs == 0 then
			say("  NO TABLE FOUND -- stopping, nothing to match against.")
			entries = {}
			wramReads = 99
			return
		end
		entries = {}
		for _, r in ipairs(runs) do
			local b = memory.read_bytes_as_array(r.at, r.n * ENTRY, ROM)
			for i = 0, r.n - 1 do
				local s = {}
				for k = 1, ENTRY do s[k] = string.char(b[i * ENTRY + k]) end
				entries[#entries + 1] = { index = i, bytes = table.concat(s), run = r.at }
			end
		end
		say(string.format("  %d candidate entries loaded; tileset 1 bytes: %s", #entries,
			entries[2] and hexs(entries[2].bytes) or "?"))
		return
	end
	if wramReads < 6 and frames % 60 == 0 then
		readWram()
		if wramReads == 6 and logfile then
			say("  done (6 reads). Drop this file from the loader target.")
			logfile:flush()
		end
	end
end

MESHGHOST_DEV_UNLOAD = function()
	if logfile then
		pcall(function() logfile:flush() end)
		logfile:close()
		logfile = nil
	end
end
