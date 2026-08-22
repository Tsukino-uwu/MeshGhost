# How Pokémon Crystal works

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

Dated evidence for every claim: [`agent_docs/verified.md`](../../../../agent_docs/verified.md).
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

- **Fishing and the "!" emote are not sprite changes**, so they do not appear in the
  `wPlayerState` table above at all. They are an action plus a facing on the ordinary character —
  which is why a character reading "fishing" still wears its normal sprite.
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
