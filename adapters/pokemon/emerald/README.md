# Pokémon Emerald

**Status: first target game (Phase 1 in progress).** See `agent_docs/phases/phase1.md`.

- Platform: GBA, played via BizHawk.
- Adapter language: Lua (BizHawk's scripting host).
- Reading local state is trivial — the `pokeemerald` decompilation documents player X/Y,
  map bank/number, and camera offset rather than requiring reverse engineering. See
  `agent_docs/licensing.md` for the rule on how that decomp may and may not be used.
- Rendering uses `gui.drawImage` overlay (tier 1 of 3 from the brief) — draws over the
  emulator, not occluded by scenery, a weekend of effort rather than OAM injection or a
  ROM hack.
- Tile-grid movement means small integer positions; 10Hz sync is the brief's working
  hypothesis, not yet confirmed (see open questions in `agent_docs/contract.md`).
- No ROM is or will be shipped with this repo. Bring your own legally-obtained copy.

See `agent_docs/contract.md` for the adapter interface and tick model this adapter must
implement, and `agent_docs/phases/phase1.md` for the current verification task list.
