-- MeshGhost — Pokémon Crystal adapter
--
-- *** WRITES GAME RAM. *** Object RAM only, never a save, cosmetic only, vanilla Crystal V1.0
-- only. See agent_docs/architecture.md's 2026-08-17 ADR, and the ROM guard below.
--
-- WHAT MAKES THIS DIFFERENT FROM EMERALD'S ADAPTER
-- Emerald draws its ghost over the emulator with gui.* and a hand-rolled sprite decode. This one
-- SPAWNS A REAL IN-GAME OBJECT EVENT and lets Crystal render, animate and move it. The adapter
-- draws nothing, animates nothing and interpolates nothing.
--
-- The recipe below was established across Phase 9 and every step of it cost a live test; the full
-- derivation is in agent_docs/phases/phase9.md and the evidence in verified.md. In short:
--   * Copy a live NPC as the template, never the player (the player's MOVEMENT_TYPE means "driven
--     by input", so the engine leaves it to the input system).
--   * Cross-link map object <-> object struct.
--   * Take the PLAYER's sprite/tile/palette for appearance -- resident on every map, so no VRAM
--     allocation is needed, and the correct gender comes along for free.
--   * COMPUTE the screen coordinates; never copy them.
--   * Set WONT_DELETE, or the engine culls the ghost when it leaves the visible window.
--   * To move: write the step-initiation set once per tile while idle, and apply the first 2px
--     yourself -- the engine applies its first increment in the initiating frame and ours would
--     otherwise land 2px short, every step, cumulatively.
--
-- HOW TO RUN
--   1. Start a core (dev-scripts), or let one already be running.
--   2. Load the Crystal ROM in BizHawk, be in the overworld.
--   3. Lua Console -> Script -> Open, pick this file.
--      Log: meshghost_crystal_<timestamp>.log beside this script.

local GAME_ID = "crystal"
local GAME_VERSION = "phase9"

local BRIDGE_HOST = "127.0.0.1"

-- PORT WALK. A core serves exactly ONE adapter (agent_docs/contract.md): a second bridge
-- connection is answered with `reject` and closed. Two copies of one game on one machine is a
-- normal thing to do -- it is how most of this project's adapters were tested -- so an adapter
-- that takes a single fixed port makes the second copy either fail or, worse, silently share the
-- first core. Instead: probe 7778 upward and take the first core that answers `bridge_ready`.
-- Shape copied from Pseudoregalia's BridgeClient, which is the version that has been tested,
-- including the three things it got wrong first (see adapters/_template/PROTOCOL.md).
local BRIDGE_BASE_PORT = 7778
local BRIDGE_PORT_COUNT = 8

-- An explicit port is still honoured and then NOT walked: someone who names a port means that
-- port, and silently landing somewhere else would be worse than failing.
local BRIDGE_PORT_OVERRIDE = tonumber(MESHGHOST_BRIDGE_PORT or os.getenv("MESHGHOST_BRIDGE_PORT") or "")

local RECONNECT_FRAMES = 120
-- How long to leave a core alone after it says it cannot reach the relay. Long enough that the
-- adapter is not hammering a dead relay, short enough that a relay coming back is noticed within
-- a few seconds. 600 frames = 10s.
local RELAY_DOWN_BACKOFF_FRAMES = 600
-- Silence is NOT acceptance. Something that accepts a connection and never answers is far more
-- likely an unrelated program holding a port in our range than a core, and committing to it
-- strands the session with no ghosts and no explanation. 90 frames = 1.5s, matching Pseudoregalia.
local HELLO_ANSWER_FRAMES = 90
-- A port whose core said "busy" is a live core that simply is not ours; re-probing it every sweep
-- is noise. 600 frames = 10s.
local BUSY_PORT_COOLDOWN_FRAMES = 600

-- DEV-ONLY loopback offset, in tiles. A loopback relay echoes your own state back to you, so
-- without this the ghost spawns on the tile you are standing on — and this ghost is a real object
-- event with real collision, so that means standing inside something solid.
--
-- Offset to the SIDE rather than trailing behind, so the ghost can be compared against the real
-- character rather than hidden by it (user's standing preference for test ghosts). Set to 0 for a
-- real two-machine session, where a peer's position is already their own.
-- Each of these can also be set as a GLOBAL before this file is dofile()'d, which is how a second
-- instance gets a different bridge port without restarting an already-open emulator to change an
-- environment variable. See run_second_client.lua.
local LOOPBACK_OFFSET_X = tonumber(MESHGHOST_LOOPBACK_OFFSET_X or os.getenv("MESHGHOST_LOOPBACK_OFFSET_X") or "") or 0

-- SIDE-BY-SIDE TIER COMPARISON (dev only, off by default) -- MESHGHOST_COMPARE_TIERS.
--
-- The loopback ghost is rendered TWICE from the same peer state: SPAWNED two tiles to the right,
-- where the engine draws it and gives it occlusion, palettes and whatever a cave or water does to
-- a character for free; PAINTED two tiles to the left, where it gets none of that unless we built
-- it. What the drawn tier is missing is a question about a place -- a dark cave, a water
-- reflection, a doorway -- and no amount of flag-flipping between two runs answers it, because
-- the place is gone by the time the other renderer is on. Both at once, in one frame, does.
--
-- The user's request and the intended dev default for eyeballing a BizHawk drawn tier,
-- 2026-08-19. It applies ONLY to the "<id>-ghost" loopback echo -- a real peer is never
-- duplicated -- and it supplies its own +2 for the spawned side when no offset was set, since two
-- ghosts stacked on the player is the comparison this exists to avoid.
local COMPARE_TIERS = (MESHGHOST_COMPARE_TIERS or os.getenv("MESHGHOST_COMPARE_TIERS")) and true or false
-- ONE TABLE, not five names. This file sits at Lua's 200-local limit for a main chunk and has hit
-- it twice on 2026-08-21, each time as a bare "LOAD FAILED" with the whole adapter not loading --
-- so related constants get grouped rather than each spending one of the 200.
--
-- The hardware copy sits furthest out, so the three renderers read left-to-right as
-- hardware, drawn, player, spawned. The user's layout, 2026-08-21.
local COMPARE = { drawn = -2, spawned = 2, hw = -4 }
-- The drawn copy lives in `overflow` under a key of its own, so it animates frame to frame like
-- any other drawn peer while never colliding with the spawned copy's entry under the real id.
function COMPARE.key(id) return id .. " (drawn copy)" end
function COMPARE.hwKey(id) return id .. " (hardware copy)" end

local DOMAIN = "WRAM"
local ROM_DOMAIN = "ROM"

----------------------------------------------------------------------------
-- Addresses. All from our own hash-verified pokecrystal build; see verified.md.
----------------------------------------------------------------------------

local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

-- ONE TABLE PER ROM BUILD, selected by classifyRom() at startup. A build that rearranges WRAM
-- does not get vanilla's addresses "because they are close" -- it gets its own measured set or it
-- does not run at all. Every entry here is traceable: vanilla's to our own hash-verified
-- pokecrystal build, Archipelago's to a dated probe log (verified.md, 2026-08-18).
local ADDRESSES = {
	vanilla = {
		label = "vanilla Crystal V1.0",
		OBJECT_STRUCTS = flat(0xD4D6), -- 01:d4d6, 13 x 0x28
		MAP_OBJECTS = flat(0xD71E), -- 01:d71e, 16 x 0x10
		W_MAPGROUP = flat(0xDCB5),
		W_MAPNUMBER = flat(0xDCB6),
		-- the VISIBLE WINDOW origin, not the player
		W_YCOORD = flat(0xDCB7),
		W_XCOORD = flat(0xDCB8),
		W_MAPSTATUS = flat(0xD432),
		W_BATTLEMODE = flat(0xD22D),
		W_BGMAPOFFSETX = flat(0xD14C),
		W_BGMAPOFFSETY = flat(0xD14D),
		-- 01:d154, 32 two-byte entries ending at 01:d194 (wUsedSpritesEnd), which is
		-- SPRITE_GFX_LIST_CAPACITY * 2. Each entry is [sprite id, VRAM tile base]: the id is put
		-- there by AddSpriteGFX as the map loads, and ArrangeUsedSprites then overwrites the
		-- second byte with the tile the sprite's graphics were actually placed at. So this table
		-- is the answer to "is sprite N loaded right now, and where" -- the question a peer's own
		-- appearance depends on. Read-only here; nothing writes into it.
		W_USEDSPRITES = flat(0xD154),
		-- 01:d0ed. Bit 0 is SPRITE_UPDATES_DISABLED_F: _UpdateSprites returns immediately unless it
		-- is SET, and while it is clear the game has cleared the sprite buffer itself (the START
		-- menu). The hardware tier reads it so it stays out exactly when the game wants nobody drawn.
		W_STATEFLAGS = flat(0xD0ED),
		-- OverworldSprites, 05:4736 -> bank 5 * 0x4000 + (0x4736 - 0x4000). Six bytes per entry
		-- (address, size, bank, type, palette), indexed by SPRITE_* - 1. Used by the drawn tier to
		-- read a peer's graphics straight from the cartridge.
		OVERWORLD_SPRITES_ROM = 0x14736,
	},

	-- Archipelago's Crystal patch. MEASURED, never derived -- three separate vanilla relationships
	-- failed on this build before these four were established the hard way (verified.md):
	-- the coordinate block moved +7, the object array +6, and the map-object table -0x2A. Deltas
	-- from vanilla are noted only to show they disagree; nothing here is computed from them.
	--
	-- INCOMPLETE ON PURPOSE. The nil entries below have not been measured, and a nil is what makes
	-- this table refuse to run rather than silently write somewhere plausible. Fill one in only
	-- from a probe log, never from the delta of its neighbour -- that is exactly the reasoning
	-- that produced the three failures above.
	archipelago = {
		label = "Archipelago-patched Crystal",
		OBJECT_STRUCTS = 0x14DC, -- vanilla+6; player in slot 0, NPCs in 1-2, zeroes after
		MAP_OBJECTS = 0x16F4, -- vanilla-0x2A; struct_id/sprite/y/x agree with the array both ways
		W_YCOORD = 0x1CBE, -- vanilla+7; moved -1 walking up, +1 walking back down
		W_XCOORD = 0x1CBF, -- vanilla+7; moved with left/right only
		-- Measured by watching WHEN they change, not whether: across ten map transitions these
		-- two moved only on the transition itself, while seven candidates that survived two
		-- snapshot runs turned out to move constantly WITHIN a map. The group held 24 throughout
		-- (every map visited was in one group) and the number tracked each door.
		W_MAPGROUP = 0x1CBC,
		W_MAPNUMBER = 0x1CBD,
		-- So the block IS four consecutive bytes at vanilla+7 after all -- group, number, Y, X at
		-- 0x1CBC-0x1CBF. What was wrong in the refuted derivation was the LABEL: AP publishes 7359
		-- as wMapGroup and it is the X coordinate, three bytes past where the name implied.
		-- 0x0FB1 is the byte the GATE wants, and the name is provisional. It reads 2 during
		-- normal overworld play, 0 in a battle, and 1 while a map is entering (the reload after a
		-- battle ends) -- three values behaving exactly like wMapStatus's own. But Phase 9
		-- established on VANILLA that wMapStatus alone lets a battle through, and this byte does
		-- not, so it may well be something else that happens to track play state. The gate needs
		-- the behaviour, not the name; do not "correct" this to a tidier address on the strength
		-- of the label. Measured across two state runs plus two battle runs (verified.md).
		-- 0x0FB1 was the single survivor of two snapshot runs, and a live run then showed it
		-- FLICKERING between 2 and 1 several times a second while simply standing in the
		-- overworld -- so it is not wMapStatus, and the snapshots only ever agreed because they
		-- sampled while standing still and phase-locked. 0x1439 is vanilla+7 and held 2 across
		-- 1103 samples of walking. Override with MESHGHOST_CRYSTAL_STATUS_ADDR to compare.
		W_MAPSTATUS = tonumber(os.getenv("MESHGHOST_CRYSTAL_STATUS_ADDR") or "") or 0x1439,
		-- MEASURED 2026-08-19 by fighting a TRAINER battle -- the rival's Totodile in Cherrygrove
		-- City -- after two wild battles on Route 30. Ten candidates all read 1 in a wild battle;
		-- 0x1234 was the only one that read 2 in the trainer battle, held it for the whole fight
		-- and returned to 0 when it ended. 0x015A, the other candidate, read 1 in BOTH, which is
		-- what rules it out. Vanilla semantics confirmed on this build: 0 outside, 1 wild,
		-- 2 trainer. It is also vanilla's 0xD22D -> flat 0x122D plus 7, the same delta the
		-- coordinate block moved -- corroboration, not the derivation. See verified.md.
		W_BATTLEMODE = 0x1234,
		-- MEASURED 2026-08-19 by scanning the patched ROM for the table's own signature -- a run
		-- of 6-byte entries whose address is 0x4000-0x7FFF, size is 192 or 64 bytes, type is 1-3
		-- and palette is 0-7. The same scan finds vanilla's table at its known 0x14736 with 102
		-- entries, which is what makes the method trustworthy rather than a guess; on the patched
		-- ROM it finds 102 entries at 0x14564. Cross-checked by content: 97 of the 102 sprites'
		-- graphics are byte-identical between the two ROMs, including CHRIS, KRIS and RED, and the
		-- five that differ are the tail the patch adds. See verified.md.
		OVERWORLD_SPRITES_ROM = 0x14564,

		-- NOT the table. These are the leading unconfirmed candidates for the entries still nil
		-- above, used only when MESHGHOST_CRYSTAL_AP_TRY=1 asks for a deliberate experiment, and
		-- logged as unconfirmed every time. Kept separate from the real fields on purpose: a
		-- candidate that can be read by ordinary code eventually gets treated as measured.
		-- 0x015A sat here as the leading W_BATTLEMODE candidate until 2026-08-19, when a trainer
		-- battle showed it reading 1 exactly as it does in a wild one. Refuted, not measured.
		candidates = {},
		-- Pixel scroll offsets, and the only pair here measured by CORRELATION rather than by a
		-- filter: across 137 real tile steps, 0x1153 moved on 70 of 70 X steps and 1 of 67 Y
		-- steps, 0x1154 the exact mirror. They sweep 0,2,4..254 within a step, which is the shape
		-- nothing else in this region has. (Also vanilla+7, noticed after the fact, not before.)
		W_BGMAPOFFSETX = 0x1153,
		W_BGMAPOFFSETY = 0x1154,
	},
}

-- Assigned once, from the selected table, before the main loop runs.
local OBJECT_STRUCTS, MAP_OBJECTS
local W_MAPGROUP, W_MAPNUMBER, W_YCOORD, W_XCOORD
local W_MAPSTATUS, W_BATTLEMODE, W_BGMAPOFFSETX, W_BGMAPOFFSETY
-- nil on any build where it has not been measured (Archipelago's), which switches the peer's own
-- appearance off rather than reading a plausible address.
local W_USEDSPRITES, W_STATEFLAGS
local USED_SPRITES_CAPACITY = 32 -- SPRITE_GFX_LIST_CAPACITY

local OBJECT_LENGTH, MAPOBJECT_LENGTH = 0x28, 0x10
local NUM_OBJECT_STRUCTS, NUM_MAP_OBJECTS = 13, 16

local M_STRUCT_ID, M_SPRITE, M_Y, M_X = 0x00, 0x01, 0x02, 0x03
local F_SPRITE, F_MAP_OBJECT_INDEX, F_SPRITE_TILE = 0x00, 0x01, 0x02

-- SPRITEMOVEDATA_STANDING_DOWN/UP/LEFT/RIGHT are 0x06..0x09, in the same down/up/left/right order
-- this adapter uses for `dir` everywhere else, so the entry for a direction is simply 6 + dir.
--
-- All four have the same movement FUNCTION -- SPRITEMOVEFN_STANDING, "stand and do nothing else"
-- -- which is what a ghost needs between the steps we drive it through. They differ only in the
-- facing they restore, and that difference matters: when a movement ends, StepFunction_Restore
-- calls RestoreDefaultMovement (which re-reads MAPOBJECT_MOVEMENT) and then GetInitialFacing, and
-- writes the result into OBJECT_DIRECTION. So this byte is re-read after EVERY step, not only when
-- the engine first builds the object -- pinning all four directions to the DOWN entry would turn
-- the ghost to face down for a frame at the end of every step.
local SPRITEMOVEDATA_STANDING_BY_DIR = { [0] = 0x06, [1] = 0x07, [2] = 0x08, [3] = 0x09 }
local F_FLAGS1, F_PALETTE = 0x04, 0x06
local F_WALKING, F_DIRECTION, F_STEP_TYPE, F_STEP_DURATION = 0x07, 0x08, 0x09, 0x0A
local F_ACTION, F_FACING = 0x0B, 0x0D
local F_MAP_X, F_MAP_Y = 0x10, 0x11
local F_LAST_MAP_X, F_LAST_MAP_Y = 0x12, 0x13
local F_INIT_X, F_INIT_Y = 0x14, 0x15
local F_SPRITE_X, F_SPRITE_Y = 0x17, 0x18

local FLAG1_WONT_DELETE = 0x02
local STANDING = 255
local MAPSTATUS_HANDLE = 2
local UNASSIGNED = 0xFF

----------------------------------------------------------------------------
-- Logging
----------------------------------------------------------------------------

-- Under BizHawk, debug.getinfo's `source` is "main" rather than "@<path>", so it yields nothing
-- usable — which is exactly why Emerald's own scriptDir() carries a pwd fallback, and why omitting
-- one here produced four failed paths on the first run (2026-08-18).
--
-- The working directory IS the script's directory when BizHawk loads a Lua file, confirmed live:
-- `cd` returned C:\dev\MeshGhost\adapters\bizhawk\pokemon\crystal. So pwd is the primary answer here, not
-- the fallback.
local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		local dir = info.source:sub(2):match("^(.*)[/\\]")
		-- Only an ABSOLUTE answer counts. A relative one ("." from a dofile) satisfies this branch,
		-- skips the pwd fallback below, and then fails where it matters -- LuaSocket is loaded with
		-- package.loadlib, and Windows resolves a relative DLL path against the PROCESS directory
		-- (BizHawk's), never the working directory, so "./../emerald/lib/x64/" cannot work even when
		-- the folder is sitting right there. Cost this exact failure twice on 2026-08-18: once from
		-- an empty source under BizHawk, once from loading this file through run_second_client.lua.
		if dir and #dir > 0 and (dir:match("^%a:") or dir:match("^[/\\]")) then
			return dir
		end
	end
	-- MESHGHOST_SCRIPT_DIR, if whatever launched us set it. Free, absolute, and spawns nothing.
	-- Needed because `--lua=<path>` makes BizHawk report `source` as `[string "main"]` rather
	-- than a path, so the branch above cannot answer at all in that case.
	-- Game-specific FIRST -- see the same note in Emerald's adapter: an env var is process-wide,
	-- BizHawk runs every script in one process, so a shared name leaks one adapter's folder into
	-- the next one loaded.
	local fromEnv = MESHGHOST_SCRIPT_DIR
		or os.getenv("MESHGHOST_SCRIPT_DIR_CRYSTAL")
		or os.getenv("MESHGHOST_SCRIPT_DIR")
	if fromEnv and fromEnv ~= "" then
		return (fromEnv:gsub("[/\\]$", ""))
	end

	-- Last resort. It answers with the WORKING directory rather than this script's, so it is only
	-- right when the two agree, and it spawns a real `cmd` -- the console window that flashes on
	-- launch. Removing it outright on 2026-08-18 broke Emerald's `--lua=` loading instantly, which
	-- is how the "unreachable fallback" comment was shown to be wrong; kept here for the same
	-- reason, and now reached only when nothing better was offered.
	local p = io.popen and io.popen("cd")
	if p then
		local out = p:read("*l")
		p:close()
		if out and #out > 0 then
			return out
		end
	end
	return "."
end

local SCRIPT_DIR = scriptDir()
-- Prefer a logs/ subfolder, so the adapter folder stays readable across a session that reloads
-- the script many times (each run opens its own timestamped file). No mkdir needed: io.open fails
-- when the directory is absent, and that failure IS the fallback.
--
-- THE NAME CARRIES THIS EMULATOR'S PROCESS ID, and that is not decoration. Two emulators running
-- the same game (a vanilla ROM and a patched seed, which is the normal two-instance session here)
-- run this same script, and a name resolved only to the SECOND collides whenever both reload in
-- the same second -- which is exactly what a control-file edit or a shared restart does. Both then
-- hold the same file open and their lines interleave mid-write, producing mangled lines where one
-- write landed inside another. Found live on the Emerald adapter 2026-08-19 and back-ported here
-- unchanged, because this file has the identical shape; a pid cannot collide while both processes
-- exist, where a port can (the bridge port is walked when it is not pinned).
local logfile
do
	local okPid, pid = pcall(function()
		luanet.load_assembly("System")
		return luanet.import_type("System.Diagnostics.Process").GetCurrentProcess().Id
	end)
	-- No pid available (a BizHawk build without luanet): fall back to a pinned bridge port, and
	-- then to the clock's fractional part -- any discriminator beats none, because the failure
	-- being prevented is silent corruption of the file rather than a missing one.
	local tag = (okPid and pid) or BRIDGE_PORT_OVERRIDE
		or math.floor((os.clock() % 1) * 100000)
	local name = string.format("meshghost_crystal_%s_%s.log", os.date("%Y%m%d_%H%M%S"), tostring(tag))
	logfile = io.open(SCRIPT_DIR .. "/logs/" .. name, "w") or io.open(SCRIPT_DIR .. "/" .. name, "w")
	-- BUFFER IT. Every log line used to be followed by a flush, which is a synchronous disk write
	-- on the game thread -- and the game thread is the emulator. Measured 2026-08-21: a script
	-- whose ONLY per-second work was writing one log line produced exactly one 63-78ms stall every
	-- second, four to five frames, while the frame-rate average still read 59.7. That is precisely
	-- what the user had been reporting for the whole session -- *"choppy/laggy"* on a game that
	-- measured full speed. `logFile` is called every second by the drawn tier whenever peers are
	-- present, so this was shipping to players, not just to the dev rig.
	if logfile then
		pcall(function() logfile:setvbuf("full", 16384) end)
	end
end

local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
	end
end

-- File only. A per-tick diagnostic in the Lua Console scrolls the startup lines out of view, and
-- those name the ROM and every address in use -- which is what a reader actually needs
-- (probes.md: detail to the log file, headlines to the console).
--
-- DELIBERATELY UNFLUSHED, and this is the line that mattered: the drawn tier calls it once a
-- second whenever peers are present, and a flush is a synchronous disk write on the emulator's own
-- thread. Measured 2026-08-21: 63-83ms per write, four to five frames, every second, while the
-- frame-rate average still read 59.7fps. The buffer is pushed to disk on the timer in tick() and
-- by close() on the way out. `log` above still flushes -- it is rare, and an error worth printing
-- is worth having on disk before whatever follows it.
local function logFile(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end

----------------------------------------------------------------------------
-- LuaSocket. Same bootstrap as Emerald's adapter -- lua54.dll must be pre-loaded by full path
-- first, because Windows' LoadLibrary does not search the loading DLL's own directory for it.
-- See agent_docs/architecture.md's Phase 3 ADR for the full derivation.
----------------------------------------------------------------------------

local function loadSocketCore()
	if package.config:sub(1, 1) ~= "\\" then
		error("MeshGhost: only Windows is supported by the vendored LuaSocket binary so far.")
	end
	-- The vendored pair lives beside Emerald's adapter today. Try next to this script first (so a
	-- shipped per-game folder works), then Emerald's copy, then the same paths relative to the working
	-- directory — because `debug.getinfo` is not dependable under BizHawk, which is exactly why
	-- Emerald's own scriptDir() carries a pwd fallback. Getting this wrong produced an empty log
	-- and an unexplained error on the first run, 2026-08-18.
	--
	-- Every attempt is logged. A loader that fails silently is what made that first failure take a
	-- round trip to diagnose.
	-- There used to be an io.popen("cd") here building one more candidate path from the working
	-- directory. It ran unconditionally, so EVERY launch spawned a `cmd` and flashed a console
	-- window -- the user spotted it on screen. Removed 2026-08-18: SCRIPT_DIR is resolved from
	-- debug.getinfo and is the reliable answer, so the candidates below already cover every real
	-- layout without paying a process for it.

	local candidates = {
		SCRIPT_DIR .. "/lib/x64/",
		SCRIPT_DIR .. "/../emerald/lib/x64/",
		"adapters/bizhawk/pokemon/emerald/lib/x64/",
	}
	for _, dir in ipairs(candidates) do
		pcall(function()
			package.loadlib(dir .. "lua54.dll", "meshghost_force_preload")
		end)
		local ok, fn = pcall(package.loadlib, dir .. "socket-windows-5-4.dll",
			"luaopen_socket_core")
		if ok and type(fn) == "function" then
			log("MeshGhost: LuaSocket loaded from " .. dir)
			return fn()
		end
		log("MeshGhost: no LuaSocket at " .. dir)
	end
	error("MeshGhost: could not load the vendored LuaSocket binary from any of the paths above.")
end

local socketCore = loadSocketCore()

----------------------------------------------------------------------------
-- Minimal JSON. Encode only what we send; decode enough for what we receive.
----------------------------------------------------------------------------

local ESCAPES = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function jsonEscape(s)
	return (s:gsub('[%c"\\]', function(c)
		return ESCAPES[c] or string.format("\\u%04x", c:byte())
	end))
end

local function jsonEncode(v)
	local t = type(v)
	if v == nil then
		return "null"
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "number" then
		return string.format("%.14g", v)
	elseif t == "string" then
		return '"' .. jsonEscape(v) .. '"'
	elseif t == "table" then
		if v[1] ~= nil or next(v) == nil then
			local parts = {}
			for _, item in ipairs(v) do
				parts[#parts + 1] = jsonEncode(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, item in pairs(v) do
			parts[#parts + 1] = '"' .. jsonEscape(tostring(k)) .. '":' .. jsonEncode(item)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

-- Small recursive-descent decoder. Enough for the bridge's messages; not a general JSON library.
local function jsonDecode(s)
	local pos = 1
	local function skip()
		while pos <= #s and s:sub(pos, pos):match("[ \t\r\n]") do
			pos = pos + 1
		end
	end
	local parseValue
	local function parseString()
		pos = pos + 1
		local out = {}
		while pos <= #s do
			local c = s:sub(pos, pos)
			if c == '"' then
				pos = pos + 1
				return table.concat(out)
			elseif c == "\\" then
				local n = s:sub(pos + 1, pos + 1)
				local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
				if n == "u" then
					out[#out + 1] = "?"
					pos = pos + 6
				else
					out[#out + 1] = map[n] or n
					pos = pos + 2
				end
			else
				out[#out + 1] = c
				pos = pos + 1
			end
		end
		return table.concat(out)
	end
	parseValue = function()
		skip()
		local c = s:sub(pos, pos)
		if c == '"' then
			return parseString()
		elseif c == "{" then
			pos = pos + 1
			local obj = {}
			skip()
			if s:sub(pos, pos) == "}" then
				pos = pos + 1
				return obj
			end
			while true do
				skip()
				local k = parseString()
				skip()
				pos = pos + 1 -- ':'
				obj[k] = parseValue()
				skip()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "}" then
					return obj
				end
			end
		elseif c == "[" then
			pos = pos + 1
			local arr = {}
			skip()
			if s:sub(pos, pos) == "]" then
				pos = pos + 1
				return arr
			end
			while true do
				arr[#arr + 1] = parseValue()
				skip()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "]" then
					return arr
				end
			end
		elseif s:sub(pos, pos + 3) == "true" then
			pos = pos + 4
			return true
		elseif s:sub(pos, pos + 4) == "false" then
			pos = pos + 5
			return false
		elseif s:sub(pos, pos + 3) == "null" then
			pos = pos + 4
			return nil
		else
			local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if num then
				pos = pos + #num
				return tonumber(num)
			end
			pos = pos + 1
			return nil
		end
	end
	local ok, result = pcall(parseValue)
	if ok then
		return result
	end
	return nil
end

----------------------------------------------------------------------------
-- Memory helpers and the ROM guard
----------------------------------------------------------------------------

local function u8(addr, domain)
	-- A NIL ADDRESS MUST NOT READ AS ZERO. BizHawk's memory.read_u8(nil) succeeds and returns 0
	-- rather than failing -- measured 2026-08-19, not assumed. An unmeasured entry in an ADDRESSES
	-- table is nil by design, and phase9.md's promise is that the adapter then "refuses rather
	-- than writing somewhere plausible". Without this guard that promise was not kept: nil read as
	-- byte 0, so `u8(W_BATTLEMODE) == 0` was silently ALWAYS TRUE on any build with that entry
	-- unmeasured -- i.e. the adapter believed no battle was ever happening, and drew ghosts over
	-- the battle screen. Reported by the user on the Archipelago build, whose W_BATTLEMODE was nil
	-- until it was measured that same day.
	if addr == nil then
		return nil
	end
	local ok, v = pcall(memory.read_u8, addr, domain or DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

local function w8(addr, value)
	pcall(memory.write_u8, addr, value, DOMAIN)
end

-- ROM classification, three-way rather than pass/fail (user's call, 2026-08-18).
--
--   "known"        vanilla V1.0 — the addresses below were derived from a byte-identical build.
--   "archipelago"  Archipelago's Crystal patch, which rearranges WRAM non-uniformly. It no longer
--                  means "refuse": it selects ADDRESSES.archipelago, a measured set of its own.
--                  It still refuses while that set is incomplete — see the startup check, which
--                  names the missing entries rather than falling back to vanilla's. Falling back
--                  would be the corrupting case this class exists to prevent.
--   "unknown"      anything else — another revision, a romhack, a translation. **Warn loudly and
--                  RUN.** Refusing guarantees an untested-but-fine ROM does not work, where trying
--                  it might. The cost of being wrong is bounded: this adapter writes only object
--                  RAM and never a save, so the worst case is a visual mess cleared by a map
--                  reload or a reset.
local function classifyRom()
	local t = {}
	for i = 0, 9 do
		local c = u8(0x134 + i, ROM_DOMAIN)
		if not c then
			return "unknown", "could not read the ROM domain at all"
		end
		t[#t + 1] = string.char(c)
	end
	local title = table.concat(t)
	if title == "PM_CRYSTAL"
		and u8(0x14E, ROM_DOMAIN) == 0x12 and u8(0x14F, ROM_DOMAIN) == 0x9F then
		return "known", "vanilla Crystal V1.0", "vanilla"
	end
	-- Archipelago renames the header, which is a cheaper and stronger signal than the checksum --
	-- and seed-independent, which the checksum is not: every seed patches different item data on
	-- top of one shared base recompile. Emerald's adapter relies on the same property for its own
	-- Archipelago addresses; if a future world update recompiles that base, the measured addresses
	-- move and the fingerprint check below is what notices.
	if title:sub(1, 3) == "AP_" then
		return "archipelago", string.format("ROM title %q — Archipelago's Crystal patch", title),
			"archipelago"
	end
	return "unknown", string.format("ROM title %q, checksum %02X%02X — not a build these addresses "
		.. "were derived from", title, u8(0x14E, ROM_DOMAIN) or 0, u8(0x14F, ROM_DOMAIN) or 0),
		"vanilla"
end

-- The in-game gate. Established empirically in Phase 9, and BOTH terms were needed: wMapStatus
-- alone lets a battle through, and adding the event/script flags makes it flicker every step.
-- IS THE OVERWORLD THE THING ON SCREEN RIGHT NOW?
--
-- A POSITIVE test, never a list of things to avoid. A battle, a full-screen menu, an evolution
-- screen, the naming screen, the Pokedex, a cutscene and the title screen are all one case -- "not
-- the overworld" -- and a deny-list of them will never be finished, while every entry it is
-- missing shows up as a ghost painted over that screen. Two such reports arrived on 2026-08-19,
-- one for menus and one for battles; see pitfalls.md.
--
-- Every term must be a KNOWN value. `nil` is "this build has not been measured here", and it makes
-- the answer no -- it must never be allowed to satisfy a term by accident, which is what happened
-- before u8() guarded a nil address (see there).
local function inPlay()
	local status, battle = u8(W_MAPSTATUS), u8(W_BATTLEMODE)
	local group, number = u8(W_MAPGROUP), u8(W_MAPNUMBER)
	local playerSprite = u8(OBJECT_STRUCTS + F_SPRITE)
	if status == nil or battle == nil or group == nil or number == nil or playerSprite == nil then
		return false -- an unmeasured address, or a read that failed: refuse rather than guess
	end
	return status == MAPSTATUS_HANDLE
		and battle == 0
		and not (group == 0 and number == 0)
		and playerSprite ~= 0
end

local function areaId()
	return string.format("%d/%d", u8(W_MAPGROUP) or -1, u8(W_MAPNUMBER) or -1)
end

----------------------------------------------------------------------------
-- get_local_state
----------------------------------------------------------------------------

local DIR_NAMES = { [0] = "down", [4] = "up", [8] = "left", [12] = "right" }

local function getLocalState()
	if not inPlay() then
		return nil -- a menu, a battle, a warp: nothing meaningful to send
	end
	local base = OBJECT_STRUCTS
	local facing = u8(base + F_DIRECTION) or 0
	return {
		area_id = areaId(),
		position = { u8(base + F_MAP_X) or 0, u8(base + F_MAP_Y) or 0 },
		orientation = DIR_NAMES[facing] or "down",
		anim = ((u8(base + F_WALKING) or STANDING) ~= STANDING) and "walk" or "idle",
		-- `act` is OBJECT_ACTION, the byte the engine itself uses to decide which animation an
		-- object is playing -- fishing, bumping a wall, spinning on a spin tile, the "!" emote,
		-- the Fly landing. It is one byte for all of them because Crystal indexes a table with
		-- it (ObjectActionPairPointers), so a ghost that carries the peer's action byte gets the
		-- animation played by the game rather than imitated by us. phase9.md's enumeration.
		extras = { sprite = u8(base + F_SPRITE) or 0, act = u8(base + F_ACTION) or 0 },
	}
end

----------------------------------------------------------------------------
-- Ghosts: spawn, move, despawn. The Phase 9 recipe.
----------------------------------------------------------------------------

local ghosts = {} -- player_id -> { mo, st, mo_base, st_base, area }

-- Peers the engine had no room for. They are DRAWN instead of spawned (see the drawn tier below),
-- so every peer is visible even past the game's own limits -- the user's requirement, 2026-08-19.
local overflow = {} -- player_id -> { x, y, sprite }

-- Per-peer activity, for the collision policy: the frame each peer last CHANGED TILE, and the
-- frame until which it has been made passable by someone shoving into it.
local activity = {} -- player_id -> { x, y, movedAt, passableUntil }
local policyFrames = 0

function ghostCount()
	local n = 0
	for _ in pairs(ghosts) do
		n = n + 1
	end
	return n
end

-- Rate limit for the map-is-full line below; see spawnGhost.
local fullLoggedAt = nil

-- ALLOCATE FROM THE TOP DOWN, because the engine allocates from the bottom up.
--
-- Two reasons, and the second is a real bug the user found on 2026-08-19:
--   * Taking slots from the opposite end keeps ghosts and the game's own characters out of each
--     other's way as both pools fill.
--   * The Game Boy draws at most 10 sprites on a scanline and keeps the FIRST TEN IN OAM ORDER,
--     which follows struct order. Allocating low put ghosts ahead of the game's own cast in that
--     queue, so when a crowd shared a row the NPCs were the ones that lost halves of themselves --
--     watched on screen, and confirmed by a probe counting sprites per scanline. Allocating high
--     inverts it: when the hardware has to drop someone, it drops a GHOST. Emerald's adapter
--     already allocates from the top for the same reason.
local function freeMapObject()
	for i = NUM_MAP_OBJECTS - 1, 1, -1 do
		if u8(MAP_OBJECTS + i * MAPOBJECT_LENGTH + M_SPRITE) == 0 then
			return i
		end
	end
end

-- Structs the engine must always be able to get, no matter how many peers turn up.
--
-- THIS IS NOT TUNING, IT IS A BUG FIX. The engine hands a struct to each of its own characters as
-- they come into range and takes it back when they leave; a ghost carries FLAG1_WONT_DELETE, so
-- it holds one FOREVER, anywhere on the map. With a crowd of peers standing around, ghosts held
-- 11 of the 13 structs and the game had none left for itself -- measured 2026-08-19 with an NPC
-- standing ONE TILE from the player and simply not drawn, plus its own cast flickering in and out
-- as slots happened to free up. The user saw both before the probe did.
--
-- Ghosts are guests in this array. Three is enough for the NPCs that can be near the player at
-- once on the maps measured; the cost is a lower ghost ceiling (9 -> 6 in New Bark Town), which is
-- the right trade in a heartbeat: a peer who does not appear is a missing ghost, an NPC who does
-- not appear is the player's own game breaking.
local RESERVED_STRUCTS_FOR_THE_GAME = 3

-- The Game Boy draws at most 10 sprites on a scanline, and an overworld character is 4 of them
-- (2x2 of 8x8 tiles) -- so ten characters is the hardware's own ceiling and the eleventh loses
-- pieces of itself, whoever it is. Spawning past that does not add a peer, it adds FLICKER.
--
-- The user's call, 2026-08-19, asked directly: "cap it... i don't want things to pop in/out all
-- the time. i want every player/ghost to be visible all the time instead." So the adapter stops
-- at what the hardware can actually draw, and everything it does draw is solid. Peers past the
-- cap are cleanly absent -- the same honest absence as a peer past the slot limit -- until the
-- drawn-overflow tier exists to carry them (agent_docs/ideas.md).
local HARDWARE_CHARACTER_LIMIT = 10

-- How far a peer can be before its ghost gives its slots back. The visible window is 10x9 tiles,
-- so this keeps a ghost alive a little past the edge -- far enough that walking toward a peer
-- never shows a character appearing out of nothing, close enough that a peer across the map is
-- not holding a struct the game needs. See renderRemote for what this fixes.
local GHOST_RANGE_TILES = 8

-- COLLISION POLICY (user's design, 2026-08-19). A spawned ghost is a real object and blocks its
-- tile, which is right while a peer is playing and wrong the moment they wander off for coffee on
-- a doorstep. Rather than inventing a collision flag, a peer that should not be blocking is
-- rendered by the DRAWN tier instead -- a drawn ghost has no tile at all, so it cannot block
-- anything, and its engine slot goes to somebody who is actually moving.
--
-- Two rules decide it:
--   IDLE. A peer that has not CHANGED TILE for this long stops blocking. Turning on the spot does
--   not count as activity, deliberately -- the user's words: "include just facing directions as
--   nothing... have you actually move a tile or something to be considered active".
local IDLE_FRAMES_BEFORE_PASSABLE = 300 -- 5 seconds
--   BLOCKED. If the player is pressing INTO a ghost and not moving, that ghost stops blocking
--   almost immediately. This is what makes doorways and route exits work without the adapter
--   needing to know where they are: the map's warp table lives in ROM behind a bank pointer, and
--   a rule based on "someone is trying to get past you" covers every chokepoint, not just doors.
local PUSH_FRAMES_BEFORE_PASSABLE = 30 -- half a second of shoving
local PASSABLE_HOLD_FRAMES = 180 -- and it stays passable for a few seconds afterwards

local H_JOYPAD_DOWN = 0xFFA4 -- hJoypadDown, read from System Bus
local JOY_RIGHT, JOY_LEFT, JOY_UP, JOY_DOWN = 0x01, 0x02, 0x04, 0x08

-- Should this peer be solid right now? See the collision policy constants above.
--
-- Returns false when the peer is idle, or when the player is shoving into it -- and the caller
-- then renders it through the drawn tier, which has no collision at all.
-- Per-FRAME state for the policy, refreshed once by beginPolicyFrame() rather than re-read for
-- every peer. With a crowd this is the difference between a handful of memory reads a frame and
-- several hundred: measured 2026-08-19, the per-peer version cost ~9% of the frame rate on its
-- own (60fps -> 54.5) with a screen full of peers and nothing drawn at all.
local frameState = { px = 0, py = 0, standing = true, wantX = 0, wantY = 0 }

local function beginPolicyFrame()
	policyFrames = policyFrames + 1 -- ONCE per frame; incrementing per peer made "five seconds"
	                                -- mean five seconds divided by the number of peers.
	local px, py = u8(OBJECT_STRUCTS + F_MAP_X) or 0, u8(OBJECT_STRUCTS + F_MAP_Y) or 0
	frameState.px, frameState.py = px, py
	frameState.standing = (u8(OBJECT_STRUCTS + F_WALKING) or STANDING) == STANDING
	frameState.wantX, frameState.wantY = px, py
	if frameState.standing then
		local joy = memory.read_u8(H_JOYPAD_DOWN, "System Bus") or 0
		if (joy & JOY_RIGHT) ~= 0 then frameState.wantX = px + 1
		elseif (joy & JOY_LEFT) ~= 0 then frameState.wantX = px - 1
		elseif (joy & JOY_DOWN) ~= 0 then frameState.wantY = py + 1
		elseif (joy & JOY_UP) ~= 0 then frameState.wantY = py - 1 end
	end
end

-- OBJECT_ACTION values that mean "standing on this tile doing nothing in particular": the two
-- the engine gives an ordinary walking character, plus 0, which is the uninitialised entry.
-- Anything else is an animation in progress -- see ACTIONS.peer.
-- Both sets live on ONE table rather than two, because this file is close to Lua's 200-local
-- limit in its main chunk and every top-level name spends one of them. Hit for real 2026-08-21.
local ACTIONS = {}
ACTIONS.idle = { [0] = true, [1] = true, [2] = true }

local function shouldBlock(id, x, y, act)
	local a = activity[id]
	if not a then
		a = { x = x, y = y, movedAt = policyFrames, passableUntil = 0 }
		activity[id] = a
	end
	if a.x ~= x or a.y ~= y then
		a.x, a.y, a.movedAt = x, y, policyFrames
	end
	-- A peer who is FISHING has not changed tile for a while and is emphatically not idle. The
	-- five-second rule exists to give the engine back a slot nobody is using and to stop an
	-- unseen ghost being an invisible wall; a peer playing an animation is neither of those, and
	-- dropping them to the drawn tier would be the one place their animation is not rendered.
	if act ~= nil and not ACTIONS.idle[act] then
		a.movedAt = policyFrames
	end

	-- Is the player pressing INTO this peer's tile without getting anywhere? Facing alone is not
	-- enough: a player can stand facing a friend all day. The d-pad has to be held, and the
	-- player has to still be standing (a successful step means nothing was blocking).
	local fs = frameState
	if fs.standing and (fs.wantX ~= fs.px or fs.wantY ~= fs.py)
		and fs.wantX == x and fs.wantY == y then
		a.pushedFor = (a.pushedFor or 0) + 1
		if a.pushedFor >= PUSH_FRAMES_BEFORE_PASSABLE then
			a.passableUntil = policyFrames + PASSABLE_HOLD_FRAMES
		end
	else
		a.pushedFor = 0
	end

	if policyFrames < (a.passableUntil or 0) then
		return false
	end
	return (policyFrames - a.movedAt) < IDLE_FRAMES_BEFORE_PASSABLE
end

-- THE PRIORITY ORDER, in the user's words (2026-08-19): "npc's always shown, ghosts try to fill,
-- drawn otherwise". So the budget is computed from the game's needs first, not from what happens
-- to be free at this instant:
--
--   1. The game's own characters near the player are counted BEFORE any ghost is placed, and
--      their slots are simply not on offer. An NPC walking into view never has to compete with a
--      ghost for one, which is the failure the user watched: a crowd of peers left an NPC one
--      tile away undrawn.
--   2. Ghosts fill whatever the hardware can still draw.
--   3. Anything past that is the drawn-overflow tier's problem (plans.md, phase 9.1) -- absent
--      for now, and absent cleanly rather than flickering.
--
-- Counting near map objects rather than live structs is deliberate: a struct appears only once a
-- character is already in range, so budgeting from structs reserves the slot one moment too late.
local function gameCharactersNearby()
	local px, py = u8(OBJECT_STRUCTS + F_MAP_X) or 0, u8(OBJECT_STRUCTS + F_MAP_Y) or 0
	local ours = {}
	for _, g in pairs(ghosts) do
		ours[g.mo] = true
	end
	local n = 1 -- the player, who always has one
	for i = 1, NUM_MAP_OBJECTS - 1 do
		if not ours[i] then
			local base = MAP_OBJECTS + i * MAPOBJECT_LENGTH
			if (u8(base + M_SPRITE) or 0) ~= 0 then
				local mx, my = u8(base + M_X) or 0, u8(base + M_Y) or 0
				if math.max(math.abs(mx - px), math.abs(my - py)) <= GHOST_RANGE_TILES then
					n = n + 1
				end
			end
		end
	end
	return n
end

-- How many ghosts the hardware can still draw here, after the game's own cast is paid for.
local function ghostBudget()
	return HARDWARE_CHARACTER_LIMIT - gameCharactersNearby()
end


local function freeStruct()
	local free = {}
	for i = 1, NUM_OBJECT_STRUCTS - 1 do
		if u8(OBJECT_STRUCTS + i * OBJECT_LENGTH + F_SPRITE) == 0 then
			free[#free + 1] = i
		end
	end
	if #free <= RESERVED_STRUCTS_FOR_THE_GAME then
		return nil
	end
	-- Never take the game past what it can draw without flicker, and never spend a slot the
	-- game's own cast is going to need.
	if ghostCount() >= ghostBudget() then
		return nil
	end
	return free[#free] -- the highest free index; see freeMapObject for why
end

-- An object the engine is driving, to use as a behaviour template. Skips anything wearing the
-- player's sprite, which would be one of our own ghosts rather than a real NPC.
local function findTemplateNpc()
	local playerSprite = u8(OBJECT_STRUCTS + F_SPRITE)
	for i = 1, NUM_MAP_OBJECTS - 1 do
		local base = MAP_OBJECTS + i * MAPOBJECT_LENGTH
		local sprite = u8(base + M_SPRITE) or 0
		local id = u8(base + M_STRUCT_ID)
		if sprite ~= 0 and sprite ~= playerSprite and id and id ~= UNASSIGNED
			and id < NUM_OBJECT_STRUCTS then
			return i, id
		end
	end
end

-- Is sprite `id` loaded on THIS map right now, and at which VRAM tile?
--
-- A peer sends the sprite id they are wearing, but an id is not a picture: the tiles have to be
-- resident locally, and Crystal decides what is resident per map (the map's own objects indoors,
-- a fixed per-region list outdoors) plus the local player's own sprite. So the honest answer to
-- "show the peer as themselves" is: only when the game already has those tiles. This returns nil
-- otherwise, and the caller falls back to the local player's sprite -- today's behaviour, which
-- is at least always drawable. Loading a peer's tiles that are NOT resident is a separate and
-- much larger job (VRAM allocation), still open in phases/phase9.md.
local function residentSpriteTile(id)
	if not W_USEDSPRITES or not id or id == 0 then
		return nil
	end
	for i = 0, USED_SPRITES_CAPACITY - 1 do
		local entry = W_USEDSPRITES + i * 2
		local sprite = u8(entry)
		if not sprite or sprite == 0 then
			return nil -- the list is packed; a zero is the end of it
		end
		if sprite == id then
			return u8(entry + 1)
		end
	end
	return nil
end

-- Give a ghost the peer's own sprite when its tiles happen to be resident, otherwise leave it
-- wearing the local player's. Returns true when the peer's own was applied.
-- PROBE FLAG, off unless set. Substitutes one sprite id for every peer, so "does a ghost wear a
-- sprite the local player is not wearing" can be asked without a second machine and a peer of the
-- other gender. Pick an id the current map actually has loaded (an NPC standing on it) -- a
-- non-resident id changes nothing by design, which is the fallback working, not a failure.
local FORCE_PEER_SPRITE = tonumber(MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE
	or os.getenv("MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE") or "")
if FORCE_PEER_SPRITE then
	-- SAY SO, every startup, the way AP_TRY does. A global survives a dev-loader reload -- the
	-- loader swaps SCRIPTS, not the Lua state -- so one set for an experiment stays set for
	-- every later run in that emulator, silently. Live case 2026-08-19: a forced SPRITE_RIVAL
	-- left over from a probe made a ghost look like the player indoors and like an NPC outdoors,
	-- which is precisely the shape of a real bug (sprite 4 is resident outdoors and not in Elm's
	-- lab), and cost the user a report. A probe that changes what is on screen has to announce
	-- itself in the log the session is read from.
	log(string.format("PROBE FLAG IN USE: every peer is forced to sprite %d "
		.. "(MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE). Ghosts will NOT look like their peers.",
		FORCE_PEER_SPRITE))
end

if COMPARE_TIERS then
	log("PROBE FLAG IN USE: MESHGHOST_COMPARE_TIERS -- the loopback ghost is rendered TWICE, "
		.. "spawned 2 tiles right and painted 2 tiles left. Two ghosts is the flag, not a bug.")
end

local function applyPeerSprite(g, id)
	id = FORCE_PEER_SPRITE or id
	local tile = residentSpriteTile(id)
	if not tile then
		return false
	end
	if u8(g.st_base + F_SPRITE) == id and u8(g.st_base + F_SPRITE_TILE) == tile then
		return true -- already wearing it; writing every frame would fight nothing but cost reads
	end
	w8(g.st_base + F_SPRITE, id)
	w8(g.st_base + F_SPRITE_TILE, tile)
	w8(g.mo_base + M_SPRITE, id)
	g.sprite = id -- keep stillOurs()'s expectation in step with what the ghost now wears
	return true
end

-- Is the camera on a tile boundary?
--
-- screenCoords() below is only valid when it is, and that is measured, not assumed. Walking out
-- of Elm's lab put a fresh ghost a few pixels off its tile while walking IN was always fine
-- (user, 2026-08-19) -- because leaving a building drops the player into a scripted step out of
-- the doorway, so the ghost is spawned mid-scroll. A transition probe logged every object's
-- screen coordinate against what screenCoords() would compute for it, frame by frame across a
-- map load: the two agree exactly whenever both scroll offsets are multiples of 16, and disagree
-- by the sub-tile remainder whenever they are not -- the window origin advances a whole tile
-- while the pixel offset still carries the leftover, so the formula subtracts it twice.
--
-- The engine keeps every object's screen position itself once it exists; this only decides WHEN
-- it is safe to compute one from scratch. So a deferral costs a frame or two, never a wrong
-- placement that then persists for the life of the ghost.
local function cameraSettled()
	return (u8(W_BGMAPOFFSETX) or 0) % 16 == 0 and (u8(W_BGMAPOFFSETY) or 0) % 16 == 0
end

-- ---------------------------------------------------------------------------
-- The drawn tier: peers the engine has no room for
-- ---------------------------------------------------------------------------
--
-- Everything above this point asks the GAME to render a peer, which is the whole design of this
-- adapter. But the engine has 13 character slots and the Game Boy can draw 10 characters at once,
-- and a full room has more peers than that -- so past the cap a peer would simply not exist.
--
-- The user's call, 2026-08-19: "cap it, and just draw extras instead... i want every player/ghost
-- to be visible all the time instead." So peers past the cap are PAINTED over the emulator's
-- output, which is subject to none of the engine's limits because it happens after the PPU has
-- finished. Spawned ghosts stay the good tier; this is the overflow.
--
-- THIS IS A BANDAGE and is registered as one in BANDAGES.md: no engine animation, no collision,
-- no draw priority, and occlusion that we have to re-implement rather than get for free.
--
-- Pixels come from VRAM, not from ROM. A peer's sprite is already loaded (wUsedSprites says at
-- which tile), so the drawn tier reads the same tiles the engine is drawing the spawned ghosts
-- from -- 4 tiles of 2bpp, 16 bytes each, in a 2x2 block.
local DRAW_OVERFLOW = (MESHGHOST_CRYSTAL_DRAW_OVERFLOW or os.getenv("MESHGHOST_CRYSTAL_DRAW_OVERFLOW")) ~= "0"

-- THE GAME'S OWN COLOURS, not an approximation of them.
--
-- The first version hardcoded a white/red/black palette and the user's verdict was immediate:
-- "the crystal sprites look really pale, compared to the player". They were -- a drawn ghost
-- stood beside a spawned one wearing the real thing.
--
-- wOBPals1 (05:d040 -> flat 0x5040, WRAM bank 5 in this domain's flat layout) holds the eight
-- object palettes the game is actually using, four BGR555 colours each. Read them and a drawn
-- ghost is coloured by the same bytes the hardware is colouring the spawned ghosts with.
local W_OBPALS = 0x5040

local function paletteColors(palIndex)
	local base = W_OBPALS + (palIndex & 7) * 8
	local colors = { [0] = nil } -- colour 0 of an object palette is transparent
	for i = 1, 3 do
		local lo = u8(base + i * 2) or 0
		local hi = u8(base + i * 2 + 1) or 0
		local c = lo | (hi << 8)
		-- BGR555 -> 8 bits per channel. The <<3 | >>2 scaling keeps white at 0xFF rather than
		-- 0xF8, which is what makes a hand-rolled conversion look washed out.
		local r = ((c & 0x1F) << 3) | ((c & 0x1F) >> 2)
		local g = (((c >> 5) & 0x1F) << 3) | (((c >> 5) & 0x1F) >> 2)
		local b = (((c >> 10) & 0x1F) << 3) | (((c >> 10) & 0x1F) >> 2)
		colors[i] = 0xFF000000 | (r << 16) | (g << 8) | b
	end
	return colors
end

-- Decoded tiles are cached, and drawn as horizontal RUNS rather than pixels.
--
-- Both are about cost, and the cost is the whole feasibility question: filling a screen means
-- ~80 characters, and a character is 256 pixels, so the naive version is ~20,000 gui calls per
-- frame. Emerald has already shown this project what a few thousand per-frame calls do to an
-- emulator (60fps -> 3fps, 2026-08-19). A run of same-coloured pixels is one drawLine instead of
-- up to eight drawPixels, and a tile's decode is reused by every character wearing that sprite.
--
-- The cache is cleared on every map load, because VRAM is rebuilt then and a stale decode would
-- draw the previous map's graphics.
local VRAM_BANK1 = 0x2000
local tileCache = {}

-- SPRITE GRAPHICS STRAIGHT FROM THE CARTRIDGE, for a peer whose sprite this map never loaded.
--
-- The drawn tier reading VRAM can only show sprites the game already put there -- which is why a
-- peer of the other gender still looks like the local player: Crystal loads the map's own cast
-- plus YOUR sprite, and never theirs. Reading the tiles out of ROM removes that limit entirely,
-- and it is a thing only the drawn tier can do (a spawned ghost needs tiles the hardware can
-- reach, i.e. in VRAM).
--
-- The table is `OverworldSprites` at 05:4736, from our own hash-verified pokecrystal build, and
-- its shape is stated by the game's own struct (constants/sprite_data_constants.asm):
--   0-1 address, 2 size in BYTES (192 = 12 tiles), 3 bank, 4 type, 5 palette
-- six bytes per entry, indexed by SPRITE_* - 1 (the table's own comment: "entries correspond to
-- SPRITE_* constants", which start at 1).
-- Assigned from the selected address table, and NIL on any build where nobody has measured it.
local OVERWORLD_SPRITES_ROM
local SPRITEDATA_STRIDE = 6

local function romByte(offset)
	return memory.read_u8(offset, ROM_DOMAIN) or 0
end

-- Returns the ROM offset of a sprite's graphics, its size in bytes, and the palette the game
-- itself assigns it -- or nil for a sprite id the table does not cover.
local function spriteGfxInRom(spriteId)
	if not OVERWORLD_SPRITES_ROM or not spriteId or spriteId < 1 or spriteId > 255 then
		return nil
	end
	local entry = OVERWORLD_SPRITES_ROM + (spriteId - 1) * SPRITEDATA_STRIDE
	local addr = romByte(entry) | (romByte(entry + 1) << 8)
	local size, bank, palette = romByte(entry + 2), romByte(entry + 3), romByte(entry + 5)
	if size == 0 or bank == 0 or addr < 0x4000 then
		return nil -- not a banked graphics pointer; refuse rather than read somewhere plausible
	end
	return bank * 0x4000 + (addr - 0x4000), size, palette
end

-- key: a VRAM tile index, or "rom:<offset>" for cartridge graphics.
local function decodeTileAt(key, readByte, base)
	local cached = tileCache[key]
	if cached then
		return cached
	end
	-- VRAM BANK 1, not bank 0. The BizHawk domain lays both banks flat (16 KB), bank 1 starting at
	-- 0x2000, and the OAM attribute byte's bit 3 selects the bank -- a live dump of this game's own
	-- characters reads attr=8 and attr=0x28, so bit 3 is set and the graphics are in bank 1.
	-- Reading bank 0 decodes whatever unrelated tiles sit at the same index, which draws as
	-- garbage: found on screen 2026-08-19, the first thing the user said about the drawn tier.
	local rows = {}
	for row = 0, 7 do
		local lo = readByte(base + row * 2)
		local hi = readByte(base + row * 2 + 1)
		local runs, runStart, runIdx = {}, nil, nil
		for bit = 0, 8 do -- 8 is one past the end, to close the final run
			local idx = nil
			if bit < 8 then
				local mask = 1 << (7 - bit)
				idx = ((lo & mask) ~= 0 and 1 or 0) | (((hi & mask) ~= 0 and 1 or 0) << 1)
				if idx == 0 then idx = nil end -- colour 0 is transparent
			end
			if idx ~= runIdx then
				if runIdx then
					runs[#runs + 1] = { x = runStart, len = bit - runStart, idx = runIdx }
				end
				runStart, runIdx = bit, idx
			end
		end
		rows[row] = runs
	end
	tileCache[key] = rows
	return rows
end

local function readVram(a) return memory.read_u8(a, "VRAM") or 0 end

local function decodeTile(tileIndex)
	return decodeTileAt(tileIndex, readVram, VRAM_BANK1 + tileIndex * 16)
end

-- The same, for a tile inside a sprite's cartridge graphics.
local function decodeRomTile(gfxOffset, tileWithinSprite)
	local at = gfxOffset + tileWithinSprite * 16
	return decodeTileAt("rom:" .. at, romByte, at)
end

local function drawRows(rows, sx, sy, colors, xflip)
	for row = 0, 7 do
		local y = sy + row
		if y >= 0 and y < 144 then
			for _, run in ipairs(rows[row]) do
				local rx = xflip and (8 - run.x - run.len) or run.x
				local x1 = sx + rx
				local x2 = x1 + run.len - 1
				if x2 >= 0 and x1 < 160 then
					local color = colors[run.idx]
					if color then
						gui.drawLine(math.max(x1, 0), y, math.min(x2, 159), y, color)
					end
				end
			end
		end
	end
end

-- WHICH FOUR TILES, AND FLIPPED HOW -- learned from the engine, not guessed.
--
-- A walking sprite is 12 tiles (GetSpriteLength), and how those become a facing plus a walk
-- frame is the engine's business: it picks tile ids and per-sprite x-flips as it builds OAM. So
-- rather than reverse-engineer the layout, the drawn tier WATCHES the local player -- who is
-- always object struct 0 and always has the first four OAM entries -- and records what the engine
-- used for each facing. A drawn peer facing the same way then renders with exactly those tiles.
--
-- This is the same principle as calibrating the screen position against OAM: the engine is
-- already doing the work correctly every frame, so read its answer instead of recomputing it.
-- It also means the mapping is automatically right for whichever sprite the player is wearing.
-- facing (0..3) -> { stand = frame, walk = { frame, frame } }, where a frame is the four OAM
-- parts the engine used. Walk frames are collected while the player is mid-step, and the two
-- alternates are told apart by which tiles they use rather than by any assumption about the
-- sprite's layout.
local facingFrames = {}

local function readPlayerOamFrame()
	local frame = {}
	local playerTileBase = u8(OBJECT_STRUCTS + F_SPRITE_TILE) or 0
	local baseX, baseY = memory.read_u8(1, "OAM") or 0, memory.read_u8(0, "OAM") or 0
	for i = 0, 3 do
		local y = memory.read_u8(i * 4, "OAM") or 0
		if y == 0 or y >= 160 then
			return nil -- the player is not on screen this frame; learn nothing
		end
		frame[i + 1] = {
			-- an OFFSET within the sprite's own graphics, not an absolute VRAM tile: that is what
			-- lets the same learned arrangement be applied to a sprite read from the cartridge,
			-- which has its own tiles and no VRAM home at all.
			offset = ((memory.read_u8(i * 4 + 2, "OAM") or 0) - playerTileBase) & 0xFF,
			tile = memory.read_u8(i * 4 + 2, "OAM") or 0,
			xflip = ((memory.read_u8(i * 4 + 3, "OAM") or 0) & 0x20) ~= 0,
			dx = (memory.read_u8(i * 4 + 1, "OAM") or 0) - baseX,
			dy = y - baseY,
		}
	end
	return frame
end

local function sameFrame(a, b)
	if not a or not b then
		return false
	end
	for i = 1, 4 do
		if a[i].offset ~= b[i].offset or a[i].xflip ~= b[i].xflip then
			return false
		end
	end
	return true
end

local function learnFacingFromPlayer()
	local facing = ((u8(OBJECT_STRUCTS + F_DIRECTION) or 0) // 4) & 3
	local frame = readPlayerOamFrame()
	if not frame then
		return
	end
	local entry = facingFrames[facing]
	if not entry then
		entry = { walk = {} }
		facingFrames[facing] = entry
	end
	if (u8(OBJECT_STRUCTS + F_WALKING) or STANDING) == STANDING then
		entry.stand = frame
		return
	end
	-- Mid-step: this is a walk frame. Keep up to two distinct ones -- the engine alternates a
	-- left and a right stride -- identified by their tiles, so nothing here assumes how the
	-- sprite's 12 tiles are laid out.
	for _, known in ipairs(entry.walk) do
		if sameFrame(known, frame) then
			return
		end
	end
	if #entry.walk < 2 then
		entry.walk[#entry.walk + 1] = frame
	end
end

-- One drawn character: the 2x2 tile block starting at its sprite's tile base.
-- A drawn peer walks by alternating the two learned strides while it is moving, and stands
-- still otherwise. The engine drives a spawned ghost's animation for us; a drawn one has nobody
-- to drive it, so this is the one piece of animation the adapter genuinely has to do itself --
-- and it is registered as part of the drawn tier's cost in BANDAGES.md.
local WALK_FRAME_HOLD = 8 -- frames per stride, matching the engine's own cadence closely enough

-- source is { vram = <tile base> } for a sprite the map has loaded, or { rom = <gfx offset> } for
-- one read straight from the cartridge. Everything else is identical, which is the point: the
-- arrangement is learned once from the engine and applies to both.
local function drawCharacter(source, sx, sy, palIndex, facing, walkingFor)
	local colors = paletteColors(palIndex or 0)
	local entry = facing and facingFrames[facing]
	local frame = nil
	if entry then
		if walkingFor and #entry.walk > 0 then
			frame = entry.walk[((walkingFor // WALK_FRAME_HOLD) % #entry.walk) + 1]
		end
		frame = frame or entry.stand or entry.walk[1]
	end
	local function partRows(offset)
		if source.rom then
			return decodeRomTile(source.rom, offset)
		end
		return decodeTile((source.vram + offset) & 0xFF)
	end

	if frame then
		-- The engine's own arrangement for this facing: which tile of the sprite goes where, and
		-- which way round.
		for _, part in ipairs(frame) do
			drawRows(partRows(part.offset), sx + part.dx, sy + part.dy, colors, part.xflip)
		end
		return
	end
	-- Nothing learned for that facing yet (the player has not faced that way since the map
	-- loaded). The sprite's own first frame is a reasonable stand-in and is never wrong-looking,
	-- only wrong-facing.
	drawRows(partRows(0), sx, sy, colors)
	drawRows(partRows(1), sx + 8, sy, colors)
	drawRows(partRows(2), sx, sy + 8, colors)
	drawRows(partRows(3), sx + 8, sy + 8, colors)
end

-- ---------------------------------------------------------------------------
-- The HARDWARE tier: peers drawn by the Game Boy itself, not painted over it
-- ---------------------------------------------------------------------------
--
-- The middle rung of spawned -> hardware -> drawn, and the user's request, 2026-08-21. A peer here
-- is written straight into the game's sprite buffer, so the PPU draws it: the game's own live
-- palettes including day/night and fades, correct ordering against the game's own cast, and no
-- per-pixel Lua at all -- four bytes an entry instead of decoding and blitting tiles.
--
-- WHAT IT HONESTLY IS NOT, measured from the decomp before a line was written, because the case
-- for this tier was overstated when it was first proposed and the correction matters:
--
--   * IT ADDS ALMOST NO CAPACITY. It draws from the same 40 entries the engine already fills:
--     34-36 of 40 outdoors, 40 of 40 indoors (crowd-limits.md). That is zero to one extra
--     character, and in a clump the per-scanline limit bites first. The case for it is quality.
--   * IT DOES NOT GET OCCLUSION FREE. A Crystal text box is background tiles with the BG-to-OAM
--     priority bit CLEAR (TextboxPalette, home/text.asm:100), and the hardware window is parked
--     off-screen during normal play -- so a hardware sprite draws IN FRONT of a text box. This tier
--     therefore reuses the drawn tier's clipping rather than claiming to inherit any.
--   * IT INHERITS THE SPAWNED TIER'S RESIDENCY LIMIT. An OAM entry names a VRAM tile, so a peer
--     wearing a sprite this map never loaded cannot go here. Only the drawn tier reads the
--     cartridge, which is why it stays the bottom rung rather than this one.
--
-- HOW THE BUFFER WORKS (engine/overworld/map_objects.asm:2730, _UpdateSprites):
--   * `hUsedSpriteIndex` (00:ffbd) is a BYTE offset, reset to 0 every frame, and InitSprites
--     appends each visible character at 4 entries of 4 bytes;
--   * `.fill` then writes OAM_YCOORD_HIDDEN (160) into the Y byte of every remaining entry;
--   * the buffer reaches the hardware at VBlank.
-- So the free tail starts at `hUsedSpriteIndex` and our entries must be written AFTER the fill and
-- before the DMA. Whether the adapter's once-a-frame tick lands in that window is the one thing
-- that could not be settled from the source, so `verify()` below reads the hardware OAM back and
-- says plainly if nothing arrived, instead of drawing nothing and looking innocent.
local OAM_TIER = (MESHGHOST_CRYSTAL_OAM_OVERFLOW or os.getenv("MESHGHOST_CRYSTAL_OAM_OVERFLOW")) == "1"

local oam = {
	SHADOW = 0x400, -- wShadowOAM, 00:c400 -> flat
	ENTRIES = 40,
	next = nil, -- next entry index to write, counting DOWN from the top
	floor = 0, -- entries below this belong to the engine this frame
	placed = 0,
	landed = nil, -- has anything we wrote ever reached the hardware?
	checked = 0,
}

-- Once a frame, before any peer is placed: where does the engine's own use end, and are sprite
-- updates even running? `_UpdateSprites` returns immediately unless SPRITE_UPDATES_DISABLED_F is
-- SET (`ret z` on the bit test), and while it is not running the START menu has cleared the buffer
-- -- which is exactly when the game intends characters to be invisible, so we stay out.
function oam.beginFrame()
	oam.placed = 0
	oam.next = nil
	if not OAM_TIER then
		return
	end
	local flags = u8(W_STATEFLAGS)
	if not flags or (flags & 0x01) == 0 then
		return -- sprite updates disabled: the game is hiding everyone, and so do we
	end
	local used = memory.read_u8(0xFFBD, "System Bus")
	if type(used) ~= "number" then
		return
	end
	-- Allocate DOWNWARD from the last entry, so that when the hardware runs out of per-scanline
	-- sprites it drops a GHOST rather than one of the game's own characters. Same reasoning as the
	-- spawned tier's top-down struct allocation.
	oam.floor = used // 4
	oam.next = oam.ENTRIES - 1
end

-- One peer, four entries. Returns false when there is no room, so the caller falls through to the
-- drawn tier rather than the peer vanishing.
function oam.place(sx, sy, tileBase, palIndex, facing, walkingFor)
	if not oam.next or oam.next - 3 < oam.floor then
		return false
	end
	local entry = facing and facingFrames[facing]
	local frame = nil
	if entry then
		if walkingFor and #entry.walk > 0 then
			frame = entry.walk[((walkingFor // WALK_FRAME_HOLD) % #entry.walk) + 1]
		end
		frame = frame or entry.stand or entry.walk[1]
	end
	if not frame then
		return false -- nothing learned for this facing yet; the drawn tier has a fallback, we do not
	end

	for i, part in ipairs(frame) do
		local at = oam.SHADOW + (oam.next - (i - 1)) * 4
		-- OAM_Y_OFS / OAM_X_OFS are 16 and 8 (constants/hardware.inc:980) -- an OAM coordinate is
		-- the screen position plus those, which is how the hardware addresses off-screen edges.
		w8(at, (sy + part.dy + 16) & 0xFF)
		w8(at + 1, (sx + part.dx + 8) & 0xFF)
		w8(at + 2, (tileBase + part.offset) & 0xFF)
		-- Attributes: CGB palette in bits 0-2, VRAM bank in bit 3, X flip in bit 5. The priority
		-- bit is deliberately LEFT CLEAR: setting it would put the peer behind every non-zero
		-- background colour, i.e. behind the scenery it is standing on, which is worse than the
		-- text-box problem it would be trying to solve.
		w8(at + 3, (palIndex & 0x07) | 0x08 | (part.xflip and 0x20 or 0))
	end
	oam.next = oam.next - 4
	oam.placed = oam.placed + 1
	return true
end

-- Did any of it reach the hardware? Read from the OAM domain -- what the DMA actually delivered --
-- never from the shadow bytes we wrote, which would only prove that the write happened.
function oam.verify()
	if not OAM_TIER or oam.placed == 0 or oam.landed ~= nil then
		return
	end
	oam.checked = oam.checked + 1
	if oam.checked < 120 then
		return
	end
	-- Dump the whole entry, not just its Y. "Something arrived" and "something VISIBLE arrived" are
	-- different claims, and the gap between them is where a wrong tile id or a wrong attribute byte
	-- hides: the entry is present, on screen, and draws nothing anyone can see.
	local y = memory.read_u8((oam.ENTRIES - 1) * 4, "OAM")
	local parts = {}
	for i = 0, 3 do
		local at = (oam.ENTRIES - 1 - i) * 4
		parts[#parts + 1] = string.format("[%d] y=%s x=%s tile=%s attr=%s", oam.ENTRIES - 1 - i,
			tostring(memory.read_u8(at, "OAM")), tostring(memory.read_u8(at + 1, "OAM")),
			tostring(memory.read_u8(at + 2, "OAM")), tostring(memory.read_u8(at + 3, "OAM")))
	end
	log("MeshGhost: hardware tier, as the DMA delivered it -- " .. table.concat(parts, "  "))
	oam.landed = (type(y) == "number" and y ~= 160 and y ~= 0)
	if oam.landed then
		log("MeshGhost: the hardware tier is reaching the screen (entry 39 read back from OAM).")
	else
		log("MeshGhost: the hardware tier wrote entries but NOTHING reached the hardware -- the "
			.. "engine refills the buffer after we write, so these peers are invisible. Falling "
			.. "back to the drawn tier is the correct fix, not writing harder.")
	end
end

local function screenCoords(mx, my)
	local wx, wy = u8(W_XCOORD) or 0, u8(W_YCOORD) or 0
	local bx, by = u8(W_BGMAPOFFSETX) or 0, u8(W_BGMAPOFFSETY) or 0
	return (((mx - wx) & 0x0F) * 16 - bx) & 0xFF, (((my - wy) & 0x0F) * 16 - by) & 0xFF
end

-- Is the object we recorded still the object we made?
--
-- Everything the adapter writes goes through a slot number it wrote down earlier, and the game
-- rebuilds that array from ROM on every map load and every battle. So before writing, check the
-- three things we set ourselves are all still there: the cross-link both ways, and the sprite the
-- ghost was given. A rebuilt slot holding a real NPC fails this, and the entry is dropped instead
-- of being driven around or zeroed — the identity check phase9.md asks for, at the point where
-- being wrong costs someone else's NPC.
local function stillOurs(g)
	return g ~= nil
		and u8(g.mo_base + M_STRUCT_ID) == g.st
		and u8(g.st_base + F_MAP_OBJECT_INDEX) == g.mo
		and (g.sprite == nil or u8(g.st_base + F_SPRITE) == g.sprite)
end

local function despawnGhost(id)
	local g = ghosts[id]
	if not g then
		return
	end
	if not stillOurs(g) then
		-- Those bytes belong to the game again. Forget the entry; zeroing it would delete
		-- whatever the map load put there.
		ghosts[id] = nil
		log("MeshGhost: dropped stale bookkeeping for " .. id .. " (its slot is the game's again)")
		return
	end
	w8(g.st_base + F_SPRITE, 0)
	for off = 0, MAPOBJECT_LENGTH - 1 do
		w8(g.mo_base + off, 0)
	end
	ghosts[id] = nil
	log("MeshGhost: despawned " .. id)
end

-- Tell the engine what this object should do when it is not mid-step: stand, facing `dir`.
--
-- This is the fix for the snap the user reported on 2026-08-21 (*"a small snap once arriving at
-- the intended tile"*). spawnGhost copies a live NPC's whole template, movement byte included, and
-- when our step finishes the engine sets STEP_TYPE_FROM_MOVEMENT and dispatches on that byte. On a
-- template taken from a WANDERING NPC that means MovementFunction_RandomWalkXY, so for the frame
-- between our steps the ghost chose a direction of its own. posediff_probe.lua caught it exactly:
-- one frame per step where the facing jumped to an unrelated direction (9 -> 2 -> 8 while walking
-- left) and STEP_DURATION held values nothing in this adapter writes.
--
-- Both bytes are written because both are read: the object struct's is what
-- GetSpriteMovementFunction dispatches on, and the MAP OBJECT's is what RestoreDefaultMovement
-- re-reads at the end of every movement before GetInitialFacing turns the object to face it.
local function setGhostStanding(stBase, moBase, dir)
	local entry = SPRITEMOVEDATA_STANDING_BY_DIR[dir] or SPRITEMOVEDATA_STANDING_BY_DIR[0]
	w8(stBase + 0x03, entry) -- OBJECT_MOVEMENT_TYPE
	w8(moBase + 0x04, entry) -- MAPOBJECT_MOVEMENT
end

local function spawnGhost(id, x, y, peerSprite)
	-- Placing a ghost mid-scroll bakes in an offset that never corrects itself; a frame or two
	-- later the camera is on a tile boundary and the same arithmetic is exact.
	if not cameraSettled() then
		return nil
	end
	local srcMo, srcSt = findTemplateNpc()
	if not srcMo then
		return nil -- no template on this map; try again next frame
	end
	local mo, st = freeMapObject(), freeStruct()
	if not mo or not st then
		-- The map is FULL: this peer gets no body until one frees up. Say so, once a minute, and
		-- say which pool ran out -- because "my friend is invisible" and "my friend is not
		-- connected" look identical from the player's chair, and the answer differs per map.
		-- Crystal has 13 object structs and 16 map objects (pokecrystal's own
		-- NUM_OBJECT_STRUCTS / NUM_OBJECTS), and every map spends some of both on its own NPCs:
		-- New Bark Town leaves 9 for ghosts and runs out of STRUCTS first, Elm's lab also leaves
		-- 9 and runs out of MAP OBJECTS first. Measured 2026-08-19, agent_docs/crowd-limits.md.
		-- os.time(), not the frame counter: bridgeFrames is declared further down this file, so
		-- reading it here would resolve to a nil GLOBAL and throw at the exact moment a map
		-- fills up -- the forward-reference trap dev-scripts/lua-forward-refs.py exists for.
		local now = os.time()
		if not fullLoggedAt or (now - fullLoggedAt) >= 60 then
			fullLoggedAt = now
			log(string.format("MeshGhost: no room for %s on this map -- %s slots are all in use. "
				.. "Ghosts already here: %d. This is the game's own limit, not an error.",
				id, (not st) and "object struct" or "map object", ghostCount()))
		end
		return nil
	end

	local srcMoBase = MAP_OBJECTS + srcMo * MAPOBJECT_LENGTH
	local srcStBase = OBJECT_STRUCTS + srcSt * OBJECT_LENGTH
	local moBase = MAP_OBJECTS + mo * MAPOBJECT_LENGTH
	local stBase = OBJECT_STRUCTS + st * OBJECT_LENGTH

	for off = 0, MAPOBJECT_LENGTH - 1 do
		w8(moBase + off, u8(srcMoBase + off) or 0)
	end
	for off = 0, OBJECT_LENGTH - 1 do
		w8(stBase + off, u8(srcStBase + off) or 0)
	end

	w8(moBase + M_X, x)
	w8(moBase + M_Y, y)
	w8(moBase + M_STRUCT_ID, st)
	w8(stBase + F_MAP_OBJECT_INDEX, mo)
	for _, off in ipairs({ F_MAP_X, F_LAST_MAP_X, F_INIT_X }) do
		w8(stBase + off, x)
	end
	for _, off in ipairs({ F_MAP_Y, F_LAST_MAP_Y, F_INIT_Y }) do
		w8(stBase + off, y)
	end

	-- The player's sprite is resident on every map, so this needs no VRAM allocation and the
	-- correct gender comes along with it.
	w8(stBase + F_SPRITE, u8(OBJECT_STRUCTS + F_SPRITE) or 0)
	w8(stBase + F_SPRITE_TILE, u8(OBJECT_STRUCTS + F_SPRITE_TILE) or 0)
	w8(stBase + F_PALETTE, u8(OBJECT_STRUCTS + F_PALETTE) or 0)
	w8(moBase + M_SPRITE, u8(OBJECT_STRUCTS + F_SPRITE) or 0)

	local sx, sy = screenCoords(x, y)
	w8(stBase + F_SPRITE_X, sx)
	w8(stBase + F_SPRITE_Y, sy)

	w8(stBase + F_FLAGS1, (u8(stBase + F_FLAGS1) or 0) | FLAG1_WONT_DELETE)

	-- NORMALISE THE MOVEMENT TYPE, and this is not tidiness -- it is the fix for the snap the user
	-- reported on 2026-08-21: *"it still snaps towards the end of the movement, when the ghost is
	-- close to done arriving onto the next tile"*.
	--
	-- The whole template is copied from a live NPC, movement type included. When our step finishes,
	-- the engine sets STEP_TYPE_FROM_MOVEMENT and dispatches on that byte
	-- (GetSpriteMovementFunction -> SpriteMovementData). Template an NPC that WANDERS and the byte
	-- says SPRITEMOVEDATA_WANDER, so for the one frame between our steps the engine runs
	-- MovementFunction_RandomWalkXY and the ghost picks a direction of its own.
	--
	-- Measured, not reasoned: posediff_probe.lua caught exactly one frame per step where the
	-- ghost's FACING jumped to an unrelated direction (9 -> 2 -> 8 while walking left) and its
	-- STEP_DURATION held a value nothing in this adapter writes. One frame of the wrong facing at
	-- the end of every step is precisely "a small snap on arrival".
	--
	-- The SPRITEMOVEDATA_STANDING_* entries all use SPRITEMOVEFN_STANDING, which does nothing but
	-- end the movement and stand. Which of the four is chosen decides the facing the engine
	-- restores at the end of each step, so stepGhost() re-pins it per direction; the spawn just
	-- needs a benign starting value.
	setGhostStanding(stBase, moBase, ((u8(stBase + F_DIRECTION) or 0) // 4) & 3)

	ghosts[id] = { mo = mo, st = st, mo_base = moBase, st_base = stBase, area = areaId(),
		sprite = u8(stBase + F_SPRITE) }

	-- ...unless the peer's own sprite is already loaded on this map, in which case they get to
	-- look like themselves rather than like whoever is sitting at this machine.
	local own = applyPeerSprite(ghosts[id], peerSprite)

	log(string.format("MeshGhost: spawned %s at %d,%d (map object %d <-> struct %d)%s", id, x, y,
		mo, st, own and " wearing its own sprite" or ""))
	return ghosts[id]
end

-- Paint every peer the engine had no room for. Called once per frame; BizHawk clears its own
-- drawing layer each frame, so this redraws rather than accumulating.
--
-- Occlusion, which a drawn character does not get for free: skip anything inside the game's UI.
-- Crystal's text box is a compile-time constant -- the bottom six rows, full width
-- (TEXTBOX_Y = SCREEN_HEIGHT - TEXTBOX_HEIGHT, from the decomp) -- and its menus publish their
-- own rectangle in wMenuBorder*, which strobes back to zero as the menu redraws, so the last
-- non-zero one is latched. Measured 2026-08-19; see verified.md.
-- wMenuBorderTop/Left/Bottom/Right, 00:cf82-cf85, tile coordinates. Menus fill these in; text
-- boxes do not (measured 2026-08-19 -- a text box left them at zero), which is why the two panels
-- are handled separately below.
local W_MENUBOX_TOP, W_MENUBOX_LEFT, W_MENUBOX_BOTTOM, W_MENUBOX_RIGHT = 0x0F82, 0x0F83, 0x0F84, 0x0F85

-- Is a UI panel on screen at all? Both a menu and a text box drive the Game Boy's window layer
-- (WY leaves its parked 144), and both strobe it, so this latches for a moment rather than
-- trusting a single frame. A HEURISTIC, and labelled as one: it decides only whether a DRAWN
-- ghost is painted, never anything about game state, and the spawned tier -- which is most
-- ghosts -- is occluded by the game itself and needs none of this.
local UI_LATCH_FRAMES = 20
local uiSeenAt, drawFrames = nil, 0
local heldCal = {} -- last settled-frame calibration; see the calX note in drawOverflow

-- WY IS NOT THE SIGNAL, and using it cost half the screen.
--
-- First version latched on the Game Boy's window register leaving its parked 144, on the theory
-- that any UI panel drives it. It does -- but so does normal play: this game toggles WY several
-- times a second with nothing open, so the latch was permanently on and every drawn ghost below
-- row 12 was hidden. The user's report was exact: "all of the bottom half is empty".
--
-- What IS reliable is the menu rectangle the game publishes (wMenuBorder*, measured 2026-08-19),
-- so that is the only thing consulted. Text boxes do not publish one and are not clipped yet --
-- a drawn ghost can currently paint over a text box, which is an honest known gap rather than a
-- heuristic that hides things it should not. The spawned tier, which is most ghosts, is occluded
-- by the game itself either way.
local function uiPanelOpen()
	return uiSeenAt ~= nil and (drawFrames - uiSeenAt) < UI_LATCH_FRAMES
end

-- IS A TEXT BOX OPEN? Read the background tilemap and look for the box's own corner.
--
-- The decomp settles this: LoadFrame copies the six frame tiles ('┌' to '┘') to `vTiles2 tile
-- '┌'`, which its own comment gives as $79 -- so a text box's top-left corner is tile 121 and the
-- edge beside it is 122, whichever of the nine frame STYLES the player has chosen (the style
-- changes the graphics copied into those ids, not the ids). Measured live the same day: with a
-- box open the tilemap read 121,122 at row 12, and 30,31 (map terrain) with it closed.
--
-- Row 12 because the box is a constant: TEXTBOX_Y = SCREEN_HEIGHT - TEXTBOX_HEIGHT = 18 - 6.
local BGMAP_LO, BGMAP_HI = 0x1800, 0x1C00 -- 0x9800 / 0x9C00, selected by LCDC bit 3
local TEXTBOX_ROW = 12
local TILE_FRAME_CORNER, TILE_FRAME_EDGE = 121, 122

local function textBoxOpen()
	local lcdc = memory.read_u8(0xFF40, "System Bus") or 0
	local map = ((lcdc & 0x08) ~= 0) and BGMAP_HI or BGMAP_LO
	local row = map + TEXTBOX_ROW * 32
	-- Three cells, not one. Terrain shares this index space, so a single tile matching 121 could
	-- be a hillside; a corner AND its edge AND the far end of the same row being frame tiles is
	-- the box. Cheap, and it cannot be imitated by one unlucky tile.
	local left = memory.read_u8(row, "VRAM") or 0
	local next1 = memory.read_u8(row + 1, "VRAM") or 0
	local right = memory.read_u8(row + 19, "VRAM") or 0
	return left == TILE_FRAME_CORNER and next1 == TILE_FRAME_EDGE
		and right >= TILE_FRAME_CORNER and right <= TILE_FRAME_CORNER + 5
end

-- DIAGNOSTIC, off unless MESHGHOST_CRYSTAL_UI_DEBUG is set. Answers the only question that
-- matters when the user says "a ghost is drawn over a menu" and the counters say peers are being
-- hidden: WHICH peers were painted, WHERE they sat, and what rectangle the adapter thought it was
-- protecting. A count of 21 hidden is compatible with 20 more painted straight over the panel --
-- that is exactly the gap this dump closes, and it is why the count was never enough on its own.
-- An env var cannot be changed without relaunching the emulator, and this has to be switchable
-- during a live session someone is watching -- so a global works too, set by a dev-loader script
-- before or after this file loads. Read once per frame, never per peer.
local UI_DEBUG_ENV = (os.getenv("MESHGHOST_CRYSTAL_UI_DEBUG") or "") ~= ""

local lastMenuBox = nil
-- Which object struct the drawn tier is measuring from; held across frames on purpose (see
-- drawOverflow), and cleared when the world is rebuilt.
local anchorIndex = nil

function drawOverflow()
	drawFrames = drawFrames + 1
	-- COMPARE_TIERS keeps this running even with the tier switched off: the comparison ghost is
	-- the only thing `overflow` holds in that configuration, and looking at it is the point.
	if (not DRAW_OVERFLOW and not COMPARE_TIERS) or not inPlay() then
		return
	end
	learnFacingFromPlayer()
	local uiOpen = uiPanelOpen()
	local boxOpen = textBoxOpen()
	local t, l, b, r = u8(W_MENUBOX_TOP), u8(W_MENUBOX_LEFT), u8(W_MENUBOX_BOTTOM), u8(W_MENUBOX_RIGHT)
	if (b or 0) > 0 and (r or 0) > 0 then
		lastMenuBox = { top = t * 8, left = l * 8, bottom = (b + 1) * 8, right = (r + 1) * 8 }
		uiSeenAt = drawFrames -- the rectangle strobes to zero as the menu redraws; latch it
	elseif not uiOpen then
		lastMenuBox = nil -- no panel is up, so the last rectangle is stale
	end

	local nWanted, nDrawn, nNoTile, nOffScreen, nHidden, nFromRom = 0, 0, 0, 0, 0, 0
	local nOam = 0
	oam.beginFrame()
	-- Animation and facing are the two things a drawn peer has to do for itself, and a
	-- screenshot cannot settle either: one frame cannot see a walk cycle, and a peer that is
	-- merely facing the wrong way still looks like a character. So they are counted instead --
	-- how many drawn peers were rendered on a WALK frame this frame, and how many had a facing
	-- at all. `nNoFacing` is the one that matters: it counts peers rendered from the sprite's
	-- raw first frame because nothing has been learned for that facing yet, which is the state
	-- that looks exactly like broken animation.
	local nWalking, nNoFacing = 0, 0
	local UI_DEBUG = UI_DEBUG_ENV or _G.MESHGHOST_CRYSTAL_UI_DEBUG == true
	local paintedSamples = {}
	local offSample = nil

	-- IS THE OVERWORLD ON SCREEN AT ALL? If it is not, paint nothing.
	--
	-- A POSITIVE test, deliberately, rather than a deny-list. Two user reports on 2026-08-19 --
	-- ghosts over a full-screen MENU, ghosts inside a BATTLE -- are one defect: the drawn tier
	-- paints after the frame with none of the engine's context, so everything not explicitly
	-- excluded gets painted over. A list of screens to avoid (battle, menu, evolution, naming,
	-- Pokedex, cutscene, title) will never be finished, and every entry missing from it is a bug
	-- someone has to see first. Asking instead "is the overworld what is on screen" is one
	-- question with one answer.
	--
	-- A FULL-SCREEN menu (POKeMON, BAG, the PokeGear) publishes no wMenuBorder* rectangle, so
	-- there is nothing to clip against -- and it happens to trip textBoxOpen(), so the adapter
	-- protected only the bottom six rows and painted ghosts over the whole top two-thirds of the
	-- menu. Reported by the user 2026-08-19: "the ghost is being drawn while in the menu's",
	-- against counters that said peers were being hidden. Both were true; see pitfalls.md.
	--
	-- The test is the engine's own output rather than another guess at game state, and it follows
	-- from what this tier IS: the drawn tier paints ALONGSIDE the characters the engine renders.
	-- If the engine is rendering no characters at all, there is nothing to paint alongside, the
	-- anchor this code calibrates against does not exist either, and the honest answer is to draw
	-- nothing. Measured 2026-08-19 across a full sweep: overworld 28-34 live sprite entries, the
	-- START menu 28-30 (map still behind it, ghosts correctly clipped by its rectangle), a text
	-- box 30+ (map still there) -- and a full-screen submenu exactly 0.
	--
	-- Deliberately NOT a state flag: wStateFlags bit 0 was tried first and strobes between 01,
	-- 40 and 41 within a single state, the same way the WY-alone heuristic did.
	local liveSprites, playerSpriteEntries = 0, 0
	for i = 0, 39 do
		local y = memory.read_u8(i * 4, "OAM") or 0
		if y > 0 and y < 160 then
			liveSprites = liveSprites + 1
			if i < 4 then
				playerSpriteEntries = playerSpriteEntries + 1
			end
		end
	end
	-- The second term is the stronger one, and it is not a new assumption: this tier ALREADY
	-- treats OAM entries 0-3 as the local player's four sprites -- that is what the anchor
	-- calibration below measures its screen positions against. So "is the engine drawing this
	-- player's character right now" is answerable from the same four bytes, and if it is not, the
	-- calibration has nothing valid to work from either. It catches what a state flag misses: the
	-- ENCOUNTER TRANSITION, where the overworld is already gone but wBattleMode is still 0 (the
	-- Archipelago agent measured wMapStatus never leaving 2 through an entire battle on that
	-- build, so wBattleMode is the only battle term there and this is its gap).
	if liveSprites == 0 or playerSpriteEntries == 0 then
		return
	end

	-- ANCHOR ON A CHARACTER THAT IS STANDING STILL, and measure everything else from it in TILES.
	--
	-- No scroll arithmetic at all: a reference object's OAM entry is its true position in screen
	-- pixels, and a peer N tiles away is N*16 pixels away. That is exact whatever the camera is
	-- doing, which is the point -- the previous version worked in the engine's own scrolled space
	-- and was only correct at the instants the engine recomputes it. In between, the hardware
	-- scrolls and the drawn peers did not follow: measured as 64 discontinuities of 8 and 16 px
	-- in a 20-second walk, and reported by the user as ghosts snapping around while moving.
	--
	-- STANDING is what makes a reference usable. A character mid-step has already had its MAP_X/Y
	-- written to the tile it is walking TO (that is how this engine initiates a step), while its
	-- sprite is still up to a whole tile behind -- so anchoring on a walking character, the player
	-- included, is wrong by exactly the 16 px seen above.
	-- STICK TO ONE ANCHOR. Choosing the first standing character each frame looks harmless and is
	-- not: characters differ by a few pixels in how their sprite sits relative to their tile (an
	-- idle animation, a different sprite shape), so switching anchor moves every drawn peer by
	-- that difference. Measured: the first version cut the jumps from 64 to 39 and the survivors
	-- were all exactly +/-8 px horizontally -- the adapter alternating between two anchors.
	--
	-- So: keep last frame's anchor while it is still standing and still on this map; only choose
	-- again when it is not, and prefer the player, whose sprite-to-tile relationship is the one
	-- everything else is calibrated against anyway.
	local function usable(i)
		local base = OBJECT_STRUCTS + i * OBJECT_LENGTH
		return (u8(base + F_SPRITE) or 0) ~= 0
			and (u8(base + F_WALKING) or STANDING) == STANDING
	end

	if not (anchorIndex and usable(anchorIndex)) then
		anchorIndex = nil
		if usable(0) then
			anchorIndex = 0
		else
			for i = 1, NUM_OBJECT_STRUCTS - 1 do
				if usable(i) then
					anchorIndex = i
					break
				end
			end
		end
	end

	local anchorTileX, anchorTileY, anchorPx, anchorPy = nil, nil, nil, nil
	if anchorIndex then
		local base = OBJECT_STRUCTS + anchorIndex * OBJECT_LENGTH
		anchorTileX, anchorTileY = u8(base + F_MAP_X), u8(base + F_MAP_Y)
		anchorPx, anchorPy = u8(base + F_SPRITE_X) or 0, u8(base + F_SPRITE_Y) or 0
	end
	-- The engine's sprite space and the screen differ by a constant this frame; the player's own
	-- OAM entry gives it, and it is valid whether or not the PLAYER is the anchor.
	-- THE CORNER, not entry 0. A character occupies four OAM entries in a 2x2, and which one the
	-- engine writes first is not stable -- it swaps with facing, because a flipped sprite is
	-- emitted in the mirrored order. Reading entry 0 therefore gives an x that alternates by 8 px
	-- as the player turns, and every drawn peer inherited that: measured as 37 jumps of exactly
	-- +/-8 px in a 20-second walk, which survived two other fixes because neither was the cause.
	-- The minimum across the four is the character's top-left corner, which does not care about
	-- ordering or flips.
	local playerOamX, playerOamY = 255, 255
	for i = 0, 3 do
		local y = memory.read_u8(i * 4, "OAM") or 255
		local x = memory.read_u8(i * 4 + 1, "OAM") or 255
		if y < playerOamY then playerOamY = y end
		if x < playerOamX then playerOamX = x end
	end
	-- CALIBRATE ONLY WHILE THE PLAYER IS STANDING. The two sides of this subtraction live one
	-- frame apart: OAM holds what the engine BUILT last frame, the struct holds where the object is
	-- THIS frame -- so mid-walk they disagree by exactly the per-frame step delta and the
	-- calibration oscillates by +/-2px, which the user saw as ghosts "randomly wiggling"
	-- (2026-08-21). It is the same phase defect pitfalls.md records as "a script's writes land
	-- between frames; the game's land inside one", on the read side. While the player stands, both
	-- sources describe the same frame and agree; that value is held through the walk.
	local calX, calY
	if (u8(OBJECT_STRUCTS + F_WALKING) or STANDING) == STANDING then
		calX = (playerOamX - 8) - (u8(OBJECT_STRUCTS + F_SPRITE_X) or 0)
		calY = (playerOamY - 16) - (u8(OBJECT_STRUCTS + F_SPRITE_Y) or 0)
		heldCal.x, heldCal.y = calX, calY
	else
		calX = heldCal.x or 0
		calY = heldCal.y or 0
	end
	if anchorTileX then
		-- Anchor available: screen position of its tile, then tile deltas from there.
		anchorPx = anchorPx + calX
		anchorPy = anchorPy + calY
	end
	-- With the tier switched off but COMPARE_TIERS on, the comparison ghost is the only thing that
	-- may be painted -- `overflow` still fills with real peers the engine had no room for, and
	-- painting those would be the tier running under a flag that says it is off.
	local paintable = overflow
	if not DRAW_OVERFLOW then
		paintable = {}
		for pid, po in pairs(overflow) do if po.compare then paintable[pid] = po end end
	end
	for id, o in pairs(paintable) do
		nWanted = nWanted + 1
		-- Is this peer moving? Its own position changes are the only signal a drawn ghost has --
		-- nothing in the engine is animating it. A peer that has changed tile within the last
		-- half second is treated as walking, which is roughly how long a step takes.
		if o.lastX ~= o.x or o.lastY ~= o.y then
			o.lastX, o.lastY, o.movedAt = o.x, o.y, drawFrames
		end
		local walkingFor = (o.movedAt and (drawFrames - o.movedAt) < 30) and (drawFrames - o.movedAt) or nil
		-- Resident tiles first -- they are what the engine is drawing everyone else from, so a
		-- drawn peer beside a spawned one matches exactly. Failing that, read the peer's sprite
		-- out of the cartridge, which is how a peer wearing a sprite THIS map never loaded (the
		-- other gender, most obviously) gets to look like themselves.
		local source, palette = nil, u8(OBJECT_STRUCTS + F_PALETTE) or 0
		local tile = residentSpriteTile(o.sprite)
		if tile then
			source = { vram = tile }
		else
			local gfx, _, pal = spriteGfxInRom(o.sprite)
			if gfx then
				source, palette = { rom = gfx }, pal
				nFromRom = nFromRom + 1
			else
				local own = residentSpriteTile(u8(OBJECT_STRUCTS + F_SPRITE))
				source = own and { vram = own } or nil
			end
		end
		if not source then nNoTile = nNoTile + 1 end
		if source then
			-- SIGNED screen coordinates, computed here rather than borrowed from screenCoords().
			-- That helper answers in the engine's sprite space, which is taken mod 256 and offset
			-- by 16 -- fine for the engine, wrong here: a peer above or left of the camera wraps
			-- to ~240 and reads as "off screen". Live case 2026-08-19: 40 of 83 waiting peers
			-- discarded that way, which the user saw as half a screen never filling.
			-- The engine's own formula, then the wrap undone. Crystal addresses its tilemap
			-- MODULO 16 tiles and subtracts a pixel scroll of up to 255, so a character left of
			-- or above the camera comes out near 256 rather than negative. Taking that back to a
			-- signed value is what puts the left column and the top rows on screen; without it
			-- they read as "off screen" and simply never draw.
			-- The engine's OWN formula, which a probe confirmed matches every real object's
			-- sprite position exactly at rest (off=0,0 for all 13, 2026-08-19) -- then its
			-- wrapped 0-255 answer converted back to a screen position. A character left of or
			-- above the camera comes back near 256, not negative, and reading that as "off
			-- screen" is what left rows and columns empty. Y is +16 in this space (the player at
			-- tile row 8 with the window at row 4 reads 80, not 64).
			local sx, sy
			if anchorTileX then
				-- Tile deltas from a standing character: no scroll arithmetic, so nothing to be
				-- out of date. Signed on purpose -- a peer left of or above the anchor is a
				-- negative delta, not a wrapped one.
				sx = anchorPx + (o.x - anchorTileX) * 16
				sy = anchorPy + (o.y - anchorTileY) * 16
			else
				-- Nobody is standing still this frame (an empty map while the player walks).
				-- Fall back to the engine-space computation, which is right at rest and drifts by
				-- at most a tile mid-step -- better than not drawing at all.
				sx, sy = screenCoords(o.x, o.y)
				sx = sx + calX
				sy = sy + calY
			end
			-- EVERY position in this pipeline is arithmetic on BYTES -- sprite coordinates,
			-- map coordinates, the window origin -- so the true screen position only exists
			-- modulo 256, and both branches can hand back an alias: the user's drawn copy sat
			-- at "screen -224,-196", which is 32,60 seen through exactly this (2026-08-21). It
			-- was then discarded as off screen, which is why the drawn ghost did not move and
			-- why a peer released from the spawned tier while idle VANISHED instead of being
			-- painted. One normalisation for both branches: fold into [-16, 240), the window
			-- where a 16px character can touch the 160x144 screen. This is the mod-window done
			-- properly, not a compensating offset -- a genuinely off-screen character still
			-- lands outside the on-screen test below and is still discarded.
			sx = ((sx % 256) + 272) % 256 - 16
			sy = ((sy % 256) + 272) % 256 - 16
			local onScreen = sx > -16 and sx < 160 and sy > -16 and sy < 144
			if not onScreen then
				nOffScreen = nOffScreen + 1
				if COMPARE_TIERS and drawFrames % 60 == 0 then
					logFile(string.format("  copy %-28s OFF SCREEN at screen %d,%d (map %d,%d)",
						id, sx, sy, o.x, o.y))
				end
				if not offSample then
					offSample = string.format("%s at map %d,%d -> screen %d,%d (window %d,%d)",
						id, o.x, o.y, sx, sy, u8(W_XCOORD) or 0, u8(W_YCOORD) or 0)
				end
			end
			if onScreen then
				local hidden = false
				-- The text box occupies the bottom six rows at full width, always.
				if boxOpen and sy + 16 > TEXTBOX_ROW * 8 then
					hidden = true
				end
				if uiOpen and lastMenuBox and sx + 16 > lastMenuBox.left and sx < lastMenuBox.right
					and sy + 16 > lastMenuBox.top and sy < lastMenuBox.bottom then
					hidden = true
				end
				if hidden then
					nHidden = nHidden + 1
				else
					if walkingFor then nWalking = nWalking + 1 end
					if o.facing == nil then nNoFacing = nNoFacing + 1 end
					if UI_DEBUG and (boxOpen or uiOpen) and #paintedSamples < 8 then
						paintedSamples[#paintedSamples + 1] =
							string.format("%s@%d,%d", id, sx, sy)
					end
					-- THE MIDDLE RUNG FIRST. A peer whose tiles are resident in VRAM can be handed
					-- to the hardware, which draws it with the game's own live palettes and orders
					-- it against the game's own cast. It declines when the buffer has no room or
					-- nothing has been learned for this facing, and then the peer is painted
					-- exactly as before -- a peer never disappears because a tier said no.
					-- COMPARE_TIERS only: say where every copy went and where it thinks it is. Three
					-- renderers disagreeing is exactly the case a count cannot describe -- "2 off
					-- screen" does not say WHICH, at what coordinate, or which rung claimed it.
					if COMPARE_TIERS and drawFrames % 60 == 0 then
						logFile(string.format("  copy %-28s only=%-6s map %d,%d screen %d,%d "
							.. "facing=%s vram=%s",
							id, tostring(o.only), o.x, o.y, sx, sy, tostring(o.facing),
							tostring(source.vram)))
					end

					local onHardware = false
					if source.vram and o.only ~= "drawn" then
						onHardware = oam.place(sx, sy, source.vram, palette, o.facing, walkingFor)
					end
					if onHardware then
						nOam = nOam + 1
					elseif o.only == "hw" then
						nOam = nOam -- pinned to a rung that had no room: show nothing rather than
						-- quietly painting it, which would make the comparison a lie
					else
						nDrawn = nDrawn + 1
						-- the palette the local player's own sprite is drawn with, which is the one
						-- these tiles were coloured for
						drawCharacter(source, sx, sy, palette, o.facing, walkingFor)
					end
				end
			end
		end
	end

	if UI_DEBUG and (boxOpen or uiOpen) and drawFrames % 15 == 0 then
		local mb = lastMenuBox
		logFile(string.format("UI DEBUG: boxOpen=%s uiOpen=%s rect=%s wy=%d wx=%d "
			.. "-- %d painted, %d hidden; painted at: %s",
			tostring(boxOpen), tostring(uiOpen),
			mb and string.format("l=%d t=%d r=%d b=%d", mb.left, mb.top, mb.right, mb.bottom)
				or "none",
			memory.read_u8(0xFF4A, "System Bus") or 0, memory.read_u8(0xFF4B, "System Bus") or 0,
			nDrawn, nHidden,
			(#paintedSamples > 0) and table.concat(paintedSamples, " ") or "(none)"))
	end

	-- Once a second, say what the drawn tier actually did. "Half the screen is empty" needs a
	-- number that separates "the peers never arrived" from "they arrived and were not drawn".
	oam.verify()

	if drawFrames % 60 == 0 and nWanted > 0 then
		logFile(string.format("tiers: %d on hardware. "
			.. "drawn tier: %d peers waiting, %d drawn (%d from the cartridge), "
			.. "%d no sprite tiles, %d off screen, %d hidden by UI, %d spawned as real objects; "
			.. "%d on a walk frame, %d with no facing yet",
			nOam, nWanted, nDrawn, nFromRom, nNoTile, nOffScreen, nHidden, ghostCount(),
			nWalking, nNoFacing))
		if offSample then
			logFile("drawn tier: example of one it discarded -- " .. offSample)
		end
	end
end

-- The inverse of DIR_NAMES: a peer sends orientation as a name, and we need the numeric dir.
local ORIENTATION_TO_DIR = { down = 0, up = 1, left = 2, right = 3 }

local DELTA_TO_DIR = { ["0,1"] = 0, ["0,-1"] = 1, ["-1,0"] = 2, ["1,0"] = 3 }

-- The OBJECT_ACTION values a PLAYER's object can legitimately hold. The engine's own table
-- (ObjectActionPairPointers, engine/overworld/map_object_action.asm) has 17 entries, but most of
-- them are scenery -- the Copycat dolls, the Sudowoodo tree, boulder dust, shaking grass, a
-- shadow -- which the player object is never set to. A peer offering one of those is either a
-- different build or a client we should not trust, so it is ignored rather than written: inbound
-- state is peer-controlled and this one ends in a memory write.
-- The OBJECT_ACTION values a PLAYER's object can legitimately hold.
ACTIONS.peer = {
	[1] = true, -- OBJECT_ACTION_STAND
	[2] = true, -- OBJECT_ACTION_STEP
	[3] = true, -- OBJECT_ACTION_BUMP          (walking into a wall)
	[4] = true, -- OBJECT_ACTION_SPIN          (spin tiles)
	[5] = true, -- OBJECT_ACTION_SPIN_FLICKER  (the teleport/dig spin)
	[6] = true, -- OBJECT_ACTION_FISHING
	[8] = true, -- OBJECT_ACTION_EMOTE         (the "!" over the head)
	[16] = true, -- OBJECT_ACTION_SKYFALL      (the Fly landing)
}

-- Give the ghost the peer's action byte and let Crystal animate it.
--
-- This is the whole of the spawned tier's animation work, and the reason it is one line rather
-- than one branch per animation: HandleObjectAction runs for every object on every frame and
-- DERIVES OBJECT_FACING from OBJECT_ACTION (map_objects.asm calls it with
-- ObjectActionPairPointers). So the action byte selects the animation, and writing FACING
-- ourselves would be inert -- the engine overwrites it before anything is drawn.
--
-- Safe to leave written: once a ghost is idle its step function is STEP_TYPE_STANDING, which
-- touches OBJECT_WALKING and nothing else. ACTION is only reset when the object re-enters its
-- movement function (MovementFunction_Standing sets OBJECT_ACTION_STAND), which happens at the
-- END of a step -- so an action written while idle persists, and a step overwrites it with
-- OBJECT_ACTION_STEP, which is correct.
local function applyPeerAction(g, act)
	if act == nil or not ACTIONS.peer[act] then
		return
	end
	if u8(g.st_base + F_ACTION) ~= act then
		w8(g.st_base + F_ACTION, act)
	end
end

local function stepGhost(g, dir)
	local sdx = (dir == 3) and 2 or (dir == 2) and -2 or 0
	local sdy = (dir == 0) and 2 or (dir == 1) and -2 or 0
	local x = (u8(g.st_base + F_MAP_X) or 0) + ((dir == 3) and 1 or (dir == 2) and -1 or 0)
	local y = (u8(g.st_base + F_MAP_Y) or 0) + ((dir == 0) and 1 or (dir == 1) and -1 or 0)

	-- Re-pinned per step: this decides the facing the engine restores when the step ENDS, so it has
	-- to follow the direction being walked rather than stay at whatever the spawn chose.
	setGhostStanding(g.st_base, g.mo_base, dir)

	w8(g.st_base + F_WALKING, 4 + dir)
	w8(g.st_base + F_DIRECTION, dir * 4)
	w8(g.st_base + F_FACING, dir * 4)
	w8(g.st_base + F_STEP_TYPE, 2)
	w8(g.st_base + F_STEP_DURATION, 7)
	w8(g.st_base + F_ACTION, 2)
	w8(g.st_base + F_MAP_X, x)
	w8(g.st_base + F_MAP_Y, y)
	-- The engine applies its own first 2px in the frame it initiates a step; ours starts a frame
	-- later, so without this every step lands 2px short and the error accumulates.
	w8(g.st_base + F_SPRITE_X, ((u8(g.st_base + F_SPRITE_X) or 0) + sdx) & 0xFF)
	w8(g.st_base + F_SPRITE_Y, ((u8(g.st_base + F_SPRITE_Y) or 0) + sdy) & 0xFF)

	-- READ BACK the one field whose absence makes the engine run away.
	--
	-- OBJECT_WALKING's low nibble indexes StepVectors, which has 12 entries. STANDING is 255, so a
	-- nibble of 15 -- and if the step type still says "walk", the engine reads a step vector from
	-- whatever follows that table and applies it every frame until the duration runs out. That is
	-- the "went all the way up/down and off the screen" the user reported on 2026-08-21, and
	-- orphan_probe.lua caught the struct in exactly that state: WALKING=255 alongside the step type
	-- and duration this function had just written.
	--
	-- So this asks the game what it actually holds rather than trusting the write above, and only
	-- says anything when the two disagree -- silent in a healthy session.
	local back = u8(g.st_base + F_WALKING)
	if back ~= 4 + dir then
		log(string.format("MeshGhost: WROTE WALKING=%d TO STRUCT %d AND IT READS BACK %s "
			.. "(step_type=%s duration=%s). The engine walks on the step type, so this is the "
			.. "state that sends a ghost off the screen.",
			4 + dir, g.st, tostring(back), tostring(u8(g.st_base + F_STEP_TYPE)),
			tostring(u8(g.st_base + F_STEP_DURATION))))
	end
end

-- How often a ghost had to be snapped rather than walked. Counted because a teleport is the ONLY
-- thing in this adapter that can move a ghost discontinuously, so "does it feel like it snaps?"
-- and "is this being called?" are the same question -- and the answer decides whether the fix is
-- about drift or about something else entirely. Reported once a second and only when it is not
-- zero, so a healthy session stays silent.
local snaps = { n = 0, at = 0, runaways = 0 }

local function teleportGhost(g, x, y)
	-- Same reason as the spawn: this writes screen coordinates too.
	if not cameraSettled() then
		return
	end
	snaps.n = snaps.n + 1
	w8(g.st_base + F_WALKING, STANDING)
	w8(g.st_base + F_STEP_DURATION, 0)
	for _, off in ipairs({ F_MAP_X, F_LAST_MAP_X, F_INIT_X }) do
		w8(g.st_base + off, x)
	end
	for _, off in ipairs({ F_MAP_Y, F_LAST_MAP_Y, F_INIT_Y }) do
		w8(g.st_base + off, y)
	end
	w8(g.mo_base + M_X, x)
	w8(g.mo_base + M_Y, y)
	local sx, sy = screenCoords(x, y)
	w8(g.st_base + F_SPRITE_X, sx)
	w8(g.st_base + F_SPRITE_Y, sy)
end

-- Inbound state is peer-controlled: bound every number before it reaches a memory write.
local function renderRemote(id, state)
	if not inPlay() or type(state) ~= "table" then
		return
	end
	local pos = state.position
	if type(pos) ~= "table" or type(pos[1]) ~= "number" or type(pos[2]) ~= "number" then
		return
	end
	-- When did we last hear from this peer? Kept on the activity record, which already exists per
	-- peer, so this costs no new bookkeeping. tick() uses it to forget peers that stop sending --
	-- see the sweep there for why a peer can vanish without ever being despawned.
	local a = activity[id]
	if not a then
		a = { x = -1, y = -1, movedAt = policyFrames, passableUntil = 0 }
		activity[id] = a
	end
	a.seenAt = policyFrames

	local isLoopback = id:match("%-ghost$") ~= nil
	local baseX = math.floor(pos[1])
	local offsetX = LOOPBACK_OFFSET_X
	if COMPARE_TIERS and isLoopback and offsetX == 0 then offsetX = COMPARE.spawned end
	local x, y = baseX + offsetX, math.floor(pos[2])
	if x < 0 or x > 255 or y < 0 or y > 255 then
		return
	end

	-- A peer in a different area has no meaningful position here -- in EITHER tier. Clearing only
	-- the spawned one left the drawn tier painting peers from the map you just walked out of.
	if state.area_id ~= areaId() then
		despawnGhost(id)
		overflow[id] = nil
		overflow[COMPARE.key(id)] = nil
		overflow[COMPARE.hwKey(id)] = nil
		return
	end

	-- A ghost that is nowhere near the player gives its slots back, because the engine's own
	-- characters do. This is not an optimisation, it is the fix for two symptoms the user saw
	-- within a minute of each other on 2026-08-19:
	--   * NPCs popping in and out. Crystal hands a struct to each of its characters as they come
	--     into range and takes it back when they leave. A ghost carries FLAG1_WONT_DELETE, so it
	--     held one FOREVER -- and a crowd of peers held nearly all 13, leaving the game none for
	--     its own cast. Measured: an NPC standing ONE TILE from the player, simply not drawn.
	--   * Invisible collisions. A ghost off the screen still occupied its tile, so the player
	--     walked into a solid character they could not see. An NPC that far away is not there.
	-- Beyond the visible window (10x9 tiles), so a ghost exists slightly before it can be seen and
	-- nothing pops in at the screen edge.
	local px, py = u8(OBJECT_STRUCTS + F_MAP_X) or 0, u8(OBJECT_STRUCTS + F_MAP_Y) or 0
	if math.max(math.abs(x - px), math.abs(y - py)) > GHOST_RANGE_TILES then
		despawnGhost(id)
		overflow[COMPARE.key(id)] = nil
		overflow[COMPARE.hwKey(id)] = nil
		return
	end

	-- MESHGHOST_COMPARE_TIERS: the same peer, painted on the other side of the player, so the two
	-- renderers can be judged against each other in one frame. Written every frame like any drawn
	-- peer, and carrying its own movement history so it animates rather than sliding.
	if COMPARE_TIERS and isLoopback then
		local ck = COMPARE.key(id)
		local prev = overflow[ck]
		-- Each copy is PINNED to one renderer, or the comparison quietly collapses: with the
		-- hardware tier on, every resident peer is claimed by it first and nothing is ever painted,
		-- so the drawn copy would silently become a second hardware copy. `only` says which rung a
		-- copy belongs to and the draw loop honours it.
		-- Only when the hardware tier is actually ON. Pinned to a rung that is switched off, this
		-- copy renders nothing and still counts as a peer waiting -- a phantom in every tier total.
		local hk = COMPARE.hwKey(id)
		local hprev = overflow[hk]
		overflow[hk] = OAM_TIER and { compare = true, only = "hw", x = baseX + COMPARE.hw, y = y,
			sprite = FORCE_PEER_SPRITE or (state.extras and tonumber(state.extras.sprite)) or nil,
			facing = ORIENTATION_TO_DIR[state.orientation],
			lastX = hprev and hprev.lastX, lastY = hprev and hprev.lastY,
			movedAt = hprev and hprev.movedAt } or nil

		overflow[ck] = { compare = true, only = "drawn", x = baseX + COMPARE.drawn, y = y,
			sprite = FORCE_PEER_SPRITE or (state.extras and tonumber(state.extras.sprite)) or nil,
			facing = ORIENTATION_TO_DIR[state.orientation],
			lastX = prev and prev.lastX, lastY = prev and prev.lastY, movedAt = prev and prev.movedAt }
	end

	-- FORCE_PEER_SPRITE substitutes here rather than only inside applyPeerSprite, so the probe
	-- flag reaches BOTH tiers. It claimed to substitute "every peer" and did not touch the drawn
	-- one, which made a test of the cartridge path silently measure nothing (2026-08-19).
	local peerSprite = FORCE_PEER_SPRITE or (state.extras and tonumber(state.extras.sprite)) or nil

	-- What the peer's own object is DOING, in the engine's own terms. Floored before it can reach
	-- a write, and checked against ACTIONS.peer there; a peer on an older build sends no `act` at
	-- all, which reads as nil and leaves the ghost animating exactly as it did before.
	local peerActRaw = state.extras and tonumber(state.extras.act) or nil
	local peerAct = peerActRaw and math.floor(peerActRaw) or nil

	-- A peer that should not be blocking is DRAWN rather than spawned: no tile, no collision,
	-- and its engine slot freed for a peer who is actually moving.
	-- The OTHER reason to draw a peer rather than spawn one, added 2026-08-21: a spawned ghost can
	-- only wear a sprite whose tiles this map has already loaded, and the sprites that say "I am
	-- on a bike" or "I am surfing" (wPlayerState -> SPRITE_*_BIKE / SPRITE_SURF, documentation.md)
	-- are loaded only when the LOCAL player is doing the same thing. So a surfing peer used to be
	-- spawned wearing this machine's walking sprite -- a character standing on the sea.
	--
	-- The drawn tier reads the cartridge, so it can wear anything (phase9.md, step 30). Sending a
	-- peer there costs engine-driven animation and collision; keeping them spawned costs showing
	-- the wrong character entirely. The look is what the peer is telling us about, so the look wins
	-- -- the same "collision is a rendering decision" call as the idle rule below.
	--
	-- `not W_USEDSPRITES` is "this build has not been measured here" (Archipelago's table), not
	-- "nothing is resident". Without the list there is no residency question to ask, so the peer
	-- is spawned exactly as before rather than every peer on that build being quietly demoted.
	--
	-- AND the clause that matters most, missing in the first version and caught the same day by
	-- the adapter's own drawn-tier line reading "0 spawned as real objects, 1 drawn": a peer whose
	-- sprite is the one THIS MACHINE's player is wearing is always wearable, whether or not it
	-- appears in wUsedSprites. That list is what the map loaded; the local player's own sprite is
	-- resident by construction and is also the fallback a ghost gets anyway, so "not in the list"
	-- says nothing about whether the ghost can look right. Without this every peer of the same
	-- gender and state -- which is every peer in a loopback session, and most peers in a real one
	-- -- was demoted to the drawn tier, quietly turning the good tier off.
	local localSprite = u8(OBJECT_STRUCTS + F_SPRITE)
	local wearable = peerSprite == nil or not W_USEDSPRITES
		or peerSprite == localSprite
		or residentSpriteTile(peerSprite) ~= nil

	-- Called unconditionally, even when `wearable` has already decided the answer: it is what keeps
	-- each peer's movement bookkeeping current, so a peer who dismounts is not immediately judged
	-- idle on the strength of a timestamp that stopped being updated while they were on the bike.
	local blocking = shouldBlock(id, x, y, peerAct)

	if not wearable or not blocking then
		if ghosts[id] then
			-- NAME THE TRANSITION. The user saw the same peer rendered twice for a few frames while
			-- walking (2026-08-21): a peer flapping between the spawned and painted tiers passes
			-- through frames where the engine object is still on screen and the painted copy is
			-- already drawn on the same tile. Which side flips it, and why, is the whole question --
			-- a count cannot answer it, a transition line can. Throttled by nature: it only fires on
			-- an actual tier change.
			logFile(string.format("tier: %s spawned -> painted (%s)", id,
				(not wearable) and "sprite not resident here" or "idle/shoved: not blocking"))
			despawnGhost(id)
		end
		local prev = overflow[id]
		overflow[id] = { x = x, y = y, sprite = peerSprite,
			facing = ORIENTATION_TO_DIR[state.orientation],
			lastX = prev and prev.lastX, lastY = prev and prev.lastY, movedAt = prev and prev.movedAt }
		return
	end

	local g = ghosts[id]
	if not g then
		-- Try the good tier first, every frame: a slot may have freed up since last time.
		if spawnGhost(id, x, y, peerSprite) then
			if overflow[id] then
				logFile(string.format("tier: %s painted -> spawned", id))
			end
			overflow[id] = nil
		else
			local prev = overflow[id]
			overflow[id] = { x = x, y = y, sprite = peerSprite,
				facing = ORIENTATION_TO_DIR[state.orientation],
				lastX = prev and prev.lastX, lastY = prev and prev.lastY,
				movedAt = prev and prev.movedAt }
		end
		return
	end
	overflow[id] = nil
	if g and not stillOurs(g) then
		-- A map load or a battle rebuilt the array under us. Drop the entry and spawn again
		-- below; the alternative is writing steps into whatever the game put in that slot.
		log("MeshGhost: " .. id .. "'s slot is the game's again — respawning")
		ghosts[id], g = nil, nil
	end
	-- A peer's sprite is not fixed for the session: it changes with their state (on a bike, and
	-- with the gender the sprite tables are keyed on), and what is RESIDENT changes under us on
	-- every map load. So this is re-checked here rather than only at spawn.
	applyPeerSprite(g, peerSprite)

	-- AN IMPOSSIBLE STATE, AND THE ONE THAT SENDS A GHOST OFF THE SCREEN.
	--
	-- OBJECT_WALKING saying STANDING while OBJECT_STEP_TYPE still says "walk" is not a state the
	-- engine produces for its own objects: the step functions always set the two together. But
	-- orphan_probe.lua caught our ghost holding exactly it on 2026-08-21 -- and it is ruinous,
	-- because StepVectors has 12 entries and GetStepVector indexes it with WALKING's low nibble.
	-- STANDING is 255, so the nibble is 15, and the engine reads a step vector out of whatever
	-- follows that table and applies it every frame until the duration runs out. What the user saw:
	-- *"it gets dragged off screen"*.
	--
	-- The cause is not yet pinned -- stepGhost's own write reads back correct every time, so the
	-- state arrives BETWEEN our steps -- so this repairs rather than explains, and says so. The
	-- repair is the engine's own "the movement ended" path (STEP_TYPE_FROM_MOVEMENT), which lands
	-- the object in MovementFunction_Standing and then STEP_TYPE_RESTORE, exactly as a step that
	-- finished normally would. Registered in BANDAGES.md as a compensation with an unknown cause.
	local walking = u8(g.st_base + F_WALKING) or STANDING
	local stepType = u8(g.st_base + F_STEP_TYPE) or 0
	if walking == STANDING and (stepType == 2 or stepType == 7) then
		w8(g.st_base + F_STEP_TYPE, 1) -- STEP_TYPE_FROM_MOVEMENT
		w8(g.st_base + F_STEP_DURATION, 0)
		snaps.runaways = (snaps.runaways or 0) + 1
	end

	-- Only act while the ghost is idle; interrupting a step is what makes a character teleport
	-- while animating.
	if walking ~= STANDING then
		return
	end

	local cx, cy = u8(g.st_base + F_MAP_X) or 0, u8(g.st_base + F_MAP_Y) or 0
	if cx == x and cy == y then
		-- Not moving, but the peer may have TURNED IN PLACE — a real and common action in this
		-- game, and one the ghost missed entirely until 2026-08-18 because renderRemote only ever
		-- looked at position. Facing then came from whichever way the ghost last walked.
		--
		-- DIRECTION and FACING both take dir*4. FACING's low bits are the walk-cycle subframe the
		-- engine advances during a step, so writing the base value while idle is safe; doing it
		-- mid-step would fight the animation, which is why this sits behind the idle check.
		local want = ORIENTATION_TO_DIR[state.orientation]
		if want and u8(g.st_base + F_DIRECTION) ~= want * 4 then
			w8(g.st_base + F_DIRECTION, want * 4)
			w8(g.st_base + F_FACING, want * 4)
			-- A turn has to survive the engine's own restore, which re-reads the movement byte and
			-- turns the object to face whatever it names -- so the byte moves with the turn.
			setGhostStanding(g.st_base, g.mo_base, want)
		end
		-- Standing still is not the same as doing nothing: fishing, bumping a wall, spinning on a
		-- spin tile, the "!" emote and the Fly landing all happen without the peer changing tile,
		-- and until 2026-08-21 a ghost showed none of them. The direction is set first because
		-- the action handlers that need one (fishing) read it via GetSpriteDirection.
		applyPeerAction(g, peerAct)
		return
	end
	local dx, dy = x - cx, y - cy
	local dir = DELTA_TO_DIR[string.format("%d,%d", dx, dy)]
	if dir then
		stepGhost(g, dir) -- one tile: walk it, so the game animates the step
	elseif math.abs(dx) + math.abs(dy) <= 3 then
		-- A SHORT deficit is walked, not snapped. The old rule teleported for anything past one
		-- tile, and a ghost falls two tiles behind in perfectly ordinary play -- a missed idle
		-- window, a 3-frame loopback lag, one skipped step. Worse, teleportGhost waits for a
		-- settled camera, so during continuous walking the ghost FROZE until the player paused and
		-- then visibly jumped (the user's "teleporting around a bit", 2026-08-21). One real step
		-- per idle window toward the target catches up at double the peer's pace (the ghost walks
		-- every window, the peer only every other), stays animated the whole way, and never snaps.
		-- The larger axis first, so a diagonal deficit walks an L rather than dithering.
		local stepDir
		if math.abs(dx) >= math.abs(dy) then
			stepDir = (dx > 0) and 3 or 2
		else
			stepDir = (dy > 0) and 0 or 1
		end
		stepGhost(g, stepDir)
	else
		teleportGhost(g, x, y) -- genuinely far (a warp, a long silence): snap, don't fake a walk
	end
end

----------------------------------------------------------------------------
-- Bridge
----------------------------------------------------------------------------

local sock, connected, ready = nil, false, false
local rxBuffer = ""
local sinceRetry = 0

local function disconnect(why)
	if sock then
		pcall(function()
			sock:close()
		end)
	end
	sock, connected, ready, rxBuffer = nil, false, false, ""
	for id in pairs(ghosts) do
		despawnGhost(id)
	end
	overflow = {} -- drawn peers leave with the connection, the same as spawned ones
	if why then
		log("MeshGhost: bridge lost (" .. why .. ")")
	end
end

local function send(obj)
	if not sock then
		return
	end
	local line = jsonEncode(obj) .. "\n"
	local ok, err = sock:send(line)
	if not ok and err ~= "timeout" then
		disconnect(tostring(err))
	end
end

-- Ports that answered but would not have us, with the frame their cooldown ends.
local busyUntil = {}
local currentPort = nil
local helloSentAtFrame = nil
local bridgeFrames = 0
-- Set when a core reports the relay is unreachable; until then, do not walk ports or spawn cores.
local relayDownUntil = 0

local function markPortBusy(port, why)
	if port then
		busyUntil[port] = bridgeFrames + BUSY_PORT_COOLDOWN_FRAMES
		log(string.format("MeshGhost: port %d %s — skipping it for %ds.",
			port, why, BUSY_PORT_COOLDOWN_FRAMES // 60))
	end
end

local function tryPort(port)
	local s = socketCore.tcp()
	if not s then
		return false
	end
	s:settimeout(0.05)
	local ok = s:connect(BRIDGE_HOST, port)
	if not ok then
		pcall(function()
			s:close()
		end)
		return false
	end
	s:settimeout(0)
	sock, connected, ready, rxBuffer = s, true, false, ""
	currentPort, helloSentAtFrame = port, bridgeFrames
	-- Log the port, always. With a walk, "connected" no longer implies a known port, and the port
	-- is the first thing anyone needs when two instances start behaving as one.
	log(string.format("MeshGhost: bridge connected on %s:%d", BRIDGE_HOST, port))
	send({ type = "hello", payload = { game_id = GAME_ID, game_version = GAME_VERSION } })
	return true
end

-- One sweep across the whole range per cooldown, NOT one port per cooldown: each candidate costs
-- at most the 50ms connect timeout against a closed port (usually far less, since a refused
-- connection is immediate on loopback), whereas one port per 2s would take 16 seconds to find a
-- free core eight ports up.
-- The first port in the range with NOTHING listening, as seen by the last sweep -- where
-- autostart puts a new core. Taken from the sweep rather than assuming BRIDGE_BASE_PORT: with two
-- copies of the game running, the base port is the FIRST copy's core, and spawning there produces
-- a core that cannot bind and exits instantly, leaving the second emulator with none. Found live
-- on Emerald, 2026-08-18. A port that answered and then rejected us is somebody else's core, not
-- a free one, and is skipped by busyUntil rather than recorded here.
local firstFreePort = nil

local function connect()
	if BRIDGE_PORT_OVERRIDE then
		firstFreePort = BRIDGE_PORT_OVERRIDE
		tryPort(BRIDGE_PORT_OVERRIDE)
		return
	end
	firstFreePort = nil
	for i = 0, BRIDGE_PORT_COUNT - 1 do
		local port = BRIDGE_BASE_PORT + i
		if (busyUntil[port] or 0) <= bridgeFrames then
			if tryPort(port) then
				return
			end
			if not firstFreePort then
				firstFreePort = port
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Autostart: start a core ourselves, and let it die with the emulator.
--
-- os.execute and io.popen cannot do this without a visible console: both run `cmd /c ...`, so the
-- window belongs to the shell doing the launching and hiding the child cannot help (all five
-- shell variants were watched flashing, 2026-08-18). luanet -- NLua's .NET bridge, which BizHawk
-- exposes -- builds System.Diagnostics.Process directly with UseShellExecute=false and
-- CreateNoWindow=true, and that is genuinely invisible (confirmed against a window-showing
-- control). GetCurrentProcess().Id is EmuHawk's pid, so -exit-with-pid gives auto-close for free.
-- See agent_docs/environment.md and dev-scripts/bizhawk-spawn-probe.lua.
local coreChild, coreSpawnFrame, coreSpawnFailed = nil, nil, false
local AUTOSTART = os.getenv("MESHGHOST_NO_AUTOSTART") == nil

-- meshghost.exe is not shipped inside game folders (9 MB, once per game), so look where it
-- actually lives: the release root is three levels up from games/pokemon/crystal, a source
-- checkout four up. Beside the script wins if someone deliberately put one there.
local function findCoreExe()
	local candidates = {
		SCRIPT_DIR .. "/meshghost.exe",
		SCRIPT_DIR .. "/../../../meshghost.exe",
		SCRIPT_DIR .. "/../../../../meshghost.exe",
	}
	for _, path in ipairs(candidates) do
		local f = io.open(path, "rb")
		if f then
			f:close()
			return path
		end
	end
	return nil
end

local function coreStillRunning()
	if not coreChild then
		return false
	end
	local ok, exited = pcall(function() return coreChild.HasExited end)
	if not ok then
		return false
	end
	return not exited
end

local function startCore(port)
	if not AUTOSTART or coreSpawnFailed or coreStillRunning() then
		return
	end
	-- Every port in the range is somebody else's core; spawning would just fail to bind.
	if not port then
		return
	end
	-- A core takes a moment to bind. Spawning again before then is how you get a pile of
	-- processes fighting over one port.
	if coreSpawnFrame and (bridgeFrames - coreSpawnFrame) < 300 then
		return
	end

	local exe = findCoreExe()
	if not exe then
		coreSpawnFailed = true
		log("MeshGhost: meshghost.exe not found near this script -- not starting a core. "
			.. "Start it yourself, or put a copy beside this file.")
		return
	end

	coreSpawnFrame = bridgeFrames
	local ok, err = pcall(function()
		luanet.load_assembly("System") -- without this, import_type returns nil
		local Process = luanet.import_type("System.Diagnostics.Process")
		local StartInfo = luanet.import_type("System.Diagnostics.ProcessStartInfo")
		local si = StartInfo()
		si.FileName = exe
		-- No relay settings: the core reads config.json from its own directory, which is the file
		-- a player edits. Passing -relay here would silently override it.
		si.Arguments = string.format("-exit-with-pid=%d -bridge=%s:%d",
			Process.GetCurrentProcess().Id, BRIDGE_HOST, port)
		si.UseShellExecute = false
		si.CreateNoWindow = true
		coreChild = Process.Start(si)
	end)
	if not ok then
		coreSpawnFailed = true
		log("MeshGhost: could not start a core: " .. tostring(err))
		return
	end
	log(string.format("MeshGhost: started a core (no window) on bridge port %d; "
		.. "it will exit with the emulator.", port))
end

local function handle(msg)
	if type(msg) ~= "table" then
		return
	end
	local t, p = msg.type, msg.payload or {}
	if t == "bridge_ready" then
		ready = true
		log("MeshGhost: bridge_ready — this core is ours")
	elseif t == "reject" then
		local reason = tostring(p.reason)
		log("MeshGhost: rejected (" .. reason .. ")")
		-- ONE rejection means something different from the others, and treating them alike costs
		-- the player their frame rate. "busy" means this core has an adapter, so the answer is to
		-- try the next port. **"cannot reach the relay" means this core is perfectly good and the
		-- RELAY is unavailable** -- walking on finds nothing, every port gets marked busy, and the
		-- adapter then starts spawning fresh cores at the retry cadence. Emerald was measured at
		-- 5fps doing exactly that while a relay was full (2026-08-19). Wait for the same core
		-- instead: it retries the relay by itself, and reconnects when the relay comes back.
		if reason:find("relay", 1, true) then
			relayDownUntil = bridgeFrames + RELAY_DOWN_BACKOFF_FRAMES
			disconnect(nil)
			return
		end
		markPortBusy(currentPort, "is a core that already has an adapter")
		disconnect(nil)
	elseif t == "render_remote" then
		renderRemote(tostring(p.player_id), p.state)
	elseif t == "despawn_remote" then
		-- BOTH tiers, and the activity record with them. despawnGhost only knows about spawned
		-- ghosts, so before this the drawn tier kept painting a peer who had left -- forever, and
		-- invisibly to every count except the one that says how many peers are waiting. Found by
		-- killing 20 of 89 synthetic peers and watching the number not move (2026-08-19).
		local gone = tostring(p.player_id)
		despawnGhost(gone)
		overflow[gone] = nil
		overflow[COMPARE.key(gone)] = nil
		overflow[COMPARE.hwKey(gone)] = nil
		activity[gone] = nil
	end
end

local function receive()
	if not sock then
		return
	end
	local chunk, err, partial = sock:receive(4096)
	local data = chunk or partial
	if data and #data > 0 then
		rxBuffer = rxBuffer .. data
	elseif err and err ~= "timeout" then
		disconnect(tostring(err))
		return
	end
	while true do
		local nl = rxBuffer:find("\n", 1, true)
		if not nl then
			break
		end
		local line = rxBuffer:sub(1, nl - 1)
		rxBuffer = rxBuffer:sub(nl + 1)
		if #line > 0 then
			handle(jsonDecode(line))
		end
	end
end

----------------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------------

local romClass, romWhy, romTable = classifyRom()
log("=== MeshGhost — Pokémon Crystal ===")

-- Select the address set BEFORE anything reads or writes memory. An unknown ROM still gets
-- vanilla's, which is the deliberate run-anyway case; an Archipelago ROM gets its own or none.
local A = ADDRESSES[romTable or "vanilla"]
OBJECT_STRUCTS, MAP_OBJECTS = A.OBJECT_STRUCTS, A.MAP_OBJECTS
W_MAPGROUP, W_MAPNUMBER = A.W_MAPGROUP, A.W_MAPNUMBER
W_YCOORD, W_XCOORD = A.W_YCOORD, A.W_XCOORD
W_MAPSTATUS, W_BATTLEMODE = A.W_MAPSTATUS, A.W_BATTLEMODE
W_BGMAPOFFSETX, W_BGMAPOFFSETY = A.W_BGMAPOFFSETX, A.W_BGMAPOFFSETY
W_USEDSPRITES = A.W_USEDSPRITES -- optional: nil means "peer appearance off on this build"
W_STATEFLAGS = A.W_STATEFLAGS -- optional: nil turns the hardware tier off on that build
OVERWORLD_SPRITES_ROM = A.OVERWORLD_SPRITES_ROM -- optional: nil means "no cartridge graphics here"

-- CHECK THE TABLE IS WHERE WE THINK IT IS, before anything reads a graphics pointer out of it.
-- An address is measured per ROM build, but a build nobody has seen still gets vanilla's table by
-- way of the untested-build fallback, and a wrong ROM offset paints garbage rather than failing.
-- SPRITE_CHRIS is entry 0 and is the same on both builds measured (address 0x4000, 192 bytes,
-- bank 0x30, WALKING_SPRITE, palette 0), so it is a cheap six-byte assertion.
if OVERWORLD_SPRITES_ROM then
	local e = OVERWORLD_SPRITES_ROM
	local addr = (memory.read_u8(e, ROM_DOMAIN) or 0) | ((memory.read_u8(e + 1, ROM_DOMAIN) or 0) << 8)
	local size = memory.read_u8(e + 2, ROM_DOMAIN) or 0
	local bank = memory.read_u8(e + 3, ROM_DOMAIN) or 0
	local kind = memory.read_u8(e + 4, ROM_DOMAIN) or 0
	if not (addr >= 0x4000 and addr < 0x8000 and (size == 192 or size == 64)
		and bank > 0 and bank < 0x80 and kind >= 1 and kind <= 3) then
		log(string.format("MeshGhost: the sprite table is not at 0x%05X on this ROM "
			.. "(read addr=0x%04X size=%d bank=0x%02X type=%d) -- drawing peers from the "
			.. "cartridge is OFF, and they will wear this machine's sprite instead.",
			OVERWORLD_SPRITES_ROM, addr, size, bank, kind))
		OVERWORLD_SPRITES_ROM = nil
	end
end

if romClass == "known" then
	log("ROM: " .. romWhy .. " — addresses verified against a byte-identical build.")
elseif romClass == "archipelago" then
	log("ROM: " .. romWhy .. " — using its own measured address set.")
else
	-- One line, whatever the ROM. Toned down from a multi-line warning on the user's call
	-- (2026-08-18): every non-vanilla ROM is attempted, so a wall of caution on each startup is
	-- noise rather than information.
	--
	-- It still IDENTIFIES the ROM, which is the part that earns its place: if a ghost misbehaves
	-- on an untested build, the first line of the log already says which build it was. That is
	-- diagnostic value, not a warning.
	if os.getenv("MESHGHOST_CRYSTAL_STRICT") == "1" then
		log("REFUSING TO RUN (strict mode): " .. romWhy)
		return
	end
	log("ROM: untested — " .. romWhy .. ". Running anyway; object RAM only, never a save.")
end

-- A missing address is a refusal, never a fallback. Falling back to vanilla's value for one entry
-- is worse than not running: the gate would read a byte that means something else on this build,
-- pass, and start WRITING object RAM at addresses that were never checked.
-- Opt-in two ways, because the env var needs a BizHawk restart and an emulator is usually already
-- running by the time anyone decides to try: MESHGHOST_CRYSTAL_AP_TRY=1, or a file named
-- ap_try.flag beside this script. Deleting the file is how the experiment ends.
local TRY = os.getenv("MESHGHOST_CRYSTAL_AP_TRY") == "1"
if not TRY then
	local f = io.open(SCRIPT_DIR .. "/ap_try.flag", "r")
	if f then
		f:close()
		TRY = true
	end
end
local missing = {}
for _, name in ipairs({ "OBJECT_STRUCTS", "MAP_OBJECTS", "W_MAPGROUP", "W_MAPNUMBER", "W_YCOORD",
	"W_XCOORD", "W_MAPSTATUS", "W_BATTLEMODE", "W_BGMAPOFFSETX", "W_BGMAPOFFSETY" }) do
	if A[name] == nil then
		-- MESHGHOST_CRYSTAL_AP_TRY=1 is a deliberate experiment, never a default and never a
		-- fallback: it substitutes a NAMED candidate and says so on every startup, so a session
		-- run this way can always be told apart from a measured one afterwards. A missing
		-- candidate still refuses -- the flag lowers the bar to "unconfirmed", not to "invented".
		local c = TRY and A.candidates and A.candidates[name]
		if c then
			_G["__ap_try_" .. name] = c
			log(string.format("UNCONFIRMED ADDRESS IN USE: %s = 0x%04X (MESHGHOST_CRYSTAL_AP_TRY=1)",
				name, c))
		elseif TRY and name:match("^W_BGMAPOFFSET") then
			-- Not an address at all: zero makes screenCoords() position by whole tiles, which is
			-- visibly right on a tile boundary and up to a tile out mid-step.
			_G["__ap_try_" .. name] = 0
			log(string.format("NO ADDRESS FOR %s: using 0, so ghosts are positioned per TILE and "
				.. "will lag within a step.", name))
		else
			missing[#missing + 1] = name
		end
	end
end
if TRY then
	W_BATTLEMODE = W_BATTLEMODE or _G["__ap_try_W_BATTLEMODE"]
	W_BGMAPOFFSETX = W_BGMAPOFFSETX or _G["__ap_try_W_BGMAPOFFSETX"]
	W_BGMAPOFFSETY = W_BGMAPOFFSETY or _G["__ap_try_W_BGMAPOFFSETY"]
	log("This session is an EXPERIMENT: at least one address is unconfirmed. Nothing seen here")
	log("may be written to verified.md as a fact about the game.")
end
if #missing > 0 then
	log(string.format("REFUSING TO RUN on %s: %d address(es) not yet measured — %s.",
		A.label, #missing, table.concat(missing, ", ")))
	log("These are deliberately nil rather than guessed. Measure them with the probes beside this")
	log("script (see the adapter README), then fill them into ADDRESSES." .. (romTable or "?") .. ".")
	return
end

if BRIDGE_PORT_OVERRIDE then
	log(string.format("Bridge target %s:%d (MESHGHOST_BRIDGE_PORT is set, so no port walk).",
		BRIDGE_HOST, BRIDGE_PORT_OVERRIDE))
else
	log(string.format("Bridge: walking %s:%d-%d for a core that will have us. Two copies on one "
		.. "machine each find their own.", BRIDGE_HOST, BRIDGE_BASE_PORT,
		BRIDGE_BASE_PORT + BRIDGE_PORT_COUNT - 1))
end

local lastArea = nil

-- Experiment-mode diagnostic (ap_try.flag / MESHGHOST_CRYSTAL_AP_TRY=1 only). Prints, twice a
-- second, what the gate DECIDED and what it decided it from -- the Phase 9 lesson that a gate's
-- inputs beside its verdict is the thing worth logging, because a gate that silently says "no"
-- and a bridge that silently drops look identical from outside.
local diagFrames, diagLastKey = 0, nil
function diagnose(state)
	if not TRY then
		return
	end
	diagFrames = diagFrames + 1
	local key = state and (state.area_id .. "|" .. state.position[1] .. "," .. state.position[2]
		.. "|" .. state.orientation .. "|" .. state.anim) or "NO STATE"
	if diagFrames % 30 ~= 0 and key == diagLastKey then
		return
	end
	diagLastKey = key
	if state then
		logFile(string.format("gate: SENDING area=%s pos=%d,%d %s %s sprite=%s ghosts=%d "
			.. "[0FB1=%s 1439=%s]", state.area_id, state.position[1], state.position[2],
			state.orientation, state.anim, tostring(state.extras and state.extras.sprite),
			ghostCount(), tostring(u8(0x0FB1)), tostring(u8(0x1439))))
	else
		logFile(string.format("gate: NOT SENDING — status(0x%04X)=%s wants %d, battle(0x%04X)=%s "
			.. "wants 0, map=%s/%s [0FB1=%s 1439=%s]", W_MAPSTATUS, tostring(u8(W_MAPSTATUS)),
			MAPSTATUS_HANDLE, W_BATTLEMODE, tostring(u8(W_BATTLEMODE)), tostring(u8(W_MAPGROUP)),
			tostring(u8(W_MAPNUMBER)), tostring(u8(0x0FB1)), tostring(u8(0x1439))))
	end
end

local function tick()
	bridgeFrames = bridgeFrames + 1

	if not connected then
		if bridgeFrames < relayDownUntil then
			return -- a core told us the relay is down; give it time rather than spawning another
		end
		sinceRetry = sinceRetry + 1
		if sinceRetry >= RECONNECT_FRAMES then
			sinceRetry = 0
			connect()
			-- Only after a full sweep found nothing to join. A core already running -- started by
			-- hand, by a dev script, or by another copy of the game -- is used as-is, which is
			-- what stops autostart from ever producing a second one.
			if not connected then
				startCore(firstFreePort)
			end
		end
		return
	end

	-- A connection that never got an answer is not a connection worth keeping. Dropping it costs
	-- nothing if it really was an old core (the walk just finds or starts another); staying
	-- attached to a squatter costs the whole session.
	if not ready and helloSentAtFrame and bridgeFrames - helloSentAtFrame > HELLO_ANSWER_FRAMES then
		markPortBusy(currentPort, "never answered our hello, so it is not a core we can use")
		disconnect(nil)
		return
	end

	beginPolicyFrame()

	-- Push the log buffer to disk on a timer rather than per line: once every five seconds costs
	-- one frame's hitch every five seconds instead of one every second, and the file is never more
	-- than that far behind if someone is tailing it.
	if logfile and bridgeFrames % 300 == 0 then
		pcall(function() logfile:flush() end)
	end

	-- A ghost that has to be snapped is a ghost that fell behind the peer it is following; walking
	-- it would have looked like walking. Silent at zero.
	if snaps.runaways > 0 and bridgeFrames - snaps.at >= 60 then
		log(string.format("MeshGhost: repaired %d ghost%s found standing while the engine still "
			.. "thought they were mid-step -- the state that drags a ghost off screen. Cause not "
			.. "yet found; BANDAGES.md.", snaps.runaways, (snaps.runaways == 1) and "" or "s"))
		snaps.runaways, snaps.at = 0, bridgeFrames
	end

	if snaps.n > 0 and bridgeFrames - snaps.at >= 60 then
		log(string.format("MeshGhost: %d ghost snap%s in the last second (a snap is a jump the "
			.. "player can see -- it means a ghost could not walk to where its peer already was)",
			snaps.n, (snaps.n == 1) and "" or "s"))
		snaps.n, snaps.at = 0, bridgeFrames
	end

	receive()
	if not connected then
		return
	end

	-- FORGET A PEER THAT HAS STOPPED SENDING.
	--
	-- Until 2026-08-21 nothing here ever timed a peer out: a ghost lived until an explicit
	-- `despawn_remote` arrived, an area change, or the bridge dropping. A peer who simply goes
	-- quiet -- their game crashed, their machine slept, their client was killed -- was spawned or
	-- painted at their last position forever.
	--
	-- Found the hard way, and the dev rig is what exposed it: every time the core re-registers with
	-- the relay it is issued a NEW player id, so the loopback ghost becomes "p17-ghost" while
	-- "p16-ghost" is still on screen with nobody sending for it. Sixteen reconnections in one
	-- session, and the user's report was exact -- *"a weird 'static' ghost"* that survived
	-- savestates, because it was never in the game's memory at all: it was OUR painted overlay of a
	-- peer that no longer exists. Nothing in the arrays to find, which is why the sweep came back
	-- empty.
	--
	-- Three seconds at 60fps. Long enough that ordinary jitter, a slow frame or a paused emulator
	-- on the other end never trips it; short enough that a dead peer does not stand around.
	if bridgeFrames % 30 == 0 then
		for id, a in pairs(activity) do
			if a.seenAt and policyFrames - a.seenAt > 180 then
				log("MeshGhost: " .. id .. " stopped sending — removing their ghost")
				despawnGhost(id)
				overflow[id] = nil
				overflow[COMPARE.key(id)] = nil
		overflow[COMPARE.hwKey(id)] = nil
				activity[id] = nil
			end
		end
	end

	-- Object state is rebuilt from ROM on every map load, and a battle exit is also a map
	-- re-entry — so a ghost never survives either. Drop our bookkeeping rather than leaving
	-- entries pointing at slots the game has since reused.
	--
	-- FORGET, never despawn: by the time we notice, those bytes belong to the game again, and
	-- writing zeroes into them would delete one of its NPCs.
	--
	-- A BATTLE IS NOT A MAP CHANGE, and treating it as one is a bug in its own right. The first
	-- version of this also cleared the bookkeeping whenever wMapStatus left MAPSTATUS_HANDLE, on
	-- the theory that a battle rebuilds the array the way a map load does. The user watched it:
	-- leaving a wild battle produced TWO ghosts (2026-08-19). The old object had survived the
	-- battle perfectly well — so forgetting it only meant spawning a second one beside it, with
	-- nothing left tracking the first. The area check stays because a map change really does
	-- rebuild the array; everything else is left to stillOurs(), which asks whether the object we
	-- recorded is still the object we made rather than guessing from a lifecycle event.
	local area = areaId()
	if area ~= lastArea then
		if lastArea then
			for id in pairs(ghosts) do
				ghosts[id] = nil
			end
			-- The drawn tier has no slots to forget, but it does have positions, and they were
			-- computed against the OLD map's camera. Clear them too: a peer still on this map
			-- re-registers on its next state, which is at most a frame away.
			overflow = {}
			anchorIndex = nil -- the object array is rebuilt; last map's anchor means nothing
		end
		lastArea = area
	end

	if ready then
		local state = getLocalState()
		diagnose(state)
		send({ type = "local_state", payload = { state = state } })
	end

	drawOverflow()
end

event.onexit(function()
	pcall(function()
		for id in pairs(ghosts) do
			despawnGhost(id)
		end
		if sock then
			sock:close()
		end
	end)
end)

-- Dev affordance, and the only one in this file: when loaded by dev-scripts/bizhawk-dev-loader.lua
-- (a development tool, never shipped), hand it the per-frame function instead of taking the frame
-- loop. Emerald's adapter has done this since 2026-08-18; Crystal's did not, so under the loader
-- it seized the loop, the loader never polled its control file again, and no probe, savestate or
-- screenshot script could run beside it -- the adapter looked fine while the tool around it was
-- dead. A player opening this file in the Lua Console sets neither global and gets the normal
-- loop below, unchanged.
MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function()
	-- The same three things Emerald's unload lists, for the same reasons: a leaked bridge socket
	-- makes the next load bounce off "busy: this core already has a game attached"; ghosts are
	-- real objects in the game that nothing else will clear; and the log file is an OS handle that
	-- stays locked on disk. disconnect() covers the first two -- it despawns every ghost.
	pcall(disconnect, nil)
	if logfile then
		pcall(function() logfile:close() end)
		logfile = nil
	end
end

if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
