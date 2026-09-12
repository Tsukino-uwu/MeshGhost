# 2026-09-12 — A client refuses a plane it never asked for, and bounds what the two unchecked ones carry

<!-- ADR 0062. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** the core **refuses an inbound `event`, `lease_state`, `escrow_state` or
  `world_state` unless BOTH sides negotiated that plane** — the room agreed it (`Welcome.Features`)
  *and* this client asked for it (`Core.Features`, or the adapter's own bridge `hello`). Refusing
  means the message is claimed and dropped: no callback, nothing forwarded to the adapter, no error
  raised. The send paths already gated on the room's agreed features; the receive paths gated on
  nothing at all.
- **Second decision, same shape:** `lease_state` and `escrow_state` get receive-side validators
  (`protocol.ValidateLeaseState`, `ValidateEscrowState`). They were the only two relay→client
  messages that reached a game with **nothing checked**, while `event`, `state` and `world_state`
  each had a mirror of their sender-side validator.
- **Consequence, stated plainly:** a relay can no longer push an opt-in plane at a client that is
  not running it. In the configuration almost everybody runs — a cosmetic room, every shipped
  adapter, no `features` set — all four planes now stop at the door. A room that genuinely
  negotiated a plane is unaffected: the gate passes whenever the handshake said it should.
- **Status:** shipped 2026-09-12, commit `d0dc9ecf`. `run-gotests.bat` green; regression tests in
  `core/inboundplanes_test.go` confirmed failing without the fix.
- **Found by** the third adversarial review (P3a-2).

## Why the gate is not simply the mirror of the send path

This is the part worth writing down, because the obvious symmetry is wrong.

`sendControlOn` gates on `c.activeFeatures` — the room's agreed capability set. Mirroring exactly
that on receive would look complete and buy nothing against the attacker in question, because
**`activeFeatures` is filled from the relay's own `Welcome`.** A hostile relay that wants to push a
plane simply advertises it, and a gate reading only that value is a gate the attacker writes.

So `planeNegotiated` requires the other half too: that *this side asked*. That value comes from the
client's own config and the adapter's own hello, and no relay can reach it. The check is an AND, and
the second term is the one doing the work.

The same reasoning does not apply to the send path, which is why it is not changed: sending into a
plane the room did not agree is a correctness question, not a trust one.

## What it actually prevents

An empty `{"type":"event","payload":{}}` passes `ValidateEvent` — an empty event is a legal event.
The event lane on the bridge does **not** coalesce (only renders do), so repeating that message
fills the adapter's queue to `adapterQueueCap`, at which point the writer's verdict for a full queue
is "stuck, not slow": it closes the adapter's socket and runs the full teardown, taking the ghosts,
the chasers, the replays and any recording in progress with it (`core/adapterwriter.go`).

That is the damage — not a stray message, a dropped bridge — and it needed no invalid field to do it.

## The validators mirror with `len()`, not `JSONWireLen`, and that is deliberate

2026-09-08 and 2026-09-12 both produced the *forwarding* version of this bug: a bound measured on
the bytes in hand while the cost was spent on the bytes `encoding/json` writes. The instinct after
two of those is to reach for `JSONWireLen` everywhere.

Here that would be wrong, and wrong in the invisible direction. The core is a **terminal** receiver
for these two messages: the wire form was already bounded by the line cap on the way in, and nothing
re-encodes them. Measuring more strictly than the sender did would drop legitimate traffic that a
relay running this same code considered valid — the inverse defect, with the same property of
reporting nothing when it fires.

**The rule that generalises:** measure a bound the way the party that has to satisfy it measures it.
A forwarder measures what it will write; a terminal receiver measures what it was handed.

## New bounds this introduces

Both are receive-side only, and neither tightens anything a sender already had to satisfy:

- `MaxStateReasonLen` — the human-readable `reason` on a `lease_state`/`escrow_state`. Derived from
  `MaxHelloFieldLen` rather than being a fourth loose 128 (see `MaxHelloFieldLenForID`, created for
  exactly that drift). Every reason this relay sends is one of the `Lease*`/`Escrow*` constants, the
  longest of which is 23 bytes.
- `MaxEscrowParties` — two, by definition, since "both or neither" is what the plane is for. It
  exists as a bound because `Parties`, `Deposited`, `Committed` and `Blobs` are collections the
  **relay** fills, and a receiver that trusted their length would iterate as many entries as a
  4 KiB line can hold.

## What this does not close

- It does not stop a relay pushing a plane at a client that legitimately runs one. A room that
  agreed `event.v1` still receives events, at whatever rate the relay likes, bounded only by the
  client's absence of an inbound rate limit — which is a separate, accepted risk (`risks.md`).
- It does not authenticate the relay. Every plane message still arrives from whoever the client
  dialled, and "you trust whoever hosts" is unchanged (`docs/security.md`).
- It is not a substitute for adapter-side validation. The core bounds **shape**; only the adapter
  can bound **meaning**, and `internal/gameblind` keeps it that way.
