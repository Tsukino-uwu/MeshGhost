# How to investigate a game effect

**Purpose: how to go looking.** This is the procedure — the loop you actually run to find, mirror
and confirm a visual effect in a new game — told through the one investigation that exercised every
part of it. It is deliberately separate from its neighbours:

- [pitfalls.md](pitfalls.md) is *what went wrong* — incidents as symptom → cause → fix. Read it to
  avoid a specific trap.
- [`adapters/_template/README.md`](../adapters/_template/README.md) is *what to build* — enumerate
  before guessing, mirror the decision rather than the rule, latch payloads to their counter.
- **This file is *how to search*.** The order of operations, what each dead end actually taught, how
  to instrument so a run can answer something, and how to tell which of your beliefs is load-bearing.

Written 2026-08-16, immediately after Pseudoregalia's afterimage trail work concluded. The trail was
the longest-running single thread in that adapter — roughly 2026-08-15 to 2026-08-16 across several
sessions — and the ultra hop's blue afterimage was the hardest part of it. Every rule here is
something that work either paid for or was rescued by.

---

## Part 1 — The investigation, start to finish

Read this part for the shape of the thing. The rules in Part 2 are extracted from it, and are much
easier to judge with the story attached.

**The goal**: Pseudoregalia's player leaves a trail of afterimages when sliding, and a
perfect-timing "ultra" hop trails **blue** instead of the usual yellow. Make a ghost do the same.

### Stage 1 — Trying to guess when the effect fires

The first instinct was to work out the *condition*: find the state that means "sliding", and spawn
a trail on the ghost whenever the peer reports it. Three attempts, all reading `actionState`:

- `actionState == 18` looked like the slide. It is also a quick 180° turn-around skid.
- `actionState == 8` looked like the slide-launched backflip. It turns out to mean "backflip"
  generically, including a plain walking one.
- A later capture killed the whole approach: `actionState` read **0 on five of six real bursts**.

**What this cost, and the tell that was missed**: three full build → deploy → play → watch cycles.
Each guess was plausible from the name and each was confidently wrong. The tell was available from
the first failure — the same enum value meant several different moves, so no single value could ever
be the discriminator.

### Stage 2 — Keying on a physical fact instead of an enum

The fourth attempt stopped reading intent and read a *physical consequence*: a real slide shrinks the
player's capsule from 65 to 22. That is not an interpretation, it is a measurement.

It needed two refinements, both from segmenting a dense capture into runs of state:

- A turn-around skid shares `actionState == 18`. The discriminator is `animJumpType`: real slides
  run `as=18` **with** `ajt=13`, skids run `as=18` with `ajt=0`.
- A crouch also shrinks the capsule. Excluded by `moveState` (crouch is 2, slide is 0), and written
  as "not the crouch state" rather than "is the slide state" deliberately, so an unrecognised future
  state still gets a trail instead of silently losing one.

**This worked, and shipped, and was still wrong** — see Stage 11. It was a better reconstruction, but
still a reconstruction of a rule the game already owned.

### Stage 3 — Two things learned about how to touch the effect at all

**Do not hook the Blueprint functions.** `RegisterPostHook` on `Spawn After Image` and
`spawnNumAfterimages` registered successfully — real callback IDs logged — then fired **zero** times
across ~18s of real play, and the game hit a fatal error with nothing logged. UE4SS's hook swaps the
`UFunction`'s own function pointer, which is safe for a *native* function but corrupts execution for
a *Blueprint* one, whose pointer is the shared bytecode entry. A hook that registers cleanly and
never fires is the signature. **Check native vs Blueprint before hooking anything.**

**The apply side, which worked first try and never changed again**: write `afterImagesToSpawn` on the
ghost, then call `spawnNumAfterimages`. Everything that follows is about the *trigger* and the
*colour*; the thing that draws the images was never the problem.

Also measured here: the real burst size is **5**, not the 6 that had been hardcoded. A wrong count
left extra afterimages lingering after every slide — the first version of a symptom that came back
twice more in different forms.

### Stage 4 — Making the trail long enough, and finding the bursts fighting each other

A real slide runs a consistent ~87 ticks, but a single burst at the slide's start left the ghost's
trail visibly shorter than the player's. So the trigger was made to **re-fire while the slide is
held**, every 12 ticks, rather than only on entry.

Then a strange result: asking for *more* did not produce more. A test requesting 25 bursts of 5 —
125 images — produced **49 bodies**, about two per burst.

**The mechanism, and it matters for any counted effect**: the game's own loop counts
`afterImagesToSpawn` **down** as it spawns, across several ticks. A re-fire 12 ticks later
*overwrites the counter mid-countdown*, truncating the burst still in flight. The repeats were
fighting each other, which is exactly why more requests did not help.

Two lasting consequences. First, a spawn window (`SLIDE_REFIRE_WINDOW_TICKS`) was added to stop
re-fires partway through the slide, so the last images land near the slide's own end rather than
~0.5-1s after it — the "tail overhang" that stayed an open cosmetic item until 2026-08-16.
Second, and more important, **this is the same across-ticks spawning that later made the probe in
Stage 9 so destructive**: anything that stalls or interrupts the game thread truncates bursts in
progress. The fragility was documented well before it caused the regression, and the connection was
not made at the time.

### Stage 5 — The coverage gap that nobody chased

Mirroring `afterImagesToSpawn` was verified exact — 6 real bursts detected locally, 6 applied to the
ghost, no drops on either side. And yet some of the player's real afterimages still never reached
the ghost.

The conclusion recorded at the time was precise and correct: **some afterimages come from a path
that never touches `afterImagesToSpawn`.** A dedicated coverage capture found one repeatable case —
inside the bubble that suspends you in the air, where the player's trail persists but
`afterImagesToSpawn` reads 0 across all 2002 ticks of that state.

That note sat in `verified.md` labelled "REMAINING GAP" from 2026-08-15 until 2026-08-16. **It was the answer to Stage 10
and Stage 11 the whole time** — the ultra hop is one of those paths, which is why it fired no
trigger and why the capsule heuristic was silently carrying every slide. A known, written-down,
unexplained gap is a debt; when a later symptom fits it exactly, check it before theorising.

### Stage 6 — Using afterimages to fake a different effect, and why it failed

Worth recording because it is the same reasoning error in the opposite direction. The bubble-jump
flash was approximated by *spawning afterimages* on the ghost, under two guessed trigger windows.

Both were wrong twice over. The windows were guesses at a duration that was never ours to know, and
the substitute did not even look right — spawned afterimages read as a **constant glow** where the
real effect **flashes**, so no window constant could ever have fixed it. The real answer was the
game's own `StartBubbleJumpFlash` driven by its own `hasBubbleChargedJump` flag, which matched the
player to within 0.01s.

**The lesson: reaching for a mechanism you already have working is not the same as reaching for the
right one.** Both trigger windows were deleted rather than kept as a fallback, on the grounds that a
wrong-looking effect is not a useful fallback for a correct one.

### Stage 7 — The colour, and a correct finding filed under the wrong conclusion

Trail colour syncs through the pawn's `afterimageColor`, which also covers third-party mods that let
a player pick a custom colour. That worked.

But the ghost's ultra hop stayed yellow. So `afterimageColor` was edge-logged across a capture
containing a real ultra — logging only on change, deliberately not on a periodic sample, because an
ultra's window is short (~690ms) and a sampler could miss it entirely.

Result: one read of `(1.000, 0.888, 0.260)` — yellow — **which then never changed again**, through
the ultra and everything after.

A follow-up ruled out every ultra-state candidate too: `fullUltraModifier` and `cappedUltraModifier`
never change at all; `ultraCap` toggles identically on every jump including normal backflips;
`animJumpType` runs the same `13 → 11 → 0` sequence on all ~8 backflips as on the ultra.

**The investigation was then parked as unsolvable**, with a note not to resume by guessing more
property names.

> **This is the most instructive moment in the whole saga.** The finding was correct and well
> evidenced: the blue is not on `afterimageColor`. The conclusion drawn was "the blue is not
> findable". The correct conclusion was **"the blue is not on the pawn"** — a statement about
> *which object*, not about difficulty. Everything after this point followed from finally asking
> that question.

### Stage 8 — Reopening it by asking what the thing IS

Two probes, neither of which searched for a property name.

**A catalog of every particle system the game has loaded** — all 58 Niagara systems, played onto a
ghost one at a time on a ~3s cadence to see what each looked like. **None of them was an afterimage.**

That reads like a failed probe. It was the decisive result: it eliminated the entire class of object
every previous colour attempt had assumed. A colour property on a particle system was never going to
be the answer.

**A world diff around a deliberate call**: snapshot every object, call `Spawn After Image` on a
ghost on purpose, snapshot again, read what appeared. An afterimage is a **`BP_AfterImage_C` actor
carrying a `PoseableMeshComponent`** — a posed mesh snapshot of the character.

And `BP_AfterImage_C` carries **its own `Color`**. Measured live: ordinary images
`(1.000, 0.888, 0.260)`, ultra images `(0.000, 0.787, 1.000)`. The ultra path colours each image
directly and bypasses the pawn field entirely — which is exactly why the pawn field never changed,
and why that earlier finding had been right about the fact and wrong about what it implied.

### Stage 9 — The probe that broke the thing it was measuring

Reading the colour needs to find the afterimages, so a scan was added: enumerate every
`BP_AfterImage_C`, work out which belong to the local player, read each one's `Color`. It ran every
3 ticks (~50Hz), and for each object it built a full object name, converted it to UTF-8, and did a
substring search — plus several name-keyed property lookups. Against a pool that grows past 80
objects. **All on the game thread.**

A second probe, `AFTERIMAGE_DISCOVERY`, called the game's own spawn function on the ghost every ~3
seconds — a probe that *creates* the same kind of object it is measuring.

The trail went intermittently sparse and sometimes vanished. Then came the worst part:

**Four rounds of measurement all reported exact parity.** Spawn count 32 vs 32, later 40 vs 40.
Burst spacing 18-21 ticks each side. Position in X and Z identical modulo the loopback offset.
Opacity and fade curve — the ghost's marginally *higher*. Colour matching.

Every number was true and every number was irrelevant. **Every image that survived was correct, and
only the destroyed ones were missing. A counter cannot see an object that never existed.** The game
spawns a burst as a countdown across ticks, so stalling the game thread truncates bursts already in
flight — and both sides were counted by the same blind detector, so anything it missed, it missed
symmetrically and still reported parity.

#### The two wrong turns inside this stage

**Pooling, discovered correctly and then over-applied.** A lifetime probe designed to log an image's
lifespan when it disappeared produced **zero samples across 122 tracked afterimages**. Nothing ever
died — the objects are pooled and re-used. Sound finding. The fix built on it — count re-use as a
spawn — was then reverted, because a world census showed the ghost had produced roughly *twice* as
many afterimages as the real player (27 vs 54) while still looking thinner.

> "Pooling is real" and "pooling explains this bug" are separate claims needing separate evidence.

**The A/B that proved something false.** Setting `AFTERIMAGE_TRIGGER_OBSERVED = false` changed
nothing, so the trigger revamp was declared innocent. It was not: the flag gated only the *counter
increment inside* the scan, while the expensive enumeration ran regardless. **A flag flip is not a
revert.** That conclusion sent the investigation further astray than any other single step.

#### What actually found it

The user asked to check out the session-start commit and compare. `8d10f67` good → `46c4d2c` good →
`760b148` intermittent → `861e6cd` broken. **Three builds**, after hours of measurement had produced
only false parity.

Fix: heavy tracing off, scan cadence 3 → 15 ticks, and structurally, the scan gated by the flag that
owns it so that flag is a real off-switch. Trail restored and confirmed. **The blue went off with
it**, since the code that read it rode on the same scan.

### Stage 10 — Re-enabling the colour, five rounds

Each round fixed a real bug that only exposed the next. Every diagnosis came from a log line; the
two rounds that came from reasoning about the symptom were both wrong.

1. **Made the scan cheap and event-scoped.** Ownership became a single pointer compare (an
   afterimage's `cachedMesh` belongs to the pawn) instead of building a name string per object per
   scan, and it ran once per burst instead of on a cadence. Result: **no blue at all.**

2. **Cause: the colour was thrown away on the common path.** The log's `off=` column read 5, 10, 4,
   10, 4 — every burst cut short by the next trigger, long before its observation window closed.
   Two emit sites had been written and only one latched the colour; the truncating path, assumed
   rare, was nearly every burst. Result after fixing: **blue appeared, one slide late.**

3. **Cause: the ultra fires no trigger at all.** The log said so plainly, and had been saying so for
   several rounds: every burst logged `n=5`, the *hardcoded fallback*, never a real
   `afterImagesToSpawn` value. So the game's own authoritative trigger never fired for slides
   either — everything came from the Stage 2 capsule heuristic. The blue images were spawned unseen
   during the ultra and only discovered by the next slide's first scan, `new=4` at `off=4` — four
   images at once on a first scan, which is a backlog being found, not a burst spawning. Fixed with
   an idle scan that fires on images the game really spawned. Result: **blue on the ultra, but two
   images where the game draws one, plus the following slide also blue.**

4. **The following slide's blue was inherited, not detected** — that capture contains no divergence
   line for it at all. A burst that observed nothing kept the previously latched colour, making the
   latch mean "the last colour ever seen" rather than "this burst's colour". Fixed by falling back
   to the baseline.

5. **The double image was one image counted twice.** Counts could not distinguish "the game spawned
   two" from "one counted twice", and both readings were live. Logging the actor **pointer** settled
   it instantly: the identical pointer, twice, ~60 ticks (~400ms, one fade lifetime) apart, in all
   eight ultras. The pool *moves* an actor when it reclaims it, and "did it teleport?" cannot tell
   that from a fresh placement. Fixed with a fact a retirement cannot fake: an afterimage is a
   snapshot of the player, so it is **born where the player is**.

Result: **the blue, correct on screen.**

### Stage 11 — The last guess falls

The user then noticed the ghost trailing where the real player shows nothing at all: a slide into a
backflip with bad timing is meant to be neutral, and the ghost trailed yellow anyway.

The cause had been sitting in every capture since round 3 — `n=5` everywhere meant the capsule
heuristic from Stage 2 was driving *every* slide trail. It detects "a slide is happening", not "the
game decided to trail". Those agree until a move is performed badly.

The observation path was by then cheap, guarded and proven, so it became the trigger itself. The
reconstructed triggers were switched off rather than kept alongside, since both firing would
double-count.

**This also closed a separate complaint, open since 2026-08-15**: the ghost had consistently drawn 1-2 more
afterimages than the player. It was never over-*drawing* — it was over-*firing*, on slides the game
itself did not trail on. Density matched immediately, confirmed from a top-down camera.

> **A fix that was nearly taken instead**: subtracting one from the spawn count, proposed on the
> strength of that same 1-2 gap. It would have looked right on the day and permanently hidden both
> real causes. The tell that it was wrong: **the error was constant.** A miscount produces a fixed
> offset; a genuine difference varies with what happened.

### The false finishes — this was "done" at least seven times

The single most characteristic thing about this investigation, and the hardest to convey from the
tidy list above: **it kept being finished.** Not "nearly finished" — genuinely confirmed working, on
screen, and then reopened. Each time the confirmation was real; each time it covered less than it
appeared to.

| Believed finished | What reopened it |
| --- | --- |
| Stage 2 — capsule trigger shipped, trail worked | Stage 11: it fires when the game itself decides *not* to trail |
| Stage 3/4 — burst size and re-fire tuned, trail looked right | The ghost quietly ran 1-2 images ahead from 2026-08-15 |
| Stage 5 — mirroring measured **exact**, 6 detected / 6 applied | Exact for the path it watched; a whole other spawn path existed |
| Stage 7 — colour synced, modded colours included | The ultra's blue does not come from that property; parked as unsolvable |
| Stage 8 — blue found, written to a ghost, **seen blue on screen** | Switched straight back off; it rode on the probe that broke the trail |
| Stage 9 — regression fixed, dense trail confirmed live | Correct, but the blue was still disabled |
| Stage 10 — five separate rounds, each looking like the finish | "No blue" → "a slide late" → "bleeds into the next slide" → "two instead of one" |
| Stage 10 end — user: *"looks perfect now"* | Stage 11: the ghost still trailed where the player shows nothing |

**What made each finish false was never a bad test — it was a narrow one.** Every confirmation
tested the case that had just been fixed. The trail was checked by sliding; the blue was checked by
doing a good ultra. Nobody checked what happens when a move is performed **badly**, which is where
the game's own rule and our reconstruction of it diverge — and that is precisely the bug that
survived to the very end.

Two habits follow, and they are the practical payoff of this whole file:

- **Write down the case matrix before declaring an effect done**, and include the ugly rows: the
  move done correctly, the move done *badly or mistimed*, the move interrupted, the effect twice in
  quick succession, the effect adjacent to a similar one, and a long session (pools grow — the pool
  here reached 324 objects).
- **Re-test the cases you already confirmed, on every build.** Three regressions here were caught
  because the slide check was re-run first each time; the one that was not caught early cost a
  bisection.

A useful reframe for effects specifically: **a mirrored effect is not "does it appear?" but "does it
appear exactly when the real one does, and stay absent exactly when the real one is absent?"** Only
ever testing the first half is what made this take eleven stages. Absence is half the specification
and it is the half nobody watches.

### The shape of the answer

Every fix that finally worked removed a rule this project had invented about a game it does not own:

| Guess | Replaced by |
| --- | --- |
| The colour is on the pawn | Read it off the afterimage actor itself |
| A slide is happening, so the game must be trailing | Trail when the game really spawned images |
| It moved, so it must be new | It was born where the player is, so it is really new |

**You are not entitled to a model of the game's internals. You are always entitled to watch what it
did.**

---

## Part 2 — The procedure, extracted

### 0. Get a baseline you can regress against, and decide how you will judge it

- **Decide the viewing angle before you need it.** Ghost-vs-player trail density is only judgeable
  from a **top-down camera**; from behind the player the two blend, especially sliding left or
  right, and a real difference can be looked straight at and not seen. A check from the wrong angle
  is not weak evidence, it is none. This is why Stage 9's regression was visible to a person while
  every instrument reported parity.
- **Re-run the baseline check first on every build**, before looking at the feature.

### 1. Find out what the thing IS, not what it is called

Guessing from names failed every time here. `AnimGraphNode_Trail` is stock bone physics for dangling
cloth. Cling Gem has no "glide" string anywhere. `spawnTrackingParticles?` is set once at spawn.

Two probes that work, answering different questions:

- **Catalog** — enumerate everything of a kind the game has loaded and play them onto a ghost one at
  a time. Tells you what each thing *looks* like.
- **World diff around a deliberate call** — snapshot, trigger on purpose, snapshot, read what
  appeared. Tells you what an effect *is*.

**A negative result is often the finding.** "None of the 58 particle systems is an afterimage" and
"none of 122 tracked images ever disappeared" were both decisive, and both look like failed probes.

### 2. Ask which OBJECT the state lives on before hunting for more property names

When a plausible property provably never changes, that is evidence about **the object**, not about
the difficulty. Ask what else participates in the effect. Stage 7 lost the most time in this saga by
treating a correct negative as a dead end.

### 3. Instrument before fixing; design each field to be falsifiable

| Field | Question it answers |
| --- | --- |
| `off=` | ticks since trigger — *is the window even open when the thing happens?* |
| `new=` / `newTotal=` | how much of a burst has appeared so far — separates "sampled too early" from "not there" |
| `ours=` | did the ownership test match anything — *distinguishes a silent zero from absence* |
| `img=` | object identity — *separates "two spawned" from "one counted twice"* |
| `special=` | did the game diverge from its own baseline — the event actually being mirrored |
| `rejFar=` / `farNew=` | how many a threshold rejected, and how close the call was — *makes a tuned constant checkable rather than trusted* |

**Log the thing that would prove you wrong.** `ours=0` while visibly trailing means the ownership
test is broken — print it precisely because it is "obviously" fine.

### 4. When a count is suspect, log IDENTITY

Counts cannot separate "produced two" from "counted twice"; those need opposite fixes. Pointers can,
in one line.

This matters most for **pooled objects** — particles, projectiles, decals, damage numbers,
afterimages. Pooling breaks naive detectors at *both* ends, and this project hit both in the same
detector:

- Re-use makes an object look **old** → a "seen this before?" detector **undercounts**.
- Retirement **moves** an object → a "did it move?" detector **overcounts**.

Before building any spawn detector on identity, check whether the objects ever actually disappear.

### 5. Every probe and every fix needs a real off-switch

A flag must gate the **work**, not merely the decision the work feeds. If you cannot point at the
work it disables, revert the commit instead. **A flag flip is not a revert.**

### 6. One variable per run; never guess twice at the same symptom

Live testing costs a full build → deploy → play → watch cycle, so bundling changes is tempting and
means neither gets measured. **Two guessed fixes failing on the same symptom is a signal** — stop and
instrument. Adding log lines alongside one behavioural change is fine; instrumentation is not a
variable for this purpose.

### 7. Budget logging per question, never globally

A shared budget is spent by whatever happens most often, which is never the rare thing you are
hunting. A five-line session budget was consumed by routine sliding in the first seconds, so the
ultra it existed to capture produced nothing. Give the rare, decisive event its own budget.

### 8. Beware the fix that would have worked on the day

A fix producing the right visual for the wrong reason is **worse** than one that plainly fails,
because the confirmation itself becomes misleading. Both near-misses here (subtract one; the flag-flip
A/B) would have looked correct immediately.

### 9. Test the move done BADLY, and test for absence

The bug that survived every other check was found by performing a move with deliberately bad timing.
An effect's trigger and your reconstruction of it agree on the clean case and diverge on the messy
one, so the clean case cannot distinguish them.

Before calling an effect done, run the matrix: performed correctly, performed **badly/mistimed**,
interrupted, twice in quick succession, next to a similar effect, and over a long session (pools
grow — this one reached 324 objects).

**And test absence explicitly.** "Does the effect appear?" is half the specification; "does it stay
absent exactly when the real one is absent?" is the half that goes unwatched, and it is where a
reconstructed trigger fails. See "The false finishes" in Part 1 — this effect was confirmed working
seven separate times before that question was asked.

### 10. Stop and bisect

If a regression appears and two rounds of reasoning have not found it: build the last known-good
commit, confirm it is good, halve. Mechanical, needs no theory, cannot be fooled by a partial revert.
Three builds found what hours of measurement had not.

### See also

- [pitfalls.md](pitfalls.md) — the incidents as symptom → cause → fix, especially "The diagnostics
  were the bug", both pooling entries, and the latch entry.
- [`adapters/_template/README.md`](../adapters/_template/README.md) — enumeration, mirroring a
  decision rather than a rule, and latching payloads to a counter.
- [verified.md](verified.md) — the dated, confirmed findings behind every claim here.
- [`adapters/pseudoregalia/README.md`](../adapters/pseudoregalia/README.md) — the same story as a
  short build narrative (steps 23, 26, 28, 36-41).
