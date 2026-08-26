-- DRIVE ONE LEDGE HOP FROM A PREPARED SAVESTATE -- 2026-08-26
--
-- INPUT-DRIVING PROBE: loads a savestate and holds Down. **Unload it before judging anything else
-- on screen** -- an input-driving probe left loaded becomes a suspect in every later report.
--
-- THE STATE IT DRIVES. The user re-prepared slot 9 on 2026-08-26: standing one tile above a ledge,
-- where **walking DOWN one tile hops it**. (Slot 9 held the Escape Rope state earlier the same
-- session, and the cross-town Fly state before that -- so a log from this probe is only meaningful
-- against the slot as it was at the time.)
--
-- WHAT IT DOES, on a fixed countdown (endurance, not timing -- there is no window to hit):
--   1. waits 2s, loads MESHGHOST_LEDGE_SLOT (default 9),
--   2. waits 2s for the adapter to re-sync to the loaded world,
--   3. holds Down for 40 frames -- long enough to commit to the step and let the hop start,
--      then releases so the landing is not immediately walked out of,
--   4. screenshots every 4 frames for the next ~6s.
--
-- FOUR FRAMES, NOT EIGHT. `fly_drive`/`dig_drive` shoot every 8 because a spin holds each pose for
-- 4 engine ticks. A hop is over in about 32 video frames TOTAL and its arc changes every tick, so
-- an 8-frame cadence would photograph four points of a sixteen-point curve.
--
-- THE READING IS `fly_probe.lua`'s, not this one's -- the read-only "player and ghost, one line,
-- one frame" trace, which run-length encodes `act`, `face` and `yoff` for both characters. Load
-- both. `yoff` is the field that matters here; see the tail comment.

local SLOT = tonumber(_G.MESHGHOST_LEDGE_SLOT or "") or 9

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	-- The adapter's logs/ lives at the ADAPTER root, not beside this probe.
	dir = dir:match("^(.*)/probes$") or dir
end
local stamp = os.date("%H%M%S")

local phase, n, shot = 0, 0, 0

local function say(s)
	pcall(function() console.log("ledge_drive: " .. s) end)
end

say(string.format("loading slot %d in 2s, then holding Down; screenshots to logs/", SLOT))

MESHGHOST_DEV_TICK = function()
	n = n + 1
	if phase == 0 and n >= 120 then
		phase, n = 1, 0
		local ok = pcall(function() savestate.loadslot(SLOT) end)
		say(ok and ("slot " .. SLOT .. " loaded") or ("slot " .. SLOT .. " FAILED to load"))
	elseif phase == 1 and n >= 120 then
		phase, n = 2, 0
		say("holding Down")
	elseif phase == 2 then
		if n <= 40 then
			joypad.set({ Down = true })
		end
		if n % 4 == 0 and n <= 360 then
			shot = shot + 1
			pcall(function()
				client.screenshot(string.format("%s/logs/ledge_%s_slot%d_%04d.png",
					dir, stamp, SLOT, n))
			end)
		end
		if n > 360 then
			phase, n = 3, 0
			say(string.format("done: %d screenshots taken. Unload this probe.", shot))
		end
	end
end

-- WHAT THE SOURCE SAYS THIS SHOULD PRODUCE, so the log is read against a prediction rather than
-- interpreted afterwards. `.TryJump` (engine/overworld/player_movement.asm) matches the tile's
-- collision high nybble against HI_NYBBLE_LEDGES and the facing against `.ledge_table`, plays
-- SFX_JUMP_OVER_LEDGE, and issues `STEP_LEDGE` -- which `.DoStep` turns into the `jump_step`
-- movement, i.e. `JumpStep` in engine/overworld/movement.asm. That routine writes:
--
--   OBJECT_ACTION      = OBJECT_ACTION_STEP (2)      -- the ORDINARY WALKING ACTION
--   OBJECT_WALKING     = STEP_WALK << 2 | dir        -- the ORDINARY WALKING GAIT (group 1, 2px)
--   OBJECT_JUMP_HEIGHT = 0
--   OBJECT_STEP_TYPE   = STEP_TYPE_PLAYER_JUMP (9)
--   and calls SpawnShadow
--
-- **NOTHING THE ADAPTER PUTS ON THE WIRE SAYS "JUMP".** `act` is 2, which is a walk; `gait` is the
-- normal group, which is a walk. The only field that distinguishes a hop from a step is
-- OBJECT_STEP_TYPE, and that is not sent. So a receiver cannot currently know a peer hopped -- it
-- can only observe the consequences, which are these two:
--
--   THE ARC, which SHOULD already work. `StepFunction_PlayerJump` runs `UpdateJumpPosition` twice,
--   once per tile, and that writes OBJECT_SPRITE_Y_OFFSET from a fixed sixteen-entry table:
--       -4, -6, -8, -10, -11, -12, -12, -12, -11, -10, -9, -8, -6, -4, 0, 0
--   `yoff` has been on the wire since 2026-08-26 and BOTH tiers apply it, so the up-and-down may
--   have come along for free. Watch P's `yoff` and the ghost's `y=` in the trace: if the player's
--   dips to -12 and the ghost's stays 0, the byte is being sent and dropped somewhere.
--
--   THE TWO TILES, which is the suspect. A hop crosses TWO tiles as one continuous motion, at
--   ordinary walking speed per tile (8 ticks, 2px). The ghost crosses tiles through `stepGhost`,
--   which asks the ENGINE to move it -- and a ledge is impassable in the hop direction, so
--   `CanObjectMoveInDirection` is the thing most likely to refuse the step and strand the spawned
--   ghost on the near side while the painted copy sails over. That is a prediction, not a result.
--
-- AND THE SHADOW, which a ghost cannot have today: `SpawnShadow` creates a SEPARATE map object,
-- exactly the shape that made `OBJECT_ACTION_EMOTE` wrong to write onto a ghost's own body. Noted
-- so it is recognised as a known gap rather than reported as a fault.
