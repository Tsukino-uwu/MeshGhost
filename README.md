# MeshGhost

MeshGhost is an online multiplayer layer for single-player games. Everyone runs their own fully
independent copy of the game; friends show up as "ghosts" — live position, facing and animation —
while the worlds themselves stay separate. Nothing is shared unless a game's mod asks for it: by
default there are no synced items, enemies, health or progression, and desync is expected and
fine. If a friend kills a boss, it stays alive in your world, and that's okay.

**Your save is never touched.** MeshGhost reads the game's memory and draws ghosts over the top;
it does not write game state and does not modify save files — not your own, and not the save of
anyone you play with. That is a rule the project holds itself to rather than a happy accident of
the current features, and it stays true of anything added later. Uninstalling is deleting the
mod's folder.

**Download:** the [Releases page](../../releases). `MeshGhost-full-<version>.zip` is the one nearly
everyone wants — client, server, and every game's mod, for Windows. Native Linux and macOS builds
of just the client and server are there too, and are usually unnecessary: every supported game is
a Windows game, so a Linux player is already running it through Proton, and the Windows client
runs in that same prefix.

## Games

- [Pokémon Emerald](adapters/bizhawk/pokemon/emerald/README.md)
- [Pokémon Crystal](adapters/bizhawk/pokemon/crystal/README.md)
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
3. Run `meshghost.exe` — everyone does this, **except for Pseudoregalia, where the mod starts it
   for you with no window** (its settings then live in the `config.json` beside the mod). Whoever
   is hosting also runs `meshghost-server.exe` and forwards port 7777 — **both `tcp` and `udp`,
   which are two separate rules on most routers**. The server prints exactly what to forward when
   it starts.
4. Load your game's mod from `games\<publisher>\<game>\` (BizHawk Lua Console for Emerald and
   Crystal, BepInEx for TEVI, UE4SS for Pseudoregalia) — for Emerald, Crystal and TEVI, **after**
   `meshghost.exe` is already running. For Pseudoregalia there is no order to get right: starting
   the game is the whole thing. (The two Pokémon games are the only ones with a `<publisher>`
   subfolder: `games\pokemon\emerald\` and `games\pokemon\crystal\`.)

Full walkthrough: `packaging/release/README.txt`, which ships in the zip.

### Good to know

- Up to 8 players per server by default, counted across all rooms — the host can raise it.
- Bring your own legally-obtained copy of each game. No ROMs or game assets are shipped here.
- `room` is a label, not a password. `room_code` is the optional actual secret.
- Archipelago and other mods/patches: a goal, not a tested guarantee. An AP-patched Emerald ROM
  can shift where facing and running are read from, so treat it as "should work", not confirmed.
- Flagged by your antivirus? That is expected and worth understanding rather than waving away —
  [docs/antivirus.md](docs/antivirus.md).

### Transports

**Out of the box a session runs on `quic`.** Every connection still *starts* on `tcp`: the client
connects there, asks the server what it serves, and swaps to the best answer. So `connect_to` only
ever needs the server's `tcp` address, and if the swap is not available it stays on tcp and keeps
working. Nothing to configure.

| | Default | What it's for |
| --- | --- | --- |
| `quic` | **yes** — what you actually run on | Encrypted, and drops a stale position instead of delaying the ones behind it |
| `tcp` | **yes** — always the handshake, and the fallback | Works everywhere, readable on the wire when debugging |
| `udp` | no — opt in | Same loss behaviour as quic but **cannot be encrypted**; there if quic is blocked |

`quic` shares the server's port *number* (`7777/udp` alongside `7777/tcp`), so hosting still means
forwarding one number — as two separate router rules. Set `"transport"` in `config.json` to
override: `auto` (the default — prefers quic, never silently picks the unencrypted one), or
`tcp`/`udp`/`quic` to pin it.

**Encrypted is not authenticated.** quic hides your traffic and your `room_code` from anyone
watching the network, but the server's certificate is not verified, so it is not proof of *who*
you reached. Full posture: [docs/security.md](docs/security.md). Why it works this way:
[agent_docs/architecture.md](agent_docs/architecture.md)'s transport ADRs.

## How it works

- **Relay** — a small, game-agnostic server that forwards position/area/animation snapshots
  between clients. Never runs or touches the game.
- **Core client** — game-agnostic logic: talks to the relay, buffers and interpolates remote
  player state. Never touches game memory or rendering.
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
line. There is no library to link — which is why the four shipped adapters are written in three
unrelated languages (Lua, C#, C++) and share no code. Rust, Python, Godot, Java: same shape.
[docs/integrating.md](docs/integrating.md) is the guide, with a conformance checklist and a
worked example.

**Go only: compile it in.**

```text
go get github.com/Tsukino-uwu/MeshGhost
```

**Nothing here is promised.** Pre-1.0, **no API stability guarantee** — these packages may change
shape in any release, we do not test third-party use, and we will not know if we break you.
`v0.9.0` is the first fetchable tag — `v0.8.5` and earlier were cut under the old module name and
cannot be resolved at all. If you need something that cannot move under you, fork or vendor it;
[MIT](LICENSE) allows that outright. None of this affects adapters, which speak a socket rather
than a Go API.

## Repo layout

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
├── internal/             # e2e tests only — deliberately not importable
├── adapters/             # one folder per game; _template/ is the starting point for a new one
├── docs/                 # for people using MeshGhost
├── agent_docs/           # design brief, contract, architecture, roadmap, verified facts
├── dev-scripts/          # local test rig: launchers, load tests, adapter build scripts
├── packaging/            # what goes in the release zip, and how it's assembled
└── go.mod
```

## Docs

Two folders, split by who they are for. **`docs/` is for people using MeshGhost**; `agent_docs/`
is the internal working record of how it got built.

**`docs/`**

- [integrating.md](docs/integrating.md) — putting MeshGhost in your own game, in any language.
- [security.md](docs/security.md) — the security and privacy posture: what is already
  checked-safe, and the gaps that remain.
- [networking.md](docs/networking.md) — how the relay and client actually work, traced through
  the real code.
- [antivirus.md](docs/antivirus.md) — why the binaries get flagged, and what you can check.

**`agent_docs/`**

- [README.md](agent_docs/README.md) — **the full index.** Start here if what you want is not below.
- [brief.md](agent_docs/brief.md) — the design brief and reasoning.
- [plans.md](agent_docs/plans.md) — the phase-by-phase roadmap.
- [status.md](agent_docs/status.md) — one-screen summary of where things stand.
- [pitfalls.md](agent_docs/pitfalls.md) — adapter-specific issues, and how they were diagnosed.
- [risks.md](agent_docs/risks.md) — known risks and open assumptions.
- [verified.md](agent_docs/verified.md) — append-only log of facts actually confirmed running.
- [licensing.md](agent_docs/licensing.md) — what prior-art projects were checked and how they may
  be used, including the [`pokeemerald`](https://github.com/pret/pokeemerald) decompilation
  consulted for Emerald memory facts only, never for source or assets.

## Licence

[MIT](LICENSE). Bring your own copy of each game — no ROMs, game assets or decompiled source are
in this repo, and none ever will be.
