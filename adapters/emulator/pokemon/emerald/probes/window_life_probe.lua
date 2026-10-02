-- MeshGhost — Pokémon Emerald: when windows are set up, added, removed and freed (dev tool, read-only, vanilla only,
-- never shipped). Execute hooks on the routines in HOOKS log each call with R0, gMain.callback2 and byte +0 of window
-- ids 0-11, plus a CB2 line on each change of callback2; it logs calls, not the state between them.

local BUS = "System Bus"
local GMAIN_CB2 = 0x030022c4
local GWINDOWS, WINDOW_SIZE = 0x02020004, 12
local HOOKS = {
	{ "InitWindows", 0x080031c0 }, { "AddWindow", 0x08003380 }, { "RemoveWindow", 0x08003574 },
	{ "FreeAllWindowBuffers", 0x08003604 }, { "ClearWindowTilemap", 0x080038a4 },
	{ "Menu_MoveCursor", 0x081984d8 },
}

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local target = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "default"):gsub("[^%w_%-]", "_")
local logf = io.open(string.format("%s/window_life_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
local pending = {}
local function log(s) pending[#pending + 1] = string.format("f%d %s", emu.framecount(), s) end
local function flush()
	if logf and #pending > 0 then
		logf:write(table.concat(pending, "\n"), "\n")
		logf:flush()
		pending = {}
	end
end

local function windows()
	local out = {}
	for w = 0, 11 do out[#out + 1] = string.format("%02X", memory.read_u8(GWINDOWS + w * WINDOW_SIZE, BUS)) end
	return table.concat(out, " ")
end

local names = {}
for i, h in ipairs(HOOKS) do
	local name = "window_life_" .. i
	local ok = pcall(event.onmemoryexecute, function()
		log(string.format("%-20s R0=%08X cb2=%08X windows[0-11] %s", h[1], emu.getregister("R0"),
			memory.read_u32_le(GMAIN_CB2, BUS), windows()))
	end, h[2], name)
	names[#names + 1] = name
	log(string.format("hook %s at %08X %s", h[1], h[2], ok and "installed" or "REFUSED"))
end
flush()

local lastCb2, frames = nil, 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local cb2 = memory.read_u32_le(GMAIN_CB2, BUS)
	if cb2 ~= lastCb2 then
		log(string.format("CB2 %08X windows[0-11] %s", cb2, windows()))
		lastCb2 = cb2
	end
	if frames % 60 == 0 then flush() end
end
MESHGHOST_DEV_UNLOAD = function()
	for _, n in ipairs(names) do pcall(event.unregisterbyname, n) end
	log("unloaded")
	flush()
	if logf then logf:close() end
	logf = nil
end
