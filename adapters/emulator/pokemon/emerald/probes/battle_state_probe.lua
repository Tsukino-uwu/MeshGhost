-- MeshGhost — Emerald: a battle's state, raw, on every change with the pad, to pair with captures (dev tool, reads).
-- Vanilla addresses only; it cannot see text drawn by a path that does not fill gDisplayedStringBattle.

local BUS = "System Bus"
local GMAIN_CB2 = 0x030022c4
local FIELDS = {
	{ "typeflags", 0x02022fec, 4 }, { "count", 0x0202406c, 1 }, { "partyidx", 0x0202406e, 8 },
	{ "positions", 0x02024076, 4 }, { "actcur", 0x020244ac, 4 }, { "movecur", 0x020244b0, 4 },
	{ "outcome", 0x0202433a, 1 }, { "comm", 0x02024332, 8 }, { "execflags", 0x02024068, 4 },
	{ "ctrlfuncs", 0x03005d60, 16 }, { "active", 0x02024064, 1 }, { "chosen", 0x0202421c, 4 },
	{ "multicur", 0x03005d74, 1 }, { "absent", 0x02024210, 1 },
	-- gBattlescriptCurrInstr, gBattleScripting
	{ "instr", 0x02024214, 4 }, { "scripting", 0x02024474, 0x28 },
	-- gAnimScriptActive, gPauseCounterBattle
	{ "anim", 0x020383fd, 1 }, { "pause", 0x0202432c, 2 },
	-- gBattleMainFunc, gIntroSlideFlags
	{ "mainfunc", 0x03005d04, 4 }, { "slide", 0x020243fc, 2 },
	-- gMoveToLearn
	{ "movetolearn", 0x020244e2, 2 },
}
-- sMonSummaryScreen (logged with 12 bytes at its +0x40BC) and gTasks, 16 tasks of 40 bytes.
local SUMMARY_PTR, TASKS = 0x0203cf1c, 0x03005e00
-- sTextPrinters: the first two, 0x24 bytes each.
local PRINTERS, PRINTERS_LEN = 0x020201b0, 0x48
local BATTLE_MONS, BATTLE_MON_SIZE = 0x02024084, 0x58
local STRING_BATTLE = 0x02022e2c

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local target = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "default"):gsub("[^%w_%-]", "_")
local logf = io.open(string.format("%s/battle_state_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
local pending = {}
local function log(s) pending[#pending + 1] = string.format("f%d %s", emu.framecount(), s) end
local function flush()
	if logf and #pending > 0 then
		logf:write(table.concat(pending, "\n"), "\n")
		logf:flush() -- on a timer, never per frame
		pending = {}
	end
end

local function hex(a, n)
	local b, out = memory.read_bytes_as_array(a, n, BUS), {}
	for i = 1, n do out[i] = string.format("%02X", b[i]) end
	return table.concat(out)
end
local function decode(b, from, to)
	local out = {}
	for i = from, to do
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
		elseif c == 0xFE then
			out[#out + 1] = "\\n"
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

local lastSt, lastMons, lastStr, lastPr, frames = nil, {}, nil, nil, 0
local lastSum, lastTasks = nil, nil
log("battle_state_probe loaded")
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local parts = { string.format("cb2=%08X", memory.read_u32_le(GMAIN_CB2, BUS)) }
	for _, f in ipairs(FIELDS) do parts[#parts + 1] = f[1] .. "=" .. hex(f[2], f[3]) end
	local st = table.concat(parts, " ") .. " pad=" .. padString()
	if st ~= lastSt then
		log("ST " .. st)
		lastSt = st
	end
	local pr = hex(PRINTERS, PRINTERS_LEN)
	if pr ~= lastPr then
		log("PR " .. pr)
		lastPr = pr
	end
	for n = 0, 3 do
		local raw = hex(BATTLE_MONS + n * BATTLE_MON_SIZE, BATTLE_MON_SIZE)
		if raw ~= lastMons[n] then
			local b = memory.read_bytes_as_array(BATTLE_MONS + n * BATTLE_MON_SIZE + 0x30, 11, BUS)
			log(string.format("MON %d name=%q raw %s", n, decode(b, 1, 11), raw))
			lastMons[n] = raw
		end
	end
	local sp = memory.read_u32_le(SUMMARY_PTR, BUS)
	local sum = string.format("%08X", sp) .. ((sp >= 0x02000000 and sp < 0x02040000) and (" " .. hex(sp + 0x40BC, 12)) or "")
	if sum ~= lastSum then
		log("SUM " .. sum)
		lastSum = sum
	end
	local tasks = {}
	for i = 0, 15 do
		local at = TASKS + i * 40
		if memory.read_u8(at + 4, BUS) ~= 0 then
			tasks[#tasks + 1] = string.format("%d:%08X:%s", i, memory.read_u32_le(at, BUS), hex(at + 8, 24))
		end
	end
	local tk = table.concat(tasks, " ")
	if tk ~= lastTasks then
		log("TASK " .. tk)
		lastTasks = tk
	end
	local sraw = hex(STRING_BATTLE, 0x80)
	if sraw ~= lastStr then
		log(string.format("STR %q raw %s", decode(memory.read_bytes_as_array(STRING_BATTLE, 0x80, BUS), 1, 0x80), sraw))
		lastStr = sraw
	end
	if frames % 60 == 0 then flush() end
end
MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	flush()
	if logf then logf:close() end
	logf = nil
end
