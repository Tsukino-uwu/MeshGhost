-- MeshGhost — Emerald: the naming screen, raw, on every change with the pad (dev tool, read-only, no hooks, vanilla).
-- sNamingScreen's +0x1800 (the name so far) and +0x1E10..+0x1E3F, the cursor's sprite, the template, the keyboard once.

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
-- sKeyboardChars, once: three blocks of 4 rows of 8.
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
