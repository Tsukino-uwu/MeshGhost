-- MeshGhost — Emerald: each move in MOVES from the ROM, once: its 12-byte entry, the type name its +2 picks and its
-- effect text, to read against the summary's BATTLE MOVES page (dev tool, read-only, vanilla addresses).

local BUS = "System Bus"
local MOVES = { 33, 45, 189 } -- the MUDKIP's TACKLE, GROWL and MUD-SLAP
local BATTLE_MOVES, MOVE_SIZE = 0x0831c898, 12
local TYPE_NAMES, TYPE_LEN = 0x0831ae38, 7
local DESCRIPTIONS = 0x0861c524
local MOVE_NAMES, MOVE_LEN = 0x0831977c, 13

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logf = io.open(string.format("%s/move_data_probe_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")

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
		elseif c == 0xAD then
			out[#out + 1] = "."
		elseif c == 0xAE then
			out[#out + 1] = "-"
		else
			out[#out + 1] = string.format("{%02X}", c)
		end
	end
	return table.concat(out)
end

for _, id in ipairs(MOVES) do
	local e = memory.read_bytes_as_array(BATTLE_MOVES + id * MOVE_SIZE, MOVE_SIZE, BUS)
	local raw, nums = {}, {}
	for i = 1, MOVE_SIZE do
		raw[i] = string.format("%02X", e[i])
		nums[i] = string.format("+%d=%d", i - 1, e[i])
	end
	local name = decode(memory.read_bytes_as_array(MOVE_NAMES + id * MOVE_LEN, MOVE_LEN, BUS), 1, MOVE_LEN)
	local typeName = decode(memory.read_bytes_as_array(TYPE_NAMES + e[3] * TYPE_LEN, TYPE_LEN, BUS), 1, TYPE_LEN)
	local ptr = memory.read_u32_le(DESCRIPTIONS + (id - 1) * 4, BUS)
	local desc = "(pointer not in ROM)"
	if ptr >= 0x08000000 and ptr < 0x0A000000 then desc = decode(memory.read_bytes_as_array(ptr, 128, BUS), 1, 128) end
	if logf then
		logf:write(string.format("MOVE %d %q raw %s | %s | type(+2) name %q | desc@%08X %q\n", id, name,
			table.concat(raw), table.concat(nums, " "), typeName, ptr, desc))
	end
end
if logf then
	logf:write("done\n")
	logf:close()
	logf = nil
end
MESHGHOST_DEV_TICK = function() end
