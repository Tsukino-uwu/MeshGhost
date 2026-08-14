# Pokémon Emerald

**Status: Phase 8 (ongoing, post-"good enough" work).** First game targeted, shipped, and
live-tested with real two-player sessions. See
[agent_docs/phases/phase8.md](../../../agent_docs/phases/phase8.md) for the current task list
and the "Further work past 'good enough'" section below for what's still open.

- Platform: GBA, played via BizHawk.
- Adapter language: Lua (BizHawk's scripting host).
- Reading local state is trivial — the `pokeemerald` decompilation documents player X/Y,
  map bank/number, and camera offset rather than requiring reverse engineering. See
  [agent_docs/licensing.md](../../../agent_docs/licensing.md) for the rule on how that decomp
  may and may not be used.
- Rendering draws the real Brendan/May overworld sprite pixel-by-pixel via `gui.drawPixel`
  (tier 1 of 3 from the brief — draws over the emulator, not occluded by scenery). Earlier
  phases (`phase2_ghost.lua` through `phase4_multiplayer.lua`) used `gui.drawImage` for a flat
  placeholder box before the real sprite decode replaced it in Phase 5.5.
- Tile-grid movement means small integer positions; the brief's original "10Hz sync looks
  fine" hypothesis was superseded once real send-rate limits shipped — the real cap is 20Hz
  (`core.DefaultMinSendInterval`), live-confirmed across three games (see
  [agent_docs/contract.md](../../../agent_docs/contract.md)'s Limits section).
- No ROM is or will be shipped with this repo. Bring your own legally-obtained copy.
- The shipped/maintained adapter script is `meshghost_emerald.lua`, in this folder — that's
  what `.github/workflows/release.yml` ships and what any future fix belongs in.
  `phase5_5_sprite.lua` is a historical copy under its original development-phase name (split
  off 2026-08-14, byte-identical only at that moment — see that file's own header for how far
  it's since diverged) — the "How this adapter was built" section below is the accurate
  history of how it came to be, under whatever name it had at each point.

See [agent_docs/contract.md](../../../agent_docs/contract.md) for the adapter interface and
tick model this adapter must implement, and
[agent_docs/phases/phase8.md](../../../agent_docs/phases/phase8.md) for the current
verification task list.

## How this adapter was built

First game targeted, so the server and client didn't exist yet either — this build included
making those, not just the adapter. Getting from nothing to "good enough" (the end of
Phase 5.5) took about 10 hours.

Roughly in order, with the phase file that covers each part in more depth:

1. Drew a static purple box on screen as proof the overlay-rendering path worked at all.
   ([agent_docs/phases/phase2.md](../../../agent_docs/phases/phase2.md))
2. Probed memory while walking in each direction, recording what changed, to find the
   position-related addresses. ([agent_docs/phases/phase1.md](../../../agent_docs/phases/phase1.md))
3. Probed again while facing each direction without moving a tile, to separate "facing" from
   "position" in what had been found. ([agent_docs/phases/phase1.md](../../../agent_docs/phases/phase1.md))
4. Made the box follow the player, still drawn at a fixed point on screen.
   ([agent_docs/phases/phase2.md](../../../agent_docs/phases/phase2.md))
5. Made the box track world position instead of screen position, so it stayed correct whether
   the player was on- or off-screen. ([agent_docs/phases/phase2.md](../../../agent_docs/phases/phase2.md))
6. Tested going in and out of buildings and between routes, to check position tracking
   survived map/warp transitions. ([agent_docs/phases/phase1.md](../../../agent_docs/phases/phase1.md),
   [phase2.md](../../../agent_docs/phases/phase2.md))
7. Replaced the static box with an idle sprite that moves around.
   ([agent_docs/phases/phase5_5.md](../../../agent_docs/phases/phase5_5.md))
8. Added a walking animation. ([agent_docs/phases/phase5_5.md](../../../agent_docs/phases/phase5_5.md))
9. Added a running animation — initially just the walk cycle sped up, corrected to Emerald's
   real, separate running pic table once live testing showed it looked wrong.
   ([agent_docs/phases/phase5_5.md](../../../agent_docs/phases/phase5_5.md))

The real networking — the relay, the core, and the bridge protocol connecting an adapter to
both — got built alongside this adapter rather than before it, since Emerald was also the
first game to need it. [phase3.md](../../../agent_docs/phases/phase3.md) (loopback: one real
client, a synthetic echoed "ghost") and [phase4.md](../../../agent_docs/phases/phase4.md) (two
real players, join/leave, despawn on disconnect) cover that side.
[phase5.md](../../../agent_docs/phases/phase5.md) is not Emerald-specific — it's where the
core got proven game-agnostic by running it against a fake, non-Emerald adapter, which is what
let TEVI (Phase 6) reuse it directly.

See [agent_docs/phases/phase1.md](../../../agent_docs/phases/phase1.md) through
[phase5_5.md](../../../agent_docs/phases/phase5_5.md) for the detailed, dated log of this
work, and [agent_docs/pitfalls.md](../../../agent_docs/pitfalls.md) for the transferable
lessons pulled out of it (memory probing methodology, overlay rendering gotchas, map-transition
read glitches).

### Further work past "good enough"

Real work continued after Phase 5.5 closed — given its own phase file,
[phase8.md](../../../agent_docs/phases/phase8.md), rather than 1–5.5 (which bundled Emerald
with building the server/client/core themselves) or living homeless in `status.md`. Roughly in
order:

10. A review/refactor sweep fixed several real socket-framing and crash-safety bugs (partial
    send/receive, dead-socket detection, a `pcall` guard, JSON control-character escaping).
11. Ran a real two-peer (non-loopback) session for the first time; found and fixed a
    port-collision test-setup mistake along the way, not an adapter bug.
12. A real Archipelago-patched ROM broke this adapter in four distinct ways — a relocated
    `CB2_Overworld`, relocated sprite/palette data, relocated `gObjectEvents`/`gPlayerAvatar`,
    and a timing bug in that last fix — all found via live memory investigation and fixed.
13. Found and fixed a gender-read timing bug — it could resolve before character creation
    finished on a fresh save; now gated on being confirmed in the overworld.
14. Found and fixed a sub-tile movement-smoothing bug once local testing stopped hiding it —
    the self-correcting glide-duration scheme was measuring idle time as step time; replaced
    with fixed per-anim timing after two other fixes were tried and disproven.
15. Not yet done: surf, Mach Bike, Acro Bike, ledges, and Mach Bike rail sections all still
    snap badly — a real, cited detection source is found (no new memory address needed) but
    not yet live-verified; a real per-tile timing measurement is also still needed.

See [phase8.md](../../../agent_docs/phases/phase8.md) for the full record.

## Dev tools

- `probe_render_remote_trace.lua` — a headless companion script (same bridge/networking/JSON
  code as `meshghost_emerald.lua`, no sprite decoding or drawing) that prints this client's own
  area/position and every known remote's area/position/match status every ~2s. Load it in
  BizHawk's Lua Console the same way as the real adapter when diagnosing a "ghost isn't
  rendering" issue — see its own header and `agent_docs/pitfalls.md`'s "Running two instances
  of the same emulator/game silently collide on a shared default port" entry for the incident
  that motivated it.
- `vram_probe.lua` — Stage 1 of the VRAM/sprite injection investigation
  (`agent_docs/ideas.md`, "Emerald: VRAM/sprite injection investigation"). Standalone, no
  networking, no drawing, never writes memory. Watches OBJ VRAM/palette/OAM through a play
  session and reports which tiles were never touched, cross-checked against the game's own
  sprite-tile allocator bookkeeping. Load it in BizHawk's Lua Console like any other probe;
  see its own header for the full address citation trail and what a session should cover.
- `battle_probe.lua` / `sprite_probe.lua` — small throwaway diagnostics (see their own headers)
  now doubling as the reference implementation for the confirmed Archipelago
  `CB2_Overworld`/sprite-decode addresses cited in `meshghost_emerald.lua`.
- `avatar_scan_probe.lua`, `avatar_hexdump_probe.lua`, `avatar_array_probe.lua`,
  `avatar_verify_probe.lua` — the four-stage live investigation that found Archipelago's
  relocated `gObjectEvents`/`gPlayerAvatar` addresses (2026-08-14, see `agent_docs/verified.md`
  for the full trail): a scripted down/left/up/right snapshot-diff to narrow all of EWRAM down
  to two candidates, a hex dump to match the real `pokeemerald` struct layout field-by-field, an
  array-boundary scan to confirm the array's start and locate `gPlayerAvatar`, and a final live
  read-back to confirm real, responsive data. Kept as a reusable template if a future
  Archipelago Emerald world/generator version shifts these addresses again.
- `sprite_anchor_verify_probe.lua` — dev-only follow-up to `avatar_verify_probe.lua`, watching
  whether `GSPRITES_ADDR`/`GSPRITECOORDOFFSETX_ADDR`/`GSPRITECOORDOFFSETY_ADDR` were also
  Archipelago-shifted (unlike `gObjectEvents`/`gPlayerAvatar`, which were). Its result was never
  separately written up, but is implicit in every later live test:
  `meshghost_emerald.lua`'s `playerScreenPos()` uses these exact three addresses unmodified
  (`meshghost_emerald.lua:76-79`), and the ghost has been repeatedly confirmed correctly
  anchored on this Archipelago-patched ROM since (see `agent_docs/verified.md`) — so these
  three, unlike the avatar/object-event addresses, are not shifted.
