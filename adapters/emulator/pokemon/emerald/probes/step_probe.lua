-- MeshGhost — Pokémon Emerald: what a step looks like frame by frame (DEV TOOL, READ-ONLY, never shipped)
-- -- 2026-09-16
--
-- WHY THIS EXISTS. autoplay's walk has to end on the game's own state -- "the step is done", "the step
-- was refused" -- never on a frame count (`_template/probes.md`, "A driven leg is MEASURED, not timed").
-- Which bytes say so is not measured. This logs, on every frame where any of them changes, the player
-- object's first 3 bytes and its +0x10..+0x1F, the avatar block's first 4 bytes, and the pad as the
-- script host reads it, so a walked tile, a turn and a walk into a wall can each be read afterwards.
--
-- ADDRESSES: the same hash-matched build as map_probe.lua (SHA-1 compared 2026-09-16). Vanilla only.
-- Log: step_probe_<target>_<time>.log beside this file (gitignored), flushed on a timer.

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
