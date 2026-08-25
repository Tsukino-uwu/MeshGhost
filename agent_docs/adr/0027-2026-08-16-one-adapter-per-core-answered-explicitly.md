# 2026-08-16 — One adapter per core, answered explicitly (groundwork for the port walk)

<!-- ADR 0027. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** A core admits exactly one adapter at a time, and answers every `hello` with either
  `bridge_ready` or `reject{reason}` instead of silence-or-hangup.
- **Status:** Core, bridge, and tests done. The adapter-side port walk that consumes it has since
  shipped for Pseudoregalia (`BridgeClient` walks `BRIDGE_BASE_PORT..+BRIDGE_PORT_COUNT` and
  requires an explicit `bridge_ready`, covered by `internal/e2e`'s `TestPortWalkFindsAFreeCore`).
  **Updated 2026-08-18: both Pokémon adapters now walk too** — `meshghost_emerald.lua` and
  `meshghost_crystal.lua` each probe `BRIDGE_BASE_PORT` (7778) upward across `BRIDGE_PORT_COUNT`
  (8) and require `bridge_ready`. **TEVI is the last one still on a single fixed port**
  (`Plugin.cs`'s `DefaultBridgePort`, overridable by config but not walked). Both Pokémon walks
  were **watched live 2026-08-18** (two emulators taking 7778 and 7779) and again in the two-game
  session of 2026-08-19; Pseudoregalia's is still only covered by `internal/e2e`. **One resolution below is reversed** —
  silence is no longer treated as an older core, see the note on that bullet.
- **Context:** The Linux tester asked for a way to run a second game — "start it anyway with an
  increased port until a free one is found" — so each game could use a different relay. Checking
  what happens today found the reported failure (a second *different* game is refused with a silent
  socket close, and its mod reconnects forever) plus a worse one nobody had seen: two adapters with
  the *same* `game_id` were both **accepted**, because `ConnectRelayOnAdapterHello` returns early
  when the game already matches and nothing anywhere limited adapters per core. They then shared
  one `player_id`, `seq`, send-rate budget and `localAreaID` — two games driving one ghost, both
  logging a normal connect.
- **Options considered:** (1) distinct default bridge port per adapter — no protocol change, but it
  needs a port registry kept in sync with the docs and does nothing for two instances of one game,
  which is the case that actually corrupts; (2) the port walk, which needs an adapter to be able to
  tell a busy core from an empty port.
- **Resolution:** Option 2, and admission control is the half that makes it a bug fix rather than a
  feature. Occupancy is a **separate field from `relayOwner`**, deliberately: `relayOwner` answers
  "whose disconnect may tear down the relay", this answers "may you attach at all", and conflating
  them is precisely how the stale-callback bug `relayOwner` exists to prevent was written.
- **Resolution (why an ack, not just a reject):** with only a reject, "accepted" is inferred from
  silence over time — indistinguishable from a core still binding its port, or from an older core
  that ignored an unknown message type (bridge dispatch has no `default` case). A positive
  `bridge_ready` makes success observable instead of assumed, which is the same reason this project
  refuses to treat "it ran without errors" as evidence. An adapter that gets neither is on an older
  core and proceeds as before, so mixed versions still work.
  *(**Reversed** — that last sentence shipped for one build and was itself the bug. Current
  behaviour, in `contract.md` and in `BridgeClient.cpp`'s `is_ready`: **silence is not acceptance**,
  and an adapter that gets neither answer moves on to the next port. Silence is indistinguishable
  from an unrelated program squatting a port in the range, and committing to one strands the
  adapter with no ghosts and no explanation, where skipping a merely-old core costs nothing —
  the walk just starts its own on a free port. Caught by `internal/e2e`'s
  `TestPortWalkFindsAFreeCore`, which squats a port with a listener that never speaks;
  `adapters/_template/PROTOCOL.md` documents the reversed rule as standard for new adapters.)*
- **Consequences:** Two copies of one game on one machine stop corrupting each other. A refused
  adapter now learns why, in its own log, rather than seeing a hangup it cannot tell from a crash.
  The contract states the 1:1 rule outright instead of implying it through singular phrasing.

---

- **Date:** 2026-08-16
- **Decision:** `send` is **ordered** as well as reliable on every transport. `netx/udpconn`
  resequences: a reliable payload that arrives ahead of an earlier one is held until the gap fills,
  instead of being delivered on arrival.
- **Status:** accepted
- **Context:** `contract.md` promised the reserved event plane would be "reliable, ordered" and
  `udpconn.Write`'s own doc comment claimed callers "get TCP-like semantics", but the receive path
  delivered each payload immediately and deduped by seq with no resequencing buffer. Reliable, not
  ordered — and `udp` is the client default. Found while writing up what a fuller online mode would
  need; confirmed with two tests before any fix was written, rather than argued from the code.
  `TestReliableWritesArriveInOrderUnderLoss` showed `leave` overtaking `join` on the wire with only
  a single datagram dropped, and a core-level test showed the consequence: `delete` on an absent key
  is a no-op, so the late `join` re-adds a peer who has already gone and nothing will ever remove
  them again. Their ghost stays on screen for the rest of the session. Reachable whenever a join's
  first datagram is lost and the peer leaves inside the ~6s retransmit budget.
- **Options considered:** (1) guard in `core` — ignore a `join` for a `player_id` already
  seen leaving, safe because relay ids are never reused; small and low-risk, but it *corrects* the
  symptom while the cause keeps running, and every future consumer of lifecycle ordering inherits
  the same bug. That is the shape `adapters/_template`'s no-bandage rule names. (2) resequence in
  `udpconn`, which *prevents* it for every consumer and makes the two existing doc claims true.
  (3) both, as defence in depth — rejected because the core guard would read as an unexplained
  compensation once the real fix was in place.
- **Resolution:** Option 2. Out-of-order payloads are held in a bounded `reorderWindow` (64) and
  released in sequence. Two properties were deliberately preserved: a buffered payload is **not
  acked** until it is genuinely delivered, so the existing "ack only what was delivered" rule (which
  exists because `deliver` drops on a full queue) still holds; and buffer overflow simply declines to
  hold the payload rather than dropping it, so the sender's retransmit covers it — the same mechanism
  that already covers a lost datagram. The old seen-set and its 1024-entry pruning were removed, not
  kept: with in-order delivery a duplicate is exactly `seq < wantSeq`.
- **Consequences:** Head-of-line blocking now exists on the reliable path — correct here, since only
  lifecycle messages ride it (a handful per session) while the state plane rides `SendUnreliable` and
  is unaffected. `core` still has no guard of its own and deliberately depends on this
  guarantee; `TestCoreDependsOnOrderedLifecycleDelivery` pins that coupling from the other side so it
  is visible rather than implicit. The contract now states ordering explicitly instead of leaving it
  to be inferred from "reliable".

---

- **Date:** 2026-08-16
- **Decision:** quic becomes the default transport in practice: the client's `-transport` defaults to
  `auto` (which prefers quic), the relay's `-transport` defaults to `tcp,quic`, and quic **shares
  `-addr`'s port number** instead of taking a second one.
- **Status:** accepted
- **Context:** The shipped defaults were mismatched in a way nobody had noticed: the client asked for
  `udp` while the relay served `tcp` only, so every default session asked for something it could not
  have and silently fell back to tcp. The client's stated default was never honoured by a default
  relay. Meanwhile two real properties of quic were going unused. First, **encryption** — room codes
  cross tcp and udp in plaintext, which `status.md` already tracked as an open relay-safety item.
  Second, and less obvious: **quic is the only transport where the two-plane design in
  `contract.md` actually works.** On tcp `SendUnreliable` *is* `Send`, so the "lossy, latest-wins"
  state plane is neither lossy nor latest-wins — a bad link head-of-line-blocks position updates and
  then delivers them stale, which that same document calls worse than the gap it fills. quic gives
  real datagrams for state and an ordered stream for lifecycle. A third property decided the port
  question: quic carries connection IDs and survives a NAT rebinding, where `udpconn` keys
  connections by remote address (so a rebind arrives as a stranger and costs a `player_id`) and tcp
  simply breaks.
- **Options considered:** (1) leave it alone and document the mismatch; (2) hard-default both sides
  to quic, which fails outright on networks that block udp and has no fallback; (3) `auto` on the
  client plus `tcp,quic` on the relay, reusing `netx.AutoPreference` — which already prefers quic and
  already places udp last precisely so nothing silently downgrades a room code to plaintext.
  Separately for the port: (a) keep quic on its own 7780, (b) share `-addr`'s port, (c) move the
  plain udp transport to a new `-listen-udp` flag so quic could take 7777 unconditionally.
- **Resolution:** Option 3, with port option (b). `auto` degrades gracefully to tcp where udp is
  blocked, which a hard quic default cannot, and needs no new mechanism. quic shares `-addr`'s port
  because tcp and udp are separate port spaces, so `tcp:7777` and `quic:7777/udp` coexist — this was
  a **NAT decision, not tidiness**: serving quic by default would otherwise have turned hosting from
  "forward 7777" into "forward 7777 and 7780", and port forwarding is the step where a host actually
  gives up. Option (c) was rejected as more churn than it earns: it would change `-addr`'s meaning
  and break every existing udp configuration to improve a case that is already opt-in.
- **Consequences:** A default session is now encrypted against a passive observer without anyone
  configuring anything — but **not authenticated**: `quicconn` uses a self-signed in-memory cert with
  `InsecureSkipVerify`, so this is privacy from someone watching, not proof of who the relay is.
  Binding relay identity to the room code remains separate and unscheduled. The plain udp transport
  now carries the awkwardness it deserves, being opt-in and unencryptable: serving `udp` and `quic`
  together needs `-listen-quic` named explicitly, and the relay **refuses to start** with an
  actionable message rather than quietly relocating quic to a port the host never forwarded.
  `dev-scripts/run-relay-loopback.bat` is exactly that case and now passes the flag. The relay also
  prints the ports to forward at startup, protocol by protocol, since `7777/tcp` and `7777/udp` are
  two separate rules on most routers. Debuggability regresses in the common case, and that is a real
  cost: `netx.go` notes tcp is the only transport readable with netcat or a packet capture, and it is
  no longer the default path — `-transport tcp` on either side restores it.
