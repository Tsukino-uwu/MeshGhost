# MeshGhost

MeshGhost is an online multiplayer layer for single-player games. Friends show up as ghosts with
live position, facing and animation, and the worlds stay separate: no synced items, enemies, health
or progression. If a friend kills a boss, it stays alive in your world. Syncing more than that is
up to each game's mod, and the protocol underneath already carries it, but it is never on by
default — a game that does more says so in its own README.

## Games

Each link goes to that adapter's own README: how it reads its game, how it was built, and what it
can show today.

- [Pokémon Emerald](adapters/emulator/pokemon/emerald/README.md)
- [Pokémon Crystal](adapters/emulator/pokemon/crystal/README.md)
- [TEVI](adapters/tevi/README.md)
- [Pseudoregalia](adapters/pseudoregalia/README.md)

## Setup

- [Download](https://github.com/Tsukino-uwu/MeshGhost/releases)
- [Install guide](docs/getting-started.md)
- [Hosting a server](docs/hosting.md)
- [Troubleshooting](docs/troubleshooting.md)
- [All docs](docs/README.md)

## Contributing

**[.github/CONTRIBUTING.md](.github/CONTRIBUTING.md)** — the two things to do once per clone, which
tests to run, and where the rules live.

## Licence

[MIT](LICENSE). Bring your own copy of each game — no ROMs, game assets or decompiled source are
in this repo, and none ever will be.
