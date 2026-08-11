# Adapter template

**Not yet frozen.** This becomes the reusable adapter stub at the end of Phase 5, once the
core has been proven to run against a fake adapter (one that moves a ghost in a circle) with
no real game attached.

Until then this folder is empty on purpose — freezing a template before Phase 5 has actually
extracted the core would be documenting a guess, which is exactly what
`agent_docs/verified.md`'s human-gate rule exists to prevent for runtime facts, and the same
reasoning applies here: don't write down "the template" until there's a proven one to write
down.

When frozen, this folder should contain:

- The three-function stub (`get_local_state`, `render_remote`, `despawn_remote`) implementing
  nothing but the tick model described in `agent_docs/contract.md`.
- The fake circle-motion adapter used to prove the core has no game-specific leaks. As of
  2026-08-11 the concrete target for it exists: `core.Adapter` in `internal/core/core.go` —
  a Go interface scoped specifically to this in-process test adapter (real adapters like the
  Emerald one speak `internal/bridge`'s wire messages instead, they don't implement this
  interface). Phase 5's job is to write a type satisfying `core.Adapter` and confirm the core
  runs against it with no game attached and no import of anything under `adapters/`.
- A short README explaining how to start a new game adapter from this stub.
