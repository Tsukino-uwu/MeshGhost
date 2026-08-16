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

### 1. The slide render-Z compensation (+43 units)

`MeshGhostPseudo/Mod/src/Plugin.cpp`, the `slide_z_comp` block at the receive site. During a peer's
slide the ghost's render target Z is raised by `GHOST_STANDING_CAPSULE_HALF - peer_capsule_half`,
so it stops sinking into the floor.

**It is not a guess, and that is why it survived.** The mechanism was measured (`verified.md`): a
slide shrinks the player's capsule 65 → 22 and drops its origin 567.2 → 524.2, feet planted.
Mirroring the ghost's `CapsuleHalfHeight` was tried, confirmed to apply (read back 22), and fixed
nothing — the skeletal mesh hangs off the capsule at a **fixed −65 offset set at construction**,
and it is the player's own crouch logic, which an unpossessed ghost never runs, that adjusts it.

So it is precisely the tell the rule names: it *compensates* for a value the game would have set,
instead of making the game set it. **And it has already started to spread** — `Plugin.cpp`
describes a second bug, the thrown-weapon prop, as "structurally the same bug as the slide
floor-sinking fix".

**Replacement, leads and the probe to run first:** `../../agent_docs/ideas.md`, the slide entry.
User-flagged 2026-08-16.

### 2. The camera guard's 10-tick fallback window

`Plugin.cpp:213-217` (`GHOST_SPAWN_CAMERA_GUARD_TICKS = 10`) and `:4842-4858`.

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

`call_set_actor_location_and_rotation` (`Plugin.cpp:3164-3263`) fixes it with a local
version-branching helper, and its own comment says the scope plainly: *"this only covers
`K2_SetActorLocationAndRotation`, the one rotation-writing function this file actually calls."*

**Every other `FRotator`-taking SDK call is still broken**, so any future rotation write is a
latent bug until this is generalised. It is listed here because it behaves like the worst kind of
bandage — silent, plausible-looking, and waiting for the next call site — even though the existing
fix is correct for the one place it covers.

**Live trap:** the slide's lead 3 (write the mesh component's own `RelativeLocation`) is exactly
such a call. Route any new transform write through a helper modelled on `:3229-3257`, or write
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
- **`SLIDE_REFIRE_WINDOW_TICKS`.** Cuts off new slide-trail spawns ~40 ticks into the 87-tick
  slide, because images spawned late outlive the move. Left deliberately loose — tightening further
  risks visibly truncating the trail, which reads worse than a slightly long tail. `verified.md`.
- **Keying the slide trail on the capsule shrink rather than a state enum.** Three enum-based
  triggers were tried and all fired on the wrong moves; the shrink is a *physical fact* of the move.
  The reasoning is inline and in `verified.md`.
