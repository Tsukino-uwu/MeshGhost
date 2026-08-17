# Packaging

What actually goes in a release, and why it's laid out the way it is. Consumed by
`.github/workflows/release.yml` — this folder holds the hand-written parts (the config
template, player-facing READMEs, and the committed TEVI/Pseudoregalia plugins); the workflow
adds the freshly-built Go `.exe`s and the Emerald adapter files on top, stages a copy of the
client beside each game's mod along with `client-config-template.json` renamed to `config.json`,
and zips the whole `packaging/release/` folder as the Windows release asset. Two more assets go
out beside it — the Linux and macOS client+server tarballs; see "Three assets" below.

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
same zip, not a new release asset to explain. (In practice only Emerald has a `<publisher>`
subfolder — `games/pokemon/emerald/` — since "emerald" alone isn't a unique-enough folder name
the way "tevi" and "pseudoregalia" already are; TEVI and Pseudoregalia sit directly under
`games/`.) See `packaging/release/` for the actual layout.

## …and then two more, for Linux and macOS (added 2026-08-16)

A release now publishes three assets: `MeshGhost-full-<version>.zip` (the one above — Windows
client, server, and every game's mod) plus `MeshGhost-linux-<version>.tar.gz` and
`MeshGhost-macos-<version>.tar.gz`, holding native builds of **only the client and server**.
Hand-written parts live in `packaging/unix/`.

**The names are load-bearing, not decorative.** GitHub sorts a release's assets alphabetically by
filename — upload order is ignored and there is no manual ordering — so `full` < `linux` < `macos`
is what puts the download almost everyone wants at the top of the list. It is also why the version
sits at the END: `-` sorts before `.`, so any `MeshGhost-<version>-something` would have sorted
above `MeshGhost-<version>.zip` no matter what the extras were called. (The two `Source code`
archives GitHub attaches on its own cannot be reordered or removed at all; that is a long-standing
open feature request, not something this workflow adds.)

This does not contradict "why one zip". That section is about not making a downloader choose
between two files that are both for them; here the main zip stays the unambiguous default (hence
no `-windows` in its name — it *is* the download), and the tarballs are labelled extras that most
people should ignore. They were bundled into the single zip first and split back out the same day:
39 MB compressed of binaries that a Windows player would never open, for a case that mostly does
not arise, since every supported game is a Windows game and the Windows client runs in the same
Proton prefix the game already needs.

Two decisions worth keeping:

- **Built on `ubuntu-latest`, not cross-built on the Windows runner.** Only so `chmod +x` means
  something and `tar` can record it, so the packages unpack ready to run. The Windows runner has
  no executable bit to set, and `.zip` cannot store one — that combination is what forced a
  "now run `chmod +x`" instruction into the README when these shipped in the main zip, and
  deleting that instruction is most of the point. It also means the dev machine cannot verify this
  part: a local dry run got the packaging right and the mode bits wrong, on NTFS, unavoidably.
- **No adapters in them.** Every shipped adapter targets a Windows game, so a native Unix build
  has nothing to hook. Emerald's Lua script is the one that could plausibly run elsewhere (BizHawk
  is cross-platform), and it stays in the main zip rather than being duplicated.

## No launcher `.bat` files

An earlier version of this packaging shipped `run-client.bat`/`run-server.bat` alongside the
`.exe`s. Their only real function was the trailing `pause`: double-clicking an `.exe` directly
opens a console window same as the `.bat` did, but that window vanishes the instant the process
exits, taking a crash message with it before a non-technical user could read it — `pause` kept
the window open long enough to read it. Removed once `cmd/meshghost`/`cmd/meshghost-relay`
started writing their own `meshghost.log`/`meshghost-server.log` next to the `.exe` (tee'd
alongside stderr, appended to across runs) — that file survives the window closing, so the `.bat`
files stopped doing anything a user couldn't already get by double-clicking the `.exe` itself.

## Room-code auth (added 2026-08-14)

`server.room_code` (host-set) and `client.room_code` (must match) in `config.json` — see
[agent_docs/architecture.md](../agent_docs/architecture.md)'s room-code/version ADR and
[internal/README.md](../internal/README.md). **Optional and off by default**: an empty
`server.room_code` means the relay still accepts anyone with the address, the original
no-auth posture. `packaging/release/README.txt` should tell a host to set one before treating
a session as safe for people they don't personally know — see that file's own note.

**The one thing this can't protect against, and every host needs to know**: room-code auth is
enforced entirely by the relay, so it only works if `meshghost-server.exe` is a current build.
An old relay silently ignores an unrecognized `room_code` field and stays open with no warning
— see [agent_docs/risks.md](../agent_docs/risks.md)'s "stale relay" entry. There is no way to
fix this from the client side; the
only mitigation is telling hosts plainly to update the relay, not just the client, before
relying on a room code.

`"room"` remains real functionality (lets multiple groups share one server without seeing each
other) but is still not itself a secret — it's a label, checked for equality but not
constant-time-compared or meant to be hard to guess. `room_code` is the actual secret.

## Single-game servers (`server.only_game`, added 2026-08-15)

`server.only_game` (host-set, no client-side counterpart) restricts a relay to one game id:
anything else is refused at the handshake. **Optional and off by default** — an empty value
keeps the original posture, where one relay happily hosts different games in different rooms.
See [agent_docs/architecture.md](../agent_docs/architecture.md)'s ADR.

The valid values are the ids the shipped adapters announce — `emerald`, `tevi`,
`pseudoregalia` — compared for exact equality, so `README.txt` lists them literally rather than
describing them, and the relay logs the value it actually read on startup (a typo'd id refuses
every client with no other visible cause). This is the only end-user-facing setting whose valid
values are a list that grows when a game is added; **adding a game means adding it to that list
in both `packaging/release/README.txt` and the repo's top-level `README.md`.**

Same stale-relay caveat as room-code auth above, and for the same reason: the check lives
entirely in the relay, so an old `meshghost-server.exe` ignores the field and keeps hosting
everything.

## Why JSON, not a `.bat`-embedded config

Considered and rejected: config values baked directly into the launcher `.bat` (what an
earlier version of this packaging did) — a future release update overwrites the launcher and
silently wipes the user's settings. Considered and rejected: plain `key=value` text (more
typo-forgiving than JSON, no risk of a missing comma) — genuinely a reasonable alternative,
but JSON was the user's explicit preference and the downside is mitigated by shipping
`config.json` pre-filled with working placeholder values (so a user only ever edits values,
not structure) and by `cmd/meshghost`/`cmd/meshghost-relay` logging a clear parse-error
warning rather than failing silently.

**That mitigation was weaker than it looked, found live 2026-08-15 while testing
`only_game`.** A JSON file saved with a UTF-8 BOM — three invisible bytes some Windows editors
put before the opening brace, including PowerShell 5.1's own `Out-File -Encoding utf8` — is
refused outright by `encoding/json`. The file looked perfectly correct to whoever edited it,
and the failure discarded the *entire* file, silently falling back to built-in defaults for
every setting in it. The dangerous case isn't a wrong port (obvious immediately) but
`room_code`: a host could set one, see it in their editor, and be running wide open. Both
binaries now strip a UTF-8 BOM before parsing (`stripBOM`, mirrored in each `main.go` the same
way `applyFileConfig` already is, with a regression test in each package), name UTF-16 —
Notepad's "Unicode" save option, unsalvageable by stripping a prefix — as its own actionable
warning instead of a cryptic JSON error, and state the consequence out loud in every
config-failure message: *every setting in it is being IGNORED*. The general lesson for a
hand-edited config file: a warning is only a mitigation if it says what it *cost* you.

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
shippable output (other Lua scripts under `adapters/pokemon/emerald/` are frozen/dev artifacts;
`adapters/tevi/MeshGhostTevi/` is a C# project; pseudoregalia carries a submodule). Emerald is
the easy case only because `meshghost_emerald.lua` *is* the shipped file. Each game gets its own
step in `.github/workflows/release.yml`'s assemble job when its adapter is genuinely ready to
ship — see the Emerald step there for the pattern (copy the script, copy its `lib/` next to it),
and TEVI below for what a compiled adapter needs instead.

Every game also gets a hand-written, committed `games/<publisher>/<game>/README.txt` — the
end-user-facing setup steps for that specific game (what's in the folder, where to drag/copy it,
any game-specific gotcha). Keep it scoped to what a player needs to do, not why the project built
it that way (that belongs here, in this dev-facing doc, not the shipped README). This file isn't
generated by anything, so a new game's release step must add it explicitly — Emerald's own
`README.txt` was missed for a while after TEVI introduced the convention (nobody backfilled it
until 2026-08-14), which is exactly the kind of gap to check for next time.

## TEVI: a committed build output, on purpose

`packaging/release/games/tevi/MeshGhost/MeshGhostTevi.dll` is checked into the repo, which is
unusual — everything else under `packaging/release/games/` is either hand-written or assembled
fresh by CI. TEVI is different because **CI cannot build it**: `MeshGhostTevi.csproj` compiles
against `adapters/tevi/MeshGhostTevi/lib/*.dll`, copies of the developer's own proprietary TEVI
install that are gitignored and never committed
([agent_docs/licensing.md](../agent_docs/licensing.md)). Our own output —
~23 KB, `<Private>false</Private>` so no game DLL is embedded in it — is fine to distribute,
it just has to be built on a machine that already has TEVI installed.

The DLL is staged under a `MeshGhost/` subfolder rather than flat in `games/tevi/` so the whole
`MeshGhost/` folder is a single drag-and-drop into the user's `BepInEx/plugins/` — no manual
"create a folder for the mod" step, same convenience goal as Pseudoregalia's drag-and-drop tree
below, just one file instead of a whole runtime.

`dev-scripts/build-tevi.bat` does that build and stages the result here, along with
`built-from.txt` (kept one level up, outside the `MeshGhost/` drag-and-drop tree, so it never
lands in a user's `BepInEx/plugins/` folder) recording the SHA-256 of the three source files
(`Plugin.cs`, `BridgeClient.cs`, `MeshGhostTevi.csproj`) it was built from.
`.github/workflows/release.yml` rehashes those same files before assembling a release and fails
the build if they don't match — a release physically cannot ship a `MeshGhostTevi.dll` older
than the source that's supposed to have produced it. Whoever edits the TEVI adapter re-runs
`build-tevi.bat` and commits the result as part of that change.

TEVI ships marked experimental (see `packaging/release/README.txt` and
`packaging/release/games/tevi/README.txt`): the mod is code-complete and **has since been
confirmed working with two real players** (a standalone second TEVI build unblocked local
dual-instance testing, since Steam won't run two TEVI instances on one machine otherwise — see
[agent_docs/phases/phase6.md](../agent_docs/phases/phase6.md)'s 6.6). Still marked experimental
because it hasn't been confirmed over a real network between two separate machines yet, only
two local instances on one machine. Cut this kind of release with the `prerelease` checkbox
ticked (below).

## Pseudoregalia: another committed build output, and a committed runtime

`packaging/release/games/pseudoregalia/` is checked into the repo too, for the same reason as
TEVI: **CI cannot build it**. `MeshGhostPseudo`'s CMake build tree depends on the private
UEPseudo dependency (not publicly cloneable, see
[agent_docs/phases/phase7.md](../agent_docs/phases/phase7.md)'s 7.2 entry) and a locally
configured RE-UE4SS submodule build, so `main.dll` has to be built on a machine
that already has that tree set up.

Two dev scripts stage this folder, and they're independent of each other:

- `dev-scripts/build-pseudoregalia.bat` builds `main.dll` from
  `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/*` and stages it under
  `pseudoregalia/Binaries/Win64/ue4ss/Mods/MeshGhostPseudo/`, recording source hashes to
  `MeshGhostPseudo-built-from.txt` — same staleness-gate pattern as TEVI's `built-from.txt`
  above.
- `dev-scripts/stage-ue4ss-runtime.bat` stages the RE-UE4SS runtime itself (`UE4SS.dll`,
  settings, stock `Mods/`) from the pinned RE-UE4SS submodule, recording its own provenance to
  `ue4ss-runtime-built-from.txt`. This one is a deliberate exception to the project's normal
  "never redistribute the modding tool, user installs it themselves" posture — RE-UE4SS is
  MIT-licensed, and this ships its own `LICENSE` alongside the binaries per MIT's terms (see
  [agent_docs/licensing.md](../agent_docs/licensing.md)'s RE-UE4SS entry).

Both stage into the same `pseudoregalia/Binaries/Win64/...` tree, mirroring the real Steam
install's own folder layout, so the whole `pseudoregalia/` folder is one drag-and-drop into a
user's Steam install root — same onboarding as the AP randomizer. Whoever edits the C++ mod or
bumps the RE-UE4SS submodule pin re-runs the relevant script and commits the result.

## Cutting a release

Manual only, deliberately — nothing publishes on its own just from pushing a commit or tag.
On GitHub: repo → **Actions** tab → **Release** workflow → **Run workflow** → type a version
(e.g. `v0.1.0`), tick **prerelease** if this cut includes untested content → run. It builds both
`.exe`s for Windows/amd64 — the only platform the *full* bundle supports, since BizHawk's
LuaSocket vendoring is Windows-only (per
[agent_docs/licensing.md](../agent_docs/licensing.md)) — plus client and server binaries for
linux and darwin on amd64 and arm64 for the two tarballs. It verifies three committed build
outputs aren't stale (the TEVI plugin, the Pseudoregalia plugin, and the bundled UE4SS runtime —
each gated on its own `built-from.txt`-style hash record), assembles the three assets, creates
the tag if it doesn't already exist, and attaches them to a new GitHub Release.
