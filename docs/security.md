# Security and privacy posture

## The whole shape, in one picture

```text
        YOUR MACHINE                                       A FRIEND'S MACHINE
 ┌──────────────────────────┐                          ┌──────────────────────────┐
 │  game + MeshGhost mod    │                          │  game + MeshGhost mod    │
 │            │             │                          │            │             │
 │            │  BRIDGE     │  never leaves the box    │            │  BRIDGE     │
 │            │  127.0.0.1  │  ── plaintext, loopback  │            │  127.0.0.1  │
 │            ▼  NDJSON     │     only, by design      │            ▼  NDJSON     │
 │  meshghost.exe  (core)   │                          │  meshghost.exe  (core)   │
 └────────────┬─────────────┘                          └─────────────┬────────────┘
              │                                                      │
              │        RELAY PROTOCOL — tcp / quic / udp             │
              │        (handshake is ALWAYS tcp, then upgrades)      │
              │                                                      │
              └──────────────────►  ┌─────────────────┐  ◄───────────┘
                                    │  meshghost-     │
              ┌──────────────────►  │  server.exe     │  ◄───────────┐
              │                     │  (the relay)    │              │
       ┌──────┴───────┐             └─────────────────┘       ┌───────┴──────┐
       │  another     │                                       │  another     │
       │  player      │      A STAR, NOT A MESH:              │  player      │
       └──────────────┘      no client ever connects          └──────────────┘
                             to another client, ever.
```

**Two separate protocols, and the split is load-bearing.** The **bridge** is the mod talking to its
own local core over loopback — an adapter never learns a relay address and never sends a byte off the
machine. The **relay protocol** is core-to-relay. Everything a peer sees about you crosses the second
one, so everything below is about that.

### Why a relay and not peer-to-peer

Not a shortcut — a trade, with real costs on both sides.

| | Relay / star (what MeshGhost does) | Peer-to-peer / mesh |
| --- | --- | --- |
| **Your IP** | Only the relay's host sees it. Peers never learn it — the protocol has no field that could carry it. | Every peer learns every other peer's address by construction. Unavoidable: that *is* how they connect. |
| **Setup** | One person forwards one port. Everyone else only makes outbound connections. | NAT traversal — hole punching, UPnP, STUN — which fails often enough that most "P2P" games ship a relay anyway. |
| **Ordering** | One place stamps one total order, which is what makes leases and world custody possible at all. | No natural arbiter. Getting one means electing a peer, which is a relay with extra steps and a worse failure mode. |
| **Latency** | **Two hops.** Every message goes client → relay → client, so roughly double a direct link. | One hop. Genuinely better, and the main reason to want it. |
| **Bandwidth** | **Concentrated on the host.** The relay receives from everyone and re-sends to everyone, so its uplink carries the room. | Spread across players. |
| **Failure** | **Single point.** Relay down, session over. | No single point; degrades per-link instead. |
| **Who can watch** | The relay's operator sees timing, volume, and who is in which room — though not meaning, since payloads are opaque to it by hard rule. | Each peer sees only its own links. |

For a handful of friends playing a singleplayer game, the top three rows are worth the next three.
That is the whole argument, and it is a judgement, not a fact.

### What is and is not secure, per transport

| Transport | Encrypted? | Authenticated? | Notes |
| --- | --- | --- | --- |
| **tcp** | **Optional**, TLS 1.3 — off by default, on in a release (`"tls"`) | **No**, unless a fingerprint is pinned | Plaintext by default, deliberately: greppable with netcat, which is how a session gets debugged. With `tls` on it is encrypted, and under `"auto"` one port still serves both. Always carries the handshake. |
| **quic** (default) | **Yes**, TLS 1.3 | **No** — the certificate is self-signed and unverified | Stops a passive eavesdropper. Does **not** stop an active man-in-the-middle, who presents their own certificate and is accepted. |
| **udp** | **No** | No | Go's standard library has no DTLS, so this one cannot be fixed the same way. |

So the honest summary is **encrypted-by-default, authenticated-only-if-you-ask**. A room code raises
the bar from "anyone with the address" to "anyone with the address and the code" — not to "safe
against a network-level attacker".

**Authentication, since 2026-08-19, has exactly one form, it is opt-in, and it covers one leg**: the
relay prints its TLS certificate's SHA-256 fingerprint at startup, and a player who was handed that
string by some other route puts it in `"tls_fingerprint"`. A relay presenting anything else is then
refused rather than trusted. Without it, TLS (on `tcp`) and quic alike give you encryption and no
proof of who is on the other end.

**The pin authenticates the tcp leg only.** `netx.DialWithTLS` returns a plain dial for anything
that is not tcp, so the fingerprint is never consulted on the quic path; `netx/quicconn`'s client
always sets `InsecureSkipVerify`, and `quicconn.Listen` builds its own certificate — so a relay
serving tcp+TLS and quic is presenting *two different* certificates, and the fingerprint it prints
at startup is the tcp one. The leg the pin does cover is the leg that carries the room code, which
is exactly why it is the one worth closing. But the consequence is worth stating plainly: with a
fingerprint pinned, **`tcp` is stronger than `quic`, not equal to it** — the quic session stays
encrypted-but-unverified either way.

Two more caveats worth saying out loud: it only helps if someone actually compares the string, and
the certificate is regenerated on every relay restart, so the pin has to be re-copied after the host
restarts theirs. There is no CA anywhere in this design and none is planned. The other route to
authentication — TLS channel binding, which would remove the room code from the wire entirely rather
than encrypting it — is designed and unbuilt (`agent_docs/ideas.md`, transport security).

**What plain `udp` does have**, since it is otherwise the weakest of the three: an HMAC cookie so an
unauthenticated stranger cannot make the listener allocate memory for a spoofed address, a
per-connection token so guessing an `ip:port` is not enough to inject into someone's session, and an
ordered reliable path for lifecycle messages alongside the lossy one that state rides. Those are
anti-abuse measures, not encryption, and they do not make it private.

---

This file describes what the Go networking layer (`core`, `relay`, `bridge`, `protocol`,
`transport`, `netx`) does and does not protect against, and why. It exists so "is this safe to use
with people I don't know" has a real, checkable answer instead of a guess — see
[CLAUDE.md](../CLAUDE.md)'s "no addresses or APIs from memory" rule applied to security
claims, not just game memory.

**Bottom line up front, current as of 2026-08-19.** MeshGhost supports room-code auth and a peer
game-version check, and the relay/core have been hardened against several concrete malicious-peer
attack shapes (the 2026-08-14 pass, see "What changed" below). It is safer to use with people you
don't personally know than it was — but the wire is not *authenticated* unless someone pins a
fingerprint, and a pin covers the tcp leg only. `quic`, the default session path since 2026-08-16,
is always TLS 1.3; `tcp` gained optional TLS on 2026-08-19; `udp` has no encryption at all and
cannot have any, since Go's standard library has no DTLS. Certificates are self-signed and
unverified by default, so encryption stops a passive eavesdropper and not an active
man-in-the-middle. **On `tcp`, two different defaults are both true and worth separating: the
compiled-in default is `"tls"` off** (`cmd/meshghost/main.go`), which is what a dev session or a
`go run` pair uses, **while the shipped `packaging/release/config.json` sets `"tls": "auto"` on both
client and server**, so a release pair does encrypt the tcp leg. Either way, all of this raises the
bar from "anyone with the address" to "anyone with the address and the code," not to "safe against a
network-level attacker" — and room-code auth is enforced entirely by the relay, so it provides zero
protection if the relay itself is an outdated build, regardless of what any client sends or believes
it configured (see "A new risk this creates" below). Full record of the 2026-08-14 pass: the ADR in
[agent_docs/architecture.md](../agent_docs/architecture.md) (search "room-code/version ADR").

## How a client actually connects, and why it matters here

**Every client handshakes over tcp, always, and no config setting can change that.** `"transport"`
in `config.json` is not *how* you connect — it is what you move to *once* connected. The mechanics
— the query-only handshake, the offer list, what happens when a relay does not serve the preference
you asked for — are in [docs/networking.md](networking.md)'s Transports section, which is the
canonical description; they are not repeated here.

The security consequence is the part that belongs here: the handshake, and therefore the room-code
check, **always happens over tcp**. The room code crosses that leg before quic is ever reached,
which is why TLS over tcp matters even for a session that ends up on quic, and why the tcp leg is
the one a pinned fingerprint authenticates. **That leg is plaintext unless `"tls"` is turned on**;
`udp` cannot be encrypted at all, and `quic` always is. See "known gaps" below for what each of
those does and does not mean.

**The tcp handshake grants no session identity.** It is query-only: nothing joins, no `player_id`
is assigned, and the connection that follows authenticates itself independently. So the udp leg
defends itself, with two separate mechanisms — an address-validation cookie gating admission
(blocks blind spoofing and reflection), and a per-connection unpredictable token required on
every datagram afterwards (blocks injection by anyone who merely guessed a live client's
ip:port). The second was added 2026-08-16, after the first version shipped with only the former.
Neither is encryption: an attacker already on the path reads both out of the traffic, exactly as
they would a TCP sequence number.

## What changed (2026-08-14 relay-safety hardening pass)

- **Room-code auth**: `hello` carries an optional `room_code`, checked constant-time against
  the relay's own configured code. Empty (the default) means auth stays off — unchanged from
  the original friend-hosted posture unless a relay operator opts in.
- **Peer game-version check**: `hello` carries an optional `game_version` (each shipped
  adapter's own script/mod version, not a game build number — see the ADR for why). A room's
  version, once declared, is sticky the same way `game_id` already was.
- **Legible rejection**: a refused `hello` (bad version, wrong room code, mismatched game/
  version, full room) now gets a `reject` message with a reason before the connection closes,
  instead of a bare hangup indistinguishable from "the relay is just slow or down."
- **A real remote-OOM, fixed**: `transport`'s read loop used to buffer a line without
  any size bound until it found a newline — a peer streaming bytes with no newline could grow
  memory without limit, and the existing `MaxLineBytes` check ran too late to stop it. Now
  enforced *during* the read.
- **Read/write deadlines and a hello timeout**, none of which existed before — see the
  Transport section of [agent_docs/contract.md](../agent_docs/contract.md).
- **A one-stalled-peer room freeze, fixed**: `Room.Forward` used to hold its lock across every
  recipient's `Send` call; once `Send` could legitimately block for seconds against a stalled
  peer (the deadline above), that meant one bad connection could freeze joins/leaves/roster
  reads for everyone else in the room.
- **The core no longer trusts the relay completely**: it keeps its own roster (seeded from
  `welcome`, maintained by `join`/`leave`) and drops `state` for any `player_id` it never
  actually saw announced — previously a hostile or compromised relay could inject state for an
  arbitrary id, since `welcome.roster` was discarded entirely.
- **New size/length limits** on fields that were previously unbounded: `orientation`,
  `area_id`, `anim`, and every `hello` string field. Also new: `MaxPositionComponent`
  (±1e7) and `protocol.IsValidPosition` — every `position` component must be finite, not
  just under a length cap.
- **Lifecycle logging, added same-day**: the relay's own log now records a join, a leave, and
  a refused `hello` (with reason) — previously a host had zero visibility into any of these.
  `core` logs a connect failure only when the message actually changes, so a long
  wait for the relay to come up doesn't flood the log with an identical retry line.
- **Start-order independence, added same-day**: `cmd/meshghost` no longer requires the relay
  to already be running — a permanent rejection (wrong room code, version mismatch) still
  exits loudly, but "the relay isn't up yet" now retries with backoff instead of crashing the
  whole process. Confirmed live: see
  [agent_docs/verified.md](../agent_docs/verified.md)'s "start-order independence" entry.
- **A core-relay heartbeat, added same-day**: `Core.sendHeartbeats` sends a `ping` every
  `DefaultHeartbeatInterval` (20s) on an otherwise-quiet connection — found live after a core
  with no adapter attached (or one reporting no local state) sent nothing at all, got closed
  as idle by `transport.DefaultIdleTimeout` (60s), and the auto-reconnect below handed out a
  fresh `player_id` every cycle, which every other peer saw as a leave+join/despawn-respawn
  once a minute. Not a liveness/RTT mechanism — just keeps the connection non-idle.
- **Relay-disconnect auto-reconnect, added same-day**: a relay that drops *after* a
  successful connect (crash, restart, network blip) previously had no path back to
  "connected" short of a full client restart; `Core` now retries in the background with the
  same backoff shape as start-order independence above.

## A new risk this creates

**Room-code auth is enforced entirely by the relay — a stale (pre-2026-08-14) relay binary
provides zero protection regardless of what any client sends or configures, and gives no error
telling its host that.** A `room_code` field in an old relay's `config.json` is simply an
unrecognized JSON field to that binary — silently ignored, not rejected. This isn't a client
problem and can't be fixed client-side: the whole point of enforcing auth at the relay (the
host controls admission, not each joiner) means the protection only exists if the *relay*
process is current. If you're hosting: update the relay binary (`meshghost-server.exe` in a release zip,
`meshghost-relay.exe` when built from this repo), not just the client, before
relying on a room code. See the ADR in
[agent_docs/architecture.md](../agent_docs/architecture.md) for the full reasoning.

## What's already true, and why (checked against the actual code, 2026-08-15)

**No peer-to-peer connection exists.** Clients never connect to each other — only to the
relay (`relay`), a hub, not a mesh. A client has no mechanism to learn anything about
another player's network state, because no channel to another player's machine exists at all.

**No message type carries an IP address or other network-identifying field.**
`protocol/protocol.go`'s complete message set (`Hello`, `Welcome`, `Reject`, `Join`,
`Leave`, `State`, `Event`, `Lease`/`LeaseState`, `Escrow`/`EscrowState`, `World`/`WorldState`,
`Ping`/`Pong`, `Transports`) has no address field anywhere — `Reject`
carries only a reason string, and `Transports` (the transport-discovery reply, added 2026-08-16)
carries a kind and a **port** per offer, never a host: the client already knows an address, and a
relay bound to `0.0.0.0` doesn't. A client only ever learns a
peer's `player_id` and cosmetic state (position/area/anim/extras) — not even a chosen
`display_name`: `Hello.DisplayName` reaches the relay but is only logged there, never
redistributed to other clients (`Welcome.Roster` is just a list of ids, `Join` carries no name
either). See `agent_docs/ideas.md`'s nameplates entry if that's ever wired up for real.

**`player_id` is not derived from an IP.** It's a monotonic counter assigned by the relay
(`fmt.Sprintf("p%d", n)`, `relay/relay.go`'s `nextPlayerID`) — `p1`, `p2`, ... per
process lifetime, carrying no information about the connection it came from.

**The relay itself doesn't read a client's IP, and logs one only when TLS is enabled and a
connection is refused.** `relay`, `core` and `cmd/` contain no `RemoteAddr()` call site
(re-grepped 2026-08-19); the occurrences are in `netx/` -- the `net.Conn` method that
`netx/udpconn` and `netx/quicconn` must implement, plus a stub on a fake conn in `transport`'s own
tests -- plus `udpconn`'s own internal keying of its connection map by remote address, which is how
a single shared UDP socket is demultiplexed at all and is never surfaced upward or logged.

**The one exception, added 2026-08-19 with TLS over tcp:** `netx/tlsx`'s listener names the peer
address in two log lines — a plaintext connection refused under `"tls": "required"`, and a failed
TLS handshake. Both are refusals, both go only to the host's own `meshghost-server.log`, and
neither can happen at all while `tls` is `off`, which is the built-in default. It is a deliberate
narrowing of the property above rather than an oversight: "your friend cannot connect and the log
does not say who was turned away" is the support case this exists for. Nothing logs the address of
a connection that *succeeds*, so a normal session still leaves no IP anywhere. The relay is still the one party
that *could* see a real IP — it's the actual TCP endpoint every client connects to, which is
unavoidable for any relay architecture — but right now it doesn't even use that information.

**The adapter/core/relay split adds a second layer of isolation**, per
[agent_docs/contract.md](../agent_docs/contract.md)'s hard rule: an adapter (the game-side
script/plugin) never touches the network at all. It only
talks to its own local core process, over localhost, via the bridge. Only the core connects to
the relay. So even a fully compromised adapter has no path to learn anything about another
player's machine — it would have to compromise the core itself first, a separate process.

**Misbehavior limits exist and defend against both a malformed and a malicious peer**
(`relay/limits.go`, `protocol/limits.go`): `MaxLineBytes` (4096, now enforced
during the read itself, not after), `MaxExtrasBytes` (1024), `MaxPositionLen` (8),
`MaxOrientationBytes` (256), `MaxAreaIDLen`/`MaxAnimLen` (256), `MaxHelloFieldLen` (128),
`DefaultMaxClients` (8, server-wide across all rooms, configurable per relay),
`MaxMessagesPerSecond` (120 at the default 20Hz — a floor, not a flat cap: the real per-client
limit is `max(120, send_hz * RateLimitHeadroomMultiple)`, and that multiple is 6),
`DefaultHelloTimeout` (10s). The opt-in planes carry their own, in `protocol/online.go`
rather than `limits.go`: `MaxEventBytes` (1024), `MaxLeaseKeyLen` (128), `MaxEscrowBlobBytes`
(1024), `MaxWorldKeyLen` (64), `MaxWorldBlobBytes` (768), plus
`MaxLeasesPerRoom`/`MaxEscrowsPerRoom`/`MaxWorldKeysPerRoom`, which are per-room **memory** bounds
rather than per-message ones and are the only limits here of that kind. Those plane bounds are meant
to be derived from the udp datagram limit rather than `MaxLineBytes`, and two of them are not —
corrected 2026-08-18, pinned by tests in `netx/udpconn` rather than quietly reduced, and recorded as
an open decision in `agent_docs/risks.md`. What each limit does when it trips, and the full account
of that overshoot, are in [docs/networking.md](networking.md)'s "Limits and backpressure" section;
neither is repeated here. Originally
generous rather than tight (no-auth was the accepted state through Phase 4); audited with an
adversarial peer in mind as of the 2026-08-14 hardening pass — see "What changed" above and the
ADR in [agent_docs/architecture.md](../agent_docs/architecture.md).

## What is not yet true — known gaps

- **Since `world.v1` (2026-08-17) the relay RETAINS one client's opaque bytes and hands them to
  another, after the sender has gone.** Every earlier plane forwards and forgets, so a peer's bytes
  only ever reached someone connected at the time. World custody deliberately holds the latest blob
  per entity for a room's lifetime and hands the whole set to whoever takes the authority lease
  next — which is the entire point, and also the first mechanism by which a departed client's
  content reaches a stranger who arrived later. Bounded (`MaxWorldKeysPerRoom` x
  `MaxWorldBlobBytes`, ~58KB per room, freed with the room) and opt-in per room, so it is not a
  resource gap; what it is, is a new place a client could smuggle something into, and it is not
  inspected because by hard rule it cannot be. Same posture as `extras`, with a longer lifetime.
- **`tcp` is plaintext by default; `udp` always.** On `tcp` that is a default rather than a limit,
  since 2026-08-19: `"tls": "auto"` or `"required"` encrypts it, and the compiled-in default is off
  to keep the "greppable with netcat" debuggability property (see "Why TCP is the mandatory
  handshake leg" below); the shipped release config sets `auto`. On `udp` it
  is *unavoidable*, since Go's standard library has no DTLS. So with `tls` off a room code crosses
  either in the clear: anyone positioned between a client and the relay can read it. That is the
  honest ceiling of what room-code auth buys in that configuration — "anyone with the address and
  the code," not "safe against a network-level attacker." With `tls` on, `tcp` reaches quic's level
  below — encrypted, unauthenticated by default — and with a fingerprint pinned it goes one step
  *past* quic, because the pin covers the tcp leg and nothing else (see above).
  **`quic` is the exception, since 2026-08-16**: its handshake *is* TLS 1.3, so the session is
  encrypted and the source address cannot be forged. What it still does not give is proof of *who*
  the relay is — the certificate is self-signed and unverified, because `connect_to` is a bare IP
  with no CA and no hostname to check, and the `"tls_fingerprint"` pin does not reach this path at
  all. Closing that (by binding the room code to the TLS session)
  is scoped and unscheduled in [agent_docs/ideas.md](../agent_docs/ideas.md); the keying material
  it needs is confirmed reachable from a quic-go connection.
- **Room-code auth depends on the relay being current** — see "A new risk this creates" above.
  A stale relay binary silently provides none of the protection a client believes it configured.
- **Not exhaustively audited.** The 2026-08-14 pass fixed the concrete DoS/trust gaps found
  while scoping it (a real remote-OOM, a one-stalled-peer room freeze, the relay's roster being
  discarded client-side) — not a claim that every possible malicious-peer angle has been tried.
  A peer can still, for example, spam legitimate-looking rapid state changes right up to the
  rate cap. Revisit if a new concrete attack shape is found, the same way this pass was scoped
  from real findings rather than a hypothetical checklist.

## A constraint to protect going forward

Whatever the auth/room-code design ends up being, **it should not introduce a way for one
client to learn another client's IP or other real identity through the relay protocol.**
Server-side logging of IPs (for the relay operator's own moderation/debugging) is a different
and acceptable thing; anything that *echoes* connection info back to clients — e.g. a "room
member list" feature built naively — would break an invariant that currently holds for free.

That now covers a **world blob** as well as `extras`: it is opaque, retained for a room's lifetime,
and handed to clients its author never met, so anything an adapter puts in one should be treated as
published to the room's future members rather than sent to its current ones.

## Prior art: CelesteNet (researched 2026-08-13)

CelesteNet — an approved read-only design reference
([agent_docs/licensing.md](../agent_docs/licensing.md), MIT) — was read at the source to check this
posture against a shipped example in the same genre. Four conclusions came out of it and all four
are already reflected above: a self-hosted CelesteNet server is **also** open by default, so no-auth
is the normal baseline for a friend-hosted relay rather than a MeshGhost shortcut; its account/ban
system solves a problem only an always-on public server has, and was deliberately not copied; its
reject-at-handshake version check *was* the shape adopted here, for `protocol.Version` and, on
2026-08-14, for `game_version` and the room code; and its unpredictable per-connection UDP tokens
turned out to be necessary here too, once a udp transport existed (`netx/udpconn`, 2026-08-16).
Explicitly out of scope: their hardware-fingerprint anti-ban-evasion collection (machine GUID,
registry paths, MAC-derived identifiers), which conflicts directly with the constraint above.

## Why TCP is the mandatory handshake leg (recorded 2026-08-13; revised 2026-08-16 and 2026-08-19)

**tcp is not the default session, and has not been since 2026-08-16**, when the transport became a
`config.json` setting — `auto`, `tcp`, `udp` or `quic`. The client ships `auto` and the relay serves
`tcp,quic`, so a default pair runs quic and drops to tcp only when quic cannot be established (the
two transport ADRs in [agent_docs/architecture.md](../agent_docs/architecture.md)). What tcp still
is, is the **mandatory handshake leg and the universal fallback**: the only transport readable with
`netcat` or a packet capture while debugging — which it still is by default, and still is against a
relay running `"tls": "auto"` — the one that **did** gain optional TLS, on 2026-08-19, and the only
choice that changes nothing for an existing user. The reasoning below is why it holds those roles
rather than why it was once the default. Two things that reasoning did not anticipate: `udp` cannot
be encrypted at all in Go (no DTLS in the standard library), and QUIC gets the loss behaviour and
encryption together, so QUIC is the one to reach for rather than plain UDP if either matters. `udp`
and `quic` exist for the cases the reasoning genuinely does not cover — a lossy connection, or a
relay near the 100Hz ceiling — and, just as much, because having three implementations behind one
interface is what makes the "swappable network boundary" claim true rather than aspirational.

`transport` was TCP-only when this was written (NDJSON framing,
[agent_docs/contract.md](../agent_docs/contract.md)'s Transport section — it now applies that same
framing to whatever `net.Conn` `netx` hands it). This was never
actually written down as a deliberate choice against UDP until now — it fell out of "stdlib
TCP/JSON, debuggability beats bandwidth"
([agent_docs/architecture.md](../agent_docs/architecture.md)'s Go-decision ADR) rather than a
head-to-head comparison. Recording the comparison here since it came up directly while
scoping the relay-safety work.

Real-time games often prefer UDP because TCP's reliable/ordered delivery means one lost packet
stalls everything queued behind it ("head-of-line blocking") until it's retransmitted — bad
when a newer position update already superseded the lost one and you just want to render the
latest state, now. That tradeoff doesn't bite the way it would in a competitive shooter:

- **Send rate defaults to 20Hz, operator-configurable 10-100Hz** (`core.DefaultMinSendInterval`
  is the fallback when nothing else applies; the actual rate is
  `Core.effectiveSendInterval()` — the slower of a relay's advertised `Welcome.SendHz` and a
  client's own explicit `Core.MinSendInterval`, `core.go`; see the send/receive rate-control ADR
  in `architecture.md`), and rendering already runs `InterpolationDelay` (250ms default) behind
  the newest sample specifically to smooth network jitter. A TCP stall is at most one send
  interval (~50ms at the 20Hz default, as low as ~10ms at the 100Hz ceiling) — invisible against
  delay already absorbed by design at the default rate, not a new cost UDP would meaningfully
  remove; a relay configured near the 100Hz ceiling narrows that margin and is worth revisiting
  if this reasoning is ever re-checked.
- **Debuggability**: NDJSON-over-TCP is exactly why the relay protocol can be read with
  `netcat` and a human eye
  ([agent_docs/contract.md](../agent_docs/contract.md)'s framing rationale). UDP has no
  equivalent
  "greppable stream" property — each datagram would need its own framing, and there's no
  continuous stream to tap into the same way.
- **Security**: a real TCP handshake makes connection spoofing/hijacking hard by construction.
  This is *why* CelesteNet needs its own unpredictable-token generator for its UDP leg (see
  above) — a problem TCP doesn't have, and one we'd have to solve ourselves if we switched.
  **Update 2026-08-16: we did switch (as an option), and we did have to solve it.**
  `netx/udpconn` now implements both halves — an address-validation cookie gating
  admission, and exactly the kind of unpredictable per-connection token described here, required
  on every datagram afterwards. The point above stands as the reason tcp remains the default and
  the mandatory handshake leg: on tcp this protection is free, and on udp it is code we own and
  must keep correct.
- **NAT/reachability is identical either way**: MeshGhost is relay/star-topology, not P2P — no
  client ever connects directly to another client, only to the relay. UDP's actual advantage
  for reachability (hole-punching to skip port-forwarding for direct peer connections) doesn't
  apply, because there's no direct peer connection to punch a hole for.

**Caveat on the ~50ms figure above, added 2026-08-16 — it is optimistic.** A lost packet stalls
delivery until it is *retransmitted*, so the bound is retransmit timing, not send rate. Fast
retransmit needs three subsequent packets, which at 20Hz is already ~150ms, so the RTO timer —
floored near 200ms on common stacks — is likely to dominate instead. **This is reasoning, not a
measurement**: nobody has run MeshGhost over a genuinely lossy link and watched. It does not
change the conclusion (250ms of interpolation absorbs a lot, and a ghost is cosmetic), but the
number should be re-derived rather than cited if this comparison is ever re-opened.
