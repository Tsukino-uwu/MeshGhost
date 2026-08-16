# Current status

## Active status

- **Active phase: Phase 8 (Emerald), in progress since 2026-08-14.** TEVI (6) and Pseudoregalia (7)
  both ship in the release zip, marked experimental. TEVI is done through 6.6/6.7; Pseudoregalia
  through 7.6, and **7.7 (a real two-player test) has not started.** `plans.md` is the
  authoritative roadmap; `phases/phase6.md`/`phase7.md`/`phase8.md` hold the task-by-task record.

## Genuinely open items

Fixed-and-confirmed work is not listed here — see `verified.md` and the phase files.

### Blocked on a real two-player session (Pseudoregalia 7.7)

- **7.7 itself** — untested; Steam single-instance behavior for this game is unconfirmed
  either way. This is the top unblock: it also gates the items below.
- **A fresh ghost showing the LOCAL player's state instead of the peer's.** A ghost is a clone of
  the local save, so at spawn it mirrors *you* — invisible in loopback, wrong with a real peer. Two
  fixes shipped 2026-08-16 (re-arming the "already synced" latches on ghost replacement, sweeping a
  self-constructed recall glow); **neither is verifiable without two players**, by construction.
- **Ghost collision keep-or-axe.** Kept ON deliberately (user decision, 2026-08-15); its run-ending
  risk is fixed. Never judge it with `LOOPBACK_GHOST_OFFSET_X = 0` — that reproduces the 7.4 drag
  bug by construction.
- **Ghost vanishes while a peer is climbing/on a pole.** Cause UNKNOWN; three suspects ruled out.
  The *"returns stuck in a climb pose"* half is likely fixed. See `phase7.md`, `verified.md`.
- **Pole rotation, and a thrown sword near the save crystal.** Both very likely the loopback offset
  placing the ghost beside the geometry the arc/rotation was computed against — the pole sync is
  PROVEN exact (2469 samples, zero mismatch). Needs a second player, not diagnostics.

### Open, not blocked

- **Pseudoregalia: re-enable the ultra hop's BLUE trail.** Colour SOLVED (`verified.md`):
  `BP_AfterImage_C`'s own `Color`, `(0.000, 0.787, 1.000)` on an ultra. OFF because the code
  reading it carried a per-tick enumeration that broke the trail. **To finish:** compare
  `cachedMesh` by POINTER against the pawn's `VisualMesh` (the per-object `GetFullName()`/UTF-8
  conversion was the cost, not the enumeration); keep the burst-shaped trigger. Read `pitfalls.md`'s
  "The diagnostics were the bug" first.
- **Pseudoregalia: slide trail tail overhang.** Ghost spawns 1-2 more images than the player at the
  END of a slide. One constant: `SLIDE_REFIRE_WINDOW_TICKS` (40) sets when the LAST image spawns,
  not the interval. Cosmetic.
- **Pseudoregalia: a `Fatal Error!` crash on game exit**, seen once, never root-caused. Not the
  2026-08-16 level-transition crash, which is fixed and confirmed.
- **TEVI: charged-attack VFX missing on the ghost** — animations play, the effects don't. Not
  root-caused. See `phase6.md`'s 2026-08-15 entry.
- **Emerald: surf, Mach/Acro Bike, ledges, Mach Bike rails** — ghost snaps badly on all of these.
  A combined probe script is ready but **not yet run**.
- **Emerald: VRAM/sprite injection** — 5-stage plan agreed, Stage 1 not started.
- **Send/receive rate control** (built 2026-08-15) — `go test` clean, **not live-verified**: needs
  two clients, one with a low `max_receive_hz_per_player`, watched for a smoothness difference.
- **Relay-safety follow-ups, out of scope so far**: no TLS (room codes in plaintext), TEVI's
  `game_version` isn't a real Steam build number, and the *adapters'* message parsing never had
  the adversarial-input audit the Go layer got.

## Links

`plans.md` (roadmap) · `phases/phase6.md`|`phase7.md`|`phase8.md` (per-phase log) · `risks.md`
(assumptions) · `verified.md` (confirmed facts) · `pitfalls.md` (symptom → cause → fix, and the
diagnostic methodology rules).

## Update guidance

- Update whenever the active phase changes — overwrite in place, never append.
- **Keep this to one screen (~50 lines).** When an item is fixed and confirmed, delete it
  here and let `verified.md`/the phase file hold the record; don't leave a "FIXED" entry
  behind. Narrative detail belongs in `agent_docs/phases/phaseN.md`.
