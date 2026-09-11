# Current status

**Active phases: 6 (TEVI) and 9 (Crystal), with 7 (Pseudoregalia), 10 (the Go side) and 11 (replays) live.** This file is an index of what
is open right now: **two lines per item, maximum** ([claude-md-cap.md](claude-md-cap.md)), **each carrying the date it was last re-checked, and an item dated
more than 2 days before this file's last commit fails preflight** — at this project's pace, 2026-08-31 is
already not current on 2026-09-02 (user's call). At the start of a session re-date what is still current and move the rest to `plans.md`,
`ideas.md`, the adapter's `UNVERIFIED.md` or `risks.md`; a quiet repo does not go red, because age is
measured against this file's own last commit. Records are never listed here — `verified.md`, the phase
files and each `VERIFIED.md` hold them. Why two lines and a date, not a total cap: [claude-md-cap.md](claude-md-cap.md).

## Open now

- 2026-09-11 — **Autostart is opt-in everywhere now: the two Pokémon scripts look ONLY beside themselves** (ADR 0061). UNWATCHED in either game; three loads to check. Each `UNVERIFIED.md`.

- 2026-09-11 — **TEVI: some bullet BIRTH rows never reach the watcher**, so shots go missing under sustained fire — likely the extras-cap trim dropping rows oldest-first. `tevi/UNVERIFIED.md`.
- 2026-09-11 — **TEVI: bullet families that move themselves fly STRAIGHT on a ghost**; the game's own `BulletBehave` is off for good (it damaged the watcher). `tevi/UNVERIFIED.md`.
- 2026-09-11 — **The TEVI wire must be BUILD-INDEPENDENT** — the two installs are different builds. Type/sprite go by NAME; pool indices are still ordinal. `tevi/UNVERIFIED.md`.
- 2026-09-11 — **config.json is LIVE on the client** (Go side green, UNWATCHED in a game). Next: a session where the user saves a change and reads the log lines. `phases/phase10.md`.
- 2026-09-11 — **The driven ghost's hurt sit is solved (DLL port unwatched). OPEN: it never STANDS UP** — `stand_fn=` tries a candidate per launch. `pseudoregalia/UNVERIFIED.md`.
- 2026-09-11 — **The 23-agent review is WORKED TO ZERO: 150 fixed/verified, 4 left needing your call** (E11 filed by you, H19, O1, O3). `REVIEW-FINDINGS.md`, `phases/phase10.md`.
- 2026-09-11 — **Emerald is DRAWN-ONLY and all four builds see each other** (vanilla, AP, SPEEDCHOICE, EX). Cross-gender fixed by it. **EX has no occlusion** — its gMapHeader is unlocated. `emerald/PROBES.md`.
- 2026-09-11 — **The painted tier is 3.2x faster** (67ms -> 21ms at 64 peers; 32 painted hold 60fps). Water confirmed on screen; **land occlusion behind scenery is the open watch**. `emerald/UNVERIFIED.md`.
- 2026-09-11 — **Today's adapter work is UNWATCHED across all four games** — six peer-triggerable HIGHs, a CDO corruption, and the one visible change: ghosts honour `ghost_collision` now. Each `UNVERIFIED.md`.
- 2026-09-11 — **netsim has a correlated-loss model now (`-loss-burst`, opt-in) and its tcp path no longer CLUMPS**; ADR 0046's 450 ms has still never been judged on either. `phases/phase10.md`.
- 2026-09-11 — **The Archipelago pair is DONE on both sides**, plus a per-adapter protocol floor set to 2 by hand (ADR 0059). **Floors are never raised automatically — the user's call, out loud.**
- 2026-09-11 — **TCP_NODELAY is SET in all four adapters** (`55bf77d8`, 2026-09-06); only the Pseudoregalia half was watched. Open: a residual ~60 ms hitch that is not Nagle. `pseudoregalia/UNVERIFIED.md`.
- 2026-09-11 — **NOT fixed, filed with its measurement: the adapter's SEND rate sets what the core sends back** — ~171/s in, ~59,000 render lines/s out at 344 ghosts. `ideas.md`.
- 2026-09-11 — **Crystal is ACTIVE (phase 9): a second human on it, and cross-patch play.** Open: the `\uXXXX` fix, ghost solidity, a two-client AP session from the zip. `crystal/UNVERIFIED.md`.
- 2026-09-11 — **v1.1.7's engine fault site is ASSUMED FIXED by the hardened DLL** (the user's call): no action unless another crash is reported, then the feature ships OFF. `pseudoregalia/UNVERIFIED.md`.
- 2026-09-11 — **Client/config/log/replays moved to the GAME ROOT for both PC games.** Pseudoregalia confirmed; **the TEVI half is UNWATCHED.** `tevi/UNVERIFIED.md`.
- 2026-09-11 — Replay hotkeys: chords-only is the open half; the indicator half shipped 2026-09-05 (ADR 0052). `ideas.md`.
- 2026-09-11 — **Ghost cost: four things confirmed on screen 2026-09-06; the timing numbers are MEASURED, not watched.** `pseudoregalia/VERIFIED.md`, `UNVERIFIED.md`.
- 2026-09-11 — **What is plain `udp` FOR, now that no doc offers it?** Shipped option, or test/fuzz path only. Wants an ADR. `phases/phase10.md`.
- 2026-09-11 — **8 of 47 preflight sections have a negative test; 39 are assumed able to fail.** `dev-scripts/negative-test-preflight.ps1` lists them each run.
- 2026-09-11 — **The disarmed-probe WARN prints 21 entries every run**, so nobody reads it; ratchet it like the fence check. `preflight.ps1`.
- 2026-09-11 — **Replay/chaser ghosts are UNWATCHED in TEVI, Emerald and Crystal** — client-made, so they should just work; `docs/` no longer claims either way. Each `UNVERIFIED.md`.
- 2026-09-11 — **`Plugin.cpp` still says `session_policy` is "honoured by zero of four"** (two read it now). Untouched on purpose: editing it marks the committed DLL stale.
- 2026-09-11 (00:33) **Nothing is running**; ports 7777-7783 free. **Both TEVI installs are in HOT-RELOAD mode** — `-Off` before a confirmation that counts. `running-the-rig.md`.

**Trimmed 2026-09-11 back to what this file is for** — short-term memory, not a progress log
(the user's call). Eighteen items left: eleven had been carried across sessions marked *"still open,
unchanged"*, which is the definition of not-short-term, and seven were records of finished work,
which this file says are never listed here. **Every one was checked against the file it points at
before it was dropped**, and all but one were already recorded there. The exception — the four
shipped DLLs still carrying the maintainer's paths — existed only here and in `preflight.ps1`'s
allowlist, and moved to `risks.md` rather than being deleted.

## Where the rest lives

What the user has not confirmed, per game: each adapter's `UNVERIFIED.md`, whose "This run" block is
what to watch next. Known gaps and assumptions: `risks.md`. Unscheduled ideas: `ideas.md`. The roadmap:
`plans.md`. The running log per phase: `phases/README.md`. Confirmed facts: `verified.md` and each
`VERIFIED.md`. Lessons: `checklists/`, filed via `pitfalls.md`.
