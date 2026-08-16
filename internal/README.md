# internal/ — security and privacy posture

This file describes what the Go networking layer (`core`, `relay`, `bridge`, `protocol`,
`transport`) does and does not protect against, and why. It exists so "is this safe to use
with people I don't know" has a real, checkable answer instead of a guess — see
[CLAUDE.md](../CLAUDE.md)'s "no addresses or APIs from memory" rule applied to security
claims, not just game memory.

**Bottom line up front, updated 2026-08-14: MeshGhost now supports room-code auth and a peer
game-version check, and the relay/core have been hardened against several concrete
malicious-peer attack shapes (see "What changed" below). It is safer to use with people you
don't personally know than it was — but two real limits remain, and neither is closed by this
work: there is no TLS, so a room code crosses the wire in plaintext (raises the bar from
"anyone with the address" to "anyone with the address and the code," not to "safe against a
network-level attacker"); and room-code auth is enforced entirely by the relay, so it provides
zero protection if the relay itself is an outdated build, regardless of what any client sends
or believes it configured — see "A new risk this creates" below.** Full record of this pass:
the ADR in [agent_docs/architecture.md](../agent_docs/architecture.md) (search
"room-code/version ADR").

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
- **A real remote-OOM, fixed**: `internal/transport`'s read loop used to buffer a line without
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
  `internal/core` logs a connect failure only when the message actually changes, so a long
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
relay (`internal/relay`), a hub, not a mesh. A client has no mechanism to learn anything about
another player's network state, because no channel to another player's machine exists at all.

**No message type carries an IP address or other network-identifying field.**
`internal/protocol/protocol.go`'s complete message set (`Hello`, `Welcome`, `Reject`, `Join`,
`Leave`, `State`, `Event`, `Ping`/`Pong`) has no address field anywhere — `Reject` carries only a
reason string. A client only ever learns a
peer's `player_id` and cosmetic state (position/area/anim/extras) — not even a chosen
`display_name`: `Hello.DisplayName` reaches the relay but is only logged there, never
redistributed to other clients (`Welcome.Roster` is just a list of ids, `Join` carries no name
either). See `agent_docs/ideas.md`'s nameplates entry if that's ever wired up for real.

**`player_id` is not derived from an IP.** It's a monotonic counter assigned by the relay
(`fmt.Sprintf("p%d", n)`, `internal/relay/relay.go`'s `nextPlayerID`) — `p1`, `p2`, ... per
process lifetime, carrying no information about the connection it came from.

**The relay itself doesn't currently read or log a client's IP.** `conn.RemoteAddr()` is not
called anywhere in `internal/` or `cmd/` (grepped, zero hits). The relay is still the one party
that *could* see a real IP — it's the actual TCP endpoint every client connects to, which is
unavoidable for any relay architecture — but right now it doesn't even use that information.

**The adapter/core/relay split adds a second layer of isolation**, per
[agent_docs/contract.md](../agent_docs/contract.md)'s hard rule: an adapter (the game-side
script/plugin) never touches the network at all. It only
talks to its own local core process, over localhost, via the bridge. Only the core connects to
the relay. So even a fully compromised adapter has no path to learn anything about another
player's machine — it would have to compromise the core itself first, a separate process.

**Misbehavior limits exist and defend against both a malformed and a malicious peer**
(`internal/relay/limits.go`, `internal/protocol/limits.go`): `MaxLineBytes` (4096, now enforced
during the read itself, not after), `MaxExtrasBytes` (1024), `MaxPositionLen` (8),
`MaxOrientationBytes` (256), `MaxAreaIDLen`/`MaxAnimLen` (256), `MaxHelloFieldLen` (128),
`DefaultMaxClients` (8, server-wide across all rooms, configurable per relay),
`MaxMessagesPerSecond` (120 at the default 20Hz — a floor, not a flat cap: the real per-client
limit is `max(120, send_hz * RateLimitHeadroomMultiple)`, and that multiple is 6),
`DefaultHelloTimeout` (10s). Originally
generous rather than tight (no-auth was the accepted state through Phase 4); audited with an
adversarial peer in mind as of the 2026-08-14 hardening pass — see "What changed" above and the
ADR in [agent_docs/architecture.md](../agent_docs/architecture.md).

## What is not yet true — known gaps

- **No TLS.** `internal/transport` is plaintext NDJSON over TCP — deliberate, for the
  "greppable with netcat" debuggability property (see "Why TCP, not UDP" below). A room code
  therefore crosses the wire in the clear: a network-level attacker positioned between a client
  and the relay can read it. This is the honest ceiling of what room-code auth buys — "anyone
  with the address and the code," not "safe against a network-level attacker."
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

## Prior art: how CelesteNet handles this (researched 2026-08-13)

CelesteNet is already an approved read-only design reference
([agent_docs/licensing.md](../agent_docs/licensing.md), MIT).
Read its actual server source (not assumed) via `gh api` against `0x0ade/CelesteNet` before
writing any of this — findings below are cited to real files, not memory.

- **Self-hosted CelesteNet is open by default too.**
  `CelesteNetServerSettings.AuthOnly` defaults to `false`
  (`CelesteNet.Server/CelesteNetServerSettings.cs`) — a self-hosted server accepts any client
  with just a display name, no key required
  (`CelesteNet.Server/ConPlus/HandshakerRole.cs`'s `AuthenticatePlayerNameKey`, the
  `else if (!Server.Settings.AuthOnly)` branch). Their baseline posture is the same as ours
  today — no-auth isn't a MeshGhost-specific shortcut, it's the normal default for a
  friend-hosted relay in this genre.
- **Key-based auth exists, but it's scoped to their one large public server, not the
  baseline.** A `#<key>` prefix on the player name maps to a persistent account UID
  (`Server.UserData.GetUID`), checked against a stored ban list on connect. This solves a
  different problem than ours: an always-on server open to the whole internet needs a
  persistent identity for a ban to mean anything. A friend-hosted session with a shared
  address/room code doesn't have that problem — mirroring their full account+ban system would
  be over-engineering for MeshGhost's actual model, unless an always-on public relay ever
  becomes a real goal (it isn't one today).
- **Version check at connection time, before any data flows**: a
  `CelesteNet-TeapotVersion` header, server responds `409 Version Mismatch` on anything but an
  exact match (`HandshakerRole.cs`'s `TeapotHandshake`). We already do the direct equivalent
  for our own wire protocol (`protocol.Version`, checked in `hello` at
  [relay.go:643](relay/relay.go#L643)) — and, since 2026-08-14, the same reject-at-handshake
  shape for each adapter's own `game_version` too (see "What changed" above).
- **Unpredictable per-connection tokens** (`CelesteNet.Shared/TokenGenerator.cs`, a Galois
  LFSR) specifically prevent a third party from hijacking someone else's *UDP* connection by
  guessing or spamming its token. This defends against a UDP-specific weakness (UDP is
  connectionless and trivially spoofable) that doesn't apply to us — `internal/transport` is
  TCP-only, which already closes this class of attack by requiring a real handshake per
  connection. Not something to port.
- **Deliberately not a model to copy**: `CelesteNet.Server/ConPlus/ExtendedHandshake.cs`
  collects machine GUID / registry paths / MAC-derived identifiers as a hardware-fingerprint
  anti-ban-evasion check for their public server. That's real, invasive identity collection,
  and it directly conflicts with the "constraint to protect" above and this project's own
  privacy posture. Explicitly out of scope here regardless of what CelesteNet does.

**Takeaway for our own design**: aim for the *shape* of their version-check pattern (a shared
secret checked once at handshake, reject outright on mismatch, before any state is exchanged)
for room codes — not their full public-server account/ban/fingerprinting stack, which solves a
problem MeshGhost doesn't have. **Implemented 2026-08-14** — see "What changed" above.

## Why TCP, not UDP (recorded 2026-08-13 — no prior ADR existed for this)

`internal/transport` is TCP-only (NDJSON framing,
[agent_docs/contract.md](../agent_docs/contract.md)'s Transport section). This was never
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
  in `architecture.md`), and rendering already runs `InterpolationDelay` (100ms default) behind
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
  Given relay safety is the current priority, this is a real point in TCP's favor right now,
  not just a wash.
- **NAT/reachability is identical either way**: MeshGhost is relay/star-topology, not P2P — no
  client ever connects directly to another client, only to the relay. UDP's actual advantage
  for reachability (hole-punching to skip port-forwarding for direct peer connections) doesn't
  apply, because there's no direct peer connection to punch a hole for.

**Conclusion: TCP remains the right choice.** Worth revisiting only if MeshGhost's update rate
or player count ever grows enough that head-of-line stalls become perceptible against
`InterpolationDelay` — not the case today, and not close to it.
