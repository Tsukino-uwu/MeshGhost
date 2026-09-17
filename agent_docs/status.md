# Current status

**Active phases: 6 (TEVI) and 9 (Crystal), with 7 (Pseudoregalia), 10 (the Go side) and 11 (replays) live.** This file is an index of what
is open right now: **two lines per item, maximum** ([claude-md-cap.md](claude-md-cap.md)), **each carrying the date it was last re-checked, and an item dated
more than 2 days before this file's last commit fails preflight** — at this project's pace, 2026-08-31 is
already not current on 2026-09-02 (user's call). At the start of a session re-date what is still current and move the rest to `plans.md`,
`ideas.md`, the adapter's `UNVERIFIED.md` or `risks.md`; a quiet repo does not go red, because age is
measured against this file's own last commit. It lists tasks: what is running is not one (`running-the-rig.md`, the user's call 2026-09-16). Records are never listed here — `verified.md`, the phase
files and each `VERIFIED.md` hold them. Why two lines and a date, not a total cap: [claude-md-cap.md](claude-md-cap.md). **An item may say `hold to <date>`** when the user has scheduled it past the two days: preflight ages it by its newest date, so it stays until then, and only the user's call sets that date.

## Open now

- 2026-09-16 — **Sort each adapter's older code-level entries out of `UNVERIFIED.md`/`VERIFIED.md` into `MEASURED.md`**, and give every `UNVERIFIED.md` (and `_template`) a full index. Another chat.
- 2026-09-17 — **Autoplay, Emerald: Phase 2's acceptance, and the story played to ROXANNE's badge** with the tools;
  open: the learn-a-move question and evolution scene unread, items in a battle, FC bytes read raw. `phases/autoplay/emerald.md`.
- 2026-09-17 — **Autoplay, Crystal**: `goto`, a scenario 3 of 3, every PACK pocket, the POKéMON menu, badges, bike and surf, a type- and stat-aware `strongest` on V1.0;
  **paused** (the user, 2026-09-17), its scoring moved behind `effective` and checked (`df7326f7`); next the whiteout. `phases/autoplay/crystal.md`.
- 2026-09-17 — **Autoplay, TEVI: layers 5 and 4 built; a dodge that learns tells beat Ribauld** (phase one hitless, 2 hits in phase two); open:
  a hitless whole fight, outlines, the hardest difficulty, `exec`. `phases/autoplay/tevi.md`.
- 2026-09-16 — **Prediction: A3 LANDED (ADR 0069, ships off), SCREEN VERDICT OPEN; A2.0 MEASURED** (worst-case transit p99 310–320ms; the dry tail is the 1 s blackouts); A2 undecided. `prediction-planning.md`.
- 2026-09-15 — **Chaser contact: the Go half LANDED (`e546d38c`, ADR 0068, ships `off`); the adapter half is NOT started.** Next: Part A of `chaser-planning.md`; `pseudoregalia/UNVERIFIED.md` has the entry.
- 2026-09-15 — **netsim: ADR 0046's 450 ms has never been judged on the correlated-loss model** (`-loss-burst`, opt-in since 2026-09-11). `phases/phase10.md`.

**Trimmed 2026-09-15**: records of finished work were dropped and items already queued in an
adapter's `UNVERIFIED.md` folded into one line per game; every pointer was checked against its
file first, and the `adapters/CLAUDE.md` item was fixed in place rather than carried.

## Where the rest lives

What the user has not confirmed, per game: each adapter's `UNVERIFIED.md`, whose "This run" block is
what to watch next. Known gaps and assumptions: `risks.md`. Unscheduled ideas: `ideas.md`. The roadmap:
`plans.md`. The running log per phase: `phases/README.md`. Confirmed facts: `verified.md` and each
`VERIFIED.md`. Lessons: `checklists/`, filed via `pitfalls.md`.
