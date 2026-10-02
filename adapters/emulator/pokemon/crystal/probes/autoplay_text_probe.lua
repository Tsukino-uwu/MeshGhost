-- Read-only dev tool for autoplay's crystal.lua: logs the screen's tile rows, the menu block and the text, script and
-- joypad bytes on change, to settle which bytes mean a waiting message box, an open menu, the cursor and each letter.
-- Load it beside the autoplay driver; read it against captures. Blind to VRAM and between frames; logs in crystal/logs.

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local function u8(a) return memory.read_u8(a, "WRAM") end
local function hram(a) return memory.read_u8(a, "System Bus") end

local TILEMAP, MENU_BLOCK = flat(0xC4A0), flat(0xCF71)
local STATE = {
	{ "scriptRunning", flat(0xD438) }, { "scriptMode", flat(0xD437) }, { "stateFlags", flat(0xD0ED) },
	{ "textboxFlags", flat(0xCFCF) }, { "textDelayFrames", flat(0xCFB2) }, { "spriteUpdates", flat(0xC2CE) },
}
local HSTATE = { { "hBGMapMode", 0xFFD4 }, { "hJoyDown", 0xFFA8 }, { "hJoyPressed", 0xFFA7 } }

local dir, port = ".", tostring(AUTOPLAY_PORT or os.getenv("AUTOPLAY_PORT") or "na")
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logdir = (dir:match("^(.*)/probes$") or dir) .. "/logs"
local logf = io.open(string.format("%s/autoplay_text_%s_%s.log", logdir, port, os.date("%Y%m%d_%H%M%S")), "w")
if logf then logf:setvbuf("full", 65536) end
local function log(s)
	if logf then logf:write(string.format("[%s f%d] %s\n", os.date("%H:%M:%S"), emu.framecount(), s)) end
end

local function hex(bytes)
	local out = {}
	for i = 1, #bytes do out[i] = string.format("%02X", bytes[i]) end
	return table.concat(out, " ")
end

local rows, lastMenu, lastState, lastHram, frames = {}, nil, nil, nil, 0
log("loaded")

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	for r = 0, 17 do
		local s = hex(memory.read_bytes_as_array(TILEMAP + r * 20, 20, "WRAM"))
		if s ~= rows[r] then
			log(string.format("row %02d %s", r, s))
			rows[r] = s
		end
	end
	local m = hex(memory.read_bytes_as_array(MENU_BLOCK, 0x40, "WRAM"))
	if m ~= lastMenu then
		log("menu " .. m)
		lastMenu = m
	end
	local parts = {}
	for _, e in ipairs(STATE) do parts[#parts + 1] = e[1] .. "=" .. u8(e[2]) end
	for _, e in ipairs(HSTATE) do parts[#parts + 1] = e[1] .. "=" .. hram(e[2]) end
	local st = table.concat(parts, " ")
	if st ~= lastState then
		log("state " .. st)
		lastState = st
	end
	-- AUTOPLAY_TEXT_PROBE_HRAM=1 adds all of HRAM on change; off by default, as much of it changes every frame.
	if (AUTOPLAY_TEXT_PROBE_HRAM or os.getenv("AUTOPLAY_TEXT_PROBE_HRAM")) == "1" then
		local h = hex(memory.read_bytes_as_array(0xFF80, 0x7F, "System Bus"))
		if h ~= lastHram then
			log("hram " .. h)
			lastHram = h
		end
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
