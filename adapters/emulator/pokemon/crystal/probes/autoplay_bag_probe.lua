-- MeshGhost — Pokémon Crystal: the PACK's pockets and its scrolling list, for autoplay's `menu` and `select`
-- (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-17
--
-- READ-ONLY. Load it beside the autoplay driver and autoplay_text_probe.lua (the tile buffer and the menu block);
-- open the PACK, move its cursor down past the rows it shows, switch pockets, and read this log against captures.
--
-- WHY. autoplay's `menu` reads a menu from the 2D menu block and the tile buffer, which shows only the rows on
-- screen; the PACK's item list scrolls. Our V1.0 build's .sym names the pockets (wNumItems, wNumKeyItems, wNumBalls,
-- wTMsHMs), wCurPocket, each pocket's cursor and scroll position, wMenuScrollPosition, wScrollingMenuCursorPosition,
-- wScrollingMenuListSize and the item-name table; what they read is this log's job.
--
-- WHAT IT LOGS, each group on change, every frame:
--   pocket   wCurPocket (CF65), wScrollingMenuCursorPosition (CF77), D0D9-D0E4 (the pockets' cursors and scroll
--            positions, wMenuScrollPosition), wScrollingMenuListSize (D144), wMenuCursorY/X (CFA9/CFAA), hJoyDown
--   header   wMenuFlags..wMenuDataEnd, CF81-CFA0 raw
--   items    wNumItems and 41 bytes after it (D892); keys wNumKeyItems and 26 (D8BC); balls wNumBalls and 25 (D8D7)
--   tmhm     the 57 bytes from wTMsHMs (D859)
-- And ONCE per item id met in a pocket: the id'th 0x50-ended string from 72:4000, raw and spelled with MEASURED.md's
-- letters, and its 7 bytes in the table at 01:67C1 (entry id - 1). What it cannot see: the screen (autoplay_text_probe.lua), anything between frames.
--
-- COST. About 250 bytes of WRAM a frame. Log: crystal/logs/autoplay_bag_<port>_<timestamp>.log.

local dir, port = ".", tostring(AUTOPLAY_PORT or os.getenv("AUTOPLAY_PORT") or "na")
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logdir = (dir:match("^(.*)/probes$") or dir) .. "/logs"
local logf = io.open(string.format("%s/autoplay_bag_%s_%s.log", logdir, port, os.date("%Y%m%d_%H%M%S")), "w")
if logf then logf:setvbuf("full", 16384) end
local function log(s)
	if logf then logf:write(string.format("[%s f%d] %s\n", os.date("%H:%M:%S"), emu.framecount(), s)) end
end

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local function u8(cpu) return memory.read_u8(flat(cpu), "WRAM") end
local function wram(cpu, n) return memory.read_bytes_as_array(flat(cpu), n, "WRAM") end
local function hex(b)
	local out = {}
	for i = 1, #b do out[i] = string.format("%02X", b[i]) end
	return table.concat(out, " ")
end
local function spell(b)
	local out = {}
	for i = 1, #b do
		local c = b[i]
		if c == 0x50 then break end
		if c >= 0x80 and c <= 0x99 then out[#out + 1] = string.char(0x41 + c - 0x80)
		elseif c >= 0xA0 and c <= 0xB9 then out[#out + 1] = string.char(0x61 + c - 0xA0)
		elseif c >= 0xF6 then out[#out + 1] = tostring(c - 0xF6)
		elseif c == 0x7F then out[#out + 1] = " "
		elseif c == 0xE3 then out[#out + 1] = "-"
		else out[#out + 1] = string.format("{%02X}", c) end
	end
	return table.concat(out)
end

local names
local seen = {}
local function logItem(id)
	if id == 0 or id == 0xFF or seen[id] then return end
	seen[id] = true
	if not names then names = memory.read_bytes_as_array(0x72 * 0x4000, 0x1F29, "ROM") end
	local i, n = 1, 1
	while n < id and i <= #names do
		if names[i] == 0x50 then n = n + 1 end
		i = i + 1
	end
	local b = {}
	for k = i, math.min(i + 12, #names) do b[#b + 1] = names[k] end
	local attr = memory.read_bytes_as_array(0x67C1 + (id - 1) * 7, 7, "ROM")
	log(string.format("item %d name %s spelled %s attributes %s", id, hex(b), spell(b), hex(attr)))
end

local last = {}
local function changed(key, line)
	if last[key] ~= line then
		last[key] = line
		log(key .. " " .. line)
	end
end

log("loaded")
local frames = 0

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	changed("pocket", string.format("cur %d scrollCursor %d D0D9 %s listSize %d cursorY %d cursorX %d joy %02X",
		u8(0xCF65), u8(0xCF77), hex(wram(0xD0D9, 12)), u8(0xD144), u8(0xCFA9), u8(0xCFAA), memory.read_u8(0xFFA8, "System Bus")))
	changed("header", hex(wram(0xCF81, 0x20)))
	local items, keys, balls = wram(0xD892, 42), wram(0xD8BC, 27), wram(0xD8D7, 26)
	changed("items", hex(items))
	changed("keys", hex(keys))
	changed("balls", hex(balls))
	changed("tmhm", hex(wram(0xD859, 57)))
	for k = 0, 19 do logItem(items[2 + k * 2]) end
	for k = 0, 11 do logItem(balls[2 + k * 2]) end
	for k = 1, 25 do logItem(keys[1 + k]) end
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
