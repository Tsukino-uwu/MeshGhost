---
name: write-a-probe
description: Read before writing a probe for a MeshGhost adapter — a script that asks a running game a question. Sequences the probe method by what you are trying to find out, and front-loads the three lessons that cost this repo the most. Use when instrumenting a running game, hunting an unknown memory address or field, diagnosing something visual that the numbers say is fine, or measuring an adapter's cost.
---

# Writing a probe

A probe is a question asked of a running game, and **most of them fail as questions rather than as
code.** The method lives in `adapters/_template/probes.md`; this is the order to reach for it in.
Read the three below first — they are not optional and they are why this skill exists.

## The three that cost the most

1. **A probe can break the thing it measures**, and then every reading agrees with itself. Keep
   probes off by default, audit their cost before trusting their output, and re-run with them off
   before believing a result. Never leave a probe that *spawns* an effect enabled while judging
   that effect.
2. **A probe too expensive to run does not report being too expensive** — it reports nothing,
   which reads exactly like "the game did nothing."
3. **A filter applied before you look is a guess about the answer**, and a wrong guess still
   produces a complete-looking result. Dump everything; filter afterwards.

"It measured correct" is not evidence, the same way "it ran without errors" is not. And **a clean
instrument plus a symptom the user still sees means WIDEN the subsystem, never deepen the
measurement.**

## Sections to read, by what you are trying to do

| Goal | Section in `probes.md` |
|---|---|
| find a value you cannot name | "Drive the input one way, then reverse it"; "Reverse the STATE too, not just the input" |
| a general search that is not going anywhere | "How to find things — the general form"; "Ways of finding things that worked" |
| reach a state to measure it | "Or play to it"; "Edit the world instead of travelling to it" |
| confirm what a field means | "Check what a thing IS and DOES — never assume from its name" |
| separate your change from the game's own startup | "Delay your own change" |
| the numbers all agree and the screen disagrees | "Measure what is DRAWN, not the fields that feed it" |
| you built something the game also builds | "Diff what you BUILT against what the game BUILT" |
| a scripted interaction that moves the player | "A scripted interaction must return the game to a known state — and prove it did" |
| before writing any script at all | "Look first, then write the script — not the other way round" |
| judging cost | "The cost warning"; "A probe's read budget is real" |

## Rules the probe itself must satisfy

- **A probe asks for endurance, not timing.** Fixed phases with a countdown, never a window the
  user has to hit. This is a standing user preference, not a style note.
- **Log a window, not an event** — the frames either side are what make a reading interpretable.
- **Never log the value you just wrote as proof it worked.** Read it back independently: a real
  getter, not the local you wrote.
- **A probe that returns a boolean cannot be sanity-checked.** Return the values it decided from.
- **Make a probe verify its own assumption**, and have it say what it could not see — an
  instrument reports its own coverage, not just its findings.
- **Buffer the log and flush on a timer.** This is about anything running every frame, shipped
  code first — not just probes. On BizHawk the numbers are in `adapters/emulator/CLAUDE.md`.

## Where the results go

- Your measurements go to **`agent_docs/unverified.md`**, as measurements.
- **Nothing adapter/game-side on a vanilla game becomes "verified" until the USER confirms it on
  screen.** No probe log, console read, or screenshot of yours substitutes. A patched ROM
  (Archipelago etc.) is yours to confirm visually — say so.
- A new way to MEASURE something goes back into `probes.md`. A symptom → cause → fix goes to
  `agent_docs/pitfalls.md`.

## Two standing traps

- **A probe global outlives the probe**, and then looks exactly like a real bug.
- **An input-driving probe is not a passive instrument** — left loaded, it becomes a suspect in
  every later report. Unload it before judging anything.
