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
-- The routines named ChangeMenuGridCursorPosition and ChangeGridMenuCursorPosition: a grid menu's setup calls
-- the first (the bag's USE/GIVE/TOSS/CANCEL left the START menu's Menu_MoveCursor hook silent, and the
-- struct below read 2 columns and 2 rows, list_menu_probe.lua, 2026-09-17).
local CHANGE_MENU_GRID_CURSOR, CHANGE_GRID_MENU_CURSOR = 0x08199134, 0x081991f8
-- 0x24 bytes per window id. +0x1B is 1 while a message is on its way (printing or waiting on its
-- arrow) and 0 once its end is reached; +0x1C is 0 while printing, 2 while the red arrow waits for a
-- button, and 3 while it waits before an FA scrolls the text. Other +0x1C values are not measured and
-- go out raw.
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

-- FC followed by one of these codes took one more byte, and none of the three was drawn: FC 13 38 put
-- BAG 56 px right of FIGHT, FC 06 01 sat in "TYPE/NORMAL", FC 01 0B and FC 02 02 around the battle's
-- "MUDKIP♂" (battle_state_probe.lua against captures, 2026-09-16). Other FC codes go out byte by byte.
local EXT, EXT_ONE_ARG = 0xFC, { [0x01] = true, [0x02] = true, [0x06] = true, [0x13] = true }
-- And these took none: a trainer's defeat words ended FC 09 FF, and "grew to LV. 9!" FC 0A FB, with the next
-- box's text straight after (battle_state_probe.lua, 2026-09-16). Whether they draw anything is not measured.
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
-- Whether the last menu set up was a grid: the struct's column count is left over from the last grid when a
-- list menu is set up after one (the START menu read 2 columns after the bag's item menu, 2026-09-17).
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
	menuWindow, menuGrid = r8(SMENU + 5), false
end
function hooks.menuGridCursor()
	menuWindow, menuGrid = r8(SMENU + 5), true
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
	elseif stateRaw == 1 or stateRaw == 2 or stateRaw == 3 then
		-- 3: at an FA, both lines drawn and the red arrow up, before the text scrolls (a trainer's
		-- challenge, 2026-09-16). 1: at an FC 09 ending a trainer's defeat words in a battle, where it stayed
		-- until an A press moved it on (three battles, 2026-09-16).
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
	local top, cursor, last, w, width, height, columns = m[2], m[3], m[5], m[6], m[8], m[9], m[10]
	if w ~= menuWindow then return nil end
	if cursor > 127 then cursor = cursor - 256 end
	if menuGrid and columns >= 1 and width > 0 and height > 0 then
		-- A grid: +7 a column's width and +9 the columns, entries numbered row by row (the bag's item menu read
		-- 0x38 wide, 2 by 2, list_menu_probe.lua, 2026-09-17). Each printed piece goes to the cell nearest it.
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

-- Story flags: one bit per id in SaveBlock1 +0x1270, bit (id & 7) of byte id >> 3, up to FLAG_MAX where the
-- build's layout ends that byte array (measured on the badge flags, see `badges`).
local FLAGS_AT, FLAG_MAX = 0x1270, 0x95F
local function flagGet(sb1, id)
	return (r8(sb1 + FLAGS_AT + (id >> 3)) >> (id & 7)) & 1 == 1
end

-- TRAINERS (2026-09-16, vanilla, route 0.17's four trainers, read with `observe` and walked into with
-- `walk`; that adapter's MEASURED.md, "A trainer's sight"). The map's character templates are the
-- header's second pointer's first count and list, 24 bytes an entry: id +0, x and y +4/+6 (find_objects.py),
-- and on all four trainers +0x09 equal to the live character's +0x06, +0x0C to its +0x07 and +0x0E to its
-- +0x1D.
--   * +0x07 reading 1 is a trainer. The script its template's +0x10 points at began 5C on all four, and
--     the flag 0x500 plus that script's u16 at +2 read clear until the trainer was beaten and set after
--     (RICK and TIANA, read before and after each battle); a beaten one did not come for the player
--     standing three tiles into its line (CALVIN).
--   * +0x1D is how far it sees: RICK (2) came for the player 2 tiles away and not 3, TIANA (3) at 3 and not
--     4, CALVIN (3) at 3 before he was beaten.
--   * +0x18's low nibble is the way it faces: 1 down (CALVIN, drawn so, came from below), 2 up (RICK, came
--     from above), 4 right (TIANA, came from the right). 3 is not measured.
--   * A trainer that turns came for a player STANDING in its line once it turned that way (TIANA: the
--     player arrived while she faced down, and she came when she faced right), so its sight is every way it
--     turns. Sampled 16 times 30 frames apart: +0x06 7 read up only (RICK), 8 down only (CALVIN and the
--     trainer at 19,4) and 0x12 down and right (TIANA). Any other value is taken to turn every way.
-- Not measured: whether a wall or a character between them blocks a trainer's view (taken as not), a
-- +0x07 other than 1 (taken to see every way, never beaten), and what a template's +0x14 does.
local FACING = { [1] = "down", [2] = "up", [4] = "right" }
local TURNS = { [7] = { "up" }, [8] = { "down" }, [0x12] = { "down", "right" } }
local EVERY_WAY = { "up", "down", "left", "right" }
local SIGHT_STEP = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

local function readTemplates()
	local out, events = {}, r32(GMAPHEADER + 4)
	if not inRom(events) then return out end
	local n, list = r8(events), r32(events + 4)
	if not inRom(list) then return out end
	for i = 0, math.min(n, 64) - 1 do
		local e = memory.read_bytes_as_array(list + i * 24, 24, BUS)
		out[#out + 1] = { local_id = e[1], x = e[5] | (e[6] << 8), y = e[7] | (e[8] << 8), movement = e[10],
			trainer_type = e[13] | (e[14] << 8), range = e[15] | (e[16] << 8),
			script = e[17] | (e[18] << 8) | (e[19] << 16) | (e[20] << 24) }
	end
	return out
end

-- What a trainer is: `beaten` (nil when its flag cannot be read), `range`, and `sees`, the ways it looks.
local function trainerOf(sb1, trainerType, range, movement, script)
	local t = { range = range, sees = (trainerType == 1 and TURNS[movement]) or EVERY_WAY }
	if trainerType ~= 1 then t.trainer_type_raw = trainerType end
	if trainerType == 1 and inRom(script) and r8(script) == 0x5C then
		t.flag = 0x500 + r16(script + 2)
		if t.flag <= FLAG_MAX then t.beaten = flagGet(sb1, t.flag) end
	end
	return t
end

-- The other characters: object slots whose first byte has bit 0 set; +0x05 the graphic, +0x08 the
-- local id, +0x10/+0x12 where it stands. On map 0.10 two slots' ids, graphics and first positions
-- matched the map's own list, and the positions matched where the capture drew them. A trainer on this map
-- carries `trainer`; +0x06 and a facing not measured go out raw.
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
					sees = info.sees, loaded = o ~= nil }
			end
		end
	end
	return out
end

-- The tiles unbeaten trainers can see, keyed y * width + x, each naming the first trainer found.
local function sightTiles(trainers, mapW, mapH)
	local seen = {}
	for _, t in ipairs(trainers) do
		for _, way in ipairs(t.sees) do
			local step = SIGHT_STEP[way]
			for k = 1, math.min(t.range, 15) do
				local x, y = t.x + step[1] * k, t.y + step[2] * k
				if x >= 0 and y >= 0 and x < mapW and y < mapH then
					seen[y * mapW + x] = seen[y * mapW + x] or t
				end
			end
		end
	end
	return seen
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

-- A move's data, 12 bytes an entry (move_data_probe.lua against the summary's BATTLE MOVES page,
-- 2026-09-16, for TACKLE, GROWL and MUD-SLAP): +1 the power (GROWL's 0 was drawn as "---"), +2 the type
-- as an index into 7-byte type names (0 NORMAL, 4 GROUND), +3 the accuracy (95, 100, 100), +4 the PP
-- each move's maximum was drawn as on a Pokémon with no PP bonus (35, 40, 10). The effect text is
-- behind a pointer per move at (id - 1) * 4; all three read word for word as the page's DESCRIPTION.
local BATTLE_MOVES, BATTLE_MOVE_SIZE = 0x0831c898, 12
local TYPE_NAMES, TYPE_NAME_LEN, TYPE_COUNT = 0x0831ae38, 7, 18
local MOVE_DESCRIPTIONS = 0x0861c524
local moveCache = {}
local function moveInfo(id)
	local m = moveCache[id]
	if m == nil and id >= 1 and id < MOVE_COUNT then
		local e = memory.read_bytes_as_array(BATTLE_MOVES + id * BATTLE_MOVE_SIZE, BATTLE_MOVE_SIZE, BUS)
		local desc = readString(r32(MOVE_DESCRIPTIONS + (id - 1) * 4))
		local typeName
		if e[3] < TYPE_COUNT then
			-- Type 0 is a real type (NORMAL), so this reads index 0 too, unlike nameAt.
			local t = memory.read_bytes_as_array(TYPE_NAMES + e[3] * TYPE_NAME_LEN, TYPE_NAME_LEN, BUS)
			local last = TYPE_NAME_LEN
			for i = 1, TYPE_NAME_LEN do
				if t[i] == EOS then
					last = i - 1
					break
				end
			end
			typeName = decode(t, 1, last)
		end
		m = { type = typeName, power = e[2], accuracy = e[4], base_pp = e[5],
			description = #desc > 0 and decode(desc, 1, #desc) or nil }
		moveCache[id] = m
	end
	return m or {}
end

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

-- LIST MENUS (list_menu_probe.lua against captures of the bag, 2026-09-17, vanilla): while the bag's item list
-- waited, one of the 16 tasks at the build's gTasks (40 bytes each: the routine's address +0, nonzero +4
-- while active, data from +8) ran the routine named ListMenuDummyTask. Its data's first word pointed at the
-- entries, 8 bytes each (a name pointer, then an id: -2 for CLOSE BAG), +0x0C held how many (4 on KEY
-- ITEMS; 13 once ITEMS held twelve kinds, 8 of them shown), +0x10 the window, +0x18 how far the list had
-- scrolled and +0x1A the row the cursor was on: eleven Downs through thirteen entries read rows 1-4, then
-- scroll 1-5 at row 4, then rows 5 and 6, and the capture drew AWAKENING on top with the cursor on MAX
-- REPEL, entry 11. The names read as the list drew them; the quantities are printed separately. While the
-- bag was open callback2 read the routine named CB2_BagMenuRun (+1), and the byte 5 into the build's
-- gBagPosition the pocket in the bag's order (4 on KEY ITEMS; Right from there wrapped to 0, ITEMS).
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

-- BATTLES (2026-09-16, vanilla: `emerald/probes/battle_state_probe.lua` through one wild battle, read
-- against captures of each message, both menus and every cursor position; that adapter's MEASURED.md,
-- same date). gMain.callback2 read the routine the build names BattleMainCB2, +1, from before the first
-- message to after the last.
local BATTLE_MAIN_CB2 = 0x08038420
local BATTLE_TYPE_FLAGS, BATTLERS_COUNT, BATTLER_POSITIONS = 0x02022fec, 0x0202406c, 0x02024076
-- 0x58 bytes a battler: species +0x00, moves +0x0C, PP +0x24, HP +0x28, level +0x2A, max HP +0x2C, name
-- +0x30 -- each matched the battle screen, a spent PP and a level-up.
local BATTLE_MONS, BATTLE_MON_SIZE = 0x02024084, 0x58
local ACTION_CURSOR, MOVE_CURSOR, BATTLE_OUTCOME = 0x020244ac, 0x020244b0, 0x0202433a
-- One routine per battler; battler 0's was the routine named HandleInputChooseAction (+1) for as long as
-- the action menu waited, and the one named HandleInputChooseMove (+1) for the move menu.
local CONTROLLER_FUNCS, CHOOSE_ACTION, CHOOSE_MOVE = 0x03005d60, 0x08057588, 0x08057bfc
-- The routine the build names gBattlescriptCurrInstr moves on as the battle's script does, and the byte
-- 0x1E into the one it names gBattleScripting read 6 while the level-up box's first page waited for a
-- button, 8 while its second did, and 10 once it closed -- each A press moving it on, then the script
-- pointer moving (battle_state_probe.lua, a level-up to 9, 2026-09-16). Nothing else logged changed while
-- the box waited.
local BATTLESCRIPT_INSTR, LEVEL_UP_BOX_STATE = 0x02024214, 0x02024474 + 0x1E
local LEVEL_UP_BOX_WAITING = { [6] = "page 1", [8] = "page 2" }
-- The action menu as drawn, in cursor order: 0 FIGHT and 1 BAG on the top row, 2 POKéMON and 3 RUN below.
local BATTLE_ACTIONS = { "FIGHT", "BAG", "POKéMON", "RUN" }

local function inBattle()
	local cb = r32(GMAIN_CB2)
	return cb == BATTLE_MAIN_CB2 or cb == BATTLE_MAIN_CB2 + 1
end

-- What battler 0's controller waits for: "action", "move", or nil for anything else.
local function battleAsking()
	local f = r32(CONTROLLER_FUNCS) & 0xFFFFFFFE
	if f == CHOOSE_ACTION then return "action" end
	if f == CHOOSE_MOVE then return "move" end
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
				-- Type, power and accuracy only: a battle observation rides on every press, and the effect
				-- text is in `party`.
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
		-- Position 0 was the player's Pokémon and 1 the opponent's in a single battle; others unmeasured.
		local pos = positions[i + 1]
		battlers[#battlers + 1] = { battler = i, position = pos, side = (pos == 0 and "player") or (pos == 1 and "opponent") or nil,
			species_id = u16of(b, 1), species = nameAt(SPECIES_NAMES, SPECIES_LEN, SPECIES_COUNT, u16of(b, 1)),
			nickname = decode(b, 49, last), level = b[43], hp = u16of(b, 41), max_hp = u16of(b, 45),
			moves = #moves > 0 and moves or nil }
	end
	-- The type flags read 0x04 in four wild battles and 0x0C against a trainer (one battle).
	local flags = r32(BATTLE_TYPE_FLAGS)
	return { asking = battleAsking(), kind = (flags & 0x08) ~= 0 and "trainer" or "wild", battlers = battlers,
		type_flags_raw = flags, outcome_raw = r8(BATTLE_OUTCOME) }
end

-- The menu battler 0 is choosing from, as `select` reads a menu: `columns` 2, cursor order row by row.
local function battleMenu()
	local asking = battleAsking()
	if asking == "action" then
		return { window = "battle_action", items = BATTLE_ACTIONS, cursor = r8(ACTION_CURSOR), columns = 2 }
	elseif asking == "move" then
		-- The four move slots as the move menu drew them, "-" for an empty one.
		local items = {}
		for k = 0, 3 do
			local id = r16(BATTLE_MONS + 0x0C + k * 2)
			items[#items + 1] = id ~= 0 and (nameAt(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, id) or string.format("move %d", id)) or "-"
		end
		return { window = "battle_move", items = items, cursor = r8(MOVE_CURSOR), columns = 2 }
	end
	return nil
end

local game = {
	game = "emerald",
	-- "vanilla" only when the ROM's hash is the one every address here was measured on.
	variant = isVanilla and "vanilla" or "unverified",
	capabilities = { "observe", "press", "wait", "screenshot", "snapshot", "restore", "cheat:warp", "cheat:set_flag",
		"cheat:give_item", "cheat:register_item", "select", "walk", "goto", "battle", "advance_text" },
	-- The START menu and a YES/NO: Down moved the cursor one entry per press and A chose it; in a battle
	-- menu Left and Right moved between its two columns (2026-09-16).
	menuButtons = { prev = "Up", next = "Down", left = "Left", right = "Right", confirm = "A" },
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
	local battle = isVanilla and inBattle() and readBattle() or nil
	if #hookNames > 0 then
		d, m = readDialogue(), readMenu()
	end
	-- A list menu under a menu opened from it (the bag's item menu) is not the one waiting.
	local list = (isVanilla and not battle and not m) and readListMenu() or nil
	m = m or list
	if #hookNames > 0 then
		-- In a battle the windows' own bytes do not say which are showing (the action and move menus
		-- stayed listed while a message played), so screen_text is left out; `battle` and `menu` say
		-- what is being asked. A list's own window is left out too: its rows are reprinted as it scrolls.
		if not battle then
			s = readScreenText(d and d.window, m and m.window)
			if #s == 0 then s = nil end
		end
	end
	if battle then m = battleMenu() end
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
		battle = battle,
		dialogue = d,
		menu = m,
		screen_text = s,
		local_map = localMap,
		nearby = nearby,
		warps = warps,
		frame = emu.framecount(),
		mode = (overworld and "overworld") or (battle and "battle") or "not_overworld",
		-- The avatar's first byte: 0x04 read on the Acro Bike, 0x02 on the Mach Bike, 0x01 on foot and 0x81
		-- running (step_probe.lua and bike_probe.lua, 2026-09-16); anything else stays in extras.
		movement = overworld and (((r8(GPLAYERAVATAR) & 0x04) ~= 0 and "acro_bike") or ((r8(GPLAYERAVATAR) & 0x02) ~= 0
			and "mach_bike") or ((r8(GPLAYERAVATAR) & 0x01) ~= 0 and "on_foot")) or nil,
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

-- register_item {item = name or id}: the item SELECT uses, SaveBlock1 +0x496, a plain u16 (cmd_drive.lua's
-- `register`, 2026-09-16: with the Acro Bike's id written there, SELECT mounted it through the game's own
-- field effect, and with the Super Rod's it cast). Refused unless the bag holds the item, and outside the
-- overworld. Getting on a bike is then a press of Select.
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

-- The menu alone, for a program that looks every frame (select).
function game.menu()
	if isVanilla and inBattle() then return battleMenu() end
	local m = (#hookNames > 0) and readMenu() or nil
	return m or (isVanilla and readListMenu()) or nil
end

-- PROGRAMS: run once a frame by the driver, each returning (pad or nil, finished, result, error).
game.programs = {}

local DIRECTIONS = {
	up = { button = "Up", dx = 0, dy = -1 }, down = { button = "Down", dx = 0, dy = 1 },
	left = { button = "Left", dx = -1, dy = 0 }, right = { button = "Right", dx = 1, dy = 0 },
}
local REST_LIMIT, IDLE_LIMIT, PRESS_LIMIT, DOOR_LIMIT, STEP_LIMIT = 120, 20, 90, 150, 180
-- The avatar's first byte: 0x01 on foot (0x81 running), 0x02 on the Mach Bike, 0x04 on the Acro Bike
-- (step_probe.lua and bike_probe.lua, 2026-09-16).
local ON_FOOT_FLAG, MACH_BIKE_FLAG, ACRO_BIKE_FLAG = 0x01, 0x02, 0x04

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

-- A TRAINER COMING FOR THE PLAYER (trainer_approach_probe.lua, 2026-09-17, walking into RICK's line and a
-- goto routed into TIANA's): the byte the build names gNoOfApproachingTrainers went from 0 to 1 on the frame
-- after the step into the line began -- 16 frames before the player arrived -- and stayed 1 through the
-- approach; gSpecialVar_LastTalked read the trainer's local id (3, then 4) and the second byte of
-- gApproachingTrainers how many tiles away it stood (2 both times). Held input then does nothing, which
-- `walk` and `goto` used to report as `no_response`. What these read once a battle is over is not measured,
-- so a reading left over from before the program counts only once it has changed.
local NUM_APPROACHING, APPROACHING, LAST_TALKED = 0x030060a8, 0x03006090, 0x020375f2
-- The byte the build names sGlobalScriptContextStatus read 2 with no script running (before the step into
-- the line, after a warp, and 25 frames after the overworld came back from the battle), 0 on the frame the
-- trainer's approach began, and 0 or 1 from then through its words, the battle and its words after
-- (trainer_approach_probe.lua, 2026-09-17, three approaches and one whole battle). Other scripts -- a
-- character spoken to, a sign -- are not measured.
local SCRIPT_CONTEXT_STATUS, SCRIPT_CONTEXT_OFF = 0x03000e38, 2

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

-- walk {direction, tiles, run}: the direction is held from the first tile to the last, the way a player
-- walks, and every tile is counted on the game's own state (step_probe.lua, 2026-09-16, a held direction
-- across six tiles into a wall, walking and running):
--   * a step BEGINS the frame the player's coordinates change; the previous coordinate catches up and
--     the object's byte 0 top bit comes back at its end, for one frame, and with the direction still
--     held the next step begins on the frame after;
--   * a step that cannot be taken is a bump: the coordinates stay, the previous coordinate already equals
--     them, the avatar's +2 reads 2 and byte 0's top bit is clear -- from rest (the first measurement)
--     and straight after a step alike;
--   * releasing while a step is under way lets it finish, and "at rest" (atRest) follows 2 frames later.
-- So the direction is released when the last tile's step begins, and the answer waits for rest. From
-- rest, a press facing another way turns first (+2 reads 1 for 7 frames), and a door opens before the
-- step (+2 at 1 and +3 at 2 for 13 more), so only frames where +2 reads 0 count towards giving up --
-- unless the tile ahead is in the warp list: a door facing the player opened with all of these bytes at
-- rest for 20 frames, then the step began on its own, so a press toward a warp waits up to DOOR_LIMIT.
-- It stops early when the map changes, the game leaves the overworld, or a message box or menu is on
-- screen; `moved` counts the steps begun. `run`: B is held too (step_probe.lua: the avatar's first byte
-- read 0x81 instead of 0x01, a tile took 8 frames instead of 16); `ran` says whether 0x80 was seen,
-- which it is not without the running shoes, when B does nothing.
-- ON A BIKE (bike_probe.lua, 2026-09-16, the avatar's first byte reading 0x02 on the Mach Bike and 0x04 on
-- the Acro Bike): the Acro Bike rode 6 frames a tile and stopped on the tile it was on when released, so it
-- walks like the player on foot. The Mach Bike's +0x0B read 0 on the first held tile (16 frames), 1 on the
-- second (8) and 3 from the third (4), and once released it carried on one tile per unit of that value,
-- counting down (3: three more tiles, 1: one more). So on the Mach Bike the direction is let go as soon as
-- holding one more tile would carry past the target, the ride coasts, and any tiles still short are walked
-- from rest the same way.
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
			if mach then
				-- The step just begun carries on for `speed` more tiles once released; holding one more
				-- raises it from 0 to 1, or from 1 to 3 (bike_probe.lua).
				local speed = r8(GPLAYERAVATAR + 0x0B)
				local nextSpeed = speed == 0 and 1 or 3
				if moved + speed >= tiles or moved + 1 + nextSpeed > tiles then
					phase = "coasting"
					return nil, false
				end
			end
			towardWarp = warpAhead(x, y)
			return hold, false
		end
		local b = memory.read_bytes_as_array(playerObject(), 0x18, BUS)
		local caughtUp = b[17] == b[21] and b[18] == b[22] and b[19] == b[23] and b[20] == b[24]
		local state = r8(GPLAYERAVATAR + 2)
		if state == 2 and caughtUp and (b[1] & 0x80) == 0 then
			phase, frames = "refused", 0
			return nil, false
		end
		if state == 0 then idle = idle + 1 end
		if towardWarp then
			if frames > DOOR_LIMIT then return finish("no_response") end
		elseif idle > IDLE_LIMIT or frames > PRESS_LIMIT then
			return finish("no_response")
		end
		return hold, false
	end
end

-- goto {x, y, run}: to a tile on this map by a planned route of straight legs, holding each leg's
-- direction and switching to the next as the step into the corner begins -- a held direction turns on
-- arrival, and the Mach Bike kept its speed through a turn (bike_probe.lua, 2026-09-16: the first tile
-- after the corner read +0x0B 3). Everything the ride does rests on `walk`'s measurements; what is new is
-- the plan, made over the whole map grid (gBackupMapLayout, measured for `local_map`):
--   * a tile is open when it is inside the map, its collision bits are clear, its elevation is the
--     player's, it is not a ledge (behaviour 0x3B, which hopped two tiles going down), no character stands
--     on it, and it is not a warp unless it is the target. Other elevations and behaviours are not
--     measured as walkable or not, so the plan stays on the player's elevation and learns the rest;
--   * the cost is a tile a step plus TURN_COST a turn, so the route takes straight legs where it can, and
--     GRASS_COST more for a tile of behaviour 0x02 (every wild encounter so far began on one: route 0.16
--     four times, route 0.17 once) unless `cross_grass` is true, as with a Repel running;
--   * SIGHT_COST more for a tile an unbeaten trainer looks at (TRAINERS, above: every way it turns, as far
--     as it sees), and a trainer not loaded yet closes its template's tile, so a route enters a trainer's
--     line only where there is no other way; `route_in_sight` names each one the last plan had to cross;
--   * on the Mach Bike the last leg lets go by `walk`'s coast rule, and a last leg of 3 tiles or fewer is
--     reached by stopping at its corner first, since after a turn at speed the first tile reads 3 and
--     coasts three;
--   * a bump ends the ride at rest, marks the refused tile closed, and plans again (at most REPLANS times).
-- It stops for the same reasons `walk` does, and a warp or an edge that changes the map ends it too.
local TURN_COST, GRASS_COST, SIGHT_COST, REPLANS = 2, 8, 100, 8

local function planRoute(fromX, fromY, toX, toY, closed, crossGrass)
	local layout = r32(GMAPHEADER)
	if not inRom(layout) then return nil, "no map layout" end
	local mapW, mapH = r32(layout), r32(layout + 4)
	local gw, gh, gp = r32(GBACKUPMAPLAYOUT), r32(GBACKUPMAPLAYOUT + 4), r32(GBACKUPMAPLAYOUT + 8)
	if mapW < 1 or mapH < 1 or mapW > 512 or mapH > 512 or gw * gh > 262144 then return nil, "map size out of range" end
	if toX < 0 or toY < 0 or toX >= mapW or toY >= mapH then
		return nil, string.format("(%d,%d) is outside this map's %d by %d", toX, toY, mapW, mapH)
	end
	local grid = memory.read_bytes_as_array(gp, gw * gh * 2, BUS)
	local elevation = r8(playerObject() + 0x0B) & 0x0F
	local blocked, objects = {}, readObjects()
	for _, o in ipairs(objects) do blocked[o.y * mapW + o.x] = "character" end
	local trainers = unbeatenTrainers(objects)
	for _, t in ipairs(trainers) do
		if not t.loaded then blocked[t.y * mapW + t.x] = blocked[t.y * mapW + t.x] or "trainer" end
	end
	local seen = sightTiles(trainers, mapW, mapH)
	for _, w in ipairs(readWarps()) do
		if not (w.x == toX and w.y == toY) then blocked[w.y * mapW + w.x] = blocked[w.y * mapW + w.x] or "warp" end
	end
	for k, why in pairs(closed) do blocked[k] = why end
	-- nil when a tile is closed; otherwise the extra cost of stepping onto it.
	local function open(x, y)
		if x < 0 or y < 0 or x >= mapW or y >= mapH or blocked[y * mapW + x] then return nil end
		local i = ((x + MAP_OFFSET) + gw * (y + MAP_OFFSET)) * 2 + 1
		local v = grid[i] | (grid[i + 1] << 8)
		if (v & 0x0C00) ~= 0 or (v >> 12) ~= elevation then return nil end
		local behaviour = behaviourOf(v & 0x3FF)
		if behaviour == 0x3B then return nil end
		return ((behaviour == 0x02 and not crossGrass) and GRASS_COST or 0) + (seen[y * mapW + x] and SIGHT_COST or 0)
	end
	if not open(toX, toY) then
		return nil, string.format("(%d,%d) is not an open tile at elevation %d", toX, toY, elevation)
	end
	-- Dijkstra over (tile, facing) with a binary heap.
	local order = { DIRECTIONS.up, DIRECTIONS.down, DIRECTIONS.left, DIRECTIONS.right }
	local dist, prev, heap = {}, {}, {}
	local function push(cost, key)
		heap[#heap + 1] = { cost, key }
		local i = #heap
		while i > 1 do
			local parent = i // 2
			if heap[parent][1] <= heap[i][1] then break end
			heap[parent], heap[i] = heap[i], heap[parent]
			i = parent
		end
	end
	local function pop()
		local top = heap[1]
		local last = table.remove(heap)
		if #heap > 0 then
			heap[1] = last
			local i = 1
			while true do
				local l, r, m = i * 2, i * 2 + 1, i
				if l <= #heap and heap[l][1] < heap[m][1] then m = l end
				if r <= #heap and heap[r][1] < heap[m][1] then m = r end
				if m == i then break end
				heap[m], heap[i] = heap[i], heap[m]
				i = m
			end
		end
		return top
	end
	for di = 1, 4 do
		local key = (fromY * mapW + fromX) * 4 + di - 1
		dist[key] = 0
		push(0, key)
	end
	local goal
	while #heap > 0 do
		local item = pop()
		local cost, key = item[1], item[2]
		if cost == dist[key] then
			local tile, di = key // 4, key % 4 + 1
			local x, y = tile % mapW, tile // mapW
			if x == toX and y == toY then
				goal = key
				break
			end
			for ni = 1, 4 do
				local d = order[ni]
				local nx, ny = x + d.dx, y + d.dy
				local extra = open(nx, ny)
				if extra then
					local nkey = (ny * mapW + nx) * 4 + ni - 1
					local ncost = cost + 1 + extra + ((ni ~= di and cost > 0) and TURN_COST or 0)
					if dist[nkey] == nil or ncost < dist[nkey] then
						dist[nkey], prev[nkey] = ncost, key
						push(ncost, nkey)
					end
				end
			end
		end
	end
	if not goal then return nil, string.format("no open route from (%d,%d) to (%d,%d) at elevation %d", fromX, fromY, toX, toY, elevation) end
	-- Walk back to the start, then fold the steps into legs.
	local steps, key = {}, goal
	while prev[key] do
		table.insert(steps, 1, order[key % 4 + 1])
		key = prev[key]
	end
	local legs, x, y, inSight, named = {}, fromX, fromY, {}, {}
	for _, d in ipairs(steps) do
		x, y = x + d.dx, y + d.dy
		local t = seen[y * mapW + x]
		if t and not named[t] then
			named[t] = true
			inSight[#inSight + 1] = { trainer_local_id = t.local_id, trainer_at = { x = t.x, y = t.y }, first_tile = { x = x, y = y } }
		end
		local leg = legs[#legs]
		if leg and leg.d == d then
			leg.len, leg.endX, leg.endY = leg.len + 1, x, y
		else
			legs[#legs + 1] = { d = d, len = 1, endX = x, endY = y }
		end
	end
	return legs, inSight
end

game.programs["goto"] = function(p)
	local toX, toY = math.tointeger(p.x), math.tointeger(p.y)
	if not toX or not toY then return nil, "goto needs x and y, a tile on this map" end
	if not isVanilla then return nil, "goto is measured on the vanilla ROM only" end
	if not inOverworld() then return nil, "goto needs the overworld" end
	local run, crossGrass = p.run == true, p.cross_grass == true
	local phase, frames, idle, moved, replans = "rest", 0, 0, 0, 0
	local startMap, lastX, lastY, legs, li, mach, onFoot = nil, 0, 0, nil, 1, false, true
	local closed, towardWarp, legsTaken, inSight = {}, false, 0, {}
	local spotted = approachWatch()
	local function here()
		local sb1 = r32(SB1PTR)
		return string.format("%d.%d", r8(sb1 + 4), r8(sb1 + 5)), r16(sb1), r16(sb1 + 2)
	end
	local function finish(outcome, extra)
		local _, x, y = here()
		local r = { target = { x = toX, y = toY }, at = { x = x, y = y }, outcome = outcome, moved = moved,
			turns = legsTaken, replans = replans, route_in_sight = #inSight > 0 and inSight or nil }
		for k, v in pairs(extra or {}) do r[k] = v end
		return nil, true, r
	end
	local function hold()
		return { [legs[li].d.button] = true, B = (run and onFoot) or nil }
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

		if phase == "rest" then
			if not atRest() then
				if frames > REST_LIMIT then return finish("not_at_rest") end
				return nil, false
			end
			if x == toX and y == toY then return finish("done") end
			local flags = r8(GPLAYERAVATAR)
			mach, onFoot = (flags & MACH_BIKE_FLAG) ~= 0, (flags & ON_FOOT_FLAG) ~= 0
			local planned, why = planRoute(x, y, toX, toY, closed, crossGrass)
			if not planned then return finish(replans > 0 and "blocked" or "unreachable", { reason = why }) end
			inSight = why
			legs, li, phase, frames, idle, lastX, lastY = planned, 1, "hold", 0, 0, x, y
			towardWarp = false
			for _, w in ipairs(readWarps()) do
				towardWarp = towardWarp or (w.x == x + legs[1].d.dx and w.y == y + legs[1].d.dy)
			end
		end

		if phase == "coasting" then
			if x ~= lastX or y ~= lastY then
				moved = moved + math.abs(x - lastX) + math.abs(y - lastY)
				lastX, lastY, frames = x, y, 0
			end
			if atRest() then
				phase, frames = "rest", 0
				return nil, false
			end
			if frames > STEP_LIMIT then return finish("not_at_rest") end
			return nil, false
		end

		if phase == "refused" then
			if atRest() then
				local d = legs[li].d
				local layout = r32(GMAPHEADER)
				local mapW = inRom(layout) and r32(layout) or 0
				closed[(y + d.dy) * mapW + (x + d.dx)] = "refused"
				replans = replans + 1
				if replans > REPLANS then
					return finish("blocked", { blocked_by = describeTile(x + d.dx, y + d.dy) })
				end
				phase, frames = "rest", 0
			elseif frames > REST_LIMIT then
				return finish("not_at_rest")
			end
			return nil, false
		end

		-- hold: follow the legs.
		if x ~= lastX or y ~= lastY then
			moved = moved + math.abs(x - lastX) + math.abs(y - lastY)
			lastX, lastY, frames, idle = x, y, 0, 0
			if x == toX and y == toY then
				phase = "coasting"
				return nil, false
			end
			local turned = false
			if x == legs[li].endX and y == legs[li].endY and li < #legs then
				li, legsTaken, turned = li + 1, legsTaken + 1, true
			end
			local leg = legs[li]
			-- Not on a corner tile: letting go there would coast along the leg just finished.
			if mach and not turned then
				local dist = math.abs(leg.endX - x) + math.abs(leg.endY - y)
				local last = li == #legs
				local stopAtCorner = li == #legs - 1 and legs[#legs].len <= 3
				if last or stopAtCorner then
					local speed = r8(GPLAYERAVATAR + 0x0B)
					local nextSpeed = speed == 0 and 1 or 3
					if speed >= dist or nextSpeed + 1 > dist then
						phase = "coasting"
						return nil, false
					end
				end
			end
			towardWarp = false
			for _, w in ipairs(readWarps()) do
				towardWarp = towardWarp or (w.x == x + leg.d.dx and w.y == y + leg.d.dy)
			end
			return hold(), false
		end
		local b = memory.read_bytes_as_array(playerObject(), 0x18, BUS)
		local caughtUp = b[17] == b[21] and b[18] == b[22] and b[19] == b[23] and b[20] == b[24]
		local state = r8(GPLAYERAVATAR + 2)
		if state == 2 and caughtUp and (b[1] & 0x80) == 0 then
			phase, frames = "refused", 0
			return nil, false
		end
		if state == 0 then idle = idle + 1 end
		if towardWarp then
			if frames > DOOR_LIMIT then return finish("no_response") end
		elseif idle > IDLE_LIMIT or frames > PRESS_LIMIT then
			return finish("no_response")
		end
		return hold(), false
	end, nil, 7200
end

-- TEXT AND BATTLES AS ONE CALL (2026-09-16). A loop driven from outside took several round trips a
-- step, waited fixed times and ran out its budget in silence when it met a state it did not handle (the
-- user: "so i don't sit around waiting for several minutes"). These run in the driver a frame at a time,
-- press only when a measured state asks for it, keep a `log` of every message and choice, and stop
-- within seconds once nothing changes: after NUDGE_FRAMES with no change they press A once (a message
-- in a printer state not yet measured, like the 1 a trainer's last words read), a press that changes
-- nothing is let go and tried again later (the nurse's "for a few seconds" ignored A through its jingle),
-- and after NUDGES of either without a change they finish `stuck` with what they last saw.
local NUDGE_FRAMES, NUDGES, QUIET_FRAMES, PRESS_FRAMES, LOG_MAX = 180, 3, 90, 30, 200

-- The state a text or battle program watches for progress, as one string.
local function progressSignature()
	local d = (#hookNames > 0) and readDialogue() or nil
	-- The printer's pointer moves with every character (the text entry), so a box still printing is progress.
	local parts = { r32(GMAIN_CB2), battleAsking() or "-", d and d.state or "-", d and d.box or "-",
		d and r32(STEXTPRINTERS + d.window * PRINTER_SIZE) or "-", r8(ACTION_CURSOR), r8(MOVE_CURSOR) }
	if inBattle() then
		for i = 0, math.min(r8(BATTLERS_COUNT), 4) - 1 do parts[#parts + 1] = r16(BATTLE_MONS + i * BATTLE_MON_SIZE + 0x28) end
		-- The battle's script moving on, and the level-up box's own state, are progress too: an A that
		-- turned the box's page changed nothing else.
		parts[#parts + 1] = r32(BATTLESCRIPT_INSTR)
		parts[#parts + 1] = r8(LEVEL_UP_BOX_STATE)
	end
	return table.concat(parts, "|"), d
end

-- The usable move (PP left) with the most power times accuracy, as a 0-3 slot; the first with PP if
-- none does damage.
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

-- A text-and-choices machine shared by both programs. `choose(asking)` returns the target cursor for a
-- battle menu, or nil to stop there; `stopWhen(state)` returns an outcome to finish with, or nil.
local function textMachine(choose, stopWhen)
	local log, lastBox, signature, still, nudges = {}, nil, nil, 0, 0
	local pressing, held, settle, battleSeen, quiet, frames = nil, 0, 0, false, 0, 0
	local function note(entry)
		if #log < LOG_MAX then log[#log + 1] = entry end
	end
	local function finish(outcome, extra)
		local r = { outcome = outcome, log = log, frames = frames }
		for k, v in pairs(extra or {}) do r[k] = v end
		return nil, true, r
	end
	return function()
		frames = frames + 1
		local sig, d = progressSignature()
		if sig ~= signature then
			signature, still, nudges = sig, 0, 0
		else
			still = still + 1
		end
		if d and d.box ~= "" and d.box ~= lastBox then
			lastBox = d.box
			note({ text = d.box })
		end
		local battle = inBattle()
		battleSeen = battleSeen or battle

		local stop, extra = stopWhen({ battle = battle, battleSeen = battleSeen, dialogue = d })
		if stop then return finish(stop, extra) end

		if settle > 0 then
			settle = settle - 1
			return nil, false
		end

		-- A press under way: hold it until the thing it was for changes.
		if pressing then
			if pressing.done() then
				pressing, held, settle = nil, 0, 2
				return nil, false
			end
			held = held + 1
			if held > PRESS_FRAMES then
				-- Unanswered (a message that waits out a jingle ignores A): let go, look again later, and
				-- call it stuck only after NUDGES of these AND NUDGE_FRAMES with nothing changing -- an
				-- answered press can take longer than PRESS_FRAMES to show (the level-up box's last A: the
				-- next message printed 156 frames later).
				local what = pressing.what
				pressing, held, nudges, settle = nil, 0, nudges + 1, NUDGE_FRAMES // 2
				if nudges > NUDGES and still >= NUDGE_FRAMES then
					return finish("stuck", { waiting_on = what, signature = sig })
				end
				return nil, false
			end
			return pressing.pad, false
		end

		-- A battle menu waiting: move its cursor to the choice, then confirm.
		local asking = battle and battleAsking() or nil
		if asking then
			local target, label = choose(asking)
			if target == nil then return finish("needs_choice", { asking = asking, reason = label }) end
			local cursorAt = asking == "action" and ACTION_CURSOR or MOVE_CURSOR
			local cursor = r8(cursorAt)
			if cursor ~= target then
				local dir
				if target % 2 ~= cursor % 2 then
					dir = (target % 2 > cursor % 2) and "Right" or "Left"
				else
					dir = (target > cursor) and "Down" or "Up"
				end
				local from = cursor
				pressing = { what = asking .. " cursor " .. dir, pad = { [dir] = true },
					done = function() return r8(cursorAt) ~= from or battleAsking() ~= asking end }
				return pressing.pad, false
			end
			note({ chose = label, from = asking })
			pressing = { what = "confirm " .. label, pad = { A = true },
				done = function() return battleAsking() ~= asking end }
			return pressing.pad, false
		end

		-- The level-up box waiting on one of its pages.
		local page = battle and LEVEL_UP_BOX_WAITING[r8(LEVEL_UP_BOX_STATE)] or nil
		if page then
			local at = r8(LEVEL_UP_BOX_STATE)
			note({ level_up_box = page })
			pressing = { what = "the level-up box, " .. page, pad = { A = true },
				done = function() return r8(LEVEL_UP_BOX_STATE) ~= at end }
			return pressing.pad, false
		end

		-- A message waiting for a button. In a battle only the arrow counts: a battle message window reads
		-- "finished" while animations play.
		if d then
			local waiting = d.state == "waiting_for_button" or (not battle and d.state == "finished")
			if waiting then
				local box, state = d.box, d.state
				pressing = { what = "a message: " .. box, pad = { A = true },
					done = function()
						local now = readDialogue()
						return not now or now.box ~= box or now.state ~= state
					end }
				return pressing.pad, false
			end
		end

		-- Nothing asked for: let the game run, nudging if it stays still.
		if still >= NUDGE_FRAMES then
			if nudges >= NUDGES then
				return finish("stuck", { waiting_on = "no change after " .. nudges .. " A presses", signature = sig,
					dialogue = d })
			end
			nudges, still = nudges + 1, 0
			note({ nudged = sig })
			local before = sig
			pressing = { what = "a nudge", pad = { A = true }, done = function() return progressSignature() ~= before end }
			return pressing.pad, false
		end
		return nil, false
	end
end

-- battle {policy = "strongest" | "run"}: plays a battle to its end, a trainer's words before and after
-- included. "strongest" chooses FIGHT and the usable move with the most power times accuracy (move data,
-- measured against the summary); "run" chooses RUN and, on the move menu, backs out with B.
game.programs.battle = function(p)
	if not isVanilla then return nil, "battle is measured on the vanilla ROM only" end
	if #hookNames == 0 then return nil, "battle reads messages through the text hooks, which are off (AUTOPLAY_TEXT=0)" end
	local policy = p.policy or "strongest"
	if policy ~= "strongest" and policy ~= "run" then return nil, 'battle policy is "strongest" or "run"' end
	local outside = 0
	local machine = textMachine(function(asking)
		if asking == "action" then
			if policy == "run" then return 3, "RUN" end
			return 0, "FIGHT"
		end
		if policy == "run" then return nil, "on the move menu with policy run" end
		local slot = strongestMoveSlot()
		if slot == nil then return nil, "no move has PP left" end
		local id = r16(BATTLE_MONS + 0x0C + slot * 2)
		return slot, nameAt(MOVE_NAMES, MOVE_LEN, MOVE_COUNT, id) or ("move " .. id)
	end, function(st)
		if st.battle then
			outside = 0
			return nil
		end
		-- A script still running (a trainer walking over before its words, its words after) is not the end.
		if st.dialogue ~= nil or r8(SCRIPT_CONTEXT_STATUS) ~= SCRIPT_CONTEXT_OFF then
			outside = 0
			return nil
		end
		outside = outside + 1
		if outside >= QUIET_FRAMES and inOverworld() then
			if st.battleSeen then
				local save = readSave()
				return "ended", { outcome_raw = r8(BATTLE_OUTCOME), money = save and save.money,
					party = save and save.party and (function()
						local out = {}
						for _, m in ipairs(save.party) do out[#out + 1] = { species = m.species, level = m.level, hp = m.hp, max_hp = m.max_hp } end
						return out
					end)() }
			end
			return "no_battle"
		end
		return nil
	end)
	return machine, nil, 36000
end

-- advance_text: presses through the message on screen, box by box, and stops when it closes and stays
-- closed, when a menu opens (answer it with select), or when a battle begins (hand it to battle).
game.programs.advance_text = function(p)
	if not isVanilla then return nil, "advance_text is measured on the vanilla ROM only" end
	if #hookNames == 0 then return nil, "advance_text reads messages through the text hooks, which are off (AUTOPLAY_TEXT=0)" end
	local closed = 0
	local machine = textMachine(function() return nil, "a battle began" end, function(st)
		if st.battle then return "battle_started" end
		local m = readMenu()
		if m then return "menu_open", { menu = m } end
		if st.dialogue then
			closed = 0
			return nil
		end
		closed = closed + 1
		if closed >= QUIET_FRAMES then return "closed" end
		return nil
	end)
	return machine, nil, 7200
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
		battle_asking = o.battle and o.battle.asking or "none",
		battle_hp = o.battle and (function()
			local hp = {}
			for _, b in ipairs(o.battle.battlers) do hp[#hp + 1] = b.hp .. "/" .. b.max_hp end
			return table.concat(hp, " ")
		end)() or "none",
	}
end

-- Read every frame for events: a map or mode change, and a dialogue or menu opening or closing.
-- Nothing is decoded here.
function game.watch()
	local sb1 = r32(SB1PTR)
	local cb2 = r32(GMAIN_CB2)
	return {
		map = string.format("%d.%d", r8(sb1 + 4), r8(sb1 + 5)),
		mode = ((cb2 == CB2_OVERWORLD or cb2 == CB2_OVERWORLD + 1) and "overworld")
			or (isVanilla and (cb2 == BATTLE_MAIN_CB2 or cb2 == BATTLE_MAIN_CB2 + 1) and "battle") or "not_overworld",
		dialogue = (dialogue and windowOnScreen(dialogue.window)) and "open" or "closed",
		menu = (menuWindow and windowOnScreen(menuWindow)) and "open" or "closed",
		-- battle_input_changed: the battle starts or stops waiting for an action or a move.
		battle_input = isVanilla and (cb2 == BATTLE_MAIN_CB2 or cb2 == BATTLE_MAIN_CB2 + 1) and battleAsking() or "none",
	}
end

return game
