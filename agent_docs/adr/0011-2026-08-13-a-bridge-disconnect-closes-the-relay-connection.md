# 2026-08-13 — A bridge disconnect closes the relay connection, and a relay drop clears identity

<!-- ADR 0011. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-13
- **Decision:** A bridge (adapter↔core) disconnect now closes the Core's relay connection too,
  and a relay disconnect (any cause) clears the Core's relay identity (`c.relay`, `playerID`,
  `relayGame`) so a later bridge `hello` can redial.
- **Status:** accepted
- **Context:** Found live during the first real TEVI two-player test (two local instances
  through one real, non-loopback relay): a player backing out to the main menu stopped sending
  `local_state` (per `forwardLocalState`'s existing nil-means-"don't send this frame"
  contract), but nothing told the *relay* this player was gone. The remote's ghost stayed
  frozen in the other player's world indefinitely — there is no staleness timeout
  (`remoteBuffer.at()` holds the newest sample forever, by design, per its own comment) and the
  only thing that despawns a remote is a real relay `Leave`. Reconnecting made it worse: a
  second, correctly-positioned ghost appeared alongside the frozen one, because the Core never
  actually left the room in the relay's eyes, so there was nothing to distinguish "same player
  resuming" from "a new join."
- **Options considered:** (1) an idle/staleness timeout in `remoteBuffer` — a magic-number
  interval with no non-arbitrary value, and doesn't fix the "reconnect leaves both" half at
  all; (2) an explicit "despawn self" bridge/relay message — a new wire message type for
  something the existing disconnect machinery already does for every other disconnect cause;
  (3) tie the Core's relay connection lifecycle to its bridge connection lifecycle, so an
  adapter going away for any reason (game closes, bridge socket drops) reads as a real
  disconnect to the relay, the same as a network blip already does.
- **Resolution:** Option 3. `handleBridgeConn` (`core/core.go`) now closes `c.relay`
  when the bridge connection ends. `ConnectRelay`'s existing relay-`OnDisconnect` handler
  (previously only `dropAllRemotes()`, added for the unrelated "own relay died" case — see the
  ADR below) now also clears `c.relay`/`c.playerID`/`c.relayGame`, guarded by comparing against
  the specific connection that disconnected so a stale callback can't clobber a newer
  connection. This reuses the relay/core despawn path that was already built and tested
  (`TestDisconnectDespawnsRemote`, `TestOwnRelayDisconnectDespawnsRemotes`) rather than adding
  a third despawn mechanism. Regression-tested: `TestBridgeDisconnectDespawnsForPeer` (the bug
  as reported — closing the bridge, not the relay, must still despawn for the peer) and
  `TestReconnectAfterBridgeDisconnectGetsFreshPlayerID` (a disconnected Core must be able to
  redial and get a new `player_id`, not stay wedged) in `core/core_test.go`.
- **Consequences:** Game-agnostic — every adapter's game-close/reconnect now cleans up for
  free, no per-adapter change. Deliberately scoped to the bridge socket's actual lifecycle:
  TEVI's `Plugin.cs` keeps its bridge connection open across a return to the main menu (it only
  stops sending state), so main-menu cleanup is **not** covered by this change — see the open
  follow-up in `plans.md`/`risks.md` about verifying whether TEVI's `mainCharacter` reads null
  during a pause menu too before wiring an adapter-side disconnect into that transition. A real
  behavior change worth knowing: reconnecting after any disconnect now always gets a fresh
  `player_id` — there is no session resumption under the old identity.
