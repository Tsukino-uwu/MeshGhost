-- Read-only, never shipped: a step frame by frame, for a walk that ends on the game's own state, never a frame
-- count. On every frame any of them changes it logs the player object's first 3 bytes and +0x10..+0x1F, the
-- avatar block's first 4 bytes and the pad, so a walked tile, a turn and a wall bump can be read afterwards.
-- Vanilla only; the log is step_probe_<target>_<time>.log beside this file, flushed on a timer.

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
local logf = io.open(string.format("%s/step_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
local pending = {}
local function flush()
	if logf and #pending > 0 then
		logf:write(table.concat(pending, "\n"), "\n")
		logf:flush() -- on a timer, never per line
		pending = {}
	end
end
local function hex(a, n)
	local b, out = memory.read_bytes_as_array(a, n, BUS), {}
	for i = 1, n do out[i] = string.format("%02X", b[i]) end
	return table.concat(out)
end

local last, frames = nil, 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local obj = GOBJECTEVENTS + memory.read_u8(GPLAYERAVATAR + 5, BUS) * OBJ_SIZE
	local pad = {}
	for name, down in pairs(joypad.get()) do
		if down == true then pad[#pad + 1] = name end
	end
	table.sort(pad)
	local line = string.format("obj+00=%s obj+10=%s avatar=%s pad=%s", hex(obj, 3), hex(obj + 0x10, 0x10),
		hex(GPLAYERAVATAR, 4), table.concat(pad, "+"))
	if line ~= last then
		last = line
		pending[#pending + 1] = string.format("f%d %s", emu.framecount(), line)
	end
	if frames % 60 == 0 then flush() end
end
MESHGHOST_DEV_UNLOAD = function()
	pending[#pending + 1] = "unloaded"
	flush()
	if logf then logf:close() end
	logf = nil
end
