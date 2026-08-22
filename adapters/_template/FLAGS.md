# `<game>` — flag register

Every adapter accumulates switches. They look alike and they are not alike, and mistaking one
class for another costs real time. This file is the index: which switch is which kind, what the
shipped value is, and which ones must not be touched alone.

**Four kinds of switch live here, not one.** Compile-time bools are the first and the easiest to
spot; the other three each got missed once. `constexpr` **numbers** decide as much behaviour as any
bool ("Tunable constants"). **Runtime** switches — environment variables, flag files, globals set
by a loader — are the only kind an interpreted adapter has at all ("Runtime switches"). And a
**derived** flag, set from other flags rather than by hand, belongs in whichever section its
sources do, marked as derived.

**Write this file once you have more than a handful of flags.** Pseudoregalia reached 56 before it
had one, and the cost was concrete: on 2026-08-17 three load-bearing pose flags were read as
leftover debug switches, because their comments still said "OFF" from a sweep that had been
reverted. The register is what you trust when a comment and a value disagree.

It is not a description of how the game works — that is `documentation.md` — and not a list of
compensations, which is `BANDAGES.md`. A flag can appear in both this file and `BANDAGES.md`; this
one says what it is, that one says what it costs.

**Keep it in step with the code.** Add a flag, add its row. Flip a flag, fix its row in the same
edit. A register that disagrees with the source is worse than no register.

## The three kinds a compile-time bool can be

| Kind | Shipped value | What it means |
|---|---|---|
| **Behaviour** | `true` | Real shipped behaviour. Turning it off changes what a player sees. |
| **Probe** | `false` | A diagnostic: tracing, dumping, or measuring. Off in every build a user runs. |
| **Dormant** | `false` | A recorded negative or a retired approach, kept as evidence and as an instant revert. |

## Behaviour — the ones that are `true`

List each with one line on what it does, and what turning it off would cost. Everything here ships:
the value in the code is the value a player gets.

| Flag | What it does |
|---|---|
| `<FLAG>` | `<what a player loses if this goes false>` |

**Group any flags that only work together, and say so loudly.** This is the row most likely to be
"tidied" by someone who wasn't there. If a set of mechanisms is only correct as a union, a reader
who tests them one at a time will measure a negative for each and conclude all of them are dead
code — every single-mechanism test can be negative while the union works, because game systems have
preconditions. That is `CLAUDE.md`'s "try the untested COMBINATION" rule, and it was learned by
paying for it. Record which combination was the one that worked, and the date.

## Probes — off, and they must stay off

Name the convention you use (`_TRACE`, `_PROBE`, `_DIFF`, `_DUMP`, …) so a reader can classify a new
flag on sight without opening it.

**A diagnostic can break the thing it measures, and then every reading agrees with itself.** This is
not hypothetical: it produced the worst regression in this project's history (Pseudoregalia,
2026-08-16). The expensive shape is per-tick enumeration on the game thread, especially with a name
lookup or string conversion per object — compare by pointer instead.

Rules that follow from that:

- Audit a probe's cost before trusting its output.
- Re-run with the probe off before believing a result.
- Never leave a probe that *spawns* an effect enabled while judging that effect.
- Numbers gathered while a heavy probe was live are retroactively suspect.
- "It measured correct" is not evidence, the same way "it ran without errors" isn't. If the user
  reports a difference your metrics deny, **the metrics are the suspect.**

## Dormant — recorded negatives and retired approaches

A negative result is worth keeping. It stops the next person arriving with an idea that was already
tried, and it makes a retired approach an instant revert rather than an archaeology exercise.

| Flag | Why it is kept |
|---|---|
| `<FLAG>` | `<what it was, when it was retired, and what replaced it>` |

A useful pattern worth copying: when something has two plausible polarities nobody has established
(which input index is press vs release, which way a sync inverts), leave both behind a flag and log
which one fired. **A swap then costs a flag, not a build** — which matters a lot when every test
cycle costs the user a real game launch.


## Tunable constants — the `constexpr`/`local` NUMBERS

**A bool register is only half the switches, and this half is the one that gets missed.** Every
shipped adapter also carries constants that decide behaviour: a hold window, a spawn guard, a
render offset, a distance threshold, a snap limit. They do not look like switches — they look like
arithmetic — so nobody classifies them, and then one gets "simplified" by a reader who assumed it
was arbitrary. Pseudoregalia has ~40 of these against its 58 bools; the register was bools-only
until 2026-08-18 and that omission is why this section exists.

**Register a number here the moment its value carries an argument.** Not every integer needs a
row — a buffer size does not. The test is whether someone changing it would be changing
*behaviour a player sees* or *a claim about the game*.

**Sort each one by provenance, because that is what says whether it may be touched:**

| Provenance | What it means | May it be changed? |
|---|---|---|
| **Measured** | derived from a capture of the game, with the capture cited at the constant | only by re-measuring |
| **Sized** | chosen against a known rate or bound, with margin, and the reasoning written down | yes, if the bound it was sized against changed |
| **Tuned by eye** | adjusted until it looked right | yes — and it belongs in `BANDAGES.md`, not only here |

That last row is the join between this file and `BANDAGES.md`: *"where did this number come
from — measuring the mechanism, or trying values until it looked right?"* is the same question
both files ask. A number that cannot answer it is a bandage that has not been logged yet.

**Two traps worth naming before you meet them:**

- **An enum value is not a tunable.** `CROUCH_MOVE_STATE = 2` is a *fact about the game*; changing
  it asserts a different fact. Group these separately and say so, or someone will "tune" one.
- **Say where it lives.** A constant declared inside a function is invisible to a grep at the top
  of the file, and citing it by bare name elsewhere reads as though it were file-scope. Note the
  enclosing function in its row.

**Probe constants go in their own table.** A cadence or a threshold that only runs while a `false`
flag is on is dead code in every shipped build, and mixing it in with live behaviour makes the
live list look far more dangerous than it is. Keep them, though — turning a probe back on should
not also mean re-deriving how often it ought to run. One of them is usually worth a warning of its
own: a probe's *own* cadence can invert its conclusion, which has happened here.

## Runtime switches — environment variables and flag files

**Not every adapter has a compile step.** A Lua adapter loaded by an emulator has no `constexpr`
at all, so its switches are environment variables, files on disk, and globals set before the
script is `dofile()`'d. **They are switches in exactly the sense this file means**, and for two
sessions the Lua adapters had no register at all because this file only contemplated compile-time
bools — which is precisely the drift `README.md`'s gold-standard rule is about.

**Register them the same way, with two extra columns' worth of information:**

- **How it is set** — `MESHGHOST_FOO=1` in the environment, a file beside the script, a global
  assigned by a loader script. An emulator usually has to be restarted for an environment variable
  to be seen, which is often *why* a file-based alternative exists beside it.
- **What its default is when unset**, stated explicitly. This is the value every real user gets,
  and it is the one thing a reader cannot recover by reading the flag's name.

**A runtime switch is more dangerous than a compile-time one, in two specific ways:**

1. **It can be on without anyone choosing it.** A stray file in a folder, or a variable exported
   in a shell and forgotten, silently changes behaviour in a build that looks identical. Make anything
   that relaxes a safety rule **announce itself in the log on every startup**, so a session run
   that way can be told apart afterwards; and make ending the experiment obvious (deleting the
   file is a good shape).
2. **It can ship.** A compile-time probe is compiled out; a flag file just needs someone to
   forget. If a switch must never reach a player, the packaging step should **fail the build** on
   finding it, not merely avoid copying it.

**And the rule that outranks both:** a runtime switch may lower the bar to *unconfirmed*, never to
*invented*. Substituting a named, logged candidate for a measured value is a deliberate
experiment. Falling back to a plausible value because a real one is missing is the thing the
verification standard exists to forbid — a missing value should refuse to run.

## When a comment and a value disagree

Believe the value, then find out why the comment drifted before changing either. These comments
accumulate in layers — an "OFF, job done" line from one session can sit directly above a "BACK ON,
and switching it off is what broke it" line from the next, with only the constant telling you which
one won.

`CLAUDE.md` states the harder version: **a flag flip is not a revert.** A compile-time bool only
reverts behaviour if it gates the *work*, not merely the decision the work feeds — otherwise an A/B
"proves" a change innocent while its cost is still running. Verify the flag disables the cost, or
revert the commit. When a regression appears, bisect real commits early: it is mechanical, needs no
theory, and can't be fooled by a partial revert.
