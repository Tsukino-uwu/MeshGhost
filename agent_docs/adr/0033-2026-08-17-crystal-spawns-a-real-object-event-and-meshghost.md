# 2026-08-17 — Crystal spawns a real object event, and MeshGhost writes game memory for the first time

<!-- ADR 0033. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** The Pokémon Crystal adapter renders a peer by **spawning a real in-game object
  event** — writing into a free `wObjectStructs` slot and letting Crystal's own engine draw it —
  rather than drawing an overlay with `gui.*` as Emerald does. This is the first deliberate
  crossing of the "no emulator memory writes" non-goal in `plans.md`, which required exactly this:
  an ADR, not an inference. **Scoped to vanilla Crystal V1.0 only.**
- **Correction, same day, on finishing `adapters/_template/README.md`: this is a narrower change
  than the first draft claimed.** That draft called it a philosophical first crossing. It is not.
  The template's own "never write a save, and never write game state" rule already says
  explicitly: *"Reading is unrestricted, and so is drawing: **spawn actors**, draw overlays, pose
  clones, play animations. The line is at persistence and at authoritative game state, not at
  pixels."* Spawning a cosmetic ghost is on the permitted side of that line, and TEVI and
  Pseudoregalia both already spawn things — so **the act is not new and needs no dispensation.**
  What *is* new, and what this ADR actually exists for, is the **mechanism**: those two adapters
  spawn from inside the game's own process through its engine API, whereas Crystal's adapter would
  poke **emulator RAM from outside**. That is `plans.md`'s separate "no emulator memory writes"
  non-goal, which is an emulator-specific rule about a blunt instrument, not a statement about
  spawning. Both rules are satisfied: the ghost stays cosmetic and non-authoritative, nothing is
  persisted, and the emulator-write gate is cleared by this ADR. **State the distinction this way
  round in future** — "we are choosing a cruder mechanism for a permitted act" is the accurate
  framing, and it keeps the actual risk (a blind write landing on moved memory) in focus rather
  than a philosophical one that was never in question.
- **Status:** Approved by the user 2026-08-17, in those terms — *"i want to actually spawn in as
  intended now for crystal, so we don't start doing this game with bandaids from the get go"*.
  **Implemented and confirmed on screen 2026-08-18** — the original status line here read "Nothing
  is implemented", true only on the day it was written.
  `adapters/emulator/pokemon/crystal/probes/object_slot_probe.lua` was the first, strictly read-only
  step; `meshghost_crystal.lua` now spawns a real object event beside the player mid-map, walks it
  with the game's own step animation, and drives it off `render_remote` over the bridge — a
  loopback ghost was watched moving and facing correctly. `verified.md`, `phases/phase9.md`.
  Two amendments to the terms below: the ROM guard is a warn (see the Archipelago bullet), and the
  scope now includes Emerald (see the 2026-08-18 ADR further down).
- **Context:** Emerald draws over the emulator: a `gui.drawPixel` overlay fed by a hand-rolled
  decode of the Brendan/May sprite out of ROM. That was the brief's own tier 1 and it shipped, but
  it re-implements what the game already does, and it is fragile in a way that has been *confirmed
  live* — the sprite decode reads fixed ROM addresses Archipelago's patch moved, and rendered as a
  striped block on a patched seed (2026-08-14, `risks.md`). Starting Crystal the same way would
  begin a new adapter with a known compensation already in it.
  **Crystal is unusually well suited to the alternative**, which is why this comes up now rather
  than for Emerald. Read from our own hash-verified `pokecrystal` build:
  - `SpawnPlayer` (`engine/overworld/player_object.asm`) is a short, legible routine: copy a
    `PlayerObjectTemplate` record into a map object slot, convert coordinates, choose a palette,
    then call `CopyMapObjectToObjectStruct`.
  - **`CopyMapObjectToObjectStruct` is generic**, not player-specific — the same shape as the
    `TrySpawnObjectEvent` finding recorded for Emerald's Union Room investigation in `ideas.md`.
  - There are **13 object slots** (`NUM_OBJECT_STRUCTS`) and the player is slot 0, so up to 12 are
    available in principle. How many are free *in practice* is what the probe measures.
  - The engine picks the palette from gender (`PAL_NPC_RED` / `PAL_NPC_BLUE`), so a peer's ghost
    can appear as Chris or Kris **using the game's own palette system** rather than a decode we
    maintain. Occlusion, animation and priority likewise become the engine's problem.
  This is the same principle Pseudoregalia arrived at the hard way and which is recorded as a
  standing preference: the ghost is a real pawn clone, and you trigger the game's own systems
  instead of reimplementing them.
- **What is NOT changed, and stays absolute:**
  1. **Never write a save.** Unchanged and non-negotiable. This is live RAM only, gone on reset.
  2. **The core never touches the game.** All of this is adapter-side; `core`/`relay` are untouched
     and remain game-agnostic, and the adapter still speaks only to its local bridge.
  3. **No gameplay authority.** A spawned object is cosmetic presence. It does not act, it is not
     simulated by peers, and nothing about it is negotiated — the `plans.md` non-goal on shared
     physics/collision stands unchanged.
- **The Archipelago condition, deliberately deferred — with a guard, not a promise.** The user's
  call 2026-08-17 was *"we worry about the base game for now, then fix/test archipelago patches
  later"*, which is reasonable sequencing. It is only safe because of what was measured the same
  day (`verified.md`): **Archipelago's Crystal patch rearranges WRAM non-uniformly** — no constant
  offset recovers it. A write aimed at a vanilla address on a patched ROM does not fail cleanly; it
  lands on whatever now occupies that address. Therefore:
  **the adapter must positively identify the ROM before it writes anything, and refuse to spawn
  otherwise** — degrading to no ghost, or to the overlay path, but never writing on an
  unrecognised ROM. Deferring Archipelago support is fine; writing blindly is not, and the
  difference between the two is this guard.
  **Amended 2026-08-18, on the user's explicit call (`verified.md`): the second half of that
  sentence is now a *warn*, not a *refuse*.** As shipped, `meshghost_crystal.lua` identifies the
  ROM, says which build it found, and runs anyway — Archipelago included, using its own measured
  address table. `MESHGHOST_CRYSTAL_STRICT=1` restores the refusal. What survives unchanged is the
  identification itself and the bound that makes attempting safe: object RAM only, never a save.
- **Open question that must be answered BEFORE implementing: call the routine, or imitate it?**
  Added 2026-08-17 on re-reading `adapters/_template/README.md`, whose "Where does this already
  happen normally?" section records precisely this failure from the day before — Emerald's Union
  Room investigation found `TrySpawnObjectEvent` was a *generic* engine function and then spent its
  effort working out how to **imitate what it writes**, never asking whether it could simply be
  **called**. The first draft of this ADR repeated that mistake, describing the decision as
  "write into a free `wObjectStructs` slot".
  **State the two options rather than assume the harder one:**
  1. **Call Crystal's own routine** — drive the emulated CPU to invoke `CopyMapObjectToObjectStruct`
     (or the path `SpawnPlayer` uses) with the arguments it expects. If workable, the engine does
     every part of the initialisation, including fields we have not identified, and there is
     nothing to keep in sync as understanding improves.
  2. **Imitate its writes** — reproduce the resulting bytes ourselves. Always possible, but it
     means owning a correct copy of what the routine does, and any field missed is a bug that
     looks like the engine misbehaving.
  **Neither is chosen yet, and option 1 is not assumed feasible**: whether a BizHawk Lua script can
  usefully call into GB code is a real question about the emulator's scripting surface, not a
  detail — it must be checked against BizHawk's own documented API rather than assumed, per
  `CLAUDE.md`'s rule against APIs from memory. **Ask the call question first and record the
  answer**; imitation is the fallback, not the default.
- **Options considered:**
  1. **Overlay, as Emerald does.** Proven, read-only, no gate to clear. Rejected for Crystal
     because it re-implements sprite decoding and palette choice that the engine already does
     correctly, and because the user's explicit goal was to avoid starting with that compensation.
  2. **OAM / VRAM injection.** The brief's middle tier, and the subject of Emerald's own
     investigation (`ideas.md`, Stage 1 ran 2026-08-14). Rejected: that investigation found the
     technique depends on fixed VRAM addresses that a reference project had already needed to
     re-tune between vanilla game versions — fragile before any patch is considered, and it still
     leaves animation and palette handling to us.
  3. **Spawn a real object event.** Chosen. The engine does the drawing, so palettes, occlusion,
     priority and animation come for free and stay correct across game states we have not thought
     about yet.
- **Consequences, accepted going in:**
  - **Object state is per-map, so a ghost will need re-spawning on every map load.** Expected, and
    the probe is written to measure exactly when and how that happens rather than assume it.
  - **A writer can race another tool's writes**, where two readers never could (`risks.md`). This
    is the real cost of the change and it is what the Archipelago work will have to confront.
  - **Slot exhaustion is a real failure mode.** Twelve slots is an upper bound, not a budget; busy
    maps use them. The adapter needs a defined behaviour when none is free.
  - **A new bandage risk of its own**: if spawning proves unreliable, the tempting fix is to fall
    back to drawing and leave both paths in. That would be a compensation, and belongs in
    `adapters/emulator/pokemon/crystal/BANDAGES.md` if it ever happens, not left unremarked.
