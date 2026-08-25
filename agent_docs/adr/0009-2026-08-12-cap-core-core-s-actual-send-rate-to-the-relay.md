# 2026-08-12 — Cap `core.Core`'s actual send rate to the relay

<!-- ADR 0009. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-12
- **Decision:** Cap `core.Core`'s actual send rate to the relay
  (`Core.MinSendInterval`, default 50ms / 20Hz) independent of how often an adapter calls in,
  rather than relying on the relay's `MaxMessagesPerSecond` limit alone.
- **Status:** accepted; the *default* is superseded by the 2026-08-15 rate-control ADR below —
  `MinSendInterval` now defaults to the zero value, meaning "follow the relay's `send_hz`", and
  50ms/20Hz survives as `DefaultMinSendInterval`, the fallback. The cap itself is unchanged.
- **Context:** Phase 6 (TEVI) hit this live: TEVI's `Update()` calls the bridge every real game
  frame with no engine-level cap, and `forwardLocalState` previously sent to the relay on every
  such call. The relay's `MaxMessagesPerSecond = 120` (`agent_docs/contract.md`'s Limits
  section) *closes* an over-limit connection rather than throttling it, and TEVI's uncapped
  frame rate exceeded it — the connection was closed by the relay after about two minutes of
  real play, confirmed live (`relay: client exceeded 120 messages/second, closing connection`
  in the relay's own log). The contract's prior text ("up to ~60Hz, one per adapter frame") was
  itself already a wrong assumption for a frame-driven engine adapter with no fixed cap — it
  held for BizHawk's ~60fps `emu.frameadvance()`, not for Unity's variable, uncapped frame rate.
- **Options considered:** (1) raise `MaxMessagesPerSecond` on the relay — treats the symptom,
  not the cause, and does nothing for a still-faster future adapter (144Hz+ displays); (2) push
  the cap into every adapter individually — repeats the same throttling logic per adapter,
  exactly the kind of duplicated "genuinely hard, genuinely reusable" work `contract.md`'s tick
  model section already argues against; (3) cap it once in `core`, where the relay
  connection is actually owned.
- **Resolution:** Option 3. `Core.MinSendInterval` (default `DefaultMinSendInterval = 50ms`,
  overridable per-`Core` the same way `InterpolationDelay` is) gates `forwardLocalState`: a
  call before the interval has elapsed since the last actual send is silently dropped (no
  `seq`/`timestamp` stamped, since it never reaches the relay) rather than queued or coalesced.
  50ms (20Hz) leaves comfortable headroom under the relay's 120/s cap for any adapter frame
  rate, and does not claim to be the "right" sync rate — the brief's 10Hz hypothesis and the
  contract's two still-open questions (snapshot frequency, `seq`/`timestamp` semantics) are
  unaffected by this change. Regression-tested: `TestForwardLocalStateRespectsMinSendInterval`
  in `core/core_test.go` drives 1000 calls in a tight loop against a counting fake
  transport and asserts the send count stays capped, not 1:1 with the call count.
- **Consequences:** Every current and future adapter is protected from this failure mode
  without needing its own rate-limiting logic — game-agnostic, matches the core's existing
  "chatty over the bridge is free, chatty over the relay is not" posture. A real behavior
  change worth knowing: local state changes between two sends within the same 50ms window are
  now invisible to remotes (the newest state at send time wins, not a coalesced value) — fine
  for cosmetic ghost rendering, would need revisiting if a future Tier 3 feature (per
  `plans.md`'s depth ladder) needed every intermediate state observed.
