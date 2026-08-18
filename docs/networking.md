# How the networking layer actually works

This file explains the Go client/server layer: what the relay process *is*, what happens on a
connection from the first byte to the last, and — where it isn't obvious — *why* it was built
that way. It is written for someone who is about to read or change `relay`,
`core`, `transport`, or `netx` and wants the shape in their head
first.

It deliberately does not overlap the three documents that already exist:

- [`docs/security.md`](security.md) is the **security and privacy posture** — what this layer
  does and does not defend against, and whether it is safe to use with people you don't know.
  Every threat question belongs there. This file points at mechanisms; that file judges them.
- [`agent_docs/contract.md`](../agent_docs/contract.md) is the **wire spec** — the packet
  schema field by field, the message table, the exact limit values. When this file says
  "the relay validates the state message", the authority on *what a state message is* is
  there, not here.
- [`agent_docs/architecture.md`](../agent_docs/architecture.md) is the **decision record** —
  dated ADRs saying why each choice was made at the time it was made. This file summarises
  conclusions and links; it never restates an ADR.
- [`docs/integrating.md`](integrating.md) is for **someone outside
  this project** who owns their own game's source and wants to reimplement the client or embed the
  relay. It is unsupported and untested by us. Closest to this file in subject, opposite in
  audience: this one is for changing the Go code, that one is for never reading it.

References here name a **file and a symbol**, never a line number. They used to carry
`file.go:123` anchors "as of 2026-08-17", with a note saying they would drift and the function
names would not -- and by 2026-08-18 they had drifted so far that most pointed at unrelated code
(one `relay.go` anchor for `joinOrCreateRoom` landed inside `Room.remove`, another for the
`only_game` check landed on `sendEnvelope`). An anchor that is confidently wrong is worse than
no anchor, and nothing existed to re-sync a hundred of them, so the half that was documented as
durable is the half that was kept.

---

## 1. The three processes, and what the relay is not

There are three things running, and they are separate on purpose:

- **The adapter** lives inside the game (BizHawk Lua, a Unity/UE mod DLL). It reads local
  player state and draws remote ghosts. It never touches the network. It holds one socket, to
  its own local core process, and nothing else.
- **The core** (`core`, shipped as `meshghost.exe`, `cmd/meshghost/main.go`) is the
  game-agnostic client. It owns the relay connection, the interpolation buffer, and the
  per-remote-player bookkeeping, and it serves the bridge listener the adapter connects to.
- **The relay** (`relay`, shipped as `meshghost-server.exe` /
  `meshghost-relay.exe`, `cmd/meshghost-relay/main.go`) is a hub. Clients connect to it; they
  never connect to each other.

The relay's whole job is: accept a connection, decide whether to admit it, hand it an id, and
copy the bytes it sends to the other members of its room. That's it. It holds no *positions* and no
history — a `Room` is a name, a `game_id`, a `game_version`, and a map of members (`relay.go`),
plus the opt-in bookkeeping the planes past cosmetic need: leases, escrows, a last-state-per-member
snapshot, and — since `world.v1`, 2026-08-17 — a **world** of opaque per-entity blobs it holds on a
room's behalf and hands to whoever takes an authority lease next (`world.go`). None of that changes
what it *understands*: every one of those is an opaque string or an opaque blob, and none of it runs
for a room that did not ask for it. It does not know what a position *means*, and by hard rule it never
will: `area_id`, `anim`, `orientation` and `extras` are opaque, compared by equality if at all,
and there is no `if game == "emerald"` anywhere in `relay` or `core`. The
relay never imports `core` or `bridge` — see the package doc at
`relay.go`, which states that as an invariant rather than an accident.

The practical consequence of "game-agnostic" is worth naming: a relay can host an Emerald room
and a TEVI room side by side and never notice. What keeps them apart is `game_id` stickiness
(section 4), not any knowledge of either game.

## 2. The life of a connection

Everything below happens on one goroutine per connection. `Serve` accepts and spawns
(`relay.go`); `handleConn` (`relay.go`) then drives that connection for its entire
life.

**Wrap the socket.** `transport.FromConnWithLimits(conn, protocol.MaxLineBytes, s.IdleTimeout, 0)`
at `relay.go`. The limits go in *at construction*, not as field assignments afterwards,
because `FromConnWithLimits` (`transport.go`) sets them before starting the read goroutine
— setting them after would race the loop's own read of them, which is exactly the bug that
made this constructor exist.

**Arm the hello timer.** `relay.go`. A connection that hasn't completed a `hello` and
joined a room within `DefaultHelloTimeout` (10s, `relay/limits.go`) is closed. The transport's
own idle timeout does not cover this: it resets on *any* successfully read line, so a peer
could ping forever without ever joining and stay under it indefinitely.

**Resolve the rate cap once.** `sendHz := s.resolveSendHz()` and
`msgLimit := maxMessagesPerSecond(sendHz)` at `relay.go-587`, before `OnReceive` is
registered. Deliberately not re-read per message: the cap the relay *enforces* has to be the
one this connection's own `welcome` *advertised*, and re-reading `s.SendHz` mid-session would
let the relay start enforcing a limit it never told this client about.

**Then the checks, in this order** — all inside the `r == nil` branch of `OnReceive`
(`relay.go`), which is the "not in a room yet" state. Only a `hello` is accepted here;
anything else this early is silently ignored.

1. **Field lengths** (`relay.go`). Every `hello` string field against `MaxHelloFieldLen`
   (128, `relay/limits.go`). This runs *first*, before even the version check, and its
   rejection logs without echoing the field values — the normal rejection path prints them,
   and printing an unbounded attacker-controlled field into the host's own log is precisely
   what bounding the field was for.
2. **Protocol version** (`relay.go`). A mismatch is refused outright rather than guessed
   at. Everything below can now safely log the fields, since they're known short.
3. **Room code** (`relay.go`). `subtle.ConstantTimeCompare`, so a wrong guess can't be
   refined byte by byte. An empty configured `Server.RoomCode` means auth is off — the original
   friend-hosted posture.
4. **Transport discovery** (`relay.go`). If `hello.QueryOnly` is set, reply with the
   `transports` offer list and hang up. The placement is the point: *after* the room code and
   *before* the room table is touched. No room is joined, no `player_id` assigned, no slot
   reserved, nobody is told anything — so a query discloses nothing to anyone who could not
   simply have joined instead. That is what keeps discovery from adding any pre-auth surface.
5. **`only_game`** (`relay.go`). A server-wide, operator-declared restriction to a single
   `game_id`, with its own reason (`ReasonGameNotAllowed`) distinct from the per-room mismatch —
   because a client refused for this one cannot fix it by picking another room.
6. **Room join** (`relay.go` → `joinOrCreateRoom`, `relay.go`). Creates the room if it
   doesn't exist; otherwise checks `game_id` and (if both sides declared one) `game_version`.
7. **Slot reservation** (`relay.go` → `tryReserveSlot`, `relay.go`). The capacity check
   and the increment happen in one critical section; a `count()`-then-increment pair would race
   two simultaneous joins past `MaxClients`. If the reservation fails, `dropIfEmpty` cleans up
   the room this attempt may just have created.

Every one of those refusals goes through `rejectAndClose` (`relay.go`): send a `reject`
with a reason string, log one line, then close. Not a bare hangup — a hangup is
indistinguishable from "the relay is down" or "the relay is slow", and the client can't tell
its user anything useful about it.

**Admission.** `nextPlayerID` (`relay.go`) hands out `p1`, `p2`, … from an atomic counter;
ids are never reused, and carry nothing about the connection. Then
`tryAddAndSnapshotRoster` (`relay.go`) adds the member *and* returns the roster as it stood
immediately before the add, under one lock. That combination matters: two clients joining
concurrently through separate `roster()` + `tryAdd()` calls could each snapshot before either
had added itself, and neither would ever learn about the other — which, since the core now
drops state from unrostered ids (section 3), means a permanently invisible peer rather than a
cosmetic gap.

**Welcome, then announce.** `welcome` goes to the joiner with its id, the pre-join roster, and
the room's `send_hz` (`relay.go`); a `join` goes to everyone else via
`Forward` to that same `rosterBeforeJoin` snapshot (`relay.go`) — not to whoever happens to
be a member by the time the broadcast runs, which CI's race job caught 2026-08-16 delivering a
duplicate, late `join` for a player the newcomer's own `welcome` roster had already named. Order
matters — the joiner learns the room from its own `welcome`, the room learns the joiner from the
`join`.

**Steady state.** Section 3.

**Leave.** `OnDisconnect` (`relay.go`) stops the hello timer, removes the member, releases
the slot, forwards a `leave` to the remaining roster, and drops the room if it is now empty.
There is no session resumption anywhere: a reconnect is a new connection with a new
`player_id`, full stop. That single fact is why `queryTransports` on the client side goes out
of its way not to join (section 6) — joining and then upgrading would make every other player
watch this one leave and rejoin.

## 3. The life of a state message

Adapter → bridge → core → relay → other cores → their adapters. What happens at each hop:

**Adapter → core.** Once per game frame the adapter sends a bridge `local_state`
(`bridge.go`). `handleBridgeConn` (`core.go`) decodes it and calls `onAdapterFrame`
(`core.go`). The adapter always drives; the core never calls into it uninvited.

**Core → relay.** `forwardLocalState` (`core.go`) does four things worth knowing:

- It records `c.localAreaID` on *every* real frame, before any throttling and whether or not a
  relay connection even exists — the cross-area render filter needs the adapter's actual
  current area, not the last one that happened to get sent.
- It throttles to `effectiveSendInterval()` (`core.go`), which is the **slower** of the
  relay's advertised rate and this core's own `MinSendInterval`, falling back to
  `DefaultMinSendInterval` (50ms/20Hz) when neither exists. Slower, always: the relay's rate is
  prescriptive for a client with no opinion, but a client that deliberately configured a floor
  did so because of its own connection, and the relay has no business overriding that upward.
- A throttled frame is dropped *before* being stamped, so it never consumes a `seq`.
- `sendState` (`core.go`) uses `SendUnreliable`, not `Send`. This is the state plane,
  which the contract defines as lossy and latest-wins. On tcp there is no difference at all; on
  a datagram transport it means a lost sample is superseded by the next one ~50ms later rather
  than retransmitted — and a retransmitted position arrives stale and out of order, which is
  worse than the gap it filled.

**At the relay.** The `TypeState` case (`relay.go`): decode, `protocol.ValidateState`
(`protocol/limits.go`) — drop the whole message rather than truncate it, so a client sees
silence instead of a confusing half-message — then **stamp `st.PlayerID = id` from the
connection's own assigned id** (`relay.go`), never trusting the payload's. A peer could
otherwise claim someone else's id. Then
`r.ForwardUnreliable(stateEnv, r.stateRecipients(id, time.Now()))` (`relay.go`).

**The per-recipient receive cap.** `stateRecipients` (`relay.go`) asks each *other* member
whether it currently wants a sample from this sender, via `Client.allowStateFrom`
(`relay.go`). The cap is per-recipient and per-sender: two recipients can receive the same
sender at two different effective rates simultaneously, decided entirely by each recipient's
own requested `max_receive_hz_per_player`. That's harmless because a ghost is a cosmetic
overlay with no shared state that has to agree across clients. It is enforced *at the relay*
because dropping on receive would save the client's downlink nothing, which is the entire
point of the feature. Excess samples are dropped, never queued or coalesced — so a lower cap
costs smoothness, never latency or memory. Only `state` is ever gated this way; a throttled
`leave` would strand a permanently frozen ghost on the capped recipient's screen.

Note `allowStateFrom` is a minimum-interval gate, not a token bucket, so the achievable rate is
quantized: a 15Hz cap against a 20Hz sender yields 10Hz, not 15. Documented at the function,
and acceptable for the same "it's cosmetic" reason.

**Receiving core.** `handleRelayMessage` (`core.go`) → `storeRemoteState` (`core.go`),
which applies the *same* `protocol.ValidateState`, ignores state for its own id, and then
checks `c.roster` — the set of ids this core actually saw announced via `welcome` or `join`.
A state for an id it never saw is dropped. That is a deliberate trust boundary against the
relay itself: previously `welcome.roster` was discarded entirely and any id arriving in a
state was accepted, so a hostile or compromised relay could inject state for an arbitrary
player. Surviving states are appended to that remote's `remoteBuffer` (`interp.go`), which
keeps the last 8 snapshots — enough to smooth a couple of dropped packets, not a replay log.

**Core → adapter.** Every adapter frame, `tickRenders` (`core.go`) computes
`renderTime = now - InterpolationDelay` (100ms by default) and asks `remoteStatesAt`
(`core.go`) for each remote's state at that moment. `remoteBuffer.at` (`interp.go`)
finds the two snapshots bracketing `renderTime` and lerps position between them; `area_id`,
`anim`, `orientation` and `extras` are opaque and are never interpolated — they're taken from
the older snapshot and hold until the next real sample passes. Outside the buffered range it
returns the nearest edge snapshot, with no extrapolation. `lerp` (`interp.go`) additionally
refuses to blend across mismatched position lengths, a non-positive time span, or two different
`area_id`s — that last one because blending two zones' unrelated coordinate spaces renders a
ghost at a meaningless midpoint.

`remoteStatesAt` also drops any remote whose `area_id` doesn't equal the local player's own,
unless the local area is still unknown. Equality only; it never looks inside the string.

`tickRenders` then diffs against what was rendered last tick and emits `render_remote` for
everything current, `despawn_remote` for everything that dropped out. Both are pushed on the
same bridge call the adapter just made — the adapter's job is only to hold the latest state per
id and redraw all of them every frame. Interpolation lives here, once, rather than in every
adapter; that's the single hardest reusable piece in the project and duplicating it into each
game is exactly the leak the core/adapter split exists to prevent.

## 4. Rooms and membership

A room is created lazily by the first `hello` that names it and destroyed by `dropIfEmpty`
(`relay.go`) when its last member leaves, so abandoned rooms don't accumulate for the life
of the process.

`game_id` and `game_version` are **sticky on first join**. The room takes both from whoever
created it (`newRoom`, `relay.go`); a later `hello` with a different `game_id` is refused
with `ReasonGameMismatch`. `game_version` is checked only when *both* the room and the joiner
have declared one (`relay.go`) — an adapter that reports no version must never be refused,
and a room whose first member reported none simply has no version to compare against yet. This
is server-wide `only_game`'s counterpart, not its duplicate: `only_game` is one operator
decision covering the whole relay, room stickiness is per room and emergent.

`player_id` is a per-process monotonic counter (`relay.go`), never reused. Never reusing
matters beyond hygiene: `Client.forgetSender` (`relay.go`) exists precisely because ids are
unique forever, so without purging a departed sender's entry from every remaining member's
receive gate, a long-lived relay with real churn would accumulate one stale map entry per
departed player, per surviving player.

`MaxClients` is enforced **server-wide across every room combined**, not per room
(`relay/limits.go`). The reason is in that constant's comment: a room fans every state
message out to every other member, so traffic within a room grows with the square of its size.
Two rooms don't each get a fresh budget.

## 5. The concurrency model

This is the subtlest part of the relay, and most of it is an argument for why there is so
little locking.

**One goroutine per connection, and `OnReceive` is serial.** `transport.readLoop`
(`transport.go`) reads lines from one connection on one goroutine and calls `onReceive`
inline, one at a time. So everything reachable only from inside `handleConn`'s `OnReceive`
callback is single-threaded by construction and needs no mutex: `rateWindow`/`rateCount`
(`relay.go`), `loopbackGhostSent` (`relay.go`), the resolved `sendHz`/`msgLimit`. The
comment at `relay.go` records that a `rateMu` guarding the rate counters was *removed* in a
review as genuinely unnecessary rather than kept as defence in depth — that's the intended
posture. `room`/`playerID` are the exception within `handleConn`, guarded by a local `mu`,
because the hello timer's separate `AfterFunc` goroutine reads `room` too (`relay.go`).

That invariant is load-bearing above its own package. It is the reason UDP and QUIC support
cost `relay` zero lines: `netx` presents both as an ordinary `net.Listener`
handing out ordinary `net.Conn`s, so the per-connection-goroutine model survives untouched and
none of this concurrency needed re-auditing. Both package docs say so explicitly
(`netx.go`, `udpconn.go`).

**`Client.gateMu` is the one real exception** (`relay.go`). `lastStateTo` maps a *sender's*
id to the last time that sender's state was forwarded *to this client*. It is per-recipient,
but it is read and written from the *sender's* `OnReceive` goroutine — so every other member of
the room can touch one recipient's gate concurrently. That breaks the "serial, so no lock"
invariant and nothing else in `Client` does; hence a mutex on exactly that field and nothing
else. `maxReceiveHz` sits next to it unguarded, because it's written once before the `Client` is
published into `Room.members` and never mutated after.

**`Room.Forward` snapshots targets before sending** (`relay.go-157`). It copies the
recipient `(id, conn)` pairs under `r.mu`, releases the lock, and only then sends. This used to
send while holding the lock for the whole loop. Once `Send` gained a write deadline and could
legitimately block for seconds against a stalled peer (`DefaultWriteTimeout`, 10s,
`transport.go`), holding `r.mu` across every recipient's `Send` meant **one stalled member
could freeze every other room operation** — joins, leaves, roster reads, other forwards — for
the same duration. The same snapshot-then-act shape appears in `Room.remove` (`relay.go`,
purging receive gates after unlocking) and `stateRecipients` (`relay.go`, consulting each
recipient's gate after unlocking), which also keeps `r.mu` and `gateMu` from ever nesting.

`Forward` vs `ForwardUnreliable` are separate methods rather than one method with a flag
(`relay.go`, `relay.go`) so that a caller who forgets which it wanted gets the safe
one. Same reasoning as `Transport.Send` being reliable everywhere: reliability is opt-*out*.

**On the core side**, `Core.mu` guards the remote map, roster, `localAreaID`, send-throttle
state, and the relay identity fields; `relayConnectMu` separately serialises dial attempts so a
retry loop and a real adapter's bridge `hello` can't race into two simultaneous connects
(`core.go`). The `OnDisconnect` handler at `core.go` checks `c.relay == conn` before
clearing anything, so a stale connection's late callback can't wipe a newer live one's state.

**In `transport`**, `deliverMu` (`transport.go`) serialises actual callback
delivery, distinct from `cbMu` which only guards the callback *fields*. It exists because of
`pending` (`transport.go`): `FromConn` starts the read loop before returning, so every
caller has a window between "connection exists" and "callback installed", and a message landing
in it used to be dropped silently. That was not theoretical — the relay installs its callback
after `FromConnWithLimits`, so a fast-enough client `hello` would never be welcomed. It surfaced
as `go test ./...` failing in ~9 of 12 runs, a different test each time, always a timeout on a
message that was sent and never delivered. `OnReceive` (`transport.go`) now flushes the
backlog in arrival order under `deliverMu`, so the read loop can't interleave a newer payload
into the middle of it.

## 6. Transports

**The handshake is always tcp, and no setting changes that.** `Core.Transport` is not "how to
connect" — it is "what to move to *once* connected". `resolveTransport` (`core.go`) states
this at length and is worth reading directly. A `tcp` preference short-circuits immediately
(there's nothing to upgrade to, and asking would cost a round trip to learn nothing); anything
else runs `queryTransports` (`core.go`) first.

That inversion buys three things at once:

- **A client never needs to know a port.** QUIC's may differ: it shares `-addr`'s port number by
  default, and moves only when the plain udp transport is served and has taken it. Guessing is
  impossible, so the relay is asked. `connect_to` only ever needs the tcp address.
- **The one leg that must work is the one that works everywhere** and is readable with netcat
  while debugging.
- **A wrong preference degrades instead of failing.** Asking a relay for quic it doesn't serve
  yields a working tcp session plus a log line (`chooseTransport`), not a
  timeout with no explanation.

`queryTransports` sends a `hello` with `QueryOnly: true` and hangs up without joining. Not
joining is the whole point (see section 2's note on session resumption). It returns an error
*only* for an unreachable relay — that error is exactly what the caller would have produced
itself, so it's passed up; everything else (an old relay, a refused room code, a malformed
answer) yields "nothing to upgrade to" and lets the real connect attempt surface the real
problem with its real reason. An older relay that doesn't know `query_only` treats the message
as a real join and replies `welcome`; `core.go` recognises that, logs it, and falls back
to tcp. That costs one spurious join/leave against pre-2026-08-16 relays only, and is the price
of the field being additive rather than a version bump.

`chooseTransport` takes **only the port** from the offer and keeps the host the
user configured. That's what makes discovery work through NAT and port forwarding: a relay bound
to `0.0.0.0` has no idea which address reaches it, but the client just connected to one. An
explicit preference is honoured exactly and nothing else is considered — a client that asked
for quic must never silently land on udp, which would swap an encrypted session for one that
cannot be encrypted at all. Only `auto` ranks, over `netx.AutoPreference` (`netx.go`):
QUIC, TCP, UDP — **udp last deliberately**, even though it shares QUIC's loss behaviour.

On the relay side, `cmd/meshghost-relay/main.go` opens one listener per selected transport,
all feeding the same `Server`, and builds the offer list from the listeners that actually came
up rather than the configured list (`main.go`) so a transport that failed to bind is never
advertised. `netx.ParseKinds` (`netx.go`) silently *prepends* tcp if the operator left it
out (`netx.go`), because a relay without tcp would be unreachable by every client —
including ones configured for the transports it does serve. That was found by `internal/e2e`,
not by reasoning.

**Why the seam is at `net.Conn` rather than a second `Transport` implementation.** This is the
key structural decision and `netx.go` argues it directly. Everything above `netx` stays
transport-agnostic for free: `relay.Serve` takes a `net.Listener`, `handleConn` takes a
`net.Conn`, and `transport` applies identical NDJSON framing to whatever `net.Conn` it
is handed. A second `Transport` implementation would instead have duplicated framing, limits,
deadlines, the pending-backlog fix, and — worst — would have put the relay's
one-goroutine-per-connection invariant back on the table, the invariant section 5 shows the
whole no-locking argument rests on. Doing the demultiplexing *below* that layer meant UDP cost
`relay` nothing.

The three implementations:

- **tcp** — `net.Listen`/`net.DialTimeout`, plain NDJSON over a stream. Readable with netcat.
  `SendUnreliable` is exactly `Send`.
- **udp** (`netx/udpconn`) — one shared socket presented as a `net.Listener`,
  demultiplexed by remote address. One datagram carries exactly one NDJSON line. *Every*
  datagram — payload as much as control — is framed with a leading `0xFF` plus a type byte,
  which can neither start a JSON object nor be a legal UTF-8 lead byte, so data and control can
  never be confused and an unframed datagram is simply dropped (`udpconn.go`). Payloads were
  bare NDJSON lines once, which was greppable but became untenable when the token below turned
  mandatory: an unwrapped datagram would have been a way to not carry it. Admission
  requires echoing back a **derived, not stored** cookie — `HMAC(secret, addr || timeSlot)`,
  checked against the current and previous slot (`cookieFor`/`validCookie`,
  `udpconn.go`/`193`). Deriving is the point: a table of unvalidated addresses would itself
  be the vulnerability, one map entry per forged hello, unbounded memory an unauthenticated
  stranger controls. Same trick as a TCP SYN cookie or QUIC's Retry packet. After admission,
  every application datagram must carry an unpredictable 8-byte **per-connection token**
  (`udpconn.go`), because address validation only gates admission — without the token, a
  connection is identified by source address alone and anyone who can guess a client's ip:port
  can inject into its session. `Write` (`udpconn.go`) is reliable **and ordered** via sequence
  numbers, acks, a retry loop, and a receive-side reorder window (`reorderWindow`, 64) — ordering
  added 2026-08-16, and `core` now depends on it rather than merely on delivery. It does
  not block waiting for the ack (blocking would stall the relay's forward loop for every other
  recipient behind one slow peer). `WriteUnreliable`
  (`udpconn.go`) is one framed, token-carrying datagram, sent once. `MaxDatagramBytes` is 1200
  (`udpconn.go`) — below the Ethernet MTU, because a datagram large enough to fragment is
  lost whole when any one fragment is lost.
- **quic** (`netx/quicconn`) — one bidirectional stream plus datagrams. `Send` goes to
  the stream (reliable, ordered); `SendUnreliable` rides a QUIC datagram (RFC 9221). Using only
  the stream would work and would be simpler, and would also make QUIC pointless here: a single
  reliable stream head-of-line blocks exactly like TCP. The payoff only appears once the state
  plane rides datagrams. The stream is line-buffered before anything is handed upward
  (`streamLoop`, `quicconn.go`) — merging naively would splice a datagram into the middle
  of a half-delivered line and produce something no parser can recover. The handshake *is* TLS
  1.3, so the session is encrypted with no configuration; the certificate is self-signed and
  in-memory and the client sets `InsecureSkipVerify` (`quicconn.go`) because `connect_to` is
  a bare IP with no CA and no hostname to check. That is encryption against someone watching the
  network, not proof of who is on the other end — see `docs/security.md`.

The seam between "reliable" and "lossy" is a **type assertion**, not a field:
`NDJSONConn.SendUnreliable` (`transport.go`) checks whether its `net.Conn` implements
`unreliableWriter` (`transport.go`) and falls back to `Send` if not. That's how
`transport` keeps its no-internal-dependencies property — it must not import
`netx` — while a `net.Conn` that knows nothing about any of this still works.

One framing detail with teeth: `Send` (`transport.go`) joins payload and `'\n'` into **one**
`Write`. Over TCP the split was invisible, since the kernel coalesces a byte stream either way.
On a datagram transport, two writes are two datagrams and every line arrives cut in half. There
is a regression test for exactly this.

## 7. Limits and backpressure

Values and rationale are in `agent_docs/contract.md`'s Limits section; the enforcement points
are `relay/limits.go` and `protocol/limits.go`. What matters here is *what
happens when each one trips*.

- **Line length** — `protocol.MaxLineBytes` (4096) is enforced *during* the read, as
  `bufio.Scanner`'s max token size (`transport.go-234`), not as a check on an
  already-buffered line. The earlier `ReadBytes` approach grew its buffer without bound until it
  found a newline, so a peer streaming bytes with no newline could force unbounded memory
  growth. Trips → the read loop fails, `fail` (`transport.go`) reports and closes.
- **Flood cap** — a tumbling one-second window at `relay.go`. Over
  `max(120, send_hz × 6)` (`MaxMessagesPerSecondFor`, `relay/limits.go`) the relay sends a
  `reject` with `ReasonRateLimited` and **closes**, rather than silently dropping the excess: a
  client flooding the relay isn't behaving as this project's own adapters do, and there's
  nothing to gain from staying connected to find out why. The cap only ever scales *up* from
  120 — turning a relay's `send_hz` down must never start disconnecting older clients still
  sending at their own built-in 20Hz default. `ReasonRateLimited` is classified *retryable* by
  `core.isPermanentRejectReason` (`core.go`), because a reconnecting client re-reads the
  room's advertised `send_hz` from the new `welcome` and may well fit the second time.
- **MaxClients** — server-wide (section 4). Trips → `ReasonServerFull`, also retryable, since
  someone may leave.
- **Hello timeout** — 10s (section 2). Trips → logged and closed, no reject (there is no
  established protocol conversation to reject *within*).
- **Idle timeout** — `DefaultIdleTimeout` (60s, `transport.go`), refreshed after every
  complete line. This is what makes `Core.sendHeartbeats` (`core.go`) necessary: a core
  with no adapter attached sends nothing at all, got closed as idle, and the auto-reconnect
  handed out a fresh `player_id` every cycle — which every other peer saw as a despawn/respawn
  once a minute. The 20s `ping` exists only to keep the connection non-idle. It is **not**
  liveness detection; nothing reads the `pong` back.
- **Write timeout** — `DefaultWriteTimeout` (10s, `transport.go`). Bounds one `Send` so a
  peer that stops reading can't block the writer forever. `Room.Forward` depends on this
  returning in bounded time (section 5).
- **Datagram size** — `udpconn.MaxDatagramBytes` (1200) is *below* `MaxLineBytes` (4096), so a
  state message with large `extras` can exceed it. That is **refused with an error**
  (`ErrDatagramTooLarge`, `udpconn.go`), never truncated — a half-written JSON line is a
  parse error at the far end with no clue why. Such a client should use tcp.
- **Plane bounds** — the planes past cosmetic carry their own, in `protocol/online.go` rather than
  `limits.go`: `MaxEventBytes` (1024), `MaxLeaseKeyLen` (128), `MaxEscrowBlobBytes` (1024),
  `MaxWorldKeyLen` (64), `MaxWorldBlobBytes` (768). **These are derived from the datagram limit
  above, not from `MaxLineBytes`**, because `checkWritable` refuses an oversized datagram
  *including a reliable one* and reports it only as a log line — so an oversized message on a
  decision-carrying plane is lost for that recipient and never superseded. `MaxWorldKeysPerRoom`
  (64) is the odd one out: it is a per-room **memory** bound rather than a per-message one, and it
  equals `udpconn`'s reorder window because a reliable burst wider than that window goes unacked
  and is retried until the connection closes. Asserted in
  `netx/udpconn/world_bounds_test.go`. Two pre-existing constants do NOT satisfy this and
  are recorded in `agent_docs/risks.md`.
- **Read queue** — 64 datagrams per connection (`udpconn.go`, `quicconn.go`), dropped
  when full rather than blocked. Blocking would let one slow reader stall the demultiplexer for
  every other connection on the shared socket.

Backpressure, in short: there isn't any, on purpose. Nothing queues on behalf of a slow peer.
Excess is dropped (receive cap, full read queue), refused (oversized datagram), or the
connection is closed (flood, idle, oversized line). That's coherent for the **state** plane because
it is defined as lossy and latest-wins — a dropped sample is superseded ~50ms later, so the failure
mode is a slightly less smooth ghost, not a wrong one.

It does not extend to the planes past cosmetic, and that asymmetry is deliberate rather than
overlooked: those carry decisions, so they ride the reliable path and are bounded before they are
ever accepted rather than dropped afterwards. The one exception is a lossy `world` write, which the
adapter opts into per write precisely because it *is* superseded by its own next update — and even
there the relay stores the latest, so a snapshot stays complete. What has no backpressure anywhere
is a peer that stops reading: that is the write timeout's job, not a queue's.

## 8. What the relay deliberately does not do

- **No game knowledge.** No memory access, no rendering, no branching on `area_id`/`anim`/
  `game_id` contents anywhere in `relay` or `core`.
- **No persistence.** Rooms exist only while occupied (`dropIfEmpty`), and nothing is written
  to disk except the operator's own log file.
- **No session resumption.** A reconnect gets a fresh `player_id`; `seq` is a core-lifetime
  counter that never resets. This is why the transport upgrade path is careful never to join
  twice (section 6).
- **It never learns anything about an adapter.** The relay sees `game_id` and `game_version` as
  opaque strings and nothing else. It has no idea whether the client is a real game, a fake
  adapter, or nothing at all.
- **It doesn't redistribute identity.** `display_name` reaches the relay and is logged there;
  it is never forwarded. `welcome.roster` and `join` carry ids only.
- **It never calls `RemoteAddr()`.** `relay` and `core` contain no call site
  (the only definitions are the `net.Conn` methods `udpconn`/`quicconn` must implement). One
  nuance worth knowing on udp specifically: `udpconn.Listener` necessarily *keys* its connection
  map by `remote.String()` (`udpconn.go`), because that is how a shared socket is
  demultiplexed at all — the address is used internally, just never surfaced upward or logged.
  Whether that matters is a question for [`docs/security.md`](security.md), which is the
  authority on privacy posture.
- **No *simulation* authority, which is not the same as no authority.** This bullet used to read
  "no event routing", and that stopped being true on 2026-08-17: addressed events, a room
  sequencer, leases, escrow and world custody all shipped that day, and `Room.Forward` already
  taking an explicit recipient set is why it was a localised change rather than a rewrite. What the
  relay still refuses to do is judge *content* — who really had the item, whether that damage was
  real. It orders and it stores; it never simulates, because that is the one job that requires
  understanding the game. See `agent_docs/contract.md`'s Extensibility section and
  `agent_docs/beyond-cosmetic.md`.

## Where to go next

- Threat model and what's still open → [`docs/security.md`](security.md)
- Exact schema, message table, limit values → [`agent_docs/contract.md`](../agent_docs/contract.md)
- Why each decision was made, with dates → [`agent_docs/architecture.md`](../agent_docs/architecture.md)
- How to run every Go-side check → [`agent_docs/testing.md`](../agent_docs/testing.md)
