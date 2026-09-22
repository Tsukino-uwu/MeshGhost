# Current status

**Active phases: 6 (TEVI), 9 (Crystal) and 13 (autoplay), with 7 (Pseudoregalia), 10 (the Go side), 11 (replays) and 12 (delivery) live.** This file is an index of what
is open right now: **two lines per item, maximum** ([claude-md-cap.md](claude-md-cap.md)), **each carrying the date it was last re-checked, and an item dated
more than 2 days before this file's last commit fails preflight** — at this project's pace, 2026-08-31 is
already not current on 2026-09-02 (user's call). At the start of a session re-date what is still current and move the rest to `plans.md`,
`ideas.md`, the adapter's `UNVERIFIED.md` or `risks.md`; a quiet repo does not go red, because age is
measured against this file's own last commit. It lists tasks: what is running is not one (`running-the-rig.md`, the user's call 2026-09-16). Records are never listed here — `verified.md`, the phase
files and each `VERIFIED.md` hold them. Why two lines and a date, not a total cap: [claude-md-cap.md](claude-md-cap.md). **An item may say `hold to <date>`** when the user has scheduled it past the two days: preflight ages it by its newest date, so it stays until then, and only the user's call sets that date.

## Open now

- 2026-09-23 — **Sort each adapter's older code-level entries out of `UNVERIFIED.md`/`VERIFIED.md` into `MEASURED.md`**, and give every `UNVERIFIED.md` (and `_template`) a full index. Another chat.
- 2026-09-23 — **Autoplay, Emerald: Phase 3 accepted** (the HEAT BADGE); `run_wild`'s `stuck` and driver reconnect fixed 2026-09-23; open: the next goal past the HEAT BADGE. `phase13.md`.
- 2026-09-23 — **Autoplay, Crystal: paused** (the user), with `goto`, the PACK, the POKéMON menu, badges, bike, surf and scoring behind `effective` done on V1.0; next the whiteout. `phases/autoplay/crystal.md`.
- 2026-09-23 — **Autoplay, TEVI: Ribauld beaten on Infernal BBQ, once hitless (115.4 s)**; open: the bomb ring in the air, orbs against hugging, normal enemies hitless, `exec`. `phases/autoplay/tevi.md`.
- 2026-09-23 — **Vision: a pixel-side instrument, Phase 0 next** — window capture + OpenCV, a PAINTED ghost vs the PLAYER, the pairing no OAM read or screenshot can answer. `plans/vision-plan.md` (untracked).
- 2026-09-23 — **Prediction: A3 LANDED (ADR 0069, ships off), SCREEN VERDICT OPEN; A2.0 MEASURED** (worst-case transit p99 310–320ms; the dry tail is the 1 s blackouts); A2 undecided. `prediction-planning.md`.
- 2026-09-23 — **Chaser contact: Part A's leak mechanism FOUND (no fix built); Part B's damage facts MEASURED but the artificial trigger UNRESOLVED, four dead ends; Part E BUILT but inert.** `phases/phase7.md`
- 2026-09-18, hold to 2026-09-25 — **Strip the build paths out of the four shipped DLLs** (one holds the username): a flag each for three, a full rebuild and a user-judged reload for `UE4SS.dll`. `risks.md`.
- 2026-09-23 — **netsim: ADR 0046's 450 ms has never been judged on the correlated-loss model** (`-loss-burst`, opt-in since 2026-09-11). `phases/phase10.md`.

**Trimmed 2026-09-15**: records of finished work were dropped and items already queued in an
adapter's `UNVERIFIED.md` folded into one line per game; every pointer was checked against its
file first, and the `adapters/CLAUDE.md` item was fixed in place rather than carried.

## Where the rest lives

What the user has not confirmed, per game: each adapter's `UNVERIFIED.md`, whose "This run" block is
what to watch next. Known gaps and assumptions: `risks.md`. Unscheduled ideas: `ideas.md`. The roadmap:
`plans.md`. The running log per phase: `phases/README.md`. Confirmed facts: `verified.md` and each
`VERIFIED.md`. Lessons: `checklists/`, filed via `pitfalls.md`.
