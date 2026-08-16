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
- **A fresh ghost showing the LOCAL player's state instead of the peer's.** A ghost is a clone
  constructed from the local save, so at spawn it mirrors *you* — invisible in loopback, where the
  peer is you, and wrong with a real peer (their ghost would show your sword/outfit/glow). Two
  fixes shipped 2026-08-16 — re-arming the "already synced" latches when a ghost is replaced, and
  sweeping a self-constructed recall glow — but **neither can be verified without two players**,
  by construction.
- **Ghost collision keep-or-axe.** Kept ON as a deliberate feature (user decision,
  2026-08-15); its run-ending risk is fixed. Loopback cannot answer whether real-peer
  contact is disruptive. Never judge it with `LOOPBACK_GHOST_OFFSET_X = 0` — that
  reproduces the 7.4 drag bug by construction.
- **Ghost vanishes while a peer is climbing/on a pole.** Cause UNKNOWN; three suspects ruled out
  (not the slide floor fix, not the loopback offset, not ghost collision). The *"returns stuck in a
  climb pose"* half is likely fixed — the montage divergence correction was widened 2026-08-15 and
  pole climbing up/down then confirmed working. See `phase7.md`, `verified.md`.

### Open, not blocked

- **Pseudoregalia: pole rotation** — the transform sync is PROVEN exact (2469 samples, zero
  mismatch); the apparent bug is very likely the loopback offset placing the ghost beside the pole
  rather than on it. Needs a real second player to confirm, not more diagnostics. See `verified.md`.
- **Pseudoregalia: empty-hand recall glow — the precondition is now MET, retry it.** It was never
  blocked on finding the function: `manageRecallIdleFX`'s `IsValid` guards most plausibly want a
  real thrown-weapon actor, and the ghost had none. The thrown-Dream-Breaker sync (done and
  confirmed live 2026-08-15) now spawns exactly that. Retry by pointing the ghost pawn's own
  `weaponRef` at its prop before calling, or by spawning the Niagara system directly the way the
  landed sword's glow now does. Read `verified.md`'s "`manageRecallIdleFX`: NEGATIVE" entry first,
  plus the montage fix's lesson: a game wrapper that no-ops on a ghost may still work via the stock
  engine call underneath it.
- **Pseudoregalia: the ultra hop's BLUE trail is SOLVED, but not currently shipped.** An afterimage
  is a `BP_AfterImage_C` actor whose own `Color` reads `(0.000, 0.787, 1.000)` on an ultra versus
  `(1.000, 0.888, 0.260)` normally. The pawn's `afterimageColor` genuinely never changes — every
  earlier attempt had the right idea aimed at the wrong object. Reproduced live on a ghost.
  Currently OFF, because the code that read it also carried a per-tick enumeration that broke the
  trail (below).
  - **To finish**: read that colour WITHOUT the expensive scan. The cost was never the enumeration
    itself but the per-image `GetFullName()` + UTF-8 conversion and map lookups. Compare
    `cachedMesh` as a POINTER against the pawn's `VisualMesh` rather than by name, and the scan
    becomes a pointer compare plus one struct read. Keep the old burst-shaped trigger — that is
    what looks right.
- **Trail regression 2026-08-16 — FOUND AND FIXED, and the diagnostics were the bug.** Two of this
  session's own instruments corrupted the trail they were measuring, which is exactly why every
  count-based check reported perfect parity: each image that survived WAS correct; only the
  destroyed ones were missing.
  - `AFTERIMAGE_DISCOVERY` fired an afterimage into the ghost every ~3s, colliding with real bursts.
  - `TRAIL_COLOR_TRACE` plus a 3-tick scan added a second `FindAllOf`, per-image name conversions
    and a log line per image, on the game thread. The game spawns afterimages as a countdown ACROSS
    ticks, so stalling that thread truncates bursts in flight — intermittently.
  - **Found by bisecting real commits** after a flag-flip A/B gave the wrong answer: only the
    counter increment *inside* the scan was gated, so flipping the flag left the expensive work
    running. **A flag flip is not a revert** unless the flag disables the work, not merely the
    decision that work feeds. That gate is fixed.
  - Confirmed working after the fix, user-watched: dense repeating slide trail, ghost within 1-2
    images of the real player.
  - **Known minor overhang**: the ghost spawns 1-2 more images than the player at the END of a
    slide. The knob is `SLIDE_REFIRE_WINDOW_TICKS` (currently 40), which sets when the LAST image
    spawns — not the interval. Left untuned deliberately: cosmetic, and one constant.
- **Pseudoregalia: a `Fatal Error!` crash on game exit**, seen once, never root-caused.
- **Pseudoregalia: a ghost's thrown sword near the save crystal looks wrong in loopback.** Expected,
  not a bug to chase here: the ghost is offset 150 units sideways, so its arc is computed against
  geometry that isn't where the ghost is. Same artifact as the pole-rotation item above; needs a
  real second player to judge.
- **TEVI: charged-attack VFX missing on the ghost** — animations play, the extra effects
  don't. Not root-caused. See `phase6.md`'s 2026-08-15 entry.
- **Emerald: surf, Mach/Acro Bike, ledges, Mach Bike rails** — the ghost snaps badly on all
  of these. Detection source cited; a combined probe script is ready but **not yet run**.
- **Emerald: VRAM/sprite injection** — 5-stage plan agreed, Stage 1 not started.
- **Send/receive rate control** (built 2026-08-15) — `go test` clean and the new tests were
  confirmed to fail when broken, but **not live-verified**: needs two clients, one with a low
  `max_receive_hz_per_player`, watched on screen at visibly different smoothness.
- **Relay-safety follow-ups, out of scope so far**: no TLS (room codes in plaintext), TEVI's
  `game_version` isn't a real Steam build number, and the *adapters'* message parsing never had
  the adversarial-input audit the Go layer got.

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
