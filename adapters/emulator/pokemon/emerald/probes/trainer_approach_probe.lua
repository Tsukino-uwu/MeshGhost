-- MeshGhost — Pokémon Emerald: a trainer coming for the player, raw (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-17
--
-- WHY THIS EXISTS. autoplay's `goto` ran into a trainer's line and answered `no_response` while the trainer
-- walked over: from the input side, a trainer's approach looks like a stuck hold. The decomp names globals
-- the sight check sets; which of them say "a trainer is coming", and from which frame, is to be measured.
-- This logs them raw whenever any changes, with the player's coordinates and the pad, so the frame the
-- player steps into a line can be paired with the frame they change.
--
-- ADDRESSES: a pokeemerald build whose ROM hashed identical to the vanilla ROM (SHA-1, 2026-09-16)
-- proves where each lives (the names below are the build's), not what its bytes mean. Vanilla only.
--
-- WHAT IT LOGS (trainer_approach_probe_<target>_<time>.log beside this file; gitignored):
--   ST on any change of: gNoOfApproachingTrainers, gTrainerApproachedPlayer, gApproachingTrainerId,
--      the 0x18 bytes of gApproachingTrainers, sGlobalScriptContextStatus, gSelectedObjectEvent,
--      gSpecialVar_LastTalked, gMain.callback2, the player's SaveBlock1 coordinates and the avatar
--      block's first four bytes -- all raw hex -- and the pad
-- WHAT IT CANNOT SEE: anything in the frames between two logged changes; which object a trainer is by
-- anything but its slot; a patched ROM.

local BUS = "System Bus"
local SB1PTR = 0x03005d8c
local FIELDS = {
	{ "napproach", 0x030060a8, 1 }, { "approached", 0x030060ac, 1 }, { "approachid", 0x02038bfc, 1 },
	{ "approaching", 0x03006090, 0x18 }, { "ctxstatus", 0x03000e38, 1 }, { "selected", 0x03005df0, 1 },
	{ "lasttalked", 0x020375f2, 2 }, { "cb2", 0x030022c4, 4 }, { "avatar", 0x02037590, 4 },
}

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local target = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "default"):gsub("[^%w_%-]", "_")
local logf = io.open(string.format("%s/trainer_approach_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
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

local function padString()
	local p, on = joypad.get(), {}
	for k, v in pairs(p) do
		if v == true then on[#on + 1] = k end
	end
	table.sort(on)
	return table.concat(on, "+")
end

local last, frames = nil, 0
log("trainer_approach_probe loaded")
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local sb1 = memory.read_u32_le(SB1PTR, BUS)
	local parts = {}
	if sb1 >= 0x02000000 and sb1 < 0x02040000 then
		parts[1] = string.format("xy=%d,%d", memory.read_u16_le(sb1, BUS), memory.read_u16_le(sb1 + 2, BUS))
	else
		parts[1] = "xy=?"
	end
	for _, f in ipairs(FIELDS) do parts[#parts + 1] = f[1] .. "=" .. hex(f[2], f[3]) end
	local st = table.concat(parts, " ")
	if st ~= last then
		log("ST " .. st .. " pad=" .. padString())
		last = st
	end
	if frames % 60 == 0 then flush() end
end
MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	flush()
	if logf then logf:close() end
	logf = nil
end
