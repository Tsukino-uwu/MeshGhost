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
touches the relay. **An adapter also has no say in *how* the core reaches the relay** — not the
address, not the transport, not the rate. Added 2026-08-16 with selectable transports: the rules
above forbade an adapter from *doing* relay things but not from *influencing* them, so a
`preferred_transport` field in the bridge `hello` would have violated nothing written here while
being exactly the wrong shape. A game that suits one transport better is expressed as shipped
configuration, never through the bridge. A future in-process adapter (e.g. a C# host embedding the core as a
library) replaces the bridge socket with direct function calls — same invariant, no socket
needed at all.

**Bridge lifecycle is tied to the relay connection:** if the bridge connection ends (the
adapter/game closes, or its socket otherwise drops), the core closes its relay connection too,
which the relay reports to the rest of the room as a real `leave` — see the 2026-08-13 ADR in
`architecture.md`. A later bridge `hello` on that same core process reconnects to the relay and
is assigned a new `player_id`; there is no session resumption under the old identity.

## Packet schema (the `state` message payload)

Unchanged from the brief, restated exactly:

| Field | Notes |
|---|---|
| `player_id` | assigned by the relay at `hello` |
| `seq` | monotonic, per-client, for ordering |
| `timestamp` | numeric, for interpolation. Milliseconds, wall-clock (`time.Now().UnixMilli()` on whichever side stamps it). **Peers' wall clocks must actually agree, not just be internally consistent** — `internal/core/interp.go`'s `remoteBuffer.at()` compares a *local* wall-clock render time directly against a *remote's* wall-clock timestamps. Meaningful clock skew between peers silently falls back to an edge snapshot every tick (interpolation stops, no error anywhere) rather than failing loudly. |
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
  "area_id": "0:9",
  "position": [123.0, 45.0],
  "orientation": "west",
  "anim": "walking",
  "extras": {}
}
```

Rules, unchanged from the brief:

- The core compares `area_id` and `anim` for equality only. It never branches on contents.
  Since 2026-08-13, the core also *uses* that equality check to filter rendering: a remote
  whose `area_id` doesn't match the local player's own most recently known `area_id` is not
  rendered (and despawns if it was previously visible), unless the local player's own area is
  still unknown, in which case nothing is filtered. See the ADR in `architecture.md`.
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
| `hello` | client → relay | protocol version, `game_id`, room name, display name, `room_code`, `game_version`, `features`, `max_receive_hz_per_player` |
| `welcome` | relay → client | assigned `player_id`, current room roster, room send rate (`send_hz`) |
| `reject` | relay → client | a reason string — sent immediately before the relay closes a connection, either refusing a `hello` at handshake or, since the send/receive rate-control feature (see the ADR in `architecture.md`), closing an already-joined connection for exceeding the per-client message cap |
| `join` | relay → client | a peer's `player_id`. The schema reserves an optional initial `state`, but no relay populates it today — every `Join` the relay sends has `State == nil`, so treat it as absent. |
| `leave` | relay → client | a peer's `player_id` — this is what drives `despawn_remote` |
| `state` | both directions | the packet schema above |
| `event` | both directions | **reserved, not implemented.** See Extensibility below. |
| `ping` / `pong` | client → relay / relay → client | keeps an otherwise-quiet connection from going idle. Each carries a `nonce` (uint64). Despite the pair being symmetric on paper, the implementation is one-directional per type: the core sends `ping`, the relay answers `pong`, and the core ignores an inbound `ping`. See below |

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

A relay may additionally be configured (`server.only_game`, off by default — see the ADR in
`architecture.md`) to accept just one `game_id` server-wide, independent of any room. That
refusal carries its own reason, `ReasonGameNotAllowed`, distinct from the per-room
`ReasonGameMismatch`: a client refused for it cannot fix the problem by picking another room.
Adding a reason string is not a contract revision — the reason field is plain text and the
constants are a convenience for Go call sites, not a closed enum (see the message table above
and the forward-compatibility rule).

### `game_version` and `room_code`

Added 2026-08-14 for relay-safety hardening — see the ADR in `architecture.md`. Both optional,
both opaque to the core and relay (never parsed, compared only where noted below).

- `game_version` is the adapter's own version string, forwarded verbatim from the adapter's
  bridge `hello` (see "Connecting: the bridge `hello`" below). A room's `game_version`, once set
  by its first member, is sticky the same way `game_id` is — a later `hello` with a *different*,
  non-empty `game_version` for that room is refused. A client that omits it (or a room where no
  member has declared one yet) is never refused on this basis; only a real mismatch between two
  declared values counts. None of the three shipped adapters read a game build number for this
  — there's no cited memory address for one, and `CLAUDE.md`'s "no addresses/APIs from memory"
  rule means one isn't guessed at. Each adapter instead reports its own script/mod version,
  which is the more useful signal anyway: it catches two peers running different revisions of
  the same adapter, the likelier real source of a silent protocol mismatch.
- `room_code` is a shared secret the relay compares (`crypto/subtle.ConstantTimeCompare`)
  against its own configured code before accepting a join. An empty configured code (the
  default) means auth is off — the original friend-hosted posture. **Crosses the wire in
  plaintext** — `internal/transport` has no TLS — so this raises the bar from "anyone with the
  address" to "anyone with the address and the code," not to "safe against a network-level
  attacker." See `internal/README.md`.

Both are refused with `reject` (see the message table above) before any `state` is exchanged,
the same "reject at handshake" shape the protocol-version check already used — researched
against CelesteNet's own version-check pattern (`internal/README.md`'s prior-art section) before
building this.

### `send_hz` and `max_receive_hz_per_player`

Added for the send/receive rate-control feature — see the ADR in `architecture.md`. Both
integer Hz (updates per second), both optional, both degrade to today's pre-existing behavior
in either direction against an older peer.

- `send_hz` (on `welcome`) is the room-wide state send rate the relay is configured for. A
  client adopts it as its own actual send rate **unless** it has deliberately configured a
  slower rate of its own (`internal/core.Core.MinSendInterval`) — the effective rate is always
  the **slower** of the two, so a peer on a poor connection can decline to go faster than it
  wants, but the relay can never speed a client up past a rate it explicitly chose. Zero on the
  wire (only possible from an older relay that predates this field) means "nothing advertised";
  a client reading that falls back to `Core.DefaultMinSendInterval`. Prescriptive, not
  enforced: nothing makes a client actually honor `send_hz` — the only hard limit is the
  per-client flood cap below, which scales from it.
- `max_receive_hz_per_player` (on `hello`) is the highest rate, **per other player**, at which
  a client wants the relay to forward that player's state to it. Zero or absent means uncapped
  (the pre-existing behavior, and what an older client sends). Enforced **at the relay**, which
  drops the excess before it goes out on the wire — discarding on receive would save the
  client's downlink nothing, which is the entire point. Per-recipient, not per-sender: two
  different recipients can receive the same sender's state at two different effective rates
  simultaneously, decided entirely by each recipient's own requested cap — harmless, since a
  ghost is a purely cosmetic overlay with no shared state that needs to agree across clients.
  Excess samples are **dropped, never coalesced or queued** — consistent with the state plane
  already being lossy/latest-wins (see the Extensibility section below); a lower effective rate
  costs ghost smoothness, never added latency or memory. `join`/`leave`/`welcome`/`reject`/
  `ping`/`pong` are never subject to this cap — only `state` is throttled, since a throttled
  `leave` would strand a permanently frozen ghost on the capped recipient's screen.

Both values are bounded to **10–100** (`protocol.MinSendHz`/`MaxSendHz`) when set to something
other than their own "unspecified"/"uncapped" sentinel; see the Limits section below for the
exact clamping table.

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
- **Selectable transport** (added 2026-08-16 — ADR in `architecture.md`): the relay connection
  runs over `tcp` (default), `udp`, or `quic`, chosen by `"transport"` in `config.json` on each
  end. The relay may serve several at once, and **one room may hold clients on different
  transports simultaneously** — the relay forwards through the `Transport` interface and never
  learns which is which. None of this reaches an adapter: the bridge is always loopback TCP
  NDJSON.
  - **Framing is identical on all three: one datagram carries exactly one NDJSON line.** The
    consequence worth knowing is that `send` must emit payload and its newline in a *single*
    write — two writes are two datagrams and split every line in half.
  - **Datagram size:** `internal/netx/udpconn.MaxDatagramBytes` (1200) bounds one message on
    `udp`, below `MaxLineBytes` (4096). A message over that is refused, not fragmented, because
    a fragmented datagram is lost whole when any one fragment is lost. Large `extras` therefore
    means `tcp`.
  - **`udp` cannot be encrypted.** Go's standard library has no DTLS, so `room_code` crosses
    that transport in the clear with no fix available. `quic` is the encrypted option — its
    handshake is TLS 1.3.
  - **Ports:** `tcp` and `udp` share `listen_on` (independent port spaces); `quic` needs its own
    `listen_quic`, because it is itself carried over UDP.
  - **The handshake is always tcp, and is not configurable.** `transport` is not *how* a client
    connects but what it moves to *once* connected: `tcp` stays put, `udp` (the shipped client
    default) and `quic` upgrade if offered, `auto` takes the best available. **tcp is mandatory
    on the relay too** — `netx.ParseKinds` adds it whether or not the operator names it, because
    a relay without tcp is unreachable by every client. Note the shipped *relay* default is
    tcp-only, so an out-of-the-box pair has the client ask for udp and degrade back to tcp with a
    log line.
  - **Discovery:** a client may send `hello`
    with `query_only: true`; the relay replies `transports` (kind + **port only**, never a host —
    the client already knows one, and a relay bound to `0.0.0.0` does not) and closes, **without
    joining a room, assigning a `player_id`, or announcing anything**. The query passes every
    check a real join does *first*, room code included, so it discloses nothing to anyone who
    could not simply have joined — that is what keeps the relay free of any pre-auth endpoint.
    Preference order is `quic`, `tcp`, `udp`; **`auto` never picks `udp` unless nothing else is
    offered**, since it cannot be encrypted. Any failure falls back to `tcp` at the configured
    address, so discovery can only improve a connection, never prevent one.
- **Transport interface, expanded:**
  - `send(bytes)` — unchanged from the brief. **Reliable on every transport**, so a caller that
    knows nothing about `send_unreliable` below is always correct.
  - `send_unreliable(bytes)` — added 2026-08-16, for the `state` plane and nothing else. Delivery
    is not guaranteed: on `udp` the datagram is sent once, on `quic` it rides a QUIC datagram, and
    on `tcp` it is exactly `send`. Correct precisely because this document already defines the
    state plane as lossy and latest-wins — a retransmitted position would arrive stale and out of
    order, which is worse than the gap it fills. Everything carrying lifecycle meaning
    (`hello`, `welcome`, `join`, `leave`, `reject`, `ping`, `pong`) stays on `send`; a dropped
    `leave` would strand a ghost on screen forever.
  - `on_receive(callback)` — unchanged from the brief.
  - `on_disconnect(reason)`, `on_error(err)` — the brief's version had no way to report a
    dropped or failed connection. (`on_connect()` was in this list too until a review pass
    removed it 2026-08-14: `internal/transport`'s implementation started its read loop before
    a caller could register the callback, so it fired from a goroutine racing that
    registration — unusable as specified, and nothing in the codebase ever registered one.)
  - Reconnect with exponential backoff on unexpected disconnect.
  - Heartbeat: `internal/core.Core.sendHeartbeats` sends a `ping` every
    `DefaultHeartbeatInterval` (20s) on an otherwise-quiet connection; the relay replies with
    `pong`, but nothing currently reads it back — this is not liveness detection. Added
    2026-08-14 for a narrower reason: a core with no adapter attached (or one reporting no
    local state) sent nothing at all, which `transport.DefaultIdleTimeout` (60s) closed as
    idle, and the existing auto-reconnect handed out a fresh `player_id` every cycle — every
    other peer saw a leave+join/despawn-respawn once a minute. The `ping` just keeps the
    connection non-idle. Actual drop detection is still entirely
    `transport.DefaultIdleTimeout` closing the socket, same as before this existed. See
    `agent_docs/verified.md`'s "Core-relay heartbeat, found live and fixed" entry and the ADR
    in `architecture.md`.
- **Versioning:** `hello` carries a protocol version. A relay that sees a mismatched major
  version refuses the connection outright rather than guessing at compatibility.
- **Bounded reads and timeouts** (added 2026-08-14, relay-safety hardening — ADR in
  `architecture.md`): `internal/transport.NDJSONConn` enforces `MaxLineBytes` *during* the read
  itself (a `bufio.Scanner` max-token-size, not a length check after the line is already fully
  buffered — the earlier `bufio.Reader.ReadBytes` approach let a peer streaming bytes with no
  newline grow memory without bound before any check could run), plus a per-line idle read
  deadline and a per-`Send` write deadline. The relay additionally closes any connection that
  hasn't completed a `hello` and joined a room within `HelloTimeout` (10s by default) — the idle
  deadline alone doesn't cover this, since it resets on any successfully read line, not only a
  completed `hello`.

## The tick model

This is the part the three-function contract left unstated, and it's the part that would
have caused a flickering ghost in Phase 2 and an argument in Phase 5 if left unresolved.

- **The adapter always drives.** It calls into the core once per frame — never the reverse.
  This is true whether the core is out-of-process (BizHawk Lua, driven by
  `emu.frameadvance()`) or in-process (a future host). One calling direction for every
  adapter means Phase 5's fake-adapter test isn't discovering an asymmetry for the first
  time; there isn't one.
- **`render_remote(id, state)` is an upsert into a set the adapter owns, not a draw call.**
  If `render_remote` drew once per network update (10Hz) while the emulator redraws at 60fps,
  the ghost would flicker 5 frames out of 6. Instead: the adapter keeps a live map of
  `id -> state` for every known remote; every frame, regardless of whether new network data
  arrived, it redraws the whole map. `render_remote` updates an entry; `despawn_remote` removes
  one. **Correction (Phase 3, 2026-08-11):** this section originally claimed "BizHawk's `gui.*`
  overlay is cleared every frame" as the reason redrawing-every-frame avoids flicker. That's
  wrong — confirmed live, and against BizHawk's own `gui.d.lua` doc for `gui.clearGraphics`
  ("clears all lua drawn graphics from the screen", which would be meaningless if the overlay
  already auto-cleared): drawn images persist across frames until something clears or
  overwrites them. A ghost that stops being redrawn (e.g. all remotes despawned, or the bridge
  connection dies) doesn't disappear — it freezes in its last position forever. The adapter
  must call `gui.clearGraphics()` itself, every frame, unconditionally (not gated behind "is
  there anything to draw"), before redrawing the current remote set — matching real precedent
  in BizHawk's own bundled scripts (`Gargoyles.lua`, `Earthworm Jim 2.lua`,
  `Super Mario World.lua`) that manage moving overlays. The redraw-every-frame requirement
  itself was already correct; only the stated reason, and the missing clear step, were wrong.
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

## Connecting: the bridge `hello`

Added 2026-08-12 (ADR in `architecture.md`), a fourth bridge message alongside the three
above. The very first message an adapter sends on a fresh bridge connection, before any
`local_state`:

```json
{"type":"hello","payload":{"game_id":"emerald","game_version":"phase5.5"}}
```

`game_id` is opaque to the core — the same equality-only rule as `area_id`/`anim` — and is
forwarded verbatim into the relay's own `hello.game_id` (the packet-schema table above). This
is what lets the core defer connecting to the relay until an adapter actually shows up and
says which game it is, instead of requiring the user to also type `"game"` into a config file
(`internal/core.Core.ConnectRelayOnAdapterHello`). A caller that already knows the game
upfront (dev/testing scripts with no adapter attached, e.g. `dev-scripts/run-core-emerald.bat`'s
`-game` flag) can still connect immediately at startup instead — both paths are supported,
and are mutually exclusive per process: once a Core is connected to the relay for one
`game_id`, a bridge `hello` for a *different* `game_id` on the same process is refused.

`game_version`, added 2026-08-14 alongside room-code auth, is optional and forwarded the same
way into the relay's own `hello.game_version` (see the "`game_version` and `room_code`"
subsection above). `Core.GameVersion` overrides whatever the adapter reports here — mirroring
how `-game`/`config.json`'s `"game"` already overrides an adapter-declared `game_id` — for
callers with no real adapter attached (dev-scripts, `cmd/meshghost-fakeadapter`).

Ordering guarantee: within one bridge connection, `hello` is always processed before any
`local_state` sent after it — a bridge connection is a single ordered stream, per the "Two
protocols" section above. `local_state` sent before any `hello` (or when the process was
started with an explicit game already) is accepted but not forwarded to the relay until a
relay connection actually exists.

## Hard rules (unchanged from the brief, still binding)

- Adapters never speak the relay protocol or open a socket to anything but the bridge, and have
  no say in how the core reaches the relay (address, transport, or rate).
- The core never touches game memory or a rendering primitive.
- `if game == "emerald"` anywhere in the core means the abstraction has leaked.
- Coordinate systems (Y-up vs Z-up, tile vs world units, pixel origins) are normalized
  **inside the adapter**, never in the core.
- Transport is swappable behind `send(bytes)` / `on_receive(cb)` from day one.
- JSON until it hurts.

## Limits (defined at Phase 3, tightened 2026-08-14 for relay-safety hardening)

Untrusted peers are on the wire the moment Phase 4 happens, so these are specified at the
same time as the schema rather than bolted on later. Values chosen and enforced at the relay
(`internal/relay/limits.go`), and — as of the relay-safety hardening pass — mirrored on
receive by `internal/core` too (`internal/protocol/limits.go` holds the shared ones, so the
two enforcement points can't silently drift apart). Originally generous rather than tight,
since the relay was no-auth through Phase 4; audited with an adversarial peer in mind
alongside room-code auth (see the architecture.md ADR) — treat the numbers below as tight now:

- Max line length per NDJSON message: **4096 bytes** (`MaxLineBytes`). Enforced *during* the
  read itself since 2026-08-14 (`internal/transport`'s bounded-read fix, see "Transport"
  above) — no longer just a check after the line is already fully buffered.
- Max serialized size of `extras`: **1024 bytes** (`MaxExtrasBytes`).
- Max length of `position`: **8** (`MaxPositionLen`) — headroom above the largest known real
  use (3, for a 3D game); the schema still never fixes this at 2 or 3.
- Each `position` component must be finite and within **±1e7** (`MaxPositionComponent`,
  `protocol.IsValidPosition`) — NaN/±Infinity/absurd magnitudes are rejected, dropping the
  whole `state` message rather than clamping it. Enforced at both the relay (`relay.go`) and
  the core on receive (`core.go`), added in the 2026-08-14 relay-safety hardening pass.
- Max serialized size of `orientation`: **256 bytes** (`MaxOrientationBytes`) — generous above
  any real representation (a handful of floats).
- Max length of `area_id` / `anim`: **256 bytes** each (`MaxAreaIDLen` / `MaxAnimLen`).
- Max length of every `hello` string field (`game_id`, `room`, `display_name`, `room_code`,
  `game_version`): **128 bytes** (`MaxHelloFieldLen`), checked at the relay before any of them
  are used to create or look up a room.
- Per-client rate limit: **`max(120, send_hz × 6)` messages/second** (`maxMessagesPerSecond`,
  `internal/relay/limits.go`) — the relay closes, rather than throttles, a connection that
  exceeds it, sending a `reject` (`ReasonRateLimited`) first since the send/receive rate-control
  feature (see the ADR in `architecture.md`). At the default `send_hz` (20), this computes to
  exactly the historical flat **120** — unchanged for an unconfigured relay. The cap **only ever
  scales up**, never down: a relay turned *down* to a slower room rate must not start
  disconnecting older clients still sending at their own built-in 20Hz default.
  **Client-side enforced since Phase 6** (TEVI): `internal/core.Core.MinSendInterval` (left at
  zero by `core.New()` since the rate-control ADR, so the relay's advertised rate wins by
  default; `DefaultMinSendInterval`, 50ms / 20Hz, is the last-resort fallback when neither a
  local preference nor a relay advertisement exists) caps how often `forwardLocalState` actually sends to the
  relay, independent of how often the adapter calls in — since the rate-control feature, the
  actual cap is `effectiveSendInterval()`, the slower of this and the relay's advertised
  `send_hz` (see the subsection above). Found live: a Unity adapter's `Update()` runs uncapped
  well above 120Hz, so the original "up to ~60Hz, one per adapter frame" assumption was already
  wrong for a frame-driven game with no engine-level cap, and the connection was closed by the
  relay after about two minutes of real play (see `agent_docs/verified.md`'s Phase 6.4/6.5 entry
  and the ADR in `architecture.md`). The brief's 10Hz hypothesis is still not what's enforced by
  default — 20Hz was chosen for headroom under the relay's cap, not as a claim that 20Hz is the
  "right" sync rate.
- `send_hz` / `max_receive_hz_per_player` clamping (`protocol.ClampSendHz` /
  `protocol.ClampReceiveHz`): absent, zero, or negative resolves to the field's own "unspecified"
  default (`protocol.DefaultSendHz` for `send_hz`; uncapped for `max_receive_hz_per_player`); a
  positive value below **10** or above **100** is clamped to the nearest bound rather than
  refused — a typo in a cosmetic tuning knob must not stop a relay from starting or a client
  from connecting.
- Max clients: **8 by default** (`DefaultMaxClients`), configurable per relay
  (`Server.MaxClients`, `-max-clients`, `config.json`'s `server.max_clients`) — enforced
  server-wide, across every room the relay is hosting combined, not per room. A relay already
  at capacity refuses an additional join the same way a `game_id` mismatch is refused.
- Hello timeout: an unauthenticated connection that hasn't completed a `hello` and joined a
  room within **10 seconds** (`DefaultHelloTimeout`, `Server.HelloTimeout`) is closed. See
  "Transport" above for why the idle read deadline alone doesn't cover this case.
- The relay stamps `player_id` on every `state` message from the connection's own
  relay-assigned id, server-side — never trusted from the client's payload, since a peer could
  otherwise claim someone else's id. `internal/core` mirrors this trust boundary on receive:
  it keeps its own roster (seeded from `welcome`, maintained by `join`/`leave`) and drops any
  `state` for a `player_id` it never actually saw announced, rather than trusting the relay
  completely — a hostile or compromised relay was previously able to inject state for an
  arbitrary id with nothing to stop it.
- Remote strings (`area_id`, `anim`, `extras` values, display name) are never interpolated
  into a file path, shell command, or format string by an adapter. They are opaque data,
  not code, even though they're only ever compared by equality within the same game.
- Max event payload size (reserved, applies once the event plane is implemented).
- An unknown message `type` is ignored, not treated as an error — same forward-compatibility
  posture as the existing unknown-*field* rule above.

## Open questions carried from the original Phase 0 backlog

Not yet closed — genuinely open until Phase 1/2 answers them against a running game, per the
verification standard in `CLAUDE.md`. Do not answer these from memory.

- [x] Exact Emerald `area_id` encoding: map bank + map number, concatenated how? **Decided:**
      `"{mapGroup}:{mapNum}"`, e.g. `"0:9"`, `"1:4"` — plain decimal pair joined by `:`.
      `mapGroup`/`mapNum` alone are sufficient: confirmed stable within a map and confirmed
      changing correctly on every real map transition tested. See `agent_docs/verified.md`
      (`gSaveBlock1Ptr`/map-transition entries).
- [x] First Emerald `anim` tag set: `idle`, `walking`, `running` — is that sufficient for a
      visible Phase 2 ghost, or is facing needed as its own tag? **Decided:** those three are
      sufficient, carried by `runningState`/`dash`: `runningState=0` → `idle`,
      `runningState=2 & !dash` → `walking`, `runningState=2 & dash` → `running`.
      `runningState=1` (turning) does not need its own tag — it's a facing change with no
      position change, already carried by `orientation`. See `agent_docs/verified.md`
      (`gPlayerAvatar`/dash entries).
- [x] Is `orientation` used for Emerald, or is facing carried in `extras` instead? **Decided:**
      `orientation` carries facing direction as `"south"`/`"north"`/`"west"`/`"east"` (matching
      `pokeemerald`'s own `DIR_*` naming for direct traceability), read from
      `gObjectEvents[gPlayerAvatar.objectEventId].facingDirection`. See `agent_docs/
      verified.md` (`gObjectEvents`/facing-direction entry).
- [x] Local snapshot frequency: **answered, not by confirming the brief's 10Hz hypothesis, but
      by superseding it.** The real enforced rate is `Core.DefaultMinSendInterval` = 50ms / 20Hz,
      live-confirmed across all three shipped games (Emerald, TEVI, Pseudoregalia) — see the
      "Limits" section above. 20Hz was chosen for headroom under the relay's 120 msg/sec cap
      (found live: TEVI's frame-driven `Update()` runs uncapped well above 120Hz with no
      engine-level throttle), not as a claim that 20Hz is the objectively "right" sync rate for
      tile-grid movement. Still 20Hz by default; now operator-configurable per relay
      (`server.send_hz`, 10–100) as of the send/receive rate-control feature — see the subsection
      above and the ADR in `architecture.md`.
- [x] `seq`/`timestamp` semantics: does `seq` reset on reconnect? Is `timestamp` wall-clock
      or client-relative? **Decided (already true of the implementation, not a new choice):**
      `seq` is a `Core`-lifetime counter (`atomic.AddUint64(&c.seq, 1)`) that never resets —
      a reconnect gets a fresh `player_id` anyway per the 2026-08-13 ADR, so this was never
      actually ambiguous. `timestamp` is unambiguously wall-clock
      (`time.Now().UnixMilli()`), not client-relative — see the packet-schema table above for
      why that matters more than it sounds.
- [x] What does `get_local_state()` return when the player is in a menu, cutscene, or other
      non-renderable state — `nil`, or a state with a sentinel `anim`? **Decided:** position
      stayed valid through every pause menu, dialogue, forced-movement cutscene, warp, and
      battle tested — none of those warrant `nil`. `nil` is only warranted when
      `gSaveBlock1Ptr` reads as null (title screen / no save loaded yet). Separately, the
      adapter should debounce one frame around any `mapGroup`/`mapNum` change: a transient
      placeholder read was observed exactly at the moment the save block's pointer relocates
      during some (not all) transitions — see `agent_docs/verified.md`'s "placeholder-glitch"
      entries. This is an adapter-side guard, not a reason to return `nil` from the core's
      perspective.

## Links

- `agent_docs/brief.md` — the original design brief this contract implements.
- `agent_docs/architecture.md` — system shape and the ADRs that produced the decisions above.
- `agent_docs/plans.md` — phase roadmap that consumes this contract.
- `agent_docs/verified.md` — where the open questions above get closed, with evidence.
