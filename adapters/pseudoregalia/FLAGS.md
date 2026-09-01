# Pseudoregalia — compile-time flag register

<!-- line-cap: none -- register; size is the number of switches that exist. Why: agent_docs/claude-md-cap.md. -->

`Plugin.cpp` carries 96 `constexpr bool` switches (re-counted 2026-08-30 with `grep -c "constexpr bool "`;
the 91 written here on 2026-08-29 was itself a correction of a stale 87 and was stale again within a
day, so treat the figure as a date-stamped measurement, not a total). They look alike and they are not alike, and
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

**Compile-time bools are not the only switches here.** `Plugin.cpp` also carries ~95 `constexpr`
*numbers* (2026-09-01 count — treat it as date-stamped like the bool count) that decide behaviour
— hold windows, guards, offsets, thresholds. They are registered in
"Tunable constants" at the bottom, because a wrong number is as load-bearing as a wrong bool and
far easier to "tidy".

## Behaviour — the 33 that are `true` (re-counted 2026-09-01)

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
| `GHOST_ROTATION_SLERP` | **Added 2026-08-30, UNWATCHED — the ghost's FACING is interpolated instead of stepping at the send rate.** Orientation is opaque to the core, so it never interpolated it: facing snapped 20 times a second, which the user saw as *"a bit choppy/low fps at 20hz and 250ms when turning around fast but super smooth when turning around slow"* — angular velocity divided by Hz, so a slow pan steps ~2 degrees and a fast spin ~18. The core now names the bracket it used (`orientation_from`/`orientation_to`/`interp_t` on `render_remote`, ADR 0043) and this adapter interpolates it shortest-arc, per component. **Gates the WORK, not the decision, and now the BRIDGE TRAFFIC too** — `false` compiles the block out AND stops the adapter asking for the bracket in its `hello` (`interpolate_orientation`), so the core computes and sends nothing either. Byte-for-byte the pre-2026-08-30 behaviour in both the rendering and the wire, which is what makes an A/B on screen mean something. **Confirm the opt-in took from the CORE log** (`adapter asked for interpolated orientation`), never from the mod's own HELLO line — a missing bracket looks exactly like the old stepping while this flag still says `true`. The bar is a side-by-side spin that is indistinguishable at every speed. |
| `SPAWN_BASED_GHOSTS` | Ghosts are spawned actors, called from the real game thread. `false` reverts to the older hijack-a-StaticMeshActor design, kept in case the world-leak crash ever reproduces. |
| `GHOST_DESTROY_ON_DESPAWN` | A despawning ghost is destroyed (`K2_DestroyActor`) instead of being flung to `DESPAWN_PARK_Z`. Turned on 2026-08-17 once the premise for parking went stale: the "destroy silently no-ops" finding was a property of the *hijacked* actor, not of the build, and since Phase 7.6 the ghost is one we spawned. Falls back to parking when the call is not reflected, so the worst case is today's behaviour plus a log line. **The one thing it cannot rule out by itself is the historical "Fatal world leaks detected" crash** — see `BANDAGES.md`'s entry 0, whose whole argument rests on this flag being `true`. Note `DESPAWN_PARK_Z`'s own comment still says "NEVER destroy the actor": that comment is stale, and the value here is what wins. |
| `GHOST_COLLISION_ENABLED` | **Listed here but `false` — the one row in this table that does not ship as `true`, kept together with the flags it gates.** **`false` since 2026-08-27 — ghosts are NOT solid.** It was on from 2026-08-15 as a deliberate feature; the user asked for it off again, with no new evidence against it. The flag gates the *work*, not just a decision: `SetActorEnableCollision(false)` plus the `if constexpr` block re-typing the ghost's capsule and setting the Pawn-channel `Block` response, all of which compiles out entirely, so this is a real revert. **The `bCanBeDamaged` hurtbox disable used to be gated by this same flag and is now its own, `GHOST_HURTBOX_DISABLED` below** — they were one, which is how turning collision off silently changed damageability too. The melee-death hazard and the never-tested non-player-damage vector only exist while it is `true`. Note `Plugin.cpp`'s long comment above the constant still argues for keeping it on — that argument is intact but no longer in force, and the value here is what wins. |
| `GHOST_HURTBOX_DISABLED` | **The second row here that ships `false`, and it had no row at all until 2026-08-27.** Marks a ghost un-damageable on spawn (`bCanBeDamaged = false`). It used to be gated by `GHOST_COLLISION_ENABLED` above, which is exactly the problem: turning collision off silently turned damageability off too, and one flag hiding a second behaviour is how a "revert" stops being a revert. Split out and left `false` on the user's call, as a suspect in the "player takes no damage" symptom rather than a harmless safety net — see the write's own comment at the spawn site. **Missing from this register is itself the finding**: a flag with no row is a flag nobody audits. |
| `WALLRUN_TRIGGER_TEST` | Ghosts trigger the game's wall-run. The feared self-propulsion (a ghost fighting its own network-authoritative position) did not materialise across three live rounds; the flag survives as the clean off-switch if a real remote peer ever shows it. |
| `AFTERIMAGE_TRIGGER_FROM_OBSERVATION` | The blue trail fires on the game's **own** observed afterimage spawns, not on any reconstructed rule. Three `actionState` theories and the capsule-shrink fact were all disproven live before this. |
| `AFTERIMAGE_OBSERVE_COLOR` | Reads the trail colour from the real effect rather than guessing it. |
| `AFTERIMAGE_OBSERVE_SPECIAL_TRIGGER` | Additive: fires only where the existing trigger found nothing. Not the old `AFTERIMAGE_TRIGGER_OBSERVED`, which replaced the trigger wholesale and scanned unconditionally. |
| `AFTERIMAGE_REQUIRE_SPAWN_PROXIMITY` | Birth-proximity check, so a recycled pooled actor is not counted as a new afterimage. |
| `RECALL_GLOW_ENABLED` | Mirrors whether the real glow is present rather than reimplementing "empty-handed AND near a save crystal". Whatever rule the game actually applies is mirrored for free and cannot drift. |
| `GHOST_AFTERIMAGE_NO_OUTLINE` | **ZERO frames, user-confirmed 2026-08-27** — the outline is refused at the native `SetRenderCustomDepth` call itself (`register_afterimage_outline_guard`), never merely stripped after. The game enables custom depth BEFORE setting `copyActor` (measured), so an unattributable enable while a ghost is alive is refused and RESTORED a tick later by the sweep if the image is the player's own — the failure mode inverted into the invisible direction. Attribution: `copyActor` equality when set; birth proximity as the labelled fallback (continuous proximity was tried first and REVERTED for taking the local player's outline with it). The per-tick sweep stays as backstop and logs anything that got past the hook. |
| `GHOST_HOLD_OUTLINE_OFF` | A ghost is never drawn through walls: custom depth is stripped from everything it owns, every tick, plus a ~30Hz sweep for components attached at RUNTIME that no property points at. Generalised from a five-name list on the user's rule — *"i don't want it to apply to the ghosts at all, no matter what/where. only to the player itself."* The asymmetry is the point: a peer's position behind geometry is information. **Has never once found custom depth on**, which is how the afterimage carrier was eventually identified. |
| `GHOST_HOLD_LIGHT_OFF` | **BUILT 2026-08-29, never watched.** Holds a ghost's ascendant-light `PointLight` at intensity 0. Measured first: the player's reads 0 and the ghost's reads 5000, same class, same attach point (`WeaponMesh`) — so 5000 is the pawn Blueprint's own DEFAULT, which the game drives down on a real player through logic a ghost never runs, and nothing was ever being copied. Additive across peers, which is why the user saw the room brighten with company. Attributed up the ATTACH chain (a `ChildActorComponent`'s actor outers to the LEVEL, so an outer walk finds nobody), and the engine call is made ONLY on a component attributed to one of our ghosts — `FindAllOf` hands back class-default objects and calling a UFunction on one crashed a live session twice the same day. **Deliberately does not touch `bVisible`/`bIsActive`: both lights report them false, including the one lighting the room.** Paired with `LIGHT_SWEEP_INTERVAL_TICKS`. |
| `GHOST_NAMETAGS` | **The nametag feature, confirmed by three peers 2026-08-29.** Renders a peer's `remote_name` as a `UTextRenderComponent` above the ghost, using only the engine's own cooked font/material (`RobotoDistanceField` / `DefaultTextMaterialOpaque`, confirmed present by `NAMETAG_CENSUS_PROBE`) — nothing of ours ships, which is what ruled out the UMG-widget approach another mod took. |
| `NAMETAG_COLOR_PLATE` | **The coloured plate behind a nametag, confirmed 2026-08-29.** Uses the engine's opaque+unlit `DebugMeshMaterial` ("Color" parameter) because every translucent material vanished behind the game's own translucency sorting and every game opaque master is lit/stylized. Drawn only when the peer set a `name_color`. |
| `GHOST_NEUTRALISE_CAMERA_RIGS` | Holds a ghost's spawned camera rig dark — the pawn Blueprint gives every spawn a camera nobody looks through, which the 2026-08-29 light hunt found contributing. Swept at `CAMERA_RIG_SWEEP_INTERVAL_TICKS` (~5/s); writes only to a rig that is not the local player's and not already neutral. |
| `PLAYER_STATE_DIFF_ON_GHOST_SPAWN` | **A diagnostic shipping `true` — its own comment says "two spawns' worth of output and it should be off again".** Scalar-diffs the local player's properties around a ghost spawn and prints what moved. Registered 2026-09-01 as exactly the defect class the register hunts (a probe in the `true` list); flip it `false` on the next functional rebuild unless its question is still open. |
| `GHOST_CUSTOM_DEPTH_DEV_TOGGLE` | **A diagnostic shipping `true` — its own comment says "must ship OFF".** Polls for a custom-depth dev toggle file every `DEV_TOGGLE_POLL_TICKS` (one `GetFileAttributesW` per poll). Registered 2026-09-01, same defect class as the row above; same disposition. |
| `MIRROR_PEER_PROJECTILE` | **Confirmed 2026-08-27.** A peer's ranged shot, mirrored as the projectile's own Niagara EFFECT along the sampled path — never as the game's actor, which crashed the game when its pointer outlived it. The sender attributes a shot by `Instigator` and requires its `ProjectileMovement` to be ACTIVE, because this game pools actors and existence is not activity. |
| `MIRROR_DEATH_FADE` | **Confirmed 2026-08-27.** Runs the pawn's own `dieFade(DieNotRez)` on a ghost — dying on the peer's health reaching zero, resurrecting when their `NS_RespawnSafe` starts. Found by two probes: the model is never hidden and its materials go dynamic (so it is an animated parameter), then a census named the function. |
| `MIRROR_HURT_REACTION` | **Confirmed 2026-08-27, and the one flag with a runtime tripwire.** Runs the pawn's own `BPI_PerformDamageResponse` on a ghost whenever the peer's shared health DECREASES — a pit fall is 5 HP, damage rather than death, which is why the death fade could not carry it. Because health is a GameInstance singleton, the mirror reads `CurrentHp` around the call and **disarms itself for the session** if the value moves. It has never fired; that is a measured fact about the function, not an assumption. |
| `GHOST_FADE_GUARD` | Neutralises a camera fade raised within `GHOST_SPAWN_FADE_GUARD_TICKS` of a ghost spawning, leaving every real fade untouched. **Armed and never fired**, which is a finding: the black flash is not a camera fade. Kept because it costs one hook and would catch the case on another build. |
| `GHOST_PREHIT_PLAYER` | **The ghost-damages-player fix, confirmed on screen 2026-08-27.** Marks the local player as already-hit in the **ghost's own** `hitActorsArray`, checked every tick, before its first swing. The game's own mechanism: only the FIRST attack ever landed because after it the player was already in that list, so this extends the game's behaviour by one attack. Nothing on the player is written, and the montage, pose and VFX are untouched. Six other candidates are Dormant below, each a recorded negative. `VERIFIED.md` has the measurement and the method. |
| `GHOST_BLOB_SHADOW_ARM_MIRROR` | **The blob-shadow fix, confirmed on screen 2026-08-27.** Mirrors the LOCAL player's `SpringArm.TargetArmLength` onto the ghost's every tick. The ghost's was 100 (the class default) against the player's 5000, and with `bDoCollisionTest=true` that length is how far the shadow may fall before it finds floor — so the ghost's shadow was pinned ~100 units under the model, in the air included. Sampled live rather than written as a constant, the same shape as the capsule mirror. `VERIFIED.md` has the measurement. |
| `GHOST_BLOB_SHADOW_DRIVE` | Calls the pawn's own `manageBlobShadow` on the ghost every tick. **Kept, but it is NOT the fix** — measured 2026-08-27: it runs (the log says so once) and the ghost's arm still read 100, so the function is not what sets that value, or it takes an early branch on an unpossessed pawn. On `true` because it is the game's own function on the game's own component and it runs BEFORE the mirror, so the mirror's write wins the ordering; if it is ever found to do harm, this is the clean off-switch. |
| `GHOST_DECOUPLE_SHARED_STATE` | Cuts a ghost off from the state it shares with the player: removes the ghost's OWN HUD widget from the viewport (the duplicate health bar, `VERIFIED.md` 2026-08-27), zeroes its damage numbers, and clears `As MV Game Instance Ref` / `UI_HudRef` / `BP_HpHitable` / `LastHitBy`. **Was missing from this register until the 2026-08-27 audit**, along with `MIRROR_PLAYER_VFX`. |
| `MIRROR_PLAYER_VFX` | Mirrors the player's live Niagara effects onto a ghost by KEY, from the compile-time `MIRRORED_EFFECTS` table — the wire never carries an asset path. |
| `STATE_SEND_TRACE` | **The one `_TRACE` flag deliberately `true` — do not "fix" it to `false`.** Logs the `area_id` and world position actually sent, every ~300 ticks (~5s). It is here because aiming any synthetic-peer rig needs both values from a live session (`cmd/meshghost-fakeadapter`'s `-center` and `-area-id`, which must match exactly or nothing renders), and on 2026-08-17 neither was readable anywhere — `dev-scripts/run-ghostload-pseudoregalia.bat`'s own header tells you to read them "from the mod's log" and that line did not exist. Cost is one throttled formatted line, no enumeration and no per-object work, so it is the same shape as the always-on bridge counter line rather than the per-tick enumeration the probe rule below is about. |

## Probes — off, and they must stay off

**One of them shipped ON, and it took a release test to notice (2026-08-28).**
`LOCAL_MOVEMENT_TRACE` did not exist as a flag at all: the block it now gates was written for the
"stuck flying after jump" investigation and left running unconditionally, so every RELEASE build
dumped movement state, VisualMesh transform and capsule rotation every ~2s forever. Measured in a
real session at **24 of the 73 adapter log lines in 18 seconds**, beside 25 bridge-stat lines --
**two thirds of what the shipped adapter logged was diagnostics from finished work.** It is now a
flag, `false`, and counted below.

The lesson for this register: a probe with no flag is invisible to this file, so counting flags
cannot prove the shipped build is quiet. What proves it is reading a real session's log, which is
the only reason this was found.

47 flags, all `false`. Names ending `_TRACE`, `_PROBE`, `_DIFF`, `_DUMP`, `_SEARCH`, `_WATCH`,
`_CENSUS`, `_HUNT`, plus `AFTERIMAGE_CALL_TEST`, `AFTERIMAGE_DISCOVERY`,
`DUMP_GHOST_SPAWN_VALUES`, `DUMP_VISUALMESH_FUNCTIONS`, and `NAMETAG_STATE_READBACK` (probe by
nature, not by suffix: reads back what each nametag component actually holds, because "never
created", "drew nothing" and "drew the wrong string" were three bugs behind one symptom). Three
worth knowing by name: `NAMETAG_CENSUS_PROBE` (the one-shot font/material census the nametag
feature was built on), `GHOST_MESH_Z_TRACE` (the slide-transition instrument `SLIDE_SEAM_HOLD_MS`
was derived from — turn it back on only to re-measure against a new game build), and the two
diagnostics currently shipping `true` in the Behaviour table above, which belong down here.

**The arithmetic, so a future audit can check it in one pass** — recounted 2026-09-01, after the
nametag/sword-throw/crowd sessions (the 2026-08-27 recount of 87 had itself gone stale within
days, which is why the figure carries a date and the COMMAND, never a total to trust): **96**
`constexpr bool` declarations in `Plugin.cpp`, being 95 written plus
`MONTAGE_PROBES_SUPPRESS_ADAPTER_STOPS`, which is **derived** rather than set
(`GHOST_SELF_MONTAGE_PROBE || MONTAGE_CATALOG_PROBE`) and is therefore false in every shipped
build without being written so. Of the 95:

- **33 written `true`** — Behaviour, above.
- **62 written `false`**, splitting by name into **47 probe-shaped** and **15 not**.
- Of those 15, **two are behaviour flags that ship off** — `GHOST_COLLISION_ENABLED` and
  `GHOST_HURTBOX_DISABLED`, both listed under Behaviour with the flags they belong beside — and
  the remaining **13 are recorded negatives / retired approaches** (the Dormant table below, plus
  `NAMETAG_STATE_READBACK`, a nametag instrument that is probe by nature though not by suffix).
- The Dormant table also carries some probe-shaped flags because their *findings* are what
  matters, not their off-ness. A flag can be counted once and written up twice.

**The audit is the grep, not this block:**
`grep -oP '^\s*constexpr bool \K\w+(?= = (true|false);)'` — it takes a second, and it is how the
2026-08-27 recount caught a probe shipping as `true` (`HEALTH_PROBE`, now off; see its comment),
which is exactly what this register is for: a name ending `_PROBE` sitting in the `true` list is
a defect, not a special case.

**`OUTLINE_HUNT` and `LOCKON_PROBE` (added 2026-08-27)** are the outline investigation's two
instruments. `OUTLINE_HUNT` enumerates every mesh component in the world currently rendering custom
depth, with its actor, stencil and position; `LOCKON_PROBE` watches the player's lock-on/target
properties per tick and names what they point at. Both answered their questions and both are off.
**`OUTLINE_HUNT` also carries a warning**: it enumerates `SkeletalMeshComponent` and
`StaticMeshComponent` only, which is precisely why it never saw an afterimage's
`PoseableMeshComponent` — widen the class list before trusting a clean result from it.

**`GHOST_PROJECTILE_WATCH` (added 2026-08-27)** sweeps once for the projectile class this build
actually has, then polls it and logs every instance with its Owner and **Instigator**, plus both
pawns' `LastHitBy` and a readback of the ghost's real collision state. Built for the "a ghost's
charged attack damages the player" item; three sessions of it put every projectile in the local
player's hands and neither `LastHitBy` was ever written, so its collision readback — never yet run
— is the next thing to look at. Cadence: `PROJECTILE_WATCH_INTERVAL_TICKS`.

**`SHADOW_COMPONENT_PROBE` (added 2026-08-27) is the shadow investigation's instrument, and its
question is answered** (`VERIFIED.md`, same day) — kept because it generalises: it is the census
that answers "which component of the player's does the ghost also have, and what is different
about the ghost's copy", which has now been the shape of three separate bugs. Read-only: a one-shot census of every component-valued property the ghost and the
local pawn each hold, taken at ghost spawn into one log, plus a world sweep for decal/billboard
components, plus a per-interval `RelativeLocation` trace of whatever shadow-shaped names the census
found. It exists because the ghost's shadow sits on the model instead of on the ground
(`UNVERIFIED.md`), and because the frame that solved the camera rig and the HUD says the question
is *which component of the player's does the ghost also have*, not which value to overwrite.
Cadence: `SHADOW_PROBE_INTERVAL_TICKS`.

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

**Known register/reality disagreement, found 2026-08-27: the `CAMERA_TRACE`-labelled log line is
NOT gated by the `CAMERA_TRACE` flag.** The per-switch line inside the `SetViewTargetWithBlend`
hook prints unconditionally — the flag reads `false` and the line appeared in a live session
anyway, which is how this was noticed. Cost is one formatted line per camera switch (rare: spawns,
cutscenes), and that same ungated line is what pinned the 2026-08-27 camera-pointer crash to its
exact statement when the crash dialog carried no stack — so it has earned something. Still a
defect by this file's own rule: gate it under the flag on the next FUNCTIONAL rebuild. Not fixed
on the spot because the fix would have re-shipped an unwatched binary minutes after the user
confirmed the current one, purely to remove a log line. **Still ungated as of 2026-09-01, having
survived every functional rebuild since** — the deferral clause has quietly become permanent, so
either gate it on the next rebuild for real or accept it here as a deliberate always-on line.

`MONTAGE_PROBES_SUPPRESS_ADAPTER_STOPS` is derived, not set: it is true whenever either montage
probe is on, and exists so a probe run does not fight the adapter's own montage stops.

## RUNTIME dev toggles — files beside the DLL, and NONE of them may ship (2026-08-29)

**A different mechanism from every flag above, and the register has to name it or an audit that
counts `constexpr bool` will report the build clean while six switches are live.** These are read
from the filesystem at runtime: a file's mere PRESENCE next to `main.dll` flips behaviour, polled
every `DEV_TOGGLE_POLL_TICKS`. That is what makes them worth having — a peer's ghost can be
changed mid-session without a rebuild or a relaunch, which is how the light hunt ran a dozen
subtractions in one game session — and exactly what makes them dangerous: **a shipped build with
these compiled in behaves differently for anyone who happens to create a file with the right
name.** They are gated behind `GHOST_CUSTOM_DEPTH_DEV_TOGGLE`, which is `true` in the committed
build and must go `false` (with the toggles removed) before release.

**Three light toggles were RETIRED on 2026-08-30 — promoted to shipped defaults, their files no
longer read** (user's call: *"properly implement it"*): the ghost vertex-light kill
(`hide_ghost_playerlight.txt`), the LightMesh/blade-aura hide (`hide_ghost_lightmesh.txt`), and
post-spawn `BP_LightManager_C::FixAllLights` (`ghost_fix_lights.txt`, the scene-latch fix —
`FixDynamicLights` alone measured insufficient). Their globals initialize `true` in code; a stale
file beside the DLL is ignored. Acceptance run quoted in `VERIFIED.md` 2026-08-30.

| File | What it does |
| --- | --- |
| `ghost_no_overlap.txt` | Spawns ghosts with capsule overlap events suppressed, so they cannot fire world triggers. Measured UNNECESSARY for lighting (2026-08-30: a ghost crossed light-transition volumes with this off, nothing changed); no other trigger class has been tested. |
| `guard_playerlocation.txt` | Native pre-hook redirecting every `MPC_PlayerRelated.PlayerLocation` write to the local player's position. The theft is real; no visual has ever been attributed to it, and the acceptance run passed without it. |
| `ghost_spawn_far.txt` | Births ghosts 5000 units above the player (next state pulls them in). A discriminator for the latch hunt — refuted the paint-at-spawn theory; keep OFF. |
| `dump_lights_now.txt` | Edge-triggered instrument: each appearance dumps player light components, the four transitions, the ambience, the manager and every vertex light. |
| `call_light_fn.txt` | Edge-triggered instrument: each appearance calls the manager function named by the file's FIRST LINE. How `FixAllLights` was proven live on a latched scene. |
| `skip_ghost_equip_call.txt` | Skips `changeEquippedWeapon` on ghosts. Split test only — **it breaks the ghost's sword throw.** |
| `skip_ghost_equip_anim.txt` | Skips `updateWeaponEquip` on ghosts. Same, same regression. |
| `skip_ghost_weapon_prop.txt` | Skips the whole thrown-sword mirror (flyer, glow, dust, bounces). The subtraction that found the 2026-09-01 cross-wire carrier; kept for A/B. |
| `skip_ghost_weapon_state.txt` | Historical: skipped the game's `Change Weapon State` on the spawned prop. The prop is gone (flyer since 2026-09-01); the toggle now gates a call that no longer exists and is retained only as the ladder's record. |
| `hide_ghost_mesh.txt`, `hide_ghost_weapon.txt`, `hide_ghost_fx.txt`, `hide_ghost_shadow.txt`, `hide_ghost_nametag.txt`, `keep_custom_depth.txt`, `ghost_light_on.txt` | Subtraction instruments, one component class each. |
| `trace_remotes.txt` | Arms the per-remote redraw readback/TRACE block (2026-09-01; previously always on). Two log lines plus ~6 reflection reads per remote every `LOG_INTERVAL_TICKS` — a real cost at crowd sizes, so it ships OFF. The `bHidden` nudge in that block is behaviour and runs regardless. |
| `bare_ghost.txt` | Spawns a ghost with everything after the pawn itself skipped — no decouple, no lights, no nametag, no mirrors. The ghost looks wrong on purpose; it is the base rung of the subtraction ladder. |
| `decouple_off.txt` | Skips parts of the shared-state decouple; a keyword on the file's first line (e.g. `lightdestroy`) selects which part. Split instrument for the decouple ladder. |
| `dump_arrays.txt` | Arms `census_object_counts`/`census_singleton_arrays` — object-count dumps at labelled moments, for leak/orphan hunts. |
| `force_gc.txt` | Requests an engine garbage-collection sweep (`CollectGarbage`, deferred by UE to a safe point) at the instrumented moment. |
| `guard_off.txt` | Turns a guard hook into log-only — nothing destroyed or suppressed — the missing CONTROL for judging what the guard itself causes. |
| `log_reset_fns.txt` | Logs the functions the game runs during a reset. Costly; its own comment says never leave it on. |
| `perf_report.txt` | **Per-subsystem frame-cost timer** (2026-08-30). Prints accumulated us/frame per subsystem every ~2s: `tick_total` plus each block, so every slot reads as a share of the whole and the unattributed remainder is itself the finding. Disarmed it is one bool test per scope. This is what found four whole-world scans costing half the frame rate -- `../../agent_docs/pitfalls/method.md`. **Never leave it armed while judging anything visual.** |

**Two of these subtractions LIE and are not to be trusted** (measured 2026-08-29): the nametag and
blob-shadow sweeps report `0 of N` switched while the components are on screen. The nametag was
eventually eliminated only because the toggle armed from BOOT works by a different path — the
updater never runs, so the components are never created. The `bVisible` byte read is the suspect;
until that is fixed, **only a subtraction printing a NON-ZERO count is evidence.**

The promotion job ran 2026-08-30: the three proven light fixes are code now, and the two rows
above stayed instruments because the acceptance run passed without them.

## Dormant — recorded negatives and retired approaches

| Flag | Why it is kept |
|---|---|
| `GHOST_SLIDE_Z_COMP` | The `+43` render-Z bandage. Retired 2026-08-17 when the crouch path replaced it; the block stays gated off. See `BANDAGES.md`. |
| `GHOST_SLIDE_CALL` | Direct slide call — negative. |
| `AFTERIMAGE_COLOR_TEST_OVERRIDE` | Forces a colour, for proving the colour path independent of detection. |
| `AFTERIMAGE_TRIGGER_OBSERVED` | The first observed-spawn trail trigger, retired 2026-08-16. `false` is a **real** revert now that the enumeration it carried is gated too — the earlier A/B was worthless because only the counter increment inside the scan was gated while the scan itself still ran. Replaced by `AFTERIMAGE_TRIGGER_FROM_OBSERVATION` plus `AFTERIMAGE_OBSERVE_SPECIAL_TRIGGER`, which are additive rather than wholesale. |
| `AFTERIMAGE_COUNT_REUSE` | Counting pooled re-use as a spawn — a **recorded negative**. Added on the theory that the ghost's thinner trail came from missed spawns; a world census measured the opposite (the ghost produced roughly twice as many afterimages as the player while still looking thinner), so this only added spurious ones. Kept because the underlying finding — these actors are pooled and re-used, which is why none ever disappear — is real and is the mechanism a future effect would want. |

| `MIRROR_PLAYER_BLINK` | Ran the pawn's `startBlink` on a ghost for the death flash. **Recorded negative, and a name that lied**: the function picks a `RandomFloatInRange` and sets a timer — it is the character's EYES blinking. It resolved, ran, and showed nothing. |
| `GHOST_STOP_TRANSITION_TIMELINES` | Stopped the ghost's `Timeline_2`/`Timeline_3` for the black flash. **Recorded negative, proven by its own readback**: `IsPlaying` reported `not playing` on every ghost, so those timelines were never running and stopping them was cosmetic. |
| `DEATH_VISIBILITY_PROBE` | Watched the player's mesh through a death. Answered in one run — never hidden, three material slots become `MaterialInstanceDynamic` — which is what redirected the search from particles to an animated material parameter. |
| `DEATH_FIELD_CENSUS` | Enumerated death/respawn/material-shaped names on the pawn. Named `dieFade`, `flash` and `BPI_CombatDeath` in one shot. |
| `FADE_FIELD_CENSUS` | Enumerated fade/screen-shaped names. Named `enterTransition`, `exitTransition` and the two fade timelines. |
| `GHOST_DAMAGE_GUARD` | Zeroes damage at `GameplayStatics::ApplyDamage` and its two siblings when the causer is a ghost. **Armed on 3 of 3 and never fired**: this game does not use the engine's damage path at all — a recorded fact about Pseudoregalia, not a broken hook. Kept because it is correct for any UE game that does. |
| `GHOST_ATTACK_LOCKOUT` | Holds the pawn's own attack gates (`lockAttack?`, `bouncedAttackLockoutTimer` true; `freeAttack?`, `saveAttack?`, `storedChargeAttack`, `obtainedChargeAttack?`, `obtainedAttack?` false). **Recorded negative** — confirmed applied every tick, and the attack still registered the player. The attack path does not consult them. |
| `GHOST_HOLD_COLLISION_OFF` | Re-asserts `SetActorEnableCollision(false)` every tick. **Recorded negative, and an instructive one**: the ghost's collision was never the route, because its attack queries OUTWARD. A per-component read during a swing showed every component at NoCollision throughout. |
| `GHOST_SKIP_ATTACK_MONTAGES` | Skips attack montages on a ghost. **A bandage that worked and was withdrawn on the user's call** — *"i do want the ghost to do all animations"*. It produced this build's attack vocabulary (`dreamLady_Attack_GF1/GF2/GF3/GL2_Montage`) and the second data point for the montage mechanism. Superseded by `GHOST_PREHIT_PLAYER`, which costs no animation. |
| `GHOST_SELF_MONTAGE_PROBE` | Suppresses every montage call to a ghost. Listed under Probes historically; noted here because its 2026-08-27 run is what proved the montage mirror triggers the ghost's attack code. |
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

**A bool register is only half the switches.** `Plugin.cpp` carries ~95 `constexpr`
numbers (2026-09-01 count, roughly a third of them function-local — see below), and several of
them decide behaviour as completely as any flag: a hold window, a guard,
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
but **a growing set is function-local** (28 distinct names by the 2026-09-01 recount, against the
nine this paragraph listed on 2026-08-27), and several are cited elsewhere (`BANDAGES.md`, and the
tables below) by bare name, which reads as though they were file-scope. They are not, and a grep
at the top of the file will not find them. The two location claims that keep getting relied on:

- inside `Plugin::game_thread_tick()` — `SLIDE_CAPSULE_THRESHOLD`, `CROUCH_MOVE_STATE`,
  `SLIDE_REFIRE_INTERVAL_TICKS`, `SLIDE_REFIRE_WINDOW_TICKS`, `FLYING_MOVEMENT_MODE`,
  `IN_BUBBLE_MOVE_STATE`, `BUBBLE_MOVEMENT_MODE`
- inside `Plugin::ensure_ghost_spawned()` — `ECC_PAWN`, `ECR_BLOCK`, `ECC_WORLD_DYNAMIC`

The rest (epsilons, per-effect proximity/reuse thresholds, weapon-flyer floor drops, catalog
bounds, log budgets) live beside their use sites — **find one with
`grep -n "constexpr.*<NAME>" Plugin.cpp` and note its enclosing function before citing it.**
**This paragraph named four until 2026-08-27 and nine until 2026-09-01**, which is exactly the
failure it exists to prevent — a constant added function-local is added here in the same edit,
or the count above is at least re-dated.

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
| `SPAWN_DELAY_TICKS` | `120` (~1 s) | **Behaviour since the reset-crash work** (its comment, `Plugin.cpp:~600`): a spawn is held until the local pawn has been stable this long, the game-side half of the fix for spawning into a mid-transition world. It was `300` (~5 s) as a Phase 7.4 diagnostic, then `0` when that investigation finished — this row said `0` until 2026-09-01 while the code shipped `120`. |
| `PULSE_HOLD_TICKS` | `3` | **Sized** against the AnimBP's own update graph, which can stomp a single-tick write to `landed?`/`jumped?` before the state machine sees it. |
| `WEAPON_SNAP_DISTANCE` | `1500.0` | **Sized, re-measured 2026-09-01** (was `400.0`; its comment records the raise): loss holes stretch ordinary flight steps past 400 units, so 400 turned normal late samples into snaps — 1500 still catches the hand-to-impact start and any area-scale jump, while anything smaller glides at segment speed. Paired with `WEAPON_SEG_MIN_MS`/`WEAPON_SEG_MAX_MS` (`16`/`400`), the clamp on a flight segment's duration. (`WEAPON_SMOOTHING_ALPHA`, the old per-tick easing constant, no longer exists — the thrown sword was rebuilt as our own flyer component, `create_ghost_weapon_flyer`, 2026-09-01.) |
| `SLIDE_REFIRE_INTERVAL_TICKS` | `12` | **Tuned by eye**, and says so: roughly a third of a short slide at ~150 Hz, so one slide gets a few overlapping bursts. Function-local. |
| `SLIDE_REFIRE_WINDOW_TICKS` | `40` | **Tuned by eye** — cuts re-fires off around the halfway mark of a slide's consistent 87 ticks so the last images land near the slide's own end. Function-local, and **dormant in practice**: the observed-spawn trigger is what fires today (`BANDAGES.md`, Deliberate). |
| `AFTERIMAGE_SPAWN_PROXIMITY_UNITS` | `400.0` | **Derived, not guessed.** An afterimage is placed at the player, so the only separation possible is how far the player moved within one scan gap (≤10 ticks at ~150 Hz ≈ 67 ms, ~100 units at 1500 units/s). 400 is ~4x margin, and the log reports the furthest mover so a mis-size shows up in the capture. |
| `AFTERIMAGE_COLOR_HOLD_TICKS` | `15` | **Sized against the send rate**, not against how long the effect looks right: the 20 Hz it was sized at is ~7-8 ticks at this build's ~150 Hz. At today's 15 Hz default (~10 ticks per sample) the margin is thinner than the row implied — still above one interval, but worth re-checking if the hold ever misses. The failure it fixes was a sampling race — same reasoning as `PULSE_HOLD_TICKS`. |
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
| `PROJECTILE_SAMPLE_INTERVAL_TICKS` | `3` | `MIRROR_PEER_PROJECTILE`. ~50 samples/sec at ~150Hz. `FindAllOf` on one class is a class-scoped lookup, not a walk of every object, and a shot is airborne for well under a second — so the cadence governs how often the sender LOOKS, not how often the peer is told. |
| `GHOST_SPAWN_FADE_GUARD_TICKS` | `10` | `GHOST_FADE_GUARD`. The same margin `GHOST_SPAWN_CAMERA_GUARD_TICKS` uses for the same event — the spawn-time camera steal lands 2-3 ticks after the spawn every time. |
| `PROJECTILE_WATCH_INTERVAL_TICKS` | `30` | `GHOST_PROJECTILE_WATCH`. **~5Hz was too slow twice** — the hit-list and per-component collision reads both came back "nothing happened" across an attack that did damage, because a swing's hit window is a few FRAMES. Those two reads were moved to per-tick; this cadence still governs the projectile sweep, where an actor lives long enough to be sampled. |
| `SHADOW_PROBE_INTERVAL_TICKS` | `30` | `SHADOW_COMPONENT_PROBE`. ~5 samples/sec at ~150Hz. The trace logs on CHANGE, so this buys resolution rather than log volume — but each sample re-reads a few properties per actor, which is why it is not every tick. |
| `VFX_PROBE_INTERVAL_TICKS`, `VFX_PROBE_PATH_FILTER`, `VFX_PROBE_NAME_FILTERS` | `450`, `"/Game/"`, `{"Weapon","Aura"}` | `VFX_CATALOG_PROBE`. The name filter is **deliberately widenable, never a hardcoded set of asset names** — clear the array to go back to all 58. A human-watched catalog needs a shortlist; that is `_template/README.md`'s rule. |
| `GHOST_SPAWN_WEAPON_TRACE_DELAY_TICKS` | `150` | `GHOST_SPAWN_WEAPON_TRACE` |
| `ROTATION_INTERP_MAX_T` | `10.0` | `GHOST_ROTATION_SLERP`. A defensive ceiling on the core's interpolation fraction, not a tuning value. Above 1 is legitimate — under `-extrapolate` the core continues the arc past the newest sample for the same window it predicts position over — and the core caps it there already against its own setting. This is the second belt, because those bytes crossed a socket and an unbounded multiplier on an angle is a ghost spinning at a rate no game produced. 10 covers a 300ms prediction over a 50ms gap (T = 7) with room to spare. |
| `AFTERIMAGE_DISCOVERY_INTERVAL_TICKS`, `AFTERIMAGE_DISCOVERY_SAMPLE_DELAY_TICKS` | `450`, `30` | `AFTERIMAGE_DISCOVERY`. **The sample delay was 3, and 3 was wrong** — at that delay the probe reported "0 new objects" and concluded afterimages were pooled, the exact opposite of the truth. A probe's own cadence can invert its conclusion. |
| `AFTERIMAGE_COLOR_SCAN_INTERVAL_TICKS` | `15` | the retired colour scan. Its predecessor at 3 ticks (~50 Hz) did per-object string work on the game thread and **truncated the very bursts it was counting** — the 2026-08-16 regression. |
| `AFTERIMAGE_CALL_TEST_INTERVAL_TICKS` | `180` | `AFTERIMAGE_CALL_TEST` |
| `AFTERIMAGE_COLOR_TEST_RGB` | `{1,0,1}` (magenta) | `AFTERIMAGE_COLOR_TEST_OVERRIDE` — deliberately a colour the game never produces, so the colour path can be proven independent of detection. |
| `AFTERIMAGE_COLOR_OBSERVE_LOG_COUNT`, `_BURST_LOG_COUNT`, `_SPECIAL_LOG_COUNT` | `40`, `400`, `200` | log budgets, so a capture ends rather than filling a session. |
| `REUSE_MOVE_THRESHOLD`, `AFTERIMAGE_REUSE_MOVE_THRESHOLD` | `5.0`, `5.0` | `AFTERIMAGE_COUNT_REUSE`. An afterimage never moves once spawned, so this only has to clear read noise. |
| `COLOR_MATCH_EPSILON`, `COLOR_EPSILON`, `ULTRA_EPSILON` | `0.01f`, `0.002f`, `0.0001` | float comparison tolerances for colour and ultra-hop detection. |
| `MONTAGE_DIVERGENCE_CHECK_INTERVAL_TICKS` | `4` | the montage divergence check. |
| `HIJACK_EXCLUDE_KEYWORDS`, `NEEDLE`, `RELEASE_CANDIDATES` | name lists | leftovers of the retired hijack design and of the crouch-release input search. |
