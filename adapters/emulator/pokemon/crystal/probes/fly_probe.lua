-- Why a spawned ghost goes invisible during a Fly landing: the player and every occupied object slot on one line,
-- run-length encoded. Read-only; play normally and Fly. It separates our yoff write pushing the ghost off screen (its
-- yoff large while it vanishes) from the game freezing every object (SU=1 for exactly those frames); face=FF is the
-- engine drawing nothing. Offsets from meshghost_crystal.lua, flag bits from the decompilation. Logs beside the script.

-- WRAM, flat, never System Bus: on a GBC that reads $D000-$DFFF through whichever bank is selected.
local DOMAIN = "WRAM"
local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

local OBJ, OBJ_LEN, NUM_OBJ = flat(0xD4D6), 0x28, 13
local F_SPRITE, F_MOI, F_FLAGS1, F_FLAGS2 = 0x00, 0x01, 0x04, 0x05
local F_ACTION, F_FACING, F_SPRITE_Y, F_YOFF = 0x0B, 0x0D, 0x18, 0x1A
local W_STATE_FLAGS, SPRITE_UPDATES_DISABLED = flat(0xD0ED), 0x01

local function u8(a)
	local ok, v = pcall(memory.read_u8, a, DOMAIN)
	return (ok and v) or 0
end

-- The image the engine drew for the player: OAM entry 0's tile relative to OBJECT_SPRITE_TILE, as the frame learner
-- stores it. Entry 0 belongs to a higher-priority object, such as an emote, while one is up.
local function playerTile()
	local base = u8(OBJ + 0x02)
	local tile = memory.read_u8(2, "OAM") or 0
	return (tile - base) & 0xFF
end

-- Signed, the way the engine stores it: the byte is two's complement.
local function s8(a)
	local v = u8(a)
	return (v > 127) and (v - 256) or v
end

local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	f = io.open(string.format("%s/fly_probe_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, flushed on a timer: a flush per line costs frames and changes what is measured.
	if f then f:setvbuf("full", 1 << 16) end
end

local frames, run, pending = 0, { key = nil, count = 0, first = 0 }, 0
-- Coverage, reported rather than assumed: an instrument says what it could not see.
local seen = { ghostFrames = 0, noGhostFrames = 0, suFrames = 0, maxYoffP = 0, maxSlots = 0 }

local function w(s)
	if f then f:write(s) end
end

local function flushRun(final)
	if run.key then
		w(string.format("  f=%-7d %s   x%d frames\n", run.first, run.key, run.count))
	end
	run.key, run.count = nil, 0
	if final and f then f:flush() end
end

-- Every occupied slot, unfiltered: a spawned ghost does not reliably read OBJECT_MAP_OBJECT_INDEX $FF, and a filter
-- applied before looking is a guess about the answer.
local function occupied()
	local out = {}
	for i = 1, NUM_OBJ - 1 do
		local b = OBJ + i * OBJ_LEN
		if u8(b + F_SPRITE) ~= 0 then
			out[#out + 1] = string.format("[%d]s=%d m=%02X a=%d f=%02X y=%+d f2=%02X",
				i, u8(b + F_SPRITE), u8(b + F_MOI), u8(b + F_ACTION), u8(b + F_FACING),
				s8(b + F_YOFF), u8(b + F_FLAGS2))
		end
	end
	return out
end

w("=== MeshGhost -- Crystal: the Fly landing, player and ghost on one line ===\n")
w("Read-only. Play normally and Fly to a town; nothing here needs to be timed.\n")
w("face=FF means the engine drew NOTHING for that character that frame.\n")
w("SU=1 means wStateFlags has SPRITE_UPDATES_DISABLED -- every object is on the frozen path.\n")
w("f2 bit 0x20 = FROZEN, bit 0x40 = OFF_SCREEN. yoff is signed.\n\n")
pcall(function()
	console.log("MeshGhost fly_probe: read-only, logging to file. Fly to a town whenever you like.")
end)

MESHGHOST_DEV_TICK = function()
	frames = frames + 1

	local slots = occupied()
	local su = (u8(W_STATE_FLAGS) & SPRITE_UPDATES_DISABLED) ~= 0
	local pYoff = s8(OBJ + F_YOFF)

	if #slots > 0 then
		seen.ghostFrames = seen.ghostFrames + 1
	else
		seen.noGhostFrames = seen.noGhostFrames + 1
	end
	if su then seen.suFrames = seen.suFrames + 1 end
	if math.abs(pYoff) > math.abs(seen.maxYoffP) then seen.maxYoffP = pYoff end
	if #slots > seen.maxSlots then seen.maxSlots = #slots end

	local key = string.format(
		"SU=%d | P spr=%3d act=%2d face=%02X tile=%02X yoff=%+4d sy=%3d f1=%02X f2=%02X | %s",
		su and 1 or 0,
		u8(OBJ + F_SPRITE), u8(OBJ + F_ACTION), u8(OBJ + F_FACING), playerTile(),
		pYoff, u8(OBJ + F_SPRITE_Y), u8(OBJ + F_FLAGS1), u8(OBJ + F_FLAGS2),
		(#slots > 0) and table.concat(slots, " ") or "no other object slots occupied")

	-- Run-length, not a line per frame: which frames each state covers is the question.
	if key == run.key then
		run.count = run.count + 1
	else
		flushRun(false)
		run.key, run.count, run.first = key, 1, frames
	end

	pending = pending + 1
	if pending >= 120 then
		pending = 0
		if f then f:flush() end
	end

	-- A standing coverage line, so a log that saw nothing says so.
	if frames % 1800 == 0 then
		flushRun(false)
		w(string.format("  [%ds] coverage: %d frames with at least one other object, %d with none,"
			.. " %d with sprite updates disabled; most slots seen at once %d;"
			.. " largest player yoff %+d\n",
			frames // 60, seen.ghostFrames, seen.noGhostFrames, seen.suFrames, seen.maxSlots,
			seen.maxYoffP))
		if f then f:flush() end
	end
end
