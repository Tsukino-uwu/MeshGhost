-- MeshGhost — Pokémon Crystal adapter
--
-- Writes object and sprite RAM only, never a save or the ROM. Knows vanilla V1.0 and V1.1, Archipelago
-- and Speedchoice v8.1 (classifyRom); another build runs on vanilla's table after saying so.
-- Peers are painted over the emulator's output (the drawn tier); the spawned tier, a real object event
-- the engine walks, is a dev opt-in. A pokecrystal symbol name says where to look, not what is measured.
--
-- Run: load the ROM in BizHawk, then Lua Console -> Script -> Open this file.
-- Log: logs/meshghost_crystal_<timestamp>_<pid>.log beside this script.

local GAME_ID = "crystal"
local GAME_VERSION = "phase9"

local BRIDGE_HOST = "127.0.0.1"

-- A core serves one adapter and rejects a second, so two copies of the game on one machine walk the
-- range and take the first core that answers `bridge_ready`.
local BRIDGE_BASE_PORT = 7778
local BRIDGE_PORT_COUNT = 8

-- A named port is honoured and never walked: landing somewhere else would be worse than failing.
local BRIDGE_PORT_OVERRIDE = tonumber(MESHGHOST_BRIDGE_PORT or os.getenv("MESHGHOST_BRIDGE_PORT") or "")

local RECONNECT_FRAMES = 120
-- A core that cannot reach the relay is still our core: wait on it rather than walking on.
local RELAY_DOWN_BACKOFF_FRAMES = 600
-- Silence is not acceptance: a port that never answers is more likely another program than a core.
local HELLO_ANSWER_FRAMES = 90
-- A core that said "busy" is live but not ours; re-probing it every sweep is noise.
local BUSY_PORT_COOLDOWN_FRAMES = 600

-- Dev, in tiles: puts the "<id>-ghost" loopback echo beside the player; MESHGHOST_LOOPBACK_TRAIL forces 0.
-- A global set before dofile() is read first, so a running emulator needs no restart.
local LOOPBACK_OFFSET_X = (os.getenv("MESHGHOST_LOOPBACK_TRAIL") and 0)
	or tonumber(MESHGHOST_LOOPBACK_OFFSET_X or os.getenv("MESHGHOST_LOOPBACK_OFFSET_X") or "") or 2

-- Dev: renders the loopback echo twice in one frame, spawned on one side and painted on the other,
-- because what the painted tier lacks (a cave's dark, a reflection, a doorway) is a question about a place.
local COMPARE_TIERS = (MESHGHOST_COMPARE_TIERS or os.getenv("MESHGHOST_COMPARE_TIERS")) and true or false
-- Dev, read-only, loopback: a spawned ghost's step lag, split into `wire` (the player takes a tile to
-- it returning through the core) and `apply` (to stepGhost's write); the engine shows it a frame later.
-- `blocked` counts frames a tile waited for the ghost's own step to end.
local stepLag = {
	on = (MESHGHOST_CRYSTAL_STEP_LAG or os.getenv("MESHGHOST_CRYSTAL_STEP_LAG")) == "1",
	commit = {},  -- "x,y" of a tile the player took -> the frame they took it
	seen = {},    -- per peer, the last tile we were told about, so a change is detectable
	open = {},    -- per peer, an arrival that has not been walked yet
	wire = {}, apply = {}, total = {}, -- histograms: frames -> how many steps took that long
	n = 0, blocked = 0, unknown = 0, at = 0,
}
-- No logging here: `logFile` is a local declared below, so inside this function it is a nil global.
stepLag.close = function(id)
	local o = stepLag.open[id]
	if not o then
		return
	end
	stepLag.open[id] = nil
	local now = emu.framecount()
	-- Clamped at 40: 250ms of interpolation alone is 15 frames, and a saturated top bucket reads as a
	-- spread of zero. `lo`/`hi` keep the raw extremes outside the histogram.
	local function bump(h, v)
		h.n, h.sum = (h.n or 0) + 1, (h.sum or 0) + v
		h.lo = math.min(h.lo or v, v)
		h.hi = math.max(h.hi or v, v)
		local k = v
		if k < 0 then
			k = 0
		elseif k > 40 then
			k = 40
		end
		h[k] = (h[k] or 0) + 1
	end
	bump(stepLag.wire, o.wire)
	bump(stepLag.apply, now - o.at)
	bump(stepLag.total, now - o.commit)
	stepLag.n = stepLag.n + 1
end
-- Comparison copies' tile offsets, left to right hardware, drawn, player, spawned; `dy` shifts every
-- copy (negative is up), once, at peerPixY. One table: the main chunk is at Lua's 200-local ceiling.
local COMPARE = { drawn = -2, spawned = 3, hw = -4, dy = 0 }
-- The spawned tier is a dev opt-in; compare mode implies it. On COMPARE for the 200-local reason.
COMPARE.spawnTier = COMPARE_TIERS
	or (MESHGHOST_CRYSTAL_SPAWN_TIER or os.getenv("MESHGHOST_CRYSTAL_SPAWN_TIER")) == "1"
-- The drawn copy has its own `overflow` key, so it never collides with the spawned copy's entry.
function COMPARE.key(id) return id .. " (drawn copy)" end
function COMPARE.hwKey(id) return id .. " (hardware copy)" end

local DOMAIN = "WRAM"
local ROM_DOMAIN = "ROM"

----------------------------------------------------------------------------
-- Addresses
----------------------------------------------------------------------------

local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

-- One table per ROM build, chosen by classifyRom(): a build that moves WRAM gets its own set, never
-- vanilla's. Vanilla's and Speedchoice's are read from hash-verified builds' .sym, Archipelago's measured.
local ADDRESSES = {
	vanilla = {
		label = "vanilla Crystal V1.0",
		-- wOBPals1 and wMenuBorder*, used by the drawn tier.
		W_OBPALS = 0x5040,
		MENUBOX = { top = 0x0F82, left = 0x0F83, bottom = 0x0F84, right = 0x0F85 },
		OBJECT_STRUCTS = flat(0xD4D6), -- 01:d4d6, 13 x 0x28
		MAP_OBJECTS = flat(0xD71E), -- 01:d71e, 16 x 0x10
		W_MAPGROUP = flat(0xDCB5),
		W_MAPNUMBER = flat(0xDCB6),
		-- the visible window's origin, not the player
		W_YCOORD = flat(0xDCB7),
		W_XCOORD = flat(0xDCB8),
		W_MAPSTATUS = flat(0xD432),
		W_BATTLEMODE = flat(0xD22D),
		W_BGMAPOFFSETX = flat(0xD14C),
		W_BGMAPOFFSETY = flat(0xD14D),
		-- A connection record holds the neighbour's width, never ours: east and south need our size.
		W_MAPCONNECTIONS = flat(0xD1A8),
		W_MAPHEIGHT = flat(0xD19E),
		W_MAPWIDTH = flat(0xD19F),
		-- wUsedSprites: 32 entries of [sprite id, VRAM tile], which sprites this map has loaded and where.
		W_USEDSPRITES = flat(0xD154),
		-- wStateFlags: bit 0 clears while the game empties the sprite buffer itself (the START menu).
		W_STATEFLAGS = flat(0xD0ED),
		-- OverworldSprites, 05:4736: six-byte rows by sprite id - 1, where the drawn tier reads peer graphics.
		OVERWORLD_SPRITES_ROM = 0x14736,
		-- StepVectors, 01:4700: a hint; ENGINE.gaitGroups re-checks its signature and scans otherwise.
		STEP_VECTORS_ROM = 0x4700,
		-- hSCX/hSCY, the camera, read on the system bus: HRAM is not in the WRAM domain.
		H_SCX = 0xFFCF,
		H_SCY = 0xFFD0,
		-- FishingGFX 2e:44f2 and KrisFishingGFX 2e:4582, not FishingRodGFX: the game overwrites the rod
		-- with this sheet. The peer's sprite id picks one. Known builds only: there is no signature to check.
		FISHING_GFX_ROM = 0xB84F2,
		FISHING_GFX_ROM_KRIS = 0xB8582,
		-- JumpShadowGFX, 41:4550, read from ROM because VRAM $fc holds the rod while anyone fishes.
		SHADOW_GFX_ROM = 0x104550,
		-- Emotes, 05:444d: how a receiver turns an emote number back into pixels.
		EMOTES_ROM = 0x1444D,
		-- wSpriteUpdatesEnabled: the positive "may a character show" test, 0 on full-screen UI. A fly
		-- shows the species' party icon: MonMenuIcons (23:6ac4) by species - 1, then IconPointers (23:6bbf).
		W_SPRITEUPDATESON = flat(0xC2CE),
		W_CURPARTYMON = flat(0xD109),
		W_PARTYSPECIES = flat(0xDCD8),
		MON_ICONS_ROM = 0x8EAC4,
		ICON_POINTERS_ROM = 0x8EBBF,
		ICONS_BANK = 0x23,
	},

	-- The patch moves WRAM non-uniformly, so each entry is measured; the deltas only show they disagree.
	-- A missing entry is nil, which refuses or turns a feature off: fill one from a probe, never a delta.
	archipelago = {
		label = "Archipelago-patched Crystal",
		-- Inherited from vanilla, not measured on this build (probes/oam_probe.lua measures them).
		W_OBPALS = 0x5040,
		MENUBOX = { top = 0x0F82, left = 0x0F83, bottom = 0x0F84, right = 0x0F85 },
		OBPALS_MEASURED = false,
		OBJECT_STRUCTS = 0x14DC, -- vanilla+6
		MAP_OBJECTS = 0x16F4, -- vanilla-0x2A
		W_YCOORD = 0x1CBE, -- vanilla+7
		W_XCOORD = 0x1CBF, -- vanilla+7
		W_MAPGROUP = 0x1CBC,
		W_MAPNUMBER = 0x1CBD,
		-- Chosen by behaviour (holds 2 while walking), not label; STATUS_ADDR compares a candidate.
		W_MAPSTATUS = tonumber(os.getenv("MESHGHOST_CRYSTAL_STATUS_ADDR") or "") or 0x1439,
		W_BATTLEMODE = 0x1234,
		OVERWORLD_SPRITES_ROM = 0x14564, -- found by the table's own signature, as on vanilla
		-- Ids $65/$66 are run sprites a vanilla cartridge lacks, so a runner here sends their art.
		WIRE_ART = true,
		-- Found by signature; this build's table has a fourth gait, 8px a tick for 2 ticks.
		STEP_VECTORS_ROM = 0x48C9,
		-- Vanilla's $FFCF/$FFD0 never change here: found by an HRAM sweep (probes/ap_hram_scroll_probe.lua).
		H_SCX = 0xFFC7,
		H_SCY = 0xFFC8,

		-- Unconfirmed, for MESHGHOST_CRYSTAL_AP_TRY only: apart, so nothing treats one as measured.
		candidates = {},
		W_BGMAPOFFSETX = 0x1153,
		W_BGMAPOFFSETY = 0x1154,
		-- No connection block: unmeasured, so cross-map ghosts are off (probes/connections_probe.lua).
	},

	-- Crystal Speedchoice v8.1, read from the .sym of its source built byte-identical to the ROM. One
	-- inserted byte (wLastSpawnMapGroup) puts the map block and party species at vanilla+1.
	speedchoice = {
		label = "Crystal Speedchoice v8.1",
		OBJECT_STRUCTS = flat(0xD4D6), -- 01:d4d6, layout unchanged (wPlayerStruct fields agree)
		MAP_OBJECTS = flat(0xD71E), -- 01:d71e
		W_MAPGROUP = flat(0xDCB6), -- vanilla+1, all four
		W_MAPNUMBER = flat(0xDCB7),
		W_YCOORD = flat(0xDCB8),
		W_XCOORD = flat(0xDCB9),
		W_MAPSTATUS = flat(0xD432),
		W_BATTLEMODE = flat(0xD22D),
		W_BGMAPOFFSETX = flat(0xD14C),
		W_BGMAPOFFSETY = flat(0xD14D),
		W_MAPCONNECTIONS = flat(0xD1A8),
		W_MAPHEIGHT = flat(0xD19E),
		W_MAPWIDTH = flat(0xD19F),
		W_USEDSPRITES = flat(0xD154),
		W_STATEFLAGS = flat(0xD0ED), -- `wVramState` in this fork's older label set
		OVERWORLD_SPRITES_ROM = 0x14723, -- 05:4723, vanilla-0x13; same 612 bytes, so gfxSig agrees
		STEP_VECTORS_ROM = 0x4700, -- 01:4700, GetStepVectorSign still at 01:4730: three groups
		H_SCX = 0xFFCF,
		H_SCY = 0xFFD0,
		FISHING_GFX_ROM = 0xB84D7, -- 2e:44d7
		FISHING_GFX_ROM_KRIS = 0xB8567, -- 2e:4567
		SHADOW_GFX_ROM = 0x104550, -- 41:4550, unmoved
		EMOTES_ROM = 0x1443A, -- 05:443a
		W_SPRITEUPDATESON = flat(0xC2CE),
		W_CURPARTYMON = flat(0xD109),
		W_PARTYSPECIES = flat(0xDCD9), -- vanilla+1
		MON_ICONS_ROM = 0x8EACA, -- 23:6aca, vanilla+6, same bytes
		ICON_POINTERS_ROM = 0x8EBC5, -- 23:6bc5; entries differ from vanilla's because Icons moved
		ICONS_BANK = 0x23,
	},
}

-- Assigned once, from the selected table, before the main loop runs.
local OBJECT_STRUCTS, MAP_OBJECTS
local W_MAPGROUP, W_MAPNUMBER, W_YCOORD, W_XCOORD
local W_MAPSTATUS, W_BATTLEMODE, W_BGMAPOFFSETX, W_BGMAPOFFSETY
-- nil where unmeasured (Archipelago), which switches the peer's own appearance off.
local W_USEDSPRITES, W_STATEFLAGS
-- wOBPals1, the eight live object palettes. A load-time value the selected table overrides, like
-- MENUBOX, which a top-level statement (TEXTBOX.stale) reads before any ROM is classified.
local W_OBPALS = 0x5040
local USED_SPRITES_CAPACITY = 32 -- SPRITE_GFX_LIST_CAPACITY

local OBJECT_LENGTH, MAPOBJECT_LENGTH = 0x28, 0x10
local NUM_OBJECT_STRUCTS, NUM_MAP_OBJECTS = 13, 16

local M_STRUCT_ID, M_SPRITE, M_Y, M_X = 0x00, 0x01, 0x02, 0x03
local F_SPRITE, F_MAP_OBJECT_INDEX, F_SPRITE_TILE = 0x00, 0x01, 0x02

-- SPRITEMOVEDATA_STANDING_DOWN/UP/LEFT/RIGHT: one stand-still movement per facing, since the engine
-- restores the facing from this byte after every step (one entry for all four would face down a frame).
local SPRITEMOVEDATA_STANDING_BY_DIR = { [0] = 0x06, [1] = 0x07, [2] = 0x08, [3] = 0x09 }
local F_FLAGS1, F_PALETTE = 0x04, 0x06
local F_WALKING, F_DIRECTION, F_STEP_TYPE, F_STEP_DURATION = 0x07, 0x08, 0x09, 0x0A
local F_ACTION, F_FACING = 0x0B, 0x0D
local F_MAP_X, F_MAP_Y = 0x10, 0x11
local F_LAST_MAP_X, F_LAST_MAP_Y = 0x12, 0x13
local F_INIT_X, F_INIT_Y = 0x14, 0x15
local F_SPRITE_X, F_SPRITE_Y = 0x17, 0x18

-- Engine constants and helpers share one table: the main chunk is at Lua's 200-local ceiling.
local ENGINE = {
	WONT_DELETE = 0x02, -- OBJECT_FLAGS1 bit: the engine's own culler leaves this object alone
	UNASSIGNED = 0xFF, -- OBJECT_MAP_OBJECT_INDEX for an object with no map-object entry
	MAPSTATUS_HANDLE = 2, -- wMapStatus while the overworld is the thing on screen
	-- playerEmote is a field so getLocalState, defined above its readers, can still reach it.
	emoteIds = {}, -- the 16 bytes at VRAM $f8 -> which Emotes entry they are (-1 for none)
}

-- The "!" is a separate map object 16px above the character, flagged EMOTE_OBJECT and drawn from
-- absolute tiles $f8-$fb, so nothing about it rides the character's own action or facing byte.
local emote = {
	F_YOFF = 0x1A, -- OBJECT_SPRITE_Y_OFFSET
	FLAG1 = 0x80, -- EMOTE_OBJECT, bit 7 of OBJECT_FLAGS1
	PAL = 5, -- PAL_OW_EMOTE
	VTILE = 0xF8, -- where the 4-tile emotes are loaded, and what FacingEmote names
	LIFT = 16, -- how far above the character's own tile the box sits
	rom = nil, -- the Emotes table, resolved at startup from the address block
	gfx = {}, -- emote index -> flat ROM offset of its graphics, memoised

	-- The ledge hop's shadow lives here too: like the "!", it is a separate object flagged EMOTE_OBJECT.
	F_STEP_INDEX = 0x1C, -- OBJECT_STEP_INDEX, the anon-jumptable index (which phase runs next)
	F_JUMP_HEIGHT = 0x1F, -- OBJECT_JUMP_HEIGHT, what UpdateJumpPosition accumulates
	-- The shadow's Y offset below the character's tile, by facing; up's 14 is unmeasured.
	SHADOW_DY = { [0] = 14, [1] = 14, [2] = 12, [3] = 12 },
}
local STANDING = 255

----------------------------------------------------------------------------
-- Logging
----------------------------------------------------------------------------

-- BizHawk often reports `source` as a chunk name, not "@<path>"; its working directory is then the
-- script's own, which the last-resort fallback relies on.
local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		local dir = info.source:sub(2):match("^(.*)[/\\]")
		-- Absolute only: Windows resolves a relative DLL path against BizHawk's process directory.
		if dir and #dir > 0 and (dir:match("^%a:") or dir:match("^[/\\]")) then
			return dir
		end
	end
	-- Set by a launcher, since `--lua=` reports `source` as `[string "main"]`. The game-specific name
	-- wins: BizHawk runs every script in one process, so a shared env var leaks between adapters.
	local fromEnv = MESHGHOST_SCRIPT_DIR
		or os.getenv("MESHGHOST_SCRIPT_DIR_CRYSTAL")
		or os.getenv("MESHGHOST_SCRIPT_DIR")
	if fromEnv and fromEnv ~= "" then
		return (fromEnv:gsub("[/\\]$", ""))
	end

	-- Last resort: the working directory, via a real `cmd` that flashes a console window.
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
-- logs/ if it exists, else beside the script: a failed io.open is the fallback. The name carries the
-- process id, since two emulators reloading in the same second would otherwise interleave one file.
local logfile
do
	local okPid, pid = pcall(function()
		luanet.load_assembly("System")
		return luanet.import_type("System.Diagnostics.Process").GetCurrentProcess().Id
	end)
	-- Without luanet, any discriminator beats a shared, silently corrupted file.
	local tag = (okPid and pid) or BRIDGE_PORT_OVERRIDE
		or math.floor((os.clock() % 1) * 100000)
	local name = string.format("meshghost_crystal_%s_%s.log", os.date("%Y%m%d_%H%M%S"), tostring(tag))
	logfile = io.open(SCRIPT_DIR .. "/logs/" .. name, "w") or io.open(SCRIPT_DIR .. "/" .. name, "w")
	-- Buffered: a flush is a synchronous disk write on the emulator's own thread.
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

-- File only and unflushed, for anything per-tick or per-second: tick()'s timer and close() flush it.
-- `log` above flushes because it is rare and an error should reach disk first.
local function logFile(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end

-- The bridge range starts at config.json's local_game_bridge port, read by hand (one fixed-shape key);
-- MESHGHOST_BRIDGE_PORT still wins. A do-block, so its locals cost none of the main chunk's 200.
do
	local candidates = {
		SCRIPT_DIR .. "/config.json",
		SCRIPT_DIR .. "/../../../config.json",
		SCRIPT_DIR .. "/../../../../config.json",
	}
	for _, path in ipairs(candidates) do
		local f = io.open(path, "r")
		if f then
			local text = f:read("*a")
			f:close()
			local port = tonumber(string.match(text or "",
				'"local_game_bridge"%s*:%s*"[^"]*:(%d+)"'))
			if port and port >= 1 and port <= 65535 and port ~= BRIDGE_BASE_PORT then
				log(string.format(
					"MeshGhost: bridge ports %d-%d, from local_game_bridge in config.json",
					port, port + BRIDGE_PORT_COUNT - 1))
				BRIDGE_BASE_PORT = port
			end
			-- First readable config wins even without the key: a later one is another install's.
			break
		end
	end
end

----------------------------------------------------------------------------
-- LuaSocket. lua54.dll is pre-loaded by full path: LoadLibrary does not search the loading DLL's
-- own directory for it.
----------------------------------------------------------------------------

local function loadSocketCore()
	if package.config:sub(1, 1) ~= "\\" then
		error("MeshGhost: only Windows is supported by the vendored LuaSocket binary so far.")
	end
	-- Beside this script (a shipped game folder), then Emerald's copy; every attempt is logged.

	local candidates = {
		SCRIPT_DIR .. "/lib/x64/",
		SCRIPT_DIR .. "/../emerald/lib/x64/",
		"adapters/emulator/pokemon/emerald/lib/x64/",
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

-- Small recursive-descent decoder for the bridge's messages. Every container loop checks for the end
-- of input: an infinite loop raises nothing for the pcall to catch, and freezes the emulator.
local function jsonDecode(s)
	local pos = 1
	-- Far above the bridge's three levels of nesting, far below the Lua stack's limit.
	local depth = 0
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
					-- Go's encoding/json escapes &, < and > as \u00XX, so ASCII is decoded; the font
					-- cannot draw anything above it. A truncated escape consumes only what is there.
					local hex = s:sub(pos + 2, pos + 5)
					local cp = #hex == 4 and hex:match("^%x%x%x%x$") and tonumber(hex, 16) or nil
					if cp and cp >= 0x20 and cp < 0x7F then
						out[#out + 1] = string.char(cp)
						pos = pos + 6
					elseif cp then
						out[#out + 1] = "?"
						pos = pos + 6
					else
						-- Not a well-formed \uXXXX: consume the backslash and the "u" only.
						out[#out + 1] = "?"
						pos = pos + 2
					end
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
		depth = depth + 1
		if depth > 64 then
			error("json: too deeply nested")
		end
		skip()
		local c = s:sub(pos, pos)
		if pos > #s then
			error("json: unexpected end of input")
		end
		if c == '"' then
			depth = depth - 1
			return parseString()
		elseif c == "{" then
			pos = pos + 1
			local obj = {}
			skip()
			if s:sub(pos, pos) == "}" then
				pos = pos + 1
				depth = depth - 1
				return obj
			end
			while true do
				skip()
				if pos > #s then
					error("json: unterminated object")
				end
				local k = parseString()
				skip()
				pos = pos + 1 -- ':'
				obj[k] = parseValue()
				skip()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "}" then
					depth = depth - 1
					return obj
				elseif d ~= "," then
					error("json: expected ',' or '}'")
				end
			end
		elseif c == "[" then
			pos = pos + 1
			local arr = {}
			skip()
			if s:sub(pos, pos) == "]" then
				pos = pos + 1
				depth = depth - 1
				return arr
			end
			while true do
				if pos > #s then
					error("json: unterminated array")
				end
				arr[#arr + 1] = parseValue()
				skip()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "]" then
					depth = depth - 1
					return arr
				elseif d ~= "," then
					error("json: expected ',' or ']'")
				end
			end
		elseif s:sub(pos, pos + 3) == "true" then
			pos = pos + 4
			depth = depth - 1
			return true
		elseif s:sub(pos, pos + 4) == "false" then
			pos = pos + 5
			depth = depth - 1
			return false
		elseif s:sub(pos, pos + 3) == "null" then
			pos = pos + 4
			depth = depth - 1
			return nil
		else
			local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if num then
				pos = pos + #num
				depth = depth - 1
				return tonumber(num)
			end
			-- Never advance silently: a container would loop forever on the same nothing.
			error("json: unexpected character")
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
	-- BizHawk's read_u8(nil) returns 0, and a nil address means unmeasured: it must not satisfy a gate.
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

-- Returns a class, a description and an ADDRESSES key. "known" is a build compiled byte-identical to
-- the ROM; "archipelago" the measured table, refused while it lacks an entry; "unknown" runs on
-- vanilla's, since refusing guarantees a fine ROM fails and a wrong guess is cleared by a map reload.
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
	-- V1.1 shares vanilla's table: its byte-identical build moves no label or ROM table we read.
	if title == "PM_CRYSTAL" and u8(0x14C, ROM_DOMAIN) == 0x01
		and u8(0x14E, ROM_DOMAIN) == 0x18 and u8(0x14F, ROM_DOMAIN) == 0xD2 then
		return "known", "vanilla Crystal V1.1", "vanilla"
	end
	-- Archipelago renames the header: unlike the checksum, the title does not change per seed.
	if title == "AP_CRYSTAL" then
		-- One table serves a V1.0 or a V1.1 base; $14C names which, for the log.
		return "archipelago", string.format("ROM title %q — Archipelago's Crystal patch on a V1.%d base",
			title, u8(0x14C, ROM_DOMAIN) or 0), "archipelago"
	end
	-- Another AP_ title is most likely a renamed Archipelago build, nearer its table than vanilla's.
	if title:sub(1, 3) == "AP_" then
		return "archipelago", string.format("UNRECOGNISED Archipelago title %q (expected \"AP_CRYSTAL\") — "
			.. "assuming Archipelago's layout; ghosts may draw wrong if this build moved its RAM", title), "archipelago"
	end
	-- Speedchoice keeps vanilla's title; its version byte and checksum identify v8.1.
	if title == "PM_CRYSTAL" and u8(0x14C, ROM_DOMAIN) == 0x06
		and u8(0x14E, ROM_DOMAIN) == 0x99 and u8(0x14F, ROM_DOMAIN) == 0xA8 then
		return "known", "Crystal Speedchoice v8.1", "speedchoice"
	end
	return "unknown", string.format("ROM title %q, checksum %02X%02X — not a build these addresses "
		.. "were derived from", title, u8(0x14E, ROM_DOMAIN) or 0, u8(0x14F, ROM_DOMAIN) or 0),
		"vanilla"
end

-- The stride of a `StepVectors` gait group at `off`, or nil: four rows, stride * duration = 16 px.
-- Skips u8()'s per-byte pcall, since it may scan 16 KB at startup.
function ENGINE.gaitAt(off)
	local s = memory.read_u8(off + 1, ROM_DOMAIN)
	local d = memory.read_u8(off + 2, ROM_DOMAIN)
	if not s or not d or s == 0 or d == 0 or s * d ~= 16 then
		return nil
	end
	local neg = (256 - s) & 0xFF
	local want = { 0, s, d, s, 0, neg, d, s, neg, 0, d, s, s, 0, d, s }
	for i = 1, 16 do
		if memory.read_u8(off + i - 1, ROM_DOMAIN) ~= want[i] then
			return nil
		end
	end
	return s
end

-- How many gaits this cartridge has, asked of its ROM: a peer on a four-gait build reports gait 3,
-- and writing a group this table lacks makes the engine read past its end as a movement vector.
-- Anchored on vanilla's 1px/16, 2px/8, 4px/4; without `base`, bank 1 is scanned. Not found is 3.
function ENGINE.gaitGroups(base)
	if not base then
		for off = 0x4000, 0x8000 - 48 do
			-- A step down's x is 0, so one read rejects most offsets before the full check.
			if memory.read_u8(off, ROM_DOMAIN) == 0 and ENGINE.gaitAt(off) == 1 then
				local n = ENGINE.gaitGroups(off)
				if n then
					return n, off
				end
			end
		end
		return nil
	end
	if ENGINE.gaitAt(base) ~= 1 or ENGINE.gaitAt(base + 16) ~= 2
		or ENGINE.gaitAt(base + 32) ~= 4 then
		return nil
	end
	local n, last = 3, 4
	while true do
		local s = ENGINE.gaitAt(base + n * 16)
		-- Strictly faster, or it is code after the table that happens to fit the shape.
		if not s or s <= last then
			return n, base
		end
		n, last = n + 1, s
	end
end

-- Is the overworld the thing on screen? A positive test, never a list of screens to avoid. wMapStatus
-- alone lets a battle through, hence the battle term; an unmeasured (nil) term answers no.
local function inPlay()
	local status, battle = u8(W_MAPSTATUS), u8(W_BATTLEMODE)
	local group, number = u8(W_MAPGROUP), u8(W_MAPNUMBER)
	local playerSprite = u8(OBJECT_STRUCTS + F_SPRITE)
	if status == nil or battle == nil or group == nil or number == nil or playerSprite == nil then
		return false -- an unmeasured address, or a read that failed: refuse rather than guess
	end
	return status == ENGINE.MAPSTATUS_HANDLE
		and battle == 0
		and not (group == 0 and number == 0)
		and playerSprite ~= 0
end

local function areaId()
	return string.format("%d/%d", u8(W_MAPGROUP) or -1, u8(W_MAPNUMBER) or -1)
end

-- Cross-map ghosts: a peer on a connected map is translated into our tile frame at ingest; anyone
-- else is hidden. A house is reached only by warp and has no connections, so needs no special case.
ENGINE.xmap = {
	-- Filled at startup; nil where the block is unmeasured, and `armed()` is the single gate.
	connAt = nil, wAt = nil, hAt = nil,
	conns = nil, connsFor = nil, ourW = 0, ourH = 0,
	-- (peer, their map, our map) triples already logged; deliberately not cleared on a map change.
	said = {},
	-- Each direction's mask bit and the offset of its connection record.
	DIRS = {
		{ name = "north", bit = 0x08, at = 1 },
		{ name = "south", bit = 0x04, at = 13 },
		{ name = "west", bit = 0x02, at = 25 },
		{ name = "east", bit = 0x01, at = 37 },
	},
}

-- A coordinate one tile past the west or north edge is stored as 255, not -1.
function ENGINE.xmap.signed8(v) return (v > 127) and (v - 256) or v end

function ENGINE.xmap.armed()
	return ENGINE.xmap.connAt ~= nil and ENGINE.xmap.wAt ~= nil and ENGINE.xmap.hAt ~= nil
end


-- Rebuilt on a map change only: the engine writes the block at map load. A direction the mask does
-- not claim still holds the previous map's record, so only flagged ones are read.
function ENGINE.xmap.build(localKey)
	-- Keep the departing map's set (only a non-empty one): seam-or-warp is asked of it, and receive()
	-- usually rebuilds this table before tick() asks.
	if ENGINE.xmap.connsFor ~= localKey and next(ENGINE.xmap.conns or {}) ~= nil then
		ENGINE.xmap.prevConns, ENGINE.xmap.prevFor = ENGINE.xmap.conns, ENGINE.xmap.connsFor
		-- Its extent too: the east/south rebase is expressed in the departing map's size.
		ENGINE.xmap.prevW, ENGINE.xmap.prevH = ENGINE.xmap.ourW, ENGINE.xmap.ourH
	end
	ENGINE.xmap.conns, ENGINE.xmap.connsFor = {}, localKey
	ENGINE.xmap.ourW = (u8(ENGINE.xmap.wAt) or 0) * 2   -- wMapWidth/wMapHeight are in blocks of 2x2 tiles
	ENGINE.xmap.ourH = (u8(ENGINE.xmap.hAt) or 0) * 2
	-- Early in a map load the size reads 0: left uncached, so a seam is not torn down as a warp.
	if ENGINE.xmap.ourW <= 0 or ENGINE.xmap.ourH <= 0 then
		ENGINE.xmap.connsFor = nil
		return
	end
	local mask = u8(ENGINE.xmap.connAt) or 0
	for _, d in ipairs(ENGINE.xmap.DIRS) do
		if (mask & d.bit) ~= 0 then
			local at = ENGINE.xmap.connAt + d.at
			local g, n = u8(at + 0) or 0, u8(at + 1) or 0
			ENGINE.xmap.conns[g .. "/" .. n] = {
				dir = d.name,
				yOff = u8(at + 8) or 0,
				xOff = u8(at + 9) or 0,
			}
		end
	end
end

-- The inverse of `translate`, for our own seam crossing: the painted tier's positions are rebased,
-- not cleared (a gap) or kept (wrong). The tile delta from `from`'s frame to `to`'s, or nil for a warp.
function ENGINE.xmap.rebaseDelta(from, to)
	local conns, ourW, ourH
	if ENGINE.xmap.connsFor == from then
		conns, ourW, ourH = ENGINE.xmap.conns, ENGINE.xmap.ourW, ENGINE.xmap.ourH
	elseif ENGINE.xmap.prevFor == from then
		conns, ourW, ourH = ENGINE.xmap.prevConns, ENGINE.xmap.prevW, ENGINE.xmap.prevH
	end
	local c = conns and conns[to]
	if not c or not ourW or ourW <= 0 then return nil end
	-- Each line is `translate` solved for the other side: whatever it subtracts, this adds.
	if c.dir == "west" then
		return c.xOff + 1, ENGINE.xmap.signed8(c.yOff)
	elseif c.dir == "east" then
		return -ourW, ENGINE.xmap.signed8(c.yOff)
	elseif c.dir == "north" then
		return ENGINE.xmap.signed8(c.xOff), c.yOff + 1
	end
	return ENGINE.xmap.signed8(c.xOff), -ourH
end

-- Tile fields move by the delta, map-pixel fields by 16x it; a missed field is a ghost tiles off.
function ENGINE.xmap.rebaseEntry(o, dx, dy)
	if type(o) ~= "table" then return end
	for _, k in ipairs({ "x", "lastX" }) do
		if type(o[k]) == "number" then o[k] = o[k] + dx end
	end
	for _, k in ipairs({ "y", "lastY" }) do
		if type(o[k]) == "number" then o[k] = o[k] + dy end
	end
	-- paintedX/Y are screen positions and stay: the screen is continuous across a seam.
	if type(o.modelX) == "number" then o.modelX = o.modelX + dx * 16 end
	if type(o.modelY) == "number" then o.modelY = o.modelY + dy * 16 end
end

-- A peer on a connected map in our tile frame, or nil. The cross-axis field is a signed shift; the
-- along-axis one is the landing tile (0 from east or south, extent - 1 from west or north).
function ENGINE.xmap.translate(srcArea, sx, sy)
	local c = ENGINE.xmap.conns and ENGINE.xmap.conns[srcArea]
	if not c then return nil end
	if c.dir == "west" then
		return sx - (c.xOff + 1), sy - ENGINE.xmap.signed8(c.yOff)
	elseif c.dir == "east" then
		return sx + ENGINE.xmap.ourW, sy - ENGINE.xmap.signed8(c.yOff)
	elseif c.dir == "north" then
		return sx - ENGINE.xmap.signed8(c.xOff), sy - (c.yOff + 1)
	end
	return sx - ENGINE.xmap.signed8(c.xOff), sy + ENGINE.xmap.ourH
end

----------------------------------------------------------------------------
-- get_local_state
----------------------------------------------------------------------------

local DIR_NAMES = { [0] = "down", [4] = "up", [8] = "left", [12] = "right" }

-- One letter per dir index (the facing byte / 4), derived from DIR_NAMES so a hand-written order
-- cannot swap left and right. A string key never collides with the numeric facing keys.
DIR_NAMES.letter = {}
for i = 0, 3 do
	DIR_NAMES.letter[i] = (DIR_NAMES[i * 4] or "?"):sub(1, 1)
end
-- A label is data: checked once at load.
assert(table.concat(DIR_NAMES.letter, "", 0, 3) == "dulr",
	"DIR_NAMES.letter disagrees with DIR_NAMES -- a direction table changed without its labels")

-- Pixels per tick and ticks per tile by gait group (OBJECT_WALKING & $0F, four directions a group).
-- Group 3 exists only on a patched cartridge; ENGINE.gait() decides what this one may walk at.
local GAIT_PX = { [0] = 1, [1] = 2, [2] = 4, [3] = 8 }
local GAIT_TICKS = { [0] = 16, [1] = 8, [2] = 4, [3] = 2 }

-- The gait this cartridge may be told to walk at, clamped to its own table; a faster peer is kept off
-- the spawned tier anyway (`paceable`). It must stay below GAIT_PX: above it, the name is a nil global.
function ENGINE.gait(g)
	if not GAIT_PX[g] then
		return 1
	end
	local max = (ENGINE.gaits or 3) - 1
	return g > max and max or g
end

-- HRAM always reads, so a wrong camera address never trips the fallback: a minute of walking with at
-- most two values per axis demotes the pair to the BG map offset, a rougher clock.
ENGINE.camSeen = {}
function ENGINE.camCheck(hcx, hcy)
	if ENGINE.camDead or ENGINE.camOk then
		return
	end
	-- Mid-step only: a camera holds still while the player stands, as a dead byte does.
	if (u8(OBJECT_STRUCTS + F_WALKING) or STANDING) == STANDING then
		return
	end
	local n = (ENGINE.camWalked or 0) + 1
	ENGINE.camWalked = n
	local s = ENGINE.camSeen
	if hcx then s["x" .. hcx] = true end
	if hcy then s["y" .. hcy] = true end
	local nx, ny = 0, 0
	for k in pairs(s) do
		if k:sub(1, 1) == "x" then nx = nx + 1 else ny = ny + 1 end
	end
	-- Three distinct values on either axis is a scrolling register; stop checking for good.
	if nx > 2 or ny > 2 then
		ENGINE.camOk = true
		return
	end
	if n >= 3600 then -- a minute of walking, not of wall-clock
		ENGINE.camDead = true
		log(string.format("MeshGhost: $%04X/$%04X do not behave like the camera on this ROM -- "
			.. "%d distinct X and %d distinct Y across %d frames of the player actually walking. "
			.. "Falling back to the BG map offset, which is measured on this build but is a "
			.. "per-frame delta rather than an absolute scroll, so a painted peer will be rougher "
			.. "than it should be. MEASURE the camera pair on this build "
			.. "(probes/ap_hram_scroll_probe.lua) and put it in this adapter's address table.",
			ENGINE.scxAddr or 0, ENGINE.scyAddr or 0, nx, ny, n))
	end
end

-- Which gait an object is walking at, or nil while standing (the byte then reads $FF).
local function stepGait(base)
	local w = u8(base + F_WALKING) or STANDING
	if w == STANDING then
		return nil
	end
	local group = (w & 0x0F) // 4
	if not GAIT_PX[group] then
		return nil
	end
	return group
end

-- Held across standing frames, so a receiver has it on the frame a peer starts moving.
local lastGait = 1

-- The gait to send: this object's own if it is mid-step, otherwise the last one it was seen at.
local function rememberGait(base)
	local group = stepGait(base)
	if group then
		lastGait = group
	end
	return lastGait
end

-- Pixels travelled into the current step, 0-16, at whatever gait the object is walking.
local function stepProgress(base)
	local group = stepGait(base)
	if not group then
		return 0
	end
	local dur = u8(base + F_STEP_DURATION) or 0
	local px = (GAIT_TICKS[group] - dur) * GAIT_PX[group]
	if px < 0 then px = 0 end
	if px > 16 then px = 16 end
	return px
end

local function getLocalState()
	if not inPlay() then
		return nil -- a menu, a battle, a warp: nothing meaningful to send
	end
	-- Dev: pins what is sent, area included, to the first state, so the loopback ghost can be walked
	-- into. A bare global: the tables it could live on are locals declared below this function.
	if MESHGHOST_CRYSTAL_FREEZE_STATE and MESHGHOST_CRYSTAL_FROZEN then
		return MESHGHOST_CRYSTAL_FROZEN
	end
	local base = OBJECT_STRUCTS
	local facing = u8(base + F_DIRECTION) or 0
	local artH, artI, artD = ENGINE.wireArtChunk(u8(base + F_SPRITE) or 0)
	return {
		area_id = areaId(),
		-- The tile, then the map-pixel position: the core interpolates every component, and whole
		-- tiles alone interpolate to a staircase.
		position = (function()
			local mx, my = u8(base + F_MAP_X) or 0, u8(base + F_MAP_Y) or 0
			local px, py = mx * 16, my * 16
			if (u8(base + F_WALKING) or STANDING) ~= STANDING then
				-- MAP_X/Y already name the step's destination, `16 - prog` pixels ahead.
				local back = stepProgress(base) - 16
				local d = (facing // 4) & 3
				if d == 0 then py = py + back
				elseif d == 1 then py = py - back
				elseif d == 2 then px = px - back
				else px = px + back end
			end
			return { mx, my, px, py }
		end)(),
		orientation = DIR_NAMES[facing] or "down",
		anim = ((u8(base + F_WALKING) or STANDING) ~= STANDING) and "walk" or "idle",
		-- extras, opaque to the core and never interpolated:
		--   act   OBJECT_ACTION, which picks the animation rule, so the game plays the peer's animation.
		--   prog  pixels into the current step, 0-16: the painted tier's sub-tile position.
		--   face  OBJECT_FACING; its stride bits say which foot a stepping frame is on.
		--   gait  the gait group, so a ghost steps at the peer's pace.
		--   yoff  OBJECT_SPRITE_Y_OFFSET, signed: every vertical move made without changing tile.
		--   entry how the player last entered the map (MAPSETUP_*), for 4s; $FC is a fly.
		--   jump  true while hopping a ledge: a bool, since a receiver writes its own NPC jump, never
		--         the player's step type 9, which drives the camera.
		extras = { sprite = u8(base + F_SPRITE) or 0,
			-- OBJECT_PALETTE: the game colours the player by gender and the surf blob follows it.
			pal = u8(base + F_PALETTE) or 0,
			-- That slot's clothing colour (word 2 of 4, BGR555), since a build may recolour a slot.
			clo = ENGINE.devClothing() or ENGINE.clothing(u8(base + F_PALETTE) or 0),
			-- This sprite's own row signature: a receiver wears the id only if its row matches.
			gfx = ENGINE.spriteSig(u8(base + F_SPRITE) or 0),
			act = u8(base + F_ACTION) or 0,
			prog = stepProgress(base), face = u8(base + F_FACING) or 0,
			gait = rememberGait(base), yoff = u8(base + 0x1A) or 0,
			jump = ((u8(base + F_STEP_TYPE) or 0) == 9) or nil,
			emote = ENGINE.playerEmote(),
			entry = (ENGINE.entryAt and emu.framecount() - ENGINE.entryAt < 240)
				and ENGINE.entry or nil,
			-- The species that carried this player, in the same window as `entry`.
			fly = (ENGINE.entry == 0xFC and ENGINE.entryAt
				and emu.framecount() - ENGINE.entryAt < 240) and ENGINE.flySpecies or nil,
			-- The run sprite's art for a cartridge that lacks it (ENGINE.wireArtChunk).
			arth = artH, arti = artI, artd = artD },
	}
end

-- Out of play (a battle, a menu, a warp) the last in-play state is re-sent, idle and without transient
-- extras, so peers see a standing ghost rather than age it out. Also captures the freeze flag's sample.
local getLocalStateLive = getLocalState
function getLocalState()
	local st = getLocalStateLive()
	if st == nil then
		return MESHGHOST_CRYSTAL_HELD
	end
	do
		local ex = {}
		for k, v in pairs(st.extras or {}) do ex[k] = v end
		ex.entry, ex.fly, ex.jump, ex.arti, ex.artd = nil, nil, nil, nil, nil
		-- Receivers draw the face byte verbatim, so the held copy rests on the standing stride.
		if type(ex.face) == "number" and ex.face < 0x10 and (ex.face & 1) == 1 then
			ex.face = ex.face - 1
		end
		MESHGHOST_CRYSTAL_HELD = { area_id = st.area_id, position = st.position,
			orientation = st.orientation, anim = "idle", extras = ex }
	end
	if MESHGHOST_CRYSTAL_FREEZE_STATE and st and not MESHGHOST_CRYSTAL_FROZEN then
		MESHGHOST_CRYSTAL_FROZEN = st
		logFile("FREEZE: peers pinned to " .. tostring(st.position[1]) .. ","
			.. tostring(st.position[2]) .. " -- both ghosts will stand still while you walk")
	end
	return st
end

----------------------------------------------------------------------------
-- Ghosts: spawn, move, despawn (the spawned tier)
----------------------------------------------------------------------------

local ghosts = {} -- player_id -> { mo, st, mo_base, st_base, area }

-- Peers painted by the drawn tier: by default every peer, and past the game's limits the rest.
local overflow = {} -- player_id -> { x, y, sprite }

-- Per peer, for the collision policy: when it last changed tile, and until when it is passable.
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

-- Top down, against the engine's bottom up: the hardware keeps the first ten sprites on a scanline
-- in OAM order, which follows slot order, so when it must drop someone it drops a ghost.
local function freeMapObject()
	for i = NUM_MAP_OBJECTS - 1, 1, -1 do
		if u8(MAP_OBJECTS + i * MAPOBJECT_LENGTH + M_SPRITE) == 0 then
			return i
		end
	end
end

-- Structs ghosts never take: a ghost carries WONT_DELETE and holds its struct for good, while the
-- engine hands one to each character coming into range. A missing NPC breaks the player's own game.
local RESERVED_STRUCTS_FOR_THE_GAME = 3

-- 40 sprite entries at 4 per character: past ten characters the hardware drops pieces, so the
-- spawned tier stops there and the rest are painted.
local HARDWARE_CHARACTER_LIMIT = 10

-- Beyond this a ghost gives its slots back: a little past the 10x9 window, so nobody pops in.
local GHOST_RANGE_TILES = 8

-- A spawned ghost blocks its tile, so one that should not block is painted. A peer that has not
-- changed tile (turning is not activity) stops blocking; to chase a tier-handover artefact, lower it.
local IDLE_FRAMES_BEFORE_PASSABLE = 3600 -- one minute
-- A player pressing into a ghost gets past: every doorway clears without knowing where it is.
local PUSH_FRAMES_BEFORE_PASSABLE = 30 -- half a second of shoving
local PASSABLE_HOLD_FRAMES = 180 -- and it stays passable for a few seconds afterwards

-- Pixels into the peer's step before the spawned ghost starts one: a lerped tile index crosses at a
-- moment that drifts by the sample interval, the pixels do not. 0 reverts; judge it at shipped interp.
local STEP_TRIGGER_PROG = 4

-- hJoypadDown and its four direction bits, on one table for the 200-local ceiling.
local JOY = { addr = 0xFFA4, right = 0x01, left = 0x02, up = 0x04, down = 0x08 }

-- Per-frame policy state, read once by beginPolicyFrame() rather than once per peer.
local frameState = { px = 0, py = 0, standing = true, wantX = 0, wantY = 0 }

local function beginPolicyFrame()
	policyFrames = policyFrames + 1 -- once per frame: per peer divides the idle timeout by the peer count
	local px, py = u8(OBJECT_STRUCTS + F_MAP_X) or 0, u8(OBJECT_STRUCTS + F_MAP_Y) or 0
	frameState.px, frameState.py = px, py
	frameState.standing = (u8(OBJECT_STRUCTS + F_WALKING) or STANDING) == STANDING
	frameState.wantX, frameState.wantY = px, py
	if frameState.standing then
		local joy = memory.read_u8(JOY.addr, "System Bus") or 0
		if (joy & JOY.right) ~= 0 then frameState.wantX = px + 1
		elseif (joy & JOY.left) ~= 0 then frameState.wantX = px - 1
		elseif (joy & JOY.down) ~= 0 then frameState.wantY = py + 1
		elseif (joy & JOY.up) ~= 0 then frameState.wantY = py - 1 end
	end
end

-- OBJECT_ACTION values that mean standing doing nothing: 0 (uninitialised), STAND and STEP.
local ACTIONS = {}
ACTIONS.idle = { [0] = true, [1] = true, [2] = true }

-- Should this peer be solid right now? False when idle or shoved into; the caller then paints it.
local function shouldBlock(id, x, y, act)
	-- Dev: nothing blocks, so motion can be judged without a walking ghost bumping the player. Since
	-- not blocking means painted, the peer then appears as a drawn ghost.
	if MESHGHOST_CRYSTAL_GHOSTS_PASSABLE then
		return false
	end
	-- The room's policy outranks everything below; nil (an older core) keeps ghosts solid.
	if ENGINE.ghostCollisionAllowed == false then
		return false
	end
	-- Dev: a frozen peer stays solid, or the idle and shove rules would end a hitbox test.
	if MESHGHOST_CRYSTAL_FREEZE_STATE then
		return true
	end
	local a = activity[id]
	if not a then
		a = { x = x, y = y, movedAt = policyFrames, passableUntil = 0 }
		activity[id] = a
	end
	if a.x ~= x or a.y ~= y then
		-- The tile it is stepping out of, so the shove rule treats a ghost mid-step as two tiles.
		a.lastX, a.lastY = a.x, a.y
		a.x, a.y, a.movedAt = x, y, policyFrames
	end
	-- A peer playing an animation (fishing) is active, even standing on one tile.
	if act ~= nil and not ACTIONS.idle[act] then
		a.movedAt = policyFrames
	end

	-- Is the player holding the d-pad into this peer's tile, or the tile it is leaving, while
	-- standing? Facing alone is not pressing. The old tile counts only for a step's ~16 frames.
	local fs = frameState
	local into = (fs.wantX == x and fs.wantY == y)
		or (a.lastX ~= nil and policyFrames - a.movedAt <= 20
			and fs.wantX == a.lastX and fs.wantY == a.lastY)
	if fs.standing and (fs.wantX ~= fs.px or fs.wantY ~= fs.py) and into then
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

-- The game's characters near the player, counted before any ghost: by map object, since a struct
-- appears only once its character is already in range.
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
	-- Never past what the hardware draws without flicker, nor into a slot the game's cast needs.
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
		if sprite ~= 0 and sprite ~= playerSprite and id and id ~= ENGINE.UNASSIGNED
			and id < NUM_OBJECT_STRUCTS then
			return i, id
		end
	end
end

-- The VRAM tile sprite `id` is loaded at on this map, or nil: an id is not a picture, and what is
-- resident is decided per map. The caller then falls back to the local player's sprite.
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

-- Probe flag: one sprite id for every peer, to test wearing a sprite the local player is not.
local FORCE_PEER_SPRITE = tonumber(MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE
	or os.getenv("MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE") or "")
if FORCE_PEER_SPRITE then
	-- Said every startup: a global survives a dev-loader reload, which swaps scripts, not Lua state.
	log(string.format("PROBE FLAG IN USE: every peer is forced to sprite %d "
		.. "(MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE). Ghosts will NOT look like their peers.",
		FORCE_PEER_SPRITE))
end

if COMPARE_TIERS then
	log("PROBE FLAG IN USE: MESHGHOST_COMPARE_TIERS -- the loopback ghost is rendered TWICE, "
		.. "spawned 2 tiles right and painted 2 tiles left. Two ghosts is the flag, not a bug.")
end
if COMPARE.spawnTier then
	log("MeshGhost: spawned tier ON (" .. (COMPARE_TIERS and "compare mode" or "MESHGHOST_CRYSTAL_SPAWN_TIER")
		.. ") -- a peer that can be a real object is one; the shipped default is drawn only.")
else
	log("MeshGhost: drawn tier only (the shipped default since 2026-09-02); "
		.. "MESHGHOST_CRYSTAL_SPAWN_TIER=1 re-enables spawned ghosts.")
end

-- Give a ghost the peer's own sprite when its tiles are resident, otherwise leave it wearing the
-- local player's. Returns true when the peer's own was applied.
local function applyPeerSprite(g, id)
	-- nil when renderRemote has just found the slot back in the game's hands, as after a map load.
	if g == nil then
		return false
	end
	id = FORCE_PEER_SPRITE or id
	local tile = residentSpriteTile(id)
	if not tile then
		return false
	end
	if u8(g.st_base + F_SPRITE) == id and u8(g.st_base + F_SPRITE_TILE) == tile then
		return true -- already wearing it; writing every frame would fight nothing but cost reads
	end
	-- Cross-links checked before the write: `g.sprite = id` updates what stillOurs() compares, so no
	-- later check can catch a write onto the game's NPC. Logged once, so its use can be judged.
	if u8(g.mo_base + M_STRUCT_ID) ~= g.st or u8(g.st_base + F_MAP_OBJECT_INDEX) ~= g.mo then
		if not meshghostSpriteGuardFired then
			meshghostSpriteGuardFired = true
			log(string.format("MeshGhost: REFUSED a sprite write onto slot mo=%d/st=%d -- its "
				.. "cross-links say it is the game's object now, not our ghost's. If you are "
				.. "seeing an NPC wearing the wrong sprite, this is the cause.", g.mo, g.st))
		end
		return false
	end
	w8(g.st_base + F_SPRITE, id)
	w8(g.st_base + F_SPRITE_TILE, tile)
	w8(g.mo_base + M_SPRITE, id)
	g.sprite = id -- keep stillOurs()'s expectation in step with what the ghost now wears
	return true
end

-- screenCoords() is exact only on a tile boundary: mid-scroll the window origin has moved a whole tile
-- while the pixel offset still holds the rest. A spawn waits rather than land off its tile for good.
local function cameraSettled()
	return (u8(W_BGMAPOFFSETX) or 0) % 16 == 0 and (u8(W_BGMAPOFFSETY) or 0) % 16 == 0
end

-- ---------------------------------------------------------------------------
-- The drawn tier: peers painted over the emulator's output
-- ---------------------------------------------------------------------------
--
-- The shipped default, and the overflow when the spawned tier is on. No engine limit applies after the
-- PPU, nor its animation, collision or occlusion. Tiles come from VRAM when resident, else the cartridge.
local DRAW_OVERFLOW = (MESHGHOST_CRYSTAL_DRAW_OVERFLOW or os.getenv("MESHGHOST_CRYSTAL_DRAW_OVERFLOW")) ~= "0"

-- BGR555 to 8 bits a channel; the <<3 | >>2 keeps white at 0xFF rather than a washed-out 0xF8.
function ENGINE.bgr555(c)
	local r = ((c & 0x1F) << 3) | ((c & 0x1F) >> 2)
	local g = (((c >> 5) & 0x1F) << 3) | (((c >> 5) & 0x1F) >> 2)
	local b = (((c >> 10) & 0x1F) << 3) | (((c >> 10) & 0x1F) >> 2)
	return 0xFF000000 | (r << 16) | (g << 8) | b
end

-- Colours come from wOBPals1, the object palettes the hardware is using. A peer's `clo` replaces colour 2 only, the
-- clothing a build may let a player pick, which the slot index alone would paint in this cartridge's colour.
local function paletteColors(palIndex, clothing)
	local base = W_OBPALS + (palIndex & 7) * 8
	local colors = { [0] = nil } -- colour 0 of an object palette is transparent
	for i = 1, 3 do
		local lo = u8(base + i * 2) or 0
		local hi = u8(base + i * 2 + 1) or 0
		colors[i] = ENGINE.bgr555(lo | (hi << 8))
	end
	if clothing then colors[2] = ENGINE.bgr555(clothing & 0x7FFF) end
	return colors
end

-- Decoded tiles are cached and drawn as horizontal runs, not pixels. Characters' tiles are in VRAM bank 1, at 0x2000.
local VRAM_BANK1 = 0x2000
local tileCache = {}

-- wUsedSprites changes when the graphics behind an index do, a surf mount's in-place rewrite included.
local tileCacheSig = nil
local function invalidateTileCache()
	local sig = (u8(W_MAPGROUP) or 0) * 256 + (u8(W_MAPNUMBER) or 0)
	if W_USEDSPRITES then
		for i = 0, USED_SPRITES_CAPACITY - 1 do
			local id = u8(W_USEDSPRITES + i * 2)
			if not id or id == 0 then
				break
			end
			sig = (sig * 31 + id * 256 + (u8(W_USEDSPRITES + i * 2 + 1) or 0)) % 0x3FFFFFFF
		end
	end
	if sig == tileCacheSig then
		return
	end
	tileCacheSig = sig
	local kept = {}
	for k, v in pairs(tileCache) do
		-- "rom:" and "art:" cannot have moved; content-keyed "vram:" entries are dropped only so they do not pile up.
		if type(k) == "string" and (k:sub(1, 4) == "rom:" or k:sub(1, 4) == "art:") then
			kept[k] = v
		end
	end
	tileCache = kept
end

-- Colour 2 of one of our palette slots as palette RAM holds it, so a patch's or a player's chosen colour is sent.
function ENGINE.clothing(palIndex)
	local at = W_OBPALS + ((palIndex or 0) & 7) * 8 + 4
	return (u8(at) or 0) | ((u8(at + 1) or 0) << 8)
end

-- MESHGHOST_CRYSTAL_DEV_CLOTHING ("RRGGBB") replaces `clo` on the wire only; nothing in the game changes.
function ENGINE.devClothing()
	local v = MESHGHOST_CRYSTAL_DEV_CLOTHING or os.getenv("MESHGHOST_CRYSTAL_DEV_CLOTHING")
	if not v or v == "" then return nil end
	if v ~= ENGINE.devClothingRaw then
		ENGINE.devClothingRaw = v
		local n = tonumber((tostring(v):gsub("^#", "")), 16)
		if n then
			local r, g, b = (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF
			ENGINE.devClothingWord = (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10)
			logFile(string.format("PROBE FLAG IN USE: MESHGHOST_CRYSTAL_DEV_CLOTHING=%s -- the clothing colour "
				.. "on the wire is %04X, not this game's own; nothing local changes", tostring(v), ENGINE.devClothingWord))
		else
			ENGINE.devClothingWord = nil
			logFile(string.format("MESHGHOST_CRYSTAL_DEV_CLOTHING=%s is not RRGGBB -- ignored", tostring(v)))
		end
	end
	return ENGINE.devClothingWord
end

-- Cartridge sprite graphics, for a peer whose sprite this map never loaded; nil on an unmeasured build.
local OVERWORLD_SPRITES_ROM, EMOTES_ROM
local SPRITEDATA_STRIDE = 6

local function romByte(offset)
	return memory.read_u8(offset, ROM_DOMAIN) or 0
end

-- The emote over the player's head as an `Emotes` index, or nil: nothing in WRAM names it, so its tiles are matched.
function ENGINE.playerEmote()
	if not EMOTES_ROM then
		return nil -- no address for this build; a peer simply gets no emote
	end
	local px, py = u8(OBJECT_STRUCTS + F_MAP_X), u8(OBJECT_STRUCTS + F_MAP_Y)
	local found = false
	for i = 1, NUM_OBJECT_STRUCTS - 1 do
		local b = OBJECT_STRUCTS + i * OBJECT_LENGTH
		-- EMOTE_OBJECT marks any decoration, the jump shadow included; action 8 is what tells an emote apart.
		if (u8(b + F_SPRITE) or 0) ~= 0
			and ((u8(b + F_FLAGS1) or 0) & 0x80) ~= 0 -- EMOTE_OBJECT: decoration, not necessarily "!"
			and (u8(b + F_ACTION) or 0) == 8 -- OBJECT_ACTION_EMOTE, the half that means emote
			and u8(b + F_MAP_X) == px and u8(b + F_MAP_Y) == py then
			found = true
			break
		end
	end
	if not found then
		return nil
	end
	-- The four-tile emotes all load at $f8 in VRAM bank 1, so its first tile names the set; memoised on those 16 bytes.
	local key = {}
	for i = 0, 15 do
		-- Not readVram: it is declared below this function, so it would be a nil global here.
		key[#key + 1] = string.char(memory.read_u8(VRAM_BANK1 + 0xF8 * 16 + i, "VRAM") or 0)
	end
	key = table.concat(key)
	if ENGINE.emoteIds[key] ~= nil then
		local v = ENGINE.emoteIds[key]
		return (v >= 0) and v or nil
	end
	local answer = -1
	for idx = 0, 11 do
		local e = EMOTES_ROM + idx * 6
		-- dw graphics, db length, db bank, dw vtile; only one that loads at $f8 can be what is there.
		if (romByte(e + 4) | (romByte(e + 5) << 8)) == 0x8F80 then
			local gfx = romByte(e + 3) * 0x4000 + ((romByte(e) | (romByte(e + 1) << 8)) - 0x4000)
			local same = true
			for i = 0, 15 do
				if romByte(gfx + i) ~= string.byte(key, i + 1) then
					same = false
					break
				end
			end
			if same then
				answer = idx
				break
			end
		end
	end
	ENGINE.emoteIds[key] = answer
	return (answer >= 0) and answer or nil
end

-- A sprite's graphics as ROM offset, size and the game's own palette, or nil for an id the table does not cover.
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

-- key: a VRAM tile index, or a "vram:<bytes>", "rom:<offset>" or "art:<hash>:<tile>" string.
local function decodeTileAt(key, readByte, base)
	local cached = tileCache[key]
	if cached then
		return cached
	end
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

-- Keyed by the tile's 16 bytes, not its index, which can race the pixels behind it; the index is the fallback.
local function decodeTile(tileIndex)
	local base = VRAM_BANK1 + tileIndex * 16
	local ok, b = pcall(memory.read_bytes_as_array, base, 16, "VRAM")
	if not ok or type(b) ~= "table" or #b ~= 16 then
		return decodeTileAt(tileIndex, readVram, base)
	end
	return decodeTileAt("vram:" .. string.char(table.unpack(b)),
		function(a) return b[a - base + 1] or 0 end, base)
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
						-- Paint counter: a tier that stops painting also gets faster.
						MG_CRY_SPANS = (MG_CRY_SPANS or 0) + 1
					end
				end
			end
		end
	end
end

-- Tiles and flips per facing, learned by watching the engine draw the local player: facing (0..3) -> { stand = <frame>,
-- step = { [stride] = <frame> } }, a frame being the four OAM parts. Bit 0x80 of an offset marks a stepping view.
local facingFrames = {}

local function readPlayerOamFrame()
	local frame = {}
	-- A player whose facing is STANDING is not drawn (Fly holds $FF), so OAM 0-3 then belong to someone else.
	if (u8(OBJECT_STRUCTS + F_FACING) or 0) == STANDING then
		return nil
	end
	local playerTileBase = u8(OBJECT_STRUCTS + F_SPRITE_TILE) or 0
	for i = 0, 3 do
		local y = memory.read_u8(i * 4, "OAM") or 0
		if y == 0 or y >= 160 then
			return nil -- the player is not on screen this frame; learn nothing
		end
		-- OAM 0-3 are not always the player's (a spawned ghost can hold them), so an offset from the player's tile
		-- base must land in its own art: (offset & 0x7F) < 12, the mask folding stepping views (0x80 up) onto standing.
		local tile = memory.read_u8(i * 4 + 2, "OAM") or 0
		local offset = (tile - playerTileBase) & 0xFF
		-- 12 and 0x7F as literals: the file is at Lua's 200-local ceiling.
		if (offset & 0x7F) >= 12 then
			return nil
		end
		frame[i + 1] = {
			-- An offset within the sprite's graphics, not a VRAM tile, so it also applies to cartridge art.
			offset = offset,
			tile = memory.read_u8(i * 4 + 2, "OAM") or 0,
			xflip = ((memory.read_u8(i * 4 + 3, "OAM") or 0) & 0x20) ~= 0,
			-- Raw screen position for now; normalised against the frame's own top-left below.
			dx = memory.read_u8(i * 4 + 1, "OAM") or 0,
			dy = y,
		}
	end

	-- Measured from the frame's top-left, not entry 0: a flipped sprite emits its entries mirrored.
	local minX, minY = 255, 255
	for i = 1, 4 do
		if frame[i].dx < minX then minX = frame[i].dx end
		if frame[i].dy < minY then minY = frame[i].dy end
	end
	for i = 1, 4 do
		frame[i].dx = frame[i].dx - minX
		frame[i].dy = frame[i].dy - minY
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

-- OAM holds last frame's drawing, so art is learned against the previous frame's direction, only when contiguous.
-- This and the guards in readPlayerOamFrame are needed together: either alone lets a wrong view in.
local function learnFacingFromPlayer()
	local dirNow = ((u8(OBJECT_STRUCTS + F_DIRECTION) or 0) // 4) & 3
	local prev = facingFrames.prev
	-- emu.framecount(), not drawFrames, which is declared below and would be a nil global here.
	local nowFrame = emu.framecount()
	-- OBJECT_FACING's low two bits are the engine's stride (which foot), paired with the art like the direction.
	facingFrames.prev = { dir = dirNow, at = nowFrame, face = u8(OBJECT_STRUCTS + F_FACING) or 0 }

	local frame = readPlayerOamFrame()
	if not frame then
		return
	end
	if not prev or prev.at ~= nowFrame - 1 then
		return -- not a contiguous pair: the art and the direction would describe different moments
	end
	local facing = prev.dir
	local entry = facingFrames[facing]
	if not entry then
		entry = { step = {} }
		facingFrames[facing] = entry
	end
	-- A facing's tile group is fixed by the format (down 0-3, up 4-7, side 8-11), so it is checked, never learned, on
	-- all four parts and before `stand` is stored: one foreign part garbles the sprite.
	local group = (frame[1].offset & 0x7F) // 4
	for gi = 2, 4 do
		if ((frame[gi].offset & 0x7F) // 4) ~= group then
			return
		end
	end
	if group ~= ((facing == 0) and 0 or (facing == 1) and 1 or 2) then
		return
	end
	-- The flip separates left from right; up and down mirror to walk, so both flips are theirs.
	if group == 2 and frame[1].xflip ~= (facing == 3) then
		return
	end
	-- Filed by the art, not by whether the player was mid-step: bit 0x80 clear is a standing view, set a stepping one.
	if (frame[1].offset & 0x80) == 0 then
		-- Traced here too, as this returns above the trace below; edge-triggered, since idling rewrites it.
		if MESHGHOST_CRYSTAL_FACING_TRACE then
			local k = string.format("%d:%d@%d,%d|%d@%d,%d|%d@%d,%d|%d@%d,%d", facing,
				frame[1].offset, frame[1].dx, frame[1].dy, frame[2].offset, frame[2].dx, frame[2].dy,
				frame[3].offset, frame[3].dx, frame[3].dy, frame[4].offset, frame[4].dx, frame[4].dy)
			facingFrames.standLast = facingFrames.standLast or {}
			if facingFrames.standLast[facing] ~= k then
				facingFrames.standLast[facing] = k
				-- emu.framecount(), not drawFrames, which is declared below and would be a nil global here.
				logFile(string.format("facing-trace: f=%d STAND facing=%d [%s]",
					emu.framecount(), facing, k))
			end
		end
		entry.stand = frame
		return
	end
	-- A stepping view, keyed by the engine's stride so a later sample corrects an earlier one.
	local stride = (prev.face or 0) & 3
	if entry.step[stride] and sameFrame(entry.step[stride], frame) then
		return
	end
	entry.step[stride] = frame
	-- MESHGHOST_CRYSTAL_FACING_TRACE: logs a slot when its art changes; the cache is never cleared.
	if MESHGHOST_CRYSTAL_FACING_TRACE then
		local parts = {}
		for i = 1, 4 do
			parts[i] = string.format("%d%s@%d,%d", frame[i].offset,
				frame[i].xflip and "F" or "", frame[i].dx, frame[i].dy)
		end
		-- Flags any frame in the wrong group or flip for its facing, so the log settles it.
		logFile(string.format(
			"facing-trace: f=%d LEARNED facing=%d stride=%d group=%d dir=%d face=%02X [%s]%s",
			emu.framecount(), facing, stride, group, dirNow, prev.face or 0,
			table.concat(parts, " "),
			(group ~= ((facing == 0) and 0 or (facing == 1) and 1 or 2)
				or (group == 2 and frame[1].xflip ~= (facing == 3)))
				and "  *** WRONG VIEW FOR THIS FACING -- STILL BROKEN ***" or ""))
	end
end

-- A facing the local player has not walked yet: a learned arrangement pointed at this facing's tile group, mirrored
-- across the side flip, and the sprite format's own frame for any slot left.
function facingFrames.derive(facing)
	-- Keyed by direction index 0-3 (down, up, left, right), not the facing byte; 3 is right, the flipped side view.
	local GROUP = { [0] = 0, [1] = 4, [2] = 8, [3] = 8 }
	local base = GROUP[facing]
	if not base then
		return nil
	end
	-- Declared here: a bare `out = out or {...}` below would be a global that survives between calls.
	local out
	-- The format's own frame, consulted last; needed even with something learned, as an idle player leaves a
	-- stand-only entry.
	local function seedPart(i, stepping)
		local flip = (facing == 3)
		return {
			offset = (stepping and 0x80 or 0) + base + i,
			xflip = flip,
			dx = flip and (8 - ((i % 2) * 8)) or ((i % 2) * 8),
			dy = (i // 2) * 8,
		}
	end
	local function seedFrame(stepping)
		return { seedPart(0, stepping), seedPart(1, stepping),
			seedPart(2, stepping), seedPart(3, stepping) }
	end
	for _, src in ipairs({ 0, 1, 2, 3 }) do
		local e = facingFrames[src]
		local from = GROUP[src]
		if e and src ~= facing and from then
			local mirror = (src == 3) ~= (facing == 3)
			local function remap(f)
				if not f then
					return nil
				end
				local out = {}
				for i = 1, 4 do
					local p = f[i]
					if not p then
						return nil
					end
					-- Not `mirror and (not p.xflip) or p.xflip`: the and/or idiom cannot yield false, so the flip
					-- would never clear. dx below is safe written that way, since 0 is truthy in Lua.
					local xf = p.xflip and true or false
					if mirror then xf = not xf end
					out[i] = {
						offset = (p.offset & 0x80) | (base + ((p.offset & 0x7F) - from)),
						xflip = xf,
						-- Reflected across the two-tile frame, dx being measured from its top-left.
						dx = mirror and (8 - p.dx) or p.dx,
						dy = p.dy,
					}
				end
				return out
			end
			-- Fill every slot this source can, then keep looking: a stand with no steps is a peer that never animates.
			out = out or { step = {}, derived = true }
			out.stand = out.stand or remap(e.stand)
			for i = 0, 3 do
				out.step[i] = out.step[i] or remap(e.step[i])
			end
			if out.stand and out.step[0] and out.step[1] and out.step[2] and out.step[3] then
				return out
			end
		end
	end
	-- Any slot still empty gets the sprite format's own frame.
	out = out or { step = {}, derived = true }
	out.stand = out.stand or seedFrame(false)
	for i = 0, 3 do
		out.step[i] = out.step[i] or seedFrame(true)
	end
	return out
end

function facingFrames.pick(facing, walking, prog, stride)
	local entry = facing and facingFrames[facing]
	if not entry then
		-- Not cached: a derived entry is never taken for a learned one, and a real arrangement takes over once learned.
		entry = facing and facingFrames.derive(facing) or nil
	end
	if not entry then
		return nil -- no facing, or not 0..3; each caller has its own fallback
	end
	-- `walking` already carries the engine's stand/step alternation, read off the peer's face byte (facingFrames.pose).
	if walking then
		local f = entry.step[(stride or 0) & 3]
		-- A learned entry is often stand-only, so: a derived step, then any step, and only then the standing frame.
		if not f and not (entry.step[0] or entry.step[1] or entry.step[2] or entry.step[3]) then
			local d = facingFrames.derive(facing)
			if d then
				f = d.step[(stride or 0) & 3] or d.step[0]
			end
		end
		-- Any stepping view beats the standing one, which would drop the whole step; for left and right it is exact.
		for i = 0, 3 do
			if f then break end
			f = entry.step[i]
		end
		if f then
			return f
		end
	end
	return entry.stand or entry.step[0] or entry.step[1] or entry.step[2] or entry.step[3]
end

-- The pose for every animation, including those that do not move the character (bump, spin, a turn, fishing, the
-- Dig flicker): the peer's OBJECT_FACING byte, sent as `extras.face`, read as the pose itself. 0x00-0x0F is
-- direction * 4 + stride, odd strides stepping; 0x10-0x13 fishing; 0xFF drawn as nothing; anything else standing.
-- Returns facing, walking, stride, hide, rod.
function facingFrames.pose(act, face, facing, moving, stride)
	if act == nil or ACTIONS.idle[act] then
		-- The face byte is the peer's engine-paced step clock at every gait; step progress matches it only at the walk.
		if face and face < 0x10 then
			local fs = face & 3
			-- Shown verbatim, moving or not, so a turn on the spot animates.
			return facing, (fs & 1) == 1, fs, false, nil
		end
		return facing, moving, stride, false, nil
	end
	-- Action 5, the Dig/Teleport flicker, hides the character on alternate ticks; checked as the engine keys on it.
	if act == 5 or face == 0xFF then
		return facing, false, 0, true, nil
	end
	if face and face >= 0x10 and face <= 0x13 then
		-- FACING_FISH_* are in the same DOWN/UP/LEFT/RIGHT order as this adapter's dir index.
		return face - 0x10, false, 0, false, face - 0x10
	end
	if face and face < 0x10 then
		local s = face & 3
		return (face // 4) & 3, (s & 1) == 1, s, false, nil
	end
	-- 0x14 and up are scenery facings (an emote box, a shadow, boulder dust), never learned: shown standing.
	return facing, false, 0, false, nil
end

-- The fishing rod: one tile of the fishing sheet (`t`) at dx/dy from the character's top-left, per dir index.
facingFrames.ROD = {
	[0] = { dx = 0, dy = 16, t = 6 }, -- down: below the character
	[1] = { dx = 0, dy = -8, t = 6 }, -- up: above it
	[2] = { dx = -8, dy = 5, t = 7, flip = true }, -- left
	[3] = { dx = 16, dy = 5, t = 7 }, -- right
}

-- Every peer number that becomes a ROM offset and a memo key: an integer in [lo, hi], or nil. A float would read a
-- fractional address and grow a never-cleared memo per value.
function ENGINE.peerRomIndex(v, lo, hi)
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	if v ~= math.floor(v) or v < lo or v > hi then
		return nil
	end
	return math.tointeger(v)
end

-- A Fly landing draws the peer's party mon icon: MonMenuIcons then IconPointers, in bank 0x23; memoised.
facingFrames.iconRom = {}
facingFrames.iconGfx = function(species)
	species = ENGINE.peerRomIndex(species, 1, 251) -- integer and in range; see ENGINE.peerRomIndex
	if not facingFrames.iconTbl or not facingFrames.iconPtrs or not species then
		return nil
	end
	local cached = facingFrames.iconRom[species]
	if cached ~= nil then
		return (cached ~= false) and cached or nil
	end
	local icon = romByte(facingFrames.iconTbl + species - 1)
	local e = facingFrames.iconPtrs + icon * 2
	local addr = romByte(e) | (romByte(e + 1) << 8)
	local at = (addr >= 0x4000) and (facingFrames.iconBank * 0x4000 + (addr - 0x4000)) or false
	facingFrames.iconRom[species] = at
	return at or nil
end

-- The engine's Fly landing curve, relative to the ghost's landing tile rather than the screen centre.
facingFrames.FLY_FRAMES = 44
facingFrames.flyOffset = function(k)
	local amp = 88 - 2 * k
	if amp < 0 then amp = 0 end
	return math.floor(amp * math.cos(k * math.pi / 32) + 0.5), -amp
end

-- Which of the icon's two frames: each held 8 frames, the second x-flipped every other cycle (A, B, A, B-flipped).
facingFrames.flyFrame = function(k)
	local cycle = (k // 8) % 4
	return (cycle == 1 or cycle == 3) and 4 or 0, cycle == 3
end

-- The icon's 2x2 tiles, from the block's top-left rather than the engine's centre anchor.
facingFrames.ICON_BOX = {
	{ dx = 0, dy = 0, t = 0 }, { dx = 8, dy = 0, t = 1 },
	{ dx = 0, dy = 8, t = 2 }, { dx = 8, dy = 8, t = 3 },
}

-- One emote's tiles in the cartridge, memoised: VRAM $f8 holds whatever the local game last loaded there.
facingFrames.emoteGfx = function(idx)
	idx = ENGINE.peerRomIndex(idx, 0, 11) -- integer and in range; see ENGINE.peerRomIndex
	if not EMOTES_ROM or not idx then
		return nil
	end
	local cached = facingFrames.emoteRom[idx]
	if cached ~= nil then
		return (cached ~= false) and cached or nil
	end
	local e = EMOTES_ROM + idx * 6
	local addr, bank = romByte(e) | (romByte(e + 1) << 8), romByte(e + 3)
	local at = (bank ~= 0 and addr >= 0x4000) and (bank * 0x4000 + (addr - 0x4000)) or false
	facingFrames.emoteRom[idx] = at
	return at or nil
end
facingFrames.emoteRom = {}

-- An emote box's four tiles ($f8 $f9 over $fa $fb, graphics tiles 0..3); the box sits one tile above the character.
facingFrames.EMOTE_BOX = {
	{ dx = 0, dy = 0, t = 0 }, { dx = 8, dy = 0, t = 1 },
	{ dx = 0, dy = 8, t = 2 }, { dx = 8, dy = 8, t = 3 },
}

-- The fishing sheet for the peer's own sprite id, not the local gender; nil draws the peer without the fishing half.
function facingFrames.fishRom(spriteId)
	if not facingFrames.fishChris then
		return nil
	end
	if spriteId == 0x60 then -- SPRITE_KRIS
		return facingFrames.fishKris
	end
	if spriteId == 0x01 then -- SPRITE_CHRIS
		return facingFrames.fishChris
	end
	return nil
end

-- Bottom-half offsets 2,3 (down), 6,7 (up), 10,11 (side) become fishing tiles 0..5; nil for a tile not replaced.
function facingFrames.fishTile(offset)
	if offset > 11 or (offset % 4) < 2 then
		return nil
	end
	return (offset // 4) * 2 + (offset % 2)
end

-- source is { vram = <tile base> }, { rom = <gfx offset> } or { art = <wire tiles> }.
local function drawCharacter(source, sx, sy, palIndex, facing, walking, prog, stride, fishRom, clothing)
	local colors = paletteColors(palIndex or 0, clothing)
	local frame = facingFrames.pick(facing, walking, prog or 0, stride)
	local function partRows(offset)
		-- A fishing bottom half: this machine's VRAM holds the peer's walking art there, so read the cartridge.
		if fishRom then
			local ft = facingFrames.fishTile(offset)
			if ft then
				return decodeRomTile(fishRom, ft)
			end
		end
		if source.art then
			-- Wire art is the cartridge layout verbatim (ENGINE.wireArtChunk), so the ROM mapping applies.
			local t = ((offset & 0x80) ~= 0) and (12 + (offset & 0x7F)) or offset
			if t > 23 then
				return decodeTileAt("art:none", function() return 0 end, 0)
			end
			local art = source.art
			return decodeTileAt(string.format("art:%08X:%d", art.h, t),
				function(a) return art[a] or 0 end, t * 16 + 1)
		end
		if source.rom then
			-- In ROM the 12 stepping tiles follow the 12 standing ones; in VRAM they sit 0x80 above.
			return decodeRomTile(source.rom,
				((offset & 0x80) ~= 0) and (12 + (offset & 0x7F)) or offset)
		end
		return decodeTile((source.vram + offset) & 0xFF)
	end

	if frame then
		-- Drawing is not the stutter's cost: one primitive per ghost changed nothing on screen.
		for _, part in ipairs(frame) do
			drawRows(partRows(part.offset), sx + part.dx, sy + part.dy, colors, part.xflip)
		end
		return
	end
	-- No frame for that facing: the sprite's first frame, never wrong-looking, only wrong-facing.
	drawRows(partRows(0), sx, sy, colors)
	drawRows(partRows(1), sx + 8, sy, colors)
	drawRows(partRows(2), sx, sy + 8, colors)
	drawRows(partRows(3), sx + 8, sy + 8, colors)
end

-- ---------------------------------------------------------------------------
-- The hardware tier: peers drawn by the Game Boy itself, not painted over it
-- ---------------------------------------------------------------------------
-- The middle rung: a peer in wShadowOAM, drawn by the PPU in the game's live palettes. It adds almost no capacity
-- and needs resident tiles; entries go downward from the top, no lower than hUsedSpriteIndex ($ffbd).
local OAM_TIER = (MESHGHOST_CRYSTAL_OAM_OVERFLOW or os.getenv("MESHGHOST_CRYSTAL_OAM_OVERFLOW")) == "1"

local oam = {
	SHADOW = 0x400, -- wShadowOAM, 00:c400 -> flat
	ENTRIES = 40,
	next = nil, -- next entry index to write, counting down from the top
	floor = 0, -- entries below this belong to the engine this frame
	placed = 0,
	landed = nil, -- has anything we wrote ever reached the hardware?
	checked = 0,
}

-- Once a frame: where the engine's entries end, and whether sprite updates run (off, the game hides everyone).
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
	-- Downward from the last entry, so a full scanline drops a ghost rather than one of the game's characters.
	oam.floor = used // 4
	oam.next = oam.ENTRIES - 1
end

-- One peer, four entries; false when there is no room, so the caller falls through to the drawn tier.
function oam.place(sx, sy, tileBase, palIndex, facing, walking, prog, stride)
	if not oam.next or oam.next - 3 < oam.floor then
		return false
	end
	-- The painted tier's picker, so COMPARE_TIERS compares like with like; offsets are VRAM-layout already.
	local frame = facingFrames.pick(facing, walking, prog or 0, stride)
	if not frame then
		return false -- no frame for this facing; the drawn tier has a fallback, we do not
	end

	for i, part in ipairs(frame) do
		local at = oam.SHADOW + (oam.next - (i - 1)) * 4
		-- An OAM coordinate is the screen position plus 16 (Y) and 8 (X).
		w8(at, (sy + part.dy + 16) & 0xFF)
		w8(at + 1, (sx + part.dx + 8) & 0xFF)
		w8(at + 2, (tileBase + part.offset) & 0xFF)
		-- Palette in bits 0-2, VRAM bank in bit 3, X flip in bit 5. Priority stays clear: set, it would put the peer
		-- behind every non-zero background colour, the ground it stands on included.
		w8(at + 3, (palIndex & 0x07) | 0x08 | (part.xflip and 0x20 or 0))
	end
	oam.next = oam.next - 4
	oam.placed = oam.placed + 1
	return true
end

-- Did any of it reach the hardware? Read from the OAM domain, what the DMA delivered, never the shadow bytes we wrote.
function oam.verify()
	if not OAM_TIER or oam.placed == 0 or oam.landed ~= nil then
		return
	end
	oam.checked = oam.checked + 1
	if oam.checked < 120 then
		return
	end
	-- The whole entry, not just its Y: a wrong tile id or attribute byte arrives and draws nothing visible.
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

-- Screen coordinates correct mid-scroll too, which screenCoords is not: anchored on the player's object, the engine's
-- own coherent value, as screen = playerSpriteXY + (worldPx - playerWorldPx), MAP_X being the step's destination.
local function liveScreenCoords(mx, my)
	local base = OBJECT_STRUCTS -- struct 0: the player
	local psx = u8(base + F_SPRITE_X) or 0
	local psy = u8(base + F_SPRITE_Y) or 0
	local pmx = (u8(base + F_MAP_X) or 0) * 16
	local pmy = (u8(base + F_MAP_Y) or 0) * 16
	if (u8(base + F_WALKING) or STANDING) ~= STANDING then
		local back = stepProgress(base) - 16
		local d = ((u8(base + F_DIRECTION) or 0) // 4) & 3
		if d == 0 then pmy = pmy + back
		elseif d == 1 then pmy = pmy - back
		elseif d == 2 then pmx = pmx - back
		else pmx = pmx + back end
	end
	return (psx + mx * 16 - pmx) & 0xFF, (psy + my * 16 - pmy) & 0xFF
end

-- Is the object we recorded still ours? A map load or battle rebuilds the arrays, and a real NPC's slot is never ours.
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
		-- The game's again: zeroing it would delete whatever the map load put there.
		ghosts[id] = nil
		log("MeshGhost: dropped stale bookkeeping for " .. id .. " (its slot is the game's again)")
		return
	end
	-- A jump shadow tracking this ghost goes with it, or it would follow the next ghost given this struct.
	for sidx = 0, NUM_OBJECT_STRUCTS - 1 do
		local sb = OBJECT_STRUCTS + sidx * OBJECT_LENGTH
		if (u8(sb + 0x03) or 0) == 0x1B and (u8(sb + 0x20) or 0xFF) == g.st then
			for off = 0, OBJECT_LENGTH - 1 do
				w8(sb + off, 0)
			end
		end
	end
	w8(g.st_base + F_SPRITE, 0)
	for off = 0, MAPOBJECT_LENGTH - 1 do
		w8(g.mo_base + off, 0)
	end
	ghosts[id] = nil
	log("MeshGhost: despawned " .. id)
end

-- Between our steps the engine runs this: stand facing `dir`, not a donor's random walk. The struct's copy dispatches,
-- the map object's is restored after every movement.
local function setGhostStanding(stBase, moBase, dir)
	local entry = SPRITEMOVEDATA_STANDING_BY_DIR[dir] or SPRITEMOVEDATA_STANDING_BY_DIR[0]
	w8(stBase + 0x03, entry) -- OBJECT_MOVEMENT_TYPE
	w8(moBase + 0x04, entry) -- MAPOBJECT_MOVEMENT
end

local function spawnGhost(id, x, y, peerSprite)
	local srcMo, srcSt = findTemplateNpc()
	if not srcMo then
		return nil -- no template on this map; try again next frame
	end
	local mo, st = freeMapObject(), freeStruct()
	if not mo or not st then
		-- The map is full: say so once a minute and name the pool, since an invisible friend and a disconnected
		-- one look the same from the player's chair. os.time(), as bridgeFrames is declared below (a nil global here).
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

	-- The player's sprite is resident on every map, so it needs no VRAM allocation.
	w8(stBase + F_SPRITE, u8(OBJECT_STRUCTS + F_SPRITE) or 0)
	w8(stBase + F_SPRITE_TILE, u8(OBJECT_STRUCTS + F_SPRITE_TILE) or 0)
	w8(stBase + F_PALETTE, u8(OBJECT_STRUCTS + F_PALETTE) or 0)
	w8(moBase + M_SPRITE, u8(OBJECT_STRUCTS + F_SPRITE) or 0)

	local sx, sy = liveScreenCoords(x, y)
	w8(stBase + F_SPRITE_X, sx)
	w8(stBase + F_SPRITE_Y, sy)

	-- Normalise the flags inherited from the donor NPC (a still object's SLIDING and FIXED_FACING).
	local flags1 = (u8(stBase + F_FLAGS1) or 0) | ENGINE.WONT_DELETE
	flags1 = flags1 & ~0x08 -- SLIDING: suppresses the walk animation
	flags1 = flags1 & ~0x04 -- FIXED_FACING: suppresses turning
	w8(stBase + F_FLAGS1, flags1)

	-- Normalise the movement type too (see setGhostStanding); stepGhost() re-pins it per direction.
	setGhostStanding(stBase, moBase, ((u8(stBase + F_DIRECTION) or 0) // 4) & 3)

	-- Normalise what the ghost is, on its own map object only: a donor trainer's type and sight range made a ghost
	-- raise the trainer `!` and hang the game. Type 3 is a no-op event that never reads the script pointer.
	local palette = (u8(moBase + 0x08) or 0) & 0xF0 -- MAPOBJECT_PALETTE, high nibble of byte 8
	w8(moBase + 0x08, palette | 3)                  -- MAPOBJECT_TYPE = OBJECTTYPE_3 (a no-op event)
	w8(moBase + 0x09, 0)                            -- MAPOBJECT_SIGHT_RANGE: a ghost sees nobody
	w8(moBase + 0x0A, 0)                            -- MAPOBJECT_SCRIPT_POINTER, low
	w8(moBase + 0x0B, 0)                            -- ...and high; never read at type 3
	w8(moBase + 0x0C, 0xFF)                         -- MAPOBJECT_EVENT_FLAG: the "no flag" sentinel
	w8(moBase + 0x0D, 0xFF)                         -- both donors seen carried FF FF here

	ghosts[id] = { mo = mo, st = st, mo_base = moBase, st_base = stBase, area = areaId(),
		sprite = u8(stBase + F_SPRITE) }

	-- The peer's own sprite instead, when it is already loaded on this map.
	local own = applyPeerSprite(ghosts[id], peerSprite)

	-- The type read back out of the game, not the value just written, beside the donor: a 2 would name the NPC.
	local gotType = (u8(moBase + 0x08) or 0) & 0x0F
	log(string.format("MeshGhost: spawned %s at %d,%d (map object %d <-> struct %d, type %d, "
		.. "cloned from map object %d)%s", id, x, y, mo, st, gotType, srcMo,
		own and " wearing its own sprite" or ""))
	return ghosts[id]
end

-- The menu rectangle the game publishes (wMenuBorder*, tiles; a text box leaves it zero). Per build, from ADDRESSES.
local MENUBOX = { top = 0x0F82, left = 0x0F83, bottom = 0x0F84, right = 0x0F85 }

-- A menu's rectangle strobes to zero as it redraws, so a panel stays latched open for UI_LATCH_FRAMES.
local UI_LATCH_FRAMES = 20
local uiSeenAt, drawFrames = nil, 0

-- A few frames of the player's position. `age` is 0, as the model walks on live camera frames and an older reference
-- wobbles; `settle` is frames left after a world rebuild, so the painted tier does not draw over a fade-in.
local playerHistory = { size = 12, age = 0, settle = 0 }

-- Never WY: the game toggles the window register several times a second with nothing open.
local function uiPanelOpen()
	return uiSeenAt ~= nil and (drawFrames - uiSeenAt) < UI_LATCH_FRAMES
end

-- A text box is the bottom six rows, its corner tile 121 and edge 122 in any frame style; `lo`/`hi` are the
-- tilemaps LCDC bit 3 picks between.
local TEXTBOX = { lo = 0x1800, hi = 0x1C00, row = 12, corner = 121, edge = 122 }
-- wMenuBorder* at load is refused until it changes: a reload cannot tell a live menu's rectangle from a leftover.
TEXTBOX.stale = string.format("%d,%d,%d,%d", u8(MENUBOX.top) or 0, u8(MENUBOX.left) or 0,
	u8(MENUBOX.bottom) or 0, u8(MENUBOX.right) or 0)

local function textBoxOpen()
	local lcdc = memory.read_u8(0xFF40, "System Bus") or 0
	local map = ((lcdc & 0x08) ~= 0) and TEXTBOX.hi or TEXTBOX.lo
	local row = map + TEXTBOX.row * 32
	-- Three cells, not one: terrain shares this index space, so one tile matching 121 could be a hillside.
	local left = memory.read_u8(row, "VRAM") or 0
	local next1 = memory.read_u8(row + 1, "VRAM") or 0
	local right = memory.read_u8(row + 19, "VRAM") or 0
	return left == TEXTBOX.corner and next1 == TEXTBOX.edge
		and right >= TEXTBOX.corner and right <= TEXTBOX.corner + 5
end


-- MESHGHOST_CRYSTAL_UI_DEBUG (or a global, set mid-session): which peers were painted, where, against what rectangle.
local UI_DEBUG_ENV = (os.getenv("MESHGHOST_CRYSTAL_UI_DEBUG") or "") ~= ""

-- COMPARE_TIERS's per-frame instruments also need MESHGHOST_CRYSTAL_COMPARE_STATS: their cost desyncs the tiers.
facingFrames.statsEnv = (os.getenv("MESHGHOST_CRYSTAL_COMPARE_STATS") or "") ~= ""
function facingFrames.stats()
	return COMPARE_TIERS
		and (facingFrames.statsEnv or _G.MESHGHOST_CRYSTAL_COMPARE_STATS == true)
end

-- MESHGHOST_CRYSTAL_MOVE_TRACE: S lines for what this engine sends, R lines per drawn peer, stamped with frame and
-- wall clock so two instances' logs line up; one file per bridge port.
function facingFrames.mvTrace(line)
	if not _G.MESHGHOST_CRYSTAL_MOVE_TRACE then
		return
	end
	local b = facingFrames.mvBuf or {}
	facingFrames.mvBuf = b
	local t = socketCore and socketCore.gettime and socketCore.gettime() or 0
	b[#b + 1] = string.format("%.3f f=%d %s", t, emu.framecount(), line)
	if #b >= 240 then
		local tf = io.open(string.format("%s/probes/movetrace_%s.log", SCRIPT_DIR,
			os.getenv("MESHGHOST_BRIDGE_PORT") or "default"), "a")
		if tf then
			tf:write(table.concat(b, "\n"), "\n")
			tf:close()
		end
		facingFrames.mvBuf = {}
	end
end

local lastMenuBox = nil
-- The object struct the drawn tier measures from, held across frames and cleared when the world is rebuilt.
local anchorIndex = nil

-- Sampled before every early return in drawOverflow, as a skipped frame's delta would be absorbed as a rebase.
-- A global: the file is at Lua's 200-local ceiling.
function meshghostSampleCamera()
	if facingFrames.camFrame ~= drawFrames then
		-- Frames since this last ran, which should always be 1: a regression check that it runs before every gate.
		if facingFrames.stats() and facingFrames.camFrame then
			local g = drawFrames - facingFrames.camFrame
			if g > 24 then g = 25 end
			facingFrames.camGap = facingFrames.camGap or {}
			facingFrames.camGap[g] = (facingFrames.camGap[g] or 0) + 1
		end
		facingFrames.camFrame = drawFrames
		-- The camera is hSCX/hSCY, negated; where the pair is dead bytes, camCheck sets camDead and the offset is used.
		local hcx = not ENGINE.camDead and u8(ENGINE.scxAddr, "System Bus") or nil
		local hcy = not ENGINE.camDead and u8(ENGINE.scyAddr, "System Bus") or nil
		ENGINE.camCheck(hcx, hcy)
		local scx = hcx and ((256 - hcx) % 256) or (u8(W_BGMAPOFFSETX) or 0)
		local scy = hcy and ((256 - hcy) % 256) or (u8(W_BGMAPOFFSETY) or 0)
		-- Audit against wPlayerBGMapOffsetX/Y: if the two mirror each other, every frame has dOff == -dH.
		if facingFrames.stats() then
			local hx, hy = hcx, hcy
			-- The old source, read explicitly: comparing scx/scy would compare hSC against itself.
			local ox = u8(W_BGMAPOFFSETX) or 0
			local oy = u8(W_BGMAPOFFSETY) or 0
			if hx and hy then
				if facingFrames.hX then
					local dhx = ((hx - facingFrames.hX + 128) % 256) - 128
					local dhy = ((hy - facingFrames.hY + 128) % 256) - 128
					local dox = ((ox - (facingFrames.hOX or ox) + 128) % 256) - 128
					local doy = ((oy - (facingFrames.hOY or oy) + 128) % 256) - 128
					facingFrames.hN = (facingFrames.hN or 0) + 1
					if dox == -dhx and doy == -dhy then
						facingFrames.hAgree = (facingFrames.hAgree or 0) + 1
					else
						facingFrames.hDis = (facingFrames.hDis or 0) + 1
						local k = string.format("off %+d,%+d vs hSC %+d,%+d",
							dox, doy, dhx, dhy)
						facingFrames.hD = facingFrames.hD or {}
						facingFrames.hD[k] = (facingFrames.hD[k] or 0) + 1
					end
				end
				facingFrames.hX, facingFrames.hY = hx, hy
				facingFrames.hOX, facingFrames.hOY = ox, oy
			else
				facingFrames.hNoRead = (facingFrames.hNoRead or 0) + 1
			end
		end
		if facingFrames.camX ~= nil
			and (scx ~= facingFrames.camX or scy ~= facingFrames.camY) then
			-- Only one axis and one gait stride is motion; anything else is a rebase, absorbed into camA and K so the
			-- paint cannot move.
			local pdx = ((scx - facingFrames.camX + 128) % 256) - 128
			local pdy = ((scy - facingFrames.camY + 128) % 256) - 128
			local pcd = math.abs(pdx) + math.abs(pdy)
			-- Every delta, before the test that might reject it.
			facingFrames.camHist = facingFrames.camHist or {}
			facingFrames.camHist[pcd] = (facingFrames.camHist[pcd] or 0) + 1

			-- Every stride this cartridge's StepVectors hold: a patched build's fourth gait scrolls 8px.
			local ok = false
			for g = 0, (ENGINE.gaits or 3) - 1 do
				if pcd == GAIT_PX[g] then
					ok = true
				end
			end
			local plausible = ok and (pdx == 0 or pdy == 0)
			if not plausible then
				facingFrames.camAX = (facingFrames.camAX or 0) + pdx
				facingFrames.camAY = (facingFrames.camAY or 0) + pdy
				if facingFrames.camKX then
					-- Minus: the paint is model + camA + K on both axes, so a rebase added to camA is cancelled in K.
					facingFrames.camKX = facingFrames.camKX - pdx
					facingFrames.camKY = facingFrames.camKY - pdy
				end
				facingFrames.camMoved = false
				facingFrames.camDelta = 0
				facingFrames.camStillFor = (facingFrames.camStillFor or 99) + 1
				facingFrames.camX, facingFrames.camY = scx, scy
				if COMPARE_TIERS then
					facingFrames.camRebase = (facingFrames.camRebase or 0) + 1
					-- Which rejected moves, not just how many: a repeated pair is a mechanism, not a rebase.
					local key = string.format("%+d,%+d", pdx, pdy)
					facingFrames.camRebaseD = facingFrames.camRebaseD or {}
					facingFrames.camRebaseD[key] =
						(facingFrames.camRebaseD[key] or 0) + 1
				end
			else
			facingFrames.camMoved, facingFrames.camStillFor = true, 0
			-- How far the camera moved, taken the short way round as the registers wrap at 256.
			local dxw = ((scx - facingFrames.camX + 128) % 256) - 128
			local dyw = ((scy - facingFrames.camY + 128) % 256) - 128
			-- The camera's accumulated world position, integrated from the register the screen is scrolled by.
			facingFrames.camAX = (facingFrames.camAX or 0) + dxw
			facingFrames.camAY = (facingFrames.camAY or 0) + dyw
			-- Each camera move against the direction the player walked: which register and sign, per direction.
			if facingFrames.stats() then
				local np = playerHistory[(playerHistory.n % playerHistory.size) + 1]
				local pdir = (np and np.dir) or 9
				facingFrames.camSign = facingFrames.camSign or {}
				local key = string.format("%s:%+d,%+d",
					DIR_NAMES.letter[pdir] or "?", dxw, dyw)
				facingFrames.camSign[key] = (facingFrames.camSign[key] or 0) + 1
			end
			local cd = math.abs(dxw) + math.abs(dyw)
			-- Binned per frame: the shape of the world's own scrolling as this adapter samples it.
			if cd > 8 then cd = 8 end
			facingFrames.camDelta = cd
			if facingFrames.stats() then
				facingFrames.camD = facingFrames.camD or {}
				facingFrames.camD[cd] = (facingFrames.camD[cd] or 0) + 1
			end
			end
		else
			facingFrames.camMoved = false
			facingFrames.camDelta = 0
			facingFrames.camStillFor = (facingFrames.camStillFor or 99) + 1
		end
		facingFrames.camX, facingFrames.camY = scx, scy
	end
end

-- Paints every peer the engine had no room for, once a frame.
function drawOverflow()
	drawFrames = drawFrames + 1
	-- Before every gate below, like the camera sampler: a frame skipped here would paint from tiles that are gone.
	invalidateTileCache()
	-- Before every gate below: the camera accumulator must not miss a frame.
	meshghostSampleCamera()
	-- Every early return clears (BizHawk's layer persists, freezing the last peers) and records why it stopped.
	local function stopDrawing(why)
		if why then
			facingFrames.stopWhy = facingFrames.stopWhy or {}
			facingFrames.stopWhy[why] = (facingFrames.stopWhy[why] or 0) + 1
			-- This frame's reason, so the per-frame trace can attribute a blank frame.
			facingFrames.stopLast, facingFrames.stopLastAt = why, policyFrames
		end
		pcall(function() gui.clearGraphics() end)
	end

	-- The settle hold ticks before any early return, so it is spent during a crossing. A seam has no fade and shuttling
	-- across one would re-arm it forever, so a seam crossing drains it.
	local seamRecently = ENGINE.xmap.seamAt
		and (policyFrames - ENGINE.xmap.seamAt) < 60
	-- Drained, not bypassed: holding `settling` false would freeze the countdown until the seam window ends.
	if seamRecently and playerHistory.settle > 0 then
		playerHistory.settle = 0
	end
	local settling = playerHistory.settle > 0
	if settling then
		playerHistory.settle = playerHistory.settle - 1
	end

	if not inPlay() then
		-- Every warp leaves HANDLE, same-map ones included, and no menu rectangle survives one.
		uiSeenAt, lastMenuBox = nil, nil
		-- The game never zeroes wMenuBorder* after a warp or a battle, so the latch site refuses this value until
		-- the slot changes. On TEXTBOX to spare a top-level local.
		TEXTBOX.stale = string.format("%d,%d,%d,%d", u8(MENUBOX.top) or 0,
			u8(MENUBOX.left) or 0, u8(MENUBOX.bottom) or 0, u8(MENUBOX.right) or 0)
		-- A seam crossing is not a teardown: inPlay() is false for six frames while the connection strip loads.
		-- Bypassing is safe only with the walking-player anchor below; without it, always stop.
		if not (ENGINE.xmap.seamAt and (policyFrames - ENGINE.xmap.seamAt) < 15) then
			stopDrawing("not-in-play")
			return
		end
	end
	if not DRAW_OVERFLOW and not COMPARE_TIERS then
		stopDrawing("menu")
		return
	end
	-- Paint only while the overworld sprite engine runs: every full-screen UI calls DisableSpriteUpdates.
	if ENGINE.sprOn and (u8(ENGINE.sprOn) or 0) == 0 then
		stopDrawing("sprites-off")
		return
	end

	-- HANDLE returns mid-fade and Crystal never fades the OBJ palette, so a rebuilt world is waited out.
	if settling then
		stopDrawing("settling")
		return
	end
	learnFacingFromPlayer()
	local uiOpen = uiPanelOpen()
	local boxOpen = textBoxOpen()
	local t, l, b, r = u8(MENUBOX.top), u8(MENUBOX.left), u8(MENUBOX.bottom), u8(MENUBOX.right)
	-- wMenuBorder* holds only the most recent box drawn (a text box over the party menu replaces it), so every
	-- distinct rectangle seen while the latch lives is kept.
	local rectKey = string.format("%d,%d,%d,%d", t or 0, l or 0, b or 0, r or 0)
	if TEXTBOX.stale and rectKey ~= TEXTBOX.stale then
		TEXTBOX.stale = nil -- the slot changed, so the game wrote this value
	end
	-- A rectangle is live only while its frame's corner tile sits at its top-left in the tilemap: the stale
	-- guard alone would leave a menu open across a reload unhidden.
	local boxDrawn = false
	if (b or 0) > 0 and (r or 0) > 0 then
		local lcdc = memory.read_u8(0xFF40, "System Bus") or 0
		local map = ((lcdc & 0x08) ~= 0) and TEXTBOX.hi or TEXTBOX.lo
		local scy = (memory.read_u8(0xFF42, "System Bus") or 0) // 8
		local scx = (memory.read_u8(0xFF43, "System Bus") or 0) // 8
		local tile = memory.read_u8(map + ((t + scy) % 32) * 32 + ((l + scx) % 32), "VRAM") or 0
		boxDrawn = (tile == TEXTBOX.corner)
		if UI_DEBUG_ENV or _G.MESHGHOST_CRYSTAL_UI_DEBUG == true then
			TEXTBOX.dbgCorner = tile
		end
	end
	if boxDrawn then
		local top, left, bottom, right = t * 8, l * 8, (b + 1) * 8, (r + 1) * 8
		lastMenuBox = lastMenuBox or {}
		local known = false
		for _, box in ipairs(lastMenuBox) do
			if box.top == top and box.left == left and box.bottom == bottom
				and box.right == right then
				known = true
				break
			end
		end
		if not known and #lastMenuBox < 8 then
			lastMenuBox[#lastMenuBox + 1] =
				{ top = top, left = left, bottom = bottom, right = right }
		end
		uiSeenAt = drawFrames -- the rectangle strobes to zero as the menu redraws; latch it
	elseif not uiOpen then
		lastMenuBox = nil -- no panel is up, so every remembered rectangle is stale
	end

	local nWanted, nDrawn, nNoTile, nOffScreen, nHidden, nFromRom = 0, 0, 0, 0, 0, 0
	local nOam = 0
	oam.beginFrame()
	-- nNoFacing counts peers drawn from the sprite's raw first frame because that facing has nothing learned
	-- yet, which looks like broken animation.
	local nNoFacing = 0
	local UI_DEBUG = UI_DEBUG_ENV or _G.MESHGHOST_CRYSTAL_UI_DEBUG == true
	local paintedSamples = {}
	local offSample = nil

	-- A positive test, not a deny-list of screens: a full-screen submenu leaves zero live OAM entries, where
	-- the overworld, the START menu and a text box keep 28 or more. wStateFlags bit 0 strobes, so not that.
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
	-- The player's entries catch the encounter transition, where the overworld is gone while wBattleMode is 0.
	if liveSprites == 0 or playerSpriteEntries == 0 then
		stopDrawing("no-live-sprites")
		return
	end

	-- Anchor on a standing character (a walker's MAP_X/Y is already its destination) and keep it while it
	-- stands, preferring the player: switching anchors shifts every peer by a few pixels.
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
	elseif (u8(OBJECT_STRUCTS + F_SPRITE) or 0) ~= 0 then
		-- Nobody stands: the walking player, its sprite taken back 16 - stepProgress along the walk to pair
		-- with MAP_X/Y. This keeps a reference through a seam crossing; never stored in anchorIndex.
		local base = OBJECT_STRUCTS
		anchorTileX, anchorTileY = u8(base + F_MAP_X), u8(base + F_MAP_Y)
		anchorPx, anchorPy = u8(base + F_SPRITE_X) or 0, u8(base + F_SPRITE_Y) or 0
		if (u8(base + F_WALKING) or STANDING) ~= STANDING then
			local back = stepProgress(base) - 16
			local d = ((u8(base + F_DIRECTION) or 0) // 4) & 3
			if d == 0 then anchorPy = anchorPy - back
			elseif d == 1 then anchorPy = anchorPy + back
			elseif d == 2 then anchorPx = anchorPx + back
			else anchorPx = anchorPx - back end
		end
	end
	-- The player's OAM corner: the minimum over its entries (a flip mirrors their order), found by tile id
	-- because InitSprites emits by priority and an emote can own entries 0-3. Emote and rod tiles lie outside.
	local playerOamX, playerOamY = 255, 255
	local pBase, pFound = (u8(OBJECT_STRUCTS + F_SPRITE_TILE) or 0) & 0x7F, 0
	for i = 0, oam.ENTRIES - 1 do
		local y = memory.read_u8(i * 4, "OAM") or 255
		if y >= 160 then -- OAM_YCOORD_HIDDEN, what `.fill` writes into every unused entry
			break -- the engine packs from 0 and hides the tail, so there is nothing past here
		end
		local d = ((memory.read_u8(i * 4 + 2, "OAM") or 255) - pBase) & 0xFF
		if d <= 0x0B or (d >= 0x80 and d <= 0x8B) then
			local x = memory.read_u8(i * 4 + 1, "OAM") or 255
			if y < playerOamY then playerOamY = y end
			if x < playerOamX then playerOamX = x end
			pFound = pFound + 1
			if pFound >= 4 then
				break -- four body entries; a ghost wearing the same sprite comes later in struct order
			end
		elseif pFound > 0 then
			break -- the player's own run has ended; anything further is somebody else
		end
	end
	if pFound == 0 then
		-- Not in the buffer (facing STANDING, or skipped): entries 0-3, rather than painting at 255,255.
		for i = 0, 3 do
			local y = memory.read_u8(i * 4, "OAM") or 255
			local x = memory.read_u8(i * 4 + 1, "OAM") or 255
			if y < playerOamY then playerOamY = y end
			if x < playerOamX then playerOamX = x end
		end
	end
	-- Recalibrated every frame: this term tracks the camera, and freezing it left the ghost a tile off the
	-- scroll. Each history entry keeps the OAM origin with the tile and offset it belongs to.
	do
		local h = playerHistory
		h.n = (h.n or 0) + 1
		-- The ring is never cleared, so this alone tells a current-map sample from one of the map just left.
		h.since = (h.since or 0) + 1
		h[(h.n % h.size) + 1] = {
			oamX = playerOamX, oamY = playerOamY,
			tx = u8(OBJECT_STRUCTS + F_MAP_X) or 0, ty = u8(OBJECT_STRUCTS + F_MAP_Y) or 0,
			prog = stepProgress(OBJECT_STRUCTS),
			walking = (u8(OBJECT_STRUCTS + F_WALKING) or STANDING) ~= STANDING,
			dir = ((u8(OBJECT_STRUCTS + F_DIRECTION) or 0) // 4) & 3,
		}
		-- The engine's tick, observed: the parity on which the player's step progress changes is the clock a
		-- ghost must move on. Latched, so a standing player keeps the last phase.
		local nowProg = stepProgress(OBJECT_STRUCTS)
		if facingFrames.lastPlayerProg and nowProg ~= facingFrames.lastPlayerProg then
			local parity = emu.framecount() % 2
			if COMPARE_TIERS then
				facingFrames.paritySeen = facingFrames.paritySeen or {}
				facingFrames.paritySeen[parity] = (facingFrames.paritySeen[parity] or 0) + 1
				-- The player's own gaps: the irregular rhythm the ghost's are compared against.
				if facingFrames.playerGapAt then
					local g = emu.framecount() - facingFrames.playerGapAt
					if g > 8 then g = 8 end
					facingFrames.playerGap = facingFrames.playerGap or {}
					facingFrames.playerGap[g] = (facingFrames.playerGap[g] or 0) + 1
				end
				facingFrames.playerGapAt = emu.framecount()
			end
			facingFrames.tickParity = parity
		end
		facingFrames.lastPlayerProg = nowProg
	end

	-- Paint only once the aged reference is from this map. Never clear the ring instead: the lookup then
	-- falls through to this frame's sample. `age + 1`: the lookup reaches back exactly `age` pushes.
	if (playerHistory.since or 0) <= playerHistory.age then
		stopDrawing("history-not-ready")
		return
	end

	local calX = (playerOamX - 8) - (u8(OBJECT_STRUCTS + F_SPRITE_X) or 0)
	local calY = (playerOamY - 16) - (u8(OBJECT_STRUCTS + F_SPRITE_Y) or 0)

	if anchorTileX then
		anchorPx = anchorPx + calX
		anchorPy = anchorPy + calY
	end
	-- With the tier off but COMPARE_TIERS on, only the comparison ghost is painted.
	local paintable = overflow
	if not DRAW_OVERFLOW then
		paintable = {}
		for pid, po in pairs(overflow) do if po.compare then paintable[pid] = po end end
	end
	for id, o in pairs(paintable) do
		nWanted = nWanted + 1
		if o.lastX ~= o.x or o.lastY ~= o.y then
			o.fromX, o.fromY = o.lastX, o.lastY
			o.lastX, o.lastY, o.movedAt = o.x, o.y, drawFrames
		end
		-- Resident tiles first, matching a spawned peer beside it; else the cartridge.
		local source, palette = nil, u8(OBJECT_STRUCTS + F_PALETTE) or 0
		-- The engine copies a sprite's graphics into VRAM verbatim, so a resident base whose first tile differs
		-- from the ROM's holds something else right now: draw from ROM. The ROM sum is memoised per sprite.
		local tile = residentSpriteTile(o.sprite)
		if tile and OVERWORLD_SPRITES_ROM then
			local want = facingFrames.romSig and facingFrames.romSig[o.sprite]
			if want == nil then
				local g = spriteGfxInRom(o.sprite)
				want = false
				if g then
					want = 0
					for b = 0, 15 do
						want = (want + romByte(g + b)) & 0xFFFF
					end
				end
				facingFrames.romSig = facingFrames.romSig or {}
				facingFrames.romSig[o.sprite] = want
			end
			if want then
				-- Character graphics live in bank 1 (VRAM_BANK1); BizHawk's VRAM domain holds both banks flat.
				local have = 0
				for b = 0, 15 do
					have = (have + (readVram(VRAM_BANK1 + tile * 16 + b) or 0)) & 0xFFFF
				end
				if have ~= want then
					local was = tile
					tile = nil -- not this sprite's pixels right now; fall through to the cartridge
					-- Logged once: bank 1 held steady through two flies, so this may guard nothing.
					if not facingFrames.vramMismatch then
						facingFrames.vramMismatch = true
						logFile(string.format("resident tiles for sprite %s did not match the "
							.. "cartridge (base %d) -- drawing from ROM instead. FIRST TIME this "
							.. "session; if this line never appears, the check is dead weight.",
							tostring(o.sprite), was or -1))
					end
				end
			end
		end
		-- Wire art first (`o.sprite` is then a stand-in). No `vram` on it, so the hardware tier declines
		-- it and nothing reaches game memory.
		if o.art then
			source = { art = o.art }
		elseif tile then
			source = { vram = tile }
		else
			local gfx, _, pal = spriteGfxInRom(o.sprite)
			if gfx then
				source, palette = { rom = gfx }, pal
				nFromRom = nFromRom + 1
			else
				-- Last resort: this machine's own player, whose sprite id is valid on our ROM by construction.
				local mine = u8(OBJECT_STRUCTS + F_SPRITE)
				local own = residentSpriteTile(mine)
				if own then
					source = { vram = own }
				else
					local g, _, p = spriteGfxInRom(mine)
					if g then
						source, palette = { rom = g }, p
						nFromRom = nFromRom + 1
					end
				end
			end
		end
		if not source then nNoTile = nNoTile + 1 end
		-- The peer's own palette wins over both fallbacks; an older peer sends none.
		if source and o.pal ~= nil then palette = o.pal end
		-- Off unless MESHGHOST_CRYSTAL_SPRITE_TRACE. Logs only when a peer's graphics source changes, which
		-- tells a wrong id from the right id on the wrong tiles.
		if facingFrames.sprTrace == nil then
			facingFrames.sprTrace = (os.getenv("MESHGHOST_CRYSTAL_SPRITE_TRACE") or "") ~= ""
		end
		if facingFrames.sprTrace or _G.MESHGHOST_CRYSTAL_SPRITE_TRACE == true then
			local kind = source and (source.vram and "vram" or "rom") or "none"
			local where = source and (source.vram or source.rom) or -1
			-- Keyed on a pixel signature too: the content under a steady base can change.
			local sig = 0
			if source and source.vram then
				for b = 0, 15 do
					sig = (sig + (readVram(VRAM_BANK1 + source.vram * 16 + b) or 0)) & 0xFFFF
				end
			end
			local key = string.format("%s/%s/%s/%s/%04X", tostring(o.sprite), kind, tostring(where),
				tostring(o.facing), sig)
			facingFrames.sprLast = facingFrames.sprLast or {}
			if facingFrames.sprLast[id] ~= key then
				facingFrames.sprLast[id] = key
				logFile(string.format("sprite-trace: f=%d %s peerSprite=%s -> %s %s sig=%04X "
					.. "(facing=%s, local sprite=%s at base=%s)", drawFrames, id,
					tostring(o.sprite), kind, tostring(where), sig, tostring(o.facing),
					tostring(u8(OBJECT_STRUCTS + F_SPRITE)),
					tostring(u8(OBJECT_STRUCTS + F_SPRITE_TILE))))
			end
		end
		if source then
			-- Signed coordinates, not screenCoords(): its sprite space wraps at 256 (Y offset by 16), so a peer
			-- above or left of the camera would read as off screen.
			local sx, sy
			if anchorTileX then
				-- Tile deltas from a standing character, signed: a peer left of or above it is a negative delta.
				sx = anchorPx + (o.x - anchorTileX) * 16
				sy = anchorPy + (o.y - anchorTileY) * 16
			else
				-- Nobody stands still: the engine-space formula, right at rest and up to a tile off mid-step.
				sx, sy = screenCoords(o.x, o.y)
				sx = sx + calX
				sy = sy + calY
			end
			-- Every term is byte arithmetic, so the true position exists only mod 256: fold into [-16, 240),
			-- where a 16px character can touch the screen; a genuinely off-screen one still lands outside it.
			sx = ((sx % 256) + 272) % 256 - 16
			sy = ((sy % 256) + 272) % 256 - 16

			-- playerScreen + (peerTile - playerTile)*16 - playerProgress + peerProgress: the camera cancels. The
			-- player is taken as it was when the peer's state was current, or every tile boundary snaps back.
			local hist = playerHistory
			local aged = hist[((hist.n - hist.age) % hist.size) + 1]
				or hist[(hist.n % hist.size) + 1]

			local pTile = { x = aged.tx, y = aged.ty }
			local pProg = aged.prog
			local pDir = aged.dir
			local peerProg = tonumber(o.prog) or 0

			-- Progress becomes a displacement through the facing, in the adapter's down/up/left/right order.
			local function displace(dir, px)
				if dir == 0 then return 0, px end
				if dir == 1 then return 0, -px end
				if dir == 2 then return -px, 0 end
				return px, 0
			end
			-- MAP_X/MAP_Y are the destination: mid-step a character is at destination - (16 - progress).
			local function offsetFromDest(dir, prog, walking)
				if not walking then
					return 0, 0
				end
				return displace(dir, prog - 16)
			end

			local ppx, ppy = offsetFromDest(pDir, pProg, aged.walking)

			-- The ghost walks to the destination tile at the engine's pace rather than being placed: interpolation
			-- sampled at unevenly spaced emulated frames rounds to steps no character takes.
			local tX, tY = o.x * 16, o.y * 16
			if not o.modelX then
				o.modelX, o.modelY = tX, tY
			end
			-- Gaps between the ghost's 2px moves, to compare with the player's rhythm.
			if facingFrames.stats() and o.only == "drawn" then
				local now = emu.framecount()
				if o.modelX ~= facingFrames.gapLastX or o.modelY ~= facingFrames.gapLastY then
					if facingFrames.gapLastAt then
						local g = now - facingFrames.gapLastAt
						if g > 8 then g = 8 end
						facingFrames.ghostGap = facingFrames.ghostGap or {}
						facingFrames.ghostGap[g] = (facingFrames.ghostGap[g] or 0) + 1
					end
					facingFrames.gapLastAt = now
					facingFrames.gapLastX, facingFrames.gapLastY = o.modelX, o.modelY
				end
			end
			-- Signed lead over the interpolated position: ahead and behind are different faults.
			if facingFrames.stats() and o.only == "drawn" and o.pixX and o.pixY then
				local lead = (o.facing == 0 or o.facing == 1)
					and (o.modelY - o.pixY) or (o.modelX - o.pixX)
				if o.facing == 1 or o.facing == 2 then lead = -lead end -- toward travel
				local lk = math.floor(lead + 0.5)
				if lk > 8 then lk = 8 end
				if lk < -8 then lk = -8 end
				facingFrames.lead = facingFrames.lead or {}
				facingFrames.lead[lk] = (facingFrames.lead[lk] or 0) + 1
			end
			-- How far behind the model gets; ungated because the shipped pacing line reads it.
			local behind = math.abs(o.modelX - tX) + math.abs(o.modelY - tY)
			facingFrames.modelMax = math.max(facingFrames.modelMax or 0, behind)
			if o.pixX and o.pixY then
				-- Where: the interpolated position rounded to the engine's 2px grid. When: on the engine's beat,
				-- latched per burst, since a walk holds one parity and the next may not. The raw stream needs this
				-- too: about 7% of walking frames receive 0 or 2 messages.
				local qx = math.floor(o.pixX / 2 + 0.5) * 2
				local qy = math.floor(o.pixY / 2 + 0.5) * 2
				-- Born tile-aligned: every later move is a committed 16px step, so it keeps that alignment.
				if not o.modelX then
					o.modelX, o.modelY = tX, tY
				end
				-- The phase is released only after half a second still (each re-latch is a parity toss) and taken
				-- from the engine's tick. Wants: mid-step, or one stride of the peer's gait away (legacy: 8px).
				local wants = (o.stepLeft or 0) > 0
					or (math.abs(qx - o.modelX) + math.abs(qy - o.modelY))
						>= (_G.MESHGHOST_CRYSTAL_LEGACY_CUSHION and 8 or (GAIT_PX[o.gait or 1] or 2))
				if not wants then
					o.modelStill = (o.modelStill or 0) + 1
					if o.modelStill >= 30 then
						o.modelPhase = nil
					end
				else
					o.modelStill = 0
					if o.modelPhase == nil then
						o.modelPhase = facingFrames.tickParity or (emu.framecount() % 2)
						if COMPARE_TIERS then
							facingFrames.relatch = (facingFrames.relatch or 0) + 1
						end
					end
					-- Follow the engine's beat: a lag frame pauses its tick but not emu.framecount(), flipping
					-- the parity mid-walk, so tickParity is re-observed on every advance of the player's step.
					if facingFrames.tickParity ~= nil
						and o.modelPhase ~= facingFrames.tickParity then
						o.modelPhase = facingFrames.tickParity
						if COMPARE_TIERS then
							facingFrames.phaseFollow = (facingFrames.phaseFollow or 0) + 1
						end
					end
					-- A character cannot stop mid-tile, so the target is read only at boundaries. The model
					-- moves on frames the scroll register changes; after eight still frames (the camera pauses
					-- 1-2 at each step boundary) it keeps its own beat, as does a step whose peer has stopped.
					local due = facingFrames.camMoved
						or (((((o.stepLeft or 0) > 0 and not o.walking)
								or (facingFrames.camStillFor or 99) >= 8))
							and (emu.framecount() % 2) == o.modelPhase)
					-- The model's beat and the paint's origin are one decision: align tiers by delaying the
					-- model's inputs, never its clock.
					if due then
						-- Can run twice a frame: a 4px camera frame may land with 2px left in the step, and
						-- splitting it across two frames stutters once a tile.
						local function decideBoundary()
							local dx, dy = qx - o.modelX, qy - o.modelY
							local adx, ady = math.abs(dx), math.abs(dy)
							-- Catch-up arms after two boundaries 6 strides behind and clears under 3: outside the
							-- hover chaining keeps the model in, and in strides so it holds at every gait.
							local st = GAIT_PX[o.gait or 1] or 2
							if adx + ady >= 6 * st then
								o.lagBeats = (o.lagBeats or 0) + 1
							elseif adx + ady < 3 * st then
								o.lagBeats, o.catchup = 0, nil
							end
							if (o.lagBeats or 0) >= 2 then
								o.catchup = true
							end
							if adx + ady > 48 then
								-- Three tiles out is a teleport: snap to the tile, keeping the model grid-aligned.
								o.modelX, o.modelY, o.stepLeft = tX, tY, 0
								if COMPARE_TIERS then
									facingFrames.modelSnaps = (facingFrames.modelSnaps or 0) + 1
								end
							elseif not _G.MESHGHOST_CRYSTAL_LEGACY_CUSHION then
								-- One stride of displacement is a step that has started, and it will finish its
								-- tile. The walking flag reads idle for two frames at a step's top, so it is not
								-- consulted. MESHGHOST_CRYSTAL_LEGACY_CUSHION keeps the old thresholds below.
								if adx >= st or ady >= st then
									if adx >= ady then
										o.stepDX, o.stepDY = (dx > 0 and 1 or -1), 0
									else
										o.stepDX, o.stepDY = 0, (dy > 0 and 1 or -1)
									end
									o.stepLeft = 16
								end
							elseif adx >= ady and adx >= 8 then
								o.stepDX, o.stepDY = (dx > 0 and 1 or -1), 0
								o.stepLeft = 16
							elseif ady > adx and ady >= 8 then
								o.stepDX, o.stepDY = 0, (dy > 0 and 1 or -1)
								o.stepLeft = 16
							elseif o.walking and adx + ady >= 3 * st then
								-- Legacy: a three-stride cushion, which the wire's 2-4px arrival jitter cannot pierce.
								if adx >= ady then
									o.stepDX, o.stepDY = (dx > 0 and 1 or -1), 0
								else
									o.stepDX, o.stepDY = 0, (dy > 0 and 1 or -1)
								end
								o.stepLeft = 16
							elseif o.walking and adx + ady >= st
								and drawFrames - (o.modelMovedAt or -99) <= 2 then
								-- Chaining: a model that finished a tile within two frames while its peer still walks
								-- is mid-gait, so one stride of headroom suffices.
								if adx >= ady then
									o.stepDX, o.stepDY = (dx > 0 and 1 or -1), 0
								else
									o.stepDX, o.stepDY = 0, (dy > 0 and 1 or -1)
								end
								o.stepLeft = 16
							end
						end
						-- On a camera frame the budget is the camera's own delta, consecutive frames included;
						-- the two-frame rule binds only the camera-parked fallback.
						local mgap = drawFrames - (o.modelMovedAt or -99)
						local budget = 0
						-- extras.gait carries the engine's StepVectors group (1/2/4px), so the stride is the peer's.
						local stride = GAIT_PX[o.gait or 1] or 2
						if facingFrames.camMoved then
							-- The camera's delta is the world moving under the peer: a standing peer shifts by
							-- exactly that, so its stride is never a ceiling. camDelta is clamped to 8.
							budget = facingFrames.camDelta or stride
							-- The stride is a floor only for a peer that is stepping.
							if o.walking and budget < stride then
								budget = stride
							end
						elseif mgap >= 2 then
							-- Camera parked: walk at the peer's own gait, never faster; double pace is a snap.
							budget = stride
							if o.catchup and COMPARE_TIERS then
								facingFrames.freeCatchup = (facingFrames.freeCatchup or 0) + 1
							end
						end
						o.dbgState = facingFrames.stats() and string.format("cam=%d gap=%d bud=%d step=%d dist=%d,%d cu=%s",
							facingFrames.camDelta or 0, mgap, budget, o.stepLeft or 0,
							qx - o.modelX, qy - o.modelY, tostring(o.catchup or false)) or o.dbgState
						for _ = 1, 2 do
							if budget <= 0 then break end
							if (o.stepLeft or 0) == 0 then
								decideBoundary()
								if (o.stepLeft or 0) == 0 then break end
							end
							local mv = budget
							if mv > o.stepLeft then mv = o.stepLeft end
							o.modelX = o.modelX + (o.stepDX or 0) * mv
							o.modelY = o.modelY + (o.stepDY or 0) * mv
							o.stepLeft = o.stepLeft - mv
							budget = budget - mv
							-- Ungated: the shipped pacing line reads it too.
							if o.catchup then
								facingFrames.catchupFrames = (facingFrames.catchupFrames or 0) + 1
							end
							-- The legs read this: position and pose run off one clock.
							o.modelMovedAt = drawFrames
						end
					end
				end
			elseif math.abs(o.modelX - tX) > 24 or math.abs(o.modelY - tY) > 24 then
				-- Past a tile and a half is a teleport, and this snaps. Counted unconditionally, so the
				-- shipped log shows whether it fires.
				facingFrames.modelSnaps = (facingFrames.modelSnaps or 0) + 1
				facingFrames.modelSnapPx = math.max(facingFrames.modelSnapPx or 0,
					math.max(math.abs(o.modelX - tX), math.abs(o.modelY - tY)))
				o.modelX, o.modelY = tX, tY
			else
				-- Two pixels, on the engine's tick: the scroll never moves 1px, and moving on the other parity
				-- shifts the ghost 2px against the player every frame. Latched for a standing player.
				local moveThisFrame = (emu.framecount() % 2) == (facingFrames.tickParity or 0)
				if moveThisFrame then
					local dx, dy = tX - o.modelX, tY - o.modelY
					local sx2 = (dx > 0 and 2) or (dx < 0 and -2) or 0
					local sy2 = (dy > 0 and 2) or (dy < 0 and -2) or 0
					-- Never overshoot: a resync or an odd start can leave the model off the 2px grid.
					if math.abs(dx) < 2 then sx2 = dx end
					if math.abs(dy) < 2 then sy2 = dy end
					o.modelX, o.modelY = o.modelX + sx2, o.modelY + sy2
				end
			end
			if _G.MESHGHOST_CRYSTAL_MOVE_TRACE and o.only ~= "hw" then
				facingFrames.mvTrace(string.format("R %s tgt=%s,%s model=%d,%d left=%d dir=%d,%d walk=%s "
					.. "gait=%s cam=%s/%d still=%d face=%s cu=%s",
					tostring(id), tostring(o.pixX), tostring(o.pixY), o.modelX, o.modelY, o.stepLeft or 0,
					o.stepDX or 0, o.stepDY or 0, tostring(o.walking), tostring(o.gait),
					tostring(facingFrames.camMoved), facingFrames.camDelta or 0,
					facingFrames.camStillFor or -1, tostring(o.facing), tostring(o.catchup or false)))
			end
			-- While a committed step is unfinished its direction is the facing: the wire turns on a step's
			-- first pixel, before the model finishes its tile. MESHGHOST_CRYSTAL_WIRE_FACING reverts it.
			if (o.stepLeft or 0) > 0 and not _G.MESHGHOST_CRYSTAL_WIRE_FACING then
				local sdx, sdy = o.stepDX or 0, o.stepDY or 0
				if sdy > 0 then o.facing = 0
				elseif sdy < 0 then o.facing = 1
				elseif sdx < 0 then o.facing = 2
				elseif sdx > 0 then o.facing = 3 end
			end
			local gx = o.modelX - pTile.x * 16
			local gy = o.modelY - pTile.y * 16

			-- Legs from distance travelled along the axis of travel (position mod 16): extras.prog is not
			-- interpolated, and distance remaining restarts the cycle early. The axis comes from the
			-- destination, never the facing, which can flicker.
			if tX ~= o.modelX then
				o.progAxis = "x"
			elseif tY ~= o.modelY then
				o.progAxis = "y"
			end
			local along = (o.progAxis == "x") and o.modelX or o.modelY
			peerProg = math.floor(along) % 16
			-- Up and left travel toward smaller coordinates, so their progress runs the other way.
			if o.facing == 1 or o.facing == 2 then
				peerProg = (16 - peerProg) % 16
			end
			sx = math.floor((aged.oamX or playerOamX) - 8 + gx - ppx + 0.5)
			sy = math.floor((aged.oamY or playerOamY) - 16 + gy - ppy + 0.5)

			-- Painted as model + camA + K: the tile formula above hands over on different frames at each
			-- boundary, so it only calibrates K while the camera is parked.
			if o.modelX then
				-- Both scroll registers run inverted to map pixels. The paint never switches formula when the
				-- camera parks; parking only nudges K.
				if (facingFrames.camStillFor or 0) >= 8 then
					local wantKX = sx - o.modelX - (facingFrames.camAX or 0)
					local wantKY = sy - o.modelY - (facingFrames.camAY or 0)
					if not facingFrames.camKX then
						facingFrames.camKX, facingFrames.camKY = wantKX, wantKY
					else
						local ddx = wantKX - facingFrames.camKX
						local ddy = wantKY - facingFrames.camKY
						-- wantK is player-side only, so while parked it must be constant; correct K only when it
						-- equals last frame's, since the camera goes quiet for a beat as a step starts.
						local stable = (facingFrames.kWantX == wantKX
							and facingFrames.kWantY == wantKY)
						facingFrames.kStable = stable
						-- Eight frames of equality: entering a park the reference can sit up to 3px off for eight
						-- frames, which a two-frame check passes.
						facingFrames.kStableFor = stable and ((facingFrames.kStableFor or 0) + 1) or 0
						-- Outside the probe guard: `stable` is shipped behaviour, so its state must advance with
						-- the probe off.
						facingFrames.kWantX, facingFrames.kWantY = wantKX, wantKY
						if facingFrames.stats() then
							if facingFrames.kWantPrev and not stable then
								facingFrames.kWantMoves = (facingFrames.kWantMoves or 0) + 1
							end
							facingFrames.kWantPrev = true
							-- camAX is fixed while parked and modelX cancels, so a moving target is the player's
							-- OAM, tile or progress; OAM also holds our own drawn ghost.
							local cOam = (aged.oamX or playerOamX)
							if facingFrames.kTOam and cOam ~= facingFrames.kTOam then
								facingFrames.kTOamN = (facingFrames.kTOamN or 0) + 1
							end
							if facingFrames.kTTile and pTile.x ~= facingFrames.kTTile then
								facingFrames.kTTileN = (facingFrames.kTTileN or 0) + 1
							end
							if facingFrames.kTPpx and ppx ~= facingFrames.kTPpx then
								facingFrames.kTPpxN = (facingFrames.kTPpxN or 0) + 1
							end
							if facingFrames.kTCam and (facingFrames.camAX or 0) ~= facingFrames.kTCam then
								facingFrames.kTCamN = (facingFrames.kTCamN or 0) + 1
							end
							facingFrames.kTOam, facingFrames.kTTile = cOam, pTile.x
							facingFrames.kTPpx, facingFrames.kTCam = ppx, (facingFrames.camAX or 0)
							if o.modelX % 1 ~= 0 or o.modelY % 1 ~= 0 then
								facingFrames.kFrac = (facingFrames.kFrac or 0) + 1
							end
						end
						-- KSETTLE speaks only when a park opens with a disagreement; samples are stamped by frame
						-- because facingFrames is shared by every drawn peer.
						if COMPARE_TIERS and (ddx ~= 0 or ddy ~= 0)
							and (facingFrames.camStillFor or 0) >= 8
							and (facingFrames.camStillFor or 0) <= 64
							and (facingFrames.camStillFor % 8) == 0
							and facingFrames.kSettleAt ~= drawFrames then
							facingFrames.kSettleAt = drawFrames
							logFile(string.format("  KSETTLE f%d still=%d dd=%d,%d",
								drawFrames, facingFrames.camStillFor, ddx, ddy))
						end
						-- The drift a walk left, sampled at 16, not 8: the reference settles between 8 and 16.
						if COMPARE_TIERS and (facingFrames.camStillFor or 0) == 16
							and facingFrames.kParkAt ~= drawFrames then
							facingFrames.kParkAt = drawFrames
							local d = math.abs(ddx) + math.abs(ddy)
							facingFrames.kParks = (facingFrames.kParks or 0) + 1
							facingFrames.kParkSum = (facingFrames.kParkSum or 0) + d
							if d > (facingFrames.kParkMax or 0) then facingFrames.kParkMax = d end
							-- Per direction, and one line per park decomposing ddx = dTarget - dModel - dCamA
							-- since the last park: the term off its prediction carries the drift.
							local tgtX = wantKX + o.modelX + (facingFrames.camAX or 0)
							local tgtY = wantKY + o.modelY + (facingFrames.camAY or 0)
							if facingFrames.kRunTgtX then
								logFile(string.format(
									"  KPARK f%d dir=%s dd=%d,%d run: target=%d,%d model=%d,%d camA=%d,%d",
									drawFrames, DIR_NAMES.letter[pDir] or "?", ddx, ddy,
									tgtX - facingFrames.kRunTgtX, tgtY - facingFrames.kRunTgtY,
									o.modelX - facingFrames.kRunModX, o.modelY - facingFrames.kRunModY,
									(facingFrames.camAX or 0) - facingFrames.kRunCamX,
									(facingFrames.camAY or 0) - facingFrames.kRunCamY))
							end
							facingFrames.kRunTgtX, facingFrames.kRunTgtY = tgtX, tgtY
							facingFrames.kRunModX, facingFrames.kRunModY = o.modelX, o.modelY
							facingFrames.kRunCamX = facingFrames.camAX or 0
							facingFrames.kRunCamY = facingFrames.camAY or 0
							local dl = DIR_NAMES.letter[pDir] or "?"
							facingFrames.kParkDir = facingFrames.kParkDir or {}
							local b = facingFrames.kParkDir[dl] or { n = 0, sum = 0, max = 0 }
							b.n, b.sum = b.n + 1, b.sum + d
							if d > b.max then b.max = d end
							facingFrames.kParkDir[dl] = b
						end
						-- Over a tile apart, K is reset; otherwise it is nudged 1px per axis, only on a frame
						-- the model did not move and against a reference stable for eight frames.
						if math.abs(ddx) > 16 or math.abs(ddy) > 16 then
							facingFrames.camKX, facingFrames.camKY = wantKX, wantKY
						elseif o.modelMovedAt ~= drawFrames
							and (facingFrames.kStableFor or 0) >= 8 then
							-- Repayment stays continuous and 1px: a deadband let drift grow to the snap
							-- threshold, and 2px steps after arrival overshot and snapped back.
							if ddx ~= 0 then
								facingFrames.camKX = facingFrames.camKX + (ddx > 0 and 1 or -1)
							end
							if ddy ~= 0 then
								facingFrames.camKY = facingFrames.camKY + (ddy > 0 and 1 or -1)
							end
							if COMPARE_TIERS and (ddx ~= 0 or ddy ~= 0) then
								-- Pixels actually repaid: one per axis per nudge frame.
								facingFrames.kFix = (facingFrames.kFix or 0)
									+ (ddx ~= 0 and 1 or 0) + (ddy ~= 0 and 1 or 0)
								-- Far more nudge frames than drift means it chases something that returns.
								facingFrames.kNudges = (facingFrames.kNudges or 0) + 1
								-- Reversals tell a slow corrector from one undoing itself: a real debt reverses
								-- at most once a park.
								local sgx = (ddx > 0) and 1 or ((ddx < 0) and -1 or 0)
								local sgy = (ddy > 0) and 1 or ((ddy < 0) and -1 or 0)
								if sgx ~= 0 and facingFrames.kSgX and sgx ~= facingFrames.kSgX then
									facingFrames.kFlips = (facingFrames.kFlips or 0) + 1
								end
								if sgy ~= 0 and facingFrames.kSgY and sgy ~= facingFrames.kSgY then
									facingFrames.kFlips = (facingFrames.kFlips or 0) + 1
								end
								if sgx ~= 0 then facingFrames.kSgX = sgx end
								if sgy ~= 0 then facingFrames.kSgY = sgy end
							end
						end
					end
				end
				if facingFrames.camKX then
					sx = math.floor(o.modelX + (facingFrames.camAX or 0) + facingFrames.camKX + 0.5)
					sy = math.floor(o.modelY + (facingFrames.camAY or 0) + facingFrames.camKY + 0.5)
					-- Event-triggered: dump the model state of any frame where the paint jumps 2px or more.
					if facingFrames.stats() and o.only == "drawn" then
						local jump = facingFrames.kLastSX
							and (math.abs(sx - facingFrames.kLastSX) >= 2
								or math.abs(sy - facingFrames.kLastSY) >= 2)
						if jump then
							logFile(string.format("  KJUMP f%d dsx=%d dsy=%d %s",
								drawFrames, sx - facingFrames.kLastSX, sy - facingFrames.kLastSY,
								o.dbgState or "?"))
						end
						facingFrames.kLastSX, facingFrames.kLastSY = sx, sy
					end
				end
			end

			-- Splits the painted delta into the player reference and the ghost's own motion: which term jumps.
			if facingFrames.stats() and o.only == "drawn" then
				local refY = (aged.oamY or playerOamY) - ppy
				local refX = (aged.oamX or playerOamX) - ppx
				if facingFrames.lastRefY then
					facingFrames.refD = facingFrames.refD or {}
					facingFrames.ghostD = facingFrames.ghostD or {}
					local vertical = (o.facing == 0 or o.facing == 1)
					local rd = math.floor(math.abs((vertical and refY or refX)
						- (vertical and facingFrames.lastRefY or facingFrames.lastRefX)) + 0.5)
					local gd = math.floor(math.abs((vertical and gy or gx)
						- (vertical and facingFrames.lastGY or facingFrames.lastGX)) + 0.5)
					local key = (vertical and "v" or "h")
					facingFrames.refD[key] = facingFrames.refD[key] or {}
					facingFrames.ghostD[key] = facingFrames.ghostD[key] or {}
					if rd > 6 then rd = 6 end
					if gd > 6 then gd = 6 end
					facingFrames.refD[key][rd] = (facingFrames.refD[key][rd] or 0) + 1
					facingFrames.ghostD[key][gd] = (facingFrames.ghostD[key][gd] or 0) + 1
				end
				-- On facingFrames, not o: the peer entry is rebuilt on every state message, so o forgets by next frame.
				facingFrames.lastRefY, facingFrames.lastRefX = refY, refX
				facingFrames.lastGY, facingFrames.lastGX = gy, gx
				-- stepProgress is always even: histogram the two 1px-resolution sources to see which moves each frame.
				local scr = u8(W_BGMAPOFFSETY)
				local oy = playerOamY
				if scr and facingFrames.lastScroll then
					local sd = math.abs(scr - facingFrames.lastScroll)
					if sd > 6 then sd = 6 end
					facingFrames.scrollD = facingFrames.scrollD or {}
					facingFrames.scrollD[sd] = (facingFrames.scrollD[sd] or 0) + 1
				end
				if oy and facingFrames.lastOamY then
					local od = math.abs(oy - facingFrames.lastOamY)
					if od > 6 then od = 6 end
					facingFrames.oamD = facingFrames.oamD or {}
					facingFrames.oamD[od] = (facingFrames.oamD[od] or 0) + 1
				end
				facingFrames.lastScroll, facingFrames.lastOamY = scr, oy
			end

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
				-- The game draws characters over its text box, so a box covers a ghost only where its tiles set BG
				-- priority, read at its top-left interior tile with scroll; VRAM bank 1 is at +0x2000 in BizHawk.
				local function boxCovers(topPx, leftPx)
					local lcdc = memory.read_u8(0xFF40, "System Bus") or 0
					local map = ((lcdc & 0x08) ~= 0) and TEXTBOX.hi or TEXTBOX.lo
					local scy = (memory.read_u8(0xFF42, "System Bus") or 0) // 8
					local scx = (memory.read_u8(0xFF43, "System Bus") or 0) // 8
					local row = (topPx // 8 + scy) % 32
					local col = (leftPx // 8 + 1 + scx) % 32
					local attr = memory.read_u8(0x2000 + map + row * 32 + col, "VRAM") or 0
					return (attr & 0x80) ~= 0
				end
				-- A live menu rectangle other than the text box means a menu is up; then the text-box rows hide too.
				local menuUp = false
				if uiOpen and lastMenuBox then
					for _, box in ipairs(lastMenuBox) do
						if not (box.top >= TEXTBOX.row * 8 and box.left <= 8 and box.right >= 152) then
							menuUp = true
							break
						end
					end
				end
				-- While a menu is up, hide under it and in the text-box rows: a chosen rule, matching no build exactly.
				if (boxOpen or menuUp) and sy + 16 > TEXTBOX.row * 8 and (menuUp or boxCovers(TEXTBOX.row * 8, 0)) then
					hidden = true
				end
				if uiOpen and lastMenuBox then
					-- A menu rectangle always hides (the game hides NPCs under menus by not drawing them, not by tile
					-- priority); the text box, the one rectangle characters are drawn through, hides only by its tiles.
					for _, box in ipairs(lastMenuBox) do
						if sx + 16 > box.left and sx < box.right
							and sy + 16 > box.top and sy < box.bottom then
							local isTextBox = box.top >= TEXTBOX.row * 8 and box.left <= 8 and box.right >= 152
							if not isTextBox or menuUp or boxCovers(box.top, box.left) then
								hidden = true
								break
							end
						end
					end
				end
				if hidden then
					nHidden = nHidden + 1
				else
					-- The stride is latched when the peer enters the stepping band and held until it leaves: the engine
					-- shows one image per burst while OBJECT_FACING counts through the step.
					-- A short gap still counts as walking: anim reads standing for two frames at the top of each step.
					o.idleFor = o.walking and 0 or ((o.idleFor or 99) + 1)
					-- A turn ends a burst, once the new facing has held for a frame: the wire's orientation can
					-- flicker for one.
					if o.facing ~= o.lastFacing and o.facing == o.facingSeen then
						-- Rearm, not just clear: the peer is usually walking when it turns, so the band would re-fire
						-- next frame and step straight out of the turn.
						o.lastFacing, o.idleFor, o.stepLatch, o.rearm = o.facing, 99, nil, true
					end
					-- Last frame's facing; lastFacing is the burst's and must not move on a flicker.
					o.facingSeen = o.facing
					-- The rearm ends at the peer's next real step; a pivot reads as not walking.
					if o.rearm and o.walking then
						o.rearm = nil
					end
					-- The legs run off the model, like the body: the wire's walking flag is a quarter second ahead.
					-- Window 2 because the model moves every other frame; a gap of three is a stop.
					local modelActive = o.modelMovedAt ~= nil
						and (drawFrames - o.modelMovedAt) <= 2
					local moving = (modelActive or o.walking or o.idleFor <= 3) and not o.rearm
					if moving and (peerProg <= 4 or peerProg >= 14) then
						if not o.stepLatch then
							o.stepLatch = ((o.face or 0) & 3) + 1 -- +1 so 0 is not falsy
						end
					else
						o.stepLatch = nil
					end
					-- Counted at the latch the renderer acts on, cumulatively, with its denominator: a per-frame count
					-- sampled once a second measures when the log fires. On facingFrames for Lua's 200-local ceiling.
					facingFrames.nDrawnFrames = (facingFrames.nDrawnFrames or 0) + 1
					if o.stepLatch then
						facingFrames.nStepDrawn = (facingFrames.nStepDrawn or 0) + 1
					end
					-- Why a stepping frame was refused. Idle first: rearm is set when a facing is first seen and only a
					-- real step clears it, so a ghost that never moved would otherwise count as held by a turn.
					if not o.stepLatch then
						if not o.walking and (o.idleFor or 99) > 3 then
							facingFrames.nNoStepIdle = (facingFrames.nNoStepIdle or 0) + 1
						elseif o.rearm then
							facingFrames.nNoStepRearm = (facingFrames.nNoStepRearm or 0) + 1
						else
							facingFrames.nNoStepMidStep = (facingFrames.nNoStepMidStep or 0) + 1
						end
					end
					-- Cadence trace: one character a frame per renderer, ghost beside player, so a burst of the wrong
					-- length shows in the log. Behind the stats gate: six strings grown a character a frame allocate.
					if facingFrames.stats() and o.only == "drawn" then
						-- Upper case is the stepping view, lower case standing, so one direction reads out of a walk.
						local mine = DIR_NAMES.letter[o.facing or 0] or "?"
						if o.stepLatch ~= nil then mine = mine:upper() end
						-- Inside the band but not stepping: `z` held by a turn, `x` judged not walking.
						if o.walking and o.stepLatch == nil and (peerProg <= 4 or peerProg >= 14) then
							mine = o.rearm and "z" or "x"
						end
						-- `!`: a side view flipped against its facing, the character looking back for a frame.
						local chosen = facingFrames.pick(o.facing, moving, peerProg,
							o.stepLatch and (o.stepLatch - 1) or 0)
						if chosen and (o.facing == 2 or o.facing == 3)
							and chosen[1].xflip ~= (o.facing == 3) then
							mine = "!"
						end
						-- The case reports the tile drawn, as the player's line does, not the latch that feeds it.
						if chosen and mine ~= "!" then
							local stepping = (chosen[1].offset & 0x80) ~= 0
							mine = stepping and mine:upper() or mine:lower()
						end
						local pf = readPlayerOamFrame()
						local theirs = "?"
						if pf then
							local pd = ((u8(OBJECT_STRUCTS + F_DIRECTION) or 0) // 4) & 3
							theirs = DIR_NAMES.letter[pd] or "?"
							if (pf[1].offset & 0x80) ~= 0 then theirs = theirs:upper() end
						end
						facingFrames.tPeer = (facingFrames.tPeer or "") .. mine
						facingFrames.tPlayer = (facingFrames.tPlayer or "") .. theirs
						-- The step progress the band is tested against, one column per frame.
						facingFrames.tProg = (facingFrames.tProg or "")
							.. string.sub("01234567", (peerProg // 2) % 8 + 1, (peerProg // 2) % 8 + 1)
						-- Screen delta on travel: `.` none, `+` 2px on, `-` 2px back (a snap), `<`/`>` more, `o` odd.
						local sdc = "."
						if facingFrames.lastPX then
							local vert = (o.facing == 0 or o.facing == 1)
							local sd = vert and (sy - facingFrames.lastPY)
								or (sx - facingFrames.lastPX)
							-- `x`: moved on the axis it is not walking along, which a walking character never does.
							local sp = vert and (sx - facingFrames.lastPX)
								or (sy - facingFrames.lastPY)
							if o.facing == 1 or o.facing == 2 then sd = -sd end
							if sp ~= 0 then sdc = "x"
							elseif sd ~= 0 then
								if (sd % 2) ~= 0 then sdc = "o"
								elseif sd == 2 then sdc = "+"
								elseif sd == -2 then sdc = "-"
								elseif sd > 2 then sdc = ">"
								else sdc = "<" end
							end
						end
						facingFrames.lastPX, facingFrames.lastPY = sx, sy
						facingFrames.tScreen = (facingFrames.tScreen or "") .. sdc
						-- Model, reference and camera deltas in the same columns: the screen delta is model minus
						-- reference under an independent camera, and the line that wobbles owns the fault.
						local function sdChar(d)
							if d == 0 then return "."
							elseif d == 2 then return "+"
							elseif d == -2 then return "-"
							else return "#" end
						end
						local vert2 = (o.facing == 0 or o.facing == 1)
						local md = vert2 and ((o.modelY or 0) - (facingFrames.lastMY or o.modelY or 0))
							or ((o.modelX or 0) - (facingFrames.lastMX or o.modelX or 0))
						local rrX = (aged.oamX or playerOamX) - ppx
						local rrY = (aged.oamY or playerOamY) - ppy
						local rd = vert2 and (rrY - (facingFrames.lastRY or rrY))
							or (rrX - (facingFrames.lastRX or rrX))
						if o.facing == 1 or o.facing == 2 then md, rd = -md, -rd end
						facingFrames.lastMX, facingFrames.lastMY = o.modelX, o.modelY
						facingFrames.lastRX, facingFrames.lastRY = rrX, rrY
						facingFrames.tModel = (facingFrames.tModel or "") .. sdChar(md)
						facingFrames.tRef = (facingFrames.tRef or "") .. sdChar(rd)
						facingFrames.tCam = (facingFrames.tCam or "")
							.. tostring(math.min(9, facingFrames.camDelta or 0))
						if #facingFrames.tPeer >= 60 then
							logFile("  cadence ghost  " .. facingFrames.tPeer)
							logFile("  cadence player " .. facingFrames.tPlayer)
							logFile("  cadence prog   " .. (facingFrames.tProg or ""))
							logFile("  cadence screen " .. (facingFrames.tScreen or ""))
							logFile("  cadence model  " .. (facingFrames.tModel or ""))
							logFile("  cadence ref    " .. (facingFrames.tRef or ""))
							logFile("  cadence cam    " .. (facingFrames.tCam or ""))
							facingFrames.tPeer, facingFrames.tPlayer = "", ""
							facingFrames.tProg, facingFrames.tScreen = "", ""
							facingFrames.tModel, facingFrames.tRef, facingFrames.tCam = "", "", ""
						end
					end
					if o.walking then
						facingFrames.nWalkFrames = (facingFrames.nWalkFrames or 0) + 1
						if peerProg < 6 or peerProg > 12 then
							facingFrames.nStepFrames = (facingFrames.nStepFrames or 0) + 1
						end
						facingFrames.progSeen = facingFrames.progSeen or {}
						facingFrames.progSeen[peerProg] = (facingFrames.progSeen[peerProg] or 0) + 1
					end
					if o.facing == nil then nNoFacing = nNoFacing + 1 end
					if UI_DEBUG and (boxOpen or uiOpen) and #paintedSamples < 8 then
						paintedSamples[#paintedSamples + 1] =
							string.format("%s@%d,%d", id, sx, sy)
					end
					-- COMPARE_TIERS only: where every copy went and where it thinks it is, which a count cannot say.
					if COMPARE_TIERS and drawFrames % 60 == 0 then
						-- The frame picker's three inputs, which tell a wrong frame from a peer judged not walking.
						logFile(string.format("  copy %-28s only=%-6s map %d,%d screen %d,%d "
							.. "facing=%s vram=%s walking=%s prog=%s face=%s",
							id, tostring(o.only), o.x, o.y, sx, sy, tostring(o.facing),
							tostring(source.vram), tostring(o.walking), tostring(o.prog),
							tostring(o.face)))
					end

					-- Painted jumps past 4px between frames (a smooth walk moves 2px). Ungated, to catch what nobody
					-- predicted, and bounded: forty named, then a count once a second.
					if o.paintedX and (math.abs(sx - o.paintedX) > 4 or math.abs(sy - o.paintedY) > 4) then
						facingFrames.twitches = (facingFrames.twitches or 0) + 1
						if facingFrames.twitches <= 40 then
							logFile(string.format("  TWITCH %-24s painted %d,%d -> %d,%d (%+d,%+d)",
								id, o.paintedX, o.paintedY, sx, sy, sx - o.paintedX, sy - o.paintedY))
							if facingFrames.twitches == 40 then
								logFile("  TWITCH: 40 reported -- further ones are counted only, "
									.. "summarised once a second")
							end
						elseif (facingFrames.twitchSaidAt or 0) + 60 <= drawFrames then
							facingFrames.twitchSaidAt = drawFrames
							logFile(string.format("  TWITCH: %d so far this session (still happening)",
								facingFrames.twitches))
						end
					end
					-- Loopback only: the ring entry matching the peer's tile and progress names the round trip, the
					-- floor on how late a ghost can start.
					if facingFrames.stats() and o.only == "drawn" and o.walking then
						local h = playerHistory
						for age = 0, h.size - 1 do
							local e = h[((h.n - age) % h.size) + 1]
							if e and e.tx == o.x - COMPARE.drawn and e.ty == o.y
								and e.prog == peerProg then
								facingFrames.lagSeen = facingFrames.lagSeen or {}
								facingFrames.lagSeen[age] = (facingFrames.lagSeen[age] or 0) + 1
								break
							end
						end
					end
					-- Every per-frame delta, per direction: a hitch at each tile boundary never trips the 4px detector.
					if o.paintedX and o.walking and facingFrames.stats() then
						facingFrames.stepDelta = facingFrames.stepDelta or {}
						local k = DIR_NAMES.letter[o.facing or 0] or "?"
						facingFrames.stepDelta[k] = facingFrames.stepDelta[k] or {}
						local d = math.abs(sx - o.paintedX) + math.abs(sy - o.paintedY)
						facingFrames.stepDelta[k][d] = (facingFrames.stepDelta[k][d] or 0) + 1
					end
					o.paintedX, o.paintedY = sx, sy

					-- What the peer is doing, computed once for both tiers so they cannot show different animations.
					local poseFacing, poseWalking, poseStride, poseHide, poseRod =
						facingFrames.pose(o.act, o.face, o.facing, moving,
							o.stepLatch and (o.stepLatch - 1) or 0)
					-- Move trace, pose half: what the ghost is shown doing, beside the inputs that decided it.
					if _G.MESHGHOST_CRYSTAL_MOVE_TRACE and o.only ~= "hw" then
						facingFrames.mvTrace(string.format("P %s act=%s face=%s wireDir=%s walk=%s idle=%s "
							.. "rearm=%s moving=%s -> dir=%s stepping=%s stride=%s",
							tostring(id), tostring(o.act), tostring(o.face), tostring(o.facing),
							tostring(o.walking), tostring(o.idleFor), tostring(o.rearm), tostring(moving),
							tostring(poseFacing), tostring(poseWalking), tostring(poseStride)))
					end
					-- A landing peer is drawn as the flying Pokemon's icon, as the engine hides the character; with no
					-- icon the peer is drawn as usual rather than vanishing.
					local flyIcon = o.drop and o.flyMon and facingFrames.iconGfx(o.flyMon) or nil
					if flyIcon then
						poseHide = true
					end
					-- The hardware tier first; if it declines the peer is painted, so no tier's refusal hides it.
					local onHardware = false
					if source.vram and o.only ~= "drawn" and not poseHide then
						onHardware = oam.place(sx, sy, source.vram, palette, poseFacing,
							poseWalking, peerProg, poseStride)
					end
					if onHardware then
						nOam = nOam + 1
					elseif o.only == "hw" then
						nOam = nOam -- pinned to a full rung: show nothing, or the comparison is a lie
					elseif flyIcon then
						-- The descent on the engine's own curve and its two frames of art (flyOffset, flyFrame).
						facingFrames.iconPaints = (facingFrames.iconPaints or 0) + 1
						local fdx, fdy = facingFrames.flyOffset(o.drop)
						local fbase, fflip = facingFrames.flyFrame(o.drop)
						nDrawn = nDrawn + 1
						for _, part in ipairs(facingFrames.ICON_BOX) do
							drawRows(decodeRomTile(flyIcon, fbase + part.t),
								sx + fdx + (fflip and (8 - part.dx) or part.dx), sy + fdy + part.dy,
								paletteColors(0), fflip)
						end
					elseif poseHide then
						nDrawn = nDrawn -- the engine draws nothing this frame (facing STANDING), nor do we
					else
						nDrawn = nDrawn + 1
						-- Hold the drawn copy at its first handover position: the engine object stays parked on its
						-- tile while the model walks on. Safe on o: during a handover renderRemote returns before
						-- rebuilding the entry.
						if o.handover then
							if not o.handoverSX then
								o.handoverSX, o.handoverSY = sx, sy
							end
							sx, sy = o.handoverSX, o.handoverSY
						end
						if stepLag.on and stepLag.traceUntil and drawFrames <= stepLag.traceUntil then
							-- The live OAM count on the same line: four more entries is the engine's copy arriving.
							local live = 0
							for e = 0, 39 do
								local ey = memory.read_u8(e * 4, "OAM") or 0
								if ey ~= 0 and ey < 160 then
									live = live + 1
								end
							end
							logFile(string.format("handover trace f=%d %s PAINTED at %d,%d "
								.. "(handover=%s, spawned=%s, oam=%d)", drawFrames, id, sx, sy,
								tostring(o.handover), tostring(ghosts[id] ~= nil), live))
							-- The raw OAM window, not a match verdict: read the mapping off the entries.
							local near = {}
							for e = 0, 39 do
								local ey = memory.read_u8(e * 4, "OAM") or 0
								local ex = memory.read_u8(e * 4 + 1, "OAM") or 0
								if ey ~= 0 and ey < 160 then
									near[#near + 1] = string.format("%d:%d,%d", e, ex, ey)
								end
							end
							logFile(string.format("  OAM f=%d expect x=%d y=%d | %s",
								drawFrames, sx + 8, sy + 16, table.concat(near, " ")))
						end
						local fishRom = poseRod and facingFrames.fishRom(o.sprite) or nil
						-- The emote box first, at the unbobbed position: it is a separate object and does not bob.
						local emoteRom = o.emote and facingFrames.emoteGfx(o.emote) or nil
						if emoteRom then
							local ec = paletteColors(5) -- PAL_OW_EMOTE, the box's own palette
							for _, part in ipairs(facingFrames.EMOTE_BOX) do
								drawRows(decodeRomTile(emoteRom, part.t),
									sx + part.dx, sy - 16 + part.dy, ec)
							end
						end
						-- The hop's shadow: before the yoff so it stays on the ground, and before the character
						-- because it is LOW_PRIORITY and draw order is this tier's priority. One tile, then mirrored.
						if o.jump and facingFrames.shadowRom then
							local sc = paletteColors(emote.PAL) -- PAL_OW_EMOTE, the shadow's own
							local sdy = emote.SHADOW_DY[poseFacing] or emote.SHADOW_DY[0]
							drawRows(decodeRomTile(facingFrames.shadowRom, 0), sx, sy + sdy, sc)
							drawRows(decodeRomTile(facingFrames.shadowRom, 0),
								sx + 8, sy + sdy, sc, true)
						end
						-- The engine adds OBJECT_SPRITE_Y_OFFSET to the screen y: the bite wiggle, a fall, a hop's arc.
						if o.yoff and o.yoff ~= 0 then
							sy = sy + o.yoff
						end
						drawCharacter(source, sx, sy, palette, poseFacing,
							poseWalking, peerProg, poseStride, fishRom, o.clo)
						if poseRod and fishRom then
							-- The rod, after the character as in the engine's OAM order, in the character's palette.
							local r = facingFrames.ROD[poseRod]
							if r then
								drawRows(decodeRomTile(fishRom, r.t),
									sx + r.dx, sy + r.dy, paletteColors(palette or 0, o.clo), r.flip)
							end
						end
					end
				end
			end
		end
	end

	-- Nothing painted: clear, or BizHawk's persisting overlay keeps the last frame (a promotion empties
	-- overflow). Keyed on nDrawn so the clear and the summary agree.
	if nDrawn == 0 then
		stopDrawing("nothing-drawn")
	end
	-- Per-frame counters for the XTRACE block: the per-second report prints them only on the frame it fires.
	if ENGINE.xmap.traceUntil and policyFrames <= ENGINE.xmap.traceUntil then
		facingFrames.dbgCounts = string.format("want=%d drawn=%d oam=%d noTile=%d off=%d hid=%d",
			nWanted, nDrawn, nOam, nNoTile, nOffScreen, nHidden)
	end

	if UI_DEBUG and (boxOpen or uiOpen or (u8(MENUBOX.bottom) or 0) > 0) and drawFrames % 15 == 0 then
		local rects = "none"
		if lastMenuBox then
			-- The whole list: one printed rectangle can hide a hole in the union.
			local parts = {}
			for _, box in ipairs(lastMenuBox) do
				parts[#parts + 1] = string.format("l=%d t=%d r=%d b=%d",
					box.left, box.top, box.right, box.bottom)
			end
			rects = table.concat(parts, " | ")
		end
		logFile(string.format("UI DEBUG: boxOpen=%s uiOpen=%s stale=%s coords=%d,%d,%d,%d corner=%s "
			.. "rect=%s wy=%d wx=%d "
			.. "-- %d painted, %d hidden; painted at: %s",
			tostring(boxOpen), tostring(uiOpen), tostring(TEXTBOX.stale),
			t or -1, l or -1, b or -1, r or -1, tostring(TEXTBOX.dbgCorner),
			rects,
			memory.read_u8(0xFF4A, "System Bus") or 0, memory.read_u8(0xFF4B, "System Bus") or 0,
			nDrawn, nHidden,
			(#paintedSamples > 0) and table.concat(paintedSamples, " ") or "(none)"))
	end

	-- Once, after 120 frames: did the hardware tier's entries reach the screen?
	oam.verify()

	-- Which ids each tier holds, and any peer in both at once, which is that peer drawn twice.
	if drawFrames % 60 == 0 then
		local spawnedIds, paintedIds, both = {}, {}, {}
		for gid in pairs(ghosts) do
			spawnedIds[#spawnedIds + 1] = gid
		end
		for oid in pairs(overflow) do
			paintedIds[#paintedIds + 1] = oid
			if ghosts[oid] then
				both[#both + 1] = oid
			end
		end
		if #both > 0 then
			logFile("DOUBLE-RENDERED: " .. table.concat(both, ", ")
				.. " -- in BOTH tiers this frame, so that peer is on screen twice")
		end
		if #spawnedIds > 0 or #paintedIds > 0 then
			logFile(string.format("  holding: spawned{%s} painted{%s}",
				table.concat(spawnedIds, ","), table.concat(paintedIds, ",")))
		end
	end

	if drawFrames % 60 == 0 and nWanted > 0 then
		logFile(string.format("tiers: %d on hardware. "
			.. "drawn tier: %d peers waiting, %d drawn (%d from the cartridge), "
			.. "%d no sprite tiles, %d off screen, %d hidden by UI, %d spawned as real objects; "
			.. "stepping view drawn on %d of %d peer-frames so far, %d with no facing yet%s",
			nOam, nWanted, nDrawn, nFromRom, nNoTile, nOffScreen, nHidden, ghostCount(),
			facingFrames.nStepDrawn or 0, facingFrames.nDrawnFrames or 0, nNoFacing,
			(function()
				local w = facingFrames.stopWhy
				if not w then return "" end
				local parts = {}
				for k, v in pairs(w) do parts[#parts + 1] = string.format("%s:%d", k, v) end
				table.sort(parts)
				return "; NOT DRAWN because -- " .. table.concat(parts, " ")
			end)()))
		-- Lag in pixels and frames spent catching up, the shape of a glide, readable without the stats rig.
		if nDrawn > 0 then
			logFile(string.format("  model pacing: furthest behind %dpx (a step is 16px), "
				.. "%d catch-up frames",
				facingFrames.modelMax or 0, facingFrames.catchupFrames or 0))
			-- A bin that is not a whole gait stride means a sample landed mid-scroll.
			if facingFrames.camHist then
				local b = {}
				for px = 0, 16 do
					local n = facingFrames.camHist[px]
					if n then
						b[#b + 1] = string.format("%dpx:%d", px, n)
					end
				end
				logFile("  camera deltas: " .. table.concat(b, " "))
			end
		end
		-- Only once a resync has fired, so a clean run stays silent.
		if (facingFrames.modelSnaps or 0) > 0 then
			logFile(string.format("  model resyncs: %d so far, worst %dpx past the 24px threshold "
				.. "-- each one is a painted peer being ASSIGNED its position rather than walked "
				.. "there, which is a snap on screen",
				facingFrames.modelSnaps, (facingFrames.modelSnapPx or 0) - 24))
		end
		if facingFrames.lagSeen then
			local l, tot, sum = {}, 0, 0
			for age = 0, 15 do
				local c = facingFrames.lagSeen[age]
				if c then
					l[#l + 1] = string.format("%df:%d", age, c)
					tot = tot + c
					sum = sum + age * c
				end
			end
			logFile(string.format("  loopback round trip, matched against the player's own history:"
				.. " %s   (mean %.1f frames -- the floor for how late a ghost can start)",
				table.concat(l, " "), (tot > 0) and (sum / tot) or 0))
		end
		if facingFrames.stepDelta then
			for _, k in ipairs({ "d", "u", "l", "r" }) do
				local per = facingFrames.stepDelta[k]
				if per then
					local d, tot, bad = {}, 0, 0
					for v = 0, 32 do
						if per[v] then
							d[#d + 1] = string.format("%dpx:%d", v, per[v])
							tot = tot + per[v]
							if v > 0 then bad = bad + per[v] end
						end
					end
					-- Loopback at interp 0 tracks the player exactly, so any non-zero bucket is the defect.
					logFile(string.format("  painted movement, facing %s: %s   (%d of %d frames "
						.. "moved relative to the player)", k, table.concat(d, " "), bad, tot))
				end
			end
		end
		-- Every prog a walking peer arrived at: the frame is a function of prog, so mid-step only means standing.
		if facingFrames.progSeen then
			local seen = {}
			for v = 0, 16 do
				if facingFrames.progSeen[v] then
					seen[#seen + 1] = string.format("%d:%d", v, facingFrames.progSeen[v])
				end
			end
			logFile(string.format("  peer step progress, all frames: %d walking, %d of them in the "
				.. "stepping band | prog counts %s", facingFrames.nWalkFrames or 0,
				facingFrames.nStepFrames or 0, table.concat(seen, " ")))
		end
		-- Outside the guard above, so a run where the ghost never stepped still prints.
		if (facingFrames.nDrawnFrames or 0) > 0 then
			logFile(string.format("  MODEL walk: furthest behind its destination %.0fpx (a step is "
				.. "16px), %d resyncs, "
				.. "%d beat corrections, %d catch-up frames, %d of them free-running at rest"
				.. " | K drift %dpx over %d parks (worst %dpx), %dpx repaid on %d nudge frames,"
				.. " %d direction reversals"
				.. " | %d camera rebases",
				facingFrames.modelMax or 0, facingFrames.modelSnaps or 0,
				facingFrames.phaseFollow or 0,
				facingFrames.catchupFrames or 0, facingFrames.freeCatchup or 0,
				facingFrames.kParkSum or 0, facingFrames.kParks or 0,
				facingFrames.kParkMax or 0, facingFrames.kFix or 0,
				facingFrames.kNudges or 0, facingFrames.kFlips or 0,
				facingFrames.camRebase or 0))
			-- By direction of travel, on its own line.
			if facingFrames.kParkDir then
				local ds = {}
				-- Keys from DIR_NAMES.letter (lowercase initials): a hand-typed key silently matches nothing.
				for i = 0, 3 do
					local dl = DIR_NAMES.letter[i]
					local b = facingFrames.kParkDir[dl]
					if b then
						ds[#ds + 1] = string.format("%s %d parks avg %.1fpx worst %dpx",
							dl, b.n, b.sum / b.n, b.max)
					end
				end
				if #ds > 0 then
					logFile("  K drift by direction of travel: " .. table.concat(ds, " | "))
				end
			end
			-- wantK must hold while the camera is parked; kFrac says if a fractional model breaks the cancellation.
			logFile(string.format("  K target moved on %d parked frames, model was fractional on %d"
				.. " (target should be CONSTANT while parked -- if it is not, the paint's"
				.. " modelX cancellation is not exact or a 'constant' term is moving)",
				facingFrames.kWantMoves or 0, facingFrames.kFrac or 0))
			-- Camera sampling gaps: anything but 1 is scrolling never seen, absorbed or folded into one delta.
			if facingFrames.camGap then
				local gs = {}
				for g = 1, 25 do
					if facingFrames.camGap[g] then
						gs[#gs + 1] = string.format("%s%d frame%s:%d", g == 25 and ">" or "",
							g, g == 1 and "" or "s", facingFrames.camGap[g])
					end
				end
				logFile("  camera sampling gaps (1 = every frame, anything more is motion never "
					.. "seen): " .. table.concat(gs, " "))
			end
			-- Which term moved on those parked frames; camA moving means this branch ran when it should not.
			logFile(string.format("    of those, the term that moved was: player OAM %d,"
				.. " player tile %d, step progress %d, camera accumulator %d",
				facingFrames.kTOamN or 0, facingFrames.kTTileN or 0,
				facingFrames.kTPpxN or 0, facingFrames.kTCamN or 0))
			-- Rejected deltas: one pair about once per park is a mechanism misclassified, not a rebase.
			if facingFrames.camRebaseD then
				local rs = {}
				for k, v in pairs(facingFrames.camRebaseD) do
					rs[#rs + 1] = string.format("%s:%d", k, v)
				end
				table.sort(rs)
				logFile("  camera moves REJECTED as implausible (absorbed, never painted): "
					.. table.concat(rs, " "))
			end
			-- wPlayerBGMapOffset is a per-frame delta and hSCX/hSCY the scroll: a disagreement mis-clocks the model.
			if (facingFrames.hN or 0) > 0 then
				logFile(string.format("  CAMERA REGISTER AUDIT: %d frames compared, %d agree"
					.. " (dOff == -dHSC), %d DISAGREE, %d unreadable",
					facingFrames.hN or 0, facingFrames.hAgree or 0,
					facingFrames.hDis or 0, facingFrames.hNoRead or 0))
				if facingFrames.hD then
					local hs, i = {}, 0
					for k, v in pairs(facingFrames.hD) do
						i = i + 1
						if i <= 12 then hs[#hs + 1] = string.format("[%s] x%d", k, v) end
					end
					table.sort(hs)
					logFile("    disagreements (up to 12 shapes): " .. table.concat(hs, " "))
				end
			elseif (facingFrames.hNoRead or 0) > 0 then
				logFile(string.format("  CAMERA REGISTER AUDIT: hSCX/hSCY UNREADABLE on %d frames"
					.. " -- the System Bus domain name or the addresses are wrong, so this audit"
					.. " says nothing", facingFrames.hNoRead))
			end
			-- The camera's own per-frame movement, histogrammed: the clock the model mirrors.
			if facingFrames.camD then
				local cds = {}
				for v = 1, 8 do
					if facingFrames.camD[v] then
						cds[#cds + 1] = string.format("%dpx:%d", v, facingFrames.camD[v])
					end
				end
				logFile("  CAMERA per-frame deltas: " .. table.concat(cds, " "))
				if facingFrames.camSign then
					local ss = {}
					for k, v in pairs(facingFrames.camSign) do
						ss[#ss + 1] = string.format("%s:%d", k, v)
					end
					table.sort(ss)
					logFile("  CAMERA signs by walk dir: " .. table.concat(ss, " "))
				end
			end
			-- One parity should dominate, or locking the ghost to it means nothing.
			if facingFrames.ghostGap or facingFrames.playerGap then
				local function gaps(t)
					local o2 = {}
					for v = 1, 8 do
						if t and t[v] then o2[#o2 + 1] = string.format("%d:%d", v, t[v]) end
					end
					return table.concat(o2, " ")
				end
				logFile(string.format("  RHYTHM, frames between moves | player %s | ghost %s",
					gaps(facingFrames.playerGap), gaps(facingFrames.ghostGap)))
			end
			if facingFrames.paritySeen then
				logFile(string.format("  ENGINE tick parity: even %d, odd %d (locked to %d) | "
					.. "ghost lead over the peer %s",
					facingFrames.paritySeen[0] or 0, facingFrames.paritySeen[1] or 0,
					facingFrames.tickParity or -1,
					(function()
						local t = {}
						for v = -8, 8 do
							if facingFrames.lead and facingFrames.lead[v] then
								t[#t + 1] = string.format("%+d:%d", v, facingFrames.lead[v])
							end
						end
						return table.concat(t, " ")
					end)()))
			end
			-- The two 1px candidates, side by side with the quantised value they would replace.
			if facingFrames.scrollD or facingFrames.oamD then
				local function hist(t)
					local o2 = {}
					for v = 0, 6 do
						if t and t[v] then o2[#o2 + 1] = string.format("%d:%d", v, t[v]) end
					end
					return table.concat(o2, " ")
				end
				logFile(string.format("  1PX SOURCE | bg scroll Y moved %s | player OAM Y moved %s",
					hist(facingFrames.scrollD), hist(facingFrames.oamD)))
			end
			if facingFrames.refD then
				for _, key in ipairs({ "v", "h" }) do
					local rr, gg = {}, {}
					for v = 0, 6 do
						local r = facingFrames.refD[key] and facingFrames.refD[key][v]
						local g = facingFrames.ghostD[key] and facingFrames.ghostD[key][v]
						if r then rr[#rr + 1] = string.format("%d:%d", v, r) end
						if g then gg[#gg + 1] = string.format("%d:%d", v, g) end
					end
					if #rr > 0 or #gg > 0 then
						logFile(string.format("  TERMS %s | player reference moved %s | ghost moved %s",
							(key == "v") and "walking up/down " or "walking left/right",
							table.concat(rr, " "), table.concat(gg, " ")))
					end
				end
			end
			-- What was drawn, against the step progress above: the gap is the renderer refusing, by reason.
			logFile(string.format("  stepping view drawn on %d of %d peer-frames; not stepped: "
				.. "%d mid-step, %d idle, %d held by a turn",
				facingFrames.nStepDrawn or 0, facingFrames.nDrawnFrames or 0,
				facingFrames.nNoStepMidStep or 0, facingFrames.nNoStepIdle or 0,
				facingFrames.nNoStepRearm or 0))
		end
		-- Reported cumulatively, so it describes the run, not whichever second it fired in.
		if facingFrames.wire and facingFrames.wire.msgs > 0 then
			local w = facingFrames.wire
			local d = {}
			for v = 1, 9 do
				if w.dist[v] then
					d[#d + 1] = string.format("%s:%d", (v == 9) and ">=9px" or (v .. "px"), w.dist[v])
				end
			end
			logFile(string.format("  WIRE: %d messages, %d carried no movement, %d moved | %s",
				w.msgs, w.same, w.moved, table.concat(d, " ")))
			-- Arrivals per rendered frame: a 0 then a 2 paints nothing and then skips a pixel, the stutter.
			if w.perFrame then
				local pf, tot = {}, 0
				for v = 0, 6 do
					if w.perFrame[v] then
						pf[#pf + 1] = string.format("%d:%d", v, w.perFrame[v])
						tot = tot + w.perFrame[v]
					end
				end
				logFile(string.format("  ARRIVALS per rendered frame over %d frames: %s",
					tot, table.concat(pf, " ")))
			end
			-- Quarter-pixel buckets and a mean: the player walks whole pixels, and a fractional peer is rounded.
			if w.fine and w.nmoved and w.nmoved > 0 then
				local fq = {}
				for v = 0, 20 do
					if w.fine[v] then
						fq[#fq + 1] = string.format("%.2f:%d", v / 4, w.fine[v])
					end
				end
				logFile(string.format("  WIRE sub-pixel: %d moves under 5px, mean %.3f px/frame | %s"
					.. " | %d jumps over 5px, largest %.1fpx",
					w.nmoved, w.sum / w.nmoved, table.concat(fq, " "),
					w.big or 0, w.max or 0))
			end
		end
		if offSample then
			logFile("drawn tier: example of one it discarded -- " .. offSample)
		end
	end
end

-- The inverse of DIR_NAMES: a peer sends orientation as a name, and we need the numeric dir.
local ORIENTATION_TO_DIR = { down = 0, up = 1, left = 2, right = 3 }

local DELTA_TO_DIR = { ["0,1"] = 0, ["0,-1"] = 1, ["-1,0"] = 2, ["1,0"] = 3 }

-- The OBJECT_ACTION values a peer may set; anything else is ignored, since this one ends in a memory write.
ACTIONS.peer = {
	[1] = true, -- OBJECT_ACTION_STAND
	[2] = true, -- OBJECT_ACTION_STEP
	[3] = true, -- OBJECT_ACTION_BUMP          (walking into a wall)
	[4] = true, -- OBJECT_ACTION_SPIN          (spin tiles)
	[5] = true, -- OBJECT_ACTION_SPIN_FLICKER  (the teleport/dig spin)
	[6] = true, -- OBJECT_ACTION_FISHING
	[16] = true, -- OBJECT_ACTION_SKYFALL      (the Fly landing)
}
-- OBJECT_ACTION_EMOTE (8) is absent: the "!" is a separate map object (ENGINE.playerEmote), not a pose.

-- Give the ghost the peer's action byte and let the engine animate it: the action selects the pose, and
-- an OBJECT_FACING write would be overwritten before it is drawn. Safe to leave written while the ghost is idle.
local function applyPeerAction(g, act)
	if act == nil or not ACTIONS.peer[act] then
		return
	end
	if u8(g.st_base + F_ACTION) ~= act then
		w8(g.st_base + F_ACTION, act)
	end

	-- And stop the engine undoing it: an idle ghost's standing movement resets the action and sets step
	-- type 5 (RESTORE) each tick. Step type 4 touches only OBJECT_WALKING; pinned only while already idle.
	if u8(g.st_base + F_WALKING) == STANDING then
		local st = u8(g.st_base + F_STEP_TYPE)
		if st == 1 or st == 5 then -- FROM_MOVEMENT, RESTORE: the two that reach MovementFunction_Standing
			w8(g.st_base + F_STEP_TYPE, 4) -- STEP_TYPE_STANDING
		end
	end
end

-- The hop's shadow as a real map object, built as the engine builds its own: a ghost's hop is written
-- straight into its step type and so never spawns one. The engine then runs it.
-- OBJECT_RANGE is an object-struct index, as its consumer reads it, not a map-object one.
emote.shadow = function(g)
	local st = freeStruct()
	if not st then
		return -- no free struct: the hop goes on without a shadow
	end
	local b = OBJECT_STRUCTS + st * OBJECT_LENGTH
	-- Zeroed first: freeStruct only promises a clear sprite byte, and the engine is about to run this.
	for off = 0, OBJECT_LENGTH - 1 do
		w8(b + off, 0)
	end
	w8(b + F_SPRITE, 0xFF)
	w8(b + F_MAP_OBJECT_INDEX, 0xFF)
	w8(b + 0x02, 0x00) -- OBJECT_SPRITE_TILE
	w8(b + 0x03, 0x1B) -- OBJECT_MOVEMENT_TYPE = SPRITEMOVEDATA_SHADOW
	w8(b + F_FLAGS1, 0x8E)
	w8(b + 0x05, 0x01) -- OBJECT_FLAGS2 = LOW_PRIORITY
	w8(b + F_PALETTE, emote.PAL)
	w8(b + F_FACING, STANDING)
	local sx, sy = u8(g.st_base + F_MAP_X) or 0, u8(g.st_base + F_MAP_Y) or 0
	for _, off in ipairs({ F_MAP_X, F_LAST_MAP_X, F_INIT_X }) do
		w8(b + off, sx)
	end
	for _, off in ipairs({ F_MAP_Y, F_LAST_MAP_Y, F_INIT_Y }) do
		w8(b + off, sy)
	end
	w8(b + 0x20, g.st) -- OBJECT_RANGE: the struct this shadow tracks
	-- Last, because it starts the object running.
	w8(b + F_STEP_TYPE, 0) -- STEP_TYPE_RESET
end

local function stepGhost(g, dir, gait, jumping)
	local x = (u8(g.st_base + F_MAP_X) or 0) + ((dir == 3) and 1 or (dir == 2) and -1 or 0)
	local y = (u8(g.st_base + F_MAP_Y) or 0) + ((dir == 0) and 1 or (dir == 1) and -1 or 0)

	-- Re-pinned per step: it sets the facing the engine restores when the step ends.
	setGhostStanding(g.st_base, g.mo_base, dir)

	-- The peer's gait as the engine's own group and duration. ENGINE.gait clamps to a group this ROM has:
	-- GetStepVector indexes its table unchecked, and past the end reads other bytes as a vector.
	local group = ENGINE.gait(gait)
	w8(g.st_base + F_WALKING, group * 4 + dir)
	w8(g.st_base + F_DIRECTION, dir * 4)
	w8(g.st_base + F_FACING, dir * 4)
	-- Step type 2, not the player's 6: type 6 scrolls the camera.
	w8(g.st_base + F_STEP_TYPE, 2)
	-- GAIT_TICKS ticks of the gait's step vector cover the 16px tile exactly.
	w8(g.st_base + F_STEP_DURATION, GAIT_TICKS[group])
	w8(g.st_base + F_ACTION, 2)
	w8(g.st_base + F_MAP_X, x)
	w8(g.st_base + F_MAP_Y, y)

	-- A ledge hop is the engine's own NPC jump (8), which crosses both tiles and makes the whole arc; never
	-- the player's 9, which the camera follows. The step index is zeroed so it starts at the jump.
	if jumping then
		w8(g.st_base + emote.F_JUMP_HEIGHT, 0)
		w8(g.st_base + emote.F_STEP_INDEX, 0)
		w8(g.st_base + F_STEP_TYPE, 8)
		emote.shadow(g)
	end

	-- Read OBJECT_WALKING back: STANDING under a walking step type indexes past StepVectors every frame and sends
	-- the ghost off screen. Silent unless the two disagree.
	local back = u8(g.st_base + F_WALKING)
	if back ~= 4 + dir then
		log(string.format("MeshGhost: WROTE WALKING=%d TO STRUCT %d AND IT READS BACK %s "
			.. "(step_type=%s duration=%s). The engine walks on the step type, so this is the "
			.. "state that sends a ghost off the screen.",
			4 + dir, g.st, tostring(back), tostring(u8(g.st_base + F_STEP_TYPE)),
			tostring(u8(g.st_base + F_STEP_DURATION))))
	end
end

-- How often a ghost was snapped rather than walked: a teleport is the only discontinuous move. Logged
-- once a second, only when non-zero.
local snaps = { n = 0, at = 0, runaways = 0 }

local function teleportGhost(g, x, y)
	-- A warp's path is not walkable: drop the queue, or the ghost walks back to where the peer was.
	g.path, g.pathX, g.pathY = nil, nil, nil
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
	local sx, sy = liveScreenCoords(x, y)
	w8(g.st_base + F_SPRITE_X, sx)
	w8(g.st_base + F_SPRITE_Y, sy)
end

-- Each new peer tile is queued and walked in order, so the ghost visits the tile a peer turned on before
-- following it back. Past 3 entries the ghost is a step chain behind and the queue is dropped.
-- On facingFrames with a literal cap, for Lua's 200-local ceiling.
function facingFrames.pathGoal(g, x, y, cx, cy)
	local q = g.path
	if g.pathX ~= x or g.pathY ~= y then
		-- A new target: queue the previous one if the ghost has not reached it yet.
		if g.pathX ~= nil and (g.pathX ~= cx or g.pathY ~= cy)
			and math.abs(g.pathX - x) + math.abs(g.pathY - y) == 1 then
			q = q or {}
			q[#q + 1] = { g.pathX, g.pathY }
			g.path = q
		end
		g.pathX, g.pathY = x, y
	end
	if q then
		-- Drop reached and stale entries from the front.
		while q[1] and ((q[1][1] == cx and q[1][2] == cy)
			or (q[1][1] == x and q[1][2] == y)) do
			table.remove(q, 1)
		end
		if #q > 3 then
			g.path = nil -- too far behind: the deficit paths below want the live target
		elseif q[1] then
			return q[1][1], q[1][2]
		end
	end
	return x, y
end

-- True while the drawn copy must be kept: until the engine object's own OAM entries appear at the
-- latched position (+8, +16), at most 8 frames, so an object that never appears cannot pin it.
local function holdHandover(o)
	if not (o and o.handover) then
		return false
	end
	if drawFrames - o.handover > 8 then
		return false
	end
	if not o.handoverSX then
		-- The draw loop takes the latch and may not have run yet: no position means not arrived.
		return true
	end
	-- Within 8px per axis, not exact: a peer promoted while moving steps away from the latch at once.
	local wx, wy = o.handoverSX + 8, o.handoverSY + 16
	for e = 0, 39 do
		local ex = memory.read_u8(e * 4 + 1, "OAM") or 0
		local ey = memory.read_u8(e * 4, "OAM") or 0
		if math.abs(ex - wx) <= 8 and math.abs(ey - wy) <= 8 then
			return false
		end
	end
	return true
end

-- Inbound state is peer-controlled: every number is bounded before it reaches a memory write.
local function renderRemote(id, state)
	if not inPlay() or type(state) ~= "table" then
		return
	end
	if state.extras ~= nil and type(state.extras) ~= "table" then
		-- Every extras read below indexes it; a number or boolean would raise inside the frame.
		state.extras = nil
	end
	local pos = state.position
	if type(pos) ~= "table" or type(pos[1]) ~= "number" or type(pos[2]) ~= "number" then
		return
	end

	-- A peer on a connected map is rewritten into our tile frame here (state is freshly decoded), so
	-- everything below sees local coordinates; a peer elsewhere keeps its area and is hidden below.
	if ENGINE.xmap.armed() and state.area_id ~= nil then
		local here = areaId()
		if ENGINE.xmap.connsFor ~= here then
ENGINE.xmap.build(here) end
		if state.area_id ~= here then
			local tx, ty = ENGINE.xmap.translate(state.area_id, pos[1], pos[2])
			if tx then
				-- The pixel pair [3],[4] carries the smooth motion and moves by the same delta, taken before [1],[2]
				-- are overwritten.
				local dx, dy = tx - pos[1], ty - pos[2]
				if type(pos[3]) == "number" then pos[3] = pos[3] + dx * 16 end
				if type(pos[4]) == "number" then pos[4] = pos[4] + dy * 16 end
				-- Once per peer per map pair, never per frame: the line that says the feature is live.
				local k = id .. "|" .. state.area_id .. "|" .. here
				if not ENGINE.xmap.said[k] then
					ENGINE.xmap.said[k] = true
					-- %s, not %d: a fractional tile makes Lua 5.4's %d raise inside the frame.
					log(string.format("cross-map: %s is on %s, %s,%s -- translated to %s,%s on"
						.. " our %s (via its %s connection)", id, state.area_id, pos[1], pos[2],
						tx, ty, here,
						(ENGINE.xmap.conns[state.area_id] or {}).dir or "?"))
				end
				state.area_id, pos[1], pos[2] = here, tx, ty
			end
		end
	end
	-- When we last heard from this peer: tick() forgets peers that stop sending.
	local a = activity[id]
	if not a then
		a = { x = -1, y = -1, movedAt = policyFrames, passableUntil = 0 }
		activity[id] = a
	end
	a.seenAt = policyFrames

	-- Wire instrument: how the peer's position changes between messages as they arrive, before any tier,
	-- with unchanged messages counted beside the changed ones.
	if facingFrames.stats() then
		local w = facingFrames.wire
		if not w then
			w = { msgs = 0, same = 0, moved = 0, dist = {} }
			facingFrames.wire = w
		end
		w.msgs = w.msgs + 1
		-- Messages per rendered frame, empty frames included: the core interpolates on wall-clock and the
		-- emulator renders on its own, so a 0 then a 2 paints a stutter out of smooth data.
		local wf = emu.framecount()
		if w.frame ~= wf then
			if w.frame then
				w.perFrame = w.perFrame or {}
				local n = w.inFrame or 0
				w.perFrame[n] = (w.perFrame[n] or 0) + 1
				-- The frames that received nothing, counted from the gap in frame numbers.
				local gap = wf - w.frame - 1
				if gap > 0 and gap < 600 then
					w.perFrame[0] = (w.perFrame[0] or 0) + gap
				end
			end
			w.frame, w.inFrame = wf, 0
		end
		w.inFrame = (w.inFrame or 0) + 1
		local px = (type(pos[3]) == "number") and pos[3] or (pos[1] * 16)
		local py = (type(pos[4]) == "number") and pos[4] or (pos[2] * 16)
		if w.lx then
			local d = math.abs(px - w.lx) + math.abs(py - w.ly)
			-- Quarter-pixel buckets and the mean speed: an interpolated peer moves a fractional pixel a frame and
			-- is rounded on screen, so a mean unlike the player's pixels-per-frame is the defect.
			if d >= 0.01 then
				w.fine = w.fine or {}
				local fk = math.floor(d * 4 + 0.5)
				-- Outliers past 5px are counted apart with the largest: a clamped bucket must not feed the mean.
				if fk > 20 then
					w.big = (w.big or 0) + 1
					w.max = math.max(w.max or 0, d)
				else
					w.fine[fk] = (w.fine[fk] or 0) + 1
					w.sum = (w.sum or 0) + d
					w.nmoved = (w.nmoved or 0) + 1
				end
			end
			if d < 0.5 then
				w.same = w.same + 1
			else
				w.moved = w.moved + 1
				-- An integer key: the report loops over integers and would never read a float one.
				local k = math.floor(d + 0.5)
				if k < 1 then k = 1 end
				if k > 9 then k = 9 end -- 9 means "9px or more", i.e. a jump
				w.dist[k] = (w.dist[k] or 0) + 1
			end
		end
		w.lx, w.ly = px, py
	end
	-- The peer's position in map pixels, interpolated with the tile; nil from a peer that does not send it,
	-- and the drawn tier falls back to extras.prog.
	local peerPixX = (type(pos[3]) == "number") and pos[3] or nil
	local peerPixY = (type(pos[4]) == "number") and pos[4] or nil
	-- COMPARE.dy, applied once at the source every tier reads; the tile-level y below matches it.
	if COMPARE_TIERS and peerPixY and id:match("%-ghost$") then
		peerPixY = peerPixY + COMPARE.dy * 16
	end
	-- The peer's gait group, a normal walk when absent (an older client).
	local peerGait = state.extras and tonumber(state.extras.gait) or 1
	local peerProg = state.extras and tonumber(state.extras.prog) or nil
	-- Floored and bounded: prog (0-16 px) reaches //, %, string.sub and a table index, where a NaN or a
	-- fraction raises; gait (0-3) falls back to a normal walk, as an absent one does.
	if peerProg then
		if peerProg ~= peerProg or peerProg == math.huge or peerProg == -math.huge then
			peerProg = nil
		else
			peerProg = math.floor(peerProg)
			if peerProg < 0 then peerProg = 0 elseif peerProg > 16 then peerProg = 16 end
		end
	end
	if peerGait ~= peerGait or peerGait == math.huge or peerGait == -math.huge then
		peerGait = 1
	else
		peerGait = math.floor(peerGait)
		if peerGait < 0 or peerGait > 3 then peerGait = 1 end
	end
	local peerPal = state.extras and tonumber(state.extras.pal) or nil -- nil from an older peer
	local peerClo = state.extras and tonumber(state.extras.clo) or nil -- the same, see paletteColors
	-- pal and clo reach `&` (paletteColors, oam.place, bgr555), where a fraction or an infinity raises in
	-- Lua 5.4; drawOverflow has no pcall, so one bad value would stop the drawn tier for every peer.
	if peerPal then
		if peerPal ~= peerPal or peerPal == math.huge or peerPal == -math.huge then
			peerPal = nil
		else
			peerPal = math.floor(peerPal) & 0x07
		end
	end
	if peerClo then
		if peerClo ~= peerClo or peerClo == math.huge or peerClo == -math.huge then
			peerClo = nil
		else
			peerClo = math.floor(peerClo) & 0x7FFF
		end
	end
	local peerWalking = (state.anim == "walk")
	-- Only the low two bits are used; the whole byte is carried so a log shows the direction too. Floored
	-- and kept to a byte before any `&`, for the reason above.
	local peerFace = state.extras and tonumber(state.extras.face) or nil
	if peerFace then
		-- Non-finite first: math.floor(1/0) is still non-finite, and // on it raises too.
		if peerFace ~= peerFace or peerFace == math.huge or peerFace == -math.huge then
			peerFace = nil
		else
			peerFace = math.floor(peerFace) % 256
		end
	end
	-- A question, not the peer's step type: the receiver writes NPC_JUMP (8), never the camera's 9.
	local peerJump = state.extras and state.extras.jump and true or false
	-- The engine's own vertical nudge, signed; nil from an older build.
	local peerYoff = state.extras and tonumber(state.extras.yoff) or nil
	if peerYoff and peerYoff > 127 then peerYoff = peerYoff - 256 end
	-- Clamped to -96..96, the whole range the game writes to this byte, once so both tiers get the same
	-- value; it ends in a memory write on the spawned tier.
	if peerYoff then
		peerYoff = math.floor(peerYoff)
		if peerYoff > 96 then peerYoff = 96 elseif peerYoff < -96 then peerYoff = -96 end
	end
	local peerEmote = state.extras and tonumber(state.extras.emote) or nil
	-- The peer's OBJECT_ACTION, floored here and checked against ACTIONS.peer at the write. Declared above
	-- the drawn tier's entries: a local used above its declaration is a silent nil global.
	local peerActRaw = state.extras and tonumber(state.extras.act) or nil
	local peerAct = peerActRaw and math.floor(peerActRaw) or nil

	local isLoopback = id:match("%-ghost$") ~= nil
	local baseX = math.floor(pos[1])
	-- Loopback only, so an echo of yourself is not hidden underneath you.
	local offsetX = isLoopback and LOOPBACK_OFFSET_X or 0
	-- Compare mode overrides the loopback offset outright: the copies' placement is the point of it.
	if COMPARE_TIERS and isLoopback then offsetX = COMPARE.spawned end
	local x, y = baseX + offsetX, math.floor(pos[2])
	if COMPARE_TIERS and isLoopback then y = y + COMPARE.dy end
	-- Only a sanity bound: a translated peer can sit at negative coordinates (one tile past the west seam
	-- is x = -1). The u8 limit is on the spawned tier (inOurMap); the range cull below is the real one.
	local lo, hi = 0, 255
	if ENGINE.xmap.armed() then lo, hi = -160, 415 end
	if x < lo or x > hi or y < lo or y > hi then
		return
	end


	-- STEP_LAG arrive, loopback only: the peer's tile as it reaches us against the frame the player took
	-- it. Before every gate below, since a tile declined here is the delay being measured.
	if stepLag.on and isLoopback then
		local key = baseX .. "," .. y
		if stepLag.seen[id] ~= key then
			stepLag.seen[id] = key
			local at = stepLag.commit[key]
			if at then
				local now = emu.framecount()
				stepLag.open[id] = { at = now, wire = now - at, commit = at }
			else
				-- The player never took this tile: the ring forgot it or offsetX is not as assumed. Counted, not used.
				stepLag.open[id] = nil
				stepLag.unknown = stepLag.unknown + 1
			end
		end
	end

	-- A peer in another area has no position here, in either tier.
	if state.area_id ~= areaId() then
		despawnGhost(id)
		overflow[id] = nil
		overflow[COMPARE.key(id)] = nil
		overflow[COMPARE.hwKey(id)] = nil
		return
	end

	-- A peer arriving by Fly lands: extras.entry is its MAPSETUP byte ($FC is MAPSETUP_FLY), and the drop
	-- arms once per flag-wearing. extras.fly is the species that carried it.
	local peerFly = state.extras and tonumber(state.extras.fly) or nil
	-- Armed below the area gate and once the world settles, so t=0 is the first renderable frame here.
	local peerEntry = state.extras and tonumber(state.extras.entry) or nil
	-- A map reload while the flag is worn is itself a landing: a same-town fly can land on the tile it
	-- left. A remote peer flying tile-to-same-tile in our view has no signal and gets no drop.
	if peerEntry == 0xFC and (playerHistory.settle or 0) > 0 then
		a.flyPending = true
	end
	if peerEntry == 0xFC and not a.dropDone and (playerHistory.settle or 0) == 0 then
		-- A tile jump, or no previous position: arriving on another map clears this peer's bookkeeping,
		-- so that is the landing.
		if a.flyPending or (not a.flyX) or a.flyArea ~= state.area_id
			or (math.abs(x - a.flyX) + math.abs(y - a.flyY)) > 3 then
			a.dropAt, a.dropDone, a.flyPending = drawFrames, true, nil
		end
	elseif peerEntry ~= 0xFC then
		a.dropDone, a.flyPending = nil, nil -- the flag was shed; the next fly is a new drop
	end
	local dropT = a.dropAt and (drawFrames - a.dropAt) or nil
	-- Latched the moment it arrives, since the drop arms later, and held until the flag is shed with no
	-- drop running: the sender's window closes before a distant peer has landed.
	if peerFly then
		a.flySpecies = peerFly
	elseif peerEntry ~= 0xFC and not dropT then
		a.flySpecies = nil
	end

	-- A full cache dump at the drop and two seconds later: only an adapter reload clears the cache.
	if _G.MESHGHOST_CRYSTAL_FACING_TRACE and dropT and (dropT == 0 or dropT == 120) then
		for fc = 0, 3 do
			local e = facingFrames[fc]
			if e then
				local parts = {}
				if e.stand then
					parts[#parts + 1] = "stand=" .. table.concat({ e.stand[1].offset,
						e.stand[2].offset, e.stand[3].offset, e.stand[4].offset }, ",")
				end
				for st = 0, 3 do
					if e.step[st] then
						parts[#parts + 1] = string.format("step%d=%s", st,
							table.concat({ e.step[st][1].offset, e.step[st][2].offset,
								e.step[st][3].offset, e.step[st][4].offset }, ","))
					end
				end
				logFile(string.format("cache-dump: f=%d t=%d facing=%d %s", drawFrames, dropT, fc,
					(#parts > 0) and table.concat(parts, "  ") or "(empty)"))
			end
		end
	end
	-- Fly trace: the whole landing envelope, edge-triggered on the phase so a drop is a handful of lines.
	if _G.MESHGHOST_CRYSTAL_FLY_TRACE and (dropT or peerEntry == 0xFC) then
		local ph = dropT and ((dropT < 32) and "hide" or "fall") or "flagged"
		if ENGINE.flyPh ~= ph or ENGINE.flyId ~= id then
			ENGINE.flyPh, ENGINE.flyId = ph, id
			local gg = ghosts[id]
			-- Every key that arrived, which tells a send fault from a receive fault.
			local ks = {}
			for k2, v2 in pairs(state.extras or {}) do
				ks[#ks + 1] = k2 .. "=" .. tostring(v2)
			end
			table.sort(ks)
			logFile("fly-extras: " .. table.concat(ks, " "))
			logFile(string.format("fly: f=%d %s %s t=%s entry=%s wireFly=%s heldFly=%s icon=%s "
				.. "area=%s at %d,%d (was %s,%s area %s) ghost=%s facing=%s armed=%s",
				drawFrames, id, ph, tostring(dropT), tostring(peerEntry),
				tostring(peerFly), tostring(a.flySpecies),
				tostring(a.flySpecies and facingFrames.iconGfx(a.flySpecies)),
				tostring(state.area_id), x, y, tostring(a.flyX), tostring(a.flyY),
				tostring(a.flyArea), tostring(gg ~= nil),
				gg and tostring(u8(gg.st_base + F_FACING)) or "-",
				tostring(a.skyfallArmed))
				.. string.format(" ov=%s ovDrop=%s iconPaints=%s",
					tostring(overflow[id] ~= nil),
					tostring(overflow[id] and overflow[id].drop),
					tostring(facingFrames.iconPaints or 0)))
		end
	end
	-- FLY_FRAMES is the engine's own landing length (SpriteAnimFunc_FlyTo), not a duration of ours.
	if dropT and (dropT >= facingFrames.FLY_FRAMES or dropT < 0) then
		a.dropAt, dropT = nil, nil
	end
	-- After the trace, so it shows the previous position. A changed area is the jump (map coordinates are
	-- map-local), and the position is frozen while a landing is pending, or the settle window eats it.
	if not (peerEntry == 0xFC and not a.dropDone) then
		a.flyX, a.flyY, a.flyArea = x, y, state.area_id
	end
	if dropT and dropT >= 32 then
		-- The drop's fall from -96 on a quarter sine over 32 frames; FLY_FRAMES ends the drop first.
		peerYoff = -96 + math.floor(96 * math.sin(((dropT - 32) / 32) * (math.pi / 2)))
	end

	-- A ghost out of range gives its struct back, as the engine's own characters do, and stops blocking a
	-- tile nobody can see. GHOST_RANGE_TILES reaches past the 10x9 window, so nothing pops in at the edge.
	local px, py = u8(OBJECT_STRUCTS + F_MAP_X) or 0, u8(OBJECT_STRUCTS + F_MAP_Y) or 0
	if math.max(math.abs(x - px), math.abs(y - py)) > GHOST_RANGE_TILES then
		despawnGhost(id)
		-- overflow[id] too, or the painted copy stays frozen at the screen edge: translated peers reach here.
		overflow[id] = nil
		overflow[COMPARE.key(id)] = nil
		overflow[COMPARE.hwKey(id)] = nil
		return
	end

	-- Compare mode: the same peer beside the player once per renderer, so the two can be judged in one frame.
	if COMPARE_TIERS and isLoopback then
		local ck = COMPARE.key(id)
		local prev = overflow[ck]
		-- Pinned to one renderer each (`only`), or the hardware tier claims both; the hw copy only while it is on.
		local hk = COMPARE.hwKey(id)
		local hprev = overflow[hk]
		overflow[hk] = OAM_TIER and { prog = peerProg, walking = peerWalking, face = peerFace, act = peerAct, gait = peerGait,
			yoff = peerYoff, emote = peerEmote, jump = peerJump, drop = dropT, flyMon = a.flySpecies,
			-- Pixel positions are absolute, so a copy placed elsewhere shifts them by the same whole tiles.
			pixX = peerPixX and (peerPixX + COMPARE.hw * 16), pixY = peerPixY,
			compare = true, only = "hw", x = baseX + COMPARE.hw, y = y,
			sprite = FORCE_PEER_SPRITE or (state.extras and tonumber(state.extras.sprite)) or nil,
			facing = ORIENTATION_TO_DIR[state.orientation],
			lastX = hprev and hprev.lastX, lastY = hprev and hprev.lastY,
			movedAt = hprev and hprev.movedAt,
			fromX = hprev and hprev.fromX, fromY = hprev and hprev.fromY,
			paintedX = hprev and hprev.paintedX, paintedY = hprev and hprev.paintedY,
			stepLatch = hprev and hprev.stepLatch,
			idleFor = hprev and hprev.idleFor,
			lastFacing = hprev and hprev.lastFacing,
			rearm = hprev and hprev.rearm } or nil

		-- The drawn compare copy sees the peer three arrivals late, so it starts each step where the spawned tier does.
		-- Its inputs are delayed, never its camera beat: the paint's cancellation needs live camera frames.
		local dv = a.dring
		if not dv then dv = { n = 0 }; a.dring = dv end
		dv.n = dv.n + 1
		dv[(dv.n % 4) + 1] = { baseX, y, peerProg, peerWalking, peerFace, peerAct, peerGait,
			peerPixX, peerPixY, state.orientation,
			state.extras and tonumber(state.extras.sprite) or nil, peerYoff, peerEmote, peerJump }
		local dO = (dv.n > 3) and dv[((dv.n - 3) % 4) + 1] or dv[(dv.n % 4) + 1]
		overflow[ck] = { prog = dO[3], walking = dO[4], face = dO[5], act = dO[6], gait = dO[7],
			yoff = dO[12], emote = dO[13], jump = dO[14], drop = dropT, flyMon = a.flySpecies,
			pixX = dO[8] and (dO[8] + COMPARE.drawn * 16), pixY = dO[9],
			compare = true, only = "drawn", x = dO[1] + COMPARE.drawn, y = dO[2],
			sprite = FORCE_PEER_SPRITE or dO[11],
			facing = ORIENTATION_TO_DIR[dO[10]],
			lastX = prev and prev.lastX, lastY = prev and prev.lastY, movedAt = prev and prev.movedAt,
			fromX = prev and prev.fromX, fromY = prev and prev.fromY,
			paintedX = prev and prev.paintedX, paintedY = prev and prev.paintedY,
			modelX = prev and prev.modelX, modelY = prev and prev.modelY,
			modelPhase = prev and prev.modelPhase,
			modelStill = prev and prev.modelStill,
			modelMovedAt = prev and prev.modelMovedAt,
			lagBeats = prev and prev.lagBeats, catchup = prev and prev.catchup,
			stepDX = prev and prev.stepDX, stepDY = prev and prev.stepDY, stepLeft = prev and prev.stepLeft, dbgState = prev and prev.dbgState,
			progAxis = prev and prev.progAxis,
			facingSeen = prev and prev.facingSeen,
			stepLatch = prev and prev.stepLatch,
			idleFor = prev and prev.idleFor,
			lastFacing = prev and prev.lastFacing,
			rearm = prev and prev.rearm }
	end

	-- A peer's sprite id is worn only if our cartridge's row for it hashes to the peer's `extras.gfx`, or it may
	-- name another character here. FORCE_PEER_SPRITE, a probe, skips this gate and reaches both tiers.
	local peerSprite = FORCE_PEER_SPRITE
		or (function()
			local id = state.extras and tonumber(state.extras.sprite)
			if not id or id == 0 then
				return nil
			end
			local mine = ENGINE.spriteSig(id)
			return (mine and tonumber(state.extras.gfx) == mine) and id or nil
		end)()
		or nil
	-- A dropped id falls back to the peer's wire art, else its last sprite that did port, else our player's sprite.
	ENGINE.wireArtIngest(id, state.extras, peerSprite ~= nil)
	local peerArt = (peerSprite == nil) and ENGINE.wireArtFor(id) or nil
	if peerSprite then
		ENGINE.lastPortable[id] = peerSprite
	else
		peerSprite = ENGINE.lastPortable[id]
	end

	-- A spawned ghost can wear only a sprite resident on this map (a bike or surf sprite usually is not), so any
	-- other peer is drawn: the look wins over engine collision. Our own player's sprite is always resident.
	local localSprite = u8(OBJECT_STRUCTS + F_SPRITE)
	-- No residency list (an unmeasured build) sends the peer to the drawn tier, which can wear any id.
	local wearable = peerSprite == nil
		or peerSprite == localSprite
		or (W_USEDSPRITES ~= nil and residentSpriteTile(peerSprite) ~= nil)

	-- A gait faster than this ROM's step table (Archipelago's fourth) goes to the drawn tier: it moves in Lua pixels.
	local paceable = peerGait <= (ENGINE.gaits or 3) - 1

	-- Called even when `wearable` decided: it keeps the peer's idle bookkeeping current across a dismount.
	local blocking = shouldBlock(id, x, y, peerAct)

	if stepLag.on and (not COMPARE.spawnTier or not wearable or not blocking or not paceable)
		and policyFrames - (stepLag.whyAt or -999) >= 60 then
		stepLag.whyAt = policyFrames
		local a = activity[id]
		logFile(string.format("MeshGhost: %s stays on the drawn tier -- wearable=%s blocking=%s "
			.. "paceable=%s (peer sprite %s, local %s; idle for %s frames, passable for "
			.. "another %s)", id,
			tostring(wearable), tostring(blocking), tostring(paceable),
			tostring(peerSprite), tostring(localSprite),
			a and tostring(policyFrames - a.movedAt) or "?",
			a and tostring((a.passableUntil or 0) - policyFrames) or "?"))
	end

	-- The shipped default never spawns; the three engine terms matter only once the spawned tier is opted in.
	if not COMPARE.spawnTier or not wearable or not blocking or not paceable then
		if ghosts[id] then
			logFile(string.format("tier: %s spawned -> painted (%s)", id,
				(not wearable) and "sprite not resident here"
					or (not paceable) and "gait faster than this ROM's engine has a step for"
					or "idle/shoved: not blocking"))
			despawnGhost(id)
		end
		local prev = overflow[id]
		overflow[id] = { prog = peerProg, walking = peerWalking, face = peerFace, act = peerAct, gait = peerGait, pal = peerPal, clo = peerClo,
			yoff = peerYoff, emote = peerEmote, jump = peerJump, drop = dropT, flyMon = a.flySpecies,
			pixX = peerPixX and (peerPixX + offsetX * 16), pixY = peerPixY,
			x = x, y = y, sprite = peerSprite, art = peerArt,
			facing = ORIENTATION_TO_DIR[state.orientation],
			lastX = prev and prev.lastX, lastY = prev and prev.lastY, movedAt = prev and prev.movedAt,
			fromX = prev and prev.fromX, fromY = prev and prev.fromY,
			-- Carried: this entry is rebuilt on every arrival, and the twitch detector needs the last paint.
			paintedX = prev and prev.paintedX, paintedY = prev and prev.paintedY,
			modelX = prev and prev.modelX, modelY = prev and prev.modelY,
			modelPhase = prev and prev.modelPhase,
			modelStill = prev and prev.modelStill,
			modelMovedAt = prev and prev.modelMovedAt,
			lagBeats = prev and prev.lagBeats, catchup = prev and prev.catchup,
			stepDX = prev and prev.stepDX, stepDY = prev and prev.stepDY, stepLeft = prev and prev.stepLeft, dbgState = prev and prev.dbgState,
			progAxis = prev and prev.progAxis,
			facingSeen = prev and prev.facingSeen,
			stepLatch = prev and prev.stepLatch,
			idleFor = prev and prev.idleFor,
			lastFacing = prev and prev.lastFacing,
			rearm = prev and prev.rearm }
		return
	end

	local g = ghosts[id]

	-- An off-map peer stays painted: the engine culls an object outside its map, and -1 wraps to 255 in a u8.
	-- Object space is map space plus the 4-tile border. Fail open when cross-map is not armed (ourW is 0).
	local inOurMap = not ENGINE.xmap.armed() or ENGINE.xmap.ourW <= 0
		or (x >= 4 and y >= 4
			and x <= 3 + ENGINE.xmap.ourW and y <= 3 + ENGINE.xmap.ourH)
	-- Despawn a ghost whose peer left our map; the spawn gate below only stops new ones.
	if g and not inOurMap then
		despawnGhost(id)
		g = nil
		a.reclaimAt = policyFrames
	end
	-- Free on one tick, allocate on a later one: a peer on the seam steps in and out of our map.
	if a.reclaimAt and (policyFrames - a.reclaimAt) < 8 then
		inOurMap = false
	end

	-- Keep the drawn copy until holdHandover sees the new object in OAM: a fresh object is not drawn for frames.
	if g and overflow[id] and not holdHandover(overflow[id]) then
		overflow[id] = nil
	end
	if not g then
		-- Promote onto the drawn model's tile, not the peer's (the promotion fires as the model leaves its tile).
		local px, py = x, y
		local ov = overflow[id]
		if ov and ov.modelX then
			local mtx, mty = math.floor(ov.modelX / 16), math.floor(ov.modelY / 16)
			-- Only for a placeable peer: an off-map one would log this every frame.
			if inOurMap and (mtx ~= x or mty ~= y) then
				-- Logged whether or not acted on: a counter that vanishes with its fix proves nothing.
				logFile(string.format("MeshGhost: %s promoted across a %+d,%+d tile handover "
					.. "(drawn model at %d,%d, peer at %d,%d) -- placed on the model's tile",
					id, mtx - x, mty - y, mtx, mty, x, y))
				px, py = mtx, mty
			end
			local remX = ov.modelX - math.floor(ov.modelX / 16) * 16
			local remY = ov.modelY - math.floor(ov.modelY / 16) * 16
			-- Defer promotion until the model crosses a tile boundary (at most 24 frames): the object lands aligned.
			-- A crossing, not remainder == 0: the 4px catch-up gait goes 14 -> 18 -> 2 and never touches 0.
			local mtile = math.floor(ov.modelX / 16) * 256 + math.floor(ov.modelY / 16)
			local crossed = ov.promoteTile ~= nil and ov.promoteTile ~= mtile
			ov.promoteTile = mtile
			if (remX >= 1 or remY >= 1) and not crossed and (ov.promoteWait or 0) < 24 then
				ov.promoteWait = (ov.promoteWait or 0) + 1
				if stepLag.on then
					logFile(string.format("  defer f=%d %s rem %.1f,%.1f wait %d",
						drawFrames, id, remX, remY, ov.promoteWait))
				end
				px = nil
			elseif stepLag.on then
				stepLag.rem = stepLag.rem or {}
				local k = math.floor(math.max(remX, remY))
				stepLag.rem[k] = (stepLag.rem[k] or 0) + 1
				logFile(string.format("MeshGhost: %s promoted -- drawn model was %.1f,%.1f px into "
					.. "its tile after %d deferred frames (the object lands tile-aligned)",
					id, remX, remY, ov.promoteWait or 0))
			end
		end
		-- px == nil is the mid-step deferral; the promote tile is the model's, one off the peer's, so check it too.
		local placeable = inOurMap and px and px >= 4 and py >= 4
			and (ENGINE.xmap.ourW <= 0
				or (px <= 3 + ENGINE.xmap.ourW and py <= 3 + ENGINE.xmap.ourH))
		if placeable and not dropT and spawnGhost(id, px, py, peerSprite) then
			-- Face the peer now: a fresh clone keeps its template's facing until its first step.
			-- The movement byte is what a step's end restores; DIRECTION/FACING are drawn until then.
			local g2, want2 = ghosts[id], ORIENTATION_TO_DIR[state.orientation]
			if g2 and want2 then
				setGhostStanding(g2.st_base, g2.mo_base, want2)
				w8(g2.st_base + F_DIRECTION, want2 * 4)
				w8(g2.st_base + F_FACING, want2 * 4)
			end
			-- Read back from the object: facing and sprite are what a fresh clone inherits from its donor.
			if g2 then
				logFile(string.format("MeshGhost: %s spawned facing %s wearing sprite %s "
					.. "(peer orientation %q -> dir %s; peer sprite %s, local %s; object now "
					.. "DIRECTION=%s FACING=%s)", id,
					DIR_NAMES[(u8(g2.st_base + F_DIRECTION) or 0)] or "?",
					tostring(u8(g2.st_base + F_SPRITE)),
					tostring(state.orientation), tostring(want2),
					tostring(peerSprite), tostring(u8(OBJECT_STRUCTS + F_SPRITE)),
					tostring(u8(g2.st_base + F_DIRECTION)), tostring(u8(g2.st_base + F_FACING))))
			end
			if overflow[id] then
				logFile(string.format("tier: %s painted -> spawned", id))
				-- Hold the drawn copy until holdHandover sees the object in OAM, at most 8 frames.
				overflow[id].handover = drawFrames
				-- STEP_LAG: trace the handover from the paint side; client.screenshot omits the Lua overlay.
				if stepLag.on then
					-- +8, holdHandover's cap: the trace must outlast the hold.
					stepLag.traceUntil = drawFrames + 8
				end
			else
				overflow[id] = nil
			end
		else
			local prev = overflow[id]
			overflow[id] = { prog = peerProg, walking = peerWalking, face = peerFace, act = peerAct, gait = peerGait, pal = peerPal, clo = peerClo,
			yoff = peerYoff, emote = peerEmote, jump = peerJump, drop = dropT, flyMon = a.flySpecies,
			pixX = peerPixX and (peerPixX + offsetX * 16), pixY = peerPixY,
			x = x, y = y, sprite = peerSprite, art = peerArt,
				facing = ORIENTATION_TO_DIR[state.orientation],
				lastX = prev and prev.lastX, lastY = prev and prev.lastY,
				movedAt = prev and prev.movedAt,
				fromX = prev and prev.fromX, fromY = prev and prev.fromY,
			paintedX = prev and prev.paintedX, paintedY = prev and prev.paintedY,
			modelX = prev and prev.modelX, modelY = prev and prev.modelY,
			modelPhase = prev and prev.modelPhase,
			modelStill = prev and prev.modelStill,
			modelMovedAt = prev and prev.modelMovedAt,
			lagBeats = prev and prev.lagBeats, catchup = prev and prev.catchup,
			stepDX = prev and prev.stepDX, stepDY = prev and prev.stepDY, stepLeft = prev and prev.stepLeft, dbgState = prev and prev.dbgState,
			progAxis = prev and prev.progAxis,
			-- Carried only here; the demotion rebuilds drop it, so each idle period waits from zero.
			promoteWait = prev and prev.promoteWait,
			promoteTile = prev and prev.promoteTile,
			facingSeen = prev and prev.facingSeen,
			stepLatch = prev and prev.stepLatch,
			idleFor = prev and prev.idleFor,
			lastFacing = prev and prev.lastFacing,
			rearm = prev and prev.rearm }
		end
		return
	end
	-- Honour the handover here too: this runs every frame for a spawned peer.
	if not holdHandover(overflow[id]) then
		overflow[id] = nil
	end
	if g and not stillOurs(g) then
		-- A map load, battle or savestate load rebuilt the array: never write steps into the game's slot.
		log("MeshGhost: " .. id .. "'s slot is the game's again — respawning")
		ghosts[id], g = nil, nil
		-- Return: everything below dereferences `g`; next frame promotes or paints the peer.
		return
	end
	-- Every frame: a peer's sprite changes with its state, and what is resident with every map load.
	applyPeerSprite(g, peerSprite)

	local walking = u8(g.st_base + F_WALKING) or STANDING
	local stepType = u8(g.st_base + F_STEP_TYPE) or 0

	-- A dropping peer is painted, ahead of every movement path: only that tier draws the Pokemon's falling icon.
	if dropT and a.flySpecies and facingFrames.iconGfx(a.flySpecies) then
		despawnGhost(id)
		return
	end

	-- STANDING with a walk step type reads past StepVectors (WALKING's low nibble is 15) and drags the ghost off
	-- screen. Cause unknown; repaired through the engine's own end of movement (a registered bandage).
	if walking == STANDING and (stepType == 2 or stepType == 7) then
		w8(g.st_base + F_STEP_TYPE, 1) -- STEP_TYPE_FROM_MOVEMENT
		w8(g.st_base + F_STEP_DURATION, 0)
		snaps.runaways = (snaps.runaways or 0) + 1
	end

	-- Ice: a gliding peer moves posed STANDING (act 1). SLIDING on the ghost stops the engine animating its step;
	-- the player never wears the bit, and writing the action instead would race the engine's step function.
	if g and peerAct ~= nil then
		local fl = u8(g.st_base + F_FLAGS1) or 0
		local glide = peerWalking and peerAct == 1 -- moving, but posed STANDING: an ice slide
		if glide ~= ((fl & 0x08) ~= 0) then
			w8(g.st_base + F_FLAGS1, glide and (fl | 0x08) or (fl & ~0x08))
		end
	end

	-- The peer's y-offset (a fishing bite's wiggle) on the spawned ghost, above the mid-step return so a hop gets it:
	-- the engine adds it when building OAM. Stand off for a hop: the NPC jump (step type 8) writes its own arc.
	if g and peerYoff ~= nil and not peerJump and (u8(g.st_base + F_STEP_TYPE) or 0) ~= 8
		and u8(g.st_base + emote.F_YOFF) ~= (peerYoff & 0xFF) then
		w8(g.st_base + emote.F_YOFF, peerYoff & 0xFF)
	end

	-- Mid-step: never interrupt a step (a character would teleport while animating); only chain the next.
	if walking ~= STANDING then
		-- Chain a same-way, same-gait step on its last tick by topping up the duration, as the engine's walkers do;
		-- +1 because the ending step still owes its final pass. LAST_MAP is what the skipped landing would write.
		local chx, chy = u8(g.st_base + F_MAP_X) or 0, u8(g.st_base + F_MAP_Y) or 0
		local pgx, pgy = facingFrames.pathGoal(g, x, y, chx, chy)
		local chDir = DELTA_TO_DIR[string.format("%d,%d", pgx - chx, pgy - chy)]
		-- Clamped as stepGhost clamps it, or the walking-byte guard below never matches.
		local chGroup = ENGINE.gait(peerGait)
		-- Only if the same arrival says the peer still walks this way: the stale tile alone overshot reversals.
		if chDir and stepType == 2 and (u8(g.st_base + F_STEP_DURATION) or 0) == 1
			and (walking & 0x0F) == chGroup * 4 + chDir
			and peerWalking and ORIENTATION_TO_DIR[state.orientation] == chDir then
			g.chainAt, g.chainDir = drawFrames, chDir
			w8(g.st_base + F_LAST_MAP_X, chx)
			w8(g.st_base + F_LAST_MAP_Y, chy)
			w8(g.st_base + F_STEP_DURATION, GAIT_TICKS[chGroup] + 1)
			w8(g.st_base + F_MAP_X, pgx)
			w8(g.st_base + F_MAP_Y, pgy)
			if stepLag.on then
				stepLag.close(id)
			end
			return
		end
		if stepLag.on and stepLag.open[id] then
			stepLag.blocked = stepLag.blocked + 1
			-- What holds the ghost mid-step, one line per 15 blocked frames.
			if (stepLag.blocked % 15) == 1 then
				logFile(string.format(
					"blocked f=%d %s walk=%d stype=%d dur=%d act=%d ghost %d,%d peer %d,%d",
					drawFrames, id, walking, stepType, u8(g.st_base + F_STEP_DURATION) or 0,
					u8(g.st_base + F_ACTION) or 0,
					u8(g.st_base + F_MAP_X) or 0, u8(g.st_base + F_MAP_Y) or 0, x, y))
			end
		end
		return
	end

	local cx, cy = u8(g.st_base + F_MAP_X) or 0, u8(g.st_base + F_MAP_Y) or 0

	-- Re-anchor a standing ghost's sprite to its tile on a settled camera: stepGhost's screen delta accumulates error.
	if cameraSettled() then
		local wantX, wantY = screenCoords(cx, cy)
		local haveX, haveY = u8(g.st_base + F_SPRITE_X) or 0, u8(g.st_base + F_SPRITE_Y) or 0
		if haveX ~= wantX or haveY ~= wantY then
			local ddx = ((wantX - haveX + 128) & 0xFF) - 128
			local ddy = ((wantY - haveY + 128) & 0xFF) - 128
			w8(g.st_base + F_SPRITE_X, wantX)
			w8(g.st_base + F_SPRITE_Y, wantY)
			snaps.drift = (snaps.drift or 0) + 1
			-- Signed: 2px short and 2px over are opposite faults.
			snaps.driftPx = math.max(snaps.driftPx or 0, math.abs(ddx) + math.abs(ddy))
			snaps.driftDir = string.format("%+d,%+d", ddx, ddy)
			if math.abs(ddx) + math.abs(ddy) > 2 then
				-- A whole-tile correction: log the step state, which says whether MAP_X moved without the sprite.
				logFile(string.format("MeshGhost: re-anchored %s to its tile by %+d,%+d px "
					.. "(a drift bigger than one step's compensation) -- tile %d,%d last %d,%d "
					.. "walking=%s step_type=%s duration=%s action=%s facing=%s",
					id, ddx, ddy, cx, cy,
					u8(g.st_base + F_LAST_MAP_X) or 0, u8(g.st_base + F_LAST_MAP_Y) or 0,
					tostring(u8(g.st_base + F_WALKING)), tostring(u8(g.st_base + F_STEP_TYPE)),
					tostring(u8(g.st_base + F_STEP_DURATION)),
					tostring(u8(g.st_base + F_ACTION)), tostring(u8(g.st_base + F_FACING))))
			end
		end
	end
	if cx == x and cy == y then
		-- A turn in place: FACING's low bits are the walk-cycle subframe, so it is written only while idle.
		local want = ORIENTATION_TO_DIR[state.orientation]
		if want and u8(g.st_base + F_DIRECTION) ~= want * 4 then
			w8(g.st_base + F_DIRECTION, want * 4)
			w8(g.st_base + F_FACING, want * 4)
			-- The movement byte too: the engine's restore turns the object to face whatever it names.
			setGhostStanding(g.st_base, g.mo_base, want)
		end
		-- In-place actions (fishing, a wall bump, spinning, the "!" emote); direction first, which fishing reads.
		applyPeerAction(g, peerAct)
		return
	end
	local gx, gy = facingFrames.pathGoal(g, x, y, cx, cy)
	local dx, dy = gx - cx, gy - cy
	local dir = DELTA_TO_DIR[string.format("%d,%d", dx, dy)]

	if stepLag.on and (cx ~= x or cy ~= y) then
		logFile(string.format(
			"path f=%d %s ghost %d,%d peer %d,%d goal %d,%d dir=%s q=%d pathXY=%s,%s",
			drawFrames, id, cx, cy, x, y, gx, gy, tostring(dir),
			g.path and #g.path or 0, tostring(g.pathX), tostring(g.pathY)))
	end

	-- One-tile case only: step once the peer is STEP_TRIGGER_PROG px into its own step; catch-up and teleport
	-- are late already. Compared in the peer's own frame (`baseX`): its pixels carry no loopback offset.
	if dir and STEP_TRIGGER_PROG > 0 and peerPixX and peerPixY then
		-- The peer is `16 - prog` px short of its destination (`offsetFromDest`, read backwards).
		local short = math.abs(peerPixX - baseX * 16) + math.abs(peerPixY - y * 16)
		local prog = 16 - short
		-- More than a tile out (a warp, a map load) is not mid-step: let it through.
		if short >= 0 and short <= 16 and prog < STEP_TRIGGER_PROG then
			stepLag.waits = (stepLag.waits or 0) + 1
			return
		end
	end

	if stepLag.on then
		logFile(string.format("ghost step f=%d %s %s ghost %d,%d -> peer %d,%d deficit %d prog=%s",
			drawFrames, id, dir and "inphase" or "catchup", cx, cy, x, y,
			math.abs(dx) + math.abs(dy), tostring(peerProg)))
	end
	if dir then
		-- No camera-frame gate: traced, the spawned ghost already advances on the player's own frames.
		if stepLag.on then
			stepLag.close(id)
		end
		-- A step opposite a recent chain: the expected shape at a quick reversal, logged to show the turn tile.
		if g.chainDir and dir == (g.chainDir ~ 1)
			and drawFrames - (g.chainAt or -999) <= 16 then
			logFile(string.format("reversal retrace: %s chained %s at f=%d, reversing %s at f=%d",
				id, DIR_NAMES.letter[g.chainDir] or "?", g.chainAt or -1,
				DIR_NAMES.letter[dir] or "?", drawFrames))
		end
		-- Hops only in phase: a jump crosses two tiles, so a lagging ghost walks the ledge instead.
		stepGhost(g, dir, peerGait, peerJump) -- one tile: walk it, so the game animates the step
	elseif math.abs(dx) + math.abs(dy) <= 3 then
		-- Up to 3 tiles behind is walked, one step per idle window (twice the peer's pace), larger axis first:
		-- teleportGhost waits for a settled camera, so it would freeze a ghost while the player keeps walking.
		local stepDir
		if math.abs(dx) >= math.abs(dy) then
			stepDir = (dx > 0) and 3 or 2
		else
			stepDir = (dy > 0) and 0 or 1
		end
		if stepLag.on then
			stepLag.close(id)
		end
		stepGhost(g, stepDir, peerGait)
	else
		-- `dropT ~= nil`, not the raw flag, so the engine fall and the painted drop share one envelope.
		teleportGhost(g, x, y, dropT ~= nil) -- genuinely far (a warp, a long silence): snap, don't fake a walk
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
	-- Clear the overlay too: painted pixels persist, and tick() stops repainting once disconnected.
	pcall(function() gui.clearGraphics() end)
	if why then
		log("MeshGhost: bridge lost (" .. why .. ")")
	end
end

local function send(obj)
	if not sock then
		return
	end
	local line = jsonEncode(obj) .. "\n"
	-- A partial send is fatal, not a benign timeout: the next line would be glued onto the fragment; reconnect.
	local ok, err, lastByte = sock:send(line)
	if ok then
		return
	end
	if err == "timeout" and (lastByte or 0) == 0 then
		-- Nothing went out at all -- next tick restates this frame.
		return
	end
	disconnect(tostring(err))
end

-- Ports that answered but would not have us, with the frame their cooldown ends.
local busyUntil = {}
local currentPort = nil
local helloSentAtFrame = nil
local bridgeFrames = 0
-- Set when a core reports the relay is unreachable; until then, do not walk ports or spawn cores.
local relayDownUntil = 0

-- The room's ghost-collision policy (`session_policy`). nil until one arrives keeps peers solid: an older core
-- sends none. On ENGINE, not a local: the file is at the 200-local ceiling, and shouldBlock far above reads it.
ENGINE.ghostCollisionAllowed = nil

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
	-- Nagle off for one small line per frame; pcall'd, as setoption is a luasocket extension a build may lack.
	pcall(function()
		s:setoption("tcp-nodelay", true)
	end)
	sock, connected, ready, rxBuffer = s, true, false, ""
	currentPort, helloSentAtFrame = port, bridgeFrames
	log(string.format("MeshGhost: bridge connected on %s:%d", BRIDGE_HOST, port))
	-- render_all_areas, only once cross-map is armed: this adapter then owns area visibility, so the core stops
	-- dropping peers at every seam. min_protocol_version is this adapter's floor, raised only by hand.
	send({ type = "hello", payload = { game_id = GAME_ID, game_version = GAME_VERSION,
		min_protocol_version = 2,
		render_all_areas = ENGINE.xmap.armed() or nil } })
	return true
end

-- One sweep per cooldown: a refused connect is immediate on loopback, and a closed port costs at most 50ms.
-- firstFreePort: the last sweep's first silent port, where autostart puts a core (the base port may be taken).
local firstFreePort = nil

local function connect()
	if BRIDGE_PORT_OVERRIDE then
		firstFreePort = BRIDGE_PORT_OVERRIDE
		-- The busy cooldown applies to an override too.
		if (busyUntil[BRIDGE_PORT_OVERRIDE] or 0) <= bridgeFrames then
			tryPort(BRIDGE_PORT_OVERRIDE)
		end
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
-- luanet's Process with CreateNoWindow is invisible, where os.execute and io.popen flash a console.
local coreChild, coreSpawnFrame, coreSpawnFailed = nil, nil, false
-- Off by MESHGHOST_NO_AUTOSTART or "autostart": false in the first config.json found (own folder, release
-- root, checkout root). An IIFE, not a helper: this file has no local to spare.
local AUTOSTART = os.getenv("MESHGHOST_NO_AUTOSTART") == nil and (function()
    for _, dir in ipairs({ SCRIPT_DIR .. "/", SCRIPT_DIR .. "/../../../", SCRIPT_DIR .. "/../../../../" }) do
        local f = io.open(dir .. "config.json", "rb")
        if f then
            local text = f:read("*a") or ""
            f:close()
            return not text:find('"autostart"%s*:%s*false')
        end
    end
    return true
end)()

-- Autostart looks only beside this script: copying meshghost.exe here is the opt-in, so an install that never
-- opted in never spawns a process. MESHGHOST_CORE_DIR comes first, the dev escape hatch, as in TEVI.
local function findCoreExe()
	local candidates = { SCRIPT_DIR .. "/meshghost.exe" }
	local devDir = os.getenv("MESHGHOST_CORE_DIR")
	if devDir and devDir ~= "" then
		table.insert(candidates, 1, devDir .. "/meshghost.exe")
	end
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
	-- Our live child answered busy, so another instance took it: forget it (never kill it) and start another.
	-- Only on busy, never on silence, or two restarting instances chase each other's fresh cores.
	if coreStillRunning() and coreSpawnFrame and coreSpawnFrame.busy and port then
		console.log(string.format("MeshGhost: the core this script started on port %d is serving another instance -- leaving it and starting another on port %d.", coreSpawnFrame.port, port))
		coreChild = nil
	end
	if not AUTOSTART or coreSpawnFailed or coreStillRunning() then
		return
	end
	-- Every port in the range is somebody else's core; spawning would just fail to bind.
	if not port then
		return
	end
	-- A core takes a moment to bind; spawning again sooner piles processes onto one port.
	if coreSpawnFrame and (bridgeFrames - coreSpawnFrame.frame) < 300 then
		return
	end

	local exe = findCoreExe()
	if not exe then
		coreSpawnFailed = true
		log("MeshGhost: meshghost.exe not found near this script -- not starting a core. "
			.. "Start it yourself, or put a copy beside this file.")
		return
	end

	coreSpawnFrame = { frame = bridgeFrames, port = port }
	local ok, err = pcall(function()
		luanet.load_assembly("System") -- without this, import_type returns nil
		local Process = luanet.import_type("System.Diagnostics.Process")
		local StartInfo = luanet.import_type("System.Diagnostics.ProcessStartInfo")
		local si = StartInfo()
		si.FileName = exe
		-- No -relay: the core reads the player's config.json, and an argument would override it.
		si.Arguments = string.format("-exit-with-pid=%d -bridge=%s:%d",
			Process.GetCurrentProcess().Id, BRIDGE_HOST, port)
		-- The core reads config.json from its working directory, else silently uses built-in defaults.
		-- This game's own config.json wins if present, else the exe's folder; one file wins, never a merge.
		do
			local own = io.open(SCRIPT_DIR .. "/config.json", "rb")
			if own then own:close() end
			si.WorkingDirectory = own and (SCRIPT_DIR .. "/") or (exe:gsub("meshghost%.exe$", ""))
			console.log("MeshGhost: the core reads " .. si.WorkingDirectory .. "config.json"
				.. (own and " (this game's own)" or " (the release root's; put a config.json beside this script to give this game its own)"))
		end
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
		-- Only busy or already_serving walks on; any other refusal is upstream of a good core, so wait for it:
		-- walking on would mark every port busy and spawn cores. Branch on `code`, never on the reason's prose;
		-- an empty code is a core older than the field, and only it gets the old substring rule.
		local code = type(p.code) == "string" and p.code or ""
		local retryable = p.retryable == true
		local walkOn
		if code == "" then
			walkOn = not reason:find("relay", 1, true)
		else
			walkOn = (code == "busy") or (code == "already_serving")
		end
		if not walkOn then
			if code ~= "" and not retryable then
				log("MeshGhost: that refusal is PERMANENT (" .. code .. ") — waiting will not fix it; "
					.. "check the client's config.json")
			end
			relayDownUntil = bridgeFrames + RELAY_DOWN_BACKOFF_FRAMES
			disconnect(nil)
			return
		end
		local isBusy
		if code == "" then
			isBusy = reason:find("busy", 1, true) ~= nil
		else
			isBusy = code == "busy"
		end
		if isBusy and coreSpawnFrame and currentPort == coreSpawnFrame.port then
			coreSpawnFrame.busy = true -- our own child has another game: startCore may forget it
		end
		markPortBusy(currentPort, "refused us (" .. reason .. ")")
		disconnect(nil)
	elseif t == "session_policy" then
		-- Only "disabled"/"enabled" change the policy; an unknown value leaves it as it was.
		local want = type(p.ghost_collision) == "string" and p.ghost_collision or ""
		if want == "disabled" or want == "enabled" then
			local allow = (want == "enabled")
			if allow ~= ENGINE.ghostCollisionAllowed then
				ENGINE.ghostCollisionAllowed = allow
				log("MeshGhost: ghost collision " .. want .. " by the session policy -- "
					.. (allow and "peers can block you" or "peers are walk-through"))
			end
		end
	elseif t == "render_remote" then
		renderRemote(tostring(p.player_id), p.state)
	elseif t == "despawn_remote" then
		-- Both tiers and the activity record: despawnGhost knows only spawned ghosts.
		local gone = tostring(p.player_id)
		despawnGhost(gone)
		overflow[gone] = nil
		overflow[COMPARE.key(gone)] = nil
		overflow[COMPARE.hwKey(gone)] = nil
		activity[gone] = nil
		-- Shrink the per-peer tables; ENGINE.lastPortable stays, a returning peer's sprite fallback.
		ENGINE.wireArtPeer[gone] = nil
		local prefix = gone .. "|"
		for k in pairs(ENGINE.xmap.said) do
			if k:sub(1, #prefix) == prefix then ENGINE.xmap.said[k] = nil end
		end
	end
end

local function receive()
	if not sock then
		return
	end
	-- One read per frame on the emulator thread; a backlog drains over frames, as states are latest-wins.
	local chunk, err, partial = sock:receive(4096)
	local data = chunk or partial
	if data and #data > 0 then
		rxBuffer = rxBuffer .. data
	elseif err and err ~= "timeout" then
		disconnect(tostring(err))
		return
	end
	-- No newline in 16 KiB drops the bridge (a re-wrapped render_remote can exceed the relay's 4095-byte state).
	-- Checked before the scan, so only one over-long line trips it, never a burst of small ones.
	if #rxBuffer > 16384 and not rxBuffer:find("\n", 1, true) then
		log(string.format("MeshGhost: bridge buffered %d bytes with no newline -- reconnecting",
			#rxBuffer))
		rxBuffer = ""
		disconnect("oversized line")
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

-- Select the address set before any memory access: an unknown ROM runs on vanilla's, Archipelago on its own.
local A = ADDRESSES[romTable or "vanilla"]
OBJECT_STRUCTS, MAP_OBJECTS = A.OBJECT_STRUCTS, A.MAP_OBJECTS
W_MAPGROUP, W_MAPNUMBER = A.W_MAPGROUP, A.W_MAPNUMBER
W_YCOORD, W_XCOORD = A.W_YCOORD, A.W_XCOORD
W_MAPSTATUS, W_BATTLEMODE = A.W_MAPSTATUS, A.W_BATTLEMODE
W_BGMAPOFFSETX, W_BGMAPOFFSETY = A.W_BGMAPOFFSETX, A.W_BGMAPOFFSETY
-- Cross-map ghosts: all three or none; nil keeps ENGINE.xmap.armed() false.
ENGINE.xmap.connAt, ENGINE.xmap.wAt, ENGINE.xmap.hAt = A.W_MAPCONNECTIONS, A.W_MAPWIDTH, A.W_MAPHEIGHT
-- Overrides: both hold vanilla's values from load time, and `or` keeps that if a table omits them.
W_OBPALS = A.W_OBPALS or W_OBPALS
MENUBOX = A.MENUBOX or MENUBOX
if A.OBPALS_MEASURED == false then
	-- Said once at startup: an inherited address looks like a measured one at every later point.
	log("MeshGhost: NOTE — on this build the palette and menu-box addresses are INHERITED from "
		.. "vanilla and have never been measured. If peer colours or the text-box gate look wrong "
		.. "here, that is the first thing to check.")
end
W_USEDSPRITES = A.W_USEDSPRITES -- optional: nil means "peer appearance off on this build"
W_STATEFLAGS = A.W_STATEFLAGS -- optional: nil turns the hardware tier off on that build
OVERWORLD_SPRITES_ROM = A.OVERWORLD_SPRITES_ROM -- optional: nil means "no cartridge graphics here"
-- ROM art with no signature to check (emotes, icon, rod, shadow) is gated on ROM identity; nil omits the detail.
EMOTES_ROM = (romClass == "known") and A.EMOTES_ROM or nil
facingFrames.iconTbl = (romClass == "known") and A.MON_ICONS_ROM or nil
facingFrames.iconPtrs = (romClass == "known") and A.ICON_POINTERS_ROM or nil
facingFrames.iconBank = A.ICONS_BANK
ENGINE.curPartyMon, ENGINE.partySpecies = A.W_CURPARTYMON, A.W_PARTYSPECIES
ENGINE.sprOn = A.W_SPRITEUPDATESON -- nil on an unmeasured build: the gate simply never fires
facingFrames.fishChris = (romClass == "known") and A.FISHING_GFX_ROM or nil
facingFrames.fishKris = (romClass == "known") and A.FISHING_GFX_ROM_KRIS or nil
facingFrames.shadowRom = (romClass == "known") and A.SHADOW_GFX_ROM or nil
-- hMapEntryMethod (HRAM, so the System Bus): $FC is read as arrived by Fly, which drops a peer out of the sky.
-- ROM-gated like the art: a patch can move HRAM too, and nil means peers on that build simply appear.
ENGINE.entryAddr = (romClass == "known") and 0xFF9F or nil

-- The camera, per build (HRAM, so the System Bus); ENGINE.camCheck catches an inherited pair that is wrong.
ENGINE.scxAddr, ENGINE.scyAddr = A.H_SCX, A.H_SCY

-- How many gaits this ROM has: the table address is a hint, re-checked, else bank 1 is searched for it.
ENGINE.gaits = ENGINE.gaitGroups(A.STEP_VECTORS_ROM)
if not ENGINE.gaits then
	local found, at = ENGINE.gaitGroups(nil)
	ENGINE.gaits = found
	log(found
		and string.format("MeshGhost: the step-vector table is not at 0x%05X on this ROM; found "
			.. "it at 0x%05X with %d gaits", A.STEP_VECTORS_ROM or 0, at, found)
		or "MeshGhost: could not find the step-vector table on this ROM -- assuming vanilla's "
			.. "three gaits, which is the answer that cannot write past the end of it.")
end
ENGINE.gaits = ENGINE.gaits or 3
if ENGINE.gaits > 3 then
	log(string.format("MeshGhost: this ROM carries %d gaits, %d more than vanilla -- peers moving "
		.. "at one will be stepped at it.", ENGINE.gaits, ENGINE.gaits - 3))
end

-- Check the sprite table's first entry before reading pointers out of it: a wrong offset paints garbage.
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

-- The whole sprite table's signature, logged at startup only: the wire carries the per-sprite one below.
if OVERWORLD_SPRITES_ROM then
	local h = 2166136261
	-- 102 entries; a shorter table just hashes a few extra bytes, harmless for an equality test.
	for i = 0, 102 * SPRITEDATA_STRIDE - 1 do
		h = ((h ~ (memory.read_u8(OVERWORLD_SPRITES_ROM + i, ROM_DOMAIN) or 0)) * 16777619)
			& 0xFFFFFFFF
	end
	ENGINE.gfxSig = h
	log(string.format("MeshGhost: sprite-table signature %08X -- a peer's own sprite is worn only "
		.. "by a client whose cartridge reports the same number.", h))
end

-- Per sprite, the gate that ships: hash that id's own six-byte row, so only an id whose row differs falls back.
-- The mount needs no vocabulary: a player's sprite id changes when they mount. Memoised, six reads per id.
ENGINE.spriteSigs = {}
function ENGINE.spriteSig(id)
	id = ENGINE.peerRomIndex(id, 1, 255) -- integer AND in range; see ENGINE.peerRomIndex
	if not OVERWORLD_SPRITES_ROM or not id then
		return nil
	end
	local c = ENGINE.spriteSigs[id]
	if c then
		return c
	end
	local e = OVERWORLD_SPRITES_ROM + (id - 1) * SPRITEDATA_STRIDE
	local v = 2166136261
	for i = 0, SPRITEDATA_STRIDE - 1 do
		v = ((v ~ (memory.read_u8(e + i, ROM_DOMAIN) or 0)) * 16777619) & 0xFFFFFFFF
	end
	ENGINE.spriteSigs[id] = v
	return v
end

-- Wire art: the run sprite's pixels, sent from the runner's cartridge to one whose row differs; the repo has none.
-- Sender: WIRE_ART builds, ids $65/$66 while worn; chunks for 3 s after the sprite goes on or a peer appears.
-- Receiver: any malformed field drops the state's art; all N chunks, pad byte zero, FNV-1a equal to the hash.
-- At most 4 graphics in assembly and 8 done; painted on the overlay only, never written to game memory.
-- 384 bytes is 24 tiles (standing then stepping); 11 chunks, a prime, so the frame-stamped index cannot alias.
ENGINE.WIRE_ART_IDS = { [0x65] = true, [0x66] = true }
ENGINE.WIRE_ART_BYTES, ENGINE.WIRE_ART_CHUNK, ENGINE.WIRE_ART_N = 384, 35, 11
ENGINE.wireArtSend = A.WIRE_ART == true
ENGINE.wireArtMine, ENGINE.wireArtBurstUntil = {}, 0
ENGINE.wireArtPartial, ENGINE.wireArtPartialN = {}, 0
ENGINE.wireArtDone, ENGINE.wireArtDoneN = {}, 0
ENGINE.wireArtPeer, ENGINE.wireArtSeen, ENGINE.wireArtSeenN = {}, {}, 0
ENGINE.lastPortable = {}

function ENGINE.fnv32(bytes, n)
	local v = 2166136261
	for i = 1, n do
		v = ((v ~ bytes[i]) * 16777619) & 0xFFFFFFFF
	end
	return v
end

-- Sender: returns hash, and chunk index + hex only inside a burst window. nil when not wearing art.
function ENGINE.wireArtChunk(spriteId)
	if not ENGINE.wireArtSend or not ENGINE.WIRE_ART_IDS[spriteId] then
		ENGINE.wireArtWorn = nil
		return nil
	end
	local now = emu.framecount()
	if ENGINE.wireArtWorn ~= spriteId then
		ENGINE.wireArtWorn = spriteId
		ENGINE.wireArtBurstUntil = now + 180
	end
	local m = ENGINE.wireArtMine[spriteId]
	if m == nil then
		m = false
		local gfx = spriteGfxInRom(spriteId)
		if gfx then
			local bytes = {}
			for i = 1, ENGINE.WIRE_ART_BYTES do
				bytes[i] = romByte(gfx + i - 1)
			end
			bytes[ENGINE.WIRE_ART_BYTES + 1] = 0 -- pad to N * CHUNK
			local hex = {}
			for c = 0, ENGINE.WIRE_ART_N - 1 do
				local s = {}
				for k = 1, ENGINE.WIRE_ART_CHUNK do
					s[k] = string.format("%02x", bytes[c * ENGINE.WIRE_ART_CHUNK + k])
				end
				hex[c + 1] = table.concat(s)
			end
			m = { h = ENGINE.fnv32(bytes, ENGINE.WIRE_ART_BYTES), hex = hex }
			logFile(string.format("wire art: sprite $%02X ready to send, hash %08X, %d chunks",
				spriteId, m.h, ENGINE.WIRE_ART_N))
		end
		ENGINE.wireArtMine[spriteId] = m
	end
	if not m then
		return nil
	end
	if now > ENGINE.wireArtBurstUntil then
		return m.h
	end
	local i = now % ENGINE.WIRE_ART_N
	return m.h, i, m.hex[i + 1]
end

-- Receiver: called once per arriving peer state, before the entry is built.
function ENGINE.wireArtIngest(id, ex, portable)
	-- A new peer reopens our send burst so a late joiner gets the chunks; capped against a relay churning ids.
	if not ENGINE.wireArtSeen[id] then
		if ENGINE.wireArtSeenN >= 64 then
			ENGINE.wireArtSeen, ENGINE.wireArtSeenN = {}, 0
		end
		ENGINE.wireArtSeen[id] = true
		ENGINE.wireArtSeenN = ENGINE.wireArtSeenN + 1
		ENGINE.wireArtBurstUntil = emu.framecount() + 180
	end
	ENGINE.wireArtPeer[id] = nil
	if portable or type(ex) ~= "table" then
		return
	end
	local sid = ENGINE.peerRomIndex(tonumber(ex.sprite), 1, 255)
	if not sid or not ENGINE.WIRE_ART_IDS[sid] then
		return
	end
	local h = ENGINE.peerRomIndex(ex.arth, 0, 0xFFFFFFFF)
	if not h then
		return
	end
	local hasI, hasD = ex.arti ~= nil, ex.artd ~= nil
	local i, d = nil, nil
	if hasI or hasD then
		i = ENGINE.peerRomIndex(ex.arti, 0, ENGINE.WIRE_ART_N - 1)
		d = ex.artd
		if not i or type(d) ~= "string" or #d ~= ENGINE.WIRE_ART_CHUNK * 2 or d:find("[^0-9a-f]") then
			return -- malformed: none of this state's art is used, including the hash
		end
	end
	ENGINE.wireArtPeer[id] = h
	if not d or ENGINE.wireArtDone[h] then
		return
	end
	local p = ENGINE.wireArtPartial[h]
	if not p then
		if ENGINE.wireArtPartialN >= 4 then
			ENGINE.wireArtPartial, ENGINE.wireArtPartialN = {}, 0
		end
		p = { n = 0 }
		ENGINE.wireArtPartial[h] = p
		ENGINE.wireArtPartialN = ENGINE.wireArtPartialN + 1
	end
	if not p[i] then
		p[i] = d
		p.n = p.n + 1
	end
	if p.n < ENGINE.WIRE_ART_N then
		return
	end
	ENGINE.wireArtPartial[h] = nil
	ENGINE.wireArtPartialN = math.max(0, ENGINE.wireArtPartialN - 1)
	local bytes = {}
	for c = 0, ENGINE.WIRE_ART_N - 1 do
		local s = p[c]
		for k = 0, ENGINE.WIRE_ART_CHUNK - 1 do
			bytes[#bytes + 1] = tonumber(s:sub(k * 2 + 1, k * 2 + 2), 16)
		end
	end
	local ok = #bytes == ENGINE.WIRE_ART_BYTES + 1 and bytes[#bytes] == 0
		and ENGINE.fnv32(bytes, ENGINE.WIRE_ART_BYTES) == h
	if not ok then
		logFile(string.format("wire art: %s sent chunks that do not hash to %08X -- discarded", tostring(id), h))
		return
	end
	bytes[#bytes] = nil
	bytes.h = h
	if ENGINE.wireArtDoneN >= 8 then
		ENGINE.wireArtDone, ENGINE.wireArtDoneN = {}, 0
	end
	ENGINE.wireArtDone[h] = bytes
	ENGINE.wireArtDoneN = ENGINE.wireArtDoneN + 1
	logFile(string.format("wire art: assembled %08X from %s (sprite $%02X) -- painted from now on", h,
		tostring(id), sid))
end

function ENGINE.wireArtFor(id)
	local h = ENGINE.wireArtPeer[id]
	return h and ENGINE.wireArtDone[h] or nil
end

if romClass == "known" then
	log("ROM: " .. romWhy .. " — addresses verified against a byte-identical build.")
elseif romClass == "archipelago" then
	log("ROM: " .. romWhy .. " — using its own measured address set.")
else
	-- One line naming the ROM: every build is attempted, and the log's first line then says which one it was.
	if os.getenv("MESHGHOST_CRYSTAL_STRICT") == "1" then
		log("REFUSING TO RUN (strict mode): " .. romWhy)
		return
	end
	log("ROM: untested — " .. romWhy .. ". Running anyway; object RAM only, never a save.")
end

-- A missing address refuses to run: vanilla's value for one entry would pass the gate and write unchecked RAM.
-- The experiment opts in by env var or an ap_try.flag beside this script, which needs no emulator restart.
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
		-- AP_TRY substitutes a named candidate and says so on every startup; a missing one still refuses.
		local c = TRY and A.candidates and A.candidates[name]
		if c then
			_G["__ap_try_" .. name] = c
			log(string.format("UNCONFIRMED ADDRESS IN USE: %s = 0x%04X (MESHGHOST_CRYSTAL_AP_TRY=1)",
				name, c))
		elseif TRY and name:match("^W_BGMAPOFFSET") then
			-- Zero positions by whole tiles: right on a tile boundary, up to a tile out mid-step.
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

-- Experiment mode only: twice a second, the gate's verdict beside its inputs.
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
			ENGINE.MAPSTATUS_HANDLE, W_BATTLEMODE, tostring(u8(W_BATTLEMODE)), tostring(u8(W_MAPGROUP)),
			tostring(u8(W_MAPNUMBER)), tostring(u8(0x0FB1)), tostring(u8(0x1439))))
	end
end

local function tick()
	bridgeFrames = bridgeFrames + 1

	-- Latched: the entry byte lives only inside the map-load window, when getLocalState samples nothing.
	if ENGINE.entryAddr then
		local m = memory.read_u8(ENGINE.entryAddr, "System Bus") or 0
		if m ~= 0 then
			ENGINE.entry, ENGINE.entryAt = m, emu.framecount()
			-- Latched with the entry byte: wCurPartyMon moves as soon as a menu opens.
			if m == 0xFC then
				local slot = ENGINE.curPartyMon and u8(ENGINE.curPartyMon) or nil
				local sp = (slot and slot < 6 and ENGINE.partySpecies)
					and u8(ENGINE.partySpecies + slot) or nil
				if sp and sp > 0 then
					ENGINE.flySpecies = sp
				end
				if _G.MESHGHOST_CRYSTAL_FLY_TRACE and ENGINE.flyLoggedAt ~= ENGINE.entryAt then
					ENGINE.flyLoggedAt = ENGINE.entryAt
					logFile(string.format("fly-latch: f=%d curPartyMon addr=%s slot=%s "
						.. "partySpecies addr=%s species=%s -> flySpecies=%s",
						emu.framecount(), tostring(ENGINE.curPartyMon), tostring(slot),
						tostring(ENGINE.partySpecies), tostring(sp),
						tostring(ENGINE.flySpecies)))
				end
			end
			-- Hold the painted tier off through the map load itself, not just an area change (a warp to the same map
			-- changes no area): its resident tiles are being reloaded. Re-armed each frame, so it ends 30 frames after.
			playerHistory.settle = 30
		end
	end

	if not connected then
		if bridgeFrames < relayDownUntil then
			return -- a core told us the relay is down; give it time rather than spawning another
		end
		sinceRetry = sinceRetry + 1
		if sinceRetry >= RECONNECT_FRAMES then
			sinceRetry = 0
			if coreChild and coreSpawnFrame and coreSpawnFrame.port and not coreSpawnFrame.busy
				and coreStillRunning() then
				-- Our own child is alive: wait on its port; sweeping past it lets another instance attach to it.
				tryPort(coreSpawnFrame.port)
			else
				connect()
			end
			-- Only after a full sweep found nothing: a core already running is used as-is.
			if not connected then
				startCore(firstFreePort)
			end
		end
		return
	end

	if not ready and helloSentAtFrame and bridgeFrames - helloSentAtFrame > HELLO_ANSWER_FRAMES then
		markPortBusy(currentPort, "never answered our hello, so it is not a core we can use")
		disconnect(nil)
		return
	end

	beginPolicyFrame()

	-- Flush the buffered log every five seconds, never per line.
	if logfile and bridgeFrames % 300 == 0 then
		pcall(function() logfile:flush() end)
	end

	if snaps.runaways > 0 and bridgeFrames - snaps.at >= 60 then
		log(string.format("MeshGhost: repaired %d ghost%s found standing while the engine still "
			.. "thought they were mid-step -- the state that drags a ghost off screen. Cause not "
			.. "yet found; BANDAGES.md.", snaps.runaways, (snaps.runaways == 1) and "" or "s"))
		snaps.runaways, snaps.at = 0, bridgeFrames
	end

	-- Steady 2px re-anchors mean the step compensation is wrong; occasional big ones, frames lost elsewhere.
	if (snaps.drift or 0) > 0 and bridgeFrames - snaps.at >= 60 then
		logFile(string.format("MeshGhost: re-anchored a spawned ghost to its tile %d time%s this "
			.. "second, worst %d px off, last correction %s", snaps.drift,
			(snaps.drift == 1) and "" or "s", snaps.driftPx or 0,
			snaps.driftDir or "?"))
		snaps.drift, snaps.driftPx = 0, 0
	end
	if snaps.n > 0 and bridgeFrames - snaps.at >= 60 then
		log(string.format("MeshGhost: %d ghost snap%s in the last second (a snap is a jump the "
			.. "player can see -- it means a ghost could not walk to where its peer already was)",
			snaps.n, (snaps.n == 1) and "" or "s"))
		snaps.n, snaps.at = 0, bridgeFrames
	end

	-- STEP_LAG: player, spawned ghost and drawn model in map pixels, one line per frame any moved, fitted offline.
	if stepLag.on then
		local mt = stepLag.mv
		if not mt then
			mt = { last = "" }
			stepLag.mv = mt
		end
		local parts = {}
		local base = OBJECT_STRUCTS
		local function mappx(sb)
			local mx, my = (u8(sb + F_MAP_X) or 0) * 16, (u8(sb + F_MAP_Y) or 0) * 16
			if (u8(sb + F_WALKING) or STANDING) ~= STANDING then
				local back = stepProgress(sb) - 16
				local d = ((u8(sb + F_DIRECTION) or 0) // 4) & 3
				if d == 0 then my = my + back
				elseif d == 1 then my = my - back
				elseif d == 2 then mx = mx - back
				else mx = mx + back end
			end
			return mx, my
		end
		local px, py = mappx(base)
		-- Screen coords too: their ghost-minus-player difference is camera-free, the truth to check map px against.
		parts[#parts + 1] = string.format("P=%d,%d Ps=%d,%d", px, py,
			u8(base + F_SPRITE_X) or 0, u8(base + F_SPRITE_Y) or 0)
		for id, g in pairs(ghosts) do
			if stillOurs(g) then
				local gx, gy = mappx(g.st_base)
				parts[#parts + 1] = string.format("S[%s]=%d,%d Ss=%d,%d", id, gx, gy,
					u8(g.st_base + F_SPRITE_X) or 0, u8(g.st_base + F_SPRITE_Y) or 0)
			end
		end
		for key, o in pairs(overflow) do
			if o.modelX then
				parts[#parts + 1] = string.format("M[%s]=%d,%d paint=%s,%s", key,
					math.floor(o.modelX), math.floor(o.modelY),
					tostring(o.paintedX), tostring(o.paintedY))
			end
		end
		local line = table.concat(parts, " ")
		if line ~= mt.last then
			mt.last = line
			mt.lines = (mt.lines or 0) + 1
			logFile(string.format("mv f=%d %s", bridgeFrames, line))
		end
	end

	-- STEP_LAG: the frame the player committed to a tile (MAP_X/Y change at a step's start), before receive().
	if stepLag.on then
		local ck = (u8(OBJECT_STRUCTS + F_MAP_X) or 0) .. "," .. (u8(OBJECT_STRUCTS + F_MAP_Y) or 0)
		if stepLag.lastCommit ~= ck then
			stepLag.lastCommit = ck
			stepLag.commit[ck] = emu.framecount()
		end
		if stepLag.n > 0 and bridgeFrames - stepLag.at >= 300 then
			local function hist(h)
				local out, keys = {}, {}
				for k in pairs(h) do
					if type(k) == "number" then
						keys[#keys + 1] = k
					end
				end
				table.sort(keys)
				for _, k in ipairs(keys) do
					out[#out + 1] = string.format("%d:%d", k, h[k])
				end
				-- Spread first: a steady lag is invisible on screen, a wandering one is the stutter.
				return string.format("spread %d-%d (%d wide), mean %.2f over %d [%s]",
					h.lo or 0, h.hi or 0, (h.hi or 0) - (h.lo or 0),
					(h.n or 0) > 0 and h.sum / h.n or 0, h.n or 0, table.concat(out, " "))
			end
			-- Each with its sample count; `unknown` near `n` means the histograms are noise.
			logFile(string.format("MeshGhost: step lag over %d steps -- wire %s | apply %s | "
				.. "total %s | %d frames blocked mid-step, %d arrivals with no player frame. "
				.. "The engine acts the frame AFTER our write, so what is seen is total + 1.",
				stepLag.n, hist(stepLag.wire), hist(stepLag.apply), hist(stepLag.total),
				stepLag.blocked, stepLag.unknown)
				.. string.format(" %d frames held for STEP_TRIGGER_PROG=%d.",
					stepLag.waits or 0, STEP_TRIGGER_PROG))
			stepLag.wire, stepLag.apply, stepLag.total = {}, {}, {}
			stepLag.n, stepLag.blocked, stepLag.unknown, stepLag.waits = 0, 0, 0, 0
			stepLag.at = bridgeFrames
		end
	end

	receive()
	if not connected then
		return
	end

	-- Forget a peer silent for three seconds: a crashed or killed client sends no despawn_remote.
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

	-- A map change rebuilds the object array: forget our ghosts, never despawn (those bytes are the game's again).
	-- A battle is not a map change: its objects survive, and stillOurs() checks each one instead.
	local area = areaId()
	-- Re-read the connection block on every stable frame, so a crossing never inherits one bad read.
	if area == lastArea and ENGINE.xmap.armed() then ENGINE.xmap.build(area) end
	if area ~= lastArea then
		-- Seam or warp: a seam is a change the departing map's connections named, so ask before the rebuild.
		-- Ask both tables: either may hold the departing set, depending on whether a peer state rebuilt it first.
		local function seamTo(conns, forKey)
			return conns ~= nil and forKey == lastArea and conns[area] ~= nil
		end
		local wasSeam = seamTo(ENGINE.xmap.conns, ENGINE.xmap.connsFor)
			or seamTo(ENGINE.xmap.prevConns, ENGINE.xmap.prevFor)
		-- A timestamp, not a flag: the settle window reads it earlier in the frame than this runs.
		if wasSeam then ENGINE.xmap.seamAt = policyFrames end
		-- Computed BEFORE the rebuild, like the seam test itself, and for the same reason.
		local rebaseDX, rebaseDY = nil, nil
		if wasSeam then rebaseDX, rebaseDY = ENGINE.xmap.rebaseDelta(lastArea, area) end
		if lastArea and (MESHGHOST_CRYSTAL_XTRACE
			or os.getenv("MESHGHOST_CRYSTAL_XTRACE")) then
			ENGINE.xmap.traceUntil = policyFrames + 150
		end
		if lastArea and ENGINE.xmap.armed() then
			log(string.format("map change %s -> %s: %s", lastArea, area,
				(wasSeam and rebaseDX)
					and string.format("SEAM (painted tier rebased by %+d,%+d tiles, no fade guard)",
						rebaseDX, rebaseDY)
					or (wasSeam and "SEAM but NO REBASE DELTA -- clearing (this should not happen)")
					or "WARP (full teardown)"))
		end
		if ENGINE.xmap.armed() then ENGINE.xmap.build(area) end
		if lastArea then
			-- A seam is not a warp: no fade to guard, and painted entries are rebased rather than cleared.
			-- The spawned tier is dropped either way: the engine rebuilds its object array on any map load.
			if not wasSeam then
				playerHistory.settle = 30 -- a warp fades: do not paint over the fade-in
			end
			for id in pairs(ghosts) do
				ghosts[id] = nil
			end
			-- Painted positions are in the old map's frame: rebase them across a seam, clear them on a warp.
			if wasSeam and rebaseDX then
				for _, o in pairs(overflow) do
					ENGINE.xmap.rebaseEntry(o, rebaseDX, rebaseDY)
				end
				-- K absorbs the rebase (paint = model + camA + K), or every peer is un-drawn while the player walks.
				if facingFrames.camKX then
					facingFrames.camKX = facingFrames.camKX - rebaseDX * 16
					facingFrames.camKY = facingFrames.camKY - rebaseDY * 16
				end
			else
				overflow = {}
			end
			anchorIndex = nil -- the object array is rebuilt; last map's anchor means nothing
			-- A menu rectangle still set after a map load is stale (Fly tears its menu down by warping).
			uiSeenAt, lastMenuBox = nil, nil
			-- STEP_LAG's tile ring is per map: tile numbers repeat across maps.
			stepLag.commit, stepLag.seen, stepLag.open, stepLag.lastCommit = {}, {}, {}, nil

			-- Counted, not cleared: an empty ring makes the aged lookup fall back to this frame's own sample.
			playerHistory.since = 0
		end
		lastArea = area
	end

	-- XTRACE, off unless asked: for 150 frames after a map change, is there a frame neither tier holds the peer?
	if ENGINE.xmap.traceUntil and policyFrames <= ENGINE.xmap.traceUntil then
		local sp, pa = {}, {}
		for gid in pairs(ghosts) do sp[#sp + 1] = gid end
		for oid in pairs(overflow) do pa[#pa + 1] = oid end
		table.sort(sp)
		table.sort(pa)
		-- The stop reason may be a frame old (drawOverflow runs elsewhere in the frame); fine for attribution.
		local why = (facingFrames.stopLastAt and policyFrames - facingFrames.stopLastAt <= 1)
			and facingFrames.stopLast or nil
		logFile(string.format("XTRACE f=%d area=%s spawned{%s} painted{%s}%s%s%s", policyFrames, area,
			table.concat(sp, ","), table.concat(pa, ","),
			why and ("  NOT-DRAWN:" .. why) or "",
			facingFrames.dbgCounts and ("  [" .. facingFrames.dbgCounts .. "]") or "",
			(#sp == 0 and #pa == 0) and "   <-- NEITHER TIER: this frame draws no peer at all" or ""))
		facingFrames.dbgCounts = nil
	end

	if ready then
		local state = getLocalState()
		diagnose(state)
		send({ type = "local_state", payload = { state = state } })
		if _G.MESHGHOST_CRYSTAL_MOVE_TRACE and state and state.position then
			local p = state.position
			-- `ex=`: extras size against the core's 1024-byte cap, which refuses an over-cap state whole.
			facingFrames.mvTrace(string.format("S pos=%d,%d walk=%s dir=%s dur=%d steptype=%d act=%d face=%02X gait=%s spr=%s ex=%d art=%s",
				p[3] or -1, p[4] or -1, tostring(state.anim), tostring(state.orientation),
				u8(OBJECT_STRUCTS + F_STEP_DURATION) or -1, u8(OBJECT_STRUCTS + 0x09) or -1,
				u8(OBJECT_STRUCTS + F_ACTION) or -1, u8(OBJECT_STRUCTS + F_FACING) or 0,
				tostring(state.extras and state.extras.gait), tostring(state.extras and state.extras.sprite),
				state.extras and #jsonEncode(state.extras) or 0,
				tostring(state.extras and state.extras.arti)))
		end
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

-- Under dev-scripts/bizhawk-dev-loader.lua, hand it the per-frame function instead of taking the frame loop.
MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function()
	-- Release the bridge socket, the ghosts (real game objects) and the log handle; disconnect() does the first two.
	pcall(disconnect, nil)
	if logfile then
		pcall(function() logfile:close() end)
		logfile = nil
	end
end

if not MESHGHOST_DEV_LOADER then
	-- tick() under pcall: an error costs that frame, not the script; each distinct message is logged once.
	local lastTickError = nil
	while true do
		local ok, err = pcall(tick)
		if not ok and tostring(err) ~= lastTickError then
			lastTickError = tostring(err)
			log("MeshGhost: frame error (script continues): " .. lastTickError)
		end
		emu.frameadvance()
	end
end
