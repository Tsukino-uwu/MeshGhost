-- MeshGhost — Pokémon Emerald: which of a Pokémon's four encrypted 12-byte blocks the game reads for
-- which kind of data, per personality (DEV TOOL, WRITES gPlayerParty -- live RAM, restored on unload
-- -- never shipped) -- 2026-09-16
--
-- WHY THIS EXISTS. autoplay's `observe` reads the party's species, held item and moves, which sit in
-- the 48 encrypted bytes at +0x20 of each 0x64-byte slot (`party_bag_probe.lua`: XOR with +0x00 ^ +0x04
-- makes the words sum to +0x1C). WHICH block holds what depends on the personality word, and one
-- party of one Pokémon shows one arrangement. This asks the game's own routine for all of them.
--
-- HOW. The routine the build names GetSubstruct is entered with the slot in R0, the personality in R1
-- and a kind 0-3 in R2 (read here, not assumed: each call is logged raw), and returns a pointer. An
-- execute hook at its entry notes the call and its return address; a second hook at that return
-- address (installed from the tick, the first time an address is seen) reads the pointer, so the
-- block is (pointer - slot - 0x20) / 12. To give the game every personality mod 24, each round
-- rewrites all six slots as copies of slot 0 whose personalities have residues round*6 + slot, with
-- all four decrypted blocks set to slot 0's species block -- so however the game orders them, the
-- summary screen reads a valid species, moves and flags -- re-encrypted and with +0x1C recomputed.
-- Open a slot's SUMMARY and page through all six with Down; then write the next round.
--
-- COMMAND FILE: `substruct_order_probe.cmd` beside this script (`.gitignore` covers `*.cmd`), read
-- every 15 frames: a round number 0-3 writes that round; `restore` puts the party back. Unloading
-- restores it too.
--
-- ADDRESSES: a pokeemerald build whose ROM hashed identical to the vanilla ROM (SHA-1, 2026-09-16)
-- proves where the routine and the party live. Vanilla only.
-- LOG: substruct_order_probe_<time>.log beside this file (gitignored): ROUND lines (what was written),
-- CALL lines (each distinct entry: R1 mod 24, R2, return address), SEEN lines (each distinct
-- residue/kind -> block) and CONFLICT lines (the same residue and kind giving another block).
-- WHAT IT CANNOT SEE: calls made before a return address was hooked (the first page view of a round
-- can miss some); a kind never read on the screens opened.

local BUS = "System Bus"
local PARTY_COUNT, PARTY, MON_SIZE = 0x020244e9, 0x020244ec, 0x64
local GETSUBSTRUCT = 0x0806a270

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local CMD = dir .. "/substruct_order_probe.cmd"
local logf = io.open(string.format("%s/substruct_order_probe_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
local pending = {}
local function log(s) pending[#pending + 1] = string.format("f%d %s", emu.framecount(), s) end
local function flush()
	if logf and #pending > 0 then
		logf:write(table.concat(pending, "\n"), "\n")
		logf:flush()
		pending = {}
	end
end

local original = { count = memory.read_u8(PARTY_COUNT, BUS), bytes = memory.read_bytes_as_array(PARTY, MON_SIZE * 6, BUS) }

local function u32of(b, i) return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24) end

local function writeRound(round)
	local b = original.bytes
	local pers, otId = u32of(b, 1), u32of(b, 5)
	-- Slot 0's decrypted block 1 (the block holding MUDKIP's species on this save, party_bag_probe).
	local key = pers ~ otId
	local block = {}
	for w = 0, 2 do
		local v = u32of(b, 33 + 12 + w * 4) ~ key
		for k = 0, 3 do block[#block + 1] = (v >> (8 * k)) & 0xFF end
	end
	local sum = 0
	for rep = 1, 4 do
		for i = 1, 12, 2 do sum = sum + block[i] + (block[i + 1] << 8) end
	end
	sum = sum & 0xFFFF
	for slot = 0, 5 do
		local residue = round * 6 + slot
		local p = pers - (pers % 24) + residue
		local k2 = p ~ otId
		local at = PARTY + slot * MON_SIZE
		for i = 0, MON_SIZE - 1 do memory.write_u8(at + i, b[i + 1], BUS) end
		memory.write_u32_le(at, p, BUS)
		memory.write_u16_le(at + 0x1C, sum, BUS)
		for blk = 0, 3 do
			for w = 0, 2 do
				local v = u32of(block, 1 + w * 4) ~ k2
				memory.write_u32_le(at + 0x20 + blk * 12 + w * 4, v, BUS)
			end
		end
		log(string.format("ROUND %d slot %d pers=%08X residue=%d readback pers=%08X sum=%04X", round, slot, p, p % 24,
			memory.read_u32_le(at, BUS), memory.read_u16_le(at + 0x1C, BUS)))
	end
	memory.write_u8(PARTY_COUNT, 6, BUS)
	flush()
end

local function restore()
	for i = 1, MON_SIZE * 6 do memory.write_u8(PARTY + i - 1, original.bytes[i], BUS) end
	memory.write_u8(PARTY_COUNT, original.count, BUS)
	log(string.format("RESTORED count=%d readback=%d", original.count, memory.read_u8(PARTY_COUNT, BUS)))
	flush()
end

local call = nil
local returnAddrs, toHook = {}, {}
local calls, seen = {}, {}
local hookNames = {}

local function onEntry()
	local lr = emu.getregister("R14") & 0xFFFFFFFE
	call = { mon = emu.getregister("R0"), pers = emu.getregister("R1"), kind = emu.getregister("R2") & 0xFF, lr = lr }
	local k = string.format("%d/%d/%08X", call.pers % 24, call.kind, lr)
	if not calls[k] then
		calls[k] = true
		log(string.format("CALL mon=%08X pers=%08X residue=%d kind=%d return=%08X", call.mon, call.pers, call.pers % 24, call.kind, lr))
	end
	if not returnAddrs[lr] then
		returnAddrs[lr] = true
		toHook[#toHook + 1] = lr
	end
end

local function onReturn(addr)
	return function()
		if not call or call.lr ~= addr then return end
		local ptr = emu.getregister("R0")
		local off = ptr - call.mon - 0x20
		local k = string.format("%d/%d", call.pers % 24, call.kind)
		local blockIdx = (off % 12 == 0) and (off // 12) or -1
		if seen[k] == nil then
			seen[k] = blockIdx
			log(string.format("SEEN residue=%d kind=%d block=%d (ptr=%08X mon=%08X)", call.pers % 24, call.kind, blockIdx, ptr, call.mon))
		elseif seen[k] ~= blockIdx then
			log(string.format("CONFLICT residue=%d kind=%d block=%d, earlier %d", call.pers % 24, call.kind, blockIdx, seen[k]))
		end
		call = nil
	end
end

local ok = pcall(event.onmemoryexecute, onEntry, GETSUBSTRUCT, "substruct_order_entry")
hookNames[#hookNames + 1] = "substruct_order_entry"
log("substruct_order_probe loaded; entry hook " .. (ok and "installed" or "REFUSED") ..
	string.format("; original party count %d", original.count))
flush()

local last, frames = nil, 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	while #toHook > 0 do
		local a = table.remove(toHook)
		local name = string.format("substruct_order_ret_%08X", a)
		local hooked = pcall(event.onmemoryexecute, onReturn(a), a, name)
		hookNames[#hookNames + 1] = name
		log(string.format("return hook at %08X %s", a, hooked and "installed" or "REFUSED"))
	end
	if frames % 15 == 0 then
		local fh = io.open(CMD, "r")
		if fh then
			local s = fh:read("*a"):match("^%s*(.-)%s*$")
			fh:close()
			if s ~= last then
				last = s
				local round = tonumber(s)
				if round and round >= 0 and round <= 3 then
					writeRound(round)
				elseif s == "restore" then
					restore()
				end
			end
		end
	end
	if frames % 120 == 0 then
		local n = 0
		for _ in pairs(seen) do n = n + 1 end
		log(string.format("tally: %d residue/kind pairs seen", n))
		flush()
	end
end
MESHGHOST_DEV_UNLOAD = function()
	for _, name in ipairs(hookNames) do pcall(event.unregisterbyname, name) end
	restore()
	log("unloaded")
	flush()
	if logf then logf:close() end
	logf = nil
end
