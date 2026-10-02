-- The autoplay module for vanilla Pokémon Crystal V1.0 (a dev tool, never shipped). Addresses come from our pokecrystal
-- build, whose .gbc hashes identical to the ROM; what each byte means was measured on the running game, and a byte
-- whose meaning is not measured goes out raw under `extras`, never named.

-- The library the driver hands every game module: `text`, `route` and `select`.
local lib = ...

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local function u8(a) return memory.read_u8(a, "WRAM") end
local function rom8(bank, ptr) return memory.read_u8(bank * 0x4000 + (ptr - 0x4000), "ROM") end

-- The vanilla V1.0 ROM's SHA-1, as gameinfo.getromhash() returns it.
local VANILLA_SHA1 = "F4CD194BDEE0D04CA4EAC29E09B8E4E9D818C133"
local romHash = (function()
	local ok, h = pcall(gameinfo.getromhash)
	return ok and type(h) == "string" and h:upper() or ""
end)()
local isVanilla = romHash == VANILLA_SHA1

-- wXCoord/wYCoord change on the frame a step ends. The overworld is wMapStatus 2 with sprite updates on (off while a
-- full-screen menu such as the PACK fills the screen).
local W_MAPGROUP, W_MAPNUMBER, W_YCOORD, W_XCOORD = flat(0xDCB5), flat(0xDCB6), flat(0xDCB7), flat(0xDCB8)
local W_MAPSTATUS, W_SPRITEUPDATES, W_BATTLEMODE = flat(0xD432), flat(0xC2CE), flat(0xD22D)
local MAPSTATUS_WARPING, MAPSTATUS_RUNNING = 1, 2
local W_SCRIPT_RUNNING, SCRIPT_TOOK_OVER = flat(0xD438), 255 -- wScriptMode is the byte before it
-- A trainer's sight (see `walk`): wScriptRunning 1, the trainer's map object in hLastTalked, its distance in D03F.
local SCRIPT_SEEN_BY_TRAINER, H_LAST_TALKED, W_SEEN_TRAINER_DISTANCE = 1, 0xFFE0, flat(0xD03F)
-- The player's object, 0x28 bytes: +0x08 the facing, +0x10/+0x11 the tile a step is going to, plus 4.
local PLAYER_STRUCT = flat(0xD4D6)
local FACING = { [0x00] = "down", [0x04] = "up", [0x08] = "left", [0x0C] = "right" }

-- The map's warp list: a count and a pointer into wMapScriptsBank, 5 bytes an entry: y, x, the destination's warp
-- number counted from 1, its map group and number.
local W_WARP_COUNT, W_WARP_PTR, W_MAP_SCRIPTS_BANK = flat(0xDBFB), flat(0xDBFC), flat(0xD1A3)

local function inOverworld()
	return u8(W_MAPSTATUS) == MAPSTATUS_RUNNING and u8(W_SPRITEUPDATES) == 1
end

-- A tile's collision byte: its quadrant of its block in wOverworldMapBlocks, which holds 3 blocks of border each side,
-- looked up in the loaded tileset's collision table.
local W_MAPHEIGHT, W_MAPWIDTH, W_BLOCKS, W_TILESET = flat(0xD19E), flat(0xD19F), flat(0xC800), flat(0xD1D9)
local VIEW_W, VIEW_H = 7, 5 -- tiles either side: 15 by 11, more than the screen's 10 by 9
-- What a collision byte did when stepped into, where measured. Anything else is listed by number.
local COLLISION_NOTES = {
	[0x07] = "a step refused (roofs, walls, signs)",
	[0x29] = "water: a step on foot refused",
	[0x71] = "a door: stepping on it warped",
	[0x15] = "a step refused (drawn as trees, New Bark's south edge)",
	[0x18] = "tall grass: walked on; a wild battle began on the 4th step in it (Route 29)",
	[0xA0] = "a ledge: hopped going right", [0xA1] = "a ledge: hopped going left", [0xA3] = "a ledge: hopped going down",
}
local collisionCache = {}

-- A tile's block id and collision byte, or nil outside the block buffer.
local function tileAt(x, y)
	local w, h = u8(W_MAPWIDTH), u8(W_MAPHEIGHT)
	local bx, by = x // 2, y // 2
	if bx < -3 or by < -3 or bx >= w + 3 or by >= h + 3 then return nil end
	local bank, ptr = u8(W_TILESET + 6), u8(W_TILESET + 7) | (u8(W_TILESET + 8) << 8)
	if ptr < 0x4000 or ptr > 0x7FFF then return nil end
	local block = u8(W_BLOCKS + (by + 3) * (w + 6) + (bx + 3))
	local key = bank * 0x10000 + ptr
	if collisionCache.key ~= key then collisionCache = { key = key } end
	local c = collisionCache[block]
	if not c then
		c = memory.read_bytes_as_array(bank * 0x4000 + (ptr - 0x4000) + block * 4, 4, "ROM")
		collisionCache[block] = c
	end
	return block, c[(y % 2) * 2 + (x % 2) + 1]
end

-- The other characters: object records 1-12 whose graphic (+0x00) is not 0, read with the player's own codes.
local W_OBJECTS, OBJ_SIZE, OBJ_COUNT = flat(0xD4D6), 0x28, 13

-- Map-object records, 0x10 bytes each, indexed by an object record's +0x01: +0x08's low nibble 2 marks a trainer, +0x09
-- is its range, and +0x0A points into wMapScriptsBank at its defeat flag, a bit of wEventFlags.
local W_MAP_OBJECTS, MAP_OBJ_SIZE, W_EVENT_FLAGS = flat(0xD71E), 0x10, flat(0xDA72)
local MAPOBJ_TYPE_TRAINER = 2

-- A map object's trainer reading, or nil when its record is not a trainer's.
local function trainerOf(mapObject)
	if mapObject > 15 then return nil end
	local r = memory.read_bytes_as_array(W_MAP_OBJECTS + mapObject * MAP_OBJ_SIZE, MAP_OBJ_SIZE, "WRAM")
	if (r[9] & 0x0F) ~= MAPOBJ_TYPE_TRAINER then return nil end
	local t = { range = r[10] }
	local ptr = r[11] | (r[12] << 8)
	if ptr >= 0x4000 and ptr <= 0x7FFE then
		local bank = u8(W_MAP_SCRIPTS_BANK)
		local flag = rom8(bank, ptr) | (rom8(bank, ptr + 1) << 8)
		t.flag = flag
		t.beaten = ((u8(W_EVENT_FLAGS + (flag >> 3)) >> (flag & 7)) & 1) == 1
	end
	return t
end

local function readObjects()
	local out = {}
	for s = 1, OBJ_COUNT - 1 do
		local b = memory.read_bytes_as_array(W_OBJECTS + s * OBJ_SIZE, 0x12, "WRAM")
		if b[1] ~= 0 then
			out[#out + 1] = { slot = s, map_object = b[2], graphics_id = b[1], x = b[17] - 4, y = b[18] - 4,
				facing = FACING[b[9]], facing_raw = not FACING[b[9]] and b[9] or nil, movement_type_raw = b[4],
				trainer = trainerOf(b[2]) }
		end
	end
	return out
end

-- The map's bg events (signs), 5 bytes each: y, x, a kind and a script pointer.
local W_BG_COUNT, W_BG_PTR = flat(0xDC01), flat(0xDC02)

local function mapName()
	return string.format("%d.%d", u8(W_MAPGROUP), u8(W_MAPNUMBER))
end

local function modeName()
	if not isVanilla then return "not_overworld" end
	if u8(W_BATTLEMODE) ~= 0 then return "battle" end
	return inOverworld() and "overworld" or "not_overworld"
end

local function readWarps()
	local out, n = {}, u8(W_WARP_COUNT)
	local bank, ptr = u8(W_MAP_SCRIPTS_BANK), u8(W_WARP_PTR) | (u8(W_WARP_PTR + 1) << 8)
	if ptr < 0x4000 or ptr > 0x7FFF then return out end
	for i = 0, math.min(n, 32) - 1 do
		local at = ptr + i * 5
		local x, y = rom8(bank, at + 1), rom8(bank, at)
		local _, collision = tileAt(x, y)
		out[#out + 1] = { x = x, y = y, collision_raw = collision,
			to = string.format("%d.%d", rom8(bank, at + 3), rom8(bank, at + 4)), to_warp = rom8(bank, at + 2) }
	end
	return out
end

local function readSigns()
	local out, n = {}, u8(W_BG_COUNT)
	local bank, ptr = u8(W_MAP_SCRIPTS_BANK), u8(W_BG_PTR) | (u8(W_BG_PTR + 1) << 8)
	if ptr < 0x4000 or ptr > 0x7FFF then return out end
	for i = 0, math.min(n, 32) - 1 do
		out[#out + 1] = { x = rom8(bank, ptr + i * 5 + 1), y = rom8(bank, ptr + i * 5), kind_raw = rom8(bank, ptr + i * 5 + 2) }
	end
	return out
end

-- Rows of characters centred on the player, and a legend for the symbols that appear.
local function readLocalMap(warps, objects, signs)
	local px, py = u8(W_XCOORD), u8(W_YCOORD)
	local mapW, mapH = u8(W_MAPWIDTH) * 2, u8(W_MAPHEIGHT) * 2
	local marks = {}
	for _, s in ipairs(signs) do marks[s.x * 256 + s.y] = "S" end
	for _, w in ipairs(warps) do marks[w.x * 256 + w.y] = "W" end
	-- An unbeaten trainer's line: its range of tiles the way it faces now.
	for _, o in ipairs(objects) do
		local t = o.trainer
		if t and not t.beaten and o.facing then
			local d = ({ down = { 0, 1 }, up = { 0, -1 }, left = { -1, 0 }, right = { 1, 0 } })[o.facing]
			for k = 1, t.range do
				local x, y = o.x + d[1] * k, o.y + d[2] * k
				if x >= 0 and y >= 0 then marks[x * 256 + y] = "!" end
			end
		end
	end
	for _, o in ipairs(objects) do
		if o.x >= 0 and o.y >= 0 then marks[o.x * 256 + o.y] = "N" end
	end
	marks[px * 256 + py] = "@"
	local letters, nextLetter, used, rows = {}, 0, {}, {}
	for dy = -VIEW_H, VIEW_H do
		local row = {}
		for dx = -VIEW_W, VIEW_W do
			local x, y = px + dx, py + dy
			local ch = (x >= 0 and y >= 0) and marks[x * 256 + y] or nil
			if not ch then
				local _, c = tileAt(x, y)
				if not c then
					ch = " "
				elseif x < 0 or y < 0 or x >= mapW or y >= mapH then
					ch = ":"
				elseif c == 0x00 then
					ch = "."
				elseif c == 0x07 then
					ch = "#"
				else
					ch = letters[c]
					if not ch then
						ch = string.char(0x61 + nextLetter % 26)
						letters[c], nextLetter = ch, nextLetter + 1
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
		{ "S", "something to read or use when faced (a sign; bg event)" },
		{ "!", "a tile an unbeaten trainer looks at the way it faces now (stepping there starts its battle)" },
		{ "#", "collision 0x07: a step refused" }, { ".", "collision 0x00: walked on" },
		{ ":", "beyond this map's edge" }, { " ", "outside the block buffer" },
	}
	for _, f in ipairs(fixed) do
		if used[f[1]] then legend[#legend + 1] = f[1] .. " " .. f[2] end
	end
	for c, ch in pairs(letters) do
		legend[#legend + 1] = string.format("%s collision 0x%02X%s", ch, c, COLLISION_NOTES[c] and (": " .. COLLISION_NOTES[c]) or " (not measured)")
	end
	table.sort(legend)
	return { rows = rows, legend = legend }
end

-- The screen's text is the game's 20 by 18 tile buffer: every letter printed is written there.
local TILEMAP, COLS, ROWS = flat(0xC4A0), 20, 18
-- What each byte draws, named from the charset probe's captures; a byte that draws nothing, or is below 0x60 (the map's
-- tiles), reads as {XX}.
local CHARS = {}
for i = 0, 25 do
	CHARS[0x80 + i] = string.char(0x41 + i)
	CHARS[0xA0 + i] = string.char(0x61 + i)
end
for i = 0, 9 do CHARS[0xF6 + i] = tostring(i) end
do
	local drawn = {
		[0x7F] = " ",
		[0x9A] = "(", [0x9B] = ")", [0x9C] = ":", [0x9D] = ";", [0x9E] = "[", [0x9F] = "]",
		[0xC0] = "Ä", [0xC1] = "Ö", [0xC2] = "Ü", [0xC3] = "ä", [0xC4] = "ö", [0xC5] = "ü",
		[0xD0] = "'d", [0xD1] = "'l", [0xD2] = "'m", [0xD3] = "'r", [0xD4] = "'s", [0xD5] = "'t", [0xD6] = "'v",
		[0xDF] = "←", [0xE0] = "'", [0xE1] = "PK", [0xE2] = "MN", [0xE3] = "-", [0xE6] = "?", [0xE7] = "!",
		[0xE8] = ".", [0xE9] = "&", [0xEA] = "é", [0xEB] = "→", [0xEC] = "▷", [0xED] = "▶", [0xEE] = "▼",
		[0xEF] = "♂", [0xF0] = "₽", [0xF1] = "×", [0xF2] = ".", [0xF3] = "/", [0xF4] = ",", [0xF5] = "♀",
	}
	for b, s in pairs(drawn) do CHARS[b] = s end
end
-- Letters and digits: what makes a run of tiles text rather than a picture that happens to use font tiles.
local function isLetter(b) return (b >= 0x80 and b <= 0x99) or (b >= 0xA0 and b <= 0xB9) or (b >= 0xF6) end

-- Which font is loaded, by an FNV-1a checksum of each id range's tiles in VRAM bank 0, since a picture can be drawn
-- with the letters' tiles; 0x60-0x7F name different glyphs in a message box and in a battle. Two reads of 928 and 512
-- bytes, so only observe and select read it, never the per-frame watch.
local FONT_LETTERS, FONT_LOW_BOX, FONT_LOW_BATTLE = 0xABC168AD, 0x463433A3, 0x0E4FC271
local LOW_NAMES = {
	[FONT_LOW_BOX] = {
		[0x60] = "■", [0x61] = "▲", [0x63] = "D", [0x64] = "E", [0x65] = "F", [0x66] = "G", [0x67] = "H", [0x68] = "I",
		[0x69] = "V", [0x6A] = "S", [0x6B] = "L", [0x6C] = "M", [0x6D] = ":", [0x6E] = "ぃ", [0x6F] = "ぅ",
		[0x70] = "PO", [0x71] = "Ké", [0x72] = "“", [0x73] = "”", [0x74] = "·", [0x75] = "…", [0x76] = "ぁ",
		[0x77] = "ぇ", [0x78] = "ぉ",
	},
	[FONT_LOW_BATTLE] = { [0x6E] = ":L", [0x75] = "…" },
}
local function fnv(b)
	local h = 0x811C9DC5
	for i = 1, #b do h = ((h ~ b[i]) * 0x01000193) & 0xFFFFFFFF end
	return h
end
-- Whether the letters are loaded, and the names for 0x60-0x7F on this screen (nil when neither measured set is).
local function readFont()
	local letters = fnv(memory.read_bytes_as_array(0x0800, 0x3A * 16, "VRAM")) == FONT_LETTERS
	return letters, LOW_NAMES[fnv(memory.read_bytes_as_array(0x1600, 0x20 * 16, "VRAM"))]
end

-- The message box: its frame on rows 12-17, lines on rows 14 and 16; while it waits for a button the ▼ blinks at
-- (18,17), 16 frames on and 16 off. wTextboxFlags has bit 1 set while a message prints.
local BOX_TOP, BOX_BOTTOM, ARROW_COL = 12, 17, 18
local W_TEXTBOX_FLAGS, TEXTBOX_PRINTING = flat(0xCFCF), 0x02
local ARROW, BLINK_GAP = 0xEE, 20

-- A menu: w2DMenuData (CFA1) holds the first item's row and the cursor's column, the rows and columns, and the gaps in
-- CFA7. It counts as waiting for a choice only while its ▶ is drawn at the cursor's cell (it becomes ▷ once chosen).
local W_WINDOW_STACK_SIZE, W_MENU_BORDER_RIGHT = flat(0xCF78), flat(0xCF85)
local W_2DMENU, W_MENU_CURSOR_Y, W_CURSOR_TILE = flat(0xCFA1), flat(0xCFA9), flat(0xCFAC)
local CURSOR = 0xED

local function readTilemap() return memory.read_bytes_as_array(TILEMAP, COLS * ROWS, "WRAM") end
local function cell(t, c, r) return t[r * COLS + c + 1] end

-- `low`: readFont()'s names for 0x60-0x7F on this screen, or nil to leave those raw.
local function decodeCells(t, r, c0, c1, low)
	local out = {}
	for c = c0, c1 do
		local b = cell(t, c, r)
		out[#out + 1] = CHARS[b] or (low and low[b]) or string.format("{%02X}", b)
	end
	return (table.concat(out):gsub("%s+$", ""))
end

local function boxOpen(t)
	if cell(t, 0, BOX_TOP) ~= 0x79 or cell(t, 19, BOX_TOP) ~= 0x7B or cell(t, 0, BOX_BOTTOM) ~= 0x7D
		or cell(t, 19, BOX_BOTTOM) ~= 0x7E then
		return false
	end
	for r = BOX_TOP + 1, BOX_BOTTOM - 1 do
		if cell(t, 0, r) ~= 0x7C or cell(t, 19, r) ~= 0x7C then return false end
		-- No message has a frame tile inside it; the battle's action menu draws a 0x7C column at 8 in the same rows.
		for c = 1, 18 do
			local b = cell(t, c, r)
			if b >= 0x79 and b <= 0x7E then return false end
		end
	end
	return true
end

-- Kept once a frame by game.watch(): when the box's lines last changed, when the ▼ was last drawn, and `cycles`, the
-- returns of wTextDelayFrames to 5 since the rows last changed: in a battle a box waiting for A with no ▼ counts it
-- down over and over.
local W_TEXT_DELAY_FRAMES = flat(0xCFB2)
local track = { lines = nil, changedAt = -1, arrowAt = -1, seenAt = -1, cycles = 0, lastDelay = 0 }
local function boxBytes(t)
	local b = {}
	for r = BOX_TOP + 1, BOX_BOTTOM - 1 do
		for c = 1, 18 do b[#b + 1] = string.char(cell(t, c, r)) end
	end
	return table.concat(b)
end
local function trackText(t)
	local f = emu.framecount()
	local lines = boxBytes(t)
	if lines ~= track.lines then track.lines, track.changedAt, track.cycles = lines, f, 0 end
	if cell(t, ARROW_COL, BOX_BOTTOM) == ARROW then track.arrowAt = f end
	local delay = u8(W_TEXT_DELAY_FRAMES)
	if delay == 5 and track.lastDelay == 1 then track.cycles = track.cycles + 1 end
	track.lastDelay = delay
	track.seenAt = f
end

-- In a battle, the game waiting for A with no ▼ (above).
local function waitingInBattle()
	return u8(W_BATTLEMODE) ~= 0 and track.cycles >= 1 and track.seenAt >= emu.framecount() - 1
end

local function readDialogue(t, low)
	if not boxOpen(t) then return nil end
	local lines = {}
	for r = BOX_TOP + 1, BOX_BOTTOM - 1 do
		local s = decodeCells(t, r, 1, 18, low)
		if s ~= "" then lines[#lines + 1] = s end
	end
	local f, state = emu.framecount(), nil
	-- A battle's box is cleared over 2 frames, a row each, so rows changed since the watcher's last frame are still
	-- changing.
	local changing = track.seenAt == f - 1 and boxBytes(t) ~= track.lines
	if cell(t, ARROW_COL, BOX_BOTTOM) == ARROW
		or (not changing and track.arrowAt >= track.changedAt and f - track.arrowAt >= 0 and f - track.arrowAt <= BLINK_GAP)
		or (not changing and #lines > 0 and waitingInBattle()) then
		state = "waiting_for_button"
	elseif (u8(W_TEXTBOX_FLAGS) & TEXTBOX_PRINTING) ~= 0 or #lines == 0 or changing then
		-- An empty box is one about to print.
		state = "printing"
	else
		state = "finished"
	end
	return { box = table.concat(lines, "\n"), state = state }
end

-- In a battle the action and move menus use the same block, with wMenuCursorX for the grid's column; the move menu
-- opens no window, so a menu counts there without one.
local W_MENU_CURSOR_X = flat(0xCFAA)

-- `low`: readFont()'s names for 0x60-0x7F, or false to skip reading the items' text (a per-frame check). Returns the
-- menu and the rows its items are on.
local function readMenu(t, low)
	if u8(W_WINDOW_STACK_SIZE) == 0 and u8(W_BATTLEMODE) == 0 then return nil end
	local m = memory.read_bytes_as_array(W_2DMENU, 7, "WRAM")
	local top, col, rows, cols, rowGap, colGap = m[1], m[2], m[3], m[4], m[7] >> 4, m[7] & 0x0F
	local tile = u8(W_CURSOR_TILE) | (u8(W_CURSOR_TILE + 1) << 8)
	local at = tile - 0xC4A0
	if rows < 1 or cols < 1 or rowGap < 1 or (cols > 1 and colGap < 2) or at < 0 or at >= COLS * ROWS or t[at + 1] ~= CURSOR then
		return nil
	end
	local right = u8(W_MENU_BORDER_RIGHT)
	if right <= col + (cols - 1) * colGap or right >= COLS or top + (rows - 1) * rowGap >= ROWS then return nil end
	local items, used = {}, {}
	for r = 0, rows - 1 do
		used[top + r * rowGap] = true
		for c = 0, cols - 1 do
			local from = col + c * colGap + 1
			local to = (c < cols - 1) and (col + (c + 1) * colGap - 1) or (right - 1)
			items[#items + 1] = low == false and "" or decodeCells(t, top + r * rowGap, from, to, low)
		end
	end
	local menu = { items = items, cursor = (u8(W_MENU_CURSOR_Y) - 1) * cols + (u8(W_MENU_CURSOR_X) - 1) }
	if cols > 1 then menu.columns = cols end
	return menu, used
end

-- Any other text on screen, row by row: runs of named tiles holding a letter or a digit, outside the message box
-- and the menu's rows when those are reported.
local function readScreenText(t, dialogue, menuRows, low)
	local out = {}
	local function named(b) return CHARS[b] or (low and low[b]) end
	for r = 0, ROWS - 1 do
		local skip = (dialogue and r >= BOX_TOP) or (menuRows and menuRows[r]) or false
		if not skip then
			local runs, c = {}, 0
			while c < COLS do
				if named(cell(t, c, r)) and cell(t, c, r) ~= 0x7F then
					local c1, letters = c, false
					while c1 + 1 < COLS and named(cell(t, c1 + 1, r)) and not (cell(t, c1 + 1, r) == 0x7F and cell(t, math.min(c1 + 2, COLS - 1), r) == 0x7F) do
						c1 = c1 + 1
					end
					for k = c, c1 do
						if isLetter(cell(t, k, r)) then letters = true end
					end
					if letters then runs[#runs + 1] = decodeCells(t, r, c, c1, low) end
					c = c1 + 1
				else
					c = c + 1
				end
			end
			if #runs > 0 then out[#out + 1] = { row = r, text = table.concat(runs, "  ") } end
		end
	end
	return out
end

-- The PACK's item list, whole, when the menu on screen is it, and the pockets' contents (defined with the pockets,
-- below).
local itemPocketMenu, readBag, readParty, partyMenu, readBadges, movementName

-- The message and the menu on screen together: a menu drawn inside the message box's frame (the battle's action
-- menu) is not a message, and the box under the PACK's item list is that item's description.
local function readTextAndMenu(t, low)
	local d = readDialogue(t, low)
	local m, menuRows = readMenu(t, low)
	if d and menuRows then
		for r = BOX_TOP + 1, BOX_BOTTOM - 1 do
			if menuRows[r] then d = nil end
		end
	end
	-- The count back to 5 runs under a menu too, so with a menu up the box waits only if its ▼ says so.
	if d and m and d.state == "waiting_for_button" and cell(t, ARROW_COL, BOX_BOTTOM) ~= ARROW and waitingInBattle() then
		d.state = "finished"
	end
	local whole = itemPocketMenu(m) or partyMenu(m, t, low)
	if whole then
		whole.description = d and d.box ~= "" and d.box or nil
		m, d = whole, nil
	end
	return d, m, menuRows
end

-- Which battle menu waits, by the menu block's first row, column and columns.
local function battleAskingFor(m)
	if not m then return nil end
	local b = memory.read_bytes_as_array(W_2DMENU, 4, "WRAM")
	if b[1] == 14 and b[2] == 9 and b[4] == 2 then return "action" end
	if b[1] == 13 and b[2] == 5 and b[4] == 1 then return "move" end
	return nil
end

-- The battlers, 0x20 bytes each. The accuracy byte's scale is not measured, so it goes out as `accuracy_raw` and scores
-- only by comparison; a PP byte of 0x40 or more (raised PP) is not measured either and goes out as pp_raw.
local W_BATTLE_MON, W_ENEMY_MON, BATTLER_SIZE = flat(0xC62C), flat(0xD206), 0x20
local W_BATTLE_MON_NICK, W_ENEMY_MON_NICK, NICK_LEN = flat(0xC621), flat(0xC616), 11
local MOVES_BANK, MOVES_PTR, MOVE_SIZE = 0x10, 0x5AFB, 7
local MOVE_NAMES_BANK, MOVE_NAMES_PTR = 0x72, 0x5F29
local NAMES_BANK, SPECIES_NAMES_PTR, SPECIES_NAME_LEN, TYPE_NAMES_PTR = 0x14, 0x7384, 10, 0x497B
local STRING_END = 0x50
-- In a trainer battle wCurOTMon reads 255 until the first Pokémon is sent out, the opponent's block still holding the
-- last battle's.
local BATTLE_KINDS, BATTLE_MODE_TRAINER = { [1] = "wild", [2] = "trainer" }, 2
local W_CUR_OT_MON, OT_MON_NONE_YET, W_OT_PARTY_COUNT = flat(0xC663), 255, flat(0xD280)

-- In a string read from ROM, 0x54 prints as "POKé".
local function spell(b, from, to)
	local out = {}
	for i = from, to do
		if b[i] == STRING_END then break end
		out[#out + 1] = b[i] == 0x54 and "POKé" or CHARS[b[i]] or string.format("{%02X}", b[i])
	end
	return table.concat(out)
end

local romNames = { moves = {}, species = {}, types = {}, moveData = {} }
local function moveName(id)
	local cached = romNames.moves[id]
	if cached then return cached end
	if not romNames.moveBlock then
		romNames.moveBlock = memory.read_bytes_as_array(MOVE_NAMES_BANK * 0x4000 + (MOVE_NAMES_PTR - 0x4000), 0x2000, "ROM")
	end
	local b, i, n = romNames.moveBlock, 1, 1
	while n < id and i <= #b do
		if b[i] == STRING_END then n = n + 1 end
		i = i + 1
	end
	local name = spell(b, i, math.min(i + 12, #b))
	romNames.moves[id] = name
	return name
end

local function typeName(t)
	if romNames.types[t] ~= nil then return romNames.types[t] or nil end
	local ptr = rom8(NAMES_BANK, TYPE_NAMES_PTR + t * 2) | (rom8(NAMES_BANK, TYPE_NAMES_PTR + t * 2 + 1) << 8)
	local name = nil
	if t < 0x20 and ptr >= 0x4000 and ptr <= 0x7FF0 then
		local b = memory.read_bytes_as_array(NAMES_BANK * 0x4000 + (ptr - 0x4000), 10, "ROM")
		name = spell(b, 1, #b)
	end
	romNames.types[t] = name or false
	return name
end

local function speciesName(id)
	if romNames.species[id] then return romNames.species[id] end
	local b = memory.read_bytes_as_array(NAMES_BANK * 0x4000 + (SPECIES_NAMES_PTR - 0x4000) + (id - 1) * SPECIES_NAME_LEN,
		SPECIES_NAME_LEN, "ROM")
	romNames.species[id] = spell(b, 1, #b)
	return romNames.species[id]
end

-- A move's entry: its type, power, accuracy byte and the PP drawn as its maximum.
local function moveData(id)
	local m = romNames.moveData[id]
	if m then return m end
	local e = memory.read_bytes_as_array(MOVES_BANK * 0x4000 + (MOVES_PTR - 0x4000) + (id - 1) * MOVE_SIZE, MOVE_SIZE, "ROM")
	m = { name = moveName(id), type = typeName(e[4]) or nil, type_id = e[4], power = e[3], accuracy_raw = e[5], base_pp = e[6] }
	romNames.moveData[id] = m
	return m
end

local function readBattler(base, nickAt, side)
	local b = memory.read_bytes_as_array(base, BATTLER_SIZE, "WRAM")
	if b[1] == 0 then return nil end
	local nick = memory.read_bytes_as_array(nickAt, NICK_LEN, "WRAM")
	local out = { side = side, species = speciesName(b[1]), species_id = b[1], nickname = spell(nick, 1, #nick),
		level = b[14], hp = (b[17] << 8) | b[18], max_hp = (b[19] << 8) | b[20], moves = {},
		types = b[31] == b[32] and { typeName(b[31]) } or { typeName(b[31]), typeName(b[32]) },
		stats = { attack = (b[21] << 8) | b[22], defense = (b[23] << 8) | b[24], speed = (b[25] << 8) | b[26],
			sp_atk = (b[27] << 8) | b[28], sp_def = (b[29] << 8) | b[30] } }
	for k = 0, 3 do
		local id, pp = b[3 + k], b[9 + k]
		if id ~= 0 then
			local m = moveData(id)
			out.moves[#out.moves + 1] = { name = m.name, id = id, pp = pp < 0x40 and pp or nil, pp_raw = pp >= 0x40 and pp or nil,
				base_pp = m.base_pp, type = m.type, power = m.power, accuracy_raw = m.accuracy_raw }
		end
	end
	return out
end

-- The best usable move (measured PP above 0) as its move-menu index. `strongest` scores power times the accuracy byte;
-- `effective` also multiplies by the type table's multipliers (tenths, one per defending type), half again for the
-- attacker's own type, and attack over defense for a type id below 20, special attack over special defense from 20.
local function strongestMoveSlot(effective)
	local b = memory.read_bytes_as_array(W_BATTLE_MON, BATTLER_SIZE, "WRAM")
	local e = memory.read_bytes_as_array(W_ENEMY_MON, BATTLER_SIZE, "WRAM")
	if not romNames.typeChart then
		local t, raw = {}, memory.read_bytes_as_array(0x0D * 0x4000 + (0x4BB1 - 0x4000), 0x200, "ROM")
		local i = 1
		while i <= #raw - 2 and raw[i] ~= 0xFF do
			if raw[i] == 0xFE then
				i = i + 1
			else
				t[raw[i] * 256 + raw[i + 1]] = raw[i + 2]
				i = i + 3
			end
		end
		romNames.typeChart = t
	end
	local best, bestScore, weighed = nil, nil, {}
	local foeTypes = e[31] == e[32] and { e[31] } or { e[31], e[32] }
	for k = 0, 3 do
		local id, pp = b[3 + k], b[9 + k]
		if id ~= 0 and pp > 0 and pp < 0x40 then
			local m = moveData(id)
			local score = m.power * m.accuracy_raw
			if effective then
				local multiplier = 1
				for _, defending in ipairs(foeTypes) do
					local x = romNames.typeChart[m.type_id * 256 + defending]
					if x then multiplier = multiplier * x / 10 end
				end
				local same = m.type_id == b[31] or m.type_id == b[32]
				local physical = m.type_id < 20
				local attack = physical and ((b[21] << 8) | b[22]) or ((b[27] << 8) | b[28])
				local defense = physical and ((e[23] << 8) | e[24]) or ((e[29] << 8) | e[30])
				score = score * multiplier * (same and 3 / 2 or 1) * attack / math.max(defense, 1)
				weighed[#weighed + 1] = { move = m.name, type = m.type, power = m.power, accuracy_raw = m.accuracy_raw,
					same_type = same or nil, multiplier = multiplier, attack = attack, defense = defense, score = score }
			end
			if best == nil or score > bestScore then best, bestScore = k, score end
		end
	end
	if not effective then return best, best and moveName(b[3 + best]) end
	local against = {}
	for i, t in ipairs(foeTypes) do against[i] = typeName(t) end
	return best, best and moveName(b[3 + best]), { weighed = weighed, against = against }
end

-- The party: wPartyCount, then 0x30 bytes a Pokémon and an 11-byte nickname a slot; slots past the second are read the
-- same way, not yet seen.
local W_BATTLE_RESULT, W_MONEY, W_PARTY_COUNT, W_PARTY_MON1, W_PARTY_NICK1 = flat(0xD0EE), flat(0xD84E), flat(0xDCD7),
	flat(0xDCDF), flat(0xDE41)
local PARTY_MON_SIZE, PARTY_MAX = 0x30, 6

local function battleEndedReport()
	local money = memory.read_bytes_as_array(W_MONEY, 3, "WRAM")
	local report = { outcome_raw = u8(W_BATTLE_RESULT), money = (money[1] << 16) | (money[2] << 8) | money[3],
		party_count = u8(W_PARTY_COUNT) }
	if report.party_count >= 1 and report.party_count <= PARTY_MAX then
		report.party = {}
		for k = 0, report.party_count - 1 do
			local p = memory.read_bytes_as_array(W_PARTY_MON1 + k * PARTY_MON_SIZE, PARTY_MON_SIZE, "WRAM")
			local nick = memory.read_bytes_as_array(W_PARTY_NICK1 + k * NICK_LEN, NICK_LEN, "WRAM")
			report.party[#report.party + 1] = { slot = k + 1, species = speciesName(p[1]), nickname = spell(nick, 1, #nick),
				level = p[0x20], hp = (p[0x23] << 8) | p[0x24], max_hp = (p[0x25] << 8) | p[0x26] }
		end
	end
	return report
end

local game = {
	game = "crystal",
	variant = isVanilla and "vanilla" or "unverified",
	capabilities = { "observe", "press", "wait", "screenshot", "snapshot", "restore", "walk", "goto", "select", "advance_text", "battle",
		"cheat:warp", "cheat:give_item", "cheat:set_flag", "cheat:heal", "cheat:set_badge", "cheat:set_move", "cheat:set_status" },
	-- Down moves a menu's cursor one item a press, and A chooses.
	menuButtons = { prev = "Up", next = "Down", left = "Left", right = "Right", confirm = "A" },
	protected_slots = { 1 },
	shots = "crystal",
}

function game.build()
	local title = {}
	for i = 0x134, 0x13E do
		local c = memory.read_u8(i, "ROM")
		if c == 0 then break end
		title[#title + 1] = string.char(c)
	end
	return string.format("title %s, rom hash %s", table.concat(title), romHash)
end

function game.start()
	return "rom hash " .. romHash .. (isVanilla and " (vanilla V1.0)" or " is not the measured vanilla ROM")
end

-- After a snapshot is loaded: what was tracked belongs to the frames that were replaced.
function game.restored()
	track = { lines = nil, changedAt = -1, arrowAt = -1, seenAt = -1, cycles = 0, lastDelay = 0 }
end

-- `asked`: an observe the caller asked for (not a program's before and after), which also reads what the save has.
function game.observe(asked)
	local overworld = isVanilla and inOverworld()
	local ps = memory.read_bytes_as_array(PLAYER_STRUCT, 0x28, "WRAM")
	local warps, nearby, localMap
	if overworld then
		warps, nearby = readWarps(), readObjects()
		localMap = readLocalMap(warps, nearby, readSigns())
		local px, py = u8(W_XCOORD), u8(W_YCOORD)
		for _, o in ipairs(nearby) do o.dx, o.dy = o.x - px, o.y - py end
	end
	local d, m, s, menuRows
	if isVanilla then
		local t = readTilemap()
		local letters, low = readFont()
		d, m, menuRows = readTextAndMenu(t, low)
		if letters then
			-- The PACK's description box is the menu's `description`, not screen text too.
			s = readScreenText(t, d or (m and m.description), menuRows, low)
			if #s == 0 then s = nil end
		end
	end
	local battle
	if isVanilla and u8(W_BATTLEMODE) ~= 0 then
		local modeRaw = u8(W_BATTLEMODE)
		battle = { asking = battleAskingFor(m), kind = BATTLE_KINDS[modeRaw], battlers = {} }
		battle.battlers[#battle.battlers + 1] = readBattler(W_BATTLE_MON, W_BATTLE_MON_NICK, "player")
		-- In a trainer battle the opponent's block holds the last battle's Pokémon until the first is sent out.
		local otMon = u8(W_CUR_OT_MON)
		if modeRaw ~= BATTLE_MODE_TRAINER or otMon ~= OT_MON_NONE_YET then
			battle.battlers[#battle.battlers + 1] = readBattler(W_ENEMY_MON, W_ENEMY_MON_NICK, "opponent")
		end
		if modeRaw == BATTLE_MODE_TRAINER then
			battle.opponent_party_count = u8(W_OT_PARTY_COUNT)
			battle.opponent_party_index = otMon ~= OT_MON_NONE_YET and otMon or nil
		end
		-- An empty Lua table goes out as {}, not []: leave the list out until a battler is there.
		if #battle.battlers == 0 then battle.battlers = nil end
	end
	-- What the save has: the party and money as `battle`'s ended report reads them, and the measured pockets.
	local party, money, bag, badges
	if asked and isVanilla then
		local r = battleEndedReport()
		party, money, bag, badges = readParty(), r.money, readBag(), readBadges()
	end
	return {
		frame = emu.framecount(),
		dialogue = d,
		menu = m,
		battle = battle,
		party = party,
		money = money,
		bag = bag,
		badge_count = badges and #badges or nil,
		badges = (badges and #badges > 0) and badges or nil,
		screen_text = s,
		local_map = localMap,
		nearby = (nearby and #nearby > 0) and nearby or nil,
		mode = modeName(),
		-- In the overworld, a MOVEMENT_STATES name; any other state goes out raw.
		movement = overworld and (movementName() or string.format("state_raw_%d", u8(flat(0xD95D)))) or nil,
		location = { map = mapName(), x = u8(W_XCOORD), y = u8(W_YCOORD), facing = overworld and FACING[ps[9]] or nil },
		warps = (warps and #warps > 0) and warps or nil,
		extras = {
			map_status_raw = u8(W_MAPSTATUS),
			sprite_updates_raw = u8(W_SPRITEUPDATES),
			battle_mode_raw = u8(W_BATTLEMODE),
			-- 255 while a message, a menu or a Pokémon's picture waits: the only sign of a wait for a button under a
			-- picture.
			script_running_raw = u8(W_SCRIPT_RUNNING),
			script_mode_raw = u8(W_SCRIPT_RUNNING - 1),
			player_struct = (function()
				local out = {}
				for i = 1, #ps do out[i] = string.format("%02X", ps[i]) end
				return table.concat(out, " ")
			end)(),
		},
	}
end

-- Cheats: each takes its args and returns a plan ({ untilFn(observation) -> done, limit = frames, report() }) or nil
-- and a reason. A cheat changes the world by other means than play; the core marks the segment reached.
game.cheats = {}

-- warp {map = "G.N", x, y}: the writes probes/goto_map.lua makes; without hMapEntryMethod the game reloads the map it
-- is on. Refused while a script has the controls, since written then the load does not run. Done once the game has left
-- the overworld and runs the target map again.
local W_DEFAULT_SPAWNPOINT, H_MAP_ENTRY_METHOD, MAPSETUP_WARP = flat(0xD001), 0xFF9F, 0xF1
function game.cheats.warp(args)
	local map = type(args.map) == "string" and args.map or ""
	local g, n = map:match("^(%d+)%.(%d+)$")
	local x, y = math.tointeger(args.x), math.tointeger(args.y)
	g, n = tonumber(g), tonumber(n)
	if not g or g > 255 or n > 255 or not x or not y or x < 0 or y < 0 or x > 255 or y > 255 then
		return nil, 'warp needs map "G.N" (each 0-255), x and y (0-255)'
	end
	if not isVanilla then return nil, "warp is measured on the vanilla V1.0 ROM only" end
	if not inOverworld() or u8(W_BATTLEMODE) ~= 0 then return nil, "warp refused: not in the overworld" end
	if u8(W_SCRIPT_RUNNING) ~= 0 then
		return nil, string.format("warp refused: a script has the controls (wScriptRunning %d)", u8(W_SCRIPT_RUNNING))
	end
	memory.write_u8(W_MAPGROUP, g, "WRAM")
	memory.write_u8(W_MAPNUMBER, n, "WRAM")
	memory.write_u8(W_XCOORD, x, "WRAM")
	memory.write_u8(W_YCOORD, y, "WRAM")
	memory.write_u8(W_DEFAULT_SPAWNPOINT, 0xFF, "WRAM")
	memory.write_u8(H_MAP_ENTRY_METHOD, MAPSETUP_WARP, "System Bus")
	memory.write_u8(W_MAPSTATUS, MAPSTATUS_WARPING, "WRAM")
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
		report = function()
			return { map = mapName(), x = u8(W_XCOORD), y = u8(W_YCOORD), map_status_raw = u8(W_MAPSTATUS) }
		end,
	}
end

-- wJohtoBadges: bit (N - 1) is badge N as the trainer card numbers it; wKantoBadges is not measured.
local W_JOHTO_BADGES = flat(0xD857)
readBadges = function()
	local b, list = u8(W_JOHTO_BADGES), {}
	for n = 1, 8 do
		if (b >> (n - 1)) & 1 == 1 then list[#list + 1] = n end
	end
	return list
end

-- set_badge {badge = 1-8, value = true}: bit (badge - 1) of wJohtoBadges, refused outside the overworld.
function game.cheats.set_badge(args)
	local n = math.tointeger(args.badge)
	if not n or n < 1 or n > 8 then return nil, "set_badge needs badge 1-8 (Johto's; Kanto's are not measured)" end
	if args.value ~= nil and type(args.value) ~= "boolean" then return nil, "set_badge value is true or false" end
	if not isVanilla then return nil, "set_badge is measured on the vanilla V1.0 ROM only" end
	if not inOverworld() or u8(W_BATTLEMODE) ~= 0 then return nil, "set_badge refused: not in the overworld" end
	local bit, was = 1 << (n - 1), u8(W_JOHTO_BADGES)
	memory.write_u8(W_JOHTO_BADGES, args.value == false and (was & ~bit & 0xFF) or (was | bit), "WRAM")
	return {
		limit = 1,
		untilFn = function() return true end,
		report = function() return { badge = n, johto_badges_raw = u8(W_JOHTO_BADGES), was_raw = was } end,
	}
end

-- set_flag {flag, value = true}: bit (flag & 7) of the byte (flag >> 3) past wEventFlags, which is 0x100 bytes in our
-- build's .sym. Only defeat flags are measured; refused outside the overworld.
local EVENT_FLAG_COUNT = 0x100 * 8
function game.cheats.set_flag(args)
	local flag = math.tointeger(args.flag)
	if not flag or flag < 0 or flag >= EVENT_FLAG_COUNT then
		return nil, string.format("set_flag needs flag, 0 to %d", EVENT_FLAG_COUNT - 1)
	end
	if args.value ~= nil and type(args.value) ~= "boolean" then return nil, "set_flag value is true or false" end
	if not isVanilla then return nil, "set_flag is measured on the vanilla V1.0 ROM only" end
	if not inOverworld() or u8(W_BATTLEMODE) ~= 0 then return nil, "set_flag refused: not in the overworld" end
	local at, bit = W_EVENT_FLAGS + (flag >> 3), 1 << (flag & 7)
	local was = (u8(at) & bit) ~= 0
	local want = args.value ~= false
	memory.write_u8(at, want and (u8(at) | bit) or (u8(at) & ~bit & 0xFF), "WRAM")
	return {
		limit = 1,
		untilFn = function() return true end,
		report = function() return { flag = flag, was = was, now = (u8(at) & bit) ~= 0 } end,
	}
end

-- The item attribute table at 01:67C1: 7 bytes an item from id 1, +0x05 the pocket the game files it in.
local W_NUM_ITEMS, ITEM_POCKET_SLOTS, ITEM_ATTRIBUTES, ATTR_POCKET_ITEM = flat(0xD892), 20, 0x67C1, 0x01
-- The PACK's pockets by their attribute byte: a count, entries (an id and a quantity, or an id alone for key items) and
-- FF. `slots` is each pocket's room in our build's .sym, `cur` its wCurPocket, `size` the bytes an entry takes.
local POCKETS = {
	[0x01] = { name = "items", addr = W_NUM_ITEMS, slots = ITEM_POCKET_SLOTS, cur = 0, ptr = 0xD892, size = 2 },
	[0x02] = { name = "key_items", addr = flat(0xD8BC), slots = 25, cur = 2, ptr = 0xD8BC, size = 1 },
	[0x03] = { name = "balls", addr = flat(0xD8D7), slots = 12, cur = 1, ptr = 0xD8D7, size = 2 },
}
-- The TM/HM pocket: a count per TM or HM, the Kth of the 57 ids the attribute table files under 04 at D859 + K.
local TM_POCKET = { name = "tms_hms", addr = flat(0xD859), slots = 57, cur = 3 }
local tmIds
local function tmIdList()
	if tmIds then return tmIds end
	tmIds = {}
	for id = 1, 255 do
		if memory.read_u8(ITEM_ATTRIBUTES + (id - 1) * 7 + 5, "ROM") == 0x04 then tmIds[#tmIds + 1] = id end
	end
	return tmIds
end
-- The PACK's list: the entry under the ▶ is wMenuScrollPosition + wMenuCursorY - 1, CANCEL after the last.
local W_CUR_POCKET, W_MENU_SCROLL, W_SCROLL_LIST_SIZE, W_MENU_DATA_HEIGHT = flat(0xCF65), flat(0xD0E4), flat(0xD144), flat(0xCF92)
local ITEM_NAMES_BANK, ITEM_NAMES_PTR = 0x72, 0x4000

local function itemNames()
	if romNames.items then return romNames.items end
	local b = memory.read_bytes_as_array(ITEM_NAMES_BANK * 0x4000 + (ITEM_NAMES_PTR - 0x4000), MOVE_NAMES_PTR - ITEM_NAMES_PTR, "ROM")
	local names, i = {}, 1
	while i <= #b and #names < 255 do
		local j = i
		while j <= #b and b[j] ~= STRING_END do j = j + 1 end
		names[#names + 1] = spell(b, i, j)
		i = j + 1
	end
	romNames.items = names
	return names
end

-- The item list the menu header points at, or nil: the entries and CANCEL, their quantities, and the cursor.
local function itemListFromMemory()
	local h = memory.read_bytes_as_array(W_MENU_DATA_HEIGHT, 6, "WRAM")
	if h[1] ~= 5 then return nil end
	local pocket
	for _, p in pairs(POCKETS) do
		if h[3] == p.size and h[5] == p.ptr & 0xFF and h[6] == p.ptr >> 8 and u8(W_CUR_POCKET) == p.cur then pocket = p end
	end
	if not pocket then return nil end
	local count, names, y = u8(pocket.addr), itemNames(), u8(W_MENU_CURSOR_Y)
	if count > pocket.slots or u8(W_SCROLL_LIST_SIZE) ~= count or y < 1 or y > 5 then return nil end
	local items, quantities = {}, pocket.size == 2 and {} or nil
	for k = 0, count - 1 do
		local id = u8(pocket.addr + 1 + k * pocket.size)
		items[#items + 1] = names[id] or string.format("{%02X}", id)
		if quantities then quantities[#quantities + 1] = u8(pocket.addr + 2 + k * 2) end
	end
	items[#items + 1] = "CANCEL"
	return { items = items, cursor = u8(W_MENU_SCROLL) + y - 1, list = true, pocket = pocket.name, quantities = quantities }
end

-- After a press the list redraws for up to 11 frames with no ▶ on screen, so the list read whole within REDRAW_GRACE
-- frames before still counts while the header points at it.
local REDRAW_GRACE, listSeenAt = 20, -1000
-- The TM/HM list's rows draw each one's move (TMHMMoves, by its place among the 57); the entry under the ▶ is
-- wTMHMPocketScrollPosition + wTMHMPocketCursor.
local W_TMHM_CURSOR, W_TMHM_SCROLL, TMHM_MOVES_BANK, TMHM_MOVES_PTR = flat(0xD0DC), flat(0xD0E2), 0x04, 0x567A
local function tmListFromMemory()
	if u8(W_CUR_POCKET) ~= TM_POCKET.cur then return nil end
	local names, items, moves, quantities = itemNames(), {}, {}, {}
	for k, id in ipairs(tmIdList()) do
		local n = u8(TM_POCKET.addr + k - 1)
		if n > 0 then
			items[#items + 1], quantities[#quantities + 1] = names[id], n
			moves[#moves + 1] = moveName(rom8(TMHM_MOVES_BANK, TMHM_MOVES_PTR + k - 1))
		end
	end
	local rows = {}
	for i, move in ipairs(moves) do rows[i] = move end
	items[#items + 1], rows[#rows + 1] = "CANCEL", "CANCEL"
	local cursor, scroll = u8(W_TMHM_CURSOR), u8(W_TMHM_SCROLL)
	if cursor > 4 or scroll + cursor >= #items then return nil end
	return { items = items, cursor = scroll + cursor, list = true, pocket = TM_POCKET.name, moves = moves, quantities = quantities },
		rows, scroll
end

itemPocketMenu = function(m)
	local whole, rows, scroll = itemListFromMemory()
	if whole then
		rows, scroll = whole.items, u8(W_MENU_SCROLL)
	else
		whole, rows, scroll = tmListFromMemory()
	end
	local f = emu.framecount()
	if not whole then return nil end
	if m then
		-- The rows on screen must be the entries from the scroll position down (a long name is cut at the list's edge).
		for i, shown in ipairs(m.items) do
			local want = rows[scroll + i]
			if not want or shown == "" or want:sub(1, #shown) ~= shown then return nil end
		end
		listSeenAt = f
		return whole
	end
	if f - listSeenAt >= 0 and f - listSeenAt <= REDRAW_GRACE then return whole end
	return nil
end

-- The measured pockets that hold anything: per entry the item's name, id and quantity.
readBag = function()
	local names, bag = itemNames(), nil
	for _, pocket in pairs(POCKETS) do
		local count = u8(pocket.addr)
		if count >= 1 and count <= pocket.slots then
			local list = {}
			for k = 0, count - 1 do
				local id = u8(pocket.addr + 1 + k * pocket.size)
				list[#list + 1] = { item = names[id] or string.format("{%02X}", id), id = id,
					quantity = pocket.size == 2 and u8(pocket.addr + 2 + k * 2) or nil }
			end
			bag = bag or {}
			bag[pocket.name] = list
		end
	end
	local tms = {}
	for k, id in ipairs(tmIdList()) do
		local n = u8(TM_POCKET.addr + k - 1)
		if n > 0 then tms[#tms + 1] = { item = names[id] or string.format("{%02X}", id), id = id, quantity = n } end
	end
	if #tms > 0 then
		bag = bag or {}
		bag[TM_POCKET.name] = tms
	end
	return bag
end

-- A party slot's fields, by what the summary drew. A PP byte of 0x40 or more (raised PP) is not measured and goes out
-- as pp_raw.
local PARTY = { item = 0x01, moves = 0x02, exp = 0x08, pp = 0x17, level = 0x1F, status = 0x20, hp = 0x22, max_hp = 0x24 }
local PP_RAISED = 0x40
-- The status byte as the POKéMON menu draws it; others go out raw only.
local STATUS_NAMES = { [0] = "OK", [8] = "PSN" }

readParty = function()
	local count = u8(W_PARTY_COUNT)
	if count < 1 or count > PARTY_MAX then return nil end
	local names, out = itemNames(), {}
	for k = 0, count - 1 do
		local p = memory.read_bytes_as_array(W_PARTY_MON1 + k * PARTY_MON_SIZE, PARTY_MON_SIZE, "WRAM")
		local nick = memory.read_bytes_as_array(W_PARTY_NICK1 + k * NICK_LEN, NICK_LEN, "WRAM")
		local mon = { slot = k + 1, species = speciesName(p[1]), species_id = p[1], nickname = spell(nick, 1, #nick),
			level = p[PARTY.level + 1], hp = (p[PARTY.hp + 1] << 8) | p[PARTY.hp + 2],
			max_hp = (p[PARTY.max_hp + 1] << 8) | p[PARTY.max_hp + 2], status_raw = p[PARTY.status + 1],
			status = STATUS_NAMES[p[PARTY.status + 1]],
			exp = (p[PARTY.exp + 1] << 16) | (p[PARTY.exp + 2] << 8) | p[PARTY.exp + 3], moves = {},
			-- +0x26 on, two bytes each: attack, defense, speed, special attack, special defense.
			stats = { attack = (p[0x27] << 8) | p[0x28], defense = (p[0x29] << 8) | p[0x2A], speed = (p[0x2B] << 8) | p[0x2C],
				sp_atk = (p[0x2D] << 8) | p[0x2E], sp_def = (p[0x2F] << 8) | p[0x30] } }
		local item = p[PARTY.item + 1]
		if item ~= 0 then mon.held_item = names[item] or string.format("{%02X}", item) end
		for m = 0, 3 do
			local id, pp = p[PARTY.moves + 1 + m], p[PARTY.pp + 1 + m]
			if id ~= 0 then
				local d = moveData(id)
				mon.moves[#mon.moves + 1] = { name = d.name, id = id, pp = pp < PP_RAISED and pp or nil,
					pp_raw = pp >= PP_RAISED and pp or nil, base_pp = d.base_pp, type = d.type, power = d.power,
					accuracy_raw = d.accuracy_raw }
			end
		end
		out[#out + 1] = mon
	end
	return out
end

-- The POKéMON menu, and the party list in a battle: a menu block of one row per Pokémon plus CANCEL, 2 rows apart,
-- whose rows show the party's names, reads as `party: true` (the grid reader alone cuts the HP), and `select` takes a
-- name.
partyMenu = function(m, t, low)
	if not m then return nil end
	local b = memory.read_bytes_as_array(W_2DMENU, 7, "WRAM")
	local count = u8(W_PARTY_COUNT)
	if b[1] ~= 1 or b[2] ~= 0 or b[4] ~= 1 or (b[7] >> 4) ~= 2 or count < 1 or count > PARTY_MAX or b[3] ~= count + 1 then
		return nil
	end
	local items = {}
	for k = 0, count - 1 do
		local nick = memory.read_bytes_as_array(W_PARTY_NICK1 + k * NICK_LEN, NICK_LEN, "WRAM")
		local name = spell(nick, 1, #nick)
		if decodeCells(t, 1 + k * 2, 3, 12, low) ~= name then return nil end
		items[#items + 1] = name
	end
	items[#items + 1] = "CANCEL"
	return { items = items, cursor = m.cursor, party = true }
end

-- heal: every party Pokémon's HP to its max, each move's PP to the move table's maximum and the status to 0; refused on
-- a raised PP byte, whose maximum is not measured.
-- set_move {slot = 1-6, move_slot = 1-4, move}: a move id, or a name as the game spells it, with its PP at the table's
-- maximum; whether the Pokémon could learn it is not checked.
-- set_status {slot = 1-6, status = "OK" | "PSN"}: only the values the POKéMON menu was seen to draw.
-- Each is refused outside the overworld, and `report` reads the party back.
function game.cheats.set_status(args)
	if not isVanilla then return nil, "set_status is measured on the vanilla V1.0 ROM only" end
	if not inOverworld() or u8(W_BATTLEMODE) ~= 0 then return nil, "set_status refused: not in the overworld" end
	local slot, count, value = math.tointeger(args.slot), u8(W_PARTY_COUNT), nil
	if not slot or slot < 1 or slot > count or count > PARTY_MAX then return nil, string.format("set_status needs slot, 1 to %d", count) end
	for raw, name in pairs(STATUS_NAMES) do
		if type(args.status) == "string" and args.status:upper() == name then value = raw end
	end
	if not value then return nil, "set_status needs status \"OK\" or \"PSN\" (the values measured)" end
	memory.write_u8(W_PARTY_MON1 + (slot - 1) * PARTY_MON_SIZE + PARTY.status, value, "WRAM")
	return {
		limit = 1,
		untilFn = function() return true end,
		report = function()
			local mon = (readParty() or {})[slot]
			return { slot = slot, status_raw = mon and mon.status_raw, status = mon and mon.status, hp = mon and mon.hp }
		end,
	}
end

function game.cheats.set_move(args)
	if not isVanilla then return nil, "set_move is measured on the vanilla V1.0 ROM only" end
	if not inOverworld() or u8(W_BATTLEMODE) ~= 0 then return nil, "set_move refused: not in the overworld" end
	local slot, index = math.tointeger(args.slot), math.tointeger(args.move_slot)
	local count = u8(W_PARTY_COUNT)
	if not slot or slot < 1 or slot > count or count > PARTY_MAX then return nil, string.format("set_move needs slot, 1 to %d", count) end
	if not index or index < 1 or index > 4 then return nil, "set_move needs move_slot, 1 to 4" end
	local id = math.tointeger(args.move)
	if not id and type(args.move) == "string" then
		for k = 1, 251 do
			if moveName(k):upper() == args.move:upper() then id = k break end
		end
	end
	if not id or id < 1 or id > 251 then return nil, "set_move needs move: a name as the game spells it, or an id 1-251" end
	local at = W_PARTY_MON1 + (slot - 1) * PARTY_MON_SIZE
	memory.write_u8(at + PARTY.moves + index - 1, id, "WRAM")
	memory.write_u8(at + PARTY.pp + index - 1, moveData(id).base_pp, "WRAM")
	return {
		limit = 1,
		untilFn = function() return true end,
		report = function()
			local mon = (readParty() or {})[slot]
			return { slot = slot, move_slot = index, moves = mon and mon.moves }
		end,
	}
end

function game.cheats.heal()
	if not isVanilla then return nil, "heal is measured on the vanilla V1.0 ROM only" end
	if not inOverworld() or u8(W_BATTLEMODE) ~= 0 then return nil, "heal refused: not in the overworld" end
	local count = u8(W_PARTY_COUNT)
	if count < 1 or count > PARTY_MAX then return nil, string.format("heal refused: the party count reads %d", count) end
	for k = 0, count - 1 do
		for m = 0, 3 do
			local at = W_PARTY_MON1 + k * PARTY_MON_SIZE
			if u8(at + PARTY.moves + m) ~= 0 and u8(at + PARTY.pp + m) >= PP_RAISED then
				return nil, string.format("heal refused: slot %d move %d has raised PP, not measured", k + 1, m + 1)
			end
		end
	end
	for k = 0, count - 1 do
		local at = W_PARTY_MON1 + k * PARTY_MON_SIZE
		memory.write_u8(at + PARTY.hp, u8(at + PARTY.max_hp), "WRAM")
		memory.write_u8(at + PARTY.hp + 1, u8(at + PARTY.max_hp + 1), "WRAM")
		memory.write_u8(at + PARTY.status, 0, "WRAM")
		for m = 0, 3 do
			local id = u8(at + PARTY.moves + m)
			if id ~= 0 then memory.write_u8(at + PARTY.pp + m, moveData(id).base_pp, "WRAM") end
		end
	end
	return {
		limit = 1,
		untilFn = function() return true end,
		report = function()
			local out = {}
			for _, mon in ipairs(readParty() or {}) do
				local pp = {}
				for _, mv in ipairs(mon.moves) do pp[#pp + 1] = { name = mv.name, pp = mv.pp, base_pp = mv.base_pp } end
				out[#out + 1] = { slot = mon.slot, species = mon.species, hp = mon.hp, max_hp = mon.max_hp, status_raw = mon.status_raw, moves = pp }
			end
			return { party = out }
		end,
	}
end

local function itemPocketOf(id)
	return memory.read_u8(ITEM_ATTRIBUTES + (id - 1) * 7 + 5, "ROM")
end

-- give_item {item, quantity = 1}: `item` a name as the PACK draws it (case and é ignored) or an id, added to its entry
-- or as a new one before the FF; refused past 99, past the pocket's entries and outside the overworld.
local function plain(name) return (name:gsub("é", "e"):upper()) end
function game.cheats.give_item(args)
	if not isVanilla then return nil, "give_item is measured on the vanilla V1.0 ROM only" end
	if not inOverworld() or u8(W_BATTLEMODE) ~= 0 then return nil, "give_item refused: not in the overworld" end
	local names, id = itemNames(), math.tointeger(args.item)
	if not id and type(args.item) == "string" then
		for k, name in ipairs(names) do
			if plain(name) == plain(args.item) then id = k break end
		end
	end
	local quantity = args.quantity == nil and 1 or math.tointeger(args.quantity)
	if not id or id < 1 or id > #names then return nil, "give_item needs item: a name as the PACK draws it, or an id" end
	if not quantity or quantity < 1 or quantity > 99 then return nil, "give_item needs quantity 1-99" end
	-- A TM or HM is a count at its place in the TM/HM pocket.
	if itemPocketOf(id) == 0x04 then
		local at
		for k, tm in ipairs(tmIdList()) do
			if tm == id then at = TM_POCKET.addr + k - 1 end
		end
		if not at then return nil, string.format("give_item: %s is not in the TM/HM pocket's list", names[id]) end
		local had = u8(at)
		if had + quantity > 99 then return nil, string.format("give_item refused: %s has %d, and 99 is the most measured", names[id], had) end
		memory.write_u8(at, had + quantity, "WRAM")
		return {
			limit = 1,
			untilFn = function() return true end,
			report = function() return { item = names[id], id = id, pocket = TM_POCKET.name, had = had, now = u8(at) } end,
		}
	end
	local pocket = POCKETS[itemPocketOf(id)]
	if not pocket then
		return nil, string.format("give_item: %s files under pocket byte %d; only the item (01), key item (02), ball (03) and TM/HM (04) pockets are measured",
			names[id], itemPocketOf(id))
	end
	local at, count = pocket.addr, u8(pocket.addr)
	if count > pocket.slots then return nil, string.format("give_item refused: the %s pocket's count reads %d", pocket.name, count) end
	-- A key item is one byte an entry, with no quantity: added once.
	if pocket.size == 1 then
		if quantity ~= 1 then return nil, "give_item: a key item has no quantity; give 1" end
		for k = 0, count - 1 do
			if u8(at + 1 + k) == id then return nil, string.format("give_item refused: the key item pocket already holds %s", names[id]) end
		end
		if count >= pocket.slots then return nil, string.format("give_item refused: the %s pocket holds %d entries", pocket.name, pocket.slots) end
		memory.write_u8(at + 1 + count, id, "WRAM")
		memory.write_u8(at + 2 + count, 0xFF, "WRAM")
		memory.write_u8(at, count + 1, "WRAM")
		return {
			limit = 1,
			untilFn = function() return true end,
			report = function() return { item = names[u8(at + 1 + count)], id = u8(at + 1 + count), pocket = pocket.name, entries = u8(at) } end,
		}
	end
	local slot, had = nil, 0
	for k = 0, count - 1 do
		if u8(at + 1 + k * 2) == id then slot, had = k, u8(at + 2 + k * 2) end
	end
	if had + quantity > 99 then return nil, string.format("give_item refused: %s has %d, and 99 is the most measured", names[id], had) end
	if not slot then
		if count >= pocket.slots then
			return nil, string.format("give_item refused: the %s pocket holds %d entries", pocket.name, pocket.slots)
		end
		slot = count
		memory.write_u8(at, count + 1, "WRAM")
		memory.write_u8(at + 1 + slot * 2, id, "WRAM")
		memory.write_u8(at + 3 + slot * 2, 0xFF, "WRAM")
	end
	memory.write_u8(at + 2 + slot * 2, had + quantity, "WRAM")
	return {
		limit = 1,
		untilFn = function() return true end,
		report = function()
			return { item = names[id], id = id, pocket = pocket.name, had = had, now = u8(at + 2 + slot * 2), entries = u8(at) }
		end,
	}
end

-- Programs: run once a frame by the driver, each returning (pad or nil, finished, result, error).
game.programs = {}

-- A step begins on the frame the player object's +0x10/+0x11 move to the next tile and ends 14 frames later, when
-- wXCoord/wYCoord catch up; released mid-step, it finishes. So `walk` holds the direction until the last tile's step
-- begins, then waits for rest; after a door the game walks the player off it by itself.
local W_PLAYERMOVEMENT, W_PLAYERSTATE = flat(0xC2DF), flat(0xD95D)
local MOVEMENT_REST, MOVEMENT_REFUSED = 62, 80
-- wPlayerState: on foot, the BICYCLE and surfing each step the way a step on foot does (the bike faster), so `walk` and
-- `goto` ride and surf as they walk.
local MOVEMENT_STATES = { [0] = "on_foot", [1] = "bicycle", [4] = "surfing" }
movementName = function() return MOVEMENT_STATES[u8(W_PLAYERSTATE)] end
-- wTileDown..wTileRight: the engine's collision bytes for the four tiles beside the player, refreshed mid-step.
local W_TILE_DOWN = flat(0xC2FA)
local DIRECTIONS = {
	down = { button = "Down", dx = 0, dy = 1, cached = 0 }, up = { button = "Up", dx = 0, dy = -1, cached = 1 },
	left = { button = "Left", dx = -1, dy = 0, cached = 2 }, right = { button = "Right", dx = 1, dy = 0, cached = 3 },
}
local REST_LIMIT, IDLE_LIMIT, STEP_LIMIT, WARP_LIMIT, WARP_SETTLE = 120, 30, 60, 300, 8

local function stepTarget()
	local b = memory.read_bytes_as_array(PLAYER_STRUCT + 0x10, 2, "WRAM")
	return b[1] - 4, b[2] - 4
end

local function atRest()
	local b = memory.read_bytes_as_array(PLAYER_STRUCT + 0x07, 0x0B, "WRAM")
	return u8(W_PLAYERMOVEMENT) == MOVEMENT_REST and b[1] == 0xFF
		and b[10] - 4 == u8(W_XCOORD) and b[11] - 4 == u8(W_YCOORD)
end

-- What is on a tile a step was refused onto: its collision byte on the map, a warp, a character.
local function describeTile(x, y)
	local blocked = { x = x, y = y }
	local _, c = tileAt(x, y)
	blocked.map_collision_raw = c
	for _, w in ipairs(readWarps()) do
		if w.x == x and w.y == y then blocked.warp_to = w.to end
	end
	for _, o in ipairs(readObjects()) do
		if o.x == x and o.y == y then
			blocked.character = { slot = o.slot, map_object = o.map_object, graphics_id = o.graphics_id }
		end
	end
	return blocked
end

-- walk {direction, tiles}: on foot, on the BICYCLE or surfing, holding the direction from the first tile to the last.
function game.programs.walk(p)
	local name = type(p.direction) == "string" and p.direction:lower() or ""
	local d = DIRECTIONS[name]
	local tiles = math.tointeger(p.tiles)
	if not d then return nil, 'walk needs direction "up", "down", "left" or "right"' end
	if not tiles or tiles < 1 or tiles > 32 then return nil, "walk needs tiles, 1 to 32" end
	if not isVanilla then return nil, "walk is measured on the vanilla V1.0 ROM only" end
	if not MOVEMENT_STATES[u8(W_PLAYERSTATE)] then
		return nil, string.format("walk is measured on foot and on the BICYCLE only; wPlayerState reads %d", u8(W_PLAYERSTATE))
	end

	local hold = { [d.button] = true }
	local phase, frames, idle, moved, settled, startMap = "rest", 0, 0, 0, 0, mapName()
	local lastX, lastY = stepTarget()
	local function finish(outcome, extra)
		local r = { direction = name, requested = tiles, moved = moved, outcome = outcome }
		-- Crystal has no running shoes: a `run` request walks, and says so.
		if p.run == true then r.ran = false end
		for k, v in pairs(extra or {}) do r[k] = v end
		return nil, true, r
	end

	return function()
		frames = frames + 1
		if phase == "warping" then
			-- No input: after the load the game walks the player off the door, a step that begins 2 frames into a rest,
			-- so rest counts only after WARP_SETTLE frames.
			if mapName() ~= startMap and inOverworld() and atRest() then
				settled = settled + 1
				if settled >= WARP_SETTLE then return finish("map_changed", { map = mapName() }) end
			else
				settled = 0
			end
			if frames > WARP_LIMIT then
				return finish(mapName() ~= startMap and "map_changed" or "left_overworld", { map = mapName(), settled = false })
			end
			return nil, false
		end
		if u8(W_MAPSTATUS) == MAPSTATUS_WARPING or mapName() ~= startMap then
			phase, frames = "warping", 0
			return nil, false
		end
		if not inOverworld() then return finish("left_overworld") end
		local t = readTilemap()
		if boxOpen(t) then return finish("dialogue_open") end
		if readMenu(t, false) then return finish("menu_open") end
		-- A script taking over (255): held input does nothing from then on.
		if u8(W_SCRIPT_RUNNING) == SCRIPT_TOOK_OVER then return finish("script_started", { map = mapName() }) end
		-- A trainer seeing the player: wScriptRunning 1, two frames after the step ends.
		if u8(W_SCRIPT_RUNNING) == SCRIPT_SEEN_BY_TRAINER then
			return finish("spotted", { map = mapName(), trainer = { map_object = memory.read_u8(H_LAST_TALKED, "System Bus"),
				tiles_away = u8(W_SEEN_TRAINER_DISTANCE) } })
		end

		local x, y = stepTarget()
		if phase == "rest" then
			if not atRest() then
				if frames > REST_LIMIT then return finish("not_at_rest") end
				return nil, false
			end
			phase, frames, idle, lastX, lastY = "hold", 0, 0, x, y
		end

		if phase == "arriving" then
			if atRest() then return finish("done") end
			if frames > STEP_LIMIT then return finish("not_at_rest") end
			return nil, false
		end

		if phase == "refused" then
			if atRest() then
				local blocked = describeTile(u8(W_XCOORD) + d.dx, u8(W_YCOORD) + d.dy)
				blocked.collision_raw = u8(W_TILE_DOWN + d.cached)
				return finish("blocked", { blocked_by = blocked })
			end
			if frames > STEP_LIMIT then return finish("not_at_rest") end
			return nil, false
		end

		-- hold: a new step, a refusal, or waiting for either.
		if x ~= lastX or y ~= lastY then
			moved = moved + math.abs(x - lastX) + math.abs(y - lastY)
			lastX, lastY, frames, idle = x, y, 0, 0
			if moved >= tiles then
				phase = "arriving"
				return nil, false
			end
			return hold, false
		end
		local movement = u8(W_PLAYERMOVEMENT)
		if movement == MOVEMENT_REFUSED then
			phase, frames = "refused", 0
			return nil, false
		end
		if movement == MOVEMENT_REST then idle = idle + 1 end
		if idle > IDLE_LIMIT or frames > STEP_LIMIT then return finish("no_response") end
		return hold, false
	end
end

-- goto: the shared route planner over `walk`'s and `local_map`'s readings. A tile is open where its collision byte was
-- walked onto (0x00, and 0x18 tall grass) and no character stands; every other byte is closed, the unmeasured ones
-- named in the refusal. A warp is closed unless it is the target: a door (0x71) warps on the step onto it, a mat (0x70)
-- only on a press down while on it. A trainer's line runs its range the way it faces where its movement type was seen
-- standing one way, every way otherwise; one not loaded yet is read from its map-object record.
-- Scoped in a block: its locals are the goto program's alone (a chunk holds at most 200).
do
local WALK_ONTO = { [0x00] = "open", [0x18] = "grass" }
local WATER = 0x29
local CLOSED_MEASURED = { [0x07] = true, [0x15] = true, [0x29] = true, [0xA0] = true, [0xA1] = true, [0xA3] = true }
local WARP_ENTRY = { [0x71] = false, [0x70] = { press = "down" } }
local TRAINER_FACES_ONE_WAY = { [6] = "down", [7] = "up", [8] = "left" }
local MAP_OBJ_COUNT, MAPOBJ_NOT_LOADED = 16, 0xFF
local SIGHT = { down = { 0, 1 }, up = { 0, -1 }, left = { -1, 0 }, right = { 1, 0 } }

-- The map's size in tiles and a collision lookup over the whole map, reading the block buffer once.
local function collisionGrid()
	local w, h = u8(W_MAPWIDTH), u8(W_MAPHEIGHT)
	local bank, ptr = u8(W_TILESET + 6), u8(W_TILESET + 7) | (u8(W_TILESET + 8) << 8)
	if w < 1 or h < 1 or ptr < 0x4000 or ptr > 0x7FFF then return nil end
	local blocks = memory.read_bytes_as_array(W_BLOCKS, (w + 6) * (h + 6), "WRAM")
	local quads = {}
	return w * 2, h * 2, function(x, y)
		local block = blocks[(y // 2 + 3) * (w + 6) + (x // 2 + 3) + 1]
		local c = quads[block]
		if not c then
			c = memory.read_bytes_as_array(bank * 0x4000 + (ptr - 0x4000) + block * 4, 4, "ROM")
			quads[block] = c
		end
		return c[(y % 2) * 2 + (x % 2) + 1]
	end
end

local function routeGrid(fromX, fromY, toX, toY)
	local mapW, mapH, collision = collisionGrid()
	local surfing = MOVEMENT_STATES[u8(W_PLAYERSTATE)] == "surfing"
	if not mapW then return nil, "no map loaded" end
	local blocked, objects = {}, readObjects()
	for _, o in ipairs(objects) do
		if o.x >= 0 and o.y >= 0 then blocked[o.y * mapW + o.x] = "character" end
	end
	local targetWarp = false
	for _, w in ipairs(readWarps()) do
		if w.x == toX and w.y == toY then
			targetWarp = true
		else
			blocked[w.y * mapW + w.x] = blocked[w.y * mapW + w.x] or "warp"
		end
	end
	-- Every unbeaten trainer, loaded or not: an unloaded one's tile and movement type are its record's, and its tile is
	-- closed as a loaded one's would be.
	local trainers, byMapObject = {}, {}
	for _, o in ipairs(objects) do byMapObject[o.map_object] = o end
	for i = 1, MAP_OBJ_COUNT - 1 do
		local t = trainerOf(i)
		local o = byMapObject[i]
		if t and not t.beaten then
			if o then
				trainers[#trainers + 1] = { x = o.x, y = o.y, map_object = i, trainer = t,
					facing = TRAINER_FACES_ONE_WAY[o.movement_type_raw] and o.facing or nil }
			else
				local r = memory.read_bytes_as_array(W_MAP_OBJECTS + i * MAP_OBJ_SIZE, 5, "WRAM")
				if r[1] == MAPOBJ_NOT_LOADED then
					local x, y = r[4] - 4, r[3] - 4
					trainers[#trainers + 1] = { x = x, y = y, map_object = i, trainer = t, facing = TRAINER_FACES_ONE_WAY[r[5]] }
					if x >= 0 and y >= 0 and x < mapW and y < mapH then blocked[y * mapW + x] = blocked[y * mapW + x] or "trainer" end
				end
			end
		end
	end
	local seen = {}
	for _, o in ipairs(trainers) do
		local t = o.trainer
		do
			local ways = o.facing and { o.facing } or { "down", "up", "left", "right" }
			for _, way in ipairs(ways) do
				for k = 1, t.range do
					local x, y = o.x + SIGHT[way][1] * k, o.y + SIGHT[way][2] * k
					if x >= 0 and y >= 0 and x < mapW and y < mapH and not seen[y * mapW + x] then
						seen[y * mapW + x] = { x = o.x, y = o.y, map_object = o.map_object }
					end
				end
			end
		end
	end
	local unmeasured, names = {}, {}
	for y = 0, mapH - 1 do
		for x = 0, mapW - 1 do
			local c = collision(x, y)
			if not WALK_ONTO[c] and not CLOSED_MEASURED[c] and WARP_ENTRY[c] == nil and not unmeasured[c] then
				unmeasured[c] = true
				names[#names + 1] = string.format("0x%02X", c)
			end
		end
	end
	table.sort(names)
	return {
		width = mapW, height = mapH,
		where = #names > 0 and ("(collision " .. table.concat(names, ", ") .. " planned as closed: not measured)") or nil,
		tile = function(x, y)
			if blocked[y * mapW + x] then return nil end
			local c = collision(x, y)
			if targetWarp and x == toX and y == toY then
				if WARP_ENTRY[c] == nil then return nil end
				return true, false, seen[y * mapW + x]
			end
			-- Surfing, the route stays on the water (0x29), and land is open only as the target: a step ashore ends the
			-- surf.
			if surfing then
				if c == WATER then return true, false, seen[y * mapW + x] end
				if not (x == toX and y == toY) then return nil end
			end
			local kind = WALK_ONTO[c]
			if not kind then return nil end
			return true, kind == "grass", seen[y * mapW + x]
		end,
	}
end

local routeHooks = {
	position = function()
		local x, y = stepTarget()
		return mapName(), x, y
	end,
	inOverworld = inOverworld,
	-- `walk`'s early stops, in its order: a message or a menu on screen, a script taking the controls, a trainer's
	-- sight.
	watch = function()
		return function()
			local t = readTilemap()
			if boxOpen(t) then return "dialogue_open" end
			if readMenu(t, false) then return "menu_open" end
			local s = u8(W_SCRIPT_RUNNING)
			if s == SCRIPT_TOOK_OVER then return "script_started", { map = mapName() } end
			if s == SCRIPT_SEEN_BY_TRAINER then
				return "spotted", { map = mapName(), trainer = { map_object = memory.read_u8(H_LAST_TALKED, "System Bus"),
					tiles_away = u8(W_SEEN_TRAINER_DISTANCE) } }
			end
			return nil
		end
	end,
	arriving = function()
		local startMap, settled = mapName(), 0
		return function()
			if u8(W_MAPSTATUS) == MAPSTATUS_WARPING then
				settled = 0
				return true
			end
			if mapName() == startMap then return false end
			if inOverworld() and atRest() then settled = settled + 1 else settled = 0 end
			return settled < WARP_SETTLE
		end
	end,
	atRest = atRest,
	refused = function() return u8(W_PLAYERMOVEMENT) == MOVEMENT_REFUSED end,
	idle = function() return u8(W_PLAYERMOVEMENT) == MOVEMENT_REST end,
	-- On foot, with nothing held but the direction: Crystal has no running shoes.
	ride = function() return {} end,
	routeGrid = routeGrid,
	warps = readWarps,
	enterWarp = function(w) return WARP_ENTRY[w.collision_raw] or nil end,
	blockedBy = describeTile,
	limits = { rest = REST_LIMIT, idle = IDLE_LIMIT, press = STEP_LIMIT, door = WARP_LIMIT, step = STEP_LIMIT },
}

-- goto {x, y, cross_grass}: to a tile on this map, on foot, on the BICYCLE or surfing.
game.programs["goto"] = function(p)
	if not isVanilla then return nil, "goto is measured on the vanilla V1.0 ROM only" end
	-- Another map's tables are not read here yet.
	if p.map ~= nil and p.map ~= mapName() then return nil, "goto to another map is not built for Crystal yet" end
	if not MOVEMENT_STATES[u8(W_PLAYERSTATE)] then
		return nil, string.format("goto is measured on foot and on the BICYCLE only; wPlayerState reads %d", u8(W_PLAYERSTATE))
	end
	return lib.route.go(routeHooks, p)
end
end

-- hJoyDown is the game's own copy of the buttons, updated only when it looks at them: 0 once it has seen a release.
local H_JOY_DOWN = 0xFFA8
function game.inputReleased()
	return memory.read_u8(H_JOY_DOWN, "System Bus") == 0
end

-- The menu alone, for a program that looks every frame (select).
function game.menu()
	if not isVanilla then return nil end
	local _, low = readFont()
	local m = readMenu(readTilemap(), low)
	return itemPocketMenu(m) or partyMenu(m, readTilemap(), low) or m
end

-- advance_text and battle: the shared machine over Crystal's reads. Progress is any change in the tile buffer, the
-- state bytes or the player's tile (a scene walks the player). hJoyDown's bit 0 is A, so a tap holds A until the game
-- has seen it.
local function textAndMenuNow()
	local t = readTilemap()
	local _, low = readFont()
	return t, readTextAndMenu(t, low)
end

local textHooks = {
	signature = function()
		local t, d = textAndMenuNow()
		local cells = {}
		for i = 1, #t do cells[i] = string.char(t[i]) end
		local parts = { table.concat(cells), u8(W_MAPSTATUS), u8(W_BATTLEMODE), u8(W_SCRIPT_RUNNING), u8(W_TEXTBOX_FLAGS),
			u8(W_MENU_CURSOR_Y), u8(W_MENU_CURSOR_X), mapName(), u8(W_XCOORD), u8(W_YCOORD), d and d.state or "-" }
		return table.concat(parts, "|"), d
	end,
	readDialogue = function()
		local _, d = textAndMenuNow()
		return d
	end,
	inBattle = function() return u8(W_BATTLEMODE) ~= 0 end,
	battleMenu = function()
		local _, _, m = textAndMenuNow()
		local asking = battleAskingFor(m)
		if not asking then return nil end
		return asking, m
	end,
	-- Any value but 0: a trainer's approach and the quiet before its battle read 1, not 255.
	scriptRunning = function() return u8(W_SCRIPT_RUNNING) ~= 0 end,
	inOverworld = inOverworld,
	readMenu = function()
		local _, _, m = textAndMenuNow()
		return m
	end,
	actionIndex = { fight = 0, run = 3 },
	inputReleased = function() return game.inputReleased() end,
	tapSeen = function() return (memory.read_u8(0xFFA8, "System Bus") & 0x01) ~= 0 end,
	-- The level-up stats box: a frame from (9,0) to (19,11) with ATTACK at row 1 from column 11, waiting with no ▼.
	levelUpPage = function()
		local t = readTilemap()
		if cell(t, 9, 0) ~= 0x79 or cell(t, 19, 0) ~= 0x7B or cell(t, 9, 11) ~= 0x7D or cell(t, 19, 11) ~= 0x7E then return nil end
		for i, b in ipairs({ 0x80, 0x93, 0x93, 0x80, 0x82, 0x8A }) do
			if cell(t, 10 + i, 1) ~= b then return nil end
		end
		if not waitingInBattle() then return nil end
		return "stats", "waiting"
	end,
	-- Any other menu in a battle (not the action grid, the move list or the PACK's list) is a question, so `battle`
	-- stops on it rather than nudge A. `no` is NO's index on the switch question; the nickname question is the caller's
	-- choice, so it carries no `no`.
	battleQuestion = function()
		if u8(W_BATTLEMODE) == 0 then return nil end
		local t = readTilemap()
		local _, low = readFont()
		local m = readMenu(t, low)
		if not m or battleAskingFor(m) or itemPocketMenu(m) then return nil end
		local lines = {}
		for r = BOX_TOP + 1, BOX_BOTTOM - 1 do
			local s = decodeCells(t, r, 1, 18, low)
			if s ~= "" then lines[#lines + 1] = s end
		end
		local q = { kind = "unread", text = table.concat(lines, "\n"), menu = { items = m.items, cursor = m.cursor } }
		if #m.items == 2 and m.items[1] == "YES" and m.items[2] == "NO" then
			if lines[#lines] == "change POKéMON?" then
				q.kind, q.no = "switch", 1
			elseif lines[1] == "Give a nickname to" then
				q.kind = "nickname"
			elseif lines[#lines] == "Use next POKéMON?" then
				-- After the lead faints: NO runs from a wild battle, YES opens the party list.
				q.kind = "next_pokemon"
			end
		end
		-- The party list in a battle ("Which PKMN?"), read as the POKéMON menu is: a Pokémon is chosen by name with
		-- select.
		local party = partyMenu(m, t, low)
		if party then q.kind, q.menu = "party", { items = party.items, cursor = party.cursor } end
		return q
	end,
	strongestMove = function()
		local slot, name = strongestMoveSlot()
		if slot == nil then return nil, "no move has measured PP left" end
		return slot, name
	end,
	-- Policy "effective": the type table, the same-type bonus and the stats the damage uses (strongestMoveSlot, above).
	effectiveMove = function()
		local slot, name, detail = strongestMoveSlot(true)
		if slot == nil then return nil, "no move has measured PP left" end
		return slot, name, detail
	end,
	endedReport = battleEndedReport,
}

-- battle and advance_text: the shared machine's (`lib.text`), with Crystal's hooks.
game.programs.battle = function(p)
	if not isVanilla then return nil, "battle is measured on the vanilla V1.0 ROM only" end
	return lib.text.battle(textHooks, p)
end

game.programs.advance_text = function()
	if not isVanilla then return nil, "advance_text is measured on the vanilla V1.0 ROM only" end
	return lib.text.advanceText(textHooks)
end

-- What `changed` compares between two observations: the fields a press is expected to move.
function game.diffKeys(o)
	return {
		mode = o.mode,
		map = o.location.map,
		x = o.location.x,
		y = o.location.y,
		facing = o.location.facing or "none",
		dialogue_state = o.dialogue and o.dialogue.state or "none",
		dialogue_box = o.dialogue and o.dialogue.box or "",
		menu_cursor = o.menu and o.menu.cursor or "none",
		battle_mode_raw = o.extras.battle_mode_raw,
	}
end

-- Read every frame for events: a map or mode change, and a message box or menu opening or closing. It also keeps
-- the text tracker the dialogue's state is read from.
function game.watch()
	local out = {
		map = mapName(),
		mode = modeName(),
		battle_mode_raw = u8(W_BATTLEMODE),
	}
	if isVanilla then
		local t = readTilemap()
		trackText(t)
		out.dialogue = boxOpen(t) and "open" or "closed"
		out.menu = readMenu(t, false) and "open" or "closed"
	end
	return out
end

return game
