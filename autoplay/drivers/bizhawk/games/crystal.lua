-- autoplay BizHawk driver: vanilla Pokémon Crystal (DEV TOOL, never shipped).
--
-- Addresses come from our pokecrystal V1.0 build, whose .gbc hashes identical to the vanilla ROM
-- (VANILLA_SHA1). What each byte MEANS is what `adapters/emulator/pokemon/crystal/probes/` measured on
-- the running game, recorded in that adapter's MEASURED.md; a byte whose meaning is not measured goes
-- out raw under `extras`, never named.

-- The shared driver library the driver hands every game module (driver.lua: `text`).
local lib = ...

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
-- A trainer's sight (see `walk`): wScriptRunning 1, the trainer's map object in hLastTalked, its distance in D03F.
local SCRIPT_SEEN_BY_TRAINER, H_LAST_TALKED, W_SEEN_TRAINER_DISTANCE = 1, 0xFFE0, flat(0xD03F)
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

-- TRAINERS (autoplay_trainer_probe.lua and autoplay_map_probe.lua, 2026-09-17, vanilla V1.0, Bug Catcher Don on Route 30;
-- MEASURED.md, "A trainer battle: sight, approach, words and the result"). The map-object records, 0x10 bytes each from
-- D71E, indexed by an object record's +0x01: Don's (4) read +0x00 the object record holding him (2), +0x01 his graphic
-- (37), +0x02/+0x03 his tile plus 4, following his walk, +0x08 0xB2 (low nibble 2, as on the route's other two trainers'
-- records and no other), +0x09 3 -- he came for the player three tiles below him and not four -- and +0x0A a pointer into
-- wMapScriptsBank to 12 bytes whose first two are his defeat flag (1336, set once he was beaten: bit 0 of wEventFlags
-- (DA72) + 167, 0 before the battle and 1 after), then the class and id wOtherTrainerClass/ID read during it (36, 1).
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

-- The map's bg events, 5 bytes each: y, x, then a kind and a script pointer. The sign at (8,8) in New Bark Town, the
-- entry (8, 8, 0), showed "NEW BARK TOWN" when faced and A pressed.
local W_BG_COUNT, W_BG_PTR = flat(0xDC01), flat(0xDC02)

local function mapName()
	return string.format("%d.%d", u8(W_MAPGROUP), u8(W_MAPNUMBER))
end

-- A wild battle: wBattleMode went 0 to 1 about 180 frames after the encounter's script began in the grass, on the
-- same frame wSpriteUpdatesEnabled went to 0, and read 1 through the battle's text and both menus
-- (autoplay_state_probe.lua, 2026-09-17, a PIDGEY on Route 29). It read 2 from "BUG CATCHER DON wants to battle!" to the
-- end of his battle (autoplay_trainer_probe.lua, the same day, Route 30).
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
	-- An unbeaten trainer's line: its range of tiles the way it faces now (Don faced down and came from three tiles).
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
		-- No message had a frame tile inside it; the battle's action menu splits the same rows with a 0x7C column
		-- at 8, drawn before its ▶ (text.lua's log caught it, 2026-09-17).
		for c = 1, 18 do
			local b = cell(t, c, r)
			if b >= 0x79 and b <= 0x7E then return false end
		end
	end
	return true
end

-- Kept once a frame by game.watch(): when the box's lines last changed, and when the ▼ was last drawn.
-- A wait for A with no ▼ in a battle: wTextDelayFrames (CFB2) counted 5, 4, 3, 2, 1 and back to 5 for as long as the
-- level-up stats box (31 times) and "Argh! You're too strong!" after Bug Catcher Don's defeat (36 times) waited, both
-- with wTextboxFlags 1 and no ▼, until A. Across that battle it went from 1 back to 5 on no other screen; at the action
-- menu it counted down once, as A was pressed (autoplay_text_probe.lua, 2026-09-17). `cycles` counts the returns to 5
-- since the box's rows last changed.
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
	-- A battle's box is cleared over 2 frames, row 14 on the first and row 16 on the next: "attack missed!" read
	-- "            d!" for one frame, 11 frames after its ▼ went (autoplay_text_probe.lua, 2026-09-17). So a box whose rows
	-- changed since the frame the watcher last saw is still changing, whatever the ▼ did before.
	local changing = track.seenAt == f - 1 and boxBytes(t) ~= track.lines
	if cell(t, ARROW_COL, BOX_BOTTOM) == ARROW
		or (not changing and track.arrowAt >= track.changedAt and f - track.arrowAt >= 0 and f - track.arrowAt <= BLINK_GAP)
		or (not changing and #lines > 0 and waitingInBattle()) then
		state = "waiting_for_button"
	elseif (u8(W_TEXTBOX_FLAGS) & TEXTBOX_PRINTING) ~= 0 or #lines == 0 or changing then
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

-- The PACK's item list, whole, when the menu on screen is it, and the pockets' contents (defined with the pockets, below).
local itemPocketMenu, readBag, readParty, partyMenu, readBadges

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
	-- The count back to 5 runs under a menu too (the PACK's, in a battle, with its item's description in the box): with a
	-- menu on screen the box waits only if its ▼ says so.
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

-- Which battle menu waits, from the menu block (autoplay_text_probe.lua, a wild PIDGEY): the action grid's first row is
-- 14 and column 9, 2 columns; the move list's first row 13, column 5, 1 column.
local function battleAskingFor(m)
	if not m then return nil end
	local b = memory.read_bytes_as_array(W_2DMENU, 4, "WRAM")
	if b[1] == 14 and b[2] == 9 and b[4] == 2 then return "action" end
	if b[1] == 13 and b[2] == 5 and b[4] == 1 then return "move" end
	return nil
end

-- THE BATTLERS AND THEIR MOVES (2026-09-17, vanilla V1.0, a wild PIDGEY L3 against CYNDAQUIL L5 on Route 29;
-- MEASURED.md, "The battlers, their moves, and what a move's power and accuracy do").
--   * autoplay_battle_probe.lua, read against the battle screen: the player's battler at C62C and the opponent's at D206,
--     0x20 bytes each -- +0x00 the species (155, 16; the name table's entries spelled CYNDAQUIL and PIDGEY, as drawn),
--     +0x02-+0x05 the moves (33 and 43, the move menu's TACKLE and LEER; PIDGEY's 33, "Enemy PIDGEY used TACKLE!"),
--     +0x08-+0x0B their PP (35 and 30, drawn 35/35 and 30/30; 34 after a TACKLE, drawn 34/35), +0x0D the level (5 and
--     3, drawn :L5 and :L3), +0x10 and +0x12 the HP and max HP, high byte first (19 and 19 drawn 19/19, then 16 drawn
--     16/19; PIDGEY's 15 then 10, its bar 48 pixels then 32). The nicknames at C621 and C616, 0x50-ended.
--   * The move table at 10:5AFB, 7 bytes an entry from id 1, whose entry the game copied whole into the player's move
--     struct for the move under the cursor: +0x03 the type (0 for both, drawn TYPE/ NORMAL through the pointer at
--     14:497B + 2 * type), +0x05 the PP the menu drew as the maximum (35, 30). Move names: the id'th 0x50-ended string
--     from 72:5F29. Species names: 10 bytes at 14:7384 + (id - 1) * 10.
--   * autoplay_move_write_probe.lua, one TACKLE replayed frame for frame from one snapshot with one byte of the move
--     struct changed: +0x02 at 35 did 5 damage, at 0 none, at 70 8, at 140 took all 15 HP -- the POWER; +0x04 at 0 gave
--     "CYNDAQUIL's attack missed!", at 242 (the table's) and 255 it hit -- the ACCURACY, on a scale not measured, so it
--     goes out as `accuracy_raw` and scores only by comparison.
-- A PP byte of 0x40 or more (raised PP) is not measured and goes out as pp_raw.
local W_BATTLE_MON, W_ENEMY_MON, BATTLER_SIZE = flat(0xC62C), flat(0xD206), 0x20
local W_BATTLE_MON_NICK, W_ENEMY_MON_NICK, NICK_LEN = flat(0xC621), flat(0xC616), 11
local MOVES_BANK, MOVES_PTR, MOVE_SIZE = 0x10, 0x5AFB, 7
local MOVE_NAMES_BANK, MOVE_NAMES_PTR = 0x72, 0x5F29
local NAMES_BANK, SPECIES_NAMES_PTR, SPECIES_NAME_LEN, TYPE_NAMES_PTR = 0x14, 0x7384, 10, 0x497B
local STRING_END = 0x50
-- Which battle: wBattleMode 1 for the wild PIDGEY, 2 for Bug Catcher Don. In Don's battle wCurOTMon (C663) read 255
-- until his first CATERPIE was sent out -- the frame its nickname was written; the opponent's block held the PIDGEY
-- from the battle before until then -- 0 for that one and 1 for his second, with wOTPartyCount (D280) 2; in the wild
-- battle it read 0 throughout (autoplay_battle_probe.lua, 2026-09-17).
local BATTLE_KINDS, BATTLE_MODE_TRAINER = { [1] = "wild", [2] = "trainer" }, 2
local W_CUR_OT_MON, OT_MON_NONE_YET, W_OT_PARTY_COUNT = flat(0xC663), 255, flat(0xD280)

-- In a string read from ROM, 0x54 printed as "POKé": the item named 54 7F 81 80 8B 8B printed "A found POKé BALL!"
-- (autoplay_bag_probe.lua, 2026-09-17, Route 31).
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
		level = b[14], hp = (b[17] << 8) | b[18], max_hp = (b[19] << 8) | b[20], moves = {} }
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

-- The player's usable move (measured PP above 0) with the most power times accuracy byte, as its move-menu index.
local function strongestMoveSlot()
	local b = memory.read_bytes_as_array(W_BATTLE_MON, BATTLER_SIZE, "WRAM")
	local best, bestScore
	for k = 0, 3 do
		local id, pp = b[3 + k], b[9 + k]
		if id ~= 0 and pp > 0 and pp < 0x40 then
			local m = moveData(id)
			local score = m.power * m.accuracy_raw
			if best == nil or score > bestScore then best, bestScore = k, score end
		end
	end
	return best, best and moveName(b[3 + best])
end

-- AFTER A BATTLE (autoplay_battle_probe.lua, 2026-09-17, the same PIDGEY battle; MEASURED.md, "The battlers..."):
--   * wBattleResult (D0EE) read 0 after the PIDGEY fainted and 2 after "Got away safely!", both back in the overworld.
--   * wMoney (D84E), 3 bytes high first, read 3000 as the trainer card drew MONEY ₽3000.
--   * The party (wPartyCount DCD7, the first Pokémon's 0x30 bytes from DCDF, its nickname at DE41): +0x00 the species,
--     +0x1F the level, +0x22 and +0x24 the HP and max HP, high byte first -- the POKéMON screen drew CYNDAQUIL :L5
--     10/19 as they read 155, 5, 10 and 19; the HP followed the battle's. A BELLSPROUT caught on Route 31 sat 0x30 bytes
--     on, its nickname 11 bytes on, reading 69, 5, 20 and 20 as the screen drew BELLSPROUT :L5 20/20 under CYNDAQUIL
--     (the species list at DCD8 read 9B 45 FF). Slots past the second are read the same way, not yet seen.
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
		"cheat:warp", "cheat:give_item", "cheat:set_flag", "cheat:heal", "cheat:set_badge" },
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

-- CHEATS: each takes its args and returns a plan -- { untilFn = function(observation) -> done, limit = frames,
-- report = function() } -- or nil and a reason. A cheat changes the world by other means than play; the core marks
-- the segment reached.
game.cheats = {}

-- warp {map = "G.N", x, y}: the writes `probes/goto_map.lua` makes, the game's own warp as that probe's header records
-- (2026-08-21): the map group and number and the tile written directly, wDefaultSpawnpoint 0xFF, hMapEntryMethod
-- (FF9F) 0xF1 -- without it the game reloaded the map it was on -- and wMapStatus 1. Refused outside the overworld or
-- while a script has the controls: any wScriptRunning but 0. Written while Bug Catcher Don walked over and spoke
-- (wScriptRunning 1), the load did not run -- wMapStatus read 1 for 900 frames with his box up, and A went on through his
-- words into his battle with it still 1 (2026-09-17). Done once the game has left the overworld and runs the target map
-- again; `report` reads the map and tile back.
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

-- BADGES (2026-09-17, vanilla V1.0, Route 30; MEASURED.md, "Badges on the trainer card"): the trainer card's second page
-- numbers eight leaders 1-4 on the top row and 5-8 below, and drew no badge with wJohtoBadges (D857 in our build's .sym)
-- at 0. With bit 0 set a badge was drawn beside leader 1; with the byte at 137 (bits 0, 3 and 7), beside leaders 1, 4 and
-- 8. So bit (N - 1) is badge N. wKantoBadges (D858) is not measured.
local W_JOHTO_BADGES = flat(0xD857)
readBadges = function()
	local b, list = u8(W_JOHTO_BADGES), {}
	for n = 1, 8 do
		if (b >> (n - 1)) & 1 == 1 then list[#list + 1] = n end
	end
	return list
end

-- set_badge {badge = 1-8, value = true}: bit (badge - 1) of wJohtoBadges. Refused outside the overworld; `report` reads the
-- byte back.
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

-- set_flag {flag, value = true}: one event flag, bit (flag & 7) of the byte (flag >> 3) past wEventFlags -- the layout
-- two defeat flags read (Don's 1336, byte 167 bit 0, and Mikey's 1450, each 0 before his battle and 1 after;
-- MEASURED.md, "A trainer battle" and "A trainer talked to"). wEventFlags is 0x100 bytes in our build's .sym (DA72, and
-- wCurBox at DB72), so ids 0-2047. Only defeat flags are measured; refused outside the overworld. `report` reads it back.
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

-- THE ITEM POCKET (autoplay_bag_probe.lua, 2026-09-17, vanilla V1.0, Route 30; MEASURED.md, "The PACK"). wNumItems (D892)
-- then an id and a quantity per entry and FF: `01 12 01 FF` while the PACK showed POTION ×1; picking up Route 30's item
-- ball printed "A put the ANTIDOTE in the ITEM POCKET." and it read `02 12 01 09 01 FF`. Item names: the id'th 0x50-ended
-- string from 72:4000 (18 POTION, 9 ANTIDOTE, as drawn). The 7-byte entry at 01:67C1 + (id - 1) * 7 read 01 at +5 for both,
-- the pocket the game filed them in. wItems holds 20 entries: wNumKeyItems (D8BC) is 41 bytes on in our build's .sym.
local W_NUM_ITEMS, ITEM_POCKET_SLOTS, ITEM_ATTRIBUTES, ATTR_POCKET_ITEM = flat(0xD892), 20, 0x67C1, 0x01
-- THE BALL POCKET, the same way (Route 31, the same day): its item ball printed "A put the POKé BALL in the BALL POCKET.",
-- wNumBalls (D8D7) read `01 05 01 FF`, and POKé BALL's attribute entry read 03 at +5. It holds 12 entries: wNumPCItems
-- (D8F1) is 26 bytes on in our build's .sym. The PACK's pockets by that byte: the address, the entries, wCurPocket.
local POCKETS = {
	[0x01] = { name = "items", addr = W_NUM_ITEMS, slots = ITEM_POCKET_SLOTS, cur = 0, ptr = 0xD892 },
	[0x03] = { name = "balls", addr = flat(0xD8D7), slots = 12, cur = 1, ptr = 0xD8D7 },
}
-- THE PACK'S ITEM LIST (autoplay_bag_probe.lua and autoplay_text_probe.lua, 2026-09-17, the item pocket holding 9 entries,
-- Down pressed 9 times from the top): the scrolling menu's header copy read height 5 at CF92, 02 at CF94 and the pocket's
-- address D892 at CF96-CF97 (D8D7 on the ball pocket, D8BC and 01 on the key pocket); the screen showed 5 entries then
-- CANCEL after the last. wMenuCursorY counted 1-5 down the rows shown and stayed 5 while the list moved; wMenuScrollPosition
-- (D0E4) read 0 until then and 1-5 as it moved; wScrollingMenuListSize (D144) read 9. So the entry under the ▶ is
-- D0E4 + wMenuCursorY - 1, CANCEL at 9. wCurPocket (CF65) read 0 on this pocket and 1, 2, 3 for each Right.
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
	if h[1] ~= 5 or h[3] ~= 2 then return nil end
	local pocket
	for _, p in pairs(POCKETS) do
		if h[5] == p.ptr & 0xFF and h[6] == p.ptr >> 8 and u8(W_CUR_POCKET) == p.cur then pocket = p end
	end
	if not pocket then return nil end
	local count, names, y = u8(pocket.addr), itemNames(), u8(W_MENU_CURSOR_Y)
	if count > pocket.slots or u8(W_SCROLL_LIST_SIZE) ~= count or y < 1 or y > 5 then return nil end
	local items, quantities = {}, {}
	for k = 0, count - 1 do
		local id = u8(pocket.addr + 1 + k * 2)
		items[#items + 1], quantities[#quantities + 1] = names[id] or string.format("{%02X}", id), u8(pocket.addr + 2 + k * 2)
	end
	items[#items + 1] = "CANCEL"
	return { items = items, cursor = u8(W_MENU_SCROLL) + y - 1, list = true, pocket = pocket.name, quantities = quantities }
end

-- After a Down the list's rows were redrawn over 3 frames and the ▶ reached its new row 5 frames after the press, with
-- wMenuCursorY already moved (autoplay_text_probe.lua, 2026-09-17): no menu reads on screen for those frames. The list
-- read whole within REDRAW_GRACE frames before still counts while the header points at it.
local REDRAW_GRACE, listSeenAt = 10, -1000
itemPocketMenu = function(m)
	local whole = itemListFromMemory()
	if not whole then return nil end
	local f = emu.framecount()
	if m then
		-- The rows on screen must be the entries from the scroll position down (a long name is cut at the list's edge).
		local scroll = u8(W_MENU_SCROLL)
		for i, shown in ipairs(m.items) do
			local want = whole.items[scroll + i]
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
				local id = u8(pocket.addr + 1 + k * 2)
				list[#list + 1] = { item = names[id] or string.format("{%02X}", id), id = id, quantity = u8(pocket.addr + 2 + k * 2) }
			end
			bag = bag or {}
			bag[pocket.name] = list
		end
	end
	return bag
end

-- THE PARTY OUT OF A BATTLE (autoplay_battle_probe.lua's party lines and the POKéMON screen's summary pages, 2026-09-17,
-- vanilla V1.0, `session_end_route31`; MEASURED.md, "The party's moves, PP, item and status, the POKéMON menu, and a heal").
-- CYNDAQUIL's slot read +0x01 AD (ITEM BERRY drawn), +0x02/+0x03 21 2B (TACKLE, LEER), +0x08-+0x0A 00 00 9E (EXP POINTS
-- 158), +0x17/+0x18 1F 1E (PP 31/35 and 30/30), +0x20 00 (STATUS/ OK); BELLSPROUT's +0x01 00 (no ITEM drawn), +0x02 16
-- (VINE WHIP) and +0x17 0A (10/10). A PP byte of 0x40 or more (raised PP) is not measured and goes out as pp_raw.
local PARTY_ITEM, PARTY_MOVES, PARTY_EXP, PARTY_PP, PARTY_LEVEL, PARTY_STATUS, PARTY_HP, PARTY_MAX_HP =
	0x01, 0x02, 0x08, 0x17, 0x1F, 0x20, 0x22, 0x24
local PP_RAISED = 0x40

readParty = function()
	local count = u8(W_PARTY_COUNT)
	if count < 1 or count > PARTY_MAX then return nil end
	local names, out = itemNames(), {}
	for k = 0, count - 1 do
		local p = memory.read_bytes_as_array(W_PARTY_MON1 + k * PARTY_MON_SIZE, PARTY_MON_SIZE, "WRAM")
		local nick = memory.read_bytes_as_array(W_PARTY_NICK1 + k * NICK_LEN, NICK_LEN, "WRAM")
		local mon = { slot = k + 1, species = speciesName(p[1]), species_id = p[1], nickname = spell(nick, 1, #nick),
			level = p[PARTY_LEVEL + 1], hp = (p[PARTY_HP + 1] << 8) | p[PARTY_HP + 2],
			max_hp = (p[PARTY_MAX_HP + 1] << 8) | p[PARTY_MAX_HP + 2], status_raw = p[PARTY_STATUS + 1],
			exp = (p[PARTY_EXP + 1] << 16) | (p[PARTY_EXP + 2] << 8) | p[PARTY_EXP + 3], moves = {} }
		local item = p[PARTY_ITEM + 1]
		if item ~= 0 then mon.held_item = names[item] or string.format("{%02X}", item) end
		for m = 0, 3 do
			local id, pp = p[PARTY_MOVES + 1 + m], p[PARTY_PP + 1 + m]
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

-- THE POKéMON MENU (autoplay_text_probe.lua, 2026-09-17, START then POKéMON with CYNDAQUIL and BELLSPROUT): each Pokémon's
-- name on rows 1 and 3 from column 3 and its HP "10/ 19" at columns 14-19, its level and HP bar on the row under it,
-- CANCEL on row 5; the menu block read first row 1, column 0, 3 rows by 1 column, 2 rows apart, and the frame's right
-- column 19, so the grid reader cut the last digit ("10/ 1"). The same list opened in a battle after the switch question's
-- YES ("Which PKMN?"). A menu whose block has that shape, one row per Pokémon and CANCEL, and whose rows show the party's
-- names reads as `party: true` with the names; `select` then takes a name, and A on one opened STATS / SWITCH / MOVE /
-- ITEM / CANCEL (read as a menu, as drawn).
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

-- heal: every Pokémon in the party to its max HP (+0x22 from +0x24), each move's PP to the maximum the move table gives
-- (the PP the summary drew as the maximum, 35 for TACKLE), and the status byte to 0 (drawn STATUS/ OK). Refused outside
-- the overworld and on a raised PP byte, whose maximum is not measured. `report` reads the party back.
function game.cheats.heal()
	if not isVanilla then return nil, "heal is measured on the vanilla V1.0 ROM only" end
	if not inOverworld() or u8(W_BATTLEMODE) ~= 0 then return nil, "heal refused: not in the overworld" end
	local count = u8(W_PARTY_COUNT)
	if count < 1 or count > PARTY_MAX then return nil, string.format("heal refused: the party count reads %d", count) end
	for k = 0, count - 1 do
		for m = 0, 3 do
			local at = W_PARTY_MON1 + k * PARTY_MON_SIZE
			if u8(at + PARTY_MOVES + m) ~= 0 and u8(at + PARTY_PP + m) >= PP_RAISED then
				return nil, string.format("heal refused: slot %d move %d has raised PP, not measured", k + 1, m + 1)
			end
		end
	end
	for k = 0, count - 1 do
		local at = W_PARTY_MON1 + k * PARTY_MON_SIZE
		memory.write_u8(at + PARTY_HP, u8(at + PARTY_MAX_HP), "WRAM")
		memory.write_u8(at + PARTY_HP + 1, u8(at + PARTY_MAX_HP + 1), "WRAM")
		memory.write_u8(at + PARTY_STATUS, 0, "WRAM")
		for m = 0, 3 do
			local id = u8(at + PARTY_MOVES + m)
			if id ~= 0 then memory.write_u8(at + PARTY_PP + m, moveData(id).base_pp, "WRAM") end
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

-- give_item {item, quantity = 1}: `item` a name as the PACK draws it (case and é ignored) or an id. Only items whose
-- attribute pocket byte reads 01 (the item pocket) or 03 (the ball pocket), added to that item's entry or as a new one
-- before the FF. Refused past 99 in one entry, past the pocket's entries, and outside the overworld. `report` reads the
-- entry back.
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
	local pocket = POCKETS[itemPocketOf(id)]
	if not pocket then
		return nil, string.format("give_item: %s files under pocket byte %d; only the item (01) and ball (03) pockets are measured",
			names[id], itemPocketOf(id))
	end
	local at, count = pocket.addr, u8(pocket.addr)
	if count > pocket.slots then return nil, string.format("give_item refused: the %s pocket's count reads %d", pocket.name, count) end
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
		-- A trainer seeing the player: wScriptRunning read 1 (not 255) two frames after the step three tiles below Bug
		-- Catcher Don ended, on the frame hLastTalked read his map object (4) and wSeenTrainerDistance (D03F) 3; he then
		-- walked over and spoke (autoplay_trainer_probe.lua, 2026-09-17). Held input did nothing from there on.
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

-- GOTO: the route planner and the ride are shared (`../route.lua`); what they read here is Crystal's, all of it `walk`'s
-- and `local_map`'s measurements above:
--   * position is the step's target tile (the player object's +0x10/+0x11), which moves on the frame a step BEGINS;
--   * a tile is open when its collision byte is one a step was measured onto -- 0x00, and 0x18, tall grass, where the
--     wild battles began -- and no character stands on it. Every other byte is planned as closed: 0x07, 0x15 and 0x29
--     refused a step, the ledges (0xA0, 0xA1, 0xA3) hop one way, and the rest are not measured, named in the refusal;
--   * a warp is closed unless it is the target: a door (0x71) warped on the step onto it, and a house's mat (0x70) only
--     on a press down while on it (below);
--   * a tile an unbeaten trainer may look at: its range the way its movement type was seen standing (6 down: Bug Catcher
--     Don and Youngster Mikey on every visit; 7 up: a character in house 24.9; 8 left: Route 31's trainer at (21,13);
--     2026-09-17), every way for any other type, whose turning is not measured. A trainer not loaded yet (Crystal loads a
--     character as the player comes near) is read from its map-object record: Don's, with only the player and one other
--     character loaded, read `FF 25 0B 05 06 00 FF FF B2 03 ...` -- FF where a loaded one holds its object slot (02
--     once he loaded), then his graphic, his tile plus 4 and movement type 6 (autoplay_map_probe.lua,
--     logs/autoplay_map_7871_20260917_032920.log);
--   * a warp under way (`arriving`): wMapStatus 1, or a new map until the player has stood WARP_SETTLE frames -- `walk`'s
--     door rule, since the game walks the player off an outside door after the load.
-- ENTERING A MAT (2026-09-17, New Bark's house 24.9, whose two warps at (2,7) and (3,7) read collision 0x70 and the town's
-- four doors 0x71): a walk right from one mat to the other and a walk down onto a mat from the room each answered `done` on
-- the mat; a walk down from rest on it answered `map_changed` with no step (63 frames), and a held walk down 2 from the room
-- stepped onto the mat and on into the town (88 frames). So a mat is gone to, then down is held.
local WALK_ONTO = { [0x00] = "open", [0x18] = "grass" }
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
	-- Every trainer on the map, loaded or not, from its map-object record: an unloaded one's tile and movement type are its
	-- record's, and its tile is closed as a loaded one's would be.
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
	-- `walk`'s early stops, in its order: a message or a menu on screen, a script taking the controls, a trainer's sight.
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

-- goto {x, y, cross_grass}: to a tile on this map by a planned route (`../route.lua`), on foot.
game.programs["goto"] = function(p)
	if not isVanilla then return nil, "goto is measured on the vanilla V1.0 ROM only" end
	if u8(W_PLAYERSTATE) ~= PLAYERSTATE_ON_FOOT then
		return nil, string.format("goto is measured on foot only; wPlayerState reads %d", u8(W_PLAYERSTATE))
	end
	return lib.route.go(routeHooks, p)
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
	local m = readMenu(readTilemap(), low)
	return itemPocketMenu(m) or partyMenu(m, readTilemap(), low) or m
end

-- TEXT AND BATTLES AS ONE CALL: the shared machine (`../text.lua`) through Crystal's reads.
--   * Progress is any change in the tile buffer (every letter printed, every HP bar step, a menu's cursor) or the
--     state bytes, and the player's tile (a scene walks the player: the west exit's, 2026-09-17).
--   * The battle's action menu is the grid whose first row is 14 and column 9, its move menu the list at row 13,
--     column 5 (autoplay_text_probe.lua, a wild PIDGEY); RUN is the grid's 3 and FIGHT its 0.
--   * A script has the controls while wScriptRunning reads anything but 0 (MEASURED.md, "A script taking over" and
--     "A trainer battle").
--   * hJoyDown is the game's own copy of the buttons: the START menu looked every few frames and missed a 2-frame
--     release, so presses wait for it to read 0, and a tap holds A until its bit 0 is set (hJoyDown read 1 for
--     each A a message box took, 2026-09-17).
--   * The strongest move is the battlers' reading above (power times the accuracy byte, measured PP above 0).
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
	-- Any value but 0: 255 through a sign, a scene or a wild encounter, and 1 from the step into Don's sight through his
	-- walk, his words, the stretch with no text before the battle, the battle and the map's reload after it (2026-09-17;
	-- `battle` had answered no_battle in that quiet stretch while this read only 255).
	scriptRunning = function() return u8(W_SCRIPT_RUNNING) ~= 0 end,
	inOverworld = inOverworld,
	readMenu = function()
		local _, _, m = textAndMenuNow()
		return m
	end,
	actionIndex = { fight = 0, run = 3 },
	inputReleased = function() return game.inputReleased() end,
	tapSeen = function() return (memory.read_u8(0xFFA8, "System Bus") & 0x01) ~= 0 end,
	-- The level-up stats box ("CYNDAQUIL grew to level 6!", autoplay_text_probe.lua, 2026-09-17): a frame from (9,0) to
	-- (19,11) -- 79 and 7B its top corners, 7D and 7E its bottom ones -- with ATTACK at row 1 from column 11, drawn 114
	-- frames after the message's last letter and waiting (waitingInBattle) until A closed it.
	levelUpPage = function()
		local t = readTilemap()
		if cell(t, 9, 0) ~= 0x79 or cell(t, 19, 0) ~= 0x7B or cell(t, 9, 11) ~= 0x7D or cell(t, 19, 11) ~= 0x7E then return nil end
		for i, b in ipairs({ 0x80, 0x93, 0x93, 0x80, 0x82, 0x8A }) do
			if cell(t, 10 + i, 1) ~= b then return nil end
		end
		if not waitingInBattle() then return nil end
		return "stats", "waiting"
	end,
	-- Any other menu read in a battle -- not the action grid, the move list or the PACK's list -- is a question: `battle`
	-- stops on it rather than nudge A. THE SWITCH QUESTION (autoplay_text_probe.lua, 2026-09-17, Bug Catcher Don's battle
	-- with CYNDAQUIL and BELLSPROUT in the party; MEASURED.md, "A trainer's next Pokémon, and the switch question"): after
	-- "is about to use CATERPIE." the box read "Will A" on row 14 and "change POKéMON?" on row 16, and a YES/NO framed at
	-- rows 7-11, columns 1-6 read through the menu block (first row 8, column 2, 2 rows); a nudge's A there chose YES and
	-- opened the party menu. `no` is NO's index. THE NICKNAME QUESTION (the same probe and day, from the snapshot at "Gotcha!
	-- BELLSPROUT was caught!"): the box read "Give a nickname to" / "BELLSPROUT?" and its YES/NO sat at rows 7-11, columns
	-- 14-19 (first row 8, column 15). It is a choice for the caller, so it carries no `no`.
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
			end
		end
		return q
	end,
	strongestMove = function()
		local slot, name = strongestMoveSlot()
		if slot == nil then return nil, "no move has measured PP left" end
		return slot, name
	end,
	endedReport = battleEndedReport,
}

-- battle {policy = "strongest" | "run"}: FIGHT and the strongest usable move each turn, or RUN; then through the text
-- to the overworld.
game.programs.battle = function(p)
	if not isVanilla then return nil, "battle is measured on the vanilla V1.0 ROM only" end
	return lib.text.battle(textHooks, p)
end

-- advance_text: presses through the message on screen, box by box, and stops when it closes and stays closed,
-- when a menu opens (answer it with select), or when a battle begins (hand it to battle).
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
