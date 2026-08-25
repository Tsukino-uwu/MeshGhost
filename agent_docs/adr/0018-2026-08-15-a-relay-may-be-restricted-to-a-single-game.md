# 2026-08-15 — A relay may be restricted to a single game (`server.only_game`), off by default

<!-- ADR 0018. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-15
- **Decision:** A relay may be restricted to a single game (`server.only_game`), off by
  default.
- **Status:** accepted
- **Context:** The only game gate the relay had was per-room and sticky-on-first-join
  (`joinOrCreateRoom` compares a `hello`'s `game_id` against the room's existing one). That is the
  right rule for keeping two games out of one room, but it says nothing at the server level: a
  relay hosting rooms "a" and "b" happily hosts Emerald in one and Pseudoregalia in the other.
  Someone running a dedicated single-game server -- the case that prompted this -- had no way to
  express "this box is for Pseudoregalia," and would only find out a stranger was using it for
  something else by reading the log.
- **Options considered:** (1) leave it -- per-room stickiness already prevents the *incoherent*
  case (garbage ghosts), and a host who wants exclusivity can already use a room code; (2) a
  comma-separated allow-list of game ids; (3) a single game id, blank means any.
- **Resolution:** Option 3, chosen by the user over (2) explicitly: the ask was a dedicated
  single-game server, and a list would have added parse/whitespace/duplicate rules to an
  end-user-edited config file for a case nobody has. (1) was rejected because a room code is a
  different control -- it gates *who*, not *what*, and a host handing the code to friends who
  play several games still can't say "not on this box."

  Enforced in `relay`, checked in `handleConn` after the field-length and
  protocol-version checks (so the refused `game_id` is already bounded before it is logged) and
  **before** the room table is touched or a client slot reserved -- the same "reject at
  handshake, before any state flows" shape as the room-code and version checks. Refused with a
  new `reject` reason, `ReasonGameNotAllowed`, kept distinct from the per-room
  `ReasonGameMismatch`: the two mean genuinely different things to a player, since no room they
  could pick would fix this one. `core.isPermanentRejectReason` classifies unknown
  reasons as permanent already, so the client does not retry-loop against a relay that will
  never accept it, with no core change needed.

  Compared by exact equality, like every other use of `game_id`. The configured value is
  whitespace-trimmed (it is hand-typed into `config.json`, and a stray space would otherwise
  refuse everyone) but deliberately **not** case-folded, which would diverge from the equality
  comparison the adapters and `joinOrCreateRoom` already rely on. The relay logs the value it
  actually read at startup, since a typo'd id refuses every client with no other visible cause.
- **Consequences:** Nothing changes for an existing relay -- blank is the zero value and the
  pre-existing "host anything" posture. Same stale-relay caveat as room-code auth
  (`agent_docs/risks.md`): the check lives entirely in the relay, so an old
  `meshghost-server.exe` ignores the field and keeps hosting everything. This is also the first
  end-user-facing setting whose valid values are a list that grows when a game is added --
  `packaging/README.md` records the resulting maintenance rule (the ids are listed literally in
  `packaging/release/README.txt` and the top-level `README.md`, and adding a game means adding
  it to both).
