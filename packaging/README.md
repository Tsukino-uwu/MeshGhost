# Packaging

What actually goes in a release, and why it's split the way it is. Consumed by
`.github/workflows/release.yml` — this folder holds the hand-written parts (launcher `.bat`
files, player-facing READMEs); the workflow adds the freshly-built `.exe`s and the game
adapter files on top and zips each subfolder as one release asset.

## Why two zips, not one

`meshghost.exe` (the core) is game-agnostic — the same binary works for every game's adapter,
by design (`agent_docs/contract.md`). `meshghost-relay.exe` is used by exactly one person per
session (whoever hosts), never by players. Splitting along that line means:

- **`relay/`** — for the one person hosting. Just the relay binary + a launcher that listens
  on all interfaces (not just loopback, so it's actually reachable) + hosting instructions.
- **`emerald-player/`** — for every player. `meshghost.exe` bundled together with Emerald's
  adapter (the Lua script + its vendored DLLs) and a `config.json` holding the IP/room/name a
  friend actually needs to touch — not command-line flags they'd have to know to type, and not
  baked into the launcher `.bat` itself (a config file survives a future release update
  overwriting the launcher; a value hardcoded into the `.bat` wouldn't). Both `cmd/meshghost`
  and `cmd/meshghost-relay` load `config.json` natively (`-config` flag, defaults to
  `config.json` next to the exe) — CLI flags still work and override individual fields if both
  are given, so nothing about existing dev/testing `.bat` usage changed.

Bundling the core binary *into* the per-game player package (rather than a third, separate
"core" zip) is a deliberate simplification for right now: there's only one game, so a player
needs both pieces together anyway, and one download is friendlier than two. This does not
lock in badly once a second game (TEVI) exists — adding `packaging/tevi-player/` alongside
`emerald-player/` (each bundling their own copy of the same `meshghost.exe` build) costs
nothing extra to build or maintain, and avoids asking a non-technical player to correctly pair
a separately-versioned core zip with the right adapter zip. Revisit only if that duplication
actually becomes a real problem (e.g. the core binary gets large) — not worth solving before
it exists.

## No password/auth yet

Both `README.txt`s say this explicitly: the relay is no-auth (`agent_docs/architecture.md`'s
ADR). `"room"` in `emerald-player/config.json` is real functionality (lets multiple groups
share one relay without seeing each other) but is not a security mechanism — the relay
address itself is the de facto shared secret today. Real shared-secret room codes are planned
(`agent_docs/plans.md`'s "Post-Phase-4 — Room codes") but not built; update both packages'
`config.json`/`README.txt` when that ships.

## Why JSON, not a `.bat`-embedded config

Considered and rejected: config values baked directly into the launcher `.bat` (what an
earlier version of this packaging did) — a future release update overwrites the launcher and
silently wipes the user's settings. Considered and rejected: plain `key=value` text (more
typo-forgiving than JSON, no risk of a missing comma) — genuinely a reasonable alternative,
but JSON was the user's explicit preference and the downside is mitigated by shipping each
`config.json` pre-filled with working placeholder values (so a user only ever edits values,
not structure) and by `cmd/meshghost`/`cmd/meshghost-relay` logging a clear parse-error
warning rather than failing silently.

## Cutting a release

Push a tag matching `v*` (e.g. `git tag v0.1.0 && git push origin v0.1.0`) — the workflow
builds both `.exe`s for Windows/amd64 (the only platform BizHawk's LuaSocket vendoring
currently supports, per `agent_docs/licensing.md`), assembles both zips, and attaches them to
a new GitHub Release automatically. Nothing to do by hand beyond pushing the tag.
