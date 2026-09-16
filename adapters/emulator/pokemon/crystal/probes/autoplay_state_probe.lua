-- MeshGhost — Pokémon Crystal: what the game's state bytes read, frame by frame, for autoplay's
-- crystal.lua (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-17
--
-- READ-ONLY. Writes nothing, presses nothing, spawns nothing. Load it beside the autoplay driver
-- (the dev loader takes several targets) and drive the game with the driver's own tools; this probe
-- is the timeline those tools' answers are read against.
--
-- WHY. autoplay/drivers/bizhawk/games/crystal.lua needs `mode` (overworld, battle, anything else),
-- `location` (map and tile) and, for `walk`, when a step begins, ends and is refused. Our V1.0
-- build's .sym says WHERE the candidates live; what each reads in which state is this log's job.
--
-- WHAT IT LOGS. One line whenever any watched byte changes, with the frame number, every watched
-- value (not only the changed one: the neighbours are what make a line readable), and the player
-- struct's 0x28 bytes whenever they change. Also, once at load, the ROM title and
-- gameinfo.getromhash(). What it cannot see: anything between frames, and any byte not listed.
--
-- COST. About 60 byte reads a frame and one string compare; the log is buffered and flushed every
-- 120 frames, never per line (adapters/emulator/CLAUDE.md). Log:
-- crystal/logs/autoplay_state_<port>_<timestamp>.log -- the port keeps two instances apart.

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local function u8(a) return memory.read_u8(a, "WRAM") end
local function hram(a) return memory.read_u8(a, "System Bus") end

-- Addresses: pokecrystal.sym of our V1.0 build, whose .gbc hashes identical to the vanilla ROM.
local W = {
	{ "mapGroup", flat(0xDCB5) }, { "mapNumber", flat(0xDCB6) }, { "yCoord", flat(0xDCB7) }, { "xCoord", flat(0xDCB8) },
	{ "mapStatus", flat(0xD432) }, { "mapEventStatus", flat(0xD433) }, { "scriptFlags", flat(0xD434) },
	{ "scriptMode", flat(0xD437) }, { "scriptRunning", flat(0xD438) },
	{ "battleMode", flat(0xD22D) }, { "battleType", flat(0xD230) }, { "battleResult", flat(0xD0EE) },
	{ "stateFlags", flat(0xD0ED) }, { "playerState", flat(0xD95D) }, { "gameLogicPaused", flat(0xC2CD) },
	{ "spriteUpdatesEnabled", flat(0xC2CE) }, { "partyCount", flat(0xDCD7) },
	{ "walkingDirection", flat(0xD043) }, { "playerStepDirection", flat(0xD151) },
	{ "playerMovement", flat(0xC2DF) }, { "playerNextMovement", flat(0xC2DE) },
	{ "movementAnimation", flat(0xD042) }, { "turningDirection", flat(0xD04E) },
	{ "tileDown", flat(0xC2FA) }, { "tileUp", flat(0xC2FB) }, { "tileLeft", flat(0xC2FC) }, { "tileRight", flat(0xC2FD) },
	{ "joypadDisable", flat(0xCFBE) }, { "windowStackPtrLo", flat(0xCF71) }, { "windowStackPtrHi", flat(0xCF72) },
	{ "textboxFlags", flat(0xCFCF) }, { "menuCursorY", flat(0xCFA9) }, { "menuCursorX", flat(0xCFAA) },
	{ "menuFlags", flat(0xCF81) }, { "menuDataFlags", flat(0xCF91) }, { "menuFlags2d", flat(0xCFA5) },
	{ "options", flat(0xCFCC) }, { "curInput", flat(0xD03E) }, { "linkMode", flat(0xC2DC) },
	{ "warpNumber", flat(0xDCB4) }, { "mapWidth", flat(0xD19F) }, { "mapHeight", flat(0xD19E) },
	{ "tileset", flat(0xD1D9) }, { "stepCount", flat(0xDC73) }, { "bikeFlags", flat(0xDBF5) },
}
local H = {
	{ "hInMenu", 0xFFAA }, { "hBGMapMode", 0xFFD4 }, { "hMapAnims", 0xFFDE }, { "hOAMUpdate", 0xFFD8 },
	{ "hJoyDown", 0xFFA8 }, { "hMapEntryMethod", 0xFF9F },
}
local PLAYER_STRUCT, STRUCT_SIZE = flat(0xD4D6), 0x28

local dir, port = ".", tostring(AUTOPLAY_PORT or os.getenv("AUTOPLAY_PORT") or "na")
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logdir = (dir:match("^(.*)/probes$") or dir) .. "/logs"
local logf = io.open(string.format("%s/autoplay_state_%s_%s.log", logdir, port, os.date("%Y%m%d_%H%M%S")), "w")
if logf then logf:setvbuf("full", 65536) end
local function log(s)
	if logf then logf:write(string.format("[%s f%d] %s\n", os.date("%H:%M:%S"), emu.framecount(), s)) end
end

do
	local title = {}
	for i = 0x134, 0x13E do
		local c = memory.read_u8(i, "ROM")
		if c == 0 then break end
		title[#title + 1] = string.char(c)
	end
	local ok, h = pcall(gameinfo.getromhash)
	log(string.format("loaded: ROM title %q, getromhash %s, domains %s", table.concat(title), ok and tostring(h) or "error",
		table.concat(memory.getmemorydomainlist(), ",")))
end

local last, lastStruct, frames = nil, nil, 0

local function hex(bytes)
	local out = {}
	for i = 1, #bytes do out[i] = string.format("%02X", bytes[i]) end
	return table.concat(out, " ")
end

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local parts = {}
	for _, e in ipairs(W) do parts[#parts + 1] = e[1] .. "=" .. u8(e[2]) end
	for _, e in ipairs(H) do parts[#parts + 1] = e[1] .. "=" .. hram(e[2]) end
	local line = table.concat(parts, " ")
	if line ~= last then
		log(line)
		last = line
	end
	local s = hex(memory.read_bytes_as_array(PLAYER_STRUCT, STRUCT_SIZE, "WRAM"))
	if s ~= lastStruct then
		log("player " .. s)
		lastStruct = s
	end
	if logf and frames % 120 == 0 then logf:flush() end
end

MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	if logf then
		logf:flush()
		logf:close()
	end
	logf = nil
end
