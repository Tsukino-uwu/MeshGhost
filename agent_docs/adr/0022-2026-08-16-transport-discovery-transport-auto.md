# 2026-08-16 — Transport discovery: `transport: "auto"`

<!-- ADR 0022. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** A client set to `auto` opens a short tcp connection, asks the relay which
  transports it serves, disconnects **without joining**, then connects for real on the best of
  them. The query is a `query_only` flag on `Hello`; the answer is a new `transports` message
  carrying kind+port pairs. Shipped `config.json` sets the client to `auto`; the relay still
  defaults to `tcp`.
- **Status:** Implemented, same day as selectable transports. **The relay default is superseded
  by the quic-default ADR later in this file** — the relay now ships `tcp,quic`, so `auto`
  lands on quic out of the box. The client's `auto` and the discovery mechanism itself stand.
- **Context:** Selectable transports shipped with no way for a client to learn what a relay
  offers, so a host had to say "use quic, port 7780" out of band and a mismatch produced a bare
  timeout. The user's goal: if a relay enables all three, clients should end up on the best one
  with no configuration.
- **Options considered:** (1) **auto-probe** — impossible, and this is the crux: quic runs on a
  *different port*, and a client only ever knows one address, so there is nowhere to probe;
  (2) **advertise in `Welcome`, then reconnect** — one optional field, no new message type, but
  the client has already joined by then, and `contract.md` guarantees no session resumption, so
  every other player in the room watches it leave and rejoin; (3) **advertise in `Welcome` and
  only log it** — cheapest, fixes the confusing timeout, but automates nothing; (4) **ask before
  joining**.
- **Resolution:** Option 4, chosen by the user for the reason that decides it — no console noise
  and no visible churn, because nothing ever joins twice. Options 2 and 3 were the same protocol
  change and could have been staged, but both leave a leave/rejoin flicker or leave the work
  manual.
- **Resolution (and the thing that made option 4 acceptable):** **the query answers only after
  every check a real join passes — field lengths, protocol version, and the room code.** The
  serious objection to asking first was that it would become the relay's only pre-auth endpoint,
  a hole in exactly what the 2026-08-14 hardening pass closed. Running the checks first removes
  it entirely: a caller learns nothing it could not have learned by joining.
  `TestQueryOnlyStillRequiresTheRoomCode` pins it.
- **Resolution (port, not address):** An offer carries kind and **port only**. A relay bound to
  `0.0.0.0` has no idea which address reaches it from outside, whereas the client necessarily
  knows one — it just connected to it. Sending only the port makes discovery work through NAT and
  port forwarding without the relay ever learning its own public address.
- **Resolution (preference order):** `quic`, then `tcp`, then `udp` — and **`auto` never selects
  `udp` unless it is the only thing offered**, despite `udp` sharing quic's loss behaviour,
  because it cannot be encrypted at all. Auto-selecting it would silently downgrade a user's room
  code to plaintext on a relay that also offered quic. Naming `udp` explicitly still works;
  nothing picks it on someone's behalf.
- **Resolution (failure is never fatal):** Every failure path returns `(tcp, the configured
  address)` — relay down, relay old, wrong room code, no reply, malformed reply. Discovery can
  therefore only improve a connection, never prevent one, and the real connect attempt produces
  the real error. `protocol.Version` stays at 1: `query_only` is an additive optional field, same
  precedent as `room_code`.
- **Consequences:** A host no longer has to explain ports to anyone, which was the actual
  onboarding cost of having three transports. Costs one extra short-lived tcp connection per
  startup. **Against a pre-2026-08-16 relay**, `query_only` is an unknown field, so that relay
  joins the client for real and replies `Welcome`; the client recognises this, logs "older
  build — using tcp", and closes — which such a relay reports to its room as one spurious
  join/leave. That is the price of an additive field over a version bump, it affects old relays
  only, and it is strictly better than the timeout it replaces. *(As written, relays still
  defaulted to `tcp`, so `auto` changed nothing until a host opted in — no longer true since the
  quic-default ADR below moved the relay default to `tcp,quic`.)*
