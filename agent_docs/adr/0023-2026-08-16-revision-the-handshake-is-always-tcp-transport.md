# 2026-08-16 — Revision: the handshake is always tcp; `transport` is the upgrade target

<!-- ADR 0023. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** Supersedes the two ADRs above in one respect. A client **always** connects over
  tcp first, and that is not configurable. `transport` in `config.json` no longer means "how to
  connect" but "what to move to once connected": `tcp` stays put, `udp` (the shipped default at
  the time) and `quic` upgrade if the relay serves them, `auto` takes the best on offer. **tcp is
  now mandatory on the relay too** — `netx.ParseKinds` prepends it whether or not the operator
  names it.
- **Status:** Implemented, same day. **The `udp` shipped default is superseded by the quic-default
  ADR at the end of this file** (the client ships `auto`); everything else here — the mandatory tcp
  handshake, `transport` as the upgrade target, tcp mandatory on the relay — is current.
- **Context:** The user's framing, and it is better than what shipped earlier: discovery
  should be an unconditional property of connecting rather than a special `auto` mode. The first
  design left `tcp`/`udp`/`quic` as three parallel ways to connect, which meant a client had to be
  told which port a transport lived on and got a bare timeout when it guessed wrong.
- **Resolution and what it buys:** (1) **a client never needs to know a port** — quic's differs
  and is unguessable, so it is learned during the handshake and `connect_to` only ever needs the
  tcp address; (2) **a wrong preference degrades to a working tcp session plus a log line**
  instead of a timeout; (3) the one leg that must work is always the transport that works
  everywhere and is readable while debugging.
- **Resolution (tcp mandatory on the relay):** **Found by `internal/e2e`, not by reasoning** —
  a udp-only relay became unreachable by every client the moment the handshake became
  unconditional, including clients configured for udp. `ParseKinds` adds tcp silently rather than
  refusing to start: the operator still gets exactly what they asked for, plus the leg that makes
  it reachable. This is the clearest case yet for the e2e rig existing, since every package-level
  test still passed.
- **Resolution (an explicit preference does not rank):** A client asking for `quic` considers only
  quic, and falls back to tcp if it is absent — it must never silently land on `udp`, which would
  swap an encrypted session for one that cannot be encrypted. Only `auto` ranks.
- **Resolution (default `udp`), and the tradeoff recorded plainly** — *superseded the same day by
  the quic-default ADR later in this file; the client now ships `auto` and the relay `tcp,quic`,
  and udp is never chosen for anyone. Kept because the caveats below are still the reasoning:* the
  shipped client default is
  `udp`, chosen by the user so that a host who enables more than tcp automatically gets clients off
  the head-of-line-blocking path. Two honest caveats, neither of which changes the decision but
  both of which belong on the record: **`udp` is not lower latency on a link that is not losing
  packets** — all three deliver identically there, and the benefit appears only under real loss;
  and **`udp` cannot be encrypted**, so on a relay serving both udp and quic, a default client
  takes the unencrypted one and its room code crosses in the clear where quic would have protected
  it. `auto` exists precisely to prefer quic and is a one-word change in `config.json`. Relay
  defaults remain tcp-only, so default-vs-default is unchanged and this only bites once a host
  opts in.

  **The full rationale, after the point was pressed three times — udp is the leanest transport,
  and that is the real reason, not latency.** (1) **Overhead**: a raw udp datagram carries 10
  bytes of framing here (2 control + 8 token), where a quic datagram adds a packet header plus a
  16-byte AEAD tag — roughly 30-40 bytes more per packet, ~15-20% on a typical ~200-byte state
  message, plus per-packet encryption CPU. udp is genuinely the cheapest option and quic is not
  free. (2) **Ordering does not matter** to a latest-wins state plane, so udp gives up nothing
  the state plane wanted. (3) **The usual counter-argument does not apply**: udp's headline
  advantage is hole-punching for P2P, and this is a star topology through a relay, so that was
  never on the table either way (`docs/security.md`'s own NAT note).

  **What the default does NOT buy, recorded because it was the initial motivation and is false:**
  lower latency. All three transports deliver at identical speed on a link that is not losing
  packets; what udp and quic remove is head-of-line blocking *when a packet is actually lost*.
  The choice is loss tolerance and low overhead versus confidentiality, not speed versus safety.
- **Consequences:** Every connection now costs one extra short-lived tcp connection *unless* the
  preference is tcp, which short-circuits. `netx.Auto` survives as a supported value rather than
  the mechanism. The e2e transport tests now serve `tcp,<kind>` and point clients at the tcp
  address for every kind, which is what a real deployment looks like.
