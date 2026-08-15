# Adapter template

**First written 2026-08-11**, at the end of Phase 5, and kept current since with what the three
shipped adapters learned the hard way (last swept 2026-08-15). The core was proven to run against a fake
adapter (`cmd/meshghost-fakeadapter`, a ghost that walks in a circle, driven by
`core.RunAdapter` — see [agent_docs/verified.md](../../agent_docs/verified.md)'s Phase 5 entry)
with no game attached and no import of anything under `adapters/`. This folder is what that
phase promised to leave behind: a reusable starting point for the next game's adapter, not code
to run as-is.

## What's here

- [PROTOCOL.md](PROTOCOL.md) — the three-function contract (`get_local_state` /
  `render_remote` / `despawn_remote`) and the tick model, written language-agnostically
  (pseudocode, wire envelope examples), because the next game (TEVI, Phase 6) is Unity/C#, not
  BizHawk Lua — a Lua-specific stub would not transfer. Every real adapter, in any language,
  implements this same shape by speaking the bridge wire protocol (`internal/bridge/bridge.go`);
  nothing here is Go-specific.
- The `core.Adapter` Go interface (`internal/core/core.go`) is a *different* thing: an
  in-process shortcut used only by `cmd/meshghost-fakeadapter` and Go tests
  (`internal/core/core_test.go`'s `TestRunAdapterInProcess`) to drive the core without a socket
  at all. A real adapter — including TEVI's — never implements it; it dials the bridge and
  speaks NDJSON, exactly like `adapters/pokemon/emerald/phase4_multiplayer.lua` does. See
  [PROTOCOL.md](PROTOCOL.md) for why this distinction matters and where to look for a worked
  example of each.

## Folder convention

One folder per game, named after the game itself (`emerald`, `tevi`, `pseudoregalia`). Games
in the same franchise are grouped under a shared subfolder — `adapters/pokemon/emerald/`, and
a future `adapters/pokemon/platinum/` would go alongside it — purely for browsability as more
games get added; it's not a code-sharing boundary. A hypothetical Platinum adapter (NDS, a
different console/engine than Emerald's GBA) would share essentially no code with Emerald's,
same as any two unrelated games — grouping by franchise just keeps the top level of
`adapters/` from getting crowded by one series' many entries.

## Starting a new game's adapter

1. Read [agent_docs/contract.md](../../agent_docs/contract.md) in full — the packet schema,
   message types, adapter interface, and tick model are the parts that don't change per game.
2. Read [PROTOCOL.md](PROTOCOL.md) in this folder for the wire-level shape (connect,
   per-frame send/receive, redraw-every-frame) independent of any particular language.
3. For a worked, complete reference of a real adapter speaking this protocol end-to-end
   (connection retry, the hello handshake, NDJSON framing, the remote-ghost set, the tick
   loop), read `adapters/pokemon/emerald/meshghost_emerald.lua`. Its game-reading parts are
   Emerald-specific and won't transfer; its bridge-connection, hello, and tick-loop shape will.
4. Figure out, for the new game: what counts as `area_id` (a scene/level identifier), what
   `position` looks like (2D or 3D — the schema doesn't fix this), what `anim` tags are
   meaningful, and whether `get_local_state()` should ever return "don't send this frame" (a
   menu, loading screen, or similar).
5. Read [agent_docs/pitfalls.md](../../agent_docs/pitfalls.md) — at minimum its "Diagnostic
   methodology" section (one diagnostic at a time, never log the value you just wrote, run the
   test without the fix, two identical failures means stop guessing). It's the most transferable
   content in the repo, and the rest of the file is the log of what the three existing adapters
   got wrong so you don't have to.
6. Follow this project's verification standard ([CLAUDE.md](../../CLAUDE.md)): no address,
   hook, or API call from memory — everything traceable to a source, and nothing in
   [agent_docs/verified.md](../../agent_docs/verified.md) until it's been watched happening on
   screen.
7. Do not modify `internal/core` or `internal/relay` for game-specific reasons. If something
   about the new game seems to require that, stop — it means either the contract needs a real,
   ADR'd revision (rare), or the adapter is trying to do something the boundary doesn't allow
   (much more likely).
8. When the adapter is actually ready to ship, add it to the release: give it its own step in
   `.github/workflows/release.yml`'s assemble job, under `games/<publisher>/<game>/` — nothing
   under `adapters/` is picked up automatically. See
   [packaging/README.md](../../packaging/README.md)'s "Adding a game to the release" for the
   pattern (and its TEVI section if the adapter needs a build step, not just a file copy,
   before it's shippable). A *compiled* adapter is four things, not one: a
   `dev-scripts/build-<game>.bat` that stages its output into `packaging/release/games/...` and
   writes a `built-from.txt` SHA-256 record, the build output committed to the repo (CI can't
   build these), its own staleness-verification step in `release.yml`, and a hand-written
   `README.txt` for the game folder that nothing generates.

## Testing it

The local rig already exists — read [dev-scripts/README.md](../../dev-scripts/README.md) before
inventing your own. Three things about it are worth knowing up front, because each was learned
the expensive way:

- **Give each game a `run-core-<game>.bat`, and test with `-interp=0ms -min-send=10ms`.** The
  core's default 200ms interpolation buffer smooths over real local timing bugs — treat "looks
  fine with the buffer on" as untested, not confirmed. (If you also start a relay locally, it
  needs `-send-hz=100` or it silently overrides every core's fast `-min-send`.)
- **Solo-test through `run-relay-loopback.bat`**, which echoes your own state back as
  `<id>-ghost`, and give loopback ghosts a **render-only** offset so you can tell the ghost from
  your own character — all three adapters do this (Emerald 1-2 tiles, TEVI 160 units,
  Pseudoregalia 150). Offset for judging render quality, zero for verifying exact tracking;
  either way it never touches what goes on the wire.
- **Loopback cannot exercise cross-area filtering, join/leave, or despawn** — it always echoes
  your own area back. Those bugs only appear with two real instances, which is why the bridge
  port has to be per-instance overridable (see [PROTOCOL.md](PROTOCOL.md)). `run-fakeadapter1/2`
  exercise core+relay with no game attached at all.

Two habits from the existing adapters worth copying:

- **Diagnostics are named constant flags, default off, left in the tree with what they found
  written in the comment** (Emerald's `DIAG_STEP_CURVE`, TEVI's `DIAG_REDRAW_TRACE`,
  Pseudoregalia's `ANIM_PULSE_TRACE`). Throttle or edge-trigger every one of them — a per-frame
  log produced 7324 lines in a single TEVI session.
- **Hash-diff the file actually deployed into the game directory against your repo copy before
  believing any live test.** Every adapter here is a build artifact copied somewhere, and a
  stale copy has invalidated whole test sessions twice.

## Writing the new adapter's own README

Give the game's folder a `README.md` with a **"How this adapter was built"** numbered list — the
short, readable version of the story, one step per thing that happened, ~2-4 lines each, in plain
language. See `adapters/pseudoregalia/README.md` for the worked example. Keep the detail
(field names, dump sizes, failed attempts, dated evidence) in `agent_docs/phases/phaseN.md`,
`verified.md`, and `pitfalls.md`, and link to them — a step that has grown into paragraphs of
caveats belongs there with a one-line pointer left behind. See [CLAUDE.md](../../CLAUDE.md)'s
hard rule on this.

## Hard rules, restated (unchanged from [agent_docs/contract.md](../../agent_docs/contract.md))

- The adapter may hold a socket to its own local core process (the bridge) and nothing else —
  never a relay address, never the relay protocol, never bytes off-machine directly.
- `area_id` and `anim` are opaque outside the adapter that produced them — compare by equality
  only, never build a cross-game vocabulary.
- Coordinate systems (Y-up vs Z-up, tile vs world units, pixel origins) are normalized inside
  the adapter, never in the core.
