-- MeshGhost — Pokémon Crystal: make the game draw every text byte, to name what each one draws
-- (DEV TOOL, WRITES THE SCREEN'S TILE BUFFER, never shipped) -- 2026-09-17
--
-- WRITES wTilemap only: the text rows inside a message box that is already open. Presses nothing. What it
-- writes is a picture, gone when the box closes (the game put the map's own tiles back on the frame the sign's
-- box closed, autoplay_text_probe.lua, 2026-09-17). Load it ONLY with a message box on screen and waiting
-- (the `sign_text` snapshot); take it off the target when it logs `done`.
--
-- WHY. autoplay's crystal.lua reads text off the tile buffer, so it needs what each byte DRAWS. Real text read
-- against captures gave a handful of letters; this draws the rest the same way the game draws any text --
-- through its own tile buffer, copied to the screen while the box waits (hBGMapMode 1) -- so every glyph can be
-- named from a capture instead of from a charmap (adapters/_template/probes.md, "Make the game draw what you
-- cannot name").
--
-- WHAT IT DOES. Pages of 72 bytes, 0x60 upward, into rows 13-16, columns 1-18 (the box's inside), one byte a
-- cell in order; 12 frames later a capture of that page goes to dev-scripts/shots/crystal/autoplay_charset_pN.png
-- and the log names the page's first byte. Cell (column, row) is pixels (8 * column, 8 * row) in the capture.
-- Log: crystal/logs/autoplay_charset_<timestamp>.log.

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local TILEMAP = flat(0xC4A0)
local FIRST, LAST, PER_PAGE = 0x60, 0xFF, 72

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local root = dir:match("^(.*)/adapters/") or "."
local logf = io.open((dir:match("^(.*)/probes$") or dir) .. "/logs/autoplay_charset_" .. os.date("%Y%m%d_%H%M%S") .. ".log", "w")
local function log(s)
	if logf then
		logf:write(string.format("[f%d] %s\n", emu.framecount(), s))
		logf:flush() -- a handful of lines in the whole run
	end
end

-- Refuse unless a message box's frame is where the sign's was: (0,12) 79, (19,12) 7B, (0,17) 7D, (19,17) 7E.
local function boxOpen()
	local function at(c, r) return memory.read_u8(TILEMAP + r * 20 + c, "WRAM") end
	return at(0, 12) == 0x79 and at(19, 12) == 0x7B and at(0, 17) == 0x7D and at(19, 17) == 0x7E
end

local page, timer, done = 0, 20, false
log("loaded; box open: " .. tostring(boxOpen()))

MESHGHOST_DEV_TICK = function()
	if done then return end
	timer = timer - 1
	if timer > 0 then return end
	local first = FIRST + page * PER_PAGE
	if timer == 0 then
		if not boxOpen() then
			log("no message box open: stopping")
			done = true
			return
		end
		for i = 0, PER_PAGE - 1 do
			local b = first + i
			local r, c = 13 + i // 18, 1 + i % 18
			memory.write_u8(TILEMAP + r * 20 + c, b <= LAST and b or 0x7F, "WRAM")
		end
		timer = -12
		log(string.format("page %d written from %02X", page, first))
	elseif timer == -12 - 12 then
		local path = string.format("%s/dev-scripts/shots/crystal/autoplay_charset_p%d.png", root, page)
		client.screenshot(path)
		log(string.format("page %d captured: %s (first byte %02X)", page, path, first))
		page = page + 1
		if FIRST + page * PER_PAGE > LAST then
			log("done")
			done = true
		else
			timer = 1
		end
	end
end

MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	if logf then logf:close() end
	logf = nil
end
