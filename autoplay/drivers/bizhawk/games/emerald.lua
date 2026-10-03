-- autoplay BizHawk driver: vanilla Pokémon Emerald (dev tool, never shipped).
-- Addresses are from a pokeemerald build hashed identical to the vanilla ROM (VANILLA_SHA1); what a byte means is what
-- a probe showed, and a byte whose meaning is not measured, such as a facing or an action code, goes out raw. The text
-- hooks and the readers built on measured meanings run on that ROM only.

-- The shared library the driver hands every game module: `text`, `route`, and `select` once the driver defines it.
local lib = ...

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

local VANILLA_SHA1 = "F3AE088181BF583E55DAF962A92BB46F4F1D07B7"
local romHash = (function()
	local ok, h = pcall(gameinfo.getromhash)
	return ok and type(h) == "string" and h:upper() or ""
end)()
local isVanilla = romHash == VANILLA_SHA1

-- Execute hooks at the build's routine entries; the window ones take the window id in R0, AddTextPrinter a template.
local ADDTEXTPRINTER, FILLWINDOWPIXELBUFFER, REMOVEWINDOW, CLEARWINDOWTILEMAP, MENU_MOVECURSOR =
	0x0800467c, 0x08003c48, 0x08003574, 0x080038a4, 0x081984d8
-- InitWindows: a new screen rewrites the window table without removing the old windows, and reuses their ids.
local INITWINDOWS = 0x080031c0
-- ChangeMenuGridCursorPosition and ChangeGridMenuCursorPosition: a grid menu's setup calls these, not Menu_MoveCursor.
local CHANGE_MENU_GRID_CURSOR, CHANGE_GRID_MENU_CURSOR = 0x08199134, 0x081991f8
-- 0x24 bytes per window id: +0x1B is 1 while a message is on its way, +0x1C the printer's state (readDialogue).
local STEXTPRINTERS, PRINTER_SIZE = 0x020201b0, 0x24
-- 12 bytes per window id: +0 the background (FF once removed), +1 left, +2 top, +3 width, +4 height, in tiles.
local GWINDOWS, WINDOW_SIZE = 0x02020004, 12
-- +1 top, +2 cursor, +4 last index, +5 window, +8 row height. It keeps its values after the menu closes, so a menu
-- counts as open from Menu_MoveCursor until its window is cleared or removed.
local SMENU = 0x0203cd90
-- sGlobalScriptContextStatus: 2 with no script running, 0 or 1 while one runs.
local SCRIPT_CONTEXT_STATUS, SCRIPT_CONTEXT_OFF = 0x03000e38, 2
-- The field controls lock, 0x03000f2c (inline: the chunk is at Lua's 200-local limit), is 1 while a script holds the
-- player; the context above can stay 1 after a script ends, with the player walking.
local LINE_ADVANCE = 16
local CURSOR, NEWLINE, NEXT_BOX, EOS = 0xEF, 0xFE, 0xFB, 0xFF

-- The character each byte draws, read off the screen; a byte that draws nothing, or one not listed, goes out as {XX}.
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

-- FC and one of these codes take one more byte and draw nothing; other FC codes go out byte by byte.
local EXT, EXT_ONE_ARG = 0xFC, { [0x01] = true, [0x02] = true, [0x06] = true, [0x13] = true }
-- These take none; whether they draw anything is not measured.
local EXT_NO_ARG = { [0x09] = true, [0x0A] = true }

local function decode(bytes, from, to)
	local out = {}
	local i = from
	while i <= to do
		local b = bytes[i]
		if b == NEWLINE then
			out[#out + 1] = "\n"
		elseif b == EXT and i + 2 <= to and EXT_ONE_ARG[bytes[i + 1]] then
			out[#out + 1] = string.format("{FC %02X %02X}", bytes[i + 1], bytes[i + 2])
			i = i + 2
		elseif b == EXT and i + 1 <= to and EXT_NO_ARG[bytes[i + 1]] then
			out[#out + 1] = string.format("{FC %02X}", bytes[i + 1])
			i = i + 1
		else
			out[#out + 1] = CHARS[b] or string.format("{%02X}", b)
		end
		i = i + 1
	end
	return table.concat(out)
end

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

-- What the game has printed and not yet cleared, per window id, copied as printing starts since the buffer is reused.
local shown = {}
-- Windows whose last print was instant (speed 0 or 255), which never touches the printer: one finished there is stale.
local instantPrinted = {}
local dialogue = nil -- { window, bytes, start }: the last string printed letter by letter
local menuWindow = nil
-- Whether the last menu set up was a grid: a list menu's setup leaves the last grid's column count in place.
local menuGrid = false

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
	if speed ~= 0 and speed ~= 255 then
		dialogue = { window = w, bytes = bytes, start = ptr }
		instantPrinted[w] = nil
	else
		instantPrinted[w] = true
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
	menuWindow, menuGrid = r8(SMENU + 5), false
end
function hooks.menuGridCursor()
	menuWindow, menuGrid = r8(SMENU + 5), true
end
function hooks.initWindows()
	shown, dialogue, menuWindow, instantPrinted = {}, nil, nil, {}
end

local HOOKS = {
	{ at = INITWINDOWS, fn = hooks.initWindows },
	{ at = ADDTEXTPRINTER, fn = hooks.addTextPrinter },
	{ at = FILLWINDOWPIXELBUFFER, fn = hooks.fillWindowPixelBuffer },
	{ at = REMOVEWINDOW, fn = hooks.removeWindow },
	{ at = CLEARWINDOWTILEMAP, fn = hooks.clearWindowTilemap },
	{ at = MENU_MOVECURSOR, fn = hooks.menuMoveCursor },
	{ at = CHANGE_MENU_GRID_CURSOR, fn = hooks.menuGridCursor },
	{ at = CHANGE_GRID_MENU_CURSOR, fn = hooks.menuGridCursor },
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

-- A message under way after a restore or a reload never passed the hook, and one call prints several boxes: with none
-- known, an active printer on screen is taken up from its pointer (in the ROM back past the previous FF, in a message
-- buffer, gStringVar4 or gDisplayedStringBattle, from its start). A finished one only while its window is still put and
-- its string ends exactly at the pointer, which a stale pointer does not. `recovered`: box indices count from there.
local TEXT_BUFFERS = { { at = 0x02021fc4, size = 1000 }, { at = 0x02022e2c, size = 300 } }

-- Put: its first and last cells hold its base block's first and last tiles, which a frame drawn over it does not fake.
local function windowPut(w)
	local s = memory.read_bytes_as_array(GWINDOWS + w * WINDOW_SIZE, 8, BUS)
	local bg, left, top, width, height, base = s[1], s[2], s[3], s[4], s[5], s[7] | (s[8] << 8)
	if bg > 3 or width == 0 or height == 0 or left + width > 32 or top + height > 32 then return false end
	local map = 0x06000000 + ((memory.read_u16_le(0x04000008 + bg * 2, BUS) >> 8) & 0x1F) * 0x800
	local first = memory.read_u16_le(map + (top * 32 + left) * 2, BUS) & 0x3FF
	local last = memory.read_u16_le(map + ((top + height - 1) * 32 + left + width - 1) * 2, BUS) & 0x3FF
	return first == base & 0x3FF and last == (base + width * height - 1) & 0x3FF
end

-- Something drawn in a window: its pixel buffer (gWindows +8, 4 bits a pixel) holds more than one byte value in its
-- first 16 pixel rows; a box put back blank holds one.
local function windowHasPixels(w)
	local s = memory.read_bytes_as_array(GWINDOWS + w * WINDOW_SIZE, 12, BUS)
	local buf = s[9] | (s[10] << 8) | (s[11] << 16) | (s[12] << 24)
	if buf < 0x02000000 or buf >= 0x02040000 or s[4] == 0 then return false end
	local b = memory.read_bytes_as_array(buf, s[4] * 4 * 16, BUS)
	for i = 2, #b do
		if b[i] ~= b[1] then return true end
	end
	return false
end

local function recoverDialogue()
	-- A finished message only under the callback2s it was measured right on: the overworld's and CB2_MainMenu's.
	local cb = r32(GMAIN_CB2) & 0xFFFFFFFE
	local finishedHere = cb == CB2_OVERWORLD or cb == 0x0802f6b0
	for w = 0, 31 do
		local active = printerActive(w)
		if (active and windowOnScreen(w)) or (finishedHere and not active and not instantPrinted[w] and windowPut(w) and windowHasPixels(w)) then
			local ptr = r32(STEXTPRINTERS + w * PRINTER_SIZE)
			local start, bytes
			for _, buf in ipairs(TEXT_BUFFERS) do
				if ptr >= buf.at and ptr <= buf.at + buf.size then
					bytes = readString(buf.at)
					-- The pointer lies inside the string read from the buffer's start; a finished one just past its FF.
					if ptr <= buf.at + #bytes + 1 and (active or ptr == buf.at + #bytes + 1) then start = buf.at end
				end
			end
			if not start and ptr >= 0x08000200 and ptr < 0x0A000000 and (active or r8(ptr - 1) == EOS) then
				-- In the ROM, back to the byte after the previous FF (past the string's own FF when finished).
				local back = memory.read_bytes_as_array(ptr - 512, 512, BUS)
				for i = active and 512 or 511, 1, -1 do
					if back[i] == EOS then
						start = ptr - 512 + i
						break
					end
				end
				bytes = start and readString(start)
			elseif not start and active and ptr >= 0x02000000 and ptr < 0x04000000 then
				start = ptr
				bytes = readString(start)
			end
			if start then return { window = w, bytes = bytes, start = start, recovered = true } end
		end
	end
	return nil
end

local function readDialogue()
	if not dialogue then dialogue = recoverDialogue() end
	if not dialogue or not windowOnScreen(dialogue.window) then return nil end
	local p = STEXTPRINTERS + dialogue.window * PRINTER_SIZE
	local active, stateRaw = r8(p + 0x1B) == 1, r8(p + 0x1C)
	local b = dialogue.bytes
	local boxes, from = {}, 1
	for i = 1, #b + 1 do
		if b[i] == nil or b[i] == NEXT_BOX then
			boxes[#boxes + 1] = { from = from, to = i - 1 }
			from = i + 1
		end
	end
	local index = #boxes
	if active then
		-- The pointer is one past the last byte taken. Waiting on its arrow it has just taken the next-box byte, which
		-- still belongs to the box on screen; while printing, taking it means the next box has begun.
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
	elseif stateRaw == 1 or stateRaw == 2 or stateRaw == 3 then
		-- 2 on the red arrow, 3 before an FA scrolls the text, 1 at an FC 09 ending defeat words; each until A.
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
		recovered = dialogue.recovered,
	}
end

local function readMenu()
	if not menuWindow or not windowOnScreen(menuWindow) then return nil end
	local m = memory.read_bytes_as_array(SMENU, 12, BUS)
	local top, cursor, last, w, width, height, columns = m[2], m[3], m[5], m[6], m[8], m[9], m[10]
	if w ~= menuWindow then return nil end
	if cursor > 127 then cursor = cursor - 256 end
	if menuGrid and columns >= 1 and width > 0 and height > 0 then
		-- A grid: +7 a column's width and +9 the columns, entries row by row; each piece goes to its nearest cell.
		local segs, items = {}, {}
		for _, e in ipairs(shown[w] or {}) do linesOf(e, segs) end
		for i = 0, last do
			local text = {}
			for _, sg in ipairs(segs) do
				if (sg.x + width // 2) // width == i % columns and (sg.y - top + height // 2) // height == i // columns then
					text[#text + 1] = sg.text
				end
			end
			items[#items + 1] = table.concat(text, " ")
		end
		return { window = w, cursor = cursor, items = items, columns = columns }
	end
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

local GBACKUPMAPLAYOUT, GMAPHEADER = 0x03005dc0, 0x02037318
-- SaveBlock1's position plus 7 is the player object's coordinate, which addresses the grid (width, height, entries).
local MAP_OFFSET = 7
local VIEW_W, VIEW_H = 7, 5 -- tiles either side: 15 by 11, a little more than the screen
local OBJ_SIZE = 0x24

local function inRom(p) return p >= 0x08000000 and p < 0x0A000000 end
local function playerSlot() return r8(GPLAYERAVATAR + 5) end
local function playerObject() return GOBJECTEVENTS + playerSlot() * OBJ_SIZE end

-- A grid entry: metatile bits 0-9, collision 10-11, elevation 12-15. Its behaviour is the low byte of the metatile's
-- attribute word in its tileset (ids from 512 in the second).
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

-- The header's events (+4): the warp count at +1 and its list at +8, 8 bytes an entry (x +0, y +2, the destination's
-- map number +6 and group +7).
local function readWarps()
	local out, events = {}, r32(GMAPHEADER + 4)
	if not inRom(events) then return out end
	local n, list = r8(events + 1), r32(events + 8)
	if not inRom(list) then return out end
	local width, height, grid = r32(GBACKUPMAPLAYOUT), r32(GBACKUPMAPLAYOUT + 4), r32(GBACKUPMAPLAYOUT + 8)
	for i = 0, math.min(n, 64) - 1 do
		local e = memory.read_bytes_as_array(list + i * 8, 8, BUS)
		local w = { x = e[1] | (e[2] << 8), y = e[3] | (e[4] << 8), to = string.format("%d.%d", e[8], e[7]) }
		-- The tile under it, as describeTile reads one: how a warp is entered depends on it.
		local gx, gy = w.x + MAP_OFFSET, w.y + MAP_OFFSET
		if gx < width and gy < height then
			local v = r16(grid + (gx + width * gy) * 2)
			w.collision, w.elevation, w.behaviour = (v >> 10) & 3, v >> 12, behaviourOf(v & 0x3FF)
		end
		out[#out + 1] = w
	end
	return out
end

-- Flags: one bit per id from SaveBlock1 +0x1270, up to FLAG_MAX, where the build's layout ends that array.
local FLAGS_AT, FLAG_MAX = 0x1270, 0x95F
local function flagGet(sb1, id)
	return (r8(sb1 + FLAGS_AT + (id >> 3)) >> (id & 7)) & 1 == 1
end

-- Trainers. A template is 24 bytes (local id +0, x +4, y +6, movement +9, range +0x0A, type +0x0C, sight +0x0E, script
-- +0x10); type 1's defeat flag is 0x500 plus the u16 at +2 of its script (which begins 5C). A loaded one faces by its
-- +0x18 low nibble. Taken, not measured: nothing between blocks a view, and another type sees every way.
local FACING = { [1] = "down", [2] = "up", [4] = "right" }
-- The ways a trainer was seen to face, by its movement byte; any other is taken to turn every way.
local TURNS = { [7] = { "up" }, [8] = { "down" }, [9] = { "left" }, [0x0A] = { "right" }, [0x0D] = { "down", "up" },
	[0x0E] = { "left", "right" }, [0x10] = { "up", "right" }, [0x11] = { "down", "left" }, [0x12] = { "down", "right" },
	[0x17] = { "up", "down", "left", "right" }, [0x18] = { "up", "down", "left", "right" } }
local EVERY_WAY = { "up", "down", "left", "right" }
-- A trainer that walks stays inside a box round its template tile (+0x0A: low nibble the x range, high the y), so its
-- sight is taken from every tile of that box, every way: never timed, just avoided. Wandering (0x02-0x06), walking back
-- and forth (0x19-0x1C) and walk sequences (0x1D-0x34) walk.
local SIGHT_STEP = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

local function readTemplates()
	local out, events = {}, r32(GMAPHEADER + 4)
	if not inRom(events) then return out end
	local n, list = r8(events), r32(events + 4)
	if not inRom(list) then return out end
	for i = 0, math.min(n, 64) - 1 do
		local e = memory.read_bytes_as_array(list + i * 24, 24, BUS)
		out[#out + 1] = { local_id = e[1], x = e[5] | (e[6] << 8), y = e[7] | (e[8] << 8), movement = e[10],
			range_x = e[11] & 0x0F, range_y = e[11] >> 4,
			trainer_type = e[13] | (e[14] << 8), range = e[15] | (e[16] << 8),
			script = e[17] | (e[18] << 8) | (e[19] << 16) | (e[20] << 24) }
	end
	return out
end

-- What a trainer is: `beaten` (nil when its flag cannot be read), `range`, and `sees`, the ways it looks.
local function trainerOf(sb1, trainerType, range, movement, script)
	local t = { range = range, sees = (trainerType == 1 and TURNS[movement]) or EVERY_WAY }
	t.turns = trainerType == 1 and TURNS[movement] ~= nil and #TURNS[movement] > 1
	if trainerType ~= 1 then t.trainer_type_raw = trainerType end
	if trainerType == 1 and inRom(script) and r8(script) == 0x5C then
		t.flag = 0x500 + r16(script + 2)
		if t.flag <= FLAG_MAX then t.beaten = flagGet(sb1, t.flag) end
	end
	return t
end

-- The other characters: object slots with byte 0's bit 0 set; +0x05 the graphic, +0x08 the local id, +0x10/+0x12 the
-- tile, and +0x06, +0x07 and +0x1D its template's movement, trainer type and sight (the movement goes out raw).
local function readObjects()
	local out, me = {}, playerSlot()
	local sb1 = r32(SB1PTR)
	local mapNum, mapGroup = r8(sb1 + 5), r8(sb1 + 4)
	local templates
	for s = 0, 15 do
		local b = memory.read_bytes_as_array(GOBJECTEVENTS + s * OBJ_SIZE, OBJ_SIZE, BUS)
		if (b[1] & 1) == 1 and s ~= me then
			local facing = b[25] & 0x0F
			local o = { slot = s, local_id = b[9], graphics_id = b[6],
				x = (b[17] | (b[18] << 8)) - MAP_OFFSET, y = (b[19] | (b[20] << 8)) - MAP_OFFSET,
				facing = FACING[facing], facing_raw = not FACING[facing] and facing or nil, movement_type_raw = b[7] }
			if b[8] ~= 0 and b[10] == mapNum and b[11] == mapGroup then
				templates = templates or readTemplates()
				local script = 0
				for _, t in ipairs(templates) do
					if t.local_id == b[9] then script = t.script end
				end
				o.trainer = trainerOf(sb1, b[8], b[30], b[7], script)
			end
			out[#out + 1] = o
		end
	end
	return out
end

-- Every unbeaten trainer on this map, where it stands and the ways it looks: the live character where one
-- is loaded, its template where none is yet (a trainer out of view is not in the object slots).
local function unbeatenTrainers(objects)
	local sb1, live, out = r32(SB1PTR), {}, {}
	for _, o in ipairs(objects) do
		if o.trainer then live[o.local_id] = o end
	end
	for _, t in ipairs(readTemplates()) do
		if t.trainer_type ~= 0 then
			local o = live[t.local_id]
			local info = o and o.trainer or trainerOf(sb1, t.trainer_type, t.range, t.movement, t.script)
			if not info.beaten then
				out[#out + 1] = { local_id = t.local_id, x = o and o.x or t.x, y = o and o.y or t.y, range = info.range,
					sees = info.sees, turns = info.turns, loaded = o ~= nil, slot = o and o.slot or nil,
					walks = ((t.movement >= 0x02 and t.movement <= 0x06) or (t.movement >= 0x19 and t.movement <= 0x34)) and { x = t.x, y = t.y, rx = t.range_x, ry = t.range_y } or nil }
			end
		end
	end
	return out
end

-- The tiles unbeaten trainers see (y * width + x, the first trainer found), and `timed`: those only one loaded, turning
-- trainer sees, with the way it faces, for `goto` to cross by waiting beside the line until it turns away.
local function sightTiles(trainers, mapW, mapH)
	local seen, count, timed = {}, {}, {}
	for _, t in ipairs(trainers) do
		if t.walks then
			local w = t.walks
			for py = w.y - w.ry, w.y + w.ry do
				for px = w.x - w.rx, w.x + w.rx do
					for _, step in pairs(SIGHT_STEP) do
						for k = 0, math.min(t.range, 15) do
							local x, y = px + step[1] * k, py + step[2] * k
							if x >= 0 and y >= 0 and x < mapW and y < mapH then
								local key = y * mapW + x
								seen[key] = seen[key] or t
								count[key] = (count[key] or 0) + 2
							end
						end
					end
				end
			end
		end
		for _, way in ipairs(t.sees) do
			local step = SIGHT_STEP[way]
			for k = 1, math.min(t.range, 15) do
				local x, y = t.x + step[1] * k, t.y + step[2] * k
				if x >= 0 and y >= 0 and x < mapW and y < mapH then
					local key = y * mapW + x
					seen[key] = seen[key] or t
					count[key] = (count[key] or 0) + 1
					if t.slot and t.turns then timed[key] = { trainer = t, way = way } end
				end
			end
		end
	end
	for key in pairs(timed) do
		if count[key] > 1 then timed[key] = nil end
	end
	return seen, timed
end

local function readLocalMap(warps, objects)
	local obj = playerObject()
	local px, py = r16(obj + 0x10), r16(obj + 0x12)
	local elevation = r8(obj + 0x0B) & 0x0F
	local width, height, grid = r32(GBACKUPMAPLAYOUT), r32(GBACKUPMAPLAYOUT + 4), r32(GBACKUPMAPLAYOUT + 8)
	-- The map's own size is its layout's +0/+4; the grid is wider and taller, the map starting MAP_OFFSET in.
	local layout = r32(GMAPHEADER)
	local mapW, mapH = width, height
	if inRom(layout) then mapW, mapH = r32(layout), r32(layout + 4) end
	local seen = sightTiles(unbeatenTrainers(objects), mapW, mapH)
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
					elseif seen[(y - MAP_OFFSET) * mapW + x - MAP_OFFSET] then
						ch = "!"
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
		{ "!", "not collision, but an unbeaten trainer looks this way: stepping or standing there starts its battle" },
		{ ":", "beyond this map's edge: a connected map's edge, or filler (not measured which)" },
		{ " ", "outside the grid" },
	}
	for _, f in ipairs(fixed) do
		if used[f[1]] then legend[#legend + 1] = f[1] .. " " .. f[2] end
	end
	for beh, ch in pairs(letters) do
		legend[#legend + 1] = string.format("%s behaviour 0x%02X%s", ch, beh,
			(beh >= 0x38 and beh <= 0x3B) and " (a ledge: hopped two tiles walking into it its one way)" or "")
	end
	for e = 0, 15 do
		local ch = string.format("%X", e)
		if used[ch] then legend[#legend + 1] = ch .. " clear, at elevation " .. e .. " (yours is " .. elevation .. "; not measured whether a step onto it is allowed)" end
	end
	table.sort(legend)
	return { rows = rows, legend = legend }
end

local SB2PTR = 0x03005d90
local PARTY_COUNT, PARTY, MON_SIZE = 0x020244e9, 0x020244ec, 0x64
-- Name tables in the ROM, one fixed-width entry per id; the counts are the build's symbol sizes over those widths.
local SPECIES_NAMES, SPECIES_LEN, SPECIES_COUNT = 0x083185c8, 11, 412
local MOVE_NAMES, MOVE_LEN, MOVE_COUNT = 0x0831977c, 13, 355
local ITEMS, ITEM_SIZE, ITEM_NAME_LEN, ITEM_COUNT = 0x085839a0, 44, 14, 377
-- SaveBlock1's pockets in the bag's own order, 4 bytes a slot: the id, then the quantity XOR the low half of SaveBlock2
-- +0xAC. The item table's +0x1A is the pocket's number in this order; slot counts are the build's layout.
local POCKETS = {
	{ name = "items", at = 0x560, slots = 30 },
	{ name = "poke_balls", at = 0x650, slots = 16 },
	{ name = "tms_hms", at = 0x690, slots = 64 },
	{ name = "berries", at = 0x790, slots = 46 },
	{ name = "key_items", at = 0x5D8, slots = 30 },
}
local BADGE_FLAG0 = 0x867
local MAX_STACK = 99

local function inEwram(p) return p >= 0x02000000 and p < 0x02040000 end
local function u32of(b, i) return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24) end
local function u16of(b, i) return b[i] | (b[i + 1] << 8) end

-- A name from the ROM: up to the first FF within `len` bytes of entry `id` (`stride` apart, when wider than its name).
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

-- Move data, 12 bytes an entry (moveInfo names them); the effect text is behind a pointer per move at (id - 1) * 4.
local BATTLE_MOVES, BATTLE_MOVE_SIZE = 0x0831c898, 12
local TYPE_NAMES, TYPE_NAME_LEN, TYPE_COUNT = 0x0831ae38, 7, 18
local MOVE_DESCRIPTIONS = 0x0861c524

-- The type chart as Cmd_typecalc applies it: triples (move type, defending type, multiplier in tenths) to FF, those
-- after FE included; x1.5 when the move's type is one of the attacker's, then each entry naming it and one of the
-- target's two types, once when both read the same.
local TYPE_CHART = { at = 0x0831ace8, size = 0x150, sameTypeBonus = 1.5, entries = nil }

-- A type's name as the game draws it, or nil. Type 0 is a real type (NORMAL), so this reads index 0 too, unlike nameAt.
function TYPE_CHART.name(t)
	if not t or t >= TYPE_COUNT then return nil end
	local b = memory.read_bytes_as_array(TYPE_NAMES + t * TYPE_NAME_LEN, TYPE_NAME_LEN, BUS)
	local last = TYPE_NAME_LEN
	for i = 1, TYPE_NAME_LEN do
		if b[i] == EOS then
			last = i - 1
			break
		end
	end
	return decode(b, 1, last)
end

function TYPE_CHART.multiplier(moveType, t1, t2)
	if not TYPE_CHART.entries then
		local b, entries = memory.read_bytes_as_array(TYPE_CHART.at, TYPE_CHART.size, BUS), {}
		for i = 1, TYPE_CHART.size - 2, 3 do
			if b[i] == 0xFF then break end
			if b[i] ~= 0xFE then entries[#entries + 1] = { b[i], b[i + 1], b[i + 2] } end
		end
		TYPE_CHART.entries = entries
	end
	local m = 1
	for _, e in ipairs(TYPE_CHART.entries) do
		if e[1] == moveType then
			if e[2] == t1 then m = m * e[3] / 10 end
			if e[2] == t2 and t1 ~= t2 then m = m * e[3] / 10 end
		end
	end
	return m
end

local moveCache = {}
local function moveInfo(id)
	local m = moveCache[id]
	if m == nil and id >= 1 and id < MOVE_COUNT then
		local e = memory.read_bytes_as_array(BATTLE_MOVES + id * BATTLE_MOVE_SIZE, BATTLE_MOVE_SIZE, BUS)
		local desc = readString(r32(MOVE_DESCRIPTIONS + (id - 1) * 4))
		m = { type = TYPE_CHART.name(e[3]), type_id = e[3], power = e[2], accuracy = e[4], base_pp = e[5], target = e[7], effect = e[1],
			description = #desc > 0 and decode(desc, 1, #desc) or nil }
		moveCache[id] = m
	end
	return m or {}
end

-- The four encrypted 12-byte blocks at +0x20: personality mod 24 = r puts the kinds in the r-th lexicographic ordering
-- of 0-3. Kind 0 holds species, held item and EXP, kind 1 moves and PP, kind 3 the met level.
local function blockOfKind(residue, kind)
	local pool, r, fact = { 0, 1, 2, 3 }, residue, { 6, 2, 1, 1 }
	for pos = 1, 4 do
		local k = table.remove(pool, r // fact[pos] + 1)
		r = r % fact[pos]
		if k == kind then return pos - 1 end
	end
end

-- TM and HM compatibility: 8 bytes a species, bit i for entry i of sTMHMMoves (50 TMs, then 8 HMs); `hmOnly` names the
-- HMs, for picking spare Pokémon to carry them. A global: this chunk is at Lua's local limit.
EMERALD_TMHM = { learnset = 0x0831e898, moves = 0x08616040 }
function EMERALD_TMHM.canLearn(species, hmOnly)
	if not species or species < 1 or species >= SPECIES_COUNT then return nil end
	local out = {}
	for i = hmOnly and 50 or 0, 57 do
		if (r8(EMERALD_TMHM.learnset + species * 8 + (i >> 3)) >> (i & 7)) & 1 == 1 then
			out[#out + 1] = nameAt(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, r16(EMERALD_TMHM.moves + i * 2))
		end
	end
	return out
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
			mon.hm_moves = EMERALD_TMHM.canLearn(mon.species_id, true)
			local held = words[g] >> 16
			if held ~= 0 then mon.held_item = itemName(held) or string.format("item %d", held) end
			mon.exp = words[g + 1]
			local moves = {}
			for i = 0, 3 do
				local id = (words[a + (i >> 1)] >> (16 * (i & 1))) & 0xFFFF
				if id ~= 0 then
					local info = moveInfo(id)
					moves[#moves + 1] = { name = nameAt(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, id), id = id,
						pp = (words[a + 2] >> (8 * i)) & 0xFF, base_pp = info.base_pp, type = info.type,
						power = info.power, accuracy = info.accuracy, description = info.description }
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

-- List menus: a task (gTasks, 40 bytes each: the routine +0, nonzero +4 while active, data from +8) running
-- ListMenuDummyTask. Its data's first word points at the entries (8 bytes: a name pointer, then an id), +0x0C the
-- count, +0x10 the window, +0x18 the scroll and +0x1A the row. Under CB2_BagMenuRun, gBagPosition +5 is the pocket.
local GTASKS, TASK_SIZE, NUM_TASKS, LIST_MENU_TASK = 0x03005e00, 40, 16, 0x081ae458
local BAG_POSITION, CB2_BAG_MENU_RUN = 0x0203ce58, 0x081aad5c

local function readListMenu()
	for i = NUM_TASKS - 1, 0, -1 do
		local at = GTASKS + i * TASK_SIZE
		if r8(at + 4) ~= 0 and (r32(at) & 0xFFFFFFFE) == LIST_MENU_TASK then
			local d = memory.read_bytes_as_array(at + 8, 32, BUS)
			local entries, total = u32of(d, 1), u16of(d, 13)
			if (inEwram(entries) or inRom(entries)) and total >= 1 and total <= 255 then
				local items = {}
				for k = 0, total - 1 do
					local name = readString(r32(entries + k * 8))
					items[#items + 1] = decode(name, 1, #name)
				end
				local m = { window = d[17], items = items, cursor = u16of(d, 25) + u16of(d, 27), list = true }
				local cb2 = r32(GMAIN_CB2) & 0xFFFFFFFE
				if cb2 == CB2_BAG_MENU_RUN then
					local pocket = POCKETS[r8(BAG_POSITION + 5) + 1]
					m.pocket = pocket and pocket.name
				end
				return m
			end
		end
	end
	return nil
end

-- The naming keyboard: under CB2_NamingScreen, sNamingScreen points at a block whose +0x1800 is the name so far,
-- +0x1E10 the state (2 while keys are taken), +0x1E22 the page (1 capitals, 2 small, 0 symbols), +0x1E23 the cursor's
-- sprite (data[0] and data[1] its column and row) and +0x1E28 a template (+1 the length, +8 the title). The column past
-- a page's last is the buttons, OK on row 2. sKeyboardChars is three blocks of 4 rows of 8, block 1 the capitals.
local CB2_NAMING_SCREEN, SNAMINGSCREEN, GSPRITES, SPRITE_SIZE = 0x080e4f58, 0x02039f94, 0x02020630, 0x44
local KEYBOARD_CHARS, KEYBOARD_READY = 0x0858be40, 2
local PAGE_BLOCK, PAGE_COLUMNS = { [0] = 2, [1] = 1, [2] = 0 }, { [0] = 6, [1] = 8, [2] = 8 }
local PAGE_NAMES, OK_ROW = { [0] = "symbols", [1] = "capitals", [2] = "small" }, 2

local keyboardKeys = nil
local function keysOf(page)
	if not keyboardKeys then
		keyboardKeys = {}
		local b = memory.read_bytes_as_array(KEYBOARD_CHARS, 0x60, BUS)
		for p, block in pairs(PAGE_BLOCK) do
			local rows = {}
			for r = 0, 3 do
				local row = {}
				for c = 0, PAGE_COLUMNS[p] - 1 do
					local byte = b[block * 32 + r * 8 + c + 1]
					row[#row + 1] = { byte = byte, glyph = CHARS[byte] or string.format("{%02X}", byte) }
				end
				rows[#rows + 1] = row
			end
			keyboardKeys[p] = rows
		end
	end
	return keyboardKeys[page]
end

local function keyboardState()
	local cb = r32(GMAIN_CB2) & 0xFFFFFFFE
	if cb ~= CB2_NAMING_SCREEN then return nil end
	local ns = r32(SNAMINGSCREEN)
	if not inEwram(ns) then return nil end
	local tail = memory.read_bytes_as_array(ns + 0x1E10, 0x1C, BUS)
	local page, sprite, tpl = tail[0x13], tail[0x14], u32of(tail, 0x19)
	if not PAGE_BLOCK[page] or sprite > 64 or not inRom(tpl) then return nil end
	local spr = GSPRITES + sprite * SPRITE_SIZE
	local text = readString(ns + 0x1800)
	return { ns = ns, state = tail[1], page = page, column = memory.read_s16_le(spr + 0x2E, BUS),
		row = memory.read_s16_le(spr + 0x30, BUS), text = text, max = r8(tpl + 1), title = r32(tpl + 8) }
end

local function readKeyboard()
	local k = keyboardState()
	if not k then return nil end
	local keys, rows = keysOf(k.page), {}
	for _, row in ipairs(keys) do
		local glyphs = {}
		for _, key in ipairs(row) do glyphs[#glyphs + 1] = key.glyph end
		rows[#rows + 1] = glyphs
	end
	local on
	if k.column >= 0 and k.column < PAGE_COLUMNS[k.page] and k.row >= 0 and k.row <= 3 then
		on = keys[k.row + 1][k.column + 1].glyph
	elseif k.column == PAGE_COLUMNS[k.page] and k.row == OK_ROW then
		on = "OK"
	end
	local title = inRom(k.title) and readString(k.title) or {}
	return { title = #title > 0 and decode(title, 1, #title) or nil, text = decode(k.text, 1, #k.text), length = #k.text,
		max_length = k.max, page = PAGE_NAMES[k.page], cursor = { column = k.column, row = k.row }, on = on,
		on_button_row = on == nil and k.column == PAGE_COLUMNS[k.page] and k.row or nil, keys = rows,
		ready = k.state == KEYBOARD_READY or nil, state_raw = k.state ~= KEYBOARD_READY and k.state or nil }
end

-- The wall clock: under CB2_WallClock, task 0's routine is the step (setting, the YES/NO, closing, or viewing a clock
-- already set) and its s16 data words from +8 the time: +4 the hours 0-23, +6 the minutes, +8 the direction held (2
-- Right, 1 Left), +10 the period (1 PM), +12 how long it was held.
local CLOCK = { cb2 = 0x08134c9c, setting = 0x08134ce8, asking = 0x08134e30, periods = { [0] = "AM", [1] = "PM" },
	states = { [0x08134ce8] = "setting", [0x08134dc4] = "confirming", [0x08134e30] = "confirming",
		[0x08134ea4] = "closing", [0x08134ee8] = "closing", [0x08134f10] = "viewing", [0x08134f40] = "viewing" } }

local function clockState()
	if (r32(GMAIN_CB2) & 0xFFFFFFFE) ~= CLOCK.cb2 then return nil end
	for n = 0, NUM_TASKS - 1 do
		local at = GTASKS + n * TASK_SIZE
		local func = r32(at) & 0xFFFFFFFE
		if r8(at + 4) ~= 0 and CLOCK.states[func] then
			local s16 = function(o) return memory.read_s16_le(at + 8 + o, BUS) end
			return { func = func, hours = s16(4), minutes = s16(6), direction = s16(8), period = s16(10), speed = s16(12) }
		end
	end
	return nil
end

local function readClock()
	local c = clockState()
	if not c then return nil end
	return { hours = c.hours, minutes = c.minutes, period = CLOCK.periods[c.period],
		period_raw = not CLOCK.periods[c.period] and c.period or nil, state = CLOCK.states[c.func],
		turning = c.direction ~= 0 or nil }
end

-- The starter bag: under CB2_StarterChoose, task 0's data word 0 is the ball (0 left, 1 bottom, 2 right), and
-- sStarterMon names the species. A move runs two other routines for 2 frames, already holding the new word, so they
-- read as the menu too.
local STARTER = { cb2 = 0x081341e0, species = 0x085b1df8,
	choosing = { [0x0813425c] = true, [0x08134640] = true, [0x08134668] = true } }

-- The bag as a menu of one row of three, for `select` and `advance_text`, or nil.
function STARTER.menu()
	if (r32(GMAIN_CB2) & 0xFFFFFFFE) ~= STARTER.cb2 then return nil end
	for n = 0, NUM_TASKS - 1 do
		local at = GTASKS + n * TASK_SIZE
		if r8(at + 4) ~= 0 and STARTER.choosing[r32(at) & 0xFFFFFFFE] then
			local items = {}
			for i = 0, 2 do
				local id = r16(STARTER.species + i * 2)
				items[#items + 1] = nameAt(SPECIES_NAMES, SPECIES_LEN, SPECIES_COUNT, id) or ("species " .. id)
			end
			return { kind = "starter", items = items, cursor = memory.read_s16_le(at + 8, BUS), columns = 3 }
		end
	end
	return nil
end

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

-- Battles: gMain.callback2 is BattleMainCB2 (+1) from before the first message to after the last.
local BATTLE_MAIN_CB2 = 0x08038420
local BATTLE_TYPE_FLAGS, BATTLERS_COUNT, BATTLER_POSITIONS = 0x02022fec, 0x0202406c, 0x02024076
-- 0x58 bytes a battler: species +0x00, moves +0x0C, PP +0x24, HP +0x28, level +0x2A, max HP +0x2C, name +0x30.
local BATTLE_MONS, BATTLE_MON_SIZE = 0x02024084, 0x58
local ACTION_CURSOR, MOVE_CURSOR, BATTLE_OUTCOME = 0x020244ac, 0x020244b0, 0x0202433a
-- One routine per battler: HandleInputChooseAction while the action menu waits, HandleInputChooseMove the move menu.
local CONTROLLER_FUNCS, CHOOSE_ACTION, CHOOSE_MOVE = 0x03005d60, 0x08057588, 0x08057bfc
-- The battle script's pointer, and gBattleScripting +0x1E: 6 or 8 while the level-up box's page 1 or 2 waits for A.
local BATTLESCRIPT_INSTR, LEVEL_UP_BOX_STATE = 0x02024214, 0x02024474 + 0x1E
local LEVEL_UP_BOX_WAITING = { [6] = "page 1", [8] = "page 2" }
-- gAnimScriptActive reads 01 while a move's animation plays, and an A pressed inside one changes nothing. Bit n of
-- gBattleControllerExecFlags is set while battler n's controller is at work, until its routine is back at the one it
-- idles in: the game at work, unless the routine waits for a button (a message on its arrow, the menus, the target). A
-- wait not measured yet counts as work too, nudged after text.lua's SCRIPT_WAIT_FRAMES.
local BATTLE_BUSY = { anim = 0x020383fd, execFlags = 0x02024068,
	inputWaits = { [0x080597b4] = true, [CHOOSE_ACTION] = true, [CHOOSE_MOVE] = true, [0x08057824] = true } }

function BATTLE_BUSY.playing()
	if r8(BATTLE_BUSY.anim) ~= 0 then return true end
	local flags = r32(BATTLE_BUSY.execFlags)
	for i = 0, math.min(r8(BATTLERS_COUNT), 4) - 1 do
		if (flags >> i) & 1 == 1 and not BATTLE_BUSY.inputWaits[r32(CONTROLLER_FUNCS + i * 4) & 0xFFFFFFFE] then return true end
	end
	return false
end
-- The learn-a-move question, the move list and the evolution scene. In a battle the command at the battle script's
-- pointer, through gBattleScriptingCommandsTable, is Cmd_yesnoboxlearnmove (the "Stop learning?" one is taken to wait
-- the same way); gBattleScripting +0x1F reads 1 while its YES/NO waits, the cursor at gBattleCommunication +1. The list
-- is the summary screen (sMonSummaryScreen +0x40BC mode 3, +0x40BE the slot, +0x40C4 the move, +0x40C6 the cursor): the
-- party slot's moves in order, then the new one. In the evolution scene task 0's word 0 is its state (0x16 while a move
-- is replaced), word 6 the step (4 the YES/NO) and word 7 where YES goes (5 learn, 0x0B stop). Measured on slot 0 only.
local LEARN = { stateAt = 0x02024474 + 0x1F, cursorAt = 0x02024332 + 1, commands = 0x0831bd10,
	learnCmd = 0x0804e038, stopCmd = 0x0804e3c8, summaryCB2 = 0x081bfab4, summaryPtr = 0x0203cf1c, replaceInput = 0x081c174c,
	evoCB2 = 0x0813e3a4, evoLoadCB2 = 0x0813dd7c, evoTask = 0x0813e570, speciesInfo = 0x083203cc,
	-- Cmd_trygivecaughtmonnick: the nickname question after a catch, waiting while gBattleCommunication +0 reads 1.
	nicknameCmd = 0x08056bec }

function LEARN.evolution()
	local cb = r32(GMAIN_CB2) & 0xFFFFFFFE
	if cb ~= LEARN.evoCB2 and cb ~= LEARN.evoLoadCB2 then return nil end
	for n = 0, NUM_TASKS - 1 do
		local at = GTASKS + n * TASK_SIZE
		if r8(at + 4) ~= 0 and (r32(at) & 0xFFFFFFFE) == LEARN.evoTask then
			local s16 = function(i) return memory.read_s16_le(at + 8 + i * 2, BUS) end
			return { state = s16(0), species = s16(2), step = s16(6), yes = s16(7), loading = cb == LEARN.evoLoadCB2 }
		end
	end
	return nil
end

function LEARN.options(slot, newMove)
	local mon = (readParty() or {})[slot + 1]
	if not mon or not mon.moves then return nil end
	local sp = LEARN.speciesInfo + (mon.species_id or 0) * 28
	local t1, t2 = r8(sp + 6), r8(sp + 7)
	local out, items = {}, {}
	local function add(id, name)
		local info = moveInfo(id)
		out[#out + 1] = { name = name, type = info.type, power = info.power, accuracy = info.accuracy,
			same_type = (info.type_id == t1 or info.type_id == t2) or nil }
		items[#items + 1] = name
	end
	for _, m in ipairs(mon.moves) do add(m.id, m.name) end
	add(newMove, nameAt(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, newMove) or ("move " .. newMove))
	return out, items, mon
end

-- The learn-a-move question on screen, as text.lua's battleQuestion hook returns one, or nil.
function LEARN.question()
	local cb = r32(GMAIN_CB2) & 0xFFFFFFFE
	local kind
	if cb == BATTLE_MAIN_CB2 then
		local handler = r32(LEARN.commands + r8(r32(BATTLESCRIPT_INSTR)) * 4) & 0xFFFFFFFE
		if handler == LEARN.nicknameCmd and r8(LEARN.cursorAt - 1) == 1 then
			local d = readDialogue()
			return { kind = "nickname", text = d and d.box, menu = { items = { "YES", "NO" }, cursor = r8(LEARN.cursorAt) }, no = 1 }
		end
		-- "Will A change POKéMON?" before a trainer's next Pokémon, read by its message; its cursor is the nickname's.
		local d = readDialogue()
		if d and d.box and d.box:find("change", 1, true) and d.box:find("POK", 1, true) and d.box:sub(-1) == "?" then
			return { kind = "switch", text = d.box, menu = { items = { "YES", "NO" }, cursor = r8(LEARN.cursorAt) }, no = 1 }
		end
		if r8(LEARN.stateAt) ~= 1 then return nil end
		kind = (handler == LEARN.learnCmd and "learn_move") or (handler == LEARN.stopCmd and "stop_learning") or nil
	elseif cb == LEARN.evoCB2 then
		local e = LEARN.evolution()
		if e and e.state == 0x16 and e.step == 4 then kind = (e.yes == 5 and "learn_move") or (e.yes == 0x0B and "stop_learning") or nil end
	elseif cb == LEARN.summaryCB2 then
		local ptr = r32(LEARN.summaryPtr)
		local s = inEwram(ptr) and memory.read_bytes_as_array(ptr + 0x40BC, 12, BUS)
		if not s or s[1] ~= 3 then return nil end
		for n = 0, NUM_TASKS - 1 do
			local at = GTASKS + n * TASK_SIZE
			if r8(at + 4) ~= 0 and (r32(at) & 0xFFFFFFFE) == LEARN.replaceInput then
				local options, items = LEARN.options(s[3], s[9] | (s[10] << 8))
				if not options then return nil end
				return { kind = "forget_move", text = "the move list", options = options, move = options[#options].name,
					menu = { items = items, cursor = s[11] } }
			end
		end
		return nil
	end
	if not kind then return nil end
	local d = readDialogue()
	local options, _, mon = LEARN.options(0, r16(0x020244e2))
	return { kind = kind, text = d and d.box, options = options, move = options and options[#options].name,
		pokemon = mon and mon.nickname, menu = { items = { "YES", "NO" }, cursor = r8(LEARN.cursorAt) }, no = 1 }
end

-- A Mart's quantity box: a task running Task_BuyHowManyDialogueHandleInput, data word 1 the count and word 5 the item.
-- The list's own task stays active under it, so the list is not taken as the menu while this box or a message is up.
LEARN.quantityTask = 0x080e0d88
function LEARN.quantity()
	for n = 0, NUM_TASKS - 1 do
		local at = GTASKS + n * TASK_SIZE
		if r8(at + 4) ~= 0 and (r32(at) & 0xFFFFFFFE) == LEARN.quantityTask then
			local id = memory.read_s16_le(at + 18, BUS)
			return { kind = "quantity", item = itemName(id) or ("item " .. id), count = memory.read_s16_le(at + 10, BUS), items = {},
				cursor = 0 }
		end
	end
	return nil
end
-- The party list ("Use on which POKéMON?"): under CB2_UpdatePartyMenu, task 0 running Task_HandleChooseMonInput, and
-- gPartyMenu +9 the cursor (7 on CANCEL). Read as the party's nicknames in slot order, then CANCEL.
LEARN.partyMenu = { cb2 = 0x081b01b0, task = 0x081b1370, at = 0x0203cec8 }
function LEARN.partyMenu.read()
	local pm = LEARN.partyMenu
	if (r32(GMAIN_CB2) & 0xFFFFFFFE) ~= pm.cb2 then return nil end
	for n = 0, NUM_TASKS - 1 do
		local at = GTASKS + n * TASK_SIZE
		if r8(at + 4) ~= 0 and (r32(at) & 0xFFFFFFFE) == pm.task then
			local items = {}
			for _, mon in ipairs(readParty() or {}) do items[#items + 1] = mon.nickname end
			local slot = memory.read_s8(pm.at + 9, BUS)
			items[#items + 1] = "CANCEL"
			return { kind = "party", items = items, cursor = (slot == 7) and (#items - 1) or slot }
		end
	end
	return nil
end

-- The action menu as drawn, in cursor order: 0 FIGHT and 1 BAG on the top row, 2 POKéMON and 3 RUN below.
local BATTLE_ACTIONS = { "FIGHT", "BAG", "POKéMON", "RUN" }

local function inBattle()
	local cb = r32(GMAIN_CB2)
	return cb == BATTLE_MAIN_CB2 or cb == BATTLE_MAIN_CB2 + 1
end

-- What the player's side is asked, "action", "move" or "target", and which battler asks. In a double battle the
-- player's second Pokémon is battler 2, with its own routine and cursors (one byte a battler); HandleInputChooseTarget
-- (0x08057824) is battler 0's while a target is chosen, the cursor at gMultiUsePlayerCursor (0x03005d74).
local function battleAsking()
	for _, i in ipairs({ 0, 2 }) do
		local f = r32(CONTROLLER_FUNCS + i * 4) & 0xFFFFFFFE
		if f == CHOOSE_ACTION then return "action", i end
		if f == CHOOSE_MOVE then return "move", i end
		if f == 0x08057824 then return "target", i end
	end
	return nil
end

local function readBattle()
	local n = r8(BATTLERS_COUNT)
	if n < 1 or n > 4 then return nil end
	local positions = memory.read_bytes_as_array(BATTLER_POSITIONS, 4, BUS)
	local battlers = {}
	for i = 0, n - 1 do
		local b = memory.read_bytes_as_array(BATTLE_MONS + i * BATTLE_MON_SIZE, BATTLE_MON_SIZE, BUS)
		local moves = {}
		for k = 0, 3 do
			local id = u16of(b, 13 + k * 2)
			if id ~= 0 then
				-- Type, power and accuracy only: a battle observation rides on every press (effect text: `party`).
				local info = moveInfo(id)
				moves[#moves + 1] = { name = nameAt(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, id), id = id, pp = b[37 + k],
					type = info.type, power = info.power, accuracy = info.accuracy }
			end
		end
		local last = 59
		for k = 49, 59 do
			if b[k] == EOS then
				last = k - 1
				break
			end
		end
		local pos = positions[i + 1]
		local types = { TYPE_CHART.name(b[0x22]) or string.format("type %d", b[0x22]) }
		if b[0x23] ~= b[0x22] then types[2] = TYPE_CHART.name(b[0x23]) or string.format("type %d", b[0x23]) end
		battlers[#battlers + 1] = { battler = i, position = pos, side = (pos == 0 and "player") or (pos == 1 and "opponent") or nil,
			species_id = u16of(b, 1), species = nameAt(SPECIES_NAMES, SPECIES_LEN, SPECIES_COUNT, u16of(b, 1)),
			nickname = decode(b, 49, last), level = b[43], hp = u16of(b, 41), max_hp = u16of(b, 45), types = types,
			moves = #moves > 0 and moves or nil,
			-- The ability, +0x20, named from gAbilityNames, 13 bytes a name (inline: the chunk is at the local limit).
			ability_id = b[0x21], ability = nameAt(0x0831b6db, 13, 256, b[0x21]), hm_moves = EMERALD_TMHM.canLearn(u16of(b, 1), true) }
	end
	-- Type flag 0x08 is set against a trainer.
	local flags = r32(BATTLE_TYPE_FLAGS)
	return { asking = battleAsking(), kind = (flags & 0x08) ~= 0 and "trainer" or "wild", battlers = battlers,
		type_flags_raw = flags, outcome_raw = r8(BATTLE_OUTCOME) }
end

-- The menu the asking battler is choosing from, as `select` reads a menu: `columns` 2, cursor order row by row.
local function battleMenu()
	local asking, battler = battleAsking()
	if asking == "action" then
		return { window = "battle_action", items = BATTLE_ACTIONS, cursor = r8(ACTION_CURSOR + battler), columns = 2 }
	elseif asking == "move" then
		local items = {}
		for k = 0, 3 do
			local id = r16(BATTLE_MONS + battler * BATTLE_MON_SIZE + 0x0C + k * 2)
			items[#items + 1] = id ~= 0 and (nameAt(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, id) or string.format("move %d", id)) or "-"
		end
		return { window = "battle_move", items = items, cursor = r8(MOVE_CURSOR + battler), columns = 2 }
	end
	return nil
end

local game = {
	game = "emerald",
	-- "vanilla" only when the ROM's hash is the one every address here was measured on.
	variant = isVanilla and "vanilla" or "unverified",
	capabilities = { "observe", "press", "wait", "screenshot", "snapshot", "restore", "cheat:warp", "cheat:set_flag",
		"cheat:give_item", "cheat:register_item", "select", "walk", "goto", "battle", "advance_text", "type_text",
		"set_clock", "cheat:noclip", "talk", "clear_obstacle", "search", "reflex", "reflex:use_item", "reflex:fly", "reflex:fly_scan", "reflex:swap", "reflex:ride", "reflex:field_move" },
	menuButtons = { prev = "Up", next = "Down", left = "Left", right = "Right", confirm = "A" },
	protected_slots = { 1 },
	-- The folder under dev-scripts/shots/ this game's pictures go to.
	shots = "emerald",
}

function game.build()
	return string.format("gamecode %08X", r32(0x080000AC))
end

-- Any execute hook halves the emulator's top speed, however many there are, so AUTOPLAY_TEXT=0 leaves them out.
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
	shown, dialogue, menuWindow, instantPrinted = {}, nil, nil, {}
end

-- `asked` is true for the agent's own observe; the before and after of a press, a select or a walk leave out what the
-- save has, which rarely changes during one and is most of an observation's size.
function game.observe(asked)
	local cb2 = r32(GMAIN_CB2)
	local sb1 = r32(SB1PTR)
	local obj = GOBJECTEVENTS + r8(GPLAYERAVATAR + 5) * 0x24
	local d, m, s
	local battle = isVanilla and inBattle() and readBattle() or nil
	if #hookNames > 0 then
		d, m = readDialogue(), readMenu()
	end
	-- A list menu under a menu opened from it (the bag's item menu) is not the one waiting.
	local list = (isVanilla and not battle and not m and not d) and (LEARN.quantity() or readListMenu()) or nil
	m = m or list or (isVanilla and (STARTER.menu() or LEARN.partyMenu.read())) or nil
	if #hookNames > 0 then
		-- In a battle the windows' bytes do not say which are showing, so screen_text is left out there; a list's own
		-- window too, since its rows are reprinted as it scrolls.
		if not battle then
			s = readScreenText(d and d.window, m and m.window)
			if #s == 0 then s = nil end
		end
	end
	if battle then m = battleMenu() end
	local question = isVanilla and LEARN.question() or nil
	if question then
		m = { kind = question.kind, text = question.text, items = question.menu.items, cursor = question.menu.cursor,
			move = question.move, pokemon = question.pokemon, options = question.options }
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
		keyboard = isVanilla and readKeyboard() or nil,
		clock = isVanilla and readClock() or nil,
		party = save and save.party,
		bag = save and save.bag,
		money = save and save.money,
		badge_count = save and save.badge_count,
		badges = save and save.badges,
		battle = battle,
		dialogue = d,
		menu = m,
		screen_text = s,
		local_map = localMap,
		nearby = nearby,
		warps = warps,
		frame = emu.framecount(),
		mode = (overworld and "overworld") or (battle and "battle") or "not_overworld",
		-- The avatar's first byte (ON_FOOT_FLAG and the rest); anything else stays in extras.
		movement = overworld and (((r8(GPLAYERAVATAR) & 0x04) ~= 0 and "acro_bike") or ((r8(GPLAYERAVATAR) & 0x02) ~= 0
			and "mach_bike") or ((r8(GPLAYERAVATAR) & 0x01) ~= 0 and "on_foot")) or nil,
		location = {
			map = string.format("%d.%d", r8(sb1 + 4), r8(sb1 + 5)),
			x = r16(sb1),
			y = r16(sb1 + 2),
		},
		extras = {
			callback2 = string.format("%08X", cb2),
			script_context_raw = r8(SCRIPT_CONTEXT_STATUS),
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

-- Cheats: each takes its args and returns a plan, { untilFn = function(observation) -> done, limit = frames, report },
-- or nil and a reason. A cheat changes the world by other means than play; the core marks the segment reached.
game.cheats = {}

-- warp {map = "G.N", x, y}: the game's own map load, written as cmd_drive.lua's `warp` writes it. Refused outside
-- vanilla's overworld callback; done once the game has left the overworld and come back on the target map.
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

-- set_flag {flag, value = true}: ids 1 to FLAG_MAX. Refused outside the overworld, since SaveBlock1 moves during the
-- map load after CONTINUE. `report` reads the bit back.
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

-- give_item {item = name or id, quantity = 1}: into the pocket its table names. Refused past MAX_STACK, the most the
-- bag was seen to show, and outside the overworld (set_flag says why). `report` reads the pocket back.
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

-- register_item {item = name or id}: the item SELECT uses, SaveBlock1 +0x496, a plain u16. Refused unless the bag holds
-- the item, and outside the overworld. Getting on a bike is then a press of Select.
function game.cheats.register_item(args)
	local id = math.tointeger(args.item)
	if not id and type(args.item) == "string" then id = itemIdByName(args.item) end
	if not id or id < 1 or id >= ITEM_COUNT then
		return nil, "register_item needs item, a name as the bag shows it or an id 1 to " .. (ITEM_COUNT - 1)
	end
	if not isVanilla then return nil, "register_item is measured on the vanilla ROM only" end
	if not inOverworld() then
		return nil, string.format("register_item refused: gMain.callback2 is %08X, not vanilla's overworld", r32(GMAIN_CB2))
	end
	local sb1 = r32(SB1PTR)
	local held = false
	for _, list in pairs(readBag(sb1, r32(r32(SB2PTR) + 0xAC))) do
		for _, e in ipairs(list) do
			if e.id == id then held = true end
		end
	end
	if not held then return nil, string.format("the bag holds no %s", tostring(itemName(id))) end
	local was = r16(sb1 + 0x496)
	w16(sb1 + 0x496, id)
	return {
		limit = 1,
		untilFn = function() return true end,
		report = function()
			local now = r16(r32(SB1PTR) + 0x496)
			return { item = itemName(now), id = now, was = itemName(was) or was }
		end,
	}
end

-- noclip {on}: each frame (the grid streams tiles in) collision is cleared near the player except on the border's
-- metatile 0x3FF, and other characters go to an elevation the player is not on; put back when it goes off or the
-- driver unloads, dropped on a map change or a restore, which rebuild both. Not measured on ledges or water.
local NOCLIP = { on = false, radius = 6, tiles = {}, elevations = {}, where = nil }

function NOCLIP.forget()
	NOCLIP.tiles, NOCLIP.elevations, NOCLIP.where = {}, {}, nil
end

function NOCLIP.putBack()
	local tiles, characters = 0, 0
	for addr, t in pairs(NOCLIP.tiles) do
		-- A word the game has rewritten since is not ours to put back.
		if r16(addr) == t.now then
			w16(addr, t.was)
			tiles = tiles + 1
		end
	end
	for slot, was in pairs(NOCLIP.elevations) do
		local at = GOBJECTEVENTS + slot * OBJ_SIZE + 0x0B
		w8(at, (r8(at) & 0xF0) | was)
		characters = characters + 1
	end
	NOCLIP.forget()
	return tiles, characters
end

function game.tick()
	if not NOCLIP.on then return end
	local sb1 = r32(SB1PTR)
	if not inEwram(sb1) then return end
	local here = r8(sb1 + 4) * 256 + r8(sb1 + 5)
	if here ~= NOCLIP.where then
		NOCLIP.forget()
		NOCLIP.where = here
	end
	local me = playerSlot()
	if me > 15 then return end
	local obj = GOBJECTEVENTS + me * OBJ_SIZE
	local px, py = r16(obj + 0x10), r16(obj + 0x12)
	local width, height, grid = r32(GBACKUPMAPLAYOUT), r32(GBACKUPMAPLAYOUT + 4), r32(GBACKUPMAPLAYOUT + 8)
	if inEwram(grid) and width > 0 and width < 1024 and height > 0 and height < 1024 then
		local x0, x1 = math.max(px - NOCLIP.radius, 0), math.min(px + NOCLIP.radius, width - 1)
		for y = math.max(py - NOCLIP.radius, 0), math.min(py + NOCLIP.radius, height - 1) do
			if x1 >= x0 then
				local row = memory.read_bytes_as_array(grid + (x0 + width * y) * 2, (x1 - x0 + 1) * 2, BUS)
				for x = x0, x1 do
					local i = (x - x0) * 2 + 1
					local block = row[i] | (row[i + 1] << 8)
					if (block & 0x0C00) ~= 0 and (block & 0x03FF) ~= 0x03FF then
						local addr = grid + (x + width * y) * 2
						NOCLIP.tiles[addr] = { was = block, now = block & 0xF3FF }
						w16(addr, block & 0xF3FF)
					end
				end
			end
		end
	end
	-- Never elevation 0, which is compatible with every other.
	local want = ((r8(obj + 0x0B) & 0x0F) == 3) and 1 or 3
	for s = 0, 15 do
		local at = GOBJECTEVENTS + s * OBJ_SIZE
		if s ~= me and (r8(at) & 1) == 1 then
			local b = r8(at + 0x0B)
			if (b & 0x0F) ~= want then
				if NOCLIP.elevations[s] == nil then NOCLIP.elevations[s] = b & 0x0F end
				w8(at + 0x0B, (b & 0xF0) | want)
			end
		end
	end
end

-- The cheats still in effect, for the driver's hello and every cheat's answer.
function game.persisting()
	return NOCLIP.on and { "noclip" } or {}
end

function game.cheats.noclip(args)
	if not isVanilla then return nil, "noclip is measured on the vanilla ROM only" end
	local on = args.on ~= false
	local tilesBack, charactersBack
	if on then
		if not inOverworld() then return nil, "noclip refused: not in vanilla's overworld callback" end
		NOCLIP.on = true
	else
		NOCLIP.on = false
		tilesBack, charactersBack = NOCLIP.putBack()
	end
	return {
		limit = 1,
		untilFn = function() return true end,
		report = function()
			if not on then return { on = false, tiles_put_back = tilesBack, characters_put_back = charactersBack } end
			local tiles, characters = 0, 0
			for _ in pairs(NOCLIP.tiles) do tiles = tiles + 1 end
			for _ in pairs(NOCLIP.elevations) do characters = characters + 1 end
			return { on = true, tiles_cleared = tiles, characters_moved = characters }
		end,
	}
end

-- Unloading puts everything back; a restored snapshot has replaced what noclip changed.
do
	local stop, restored = game.stop, game.restored
	function game.stop()
		if NOCLIP.on then NOCLIP.putBack() end
		NOCLIP.on = false
		stop()
	end
	function game.restored()
		NOCLIP.forget()
		restored()
	end
end

-- The menu alone, for a program that looks every frame (select).
function game.menu()
	local q = isVanilla and LEARN.question() or nil
	if q then return { kind = q.kind, items = q.menu.items, cursor = q.menu.cursor } end
	if isVanilla and inBattle() then return battleMenu() end
	local m = (#hookNames > 0) and readMenu() or nil
	local d = (#hookNames > 0) and readDialogue() or nil
	return m or (isVanilla and (LEARN.quantity() or (not d and readListMenu()) or STARTER.menu() or LEARN.partyMenu.read())) or nil
end

-- Programs: run once a frame by the driver, each returning (pad or nil, finished, result, error).
game.programs = {}

local DIRECTIONS = {
	up = { button = "Up", dx = 0, dy = -1 }, down = { button = "Down", dx = 0, dy = 1 },
	left = { button = "Left", dx = -1, dy = 0 }, right = { button = "Right", dx = 1, dy = 0 },
}
local REST_LIMIT, IDLE_LIMIT, PRESS_LIMIT, DOOR_LIMIT, STEP_LIMIT = 120, 20, 90, 150, 180
-- The avatar's first byte: 0x01 on foot (0x81 running), 0x02 on the Mach Bike, 0x04 on the Acro Bike.
local ON_FOOT_FLAG, MACH_BIKE_FLAG, ACRO_BIKE_FLAG = 0x01, 0x02, 0x04

-- At rest, after a step, a bump or a turn alike: the player object's byte 0 has its top bit back, its previous
-- coordinates equal its current ones, and the avatar's +2 and +3 are both 0.
local function atRest()
	local b = memory.read_bytes_as_array(playerObject(), 0x18, BUS)
	local a = memory.read_bytes_as_array(GPLAYERAVATAR + 2, 2, BUS)
	return (b[1] & 0x80) ~= 0 and b[17] == b[21] and b[18] == b[22] and b[19] == b[23] and b[20] == b[24]
		and a[1] == 0 and a[2] == 0
end

-- A bump leaves the coordinates, the previous coordinate already equal to them, the avatar's +2 at 2 and byte 0's top
-- bit clear; +2 reads 0 while nothing is under way (1 turning, or a door opening).
local STEP = {}
function STEP.refused()
	local b = memory.read_bytes_as_array(playerObject(), 0x18, BUS)
	local caughtUp = b[17] == b[21] and b[18] == b[22] and b[19] == b[23] and b[20] == b[24]
	return r8(GPLAYERAVATAR + 2) == 2 and caughtUp and (b[1] & 0x80) == 0
end
function STEP.idle() return r8(GPLAYERAVATAR + 2) == 0 end

-- Why a step was refused, from what describeTile read; `unknown` is another elevation, not measured. A ledge reads
-- collision set and hops its one way; 0x39 and 0x3A are taken as the same family, not walked.
STEP.LEDGES = { [0x38] = "right", [0x39] = "left", [0x3A] = "up", [0x3B] = "down" }
function STEP.cause(t)
	if t.outside_map then return "off_map" end
	if t.character then return "npc_in_way" end
	if STEP.LEDGES[t.behaviour] then return "one_way_edge" end
	if STEP.SURF[t.behaviour] and t.elevation == 1 and t.collision == 0 then return "missing_ability", "surf" end
	if t.collision ~= 0 then return "solid" end
	return "unknown"
end

-- On the Mach Bike, whether to let go now with `tiles` left: once released the ride carries on for the avatar's +0x0B
-- more tiles, and holding one more raises it from 0 to 1, or from 1 to 3.
function STEP.machCoasts(tiles)
	local speed = r8(GPLAYERAVATAR + 0x0B)
	local nextSpeed = speed == 0 and 1 or 3
	return speed >= tiles or nextSpeed + 1 > tiles
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
	out.cause, out.ability = STEP.cause(out)
	return out
end

-- A trainer coming for the player: gNoOfApproachingTrainers goes 0 to 1 the frame after the step into its line begins,
-- gSpecialVar_LastTalked is its local id and gApproachingTrainers' second byte its distance; held input then does
-- nothing. What they read after a battle is not measured, so a reading left from before counts only once it changes.
local NUM_APPROACHING, APPROACHING, LAST_TALKED = 0x030060a8, 0x03006090, 0x020375f2

local function approachWatch()
	local startN, start = r8(NUM_APPROACHING), memory.read_bytes_as_array(APPROACHING, 8, BUS)
	return function()
		if r8(NUM_APPROACHING) == 0 then
			startN = 0
			return nil
		end
		local now = memory.read_bytes_as_array(APPROACHING, 8, BUS)
		if startN ~= 0 then
			local same = true
			for i = 1, 8 do
				if now[i] ~= start[i] then same = false end
			end
			if same then return nil end
		end
		return { local_id = r16(LAST_TALKED), tiles_away = now[2] }
	end
end

-- walk {direction, tiles, run}: held from the first tile to the last, as a player walks. A step begins the frame the
-- coordinates change and finishes if released, so the direction is let go as the last begins. It gives up after
-- IDLE_LIMIT frames with the avatar's +2 at 0 (1 is a turn or a door opening) or PRESS_LIMIT in all, toward a warp
-- DOOR_LIMIT, since a door facing the player opens with every byte at rest. `ran`: 0x80 seen (never without the
-- running shoes). On the Mach Bike it lets go once one more tile would coast past, and walks any still short from rest.
function game.programs.walk(p)
	local d = DIRECTIONS[type(p.direction) == "string" and p.direction:lower() or ""]
	local tiles = math.tointeger(p.tiles)
	if not d then return nil, 'walk needs direction "up", "down", "left" or "right"' end
	if not tiles or tiles < 1 or tiles > 32 then return nil, "walk needs tiles, 1 to 32" end
	if not isVanilla then return nil, "walk is measured on the vanilla ROM only" end

	local run = p.run == true
	local mach = (r8(GPLAYERAVATAR) & MACH_BIKE_FLAG) ~= 0
	local spotted = approachWatch()
	-- B only on foot: on the Acro Bike it is the wheelie button.
	local hold = { [d.button] = true, B = (run and (r8(GPLAYERAVATAR) & ON_FOOT_FLAG) ~= 0) or nil }
	local phase, frames, idle, moved, startMap, lastX, lastY, towardWarp = "rest", 0, 0, 0, nil, 0, 0, false
	local ran = false
	local function here()
		local sb1 = r32(SB1PTR)
		return string.format("%d.%d", r8(sb1 + 4), r8(sb1 + 5)), r16(sb1), r16(sb1 + 2)
	end
	local function warpAhead(x, y)
		for _, w in ipairs(readWarps()) do
			if w.x == x + d.dx and w.y == y + d.dy then return true end
		end
		return false
	end
	local function finish(outcome, extra)
		local r = { direction = p.direction:lower(), requested = tiles, moved = moved, outcome = outcome,
			ran = run and ran or nil }
		for k, v in pairs(extra or {}) do r[k] = v end
		return nil, true, r
	end

	return function()
		frames = frames + 1
		local map, x, y = here()
		startMap = startMap or map
		if map ~= startMap then return finish("map_changed", { map = map }) end
		if not inOverworld() then return finish("left_overworld") end
		local trainer = spotted()
		if trainer then return finish("spotted", { trainer = trainer }) end
		if #hookNames > 0 then
			if dialogue and windowOnScreen(dialogue.window) then return finish("dialogue_open") end
			if menuWindow and windowOnScreen(menuWindow) then return finish("menu_open") end
		end
		if (r8(GPLAYERAVATAR) & 0x80) ~= 0 then ran = true end

		if phase == "rest" then
			if not atRest() then
				if frames > REST_LIMIT then return finish("not_at_rest") end
				return nil, false
			end
			phase, frames, idle, lastX, lastY, towardWarp = "hold", 0, 0, x, y, warpAhead(x, y)
		end

		if phase == "arriving" or phase == "coasting" then
			-- No input: the last step finishes, and on the Mach Bike the ride carries on by itself.
			if x ~= lastX or y ~= lastY then
				moved = moved + math.abs(x - lastX) + math.abs(y - lastY)
				lastX, lastY, frames = x, y, 0
			end
			if atRest() then
				if moved < tiles then
					phase, frames = "rest", 0
					return nil, false
				end
				return finish("done", moved > tiles and { overshot = moved - tiles } or nil)
			end
			if frames > STEP_LIMIT then return finish("not_at_rest") end
			return nil, false
		end

		if phase == "refused" then
			if atRest() then return finish("blocked", { blocked_by = describeTile(x + d.dx, y + d.dy) }) end
			if frames > REST_LIMIT then return finish("not_at_rest") end
			return nil, false
		end

		-- hold: a new step, a bump, or waiting for either.
		if x ~= lastX or y ~= lastY then
			moved = moved + math.abs(x - lastX) + math.abs(y - lastY)
			lastX, lastY, frames, idle = x, y, 0, 0
			if moved >= tiles then
				phase = "arriving"
				return nil, false
			end
			if mach and STEP.machCoasts(tiles - moved) then
				phase = "coasting"
				return nil, false
			end
			towardWarp = warpAhead(x, y)
			return hold, false
		end
		if STEP.refused() then
			phase, frames = "refused", 0
			return nil, false
		end
		if STEP.idle() then idle = idle + 1 end
		if towardWarp then
			if frames > DOOR_LIMIT then return finish("no_response") end
		elseif idle > IDLE_LIMIT or frames > PRESS_LIMIT then
			return finish("no_response")
		end
		return hold, false
	end
end

-- The direction a warp you stand on is entered by, by its behaviour.
local WARP_PRESS = { [0x62] = "right", [0x64] = "up", [0x65] = "down" }

-- Surfed water: 0x15 the sea, 0x10 a pond, 0x12 deep water.
STEP.SURF = { [0x15] = true, [0x10] = true, [0x12] = true }
-- Currents carry the player their way; a waterfall is climbed with WATERFALL from the water below.
STEP.CURRENTS = { [0x50] = "right", [0x51] = "left", [0x52] = "up", [0x53] = "down" }
STEP.WATERFALL = 0x13
-- A cracked floor drops the player onto the same tile of the floor below, which no connection in the header names, so
-- the floors below are listed per map as measured; elsewhere a crack is closed. On the Mach Bike a crack entered at
-- speed 2 or more holds. A crack crossed becomes a hole, which drops the player.
STEP.CRACKED, STEP.HOLE = 0xD2, 0x66
STEP.FALLS = { ["24.82"] = "24.81" }
-- Surfacing where no connection names the map above (an underwater cave): the landing, as measured.
STEP.EMERGE = { ["24.26"] = { to = "24.27", x = 10, y = 17 } }

local function routeGrid(fromX, fromY, toX, toY)
	local layout = r32(GMAPHEADER)
	if not inRom(layout) then return nil, "no map layout" end
	local mapW, mapH = r32(layout), r32(layout + 4)
	local gw, gh, gp = r32(GBACKUPMAPLAYOUT), r32(GBACKUPMAPLAYOUT + 4), r32(GBACKUPMAPLAYOUT + 8)
	if mapW < 1 or mapH < 1 or mapW > 512 or mapH > 512 or gw * gh > 262144 then return nil, "map size out of range" end
	local grid = memory.read_bytes_as_array(gp, gw * gh * 2, BUS)
	-- The player's level, the low nibble of the player object's +0x0B; each step's level is routeHooks.elevationStep's.
	local elevation = r8(playerObject() + 0x0B) & 0x0F
	local blocked, objects = {}, readObjects()
	-- A ROCK SMASH rock (graphics 86) is an obstacle, not a wall, while the party knows ROCK SMASH: the walk stops in
	-- front of it and `smash` breaks it.
	local smashes, surfs = false, false
	for _, mon in ipairs(readParty() or {}) do
		for _, m in ipairs(mon.moves or {}) do
			if m.name == "ROCK SMASH" then smashes = true end
			if m.name == "SURF" then surfs = true end
		end
	end
	-- Surfing (avatar bit 0x08), water is open and reads level 0, so it and the step onto land pass the level rule; on
	-- land with SURF known, water is an obstacle `clear_obstacle` answers.
	local surfing = (r8(GPLAYERAVATAR) & 0x08) ~= 0
	for _, o in ipairs(objects) do
		blocked[o.y * mapW + o.x] = (smashes and o.graphics_id == 86) and "smash" or "character"
	end
	local trainers = unbeatenTrainers(objects)
	for _, t in ipairs(trainers) do
		if not t.loaded then blocked[t.y * mapW + t.x] = blocked[t.y * mapW + t.x] or "trainer" end
	end
	local seen, timed = sightTiles(trainers, mapW, mapH)
	for _, w in ipairs(readWarps()) do
		if not (w.x == toX and w.y == toY) then blocked[w.y * mapW + w.x] = blocked[w.y * mapW + w.x] or "warp" end

	end
	return {
		width = mapW, height = mapH, where = "from elevation " .. elevation, elevation = elevation,
		elevationAt = function(x, y)
			local i = ((x + MAP_OFFSET) + gw * (y + MAP_OFFSET)) * 2 + 1
			local v = grid[i] | (grid[i + 1] << 8)
			-- Water is entered only from level 3: facing water from level 4, A gave no SURF question.
			if (surfs or surfing) and STEP.SURF[behaviourOf(v & 0x3FF)] and (v >> 12) == 1 then return surfing and 0 or 3 end
			return v >> 12
		end,
		tile = function(x, y)
			if blocked[y * mapW + x] == "smash" then return true, false, nil, nil, "smash" end
			if blocked[y * mapW + x] then return nil end
			local i = ((x + MAP_OFFSET) + gw * (y + MAP_OFFSET)) * 2 + 1
			local v = grid[i] | (grid[i + 1] << 8)
			local behaviour = behaviourOf(v & 0x3FF)
			-- Water at elevation 1 is not walked onto.
			if STEP.SURF[behaviour] and (v >> 12) == 1 then
				if surfing then return true, false, seen[y * mapW + x], nil, nil, timed[y * mapW + x] end
				if surfs then return true, false, seen[y * mapW + x], nil, "surf", timed[y * mapW + x] end
				return nil
			end
			-- A mud slope (0xD0) slides the player back on foot, and down one is not measured: closed. A current or a
			-- waterfall is not walked or surfed as a tile: `goto` takes it as an action of the room's plan.
			if behaviour == 0xD0 or STEP.CURRENTS[behaviour] or behaviour == STEP.WATERFALL then return nil end
			-- A cracked floor drops the player: stepped onto only as the target, to fall on purpose.
			if (behaviour == STEP.CRACKED or behaviour == STEP.HOLE) and not (x == toX and y == toY) then return nil end
			-- A ledge reads collision set and is hopped its one way: two steps, onto it and past it.
			if STEP.LEDGES[behaviour] then return true, false, seen[y * mapW + x], STEP.LEDGES[behaviour], nil, timed[y * mapW + x] end
			if (v & 0x0C00) ~= 0 then return nil end
			return true, behaviour == 0x02, seen[y * mapW + x], nil, nil, timed[y * mapW + x]
		end,
	}
end

local routeHooks = {
	position = function()
		local sb1 = r32(SB1PTR)
		return string.format("%d.%d", r8(sb1 + 4), r8(sb1 + 5)), r16(sb1), r16(sb1 + 2)
	end,
	inOverworld = inOverworld,
	watch = function()
		local spotted = approachWatch()
		return function()
			local trainer = spotted()
			if trainer then return "spotted", { trainer = trainer } end
			if #hookNames > 0 then
				if dialogue and windowOnScreen(dialogue.window) then return "dialogue_open" end
				if menuWindow and windowOnScreen(menuWindow) then return "menu_open" end
			end
			return nil
		end
	end,
	atRest = atRest,
	-- The way a loaded trainer faces now, from its object slot's +0x18 low nibble (3 read left).
	turnFacing = function(slot)
		return ({ [1] = "down", [2] = "up", [3] = "left", [4] = "right" })[r8(GOBJECTEVENTS + slot * OBJ_SIZE + 0x18) & 0x0F]
	end,
	refused = STEP.refused,
	idle = STEP.idle,
	ride = function(run)
		local flags = r8(GPLAYERAVATAR)
		local mach, onFoot = (flags & MACH_BIKE_FLAG) ~= 0, (flags & ON_FOOT_FLAG) ~= 0
		-- B only on foot: on the Acro Bike it is the wheelie button. A run on foot mounts the MACH BIKE (259) first
		-- where it is registered (SaveBlock1 +0x496) and bit 0 of the map header's +0x1A allows a bike.
		local mount = run and onFoot and r16(r32(SB1PTR) + 0x496) == 259 and (r8(0x02037318 + 0x1A) & 1) == 1
		-- Long grass (0x03) refuses a bike: a map holding any is walked, no mount, and off the bike first.
		local layout = r32(GMAPHEADER)
		if STEP.longGrassLayout ~= layout then
			STEP.longGrassLayout, STEP.longGrass = layout, false
			local gw, gh, gp = r32(GBACKUPMAPLAYOUT), r32(GBACKUPMAPLAYOUT + 4), r32(GBACKUPMAPLAYOUT + 8)
			if gw * gh <= 262144 then
				local grid = memory.read_bytes_as_array(gp, gw * gh * 2, BUS)
				for i = 1, gw * gh * 2, 2 do
					if behaviourOf((grid[i] | (grid[i + 1] << 8)) & 0x3FF) == 0x03 then
						STEP.longGrass = true
						break
					end
				end
			end
		end
		if STEP.longGrass then mount = mach end
		-- shortLeg: after a turn at speed the Mach Bike's first tile coasts three.
		return { buttons = { B = (run and onFoot) or nil }, coast = mach and STEP.machCoasts or nil, shortLeg = mach and 3 or nil,
			mount = mount and "Select" or nil }
	end,
	routeGrid = routeGrid,
	warps = readWarps,
	-- Stairs warp on the step onto them; a door mat or the truck's door only on a press while standing on it, and a
	-- town door (0x69) is walked up into from the tile below. A warp entered by a press is stepped onto from rest (a
	-- held walk bumped at the truck's door), so the ride lets go one tile short and takes the last step alone.
	enterWarp = function(w)
		if w.behaviour == 0x69 then return { dy = 1, press = "up" } end
		if WARP_PRESS[w.behaviour] then return { press = WARP_PRESS[w.behaviour], fromRest = true } end
		return nil
	end,
	blockedBy = describeTile,
	limits = { rest = REST_LIMIT, idle = IDLE_LIMIT, press = PRESS_LIMIT, door = DOOR_LIMIT, step = STEP_LIMIT },
	-- Any map from the ROM: gMapGroups (0x08486578) is a pointer per group to a pointer per map to its header, the same
	-- 28 bytes as gMapHeader's copy; its layout (+0) holds width, height and at +0x0C the map data, and the header's
	-- +0x0C the connections. A map is taken only when its pointers lead into the ROM and its size is 1-512.
	maps = {},
	mapHeader = function(name)
		local g, n = string.match(name or "", "^(%d+)%.(%d+)$")
		g, n = tonumber(g), tonumber(n)
		if not g or g > 255 or n > 255 then return nil end
		local groupList = r32(0x08486578 + g * 4)
		if not inRom(groupList) then return nil end
		local hdr = r32(groupList + n * 4)
		if not inRom(hdr) or not inRom(r32(hdr)) or not inRom(r32(hdr + 4)) then return nil end
		local layout = r32(hdr)
		local w, h = r32(layout), r32(layout + 4)
		if w < 1 or h < 1 or w > 512 or h > 512 or not inRom(r32(layout + 12)) then return nil end
		return hdr, layout, w, h
	end,
}
routeHooks.connectionDirections = { [1] = "down", [2] = "up", [3] = "left", [4] = "right" }
-- A script holding the player, as textHooks.scriptRunning reads it: a planned step then turns into a refusal.
routeHooks.busy = function() return r8(SCRIPT_CONTEXT_STATUS) ~= SCRIPT_CONTEXT_OFF and r8(0x03000f2c) ~= 0 end
-- Field controls locked with no script, as on the landing after a fall through a crack: a trip waits it out.
routeHooks.locked = function() return r8(0x03000f2c) ~= 0 end
-- For `exec`: the planner's hooks, to read any map as `goto` sees it, and the planner itself (M.solve on any room).
game.routeHooks = routeHooks
game.routeLib = lib.route
routeHooks.mapExits = function(name)
	if routeHooks.maps[name] ~= nil then return routeHooks.maps[name] or nil end
	local hdr, _, w, h = routeHooks.mapHeader(name)
	if not hdr then
		routeHooks.maps[name] = false
		return nil
	end
	local exits = {}
	local conns = r32(hdr + 12)
	if inRom(conns) then
		local list = r32(conns + 4)
		for i = 0, math.min(r32(conns), 16) - 1 do
			local e = list + i * 12
			local dir = routeHooks.connectionDirections[r8(e)]
			if dir and inRom(list) then
				local to = string.format("%d.%d", r8(e + 8), r8(e + 9))
				exits[#exits + 1] = { kind = "edge", direction = dir, offset = memory.read_s32_le(e + 4, BUS), to = to,
					key = "edge " .. dir .. " to " .. to }
			end
			-- Connection kind 5 is the map below (a dive, to the same tile), 6 the one above; a dive is planned from
			-- deep water onto an open tile below, and surfacing onto deep water above (measured at one tile).
			local deep = ({ [5] = "dive", [6] = "emerge" })[r8(e)]
			if deep and inRom(list) then
				local to = string.format("%d.%d", r8(e + 8), r8(e + 9))
				exits[#exits + 1] = { kind = deep, to = to, key = deep .. " to " .. to }
			end
		end
	end
	-- A warp's +5 is the destination's warp number, from 0.
	local events, warps = r32(hdr + 4), {}
	local list = r32(events + 8)
	for i = 0, math.min(r8(events + 1), 64) - 1 do
		if not inRom(list) then break end
		local e = list + i * 8
		local x, y, to = r16(e), r16(e + 2), string.format("%d.%d", r8(e + 7), r8(e + 6))
		local _, _, behaviour = routeHooks.mapTileRaw(name, x, y)
		warps[#warps + 1] = { kind = "warp", x = x, y = y, to = to, to_warp = r8(e + 5), behaviour = behaviour,
			key = string.format("warp (%d,%d) to %s", x, y, to) }
		exits[#exits + 1] = warps[#warps]
	end
	if STEP.EMERGE[name] then
		local e = STEP.EMERGE[name]
		exits[#exits + 1] = { kind = "emerge", to = e.to, arrive = { x = e.x, y = e.y }, key = "emerge to " .. e.to }
	end
	for _, f in ipairs(routeHooks.falls(name)) do exits[#exits + 1] = f end
	routeHooks.maps[name] = { width = w, height = h, exits = exits, warps = warps }
	return routeHooks.maps[name]
end
-- Any map's tile from the ROM, through that layout's own tilesets: collision, elevation and behaviour. The map the
-- player stands on is read from the live grid instead, since a script changes its tiles (a gym's switched barriers).
routeHooks.mapTileRaw = function(name, x, y)
	local _, layout, w, h = routeHooks.mapHeader(name)
	if not layout or x < 0 or y < 0 or x >= w or y >= h then return nil end
	if routeHooks.liveFrame ~= emu.framecount() then
		routeHooks.liveFrame, routeHooks.liveMap = emu.framecount(), (routeHooks.position())
	end
	local v
	if name == routeHooks.liveMap and r32(GMAPHEADER) == layout then
		local gw = r32(GBACKUPMAPLAYOUT)
		v = r16(r32(GBACKUPMAPLAYOUT + 8) + ((x + MAP_OFFSET) + gw * (y + MAP_OFFSET)) * 2)
	else
		v = r16(r32(layout + 12) + (x + w * y) * 2)
	end
	local id, k = v & 0x3FF, 0
	if id >= 512 then id, k = id - 512, 1 end
	local ts = r32(layout + 0x10 + k * 4)
	local attrs = inRom(ts) and r32(ts + 0x10) or 0
	return (v >> 10) & 3, v >> 12, inRom(attrs) and (r16(attrs + id * 2) & 0xFF) or -1
end
-- Levels: the 0 rules were walked; the rest is IsElevationMismatchAt and ObjectEventUpdateElevation read as the map.
routeHooks.elevationStep = function(level, tileLevel, fromLevel)
	if not tileLevel then return nil end
	if level ~= 0 and tileLevel ~= 0 and tileLevel ~= 15 and tileLevel ~= level then return nil end
	if tileLevel == 15 or fromLevel == 15 then return level end
	return tileLevel
end
routeHooks.playerElevation = function() return r8(playerObject() + 0x0B) & 0x0F end
routeHooks.deepWater = function(name, x, y)
	local c, e, b = routeHooks.mapTileRaw(name, x, y)
	return c == 0 and e == 1 and b == 0x12
end
-- Where surfacing to a measured landing (STEP.EMERGE) is tried: the cave's floor of behaviour 0x12.
routeHooks.surfaceSpot = function(name, x, y)
	local c, _, b = routeHooks.mapTileRaw(name, x, y)
	return c == 0 and b == 0x12
end
routeHooks.falls = function(name)
	local below, out = STEP.FALLS[name], {}
	if not below then return out end
	local _, _, w, h = routeHooks.mapHeader(name)
	for y = 0, (h or 0) - 1 do
		for x = 0, w - 1 do
			local c, _, b = routeHooks.mapTileRaw(name, x, y)
			if c == 0 and (b == STEP.CRACKED or b == STEP.HOLE) then
				out[#out + 1] = { kind = "fall", x = x, y = y, to = below, key = string.format("fall (%d,%d) to %s", x, y, below),
					crack = b == STEP.CRACKED }
			end
		end
	end
	return out
end
routeHooks.mapTile = function(name, x, y)
	local collision, elevation, behaviour = routeHooks.mapTileRaw(name, x, y)
	if not collision then return nil end
	if STEP.LEDGES[behaviour] then return elevation, STEP.LEDGES[behaviour] end
	if collision == 0 and elevation == 1 and STEP.SURF[behaviour] and routeHooks.surfs then return 0 end
	-- Currents and a waterfall: open to this plan, which is the optimistic one; the room's plan decides.
	if collision == 0 and (STEP.CURRENTS[behaviour] or behaviour == STEP.WATERFALL) and routeHooks.surfs then return 0 end
	if collision ~= 0 or (elevation == 1 and STEP.SURF[behaviour]) or behaviour == 0xD0 or STEP.CURRENTS[behaviour]
		or behaviour == STEP.WATERFALL then return nil end
	return elevation
end

-- The room for the obstacle plan (route.lua), the one stood on from the live grid and characters. A boulder is graphics
-- 87, a ROCK SMASH rock 86, any other character solid. Another map's come from templates (graphics +1, flag +0x14):
-- one whose flag is set is not there, and a flag below 0x20 (every boulder's and rock's) is cleared on entry. STRENGTH
-- in use is flag 0x889, lost on every room change.
routeHooks.room = function(name)
	local ex, hdr = routeHooks.mapExits(name), routeHooks.mapHeader(name)
	if not ex or not hdr then return nil end
	local W, H = ex.width, ex.height
	local here, px, py = routeHooks.position()
	local live = name == here
	local warpAt, tiles = {}, {}
	for _, w in ipairs(ex.warps) do warpAt[w.y * W + w.x] = true end
	-- Cracks and holes are exits (a fall); a crack is crossed on the MACH BIKE at speed (room.crack, room.bike).
	local cracks, anyCrack = {}, false
	for _, f in ipairs(routeHooks.falls(name)) do
		warpAt[f.y * W + f.x] = true
		cracks[f.y * W + f.x] = f.crack and "crack" or "hole"
		anyCrack = anyCrack or f.crack
	end
	local function cell(x, y)
		local key = y * W + x
		local t = tiles[key]
		if t == nil then
			local c, e, b = routeHooks.mapTileRaw(name, x, y)
			t = false
			if c and STEP.LEDGES[b] then t = { "ledge", e, STEP.LEDGES[b] }
			elseif c == 0 and e == 1 and STEP.SURF[b] then t = { "water", 0 }
			elseif c == 0 and STEP.CURRENTS[b] then t = { "current", 0, STEP.CURRENTS[b] }
			elseif c == 0 and b == STEP.WATERFALL then t = { "waterfall", 0 }
			elseif c == 0 and (b == STEP.CRACKED or b == STEP.HOLE) and not STEP.FALLS[name] then t = false
			elseif c == 0 and b ~= 0xD0 then t = { "land", e, nil, b == 0x02 } end
			tiles[key] = t
		end
		if not t then return nil end
		return t[1], t[2], t[3], t[4]
	end
	local sb1, objects, can = r32(SB1PTR), {}, {}
	local kinds = { [87] = "boulder", [86] = "rock" }
	local sight, loaded = nil, {}
	if live then
		-- The room stood in: a loaded character where it stands now (a pushed boulder included), the rest as below with
		-- their flags as they are (a broken rock's is set). Only characters near the screen are loaded.
		local objs = readObjects()
		for _, o in ipairs(objs) do
			loaded[o.local_id] = true
			objects[#objects + 1] = { x = o.x, y = o.y, kind = kinds[o.graphics_id] or "solid" }
		end
		local seen, timed = sightTiles(unbeatenTrainers(objs), W, H)
		sight = function(x, y) return seen[y * W + x], timed[y * W + x] ~= nil end
	end
	local events = r32(hdr + 4)
	local list = r32(events + 4)
	for i = 0, math.min(r8(events), 64) - 1 do
		if not inRom(list) then break end
		local e = list + i * 24
		local flag = r16(e + 0x14)
		local hidden = flag ~= 0 and flag <= FLAG_MAX and (live or flag >= 0x20) and flagGet(sb1, flag)
		if not loaded[r8(e)] and not hidden then
			objects[#objects + 1] = { x = r16(e + 4), y = r16(e + 6), kind = kinds[r8(e + 1)] or "solid" }
		end
	end
	for _, mon in ipairs(readParty() or {}) do
		for _, m in ipairs(mon.moves or {}) do
			if m.name == "SURF" then can.surf = true end
			if m.name == "STRENGTH" then can.strength = true end
			if m.name == "ROCK SMASH" then can.smash = true end
			if m.name == "WATERFALL" then can.waterfall = true end
		end
	end
	local surfing = (r8(GPLAYERAVATAR) & 0x08) ~= 0
	-- The MACH BIKE rides here when it is registered and the header's +0x1A bit 0 allows a bike.
	local bike = anyCrack and r16(sb1 + 0x496) == 259 and (r8(hdr + 0x1A) & 1) == 1
	return { width = W, height = H, cell = cell, objects = objects, can = can, sight = sight, bike = bike,
		crack = function(x, y) return cracks[y * W + x] end,
		warp = function(x, y) return warpAt[y * W + x] == true end,
		start = live and { x = px, y = py, surf = surfing, level = surfing and 0 or routeHooks.playerElevation(),
			strength = flagGet(sb1, 0x889) } or nil }
end

-- clear_obstacle {}: the ROCK SMASH rock or the water beside the player (where a goto answered `obstacle`) faced, A,
-- and its text to the YES/NO; `select` YES and `advance_text` then clear it.
game.programs.clear_obstacle = function()
	local _, x, y = routeHooks.position()
	for _, o in ipairs(readObjects()) do
		if o.graphics_id == 86 and math.abs(o.x - x) + math.abs(o.y - y) == 1 then
			return game.programs.talk({ local_id = o.local_id })
		end
	end
	local dirs = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
	local order = { routeHooks.facing(), "up", "down", "left", "right" }
	for _, name in ipairs(order) do
		local d = dirs[name]
		local c, e, b = routeHooks.mapTileRaw((routeHooks.position()), x + d[1], y + d[2])
		if c == 0 and e == 1 and STEP.SURF[b] then
			local frames, advance, tapped = 0, nil, nil
			return function()
				frames = frames + 1
				if advance then return advance() end
				if routeHooks.facing() ~= name then
					if frames > 60 then return nil, true, nil, "could not face the water " .. name end
					return { [({ up = "Up", down = "Down", left = "Left", right = "Right" })[name]] = true }, false
				end
				if not tapped then
					tapped = frames
					return { A = true }, false
				end
				if frames - tapped < 4 then return { A = true }, false end
				if frames - tapped < 10 then return nil, false end
				advance = game.programs.advance_text()
				return nil, false
			end, nil, 3600
		end
	end
	return nil, "no ROCK SMASH rock (graphics 86) or water to SURF beside the player"
end

-- The rotating gates' orientations, SaveBlock1 +0x139C (vars from VAR_TEMP_0): the search's puzzle key.
routeHooks.puzzleKey = function()
	local b = memory.read_bytes_as_array(r32(SB1PTR) + 0x139C, 8, BUS)
	return table.concat(b, ",")
end
-- search {x, y}: a way found by trying steps in the game (route.lua).
game.programs.search = function(p) return lib.route.search(routeHooks, p) end

-- goto {x, y, map, run, cross_grass}: to a tile on this map, or on `map`, by a planned route (route.lua).
game.programs["goto"] = function(p)
	if not isVanilla then return nil, "goto is measured on the vanilla ROM only" end
	-- The plan across maps opens water where SURF is known.
	routeHooks.surfs = (r8(GPLAYERAVATAR) & 0x08) ~= 0
	for _, mon in ipairs(readParty() or {}) do
		for _, m in ipairs(mon.moves or {}) do if m.name == "SURF" then routeHooks.surfs = true end end
	end
	-- With `map`, even this one: a part of this map behind a warp pad is planned as across maps.
	if p.map ~= nil then return lib.route.travel(routeHooks, p) end
	-- On this map by the room's plan, which clears boulders, rocks, water and currents on the way.
	return lib.route.reach(routeHooks, p)
end

local function progressSignature()
	local d = (#hookNames > 0) and readDialogue() or nil
	-- The printer's pointer moves with every character, so a box still printing is progress; the player's coordinates
	-- too, since a cutscene walks the player between its messages.
	local sb1 = r32(SB1PTR)
	local parts = { r32(GMAIN_CB2), battleAsking() or "-", d and d.state or "-", d and d.box or "-",
		d and r32(STEXTPRINTERS + d.window * PRINTER_SIZE) or "-", r8(ACTION_CURSOR), r8(MOVE_CURSOR),
		inEwram(sb1) and r16(sb1) or "-", inEwram(sb1) and r16(sb1 + 2) or "-" }
	if inBattle() then
		for i = 0, math.min(r8(BATTLERS_COUNT), 4) - 1 do parts[#parts + 1] = r16(BATTLE_MONS + i * BATTLE_MON_SIZE + 0x28) end
		-- The battle's script moving on, and the level-up box's own state, are progress too: an A that turned the box's
		-- page changed nothing else.
		parts[#parts + 1] = r32(BATTLESCRIPT_INSTR)
		parts[#parts + 1] = r8(LEVEL_UP_BOX_STATE)
	end
	return table.concat(parts, "|"), d
end

local function strongestMoveSlot()
	local b = memory.read_bytes_as_array(BATTLE_MONS, BATTLE_MON_SIZE, BUS)
	local best, bestScore
	for k = 0, 3 do
		local id, pp = u16of(b, 13 + k * 2), b[37 + k]
		if id ~= 0 and pp > 0 then
			local info = moveInfo(id)
			local score = (info.power or 0) * (info.accuracy or 0)
			if best == nil or score > bestScore then best, bestScore = k, score end
		end
	end
	return best
end

-- battle policy "effective": the usable move with the most power times accuracy times the type multiplier against the
-- foe times the same-type bonus, as Cmd_typecalc weighs the damage; the first with PP when none scores above 0. Returns
-- the slot, the move's name, and what each usable move weighed, for the battle's log.
function TYPE_CHART.effectiveMove()
	local mons = memory.read_bytes_as_array(BATTLE_MONS, BATTLE_MON_SIZE * 4, BUS)
	local positions = memory.read_bytes_as_array(BATTLER_POSITIONS, 4, BUS)
	-- The asking battler's moves weighed against each foe standing (positions 1 and 3); the best pair wins and its foe
	-- is the aim `battle` takes at the target step. A move that also hits the partner (target byte 0x20) scores 0 while
	-- the partner stands.
	local _, meBattler = battleAsking()
	meBattler = meBattler or 0
	local me = meBattler * BATTLE_MON_SIZE
	local count = math.min(r8(BATTLERS_COUNT), 4)
	local foes, partnerUp = {}, false
	for i = 0, count - 1 do
		local hp = u16of(mons, i * BATTLE_MON_SIZE + 0x29)
		if positions[i + 1] % 2 == 1 and (hp > 0 or #foes == 0) then foes[#foes + 1] = i end
		if positions[i + 1] % 2 == 0 and i ~= meBattler and hp > 0 then partnerUp = true end
	end
	if #foes == 0 then return nil, "no battler at the opponent's position" end
	-- A foe at 0 HP is kept only when it is the only one read (a single battle's foe between turns).
	if #foes > 1 then
		local up = {}
		for _, i in ipairs(foes) do if u16of(mons, i * BATTLE_MON_SIZE + 0x29) > 0 then up[#up + 1] = i end end
		if #up > 0 then foes = up end
	end
	local own1, own2 = mons[me + 0x22], mons[me + 0x23]
	-- A move the foe resists (multiplier below 1) is chosen only when no unresisted move scores above 0.
	local best, bestScore, bestResisted, bestFoe, weighed, against, guard = nil, nil, true, nil, {}, nil, nil
	for _, fi in ipairs(foes) do
		local foe = fi * BATTLE_MON_SIZE
		local foe1, foe2 = mons[foe + 0x22], mons[foe + 0x23]
		-- Against WONDER GUARD only super effective moves score (not met in a battle yet).
		local foeAbility = nameAt(0x0831b6db, 13, 256, mons[foe + 0x21])
		local wonderGuard = foeAbility == "WONDER GUARD"
		for k = 0, 3 do
			local id, pp = u16of(mons, me + 13 + k * 2), mons[me + 37 + k]
			if id ~= 0 and pp > 0 then
				local info = moveInfo(id)
				local same = info.type_id == own1 or info.type_id == own2
				local multiplier = info.type_id and TYPE_CHART.multiplier(info.type_id, foe1, foe2) or 1
				-- Against LEVITATE a GROUND move misses: taken as doing nothing.
				if foeAbility == "LEVITATE" and info.type == "GROUND" then multiplier = 0 end
				-- A damaging move whose accuracy byte reads 0 never misses: taken as 100.
				local acc = info.accuracy or 0
				if acc == 0 and (info.power or 0) > 1 then acc = 100 end
				local score = (info.power or 0) * acc * (same and TYPE_CHART.sameTypeBonus or 1) * multiplier
				if wonderGuard and multiplier <= 1 then score = 0 end
				if partnerUp and info.target == 0x20 then score = 0 end
				-- A move with recoil (effect 48 or 198) scores a quarter below 40% HP.
				if (info.effect == 48 or info.effect == 198) and u16of(mons, me + 0x29) < 0.4 * u16of(mons, me + 0x2D) then
					score = score / 4
				end
				-- A move that faints its own user (effect 7: SELFDESTRUCT, EXPLOSION) scores 0, a last resort.
				if info.effect == 7 then score = 0 end
				weighed[#weighed + 1] = { move = nameAt(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, id), type = info.type, power = info.power,
					accuracy = info.accuracy, same_type = same or nil, multiplier = multiplier, score = score,
					foe = #foes > 1 and fi or nil }
				local resisted = multiplier < 1 or score <= 0
				if best == nil or (bestResisted and not resisted) or (resisted == bestResisted and score > bestScore) then
					best, bestScore, bestResisted, bestFoe = k, score, resisted, fi
					against = { TYPE_CHART.name(foe1) }
					if foe2 ~= foe1 then against[2] = TYPE_CHART.name(foe2) end
					guard = wonderGuard or nil
				end
			end
		end
	end
	if best == nil then return nil, "no move has PP left" end
	BATTLE_BUSY.aim = bestFoe
	return best, nameAt(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, u16of(mons, me + 13 + best * 2)),
		{ weighed = weighed, against = against, wonder_guard = guard, aim = #foes > 1 and bestFoe or nil }
end

local textHooks = {
	-- The text hook copies each string when it starts printing, so a box is whole from its first letter.
	boxKnownWhilePrinting = true,
	signature = progressSignature,
	readDialogue = readDialogue,
	inBattle = inBattle,
	battleMenu = function()
		local asking, battler = battleAsking()
		if not asking then return nil end
		if asking == "target" then return asking, { cursor = r8(0x03005d74), battler = battler } end
		return asking, { cursor = r8((asking == "action" and ACTION_CURSOR or MOVE_CURSOR) + battler), columns = 2, battler = battler }
	end,
	-- The foe the last effectiveMove weighed best, for the target step.
	effectiveTarget = function() return BATTLE_BUSY.aim end,
	scriptRunning = function() return r8(SCRIPT_CONTEXT_STATUS) ~= SCRIPT_CONTEXT_OFF and r8(0x03000f2c) ~= 0 end,
	inOverworld = inOverworld,
	-- Menus with no window too, so advance_text and `battle` stop menu_open on them for select: a Mart's quantity box,
	-- the bag's list (only with no message up), the starter bag and the party list.
	readMenu = function()
		return readMenu() or (isVanilla and (LEARN.quantity() or (not readDialogue() and readListMenu()) or STARTER.menu()
			or LEARN.partyMenu.read())) or nil
	end,
	actionIndex = { fight = 0, run = 3 },
	levelUpPage = function()
		local at = r8(LEVEL_UP_BOX_STATE)
		return LEVEL_UP_BOX_WAITING[at], at
	end,
	animationPlaying = BATTLE_BUSY.playing,
	battleQuestion = LEARN.question,
	-- Battler 0 is the player's in every single battle measured.
	ownHp = function() return r16(BATTLE_MONS + 0x28), r16(BATTLE_MONS + 0x2C) end,
	scenePlaying = function() return LEARN.evolution() ~= nil end,
	readKeyboard = readKeyboard,
	readClock = readClock,
	strongestMove = function()
		local slot = strongestMoveSlot()
		if slot == nil then return nil, "no move has PP left" end
		local id = r16(BATTLE_MONS + 0x0C + slot * 2)
		return slot, nameAt(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, id) or ("move " .. id)
	end,
	effectiveMove = TYPE_CHART.effectiveMove,
	battleKind = function() return (r32(BATTLE_TYPE_FLAGS) & 0x08) ~= 0 and "trainer" or "wild" end,
	-- Type flag 0x200 (WALLY's catching battle): the game answers its own menus there.
	gameAnswers = function() return (r32(BATTLE_TYPE_FLAGS) & 0x200) ~= 0 and not inOverworld() end,
	endedReport = function()
		local save = readSave()
		return { outcome_raw = r8(BATTLE_OUTCOME), money = save and save.money,
			party = save and save.party and (function()
				local out = {}
				for _, m in ipairs(save.party) do out[#out + 1] = { species = m.species, level = m.level, hp = m.hp, max_hp = m.max_hp } end
				return out
			end)() }
	end,
}

game.programs.battle = function(p)
	if not isVanilla then return nil, "battle is measured on the vanilla ROM only" end
	if #hookNames == 0 then return nil, "battle reads messages through the text hooks, which are off (AUTOPLAY_TEXT=0)" end
	return lib.text.battle(textHooks, p)
end

game.programs.advance_text = function()
	if not isVanilla then return nil, "advance_text is measured on the vanilla ROM only" end
	if #hookNames == 0 then return nil, "advance_text reads messages through the text hooks, which are off (AUTOPLAY_TEXT=0)" end
	return lib.text.advanceText(textHooks)
end

-- talk {local_id} (route.lua's M.talk): a character not loaded yet comes from its template, as unbeaten trainers do,
-- and on arrival the loaded one is read again. A template's hide flag is not read here.
routeHooks.characters = function()
	local out, seen = readObjects(), {}
	for _, o in ipairs(out) do seen[o.local_id] = true end
	for _, t in ipairs(readTemplates()) do
		if not seen[t.local_id] then out[#out + 1] = { local_id = t.local_id, x = t.x, y = t.y, template = true } end
	end
	return out
end
routeHooks.facing = function()
	return ({ "down", "up", "left", "right" })[r8(playerObject() + 0x18) & 0x0F]
end
-- A Center's counter (behaviour 0x80) is talked across.
routeHooks.talkAcross = function(x, y)
	local t = describeTile(x, y)
	return t.behaviour == 0x80
end
routeHooks.talkStarted = function()
	return textHooks.scriptRunning() or readDialogue() ~= nil
end
game.programs.talk = function(p)
	if not isVanilla then return nil, "talk is measured on the vanilla ROM only" end
	if #hookNames == 0 then return nil, "talk reads messages through the text hooks, which are off (AUTOPLAY_TEXT=0)" end
	return lib.route.talk(routeHooks, p, function() return lib.text.advanceText(textHooks) end)
end

-- The field errands live in their own function: the module's main chunk is at Lua's 200-local limit.
game.programs.reflex = (function()
-- A field errand is a chain of small programs (a tap, a wait on the game's state, `select`, advance_text), each run to
-- its end; the first error ends it, and a factory may return nil for nothing to do.
local function chain(steps, finish)
	local i, cur, log = 1, nil, {}
	return function()
		for _ = 1, 8 do
			if not cur then
				local s = steps[i]
				if not s then return nil, true, finish and finish(log) or { log = log } end
				local prog, err = s(log)
				if err then return nil, true, nil, string.format("step %d: %s", i, err) end
				if not prog then i = i + 1 else cur = prog end
			end
			if cur then
				local pad, done, res, err = cur()
				if err then return nil, true, nil, string.format("step %d: %s", i, err) end
				if not done then return pad, false end
				if res ~= nil then log[#log + 1] = res end
				cur, i = nil, i + 1
				return pad, false
			end
		end
		return nil, false
	end
end
local function tap(button)
	return function()
		local n = 0
		return function()
			n = n + 1
			if n <= 3 then return { [button] = true }, false end
			return nil, n >= 9
		end
	end
end
local function waitFor(pred, limit, what)
	return function()
		local n = 0
		return function()
			n = n + 1
			if pred() then return nil, true end
			if n > limit then return nil, true, nil, "waited " .. limit .. " frames for " .. what end
			return nil, false
		end
	end
end
local function menuHas(item)
	return function()
		local m = game.menu()
		if type(m) ~= "table" or type(m.items) ~= "table" then return false end
		for _, it in ipairs(m.items) do if it == item then return true end end
		return false
	end
end
local function choose(item)
	return function() return lib.select({ item = item }) end
end
-- The overworld with no script, message or menu: what every errand ends on.
local function fieldClear()
	return inOverworld() and r8(SCRIPT_CONTEXT_STATUS) == SCRIPT_CONTEXT_OFF and readDialogue() == nil and game.menu() == nil
end
local function closeAll()
	return function()
		local n = 0
		return function()
			n = n + 1
			if fieldClear() then return nil, true end
			if n > 400 then return nil, true, nil, "the field did not clear after B for 400 frames" end
			if n % 12 < 3 then return { B = true }, false end
			return nil, false
		end
	end
end
local function sb1Key() return r32(SB1PTR), r32(r32(SB2PTR) + 0xAC) end

-- A menu of `kind` walked to entry `target` by taps 12 frames apart, then A: a held Down runs past in the field party
-- list and is not taken on the summary's move list.
local function tapTo(kind, target)
	local k, tapped = 0, false
	return function()
		k = k + 1
		local pm = game.menu()
		if not pm or pm.kind ~= kind then return nil, true end
		if k > 600 then return nil, true, nil, string.format("the %s cursor did not reach %d", kind, target) end
		if k % 12 >= 3 then return nil, false end
		if pm.cursor == target then
			if tapped and k % 48 >= 3 then return nil, false end
			tapped = true
			return { A = true }, false
		end
		return { [pm.cursor < target and "Down" or "Up"] = true }, false
	end
end

-- use_item {item, on, forget}: START, BAG, the item's pocket by Right, the item, USE, the Pokémon `on` (a nickname or a
-- 0-based slot) and the messages, from and back to a clear field. Reports the repel counter, SaveBlock1 +0x13DE.
local function useItem(p)
	if not isVanilla then return nil, "use_item is measured on the vanilla ROM only" end
	local want = tostring(p.item or "")
	local sb1, key = sb1Key()
	-- The pocket and the item's place in it, chosen by place since TM and HM entries print with formatting codes. The
	-- TMs & HMs pocket is shown sorted by item id, not in its stored order.
	local pocket, place
	for idx, pk in ipairs(POCKETS) do
		local list = readBag(sb1, key)[pk.name] or {}
		if pk.name == "tms_hms" then
			local sorted = {}
			for _, it in ipairs(list) do sorted[#sorted + 1] = it end
			table.sort(sorted, function(a, b) return a.id < b.id end)
			list = sorted
		end
		for i, it in ipairs(list) do
			if it.item == want then pocket, place = idx - 1, i - 1 end
		end
	end
	if not pocket then return nil, "the bag holds no " .. want end
	local target = p.on
	if type(target) == "string" then
		for i, mon in ipairs(readParty() or {}) do if mon.nickname == target then target = i - 1 end end
		if type(target) == "string" then return nil, "no Pokémon in the party is named " .. p.on end
	end
	local steps = {
		closeAll(), tap("Start"), waitFor(menuHas("BAG"), 60, "the START menu"), choose("BAG"),
		waitFor(function() local m = game.menu(); return m and m.list and m.pocket end, 120, "the bag's list"),
		function()
			local n = 0
			return function()
				n = n + 1
				local m = game.menu()
				if r8(BAG_POSITION + 5) == pocket and m and m.list and #m.items > place then return nil, true end
				if n > 300 then return nil, true, nil, "the pocket did not come round" end
				if n % 20 < 3 then return { Right = true }, false end
				return nil, false
			end
		end,
		-- A pocket just turned to takes no Up or Down while it slides in: 30 frames first.
		function() local n = 0; return function() n = n + 1; return nil, n >= 30 end end,
		function() return lib.select({ index = place }) end, waitFor(menuHas("USE"), 60, "USE"), choose("USE"),
		-- What the item asks, until the bag's list is back or the field is clear: the party list (`on`), a YES/NO
		-- (YES), a TM's learn-a-move questions (`forget` names the move to give up; without it NO), every message.
		function()
			local n, sub, quiet = 0, nil, 0
			return function()
				n = n + 1
				if sub then
					local pad, done, _, err = sub()
					if err then return nil, true, nil, err end
					if done then sub = nil end
					return pad, false
				end
				if n > 3000 then return nil, true, nil, "the item's questions did not end" end
				local m, d = game.menu(), readDialogue()
				local answer
				if m and m.kind == "party" then
					if target == nil then return nil, true, nil, "the item asks for a Pokémon: name one with `on`" end
					sub = tapTo("party", target)
				elseif m and m.kind == "forget_move" then
					if not p.forget then return nil, true, nil, "the move asks what to forget: name it with `forget`" end
					local at
					for i, it in ipairs(m.items) do if it == p.forget then at = i - 1 end end
					if not at then return nil, true, nil, "no move " .. p.forget .. " to forget: " .. table.concat(m.items, ", ") end
					sub = tapTo("forget_move", at)
				elseif m and (m.kind == "learn_move") then
					answer = p.forget and "YES" or "NO"
				elseif m and m.kind == "stop_learning" then
					answer = "YES"
				elseif m and menuHas("YES")() then
					answer = "YES"
				elseif m and m.list then
					if n > 30 then return nil, true end
				elseif d then
					sub = game.programs.advance_text()
				elseif fieldClear() then
					return nil, true
				end
				if answer then sub = lib.select({ item = answer }) end
				return nil, false
			end
		end,
		closeAll(),
	}
	return chain(steps, function(log)
		local s1 = r32(SB1PTR)
		return { used = want, on = p.on, repel_steps = r16(s1 + 0x13DE), log = log }
	end), nil, 2400
end

-- The fly map's data while it is up: +0x0C the place name under the cursor, +0x5C/+0x5E its column and row. FLY_SPOTS:
-- a cell of each town, read by `fly_scan` (columns 1-28, rows 2-16); a town not in it needs a scan first.
local FLY_MAP_PTR = 0x0203a148
local FLY_SPOTS = {
	["LITTLEROOT TOWN"] = { x = 5, y = 13 }, ["OLDALE TOWN"] = { x = 5, y = 11 }, ["PETALBURG CITY"] = { x = 2, y = 11 },
	["RUSTBORO CITY"] = { x = 1, y = 7 }, ["DEWFORD TOWN"] = { x = 3, y = 16 }, ["SLATEPORT CITY"] = { x = 9, y = 12 },
	["MAUVILLE CITY"] = { x = 9, y = 8 }, ["VERDANTURF TOWN"] = { x = 5, y = 8 }, ["FALLARBOR TOWN"] = { x = 4, y = 2 },
	["LAVARIDGE TOWN"] = { x = 6, y = 5 }, ["FORTREE CITY"] = { x = 13, y = 2 }, ["LILYCOVE CITY"] = { x = 20, y = 5 },
	["MOSSDEEP CITY"] = { x = 26, y = 7 }, ["SOOTOPOLIS CITY"] = { x = 22, y = 9 }, ["PACIFIDLOG TOWN"] = { x = 18, y = 12 },
	["EVER GRANDE CITY"] = { x = 28, y = 10 }, ["BATTLE FRONTIER"] = { x = 23, y = 14 }, ["SOUTHERN ISLAND"] = { x = 13, y = 16 },
}
local function flyMap()
	local p = r32(FLY_MAP_PTR)
	if not inEwram(p) then return nil end
	local b = readString(p + 12)
	-- The name is padded with spaces to its field's width.
	return { name = decode(b, 1, #b):match("^(.-)%s*$"), x = r16(p + 0x5C), y = r16(p + 0x5E) }
end
-- The party menu: gMain.callback2 on its routine and its cursor byte, 0 on opening from START.
local function partyMenuUp() return (r32(GMAIN_CB2) & 0xFFFFFFFE) == LEARN.partyMenu.cb2 end
local function partyCursor() return memory.read_s8(LEARN.partyMenu.at + 9, BUS) end
-- The cursor to cell (x, y), one tapped direction at a time, each waiting until the cell reads changed.
-- `soft` (the scan): a direction the cursor does not take ends it quietly, at the map's edge.
local function flyCursorTo(x, y, soft)
	return function()
		local n, held, from = 0, 0, nil
		return function()
			n = n + 1
			local m = flyMap()
			if not m then return nil, true, nil, "the fly map is not up" end
			if n > 1200 then return nil, true, nil, string.format("the cursor is at %d,%d, not %d,%d", m.x, m.y, x, y) end
			if held > 0 then
				held = held + 1
				if held <= 3 then return { [from.dir] = true }, false end
				if (m.x ~= from.x or m.y ~= from.y) and held > 6 then held = 0 end
				if held > 40 then
					if soft then return nil, true end
					held = 0
				end
				return nil, false
			end
			if m.x == x and m.y == y then return nil, true, { at = m.name, x = x, y = y } end
			local dir = (m.x < x and "Right") or (m.x > x and "Left") or (m.y < y and "Down") or "Up"
			from, held = { x = m.x, y = m.y, dir = dir }, 1
			return { [dir] = true }, false
		end
	end
end
local function openFlyMap()
	local slot
	for i, mon in ipairs(readParty() or {}) do
		for _, mv in ipairs(mon.moves or {}) do if mv.name == "FLY" and not slot then slot = i - 1 end end
	end
	if not slot then return nil, "no Pokémon in the party knows FLY" end
	return {
		closeAll(), tap("Start"), waitFor(menuHas("POKéMON"), 60, "the START menu"), choose("POKéMON"),
		waitFor(partyMenuUp, 120, "the party menu"), waitFor(function() return partyCursor() == 0 end, 30, "the party cursor"),
		-- The screen takes no A while it fades in: 30 frames first.
		function() local n = 0; return function() n = n + 1; return nil, n >= 30 end end,
		function()
			local n = 0
			return function()
				n = n + 1
				if partyCursor() == slot then return nil, true end
				if n > 200 then return nil, true, nil, "the party cursor did not reach slot " .. slot end
				if n % 12 < 3 then return { Down = true }, false end
				return nil, false
			end
		end,
		tap("A"), waitFor(menuHas("FLY"), 60, "the Pokémon's menu"), choose("FLY"),
		waitFor(function() local m = flyMap(); return m and m.name ~= "" end, 180, "the fly map"),
	}
end
local function append(a, b) for _, s in ipairs(b) do a[#a + 1] = s end return a end

-- fly_scan {from, to}: opens the fly map and walks the cursor over rows `from` to `to` (2-16), columns 1-28, reading
-- each cell's name; returns the first cell of each name. What it read goes into FLY_SPOTS for this session.
local function flyScan(p)
	local steps, err = openFlyMap()
	if not steps then return nil, err end
	local found = {}
	for y = math.tointeger(p.from) or 2, math.tointeger(p.to) or 5 do
		for xi = 1, 28 do
			local x = (y % 2 == 0) and xi or (29 - xi)
			steps[#steps + 1] = flyCursorTo(x, y, true)
			steps[#steps + 1] = function()
				local m = flyMap()
				if m and m.x == x and m.y == y and m.name ~= "" and not found[m.name] then
					found[m.name] = { x = x, y = y }
					FLY_SPOTS[m.name] = { x = x, y = y }
				end
			end
		end
	end
	steps[#steps + 1] = closeAll()
	return chain(steps, function() return { spots = found } end), nil, 3600
end

-- fly {town}: the fly map, the cursor onto the town's cell, A, and the flight to its end (the field clear elsewhere).
local function fly(p)
	local town = tostring(p.town or ""):upper()
	local spot = FLY_SPOTS[town]
	if not spot then return nil, "no cell known for " .. town .. " (fly_scan reads them)" end
	local steps, err = openFlyMap()
	if not steps then return nil, err end
	local fromMap
	append(steps, {
		function() fromMap = r16(r32(SB1PTR) + 4) end,
		flyCursorTo(spot.x, spot.y), tap("A"),
		waitFor(function() return fieldClear() and r16(r32(SB1PTR) + 4) ~= fromMap end, 900, "the landing"),
	})
	return chain(steps, function(log) return { flew_to = town, log = log } end), nil, 3600
end

-- The party cursor to `slot` by taps 12 frames apart (the START menu's party screen). While SWITCH picks the second
-- Pokémon the cursor that moves is the next byte (+10); 7 is CANCEL.
local function partyTapTo(slot, second)
	local at = LEARN.partyMenu.at + (second and 10 or 9)
	return function()
		local k = 0
		return function()
			k = k + 1
			local c = memory.read_s8(at, BUS)
			if c == slot then return nil, true end
			if k > 400 then return nil, true, nil, "the party cursor did not reach slot " .. slot end
			if k % 12 >= 3 then return nil, false end
			return { [(c < slot) and "Down" or "Up"] = true }, false
		end
	end
end
-- swap {a, b}: party slots a and b (0-based) change places: START, POKéMON, a, A, SWITCH, b, A; the party read back.
local function swap(p)
	local a, b = math.tointeger(p.a), math.tointeger(p.b)
	local party = readParty() or {}
	if not a or not b or a == b or a < 0 or b < 0 or a >= #party or b >= #party then return nil, "swap needs two party slots" end
	local was = party[a + 1].nickname
	return chain({
		closeAll(), tap("Start"), waitFor(menuHas("POKéMON"), 60, "the START menu"), choose("POKéMON"),
		waitFor(partyMenuUp, 120, "the party menu"), waitFor(function() return partyCursor() == 0 end, 30, "the party cursor"),
		-- The screen takes no A while it fades in: 30 frames first.
		function() local n = 0; return function() n = n + 1; return nil, n >= 30 end end,
		partyTapTo(a), tap("A"), waitFor(menuHas("SWITCH"), 60, "the Pokémon's menu"), choose("SWITCH"),
		partyTapTo(b, true), tap("A"),
		waitFor(function() local now = readParty() or {}; return now[b + 1] and now[b + 1].nickname == was end, 240, "the swap"),
		closeAll(),
	}, function() local out = {}; for _, m in ipairs(readParty() or {}) do out[#out + 1] = m.nickname end; return { party = out } end),
		nil, 2400
end

-- ride {legs = {{dir, to}, ...}}: one hold, never let go between legs, for the MACH BIKE over cracked floors (a walk
-- per leg stops the bike, and a crack entered slowly drops the player). Each leg holds `dir` until the tile reaches
-- `to` on that axis; after the last, nothing until the tile has been still 30 frames. Answers where it stopped.
local function ride(p)
	local legs = type(p.legs) == "table" and p.legs or {}
	if #legs == 0 then return nil, "ride needs legs" end
	local BUTTON = { up = "Up", down = "Down", left = "Left", right = "Right" }
	for _, l in ipairs(legs) do
		if not BUTTON[l.dir] or math.tointeger(l.to) == nil then return nil, "each leg needs dir (up/down/left/right) and to" end
	end
	local i, still, last = 1, 0, nil
	local startMap = (routeHooks.position())
	-- Each tile entered, with the MACH BIKE's speed byte (avatar +0x0B) as it began: `tiles` in the answer, to read
	-- where a crack held and where the bike was too slow.
	local trace, tx, ty = {}, nil, nil
	-- wait {local_id, facing_raw}: nothing is pressed until that character's facing nibble reads facing_raw, so a
	-- turning trainer is passed while it looks away at game speed; a list waits for all of them at once.
	local wait = type(p.wait) == "table" and p.wait or nil
	if wait and wait.local_id then wait = { wait } end
	return function()
		if wait then
			local objects = readObjects()
			for _, w in ipairs(wait) do
				for _, o in ipairs(objects) do
					if o.local_id == w.local_id then
						local raw = r8(GOBJECTEVENTS + o.slot * OBJ_SIZE + 24) & 0x0F
						-- fresh: only a turn into the facing counts, so the whole of that facing is left to walk in.
						if w.fresh and raw ~= w.facing_raw then w.seen_other = true end
						if raw ~= w.facing_raw or (w.fresh and not w.seen_other) then return nil, false end
						-- x and/or y: also where it stands, for a trainer that walks a loop.
						if (w.x and o.x ~= w.x) or (w.y and o.y ~= w.y) then return nil, false end
					end
				end
			end
			wait = nil
		end
		local map, x, y = routeHooks.position()
		if map ~= startMap then return nil, true, { map = map, x = x, y = y, legs_done = i - 1, fell = true, tiles = trace } end
		if x ~= tx or y ~= ty then
			tx, ty = x, y
			trace[#trace + 1] = { x = x, y = y, speed = r8(GPLAYERAVATAR + 0x0B) }
		end
		local key = x .. "," .. y
		if i <= #legs then
			local l = legs[i]
			local at = (l.dir == "left" or l.dir == "right") and x or y
			if at == l.to then i = i + 1; return (i <= #legs) and { [BUTTON[legs[i].dir]] = true } or nil, false end
			return { [BUTTON[l.dir]] = true }, false
		end
		if key == last then still = still + 1 else still, last = 0, key end
		if still >= 30 then return nil, true, { map = map, x = x, y = y, legs_done = #legs, tiles = trace } end
		return nil, false
	end, nil, 1800
end

-- Field moves for the room's plan, each ending with the field clear and the player at rest. surf, smash and climb: face
-- the tile (a step does not enter it), one A, the text to its YES/NO, YES, the text to its end. push: STRENGTH's
-- question first while flag 0x889 is clear, then the direction held until the boulder leaves its tile, and nothing
-- until both rest. slide: the direction held until the player leaves the tile, then nothing until at rest 8 frames.
local function faceTo(d)
	return function()
		local n = 0
		return function()
			n = n + 1
			if routeHooks.facing() == d then return nil, atRest() end
			if n > 90 then return nil, true, nil, "could not face " .. d end
			return { [DIRECTIONS[d].button] = true }, false
		end
	end
end
local function settled(what)
	return function()
		local n = 0
		return function()
			n = n + 1
			if inBattle() then return nil, true, nil, "a battle started" end
			if fieldClear() and atRest() then return nil, true end
			if n > 900 then return nil, true, nil, "waited 900 frames for the field after " .. what end
			return nil, false
		end
	end
end
local function fieldMove(d, what)
	return { faceTo(d), tap("A"), waitFor(routeHooks.talkStarted, 120, "an answer to A"),
		function() return game.programs.advance_text() end, choose("YES"),
		function() return game.programs.advance_text() end, settled(what) }
end
local function objectAt(x, y)
	for _, o in ipairs(readObjects()) do
		if o.x == x and o.y == y then return o end
	end
end
routeHooks.act = function(kind, a)
	local d = DIRECTIONS[a.d]
	if not d and kind ~= "dive" and kind ~= "emerge" then return nil, "no direction " .. tostring(a.d) end
	if kind == "surf" or kind == "smash" or kind == "climb" then return chain(fieldMove(a.d, kind)) end
	if kind == "push" then
		local steps = {}
		if not flagGet(r32(SB1PTR), 0x889) then steps = fieldMove(a.d, "STRENGTH") end
		steps[#steps + 1] = function()
			local n = 0
			return function()
				n = n + 1
				if not objectAt(a.bx, a.by) then return nil, true end
				if n > 120 then return nil, true, nil, "the boulder at " .. a.bx .. "," .. a.by .. " did not move" end
				return { [d.button] = true }, false
			end
		end
		steps[#steps + 1] = waitFor(function()
			local o = objectAt(a.bx + d.dx, a.by + d.dy)
			if not o then return false end
			local b = memory.read_bytes_as_array(GOBJECTEVENTS + o.slot * OBJ_SIZE + 0x10, 8, BUS)
			return b[1] == b[5] and b[2] == b[6] and b[3] == b[7] and b[4] == b[8] and atRest()
		end, 120, "the boulder to stop")
		return chain(steps)
	end
	if kind == "dive" or kind == "emerge" then
		-- A (dive) or B (surface) where the player floats, the question, YES, the text, then the map change.
		local from = (routeHooks.position())
		return chain({ tap(kind == "dive" and "A" or "B"), waitFor(routeHooks.talkStarted, 120, "an answer to " .. kind),
			function() return game.programs.advance_text() end, choose("YES"),
			function() return game.programs.advance_text() end,
			waitFor(function() return (routeHooks.position()) ~= from and inOverworld() end, 600, "the " .. kind) })
	end
	if kind == "ride" then
		local steps = {}
		if (r8(GPLAYERAVATAR) & MACH_BIKE_FLAG) == 0 then
			steps[1] = tap("Select")
			steps[2] = waitFor(function() return (r8(GPLAYERAVATAR) & MACH_BIKE_FLAG) ~= 0 and atRest() end, 120, "the MACH BIKE")
		end
		steps[#steps + 1] = function() return ride({ legs = a.legs }) end
		-- A ride planned to end falling through a crack: the drop comes after the bike has stood on it longer than
		-- `ride`'s 30 still frames, so the map change is waited for.
		if a.fall then
			local from = (routeHooks.position())
			steps[#steps + 1] = waitFor(function() return (routeHooks.position()) ~= from end, 300, "the fall through the crack")
		end
		return chain(steps)
	end
	if kind == "slide" then
		local _, sx, sy = routeHooks.position()
		local n, still = 0, 0
		return function()
			n = n + 1
			local _, x, y = routeHooks.position()
			if n > 1200 then return nil, true, nil, "the current did not let go" end
			if x == sx and y == sy then
				if n > 60 then return nil, true, nil, "the step onto the current was not taken" end
				return { [d.button] = true }, false
			end
			still = atRest() and still + 1 or 0
			return nil, still >= 8
		end
	end
	return nil, "no field move " .. tostring(kind)
end

-- field_move {move}: START, POKéMON, the first Pokémon knowing it, A, the move; answers the lines shown in the 120
-- frames after (the game's refusal, a badge missing or not the place) and leaves the screen for the caller to close.
local function partyFieldMove(p)
	local move = tostring(p.move or ""):upper()
	local slot
	for i, mon in ipairs(readParty() or {}) do
		for _, mv in ipairs(mon.moves or {}) do if mv.name == move and not slot then slot = i - 1 end end
	end
	if not slot then return nil, "no Pokémon in the party knows " .. move end
	local said, seen = {}, {}
	return chain({
		closeAll(), tap("Start"), waitFor(menuHas("POKéMON"), 60, "the START menu"), choose("POKéMON"),
		waitFor(partyMenuUp, 120, "the party menu"), waitFor(function() return partyCursor() == 0 end, 30, "the party cursor"),
		function() local n = 0; return function() n = n + 1; return nil, n >= 30 end end,
		partyTapTo(slot), tap("A"), waitFor(menuHas(move), 60, "the Pokémon's menu"),
		-- What the party screen already shows is not an answer.
		function()
			for _, w in ipairs(readScreenText()) do for _, l in ipairs(w.lines) do seen[l] = true end end
		end,
		choose(move),
		function()
			local n = 0
			return function()
				n = n + 1
				for _, w in ipairs(readScreenText()) do
					for _, l in ipairs(w.lines) do
						if not seen[l] then seen[l], said[#said + 1] = true, l end
					end
				end
				return nil, n >= 120
			end
		end,
	}, function() return { move = move, slot = slot, said = said } end), nil, 1200
end

-- reflex {kind, args}: the field errands above, each a program by kind.
local ERRANDS = { use_item = useItem, fly = fly, fly_scan = flyScan, swap = swap, ride = ride, field_move = partyFieldMove }
return function(p)
	local make = ERRANDS[p.kind]
	if not make then return nil, "no reflex " .. tostring(p.kind) end
	local prog, err, limit = make(type(p.args) == "table" and p.args or {})
	if not prog then return nil, err end
	return prog, nil, math.max(limit or 0, math.tointeger(p.frames) or 0)
end
end)()

-- type_text {text, confirm}: types on the naming keyboard as a player does: B until empty, then per character Select to
-- its page, a step at a time to its key, and A, each press waiting until the game's bytes show the last one landed; the
-- typed byte is read back. With confirm, Start and A on OK; without, nothing after the last letter, since after a full
-- name the cursor goes to OK by itself and an A there confirms.
game.programs.type_text = function(p)
	local TYPE_TAP, TYPE_ANSWER, TYPE_BUSY = 2, 40, 300
	if not isVanilla then return nil, "type_text is measured on the vanilla ROM only" end
	local k = keyboardState()
	if not k then return nil, "no naming keyboard is open (observe shows no keyboard)" end
	local text, confirm = type(p.text) == "string" and p.text or "", p.confirm ~= false
	local chars = {}
	local ok, err = pcall(function()
		for _, cp in utf8.codes(text) do chars[#chars + 1] = utf8.char(cp) end
	end)
	if not ok then return nil, "text is not UTF-8: " .. tostring(err) end
	if #chars == 0 or #chars > k.max then
		return nil, string.format("text must be 1 to %d characters on this keyboard, got %d", k.max, #chars)
	end
	local function keyOn(page, ch)
		for r, row in ipairs(keysOf(page)) do
			for c, key in ipairs(row) do
				if key.glyph == ch then return { page = page, row = r - 1, column = c - 1, byte = key.byte } end
			end
		end
		return nil
	end
	local function keyFor(page, ch)
		local here = keyOn(page, ch)
		if here then return here end
		for _, pg in ipairs({ 1, 2, 0 }) do
			local there = keyOn(pg, ch)
			if there then return there end
		end
		return nil
	end
	for _, ch in ipairs(chars) do
		if not keyFor(k.page, ch) then return nil, string.format("%q is on no page of this keyboard", ch) end
	end

	local phase, i, frames, busy, settle, presses, typed = "clear", 1, 0, 0, 0, 0, nil
	local pressing, expect = nil, nil
	local function finish(outcome, extra)
		local r = { outcome = outcome, typed = typed, presses = presses }
		for key, v in pairs(extra or {}) do r[key] = v end
		return nil, true, r
	end
	local function tap(button, what, done)
		pressing, presses = { pad = { [button] = true }, held = 0, what = what, done = done }, presses + 1
		return pressing.pad, false
	end

	return function()
		frames = frames + 1
		local s = keyboardState()
		if not s then
			if phase == "closing" then return finish("confirmed") end
			return finish("closed", { waiting_on = pressing and pressing.what or phase })
		end
		typed = decode(s.text, 1, #s.text)
		if pressing then
			pressing.held = pressing.held + 1
			if pressing.held <= TYPE_TAP then return pressing.pad, false end
			if pressing.done(s) then
				pressing, settle = nil, 2
			elseif pressing.held > TYPE_ANSWER then
				return nil, true, nil, string.format("the keyboard did not answer %s in %d frames", pressing.what, TYPE_ANSWER)
			end
			return nil, false
		end
		if settle > 0 then
			settle = settle - 1
			return nil, false
		end
		if s.state ~= KEYBOARD_READY then
			busy = busy + 1
			if busy > TYPE_BUSY then
				return nil, true, nil, string.format("the keyboard was not taking keys for %d frames (state %d)", TYPE_BUSY, s.state)
			end
			return nil, false
		end
		busy = 0
		if expect then
			if #s.text ~= expect.length or s.text[#s.text] ~= expect.byte then
				return nil, true, nil, string.format("typed %q, expected character %d to be byte %02X", typed, expect.length, expect.byte)
			end
			expect, i = nil, i + 1
		end

		if phase == "clear" then
			if #s.text > 0 then
				local n = #s.text
				return tap("B", "B", function(now) return #now.text < n end)
			end
			phase = "type"
		end

		if phase == "type" then
			if i > #chars then
				if not confirm then return finish("typed") end
				phase = "confirm"
			else
				local key = keyFor(s.page, chars[i])
				local columns = PAGE_COLUMNS[s.page]
				if key.page ~= s.page then
					local from = s.page
					return tap("Select", "Select", function(now) return now.page ~= from end)
				end
				local col, row = s.column, s.row
				local moved = function(now) return now.column ~= col or now.row ~= row end
				if col >= columns then return tap("Left", "Left", moved) end
				if col ~= key.column then
					local dir = col < key.column and "Right" or "Left"
					return tap(dir, dir, moved)
				end
				if row ~= key.row then
					local dir = row < key.row and "Down" or "Up"
					return tap(dir, dir, moved)
				end
				local n = #s.text
				expect = { length = n + 1, byte = key.byte }
				return tap("A", "A on " .. chars[i], function(now) return #now.text ~= n or now.state ~= KEYBOARD_READY end)
			end
		end

		if phase == "confirm" then
			if s.column == PAGE_COLUMNS[s.page] and s.row == OK_ROW then
				phase = "closing"
				return tap("A", "A on OK", function(now) return now.state ~= KEYBOARD_READY end)
			end
			return tap("Start", "Start", function(now) return now.column == PAGE_COLUMNS[now.page] and now.row == OK_ROW end)
		end
		return nil, false
	end, nil, 3600
end

-- set_clock {hours, minutes, confirm}: Right or Left, the shorter way round, held until the clock reads the time and
-- let go on that frame, which moves nothing more (a time passed is gone back to); nothing while the hands still turn.
-- With confirm (the default), A, Up to YES and A, answering once callback2 has left the clock.
game.programs.set_clock = function(p)
	local TAP, ANSWER, BUSY, HOLD = 2, 40, 120, 1500
	if not isVanilla then return nil, "set_clock is measured on the vanilla ROM only" end
	local hours, minutes = math.tointeger(p.hours), math.tointeger(p.minutes)
	if not hours or hours < 0 or hours > 23 then return nil, "set_clock needs hours, 0 to 23" end
	if not minutes or minutes < 0 or minutes > 59 then return nil, "set_clock needs minutes, 0 to 59" end
	local c = clockState()
	if not c or c.func ~= CLOCK.setting then return nil, "no clock is being set (observe shows no clock in state setting)" end
	local confirm, target = p.confirm ~= false, hours * 60 + minutes
	local phase, busy, held, presses, pressing, holding, set = "set", 0, 0, 0, nil, nil, nil
	local function finish(outcome)
		return nil, true, { outcome = outcome, set = set, presses = presses }
	end
	local function fail(msg) return nil, true, nil, msg end
	local function tap(button, what, done)
		pressing, presses = { pad = { [button] = true }, held = 0, what = what, done = done }, presses + 1
		return pressing.pad, false
	end

	return function()
		local s = clockState()
		if not s then
			if phase == "closing" then return finish("confirmed") end
			return fail("the clock screen closed before the time was " .. (confirm and "confirmed" or "set"))
		end
		if pressing then
			pressing.held = pressing.held + 1
			if pressing.held <= TAP then return pressing.pad, false end
			if pressing.done(s) then
				pressing = nil
			elseif pressing.held > ANSWER then
				return fail(string.format("the clock did not answer %s in %d frames", pressing.what, ANSWER))
			end
			return nil, false
		end

		if phase == "set" then
			if s.func ~= CLOCK.setting then return fail("the clock stopped taking the time (state " .. tostring(CLOCK.states[s.func]) .. ")") end
			local ahead = (target - (s.hours * 60 + s.minutes)) % 1440
			local way = ahead <= 720 and "Right" or "Left"
			if holding then
				if ahead == 0 or way ~= holding then
					holding = nil
					return nil, false
				end
				held = held + 1
				if held > HOLD then
					return fail(string.format("%s held %d frames and the clock reads %d:%02d", holding, HOLD, s.hours, s.minutes))
				end
				return { [holding] = true }, false
			end
			if s.direction ~= 0 or s.speed ~= 0 then
				busy = busy + 1
				if busy > BUSY then return fail(string.format("the hands kept turning for %d frames", BUSY)) end
				return nil, false
			end
			busy = 0
			if ahead ~= 0 then
				holding, held, presses = way, 0, presses + 1
				return { [holding] = true }, false
			end
			set = { hours = s.hours, minutes = s.minutes, period = CLOCK.periods[s.period] }
			if not confirm then return finish("set") end
			phase = "confirm"
			return tap("A", "A", function(now) return now.func == CLOCK.asking end)
		end

		if phase == "confirm" then
			if s.func ~= CLOCK.asking then return fail("the clock's question is not up") end
			if r8(SMENU + 2) ~= 0 then
				return tap("Up", "Up to YES", function() return r8(SMENU + 2) == 0 end)
			end
			phase = "closing"
			return tap("A", "A on YES", function(now) return now.func ~= CLOCK.asking end)
		end
		return nil, false
	end, nil, 3600
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
		keyboard_text = o.keyboard and o.keyboard.text or "none",
		keyboard_on = o.keyboard and (o.keyboard.on or ("button row " .. tostring(o.keyboard.on_button_row))) or "none",
		keyboard_page = o.keyboard and o.keyboard.page or "none",
		clock = o.clock and string.format("%d:%02d %s", o.clock.hours, o.clock.minutes, o.clock.state) or "none",
		battle_asking = o.battle and o.battle.asking or "none",
		battle_hp = o.battle and (function()
			local hp = {}
			for _, b in ipairs(o.battle.battlers) do hp[#hp + 1] = b.hp .. "/" .. b.max_hp end
			return table.concat(hp, " ")
		end)() or "none",
	}
end

-- Read every frame for events (a map or mode change, a dialogue or menu opening or closing): nothing is decoded here.
function game.watch()
	local sb1 = r32(SB1PTR)
	local cb2 = r32(GMAIN_CB2)
	return {
		map = string.format("%d.%d", r8(sb1 + 4), r8(sb1 + 5)),
		mode = ((cb2 == CB2_OVERWORLD or cb2 == CB2_OVERWORLD + 1) and "overworld")
			or (isVanilla and (cb2 == BATTLE_MAIN_CB2 or cb2 == BATTLE_MAIN_CB2 + 1) and "battle") or "not_overworld",
		dialogue = (dialogue and windowOnScreen(dialogue.window)) and "open" or "closed",
		menu = (menuWindow and windowOnScreen(menuWindow)) and "open" or "closed",
		-- battle_input_changed: the battle starts or stops waiting for an action, a move or a target.
		battle_input = isVanilla and (cb2 == BATTLE_MAIN_CB2 or cb2 == BATTLE_MAIN_CB2 + 1) and battleAsking() or "none",
	}
end

return game
