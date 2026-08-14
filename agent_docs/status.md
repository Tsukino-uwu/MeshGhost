# Current status

## Active status

- **Active phase: Phase 8 (Emerald, dedicated ongoing work), in progress since 2026-08-14.** TEVI
  (Phase 6) and Pseudoregalia (Phase 7) have both shipped in the release zip, marked
  experimental. TEVI is fully done through 6.6/6.7 (two real players, map markers), confirmed
  live. Pseudoregalia is done through 7.6 (real character-visual ghost, animation, facing
  direction); **7.7 (a real two-player test) has not started.** See `agent_docs/plans.md` for the
  authoritative roadmap and `agent_docs/phases/phase6.md`/`phase7.md`/`phase8.md` for the
  full task-by-task record of each.

## Genuinely open items

- **Pseudoregalia 7.7** — two real players, not yet tested (Steam single-instance behavior for
  this game is unconfirmed either way). See `agent_docs/phases/phase7.md`.
- **Pseudoregalia: a not-yet-root-caused `Fatal Error!` crash** observed once on game exit in an
  earlier session (crashdump, not `LowLevelFatalError`) — see `agent_docs/phases/phase7.md`'s 7.6
  entry.
- **Emerald: surf, Mach Bike, Acro Bike, ledges, and Mach Bike rail sections** — the ghost snaps
  badly on all of these today; detection source found and cited
  (`pokeemerald`'s `include/global.fieldmap.h:288-295`), a combined probe script is ready but not
  yet run. See `agent_docs/phases/phase8.md`.
- **Emerald: VRAM/sprite injection investigation** (`agent_docs/ideas.md`) — a 5-stage test plan
  is agreed; Stage 1 (read-only vanilla probe) not started. See `agent_docs/phases/phase8.md`.
- **Relay-safety follow-ups, deliberately out of scope so far**: no TLS (a room code crosses the
  wire in plaintext), TEVI's `game_version` doesn't reflect a real Steam build number, and the
  adapters' own message-parsing code hasn't been audited with an adversarial-input mindset the
  way the Go relay/core layer was. See `agent_docs/risks.md` and `agent_docs/plans.md`'s "Room
  codes / relay safety" section.

## Links

- `agent_docs/plans.md` — the authoritative roadmap and per-phase status.
- `agent_docs/phases/phase6.md` — TEVI, fully done.
- `agent_docs/phases/phase7.md` — Pseudoregalia, done through 7.6, 7.7 open.
- `agent_docs/phases/phase8.md` — Emerald's ongoing post-5.5 work, in progress.
- `agent_docs/risks.md` — assumptions and risk register.
- `agent_docs/verified.md` — append-only verification log.

## Update guidance

- Update this file whenever the active phase changes — overwrite the relevant line/section in
  place, don't append a new one.
- Keep entries short; this is a one-screen summary, not a log. Narrative detail belongs in the
  relevant `agent_docs/phases/phaseN.md`.
