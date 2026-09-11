# Current status

**Active phases: 6 (TEVI) and 9 (Crystal), with 7 (Pseudoregalia), 10 (the Go side) and 11 (replays) live.** This file is an index of what
is open right now: **two lines per item, maximum** ([claude-md-cap.md](claude-md-cap.md)), **each carrying the date it was last re-checked, and an item dated
more than 2 days before this file's last commit fails preflight** — at this project's pace, 2026-08-31 is
already not current on 2026-09-02 (user's call). At the start of a session re-date what is still current and move the rest to `plans.md`,
`ideas.md`, the adapter's `UNVERIFIED.md` or `risks.md`; a quiet repo does not go red, because age is
measured against this file's own last commit. Records are never listed here — `verified.md`, the phase
files and each `VERIFIED.md` hold them. Why two lines and a date, not a total cap: [claude-md-cap.md](claude-md-cap.md).

## Open now

- 2026-09-11 — **TEVI: some bullet BIRTH rows never reach the watcher**, so shots go missing under sustained fire — likely the extras-cap trim dropping rows oldest-first. `tevi/UNVERIFIED.md`.
- 2026-09-11 — **TEVI: bullet families that move themselves fly STRAIGHT on a ghost**; the game's own `BulletBehave` is off for good (it damaged the watcher). `tevi/UNVERIFIED.md`.
- 2026-09-11 — **The TEVI wire must be BUILD-INDEPENDENT** — the two installs are different builds. Type/sprite go by NAME; pool indices are still ordinal. `tevi/UNVERIFIED.md`.
- 2026-09-11 — **config.json is LIVE on the client** (Go side green, UNWATCHED in a game). Next: a session where the user saves a change and reads the log lines. `phases/phase10.md`.
- 2026-09-11 — **The driven ghost's hurt sit is solved (DLL port unwatched). OPEN: it never STANDS UP** — `stand_fn=` tries a candidate per launch. `pseudoregalia/UNVERIFIED.md`.
- 2026-09-11 — **The 23-agent review: 39 findings fixed Go-side, ~109 open** in the untracked `REVIEW-FINDINGS.md` — the checklist; delete it when it empties. `phases/phase10.md`.
- 2026-09-11 — **netsim is milder than "bad wifi" and ADR 0046's 450 ms rests on it**: Bernoulli loss never reaches the 150-500 ms regime, so 450 may be UNDER-sized. `REVIEW-FINDINGS.md` D5.
- 2026-09-11 — **Both Archipelago proposals shipped Go-side** (version FLOOR; `reject` `code`+`retryable`). **The adapter half is open — all four still substring-match.** ADR 0058.
- 2026-09-11 — **TCP_NODELAY fixed the Linux tester's stutter on Pseudoregalia; still open on TEVI and both Lua adapters**, plus a residual that is not Nagle. `pseudoregalia/UNVERIFIED.md`.
- 2026-09-11 — **NOT fixed, filed with its measurement: the adapter's SEND rate sets what the core sends back** — ~171/s in, ~59,000 render lines/s out at 344 ghosts. `ideas.md`.
- 2026-09-11 — **Crystal is ACTIVE (phase 9): a second human on it, and cross-patch play.** Open: the `\uXXXX` fix, ghost solidity, a two-client AP session from the zip. `crystal/UNVERIFIED.md`.
- 2026-09-11 — **HIGH: v1.1.7 crashed at a new engine fault site. The hardened DLL is deployed and UNPROVEN**; if it recurs the feature ships OFF. `pseudoregalia/UNVERIFIED.md`.
- 2026-09-11 — **Client/config/log/replays moved to the GAME ROOT for both PC games.** Pseudoregalia confirmed; **the TEVI half is UNWATCHED.** `tevi/UNVERIFIED.md`.
- 2026-09-11 — Replay hotkeys: chords-only is the open half; the indicator half shipped 2026-09-05 (ADR 0052). `ideas.md`.
- 2026-09-11 — **The FPS that outlived a ghost was its `BP_PlayerCam_C` rig: FIXED and census-clean on all three despawn paths, UNWATCHED by the user.** `pseudoregalia/UNVERIFIED.md`.
- 2026-09-11 — **Ghost cost: four things confirmed on screen 2026-09-06; the timing numbers are MEASURED, not watched.** `pseudoregalia/VERIFIED.md`, `UNVERIFIED.md`.
- 2026-09-11 — **The on-screen INPUT HISTORY is built on both sides and has been SEEN; the user's words on the read-back are still owed.** `pseudoregalia/UNVERIFIED.md`, ADR 0057.
- 2026-09-11 — **The recording indicator is a screen-space widget**: the mechanism is user-confirmed on the Lua prototype, the C++ port SEEN in a screenshot, their words owed. `pseudoregalia/UNVERIFIED.md`.
- 2026-09-11 — **What is plain `udp` FOR, now that no doc offers it?** Shipped option, or test/fuzz path only. Wants an ADR. `phases/phase10.md`.
- 2026-09-11 — **The leak gates do not scan for IP ADDRESSES**: a tester's LAN address reached a committed file from pasted log output, past both the hook and preflight (fixed `82553f8d`). Worth a rule there. `pitfalls.md`'s leak cases.
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
