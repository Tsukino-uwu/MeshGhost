# Current status

**Active phase: 9 — Crystal, with Emerald reopened for Fly and the boat.** This file is an index of what
is open right now: **one line per item, each carrying the date it was last re-checked, and an item dated
more than 2 days before this file's last commit fails preflight** — at this project's pace, 2026-08-31 is
already not current on 2026-09-02 (user's call). At the start of a session re-date what is still current and move the rest to `plans.md`,
`ideas.md`, the adapter's `UNVERIFIED.md` or `risks.md`; a quiet repo does not go red, because age is
measured against this file's own last commit. Records are never listed here — `verified.md`, the phase
files and each `VERIFIED.md` hold them. Why one line and a date, not a total cap: `claude-md-cap.md`.

## Open now

- 2026-09-02 **HIGH PRIORITY: all four games need ONE RUN EACH to watch the adversarial review's adapter-side changes**, Crystal first — each queue's "This run" block; ADR 0044.
- 2026-09-02 **Emerald Fly is bandaged, not finished; the boat is built and never watched; rails are unbuilt** — `emerald/BANDAGES.md` §4, `emerald/UNVERIFIED.md`.
- 2026-09-02 **Crystal's next run: hop a ledge THEN cast a rod in one session (shared vtile `$fc`); reproduce the savestate-load crash; Teleport is the last unbuilt action class** — `crystal/UNVERIFIED.md`.
- 2026-09-02 **Two shipped settings do nothing: `ghost_collision` reaches no adapter, nametags reach one of four** — the plan is `plans.md`, "Settings: defined once, honoured everywhere".
- 2026-09-02 **TEVI's shipped interp went 175 → 300ms on an untested assumption; one netsim ocean run decides it** — `tevi/UNVERIFIED.md`.
- 2026-09-02 **TEVI: a portal keeps its awake visual after the last ghost leaves (user-reported 2026-08-29)** — `tevi/UNVERIFIED.md`.
- 2026-09-02 **Pseudoregalia open faults: the sword's mid-air snap, the black flash on spawn, two unattributed crashes, `curve catmull-rom` crashing both instances** — `pseudoregalia/UNVERIFIED.md`.
- 2026-09-02 **Pseudoregalia crowds: step 2 (reflection cache, −59% tick) and the re-run ladder are UNWATCHED; `ls_rest` is the next split** — `crowd-limits.md`.
- 2026-09-02 **`DefaultSendHz` is 15 everywhere, measured on Pseudoregalia only and inherited UNWATCHED by the other three** — each adapter's `UNVERIFIED.md`.
- 2026-09-02 **Relay cross-area filtering is UNWATCHED on screen; Emerald seam crossings are the check** — ADR 0041, `emerald/UNVERIFIED.md`.
- 2026-09-02 **Go side: the `internal/e2e` port reservation TOCTOU flakes under `-race`; `encoding/json` is ~58% of relay per-state CPU; `curve catmull-rom` bends on uneven spacing** — `testing.md` Traps, `scaling.md`, `core/curvespacing_test.go`.
- 2026-09-02 **Crystal is 3 names and Emerald 1 from Lua's 200-local ceiling; modules are the fix** — `emulator/CLAUDE.md`, `ideas.md`.
- 2026-09-02 **Nothing is running** — every rig was verified down at the end of 2026-08-26; rig setups and savestate slots: `environment.md`, "Rig notes".
- 2026-09-02 **The 2026-09-02 doc pass is mid-way: parts C and D (queues, phase log, ideas split, structural moves) in progress** — `doc-history.md`.

## Where the rest lives

What the user has not confirmed, per game: each adapter's `UNVERIFIED.md`, whose "This run" block is
what to watch next. Known gaps and assumptions: `risks.md`. Unscheduled ideas: `ideas.md`. The roadmap:
`plans.md`. The running log per phase: `phases/README.md`. Confirmed facts: `verified.md` and each
`VERIFIED.md`. Lessons: `checklists/`, filed via `pitfalls.md`.
