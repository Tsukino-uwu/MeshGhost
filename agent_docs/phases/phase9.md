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

## What was done, in order

Every step, including the ones that were wrong — the wrong ones are most of what was learned.
Evidence for each is in `verified.md` under the matching date.

**Groundwork (2026-08-17)**

1. **Licence-checked the whole `pret` family before reading any of it.** All of them carry no
   licence file, so the facts-only posture already recorded for `pokeemerald` applies unchanged.
   One row now covers the family (`licensing.md`).
2. **Built `pokecrystal` and verified it three ways** — the built ROM, the user's ROM, and the hash
   the decomp documents all match (`f4cd194b…`). This is what makes every address authoritative
   rather than plausible. **Nothing needed installing**; the one trap was that the build must run
   in the msys2 shell, whose failure mode looks like a broken compiler (`environment.md`).
3. **Pulled player/map addresses from `pokecrystal.sym`**, including the four consecutive bytes
   `wMapGroup`/`wMapNumber`/`wYCoord`/`wXCoord` that later served as a live fingerprint.
4. **`domain_probe.lua`** — established that `System Bus` and `WRAM` both reach bank 1 and agree.
   - *First run verdict was wrong*: it reported "ambiguous" because two domains agreed exactly.
     Aliasing domains are corroboration, not conflict; the logic was fixed.
   - *Also fixed*: the probe had no log file, so its verdict existed only in the Lua Console and
     had to be copied back by hand. All probes now write a timestamped log beside themselves.

**Understanding the object model (2026-08-17 → 08-18)**

5. **`object_slot_probe.lua`** — 13 object structs of 0x28 bytes, player in slot 0.
   - *Run 1* produced a single line in an empty bedroom and looked broken; a heartbeat was added so
     a quiet room reads as quiet.
   - *Run 2* caught the game's own `SpawnPlayer` at frame 454 and dumped the struct.
   - *Run 3* dumped **different bytes for the same event** — revealing that the first frame a slot
     is non-zero is *during* initialisation. Follow-up dumps at +1/+4/+16/+64 frames were added,
     and the earlier "ground truth" was marked provisional.
6. **Wrote the spawn ADR** (`architecture.md`), then corrected it twice: once to ask
   **call-vs-imitate** before implementing (a lesson the template already recorded), and once to
   narrow the claim — spawning was never forbidden; the emulator **mechanism** is what needed the
   gate.

**Making something appear (2026-08-18)**

7. **`spawn_test.lua`** — copied the player's object struct into a free slot. **A second character
   rendered, correctly, confirmed on screen.** First game-RAM write in the project.
8. **The user found the seam**: collision sat two tiles from the sprite, and an invisible blocked
   tile existed where nothing was drawn. Cause: map coordinates drive collision, screen coordinates
   drive drawing, and the engine never recomputed the latter — a **half-owned object**. The script
   had logged that and it was misread as "stationary, inconclusive".
9. **`spawn_test2.lua`** — wrote a *map object* instead and waited for adoption. Nothing happened
   for 600 frames.
   - *First attempt refused to write at all*: map object slot 1 held `SPRITE_CONSOLE`, the console
     in the bedroom. The guard was right; hardcoding a slot was not. Free-slot selection became
     a runtime scan, and the array is now dumped first.
   - *The dump explained the silence*, and not from our object: **the game's own dolls were also
     sitting unadopted.** Nothing was being adopted.
10. **Read `CheckObjectEnteringVisibleRange`**: it is not a general adoption pass but *"spawn
    objects as they scroll onto the screen edge"* — one row, only mid-step. An object beside the
    player can never match it.
11. **`spawn_test3.lua`** — placed on the row the engine actually scans. **`*** ADOPTED ***` — the
    engine replaced our `-1` with a real struct id.** The ADR's chosen branch, proven.
    - *Two side effects*: the ghost landed on an NPC's tile (a free **slot** was checked, never a
      free **tile**), and an existing NPC was bumped out of the struct pool and stayed invisible.
      Both undone by a map reload, which the user confirmed on screen.
    - *A claim was withdrawn*: this was first written up as pool exhaustion. A struct was free
      throughout, so it was a reshuffle, not exhaustion.

**Lifecycle (2026-08-18)**

12. **`ingame_gate_probe.lua`** — started on the title screen, walked through the whole lifecycle.
    - Found a **~2-second window** after loading where the map identity and player object both look
      valid while the world is still being built. Any data-plausibility check passes there.
    - *Gate correction 1*: including `wMapEventStatus`/`wScriptRunning` made it flicker dozens of
      times crossing one room — they toggle every step.
    - *Gate correction 2*: `wMapStatus` stays `HANDLE` through a **battle**, so `wBattleMode`
      became its own term.
    - Captured a **door transition** (objects rebuild from ROM) and a **battle exit** (also passes
      through `ENTER`).
13. **A false `ADOPTED`**: the player changed maps, our object was wiped, and the new map's NPC
    inherited the slot — answering "is the struct id set?" perfectly plausibly. The script now
    checks **identity** (sprite, coordinates, map) before claiming anything.

**Cross-cutting fixes made along the way**

14. **All four scripts moved off `event.onframeend`** to `while true do … emu.frameadvance() end`.
    A registered callback outlives its script, so stopping it left it running and every reload
    stacked another — the console spammed while the UI reported "0 active". **The shipped Emerald
    adapter had used the correct idiom all along**; nobody read it first. Written up in
    `pitfalls.md`, generalised into the template.
15. **Rules added to `CLAUDE.md` and the template** as a result: read `_template/README.md` end to
    end before starting an adapter; read the working adapter for the same host first; gate spawns
    on the game's own in-play signal; and give a new game its own phase file.

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

## The recipe — how to spawn a character, complete

**Solved 2026-08-18, confirmed on screen.** A player-looking character, created at a chosen
position at any time, drawn and animated by Crystal's own engine with **no drawing code**. Every
step below is necessary and none was guessable; each cost a live test.

1. **Copy a live NPC** — its map object *and* its object struct. **Not the player**: the player's
   `MOVEMENT_TYPE` is `SPRITEMOVEDATA_PLAYER`, meaning "driven by input", so the engine treats it
   as the input system's business.
2. **Cross-link the pair**: `MAPOBJECT_OBJECT_STRUCT_ID` <-> `OBJECT_MAP_OBJECT_INDEX`.
3. **Place relative to the player's own object struct.** `wXCoord`/`wYCoord` are the **visible
   window's origin**, not the player's position — conflating the two put a ghost next to Professor
   Elm.
4. **Compute `OBJECT_SPRITE_X`/`Y`; never copy them.** Adoption computes them, and copying a
   template's drew our object off the bottom of the screen while the engine drove it perfectly:
   `((map - window_origin) & $0F) * 16 - BGMapOffset`.
5. **Set `WONT_DELETE`**, or the engine culls the object once both its current and spawn tiles
   leave the visible window.
6. **For appearance, borrow the PLAYER's `SPRITE`, `SPRITE_TILE` and `PALETTE`.** `SPRITE_TILE` is
   a per-map VRAM allocation rather than a value, and the player's sprite is resident on every map
   by construction — so this needs no allocation, and **inherits the correct gender for free**,
   since Crystal picks the player's sprite from the Chris/Kris tables keyed on `wPlayerState`.

## Open

- [ ] **A ghost looks like THIS machine's player, not like the peer.** Showing a peer's own gender
      needs their sprite's tiles loaded on the local map — the `wUsedSprites` allocation question,
      deliberately deferred. Worth attacking once there is a real peer to represent.
- [ ] **Nothing networked exists yet** — no bridge, no socket, no `get_local_state`. Emerald's
      socket layer transfers wholesale. This is now the largest remaining piece, and the
      best-understood one.
- [ ] **Lifecycle: re-spawn on every map load AND every battle**, since a battle exit is also a map
      re-entry. Understood, not yet implemented.
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
