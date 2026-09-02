# 2026-09-02 — Every state carries the sample before it (loss cover for the state plane)

<!-- ADR 0045. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** at send rates of 25Hz and slower, every `state` message also carries the sender's
  previous sample as a delta in a new optional `prev` field. The receiving core reconstructs it and
  inserts it into the peer's buffer if that sample never arrived; the relay forwards it untouched
  and never stores it. Above 25Hz nothing is attached. `protocol/prev.go`, `core/sending.go`,
  `core/remotes.go`, `relay/states.go`; `core.Core.RedundancyMinInterval` is the gate (40ms
  default, negative turns it off).
- **Status:** built and confirmed with the tools 2026-09-02 (`run-gotests.bat`, `-race`); the
  on-screen half — the Crystal netsim run at 2% loss that found it, repeated with the cover on — is
  in `crystal/UNVERIFIED.md`.
- **Why now:** the interp ladder on Crystal (`crystal/UNVERIFIED.md`, 2026-09-02): on a 100–200ms
  round trip with 2% loss and the shipped 250ms interp the ghost still snapped on quic and snapped,
  glided and teleported on udp, and with loss OFF at the same delay it was clean. Delay was never the
  problem; loss was.

## The mechanism, and why interp could not cover it

The state plane is unreliable by design (contract: lossy, latest-wins). On quic it rides RFC 9221
datagrams, on udp plain packets; a lost sample is superseded, never retransmitted. That is right for
a sample in the middle of a walk. It is wrong for the LAST one: change suppression (ADR 0039) means
"I stopped here" has no successor until the idle keepalive 250ms later. Lose it and the receiver's
newest sample is one step short — on a bike at 15Hz, a whole tile — so the ghost holds there and
jumps when the keepalive lands. More interp cannot buy that back, because the missing sample is not
late, it is absent.

The first reading of the run blamed quic's retransmits. It was wrong, and worth recording: the quic
transport's state plane is datagrams (`netx/quicconn`'s package doc says so), so quic loses like udp
and the two runs differed by the dice. The user's question that caught it: *"would this help/affect
quic as well if done for udp?"*

## The shape

- **A delta, not a copy.** `prev` carries the previous sample's `seq` and `timestamp` and only the
  fields that differ from the carrying state — for one step of a walk that is the position, ~60
  bytes. Nullable fields say "the previous sample did NOT have this" (`orientation: null`,
  `position_none`, an extras key set to `null`, `extras_none` — flags rather than empty values,
  because `omitempty` drops an empty array exactly like a missing one, which the first version got
  wrong and the round-trip test caught); `protocol.BuildPrev`/`ApplyPrev` are the two pure halves and
  `protocol/prev_test.go` round-trips every kind of difference through JSON.
- **Rate-gated, by interval, not by transport.** The visible cost of one lost packet is the send
  interval: 67ms at 15Hz, 16ms at 60Hz. The shipped 15Hz room carries it; the 100Hz dev rig does
  not. This is the answer to the bandwidth question — Pseudoregalia's 600-byte state at 60Hz,
  doubled, would be +130 MB/hour of upload per player fanned out with the square of the room, for a
  hole nobody can see. As shipped the cost is the changed fields of one sample per packet, at rates
  where a packet is already a rare thing.
- **Bounded like the state it rides in.** `ValidateState` applies every existing bound to the
  delta's own fields; `StatePrev` has no `prev` of its own, so it cannot nest. The relay's fuzz seed
  corpus carries two `prev` cases. `MaxLineBytes` still bounds the whole line.
- **The bracket sample (ADR 0039) is covered too**: it carries the pre-silence state, and the resume
  that follows carries the bracket, so losing either leaves the receiver whole.
- **The relay strips it from `lastState`.** A late joiner is seeded with the newest sample; the one
  before it is a hole-filler for someone who was listening at the time.
- **Two counters** on the client stats line: `carried` (sent states with a prev) and `recovered`
  (received prevs that filled a hole). Recovered is the number that says a link is losing packets.

## What it does not do

It covers ONE lost packet. Two in a row still lose the older sample; a burst still shows. Carrying the
last N is the same code with a list, and is not built until a run shows the need. It does nothing for
tcp, which does not lose. And it does not change the user's view of the transports (recorded in
`ideas.md`): quic is the default and the reason this exists; udp is an opt-in that gets it for free.

## Contract changes

`agent_docs/contract.md`: the packet schema gains the optional `prev` field; Limits notes that it is
bounded by the same rules. No existing field changes shape; an older peer ignores `prev` under the
unknown-fields rule.
