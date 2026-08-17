# MeshGhost

MeshGhost is an online multiplayer layer for single-player games. Everyone runs their own fully
independent copy of the game; friends show up as "ghosts" — live position, facing and animation —
while the worlds themselves stay separate. Nothing is shared unless a game's mod asks for it: by
default there are no synced items, enemies, health or progression, and desync is expected and
fine. If a friend kills a boss, it stays alive in your world, and that's okay.

That default is a choice rather than a ceiling. The protocol underneath also carries reliable,
ordered, addressed events between specific players, exclusive locks over opaque keys,
both-or-neither exchanges, and custody of a shared world the server holds but cannot read — built
and tested, off unless every member of a room opts in, and used by no shipped game today. They exist so a game's adapter *could* go further; none currently does,
and shipping one is a per-game decision nobody has taken.

**So where is the ceiling, concretely?** There are two different ceilings, and they are worth not
confusing.

**What this layer gives any game for free** tops out at **bounded, consensual interactions between
two specific players** — a trade, a battle turn, an emote: something with a clear beginning, two
willing participants, and an outcome both sides can be told about. Two things put it there. The
server never understands the game, so it can order actions and hand out exclusive claims (both are
just comparisons of opaque strings, and that really does settle "who picked this up first") but can
never judge *content* — "you did not really have that item" needs a server simulating the game, and
that also means there is no anti-cheat here: a lying client still lies. And arbitration costs a
round trip, because an adapter must ask before acting rather than announce afterwards, which is
unnoticeable in a trade menu and unusable in a fight.

**The server also answers "who is the host, and what happens when they leave?"** — which turns out
to be three jobs, and it holds two of them. It *designates* the authority, handing an opaque key to
one client and refusing the rest. And it holds *custody*: the latest opaque blob per entity, handed
as one canonical set to whoever takes that key next, so a host quitting does not take the world
with it and a player arriving late is shown the same world as everyone else. What it never does is
*simulate* — running the AI and resolving damage stays on a client, because that is the one job
that requires understanding the game.

**What a single game's adapter could reach is much higher, and it is not a permission problem.** A
mod can already spawn and drive real entities — that is exactly what a ghost is, a real player pawn
clone posed by its own game's systems. Take that to its conclusion and you get actual co-op: mod
the game so nothing dynamic is placed by the level at all, and the player, the enemies and the
pickups all arrive from the network instead, one client owning them and the rest displaying what
they are told. The two copies then never have to independently agree about anything, because only
one of them is deciding. None of it involves touching a save — spawning and driving things is
runtime state, the same as the ghost.

The relay does not change for any of that. It keeps forwarding opaque blobs and understanding
nothing — and since custody landed, it also keeps them, so "one client owning them" no longer means
"and the world dies with that client". What the work actually costs is all inside the game:

- **Switching off the game's own authority, comprehensively.** Every native spawn, trigger and AI
  tick for a peer-owned entity has to stop running locally, or both copies simulate and neither
  matches. This is the deep part, it is per-game, and it is all-or-nothing per entity type.
- **Volume.** Today one snapshot per *player*; this needs one per *entity*, which is a different
  scale of traffic even though the relay still cannot read any of it.
- **Latency, with nothing to hide it behind.** A remotely-owned enemy is always as old as the round
  trip. Real co-op games spend prediction and rollback on exactly that, which is a substantial
  project by itself.
- **Trust becomes total.** The owning client's word is final for everything it owns, so it is a
  model for playing with friends, not a security boundary.

(There is a second route — replay identical inputs on both sides, the way emulator netplay does —
but it needs the game to be deterministic, so it is plausible for an emulated game and not for a
modern engine that drifts on floats and update ordering.)

So the ceiling really is movable, per game, by whoever writes that adapter. What it stops being at
that point is a MeshGhost feature: it is a game-specific netcode project reusing this relay and
transport, which this repo records as architecturally separate rather than merely unscheduled. Full
reasoning, including which of the shipped games could and could not:
[agent_docs/beyond-cosmetic.md](agent_docs/beyond-cosmetic.md).

**Your save is never touched.** MeshGhost reads the game's memory and draws ghosts over the top;
it does not write game state and does not modify save files — not your own, and not the save of
anyone you play with. That is a rule the project holds itself to rather than a happy accident of
the current features, and it stays true of anything added later. Uninstalling is deleting the
mod's folder.

## Games

- **Pokémon Emerald** (GBA, via BizHawk) — game id `emerald`. Tested online with two real
  players. Animated, correctly-gendered Brendan/May ghosts with live position, facing, walking,
  and running.
- **TEVI** (Unity) — game id `tevi`. Adapter confirmed working (two clients / client +
  loopback), not yet tested online.
- **Pseudoregalia** (Unreal Engine 5) — game id `pseudoregalia`. Tested online with two real
  players on two machines.

**One server hosts every game at once, and there is nothing to set up for it.** A single
`meshghost-server.exe` carries an Emerald session, a TEVI session and a Pseudoregalia session
simultaneously on one port. Each game gets its own rooms automatically the moment someone from
that game connects, so everyone can leave `room` at its default and games never collide or mix —
players only ever see others in the same game and the same room name.

The game id is what an adapter announces itself as. You never set it yourself as a player — it is
picked up automatically from whichever game's mod you load. A host who deliberately wants their
server locked to a single game types one of those exact strings into `server.only_game` (see Setup
below); that is a restriction to opt into, not the normal setup.

TEVI isn't personally confirmed online yet, but it's expected to work — the relay and core
client are game-agnostic and don't know which game an adapter is for, so "works locally" and
"works online" are the same code path.

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
   below; the server prints exactly what to forward when it starts). Left as it ships, the server hosts
   any game, several at once, with each game kept to its own rooms automatically.
   `server.only_game` locks it to one game if you actually want that.
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

- Reads game memory, never writes it — see the save promise at the top of this page.
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

Full detail: [docs/networking.md](docs/networking.md) (how the relay and client
actually work — the life of a connection and of a state message, traced through the real code),
[agent_docs/contract.md](agent_docs/contract.md) (schema and interfaces),
[agent_docs/architecture.md](agent_docs/architecture.md) (system shape and design rationale), and
[docs/security.md](docs/security.md) (the relay/core's own networking-layer doc — security
posture, what's already checked-safe vs. the known open gaps).

## Repo layout

```text
MeshGhost/
├── cmd/                  # entry points: the desktop app, the standalone relay, and the test
│                         #   rig's fake adapter and network simulator
│
│                         # the library, importable from outside (see below):
├── core/                 # game-agnostic client: relay connection, buffering, interpolation
├── relay/                # game-agnostic server: rooms, forwarding, limits
├── protocol/             # the wire messages both speak
├── transport/            # NDJSON framing over any net.Conn
├── bridge/               # the adapter <-> local core messages
├── netx/                 # transport selection: tcp | udp | quic
│
├── internal/             # e2e tests only — deliberately not importable
├── adapters/             # one folder per game; _template/ is the starting point for a new one
├── docs/                 # for people using MeshGhost: integrating, security, networking
├── agent_docs/           # design brief, contract, architecture, roadmap, verified facts
├── dev-scripts/          # local test rig: launchers, load tests, adapter build scripts
├── packaging/            # what goes in the release zip, and how it's assembled
├── go.mod
└── README.md
```

## Using this from your own game

**Any language: run it beside your game.** `meshghost.exe` does all the networking as its own
process; your game connects a TCP socket to it on localhost and exchanges one JSON object per
line. There is no library to link and nothing of ours to compile — which is why the three
shipped adapters are written in three unrelated languages (Lua, C#, C++) and share no code.
Rust, Python, Godot, Java, anything with a socket works the same way.
[docs/integrating.md](docs/integrating.md) is the guide, including a conformance checklist and
a worked example.

**Go only: compile it in.** The packages above are importable:

```text
go get github.com/Tsukino-uwu/MeshGhost
```

**Nothing here is promised.** This is pre-1.0 and there is **no API stability guarantee** —
these packages may change shape in any release, we do not test third-party use, and we will not
know if we break you. Tags up to `v0.8.5` were cut under the old module name and cannot be
fetched at all. If you need something that cannot move under you, fork or vendor it; the licence
([MIT](LICENSE)) allows that outright and it is an honest answer rather than a fallback. None of
this affects adapters, which speak a socket rather than a Go API.

## Docs

- [agent_docs/README.md](agent_docs/README.md) — **full internal documentation index.** Start
  here if what you're looking for isn't in the shortlist below — it covers everything from
  system design to risk tracking to what's actually been confirmed running.
- [docs/integrating.md](docs/integrating.md) — **own your
  game's source and want this built in rather than shipped beside it?** How to reimplement the
  client, or embed the relay, without writing an adapter. Unsupported and untested, but it is all
  written down.
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
