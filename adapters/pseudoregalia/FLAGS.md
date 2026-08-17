# Pseudoregalia — compile-time flag register

`Plugin.cpp` carries 56 `constexpr bool` switches. They look alike and they are not alike, and
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

## Behaviour — the 14 that are `true`

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
| `GHOST_COLLISION_ENABLED` | Ghosts are solid. Kept deliberately as a feature, not an accident — see `agent_docs/ideas.md`. Whether it stays is still an open call. |
| `WALLRUN_TRIGGER_TEST` | Ghosts trigger the game's wall-run. The feared self-propulsion (a ghost fighting its own network-authoritative position) did not materialise across three live rounds; the flag survives as the clean off-switch if a real remote peer ever shows it. |
| `AFTERIMAGE_TRIGGER_FROM_OBSERVATION` | The blue trail fires on the game's **own** observed afterimage spawns, not on any reconstructed rule. Three `actionState` theories and the capsule-shrink fact were all disproven live before this. |
| `AFTERIMAGE_OBSERVE_COLOR` | Reads the trail colour from the real effect rather than guessing it. |
| `AFTERIMAGE_OBSERVE_SPECIAL_TRIGGER` | Additive: fires only where the existing trigger found nothing. Not the old `AFTERIMAGE_TRIGGER_OBSERVED`, which replaced the trigger wholesale and scanned unconditionally. |
| `AFTERIMAGE_REQUIRE_SPAWN_PROXIMITY` | Birth-proximity check, so a recycled pooled actor is not counted as a new afterimage. |
| `RECALL_GLOW_ENABLED` | Mirrors whether the real glow is present rather than reimplementing "empty-handed AND near a save crystal". Whatever rule the game actually applies is mirrored for free and cannot drift. |

## Probes — off, and they must stay off

41 flags. Names ending `_TRACE`, `_PROBE`, `_DIFF`, `_DUMP`, `_SEARCH`, `_WATCH`, plus
`POSE_WINDOW_TRACE`, `VFX_CATALOG_PROBE`, `OBJECT_REFLECTION_DUMP`, `AFTERIMAGE_CALL_TEST`,
`DUMP_GHOST_SPAWN_VALUES`, `DUMP_VISUALMESH_FUNCTIONS`.

**A diagnostic can break the thing it measures, and then every reading agrees with itself.** This
adapter produced the worst regression in the project's history that way (2026-08-16). The expensive
shape is per-tick enumeration on the game thread, especially with a name lookup or string
conversion per object — compare by pointer instead. Before believing any measurement, re-run with
the probe off. Numbers gathered while a heavy probe was live are retroactively suspect.

Never leave a probe that *spawns* an effect enabled while judging that effect.

`MONTAGE_PROBES_SUPPRESS_ADAPTER_STOPS` is derived, not set: it is true whenever either montage
probe is on, and exists so a probe run does not fight the adapter's own montage stops.

## Dormant — recorded negatives and retired approaches

| Flag | Why it is kept |
|---|---|
| `GHOST_SLIDE_Z_COMP` | The `+43` render-Z bandage. Retired 2026-08-17 when the crouch path replaced it; the block stays gated off. See `BANDAGES.md`. |
| `GHOST_SLIDE_CALL` | Direct slide call — negative. |
| `AFTERIMAGE_COLOR_TEST_OVERRIDE` | Forces a colour, for proving the colour path independent of detection. |
| `WEAPON_SYNC_INVERT` | Kept so a swapped weapon-sync polarity costs a flag, not a build. |

Two other flags follow that same "a swap costs a flag, not a build" idea — the crouch input tries
`_16` down and `_15` up, and logs which fired, because which Enhanced Input index is press and
which is release was never established.

## When a comment and a value disagree

Believe the value, then find out why the comment drifted before changing either. These comments
accumulate in layers — an "OFF, job done" line from one session can sit directly above a "BACK ON,
and switching it off is what broke it" line from the next, with only the constant telling you which
one won. That is precisely how the 2026-08-17 confusion happened.

`CLAUDE.md` states the harder version of this: **a flag flip is not a revert.** A `constexpr bool`
only reverts behaviour if it gates the *work*, not merely the decision the work feeds — otherwise an
A/B "proves" a change innocent while its cost is still running. Verify the flag disables the cost,
or revert the commit.
