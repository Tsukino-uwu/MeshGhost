# MeshGhost

MeshGhost is a visual-only multiplayer layer for single-player games. Everyone runs their own
fully independent copy of the game; friends show up as cosmetic "ghosts" with no shared world
state — no synced items, enemies, health, or progression. Desync is expected and fine: if a
friend kills a boss, it stays alive in your world, and that's okay.

## Games

- **Pokémon Emerald** (GBA, via BizHawk) — game id `emerald`. Tested online with two real
  players. Animated, correctly-gendered Brendan/May ghosts with live position, facing, walking,
  and running.
- **TEVI** (Unity) — game id `tevi`. Adapter confirmed working (two clients / client +
  loopback), not yet tested online.
- **Pseudoregalia** (Unreal Engine 5) — game id `pseudoregalia`. Adapter confirmed working
  locally, not yet tested online.

The game id is what an adapter announces itself as. You never set it yourself as a player —
it's picked up automatically from whichever game's mod you load — but a host running a
dedicated single-game server types one of those exact strings into `server.only_game` (see
Setup below).

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
   `meshghost-server.exe` and forwards a TCP port. A host who wants their server to be for one
   game only sets `server.only_game` to that game's id from the list above; left blank (the
   default) the server hosts any game, including several at once in different rooms.
4. Load your game's mod from `games\<publisher>\<game>\` (BizHawk Lua Console for Emerald,
   BepInEx for TEVI, UE4SS for Pseudoregalia) — **after** `meshghost.exe` is already running.
   (Emerald is the only game with a `<publisher>` subfolder — `games\pokemon\emerald\` — since
   "emerald" alone isn't a unique-enough folder name; TEVI and Pseudoregalia sit directly under
   `games\`.)

Full walkthrough: `packaging/release/README.txt` (ships in the zip) and
[packaging/README.md](packaging/README.md) for how it's built.

### Good to know

- Reads game memory, never writes it — MeshGhost does not touch your save.
- Up to 8 players per server by default, counted across all rooms — the host can raise it.
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
  draws the ghost. Never touches the network directly. How each one actually reads its game:
  [Emerald](adapters/pokemon/emerald/README.md), [TEVI](adapters/tevi/README.md),
  [Pseudoregalia](adapters/pseudoregalia/README.md).

Full detail: [agent_docs/contract.md](agent_docs/contract.md) (schema and interfaces),
[agent_docs/architecture.md](agent_docs/architecture.md) (system shape and design rationale), and
[internal/README.md](internal/README.md) (the relay/core's own networking-layer doc — security
posture, what's already checked-safe vs. the known open gaps).

## Repo layout

```text
MeshGhost/
├── cmd/                  # entry points: the desktop app, the standalone relay
├── internal/             # core, relay, protocol, transport, adapter bridge
├── adapters/             # one folder per game; _template/ is the starting point for a new one
├── agent_docs/           # design brief, contract, architecture, roadmap, verified facts
├── dev-scripts/          # local test rig: launchers, load tests, adapter build scripts
├── packaging/            # what goes in the release zip, and how it's assembled
├── go.mod
└── README.md
```

## Docs

- [agent_docs/README.md](agent_docs/README.md) — **full internal documentation index.** Start
  here if what you're looking for isn't in the shortlist below — it covers everything from
  system design to risk tracking to what's actually been confirmed running.
- [agent_docs/brief.md](agent_docs/brief.md) — the full design brief and reasoning.
- [agent_docs/plans.md](agent_docs/plans.md) — the phase-by-phase roadmap.
- [agent_docs/status.md](agent_docs/status.md) — one-screen summary of where things stand.
- [agent_docs/pitfalls.md](agent_docs/pitfalls.md) — adapter-specific issues found while
  building each game's adapter, and how they were diagnosed and fixed.
- [agent_docs/risks.md](agent_docs/risks.md) — known risks and open assumptions (e.g. no TLS
  on the wire yet).
- [agent_docs/verified.md](agent_docs/verified.md) — append-only log of facts actually
  confirmed against a running game, not just "it built."
- [agent_docs/licensing.md](agent_docs/licensing.md) — what prior-art projects were checked
  and how they may be used, including the
  [`pokeemerald`](https://github.com/pret/pokeemerald) decompilation consulted for Emerald
  memory facts only (never for source or assets).
