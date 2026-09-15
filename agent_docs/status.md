# Current status

**Active phases: 6 (TEVI) and 9 (Crystal), with 7 (Pseudoregalia), 10 (the Go side) and 11 (replays) live.** This file is an index of what
is open right now: **two lines per item, maximum** ([claude-md-cap.md](claude-md-cap.md)), **each carrying the date it was last re-checked, and an item dated
more than 2 days before this file's last commit fails preflight** — at this project's pace, 2026-08-31 is
already not current on 2026-09-02 (user's call). At the start of a session re-date what is still current and move the rest to `plans.md`,
`ideas.md`, the adapter's `UNVERIFIED.md` or `risks.md`; a quiet repo does not go red, because age is
measured against this file's own last commit. Records are never listed here — `verified.md`, the phase
files and each `VERIFIED.md` hold them. Why two lines and a date, not a total cap: [claude-md-cap.md](claude-md-cap.md). **An item may say `hold to <date>`** when the user has scheduled it past the two days: preflight ages it by its newest date, so it stays until then, and only the user's call sets that date.

## Open now

- 2026-09-15 — **CI at `b322c224` was red on all three workflows; every cause is fixed in this session, nothing pushed.** After the push: `gh run list -L 5`, then `--log-failed` on anything red.
- 2026-09-15 — **Flake seen once under `-race` with every package running beside it: netsim's `TestTCPDelayDoesNotClumpTheStream`** (10 ms spacing); 6/6 green standalone. `phases/phase10.md`.
- 2026-09-15 — **CI: `core` under `-race` is near its 600 s package limit** (528 s in run 34997994110). Next red is likely; `run-gotests-race.bat` passes locally.
- 2026-09-15 — **TLS always on, TOFU and the room-code PAKE are LANDED (ADRs 0066, 0067; protocol 3).** UNWATCHED in a real game: a coded join; the "identity changed" warning after `private/` is deleted.
- 2026-09-15 — **Both `config.json` files are LIVE** (relay: room_code/only_game/max_clients; client: smoothing, chaser, replay, hotkeys); never watched with a real client editing one. `phases/phase10.md`.
- 2026-09-15 — **Review pass 3's remainder lost its detail** (the cell reports were never tracked): P1b's timer sum FIXED today, P2f-3 already fixed in the Lua; the rest needs a re-run. `phases/phase10.md`.
- 2026-09-15 — **PARKED, the user's call: measure whether quic's congestion controller paces datagrams late after a loss** (the 2026-09-02 bike glide). Instrument, matrix and decision rule in `ideas.md`.
- 2026-09-15 — **Adapter work from 2026-09-11/12 is UNWATCHED in all four games** (peer-input hardening, `ghost_collision` in the Pokémon pair, autostart opt-in, replay/chaser ghosts). Each `UNVERIFIED.md`.
- 2026-09-15 — **TEVI open**: bullet BIRTH rows missing under sustained fire; self-moving bullets fly straight on a ghost; pool indices ordinal across builds; game-root move unwatched. `tevi/UNVERIFIED.md`.
- 2026-09-15 — **Pseudoregalia open**: the driven ghost never STANDS UP after its hurt sit (`stand_fn=`); a ~60 ms hitch, not Nagle; a never-worn costume retries unbounded. `pseudoregalia/UNVERIFIED.md`.
- 2026-09-15 — **Emerald open**: the painted ghost's BIKES are fixed but unjudged (four causes, none watched); `noclip` does not reach water. `emerald/UNVERIFIED.md`.
- 2026-09-15 — **Crystal is ACTIVE (phase 9)**: the `\uXXXX` fix, ghost solidity, a two-client AP session from the zip; the first-step ghost start is measured, not judged. `crystal/UNVERIFIED.md`.
- 2026-09-15 — **Prediction groundwork LANDED (`d53291a5`, ADR 0069; `correction` ships `0s`); SCREEN VERDICT OPEN** on netsim no-arg; A2 waits on the stats-line sizing numbers. `prediction-planning.md`.
- 2026-09-15 — **CI sharded (fuzz six runners, race three), unproven until the next push lands.** Next cut: the release's Windows tests beside the unix job; `phases/phase10.md` (after prediction).
- 2026-09-15 — **Chaser contact: the Go half LANDED (`e546d38c`, ADR 0068, ships `off`); the adapter half is NOT started.** Next: Part A of `chaser-planning.md`; `pseudoregalia/UNVERIFIED.md` has the entry.
- 2026-09-15 — **netsim: ADR 0046's 450 ms has never been judged on the correlated-loss model** (`-loss-burst`, opt-in since 2026-09-11). `phases/phase10.md`.
- 2026-09-15 — **preflight chores**: 39 of 47 sections have no negative test (`negative-test-preflight.ps1` lists them); the disarmed-probe WARN prints 21 entries every run — ratchet it.
- 2026-09-15 — **`Plugin.cpp` comments are stale** (`session_policy` "zero of four"; the deleted `PLAYER_FIELDS.md`): fix at the next rebuild, since editing marks the committed DLL stale.
- 2026-09-15 — **Nothing is running**; loader targets `none`. **TEVI is HOT-RELOAD: `-Off` before a real confirmation.** `running-the-rig.md`.
- 2026-09-13, hold to 2026-09-16 — **AUDIT QUEUED: "measured or observed only" for all pre-rule content** — start at the two preflight ratchets. `phases/phase9.md`, `licensing.md`.
- 2026-09-13, hold to 2026-09-16 — **SYNCED.md: guard the 29 `not checked yet` values** (6/20/2/1) and lower each ratchet. Each `SYNCED.md`; whole-message gaps in each `UNVERIFIED.md`.
- 2026-09-13, hold to 2026-09-16 — **SYNCED.md is not checked by CI on a code-only push** (`docs.yml` may not filter adapter paths). Wire it into the adapter workflows, or accept. `phases/phase12.md`.

**Trimmed 2026-09-15**: records of finished work were dropped and items already queued in an
adapter's `UNVERIFIED.md` folded into one line per game; every pointer was checked against its
file first, and the `adapters/CLAUDE.md` item was fixed in place rather than carried.

## Where the rest lives

What the user has not confirmed, per game: each adapter's `UNVERIFIED.md`, whose "This run" block is
what to watch next. Known gaps and assumptions: `risks.md`. Unscheduled ideas: `ideas.md`. The roadmap:
`plans.md`. The running log per phase: `phases/README.md`. Confirmed facts: `verified.md` and each
`VERIFIED.md`. Lessons: `checklists/`, filed via `pitfalls.md`.
