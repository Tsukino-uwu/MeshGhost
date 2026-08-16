# Bandages — <game>

Copy this file into your adapter folder, next to its `README.md`, and log every shipped
compensation here as you take it.

**What belongs here:** a fix that *restores, forces, compensates for, or remembers* a value rather
than preventing whatever changed it. The rule, the mechanical tell (does it **prevent** the wrong
thing, or **correct** it afterwards?), its one narrow exception and the exception's price, and —
importantly — **what the rule is not**, all live in this folder's `README.md`.

That last part matters: a number *measured from the game* and documented is a design decision with
evidence behind it, not a bandage. Log those under "Deliberate" so a future audit doesn't churn
them.

**Keep the entries short.** Symptom, the file:line, why the compensation was taken, and what would
replace it. The long evidence trail goes to `agent_docs/phases/phaseN.md`, `verified.md`, or
`pitfalls.md` — link, don't inline. Same discipline as the README's build-story steps.

---

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
it knows is wrong; a constant that appeared during a test session rather than from a capture.

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
   versus the slide floor-sinking fix.
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

**When in doubt, log it.** A false positive costs one line under "Deliberate" and saves the next
audit from re-deriving it. A missed one costs a live test round, or a user report.

---

Existing registers worth reading as examples — the first is the fullest:
`adapters/pseudoregalia/BANDAGES.md`, `adapters/tevi/BANDAGES.md`,
`adapters/pokemon/emerald/BANDAGES.md`, `agent_docs/bandages-core.md`.

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
