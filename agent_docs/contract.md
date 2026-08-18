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

**An adapter MAY start its own local core process** (added 2026-08-16, with autostart — see the
ADR in `architecture.md`). That is a lifecycle act, not a protocol one, and everything above still
holds: the spawned core is given a working directory and finds its own `config.json` there, so the
adapter passes no relay address, no transport, and no rate, exactly as if a human had launched it
in that folder. The only arguments an adapter may pass are ones that are already its own business
— its bridge port, and a pid for the core to exit with. **Passing `-relay` (or any other relay
setting) is forbidden and would break this invariant**, which is why the mechanism is a working
directory rather than a command line. An adapter must also only ever stop a core it started
itself; a core it merely found belongs to whoever started it.

**A core serves exactly one adapter at a time** (added 2026-08-16 with the port walk). A second
bridge connection is answered with `reject` and closed. This was always the intent — everything
below says "the bridge connection" in the singular — but nothing enforced it, and the gap was not
theoretical: two adapters running the *same* `game_id` both got an accepted `hello` and then shared
one relay session, fighting over one `player_id`, one `seq`, one send-rate budget and one
`area_id`, with both sides logging a normal connect. Two copies of one game on one machine is a
normal thing to do — it is how most adapters here were tested — so the rule is now explicit and
enforced rather than assumed.

**A `hello` is always answered**, with exactly one of:

| Message | Meaning |
|---|---|
| `bridge_ready` | accepted; this core is yours |
| `reject` (with a `reason`) | not available — the core closes immediately after |

The acknowledgement exists because silence used to be ambiguous. A core only ever sent
`render_remote`/`despawn_remote`, and only once a peer existed, so an adapter could not distinguish
"accepted" from "still starting" from "wrong program on this port" — it could only infer success
from the absence of a hangup. That was affordable when there was one fixed port and unaffordable
once adapters started walking a range looking for a free core. `reason` is for the adapter's log,
not for branching on: the correct response to any rejection is the same, which is to try the next
port. **An adapter that receives neither must move on to the next port**, not assume acceptance.
Silence looks identical to an unrelated program holding a port in the range, and committing to one
strands the adapter with no ghosts and no explanation. Skipping a core that is merely old costs
nothing by comparison: the adapter starts its own on a free port and everything works. This was
briefly the other way round, and a test that squats a port with a listener that never speaks
(`internal/e2e`'s `TestPortWalkFindsAFreeCore`) showed the trade was backwards.

**Bridge lifecycle is tied to the relay connection:** if the bridge connection ends (the
adapter/game closes, or its socket otherwise drops), the core closes its relay connection too,
which the relay reports to the rest of the room as a real `leave` — see the 2026-08-13 ADR in
`architecture.md`. A later bridge `hello` on that same core process reconnects to the relay and
is assigned a new `player_id`: the core deliberately discards its `resume_token` when the
adapter goes away, so an adapter-driven disconnect is always a real leave. Session resumption
(see `resume_token` below) exists for the opposite case — the relay connection dropping
underneath a game that is still running.

## Packet schema (the `state` message payload)

Unchanged from the brief, restated exactly:

| Field | Notes |
|---|---|
| `player_id` | assigned by the relay at `hello` |
| `seq` | monotonic, per-client, for ordering |
| `timestamp` | numeric, for interpolation. Milliseconds, wall-clock (`time.Now().UnixMilli()` on whichever side stamps it). **Peers' wall clocks must actually agree, not just be internally consistent** — `core/interp.go`'s `remoteBuffer.at()` compares a *local* wall-clock render time directly against a *remote's* wall-clock timestamps. Meaningful clock skew between peers silently falls back to an edge snapshot every tick (interpolation stops, no error anywhere) rather than failing loudly. **A room that negotiates `clock.v1` closes that gap**: every member stamps in the *relay's* clock domain instead of its own, and renders against the same shifted clock, so nobody has to be correct about the real time — they only have to agree. Off by default, so an unnegotiated room is byte-for-byte the original behaviour. See Transport below. |
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
| `hello` | client → relay | protocol version, `game_id`, room name, display name, `room_code`, `game_version`, `features`, `resume_token`, `max_receive_hz_per_player`, `query_only` |
| `welcome` | relay → client | assigned `player_id`, current room roster, room send rate (`send_hz`), the room's agreed `features`, the relay's clock (`server_time_ms`), and — for a `resume.v1` room — a single-use `resume_token` and a `resumed` flag |
| `transports` | relay → client | the transports this relay actually serves, as `kind` + `port` pairs (never a host). The reply to a `hello` carrying `query_only: true` — sent *instead of* `welcome`, with no room joined and no `player_id` assigned, and the relay closes immediately after. See Transport below |
| `reject` | relay → client | a reason string — sent immediately before the relay closes a connection, either refusing a `hello` at handshake or, since the send/receive rate-control feature (see the ADR in `architecture.md`), closing an already-joined connection for exceeding the per-client message cap |
| `join` | relay → client | a peer's `player_id`, plus an optional initial `state`. Populated **only** for a room that negotiated `snapshot.v1`, where a joining client is sent one `join` per existing member carrying that member's most recent sample; otherwise still absent, as it was from 2026-08-11 to 2026-08-17. |
| `leave` | **both directions** | relay → client: a peer's `player_id` — this is what drives `despawn_remote`. client → relay (since 2026-08-17): a voluntary goodbye, payload ignored — see `resume_token` |
| `state` | both directions | the packet schema above |
| `event` | both directions | an opaque payload, a `to` addressee (or absent for room broadcast), a relay-stamped `from`, a room-wide `seq`, and an optional `corr_id`. **Implemented 2026-08-17**; requires `event.v1`. See Extensibility below |
| `lease` / `lease_state` | client → relay / relay → client | exclusive hold of an opaque key: `claim`/`renew`/`release`, answered with the current holder and expiry. Requires `lease.v1` |
| `escrow` / `escrow_state` | client → relay / relay → client | two-sided atomic exchange: `open`/`deposit`/`commit`/`abort`, answered with the phase and — only once committed — both opaque blobs. Requires `escrow.v1` |
| `world` / `world_state` | client → relay / relay → client | custody of a world the relay holds but cannot read: `set`/`drop` against an opaque entity key under a named authority lease, answered with the change, the whole world on adoption or join, or a refusal. Requires `world.v1` **and** `lease.v1`. See Extensibility below |
| `ping` / `pong` | client → relay / relay → client | keeps an otherwise-quiet connection from going idle, and carries clock sync. Each carries a `nonce` (uint64); `pong` also carries `server_time_ms`. Despite the pair being symmetric on paper, the implementation is one-directional per type: the core sends `ping`, the relay answers `pong`, and the core ignores an inbound `ping`. See below |

### `features`

Added to `hello` 2026-08-11 and reserved unused until 2026-08-17, when everything past the
cosmetic state plane was built on top of it. An array of opaque capability strings a client
advertises. This is the one piece of the contract that could not have been added after clients
existed in the wild: a client built before `features` existed has no way to say what it
supports, so the first feature addition would have silently broken every already-deployed
client.

The defined capabilities, each of which switches on one thing the relay would otherwise never
do (`protocol/online.go`):

| Capability | Turns on |
|---|---|
| `event.v1` | addressed event routing |
| `lease.v1` | exclusive hold of opaque keys |
| `escrow.v1` | two-sided atomic exchange |
| `world.v1` | the relay holds custody of a world and hands it to the next authority holder (requires `lease.v1`) |
| `snapshot.v1` | seeding a joining client via `join.state` |
| `resume.v1` | session resumption after an unexpected drop |
| `clock.v1` | timestamps stamped in the relay's clock domain |

**Capabilities are either room-scoped or client-scoped, and only the first kind is sticky.**
Added 2026-08-17, shortly after the capabilities themselves, because making everything sticky was
wrong in a way that only showed up when trying to actually use one:

| Scope | Capabilities | Compared between members? |
|---|---|---|
| **Room-scoped** | `event.v1`, `lease.v1`, `escrow.v1`, `world.v1`, `clock.v1` | **Yes — must match exactly** |
| **Client-scoped** | `resume.v1`, `snapshot.v1` | No — honoured per client |

A room-scoped capability describes something *shared*: `event`/`lease`/`escrow` are protocols
between peers, and `clock.v1` changes which clock `timestamp` is expressed in. A member that
disagrees fails silently, which is the hazard the sticky check exists for.

A client-scoped one describes something between **one client and the relay**, which no peer
participates in or can observe. `resume.v1` asks the relay to hold *this* client's identity;
`snapshot.v1` asks it to seed *this* client on join. Forcing those through the sticky check meant
enabling resumption cost a coordinated reconfiguration of every player in the room for a feature
none of them take part in — friction with no safety bought.

**An unrecognised capability name is treated as room-scoped**, which is the fail-safe direction: a
future shared capability wrongly treated as client-scoped would silently not be enforced, while
the opposite mistake merely asks for a config change that was not strictly necessary.
`welcome.features` reports what is actually in force **for that client** — the room's agreed set
plus its own honoured client-scoped ones — rather than a room-wide answer to a per-client
question.

Within the room-scoped half, the sticky rule is unchanged, and two things about it are worth
stating because both are easy to get backwards:

- **An empty room-scoped set is a real value that must still match.** Unlike `game_version`,
  where "not declared" means "don't check", a client advertising nothing may not join a room that
  negotiated leases. The hazard being closed is exactly that case: one client claiming
  properly while another simply acts means conflict resolution silently does not work, and
  everything looks fine until it doesn't.
- **Nothing is on by default.** Every shipped adapter advertises nothing and is therefore
  wire-compatible with any cosmetic room, which is what keeps this additive rather than a
  version bump. A capability is turned on by the user (`client.features` in `config.json`, or
  `-features`) or asked for by an adapter in its bridge `hello`; the core advertises the union.

The relay learns no more about `lease.v1` than it currently learns about the game version
`1.2.0` — it compares two normalized strings. See `agent_docs/beyond-cosmetic.md` for why
capability mismatch inside one room had to be closed rather than tolerated.

### `resume_token`

Added 2026-08-17 with session resumption. Issued in `welcome` for a `resume.v1` room, presented
in a later `hello` to reclaim the same `player_id` after an unexpected drop.

- **The relay holds a dropped identity for a grace window** (20s by default,
  `server.resume_grace_seconds`) rather than announcing a `leave`. Within it, the client's
  `player_id`, its leases and its in-flight exchanges are all still live, and **the rest of the
  room is never told anything happened at all** — no `leave`, no `join`. Past it, the drop
  becomes an ordinary leave: leases freed, live exchanges aborted, `leave` broadcast.
- **A deliberate quit is a `leave` sent client → relay**, which is why `leave` is the one message
  that travels both ways. The core sends an empty `protocol.Leave` before closing
  (`sendGoodbye`, synchronous so it cannot race its own hangup); the relay ignores the payload —
  `player_id` would be the client's own claim and the connection already knows whose it is — clears
  the resume token and takes the real-leave path instead of suspending. Without it a player who
  quit on purpose would freeze on everyone else's screen for the whole grace window.
- **A session may be taken over while the relay still believes it is live**, not only after a
  drop it has already noticed. The relay registers a session when it *issues* the token, not when
  the connection dies. This is not an edge case: on `quic` a hard-killed peer sends no close
  frame and the connection lingers until quic's idle timeout (measured 2026-08-17 at ~17s, against
  an immediate RST on `tcp`), so a client reconnecting inside that window would otherwise present
  a token matching nothing, be given a fresh `player_id`, and leave its old ghost standing.
  Only the holder of an unguessable token can do this, so a takeover is always the legitimate
  owner returning.
- **What resumption covers is narrower than it sounds, and the boundary is the token's lifetime.**
  It survives the *connection* dropping while the client process keeps running — a blip, a route
  change, a proxy restart. It does **not** survive the game or core process closing (the token is
  in memory, so a new process joins fresh, which is correct: a closed game should be a real
  leave), and it does **not** survive a relay restart (its sessions are in memory too). Nothing is
  written to disk anywhere, deliberately.
- **Single-use, and rotated on every `welcome`.** Treat it as a credential: anyone holding it
  can take over that session, including its outstanding exchanges. It is generated with
  `crypto/rand` (128 bits) rather than derived from `player_id`, which is a bare counter.
- **A token that is unknown, expired, or for another room is not an error.** The relay silently
  assigns a fresh identity instead, because being away slightly too long must cost a new
  `player_id`, never the ability to play.
- **In memory only.** This survives a network blip, not a relay restart — the relay persists
  nothing to disk, deliberately (see `beyond-cosmetic.md` §5).
- The core discards its token when **the adapter** disconnects, since a closed game is a real
  departure the room should see, not a blip to paper over.

### `game_id`

New field, not in the original brief. The brief states `anim` tags are "only ever compared
between two clients running the same game" but nothing enforced that two different games
couldn't end up in the same room. `game_id` is sent once, at `hello` (e.g. `"emerald"`,
`"tevi"`). **Rooms are keyed by `game_id` AND room name together** (2026-08-17), so two games
asking for the same room name get two separate rooms and never see each other — a game's rooms
come into existence on their own the first time someone from that game connects, with nothing to
configure.

Until then rooms were keyed by name alone and a mismatched `game_id` was refused with
`ReasonGameMismatch`. That was a bug rather than a policy: this package's own doc comment has
always said rooms are "partitioned by game_id", and since `room` ships defaulted to `"default"`
for every game, the first game onto a server took `"default"` and every other game was locked out
of its own default configuration — with a refusal that gave no hint the fix was to invent a room
name. `ReasonGameMismatch` is now unreachable from the room path and is kept only for the wire:
an older relay still sends it, so a client must still understand it.

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
  declared values counts. None of the four shipped adapters reads a game build number for this
  — there's no cited memory address for one, and `CLAUDE.md`'s "no addresses/APIs from memory"
  rule means one isn't guessed at. Each adapter instead reports its own script/mod version,
  which is the more useful signal anyway: it catches two peers running different revisions of
  the same adapter, the likelier real source of a silent protocol mismatch.
- `room_code` is a shared secret the relay compares (`crypto/subtle.ConstantTimeCompare`)
  against its own configured code before accepting a join. An empty configured code (the
  default) means auth is off — the original friend-hosted posture. **Crosses the wire in
  plaintext** — `transport` has no TLS — so this raises the bar from "anyone with the
  address" to "anyone with the address and the code," not to "safe against a network-level
  attacker." See `docs/security.md`.

Both are refused with `reject` (see the message table above) before any `state` is exchanged,
the same "reject at handshake" shape the protocol-version check already used — researched
against CelesteNet's own version-check pattern (`docs/security.md`'s prior-art section) before
building this.

### `send_hz` and `max_receive_hz_per_player`

Added for the send/receive rate-control feature — see the ADR in `architecture.md`. Both
integer Hz (updates per second), both optional, both degrade to today's pre-existing behavior
in either direction against an older peer.

- `send_hz` (on `welcome`) is the room-wide state send rate the relay is configured for. A
  client adopts it as its own actual send rate **unless** it has deliberately configured a
  slower rate of its own (`core.Core.MinSendInterval`) — the effective rate is always
  the **slower** of the two, so a peer on a poor connection can decline to go faster than it
  wants, but the relay can never speed a client up past a rate it explicitly chose. Zero on the
  wire (only possible from an older relay that predates this field) means "nothing advertised";
  a client reading that falls back to `core.DefaultMinSendInterval`. Prescriptive, not
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

## Extensibility — the event plane and the arbitration planes

MeshGhost's default is, and stays, cosmetic: position/area/anim, no shared
world state, no game writes. **Everything in this section is off unless a room's members all
ask for it**, and no shipped adapter does. It exists because the architecture must never *trap*
a specific game's adapter at cosmetic — reserved 2026-08-11, built 2026-08-17 (ADR in
`architecture.md`; concept layer in `beyond-cosmetic.md`).

**Two planes, kept structurally separate:**

- **State plane** (`state` messages) — lossy, latest-wins, ~20Hz, cosmetic, interpolated by the
  core. This plane does not grow new fields for deeper features; it stays exactly what it is
  now.
- **Event plane** (`event` messages) — reliable, ordered, addressed. Its payload is **fully
  opaque to the core and relay**, exactly like `area_id` and `anim`: they route it by `to`, they
  never parse its contents. The same rule that keeps the core game-agnostic for cosmetic fields
  is what keeps it game-agnostic for a battle protocol.

**`extras` is the tempting wrong answer for deeper data, and the reason is delivery semantics
rather than vagueness.** `extras` is a `state` field, so anything in it is lossy, latest-wins,
and re-sent ~20×/second. That is right for "what colour is this ghost's trail" and catastrophic
for "I offer you this item" — an offer sent 20 times a second on a plane that may silently drop
it is not an offer. Deeper data rides `event`, never `extras`.

### Addressing, ordering, and the sender's echo

`to` is a `player_id`, or absent for room broadcast. It is the only field of an event the relay
reads, which is the general rule: **a field earns top-level status only if game-agnostic code
must act on it.** Everything else belongs in the opaque payload, because a top-level field the
core does not read is a field the core can *start* reading.

Every room has a **sequencer**: a monotonic counter, assigned inside the same critical section
that snapshots the recipient set, and stamped on every `event`, `lease_state` and
`escrow_state`. Every member observes one identical total order. This is real server authority
in the practically useful sense and needs no game knowledge at all — **authority over *order* is
not authority over *meaning*.** "You were second" needs a counter; "that move was illegal" needs
to understand the game, and is not on offer.

**The sender always receives its own event back.** The stamp is the relay's, so an echo is the
only way a client can learn where its own action landed in the order; an adapter tells its own
echo apart by comparing `from` against its `player_id`. An event addressed to a `player_id` that
is not in the room reaches nobody but that echo, and no error is returned — the relay cannot
distinguish a typo from someone who left half a second ago.

**Delivery order matches stamp order.** The relay holds a per-room send lock across both halves;
without it two events can be stamped 1 and 2 and then race to the socket, which is precisely
what a sequencer exists to prevent. The state plane is deliberately excluded from that lock: it
is lossy by contract and does not need ordering.

### Leases — authority over an opaque key

`claim` / `renew` / `release` against an opaque key. The relay grants it to the first asker,
denies everyone else (privately, to the asker alone — broadcasting failures would turn a
contested key into a message storm), and tells the whole room every time a key changes hands.

**The relay never judges merit, only arrival.** It picks the first claim and that becomes the
fact by fiat; everyone agrees because everyone was told the same answer, not because the answer
was correct on the merits. Arbitrary-but-consistent is the whole trick, and judging *rightness*
is what would require understanding the game.

**Adapters must ask BEFORE acting, never announce after.** An adapter that acts locally and then
reports puts the relay's "no" *after* the fact is already on screen — a rollback problem, per
game and genuinely hard. The flow is claim → wait → act, so **every contested action costs a
network round trip before anything visible happens.** Invisible for a turn-based trade;
unacceptable for anything twitchy. That is the real boundary on how deep any of this can go, and
it lands independently on the same line the depth ladder already drew.

Every lease is **timed** (1s–5min, 30s default). Lifetime is the hard part, not the grant: a
holder that vanishes must not wedge a key forever, and only a clock can guarantee that without
game knowledge. A lease ends by `release`, by expiry, or by its holder disconnecting, and the
relay says which of the three happened rather than deciding what that should mean.

### Escrow — both or neither

`open` / `deposit` / `commit` / `abort` between exactly two members of a room.

**A lease grants exclusive *access*, never an atomic *swap*.** A trade is two-sided, and if one
side vanishes after handing over, an item is destroyed or duplicated — which is exactly where
historical Pokémon trading exploits came from. No amount of lease discipline prevents it, so
this is a separate mechanism rather than a use of that one.

- Blobs are opaque, and are **revealed only on `committed`** — never earlier, or the second
  depositor could choose what to offer after seeing what it was offered.
- An exchange completes only when **both** parties have deposited **and both** have committed.
  Both then receive the identical blob map, which is what makes it both-or-neither from each
  side's point of view. **An adapter applies the swap on `committed` and on no other phase.**
- Any abort, disconnect, or timeout (60s) aborts the whole thing and discards both blobs.
- A terminal record is **retained for 60s**, so a party that dropped in the instant between the
  relay committing and the message arriving can resume and be told the outcome. Without that,
  "both or neither" would hold only for as long as both sockets stayed up — the case that never
  fails in testing and always fails in the field. This is why resumption and escrow were built
  together.

### World custody — the relay holds the world, not the simulation

`set` / `drop` against an opaque entity key, under a named authority **lease key**. The relay keeps
the latest opaque blob per entity and hands the whole set to whoever takes that lease next, and to
whoever joins. Requires `lease.v1` in the same room; the two are deliberately not merged, and
neither implies the other, because implying one would change the sticky feature-set key and
silently stop matching rooms that already agreed on the old string.

**This answers "who is the host, and what happens when they leave?"** — which is three jobs, not
one. *Designation* (who is authoritative) was already `lease.v1`. *Custody* (holding the world so a
successor can adopt it) is this. *Simulation* (running the AI, resolving damage) stays on a client
and is excluded by architecture, because it is the only one that needs to understand the game.
Without custody a new host adopts from its own last-known view, every peer's view is slightly
different and slightly stale, and so *which* peer takes over changes what the world becomes.

- **Writes are lease-gated.** A write names an `authority` lease key and is accepted only from that
  lease's current holder — a pure string comparison, which is how the relay gates it while learning
  nothing. It prevents the specific failure custody exists to survive: a departing host's in-flight
  packets overwriting the new host's world after handover. A write from anyone else is answered
  with `denied`, naming the real holder, rather than dropped.
- **The adoption snapshot is part of the grant**, in the same total order — never dispatched after
  it. Otherwise a new holder could receive its grant, legally start writing, and *then* be handed a
  snapshot built before its own writes. A renew, and a re-claim by the current holder, produce no
  snapshot. **An empty world still produces one**, so a new host can tell "nothing to adopt" from
  "my adoption has not arrived yet" — a host that guesses wrong renumbers from a stale view and
  rolls the world back for everyone.
- **World lifetime is never tied to lease lifetime.** An expiry, a clean release and a holder
  disconnecting all leave the world untouched, waiting for the next claimant; only the room being
  dropped discards it. Freeing it with the lease would destroy the world in exactly the case the
  feature exists for.
- **The writer is excluded from its own broadcast**, unlike an event: the host is by definition the
  authoritative source, and it learns of failure by an explicit denial and of success by silence.
- **Delivery is chosen per write.** `reliable: false` for continuous motion that the next update
  supersedes, `true` for a change that must not be missed. The relay stores the latest either way,
  so a snapshot is always complete. **Reliable selects the delivery variant only, never the
  serialization**: every write is stamped and delivered under the same lock, so a lossy write may
  be lost and can never be reordered against another *by the relay*.
- **A write that creates a key must be reliable.** A lossy one on a key the relay does not hold is
  ignored. The lossy and reliable planes are independent on a datagram transport, so a create
  dispatched before a drop can arrive after it and resurrect an entity permanently.
- **A lossy write replaces the whole blob, so do not mix two kinds of state in one.** A blob
  carrying both a continuously-superseded field and one that must never regress can be dragged
  backwards wholesale by an inbound reorder, and nothing corrects it: the relay's copy becomes the
  stale one, so the next snapshot propagates the regression. Keep discrete state on its own key
  written reliably, and continuous position on another written lossily —
  `cmd/meshghost-fakeadapter/world.go` is the worked example.
- **A receiver applies world messages in `seq` order and ignores anything older than what it has
  already applied for a key.** The relay guarantees a total order, but reliable and lossy delivery
  to one peer are independent, so a lossy write can still land ahead of the reliable snapshot meant
  to seed it.
- **Never roster-filter a `world_state`.** A world entry legitimately outlives the player who wrote
  it, and `holder` may name someone who has already left.

Bounds are derived from the datagram limit rather than from `MaxLineBytes`, because
`udpconn.checkWritable` refuses an oversized datagram *including a reliable one* and reports it only
as a line in the relay's log: authority ≤ 128 (the lease-key bound, since it names one), key ≤ 64,
blob ≤ 768, ≤ 64 entities per room, and a batching budget of 1100 bytes per message. The 64 is
derived, not chosen: it is `udpconn`'s reorder window, and a reliable burst wider than that window
goes unacked and is retried until the connection closes. A snapshot too large for one message is
**batched, never fragmented** — every message is independently complete and no entry is ever split.

### What none of this buys

Stated because it is where an enthusiastic later session would overreach:

- **Not anti-cheat.** A lying client still lies; ordering never validates content. "The server
  disagrees that you did 9999 damage" is simulation authority, which is excluded by
  construction — catching a lie requires knowing what is true.
- **Not full sync.** Ordering is necessary, not sufficient: two clients applying the same
  ordered log to different local state still diverge. It *is* sufficient for bounded, consensual
  interactions between two specific players — a trade offer, a battle turn — which is the scope
  limit, not a stage on the way to continuous authoritative sync.
- **Not persistence.** The relay writes nothing to disk. Rooms, leases, exchanges, worlds and
  identities all die with the process, deliberately: a persistent relay needs storage, backups, migrations
  and corruption handling, and stops being a thing a user runs from a `.bat` file.

**What still gates going deeper:** anything past Tier 2 on `plans.md`'s depth ladder requires
writing game memory, which is a deliberate, per-game, opt-in departure from the read-only
default. Nothing here authorizes that; these are the transport-level primitives an adapter could
build on, not permission to build on them.

## Transport (relay protocol wire format)

The brief's `send(bytes)` / `on_receive(cb)` names the shape but not enough to implement:
TCP is a byte stream, not a message stream, so something has to say where one JSON payload
ends and the next begins.

- **Framing:** newline-delimited JSON (NDJSON) over TCP. One JSON object per line. Chosen
  over length-prefixing because it stays greppable and typeable over `netcat` while
  debugging — the same "debuggability beats bandwidth" reasoning the brief already applies
  to choosing JSON over binary.
- **Selectable transport** (added 2026-08-16 — ADR in `architecture.md`): the relay connection
  runs over `tcp`, `udp`, or `quic`, chosen by `"transport"` in `config.json` on each end.
  **Defaults changed the same day (second ADR)**: the client defaults to `auto` and the relay to
  serving `tcp,quic`, so a default session is quic — encrypted against a passive observer, and the
  only one of those two on which this document's lossy state plane is actually lossy (`udp` is
  too, for anyone who asks for it). quic shares the
  relay's `-addr` port number so hosting still means forwarding one number; only serving plain
  `udp` alongside it forces quic elsewhere. The relay may serve several at once, and **one room may hold clients on different
  transports simultaneously** — the relay forwards through the `Transport` interface and never
  learns which is which. None of this reaches an adapter: the bridge is always loopback TCP
  NDJSON.
  - **Framing is identical on all three: one datagram carries exactly one NDJSON line.** The
    consequence worth knowing is that `send` must emit payload and its newline in a *single*
    write — two writes are two datagrams and split every line in half.
  - **Datagram size:** `netx/udpconn.MaxDatagramBytes` (1200) bounds one message on
    `udp`, below `MaxLineBytes` (4096). A message over that is refused, not fragmented, because
    a fragmented datagram is lost whole when any one fragment is lost. Large `extras` therefore
    means `tcp`.
  - **`udp` cannot be encrypted.** Go's standard library has no DTLS, so `room_code` crosses
    that transport in the clear with no fix available. `quic` is the encrypted option — its
    handshake is TLS 1.3.
  - **Ports:** `tcp` and `udp` share `listen_on` (independent port spaces), and `quic` shares
    that port number too by default (`listen_quic: ""`). Because quic is itself carried over
    UDP, it collides with plain `udp` — serving both at once therefore requires naming a
    separate `listen_quic`, and the relay refuses to start otherwise.
  - **The handshake is always tcp, and is not configurable.** `transport` is not *how* a client
    connects but what it moves to *once* connected: `tcp` stays put, `udp` and `quic` upgrade if
    offered, and `auto` — the shipped client default — takes the best available. **tcp is
    mandatory on the relay too** — `netx.ParseKinds` adds it whether or not the operator names
    it, because a relay without tcp is unreachable by every client. The shipped relay default is
    `tcp,quic`, so an out-of-the-box pair lands on quic and falls back to tcp only if quic
    cannot be established.
  - **Discovery:** a client may send `hello`
    with `query_only: true`; the relay replies `transports` (kind + **port only**, never a host —
    the client already knows one, and a relay bound to `0.0.0.0` does not) and closes, **without
    joining a room, assigning a `player_id`, or announcing anything**. Every authentication check
    runs *first* — hello-field lengths, protocol version, and above all the room code — so it
    discloses nothing to anyone who could not simply have joined; only the checks that need the
    room table (`only_game`, `game_id`/`game_version` stickiness, the client cap) come after, and
    a query never reaches them. That is what keeps the relay free of any pre-auth endpoint.
    Preference order is `quic`, `tcp`, `udp`; **`auto` never picks `udp` unless nothing else is
    offered**, since it cannot be encrypted. Any failure falls back to `tcp` at the configured
    address, so discovery can only improve a connection, never prevent one.
- **Transport interface, expanded:**
  - `send(bytes)` — unchanged from the brief. **Reliable AND ordered on every transport**, so a
    caller that knows nothing about `send_unreliable` below is always correct. Ordering is stated
    explicitly because it is a separate property from delivery and is *not* implied by
    retransmission: `tcp` and `quic` get it from an ordered stream, while `udp` has to resequence
    for it. Until 2026-08-16 `udpconn` did not, and delivered a retransmitted payload after a later
    one that was never lost — which strands a ghost when a `leave` overtakes its own `join`. See
    the ADR in `architecture.md` and `verified.md`.
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
    removed it 2026-08-14: `transport`'s implementation started its read loop before
    a caller could register the callback, so it fired from a goroutine racing that
    registration — unusable as specified, and nothing in the codebase ever registered one.)
  - Reconnect with exponential backoff on unexpected disconnect.
  - Heartbeat and clock sync: `core.Core.sendHeartbeats` sends a short burst of
    `ping`s at connect and then one every `DefaultHeartbeatInterval` (20s) on an otherwise-quiet
    connection; the relay replies with `pong`, echoing the `nonce` and adding its own
    `server_time_ms`. Since 2026-08-17 the core *does* read that back: it records each ping's
    send time, and turns a reply into a round-trip time and a clock offset, keeping the sample
    with the **lowest** RTT rather than an average (a slow sample is slow because it was delayed
    asymmetrically, which is exactly what corrupts an offset estimate). The estimate is exposed
    as `Core.ClockOffsetMs`/`Core.RelayRTTMs`, and is *applied* to timestamps only in a room that
    negotiated `clock.v1`. The burst exists because a 20s heartbeat would take a minute to form
    an estimate — precisely the minute a player is first walking into everyone else's view. This
    is still not liveness detection. Added
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
  `architecture.md`): `transport.NDJSONConn` enforces `MaxLineBytes` *during* the read
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

An adapter may also declare `"features"` here — the capabilities it needs the core to negotiate
on its behalf (see `features` above). The core advertises the union of that and its own
configured list. **This is not a breach of "an adapter has no say in how the core reaches the
relay":** a capability is a statement about what the *adapter* can do, which nothing else can
know, whereas the address, transport and rate are properties of the connection and remain
entirely the core's. Every shipped adapter omits it. The core also gains **seven** more bridge
message types for those capabilities — `event` (both directions), `lease`/`escrow`/`world`
(adapter → core) and `lease_state`/`escrow_state`/`world_state` (core → adapter) — none of which
an adapter that never asks for a capability will ever see. (This sentence said "four" and then
listed five; `world`/`world_state` landed later the same day and were never added to the count.
Corrected 2026-08-18 against `bridge/bridge.go`.)

`game_id` is opaque to the core — the same equality-only rule as `area_id`/`anim` — and is
forwarded verbatim into the relay's own `hello.game_id` (the packet-schema table above). This
is what lets the core defer connecting to the relay until an adapter actually shows up and
says which game it is, instead of requiring the user to also type `"game"` into a config file
(`core.Core.ConnectRelayOnAdapterHello`). A caller that already knows the game
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
(`relay/limits.go`), and — as of the relay-safety hardening pass — mirrored on
receive by `core` too (`protocol/limits.go` holds the shared ones, so the
two enforcement points can't silently drift apart). Originally generous rather than tight,
since the relay was no-auth through Phase 4; audited with an adversarial peer in mind
alongside room-code auth (see the architecture.md ADR) — treat the numbers below as tight now:

- Max line length per NDJSON message: **4096 bytes** (`MaxLineBytes`). Enforced *during* the
  read itself since 2026-08-14 (`transport`'s bounded-read fix, see "Transport"
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
  `relay/limits.go`) — the relay closes, rather than throttles, a connection that
  exceeds it, sending a `reject` (`ReasonRateLimited`) first since the send/receive rate-control
  feature (see the ADR in `architecture.md`). At the default `send_hz` (20), this computes to
  exactly the historical flat **120** — unchanged for an unconfigured relay. The cap **only ever
  scales up**, never down: a relay turned *down* to a slower room rate must not start
  disconnecting older clients still sending at their own built-in 20Hz default.
  **Client-side enforced since Phase 6** (TEVI): `core.Core.MinSendInterval` (left at
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
  otherwise claim someone else's id. `core` mirrors this trust boundary on receive:
  it keeps its own roster (seeded from `welcome`, maintained by `join`/`leave`) and drops any
  `state` for a `player_id` it never actually saw announced, rather than trusting the relay
  completely — a hostile or compromised relay was previously able to inject state for an
  arbitrary id with nothing to stop it.
- Remote strings (`area_id`, `anim`, `extras` values, display name) are never interpolated
  into a file path, shell command, or format string by an adapter. They are opaque data,
  not code, even though they're only ever compared by equality within the same game.
- Max `event` payload: **1024 bytes** (`MaxEventBytes`), plus **64** for `corr_id`
  (`MaxCorrIDLen`). Uniform across every transport rather than transport-dependent, so an event
  means the same thing everywhere and needs no size negotiation.
  **Correction, 2026-08-18: it does NOT keep a whole event envelope under
  `udpconn.MaxDatagramBytes` (1200), and this file previously claimed it was chosen to.** It was
  sized against the *payload* alone. Measured: a maximal `Event` renders to **1321 bytes** and a
  committed `EscrowState` to **2294**, against 1182 usable after 18 bytes of framing — both are
  refused by `udpconn.checkWritable`, on the reliable plane too, and lost for that recipient. See
  `risks.md`, which has the full measurement, and `bandages-core.md`. Unreached today: no adapter
  uses these planes. Fixing it is a contract change with its own trade-offs and its own decision. **There is no application-level
  fragmentation, deliberately**: an oversized event is refused, not split, because fragmenting
  across a lossy plane reinvents TCP badly and the reliable plane already is TCP. If a payload
  does not fit, send a *reference* to the data (a key, an exchange id), never chunks.
- Max lease key: **128 bytes** (`MaxLeaseKeyLen`); max distinct keys held per room: **256**
  (`MaxLeasesPerRoom`), past which a claim is denied like any other refusal — without it a
  client could grow the relay's lease table without bound by claiming a fresh key per message.
- Lease TTL: clamped to **1s–5min**, default **30s** (`ClampLeaseTTL`) — clamped rather than
  refused, so a silly duration never costs a claim that would otherwise have been won.
- Max escrow id: **64 bytes**; max escrow blob: **1024 bytes**; max concurrent exchanges per
  room: **64** (`MaxEscrowsPerRoom`). Escrow timeout **60s**, terminal-record retention **60s**.
- Max `features` entries: **16**, each **64 bytes** (`MaxFeatures` / `MaxFeatureLen`). Max
  `resume_token`: **128 bytes** (`MaxResumeTokenLen`); the relay's own are 16 random bytes as
  hex. Both checked at the relay alongside the other `hello` field bounds, before any of them
  are used to create or look up a room.
- Resume grace: an identity dropped from a `resume.v1` room is held **20s** by default
  (`DefaultResumeGrace`, `server.resume_grace_seconds`) before becoming a real leave. The
  client's slot stays counted against `max_clients` for that window, since it is still occupied.
- An unknown message `type` is ignored, not treated as an error — same forward-compatibility
  posture as the existing unknown-*field* rule above.

## Open questions carried from the original Phase 0 backlog (all now closed)

All six were answered against a running game, per the verification standard in `CLAUDE.md` —
each carries its decision and the `verified.md` entry that settled it below. Kept as dated
history rather than deleted, because the answers are the contract. Nothing here is still open;
a *new* question of this kind gets closed the same way it was then, against a running game and
never from memory.

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
      by superseding it.** The real enforced rate is `core.DefaultMinSendInterval` = 50ms / 20Hz,
      live-confirmed across the three games shipping at the time (Emerald, TEVI, Pseudoregalia; Crystal
      came later, 2026-08-18) — see the
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
