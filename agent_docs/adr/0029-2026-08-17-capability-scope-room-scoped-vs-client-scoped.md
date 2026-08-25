# 2026-08-17 — Capability scope: room-scoped vs client-scoped, and session takeover

<!-- ADR 0029. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** Split `features` into capabilities every member of a room must agree on
  (`event.v1`, `lease.v1`, `escrow.v1`, `clock.v1`) and capabilities that concern only one client
  and the relay (`resume.v1`, `snapshot.v1`). Only the first kind is sticky. Separately, register a
  resumable session when its token is **issued** rather than when the connection drops, so a
  reconnect can take over a session the relay still believes is live.
- **Status:** Done, with tests, and both halves confirmed against the real binaries rather than only
  in-process. `dev-scripts/run-relay-online.bat` and `run-core-pseudoregalia-online.bat` exist to
  run the pair on two machines.
- **Context:** Asked whether the shipped adapters could use any of the new capabilities. Two were
  worth enabling immediately because they need no adapter change at all — `clock.v1` (interpolation
  degrades *silently* under clock skew, per `testing.md`, and that only matters across two
  machines) and `resume.v1` (the 2026-08-14 incident where a relay restart left cores idle, and the
  reconnect-churn the heartbeat exists to prevent). Trying to actually wire them up is what exposed
  both problems below.
- **Options considered:** (1) leave the single sticky rule — one rule, no exceptions, but it prices
  resumption at a lockstep reconfiguration of every player for something no peer participates in,
  which in practice means nobody enables it; (2) drop stickiness entirely — reopens the exact
  silent-mismatch hazard the check was built for; (3) split by scope.
- **Resolution:** Option 3, with **unrecognised names treated as room-scoped**: a future shared
  capability wrongly classed as client-scoped would silently not be enforced, while the opposite
  mistake merely asks for an unnecessary config change. Annoying beats silently broken.
  The takeover half was not part of the original plan and was found by running it. Registering a
  session only on disconnect means a resume works solely when the relay noticed the drop *first* —
  and on quic it routinely does not: a hard-killed peer sends no close frame, so the connection
  lingers until quic's idle timeout, measured at **~17s against an immediate RST on tcp**. A client
  reconnecting inside that window presented a token matching nothing, received a fresh `player_id`,
  and left its old ghost standing until the timeout. That is strictly worse than not having
  resumption, and it is the *common* case, so the feature would have shipped looking correct in
  every test and wrong in every real use.
- **Consequences:** Enabling resumption is now a per-player decision that costs nobody else
  anything, which is what makes it usable at all. `welcome.features` had to start reporting what is
  in force **for that client** rather than for the room, since the question is now per-client.
  `Server.Snapshot`'s suspended count had to stop being `len(sessions)` — that map now holds every
  live identity, so it would have reported a healthy three-player room as three suspended sessions,
  the exact class of confidently-wrong number a debugging aid must never produce.
  Three limits are now documented rather than assumed, all measured the same day: resumption does
  not survive the client process closing (the token is in memory — correct, since a closed game
  should be a real leave), does not survive a relay restart, and **barely matters on tcp for short
  outages**, where a 25s total link partition did not break the connection at all because the read
  deadline is 60s. The open follow-up it exposes is quic's idle timeout: `quicconn.quicConfig` sets
  no `MaxIdleTimeout`, so drop detection there is whatever quic-go defaults to, and that dominates
  the grace window a host actually configures.
