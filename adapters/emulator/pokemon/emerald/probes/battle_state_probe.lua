-- MeshGhost — Pokémon Emerald: a battle's state, raw (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-16
--
-- WHY THIS EXISTS. autoplay's Phase 1 ends at the first trainer battle (`agent_docs/phases/phase13.md`),
-- so `observe` has to say a battle is on, who is in it, what the game is asking, and where its cursors
-- are. `battle_probe.lua` only showed gMain.callback2 leaving the overworld. What each byte below
-- means is to be measured: this logs them raw whenever any changes, with the pad, so each reading can
-- be paired with a capture of the same frame.
--
-- ADDRESSES: a pokeemerald build whose ROM hashed identical to the vanilla ROM (SHA-1, 2026-09-16)
-- proves where each lives (the names below are the build's), not what its bytes mean. Vanilla only.
--
-- WHAT IT LOGS (battle_state_probe_<target>_<time>.log beside this file; gitignored):
--   ST    on any change of: gMain.callback2, gBattleTypeFlags, gBattlersCount, gBattlerPartyIndexes,
--         gBattlerPositions, gActionSelectionCursor, gMoveSelectionCursor, gBattleOutcome,
--         gBattleCommunication, gBattleControllerExecFlags, gBattlerControllerFuncs, gActiveBattler,
--         gChosenActionByBattler, gMultiUsePlayerCursor, gAbsentBattlerFlags, gBattlescriptCurrInstr and
--         all 0x28 bytes of gBattleScripting -- all raw hex -- and the pad
--   MON n on any change of that battler's 0x58 bytes named gBattleMons: raw hex, and +0x30 decoded
--         as a name (letters and digits only)
--   STR   on any change of the first 0x80 bytes named gDisplayedStringBattle: decoded up to FF, and raw
-- WHAT IT CANNOT SEE: text drawn by any path that does not fill that buffer; anything in the frames
-- between two logged changes; a patched ROM.

local BUS = "System Bus"
local GMAIN_CB2 = 0x030022c4
local FIELDS = {
	{ "typeflags", 0x02022fec, 4 }, { "count", 0x0202406c, 1 }, { "partyidx", 0x0202406e, 8 },
	{ "positions", 0x02024076, 4 }, { "actcur", 0x020244ac, 4 }, { "movecur", 0x020244b0, 4 },
	{ "outcome", 0x0202433a, 1 }, { "comm", 0x02024332, 8 }, { "execflags", 0x02024068, 4 },
	{ "ctrlfuncs", 0x03005d60, 16 }, { "active", 0x02024064, 1 }, { "chosen", 0x0202421c, 4 },
	{ "multicur", 0x03005d74, 1 }, { "absent", 0x02024210, 1 },
	-- Added 2026-09-16 (later): the level-up box waited for A with nothing above changing.
	{ "instr", 0x02024214, 4 }, { "scripting", 0x02024474, 0x28 },
}
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

local lastSt, lastMons, lastStr, frames = nil, {}, nil, 0
log("battle_state_probe loaded")
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local parts = { string.format("cb2=%08X", memory.read_u32_le(GMAIN_CB2, BUS)) }
	for _, f in ipairs(FIELDS) do parts[#parts + 1] = f[1] .. "=" .. hex(f[2], f[3]) end
	local st = table.concat(parts, " ")
	if st ~= lastSt then
		log("ST " .. st .. " pad=" .. padString())
		lastSt = st
	end
	for n = 0, 3 do
		local raw = hex(BATTLE_MONS + n * BATTLE_MON_SIZE, BATTLE_MON_SIZE)
		if raw ~= lastMons[n] then
			local b = memory.read_bytes_as_array(BATTLE_MONS + n * BATTLE_MON_SIZE + 0x30, 11, BUS)
			log(string.format("MON %d name=%q raw %s", n, decode(b, 1, 11), raw))
			lastMons[n] = raw
		end
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
