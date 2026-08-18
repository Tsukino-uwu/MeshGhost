# Bandages — the canonical guide

**This file is the guide, not the thing you copy.** A new adapter's register lives at
`adapters/<game>/BANDAGES.md` and carries a compact form that links back here. Start it from the
stub at the bottom of this file. Three of the four shipped registers have that exact shape;
Crystal's diverges (it heads its first section "Shipped compensations" and carries no "Borderline"),
which is the cost being warned about — a register that does not match its siblings is harder to
read across games, and harder to audit in one pass.

**Keep this template current.** Anything an adapter's own register learns — a new tell, a new rule,
a category that keeps recurring — belongs back here in the same pass. `_template/` is the gold
standard the next game starts from; see `README.md`'s standing rule at the top.

**What belongs here:** a fix that *restores, forces, compensates for, or remembers* a value rather
than preventing whatever changed it. The rule, the mechanical tell (does it **prevent** the wrong
thing, or **correct** it afterwards?), its one narrow exception and the exception's price, and —
importantly — **what the rule is not**, all live in this folder's `README.md`.

That last part matters: a number *measured from the game* and documented is a design decision with
evidence behind it, not a bandage. Log those under "Deliberate" so a future audit doesn't churn
them.

**Keep the entries short.** Symptom, where it lives, why the compensation was taken, and what would
replace it. **Cite the file and the FUNCTION, never a line number** — line citations drift silently
and then point at unrelated code, which is worse than making a reader search. Emerald's register
had drifted a hundred lines out of date by 2026-08-18, from one pass of work elsewhere in the file;
TEVI's had drifted too. Both were rewritten to name functions instead. The long evidence trail goes to `agent_docs/phases/phaseN.md`, `verified.md`, or
`pitfalls.md` — link, don't inline. Same discipline as the README's build-story steps.

---

## The standing position on bandages — user, 2026-08-16

**A bandage is a state this project is passing through, never where it stops.** The user's words,
after a slide fix was measured, understood, and then kept anyway: *"I wanted the bandaid ripped off
and fixed, not another temp/bandaid fix for it"* — and *"I don't like bandaid fixes, I prefer real
fixes."*

What that means in practice, because it changes how an investigation ends:

- **Understanding why a bandage is hard is not permission to keep it.** Ruling out three
  replacements narrows the search; it does not close it. Say what is still unknown and keep going.
- **"I have tried N things, so I will stop" is the agent's own rule, not the user's.** Do not
  announce a stopping rule as if it settles the matter. If a real fix is genuinely blocked, name
  the *specific* unknown that blocks it — not the count of attempts.
- **A visually perfect result does not make it fixed**, and must never be reported as fixed. Say
  plainly that the compensation is still in place, or the register here quietly becomes a lie.
- **The question that actually moves an investigation forward is "what is doing this?"** — the
  cause, identified. Every failed replacement in the slide case was a guess at a *lever*; nobody
  had yet found the *writer*. Find the writer.

Logging a bandage is therefore an admission with a debt attached, not a resting place. Entries here
are expected to leave.

### The bandage will usually look BETTER than the proper fix — for a while

The most seductive fact about a bandage, and the reason "it looks fine" must never be the test.

**Worked example, 2026-08-17 (Pseudoregalia's slide pose).** The compensation — offset the ghost's
render Z by the amount its capsule shrank — was **visually perfect**. Nobody could see anything
wrong with it. Replacing it with the game's own mechanism took ~15 live test cycles, and for nearly
all of them the ghost looked *worse* than the bandage had: sunk into the floor, floating above it,
flickering between the two, snapping at the end of every slide. Judged on appearance at any point
in that sequence, the honest answer was "the old way was better".

Two things follow, and they pull in the same direction:

- **"It looks right" is not evidence of a proper fix.** The bandage looked right precisely because
  it was tuned against appearance.
- **"The replacement looks worse right now" is not evidence the replacement is wrong.** A bandage is
  a local optimum; the path out of one goes downhill before it goes up. Expect the intermediate
  states to look bad, and do not let that end the attempt.

**What was actually gained**, none of it visible on the day it landed: the ghost's position stopped
being a lie that other code could inherit (it already had, once), its collision capsule started
matching its pose, and the behaviour now comes from the game — so cases nobody thought to test are
handled because the game handles them. That last one is the real return, and it is invisible by
definition.

## How to tell a bandage from a proper fix

**This is the canonical version. The per-adapter registers carry a compact form and link here.**

### The one mechanical test

**Does the fix *prevent* the wrong thing, or *correct* it afterwards?** Correcting afterwards means
the cause is still running, and something else will eventually read the state you patched. This
test needs no judgement, which is why it is the one to use.

Two supporting questions, both answerable at the keyboard:

- **"What would make this unnecessary?"** A proper fix has no answer — it *is* the thing. A bandage
  always has one, and if you can't name it, you haven't found the mechanism yet.
- **"Where did this number come from?"** From *measuring the mechanism*, or from *trying values
  until it looked right*? Only the second is a bandage. A measured, documented constant is a design
  decision — log it under "Deliberate", not "Open".

### Tells while you are writing it

**In your own reasoning** — these words are usually the moment the real mechanism stopped being
investigated: *almost*, *good enough*, *for now*, *just to be safe*, *close enough*, *seems to
work*.

**In the code** — the fix *restores*, *forces*, *remembers*, *re-applies*, *clamps back*, or
*offsets* a value. Also: a value rewritten every tick to keep it; a fallback that continues on data
it knows is wrong; a constant that appeared during a test session rather than from a capture; and
**a fix applied more broadly than the measurement that justified it** — one layer was measured
broken, five get forced, and the four nobody looked at are now a second bug wearing the first one's
clothes (`adapters/tevi/BANDAGES.md`'s open entry, and `agent_docs/pitfalls.md`'s "only reset the
field actually confirmed broken").

**In the evidence** — you can describe the *symptom* precisely but not the *mechanism*. "The ghost
sits 43 units too low" is a symptom. "The mesh hangs off the capsule at a fixed offset the crouch
logic adjusts, and a ghost never runs it" is a mechanism.

### Tells that only show up later — the ones this file exists for

You will not always know at the time. **These are how a fix reveals itself as a bandage
afterwards**, and any one of them is enough to add an entry:

1. **Its cause got fixed somewhere else, and the fix is still there.** Nothing forces a compensation
   to be removed when the thing it compensated for goes away. It just sits there, now acting on a
   world that changed. Live case: a `bHidden` flip-flop still running a phase after its cause was
   fixed.
2. **A second bug gets described as "structurally the same bug as X."** That sentence means X was
   a bandage and it has started teaching the next one to exist. Live case: the thrown-weapon prop
   versus the slide floor-sinking fix — the latter was replaced with a real fix 2026-08-17, and
   the sentence naming it is what marked it as a bandage in the first place.
3. **It outlived its purpose and became the bug.** The strongest signal, and it arrives as a user
   report. Live case: the camera fight-back worked for its one spawn case and blocked every
   legitimate camera change forever after; players saw it as the ghost stealing the camera.
4. **A constant needs re-tuning when something unrelated changes.** A measured value doesn't drift
   with your framerate, your test save, or a mod update. A tuned one does.
5. **Removing it breaks something it was never about.** Other code has started reading the state it
   patches, and has inherited the lie.
6. **You can't explain it out loud without describing a *sequence*.** "The game sets X, then we set
   it back" is a bandage on its face. A proper fix is one clause.
7. **It needs a companion fix elsewhere to stay correct.** Two places compensating for each other
   is one mechanism nobody found.
8. **It works on an object the game made, that you took rather than created.** See below — this
   one is severe enough to be worth avoiding outright rather than merely logging.

### The bandage to avoid entirely: borrowing an object instead of creating one

**Prefer the game's own creation call over repurposing something that already exists, even when
repurposing works.** This is the highest-cost bandage shape this project has found, and unlike the
others it is usually cheap to avoid *at the time* and very expensive to unwind later.

**What it looks like.** You need a thing on screen — a character, a marker, an effect. Instead of
asking the game to make one (Unreal: `world->SpawnActor(<a class the game already ships>, …)`),
you find something suitable already in the level and drive that.

**Why it is worse than it looks.** The obvious cost is cosmetic: a scenery object cannot animate
and does not look like a character. The real cost is that **the object is still the game's**:

- Destroying it deletes part of the level, permanently for that session.
- Hiding or moving it leaves a hole where it used to be, and may break whatever referenced it.
- None of the game's systems that would drive a *real* instance apply to it, so every behaviour
  you wanted has to be reimplemented by hand — which is a second bandage, and then a third.

**And the part that actually bites.** You inherit a permanent *"never do X to this"* rule, written
far from the code that will eventually want to do X. When the design later changes and the object
becomes yours, **nothing re-tests that rule** — so a constraint invented for a design that no
longer exists silently keeps a workaround alive. That is tell #1 above, in its most durable form.

**The live case.** Pseudoregalia's ghost began as a hijacked `StaticMeshActor`, which produced a
"ghosts are never destroyed" constraint recorded as a *permanent* one. The adapter later moved to
spawning a clone of the player's own pawn class — a real pawn, driven by the game's own animation
systems, and genuinely ours — but the constraint stayed, and the workaround it justified went on
shipping. It was reopened only when someone asked "did we ever actually check?", and the answer
was that the premise had been false since the design changed. `agent_docs/pitfalls.md`.

**If you must borrow**, record in this file what you may not do to the object *and why*, and put a
re-test of that constraint on the list for whenever the design around it changes.

**When in doubt, log it.** A false positive costs one line under "Deliberate" and saves the next
audit from re-deriving it. A missed one costs a live test round, or a user report.

---

Existing registers worth reading as examples — the first is the fullest:
`adapters/pseudoregalia/BANDAGES.md`, `adapters/tevi/BANDAGES.md`,
`adapters/bizhawk/pokemon/emerald/BANDAGES.md`, `adapters/bizhawk/pokemon/crystal/BANDAGES.md`,
`agent_docs/bandages-core.md`.

## Open compensations

Ranked, most likely to cause a real bug first. Each entry: what ships, why it was taken, and the
measurement that would replace it. A bandage with **no** measurement behind it is the expensive
kind — there is nothing to build the real fix on.

## Borderline — noted, not urgent

Things that match the pattern but are saved by something in practice. Worth recording so the next
audit doesn't have to re-derive why they were left.

## Deliberate — do NOT "fix" these

Constants and behaviours that look like bandages and are not, with the evidence that makes them
design decisions. This section exists to prevent churn; it is not a place to park things you
haven't measured.

## Not a compensation, but worse than most of them

A *correct* fix whose scope is dangerously narrow — right where it is applied, silently absent
everywhere else, and shaped so the next call site inherits the bug without anyone noticing. It
fails none of the tests above, which is exactly why it needs its own section. Live case:
`adapters/pseudoregalia/BANDAGES.md`'s `FRotator` float/double fix, correct at one call site and
missing at every other rotation write in the SDK.

---

## The stub to copy

Everything below the line goes into a new `adapters/<game>/BANDAGES.md`. Fill in the game name and
the cross-links; leave the three section headings in place even when empty — an empty register
says "audited, nothing found", an absent one says nothing at all. **Check the relative depth of
every cross-link**: a franchise-grouped adapter sits one level deeper than the stub assumes
(`adapters/bizhawk/pokemon/emerald/` needs `../../_template/`, not `../_template/`).

```markdown
# Bandages — <Game>

Shipped compensations in this adapter: **a fix that restores, forces, compensates for, or
remembers a value rather than preventing whatever changed it.** The rule, its one narrow
exception, and what it is *not*: `adapters/_template/README.md` ("a bandage fix is not a finished
feature").

Ranked by how likely each is to cause a real bug.

Other registers: `../<other-game>/BANDAGES.md`, `../../agent_docs/bandages-core.md`.

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

None currently recorded for this adapter.

## Borderline — noted, not urgent

None currently recorded for this adapter.

## Deliberate — do NOT "fix" these

None currently recorded for this adapter.
```
