-- MeshGhost — Pokémon Emerald: every active task, raw (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-17
--
-- WHY THIS EXISTS. Screens that nothing reads keep their state in a task's data: the wall clock of the new game's room
-- (autoplay's `advance_text` stops `stuck` on it, `agent_docs/phases/phase13.md`). `list_menu_probe.lua` logs data only
-- for the list menu's task. This logs every active task whole, so the one a screen runs can be found by pressing and
-- watching what moves.
--
-- ADDRESSES: a pokeemerald build whose ROM hashed identical to the vanilla ROM (SHA-1, 2026-09-16) proves where the
-- array the build names gTasks lives (0x03005E00, 16 tasks of 40 bytes, as `list_menu_probe.lua` measured: the routine
-- at +0, nonzero +4 while active, data from +8). What any data word means is to be measured.
--
-- WHAT IT LOGS (task_probe_<target>_<time>.log beside this file; gitignored), each on change, with the pad:
--   CB2    gMain.callback2
--   TASK n the routine's address and the task's 40 bytes raw, for every active task n
--   GONE n when task n stops being active
-- WHAT IT CANNOT SEE: state kept outside a task, anything between two changes, a patched ROM.
-- COST: 640 bytes read a frame, no hooks.

local BUS = "System Bus"
local GMAIN_CB2, GTASKS, TASK_SIZE, NUM_TASKS = 0x030022c4, 0x03005e00, 40, 16

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local target = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "default"):gsub("[^%w_%-]", "_")
local logf = io.open(string.format("%s/task_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
local pending = {}
local function log(s) pending[#pending + 1] = string.format("f%d %s", emu.framecount(), s) end
local function flush()
	if logf and #pending > 0 then
		logf:write(table.concat(pending, "\n"), "\n")
		logf:flush() -- on a timer, never per frame
		pending = {}
	end
end

local function padString()
	local p, on = joypad.get(), {}
	for k, v in pairs(p) do
		if v == true then on[#on + 1] = k end
	end
	table.sort(on)
	return table.concat(on, "+")
end

local last, frames = {}, 0
log("task_probe loaded")
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local pad = padString()
	local cb2 = memory.read_u32_le(GMAIN_CB2, BUS)
	if last.cb2 ~= cb2 then
		last.cb2 = cb2
		log(string.format("CB2 %08X pad=%s", cb2, pad))
	end
	if last.pad ~= pad then
		last.pad = pad
		log("PAD " .. pad)
	end
	local b = memory.read_bytes_as_array(GTASKS, TASK_SIZE * NUM_TASKS, BUS)
	for n = 0, NUM_TASKS - 1 do
		local o = n * TASK_SIZE
		if b[o + 5] ~= 0 then
			local out = {}
			for i = 1, TASK_SIZE do out[i] = string.format("%02X", b[o + i]) end
			local raw = table.concat(out)
			if last[n] ~= raw then
				last[n] = raw
				local func = b[o + 1] | (b[o + 2] << 8) | (b[o + 3] << 16) | (b[o + 4] << 24)
				log(string.format("TASK %d func=%08X %s", n, func, raw))
			end
		elseif last[n] then
			last[n] = nil
			log(string.format("GONE %d", n))
		end
	end
	if frames % 60 == 0 then flush() end
end
MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	flush()
	if logf then logf:close() end
	logf = nil
end
