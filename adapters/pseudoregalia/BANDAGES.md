# Bandages — Pseudoregalia

Shipped compensations in this adapter: **a fix that restores, forces, compensates for, or
remembers a value rather than preventing whatever changed it.** The rule, its one narrow
exception, and what it is *not*: `adapters/_template/README.md` ("a bandage fix is not a finished
feature").

From the repo-wide audit of 2026-08-16. Its headline holds here too: most things that *look* like
bandages are not — the great majority carry the live incident, the rejected alternative, and the
derivation right beside them. Ranked by how likely each is to cause a real bug.

Other registers: `../tevi/BANDAGES.md`, `../pokemon/emerald/BANDAGES.md`,
`../../agent_docs/bandages-core.md`.

## Is this a bandage? — the short form

Full version, including all seven after-the-fact tells: `../_template/BANDAGES.md`.

**The one mechanical test:** does the fix **prevent** the wrong thing, or **correct** it
afterwards? Correcting afterwards means the cause is still running. Then: *"what would make this
unnecessary?"* (a proper fix has no answer) and *"where did this number come from?"* — measuring
the mechanism, or trying values until it looked right?

**Writing it:** watch for *almost*, *good enough*, *for now* in your own reasoning, and for code
that *restores*, *forces*, *remembers*, *re-applies*, or *offsets* a value.

**Discovering it later — you will not always know at the time.** Add an entry if any of these
happen: its cause got fixed somewhere else and the fix is still there; a second bug gets described
as *"structurally the same bug as X"*; it outlived its purpose and became the bug itself; a
constant needs re-tuning when something unrelated changes; removing it breaks something it was
never about; you can't explain it without describing a sequence; it needs a companion fix elsewhere
to stay correct.

**When in doubt, log it.** A false positive costs one line under "Deliberate".

## Open compensations

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
`../../agent_docs/verified.md` (2026-08-17); how the game does it is in `documentation.md`.

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

**Every other `FRotator`-taking SDK call is still broken**, so any future rotation write is a
latent bug until this is generalised. It is listed here because it behaves like the worst kind of
bandage — silent, plausible-looking, and waiting for the next call site — even though the existing
fix is correct for the one place it covers.

**Live trap:** the slide's lead 3 (write the mesh component's own `RelativeLocation`) is exactly
such a call. Route any new transform write through a helper modelled on
`call_set_actor_location_and_rotation`'s `UE_COPY_VECTOR` mirror, or write
in place through the `GetValuePtrByPropertyNameInChain<FVector>` pointer — never a bare SDK
`K2_SetRelative*`.

Detail: `../../agent_docs/pitfalls.md`, `../../agent_docs/verified.md`. A separate sign error found
in the same investigation (`FRotator::Quaternion()` missing a negation on `Y`) is harmless for this
pawn — pitch and roll are confirmed always zero — and was left unfixed deliberately.

## Borderline — noted, not urgent

None currently recorded for this adapter.

## Deliberate — do NOT "fix" these

Recorded so a future audit does not churn them.

- **The loopback ghost's sideways offset.** A deliberate render-only displacement so a test ghost
  never overlaps the player. Measured design decision, not a tuned value.
- **`SLIDE_REFIRE_WINDOW_TICKS`, and keying the slide trail on the capsule shrink.** Both were
  deliberate, and both are now **dormant**: `AFTERIMAGE_TRIGGER_FROM_OBSERVATION` is on, so the
  ghost trails when the game is *seen* to spawn afterimages, and the reconstructed triggers those
  two belong to are switched off to avoid double-counting a burst. Left in place as a real revert
  path — the flag gates the enumeration, not just the decision it feeds. `verified.md`.
