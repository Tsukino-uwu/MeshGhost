-- MeshGhost — Pokémon Emerald: what the engine builds for the player, every frame (dev tool, read-only, vanilla).
-- While the global MESHGHOST_BV_REC is truthy (any script the dev loader runs can set it) it logs per frame:
-- F the frame and gMain.callback2, P the player's object event, S<nn> each nonzero sprite slot, and V a checksum
-- of the 8 VRAM OBJ tiles the player's sprite points at. Run it with the adapter unloaded; heavy while recording.

local GPLAYERAVATAR, GOBJECTEVENTS, GSPRITES, GMAIN_CB2 = 0x02037590, 0x02037350, 0x02020630, 0x030022c4
local BUS = "System Bus"

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local path = dir .. "/borrowed_values_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
local f = io.open(path, "w")
if f then f:setvbuf("full", 1 << 20) end
local function out(s) if f then f:write(s, "\n") end end

local function hex(t, n)
	local p = {}
	for i = 1, n do p[i] = string.format("%02X", t[i] or 0) end
	return table.concat(p)
end

local recording, frames, lastFlush = false, 0, 0

local function dumpFrame()
	out(string.format("F %d cb2 %08X", emu.framecount(), memory.read_u32_le(GMAIN_CB2, BUS)))
	local objId = memory.read_u8(GPLAYERAVATAR + 5, BUS)
	if objId < 16 then
		out("P " .. hex(memory.read_bytes_as_array(GOBJECTEVENTS + objId * 0x24, 0x24, BUS), 0x24))
	end
	local all = memory.read_bytes_as_array(GSPRITES, 64 * 0x44, BUS)
	for s = 0, 63 do
		local base, nz = s * 0x44, false
		for k = 1, 0x44 do
			if all[base + k] ~= 0 then nz = true break end
		end
		if nz then
			local b = {}
			for k = 1, 0x44 do b[k] = all[base + k] end
			out(string.format("S%02d %s", s, hex(b, 0x44)))
		end
	end
	local spr = memory.read_u8(GPLAYERAVATAR + 4, BUS)
	if spr < 64 then
		local attr2 = all[spr * 0x44 + 5] + all[spr * 0x44 + 6] * 256
		local tile = attr2 & 0x3ff
		local ok, v = pcall(memory.read_bytes_as_array, 0x10000 + tile * 32, 256, "VRAM")
		if ok and v then
			local sum = 0
			for k = 1, #v do sum = (sum * 31 + v[k]) % 4294967296 end
			out(string.format("V tile %03X sum %08X", tile, sum))
		end
	end
end

out("borrowed_values_probe loaded frame " .. emu.framecount())
pcall(function() console.log("borrowed_values_probe: " .. path) end)

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local want = _G.MESHGHOST_BV_REC and true or false
	if want ~= recording then
		recording = want
		out(string.format("REC %s frame %d %s", want and "on" or "off", emu.framecount(),
			tostring(_G.MESHGHOST_BV_LABEL or "")))
	end
	if recording then dumpFrame() end
	if frames - lastFlush >= 60 and f then
		lastFlush = frames
		pcall(function() f:flush() end)
	end
end

MESHGHOST_DEV_UNLOAD = function()
	if f then
		out("unloaded frame " .. emu.framecount())
		pcall(function() f:close() end)
		f = nil
	end
end
