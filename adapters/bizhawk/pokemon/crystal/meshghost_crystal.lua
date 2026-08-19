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
		-- Two candidates, deliberately unresolved. Both read 0 whenever the player is in the
		-- overworld and 1 through a wild battle:
		--   0x015A -- non-zero earliest and for the most of each battle.
		--   0x1234 -- vanilla's wBattleMode (0xD22D -> flat 0x122D) plus 7, the same delta the
		--             coordinate block moved. Corroboration from an independent direction.
		-- Both earlier battles were WILD, so nothing has yet asked either to hold a DIFFERENT
		-- non-zero value. A trainer battle does (vanilla semantics: 1 wild, 2 trainer), and
		-- ap_battlemode_probe.lua reports the moment one ends. Until then this stays nil and the
		-- adapter refuses -- picking the steadier of two on a hunch is the exact move that put
		-- three refuted addresses in this file already.
		W_BATTLEMODE = nil,

		-- NOT the table. These are the leading unconfirmed candidates for the entries still nil
		-- above, used only when MESHGHOST_CRYSTAL_AP_TRY=1 asks for a deliberate experiment, and
		-- logged as unconfirmed every time. Kept separate from the real fields on purpose: a
		-- candidate that can be read by ordinary code eventually gets treated as measured.
		candidates = {
			W_BATTLEMODE = 0x015A,
		},
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
local W_USEDSPRITES
local USED_SPRITES_CAPACITY = 32 -- SPRITE_GFX_LIST_CAPACITY

local OBJECT_LENGTH, MAPOBJECT_LENGTH = 0x28, 0x10
local NUM_OBJECT_STRUCTS, NUM_MAP_OBJECTS = 13, 16

local M_STRUCT_ID, M_SPRITE, M_Y, M_X = 0x00, 0x01, 0x02, 0x03
local F_SPRITE, F_MAP_OBJECT_INDEX, F_SPRITE_TILE = 0x00, 0x01, 0x02
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
local logfile
do
	local name = string.format("meshghost_crystal_%s.log", os.date("%Y%m%d_%H%M%S"))
	logfile = io.open(SCRIPT_DIR .. "/logs/" .. name, "w") or io.open(SCRIPT_DIR .. "/" .. name, "w")
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
local function logFile(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
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
local function inPlay()
	return u8(W_MAPSTATUS) == MAPSTATUS_HANDLE
		and u8(W_BATTLEMODE) == 0
		and not (u8(W_MAPGROUP) == 0 and u8(W_MAPNUMBER) == 0)
		and (u8(OBJECT_STRUCTS + F_SPRITE) or 0) ~= 0
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
		extras = { sprite = u8(base + F_SPRITE) or 0 },
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

local function shouldBlock(id, x, y)
	local a = activity[id]
	if not a then
		a = { x = x, y = y, movedAt = policyFrames, passableUntil = 0 }
		activity[id] = a
	end
	if a.x ~= x or a.y ~= y then
		a.x, a.y, a.movedAt = x, y, policyFrames
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
--   0-1 address, 2 size in tiles, 3 bank, 4 type, 5 palette
-- six bytes per entry, indexed by SPRITE_* - 1 (the table's own comment: "entries correspond to
-- SPRITE_* constants", which start at 1).
local OVERWORLD_SPRITES_ROM = 0x14736 -- bank 5 * 0x4000 + (0x4736 - 0x4000)
local SPRITEDATA_STRIDE = 6

local function romByte(offset)
	return memory.read_u8(offset, ROM_DOMAIN) or 0
end

-- Returns the ROM offset of a sprite's graphics, its size in tiles, and the palette the game
-- itself assigns it -- or nil for a sprite id the table does not cover.
local function spriteGfxInRom(spriteId)
	if not spriteId or spriteId < 1 or spriteId > 255 then
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

local lastMenuBox = nil

function drawOverflow()
	drawFrames = drawFrames + 1
	if not DRAW_OVERFLOW or not inPlay() then
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
	local offSample = nil

	-- CALIBRATE AGAINST THE HARDWARE, rather than deriving a screen position from first
	-- principles. The engine's F_SPRITE_X/Y are in its own scrolled space, not screen pixels, and
	-- three attempts at converting them by reasoning each put whole rows off screen. OAM is not
	-- ambiguous: it is what the PPU draws from, in screen pixels (offset by 8 and 16 by the
	-- hardware). The player is always object struct 0 and always has OAM entries, so the
	-- difference between the two is the offset that applies to everything else this frame.
	local playerOamY = memory.read_u8(0x00, "OAM") or 0
	local playerOamX = memory.read_u8(0x01, "OAM") or 0
	local calX = (playerOamX - 8) - (u8(OBJECT_STRUCTS + F_SPRITE_X) or 0)
	local calY = (playerOamY - 16) - (u8(OBJECT_STRUCTS + F_SPRITE_Y) or 0)
	for id, o in pairs(overflow) do
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
			local sx, sy = screenCoords(o.x, o.y)
			sx = sx + calX
			sy = sy + calY
			if sx >= 240 then sx = sx - 256 end
			if sy >= 240 then sy = sy - 256 end
			local onScreen = sx > -16 and sx < 160 and sy > -16 and sy < 144
			if not onScreen then
				nOffScreen = nOffScreen + 1
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
					nDrawn = nDrawn + 1
					-- the palette the local player's own sprite is drawn with, which is the one
					-- these tiles were coloured for
					drawCharacter(source, sx, sy, palette, o.facing, walkingFor)
				end
			end
		end
	end

	-- Once a second, say what the drawn tier actually did. "Half the screen is empty" needs a
	-- number that separates "the peers never arrived" from "they arrived and were not drawn".
	if drawFrames % 60 == 0 and nWanted > 0 then
		logFile(string.format("drawn tier: %d peers waiting, %d drawn (%d from the cartridge), "
			.. "%d no sprite tiles, %d off screen, %d hidden by UI, %d spawned as real objects",
			nWanted, nDrawn, nFromRom, nNoTile, nOffScreen, nHidden, ghostCount()))
		if offSample then
			logFile("drawn tier: example of one it discarded -- " .. offSample)
		end
	end
end

-- The inverse of DIR_NAMES: a peer sends orientation as a name, and we need the numeric dir.
local ORIENTATION_TO_DIR = { down = 0, up = 1, left = 2, right = 3 }

local DELTA_TO_DIR = { ["0,1"] = 0, ["0,-1"] = 1, ["-1,0"] = 2, ["1,0"] = 3 }

local function stepGhost(g, dir)
	local sdx = (dir == 3) and 2 or (dir == 2) and -2 or 0
	local sdy = (dir == 0) and 2 or (dir == 1) and -2 or 0
	local x = (u8(g.st_base + F_MAP_X) or 0) + ((dir == 3) and 1 or (dir == 2) and -1 or 0)
	local y = (u8(g.st_base + F_MAP_Y) or 0) + ((dir == 0) and 1 or (dir == 1) and -1 or 0)

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
end

local function teleportGhost(g, x, y)
	-- Same reason as the spawn: this writes screen coordinates too.
	if not cameraSettled() then
		return
	end
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
	local x, y = math.floor(pos[1]) + LOOPBACK_OFFSET_X, math.floor(pos[2])
	if x < 0 or x > 255 or y < 0 or y > 255 then
		return
	end

	-- A peer in a different area has no meaningful position here.
	if state.area_id ~= areaId() then
		despawnGhost(id)
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
		return
	end

	-- FORCE_PEER_SPRITE substitutes here rather than only inside applyPeerSprite, so the probe
	-- flag reaches BOTH tiers. It claimed to substitute "every peer" and did not touch the drawn
	-- one, which made a test of the cartridge path silently measure nothing (2026-08-19).
	local peerSprite = FORCE_PEER_SPRITE or (state.extras and tonumber(state.extras.sprite)) or nil

	-- A peer that should not be blocking is DRAWN rather than spawned: no tile, no collision,
	-- and its engine slot freed for a peer who is actually moving.
	if not shouldBlock(id, x, y) then
		if ghosts[id] then
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

	-- Only act while the ghost is idle; interrupting a step is what makes a character teleport
	-- while animating.
	if (u8(g.st_base + F_WALKING) or STANDING) ~= STANDING then
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
		end
		return
	end
	local dir = DELTA_TO_DIR[string.format("%d,%d", x - cx, y - cy)]
	if dir then
		stepGhost(g, dir) -- one tile: walk it, so the game animates the step
	else
		teleportGhost(g, x, y) -- further than a step: snap, rather than fake a long walk
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

	receive()
	if not connected then
		return
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
