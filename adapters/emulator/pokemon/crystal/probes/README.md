# Crystal probes

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

Every script here is a **development tool**, not part of the shipped adapter — the release ships
`meshghost_crystal.lua` and nothing else from this folder. They are kept because they are the
record of *how each fact was established*: the addresses and the spawn recipe in
`agent_docs/phases/phase9.md` were all measured by something in this list, and several were
re-run against an Archipelago ROM to answer the same question a second time.

**Logs are not kept.** Each probe writes a timestamped `.log` beside itself (a verdict that lives
only in the Lua Console has to be copied back by hand), and `.gitignore` covers them. Once a run
has been read, its conclusion belongs in `VERIFIED.md`.

**How to run one**: point `dev-scripts/bizhawk-dev-loader.target` at it — the loader swaps scripts
live, with no emulator relaunch. See `agent_docs/environment.md`. Older probes here predate the
loader and run their own frame loop, so they still work opened directly in the Lua Console.

## Fifteen of these WRITE, and three hold the controller. Read this before running one.

Called out here rather than only in their own headers, because a folder index that hides a
memory-writing tool is the worst kind of gap — nobody reads a header they did not know existed.
**This section said "ten" and named nine until 2026-08-25, while eighteen scripts were missing
from the index entirely — five of them writers.** That is the gap in its purest form: the index
was reassuring and wrong at the same time.

**Object RAM only, never a save** — a reset or a map load rebuilds what they touched:
`spawn_test.lua` through `spawn_test7.lua`, `struct_diff_probe.lua`, `walk_test.lua`,
`orphan_sweep.lua`.

**Hardware sprite entries:** `oam_probe.lua` writes shadow OAM 36..39 and the `OAM` domain, only
on frames where the engine's own layout pass has declared them unused, and parks them back at
`y=160` — the engine's own "not in use" value — when it is done.

**Player state, deliberately** — these cheat on purpose, which `CLAUDE.md` permits for a
probe and never for an adapter: `goto_map.lua` warps the player (six writes, exactly what the
game's own `warp` command does; **it savestates to slot 8 first, always**, which is this
project's undo convention), `grant_test_kit.lua` writes badges/HMs into the party,
`grant_items.lua` writes the bag, `set_level.lua` writes a party Pokémon's level, experience and
stats, and `noclip.lua` redirects `wTilesetCollisionAddress` into a WRAM zero region.
**None writes the `.sav`** — but an in-game save afterwards makes their changes
permanent, so savestate first and reload after. `noclip_off.lua` restores the collision pointer.

**The three grant probes are kept SEPARATE on purpose** — badges/moves, bag, and levels — so that
what each one changed stays obvious when something later looks wrong.

**Three hold the d-pad**: `door_loop.lua`, `square_drive.lua`, and anything loaded with them.
Unload them before handing the game back — in a loopback session the ghost IS the local player
echoed, so a probe jittering the player jitters the ghost, and that reads as a rendering fault.
One left loaded on 2026-08-22 became a suspect for a ghost wiggle and cost a round of diagnosis.

Everything else in this folder is read-only — `object_slot_probe.lua` included, whose own header
says it deliberately performs no writes.

## Understanding the game

| Probe | What it answered |
| --- | --- |
| `domain_probe.lua` | Whether `System Bus` and `WRAM` reach the same bank-1 bytes. They do, and agree exactly. |
| `ingame_gate_probe.lua` | What "the player is actually in the game" means. Produced both gate corrections: `wMapEventStatus`/`wScriptRunning` flicker every step, and `wMapStatus` stays `HANDLE` through a battle. |
| `object_slot_probe.lua` | How many of the 13 object structs are free during real play, and what a map load does to them. |
| `step_watch_probe.lua` | What a real NPC's fields look like across one step — the read that overturned the movement plan before any code was written. |
| `struct_diff_probe.lua` | Our hand-built object against one the engine built, field by field. |
| `oam_probe.lua` | **Writes four OAM entries.** Whether a third rendering tier is possible between spawned and drawn: how many of the 40 hardware sprite entries the game uses, whether it clears the tail every frame (`_UpdateSprites`'s fill loop says it does), whether an entry written at the Lua frame boundary reaches the hardware at all, and what a text box and the START menu do to one. |
| `uiframe_probe.lua` | Read-only. Which screen rows a UI frame actually appears on, and whether "frame tiles are in the tilemap" means "a panel is on screen" — the two things that have to be measured before the drawn tier's row-12 text-box test can be generalised to the top-of-screen phone-call box. |

## Spawning, in the order it was worked out

Each one exists because the previous one failed in a specific way; `phase9.md` has the narrative.

| Probe | What it tried |
| --- | --- |
| `spawn_test.lua` | Copy the player's object struct into a free slot. A character rendered — but half-owned: collision followed the map coords, the sprite stayed put. |
| `spawn_test2.lua` | Write a *map object* and wait for adoption. Nothing happened for 600 frames — and the dump showed the game's own dolls sitting unadopted too. |
| `spawn_test3.lua` | Place it on the row the engine actually scans. **`*** ADOPTED ***`** — the engine assigned a real struct id. |
| `spawn_test4.lua` | Both halves written and cross-linked, beside the player. |
| `spawn_test5.lua` | Built from an NPC instead of from the player (the player's movement type means "driven by input"). |
| `spawn_test6.lua` | NPC template *plus* computed screen coordinates — copying them drew the ghost off-screen. |
| `spawn_test7.lua` | NPC behaviour wearing the player's face: the combination that shipped. |
| `walk_test.lua` | Making a spawned ghost walk using the game's own step mechanism. |

## Movement, pose and cadence

The 1:1 bar is judged on screen, so these measure what the engine DRAWS and how fast, not what
its structs say. `../CLAUDE.md`'s "never move a ghost in units the game does not use" came out
of this group.

| Probe | What it answered |
| --- | --- |
| `action_watch.lua` | Read-only. Whether the PLAYER's own object actually carries the `OBJECT_ACTION` values the decomp says drive fishing, bumping, spinning and emotes — reading the source is not watching it happen. |
| `action_probe.lua` | The generalisation of `bump_probe.lua`: every non-walking animation class in the engine's own terms, how long each facing holds in video frames, and how fast the engine's object clock actually ticks. The **cadence** a still frame cannot show. |
| `bump_probe.lua` | What a bump looks like in the struct AND in the tiles drawn — walking stays `STANDING`, action reads 3, facing alternates, and the drawn tile follows the facing byte. |
| `stride_probe.lua` | Read-only. What the engine draws across one step, per direction — measuring the drawn tier's two guesses (two mid-step arrangements per facing, an 8-frame `WALK_FRAME_HOLD`), neither of which had ever been seen running. Pair with `square_drive.lua` and it needs nobody. |
| `posediff_probe.lua` | Read-only. Which of lag / speed / phase / rounding is behind *"walking left/right feels a bit off... not 1:1"* — four causes needing four different fixes, so it measures instead of guessing. |
| `handover_probe.lua` | Read-only. How many frames a freshly promoted ghost takes to reach hardware OAM — i.e. whether the adapter's one-frame tier overlap is actually enough, or whether the peer is drawn by nobody for a frame. |
| `transition_probe.lua` | Read-only. What is true while a door transition is on screen, after the painted tier's three positive gates all let one through. Watches every candidate across a transition rather than reasoning about which ought to work. |

## Orphans — a character we left behind

| Probe | What it does |
| --- | --- |
| `orphan_probe.lua` | Read-only. Names whether a *"weird static ghost"* is ours, by the fingerprint no map-placed NPC carries: the local player's sprite id plus `FLAG1_WONT_DELETE`. |
| `orphan_sweep.lua` | **Writes.** Clears the objects `orphan_probe` identified — the same bytes the adapter clears on despawn. The adapter deliberately forgets an unverifiable ghost rather than zeroing a slot the game may have reused, which is why the cleanup is a separate opt-in tool. |

## Driving the game, so a person does not have to

`agent_docs/playing.md` allows driving a running game to reach a state. Every one of these costs
the user nothing, which is the point.

| Tool | What it does |
| --- | --- |
| `square_drive.lua` | **Holds the d-pad.** Walks a 3x3 square forever — the user's own test case for an intermittent fault that needs the same movement many times. |
| `door_loop.lua` | **Holds the d-pad.** In and out of a door forever, waiting between presses so each transition completes — how the painted tier's map-transition behaviour gets watched often enough to measure. |
| `goto_map.lua` | **Writes + savestates slot 8.** Warps the player to a named map, doing exactly what the game's own `warp` script command does, in the same order. |
| `goto_route39.lua` | One line of config pointing `goto_map` at Route 39 — the user's designated worst case (*"a big route, and fills up things due to having a lot of npc's"*). List it ABOVE `goto_map.lua` in the loader's control file. |
| `load_undo.lua` | Loads savestate slot 8 — the undo for a `goto_map` warp. One action, then quiet. |
| `noclip.lua` | **Writes.** Walk through anything, by redirecting `wTilesetCollisionAddress` into a WRAM zero region — *not* Emerald's approach, because Game Boy keeps the collision table in ROM, which this project never writes. |
| `noclip_off.lua` | **Writes.** Turns noclip off and proves it, restoring the pointer if an unclean unload left it redirected. |
| `grant_test_kit.lua` | **Writes.** Grants the badges, HMs and field moves a test session needs to reach water, ledges, dark caves and the sky without playing through the game. |
| `grant_items.lua` | **Writes the bag, and holds one byte every frame.** Super Rod (the drawn tier's fishing class cannot be watched without one), Master Balls, Max Repels, Rare Candies — all idempotent one-shot writes. **Permanent repel** is the exception and the only per-frame part: `wRepelEffect` is a STEP COUNTER the engine decrements, so "permanent" means topping it up, the same shape as Emerald's `testkit.lua`. It suppresses wild Pokémon **below your lead's level, not all of them** (`CheckRepelEffect`), so pair it with `set_level.lua` when encounters keep coming. The key-item pocket has no quantity byte where the other two do — cited from `ram/wram.asm`, because assuming otherwise corrupts the bag. |
| `set_level.lua` | **Writes a party Pokémon.** Level, experience AND the six stats, because writing the level byte alone leaves stale stats and stale EXP that the next battle uses to drop the level back. Base stats are read from the CARTRIDGE at run time, not from a table; the entry stride is re-verified against the dex numbers every run. |
| `compare_layout.lua` | Config only: the loopback ghost rendered TWICE from one state — spawned 2 tiles right, painted 2 tiles left — with the hardware tier explicitly OFF. Every switch is set explicitly, including the ones being turned off — the loader replaces files, never globals. |

## The drawn tier

| Probe | What it answered |
| --- | --- |
| `flags_facing_trace.lua` | Not a probe — sets `MESHGHOST_CRYSTAL_FACING_TRACE`, which makes the adapter log every frame its facing cache accepts. **The instrument that ended the 2026-08-22 facing bug** after four fixes reasoned from the code had each failed on screen. It measured the sprite's view layout, caught frames captured from another character's OAM entries, and then proved the fix by printing an invariant instead of a value. |
| `paintgate_probe.lua` | How many frames late the painted tier comes back after a map crossing, per direction, and what each candidate anchor for the hold WOULD have cost on the same crossing. Measured 5 frames going in and 2 coming out against a 30-frame hold, across 14 crossings with zero variance — because the hold is armed on the map id changing, which happens part-way through the crossing, so most of it is spent before the world is ready. |

## Archipelago address measurement

One probe per address, because a probe that measures several at once cannot say which one is
wrong. Results and what is still unmeasured: `phase9.md` and `VERIFIED.md`.

| Probe | Address it measured |
| --- | --- |
| `ap_address_probe.lua` | `wObjectStructs`, by differential scan |
| `ap_struct_check.lua` | fingerprints the `wObjectStructs` candidate before trusting it |
| `ap_coord_probe.lua` | the player's coordinates, by walking one direction |
| `ap_reverse_probe.lua` | the same coordinates **by reversal**, in one run — confirmation, not a repeat |
| `ap_mapid_probe.lua` | which byte pair is the *current* map rather than the previous one |
| `ap_mapobj_probe.lua` | `wMapObjects`, by matching it against `wObjectStructs` |
| `ap_state_probe.lua` | the map-identity and game-state addresses |
| `ap_scroll_probe.lua` | `wBGMapOffsetX` / `wBGMapOffsetY` |
| `ap_scroll_watch.lua` | watches the scroll-offset neighbourhood directly |
| `ap_battlemode_probe.lua` | `wBattleMode` — **settled 2026-08-19** by one trainer battle: `0x1234` read 2 for the whole fight and returned to 0; `0x015A` read 1 in both a wild and a trainer battle, which is what ruled it out |

## Not a probe

| File | What it is |
| --- | --- |
| `run_second_client.lua` | Four lines of configuration: points a second BizHawk at bridge port 7779, then loads the real adapter. Kept for convenience; **it no longer ships**, because the adapter now walks ports 7778-7785 by itself and a second copy finds its own core with no help. |
