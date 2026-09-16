-- autoplay BizHawk driver: vanilla Pokémon Crystal (DEV TOOL, never shipped).
--
-- Addresses come from our pokecrystal V1.0 build, whose .gbc hashes identical to the vanilla ROM
-- (VANILLA_SHA1). What each byte MEANS is what `adapters/emulator/pokemon/crystal/probes/` measured on
-- the running game, recorded in that adapter's MEASURED.md; a byte whose meaning is not measured goes
-- out raw under `extras`, never named.

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local function u8(a) return memory.read_u8(a, "WRAM") end
local function rom8(bank, ptr) return memory.read_u8(bank * 0x4000 + (ptr - 0x4000), "ROM") end

-- The SHA-1 of the vanilla V1.0 ROM file and of our pokecrystal build (sha1sum), and what
-- gameinfo.getromhash() returned for it (autoplay_state_probe.lua, 2026-09-17).
local VANILLA_SHA1 = "F4CD194BDEE0D04CA4EAC29E09B8E4E9D818C133"
local romHash = (function()
	local ok, h = pcall(gameinfo.getromhash)
	return ok and type(h) == "string" and h:upper() or ""
end)()
local isVanilla = romHash == VANILLA_SHA1

-- POSITION AND MODE (autoplay_state_probe.lua, 2026-09-17, vanilla V1.0: a cold boot to CONTINUE,
-- walks in all four directions, a bump, a sign, the START menu, the PACK, the POKéGEAR and a door both
-- ways; that adapter's MEASURED.md, same date).
--   * wMapGroup/wMapNumber read 0.0 through the intro, title and main menu and 24.4 once CONTINUE had
--     loaded the town; wXCoord/wYCoord are the player's tile and change on the frame a step ENDS.
--   * wMapStatus read 0 until the town was running, then 2 through walking, a sign's text and the START
--     menu, and 1 from the frame after stepping onto a door until the new map was running (32-37 frames).
--     wSpriteUpdatesEnabled read 1 in all of those and 0 while the PACK or the POKéGEAR filled the
--     screen. So the overworld is status 2 with sprite updates on.
local W_MAPGROUP, W_MAPNUMBER, W_YCOORD, W_XCOORD = flat(0xDCB5), flat(0xDCB6), flat(0xDCB7), flat(0xDCB8)
local W_MAPSTATUS, W_SPRITEUPDATES, W_BATTLEMODE = flat(0xD432), flat(0xC2CE), flat(0xD22D)
local MAPSTATUS_WARPING, MAPSTATUS_RUNNING = 1, 2
local W_SCRIPT_RUNNING, SCRIPT_TOOK_OVER = flat(0xD438), 255 -- wScriptMode is the byte before it
-- The player's object, 0x28 bytes: +0x08 the way it faces (0x00 down, 0x04 up, 0x08 left, 0x0C right --
-- each read after a turn that way), +0x10/+0x11 the tile a step is going to (wXCoord/wYCoord plus 4).
local PLAYER_STRUCT = flat(0xD4D6)
local FACING = { [0x00] = "down", [0x04] = "up", [0x08] = "left", [0x0C] = "right" }

-- The map's warp list: a count and a pointer into the bank the map's scripts are in, 5 bytes an entry:
-- y, x, the destination's warp number counted from 1, and its map group and number. Walked both ways on
-- 2026-09-17: 24.4's fourth entry (13, 11, 1, 24, 9) is the door at (11,13), which led to 24.9 at
-- (2,7), the tile of 24.9's first entry; stepping off that mat led back to 24.4 at (11,13).
local W_WARP_COUNT, W_WARP_PTR, W_MAP_SCRIPTS_BANK = flat(0xDBFB), flat(0xDBFC), flat(0xD1A3)

local function inOverworld()
	return u8(W_MAPSTATUS) == MAPSTATUS_RUNNING and u8(W_SPRITEUPDATES) == 1
end

-- THE MAP AROUND THE PLAYER (autoplay_map_probe.lua, 2026-09-17, vanilla V1.0, read against captures on the same
-- tile; that adapter's MEASURED.md, same date). A tile's collision is quadrant (y%2)*2 + (x%2) of block (x//2, y//2),
-- whose id is at (by+3)*(wMapWidth+6) + (bx+3) in wOverworldMapBlocks, looked up in the loaded tileset's collision
-- table (bank at wTileset+6, pointer at +7) -- cmd_drive.lua's formula (2026-09-16), which agreed tile for tile with
-- New Bark Town's capture: roofs, walls, the sign and the mailbox 0x07, both doors 0x71, open ground and the grass
-- patches 0x00. The map is wMapWidth by wMapHeight blocks; the buffer holds 3 more blocks of border each side.
local W_MAPHEIGHT, W_MAPWIDTH, W_BLOCKS, W_TILESET = flat(0xD19E), flat(0xD19F), flat(0xC800), flat(0xD1D9)
local VIEW_W, VIEW_H = 7, 5 -- tiles either side: 15 by 11, more than the screen's 10 by 9
-- What a collision byte did when stepped into, where measured. Anything else is listed by number.
local COLLISION_NOTES = {
	[0x07] = "a step refused (roofs, walls, signs)",
	[0x29] = "water: a step on foot refused",
	[0x71] = "a door: stepping on it warped",
	[0x15] = "a step refused (drawn as trees, New Bark's south edge)",
	[0x18] = "tall grass: walked on; a wild battle began on the 4th step in it (Route 29)",
	-- cmd_drive.lua's hops on vanilla V1.0 (2026-09-16).
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

-- The other characters: object records 1-12 whose first byte (the graphic) is not 0; record 0 is the player (its
-- +0x10/+0x11 are wXCoord/wYCoord plus 4). The girl at (6,8) and the man at (12,9) in New Bark Town's capture were
-- records 1 and 2: +0x01 their index in the map's object list, +0x10/+0x11 their tile plus 4, +0x08 the way they
-- faced as drawn (0x00 down for the girl, 0x04 up for the man) -- the player's own codes.
local W_OBJECTS, OBJ_SIZE, OBJ_COUNT = flat(0xD4D6), 0x28, 13

local function readObjects()
	local out = {}
	for s = 1, OBJ_COUNT - 1 do
		local b = memory.read_bytes_as_array(W_OBJECTS + s * OBJ_SIZE, 0x12, "WRAM")
		if b[1] ~= 0 then
			out[#out + 1] = { slot = s, map_object = b[2], graphics_id = b[1], x = b[17] - 4, y = b[18] - 4,
				facing = FACING[b[9]], facing_raw = not FACING[b[9]] and b[9] or nil, movement_type_raw = b[4] }
		end
	end
	return out
end

-- The map's bg events, 5 bytes each: y, x, then a kind and a script pointer. The sign at (8,8) in New Bark Town, the
-- entry (8, 8, 0), showed "NEW BARK TOWN" when faced and A pressed.
local W_BG_COUNT, W_BG_PTR = flat(0xDC01), flat(0xDC02)

local function mapName()
	return string.format("%d.%d", u8(W_MAPGROUP), u8(W_MAPNUMBER))
end

-- A wild battle: wBattleMode went 0 to 1 about 180 frames after the encounter's script began in the grass, on the
-- same frame wSpriteUpdatesEnabled went to 0, and read 1 through the battle's text and both menus
-- (autoplay_state_probe.lua, 2026-09-17, a PIDGEY on Route 29). A trainer battle is not measured on this build.
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
		out[#out + 1] = { x = rom8(bank, at + 1), y = rom8(bank, at),
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

-- TEXT AND MENUS (2026-09-17, vanilla V1.0: `autoplay_text_probe.lua` through a sign's three boxes, the START
-- menu's cursor, SAVE's box and its YES/NO; `autoplay_charset_probe.lua`; that adapter's MEASURED.md, same date).
-- The screen's text IS the game's 20 by 18 tile buffer: every letter printed was written there, one a frame, and
-- the map's own tiles came back on the frame a box closed.
local TILEMAP, COLS, ROWS = flat(0xC4A0), 20, 18
-- What each byte draws, named from captures of the game drawing 0x60-0xFF inside a message box (the charset
-- probe) and checked against every word of real text read: the sign, the START menu and its descriptions, the
-- save box and the YES/NO. A byte that draws nothing, or is below 0x60 (the map's tiles), reads as {XX}.
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

-- WHICH FONT IS LOADED (autoplay_font_probe.lua, 2026-09-17: a 32-bit FNV-1a checksum of the tiles' 16 bytes each in
-- VRAM bank 0; LCDC read E3 throughout).
--   * Ids 0x80-0xB9 (0x0800 in VRAM): ABC168AD on every screen whose text was read correctly -- the main menu, the
--     START menu, the town sign's box, Elm's question, and a wild battle -- A75F347B with a Pokémon's picture drawn
--     with those ids in Elm's lab (which `screen_text` had read as "AHOV:dk"), CF66AFAD in the town with no text up.
--   * Ids 0x60-0x7F (0x1600): 463433A3 on the sign, the main menu and the lab, 0E4FC271 in the battle. The charset
--     probe named them in each: the message box's table below, and in the battle only 0x6E (":L", the level mark
--     before PIDGEY's 3), 0x75 (…) and the box frame; the rest there were pieces of the HP bars.
--   * 0xBA-0xFF: 55247223 on all of those screens.
-- Two reads of 928 and 512 bytes and loops over them, so only observe and select read it, never the per-frame watch.
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

-- The message box: its frame at rows 12-17 (79 and 7B the top corners, 7D and 7E the bottom ones, 7C the sides),
-- lines printed on rows 14 and 16 and scrolled up through 13 and 15, columns 1-18. While a box waited for a button
-- 0xEE (the ▼) blinked at (18,17), 16 frames on and 16 off. wTextboxFlags read 3 from the frame before a message's
-- first letter and 1 from the frame after its last -- the sign's last box, and the save question on the frame its
-- YES/NO was drawn -- until the next message.
local BOX_TOP, BOX_BOTTOM, ARROW_COL = 12, 17, 18
local W_TEXTBOX_FLAGS, TEXTBOX_PRINTING = flat(0xCFCF), 0x02
local ARROW, BLINK_GAP = 0xEE, 20

-- A menu with a cursor: wWindowStackSize counted the windows open (START 1, its save box 2, the YES/NO 4, then 3,
-- 2 and 1 as B closed them; the sign's box opened none). The block the build names w2DMenuData held the first
-- item's row and the cursor's
-- column (CFA1, CFA2: 2 and 11 on START, 8 and 1 on the YES/NO), how many rows (6, 2) and columns (1, 1), and
-- the rows between items in the high nibble of CFA7 (0x20, drawn 2 apart on both); wMenuCursorY counted from 1
-- (one Down press moved it one item, and the ▶ was drawn on that row); wCursorCurrentTile pointed at the ▶'s
-- cell. wMenuBorderRightCoord was the frame's right column (19, 5). The ▶ became ▷ (0xEC) once A chose SAVE,
-- so a menu counts as waiting for a choice only while its ▶ is drawn at the cursor's cell.
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
	end
	return true
end

-- Kept once a frame by game.watch(): when the box's lines last changed, and when the ▼ was last drawn.
local track = { lines = nil, changedAt = -1, arrowAt = -1 }
local function trackText(t)
	local f = emu.framecount()
	local b = {}
	for r = BOX_TOP + 1, BOX_BOTTOM - 1 do
		for c = 1, 18 do b[#b + 1] = string.char(cell(t, c, r)) end
	end
	local lines = table.concat(b)
	if lines ~= track.lines then track.lines, track.changedAt = lines, f end
	if cell(t, ARROW_COL, BOX_BOTTOM) == ARROW then track.arrowAt = f end
end

local function readDialogue(t, low)
	if not boxOpen(t) then return nil end
	local lines = {}
	for r = BOX_TOP + 1, BOX_BOTTOM - 1 do
		local s = decodeCells(t, r, 1, 18, low)
		if s ~= "" then lines[#lines + 1] = s end
	end
	local f, state = emu.framecount(), nil
	if cell(t, ARROW_COL, BOX_BOTTOM) == ARROW
		or (track.arrowAt >= track.changedAt and f - track.arrowAt >= 0 and f - track.arrowAt <= BLINK_GAP) then
		state = "waiting_for_button"
	elseif (u8(W_TEXTBOX_FLAGS) & TEXTBOX_PRINTING) ~= 0 or #lines == 0 then
		-- An empty frame was drawn 4 frames before the save question began printing.
		state = "printing"
	else
		state = "finished"
	end
	return { box = table.concat(lines, "\n"), state = state }
end

-- IN A BATTLE (autoplay_text_probe.lua, 2026-09-17, a wild PIDGEY on Route 29): the action menu used the same block --
-- first row 14 and cursor column 9, 2 rows by 2 columns, CFA7 0x26 (items 2 rows and 6 columns apart: FIGHT at
-- column 10, PKMN at 16), wMenuCursorY and wMenuCursorX (CFAA) both from 1, the ▶ at wCursorCurrentTile. The move
-- menu that FIGHT opened read first row 13, column 5, 2 rows (the two moves CYNDAQUIL knows) by 1, CFA7 0x10, with
-- wWindowStackSize at 0 -- so in a battle a menu counts without a window. Its frame's right column (CF85) still read
-- the action menu's 19, which is also the move box's.
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

local game = {
	game = "crystal",
	variant = isVanilla and "vanilla" or "unverified",
	capabilities = { "observe", "press", "wait", "screenshot", "snapshot", "restore", "walk", "select" },
	-- The START menu: Down moved the cursor one item a press and A chose it (2026-09-17).
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
	track = { lines = nil, changedAt = -1, arrowAt = -1 }
end

function game.observe()
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
		d = readDialogue(t, low)
		m, menuRows = readMenu(t, low)
		-- A menu drawn inside the message box's frame (the battle's action menu) is not a message.
		if d and menuRows then
			for r = BOX_TOP + 1, BOX_BOTTOM - 1 do
				if menuRows[r] then d = nil end
			end
		end
		if letters then
			s = readScreenText(t, d, menuRows, low)
			if #s == 0 then s = nil end
		end
	end
	return {
		frame = emu.framecount(),
		dialogue = d,
		menu = m,
		screen_text = s,
		local_map = localMap,
		nearby = (nearby and #nearby > 0) and nearby or nil,
		mode = modeName(),
		location = { map = mapName(), x = u8(W_XCOORD), y = u8(W_YCOORD), facing = overworld and FACING[ps[9]] or nil },
		warps = (warps and #warps > 0) and warps or nil,
		extras = {
			map_status_raw = u8(W_MAPSTATUS),
			sprite_updates_raw = u8(W_SPRITEUPDATES),
			battle_mode_raw = u8(W_BATTLEMODE),
			-- wScriptRunning read 255 (wScriptMode 1) while a message, a menu or a Pokémon's picture waited -- the
			-- picture with no message box, so this is the only sign the game is waiting for a button then; 9
			-- during a turn, 5 during a door's warp, 0 walking (autoplay_state_probe.lua, 2026-09-17).
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

-- PROGRAMS: run once a frame by the driver, each returning (pad or nil, finished, result, error).
game.programs = {}

-- A STEP ON FOOT (autoplay_state_probe.lua, 2026-09-17, vanilla V1.0, New Bark Town and a house: held
-- walks in all four directions, a bump into a roof from a step and from rest, a door each way). The overworld
-- moved the player only on even frames, every 2 frames.
--   * wWalkingDirection (and wPlayerStepDirection while a step runs) read 0 down, 1 up, 2 left, 3 right.
--   * wPlayerMovement read 62 at rest, 4 + that code while turning (6 frames, when the press faced another
--     way), 12 + it while stepping, and 80 while a step was refused -- for as long as the direction was held,
--     with the coordinates unchanged.
--   * A step BEGINS on the frame the player object's +0x10/+0x11 move to the next tile (+0x07 reading 4 +
--     the code, FF otherwise) and ENDS 14 frames later, when wXCoord/wYCoord and +0x12/+0x13 catch up; with
--     the direction still held the next step begins 2 frames after that, and released at any point during a
--     step, the step finished and the player stood (62) 2 frames after its end.
--   * A step onto a door ended and wMapStatus read 1 on the next frame; stepping toward the edge while on a
--     door mat inside turned the player and went straight to 1, with no step. Once the new map ran (status 2)
--     the game stepped the player off the outside door by itself, and only then stood.
-- So `walk` holds the direction until the last tile's step begins, then waits for rest; a door waits for the
-- new map to run and the player to stand.
local W_PLAYERMOVEMENT, W_PLAYERSTATE = flat(0xC2DF), flat(0xD95D)
local MOVEMENT_REST, MOVEMENT_REFUSED = 62, 80
-- wPlayerState read 0 walking; nothing else is measured, so `walk` refuses anything else.
local PLAYERSTATE_ON_FOOT = 0
-- The engine's own collision bytes for the four tiles beside the player, in the order down, up, left, right:
-- 7 beside the roof the player bumped from above and beside the sign they turned to from below; 0 beside open
-- ground. They are refreshed mid-step. Other values go out raw.
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

-- walk {direction, tiles}: on foot only, holding the direction from the first tile to the last.
function game.programs.walk(p)
	local name = type(p.direction) == "string" and p.direction:lower() or ""
	local d = DIRECTIONS[name]
	local tiles = math.tointeger(p.tiles)
	if not d then return nil, 'walk needs direction "up", "down", "left" or "right"' end
	if not tiles or tiles < 1 or tiles > 32 then return nil, "walk needs tiles, 1 to 32" end
	if not isVanilla then return nil, "walk is measured on the vanilla V1.0 ROM only" end
	if u8(W_PLAYERSTATE) ~= PLAYERSTATE_ON_FOOT then
		return nil, string.format("walk is measured on foot only; wPlayerState reads %d", u8(W_PLAYERSTATE))
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
			-- No input: the new map loads, and the game walks the player off the door by itself -- a step that
			-- began 2 frames after the map ran, with the player at rest on those 2 frames, so rest has to hold
			-- for WARP_SETTLE frames before it counts (a first version answered on the door tile).
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
		-- A script taking over: wScriptRunning went 0 to 255 on the frame after the step onto New Bark's west exit
		-- (wScriptMode 1, "Wait, A!" 10 frames later) and onto the tile where Elm's aide walks over (mode 2, her
		-- walk first); walking itself only ever read 9 (a turn) or 5 (a door). Held input then does nothing.
		if u8(W_SCRIPT_RUNNING) == SCRIPT_TOOK_OVER then return finish("script_started", { map = mapName() }) end

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
				local px, py = u8(W_XCOORD), u8(W_YCOORD)
				local blocked = { x = px + d.dx, y = py + d.dy, collision_raw = u8(W_TILE_DOWN + d.cached) }
				local _, c = tileAt(blocked.x, blocked.y)
				blocked.map_collision_raw = c
				for _, w in ipairs(readWarps()) do
					if w.x == blocked.x and w.y == blocked.y then blocked.warp_to = w.to end
				end
				for _, o in ipairs(readObjects()) do
					if o.x == blocked.x and o.y == blocked.y then
						blocked.character = { slot = o.slot, map_object = o.map_object, graphics_id = o.graphics_id }
					end
				end
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

-- Whether the game has seen every button released: hJoyDown is the game's own copy of the buttons, updated
-- when it looks at them -- in the START menu it read Down at f16525, still Down 36 frames later while it was
-- held, and 0 only once it was let go (autoplay_text_probe.lua, 2026-09-17). The driver's select waits for this
-- between cursor moves.
local H_JOY_DOWN = 0xFFA8
function game.inputReleased()
	return memory.read_u8(H_JOY_DOWN, "System Bus") == 0
end

-- The menu alone, for a program that looks every frame (select).
function game.menu()
	if not isVanilla then return nil end
	local _, low = readFont()
	return (readMenu(readTilemap(), low))
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
