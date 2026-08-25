# 2026-08-16 — Selectable transport: `tcp` | `udp` | `quic`

<!-- ADR 0021. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** The relay connection's transport is chosen in `config.json` (`"transport"`), with
  three implementations behind the existing `Transport` interface. The relay may serve several at
  once and a room may hold clients on different transports simultaneously. **Adapters are
  unaffected and cannot observe the choice** — the bridge stays loopback TCP NDJSON permanently.
- **Status:** Implemented.
- **Context:** `brief.md` and `transport`'s own doc comment both call `Transport` "the
  swappable network boundary," but it had exactly one implementation, so the claim was untested and
  nothing forced the boundary to hold. `contract.md`'s hard rule "Transport is swappable behind
  `send(bytes)`/`on_receive(cb)` from day one" was likewise aspirational. The motivation is
  modularity — and the expectation that a future game/adapter may suit one transport better than
  another — explicitly **not** throughput. Two facts found while scoping shaped everything below:
  UDP cannot be encrypted in Go (no DTLS in the standard library), and `NDJSONConn.Send` issued two
  `Write` calls, which is invisible on a stream and fatal on a datagram.
- **Options considered (where to put the seam):** (1) a second `Transport` implementation per
  protocol — the obvious reading of "swappable transport", but it would have moved framing,
  reconnect and callback handling into each one and left `relay` needing a datagram-shaped
  accept path; (2) expose every transport as a `net.Listener`/`net.Conn` pair and keep `NDJSONConn`
  as the only `Transport` — more work inside the new packages, none anywhere else.
- **Resolution:** Option 2. `relay.Serve` already takes any `net.Listener` and `handleConn` any
  `net.Conn`, so **`relay` gained no transport-aware line at all**, and — decisively — the
  per-connection-goroutine model survived untouched. `Client.gateMu`'s comment states that
  everything else in that struct needs no lock *because* "OnReceive is serial", which is true only
  while each connection owns a goroutine; option 1 would have required re-auditing every concurrent
  site in the relay to keep that claim honest. New packages: `netx` (the `Kind` seam),
  `netx/udpconn`, `netx/quicconn`.
- **Resolution (framing):** One datagram carries exactly one NDJSON line. Framing is redundant on
  udp/quic but harmless, and it keeps a single `Transport` implementation for all three. This is
  what made `Send`'s two-`Write` split a real bug rather than a style point: over a datagram
  transport it is two datagrams per message, splitting every line in half with nothing downstream
  able to reassemble it. Fixed, with `TestSendIssuesExactlyOneWritePerMessage` (which fails against
  the old version — verified by reverting it, not assumed).
- **Options considered (reliability):** (1) make every transport fully reliable — simplest, but
  QUIC then head-of-line blocks exactly like TCP and buys nothing but encryption, and UDP would need
  retransmission on the 20Hz hot path; (2) make datagram transports fully unreliable — loses
  `leave`/`welcome`, which are not recoverable at any higher layer; (3) reliable by default with an
  explicit opt-out.
- **Resolution (reliability):** Option 3. `Transport` gained `SendUnreliable`, and the polarity is
  deliberate: `Send` stays reliable on every transport, so **any call site that never learns about
  the new method remains correct**. Exactly two sites opt out — `core.sendState` and the relay's
  `Room.ForwardUnreliable` — because `contract.md` already defines the state plane as lossy and
  latest-wins. A retransmitted position would arrive stale and out of order, which is worse than the
  gap it fills. `ForwardUnreliable` is a separate method rather than a flag on `Forward` so a caller
  who forgets which they wanted gets the safe one. TCP implements it as `Send`; a `net.Conn` opts in
  structurally via an unexported `unreliableWriter` interface, so `transport` keeps its
  no-internal-dependencies property.
- **Resolution (UDP address validation):** A remote must echo back a cookie sent to the address it
  claimed before it gets a `Conn`, which defeats blind spoofing and stops the relay being used as a
  reflector. The cookie is **derived, not stored** — `HMAC(secret, addr || timeSlot)`, current and
  previous slot accepted. A table of unvalidated addresses would itself have been the
  vulnerability: one entry per forged hello is unbounded memory an unauthenticated stranger
  controls. Same technique as a TCP SYN cookie and QUIC's Retry. It does **not** stop an on-path
  attacker, which is the same bar TCP sequence numbers set.
- **Resolution (ports):** TCP and UDP have independent port spaces, so `tcp` and `udp` share
  `listen_on` — pinned by `TestTCPAndUDPShareAPortNumber` rather than left as a comment, because if
  it were ever false the relay would fail to start in a shipped configuration for a non-obvious
  reason. QUIC is carried over UDP and therefore **cannot** share a port with the plain `udp`
  transport, so it gets its own `listen_quic`. *(Refined the same day: `listen_quic` now defaults
  to empty, meaning quic reuses `listen_on`'s port number. It is required only when plain `udp` is
  served too — which is the collision this bullet is really about.)* A host serving all three
  forwards three router rules
  across two port numbers.
- **Resolution (defaults)** — *superseded the same day by the quic-default ADR later in this file:
  the client ships `auto` and the relay `tcp,quic`:* Both ends default to `tcp`, and the shipped
  `config.json` says so.
  Considered and rejected: client `udp` with server `tcp`, which cannot connect at all out of the
  box. `tcp` is also the safest default (the only encryptable-later one, and the only one readable
  with netcat for debugging) and the only choice that changes nothing for existing users.
- **Resolution (per-game preference):** Expressible **only as shipped configuration** — a per-game
  `config.json` plus a note in that adapter's README. An adapter must not choose (it never learns a
  relay address and never speaks the relay protocol), and the core must not choose either, because
  branching on `game_id` in game-agnostic code is forbidden outright. Recorded here so the tempting
  version does not get built later. `contract.md`'s adapter invariant was widened at the same time:
  it previously forbade an adapter *doing* relay things but not *influencing* them, so a
  `preferred_transport` field in the bridge `hello` would have violated no written rule.
- **Consequences:** The `Transport` boundary is now load-bearing instead of decorative, and
  `contract.md`'s day-one hard rule is finally true. **`udp` can never be encrypted** — the room
  code crosses it in the clear with no fix available, which is recorded in `risks.md` and stated in
  the flag's own help text. QUIC is the encrypted option, and its `tls.ConnectionState` does expose
  a working `ExportKeyingMaterial` (checked, not assumed — `TestHandshakeIsTLS13`), so the shelved
  room-code channel-binding work in `ideas.md` would drop straight into it. **First third-party
  dependency in the repo** (`quic-go`, MIT, plus three `golang.org/x/*` at BSD-3-Clause), which
  brings a `THIRD-PARTY-NOTICES` obligation for the Go binaries and may shift the antivirus
  false-positive baseline. `go get` also raised the module's Go directive from 1.22 to 1.25.0.
  Clients still cannot discover which transports a relay offers — they must be told out of band.
  Making `Welcome` advertise them, so a client can upgrade itself, is the natural follow-up and is
  filed in `ideas.md`.
