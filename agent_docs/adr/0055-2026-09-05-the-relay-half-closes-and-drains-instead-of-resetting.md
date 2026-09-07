# 2026-09-05 — The relay half-closes and drains instead of resetting, so a last line survives

<!-- ADR 0055. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** Where the relay writes a line and then hangs up, it no longer calls `Close()`. It
  **half-closes and keeps reading** for a bounded drain — `transport.NDJSONConn.CloseGracefully` —
  so the line it just wrote cannot be discarded by a TCP reset. Applied at all three such sites: the
  rate-limit disconnect (2026-09-05) and both handshake close paths (2026-09-06).
- **Status:** accepted, shipped. `transport/transport.go` `CloseGracefully`;
  `relay/limits.go` `rateLimitDrain` and `handshakeCloseDrain`, both 2s; call sites in
  `relay/relay.go`. Covered by `relay.TestRateLimitedClientReceivesRejectBeforeClose` and
  `core.TestBridgeHelloGameVersionReachesRelay`.
- **Written 2026-09-07**, during the stale-fact sweep, which found that **"graceful" and "drain"
  appeared zero times in `contract.md`** while `:226` still described a `reject` as "sent
  immediately before the relay closes a connection" — the behaviour this replaced.

## The defect, which is a TCP property rather than a bug in our code

**`Close()` behind unread bytes is a RESET, not a FIN.** If the peer has sent data this side never
read, the kernel answers the close with RST — and a reset **discards what is still queued unread in
the PEER's receive buffer**, including the line this side just wrote.

So the relay's most important messages were the ones most likely to be lost, because every case
where the relay hangs up is a case where it has probably not drained the client:

- **A rate-limited client** has, by definition, most of its flood sitting unread server-side at the
  moment the `Reject` goes out.
- **A refused handshake** is the same shape whenever the client wrote anything after its `hello` — a
  keepalive, a queued state, a second hello.

## Why it mattered more than a dropped message

**A `Reject` that does not arrive is not a silent failure — it is a MISCLASSIFIED one.** The core
sees EOF with no reason, reports "the relay connection dropped before the welcome arrived", and that
is a *transient* error. `core.isPermanentRejectReason` never runs, so a **permanent** refusal (a
game-version mismatch, a wrong room code) is retried forever instead of being shown to the player
and closing the bridge. The wire-level defect surfaced as a client that appeared to hang.

## How it was found, twice, and the part worth remembering

**Both halves were found by CI's Linux runner and neither reproduced locally.** The rate-limit case
timed out on Linux while 40 consecutive local Windows runs passed; the handshake case came from the
Linux race job while 30 local runs under `-race` never showed it. **A close-path race is a platform
and timing property, so a green local suite is not evidence about it** — which is the standing
reason this repo treats CI as the authority on race and fuzz, not a formality.

**The 2026-09-05 fix was incomplete and looked complete.** It cured the rate-limit path, the one the
failing test named, and left the handshake path — same class, same reset, different call site —
untouched until CI found it on 2026-09-06. Fixing the site a test names is not the same as fixing
the class it belongs to.

## Consequences

- **A refused connection is held half-open until the client closes**, bounded at 2s. The drain ends
  the moment the client hangs up, which a client that read its `Reject` does immediately — so the
  bound is a ceiling on misbehaviour, not a cost paid per refusal.
- **A transport that cannot half-close falls back to `Close()`.** `CloseGracefully` needs
  `CloseWrite`; anything without it behaves exactly as before, so udp and quic are unaffected and
  nothing had to be special-cased per transport.
- **`contract.md` documents the close behaviour** as of this write-up. It had described the
  `Close()` this replaced.
- **The reserved planes inherit it for free**, since they close through the same connection type.
