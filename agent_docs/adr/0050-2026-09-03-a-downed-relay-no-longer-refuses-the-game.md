# 2026-09-03 — A relay that is merely down no longer refuses the game

<!-- ADR 0050. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** when an adapter's hello reaches a core that cannot DIAL its relay, the core keeps
  the adapter, says plainly that nobody else will appear, and retries the relay in the background
  (`retryRelayForSoloAdapter`). A PERMANENT refusal — wrong room code, version mismatch, a
  protocol gap — still rejects the adapter, because retrying fixes none of those and the player
  needs to be told.
- **Status:** built 2026-09-03, suite and `internal/e2e` green, the two tests that pinned the old
  behaviour rewritten to pin the new one. Watched only in the sense that the defect was found in
  the user's own game log; the fixed behaviour is not yet watched on screen.
- **Why, and it is a Phase 11 consequence rather than a new idea:** until now the client was a
  multiplayer client, so "no relay" honestly meant "no session". ADR 0047 made recording, replays
  and the chaser SOLO features that need no relay at all — and the refusal took them down with it.
  **Seen live:** `record_on_launch` armed in Pseudoregalia with no relay running wrote nothing,
  because the recorder tap only runs on frames an attached adapter sends and the adapter was
  refused on every hello, once every ten seconds, forever. The user's expectation, which is the
  right one: *"i just assumed both recording & playing back would work offline/without a server"*.
- **What this is NOT:** the `offline` setting (shipped the same day) is still worth having and is
  unchanged. `offline: true` means *never dial, do not retry, say nothing* — a deliberate choice
  for someone playing alone on purpose. This ADR is about the accident: a server that is late,
  down, or forgotten.
- **The failure mode this also removes, which was already known and worked around in four
  adapters:** a refusal per hello is what cooled port after port until a real user's sweep reported
  "NO free port to start a core on" (2026-08-28). Every adapter grew a guard matching the substring
  `relay` in the reject reason to tell "wait here" from "walk on". A core that accepts cannot start
  that cascade at all. **The word contract still stands for the refusals that remain** and
  `TestAPermanentRelayRefusalStillSaysRelay` pins it, so no adapter needs changing.
- **The invariant that keeps tests honest, and it was the user's question when this was built:**
  a solo core has NO PLAYER ID. Everything that measures a real relay — `waitForPlayerID`, the
  schedule fuzzer's `sees` (which refuses an empty id explicitly), every `internal/e2e` assertion
  on a peer's `render_remote` — therefore still cannot pass without a relay having answered.
  "The adapter attached" is no longer evidence of a server, and the e2e helper says so where
  someone would otherwise rely on it. `TestASoloSessionUpgradesWhenARelayAppears` proves the state
  is temporary rather than terminal: start the game first, start the server second, and the room
  joins itself.
- **It flaps, and a recording does not notice — asked by the user the same evening, and answered
  with a test rather than with reasoning.** `TestASessionFlapsBetweenSoloAndJoinedAndTheRecordingSurvivesIt`
  drives solo -> joined -> solo -> joined by starting and killing a real relay on one address, with
  a recording running throughout, and asserts all of it: the core returns to solo when the server
  dies (`forgetRelaySessionLocked` clears `playerID`, so it is genuinely solo again rather than
  merely disconnected), it rejoins when the server comes back, and the recording is ONE CONTINUOUS
  CLIP — monotonic timestamps, no gap large enough to be a playback seam (`replayGapSeamMs`, which
  would otherwise show as the ghost teleporting mid-replay), and the walk covering every phase.
  That holds because the recorder taps the local frame at the top of `forwardLocalState`, before
  anything about the relay is consulted. 20 consecutive runs clean.
  **The one caveat, unexercised because the feature is off in every room today:** the recording is
  stamped on `nowMs`, which carries a clock-sync offset when `clock.v1` is negotiated. A join that
  applied a large offset mid-recording would jump that clock forward and could punch exactly the
  seam-sized hole this test forbids. `nowMsLocked`'s clamp stops it going backwards; nothing stops
  it jumping ahead. If clock sync is ever turned on, re-run this test with it on.

- **Retry loop kept separate on purpose.** `reconnectWithBackoff` (a relay DROP under a live
  adapter) was left alone: it is entered from a path where the bridge connection deliberately is
  not the attached adapter (the ownership transfer), and adding a stop condition for the solo case
  broke exactly that — caught by `TestASessionDyingDuringOwnershipTransferStillReconnects` within
  minutes. The solo loop is its own function with the stricter check it actually needs.
