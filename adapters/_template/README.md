# Adapter template

**Frozen 2026-08-11**, at the end of Phase 5. The core was proven to run against a fake
adapter (`cmd/meshghost-fakeadapter`, a ghost that walks in a circle, driven by
`core.RunAdapter` — see `agent_docs/verified.md`'s Phase 5 entry) with no game attached and no
import of anything under `adapters/`. This folder is what that phase promised to leave behind:
a reusable starting point for the next game's adapter, not code to run as-is.

## What's here

- `PROTOCOL.md` — the three-function contract (`get_local_state` / `render_remote` /
  `despawn_remote`) and the tick model, written language-agnostically (pseudocode, wire
  envelope examples), because the next game (TEVI, Phase 6) is Unity/C#, not BizHawk Lua —
  a Lua-specific stub would not transfer. Every real adapter, in any language, implements this
  same shape by speaking the bridge wire protocol (`internal/bridge/bridge.go`); nothing here
  is Go-specific.
- The `core.Adapter` Go interface (`internal/core/core.go`) is a *different* thing: an
  in-process shortcut used only by `cmd/meshghost-fakeadapter` and Go tests
  (`internal/core/core_test.go`'s `TestRunAdapterInProcess`) to drive the core without a socket
  at all. A real adapter — including TEVI's — never implements it; it dials the bridge and
  speaks NDJSON, exactly like `adapters/emerald/phase4_multiplayer.lua` does. See
  `PROTOCOL.md` for why this distinction matters and where to look for a worked example of each.

## Starting a new game's adapter

1. Read `agent_docs/contract.md` in full — the packet schema, message types, adapter
   interface, and tick model are the parts that don't change per game.
2. Read `PROTOCOL.md` in this folder for the wire-level shape (connect, per-frame send/receive,
   redraw-every-frame) independent of any particular language.
3. For a worked, complete reference of a real adapter speaking this protocol end-to-end
   (connection retry, NDJSON framing, the remote-ghost set, the tick loop), read
   `adapters/emerald/phase4_multiplayer.lua`. Its game-reading parts (`getLocalState`,
   `playerScreenPos`) are Emerald-specific and won't transfer; its bridge-connection and
   tick-loop shape will.
4. Figure out, for the new game: what counts as `area_id` (a scene/level identifier), what
   `position` looks like (2D or 3D — the schema doesn't fix this), what `anim` tags are
   meaningful, and whether `get_local_state()` should ever return "don't send this frame" (a
   menu, loading screen, or similar).
5. Follow this project's verification standard (`CLAUDE.md`): no address, hook, or API call
   from memory — everything traceable to a source, and nothing in `agent_docs/verified.md`
   until it's been watched happening on screen.
6. Do not modify `internal/core` or `internal/relay` for game-specific reasons. If something
   about the new game seems to require that, stop — it means either the contract needs a real,
   ADR'd revision (rare), or the adapter is trying to do something the boundary doesn't allow
   (much more likely).

## Hard rules, restated (unchanged from `agent_docs/contract.md`)

- The adapter may hold a socket to its own local core process (the bridge) and nothing else —
  never a relay address, never the relay protocol, never bytes off-machine directly.
- `area_id` and `anim` are opaque outside the adapter that produced them — compare by equality
  only, never build a cross-game vocabulary.
- Coordinate systems (Y-up vs Z-up, tile vs world units, pixel origins) are normalized inside
  the adapter, never in the core.
