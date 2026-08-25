# Crystal — bandage register

<!-- line-cap: none -- register; growth is a smell you must be able to SEE, never one to hide by trimming. Why: agent_docs/claude-md-cap.md. -->

**It was empty until 2026-08-19, and that was the point.** Phase 9 exists because the user's call
was to build this adapter without starting from a compensation: *"i want to actually spawn in as
intended now for crystal, so we don't start doing this game with bandaids from the get go"*
(2026-08-17). It carried nothing under Shipped for two days.

**It carries one now, deliberately and on the user's instruction**: the drawn-overflow tier. The
entry below is written the way the guide asks — what it compensates for, what it costs, and what
would retire it.

**A file that is present and empty is the goal; a file that is absent is a gap.** An absent register
cannot tell you whether an adapter has no compensations or merely never wrote them down.

The canonical guide — what counts as a bandage, the mechanical tell, the one narrow exception, and
the user's standing position that a bandage is a state to leave rather than rest at — lives in
[`adapters/_template/BANDAGES.md`](../../../_template/BANDAGES.md). Read it before adding an entry.

## Shipped compensations

### 1. The drawn-overflow tier — peers the engine has no room for are painted, not spawned

**What it is.** `meshghost_crystal.lua`'s drawn tier renders a peer with `gui.*` primitives over
the emulator's output when the engine cannot give it a slot. `MESHGHOST_CRYSTAL_DRAW_OVERFLOW`
(FLAGS.md) turns it off; it is **ON by default**, which is the opposite polarity to Emerald's
equivalent and is deliberate — Emerald's is off because its UI regions are not yet locatable, and
Crystal's are (`VERIFIED.md`, 2026-08-19).

**What it compensates for.** A hard ceiling that is genuinely the game's: 13 object structs, 16 map
objects, 40 hardware sprites at 4 per character, so 10 characters on screen. Past that a peer
would not exist at all.

**Why it was taken, when this file previously named it as a temptation to resist.** The user asked
for it directly after seeing the cap measured: *"cap it, and just draw extras instead if that is
required. i don't want things to pop in/out all the time. i want every player/ghost to be visible
all the time instead"* (2026-08-19). The temptation entry below was written against *"falling back
to drawing if spawning proves unreliable"* — spawning did not prove unreliable, and the spawned
tier is untouched and still the good one. This is an overflow, not a fallback. That distinction is
the whole reason it is defensible, and if it ever starts carrying peers the engine *could* have
held, it has become the thing the temptation warned about.

**What it costs, honestly:**

- **No engine animation.** The adapter animates a drawn peer itself, from frames it learns by
  watching the engine render the local player.
- **No collision, and no interaction.** Used deliberately by the collision policy — an idle peer is
  moved to this tier precisely so it stops blocking — but it means drawn peers are unequal to
  spawned ones in a way a player can notice.
- **Occlusion is re-implemented, not inherited.** Text box and menu regions are detected and
  clipped by us; the spawned tier gets that from the game for free.
- **Two rendering paths in one adapter**, which will drift. That is the cost the guide warns about
  most, and the reason this entry exists.

**What retires it.** Nothing available: the ceiling is the hardware's. It would be retired by a
different rendering strategy entirely, not by fixing anything.

### 2. A standing ghost is re-anchored to the tile it claims to be on

**What it is.** Every frame a spawned ghost is idle, `renderRemote` recomputes `screenCoords` of its
map tile and writes that to its sprite coordinates if they differ.

**Why it is here, in the register's own words.** The "known temptations" list at the bottom of this
file already named it before it was taken: *"re-writing a value every tick to keep a ghost where it
should be — a fix that RESTORES a value rather than preventing whatever changed it."* That is
precisely what this does, so it is registered rather than quietly kept.

**The honest state, 2026-08-22.** The thing it was compensating for was found and fixed:
`OBJECT_STEP_DURATION` was 7, which walks 14px across a 16px tile, so every step ended 2px short and
the error accumulated until the ghost was visibly off the grid. With the step covering a whole tile,
this correction now fires **zero times across 1108 walking frames** — it corrects nothing.

**So why keep it.** As a bound and as an instrument. It reports the size AND direction of any
correction it makes, and a silent zero is a live assertion that nothing is drifting. Retiring it
would remove the only thing that would notice the fault coming back.

**What makes it a real bandage again.** If it ever starts reporting corrections during ordinary
walking, it is hiding a new cause rather than guarding against an old one — and the number it prints
is the first clue to what. It must not be allowed to become the reason a drift is tolerable.

**What retires it.** Nothing planned. It is cheap, silent when healthy, and self-reporting when not.

## Deliberate — measured decisions, not bandages

A number **measured from the game** and written down is a design decision with evidence behind it,
not a compensation. These are logged so a later audit does not churn them — and so that the day one
of them stops being measured, the entry is already here to be corrected.

- **The adapter applies the first 2 px of every step itself.** `stepGhost()` writes the game's own
  step-initiation set and then adds ±2 to the ghost's sprite X/Y in the same frame. It looks
  exactly like the tell — a value nudged by hand right after the engine was asked to do the job —
  and it is not one, because the *mechanism* is known rather than the *symptom*: **the engine
  applies its own first 2 px increment in the frame it initiates a step**, and ours begins a frame
  later. Without the addition every step lands 2 px short and the error accumulates, so this is
  starting the ghost from the same place the engine starts a real character, not correcting it
  afterwards. Established by watching a real NPC take one step frame by frame
  (`probes/step_watch_probe.lua`) — the same capture that overturned the movement plan before any
  code was written. **What would let it go:** initiating the ghost's step in the same frame the
  engine would, which needs a write that lands before the engine's own step pass rather than after
  it. If that ever becomes possible, this line should disappear rather than be re-tuned. A *tuned*
  version of this — nudging the number until it looked right — would belong in Shipped, above.
- **`MESHGHOST_CRYSTAL_AP_TRY` substitutes a named candidate address for an unmeasured one.**
  Superficially the shape a bandage takes: continuing on data known to be uncertain. It is
  deliberate, and every clause of how it is built is what keeps it out of Shipped. It is
  **off by default** and a missing address otherwise **refuses to run** rather than falling back;
  it substitutes only from an explicit `candidates` table kept separate from the real fields,
  precisely so a candidate that ordinary code can read does not quietly get treated as measured;
  it logs `UNCONFIRMED ADDRESS IN USE` on **every** startup, so a session run this way can be told
  apart afterwards; and it announces that nothing seen in that session may be written to
  `VERIFIED.md` as a fact. **It lowers the bar to *unconfirmed*, never to *invented*** — a missing
  candidate still refuses. `release.yml` fails the build if `ap_try.flag` reaches the package.
  **It is currently INERT, and that is the interesting part.** Every address the startup check
  requires has now been measured (`W_BATTLEMODE`, the last holdout, on 2026-08-19 with
  `probes/ap_battlemode_probe.lua`), and `candidates` is an empty table — so the flag has nothing
  left to substitute and turning it on changes nothing. The one address still unmeasured on the
  Archipelago build, `W_USEDSPRITES`, is not in the required list at all: it is optional by
  design, and its absence switches the peer's own appearance off rather than refusing to run.
  **What would let it go:** deleting it, once someone is satisfied that no further Archipelago
  address will need the same treatment. Kept for now because the mechanism is the valuable part
  and rebuilding it correctly is harder than leaving it. Registered in [FLAGS.md](FLAGS.md) as a
  runtime switch.

### 5. Repairing a step state the engine should never be in — cause unknown

**What it is.** Before stepping a ghost, `renderRemote()` checks for `OBJECT_WALKING == STANDING`
alongside a walking `OBJECT_STEP_TYPE`, and if it finds that pair puts the object through the
engine's own end-of-movement path (`STEP_TYPE_FROM_MOVEMENT`, duration 0). Counted, and reported
once a second when it is not zero.

**Why it is a bandage.** It repairs a state instead of preventing it, which is exactly the tell the
guide names. The pair is not one the engine produces for its own objects — every step function sets
`WALKING` and `STEP_TYPE` together — and `stepGhost()`'s own write of `WALKING` reads back correct
every time it runs, so the state arrives *between* our steps and nobody has found what writes it.

**What it costs if left.** Nothing visible, and it prevents something severe: `StepVectors` has 12
entries and `GetStepVector` indexes it with `WALKING`'s low nibble, so `STANDING` (255) masks to 15
and the engine reads a step vector out of whatever follows the table, applying it every frame until
the duration expires. The user, 2026-08-21: *"it gets dragged off screen"*. Caught by
`probes/orphan_probe.lua`, which dumps the ten frames leading up to it.

**What removing it needs.** The writer. The ten-frame trace in `orphan_probe.lua` is the instrument;
what is missing is a capture of the frame the pair first appears with the adapter's own step
accounting alongside it.

## Known temptations, recorded before they are taken

Not bandages — none of these has been taken. Listed because each is a place where a compensation is
the obvious next move, and naming them early makes taking one a decision rather than a slip.

- ~~**Falling back to drawing an overlay if spawning proves unreliable**, and leaving both paths
  in.~~ **A drawn path was added 2026-08-19 — see Shipped entry 1 — but NOT for this reason.**
  Kept here rather than deleted, because the distinction is the thing worth preserving: this
  temptation was about drawing *instead of* spawning when spawning disappoints. What shipped
  draws only what the engine has no room for, and spawning is still first choice for every peer
  that fits. If a future change ever starts drawing peers the engine could have held, this
  temptation has been taken after all.
- **Writing an object struct directly instead of going through a map object.** It renders, and it
  was the first thing that worked — but it produces a half-owned object the engine does not
  maintain, with collision and sprite drifting apart. Any future use of that shortcut is a bandage
  and belongs here with the reason.
- **Re-writing a value every tick to keep a ghost where it should be.** The tell from the guide
  applies directly: a fix that *restores* a value rather than preventing whatever changed it.
