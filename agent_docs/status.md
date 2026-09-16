# Current status

**Active phases: 6 (TEVI) and 9 (Crystal), with 7 (Pseudoregalia), 10 (the Go side) and 11 (replays) live.** This file is an index of what
is open right now: **two lines per item, maximum** ([claude-md-cap.md](claude-md-cap.md)), **each carrying the date it was last re-checked, and an item dated
more than 2 days before this file's last commit fails preflight** — at this project's pace, 2026-08-31 is
already not current on 2026-09-02 (user's call). At the start of a session re-date what is still current and move the rest to `plans.md`,
`ideas.md`, the adapter's `UNVERIFIED.md` or `risks.md`; a quiet repo does not go red, because age is
measured against this file's own last commit. It lists tasks: what is running is not one (`running-the-rig.md`, the user's call 2026-09-16). Records are never listed here — `verified.md`, the phase
files and each `VERIFIED.md` hold them. Why two lines and a date, not a total cap: [claude-md-cap.md](claude-md-cap.md). **An item may say `hold to <date>`** when the user has scheduled it past the two days: preflight ages it by its newest date, so it stays until then, and only the user's call sets that date.

## Open now

- 2026-09-15 — **TLS always on, TOFU and the room-code PAKE are LANDED (ADRs 0066, 0067; protocol 3).** UNWATCHED in a real game: a coded join; the "identity changed" warning after `private/` is deleted.
- 2026-09-15 — **Both `config.json` files are LIVE** (relay: room_code/only_game/max_clients; client: smoothing, chaser, replay, hotkeys); never watched with a real client editing one. `phases/phase10.md`.
- 2026-09-16 — **Adapter work from 2026-09-11 to 09-16 is UNWATCHED in all four games** (peer-input hardening, 29 SYNCED.md guards, autostart opt-in, replay/chaser ghosts, pass 5's fixes). Each `UNVERIFIED.md`.
- 2026-09-16 — **Prediction: A3 LANDED (ADR 0069, ships off), SCREEN VERDICT OPEN; A2.0 MEASURED** (worst-case transit p99 310–320ms; the dry tail is the 1 s blackouts); A2 undecided. `prediction-planning.md`.
- 2026-09-15 — **Chaser contact: the Go half LANDED (`e546d38c`, ADR 0068, ships `off`); the adapter half is NOT started.** Next: Part A of `chaser-planning.md`; `pseudoregalia/UNVERIFIED.md` has the entry.
- 2026-09-15 — **netsim: ADR 0046's 450 ms has never been judged on the correlated-loss model** (`-loss-burst`, opt-in since 2026-09-11). `phases/phase10.md`.
- 2026-09-16 — **Audit second sweep DONE: four `documentation.md` stripped to mechanics; Lua decomp citations are pointers under a preflight ratchet; per-site rewrite is the user's call.** `phases/phase12.md`.

**Trimmed 2026-09-15**: records of finished work were dropped and items already queued in an
adapter's `UNVERIFIED.md` folded into one line per game; every pointer was checked against its
file first, and the `adapters/CLAUDE.md` item was fixed in place rather than carried.

## Where the rest lives

What the user has not confirmed, per game: each adapter's `UNVERIFIED.md`, whose "This run" block is
what to watch next. Known gaps and assumptions: `risks.md`. Unscheduled ideas: `ideas.md`. The roadmap:
`plans.md`. The running log per phase: `phases/README.md`. Confirmed facts: `verified.md` and each
`VERIFIED.md`. Lessons: `checklists/`, filed via `pitfalls.md`.
