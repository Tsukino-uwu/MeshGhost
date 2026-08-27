# Bandages — Pseudoregalia

<!-- line-cap: none -- register; growth is a smell you must be able to SEE, never one to hide by trimming. Why: agent_docs/claude-md-cap.md. -->

Shipped compensations in this adapter: **a fix that restores, forces, compensates for, or
remembers a value rather than preventing whatever changed it.** The rule, its one narrow
exception, and what it is *not*: `adapters/_template/README.md` ("a bandage fix is not a finished
feature").

From the repo-wide audit of 2026-08-16. Its headline holds here too: most things that *look* like
bandages are not — the great majority carry the live incident, the rejected alternative, and the
derivation right beside them. Ranked by how likely each is to cause a real bug.

Other registers: `../tevi/BANDAGES.md`, `../emulator/pokemon/emerald/BANDAGES.md`,
`../emulator/pokemon/crystal/BANDAGES.md`,
`../../agent_docs/bandages-core.md`.

## Is this a bandage?

The canonical guide — the one mechanical test, the tells while you are writing it, the eight
tells that only show up later, and the one bandage shape to avoid outright — lives in
[`adapters/_template/BANDAGES.md`](../_template/BANDAGES.md). Read it before adding an entry.

## Open compensations

### 0. Parking a despawned ghost at Z = -500000 instead of destroying it

**Never registered here until 2026-08-17, despite already being live** — found when the user
called it "a pretty big bandage right now i think", checked the register, and it was not in it.
Recorded now, including that omission, because an unregistered compensation is the case this file
exists to prevent.

**What it does.** `release_ghost` moves a despawning ghost to `DESPAWN_PARK_Z` (-500000) via the
same move call the redraw loop uses, rather than removing it. It fixed something real: before it,
a peer leaving *mid-area* left its ghost standing frozen and visible until the next area
transition.

**Why it existed.** The recorded reason was that `K2_DestroyActor` "silently no-ops on this build"
and that the ghost "was never ours" — both from the **hijack** design, where the ghost was a
`StaticMeshActor` belonging to the level. Destroying it would have deleted level geometry.

**Why it is now questionable.** Since Phase 7.6 the ghost is spawned by us from the player's own
pawn class, so it *is* ours, and `pitfalls.md`'s 2026-08-17 audit already narrowed the no-op claim
to that specific actor rather than the build. **Live-tested 2026-08-17 with
`GHOST_DESTROY_ON_DESPAWN = true`: `K2_DestroyActor` was reflected and called on every zone
transition, repeatedly, with no crash** — so the premise for parking is gone for that path. See
the template's "the bandage to avoid entirely: borrowing an object instead of creating one".

**Now tested, 2026-08-17 — both despawn paths are covered.** The case this was written for, a peer
despawning *mid-area* with no level transition behind it, finally ran: a `cmd/meshghost-fakeadapter`
peer circling the player was stopped cleanly, the relay forwarded the leave, and 60 ms later
`release_ghost` called `K2_DestroyActor`. **The ghost disappeared on screen and the game kept
running** — user-confirmed. An earlier attempt that killed the *relay* did not count, because that
removes the very thing that would deliver the peer's leave. `VERIFIED.md`.

**Status: the park is now a fallback, not the mechanism.** `call_destroy_actor` returns false when
the function is not reflected, and parking is what happens then — so it still earns its place, and
removing it would leave that branch with nothing. But it is no longer what normally runs, and the
premise that once justified it (the ghost is not ours, destroy no-ops) is dead on both halves.

**What would let this entry be deleted outright:** confidence that no supported build can reach
the no-reflection branch. Nobody has checked that, and the cost of keeping the fallback is a few
lines, so it stays.

### ~~1. The slide render-Z compensation (+43 units)~~ — REMOVED 2026-08-17

**Gone, and replaced by the game's own pose path rather than a better compensation.** The ghost is
now posed by the game itself: its capsule mirrors the peer's, the slide Blueprint Timeline's curve
is driven with the peer's own `slide_t` through `Timeline_1__UpdateFunc`, the Blueprint's crouch
input and crouch events are fired, and `bIsCrouched` is set and cleared on the peer's edges.
User-watched: *"everything works now, and looks identical to the player."*

No longer shipped: `GHOST_SLIDE_Z_COMP` is `false` in `Plugin.cpp`, so nothing is added to the
ghost's Z any more. The disabled code path is still in the file alongside the dated comments that
explain why it went — retiring it fully is a tidy-up, not an open compensation.

**Kept as a struck-through entry, not deleted**, because the register's job is to show that entries
here are expected to leave — see the standing position in `../_template/BANDAGES.md`. The full
mechanism, the two findings that cracked it, and the nine dead ends are in
`VERIFIED.md` (2026-08-17); how the game does it is in `documentation.md`.

**The durable lesson**: every one of the five mechanisms tested NEGATIVE on its own, and the
working configuration is their union. "A alone does nothing" never meant "A is useless" — this
game's pose path has preconditions, and testing one lever at a time could not have found it.

#### What the bandage did, versus what the game does

| | Bandage (`+43` render Z) | The game's own path |
| --- | --- | --- |
| What moved | the ghost's **whole actor**, every tick a peer was short | the **mesh**, by the game's own maintenance |
| Who decided the number | our arithmetic, `65 − peer half` | the game — we set state, it computes |
| Ghost's actor Z | 43 units wrong for the whole slide | truthful; matches the peer exactly |
| Collision capsule | standing-size while the pose was crouched | mirrors the peer, matches the pose |
| Crouch (not slide) | worked **by accident** — same capsule shrink, never reasoned about | handled because the game handles it |
| A future move that shrinks the capsule | silently inherits the guess | follows for free |
| Anything reading the ghost's Z | inherits the lie — and it had already spread once, to the thrown-weapon prop | reads the truth |
| Cost | ~10 lines | 5 mechanisms plus one wire field (`slide_t`) |

**The row that matters most is the accidental one.** The bandage handled a stationary crouch
correctly without anyone knowing why — crouch happens to shrink the same capsule, so the same
offset happened to be right. That is the difference between a fix and a coincidence that has not
failed yet, and it is exactly what "worked for the case it was written for" looks like from the
inside.

**And it looked perfect.** The replacement looked worse for most of ~15 test cycles. See
`../_template/BANDAGES.md`, "The bandage will usually look BETTER than the proper fix".

### 2. The camera guard's 10-tick fallback window

`Plugin.cpp`, `GHOST_SPAWN_CAMERA_GUARD_TICKS = 10` and the camera-switch hook that consults it.

**The primary test is real and precise, not a bandage**: a camera switch is rejected when the
target rig's `OwningActor` is one of our ghosts — a property found by dumping a rig caught
mid-steal. That replaced a genuine fight-back (block every camera change forever), which was
deleted 2026-08-16 for being worse than the bug it fixed.

**The tick window is the leftover.** It still rejects a switch during the 10 ticks after a ghost
spawn *when the rig cannot be identified at all* — a timing correlation standing in for a test,
which is the shape the rule names. Mitigating facts, both recorded at the constant: the switch is
measured at 2-3 ticks every time so 10 is margin not tuning, and outside the window the game keeps
every camera decision it makes.

**Fix:** find why a rig would resolve neither `OwningActor` nor `Owner`, or drop the fallback and
accept the identified-only test.

## Not a compensation, but worse than most of them

### The FRotator float/double bug is fixed at exactly one call site

The vendored RE-UE4SS SDK marshals `FRotator`'s Pitch/Yaw/Roll as hardcoded `float` into the
reflected parameter buffer, unlike `FVector`, which correctly branches on engine version via
`UE_COPY_VECTOR`. Pseudoregalia is UE 5.1, where those fields are `double` — so 4 bytes of float
land in an 8-byte slot and the engine reads back a denormal near zero.

`call_set_actor_location_and_rotation` (`Plugin.cpp`) fixes it with a local
version-branching helper, and its own comment says the scope plainly: *"this only covers
`K2_SetActorLocationAndRotation`, the one rotation-writing function this file actually calls."*

**GENERALISED 2026-08-27, and this entry is close to retirable.** `write_struct_triple` plus its
two named wrappers `write_vector_param` / `write_rotator_param` (`Plugin.cpp`, immediately above
`call_set_actor_location_and_rotation`) now carry the version branch, the inner-field resolution
and a refuse-rather-than-half-write return, so there is a correct thing for the next author to
reach for instead of a bare SDK call.

**The one existing call site was migrated onto the helpers in the same pass, deliberately.**
Leaving them unexercised would have reproduced exactly the failure mode this entry predicted — a
plausible-looking path nobody runs until a new feature reaches for it, at which point a defect in
the shared helper presents as a bug in the new feature. Migrating puts them on the most-run
reflected call in the adapter, where a ghost standing in the wrong place or facing the wrong way
is immediate, unmissable, every-session evidence.

**Why it is not deleted yet: it compiles, and nothing has watched it.** Behaviour-preserving by
construction is not the standard this project holds adapter changes to — `UNVERIFIED.md` carries
it until a ghost is seen positioned and facing correctly. The original scope note is also still
literally true of the *SDK*: RE-UE4SS's own `FRotator` marshalling is untouched, and a call made
without these helpers is still broken. This is a safe route past the bug, not a repair of it.

**Live trap:** the slide's lead 3 (write the mesh component's own `RelativeLocation`) is exactly
such a call. Route any new transform write through a helper modelled on
`call_set_actor_location_and_rotation`'s `UE_COPY_VECTOR` mirror, or write
in place through the `GetValuePtrByPropertyNameInChain<FVector>` pointer — never a bare SDK
`K2_SetRelative*`.

Detail: `../../agent_docs/pitfalls.md`, `VERIFIED.md`. A separate sign error found
in the same investigation (`FRotator::Quaternion()` missing a negation on `Y`) is harmless for this
pawn — pitch and roll are confirmed always zero — and was left unfixed deliberately.

## Borderline — noted, not urgent

None currently recorded for this adapter.

## Shipped compensations

- **`SLIDE_SEAM_HOLD_MS` — holding a ghost's slide pose across the seams between repeated slides.**
  A held slide is a ~600ms action that re-triggers, and the capsule really does return to standing
  for 14-153ms in between (`documentation.md`). The ghost mirrored that faithfully and looked wrong
  for it, because a player's mesh is animation-blended through those seams while a ghost is posed
  discretely through the game's crouch system, which cannot start and finish a transition inside
  14ms. Every seam became a visible pose bounce, reported as the slide feeling "delayed".
  **Why it is a bandage and not a fix:** it makes the ghost show something the peer's capsule was
  not doing at that instant, to compensate for the pose mechanism being slower than the data. The
  real fix is a ghost posed by the same animation path the player uses, which nothing here has
  found. **The tell that it is still a bandage:** the threshold is a duration, and durations
  compensating for a mechanism's latency are exactly the shape that quietly stops matching when the
  mechanism or the game changes.
  Bounded and asymmetric on purpose: too long costs up to 200ms of stale pose after a genuine
  stand-up, too short restores the bounce. Derived from the empty band between two measured
  populations, so **re-measure with `GHOST_MESH_Z_TRACE` rather than nudging it** if a game update
  changes the slide.

## Deliberate — do NOT "fix" these

Recorded so a future audit does not churn them.

- **The loopback ghost's sideways offset.** A deliberate render-only displacement so a test ghost
  never overlaps the player. Measured design decision, not a tuned value.
  **Do not "improve" it into a vertical offset.** `LOOPBACK_GHOST_OFFSET_Z` exists and the idea
  comes up on its own merits — a sideways offset shifts a valid position without re-grounding it,
  so over sloped geometry the ghost ends up buried or floating, and since the ghost is a real pawn
  with collision and the game's own movement running on it, that is a genuine source of oddities
  (`VERIFIED.md`, 2026-08-17). Offsetting up would remove that entirely. **It is still refused**,
  by the user, for a better reason than the one it solves: side by side **at the same ground
  level** is what makes pose and timing directly comparable, and vertical separation puts the two
  at different heights and hides exactly the 1:1 differences the loopback rig exists to reveal.
  The rig artefact is the accepted cost; judge loopback-only oddities in impossible positions
  accordingly rather than fixing the offset.
- **`SLIDE_REFIRE_WINDOW_TICKS`, and keying the slide trail on the capsule shrink.** Both were
  deliberate, and both are now **dormant**: `AFTERIMAGE_TRIGGER_FROM_OBSERVATION` is on, so the
  ghost trails when the game is *seen* to spawn afterimages, and the reconstructed triggers those
  two belong to are switched off to avoid double-counting a burst. Left in place as a real revert
  path — the flag gates the enumeration, not just the decision it feeds. `VERIFIED.md`.
