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
local BRIDGE_PORT = tonumber(MESHGHOST_BRIDGE_PORT or os.getenv("MESHGHOST_BRIDGE_PORT") or "") or 7778
local RECONNECT_FRAMES = 120

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
-- `cd` returned C:\dev\MeshGhost\adapters\pokemon\crystal. So pwd is the primary answer here, not
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
local logfile = io.open(string.format("%s/meshghost_crystal_%s.log", SCRIPT_DIR,
	os.date("%Y%m%d_%H%M%S")), "w")

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
	local cwd = (io.popen and (function()
		local p = io.popen("cd")
		if not p then
			return nil
		end
		local out = p:read("*l")
		p:close()
		return out
	end)()) or nil

	local candidates = {
		SCRIPT_DIR .. "/lib/x64/",
		SCRIPT_DIR .. "/../emerald/lib/x64/",
		"adapters/pokemon/emerald/lib/x64/",
	}
	if cwd then
		candidates[#candidates + 1] = cwd .. "\\adapters\\pokemon\\emerald\\lib\\x64\\"
	end

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

function ghostCount()
	local n = 0
	for _ in pairs(ghosts) do
		n = n + 1
	end
	return n
end

local function freeMapObject()
	for i = 1, NUM_MAP_OBJECTS - 1 do
		if u8(MAP_OBJECTS + i * MAPOBJECT_LENGTH + M_SPRITE) == 0 then
			return i
		end
	end
end

local function freeStruct()
	for i = 1, NUM_OBJECT_STRUCTS - 1 do
		if u8(OBJECT_STRUCTS + i * OBJECT_LENGTH + F_SPRITE) == 0 then
			return i
		end
	end
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

local function screenCoords(mx, my)
	local wx, wy = u8(W_XCOORD) or 0, u8(W_YCOORD) or 0
	local bx, by = u8(W_BGMAPOFFSETX) or 0, u8(W_BGMAPOFFSETY) or 0
	return (((mx - wx) & 0x0F) * 16 - bx) & 0xFF, (((my - wy) & 0x0F) * 16 - by) & 0xFF
end

local function despawnGhost(id)
	local g = ghosts[id]
	if not g then
		return
	end
	w8(g.st_base + F_SPRITE, 0)
	for off = 0, MAPOBJECT_LENGTH - 1 do
		w8(g.mo_base + off, 0)
	end
	ghosts[id] = nil
	log("MeshGhost: despawned " .. id)
end

local function spawnGhost(id, x, y)
	local srcMo, srcSt = findTemplateNpc()
	if not srcMo then
		return nil -- no template on this map; try again next frame
	end
	local mo, st = freeMapObject(), freeStruct()
	if not mo or not st then
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

	ghosts[id] = { mo = mo, st = st, mo_base = moBase, st_base = stBase, area = areaId() }
	log(string.format("MeshGhost: spawned %s at %d,%d (map object %d <-> struct %d)", id, x, y, mo, st))
	return ghosts[id]
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

	local g = ghosts[id]
	if not g then
		spawnGhost(id, x, y)
		return
	end

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

local function connect()
	local s = socketCore.tcp()
	if not s then
		return
	end
	s:settimeout(0.05)
	local ok = s:connect(BRIDGE_HOST, BRIDGE_PORT)
	if not ok then
		pcall(function()
			s:close()
		end)
		return
	end
	s:settimeout(0)
	sock, connected, ready, rxBuffer = s, true, false, ""
	log(string.format("MeshGhost: bridge connected on %s:%d", BRIDGE_HOST, BRIDGE_PORT))
	send({ type = "hello", payload = { game_id = GAME_ID, game_version = GAME_VERSION } })
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
		log("MeshGhost: rejected (" .. tostring(p.reason) .. ")")
		disconnect(nil)
	elseif t == "render_remote" then
		renderRemote(tostring(p.player_id), p.state)
	elseif t == "despawn_remote" then
		despawnGhost(tostring(p.player_id))
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

log(string.format("Bridge target %s:%d (set MESHGHOST_BRIDGE_PORT to change).", BRIDGE_HOST, BRIDGE_PORT))

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
	if not connected then
		sinceRetry = sinceRetry + 1
		if sinceRetry >= RECONNECT_FRAMES then
			sinceRetry = 0
			connect()
		end
		return
	end

	receive()
	if not connected then
		return
	end

	-- Object state is rebuilt from ROM on every map load, and a battle exit is also a map
	-- re-entry — so a ghost never survives either. Drop our bookkeeping rather than leaving
	-- entries pointing at slots the game has since reused.
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

while true do
	tick()
	emu.frameadvance()
end
