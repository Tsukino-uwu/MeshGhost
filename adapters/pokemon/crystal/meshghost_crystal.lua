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
local BRIDGE_PORT = tonumber(os.getenv("MESHGHOST_BRIDGE_PORT") or "") or 7778
local RECONNECT_FRAMES = 120

-- DEV-ONLY loopback offset, in tiles. A loopback relay echoes your own state back to you, so
-- without this the ghost spawns on the tile you are standing on — and this ghost is a real object
-- event with real collision, so that means standing inside something solid.
--
-- Offset to the SIDE rather than trailing behind, so the ghost can be compared against the real
-- character rather than hidden by it (user's standing preference for test ghosts). Set to 0 for a
-- real two-machine session, where a peer's position is already their own.
local LOOPBACK_OFFSET_X = tonumber(os.getenv("MESHGHOST_LOOPBACK_OFFSET_X") or "") or 2

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

local OBJECT_STRUCTS = flat(0xD4D6) -- 01:d4d6, 13 x 0x28
local MAP_OBJECTS = flat(0xD71E) -- 01:d71e, 16 x 0x10
local W_MAPGROUP, W_MAPNUMBER = flat(0xDCB5), flat(0xDCB6)
local W_YCOORD, W_XCOORD = flat(0xDCB7), flat(0xDCB8) -- the VISIBLE WINDOW origin, not the player
local W_MAPSTATUS, W_BATTLEMODE = flat(0xD432), flat(0xD22D)
local W_BGMAPOFFSETX, W_BGMAPOFFSETY = flat(0xD14C), flat(0xD14D)

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
		if dir and #dir > 0 then
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
--   "incompatible" a ROM we have POSITIVE evidence is wrong: Archipelago's Crystal patch
--                  rearranges WRAM non-uniformly, so vanilla addresses land on whatever now
--                  occupies them. Refused, because this is not "untested", it is "tested and known
--                  to corrupt". Overridable with MESHGHOST_CRYSTAL_FORCE=1 for deliberate
--                  experimentation.
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
		return "known", "vanilla Crystal V1.0"
	end
	-- Archipelago renames the header, which is a cheaper and stronger signal than the checksum.
	if title:sub(1, 3) == "AP_" then
		return "incompatible",
			string.format("ROM title %q — Archipelago's patch moves WRAM, so these addresses "
				.. "would land on the wrong data", title)
	end
	return "unknown", string.format("ROM title %q, checksum %02X%02X — not a build these addresses "
		.. "were derived from", title, u8(0x14E, ROM_DOMAIN) or 0, u8(0x14F, ROM_DOMAIN) or 0)
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

local romClass, romWhy = classifyRom()
log("=== MeshGhost — Pokémon Crystal ===")
if romClass == "known" then
	log("ROM: " .. romWhy .. " — addresses verified against a byte-identical build.")
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
log(string.format("Bridge target %s:%d (set MESHGHOST_BRIDGE_PORT to change).", BRIDGE_HOST, BRIDGE_PORT))

local lastArea = nil

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
		send({ type = "local_state", payload = { state = getLocalState() } })
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
