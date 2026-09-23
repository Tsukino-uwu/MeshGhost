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

-- The shared driver library the driver hands every game module (driver.lua: `text`, `route`).
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
-- The byte the build names sGlobalScriptContextStatus read 2 with no script running (before the step into
-- the line, after a warp, and 25 frames after the overworld came back from the battle), 0 on the frame the
-- trainer's approach began, and 0 or 1 from then through its words, the battle and its words after
-- (trainer_approach_probe.lua, 2026-09-17, three approaches and one whole battle). Other scripts -- a
-- character spoken to, a sign -- are not measured.
local SCRIPT_CONTEXT_STATUS, SCRIPT_CONTEXT_OFF = 0x03000e38, 2
-- The player's field controls locked, 0x03000f2c (written inline in textHooks.scriptRunning: this chunk is at Lua's
-- 200-local limit): 1 while a script holds the player (a message, a battle begun by one), 0 once
-- they walk. After escaping a ROCK SMASH rock's wild battle the context above stayed 1 with the player walking freely,
-- and `battle` waited it out and ended stuck; this byte read 0 there (2026-09-23, 0.26 (18,101), three runs).
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
-- Windows whose last print was instant (speed 0 or 255), which never touches the window's text printer: on the wall
-- clock's screen "Is this the correct time?" was drawn so into window 0 while its printer still held the finished
-- "Better set it and start it!" (2026-09-17). A finished printer there is not what the window shows.
local instantPrinted = {}
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
-- A new screen's windows: nothing printed or opened before belongs to any window id now.
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

-- A message already under way when the driver started looking (after a restore or a reload) never passes
-- through the hook, and a string of several boxes prints them all from one call: Birch's speech read as no
-- message after a restore while "Welcome to the world of" printed (2026-09-17). So with none known, a window
-- whose printer is active and on screen is taken up from the printer's own pointer; for a string in the ROM
-- its start is found by going back to the byte after the previous FF, and anywhere else the text starts at the
-- pointer. `recovered` marks it: its box index counts from wherever that start was.
--
-- A FINISHED message is taken up too (2026-09-17): restored at a trainer's challenge whose last box had printed, `battle`
-- saw no message at all and answered `stuck` after 601 frames. printer_state_probe.lua showed what one leaves: the
-- printer inactive, its pointer one past the string's FF, and the window still PUT on its background -- its first
-- cell holding its base block's tile and its last cell the block's last (the message box, base 0x194, 27 by 4: 194
-- and 1FF while RICK's words were up; 000 once the box closed, and 000 after a battle while the printer still held
-- "A got ₽64 for winning!"). The START menu's frame drew into window 0's top row with no message up, which the
-- top-row test alone would take for a box. The field message and a battle message each began at their buffer's
-- first byte (the build's gStringVar4 and gDisplayedStringBattle: RICK's challenge and his words after, "BUG CATCHER
-- RICK would like to battle!"), so a pointer in one reads from there, and a finished one only when that string ends
-- exactly at the pointer -- a stale pointer into a buffer since rewritten does not.
local TEXT_BUFFERS = { { at = 0x02021fc4, size = 1000 }, { at = 0x02022e2c, size = 300 } }

local function windowPut(w)
	local s = memory.read_bytes_as_array(GWINDOWS + w * WINDOW_SIZE, 8, BUS)
	local bg, left, top, width, height, base = s[1], s[2], s[3], s[4], s[5], s[7] | (s[8] << 8)
	if bg > 3 or width == 0 or height == 0 or left + width > 32 or top + height > 32 then return false end
	local map = 0x06000000 + ((memory.read_u16_le(0x04000008 + bg * 2, BUS) >> 8) & 0x1F) * 0x800
	local first = memory.read_u16_le(map + (top * 32 + left) * 2, BUS) & 0x3FF
	local last = memory.read_u16_le(map + ((top + height - 1) * 32 + left + width - 1) * 2, BUS) & 0x3FF
	return first == base & 0x3FF and last == (base + width * height - 1) & 0x3FF
end

-- Something drawn in a window: its pixel buffer (gWindows +8, 4 bits a pixel, 8 pixels a tile) holds more than one byte
-- value in its first 16 pixel rows. Put back on the screen after the naming keyboard, Birch's box was put for 7
-- frames with every byte 00 and then 11, while its printer still pointed past "What's your name?"; RICK's finished box
-- held 8 values (printer_state_probe.lua, 2026-09-17).
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
	-- A finished message is taken up only under the callback2s it was measured right on: the overworld's (RICK's box) and
	-- the routine the build names CB2_MainMenu (Birch's "Are you a boy? Or are you a girl?" restored at `ng_gender`). Restored
	-- on the starter bag, whose own text is an instant print, window 0 was put and drawn while its printer still pointed
	-- past the last field message, and "In my BAG! There's a POKé BALL!" read as the dialogue (2026-09-17).
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
					-- The pointer must lie inside the string read from the buffer's start, and a finished one at its end.
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
			(beh >= 0x38 and beh <= 0x3B) and " (a ledge: hopped two tiles walking into it its one way)" or "")
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

-- WHAT A MOVE'S TYPE DOES TO ITS DAMAGE (type_calc_probe.lua, the rescue battle from the snapshot `ng_rescue_move_menu`,
-- 2026-09-17; that adapter's MEASURED.md, "What a move's type does to its damage"). The 0x150 ROM bytes the build names
-- gTypeEffectiveness are triples -- the move's type, a defending type, a multiplier in tenths (20, 5 or 0) -- with FE FE 00
-- after the 108th and FF FF 00 at the end; all 289 pairs they make matched the Generation II-V type chart the user named as
-- the map. Read at the entry and the exit of the battle script command the build names Cmd_typecalc, the damage word was
-- multiplied by 1.5 when the move's type was one of the attacker's two type bytes (+0x21 and +0x22 of its gBattleMons
-- entry), then by the multiplier of each entry naming the move's type and one of the target's two type bytes, only once
-- when both read the same, the two entries after FE included. Ten trials with the target's type bytes written: x1, x1.5,
-- x0.5, x0 (NORMAL against GHOST, after FE), x6 (the bonus and two x2), x0.375, x0 either way round, x4, and x2 with x0.5 as
-- x1, each "It's super effective!", "It's not very effective…", "It doesn't affect" or no message as the flags said.
-- Both species' own type bytes (+6 and +7 of their 28-byte gSpeciesInfo entry) read what their battle entries held.
-- Not measured: an ability (the decomp names LEVITATE and WONDER GUARD in that command), FORESIGHT (which the decomp stops
-- at FE for), a move whose type changes, the physical and special split, weather, a double battle. One table, as the
-- module is at Lua's local ceiling (199 of 200 with it).
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

-- The multiplier a move of `moveType` meets against a target of types t1 and t2, as Cmd_typecalc applied it.
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
		m = { type = TYPE_CHART.name(e[3]), type_id = e[3], power = e[2], accuracy = e[4], base_pp = e[5], target = e[7],
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

-- TM AND HM COMPATIBILITY (2026-09-23): 8 bytes a species from the table the build's .sym names gTMHMLearnsets
-- (0x0831e898, 0xCE0 bytes), bit i for the move at entry i of sTMHMMoves (0x08616040, 58 u16 move ids): the 50 TMs, then
-- the 8 HMs. Returns the names of the moves the species can learn, the HMs' only with `hmOnly` (the user: catch spare
-- Pokémon for the HMs still needed, chosen by what each can learn). A global: this chunk is at Lua's local limit.
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

-- THE NAMING KEYBOARD (naming_probe.lua against captures of all three pages, 2026-09-17, vanilla, the new game's
-- "YOUR NAME?"; that adapter's MEASURED.md, "The naming keyboard"). While callback2 read the routine the build names
-- CB2_NamingScreen (+1), the pointer it names sNamingScreen held a block where: +0x1800 is the name so far, FF-ended
-- (A on H added C2, B took it off); +0x1E10 read 2 while keys were taken, 4 and 5 during a page swap, 3 for the 17
-- frames after the last letter, 6-9 once OK was chosen; +0x1E22 is the page -- 1 capitals, 2 small letters, 0
-- symbols, Select going 1, 2, 0, 1; +0x1E23 the cursor's sprite, whose data[0] and data[1] (+0x2E, +0x30 of a
-- 0x44-byte sprite) are its column and row (Right 0 to 1, Down 0 to 1); and the pointer at +0x1E28 leads to a template
-- whose +1 is how long the name may be (7, as drawn) and +8 points at the title. The column past a page's last one is
-- the buttons: Start put the cursor on it at row 2 (OK), and it also went there by itself after the seventh letter,
-- where the next A chose OK and closed the screen. The keys are the ROM's 0x60 bytes the build names sKeyboardChars,
-- three blocks of 4 rows of 8: block 1 read as the capitals page drew, block 0 the small letters and block 2 the
-- symbols (six columns: Left from its button column went to column 5), and each typed byte matched its key.
local CB2_NAMING_SCREEN, SNAMINGSCREEN, GSPRITES, SPRITE_SIZE = 0x080e4f58, 0x02039f94, 0x02020630, 0x44
local KEYBOARD_CHARS, KEYBOARD_READY = 0x0858be40, 2
local PAGE_BLOCK, PAGE_COLUMNS = { [0] = 2, [1] = 1, [2] = 0 }, { [0] = 6, [1] = 8, [2] = 8 }
local PAGE_NAMES, OK_ROW = { [0] = "symbols", [1] = "capitals", [2] = "small" }, 2

local keyboardKeys = nil -- per page, rows of { byte, glyph }
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

-- The keyboard's state, or nil when no naming screen is up.
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

-- THE WALL CLOCK (2026-09-17, vanilla, the new game's room from the snapshot `ng_clock`: `emerald/probes/task_probe.lua`
-- while Right and Left were held and A, Up and A pressed, against captures; that adapter's MEASURED.md, "The wall clock
-- screen" and "The wall clock set"). While callback2 read the routine the build names CB2_WallClock (+1), task 0 ran
-- the routine named Task_SetClock_HandleInput (+1) while the hands could be moved; A moved it to AskConfirm and then
-- HandleConfirmInput, with "Is this the correct time?" and a YES/NO whose cursor started on NO; YES moved it to
-- Confirmed and Exit, and callback2 went back to the overworld's 34 frames later. Its data words (s16 from the task's
-- +8): +4 the hours, 0 to 23 (0:59 went back to 23:59, 11:59 on to 12:00, and 13:00 drew 1:00 PM); +6 the minutes; +10
-- 0 on hours 0-11 with AM drawn and 1 from 12 with PM drawn; +8 2 while Right moved the hands and 1 while Left did,
-- 0 again with +12 once let go. A held direction moved one minute every 6 frames at first and one a frame once +12
-- passed 60, and the frame the direction was let go moved nothing more. The AM/PM sign turns over after the period
-- changes: one frame after `set_clock` answered 23:59, set from midnight, it still drew AM, and 14 frames after, PM. A toward the clock
-- once it was set went through the routine named CB2_ViewWallClock to the same callback2, with task 0 running
-- Task_ViewClock_WaitFadeIn and then HandleInput (+1 each), its words holding the time set (7, 30, 0) and 7:30 AM drawn.
-- One table, since this module's main chunk is at Lua's 200-local ceiling.
local CLOCK = { cb2 = 0x08134c9c, setting = 0x08134ce8, asking = 0x08134e30, periods = { [0] = "AM", [1] = "PM" },
	states = { [0x08134ce8] = "setting", [0x08134dc4] = "confirming", [0x08134e30] = "confirming",
		[0x08134ea4] = "closing", [0x08134ee8] = "closing", [0x08134f10] = "viewing", [0x08134f40] = "viewing" } }

-- The clock being set, or nil: its task's routine and data words.
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

-- THE STARTER BAG (2026-09-17, vanilla, the new game on Route 101 from the snapshot `ng_route101_facing_bag`:
-- `emerald/probes/task_probe.lua` while Left, Right, A and B were pressed, against captures; that adapter's MEASURED.md,
-- "The starter bag"). A on the bag took callback2 to the routine the build names CB2_StarterChoose (+1), and task 0 ran
-- Task_HandleStarterChooseInput (+1) while a ball could be chosen. Its data word 0 read 1 with TORCHIC labelled and the
-- hand on the bottom ball; Left made it 0 (TREECKO, the left ball) and Right from there 1 and then 2 (MUDKIP, the right
-- ball), each through two short routines and back within 2 frames; Left at 0 and Right at 2 changed nothing. The three
-- species are the u16s of the ROM table the build names sStarterMon, named from the species table: each name matched the
-- label drawn for its word. A moved the task on and "Do you choose this POKéMON?" came with a YES/NO the menu reader
-- already reads; B there went back to choosing with word 0 kept. One table, as the module is at Lua's local ceiling.
-- The two routines a move runs (the build's Task_MoveStarterChooseCursor and Task_CreateStarterLabel) held the new word 0
-- already, and a reader blind to them made `select` see the menu close mid-move.
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
-- The byte the build names gAnimScriptActive read 01 while a move's animation played and 00 between (battle_state_probe.lua,
-- RICK's battle from a snapshot, 2026-09-17): after "Foe WURMPLE used STRING SHOT!" it read 01 for 228 frames, four times,
-- then 01 for 75 more (the stat-change animation) before "MUDKIP's SPEED fell!" printed; nothing else the probe logs
-- changed in those frames, and an A pressed inside them changed nothing.
-- A BATTLER'S CONTROLLER AT WORK (battle_state_probe.lua, the rescue battle from the snapshot `ng_rescue_battle`, 2026-09-17;
-- that adapter's MEASURED.md, "A battle controller at work"): bit n of the u32 the build names gBattleControllerExecFlags was
-- set from the frame battler n's controller took a command until its routine (CONTROLLER_FUNCS, one per battler) was back
-- at the one it idles in. In the intro, battler 1's ran 218 frames (the routine the build names TryShinyAnimAfterMonAnim)
-- with nothing in `battle`'s signature changing, and it ended on the same frame with an A pressed inside it and with no
-- input at all: that A was `battle`'s nudge. Through the whole battle every stretch of 20 frames or more ended with no
-- button down, but for three routines: CompleteOnInactiveTextPrinter2 (a message on the player's side waiting on its arrow),
-- HandleInputChooseAction and HandleInputChooseMove (the menus). So a set bit is the game at work unless its battler's
-- routine is one of those; a wait for a button not measured yet is taken as work too, and is nudged after text.lua's longer
-- wait. One table, as the module is at Lua's local ceiling.
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
-- THE LEARN-A-MOVE QUESTION, THE MOVE LIST AND THE EVOLUTION SCENE (battle_state_probe.lua with its SUM and TASK lines, a
-- wild battle on 0.31 from the snapshot `learn_wild_battle_start` -- MUDKIP Lv 12 with its EXP written to 2534 through `exec`,
-- the made situation -- against captures `autoplay_learn_*`, 2026-09-17; that adapter's MEASURED.md, "The learn-a-move
-- question, the move list and the evolution scene"). The decomp was the map for every routine and field named here.
--   * In the battle: after "Delete a move to make room for BIDE?" the battle script's pointer stood at 0x082DABF4, whose byte
--     (5A) indexes the ROM table the build names gBattleScriptingCommandsTable to the routine it names Cmd_yesnoboxlearnmove
--     (+1); gBattleScripting +0x1F read 1 while the YES/NO waited, with the cursor in gBattleCommunication +1 (0 YES), and A
--     made it 2 and opened the list. The "Stop learning?" command (Cmd_yesnoboxstoplearningmove) in a battle is taken to wait
--     the same way, on the evolution scene's measurement below.
--   * The list: callback2 the routine the build names MainCB2 at 0x081BFAB4 (+1), task 0 running Task_HandleReplaceMoveInput
--     (+1), and at +0x40BC of the pointer sMonSummaryScreen: 3 (the mode), the party slot at +0x40BE, the move to learn at
--     +0x40C4 (0x75 BIDE, 0x155 MUD SHOT) and the cursor at +0x40C6, which Down moved 0 to 4: the four moves in the party's
--     slot order, then the move to learn, as drawn. A on 1 forgot GROWL; A on 3 forgot WATER GUN (slot 3 by then).
--   * The evolution: callback2 CB2_EvolutionSceneUpdate (0x0813E3A4, +1) with task 0 running Task_EvolutionScene (+1), its data
--     word 0 the scene's state: 0x0F waiting on "Congratulations! ... evolved into MARSHTOMP!" and its arrow, reached 900-odd
--     frames after "What? MUDKIP is evolving!" with no input; 0x16 while a move is replaced, data word 6 its step -- 1 and 2
--     the first two messages on their arrows, 3 the third printing, 4 the YES/NO waiting (cursor gBattleCommunication +1:
--     Down made it 1 and the capture drew No), 6 the list, 8 "Poof!". Data word 7 is where YES goes: 5 on "Delete a move to
--     make room for MUD SHOT?", 0x0B on "Stop learning MUD SHOT?" (after NO; NO there went back to the first message).
-- Not measured: an HM in the list ("can't be forgotten"), a party slot other than 0, the move list opened outside a battle.
local LEARN = { stateAt = 0x02024474 + 0x1F, cursorAt = 0x02024332 + 1, commands = 0x0831bd10,
	learnCmd = 0x0804e038, stopCmd = 0x0804e3c8, summaryCB2 = 0x081bfab4, summaryPtr = 0x0203cf1c, replaceInput = 0x081c174c,
	evoCB2 = 0x0813e3a4, evoLoadCB2 = 0x0813dd7c, evoTask = 0x0813e570, speciesInfo = 0x083203cc,
	-- The routine the build names Cmd_trygivecaughtmonnick: "Give a nickname to the captured X?" after a catch, its YES/NO
	-- waiting while gBattleCommunication +0 reads 1 -- the decomp as the map only: NOT measured, no catch made yet (2026-09-17).
	nicknameCmd = 0x08056bec }

-- The evolution scene's task data, or nil.
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

-- The options a learn-a-move question weighs: party slot `slot`'s moves in order, then `newMove`.
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

-- THE PARTY LIST A BATTLE'S BAG OPENS (2026-09-17, a wild TAILLOW on 0.31 from the snapshot `bag_wild_battle_start`, POTION x3
-- given; `exec` reads and captures `autoplay_battle_bag_*`; that adapter's MEASURED.md, "The bag inside a battle"). BAG from the
-- action menu opened the bag's list (read already, pocket `items`), A on POTION a USE/CANCEL menu (read already), and USE "Use on
-- which POKéMON?": callback2 the routine the build names CB2_UpdatePartyMenu (+1), task 0 running Task_HandleChooseMonInput
-- (+1), and byte 9 of the struct it names gPartyMenu 0 with the frame on MARSHTOMP, 7 with it on CANCEL after a Down, 0 again
-- after the next. Read as the party's nicknames in slot order, then CANCEL. Only a party of one is measured.
-- A MART'S QUANTITY BOX (2026-09-17, Slateport's Mart 9.13, `exec` reads against captures `autoplay_shop_*`; that adapter's
-- MEASURED.md, "A Mart"). After A on POTION in the buy list and "How many would you like?", a task ran the routine the build
-- names Task_BuyHowManyDialogueHandleInput (+1): its data word 1 read 1, then 2 and 3 after two Ups, with "x03 ₽900" drawn, and
-- word 5 read 13, POTION's id. The list's own task stayed active under it (and under the price question after), so the list
-- is not taken as the menu while this box or a message is up.
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

-- What battler 0's controller waits for: "action", "move", or nil for anything else.
-- A DOUBLE BATTLE (2026-09-23, TWINS GINA & MIA on 0.19, type flags 0x0D, battlers at positions 0-3): the player's second
-- Pokémon is battler 2, its menus run by its own routine (gBattlerControllerFuncs[2]) with its own cursors (the action and
-- move cursors are one byte a battler). After a move the target was chosen on the same screen, battler 0's routine the one
-- the build's .sym names HandleInputChooseTarget (0x08057824), gMultiUsePlayerCursor (0x03005d74) reading the targeted
-- battler (1, SEEDOT); A took it and "What will TAILLOW do?" followed. Returns what is asked and which battler asks.
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
		-- The two type bytes, one name when both read the same (TYPE_CHART, above).
		local types = { TYPE_CHART.name(b[0x22]) or string.format("type %d", b[0x22]) }
		if b[0x23] ~= b[0x22] then types[2] = TYPE_CHART.name(b[0x23]) or string.format("type %d", b[0x23]) end
		battlers[#battlers + 1] = { battler = i, position = pos, side = (pos == 0 and "player") or (pos == 1 and "opponent") or nil,
			species_id = u16of(b, 1), species = nameAt(SPECIES_NAMES, SPECIES_LEN, SPECIES_COUNT, u16of(b, 1)),
			nickname = decode(b, 49, last), level = b[43], hp = u16of(b, 41), max_hp = u16of(b, 45), types = types,
			moves = #moves > 0 and moves or nil,
			-- The ability, +0x20; its name from the table the build's .sym names gAbilityNames, 13 bytes a name (inline: this
			-- chunk is at Lua's 200-local limit).
			ability_id = b[0x21], ability = nameAt(0x0831b6db, 13, 256, b[0x21]), hm_moves = EMERALD_TMHM.canLearn(u16of(b, 1), true) }
	end
	-- The type flags read 0x04 in four wild battles and 0x0C against a trainer (one battle).
	local flags = r32(BATTLE_TYPE_FLAGS)
	return { asking = battleAsking(), kind = (flags & 0x08) ~= 0 and "trainer" or "wild", battlers = battlers,
		type_flags_raw = flags, outcome_raw = r8(BATTLE_OUTCOME) }
end

-- The menu the asking battler is choosing from (battler 2 in a double battle, DOUBLE BATTLE below), as `select` reads a
-- menu: `columns` 2, cursor order row by row.
local function battleMenu()
	local asking, battler = battleAsking()
	if asking == "action" then
		return { window = "battle_action", items = BATTLE_ACTIONS, cursor = r8(ACTION_CURSOR + battler), columns = 2 }
	elseif asking == "move" then
		-- The four move slots as the move menu drew them, "-" for an empty one.
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
		"set_clock", "cheat:noclip", "talk", "clear_obstacle" },
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
	shown, dialogue, menuWindow, instantPrinted = {}, nil, nil, {}
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
	local list = (isVanilla and not battle and not m and not d) and (LEARN.quantity() or readListMenu()) or nil
	m = m or list or (isVanilla and (STARTER.menu() or LEARN.partyMenu.read())) or nil
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
	-- A learn-a-move question, in a battle, on the move list or in the evolution scene (LEARN, above): its YES/NO or its list
	-- as the menu, with its kind and what each option weighs.
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

-- NOCLIP (cheat `noclip {on}`): the mechanism of `emerald/probes/noclip.lua`, kept in effect by the driver every frame
-- (game.tick) instead of by the dev loader. Around the player, every tile of the live grid with collision bits set has
-- them cleared, again each frame since the grid streams tiles in as the camera scrolls, except a tile whose metatile id
-- is 0x3FF, so the map's border still stops the player; and every other character is put on an odd elevation the player
-- is not on, so none blocks a step. Every tile and elevation changed is put back when noclip is turned off or the driver
-- unloads. A map change or a restored snapshot drops the record instead: the grid and the characters are rebuilt. Ledges,
-- one-way tiles and water are the probe's own limits (its water is open in emerald/UNVERIFIED.md). While it is on, the
-- driver says so in `persisting` and the core begins every run segment reached. One table, at the local ceiling.
local NOCLIP = { on = false, radius = 6, tiles = {}, elevations = {}, where = nil }

function NOCLIP.forget()
	NOCLIP.tiles, NOCLIP.elevations, NOCLIP.where = {}, {}, nil
end

-- Puts back what is still as noclip left it, and returns how many tiles and characters that was.
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
	-- Never elevation 0, which is compatible with every other (the probe's notes).
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
	-- A learn-a-move question is a menu too, for `select` (LEARN, above).
	local q = isVanilla and LEARN.question() or nil
	if q then return { kind = q.kind, items = q.menu.items, cursor = q.menu.cursor } end
	if isVanilla and inBattle() then return battleMenu() end
	local m = (#hookNames > 0) and readMenu() or nil
	local d = (#hookNames > 0) and readDialogue() or nil
	return m or (isVanilla and (LEARN.quantity() or (not d and readListMenu()) or STARTER.menu() or LEARN.partyMenu.read())) or nil
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

-- A held step refused, and held input doing nothing yet, from step_probe.lua (2026-09-16; `walk`, below): a bump
-- leaves the coordinates, the previous coordinate already equal to them, the avatar's +2 reading 2 and the object's
-- byte 0 top bit clear; +2 reads 0 while nothing is under way (1 turning, or a door opening).
-- One table, since this module's main chunk is at Lua's 200-local ceiling.
local STEP = {}
function STEP.refused()
	local b = memory.read_bytes_as_array(playerObject(), 0x18, BUS)
	local caughtUp = b[17] == b[21] and b[18] == b[22] and b[19] == b[23] and b[20] == b[24]
	return r8(GPLAYERAVATAR + 2) == 2 and caughtUp and (b[1] & 0x80) == 0
end
function STEP.idle() return r8(GPLAYERAVATAR + 2) == 0 end

-- WHY A STEP WAS REFUSED (2026-09-17, `walk` into each on map 0.18 with `probes/step_probe.lua` loaded; MEASURED.md, "Ledges,
-- water, and other maps read from the ROM"): a ledge (behaviour 0x3B, collision set) hopped going down and refused going up;
-- water (0x15, collision clear, elevation 1) refused a step on foot; a character on the tile and a collision tile refused
-- as `walk` measured them. The cause for a refused tile, from what describeTile read on it: `npc_in_way`, `one_way_edge`,
-- `missing_ability` (with the ability), `solid`, `off_map`, or `unknown` for anything else (another elevation not measured).
-- A ledge's one way, by behaviour: 0x3B down (above); 0x38 right, hopped from 0.27 (9,50) to (11,50) walking right and
-- refused walking left, collision set at elevation 0 (2026-09-23). 0x39 left and 0x3A up are the same family, not walked.
STEP.LEDGES = { [0x38] = "right", [0x39] = "left", [0x3A] = "up", [0x3B] = "down" }
function STEP.cause(t)
	if t.outside_map then return "off_map" end
	if t.character then return "npc_in_way" end
	if STEP.LEDGES[t.behaviour] then return "one_way_edge" end
	if t.behaviour == 0x15 and t.elevation == 1 and t.collision == 0 then return "missing_ability", "surf" end
	if t.collision ~= 0 then return "solid" end
	return "unknown"
end

-- On the Mach Bike, whether to let go now with `tiles` left: the step just begun carries on for +0x0B more tiles once
-- released, and holding one more raises it from 0 to 1, or from 1 to 3 (bike_probe.lua, 2026-09-16; `walk`, below).
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

-- A TRAINER COMING FOR THE PLAYER (trainer_approach_probe.lua, 2026-09-17, walking into RICK's line and a
-- goto routed into TIANA's): the byte the build names gNoOfApproachingTrainers went from 0 to 1 on the frame
-- after the step into the line began -- 16 frames before the player arrived -- and stayed 1 through the
-- approach; gSpecialVar_LastTalked read the trainer's local id (3, then 4) and the second byte of
-- gApproachingTrainers how many tiles away it stood (2 both times). Held input then does nothing, which
-- `walk` and `goto` used to report as `no_response`. What these read once a battle is over is not measured,
-- so a reading left over from before the program counts only once it has changed.
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

-- GOTO: the route planner and the ride are shared (`../route.lua`, moved out of this file on 2026-09-17); what they read
-- here is Emerald's, through the hooks below. Everything the ride does rests on `walk`'s measurements; the plan is made
-- over the whole map grid (gBackupMapLayout, measured for `local_map`):
--   * a tile is open when it is inside the map, its collision bits are clear, its elevation is the player's, no
--     character stands on it, and it is not a warp unless it is the target; a ledge (behaviour 0x3B, collision set) is
--     one way, crossed moving down, as it hopped, and never stood on (2026-09-17). Other elevations and behaviours are not measured as walkable or not, so the plan stays
--     on the player's elevation and learns the rest;
--   * tall grass is behaviour 0x02: every wild encounter so far began on one (route 0.16 four times, route 0.17 once);
--   * a tile an unbeaten trainer looks at is every way it turns, as far as it sees (TRAINERS, above), and a trainer not
--     loaded yet closes its template's tile;
--   * on the Mach Bike the last leg lets go by `walk`'s coast rule (STEP.machCoasts), and a last leg of 3 tiles or fewer is
--     reached by stopping at its corner first, since after a turn at speed the first tile reads 3 and coasts three.
-- The direction a warp you stand on is entered by (ENTERING A WARP, below).
-- Petalburg Woods' north exit (24.11 (14,5) and (15,5), behaviour 0x64) took no step onto it and warped on Up (2026-09-17).
local WARP_PRESS = { [0x62] = "right", [0x64] = "up", [0x65] = "down" }
-- MUD SLOPE (2026-09-17, 0.26 (17,36)-(17,37), behaviour 0xD0, below the player at (17,38)): `walk up 1` answered done,
-- moved 2, overshot 1, and left the player on (17,38) -- onto the slope and slid back. Two unattended sessions' trips looped
-- on it until stopped. The user: "you need a mach bike to go up the mud slides". Moving down one, and the bike on one, are
-- not measured: the plan on foot closes 0xD0 both ways.

local function routeGrid(fromX, fromY, toX, toY)
	local layout = r32(GMAPHEADER)
	if not inRom(layout) then return nil, "no map layout" end
	local mapW, mapH = r32(layout), r32(layout + 4)
	local gw, gh, gp = r32(GBACKUPMAPLAYOUT), r32(GBACKUPMAPLAYOUT + 4), r32(GBACKUPMAPLAYOUT + 8)
	if mapW < 1 or mapH < 1 or mapW > 512 or mapH > 512 or gw * gh > 262144 then return nil, "map size out of range" end
	local grid = memory.read_bytes_as_array(gp, gw * gh * 2, BUS)
	-- The player's level, the low nibble of the player object's +0x0B; each step's level is routeHooks.elevationStep's (LEVELS).
	local elevation = r8(playerObject() + 0x0B) & 0x0F
	local blocked, objects = {}, readObjects()
	-- A ROCK SMASH rock (graphics 86: the two on 0.26 at (18,101) and (19,100) that A, YES broke, 2026-09-17 and 09-23)
	-- is an obstacle, not a wall, while the party knows ROCK SMASH: the walk stops in front of it and `smash` breaks it.
	local smashes = false
	for _, mon in ipairs(readParty() or {}) do
		for _, m in ipairs(mon.moves or {}) do if m.name == "ROCK SMASH" then smashes = true end end
	end
	for _, o in ipairs(objects) do
		blocked[o.y * mapW + o.x] = (smashes and o.graphics_id == 86) and "smash" or "character"
	end
	local trainers = unbeatenTrainers(objects)
	for _, t in ipairs(trainers) do
		if not t.loaded then blocked[t.y * mapW + t.x] = blocked[t.y * mapW + t.x] or "trainer" end
	end
	local seen = sightTiles(trainers, mapW, mapH)
	for _, w in ipairs(readWarps()) do
		if not (w.x == toX and w.y == toY) then blocked[w.y * mapW + w.x] = blocked[w.y * mapW + w.x] or "warp" end
	end
	return {
		width = mapW, height = mapH, where = "from elevation " .. elevation, elevation = elevation,
		elevationAt = function(x, y)
			local i = ((x + MAP_OFFSET) + gw * (y + MAP_OFFSET)) * 2 + 1
			return (grid[i] | (grid[i + 1] << 8)) >> 12
		end,
		tile = function(x, y)
			if blocked[y * mapW + x] == "smash" then return true, false, nil, nil, "smash" end
			if blocked[y * mapW + x] then return nil end
			local i = ((x + MAP_OFFSET) + gw * (y + MAP_OFFSET)) * 2 + 1
			local v = grid[i] | (grid[i + 1] << 8)
			local behaviour = behaviourOf(v & 0x3FF)
			-- Water (0x15 at elevation 1) is not walked onto (WHY A STEP WAS REFUSED); a step's level is elevationStep's.
			if behaviour == 0x15 and (v >> 12) == 1 then return nil end
			-- A mud slope (0xD0) slid the player back on foot (MUD SLOPE, above): closed.
			if behaviour == 0xD0 then return nil end
			-- A ledge reads collision set, and hopped moving down: two steps, onto it and past it (WHY A STEP WAS REFUSED).
			if STEP.LEDGES[behaviour] then return true, false, seen[y * mapW + x], STEP.LEDGES[behaviour] end
			if (v & 0x0C00) ~= 0 then return nil end
			return true, behaviour == 0x02, seen[y * mapW + x]
		end,
	}
end

local routeHooks = {
	position = function()
		local sb1 = r32(SB1PTR)
		return string.format("%d.%d", r8(sb1 + 4), r8(sb1 + 5)), r16(sb1), r16(sb1 + 2)
	end,
	inOverworld = inOverworld,
	-- `walk`'s early stops: a trainer coming (A TRAINER COMING FOR THE PLAYER, above), a message or a menu on screen.
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
	refused = STEP.refused,
	idle = STEP.idle,
	ride = function(run)
		local flags = r8(GPLAYERAVATAR)
		local mach, onFoot = (flags & MACH_BIKE_FLAG) ~= 0, (flags & ON_FOOT_FLAG) ~= 0
		-- B only on foot: on the Acro Bike it is the wheelie button.
		-- MOUNTING (2026-09-23, Mauville): with the MACH BIKE (259) registered at SaveBlock1 +0x496, SELECT on 0.2 mounted it,
		-- and in the bike shop 10.1 it printed "DAD's advice… there's a time and place for everything!". The map header's byte
		-- +0x1A (gMapHeader's copy) read 0x0D on 0.2, 0.0, 0.16 and 0.27, 0x0F in cave 24.14, 0 in 10.1, 10.5 and 4.1: bit 0 set
		-- where the bike went. So a run on foot mounts first where the bike is registered and bit 0 is set (the user: the
		-- MACH BIKE is the preferred one, it goes faster).
		local mount = run and onFoot and r16(r32(SB1PTR) + 0x496) == 259 and (r8(0x02037318 + 0x1A) & 1) == 1
		return { buttons = { B = (run and onFoot) or nil }, coast = mach and STEP.machCoasts or nil, shortLeg = mach and 3 or nil,
			mount = mount and "Select" or nil }
	end,
	routeGrid = routeGrid,
	warps = readWarps,
	-- ENTERING A WARP (2026-09-17, the new game's truck, house and town, `walk` and `observe`'s warps): stairs
	-- (behaviour 0x60) warped on the step onto them; the truck's door (0x62) and the house's door mat (0x65)
	-- only when the player, standing on them, pressed right and down; a town door (0x69, collision set) is
	-- walked up into from the tile below it (a Pokémon Center's, 2026-09-16). So a goto to a warp goes onto it,
	-- or below a door, and holds that direction until the map changes.
	-- A warp entered by a press on it is stepped onto from rest: from the new game's truck (snapshot `ng_truck_fast`, the
	-- door open), a held walk right 2 bumped at the door (4,2) after one tile, and two walks of 1 each landed on it
	-- (2026-09-17). So the ride lets go one tile short, comes to rest, and takes the last step alone.
	enterWarp = function(w)
		if w.behaviour == 0x69 then return { dy = 1, press = "up" } end
		if WARP_PRESS[w.behaviour] then return { press = WARP_PRESS[w.behaviour], fromRest = true } end
		return nil
	end,
	blockedBy = describeTile,
	limits = { rest = REST_LIMIT, idle = IDLE_LIMIT, press = PRESS_LIMIT, door = DOOR_LIMIT, step = STEP_LIMIT },
	-- ANY MAP FROM THE ROM (2026-09-17, `exec` on map 0.18; MEASURED.md, "Ledges, water, and other maps read from the ROM"):
	-- gMapGroups (0x08486578 in the build's .sym) is a pointer per group to a pointer per map to its ROM header, and that
	-- header's 28 bytes read the same as gMapHeader's copy. The header's layout (+0) holds width, height and at +0x0C the
	-- map data, which read equal to the live grid on all 1760 tiles of 0.18; the connections (+0x0C: count, list of 12-byte
	-- entries) and warps are read as the adapter and `readWarps` measured them. A map is taken only when its header, layout
	-- and events point into the ROM and its size is 1-512.
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
-- A connection's direction byte: 1 south, 2 north, 3 west, 4 east (the adapter's seams, 2026-08-20).
routeHooks.connectionDirections = { [1] = "down", [2] = "up", [3] = "left", [4] = "right" }
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
		end
	end
	-- A warp's +5 is the destination's warp number, from 0: through 0.10's Center door (+5 0) the player arrived on 2.2's
	-- warp 0 at (7,8), and out through that (+5 2) on 0.10's warp 2 at (6,16) (2026-09-17). +4 read 3 on 2.2's mats, which
	-- read elevation 3, and 0 or 4 elsewhere (not used).
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
	routeHooks.maps[name] = { width = w, height = h, exits = exits, warps = warps }
	return routeHooks.maps[name]
end
-- Any map's tile from the ROM: collision, elevation and behaviour, through that layout's own tilesets (as behaviourOf reads
-- the current one's).
-- The map the player stands on is read from the live grid instead: a script changes its tiles. In WATTSON's gym (10.0)
-- after its four switches, 20 tiles read differently -- the barriers collision set in the ROM's layout (0628) and clear
-- in the live grid (0238), the switches 3205 against 3206 -- and a trip from the floor to the Center answered "no way on
-- foot" (2026-09-17, `exec` from `story_dynamo_badge`). The current map's name is read once a frame.
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
-- LEVELS (2026-09-17). Measured before: the house's mats and stairs (0) were walked onto from 3 and walked off onto 3;
-- Petalburg's gym floor read 0 all round and was walked from its mats at 3. The rest is the decomp as the map (the routines
-- the build names IsElevationMismatchAt and ObjectEventUpdateElevation): a step is taken when the player's level is 0 or the
-- tile's is 0, 15 or the same; the level then becomes the tile's, unless the tile stepped from or onto is 15. Built after
-- Route 110 (0.25), whose ground at 3 and at 1 meets through 0s, had no route under the one-level plan.
routeHooks.elevationStep = function(level, tileLevel, fromLevel)
	if not tileLevel then return nil end
	if level ~= 0 and tileLevel ~= 0 and tileLevel ~= 15 and tileLevel ~= level then return nil end
	if tileLevel == 15 or fromLevel == 15 then return level end
	return tileLevel
end
routeHooks.playerElevation = function() return r8(playerObject() + 0x0B) & 0x0F end
-- A tile of any map for the plan across maps, on foot: a ledge (0x3B) one way down, collision set closed, water (behaviour
-- 0x15 at elevation 1) closed (WHY A STEP WAS REFUSED); otherwise its elevation. Every elevation-1 tile was closed until
-- 2026-09-17, when Route 110 (0.25) and DEWFORD's gym floor, both walked, read elevation 1 on land and `goto` found no way
-- across them. Water of other behaviours is not measured.
routeHooks.mapTile = function(name, x, y)
	local collision, elevation, behaviour = routeHooks.mapTileRaw(name, x, y)
	if not collision then return nil end
	if STEP.LEDGES[behaviour] then return elevation, STEP.LEDGES[behaviour] end
	if collision ~= 0 or (elevation == 1 and behaviour == 0x15) or behaviour == 0xD0 then return nil end
	return elevation
end

-- clear_obstacle {}: the ROCK SMASH rock beside the player (the one a goto answered `obstacle` in front of) faced, A, and its
-- text to the YES/NO, by `talk`'s own walk-face-tap; `select` YES and `advance_text` then break it (route.md, 0.26).
game.programs.clear_obstacle = function()
	local _, x, y = routeHooks.position()
	for _, o in ipairs(readObjects()) do
		if o.graphics_id == 86 and math.abs(o.x - x) + math.abs(o.y - y) == 1 then
			return game.programs.talk({ local_id = o.local_id })
		end
	end
	return nil, "no ROCK SMASH rock (graphics 86) beside the player"
end

-- goto {x, y, run, cross_grass}: to a tile on this map by a planned route (`../route.lua`).
game.programs["goto"] = function(p)
	if not isVanilla then return nil, "goto is measured on the vanilla ROM only" end
	if p.map ~= nil and p.map ~= (routeHooks.position()) then return lib.route.travel(routeHooks, p) end
	return lib.route.go(routeHooks, p)
end

-- TEXT AND BATTLES AS ONE CALL: the machine that decides when to press is shared (`../text.lua`, moved out of this
-- file on 2026-09-17); what it reads here is Emerald's, through the hooks below.

-- The state a text or battle program watches for progress, as one string.
local function progressSignature()
	local d = (#hookNames > 0) and readDialogue() or nil
	-- The printer's pointer moves with every character (the text entry), so a box still printing is progress.
	-- The player's coordinates too: a cutscene walks the player between its messages (Route 101's, 2026-09-17).
	local sb1 = r32(SB1PTR)
	local parts = { r32(GMAIN_CB2), battleAsking() or "-", d and d.state or "-", d and d.box or "-",
		d and r32(STEXTPRINTERS + d.window * PRINTER_SIZE) or "-", r8(ACTION_CURSOR), r8(MOVE_CURSOR),
		inEwram(sb1) and r16(sb1) or "-", inEwram(sb1) and r16(sb1 + 2) or "-" }
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

-- battle policy "effective": the usable move with the most power times accuracy times the type multiplier against the
-- opponent (position 1, the only one measured) times the same-type bonus -- what Cmd_typecalc did to the damage word
-- (TYPE_CHART, above); the first with PP when none scores above 0. Returns the slot, the move's name, and what each usable
-- move weighed, for the battle's log.
function TYPE_CHART.effectiveMove()
	local mons = memory.read_bytes_as_array(BATTLE_MONS, BATTLE_MON_SIZE * 4, BUS)
	local positions = memory.read_bytes_as_array(BATTLER_POSITIONS, 4, BUS)
	-- DOUBLE BATTLE (above): the moves of the battler whose menu is up, weighed against each foe standing (positions 1
	-- and 3); the best pair wins and its foe is the aim `battle` takes at the target step. A move that also hits the
	-- partner (the move's target byte 0x20) scores 0 while the partner stands (the user, 2026-09-23: attack the two foes,
	-- not your own Pokémon); SURF and GROWL read 8 (both foes), PECK and MUD SHOT 0 (one), self moves 16.
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
	-- The user, 2026-09-17, after MUD SHOT at x0.5 (scored above TACKLE) lost to MAY's TREECKO: "its bad to use ineffective
	-- moves, they deal less damage". So a move the foe resists (multiplier below 1) is chosen only when no unresisted move
	-- scores above 0.
	local best, bestScore, bestResisted, bestFoe, weighed, against, guard = nil, nil, true, nil, {}, nil, nil
	for _, fi in ipairs(foes) do
		local foe = fi * BATTLE_MON_SIZE
		local foe1, foe2 = mons[foe + 0x22], mons[foe + 0x23]
		-- The user, 2026-09-23: a foe with WONDER GUARD "can only be damaged by super effective moves and nothing else", so
		-- against one every other move scores 0. Not met in a battle yet; the ability's name is read as `battle` reads it.
		local wonderGuard = nameAt(0x0831b6db, 13, 256, mons[foe + 0x21]) == "WONDER GUARD"
		for k = 0, 3 do
			local id, pp = u16of(mons, me + 13 + k * 2), mons[me + 37 + k]
			if id ~= 0 and pp > 0 then
				local info = moveInfo(id)
				local same = info.type_id == own1 or info.type_id == own2
				local multiplier = info.type_id and TYPE_CHART.multiplier(info.type_id, foe1, foe2) or 1
				local score = (info.power or 0) * (info.accuracy or 0) * (same and TYPE_CHART.sameTypeBonus or 1) * multiplier
				if wonderGuard and multiplier <= 1 then score = 0 end
				if partnerUp and info.target == 0x20 then score = 0 end
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
	-- Both battle menus are grids of two columns, their cursors at ACTION_CURSOR and MOVE_CURSOR.
	battleMenu = function()
		local asking, battler = battleAsking()
		if not asking then return nil end
		if asking == "target" then return asking, { cursor = r8(0x03005d74), battler = battler } end
		return asking, { cursor = r8((asking == "action" and ACTION_CURSOR or MOVE_CURSOR) + battler), columns = 2, battler = battler }
	end,
	-- The foe the last effectiveMove weighed best (DOUBLE BATTLE), for the target step.
	effectiveTarget = function() return BATTLE_BUSY.aim end,
	scriptRunning = function() return r8(SCRIPT_CONTEXT_STATUS) ~= SCRIPT_CONTEXT_OFF and r8(0x03000f2c) ~= 0 end,
	inOverworld = inOverworld,
	-- The starter bag has no window: advance_text stops menu_open on it, for select.
	-- The bag's list too: `battle` on the bag opened from a battle answered `stuck` without it (2026-09-17).
	-- A Mart's quantity box first, and the list only with no message up (A MART'S QUANTITY BOX).
	readMenu = function()
		return readMenu() or (isVanilla and (LEARN.quantity() or (not readDialogue() and readListMenu()) or STARTER.menu()
			or LEARN.partyMenu.read())) or nil
	end,
	-- FIGHT is the action menu's 0 and RUN its 3 (BATTLE_ACTIONS).
	actionIndex = { fight = 0, run = 3 },
	levelUpPage = function()
		local at = r8(LEVEL_UP_BOX_STATE)
		return LEVEL_UP_BOX_WAITING[at], at
	end,
	-- A move's animation, or a battler's controller at work (BATTLE_BUSY, above).
	animationPlaying = BATTLE_BUSY.playing,
	-- The learn-a-move questions and the move list, and the evolution scene playing by itself (LEARN, above).
	battleQuestion = LEARN.question,
	-- Battler 0's HP and max HP (BATTLE_MONS +0x28, +0x2C; the player's in every single battle measured).
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
	-- The type flags' 0x08 read set against a trainer and clear in wild battles (BATTLES, readBattle).
	battleKind = function() return (r32(BATTLE_TYPE_FLAGS) & 0x08) ~= 0 and "trainer" or "wild" end,
	-- WALLY's catching battle in Petalburg's gym (2026-09-17): the type flags read 0x204 against 0x04 in four wild battles, and
	-- the bag's USE/CANCEL that `battle` stopped on went on by itself, with no input, to "Gotcha! RALTS was caught!".
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

-- battle {policy = "strongest" | "effective" | "run"}: plays a battle to its end, a trainer's words before and after
-- included. "strongest" chooses FIGHT and the usable move with the most power times accuracy (move data,
-- measured against the summary); "effective" weighs that by the type chart and the same-type bonus (TYPE_CHART); "run"
-- chooses RUN.
game.programs.battle = function(p)
	if not isVanilla then return nil, "battle is measured on the vanilla ROM only" end
	if #hookNames == 0 then return nil, "battle reads messages through the text hooks, which are off (AUTOPLAY_TEXT=0)" end
	return lib.text.battle(textHooks, p)
end

-- advance_text: presses through the message on screen, box by box, and stops when it closes and stays
-- closed, when a menu opens (answer it with select), or when a battle begins (hand it to battle).
game.programs.advance_text = function()
	if not isVanilla then return nil, "advance_text is measured on the vanilla ROM only" end
	if #hookNames == 0 then return nil, "advance_text reads messages through the text hooks, which are off (AUTOPLAY_TEXT=0)" end
	return lib.text.advanceText(textHooks)
end

-- talk {local_id}: to a tile beside the character, facing it, A, and advance_text (`../route.lua`'s M.talk). The player
-- object's +0x18 low nibble read 1 after a walk down, 2 up, 3 left and 4 right (2026-09-17, `walk` and `goto` on 0.18); a
-- script has the controls while the script context status is not SCRIPT_CONTEXT_OFF.
-- A character not loaded yet (off-screen: ROXANNE at 11.3 (5,2), talked to from the gym's door) comes from its template,
-- as unbeaten trainers do; on arrival `talk` reads the loaded one again. A template's hide flag is not read.
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
-- A Center's counter: behaviour 0x80, collision set, elevation 0 at 8.4 (7,3); from (7,4) facing up, A opened the nurse's
-- "Hello, and welcome to the POKéMON CENTER." with her at (7,2) (2026-09-17).
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

-- type_text {text, confirm}: types on the naming keyboard (THE NAMING KEYBOARD, above) the way a player does. B until
-- nothing is typed; then for each character Select until a page holding it shows, a direction one step at a time until
-- the cursor is on its key, and A -- each press let go after TAP frames and the next waiting until the game's own bytes
-- show the last one landed, and none while the screen is not taking keys. The typed byte is read back against the key's.
-- With confirm, Start and A on OK; without, nothing after the last letter, since after the seventh the cursor had gone
-- to OK by itself and an A there confirmed.
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
	-- Where a character's key is on a page, or nil.
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

-- set_clock {hours, minutes, confirm}: sets the wall clock (THE WALL CLOCK, above) the way a player does. Right or Left,
-- whichever way round the dial is shorter, is held while the minutes read short of the time and let go on the frame
-- they read it -- the frame a direction was let go moved nothing more -- and a time passed is gone back to the other
-- way. Nothing is pressed while the hands still turn. With confirm (the default), A, Up to YES and A, and it answers
-- once callback2 has left the clock.
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
