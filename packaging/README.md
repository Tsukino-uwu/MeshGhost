# Packaging

What actually goes in a release, and why it's laid out the way it is. Consumed by
`.github/workflows/release.yml` — this folder holds the hand-written parts (launcher `.bat`
files, the config template, player-facing READMEs, and the committed TEVI plugin); the
workflow adds the freshly-built Go `.exe`s and the Emerald adapter files on top and zips the
whole `packaging/release/` folder as the one release asset.

## Why one zip

Earlier releases (`v0.1.0`) shipped two zips — one named after the relay, one after the
Emerald player — split along an internal architecture line (`meshghost.exe` is game-agnostic;
`meshghost-relay.exe`/now `meshghost-server.exe` is used by exactly one person per session).
Looking at the real Releases page after `v0.1.0` shipped, that split cost a downloader a
decision they had no basis to make: "relay" and "player" are this project's own vocabulary,
not "am I hosting or joining."

One zip fixes that at the source — there's no second file to pick wrong. `client`/`server`
sections in one `config.json`, `run-client.bat`/`run-server.bat` side by side, and
`games/<publisher>/<game>/` mirroring `adapters/` so a second game adds a folder inside the
same zip, not a new release asset to explain. See `packaging/release/` for the actual layout.

## No password/auth yet

`packaging/release/README.txt` says this explicitly: the server is no-auth
(`agent_docs/architecture.md`'s ADR). `"room"` in `config.json`'s `client` section is real
functionality (lets multiple groups share one server without seeing each other) but is not a
security mechanism — the server address itself is the de facto shared secret today. Real
shared-secret room codes are planned (`agent_docs/plans.md`'s "Post-Phase-4 — Room codes") but
not built; update `config.json`/`README.txt` when that ships.

## Why JSON, not a `.bat`-embedded config

Considered and rejected: config values baked directly into the launcher `.bat` (what an
earlier version of this packaging did) — a future release update overwrites the launcher and
silently wipes the user's settings. Considered and rejected: plain `key=value` text (more
typo-forgiving than JSON, no risk of a missing comma) — genuinely a reasonable alternative,
but JSON was the user's explicit preference and the downside is mitigated by shipping
`config.json` pre-filled with working placeholder values (so a user only ever edits values,
not structure) and by `cmd/meshghost`/`cmd/meshghost-relay` logging a clear parse-error
warning rather than failing silently.

## One config file, two sections

`config.json` has a `client` section (everyone edits this) and a `server` section (only the
host touches this) — see `packaging/release/config.json`. Both `cmd/meshghost` and
`cmd/meshghost-relay` read the whole file but only look at their own section, so one file
works for both roles without either binary needing to know about the other's settings.

Field names inside `client` are deliberately end-user-facing rather than matching the CLI flag
names or Go's own conventions: `connect_to` (the host's address, outbound) and
`local_game_bridge` (a loopback-only socket between the client and the game mod, on your own
PC — nothing to do with anyone else) read as clearly different things at a glance, which
`"relay"` and `"bridge"` didn't. `server.listen_on` deliberately reads as the opposite of
`client.connect_to`. See `cmd/meshghost/main.go` and `cmd/meshghost-relay/main.go`'s
`fileConfig` doc comments for the full mapping back to flag names.

## Adding a game to the release

Nothing under `adapters/` is picked up automatically — that tree holds source and history, not
shippable output (phase-numbered Lua scripts are dev artifacts; `adapters/tevi/MeshGhostTevi/`
is a C# project; pseudoregalia carries a submodule). Emerald is the easy case only because its
adapter *is* the shipped file. Each game gets its own step in
`.github/workflows/release.yml`'s assemble job when its adapter is genuinely ready to ship —
see the Emerald step there for the pattern (copy + rename the script, copy its `lib/` next to
it), and TEVI below for what a compiled adapter needs instead.

## TEVI: a committed build output, on purpose

`packaging/release/games/tevi/MeshGhostTevi.dll` is checked into the repo, which is unusual —
everything else under `packaging/release/games/` is either hand-written or assembled fresh by
CI. TEVI is different because **CI cannot build it**: `MeshGhostTevi.csproj` compiles against
`adapters/tevi/MeshGhostTevi/lib/*.dll`, copies of the developer's own proprietary TEVI
install that are gitignored and never committed (`agent_docs/licensing.md`). Our own output —
16 KB, `<Private>false</Private>` so no game DLL is embedded in it — is fine to distribute,
it just has to be built on a machine that already has TEVI installed.

`dev-scripts/build-tevi.bat` does that build and stages the result here, along with
`built-from.txt` recording the SHA-256 of the three source files (`Plugin.cs`,
`BridgeClient.cs`, `MeshGhostTevi.csproj`) it was built from. `.github/workflows/release.yml`
rehashes those same files before assembling a release and fails the build if they don't match
— a release physically cannot ship a `MeshGhostTevi.dll` older than the source that's supposed
to have produced it. Whoever edits the TEVI adapter re-runs `build-tevi.bat` and commits the
result as part of that change.

TEVI ships marked experimental (see `packaging/release/README.txt` and
`packaging/release/games/tevi/README.txt`): the mod is code-complete but has never been tested
against a second real player (Steam won't run two TEVI instances on one machine, so this
release *is* the way that finally gets tested — see `agent_docs/phases/phase6.md`'s 6.6). Cut
this kind of release with the `prerelease` checkbox ticked (below).

## Cutting a release

Manual only, deliberately — nothing publishes on its own just from pushing a commit or tag.
On GitHub: repo → **Actions** tab → **Release** workflow → **Run workflow** → type a version
(e.g. `v0.1.0`), tick **prerelease** if this cut includes untested content (e.g. TEVI before
its first real two-player test) → run. It builds both `.exe`s for Windows/amd64 (the only
platform BizHawk's LuaSocket vendoring currently supports, per `agent_docs/licensing.md`),
verifies the committed TEVI plugin isn't stale, assembles the one zip, creates the tag if it
doesn't already exist, and attaches the zip to a new GitHub Release.
