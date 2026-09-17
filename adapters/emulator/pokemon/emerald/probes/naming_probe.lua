-- MeshGhost — Pokémon Emerald: the naming screen's state, raw (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-17
--
-- WHY THIS EXISTS. autoplay's `advance_text` stops `stuck` on the naming keyboard, which nothing reads: the new-game
-- run typed its name with raw presses, and a nudge once typed "AA" there (`agent_docs/phases/phase13.md`). What the
-- screen holds -- the name so far, which page shows, where the cursor is, how long a name may be -- is to be
-- measured, so a reader and a program can be built on it.
--
-- ADDRESSES: a pokeemerald build whose ROM hashed identical to the vanilla ROM (SHA-1, 2026-09-16) proves where the
-- pointer the build names sNamingScreen (0x02039F94) and the sprite array gSprites (0x02020630, 0x44 a sprite) live.
-- The offsets below are where its struct layout says to LOOK -- the text buffer at +0x1800, a tail from +0x1E10 with the
-- page and the cursor's sprite id, the template pointer at +0x1E28 -- and each is logged raw, to be read against the
-- screen: none of them is taken as meaning anything until a press moves it.
--
-- WHAT IT LOGS (naming_probe_<target>_<time>.log beside this file; gitignored), each on change, with the pad:
--   CB2    gMain.callback2
--   NS     the sNamingScreen pointer
--   TXT    +0x1800, 16 bytes raw
--   TAIL   +0x1E10..+0x1E3F raw
--   SPR n  sprite n's 0x44 bytes raw, for the id at +0x1E23 and for every sprite whose +0x2E..+0x31 changed since the
--          last frame (so a cursor on another sprite still shows)
--   TPL    the 12 bytes at the pointer in +0x1E28
-- WHAT IT CANNOT SEE: anything between two changes, a keyboard not opened through this struct, a patched ROM.
-- COST: about 0x1100 bytes read a frame (the sprite array), no hooks.

local BUS = "System Bus"
local GMAIN_CB2, SNAMINGSCREEN, GSPRITES, SPRITE_SIZE, SPRITES = 0x030022c4, 0x02039f94, 0x02020630, 0x44, 65

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local target = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "default"):gsub("[^%w_%-]", "_")
local logf = io.open(string.format("%s/naming_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
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

local function padString()
	local p, on = joypad.get(), {}
	for k, v in pairs(p) do
		if v == true then on[#on + 1] = k end
	end
	table.sort(on)
	return table.concat(on, "+")
end

local last, lastData, frames = {}, {}, 0
local function onChange(key, value, line)
	if last[key] ~= value then
		last[key] = value
		log(line .. " pad=" .. padString())
	end
end

log("naming_probe loaded")
-- Added the same day: the 0x60 bytes the build names sKeyboardChars (0x0858BE40), once, as 3 blocks of 4 rows of 8,
-- letters and digits decoded -- to be read against captures of the three pages.
do
	local b = memory.read_bytes_as_array(0x0858be40, 0x60, BUS)
	for k = 0, 2 do
		local rows = {}
		for r = 0, 3 do
			local out = {}
			for c = 0, 7 do
				local x = b[k * 32 + r * 8 + c + 1]
				if x >= 0xBB and x <= 0xD4 then out[#out + 1] = string.char(0x41 + x - 0xBB)
				elseif x >= 0xD5 and x <= 0xEE then out[#out + 1] = string.char(0x61 + x - 0xD5)
				elseif x >= 0xA1 and x <= 0xAA then out[#out + 1] = tostring(x - 0xA1)
				else out[#out + 1] = string.format("{%02X}", x) end
			end
			rows[#rows + 1] = table.concat(out, " ")
		end
		log(string.format("KB %d: %s", k, table.concat(rows, " | ")))
	end
end
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local cb2 = memory.read_u32_le(GMAIN_CB2, BUS)
	onChange("cb2", cb2, string.format("CB2 %08X", cb2))
	local ns = memory.read_u32_le(SNAMINGSCREEN, BUS)
	onChange("ns", ns, string.format("NS %08X", ns))
	local cursorId
	if ns >= 0x02000000 and ns < 0x02040000 - 0x1E40 then
		local txt = hex(memory.read_bytes_as_array(ns + 0x1800, 16, BUS), 1, 16)
		onChange("txt", txt, "TXT " .. txt)
		local tail = memory.read_bytes_as_array(ns + 0x1E10, 0x30, BUS)
		onChange("tail", hex(tail, 1, 0x30), "TAIL " .. hex(tail, 1, 0x30))
		cursorId = tail[0x14] -- +0x1E23
		local tpl = tail[0x19] | (tail[0x1A] << 8) | (tail[0x1B] << 16) | (tail[0x1C] << 24) -- +0x1E28
		if tpl >= 0x08000000 and tpl < 0x0A000000 then
			local t = hex(memory.read_bytes_as_array(tpl, 12, BUS), 1, 12)
			onChange("tpl", t, string.format("TPL %08X %s", tpl, t))
		end
	end
	local all = memory.read_bytes_as_array(GSPRITES, SPRITE_SIZE * SPRITES, BUS)
	for n = 0, SPRITES - 1 do
		local o = n * SPRITE_SIZE
		local data = hex(all, o + 0x2F, o + 0x32)
		if (n == cursorId or (lastData[n] and lastData[n] ~= data)) then
			onChange("spr" .. n, hex(all, o + 1, o + SPRITE_SIZE), string.format("SPR %d %s", n, hex(all, o + 1, o + SPRITE_SIZE)))
		end
		lastData[n] = data
	end
	if frames % 60 == 0 then flush() end
end
MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	flush()
	if logf then logf:close() end
	logf = nil
end
