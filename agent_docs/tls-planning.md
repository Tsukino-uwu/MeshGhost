# Plan (scheduled, 2026-09-15): TLS always on, relay identity persisted, nothing manual for anyone

**Status 2026-09-15 (later the same day): steps 1–4 and 6–9 LANDED as ADR 0066** — TLS always on,
the identity persisted, the client's known-relays store, the binaries and the shipped config, the
dev-only key log, the docs. **Step 5 (the room-code PAKE) is OPEN**: the user's call was TOFU first,
then OPAQUE (`bytemare/opaque`, RFC 9807 — the survey is a row in `licensing.md`) as a separate
piece so each is tested on its own. Until it lands, a changed relay identity is warned about and
remembered, not proven or refused (the accepted trade-off below). Two deviations from the text
below, both recorded in the ADR: the certificate is persisted as well as the key (a re-signed
certificate has a new serial and so a new fingerprint), and a corrupt `known_relays.json` refuses
the connection rather than being overwritten.

Written 2026-09-14 and parked; **scheduled 2026-09-15 as the next piece of work after the fourth
adversarial review's fixes** (user decision, that day). Its prerequisite has landed: plain udp is
dormant behind the `meshghost_devudp` build tag (ADR 0065, 2026-09-15), so forced TLS has no
exceptions anywhere in shipped code. Two of the review's targeted fixes are the first half of this
plan and are already in: a client under `auto` never falls back to plaintext (commit `bf47f160`),
and a pin must be a whole fingerprint (`196415b4`). Step 1 below still removes `Off` and the pin.

## Context

User decisions (2026-09-14): *"encryption should be default rather than optional"*, and *"I just
want it to be automatic and nothing manual required"*. TLS is forced on every shipped transport —
no `off`, no `auto`, no plaintext fallback. A relay refuses clients without TLS; a client refuses
relays without TLS. Neither a host nor a player ever copies a fingerprint, edits a trust file or
deletes one — not on first connect, not when a server reinstalls, not when switching servers.

Today (from the tree, 2026-09-14):
- `tls` is `off|auto|required`, default `auto` (`netx/tlsx/tlsx.go` `Mode`). Under `auto` the
  relay serves plaintext and TLS on one port (the one-byte sniff in `classify`), and the client
  falls back to plaintext tcp with a warning (`netx/netx.go` `DialWithTLS`).
- The certificate is generated in memory and regenerated every relay restart (`tlsx.ServerConfig`),
  so the optional `tls_fingerprint` pin must be re-copied by hand after every restart.
- quic generates its **own second** certificate and discards its fingerprint
  (`netx/quicconn/quicconn.go` `newSelfSignedTLSConfig`, `clientTLSConfig` with
  `InsecureSkipVerify` and no verifier) — the pin covers tcp only (`docs/security.md`).
- The room code is sent as-is (inside TLS when TLS is up), so whoever terminates that TLS reads it.

## Why (from the discussion)

- **ADR 0034 rejected a key file** because "nothing verifies it by default, so a key file next to
  the exe would buy zero security". This plan removes that premise: every client now checks the
  relay's identity, and a persisted key is what makes that possible.
- **Browser-style CA trust is out**: it needs a domain name and an issuer; players host on bare IPs.
- **Only the relay has an identity.** Clients hold no certificate (mTLS stays rejected,
  `agent_docs/security-design.md`), so nothing is exchanged the other way.
- **Trust on first use (TOFU, the SSH model)**: a client remembers each relay's fingerprint on
  first connect and checks it afterwards. SSH refuses on a change, which needs a manual step; here
  the room code settles a change instead, so nothing is manual.
- **The room code already is a shared secret** between host and players, so it can prove the relay
  is genuine without being sent: a PAKE (password-authenticated key exchange) bound to the TLS
  connection. A man-in-the-middle runs two TLS sessions, so the proof fails, and a PAKE gives it no
  offline guess at a short code. With a code this authenticates the relay on EVERY connection,
  first included.
- **Files stay in the install** (user): a `tls/` folder next to the config, so uninstall is still
  "delete the folder" and the files are easy to find, delete or swap. A per-user app-data folder was
  considered and rejected for that reason.
- **Each install has its own files**, so several client installs, several adapters, or several
  copies of one game never collide: adapters speak only the bridge and never see TLS, and every
  client of one relay sees that relay's one fingerprint.
- **One certificate for tcp and quic** closes the "tcp is stronger than quic" gap.
- **Accepted trade-offs**: a relay with no room code has nothing to prove with, so a changed identity
  there is warned about, not blocked; a re-shared used folder leaks `tls/relay.key` (documented).

## What each change does to a returning player

| Host changes | What a returning player sees |
|---|---|
| Room name | Nothing — the fingerprint still matches |
| Room code (new code, turned on, or turned off) | Nothing on the TLS side — the fingerprint still matches. Joining works as today: the right code (or none, if the room has none) gets in; an old or wrong code is refused |
| Key (reinstall, fresh folder, deleted `tls/`) | With a room code: proven by the code, entry updated, connects. Without one: connects, still encrypted, with a loud "identity changed, not proven" warning |
| Key **and** room code together | The player needs the new code anyway, as today; with it the proof succeeds and the entry updates |
| A different relay at the same address | Same as a changed key |

The room code does two jobs that never conflict: on every connection it is the join check, and when
a key has changed it is also what proves the server is who it says. Hosts can switch codes on, off or
to something new freely without touching anyone's trust file.

## Approach

1. **`netx/tlsx`**: delete `Mode` (`Off`/`Auto`/`Required`), `ParseMode`, the `Auto` passthrough
   and the pin (`TLSOptions.Fingerprint` and its uses). `NewListener` always requires TLS; the sniff
   stays only to log a throttled "plaintext client refused". New
   `LoadOrCreateIdentity(dir) (*tls.Config, fingerprint, error)` reusing `ServerConfig`'s generation:
   missing → generate and write `tls/relay.key` (0600) and `tls/relay.fingerprint` (full SHA-256)
   atomically (temp + rename); present but unreadable/corrupt → **fatal** (a silent regeneration
   would hide a broken file); long validity. `clientConfig` takes a `Verify func(leafDER []byte)
   error`, keeping the leaf-only check.
2. **`netx/quicconn`**: `Listen` takes the shared `*tls.Config` (quic ALPN on a clone); `Dial`
   takes the same verifier; a nil verifier is an error, never an unchecked handshake.
3. **`netx/netx.go`**: `TLSOptions` loses `Mode`; `ListenWithTLS` always wraps tcp and hands the
   config to quic; `DialWithTLS` loses its plaintext branch. Tagged dev udp stays plaintext.
4. **Client trust store**, new `core/knownrelays.go`: `tls/known_relays.json` next to the client
   config, relay address (as configured) → fingerprint. Mutex + atomic write (discovery and session
   legs can race). Covers every leg: tcp discovery, tcp session, quic session.
   - first connect → record, log "trusting server X, fingerprint Y (first connection)";
   - match → connect;
   - mismatch + room code → the PAKE (step 5) decides: success updates the entry and logs "server
     identity changed; proven by the room code"; failure refuses (whoever answered lacks the code);
   - mismatch, no room code → connect (still encrypted), update the entry, loud warning.
   Remove the now-meaningless escalations in `core/transportpick.go` and the plaintext warning in
   `core/relaysession.go`.
5. **Room-code PAKE with channel binding**: the room code is never sent, not even inside TLS. Client
   and relay run a PAKE keyed by the room code and bound to the connection's exporter value (RFC 9266
   `tls-exporter`; quic-go's `ExportKeyingMaterial`, ADR 0021), mutually — the relay learns the
   client knows the code (replacing today's check), the client learns the relay does.
   - **Before any code: find a Go PAKE implementation (e.g. CPace or SPAKE2), read its license
     first (`agent_docs/licensing.md`), cite its docs — nothing from memory.** If none is clear,
     bring that back to the user rather than improvising one.
   - **Surveyed 2026-09-15 (the row in `licensing.md` has the citations): none is clean, and the
     choice was put to the user.** CPace is still an Internet-Draft (draft-21) and its one live Go
     implementation calls itself a proof of concept; Filippo's is a 2021 experiment; croc's is a
     textbook variant, not the RFC; CIRCL has no PAKE. The one standardized, maintained, permissive
     candidate is `bytemare/opaque` (RFC 9807, MIT, maintained by an RFC author) — an *asymmetric*
     PAKE, which fits by registering ONE record per room from the code at relay startup and having
     every client log in against it; its cost is a dependency tree of small single-maintainer
     modules. The alternative that needs no PAKE: steps 1–4 and 6–9 alone (TOFU), where a changed
     relay key with a room code set is warned about loudly rather than proven — which gives up
     "nothing manual" only in the reinstall case, and only for a player who reads the warning.
   - It changes the wire: a contract revision (new ADR superseding ADR 0013's room-code handling).
     Whether the wire floor moves is the user's call — floors are never raised automatically.
6. **cmd**: relay drops `-tls`, loads the identity from `tls/` beside the config file
   (`filepath.Dir` of the absolute `-config`), and logs the fingerprint and folder instead of
   "regenerated on restart". Client drops `-tls` and `-tls-fingerprint`; `tls/known_relays.json`
   beside its config. **Legacy keys**: `"tls"` `off`/`auto` and aliases → startup error "TLS is
   always on; delete \"tls\" from config.json"; `required` and aliases → runs with a one-line note to
   delete it. `"tls_fingerprint"` empty → runs with a note; non-empty → startup error saying pins are
   gone and servers are now remembered automatically (a security setting is never silently ignored).
   Drop both from `cmd/meshghost/reload.go`'s relaunch list.
7. **Shipped config**: remove `"tls"` and `"tls_fingerprint"` from `packaging/release/config.json`;
   update `cmd/meshghost/shippedconfig_test.go`. `.gitignore` `tls/`; a packaging check that no
   `tls/` folder is ever in `packaging/release/`.
8. **Dev-only Wireshark**: `SSLKEYLOGFILE` → `KeyLogWriter` on tcp and quic, behind the dev build
   tag only (the udp plan's `meshghost_devudp`, or a broader `meshghost_dev`). Never in releases.
9. **Docs**: new ADR in `agent_docs/adr/` superseding 0034's TLS section and its "never written to
   disk" decision, indexed in `agent_docs/architecture.md`; `agent_docs/security-design.md`
   (confidentiality always on; relay authentication by TOFU plus the room-code PAKE; the accepted
   trade-offs); `docs/security.md` (also its inaccurate claim that `tls`/`tls_fingerprint` apply
   without a relaunch), `docs/config.md`, `docs/hosting.md` (keep `tls/relay.key` private; copy
   `tls/` into a new install to keep the identity), `docs/networking.md`,
   `packaging/release/docs/config.txt` and `hosting.txt` in plain words ("server").

## Tests

- **Rewrite or remove** what assumed optional TLS or a pin: `TestAutoReachesBothKindsOfRelay`,
  `TestPlaintextClientStillReachesATLSRelayInAuto`, `TestListenWithTLSOffIsUntouched`, the tlsx
  `Off*`/`Auto*`/`ParseMode*`/`PinnedFingerprint*`/`APinIsForgiving*` tests, `pin_internal_test.go`,
  `TestAPlaintextDiscoveryLegKeepsAutoAsAuto`, `TestAPinEscalatesAutoToRequired`,
  `TestThePinReachesBothLegs`, the cmd `TestTLS*` config tests, and e2e
  `TestATLSRequiredClientRefusesAPlaintextRelay` (uses `-tls off`; point it at a raw plaintext
  listener instead).
- **New, each failing without the change**:
  - relay refuses a plaintext client; client refuses a plaintext relay on every shipped transport;
  - same folder → same fingerprint across restarts, equal on tcp and quic; missing key regenerates;
    corrupt key is fatal; key written 0600 where the OS supports it;
  - first connect records; second succeeds; concurrent records don't corrupt the file;
  - changed identity + right code → entry updated, connects; + wrong code → refused; no code →
    connects with the warning and updates — each on the discovery leg, tcp session and quic session;
  - room code changed, turned on or turned off with the key unchanged → no trust-store change;
  - PAKE: a man-in-the-middle relay (two TLS sessions) fails the proof on both sides; the room code
    never appears on the wire (extend `TestTheRoomCodeIsNotReadableOnTheWireWithTLS`, its plaintext
    control from a raw socket);
  - legacy config: `"tls":"off"`/`"auto"` error, `"required"` runs; `"tls_fingerprint":""` runs,
    non-empty errors.
- **Fuzz**: `FuzzKnownRelaysFileNeverPanics` — a corrupt or hostile file is a clean error; a fuzz
  target on the PAKE message parser.

## Verification

- `run-gotests.bat` and `run-gotests-race.bat` green (the trust store and listener are concurrent);
  `-count=10` on the new tlsx/core/e2e tests.
- Rebuild root `meshghost*.exe` with `-o`, then hidden in a scratch dir: relay's first start creates
  `tls/` with the key and fingerprint and logs it; restart shows the same one; a client on `auto`
  connects over quic and writes `tls/known_relays.json`; change the room code and back → no trust
  change; delete `tls/relay.key` and restart → with a code the client reconnects on its own ("proven
  by the room code"), with a wrong code it is refused, with no code it reconnects with the warning;
  a plaintext connection to the relay is refused; a config with `"tls":"off"` fails at startup.
- `run-netsim.bat` (no-arg worst case) still round-trips, the PAKE's extra round trip included.
- Close every process started; after commit, `gh run list -L 5` once pushed.
