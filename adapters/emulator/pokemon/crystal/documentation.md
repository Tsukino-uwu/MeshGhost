# How Pokémon Crystal works

<!-- line-cap: 700 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

## Before adding anything to this file

**Explain facts; never reproduce expression.** Measured numbers, timings, field/function/type
*names*, and behaviour described in your own sentences are all fine. Source text in any language,
decompiler or disassembler output, asset content or extracted strings, verbatim reflection or memory
dumps, and data tables copied wholesale are never fine — **regardless of what a licence permits**.

**The test: could someone re-derive this by owning the game and watching it?** If yes, it is a fact
and may be explained; whatever you learned it from only saved you the time, and is not the source of
your right to know it. If the only way to have it is to copy something, it stays out.

This is [CLAUDE.md](../../../../CLAUDE.md)'s standing rule — *is this fine sitting in a public repo
forever?* — applied to prose. No, or merely unclear, means out. Full guidance and the two edge cases
worth knowing: [adapters/_template/README.md](../../../_template/README.md).

> Everything here is **measured from a running game** during Phase 9 (2026-08-17 onward), and
> cross-checked against the public `pret/pokecrystal` decompilation, which is cited by file so any
> claim can be re-checked. **No source text, data table, or asset from that decompilation is
> reproduced here** — only facts, per `agent_docs/licensing.md`.

**What this file is: how *the game* does things**, per mechanic. **Nothing here describes an
adapter workaround** — those belong in [BANDAGES.md](BANDAGES.md). It should read as a description
of Crystal to someone who has never seen our code.

Dated evidence for every claim: [`VERIFIED.md`](VERIFIED.md).
The narrative of how it was discovered: [`phases/phase9.md`](../../../../agent_docs/phases/phase9.md).

## Overworld characters: two arrays, not one

This is the single most important thing to understand, and the thing that cost three attempts.

| | **Map objects** | **Object structs** |
| --- | --- | --- |
| Count | 16 | 13 |
| Where | `wMapObjects` (`01:d71e`), 16 bytes each | `wObjectStructs` (`01:d4d6`), 0x28 bytes each |
| What it is | **what the MAP defines** — loaded from ROM on map load | **what the engine is currently driving** |
| Slot 0 | the player | the player |

**Map objects are the source of truth.** An object struct is downstream: the engine creates one
*from* a map object when that object needs to be active, and links them with a pair of
cross-references — `MAPOBJECT_OBJECT_STRUCT_ID` on one side, `OBJECT_MAP_OBJECT_INDEX` on the other.
A map object with no struct yet carries `-1` (255) in that field.

Consequence worth stating plainly: **a map object can exist while having no struct**, and it is then
not drawn. Several of a room's own objects sit in exactly that state during normal play.

## How a character comes to exist

Crystal has two entry points, and **both are event-driven rather than continuous**:

1. **At map load** — `InitializeVisibleSprites` walks the map objects and assigns structs to those
   that qualify. (`engine/overworld/player_object.asm`, called from `map_setup.asm`.)
2. **At the screen edge** — `CheckObjectEnteringVisibleRange` runs *per step*, and is the mechanism
   by which characters appear as the world scrolls. It scans **exactly one row**: `wYCoord + 9`
   when walking down, `wYCoord - 1` when walking up, matching map objects on that row whose struct
   id is still `-1`. It returns immediately unless the player is mid-step.

**There is no general "anything unassigned gets picked up" pass.** A character standing inside the
visible area with no struct simply stays absent until one of the two events above reaches it.

The player itself is spawned by `SpawnPlayer`: copy a template map object, convert coordinates,
choose a palette by gender, then `CopyMapObjectToObjectStruct`. That last routine is **generic**,
not player-specific.

## The player's appearance

Sprite selection is a small table keyed on `wPlayerState`, with one table per gender
(`data/sprites/player_sprites.asm`):

| Player state | Chris | Kris |
| --- | --- | --- |
| `PLAYER_NORMAL` | `SPRITE_CHRIS` (1) | `SPRITE_KRIS` (0x60) |
| `PLAYER_BIKE` | `SPRITE_CHRIS_BIKE` | `SPRITE_KRIS_BIKE` |
| `PLAYER_SURF` | `SPRITE_SURF` | `SPRITE_SURF` — same |
| `PLAYER_SURF_PIKA` | `SPRITE_SURFING_PIKACHU` | same |

So a character's whole appearance reduces to **gender + player state → one sprite id**. Surfing is
gender-neutral.

Note the spawn template hardcodes `SPRITE_CHRIS`; the gender-correct sprite is written *afterwards*,
so a struct captured at the instant of spawn does not yet show the final appearance.

Sprite *graphics* are a separate matter: `wUsedSprites` (`01:d154`) is a per-map list of which
sprite ids have tiles loaded, built at map load and capped at `SPRITE_GFX_LIST_CAPACITY` (32).

## What a character is DOING: action and facing

Appearance (above) is only half of what a character looks like. The other half is two more fields
of the same object struct, and between them they cover **every animation this game can put a
character into** — there is no third mechanism:

- `OBJECT_ACTION` (offset `0x0b`) indexes `ObjectActionPairPointers`
  (`engine/overworld/map_object_action.asm`). The whole set, from
  `constants/map_object_constants.asm`: `STAND` (1), `STEP` (2), `BUMP` (3), `SPIN` (4),
  `SPIN_FLICKER` (5), `FISHING` (6), `SHADOW` (7), `EMOTE` (8), `BIG_DOLL_SYM` (9), `BOUNCE` (0a),
  `WEIRD_TREE` (0b), `BIG_DOLL_ASYM` (0c), `BIG_DOLL` (0d), `BOULDER_DUST` (0e), `GRASS_SHAKE`
  (0f), `SKYFALL` (10).
- `OBJECT_FACING` (offset `0x0d`) indexes `data/sprites/facings.asm`, which is a flat list rather
  than a direction plus a frame number: `STEP_DOWN_0..3`, `STEP_UP_0..3`, `STEP_LEFT_0..3`,
  `STEP_RIGHT_0..3`, then `FISH_DOWN`, `FISH_UP`, `FISH_LEFT`, `FISH_RIGHT`, `EMOTE`, `SHADOW`,
  and the doll/tree entries.

Two consequences worth stating plainly, because they are what makes a peer's animation tractable:

- **Fishing is not a sprite change**, so it does not appear in the `wPlayerState` table above at
  all. It is an action plus a facing on the ordinary character — which is why a character reading
  "fishing" still wears its normal sprite.
- **The "!" emote is not on the character at all.** `SpawnEmote`
  (`engine/overworld/map_objects.asm`) creates a **separate map object**, flagged `EMOTE_OBJECT_F`
  and given the `EMOTE` movement data, which parks itself two tiles above the character it belongs
  to; `DespawnEmote` deletes whichever object carries that flag. So a character's own
  `OBJECT_ACTION` never becomes `EMOTE` — that value belongs to the little object holding the box,
  and it is the reason the emote survives the character underneath it walking, turning or being
  frozen.
- **The four walking frames per direction are in the facing list itself.** A direction is not a
  separate field from an animation frame: `STEP_DOWN_0` through `STEP_DOWN_3` are four entries of
  one list, so a single byte says both which way a character faces and which stride it is on.

`OBJECT_DIRECTION` (offset `0x08`) is the coarser value — the direction alone, in steps of 4 — and
is what the engine's own step logic writes.

## Position, and the two coordinate spaces

- `wXCoord` / `wYCoord` (`01:dcb8` / `01:dcb7`) — despite the names, the **origin of the visible
  window** in map space, not the player's own position, and the space
  `CheckObjectEnteringVisibleRange` compares against. Two independent things say so: the
  `wYCoord - 1` / `wYCoord + 9` scan rows above bracket a window rather than sitting symmetrically
  around a walker, and converting a map coordinate to a screen one is `(mx - wXCoord) & 0x0F`
  — subtracting a window origin, which would put the player in the top-left corner if this were
  the player's own position.
- An object struct carries **map** coordinates (`OBJECT_MAP_X`/`MAP_Y`, offsets 0x10/0x11) *and*
  **screen** coordinates (`OBJECT_SPRITE_X`/`Y`, 0x17/0x18) as separate fields.

**These two are maintained independently, and that distinction is load-bearing**: map coordinates
drive collision, screen coordinates drive where the sprite is drawn. The engine keeps them
consistent for objects it owns.

**A step sets the map coordinate to its DESTINATION, on the first frame** — measured from a
read-only capture of an NPC taking a real step (2026-08-18). The map coordinate is not updated when
a step completes; it is set at the start, in the same frame as everything else, and the sprite then
slides to catch up over the following ~16 frames. Every frame after the first is the engine's own
work.

**Why it matters for a ghost:** the intuitive model — write coordinates when a step finishes and
let animation follow — is backwards, and produces a character that teleports while appearing to
walk. The bug then looks like a smoothing fault, which is where the search would go.

## Map identity

`wMapGroup` (`01:dcb5`) and `wMapNumber` (`01:dcb6`) are consecutive bytes, followed immediately by
`wYCoord` and `wXCoord` — four consecutive bytes in total. Map identity is a **pair**; neither byte
means anything alone. Groups are broadly regional (group 24 is the New Bark Town area).

## The game's lifecycle states

`wMapStatus` (`01:d432`) is the map state machine, and is the honest answer to "is the world
currently real":

| Value | Meaning |
| --- | --- |
| `MAPSTATUS_START` (0) | before the world exists, and during setup |
| `MAPSTATUS_ENTER` (1) | entering or re-entering a map |
| `MAPSTATUS_HANDLE` (2) | the steady overworld state |
| `MAPSTATUS_DONE` (3) | |

Measured behaviour, all confirmed live:

- **Loading a save**: the player object appears *before* the map identity becomes valid, and
  `HANDLE` arrives roughly **two seconds after both** — a window where every value looks plausible
  and the world is still being built.
- **A door transition**: `HANDLE → ENTER → HANDLE`, with the map identity switching during `ENTER`
  and the object arrays repopulating from ROM.
- **Leaving a battle**: also passes through `ENTER`. **A battle exit is a map re-entry.**
- **Object state is per-map** and rebuilt from ROM on load, so anything not defined by the map is
  gone after a transition.

Two neighbouring flags are *not* useful as "is the world stable" signals, though they are real:
`wMapEventStatus` (`01:d433`, ON/OFF) and `wScriptRunning` (`01:d438`) **toggle on every walking
step**, since the game suspends map events while a step is in progress.

## Battles

`wBattleMode` (`01:d22d`): `0` none, `1` wild, `2` trainer.

**A battle is invisible to the map state machine** — `wMapStatus` stays `HANDLE` throughout. The two
are independent, and battle state cannot be inferred from map state. Object structs are not cleared
on battle entry.

## What a character IS: type, sight range, and script

A map object's 16 bytes are laid out as object-struct id, sprite, y, x, movement, radius, two
time-of-day bytes, a shared palette/type byte, sight range, a script pointer, and an event flag
(`constants/map_object_constants.asm:79-99`). **Byte 8 carries two things in one:** its high nibble
is the palette, its low nibble is the object's TYPE.

The type values are a plain sequence from zero (`constants/script_constants.asm:137-145`): script 0,
itemball 1, **trainer 2**, and four more that the game itself labels dummy events.

That nibble decides what happens when the player faces the character
(`engine/overworld/events.asm`, its object-event type table):

| Type | Facing it does |
| --- | --- |
| script (0), itemball (1) | **dereferences the script pointer** and runs it |
| trainer (2) | talks to the trainer |
| 3-6 | nothing at all — each handler immediately returns |

Worth stating plainly, because it is not obvious: **types 3-6 are the only ones that never touch the
script pointer.** A character with type 0 and a blank pointer is not inert — it is a jump through a
null pointer waiting to happen.

## How a trainer spots you

`_CheckTrainerBattle` (`home/trainers.asm:13`) walks the **map objects** — not the object structs —
skipping the player, and starts a battle when all of these hold:

1. the object has a sprite,
2. its type nibble is trainer,
3. it currently has an object struct (the id is not -1, i.e. it is live on screen),
4. it is facing the player, and the distance is within its **sight range** byte,
5. and the event flag it points at is not already set.

The order matters for anyone changing a character's identity: **the type is tested second, before
the sight range and before the script pointer is ever read.** A character whose type is not trainer
leaves this scan at step 2.

## Which characters block the player, and which do not

When the player takes a step, the destination tile is checked against every object struct by
`IsNPCAtCoord` (`engine/overworld/npc_movement.asm:314`, called from
`engine/overworld/player_movement.asm:634`). A character is **skipped** — the player walks through
it — when either:

- it has no sprite, or
- **`EMOTE_OBJECT` is set in its `OBJECT_FLAGS1`.**

So the game does have a real "not solid" bit, and it is checked on the player's side.

Two details that matter more than they look:

- **A moving character occupies two tiles.** The check compares the destination against each
  object's current coordinates *and* its `LAST_MAP_X`/`LAST_MAP_Y`. A character mid-step blocks both
  the tile it left and the tile it is entering, so a walking character is a wider obstacle than a
  standing one.
- **`EMOTE_OBJECT` has a second meaning, and it is destructive.** When an emote despawns,
  `DespawnEmote` (`engine/overworld/map_objects.asm:2098`) zeroes *every* object struct carrying
  that bit, wholesale. It does not consult `WONT_DELETE`. The bit means "this struct is an emote
  bubble", and pass-through is a consequence of that, not a general-purpose flag.

`NOCLIP_OBJS` (`OBJECT_FLAGS1`) is a different thing and is easy to confuse with the above: it is
read in `engine/overworld/npc_movement.asm:33` and governs whether **that character's own movement**
bumps into others, not whether the player is blocked by it.

## The three flag bytes on an object struct

Named bits, from `constants/map_object_constants.asm:46-72`. Listed in full because most of them
describe behaviour the game already handles for a character that has them set.

- **`OBJECT_FLAGS1`** (0x04): invisible, won't delete, fixed facing, sliding, noclip tiles, move
  anywhere, noclip objects, emote object.
- **`OBJECT_FLAGS2`** (0x05): low priority, high priority, boulder moving, **in grass**, use OBP1,
  frozen, off screen, **under tiles**.
- **`OBJECT_PALETTE`** (0x06) also carries bits: **swimming**, strength boulder, **big object**.

`IN_GRASS` is set and cleared by the engine as a character moves
(`engine/overworld/map_objects.asm:229-261`), and the priority and `UNDER_TILES` bits are what place
a character behind scenery.

## The rest of the object struct

The full 0x28 (`constants/map_object_constants.asm:3-37`). Fields not covered elsewhere in this
file, and what each is for:

| Offset | Field | Notes |
| --- | --- | --- |
| 0x0c | step frame | which frame of the walk cycle is showing |
| 0x0e, 0x0f | tile collision, last tile | the terrain under the character |
| 0x16 | radius | how far a wandering character may stray |
| 0x19, 0x1a | sprite x/y offset | pixel offsets applied on top of the position |
| 0x1b, 0x1c | movement index, step index | where the character is in its movement script |
| 0x1f | jump height | non-zero through a ledge hop |
| 0x20 | range | the sight range, copied up from the map object |

## Where this is read from in the adapter

One line each; the code stays the source of truth.

- `domain_probe.lua` — establishing that BizHawk's `WRAM` domain reaches bank 1 (GB WRAM is banked;
  `WRAM` addresses bank 1 unconditionally, `System Bus` follows the currently selected bank).
- `object_slot_probe.lua` — the object struct array and its field layout.
- `ingame_gate_probe.lua` — the lifecycle states above.
- `spawn_test*.lua` — the adoption mechanism.

## How many characters the game can hold at once

Two separate budgets, and the smaller one wins:

- **The engine's slots.** 13 **object structs** and 16 **map objects** (`NUM_OBJECT_STRUCTS` /
  `NUM_OBJECTS`). A map spends some of both on its own cast before anything else asks: New Bark
  Town leaves 9 free, Elm's lab also leaves 9 — but **outdoors the structs run out first and
  indoors the map objects do**, because an indoor map declares more map objects than it has
  characters on screen at any moment.
- **The hardware.** 40 sprite entries (`wShadowOAM`, `00:c400`–`00:c4a0`, 4 bytes each) and an
  overworld character occupies exactly 4 of them, so **10 characters can be on screen at once**,
  player included. Unused entries are parked at `y=160`, one row below the 144-line screen. The
  Game Boy also drops sprites past 10 *per scanline*; ten characters spread vertically do not
  reach it.

Measured 2026-08-19 with real synthetic peers over the relay, at 60fps throughout — including with
36 peers offered against 9 slots, and with the sprite hardware fully saturated at 40 of 40 in the
lab, where all ten characters still drew correctly. Method and full table:
`agent_docs/crowd-limits.md`.

## The game's UI covers characters by itself

A text box or the pause menu is drawn by the game over the map, and every character underneath it
is covered by hardware priority — the game's own NPCs and any object written into the arrays
alike. A character standing *outside* the panel's region keeps drawing normally.

Confirmed on screen 2026-08-19 with nine spawned ghosts and the pause menu open. Recorded here
because it is a property of the game: hardware priority does this for anything the engine itself
is drawing, with nothing asked of whoever put the character in the array.

## How a walking sprite's tiles become four facings and a walk cycle

A walking overworld sprite is **six views of four tiles** — three standing and three stepping —
and a character's tiles are found **relative to its own tile base** (`OBJECT_SPRITE_TILE`):

| View | Offset from the character's own base | Used for |
|---|---|---|
| down | 0-3 | facing down, standing or mid-step |
| up | 4-7 | facing up |
| side | 8-11 | facing **both** left and right |
| down, stepping | 0x80-0x83 | facing down, on a step |
| up, stepping | 0x84-0x87 | facing up |
| side, stepping | 0x88-0x8B | left and right |

**There is no left art and no right art.** One side view is drawn as-is for one direction and
mirrored by the hardware for the other — every clean sample agreeing: left takes it unflipped,
right takes it mirrored.

**The stepping views are 0x80 above the standing ones, relative to the character's own base.**
Measured on two characters at two different bases in one session: the player at base 0x00 (stepping
at 0x80-0x8B) and an Olivine NPC at base 0x30 (standing at 0x38-0x3B, stepping at 0xB8-0xBB). So
0x80 is a stride within a sprite's own graphics, not an absolute region of tile memory.

**In the CARTRIDGE the six views are contiguous**, because ROM has no tile base to be relative to:
VRAM `base + 0..11` are ROM tiles 0-11 and VRAM `base + 0x80..0x8B` are ROM tiles **12-23**,
matched byte for byte on both sprites above. A sprite's graphics are therefore **24 tiles**, even
though the sprite table's own size field reports 192 bytes — that field describes the standing
half only.

**Which view is drawn is a function of how far through its step a character is**, and the partition
is exact, with no overlap, measured across all four directions:

| Pixels into the step | View drawn |
|---|---|
| 0, 2, 4, 14 | stepping |
| 6, 8, 10, 12 | standing |

**The two feet come from mirroring the stepping view**, so the flip carries two unrelated meanings
depending on the direction. Facing down or up, both flips are legitimate and alternating between
them is what makes the walk cycle. Facing sideways, the flip is what says which way the character
is looking, so it cannot also carry the stride — a sideways walk uses one stepping view throughout.
Which foot is selected by the low two bits of `OBJECT_FACING`, the engine's own stride index.

Measured 2026-08-22 by logging what the engine actually drew (`probes/stride_probe.lua`, and
`MESHGHOST_CRYSTAL_FACING_TRACE`), against the player and an NPC walking each direction. Why it
matters to an adapter, and the two faults it produced — the flip read as a direction, and the
stepping views discarded as another character's tiles: `agent_docs/pitfalls.md`.

## The camera: what scrolls the screen, and the register that only looks like it

Two different quantities move when the player walks, and they are easy to mistake for each other.

**`hSCX` / `hSCY` ($ffcf / $ffd0) are the camera.** `ScrollScreen` adds the frame's player step
vector to them, and they are what the background is actually scrolled by. A walking player moves
them 2px per engine tick on one axis; the bike moves 4px. They are 8-bit and wrap at 256, so any
difference taken across frames has to be read the short way round.

**`wPlayerBGMapOffsetX` / `wPlayerBGMapOffsetY` ($d14c / $d14d) are NOT the camera**, despite moving
by the same amounts at the same times. They are a *per-frame delta*: `_HandlePlayerStep` subtracts
the same step vector from them (note the opposite sign to `hSC`), and then `ApplyBGMapAnchorToObjects`
— reached from `_UpdateSprites` every frame — reads them, adds them to every object's sprite X and Y
as a correction, and **zeroes them**. Their value is "how far the camera has moved since the sprites
were last positioned", and it returns to zero each frame. Integrating them as though they were an
absolute scroll position produces something that tracks the camera most of the time and diverges
without warning; measured against `hSC` on the same frame, the two disagreed on about 9% of frames.

Consequences worth knowing before using either:

- **The two run in opposite directions.** `hSC` gains what the offset pair loses, so a difference
  taken on one is the negation of the same difference on the other.
- **The player's sprite does not move when the player walks** — the camera does. The player's on-screen
  position only changes where the camera is clamped, such as near a map edge, and that is why a
  screen-space calculation needs the player's OAM position as well as the camera.
- **A camera reading is only as good as how often you take it.** Both quantities are differences, and
  a difference is only a per-frame difference if you sampled on every frame; miss eight frames of a
  2px walk and the next reading is 16px, which is indistinguishable from the game having jumped.

Sources: `wPlayerBGMapOffsetX/Y` and `ApplyBGMapAnchorToObjects` from `pret/pokecrystal`
(`ram/wram.asm`, `engine/overworld/map_objects.asm`); `ScrollScreen` and the step-vector arithmetic
from `engine/overworld/player_step.asm`; addresses from a hash-verified local build of V1.0.
Confirmed against a running V1.0 by reading both registers on the same frame, 2026-08-23.

## Walking into a wall

Holding a direction against something impassable does not leave the character standing. Crystal plays
a walk-in-place shuffle, and **it is built out of the two poses the character already has, not out of
the walk cycle**:

- `OBJECT_WALKING` stays **STANDING** for the whole thing. Nothing about a bump is a step, so anything
  that keys off "is this character walking" cannot see one.
- `OBJECT_ACTION` reads **`BUMP`** (3) throughout, and that is the only field that says a bump is
  happening at all.
- `OBJECT_STEP_DURATION` is **0**, so any progress-through-a-step derived from it reads as a
  completed step rather than as no step.
- `OBJECT_FACING` advances **0, 1, 2, 3** and wraps, one value every 16 frames.
- The tile actually drawn alternates between the character's **standing** art and its **stepping**
  art (the `+ 0x80` block described under the walk cycle below) in **16-frame runs** — stepping on
  odd strides, standing on even ones. The block changes three frames before the facing does, so each
  facing shows 3 frames of one pose and 13 of the other.

Measured on the player, holding into a fence, run-length encoded so the cadence is visible
(`probes/bump_probe.lua`, 2026-08-23):

```
facing 2: stepping x3, standing x13     facing 3: standing x3, stepping x13
facing 0: stepping x3, standing x13     facing 1: standing x3, stepping x13
```

**So a bump is a two-pose shuffle at about four poses a second, not a stride cycle.** It looks
slower and heavier than walking because it is: a walk changes pose roughly twice as often.

The same shape covers every animation the game plays *without moving the character* — turning in
place, spin tiles, fishing, Teleport, Dig, the Fly landing. All are selected by `OBJECT_ACTION`
while the position fields sit still, so `OBJECT_ACTION` is the only field that can distinguish
them. Each one is enumerated below. (The `!` emote is **not** in this family: it is a separate
object, not a pose the character adopts.)

## Every animation that does not move the character, and what each one is made of

The bump above is one of a family. Every one of them keeps the character on its tile and changes
only `OBJECT_ACTION`, and each action handler's whole job is to write `OBJECT_FACING` — so **the
facing byte is the pose**, and the action byte only says which rule is producing it. This is worth
stating in that order, because it is not obvious from the outside: the engine looks the facing byte
up in the facing list (`data/sprites/facings.asm`) and emits the sprite parts it finds there, so
two characters with the same facing byte are drawn identically no matter what they are doing.

Reading the facing byte the way the engine does:

| facing byte | what it names | drawn as |
| --- | --- | --- |
| `0x00`–`0x0f` | `STEP_<dir>_<0..3>`: direction is the byte over four, stride is the low two bits | strides 0 and 2 are the **standing** view, 1 and 3 the two **stepping** ones |
| `0x10`–`0x13` | `FISH_DOWN` / `UP` / `LEFT` / `RIGHT` | the character's own **standing** view for that direction, **plus a fifth sprite** for the rod |
| `0x14` | `EMOTE` | four tiles of the emote box **instead of** the character — and it is a separate object, never a player |
| `0x15` and up | `SHADOW`, the dolls, the tree, boulder dust, shaking grass | scenery; a player object never holds one |
| `0xff` | `STANDING` | **nothing is drawn.** The engine skips the object entirely |

### The engine's object clock runs at half the video rate

Everything below counts in **engine ticks**, not video frames, because that is what the action
handlers count. A tick is **two video frames**: the decomp has a bump advancing its facing once
every eight increments of `OBJECT_STEP_FRAME`, and the same bump measured on screen advances its
facing once every **sixteen** video frames (`probes/bump_probe.lua`, 2026-08-23). The same factor
of two shows up in an ordinary walking step, which counts down eight units of
`OBJECT_STEP_DURATION` across roughly sixteen video frames.

**Two video frames is the average, not a guarantee.** The tick does not sit on a fixed frame
parity: within one bout of walking the parity holds, across bouts it differs, and two ticks do
sometimes land on consecutive frames (measured 2026-08-23 against the scroll registers,
`VERIFIED.md`). So the tick counts below are exact in ticks and approximate in frames.

### The classes, one by one

All of these are from `engine/overworld/map_object_action.asm` unless another file is named.

- **`BUMP` (3)** — `OBJECT_STEP_FRAME` counts up by one a tick, and the facing's stride is **bits 3
  and 4** of it, so the stride advances every **8 ticks**. Full detail and the measured cadence
  under *Walking into a wall* above. Entered by the movement engine (`engine/overworld/movement.asm`)
  and re-issued for as long as the direction is held.
- **`SPIN` (4)** — the action that turns a character **counterclockwise**: `OBJECT_STEP_FRAME` is
  used as two separate two-bit fields, a timer in the low bits and a facing index in bits 4 and 5,
  and the direction advances **down → right → up → left** every **4 ticks**. The facing byte is
  simply the direction with stride 0, so a spinning character always shows a **standing** view.
  It is used for four different things: **turning in place** (which is why this is by far the most
  common of the family — see below), the **spin tiles**, and the rise and descent of **Teleport**
  and **Dig**, each of those phases running for 16 ticks.
- **`SPIN_FLICKER` (5)** — spins the direction exactly as above and then sets `OBJECT_FACING` to
  `STANDING`, so **the character is not drawn on that tick**. `Dig` alternates it with `SPIN` on
  odd and even ticks, and that alternation *is* the flicker: the character is visibly present half
  the time while it spins.
- **`FISHING` (6)** — the facing becomes `FISH_` plus the direction. The body is the character's
  ordinary standing art; the **rod is one extra sprite**, and it is not part of the character's
  graphics — its tile id is absolute rather than relative to the character's tile base, so it comes
  from a pair of shared tiles the game loads on demand (`data/sprites/emotes.asm` lists the rod as
  two tiles, sharing its slot with the jump shadow). The rod sits below the character facing down,
  above it facing up, and to the side facing left or right. **It has no fixed length** — the action
  is set when the rod is cast and stays until the fishing script ends it, so this is the one class
  that can hold for many seconds.
- **`SKYFALL` (16)** — the Fly landing. Identical arithmetic to a walking step except that
  `OBJECT_STEP_FRAME` goes up by **two** a tick instead of one, so the stride advances every **2
  ticks**: the character runs its walk cycle at **double speed** while it falls. The fall itself is
  a sprite Y offset that starts high above the tile and comes down; the top phase is 16 ticks.

### Turning in place is a spin, and it happens constantly

The single most common member of this family is not an exotic one. Tapping a direction the
character is not already facing turns it without moving it, and the engine animates that turn with
`OBJECT_ACTION_SPIN` — the same counterclockwise spin the spin tiles use, run for **4 ticks** (two
at the old direction, two at the new one, from `engine/overworld/map_objects.asm`'s turning step).
So a character that turns around passes visibly through an intermediate direction rather than
snapping, and anything that reconstructs a character's pose from its position alone will miss it
every time a player looks around.

## A newly created object is not drawn for one to two frames

Writing a complete, valid object struct does not put a character on screen that frame. The engine
builds its sprite list from the object array once per frame, and a struct written between frames is
not in the list the next frame draws.

**Measured** by dumping hardware OAM every frame across several newly created objects (2026-08-23):
the object has **no OAM entries at all** on the frame it is created, and its four entries first
appear **two or three frames later** — three in most samples, two in a minority. The count is exact
because a character is four entries and the live-entry total steps up by four when it arrives.

This matters to anything that hands a character over between two ways of drawing it: the gap is real,
it is not a single frame, and it varies, so a fixed number of frames chosen by reasoning will be
wrong some of the time.

## OAM entry order is not stable

The player's four sprites are commonly the first four OAM entries, and **that is a coincidence of
how many characters are on screen, not a rule.** Observed on this game (2026-08-23): with a second
character nearby, the player's own entries appeared in a different order within their group, and
another character occupied entries 0-3 while the player sat further down the table.

**Anything that identifies a character by its OAM slot is reading whichever character happens to be
there.** The reliable route is to derive the relationship between an object's `OBJECT_SPRITE_X`/`Y`
and its OAM position each frame, and to CHECK that derivation against a character whose position is
already known before trusting it for another — a check which, when it fails, should produce no
reading rather than a wrong one.
