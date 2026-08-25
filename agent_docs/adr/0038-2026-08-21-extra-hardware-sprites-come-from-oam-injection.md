# 2026-08-21 — Extra hardware sprites come from OAM injection above `gOamLimit`, not HBlank multiplexing

<!-- ADR 0038. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-21
- **Decision:** Where a BizHawk adapter wants more characters on screen than the engine's own object
  array can hold, it writes **additional entries into the game's shadow OAM buffer, in the range the
  engine's per-frame path does not touch**, from an execute hook on a routine the game already runs.
  It does **not** re-point an OAM entry mid-frame to draw it twice (sprite multiplexing), on this or
  any other game, unless a specific game is measured to need it.
- **Status:** accepted; mechanism proven on Emerald, tier scheduled as `plans.md` Phase 8.1.
- **Context:** an outside developer working on Crystal raised multiplexing — *"one slot and moving it
  in hblank"* — as cheaper than painting ghosts over the emulator's output, which it would be. The
  question was whether it is reachable from Lua, and the user's condition was the project rule now
  recorded in the ADR above: no ROM patch, Lua only.
- **Options considered:**
  1. **HBlank sprite multiplexing.** The classic technique: rewrite an OAM entry in the gap after a
     scanline so the same hardware sprite draws again lower down. **Rejected, on three independent
     grounds, any one of which is sufficient.**
     - *No hook exists.* BizHawk 2.11's entire `event` library — read out of
       `BizHawk.Client.Common.dll` rather than recalled — offers frame, input, savestate and memory
       callbacks. **There is no scanline or LYC callback.** Every mid-frame wakeup available is a
       memory callback on an address the game itself touches.
     - *The affordable wakeups are the wrong ones.* Emerald's own VCount interrupt fires once a
       frame, at one fixed line, and is the only free mid-frame hook — one wakeup, not the many a
       multiplexer needs. Enabling the game's HBlank interrupt from Lua is possible without a patch
       and would fire **160 times a frame**, two orders of magnitude past the per-callback cost this
       project has already priced, while contending with the field's own HBlank DMA.
     - *There is nothing to solve.* Multiplexing exists to beat a **sprite-count** limit. Emerald has
       128 hardware entries with about five in use on a normal map (`documentation.md`); the limit
       that binds is the engine's 16-entry object array, which no hardware trick touches.
  2. **OAM injection above `gOamLimit`.** Chosen. The engine bounds its layout pass at 64 on the
     overworld while transferring all 128 entries to hardware every VBlank, so entries 64–127 are
     carried to the PPU for free and are never cleared. **The game itself relies on this** — its
     wireless status indicator sits at entry 125 — so this is a sanctioned pattern rather than a
     trick played on the engine.
  3. **Keep painting over the finished frame.** Already shipped as the drawn tier and kept as the
     last resort, not removed: it is the only one of the three with no ceiling.
- **What settled it was measurement, not the argument.** Standing still with the crowd on screen,
  same map, each tier alone (`verified.md`, 2026-08-21): at 16 peers all three tiers measure 60.0 avg
  against a 60.0 bare control. At **56** — where the OAM window fills — injection holds **60.0** and
  painting drops to **39.6**. At 150 painted peers, 10.4. Injection is flat to its ceiling.
- **Consequences, accepted going in:**
  - **Three attribute halfwords only.** The affine-matrix pass rewrites the fourth halfword of all
    128 entries every frame; anything writing there is fighting the engine.
  - **A leased entry must be released.** Nothing clears 64–127 per frame, so an entry left behind is
    a body frozen on screen until the next scene change. The release path is not optional.
  - **Injected sprites lose overlap ties** to the engine's own, which sit at lower indices, and get
    no collision, no engine animation and no walking. This replaces the *drawn* tier, never the
    spawned one.
  - **OBJ tiles, not entries, become the capacity limit** — which is what makes the painted tier's
    survival as a third fallback the right call rather than a compromise.
  - **Multiplexing is not forbidden forever**, it is unjustified here. A game that genuinely runs out
    of OAM entries (Crystal has 40 and spends most) can revisit it — with the one probe named in
    `ideas.md` answering the only question that matters: what a mid-frame Lua wakeup costs on that
    core.
