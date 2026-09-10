# MeshGhost

MeshGhost is an online multiplayer layer for single-player games. Friends show up as ghosts with
live position, facing and animation, and the worlds stay separate: no synced items, enemies, health
or progression. If a friend kills a boss, it stays alive in your world. Syncing more than that is
up to each game's mod, and the protocol underneath already carries it, but it is never on by
default — a game that does more says so in its own README.

## Games

- [Pokémon Emerald](adapters/emulator/pokemon/emerald/README.md)
- [Pokémon Crystal](adapters/emulator/pokemon/crystal/README.md)
- [TEVI](adapters/tevi/README.md)
- [Pseudoregalia](adapters/pseudoregalia/README.md)

Each link goes to that adapter's own README: how it reads its game, how it was built, and what it
can show today.

## Setup

**Download:** the [Releases page](https://github.com/Tsukino-uwu/MeshGhost/releases). Then
**[docs/getting-started.md](docs/getting-started.md)**, with
[docs/hosting.md](docs/hosting.md) for whoever runs the server and
[docs/troubleshooting.md](docs/troubleshooting.md) when something is wrong. All three ship in the
zip too, under `docs\`.

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

- [getting-started.md](docs/getting-started.md) — **start here.** Everything a player does, from unzipping to seeing a friend appear.
- [hosting.md](docs/hosting.md) — running the server for your group: the short version, then every knob and what it costs.
- [troubleshooting.md](docs/troubleshooting.md) — it did not work, or something looks wrong.
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
- [code-signing.md](docs/code-signing.md) — what a signature on a release vouches for, and who holds the keys (nobody).

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
- [beyond-cosmetic.md](agent_docs/beyond-cosmetic.md) — how far MeshGhost can go past cosmetic
  ghosts, what the protocol already carries, and where a dumb relay stops.
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
