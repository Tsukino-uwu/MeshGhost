# GhostSync — project brief

(renamed to MeshGhost, after a lot of back/forth thinking to be something more unique)

Hand this file to Claude Code at the start of a session. It defines what is being built,
why, and the rules that govern how. Read it fully before proposing a plan.

The implemented, precise version of section 3 below now lives in `agent_docs/contract.md` —
that file is the one to follow for schema/interface details; this section is kept for the
original reasoning and is not the current source of truth for exact field behavior.

---

## 1. What this is

A visual-only multiplayer layer for singleplayer games. Each player runs their own
completely independent copy of the game. The only thing crossing the network is enough
information to draw a cosmetic "ghost" of the other player: position, area, and animation
state.

Nothing about the game world is shared. Not enemies, not pickups, not doors, not RNG. Remote
players are non-interactive props with no collision, no damage, no AI. The goal is to see
friends moving around in the same space while playing. That's it.

> Since superseded on one point: ghost collision became an opt-in per-adapter feature
> 2026-08-15, on the user's own request — see `plans.md`. Everything else here still holds.

### Explicit non-goals

- No shared or authoritative world state
- No syncing of items, enemies, health, or progression
- No attempt to keep worlds consistent between players
- No rollback, prediction, or authority arbitration

Desync is expected and accepted. If a friend kills a boss it stays alive in your world and
their ghost will appear to fight nothing. This is fine. Do not propose fixes for it.

### Prior art worth reading

MAKE SURE TO CHECK, READ AND RESPECT ANY AND ALL LICENSES. Don't just copy things we are not
allowed to use from any of these GitHub links. Don't break or disrespect any licenses, or get
in trouble for not following licenses later on — everything we do should be our own code and
not something we copied or stole. See `agent_docs/licensing.md` for the audit this produced.

- [CelesteNet](https://github.com/0x0ade/CelesteNet) (2024) — closest reference
  implementation of this exact idea.
- [GhostMod](https://github.com/EverestAPI/GhostMod) (2018) — what CelesteNet is based on
  and replaced.
- [Everest](https://github.com/EverestAPI/Everest) — Celeste mod loader/manager. Usefulness
  to this project unconfirmed.
- [MonoMod](https://github.com/MonoMod/MonoMod) — modding framework Everest is built on;
  "C# modding swiss army knife, powered by cecil."
- [HKMP](https://github.com/Extremelyd1/HKMP) (Hollow Knight)
- [SilklessCoop](https://github.com/nek5s/SilklessCoop) (Silksong) — restrictively licensed,
  see `agent_docs/licensing.md` before treating this as anything but a read-only reference.
- bizhawk-co-op (`TestRunnerSRL`) — BizHawk Lua socket plumbing, though it syncs state
  rather than drawing ghosts.
- Archipelago's `connector_bizhawk_generic.lua` — emulator/client bridge pattern.

Ask for permission before doing/looking at anything outside of `C:\dev\MeshGhost`.
`C:\ProgramData\Archipelago\Bizhawk\Lua` is believed to be the emulator's own Lua files.
`C:\ProgramData\Archipelago\SNI` and `C:\ProgramData\Archipelago\SNI\lua\Connector.lua` are
believed to be the Lua connector normally applied manually for Archipelago — unconfirmed,
treat as a lead to verify rather than a fact, per the no-memory rule.

Note: the Ori randomizer's multiplayer is pickup/world-state sync, NOT ghost rendering. It is
not a reference for this project.

---

## 2. Architecture

Two halves, separated by a deliberately thin boundary.

```text
        Relay server          <- game-agnostic, write once
             |
        Core client           <- game-agnostic, write once
             |
     [ Adapter contract ]     <- the boundary; keep it thin
        /    |    \
   Emerald  Unity  UE5        <- per-game, rewritten each time
```

The core is engine-ignorant. Adapters are game-specific. Portability lives in the boundary,
not in the code.

### Reusability, realistically

The relay server, interpolation, and packet schema are ~100% reusable. Reading the local
player position, rendering a remote player, and mapping animation state are ~0% reusable and
account for most of the work per game. Expect the second game to cost 60–70% of the first,
the third around 50%. It never becomes plug-and-play.

---

## 3. The contract

Original design intent — for the implemented, precise contract (message types, tick model,
transport framing, limits) see `agent_docs/contract.md`.

### Packet schema

| Field | Notes |
| --- | --- |
| `player_id` | assigned by server |
| `seq` | monotonic, for ordering |
| `timestamp` | for interpolation |
| `area_id` | **opaque string**. Map bank for Emerald, scene name for Unity. |
| `position` | **variable-length float array**. 2 for Emerald, 3 for 3D games. |
| `orientation` | optional; facing direction or quaternion |
| `anim` | **opaque string** tag |
| `extras` | small free-form dict for game-specific data |

`area_id` and `anim` are opaque. The core compares them for equality and passes them
through. It must never branch on their contents.

Do not fix position at 2 or 3 components. Do not invent a universal animation vocabulary —
each adapter defines its own tag set, and tags are only ever compared between two clients
running the same game.

### Adapter interface

```text
get_local_state()          -> snapshot | nil
render_remote(id, state)   -> void
despawn_remote(id)         -> void
```

Three functions. That is the entire surface.

### Hard rules

- Adapters never touch a socket.
- The core never touches the game.
- `if game == "emerald"` anywhere in the core means the abstraction has leaked.
- Coordinate systems (Y-up vs Z-up, tile vs world units, pixel origins) are normalized
  **inside the adapter**, never in the core.
- Transport is swappable: wrap it behind `send(bytes)` / `on_receive(cb)` from day one.
  BizHawk uses a Lua socket; native games use an in-process client.
- JSON until it hurts. Debuggability beats bandwidth at this scale.

---

## 4. Target games

### Pokémon Emerald (GBA, via BizHawk) — FIRST

Chosen because reading is trivial: full `pokeemerald` C decompilation exists
([decomp link](https://github.com/pret/pokeemerald)), so player X/Y, map bank/number, and
camera offset are documented, not reverse engineered. Lua iterates in seconds.

Rendering is the hard part on GBA — there is no "spawn an actor". Three tiers:

1. **Lua overlay via `gui.drawImage`** — USE THIS. Compute screen position from map coords +
   camera scroll, draw over the emulator. Draws over menus and isn't occluded by scenery,
   but it works and it's a weekend of effort.
2. OAM injection — composites properly, much fiddlier (sprite slots, VRAM, timing)
3. Decomp ROM hack — cleanest, heaviest

Tile-grid movement means small integer positions and 10Hz sync looks fine.

### Second game — TEVI (superseding Ori: Will of the Wisps)

Original brief text named *Ori and the Will of the Wisps* here. As of 2026-08-11 the second
slot is **TEVI** instead — see `agent_docs/architecture.md`'s decision log for why. Original
Ori reasoning, kept for reference in case Ori is picked up again later:

> BepInEx/Harmony likely applies and the randomizer proves the game is moddable, but nobody
> has solved "find the transform, render a second Ori". Verify whether the build is IL2CPP
> or Mono before committing — it materially changes tooling. Animation is skeletal and
> heavily blended (bash/dash/glide/wall-cling), which is the worst case for clean animation
> tags.

TEVI's own IL2CPP/Mono status is equally unverified — confirm at Phase 6, not from memory.

> **Resolved 2026-08-11: confirmed Mono**, not IL2CPP (`Assembly-CSharp.dll` present, no
> `GameAssembly.dll`, `doorstop_config.ini` has `[UnityMono]`). See
> `agent_docs/phases/phase6.md` and `adapters/tevi/README.md`.

### Pseudoregalia (Unreal Engine 5) — LAST

Worst starting point, best destination. Small game, movement-focused 3D platformer — the
genre where ghost co-op shines. But: UE5, no source, no BepInEx. Tooling is UE4SS (Lua + C++
hooks). Check the Pseudoregalia modding Discord first; the Archipelago randomizer devs have
likely already located the player object.

---

## 5. Build plan

Each phase has exactly one visible outcome. Do not start the next phase until the current
one has been watched working on screen.

**Phase 0 — Contract on paper.** Write the schema and interface. Create an empty
`agent_docs/verified.md`. No code.

**Phase 1 — Emerald, read only.** Print player X/Y/map to the BizHawk Lua console. Walk
around; confirm the numbers change correctly. Record addresses in `agent_docs/verified.md`
with their decomp source.

**Phase 2 — Fake ghost, no network.** Draw a sprite at a hardcoded offset from the player.
Proves the screen-position math (map coords + camera scroll) offline, where it's far easier
to debug.

**Phase 3 — Loopback.** Local relay server. One client sends its own state and receives it
back, rendering a ghost trailing itself by ~200ms. Exercises socket, schema, and
interpolation buffer with one machine.

**Phase 4 — Two players.** Second BizHawk instance, then a friend over the net. Handle
joins, drops, and `area_id` mismatch (don't draw someone in another map). First real
milestone.

**Phase 5 — Extract the template.** Pull the core out of the Emerald code. Build a fake
adapter that moves a ghost in a circle and confirm the core runs against it with no game
attached. If it doesn't, something leaked. Freeze the stub as the adapter template — this is
the real deliverable.

**Phase 6 — Second game.** Same sequence. Phases 3–4 should be nearly free. This is where
you find out whether the contract was any good.

Rough sizing: phases 0–4 are a few evenings if things go well, a couple of weekends if not.
Phase 6 is genuinely unpredictable.

---

## 6. Working rules for Claude Code

These now also live in `CLAUDE.md` so they're loaded automatically every session; kept here
for the original phrasing and context.

**Verification standard.** "It ran without errors" is not evidence. A wrong memory address
returns a plausible number instead of crashing; a hook that never fires logs nothing. The
standard is: *was the expected thing seen happening on screen in a running game?*

**No addresses or APIs from memory.** Every memory offset, API call, and hook must be
traceable to a specific file in a repo or a documentation page. If asked "where did this
come from?", there must be an answer. Anything that looks suspiciously tidy should be
treated as invented until confirmed.

**`agent_docs/verified.md` is append-only and human-gated.** Nothing is written to it until
the user has watched it work. It is the defence against a context reset hallucinating a
confirmed fact back incorrectly.

**Small runnable steps.** Every step must have a visible outcome. "Read player X" is
testable — print it, walk left, the number goes down. "Implement the network layer" is not;
split it into connect-and-heartbeat, echo-to-self, see-on-second-client.

**Test against known-direction motion**, not just plausible values. A printed number proves
nothing on its own; a number that decreases when you walk left proves the address is right.

**Log raw values, not just derived ones.** When a ghost lands in the wrong place, you need
to know immediately whether the position, the camera offset, or the math was wrong.

**Don't build for games not yet attempted.** The contract will need revision after Emerald
ships and again after the first 3D game. Design it now because it's cheap; don't add a
third adapter's speculative requirements.
