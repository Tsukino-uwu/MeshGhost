# Unverified — Pseudoregalia's queue waiting on the user

**What this is.** [`VERIFIED.md`](VERIFIED.md) is the append-only record of what is *confirmed*.
This is its waiting room: things the agent believes work, has self-tested as far as it can, and
**the user has not seen yet**. It exists so work can continue while the user is away without
either losing track of what still needs checking or quietly drifting into calling it done.

**The rule it serves** (`../../agent_docs/testing.md`, `../../agent_docs/environment.md`): the agent
verifies the Go client/server with tools; **anything about a running game needs the user to watch
it**. A screenshot the agent took is not a substitute, and neither is a healthy log. *"nothing is
considered done/fixed until i actually confirm it as such."*

**How to use it.**

- The agent adds an item the moment it believes something works, with **what to look at** and
  **what correct looks like** — enough that the user can judge it without re-deriving anything.
- The user works down the list and answers each **confirm** or **decline**. Decline is a normal
  answer, not a failed handover.
- **On confirm:** move it to [`VERIFIED.md`](VERIFIED.md) with the date, and delete it here.
- **On decline:** it goes back to being work. Note what was actually seen — that is usually the
  most valuable line in the whole file.
- Nothing here is cited as established anywhere else while it sits here.

**Created 2026-08-27.** Pseudoregalia had no queue, and three files said that was fine because "an
adapter with nothing pending does not need an empty one" — while `../../agent_docs/status.md` was
carrying Pseudoregalia items nobody had watched. The premise was wrong, not the rule: the user's
call is that **every adapter carries this file**, and `preflight.ps1` now requires it. The entries
below were moved here from `status.md` rather than invented.

**This queue drains.** Confirmed items move to `VERIFIED.md` with the date and are deleted here;
declined ones go back to being work. An entry still here has not been confirmed. Sibling queues:
`../emulator/pokemon/crystal/UNVERIFIED.md`, `../emulator/pokemon/emerald/UNVERIFIED.md`,
`../tevi/UNVERIFIED.md`.

---

## This run — watch these first

**The READY entries below, newest first, at most ten.** Each says what to look at and what correct looks
like; answer each with a plain yes or no at the end of the run. Every entry in this file carries
**READY** (built, waits for your eyes), **OPEN** (not fixed, parked as work) or **DONE** (kept for its
mechanism; nothing to confirm) — the rule is [`../_template/UNVERIFIED.md`](../_template/UNVERIFIED.md), and `dev-scripts/preflight.ps1` fails an
entry without one.

- READY — **THE DRIVEN GHOST (dev rig, `ghost_drive.txt` `mode=track`, builds through `9c4e84ea373c`, 2026-09-08 22:5x - 2026-09-09 00:2x): a replay ghost driven by its clip's input track through the pawn's own input events and the engine's movement input, corrected by the recorded position. Your words across the evening, in order: *"it jumped, and then fell down into the floor"* -> *"yee it lands on the floor"* -> *"i saw it attack a few times"* -> *"now the input ghost has the same sword/outfit as me, and its doing attacks"* -> *"its not sitting, only idle/attacking"* -> *"now its walking around, but its not changing its facing"* -> *"its facing properly, and also still walking not gliding"* -> *"now it sat down"* -> *"okay now it was doing the chair glitch"*. What is still yours to say on the 1:1 bar, side by side with the mirrored ghost of the same clip: the route, the timing of each action, and the corrections you can see (the log counts them: ~1-2 per 10 s while walking, a spike on the clip's cling at its end).**
- OPEN — **A driven ghost's chair sit is the HURT variant** (2026-09-09 00:2x, your words: *"it also sits as if its hurt/low health"*): `CurrentHp` lives on the shared game instance and the ghost's reference to it is cut on purpose (`GHOST_DECOUPLE_SHARED_STATE`; re-attaching it would let the pawn's sit HEAL you). Candidate, unmeasured: a private object of that class on the driven ghost, the adapter's own "give the ghost its own instance" pattern.
- READY — **The overlays' viewport z-order is 0 now, not 1000** (a tester's report 2026-09-08: at 1000 the input display drew over the pause menu and in front of its mouse input; *"even 99 is already above everything actually in game"*); the indicator took it live through `rec_indicator.txt` and you confirmed *"the 0 UI thing worked"*; the two input panels take it from build `d4de634453e3` on, unwatched under the pause menu.
- OPEN — **D0, the input-node census (2026-09-08 22:28, `probes/probe_inputnodes/`, calls on a replay ghost steered by its own AIController): MEASURED, not confirmed -- Jump `_20` = press (`jumpButtonHeld?` false->true, `jumpType` 0->1 within 20 ms), `_21` = release; WallRide `_13` = press (`wallRideButtonHeld?` true), `_14` = release; Crouch consistent with the shipped `_16` down / `_15` up.** Attack (3 nodes), Power (3), Guard, LockOn and Look were UNREADABLE on this rig: a replay ghost's `moveState`/`actionState`/`animJumpType` are rewritten every tick by the clip's mirror, the 22 s loop seam swapped the pawn mid-run, and round two read nothing at all (the ghost most likely dormant past the far tier once the user walked off). Move was never called (its value cannot be passed from Lua). **Next rig: the D1 dev toggle in C++ -- a ghost with mechanisms 1-12 off and its tick kept on, where every node and a real Move vector can be fired and read cleanly.** The first run of the probe fired Jump, Jump and Crouch on the PLAYER: two UE4SS Lua wrappers for one object are never `==`, so `p ~= player_pawn` was true for the player's own pawn; fixed by address/name compare plus a per-tick refusal, and filed as a lesson.
- READY — **THE INPUT HISTORY'S GHOST HALF (build `274c9ad8117a`, both installs; ADR 0057): a replay ghost's inputs on the right, from the track recorded beside its clip, streamed by the core and applied on the frame the ghost's rendered state reaches each press. The user, 2026-09-08 22:0x-22:17, on their own 22 s recording: a screenshot of the panel filling beside the ghost, then *"yee it was sending in the input history before"*, *"yee its working"*, and after seven restarts *"yee it working every time now"*. Their word on the two things that make it 1:1 is still owed: the row changes on the SAME frame the ghost visibly jumps/attacks, and the rows read as what they pressed in that recording. One restart on the earlier build (22:07) showed a small empty box, *"a dark box, no rows"*, and did not recur across seven traced restarts; unexplained, kept here.** The `INPUTDISPLAY: <id> first edge applied` line in `UE4SS.log` (and `waiting` every ~2 s while nothing applies) is what to read if it ever recurs.
- READY — **The input track carries the CAMERA now (2026-09-08 evening build, ADR 0057's Stage 0): six axes on every edge, `cam_yaw` and `cam_pitch` last, from the camera manager's rotation; `source` reads `imc_keys+bound_axes+camrot`.** The 21:39 run (first build, the controller's `ControlRotation`) proved the mechanism and disproved the source: six axes, the tag, 856 edges -- and yaw at -90, pitch at 0 on every one through the user's full circle. Second build reads the camera manager instead, the read the recording indicator is placed by. **The 21:50 run, on that build: `camera rotation resolved` logged; 1,462 edges, all six-slot; yaw walked -180..180 (1,169 distinct values) and pitch -80..50 (the game's look clamp) while the user turned a full circle and looked up and down; 16 jump edges agreeing, none disagreeing. Yours to say: that run WAS the circle-and-look routine, and it stays here until you do.** What that run had to show, none of it on screen: `UE4SS.log` has `INPUTTRACK: camera rotation resolved (PlayerCameraManager.GetCameraRotation)`; and while you turn the camera a full circle standing still, the fifth `ax` value walks through 360 degrees of yaw and the sixth moves only when you look up or down. Which way is positive is recorded from the file, not assumed. Nothing reads these yet; they are for the driven ghost.
- READY — **THE INPUT TRACK WORKS on Pseudoregalia, every button and both sticks (the 13:55 file, `replay/inputs/in-20260908-135457.ndjson`, 1,107 edges, zero disagreements, no drops). Nothing on screen changes; what is yours to say is whether the read-back matches what you pressed. Entry below.** With `replay.inputs: true` and `record_on_launch: true` in the game-root config.json (set for this run): press a few things, then look for `replay/inputs/in-*.ndjson` beside the clip and for the `INPUTTRACK:` line in `UE4SS.log` with `disagree=0`. Entry below.
- OPEN — **at 512 chasers some ghosts LOOKED stuck / not moving, and the game was at 5-7 fps** (the user, on screen, 2026-09-07, hedged in their own words: *"I think all ghosts stay spawned, but also looked like some got stuck/didn't move ? but obviusly hard to tell at 5-7fps as well with this many ghosts at the same time"*). **Not yet a defect** — there is a confound in the rig I set up and it has to be removed first. I ran that test at 100ms chaser spacing to make the pack fill in a minute instead of 8.5, and 100ms is SHORTER than the game's own frame interval at 5-7 fps (140-200ms). At ~6 fps, 52s of history holds ~310 samples for 512 chasers, so consecutive chasers land on the same sample and render at identical positions — which would look exactly like this. **What to run instead:** a count that keeps the framerate judgeable with spacing wider than a frame (~120 chasers at 500ms was the offer). If it survives that, it is real and worth chasing; if it does not, it was the spacing. Go side of the same run is clean and recorded — `../../agent_docs/verified.md`, 2026-09-07.
- READY — **THE INPUT HISTORY DISPLAY, player half (build `0e1c5dc9f3d9`, both installs; counts in hundredths of a second by default, `unit` cs/ms/frames and `count_side` left/right in the config, the cap four digits for ms): the panel on the left with counts, single-glyph arrows and a letter per action, and the screen-space indicator in the corner -- both seen in your 15:16 screenshot; a middle dot marks a neutral row in this build (the earlier `b7` was a mangled escape). What is yours to say: the rows split where your input changed, the arrows match, the letters match -- and why `G` (guard) sits on so many rows.** Entry below.
- OPEN — **a session with the input-display PROTOTYPE loaded ended in "Abort signal received" (14:41:52), 63 s after a reload, with the Archipelago mod also live. UNATTRIBUTED**: nothing logged an error; the probe had one unguarded game-thread callback (since guarded, poll halved) and it is the same signature as the 2026-09-06 probe aborts. The shipped DLL in that session was the input-track build with the track OFF. Archipelago is disabled in the main install at your ask. If the C++ display's session aborts the same way, the display is the suspect; if not, the prototype was.
- READY — **the recording indicator is a SCREEN-SPACE widget now (build `0e1c5dc9f3d9`): built once per recording, handles valid on the tick they were made, removed on stop -- in your 15:16 screenshot at 0:00. Yours to say: it looks like the ShareX-checked prototype and keeps its time across a zone change.**
- DONE (mechanism confirmed on the prototype) — **the recording indicator is drawn BEHIND world geometry and objects**: it disappears where something is between it and the camera, instead of sitting on top of everything the way a HUD element does (the user, 2026-09-06). Low priority, by their call.
- OPEN — **the recording indicator LEAVES its intended position during a move or ability that changes the player's speed or field of view**: it drifts from the corner it is pinned to and comes back afterwards (the user, 2026-09-06). Which moves, and whether it tracks speed or FOV, is not yet named.
- OPEN, NO PRIORITY — **the Linux tester's clip still carries six ~60 ms freezes the Windows clip has none of, and they are NOT Nagle** (measured 2026-09-07, after `TCP_NODELAY` closed the real fault — `VERIFIED.md`): a ~31 ms sample with zero movement then a ~60 ms sample carrying ~6.9 units, roughly one a second across the clip. No fixed floor and the character MOVES across the gap, so it is production, not delivery — a periodic hitch on their machine or in Proton, most likely. The tester did not notice it. If it is ever chased: a clip cannot localise it further, so it needs their frame times.
- OPEN, NO PRIORITY (the user's call) — **one single afterimage appears whenever a looping recording restarts, and probably whenever any ghost spawns** (the user, on screen, 2026-09-06). Not severe and not queued for a fix; logged so it is on the record. A loop seam IS a despawn plus a respawn by design (`replayPlayer.seam`), which is why the two cases are likely one.
- DONE — the stuck blue sword/body outline: CAUSE FOUND AND FIX CONFIRMED 2026-09-05 (`VERIFIED.md`): the afterimage sweep stripped the PLAYER's body through `BP_AfterImage_C.cachedMesh`; both strips now check ownership. The outline on the player BEHIND a ghost stays, by the user's call (option 3; stencil is ignored by the outline pass).
- OPEN, HIGH — **v1.1.7 CRASHES: a NEW fault site, exe+0x36CCF98, inside the engine's skeletal-mesh reset chain; three dumps on the user's machine 20:56/21:01/21:02 (an Archipelago connect, a zone change) plus a tester's, none at that site in ~90 dumps since 2026-08-12.** The tester's dump has our frames: `game_thread_tick` (weapon-model apply) -> `call_set_skeletal_mesh_asset` -> ProcessEvent -> the fault, with a chaser's `weapon_mesh` after a swap. The user's two have NO frame of ours: engine tick -> Blueprint -> a hooked native -> the same chain, i.e. state v1.1.7 left behind. v1.1.7 ran a FULL SetSkeletalMeshAsset of the stock sword onto every ghost's hand at spawn plus two raw property writes. Hardened build `A81C7D23` deployed 21:03 (same-asset = no call; setter only; resolver refuses destroyed assets; Skeleton must be alive) -- UNPROVEN; the crash watcher is armed. Entry below.
- DONE — WEAPON MODEL SYNC, built 2026-09-05 (v1.1.7): a peer's sword asset is sent as `weapon_mesh` and applied to their ghost's hand `WeaponMesh` (and a live flyer) through the outfit recipe. **CONFIRMED on screen 2026-09-06** (`VERIFIED.md`) once the entry below fixed what was actually blocking it -- the sync waited on a flag this build does not reflect. Both sides need v1.1.7. Before this, both players confirmed a modded sword showed as stock -- `documentation.md`, `ideas.md`.
- DONE — a tester's EXCEPTION_ACCESS_VIOLATION (2026-09-05) was NOT ours: their `UE4SS.log` showed the old UE4SS 2.5 layout (`Win64\Mods\`), no C++ mod started from `enabled.txt`, not one `[MeshGhostPseudo]` line -- our folder sat unread beside an older Archipelago install's runtime. A clean game reinstall plus both drags fixed it. Lesson for the README: an old UE4SS must be let go of, or nothing of ours loads.
- OPEN, NO PRIORITY — the NAMETAG sometimes sits too LOW / in the wrong place over a ghost (user, 2026-09-05, two-machine session); rare and inconsistent, no reproduction. If seen again: which ghost, what it was doing (crouch? slide? outfit swap? just spawned?), and whether it recovered on its own -- the tag rewrites its transform every tick (`by-lesson.md`, 2026-09-05), so a low tag is a wrong INPUT to that rewrite (the pawn's capsule half-height or the mesh offset), not a stale one.
- OPEN, NO PRIORITY — seen ONCE 2026-09-05 in a two-machine session: a remote peer's ghost flashed red (took damage), vanished on their reset-to-save, and came back GLITCHED (body gone but for scattered fragments, sword and blob shadow intact); the watcher's own reset-to-save cleared it; the peer saw nothing; not reproduced. Entry below.
- OPEN — small cousin: a player afterimage born ON a ghost can be attributed to the ghost by birth proximity and lose its own silhouette (`copyActor` is null on its first tick); harmless to the player since the ownership fix, unwatched.
- READY — TEVI: meshghost.exe + config.json now live in the GAME ROOT (beside TEVI.exe) and the plugin looks nowhere else; deployed to both installs 2026-09-05, unwatched (Pseudoregalia's half CONFIRMED, `VERIFIED.md`).
- READY — the ghost sword mirror no longer rewrites `WeaponMesh.bVisible` (and logs it) every tick per ghost: the read goes through the bitfield mask now; nothing should LOOK different, the log should show one WEAPONMESH line per ghost per change (built 2026-09-05, deploys at the next game exit)
- READY — **the FPS drop that outlives a ghost is the ghost's `BP_PlayerCam_C` camera rig: the pawn's own camera actor, never destroyed with the pawn, spring arm still ticking.** Found 2026-09-06 with a full object census; 68 orphans cost ~1.7 ms a frame uncapped, a level reload was the only thing reclaiming them. FIXED in the DLL (destroyed with the ghost + an orphan sweep), unwatched. The ~2 Niagara per despawn from 2026-09-04 did NOT show in the census (collected within 90s); that item is folded in here. Next: 150 fake peers, a few spawn/despawn rounds, baseline before vs after (user's test).
- DONE — the frozen-player state (item popup, pause menu): the CHASER half is fixed and CONFIRMED 2026-09-05 (`VERIFIED.md`); a recording still shows the run-fall on the spot, by the user's call (chaser only)
- READY — a non-ASCII display name should render as itself now, not mojibake (2026-09-04)
- READY — the peer-JSON readers were rescoped and 42 call sites changed shape; nothing should look different, which is why it needs a look (2026-09-04)
- READY — no state is sent from the title screen, so a recording starts at your first real frame; built and deployed 2026-09-04, unwatched — **set up for the 2026-09-04 run**
- READY — the SFX fix now ships in the DLL (the ghost stole the player's audio attenuation listener; CAUSE AND FIX CONFIRMED in Lua 2026-09-04, `VERIFIED.md`) -- the C++ version rewrites the call instead of answering it, built and deployed, UNWATCHED
- READY — a chaser set to 3s should now LOOK 3s behind, not 3.45s, and a split time should match the ghost you can see (ADR 0049), unwatched — **not the 2026-09-04 run: the chaser is at 60s there to give the audio A/B a ghost-free first minute**
- READY — `"autostart": false` in config.json now stops the mod starting a client (the old MESHGHOST_NO_AUTOSTART still counts), built and deployed 2026-09-03, unwatched
- MEASURED 2026-09-02 (logs) — the launcher forgets a child the port walk has moved off: cross-wire provoked on one port base, recovered; then both copies walked normally from 7778
- Pending — three input bounds from the 2026-09-02 adversarial review, built and deployed, unwatched
- Pending — every peer-named asset now resolves through the CATALOG GATE, built and unwatched (2026-09-01)
- Pending — the WALL-KICK mirror v1: watched once, hedged, with two stated limits (2026-09-01)
- The ghost's FACING is now interpolated, and nobody has watched it (2026-08-30)
- Pending — the PERFORMANCE WORK: what it bought, what it broke, and what is unwatched (2026-08-30)
- The RENDER SWEEP on netsim: the interp ladder, the rate axis, and what was NOT taken (2026-08-30)
- Pending — `bb`, `hw` and `hew` got the one-shot counter treatment and were never watched (2026-08-29)
- BUILT 2026-08-29, NEVER WATCHED — the ghost's light is now held at 0
- Pending — the bridge port walk's SECOND-INSTANCE case is still unwatched (2026-08-27)
- Pending — ghost collision turned OFF again (2026-08-27), and it may cost the cling-gem VFX
- OPEN — three faults with no entry of their own: the sword's MID-AIR SNAP, the BLACK FLASH on spawn, and two unattributed crashes (from `status.md`, 2026-09-02; `curve catmull-rom` has its own entry below)

## [READY] the input track's capture is built and deployed, UNWATCHED (2026-09-08 midday)

**First run, 13:14-13:16, the user's own launch (build `11ee35453e62`): the plumbing worked and the
buttons did not.** `replay.inputs` reached the mod (`config replay.inputs=true`), the label table went
out after the hello, the layout check passed exactly as the header says (`Actor@0 Action@8
ReturnValue@16 size 32`), frames counted at ~140 a second, and 155 edges were sent -- **every one of
them axis-only: the jump check never fired.** The census had proved `GetBoundActionValue` CALLABLE,
not that it answers for every action, and it does not: a bound action value exists only for the
actions the Blueprint binds by VALUE, and this pawn's own function list (the census file) shows which
-- `setInputVariables` and `poleTick` read one, i.e. the sticks; every button is event-bound
(`InpActEvt_*`) and reads zero. Two other findings from the same run: the core in the game root was
the 2026-09-07 build, older than the input track, so no file was written (both game roots now carry
`57a22f8b8cd0`); and the `INPUTTRACK:` line printed at the bridge line's cadence, ~1.5 a second.

**Fourth run, 13:54-13:56, build `27a091d57453`, the user pressing "everything a bit on gamepad":
COMPLETE.** Every one of the 11 labels and all four axes appear in `in-20260908-135457.ndjson`:
35 jumps, 33 attacks, 19 crouches, 16 clings (up to 402 frames), 14 throws, 19 guards, 25
interact/power pairs, 30 lock-ons, 5 quick-maps, 10 perspective toggles; `look_x`/`look_y` both
reach full deflection; 1,107 edges, 7,698 frames, no drops; `jump_check agree=70 disagree=0`; the
core's launch line names the track. The read-back matching what was pressed is the user's call
and is the only thing left; `record_on_launch` is back to `false` in the game-root config,
`inputs` left `true`.

**Third run, 13:45-13:47, build `29c2c91fae0f`: CORRECT.** The applied table gave 21 keys for 11
actions from 35 applied mappings; `jump_check agree=30 disagree=0` across the run; 565 edges, no
drops, 6,455 frames. Read back: 15 jumps (11-53 frames each), 7 attacks with no jump bit on any,
8 crouches including the 278-frame hold, 3 clings, 3 guards, 3 lock-ons, a throw, the square on the
move axes -- and interact and power ALWAYS together, 4 for 4, which is the game's own table (both
on E and the right face button; the census's MAP lines). **One gap: `look_x/look_y` stayed 0 for a
whole run of looking around** -- `IA_Look` is not value-bound either (its handlers are
`InpActEvt_IA_Look_*` events), so its bound value is zero like the buttons' were.

**Fourth build (`27a091d57453`, 13:50):** look reads `APlayerController::GetInputVectorKeyState(FKey)` summed
over the keys the applied table binds to `IA_Look` (`Mouse2D`, `Gamepad_Right2D`): the stick's
position plus the mouse's per-frame delta, on one pair of axes; layout checked (a 24-byte FVector
back) before the first call, refused with a WARNING otherwise. Move stays on the bound value, which
the third run proved. Also the core (`4c8980ec09f0`, both game roots) now logs `input track to ...`
on the launch path, where the first runs said nothing about it. UNWATCHED: expect
`GetInputVectorKeyState resolved (Key@0 size 24, ReturnValue@24 size 24, ..)`, `.. 2 look key(s) ..`,
and non-zero `look_x/look_y` in the next file.

**Second run, 13:35-13:36, build `bc30c56f9baf`: the track WORKS, with one wrong bit.** Both reads
resolved (`IsInputKeyDown` Key@0 size 24, KeyName@0 size 8; a key table of 23 keys for 11 actions),
the core wrote `replay/inputs/in-20260908-133553.ndjson` beside the clip with the same
`recording_id`, 281 edges, and read back it is the sequence: three jumps held 31/31/48 frames,
crouch held 309 frames, a throw, a cling with the stick pinned, jumps mid-square with the stick
values on them. **The one fault: every gamepad attack also raised the jump bit** -- `jump_check`
agree=19 disagree=9 for exactly 9 attacks -- because the table merged EVERY loaded mapping context,
and this game keeps two: `IMC_Default` (the player's CURRENT bindings, rewritten by rebinding) and
`IMC_Reference` (the factory defaults, never applied), and the factory default for that face button
is Jump while the user's binding is Attack. Same for R (factory QuickMap, user Throw), X/Z.

**Third build (`29c2c91fae0f`):** the key table is read from the engine's own APPLIED merged table,
`PlayerInput.EnhancedActionMappings` (a reflected array the census listed), never from the loaded
contexts -- so it is what the game acts on, it follows a rebind the moment the engine does, and the
periodic `FindAllOf` is gone. Expect `key table: N distinct key(s) for 11 actions from M applied
mapping(s)` and `disagree=0` across a run with attacks in it. UNWATCHED.

**Second build (`bc30c56f9baf`, 13:26):** buttons through `IsInputKeyDown(FKey)` per key the game's mapping
contexts bind to each action, the census's proven path, folded into the action bits (a key bound to
two of our actions sets both -- the game's own table has several); sticks unchanged through the bound
value; the log line every tenth bridge line; `source` is now `imc_keys+bound_axes`. Expect two new
lines at the first gameplay frame -- `IsInputKeyDown resolved (Key@.. size 24, KeyName@0 size 8, ..)`
and `key table: N distinct key(s) for 11 actions from 2 mapping context(s)` (the census saw 35
mappings per context, ~28 keys for these 11 actions).

**What it is.** The adapter half of ADR 0056: once per engine frame the mod reads the game's own
merged Enhanced Input value for 11 actions and the two sticks on the local pawn, and sends every
CHANGE to the core as an `input_sample` edge; the core writes them as a second file in
`replay/inputs/`, correlated to the clip by `recording_id`. Source chosen by the census entry below
this one. `FLAGS.md`: `INPUT_TRACK_CAPTURE` / `INPUT_TRACK_AXES`, runtime gate `replay.inputs`.

**What to look at, in order.**

1. `UE4SS.log`, at the first gameplay frame: `INPUTTRACK: GetBoundActionValue resolved (Actor@..
   Action@.. ReturnValue@.. size 32, ..)` — the layout check passed. A `WARNING: INPUTTRACK refused`
   line instead means the reflected function or its return size is not what UE 5.1's header says,
   and the feature has switched itself off; nothing else will appear.
2. Every ~5 s beside the bridge stats: `INPUTTRACK: frames=N edges_sent=N batches=N jump_check
   agree=A disagree=D`. **`D` must stay 0 while `A` climbs with your jumps.** A non-zero `D` means
   the value bytes are misread on this build and the fallback (`IsInputKeyDown` per mapped key,
   census-proven) is the next build. `edges_sent` should move when you press things and stop when
   you stand still.
3. `meshghost.log` in the game root: the recording start line should name BOTH files (the clip and
   the input track); any `input` reject line is a shape mismatch between the two sides.
4. `replay/inputs/in-<stamp>.ndjson` beside the clip after you quit (or `inlast-` after the save-last
   key): a header line with `"labels":["jump","attack",...]`, then one line per edge. A short
   scripted check I can read back: **stand still 3 s, jump 3 times, attack 3 times, hold crouch 2 s,
   walk in a small square, look around, stand still 3 s** — the file should show 3 jump edge pairs
   (bit 1 on/off), 3 attack pairs (bit 2), one crouch pair (bit 4) ~2 s apart, `move_x/y` moving
   during the square and `look_x/y` during the look, and nothing during the stills.

**What correct looks like** for the user: nothing on screen changes at all. This feature draws
nothing and touches no actor; if anything looks different, that IS the report.

**Cost:** 13 reflected calls a frame when `replay.inputs` is on, in the `input_read` perf slot;
nothing when it is off. Unmeasured.

**Not done in this build**, deliberately: `record_on_launch` is set `true` in the game-root config
only for this first run and goes back to `false` after; the `source` tag is
`enhanced_input_bound_value`; the emulator and TEVI adapters send nothing.

## [DONE] INPUT API CENSUS -- which input read works on this build, measured (2026-09-08)

**Measured by the agent, not confirmed on screen by the user, and nothing here is a visual claim**: it is
which reflected API answers, and which pawn field moves for which button. The probe is
`probes/probe_inputcensus/` (two stages through the scratch slot, 12:04-12:13, the user at keyboard then
gamepad, holding each input ~3 s); the raw census files stay in the install's scratch folder and are NOT
committed (a full class-schema dump is expression, `CLAUDE.md`). The decision it feeds is the C++ half of
ADR 0056, the input track.

**The verdict, three sources, in the order the C++ should reach for them:**

1. **E -- Enhanced Input's merged action value, `UEnhancedInputLibrary::GetBoundActionValue(pawn, IA_*)`:
   CALLABLE and SAFE** (a reflected BlueprintPure static on the library's default object, two object
   parameters; ~55,000 calls over 4 minutes, no crash, no Lua error). **Its VALUE is unreadable from Lua**:
   the returned `FInputActionValue` came back as an EMPTY table, because that struct has no reflected
   fields, so Lua cannot see `Value`/`ValueType`. C++ can: the return is a fixed-layout struct whose size
   the reflected `ReturnValue` property reports, and the C++ step reads it from the ProcessEvent buffer
   and asserts the size. **So E is proven callable, NOT proven correct** -- its first C++ read needs one
   live check against the pawn fields below. Also reflected on this build and untried:
   `EnhancedPlayerInput.ActionInstanceData` (a `MapProperty`, action -> instance), which the current
   engine API page does not list at all.
2. **A -- `APlayerController::IsInputKeyDown(FKey)` / `GetInputAnalogKeyState(FKey)` with an FKey built
   from a Lua table `{KeyName = FName("SpaceBar")}`: WORKS END TO END.** 118,000 calls, every mapped key
   answered, gamepad buttons, both sticks, both triggers, the mouse and WASD all seen going down and up
   in step with the pawn. `GetInputVectorKeyState(FKey)` exists for the 2D keys (`Gamepad_Left2D`,
   `Gamepad_Right2D`, `Mouse2D`), untried; the analog read on a 2D key yields one component. Every one
   of these is `native,pure,callable` on the controller. Folded through the live mapping contexts this
   is device-agnostic too, and it is the fallback if E's value read disagrees.
3. **C -- the pawn's own Blueprint fields: PARTIAL, as predicted.** `jumpButtonHeld?` <-> IA_Jump (24 of
   24 presses), `wallRideButtonHeld?` <-> IA_WallRide, `inputVectorWorld` / `moveInputAmount` /
   `hasMovementInput?` and the engine's `ControlInputVector` / `LastControlInputVector` <-> IA_Move,
   `bIsCrouched` <-> IA_Crouch, `weaponEquipped?` <-> IA_Throw. Attack shows only downstream
   (`saveAttack?`, `attackComboPosition`, `actionState`), and NOTHING on the pawn moves for IA_Look,
   IA_Interact, IA_Guard (only `obtainedSlideJump` toggled with it, 15 times -- recorded, not
   interpreted), IA_LockOn, IA_Power, IA_Pause. B (`UPlayerInput`'s key map) is confirmed unreflected.

**The vocabulary, from the game itself.** 15 `InputAction` assets under `/Game/ThirdPerson/Input/Actions/`:
Attack, Crouch, Guard, Interact, Jump, LockOn, Look (Axis2D), MenuAdvance, Move (Axis2D), Pause,
PerspectiveToggle, Power, QuickMap, Throw, WallRide. The pawn binds 13 of them through 23 `InpActEvt_IA_*`
Blueprint events (Pause and MenuAdvance are not the pawn's). Two mapping contexts, `IMC_Default` and
`IMC_Reference`, 35 mappings each; the legacy `InputSettings` action/axis lists are both empty. Keys as
loaded: Jump = SpaceBar, Gamepad_FaceButton_Bottom AND Gamepad_FaceButton_Left; Attack = LeftMouseButton,
Gamepad_FaceButton_Left; Crouch = Q, Gamepad_LeftTriggerAxis; WallRide = LeftShift, Z,
Gamepad_RightTriggerAxis; Throw = X, R, Gamepad_LeftShoulder; Guard = LeftControl, Gamepad_FaceButton_Top;
Interact = E, Gamepad_FaceButton_Right; LockOn = RightMouseButton, Gamepad_RightShoulder; Power = F,
Gamepad_FaceButton_Right; QuickMap = Tab, R, Gamepad_DPad_Up; PerspectiveToggle = Y,
Gamepad_RightThumbstick; Pause = Escape, Gamepad_Special_Right; Move = WASD, Gamepad_Left2D; Look =
Mouse2D, Gamepad_Right2D. Several keys map to two actions; that is the game's table, not a finding.

**Cost of the instrument**: 3-4.8 ms per sample at 20 Hz on the game thread with 110 bools, 15 E calls
and 32 A calls per sample -- fine for a census, nothing to ship. **What it could not see**: a one-frame
press between 50 ms samples (the protocol held everything); SpaceBar and LeftMouseButton never went
down during stage 2 (the keyboard jump/attack fell in stage 1, before path A existed), so A is proven
for them only by the other 30 keys; the pause menu was not exercised on the record.

## [DONE] Did the 512-chaser pack leave anything behind? No -- measured 2026-09-08

The user's question after the pack was switched off mid-session (config `chaser.enabled` false, then the
core killed so the mod respawned it): *"did the leak/leave anything left over?"* Two `FindAllOf` counts
and then a flag read, from the scratch slot, with three looping clips as the only ghosts:

| when | `BP_PlayerGoatMain_C` | `BP_PlayerCam_C` |
| --- | --- | --- |
| 12:09:27, 3 min after the kill | 24 | 24 |
| 12:12:45 | 34 | 34 |
| 12:13:28, with `bActorIsBeingDestroyed` read per object | **4 alive**, 19 dying | **4 alive**, 19 dying |

Four alive is exactly the player plus three replay ghosts. Everything above it carries the destroy
flag: pawns AND their camera rigs the looping clips despawn at every seam, sitting in the pending-kill
state until the engine's periodic purge collects them -- which is why a bare count rose 24 -> 34 and
then fell to 23. **A count of a class is not a count of leftovers; read the flag** (the 2026-09-06
census lesson, sharpened). Nothing from the chaser pack survived, and the rigs die with their pawns,
which is the 2026-09-06 camera-rig fix doing its job on the seam path.

## [OPEN] a single afterimage on a loop restart, and probably on any ghost spawn (the user, 2026-09-06)

**What was seen.** The user, watching their own looping recordings: *"1 single after image is shown
whenever a recording is looped, and probly whenever a ghost is spawned"*. Their call on severity:
*"i don't really consider it a severe bug or anything that needs fixing. but just so its noted
somewhere"* -- so this is a record, not a queued task.

**Why the two cases are probably one.** A replay's loop seam is not a rewind: the core DESPAWNS the
ghost and respawns it, on purpose, so the jump back to the start reads as a cut rather than a glide
(`replayPlayer.seam`; ADR 0047, and the chaser does the same on a live gap). So "on every loop" and
"on every spawn" are the same moment, and a fix for one is a fix for both.

**Not investigated.** Nobody has looked at whether the afterimage is spawned BY the adapter's
afterimage mirror on the ghost's first tick, or by the game's own trail logic reacting to a pawn
appearing with a position that jumped. Those are distinguishable: the mirror is ours and logs, the
game's own is not. `probe_outline/` and the afterimage entries in `VERIFIED.md` are where the trail
mechanism is written down.

**If it is ever picked up:** ask the user first which state it is visible in (`agent_docs/pitfalls/`
records that naming a game state from code reasoning has produced a false regression here before),
and remember that the ghost-spawn path already does several things at once -- the light kill, the
outfit apply, the emitter switch-off -- any of which lands on the same tick.

## [READY] the input history display, player half, in C++, UNWATCHED (2026-09-08 late afternoon)

**The user's design, all of it recorded because it shapes the ghost half too:** a fighting-game-
style input history -- each row is what was held and for how many frames, newest on top -- the
PLAYER's on the left, a replay GHOST's on the right fed by the input track recorded beside its
clip, each with its own on/off in the client config, the player's showable with no recording
running, a toggle for the translucent background (on by default), rows and text size as options,
and each display's side changeable (defaults player left, ghost right; the ghost takes the left
when the player's is off). The Lua prototype (`probes/probe_inputdisplay/`) was judged *"it works"*
with two asks folded in: the diagnostic text gone, the background a toggle. One report against it:
sideways directions did not all show -- it read raw keys and the stick's vector; the C++ reads the
game's merged move value, which the track file already showed reaching both extremes.

**What shipped (build `1598e915c39a`, `INPUT_HISTORY_DISPLAY`):** the player half. Config section
`input_display` (`docs/config.md`; shipped off, pinned by the shipped-config test). The panel is a
UMG Border + TextBlock like the indicator, pinned in the root set while shown, rebuilt after a
transition, placed left (`x=200 y=300` at 1920x1080, the prototype's) or right (from the panel's
laid-out width), rows `JACWTGILPMV` letters after the frame count and arrows, text rewritten on a
row change and every 4th frame while a state holds. The read is the input track's own, run when
either consumer wants it.

**What to look at:** with `player` and `always` true the panel is there in gameplay with no
recording. Hold things, walk diagonally, press two buttons together: rows should split exactly
where your input changed, all eight directions should appear as arrows, letters should match the
action (J A C W T G I L P M V). Say if it costs frames (`perf_report.txt` puts the read in
`input_read`). The ghost half is next and needs the core.

## [READY] the recording indicator is a SCREEN-SPACE widget now: the C++ port of the confirmed prototype, UNWATCHED (2026-09-08)

**Both 2026-09-06 complaints are answered by the mechanism, and the user confirmed it on the Lua
prototype** (`VERIFIED.md`, 2026-09-08: stays drawn behind geometry, does not move with the field of
view, survives reset/zone/menu, pixel-aligned by ShareX). **The C++ port shipped in build `7b0fc8535823`
under `REC_INDICATOR_SCREEN_SPACE` (`true`; `false` is the whole old path, kept as the revert)**, both
installs, deployed at the game's next exit. Same calls as the prototype with the real recording
state: built when a recording starts, removed when it stops, pinned in the root set while shown,
rebuilt after a level transition, the box auto-sized to the digits, the square sized to the box's
laid-out height, re-placed when the viewport size or the digit count changes, colours from
config.json's `indicator_color`/`indicator_timer_color` as before. Tuning: `rec_indicator.txt`'s
`hud_x hud_y hud_size hud_gap hud_text hud_pad hud_z` (any change rebuilds the pair).

**What to look at:** start a recording. The pair should look exactly like the prototype did at
14:30 (the ShareX-checked one), read the real elapsed time from the core's start stamp (no reset to
0:00 on a zone change), and disappear when recording stops. `UE4SS.log` says
`RECINDICATOR: screen-space widgets built (...)` once per start and `removed` once per stop; a
`WARNING: HUD indicator:` line names any call that did not resolve on this build.

## [DONE] the recording indicator: drawn behind the world, and it moves when speed or FOV changes (the user, 2026-09-06) -- answered above

**Two separate reports, both from the user's own play, logged here so neither is lost.** The indicator
itself is CONFIRMED working (`VERIFIED.md`, 2026-09-05: the shapes pixel-aligned, and the same again
from the baked defaults with no tuning file). These are defects in where and over what it draws.

1. **Behind world geometry and objects (LOW priority, the user's call).** The indicator vanishes where
   something in the level is between it and the camera, rather than drawing over everything the way a
   HUD element does. Whatever it is drawn WITH is taking part in depth testing.
2. **It leaves its intended position during a move or ability that changes the player's SPEED or FOV.**
   It drifts off the corner it is pinned to while such a move is happening and returns afterwards.

**Lead, 2026-09-08 (from a tester's MIT mod, `documentation.md`, "What a tester's MIT-licensed mod
showed").** Both complaints are properties of a WORLD-space text component. A screen-space UMG widget
built at runtime (`UserWidget` + `WidgetTree` + `TextBlock`, `AddToViewport`) is composited over the
scene and pinned to the viewport, and that mod draws its readout that way in this game today. Unbuilt;
whether the indicator should move to it is the user's call, since it changes what they see.

**What is NOT established.** Which specific moves do it (the ultra hop, the slide, the charged attack
and the wall ride all change speed and/or FOV, and none has been named); whether the trigger is the
speed change, the FOV change, or a camera transform the indicator's placement reads; and whether the
two reports share one cause -- a placement computed in a space that is not the viewport's would
explain both. **Ask the user which move to reproduce it on before probing anything**: naming a move
from the code is the mistake `../../agent_docs/pitfalls/` records twice.

**Where the code is.** The indicator's placement and its live-tunable numbers are in `Plugin.cpp`
beside the nametag's (both rewrite their transform every tick, which is the only reason either
appears at all -- see `documentation.md`); the tuning file is `rec_indicator.txt` (`FLAGS.md`).

## [OPEN] (no priority) a remote ghost came back GLITCHED after its peer's reset-to-save -- seen once, 2026-09-05, not reproduced

**What was seen (the user, watching a real second player over the internet, v1.1.6 DLL).** While testing
whether damage shows on a ghost: the peer's ghost flashed red (the hit), then disappeared -- the peer had
done a reset to last save -- then reappeared in a broken state: the body mesh gone except for a few
floating fragments, the sword floating upright at full size, the blob shadow drawn normally underneath
(screenshot in the session, not saved). It stayed that way; the user's OWN reset to last save cleared it
and the ghost has looked normal since, outfit swaps included. The peer saw nothing wrong on their side,
and could not reproduce it by taking damage, changing outfits or resetting again.

**What is and is not known.** Only that the sequence was hit -> peer's reset-to-save -> despawn ->
respawn glitched, once, and that a watcher-side world reset fixed it. Candidates named in the session,
none measured: something of the ghost's not released before the peer's save reload rebuilt the world
(the class of bug `release_all_ghosts` exists for), garbage collection of a pawn clone mid-rebuild, or
a costume mod on the peer's side (they run many mods, and one costume is known to them as odd). The
user's rule holds: anything the mod holds in the world must be dropped before a reset-to-save, a return
to the main menu or a zone transition, or it crashes or misdraws.

**Why it is logged at all.** The tester's ask: *"Log it as 'has occurred, no priority' ... just for
having any documentation when it comes back to it."* If it recurs, the first instrument is the watcher's
`UE4SS.log` around the peer's despawn/respawn (`releasing remote` / `spawned ghost for remote` lines) and
the sword-mirror and outfit lines for that ghost right after the respawn. No steps to reproduce exist.

## [OPEN] HIGH — v1.1.7 crashes at exe+0x36CCF98, the engine's skeletal-mesh reset chain (2026-09-05 night)

**The evidence, in order of arrival.**
- A tester (v1.1.7 DLL from the pre-release share) crashed "sometimes on a weapon swap while a replay
  played". Their dump: fault in the game exe at +0x36CCF98; `--stack` shows `main.dll` frames that our
  PDB names `Plugin::game_thread_tick` at the weapon-model apply, then
  `call_set_skeletal_mesh_asset` at its ProcessEvent call, then UE4SS, then the engine chain
  `+0x37BCDBC .. +0x35BF1C3 .. +0x36BDE40 .. +0x36CCF98`. Their client log: chaser on, two replays just
  finished, pause-menu events last. The two `main.dll` modules are told apart by image size: ours is
  the 0xD9000 one (`SizeOfImage` of our build), Archipelago's the 0x1CF000 one.
- The user (same DLL) crashed on an Archipelago connect (20:56) and on a zone change (21:02), plus one
  at 21:01. All three at the SAME site with the SAME chain, and **no frame of ours on any of the
  three stacks** (400-frame scan): engine tick hook -> ProcessEvent -> Blueprint VM three deep ->
  a hooked native (FFrame detour) -> the chain -> fault. So the game's own code trips over state
  the mod left behind, not a call in progress.
- `Saved\Crashes` history: 0x36CCF98 never occurred in ~90 dumps from 2026-08-12 to today 04:22;
  three times tonight. The 04:xx dumps are the old 0x1CD9A60 reset-hook crash, fixed that day.

**What v1.1.7 did that nothing before it did.** On every ghost spawn, and on every `weapon_mesh`
change, `SetSkeletalMeshAsset` on the ghost's hand `WeaponMesh` (and a live flyer) -- a FULL mesh
reset even when the target was the stock sword the hand already held -- followed by two raw writes
of `SkeletalMesh` and `SkinnedAsset`. A weapon mesh is a component the game itself re-targets on
equip, throw and recall; the body mesh the outfit path swaps is not.

**Built and deployed 21:03 (`A81C7D23`, both installs), UNPROVEN:** same-asset targets are synced by
inspection with no engine call; the setter only, no raw writes; `resolve_peer_named_asset` returns
nothing for an object that is unreachable or has `RF_BeginDestroyed`/`RF_FinishDestroyed`; a weapon
asset without a live `Skeleton` is refused; every component the path touches is checked alive. The
crash watcher (scratchpad `crashes/`) saves each new dump with that session's `UE4SS.log` and
`meshghost.log` before a relaunch can overwrite them. **The measurement that closes this: the user's
evening of play on `A81C7D23` with peers, Archipelago connects and zone changes, and no new
0x36CCF98 dump.** A recurrence with no frame of ours means the mechanism is still not understood
and the feature ships OFF behind a flag until it is.

## [DONE] the blue outline that stuck to the player's sword: cause found, fixed and CONFIRMED 2026-09-05 -- see `VERIFIED.md`; kept for the measurements and the method

**The report (user, on screen, with a screenshot).** Standing among ghosts, the player gets the game's
blue "behind something" silhouette whenever a ghost is between camera and player; and the player's
own SWORD showed the silhouette THROUGH THE PLAYER'S BODY, staying that way after the ghosts moved on.
*"the players sword is never supposed to have a blue outline against the player itself."* The user's
call: **a ghost must never trigger that outline on the player or the sword at all.**

**What the picture says.** The outline is stock custom depth (`documentation.md`, "The through-walls
outline"): body and sword both write it, the custom-depth pass keeps the nearest writer, so a sword
behind the body is never "behind scene depth". A sword outlined through the body means the BODY
stopped writing custom depth -- as a flag or as render state.

**Measured live, 2026-09-05, one A/B with the dev toggle `keep_custom_depth.txt` (ghosts KEEP custom
depth; the mod stops stripping it):**

| ghosts' custom depth | player behind a ghost | sword through own body | ghosts through walls |
|---|---|---|---|
| stripped (shipped) | blue outline on the player | blue, and it stuck | none |
| kept (toggle on) | **none** | **none** -- until ONE melee attack, then body AND sword blue, permanently | blue silhouettes (through walls, not through the translucent void doors -- expected, they write no depth) |

So the occluder half is exactly what it looks like: an opaque ghost writing no custom depth is a wall
as far as the outline pass is concerned. Ghosts writing custom depth removes it, at the cost of ghost
silhouettes through walls -- the cost a different `CustomDepthStencilValue` for ghosts would avoid IF
the game's post-process masks by stencil, which is unmeasured. **The stuck half is triggered by the
player's melee attack** and is not yet explained. Ruled out by reading: the afterimage outline guard
(a pre-hook on `SetRenderCustomDepth`) only ever touches components whose outer is a `BP_AfterImage_C`.
Not ruled out: the per-tick hold walking every object-typed property on a ghost pawn and its thrown
weapon and stripping any value with a custom-depth flag -- if one of those points at the player's own
mesh, the player is stripped every tick with no log line; and whatever the game itself does to the
player's custom depth or stencil around a melee swing.

**The instrument, staged and unrun:** `probe_outline/` in the scratch slot (read-only; flags and
stencil on the player's and every ghost's three meshes on change, a CROSS-OWNER walk of the ghost's
object properties, afterimage attribution). The reinstall had wiped the reloader and the scratch slot,
so it arms on the next launch. Run: stand still, one melee attack, stand still; read `UE4SS.log`.

**Where it goes when found:** the mechanism to `documentation.md` (game fact), the mod change to the
build story, symptom -> cause -> fix to `agent_docs/pitfalls/`.

## [DONE] the sword on a ghost is `WeaponMesh.bVisible`, and it is now mirrored (measured, FIXED and CONFIRMED ON SCREEN 2026-09-04 -- see `VERIFIED.md`; kept here for the two dead theories and the method)

**User-confirmed on screen** (three cases, below). **Measured with `probe_pickup/`**, live, on a new
save. **FIXED, built and deployed 2026-09-04, unwatched** -- the fix is at the end of this entry.
Two earlier theories in this entry were WRONG and are struck rather than deleted, because the way
they died is the useful part.

### What was measured

`probe_pickup/` read both pawns side by side while a replay ghost was on screen and the player had
never picked up the sword:

| | ghost | player |
|---|---|---|
| `weaponEquipped?` | false | false |
| `animEquippedWeapon` | false | false |
| `weaponRef` | `<nil>` | `<nil>` |
| **`WeaponMesh.bVisible`** | **TRUE** | **false** |

The flag sync is correct. What is visible is the **`WeaponMesh` component**, and nothing mirrors it.

### The rule that explains all three cases the user saw

A ghost is spawned from `BP_PlayerGoatMain_C`, whose defaults disagree with each other:
`weaponEquipped?` false, `WeaponMesh.bVisible` **true**. The apply gate is
`!weapon_equip_call_armed || target != last_synced`, so the first tick does call
`changeEquippedWeapon(ghost, target)` — but that is the game's own function, and it early-outs when
the value it is handed already matches the ghost's property. So the mesh only ever changes when
there is a real EDGE:

| clip | `weapon_equipped` | edge on the ghost? | result |
|---|---|---|---|
| recorded before the pickup | `0` throughout | ghost flag already false — **none** | **sword shown** WRONG |
| recorded while thrown | `1` -> `0` | yes | no sword, correct |
| recorded after re-pickup | `1` throughout | false -> 1 is an edge | sword shown, correct |

**So the defect is exactly "the ghost's INITIAL mesh state is never established, only transitions
are."** One broken case, and it is the one the user hit.

`Plugin.cpp:19494`'s own comment predicted this failure mode — *"it would always see old==new and
silently do nothing"* — but was written and fixed for `false -> true`. The case where both sides are
already false, so there is no change for the function to notice at all, was never covered.

### The fix, and why it is this one

Mirror `WeaponMesh.bVisible` **directly** from `target_weapon_equipped`, the way `shadow_on` already
mirrors `BlobShadow` — a component visibility write on our own actor, no game function, so it cannot
depend on an edge and cannot cross-wire. Measured proof that this is the right signal: on the real
player all four flip together on one sample at a throw — `weaponEquipped? true->false`,
`WeaponMesh.bVisible true->false`, `animEquippedWeapon true->false`,
`weaponRef <nil>->BP_looseWeapon_C_...`.

### The two theories that were wrong, kept because of HOW they died

- ~~`weaponEquipped?` reads true before the pickup, so we record a wrong value.~~ **Measured false.**
  The probe's baseline on a fresh save: `weaponEquipped? = false`. The send side was correct all
  along, and so was the clip — `weapon_equipped:0` appears in the recorded ndjson.
- ~~The ghost always shows a sword, so a thrown-sword clip would show two.~~ **Predicted, then
  contradicted by the user the same hour**: a clip recorded while the sword was thrown showed no
  sword at all. That contradiction is what produced the edge rule above — the model only became
  correct once a prediction failed.

**The method note worth keeping:** the answer came from reading TWO pawns in one census and diffing
them, not from tracing one field. Every wrong theory here came from reasoning about a single value.

### BUILT 2026-09-04 -- what shipped, and the second writer that had to be told

`tick_remote_weapon`'s equip block is unchanged; a new mirror sits beside the blob-shadow one and
writes `WeaponMesh.bVisible` straight from `target_weapon_equipped`, comparing against the ghost's
own current `bVisible` rather than a remembered flag (per-mesh truth, no engine call once settled).
Two writers keep priority over it, deliberately: `weapon_hand_hidden`, which is the thrown-sword
path owning the hand until the catch, and the `hide_ghost_weapon.txt` dev subtraction.

**And the ghost mesh loop had to learn the same signal.** It re-asserts `WeaponMesh` visible every
tick unless something claims it, so without a `target_weapon_equipped` term it would have undone the
mirror one tick later and the defect would have looked unfixed. Found by reading the loop, not by
watching the fix fail -- the "two writers on one field" rule this adapter's `CLAUDE.md` states, and
the same shape as the thrown-prop case further down this file.

**What to look at, and what correct looks like.** Play back the clip recorded before the pickup
(`rec-20260904-165557.ndjson`, kept in the install's `replay/`): the ghost should carry **no sword at
all**, where before it always had one. Then the two cases that were already right must stay right --
a clip recorded while the sword was thrown still shows an empty hand, and one recorded after the
pickup still shows the sword. A live peer is the fourth case: pick the sword up, throw it, catch it,
and the ghost's hand should follow all three edges as it did before.

## [DONE] FIXED and CONFIRMED 2026-09-06 (night) -- modded SWORD models never reached a ghost: the sync waited on a flag this build does not reflect (see `VERIFIED.md`; kept for the method)

**The report.** Two instances, each wearing a modded sword (a leek, the Buster Sword): each saw the
STOCK sword on the other's ghost while the outfits synced; two replay ghosts wearing modded outfits
kept the stock sword although their clips carried `weapon_mesh` (the needle, the Buster Sword).

**The cause.** The weapon-mesh sync refuses to touch the hand mesh until `bVisible` AND
`bRegistered` read true, through `mg_read_bool` with a fallback of false -- and `bRegistered` is
not a reflected property on this build, so the fallback deferred every modded sword forever, with
no log line on that path. A probe of the live ghosts showed the hand mesh visible and holding
`mainWeapon`. Fix: the flag gates only when the build reflects it; the deferral logs once per ghost.

**After the fix, both installs' logs:** `weapon mesh applied` for the needle on the horned replay,
the Buster Sword on the small one and on the older replays, and on the copy install for the main
player's ghost (`p30`), each read back as the intended asset. **Confirmed by the user on screen the same night:** *"recordings & other ghosts have the correct modded swords visually shown now"* -- `VERIFIED.md` 2026-09-06.

## [OPEN] BUILT and MEASURED 2026-09-06 (night) -- the leak behind "fps slowly dropping" (fixed), the world walks replaced by event-fed registries (measured), the spawn spike (fixed, confirmed); what is still unwatched is listed at the end

**The user's target, stated that evening:** *"8 ghosts can be assumed to be a pretty small/decent
expected lobby, i don't think this amount of ghosts should be affecting fps in any bad way at
all ... performance to be good all the time even if ghosts are nearby/far and also when they
spawn/despawn so there are no random performance spikes."* Testers had reported 120 -> 100 fps
with a couple of ghosts; the user sees 3-5 fps on their machine.

**1. The leak (FIXED, measured before and after).** With four looping replay ghosts (eight, with a
zip of the same clips) the user's fps drifted 135-144 -> 125-130 -> 112-115 over ~20 minutes. The
census probe counted `NiagaraComponent` 3,257 -> 3,390 in one minute, never down: every one-shot
effect the adapter mirrors onto a ghost was spawned with auto-destroy OFF and only the last 32 per
ghost were destroyed at despawn, so everything older lived forever, and the VFX-mirror scan that
walked them all every 5 ticks had grown from 0.28 to 1.8 ms a frame. Fix:
`spawn_niagara_at_location(..., auto_destroy)`, true at the three one-shot sites, and the ghost's
own `AIController` destroyed with the ghost in `release_ghost` (every loop seam is a release plus
a respawn). After the fix, same rig: 425 -> 541 -> 346 across a forced GC and 90 s -- the count
now rides the GC cycle instead of climbing. `pitfalls/by-lesson.md` 2026-09-06, the leak entry.

**2. The fixed cost with ZERO ghosts (BUILT, unmeasured as of this entry).** With the leak gone
and 8 replay ghosts, the adapter's tick was 2.05 ms a frame at 138 fps and 1.3 of it was the LOCAL
half, which runs with no ghosts at all: the afterimage observer 0.5, the VFX-mirror walk 0.34, the
camera-rig sweep 0.11, the afterimage outline sweep 0.09, the recall scan 0.08 -- every one a
`FindAllOf` on a short cadence, and one such walk is ~1 ms in a lived-in world. They now read
**object registries** (`ObjectRegistry`, Plugin.cpp): seeded once by a real walk, FED by the event
that creates their members -- the two Niagara spawn functions, post-hooked natively
(`register_niagara_spawn_hooks`, the return value), and the SetRenderCustomDepth pre-hook that
already sees every afterimage reuse -- and re-seeded on a slow belt (600 ticks) so a member no hook
covers is late once by at most ~4 s. Members are `FWeakObjectPtr`; the camera registries are
re-seeded at every ghost spawn (the rig is the pawn's). Consumers are unchanged in logic and
cadence. **Expected:** the local half near zero with no ghosts; per ghost ~60 us. **To measure:**
`perf_report.txt` at 0 ghosts, then 3 and 8 fake peers, and the census probe's `ft_request.txt`
(mean / p95 / worst) for the spikes; then a walk away from the ring for the tiers.

**3. Dormant ghosts hid neither their nametag nor their plate** (the user saw tags at the far end
of the loop): both are now hidden and shown explicitly with the tier, and the tier decision moved
ahead of the per-tick nametag update so a dormant ghost's tag is not redrawn every tick.

**Measured after the registries (same night, the user idle, 144 cap):** the local half 1.29 -> 0.16
ms; zero ghosts 6.94 ms mean / 6.94 p95; 8 replay ghosts 6.99 / 6.94; 11 ghosts 7.19 / 7.20 --
8 idle ghosts hold the cap at the same p95 as none. The spawn spike was then named by SPAWNCOST:
the engine's clone 2.5 ms, the adapter's `FixAllLights` repair 18 ms per spawn -- off by default
now, confirmed unnecessary on screen (`VERIFIED.md`), spawns spaced one per two ticks; a spawn
costs the adapter ~0.6 ms of its own work. Tiers A/B at 11 ghosts: tiers off vs on 7.10 vs 7.10
mean, p95 7.39 vs 6.94.

**The README's peer ladder, re-run the same night (cap on, player idle in ZONE_Dungeon, one
minute's settle, a 10 s sample each; the adapter's tick beside it):**

| peers | fps (mean / median) | p95 ms | adapter tick ms | per ghost us |
|---|---|---|---|---|
| 0 | 144 / 144 | 6.94 | 0.16 | -- |
| 4 | 144 / 144 | 6.94 | 0.57 | 76 |
| 8 | 143 / 144 | 6.94 | 0.77 | 63 |
| 16 | 143 / 144 | 7.01 | 1.25 | 56 |
| 32 | 96 / 106 | 15.2 | 2.47 | 59 |
| 100 | 30 / 33 | 49.3 | 7.64 | 63 |
| 150 | 17 / 14 | 116 | 15.8 | 105 |

Against 2026-09-01's ~143 / 133 / 124 / 82 / 53 / 12 / 4.5. The first 100-peer attempt at the
rig's defaults was NOT a measurement: the relay dropped and re-admitted clients continuously
(each fake client saw 17-55 remotes), the game spawned and released 2,918 ghosts and sat near 9
fps; the two big legs were re-run with the relay at 20 Hz and the fake clients at 5 renders/s,
every fake client then holding N-1 remotes for the whole leg. The fake cores run on the same CPU
as the game, so 100 and 150 are a floor. The game recovered to 144.0 / 6.98 ms worst after 3,187
spawn-release cycles. `README.md` carries the new column.

**Still UNWATCHED as of the end of 2026-09-06:** (a) a dormant ghost's nametag FOLLOWING the peer
(the last builds keep the tag and move the hidden actor; the user saw tags at the far end before
that change, not after a peer moved while dormant); (b) a MOVING real peer with the no-use parts
off (step 2, still on by default, measured at no gain -- the user has not decided whether it
ships); (c) the five `ls_rest` sub-slots at 50 ghosts (they were read at 11: `ls_afterimg` and
`ls_vfxmirror` were the growth, and both now read registries); (d) the loop seam as a despawn +
respawn by design (core `replayPlayer.seam`) -- an interpolation reset without a respawn is the
untested idea, core-side, and the last visible spike with looping replays; (e) `loop_pose_xf`,
~40 us per ghost of engine calls (the actor move plus the Blueprint slide handler every tick).

## [OPEN] BUILT 2026-09-06 (evening), deployed to both installs, UNWATCHED -- the distance tiers, the ambient emitter off, the enemies' animation tick option, and a tester zip

**Built and deployed (DLL hash `71713748f788`, both installs; the tester zip on the user's desktop
carries the same DLL and a client rebuilt from the same day's source):**

1. **Distance tiers** (`apply_ghost_distance_tier`; `docs/config.md` has the three keys) on the
   user's own numbers: *"3k+ throttle, 5k+ throttle bit more/almost fully, 10-11k+ despawn"*. Full
   under `ghost_range_throttle` (6500); the engine's update-rate optimization on the three skeletal
   meshes from there; from `ghost_range_far` (8500) the animation paused and the skeleton frozen
   (the model still moves as a whole); from `ghost_range` (10500) DORMANT -- `SetActorHiddenInGame`,
   actor tick off, movement tick off, animation paused, and the adapter `continue`s past that ghost
   in its loop. Dormant instead of despawned for the reason `ideas.md` 7 gives (a spawn is the
   expensive, leak-prone operation; a dormant ghost wakes in one frame). Hysteresis 5%. Distance is
   the peer's target position against the local pawn, one compare per ghost per tick; only a CHANGE
   of tier makes engine calls, each announced in the log. Keys re-read on the dev poll.
2. **The ambient particle emitter off** on every ghost at spawn (`strip_ghost_ambient_particles`):
   `NE_Particles_System`, found in the ghost's own attach tree by asset name, hidden and deactivated
   through the engine's setters. The user's decision after the subtraction (*"basically no balls,
   just the players own"* at zero ghosts; *"i don't think this is something the ghosts need"*).
3. **`VisibilityBasedAnimTickOption = 1`** on the ghost's three meshes at spawn -- animate always,
   refresh the bones only while rendered -- which is what this game gives every enemy and NPC
   (measured 2026-09-06: `BP_Enemy__WalkinEgg_C`, `BP_NPC_C`, `BP_NPC_Child_C` all at 1; the player
   at 0; none of them carries a max draw distance or the update-rate throttle, so the game throttles
   nothing by distance itself). Bones refresh the frame the mesh is rendered, so nothing on screen
   should differ; it has not been watched.
4. Five more `perf_report.txt` sub-slots inside `ls_rest` (`ls_weapon`, `ls_traces`, `ls_slide`,
   `ls_afterimg`, `ls_trail`), for the 1.5 ms that grows with ghost count and has no name yet.

**Not yet seen by anyone:** the tier transitions on screen (walk away from the ring: thinner at
~3k, frozen at ~5k, gone past ~10.5k, back on the way in), the parts-off ghosts, the emitter-less
ghosts, and any perf reading of this build. The rig was down before the game relaunched.

## [OPEN] BUILT and MEASURED 2026-09-06 (later) -- the adapter's own per-ghost tick cut from 11.7 to 7.8 ms at 50 ghosts; the no-use parts switched off at spawn buy NOTHING measurable

**What was built** (one DLL, deployed to both installs; `FLAGS.md` has the two new toggles):

1. The outline hold (`tail_sweeps`) reads a per-class list of object properties resolved once
   (`mg_object_properties`) instead of walking and NAMING every property of the pawn's class per
   ghost per tick; the slide-timeline and blob-shadow function lookups go through a UFunction
   cache (`mg_cached_function`); the per-tick location write resolves its four parameters and six
   inner fields once (`StructTripleLayout`); the ghost-light sweep enumerates the world's lights
   once per sweep tick for all ghosts instead of twice per ghost; the recall-glow scan and the VFX
   mirror share one Niagara enumeration per tick, and the recall scan caches "owned by the pawn +
   recall asset" per component pointer (`g_recall_identity`). Three sub-slots inside `ls_rest`.
2. `strip_ghost_no_use_parts` at spawn: `SpringArm1` (tick off + Deactivate), `DialogueCam` tick,
   `CapsuleComponent` tick, the ghost's `AIController` tick with `PathFollowingComponent` and
   `ActionsComp`. **`SpringArm` stays on -- it is the blob shadow's arm** (the pawn dump's attach
   tree: `SpringArm1`'s only child is `DialogueCam`; the arm mirror feeds `SpringArm`). Character
   movement is opt-in (`ghost_charmove_off.txt`) until a moving peer has been watched.

**Measured** (perf_report.txt, median of five 2-second reports per leg, ghost count verified from
the nametag slot's calls-per-frame, player standing still on ZONE_Dungeon, cap 144, fake peers
orbiting at radius 250; a settle of 60 s after the 50 spawned):

| ms per frame | old DLL, 0 | old DLL, 50 | new, 0 | new, 50 parts kept | new, 50 parts off |
|---|---|---|---|---|---|
| adapter tick | 0.76-0.96 | 11.7 | 1.01 | 7.53 | 7.78 |
| `tail_sweeps` | 0 | 3.7 | 0 | 0.80 | 0.79 |
| `tail_light` | 0 | 0.86 | 0 | 0.37 | 0.45 |
| `loop_pose_xf` | 0 | 2.13 | 0 | 2.10 | 2.02 |
| `ls_rest` (of which recall / vfxmirror / json) | 0.66-0.81 | 2.29 | 0.85 (0.07 / 0.28 / 0.01) | 2.28 (0.13 / 0.45 / 0.02) | 2.44 (0.17 / 0.52 / 0.02) |
| game fps | 144 | ~40 | 144 | 47 | 48 |

**What it says.** (a) The caches took a third off the adapter's 50-ghost tick and the two world-walk
slots fell by ~3.4 ms together. (b) `loop_pose_xf` did NOT move: its ~40 us per ghost is the
engine's own `K2_SetActorLocationAndRotation` (a 28-component actor moved with teleport) plus the
Blueprint slide-timeline handler call, not our lookups. (c) `ls_rest` still grows by ~1.5 ms from 0
to 50 ghosts and the three named sub-slots explain ~0.3 of that; the rest of its ~2,900 lines needs
splitting before it can be cut. (d) At zero ghosts the tick is 1.0 ms and the shared Niagara walk
is 0.28 of it -- UE4SS's `FindAllOf` walks the entire object array with a superclass-chain compare
per object, so one walk is ~1.4 ms in this session and grows with everything pooled. (e) **The
no-use parts cost nothing measurable, adapter-side or in fps**, which agrees with the 50-ghost
matrix (no single one of them left the all-off band). Whether that spawn-time change ships is the
user's call; the agent's recommendation is not to ship a visual risk with no measured gain.

**What the user has NOT judged yet:** the orbiting ghosts with the parts off (shadow on the ground,
pose, anything odd); the white ball particles they see around ghosts (every ghost's
`NE_Particles_System` spawns attached to its capsule -- the probe hook saw 51 of them -- and the
user watched the balls thin out when ghosts despawned, so it is the leading candidate; the
subtraction at 50 ghosts is unusable because `hide_ghost_fx.txt` re-walks the world per ghost per
tick while armed, so it is a two-ghost test).

**A freeze, attributed to the SCRATCH PROBE, one negative so far:** with `probe_partnames` loaded
(Lua `RegisterHook` on `NiagaraFunctionLibrary:SpawnSystemAtLocation` and `:SpawnSystemAttached`),
a melee sword attack among 50 ghosts froze the game thread at 16:06:39 while UE4SS's own thread
kept logging; the last game-thread line was UE4SS's *"Tried to execute UFunction::FuncPtr hook but
there was no function map entry for ... ExecuteUbergraph_BP_PlayerGoatMain. Executing original
function instead."* The user force-closed it. Relaunched with the pristine stub and the same DLL,
the same attack did not freeze. `pitfalls/by-lesson.md` 2026-09-06.

## [OPEN] MEASURED 2026-09-06 -- what a ghost costs, part by part, and half of it is the ADAPTER's own per-ghost tick

**The user's ask:** *"what parts of the player are the most performance heavy? ... spawn ghosts
with only that thing and nothing else ... so we can separate and make a proper list of what
everything does performance wise"*. A pawn cannot be spawned with one component, so
`probes/probe_strip/` switches a live ghost to ALL OFF and one part back ON at a time; 50 fake
peers, cap lifted (`t.MaxFPS 0`), player standing still on ZONE_Dungeon, two 10s samples per
configuration. The one-ghost pass first: 0 ghosts 1.87-2.00 ms, one stock ghost 2.10-2.36, the same
ghost with the six no-use parts off 2.28-2.29 -- a single ghost costs ~0.3 ms and stripping it is
below the noise. The user's look at that stripped ghost: *"think 'one' looks fine/normal
visually?"* -- a first reaction with a hedge, kept as such.

### The 50-ghost matrix (mean ms per frame, two samples; noise between repeats is ~2-4 ms)

| configuration | mean | median |
|---|---|---|
| 0 ghosts | 1.84 | 1.20 |
| 50 stock, fresh after spawn | 34.0 / 35.2 | 32.7 / 33.3 |
| 50 stock, after the matrix (`on=all`) | 25.5 / 26.6 | 24.9 / 25.9 |
| 50 stock + engine anim throttle (`uro`) | 23.7 / 24.0 | 22.8 / 23.2 |
| 50 with EVERYTHING off | 15.2 / 17.7 | 13.8 / 16.2 |
| only dialogue camera tick on | 15.6 / 19.5 | 14.5 / 17.5 |
| only `NE_Particles_System` on | 17.3 / 20.2 | 15.6 / 17.9 |
| only AIController tick on | 14.3 / 15.2 | 13.5 / 14.0 |
| only blob shadow on | 15.0 / 16.4 | 14.3 / 15.3 |
| only nametag on | 15.9 / 16.4 | 14.5 / 14.6 |
| only capsule tick on | 15.6 / 19.4 | 13.9 / 16.5 |
| only the pawn's own tick on | 17.0 / 17.7 | 15.6 / 16.0 |
| only the animation driver (CharacterMesh0 anim BP + IK) on | 17.3 / 20.7 | 15.5 / 19.7 |
| only the visible model on | 15.6 / 16.8 | 14.9 / 15.1 |
| only the weapon mesh on | 15.1 / 16.9 | 14.4 / 15.4 |
| only character movement on | 15.9 / 16.6 | 15.2 / 15.3 |
| only the two spring arms on | 15.2 / 15.4 | 14.0 / 14.6 |
| after all peers gone | 1.61 / 1.66 | 1.18 / 1.19 |

**What the matrix says.** No single part stands out: each one alone sits inside the all-off band.
The pawn's parts together cost ~10 ms across 50 ghosts (25.5 -> 15.2), i.e. ~0.2 ms per ghost, and
they cost it in COMBINATION (animation driving a visible model driving a shadow...), not one at a
time. The engine's update-rate throttle on the three skeletal meshes saves ~2 ms of that at 50.
The fresh-after-spawn stock reading is ~9 ms above the settled one: spawn-time work (materials,
animation warm-up) that a 40s wait does not cover, and the first, crashed pass (below) measured
inside that window -- its "character movement and spring arms cost as much as the model" was that
warm-up, not the parts. **A ghost with everything off still costs ~0.27 ms**, which is where the
adapter's own timer comes in.

### The adapter's own tick (`perf_report.txt`, us per frame)

| slot | 0 ghosts | 50 stock | 50 all off |
|---|---|---|---|
| `tick_total` | 368 | 12,643 | 12,890 |
| `local_state` (of which `ls_rest`) | 355 (296) | 2,843 (2,448) | 2,507 (2,163) |
| `remotes_loop` | 0 | 8,093 | 9,064 |
| .. `loop_tail` / `tail_sweeps` (outline hold) | 0 | 4,786 / 4,004 | 5,008 / 4,249 |
| .. `loop_pose_xf` | 0 | 2,147 | 2,469 |
| .. `loop_mirrors` | 0 | 625 | 922 |
| .. `tail_light` | 0 | 755 | 725 |
| `nametag` | 0 | 321 | 413 |

**Half of a ghost's cost is ours.** 12.6-12.9 ms of the 50-ghost frame is the adapter's own tick,
~0.25 ms per ghost, and it does not move when the ghost's parts are switched off -- it is per-ghost
work the DLL does regardless. The biggest single slot is `tail_sweeps`, the per-tick
`GHOST_HOLD_OUTLINE_OFF` re-assert that walks the ghost's components every frame (~80 us per ghost
per frame, 4 ms at 50); then `loop_pose_xf` (~45 us per ghost), `ls_rest` (which GROWS with ghost
count although it is the local player's half: 0.3 -> 2.4 ms, so something in it scans the world),
`loop_mirrors`, `tail_light`, `nametag`. And at ZERO ghosts the adapter costs 0.37 ms a frame --
a fifth of a 1.8 ms frame -- almost all of it `ls_rest`.

**So the cost split at 50 ghosts, settled:** ~2 ms base game, ~13 ms adapter tick, ~4 ms bare
pawns (actor + hidden components), ~10 ms the pawns' parts, of which the engine throttle recovers
~2. The order to work in: the adapter's own slots first (deterministic C++, verifiable with this
timer alone), then the at-spawn switch-off of the parts a ghost has no use for (visual confirmation
needed per part), then the animation throttle (visual confirmation needed).

**The first pass crashed the game** (14:12:32, "Abort signal received") at `on=dialoguecam`:
`Activate()` on a ghost's camera component. The part is tick-only now; `pitfalls/by-lesson.md`.

## [READY] MEASURED and FIXED 2026-09-06 -- a ghost's camera rig outlives the ghost, and that is the FPS that never comes back

**The user's report (2026-09-06):** frame rate drops every time a ghost despawns -- a peer, a replay
or a chaser alike -- and stays down until "reset to last save", a zone change or the main menu; the
pause menu runs at full rate; after 150 ghosts they sat at 70 fps instead of 141-144. Their own
reading of it was exact: something the WORLD owns (a level reload clears it) and something that
costs a TICK (pausing stops it), accumulating one despawn at a time.

### The census, and why the earlier probe missed it

`probe_leakcount/Scripts/census.lua` walks EVERY UObject and buckets by class, then names what is
new since the first walk. Two fake peers up, then gone, then 90s idle on ZONE_Dungeon:

| class | baseline | 2 ghosts up | 90s after despawn |
|---|---|---|---|
| `BP_PlayerGoatMain_C` (ghost pawn) | 1 | 3 | 1 |
| `AIController` | 6 | 8 | 6 |
| `NiagaraComponent` | 40 | 42 | 40 |
| `TimelineComponent` | 24 | 44 | 26 |
| **`BP_PlayerCam_C`** | **1** | **3** | **3** |
| `SpringArmComponent` | 8 | 14 | 10 |
| `CameraComponent` | 4 | 10 | 8 |

Everything a ghost brought was collected -- including the ~2 Niagara per despawn the 2026-09-04
count had flagged, which that probe could not distinguish from the game's own churn. The ONE
survivor is the camera rig: each ghost pawn's Blueprint spawns its own `BP_PlayerCam_C` (a
`CameraBoom` spring arm, `MainCam`, `FirstPersonCamera`, a timeline), all `bIsActive=true`, and its
`OwningActor` reads null once the pawn is gone. `Plugin.cpp` already knew the rig outlives the
ghost (`GHOST_NEUTRALISE_CAMERA_RIGS`, 2026-08-29) and only zeroed its post-process weight. A
spring arm ticks and sweeps every frame; that is the tick that stops in the pause menu and dies
with the level. **The 2026-09-04 two-class counter could never have found this**: it counted the
classes it had been told to, and the leftover was a class nobody had named.

### The cost, measured with the cap off

`t.MaxFPS 0` sent from the probe with the user's go-ahead (at the 144 cap the frame delta is a
flat 6.94 ms whatever a leaked tick costs -- 36 orphan rigs read as "144 fps, nothing wrong").
Player standing still on ZONE_Dungeon, 10s samples of the world's frame delta:

| orphan rigs alive | mean | median | ~fps |
|---|---|---|---|
| 0 (after reset to last save) | 1.64 / 1.71 ms | 1.2 | 600 |
| 36 | 2.56 / 2.80 ms | 2.1-2.5 | 370 |
| 68 | 3.28 / 3.47 ms | 2.9 | 300 |
| (32 ghosts UP, for scale) | 13.76 / 16.82 ms | 13.3-16.0 | 60-73 |

A straight line, ~0.025 ms per rig. **It is real and it is not the whole story**: at 150 rigs it
extrapolates to ~+3.7 ms -- and the user's 70 fps after 150 fake peers dates from before the first
performance work, when the per-frame base was higher, so the rigs alone can account for it. The next
test the user asked for: 150 fake peers, a few rounds, before vs after (2026-09-06, below).

**Two instrument findings on the way.** Something re-applied the 144 cap mid-session, after a
despawn round, without any settings change -- the probe now resends `t.MaxFPS 0` before each
sample; what re-applies it is not known. And the walk crashed the game once, on its second load of
the session (`pitfalls/by-lesson.md`, 2026-09-06).

### The fix (built 2026-09-06) -- WATCHED BY THE INSTRUMENT the same day, not yet by the user

Fresh launch on the new DLL, cap lifted, 150 fake peers, three spawn/despawn rounds, player
standing still on ZONE_Dungeon:

| point | mean frame | median | `BP_PlayerCam_C` | ghost pawns |
|---|---|---|---|---|
| before, twice | 1.78 / 1.76 ms | 1.3 / 1.2 | 1 | 1 |
| 45s after round 1 | 1.89 ms | 1.2 | **1** | 1 |
| 45s after round 2 | 1.52 ms | 1.1 | **1** | 1 |
| 45s after round 3 | 1.62 ms | 1.1 | **1** | 1 |
| after all rounds, twice | 1.80 / 2.12 ms | 1.1 / 1.4 | **1** | 1 |

`release_ghost` destroyed exactly one rig per despawn (3,476 `CAMRIG release_ghost: 1 rig(s)`
lines); the orphan sweep never had to fire. The world returns to one rig and one pawn after every
round and the frame time to the pre-round baseline within the noise (the last sample's 2.12 ms is
the one reading above the band; its p95 and worst are also the highest, and the counts are clean,
so it reads as noise until a longer sample says otherwise). **Peer-path despawns leave nothing
else behind.** Still READY rather than VERIFIED because the user has not yet reported the frame
rate holding through a session of their own.

**The load rig does not survive 150 fake peers, and that is a separate finding.** Each fake client
receives every other peer's stream; at 150 the relay disconnects clients that are *"not draining"*
(17 kicks, 300 joins for 150 peers, 51k failed sends in `relay.err.log`), they reconnect, and the
game saw ~1,400 spawns and ~1,660 despawns per round instead of 150 -- 689 to 984 pawn objects
alive at once (most of them destroyed and waiting for GC), 400 ms frames. A harder leak test than
intended, and NOT a measurement of what 150 live ghosts cost; that needs a fake peer that drains,
or fewer peers per process.

**The user's 70-fps session was 150 FAKE PEERS too, despawned, stuck until reset to last save** --
corrected by the user 2026-09-06 after this entry first blamed replays and chasers; it dates from
before the first performance work, so 150 orphan rigs (~3.7 ms) on top of that build's per-frame cost
is a sufficient explanation. Recordings and chasers despawn through their own path and are the next
census, at the user's request: *"we should probly check recording & chase ghosts as well"*.

`GHOST_DESTROY_ORPHAN_CAMERA_RIGS`: `release_ghost` destroys the rigs whose `OwningActor` is the
ghost, BEFORE destroying the ghost (afterwards that property is the only handle and it goes null
within a GC cycle); the neutralise sweep additionally destroys any rig whose `OwningActor` reads
null on three consecutive sweeps, the backstop for a despawn path that never reaches
`release_ghost`. Null only -- a rig that names any pawn is somebody's. What settles it: the census
counts `BP_PlayerCam_C` back at 1 after a despawn round, and the uncapped baseline after several
150-ghost rounds equal to the one before.

## [OPEN] world-spawned VFX outlived the ghost — the SCREEN is fixed and confirmed 2026-09-04, the OBJECTS are not

**User-confirmed on screen:** dust in wrong positions after a replay restarts/loops; and, separately,
*"i picked up the sword now, but i still see the sword ground vfx"* — a landed-sword glow left behind
after the ghost that made it was gone. **Root cause found by reading, not yet fixed.**

### The cause

`spawn_niagara_at_location` (`Plugin.cpp:5520`) calls
`NiagaraFunctionLibrary::SpawnSystemAtLocation`. That spawns a **free-standing, world-space**
component — the `world_context` argument is a world handle, not a parent. **Nothing is attached to
the ghost.** Every path that assumes otherwise is wrong, and one says so in a comment:

```cpp
it->second.weapon_glow_component = nullptr;  // attached to the flyer; dies with the ghost
```

(`Plugin.cpp:10683`, and the bare `nullptr` at `:10797`.) It is not attached and it does not die with
the ghost: the release path drops the only handle to a live, visible Niagara ring. The code already
knows how to destroy one — `DestroyComponent` at `:8485`, used when the sword returns to hand — the
release path simply never calls it.

### The three symptoms, all the same defect

1. **The landed-sword glow is left in the world** when a ghost is released. Directly what the user
   saw, and the simplest proof of the cause.
2. **Dust bursts outlive the `remotes` entry.** The detection pass builds its "ours, do not measure"
   exclusion set by walking `remotes`, so a component whose ghost has been erased falls OUT of it and
   can be attributed to the player.
3. **That poisons `observed_world_offset_z`**, which is learned at runtime from the local player's own
   effect, is file-scope rather than per-peer by design, and is NEVER reset — so one bad sample moves
   every later burst, which is why the dust lands in the wrong place and why the tester tied it to
   *"the height of ghost sybil when it despawns"*: the error IS the ghost's despawn height minus the
   player's.

### Why a replay makes it constant

`replayPlayer.seam` (`core/replay.go:522`) is drop -> wait a render tick -> re-admit, and it has four
callers: **every seek (restart, rewind, fast-forward), the loop's end-to-start, a recorded gap longer
than `replayGapSeamMs`, and a clock step-back.** So a replay despawns its ghost repeatedly during
ordinary playback — the third one with nobody touching a key — and each despawn strands whatever it
had spawned.

### The fix, one shape for all three

**Destroy these components explicitly before the `remotes` entry is erased**, since nothing else owns
them. That also removes the offset poisoning for free: a destroyed component cannot be
mis-attributed. Per-ghost counters (`vfx_counts`, `last_seen_*`) should reset on release in the same
pass — but note they are the SECOND half, and resetting them alone would remove the symptom that
makes the leak visible while leaving the leak. Both, or neither.

**Still unmeasured:** the `observed_world_offset_z` poisoning itself. It is file-scope C++, invisible
to a Lua probe, so confirming it needs a log line on every change to that value naming what it was
measured against — cheap, and it belongs in the same rebuild as the fix.

### BUILT 2026-09-04 -- the destroy, the liveness check, and the instrument that goes with it

`release_ghost` now gathers everything world-spawned that the entry holds — the landed-sword glow,
the projectile effect, the retained `vfx_components`, and the `recent_one_shot_components` ring —
and destroys them **before** any of those handles is dropped, hidden-then-stopped-then-destroyed in
the order the glow teardown already proved on this build (it has no `DeactivateImmediate`, so plain
`Deactivate` leaves live particles rendering; hiding first is what actually stops the pixels). The
ring is cleared in the same pass, which it never was.

**The one-shot ring could not simply be dereferenced, and that is the interesting part.** A burst
destroys itself when its particles finish and nothing tells us, so those pointers legitimately go
stale — harmless for the identity comparison they were built for, a crash for a `ProcessEvent`. The
release path therefore takes ONE `FindAllOf("NiagaraComponent")` and only touches handles the engine
still lists. Per-event cadence, none at all for a ghost that spawned nothing; the preflight ratchet
was bumped with the cadence named at the site.

**The instrument for the unmeasured half shipped with it:** `VFXOFFSET` logs every real change to
`observed_world_offset_z`, naming the row key, the component it was measured from, its world Z and
the player's. If a stranded ghost effect was ever being mistaken for the player's own, that line says
so by name — "the value changed" alone would not have distinguished the two.

**What to look at, and what correct looks like.** Land a thrown sword as a peer, then have that ghost
despawn (walk to another area, or just let a replay loop): the ring on the ground must go with it.
Then a replay that loops or is rewound repeatedly — the dust should keep landing at the ghost's feet
run after run, where it has been drifting to wrong heights. The `VFXOFFSET` lines in
`meshghost.log`/`UE4SS.log` are mine to read afterwards; they should only ever cite a component
measured against your own player.

## [DONE] MEASURED 2026-09-04 -- a FROZEN-PLAYER state (item popup, pause menu) freezes the pawn but NOT the fields we send -- the chaser half CONFIRMED fixed 2026-09-05

**2026-09-05 (later) — the probe RAN twice (`probe_frozen/`, `PROBES.md`): the pause menu AND the
item popup are the engine's own pause, and the cutscene is a scripted possession with no readable
edge.** Popup: `PauserPlayerState` set on the sample `UI_NewUpgradePrompt_C` appeared, cleared on
continue, a 19-second span with exact edges. Cutscene: pause off, dilation 1.0, the game moving the
pawn itself; a `UI_CutsceneSkipListener_C` widget marks the start and is collected ~12s after the
end; the controller input gates need a C++ read (`FBoolProperty`, as the cursor flag is read). **The
adapter's `player_frozen` signal is `WorldSettings.PauserPlayerState != null`**, which covers the two
states that produced the 110s freeze; the cutscene moves the pawn and needs no clock stop. Pause menu: `WorldSettings.PauserPlayerState` flips from empty to the
player's PlayerState on the sample the pause-menu widget appears and back on the sample it closes,
held across the options submenu, caught on every edge of a 100ms open/close spam. That is the
adapter's `player_frozen` signal for the pause menu. **Still unmeasured:** the item popup, the intro
cutscene (*"can't move during that cutscene"*, reached by loading a new save) and a zone transition
— the run ended in a reset-to-save crash (the indicator's, see the READY entry above; not the
probe's, cleared by timing). Five controller input gates do not resolve on this build through
UE4SS's property read; the engine pause, time dilation, the pawn's gates and the widget census do.

**2026-09-05 — the CHASER half is decided and built on the Go side; the adapter half is a probe
away.** ADR 0053: a `player_frozen` bridge message (adapter -> core, on change) stops the chaser's
clock, so a pause costs it no delay and it never converges onto a frozen player. Tested
(`core/chaser_test.go`, fails without the fix). **Scope is the user's call, 2026-09-05: chaser
only — recordings and replay ghosts are NOT touched**, so the "floating in the air" picture below
stays as it is by decision, and the "what is NOT the fix" section is now moot for replays. **What
this adapter still owes:** the game's own frozen signal, found with a probe (`/write-a-probe`) —
the 2026-09-04 measurement shows `MovementMode` never changes, so nothing sampled today marks it;
candidates are a pause state or the input mode the popup switches to, and the probe should also
ask whether a zone transition trips it. Then a `player_frozen` send on change, then a chaser
watched across a pause menu.

**The user:** *"recordings look a bit weird as if you are just floating in the air/frozen for a bit"*
when picking an item up. **Measured with `probe_pickup/`** across a real pickup. **Not fixed.**

### What was measured, exactly

Picking up the Dream Breaker opens a modal popup (*"a small popup that comes up when picking an item,
explaining what the item does/how to use it, and need to press continue"*). Across it:

```
s=3439  t=823.3   weaponEquipped? / WeaponMesh.bVisible / animEquippedWeapon   all false -> true
s=3439..4519      1081 samples, ~110 seconds, EVERY SAMPLED VALUE BYTE-IDENTICAL:
                  loc=-3527,4898,147   h=550.0   v=-290.6   move=1   act=0   caps=65.0
s=4520  t=933.6   continue pressed: moveState 1->0, MovementMode 3->1, landed? false->true
```

**The frozen values are mid-air motion values.** `h=550.0` is full running speed and `v=-290.6` is
falling — the pickup was taken mid-jump, and the game froze the pawn for the popup while leaving the
velocity fields at their last in-flight values. `MovementMode` stayed 3 (falling) for the whole
110 seconds. The resume is instantaneous: the fall completes and lands inside a single sample.

### Why it looks like floating

The adapter samples and sends `horizontalSpeed`, `verticalSpeed` and `moveState`. During the popup it
therefore transmits *position not moving, running at 550, falling at 290*. A ghost fed that has a
static position with its blend space driven by run+fall, so it plays a running-fall animation on the
spot — for however long the player reads the popup. The real player is frozen with their animation
frozen too; the ghost's AnimBP keeps running on stale numbers. **The recording is numerically
faithful and visually wrong.**

### What is NOT the fix

Both obvious answers fail against the standing rule that a recording reproduces what was recorded
(`_template/README.md`):

- **Stop sending during the popup** — the ghost holds its last position but its AnimBP still runs on
  `h=550/v=-290`, so it still animates in place. Fixes nothing.
- **Send zeroed speeds** — the ghost stands idle, but the player was frozen MID-FALL, so an idle
  stand is a different wrong picture.

The faithful result is a ghost frozen in the same mid-fall pose, which means pausing the ghost's
ANIMATION rather than adjusting its numbers — a lever nothing currently syncs.

### IT IS NOT THE PICKUP POPUP -- it is ANY state where the game freezes the player

**The user, immediately after the above:** *"same for using the pause menu"*. So the pickup popup is
the instance that got measured, not the scope. The pause menu does the same thing, and by the same
reasoning so does anything else that holds the player still while the world waits -- a map screen, an
inventory, any modal.

**That changes what the fix may be.** A pickup-specific check would be a bandage by construction: it
would leave the pause menu, which is far more common, doing exactly what the measurement above shows.
What is wanted is the general fact *the player is frozen and this is not gameplay*, produced once and
honoured by the adapter (hold the pose), the chaser (do not advance the delay) and the recorder (mark
the span) alike.

**It also makes the chaser half much worse than the measurement suggests.** 110 seconds was a
deliberately long hold for a probe; a player pausing to answer the door is unbounded. Every second of
it is delay the chaser silently spends, so a long pause ends with the chaser sitting inside the
player with no way back except playing until the buffer refills.

**Worth checking when this is picked up, since it is the same question asked twice:** whether a
ZONE TRANSITION is a third instance. The adapter already knows about transitions
(`../CLAUDE.md`: a transition invalidates every cached reference and produces a new pawn), so the
signal may partly exist there already.

### THE CHASER MUST PAUSE TOO, and this is the half that reaches the CORE

**The user, 2026-09-04:** *"chase ghosts should be paused temporarily during this, so they don't just
get on top of you instantly after having picked up an item"*.

**Why it happens, and the measurement above is the proof.** A chaser renders the player's own state
from N seconds ago. While the player is frozen at one position for the whole popup, every sample in
that window is the SAME position — so after N seconds the chaser is drawing that position too, and it
converges onto the player and sits on them. At the 110 seconds measured here the chaser spends
roughly 107 of them parked inside the player. Resuming does not undo it: the chaser is now level, and
the delay it was configured for is simply gone until enough new samples push it back.

**So the fix is not only "freeze the ghost's animation".** Two different things need the same signal:

- an ADAPTER concern: a ghost should hold the pose the player is frozen in, rather than run-falling on
  the spot with stale `h`/`v`;
- a CORE concern: a chaser's delay clock must not advance while the player is frozen, or the delay is
  silently spent. Same for a recording's own timeline, which is what makes a clip reproduce the pause
  at the right length rather than as a stall.

**That raises the bar on what the "a modal is open" signal has to be.** An adapter-local workaround
cannot fix the chaser, because the chaser is core-invented (ADR 0047) and the core never touches the
game. The signal has to reach the core — which means it is a bridge-visible fact, not a private
adapter detail, and adding one is an ADR.

**Not designed, and deliberately not designed here.** Whether the core should suspend the clock,
whether the recorder should mark the span, and what the ghost does with the marked span, are three
separate decisions. What is established is that all three want the same input and nothing currently
produces it.


### THIS IS A BLOCKER FOR `chaser_contact`, not merely a cosmetic annoyance

**The user, closing the thread:** *"else once we add some kind of dmg/ability to hurt the player, it
wouldn't really work that well"*. That is the right reading and it changes the priority of this
entry.

`session_policy.chaser_contact` already exists in the contract (ADR 0047) as **the one effect a
cosmetic ghost may ever have** -- an overlap that hurts on touch. No shipped adapter honours it yet.
The measurement above says that a chaser converges INTO the frozen player and stays there for the
whole modal: so with contact enabled, a player who opens the pause menu would be stood inside a
damaging ghost, for an unbounded time, with no way to react because the game is frozen.

**So the order is fixed rather than a preference: the frozen-player signal has to exist BEFORE
`chaser_contact` is turned on for any adapter.** Enabling contact first would ship a mechanic whose
worst case is "the pause menu kills you", and it would be blamed on contact rather than on this.

Noted here rather than in the contract because nothing has changed about what `chaser_contact` MEANS
-- only about what must be true before it is used. If it is ever implemented, the implementing ADR
should cite this entry.

### The open question, and it is the whole of the remaining work

**Nothing we sample says "a modal is open".** `moveState` stayed 1 and `actionState` stayed 0
throughout; `MovementMode` stayed 3. `probe_menuwatch/` does not help — despite the name it is the
reset-world fingerprint, not a menu detector. So the work is to find the signal that marks this
state, and the nearest precedent for acting on one is the title-screen send gate.

**Same shape as the sword finding on the same day:** the game reached a state through a path none of
our sampled fields describe.

## [READY] a non-ASCII display name should now render as itself, not as mojibake (2026-09-04)

**The defect, found by the fuzzer rather than by anyone looking at a nametag.** Since 2026-09-03
`json_string_field` decodes escapes and multi-byte UTF-8 correctly, so a display name arrives in the
adapter as real UTF-8 bytes. It was then handed to `to_wide_ascii`, which widens each BYTE
separately -- so a name with any non-ASCII character in it rendered as two or more garbage glyphs.
The core had already sanitised the name correctly; the adapter took the right bytes and drew them
wrong.

`to_wide_ascii` was not the bug. Its own comment scopes it to core-stamped ASCII `player_id`s and it
is right for those. A NAME is user-typed free text and was simply routed through the function built
for ids. `utf8_to_wide` is the inverse of the `to_utf8` this file already had.

**What to watch:** set a display name with a non-ASCII character in it -- an accent, a Japanese
character, an emoji -- on one client, and read the nametag on the other. It should read as the name
you typed. Before this it read as mojibake, so the difference is unmistakable rather than subtle.

**Also worth one glance while you are there:** a plain ASCII name must still be exactly right, and
the deliberately nasty name that was confirmed on 2026-09-04 (`VERIFIED.md`, quotes and `#` in it)
must still come through whole. That one exercised the escape decoding, and this change sits directly
downstream of it.

## [READY] the peer-JSON readers were rebuilt and rescoped, and nobody has watched a ghost since (2026-09-04)

**What changed and why it needs eyes.** Every field on a `render_remote` used to be found by
searching the whole bridge line for its key and taking the first hit. A new fuzzer
(`MeshGhostPseudo.Tests/peer_json_fuzz.cpp`) showed three ways a peer beats that, so
`handle_bridge_line` now resolves root -> payload -> state -> extras once and reads named members of
those objects. **42 call sites changed shape** — every animation-state field, every weapon and
projectile field, the counts, the nametag. Ten narrowings also gained bounds, and `position` gained
a finiteness check.

**None of this is supposed to change anything you can see**, which is exactly why it wants a look:
the failure mode of a mistake here is not a crash but a field that silently stops arriving, and a
field that stops arriving looks like a feature that was never built.

**What to watch, in one session with a chaser or a second client:**

- A ghost animates normally — walking, jumping, landing, sliding, wall-riding. Those are
  `move_state`, `action_state`, `anim_jump_type`, `movement_mode`, `h_speed`, `v_speed`, and they
  are the fields most likely to go quiet if a span resolves wrong.
- The Dream Breaker: thrown, in flight, landed, its glow, and the recall glow. `weapon_*` is the
  largest group of extras fields and the most intricate.
- The slide: the capsule shrinks and the pose runs. `capsule_half` and `slide_t` both gained
  clamps, and `capsule_half` also feeds position Z.
- The afterimage trail, colour included — `afterimage_color` gained a clamp, so a wrong bound would
  show as a grey or black trail rather than the peer's colour.
- A nametag appears with the right text and colour.
- **A modded outfit or weapon, if you have one installed on both sides.** The catalog gate is
  untouched, but this is the run to confirm mods still resolve.

**What correct looks like:** exactly what you saw before this change. Any field that has gone quiet
is a scoping mistake, and naming which one points straight at the span that resolved wrong.

## [READY] a chaser looks like its own delay, and a split time matches the ghost you SEE (2026-09-04), unwatched

**The defect this fixes shipped and was found by reading, not by watching** (ADR 0049): a ghost this
core invents was drawn one full `interp` behind its own schedule on top of that schedule, because
local ghosts share the interpolation buffer with relay peers and nothing subtracted the delay back.
At the shipped 450ms that made **a chaser configured for 3s appear at 3.45s**, and it made the split
time describe a ghost 450ms ahead of the one on screen -- in the one feature racing a ghost is for.

**What to watch, and both halves want a stopwatch rather than an impression:**

- Set `chaser.enabled: true` with `chaser.delay: "3s"`. Walk a straight line, stop, and count how
  long until the chaser reaches where you stopped. Three seconds, not three and a half. The old
  behaviour is 15% late, which is the kind of thing that reads as "feels a bit off" rather than as a
  number, so compare against a clock rather than a memory.
- With a replay ghost and `replay.split_times: true`, stand exactly where the ghost is drawn. The
  tag should read about `0.0s` there. Before this it read `0.0s` when you stood where the ghost's
  RECORDING was at that moment, which is a spot the ghost had not visibly reached yet.

**Everything measurable is already measured** -- the Go tests pin both numbers, and each one was run
against a deliberately reintroduced defect to prove it fails (the end-to-end one reads 637ms where
200 is wanted). What no test can answer is whether it now looks right, which is the whole reason
this entry exists.

## [READY] the title screen no longer reports a player (2026-09-04), unwatched

**Found in the user's own recording:** every `record_on_launch` clip opened with a stack of
`TitleScreen` samples at [0,0,0], 250ms apart, which is the keepalive cadence for a state that is
not changing. The core promises the opposite (`bridgeserve.go`'s `record_on_launch` comment) and
cannot deliver it, being forbidden from knowing what a menu is -- and this adapter's existing "no
pawn, send null" branch never fired, because Pseudoregalia's title screen is a real level with a
real player pawn standing at the origin. The gate now matches the level name against a list of
non-gameplay maps, currently just `TitleScreen`.

**What to watch:** start with `record_on_launch` on, sit in the menu a while, then play. Correct is
a recording whose first sample is your first real frame in a real level, with no `TitleScreen`
lines at the top of the file. Worth noticing while there: no peer standing at the origin while you
are both in menus.

**If another non-gameplay map exists** (credits, a loading map), it needs adding to the same list,
and it will look exactly like this bug did.

**MEASURED 2026-09-04 on the user's own run, and still theirs to confirm on screen:** the game came
up at 11:58:19 and `rec-20260904-115825.ndjson` opens its first sample at 11:59:15 — **56 seconds
of menu with nothing recorded** — in `ZONE_LowerCastle`, at a real position. `TitleScreen` appears
**0 times** in the whole 6.8MB file, against a stack of them at the top of every clip before the
fix. That is the file half of the entry; what is left for eyes is that the menu behaved normally
while it recorded nothing.

## [READY] the SFX fix in the DLL, unwatched -- the diagnosis trail that got there is kept below (2026-09-03 -> 2026-09-04)

**WHAT TO WATCH, and it is the only thing left here:** the fix was proven in Lua and confirmed by
the user (`VERIFIED.md`, 2026-09-04), then rewritten as production C++ in a DIFFERENT and better
shape -- `register_audio_listener_guard` rewrites the argument of
`SetAudioListenerAttenuationOverride` in a pre-hook, so the engine's own call uses the player's
capsule and no second call is made. **A different implementation is a different thing to watch.**
Built with `build-pseudoregalia.bat` and deployed to both installs on 2026-09-04; it takes effect
on the next game start.

Correct is: play with the chaser on, let ghosts spawn and despawn repeatedly, and cross zones with
one alive -- your own SFX never drop out. The log carries the first five corrections
(`audio listener: a call pointed the attenuation listener at ... -- redirected`) and then goes
quiet on purpose, so a silent log after five is the healthy state, not a stopped guard.

**Setting the run up takes two lines, because both installs were put back to the SHIPPED config at
the end of 2026-09-04** (the standing rule: an install that has drifted cannot answer "does the
release work"). For the next run, set `chaser.enabled: true` and a short `chaser.delay` -- `8s` is
what made the 2026-09-04 loop bearable, against the 60s that had the user *"sitting around waiting
for nothing to happen"*. **A client-only setting like that no longer needs a relaunch**: edit the
file and kill the `meshghost` process, and the adapter starts a new core that reads it
(`../../agent_docs/running-the-rig.md`).

**Both audio probes are PARKED (`enabled.txt.off`), in the installs and here.** `probe_audiofix/`
especially: it applies the same fix from Lua, so leaving it armed would make the shipped C++ fix
untestable -- the run would pass whether or not the DLL works.


**The user, after a session with a replay ghost running:** *"think ghosts are eating up the players
sound, like sfx is not doing anything when the player does things, but ghosts had them."* Logged at
their request rather than chased -- nothing here has been reproduced or measured by the agent, and
no fix has been attempted.

**Why this is plausible rather than surprising, and where to start.** The ghost is a real
`BP_PlayerGoatMain_C`, so triggering the pawn's own systems gets its AUDIO for free -- which the
project already knows and already has a rule about: `ideas.md`'s SILENCE CLAUSE (2026-08-15), *"ghosts
should be silent"*, with the suppression meant to happen immediately after the call that starts a
sound. Two shapes fit what was reported, and they want different fixes:

- **A ghost is playing sounds it should not** -- the silence clause is not covering some path (a new
  effect, the replay/chaser feed, or a sound started by the animation rather than by our trigger).
  That alone would explain "ghosts had them".
- **Concurrency, which would explain the other half.** Unreal sounds carry concurrency limits, and a
  common setting is a small per-sound cap that STEALS the oldest instance. If a ghost plays the same
  cue the player is about to, the player's own can be refused or cut -- the ghost is not merely noisy,
  it is spending the player's voices. This is the shape that matches "the player's SFX do nothing".

**First measurement when this is picked up**, cheapest first, and none of it needs a fix in hand:
play with NO ghost (no replay in `replay/active/`, chaser off) and confirm the player's SFX are
normal -- that separates a ghost-caused fault from an unrelated audio regression. Then one ghost, and
listen for whether the player's sound is missing only while the ghost is doing something. A Lua probe
can enumerate live `AudioComponent`s and their owners (`../CLAUDE.md`: probe in Lua, hot reload) --
who owns them and whether the ghost's are active is the question, and the answer picks between the
two shapes above.

**Not a regression from today's work, as far as anything shows:** nothing in the 2026-09-03 session
touched audio. It may well predate the replay feature entirely; the replay ghost is simply the first
time a ghost has been reliably present and doing things while the user listened.

**The instrument is built, 2026-09-04, and the run is set up but not yet run.**
`probe_audiocensus/` (indexed in `PROBES.md`) logs every `AudioComponent` appearance, START and
STOP, attributed to the player or a ghost by name containment, and dumps each distinct cue's own
CONCURRENCY settings the first time it is seen — that dump is what decides the second shape
without needing an ear, because a cue that caps itself and resolves by stopping the oldest
instance IS the mechanism. Deployed armed to both installs. **It is blind to
`PlaySoundAtLocation`/`PlaySound2D`**, which create no component and are the usual shape of an
anim-notify footstep, and blind to whether an active component was actually audible — both stated
in its header, and both mean a quiet log is not an acquittal.

**The A/B is built into the session rather than asked of the user**, so there is nothing to time
and no window to hit: the chaser is configured to 60s, so the first minute of play has NO ghost
at all and the second minute has a ghost repeating the same actions in the same place. Do the
noisy things (jump, land, slash, dash, cling) in both halves and listen to your OWN sound. The
probe marks the boundary itself with a `GHOSTCOUNT 0 -> 1` line. Both installs also carry
`record_on_launch: true` and `offline: true` for this run.

### RUN 2026-09-04: reproduced, and the trigger is GHOST PRESENCE, not the zone change

**The user's rule, arrived at across three attempts in one session, each one narrowing it:** *"I
lost the player sfx after moving to another zone, it was working in the first zone before & after
the ghost"*, then *"moving back and forth between the zones fixed it"*, then — the isolating
one, with the zone held constant — *"both the player & ghost had sounds while it was spawned, but
the sfx went away once the ghost despawned"*. **A ghost alive means you can hear yourself; the
moment it despawns your own SFX are gone; the next chaser spawn brings them back.** The zone
change was never the cause: a transition destroys the ghost, which is the same event.

**The user also hears MUSIC throughout, and *"any player related sfx is completly silent"* — not
faint — jumping, wall kicks, sliding, backflips.**

**What the log settles, and it turns the diagnosis around** (`UE4SS.log`, the 12:17 cycle):

- **The game never stops playing your sounds.** Your own footstep, land and jump components are
  still created and still go active DURING the silence, seconds after the ghost went. So this is
  not a suppression and not a missed silence clause — the sounds are played and are inaudible.
- **One `MainPlayerController_C`, driving your pawn, unchanged across the whole cycle.** A second
  local player stealing the listener is ruled out by measurement rather than by argument.
- **The view target is stable and tracks the player** — the same `BP_PlayerCam_C` before, during
  and after, moving with you. The camera is not wandering, and the earlier "stale rig from the old
  zone" idea is dead: the rig followed the transition correctly at 12:09:11.
- **This game's sound classes are `SoundClass_SFX`, `SoundClass_Music`, `SoundClass_UI` and
  `Master`** — the split the symptom follows exactly. Their `Properties.Volume` all read 1.00, and
  that read CANNOT close the question: a runtime SoundMix modifier ducks a class inside the audio
  device without writing anything back to the asset.

**The standing hypothesis, and why it fits everything:** a ghost is a CLONE OF THE PLAYER PAWN, so
its BeginPlay and EndPlay run the game's own player-pawn audio setup and teardown against the one
global audio device the player is listening through. A mix pushed when a pawn appears and popped
when one is destroyed produces precisely this — audible while a ghost exists, silent the moment it
goes, music untouched because it is a different class. Hooks on `PushSoundMixModifier`,
`PopSoundMixModifier`, `SetBaseSoundMix`, `ClearSoundMixModifiers` and the two class-override
statics are armed in the probe (all six resolved; `StopAllSounds` is not on this build), so the
next despawn names the call if that is what is happening.

### CAUSE FOUND 2026-09-04: every ghost STEALS the player's audio attenuation listener

**The call, caught twice out of two ghost spawns, ~0.1s before each `GHOSTCOUNT 0 -> 1`:**

```
LISTENERCALL SetAudioListenerAttenuationOverride
  arg1=CapsuleComponent ...PersistentLevel.BP_PlayerGoatMain_C_2147378487.CollisionCylinder
```

and the coverage line names that pawn `BP_PlayerGoatMain_C_2147378487=ghost`. The second spawn did
the same with its own new pawn (`...2147366642`). **`BP_PlayerGoatMain_C` pins the player
controller's audio ATTENUATION listener to its own collision capsule on BeginPlay — and a ghost is
a clone of that pawn, so every ghost that spawns takes the listener with it.**

Attenuation is what decides how loud a spatialized sound is at the ear, so the whole report falls
out of it:

- **Ghost alive:** attenuation is measured from the ghost, which is standing near the player, so
  both are audible — the user's *"both the player & ghost had sounds while it was spawned"*, and
  the original *"ghosts had them"*.
- **Ghost despawns:** the override still names a component that no longer exists, so every
  spatialized sound attenuates to nothing. **Music is 2D and never consults attenuation**, which is
  why it survives, and why the silence is total rather than faint.
- **Next ghost spawns:** its BeginPlay re-points the override and everything returns.
- **A zone change with a ghost present:** the ghost dies with the level. That is the first report,
  and the reason it read as a transition bug across the first three reports of 2026-09-04.

**This is the loose-sword class again** (`VERIFIED.md`, 2026-09-01, the ghost repointing the
watcher's `weaponRef`): a singleplayer game's own code claims *the* player, and a ghost is a real
player pawn, so it claims it too. `../CLAUDE.md` already carries the rule — this is its second
instance, and the first one outside gameplay state.

**Eliminated on the way, each by measurement:** `SetAudioListenerOverride` and its two siblings are
never called; a ghost spawn fires the game instance's own settings pass (`SetBaseSoundMix`, then
four `SetSoundMixClassOverride` — Master `0.2317`, Music/**SFX**/UI all `1.0`); `MySoundMix` has
`Duration=-1` so it never expires; the sound classes' own volumes never change; a despawn fires
none of the ten hooked audio calls.

**THE FIX, not yet built:** the ghost decouple pass that already runs on the spawn tick — the one
clearing the ghost's HUD ref, game-instance ref and damage values — puts the attenuation listener
back on the LOCAL player's capsule after the ghost's BeginPlay has stolen it. **Nothing is watched
yet**: the cause is named from the log, the fix is not written, and neither has been heard.

**Two instrument limits found the hard way today, both recorded because a reader would otherwise
trust the readings:** the controller's listener-override fields (`bOverrideAudioListener`,
`AudioListenerComponent` and neighbours) **do not read on this build** — each handed back a fresh
UObject wrapper at a different address every sample, which `prop()` reports as *resolved* because
the read itself succeeds. And the probe's first pawn discriminator was wrong: **a ghost here reads
as POSSESSED**, so asking each pawn for a Controller labelled every ghost as the player. It asks
the controller which pawn it drives now.

## [READY] `"autostart"` in config.json replaces the environment variable as the way to say "don't start a client" (2026-09-03), unwatched

The user's call: *"even me that is somewhat tech savvy, has no clue what 'an environment variable' means."*
The launcher reads `"autostart"` out of the same config.json the client will read (the GAME ROOT, and since 2026-09-05 nowhere
else -- the mod folder stopped being searched with `31242013`), by a hand scan for `"autostart": false`; absent or
anything else means start. `MESHGHOST_NO_AUTOSTART` still counts as a no. `config_disables_autostart()` beside `resolve_bridge_base_port`, checked in the constructor after the variable; the log line is `"autostart": false in config.json -- not starting a core`. **What to watch:**
with `false` in the file, the game comes up with no client started and the log line naming the reason;
with `true` (the shipped value) the client starts exactly as before. Root and per-game READMEs rewritten
around the key ("Turning autostart off").

## [READY] the launcher forgets a child the port walk has moved off — mirrored from TEVI 2026-09-02, unwatched

**Reproduced and recovered here too, the same night (agent, from `UE4SS.log`):** both installs put on one
port base (6700) and launched 3 seconds apart; the main install's core was taken by the Copy, the main
logged `the core this mod started (pid 2292, port 6700) is serving another game -- leaving it to that game
and starting another on port 6701`, then `core on port 6701 accepted us`; both games rendered each other.
The custom bases (6700/6800, the user's 2026-08-30 test numbers) were then removed from both installs --
*"shouldn't those be 7778 as well?"* -- and a relaunch 3 seconds apart walked normally: main on 7778, the
Copy `busy` there and accepted on 7779. What is left for eyes: the two ghosts after such a start.

**Mirrored from TEVI, 2026-09-02, unwatched here.** "My child process is alive" was read as "I have a
core": two copies launched a few seconds apart can each spawn on the base port, one core wins the
bind, the OTHER copy's adapter can reach it first, and the spawner is answered `busy` on its own
child's port and walks on while its launcher never spawns again. Watched on TEVI, reproduced on purpose
there and recovered (`adapters/tevi/UNVERIFIED.md`, "the port walk's dead end"). The fix here is the same
shape: `CoreLauncher.cpp` remembers `last_spawn_port`; a live child on a port the walk has moved off is forgotten (never terminated) and a fresh core starts at the cursor. Built with `build-pseudoregalia.bat`, deployed to both installs. **What to watch:** two instances launched a few seconds apart both reach a ghost, with
nobody killing a core; the log line in the copy that lost the race is `the core this mod started (pid N, port P) is serving another game`.


**REVISED the same night, after Emerald showed the first version's flaw (2026-09-02, ~23:00).** Forgetting the
child whenever the walk moved off its port was too eager: two instances whose cores were restarted
together each spawned on the base port, each adapter's sweep attached to the OTHER's fresh core first,
each then took `busy` on its own child, forgot it, spawned again -- three cores for two games, and the
emulator at 3fps under the connect storm (Emerald's sweep ran every frame, eight blocking 50ms connects
each). The rule is now two-part in all four launchers: **a spawner waits on its own child's port and never
sweeps past it while that child lives; the child is forgotten only when its port answers "busy"**, never
on silence. Emerald's sweep also runs every 30 frames instead of every frame. Built and deployed (TEVI,
Pseudoregalia DLLs; both Lua files); unwatched beyond one Emerald reload that reattached cleanly.

## [OPEN] Pending — BOTH INSTANCES HARD-CRASHED seconds after `curve catmull-rom` was switched on (2026-08-30)

**What happened.** On the two-instance netsim rig (relay 60Hz, both clients interp 250ms,
`predict damped`, through `meshghost-netsim` at 60ms/±25ms/2% loss/2% reorder), the curve was
flipped from `linear` to `catmull-rom` with nothing else changed. Both games ran normally for
~13 seconds and then died within two seconds of each other — 20:28:37 and 20:28:39 — with the
empty `Fatal error!` dialog this adapter's crash family is known for (it dies inside the engine
rather than in our frame).

**The logs are clean right up to the last tick**, which is what makes this worth keeping: both
adapters' bridge counters read `send_fail=0 lines_malformed=0` at 20:28:36.7, and both cores
logged nothing but a normal `pid ... is gone -- exiting`. Nothing reported a problem before the
process vanished.

**The curve is the only variable that changed**, and two independent processes dying at the same
moment points at the data they were both rendering rather than at either machine. That is
suspicion, not attribution.

**MEASURED GO-SIDE, and it does NOT close the case** (`core/curvespacing_test.go`, written for
this): `curved()` picks `p0` and `p3` by INDEX and parameterises the spline UNIFORMLY, while a
real session's spacing is wildly uneven — 60Hz samples ~16ms apart, a `keepalive` re-send 250ms
after the last change, plus the link's own loss and reordering. On a STRAIGHT constant-velocity
run, where a straight line should be exact, a 250ms/16ms spacing mismatch throws the rendered
position **0.45 segment lengths** outside the segment (evenly spaced samples stay under 0.01).
So the curve really does misbehave on this rig's data — but 0.45 of a segment is a wobble, not a
teleport, and **it is not a crash mechanism.** The cause is still unknown.

**A CONFOUND that must be stated, because it was my own rig fault.** At crash time the two games
were CROSS-WIRED: the Copy was attached to the core started for instance 1 (port 6674), while
instance 1 was attached to a stale mod-spawned core on 6672 that neither launch created. Both
mods walk 8 ports from the same base, so whichever core answered first won, and the
kill-all-and-restart loop used for each sweep step reshuffled it every time. **Fixed for the
future** by giving each install its own far-apart base (6700 and 6800), which the walks cannot
overlap. Whether a stale core was serving one game settings from an earlier step is not knowable
after the fact — so this crash sits on a rig that was not clean, and a reproduction attempt has
to happen on the fixed one before it means anything.

**What to do next, in order:**
1. Relaunch both games on the fixed rig at `linear` and confirm a normal session — that this is
   healthy is not currently established.
2. Only then re-enable `catmull-rom` deliberately, watching for the same ~13-second delay. If it
   crashes twice, it is the curve and the next step is the crash dump under
   `pseudoregalia/Saved/Crashes` rather than more theory.
3. If it does not reproduce, this stays open and unattributed rather than being quietly closed —
   an unreproduced simultaneous crash is exactly what an intermittent defect looks like early.

**The curve knob is UNJUDGED as a result** — nobody has yet seen whether it fixes the jump chop it
was enabled to test, because the session ended before either player could look at a jump.

---

## [READY] The RENDER SWEEP on netsim: the interp ladder, the rate axis, and what was NOT taken (2026-08-30)

**The rig**, which is the part that makes the numbers mean anything: **two real game instances**
(the user's call -- *"think i used 2 clients when testing with tevi, also easier to spot that way"*
-- a loopback self-ghost was the first plan and is a weaker read), both clients through
`meshghost-netsim` at **60ms latency / +/-25ms jitter / 2% loss / 2% reorder**, relay at the
shipped 20Hz, `interp` swept in both installs' `config.json`. Same fault profile TEVI's sweep used,
so the two games are comparable.

**Judged CLIMBING from the broken end, on the user's rule:** *"our goal should be to go from low, to
high, not just go high and then low ? so we actually notice when it 'gets good' instead of 'when it
gets bad'"*, and *"easier to notice bad things getting better/perfect, than spotting when something
gets slightly worse"*. The agent had started at the top and had to be corrected twice -- once on
`interp`, then again on the rate axis, where "the bad end" is the opposite direction.

### The interp ladder — walking back and forth past each other

| interp | The user's read |
| --- | --- |
| 0ms | broken, as intended (the floor of the ladder) |
| 175ms | *"still looks choppy/bad when moving back/forward"* |
| 200ms | *"mostly smooth, but i see some chopy/jittery parts like 2-3"* |
| 225ms | *"noticable choppy/jittery in comparison to 235"* — on a SECOND fault sequence, so not a dice roll |
| 235ms | *"i don't think im seeing anything choppy/bad anymore"* |
| 250ms (shipped) | clean |

**The wall sits between 225 and 235ms, and Pseudoregalia therefore keeps the template's 250ms** --
where TEVI settled at 175ms on the identical link. A per-game difference measured rather than
assumed, which is what ADR 0040 exists for.

**A 240ms override was written and then withdrawn the same hour, on the user's call.** They chose
240 first (*"thats still a 10ms win compared to the 250ms we have used before"*) and then
*"actually just put it at 250ms"*. Recorded because the reasoning matters: the user's standing
preference is **the lowest delay that holds, not the safest high one** -- interp is visible lag by
design -- and 240 vs 250 is inside one dice roll of the fault sequence anyway.

### The rate axis — judged on JUMPING, which was the user's idea

**20 -> 30 -> 40 -> 50 -> 60Hz barely moved the jump chop.** *"60 is also choppy"*. Tripling the
rate is the biggest lever the network side has, so **that is a real result: the jump chop is not
sample spacing**, and the shipped 20Hz is vindicated -- there is no reason to spend three times the
bandwidth on a defect it does not fix.

**The user picked the motion per axis, and it mattered:** back-and-forth walking for interp,
jumping for rate. A jump is an ARC; on a straight path `catmull-rom` and `linear` are numerically
identical, so the walking test could never have said anything about curvature.

### What was NOT taken, and why

- **`extrapolate`: not taken.** The user remembered TEVI's outcome correctly and the agent quoted a
  stale line at them: the mid-sweep KNOB winner included prediction, but **TEVI's settled pick is
  175ms / linear / prediction OFF**, because prediction hid the delay and pushed a landing ghost
  through the floor. *"extrapolation felt way more instant/responsive, but it looked visually bad
  in comparison for Tevi."* Pseudoregalia has more airtime, so the sink has more chances, not
  fewer. `dev-scripts/README.md` now carries both lines together so the winner cannot be quoted
  alone again.
- **`curve catmull-rom`: UNJUDGED.** It was enabled to test the jump chop -- an arc drawn as chords
  is the obvious suspect once rate is ruled out -- and **both game instances hard-crashed ~13
  seconds later**, before anyone could look at a jump. See the crash entry below.
- **Measured Go-side afterwards** (`core/curvespacing_test.go`): the curve is uniform-parameterised
  but picks its neighbours BY INDEX, and this session's spacing was wildly uneven (60Hz samples
  ~16ms apart, a 250ms keepalive re-send whenever a player stands still, plus the link's loss and
  reordering). On a straight constant-velocity run, where a straight line should be exact, that
  bends the rendered position **0.45 segment lengths**. Real defect, pinned by a test -- but a
  wobble, not a teleport, so **it does not explain the crash** and was not claimed to.

**So the sweep's remaining question is unchanged: what makes a jumping ghost look choppy at every
rate and every interp?** Not spacing, not delay. The next candidates are the curve (once it is safe
to enable) and the ghost's own animation being driven by arriving state rather than played through.

---

## [READY] Pending — the PERFORMANCE WORK: what it bought, what it broke, and what is unwatched (2026-08-30)

**The problem, user-reported:** one peer took the game from 144fps to 70-80; two real clients the
same; three ~40; four ~30. *"The game becomes unplayable with even just 2-3 players."*

**What it turned out to be:** four whole-world `UObjectGlobals::FindAllOf` scans running on the
tick, none of it rendering. Method, table and the transferable lessons:
`../../agent_docs/pitfalls/method.md`, "A ghost cost half the frame rate".

**Peak measured result, before the safety reverts below:** `tick_total` 9819 -> 2924 us/frame,
per-ghost 6283 -> 309 us, and the user's own reading **70-80fps -> 141-144fps** with a peer
present. Two ghosts measured 606 us total, i.e. linear.

### What SHIPPED and is still in

| Fix | What it was | Worth |
| --- | --- | --- |
| Dev-toggle sweeps gated | `hide_ghost_shadow`/`hide_ghost_nametag`/`hide_ghost_fx` swept the whole world every tick **in normal play, armed or not** | ~3300 us/frame |
| Outline sweep walks the attach tree | was `FindAllOf` over every skeletal + static mesh in the level, every 5th frame | ~500 us/frame |
| Light hold walks the attach tree | was two whole-world light scans **per ghost per tick** | ~6357 us/frame |
| Afterimage sweep on an interval | was `FindAllOf("BP_AfterImage_C")` every tick | ~1200 us/frame |

**The gating was reverted for one A/B run and then restored**, because the invisibility it was
suspected of turned out to be the rig. It is worth ~3300 us/frame and is IN.

### What was REVERTED, and why it must not be retried naively

**A crash appeared, it was attributed to these fixes, AND THAT ATTRIBUTION WAS WRONG.** The user
reloaded a save on the second client and the game died with the empty `Fatal error!` dialog. The
caches were the obvious suspect and the reasoning below is sound in itself -- but **bisecting
settled it the other way**: with the pre-session DLL deployed (commit `b74a1d1`, confirmed live by
zero `PERF` lines in the log), *"reset to last save"* **still crashed client2**. So the crash is
PRE-EXISTING and predates every change made on 2026-08-30. **Closed 2026-09-01 -- it was the
nametag residue; see the CLOSED section below and `VERIFIED.md`.**

The caches were reverted anyway, and should stay reverted, because the lifetime defect described
here is real whether or not it caused this particular crash. Three fixes had cached raw pointers to
level-owned objects between ticks: the local controller, the ghost's light components, the pooled
projectile actors.

- **RELOADING A SAVE INTO THE SAME LEVEL DOES NOT FIRE THE `LoadMap PRE` HOOK** -- the one place
  this file drops every other level-owned pointer. Confirmed from the log: no `LoadMap PRE fired`
  line anywhere near the crash.
- **`IsUnreachable()` IS NOT A VALIDITY TEST.** It dereferences the object being tested, so the
  guard written for a freed pointer is the same crash. The 2026-08-13 entry above the LoadMap hook
  already said this; it was written and then not applied to the two caches that followed.
- Reverted: the controller cache (+1308 us/frame) and the projectile pool cache (+~1200 us/frame).
  Both carry a comment saying the obvious optimisation is a crash and **what it needs first: a
  hook that fires on a same-level reload.** Not a cleverer guard.
- The light fix was KEPT but rebuilt to walk `remote.ghost`'s own attach tree -- same saving, no
  pointers held, and the ghost's lifetime is already managed by this file.

### CLOSED 2026-09-01: the reset-to-save crash, the vanished nametags, and the spawn holds

The two-session hunt that lived here (2026-08-30 -> 09-01: seven configuration runs, four refuted
theories, the causal spawn-tracking experiment, the race finding, the intermittency protocol) is
**resolved and user-confirmed** -- the cause was the nametag trio's stale component pointers,
never cleared by any release path. Confirmed entries: `VERIFIED.md` 2026-09-01. Transferable
lessons and the full method: `agent_docs/pitfalls/by-lesson.md`, "The reset-to-save crash". The
run-by-run hunt log is in this file's history at commit `be2763b`.

**Still open from that closure, filed here so it is not lost:**

- **The two reverted perf caches are UNBLOCKED.** They were reverted pending "a hook that fires
  on a same-level reload" -- the InitGameState PRE hook now IS that hook (it fired on every reset
  in the 2026-09-01 logs). Re-landing the controller cache (+1308 us/frame) and projectile pool
  cache (+~1200 us/frame) with their pointers cleared there is ~2500 us/frame waiting on an
  afternoon. See "What was REVERTED" above.
- **The earlier exe-side fault (+0x1CD9A60, five dumps) was never separately explained.** It is
  ATTRIBUTED to the same residue (a use-after-free crashes wherever the garbage points), and no
  crash of any kind has reproduced since the fix -- but if that address ever returns, it is its
  own bug and the attribution was too generous.
- **A LOG-VOLUME perf audit has never been run (user's standing priority, 2026-09-01: perf is
  high priority on all adapters).** The 2026-09-01 session log shows steady per-event
  `Output::send` traffic in normal play -- `bridge:` stats ~1/s, `CAMERA_TRACE`, per-redraw
  `TRACE remote` lines -- 475 call sites total, cost unmeasured. Measure with `perf_report.txt`
  before touching anything; Emerald's lesson was one line a second costing 7fps (console there,
  file here -- the file may well be fine, which is what the measurement is for).

### The PEER LADDER, first run (2026-09-01): linear to 50, superlinear above, and a wire bug at 150

**The definitive post-fix ladder (same day, all three fixes in, 0-150 with recovery) is in
`agent_docs/crowd-limits.md`'s Pseudoregalia section and the README's performance section — this
section is the first run's record and the findings that came out of it.**

**Rig:** one real client at the standing spot, `meshghost-fakeadapter -clients N` (idle orbiters,
no names), relay at 20Hz / `-max-clients=200`, `perf_report.txt` armed. Rungs 4 / 16 / 50 / 100 /
150. User's read at 50: *"started to drop fps quite a bit, but i guess its still better than what
1-2 ghosts were at before"* (pre-fix, ONE peer cost 144->70).

| peers | tick_total | remotes_loop | per-ghost | frames/2s (~fps) |
| --- | --- | --- | --- | --- |
| 0 | ~1.5 ms | - | - | ~287 (~144) |
| 4 | ~3.1 ms | 1.3 ms | ~330 us | ~276 (~138) |
| 16 | ~7.6 ms | 5.0 ms | ~310 us | ~175 (~87) |
| 50 | ~23 ms | 17.2 ms | ~344 us | ~61 (~30) |
| 100 | 59-94 ms | 43.5 ms | ~435 us | ~20 (~10) |

**Findings, in priority order:**

1. **`loop_tail` (the reflection-driven redraw) is ~80% of per-ghost cost at every rung**
   (~250-350 us/ghost). It is THE target for any crowd work: batching the reflected calls,
   caching resolved FProperty offsets per class, or a cheaper position write would move every
   row of the table at once. Unmeasured which of its calls dominates -- perf-slot it first.
2. **Per-ghost cost RISES with population** (310 us at 16 -> 435 us at 100), and flat subsystems
   grew too (`ls_rest` 0.7 -> 4.4 ms at 100): reflection lookups appear to scale with total
   UObject count. So 150-peer numbers cannot be extrapolated from 16-peer measurements.
3. **150 peers found a REAL wire bug** -- `bufio.Scanner: token too long` on one synthetic core.
   Cause found in `transport.Send`: a write-deadline expiry mid-line left the connection open
   with an unterminated line, and every later Send appended to it. **Fixed 2026-09-01 (a failed
   write closes the stream connection), regression-tested (`TestFailedWritePoisonsConnection`,
   verified to fail against the old code).** The reconnect path takes over; what a 150-peer room
   looks like ACROSS a reconnect has not been watched.
4. **The empty-projectile-pool rescan was refilling at the sample cadence** -- 577 us/frame paid
   in every session where nobody ever fires. Fixed same day (interval-only rescan); the
   post-fix no-peer baseline should read ~950 us/frame and has not been re-measured.
5. **Ladder caveats:** all idle anim, one machine carrying game + relay + 150 cores at once.
   Engine-side pawn cost is inside the fps readings but outside the PERF numbers. (Fake peers DO
   carry nametags -- "fake-ghost-N" -- confirmed on screen at 150, so tag cost is included.)

**LIVE 150 (second attempt, wire fixed) found the next layer down: a DRAIN RUNAWAY (2026-09-01,
fixed in source, UNWATCHED).** With the relay fix in, all 150 peers joined clean -- and the GAME
spiralled: single ticks of 19s -> 33s -> 45s, 0fps, GPU idle. Cause read from the drain loop:
`game_thread_tick` replayed EVERY queued bridge line faithfully, so once one tick ran longer
than the arrival rate (150 peers x 20Hz = 3000 lines/s), the queue compounded -- and the backlog
replayed the whole session's spawn history in order, which the fingerprint probe measured as
**2051 player pawns alive at once** before the queued despawns caught up. Removing the crowd
left ~20fps of GC hangover from the two thousand corpses. The fix: latest-wins collapse -- the
drain now keeps only the NEWEST `render_remote` per player (lifecycle lines all still apply in
order), bounding a tick's work by peer count rather than by how far behind it got. **CONFIRMED
2026-09-01, same session: stable slideshow at 150 (bounded 250ms ticks, rig-starved), recovery
in seconds when the crowd leaves, and a reset-to-save restored max fps -- moved to
`VERIFIED.md`.** Crowd-rig calibration for repeats: ring **z = -545**, radius <= 200 at the
standing spot (pawn-center ground is -733; -650 and -580 both left bodies partly buried).

### The TAIL SPLIT is READ (2026-09-01): `tail_sweeps` owns the redraw, and it is name-based reflection

**`plans.md` "Crowds that PLAY" step 1, done.** One 16-peer rung on the deployed instrumented
build, `perf_report.txt` armed, same rig as the ladder (relay 20Hz / `-max-clients=200` /
`-ghost-collision=disabled`, `meshghost-fakeadapter -clients 16` orbiting the ZONE_LowerCastle
standing spot at ring z=-545 radius 200, idle anim, one machine). Four consecutive 2s report
blocks, all agreeing within a few percent; the table is one of them (15:07:28, 186 frames/2s
= ~93fps).

| slot | us/frame | per ghost | share |
| --- | --- | --- | --- |
| `tick_total` | 6911 | - | 100% |
| `remotes_loop` | 5225 | 327 us | 76% of tick |
| -- `loop_tail` | 4182 | 261 us | **80% of the loop** |
| ---- `tail_sweeps` | 2828 | 177 us | **68% of the tail** |
| ---- `tail_light` | 1349 | 84 us | 32% of the tail |
| ---- `tail_posetrc` | 2 | 0.1 us | ~0 |
| ---- `tail_events` | 0 | 0 us | ~0 |
| `local_state` (flat) | 1252 | - | 18% of tick |

**The four sub-slots sum to `loop_tail` with no unattributed remainder** (4179 vs 4182), so the
split is complete: there is no hidden fifth cost inside that span.

**The finding: two of the four blocks are free and one is the whole target.** Pose-trace and
event mirrors cost nothing measurable; the optimization is `tail_sweeps` (the visibility /
outline / custom-depth sweeps), with `tail_light` a real second at half its size.

**And `tail_sweeps` is exactly the shape the step-2 cache was designed for**: read of
`Plugin.cpp` 17742-18120 shows it is `GetValuePtrByPropertyNameInChain<...>` all the way down --
`bVisible`, `bRenderCustomDepth`, `VisualMesh`/`WeaponMesh`/`LightMesh`, `RootComponent`,
`AttachChildren` -- a name lookup per component per ghost per tick, plus a `TFieldRange`
property walk over each outline target's class. That also explains ladder finding 2 (per-ghost
cost rising with world population): name-based resolution scales with what it has to search.

- **Unwatched by the user; these are the agent's own numbers**, and nothing visual was judged
  while `perf_report.txt` was armed. It is STILL ARMED in the Steam install -- disarm before any
  visual session, re-arm for step 2's before/after.
- **Step 2 is now unblocked and aimed**: cache the resolved (UClass*, name) -> offset, clear it
  where every other cache is cleared (the InitGameState PRE hook). Expect it to move
  `tail_sweeps`, not `tail_light`; verify with a normal 2-ghost session watched for visual
  regressions, then re-run rungs 16/32/100 against this table.

### Step 2, the REFLECTION-PROPERTY CACHE: built, deployed, measured -59% tick -- UNWATCHED (2026-09-01)

**All 376 `GetValuePtrByPropertyNameInChain` call sites now go through a (UClass*, name) ->
FProperty* cache** (`Plugin.cpp`, `g_property_cache` beside the controller/projectile caches,
cleared with them in `release_all_ghosts` -- LoadMap PRE / InitGameState PRE / the Reset click).
Behaviour-preserving by construction: the cached FProperty* is the exact pointer UE4SS's own
chain walk returns, and the miss path calls that same function. Misses are cached too.

**Measured on the same 16-peer rung, minutes apart, same rig and ring** (before = the step-1
table above; after = four agreeing 2s blocks, 15:16-15:18):

| slot | before | after | change |
| --- | --- | --- | --- |
| `tick_total` | 6911 | 2824 | -59% |
| `remotes_loop` | 5225 | 1548 | -70% (327 -> 97 us/ghost) |
| -- `loop_tail` | 4182 | 959 | -77% |
| ---- `tail_sweeps` | 2828 | 829 | -71% |
| ---- `tail_light` | 1349 | 125 | -91% |
| `local_state` | 1252 | 851 | -32% |
| `ls_rest` | 1197 | 803 | -33% |
| frames/2s | 186 (~93fps) | 266 (~133fps) | +43% |

At 16 peers the game now runs ~133fps against a ~143 solo baseline. Log clean over the run: no
warnings, no lookup failures, 16 nametags drawn every frame, `send_fail=0 lines_malformed=0`.

- **The step-1 prediction was HALF WRONG, on the record:** it said the cache would move
  `tail_sweeps` and leave `tail_light` roughly alone. `tail_light` fell hardest (-91%) -- it was
  name-lookup bound too, not doing distinct work. The flat blocks moving (-32/-33%) is why
  converting every call site paid, not just the named block.
- **User's first read, 2026-09-01, after a reset-to-save (which exercises the cache-clear path)
  and a 2-ghost session with perf disarmed: *"think everything look and works fine"*.** Hedged
  with "think", so it sits here until it holds through normal play; the same session immediately
  found the melee-VFX gap below, which is a missing feature, not a cache regression.
- **Rungs 32/100/150 re-run same day: every rung ~2x faster, the population rise halved but
  survived** (97 -> 219 us/ghost across the ladder, was 321 -> 657; 150 rung dirty, ~114 live).
  Table and caveats: `../../agent_docs/crowd-limits.md`, "The property-cache re-run".
- **What the post-cache profile says is left, largest first (16 peers, us/frame):** `ls_rest` 929
  (flat), `tail_sweeps` 823 (the outline attach-tree walk per ghost per tick -- the per-call
  reflection inside it is now cached, the walk itself is not), `loop_pose_xf` 338, `local_state`'s
  other blocks ~50. The remaining `tail_sweeps` is ~51 us/ghost.

### The projectile-pool crash (2026-09-01): FIXED with FWeakObjectPtr, UNWATCHED under a real shot

**The user's game crashed (`EXCEPTION_ACCESS_VIOLATION` in `game_thread_tick`, the projectile
block) four seconds after they fired a charged shot** -- the pool cache re-landed that morning
held raw pointers to actors the game destroys on impact; full account and the new rule:
`../../agent_docs/pitfalls/by-lesson.md` (mid-level frees have no hook) and this adapter's
`CLAUDE.md`. Fixed same hour: the pool holds `FWeakObjectPtr`, `Get()` per use; `preflight` now
requires a `stale-safe:` annotation on every file-scope raw-pointer cache. Deployed to both
installs. **UNWATCHED: needs a session where a real charged shot is fired and hits something --
the exact sequence that crashed -- plus the peer-side projectile still rendering on a ghost.**

### The sword-throw cross-wire: CLOSED same day -- see VERIFIED.md 2026-09-01 (the flyer suite)

**Every symptom in this section was fixed and user-confirmed on two clients the same day**; the
record below stands as the investigation trail. Remaining opens: a throw across a map seam, a
reset mid-throw, and the ring/dust floor-drop (38) on non-flat ground -- none watched.

### (closed) The sword-throw cross-wire: CARRIER FOUND (2026-09-01) -- it was the thrown-weapon PROP path

**The subtraction that settled it: with `skip_ghost_weapon_prop.txt` armed on the WATCHING
client, the player KEPT their sword through a peer's throw+pickup (user-confirmed live).** Four
carriers were exonerated by measurement first: extras-cap state drops (relay drop-logging saw
none), a shared anim instance (identities distinct), `changeEquippedWeapon`-on-ghost and the
throw montage on the ghost (both flag-sampled clean). So the claimer is the mirror spawning a
real `BP_looseWeapon_C` and/or calling the game's `Change Weapon State` on it -- a singleplayer
game with ONE recallable sword keeping global loose-sword state fits exactly.

- **Next split is BUILT: `skip_ghost_weapon_state.txt`** keeps the spawn + position writes and
  silences only the state call. One watched round names the claimer precisely.
- **The stuck-in-air mechanism is CAPTURED numerically** (WEAPON_PROP_TRACE, 16:38): our position
  writes land (READBACK==RENDER) and by the next tick the actor is back at a FIXED point -- the
  spawned prop's own in-flight logic is a second writer fighting ours. TWO WRITERS ON ONE FIELD.
- **The likely endgame fix, not yet decided:** stop borrowing the game's gameplay-bearing class
  as a cosmetic prop -- reproduce the EFFECT (sword mesh, glow, embed pose) on an actor we fully
  own, which retires the cross-wire, the second writer AND the sinking in one move. That is the
  adapters/CLAUDE.md "reproduce the effect, never adopt the structure" rule; decide after the
  state-call split says which half claims.
- **NEW, user-observed: the sword-landing DUST plays at the GHOST instead of where the sword
  landed.** The `dl` one-shot row can only spawn at the ghost; dust born at a sword's landing
  point needs the sword position. Wants either suppression of sword-landing dust from the `dl`
  counter (sender-side attribution) or a positioned one-shot variant.
- **The whole loopback-era sword-throw record is demoted:** every 2026-08-15 "confirmed live"
  was loopback, where the cross-wire writes the player's own values back and is invisible.
  User, 2026-09-01: assume everything sword-throw is unverified with two peers.

### NEW (user, 2026-09-01): a ghost's MELEE ATTACK shows no VFX

**Found on a two-client session the same hour the cache was confirmed: *"we are not doing the a
vfx when using the melee attacks"*.** The ghost plays the attack montage (montage mirroring
ships); whatever the game spawns alongside a swing is not mirrored -- the same shape as the heal
waves and landing dust before their rows existed (`MIRRORED_EFFECTS` covers heal/chg/hw/hew/rsp/
dl/bb; nothing attack-shaped). MEASURED same hour (`probe_slashvfx`, six swings, all
identical): **`NS_PlayerSlash`, world-spawned at the player's x/y, +30 above the actor origin** --
and the same capture found `NS_FootstepDust` (world-spawned at the feet) equally unmirrored, filed
as a candidate, not added. **CONFIRMED on two clients, user 2026-09-01: "the slash works"
-- moved to `VERIFIED.md`.** Direction was not separately called out; the size-checked Rotation
write is the first suspect if a wrong-facing arc is ever reported. `NS_FootstepDust` stays here
as the filed candidate.

### The OPEN defect: ghosts freeze and vanish, one side only

**User-observed, twice, and NOT explained.** With two clients plus a synthetic peer:

- **Client1's view:** client2's ghost frozen; the fake peer still moving normally.
- **Client2's view:** client1's ghost frozen; the fake peer **not visible at all**.
- Trigger, in the user's words: *"it seems to happen when i move around a lot and do different
  stuffs on client2"*. Earlier in the same session: *"the ghosts also look really slow/laggy"* --
  that half was the rig, see below.

**So client2 stopped RECEIVING while client1 kept receiving.** A one-sided stall, not a rendering
bug.

**The mechanism for the flicker is known**, and it is not itself the bug: `core/remotes.go`'s
`tickRenders` renders whoever `remoteStatesAt(renderTime)` returns and **despawns everyone else**.
A peer whose samples stop arriving -- even briefly -- is despawned, and respawned when data
resumes. Client2's adapter logged **44 spawn/despawn cycles of the fake peer**, ~20/second. So the
flicker is a faithful report of a stream that keeps stopping; the question is why the stream stops.

**A relay failure mode exists that fits, but the one in the log was self-inflicted:**
`relay: pN is not draining its connection (256 messages queued) -- disconnecting it`. The instance
of it that night came from the agent killing cores, so it is a CANDIDATE, not the finding.

**What was NOT the cause, ruled out:** the cross-area filter (both sides reported byte-identical
`area_id`), and the relay dropping either client (both stayed joined throughout the observation).

**RESOLVED THE SAME EVENING, and it was the rig.** Reproduced on a clean rig -- shipped 20Hz relay,
no netsim, no stale cores, one synthetic peer, then both clients -- and it did not happen: the user
confirmed *"the ghosts didn't disappear for client1 this time"*, the adapters logged **0 and 1**
spawn/despawn cycles against 44 before, and the relay logged no stall. Run twice, once with the
dev-sweep gating off and once with it back on, so the gating is EXONERATED too.

**So the cause was the polluted session, not the code**: `meshghost-netsim` still in the path with
2% loss, and dead cores left in the room by the agent's own restarts (four members at one point,
two of them dead, rendering as frozen ghosts). Both are recorded under RIG HYGIENE below. The
mechanism note above still stands and is worth keeping -- a stalling stream really does read as
spawn/despawn churn -- but nothing here is a live defect.

### RIG HYGIENE -- three ways the agent's own rig corrupted the evidence

Written down because each one produced a symptom the user then had to judge:

1. **Both mods walk 8 bridge ports from the same base**, so a kill-and-restart loop reshuffled
   which game got which core, and stray mod-spawned cores appeared in the gaps. At one point the
   two games were CROSS-WIRED. Fixed by giving each install its own far-apart base (6700 / 6800).
2. **Killing cores mid-session leaves the dead sessions in the room** until the relay times them
   out -- at one point four members, two of them dead, showing as frozen duplicate ghosts. Any
   judgement made in that window is worthless.
3. **`meshghost-netsim` stayed in the path from 18:02 until 22:00 on 2026-08-30**, long after
   the interp sweep it was started for had ended (60ms latency,
   +/-25ms jitter, 2% loss), because the install configs still pointed at `127.0.0.2`. That is the
   whole explanation for *"the ghosts also look really slow/laggy"*, and it was the agent's fault
   for not resetting the rig when the task changed.

### What needs the user's eyes, none of it confirmed

1. **That the crash is gone** -- reload a save on a second client, the exact thing that died.
2. **That the freeze/vanish is gone, or reproducible**, on the clean rig.
3. **A ghost must still not glow** -- the light hold was rewritten under a confirmed fix.
4. **A ghost must not draw through walls during an attack** -- the outline sweep now walks the
   attach tree instead of scanning the level.
5. **The peer's thrown sword and ranged shot still appear** -- that block was edited and reverted.
6. **A hypothesis that is unproven and worth testing when the gating goes back in:** the ungated
   dev sweep called `call_set_visibility(component, true)` on anything of the ghost's it found
   hidden, so it may have been acting as an accidental per-tick RE-SHOW. If ghosts stop vanishing
   with the gating reverted, that is the answer -- and the fix is a cheap attach-tree restore, not
   a whole-world sweep.

---

## [OPEN] Pending — a NAMETAG SAT TOO LOW on a friend's machine, never reproduced here (2026-08-30)

**Reported second-hand**, which is the most important fact about this entry: *"nametag sitting too
low, it works fine on my machine. but on a friends machine they had one of the nametags appear
lower than intended"*. Nobody in this repo has seen it, and the person who did see it is not the
person reporting it — so both the symptom and the conditions are one retelling away from the
source.

**What is NOT a plausible cause, and can be ruled out by reading the code.** The tag is placed in
WORLD space: `tag_z = ghost actor Z + NAMETAG_HEIGHT_ABOVE_GHOST` (110 units, ~88 of which is the
standing capsule half). It is not a screen-space widget, so **resolution, DPI, UI scale, aspect
ratio and window mode cannot move it** — the usual "works on my machine" suspects are all
excluded by construction. That is worth stating up front, because it is exactly where an
investigation would otherwise start.

**So the height is only ever wrong if the GHOST'S ACTOR Z is wrong**, and this adapter has a fully
worked precedent for that: the slide, where the engine's own CROUCH path moves the mesh by
`-(capsuleHalf + 1)`. A ghost in a crouch/slide state, or one whose capsule differs from the
standing 88, puts the tag exactly this kind of low. A pawn mid-landing is the other shape.

**Questions the report has to answer before anything is measured** — each points at different code,
and guessing picks the wrong instrument:

1. **Whose tag was low** — the friend's own ghost as seen by them, or another player's?
2. **Was that character doing something** at the time (sliding, crouching, mid-air, landing), or
   standing normally? If it tracked a state, this is the slide problem again.
3. **Was it low permanently or only for a moment**, and did it correct itself?
4. **How many players were in the room** — "one of the nametags" implies three or more, and whether
   the others were correct at the same instant is the cheapest discriminator there is.

**Do not fix this with an offset.** A constant nudge to `NAMETAG_HEIGHT_ABOVE_GHOST` would hide a
wrong actor Z rather than fix it, and this adapter has removed exactly that bandage once already
(`BANDAGES.md` entry 1). `probe_nametag/` already exists and was what settled the colour work.

### Second report, same friend: RELOADING A SAVE REMOVES A REMOTE'S NAMETAG PERMANENTLY (2026-08-30)

*"after reloading to save it removed the nametag off the remote sybil, movement still replicated
correctly"* — relayed by the user, who read it as the name being **sent only once** and never
re-sent when a ghost despawns and respawns.

**The "sent once" half is true and is NOT the bug.** `remote_name` arrives once per peer, and the
mod stores it in `Plugin::nametags`, keyed by player id and kept deliberately OUTSIDE `remotes`
so it survives a peer having no ghost. A level reload does not touch that map, and the core
re-pushes every known name whenever an adapter attaches (`core/remotenames.go`,
`pushRemoteNames`). So the NAME is still in hand after a reload.

**What is not restored is the COMPONENT, and this is a code read, not a measurement.** The
LoadMap teardown (`release_all_ghosts`, the block that runs before a level is torn down) drops
`weapon_actor`, `vfx_components`, `projectile_component`, `recall_glow_component` and re-arms
every "already synced" latch — and **never touches `nametag_component`, `nametag_plate`,
`nametag_plate_mid`, `nametag_applied_name` or `nametag_create_failed`**. Those are raw pointers
to TextRender components the OLD level owned. After the reload:

- `update_ghost_nametag` opens with `if (!entry.nametag_component) { create... }`. The pointer is
  non-null — it just names freed memory — so **the branch that would build a tag on the new ghost
  never runs, and the peer stays unlabelled for the rest of the session** while movement, which
  goes through the newly spawned ghost, keeps working perfectly. That is exactly the reported
  shape.
- Worse, the tick then keeps CALLING through that stale pointer every frame
  (`set_text_render_string`, the position write). That is the same access-violation family as the
  three crashes this very block was extended to fix, and the comment there already predicted the
  next one: *"per-ghost state that outlived its ghost"*. This may be a live crash risk, not only a
  missing label.

**The fix is the same one-liner family: clear those five fields in that teardown block**, so the
next ghost builds its own tag from the name still sitting in `nametags`. Not written yet — the
netsim render sweep is mid-flight and a rebuild would cost the running session.

**How to confirm it on screen** (this is a claim about a running game, so it is not settled until
watched): two instances, both with names set, reload a save on one of them, and look at whether the
OTHER player's tag comes back over that instance's fresh ghost. The mod's own log line
`pid=N remote <id> nametag = "..."` tells you the name is still known, which separates "the name
was lost" from "the component was lost" without guessing.

**This does not explain the tag sitting LOW above** — different symptom, different mechanism. They
are filed together only because they are the same reporter and the same feature.

---

## [OPEN] Pending — LANDING DUST is not working properly, user-reported (2026-08-30)

**User-reported, live, on the two-instance netsim rig** (relay 20Hz no `-loopback`, both clients
through `meshghost-netsim` at 60ms/±25ms/2% loss/2% reorder, both installs at 250ms interp /
linear / no extrapolation, slerp on): *"landing dust not working properly"*.

**The exact fault is NOT recorded yet** — "not properly" could be absent, late, in the wrong
place, on the wrong character, or firing when nobody landed, and those point at different code.
Asked; this entry gets the answer written into it before anything is measured, because guessing
which one it is would pick the wrong instrument.

**What the row is.** Landing dust is one of the mirrored effect rows: `dl` ->
`/Game/VFX/Systems/NS_DustLand`, spawned on the ghost's `RootComponent` with a deliberate
`-GHOST_STANDING_CAPSULE_HALF` Z offset so it sits at the FEET rather than the actor origin
(`Plugin.cpp`, the mirrored-effect table). It is a **fallback** — a ghost that carries the game's
own dust keeps that instead.

**The two things already known to bite this exact row**, both worth checking before anything new:

- **The echo loop, fixed 2026-08-29 by excluding components we spawned, BY IDENTITY.** `dl` is a
  `world_spawned` row, and those are attributed purely by distance, so dust spawned onto a ghost
  standing near its own player used to be read as that player's own landing and sent straight back
  — *"that other player never jumped"*. If the symptom this time is dust on a character who did not
  land, this is the first suspect and the guard is where to look.
- **The netsim rig itself is new for this game.** Effects coupled to message ARRIVAL look correct
  on a clean loopback and wrong under jitter — that is the whole reason the two-rig doctrine
  exists, and this sighting is on the faulted link. So "it looked fine before" is not evidence
  against it.

**Do NOT start from theory.** `probe_dustlight/` already exists and dumps one census line per
character in a live two-instance session; the settled method for this class of question is to log
what actually spawned, on whom, and when, rather than reasoning from the table.

---

## [READY] The ghost's FACING is now interpolated, and nobody has watched it (2026-08-30)

**What changed.** A ghost's facing used to STEP at the send rate. Orientation is opaque to the
core by contract, so `core/interp.go` never interpolated it — it held the older bracketing
snapshot's value until render time crossed the newer one. At 20Hz that is 20 snaps a second, and
the visible error is angular velocity divided by Hz: a slow pan steps ~2 degrees and is invisible,
a fast spin steps ~18 and is not. That is the user's report exactly — *"a bit choppy/low fps at
20hz and 250ms when turning around fast but super smooth when turning around slow"*.

The core now names the pair it used and the fraction it rendered at (`orientation_from`,
`orientation_to`, `interp_t` on `render_remote` — bridge only, zero bandwidth, ADR 0043) and this
adapter interpolates the degrees triple itself, shortest-arc per component so yaw 350 -> 10
travels +20 rather than -340. `GHOST_ROTATION_SLERP`, shipped `true`.

**What to look at — a side-by-side spin.** Stand still and spin the character with the gamepad,
with a loopback ghost offset beside you (the standing dev setup). **Position never changes in this
test**, which is what makes it a clean read on facing alone.

**What correct looks like: the ghost's facing and the player's are indistinguishable at EVERY spin
speed.** Not "smoother than before" — the bar is 1:1, and the failure this replaces was only ever
visible at speed, so a slow-pan check proves nothing. Three things worth watching for specifically:

- **A spin that briefly goes the LONG way round** near the wrap point would mean the shortest-arc
  fold is wrong, and it is the one bug a plain lerp would give.
- **A facing that lags the body**, or leads it, during fast movement — that would mean rotation
  and position ended up on different clocks, which is the whole reason this uses the same bracket
  rather than the simpler chase-the-newest-value damper.
- **A ghost whose facing drifts while it is standing perfectly still.** Nothing should move.

**A/B is a flag flip:** `GHOST_ROTATION_SLERP = false` compiles the block out and restores the raw
field, byte-for-byte the old behaviour.

**Go side is confirmed with the tools** (full suite twice, `-race`, `internal/e2e`,
`core/orientbracket_test.go`) — that says the right two samples and the right fraction reach the
adapter, and says nothing at all about how it looks.

**A/B RUN 2026-08-30 — POSITIVE, AND DELIBERATELY NOT PROMOTED YET.** Three launches on the
loopback rig (relay `-loopback -send-hz=20 -ghost-collision=disabled`, install config 250ms /
linear / no extrapolation), flag on, off, on, nothing else changed between them. The user, on the
ON run first: *"it actually looks smooth now i think ?"*; then on the OFF run: *"it looked a bit
choppy/low fps in comparison"*; then back ON: *"now when im testing slerp again it just looks
'delayed' not bad/choppy"*, and *"so slerp is for sure doing 'something' better"*.

**Why that stays here rather than moving to `VERIFIED.md`:** every one of those is hedged — *"i
think ?"*, *"something"* in the user's own scare quotes. The bar is 1:1, judged as
indistinguishable from the local character at every spin speed, and *"doing something better"* is
not that. It sits here until the user says it plainly.

**THE FINDING THAT MATTERS MOST IS THE SYMPTOM SWAPPING, and it is not a new defect.** Choppy
became *delayed*. Those are different complaints about different mechanisms: the chop was the
facing STEPPING, which this fixed; the lateness is the 250ms interpolation delay doing exactly its
job, on both runs equally. **Slerp does not add delay — it very slightly REDUCES it.** With the
step, facing showed the older bracket until render time crossed the newer sample, so it was on
average about half a sample interval (~25ms at 20Hz) staler than the interpolated version is. What
changed is that the lateness became LEGIBLE: a choppy motion masks a smooth lag, and removing the
chop is what let the delay be seen at all. Expect this shape again on any future adapter — fixing
a stutter routinely "reveals" a delay that was there the whole time, and treating that as a
regression is how a good fix gets reverted.

**RE-CHECK NEEDED after the 2026-08-30 opt-in change.** The confirmation above was won on a build
where the core sent the bracket to every adapter unconditionally. It is now OPT-IN — the mod asks
with `interpolate_orientation` in its bridge `hello` — plus the core suppresses the bracket when a
peer's two orientations are byte-identical. Neither should be visible (the suppression provably
cannot change a pixel, and the opt-in is asserted end to end over a real bridge socket by
`TestHelloOptInReachesRenderRemoteEndToEnd`), **but the confirmed build and the shipped build are
no longer the same binary, so the confirmation does not automatically carry across.** One spin is
enough. **The tell if the wiring broke: the ghost's facing steps again exactly like the flag was
off** — check the CORE log for `adapter asked for interpolated orientation`, not the mod's own
HELLO line, which only proves it built the string.

**So the next question is a KNOB, not a bug**, and it is the one ADR 0040 shipped for exactly this:
`interp` (250ms here, never swept for this game — TEVI measured 175ms on 2026-08-28) and
`extrapolate`, which is off. Both are config-only in the install's `config.json`, needing a
relaunch and no rebuild. **`extrapolate` now covers rotation too** (`interp_t` above 1, ADR 0043)
and that half has never been on screen in any form.

---

## [DONE] DRAINED 2026-08-27 — the health bar, and the ghost that could damage the player

Both halves of what used to sit here were closed and user-confirmed the same day, so the entry is
gone rather than left to rot. Where each piece went:

- **The health bar stuck full** was the ghost's OWN HUD widget drawn over the player's, removed
  with stock `RemoveFromParent`. `VERIFIED.md`, 2026-08-27. The shared-singleton theory really was
  refuted, exactly as this entry argued — the value was never wrong, only the widget being looked
  at. The control-experiment pair that proved it was the user's own design and is recorded there.
- **The ghost damaging the player** was the game's own `hitActorsArray`, and the six candidates
  this entry had ruled out are each kept as a recorded negative in `FLAGS.md`. `VERIFIED.md`,
  2026-08-27.
- **`CurrentHp`'s own measurements** (max 80, 5 per pit fall, where it lives, why the HUD caches
  nothing) live in `PLAYER_FIELDS.md` and `documentation.md`, which is where a field belongs.

Left here as a one-time marker because the entry was cited from `status.md` while it was open;
delete it freely once nothing points at it.

## [OPEN] Pending — a BLACK FLASH when a ghost appears, cause unknown after two negatives (2026-08-27)

**User-reported:** *"'black flash' on the screen whenever a ghost appears, is this something the
ghost is taking/applying from the player as well when they spawn in? similar to the health hud/ui
thing?"* — the same frame that explained the camera rig, the HUD, the shadow and the damage.

**Not confirmable by eye, on the user's own account** — *"i can't really confirm, as its hard to
see/test"* — which is why both attempts were built to report on themselves rather than rely on
watching.

| Tried | Result |
| --- | --- |
| Stop the ghost's `Timeline_2`/`Timeline_3` (the pawn's fade timelines, named by the fade census) | **REFUTED by its own readback**: `IsPlaying` reported `not playing` on every ghost, every timeline. They were never running, so stopping them was cosmetic. |
| Neutralise a camera fade raised within 10 ticks of a ghost spawn (`GHOST_FADE_GUARD`) | **Armed on `StartCameraFade` and NEVER FIRED.** No camera fade is raised anywhere near a ghost spawn, so the flash is not a camera fade either. |

**Both negatives came from instruments rather than from the user squinting**, which is the part
worth keeping: an unconfirmable symptom was turned into two clean measurements.

**What is left to try**, in order of cheapness:
1. `enterTransition` is a Blueprint function on the pawn and cannot be hooked on this build — but
   what it TOUCHES can be watched. A widget added to the viewport would show up the way the ghost's
   own HUD did.
2. The ghost's `PlayerLight` / `PointLight` ChildActor components fire at spawn and were never
   examined; a light popping on for a frame can read as a flash.
3. Level streaming around the spawn, which nothing has looked at.

## [OPEN] Pending — the ghost FLOATS UP slightly during a melee sword attack — SEEN ONCE, never since (2026-08-27)

**User-reported, live.** While the peer swings the sword, the ghost rises a little.

**NOT REPRODUCED, and the user said so unprompted at the end of the same session:** *"i didn't
see/notice this later on, was just right when i mentioned it. never in any of the other tests or the
thing we tested now last."* Between that first sighting and the end of the day the ghost was watched
across roughly a dozen further runs — the damage A/Bs, the projectile work, the pit-fall captures —
with melee swings throughout, and it was never seen again.

**So the honest status is a single unreproduced sighting, not a live defect**, and it is left open
rather than deleted for two reasons. A one-off that nobody can reproduce is exactly what an
intermittent bug looks like early. And several things changed underneath it that same day —
`GHOST_BLOB_SHADOW_ARM_MIRROR` writes the ghost's spring arm every tick, `GHOST_PREHIT_PLAYER`
touches its hit list, and the collision experiments came and went — so it may well have been fixed
incidentally by one of them, which would be worth knowing.

**If it recurs, do NOT start from theory**: get the ghost's mesh Z and capsule half logged through a
melee montage first, the same measurement that settled the slide.

Not investigated. The specific thing to look at first: this adapter already has a fully worked
precedent for a ghost's Z going wrong during an animation — the slide, where the answer turned out
to be the engine's own CROUCH path moving the MESH by `-(capsuleHalf + 1)`, and where the first fix
was a render-Z bandage that has since been deleted (`BANDAGES.md` entry 1). A melee montage that
changes the capsule, or a mesh Z that is not being maintained while a montage plays, is the same
shape of problem and the same place to measure.

**Do NOT fix this with an offset.** That is precisely the bandage this adapter already removed
once, and the register records what it cost.

## [DONE] RESOLVED — "heal" IS healing; the table row is correctly labelled (2026-08-27)

Asked because `NS_Healing` bracketed every single charge across two runs, which fitted "the charge
has a body aura the game happens to have named NS_Healing" at least as well as it fitted "this is
the heal" — and in this game names have lied before (`AnimGraphNode_Trail` is cloth physics; Cling
Gem has no "glide" string anywhere).

**Answered by the user, who watched it**: the white particle effect appears *while healing*, not
only while charging. So the row is right and the mirror is correctly labelled. **The pairing in the
log was just what they happened to be doing** — heal, then charge — and reading a mechanism into it
would have been a wrong turn.

Worth keeping rather than deleting: the anomaly was real, the two readings needed opposite fixes,
and **the thing that settled it was a question a person could answer without naming an asset**.
That is cheaper than any probe and should be reached for first.

## [READY] Pending — the FRotator float/double fix is generalised, and the ghost transform path moved onto it

`write_struct_triple` + `write_vector_param` / `write_rotator_param` (`Plugin.cpp`) now carry the
version branch and inner-field resolution that the vendored SDK gets wrong for `FRotator`, and
**`call_set_actor_location_and_rotation` was migrated onto them in the same pass** rather than
leaving them unexercised. `BANDAGES.md`'s entry is updated.

**What to look at.** Nothing specific — that is the point. This is the call that puts every ghost
where it stands and points it where it faces, so **a ghost standing in the right place facing the
right way IS the confirmation**, in any session, without testing it on purpose. **What failure
looks like:** ghosts at the wrong position or spinning to a near-zero rotation — the original
denormal symptom — or a new `refusing to call it` warning in the log.

Behaviour-preserving by construction and it compiles, but neither is the standard this project
holds adapter changes to, so it sits here until a ghost is actually seen.

## [READY] Pending — ghost collision turned OFF again (2026-08-27), and it may cost the cling-gem VFX

`GHOST_COLLISION_ENABLED` is `false` again at the user's request, reversing the 2026-08-15
keep-it-on decision. No new evidence prompted it; the feature worked as described. Built and
deployed to the live Steam install the same hour, hash-matched.

**The flag is a real revert, not a decision-only gate** (`../../agent_docs/pitfalls/method.md`):
it turns `SetActorEnableCollision` to `false` and compiles out two `if constexpr` blocks
entirely — the `bCanBeDamaged` hurtbox disable and the Pawn-channel `Block` response. So the
melee-death hazard and the never-tested non-player-damage vector both stop existing while it is
off, rather than merely being unreachable.

**The risk this creates, and it is a real one.** The cling-gem (wall-ride) VFX is a *confirmed
working* ghost visual, and it was confirmed with collision ON. This file's own earlier reasoning
predicted that effect would be structurally blocked without collision, because `doWallRun`
depends on `wallRideHit`, a real geometry hit result a collisionless ghost cannot produce. That
prediction was then beaten — but by a `doWallRun` call made on a ghost that *had* collision. **So
nobody has watched the cling gem on a collisionless ghost, and it is the single most likely thing
to have just regressed.**

**What to look at.** A peer clinging to a wall. **What correct looks like:** the ghost still shows
the cling-gem sparkle, and it still stops when the peer leaves the wall. **What failure looks
like:** no sparkle at all on the ghost while the peer clings — which would mean the effect was
riding on collision the whole time and this is now a trade, not a free revert. Check
`WALLRUN_TRIGGER_TEST`'s `TRACE wallRide ghost` lines: `moveState entered 4, calling doWallRun`
still firing with no visible effect pins it on the precondition rather than the trigger.

Also worth a glance in the same session, for the same reason: the ledge-grab self-start behaviour,
which a 2026-08-15 run showed happens with collision off *too*, so it should be unchanged.

## [READY] Pending — the bridge port walk's SECOND-INSTANCE case is still unwatched (2026-08-27)

The walk itself now runs on every launch and is confirmed: autostart binds 7778 and connects
(`VERIFIED.md`, 2026-08-27), and the sweep's free-port test was rewritten from "did it refuse us" to
"can we bind it" after a measurement showed a closed loopback port on this machine is never refused
at all.

**What is still unwatched is the case the walk exists FOR:** a second game instance finding its own
core one port up while the first keeps 7778. Nothing this session ran two instances. Expect the
second to log `bridge connected on port 7779` with the first unaffected.

## [OPEN] Pending — a hard crash mid-session after the pause menu opened twice (2026-08-17)

**Not root-caused, and not attributable to MeshGhost on the evidence available.** Seen once. It is
here rather than in `VERIFIED.md` because nothing about it is established: not the trigger, not the
cause, and not whether this adapter is involved at all.

**What to look at.** A session with the pause menu opened and closed repeatedly, with a peer
connected. **What would settle it:** the same crash with the mod's `constexpr bool` flags off — and
per `../../agent_docs/pitfalls/method.md`, a flag flip only counts as a revert if it gates the
*work* rather than the decision the work feeds, so check the flag actually disables the cost before
believing an A/B. Bisecting real commits is the method that cannot be fooled here.

Recorded 2026-08-17 in `VERIFIED.md` as an observation, not a finding.

### ROOT-CAUSED for the 2026-08-27 recurrences — a projectile prop pointer, with a stack trace

The crashes during this session were **ours, and they are fixed**. The user captured the trace:

```text
UObject::ProcessEvent()
main.dll!call_destroy_actor()          Plugin.cpp:3928
main.dll!Plugin::release_ghost()       Plugin.cpp:6615
main.dll!Plugin::handle_bridge_line()
main.dll!Plugin::game_thread_tick()
```

The projectile mirror's first version spawned the game's own `PRJ_PlayerCutter_C` as a prop and held
the pointer. A thrown sword rests where it lands and nothing takes it away; **a projectile's
lifetime belongs to the game**, which destroys it on impact — so the release path asked a freed
actor to destroy itself. The mirror now holds only a Niagara component it created, and the user
confirmed *"no crash anymore"* on the same exit path that crashed twice.

**A liveness check does NOT close this class of bug**, and the comment directly above the crashing
line already said so: `IsUnreachable()` is only safe on an object that is still ALLOCATED. One was
added anyway before the redesign — a pointer that must not be held was treated as a pointer that
needs checking.

**The 2026-08-17 sighting predates all of this and is NOT explained by it.** It remains open, and
the probe-suspicion recorded against the earlier recurrence is withdrawn: the user ran menu
back/forth plus a quit on a probe-free build with no crash, and the crashes that did happen are now
attributed to the prop.

## [OPEN] Pending — a `Fatal Error!` on game exit, seen once, never root-caused

Distinct from the 2026-08-16 level-transition crash, which is fixed and confirmed. Seen once on
exit; no repro, no cause, no attribution.

**What to look at.** Whether it recurs at all on a normal quit. **What correct looks like:** the
game closes with no dialog. **If it recurs**, the UE4SS log from that run is the first thing to
read, before any theory — a mod framework's own error log is the cheapest evidence available and
this project has twice gone looking for a rendering bug that was a load failure.

### RECURRED 2026-08-27 — on exiting to the MAIN MENU, not on quitting

User: *"The UE-pseudoregalia Game has crashed and will close / Fatal error!"* — *"got this when i
exited out to the main menu"*. That is a level transition, which makes it adjacent to the
2026-08-16 transition crash (fixed and confirmed) rather than a straight repeat of the exit case
above; "exit" now covers two different actions and the entry should not be allowed to blur them.

**The log was read first, and it says almost nothing** (archived from that session). The last
adapter line is a ghost-spawn census at 18:59:08, then the ordinary bridge-stats line every ~0.7s
until it simply stops at 18:59:34. No warning, no unresolved name, no release path, no `LoadMap PRE`
line for the transition.

**Attribution is genuinely open, and this run is a bad witness.** Three probes were compiled ON
(`SHADOW_COMPONENT_PROBE`, `GHOST_PROJECTILE_WATCH`, `VFX_CATALOG_PROBE`), and the catalog probe
spawns Niagara components onto a ghost — a component whose owner is destroyed at a transition is
exactly the kind of thing that turns a teardown into a crash. But the same class of crash was seen
on 2026-08-17 with none of that on, so **the honest reading is "unattributed, and the next
occurrence must be on a probe-free build to be worth anything"**. Do not record a cause from this
one — `CLAUDE.md`'s rule about numbers gathered while a heavy probe was live applies to crashes as
much as to measurements.

## [OPEN] Pending — every probe under the three UE4SS mod directories predates this queue

`PROBES.md` indexes them (three directories, six scripts). They are the record of how each fact was
established, and several were run before this file existed — so the honest statement is that nothing
in this queue depends on them, and none of their logs is evidence for anything not already in
`VERIFIED.md`.

Kept as an entry so that the *next* probe run has somewhere to land before it is confirmed.

## [DONE] THE SCENE LATCH IS FIXED AND SHIPPED — moved to `VERIFIED.md` 2026-08-30; this section stays for the mechanism and the failed-fix table

**Final state**: all three light fixes are SHIPPED DEFAULTS (globals initialize true; the toggle
files are no longer read and were deleted from both installs). The full acceptance run — latch
gone, ghosts dark, blades clean, and a ghost crossing light-transition volumes disturbing nothing
with the overlap suppression OFF — is quoted in `VERIFIED.md`'s 2026-08-30 entry. What follows is
the mechanism and the night's negatives, kept because they are the record of HOW.

**What the latch actually was, measured down to refuting everything else first.** The glow
FOLLOWS the local player (user walked it: *"yes, even if client2 disconnect it still follows"*),
survives the peer leaving, and lives in NO reflected scalar — a clean latched-vs-baseline diff of
401 fields over the four transitions, the ambience actor, the manager (including its 32-slot
`IlluminatedComponents` count) and every vertex-light actor found ZERO differences. What remains:
the ghost's `BP_DynamicVertexLight_C` **registers with the light manager during `SpawnActor`**
(vocabulary: `Register`, and each light's `LightIndex` — player 0, ghost 1) and NOTHING
unregisters it; the stale registration (Intensity 0.5 / Radius 600, the exact values the destroyed
actor still holds) keeps being rendered at the player's own position, stacked on the player's dim
0.05. A registered-but-dead light is invisible to every actor-level read, which is why eleven
suspects and three whole-state diffs came back clean.

**The subtraction table, because five fixes failed before the one that worked:**

| Attempt | Result |
| --- | --- |
| Destroy ghost's light per-tick / in spawn tick | Ghost goes dark (bug 2 fixed); latch stays |
| Suppress via CDO `PlayerLight` template | NO-OP — `PlayerLight` is null on the CDO (2026-08-29's "latch fired through template suppression" was never a real test) |
| Suppress via `*_GEN_VARIABLE` archetype | NO-OP — no such archetype findable |
| MPC PlayerLocation guard / capsule overlap suppression / far spawn (+5000) | Latch stays through all three |
| Zero Intensity+Radius, push `InitializePrameters`, then destroy | Latch stays — the slot copies its values at Register time, inside `SpawnActor` |
| `FixDynamicLights` post-spawn / live on latched scene | NO visible change |
| **`FixAllLights` live on a latched scene** | **Glow vanished with the user watching, same second** |

**How it was found — the method, worth more than the fix**: when every scalar diff is clean,
stop diffing and dump the class's FUNCTION vocabulary (`LIGHTVOCAB`), then try the game's own
verbs one at a time on the live symptom via an edge-triggered toggle file whose CONTENT names the
function (`call_light_fn.txt`). The night's other permanent wins: `snapshot_scalar_properties`
now reads bitfield bools correctly through `FBoolProperty` (the old byte read printed ~30 manager
bools as uniformly true — the same wrong read suspected behind the two lying subtraction
toggles), and the user cloned the install (`Pseudoregalia - Copy`) so each instance has its OWN
`UE4SS.log`/toggles — simultaneous dumps from one shared log interleave line-by-line and
corrupted a whole sample before that.

**Resolved the same night (all four bullets that stood here):** the three fixes ARE the shipped
defaults (user: *"we should properly implement it"*); the parity question is answered — ghosts
never glow, like the blue outline — with the future mirror filed in `agent_docs/ideas.md`; and
the acceptance run ran with `guard_playerlocation` and `ghost_no_overlap` UNARMED: no latch, and
a ghost walking through light-transition volumes changed nothing, so neither is needed for
lighting and both stay dev-only.

**Still open:**

- The pickup cross-wire (below) is untouched by all of this.
- `FixAllLights` side effects outside `ZONE_Dungeon`'s dark rooms: unwatched (it runs on every
  ghost spawn, in every level).
- Every `<bool>` byte read OUTSIDE `snapshot_scalar_properties` (the `bVisible` sweeps above all)
  is still the bitfield-blind read — convert before trusting any of those subtractions again.

## [DONE] CAUSE FOUND 2026-08-29 (evening session) — BOTH light bugs are the ghost's `BP_DynamicVertexLight_C`, and this supersedes the whole section below it

**The two bugs the section below separates have ONE cause, watched live by the user through a
subtraction toggle.** This game's dark-area lighting is not lights at all: every pawn's
`PlayerLight` ChildActorComponent holds a **`BP_DynamicVertexLight_C`** — retro vertex lighting
that paints brightness into level geometry, invisible to every light/material/post-process census
(which is why eleven suspects died clean). The ghost constructs from the LOCAL save, which owns
the ascendant-light upgrade, so it is born with the whole kit ON. `GHOST_HOLD_LIGHT_OFF` held the
pawn's `PointLightComponent` at 0 the entire time — the wrong object.

- **Bug 2 (glow travels with the ghost): CONFIRMED FIXED on screen** — destroying each ghost's
  vertex-light child actor (`hide_ghost_playerlight.txt`) turned every ghost dark the moment it
  fired, both instances, user watching. Still toggle-gated, not shipped default.
- **Bug 1 (per-client scene latch on connect): the same actor, but destruction is TOO LATE by
  construction.** Measured escalation: per-tick sweep → latch fires; destroy in the SAME TICK as
  `SpawnActor` → latch still fires. The child actor's BeginPlay runs INSIDE `SpawnActor` and the
  scene keeps whatever it did. Current build (deployed, UNWATCHED) nulls the class template's
  `ChildActorClass` around our one `SpawnActor` call and restores it after, so the light actor is
  never created for a ghost. **The next connect-in-darkness run answers it.**
- **The blade shimmer is a THIRD component: `LightMesh`** (`StaticMeshComponent`, `M_SpiritAura`,
  gold 0.88/0.81/0.27) — the ascendant-light blade aura, named by the user's speedrunner contact,
  stuck visible on ghosts for the same born-from-local-save reason. **CONFIRMED gone on screen**
  with `hide_ghost_lightmesh.txt`. Also toggle-gated, not shipped.
- **OPEN — parity gap, user's call pending:** with the kill and the hide armed, a ghost can NEVER
  glow, including a peer who legitimately has the light (item, or post-pickup temp light — the
  user watched exactly that go missing). The proper fix is syncing the peer's actual light state,
  the observation-mirror shape the recall glow uses.
- **OPEN — the pickup CROSS-WIRE: a peer picking up their thrown sword drives the LOCAL player's
  pickup animation (and, pre-kill, the temp light) on the other machine.** Watched FOUR rounds:
  `changeEquippedWeapon` skipped, `updateWeaponEquip` skipped, and BOTH skipped — the cross-wire
  survived every combination, so **neither adapter call is the carrier**. Next suspect: the
  thrown-weapon PROP (a real `BP_looseWeapon_C`) being destroyed on the pickup edge — its own
  destruction/pickup logic reaching "the player". Untested. **Regression while split-testing:
  with EITHER call skipped the ghost's sword no longer leaves its hand on a throw** — the pair is
  load-bearing together (2026-08-15 confirmed them working as a pair); both restored.
- **THE LATCH'S REAL MECHANISM (measured down to the actor, 2026-08-29 late):** destruction at
  any speed failed (per-tick, same-tick, and template-suppressing the vertex light entirely — the
  latch fired through all three), and the MPC theory died the same way: `probe_namecensus` stage
  10 measured the live `MPC_PlayerRelated.PlayerLocation` holding the GHOST's position on both
  instances, a real theft — but a native pre-hook redirecting every write to the local player's
  position (`guard_playerlocation.txt`, watched rewriting 100+ times) did not stop the latch
  either. What is left, and what the stage-12/13 census supports: the level's lighting is run by
  **`BP_LightManager_C`** (an `IlluminatedComponents` map) fed by **`BP_LightTransition_C`
  trigger volumes**, and a pawn fires BeginOverlap for the volume it SPAWNS inside — the ghost
  spawns in the lit zone and transitions the whole scene. **Fix built and deployed, UNWATCHED:**
  `ghost_no_overlap.txt` flips the capsule template's `bGenerateOverlapEvents` off around our
  `SpawnActor` (the same CDO trick as the vertex light, because spawn-time overlaps fire inside
  `SpawnActor`). If confirmed, ghosts also stop firing encounters/hazards/save-point triggers —
  the same singleplayer assumption, everywhere.
- **The MPC PlayerLocation THEFT is real regardless of the latch** — the guard stays armed; what
  visual it owns (if any, now that the vertex light is dead) is unmeasured.
- **OPEN, new observation while testing: the ghost's thrown sword was never seen in the AIR** —
  it appeared only on the ground (glowing there, which matches the real one). May predate today.
- **Method note for the next subtraction that "matches 0":** the nametag toggle armed from BOOT
  works by never CREATING the tags (the updater is skipped), which is how it was finally
  eliminated by absence — while the same toggle flipped mid-session still matches 0 components,
  and the blob-shadow sweep matched 0 of 879 while `LightMesh` (name-containing, visible) sat in
  that class list. The `bVisible` byte read in those sweeps is the suspect. Two subtraction
  toggles still lie; do not trust either until this is fixed.

The census that found all of this is `probe_namecensus/` (deployed as `MeshGhostNameCensus`), and
the reloader can re-run it any time — it prints world inventories by class, `MPC_PlayerRelated`
(one parameter: `PlayerLocation`), per-mesh materials/flags, and the `PlayerLight`/`LightMesh`
pair. `PROBES.md` has the entry.

### This plan ran on 2026-08-30 and is DONE — kept only so its predictions can be checked against what happened

Step 1's latch test FAILED (overlap suppression was not the answer; the registration was), step
2's map read went through the count only (32 slots, unchanged latched-vs-clean — the values were
never needed once the vocabulary dump named `FixAllLights`), step 4's promotion and parity
question are both resolved (shipped defaults; ghosts never glow, mirror filed in `ideas.md`).
**Step 3 — the pickup cross-wire — is the one that remains open.** The toggle files named above
were deleted from both installs; three are no longer even read.

## [DONE] SUPERSEDED by the section above — kept for its measurements (2026-08-29, long session)

**Read the section above before touching the ghost-light problem again.** The entries further down
were written while the cause was still believed to be the ghost's `PointLight`; that belief is now
refuted, and each is kept only for the measurements it records.

### There are TWO bugs wearing the same clothes, and separating them is the session's main result

The user's own words, and the thing that finally made the reports consistent:

1. **A per-client SCENE LATCH.** When a peer's ghost spawns, the local client's whole scene flips
   to a lit state -- *"it got bright around client1 even before i could walk over there"*, from
   across the level. It **survives the peer leaving** and clears only when the player walks out of
   the dark area and back in. Solo play never shows it. The user's constraint: this **predates
   nametags entirely**.
2. **A glow that belongs to each GHOST.** With the local scene repaired by an area transition, each
   ghost is still lit and still lights the wall around it. It **travels with the ghost and dies
   with it** -- *"whenever a ghost disconnect, their glow goes away"* -- so nothing is left behind
   in the world.

Every earlier run confused these, because a subtraction judged while the scene was latched cannot
say anything about the ghost. **The clean setup is: both clients walk out of the dark area and back
in first.** Only then is a ghost-side subtraction worth anything.

### Ruled out by measurement, not by argument

| Suspect | How it was killed |
| --- | --- |
| The ghost's `PointLight` | Held at 0 within **4ms** of spawn (log-timed). `SetIntensity` resolved -- no warning ever printed. Forcing it back to 5000 changed nothing on screen. |
| The game re-lighting it | A per-tick hold with a re-light counter: **never once incremented**. |
| The ghost's model | Hidden entirely, in the clean setup. Walls still lit. |
| Materials / lighting flags | Player and ghost carry the same assets and parents (`MI_n64_Playergoat`, `MI_n64_PlayergoatFace`), same lighting channels, same shadow flags. |
| Material parameters | The only ones the game drives are `DieAmount` and `UVOffset`. |
| `bRenderCustomDepth` (the shading pass) | The single field that DID differ. Subtracted live via a toggle; no visible change. |
| Any other light in the level | A census of `LightComponent` **and every subclass** finds exactly two lights in the map: the two players'. The ghost's reads 0. |
| Camera post-process blend | Every rig not serving the local pawn zeroed, confirmed by log. Still glows. |
| Scalars on the local pawn | Diffed across the spawn: **two uptime timers**, nothing else. |
| Scalars on the shared GameInstance | Diffed across the spawn: **zero fields changed**. |
| The level's own post-process | Diffed across the spawn, struct interior included: **zero fields changed**. |

### NOT eliminated -- and two of them were REPORTED as eliminated when they were not

**This is the part to distrust in the older entries.** Two subtractions logged success and did
nothing, because they attributed components to a ghost by `GetOuterPrivate()`:

- **The nametag** -- reported `0 component(s) of 12` once a count was finally printed, while the
  user watched the tag stay on screen. An earlier version *also* had the nametag updater put the
  components straight back every tick.
- **The ghost's Niagara systems** -- same broken owner test, and that branch printed **no count at
  all**, so "particles are off" was said on the strength of a toggle flag and never measured.
- **The blob shadow** -- same, never actually switched.

`TextRenderComponent` and `NiagaraComponent` do **not** outer to the pawn the way the
property-held meshes do. **Name containment is the attribution that works here**, which is what
`GHOST_HOLD_OUTLINE_OFF` has used since it was written. The build committed at the end of the
session uses it and prints `N of M switched` for every subtraction.

**So the three live suspects are the nametag, the blob shadow and the ghost's particle systems**,
in that order -- the nametag being the brightest thing on a ghost, and the user's own early guess.
Note it cannot explain bug 1, which predates nametags; expect two causes, not one.

### The rig, and how to reproduce in one run

Relay + two instances; the mod starts its own core per instance (the port walk **did** work here --
6672 and 6673, unaided, which contradicts the "NO free port" entry further down). Then:

1. Client 1 into the dark area, client 2 connects and loads in -> bug 1 fires.
2. **Both** clients walk out of the dark and back in -> scene repaired, only bug 2 left.
3. Flip one toggle at a time and read the `N of M switched` line before believing anything.

### Dev toggles that MUST come out before this ships

`GHOST_CUSTOM_DEPTH_DEV_TOGGLE` and `PLAYER_STATE_DIFF_ON_GHOST_SPAWN` are both `true` in the
committed build. They gate `keep_custom_depth.txt`, `ghost_light_on.txt`, `hide_ghost_mesh.txt`,
`hide_ghost_shadow.txt`, `hide_ghost_nametag.txt` and `hide_ghost_fx.txt`, all read from beside the
DLL, plus a property diff on every ghost spawn. Harmless to a player (the files never exist) but
they are instruments, and `../../CLAUDE.md` says instruments ship off.

## [DONE] ONE ghost cosmetic the user saw wrong on screen (2026-08-28) — the LIGHT half only

> **The DUST half of this entry is DONE and user-confirmed (2026-08-29)** — four stacked defects,
> all fixed and watched on screen. It has moved to `VERIFIED.md`, "Landing dust on a ghost".
> Only the light half below is still open.

**These run the opposite way to everything else in this file.** The rest is "the agent believes it
works, the user has not looked yet". These two the user HAS looked at, and they are wrong. They are
here because they are open work with nothing measured yet, and nothing below is established.

**1. Landing dust fires on the wrong character's landing.** SHARPENED BY THE USER 2026-08-29, and
it changes the question: the dust fires *"whenever you land after jumping"*, the ghost *"doesn't
handle it on its own"*, so it *"just happens whenever the player does it, and gets replicated onto
the ghost at wrong times"*. First noticed on a TWO-INSTANCE session.

**So this is not a missing effect — it is an effect fired by the wrong character's landing**, and
the earlier framing here (never spawns it / spawns it invisibly / something strips it) was aimed at
the wrong three possibilities. The shipped `dl` row mirrors `NS_DustLand` as part of the `vfx`
STATE set, attributed to the SENDER by proximity; a one-shot burst delivered as resent state can
only fire when the receiver next reads it, which is not when the ghost is drawn landing (`interp`
is 250ms). Whether that alone accounts for it is the measurement, not the conclusion.

This is the shape `../CLAUDE.md` names outright — *reproduce the WHOLE effect, the animation and its
extras*. A jump is not just a pose, and Emerald's surf blob is the worked precedent: the state
looked done because the animation played, and the thing riders sit ON was a separate sprite nobody
had counted. So the first move is the one that file prescribes: **do the jump in the real game and
count what appears**, rather than reading the ghost's spawn path and reasoning about it.
`../../agent_docs/effect-investigation.md` is the method.

**2. Light / "ascendant light" level is being COPIED onto the ghost, and never should be.** User:
these *"should always be off for a ghost similar to the blue outline things"*.

Located further by the user 2026-08-29: it *"emits from the player itself, or maybe from the
ascendant light upgrade"*, and *"makes the game look a bit too bright when nearby other
ghosts/players"* — so the visible symptom is ADDITIVE. Each ghost carries its own copy of the
emitter and they sum, which means the brightness scales with how many peers are in the room and a
one-peer session understates it.

So this is not a value to mirror more accurately — it is a value to force off, in the same class as
the blue outline, and the outline's own history says how. `GHOST_HOLD_OUTLINE_OFF` in `Plugin.cpp`
is a per-tick **HOLD**, not a spawn-time write, and the comment there records why: the outline was
already disabled at spawn on `VisualMesh` and `WeaponMesh`, and the user still saw blue outlines
mid-attack, because the game re-enabled it. That was the **third** time in one session a spawn-time
write turned out to be the bug, after the blob shadow and the collision disable.

**So whatever writes this must be a hold too**, unless it is measured to be written exactly once —
and "the ghost looked right in one run" is not that measurement. Expect the same trap: set it at
spawn, watch it come back the moment the game touches the level again.

**Neither is diagnosed and neither has a fix.** No probe has been run for either, so there is no
number here to be wrong about later — which is the only good thing about the state of this entry.

**A probe now exists for both and has not yet been run** (2026-08-29): `probe_dustlight/`, indexed
in `PROBES.md`. It answers the light half by census — every light component and child actor on the
player and on each ghost, walked up BOTH the outer and the attach chain — and the dust half by
timeline, putting every Niagara/Cascade component's first appearance on one clock with every
character's `MovementMode` transition. The run is built around the user's own report: one instance
jumps, the other stands still, and a dust burst logged on the still instance is the defect caught
next to the landing that did not happen. Nothing here is measured until that log exists.

## [DONE] MEASURED 2026-08-29 — the ghost's PointLight is at 5000 while the player's is at 0

**This is an agent measurement, so it lives here and not in `VERIFIED.md`.** It was read out of a
live two-instance session in `ZONE_Dungeon` by `probe_dustlight/`, one census line per character:

```
PointLightComponent ... BP_PlayerGoatMain_C_2147482274.PointLight owner=PLAYER
  Intensity=0.0     AttenuationRadius=1000.0 bAffectsWorld=true bVisible=false bIsActive=false
  attach=SkeletalMeshComponent ....WeaponMesh
PointLightComponent ... BP_PlayerGoatMain_C_2147482218.PointLight owner=GHOST1
  Intensity=5000.0  AttenuationRadius=1000.0 bAffectsWorld=true bVisible=false bIsActive=false
  attach=SkeletalMeshComponent ....WeaponMesh
```

**Same class, same component name, same attach point — the local player's is 0 and the ghost's is
5000.** The component is a `PointLight` child actor hanging off `WeaponMesh`, not off the capsule
or the body, which fits Ascendant Light being a property of the weapon.

**This reframes the entry above it.** The value is not being *copied from the player* — if it were,
the ghost would read 0 too, because that is what the player reads. It is the Blueprint's own
DEFAULT, which the ghost is born holding and which nothing ever turns down, while the real player's
gets driven to 0 by the game's own logic. A ghost is spawned from the player's pawn class and then
never runs that logic. **So the fix is not to stop copying something; it is to write the light down
on a ghost that was born bright.**

**One trap visible in the same two lines**, and it is why this is not yet a fix: BOTH report
`bVisible=false` and `bIsActive=false`, including the one that is demonstrably lighting the room.
So neither flag is what makes this light visible, and an implementation that toggles either of them
will read as correct in a log while changing nothing on screen. `Intensity` is the only field that
separates the two characters, and the `ChildActor` beneath it was never inspected — the run died
before reaching the `ChildActorComponent` census.

**Also unmeasured: whether it must be a per-tick HOLD.** The entry above predicts one, by analogy
with `GHOST_HOLD_OUTLINE_OFF`. Nothing here tested it. Write it once, then watch whether the game
puts it back the next time it touches the weapon.

## [READY] BUILT 2026-08-29, NEVER WATCHED — the ghost's light is now held at 0

`GHOST_HOLD_LIGHT_OFF` in `Plugin.cpp`, built straight off the measurement above and deployed to
the Steam install. **Nothing about it has been seen on screen.**

**What it does.** Every `LIGHT_SWEEP_INTERVAL_TICKS` (30, ~5Hz) it takes every
`PointLightComponent` and `SpotLightComponent`, skips any already at `Intensity == 0` without an
engine call, attributes the rest to a character by walking **`AttachParent` upward** as well as
testing the component's own name, and calls the engine's `SetIntensity(0)` on the ones belonging to
one of our ghosts. A HOLD, not a spawn-time write, by analogy with `GHOST_HOLD_OUTLINE_OFF`.

**Three things it deliberately does NOT do**, each from a fact in the entries above:

- It never touches `bVisible` or `bIsActive`. Both characters' lights report both flags false,
  including the one lighting the room, so either toggle would read correct in a log and change
  nothing on screen.
- It never calls a UFunction on a component it has not attributed to a ghost. `FindAllOf` hands
  back class-default and half-torn-down objects, and calling into one is what crashed the session
  twice.
- It does not write `Intensity` directly. Brightness is render-thread state; the engine's own setter
  is what marks the render state dirty.

**What to watch for, and it is not a screenshot of one ghost.** The reported symptom is ADDITIVE —
the room gets too bright *near other ghosts* — so the check is a session with at least two peers
present, comparing how lit the room is against a solo run. A single ghost may never have looked
obviously wrong.

**FIRED on both ghosts, 2026-08-29, agent-measured.** A two-instance session on the user's own
machine (relay + a second core on bridge 6673, both instances in `ZONE_Dungeon`, p1 and p2 seeing
each other) logged it once per ghost:

```
ghost light: 'PointLightComponent ....BP_PlayerGoatMain_C_2147482039.PointLight' was at intensity 5000 -- holding it at 0.
ghost light: 'PointLightComponent ....BP_PlayerGoatMain_C_2147482082.PointLight' was at intensity 5000 -- holding it at 0.
```

So the attach-chain attribution reaches the component, the value it found is exactly the 5000 the
census measured, and neither the local player's light nor the level's was touched. **That is the
mechanism working, not the cosmetic fixed** — nobody has looked at the screen, and the additive
symptom is what the user has to judge.

**The user looked and could NOT tell, 2026-08-29** — *"unsure, its pretty hard to visually tell
where im at right now. i can go to another darker area later and test"*. So this is neither
confirmed nor refuted, and the reason is the test conditions, not the fix: the area the session
happened to be in was lit enough to swallow the difference. **The judgement is deferred to a dark
area, and until it happens this stays here.**

**A straight A/B is not available while the hold runs**, which is worth knowing before anyone tries
to build one. Anything that writes 5000 back for comparison is fighting a per-tick sweep that
re-zeroes it, so the two would just race. The honest A/B is two runs of the DLL — one built with
`GHOST_HOLD_LIGHT_OFF` false — and it costs a relaunch, so ask before assuming the dark-area look
alone is inconclusive.

**The readback is NOT done.** The hold announces once per component and is silent after, so a
light the game re-lights every frame and the hold re-darkens looks identical in the log to one
fixed on the first sweep. `probe_lightcheck/` exists for exactly that and is deployed — but
`RestartMod` cannot introduce a mod UE4SS did not load at launch (*"Could not find mod to
reinstall"*, measured the same day), so it arms itself on the NEXT game start.

**The log line is the other half.** On the first sweep that finds a lit ghost light it prints
`ghost light: '<full name>' was at intensity 5000 -- holding it at 0`, once per component. If that
line never appears, the sweep is not reaching the component and the attach-chain attribution is
where to look; if it appears repeatedly for the same component across a session, the game IS putting
the light back and the hold is doing the work the entry above predicted it might have to.

## [OPEN] THE PROBE CRASHED THE GAME TWICE — `probe_dustlight/` is DISABLED and must not be re-run as-is

**Both crashes were caused by the agent, during the user's session.** `Fatal error!`,
`EXCEPTION_ACCESS_VIOLATION` reading `0x20`, with a callstack ~15 frames deep inside UE4SS's own
Lua/reflection machinery and no game or `MeshGhostPseudo` frame in it.

**The subtraction is what makes it attribution rather than suspicion**, and it is three runs:

| Run | Probe loaded | Result |
| --- | --- | --- |
| 1 — start a new game | yes | crash at LoadMap |
| 2 — same, control | **no** | clean, played fine |
| 3 — hot-reloaded mid-session | yes (hardened) | crash within a second of the census |

**Run 3 localises it precisely.** The census prints one summary line per class in `LIGHT_CLASSES`,
and the log ends on the `LightComponent` summary having never printed a `ChildActorComponent` line
or any `LIGHTPROP` line. The next thing it would have done is walk every `ChildActorComponent` in
the world — reading `ChildActor`/`ChildActorClass` and calling `K2_GetComponentLocation` on each.
**That pass is the suspect, and `ChildActorComponent` should come out of the class list before this
probe is ever loaded again.**

**A guess that failed, recorded so it is not retried.** Between runs 1 and 3 the probe gained a
`usable()` guard that skips class-default objects and revalidates `IsValid`. It did not help. That
is one hardening attempt spent; `../../CLAUDE.md`'s rule applies — the next move is subtraction
(cut the class list down to the two rows that actually answered the question) and not a third guess
at what to guard.

**What the probe must give up to run again**: it went after two questions and a whole-world
enumeration at once, and it only ever needed the pawn's own components. The light answer above came
from two lines of its output. A version that enumerates a CHARACTER's components rather than the
WORLD's would have produced the same answer without ever touching an object it does not own.

## [OPEN] WATCHED LIVE 2026-08-29 and it FAILED — a second instance never starts its own core

**This is the first live look at Pseudoregalia's bridge port walk** (`status.md` had it as "built
but not yet watched"). Two instances of the game, one install, the shipped `config.json`
(`local_game_bridge` 127.0.0.1:6672). **Instance 2 never got a core**, and a human would have
called that "the second window just doesn't work".

The sequence, from `UE4SS.log`, all of it instance 2:

1. `14:09:08` — `using a MeshGhost core that was already running`, then
   `core on port 6672 cannot reach the relay (...) -- waiting on this core rather than walking; it
   retries by itself`. **Correct by design**: a core that cannot reach the relay is not a busy core.
2. `14:10:39` — the relay came up, instance 1's adapter attached first, and 6672 answered
   `busy: this core already has a game attached` — so instance 2 walked, as designed.
3. `14:10:40` onward, once a second, forever:
   `bridge not connected and the sweep found NO free port to start a core on -- every port in the
   range either answered or never refused. Autostart is idle, not broken-silently.`

**Ports 6673–6679 were free the whole time.** Nothing was listening on any of them; the second core
that eventually made the session work was started BY HAND on 6673 and bound it without complaint.

**So `spawnable_port()` said no while a free port sat one number up**, and the branch that prints
this is the one `Plugin.cpp` already calls out as having cost a session once. The 2026-08-27 fix
replaced "did the connect get refused" with "can we BIND it" for exactly this reason, and the
symptom is back in a different shape.

**Not diagnosed — and one structural detail is worth having before anyone guesses.** `BridgeClient`'s
sweep computes `have_spawnable_port` inside the same loop that connects, and **returns the moment
`try_port` succeeds**, so any sweep that finds a core leaves the spawnable answer false. That alone
does not explain step 3, where the busy port is skipped by its cooldown and the loop should reach
6673 — which is why this is written as a symptom, not a cause.

**The next measurement, and it is one line of logging, not a theory**: print per candidate port what
the sweep decided — index, port, `try_port` result, `refused`, `port_is_bindable`. Two instances
reproduce it in under a minute, so this is cheap. Do that before changing anything.

## [READY] Pending — `bb`, `hw` and `hew` got the one-shot counter treatment and were never watched (2026-08-29)

The dust fix moved every `world_spawned` row in `MIRRORED_EFFECTS` from presence-mirroring to a
counter, because they are all one-shot bursts and all lost repeats the same way. **Only `dl` was
watched on screen.** The other three changed behaviour in the same build and nobody has looked:

| Row | Effect | What to watch |
| --- | --- | --- |
| `bb` | `NS_BasicBurst`, the death burst | A peer dying twice in quick succession should burst twice. Note this row's standing risk: the record has it firing ~14x in ordinary combat, so proximity attribution can occasionally put somebody else's hit on a ghost. |
| `hw` | `NS_HealWave` | A peer healing twice in a row. Height is observed from the local player's own heal, so a watcher who has never healed uses the row's fallback (+100). |
| `hew` | `NS_HealEndwave` | Same, fallback +10. |

**What correct looks like:** each repeat produces its own burst, at the same height as before the
change, with no burst appearing on a ghost whose peer did nothing. **What a regression looks like:**
the echo returning on any of these — they share the exclusion set with `dl`, so a fault there would
show on all four.

**Also unwatched: the first-of-session baseline for these three.** Counters are now sent always, so
the first heal/death after joining should fire like any other. That was a real bug for `dl` and is
fixed by the same mechanism, but only `dl` was confirmed.

## [OPEN] LOGGED, NOT BEING FIXED — a ghost may be stiffer than the game's own model ("model wiggle", 2026-08-29)

**The user's own framing, and the reason this is filed as a question rather than a defect:** *"ik
we are doing all animations & vfx, but unsure if a model 'draggin itself out/wiggling a bit'
visually is due to low hz/interp. or actually something we are not syncing. not really visually
noticable as its minor but we might have a more 'static/stiff' model than what the game itself
does"* — and explicitly: *"this is not an issue i currently plan to fix if it is a thing, but just
something i want to log."*

**So the open question is not "how do we fix the wiggle" but "is there one".** Two candidate
readings, and nothing here distinguishes them:

1. **A sampling artifact.** The ghost is drawn from interpolated samples at the send rate, so any
   secondary motion the game produces per-frame is being resampled. That would make the ghost look
   *smoother or stiffer* than the player without anything being unsynced — the renderer's, not the
   adapter's.
2. **Something genuinely not mirrored.** This game's characters carry stock bone-physics dangle
   (`documentation.md` records `AnimGraphNode_Trail` as exactly that — cloth-style secondary motion,
   NOT the afterimage trail). Secondary physics is usually simulated locally per-actor and would
   need the ghost's own simulation running, not a synced value. If it is disabled or never ticks on
   a ghost, the ghost would be stiff while the player is not.

**Reading 2 is the one with a concrete first check**, and it is cheap: compare the player's and a
ghost's bone-physics/anim-dynamics components side by side — do they exist on the ghost, and are
they simulating? That is a census of two actors, which is precisely the scoped-enumeration shape
`probe_dustlight/` should have used and did not.

**Do not chase this by eye.** The user calls it *"not really visually noticable"* and *"minor"*,
which is the regime where a watcher confirms whatever they expect. If it is ever picked up, get the
two models' bone transforms logged over the same motion before forming a theory.

**Deliberately NOT scheduled.** Recorded so it is not rediscovered from scratch, and so that if a
future stiffness report arrives there is a dated note saying it was noticed on 2026-08-29 and left
alone on purpose.

## [READY] Pending — the WALL-KICK mirror v1: watched once, hedged, with two stated limits (2026-09-01)

**What shipped.** A ghost's wall kick now plays both measured systems (six-kick capture via the
`probe_slashvfx` shape, logged in `UE4SS.log` 18:42): `wk` = `NS_WallKickHit`, the impact burst,
world-spawned one-shot on the counter path with observed-height learning (fallback 0 -- the
capture's 0..-72 offsets were measured against a player position logged up to one sample LATE, so
the true at-kick offset is near zero); `ks` = `NS_KickStab`, the flourish, attached to the ghost's
`VisualMesh` at the measured constant rel (10, 100, 85) -- the first attached row with an offset
(`MirroredEffect::attach_offset_*`).

**The user's one look:** *"think wall kicks look good enought now, hard to tell if anything is
wrong"* -- a hedged positive, kept here rather than promoted until it holds through normal play.

**Two limits stated at build time, not discovered later:**
- **`wk` spawns centred on the ghost, not pushed to the wall face** (~40-100 units sideways in
  the capture). Unlike the heal waves that offset IS knowable -- a world-frame delta the sender
  could ship in extras beside the counter -- so if the placement ever reads wrong on screen,
  that wire-carried offset is the upgrade. Do not guess it from the performer's yaw.
- **`ks` is a presence row, so two kicks in one active window re-burst once** on the ghost
  instead of twice -- the same shape the dust had before counters. Promote it to a counter only
  if that is ever seen to matter.

**Also unwatched:** both rows' first-of-session baseline behaviour, and `wk` on a watcher who has
never wall-kicked (fallback height, no learned value).

## [OPEN] OPEN — the thrown sword still SNAPS occasionally mid-arc, cause unattributed (2026-09-01)

Survived every change made tonight, which is what makes it worth its own entry: seen at the old
EMA renderer, at the segment glide, and AFTER `WEAPON_SNAP_DISTANCE` was raised 400 -> 1500 (so
that constant is exonerated as the cause -- it was ALSO wrong, first session to enforce it, but
fixing it did not remove the symptom). Final user state: *"now it just snap/teleport a bit"*,
accepted as good enough for now on the ocean-profile link (5% loss).

Next suspects, in order, none measured: (1) a loss hole longer than the segment's 400ms duration
clamp makes the glide sprint the whole hole's distance in 400ms -- reads as a lurch/snap; (2) the
`weapon_thrown` flag flickering across a suppressed/lost sample re-primes the renderer (a re-prime
IS a deliberate snap); (3) a genuine target jump. A one-line log at the snap site (gap length,
distance, primed state) settles all three in one throw session; measure before theorising.

## [OPEN] FILED — a smooth ghost tumble needs SENDER-side spin data; receiver-side guessing is exhausted (2026-09-01)

Three rotation renderers were watched in one evening (full verdicts: `VERIFIED.md`, the
2026-09-01 evening entry; mechanism comments at the render site in `Plugin.cpp`). The conclusion
is information-theoretic, not a tuning matter: at 15-20Hz a fast tumble turns more than 180
degrees between arrivals, so its direction and turn count are simply not in the data -- shortest
-arc under-rotates and sometimes reverses, unwrapping runs away. If 1:1 spin is ever wanted, the
SENDER must ship the spin (rate or phase) in extras, where it knows it exactly. Until then
write-through is the settled state and matches the game's own deliberately steppy spin.

## [READY] Pending — every peer-named asset now resolves through the CATALOG GATE, built and unwatched (2026-09-01)

**What changed.** The 2026-08-27 ACE audit's "a peer can NAME a thing" gap is closed, and it had
grown since the audit: five resolve sites, not one -- `target_montage` (play + divergence-restore),
`target_outfit_mesh`, `target_weapon_glow`, `target_projectile_vfx` -- each fed a peer string
straight to `StaticFindObject`. All five now go through `resolve_peer_named_asset` (`Plugin.cpp`):
the peer's string is a key into a set of the LOCAL game's own loaded assets of the right class
(class-scoped `FindAllOf`, rebuilt at most once per 10s and only on a miss), and on a hit the
global lookup runs on the catalog's own copy of the string. A miss is a refusal. Closes both
residual risks: a peer naming loaded-but-wrong assets of the right class is unchanged (parity --
same class, same game), but the garbage-name-spam perf lever (one global object lookup per
message) is now one hash lookup, and nothing peer-controlled reaches `StaticFindObject` at all.

**Why not an allowlist:** the montage mirror is deliberately generic (the sender ships whatever
montage is playing -- capability parity), and a hand list breaks the next montage nobody thought
of. The catalog IS the game's own list, mods included, maintained by the game.

**What to watch, one session:** montage mirror (throw a sword, ledge-hang), outfit swap, landed
sword glow, the ranged shot -- all four must look exactly as before; any of them missing is the
gate over-refusing and the log will say which name missed. **Known edge, stated up front:** an
asset first LOADED mid-session resolves up to ~10s later than before (the miss-triggered refresh
is rate-limited); outfits retry and self-heal, but a montage played within seconds of its first
load this level could skip once. If that is ever seen, the fix is a cheap targeted refresh on the
montage path, not a loosening of the gate.

**Mod compatibility, asked by the user and answered from the code:** unchanged. The old path had
no LoadAsset fallback -- `StaticFindObject` also only ever found loaded objects -- so "same outfit
mod on both machines" worked before and works now (the catalog is YOUR game, mods included), and
"a mod only the peer has" never worked on your screen either way; the refusal is just explicit now.

## [READY] Pending — three input bounds from the 2026-09-02 adversarial review, built and deployed, unwatched

`Plugin.cpp`, three changes, all of the shape "a peer's field reaches the game unchecked" (ADR
0044, `docs/security.md`). Built with `build-pseudoregalia.bat` and deployed to both installs
2026-09-02; nothing has been watched since.

- **`afterimage_n` is clamped to 1..64, else 6.** A peer's value was written straight into the
  pawn's `afterImagesToSpawn`; only `<= 0` was corrected. What to watch: a slide still spawns the
  same afterimage burst as before (the sender's real count is 6 on every build seen, well inside
  the bound), and nothing about the trail looks different.
- **A non-finite `orientation` is zeroed** on the raw (non-bracket) path. Only reachable from a
  peer sending `1e999`; a normal session cannot tell the difference. Nothing to watch beyond
  "ghosts still turn".
- **Nametags are capped at 1024 remembered peers**, evicting names with no live ghost when full.
  A normal session never reaches it. Nothing to watch beyond "names still show".

Regression on the Go side (`core/roster_cap_test.go`) bounds how many ids a relay can announce at
512, so the "unbounded pawn clones" finding is closed above this mod rather than in it.

## [OPEN] Four items that need a real two-machine session, carried out of `status.md` (opened 2026-08-16/17, moved 2026-09-02)

Two real players on two machines were confirmed on 2026-08-16 (`../../agent_docs/verified.md`), and these
four were written down that week as needing re-judging once a peer's state genuinely differs from the
local player's — which loopback can never show. None has been looked at since; each keeps its original
pointer.

- **Ghost collision: answered as a setting, not a yes/no.** ADR 2026-08-19 in `architecture.md`
  makes it a host-set room policy with a one-way client override; decided, not implemented.
- **Killing a ghost leaves the player respawning at 0/empty health** — player melee only; the HUD
  is fine, the value isn't. Suspect shared health state. `verified.md` 2026-08-17.
- **Ghost vanishes while a peer is on a pole**, then returns stuck in a climb pose. Cause unknown,
  two suspects ruled out; `phase7.md`. (Pole *rotation* was the separate item, cleared 2026-08-16.)
- **A thrown sword near a save crystal.** Suspected a loopback-offset artifact rather than a real
  bug; a two-machine session settles it. `verified.md`.

## [OPEN] MEASURED 2026-09-04 -- the cleanup HIDES rather than destroys, and ~2 components per despawn stay resident

**The visible half is confirmed and lives in `VERIFIED.md`.** This is the half that a player cannot
see and the agent's own log gave away.

### What the instrument said, against the fix that had just shipped

`VFXCLEANUP release_ghost: 0 world-spawned component(s) destroyed, 0 already gone.` — on all seven
despawns of the session, including the one the user watched clean up correctly. The teardown hides,
stops, then destroys, and **hiding is what removes something from the screen**, so a clean floor
proves only the first step ran.

**The counter could not even tell which had happened**, which is the more embarrassing half: a live
component whose `DestroyComponent` does not resolve incremented NEITHER counter, so "0 and 0" was
consistent with "the path never ran" and with "it ran and destroyed nothing". `_template/probes.md`
already says a report that cannot be sanity-checked is not a report; this was shipping code.

### The population census, and the one thing it rules out

`probe_leakcount/`, through the new scratch slot, over three despawn cycles driven by restarting the
core:

| | start | peak | after 90s idle |
|---|---|---|---|
| `NiagaraComponent` | 61 | 74 | **67** |
| `BP_PlayerGoatMain_C` | 1 | 4 | **1** |

**The ghost PAWNS are collected** — 4 down to 1 on GC's own schedule, so the user's *"might be the
same like ghosts being stuck in garbagecollection after leaving?"* describes the mechanism exactly
and it resolves. **The effects do not**: about two per despawn, still there after 90 seconds idle.

**Not proof, and the reason is worth keeping:** the game spawns and retires its own Niagara
components constantly, and 61 was one instant rather than a measured floor. What the census does
establish is that this is NOT a pawn leak, which is where a reader would otherwise look first.

### What is written and waits on a rebuild

The cleanup line now reports `N candidate(s) -> X destroyed, Y hidden+stopped only (no
DestroyComponent on this build), Z already gone`. That distinguishes all three cases in one line,
and it is the reading that says whether the fix is "destroy does not resolve on Niagara here" (in
which case the shape of the fix changes -- `K2_DestroyComponent`, an auto-destroy flag at spawn, or
destroying up the attach chain) or something dumber, like a candidate list that was empty of the
things that matter.

## [OPEN] MEASURED 2026-09-04 -- `observed_world_offset_z` is re-learned from a burst that is standing still

**Found by the instrument added in the same rebuild as the fix it was meant to check** -- and it is
a different defect from the stranding it was written to investigate, which is the reason it is its
own entry.

```
VFXOFFSET 'dl': -61.3 -> -60.5 -> -49.2 -> -42.2 -> -24.0 -> +14.7 -> +30.6
    every reading from ONE component at a FIXED z=905.9, while the player fell z=966 -> z=875
```

**The value is assigned on every sample a world-spawned burst is alive, not once when it appears.**
A burst does not move; the player does. So the quantity being learned stops being *"how high above
the actor origin does the game put this effect"* and silently becomes *"how far is the player
currently above a burst that is standing still"* — and since it is file-scope and shared by every
ghost, one jump or fall through your own lingering dust rewrites the height every later burst uses,
on every peer.

**Ninety units of drift in one fall, with no ghost involved and nothing stranded.** So this half of
the wrong-height dust was never about the leak at all, and the tester's *"related to the height of
ghost sybil when it despawns"* has a sibling cause that needs no despawn.

**The fix:** learn it only when `newly_seen` is true — the one sample where the component did not
exist before, which is exactly when the effect is where the game just put it. That flag is already
computed one line above for the burst counter.

**BUILT, DEPLOYED AND WATCHED 2026-09-04 — confirmed ONCE, and the user's own hedge is kept.** Their
words after a session of jumping around a looping ghost: *"yee looks like the dust thing is fixed,
its only appearing where its intended/supposed to"*. **Held here rather than moved to `VERIFIED.md`
because a first positive reaction is not a settled one** (the standing rule after a reaction that
later reversed) — it wants one more session, ideally with somebody deliberately falling past their
own dust, which is the case that produced the drift.

**The instrument agrees, which is why the hedge is only about durability and not about the
mechanism.** After the fix every `VFXOFFSET` line cites a DIFFERENT component id and the values sit
in a -61..-75 band; before it, one stationary component dragged the shared value -61 -> +30 as the
player fell. Learning per burst is what it always claimed to do.

## [OPEN] MEASURED 2026-09-04 -- the cleanup's own log line reports numbers the code cannot produce

**A note on the entry above, because it changes what that evidence is worth.** `VFXCLEANUP ...: 0
world-spawned component(s) destroyed, 0 already gone` is **not a possible output of the function
that prints it**, and that was established by reading it line by line rather than by theorising:

- It returns BEFORE logging when the candidate list is empty, so a printed line means candidates
  existed.
- Every candidate then takes one of two branches: not in the live set (`++already_gone`) or live
  (hidden, stopped, and `++destroyed` if `DestroyComponent` resolves).
- **`DestroyComponent` DOES resolve on this build** — measured with `probe_leakcount/verbs.lua`,
  existence-only, no call: `YES` on every NiagaraComponent sampled, alongside
  `K2_DestroyComponent`, `SetAutoDestroy` and the rest.

So zero-and-zero cannot happen. **The leading suspect is now the LOG LINE, not the cleanup** — a
format call that mis-binds its arguments and prints zeros whatever the counters hold. That is worse
than the bug it was written to investigate: a diagnostic that always reads zero is indistinguishable
from a path that never ran, and conclusions were already being drawn from it here.

**What settles it, already written and waiting on a rebuild:** the line prints `wanted.size()` too.
If the candidate count also reads `0` while components are demonstrably being torn down, the
formatter is the liar; if it reads a real number, the branch logic is.

**An instrument-versus-instrument disagreement worth having in writing:** Lua reports
`DeactivateImmediate` as present, while the adapter's C++ `GetFunctionByNameInChain` concluded it is
absent on this same build and fell back to plain `Deactivate` (logged, 2026-09-04, and a whole
comment in `Plugin.cpp` rests on it). Two lookup mechanisms, one build, opposite answers. Neither is
established as right yet — and the C++ side's conclusion is load-bearing for the glow teardown, so
this is worth an hour before anything else trusts either lookup.
