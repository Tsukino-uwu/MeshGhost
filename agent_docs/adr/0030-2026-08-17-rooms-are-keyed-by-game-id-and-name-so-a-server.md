# 2026-08-17 — Rooms are keyed by game_id AND name, so a server hosts many games out of the box

<!-- ADR 0030. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** Key `Server.rooms` by `roomKey(game_id, name)` rather than by name alone. Two games
  asking for the same room name get two separate rooms; a game's rooms are created on demand the
  first time one of its clients connects. `ReasonGameMismatch` becomes unreachable from the room
  path and is retained only for wire compatibility with older relays.
- **Status:** Done, with a replacement regression test, and demonstrated end to end on the real
  binaries: emerald, emerald, tevi, emerald — all on the shipped default `room` — produced one
  3-member emerald room and one 1-member tevi room on one server, with nothing configured.
- **Context:** The user asked why the README had to warn that two games on the default room name
  collide, and whether that should not simply be handled. It should. The relay's package comment
  has said "partitioned by game_id" since it was written; the partitioning was never implemented,
  and a mismatch was rejected instead. Since `room` ships defaulted to `"default"` for every game,
  the practical effect was that a server advertising "hosts any game, several at once" was broken
  by its own defaults for the second game onwards, and told that user only "game mismatch for this
  room".
- **Options considered:** (1) document the collision and tell hosts to assign room names per game —
  what the README briefly did, and it makes every user carry a workaround for a server-side
  defect; (2) default the client's `room` to its `game_id` — the client does not know its game
  until an adapter says so, and two users could still both pick the same name; (3) key rooms by
  game and name, which is what the documentation already promised.
- **Resolution:** Option 3. The key is length-prefixed (`"%d:%s:%s"`) rather than joined with a
  separator, because both halves arrive off the wire and JSON strings can contain any byte
  including NUL — a plain join would let a crafted `game_id` place a client in another game's room.
- **Consequences:** The user-facing warning disappears from the README, which was the point.
  `only_game` is untouched and still restricts a whole server to one game. The room-mismatch
  rejection is gone, so a client can no longer discover "you are in the wrong game for this room" —
  which was never actionable anyway, since `game_id` comes from whichever mod was loaded rather
  than from anything the player typed. Rooms are now cheap enough that a server hosting three games
  holds three room objects where it previously held one and refused two clients; that is the
  intended shape, and `DefaultMaxClients` still bounds the server as a whole rather than per room.
