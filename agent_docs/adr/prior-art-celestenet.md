# Prior art: how CelesteNet handles this (researched 2026-08-13)

<!-- Research behind several ADRs. Indexed in ../architecture.md. -->


Moved here from `docs/security.md` on 2026-08-19: it is research history behind several
ADRs above (room-code auth, the game-version check, the udp per-connection token), not
part of a user-facing security posture. Cited from this file's own ADRs and from
`contract.md`. Findings below were read from real files in the MIT-licensed
`0x0ade/CelesteNet` source, an approved read-only reference per `licensing.md` — facts
and citations only, never its code.
- **Self-hosted CelesteNet is open by default too.**
  `CelesteNetServerSettings.AuthOnly` defaults to `false`
  (`CelesteNet.Server/CelesteNetServerSettings.cs`) — a self-hosted server accepts any client
  with just a display name, no key required
  (`CelesteNet.Server/ConPlus/HandshakerRole.cs`'s `AuthenticatePlayerNameKey`, the
  `else if (!Server.Settings.AuthOnly)` branch). Their baseline posture is the same as ours
  today — no-auth isn't a MeshGhost-specific shortcut, it's the normal default for a
  friend-hosted relay in this genre.
- **Key-based auth exists, but it's scoped to their one large public server, not the
  baseline.** A `#<key>` prefix on the player name maps to a persistent account UID
  (`Server.UserData.GetUID`), checked against a stored ban list on connect. This solves a
  different problem than ours: an always-on server open to the whole internet needs a
  persistent identity for a ban to mean anything. A friend-hosted session with a shared
  address/room code doesn't have that problem — mirroring their full account+ban system would
  be over-engineering for MeshGhost's actual model, unless an always-on public relay ever
  becomes a real goal (it isn't one today).
- **Version check at connection time, before any data flows**: a
  `CelesteNet-TeapotVersion` header, server responds `409 Version Mismatch` on anything but an
  exact match (`HandshakerRole.cs`'s `TeapotHandshake`). We already do the direct equivalent
  for our own wire protocol (`protocol.Version`, checked in `hello` at
  `relay.go`'s `handleConn`) — and, since 2026-08-14, the same reject-at-handshake
  shape for each adapter's own `game_version` too — the room-code/version ADR above.
- **Unpredictable per-connection tokens** (`CelesteNet.Shared/TokenGenerator.cs`, a Galois
  LFSR) specifically prevent a third party from hijacking someone else's *UDP* connection by
  guessing or spamming its token. This defends against a UDP-specific weakness (UDP is
  connectionless and trivially spoofable) that didn't apply to us while `transport` was
  TCP-only. **Update 2026-08-16: it applies now.** We added a udp transport and had to solve
  exactly this — `netx/udpconn` carries an 8-byte per-connection token, checked on every
  datagram, for the same reason CelesteNet does. Ported after all, independently.
- **Deliberately not a model to copy**: `CelesteNet.Server/ConPlus/ExtendedHandshake.cs`
  collects machine GUID / registry paths / MAC-derived identifiers as a hardware-fingerprint
  anti-ban-evasion check for their public server. That's real, invasive identity collection,
  and it directly conflicts with this project's own privacy posture
  (`docs/security.md`). Explicitly out of scope here regardless of what CelesteNet does.

**Takeaway for our own design**: aim for the *shape* of their version-check pattern (a shared
secret checked once at handshake, reject outright on mismatch, before any state is exchanged)
for room codes — not their full public-server account/ban/fingerprinting stack, which solves a
problem MeshGhost doesn't have. **Implemented 2026-08-14** — the room-code/version ADR above.

