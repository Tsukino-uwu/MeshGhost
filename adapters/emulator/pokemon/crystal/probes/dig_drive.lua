-- DRIVE ONE ESCAPE ROPE (or Dig) FROM A PREPARED SAVESTATE -- 2026-08-26
--
-- INPUT-DRIVING PROBE: loads a savestate and presses A twice. **Unload it before judging anything
-- else on screen** -- an input-driving probe left loaded becomes a suspect in every later report.
--
-- THE STATE IT DRIVES. The user prepared slot 9 on 2026-08-26: standing in a cave with the bag
-- already open on an Escape Rope, where **pressing A twice uses it**. That is what turns this
-- animation class from a request on the user's time into something this rig runs by itself -- the
-- same economics as the fly savestates, and `_template/probes.md` records why it is worth asking
-- for one before grinding live cycles. Note slot 9 previously held the cross-town Fly state; the
-- user overwrote it deliberately.
--
-- WHY ESCAPE ROPE IS EXPECTED TO ANSWER THE DIG QUESTION TOO. The decompilation points both items
-- at one shared routine (look at `EscapeRopeOrDig` in `engine/events/overworld.asm`), so the
-- hypothesis is that they play the same animation. This probe measures the Escape Rope; that Dig
-- matches it is a prediction until a Dig run says so, and the probe is named for the animation.
--
-- WHAT IT DOES, on a fixed countdown (endurance, not timing -- there is no window to hit):
--   1. waits 2s, loads MESHGHOST_DIG_SLOT (default 9),
--   2. waits 2s for the adapter to re-sync to the loaded world,
--   3. presses A, waits 1.5s, presses A again,
--   4. screenshots every 8 frames for the next ~14s into the adapter's logs/ folder.
--
-- The window is long on purpose: the departure spin is 32 engine ticks (~64 frames), the map
-- reload and its fade sit in the middle with nothing to see, and the arrival spin-flicker is
-- another 32 ticks on the far side. A short window would photograph one half and read as "the
-- other half does nothing".
--
-- THIS PROBE SUPPLIES THE EYES ONLY. The reading is `fly_probe.lua`'s -- the general "player and
-- ghost, one line, one frame" trace, which is read-only and run-length encodes `act` and `face`
-- for both characters. Load both. What to look for is in this file's tail comment.
--
-- LOADS ONCE, NOT ON EVERY RE-ATTACH. `phase` is a plain local, so a reload of this script starts
-- the countdown again from the top -- which is the intended way to run another iteration. It is
-- NOT driven by a global that survives a swap: `MESHGHOST_SQUARE_LOAD_STATE` is the standing
-- example of a probe global that outlives the probe and then loads a savestate under a session
-- that did not ask for one (`agent_docs/status.md`).

local SLOT = tonumber(_G.MESHGHOST_DIG_SLOT or "") or 9

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	-- The adapter's logs/ lives at the ADAPTER root, not beside this probe -- fly_drive's first run
	-- wrote 75 screenshots into probes/logs/, which does not exist, and the pcall swallowed every
	-- one of them.
	dir = dir:match("^(.*)/probes$") or dir
end
local stamp = os.date("%H%M%S")

local phase, n, shot = 0, 0, 0

local function say(s)
	pcall(function() console.log("dig_drive: " .. s) end)
end

say(string.format("loading slot %d in 2s, then A twice; screenshots to logs/", SLOT))

MESHGHOST_DEV_TICK = function()
	n = n + 1
	if phase == 0 and n >= 120 then
		phase, n = 1, 0
		local ok = pcall(function() savestate.loadslot(SLOT) end)
		say(ok and ("slot " .. SLOT .. " loaded") or ("slot " .. SLOT .. " FAILED to load"))
	elseif phase == 1 and n >= 120 then
		phase, n = 2, 0
		say("pressing A (1 of 2)")
	elseif phase == 2 then
		-- Two presses, 90 frames apart. Held for 3 frames each rather than 1: the game samples
		-- input once per its own loop, not once per video frame, and a single-frame press is the
		-- kind of thing that works nine times and silently misses the tenth.
		if n <= 3 then
			joypad.set({ A = true })
		end
		if n >= 90 and n <= 93 then
			joypad.set({ A = true })
			if n == 90 then
				say("pressing A (2 of 2)")
			end
		end
		if n % 8 == 0 and n <= 840 then
			shot = shot + 1
			pcall(function()
				client.screenshot(string.format("%s/logs/dig_%s_slot%d_%04d.png",
					dir, stamp, SLOT, n))
			end)
		end
		if n > 840 then
			phase, n = 3, 0
			say(string.format("done: %d screenshots taken. Unload this probe.", shot))
		end
	end
end

-- THE PREDICTION, written before the run so the log is read against it rather than interpreted
-- after the fact. Where to look: `.DigOut` / `.DigReturn` in `engine/events/overworld.asm` and
-- `StepFunction_DigTo` in `engine/overworld/map_objects.asm`. Hypotheses this run tests:
--
--   DEPARTURE  the player's action byte holds SPIN (4) in place, then the object is hidden --
--              no flicker and no vertical movement on the way out.
--   ARRIVAL    the map load is an ordinary door entry (so nothing on the wire marks it as Dig),
--              then the action byte alternates SPIN (4) / SPIN_FLICKER (5) -- the flicker, on
--              the arrival only. SPIN_FLICKER has never appeared in any capture this project
--              has taken, so this is the run that either produces action 5 or refutes it.
--
-- THE REASON TO MEASURE RATHER THAN BELIEVE THE ABOVE: Fly reads exactly as convincingly in the
-- source and turned out not to use the player's map object at all -- through an entire Fly the
-- player holds action 1, facing $FF and yoff 0, because `FlyToAnim` hides every character and runs
-- a cutscene sprite instead. Dig uses `applymovement PLAYER`, which Fly does not, so the two are
-- not the same shape -- but that is the prediction being tested, not a result.
--
-- ONE CLAIM IN THE ADAPTER'S OWN DOCS THIS RUN ALSO CHECKS: several places call `extras.yoff` "the
-- Fly, Dig and Teleport falls". Teleport does raise the sprite (`StepFunction_TeleportFrom`
-- feeds OBJECT_JUMP_HEIGHT through `Sine` into OBJECT_SPRITE_Y_OFFSET), but nothing on the Dig
-- path touches that byte. If `yoff` stays 0 across this whole run, "the Dig drop" is a phrase to
-- delete rather than a behaviour to implement.
