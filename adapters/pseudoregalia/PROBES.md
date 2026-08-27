# Pseudoregalia probes

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

Every script here is a **development tool**, not part of the shipped adapter — the release ships
`main.dll` built from `MeshGhostPseudo/`, and nothing from these folders. They are kept because
they are the record of *how each fact was established*: the pawn/position/rotation discovery, the
auto-possess diagnosis, and the whole socket-capability answer in `agent_docs/phases/phase7.md`
were each settled by something in this list.

**Why this file is `PROBES.md` at the adapter root, and not `probes/README.md`.** UE4SS loads a
Lua mod from a fixed `<ModName>/Scripts/main.lua`, so each probe has to be its *own mod directory*
— there is no single `probes/` folder to index from the inside. Three directories, six scripts,
one index. Written 2026-08-25; before that the directories had no index at all, which
`_template/README.md` had mandated since it was written.

## Every probe here is READ-ONLY

None writes game memory and none writes a save. The two that touch anything outside the process
are the socket stages, and they only open a local TCP connection to our own bridge.

The one thing to be careful of is the opposite of a write: **`probe_ghost/Scripts/main.lua` is a
full working adapter**, not a diagnostic. Running it alongside the real C++ mod would put two
things on the bridge at once.

## `probe/` — where the player actually lives (Phase 7.1)

- **`Scripts/main.lua`** (92) — the first read-only discovery probe, before any C++ existed.
  Confirmed on screen where Pseudoregalia's local player pawn, position, rotation and level name
  are, so the real adapter could be written against measured facts instead of reflection guesses.

## `probe_ghost/` — the ghost, and why it kept stealing the player

- **`Scripts/diagnose.lua`** (151) — **the entry worth reading.** Written after three straight
  fix-and-retest cycles each failed to stop the player being dragged around by the ghost. Instead
  of guessing a fourth time it gathers evidence, and it found the cause: `BP_PlayerGoatMain_C`
  has Auto Possess Player set, so spawning a second instance hands the controller to it. This is
  the worked example behind `../CLAUDE.md`'s "two guessed fixes failing the same way is a signal".
- **`Scripts/main.lua`** (849) — Phase 7.5's **complete Lua adapter**: real local state every
  tick, a real bridge connection, the re-possess fix and the `SetViewTargetWithBlend` hook that
  fights the game's camera rig back to the player. Superseded by the C++ mod, kept because it is
  the last version where the whole adapter is readable in one file.

**Its camera fight-back is the one thing in here not to copy.** That file's header still describes
a `SetViewTargetWithBlend` hook forcing the view target back whenever a ghost spawn makes the game
re-target. The approach was deleted 2026-08-16 for blocking every legitimate camera change forever
after; what ships instead refuses only a switch to a rig whose `OwningActor` is a ghost, because
the ghost bringing its own camera rig was the actual cause. See `BANDAGES.md` and `VERIFIED.md`.
The file is history, and history includes the parts that were wrong.

## `probe_socket/` — can UE4SS's Lua reach a socket at all?

Three deliberately staged scripts, each only run after the previous one came back safe. UE4SS
always loads `Scripts/main.lua`, so **Stages 2 and 3 are run by copying them over `main.lua`**,
not by being wired in.

- **`Scripts/main.lua`** (26) — Stage 1, SAFE: does `package.loadlib` even exist and is it
  callable? Loads no DLL.
- **`Scripts/stage2_loadlib.lua`** (94) — Stage 2, riskier: actually load vendored LuaSocket into
  UE4SS's embedded Lua and *create* a TCP socket. Never connects.
- **`Scripts/stage3_roundtrip.lua`** (129) — Stage 3: a real bind/connect/send/receive round trip
  against the bridge protocol — the one thing Stage 2 deliberately left untested.

**The staging is the method, not caution theatre.** Each stage answers exactly one question and
stops, so a crash names its own cause. `agent_docs/verified.md` and `phase7.md` carry the answers.
