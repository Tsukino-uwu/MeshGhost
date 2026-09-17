-- MeshGhost — Pokémon Emerald: every text printer and window, whole, on every change (DEV TOOL, READ-ONLY, never
-- shipped) -- 2026-09-17
--
-- WHY THIS EXISTS. autoplay's `battle` answered `stuck` after a restore to a trainer's challenge whose last box had
-- finished printing: the driver takes up only a message whose printer is still active (`agent_docs/phases/
-- phase13.md`, 2026-09-17). What a FINISHED message leaves behind -- in its printer, its window and the text before
-- the printer's pointer -- is to be measured, and what a menu or a cleared box leaves, so the two are told apart.
-- `text_probe.lua` logs a printer only when its +0x1B or +0x1C byte changes, which a restore to the same values hides.
--
-- ADDRESSES: a pokeemerald build whose ROM hashed identical to the vanilla ROM (SHA-1, 2026-09-16) proves where the
-- blocks named sTextPrinters (0x24 bytes per window id) and gWindows (12 per id) live, not what their bytes mean.
--
-- WHAT IT LOGS (printer_state_probe_<target>_<time>.log beside this file; gitignored), each on change:
--   PR w   printer w's 0x24 bytes raw, for w 0-7, and the bytes BEFORE its first word (the printer's pointer): back
--          to the previous FF, at most 256 bytes, decoded as letters where they are letters
--   WIN    window slots 0-7, 12 bytes each, raw
--   TILES  per window with a background: its base block and the tile ids in its first and last cells
--   PIX    per window with a background: how many different bytes its pixel buffer's first 16 rows hold
--   BG0    per screen row, the first and last column with a non-zero BG0 tile (textbox_probe.lua's method)
--   CB2    gMain.callback2
-- WHAT IT CANNOT SEE: windows 8-31 and their printers, anything in the frames between changes, a patched ROM.
-- COST: about 0x180 bytes read a frame and a 30x20 tile scan every 4 frames; no hooks.

local BUS = "System Bus"
local STEXTPRINTERS, PRINTER_SIZE, GWINDOWS, WINDOW_SIZE, GMAIN_CB2 = 0x020201b0, 0x24, 0x02020004, 12, 0x030022c4
local IDS = 8

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local target = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "default"):gsub("[^%w_%-]", "_")
local logf = io.open(string.format("%s/printer_state_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
local pending = {}
local function log(s) pending[#pending + 1] = string.format("f%d %s", emu.framecount(), s) end
local function flush()
	if logf and #pending > 0 then
		logf:write(table.concat(pending, "\n"), "\n")
		logf:flush() -- on a timer, never per frame
		pending = {}
	end
end

local function hex(b, from, to)
	local out = {}
	for i = from, to do out[#out + 1] = string.format("%02X", b[i]) end
	return table.concat(out)
end

-- Letters, digits and the space as the driver reads them; everything else as {XX}.
local function decode(b)
	local out = {}
	for _, c in ipairs(b) do
		if c >= 0xBB and c <= 0xD4 then
			out[#out + 1] = string.char(0x41 + c - 0xBB)
		elseif c >= 0xD5 and c <= 0xEE then
			out[#out + 1] = string.char(0x61 + c - 0xD5)
		elseif c >= 0xA1 and c <= 0xAA then
			out[#out + 1] = tostring(c - 0xA1)
		elseif c == 0x00 then
			out[#out + 1] = " "
		else
			out[#out + 1] = string.format("{%02X}", c)
		end
	end
	return table.concat(out)
end

-- The bytes before a pointer, back to (not including) the previous FF, at most 256; and whether an FF was found.
local function before(ptr)
	local inRam = ptr >= 0x02000000 and ptr < 0x02040000
	local inRom = ptr >= 0x08000000 and ptr < 0x0A000000
	if not (inRam or inRom) or ptr - 256 < (inRam and 0x02000000 or 0x08000000) then return "not RAM or ROM", false end
	local b = memory.read_bytes_as_array(ptr - 256, 256, BUS)
	local from = 1
	local found = false
	-- The byte just before the pointer is the printer's last one taken; the FF before THAT starts the string.
	for i = 255, 1, -1 do
		if b[i] == 0xFF then
			from, found = i + 1, true
			break
		end
	end
	local out = {}
	for i = from, 256 do out[#out + 1] = b[i] end
	return decode(out) .. string.format(" (last byte %02X)", b[256]), found
end

local last = {}
local function onChange(key, value, line)
	if last[key] ~= value then
		last[key] = value
		log(line)
	end
end

local frames = 0
log("printer_state_probe loaded")
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	onChange("cb2", memory.read_u32_le(GMAIN_CB2, BUS), string.format("CB2 %08X", memory.read_u32_le(GMAIN_CB2, BUS)))
	local p = memory.read_bytes_as_array(STEXTPRINTERS, PRINTER_SIZE * IDS, BUS)
	for w = 0, IDS - 1 do
		local o = w * PRINTER_SIZE
		local raw = hex(p, o + 1, o + PRINTER_SIZE)
		if last["pr" .. w] ~= raw then
			last["pr" .. w] = raw
			local ptr = p[o + 1] | (p[o + 2] << 8) | (p[o + 3] << 16) | (p[o + 4] << 24)
			local text, found = before(ptr)
			log(string.format("PR %d %s before=%s%s", w, raw, text, found and "" or " (no FF within 256)"))
		end
	end
	local wb = memory.read_bytes_as_array(GWINDOWS, WINDOW_SIZE * IDS, BUS)
	local slots = {}
	for s = 0, IDS - 1 do slots[#slots + 1] = s .. ":" .. hex(wb, s * WINDOW_SIZE + 1, s * WINDOW_SIZE + WINDOW_SIZE) end
	local ws = table.concat(slots, " ")
	onChange("win", ws, "WIN " .. ws)
	-- Added the same day: for each window that has a background, the tile ids in its first and last cells on that
	-- background (low 10 bits), beside its base block (+6, u16) -- whether a window is put on the screen, not only
	-- whether something is drawn in its top row (the START menu's frame drew into window 0's top row).
	local tiles = {}
	for s = 0, IDS - 1 do
		local o = s * WINDOW_SIZE
		local bg, left, top, width, height = wb[o + 1], wb[o + 2], wb[o + 3], wb[o + 4], wb[o + 5]
		if bg <= 3 and width > 0 and height > 0 then
			local cnt = memory.read_u16_le(0x04000008 + bg * 2, BUS)
			local base = 0x06000000 + ((cnt >> 8) & 0x1F) * 0x800
			local first = memory.read_u16_le(base + (top * 32 + left) * 2, BUS) & 0x3FF
			local lastCell = memory.read_u16_le(base + ((top + height - 1) * 32 + left + width - 1) * 2, BUS) & 0x3FF
			tiles[#tiles + 1] = string.format("%d:base=%03X first=%03X last=%03X", s, wb[o + 7] | (wb[o + 8] << 8), first, lastCell)
		end
	end
	local ts = table.concat(tiles, " ")
	onChange("tiles", ts, "TILES " .. ts)
	-- Added later the same day: an empty box read as put with a stale printer on the way back from the naming screen.
	-- For each window with a background, its pixel buffer (+8, 4 bits a pixel, width * 8 pixels a row): how many
	-- different byte values its first 16 pixel rows hold, and the most common one.
	local pix = {}
	for s = 0, IDS - 1 do
		local o = s * WINDOW_SIZE
		local bg, width, buf = wb[o + 1], wb[o + 4], wb[o + 9] | (wb[o + 10] << 8) | (wb[o + 11] << 16) | (wb[o + 12] << 24)
		if bg <= 3 and width > 0 and buf >= 0x02000000 and buf < 0x02040000 then
			local n = width * 4 * 16
			local b = memory.read_bytes_as_array(buf, n, BUS)
			local counts, distinct, top, topN = {}, 0, 0, 0
			for i = 1, n do
				local v = b[i]
				if not counts[v] then counts[v], distinct = 0, distinct + 1 end
				counts[v] = counts[v] + 1
				if counts[v] > topN then top, topN = v, counts[v] end
			end
			pix[#pix + 1] = string.format("%d:distinct=%d top=%02Xx%d/%d", s, distinct, top, topN, n)
		end
	end
	local ps = table.concat(pix, " ")
	onChange("pix", ps, "PIX " .. ps)
	if frames % 4 == 0 then
		local cnt = memory.read_u16_le(0x04000008, BUS)
		local base = 0x06000000 + ((cnt >> 8) & 0x1F) * 0x800
		local rows = {}
		for y = 0, 19 do
			local r = memory.read_bytes_as_array(base + y * 64, 60, BUS)
			local first, lastCol
			for x = 0, 29 do
				if ((r[x * 2 + 1] | (r[x * 2 + 2] << 8)) & 0x3FF) ~= 0 then
					first = first or x
					lastCol = x
				end
			end
			if first then rows[#rows + 1] = string.format("%d:%d-%d", y, first, lastCol) end
		end
		local bg = #rows > 0 and table.concat(rows, " ") or "empty"
		onChange("bg0", bg, "BG0 " .. bg)
	end
	if frames % 60 == 0 then flush() end
end
MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	flush()
	if logf then logf:close() end
	logf = nil
end
