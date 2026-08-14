# MeshGhost

MeshGhost is a visual-only multiplayer layer for single-player games. Everyone runs their own
fully independent copy of the game; friends show up as cosmetic "ghosts" with no shared world
state — no synced items, enemies, health, or progression. Desync is expected and fine: if a
friend kills a boss, it stays alive in your world, and that's okay.

## Games

- **Pokémon Emerald** (GBA, via BizHawk) — tested online with two real players. Animated,
  correctly-gendered Brendan/May ghosts with live position, facing, walking, and running.
- **TEVI** (Unity) — adapter confirmed working (two clients / client + loopback), not yet
  tested online.
- **Pseudoregalia** (Unreal Engine 5) — adapter confirmed working locally, not yet tested
  online.

TEVI and Pseudoregalia aren't personally confirmed online yet, but they're expected to work —
the relay and core client are game-agnostic and don't know which game an adapter is for, so
"works locally" and "works online" are the same code path.

Releases are Windows-amd64 only today. Linux/macOS builds of the client and server are a real
goal (part of why the core is written in Go), though each game's adapter is its own platform
story and may not all follow.

## Setup

1. Grab the latest release zip from the [Releases page](../../releases) and unzip it.
2. Edit `config.json`: `connect_to` (the host's address), `room` (must match everyone else's),
   and `name`. If the host set a `room_code`, enter that too.
3. Run `meshghost.exe` — everyone does this. Whoever's hosting also runs
   `meshghost-server.exe` and forwards a TCP port.
4. Load your game's mod from `games\<publisher>\<game>\` (BizHawk Lua Console for Emerald,
   BepInEx for TEVI, UE4SS for Pseudoregalia) — **after** `meshghost.exe` is already running.

Full walkthrough: `packaging/release/README.txt` (ships in the zip) and
[packaging/README.md](packaging/README.md) for how it's built.

### Good to know

- Reads game memory, never writes it — MeshGhost does not touch your save.
- Up to 8 players per room.
- Bring your own legally-obtained copy of each game — no ROMs or game assets are shipped here.
- `room` is a label, not a password. `room_code` is the optional actual secret, and it isn't
  encrypted in transit yet — don't rely on it against a determined attacker.
- Archipelago and other mods/patches: a goal, not a tested guarantee. Emerald's adapter reads
  memory rather than patching the ROM, and TEVI's/Pseudoregalia's adapters were built alongside
  their AP mods — but an AP-patched Emerald ROM can shift where facing/running are read from,
  so treat it as "should work," not confirmed.

## How it works

- **Relay** — a small, game-agnostic server that forwards position/area/animation snapshots
  between clients. Never runs or touches the game.
- **Core client** — game-agnostic logic: talks to the relay, buffers and interpolates remote
  player state. Never touches game memory or rendering.
- **Adapter** — the game-specific layer. Reads the local game's position/area/animation and
  draws the ghost. Never touches the network directly.

Full detail: [agent_docs/contract.md](agent_docs/contract.md) (schema and interfaces) and
[agent_docs/architecture.md](agent_docs/architecture.md) (system shape and design rationale).

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

## Docs

- [agent_docs/brief.md](agent_docs/brief.md) — the full design brief and reasoning.
- [agent_docs/plans.md](agent_docs/plans.md) — the phase-by-phase roadmap.
- [agent_docs/status.md](agent_docs/status.md) — one-screen summary of where things stand.
- [agent_docs/pitfalls.md](agent_docs/pitfalls.md) — adapter-specific issues found while
  building each game's adapter, and how they were diagnosed and fixed.
- [agent_docs/licensing.md](agent_docs/licensing.md) — what prior-art projects were checked
  and how they may be used, including the
  [`pokeemerald`](https://github.com/pret/pokeemerald) decompilation consulted for Emerald
  memory facts only (never for source or assets).
