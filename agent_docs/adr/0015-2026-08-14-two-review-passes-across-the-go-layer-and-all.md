# 2026-08-14 (same-day sweep) — Two review passes across the Go layer and all three adapters

<!-- ADR 0015. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-14 (same-day review/refactor sweep)
- **Decision:** Two review passes (one Go-layer, one adapter) across `internal/`, `cmd/`, and
  all three adapters surfaced roughly a dozen real bugs, dead code, and stale comments; fix
  everything found rather than triaging into a follow-up backlog. Four of the fixes are real
  behavior changes worth recording as decisions, not just bug fixes:
  1. **Core-side finiteness/magnitude validation on remote `position`.** A remote peer can put
     `[1e400,...]` on the wire — syntactically valid JSON that overflows to `+Inf` on decode, or
     `1e308` that overflows to `+Inf` when narrowed to `float32` — and nothing anywhere checked
     for it (zero `math.IsInf`/`IsNaN` calls existed in `internal/`). This reaches Pseudoregalia's
     `sscanf`/`FRotator` and TEVI's `Transform` unfiltered. `core.storeRemoteState` now
     drops (not clamps — same "drop, don't store" posture as the existing size caps) any `State`
     whose `Position` contains a `NaN`, `Inf`, or `|x| > protocol.MaxPositionComponent` (new
     const, `1e7` — generous, not a measured game bound, chosen only to reject "obviously not a
     real coordinate" magnitudes). `orientation` stays opaque JSON the core cannot parse this way;
     each adapter is documented (`adapters/_template/PROTOCOL.md`) as responsible for bounding
     whatever numbers it pulls out of its own `orientation`/`extras`.
  2. **`core/interp.lerp` no longer blends across an `area_id` change.** Two bracketing
     snapshots with different `AreaID` previously had their raw world coordinates linearly
     blended and stamped with the older snapshot's `AreaID` — a phantom-midpoint result, the
     exact failure shape the 2026-08-13 cross-area-filtering ADR (above) exists to prevent, just
     one layer earlier than that ADR's own fix (which filters at render time, not interpolation
     time). `lerp` now returns the older snapshot outright when `AreaID` differs, mirroring the
     existing mismatched-length guard already in the same function.
  3. **`Core.ConnectRelay`'s 7 positional parameters collapsed to read `Core`'s own fields.**
     Every parameter but `gameID` already duplicated a `Core` field
     (`RelayAddr`/`Room`/`DisplayName`/`RoomCode`/`GameVersion`/`DialTimeout`) — the same
     duplication-is-a-bug-magnet shape already fixed once for `applyFileConfig` via
     `configTargets`. All three callers (`cmd/meshghost`, `cmd/meshghost-fakeadapter`,
     `core_test.go`) updated to the new signature; this is a source-breaking change to any code
     calling `ConnectRelay` directly (not the wire protocol, which is unaffected).
  4. **Pseudoregalia ghosts move offscreen on despawn instead of only `SetActive`-equivalent
     hiding.** Cosmetic-only fix, not a lifetime-management change — see the "Actor destroy
     unavailable" pitfall in `pitfalls.md` for why ghosts are never destroyed on this build at
     all. Before this fix, a peer leaving/reconnecting within a single area left their last-known
     ghost frozen in place with no visual indication anything had changed; now `release_ghost`
     moves it far offscreen first (the same proven `call_set_actor_location_and_rotation` path
     used everywhere else), so a same-area leave is visually silent instead of a visible frozen
     statue, while the level's own teardown on the next area transition still does the real
     reclaim, unchanged.
- **Status:** accepted
- **Context:** Set as the explicit next priority once the 2026-08-14 relay-safety ADRs above
  landed — a full review/refactor sweep across the server/client and all three adapters, since
  the hardening work above had been added incrementally across several sessions without a
  dedicated pass to catch what accumulated in the gaps.
- **Options considered:** fix everything found now (all four items above, plus every
  non-behavior-changing bug/race/dead-code item logged individually in `verified.md`/commit
  history rather than here) vs. triage into "must-fix now" and "follow-up backlog." The user
  chose fix-everything explicitly, plus rebuild+deploy Pseudoregalia, and explicitly **rejected**
  one reviewer conclusion: destroying Pseudoregalia ghosts, which would reintroduce the
  world-leak crash the move-offscreen design exists to avoid (see the pitfall entry).
- **Resolution:** All four items above shipped in this pass, along with the non-behavior-changing
  fixes (a wedged-core timeout leak, a `DialTimeout==0` instant-fail bug, a real `-race` data
  race on `playerID`, a cross-game bug where a second adapter's bridge connect could tear down a
  first adapter's already-working relay session, several smaller races/reorderings/dead-code
  removals in `internal/`) and the adapter-side fixes in Pseudoregalia's C++ (partial-send/
  unbounded-recv-buffer, connect backoff, unclamped numeric casts, cached-pointer hardening,
  callback unregistration), Emerald's Lua (partial-line receive corruption — see the pitfall
  entry above — partial send, dead-socket-after-hard-connect-error, a `pcall` around the main
  loop, control-char JSON escaping), and TEVI's C# (a stale-thread generation guard so an
  in-flight reconnect can't clobber a newer connection's state, `TcpClient` disposal, ghost/marker
  `GameObject`s actually `Destroy()`d instead of only deactivated, `OnDestroy`/
  `OnApplicationQuit` closing the bridge, `room_x`/`room_y` range-checked before a map-lookup
  call, and `TryGetValue` in place of unguarded `JObject` casts in `DrainInto`).
- **Consequences:** `protocol.Version` is unaffected — every change above is either server-side
  validation (already-permitted values still round-trip identically; only `NaN`/`Inf`/absurd
  magnitudes are newly dropped) or adapter-internal. The `ConnectRelay` signature change only
  affects Go code calling `core` directly, not the wire protocol or any adapter. The
  Pseudoregalia rebuild was hash-diff-confirmed deployed to the in-repo packaging copy; the live
  Steam install and the TEVI DLL rebuild remain manual follow-ups outside this repo's automated
  reach (packaging/README.md's existing staleness-check note covers the latter). The
  Pseudoregalia despawn-visual/area-transition half has since been watched live (`verified.md`,
  2026-08-14 — and it took a further real fix to pass); the finiteness/lerp fixes' observed
  behaviour has no live entry, per `CLAUDE.md`'s rule that nothing goes in `verified.md` until it
  has been watched on screen.
