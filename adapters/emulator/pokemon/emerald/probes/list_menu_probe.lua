-- MeshGhost — Pokémon Emerald: list menus such as the bag, raw (dev tool, read-only, vanilla only, never shipped).
-- On any change, with the pad: ST, gMain.callback2, gBagPosition, sMenu, gMultiuseListMenuTemplate and each active
-- task's routine, raw; LIST, per task running ListMenuDummyTask, its 32 data bytes and up to 64 of the entries its
-- first word points at, each a name pointer and an id, the name decoded. Names are the build's.

local BUS = "System Bus"
local GMAIN_CB2 = 0x030022c4
local BAG_POSITION, SMENU, MULTIUSE_LIST = 0x0203ce58, 0x0203cd90, 0x03006310
local GTASKS, TASK_SIZE, NUM_TASKS = 0x03005e00, 40, 16
local LIST_MENU_DUMMY_TASK = 0x081ae458

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local target = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "default"):gsub("[^%w_%-]", "_")
local logf = io.open(string.format("%s/list_menu_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
local pending = {}
local function log(s) pending[#pending + 1] = string.format("f%d %s", emu.framecount(), s) end
local function flush()
	if logf and #pending > 0 then
		logf:write(table.concat(pending, "\n"), "\n")
		logf:flush()
		pending = {}
	end
end

local function hex(a, n)
	local b, out = memory.read_bytes_as_array(a, n, BUS), {}
	for i = 1, n do out[i] = string.format("%02X", b[i]) end
	return table.concat(out)
end

local function inMemory(p) return (p >= 0x02000000 and p < 0x02040000) or (p >= 0x03000000 and p < 0x03008000) or (p >= 0x08000000 and p < 0x0A000000) end

local function decodeAt(p)
	if not inMemory(p) then return string.format("<%08X>", p) end
	local b, out = memory.read_bytes_as_array(p, 32, BUS), {}
	for i = 1, 32 do
		local c = b[i]
		if c == 0xFF then break end
		if c >= 0xBB and c <= 0xD4 then
			out[#out + 1] = string.char(0x41 + c - 0xBB)
		elseif c >= 0xD5 and c <= 0xEE then
			out[#out + 1] = string.char(0x61 + c - 0xD5)
		elseif c >= 0xA1 and c <= 0xAA then
			out[#out + 1] = tostring(c - 0xA1)
		elseif c == 0x00 then
			out[#out + 1] = " "
		else
			out[#out + 1] = string.format("{%02X}", c)
		end
	end
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

local lastSt, lastLists, frames = nil, {}, 0
log("list_menu_probe loaded")
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local tasks, lists = {}, {}
	for i = 0, NUM_TASKS - 1 do
		local at = GTASKS + i * TASK_SIZE
		if memory.read_u8(at + 4, BUS) ~= 0 then
			local func = memory.read_u32_le(at, BUS)
			tasks[#tasks + 1] = string.format("%d:%08X", i, func)
			if (func & 0xFFFFFFFE) == LIST_MENU_DUMMY_TASK then lists[#lists + 1] = i end
		end
	end
	local st = string.format("cb2=%08X bagpos=%s smenu=%s multilist=%s tasks=%s", memory.read_u32_le(GMAIN_CB2, BUS),
		hex(BAG_POSITION, 0x1C), hex(SMENU, 12), hex(MULTIUSE_LIST, 0x18), table.concat(tasks, ","))
	if st ~= lastSt then
		log("ST " .. st .. " pad=" .. padString())
		lastSt = st
	end
	local seen = {}
	for _, i in ipairs(lists) do
		local data = GTASKS + i * TASK_SIZE + 8
		local raw = hex(data, 32)
		local items, total = memory.read_u32_le(data, BUS), memory.read_u16_le(data + 0x0C, BUS)
		local names = {}
		if inMemory(items) then
			for k = 0, math.min(total, 64) - 1 do
				local e = items + k * 8
				names[#names + 1] = string.format("%d=%q/%d", k, decodeAt(memory.read_u32_le(e, BUS)), memory.read_s32_le(e + 4, BUS))
			end
		end
		local line = raw .. " " .. table.concat(names, " ")
		if line ~= lastLists[i] then
			log(string.format("LIST task %d data=%s", i, line))
			lastLists[i] = line
		end
		seen[i] = true
	end
	for i in pairs(lastLists) do
		if not seen[i] then
			log(string.format("LIST task %d gone", i))
			lastLists[i] = nil
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
