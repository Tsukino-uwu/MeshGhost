# Current status

## Active status

**Phase 7 (Pseudoregalia) is the live one** — all of 2026-08-16 went to its trail/VFX sync; Phase 8
(Emerald) is open but idle since 2026-08-14; Phase 6 (TEVI) is done. Both shipping adapters are in
the release zip marked experimental, and **7.7 (a real two-player test) has not started.**
Roadmap: `plans.md`. Per-phase log: `phases/`.

## Genuinely open items

Fixed-and-confirmed work is not listed here — see `verified.md` and the phase files.

### Was blocked on a two-player session — now unblocked (7.7 confirmed 2026-08-16)

Two real players on two machines, confirmed on screen — `verified.md`. These need re-judging now
that a peer's state genuinely differs from the local player's, which loopback could never show:

- **A fresh ghost shows the LOCAL player's state, not the peer's.** Two fixes shipped 2026-08-16,
  never verifiable in loopback — `verified.md` (recall glow entry).
- **Ghost collision keep-or-axe.** Kept ON deliberately; run-ending risk fixed. `risks.md`.
- **Ghost vanishes while a peer is on a pole.** Cause unknown, three suspects ruled out;
  `phase7.md`.
- **A thrown sword near a save crystal.** Suspected a loopback-offset artifact rather than a real
  bug; a two-machine session settles it. (Pole rotation, same suspicion, confirmed FINE
  2026-08-16.) `verified.md`.

### Open, not blocked

- **Camera not re-grabbed after a cutscene or "reset to last save"** (user-reported 2026-08-16).
  The fight-back hook rewrites EVERY view-target change once a ghost exists; `phase7.md`, and read
  the existing `camera fight-back: rewriting` log lines before instrumenting.
- **Two different games at once is broken** — both mods use bridge port 7778, and a core serves
  one game only, so the second reconnects forever in silence. Fix options in `ideas.md`.
- **Autostart: TEVI and Emerald not converted yet.** Windows and Proton both fully confirmed;
  Emerald needs a spawn-mechanism spike (BizHawk Lua has no hidden-process API). `verified.md`.
- **Pseudoregalia: a `Fatal Error!` on game exit**, seen once, never root-caused. Not the
  2026-08-16 transition crash, which is fixed.
- **TEVI: charged-attack VFX missing on the ghost** — animations play, effects don't.
  `phase6.md` (2026-08-15).
- **Emerald: surf, Mach/Acro Bike, ledges, rails** — ghost snaps badly; combined probe script
  ready, **not yet run**. `phase8.md`.
- **Emerald: VRAM/sprite injection** — Stage 1 ran 2026-08-14 and is written up; Stages 2–5 not
  started. `ideas.md`, `environment.md`.
- **Receive rate cap** — `max_receive_hz_per_player` never watched live; needs two clients at
  different caps. (The send side was confirmed on screen 2026-08-15.) `architecture.md` ADR.
- **Relay-safety follow-ups**: no TLS on `tcp`/`udp` (room codes in plaintext; `quic` is encrypted),
  TEVI's `game_version` isn't real, adapters' parsing never got the adversarial audit. `internal/README.md`.
- **Selectable transport shipped 2026-08-16**, all three confirmed live on Pseudoregalia — open:
  no sustained-load or two-machine test, `udp` unencryptable, no per-IP cap. `verified.md`, `risks.md`.
- **A served-but-unforwarded transport strands a client** — discovery knows what a relay offers,
  not whether the path works, so it retries instead of falling back to tcp. Docs-only for now.
- **Suspected: Pseudoregalia mod may not clear ghosts when the bridge drops** — pre-existing, any
  transport. Planned fix: `release_all_ghosts` on bridge loss, NOT parking. `verified.md` 2026-08-16.

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
