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
  adapter for an hour.
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

`adapters/bizhawk/pokemon/crystal/README.md` (reader-facing) · `architecture.md` (the spawn ADR) ·
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
