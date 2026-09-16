# 2026-09-16 — A room code on one side only is a mismatch: a client with a code refuses a relay that asks for none

<!-- ADR 0070. Indexed in ../architecture.md, which is the decision log front door. A contract revision: it changes what a client does with a `welcome`. Revises one line of ADR 0067. -->

- **Decision:** a client with a `room_code` that receives a `welcome` (or a `transports` answer)
  without the relay having asked for the room-code proof refuses the session, permanently, with
  `invalid_room_code` and prose naming both causes: the server has no code, or it is not the
  server this client meant. The relay is unchanged: one with no code still ignores an offered
  proof and welcomes, and the client is what refuses. The other direction was already refused
  (a relay with a code refuses a hello without a proof).
- **Why:** the user, 2026-09-16: *"either you have a code or you don't. if the client have a code
  and the server don't the client its a mismatched password basically so it should be refused.
  both should either have no code or both have the same code -- similar to how you have to change
  the ip/adress if you want to connect to another server."* ADR 0067 had a code-less relay welcome
  a coded client "with a note", and the fifth adversarial review (P1b-client-1) showed what that
  cost: an impostor never had to know the code, only to never ask for it, and the player was
  joined to it with one log line. With this, a client with a code joins only a server that
  proved the code, on every connection, first included.
- **What a player sees:** a host who removes the room code from a server that had one must tell
  players to clear theirs, the same way a changed address has to be passed on. Until they do,
  their client refuses with the reason above, and does not retry it (a permanent refusal).
- **Revises** ADR 0067's "What a host and a player see" (the "joins, and logs once that its code
  went unused" sentence) and its test list ("a code-less relay welcomes with the note"). The
  contract's `room_code` section is revised in `contract.md`.
- **Tests:** `core.TestAClientWithACodeRefusesARelayWithNone` (replaces
  `TestARelayWithNoCodeWelcomesAClientThatHasOne`), shown failing against the previous
  `core/roomproof.go`. The discovery leg closes on the same refusal and the session leg reports
  it.
