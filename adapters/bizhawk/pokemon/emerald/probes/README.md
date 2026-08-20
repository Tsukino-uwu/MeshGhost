# Emerald probes

Every script here is a **development tool**, not part of the shipped adapter — the release ships
`meshghost_emerald.lua` and `lib/`, nothing from this folder. They are kept as the record of how
each fact was established. The four `avatar_*` probes in particular are a **reusable template**:
they were written to chase one address shift on an Archipelago ROM and are the first thing to
reach for when a ROM moves something again.

**Logs are not kept** — each probe writes a timestamped `.log` beside itself and `.gitignore`
covers them. Conclusions belong in `agent_docs/verified.md`.

**How to run one**: point `dev-scripts/bizhawk-dev-loader.target` at it — the loader swaps scripts
live, with no emulator relaunch (`agent_docs/environment.md`). Probes written before the loader
run their own frame loop and still work opened directly in the Lua Console.

## Three of these WRITE. Read this before running one.

Most scripts here are read-only. Three are not, and they are called out here rather than only in
their own headers, because a folder index that hides a save-altering tool is the worst kind of
gap — nobody reads a header they did not know existed.

| Probe | What it writes | Does it survive a reset? |
| --- | --- | --- |
| `testkit.lua` | **`SaveBlock1` — the save structure itself.** Bikes, a rod, badges. | **YES, if you save the game afterwards.** Use a file you do not mind changing. |
| `watertile.lua` | the **live map grid**, turning the tile in front of you into water | No. The map is rebuilt from ROM on the next map load, and it restores the original tile on unload. |
| `spawn_test.lua` | object RAM — one object event plus a sprite | No. Live RAM only, cleared by the engine. |

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

## Spawning a real character (2026-08-18)

| Probe | What it is for |
| --- | --- |
| `object_slot_probe.lua` | Read-only. How many of the 16 object events and 64 sprites are free during real play, what a live NPC's records look like beside the player's, and what map loads and camera culling do to both. |
| `spawn_test.lua` | **Writes game RAM** (ADR-gated). Spawns one real object event + sprite, walks it with held movements, cycles its facing, and re-spawns it after the engine clears it. This is the working recipe. |

## Reaching a state without playing to it — the two cheating tools

Both exist for the same reason: surf, the bikes and fishing all need a save that can do them, and
an hour of play per attempt is a cost paid in the *user's* time, every cycle. Both are covered by
the dev-tooling carve-out above.

| Probe | What it does |
| --- | --- |
| `testkit.lua` | **WRITES `SaveBlock1`, and it persists if you save.** Puts a Mach Bike, an Acro Bike and a Super Rod in the bag and sets badge flags, in one second. Bag quantities are XOR-encrypted with `SaveBlock2`'s `encryptionKey`, which is why a plain write there yields an item with a nonsense count — the header explains the whole structure. |
| `watertile.lua` | **WRITES the live map grid**, reversibly. Finds a metatile in the tilesets this map already has loaded whose behaviour is water, and writes it into the tile you are facing — so the game treats it as water because as far as it is concerned it is. Restores the original on unload, and a map load rebuilds it from ROM anyway. The "combine the tools" script: read the decomp to learn what makes a tile water, write memory to make one, checkpoint with a savestate, drive input to use it. |

## The surfing and fishing states

Reproducing a state means reproducing **the whole** state — the animation *and* whatever the game
spawns alongside it. Surfing turned out to be a pose **plus** a separate Pokémon sprite attached
through the object's own `fieldEffectSpriteId`, so a ghost given only the graphic was half a
character. These ask the same question of fishing.

| Probe | What it answers |
| --- | --- |
| `fishing_probe.lua` | Read-only. A one-line-per-change timeline of every field that could carry the fishing animation — `graphicsId` above all, since Emerald swaps the whole avatar graphic for special states, and that distinction decides how a ghost would reproduce it at all. Logging only on change is deliberate: a per-frame dump of a 200-frame sequence is unreadable, and the changes *are* the animation. |
| `fishing_watch.lua` | Read-only. Asks the companion-sprite question directly: does fishing **create** anything, the way surfing does? It logs every change across the whole process rather than sampling an endpoint, because fishing is a process with branches — nothing bites, something bites and is missed, something bites and takes several rounds, something bites and a battle starts — and two of those branches end in the same standing pose. |

## Archipelago address relocation — the reusable four-stage template

Run in this order; each narrows what the previous one found. Full story: `phases/phase8.md`.

| Probe | Stage |
| --- | --- |
| `avatar_scan_probe.lua` | Scan EWRAM for where `gObjectEvents`/`gPlayerAvatar` moved to |
| `avatar_hexdump_probe.lua` | Dump raw memory around the candidates the scan produced |
| `avatar_array_probe.lua` | Confirm the candidate really is array entry 0, by array-boundary arithmetic |
| `avatar_verify_probe.lua` | Final live verification that the relocated addresses respond to real input |
| `sprite_anchor_verify_probe.lua` | Follow-up: confirms the sprite/screen anchor on the relocated ROM |

## Feasibility and mechanism probes

| Probe | What it answered |
| --- | --- |
| `sprite_probe.lua` | Whether the Brendan/May sprite could be decoded out of ROM at all, before any rendering was built |
| `sprite_ghost_test.lua` | Drawing that decoded frame on screen at a fixed offset — no network |
| `shadow_ghost_probe.lua` | A second ghost driven by the *same* code path as the real one, to isolate rendering from networking |
| `battle_probe.lua` | Whether `gMain.callback2` reliably distinguishes "in battle" from "in the overworld" |
| `vram_probe.lua` | Stage 1 of the VRAM/sprite-injection investigation (`agent_docs/ideas.md`); stages 2-5 never ran |
| `surf_bike_probe.lua` | Built for the open surf/Mach Bike/Acro Bike question — **written, never yet run** |
| `probe_render_remote_trace.lua` | A headless companion that speaks the same bridge protocol, for tracing `render_remote` without a game |
| `sweep_guard_probe.lua` | Read-only. Whether `sweepOrphanGhosts()`'s "active, not the player, `localId` 255" predicate ever matches something that is not one of ours — the measurement behind gating that sweep on the overworld and on a confirmed vanilla address (2026-08-19). |
| `oaminject_probe.lua` | **WRITES** (live RAM only: OAM shadow entries, nothing else). Parks N hardware sprites in `gMain.oamBuffer[64..119]` and lets the PPU draw them — Stage 1 of the hardware-sprite tier. `MESHGHOST_OAMINJECT_COUNT` sets N; `_NO_WRITE`/`_NO_SCAN`/`_QUIET` are subtraction switches kept from the run that proved the tier is free and the probe's own logging was not. |
| `fpshold.lua` | Read-only, presses nothing. Samples the emulator's frame rate while the player STANDS STILL, and exists because `fpsride.lua` is the wrong instrument for comparing rendering tiers: a moving route leaves fixed-position synthetic peers behind, and the painted tier's off-screen cull then makes them look free. Results 2026-08-21 in `verified.md`. |
| `oamshadow_probe.lua` | Read-only. Whether `gMain.oamBuffer[64..127]` — the shadow-OAM window above `gOamLimit` — is really dead space the engine never writes, and whether it reaches hardware. The de-risk under the hardware-sprite tier (`plans.md` Phase 8.1); results in `verified.md` 2026-08-21. Also the recorded reason a frame-boundary shadow-vs-hardware compare cannot settle the transfer question: it is one frame out of phase by construction. |
| `capacity_probe.lua` | Read-only. How many ghosts this game can actually hold in its own terms: object events out of 16, engine sprites out of 64, and enabled hardware OAM entries out of 128 — the ceiling under the engine's. Also prints the local `area_id` and tile so a synthetic peer can be aimed at exactly that map. |
| `gsprites_scan_probe.lua` | Finds `gSprites`' EWRAM base on an arbitrary (possibly Archipelago-patched) build. Reads game memory only; it drives the D-pad and nothing else. Assumes nothing about where `gSprites` is — it is a runtime array, so unlike ROM data it cannot be found by byte-searching the file. This is the measurement that would close the two-render-paths split in `BANDAGES.md`. |
| `apspawn_gate_probe.lua` | Read-only. Why the Archipelago build receives a peer and spawns nothing: prints all three reasons the spawn tier can decline (budget 0, `area_id` mismatch, refused cross-link) side by side once a second, because none of them logs on its own. |
| `uiregion_probe.lua` | **A recorded negative.** Asked the GBA's own display registers (`DISPCNT`'s window enables, `WIN0H`/`WIN0V`) where the UI panels are. They change every frame during ordinary walking, so they describe the display rather than the panel — the same trap that caught the Game Boy's window layer on Crystal. Kept as the reason the tilemap route was taken instead. |
| `textbox_probe.lua` | The route that worked: asks what the game DREW rather than what the LCD is displaying, reading BG tilemaps with each background's address taken from its own `BGxCNT` screen-base bits so no game symbol is involved. Measured 2026-08-19 that BG0 is the UI layer and empty until a panel opens — the whole detector behind the drawn tier's clipping. |

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
