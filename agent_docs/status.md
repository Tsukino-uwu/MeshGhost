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
- **TEVI: charged-attack VFX missing on the ghost** — animations play correctly, but the extra
  visual effects on the charged attack (held attack button) don't render. Not yet root-caused.
  See `agent_docs/phases/phase6.md`'s 2026-08-15 entry.
- **Pseudoregalia: Dream Breaker held/thrown visibility — FIXED and confirmed live 2026-08-15.**
  Root cause found via a genuine 0%/100%-completion save comparison (a new reusable diagnostic
  method, documented in `adapters/pseudoregalia/README.md`'s build-log step 20): the ghost-write
  code wrote `weaponEquipped?`/`animEquippedWeapon` directly onto the ghost *before* calling
  `changeEquippedWeapon`/`updateWeaponEquip`, so those calls always saw the property already at
  the new value and silently did nothing. Fix was a pure reorder (calls first, property write
  after, as a safety-net) — no new function or property needed. User confirmed on screen: sword
  disappears on a real throw. Pickup direction (false→true) not separately watched yet, but same
  code path. **Pickup animation: confirmed fixed as a free side effect of the same reorder** — user
  watched it directly, previously didn't play at all, now plays correctly on pickup. **Throw
  animation: still separately blocked, NOT fixed** — user explicitly confirmed something else is
  still preventing the throw motion specifically, distinct from the pickup direction. Not yet
  root-caused; needs its own investigation, don't assume the reorder fixed both directions
  symmetrically just because it fixed pickup.
- **Pseudoregalia: outfit/costume sync — FIXED and confirmed live 2026-08-15, same day as the
  weapon fix.** `VisualMesh.SkeletalMesh`/`SkinnedAsset` swap directly per outfit (found via a
  live value-diff straddling real costume swaps, no boolean flag or animBPref indirection like
  weapon needed). First sync attempt (a raw property write) produced a real negative: the ghost
  T-posed instead of showing the new costume — the mesh reference stuck but the engine never
  re-bound the anim instance. Root cause: `SetSkeletalMeshAsset` (found via a live function-name
  dump — the only real candidate this build's reflection exposes; no `SetSkeletalMesh`/`InitAnim`/
  `MarkRenderStateDirty` exist) needed to be called, not just the property written. Fix calls it
  first, property write kept after as a safety net — applying the weapon fix's ordering lesson
  proactively this time. User confirmed on screen: ghost correctly swapped costume, no T-pose.
- **Still fully open**: ability VFX only (cling-gem sparkle, empty-hand glow — zero sync code,
  only read-only diagnostics exist). This is now the only remaining Pseudoregalia visual gap. See
  `agent_docs/verified.md`'s "Dream Breaker weapon-visibility" and "Outfit/costume sync" entries
  and `adapters/pseudoregalia/PLAYER_FIELDS.md`.
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
- **Send/receive rate control (`server.send_hz` / `client.max_receive_hz_per_player`), built
  2026-08-15** — `go test` clean, all new tests confirmed to actually fail when their check is
  broken, but **not yet live-verified**: needs a real two-client session, one client with a low
  `max_receive_hz_per_player`, watching both ghosts on screen at visibly different smoothness.
  See `agent_docs/plans.md`'s "Send/receive rate control" section and the ADR in
  `agent_docs/architecture.md`.

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
