# 2026-08-14 (found in live testing) — `Core` auto-retries a dropped relay connection

<!-- ADR 0016. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-14 (found during live testing of the sweep above)
- **Decision:** `Core` now auto-retries a dropped relay connection in the background after any
  *previously successful* `ConnectRelayOnAdapterHello` connect, not just the first attempt.
- **Status:** accepted
- **Context:** Live two-TEVI testing (both clients connected fine, then the shared relay was
  restarted) showed both clients logging `relay disconnected` and then sitting idle forever —
  no reconnect attempt at all, requiring a full client restart. Root cause: the only existing
  retry loop, `cmd/meshghost`'s `connectRelayWithRetry`, drives just the *first* connect attempt
  and returns once it succeeds (see the "client/relay start-order independence" ADR above); a
  real adapter's own bridge-Hello resend — the other trigger for `ConnectRelayOnAdapterHello` —
  only fires when the *bridge* connection itself drops, which a relay-only outage never touches.
  So a relay restart or network blip after an already-successful connect had no path back to
  "connected" short of restarting the whole client process. Separately, this same debugging
  session also surfaced that the actual `meshghost.exe`/`meshghost-relay.exe` binaries at the
  repo root were stale (dated the day before this entire review sweep) — `go build ./...`/
  `go vet`/`go test`, run repeatedly throughout the sweep, compile-check everything but don't
  refresh the named binaries the `dev-scripts/*.bat` files launch. Both issues compounded: the
  user's first repro was against binaries that predated even the start-order-independence fix.
- **Options considered:** (1) leave reconnection entirely adapter-driven (status quo) — simplest,
  but leaves exactly the gap just found; (2) have `cmd/meshghost`'s `connectRelayWithRetry` loop
  forever instead of returning after the first success — fixes the eager `-game` path only, does
  nothing for a real adapter (TEVI/Pseudoregalia/Emerald) whose relay drops while its bridge
  connection stays healthy, which is the actual case that broke live; (3) move auto-retry into
  `Core` itself, armed only by `ConnectRelayOnAdapterHello`'s own success path, so it covers both
  the eager path and a real adapter uniformly.
- **Resolution:** Option 3. `Core.autoRetryGameID`/`autoRetryAdapterGameVersion`/
  `autoRetryBridgeConn` are set on every `ConnectRelayOnAdapterHello` success; `ConnectRelay`'s
  `OnDisconnect` handler spawns `Core.reconnectWithBackoff` (same 1s→15s doubling shape as
  `cmd/meshghost`'s loop, but logs and stops on a permanent reject instead of `log.Fatalf`ing —
  `Core` is a library and must not exit the host process) whenever these are armed. Deliberately
  **not** armed for `cmd/meshghost-fakeadapter`'s direct `ConnectRelay` calls or `core_test.go`'s
  (both leave the fields at zero value, opting out by construction — matches the existing
  documented "fakeadapter fails fast on purpose" posture). A real regression caught by the test
  suite before shipping: `handleBridgeConn`'s existing behavior of closing `c.relay` when the
  *adapter itself* intentionally disconnects (so the relay broadcasts a real Leave) was racing
  against the new auto-retry and silently reconnecting with a fresh `player_id` before the
  disconnect could be observed — `TestReconnectAfterBridgeDisconnectGetsFreshPlayerID` failed.
  Fixed by disarming the auto-retry fields in that same code path, in the same critical section,
  before the deliberate `relay.Close()` — an intentional adapter-driven disconnect must stay
  disconnected until a fresh bridge Hello, not silently reconnect behind the adapter's back.
- **Consequences:** No wire-protocol change. Live-verified (not just `go test`): a real relay
  killed mid-session, a real client kept retrying with backoff and logging exactly once (existing
  dedup logic), then reconnected automatically the instant a new relay came up on the same
  address — see `verified.md`. `meshghost.exe`/`meshghost-relay.exe`/
  `meshghost-fakeadapter.exe` at the repo root were rebuilt from current source as part of this
  fix; there is no automated step that keeps them fresh across a session — rebuild explicitly
  after any `core`/`cmd/meshghost` change before testing via the `dev-scripts/*.bat`
  files, the same discipline already documented for the Pseudoregalia/TEVI adapter builds.

---

- **Date:** 2026-08-14 (retroactively ADR'd — a documentation sweep found this real wire-protocol
  addition had no ADR despite `CLAUDE.md` requiring one for contract changes)
- **Decision:** `Core` sends a `ping` every `DefaultHeartbeatInterval` (20s) on an otherwise-quiet
  relay connection.
- **Status:** accepted
- **Context:** A core with no adapter attached, or one whose adapter reported no local state for
  a stretch (e.g. parked at a menu), sent nothing to the relay at all. `transport.
  DefaultIdleTimeout` (60s) closed that as an idle connection, and the already-existing
  auto-reconnect immediately redialed — but `nextPlayerID` never reuses an id, so every other
  peer in the room saw a leave+join/ghost despawn-respawn cycle roughly once a minute, purely
  from a quiet client sitting still.
- **Options considered:** (1) raise `DefaultIdleTimeout` — treats the symptom, not the cause, and
  weakens idle-connection cleanup generally; (2) send a real heartbeat that keeps the connection
  demonstrably alive. The relay already replied to `Ping` with `Pong` (protocol support existed
  from earlier work) but nothing on the client side ever sent one.
- **Resolution:** Option 2. `Core.sendHeartbeats` sends `Ping` every `HeartbeatInterval`
  (default `DefaultHeartbeatInterval`, 20s — comfortable margin under the 60s idle timeout even
  accounting for scheduling jitter). This is deliberately **not** a liveness/RTT mechanism —
  `Pong`'s `Nonce` is echoed by the relay but not read by anything on receipt. **Superseded in
  part, 2026-08-17:** the core now *does* read the pong back, producing `Core.RelayRTTMs` and
  `Core.ClockOffsetMs` (lowest-RTT sample, applied only under `clock.v1`), and since 2026-08-18
  `meshghost -stats=<dur>` prints both. Drop detection is still not built on it. Drop detection is
  unchanged: still entirely `transport.DefaultIdleTimeout` closing the socket on a truly dead
  connection. `HeartbeatInterval <= 0` disables heartbeats entirely, used by `core_test.go` to
  reproduce the pre-fix idle-timeout-churn bug directly.
- **Consequences:** `contract.md`'s Transport section and message-type table updated to describe
  this accurately (an earlier version incorrectly described missed-pong-counting drop detection
  and an RTT-feeds-interpolation-delay mechanism, neither of which was ever implemented — found
  and corrected in the same documentation sweep that added this ADR). See `verified.md`'s
  "Core-relay heartbeat, found live and fixed" entry for the live confirmation.
