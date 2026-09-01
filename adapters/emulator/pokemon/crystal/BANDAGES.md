# Crystal — bandage register

<!-- line-cap: none -- register; growth is a smell you must be able to SEE, never one to hide by trimming. Why: agent_docs/claude-md-cap.md. -->

**It was empty until 2026-08-19, and that was the point.** Phase 9 exists because the user's call
was to build this adapter without starting from a compensation: *"i want to actually spawn in as
intended now for crystal, so we don't start doing this game with bandaids from the get go"*
(2026-08-17). It carried nothing under Shipped for two days.

**It carries four live**: the drawn-overflow tier (#1, 2026-08-19), the standing ghost's re-anchor
(#2), that tier's camera-clocked beat (#3, 2026-08-25), and the step-state repair (#5, cause still
unknown). A fifth — the fly-arrival drop (#4) — was added and retired on 2026-08-26, and is kept
below marked as such: the route out was written
into the entry, and it is the route that was taken. Each entry below is written the way
the guide asks — what it compensates for, what it costs, and what would retire it. The second is
the more instructive one: its proper mechanism is **known and written down**, which is what makes
it debt rather than a ceiling.

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

### 3. The drawn tier's beat and paint are both the CAMERA, so its rhythm is smoother than the game's

**What it is.** The drawn model moves on the frames the background scroll register changes, and is
painted by a camera formula (an accumulator plus a constant `K`, with a park-time nudge repaying
the drift between that formula and the tile-derived one).

**What it compensates for.** `screenCoords()` — tile, camera offset and scroll — is only coherent
at tile boundaries, because those terms update at different moments inside a step. The camera
accumulator exists to have a world-to-screen mapping that survives mid-scroll.

**What it costs, measured 2026-08-25** (three-way trace, raw frames, dev rig at `-interp=0`):

- **The drawn ghost's beat is metronomic where the engine's is not.** The player advances at frames
  649, 651, 652, 654 — gaps of 2, 1, 2, 2 — and the model at 647, 649, 651, 653, a perfect 2 every
  time. Smoother than the game, which `adapters/CLAUDE.md` names as its own defect: *"the engine's
  RHYTHM is as visible as its speed"*. The spawned ghost does not have this, because the engine
  moves it and it inherits the irregularity for free.
- **A constant one-frame phase** behind the player and the spawned ghost. Constant, so it is the
  invisible kind — the user, looking at all three side by side: *"it looks visually the same to me
  i think"* — but it is not 1:1 and is recorded rather than called finished.
- **All the machinery listed above is this entry's cost too**: `K`, the drift accumulator, the park
  nudge, the 1px repayment, the rebase plausibility test. Each exists to survive the mapping.

**What would retire it — the mechanism is known, which is why this is debt and not a ceiling.**
`liveScreenCoords()` (written 2026-08-25 for the promotion fix) maps any world position to the
screen exactly on **every** frame, mid-scroll included, by anchoring on the player's own object
rather than on the scroll registers. Paint from that and the camera formula and its whole
repayment apparatus are unnecessary. The rhythm then has to come from **the peer's own `prog`**,
which is already on the wire and carries the peer's engine's irregular timing — **not** from the
local player, which would look perfect in loopback and be wrong the moment a second machine joins,
since a real peer walks while the local player stands still. The model itself stays: its remaining
job is smoothing arrival jitter (~7% of frames carry zero or two messages).

**Proven so far:** `liveScreenCoords` is measured correct for *placement* — 8 promotions, every
landing 0.0px, no wobble. It has **not** been tried as a per-frame paint origin; that is the first
measurement, and it is cheap (paint the compare copy from it and diff frame by frame against the
current formula).

**Why it is still here.** The user's call, 2026-08-25, after watching all three: *"good nuff/
intended bandage to keep it as it is right now then?"* — taken with the queue in `UNVERIFIED.md`
unwatched, including six animation classes never seen on screen at all. Left deliberately, with
the route out written down, rather than rested at.

### 4. RETIRED 2026-08-26, the same day it was added — the fly arrival is the real animation now

**Kept below as written, because a retired entry is evidence and this register is append-only in
spirit: it shows what the compensation was, and that the route out written into it was the route
actually taken.** The user's call, hours after choosing to keep it: *"try to fix the 'pokemon
sprite & landing animation, for a different town' so we don't have to use the 'falling' bandage
anymore."*

**What replaced it.** The peer's fly SPECIES now crosses the wire (`extras.fly`, latched with the
map-entry byte because `wCurPartyMon` moves as soon as a menu opens), and for the 44 frames of a
landing the ghost is not a character at all: the engine object is parked with a STANDING facing —
drawing nothing, exactly as the game hides every character through a fly — while the painted tier
flies that Pokemon's ICON down on `SpriteAnimFunc_FlyTo`'s own curve. `88 - 2k` pixels above the
landing tile, `(88 - 2k) * cos(k * pi/32)` to the side, two frames of art alternating every eight
with the fourth x-flipped. Every number is the engine's; none is tuned.

**What this entry cost while it stood**: about half a day of live cycles, because a vertical fall
was near enough to look like a bug rather than a placeholder, and each attempt to make it land
correctly was work on the wrong animation. **The lesson is not "do not use a stand-in" — it is that
a stand-in for something ANIMATED reads as a defect, so it buys much less time than one for
something static.**

---

### 4 (as it stood). A fly ARRIVAL uses the engine's floor-fall, which is not what a Fly landing looks like

**What it is.** A peer that arrives by Fly is dropped onto its tile with `STEP_TYPE_SKYFALL` (the
Burned Tower floor-fall) on the spawned tier, mirrored on the painted tiers by a matching hide-then-
fall envelope. Added 2026-08-26 on the user's call, in preference to the ghost simply appearing.

**What it compensates for, and why it is not 1:1.** The real landing is not a fall and not the
character: `SpriteAnimFunc_FlyTo` swoops the **Pokémon's icon** down from the top of the screen on a
**decaying-cosine spiral**, the side-to-side swing shrinking to nothing as it settles
(`documentation.md` has the full trace). No timing of a vertical skyfall can resemble that, so this
is a stand-in rather than an approximation that could be tuned into correctness. The user, seeing
it: *"they just 'dropped down' instead of doing the fly landing animation"*, and, offered the
choice between building the real one, reverting to a plain appearance, or keeping this: *"keep the
drop for now"*.

**What it costs.** A watcher sees a motion the game never shows. It is also the one place this
adapter animates a peer from something other than the peer's own object state, so it can never be
made more correct by better wire data alone.

**What retires it.** The real landing, which needs three things and is specified in `UNVERIFIED.md`:
the peer's fly SPECIES on the wire, a mon-icon graphics path (icons are a different family from the
walking sprites both tiers draw from), and the decaying-cosine descent in place of the fall. The
spawned tier probably cannot wear an icon at all, so that peer would be hidden until it lands —
which is what the engine does to the flier anyway.

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
  candidate still refuses. `dev-scripts/stage-release.ps1` (run by `release.yml`) fails the build
  if `ap_try.flag` reaches the package.
  **It is currently INERT, and that is the interesting part.** Every address the startup check
  requires has now been measured (`W_BATTLEMODE`, the last holdout, on 2026-08-19 with
  `probes/ap_battlemode_probe.lua`), and `candidates` is an empty table — so the flag has nothing
  left to substitute and turning it on changes nothing. **Eleven** optional addresses are still
  unmeasured on the Archipelago build — `W_USEDSPRITES` and `W_STATEFLAGS`, plus the
  map-connection trio (cross-map ghosts off), `W_SPRITEUPDATESON` (the drawn tier's UI gate never
  fires) and the five Fly-landing entries — and none is in the required list: all are optional by
  design, and their absence switches those features off rather than refusing to run. (This said
  "the one address" until 2026-08-27 and "two" until 2026-09-01 — each correction counted only
  the entries someone had already been bitten by, which is the under-count's own lesson.)
  **What would let it go:** deleting it, once someone is satisfied that no further Archipelago
  address will need the same treatment. Kept for now because the mechanism is the valuable part
  and rebuilding it correctly is harder than leaving it. Registered in [FLAGS.md](FLAGS.md) as a
  runtime switch.

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
