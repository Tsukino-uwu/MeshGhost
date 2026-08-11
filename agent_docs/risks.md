# Risks and assumptions

## Current assumptions

- The core/adapter/relay split, with an out-of-process Go core, is the right long-term
  architecture (see `agent_docs/architecture.md` ADR on the Go decision).
- A replayable JSON snapshot schema is sufficient for the first two target games.
- Pokémon Emerald can expose local player position, area, and basic animation state from
  BizHawk — not yet confirmed, Phase 1's actual purpose.
- Lua overlay rendering (`gui.drawImage`) is the fastest practical approach for Emerald ghost
  drawing, and won't visibly flicker once the tick model in `contract.md` is implemented
  correctly (redraw the whole remote-ghost set every frame, not on receipt).
- TEVI's engine tooling (BepInEx/Harmony) will apply the way it does for other Unity
  games — **unconfirmed**, and TEVI's IL2CPP-vs-Mono status specifically is unknown. Do not
  assume either from memory or by analogy to the brief's Ori reasoning; verify at Phase 6.

## Known risks

- Changing the adapter contract after Phase 5 may create compatibility issues across
  already-built adapters.
- The TEVI and Pseudoregalia targets may require substantially different adapter behavior
  than Emerald — the brief's own estimate is 60–70% new work for the second game, ~50% for
  the third.
- BizHawk Lua's socket support may be slower or more limited than expected for real-time
  ghost rendering once the adapter is calling out to an out-of-process Go core every frame
  (see the tick model in `contract.md` — chatty by design, cost unverified at 60fps).
- Relying on a single emulator version or toolchain may create setup drift between sessions.
- Undocumented game state or menu/camera edge cases can break ghost placement or crash the
  adapter's assumptions about `get_local_state()`'s return shape.
- **Licensing exposure**: `pokeemerald` carries no LICENSE file (see `agent_docs/licensing.md`)
  and SilklessCoop is restrictively licensed. Both are permitted as read-only fact sources,
  never as copied code — the risk is a future session forgetting that distinction under time
  pressure.
- **macOS distribution friction**: an unsigned Go binary will trip Gatekeeper on first run.
  Not a blocker for early phases, but worth planning for before a public release.
- **No-auth relay window**: Phases 3–4 run without authentication (see the relay-auth ADR).
  Anyone with the address can join during that window. Acceptable for a friend-shared
  IP:port, not for anything posted publicly, until room codes ship.
- **Archipelago coexistence, unconfirmed**: the Archipelago Emerald randomizer runs its own
  BizHawk Lua connector (`connector_bizhawk_generic.lua`) against a ROM it has already
  patched. A MeshGhost Emerald adapter would be a second Lua script in the same Lua Console.
  Two read-only scripts shouldn't conflict, but three things are unverified: whether BizHawk
  can run two scripts concurrently at all, whether Archipelago's ROM patch shifts the RAM
  addresses MeshGhost reads, and whether running both costs noticeable performance. Test
  plan is in `agent_docs/phases/phase1.md`. This is also the concrete argument for keeping
  the read-only default (see the depth ladder in `plans.md`): two readers never race, but a
  future memory-*writing* feature could race Archipelago's own writes.
- **Reserved-but-unbuilt contract fields going stale**: the `features` field and the `event`
  message type (`agent_docs/contract.md`, Extensibility section) are documented now and
  implemented never, until something needs them. The risk is a future session building
  routing for them speculatively, before any adapter actually sends an event — that produces
  code with no on-screen consumer, which this project's own verification standard treats as
  unproven. The mitigation is procedural: don't implement the event plane until a specific
  Tier 3 feature (see `plans.md`) is approved via its own ADR and has a concrete adapter
  ready to use it.

## Mitigations

- Keep the contract minimal, and validate it early with a fake adapter (Phase 5).
- Record confirmed facts in `agent_docs/verified.md` and treat everything else as
  provisional — including this file.
- Keep transport abstract and swap-friendly so the relay layer can evolve past no-auth
  without touching the core or any adapter.
- Use phase-based validation to catch contract or rendering issues early rather than after
  a second game is underway.
- Track toolchain versions in `agent_docs/environment.md` as soon as Phase 1 starts.
- Re-check a project's license (`agent_docs/licensing.md`) before treating it as anything
  more than a documentation reference.
