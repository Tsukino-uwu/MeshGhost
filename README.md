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

A release publishes three downloads. **`MeshGhost-full-<version>.zip` is the one nearly
everyone wants** — client, server, and every game's mod, for Windows. Alongside it,
`MeshGhost-linux-<version>.tar.gz` and `MeshGhost-macos-<version>.tar.gz` hold native builds of
just the client and server (amd64 and arm64), ready to run: they're built on Linux and tarred,
so they keep their executable bit instead of needing a `chmod` first.

The native builds are optional, and often unnecessary. Every game supported today is a Windows
game, so a Linux player is already running it through Proton — and the Windows client runs in
that same prefix, which for Pseudoregalia happens by itself. They're worth having for hosting a
relay (no game involved, so no reason to go through Wine) or if you'd simply rather the client
were a native process. Only Windows has actually been played on; the others are compiled and
tested by CI on Linux, and macOS has no test machine at all.

Each game's adapter is its own platform story and does not follow: TEVI's and Pseudoregalia's
mods are Windows DLLs (so on Linux they run inside the game's Proton prefix), while Emerald's
is a Lua script that runs wherever BizHawk does.

## Setup

1. Grab the latest release zip from the [Releases page](../../releases) and unzip it.
2. Edit `config.json`: `connect_to` (the host's address), `room` (must match everyone else's),
   and `name`. If the host set a `room_code`, enter that too.
3. Run `meshghost.exe` — everyone does this, **except for Pseudoregalia, where the mod starts it
   for you with no window** (its settings then live in the mod's own folder, in the `config.json`
   beside it). Whoever's hosting also runs
   `meshghost-server.exe` and forwards port 7777 — **both `tcp` and `udp`, which are two separate
   rules on most routers**, since sessions run on quic over that same number (see Transports
   below; the server prints exactly what to forward when it starts). A host who wants their server to be for one
   game only sets `server.only_game` to that game's id from the list above; left blank (the
   default) the server hosts any game, including several at once in different rooms.
4. Load your game's mod from `games\<publisher>\<game>\` (BizHawk Lua Console for Emerald,
   BepInEx for TEVI, UE4SS for Pseudoregalia) — for Emerald and TEVI, **after** `meshghost.exe`
   is already running. For Pseudoregalia there's no order to get right: starting the game is the
   whole thing.
   (Emerald is the only game with a `<publisher>` subfolder — `games\pokemon\emerald\` — since
   "emerald" alone isn't a unique-enough folder name; TEVI and Pseudoregalia sit directly under
   `games\`.)

Full walkthrough: `packaging/release/README.txt` (ships in the zip) and
[packaging/README.md](packaging/README.md) for how it's built.

### Good to know

- Reads game memory, never writes it — MeshGhost does not touch your save.
- Up to 8 players per server by default, counted across all rooms — the host can raise it.
- Bring your own legally-obtained copy of each game — no ROMs or game assets are shipped here.
- `room` is a label, not a password. `room_code` is the optional actual secret. By default it is
  encrypted in transit, since sessions run on `quic` — but it crosses in the clear on `tcp` and
  `udp`, so don't rely on it there against a determined attacker (see Transports below).
- Archipelago and other mods/patches: a goal, not a tested guarantee. Emerald's adapter reads
  memory rather than patching the ROM, and TEVI's/Pseudoregalia's adapters were built alongside
  their AP mods — but an AP-patched Emerald ROM can shift where facing/running are read from,
  so treat it as "should work," not confirmed.

### Transports — quic by default, tcp as the handshake and the fallback

**Out of the box a session runs on `quic`.** Every connection still *starts* on `tcp`: the client
connects there, asks the server what it serves, and swaps to the best answer. So `connect_to` only
ever needs the server's `tcp` address — the client is told the rest — and if the swap isn't
available it simply stays on tcp and keeps working. Nothing to configure for either.

| | Default | What it's for |
| --- | --- | --- |
| `quic` | **yes** — what you actually run on | Encrypted, and drops a stale position instead of delaying the ones behind it |
| `tcp` | **yes** — always the handshake, and the fallback | Works everywhere, readable on the wire when debugging |
| `udp` | no — opt in | Same loss behaviour as quic but **cannot be encrypted**; there if quic is blocked |

`quic` shares the server's port *number* (`7777/udp` alongside `7777/tcp`), so hosting still means
forwarding one number — but they are two separate router rules, and the server prints exactly what
to forward when it starts. Turning on plain `udp` as well is the one case needing a second port.

Set `"transport"` in `config.json` to override: `auto` (the default — prefers quic, never silently
picks the unencrypted one), or `tcp`/`udp`/`quic` to pin it. A room can mix all three, and asking
for something the server doesn't serve leaves you connected rather than failing.

Encrypted is not authenticated: quic hides your traffic and your `room_code` from anyone watching
the network, but the server's certificate isn't verified, so it isn't proof of *who* you reached.

Which ports to forward: `packaging/release/README.txt`. Why it works this way:
[agent_docs/architecture.md](agent_docs/architecture.md)'s transport ADRs.

## How it works

- **Relay** — a small, game-agnostic server that forwards position/area/animation snapshots
  between clients. Never runs or touches the game.
- **Core client** — game-agnostic logic: talks to the relay, buffers and interpolates remote
  player state. Never touches game memory or rendering.
- **Adapter** — the game-specific layer. Reads the local game's position/area/animation and
  draws the ghost. Never touches the network directly. How each one actually reads its game:
  [Emerald](adapters/pokemon/emerald/README.md), [TEVI](adapters/tevi/README.md),
  [Pseudoregalia](adapters/pseudoregalia/README.md).

Full detail: [internal/documentation.md](internal/documentation.md) (how the relay and client
actually work — the life of a connection and of a state message, traced through the real code),
[agent_docs/contract.md](agent_docs/contract.md) (schema and interfaces),
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
- [agent_docs/risks.md](agent_docs/risks.md) — known risks and open assumptions (e.g. the default
  `quic` path encrypts the `room_code` but does not authenticate the server; `udp` can never
  encrypt it at all).
- [agent_docs/verified.md](agent_docs/verified.md) — append-only log of facts actually
  confirmed against a running game, not just "it built."
- [agent_docs/licensing.md](agent_docs/licensing.md) — what prior-art projects were checked
  and how they may be used, including the
  [`pokeemerald`](https://github.com/pret/pokeemerald) decompilation consulted for Emerald
  memory facts only (never for source or assets).

## "My antivirus flagged it"

MeshGhost's client and server are unsigned Go binaries, and two different things flag them. They
are separate causes with separate answers, so they are worth telling apart rather than lumping
together as "it's a false positive, trust me."

**1. Scanners that don't recognise Go binaries.** This one isn't about MeshGhost at all — it
happens to Go programs generally, and Go's own FAQ says so
([go.dev/doc/faq](https://go.dev/doc/faq#virus_scanning_software)):

> This is a common occurrence, especially on Windows machines, and is almost always a false
> positive. Commercial virus scanning programs are often confused by the structure of Go binaries,
> which they don't see as often as those compiled from other languages.

**2. A Microsoft Defender detection whose name ends in `!ml`.** That suffix means the verdict came
from a machine-learning model rather than a signature match — Defender is not saying "this is a
known bad file", it's saying "this *looks* like one". And the profile it matches on is, honestly,
accurate about MeshGhost: the binaries are unsigned, they're downloaded by very few people so they
have no reputation, they open network connections, and for Pseudoregalia the game's mod starts one
*for* you rather than you double-clicking it. That combination is also what a dropper looks like.
The heuristic isn't being stupid; it just can't tell the difference yet.

**What you can actually check, rather than taking our word for it:**

- The whole source is in this repo, and the release binaries are built from it by GitHub Actions —
  the build is a public workflow log, not something produced on a developer's machine.
- Every release asset shows a SHA-256 on the [Releases page](../../releases). If the file you have
  matches, it's the file CI produced.
- If it's specifically the Pseudoregalia mod starting `meshghost.exe` that your scanner objects to,
  set the environment variable `MESHGHOST_NO_AUTOSTART` to anything and start the client yourself —
  that path is unchanged and fully supported.

**What we intend to do about it:** get the binaries code-signed, via SignPath's free offering for
open-source projects. That work hasn't started. It should help with both causes, but it's worth
being straight that signing is a lever rather than a switch — an ML verdict weighs reputation as
well as signing, and reputation is something a new certificate earns over time rather than arrives
with. If your scanner flags a MeshGhost binary, reporting it to that vendor as a false positive
genuinely helps, which is the same thing Go's FAQ asks for.
