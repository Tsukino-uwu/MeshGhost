# Unverified — Pseudoregalia's queue waiting on the user

<!-- line-cap: none -- queue that drains; size is how much the user has not seen yet. Why: agent_docs/claude-md-cap.md. -->

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

## DRAINED 2026-08-27 — the health bar, and the ghost that could damage the player

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

## Pending — a BLACK FLASH when a ghost appears, cause unknown after two negatives (2026-08-27)

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

## Pending — the ghost FLOATS UP slightly during a melee sword attack — SEEN ONCE, never since (2026-08-27)

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

## RESOLVED — "heal" IS healing; the table row is correctly labelled (2026-08-27)

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

## Pending — the FRotator float/double fix is generalised, and the ghost transform path moved onto it

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

## Pending — ghost collision turned OFF again (2026-08-27), and it may cost the cling-gem VFX

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

## Pending — the bridge port walk's SECOND-INSTANCE case is still unwatched (2026-08-27)

The walk itself now runs on every launch and is confirmed: autostart binds 7778 and connects
(`VERIFIED.md`, 2026-08-27), and the sweep's free-port test was rewritten from "did it refuse us" to
"can we bind it" after a measurement showed a closed loopback port on this machine is never refused
at all.

**What is still unwatched is the case the walk exists FOR:** a second game instance finding its own
core one port up while the first keeps 7778. Nothing this session ran two instances. Expect the
second to log `bridge connected on port 7779` with the first unaffected.

## Pending — a hard crash mid-session after the pause menu opened twice (2026-08-17)

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

## Pending — a `Fatal Error!` on game exit, seen once, never root-caused

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

## Pending — every probe under the three UE4SS mod directories predates this queue

`PROBES.md` indexes them (three directories, six scripts). They are the record of how each fact was
established, and several were run before this file existed — so the honest statement is that nothing
in this queue depends on them, and none of their logs is evidence for anything not already in
`VERIFIED.md`.

Kept as an entry so that the *next* probe run has somewhere to land before it is confirmed.

## ONE ghost cosmetic the user saw wrong on screen (2026-08-28) — the LIGHT half only

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

## MEASURED 2026-08-29 — the ghost's PointLight is at 5000 while the player's is at 0

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

## THE PROBE CRASHED THE GAME TWICE — `probe_dustlight/` is DISABLED and must not be re-run as-is

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

## Pending — `bb`, `hw` and `hew` got the one-shot counter treatment and were never watched (2026-08-29)

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
