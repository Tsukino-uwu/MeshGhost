# Orientation — the whole project in plain words

**Who this is for**: the maintainer coming back after a long break, unsure where anything is or
how any of it was done. Read it top to bottom once; every section ends with where to go deeper.
Nothing here is a rule (those are [../CLAUDE.md](../CLAUDE.md)) or a fact record (those are
[verified.md](verified.md) and each game's own `VERIFIED.md`). **If this file and a linked file
disagree, the linked file wins**, and this one gets fixed. Written 2026-09-16.

## 1. What MeshGhost is

Other players appear in your singleplayer game as ghosts. Everyone runs their own copy of the
game and their own save; nothing about the game is shared except where each player is and what
they are doing, and the only thing that does with it is draw a ghost. It is free and MIT-licensed,
and the same client and server work for every game because they know nothing about any of them.
Each game gets a small mod, called an adapter here, that reads your own character and shows
everyone else's.

Go deeper: [brief.md](brief.md) is the original vision, frozen on purpose;
[../README.md](../README.md) is what a player sees first; [plans.md](plans.md) is the roadmap
and the non-goals.

## 2. The three moving parts, and how a ghost travels

```text
 your game ──adapter──▶ bridge ──▶ core (meshghost.exe) ──▶ relay (meshghost-server.exe)
                                                                  │
 their game ◀──adapter◀── bridge ◀── their core ◀─────────────────┘
```

- **The adapter** lives inside the game (a Lua script in the emulator, a C# plugin, a C++ mod).
  Every frame or so it reads where the player is, which area they are in and what animation they
  are playing, and hands that to the core. When the core hands back other players, the adapter
  draws them. An adapter talks to nothing but its own local core.
- **The bridge** is that local link: newline-delimited JSON over a TCP socket on this machine
  only. The message names are in `bridge/bridge.go`; the ones every adapter uses are `hello`,
  `bridge_ready`, `local_state`, `render_remote` and `despawn_remote`. The adapter always calls
  the core, never the reverse, so every adapter has the same shape.
- **The core** is `meshghost.exe`, one per player. It takes the adapter's samples, rate-limits
  them, sends them to the relay, receives everyone else's, smooths them between samples
  (interpolation, the `interp` you see in the dev scripts) and hands the adapter something to
  draw. It reads `config.json` for the server address, room, player name and colour, and reloads
  that file when it is saved.
- **The relay** is `meshghost-server.exe`, one per group of friends (built locally as
  `meshghost-relay.exe`, same program, renamed on release). It holds rooms, forwards each
  player's state to the others in the same room, enforces limits, and knows nothing about games.
  It speaks TCP, UDP or QUIC, always under TLS since 2026-09-15, with a room code as the shared
  secret.

Two ideas make this cheap. **Rooms** are just a name in the config; a room code, if the host
sets one, gates entry. **Area filtering**: each sample carries an `area_id` that the core and
relay compare only for equality, so a ghost is only handed to a player whose adapter reports
the same area. Deeper planes (events, leases, shared world state) exist in the protocol, are
opt-in, and no adapter uses them.

Go deeper: [contract.md](contract.md) is the exact packet and message schema;
[architecture.md](architecture.md) is the shape, the package rules and the index of every
decision; [../docs/networking.md](../docs/networking.md) traces the real code.

## 3. Where everything lives

The repo root, one line each:

- `core/`, `relay/`, `protocol/`, `transport/`, `bridge/`, `netx/` — the Go library packages,
  public and importable. `protocol` is the wire shapes, `transport` the framing, `bridge` the
  adapter side, `netx` the tcp/udp/quic listeners and the TLS story, `core` and `relay` the two
  programs' logic.
- `cmd/` — the four executables: `meshghost` (core), `meshghost-relay`, `meshghost-fakeadapter`
  (a pretend game for tests) and `meshghost-netsim` (a bad-network simulator the rig runs by
  default).
- `internal/` — helpers that are ours alone, plus `internal/e2e`, which launches the real
  binaries and drives a fake adapter through them in `go test`.
- `adapters/` — one folder per game, plus `_template/`, the gold standard every adapter is held
  to. Emulator games sit under `adapters/emulator/pokemon/`.
- `packaging/` — the hand-written half of a release: the shipped `config.json`, the player
  `README.txt`s, and the two committed mod DLLs that CI cannot build.
- `dev-scripts/` — every launcher, probe, hot-reload script, `preflight.ps1` and `release.ps1`.
  `dev-scripts/README.md` describes each one.
- `dev-logs/` — where every log from the scripts and the probes goes. Tracked empty on purpose.
- `docs/` — for players, hosts, reviewers and integrators. `docs/README.md` indexes it.
- `agent_docs/` — for us: the contract, the guides, the records, this file.
  [README.md](README.md) indexes it.
- `.github/workflows/` — CI, the gates and the release pipeline; `.githooks/` — the pre-commit
  hook that refuses a machine-specific path.
- `replay/`, `private/` — runtime folders the core writes (replay recordings; the relay's TLS
  identity). `private/` is untracked.
- The root `meshghost*.exe` files are your local dev builds, refreshed with `go build -o`, and
  `config.json` at the root is the one they read.

Go deeper: [architecture.md](architecture.md), "Package boundaries", for who may import whom.

## 4. Which document answers which question

| I want to know… | Read |
| --- | --- |
| The rules I work under | [../CLAUDE.md](../CLAUDE.md), plus `adapters/CLAUDE.md` and each host's own |
| What is open right now | [status.md](status.md) — two lines per item, each dated ([claude-md-cap.md](claude-md-cap.md) is why) |
| What is proven, and by whom | [verified.md](verified.md) for the Go side; each game's `VERIFIED.md` |
| What is built but nobody has watched | each game's `UNVERIFIED.md`; [unverified.md](unverified.md) indexes them |
| What we intend, and what we will not do | [plans.md](plans.md), [ideas.md](ideas.md) |
| Why a decision was made | `adr/`, one dated file per decision, indexed in [architecture.md](architecture.md) |
| What went wrong before, and the check that stops it | [checklists/](checklists/) — one page per moment; [pitfalls/INDEX.md](pitfalls/INDEX.md) |
| What happened, session by session | [phases/](phases/README.md) — one running log per game and per component |
| How a game's adapter got built | that adapter's `README.md`, one numbered step per capability (the rule is in [../CLAUDE.md](../CLAUDE.md)) |
| How the game itself works | that adapter's `documentation.md` |
| What a game sends and how it is checked on arrival | that adapter's `SYNCED.md` |
| The machine and its tools | [dependencies.md](dependencies.md) to install; [environment.md](environment.md) for versions and traps |
| How a live test is run | [running-the-rig.md](running-the-rig.md); the `/play-game` skill to drive the game yourself ([playing-rationale.md](playing-rationale.md) for why) |

Two habits explain why these files look the way they do. **Indexes are one line per entry**
(`status.md`, the `VERIFIED.md` indexes, the checklists, the `agent_docs/README.md` list), so
the detail always lives one link away and preflight fails a second line. **Records are
append-only** (`VERIFIED.md`, the phase files, the ADRs): a dated entry is true as of its date
and is never rewritten, so a stale-looking sentence in one is history, not an error.

Go deeper: [README.md](README.md) is the full index, grouped by kind; [claude-md-cap.md](claude-md-cap.md)
is why the rule files are capped and the records are not.

## 5. The games, as of 2026-09-16

- **Pokémon Emerald** (GBA, BizHawk, Lua) — `adapters/emulator/pokemon/emerald/`. A Lua script
  reads fixed memory addresses, with the `pokeemerald` decompilation as the map of where to
  look and our own probes as the proof. Since 2026-09-11 the shipped tier is drawn only, the
  same call as Crystal: every peer is painted over the emulator's output, reading the peer's own
  sprite from the cartridge, which is what lets a vanilla player see an Archipelago player of the
  other gender. Spawning a real in-game object and writing hardware sprites both remain as dev
  opt-ins (the spawn cap defaults to zero, the OAM tier to off). Runs on vanilla, Archipelago and
  two speedchoice builds. Log: [phases/phase8.md](phases/phase8.md).
- **Pokémon Crystal** (GBC, BizHawk, Lua) — `adapters/emulator/pokemon/crystal/`. Same host,
  same answer, reached first: since 2026-09-02 the shipped tier is drawn only, painted over the
  emulator's output in step with the game's camera, after the spawned object was seen snapping
  at a map seam. Spawned and hardware tiers remain as dev opt-ins. One address table per ROM build,
  chosen at startup from the header. Log: [phases/phase9.md](phases/phase9.md).
- **TEVI** (Unity, Mono, C#) — `adapters/tevi/`. A BepInEx plugin. The game's own
  `Assembly-CSharp.dll` is managed code, so its class and field names were read with ILSpy and
  the plugin compiles against them: a wrong name is a build error. The ghost is a clone of the
  player's own character object, so the game's animator and sprite handling do the work. Built
  locally with `dev-scripts/build-tevi.bat`; the DLL is committed. Log: [phases/phase6.md](phases/phase6.md).
- **Pseudoregalia** (Unreal Engine 5, C++) — `adapters/pseudoregalia/`. A UE4SS C++ mod. No
  source exists anywhere, so every class, property and function is a name string resolved at
  runtime, and a wrong one returns nothing or something plausible: the hardest adapter by far,
  and where most of the project's tooling and lessons came from. The ghost is spawned from the
  player's own class. Built locally with `dev-scripts/build-pseudoregalia.bat`; the DLL and the
  UE4SS runtime it loads under are committed. Log: [phases/phase7.md](phases/phase7.md).

Each adapter's `README.md` is the story of how it got there, step by numbered step, and is the
best worked example of the method below. The fifth game, when it comes, takes phase 13.

Go deeper: [access-models.md](access-models.md) is why these four were easy or hard in the order
they were.

## 6. How an adapter is made, from nothing to a ghost on screen

This is the part most easily forgotten, because each adapter was a rewrite. The ladder is the
same every time.

1. **Ask what you will be able to READ about the game.** That predicts the difficulty better
   than the engine does. An emulator exposes memory and a decompilation may map it; a Mono game
   documents itself through its managed assembly; an Unreal shipping build gives you runtime
   reflection and nothing else. [access-models.md](access-models.md), then
   [candidate-games.md](candidate-games.md) and [game-shapes.md](game-shapes.md) if the game is
   not one avatar in one world.
2. **Read licences before source, and borrow nothing.** A decompilation, wiki or other mod is
   where to look; only our own measurement makes a claim a fact, and only that goes in the repo.
   [licensing.md](licensing.md) lists what has been cleared and how a citation is gated.
3. **Start from the template.** `/new-adapter` sequences the reading. Every adapter carries the
   same file set from day one: `README.md`, `documentation.md`, `BANDAGES.md`, `FLAGS.md`,
   `SYNCED.md`, `VERIFIED.md`, `UNVERIFIED.md` and a probes index. Preflight checks the set.
   Ask the user for the phase number and create `phases/phaseN.md` before the first file.
   [../adapters/_template/README.md](../adapters/_template/README.md), read end to end.
4. **Build the hot-reload loop before the first feature.** Every host has one; without it every
   change costs a game launch. [live-reload.md](live-reload.md) has the three answers side by side.
5. **Learn how the game does it, before you do anything yourself.** This is the mindset the
   rest of the ladder depends on: **if the game can do something, so can we, by asking the game
   to do it.** Before looking for a single address, answer two questions about the game itself.
   *How does the game spawn a player, or any character?* The player is spawned by some path the
   game already ships (an object event, a prefab, a pawn class), and a ghost made by that same
   path inherits animation, collision, layering and occlusion for nothing. *How does the game do
   the thing you are about to mirror?* Walking, a hop, a splash, a trail, a facing change: each
   is a mechanism with a normal trigger, and firing that trigger is the whole job. Reimplementing
   it from outside is the last resort, and the template lists what it costs. Write what you
   learn in the adapter's `documentation.md` as you go, in your own words and never the game's
   text. The template's "Where does this already happen normally?", "Ask the game what it has,
   before you guess at what it might have" and "Hard rule: find out how the GAME does it before
   you work around it" sections are the method, with the player-capability parity rule beside
   them: anything the player can do, a ghost must too, and "impossible" only means the
   mechanism is not found yet.
6. **Find the player.** Position, area, facing, animation. A probe asks the running game,
   the reading is watched on screen, and only then is it written down. Emerald's first addresses,
   confirmed by walking, are the worked example: [phases/phase1.md](phases/phase1.md).
7. **Send it.** The adapter opens a localhost socket to the core, says `hello`, waits for
   `bridge_ready`, then streams `local_state`. Nothing about the relay ever reaches the adapter.
   [contract.md](contract.md) is the adapter interface.
8. **Show a ghost, and let the game do the work.** Use what step 5 found: ask the game to make
   one with a class it already ships (a spawned object, a cloned character, a pawn), so
   animation, layering and occlusion come free; paint over the frame only above what the game
   can hold, or where painting was the deliberate call. In local testing two rendered characters
   never share a tile, and the loopback ghost sits to one side so you can judge it against the
   player. The template's "Did the game make this, or did you take it?" section is the decision
   table.
9. **The bar is 1:1, and the user is the judge.** A ghost looks exactly like the player doing
   the same thing, judged on screen, never by matching numbers. "Ran without errors" is not
   evidence for an adapter, because a wrong address returns a plausible number. A confirmed
   fact goes to `VERIFIED.md` and the phase file; the README gains a numbered step when a
   capability lands, never per fix.

Go deeper: the four shipped READMEs, in the order they were built (Emerald, TEVI,
Pseudoregalia, Crystal); [effect-investigation.md](effect-investigation.md) for mirroring a
visual effect; [beyond-cosmetic.md](beyond-cosmetic.md) before anything past a cosmetic ghost.

## 7. How to mod and probe a running game

The instrument side of the same work.

- **A probe** is a small script that asks the running game one question and writes the answer
  to `dev-logs/`. It is off by default, its cost is audited before its reading is trusted, and a
  reading is never believed alone: a diagnostic can break the thing it measures.
  `/write-a-probe` sequences the method; [../adapters/_template/probes.md](../adapters/_template/probes.md)
  is how to build one; [checklists/before-a-probe.md](checklists/before-a-probe.md) and
  [checklists/before-trusting-a-reading.md](checklists/before-trusting-a-reading.md) are the
  two pages to open first. Each game's `PROBES.md` indexes the ones already written.
- **Getting code into the running game**, per host:
  - BizHawk: the Lua Console, and `dev-scripts/hot-reload-lua.ps1` with the dev loader in
    `dev-scripts/bizhawk-dev-loader.lua`, which attaches, swaps and drops scripts without
    touching the emulator.
  - TEVI: ScriptEngine reloads a plugin DLL dropped into `BepInEx\scripts\`;
    `dev-scripts/tevi-hotreload.ps1` builds, deploys and arms the watcher. UnityExplorer
    browses the live scene; dnSpyEx and `ilspycmd` read the game's own code.
  - Pseudoregalia: UE4SS Lua mods reload live (a reloader mod off a trigger file, since a
    keybind needs game focus), so iteration happens in a Lua probe; the C++ mod itself needs
    `build-pseudoregalia.bat` and a relaunch. `dev-scripts/pseudo-hotreload.ps1` and UE4SS's
    Live Viewer are the tools.
- **Dev toggles.** Each adapter's `FLAGS.md` lists the toggle files and variables the built mod
  reads, so behaviour changes without a rebuild. Prefer a toggle to a rebuild, and a rebuild to
  a manual restart.
- **Driving the game yourself.** Savestates (slot 1 is the user's, the rest are yours), scripted
  input, screenshots and cheats reach and hold a state before anyone is asked to look.
  The `/play-game` skill is what may be changed and how; [running-the-rig.md](running-the-rig.md)
  is the scaffolding around it: relay, core and netsim started hidden, two games at once,
  several agents, crash dumps.
- **Where the answer goes.** A measurement of yours goes to that game's `UNVERIFIED.md` as
  something for the user to watch. What the user confirms on screen goes to `VERIFIED.md`. A
  wrong theory and how it was caught goes to `pitfalls/` and, if it earns a check, to a page in
  `checklists/`.

## 8. How a day of work goes

Read [status.md](status.md), then `gh run list -L 5` if recent commits touched `.go` files: CI
runs the race detector and the fuzzers that a local run cannot. Make the change. For the Go
side, `dev-scripts/run-gotests.bat` green means done, with `run-gotests-race.bat` when
concurrency moved and a regression test that fails without the fix. For a game, bring up the
rig ([running-the-rig.md](running-the-rig.md)), hot-reload the change, watch, and ask the user
for one confirmation of the finished result rather than one per step. Record it where it goes
(section 7). Commit straight to `master`; never push unless told to in that message. Run
`dev-scripts/preflight.ps1` before handing the user a game to test. Before the session ends,
append a dated entry to the live phase file.

Go deeper: [testing.md](testing.md), [phases/README.md](phases/README.md).

## 9. How a release happens

`dev-scripts/release.ps1` is the only way: it runs preflight, rebuilds any mod DLL preflight
calls stale, waits for CI on the commit, and only then dispatches `.github/workflows/release.yml`.
The workflow builds the Go binaries for every OS, renames the relay to `meshghost-server.exe`,
runs `dev-scripts/stage-release.ps1` to assemble `packaging/release/` (the Lua adapters copied
in, a `config.json` beside each game), zips it as the Windows asset, and adds Linux and macOS
tarballs. The two committed DLLs each carry a `built-from.txt`; the release refuses to cut if
either is older than its sources. Signing is an external service and its status is a dated fact.

Go deeper: [../packaging/README.md](../packaging/README.md), [phases/phase12.md](phases/phase12.md),
[../docs/code-signing.md](../docs/code-signing.md).

## 10. The things that bite

- **Anything on `PATH` may be the wrong install.** `gcc`, `cmake`, `git` and even `cmd` have
  resolved to an MSYS2 copy here; scripts call absolute paths, and a `.bat` runs through
  `$env:ComSpec`. [pitfalls/INDEX.md](pitfalls/INDEX.md).
- **A VPN fails the UDP tests** with an address error that reads like a code bug.
  [environment.md](environment.md), Onboarding.
- **The root `meshghost*.exe` do not refresh on `go build ./...`**; build them with `-o` before
  any `.bat` launcher, or you test a stale binary. Preflight checks this.
- **A clean instrument plus a symptom the user still sees means widen the search**, not deepen
  the measurement. [checklists/before-trusting-a-reading.md](checklists/before-trusting-a-reading.md).
- **After about three failed live iterations, stop and table what was tried**, then test the
  untried combination; each cycle costs a game launch.

## 11. On a new machine

[dependencies.md](dependencies.md) says what to install, by tier. [environment.md](environment.md)
says which versions were confirmed and what each tool did wrong the first time.
