# Pseudoregalia probes

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

Every script here is a **development tool**, not part of the shipped adapter — the release ships
`main.dll` built from `MeshGhostPseudo/`, and nothing from these folders. They are kept because
they are the record of *how each fact was established*: the pawn/position/rotation discovery, the
auto-possess diagnosis, and the whole socket-capability answer in `agent_docs/phases/phase7.md`
were each settled by something in this list.

**Why this file is `PROBES.md` at the adapter root, and not `probes/README.md`.** UE4SS loads a
Lua mod from a fixed `<ModName>/Scripts/main.lua`, so each probe has to be its *own mod directory*
— there is no single `probes/` folder to index from the inside. Six directories, nine scripts,
one index. Written 2026-08-25; before that the directories had no index at all, which
`_template/README.md` had mandated since it was written. Three of the six arrived on 2026-08-29,
when `CLAUDE.md` made Lua-plus-hot-reload the default way to ask this game a question.

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

## `probe_nametag/` — which material renders coloured text (2026-08-29)

- **`Scripts/main.lua`** (747) — the first probe written to the Lua-and-hot-reload rule, and the
  reason that rule exists: twelve rounds of material candidates in one game session, where the
  same investigation had cost a relaunch per experiment in C++ the day before. Each round's
  screen verdict is kept in the file's own header, so the losing candidates are readable next to
  the winner. Ships nothing; the answer it found is in `VERIFIED.md`.
- **Leave it at `PROBE_ENABLED = false`.** It spawns a row of text actors, and one was still
  appearing during somebody else's test on 2026-08-29.

## `probe_reloader/` — the hot-reload loop itself

- **`Scripts/main.lua`** (65) — a resident watcher that calls `RestartMod` when a trigger file
  changes, so a probe restarts inside the running game with no keystroke and no window focus.
  Deliberately dumb and never edited during an iteration: a syntax error in the probe being
  iterated cannot take the reload loop down with it. `../CLAUDE.md` has the protocol.

## `probe_dustlight/` — the landing dust and the ascendant light (2026-08-29)

> **DISABLED — this probe CRASHED THE GAME TWICE during a live session, and must not be loaded
> again until its class list is cut down.** `EXCEPTION_ACCESS_VIOLATION` inside UE4SS's Lua
> machinery; localised to the `ChildActorComponent` pass, which walks every child actor in the
> world and calls a UFunction on each. Its `enabled.txt` is deliberately absent from the deployed
> copy. It DID deliver the light answer before dying — two output lines — which is exactly why the
> world-wide enumeration was never needed. Full account: `UNVERIFIED.md`,
> `../../agent_docs/pitfalls/by-lesson.md`.

- **`Scripts/main.lua`** — the two cosmetics the user watched and called wrong, both open in
  `UNVERIFIED.md` with nothing measured. One run answers both: a **light census** naming every
  light component and child actor on the player and on each ghost (attributed up BOTH the outer
  and the attach chain, because a light inside a ChildActorComponent is invisible to an outer
  walk alone), then a **landing timeline** putting every Niagara/Cascade component's first
  appearance on the same clock as every character's MovementMode transition.
- **The timeline is the point, not the catalogue.** The user's report is that the dust fires when
  the *player* lands rather than when the *ghost* does, which is a claim about when — so the run
  is built to catch a dust burst on an instance whose own character never left the ground.
