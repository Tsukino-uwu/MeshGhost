# Current status

**Active phase: 9 — Crystal, with Emerald reopened for Fly and the boat.** This file is an index of what
is open right now: **one line per item, each carrying the date it was last re-checked, and an item dated
more than 2 days before this file's last commit fails preflight** — at this project's pace, 2026-08-31 is
already not current on 2026-09-02 (user's call). At the start of a session re-date what is still current and move the rest to `plans.md`,
`ideas.md`, the adapter's `UNVERIFIED.md` or `risks.md`; a quiet repo does not go red, because age is
measured against this file's own last commit. Records are never listed here — `verified.md`, the phase
files and each `VERIFIED.md` hold them. Why one line and a date, not a total cap: `claude-md-cap.md`.

## Open now

- 2026-09-02 **The post-review run is DONE on all four games; Crystal's and Emerald's interp verdicts were judged on the broken relay and want a re-run on the fixed one** — each queue's "This run" block; ADR 0044.
- 2026-09-02 **The review's connection limiter hid `WriteUnreliable`: every relayed quic/udp state rode the reliable stream until `341a768`; watched fixed on TEVI, Pseudoregalia and the Pokemon games unwatched since** — `verified.md`, "The limiter hid WriteUnreliable".
- 2026-09-02 **Emerald Fly is bandaged, not finished; the boat is built and never watched; rails are unbuilt** — `emerald/BANDAGES.md` §4, `emerald/UNVERIFIED.md`.
- 2026-09-02 **Emerald ships spawned -> OAM -> drawn (user's call); three tile leaks and a double-free found and fixed with a crowd, watched clean; OPEN: the attach nametag burst (core never prunes names, adapter hello times out), rung churn, drawn clipping under a text box unexercised** — `emerald/UNVERIFIED.md`.
- 2026-09-02 **Crystal's next run: hop a ledge THEN cast a rod in one session (shared vtile `$fc`); reproduce the savestate-load crash; Teleport is the last unbuilt action class** — `crystal/UNVERIFIED.md`.
- 2026-09-02 **Two shipped settings do nothing: `ghost_collision` reaches no adapter, nametags reach one of four** — the plan is `plans.md`, "Settings: defined once, honoured everywhere".
- 2026-09-02 **The port walk's dead end (a live child on a port the walk left): fixed in all four launchers and the template; reproduced and recovered on TEVI, UNWATCHED on Pseudoregalia, Emerald and Crystal** — each adapter's `UNVERIFIED.md`.
- 2026-09-02 **Pseudoregalia open faults: the sword's mid-air snap, the black flash on spawn, two unattributed crashes, `curve catmull-rom` crashing both instances** — `pseudoregalia/UNVERIFIED.md`.
- 2026-09-02 **Pseudoregalia crowds: step 2 (reflection cache, −59% tick) and the re-run ladder are UNWATCHED; `ls_rest` is the next split** — `crowd-limits.md`.
- 2026-09-02 **`DefaultSendHz` is 15 everywhere; watched on Pseudoregalia, Crystal and TEVI; the INTERP ladder on the WORST-CASE proxy (the only one that counts since 2026-09-02): 450ms CONFIRMED on TEVI, Pseudoregalia and Emerald, and on Crystal by the user's explicit exception; 450ms ships everywhere (ADR 0046) (their earlier numbers were milder links or the broken relay)** — each adapter's `UNVERIFIED.md`.
- 2026-09-02 **Relay cross-area filtering is UNWATCHED on screen; Emerald seam crossings are the check** — ADR 0041, `emerald/UNVERIFIED.md`.
- 2026-09-02 **Loss cover (ADR 0045) WATCHED on Crystal: A/B on one netsim seed, cover off is worse, no teleport at any interp; shipped 250ms stands (loopback overstates by one-way latency), 275–300ms to be re-judged with two real clients** — `crystal/UNVERIFIED.md`.
- 2026-09-02 **Go side: the `internal/e2e` port reservation TOCTOU flakes under `-race`; `encoding/json` is ~58% of relay per-state CPU; `curve catmull-rom` bends on uneven spacing** — `testing.md` Traps, `scaling.md`, `core/curvespacing_test.go`.
- 2026-09-02 **Crystal is AT Lua's 200-local ceiling (`luac` refused a 201st on 2026-09-02; new switches ride on existing tables) and Emerald is 1 from it; modules are the fix** — `emulator/CLAUDE.md`, `ideas.md`.
- 2026-09-02 **Nothing is running** — every rig was verified down at the end of 2026-09-02 (relay, proxy, cores, both emulators; the temporary root `config.json` deleted); rig setups and savestate slots: `running-the-rig.md`, "Rig notes".
- 2026-09-02 **The 2026-09-02 doc pass is DONE, parts A–D; what changed, what was measured and what was left alone: `doc-history.md`.** Ages out of here on its own.

## Where the rest lives

What the user has not confirmed, per game: each adapter's `UNVERIFIED.md`, whose "This run" block is
what to watch next. Known gaps and assumptions: `risks.md`. Unscheduled ideas: `ideas.md`. The roadmap:
`plans.md`. The running log per phase: `phases/README.md`. Confirmed facts: `verified.md` and each
`VERIFIED.md`. Lessons: `checklists/`, filed via `pitfalls.md`.
