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
              │        RELAY PROTOCOL — tcp / quic                   │
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

### You trust whoever hosts (2026-09-11)

**"Opaque by hard rule" is a discipline, not cryptography.** The relay terminates the connection, so
TLS and quic protect your bytes *in transit* and not *from the server*. The shipped relay never
interprets a payload — but a host running a modified build could read what arrives, and nothing in
the protocol would reveal that. Every hardening pass below defends the relay and its clients against
a malicious *peer*; none of it defends a client against a malicious *host*, and none of it can.

**What that exposes is bounded by what a client ever sends**: your IP, your display name if you set
one, which room and game you are in, and your position/animation stream. It cannot reach your save,
your game files or anything else on disk — not because the relay refuses to ask, but because nothing
ever reads them. An adapter holds a socket to its own local core and nothing else, so there is no
path from your disk to the wire for a hostile server to pull on.

**Closing the gap would mean end-to-end encrypting payloads** under a key derived from the room code,
so the relay routes without holding readable bytes. It would fit — even the retained `world.v1` blob
is already opaque to the relay — but it turns the room code into a real secret with real key
distribution, to protect a character's coordinates from someone you chose to connect to. Not worth it
while hosting is friend-to-friend; revisit if public or third-party hosting ever becomes normal.

### What is and is not secure, per transport

| Transport | Encrypted? | Authenticated? | Notes |
| --- | --- | --- | --- |
| **tcp** | **Always**, TLS 1.3 (since 2026-09-15; no mode, no plaintext fallback on either side) | **Remembered**: the client checks the server's certificate against what it saw on the first connection | A plaintext connection is closed by the server and a plaintext server is refused by the client. Always carries the handshake. |
| **quic** (default) | **Yes**, TLS 1.3 | **Remembered**, the same entry as tcp — the server presents one certificate on both | Stops a passive eavesdropper on every connection. An active man-in-the-middle is noticed from the second connection on (a changed identity is warned about, loudly), not on the first. |
| **udp** | **No** | No | **Not shipped since 2026-09-15** (ADR 0065): Go's standard library has no DTLS, so it could never be encrypted, and it rescued no player quic could not. A release refuses the name; the code is a dev build's comparison tool. |

So the honest summary is **always encrypted, and the server is recognised from the second
connection on**. A room code raises the bar from "anyone with the address" to "anyone with the
address and the code" — not to "safe against a network-level attacker".

**How the server is recognised (since 2026-09-15, ADR 0066).** Every server has a persistent
identity: a certificate it generates on its first start and keeps in a `tls\` folder beside its
`config.json` (`relay.key`, `relay.crt`, `relay.fingerprint`), served on tcp and quic alike so one
server has one fingerprint. Every client remembers each server's fingerprint under the address it
configured, in `tls\known_relays.json` beside its own `config.json`, on the first connection, and
checks every later connection — the tcp handshake, the tcp session, the quic session — against
that entry. This is the SSH model, trust on first use: the first connection cannot be checked
against anything, and from then on a different certificate at the same address is **noticed**.
Nobody copies a string, edits a file or deletes one; the two files are written and read by the two
programs.

**What happens when the identity changes** — the host reinstalled, moved the server to a fresh
folder, deleted `tls\`, or someone is impersonating it — is, for now, a **warning, not a
refusal**: the client logs both fingerprints in a block that says the host should compare the one
their server prints at startup, updates its entry, and connects, still encrypted. SSH refuses
instead, and then a human deletes a line from a file; the user's requirement is that nobody ever
does that. What will settle a change instead is the room code, used as a proof that never crosses
the wire (a PAKE bound to the TLS connection — the next piece of this work, chosen and not yet
built; [agent_docs/tls-planning.md](../agent_docs/tls-planning.md) step 5): with a code set, a
changed identity will be *proven* by the code or *refused*. Until then a host who reinstalls costs
each returning player one loud line, and a host who wants to be sure can read their fingerprint
line to a player over chat and have the player compare it with the warning.

**There is no mode and no plaintext fallback, on either side.** A server closes a connection that
does not begin with a TLS handshake (one throttled log line says so); a client sends nothing —
not a hello, not a room code — to a server that does not complete one, on the discovery leg and
the session leg alike, on every reconnect. Until 2026-09-15 there was a three-way `tls` setting:
`auto` on the client fell back to plaintext once, with a warning, so a client could still reach a
relay built before TLS existed, and the fourth adversarial review showed what that cost — *any*
failed handshake took the fallback (a reset, a dropped ClientHello, the 3 s discovery timeout), the
plaintext redial carried the room code, and a middlebox that resets TLS on a non-443 port did it by
accident. Nor could the allowance be kept for old relays, because a plaintext relay never answers a
ClientHello with bytes, which is exactly what an attacker blackholing the handshake looks like.
Every release since 2026-08-19 speaks TLS, so the fallback went, and the same day the mode and the
hand-copied `tls_fingerprint` pin went with it. A `config.json` still saying `"tls": "off"` or
`"auto"`, or carrying a pin, refuses to start and says what replaced it, rather than quietly
meaning something else.

There is no CA anywhere in this design and none is planned: `connect_to` is a bare IP, and there is
no name a certificate could be checked against.

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

**Bottom line up front, current as of 2026-09-11.** MeshGhost supports room-code auth and a peer
game-version check, and the relay/core have been hardened against several concrete malicious-peer
attack shapes (the 2026-08-14 pass, see "What changed" below). It is safer to use with people you
don't personally know than it was. **Every connection is encrypted, on every transport, with no
setting** (since 2026-09-15): `quic`, the default session path since 2026-08-16, was always TLS
1.3; `tcp` gained optional TLS on 2026-08-19 and unconditional TLS on 2026-09-15; plain `udp`,
which could never be encrypted, stopped shipping the same day. Certificates are self-signed — there
is no CA for a bare IP — and **a client remembers each server's certificate from its first
connection and checks every later one against it**, so a passive eavesdropper is stopped always and
an active man-in-the-middle is noticed from the second connection on (see "What is and is not
secure" above for what a changed identity does today). All of this raises the bar from "anyone
with the address" to "anyone with the address and the code," not to "safe against a
network-level attacker" — and room-code auth is enforced entirely by the relay, so it provides zero
protection if the relay itself is an outdated build, regardless of what any client sends or believes
it configured (see "A new risk this creates" below). Full record of the 2026-08-14 pass: ADR 0013, indexed in
[agent_docs/architecture.md](../agent_docs/architecture.md) as "Add room-code auth and a peer
game-version check to `hello`".

## How a client actually connects, and why it matters here

**Every client handshakes over tcp, always, and no config setting can change that.** `"transport"`
in `config.json` is not *how* you connect — it is what you move to *once* connected. The mechanics
— the query-only handshake, the offer list, what happens when a relay does not serve the preference
you asked for — are in [docs/networking.md](networking.md)'s Transports section, which is the
canonical description; they are not repeated here.

The security consequence is the part that belongs here: the handshake, and therefore the room-code
check, **always happens over tcp**. The room code crosses that leg **in addition to**, not instead
of, the session leg — the check sits ahead of the query-only branch in the relay, so the discovery
query must carry the code, and the joining connection (quic by default) sends it again and is
checked again independently.

**That is why TLS over tcp matters even for a session that ends up on quic, and it is stronger
than "belt and braces": with `tls` off, an eavesdropper reads the room code from the plaintext
discovery query and can then join over quic perfectly normally. Quic's encryption cannot protect
a secret that already leaked on the other leg.** Since 2026-09-15 that leg is always TLS, the
server's one certificate is checked on it exactly as on the quic leg, and plain `udp` no longer
ships. See "known gaps" below for what remains.

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
  version, mismatched feature set, a game this relay does not host, a field over its length
  bound, full room) now gets a `reject` message with a reason before the connection closes,
  instead of a bare hangup indistinguishable from "the relay is just slow or down." A joined
  client that trips the flood cap gets one too (`rate limited`, retryable).
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
  whole process, so the relay and the client can be started in either order. Which refusals are
  permanent and which are retried is pinned by `TestConnectRelayOnAdapterHelloCachesPermanentReject`
  and `TestRateLimitedRejectIsRetryableUnlikeAConfigReject` (`core`).
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

## What changed (2026-09-02 adversarial review)

The first pass that read this code the way an attacker would: five reviewers given only the code
and "break this", one attack class each (resource exhaustion, protocol state and trust, the
transport layer, the peer-to-adapter path), plus one checking every claim on this page against the
code as it stood. Method, findings, fixes and what was deliberately left alone:
[agent_docs/adr/0044](../agent_docs/adr/0044-2026-09-02-the-first-adversarial-review-and-what-it-changed.md).
Every fix below has a regression test that failed before it. Ranked by what it cost a host.

- **One spoofable UDP datagram no longer kills the relay.** A datagram over 1200 bytes made
  Windows hand the read loop an error alongside the bytes; the loop closed the listener, and the
  relay binary treats that as fatal — tcp and quic died with it. No handshake, any source address.
  The client side had the same hole against a player's port. Now read into a 64 KiB buffer and
  dropped. The fuzzer had never seen it because it truncated its own inputs to that same limit.
- **Descriptor exhaustion is no longer a remote crash.** `Serve` retries a temporary `Accept`
  error (EMFILE) with backoff instead of returning.
- **Connections that have not said hello are bounded.** Previously only *joined* clients counted
  toward anything; a stranger could hold thousands of pre-hello connections at a few bytes each.
  Now every listener closes connections past `relay.MaxOpenConnsFor` (8 per seat, floor 64),
  counted beneath the TLS layer so a parked handshake counts too; refusals are logged once a second.
- **One member can no longer refuse every trade in an `escrow.v1` room.** Terminal records kept
  for `EscrowRetention` counted toward the room's cap, so 64 open-then-abort pairs — under the
  flood cap — rejected everyone else's opens for `EscrowRetention` (60s), renewably. An opener now
  holds at most 8 live exchanges (`MaxLiveEscrowsPerMember`) and terminal records stop counting
  toward the room cap. Revised again on 2026-09-08: counting only live exchanges left the table
  itself bounded by nothing but rate × retention, and the full-table scan ran under the room lock on
  every open. It is now O(1) off maintained counters, with the table bounded by evicting the oldest
  terminal record — so the 2026-09-02 property that a dead exchange costs nobody a slot still holds,
  by a different mechanism.
- **QUIC validates source addresses.** Every unvalidated Initial gets a Retry first, so a spoofed
  packet costs a stateless reply rather than a TLS handshake and five seconds of half-open state,
  and the 3x reply toward the spoofed address is gone. Incoming streams are limited to the one
  the protocol uses and receive windows shrink from 512 KiB/1.5 MiB to 64/256 KiB.
- **Pre-hello log amplification closed.** An oversized line's head was logged quoted up to 16000
  bytes — 4 KB of NULs became 16 KB of log per unauthenticated connection. The head is 96 bytes.
- **The core's roster is bounded** (`MaxRosterSize`, 512). A hostile or broken relay could announce
  ids without end and every shipped adapter spawns a ghost per id with no count of its own.
- **The log is bounded for the life of the process.** Both binaries rotated their log at startup
  only, so a long-running relay grew it without bound, and under a connection flood that was
  a disk filled from outside. The writer now rotates itself at 1 MiB, keeping one generation.
- **Release binaries are reproducible.** Built with `-trimpath` and no cgo, so a build of the
  same tag with the same Go version is byte-identical to the shipped asset — the digest GitHub
  shows beside it now proves provenance, not just an intact download. Recipe in
  [reviewing.md](reviewing.md).
- **Dependencies are checked against the Go vulnerability database on every push**
  (`govulncheck`, CI's "Known vulnerabilities" job), and `.github/SECURITY.md` says how to
  report a finding.
- **Adapter-side input hardening, built and deployed but not yet watched:** Pseudoregalia bounds a
  peer's afterimage spawn count (it was written straight into the game's own spawn count), zeroes a
  non-finite orientation, and caps remembered nametags; Crystal's main loop runs under `pcall` so
  one bad field no longer ends the script; Emerald accepts only the two gender values its frame
  tables know; TEVI treats a non-finite `anim_t`/`pause` as absent.

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

## What changed (2026-09-05 and 2026-09-06: a refusal that could not be heard)

Two fixes to the same defect, a day apart, both found by CI's Linux runner and **neither
reproducible on the developer's Windows machine** — 40 consecutive local runs for the first, 30
under `-race` for the second. Full reasoning:
[agent_docs/adr/0055](../agent_docs/adr/0055-2026-09-05-the-relay-half-closes-and-drains-instead-of-resetting.md).

- **A `reject` the relay had already written could be discarded before the client read it.**
  Closing a TCP connection while the peer's data sits unread makes the kernel answer with a RESET
  rather than a FIN, and a reset **throws away what is still queued unread in the peer's receive
  buffer — including the line just sent**. Every place the relay hangs up is a place it has
  probably not drained the client, so the messages most at risk were the ones that matter: the
  `reject` telling a rate-limited client why it was cut off (2026-09-05), and the `reject` refusing
  a `hello` at handshake (2026-09-06).

  **Why this is a security-relevant bug and not just a lost message: it turned a PERMANENT refusal
  into a retry loop.** With no reason on the wire, a client sees only EOF, classifies it as a
  transient drop, and reconnects — so a wrong room code or a version mismatch produced an
  indefinite reconnect cycle against the relay instead of a refusal the player could read. The
  relay was correctly refusing admission and the client could not tell.

  Fixed by half-closing and draining (`transport.NDJSONConn.CloseGracefully`, 2s) at all three
  sites the relay writes-then-closes. A transport that cannot half-close falls back to the previous
  behaviour, so udp and quic are unchanged.

- **Worth stating plainly for anyone reading this page as a reviewer:** the 2026-09-05 fix *looked*
  complete. It repaired the path its failing test named and left the handshake path — same class,
  same reset, different call site — untouched until CI found that one on 2026-09-06. Fixing the
  site a test names is not the same as fixing the class it belongs to.

## What changed (2026-09-07 and 2026-09-08: the drain window, and four review findings)

**A refused peer could still complete a join.** The 2026-09-05/06 fix above made a rejected
connection half-close and drain rather than reset, so the client could actually read the reason it
was refused. That drain left a window: the socket stays readable, and nothing stopped a second,
**valid** `hello` arriving inside it. A peer refused for a bad room code could pipeline another one
and complete a genuine join over a half-closed socket — taking a `max_clients` slot and spawning a
ghost on every real player's screen — and could keep the relay writing log lines for it, all
unauthenticated. The fix is a latch: `rateRejected || handshakeRejected` is checked at the very top
of `OnReceive`, before the flood cap and before any decode, so a connection that has been refused
once is deaf for the rest of its life (`relay/relay.go`).

**Four smaller findings the same week**, each with a test that fails without its fix:

- **A sender could build a line the receiver would refuse.** `protocol.MaxLineBytes` is 4096 and the
  check compared against it, so an envelope of exactly 4096 passed, went out, and killed the
  receiver's read loop with the very `ErrTooLong` the check existed to prevent.
  `protocol.MaxPayloadBytes` is now 4095 — the largest line a receiver will actually accept — and
  senders size to that (`protocol/limits.go`).
- **The room code could reach the process list.** Passing `-room-code` on the command line put the
  secret in argv, where any local user can read it; the flag's help now says so and points at the
  config file (`cmd/meshghost-relay/main.go`).
- **A log rotation that failed retried forever**, tightly, instead of backing off
  (`internal/cfg/cfg.go`).
- **One bad value in a config file discarded the rest of it.** Everything else in the file now still
  applies, and the bad value is reported rather than silently taking the whole file with it
  (`internal/cfg/cfg.go`).

## What changed (2026-09-08 to 2026-09-11: the udp connect window, a listener that stopped, and the last blocking write)

**An off-path attacker could hijack a udp client's session token.** During the connect exchange the
client read its cookie and per-connection token off an *unconnected* socket, with `ReadFromUDP`, and
discarded the sender's address. Anything arriving on that port in that window was believed — so an
attacker spraying the ephemeral range during the handshake could make a client adopt a token the
relay never issued, after which every datagram it sent was dropped and the session simply never
worked. This is the same connect window the cookie and token above are described as protecting;
they do protect it now (`netx/udpconn`).

**The relay could silently stop accepting TCP for the life of the process.** The sniffing listener
is always in the tcp path (then because `tls=auto` was the shipped default; since 2026-09-15
unconditionally). Its accept loop
returned on the *first* `Accept` error of any kind; `Serve` then retried, as the 2026-09-02
descriptor-exhaustion fix above has it do, and the retry blocked forever on a channel nothing would
send to. So for six days the EMFILE hardening recorded above was defeated by the wrapper sitting in
front of it, and a relay could go deaf with its window still open (`netx/tlsx`).

**An oversized `welcome` killed joiners again, at a fifth of the expected player count.** The
roster cap added on 2026-09-01 was sized on bytes in hand — but `SanitizeDisplayName` permits `&`,
`<` and `>`, and `encoding/json` escapes each to six characters, so a maximal entry is about 173
bytes rather than the ~67 assumed. Measured: 3973 B at 21 members and 6019 B at the cap of 32,
against `MaxLineBytes` 4096. Past that the *joining* client's scanner dies with "token too long" —
the exact incident the cap was written to prevent. The bound is now the marshalled envelope itself,
so it cannot be wrong again for a reason nobody predicted, and it applies to the resume path, which
had had no bound at all.

**Two more from that pass are peer-triggerable**, both `resume.v1`: an unbounded resume snapshot
against a 256-line outbox meant one member holding many leases could make **another player's**
resume disconnect-loop; and `handleWorld`'s default arm treated any unknown op as a *set*, so the
entity cap rested on a check in another package. Both fixed with tests. Same week, smaller:
`State.Timestamp` gained bounds ("three reported defects were one missing check"), and the core's
bridge admission, which was checked on `hello` only, so anything that was not a hello got in.

**A stalled relay could freeze the game.** `sendState` wrote the relay socket synchronously, on the
bridge connection's read goroutine. A relay that stopped reading — a saturated uplink, a swapping
box — blocked that loop for the whole ten-second write deadline; the bridge socket's buffer then
filled and the adapter's next write blocked **on the game's main thread**. A frozen game, on a
machine where nothing was wrong, because something on the far side of the internet stopped reading.
The core→relay direction is now a bounded queue with its own writer goroutine
(`core/relaywriter.go`), matching the core→adapter one added 2026-09-07 and the relay's own from
2026-08-28. This was the last frame-path socket write in the process.

**Three smaller ones, each visible to a player rather than an attacker:**

- **`config.json` is re-read while the client runs** (2026-09-09), and `room_code` was among the
  values that took effect without a relaunch, alongside the then-existing `tls` and
  `tls_fingerprint` (both keys gone since 2026-09-15). A change made the client leave the relay
  and rejoin. The **relay** does not re-read its config; it restarts. (Superseded 2026-09-12: see
  the third review's section — where you connect is no longer live.)
- **A key that is not a setting says so** (2026-09-11). A misspelled key used to parse, be ignored,
  and leave the setting at its default in silence — the same class of mistake as a wrongly-typed
  value, and on record as having cost a tester their room code. The client and relay now name such
  keys in the log (`internal/cfg`). Keys the file carries for the game's mod are declared as such,
  so they are not reported as typos.
- **An adapter declares the oldest relay it will work with** (2026-09-11, ADR 0059), and a floor
  never moves by itself.

**Code signing** got its two prerequisites on 2026-09-06 — the policy page and a Windows version
resource on both executables — which is what [code-signing.md](code-signing.md) describes. The
releases are still unsigned, and that page says who holds the keys (nobody).

## What changed (2026-09-12: the third adversarial review, worked to the end of what it found)

Seventeen reviewers were planned, split by **who is attacking whom** rather than by which file they
read — because the pass before this one split by component, and a component split cannot see a seam
that lives between two correct-looking halves. Ten finished. Everything below is from those ten;
what the other seven would have found is not known, and the gap is named in the bullet above rather
than quietly left out.

**A relay you connected to could kill your game's bridge, and it took no invalid message to do it.**
Two ways, both fixed. The core kept a nametag for every id a relay ever mentioned, with no cap and
no clearing when the connection ended — and hands the whole set to the next adapter that attaches,
one message each, on a lane that cannot coalesce. Past the queue limit the core calls the adapter
stuck, closes its socket and tears down the ghosts, the chasers, the replays and any recording in
progress; then the next game launch does it again, for as long as the process lives. Separately, the
core forwarded `event`, `lease_state`, `escrow_state` and `world_state` to the game with **no check
that the room had negotiated that plane at all**, while every matching send path did check — and an
empty event is a legal event, so repeating one filled the same queue to the same end.

**A relay could also make a client's ghosts freeze, or never despawn.** `Pong.ServerTimeMs` was
bounded by nothing and the client's clock only ever moves forward, so one reply moved it **82.7
years** — measured — after which every ghost in the room ages out on every frame. A peer's timestamp
was likewise trusted for "have we heard from them lately", and the schema allows the year 2109, so
one state dated ahead made a peer permanently undespawnable, holding a seat in a room that holds
512. The reconnect backoff never survived a reconnect either: a relay that welcomed a client and
immediately dropped it got an unlimited free redial, at round-trip speed.

**A replay clip somebody sends you is a stranger's file, and the budget guarding it counted the
wrong thing.** Clips are shared — the docs suggest zipping one to send it — and everything in
`replay/active/` is loaded the moment a game launches. The size limit counted SAMPLES, sized on an
assumption of 128 bytes each, which is true of an empty sample and of nothing else. Measured this
day: a 596-byte line of nested `extras` costs **21.9 KB** held, so the accepted file count asks for
**40 GB**. The line length is not a usable proxy either — the worst case is the *smallest* of the
big lines — so the budget now charges what a sample actually costs. Four more from the same file: a
zip's clip COUNT was bounded by nothing (100 KB of archive yields 552 ghosts, each taking one of the
512 seats real players share), a clip's `speed` could wrap the playback timer negative into a busy
loop, one input track re-allocated per clip that matched it, and a zip's input track was handed to
adapters that never asked for one.

**In a room, one member's message rate decided things for everybody else.** A lease renew that
changed nothing was broadcast to the whole room and counted against no table, so it fanned out at
whatever rate the holder liked. Alternating your own `area_id` made the relay re-seed you with every
peer in the area, once per message. The per-connection flood cap was a tumbling window, so twice the
limit crossed a boundary — minor alone, and it multiplied both of those. And three bounded
structures chose what to discard by age alone, in the three places where a third party controls the
age: a committed trade outcome whose party was still away, a disconnected member's addressed
messages against a flood of broadcasts, and the trade section of a resume overrunning the budget the
world, lease and position sections share.

**Where you connect is no longer live-editable.** Saving `config.json` still applies your name,
colours, smoothing, chaser, replay and hotkey settings without a relaunch — but `connect_to`, `room_name`
and `room_code` now wait for one. A live re-read meant any other program on your PC able to write
that file could move you into someone else's room while you played, with nothing on screen saying
so. The counter-argument, that such a program could kill the client anyway, argues one hole is no
worse than another rather than that this one should stay open.

**Two more on the bridge.** The buffer holding your recent play for the save-last hotkey was bounded
by TIME and not by COUNT — and the ring beside it, which already had both, says so in its own
comment and names this one as the buffer that only got half of it. It also stayed armed after the
game closed. And a connection to the bridge port whose first line is not the protocol is now hung up
on rather than ignored, which is what stops a web page POSTing at `127.0.0.1:7778` and having its
headers skipped until the part it chose arrives as a line the bridge reads.

**In TEVI**, a peer could name unlimited "summon" types and have the game create a full character
rig for each one, on your machine, until it ran out of memory. It is capped at four now, sized from
the two the game itself can produce. Three smaller ones beside it, including a pooled effect a ghost
had borrowed being marked as ours forever — which quietly stopped YOUR own effects from reaching
other players, later and later into a session.

**Two of the review's own claims did not survive being read**, and they are recorded because a
review that is never wrong is a review nobody checked: one described the documented design of a
setting as a defect, and another called two collections memory leaks when they are bounded by the
game's own object pools. Reading the second found a real bug underneath it anyway.

## What changed (2026-09-15: hosting on the internet, the fourth review)

**The question was a host's, this time.** Someone hosting a Pokémon Crystal randomizer community
asked, before putting `meshghost-server` on a rented server: *"can you look for possible security or
other issues?"* Nine reviewers who had not written the code read it from the positions an attacker
would actually stand in — a stranger who has the address, someone on the network path, a member of
a room, a hostile server, and the test instruments themselves — and found twenty-nine things. What
follows is what a host needs to know: what a stranger with your address can and cannot do now, and
the few settings that matter on a server other people can reach. Two decisions came out of it
(ADR 0064 and ADR 0065), and the next piece of work, forcing encryption on with nothing manual for
anyone, is scheduled behind it.

**One machine can no longer fill the server.** The server accepts 64 connections per listener,
counted before anyone says hello, and a single address could hold all 64 open and silent —
refreshing them every ten seconds — so every real player was refused with a bare disconnect,
indistinguishable from the server being down. Each address now gets its own share: twice the seat
count, so 16 on a default server, enough for a whole household behind one home router to fill every
seat and more. A flood from one machine now needs four machines, and the addresses it costs are
kept in memory only, never in the log (see the privacy section below).

**A room code cannot be guessed at the speed connections can be opened.** A wrong code cost the
guesser one connection, and a connection is a couple of round trips: hundreds of guesses a second
from one machine, a dictionary word in minutes. Each address now gets six wrong codes, then one more
per second; while over budget it is told "rate limited" before its next code is even compared, the
right code included, so the reply never says whether a guess was close. A code is checked on both
legs of a join, so a friend's typo costs two of the six — three typos are free. The server also
warns at startup if the code is under eight characters. **On a server strangers can reach, set a
room code, and make it long: eight characters or more.**

**A stranger cannot erase your log.** Every refused hello, every socket that never said hello and
every reset wrote one line, and the log keeps one megabyte plus one rotated copy — so about 1,900
refused connections rolled the startup banner (your certificate fingerprint included) and every
join and leave off the end in seconds. A member that stopped reading cost 256 lines every twelve
seconds the same way. Every line a stranger can cause is now at most one a second, carrying a count,
and a dead connection's queue is dropped after its first failed write.

**A player's client never quietly downgrades to plaintext.** With the shipped `tls` setting a
client that failed a TLS handshake for any reason — a reset, a timeout, something on the path
breaking it — reconnected in plaintext with the room code readable, and on a tcp-only server the
whole session then ran in the clear. Now a client refuses any server that does not complete the
handshake, full stop.

**Encryption is no longer a setting, and your server has an identity now** (same day, ADR 0066).
The `tls` and `tls_fingerprint` keys are gone: every connection is TLS on both transports, a
plaintext client is closed and a plaintext server refused. Your server generates a certificate on
its first start and keeps it in `tls\` beside its `config.json`, so it is the same server after a
restart; it prints the fingerprint at startup and names the folder. Every player's client remembers
that fingerprint on its first connection and warns, loudly, if it ever changes — the SSH model, with
nothing for anyone to copy. Keep `tls\relay.key` private (whoever has it can pose as your server to
everyone who has connected before); copy the `tls\` folder into a new install to stay the same
server; delete it to become a new one, at the cost of one warning per returning player. A
`config.json` still carrying `"tls": "off"` or `"auto"`, or a pin, refuses to start and says why.

**Plain udp is gone from releases.** It could never be encrypted, it rescued no player quic could
not (quic runs over udp, so whatever blocks one blocks both, and tcp is the fallback anyway), and it
was attack surface for no benefit. A `transport` or `listen_udp` still naming it refuses to start
and says why. The default `tcp,quic` is unchanged.

**What a server operator sees is truer.** The "listening on" line says which address families the
socket covers — a wildcard bind is dual-stack on Linux and Windows, so `0.0.0.0` had an IPv6 side
open that a v4-only firewall never saw. A server started from a directory other than its own (a
service manager's default) now looks for `config.json` beside the executable too, says which file it
read or that it found none, and writes its log beside that config. `room_code`, `only_game` and
`max_clients` are re-read when the file is saved, without disconnecting anyone — a leaked code no
longer costs a restart. A server that dies of a listener error says goodbye to its players the way
Ctrl+C does, and the goodbye no longer waits on one stalled member. The qlog packet trace is written
only when asked for with `-qlog`, not whenever an environment variable happens to be set. A key typed
in the wrong case is no longer applied and simultaneously reported as ignored, a `max_clients` of
`0` is printed as the 8 it enforces, and a trailing space in `room_code` no longer refuses everyone.

**On a server strangers can reach, then:** set a `room_code` of eight characters or more; keep the
`tls\` folder with the install and `relay.key` private, and read your fingerprint line to a player
over chat if they ever see the "identity changed" warning and you did not reinstall; bind `0.0.0.0` and firewall
both IPv4 and IPv6, or bind one explicit address; keep `transport` at `tcp,quic` and forward that
one port number for both tcp and udp; run it from its own folder or give `-config` an absolute
path; and read the startup lines — every one of the settings above prints what it decided.

**What was looked at and not changed.** Five findings sit in the position of a room member on an
opt-in plane no shipped game negotiates; they are recorded in `agent_docs/risks.md` with their
numbers, for when a plane ships. The test instruments were made honest as part of the same pass: a
hostile-client harness now drives the exact listener stack a stranger meets, the fuzz census was
recounted, and the udp fuzz target moved with its transport to the dev build.

## What's already true, and why (checked against the actual code, 2026-09-11)

**No peer-to-peer connection exists.** Clients never connect to each other — only to the
relay (`relay`), a hub, not a mesh. A client has no mechanism to learn anything about
another player's network state, because no channel to another player's machine exists at all.

**No message type carries an IP address or other network-identifying field.**
`protocol/protocol.go`'s complete message set (`Hello`, `Welcome`, `Reject`, `Join`,
`Leave`, `State`, `Prefs`, `Event`, `Lease`/`LeaseState`, `Escrow`/`EscrowState`,
`World`/`WorldState`, `Ping`/`Pong`, `Transports`) has no address field anywhere — `Reject`
carries only a reason string, and `Transports` (the transport-discovery reply, added 2026-08-16)
carries a kind and a **port** per offer, never a host: the client already knows an address, and a
relay bound to `0.0.0.0` doesn't. A client only ever learns a peer's `player_id`, cosmetic state
(position/area/anim/extras), and — since nametags shipped — the peer's chosen display label:
`Hello.DisplayName` and `Hello.NameColor` are sanitized by the relay (length-capped, control
characters stripped) and redistributed as `Welcome.Nametags` and `Join.Nametag`, then re-sanitized
by the receiving client. A nametag is explicitly a label, not an identity, and still carries no
address or network-identifying field.

**A session can be resumed, and the token is the only secret the relay ever mints.** In a room that
negotiated `resume.v1`, a dropped client's identity — its `player_id`, held leases and in-flight
exchanges — is parked for a grace window (20s default) rather than announced as a leave, and
reclaimed by presenting the `resume_token` its `welcome` carried: 16 bytes from `crypto/rand`,
single-use, rotated on every welcome, looked up by exact match and never broadcast or logged
(`relay/resume.go`). Whoever holds the token owns the session, so it crosses the network under
whatever the transport gives it: encrypted on quic and TLS tcp, readable by an on-path observer on
plain tcp and udp. A cosmetic room mints none and parks nothing.

**`player_id` is not derived from an IP.** It's a monotonic counter assigned by the relay
(`fmt.Sprintf("p%d", n)`, `relay/relay.go`'s `nextPlayerID`) — `p1`, `p2`, ... per
process lifetime, carrying no information about the connection it came from.

**The relay itself doesn't read a client's IP, and logs one only when TLS is enabled and a
connection is refused.** `relay`, `core` and `cmd/` contain no `RemoteAddr()` call site — a test
fails the build on one since 2026-09-15 (`internal/gameblind`); the occurrences are in `netx/`, the
`net.Conn` method the transports must implement.

**Since 2026-09-15 `netx` does keep one thing per client address, in memory only** (ADR 0064): how
many connections that address holds open, and how many wrong room codes it has sent in the last few
seconds. That is what bounds a single machine that used to be able to hold every connection slot or
guess room codes hundreds of times a second (see the 2026-09-15 section above). The table is capped
at 4096 addresses, an address is forgotten as soon as it is idle and the table needs the room, and
**no address in it is ever written to the log or to disk** — the throttled refusal lines print
counts. The relay reaches it through an interface it hands the connection to, so the relay still
never reads the address itself.

**The one exception, added 2026-08-19 with TLS over tcp:** `netx/tlsx`'s listener names the peer
address in two log lines — a plaintext connection refused (every connection is TLS since
2026-09-15), and a failed TLS handshake. Both are refusals, both go only to the host's own
`meshghost-server.log`, and both are throttled to one line a second. It is a deliberate
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
`MaxOrientationBytes` (256), `MaxAreaIDLen`/`MaxAnimLen` (256), `MaxJSONDepth` (32 — how deep
`extras` and `orientation` may NEST, a bound on shape that the byte caps do not give, enforced by
every receiver; the depth fuzzer found and fixed an off-by-one in it on 2026-09-05),
`MaxDisplayNameBytes`/`MaxDisplayNameRunes` (64 bytes AND 24 runes, `protocol/displayname.go`,
because either alone lets a smear of combining marks or a wire-heavy name through),
`MaxHelloFieldLen` (128, in `protocol/online.go`),
`DefaultMaxClients` (8, server-wide across all rooms, configurable per relay),
`MaxMessagesPerSecond` (120 — a floor, not a flat cap: the real per-client limit is
`max(120, send_hz * RateLimitHeadroomMultiple)` with the multiple at 6, and at the default 15Hz
the scaled term is 90, so the floor is what applies),
`DefaultHelloTimeout` (10s). The opt-in planes carry their own, in `protocol/online.go`
rather than `limits.go`: `MaxEventBytes` (1024), `MaxLeaseKeyLen` (128), `MaxEscrowBlobBytes`
(1024), `MaxWorldKeyLen` (64), `MaxWorldBlobBytes` (768), plus
`MaxLeasesPerRoom`/`MaxEscrowsPerRoom`/`MaxWorldKeysPerRoom`, which are per-room **memory** bounds
rather than per-message ones and are the only limits here of that kind. The handshake and
extension fields carry their own too: `MaxCorrIDLen` (64), `MaxFeatures` (16) and `MaxFeatureLen`
(64), `MaxResumeTokenLen` (128), `MaxEscrowIDLen` (64) and `MaxWorldMessageBytes` (1100). Two
**queues** are bounded rather than any message: `maxOutboxLines` (256, `relay/outbox.go`) is what
the relay will hold for a client that stopped reading, and `maxRelayOutboxLines` (256,
`core/relaywriter.go`) what a core will hold for a relay that did.

**The bridge is bounded separately, and more loosely on purpose.** None of the above applies to the
localhost socket between an adapter and its core: it tolerates a **64 KiB** line
(`transport.DefaultMaxLineBytes`), not `MaxLineBytes`' 4096, because an input track never goes on
the wire. What bounds it is `bridge/inputlimits.go` — `MaxInputEdgesPerBatch` (64), `MaxInputAxes`
(8), `MaxInputLabels` (32), `MaxInputLabelLen` (32), `MaxInputAxisValue` (1e4) — and that file is
blunt about what they are for: they "are the only thing standing between a broken adapter and the
core's memory". They are not a defence against a remote peer, which never reaches this socket. Those plane bounds are meant
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
  `MaxWorldBlobBytes`, ~52KiB per room, freed with the room) and opt-in per room, so it is not a
  resource gap; what it is, is a new place a client could smuggle something into, and it is not
  inspected because by hard rule it cannot be. Same posture as `extras`, with a longer lifetime.
- **The first connection to a server is unauthenticated, and a changed identity is warned about,
  not refused** (ADR 0066, 2026-09-15). `tcp` and `quic` are both TLS 1.3 always, and both are
  checked against the one certificate the client remembers for that address — so an eavesdropper
  is stopped on every connection, and an impostor is noticed from the second connection on. What
  is still open is the first connection (nothing to compare against yet), and what a *change*
  means: today the client logs both fingerprints, updates its memory and connects, because
  refusing would need a human to delete a line from a file. Plain `udp`, which could never be
  encrypted, stopped shipping the same day (ADR 0065).
  Closing the rest (by binding the room code to the TLS session, so a changed identity is proven
  by the code or refused, and the code never crosses the wire) is the chosen next piece of this
  work and not yet built — [agent_docs/tls-planning.md](../agent_docs/tls-planning.md) step 5; the
  design is in
  [agent_docs/security-design.md](../agent_docs/security-design.md), point 3, and carried as a
  known gap in [agent_docs/risks.md](../agent_docs/risks.md); the keying material it needs is
  confirmed reachable from a quic-go connection (`TestHandshakeIsTLS13`).
- **Room-code auth depends on the relay being current** — see "A new risk this creates" above.
  A stale relay binary silently provides none of the protection a client believes it configured.
- **Audited adversarially four times, on 2026-09-02, 2026-09-07, 2026-09-12 and 2026-09-13** — the resource-exhaustion,
  protocol-trust, transport and peer-to-adapter surfaces, and on the fourth the internet-facing
  relay specifically, by reviewers who had not written the code
  and were not shown this page (ADR 0044 covers the first; the 2026-09-15 section above the fourth). The second found, among others, the
  drain-window rejoin and the synchronous relay write that could freeze a game, both below. That is
  two passes by one kind of reviewer, not a proof; the honest
  status is "the things a hostile reader found in a day are fixed, and what they chose to leave
  are listed below." A peer can still spam legitimate-looking rapid state changes right up to the
  rate cap; that is what the cap is for. The next set of eyes should read the ADR first to look
  past what the last set found. How to be that next set: [reviewing.md](reviewing.md).
  **The third pass is the one to read honestly**: ten of its seventeen reviewers finished and seven
  did not, so three of the four game adapters were never looked at — including the only one written
  in a memory-unsafe language — and both of its cross-cutting sweeps are missing. What the ten found
  is fixed and listed below; what the seven would have found is unknown, and "unknown" is not
  "clean".
- **Room squatting under no-auth.** The first `hello` for a room name fixes its `game_version` and
  feature set; every later joiner that disagrees is refused. With `room_code` unset, a stranger who
  connects first locks that room name for everyone else. This is what the no-auth posture means;
  the defence is the room code.
- **A member of an opt-in `lease.v1`/`world.v1` room can fill its tables.** 256 lease keys
  (renewable) or 64 world keys, after which every other member gets `too many`. World entries
  outlive their writer by design — custody is the plane's purpose — so a departed member's 64 keys
  stay until the room empties or a later authority drops them. No shipped adapter negotiates these
  planes — but the shipped client config carries a `"features"` key, so a player can ask for them
  from `config.json` without any adapter being involved; a per-member bound of escrow's shape is the
  fix when one does. Related: a lease-holder
  handover re-sends the room's world snapshot (~53 KB) per change of holder, so two colluding
  members can turn ~200 B in into ~53 KB out per handover, up to the flood cap.
- **Resume grace holds a seat with no socket.** A `resume.v1` identity keeps its `max_clients` slot
  for the grace window after dropping, so eight identities cycling reconnects can hold all eight
  default seats while rarely being connected. Bounded by `max_clients`, and no cheaper for the
  attacker than holding eight connections.
- **A connection refused by the per-address cap gets a bare close, not a reason** (2026-09-15). The
  cap sits in `netx`, below the protocol, and cannot write a Reject; the listener-wide cap it extends
  has always behaved the same. A player behind a NAT that already holds its share sees "the server
  dropped me", not "too many from your address". Accepted; the share is two connections per seat
  with a floor of 16, so a household fills it only by holding twice its seats open.
- **The per-address budgets trust the address.** A source that is spoofed or spread across many
  machines is bounded only by the listener-wide caps the budgets sit inside. And a household behind
  one NAT shares one budget of wrong room codes: one member's typos block the others for a second
  per attempt (three typos are free; a code rides both legs of a join, so that is six attempts).
- **Five findings in the member position of an opt-in plane are recorded, not fixed** — a reliable
  flood that gets a slower peer disconnected, an escrow anyone can open naming anyone, and three
  smaller ones. None is reachable in a cosmetic room; each is a contract decision for when a plane
  ships. They are in [agent_docs/risks.md](../agent_docs/risks.md), with the numbers.

### Why `auto` and not `off` — a policy decision, 2026-08-19, superseded 2026-09-15

The flags used to default to `off` so that a client could not suddenly demand encryption from a
relay that predated it. That reasoning was retired outright: **assume everyone is on the
latest release.** A default whose whole purpose is protecting stale versions protects nobody, and
the cost of keeping it was real -- every fresh install ran unencrypted unless somebody found the
setting.

`auto` was then the right shape because it never broke a session: TLS where the other end spoke
it, plaintext on the same port on the relay side, netcat still usable. **Superseded 2026-09-15 (ADR
0066)**: the same stance, taken to its end, means there is no setting at all — every release since
2026-08-19 speaks TLS, so `auto` protected nobody either, and the fourth review showed its fallback
was a downgrade any failed handshake could trigger. Netcat lost; `docs/reviewing.md` says what to
use instead.

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
`netcat` or a packet capture while debugging — which it no longer is against a shipped relay, every
connection being TLS since 2026-09-15 (a dev build honours `SSLKEYLOGFILE` for Wireshark) — the one
that **did** gain optional TLS, on 2026-08-19, then unconditional TLS on 2026-09-15, and the only
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

- **Send rate defaults to 15Hz, operator-configurable 10-100Hz** (`core.DefaultMinSendInterval`
  is the fallback when nothing else applies; the actual rate is
  `Core.effectiveSendInterval()` — the slower of a relay's advertised `Welcome.SendHz` and a
  client's own explicit `Core.MinSendInterval`, `core.go`; see the send/receive rate-control ADR
  in `architecture.md`), and rendering already runs `InterpolationDelay` (450ms default) behind
  the newest sample specifically to smooth network jitter. A TCP stall is at most one send
  interval (~67ms at the 15Hz default, as low as ~10ms at the 100Hz ceiling) — invisible against
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
  on every datagram afterwards. The point above stands as the reason tcp remains the mandatory
  handshake leg and the universal fallback: on tcp this protection is free, and on udp it is code we own and
  must keep correct.
- **NAT/reachability is identical either way**: MeshGhost is relay/star-topology, not P2P — no
  client ever connects directly to another client, only to the relay. UDP's actual advantage
  for reachability (hole-punching to skip port-forwarding for direct peer connections) doesn't
  apply, because there's no direct peer connection to punch a hole for.

**Caveat on the ~67ms figure above, added 2026-08-16 — it is optimistic.** A lost packet stalls
delivery until it is *retransmitted*, so the bound is retransmit timing, not send rate. Fast
retransmit needs three subsequent packets, which at 15Hz is already ~200ms, so the RTO timer —
floored near 200ms on common stacks — is likely to dominate instead. **This is reasoning, not a
measurement**: nobody has run MeshGhost over a genuinely lossy link and watched. It does not
change the conclusion (450ms of interpolation absorbs a lot, and a ghost is cosmetic), but the
number should be re-derived rather than cited if this comparison is ever re-opened.
