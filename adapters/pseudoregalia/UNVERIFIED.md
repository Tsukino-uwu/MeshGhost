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

## FOUND, then CORRECTED — health is `CurrentHp` on the GameInstance, and the ghost does NOT corrupt it

**The field, measured.** `CurrentHp` (Double) on the object the pawn holds as
`As MV Game Instance Ref`. Max 80, exactly 5 per pit fall, heal restores to 80, death 0, respawn
80. Found by diffing GameInstance snapshots across a run the user drove deliberately — attack for
heal stock, pit repeatedly, heal to full, pit until death. It is not on the pawn: every
health-shaped pawn property is config (`healAmountPerDing`, `HPpiecesNeededForHeart`, `hitsToFill`).

**The control experiment settled the rest, and it was the user's own design** (*"should we do a non
ghost probe on losing/gaining health/current health? and then one with a ghost next to us?"*):

| | `CurrentHp` value | health bar on screen |
| --- | --- | --- |
| **No ghost** | correct | **correct** — user-confirmed |
| **With a ghost** | **correct** | **stuck visually full** |

**So the shared-singleton theory is REFUTED.** `CurrentHp` moves correctly with a ghost present —
damage, heal, death and respawn all land on the right values. The ghost is not writing the player's
health. **The bug is the HUD display alone**, and everything built on the other reading is wrong:

- Clearing `As MV Game Instance Ref` / `UI_HudRef` / `BP_HpHitable` / `LastHitBy` on the ghost
  (`GHOST_DECOUPLE_SHARED_STATE`) — all four confirmed cleared in the log, no effect. **Separately
  useful as a fact: clearing a cached pointer decouples nothing**, since any actor reaches the
  singleton via `GetGameInstance()`.
- Zeroing the ghost's damage fields — `lightAttackDamage` 15→0, `heavyAttackDamage` 50→0,
  `projectileFullDamage` 45→0 all confirmed applied, and `obtainedProjectile?` was **already
  false** — and the ghost still hits the player with its first charge attack. So the damage comes
  from neither the pawn's damage numbers nor its projectile unlock flag.

**Both fixes are still in place and both are unproven.** Neither made anything worse; neither did
what it was built to do. They should be reverted rather than left as decoration unless a later
finding justifies them.

**Where to look next for the HUD**, and it is NOT another property hunt: the HUD stores nothing
health-related (only `AnimationTickManager` moved across a whole run), so it reads `CurrentHp` live.
A live reader showing a stale value means the widget on screen is not the one being updated, or its
update stopped running. The ghost spawn briefly **possesses** the ghost and then re-possesses the
player — a controller's pawn changing is exactly the kind of thing a HUD binds to. **Test whether
the bar breaks at the moment the first ghost spawns**, which is cheap and needs no new instrument.

**And the standing trap, recorded before anyone reaches for it:** now that `CurrentHp` is known,
the tempting fix is to watch it and restore it. That is a bandage by this project's definition —
restoring a value rather than preventing what changed it — and it would also be fixing the wrong
thing entirely, since the value is already correct.

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

## Pending — the ghost FLOATS UP slightly during a melee sword attack (2026-08-27)

**User-reported, live.** While the peer swings the sword, the ghost rises a little.

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
