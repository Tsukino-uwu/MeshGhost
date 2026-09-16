# Crystal probes

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

## Eighteen of these WRITE (twenty until four were deleted 2026-09-16; `cmd_drive` added the same day, `autoplay_charset_probe` 2026-09-17), and nineteen hold the controller. Read this before running one.

Called out here rather than only in their own headers, because a folder index that hides a
memory-writing tool is the worst kind of gap — nobody reads a header they did not know existed.
**This section said "ten" and named nine until 2026-08-25, while eighteen scripts were missing
from the index — five of them writers** (and it undercounted twice more since).

**Object RAM only, never a save** — a reset or a map load rebuilds what they touched:
`spawn_test.lua` through `spawn_test5.lua`, `struct_diff_probe.lua`,
`orphan_sweep.lua`, `set_colour.lua` (the player object's palette byte, and palette RAM).

**Hardware sprite entries:** `oam_probe.lua` writes shadow OAM 36..39 and the `OAM` domain, only
on frames where the engine's own layout pass has declared them unused, and parks them back at
`y=160` — the engine's own "not in use" value — when it is done.

**Player state, deliberately** — these cheat on purpose, which `CLAUDE.md` permits for a
probe and never for an adapter: `goto_map.lua` warps the player (six writes, exactly what the
game's own `warp` command does; **it savestates first, always** — to slot 8, this project's undo
convention, unless `MESHGHOST_GOTO_UNDO_SLOT` says otherwise), `grant_test_kit.lua` writes
badges/HMs into the party, `grant_items.lua` writes the bag, `grant_flash.lua` sets the Flash
status flag, `ap_bag_grant.lua` and `ap_force_state.lua` write bag/state on an Archipelago build,
and `noclip.lua` redirects `wTilesetCollisionAddress` to a filtered table it writes into the unused
tail of `wOverworldMapBlocks`, and sets `EMOTE_OBJECT` on nearby NPCs (2026-09-13); `cmd_drive.lua`
writes whatever its command file says -- map blocks into `wOverworldMapBlocks`, single WRAM bytes
(2026-09-16).
**The screen's tile buffer only:** `autoplay_charset_probe.lua` writes bytes into the text rows of a
message box that is already open, so the game draws them; closing the box puts the map back (2026-09-17).
**None writes the `.sav`** — but an in-game save afterwards makes their changes
permanent, so savestate first and reload after. `noclip_off.lua` restores the collision pointer.

**The grant probes are kept SEPARATE on purpose** — badges/moves, bag, Flash — so that
what each one changed stays obvious when something later looks wrong.

**Nineteen hold the controller**, and the count keeps growing because a driven rig is now the
normal way to reach an expensive state: `action_probe`, `bump_probe`, `cmd_drive`, `dig_drive`,
`door_loop`, `fish_drive`, `fly_drive`, `ice_probe`, `idle_cycle_drive`, `ledge_drive`,
`menu_clip_check`, `menu_state_table`, `seam_drive`, `seam_shuttle`, `square_drive`,
`surf_follow_probe`, `trainer_check`, `turn_drive`, `whirlpool_drive` — plus anything loaded alongside them.
**Check before driving a window the user may be holding** (2026-09-13): a driver pressed the d-pad
while the user was loading savestates in the same window; the frame counter jumping backwards and
forwards in the trace was the only sign.
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

**Deleted 2026-09-16** (the audit, the user's call: their code transcribed a decompilation formula):
`spawn_test6.lua` (NPC template plus computed screen coordinates), `spawn_test7.lua` (NPC behaviour
wearing the player's face, the combination that shipped) and `walk_test.lua` (a spawned ghost walking
by the game's own step mechanism); `set_level.lua` (a party Pokémon's level, experience and stats)
goes with them for the same reason. What they showed stays in `VERIFIED.md`; the scripts are in git
history, and anything needed again is re-measured rather than restored.

## Movement, pose and cadence

The 1:1 bar is judged on screen, so these measure what the engine DRAWS and how fast, not what
its structs say. `adapters/CLAUDE.md`'s "never move a ghost in units the game does not use" came
out of this group.

| Probe | What it answered |
| --- | --- |
| `action_watch.lua` | Read-only. Whether the PLAYER's own object actually carries the `OBJECT_ACTION` values the decomp says drive fishing, bumping, spinning and emotes — reading the source is not watching it happen. |
| `action_probe.lua` | The generalisation of `bump_probe.lua`: every non-walking animation class in the engine's own terms, how long each facing holds in video frames, and how fast the engine's object clock actually ticks. The **cadence** a still frame cannot show. |
| `fish_drive.lua` | **Holds the controller and loads a savestate.** Casts the rod, holds it, presses B to clear the text and casts again — because a BITE is the interesting case and reloading a savestate replays one RNG state. Logs the player's and every ghost's action/facing/position, run-length encoded. |
| `rod_check.lua` | Read-only, one shot. Diffs the two rod tiles we read from the cartridge against the ones the engine has in VRAM while the player is fishing — which is how `FishingRodGFX` was found to be the wrong asset entirely (`LoadFishingGFX` overwrites it). |
| `fly_probe.lua` | The player and EVERY occupied object slot on one line, run-length encoded — action, facing, drawn tile, sprite y offset, flags. Written to find why a spawned ghost went invisible during a Fly; what it actually found was that the player's object carries no Fly animation at all (action 1, facing `$FF`, `yoff` 0 throughout). Read-only. |
| `menu_state_table.lua` | **Drives** a START menu open and shut and prints one table of every cheap display byte across three states — no menu, menu open, menu closed. Built after two candidate "is a panel on screen" signals had already failed; the table killed both at a glance and showed the real behaviour. Unload it before judging anything on screen. |
| `menu_clip_check.lua` | The narrower version of the same idea: opens and closes a menu so the adapter's own `MESHGHOST_CRYSTAL_UI_DEBUG` lines can be read with a menu genuinely up. Drives input. |
| `fly_drive.lua` | **Drives** one complete Fly from a prepared savestate — loads `MESHGHOST_FLY_SLOT` (the user's slot 8 = same town, 9 = cross-town), presses A once, and screenshots the landing into `logs/`. Turned the fly-landing iteration loop from a request on the user's time into a self-driven one; the fly trace is the other half of the reading. Unload before judging anything else. |
| `icon_check.lua` | Read-only: does the species -> Pokemon-icon ROM lookup land on real graphics? Prints the two-hop resolution for a spread of species plus two self-checks — Pidgey/Spearow/Fearow must share one icon, which arithmetic that is merely plausible cannot fake. |
| `whirlpool_drive.lua` | **Drives (savestate 10) and holds Up.** The SPIN class, made repeatable: a whirlpool spins the player on demand. Logs every occupied object slot -- so it sees the GHOST's action and step machinery, not just the player's. Its first version held Up continuously, which is the case that WORKS; it now drives the reported up/pause/up cycle. |
| `dig_drive.lua` | **Drives (savestate 9, as it was that hour) one Dig/Escape Rope** — loads the slot, presses A twice, screenshots every 8 frames for ~14s. The window is long on purpose: 32 ticks of departure spin, the map reload, then 32 ticks of arrival flicker. Dig and Escape Rope are ONE routine (`EscapeRopeOrDig`), so this covers both. `fly_probe.lua` is the actual reading. Unload before judging anything else. |
| `ledge_drive.lua` | **Drives (savestate 9, later the same day) one ledge hop** — loads the slot, holds Down 40 frames, screenshots every **4** frames rather than 8, because a hop is over in ~32 frames total and its arc changes every tick. An 8-frame cadence photographs four points of a sixteen-point curve. Unload before judging anything else. |
| `flags_compare_tiers.lua` | Sets `MESHGHOST_COMPARE_TIERS` (and explicitly clears the flags it does NOT want) so the one loopback ghost renders twice — painted 2 tiles left, spawned 3 tiles right (`COMPARE.spawned = 3`, which overrides the loopback offset outright). The standing dev default for judging the drawn tier against the engine in one place at one time. Sets no tick; it runs once. |
| `flags_goto.lua` | Sets `MESHGHOST_GOTO` and `MESHGHOST_GOTO_UNDO_SLOT` for `goto_map.lua`. Exists because goto_map's own header says to set those before loading it and there was no way to do that on a running emulator — an env var is fixed at launch and the loader's control file names paths, not values, so the only reachable destination was goto_map's hardcoded `DEFAULT`. **Load it BEFORE goto_map, and clear `MESHGHOST_GOTO` after**: a leftover destination warps the player on the next load of goto_map. |
| `surf_follow_probe.lua` | Read-only, driven. Whether a spawned ghost follows a peer on water, and whether a break is a REFUSAL or just lag. Counts SWIMMING agreement and follow lag, and is written so the suspect it was built around can be REFUTED by its own output. |
| `ice_probe.lua` | Read-only, driven across ice with a walking CONTROL phase. What the player's object carries while gliding: the fast gait, `OBJECT_ACTION_STAND`, and a stride that never advances. **It refuted the obvious fix** -- `SLIDING seen SET = false`, so the peer never wears the bit Emerald's `noanim` corresponds to. |
| `trainer_check.lua` | **Drives a short route from a savestate.** Everything that decides what a trainer LOOKS like -- `wVariableSprites`, `wUsedSprites`, map objects, structs, OAM -- plus a screenshot in the same frame. Built to run TWICE (adapter loaded / not) so the two dumps can be diffed; that diff is what exonerated the adapter over the wrong-trainer-sprite report. |
| `slot10_census.lua` | Read-only, one shot. Every map object and object struct with its sprite id, plus a screenshot -- built to be run with the adapter loaded and NOT loaded so the two can be diffed. Superseded by `trainer_check.lua`, which drives a route and adds the variable-sprite table. |
| `warp_check.lua` | Read-only, one shot. Where a warp actually landed: map id, status, the player's object, live OAM count, and whether BG row 0 is all one tile (a blank screen) -- plus a screenshot. Written because `goto_map`'s log buffers and reports NOTHING on a short run. |
| `grant_flash.lua` | **Writes one bit** -- `STATUSFLAGS_FLASH_F`. Kept, but note it was written for a misdiagnosis: the grey screen it was meant to fix was a wrong map id, not a dark cave. Lighting applies on the next map load, not immediately. |
| `bump_probe.lua` | What a bump looks like in the struct AND in the tiles drawn — walking stays `STANDING`, action reads 3, facing alternates, and the drawn tile follows the facing byte. |
| `stride_probe.lua` | Read-only. What the engine draws across one step, per direction — measuring the drawn tier's two guesses (two mid-step arrangements per facing, an 8-frame `WALK_FRAME_HOLD`), neither of which had ever been seen running. Pair with `square_drive.lua` and it needs nobody. |
| `posediff_probe.lua` | Read-only. Which of lag / speed / phase / rounding is behind *"walking left/right feels a bit off... not 1:1"* — four causes needing four different fixes, so it measures instead of guessing. |
| `handover_probe.lua` | Read-only. How many frames a freshly promoted ghost takes to reach hardware OAM — i.e. whether the adapter's tier overlap is long enough, or whether the peer is drawn by nobody for a frame. **The overlap is not one frame**: `holdHandover` keeps the painted copy for up to **8** and releases on evidence (the object's own entries appearing in OAM, within one engine stride). Measured at four frames in Crystal, which is why counting frames was replaced by looking; this row said "one-frame" until 2026-08-27. |
| `transition_probe.lua` | Read-only. What is true while a door transition is on screen, after the painted tier's three positive gates all let one through. Watches every candidate across a transition rather than reasoning about which ought to work. |

## Orphans — a character we left behind

| Probe | What it does |
| --- | --- |
| `orphan_probe.lua` | Read-only. Names whether a *"weird static ghost"* is ours, by the fingerprint no map-placed NPC carries: the local player's sprite id plus `ENGINE.WONT_DELETE`. |
| `orphan_sweep.lua` | **Writes.** Clears the objects `orphan_probe` identified — the same bytes the adapter clears on despawn. The adapter deliberately forgets an unverifiable ghost rather than zeroing a slot the game may have reused, which is why the cleanup is a separate opt-in tool. |

## Driving the game, so a person does not have to

The `/play-game` skill allows driving a running game to reach a state. Every one of these costs
the user nothing, which is the point.

| Tool | What it does |
| --- | --- |
| `square_drive.lua` | **Holds the d-pad.** Walks a 3x3 square forever — the user's own test case for an intermittent fault that needs the same movement many times. |
| `door_loop.lua` | **Holds the d-pad.** In and out of a door forever, waiting between presses so each transition completes — how the painted tier's map-transition behaviour gets watched often enough to measure. |
| `goto_map.lua` | **Writes + savestates slot 8.** Warps the player to a named map, doing exactly what the game's own `warp` script command does, in the same order. |
| `goto_route39.lua` | One line of config pointing `goto_map` at Route 39 — the user's designated worst case (*"a big route, and fills up things due to having a lot of npc's"*). List it ABOVE `goto_map.lua` in the loader's control file. |
| `load_undo.lua` | Loads savestate slot 8 — the undo for a `goto_map` warp. One action, then quiet. |
| `turn_drive.lua` | **Holds the d-pad.** Turns on the spot, one direction at a time: holds a direction only until the engine's own `OBJECT_DIRECTION` changes, then waits 90 frames — measured, not timed, so a press cannot run on into a step. What produced the turn-in-place frame sequence of 2026-09-13 (`documentation.md`, *Turning in place*). |
| `movetrace_pair.py` | Reads logs only. Pairs two instances' `MESHGHOST_CRYSTAL_MOVE_TRACE` logs by wall clock: a peer's first engine pixel to the watcher's target and model (`lag`), a turn's face bytes against the drawn pose (`turn`), direction change against a step's first pixel (`dirflip`), idle tile alignment (`idle`). |
| `noclip.lua` | **Writes** (2026-09-13 version). Points the tileset's collision pointer at a filtered copy of the real table in the unused tail of `wOverworldMapBlocks` — warp-family and grass values kept — and sets `EMOTE_OBJECT` on NPCs within two tiles, standing down while any real decoration object exists; per build (vanilla, Archipelago V1.0 base). Which of its premises are measured and which are not: its header. The superseded row below described the first version: walk through anything, by redirecting `wTilesetCollisionAddress` into a WRAM zero region — *not* Emerald's approach, because Game Boy keeps the collision table in ROM, which this project never writes. |
| `noclip_off.lua` | **Writes.** Turns noclip off and proves it, restoring the pointer if an unclean unload left it redirected. |
| `grant_test_kit.lua` | **Writes.** Grants the badges, HMs and field moves a test session needs to reach water, ledges, dark caves and the sky without playing through the game. |
| `grant_items.lua` | **Writes the bag, and holds one byte every frame.** Super Rod (the drawn tier's fishing class cannot be watched without one), Master Balls, Max Repels, Rare Candies — all idempotent one-shot writes. **Permanent repel** is the exception and the only per-frame part: `wRepelEffect` is a STEP COUNTER the engine decrements, so "permanent" means topping it up, the same shape as Emerald's `testkit.lua`. It suppresses wild Pokémon **below your lead's level, not all of them** (`CheckRepelEffect`), so pair it with `set_level.lua` when encounters keep coming. The key-item pocket has no quantity byte where the other two do — cited from `ram/wram.asm`, because assuming otherwise corrupts the bag. |
| `compare_layout.lua` | Config only: the loopback ghost rendered TWICE from one state — spawned 3 tiles right, painted 2 tiles left — with the hardware tier explicitly OFF. Every switch is set explicitly, including the ones being turned off — the loader replaces files, never globals. |

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
| `tileset_header_probe.lua` | Read-only. The loaded tileset header and the ROM table it is copied from, by finding the table by its entries' shape and every entry in WRAM; self-checks on vanilla against the `.sym`. **2026-09-13**: header at flat `$11E0`, table at ROM `$4D46B` (vanilla `$11D9` / `$4D596`). |
| `zero_runs_probe.lua` | Read-only. Every run of ≥ 256 zero bytes in CPU-visible WRAM, re-read for ten seconds, reporting any byte that became non-zero. **2026-09-13**: `$C8C0-$CD1F` identical on both builds, every bank-1 run moved. |
| `player_sprite_probe.lua` | Read-only. The local player's `OBJECT_SPRITE` and `OBJECT_WALKING`, a line on every change, for a minute. **2026-09-13**: a runner on the Archipelago build wears `$65` at gait group 2. |
| `ap_battlemode_probe.lua` | `wBattleMode` — **settled 2026-08-19** by one trainer battle: `0x1234` read 2 for the whole fight and returned to 0; `0x015A` read 1 in both a wild and a trainer battle, which is what ruled it out |

## Added 2026-08-26/27 — the mixed vanilla + Archipelago session

| File | What it answers |
| --- | --- |
| `ap_hram_scroll_probe.lua` | `hSCX`/`hSCY` on a patched build, by sweeping all 127 bytes of HRAM for the camera's own signature. **Found `$FFC7`/`$FFC8`**, where vanilla's pair are dead bytes. Reports what the CURRENTLY-USED pair did, by name, so a run either confirms the assumption or names its replacement |
| `ap_bag_probe.lua` | lists every pocket-shaped run in the player-data bank. An empty pocket is `00 FF`, which zeroed RAM also looks like, so only a pocket with CONTENTS can be matched against the screen |
| `ap_bag_grant.lua` | **WRITES.** Puts a BICYCLE in the key-item pocket — the only way to reach the fourth gait. Re-checks its anchor and savestates before writing |
| `ap_playerstate_probe.lua` | a byte that changes on a bike toggle and changes BACK. Start-state agnostic on purpose |
| `ap_force_state.lua` | **WRITES.** Forces a player-state value to confirm the address by its EFFECT. Refuted `0x1A17` on 2026-08-27 — the write produced no visible change |
| `wram_window.lua` | a hex dump of a WRAM window. The blunt instrument to reach for when a signature scan has just produced a confident wrong answer |
| `idle_cycle_drive.lua` | walk, stand still past the idle rule, walk again — the demote/promote pair on a loop. HOLDS THE CONTROLLER. Verifies its own input landed by reading the game's tile back |
| `shot_burst.lua` | a screenshot a second. Screenshots capture the emulated framebuffer WITHOUT the Lua overlay, so this separates an ENGINE character from a PAINTED one in one image |
| `flags_step_lag.lua` | turns on the line naming WHICH term refused a peer the spawned tier (`wearable`/`blocking`/`paceable`) |
| `flags_bike_pose.lua` | facing trace + sprite trace together: what the cache holds, and which graphics a peer resolved from |

## Cross-map ghosts, and the seam (2026-08-27)

| File | What it is |
| --- | --- |
| `connections_probe.lua` | **Passive.** Reads `wMapConnections` and all four connection structs every frame and prints a SEAM REPORT on every map change: which of the departing map's structs named the arriving map, the player's coordinates on both sides, and a CANDIDATE CHECK that runs the translation arithmetic BACKWARDS against the crossing to mark its own homework. It is what caught a mirrored north/south assumption before it shipped. Also logs `wBGMapOffsetX/Y` and `hSCX/hSCY` for screen-mapping questions, and reports which directions it has NOT seen. Honours `MESHGHOST_CRYSTAL_CONN_ADDR` (env, then global) to override the `wMapConnections` address. |
| `seam_drive.lua` | **Input-driving.** Loads savestates 7, 8 and 5 in turn and walks one tile across each seam, so all four directions are exercised without asking anyone to hold a controller. Aborts if a wild battle starts (slot 5 is on the water) and proves it returned to a known state rather than asserting it. |
| `seam_shuttle.lua` | **Input-driving.** Walks back and forth across one east/west seam forever — the user's own repro. Deliberately paces PERPENDICULAR to the seam and prints the player's map each second: an earlier square-walking driver strolled across the seam and silently turned a cross-map peer into an ordinary one. Repetition is what turns "I think it blinked" into a distribution. |
| `where_probe.lua` | Read-only. Once a second: this window's build (from the header), map group/number, the player's tile and the two in-play bytes, from the same per-build addresses the adapter uses. Attach it as a second line of the dev-loader target so it runs BESIDE the adapter. Written on the five-build rig (2026-09-09) to settle range/area questions the adapter logs cannot -- they carry peer positions but never the player's. Log named by bridge port: two Archipelago seeds share a checksum. |
| `loadstate_once.lua` | **Loads a savestate** (slot 3, or `MESHGHOST_LOADSTATE_SLOT`) two seconds after attach, once, logging the tile before and after. A reproduction tool for "does a savestate load make this window's ghost vanish for others" (2026-09-09: it does not; the cause was the emulator pausing on the menu that loads it). Unload it before judging anything -- and take it OFF the target file after use, or every reload fires it again. |
| `grant_all_vanilla.lua` | **Writes the game.** All 16 badges, all 7 HMs, a Bicycle (registered to Select) and a Super Rod, once, on vanilla V1.0, V1.1 or Speedchoice v8.1 -- refuses anything else. Addresses from the three hash-verified `.sym`s (all equal), ids from `item_constants.asm`; saves an undo state to slot 6 first; reads everything back. Take it off the target after it acts. |
| `grant_all_ap.lua` | **Writes the game.** The same kit on an Archipelago ROM, either base. Its addresses were MEASURED from the cartridge on 2026-09-09 (the header says how): the pack-menu headers give the three pockets (D866 / D960 / D989, two of them already confirmed on screen), the engine-flag table's badge signature gives D82B/D82C, and wTMsHMs is the 57 bytes between. Item ids from the apworld's public `items` table. Does not register the bike (that pair is unmeasured). |
| `wram_dump.lua` | Read-only. Hex-dumps one flat WRAM range once (`MESHGHOST_DUMP_FROM`/`_TO`, default the badge/bag region) to a log named by bridge port. Filters nothing; the pockets are identified afterwards by shape. On an EMPTY bag it shows nothing but terminators, which is why the AP addresses above were taken from the ROM instead. |
| `ui_signals_probe.lua` | Read-only. Logs, on change, the signals around the drawn tier's gates: wSpriteUpdatesEnabled, wMapStatus/wBattleMode, live OAM count and the first twelve entries, LCDC/WY/WX/SCX/SCY, the text-box corner tile and the CGB attribute of a box tile (bit 7 = BG covers sprites). Vanilla family only. Written 2026-09-09 to see what a fishing text box does to sprites; it showed the game draws them over the box. |
| `drive_fish.lua` | **Input-driving**, one-shot: loads slot 5 (a spot where A casts the rod), casts, dismisses the text, opens START and its first two entries, on a frame countdown. The user's "savestate 5, press A to fish" turned into something the agent can replay. Take it off the target afterwards. |
| `grant_party.lua` | **Writes the game.** Teaches Surf/Fly/Strength/Waterfall to party slot 1 (Whirlpool/Cut/Flash to slot 2) on all five builds, and on a vanilla-family build with an EMPTY party first creates a level-5 Cyndaquil (a copy of the AP window's own starter struct, the player's name and ID as trainer). The AP party address was measured by contents from a `wram_dump.lua` run (2026-09-09); AP never gets a created Pokemon because its nickname/OT blocks are unmeasured. Undo state to slot 6. |
| `drive_menu_npc.lua` | **Input-driving**, one-shot, any build: waits for a non-player sprite on the right half of the screen (45 s at most), presses START, logs every live OAM entry and a menu tile's CGB attribute for two seconds, presses B. Answered "does this build draw a character under its START menu" on 2026-09-09: Archipelago removes the NPC's OAM entries (8 live -> 4) and keeps the player; Speedchoice keeps all eight (its NPC was beside the menu, not under it). Neither menu's tiles set BG priority. Also dumps bank-0 WRAM 0x0F00-0x0FFF with the menu open and closed: on AP the four wMenuBorder coordinates sit at vanilla's 0x0F82-0x0F85 (0,10,15,19 for the START menu). |
| `drive_surf.lua` | **Input-driving**, one-shot, any build: walks Right until blocked, presses A at the water and keeps confirming until wPlayerState reads PLAYER_SURF (on AP, until the tile moves), paddles a 2-tile square and screenshots. Surfed V1.1 from New Bark's east shore across the seam into Route 27 and back on 2026-09-09. Its first version pressed B too early and declined its own prompt -- the header says so. |
| `fly_menu_drive.lua` | **Input-driving**, one-shot, any build: Fly through the menus from the overworld with no prepared state -- START, POKeMON, the lead, Down to FLY, the map, go -- a screenshot after every press beside the logs. Flew V1.1 to New Bark's own fly point on 2026-09-09. `fly_drive.lua` remains the savestate-based one. |
| `set_colour.lua` | Two modes, any build. Default, WIRE ONLY: hands `MESHGHOST_COLOUR_RGB` to the adapter's `MESHGHOST_CRYSTAL_DEV_CLOTHING` override and writes nothing -- the ghosts elsewhere wear it, the local player does not. `MESHGHOST_COLOUR_FAKE_PATCH=1`: **writes object RAM and palette RAM**, held per frame, doing what a custom-trainer-colour patch does (the player object onto slot `MESHGHOST_COLOUR_PAL`, that slot's clothing colour rewritten in BOTH palette blocks, the hardware flag set), which colours the local player too; refuses until the red slot's clothing colour reads as the game keeps it, its own check of the palette-RAM address. Both modes CONFIRMED ON SCREEN 2026-09-10 (`VERIFIED.md`). |
| `cmd_drive.lua` | **Writes the game and holds the controller.** Vanilla V1.0 only. Runs a command file beside it (`cmd_drive.cmd`, re-read live): hold/wait/shot/status, `poke`, `block BX,BY ID` into the map buffer, `redraw` (START then B), `tilecheck` (tile to block to collision, beside the engine's own byte), `collscan`/`collfind` (which blocks of the loaded tileset are ledges or water). The state-building half of the `/play-game` skill's "cheat to create, then use it as the game intends": built 2026-09-16 to hop real ledge blocks and cast at real water blocks for `borrowed_values_probe`. Its header says what is measured. |
| `borrowed_values_probe.lua` | Read-only. Whenever the player fishes or a new object appears (a hop's shadow), logs every object struct and all 40 OAM entries per frame, 8 frames before to 60 after, unfiltered. Measured 2026-09-16 that `facingFrames.ROD`, the shadow's spawn bytes and `emote.SHADOW_DY` (down/left/right) match the engine's own (`UNVERIFIED.md`, the per-site audit entry). Reads every frame while loaded, so it is not for judging pacing. |
| `xtrace_on.lua` | Sets `MESHGHOST_CRYSTAL_XTRACE` before the adapter loads, arming the adapter's own bounded per-frame tier trace (150 frames after each map change, with per-frame draw counters and the reason any frame went unpainted). The dev loader shares one Lua environment, which is why a global set here reaches the adapter. |

## autoplay's Crystal module (2026-09-17)

Loaded beside `autoplay/drivers/bizhawk/driver.lua` on an autoplay instance, and read against the driver's own answers; `MEASURED.md` has what each settled.

| File | What it is |
| --- | --- |
| `autoplay_state_probe.lua` | Read-only. Every frame, one line when any of ~50 state bytes changes (map, tile, wMapStatus, wSpriteUpdatesEnabled, wBattleMode, the movement and direction bytes, the neighbour collisions, menu and script bytes, a few HRAM ones), and the player object's 0x28 bytes on change. Log named by `AUTOPLAY_PORT`. Settled position, facing, mode, a step, a refusal and a door. |
| `autoplay_text_probe.lua` | Read-only. The 18 rows of `wTilemap`, 0x40 bytes of the menu block from `wWindowStackPointer`, and the text and joypad bytes, each on change; `AUTOPLAY_TEXT_PROBE_HRAM=1` (global or environment) adds all of HRAM. Settled the message box, the ▼'s blink, `wTextboxFlags`, the 2D menu block and when the game sees a button. |
| `autoplay_charset_probe.lua` | **Writes the tile buffer.** With a message box open and waiting (refuses otherwise), writes 0x60-0xFF into its text rows 72 at a time and captures each page, so every byte is named from what the game draws. Presses nothing; closing the box restores the map. Take it off the target when it logs `done`. |

## Not a probe

| File | What it is |
| --- | --- |
| `run_second_client.lua` | Four lines of configuration: points a second BizHawk at bridge port 7779, then loads the real adapter. Kept for convenience; **it no longer ships**, because the adapter now walks ports 7778-7785 by itself and a second copy finds its own core with no help. |
