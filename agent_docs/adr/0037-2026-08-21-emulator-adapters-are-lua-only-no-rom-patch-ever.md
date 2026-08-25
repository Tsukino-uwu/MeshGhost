# 2026-08-21 — Emulator adapters are Lua-only: no ROM patch, ever

<!-- ADR 0037. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-21
- **Decision:** Every BizHawk adapter renders and reads entirely from the emulator's own Lua front
  end. **MeshGhost never ships, generates, applies or requires a patch to a game ROM**, and no
  technique is adopted that depends on code running inside the game. This is a standing rule, not a
  per-feature condition.
- **Status:** accepted. Describes what Emerald and Crystal already do; it is written down so the
  first technique that *needs* a patch gets refused on principle instead of re-argued.
- **Context:** the question arrived attached to a rendering idea — classical sprite multiplexing
  wants code on the game's own HBlank interrupt — but the user's answer was about the whole project:
  *"i want us to stick with lua for all bizhawk games, so we have cross rom patch compatability.
  making a rom patch would ruin that feature for us"*.
- **The reasoning, and it is the load-bearing part.** MeshGhost works on Archipelago seeds,
  randomizers and every other patched ROM **because it never touches the ROM**. It reads and writes
  live RAM from outside the emulated machine, so whatever patch the player is already running stays
  intact underneath and MeshGhost layers on top of it. Ship a patch of our own and that ends: the
  player would need our patch *and* their seed's patch reconciled into one ROM, which is not
  something they can do — the two are produced by different tools, from different bases, and neither
  knows about the other. **A patch would trade a feature that works on every ROM for one that works
  on one ROM.** The Archipelago compatibility work already in this repo is the thing being protected.
- **It is also the same rule the mod-based adapters already follow**, in a different medium: ship the
  minimum, install additively without overwriting, and work at any load order relative to other mods.
  A ROM patch is the emulator-side violation of all three at once.
- **Options considered:** (1) **Front-end Lua only** — chosen. (2) **Ship a ROM patch** — rejected
  for the reason above; it is not a cost/benefit call, it removes the property the project is built
  on. (3) **Hybrid — Lua by default, an optional patch for players who want more** — rejected as the
  worst of the three: it splits the user base by ROM, makes every bug report ambiguous about which
  build produced it, and creates a second artifact per game to keep in sync with the first.
- **Consequences, accepted going in:**
  - **Techniques that require code inside the game are out of reach by choice.** Classical HBlank
    sprite multiplexing is the first casualty (`ideas.md`); anything wanting a custom interrupt
    handler, a hooked engine routine that must *return* a value, or new code at a ROM address is the
    same answer. The compensating fact, found while answering this: the front end can usually reach
    the same place from outside — an `event.onmemoryexecute` hook at an engine routine is a mid-frame
    wakeup with no patch, and writing the engine's own shadow OAM buffer above `gOamLimit` gets extra
    hardware sprites with no patch either (the hardware-sprite tier, `ideas.md`).
  - **Live RAM writes remain the mechanism**, on the terms the 2026-08-17 / 2026-08-18 spawn ADRs
    already set: cosmetic only, identify the ROM first, and never write a save.
  - **A ROM's own contents stay read-only input.** Reading ROM data (sprite art, tables, pointers) is
    unaffected and is how both Pokémon adapters get their graphics.
