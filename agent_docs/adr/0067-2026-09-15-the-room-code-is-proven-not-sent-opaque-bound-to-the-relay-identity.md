# 2026-09-15 — The room code is proven, not sent: OPAQUE bound to the relay's identity, and the floor moves to protocol 3

<!-- ADR 0067. Indexed in ../architecture.md, which is the decision log front door. A contract revision: hello loses room_code, gains pake_ke1; a new pake message; protocol.Version and MinProtocolVersion are 3. -->

- **Decision:** the room code never crosses the wire. A client that has a code sends the first
  message of an OPAQUE login (RFC 9807, `github.com/bytemare/opaque`, MIT) in its hello
  (`pake_ke1`); the relay answers with a `pake` message carrying KE2; the client answers with
  KE3; only then does the relay go on to the Welcome, or to the Transports answer of a
  query-only hello. The relay registers **one record per room code** at startup, playing both
  OPAQUE roles in-process (it holds the code), and re-registers when the code changes on a
  reload. The login is **bound to the relay's TLS identity**: the relay registers under its own
  certificate fingerprint and the client names the fingerprint of the certificate it verified on
  this connection, so a login through anyone presenting another certificate fails on the client
  before KE3 is sent, whatever the middle relays. `protocol.Version` and `MinProtocolVersion`
  are 3: a v2 peer sent the code itself, which a v3 relay must not accept and a v3 client never
  sends. The `hello.room_code` field is gone. Package `pake` is the thin shape over the library;
  `core/roomproof.go` is the client half; the relay parks a hello between KE2 and KE3.
- **Status:** Implemented 2026-09-15, the evening after ADR 0066 (the user's call that morning:
  TOFU first, then OPAQUE; that afternoon, when the TOFU warning's weakness was spelled out,
  *"Lets keep going then i guess"*, and on the floor: raise it to 3). The library survey that
  chose OPAQUE is a row in `licensing.md`; the plan is `tls-planning.md` step 5.
- **Why a PAKE at all.** With TLS always on (ADR 0066) the code was encrypted, and with trust on
  first use a changed relay identity was noticed -- and then only warned about, in a log a player
  with a hidden console never reads. Three things stayed open: the first connection to a relay is
  unauthenticated; a changed identity is warned about, not settled; and whoever terminates the
  client's TLS -- the relay you meant, or anyone between -- reads the code. One mechanism closes
  all three: the code is a secret both ends already share, so it can prove the relay to the
  client and the client to the relay on every connection, first included, without being sent.
- **Why OPAQUE and not the HMAC-over-exporter design in `security-design.md`.** That design
  sent `HMAC(code, exporter)`; whoever holds the exporter value -- the party terminating TLS --
  gets an offline guess at a short code. A PAKE gives an interceptor no offline guess: each
  online attempt is one guess, and the relay's per-source budget (ADR 0064) prices those. Of the
  Go PAKEs surveyed, OPAQUE is the one standardized, maintained, permissively licensed
  implementation; it is asymmetric, which fits one record per room registered by the party that
  holds the code.
- **Why bind to the certificate fingerprint rather than the TLS exporter.** OPAQUE's identities
  are inside what the envelope authenticates, so both ends must name the same server identity or
  the client's KE3 step fails. A per-connection exporter cannot be that identity (the record is
  registered once, before any connection). The fingerprint can: it is fixed for the relay's
  lifetime, the client already computes it (it is what the known-servers store remembers), and it
  is the one thing an interceptor cannot present. A man in the middle relaying KE1/KE2 between
  two TLS sessions makes the client name the interceptor's fingerprint, and the login fails there.
  A relay that sets no identity registers under `pake.UnboundIdentity` (tests, the dev-only udp
  transport): the code is still proven, the identity is not; the shipped relay always sets it.
- **What settles a changed identity now.** With a code: the proof, silently -- a reinstall by
  the real host succeeds (it knows the code), an impostor is refused (it does not). The
  known-servers warning (ADR 0066) still logs the change. Without a code: nothing can prove
  anything, so the ADR 0066 behaviour stands -- warn and connect -- and a code-less relay is
  open to anyone by definition, so an impostor gains nothing joining could not.
- **Wrong code, and the budget.** The client learns a wrong code at KE2 (the envelope does not
  open) and hangs up without sending anything further; it reports a permanent, named refusal to
  its caller with the room-code CODE so no retry loop spins. The relay never sees a KE3 then, so
  it charges the source's budget when a parked hello's connection ends; a KE3 that fails is
  charged the same way; a source over budget is refused before its KE1 is even computed on
  (`ReasonRateLimited`, retryable). A hello without `pake_ke1` against a coded relay is refused as
  a wrong code and charged. A relay whose registration fails refuses every join and says why,
  rather than falling open.
- **Cost.** One extra round trip on every leg that carries a code (the discovery query and the
  session), and Argon2id once per login on the client and once per registration on the relay --
  well under a second on a player's machine and never per hello on the relay, since the record
  is cached until the code changes. Five new small modules from one maintainer (all MIT, plus
  `gtank/ristretto255` BSD-3), all recorded in `licensing.md`.
- **What a host and a player see.** Nothing new when it works. A wrong code is the same
  `invalid room code` refusal as before, now decided on the player's side with prose naming the
  other cause ("or the server is not the one this client verified"). A client with a code
  against a relay that has none joins, and logs once that its code went unused. **REVISED by
  ADR 0070 (2026-09-16): it refuses, as a mismatched code.** A v2 peer is
  refused with the usual "update" message.
- **Supersedes** ADR 0013's room-code handling (the code compared in constant time on the relay)
  and the "room-code proof" design in `security-design.md` point 3; leaves ADR 0066's memory of
  relays in place as the second check. The contract's `hello` row, `room_code` section, transport
  notes, versioning line and limits are revised in `contract.md`.
- **Tests, each shown failing without its change.** `pake`: right code succeeds on both sides, a
  wrong code fails on the client before KE3 and on the relay at KE3, a different server identity
  fails the client, a KE3 from another session or a second Finish is refused, messages are
  bounded, `FuzzMessagesNeverPanic`. `relay`: a hello without a proof is refused and charged, an
  abandoned proof is charged, a hello during a parked proof is ignored; every existing room-code
  test now proves rather than sends. `core`: right code joins, wrong code is a permanent local
  refusal naming the room code, the discovery leg proves too, a code-less relay welcomes with the
  note. `cmd/meshghost-relay`: the shipped stack, guard included, through the proof. `internal/e2e`:
  the release binaries round-trip a ghost with a room code set on both ends. `agent_docs/verified.md`
  (2026-09-15, PAKE) has the runs, the live scratch run included.
