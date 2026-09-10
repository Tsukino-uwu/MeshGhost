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

**Download:** can be found at the [Releases page](https://github.com/Tsukino-uwu/MeshGhost/releases).
Instructions for how to play at **[docs/getting-started.md](docs/getting-started.md)**, along with
[docs/hosting.md](docs/hosting.md) for whoever runs the server and
[docs/troubleshooting.md](docs/troubleshooting.md) if something goes wrong.

## Docs

**[docs/](docs/README.md)** is for people using MeshGhost. **[agent_docs/](agent_docs/README.md)**
is the internal working record.

## Contributing

**[.github/CONTRIBUTING.md](.github/CONTRIBUTING.md)** — the two things to do once per clone, which
tests to run, and where the rules live.

## Licence

[MIT](LICENSE). Bring your own copy of each game — no ROMs, game assets or decompiled source are
in this repo, and none ever will be.
