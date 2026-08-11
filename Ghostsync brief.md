# GhostSync — project brief

(renamed to MeshGhost, after a lot of back/forth thinking to be something more unique)

Hand this file to Claude Code at the start of a session. It defines what is being

built, why, and the rules that govern how. Read it fully before proposing a plan.

\---

\## 1. What this is

A visual-only multiplayer layer for singleplayer games. Each player runs their own

completely independent copy of the game. The only thing crossing the network is

enough information to draw a cosmetic "ghost" of the other player: position,

area, and animation state.

Nothing about the game world is shared. Not enemies, not pickups, not doors, not

RNG. Remote players are non-interactive props with no collision, no damage, no AI.

The goal is to see friends moving around in the same space while playing. That's it.

\### Explicit non-goals

\- No shared or authoritative world state

\- No syncing of items, enemies, health, or progression

\- No attempt to keep worlds consistent between players

\- No rollback, prediction, or authority arbitration

Desync is expected and accepted. If a friend kills a boss it stays alive in your

world and their ghost will appear to fight nothing. This is fine. Do not propose

fixes for it.

\### Prior art worth reading

\- CelesteNet — closest reference implementation of this exact idea

MAKE SURE TO CHECK, READ AND RESPECT ANY AND ALL LICENSES, I DON*T WANT YOU TO JUST COPY THINGS WE ARE NOT ALLOWED TO USE FROM ANY OF THESE GITHUB LINKS, I DON*T WANT TO BREAK OR DISRESPECT ANY LICENSES, OR GET IN TROUBLE FOR NOT FOLLOWING LICENSES LATER ON, EVERYTHING WE DO SHOULD BE OUR OWN CODE AND NOT SOMETHING WE COPIED OR STOLE

<https://github.com/0x0ade/CelesteNet> (2024)
<https://github.com/EverestAPI/GhostMod> (2018, what CelesteNet is based on and replaced)

no clue if these 2 are useful for anything?
<https://github.com/EverestAPI/Everest> (Celeste mod loader/manager thing)

<https://github.com/MonoMod/MonoMod> (modding framework~, that Everest is built on i think? "C# modding swiss army knife, powered by cecil.")

<https://github.com/Extremelyd1/HKMP> ( Hollow Knight)
<https://github.com/nek5s/SilklessCoop> ( Silksong )

\- bizhawk-co-op (TestRunnerSRL) — BizHawk Lua socket plumbing, though it syncs

&#x20; state rather than drawing ghosts

\- Archipelago's `connector\_bizhawk\_generic.lua` — emulator/client bridge pattern

Ask for permission before doing/looking at anything outside of C:\dev\MeshGhost
"C:\ProgramData\Archipelago\Bizhawk\Lua" I guess this is the emulators own lua files?

these 2 folders are the lua things archipelago use i think?
"C:\ProgramData\Archipelago\SNI"
"C:\ProgramData\Archipelago\SNI\lua\Connector.lua", think this is the file i usually use/pick when i have to manually apply it ?

Note: the Ori randomizer's multiplayer is pickup/world-state sync, NOT ghost

rendering. It is not a reference for this project.

\---

\## 2. Architecture

Two halves, separated by a deliberately thin boundary.

```text
&#x20;       Relay server          <- game-agnostic, write once

&#x20;            |

&#x20;       Core client           <- game-agnostic, write once

&#x20;            |

&#x20;    \[ Adapter contract ]     <- the boundary; keep it thin

&#x20;       /    |    \\

&#x20;  Emerald  Unity  UE5        <- per-game, rewritten each time

```

The core is engine-ignorant. Adapters are game-specific. Portability lives in the

boundary, not in the code.

\### Reusability, realistically

The relay server, interpolation, and packet schema are \~100% reusable. Reading the

local player position, rendering a remote player, and mapping animation state are

\~0% reusable and account for most of the work per game. Expect the second game to

cost 60–70% of the first, the third around 50%. It never becomes plug-and-play.

\---

\## 3. The contract

\### Packet schema

| Field | Notes |

|---|---|

| `player\_id` | assigned by server |

| `seq` | monotonic, for ordering |

| `timestamp` | for interpolation |

| `area\_id` | \*\*opaque string\*\*. Map bank for Emerald, scene name for Unity. |

| `position` | \*\*variable-length float array\*\*. 2 for Emerald, 3 for 3D games. |

| `orientation` | optional; facing direction or quaternion |

| `anim` | \*\*opaque string\*\* tag |

| `extras` | small free-form dict for game-specific data |

`area\_id` and `anim` are opaque. The core compares them for equality and passes

them through. It must never branch on their contents.

Do not fix position at 2 or 3 components. Do not invent a universal animation

vocabulary — each adapter defines its own tag set, and tags are only ever compared

between two clients running the same game.

\### Adapter interface

```text

get\_local\_state()          -> snapshot | nil

render\_remote(id, state)   -> void

despawn\_remote(id)         -> void

```

Three functions. That is the entire surface.

\### Hard rules

\- Adapters never touch a socket.

\- The core never touches the game.

\- `if game == "emerald"` anywhere in the core means the abstraction has leaked.

\- Coordinate systems (Y-up vs Z-up, tile vs world units, pixel origins) are

&#x20; normalized \*\*inside the adapter\*\*, never in the core.

\- Transport is swappable: wrap it behind `send(bytes)` / `on\_receive(cb)` from

&#x20; day one. BizHawk uses a Lua socket; native games use an in-process client.

\- JSON until it hurts. Debuggability beats bandwidth at this scale.

\---

\## 4. Target games

\### Pokémon Emerald (GBA, via BizHawk) — FIRST

Chosen because reading is trivial: full `pokeemerald` C decompilation exists, so
<https://github.com/pret/pokeemerald> (decomp link)

player X/Y, map bank/number, and camera offset are documented, not reverse

engineered. Lua iterates in seconds.

Rendering is the hard part on GBA — there is no "spawn an actor". Three tiers:

1\. \*\*Lua overlay via `gui.drawImage`\*\* — USE THIS. Compute screen position from

&#x20;  map coords + camera scroll, draw over the emulator. Draws over menus and isn't

&#x20;  occluded by scenery, but it works and it's a weekend of effort.

2\. OAM injection — composites properly, much fiddlier (sprite slots, VRAM, timing)

3\. Decomp ROM hack — cleanest, heaviest

Tile-grid movement means small integer positions and 10Hz sync looks fine.

\### Ori and the Will of the Wisps (Unity) — SECOND

BepInEx/Harmony likely applies and the randomizer proves the game is moddable, but

nobody has solved "find the transform, render a second Ori". Verify whether the

build is IL2CPP or Mono before committing — it materially changes tooling.

Animation is skeletal and heavily blended (bash/dash/glide/wall-cling), which is

the worst case for clean animation tags.

\### Pseudoregalia (Unreal Engine 5) — LAST

Worst starting point, best destination. Small game, movement-focused 3D

platformer — the genre where ghost co-op shines. But: UE5, no source, no BepInEx.

Tooling is UE4SS (Lua + C++ hooks). Check the Pseudoregalia modding Discord first;

the Archipelago randomizer devs have likely already located the player object.

\---

\## 5. Build plan

Each phase has exactly one visible outcome. Do not start the next phase until the

current one has been watched working on screen.

\*\*Phase 0 — Contract on paper.\*\* Write the schema and interface. Create an empty

`agent_docs/verified.md`. No code.

\*\*Phase 1 — Emerald, read only.\*\* Print player X/Y/map to the BizHawk Lua console.

Walk around; confirm the numbers change correctly. Record addresses in

`agent_docs/verified.md` with their decomp source.

\*\*Phase 2 — Fake ghost, no network.\*\* Draw a sprite at a hardcoded offset from the

player. Proves the screen-position math (map coords + camera scroll) offline,

where it's far easier to debug.

\*\*Phase 3 — Loopback.\*\* Local relay server. One client sends its own state and

receives it back, rendering a ghost trailing itself by \~200ms. Exercises socket,

schema, and interpolation buffer with one machine.

\*\*Phase 4 — Two players.\*\* Second BizHawk instance, then a friend over the net.

Handle joins, drops, and `area\_id` mismatch (don't draw someone in another map).

First real milestone.

\*\*Phase 5 — Extract the template.\*\* Pull the core out of the Emerald code. Build a

fake adapter that moves a ghost in a circle and confirm the core runs against it

with no game attached. If it doesn't, something leaked. Freeze the stub as the

adapter template — this is the real deliverable.

\*\*Phase 6 — Second game.\*\* Same sequence. Phases 3–4 should be nearly free. This

is where you find out whether the contract was any good.

Rough sizing: phases 0–4 are a few evenings if things go well, a couple of

weekends if not. Phase 6 is genuinely unpredictable.

\---

\## 6. Working rules for Claude Code

\*\*Verification standard.\*\* "It ran without errors" is not evidence. A wrong memory

address returns a plausible number instead of crashing; a hook that never fires

logs nothing. The standard is: \*was the expected thing seen happening on screen in

a running game?\*

\*\*No addresses or APIs from memory.\*\* Every memory offset, API call, and hook must

be traceable to a specific file in a repo or a documentation page. If asked "where

did this come from?", there must be an answer. Anything that looks suspiciously

tidy should be treated as invented until confirmed.

\*\*`agent_docs/verified.md` is append-only and human-gated.\*\* Nothing is written to it until

the user has watched it work. It is the defence against a context reset

hallucinating a confirmed fact back incorrectly.

\*\*Small runnable steps.\*\* Every step must have a visible outcome. "Read player X"

is testable — print it, walk left, the number goes down. "Implement the network

layer" is not; split it into connect-and-heartbeat, echo-to-self, see-on-second-client.

\*\*Test against known-direction motion\*\*, not just plausible values. A printed

number proves nothing on its own; a number that decreases when you walk left

proves the address is right.

\*\*Log raw values, not just derived ones.\*\* When a ghost lands in the wrong place,

you need to know immediately whether the position, the camera offset, or the math

was wrong.

\*\*Don't build for games not yet attempted.\*\* The contract will need revision after

Emerald ships and again after the first 3D game. Design it now because it's cheap;

don't add a third adapter's speculative requirements.
