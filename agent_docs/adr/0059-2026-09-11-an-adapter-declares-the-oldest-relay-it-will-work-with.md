# 2026-09-11 — An adapter declares the oldest relay it will work with

<!-- ADR 0059. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** `bridge.Hello` gains `min_protocol_version`, an integer. It is the oldest relay
  **that adapter** will work with, checked by the core against the `protocol_version` the relay
  announces in its Welcome. Below it, the core refuses the relay session with a permanent
  `RejectError` carrying `protocol_version_mismatch`, exactly as it already does for its own floor.
  Absent or `0` means "no opinion" and is what every shipped adapter sends today.
- **Status:** Go side built and tested 2026-09-11 (`refuseWelcomeVersion`, three tests: a relay
  below an adapter's floor is refused permanently, no floor accepts whatever the build accepts, and
  a floor *below* the build's own cannot loosen anything). **No adapter declares one yet** — by the
  policy below, none has earned it.
- **Asked for by the user**, 2026-09-11, as "similar to the server/client min floor we already
  have", in the conversation that fixed the adapter half of ADR 0058.

## Why an adapter gets a say at all

An adapter never learns a relay address and never sends a byte off-machine, and nothing here
changes that: the adapter states a number, the **core** does the comparing and the refusing.

The floor that already exists (`protocol.MinProtocolVersion`, applied at both ends) answers "can
these two builds talk" — a property of the **wire**. That is not the question an adapter has. An
adapter can depend on a field an older relay never forwards, and the wire floor has no opinion
about that, because the wire is fine. So the adapter connects, renders, and is quietly missing the
thing it was written for.

**That silent degradation is the failure this repo keeps rediscovering** — the stale-binary
room-code case in `risks.md`, the four adapters that branched on a reject reason nobody had checked
(ADR 0058), the fuzz harnesses that passed while exercising nothing. Saying the number turns it
into a refusal that names both versions and says which end to update.

## The rule that keeps it safe: it may only ever tighten

`refuseWelcomeVersion` applies `protocol.AcceptsPeerVersion` **first and unconditionally**, and
only then the adapter's number. An adapter naming a floor below this build's own changes nothing.

That order is the whole safety argument. A field that could *loosen* a check from outside the
process would be worse than no field — a mod could talk a core into a room the core itself had
decided it could not speak to. The test `TestAnAdapterCannotLowerTheBuildFloor` exists to fail if
that order is ever swapped.

## When to raise it, which is the part that will actually go wrong

**The user's call, 2026-09-11: a MAJOR or SECURITY update to that adapter, and nothing else.**

> "if an adapter gets a major update/security for example we raise the floor to match the current
> client/server and enforce things a bit. if its just syncing a bit more/less things visually there
> is not really any need to raise it as the server/client covers most of the safety/security things
> anyway"

So the temptation to resist is bumping it because an adapter now sends one more extras key. The
client and the relay already carry the safety floor between them; raising this for a cosmetic
change refuses rooms for no gain and splits the player base over something nobody can see. Raise it
when an adapter genuinely cannot work correctly against the older wire.

**And it is raised BY HAND, said out loud, never inferred from a diff** — the user, the same day,
for both floors:

> "I will say manually whenever we raise the floor, server/client is always together and usually
> after big milestones like v1.0.0 or when we reach v2.0.0. per adapter i will say manually as
> well, they can lag after if no changes have been made, but if an adapter have any major changes
> done it will match whatever the client is at the time as the min floor"

Two rules fall out of that, and they are written where each number lives rather than only here:

- **The WIRE floor (`protocol.MinProtocolVersion`) moves on the client and the relay together**,
  and usually at a milestone rather than because a field was added.
- **An adapter's floor is allowed to LAG.** One with no changes keeps the number it has. One that
  gets a major change takes whatever the client is at that moment — which is what turns "the mod
  and the client shipped together" into something a running process can check.

## What this is deliberately NOT

**Not a per-GAME floor**, which is what Archipelago's per-slot `minimum_client_versions` would have
become here. That was considered and rejected in the same review pass that proposed the wire floor
(the D6 decision: never separate game builds). The distinction is that this number belongs to the
**adapter binary**, not to the game it adapts: two people playing the same game with the same mod
build send the same number, and a room never has to reason about which game a member is playing to
know whether its versions agree.

**Not a relay-side check.** The relay still knows nothing about games or adapters, and this adds
nothing to `protocol.Hello`. The comparison happens entirely inside one player's own core, on data
that never crosses the network.

## The gate that had to be told

`internal/gameblind`'s `TestWireFieldsAreFrozen` refuses a new `bridge.Hello` field until someone
justifies it, and it refused this one. The justification, recorded there: `min_protocol_version` is
a **number the core compares and never interprets**. There is no game whose floor differs from
another's for a reason about the game — only for a reason about the mod binary — so it carries no
game knowledge, which is the test's second criterion.

The same pass tripped `TestAdaptersNeverSpeakTheRelayProtocol`, on a reject **code** used as an
example in an adapter's test file. That one was right to fire and the example was changed rather
than exempted: an adapter never sends a room code and has no reason to name one.
