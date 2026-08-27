# Pseudoregalia — compile-time flag register

<!-- line-cap: none -- register; size is the number of switches that exist. Why: agent_docs/claude-md-cap.md. -->

`Plugin.cpp` carries 58 `constexpr bool` switches. They look alike and they are not alike, and
mistaking one class for another has already cost this adapter real time — most recently 2026-08-17,
when three load-bearing pose flags were read as leftover debug switches because their comments
still said "OFF" from a sweep that had been reverted.

This file is the index: which flag is which kind, what the shipped value is, and which ones you
must not touch alone. It is not a description of how the game works — that is `documentation.md` —
and not a list of compensations, which is `BANDAGES.md`.

**Keep it in step with the code.** If you add a flag, add its row. If you flip one, fix its row in
the same edit. A register that disagrees with `Plugin.cpp` is worse than no register, because the
whole point is to be the thing you trust when a comment and a value disagree.

## The three kinds

| Kind | Shipped value | What it means |
|---|---|---|
| **Behaviour** | `true` | Real shipped behaviour. Turning it off changes what a player sees. |
| **Probe** | `false` | A diagnostic: tracing, dumping, or measuring. Off in every build a user runs. |
| **Dormant** | `false` | A recorded negative or a retired approach, kept as evidence and as an instant revert. |

**Compile-time bools are not the only switches here.** `Plugin.cpp` also carries ~40 `constexpr`
*numbers* that decide behaviour — hold windows, guards, offsets, thresholds. They are registered in
"Tunable constants" at the bottom, because a wrong number is as load-bearing as a wrong bool and
far easier to "tidy".

## Behaviour — the 16 that are `true`

Everything here ships. The value in the code is the value a player gets.

### The pose cluster — **five flags that only work together**

`GHOST_SLIDE_TIMELINE_DRIVE` · `GHOST_CROUCH_INPUT_CALL` · `GHOST_CROUCH_EVENT_CALL` ·
`GHOST_CAPSULE_MIRROR` · `GHOST_BASE_TRANSLATION_OFFSET_MIRROR`

Plus `GHOST_CROUCH_CLEAR_ON_STAND`, which clears the pose again on stand-up.

**Do not switch any of these off individually.** Every single-mechanism test in the investigation
was negative, and the working configuration is the *union* of them. On 2026-08-17 the last three
were switched off as "redundant now the Timeline drives the pose" and the ghost went straight back
into the floor; turned back on, the poses were correct again. Alone-negative does not mean useless
when a system has preconditions — that is the whole lesson of this investigation, and it is also
`CLAUDE.md`'s "try the untested COMBINATION" rule, learned here.

The full reasoning lives in the comments above each flag in `Plugin.cpp`, in
`agent_docs/phases/phase7.md` (7.8), and in `README.md` steps 43-44.

### The rest

| Flag | What it does |
|---|---|
| `SPAWN_BASED_GHOSTS` | Ghosts are spawned actors, called from the real game thread. `false` reverts to the older hijack-a-StaticMeshActor design, kept in case the world-leak crash ever reproduces. |
| `GHOST_DESTROY_ON_DESPAWN` | A despawning ghost is destroyed (`K2_DestroyActor`) instead of being flung to `DESPAWN_PARK_Z`. Turned on 2026-08-17 once the premise for parking went stale: the "destroy silently no-ops" finding was a property of the *hijacked* actor, not of the build, and since Phase 7.6 the ghost is one we spawned. Falls back to parking when the call is not reflected, so the worst case is today's behaviour plus a log line. **The one thing it cannot rule out by itself is the historical "Fatal world leaks detected" crash** — see `BANDAGES.md`'s entry 0, whose whole argument rests on this flag being `true`. Note `DESPAWN_PARK_Z`'s own comment still says "NEVER destroy the actor": that comment is stale, and the value here is what wins. |
| `GHOST_COLLISION_ENABLED` | **`false` since 2026-08-27 — ghosts are NOT solid.** It was on from 2026-08-15 as a deliberate feature; the user asked for it off again, with no new evidence against it. The flag gates the *work*, not just a decision: `SetActorEnableCollision(false)` plus two `if constexpr` blocks (the `bCanBeDamaged` hurtbox disable and the Pawn-channel `Block` response) that compile out entirely, so this is a real revert. The melee-death hazard and the never-tested non-player-damage vector only exist while it is `true`. Note `Plugin.cpp`'s long comment above the constant still argues for keeping it on — that argument is intact but no longer in force, and the value here is what wins. |
| `WALLRUN_TRIGGER_TEST` | Ghosts trigger the game's wall-run. The feared self-propulsion (a ghost fighting its own network-authoritative position) did not materialise across three live rounds; the flag survives as the clean off-switch if a real remote peer ever shows it. |
| `AFTERIMAGE_TRIGGER_FROM_OBSERVATION` | The blue trail fires on the game's **own** observed afterimage spawns, not on any reconstructed rule. Three `actionState` theories and the capsule-shrink fact were all disproven live before this. |
| `AFTERIMAGE_OBSERVE_COLOR` | Reads the trail colour from the real effect rather than guessing it. |
| `AFTERIMAGE_OBSERVE_SPECIAL_TRIGGER` | Additive: fires only where the existing trigger found nothing. Not the old `AFTERIMAGE_TRIGGER_OBSERVED`, which replaced the trigger wholesale and scanned unconditionally. |
| `AFTERIMAGE_REQUIRE_SPAWN_PROXIMITY` | Birth-proximity check, so a recycled pooled actor is not counted as a new afterimage. |
| `RECALL_GLOW_ENABLED` | Mirrors whether the real glow is present rather than reimplementing "empty-handed AND near a save crystal". Whatever rule the game actually applies is mirrored for free and cannot drift. |
| `STATE_SEND_TRACE` | **The one `_TRACE` flag deliberately `true` — do not "fix" it to `false`.** Logs the `area_id` and world position actually sent, every ~300 ticks (~5s). It is here because aiming any synthetic-peer rig needs both values from a live session (`cmd/meshghost-fakeadapter`'s `-center` and `-area-id`, which must match exactly or nothing renders), and on 2026-08-17 neither was readable anywhere — `dev-scripts/run-ghostload-pseudoregalia.bat`'s own header tells you to read them "from the mod's log" and that line did not exist. Cost is one throttled formatted line, no enumeration and no per-object work, so it is the same shape as the always-on bridge counter line rather than the per-tick enumeration the probe rule below is about. |

## Probes — off, and they must stay off

35 flags, all `false`. Names ending `_TRACE`, `_PROBE`, `_DIFF`, `_DUMP`, `_SEARCH`, `_WATCH`, plus
`VFX_CATALOG_PROBE`, `OBJECT_REFLECTION_DUMP`, `AFTERIMAGE_CALL_TEST`, `AFTERIMAGE_DISCOVERY`,
`DUMP_GHOST_SPAWN_VALUES`, `DUMP_VISUALMESH_FUNCTIONS`.

**The arithmetic, so a future audit can check it in one pass:** 58 `constexpr bool` in
`Plugin.cpp`. 16 are written `true` (Behaviour, above) and 41 written `false` — these 35 probes
plus the 6 Dormant entries below. The 58th is `MONTAGE_PROBES_SUPPRESS_ADAPTER_STOPS`, which is
**derived** rather than set (`GHOST_SELF_MONTAGE_PROBE || MONTAGE_CATALOG_PROBE`) and is therefore
false in every shipped build without being written so. Recounted 2026-08-18.

**`AFTERIMAGE_DISCOVERY` is the one probe with a standing "must stay off" of its own**: it fires an
afterimage on the ghost every ~3s by itself, which looks exactly like a trail bug. It is the rule
below in its most literal form — never leave a probe that *spawns* an effect enabled while judging
that effect.

**A diagnostic can break the thing it measures, and then every reading agrees with itself.** This
adapter produced the worst regression in the project's history that way (2026-08-16). The expensive
shape is per-tick enumeration on the game thread, especially with a name lookup or string
conversion per object — compare by pointer instead. Before believing any measurement, re-run with
the probe off. Numbers gathered while a heavy probe was live are retroactively suspect.

Never leave a probe that *spawns* an effect enabled while judging that effect.

**One `_TRACE` flag is deliberately on**: `STATE_SEND_TRACE`, listed under Behaviour above with
its reasoning. It is a throttled log line, not a probe, and an audit that flips it to `false` on
name alone breaks the ability to aim a synthetic-peer rig.

`MONTAGE_PROBES_SUPPRESS_ADAPTER_STOPS` is derived, not set: it is true whenever either montage
probe is on, and exists so a probe run does not fight the adapter's own montage stops.

## Dormant — recorded negatives and retired approaches

| Flag | Why it is kept |
|---|---|
| `GHOST_SLIDE_Z_COMP` | The `+43` render-Z bandage. Retired 2026-08-17 when the crouch path replaced it; the block stays gated off. See `BANDAGES.md`. |
| `GHOST_SLIDE_CALL` | Direct slide call — negative. |
| `AFTERIMAGE_COLOR_TEST_OVERRIDE` | Forces a colour, for proving the colour path independent of detection. |
| `AFTERIMAGE_TRIGGER_OBSERVED` | The first observed-spawn trail trigger, retired 2026-08-16. `false` is a **real** revert now that the enumeration it carried is gated too — the earlier A/B was worthless because only the counter increment inside the scan was gated while the scan itself still ran. Replaced by `AFTERIMAGE_TRIGGER_FROM_OBSERVATION` plus `AFTERIMAGE_OBSERVE_SPECIAL_TRIGGER`, which are additive rather than wholesale. |
| `AFTERIMAGE_COUNT_REUSE` | Counting pooled re-use as a spawn — a **recorded negative**. Added on the theory that the ghost's thinner trail came from missed spawns; a world census measured the opposite (the ghost produced roughly twice as many afterimages as the player while still looking thinner), so this only added spurious ones. Kept because the underlying finding — these actors are pooled and re-used, which is why none ever disappear — is real and is the mechanism a future effect would want. |
| `WEAPON_SYNC_INVERT` | Kept so a swapped weapon-sync polarity costs a flag, not a build. |

Two other flags follow that same "a swap costs a flag, not a build" idea — the crouch input tries
`_16` down and `_15` up, and logs which fired, because which Enhanced Input index is press and
which is release was never established.

## When a comment and a value disagree

Believe the value, then find out why the comment drifted before changing either. These comments
accumulate in layers — an "OFF, job done" line from one session can sit directly above a "BACK ON,
and switching it off is what broke it" line from the next, with only the constant telling you which
one won. That is precisely how the 2026-08-17 confusion happened.

**A flag flip is not a revert** — verify the flag disables the *work*, not merely the decision the
work feeds, or revert the commit instead.
[`agent_docs/pitfalls.md`](../../agent_docs/pitfalls.md#diagnostic-methodology) has the case behind it.

## Tunable constants — the `constexpr` NUMBERS

**A bool register is only half the switches.** `Plugin.cpp` carries roughly forty `constexpr`
numbers, and several of them decide behaviour as completely as any flag: a hold window, a guard,
an offset, a threshold. They are listed here for the same reason the bools are — so a number with
a measurement behind it is not "tidied" by someone who reads it as arbitrary, and so a number that
*is* arbitrary is not mistaken for a measurement.

**Three provenances, and the difference is what this table is for:**

| Provenance | What it means | May it be changed? |
|---|---|---|
| **Measured** | derived from a capture of the game, with the capture cited at the constant | only by re-measuring |
| **Sized** | chosen against a known rate or bound, with margin, and the reasoning written down | yes, if the bound it was sized against changed |
| **Tuned by eye** | adjusted until it looked right — the shape `BANDAGES.md` cares about | yes, and it should eventually be replaced |

**Where a constant lives matters too.** Most sit at namespace scope near the top of `Plugin.cpp`,
but **nine are function-local**, and they are cited elsewhere (`BANDAGES.md`, and the tables below)
by bare name, which reads as though they were file-scope. They are not, and a grep at the top of the
file will not find them:

- inside `Plugin::game_thread_tick()` — `SLIDE_CAPSULE_THRESHOLD`, `CROUCH_MOVE_STATE`,
  `SLIDE_REFIRE_INTERVAL_TICKS`, `SLIDE_REFIRE_WINDOW_TICKS`, `FLYING_MOVEMENT_MODE`,
  `IN_BUBBLE_MOVE_STATE`, `BUBBLE_MOVEMENT_MODE`
- inside `Plugin::ensure_ghost_spawned()` — `ECC_PAWN`, `ECR_BLOCK`, `ECC_WORLD_DYNAMIC`

**This paragraph named four of the nine until 2026-08-27**, and gave `game_thread_tick()` as the
home of all of them, which is exactly the failure it exists to prevent — so it now lists them, and
a constant added function-local is added here in the same edit.

### Shipped behaviour

| Constant | Value | Provenance |
|---|---|---|
| `SLIDE_SEAM_HOLD_MS` | `200` | **Measured.** A held slide is not one continuous crouch: across 53 transitions the standing gaps were bimodal — 14-153 ms (a seam between two repeats) then nothing until 244 ms (a real stand-up). 200 sits in the empty band with ~50 ms margin either side. If the game's slide duration ever changes, re-measure; do not nudge. |
| `GHOST_STANDING_CAPSULE_HALF` | `65.0` | **Measured** across 692 samples (65 standing, 22 sliding/crouching). Used only to ask "is the peer shorter than standing?" — never added to anything as an offset. |
| `SLIDE_CAPSULE_THRESHOLD` | `50.0f` | **Measured**, the gap between those two populations. Function-local. |
| `GHOST_SPAWN_CAMERA_GUARD_TICKS` | `10` | **Sized.** The post-spawn camera switch is measured at 2-3 ticks every time; 10 is margin, not tuning. It is also the surviving half of a deleted fight-back — see `BANDAGES.md` entry 2, which wants the fallback dropped, not widened. |
| `DESPAWN_PARK_Z` | `-500000.0` | **Sized** as "further below the playable area than any real level position", the mirror of `MIN_PLAUSIBLE_DISTANCE`. Now the **fallback** path only: `GHOST_DESTROY_ON_DESPAWN` is `true`. Its own comment still says "NEVER destroy the actor" and is stale. |
| `MIN_PLAUSIBLE_DISTANCE` | `100.0` | **Sized.** Refuse to spawn against a transform still near the origin — a real placed pawn is never that close to (0,0,0), so this reads "the engine has not placed this pawn yet", not a location. |
| `LOOPBACK_GHOST_OFFSET_X` | `150.0` | **Deliberate design decision**, dev-only, render-only. **Do not set it to 0 while `GHOST_COLLISION_ENABLED` is true** — tried 2026-08-15 and it immediately reproduced the Phase 7.4 bug where an overlapping ghost physically shoves the player. It is also real evidence about the collision feature: the "collision doesn't push me around" result was obtained *with* this offset, and real peers get none. |
| `LOOPBACK_GHOST_OFFSET_Z` | `0.0` | **Refused at any other value**, by the user, and `BANDAGES.md` records why: side by side at the same ground level is what makes pose and timing comparable. Tried at `220.0` on 2026-08-15 and it was worse — on a pole the ghost went out of frame entirely. Kept named because it is the right tool for a horizontal orbit. |
| `SPAWN_DELAY_TICKS` | `0` | Was `300` (~5 s) as a **diagnostic**, never as behaviour — it isolated the Phase 7.4 camera re-pick from level entry. That investigation finished, so the cost stopped being worth paying; the constant stays so the next one can raise it. |
| `PULSE_HOLD_TICKS` | `3` | **Sized** against the AnimBP's own update graph, which can stomp a single-tick write to `landed?`/`jumped?` before the state machine sees it. |
| `WEAPON_SMOOTHING_ALPHA` | `0.25` | **Sized** against the rate gap: extras cross the wire at 20 Hz and the core never interpolates them, while the redraw loop runs at ~150 Hz. Fraction of the remaining gap closed per tick. |
| `WEAPON_SNAP_DISTANCE` | `400.0` | **Sized.** Above this, snap instead of easing — comfortably above one 20 Hz step of the measured ~300 units/s throw arc and well below a room-scale jump, so a throw or an area change does not draw the sword gliding through the level. |
| `SLIDE_REFIRE_INTERVAL_TICKS` | `12` | **Tuned by eye**, and says so: roughly a third of a short slide at ~150 Hz, so one slide gets a few overlapping bursts. Function-local. |
| `SLIDE_REFIRE_WINDOW_TICKS` | `40` | **Tuned by eye** — cuts re-fires off around the halfway mark of a slide's consistent 87 ticks so the last images land near the slide's own end. Function-local, and **dormant in practice**: the observed-spawn trigger is what fires today (`BANDAGES.md`, Deliberate). |
| `AFTERIMAGE_SPAWN_PROXIMITY_UNITS` | `400.0` | **Derived, not guessed.** An afterimage is placed at the player, so the only separation possible is how far the player moved within one scan gap (≤10 ticks at ~150 Hz ≈ 67 ms, ~100 units at 1500 units/s). 400 is ~4x margin, and the log reports the furthest mover so a mis-size shows up in the capture. |
| `AFTERIMAGE_COLOR_HOLD_TICKS` | `15` | **Sized against the send rate**, not against how long the effect looks right: ~20 Hz is ~7-8 ticks at this build's ~150 Hz. The failure it fixes was a sampling race — same reasoning as `PULSE_HOLD_TICKS`. |
| `AFTERIMAGE_COLOR_OBSERVE_DELAY_TICKS` | `4` | **Measured behaviour**: the game counts `afterImagesToSpawn` *down* across ticks, so on the tick a burst is detected its images do not exist yet. |
| `AFTERIMAGE_COLOR_OBSERVE_WINDOW_TICKS` | `20` | **Sized generously on purpose.** A single scan saw only part of a burst and mis-attributed the rest to the *next* one — the "blue arrives one burst late" bug. The log's `off=`/`new=` pair reports the real drain profile, so tighten from measurement, not from another guess. |
| `AFTERIMAGE_OBSERVE_SCAN_INTERVAL_TICKS` / `AFTERIMAGE_IDLE_SCAN_INTERVAL_TICKS` / `AFTERIMAGE_COLOR_OBSERVE_STRIDE_TICKS` | `6` / `10` / `5` | Cadences for the observe path, which runs **once per burst** rather than on a fixed forever-cadence. That is one of the three reasons it is cheap enough to leave on where its predecessor regressed. |
| `RECALL_GLOW_SCAN_INTERVAL_TICKS` | `15` | Cadence of the glow presence mirror. |
| `LOG_INTERVAL_TICKS` | `120` | ~2 s bridge-stats cadence, chosen for readability. `local_state` itself is sent every tick and is not throttled by this. |
| `LANDED_WEAPON_STATE` / `CROUCH_MOVE_STATE` / `FLYING_MOVEMENT_MODE` / `IN_BUBBLE_MOVE_STATE` / `BUBBLE_MOVEMENT_MODE` | `3` / `2` / `5` / `7` / `5` | **Observed enum values, not tunables.** Changing one asserts a different fact about the game — check `documentation.md` first. |
| `ECC_PAWN` / `ECR_BLOCK` / `ECC_WORLD_DYNAMIC` | `2` / `2` / `1` | Unreal collision-channel and response enum values, used to make a ghost solid. Same category: facts, not dials. |
| `SLIDE_TIMELINE_TRACK` / `SLIDE_TIMELINE_UPDATE` / `RECALL_GLOW_ASSET` | asset and function paths | Reflected names the pose and glow paths resolve at runtime. A typo here does not fail to compile — it returns nothing, which is the whole hazard of a reflection-only game. |
| `GAME_ID` / `ADAPTER_VERSION` / `BRIDGE_HOST` | `"pseudoregalia"` / `"phase7.7"` / `"127.0.0.1"` | Protocol identity and the bridge host. The bridge **port** is deliberately not a constant here — `BridgeClient` walks a range so a second instance finds its own core. |

### Probe cadences and thresholds — only live while their flag is on

Every one of these is dead in a shipped build, because the flag that reads it is `false`. They are
listed so that turning a probe on does not also mean re-deriving how often it should run.

| Constant | Value | Belongs to |
|---|---|---|
| `SLIDE_MESH_PROBE_INTERVAL_TICKS` | `10` | `SLIDE_MESH_PROBE` |
| `POSE_WINDOW_TICKS` | `14` | `POSE_WINDOW_TRACE` |
| `POSSESS_TRACE_TICKS` | `20` | `POSSESS_TRACE` |
| `BUBBLE_FX_DIFF_INTERVAL_TICKS` | `4` | `BUBBLE_FX_DIFF` |
| `OBJECT_REFLECTION_DUMP_INTERVAL_TICKS` | `300` | `OBJECT_REFLECTION_DUMP` |
| `CATALOG_PROBE_INTERVAL_TICKS`, `CATALOG_PROBE_MONTAGES` | `600`, 5 names | `MONTAGE_CATALOG_PROBE` |
| `WEAPON_ACTOR_MOVE_EPSILON`, `WEAPON_ACTOR_SWEEP_DELAY_TICKS` | `1.0`, `30` | `WEAPON_ACTOR_TRACE` |
| `WEAPON_PROP_TRACE_INTERVAL_TICKS` | `15` | `WEAPON_PROP_TRACE` |
| `VFX_WATCH_INTERVAL_TICKS` | `10` | `VFX_WATCH` |
| `VFX_PROBE_INTERVAL_TICKS`, `VFX_PROBE_PATH_FILTER`, `VFX_PROBE_NAME_FILTERS` | `450`, `"/Game/"`, `{"Weapon","Aura"}` | `VFX_CATALOG_PROBE`. The name filter is **deliberately widenable, never a hardcoded set of asset names** — clear the array to go back to all 58. A human-watched catalog needs a shortlist; that is `_template/README.md`'s rule. |
| `GHOST_SPAWN_WEAPON_TRACE_DELAY_TICKS` | `150` | `GHOST_SPAWN_WEAPON_TRACE` |
| `AFTERIMAGE_DISCOVERY_INTERVAL_TICKS`, `AFTERIMAGE_DISCOVERY_SAMPLE_DELAY_TICKS` | `450`, `30` | `AFTERIMAGE_DISCOVERY`. **The sample delay was 3, and 3 was wrong** — at that delay the probe reported "0 new objects" and concluded afterimages were pooled, the exact opposite of the truth. A probe's own cadence can invert its conclusion. |
| `AFTERIMAGE_COLOR_SCAN_INTERVAL_TICKS` | `15` | the retired colour scan. Its predecessor at 3 ticks (~50 Hz) did per-object string work on the game thread and **truncated the very bursts it was counting** — the 2026-08-16 regression. |
| `AFTERIMAGE_CALL_TEST_INTERVAL_TICKS` | `180` | `AFTERIMAGE_CALL_TEST` |
| `AFTERIMAGE_COLOR_TEST_RGB` | `{1,0,1}` (magenta) | `AFTERIMAGE_COLOR_TEST_OVERRIDE` — deliberately a colour the game never produces, so the colour path can be proven independent of detection. |
| `AFTERIMAGE_COLOR_OBSERVE_LOG_COUNT`, `_BURST_LOG_COUNT`, `_SPECIAL_LOG_COUNT` | `40`, `400`, `200` | log budgets, so a capture ends rather than filling a session. |
| `REUSE_MOVE_THRESHOLD`, `AFTERIMAGE_REUSE_MOVE_THRESHOLD` | `5.0`, `5.0` | `AFTERIMAGE_COUNT_REUSE`. An afterimage never moves once spawned, so this only has to clear read noise. |
| `COLOR_MATCH_EPSILON`, `COLOR_EPSILON`, `ULTRA_EPSILON` | `0.01f`, `0.002f`, `0.0001` | float comparison tolerances for colour and ultra-hop detection. |
| `MONTAGE_DIVERGENCE_CHECK_INTERVAL_TICKS` | `4` | the montage divergence check. |
| `HIJACK_EXCLUDE_KEYWORDS`, `NEEDLE`, `RELEASE_CANDIDATES` | name lists | leftovers of the retired hijack design and of the crouch-release input search. |
