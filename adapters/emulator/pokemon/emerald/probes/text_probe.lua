-- MeshGhost — Pokémon Emerald: what text the game prints, and into which window (dev tool, read-only, vanilla only,
-- never shipped). Execute hooks log each string's raw bytes as its printing starts and each window call; the text
-- printers, sMenu, the message box mode, the START menu, gWindows and BG0's drawn rows are logged on change, FPS
-- every 300 frames. TEXT_PROBE_NO_HOOKS = true before loading leaves the hooks out, to price them.

local BUS = "System Bus"
local HOOKS = {
	{ name = "ATP", at = 0x0800467c }, -- AddTextPrinter
	{ name = "FILL", at = 0x08003c48 }, -- FillWindowPixelBuffer
	{ name = "REMOVE", at = 0x08003574 }, -- RemoveWindow
	{ name = "PUT", at = 0x0800378c }, -- PutWindowTilemap
	{ name = "CLEARTM", at = 0x080038a4 }, -- ClearWindowTilemap
	{ name = "ADDWIN", at = 0x08003380 }, -- AddWindow
}
local STEXTPRINTERS, PRINTER_SIZE, WINDOWS_MAX = 0x020201b0, 0x24, 32
local SMENU = 0x0203cd90
local SFIELDMESSAGEBOXMODE = 0x020375bc
local SSTARTMENUCURSORPOS = 0x0203760e
local GWINDOWS = 0x02020004

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local target = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "default"):gsub("[^%w_%-]", "_")
local logf = io.open(string.format("%s/text_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")

local pending, lastLine, repeats = {}, nil, 0
local function emit(line)
	pending[#pending + 1] = line
end
local function log(line)
	if line == lastLine then
		repeats = repeats + 1
		return
	end
	if repeats > 0 then emit(string.format("  (previous line x%d more)", repeats)) end
	lastLine, repeats = line, 0
	emit(string.format("f%d %s", emu.framecount(), line))
end
local function flush()
	if not logf or #pending == 0 then return end
	logf:write(table.concat(pending, "\n"), "\n")
	logf:flush()
	pending = {}
end

local function hex(bytes, from, to)
	local out = {}
	for i = from or 1, to or #bytes do out[#out + 1] = string.format("%02X", bytes[i]) end
	return table.concat(out)
end
local function reg(name)
	local ok, v = pcall(emu.getregister, name)
	return ok and v or -1
end

local function bytesUntilFF(at)
	if at < 0x02000000 or at >= 0x0A000000 then return nil, "not RAM/ROM" end
	local out = {}
	for chunk = 0, 15 do
		local b = memory.read_bytes_as_array(at + chunk * 64, 64, BUS)
		for i = 1, 64 do
			out[#out + 1] = b[i]
			if b[i] == 0xFF then return out end
		end
	end
	return out, "no FF in 1024"
end

local handlers = {}
function handlers.ATP()
	local r0, r1 = reg("R0"), reg("R1")
	local t = memory.read_bytes_as_array(r0, 16, BUS)
	local ptr = t[1] | (t[2] << 8) | (t[3] << 16) | (t[4] << 24)
	local s, note = bytesUntilFF(ptr)
	log(string.format("ATP w=%d font=%d xy=%d,%d r1=%d tmpl=%s ptr=%08X len=%d%s bytes=%s", t[5], t[6], t[7], t[8],
		r1, hex(t), ptr, s and #s or 0, note and (" (" .. note .. ")") or "", s and hex(s) or ""))
end
function handlers.FILL() log(string.format("FILL w=%d v=%d", reg("R0"), reg("R1"))) end
function handlers.REMOVE() log(string.format("REMOVE w=%d", reg("R0"))) end
function handlers.PUT() log(string.format("PUT w=%d", reg("R0"))) end
function handlers.CLEARTM() log(string.format("CLEARTM w=%d", reg("R0"))) end
function handlers.ADDWIN()
	log("ADDWIN tmpl=" .. hex(memory.read_bytes_as_array(reg("R0"), 8, BUS)))
end

local hookNames = {}
if not TEXT_PROBE_NO_HOOKS then
	for _, h in ipairs(HOOKS) do
		local name = "meshghost_text_probe_" .. h.name
		pcall(event.unregisterbyname, name)
		local ok, err = pcall(event.onmemoryexecute, function()
			local hok, herr = pcall(handlers[h.name])
			if not hok then log("HOOK ERROR " .. h.name .. ": " .. tostring(herr)) end
		end, h.at, name)
		log(string.format("hook %s at %08X: %s", h.name, h.at, ok and "registered" or ("REFUSED " .. tostring(err))))
		if ok then hookNames[#hookNames + 1] = name end
	end
else
	log("hooks off (TEXT_PROBE_NO_HOOKS)")
end

local last = {}
local function onChange(key, value, line)
	if last[key] ~= value then
		last[key] = value
		log(line or (key .. " " .. value))
	end
end

local frames = 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1

	local p = memory.read_bytes_as_array(STEXTPRINTERS, PRINTER_SIZE * WINDOWS_MAX, BUS)
	for w = 0, WINDOWS_MAX - 1 do
		local o = w * PRINTER_SIZE
		local sig = string.format("%02X%02X", p[o + 0x1C], p[o + 0x1D])
		if last["prn" .. w] ~= sig then
			last["prn" .. w] = sig
			log(string.format("PRN w=%d +1B=%02X +1C=%02X +1D..1F=%s head=%s", w, p[o + 0x1C], p[o + 0x1D],
				hex(p, o + 0x1E, o + 0x20), hex(p, o + 1, o + 8)))
		end
	end

	local m = hex(memory.read_bytes_as_array(SMENU, 12, BUS))
	onChange("menu", m, "MENU " .. m)
	local mb = string.format("%02X", memory.read_u8(SFIELDMESSAGEBOXMODE, BUS))
	onChange("mbox", mb, "MBOX " .. mb)
	local st = hex(memory.read_bytes_as_array(SSTARTMENUCURSORPOS, 11, BUS))
	onChange("start", st, "START " .. st)

	if frames % 4 == 0 then
		local wb = memory.read_bytes_as_array(GWINDOWS, 0x180, BUS)
		local parts = {}
		for s = 0, 31 do
			local slot = hex(wb, s * 12 + 1, s * 12 + 12)
			if slot ~= "000000000000000000000000" then parts[#parts + 1] = s .. ":" .. slot end
		end
		local ws = table.concat(parts, " ")
		onChange("wins", ws, "WINS " .. ws)

		local cnt = memory.read_u16_le(0x04000008, BUS)
		local base = 0x06000000 + ((cnt >> 8) & 0x1F) * 0x800
		local tm = memory.read_bytes_as_array(base, 32 * 20 * 2, BUS)
		local rows = {}
		for r = 0, 19 do
			local first, lastc
			for c = 0, 29 do
				local i = (r * 32 + c) * 2
				if ((tm[i + 1] | (tm[i + 2] << 8)) & 0x3FF) ~= 0 then
					first = first or c
					lastc = c
				end
			end
			if first then rows[#rows + 1] = string.format("%d:%d-%d", r, first, lastc) end
		end
		local bg = table.concat(rows, " ")
		onChange("bg0", bg, "BG0 " .. (bg == "" and "empty" or bg))
	end

	if frames % 300 == 0 then log(string.format("FPS %.1f", client.get_approx_framerate())) end
	if frames % 60 == 0 or #pending > 200 then flush() end
end

MESHGHOST_DEV_UNLOAD = function()
	for _, name in ipairs(hookNames) do pcall(event.unregisterbyname, name) end
	log("unloaded")
	lastLine = nil
	flush()
	if logf then logf:close() end
	logf = nil
end
