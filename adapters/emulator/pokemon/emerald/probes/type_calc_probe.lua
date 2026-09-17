-- MeshGhost — Pokémon Emerald: what a move's type does to its damage (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-17
--
-- WHY THIS EXISTS. autoplay's `battle` chooses a move by power times accuracy alone. A policy that weighs types needs
-- the game's own type table and what the battle does with it (the user, 2026-09-17: the game's table is what gets
-- measured, a Gen III type chart only the map). The decomp says the table is the ROM block the build names
-- gTypeEffectiveness, and that a move's damage word (gBattleMoveDamage) is multiplied by it inside the battle script
-- command named Cmd_typecalc, between Cmd_damagecalc and Cmd_adjustnormaldamage. That is where to look; this logs
-- what the game actually does there.
--
-- ADDRESSES: a pokeemerald build whose ROM hashed identical to the vanilla ROM (SHA-1, 2026-09-16) proves where each
-- lives (the names below are the build's), not what its bytes mean. Vanilla only.
--
-- WHAT IT LOGS (type_calc_probe_<target>_<time>.log beside this file; gitignored):
--   TYPE i   once at load: the 7-byte type name at index i of the block named gTypeNames (autoplay reads move types
--            from it), for i 0-17
--   TABLE    once at load: the 0x150 bytes named gTypeEffectiveness as triples, raw and with the names above
--   TC       entry to Cmd_typecalc: gCurrentMove and its name, the move's type byte (+2 of its 12-byte entry in the
--            block named gBattleMoves), gBattlerAttacker and gBattlerTarget, gBattleMoveDamage (s32), gMoveResultFlags,
--            and for both battlers: species, the bytes +0x20 (ability) and +0x21/+0x22 (types) of its gBattleMons
--            entry, and +6/+7 of that species' 28-byte entry in the block named gSpeciesInfo
--   ADJ      entry to Cmd_adjustnormaldamage: gBattleMoveDamage and gMoveResultFlags
--   STR      on any change of the first 0x80 bytes named gDisplayedStringBattle, decoded (letters, digits, space)
-- WHAT IT CANNOT SEE: damage computed by any other command (typecalc2, a fixed-damage move), anything between the two
-- hooks other than their words, a patched ROM.
--
-- COST: two execute hooks (autoplay's driver already runs eight, and any number costs the same half of top speed:
-- `emerald/MEASURED.md`, "What the driver and its hooks cost"), and one 0x80-byte read a frame.

local BUS = "System Bus"
local CMD_TYPECALC, CMD_ADJUSTNORMALDAMAGE = 0x08047038, 0x080478f4
local TYPE_EFFECTIVENESS, TYPE_EFFECTIVENESS_LEN = 0x0831ace8, 0x150
local TYPE_NAMES, TYPE_NAME_LEN = 0x0831ae38, 7
local BATTLE_MOVES, MOVE_NAMES, MOVE_NAME_LEN = 0x0831c898, 0x0831977c, 13
local SPECIES_INFO, SPECIES_INFO_SIZE = 0x083203cc, 28
local CURRENT_MOVE, ATTACKER, TARGET = 0x020241ea, 0x0202420b, 0x0202420c
local MOVE_DAMAGE, RESULT_FLAGS = 0x020241f0, 0x0202427c
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
local logf = io.open(string.format("%s/type_calc_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
local pending = {}
local function log(s) pending[#pending + 1] = string.format("f%d %s", emu.framecount(), s) end
local function flush()
	if logf and #pending > 0 then
		logf:write(table.concat(pending, "\n"), "\n")
		logf:flush() -- on a timer, never per frame
		pending = {}
	end
end

local function hex(b)
	local out = {}
	for i = 1, #b do out[i] = string.format("%02X", b[i]) end
	return table.concat(out)
end
local function decode(b)
	local out = {}
	for i = 1, #b do
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

local typeNames = {}
for i = 0, 17 do
	typeNames[i] = decode(memory.read_bytes_as_array(TYPE_NAMES + i * TYPE_NAME_LEN, TYPE_NAME_LEN, BUS))
	log(string.format("TYPE %d %s", i, typeNames[i]))
end
local function typeName(t) return typeNames[t] or string.format("?%02X", t) end
do
	local b = memory.read_bytes_as_array(TYPE_EFFECTIVENESS, TYPE_EFFECTIVENESS_LEN, BUS)
	for i = 1, TYPE_EFFECTIVENESS_LEN - 2, 3 do
		log(string.format("TABLE %3d %02X %02X %02X  %s %s %d", (i - 1) // 3, b[i], b[i + 1], b[i + 2],
			typeName(b[i]), typeName(b[i + 1]), b[i + 2]))
	end
end

local function battler(n)
	local at = BATTLE_MONS + n * BATTLE_MON_SIZE
	local species = memory.read_u16_le(at, BUS)
	local s = memory.read_bytes_as_array(SPECIES_INFO + species * SPECIES_INFO_SIZE + 6, 2, BUS)
	local m = memory.read_bytes_as_array(at + 0x20, 3, BUS)
	return string.format("b%d species=%d ability=%02X types=%02X,%02X(%s/%s) speciesinfo=%02X,%02X", n, species, m[1], m[2], m[3],
		typeName(m[2]), typeName(m[3]), s[1], s[2])
end

local hooks = {
	{ name = "TC", at = CMD_TYPECALC, fn = function()
		local move = memory.read_u16_le(CURRENT_MOVE, BUS)
		local mtype = memory.read_u8(BATTLE_MOVES + move * 12 + 2, BUS)
		local att, tgt = memory.read_u8(ATTACKER, BUS), memory.read_u8(TARGET, BUS)
		log(string.format("TC move=%d %s type=%02X(%s) attacker=%d target=%d damage=%d flags=%02X | %s | %s", move,
			decode(memory.read_bytes_as_array(MOVE_NAMES + move * MOVE_NAME_LEN, MOVE_NAME_LEN, BUS)), mtype, typeName(mtype),
			att, tgt, memory.read_s32_le(MOVE_DAMAGE, BUS), memory.read_u8(RESULT_FLAGS, BUS), battler(att), battler(tgt)))
	end },
	{ name = "ADJ", at = CMD_ADJUSTNORMALDAMAGE, fn = function()
		log(string.format("ADJ damage=%d flags=%02X", memory.read_s32_le(MOVE_DAMAGE, BUS), memory.read_u8(RESULT_FLAGS, BUS)))
	end },
}
local hookNames = {}
for _, h in ipairs(hooks) do
	local name = "meshghost_type_calc_probe_" .. h.name
	pcall(event.unregisterbyname, name)
	local ok, err = pcall(event.onmemoryexecute, function()
		local hok, herr = pcall(h.fn)
		if not hok then log("HOOK ERROR " .. h.name .. ": " .. tostring(herr)) end
	end, h.at, name)
	log(string.format("hook %s at %08X: %s", h.name, h.at, ok and "registered" or ("REFUSED " .. tostring(err))))
	if ok then hookNames[#hookNames + 1] = name end
end
flush()

local lastStr, frames = nil, 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local b = memory.read_bytes_as_array(STRING_BATTLE, 0x80, BUS)
	local s = hex(b)
	if s ~= lastStr then
		lastStr = s
		log(string.format("STR %q", decode(b)))
	end
	if frames % 60 == 0 then flush() end
end
MESHGHOST_DEV_UNLOAD = function()
	for _, name in ipairs(hookNames) do pcall(event.unregisterbyname, name) end
	log("unloaded")
	flush()
	if logf then logf:close() end
	logf = nil
end
