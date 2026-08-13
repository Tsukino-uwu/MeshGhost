# internal/ — security and privacy posture

This file describes what the Go networking layer (`core`, `relay`, `bridge`, `protocol`,
`transport`) does and does not protect against, and why. It exists so "is this safe to use
with people I don't know" has a real, checkable answer instead of a guess — see
`CLAUDE.md`'s "no addresses or APIs from memory" rule applied to security claims, not just
game memory.

**Bottom line up front: MeshGhost is currently safe to use with a friend you directly hand an
address to. It is not yet safe to expose to strangers or post publicly.** The gap is tracked
as the current priority — see `agent_docs/risks.md`'s "No-auth relay window" entry and
`agent_docs/plans.md`'s "Next priority — Room codes / relay safety" section.

## What's already true, and why (checked against the actual code, 2026-08-13)

**No peer-to-peer connection exists.** Clients never connect to each other — only to the
relay (`internal/relay`), a hub, not a mesh. A client has no mechanism to learn anything about
another player's network state, because no channel to another player's machine exists at all.

**No message type carries an IP address or other network-identifying field.**
`internal/protocol/protocol.go`'s complete message set (`Hello`, `Welcome`, `Join`, `Leave`,
`State`, `Event`, `Ping`/`Pong`) has no address field anywhere. A client only ever learns a
peer's `player_id`, chosen `display_name`, and cosmetic state (position/area/anim/extras).

**`player_id` is not derived from an IP.** It's a monotonic counter assigned by the relay
(`fmt.Sprintf("p%d", n)`, `internal/relay/relay.go`'s `nextPlayerID`) — `p1`, `p2`, ... per
process lifetime, carrying no information about the connection it came from.

**The relay itself doesn't currently read or log a client's IP.** `conn.RemoteAddr()` is not
called anywhere in `internal/` or `cmd/` (grepped, zero hits). The relay is still the one party
that *could* see a real IP — it's the actual TCP endpoint every client connects to, which is
unavoidable for any relay architecture — but right now it doesn't even use that information.

**The adapter/core/relay split adds a second layer of isolation**, per `agent_docs/contract.md`'s
hard rule: an adapter (the game-side script/plugin) never touches the network at all. It only
talks to its own local core process, over localhost, via the bridge. Only the core connects to
the relay. So even a fully compromised adapter has no path to learn anything about another
player's machine — it would have to compromise the core itself first, a separate process.

**Basic misbehavior limits exist and defend against a malformed peer** (`internal/relay/limits.go`):
`MaxLineBytes` (4096), `MaxExtrasBytes` (1024), `MaxPositionLen` (8), `MaxClientsPerRoom` (8),
`MaxMessagesPerSecond` (120). These stop a broken or careless client from corrupting a room for
everyone else in it (an oversized payload, a runaway send loop). They are explicitly **not**
a defense against a determined attacker — generous, not tight, exactly because no-auth was the
accepted state through Phase 4 (see the relay-auth ADR in `agent_docs/architecture.md`).

## What is not yet true — known gaps

- **No authentication.** Anyone who has the relay's address can connect and join a room. There
  is no room code, password, or invite mechanism. This is the main reason MeshGhost isn't
  currently safe with strangers.
- **No peer game-version check.** `hello` carries `game_id` but nothing about version or
  installed DLC — two peers on incompatible game versions connect and exchange state without
  any warning that `area_id`/`anim` might mean different things to each of them.
- **No protection against a *malicious* (not just malformed) peer specifically** — the limits
  above bound size/rate, not intent. A peer could still, for example, spam legitimate-looking
  rapid state changes right up to the rate cap, or send deliberately confusing (not oversized)
  `extras` content. Not yet audited with an adversarial mindset; the "Next priority" work in
  `agent_docs/plans.md` should include this, not just auth.

## A constraint to protect going forward

Whatever the auth/room-code design ends up being, **it should not introduce a way for one
client to learn another client's IP or other real identity through the relay protocol.**
Server-side logging of IPs (for the relay operator's own moderation/debugging) is a different
and acceptable thing; anything that *echoes* connection info back to clients — e.g. a "room
member list" feature built naively — would break an invariant that currently holds for free.

## Prior art: how CelesteNet handles this (researched 2026-08-13)

CelesteNet is already an approved read-only design reference (`agent_docs/licensing.md`, MIT).
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
  [relay.go:304](relay/relay.go#L304)) — but that only covers *our* protocol version, not each
  adapter's underlying game version/DLC, which is the still-open "no peer game-version check"
  gap above. Worth copying the *pattern* (reject outright at handshake, before any state
  exchange) for that gap too, once it's designed.
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
problem MeshGhost doesn't have.

## Why TCP, not UDP (recorded 2026-08-13 — no prior ADR existed for this)

`internal/transport` is TCP-only (NDJSON framing, `contract.md`'s Transport section). This was
never actually written down as a deliberate choice against UDP until now — it fell out of
"stdlib TCP/JSON, debuggability beats bandwidth" (`architecture.md`'s Go-decision ADR) rather
than a head-to-head comparison. Recording the comparison here since it came up directly while
scoping the relay-safety work.

Real-time games often prefer UDP because TCP's reliable/ordered delivery means one lost packet
stalls everything queued behind it ("head-of-line blocking") until it's retransmitted — bad
when a newer position update already superseded the lost one and you just want to render the
latest state, now. That tradeoff doesn't bite the way it would in a competitive shooter:

- **Send rate is capped at 20Hz** (`Core.DefaultMinSendInterval`, `core.go`), and rendering
  already runs `InterpolationDelay` (100ms default) behind the newest sample specifically to
  smooth network jitter. A TCP stall is at most ~50ms at this rate — invisible against delay
  we already absorb by design, not a new cost UDP would meaningfully remove.
- **Debuggability**: NDJSON-over-TCP is exactly why the relay protocol can be read with
  `netcat` and a human eye (`contract.md`'s framing rationale). UDP has no equivalent
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
