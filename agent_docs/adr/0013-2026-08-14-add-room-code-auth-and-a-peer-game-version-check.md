# 2026-08-14 — Add room-code auth and a peer game-version check to `hello`

<!-- ADR 0013. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-14
- **Decision:** Add room-code auth and a peer game-version check to `hello`
  (`protocol.Hello.RoomCode`/`GameVersion`), a `reject` message so a refusal carries a reason
  instead of a bare hangup, and a broader malicious-peer hardening pass across
  `transport`, `relay`, and `core`. Supersedes the 2026-08-11
  no-auth ADR above (kept, not deleted, as the historical record of why no-auth was the right
  call for Phases 3–4).
- **Status:** accepted
- **Context:** Set as the explicit next priority 2026-08-13 (see `risks.md`'s "No-auth relay
  window" entry and `plans.md`'s "Room codes / relay safety" section): the relay/core was
  no-auth and safe only for a friend you hand an address to, not for people you don't
  personally know, including someone actively trying to be malicious with the server/client.
  Two named gaps (no auth, no peer game-version check) plus a broader malicious-peer audit.
  Researched CelesteNet's own prior art first (the prior-art section at the end of this file, MIT,
  approved reference per `licensing.md`) rather than designing from scratch — its self-hosted
  default is no-auth too (mirroring our own starting posture), and its version-check pattern
  (reject outright at handshake, before any state exchange) is the shape this ADR reuses for
  both room codes and game version, without copying its heavier public-server account/ban/
  hardware-fingerprinting stack, which solves a problem (an always-on server open to the whole
  internet) MeshGhost doesn't have.
- **Options considered (auth):** (1) a shared secret in `hello`, compared constant-time,
  reject before any state flows — simple, no crypto to design, but the secret crosses the wire
  in plaintext since `transport` has no TLS; (2) an HMAC challenge-response (relay
  sends a nonce, client returns `HMAC(secret, nonce)`) — the secret itself never crosses the
  wire, but costs a new handshake round-trip and two new message types, and still doesn't stop
  a MITM relaying the whole session, which a real TLS layer would (a separate, larger piece of
  work, deliberately out of scope here); (3) a per-room code set by whichever client creates
  the room (lobby-password style) — more flexible for a relay hosting several unrelated
  groups, but the relay has no way to tell an intended host from a race-winning stranger.
- **Resolution (auth):** Option 1. `protocol.Hello.RoomCode`, checked via
  `crypto/subtle.ConstantTimeCompare` (not `==`, so a wrong guess can't be timed byte-by-byte)
  against `Server.RoomCode`. An empty configured code (the default) means auth stays off — the
  pre-existing friend-hosted posture is unchanged unless a relay operator opts in. The relay
  logs loudly at startup when running open, the same pattern `-loopback` already used.
  **Explicit limit, recorded rather than implied:** this raises the bar from "anyone with the
  address" to "anyone with the address and the code," not to "safe against a network-level
  attacker" — the code is still plaintext on the wire. TLS is a real, separate piece of future
  work if that ever becomes the actual threat model; not attempted here.
- **Options considered (version check):** (1) the adapter reports `game_version` over its
  bridge `hello`, forwarded into the relay `hello` — follows the existing 2026-08-12
  "adapter declares `game_id`" ADR's own reasoning (the adapter already knows, don't make the
  user retype it), but dev-scripts/`cmd/meshghost-fakeadapter` have no real adapter to ask;
  (2) same, plus a `-game-version`/`config.json` override — mirrors how `-game` already
  overrides an adapter-declared `game_id` for exactly that case; (3) config-only, no adapter
  changes — fastest, no adapter rebuilds (including TEVI's committed DLL), but reintroduces the
  exact redundancy (a fact the adapter already knows, retyped by the user, another place to go
  stale) the `game_id` ADR removed.
- **Resolution (version check):** Option 2. `bridge.Hello.GameVersion`, forwarded verbatim
  (opaque, same discipline as `game_id`/`area_id`/`anim`); `Core.GameVersion` overrides it when
  set. All four shipped adapters report their own **adapter/mod version**, not a game build
  number read from memory — no cited address exists for a game version in any of the four
  games, and `CLAUDE.md`'s "no addresses/APIs from memory" rule means one isn't guessed at. An
  adapter-script version is arguably the more useful signal anyway: it catches two peers on
  different revisions of the same adapter, the likelier real source of a silent mismatch. A
  room's `game_version`, once set by its first member, is sticky the same way `game_id` already
  is; a client that never declares one is never refused on that basis — only a real mismatch
  between two declared values counts.
- **Options considered (malicious-peer hardening scope):** (1) auth and version check only,
  file the discovered DoS/trust gaps in `risks.md` for a separate pass — smallest change, but
  ships a "safe for strangers" feature with a known remote-OOM still live; (2) the concrete DoS
  holes found while scoping this (unbounded read buffer, no read/write deadlines, a lock held
  across a potentially-slow `Send`, no hello timeout) but not the core-side trust gaps; (3)
  everything found, relay-side and core-side.
- **Resolution (hardening scope):** Option 3, per explicit user direction. Fixed:
  `transport.NDJSONConn`'s unbounded `bufio.Reader.ReadBytes` read (switched to
  `bufio.Scanner` with a real max-token-size, enforced during the read, not after — the
  previous `relay.MaxLineBytes` check ran too late to prevent the allocation), added
  read/write deadlines and a dial timeout (none existed before), fixed
  `relay.Room.Forward` holding `r.mu` across every recipient's `Send` (a stalled peer
  could freeze joins/leaves/roster reads for the whole room once `Send` could legitimately
  block for seconds against it), and added `Server.HelloTimeout` (an unauthenticated connection
  that never completes a `hello` was previously held open forever). On the trust side:
  `core` now keeps its own roster (seeded from `welcome`, maintained by `join`/
  `leave`) and drops `state` for any `player_id` it never actually saw announced — previously a
  hostile or compromised relay could inject state for an arbitrary id, since `welcome.roster`
  was discarded entirely and any incoming `player_id` was trusted outright. The relay's own
  `MaxPositionLen`/`MaxExtrasBytes` caps are now mirrored on the core's receive side too
  (`protocol/limits.go` holds the shared constants so the two enforcement points can't
  drift apart), plus new caps on `orientation`, `area_id`, `anim`, and every `hello` string
  field, none of which were bounded anywhere before.
- **Consequences:** `protocol.Version` stays at `1` — every new field is optional/additive, and
  Go's `json.Unmarshal` ignores fields it doesn't recognize, so an old client against a new
  relay (or vice versa) degrades gracefully rather than breaking outright. The one real residual
  risk this creates, not fully closed: **room-code auth is enforced entirely by the relay, so a
  stale (pre-this-ADR) relay binary silently provides zero protection regardless of what any
  client sends or believes it configured** — a `room_code` field in an old relay's `config.json`
  is invisible to it (unknown JSON fields are ignored the same way), with no error to tell the
  host their room is actually wide open. Worth a follow-up: `docs/security.md` and
  `packaging/README.md` should say plainly that room-code auth requires the *relay* to be
  current, not just the client. Every new size/length limit is a real, if small, behavior
  change: a legitimately-oversized field that was previously silently truncated-by-forwarding
  or merely logged is now dropped outright (state fields) or refused at handshake (`hello`
  fields) — matches the existing "drop, don't truncate" posture already established for
  `MaxPositionLen`/`MaxExtrasBytes`, just extended to the fields that were missing it.
