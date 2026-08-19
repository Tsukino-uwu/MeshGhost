# Pokémon Emerald

**Status: Phase 8 (ongoing, post-"good enough" work).** First game targeted, shipped, and
live-tested with real two-player sessions. See
[agent_docs/phases/phase8.md](../../../../agent_docs/phases/phase8.md) for the current task list
and the "Further work past 'good enough'" section below for what's still open.

- Platform: GBA, played via BizHawk.
- Confirmed working roms: "Vanilla", "Archipelago 0.6.7".
- **It writes game RAM** — object RAM only (`gObjectEvents`, `gSprites`, the sprite-tile
  allocation bitmap), never a save, cosmetic only, and only on a ROM whose addresses were
  measured. Cleared by `agent_docs/architecture.md`'s 2026-08-18 ADR, which extends Crystal's
  spawn ADR to this adapter. The adapter's own header said "Never writes memory" until that
  day; see [BANDAGES.md](BANDAGES.md) for the ROM guard that decides where it may write.
- Adapter language: Lua (BizHawk's scripting host).
- **How the game is read: an external source decompilation.** Fixed memory addresses, looked up in
  [`pokeemerald`](https://github.com/pret/pokeemerald) and cited — nothing is discovered at runtime.
  Addresses are unknowable but authoritative: you cannot invent one, and once the decomp gives it to
  you it is right. See [agent_docs/access-models.md](../../../../agent_docs/access-models.md) for what
  each access model costs and what the other adapters used.
- **[BANDAGES.md](BANDAGES.md)** is this adapter's shipped-compensation register and
  **[FLAGS.md](FLAGS.md)** its switch register — including the environment variables that are the
  only kind of switch a Lua adapter has.
- **[documentation.md](documentation.md)** describes how Emerald itself works — where player state
  lives and why one address is not enough, the tile-based movement model, and the callback that
  says which state machine is running. It was previously argued that a game with a decompilation
  needed no such file; **the user overturned that 2026-08-18** and every adapter now carries one.
  A curated description of the mechanics this adapter depends on is a different artifact from the
  decompilation, and being able to look something up is not the same as having looked
  ([adapters/_template/README.md](../../../_template/README.md)'s folder convention).
- Reading local state is trivial — the `pokeemerald` decompilation documents player X/Y,
  map bank/number, and camera offset rather than requiring reverse engineering. See
  [agent_docs/licensing.md](../../../../agent_docs/licensing.md) for the rule on how that decomp
  may and may not be used.
- **Rendering: the engine draws the ghost, not us.** A peer is spawned as a real object event
  plus a sprite and Emerald animates, walks and occludes it itself (step 18 below) — which is why
  a ghost is correctly hidden behind the pause menu, something the old overlay never was.
  **The `gui.drawPixel` overlay is still in the file and is still live, as the fallback on an
  Archipelago-patched ROM only** — the spawn path writes `gSprites`, whose relocation under that
  patch was never verified for *writing*. Registered in [BANDAGES.md](BANDAGES.md) as a
  deliberate, temporary split with one live run standing between it and deletion. Earlier phases
  (`phase2_ghost.lua` through `phase4_multiplayer.lua`) used `gui.drawImage` for a flat
  placeholder box, before the real sprite decode replaced it in Phase 5.5 and the spawn replaced
  that in Phase 8.
- Tile-grid movement means small integer positions; the brief's original "10Hz sync looks
  fine" hypothesis was superseded once real send-rate limits shipped — the real cap is 20Hz
  (`core.DefaultMinSendInterval`), live-confirmed across three games (see
  [agent_docs/contract.md](../../../../agent_docs/contract.md)'s Limits section).
- No ROM is or will be shipped with this repo. Bring your own legally-obtained copy.
- The shipped/maintained adapter script is `meshghost_emerald.lua`, in this folder — that's
  what `.github/workflows/release.yml` ships and what any future fix belongs in.
  `phase5_5_sprite.lua` is a historical copy under its original development-phase name (split
  off 2026-08-14, byte-identical only at that moment — see that file's own header for how far
  it's since diverged) — the "How this adapter was built" section below is the accurate
  history of how it came to be, under whatever name it had at each point.

See [agent_docs/contract.md](../../../../agent_docs/contract.md) for the adapter interface and
tick model this adapter must implement, and
[agent_docs/phases/phase8.md](../../../../agent_docs/phases/phase8.md) for the current
verification task list.

## Limits that come from the game, not from us

Measured 2026-08-19 with real peers over the real relay. Full table and method:
[agent_docs/crowd-limits.md](../../../../agent_docs/crowd-limits.md).

- **`16 − (objects the map currently has)` ghosts**, which was **13** in Littleroot Town.
  `gObjectEvents` has 16 entries and every NPC shares it.
- **The ceiling moves while you walk.** The same town reported 3, 2 and 1 active objects from
  different camera positions, so free slots change during play and a ghost can lose its slot when
  a nearby NPC loads.
- **The hardware is not the constraint here.** A GBA overworld character is a single OAM entry, so
  13 ghosts plus the cast used 16 of 128. (Crystal, on the Game Boy, hits a hardware wall of ten
  characters — this one does not.)
- **Past the limit, extra peers are refused and never appear**; nothing is corrupted and no NPC is
  displaced. That path used to cost the game its frame rate — 3fps at 24 peers — because the
  adapter re-scanned and logged per unplaceable peer per frame; fixed 2026-08-19, now a flat
  ~59.7fps with 36 peers offered.

## How this adapter was built

First game targeted, so the server and client didn't exist yet either — this build included
making those, not just the adapter. Getting from nothing to "good enough" (the end of
Phase 5.5) took about 10 hours.

Roughly in order, with the phase file that covers each part in more depth:

1. Drew a static purple box on screen as proof the overlay-rendering path worked at all.
   ([agent_docs/phases/phase2.md](../../../../agent_docs/phases/phase2.md))
2. Probed memory while walking in each direction, recording what changed, to find the
   position-related addresses. ([agent_docs/phases/phase1.md](../../../../agent_docs/phases/phase1.md))
3. Probed again while facing each direction without moving a tile, to separate "facing" from
   "position" in what had been found. ([agent_docs/phases/phase1.md](../../../../agent_docs/phases/phase1.md))
4. Made the box follow the player, still drawn at a fixed point on screen.
   ([agent_docs/phases/phase2.md](../../../../agent_docs/phases/phase2.md))
5. Made the box track world position instead of screen position, so it stayed correct whether
   the player was on- or off-screen. ([agent_docs/phases/phase2.md](../../../../agent_docs/phases/phase2.md))
6. Tested going in and out of buildings and between routes, to check position tracking
   survived map/warp transitions. ([agent_docs/phases/phase1.md](../../../../agent_docs/phases/phase1.md),
   [phase2.md](../../../../agent_docs/phases/phase2.md))
7. Replaced the static box with an idle sprite that moves around.
   ([agent_docs/phases/phase5_5.md](../../../../agent_docs/phases/phase5_5.md))
8. Added a walking animation. ([agent_docs/phases/phase5_5.md](../../../../agent_docs/phases/phase5_5.md))
9. Added a running animation — initially just the walk cycle sped up, corrected to Emerald's
   real, separate running pic table once live testing showed it looked wrong.
   ([agent_docs/phases/phase5_5.md](../../../../agent_docs/phases/phase5_5.md))

The real networking — the relay, the core, and the bridge protocol connecting an adapter to
both — got built alongside this adapter rather than before it, since Emerald was also the
first game to need it. [phase3.md](../../../../agent_docs/phases/phase3.md) (loopback: one real
client, a synthetic echoed "ghost") and [phase4.md](../../../../agent_docs/phases/phase4.md) (two
real players, join/leave, despawn on disconnect) cover that side.
[phase5.md](../../../../agent_docs/phases/phase5.md) is not Emerald-specific — it's where the
core got proven game-agnostic by running it against a fake, non-Emerald adapter, which is what
let TEVI (Phase 6) reuse it directly.

See [agent_docs/phases/phase1.md](../../../../agent_docs/phases/phase1.md) through
[phase5_5.md](../../../../agent_docs/phases/phase5_5.md) for the detailed, dated log of this
work, and [agent_docs/pitfalls.md](../../../../agent_docs/pitfalls.md) for the transferable
lessons pulled out of it (memory probing methodology, overlay rendering gotchas, map-transition
read glitches).

### Further work past "good enough"

Real work continued after Phase 5.5 closed — given its own phase file,
[phase8.md](../../../../agent_docs/phases/phase8.md), rather than 1–5.5 (which bundled Emerald
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
15. Taught the emulator to work for us, which turned out to matter more than any single fix.
    A loader script attached once at launch now loads, swaps and drops any number of scripts
    from a one-line control file — so an edit costs no relaunch, and the adapter and a test-state
    script run side by side. Before this, every probe revision interrupted whoever held the pad.
16. Kept going through the rest of what BizHawk exposes, once it was clear how much was sitting
    unused: savestates (all ten slots, save and load), the cheat engine, a Lua syntax checker,
    controller input, and screenshots the agent can read. Reaching a test state stopped costing
    real playing time — checkpoint once, restore instantly, forever.
17. Wrote down the limit in the same breath. A screenshot answers "what is on screen now", never
    "does this look right moving", so it changes no rule: the user still confirms every visual
    claim personally. That is the anti-hallucination split this project rests on — see
    [testing.md](../../../../agent_docs/testing.md).
18. Replaced the drawn ghost with a **spawned one**. A peer is now a real object event plus a
    sprite, and Emerald's own engine draws, animates and walks it — no drawing code at all. It
    is hidden behind the pause menu, which the overlay never was, and gets the right gender and
    palette for free by borrowing the player's own graphics.
19. Six bugs came out of that, each found by watching rather than reading, and the logs looked
    healthy for every one: a ghost wearing the player's animation frames (it had no tiles of its
    own), talking to a ghost launching the slot machine, a ghost frozen after one step, a run
    that was really a fast walk, a sprite a few pixels off its grid, and — the worst — a solid
    ghost leaked at every route crossing, which would eventually wall the route off.
20. The leak taught the general lesson: **"the map changed" and "the world was rebuilt" are
    different events.** A house rebuilds the world, a route boundary does not, and an identity
    check keyed on the map is wrong in exactly the case the other one hides. Houses had tested
    perfectly clean. ([_template/README.md](../../../_template/README.md))
21. Not yet done: surf, Mach Bike, Acro Bike, ledges, and Mach Bike rail sections. Half of this
    is now solved — every special state is simply its own `graphicsId`, so no anim classifier is
    needed. What remains is rendering it: a ghost borrows the player's graphics, so showing a
    surfing peer while you walk needs the sprite built from the graphics table instead of copied.

**~2 hours from a drawn ghost to a spawned one**, on top of the ~10 hours the drawn one took —
most of it spent on the six bugs above rather than on the spawn itself.

See [phase8.md](../../../../agent_docs/phases/phase8.md) for the full record.

## Dev tools

Everything below lives in [probes/](probes/), and **[probes/README.md](probes/README.md) is the
full index** — including the three scripts that WRITE, one of which alters the save. Read that
before running any of them. The adapter's own switches are in [FLAGS.md](FLAGS.md).

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
- `shadow_ghost_probe.lua` — draws a second ghost at a fixed tile offset beside the real player,
  driven by the *same* local-state read, smoothing, and animation code as the real remote path
  but with no bridge/relay/core in the picture. Isolates "is the rendering wrong?" from "is the
  network wrong?" — see its own header for the 2026-08-14 incident that motivated it.
- `surf_bike_probe.lua` — read-only probe for the still-open surf/Mach Bike/Acro Bike work
  (item 21 above): checks whether the `PLAYER_AVATAR_FLAG_*` bits behave as `pokeemerald`
  documents them, and measures real per-tile timing. Its findings aren't live-verified yet.
- `sprite_ghost_test.lua` — the Phase 5.5 step that drew a decoded Brendan frame beside the
  local player with no networking, proving the decode-then-draw path on screen before it was
  wired into real remote rendering.
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
