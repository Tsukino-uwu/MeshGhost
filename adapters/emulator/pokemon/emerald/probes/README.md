# Emerald probes

Every script here is a **development tool**, not part of the shipped adapter — the release ships
`meshghost_emerald.lua` and `lib/`, nothing from this folder. They are kept as the record of how
each fact was established. The four `avatar_*` probes in particular are a **reusable template**:
they were written to chase one address shift on an Archipelago ROM and are the first thing to
reach for when a ROM moves something again.

**Logs are not kept** — each probe writes a timestamped `.log` beside itself and `.gitignore`
covers them. Conclusions belong in `VERIFIED.md`.

**How to run one**: point `dev-scripts/bizhawk-dev-loader.target` at it — the loader swaps scripts
live, with no emulator relaunch (`agent_docs/environment.md`). Probes written before the loader
run their own frame loop and still work opened directly in the Lua Console.

**This index is meant to be complete.** Every `.lua` in this folder has a row somewhere below. If
you add a script, add its line in the same edit — a folder index that silently stops covering the
folder is worse than no index, because it reads as "that is everything".

## Some of these WRITE. Read this before running one.

Most scripts here only read. These do not, and they are called out here rather than only in their
own headers, because a folder index that hides a save-altering tool is the worst kind of gap —
nobody reads a header they did not know existed.

| Probe | What it writes | Does it survive a reset? |
| --- | --- | --- |
| `testkit.lua` | **`SaveBlock1` — the save structure itself.** Bikes, a rod, badges. | **YES, if you save the game afterwards.** Use a file you do not mind changing. |
| `grant_test_kit.lua` | **`SaveBlock1`**, same class as `testkit.lua` — the granter kept as a standalone one-shot. | **YES, if you save afterwards.** |
| `watertile.lua` | the **live map grid**, turning the tile in front of you into water | No. The map is rebuilt from ROM on the next map load, and it restores the original tile on unload. |
| `noclip.lua` | the **live map grid**, clearing collision so you can walk through anything | No, and it restores the tiles it changed when dropped. Drop it before judging anything. |
| `goto_map.lua` | the warp/map fields, plus `MESHGHOST_WARP_X/_Y` for the destination coordinates | No — live RAM. **Slot 8 is its undo**, and `CLAUDE.md` says to ask before warping the user's character. |
| `spawn_test.lua` | object RAM — one object event plus a sprite | No. Live RAM only, cleared by the engine. |
| `wheelie_ghost.lua` | a ghost's movement action, to drive one wheelie deliberately | No — live RAM. |
| `oaminject_probe.lua` | shadow-OAM entries above `gOamLimit` | No — live RAM, rewritten by the engine's own transfer every frame. |
| `use_acro.lua` / `use_mach.lua` / `acroride.lua` | the registered-SELECT-item field, so the bike can be got onto by the game's own field effect | No — live RAM, and the game's own code does the rest. |

**Why this is allowed at all.** `CLAUDE.md`'s rule is that nothing which *ships* writes a save or
game state; the carve-out for dev-only test tooling was granted by the user 2026-08-18 —
*"this is during dev/testing i don't care about my save files. its fine/expected. but a release
should obviously still never touch/affect a save file"*. It is narrow: a probe, never an adapter;
never imported by `meshghost_emerald.lua`; never copied into a release; and the tester's own save,
knowingly. `_template/README.md` has the full clause.

**And its own hard rule: verify the address, do not trust a code.** `testkit.lua` exists in the
shape it does because published cheat codes were tried first and failed — BizHawk accepted Emerald
GameShark codes without error, decoded them to nonsense, marked them ACTIVE, and wrote garbage
every frame. Every offset it uses instead comes from our own make-compare-verified `pokeemerald`
build, so each one is checkable. `agent_docs/pitfalls.md`.

## Reaching a state without playing to it

All of these exist for one reason: an hour of play per attempt is a cost paid in the *user's* time,
every cycle. Cheating to reach a state is explicitly allowed (`agent_docs/playing.md`); cheating is
never in an adapter.

| Probe | What it does |
| --- | --- |
| `goto_map.lua` | **Writes.** Warp to any map. `CB2_LoadMap` does not run `WarpIntoMap`, so it also sets the destination coordinates from that map's own warp event — without which it changed the map and left the player outside it. |
| `noclip.lua` | **Writes the live grid, reversibly.** Walk through anything. Warping lands you on a warp tile; getting from there to the water, the ledge or the corner a test needs is the slow part. |
| `testkit.lua` / `grant_test_kit.lua` | **Write `SaveBlock1`, and it persists if you save.** A Mach Bike, an Acro Bike, a Super Rod and badge flags in one second. Bag quantities are XOR-encrypted with `SaveBlock2`'s `encryptionKey`, which is why a plain write yields an item with a nonsense count — the header explains the whole structure. |
| `watertile.lua` | **Writes the live map grid**, reversibly. Finds a metatile in the tilesets this map already has loaded whose behaviour is water and writes it into the tile you are facing, so the game treats it as water because as far as it is concerned it is. The "combine the tools" script: read the decomp to learn what makes a tile water, write memory to make one, checkpoint with a savestate, drive input to use it. |
| `loadslot9.lua` | Loads the user's checkpoint savestate — how a scripted ride that drifted or got blocked is undone. A savestate is not an in-game save, so it costs nothing. |
| `use_acro.lua` / `use_mach.lua` | Register the bike to SELECT and press it, so the item's own field effect sets every avatar flag rather than us writing `PLAYER_AVATAR_FLAG_*` by hand. |
| `dismount.lua` | Gets off whatever you are riding, and **confirms it happened**. Written because `use_acro` pressed SELECT once and assumed; three times in one session it silently did not, and the run carried on reading a state nobody was ever in. |
| `press_a.lua` | Taps A to clear dialogue. Tapped, not held — the game reads a new press, so a held A advances one box and sits there. |
| `input_test.lua` | Does `joypad.set` reach this game at all? The subtraction step for "the press did nothing", which has three unrelated causes. |
| `acro_check.lua` | Is the Acro Bike actually in the bag *and* registered *and* is the pad landing? Reads all three rather than guessing between them. |
| `surfstart_drive.lua` | Replays the start of surfing frame by frame from a savestate, because the transition lasts about two seconds and cannot be judged by hand. |

## Scripted rides and walks — counted in TILES, never in frames

A frame-timed route drifts across the map and rides into trainers. Every one of these counts
tiles, and each was written for a specific defect the user reported while watching.

| Probe | The route, and what it was for |
| --- | --- |
| `grasswalk.lua` | Three tiles up, three down, forever — the plain walking baseline both renderers are judged against. |
| `bikeloop_probe.lua` | A fixed square on the Mach Bike: movement plus turns, repeatably, while both renderers are watched. |
| `bikeline_probe.lua` | Up and down a muddy slope — the one terrain that exercises acceleration, top speed, and being pushed backwards while still holding a direction. |
| `bikeclimb_probe.lua` | The run-up and the climb, repeating. |
| `machsquare.lua` | Squares of 1, 2 and 3 tiles a side, because a long leg is always at top speed and says nothing about the speeds below it. |
| `holdup.lua` | Holds one direction and nothing else, for minutes. |
| `bikestop.lua` | Rides, then STOPS — the interesting frames are the few just after a stop, which is too short to catch by hand while also reading a log. |
| `onestep.lua` | Exactly one tile at a time on the bike, to reproduce a whole walk cycle being spent on a single step. |
| `acroride.lua` | Three tiles left, three right on the Acro Bike — the one Acro case with no wheelie and no hop in it, so anything off the ground during the run is ours. |
| `acro_hop.lua` | Hop in place, then hop while moving. Fixed phases with a countdown, nothing to time by hand. |
| `hopride.lua` | B held throughout, long runs one way, reversals of varying length — the user's own reading of when the defect appears. |
| `wheelietile.lua` | One tile, in a wheelie. A wheelie ride has to be entered before it can be steered, so a plain tap never produces it. |
| `poseshot.lua` | Rides into the idle bike pose and holds it, facing up and down — the side-on frames hide the difference between standing on the bike and rolling along on it. |

## Spawning a real character (2026-08-18)

| Probe | What it is for |
| --- | --- |
| `object_slot_probe.lua` | Read-only. How many of the 16 object events and 64 sprites are free during real play, what a live NPC's records look like beside the player's, and what map loads and camera culling do to both. |
| `spawn_test.lua` | **Writes game RAM** (ADR-gated). Spawns one real object event + sprite, walks it with held movements, cycles its facing, and re-spawns it after the engine clears it. This is the working recipe. |

## Watching what the ENGINE does, so a ghost can be made to match

**This is the method that worked for every peer state.** Read what the engine does for the player,
then make the ghost match it — never reason about what the code ought to do and ask the user to
look (`phase8.md`'s retrospective).

| Probe | What it answers |
| --- | --- |
| `playeranim_probe.lua` | What the PLAYER's own sprite is doing — the reference every mirrored pose is checked against. The overworld PAUSES an idle sprite, which is why handing the animation to the engine is right for fishing and wrong for a stationary bike. |
| `posediff.lua` | Do the ghost and the player hold the same PIXELS? Written when every struct field agreed and the screen did not. |
| `facing_probe.lua` | What facing the ghost is actually DRAWN with — an object's visible direction is its sprite's animation number plus the hardware flip, not its `facingDirection` field. |
| `hopwatch.lua` | Catches a ghost hopping when the player is not. |
| `wheelie_watch.lua` | What the engine does with a wheelie, frame by frame — this is what proved every wheelie action DOES complete on the engine's own object. |
| `wheelie_ghost.lua` | **Writes.** The other half: why a GHOST does not finish one, when the player does. |
| `shadowdust_probe.lua` | Who has a shadow and who has dust, for a hopping ghost — two questions a screenshot answers badly and a memory read answers exactly. |
| `surfblob_probe.lua` | Reads the game's own surf blob, so a ghost's can be built from the field effect's ROM template and handed to the engine rather than approximated. |
| `dive_probe.lua` | What DIVING does to a character. Underwater is not a variant of surfing: it warps to a separate map, swaps the graphic, and starts a bobbing driver. |
| `ripple_probe.lua` | Logs every sprite that comes into existence, with the ROM pointers it was built from, where it appeared relative to the player and how long it lived. Written to specify the water trail; it reports ALL new sprites on purpose, because deciding in advance which ones are ripples is the assumption worth not making. |
| `grasslive.lua` | What the engine's grass sprites are doing — where they sit, which frame, and the one a screenshot cannot answer: their subpriority relative to the character. |
| `grassdump.lua` | Whether grass occlusion is the metatile's top layer or a field-effect SPRITE. (It is a sprite.) |
| `fishing_probe.lua` | A one-line-per-change timeline of every field that could carry the fishing animation — `graphicsId` above all, since Emerald swaps the whole avatar graphic for special states. Logging only on change is deliberate: the changes *are* the animation. |
| `fishing_watch.lua` | Does fishing **create** anything, the way surfing does? Logs the whole process rather than sampling an endpoint, because fishing branches and two branches end in the same standing pose. |
| `turn_and_door_probe.lua` | Two gaps the side-by-side comparison turned up, both about what the engine does that the painted renderer does not. |
| `cavewarp_probe.lua` | The drawn tier's two hiding mechanisms across a warp — the player sprite's invisible bit and the live-vs-ROM palette fit. Written for "the drawn ghost lingers entering a cave"; it is what showed a cave fades to WHITE. |

## Reading the map, the seams and the world

| Probe | What it answers |
| --- | --- |
| `connections.lua` | Which maps CONNECT to this one: the neighbour, the seam offset, and its dimensions. Indoor maps carry no connections pointer at all — which is the whole house-hiding rule. |
| `coordwatch.lua` | Who moves whom at a seam crossing. The engine rebases every live object one frame AFTER the crossing, which decides whether our own bookkeeping matches the world or fights it. |
| `blinkwatch.lua` | Does a ghost's sprite ever go invisible across a seam? (It does not — the blink was the drawn tier being cleared on transition frames.) |
| `collisionmap.lua` | What is walkable around the player, so a scripted ride can path instead of driving into a fence. |
| `findmud.lua` | Where the muddy slope is on this map, so a ride starts at the bottom of it rather than hunting by eye. |
| `warpdump.lua` | Where the game thinks it is, and what is in the warp structs. |

## Rendering internals — VRAM, tiles, backgrounds and the UI

| Probe | What it answers |
| --- | --- |
| `bgread_probe.lua` | Can the BG layers be read at all — control registers, tilemaps, tile pixels? Asked first because this project has a recorded case of a VRAM region reading back as all zeros, which taken at face value is a confident and completely false answer. |
| `tiledecode_probe.lua` | Decodes specific BG tiles and prints them, for when the coverage mask reported a strip half the width the screen showed. |
| `framedump.lua` | Renders a graphic's animation frames to PPM straight from ROM, independently of the painter — if the hat is missing HERE the decode is wrong, if it is present the painter clips it. |
| `vram_probe.lua` | Stage 1 of the VRAM/sprite-injection investigation (`agent_docs/ideas.md`). Stages 2–5 were never run; the hardware-sprite tier reached the same goal by the OAM route instead. |
| `vramwrite_probe.lua` | WHO writes the ghost's OBJ tiles mid-frame, when every per-tick instrument reads clean. |
| `vramdiff_probe.lua` | The inversion of it: WHICH OBJ tiles change tick to tick, for when a per-address write-watch only covers the addresses it was pointed at. |
| `gsprites_scan_probe.lua` | Finds `gSprites`' EWRAM base on an arbitrary (possibly patched) build. `gSprites` is a runtime array, so unlike ROM data it cannot be found by byte-searching the file. **This is the measurement that closed the two-render-paths split** — it does not shift on the Archipelago build, so both builds spawn (`BANDAGES.md`, 2026-08-19). |
| `oamshadow_probe.lua` | Read-only. Whether `gMain.oamBuffer[64..127]` — the window above `gOamLimit` — is really dead space the engine never writes, and whether it reaches hardware. The de-risk under the hardware-sprite tier. Also the recorded reason a frame-boundary shadow-vs-hardware compare cannot settle the transfer question: it is one frame out of phase by construction. |
| `oaminject_probe.lua` | **Writes** (live RAM only: shadow-OAM entries). Parks N hardware sprites in `gMain.oamBuffer[64..119]` and lets the PPU draw them — Stage 1 of the hardware tier. `_NO_WRITE`/`_NO_SCAN`/`_QUIET` are subtraction switches kept from the run that proved the tier is free and the probe's own logging was not. |
| `uiregion_probe.lua` | **A recorded negative.** Asked the GBA's display registers (`DISPCNT` window enables, `WIN0H`/`WIN0V`) where the UI panels are. They change every frame during ordinary walking, so they describe the display rather than the panel — the same trap that caught the Game Boy's window layer on Crystal. Kept as the reason the tilemap route was taken instead. |
| `textbox_probe.lua` | The route that worked: asks what the game DREW rather than what the LCD is displaying, reading BG tilemaps with each background's address taken from its own `BGxCNT` screen-base bits, so no game symbol is involved. Measured 2026-08-19 that BG0 is the UI layer and empty until a panel opens — the whole detector behind the drawn tier's clipping. |

## Measuring cost

| Probe | What it measures |
| --- | --- |
| `fpshold.lua` | Read-only, presses nothing. Samples the frame rate while the player STANDS STILL — the right instrument for comparing rendering tiers, because a moving route leaves fixed-position synthetic peers behind and the painted tier's off-screen cull then makes them look free. |
| `fpsride.lua` | The moving counterpart, for judging a change during real play rather than comparing tiers. |
| `fps_probe.lua` | Whether the EMULATOR is keeping 60fps. `os.clock` inside the adapter measures the Lua process's own CPU and said 0.44ms/frame while the user still reported lag; `client.get_approx_framerate()` is the instrument for the claim "the script makes it laggy". |
| `capacity_probe.lua` | How many ghosts this game can hold in its own terms: object events out of 16, engine sprites out of 64, enabled hardware OAM entries out of 128. Also prints the local `area_id` and tile, so a synthetic peer can be aimed at exactly that map. |

## Diagnosing the adapter itself

| Probe | What it answers |
| --- | --- |
| `probe_render_remote_trace.lua` | A headless companion (same bridge/networking/JSON code as the adapter, no sprite decoding or drawing) printing this client's own area/position and every known remote's area/position/match status every ~2s. Load it the way you load the adapter when diagnosing a "ghost isn't rendering" issue — see `agent_docs/pitfalls.md`'s entry on two emulator instances silently colliding on a shared default port, which is what motivated it. |
| `shadow_ghost_probe.lua` | Draws a second ghost at a fixed tile offset beside the player, driven by the *same* local-state read, smoothing and animation code as a real remote but with no bridge, relay or core. Isolates "is the rendering wrong?" from "is the network wrong?". |
| `sweep_guard_probe.lua` | Whether `sweepOrphanGhosts()`'s "active, not the player, `localId` 255" predicate ever matches something that is not one of ours — the measurement behind gating that sweep on the overworld and on a confirmed address. |
| `apspawn_gate_probe.lua` | Why an Archipelago build receives a peer and spawns nothing: prints all three reasons the spawn tier can decline (budget 0, `area_id` mismatch, refused cross-link) side by side once a second, because none of them logs on its own. |
| `battle_probe.lua` | Whether `gMain.callback2` reliably distinguishes "in battle" from "in the overworld". |
| `shot_once.lua` | One screenshot, then nothing. `client.screenshot()` writes the emulator's video output — BG layers and engine-drawn sprites, and never the Lua-overlay drawn tier (`agent_docs/playing.md`). |

## Feasibility probes, from before the thing existed

| Probe | What it answered |
| --- | --- |
| `sprite_probe.lua` | Whether the Brendan/May sprite could be decoded out of ROM at all, before any rendering was built. |
| `sprite_ghost_test.lua` | Drawing that decoded frame on screen at a fixed offset — no network. |
| `surf_bike_probe.lua` | Written for the then-open surf/Mach Bike/Acro Bike question — whether the `PLAYER_AVATAR_FLAG_*` bits behave as `pokeemerald` documents them, plus real per-tile timing. **It was never run**: all three states were finished instead by watching the engine directly, with the probes in the section above. Kept as a worked example of the read-only shape, not as live tooling. |

## Archipelago address relocation — the reusable four-stage template

Run in this order; each narrows what the previous one found. Full story: `phases/phase8.md`.

| Probe | Stage |
| --- | --- |
| `avatar_scan_probe.lua` | Scan EWRAM for where `gObjectEvents`/`gPlayerAvatar` moved to |
| `avatar_hexdump_probe.lua` | Dump raw memory around the candidates the scan produced |
| `avatar_array_probe.lua` | Confirm the candidate really is array entry 0, by array-boundary arithmetic |
| `avatar_verify_probe.lua` | Final live verification that the relocated addresses respond to real input |
| `sprite_anchor_verify_probe.lua` | Follow-up: confirms the sprite/screen anchor on the relocated ROM |

## Any Emerald-derived ROM — resolve the anchors instead of recognising the build

The four probes above chase one known relocation. This one asks the opposite question: given a ROM
nobody has measured — an Archipelago world revision, SPEEDCHOICE, EX SPEEDCHOICE — where are the
anchors *now*?

| Probe | What it does |
| --- | --- |
| `romvariant_probe.lua` | Read-only, presses nothing, draws nothing. Logs the ROM header identity and a bounded FNV-1a checksum (whole plus per-megabyte, computed 32 KB per frame so nothing blocks), then resolves each anchor by **search** — the character palette block by byte signature plus a palette-structure check, `gObjectEventGraphicsInfoPointers` by a purely structural pointer-run search, and `gObjectEvents`/`gPlayerAvatar`/`gSaveBlock1Ptr` by a live two-way cross-link scan of EWRAM and IWRAM. Anchors no search can reach (`gSprites`, the sprite coord offsets, `gMain`) are logged as *this vanilla literal read this value*, for a human to compare. Every anchor is reported RESOLVED / **AMBIGUOUS** / **UNRESOLVED**; it never picks one of several. Fixed phases with a countdown — be in the overworld when it says so, and nothing else. |

Its two deliberate limits, both stated in its own log: `gSprites` is a runtime array with no ROM
original, so `gsprites_scan_probe.lua` remains the instrument for it; and `gMain.callback2` is only
*observed* at the vanilla code site, so a build that moved `gMain` makes that section meaningless.

## Frozen phase snapshots

Kept under their original development-phase names as historical snapshots, not maintained. The
shipped adapter is `../meshghost_emerald.lua`.

| File | Phase |
| --- | --- |
| `phase1_probe.lua` | Phase 1 — read local X/Y and map, verify against known motion |
| `phase2_ghost.lua` | Phase 2 — a fake ghost, no network |
| `phase3_loopback.lua` | Phase 3 — real state through the real Go stack, drawn as it comes back |
| `phase4_multiplayer.lua` | Phase 4 — two real players |
| `phase5_5_sprite.lua` | Phase 5.5 — the real sprite; byte-identical to the adapter as it stood on 2026-08-14 |
