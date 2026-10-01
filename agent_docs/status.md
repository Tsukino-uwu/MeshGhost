# Current status

**Active phases: 6 (TEVI), 9 (Crystal) and 13 (autoplay), with 7 (Pseudoregalia), 10 (the Go side), 11 (replays) and 12 (delivery) live.** This file is an index of what
is open right now: **two lines per item, maximum** ([claude-md-cap.md](claude-md-cap.md)), **each carrying the date it was last re-checked, and an item dated
more than 2 days before this file's last commit fails preflight** — at this project's pace, 2026-08-31 is
already not current on 2026-09-02 (user's call). At the start of a session re-date what is still current and move the rest to `plans.md`,
`ideas.md`, the adapter's `UNVERIFIED.md` or `risks.md`; a quiet repo does not go red, because age is
measured against this file's own last commit. It lists tasks: what is running is not one (`running-the-rig.md`, the user's call 2026-09-16). Records are never listed here — `verified.md`, the phase
files and each `VERIFIED.md` hold them. Why two lines and a date, not a total cap: [claude-md-cap.md](claude-md-cap.md). **An item may say `hold to <date>`** when the user has scheduled it past the two days: preflight ages it by its newest date, so it stays until then, and only the user's call sets that date. **An item marked `PINNED`** never ages out: a priority the user has said must
not expire (2026-09-27), kept at the top until the user unpins it.

## Open now

- 2026-10-01 — **PINNED, priority 1 (the user): the four shipped DLLs rebuilt with no build path or username, and deployed; open until a TEVI and a Pseudoregalia ghost are seen on screen.** `phases/phase12.md`.
- 2026-10-01 — **Gates and docs from bug_fables_ap, Part A (A1–A7): A1, A2 and A3 done bar the on-screen check above; A4 (code map, build-step Status lines) next.** `phases/phase12.md`.
- 2026-09-30 (re-checked) — **Sort each adapter's older code-level entries out of `UNVERIFIED.md`/`VERIFIED.md` into `MEASURED.md`**, and give every `UNVERIFIED.md` (and `_template`) a full index. Another chat.
- 2026-09-30 (re-checked) — **Autoplay, Emerald: the League beaten** (the 1:1 route run); the state planner's step 2 begun, badge rules measured; next the capability reader. `phases/autoplay/emerald.md`.
- 2026-09-30 (re-checked) — **Autoplay, Crystal: paused** (the user); `goto`, the PACK, POKéMON menu, badges, bike, surf and `effective` scoring done on V1.0; next the whiteout. `phases/autoplay/crystal.md`.
- 2026-09-30 (re-checked) — **Autoplay, TEVI: into the story, at the Travoll Mines**; the fight distilled (`hug` 5 build, 7 of 10 at 103.2 s). `phases/autoplay/tevi.md`.
- 2026-09-30 (re-checked) — **Autoplay, Pseudoregalia: opened** — UE4SS driver, File 8 a new game, walking and camera by injected input; next menu keys, snapshots. `phases/autoplay/pseudoregalia.md`.
- 2026-09-30 (re-checked) — **Vision: a pixel-side instrument, Phase 0 next** — window capture + OpenCV, a PAINTED ghost vs the PLAYER, beyond any OAM read or screenshot. `plans/vision-plan.md` (untracked).
- 2026-09-30 (re-checked) — **Prediction: A3 LANDED (ADR 0069, ships off), SCREEN VERDICT OPEN; A2.0 MEASURED** (transit p99 310–320ms; the dry tail is the 1 s blackouts); A2 undecided. `prediction-planning.md`.
- 2026-09-30 (re-checked) — **Chaser contact: `hurt`, `kill`, the respawn and seated/talking holds WORK (user-confirmed); open: Part A's attack leaks, the world-leak crash on reload.** `chaser-planning.md`.
- 2026-09-30 (re-checked) — **Every adapter README's "roughly in order" build story: a stale sweep** -- it drifts despite the checks (the user); Pseudoregalia likely skips steps 70-71. Fact-check against the code.
- 2026-09-30 (re-checked) — **netsim: ADR 0046's 450 ms has never been judged on the correlated-loss model** (`-loss-burst`, opt-in since 2026-09-11). `phases/phase10.md`.

**Trimmed 2026-09-15**: records of finished work were dropped and items already queued in an
adapter's `UNVERIFIED.md` folded into one line per game; every pointer was checked against its
file first, and the `adapters/CLAUDE.md` item was fixed in place rather than carried.

## Where the rest lives

What the user has not confirmed, per game: each adapter's `UNVERIFIED.md`, whose "This run" block is
what to watch next. Known gaps and assumptions: `risks.md`. Unscheduled ideas: `ideas.md`. The roadmap:
`plans.md`. The running log per phase: `phases/README.md`. Confirmed facts: `verified.md` and each
`VERIFIED.md`. Lessons: `checklists/`, filed via `pitfalls.md`.
