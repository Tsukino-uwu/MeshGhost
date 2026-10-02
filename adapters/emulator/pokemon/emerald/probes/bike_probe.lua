-- MeshGhost — Pokémon Emerald: a bike ride frame by frame (dev tool, read-only, vanilla only, never shipped).
-- One line on any change of the player object's coordinates, previous coordinates, byte 0 and +0x1C, the avatar
-- block's first 16 bytes, or the pad, so which byte tracks the bike's speed is read, not assumed.

local BUS = "System Bus"
local GPLAYERAVATAR, GOBJECTEVENTS, OBJ_SIZE = 0x02037590, 0x02037350, 0x24

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local target = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "default"):gsub("[^%w_%-]", "_")
local logf = io.open(string.format("%s/bike_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
local pending = {}
local function flush()
	if logf and #pending > 0 then
		logf:write(table.concat(pending, "\n"), "\n")
		logf:flush()
		pending = {}
	end
end

local function hex(b, from, to)
	local out = {}
	for i = from, to do out[#out + 1] = string.format("%02X", b[i]) end
	return table.concat(out)
end

local last, frames = nil, 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local slot = memory.read_u8(GPLAYERAVATAR + 5, BUS)
	local o = memory.read_bytes_as_array(GOBJECTEVENTS + slot * OBJ_SIZE, 0x20, BUS)
	local a = memory.read_bytes_as_array(GPLAYERAVATAR, 16, BUS)
	local pad, on = joypad.get(), {}
	for k, v in pairs(pad) do
		if v == true then on[#on + 1] = k end
	end
	table.sort(on)
	local line = string.format("x=%d y=%d prev=%d,%d top=%d act=%02X avatar=%s pad=%s",
		o[17] | (o[18] << 8), o[19] | (o[20] << 8), o[21] | (o[22] << 8), o[23] | (o[24] << 8),
		(o[1] & 0x80) ~= 0 and 1 or 0, o[29], hex(a, 1, 16), table.concat(on, "+"))
	if line ~= last then
		pending[#pending + 1] = string.format("f%d %s", emu.framecount(), line)
		last = line
	end
	if frames % 60 == 0 then flush() end
end
MESHGHOST_DEV_UNLOAD = function()
	flush()
	if logf then logf:close() end
	logf = nil
end
