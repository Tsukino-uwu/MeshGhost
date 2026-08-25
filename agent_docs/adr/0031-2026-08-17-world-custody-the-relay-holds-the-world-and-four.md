# 2026-08-17 — World custody: the relay holds the world, and four ways of doing it that fail silently

<!-- ADR 0031. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** Add `world.v1` (`world` / `world_state`): the relay keeps the latest opaque blob
  per entity, namespaced by the authority **lease key** the write was made under, and hands the
  whole set to whoever takes that lease next — and to whoever joins. Writes are accepted only from
  the lease's current holder. The relay reads none of it, exactly as with escrow deposits and
  `Join.State`. Requires `lease.v1` in the same room; neither implies the other.
- **Status:** Done. Relay, core, bridge, introspection, a worked example in
  `cmd/meshghost-fakeadapter`, and an `internal/e2e` run that kills a host *process* and watches a
  successor adopt the world off the floor.
- **Context:** "Could a mod make a game act as if it's online — player and enemies all spawned from
  the network?" The follow-up is what exposed the gap: **who is the host, and what happens when
  they leave?** "Host" is three jobs. *Designation* — `lease.v1` already did it. *Simulation* —
  excluded by architecture, the one job that needs to understand the game. *Custody* — missing.
  Without it a successor adopts from its own last-known view; every peer's is slightly different
  and slightly stale, so *which* peer takes over changes what the world becomes.
- **The four corrections, which is the real content of this ADR.** Each is silent: no error
  anywhere, just two clients looking at different worlds. Each has a test that fails without it.
  1. **`reliable` selects the delivery variant ONLY, never the serialization.** The tempting design
     is "lossy writes skip `sendMu`, like the state plane does". Wrong, and the premise is wrong
     too. Wrong because of reordering: a lossy write can be stamped first and delivered second, so
     the relay's map holds one value while every client's last-received is another — and nothing
     corrects it, because snapshots go only to joiners and a key may never be written again. Worse
     for a `drop`: overtaken by a stale `set`, the entity is resurrected permanently for everyone
     but the relay. And the "hot path" premise is false — the relay's inbound flood cap is
     `max(120, sendHz*6)` *per client*, so a host cannot legally emit more than ~120 writes/second
     regardless of entity count, a rate `sendMu` already serializes the whole control plane at. The
     rule, now stated in code: *a message may skip `sendMu` only if it is unstamped, latest-wins,
     and self-superseding at a fixed rate.* `protocol.State` qualifies; no world write does,
     because a world key's write rate is the adapter's choice and may be one-shot.
  2. **The adoption snapshot is built inside `grantLeaseLocked`**, not dispatched after it. Built
     after, the new holder can receive its grant, legally begin writing, and *then* receive a
     snapshot predating its own writes — reverting itself, with the relay correct and the host
     stale. Building it in the same `mu` section as the grant and delivering it in the same
     `sendMu` window makes "grant, then snapshot" a fact of the total order rather than a hope.
  3. **World lifetime is never tied to lease lifetime.** Freeing entries in `freeLeaseLocked`
     destroys the world in exactly the case the feature exists for — a host crashing reaches it via
     `expireSuspended` → `finishLeave` → `releaseLeasesOfLocked` — and a deliberate handoff reaches
     it too. Only the room going away discards a world; what accumulates meanwhile is bounded by
     `MaxWorldKeysPerRoom`, so it is a cap, not a leak, and no retention timer ships.
  4. **The pre-existing late-join seed was missing `sendMu`**, and this work exposed it. State got
     away with it because a stale seed self-corrects within 50ms; a world seed delivered after a
     concurrently-broadcast newer write leaves the joiner permanently stale. Factored into
     `Room.joinSnapshot`, in the shape of `resumeSnapshot`, which already took the lock.
- **Two more the soak found that reading did not.** Both are adapter-facing rules rather than relay
  bugs, and both passed cleanly on tcp and on lossless udp first — the shape of thing that ships.
  5. **A write that creates a key must be reliable.** The lossy and reliable planes are independent
     on a datagram transport, so a create dispatched before a drop can arrive after it and
     resurrect an entity. The relay ignores a lossy create and says so once per room. Creation and
     deletion then travel the same ordered plane and cannot overtake each other.
  6. **A lossy write replaces the whole blob**, so a blob may not mix a continuously-superseded
     field with one that must never regress: an inbound reorder drags the whole thing backwards,
     the relay's copy becomes the stale one, and the next snapshot propagates the regression rather
     than repairing it. The relay cannot detect this — it has no client-side stamp to judge with —
     so it is a contract rule: separate keys, discrete state reliable, position lossy.
     Additionally, **an adoption always sends exactly one snapshot, empty world included**, so a
     new host can distinguish "nothing to adopt" from "my adoption has not landed"; without that a
     host writes over a world it has not seen and renumbers it downwards.
- **Bounds are derived from the datagram limit, not from `MaxLineBytes`.** `udpconn.checkWritable`
  refuses an oversized datagram *including a reliable one*, and reports it only as a log line — so
  an oversized custody message is silently lost for that recipient and never superseded. Hence
  blob ≤ 768, key ≤ 64, authority ≤ `MaxLeaseKeyLen`. `MaxWorldKeysPerRoom = 64` is **derived, not
  chosen**: it is `udpconn`'s `reorderWindow`, because a reliable burst wider than that window is
  not held, is therefore not acked, and is retried until the connection closes. The relationship is
  asserted by a test in `package udpconn`, the only place that can see the unexported constant —
  same discipline as `RateLimitHeadroomMultiple`.
- **Consequences:** `outgoing` gains an `unreliable` flag, so `deliver`'s "there is no unreliable
  variant on purpose" is now a documented exception rather than an absolute. The writer is excluded
  from its own broadcast (unlike an event, where the echo is how a sender learns its own stamp),
  which halves the busiest client's inbound. Introspection reports entity counts and byte sizes per
  authority and never blobs, and calls an un-owned world out in words, because that is the state
  custody exists to produce rather than a fault. A room negotiating `world.v1` without `lease.v1`
  is logged once rather than rejected: making one imply the other in `NormalizeFeatures` would
  change the sticky `FeatureSetKey` and silently stop matching rooms that already agreed on the old
  string. The same datagram arithmetic turned up a **pre-existing** bug that is not fixed here and
  is recorded in `risks.md`: a maximal `Event` renders to 1321 bytes and a committed `EscrowState`
  with two blobs to 2294, against 1182 usable — both undeliverable to a udp peer today, despite
  `MaxEventBytes`' own comment claiming it was sized to fit. (That comment was corrected
  2026-08-18 and the relationship is now pinned by tests in `netx/udpconn/world_bounds_test.go`;
  the constants are unchanged.)
