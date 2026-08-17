# `<game>` — compile-time flag register

Every adapter accumulates compile-time switches. They look alike and they are not alike, and
mistaking one class for another costs real time. This file is the index: which flag is which kind,
what the shipped value is, and which ones must not be touched alone.

**Write this file once you have more than a handful of flags.** Pseudoregalia reached 56 before it
had one, and the cost was concrete: on 2026-08-17 three load-bearing pose flags were read as
leftover debug switches, because their comments still said "OFF" from a sweep that had been
reverted. The register is what you trust when a comment and a value disagree.

It is not a description of how the game works — that is `documentation.md` — and not a list of
compensations, which is `BANDAGES.md`. A flag can appear in both this file and `BANDAGES.md`; this
one says what it is, that one says what it costs.

**Keep it in step with the code.** Add a flag, add its row. Flip a flag, fix its row in the same
edit. A register that disagrees with the source is worse than no register.

## The three kinds

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
