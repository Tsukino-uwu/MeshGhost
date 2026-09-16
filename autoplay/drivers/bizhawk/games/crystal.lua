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

local function mapName()
	return string.format("%d.%d", u8(W_MAPGROUP), u8(W_MAPNUMBER))
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
		[0x60] = "■", [0x61] = "▲", [0x63] = "D", [0x64] = "E", [0x65] = "F", [0x66] = "G", [0x67] = "H", [0x68] = "I",
		[0x69] = "V", [0x6A] = "S", [0x6B] = "L", [0x6C] = "M", [0x6D] = ":", [0x6E] = "ぃ", [0x6F] = "ぅ",
		[0x70] = "PO", [0x71] = "Ké", [0x72] = "“", [0x73] = "”", [0x74] = "·", [0x75] = "…", [0x76] = "ぁ",
		[0x77] = "ぇ", [0x78] = "ぉ", [0x7F] = " ",
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

local function decodeCells(t, r, c0, c1)
	local out = {}
	for c = c0, c1 do
		local b = cell(t, c, r)
		out[#out + 1] = CHARS[b] or string.format("{%02X}", b)
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

local function readDialogue(t)
	if not boxOpen(t) then return nil end
	local lines = {}
	for r = BOX_TOP + 1, BOX_BOTTOM - 1 do
		local s = decodeCells(t, r, 1, 18)
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

local function readMenu(t)
	if u8(W_WINDOW_STACK_SIZE) == 0 then return nil end
	local m = memory.read_bytes_as_array(W_2DMENU, 7, "WRAM")
	local top, col, rows, cols, spacing = m[1], m[2], m[3], m[4], m[7] >> 4
	local tile = u8(W_CURSOR_TILE) | (u8(W_CURSOR_TILE + 1) << 8)
	local at = tile - 0xC4A0
	if rows < 1 or cols ~= 1 or spacing < 1 or at < 0 or at >= COLS * ROWS or t[at + 1] ~= CURSOR then return nil end
	local right = u8(W_MENU_BORDER_RIGHT)
	if right <= col or right >= COLS or top + (rows - 1) * spacing >= ROWS then return nil end
	local items, used = {}, {}
	for k = 0, rows - 1 do
		items[#items + 1] = decodeCells(t, top + k * spacing, col + 1, right - 1)
		used[top + k * spacing] = true
	end
	return { items = items, cursor = u8(W_MENU_CURSOR_Y) - 1 }, used
end

-- Any other text on screen, row by row: runs of named tiles holding a letter or a digit, outside the message box
-- and the menu's rows when those are reported.
local function readScreenText(t, dialogue, menuRows)
	local out = {}
	for r = 0, ROWS - 1 do
		local skip = (dialogue and r >= BOX_TOP) or (menuRows and menuRows[r]) or false
		if not skip then
			local runs, c = {}, 0
			while c < COLS do
				if CHARS[cell(t, c, r)] and cell(t, c, r) ~= 0x7F then
					local c1, letters = c, false
					while c1 + 1 < COLS and CHARS[cell(t, c1 + 1, r)] and not (cell(t, c1 + 1, r) == 0x7F and cell(t, math.min(c1 + 2, COLS - 1), r) == 0x7F) do
						c1 = c1 + 1
					end
					for k = c, c1 do
						if isLetter(cell(t, k, r)) then letters = true end
					end
					if letters then runs[#runs + 1] = decodeCells(t, r, c, c1) end
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
	menuButtons = { prev = "Up", next = "Down", confirm = "A" },
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
	local warps = overworld and readWarps() or nil
	local d, m, s, menuRows
	if isVanilla then
		local t = readTilemap()
		d = readDialogue(t)
		m, menuRows = readMenu(t)
		s = readScreenText(t, d, menuRows)
		if #s == 0 then s = nil end
	end
	return {
		frame = emu.framecount(),
		dialogue = d,
		menu = m,
		screen_text = s,
		mode = overworld and "overworld" or "not_overworld",
		location = { map = mapName(), x = u8(W_XCOORD), y = u8(W_YCOORD), facing = overworld and FACING[ps[9]] or nil },
		warps = (warps and #warps > 0) and warps or nil,
		extras = {
			map_status_raw = u8(W_MAPSTATUS),
			sprite_updates_raw = u8(W_SPRITEUPDATES),
			battle_mode_raw = u8(W_BATTLEMODE),
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
		if readMenu(t) then return finish("menu_open") end

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
				for _, w in ipairs(readWarps()) do
					if w.x == blocked.x and w.y == blocked.y then blocked.warp_to = w.to end
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
	return (readMenu(readTilemap()))
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
		mode = (isVanilla and inOverworld()) and "overworld" or "not_overworld",
		battle_mode_raw = u8(W_BATTLEMODE),
	}
	if isVanilla then
		local t = readTilemap()
		trackText(t)
		out.dialogue = boxOpen(t) and "open" or "closed"
		out.menu = readMenu(t) and "open" or "closed"
	end
	return out
end

return game
