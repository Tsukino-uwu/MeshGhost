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

### Moving it — also solved, 2026-08-18

**A step is initiated in one frame; the engine plays out the other ~16.** Write this set once per
tile, only while the object is idle (`STEP_DURATION == 0`), and let go:

| Field | Value |
| --- | --- |
| `WALKING` | `4 + dir` |
| `DIRECTION`, `FACING` | `dir * 4` |
| `STEP_TYPE` | `2` |
| `STEP_DURATION` | `7` |
| `ACTION` | `2` |
| `MAP_X`/`MAP_Y` | **the destination** |

`dir` is `0` down, `1` up, `2` left, `3` right — derived from `InitStep`, which stores the value in
`OBJECT_WALKING` and computes `DIRECTION = (walking << 2) & $0C`.

**`MAP_X`/`MAP_Y` are the destination, written at the START**, with the sprite sliding to catch up
at 2px every 2 frames. This is the reverse of what the movement work was planned around, and one
read-only capture overturned it before any code was written — see the template's
"watch it before you PLAN against it".

**Interrupting a half-played step** is what produces a character that teleports while animating.
Hence the idle check.

## Must be dealt with BEFORE this adapter is ever released

Both are dev conveniences that are correct for a loopback session and wrong for a shipped one.
Recorded at the moment they were introduced (2026-08-18, on the user's question) rather than left
to be noticed by a user.

- [x] **DONE 2026-08-18: `LOOPBACK_OFFSET_X` now defaults to `0`.** A loopback session sets it
      explicitly (env var or a global before `dofile`); the shipped default is the correct one.
      Original note follows.
- [x] **`LOOPBACK_OFFSET_X` defaulted to `2` and had to default to `0`.** A loopback relay echoes your
      own state back, and this ghost has real collision, so without an offset the player stands
      inside something solid. Shipped as-is it would place **every real peer two tiles from where
      they actually are**, permanently and silently — the worst kind of bug, since it looks like a
      deliberate design choice rather than a leftover.
- [ ] **Trim the LuaSocket path fallbacks.** A release gives each game its own folder with its own
      `lib/x64/`, so the first candidate always wins; the `../emerald/` and working-directory
      fallbacks exist only for a source checkout and are inert but misleading in a shipped file.
      See `packaging/README.md` for what a game folder must contain.

**Two tiers, and a screen that fills (2026-08-19)**

The day started with the adapter spawning real objects and nothing else. It ended with a
character on every visible tile. In order, because the order is the lesson:

23. **Measured the ceiling instead of assuming it.** Real synthetic peers over the real relay,
    an engine-side probe, a wall-clock frame counter: **9 ghosts**, and the binding resource
    changes with the map (structs outdoors, map objects indoors). Under both sits the hardware:
    40 sprite entries at 4 per character = **10 characters on screen, ever**.
    `agent_docs/crowd-limits.md` holds the tables and the rig.
24. **The crowd broke three things, all one root cause.** A ghost took engine resources the
    engine expected back, and took them from the end the engine allocates from. NPCs popped in
    and out (ghosts held 11 of 13 structs — an NPC one tile away simply not drawn), off-screen
    ghosts were invisible walls, and the game's own cast lost the per-scanline sprite fight.
    Fixed by giving slots back beyond 8 tiles, reserving three structs outright, and allocating
    from the top down so the hardware drops a GHOST when it must drop someone.
25. **Then the cap became a feature.** The user's call: cap at what the hardware can draw so
    nothing flickers, and **draw the overflow** so every peer is still visible. Both halves
    shipped the same evening.
26. **The drawn tier, built by measurement at every step.** VRAM bank 1 (bit 3 of the OAM
    attribute), the game's own `wOBPals1` palettes, tiles decoded once and drawn as horizontal
    runs, and — after three failed attempts at deriving screen position from the engine's
    coordinates — **calibration against OAM every frame**, which is the trick that made it work.
    89 of 89 peers drawn at 60fps, user-confirmed.
27. **Facing and animation learned from the engine**, not from the sprite format: the adapter
    watches the engine render the local player and records which tiles, flips and offsets it
    used per facing, keeping the standing frame and two strides apart by their tiles.
28. **Occlusion the drawn tier does not inherit**: a text box is the game's own frame tiles at a
    fixed row (`$79`, from `LoadFrame`), a menu publishes `wMenuBorder*`. Both measured live,
    both clipped. The first attempt used the hardware window register and blanked half the
    screen during normal play — the game drives that register constantly.
29. **Collision became a rendering decision.** A peer that should not block is simply drawn
    instead of spawned: idle for five seconds, or being shoved into. That is why doorways clear
    without the adapter knowing where doors are.
30. **Cartridge-sourced sprites** (`OverworldSprites`, `05:4736`): a drawn peer can wear a sprite
    this map never loaded, which is the answer to the oldest item on this adapter.
31. **Three leaks the crowd found and nothing else would have.** A peer who left kept being
    painted; so did a peer who walked into another map; so did every drawn position after a map
    change. Each looked exactly like a peer standing still.

## Open

- [~] **A ghost looks like THIS machine's player, not like the peer — HALF DONE 2026-08-19.**
      A peer already sends the sprite id they are wearing, and the adapter now looks that id up in
      `wUsedSprites` (01:d154, 32 entries of `[sprite id, VRAM tile]`, packed and zero-terminated)
      and gives the ghost the peer's own sprite **whenever those tiles are already resident**,
      falling back to the local player's otherwise. Established with
      `MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE` (`FLAGS.md`): the ghost took `SPRITE_RIVAL`'s id **and
      its tile 108**, matching byte for byte the engine's own object wearing that sprite on the
      same map — a read-back of two fields nothing in the adapter derives from each other.
      **What is still open is the case that actually matters**: the other gender's sprite is never
      resident, since Crystal loads the map's own objects indoors and a fixed per-region list
      outdoors (`AddIndoorSprites` / `AddOutdoorSprites`), plus the local player's own. Making that
      work needs tiles put into VRAM that the game did not load — an allocation this adapter has
      so far avoided entirely, and the reason the item is not closed.
- [x] **Networking exists and works.** Bridge, socket, `get_local_state`, `render_remote` and
      `despawn_remote` are all in, and a loopback ghost was watched walking on 2026-08-18 —
      on the Archipelago ROM, which was the harder of the two targets.
- [~] **Lifecycle: re-spawn on every map load AND every battle — IMPLEMENTED 2026-08-19, not yet
      watched.** `wMapStatus` leaving `MAPSTATUS_HANDLE` is the event that means "the world is
      being rebuilt", and it covers both cases; the area check alone could not see a battle at all,
      because a wild battle begins and ends on the same map.
- [~] **Does a ghost survive a battle? ANSWERED FROM THE CODE 2026-08-19: no — and until today it
      took an NPC with it.** The array is rebuilt from ROM on the way back out, so the ghost is
      gone; the adapter's bookkeeping was not, and it pointed at a slot the game had refilled. The
      next render would have walked a REAL NPC around, and a despawn would have zeroed it. Fixed
      two ways (the status-change clear above, and `stillOurs()` — the cross-link both ways plus
      the sprite — checked before every write, which FORGETS rather than zeroes). Self-tested by
      breaking the cross-link from a probe mid-session: the adapter logged *"its slot is the game's
      again — respawning"* and rebuilt into a fresh pair instead of writing. **A real battle still
      has to be watched**, which is what `unverified.md` asks for.
- [ ] **The struct reshuffle.** Inserting an object caused an existing NPC to be bumped out of the
      struct pool and stay invisible until re-triggered. Not exhaustion (a struct was free
      throughout); mechanism unknown.
- [ ] **Slot budget.** Indoor maps use ~4 of 16 map objects, an outdoor route ~9 — but the outdoor
      figure was measured with a writer running and needs re-measuring alone.
- [ ] **Gender/appearance.** The sprite comes from `ChrisStateSprites`/`KrisStateSprites` keyed on
      `wPlayerState`, so a peer's appearance is gender + state -> one sprite id. `OBJECT_PALETTE`'s
      encoding is not worked out (`PAL_NPC_RED` is 8, observed values were 0 and 1).
- [x] **Superseded 2026-08-18 by the "Networking exists and works" item above** — this entry read
      "Nothing networked exists yet"; the bridge, the socket and all three handlers now exist and
      a loopback ghost has been watched. Kept so the contradiction is not re-read as live.
- [~] **Archipelago is IN scope and mostly measured** (reversed from out-of-scope, 2026-08-18).
      The patch does rearrange WRAM non-uniformly — +7, +6 and −0x2A in one build — so the adapter
      keeps one address table per ROM, selected by the header-title classifier, and an unmeasured
      entry stays `nil` so the adapter refuses rather than writing somewhere plausible.
      **All ten entries are now measured**: `wBattleMode` = `0x1234`, settled 2026-08-19 by
      fighting the rival in Cherrygrove — 0x015A read 1 in a wild AND a trainer battle, 0x1234
      read 1 then 2. See `verified.md` and `pitfalls.md`.
      **In scope does not mean equal priority** — settled 2026-08-18 (`plans.md`): Archipelago is a
      real goal but always comes after the original game. Vanilla is what the project promises;
      a patched ROM is best-effort until it is not.

## Animation completeness — the enumeration, 2026-08-19

**The user's ask, 2026-08-19:** *"base game crystal and emerald should try to fix up any/all
animations for everything the player/ghost needs. surf/fly etc and other things."* Enumerated
first rather than guessed, from the game's own terms (`documentation.md`, "What a character is
DOING"), against what the adapter puts on the wire today: `area_id`, `position`,
`orientation` (a cardinal string from `OBJECT_DIRECTION`), `anim` (`"walk"`/`"idle"`, from
`OBJECT_WALKING`), and `extras.sprite` (the object's `OBJECT_SPRITE`).

| What a player can be doing | How Crystal shows it | On the wire today | Spawned ghost | Drawn ghost |
| --- | --- | --- | --- | --- |
| Standing / walking, facing | `OBJECT_ACTION` STAND/STEP + `OBJECT_FACING` | direction + walk/idle | engine drives it | learned frames |
| **Bike** | `wPlayerState` -> `SPRITE_*_BIKE` | **yes**, via `extras.sprite` | only if resident (it is not) | yes, read from ROM |
| **Surf** | `wPlayerState` -> `SPRITE_SURF` | **yes** | only if resident | yes, read from ROM |
| **Surfing Pikachu** | `wPlayerState` -> `SPRITE_SURFING_PIKACHU` | **yes** | only if resident | yes, read from ROM |
| **Fishing** | `OBJECT_ACTION_FISHING` + `FACING_FISH_*` | **no** | no | no |
| **Bumping a wall** | `OBJECT_ACTION_BUMP` | no | no | no |
| **Spin tiles / the "!" emote** | `OBJECT_ACTION_SPIN` / `_EMOTE` | no | no | no |
| **Fly (landing)** | `OBJECT_ACTION_SKYFALL`, `STEP_TYPE_SKYFALL_TOP` | no | no | no |

> **Two rows of this table were later corrected** — see *Closing the rest of the action classes*
> at the end of this file (2026-08-25). The emote is not an action on the player at all, and
> turning in place, Teleport and Dig belong in the list and were missing from it.
| Door / warp / Fly (leaving) | the map is rebuilt | `area_id` changes | despawn + respawn | same |
| Battle | the player leaves the overworld | **nothing is sent** (the in-play gate) | ghost freezes where it was | same |

**The shape of the fix, and it is one change rather than eight.** Every row marked "no" above is
the same missing pair: the adapter reads neither `OBJECT_ACTION` (`0x0b`) nor `OBJECT_FACING`
(`0x0d`), although it already knows both offsets (`F_ACTION`, `F_FACING`) and uses them when
writing a step. Send those two bytes as `extras`, and:

- a **spawned** ghost gets the animation for free by having them written onto its struct — the
  engine plays fishing, bump, spin, emote and the Fly landing itself, which is the whole point of
  the spawned tier;
- a **drawn** ghost can select the frame directly, because `OBJECT_FACING` already *is* an index
  into the frame list — no learning from the player needed for the cases the player is not
  currently doing.

**What that does NOT fix**, and should not be conflated with it:

- **A spawned ghost still cannot wear a sprite this map never loaded**, so bike and surf reach a
  spawned ghost only when the local player happens to be doing the same thing. The drawn tier
  already reads the cartridge, so it is unaffected. This is the same open VRAM-allocation item
  above, not a new one.
- **A peer in a battle sends nothing at all**, so their ghost freezes rather than animating. That
  is a lifecycle question (Emerald answered its version by dropping the bridge), not an animation
  one.
- `anim` as a wire field is redundant once the action byte is sent; it stays because the contract
  is game-agnostic and `anim` is opaque to the core.

Not implemented. Enumerated, cited, and scoped so the next session can close it one row at a time.

## The night the two tiers were made to move properly — 2026-08-21/22

A single long session, all of it on Crystal, driven by the user watching a loopback ghost on
**Route 39** — chosen deliberately as *"the most demanding one in the whole game… a big route, and
fills up things due to having a lot of npc's"*. That choice is responsible for at least one bug that
no quiet map could have exposed.

### What was fixed, each from a measurement

1. **The spawned ghost never animated** — and it depended on the map. `spawnGhost` copies a live
   NPC's whole struct as a template, `OBJECT_FLAGS1` included, and Route 39's templates are
   `SPRITEMOVEDATA_STILL` objects whose flags are `FIXED_FACING | SLIDING`. `SetFacingStepAction`
   tests `SLIDING` first and never advances `OBJECT_STEP_FRAME`. Flags are now normalised at spawn.
   After: ghost and player step frames match 7/7, 8/8, 9/9.
2. **A peer that stopped sending was rendered forever.** Nothing timed a peer out; the rig exposed it
   because the core is issued a new player id on every relay reconnection. Now dropped after three
   seconds. **A shipped bug, not a rig artefact** — a peer whose game crashed would have been painted
   at their last position for the rest of the session.
3. **The painted tier's position was an alias.** Every term is byte arithmetic, so a screen position
   only exists modulo 256; `screen -224,-196` was `32,60` in disguise and the tier discarded itself as
   off-screen. Both branches now fold into one `[-16, 240)` window.
4. **A ghost two tiles behind could only be snapped**, and snapping waits for a settled camera — so
   during continuous walking it froze and then jumped. Short deficits are now walked.
5. **The painted tier's whole motion model was rebuilt** (see below).
6. **The painted tier drew over map transitions** — because BizHawk's drawing layer persists and the
   tier was falling silent rather than clearing.
7. **Both adapters stalled the game once a second by logging.** `console.log` plus a per-line flush
   cost 63–83ms on the emulator's own thread. Fixed in Crystal, Emerald, and all 36 probe files.

### The painted tier's motion, and three wrong turns

The spawned tier is smooth because the ENGINE interpolates it. The painted tier has to reconstruct
sub-tile motion, stride phase and camera tracking by hand, from data that arrives quantised and late.
Three attempts were made and reverted in one evening — a glide added to the destination, a frozen
calibration, and dead reckoning — and **all three added or froze a term on top of a position whose
own behaviour had never been measured**. `pitfalls.md` carries each with its trace.

**The model that works** paints the peer at

```
playerScreen + (peerTile − playerTile)×16 + peerOffset − playerOffset
```

with every player term read from one frame, and offsets measured from the DESTINATION, because
`MAP_X`/`MAP_Y` are written at the *start* of a step. The camera appears on neither side, because it
moved the player and the world together. The only missing quantity was the peer's sub-tile progress,
which only the peer knows — now sent as `extras.prog`, derived from the engine's own countdown as
`(8 − duration) × 2`.

**One knob remains**, `playerHistory.age`, and its direction is documented in the source: too high
and the ghost races its destination, too low and it snaps backwards at each tile boundary.

**`extras.prog` paid twice**: added for positioning, it also fixed the painted stride, because both
were asking the same question — how far through its step is this peer. Sending the fact rather than a
symptom is why.

### The hardware (OAM) tier — built, proven, unjudged

Added on the user's request as the middle rung of **spawned → hardware → drawn**. A peer whose tiles
are resident is written into `wShadowOAM` so the PPU draws it. The one question no source could
answer — whether a write at the adapter's frame boundary survives to the VBlank DMA — was answered by
reading entry 39 back from the `OAM` domain: **it does**, at no measurable cost.

It is **shipped off** (`MESHGHOST_CRYSTAL_OAM_OVERFLOW`) and nothing about how it LOOKS has been
confirmed. Its honest case is also smaller than it first appeared, and the register says so: it adds
**zero to one character** (the engine already uses 34–36 of 40 entries outdoors and all 40 indoors),
and it does **not** get occlusion free — a Crystal text box is background tiles with the priority bit
clear, so a hardware sprite draws in front of it.

### Method lessons worth more than the fixes

- **Test on the busiest map.** Route 39 exposed a template-dependent bug that any quiet room would
  have passed.
- **Instruments that agree can share a blind spot.** Three detectors read clean while the user saw
  twitching; all three measured POSITION, and the faults were in TIMING and in the IMAGE.
- **The rig's settings are part of the experiment.** A restart at the relay's default 20Hz instead of
  the documented 100Hz widened step-start lag from 3–5 frames to 0–6 and was misattributed to the
  adapter.
- **`pitfalls.md` already held three of the evening's answers** — the logging stall, probe globals
  outliving their probe, and the `goto_map` warp — and each was rediscovered the expensive way
  because it had not been read.

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

`adapters/emulator/pokemon/crystal/README.md` (reader-facing) · `architecture.md` (the spawn ADR) ·
`verified.md` (all evidence, dated) · `pitfalls.md` (the BizHawk Lua lifecycle trap) ·
`environment.md` (decomp toolchain) · `licensing.md` (the `pret` family row)

## The night the drawn tier's facing was fixed — 2026-08-22

A single session, all of it on Crystal's painted tier, driven by the user watching a loopback ghost
in New Bark Town and walking in and out of a house. **Three defects were fixed; one change was
built, measured and deliberately reverted.** The facing bug took six attempts and is the reason
this entry exists — not for the fix, which is small, but for how badly the first four went.

### What was fixed

1. **A drawn ghost appeared in the wrong place on the way out of a door.** The painted position
   measures the peer against the player as they were `age` frames ago; the ring still held the
   PREVIOUS map's samples, so the first painted frames placed the ghost against a world that was
   gone. It now WAITS until enough samples describe the current map. Confirmed by the user.
2. **The drawn ghost faced the wrong way, differently every session.** Two independent layers, both
   invisible to reading the code — see `pitfalls.md`. Confirmed by the user and, separately, by an
   invariant printed in the adapter's own log.
3. **A `local` used above its declaration was caught before shipping**, for the third time in this
   file: `drawFrames` is declared ~400 lines below the facing learner, so naming it there would
   have been a silent nil global throwing every frame.

### What was measured and NOT shipped

**The transition hold spends 30 frames after the world is ready rather than during the crossing.**
`probes/paintgate_probe.lua`, 14 crossings, zero variance: ticking it during the crossing brings
the tier back **5 frames late going in, 2 coming out**, against ~30 today. It was built, watched,
and reverted — it paints ~25 frames of the arrival that were previously blank, and the user judged
the result worse. **The lateness and the exposed window are the same 25 frames seen from two
sides**, and shortening the hold without first making that window stable trades one defect for a
worse one. The crossing's own 33-37 blank frames are untouched by any of this and dominate what the
user calls "a bit slow".

### Method lessons, which cost far more than the fixes

- **Build the instrument before the first attempt, not after the fourth.** Four facing fixes were
  shipped on inference and all four failed on screen; the trace took ten minutes and answered in
  eight lines. Two of its findings contradicted a theory that had already shipped.
- **A fault that MOVES between cases without the responsible code changing is a lifetime
  problem, not a logic one.** The facing bug appeared on left, then right, then up, and looked like
  a regression after every unrelated change — because a cache that keeps the first samples and
  never clears re-rolls which case is poisoned on every reload.
- **"It worked at first and then degraded" was the single most useful sentence of the session.** It
  is a statement about accumulated state, and it is what identified a contaminant that needs ~2,000
  frames and a ghost facing elsewhere before it can appear.
- **Log the INVARIANT, not the values.** Printing each accepted frame's view beside the one its
  facing requires turned the log into a pass/fail the agent could read, instead of a symptom the
  user had to characterise a fifth time.
- **A revert can be wrong.** The frame-pairing fix was reverted for "making it worse" when it was
  half of a two-part fix whose other half did not exist yet. `CLAUDE.md` already says to try the
  UNION after several single-variable negatives; that rule applied and was not followed until the
  trace forced it.
- **Remove the instrument before believing the subject.** A wiggle was blamed on `door_loop.lua`,
  which drives the d-pad, while the user was testing by hand. That guess was wrong, but the rig
  genuinely should not have been left loaded — and the bisect that followed (revert to HEAD, ask)
  is what should have happened first.

### Where the two tiers stand at the end of 2026-08-22

**The user's own summary, and the most honest statement of this adapter's state:** the session went
from *"2 broken ghosts"* to the **drawn** ghost being *"perfect but not animated"* and the
**spawned** ghost *"somewhat decent but still some yank"*.

That is worth reading twice, because it inverts the tier ladder. `architecture.md`'s spawn -> OAM ->
drawn order exists on the reasoning that the engine does the work better than we can: a spawned
character gets animation, collision, occlusion and lifetime for free, while a painted one
reimplements each. On Crystal today the painted tier is the better-behaved of the two — its
position, facing and placement are each confirmed 1:1 — and the engine-driven one still yanks.

**What that suggests about where the remaining work is.** The painted tier's faults were all in code
we own and were closed once measured. The spawned tier's remaining yank is in how we drive the
engine's own step machinery, which is a smaller surface and has resisted several sessions. It is
also the tier that most peers actually get, so its yank is what a real session looks like.

### Fixed on 2026-08-22, all user-confirmed on screen

| Fault | Cause | Confirmed |
|---|---|---|
| ghost in the wrong place leaving a door | the aged reference still described the previous map | *"yes this is fixed"* |
| facing swapping between two views | the learner read its own ghost's sprite entries as the player's | *"seems to work properly now"* |
| right-facing drawn 8px left | parts measured from OAM entry 0, which mirrors with the sprite | *"absolutely perfect/static in all directions"* |
| ~65 frames blank after a crossing | the hold was counted down after the crossing, never during it | *"think it looks pretty good"* |

### Still open on this adapter, in the order worth taking them

1. **The drawn tier's stride animation has never been seen running.** Its summary line read
   `0 on a walk frame` all evening, and only one frame per facing was ever captured. A ghost that
   is perfectly placed and perfectly facing but sliding is the next visible gap.
2. **The spawned tier's yank**, which is now the worse of the two tiers and the one most peers get.
3. **The spawned ghost drifting** when the peer looks up and then to the side — reported the same
   evening, deliberately NOT folded in with the drawn tier's 8px offset, because the spawned ghost
   is placed by the engine from its struct rather than through `readPlayerOamFrame`. Same symptom,
   different path; it needs its own measurement.
4. **The drawn ghost appears ~8-13 frames after the player** on a crossing: the hold's leftover
   (2-5), the readiness gate (3), the wire (3-5). Only the first two are ours.
5. **`extras.act`** remains on the wire and untested.

## The session that made the drawn tier animate — 2026-08-22 (later)

Started from `status.md`'s first open Crystal item: *"the drawn tier's stride animation has never
been seen running"*. Ended with that closed and user-confirmed, the spawned tier's drift and step
length fixed, Emerald's adapter rescued from not compiling, and a whole class of stutter traced to
the wire rather than to any renderer. It also produced more instrument failures than any session so
far, which is the part worth reading.

### What was fixed, and what settled each

| Fault | Cause | Settled by |
|---|---|---|
| the drawn tier never animated | a sprite has SIX views, not three, and the `offset >= 12` guard rejected every stepping frame as another character's tiles | measured on two sprites at two different tile bases |
| the stride ran at the wrong speed | `OBJECT_FACING` counts 0..3 THROUGH a step, so reading it per frame mirrored the character mid-foot-plant | latched once per burst; cadence printed against the player's, one character a frame |
| the spawned ghost slid off its tile | `OBJECT_STEP_DURATION` was 7, walking 14px across a 16px tile | a standing ghost re-anchored to its own tile, which measured the error at 2px every step |
| Emerald did not compile at all | 202 declared names against Lua's limit of 200 — a silent non-load | folded seven constants onto two tables |
| the drawn tier staircased at shipped settings | whole tiles on the wire, so the core interpolated between two identical values | 1838 of 1911 messages carrying no movement; 521 of 521 moving 1px after |

### The sprite layout, which was the root of the animation work

A walking sprite is **six views of four tiles**, relative to the character's own tile base: three
standing at `base + 0..11`, three **stepping** at `base + 0x80 + 0..11`. Confirmed on the player
(base 0x00) *and* an Olivine NPC (base 0x30), so the 0x80 is relative and not an absolute block. In
ROM the six are contiguous — tiles 0-11 and **12-23** — so a sprite's graphics are 24 tiles even
though the sprite table's own size field reports 12. `documentation.md` has the tables.

The guard that discarded all of it had been added the same morning, for a real reason (the learner
was adopting another character's OAM entries) and with the wrong boundary. **It was right about the
danger and wrong about the number**, which is the most dangerous shape a guard can have.

### Two things that were tried and are now CLOSED, not open

- **Giving a painted peer a collision body** by parking a real object struct out of sight. The write
  holds (1 rewrite in 480 frames) but 160 is the engine's own off-screen value and Crystal treats
  such an object as having left the map: not drawn AND not collided with. `verified.md`.
- **Giving a ghost the player's step type.** It makes the pace a true copy (17.2 against 17.1
  frames per tile) and **scrolls the camera**, because that is what that step type is for. The pace
  difference is therefore a requirement, not a defect — and reverting the code did not undo it, the
  user had to load a savestate. `pitfalls.md`.

### The instruments, which cost more than the bugs

Six separate false readings, each of which changed a decision; two caused a revert or a change
shipped on a wrong justification. Written up in full in `adapters/_template/probes.md`. The one that
generalises:

> **An instrument reports its own coverage, not just its findings** — how many samples it took, how
> many it discarded and why, and over what window. A probe that prints only what it found cannot be
> told apart from one that found nothing because it was looking in the wrong place.

Two more worth carrying separately:

- **The rig is part of the experiment, for the third recorded time.** Crystal had no
  `run-core-crystal.bat`, so every session silently got an autostarted core on shipped defaults.
  Two rounds of renderer work went into a stutter that was the 250ms interpolation.
- **A writing probe must prove it found its target before it writes.** One matched about 1.5 of the
  4 sprite-buffer entries it meant to blank and corrupted whoever else held them — reported by the
  user as a regression in the commit that had just landed.

### Where it stands at the end

**Confirmed on screen, at the dev rig's settings** (`verified.md`): the drawn tier animating and
tracking 1:1; the spawned tier with no drift, no snap and no teleport in ordinary walking. The
user: *"this currently looks good/perfect i think ? its just the spawned ghost trailing behind a
tiny bit when moving now"*.

**Open, all measured rather than described** (`unverified.md`, `status.md`):

1. **The drawn tier at SHIPPED settings.** The wire is now smooth (521 movements, 517 at 1px) and
   the stride derives from it, but the last on-screen judgement was ambiguous — *"legs look wrong"*
   or *"no change"*. The contradiction that was blocking this is **settled, 2026-08-23: there was
   none.** See below; the stride can be judged on the next live run.

### The cadence contradiction was an instrument, not a finding — 2026-08-23

The blocker was *"the trace says the ghost never steps, the counter says 214 of 507 walking
frames"*. Re-read against the log the numbers came from
(`logs/meshghost_crystal_20260822_221839_11136.log`), **the two agree and always did**:

- The **cadence trace** does show the ghost stepping — `...llllLLLLLLLLLllllllllllLLLl...` against the
  player's `...lllLLLLLLLLllllllllLLLL...`, uppercase bursts in step with the player's, for every one
  of the four directions. It was never the instrument reading zero.
- The zero came from a **third** readout nobody counted as one: `nWalking` in the `tiers:` summary
  line — a per-frame local, printed once a second. It read `0 on a stepping frame` in **439 of 441**
  samples. That is the expected result, not a fault: the ghost is walking for ~1% of a run's frames
  and steps on ~45% of those, so a single frame sampled once a second should find it about twice in
  441 tries. It found two.

Fixed in the adapter rather than left as a caveat, because a zero that means "I looked once" cannot
be told from a zero that means "it never happened":

- The stepping count is now **cumulative** and taken **at the latch that selects the stepping view** —
  the value the renderer actually acts on. The old counters tested a step-progress *band*, which is
  the renderer's input: the latch, the turn rearm and `moving` all sit between that band and the
  screen, so the band can read a healthy 45% while nothing steps.
- Both are logged, on adjacent lines, each with the total it was counted out of. **The gap between
  them is the diagnosis** — it separates "the peer sent nothing to step on" from "the renderer
  refused", which look identical on screen. The refusals are broken out as mid-step / idle / held by
  a turn.
- The per-frame `nWalking` is deleted, so no once-a-second sample of a two-frame cadence remains in
  the log to be misread a second time.

Compiles (`dev-scripts/bizhawk-syntax-check.lua`, 17/17); **not yet run in a live session** — the new
lines are unread until the next one. Entries 5 and 6 in `adapters/_template/probes.md`.
2. **The spawned tier trails ~4.3 frames** starting each step. 1.5 frames is the wire, the rest the
   adapter's pipeline. Structural for an engine-driven ghost, which cannot be told "you are part-way
   through a step".
3. **A respawn teleports on the first tile** — FIXED 2026-08-23, and this description was
   BACKWARDS: measured, the object is placed on the peer's CURRENT tile while the drawn model is
   one tile behind it, not on a tile the peer has left. `verified.md`.

## 2026-08-23 — the drawn tier's motion, and a full session spent inside instruments

**Outcome: user-confirmed clean at the dev rig** (`verified.md`), after nine distinct defects across
three layers. The full symptom → cause → fix table is in `pitfalls.md`; the instrument methods, which
are the more reusable half, are in `adapters/_template/probes.md`.

### The shape of the session, which is the lesson

The reported symptom was one word, *"jittery"*, and it covered **both position and animation**. It
was read as position, and five instruments plus four rebuilds of the motion model followed, each
measuring clean while the user kept saying it looked wrong. The user disambiguated it themselves —
*"weird choppy animation speeds"*, then *"position wise its following perfectly"* — and the animation
cause was found in one step, in a histogram that had been printing all along.

**The question that would have split it in one sentence, and is now the default for anything
visual:** *is it in the wrong PLACE, or in the right place doing the wrong THING?*

### The three layers, and why each hid the next

1. **The model** (the ghost's world coordinate). Seven defects, ending in a design that commits
   whole tiles, decides only at tile boundaries, and copies the camera's own per-frame delta.
2. **The paint** (world coordinate to screen position). The screen origin came from the player's
   tile plus step progress — two values that hand over on different frames — and the old renderer's
   ghost term shared that machinery, so the seams cancelled. A seamless model exposed it. Now
   painted in the camera's own frame: `model - camera + K`.
3. **The animation**. Six defects, including a dead local, a sign bug that pinned two directions,
   and legs gated on the wire's flag instead of the model's own clock.

Each layer read clean while the one beneath it was wrong, because every instrument was built in the
layer's own coordinate frame. **The instrument that broke the deadlock watched the painted screen
position** — the number the eye actually watches.

### Facts about Crystal established, all measured on the running ROM

Recorded in `verified.md`: a tile is 8 ticks of 2px and the scroll never moves 1px; both scroll
registers run inverted to map pixels; the movement tick is not on a fixed frame parity and does tick
on consecutive frames; the registers are rebased (an 8px diagonal jump at each walk start) and a
rebase must not be painted as motion.

### Rig work that came out of it

`run-core-crystal-shipped.bat` / `run-relay-loopback-shipped.bat` (the shipped case now has a named
rig); the core logs its own smoothing settings; `square_drive` takes `MESHGHOST_SQUARE_SIDE`,
`_DIRS`, `_LOAD_STATE` and `_FLOW`; `MESHGHOST_CRYSTAL_GHOSTS_PASSABLE` removes the collision
confound; and `square_drive` is in the syntax checker's list, which it should always have been.

## Closing the rest of the action classes — 2026-08-25

The 2026-08-19 enumeration above scoped this as "one change rather than eight" and the 2026-08-23
bump fix was the first row of it. This is the rest, and the enumeration turned out to need two
corrections before it could be implemented.

### What the decomp said that the enumeration had wrong

**Read before measuring**, per CLAUDE.md, and both of these would have been expensive to discover
on screen:

1. **The `!` emote is not an action on the player.** `SpawnEmote` (`engine/overworld/map_objects.asm`)
   creates a **separate map object**, flagged `EMOTE_OBJECT_F`, that parks itself two tiles above
   the character; `DespawnEmote` deletes whichever object carries that flag. A player's own
   `OBJECT_ACTION` therefore never reads `EMOTE` (8) — and the adapter had 8 in its
   `ACTIONS.peer` allow-list, meaning a peer that sent it would have had its ghost's **body
   replaced** by the emote box (`FacingEmote` substitutes four absolute tiles for all four of the
   character's parts) and drawn on its own tile rather than above it, because the two-tile Y offset
   is set by the emote object's movement function, which a written action byte does not go
   through. Removed, with the citation, rather than left as a harmless-looking entry.
2. **Turning in place is `OBJECT_ACTION_SPIN`**, and it is by far the most common member of the
   family. `TurningStep` (`engine/overworld/map_objects.asm`) sets it for a 2 + 2 tick turn, so a
   character that merely looks around is animating without moving. The enumeration listed `SPIN`
   as "spin tiles" only, which made it look rare and low-value; it is neither. **Teleport and Dig
   are also `SPIN`**, and Dig alternates it with `SPIN_FLICKER` — which sets `OBJECT_FACING` to
   `STANDING`, i.e. the engine draws nothing at all that tick.

### The implementation is one rule, not five branches

`OBJECT_FACING` is literally the index into `Facings` (`data/sprites/facings.asm`) — the table the
engine looks up to decide which sprite parts to emit. So the drawn tier does not need a case per
animation: it needs to read the peer's facing byte the way `_UpdateSprites` does. That is
`facingFrames.pose` in `meshghost_crystal.lua`, and the bump special case it replaced is exactly
what it still returns for action 3.

- `0x00`–`0x0f` → direction is the byte over four, stride the low two bits, stepping on odd
  strides. Covers `BUMP`, `SPIN` and `SKYFALL` without naming any of them.
- `0x10`–`0x13` → fishing: the standing view for that direction, plus the rod.
- `0xff`, or action `SPIN_FLICKER` → the engine draws nothing; neither do we.
- actions 0/1/2 → unchanged. The position-derived pose is **better** there, because it is
  phase-locked to the peer's own sub-tile progress rather than to a byte sampled at the send rate.

The **fishing rod** is the one part that is not the character's own art: its tile id is absolute,
so it comes from the two shared tiles the game loads on demand — which on a receiving machine hold
the jump shadow, not the rod, unless the local player happens to be fishing too. The drawn tier
reads `FishingRodGFX` from the cartridge instead (`41:4560`, from our own hash-verified build),
gated on the ROM classifier saying V1.0: unlike the sprite table this address has no cheap
signature to check, and two tiles of art look like any other two tiles. On any other build the
body is drawn and the rod is not, which is a missing detail rather than a wrong one.

### What is NOT closed by this

- **Nothing here has been watched on screen.** Measurements and derivations only —
  `agent_docs/unverified.md`, 2026-08-25.
- **The Fly landing's fall is not rendered**, only its double-speed walk cycle. The drop itself is
  `OBJECT_SPRITE_Y_OFFSET` sweeping down from high above the tile, and that offset is not on the
  wire. Same for Teleport's and Dig's rise and descent.
- **The spawned tier's spin is free-running**, not phase-locked: it is handed the action byte and
  the engine spins it on its own clock, so a spawned ghost spins the right way at the right speed
  starting from wherever its own step frame was.
- **A peer's emote is not rendered at all**, and cannot be by sending the player's action byte —
  it would need the separate object to be noticed and sent as its own thing.

## 2026-08-25, evening — eleven fixes, three reverts, and a lag that was the console

One session, driven start to finish by what the user could see. Every fix below came from a
measurement that killed a theory first; the reverts are kept because each was the obvious idea.

### The chain of faults, in the order they surfaced

1. **A surfing peer was drawn as a walking character on the sea.** The compare rig localised it in
   one observation — spawned correct, drawn wrong, same peer, same frame — which excludes the wire,
   the sprite id and the state by construction. `MESHGHOST_CRYSTAL_SPRITE_TRACE` (built for this)
   showed both tiers pointed at VRAM base 0, so the source was right and the pixels were wrong.
   Cause: the drawn tier's decoded-tile cache had **three references in the file — declare, read,
   write** — while its comment claimed a map load cleared it. A surf mount rewrites the player's
   tiles in place: same base, new graphics, no map load. Invalidation now keys on `wUsedSprites`.
   It also explained the *"swapping, only when walking downwards"* report that two earlier theories
   could not: only indices already cached were stale.
2. **A biking peer's spawned ghost walked at half pace and snapped.** `StepVectors` has three gaits
   indexed by `OBJECT_WALKING & $0F`; the adapter hard-coded the normal row. Measured on the running
   game: biking holds group 8 (fast, 4px/4 ticks). `extras.gait` now carries the group.
3. **A 3px slide at every stop.** KPARK (per-park decomposition) showed all run deltas zero with the
   disagreement appearing at the stop itself; KSETTLE showed it at stillness 8 and gone by 16 — an
   8-frame settling transient in the player-side reference that the corrector was chasing down and
   back. The nudge now waits for 8 frames of stability.
4. **The spawned ghost trailed the drawn one.** STEP_LAG decomposed it: the boundary handoff, which
   the engine's own walkers never pay. Chaining a consecutive step at the last tick — the engine's
   own `CONTINUE_WALK` mechanism — removed it. The chained step is owed its final tick: **+1**.
5. **The two tiers ran at different speeds on the bike.** The catch-up band (12/6px) and the commit
   cushions were measured at the walk; the hover they sit outside of scales with the gait, so the
   bike's ordinary hover reached the arming line and catch-up cycled hot. Restated in **strides**.
6. **The drawn ghost pedalled twice too fast.** `SetFacingStepAction` advances the stride once per 8
   video frames off `OBJECT_STEP_FRAME` — a fixed clock, gait-independent — and the drawn tier
   derived stand/step from step progress instead, a partition that is exact at the walk only
   because the two clocks align at 16 frames a tile. The pose now reads the peer's `face` byte.
7. **Quick reversals turned early in open ground.** The tier stepped toward the peer's LATEST tile;
   trailing by the echo, that truncates a reversal and the turn tile is never visited. The ghost now
   walks a small **queue of the peer's path**, turn tile included.
8. **A second ghost after a respawn.** Not an orphan (`orphan_probe` found one tracked body): the
   promotion hold matched EXACT coordinates, and a peer promoted while moving is never exactly
   there, so the hold ran its full 8 frames every time. Matched within a stride now.

### Three reverts, each the obvious next idea

- **Delaying the drawn model's camera BEAT to match the spawned tier's floor** — twice, at 3 and 2
  frames. Both sawtoothed (the paint's cancellation needs the model moving on live camera frames),
  and the second froze the ghost outright. The lesson was already in the file from the other side:
  the model's beat and the paint's origin are one decision. What worked instead: delay the compare
  copy's **inputs** by three arrivals, leaving every clock live.
- **Two overlay optimisations** (whole-character rectangle decomposition; a one-block draw mode)
  built on the theory that compositing caused the lag. Primitives went ~116/frame -> ~2 and the
  stutter never moved. Both reverted, with a note at `drawCharacter` so the path is not
  re-optimised on that evidence.

### The lag, and the methodological failure behind it

Heavy stutter, while BizHawk reported a flat 60fps and the adapter measured 25ms of each second.
The user named the class from memory — *"probes have lagged things before"* — and asked for the
subtraction. It was the **Lua console**: append cost scales with buffer size, a day of banners had
grown it huge, and the stall lands on the UI thread where no in-Lua timer can see it. Five probes
were live at once while the user was being asked to judge frame-accurate motion, which is the
`CLAUDE.md` rule about auditing a probe's cost, failed for a whole session. Mechanism and new
rules: `pitfalls/by-host.md`. The compare rig's per-frame instruments now sit behind
`MESHGHOST_CRYSTAL_COMPARE_STATS`, off by default.

### What closed it

The user, riding a 9x9 on the bike with the full stack live: *"yee its smooth to play/control as
well now. and looks smooth visually"*, then *"moving perfect, surf working, bike working etc etc"*.
Agent numbers on that same lap: furthest behind 0px, K drift 0 over 7 parks, 0 catch-up, 0 resyncs.

## Catch-up record, written 2026-09-01 — the active phase's missing week

This is the ACTIVE phase file and its record stopped at 2026-08-25. Backfilled from the commit
log; evidence in `adapters/emulator/pokemon/crystal/VERIFIED.md`, `UNVERIFIED.md` and `FLAGS.md`.

- **2026-08-26 — fishing confirmed; the Fly arc end to end.** The "!" was two faults in one
  symptom (`21085ac`, `6c3aa33`). Then Fly, from "does not touch the player's object" to
  confirmed on screen, landing spiral included, with the peer becoming the Pokémon mid-flight
  and teleport queued with its whole envelope (`e95ce49` … `9b299f3`). Ledge hops confirmed on
  both tiers; Dig and Escape Rope confirmed; three decomp-shaped guesses refuted by measurement
  (`c4b6ea9`, `d6bd684`, `d16e97e`, `aa237d0`).
- **2026-08-26, the patched cartridge** — its extra fourth gait measured (`43ceab5` and kin),
  the camera's two dead bytes on that build, the third ghost that was never in the game, the
  idle rule raised to a minute, stand-only learned facing.
- **2026-08-27 — cross-map ghosts.** Crystal learned the game's own map connections
  (`f09e3b7`, `80316b2`, `43b44b8`, `d62020f`, `6bccb3c`): a peer on a connected neighbour map
  renders through translated coordinates; a seam crossing no longer un-draws peers; derived
  facing kept a stale mirror and was fixed. GAIT_PX per engine tick vs video frame, and the
  camera plausibility test taught the fourth gait (`a2b640c`, `4af2333`, `cc108e2`).
- **2026-08-28** — cross-map ghosts survive the relay's cross-area filter, measured at a 76%
  cross-area room (`8eb0b20` — the adapter-side counterpart of ADR 0041), and the bridge-port
  config landed with the other adapters (`15b2715`).
