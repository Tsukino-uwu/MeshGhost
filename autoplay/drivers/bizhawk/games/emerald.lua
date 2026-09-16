-- autoplay BizHawk driver: vanilla Pokémon Emerald (DEV TOOL, never shipped).
--
-- The position and warp addresses are ones `adapters/emulator/pokemon/emerald/probes/cmd_drive.lua`
-- already uses, and that file's header says what was measured and when (vanilla, 2026-09-16). Where a
-- byte's MEANING is not measured -- a facing or an action code -- the value goes out raw and unnamed.
-- `mode` says whether gMain.callback2 is vanilla's overworld callback, and the warp cheat refuses when
-- it is not, as `cmd_drive.lua`'s `warp` does.
--
-- TEXT AND MENUS (measured 2026-09-16 with `emerald/probes/text_probe.lua` and `charset_probe.lua` on
-- the vanilla ROM whose SHA-1 is VANILLA_SHA1; the record is that adapter's MEASURED.md, same date).
-- Addresses come from a pokeemerald build hashed identical to that ROM; what each byte means is what
-- the probes showed. Only on that ROM are the hooks installed; anywhere else `dialogue`, `menu` and
-- `screen_text` are absent.

local BUS = "System Bus"
local GPLAYERAVATAR, GOBJECTEVENTS = 0x02037590, 0x02037350
local SB1PTR = 0x03005d8c
local GMAIN_CB2, CB2_OVERWORLD, CB2_LOADMAP = 0x030022c4, 0x08085e5c, 0x08085fcc
local GFIELDCALLBACK, FIELDCB_DEFAULTWARPEXIT = 0x03005dac, 0x080af398
local SWARPDESTINATION = 0x020322e4

local function r8(a) return memory.read_u8(a, BUS) end
local function r16(a) return memory.read_u16_le(a, BUS) end
local function r32(a) return memory.read_u32_le(a, BUS) end
local function w8(a, v) memory.write_u8(a, v, BUS) end
local function w16(a, v) memory.write_u16_le(a, v, BUS) end
local function w32(a, v) memory.write_u32_le(a, v, BUS) end

-- gameinfo.getromhash() on the vanilla ROM, equal to its sha1sum and to our pokeemerald build's
-- (all three compared 2026-09-16).
local VANILLA_SHA1 = "F3AE088181BF583E55DAF962A92BB46F4F1D07B7"
local romHash = (function()
	local ok, h = pcall(gameinfo.getromhash)
	return ok and type(h) == "string" and h:upper() or ""
end)()
local isVanilla = romHash == VANILLA_SHA1

-- Execute hooks, at the entry of routines named in the build: text_probe.lua saw each fire with a
-- window id in R0 (AddTextPrinter: a pointer to a template whose first word points at the string,
-- +4 the window, +6/+7 x and y; R1 the speed).
local ADDTEXTPRINTER, FILLWINDOWPIXELBUFFER, REMOVEWINDOW, CLEARWINDOWTILEMAP, MENU_MOVECURSOR =
	0x0800467c, 0x08003c48, 0x08003574, 0x080038a4, 0x081984d8
-- The routine named InitWindows: window_life_probe.lua saw it rewrite the whole window table when the
-- START menu gave way to the party menu and again on the way back, after FreeAllWindowBuffers and with
-- no RemoveWindow for the START menu's window 1 -- which the party menu then reused (2026-09-16).
local INITWINDOWS = 0x080031c0
-- 0x24 bytes per window id. +0x1B is 1 while a message is on its way (printing or waiting on its
-- arrow) and 0 once its end is reached; +0x1C is 0 while printing and 2 while the red arrow waits for
-- a button. Other +0x1C values are not measured and go out raw.
local STEXTPRINTERS, PRINTER_SIZE = 0x020201b0, 0x24
-- 12 bytes per window id: +0 the background (FF once removed), +1 left, +2 top, +3 width, +4 height,
-- in tiles -- matched against the drawn BG0 cells for the START menu and the message box.
local GWINDOWS, WINDOW_SIZE = 0x02020004, 12
-- +1 top, +2 cursor, +4 last index, +5 window, +8 row height; it keeps its old values after the menu
-- closes, which is why a menu counts as open from the routine named Menu_MoveCursor (which both of
-- its setups call, the START menu's and the YES/NO's) until its window is cleared or removed.
local SMENU = 0x0203cd90
-- Font 1 with no extra line spacing: the second line of a message box and the NO of a YES/NO sat 16px
-- below the first.
local LINE_ADVANCE = 16
local CURSOR, NEWLINE, NEXT_BOX, EOS = 0xEF, 0xFE, 0xFB, 0xFF

-- The character each byte draws, read off the screen: bytes 00-F7 drawn by the game's own text printer
-- in a message box (charset_probe.lua) and the START menu, the nurse's dialogue and a YES/NO. The
-- letters in ordinary text agreed with the full pass. A byte that draws nothing, or one not listed, goes
-- out as {XX}; 00 is the space between words.
local CHARS = { [0x00] = " " }
for i = 0, 25 do
	CHARS[0xBB + i] = string.char(0x41 + i)
	CHARS[0xD5 + i] = string.char(0x61 + i)
end
for i = 0, 9 do CHARS[0xA1 + i] = tostring(i) end
do
	local drawn = {
		[0x01] = "À", [0x02] = "Á", [0x03] = "Â", [0x04] = "Ç", [0x05] = "È", [0x06] = "É", [0x07] = "Ê",
		[0x08] = "Ë", [0x09] = "Ì", [0x0B] = "Î", [0x0C] = "Ï", [0x0D] = "Ò", [0x0E] = "Ó", [0x0F] = "Ô",
		[0x10] = "Œ", [0x11] = "Ù", [0x12] = "Ú", [0x13] = "Û", [0x14] = "Ñ", [0x15] = "ß", [0x16] = "à",
		[0x17] = "á", [0x19] = "ç", [0x1A] = "è", [0x1B] = "é", [0x1C] = "ê", [0x1D] = "ë", [0x1E] = "ì",
		[0x20] = "î", [0x21] = "ï", [0x22] = "ò", [0x23] = "ó", [0x24] = "ô", [0x25] = "œ", [0x26] = "ù",
		[0x27] = "ú", [0x28] = "û", [0x29] = "ñ", [0x2A] = "º", [0x2B] = "ª", [0x2C] = "ᵉʳ", [0x2D] = "&",
		[0x2E] = "+", [0x34] = "Lv", [0x35] = "=", [0x36] = ";", [0x51] = "¿", [0x52] = "¡", [0x53] = "PK",
		[0x54] = "MN", [0x55] = "PO", [0x56] = "Ké", [0x57] = "BL", [0x58] = "OCK", [0x5A] = "Í",
		[0x5B] = "%", [0x5C] = "(", [0x5D] = ")", [0x68] = "â", [0x6F] = "í", [0x79] = "↑", [0x7A] = "↓",
		[0x7B] = "←", [0x7C] = "→", [0x84] = "ᵉ", [0x85] = "<", [0x86] = ">", [0xA0] = "ʳᵉ", [0xAB] = "!",
		[0xAC] = "?", [0xAD] = ".", [0xAE] = "-", [0xAF] = "·", [0xB0] = "…", [0xB1] = "“", [0xB2] = "”",
		[0xB3] = "‘", [0xB4] = "’", [0xB5] = "♂", [0xB6] = "♀", [0xB7] = "₽", [0xB8] = ",", [0xB9] = "×",
		[0xBA] = "/", [0xEF] = "▶", [0xF0] = ":", [0xF1] = "Ä", [0xF2] = "Ö", [0xF3] = "Ü", [0xF4] = "ä",
		[0xF5] = "ö", [0xF6] = "ü",
	}
	for b, s in pairs(drawn) do CHARS[b] = s end
end

local function decode(bytes, from, to)
	local out = {}
	for i = from, to do
		local b = bytes[i]
		if b == NEWLINE then
			out[#out + 1] = "\n"
		else
			out[#out + 1] = CHARS[b] or string.format("{%02X}", b)
		end
	end
	return table.concat(out)
end

-- Bytes from a pointer up to the first FF, which is not kept; at most 1024.
local function readString(at)
	local out = {}
	if at < 0x02000000 or at >= 0x0A000000 then return out end
	for chunk = 0, 15 do
		local b = memory.read_bytes_as_array(at + chunk * 64, 64, BUS)
		for i = 1, 64 do
			if b[i] == EOS then return out end
			out[#out + 1] = b[i]
		end
	end
	return out
end

-- What the game has printed and not yet cleared, per window id: { {x, y, bytes} }. Strings are
-- copied when printing starts, since the buffer they come from is reused by the next one.
local shown = {}
local dialogue = nil -- { window, bytes, start }: the last string printed letter by letter
local menuWindow = nil

local function printerActive(w)
	return r8(STEXTPRINTERS + w * PRINTER_SIZE + 0x1B) == 1
end

local hooks = {}
function hooks.addTextPrinter()
	local tmpl = emu.getregister("R0")
	local t = memory.read_bytes_as_array(tmpl, 8, BUS)
	local ptr = t[1] | (t[2] << 8) | (t[3] << 16) | (t[4] << 24)
	local w, x, y, speed = t[5], t[7], t[8], emu.getregister("R1")
	local bytes = readString(ptr)
	local entry = { x = x, y = y, bytes = bytes }
	local list = shown[w] or {}
	shown[w] = list
	for i, e in ipairs(list) do
		if e.x == x and e.y == y then
			list[i] = entry
			entry = nil
			break
		end
	end
	if entry then list[#list + 1] = entry end
	-- Speed 0 and 255 print at once (the START menu's items and cursor); anything else runs a printer.
	if speed ~= 0 and speed ~= 255 then
		dialogue = { window = w, bytes = bytes, start = ptr }
	end
end
function hooks.fillWindowPixelBuffer()
	-- A message clears its own window between boxes while its printer runs; that keeps its text.
	local w = emu.getregister("R0")
	if not printerActive(w) then shown[w] = nil end
end
function hooks.removeWindow()
	local w = emu.getregister("R0")
	shown[w] = nil
	if menuWindow == w then menuWindow = nil end
	if dialogue and dialogue.window == w then dialogue = nil end
end
function hooks.clearWindowTilemap()
	local w = emu.getregister("R0")
	if menuWindow == w then menuWindow = nil end
	if dialogue and dialogue.window == w then dialogue = nil end
end
function hooks.menuMoveCursor()
	menuWindow = r8(SMENU + 5)
end
-- A new screen's windows: nothing printed or opened before belongs to any window id now.
function hooks.initWindows()
	shown, dialogue, menuWindow = {}, nil, nil
end

local HOOKS = {
	{ at = INITWINDOWS, fn = hooks.initWindows },
	{ at = ADDTEXTPRINTER, fn = hooks.addTextPrinter },
	{ at = FILLWINDOWPIXELBUFFER, fn = hooks.fillWindowPixelBuffer },
	{ at = REMOVEWINDOW, fn = hooks.removeWindow },
	{ at = CLEARWINDOWTILEMAP, fn = hooks.clearWindowTilemap },
	{ at = MENU_MOVECURSOR, fn = hooks.menuMoveCursor },
}
local hookNames, hookErrors = {}, 0

-- On screen: the window exists and its top row of tiles is drawn on its background.
local function windowOnScreen(w)
	if w < 0 or w > 31 then return nil end
	local s = memory.read_bytes_as_array(GWINDOWS + w * WINDOW_SIZE, 5, BUS)
	local bg, left, top, width = s[1], s[2], s[3], s[4]
	if bg > 3 or width == 0 then return nil end
	local cnt = memory.read_u16_le(0x04000008 + bg * 2, BUS)
	local row = memory.read_bytes_as_array(0x06000000 + ((cnt >> 8) & 0x1F) * 0x800 + (top * 32 + left) * 2, width * 2, BUS)
	for i = 1, width * 2, 2 do
		if ((row[i] | (row[i + 1] << 8)) & 0x3FF) ~= 0 then return { left = left, top = top } end
	end
	return nil
end

-- A string's lines, each with its own y: a newline starts the next line LINE_ADVANCE lower, and a
-- next-box byte starts again at the string's own y.
local function linesOf(e, out)
	local y, from = e.y, 1
	local b = e.bytes
	for i = 1, #b + 1 do
		local c = b[i]
		if c == nil or c == NEWLINE or c == NEXT_BOX then
			if i > from then
				local only = true
				for k = from, i - 1 do
					if b[k] ~= CURSOR then only = false end
				end
				if not only then out[#out + 1] = { x = e.x, y = y, text = decode(b, from, i - 1) } end
			end
			y = (c == NEXT_BOX) and e.y or (y + LINE_ADVANCE)
			from = i + 1
		end
	end
	return out
end

local function windowLines(w)
	local segs = {}
	for _, e in ipairs(shown[w] or {}) do linesOf(e, segs) end
	table.sort(segs, function(a, b) return a.y < b.y or (a.y == b.y and a.x < b.x) end)
	local lines = {}
	for _, s in ipairs(segs) do
		local last = lines[#lines]
		if last and last.y == s.y then
			last.text = last.text .. " " .. s.text
		else
			lines[#lines + 1] = { y = s.y, text = s.text }
		end
	end
	return lines
end

local function readDialogue()
	if not dialogue or not windowOnScreen(dialogue.window) then return nil end
	local p = STEXTPRINTERS + dialogue.window * PRINTER_SIZE
	local active, stateRaw = r8(p + 0x1B) == 1, r8(p + 0x1C)
	local b = dialogue.bytes
	-- Boxes: split at each next-box byte. The box being shown is the one the printer is in, or the
	-- last one once the printer has reached the end.
	local boxes, from = {}, 1
	for i = 1, #b + 1 do
		if b[i] == nil or b[i] == NEXT_BOX then
			boxes[#boxes + 1] = { from = from, to = i - 1 }
			from = i + 1
		end
	end
	local index = #boxes
	if active then
		-- The printer's pointer is one past the last byte it took. Waiting on its arrow it has just taken
		-- the next-box byte (the nurse's first box: pointer 42 bytes in, that byte at 41), which still
		-- belongs to the box on screen; while printing, taking it means the next box has begun.
		local consumed = r32(p) - dialogue.start
		for i, box in ipairs(boxes) do
			if consumed <= ((stateRaw == 2) and box.to + 1 or box.to) then
				index = i
				break
			end
		end
	end
	local state
	if not active then
		state = "finished"
	elseif stateRaw == 0 then
		state = "printing"
	elseif stateRaw == 2 then
		state = "waiting_for_button"
	else
		state = string.format("printer_state_%d", stateRaw)
	end
	return {
		window = dialogue.window,
		state = state,
		box = decode(b, boxes[index].from, boxes[index].to),
		box_index = index,
		boxes = #boxes,
	}
end

local function readMenu()
	if not menuWindow or not windowOnScreen(menuWindow) then return nil end
	local m = memory.read_bytes_as_array(SMENU, 12, BUS)
	local top, cursor, last, w, height = m[2], m[3], m[5], m[6], m[9]
	if w ~= menuWindow then return nil end
	if cursor > 127 then cursor = cursor - 256 end
	local lines = windowLines(w)
	local items = {}
	for i = 0, last do
		local y, text = top + i * height, {}
		for _, l in ipairs(lines) do
			if l.y == y then text[#text + 1] = l.text end
		end
		items[#items + 1] = table.concat(text, " ")
	end
	return { window = w, cursor = cursor, items = items }
end

local function readScreenText(skipA, skipB)
	local out = {}
	for w, list in pairs(shown) do
		local at = w ~= skipA and w ~= skipB and #list > 0 and windowOnScreen(w)
		if at then
			local texts = {}
			for _, l in ipairs(windowLines(w)) do texts[#texts + 1] = l.text end
			if #texts > 0 then out[#out + 1] = { window = w, top = at.top, left = at.left, lines = texts } end
		elseif not windowOnScreen(w) and r8(GWINDOWS + w * WINDOW_SIZE) == 0xFF then
			shown[w] = nil
		end
	end
	table.sort(out, function(a, b) return a.top < b.top or (a.top == b.top and a.left < b.left) end)
	for _, o in ipairs(out) do o.top, o.left = nil, nil end
	return out
end

-- THE MAP AROUND THE PLAYER (2026-09-16, vanilla: `emerald/probes/map_probe.lua` and `step_probe.lua`
-- read against captures and walks; that adapter's MEASURED.md, same date).
local GBACKUPMAPLAYOUT, GMAPHEADER = 0x03005dc0, 0x02037318
-- SaveBlock1's position plus 7 is the player object's coordinate, and the grid is addressed by it
-- (width at +0, the entries' pointer at +8; cmd_drive.lua's `grid`): five walked positions agreed.
local MAP_OFFSET = 7
local VIEW_W, VIEW_H = 7, 5 -- tiles either side: 15 by 11, a little more than the screen
local OBJ_SIZE = 0x24

local function inRom(p) return p >= 0x08000000 and p < 0x0A000000 end
local function playerSlot() return r8(GPLAYERAVATAR + 5) end
local function playerObject() return GOBJECTEVENTS + playerSlot() * OBJ_SIZE end

-- A grid entry's low 10 bits pick a metatile; its attribute word's low byte is the behaviour (ids from
-- 512 in the second tileset: cmd_drive.lua's `mtscan`). Collision is bits 10-11 and elevation 12-15
-- (VERIFIED.md, 2026-08-18 and 2026-08-20).
local behaviourCache = {}
local function behaviourOf(id)
	local layout = r32(GMAPHEADER)
	if behaviourCache.layout ~= layout then behaviourCache = { layout = layout } end
	local b = behaviourCache[id]
	if b == nil then
		b = -1
		if inRom(layout) then
			local k, index = 0, id
			if id >= 512 then k, index = 1, id - 512 end
			local ts = r32(layout + 0x10 + k * 4)
			local attrs = inRom(ts) and r32(ts + 0x10) or 0
			if inRom(attrs) then b = r16(attrs + index * 2) & 0xFF end
		end
		behaviourCache[id] = b
	end
	return b
end

-- The header's second pointer holds four counts; the second count's list is 8 bytes an entry, x and y
-- at +0/+2 and the destination's map number and group at +6/+7. The Center door we walked into from
-- (6,17) on map 0.10 is its entry (6,16) -> 2.2, and both listed doors there sit on behaviour 0x69.
local function readWarps()
	local out, events = {}, r32(GMAPHEADER + 4)
	if not inRom(events) then return out end
	local n, list = r8(events + 1), r32(events + 8)
	if not inRom(list) then return out end
	for i = 0, math.min(n, 64) - 1 do
		local e = memory.read_bytes_as_array(list + i * 8, 8, BUS)
		out[#out + 1] = { x = e[1] | (e[2] << 8), y = e[3] | (e[4] << 8), to = string.format("%d.%d", e[8], e[7]) }
	end
	return out
end

-- The other characters: object slots whose first byte has bit 0 set; +0x05 the graphic, +0x08 the
-- local id, +0x10/+0x12 where it stands. On map 0.10 two slots' ids, graphics and first positions
-- matched the map's own list, and the positions matched where the capture drew them.
local function readObjects()
	local out, me = {}, playerSlot()
	for s = 0, 15 do
		local b = memory.read_bytes_as_array(GOBJECTEVENTS + s * OBJ_SIZE, 0x14, BUS)
		if (b[1] & 1) == 1 and s ~= me then
			out[#out + 1] = { slot = s, local_id = b[9], graphics_id = b[6],
				x = (b[17] | (b[18] << 8)) - MAP_OFFSET, y = (b[19] | (b[20] << 8)) - MAP_OFFSET }
		end
	end
	return out
end

-- Rows of characters centred on the player, and a legend for the symbols that appear.
local function readLocalMap(warps, objects)
	local obj = playerObject()
	local px, py = r16(obj + 0x10), r16(obj + 0x12)
	local elevation = r8(obj + 0x0B) & 0x0F
	local width, height, grid = r32(GBACKUPMAPLAYOUT), r32(GBACKUPMAPLAYOUT + 4), r32(GBACKUPMAPLAYOUT + 8)
	-- The map's own size is the header's first pointer's +0/+4; the grid is 15 wider and 14 taller (map
	-- 0.10: 20 by 20 against 35 by 34), the map starting MAP_OFFSET in. The rest is border.
	local layout = r32(GMAPHEADER)
	local mapW, mapH = width, height
	if inRom(layout) then mapW, mapH = r32(layout), r32(layout + 4) end
	local marks = {}
	for _, w in ipairs(warps) do marks[(w.x + MAP_OFFSET) * 65536 + w.y + MAP_OFFSET] = "W" end
	for _, o in ipairs(objects) do marks[(o.x + MAP_OFFSET) * 65536 + o.y + MAP_OFFSET] = "N" end
	marks[px * 65536 + py] = "@"
	local letters, nextLetter, used, rows = {}, 0, {}, {}
	for dy = -VIEW_H, VIEW_H do
		local y, row = py + dy, {}
		local x0, x1 = px - VIEW_W, px + VIEW_W
		local cells
		if y >= 0 and y < height and x1 >= 0 and x0 < width then
			local a, b = math.max(x0, 0), math.min(x1, width - 1)
			cells = { from = a, to = b, bytes = memory.read_bytes_as_array(grid + (a + width * y) * 2, (b - a + 1) * 2, BUS) }
		end
		for x = x0, x1 do
			local ch = marks[x * 65536 + y]
			if not ch then
				if not cells or x < cells.from or x > cells.to then
					ch = " "
				elseif x < MAP_OFFSET or y < MAP_OFFSET or x >= MAP_OFFSET + mapW or y >= MAP_OFFSET + mapH then
					ch = ":"
				else
					local i = (x - cells.from) * 2 + 1
					local v = cells.bytes[i] | (cells.bytes[i + 1] << 8)
					local beh = behaviourOf(v & 0x3FF)
					if (v & 0x0C00) ~= 0 then
						ch = "#"
					elseif beh > 0 then
						ch = letters[beh]
						if not ch then
							ch = string.char(0x61 + nextLetter % 26)
							letters[beh], nextLetter = ch, nextLetter + 1
						end
					elseif (v >> 12) == elevation then
						ch = "."
					else
						ch = string.format("%X", v >> 12)
					end
				end
			end
			used[ch] = true
			row[#row + 1] = ch
		end
		rows[#rows + 1] = table.concat(row)
	end
	local legend = {}
	local fixed = {
		{ "@", "you" }, { "N", "a character (nearby lists them)" }, { "W", "a warp (warps says where to)" },
		{ "#", "collision set: a step into it was refused" }, { ".", "clear, at your elevation" },
		{ ":", "beyond this map's edge: a connected map's edge, or filler (not measured which)" },
		{ " ", "outside the grid" },
	}
	for _, f in ipairs(fixed) do
		if used[f[1]] then legend[#legend + 1] = f[1] .. " " .. f[2] end
	end
	for beh, ch in pairs(letters) do
		legend[#legend + 1] = string.format("%s behaviour 0x%02X%s", ch, beh,
			beh == 0x3B and " (a ledge: walked into going down, it hopped two tiles)" or "")
	end
	for e = 0, 15 do
		local ch = string.format("%X", e)
		if used[ch] then legend[#legend + 1] = ch .. " clear, at elevation " .. e .. " (yours is " .. elevation .. "; not measured whether a step onto it is allowed)" end
	end
	table.sort(legend)
	return { rows = rows, legend = legend }
end

-- WHAT THIS SAVE HAS (2026-09-16, vanilla: `emerald/probes/party_bag_probe.lua` read against captures of
-- the party menu, three summary pages, all five bag pockets and the trainer card, and
-- `substruct_order_probe.lua`; that adapter's MEASURED.md, same date).
local SB2PTR = 0x03005d90
local PARTY_COUNT, PARTY, MON_SIZE = 0x020244e9, 0x020244ec, 0x64
-- Name tables in the ROM, one fixed-width entry per id: species 11 bytes, moves 13, items 44 with the
-- name in the first 14. The counts are the build's symbol sizes over those widths.
local SPECIES_NAMES, SPECIES_LEN, SPECIES_COUNT = 0x083185c8, 11, 412
local MOVE_NAMES, MOVE_LEN, MOVE_COUNT = 0x0831977c, 13, 355
local ITEMS, ITEM_SIZE, ITEM_NAME_LEN, ITEM_COUNT = 0x085839a0, 44, 14, 377
-- SaveBlock1's pockets in the bag's own order (ITEMS, POKé BALLS, TMs & HMs, BERRIES, KEY ITEMS), 4
-- bytes a slot: the id, then the quantity XOR the low half of SaveBlock2 +0xAC. The item table's
-- +0x1A byte is the pocket's number in that order: every item this save held sat in the pocket its
-- byte named, and give_item's ORAN BERRY (byte 4) was drawn under BERRIES. Slot counts are the build's
-- layout.
local POCKETS = {
	{ name = "items", at = 0x560, slots = 30 },
	{ name = "poke_balls", at = 0x650, slots = 16 },
	{ name = "tms_hms", at = 0x690, slots = 64 },
	{ name = "berries", at = 0x790, slots = 46 },
	{ name = "key_items", at = 0x5D8, slots = 30 },
}
local FLAGS_AT, FLAG_MAX = 0x1270, 0x95F
-- Flag 0x867 + i is the trainer card's badge i + 1, left to right: three cards drawn with a different
-- binary pattern of the eight cleared named every position, and setting one back redrew it.
local BADGE_FLAG0 = 0x867
local MAX_STACK = 99

local function inEwram(p) return p >= 0x02000000 and p < 0x02040000 end
local function u32of(b, i) return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24) end
local function u16of(b, i) return b[i] | (b[i + 1] << 8) end

-- A name from the ROM: up to the first FF within `len` bytes of entry `id` (`stride` apart, when the
-- entry is wider than its name).
local function nameAt(tbl, len, count, id, stride)
	if not id or id < 1 or id >= count then return nil end
	local b = memory.read_bytes_as_array(tbl + id * (stride or len), len, BUS)
	local last = len
	for i = 1, len do
		if b[i] == EOS then
			last = i - 1
			break
		end
	end
	return decode(b, 1, last)
end
local function itemName(id) return nameAt(ITEMS, ITEM_NAME_LEN, ITEM_COUNT, id, ITEM_SIZE) end

-- The four encrypted 12-byte blocks at +0x20, per personality mod 24: the game's routine for them,
-- asked for every residue with every kind (substruct_order_probe.lua, 96 of 96, no conflicts), put
-- residue r's kinds in the r-th ordering of 0-3 in lexicographic order (0 -> 0,1,2,3; 1 -> 0,1,3,2;
-- 23 -> 3,2,1,0). Kind 0 held species, held item and EXP; kind 1 moves and PP; kind 3 the met level
-- (all three matched the summary pages).
local function blockOfKind(residue, kind)
	local pool, r, fact = { 0, 1, 2, 3 }, residue, { 6, 2, 1, 1 }
	for pos = 1, 4 do
		local k = table.remove(pool, r // fact[pos] + 1)
		r = r % fact[pos]
		if k == kind then return pos - 1 end
	end
end

local function readParty()
	local n = r8(PARTY_COUNT)
	if n > 6 then return nil end
	local out = {}
	for slot = 0, n - 1 do
		local b = memory.read_bytes_as_array(PARTY + slot * MON_SIZE, MON_SIZE, BUS)
		local pers, otId = u32of(b, 1), u32of(b, 5)
		local last = 18
		for i = 9, 18 do
			if b[i] == EOS then
				last = i - 1
				break
			end
		end
		local mon = { slot = slot, nickname = decode(b, 9, last), level = b[85], hp = u16of(b, 87), max_hp = u16of(b, 89),
			status_raw = u32of(b, 81),
			stats = { attack = u16of(b, 91), defense = u16of(b, 93), speed = u16of(b, 95), sp_attack = u16of(b, 97),
				sp_defense = u16of(b, 99) } }
		-- The decrypted words sum to +0x1C; when they do not, the blocks are not read.
		local key, words, sum = pers ~ otId, {}, 0
		for w = 0, 11 do
			words[w] = u32of(b, 33 + w * 4) ~ key
			sum = (sum + (words[w] & 0xFFFF) + (words[w] >> 16)) & 0xFFFF
		end
		if sum ~= u16of(b, 29) then
			mon.checksum_mismatch = true
		else
			local g, a = blockOfKind(pers % 24, 0) * 3, blockOfKind(pers % 24, 1) * 3
			mon.species_id = words[g] & 0xFFFF
			mon.species = nameAt(SPECIES_NAMES, SPECIES_LEN, SPECIES_COUNT, mon.species_id)
			local held = words[g] >> 16
			if held ~= 0 then mon.held_item = itemName(held) or string.format("item %d", held) end
			mon.exp = words[g + 1]
			local moves = {}
			for i = 0, 3 do
				local id = (words[a + (i >> 1)] >> (16 * (i & 1))) & 0xFFFF
				if id ~= 0 then
					moves[#moves + 1] = { name = nameAt(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, id), id = id,
						pp = (words[a + 2] >> (8 * i)) & 0xFF }
				end
			end
			if #moves > 0 then mon.moves = moves end
		end
		out[#out + 1] = mon
	end
	return out
end

local function readBag(sb1, key)
	local bag = {}
	for _, p in ipairs(POCKETS) do
		local b, list = memory.read_bytes_as_array(sb1 + p.at, p.slots * 4, BUS), {}
		for i = 0, p.slots - 1 do
			local id = u16of(b, i * 4 + 1)
			if id ~= 0 then
				list[#list + 1] = { item = itemName(id) or string.format("item %d", id), id = id,
					quantity = u16of(b, i * 4 + 3) ~ (key & 0xFFFF) }
			end
		end
		-- An empty table would go out as {} (json.lua), so an empty pocket is left out.
		if #list > 0 then bag[p.name] = list end
	end
	return bag
end

local function flagGet(sb1, id)
	return (r8(sb1 + FLAGS_AT + (id >> 3)) >> (id & 7)) & 1 == 1
end

-- What the save has: the party, the bag, money and badges. Nil until the save blocks are in place.
local function readSave()
	local sb1, sb2 = r32(SB1PTR), r32(SB2PTR)
	if not inEwram(sb1) or not inEwram(sb2) then return nil end
	local key = r32(sb2 + 0xAC)
	local badges = {}
	for i = 0, 7 do
		if flagGet(sb1, BADGE_FLAG0 + i) then badges[#badges + 1] = i + 1 end
	end
	return { party = readParty(), bag = readBag(sb1, key), money = r32(sb1 + 0x490) ~ key, badge_count = #badges,
		badges = #badges > 0 and badges or nil }
end

local game = {
	game = "emerald",
	-- "vanilla" only when the ROM's hash is the one every address here was measured on.
	variant = isVanilla and "vanilla" or "unverified",
	capabilities = { "observe", "press", "wait", "screenshot", "snapshot", "restore", "cheat:warp", "cheat:set_flag",
		"cheat:give_item", "select", "walk" },
	-- The START menu and a YES/NO: Down moved the cursor one entry per press and A chose it (2026-09-16).
	menuButtons = { prev = "Up", next = "Down", confirm = "A" },
	protected_slots = { 1 },
	-- The folder under dev-scripts/shots/ this game's pictures go to.
	shots = "emerald",
}

function game.build()
	return string.format("gamecode %08X", r32(0x080000AC))
end

-- Install the text hooks, on the measured ROM only. Returns what happened, for the driver's log.
-- Any execute hook halves the emulator's top speed, however many there are (hookcost_probe.lua, one
-- instance, frame limiter off, a core connected, 2026-09-16: 818 frames/s with none, 410.5 with one
-- no-op hook, 415.5 with these six), so AUTOPLAY_TEXT=0 leaves them out for a run that wants full
-- fast-forward and no text.
function game.start()
	if (AUTOPLAY_TEXT or os.getenv("AUTOPLAY_TEXT")) == "0" then
		return "AUTOPLAY_TEXT=0: no text hooks"
	end
	if not isVanilla then
		return "rom hash " .. romHash .. " is not the measured vanilla ROM: no text hooks"
	end
	for i, h in ipairs(HOOKS) do
		local name = "autoplay_emerald_text_" .. i
		pcall(event.unregisterbyname, name)
		local ok = pcall(event.onmemoryexecute, function()
			if not pcall(h.fn) then hookErrors = hookErrors + 1 end
		end, h.at, name)
		if not ok then
			game.stop()
			return string.format("event.onmemoryexecute refused %08X: no text hooks", h.at)
		end
		hookNames[#hookNames + 1] = name
	end
	return string.format("%d text hooks installed", #hookNames)
end

function game.stop()
	for _, name in ipairs(hookNames) do pcall(event.unregisterbyname, name) end
	hookNames, shown, dialogue, menuWindow = {}, {}, nil, nil
end

-- After a snapshot is loaded: the text seen so far belongs to the memory that was replaced.
function game.restored()
	shown, dialogue, menuWindow = {}, nil, nil
end

-- `asked` is true for the agent's own observe; the before and after of a press, a select or a walk leave
-- out what the save has, which rarely changes during one and is most of an observation's size.
function game.observe(asked)
	local cb2 = r32(GMAIN_CB2)
	local sb1 = r32(SB1PTR)
	local obj = GOBJECTEVENTS + r8(GPLAYERAVATAR + 5) * 0x24
	local d, m, s
	if #hookNames > 0 then
		d, m = readDialogue(), readMenu()
		s = readScreenText(d and d.window, m and m.window)
		if #s == 0 then s = nil end
	end
	local overworld = cb2 == CB2_OVERWORLD or cb2 == CB2_OVERWORLD + 1
	local localMap, nearby, warps
	if isVanilla and overworld then
		warps, nearby = readWarps(), readObjects()
		localMap = readLocalMap(warps, nearby)
		local px, py = r16(sb1), r16(sb1 + 2)
		for _, o in ipairs(nearby) do o.dx, o.dy = o.x - px, o.y - py end
		if #nearby == 0 then nearby = nil end
		if #warps == 0 then warps = nil end
	end
	local save = (asked and isVanilla) and readSave() or nil
	return {
		party = save and save.party,
		bag = save and save.bag,
		money = save and save.money,
		badge_count = save and save.badge_count,
		badges = save and save.badges,
		dialogue = d,
		menu = m,
		screen_text = s,
		local_map = localMap,
		nearby = nearby,
		warps = warps,
		frame = emu.framecount(),
		mode = overworld and "overworld" or "not_overworld",
		location = {
			map = string.format("%d.%d", r8(sb1 + 4), r8(sb1 + 5)),
			x = r16(sb1),
			y = r16(sb1 + 2),
		},
		extras = {
			callback2 = string.format("%08X", cb2),
			text_hook_errors = hookErrors > 0 and hookErrors or nil,
			avatar_flags = r8(GPLAYERAVATAR),
			player_object = {
				x = r16(obj + 0x10),
				y = r16(obj + 0x12),
				facing_raw = r8(obj + 0x18),
				action_raw = r8(obj + 0x1c),
			},
		},
	}
end

local function inOverworld()
	local cb = r32(GMAIN_CB2)
	return cb == CB2_OVERWORLD or cb == CB2_OVERWORLD + 1
end

-- Cheats: each takes its args and returns a plan -- { untilFn = function(observation) -> done,
-- limit = frames } -- or nil and a reason. A cheat changes the world by other means than play; the
-- core marks the segment reached.
game.cheats = {}

-- warp {map = "G.N", x, y}: the game's own map load, the writes `cmd_drive.lua`'s `warp` measured
-- (2026-09-16: lands on the named map and tile, onto water arriving surfing). Refused unless
-- gMain.callback2 is vanilla's overworld callback. Done once the game has left the overworld and come
-- back on the target map; 600 frames at most.
function game.cheats.warp(args)
	local map = type(args.map) == "string" and args.map or ""
	local g, n = map:match("^(%d+)%.(%d+)$")
	local x, y = math.tointeger(args.x), math.tointeger(args.y)
	g, n = tonumber(g), tonumber(n)
	if not g or g > 255 or n > 255 or not x or not y or x < 0 or y < 0 or x > 0xffff or y > 0xffff then
		return nil, 'warp needs map "G.N" (each 0-255), x and y'
	end
	if not inOverworld() then
		return nil, string.format("warp refused: gMain.callback2 is %08X, not vanilla's overworld", r32(GMAIN_CB2))
	end
	local sb1 = r32(SB1PTR)
	for _, at in ipairs({ SWARPDESTINATION, sb1 + 0x04 }) do
		w8(at, g); w8(at + 1, n); w8(at + 2, 0)
		w16(at + 4, 0xffff); w16(at + 6, 0xffff)
	end
	w16(sb1, x); w16(sb1 + 2, y)
	w32(GFIELDCALLBACK, FIELDCB_DEFAULTWARPEXIT + 1)
	w32(GMAIN_CB2, CB2_LOADMAP + 1)
	local left = false
	return {
		limit = 600,
		untilFn = function(o)
			if o.mode ~= "overworld" then
				left = true
				return false
			end
			return left and o.location.map == map
		end,
	}
end

-- set_flag {flag, value = true}: one bit per flag id in SaveBlock1 +0x1270, bit (id & 7) of byte id >> 3
-- (measured on the badge flags, see `badges`). Ids 1 to FLAG_MAX, where the build's layout ends that
-- byte array; only the badge flags are measured. Refused outside the overworld, since SaveBlock1 moved
-- during the map load after CONTINUE (party_bag_probe.lua: 0x02025A2C, then 0x02025A10). Done at once;
-- `report` reads the bit back.
function game.cheats.set_flag(args)
	local id = math.tointeger(args.flag)
	local value = args.value
	if value == nil then value = true end
	if not id or id < 1 or id > FLAG_MAX or type(value) ~= "boolean" then
		return nil, string.format("set_flag needs flag, 1 to %d, and value true or false", FLAG_MAX)
	end
	if not isVanilla then return nil, "set_flag is measured on the vanilla ROM only" end
	if not inOverworld() then
		return nil, string.format("set_flag refused: gMain.callback2 is %08X, not vanilla's overworld", r32(GMAIN_CB2))
	end
	local sb1 = r32(SB1PTR)
	local at, bit = sb1 + FLAGS_AT + (id >> 3), 1 << (id & 7)
	local was = flagGet(sb1, id)
	w8(at, value and (r8(at) | bit) or (r8(at) & ~bit & 0xFF))
	return {
		limit = 1,
		untilFn = function() return true end,
		report = function() return { flag = id, was = was, now = flagGet(r32(SB1PTR), id) } end,
	}
end

-- The item id for a name, from the ROM's item table (case ignored).
local itemIds = nil
local function itemIdByName(name)
	if not itemIds then
		itemIds = {}
		for id = 1, ITEM_COUNT - 1 do
			local n = itemName(id)
			if n and n ~= "" and not itemIds[n:lower()] then itemIds[n:lower()] = id end
		end
	end
	return itemIds[name:lower()]
end

-- give_item {item = name or id, quantity = 1}: adds to the stack of that item in its pocket, or fills
-- the pocket's first empty slot -- the pocket named by the item table's +0x1A byte. A stack is capped at
-- MAX_STACK, the most the bag was seen to show (RARE CANDY x99); past that is refused, not measured.
-- Refused outside the overworld (set_flag says why). `report` reads the pocket back.
function game.cheats.give_item(args)
	local quantity = math.tointeger(args.quantity or 1)
	local id = math.tointeger(args.item)
	if not id and type(args.item) == "string" then id = itemIdByName(args.item) end
	if not id or id < 1 or id >= ITEM_COUNT then
		return nil, "give_item needs item, a name as the bag shows it or an id 1 to " .. (ITEM_COUNT - 1)
	end
	if not quantity or quantity < 1 or quantity > MAX_STACK then
		return nil, "give_item needs quantity 1 to " .. MAX_STACK
	end
	if not isVanilla then return nil, "give_item is measured on the vanilla ROM only" end
	if not inOverworld() then
		return nil, string.format("give_item refused: gMain.callback2 is %08X, not vanilla's overworld", r32(GMAIN_CB2))
	end
	local pocket = POCKETS[r8(ITEMS + id * ITEM_SIZE + 0x1A)]
	if not pocket then
		return nil, string.format("item %d (%s) has no pocket", id, tostring(itemName(id)))
	end
	local sb1, key16 = r32(SB1PTR), r32(r32(SB2PTR) + 0xAC) & 0xFFFF
	local slot, have = nil, 0
	for i = 0, pocket.slots - 1 do
		local at = sb1 + pocket.at + i * 4
		local sid = r16(at)
		if sid == id then
			slot, have = i, r16(at + 2) ~ key16
			break
		elseif sid == 0 and not slot then
			slot = i
		end
	end
	if not slot then return nil, pocket.name .. " is full" end
	if have + quantity > MAX_STACK then
		return nil, string.format("the bag has %d %s; %d more is past %d", have, itemName(id), quantity, MAX_STACK)
	end
	local at = sb1 + pocket.at + slot * 4
	w16(at, id)
	w16(at + 2, (have + quantity) ~ key16)
	return {
		limit = 1,
		untilFn = function() return true end,
		report = function()
			local s = r32(SB1PTR)
			local list = readBag(s, r32(r32(SB2PTR) + 0xAC))[pocket.name]
			local now = 0
			for _, e in ipairs(list) do
				if e.id == id then now = e.quantity end
			end
			return { item = itemName(id), id = id, pocket = pocket.name, had = have, now = now }
		end,
	}
end

-- The menu alone, for a program that looks every frame (select).
function game.menu()
	if #hookNames > 0 then return readMenu() end
	return nil
end

-- PROGRAMS: run once a frame by the driver, each returning (pad or nil, finished, result, error).
game.programs = {}

local DIRECTIONS = {
	up = { button = "Up", dx = 0, dy = -1 }, down = { button = "Down", dx = 0, dy = 1 },
	left = { button = "Left", dx = -1, dy = 0 }, right = { button = "Right", dx = 1, dy = 0 },
}
local REST_LIMIT, IDLE_LIMIT, PRESS_LIMIT, DOOR_LIMIT, STEP_LIMIT = 120, 20, 90, 150, 180

-- At rest, from step_probe.lua (2026-09-16): after a walked tile, a wall bump and a turn alike, the
-- player object's byte 0 has its top bit back, its previous coordinates equal its current ones, and
-- the avatar block's +2 and +3 are both 0 -- all true together 2 frames after the step's last pixel.
local function atRest()
	local b = memory.read_bytes_as_array(playerObject(), 0x18, BUS)
	local a = memory.read_bytes_as_array(GPLAYERAVATAR + 2, 2, BUS)
	return (b[1] & 0x80) ~= 0 and b[17] == b[21] and b[18] == b[22] and b[19] == b[23] and b[20] == b[24]
		and a[1] == 0 and a[2] == 0
end

-- What stands on a tile, in map coordinates, for a refused step.
local function describeTile(x, y)
	local ox, oy = x + MAP_OFFSET, y + MAP_OFFSET
	local width, height = r32(GBACKUPMAPLAYOUT), r32(GBACKUPMAPLAYOUT + 4)
	local out = { x = x, y = y }
	if ox < 0 or oy < 0 or ox >= width or oy >= height then
		out.outside_map = true
		return out
	end
	local v = r16(r32(GBACKUPMAPLAYOUT + 8) + (ox + width * oy) * 2)
	out.collision, out.elevation, out.behaviour = (v >> 10) & 3, v >> 12, behaviourOf(v & 0x3FF)
	for _, o in ipairs(readObjects()) do
		if o.x == x and o.y == y then out.character = { slot = o.slot, local_id = o.local_id, graphics_id = o.graphics_id } end
	end
	for _, w in ipairs(readWarps()) do
		if w.x == x and w.y == y then out.warp_to = w.to end
	end
	return out
end

-- walk {direction, tiles}: one tile at a time, each ending on the game's own state. From rest, hold the
-- direction until the player's coordinates change (the step has begun: they jump to the next tile the
-- frame the press lands) or the avatar's +2 reads 2 with them unchanged (the step was refused: a wall
-- read that way from its first frame); release, and wait for rest. A press facing another way turns
-- first (+2 reads 1 for 7 frames), and a door opens before the step (+2 at 1 and +3 at 2 for 13 more), so
-- only frames where +2 reads 0 count towards giving up -- unless the tile ahead is in the warp list: a
-- door facing the player opened with all of these bytes at rest for 20 frames, then the step began on
-- its own, so a press toward a warp waits up to DOOR_LIMIT for the step or the map change. It stops early
-- when the map changes, the game leaves the overworld, or a message box or menu is on screen.
function game.programs.walk(p)
	local d = DIRECTIONS[type(p.direction) == "string" and p.direction:lower() or ""]
	local tiles = math.tointeger(p.tiles)
	if not d then return nil, 'walk needs direction "up", "down", "left" or "right"' end
	if not tiles or tiles < 1 or tiles > 32 then return nil, "walk needs tiles, 1 to 32" end
	if not isVanilla then return nil, "walk is measured on the vanilla ROM only" end

	local phase, frames, idle, moved, startMap, fromX, fromY, towardWarp = "rest", 0, 0, 0, nil, 0, 0, false
	local function here()
		local sb1 = r32(SB1PTR)
		return string.format("%d.%d", r8(sb1 + 4), r8(sb1 + 5)), r16(sb1), r16(sb1 + 2)
	end
	local function finish(outcome, extra)
		local r = { direction = p.direction:lower(), requested = tiles, moved = moved, outcome = outcome }
		for k, v in pairs(extra or {}) do r[k] = v end
		return nil, true, r
	end

	return function()
		frames = frames + 1
		local map, x, y = here()
		startMap = startMap or map
		if map ~= startMap then return finish("map_changed", { map = map }) end
		if not inOverworld() then return finish("left_overworld") end
		if #hookNames > 0 then
			if dialogue and windowOnScreen(dialogue.window) then return finish("dialogue_open") end
			if menuWindow and windowOnScreen(menuWindow) then return finish("menu_open") end
		end

		if phase == "rest" then
			if not atRest() then
				if frames > REST_LIMIT then return finish("not_at_rest") end
				return nil, false
			end
			if moved >= tiles then return finish("done") end
			phase, frames, idle, fromX, fromY = "press", 0, 0, x, y
			towardWarp = false
			for _, w in ipairs(readWarps()) do
				if w.x == x + d.dx and w.y == y + d.dy then towardWarp = true end
			end
		end

		if phase == "press" then
			if x ~= fromX or y ~= fromY then
				phase, frames = "moving", 0
				return nil, false
			end
			local state = r8(GPLAYERAVATAR + 2)
			if state == 2 then
				phase, frames = "refused", 0
				return nil, false
			end
			if state == 0 then idle = idle + 1 end
			if towardWarp then
				if frames > DOOR_LIMIT then return finish("no_response") end
			elseif idle > IDLE_LIMIT or frames > PRESS_LIMIT then
				return finish("no_response")
			end
			return { [d.button] = true }, false
		end

		if phase == "moving" then
			if atRest() then
				moved = moved + math.abs(x - fromX) + math.abs(y - fromY)
				phase, frames = "rest", 0
			elseif frames > STEP_LIMIT then
				return finish("not_at_rest")
			end
			return nil, false
		end

		-- refused: let the bump finish, then say what is on the tile.
		if atRest() then
			return finish("blocked", { blocked_by = describeTile(fromX + d.dx, fromY + d.dy) })
		end
		if frames > REST_LIMIT then return finish("not_at_rest") end
		return nil, false
	end
end

-- What `changed` compares between two observations: the fields a press is expected to move.
function game.diffKeys(o)
	return {
		mode = o.mode,
		map = o.location.map,
		x = o.location.x,
		y = o.location.y,
		facing_raw = o.extras.player_object.facing_raw,
		dialogue_state = o.dialogue and o.dialogue.state or "none",
		dialogue_box = o.dialogue and o.dialogue.box or "",
		menu_cursor = o.menu and o.menu.cursor or "none",
	}
end

-- Read every frame for events: a map or mode change, and a dialogue or menu opening or closing.
-- Nothing is decoded here.
function game.watch()
	local sb1 = r32(SB1PTR)
	local cb2 = r32(GMAIN_CB2)
	return {
		map = string.format("%d.%d", r8(sb1 + 4), r8(sb1 + 5)),
		mode = (cb2 == CB2_OVERWORLD or cb2 == CB2_OVERWORLD + 1) and "overworld" or "not_overworld",
		dialogue = (dialogue and windowOnScreen(dialogue.window)) and "open" or "closed",
		menu = (menuWindow and windowOnScreen(menuWindow)) and "open" or "closed",
	}
end

return game
