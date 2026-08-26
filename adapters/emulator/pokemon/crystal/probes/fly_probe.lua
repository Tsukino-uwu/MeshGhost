-- WHY A SPAWNED GHOST GOES INVISIBLE DURING A FLY LANDING -- the player and the ghost, one line,
-- one frame.
--
-- READ-ONLY DIAGNOSTIC. Writes nothing, spawns nothing, drives no input, changes nothing on
-- screen. Play normally; there is no window to hit and no timing to get right.
--
-- THE TWO CANDIDATES IT EXISTS TO SEPARATE. The user, 2026-08-26: *"fly looks really broken on
-- the ghosts, also the spawned ghost goes invisible when fly is used"*. Both of these are
-- supported by the engine's own source, they predict the same symptom, and only a measurement
-- taken on ONE frame can tell them apart:
--
--   (a) OUR yoff WRITE PUSHES IT OFF SCREEN. `UpdateObjectFrozen` calls
--       `CheckObjectCoveredByTextbox`, which adds OBJECT_SPRITE_Y_OFFSET to OBJECT_SPRITE_Y and,
--       if the sum does not fit the screen height, falls through to `SetFacing_Standing` --
--       OBJECT_FACING = STANDING ($FF), and the engine then draws nothing at all. The Fly fall
--       runs that byte to about -96 (`StepFunction_Skyfall` scales `Sine` by $60), and the
--       spawned tier started writing the peer's copy of it on 2026-08-26. If this is the cause,
--       the ghost's own `yoff` is large on the frames it disappears.
--   (b) THE GAME HID EVERY OBJECT ITSELF, and our byte is irrelevant. `UpdateAllObjectsFrozen`
--       runs only while `wStateFlags` has SPRITE_UPDATES_DISABLED set, and it walks all thirteen
--       structs. If the Fly sequence sets that bit, every object is on the frozen path for the
--       duration -- ghost included -- and this is pre-existing behaviour that has nothing to do
--       with this week's work. If this is the cause, `SU=1` is on for exactly the frames the
--       ghost is gone, and the ghost's `yoff` is 0 throughout.
--
-- The two are not exclusive; the log says which frames each covers, which is the point.
--
-- WHAT TO READ IN THE OUTPUT
--   `face=FF` on either character IS "the engine drew nothing this frame" -- that is what STANDING
--   means to `_UpdateSprites`, not a direction. So compare the P and G halves of one line:
--     * G face=FF while P face is a real facing  -> the ghost alone is being hidden.
--     * BOTH at FF                               -> the game hid everything (candidate b).
--     * G face=FF and G yoff large               -> candidate (a), stated outright.
--     * G f2 bit 0x20 set                        -> that object is FROZEN, so it is on the
--                                                   `UpdateObjectFrozen` path this frame.
--     * G f2 bit 0x40 set                        -> the engine's own OFF_SCREEN flag.
--
-- FIND THE SUBJECT BY WHAT IT IS, NEVER BY AN ADAPTER GLOBAL (probes.md, the parity probe): a
-- ghost is any struct past slot 0 that has a sprite and whose OBJECT_MAP_OBJECT_INDEX is $FF --
-- an object with no map-object entry behind it, which on a vanilla map is exactly what we spawned
-- and nothing else. That keeps this probe working across an adapter reload and means it cannot
-- fail in the same instant as the code it is measuring.
--
-- Constants from meshghost_crystal.lua: OBJECT_STRUCTS 0xD4D6 (vanilla V1.0), OBJECT_LENGTH 0x28,
-- 13 structs, F_SPRITE 0x00, F_MAP_OBJECT_INDEX 0x01, F_ACTION 0x0B, F_FACING 0x0D, F_SPRITE_Y
-- 0x18. OBJECT_FLAGS1 0x04, OBJECT_FLAGS2 0x05, OBJECT_SPRITE_Y_OFFSET 0x1A, the FROZEN (bit 5)
-- and OFF_SCREEN (bit 6) flags, wStateFlags $D0ED and SPRITE_UPDATES_DISABLED (bit 0) are from
-- the decompilation's own listings (constants/map_object_constants.asm, constants/ram_constants.asm,
-- pokecrystal.sym) and are cited in documentation.md.
--
-- Log beside this script, resolved from the script's own path -- never an absolute one, which
-- would be a personal path in a public repo.

-- THE ADAPTER'S OWN DOMAIN AND FLAT MAPPING, not "System Bus" -- and this probe's first draft got
-- it wrong, which is the only reason the mistake is written down here. On a GBC, "System Bus"
-- reads $D000-$DFFF through WHICHEVER WRAM BANK IS CURRENTLY SELECTED, so a bank-1 address read
-- that way is right only while bank 1 happens to be banked in. The first run reported
-- SPRITE_UPDATES_DISABLED set for 11,544 consecutive frames of ordinary standing-still play,
-- which is not a game state -- it is a probe reading someone else's bank. The "WRAM" domain
-- addresses the banks unconditionally: bank 0 is $C000-$CFFF -> 0x0000, bank 1 is $D000-$DFFF ->
-- 0x1000, which is what `flat()` below does and what meshghost_crystal.lua has always done.
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

-- WHICH IMAGE THE ENGINE ACTUALLY DREW for the player, not which field fed it (probes.md,
-- "Measure what is DRAWN, not the fields that feed it"). The player owns OAM entries 0-3 while it
-- is drawn at all, and the art is the tile id relative to the object's own OBJECT_SPRITE_TILE --
-- the same `(tile - base) & 0xFF` the adapter's own frame learner stores. This is here because
-- the second half of the report is about the PAINTED ghost's art, and the painted tier is
-- supposed to be reproducing exactly this number.
local function playerTile()
	local base = u8(OBJ + 0x02)
	local tile = memory.read_u8(2, "OAM") or 0
	return (tile - base) & 0xFF
end

-- Signed, the way the engine stores it: this byte is two's complement and the Fly fall is negative.
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
	-- BUFFERED, FLUSHED ON A TIMER. One flush per line is 63-83ms on this host
	-- (adapters/emulator/CLAUDE.md), which is four to five frames -- an instrument that costs
	-- that much changes the thing it is measuring.
	if f then f:setvbuf("full", 1 << 16) end
end

local frames, run, pending = 0, { key = nil, count = 0, first = 0 }, 0
-- COVERAGE, reported rather than assumed: an instrument says what it could not see.
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

-- EVERY OCCUPIED SLOT, NOT THE ONE I GUESSED WAS THE GHOST. The first draft filtered for
-- "sprite set and OBJECT_MAP_OBJECT_INDEX == $FF" on the reasoning that a spawned ghost has no
-- map-object entry behind it. That filter reported "G none spawned" for 12,583 of 12,600 frames
-- of a session that had a ghost on screen throughout, so the rule is simply wrong -- and it is
-- exactly the trap probes.md states outright: a filter applied before you look is a guess about
-- the answer, and a wrong guess still produces a complete-looking result. So this dumps all
-- thirteen structs and the reading happens afterwards, where it can be corrected.
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

	-- RUN-LENGTH, not one line per frame: the question is which frames each state covers, and a
	-- hundred identical lines hide that while a run length states it.
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

	-- A standing coverage line, so a log that saw nothing says so rather than looking like a Fly
	-- that produced nothing. An instrument reports its own coverage, not just its findings.
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
