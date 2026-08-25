# 2026-08-13 — `Core.remoteStatesAt` filters remotes by `area_id`, unless our own area is unknown

<!-- ADR 0012. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-13
- **Decision:** `Core.remoteStatesAt` now excludes any remote whose `area_id` doesn't match
  this Core's own most recently known `area_id`, unless the Core's own area is still unknown
  (never received a real local frame), in which case every remote passes through unfiltered.
- **Status:** accepted
- **Context:** Found live in the same real two-player TEVI test session as the bridge-
  disconnect fix above, once the two players moved through genuinely different zones (not just
  different rooms within one always-loaded zone). `core` sends every known remote
  regardless of `area_id` — a documented, previously-untested gap (`plans.md`). The remote's
  ghost kept rendering the whole time, using the peer's raw world coordinates from their own
  zone, with no relationship to the local zone's coordinate space. It only looked correct
  because the two test zones' coordinate ranges didn't happen to overlap anywhere visible on
  screen — confirmed by reading both BepInEx `LogOutput.log`s directly: `area=` changed
  `1→4→1→13→1` across five real zone transitions, but `"real remote ghost visual created"`
  logged exactly once, at initial connect, never again — the remote `GameObject` was never
  destroyed or recreated, just silently repositioned to nonsense coordinates every frame.
  Two zones whose coordinate ranges did overlap on screen would have produced a visible
  phantom ghost instead of a coincidentally-invisible one.
- **Options considered:** (1) leave it — rejected, this session's own log evidence shows it's
  not actually benign, only luck-dependent; (2) filter in each adapter individually — repeats
  per-adapter logic for something `area_id` equality already makes trivial to do once,
  centrally; (3) filter once in `core`, at the same point `remoteStatesAt` already
  builds the per-tick render set.
- **Resolution:** Option 3. Added `Core.localAreaID`, updated in `forwardLocalState` on every
  real local frame (`state != nil`) regardless of `MinSendInterval` throttling or whether a
  relay connection exists yet — filtering needs the adapter's true current area, not just what
  was last actually sent over the network. `remoteStatesAt` skips any remote whose `AreaID`
  doesn't equal `c.localAreaID`, unless `c.localAreaID` is still `""` (no real local frame yet),
  which passes everything through unfiltered rather than hiding all remotes on an unknown local
  area — this keeps every pre-existing test that never sends a local area (most of the
  `fakeAdapter`-driven suite) passing unchanged. Equality-only comparison, per `contract.md`'s
  `area_id` rule — never branches on contents. Reuses the existing render/despawn diff in
  `tickRenders` for free: a remote dropping out of `remoteStatesAt`'s filtered result is
  indistinguishable from one that actually left, so it already gets a real `despawn_remote`,
  and reappears via the normal render path once areas match again. Regression-tested:
  `TestCrossAreaFiltersRemote` in `core/core_test.go` drives a remote through
  same-area → different-area (must despawn) → same-area-again (must reappear).
- **Consequences:** Game-agnostic, benefits every adapter with no per-adapter change — closes
  the `plans.md`/`phase6.md` "genuinely unbuilt" gap. Since **confirmed live on TEVI** — a remote
  in a different zone is no longer rendered at all and reappears cleanly on return; the same
  session found and fixed a reactivation animation freeze. See `verified.md`'s "TEVI cross-area
  filtering confirmed live" entry.
