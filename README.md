# MeshGhost

MeshGhost is a visual-only multiplayer layer for single-player games. Each player runs a
fully independent copy of the game; remote players are rendered as cosmetic "ghosts" with no
shared world state — no synced items, enemies, health, or progression, and no attempt to
keep worlds consistent. Desync between players is expected and fine.

Status: **working, single-game.** Two independent Pokémon Emerald players (via BizHawk) can
join the same relay and see each other as real, animated, correctly-gendered Brendan/May
ghosts — position, facing, walking, and running all tracked live, no shared world state. See
[agent_docs/status.md](agent_docs/status.md) for exactly where things stand and
[agent_docs/plans.md](agent_docs/plans.md) for the phase-by-phase roadmap.

## Playing right now (Emerald, plus experimental TEVI)

No need to build anything: grab the latest release from the [Releases page](../../releases) —
one zip for everyone. Unpack it, run `run-client.bat` to play; whoever's hosting also runs
`run-server.bat`. The one file you actually need to edit is `config.json` (server address,
room name, your display name), and `README.txt` has the full walkthrough. See
[packaging/README.md](packaging/README.md) if you're curious how it's built.

## The shape

- **Relay** — a small, game-agnostic server that forwards position/area/animation snapshots
  between clients. Never runs or touches the game.
- **Core client** — game-agnostic logic: talks to the relay, buffers and interpolates remote
  player state. Never touches game memory or rendering.
- **Adapter** — the game-specific layer. Reads the local game's position/area/animation and
  draws the ghost. Never touches the network directly.

Full detail: [agent_docs/contract.md](agent_docs/contract.md) (the schema and interfaces) and
[agent_docs/architecture.md](agent_docs/architecture.md) (system shape and design rationale).

## Goals for the shipped app

The end target is a normal desktop program — no Python, no separate runtime install — that
works on Windows, Linux, and macOS. The core and relay are written in Go specifically so
they can ship as a single dependency-free binary per platform (see the ADR in
[agent_docs/architecture.md](agent_docs/architecture.md)). Game-specific adapters stay
lightweight and easy to drop in next to the game (a Lua script for BizHawk, a mod DLL for
Unity, and so on).

## Target games

1. **Pokémon Emerald** (GBA, via BizHawk) — first, **working**. Reading state is trivial
   thanks to the [`pokeemerald`](https://github.com/pret/pokeemerald) decompilation (consulted
   for facts only — addresses and struct layouts, cited by file/line — never for source or
   assets; see [agent_docs/licensing.md](agent_docs/licensing.md)).
2. **TEVI** (Unity) — second, code-complete but not yet confirmed with two real players; see
   [agent_docs/phases/phase6.md](agent_docs/phases/phase6.md).
3. **Pseudoregalia** (Unreal Engine 5) — third, not yet started.

## Repo layout

```text
MeshGhost/
├── cmd/                  # entry points: the desktop app, the standalone relay
├── internal/             # core, relay, protocol, transport, adapter bridge
├── adapters/             # one folder per game; _template/ is the frozen stub (post-Phase 5)
├── agent_docs/           # design brief, contract, architecture, roadmap, verified facts
├── go.mod
└── README.md
```

## Read next

- [agent_docs/brief.md](agent_docs/brief.md) — the full design brief and reasoning.
- [agent_docs/contract.md](agent_docs/contract.md) — packet schema, adapter interface,
  transport, and tick model.
- [agent_docs/plans.md](agent_docs/plans.md) — the phase-by-phase roadmap.
- [agent_docs/pitfalls.md](agent_docs/pitfalls.md) — adapter-specific issues found while
  building each game's adapter, and how they were diagnosed and fixed.
- [agent_docs/licensing.md](agent_docs/licensing.md) — what prior-art projects were checked
  and how they may be used.
