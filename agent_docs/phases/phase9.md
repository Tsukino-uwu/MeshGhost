# Phase 9 — Pokémon Crystal (GBC), spawn-based rather than drawn

**Status: in progress**, started 2026-08-17. The fourth game, and the first that renders a peer by
**spawning a real in-game object** instead of drawing an overlay over the emulator.

Numbered after Phase 8 (Emerald, dedicated) in the same "one number per stream of work" scheme the
earlier phases use. Nothing here renumbers anything.

## Purpose

Two things at once, and the second is why the user picked Crystal:

1. **A fourth adapter**, on a platform the project already understands (BizHawk Lua, as Emerald).
2. **Do it properly from the start.** Emerald draws its ghost with `gui.*` primitives and a
   hand-rolled decode of the player sprite out of ROM — the brief's tier 1, shipped and proven, but
   a compensation for not being able to spawn. Crystal *can* spawn, so it does. User's framing,
   2026-08-17: *"i want to actually spawn in as intended now for crystal, so we don't start doing
   this game with bandaids from the get go"*.

That decision crossed `plans.md`'s standing no-emulator-writes non-goal and required an ADR rather
than an inference — see `architecture.md`, 2026-08-17, including its correction that spawning was
never the forbidden part (the template permits spawning outright; the line is persistence and
authority). What the ADR actually buys is the cruder **mechanism** an emulator forces: writing RAM
from outside the process instead of calling an engine API from within it.

## What is settled

All evidence in `agent_docs/verified.md`, dated. Summary only here.

- **Access model: tier 2, external source decompilation** (`pret/pokecrystal`), built locally and
  **byte-identical to the ROM being played** — the same gate `make compare` provides for Emerald.
  Addresses are looked up and cited, never discovered at runtime.
- **GB/GBC differs structurally from GBA**: RAM labels live in floating sections, so **no address
  exists in the decomp source at all** and the decomp must be *built* to produce `pokecrystal.sym`.
  Toolchain in `environment.md`; nothing new had to be installed.
- **How to read it from BizHawk**: `System Bus` (CPU-addressed) and `WRAM` (banks laid flat) both
  expose bank 1 and agree exactly. Prefer `WRAM` — it addresses bank 1 unconditionally rather than
  following whatever bank is currently selected.
- **The in-game gate is `wMapStatus == MAPSTATUS_HANDLE` and `wBattleMode == 0`.** Both terms were
  established empirically and **both overturned a version that looked settled**:
  - `wMapEventStatus`/`wScriptRunning` toggle on *every walking step*, so a gate including them
    flickered dozens of times crossing one room.
  - `wMapStatus` stays `HANDLE` for the whole of a battle, so battles need their own term.
- **Object state is per-map and rebuilt from ROM on map load** — and **leaving a battle also passes
  through `MAPSTATUS_ENTER`**, so every encounter is a lifecycle event, not just every map change.
- **The engine adopts map objects we write.** `CheckObjectEnteringVisibleRange` replaced our `-1`
  with a real struct id — the game stating in its own terms that our bytes are legitimate. This is
  the ADR's chosen branch proven rather than assumed.

## The shape of the thing, learned the hard way

Worth stating plainly because three tests were spent discovering it:

- **Map objects are the source of truth; object structs are downstream.** Writing a struct directly
  renders a character but produces a **half-owned object** — collision follows the map coordinates,
  the sprite stays frozen where it was copied from, because the engine never recomputes it.
- **Adoption is not a general pass.** `InitializeVisibleSprites` runs at map load;
  `CheckObjectEnteringVisibleRange` runs per step and scans **exactly one row** — the one about to
  scroll into view. **Neither will ever pick up an object placed beside the player mid-map**, which
  is precisely what a ghost needs.
- **A free slot and a free tile are different questions.** Asking only the first put a ghost on top
  of an NPC.
- **Map objects and object structs are different arrays** (16 vs 13). Reading one and reasoning
  about the other made an occupied slot look free.

## Open

- [ ] **The central unsolved problem: trigger adoption at an arbitrary position.** Both known entry
      points are map-load or screen-edge. A ghost must be able to appear anywhere. Options not yet
      explored: invoke the engine's routine directly (the ADR's call branch, needs a decision about
      whether BizHawk Lua can usefully call into GB code — **check against BizHawk's own docs, not
      from memory**), or complete the map-object/struct linkage by hand now that both arrays and
      their cross-references are understood.
- [ ] **Does a ghost survive a battle?** Set up twice and answered neither time — the first run
      confounded by two scripts, the second by a false-positive adoption. Needs one script, one
      variable, watching a *specific* object rather than a count.
- [ ] **The struct reshuffle.** Inserting an object caused an existing NPC to be bumped out of the
      struct pool and stay invisible until re-triggered. Not exhaustion (a struct was free
      throughout); mechanism unknown.
- [ ] **Slot budget.** Indoor maps use ~4 of 16 map objects, an outdoor route ~9 — but the outdoor
      figure was measured with a writer running and needs re-measuring alone.
- [ ] **Gender/appearance.** The sprite comes from `ChrisStateSprites`/`KrisStateSprites` keyed on
      `wPlayerState`, so a peer's appearance is gender + state -> one sprite id. `OBJECT_PALETTE`'s
      encoding is not worked out (`PAL_NPC_RED` is 8, observed values were 0 and 1).
- [ ] **Nothing networked exists yet** — no bridge, no socket, no `get_local_state`. Emerald's
      socket layer transfers wholesale when the spawn question is closed.
- [ ] **Archipelago is deliberately out of scope** and guarded against, not merely deferred: its
      Crystal patch rearranges WRAM non-uniformly, so the adapter must identify the ROM before
      writing and refuse otherwise.

## Method notes worth keeping

- **Probes log to a timestamped file beside themselves.** A verdict that exists only in the Lua
  Console has to be copied back by a human.
- **Log what a proposed gate WOULD have decided**, alongside the raw values. Both gate corrections
  came from reading that column against real play; neither was visible by reasoning.
- **A dump of the neighbours beat a dump of the thing being debugged.** The reason nothing was
  being adopted was only obvious once the *game's own* objects were shown sitting unadopted too.
- **Identity, not slot state.** "The slot changed" and "my object changed" are different claims;
  conflating them produced a false success that invalidated a whole run.

## Links

`adapters/pokemon/crystal/README.md` (reader-facing) · `architecture.md` (the spawn ADR) ·
`verified.md` (all evidence, dated) · `pitfalls.md` (the BizHawk Lua lifecycle trap) ·
`environment.md` (decomp toolchain) · `licensing.md` (the `pret` family row)
