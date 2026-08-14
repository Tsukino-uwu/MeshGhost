# Pokémon Emerald

**Status: first target game (Phase 1 in progress).** See
[agent_docs/phases/phase1.md](../../../agent_docs/phases/phase1.md).

- Platform: GBA, played via BizHawk.
- Adapter language: Lua (BizHawk's scripting host).
- Reading local state is trivial — the `pokeemerald` decompilation documents player X/Y,
  map bank/number, and camera offset rather than requiring reverse engineering. See
  [agent_docs/licensing.md](../../../agent_docs/licensing.md) for the rule on how that decomp
  may and may not be used.
- Rendering uses `gui.drawImage` overlay (tier 1 of 3 from the brief) — draws over the
  emulator, not occluded by scenery, a weekend of effort rather than OAM injection or a
  ROM hack.
- Tile-grid movement means small integer positions; 10Hz sync is the brief's working
  hypothesis, not yet confirmed (see open questions in
  [agent_docs/contract.md](../../../agent_docs/contract.md)).
- No ROM is or will be shipped with this repo. Bring your own legally-obtained copy.
- The shipped/maintained adapter script is `meshghost_emerald.lua`, in this folder — that's
  what `.github/workflows/release.yml` ships and what any future fix belongs in.
  `phase5_5_sprite.lua` is a frozen, byte-identical-at-the-time historical copy under its
  original development-phase name (split off 2026-08-14, see that file's own header) — the
  "How this adapter was built" section below is the accurate history of how it came to be,
  under whatever name it had at each point.

See [agent_docs/contract.md](../../../agent_docs/contract.md) for the adapter interface and
tick model this adapter must implement, and
[agent_docs/phases/phase1.md](../../../agent_docs/phases/phase1.md) for the current
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
9. Added a running animation. ([agent_docs/phases/phase5_5.md](../../../agent_docs/phases/phase5_5.md))

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

None logged yet — add entries here if work on this adapter resumes past Phase 5.5.

## Dev tools

- `probe_render_remote_trace.lua` — a headless companion script (same bridge/networking/JSON
  code as `meshghost_emerald.lua`, no sprite decoding or drawing) that prints this client's own
  area/position and every known remote's area/position/match status every ~2s. Load it in
  BizHawk's Lua Console the same way as the real adapter when diagnosing a "ghost isn't
  rendering" issue — see its own header and `agent_docs/pitfalls.md`'s "Running two instances
  of the same emulator/game silently collide on a shared default port" entry for the incident
  that motivated it.
