# Crystal probes

Every script here is a **development tool**, not part of the shipped adapter — the release ships
`meshghost_crystal.lua` and nothing else from this folder. They are kept because they are the
record of *how each fact was established*: the addresses and the spawn recipe in
`agent_docs/phases/phase9.md` were all measured by something in this list, and several were
re-run against an Archipelago ROM to answer the same question a second time.

**Logs are not kept.** Each probe writes a timestamped `.log` beside itself (a verdict that lives
only in the Lua Console has to be copied back by hand), and `.gitignore` covers them. Once a run
has been read, its conclusion belongs in `agent_docs/verified.md`.

**How to run one**: point `dev-scripts/bizhawk-dev-loader.target` at it — the loader swaps scripts
live, with no emulator relaunch. See `agent_docs/environment.md`. Older probes here predate the
loader and run their own frame loop, so they still work opened directly in the Lua Console.

## Understanding the game

| Probe | What it answered |
| --- | --- |
| `domain_probe.lua` | Whether `System Bus` and `WRAM` reach the same bank-1 bytes. They do, and agree exactly. |
| `ingame_gate_probe.lua` | What "the player is actually in the game" means. Produced both gate corrections: `wMapEventStatus`/`wScriptRunning` flicker every step, and `wMapStatus` stays `HANDLE` through a battle. |
| `object_slot_probe.lua` | How many of the 13 object structs are free during real play, and what a map load does to them. |
| `step_watch_probe.lua` | What a real NPC's fields look like across one step — the read that overturned the movement plan before any code was written. |
| `struct_diff_probe.lua` | Our hand-built object against one the engine built, field by field. |

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

## Archipelago address measurement

One probe per address, because a probe that measures several at once cannot say which one is
wrong. Results and what is still unmeasured: `phase9.md` and `agent_docs/verified.md`.

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
| `ap_battlemode_probe.lua` | `wBattleMode` — **still open**, 0x015A vs 0x1234, needs one trainer battle |

## Not a probe

| File | What it is |
| --- | --- |
| `run_second_client.lua` | Four lines of configuration: points a second BizHawk at bridge port 7779, then loads the real adapter. Kept for convenience; **it no longer ships**, because the adapter now walks ports 7778-7785 by itself and a second copy finds its own core with no help. |
