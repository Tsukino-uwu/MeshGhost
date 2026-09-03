# MeshGhost

MeshGhost is an online multiplayer layer for single-player games. Everyone runs their own copy,
friends show up as ghosts with live position, facing and animation, and the worlds stay separate.
Nothing is synced unless a game's mod asks for it: not items, enemies, health or progression. If a
friend kills a boss, it stays alive in your world.

It also records you. Play a run back and it becomes a replay ghost, running your own line beside
you, to race the way you would a time-trial ghost. A recording is one small file, so a good run can
be kept, edited or sent to a friend. A chaser is the same idea without a file: your own past,
following a few seconds behind you as you play. Neither needs a server or anyone else online.

Your save is never touched and no ROM is patched. Some adapters put a ghost into the game's live
memory, and that memory is gone the moment you close it. Uninstalling is deleting the mod's folder.

**Download:** the [Releases page](../../releases). `MeshGhost-full-<version>.zip` is the one nearly
everyone wants — client, server, and every game's mod, for Windows. Native Linux and macOS builds
of just the client and server are there too, and are usually unnecessary: every supported game is
a Windows game, so a Linux player is already running it through Proton, and the Windows client
runs in that same prefix.

## Games

- [Pokémon Emerald](adapters/emulator/pokemon/emerald/README.md)
- [Pokémon Crystal](adapters/emulator/pokemon/crystal/README.md)
- [TEVI](adapters/tevi/README.md)
- [Pseudoregalia](adapters/pseudoregalia/README.md)

Each link goes to that adapter's own README: how it reads its game, how it was built, and what it
can show today.

**One server hosts every game at once**, with nothing to set up for it: a single
`meshghost-server.exe` carries Emerald, Crystal, TEVI and Pseudoregalia sessions simultaneously
on one port. Each game gets its own rooms automatically, so games never collide and players only
ever see others in the same game and the same room name. A host who wants their server locked to
one game sets `server.only_game` to that game's id — `emerald`, `crystal`, `tevi` or
`pseudoregalia`. Players never set it: a mod announces its own id.

## Setup

1. Grab the latest release zip from the [Releases page](../../releases) and unzip it.
2. Edit `config.json`: `connect_to` (the host's address), `room` (must match everyone else's),
   and `name`. If the host set a `room_code`, enter that too.
3. Load your game's mod from `games\<publisher>\<game>\` — BizHawk's Lua Console for Emerald and
   Crystal, BepInEx for TEVI, UE4SS for Pseudoregalia. **You do not start `meshghost.exe` yourself:
   every adapter starts one for you, with no window, and closes it again with the game.** There is
   no order to get right and nothing to leave open. (The two Pokémon games are the only ones with a
   `<publisher>` subfolder: `games\pokemon\emerald\` and `games\pokemon\crystal\`.)
4. Whoever is hosting also runs `meshghost-server.exe` and forwards port 7777 — **both `tcp` and
   `udp`, which are two separate rules on most routers**. The server prints exactly what to forward
   when it starts.

TEVI and Pseudoregalia install their mod *into* the game, so they need `meshghost.exe` copied into
that mod's folder once, and they read the `config.json` that sits beside it rather than the one in
the folder you unzipped. Emerald and Crystal run from the release folder itself and need neither.
Setting `"autostart": false` in that `config.json` turns autostart off, if you would rather run the
client by hand. (The older `MESHGHOST_NO_AUTOSTART` environment variable still works.)

Bring your own legally-obtained copy of each game. No ROMs or game assets are shipped here.

Full walkthrough: `packaging/release/README.txt`, which ships in the zip.

## How it works

- **Relay** — a small, game-agnostic server that forwards position/area/animation snapshots
  between clients. Never runs or touches the game.
- **Core client** — game-agnostic logic: talks to the relay, buffers and interpolates remote
  player state, and re-checks everything the relay sends (sizes, finite numbers, a bounded roster,
  sanitized names) before the adapter sees any of it. Never touches game memory or rendering.
- **Adapter** — the game-specific layer. Reads the local game's position/area/animation and draws
  the ghost. Never touches the network directly.

That split is the whole design: the relay and core know nothing about any game, so a new game is
an adapter and nothing else.

**How deep could this go?** The protocol underneath cosmetic ghosts already carries reliable
addressed events, exclusive locks over opaque keys, both-or-neither exchanges, and custody of a
world the server holds but cannot read — all built, all off unless every member of a room opts
in, and used by no shipped game. What that buys tops out at bounded, consensual interactions
between two players, because the server never understands the game and so can never judge
content; there is no anti-cheat here. A single game's adapter could go much further, up to real
co-op, but that is a per-game netcode project reusing this relay rather than a MeshGhost feature.
The full reasoning, including which shipped games could and could not:
[agent_docs/beyond-cosmetic.md](agent_docs/beyond-cosmetic.md).

Deeper detail: [docs/networking.md](docs/networking.md) (how the relay and client actually work,
traced through the real code), [agent_docs/contract.md](agent_docs/contract.md) (schema and
interfaces), [agent_docs/architecture.md](agent_docs/architecture.md) (system shape and rationale).

## Using this from your own game

**Any language: run it beside your game.** `meshghost.exe` does all the networking as its own
process; your game connects a TCP socket to it on localhost and exchanges one JSON object per
line. There is no library to link — which is why the shipped adapters are written in unrelated
languages (Lua, C#, C++) and share no code. Rust, Python, Godot, Java: same shape.
[docs/integrating.md](docs/integrating.md) is the guide, with a conformance checklist and a
worked example.

**Go only: compile it in.**

```text
go get github.com/Tsukino-uwu/MeshGhost
```

**What `v1.0.0` (2026-08-30) does and does not promise.** The stable surface is the **wire
protocol**: it is version-checked at the handshake, additions since have been optional fields an
old client safely ignores, and [docs/integrating.md](docs/integrating.md) documents it precisely
so other games and other clients can build against the relay — which is what the 1.0 marks. The
**Go package APIs** follow module semver from here (a breaking Go-API change means a `/v2` module
path), but third-party use of the packages is unsupported and untested — we will not knowingly
break you, and we also will not know if we do. `v0.9.0` is the first fetchable tag — `v0.8.5` and
earlier were cut under the old module name and cannot be resolved at all. If you need something
that cannot move under you, pin a version, or fork/vendor it;
[MIT](LICENSE) allows that outright. None of this affects adapters, which speak a socket rather
than a Go API.

## Repo layout

Grouped by what each thing *is*, not alphabetically — so GitHub's file listing shows these in a
different order. Only the directories worth orienting on are listed; the usual `LICENSE`,
`.gitignore` and friends are omitted.

```text
MeshGhost/
├── cmd/                  # entry points: the desktop app, the standalone relay, and the test
│                         #   rig's fake adapter and network simulator
│
│                         # the library, importable from outside:
├── core/                 # game-agnostic client: relay connection, buffering, interpolation
├── relay/                # game-agnostic server: rooms, forwarding, limits
├── protocol/             # the wire messages both speak
├── transport/            # NDJSON framing over any net.Conn
├── bridge/               # the adapter <-> local core messages
├── netx/                 # transport selection: tcp | udp | quic
│
├── internal/             # not importable: the e2e suite that drives the real binaries, config
│                         #   loading, and the check that keeps the Go side game-blind
├── adapters/             # one folder per game; _template/ is the starting point for a new one
├── docs/                 # for people using MeshGhost
├── agent_docs/           # design brief, contract, architecture, roadmap, verified facts
├── dev-scripts/          # local test rig: launchers, load tests, adapter build scripts
├── packaging/            # what goes in the release zip, and how it's assembled
├── .github/workflows/    # CI on every push; the release is a manual button
├── CLAUDE.md             # the rules this project is built under, for whoever works on it
└── go.mod
```

## Docs

Two folders, split by who they are for. **`docs/` is for people using MeshGhost**; `agent_docs/`
is the internal working record of how it got built.

**`docs/`**

- [config.md](docs/config.md) — every `config.json` key: its shipped value, what it does, which program reads it.
- [integrating.md](docs/integrating.md) — putting MeshGhost in your own game, in any language.
- [security.md](docs/security.md) — the security and privacy posture: what is already
  checked-safe, the gaps that remain, and a dated changelog of every hardening pass.
- [reviewing.md](docs/reviewing.md) — auditing it yourself: which code a host runs, where the
  bytes go, and how to run the fuzzers and race detector on your own machine.
- [networking.md](docs/networking.md) — how the relay and client actually work, traced through
  the real code.
- [live-reload.md](docs/live-reload.md) — how a code change reaches a running game without
  restarting it, and why each host (BizHawk, BepInEx, UE4SS) needed its own answer.
- [antivirus.md](docs/antivirus.md) — why the binaries get flagged, and what you can check.

**`agent_docs/`**

- [README.md](agent_docs/README.md) — **the full index.** Start here if what you want is not below.
- [brief.md](agent_docs/brief.md) — the design brief and reasoning.
- [contract.md](agent_docs/contract.md) — the implemented contract: wire protocol, bridge, limits.
- [architecture.md](agent_docs/architecture.md) — the system shape, and the index of every
  decision record in [adr/](agent_docs/adr/).
- [plans.md](agent_docs/plans.md) — the phase-by-phase roadmap; [phases/](agent_docs/phases/)
  holds one work log per phase and per game.
- [status.md](agent_docs/status.md) — one-screen summary of where things stand.
- [pitfalls.md](agent_docs/pitfalls.md) — adapter-specific issues, and how they were diagnosed.
- [risks.md](agent_docs/risks.md) — known risks and open assumptions.
- [verified.md](agent_docs/verified.md) — append-only log of facts actually confirmed running.
  Go-side and cross-game entries plus the index; each adapter carries its own `VERIFIED.md`
  (and `UNVERIFIED.md`, the queue waiting on the user) beside its `README.md`.
- [licensing.md](agent_docs/licensing.md) — what prior-art projects were checked and how they may
  be used, including the [`pokeemerald`](https://github.com/pret/pokeemerald) decompilation
  consulted for Emerald memory facts only, never for source or assets.

## Contributing

Two things before the first commit, both once per clone: `git config core.hooksPath .githooks`, so the
pre-commit hook can refuse a machine-specific path before it reaches the public tree, and a run of
`dev-scripts/preflight.ps1`, which checks the docs, the adapter file sets and the built artifacts and
says what a change is expected to keep true. For anything under `core`, `relay`, `transport`, `bridge`
or `cmd`, `dev-scripts/run-gotests.bat` is the whole suite; CI runs the same plus the fuzzers and the
race detector on every push. The rules the project is built under are `CLAUDE.md`, and
`agent_docs/README.md` is the map of everything else.

## Licence

[MIT](LICENSE). Bring your own copy of each game — no ROMs, game assets or decompiled source are
in this repo, and none ever will be.
