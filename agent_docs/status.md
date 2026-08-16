# Current status

## Active status

**Phase 8 (Emerald), in progress since 2026-08-14.** TEVI (6) and Pseudoregalia (7) both ship in the
release zip, marked experimental — TEVI done through 6.6/6.7, Pseudoregalia through 7.6, and
**7.7 (a real two-player test) has not started.** Roadmap: `plans.md`. Per-phase log: `phases/`.

## Genuinely open items

Fixed-and-confirmed work is not listed here — see `verified.md` and the phase files.

### Blocked on a real two-player session (Pseudoregalia 7.7)

- **7.7 itself** — untested; Steam single-instance behavior unconfirmed. Top unblock; gates
  everything below.
- **A fresh ghost shows the LOCAL player's state, not the peer's.** Two fixes shipped 2026-08-16,
  neither verifiable in loopback by construction — `verified.md` (recall glow entry).
- **Ghost collision keep-or-axe.** Kept ON deliberately; run-ending risk fixed. Never judge with
  `LOOPBACK_GHOST_OFFSET_X = 0` — reproduces the 7.4 drag bug. `risks.md`.
- **Ghost vanishes while a peer is on a pole.** Cause unknown, three suspects ruled out; the
  "stuck in a climb pose" half likely fixed. `phase7.md`.
- **Pole rotation, and a thrown sword near a save crystal.** Both very likely the loopback offset,
  not real bugs; pole sync PROVEN exact. `verified.md`.

### Open, not blocked

- **Pseudoregalia: re-enable the ultra hop's BLUE trail.** Colour solved, currently OFF. Read
  `verified.md` and `pitfalls.md`'s "The diagnostics were the bug" before touching it.
- **Pseudoregalia: slide trail tail overhang.** 1-2 extra ghost images at a slide's end; one
  constant, `SLIDE_REFIRE_WINDOW_TICKS`. Cosmetic.
- **Pseudoregalia: a `Fatal Error!` on game exit**, seen once, never root-caused. Not the
  2026-08-16 transition crash, which is fixed.
- **TEVI: charged-attack VFX missing on the ghost** — animations play, effects don't.
  `phase6.md` (2026-08-15).
- **Emerald: surf, Mach/Acro Bike, ledges, rails** — ghost snaps badly; combined probe script
  ready, **not yet run**. `phase8.md`.
- **Emerald: VRAM/sprite injection** — 5-stage plan agreed, Stage 1 not started. `ideas.md`.
- **Send/receive rate control** — `go test` clean, **not live-verified**; needs two clients at
  different `max_receive_hz_per_player`. `architecture.md` ADR.
- **Relay-safety follow-ups**: no TLS (room codes in plaintext), TEVI's `game_version` isn't a real
  build number, adapters' parsing never got the adversarial audit. `internal/README.md`.

## Links

`plans.md` (roadmap) · `phases/phase6.md`|`phase7.md`|`phase8.md` (per-phase log) · `risks.md`
(assumptions) · `verified.md` (confirmed facts) · `pitfalls.md` (symptom → cause → fix, and the
diagnostic methodology rules).

## Update guidance

This file is an **index of what is open**, not a record of anything. Every item here is a pointer;
the record lives in `verified.md`, `pitfalls.md`, or a phase file.

- **Two lines per item, maximum: what is open, and where the detail lives.** A third line means it
  belongs in `verified.md`/`pitfalls.md`/`phases/phaseN.md` — move it, leave a pointer. (Replaced a
  flat line cap on 2026-08-16, which capped the file but not per-item verbosity, so it crept back.)
- **Delete an item the moment it is fixed and confirmed** — never leave a "FIXED" entry behind.
- Update whenever the active phase changes — overwrite in place, never append.
