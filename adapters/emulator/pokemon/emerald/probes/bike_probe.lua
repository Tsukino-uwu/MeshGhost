-- MeshGhost — Pokémon Emerald: a bike ride frame by frame (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-16
--
-- WHY THIS EXISTS. autoplay's `walk` holds a direction across tiles and counts each tile as its step
-- begins (`emerald/MEASURED.md`, "A direction held across tiles"). On the Mach Bike a released ride kept
-- going -- one tile per speed tier (step_probe.lua, the same day) -- so a ride that must stop on a tile
-- has to let go early, by an amount only the bike's current speed says. `documentation.md` names the
-- avatar block's +0x0B as the Mach Bike's stable speed field; this logs the whole first 16 bytes of that
-- block beside each step, on either bike, so which byte tracks the speed is read, not assumed.
--
-- ADDRESSES: the same hash-matched build as step_probe.lua (SHA-1 compared 2026-09-16). Vanilla only.
-- WHAT IT LOGS (bike_probe_<target>_<time>.log beside this file; gitignored), on any change of: the
-- player object's coordinates, previous coordinates, byte 0 and +0x1C, the avatar block's first 16
-- bytes, or the pad -- one line each. WHAT IT CANNOT SEE: anything outside those bytes, such as where the
-- bike's acceleration counter lives if not in them.

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
		logf:flush() -- on a timer, never per frame
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
