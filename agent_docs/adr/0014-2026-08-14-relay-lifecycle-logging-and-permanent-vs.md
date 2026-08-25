# 2026-08-14 (same-day follow-up) — Relay lifecycle logging, and permanent vs transient rejects

<!-- ADR 0014. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-14 (same-day follow-up to the ADR above)
- **Decision:** Add lifecycle logging (join/leave/reject) at the relay; classify a relay
  `Reject` as permanent or transient (`core.RejectError`/`core.IsPermanentRejectErr`,
  `protocol.ReasonServerFull` the one transient reason); cache a permanent rejection on the
  `Core` so a retrying adapter doesn't keep re-dialing an already-known-hopeless connection;
  and make `cmd/meshghost`'s eager `-game` startup path retry until the relay is reachable
  instead of crashing the whole process on the first failed dial.
- **Status:** accepted
- **Context:** Three real gaps surfaced in conversation while reviewing the room-code/version
  ADR above, each traced back to something this project's own review missed rather than a new
  request out of nowhere:
  1. The user asked how a host or player would actually find out a `hello` was refused. Answer,
     checked against the code: **nowhere adequate.** `rejectAndClose` (added by the ADR above)
     sent the reason to the client, but never logged anything server-side — a host had zero
     visibility that anyone was ever refused. The reason did reach `core`'s own log,
     but no further: every shipped adapter, on a closed bridge connection, just logs a
     generic "lost, will retry" and loop silently forever with no reason ever reaching the
     player. Separately, the relay's own log had never recorded a successful join or leave
     either — a gap the user had already flagged once before, in the cross-machine session
     entry in `verified.md`, and it was still unaddressed.
  2. The user then asked whether the client had to be started after the server. Checked against
     the code: **yes, for the eager `-game` path specifically.** `cmd/meshghost`'s eager branch
     called `Core.ConnectRelay` once, synchronously, and `log.Fatalf`'d the whole process on any
     failure — including a plain "relay isn't up yet" dial error, indistinguishable in that
     branch from a real permanent refusal. The lazy path (no `-game`, the real shipped
     `config.json`'s actual default) already tolerated this for free, since a failed
     `ConnectRelayOnAdapterHello` only closes one bridge connection and the adapter's own
     reconnect loop drives the next attempt — but that same mechanism had no way to distinguish
     "keep trying" from "this will never succeed," so a wrong room code or version mismatch
     would have silently retried forever too, hammering the relay and this process's own log
     with an identical failure indefinitely once fixed to not crash.
- **Options considered (logging):** (1) log everything, including per-`state` traffic — rejected
  outright, this is exactly the spam the user explicitly warned against and duplicates what
  `MaxMessagesPerSecond` already guards against; (2) log only lifecycle events (hello
  reject/accept, join, leave) — these happen once per connection event, not per frame, so
  logging every one of them cannot spam regardless of session length; (3) option 2, plus
  per-message-content dedup on the *core* side specifically, since a retrying adapter can
  legitimately hit the *same* connect failure many times in a row where the relay's own
  lifecycle events (each a genuinely new occurrence) don't have that problem.
- **Resolution (logging):** Options 2 and 3 together. `relay.rejectAndClose` now logs
  the reason plus the offending `hello`'s `game_id`/`room`/`display_name` before closing; a
  successful join logs the assigned `player_id`, display name, room, and game; a disconnect
  logs the leaving `player_id` and room. `core.ConnectRelayOnAdapterHello` logs a
  connect failure only when the message actually changes from the last one logged
  (`Core.lastConnectErr`), so a long wait for the relay to come up, or a room stuck full for a
  while, produces one line per *actual* state change, not one per retry.
- **Options considered (retry vs. crash):** (1) leave the eager path crashing on any failure —
  simplest, but directly contradicts what the user just asked for; (2) retry inside
  `cmd/meshghost` using `Core.ConnectRelay` directly, with its own backoff loop — works, but a
  real adapter could *also* connect over the bridge and send its own `hello` for the same
  `game_id` while this loop is still waiting, and since `ConnectRelay` doesn't serialize against
  `ConnectRelayOnAdapterHello`'s `relayConnectMu`, the two could race to dial independently;
  (3) route the eager path's retry loop through `ConnectRelayOnAdapterHello` itself instead of
  `ConnectRelay` directly, so both entry points serialize on the same lock and share the same
  permanent/transient classification and logging.
- **Resolution (retry vs. crash):** Option 3. `RejectError` (`core`) wraps a relay
  `Reject`'s reason so it can be distinguished from a plain dial/timeout error without string-
  matching a formatted message. `isPermanentRejectReason` treats every reason except
  `protocol.ReasonServerFull` as permanent — the only one of the named reasons *as of this ADR*
  (`ReasonProtocolVersionMismatch`, `ReasonHelloFieldTooLong`, `ReasonInvalidRoomCode`,
  `ReasonGameMismatch`, `ReasonGameVersionMismatch`, `ReasonServerFull`) that can resolve on its
  own without a config change, if someone else leaves the room. **Superseded by the 2026-08-15
  rate-control ADR below**: the code now works from an explicit *retryable* set of two —
  `ReasonServerFull` and `ReasonRateLimited` — and two more reasons exist that this list predates
  (`ReasonGameNotAllowed`, `ReasonRateLimited`). `Core.permanentRejectGame`/
  `permanentRejectReason` cache a permanent rejection per `gameID`, checked before dialing;
  `IsPermanentRejectErr` is exported so `cmd/meshghost`'s new `connectRelayWithRetry` (backed
  off 1s→15s, doubling) can decide whether to keep retrying or `log.Fatalf` — a permanent
  rejection still ends the process loudly, since that's a real, unresolvable-by-retrying
  refusal, not "the relay isn't up yet." `cmd/meshghost`'s bridge listener now starts
  immediately regardless of relay reachability (the relay connect is backgrounded, not blocking
  startup), matching the tolerance the lazy path already had.
- **Consequences:** Both `cmd/meshghost` startup paths (`-game` set or not) now tolerate the
  relay coming up after the client, with no ordering requirement either direction — confirmed
  live (not just `go test`): real `meshghost.exe` started against a relay address nothing was
  listening on yet, logged the retry message exactly once despite several retry cycles across
  ~15 seconds, then connected automatically the moment a real `meshghost-relay.exe` started on
  that address, with matching join lines appearing in both processes' logs at that same moment
  — see `verified.md`. A permanently-rejected `-game` startup (bad room code, version mismatch)
  still exits the process via `log.Fatalf`, unchanged from before this ADR — only the
  transient/"not up yet" case gained tolerance. `cmd/meshghost-fakeadapter` was deliberately
  left on the old one-shot `ConnectRelay`+immediate-error pattern: it's dev-only tooling meant
  to fail fast and visibly if pointed at a bad address, not something that needs to tolerate a
  slow-starting relay the way the real shipped client does.
