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

## Spawning a real character (2026-08-18)

| Probe | What it is for |
| --- | --- |
| `object_slot_probe.lua` | Read-only. How many of the 16 object events and 64 sprites are free during real play, what a live NPC's records look like beside the player's, and what map loads and camera culling do to both. |
| `spawn_test.lua` | **Writes game RAM** (ADR-gated). Spawns one real object event + sprite, walks it with held movements, cycles its facing, and re-spawns it after the engine clears it. This is the working recipe. |

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
