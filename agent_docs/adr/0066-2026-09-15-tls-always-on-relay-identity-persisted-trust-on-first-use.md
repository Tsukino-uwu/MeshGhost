# 2026-09-15 — TLS is always on, the relay's identity is persisted, and clients remember it (trust on first use)

<!-- ADR 0066. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** every shipped connection between a client and a relay is TLS 1.3, on tcp and quic
  alike, with no mode and no plaintext fallback on either side. A relay refuses a connection that
  does not begin with a TLS handshake (one throttled log line says why); a client sends nothing to
  a relay it cannot handshake with. The relay's certificate is **persisted**, in a `tls/` folder
  beside its `config.json` (beside the executable when there is no config): `relay.key` (PKCS#8
  PEM, 0600 where the OS has modes), `relay.crt`, and `relay.fingerprint` for a human to read.
  The same certificate is served on tcp and quic, so one relay has one fingerprint. A client
  **remembers** each relay's fingerprint under the address it configured, in `tls/known_relays.json`
  beside its own `config.json`, on the first connection, and checks every later connection on
  every leg against that entry. A changed identity is **warned about loudly and remembered**, not
  refused. The `tls` and `tls_fingerprint` config keys and the `-tls`/`-tls-fingerprint` flags are
  gone; a config still carrying `"tls": "off"` or `"auto"`, or a non-empty `tls_fingerprint`,
  refuses to start with a message saying what replaced it; `"tls": "required"` runs with a note.
- **Status:** Implemented 2026-09-15 (user decisions 2026-09-14: *"encryption should be default
  rather than optional"*, *"I just want it to be automatic and nothing manual required"*; and
  2026-09-15: TOFU first, the PAKE afterwards, one at a time). `netx/tlsx` (`identity.go`,
  `Verifier`), `netx/quicconn.DialWith` and `Options.TLS`, `netx.TLSOptions{Server, Verify}`,
  `core/knownrelays.go`, both mains. The plan and the reasoning behind each choice:
  `agent_docs/tls-planning.md`.
- **Why.** Until this date a client under the shipped `auto` never fell back to plaintext (ADR-less
  fix `bf47f160`, fourth review A1), but the mode still existed, so a relay could be run plaintext
  and a client told to accept it; the certificate lived in memory and was regenerated every
  restart, so the one form of authentication — a pin a human copied — had to be re-copied after
  every restart, which nobody did; and quic generated a second, unverified certificate of its own,
  so the pin covered the tcp leg only ("tcp stronger than quic", `docs/security.md`). Every
  release since 2026-08-19 speaks TLS, so a plaintext option protected nobody and a mode was one
  more setting to get wrong. A persisted identity is what makes remembering it worth anything;
  remembering it is what makes an impostor visible from the second connection on, with nothing
  for a host or a player to copy, edit or delete.
- **Why a warning and not a refusal on a change.** SSH refuses, and then a human deletes a line
  from a file. The user's requirement is that nobody ever does that, so the entry updates and the
  session goes ahead, encrypted, under a warning that names both fingerprints and says who to ask.
  What will settle a change instead is the room code, as a PAKE bound to the connection (plan
  step 5, `bytemare/opaque`, RFC 9807 — surveyed in `licensing.md`, chosen by the user, not yet
  built): with a code set, a changed identity is then *proven* or *refused* rather than warned
  about. That is a contract revision of its own (the room code leaves the wire) and gets its own
  ADR when it lands. Until then a relay reinstall costs every returning player one loud line.
- **Why files beside the config, and why the key is not enough.** The user's call: files stay in
  the install, so uninstall is still "delete the folder" and moving an install moves the identity
  with it; a per-user app-data folder was rejected for that reason. The certificate is persisted
  as well as the key because a certificate re-signed from the same key has a new serial and so a
  new fingerprint — a key-only file would give the relay a new identity every restart while
  looking persisted. Half an identity (one file of the two), or a file that does not parse, is
  **fatal** at startup, never a silent regeneration: that would hide a broken install behind a
  "new identity" warning on every client. Deleting both files is the documented way to a new one.
- **What a host sees.** One line with the fingerprint and one naming the folder ("copy `tls/` into
  a new install to keep this identity; keep `relay.key` private"). `tls/` is gitignored and
  `stage-release.ps1` refuses a release folder that contains one: `relay.key` in a zip would make
  every install of that zip the same relay to every client that had connected to any of them.
- **What a player sees.** Nothing, unless a relay's identity changes: "trusting server X,
  fingerprint Y (first connection)" once per relay, then silence. A corrupt `known_relays.json` is
  a connection error naming the file, never overwritten. A read-only install still plays and is
  told once that nothing is remembered. A hand-edited entry with colons or capitals still matches.
  The keys `tls`/`tls_fingerprint` in an old `config.json` are judged at startup as above; the
  release `config.json` no longer carries them.
- **Costs accepted.** A first connection is unauthenticated (there is nothing to compare yet); a
  relay from before this date presents two certificates (tcp and quic), so a client of one sees a
  changed-identity warning on every connect until the relay updates; a re-shared install folder
  leaks `relay.key` (documented in `docs/hosting.md`); netcat can no longer drive a relay, and
  `docs/reviewing.md` says so. The dev build (`meshghost_devudp`) honours `SSLKEYLOGFILE` so a
  Wireshark capture is still readable on the developer's own machine; a release never does.
- **Supersedes** the TLS section of ADR 0034 (2026-08-18: three-way mode, in-memory certificate
  "never written to disk", opt-in pin) in full; the "encrypt by default" half of that decision is
  kept and made unconditional. Leaves ADR 0065 (no shipped udp) as its prerequisite.
- **Tests, each shown failing without its change.** `netx/tlsx`: a plaintext client is refused, a
  nil verifier is an error, the verifier sees the leaf only, an identity is created then reused,
  half or corrupt is fatal, the key is 0600 (POSIX), no temp file is left. `netx`: the room code
  is absent from the wire (control from a raw socket), a client refuses a plaintext relay and a
  relay refuses a plaintext client, one fingerprint on tcp and quic, the verifier decides on both,
  the bare quic dial refuses. `core`: first connect records, second matches, a change warns and
  updates, the room code is not part of the entry, concurrent records do not corrupt the file, a
  corrupt file refuses, hand-edited entries match, an unwritable store still connects, both legs
  verify against one entry, `FuzzKnownRelaysFileNeverPanics`. `cmd`: the legacy keys are judged
  by what they asked for; the shipped stack refuses a plaintext hello with no Reject; the shipped
  config carries neither key. `internal/e2e`: the release binaries round-trip a ghost with no flag
  about encryption, the relay persists `tls/` and the client writes `known_relays.json`; the client
  refuses a raw plaintext listener. `agent_docs/verified.md` (2026-09-15, TOFU) has the runs.
