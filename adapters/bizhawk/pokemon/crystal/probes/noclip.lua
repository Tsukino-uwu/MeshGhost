-- MeshGhost — Pokémon Crystal: walk through anything (DEV TOOL, WRITES, never shipped)
--
-- `playing.md` allows driving a running game to reach a state, collision edits explicitly. Getting
-- from a warp tile to the water, the ledge or the corner a test actually needs is the slow part.
--
-- WHY THIS IS NOT EMERALD'S NOCLIP, AND WHY IT TOOK A SECOND LOOK
-- Emerald's version zeroes two collision bits in each live map-grid word, because on GBA the grid
-- is in RAM. On Game Boy it is not: `GetCoordTileCollision` (home/map.asm:1711) takes the block id
-- from the map, indexes the TILESET's collision table, and reads it with `GetFarByte` from a
-- bank -- and that table lives in ROM, which this project never writes.
--
-- The way in is that the POINTER is in RAM. `wTilesetCollisionAddress` (01:d1e0) and
-- `wTilesetCollisionBank` (01:d1df) are what the lookup goes through, and `GetFarByte`
-- (home/copy.asm:54) ends in a plain `ld a, [hl]`. A bank switch only affects the ROM window, so if
-- `hl` points into WRAM instead, the read comes from WRAM and the bank byte stops mattering.
--
-- So: point the collision table at a stretch of WRAM that is already all zeroes. COLL_FLOOR is $00
-- (constants/collision_constants.asm:9), so every block reports "floor" and the game lets you walk.
-- Nothing is patched, nothing in ROM is touched, and putting the two bytes back restores it exactly.
--
-- THE ZERO REGION IS FOUND, NOT ASSUMED. Picking an address that "looks unused" is how you corrupt
-- a save. This scans the CPU-visible WRAM window for the longest run of zeroes and uses that,
-- reports where it found it and how many block ids it covers, and re-checks that the run is still
-- zero -- if the game starts using it, noclip turns itself off rather than inventing collision.
--
-- It must be re-applied after a map load, because loading a tileset rewrites the pointer. That is
-- one comparison of two bytes per frame, not a write.
--
-- HOW TO RUN
--   Add it to the loader's target file; remove the line to put collision back. Log:
--   noclip_<timestamp>.log beside this file.
--
-- WHAT IT DOES NOT DO. Ledges, warps and water are separate mechanisms, not collision bytes -- a
-- ledge still hops you, a door still warps you. It also does not stop a TRAINER seeing you.

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- pokecrystal.sym
local W_COLL_BANK = flat(0xD1DF) -- wTilesetCollisionBank
local W_COLL_ADDR = flat(0xD1E0) -- wTilesetCollisionAddress, little-endian CPU address
local W_TILE_DOWN = flat(0xC2FA) -- wTileDown/Up/Left/Right, four consecutive bytes
local W_MAPGROUP = flat(0xDCB5)

-- The pointer must be a CPU address the game can dereference, so the search is limited to what the
-- CPU can see: C000-CFFF (bank 0) and D000-DFFF (whichever WRAM bank is selected, which Crystal
-- keeps at 1). Higher WRAM banks exist in the flat domain but the CPU cannot reach them here.
local SEARCH_FROM, SEARCH_TO = 0xC000, 0xDFFF

-- Block ids index the table at four bytes each, so a run of N bytes covers N/4 block ids. Most maps
-- use well under 64 distinct blocks; anything less than this is not worth switching on.
local MIN_RUN = 256

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/noclip_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, and never flushed per line: a console.log plus a flush is a synchronous disk
	-- write on the emulator's own thread, measured at 63-83ms -- four to five frames, every time
	-- (pitfalls.md, "ONE console line a second cost 7.4 fps"). A probe that stalls the game is a
	-- probe that changes what it measures.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
	if logfile then
		pcall(function() logfile:setvbuf("full", 4096) end)
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
		pcall(function() logfile:flush() end)
	end
end

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

local function w8(addr, value)
	pcall(memory.write_u8, addr, value & 0xFF, DOMAIN)
end

open_log()
log("=== MeshGhost Crystal noclip (THIS ONE WRITES) ===")

-- Saved before anything is changed, and put back on unload.
local original = { bank = u8(W_COLL_BANK), lo = u8(W_COLL_ADDR), hi = u8(W_COLL_ADDR + 1) }
log(string.format("  original collision table: bank %s at $%02X%02X",
	tostring(original.bank), original.hi or 0, original.lo or 0))

-- Find the longest zero run, in chunks across frames: a 8KB scan in one frame is exactly the kind
-- of blocking loop probes.md warns about.
local scanAt, bestStart, bestLen, runStart, runLen = SEARCH_FROM, nil, 0, nil, 0
local chosen, applied, disabled = nil, false, false
local frames = 0

local function scanChunk()
	local stop = math.min(scanAt + 512, SEARCH_TO + 1)
	while scanAt < stop do
		local v = u8(flat(scanAt))
		if v == 0 then
			if not runStart then
				runStart, runLen = scanAt, 0
			end
			runLen = runLen + 1
			if runLen > bestLen then
				bestStart, bestLen = runStart, runLen
			end
		else
			runStart, runLen = nil, 0
		end
		scanAt = scanAt + 1
	end
	if scanAt <= SEARCH_TO then
		return false
	end

	if not bestStart or bestLen < MIN_RUN then
		log(string.format("  NO USABLE ZERO REGION: longest run was %d bytes, need %d. Noclip is "
			.. "off; nothing was changed.", bestLen, MIN_RUN))
		disabled = true
		return true
	end

	chosen = bestStart
	log(string.format("  using $%04X-$%04X (%d bytes of zeroes) as the collision table -- covers "
		.. "block ids 0-%d, and every one of them reads COLL_FLOOR.",
		bestStart, bestStart + bestLen - 1, bestLen, (bestLen // 4) - 1))
	return true
end

local function apply()
	w8(W_COLL_ADDR, chosen & 0xFF)
	w8(W_COLL_ADDR + 1, (chosen >> 8) & 0xFF)
end

local function tick()
	frames = frames + 1
	if disabled then
		return
	end
	if not chosen then
		scanChunk()
		return
	end

	-- Re-assert after a map load, which rewrites the pointer when it loads a tileset. A comparison,
	-- not a write, on every frame that does not need one.
	local lo, hi = u8(W_COLL_ADDR), u8(W_COLL_ADDR + 1)
	if lo ~= (chosen & 0xFF) or hi ~= ((chosen >> 8) & 0xFF) then
		apply()
		if applied then
			log("  the game reloaded a tileset and took the pointer back -- re-applied.")
		end
	end

	if not applied then
		applied = true
		-- READ BACK, and read something the GAME computed rather than the bytes we wrote: the four
		-- adjacent-tile collision values it recalculates every frame. All zero means the lookup is
		-- coming from our region.
		local d, u2, l, r = u8(W_TILE_DOWN), u8(W_TILE_DOWN + 1), u8(W_TILE_DOWN + 2),
			u8(W_TILE_DOWN + 3)
		log(string.format("  applied. The game now computes its own neighbour collisions as "
			.. "down=%s up=%s left=%s right=%s (0 = floor).",
			tostring(d), tostring(u2), tostring(l), tostring(r)))
		log("  (Those four are recomputed by the game every frame, so any read taken in the same "
			.. "frame as the change is partly stale -- the honest reading is the one below.)")
	end

	-- The honest verification: the same four values a full second later, by which time the game has
	-- recomputed all of them through the new pointer. Logged once.
	if frames == 300 and applied then
		log(string.format("  one second on, the game computes: down=%s up=%s left=%s right=%s "
			.. "(all 0 = every neighbouring tile is floor).",
			tostring(u8(W_TILE_DOWN)), tostring(u8(W_TILE_DOWN + 1)),
			tostring(u8(W_TILE_DOWN + 2)), tostring(u8(W_TILE_DOWN + 3))))
		log("  Walk into a wall to confirm it on screen; remove this file from the loader target "
			.. "to put collision back.")
	end

	-- Is our region still zeroes? If the game starts using it, the collision table becomes whatever
	-- it wrote there, which is worse than no noclip -- so check a sample and stand down if so.
	if frames % 120 == 0 then
		for i = 0, 3 do
			if u8(flat(chosen + i * 61)) ~= 0 then
				log("  the region stopped being zeroes -- putting the original pointer back and "
					.. "switching noclip off rather than inventing collision.")
				w8(W_COLL_ADDR, original.lo or 0)
				w8(W_COLL_ADDR + 1, original.hi or 0)
				disabled = true
				return
			end
		end
	end
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
	if applied and original.lo then
		w8(W_COLL_ADDR, original.lo)
		w8(W_COLL_ADDR + 1, original.hi or 0)
		if original.bank then
			w8(W_COLL_BANK, original.bank)
		end
		log(string.format("  restored the original collision table (bank %s at $%02X%02X). "
			.. "Read back: $%02X%02X.", tostring(original.bank), original.hi or 0, original.lo or 0,
			u8(W_COLL_ADDR + 1) or 0, u8(W_COLL_ADDR) or 0))
	end
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
