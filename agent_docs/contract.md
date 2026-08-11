# The contract

This is the durable artifact of the project. Everything else — phases, adapters, the relay
implementation — is disposable and gets rewritten. This file is not. If a change here breaks
an adapter, that is a contract revision with an ADR in `architecture.md`, not a quiet edit.

Source of the design: `agent_docs/brief.md`. This file is the brief's contract section made
precise enough to implement, plus the gaps closed during the pre-code audit (2026-08-11).

## Terms

- `core` — the game-agnostic client logic: snapshot buffering, interpolation, remote-player
  tracking. Talks to the relay over the network and to the adapter over the bridge.
- `adapter` — the game-specific boundary layer. Reads local game state, draws remote ghosts.
  Never speaks the relay protocol, never opens a socket to anything but the bridge.
- `relay` — the network component that forwards snapshots between clients in a room.
- `bridge` — the local, localhost-only channel between an adapter and the core. See below.
- `packet schema` / `snapshot` — a single sample of state: position, area, anim tag, metadata.
- `area_id` — opaque string for the current game area or scene. Core compares by equality only.
- `anim` — opaque string animation/state tag. Core compares by equality only. Tags are only
  ever meaningful between two clients running the same game.
- `extras` — free-form dict for game-specific data that doesn't fit the core schema.
- `game_id` — opaque string identifying which game/adapter a client is running. See below.
- `phase` — a discrete milestone in `plans.md`.
- `loopback` — a test mode where a client sends data through the transport and gets it back.

## Two protocols

The old draft conflated these, which is what made "adapters never touch a socket" look
broken. There are two separate channels, and the invariant applies to only one of them.

- **Relay protocol** — client (core) ↔ relay, over the real network. This is what the packet
  schema and message types below describe.
- **Adapter bridge** — adapter ↔ local core process, localhost only. Framed JSON lines, same
  as the relay protocol's wire format for simplicity, but a different, private channel.

**Invariant (restated precisely):** an adapter may hold a socket to its own local core
process and nothing else. It never learns a relay address, never speaks the relay protocol
directly, and never sends bytes to anything off-machine. The core is the only thing that
touches the relay. A future in-process adapter (e.g. a C# host embedding the core as a
library) replaces the bridge socket with direct function calls — same invariant, no socket
needed at all.

## Packet schema (the `state` message payload)

Unchanged from the brief, restated exactly:

| Field | Notes |
|---|---|
| `player_id` | assigned by the relay at `hello` |
| `seq` | monotonic, per-client, for ordering |
| `timestamp` | numeric, for interpolation. Milliseconds, consistent per client. |
| `area_id` | opaque string. Map bank for Emerald, scene name for TEVI/Unity. |
| `position` | variable-length float array. 2 for Emerald, 3 for 3D games. |
| `orientation` | optional. Facing direction, angle, or quaternion. Opaque to the core. |
| `anim` | opaque string tag. |
| `extras` | small free-form dict for game-specific data. |

```json
{
  "player_id": "p1",
  "seq": 123,
  "timestamp": 1690000000000,
  "area_id": "emerald-0001",
  "position": [123.0, 45.0],
  "orientation": null,
  "anim": "walking",
  "extras": { "facing": "left" }
}
```

Rules, unchanged from the brief:

- The core compares `area_id` and `anim` for equality only. It never branches on contents.
- Do not fix `position` at 2 or 3 components.
- Do not invent a universal `anim` vocabulary. Each adapter defines its own tag set.
- JSON until it hurts. Debuggability beats bandwidth at this project's scale.
- Unknown fields in a received message are ignored, not rejected — forward compatibility for
  a contract that will be revised after the first two games.

## Message types

The brief only specified `state`. A relay needs more than that to assign identity and
signal joins/leaves — `despawn_remote(id)` has nothing to trigger it without a `leave`.

| Message | Direction | Carries |
|---|---|---|
| `hello` | client → relay | protocol version, `game_id`, room name, display name, `features` |
| `welcome` | relay → client | assigned `player_id`, current room roster |
| `join` | relay → client | a peer's `player_id` (and initial `state`, if available) |
| `leave` | relay → client | a peer's `player_id` — this is what drives `despawn_remote` |
| `state` | both directions | the packet schema above |
| `event` | both directions | **reserved, not implemented.** See Extensibility below. |
| `ping` / `pong` | both directions | liveness check; RTT feeds the interpolation delay |

### `features`

New field on `hello`, added 2026-08-11, not yet consumed by anything. An array of opaque
capability strings a client advertises (e.g. `["battle.v1"]`). A relay or peer that doesn't
recognize a capability simply ignores it — this is the one piece of the contract that cannot
be added after clients exist in the wild: a client built before `features` existed has no way
to say what it supports, so the first feature addition would silently break every already-
deployed client. Reserving the field now costs nothing; it is not populated with real values
until something actually needs one.

### `game_id`

New field, not in the original brief. The brief states `anim` tags are "only ever compared
between two clients running the same game" but nothing enforced that two different games
couldn't end up in the same room. `game_id` is sent once, at `hello` (e.g. `"emerald"`,
`"tevi"`). The relay rejects a `hello` whose `game_id` doesn't match the room's existing
`game_id`, rather than silently mixing clients that would draw garbage at each other.

## Extensibility — the event plane (reserved, not implemented)

MeshGhost's default is, and stays, a visual-only mod: cosmetic position/area/anim, no shared
world state, no game writes. But nothing about the architecture should trap a specific game's
adapter from going deeper later — trading or battling in Emerald, say — if that's ever
wanted. This section reserves the extension point; it does not build the extension.

**Two planes, kept structurally separate:**

- **State plane** (exists today, `state` messages) — lossy, latest-wins, ~10Hz, cosmetic,
  interpolated by the core. This plane does not grow new fields for deeper features; it stays
  exactly what it is now.
- **Event plane** (reserved, `event` messages, not yet implemented) — reliable, ordered,
  addressed. Its payload is **fully opaque to the core and relay**, exactly like `area_id` and
  `anim` are opaque today — they route it by `to`, they never parse its contents. The same
  rule that keeps the core game-agnostic for cosmetic fields is what would keep it
  game-agnostic for a battle protocol: an Emerald-specific event schema would live entirely
  inside the Emerald adapter, never in `internal/core` or `internal/relay`.

**Envelope addition (reserved):** a `to` field — a `player_id`, or absent for room broadcast.
Not implemented at the relay yet; see the Phase 3 note below.

**Scope limit:** the event plane is for *bounded, consensual* interactions between two
specific players — a trade offer, a battle turn — not a path to continuous authoritative
sync. It carries the same shape either way, so this has to be stated rather than inferred:
see the depth ladder in `agent_docs/plans.md` for why "everything in the game synced" is a
different, per-game project that could reuse the relay/transport but not `internal/core`,
rather than something this event plane grows into.

**Why this is documented now and built later, specifically:** building `event` routing before
any adapter sends an event would add code with no consumer — nothing to watch happening on
screen, which is exactly what this project's verification standard exists to prevent. The
`features` field is the one piece that must be reserved now, because it can't be added
retroactively once clients exist. The rest is easy to add on top of the relay's existing
forward path once there's an actual feature that needs it.

**Phase 3 guidance:** when the relay's message-forwarding path is built, shape it to take a
recipient set from the start (even though that set is always "everyone in the room" until the
event plane is implemented) rather than hardcoding room-wide broadcast. This is a shape
decision, not a feature — it costs nothing today and avoids a rewrite of the forwarding path
later.

**What would gate ever actually building this:** see the memory-write non-goal in
`agent_docs/plans.md` and the new ADR in `agent_docs/architecture.md`. Anything past Tier 2 on
the depth ladder there requires writing game memory, which is a deliberate, per-game, opt-in
departure from the current read-only default — not something this reservation authorizes on
its own.

## Transport (relay protocol wire format)

The brief's `send(bytes)` / `on_receive(cb)` names the shape but not enough to implement:
TCP is a byte stream, not a message stream, so something has to say where one JSON payload
ends and the next begins.

- **Framing:** newline-delimited JSON (NDJSON) over TCP. One JSON object per line. Chosen
  over length-prefixing because it stays greppable and typeable over `netcat` while
  debugging — the same "debuggability beats bandwidth" reasoning the brief already applies
  to choosing JSON over binary.
- **Transport interface, expanded:**
  - `send(bytes)` — unchanged from the brief.
  - `on_receive(callback)` — unchanged from the brief.
  - `on_connect()`, `on_disconnect(reason)`, `on_error(err)` — the brief's version had no
    way to report a dropped or failed connection.
  - Reconnect with exponential backoff on unexpected disconnect.
  - Heartbeat: a `ping` on an interval; a peer that misses N consecutive `pong`s is treated
    as dropped and triggers `leave`.
- **Versioning:** `hello` carries a protocol version. A relay that sees a mismatched major
  version refuses the connection outright rather than guessing at compatibility.

## The tick model

This is the part the three-function contract left unstated, and it's the part that would
have caused a flickering ghost in Phase 2 and an argument in Phase 5 if left unresolved.

- **The adapter always drives.** It calls into the core once per frame — never the reverse.
  This is true whether the core is out-of-process (BizHawk Lua, driven by
  `emu.frameadvance()`) or in-process (a future host). One calling direction for every
  adapter means Phase 5's fake-adapter test isn't discovering an asymmetry for the first
  time; there isn't one.
- **`render_remote(id, state)` is an upsert into a set the adapter owns, not a draw call.**
  BizHawk's `gui.*` overlay is cleared every frame. If `render_remote` drew once per network
  update (10Hz) while the emulator redraws at 60fps, the ghost would flicker 5 frames out of
  6. Instead: the adapter keeps a live map of `id -> state` for every known remote; every
  frame, regardless of whether new network data arrived, it redraws the whole map.
  `render_remote` updates an entry; `despawn_remote` removes one.
- **The core interpolates and pushes at frame rate, not the adapter.** With an out-of-process
  core, it's tempting to have the adapter interpolate between the last two snapshots it
  received. Don't — that duplicates the one genuinely hard, genuinely reusable piece of this
  project into every single adapter, which is exactly the leak the whole core/adapter split
  exists to prevent. The core ticks its interpolation on its own clock and pushes
  already-interpolated `render_remote` calls to the adapter every frame; the adapter's job is
  purely "hold the latest state per id, draw all of them." This is chatty over the bridge,
  but the bridge is localhost — that cost is free.

## Adapter interface

Unchanged surface from the brief, now with tick semantics attached:

```text
get_local_state()          -> snapshot | nil     # sampled once per adapter frame tick
render_remote(id, state)   -> void                # upsert into the adapter's remote-ghost set
despawn_remote(id)         -> void                # remove from that set
```

`get_local_state()` returning `nil` means "don't send this frame" (e.g. player is in a menu
or non-renderable state — see Open questions).

## Hard rules (unchanged from the brief, still binding)

- Adapters never speak the relay protocol or open a socket to anything but the bridge.
- The core never touches game memory or a rendering primitive.
- `if game == "emerald"` anywhere in the core means the abstraction has leaked.
- Coordinate systems (Y-up vs Z-up, tile vs world units, pixel origins) are normalized
  **inside the adapter**, never in the core.
- Transport is swappable behind `send(bytes)` / `on_receive(cb)` from day one.
- JSON until it hurts.

## Limits (defined now, enforced starting Phase 3)

Untrusted peers are on the wire the moment Phase 4 happens, so these are specified at the
same time as the schema rather than bolted on later:

- Max line length per NDJSON message.
- Max serialized size of `extras`.
- Max length of `position`.
- Per-client rate limit (messages/second) at the relay.
- Max clients per room.
- Remote strings (`area_id`, `anim`, `extras` values, display name) are never interpolated
  into a file path, shell command, or format string by an adapter. They are opaque data,
  not code, even though they're only ever compared by equality within the same game.
- Max event payload size (reserved, applies once the event plane is implemented).
- An unknown message `type` is ignored, not treated as an error — same forward-compatibility
  posture as the existing unknown-*field* rule above.

## Open questions carried from the original Phase 0 backlog

Not yet closed — genuinely open until Phase 1/2 answers them against a running game, per the
verification standard in `CLAUDE.md`. Do not answer these from memory.

- [ ] Exact Emerald `area_id` encoding: map bank + map number, concatenated how?
- [ ] First Emerald `anim` tag set: `idle`, `walking`, `running` — is that sufficient for a
      visible Phase 2 ghost, or is facing needed as its own tag?
- [ ] Is `orientation` used for Emerald, or is facing carried in `extras` instead?
- [ ] Local snapshot frequency: the brief's "10Hz sync looks fine" is a hypothesis for
      tile-grid movement, not yet confirmed against a running emulator.
- [ ] `seq`/`timestamp` semantics: does `seq` reset on reconnect? Is `timestamp` wall-clock
      or client-relative?
- [ ] What does `get_local_state()` return when the player is in a menu, cutscene, or other
      non-renderable state — `nil`, or a state with a sentinel `anim`?

## Links

- `agent_docs/brief.md` — the original design brief this contract implements.
- `agent_docs/architecture.md` — system shape and the ADRs that produced the decisions above.
- `agent_docs/plans.md` — phase roadmap that consumes this contract.
- `agent_docs/verified.md` — where the open questions above get closed, with evidence.
