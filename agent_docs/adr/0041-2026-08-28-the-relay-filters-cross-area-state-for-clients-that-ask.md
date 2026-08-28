# 2026-08-28 — The relay filters cross-area state, for clients that ask for it

<!-- ADR 0041. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** A client may declare `own_area_only` in its `hello`, meaning "I render only peers
  whose `area_id` equals mine." The relay then stops forwarding it states from other areas, instead
  of spending both uplinks on messages the receiving core discards at render time anyway. **Absent
  means send everything.** Two rules keep it invisible: the state that ANNOUNCES a crossing is still
  delivered to the area being left, and a client entering an area is immediately seeded with the
  newest state of everyone already standing in it.
- **Status:** **Implemented 2026-08-28, Go side complete and confirmed with the tools.** Full suite,
  `-race` at `-count=3`, and a new `internal/e2e` case driving two real clients across a seam.
  **Measured against the real binaries**: a 16-peer room spread over 8 areas suppresses **93% of
  offered state bytes**; the same rig at one area suppresses 0% and forwards exactly what it always
  did. **Not yet watched on screen** — Emerald's cross-map ghosts are the case to look at, and per
  CLAUDE.md that is the user's to confirm.

## Why: this is a change of scaling shape, not a saving

`plans.md`'s "Efficiency is a standing goal" already frames it. A room's host uplink carries
`n × (n−1)` state messages — 2.2 GB/hour at 8 players, 39.7 at 32, impossible at 1000. Filtering by
area makes it `n × (peers in your area)`. **That is the difference between "8 is the practical
limit" and "the limit is how many people are standing in the same room",** and no amount of
shrinking a state line does it; only not sending it does.

The shadow counters that sized this shipped on 2026-08-18 (commit `e868597`) and were deliberately
placed at the exact point a real filter would run, so the number they had been reporting is the
number the filter now suppresses.

## What makes it safe: a strict subset of a check that already exists

`core.remoteStatesAt` already drops a remote whose `area_id` differs from the local one, at render
time, and **that check stays in place untouched.** The relay's rule is a strict subset of it, so the
picture on screen cannot change — except where the relay's view of a recipient's area is staler than
that recipient's own. That is the entire risk surface, and it is why this was designable at all.

Every condition fails OPEN, each mirroring a core-side one: an unknown sender area, an unknown
recipient area, or a recipient that never opted in.

## The two rules that are not optional

**A crossing state still goes to the area being LEFT.** A peer walking out of your area is announced
by exactly one message: its first state carrying the new `area_id`. That is what your core notices
the mismatch on and despawns the ghost for. Drop it and you hear only silence, `remoteBuffer`
edge-holds the last sample you did get, and the ghost **stands frozen at the doorway** until
`DefaultRemoteStaleAfter` (3s) ages it out — where the despawn today takes about one interpolation
delay. Trading a ~200ms clean despawn for a 3s frozen ghost is exactly what `plans.md:93` forbids
buying bandwidth with.

This was not foreseen in review. `core`'s own `TestCrossAreaFiltersRemote` went red the moment the
filter landed, which is the whole argument for a test suite that describes behaviour rather than
implementation.

**An arriving client is seeded with who is already there.** A filtered client receives nothing from
another area, so on arrival it knows nothing about the peers there and must wait for each to speak
— and **ADR 0039 means a motionless peer does not speak**, only re-stating every `IdleKeepalive`
(250ms). Without the seed, walking into a room where someone stands still shows an empty room and
pops them in a quarter-second later, at every seam, and gets *worse* the better suppression works.
Sent reliably: a dropped seed reinstates the pop, and unlike an ordinary sample there is no next one
coming.

## Why a new Hello field and not a `features` entry

`protocol.IsRoomScopedFeature` is a **deny-list defaulting to room-scoped**: an unrecognised
capability string is sticky on first join and refuses any later joiner whose set differs
(`ReasonFeatureMismatch`). A new client advertising this as a feature against an older relay would
therefore make a mixed room **unjoinable** — turning a bandwidth optimisation into a connectivity
bug. An optional field is the only fail-open option, and "just add a feature string" is the
obvious-looking wrong answer.

## Why absent must mean "send everything"

Not politeness — two live cases. An older client does not know the field. And an adapter that
translates a neighbouring map's coordinates renders peers in **adjacent** areas: Emerald always,
Crystal when its cross-map block is armed, both via `bridge.Hello`'s `RenderAllAreas`. The core sets
`own_area_only` as the exact inverse of that declaration, so those adapters are never filtered and
their shipped, user-confirmed cross-map ghosts are untouched. Being wrong about this costs bandwidth
rather than ghosts.

The decision is per RECIPIENT, so a room may freely mix a filtered client and a cross-map one. Per
room, one Emerald client would switch filtering off for a whole 32-seat lobby.

## What else changed

- **`Client.lastArea`**, a per-client cache of the last reported `area_id`, replacing a map lookup
  and a whole-`protocol.State` copy **per member per message**. Profiled at roughly 15% of the
  relay's per-state work before this existed. Seeded on join and resume — a resumed session keeps
  its `player_id` but arrives as a brand new `*Client`, so without seeding its area would start
  empty and fail open until its next state.
- **The counters split three ways** — forwarded, cross-area (the ceiling), and actually filtered —
  because with a filter live, conflating "could suppress" with "did suppress" would make the
  introspect line report a shrinking opportunity as the filter improved. Both shares now divide by
  the pre-filter total.

## What this does NOT do

- It does not filter by distance. That needs a game-shaped notion of "near", which the core and
  relay may not have (ADR 08-20). Area equality is the whole vocabulary.
- It does not help a single-area room, by construction. Measured at exactly 0%.
- It does not change the core's own filter, the wire format of `state`, or anything an adapter sees.
