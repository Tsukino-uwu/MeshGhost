# Packaging

What actually goes in a release, and why it's laid out the way it is. Consumed by
`.github/workflows/release.yml` — this folder holds the hand-written parts (the config
template, player-facing READMEs, and the committed TEVI/Pseudoregalia plugins); the workflow
adds the freshly-built Go `.exe`s and the Emerald adapter files on top and zips the whole
`packaging/release/` folder as the one release asset.

## Why one zip

Earlier releases (`v0.1.0`) shipped two zips — one named after the relay, one after the
Emerald player — split along an internal architecture line (`meshghost.exe` is game-agnostic;
`meshghost-relay.exe`/now `meshghost-server.exe` is used by exactly one person per session).
Looking at the real Releases page after `v0.1.0` shipped, that split cost a downloader a
decision they had no basis to make: "relay" and "player" are this project's own vocabulary,
not "am I hosting or joining."

One zip fixes that at the source — there's no second file to pick wrong. `client`/`server`
sections in one `config.json`, `meshghost.exe`/`meshghost-server.exe` side by side, and
`games/<publisher>/<game>/` mirroring `adapters/` so a second game adds a folder inside the
same zip, not a new release asset to explain. See `packaging/release/` for the actual layout.

## No launcher `.bat` files

An earlier version of this packaging shipped `run-client.bat`/`run-server.bat` alongside the
`.exe`s. Their only real function was the trailing `pause`: double-clicking an `.exe` directly
opens a console window same as the `.bat` did, but that window vanishes the instant the process
exits, taking a crash message with it before a non-technical user could read it — `pause` kept
the window open long enough to read it. Removed once `cmd/meshghost`/`cmd/meshghost-relay`
started writing their own `meshghost.log`/`meshghost-server.log` next to the `.exe` (tee'd
alongside stderr, truncated each run) — that file survives the window closing, so the `.bat`
files stopped doing anything a user couldn't already get by double-clicking the `.exe` itself.

## Room-code auth (added 2026-08-14)

`server.room_code` (host-set) and `client.room_code` (must match) in `config.json` — see
`agent_docs/architecture.md`'s room-code/version ADR and `internal/README.md`. **Optional and
off by default**: an empty `server.room_code` means the relay still accepts anyone with the
address, the original no-auth posture. `packaging/release/README.txt` should tell a host to
set one before treating a session as safe for people they don't personally know — see that
file's own note.

**The one thing this can't protect against, and every host needs to know**: room-code auth is
enforced entirely by the relay, so it only works if `meshghost-server.exe` is a current build.
An old relay silently ignores an unrecognized `room_code` field and stays open with no warning
— see `risks.md`'s "stale relay" entry. There is no way to fix this from the client side; the
only mitigation is telling hosts plainly to update the relay, not just the client, before
relying on a room code.

`"room"` remains real functionality (lets multiple groups share one server without seeing each
other) but is still not itself a secret — it's a label, checked for equality but not
constant-time-compared or meant to be hard to guess. `room_code` is the actual secret.

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

**Known stale as of the 2026-08-14 relay-safety work**: `Plugin.cs`/`BridgeClient.cs` changed
(added `game_version` to the bridge `hello`, per the room-code/version ADR) without
`dev-scripts/build-tevi.bat` being re-run — this session has no TEVI/Unity install to build
against (`agent_docs/licensing.md`'s gitignored-proprietary-lib constraint, same reason CI
can't build it either). The staleness check will correctly fail the release workflow until
someone with a real TEVI install re-runs `build-tevi.bat` and commits the result.

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
