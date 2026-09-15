# 2026-09-15 — Per-source state lives in `netx`, in memory, and is never logged

<!-- ADR 0064. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** the relay process keeps ONE table of per-client-address state, `netx/srclimit`:
  how many connections each address holds open, and how many wrong room codes it has recently
  sent. It bounds two things every earlier bound left global — open connections
  (`relay.MaxOpenConnsPerSourceFor`, through `netx.LimitListenerWith` and `quicconn.ListenWith`)
  and room-code guesses (`relay.RoomCodeAttemptBurst` / `RoomCodeAttemptsPerSecond`, through
  `relay.Server.SourceGuard`). The table is in memory only, capped at 4096 addresses with
  idle-first eviction, and **no address it holds is ever written to a log or a file**: the
  throttled refusal lines print counts.
- **Status:** Implemented 2026-09-15 (fourth adversarial review, findings A3 and A5; the user's
  call the same day).
- **Context:** every bound the relay had was global — 64 open connections per listener, 256
  handshaked quic connections awaiting a stream, one guess per connection. One machine walked
  through all of them: hold every slot idle and refuse every real player with a bare close, or
  guess room codes at the rate connections can be opened, hundreds a second. Both needed the one
  thing the relay had never kept: who is asking. `docs/security.md`'s privacy section and
  `security-design.md` had parked exactly this ("needs its own decision") because the relay's
  not reading a client's IP was a stated property.
- **Where the line is, and why it holds.** `relay`, `core` and `cmd/` still contain no
  `RemoteAddr` call site — `internal/gameblind`'s `TestRelayCoreAndCmdNeverReadAClientAddress`
  fails the build on one. The relay reaches the table through `SourceGuard`, an interface it
  calls WITH the `net.Conn`; the table calls `RemoteAddr` on its side. `netx` was already the
  layer that knew addresses (udp demultiplexes by them; `tlsx` names one in a throttled refusal
  line), so this widens an existing posture rather than crossing a new one. The interface is
  typed on `net.Conn` on purpose: `RemoteAddr` is a `net.Conn` method and crosses every wrapper in
  the shipped stack, where a method type-asserted on the connection would not (`netx/limit.go`'s
  three shipped bugs).
- **The numbers, and what they are.** Per-source connections: `2 × max_clients`, floor 16. A
  client holds ONE connection at a time (checked: the discovery leg closes before the session
  dials, `core/transportpick.go`; a reconnect starts after the previous session ends), so one
  address may legitimately be a household behind one NAT filling every seat, and the 2× is a
  margin for relay-side overlap (close propagation on a resume; a quic connection briefly counted
  by both the pending gate and the limiter as it is handed up). Room codes: a burst of 6 per
  address, one back per second, tokens leaking whole so "blocked" lasts a full second; a code rides
  BOTH legs of a join, so a typo costs two and three typos are free. A blocked address is refused
  as "rate limited" before its code is compared, the right code included — the budget is the
  address's, and the reply says nothing about the guess. **These are reasoned from the join's
  shape, not measured against an attacker.** The startup line warns for a code under 8 characters.
- **The attacker pays for the table.** When full, a newcomer evicts the oldest idle entry (no open
  connection, empty bucket); if none is idle the newcomer is refused. Every non-idle entry was used
  within the last few seconds, so a full table means thousands of distinct addresses active at
  once, which is not a room of friends. A refusal at this layer is a bare close: the limiter sits
  below the protocol and cannot write a Reject. Recorded in `docs/security.md`'s known gaps.
- **Accepted trade-offs.** A household behind one NAT shares one budget of wrong codes, so one
  member's typos briefly block the others (a second per attempt). A per-source cap needs the
  address to be honest — it does not defend against a spoofed or distributed source, which the
  global caps still bound.
- **Supersedes** the "needs its own decision" paragraphs in `agent_docs/security-design.md`
  (per-IP cap) and `agent_docs/risks.md` (the udp entry's "still open" line).
