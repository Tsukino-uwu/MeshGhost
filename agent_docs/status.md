# Current status

## Active status

- **Active phase: Phase 8 (Emerald, dedicated ongoing work), in progress since 2026-08-14.**
  TEVI (Phase 6) and Pseudoregalia (Phase 7) have both shipped in the release zip, marked
  experimental. TEVI is fully done through 6.6/6.7. Pseudoregalia is done through 7.6;
  **7.7 (a real two-player test) has not started.** See `agent_docs/plans.md` for the
  authoritative roadmap and `agent_docs/phases/phase6.md`/`phase7.md`/`phase8.md` for the
  task-by-task record.

## Genuinely open items

Fixed-and-confirmed work is not listed here — see `verified.md` and the phase files.

### Blocked on a real two-player session (Pseudoregalia 7.7)

- **7.7 itself** — untested; Steam single-instance behavior for this game is unconfirmed
  either way. This is the top unblock: it also gates the two items below.
- **Ghost collision keep-or-axe.** Kept ON as a deliberate feature (user decision,
  2026-08-15); its run-ending risk is fixed. Loopback cannot answer whether real-peer
  contact is disruptive. Never judge it with `LOOPBACK_GHOST_OFFSET_X = 0` — that
  reproduces the 7.4 drag bug by construction.
- **Ghost vanishes while a peer is climbing/on a pole, then returns stuck in a climb pose.**
  Cause UNKNOWN; two suspects ruled out with evidence (not the slide floor fix, not purely
  the loopback offset). See `phase7.md`.

### Open, not blocked

- **Pseudoregalia: empty-hand recall glow** — blocked on a *precondition* (needs a real
  thrown-weapon actor for `manageRecallIdleFX`'s `IsValid` guards), not on finding the right
  function. Read `verified.md`'s "`manageRecallIdleFX`: NEGATIVE" entry before retrying —
  **and the montage fix's lesson first**: the game's own wrapper bailing on a ghost was worked
  around by calling the stock engine function underneath it, which may apply here too.
- **Pseudoregalia: which montages now ride the mirror for free — UNTESTED.** The montage mirror
  (2026-08-15, `verified.md`) is general, so attack/hurt/ledge-hang montages may already play on
  the ghost with no new code. Nobody has watched. One loopback session answers it; test before
  building anything.
- **Pseudoregalia: ultra hop's BLUE trail — PARKED with evidence.** Not `afterimageColor`,
  not `ultraCap`/`fullUltraModifier`/`cappedUltraModifier`/`animJumpType`. Not derivable
  from polled state; do not resume by guessing more property names.
- **Pseudoregalia: a `Fatal Error!` crash on game exit**, seen once, never root-caused.
- **TEVI: charged-attack VFX missing on the ghost** — animations play, the extra effects
  don't. Not root-caused. See `phase6.md`'s 2026-08-15 entry.
- **Emerald: surf, Mach/Acro Bike, ledges, Mach Bike rails** — the ghost snaps badly on all
  of these. Detection source cited; a combined probe script is ready but **not yet run**.
- **Emerald: VRAM/sprite injection** — 5-stage plan agreed, Stage 1 not started.
- **Send/receive rate control** (built 2026-08-15) — `go test` clean and the new tests were
  confirmed to fail when broken, but **not live-verified**: needs two clients, one with a low
  `max_receive_hz_per_player`, watched on screen at visibly different smoothness.
- **Relay-safety follow-ups, deliberately out of scope so far**: no TLS (room codes cross the
  wire in plaintext), TEVI's `game_version` isn't a real Steam build number, and the
  *adapters'* message parsing has never had the adversarial-input audit the Go layer got.

## Links

- `agent_docs/plans.md` — authoritative roadmap and per-phase status.
- `agent_docs/phases/phase6.md` (TEVI, done) / `phase7.md` (Pseudoregalia, 7.7 open) /
  `phase8.md` (Emerald, in progress).
- `agent_docs/risks.md` — assumptions and risk register.
- `agent_docs/verified.md` — append-only verification log.

## Update guidance

- Update whenever the active phase changes — overwrite in place, never append.
- **Keep this to one screen (~50 lines).** When an item is fixed and confirmed, delete it
  here and let `verified.md`/the phase file hold the record; don't leave a "FIXED" entry
  behind. Narrative detail belongs in `agent_docs/phases/phaseN.md`.
