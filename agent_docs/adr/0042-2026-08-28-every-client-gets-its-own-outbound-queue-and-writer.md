# 2026-08-28 — Every client gets its own outbound queue and writer

<!-- ADR 0042. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** Each `relay.Client` owns a bounded FIFO and one goroutine that drains it. `Room`'s
  fan-out enqueues instead of writing, so a peer that has stopped draining its socket blocks only
  itself. Overflow is two-class, matching the planes: a state displaces the oldest queued state, and
  a reliable message at a full queue disconnects the client rather than being dropped.
- **Status:** **Implemented 2026-08-28, Go side complete and confirmed with the tools.** Full suite,
  `-race` at `-count=3`, the stress script, `internal/e2e`, and `relay/leak_test.go` all clean.
- **Nothing on the wire changes**, and no adapter, core or game sees a difference. This is about who
  writes a byte and when, not which bytes.

## Why: this is a correctness fix that happens to look like an optimisation

`Room.forward` wrote to every recipient in a loop, on the **sending client's own read goroutine**,
while `transport`'s delivery mutex was held. So one stalled socket blocked:

- delivery to every peer **behind it in that loop**, and
- the **sender's** next inbound message, for the same duration,

for up to `transport.DefaultWriteTimeout` — ten seconds. A room is meant to degrade one peer at a
time; this degraded all of them at once.

**Demonstrated before it was fixed**, with a stalling transport and a healthy one in the same room:
the healthy peer received nothing until the stalled one was released. `TestOneStalledPeerDoesNotBlockTheRoom`
is that demonstration kept as a regression test — and reverting the enqueue does not merely turn it
red, it **hangs**, because `Forward` never returns at all. The old behaviour was "the room stops",
not "the room is slow".

## Overflow is the contract's policy, not an invention

`contract.md` makes the state plane lossy and latest-wins and everything else not, so the queue
follows that split rather than inventing a rule:

- **A state displaces the oldest queued state.** When there is a choice about which position sample
  to lose, the stale one is always right. Same reasoning as the receive gate dropping excess samples
  rather than queueing them (ADR 0017).
- **A reliable message is never dropped.** A lost `leave` strands a ghost permanently and a lost
  escrow step wedges a trade. A full queue means the peer is not reading at all, so the honest
  response is to disconnect — which a client retries and recovers from — rather than to lose the one
  message that would have kept everyone consistent.
- **A state arriving at a queue holding only reliable messages yields**, since there is nothing it
  may displace.

`close` drains rather than discards: the last thing a refused client is owed is the `Reject`
explaining why, and it travels this same queue.

## What this does NOT do: coalesce

Several lines waiting for the same peer could be written in one syscall, and NDJSON makes that
exact. **Deliberately not built**, and this is the reasoning so it is not re-derived:

- Nothing has shown it would pay. The 2026-08-28 profile puts ~58% of the relay's per-state path in
  `encoding/json` and the syscall nowhere near the top.
- It must never merge datagrams on udp/quic. `netx/udpconn`'s `MaxDatagramBytes` is 1200 and
  Pseudoregalia's state lines are 597+, so two do not reliably fit — and a merged datagram doubles
  the blast radius of a single loss on the plane deliberately made lossy.
- Any form of it must be **opportunistic**, batching only what is already queued, never a timed tick
  that deliberately waits. The user picked 175ms interpolation for TEVI and called 150ms *"living at
  the edge"* (ADR 0040), and per-adapter tuning may go lower. There is no latency budget to spend.

Filed as an idea with the measurement it would need first.

## The ordering invariants, and why they survive

`relay/online.go`'s header calls `sendMu`'s total order load-bearing: a sequencer stamp is assigned
and the message delivered under the same lock, so the order assigned is the order sent. **That
survives, because "deliver" now means "enqueue in order onto each recipient's FIFO"** — a FIFO
drained by exactly one goroutine preserves it. `TestOutboxPreservesOrder` pins it.

`holdUntilWelcome` also survives untouched: a client held before its Welcome never reaches the
enqueue path at all, because `forwardLine` diverts those messages into `c.pending` first. So the
"Welcome is the first thing on this socket" guarantee is unchanged, and the direct writes that
handshake and ping use are unaffected — deliberately left as they were, since queueing them would
have meant re-deriving that guarantee for no benefit.

## Lifecycle

One goroutine per client is one leak per player who ever joined if a close is missed, so the outbox
is closed in all three places an identity stops using a connection: a real leave (`Room.remove`), a
drop into the resume grace window (`suspend` — the socket behind the queue is gone), and a takeover
by a new connection (`resumeInto`, including the live-takeover case routine on quic, where the relay
never noticed the old socket die). `relay/leak_test.go` covers the server end to end and
`TestClosingAnIdleOutboxStopsItsGoroutine` covers the primitive, including a writer parked waiting
for work rather than draining.
