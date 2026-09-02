# Phase 5 — Extract the template

> **A dated record. Package paths here predate the 2026-08-17 module move** — read any
> `internal/X` as `X/`. Why, and what became of `internal/README.md`: [../README.md](../README.md).

**Status: complete** (2026-08-11). Per `agent_docs/README.md`'s convention: a phase earns a
file when it's live, folded back into `agent_docs/plans.md` once done. Kept here for the
task-by-task record.

## Purpose

Prove the core has no game-specific leaks by running it against a fake adapter — one that
moves a ghost in a circle, with no game attached — then freeze `adapters/_template/` as the
reusable starting point for Phase 6 (TEVI). This is the real deliverable of the phase; the
fake adapter itself is only the proof mechanism.

## What was missing going in

`internal/core/core.go` already declared the `core.Adapter` Go interface (added ahead of
schedule, during the Phase 3/4 networking work) but nothing drove it — `Core` only had
`ServeBridge`, which speaks the bridge wire protocol over a real socket. There was no
in-process path at all.

## Tasks

- [x] Add `Core.RunAdapter(adapter Adapter, tickInterval time.Duration, stop <-chan struct{})`
      — an in-process drive loop calling `GetLocalState`/`RenderRemote`/`DespawnRemote`
      directly as Go method calls, no bridge socket. Implemented by extracting the tick-model
      diff logic (`tickRenders`) and relay-forwarding logic (`forwardLocalState`) out of the
      existing bridge-only `onAdapterFrame` so both the wire path and the in-process path share
      one implementation of the diff — not two copies that could drift.
- [x] Add `TestRunAdapterInProcess` (`internal/core/core_test.go`) — two `Core`s, each driven
      by an in-process `core.Adapter` fake, exchanging state over a real `relay.Server`. Passes.
- [x] Write `cmd/meshghost-fakeadapter/main.go` — a runnable, headless program: connects to a
      real relay, then calls `RunAdapter` against a `circleAdapter` (local state is a pure
      function of wall-clock time — no game, no bridge, no import of anything under
      `adapters/`). Prints `render_remote`/`despawn_remote` as they arrive, throttled to
      `-log-every` (default 500ms per remote) so the console is actually watchable — the core's
      own drive loop still ticks at the full `-tick` rate (default ~60fps) underneath;
      only the demo's logging is throttled.
- [x] `run-fakeadapter1.bat` / `run-fakeadapter2.bat` — added alongside the project's existing
      `run-*.bat` convention (root-level launchers next to root-level built `.exe`s, not a
      `bin/` subfolder). Later moved into `dev-scripts/` alongside every other dev-testing
      launcher (2026-08-11, ahead of publishing the repo publicly — see
      `dev-scripts/README.md`); still reference the same root-level built `.exe`s, just via
      `..\`.
- [x] Run two instances against a real relay, confirm on screen: continuously changing
      positions tracing a circle (correct radius held steady, angle advancing sample to
      sample), not frozen, not garbage. User watched both console windows directly and
      confirmed. See `agent_docs/verified.md`'s Phase 5 entry.
- [x] Freeze `adapters/_template/`: `README.md` (how to start a new game's adapter, pointing at
      `contract.md`, `PROTOCOL.md`, and the Emerald adapter as a worked reference) and
      `PROTOCOL.md` (the three-function contract and tick loop, written language-agnostically
      since Phase 6's target, TEVI, is Unity/C# — a Lua-specific stub would not have
      transferred).

## Notes

- The fake adapter deliberately does **not** live under `adapters/` — the whole point of the
  proof is that the core doesn't need anything from that directory to run. It lives under
  `cmd/` instead, alongside the other Go entry points.
- `core.Adapter` (the Go interface) and the bridge wire protocol are two different things that
  happen to share the same three-function shape. Real adapters, including the next one
  (TEVI), speak the wire protocol; only this project's own Go tests and the fake adapter use
  the in-process interface. `adapters/_template/README.md` calls this distinction out
  explicitly since it's easy to conflate.

## Links

- `agent_docs/contract.md` — the adapter interface and tick model this phase's stub restates.
- `agent_docs/plans.md` — roadmap. Phase 6 (TEVI) followed this one, using the frozen template; `agent_docs/status.md` has the current phase.
- `agent_docs/verified.md` — the human-observed confirmation for this phase.
- `adapters/_template/` — this phase's actual deliverable.
