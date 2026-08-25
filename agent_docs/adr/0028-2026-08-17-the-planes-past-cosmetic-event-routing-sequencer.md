# 2026-08-17 — The planes past cosmetic: event routing, sequencer, leases, escrow, resumption, clock sync

<!-- ADR 0028. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** Build every gap in `beyond-cosmetic.md`'s readiness table that a **dumb relay** can
  carry, and build none of the three it rules out. Shipped: addressed `event` routing, a per-room
  sequencer giving one total order, lease authority over opaque keys with real lifetime handling,
  two-sided atomic escrow, late-join state snapshots, relay-served clock sync, stable identity via
  session resumption, and `features` negotiation with per-room stickiness. **Everything is off
  unless every member of a room asks for it, and no shipped adapter does.**
- **Status:** Done, in `protocol/online.go`, `relay/online.go`,
  `core/online.go`, plus bridge message types and config plumbing on both binaries.
  Verified with the Go tools per CLAUDE.md — `relay/online_test.go` and
  `core/online_test.go`, three new fuzz targets, the full suite at `-count=10`, and
  `internal/e2e` unchanged and green. **No live game test, and none is owed**: nothing here
  touches a game, which is exactly the split that makes the deterministic side self-verifiable.
- **Context:** Asked for directly — implement what full/proper online needs, ahead of any game
  needing it. `beyond-cosmetic.md` had already done the analysis and named which gaps the opacity
  trick still covers; this is that document built rather than re-derived.
- **Options considered:** (1) build only the event plane, since it was the one thing already
  reserved — but the event plane alone is a message bus, and every actually-hard problem
  (contention, atomicity, identity across a drop) sits above it; (2) build the whole table
  including persistence and a game-aware validator — rejected, see Consequences; (3) build exactly
  the dumb-relay subset, which is what was done.
- **Resolution:** Option 3. The load-bearing insight, restated from `beyond-cosmetic.md` because
  everything below depends on it: **authority over *order* is not authority over *meaning*, and
  only the second requires game knowledge.** The relay arbitrates by arrival — first claim wins,
  by fiat — and everyone agrees because everyone was told the same answer, not because the answer
  was correct on the merits. Every identifier it handles (lease key, escrow id, event payload,
  feature name) is an opaque string compared by equality, exactly like `area_id` and `anim`.
  Specific choices worth recording:
  - **Feature stickiness treats an empty set as a real value**, unlike `game_version`'s
    "undeclared means don't check". The hazard being closed is one client claiming properly while
    another simply acts, so "advertised nothing" is precisely the case that must be refused.
  - **`MaxEventBytes` is uniform (1024), not transport-dependent.** `beyond-cosmetic.md` §9 left
    both honest; uniform means an event means the same thing on every transport and needs no size
    negotiation, at the cost of a smaller ceiling for stream transports. **No fragmentation**: an
    oversized payload should be a reference to the data, not chunks of it.
  - **Escrow is a separate mechanism from leases, not a use of them.** A lease grants exclusive
    *access*, never an atomic *swap*; conflating the two is where historical Pokémon trading
    exploits came from.
  - **Terminal escrow records are retained for 60s and replayed on resume.** This is what makes
    "both or neither" survive a crash rather than only a refusal — without it the guarantee holds
    only while both sockets stay up, which is the case that never fails in testing.
  - **Clock sync keeps the lowest-RTT sample, not an average**, and the relay is the clock rather
    than any peer. Nobody has to be correct about the real time; they only have to agree, and the
    relay is the one thing every member of a room already shares.
- **Consequences:** Three gaps stay open on purpose, and the reasons differ:
  **anti-cheat is impossible by construction** (catching a lie requires knowing what is true —
  simulation authority, excluded); **persistence is refused** because a relay with storage,
  backups, migrations and corruption handling stops being a thing a user runs from a `.bat` file;
  **deterministic lockstep is per-game** and ruled out for Unity/Unreal by float drift and
  non-deterministic update ordering. `beyond-cosmetic.md` §11's exclusion of full continuous
  game-aware co-op therefore still stands, and **none of this is permission to go past Tier 2** —
  that needs writing game memory, which remains a per-game opt-in with its own gate.
  One real regression risk was found and fixed during the work rather than after: stamping a total
  order under the room lock and *sending* after releasing it delivers the right order in the wrong
  sequence, since two handlers stamped 1 and 2 can race to the socket. It failed the total-order
  test on that test's first run. The fix is a per-room send lock held across both halves, which
  costs the control plane a serialization point; the state plane is deliberately excluded from it,
  being lossy and latest-wins by contract, so the 20Hz hot path is untouched.
