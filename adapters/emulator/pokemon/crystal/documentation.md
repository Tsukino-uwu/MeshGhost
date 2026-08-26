# How Pokémon Crystal works

<!-- line-cap: none -- written for people, not for an agent's instruction budget. Why: agent_docs/claude-md-cap.md. -->

## Before adding anything to this file

**Explain facts; never reproduce expression.** Measured numbers, timings, field/function/type
*names*, and behaviour described in your own sentences are all fine. Source text in any language,
decompiler or disassembler output, asset content or extracted strings, verbatim reflection or memory
dumps, and data tables copied wholesale are never fine — **regardless of what a licence permits**.

**The test: could someone re-derive this by owning the game and watching it?** If yes, it is a fact
and may be explained; whatever you learned it from only saved you the time, and is not the source of
your right to know it. If the only way to have it is to copy something, it stays out.

This is [CLAUDE.md](../../../../CLAUDE.md)'s standing rule — *is this fine sitting in a public repo
forever?* — applied to prose. No, or merely unclear, means out. Full guidance and the two edge
cases: [adapters/_template/README.md](../../../_template/README.md).

> **Measured from a running game** during Phase 9 (2026-08-17 onward), mostly on vanilla V1.0, and
> cross-checked against the public `pret/pokecrystal` decompilation. **Decomp facts carry a file
> citation; facts watched on a running game are marked `[measured]` with a date.**

**What this file is: how *the game* does things**, per mechanic, readable by someone who has never
seen our code. **Nothing here describes an adapter workaround** — those belong in
[BANDAGES.md](BANDAGES.md). Evidence: [`VERIFIED.md`](VERIFIED.md); narrative:
[`phases/phase9.md`](../../../../agent_docs/phases/phase9.md).

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
A map object with no struct yet carries `-1` (255) in that field. So **a map object can exist while
having no struct**, and it is then not drawn; several of a room's own objects sit in exactly that
state during normal play.

## How a character comes to exist

Crystal has two entry points, and **both are event-driven rather than continuous**:

1. **At map load** — `InitializeVisibleSprites` walks the map objects and assigns structs to those
   that qualify (`engine/overworld/player_object.asm`, called from `map_setup.asm`).
2. **At the screen edge** — `CheckObjectEnteringVisibleRange` runs *per step*, and is how characters
   appear as the world scrolls. It scans **exactly one line — a row walking vertically, a COLUMN
   walking horizontally**, matching map objects there whose struct id is still `-1`, and returns
   immediately unless the player is mid-step. The four branches take different constants, and the
   two axes do not agree: `wYCoord - 1` up, `wYCoord + 9` down, `wXCoord - 1` left, and
   `wXCoord + **10**` right (`engine/overworld/player_object.asm`). Reading it as "one row" misses
   half the cases outright, and assuming the horizontal constant is 9 misses the far column.

**There is no general "anything unassigned gets picked up" pass.** A character standing inside the
visible area with no struct simply stays absent until one of the two events above reaches it. The
player itself is spawned by `SpawnPlayer`: copy a template map object, convert coordinates, choose
a palette by gender, then `CopyMapObjectToObjectStruct` — a **generic** routine, not a
player-specific one.

## The player's appearance

Sprite selection is a small table keyed on `wPlayerState`, with one table per gender
(`data/sprites/player_sprites.asm`):

| Player state | Chris | Kris |
| --- | --- | --- |
| `PLAYER_NORMAL` | `SPRITE_CHRIS` (1) | `SPRITE_KRIS` (0x60) |
| `PLAYER_BIKE` | `SPRITE_CHRIS_BIKE` | `SPRITE_KRIS_BIKE` |
| `PLAYER_SURF` | `SPRITE_SURF` | `SPRITE_SURF` — same |
| `PLAYER_SURF_PIKA` | `SPRITE_SURFING_PIKACHU` | same |

So a character's whole appearance reduces to **gender + player state → one sprite id**, and surfing
is gender-neutral. Note the spawn template hardcodes `SPRITE_CHRIS` and the gender-correct sprite
is written *afterwards*, so a struct captured at the instant of spawn does not yet show the final
appearance.

### A sprite id is not a picture: what is RESIDENT is decided per map

Sprite *graphics* are a separate matter, and the constraint is real rather than bookkeeping.
`wUsedSprites` (`01:d154`) is a packed list of 32 two-byte entries (`SPRITE_GFX_LIST_CAPACITY`),
ending at `wUsedSpritesEnd` (`01:d194`). `AddSpriteGFX` puts a sprite id in the first byte as the
map loads; `ArrangeUsedSprites` writes the VRAM tile its graphics were actually placed at into the
second. So the table answers **"is sprite N loaded right now, and where"**, and a zero id ends it.
What goes in is the map's own cast indoors and a fixed per-region list outdoors, plus whatever the
player's current state needs.

**A sprite whose tiles are not resident cannot be drawn by the object system at all** — there is
nothing at any tile base to draw. And the mounted sprites (`SPRITE_*_BIKE`, `SPRITE_SURF`) are
loaded only while the player is doing that thing, so they are absent from most maps most of the time.

**A mount rewrites tiles in place.** Getting on the bike or the surf blob changes the player's
graphics at the **same VRAM base, with no map load** — `wUsedSprites` moves, nothing about the map
or the coordinates does, so a map-change signal cannot see it. [measured 2026-08-25]

### Some sprite ids are resolved at runtime

Ids at or above `SPRITE_VARS` (`$F0`) are **variable sprites**: a map's data names a placeholder,
and the actual sprite is looked up at map load through `wVariableSprites` (`01:d82e`), which map
scripts overwrite with a `variablesprite` command as the story progresses. Route 40's swimmers are
declared as `SPRITE_OLIVINE_RIVAL` and become swimmers only because Olivine City's script
substituted them on the way past. **So the same map can legitimately show different characters on
two saves**, and a save that skipped the story shows the slot's default rather than corruption.
Established 2026-08-26 by an A/B with nothing of ours loaded; trail in
[`UNVERIFIED.md`](UNVERIFIED.md).

### Surf and the bike, in the game's own terms

Both are `wPlayerState` (`01:d95d`) changing, and almost nothing else. **Surf replaces the
character outright** — the whole four-tile character becomes `SPRITE_SURF`, a gender-neutral blob,
with no second object and no rider drawn on top (the opposite of Emerald, which spawns a separate
blob underneath). **The bike is a different sprite plus a different gait**, group 2 — the same
group an ice glide uses, which is why the gait alone never identifies either.

**Neither is a state the object struct carries.** An object's own bytes describe the sprite it
wears and how fast it is going; "is this character surfing" lives only in `wPlayerState`, and only
for the player. The `SWIMMING` bit in `OBJECT_PALETTE` governs which terrain a character's own
movement may enter, not what it looks like. [measured 2026-08-25] mounting and dismounting.

## What a character is DOING: action and facing

Appearance is only half of what a character looks like. The other half is two more fields of the
same object struct, covering **every animation this game can put a character into** — there is no
third mechanism:

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

Three consequences worth stating plainly:

- **Fishing is not a sprite change**, so it does not appear in the `wPlayerState` table above at
  all. It is an action plus a facing on the ordinary character — which is why a character reading
  "fishing" still wears its normal sprite.
- **The "!" emote is not on the character at all.** `SpawnEmote`
  (`engine/overworld/map_objects.asm`) creates a **separate map object** parked two tiles above the
  character it belongs to, so a character's own `OBJECT_ACTION` never becomes `EMOTE` — which is why
  an emote survives the character underneath it walking, turning or being frozen. Its flag and the
  destructive despawn it shares with shadows are below (*Which characters block the player*).
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
  around a walker, and converting a map coordinate to a screen one subtracts this pair, which would
  put the player in the top-left corner if it were the player's own position.
- An object struct carries **map** coordinates (`OBJECT_MAP_X`/`MAP_Y`, offsets 0x10/0x11) *and*
  **screen** coordinates (`OBJECT_SPRITE_X`/`Y`, 0x17/0x18) as separate fields, **maintained
  independently**: map coordinates drive collision, screen coordinates drive where the sprite is
  drawn, and the engine keeps them consistent for objects it owns.

**A step sets the map coordinate to its DESTINATION, on the first frame.** It is not updated when
a step *completes*; it is set at the start, in the same frame as everything else, and the sprite
then slides to catch up over the following ~16 frames. So a character's tile is where it is *going*
for the whole of a step, and only the sprite position says how far along it is.
[measured 2026-08-18] from a read-only capture of an NPC taking a real step.

## How a character crosses a tile: three gaits, one distance — or four

Every step covers exactly one 16px tile. What a gait changes is how long that takes, and the whole
thing is one byte. `GetStepVector` (`engine/overworld/map_objects.asm`) indexes `StepVectors` with
`OBJECT_WALKING & $0F`, and the table is **three groups of four directions** — so the low nibble
carries both the gait and the direction, and nothing has to be inferred:

| Group | Index range | Speed | Ticks per tile | Used by |
| --- | --- | --- | --- | --- |
| 0 | 0-3 | 1px/tick | 16 | slow movement scripts |
| 1 | 4-7 | 2px/tick | 8 | **walking** |
| 2 | 8-11 | 4px/tick | 4 | **the bike**, and an ice glide |
| 3 | 12-15 | 8px/tick | 2 | **patched cartridges only** — no vanilla build fills it |

`OBJECT_STEP_DURATION` counts down through the group's tick budget, so **pixels travelled into the
step is `(ticks - duration) x speed`** — an exact value at every gait, not an approximation. While
a character stands, `OBJECT_WALKING` is `$FF` (`STANDING`) and says nothing about its last gait.
[measured 2026-08-25] on a bike lap: `OBJECT_WALKING` held `08`/`09` — group 2 — with the duration
counting 3, 2, 1, while walking holds 4-7. **The camera moves at the same rates** (*The camera*).

**The nibble addresses SIXTEEN entries and vanilla fills TWELVE** — which is why a patch can add
group 3 without touching `GetStepVector`, and why `STANDING` (255, nibble 15) is past the real
ones: an object left there with a live step type reads a vector out of whatever follows the table
and is dragged off the map. [measured 2026-08-26] V1.0, V1.1 and speedchoice 8.1 all carry three
groups at `0x004700`; an Archipelago seed carries four at `0x0048C9`. **Which mode uses the fourth
was not measured** — do not assume it is running. **The count is the cartridge's, not the
family's.** [UNVERIFIED.md](UNVERIFIED.md).

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
| `MAPSTATUS_DONE` (3) | the terminal value; never seen during ordinary play |

Measured behaviour, all confirmed live:

- **Loading a save**: the player object appears *before* the map identity becomes valid, and
  `HANDLE` arrives roughly **two seconds after both** — a window where every value looks plausible
  and the world is still being built.
- **A door transition**: `HANDLE → ENTER → HANDLE`, with the map identity switching during `ENTER`
  and the object arrays repopulating from ROM. **Every warp leaves `HANDLE`**, including one that
  lands back on the same map; an overlaid menu or text box never touches the status at all.
- **`HANDLE` comes back before the screen does** — it returns the moment the new map is entered,
  while the screen is still fading in. And **Crystal never touches the OBJ palette during that
  fade** (the palette shadow read flat through every crossing measured), so unlike some games there
  is no brightness signal separating a settled map from a fading one.
- **Leaving a battle**: also passes through `ENTER`. **A battle exit is a map re-entry.**
- **Object state is per-map** and rebuilt from ROM on load, so anything not defined by the map is
  gone after a transition.

Two neighbouring flags are *not* useful as "is the world stable" signals, though they are real:
`wMapEventStatus` (`01:d433`, ON/OFF) and `wScriptRunning` (`01:d438`) **toggle on every walking
step**, since the game suspends map events while a step is in progress.

## Warps: the game records HOW a map was entered

Every map load stamps `hMapEntryMethod` (`$ff9f`, in HRAM — unbanked, and therefore not in the WRAM
address space everything else here lives in) with a `MAPSETUP_*` value, and the routine that hands
the overworld back zeroes it again (`engine/overworld/events.asm`). `$F5` is `MAPSETUP_DOOR`, `$FC`
is `MAPSETUP_FLY`. So for a short window after arriving, the game itself can say whether the player
walked through a door, flew, or was warped by a script. **But not everything gets its own value**:
a Dig or an Escape Rope arrives wearing `MAPSETUP_DOOR`, indistinguishable from a door from the
outside. [measured 2026-08-23/26, `probes/transition_probe.lua` and `probes/fly_probe.lua`]

## Forced movement: a script freezes every other character

Some tiles take control of the player rather than blocking them — a whirlpool is the clearest case.
The tile forces `PLAYERMOVEMENT_FORCE_TURN` (`engine/overworld/player_movement.asm:119`), the spin
is applied through `ApplyMovement` (`engine/overworld/scripting.asm:815`), and **`ApplyMovement`
begins by calling `FreezeAllOtherObjects`.** So for the whole sequence every other character on the
map — the game's own NPCs included — stops where it stands, **mid-step included**, and resumes when
the movement script ends, completing its interrupted step normally. [measured 2026-08-26] An object
caught in it held five of eight ticks of a step — 10px of 16 — for about 60 frames, thawing exactly
as the player's spin finished. **The game does this to itself**, so a frozen character is correct.

## Battles

`wBattleMode` (`01:d22d`): `0` none, `1` wild, `2` trainer.

**A battle is invisible to the map state machine** — `wMapStatus` stays `HANDLE` throughout, so
battle state cannot be inferred from map state. Object structs are not cleared on battle entry.

## What a character IS: type, sight range, and script

A map object's 16 bytes are laid out as object-struct id, sprite, y, x, movement, radius, two
time-of-day bytes, a shared palette/type byte, sight range, a script pointer, and an event flag
(`constants/map_object_constants.asm:79-99`). **Byte 8 carries two things in one:** its high nibble
is the palette, its low nibble is the object's TYPE — a plain sequence from zero
(`constants/script_constants.asm:137-145`): script 0, itemball 1, **trainer 2**, and four more the
game itself labels dummy events. That nibble decides what happens when the player faces the
character (`engine/overworld/events.asm`, its object-event type table):

| Type | Facing it does |
| --- | --- |
| script (0), itemball (1) | **dereferences the script pointer** and runs it |
| trainer (2) | talks to the trainer |
| 3-6 | nothing at all — each handler immediately returns |

**Types 3-6 are the only ones that never touch the script pointer.** A character with type 0 and a
blank pointer is not inert — it is a jump through a null pointer waiting to happen.

## How a trainer spots you

`_CheckTrainerBattle` (`home/trainers.asm:13`) walks the **map objects** — not the object structs —
skipping the player, and starts a battle when all of these hold, in this order: the object has a
sprite; its type nibble is trainer; it currently has an object struct (the id is not -1, i.e. it is
live on screen); it is facing the player within its **sight range** byte; and the event flag it
points at is not already set.

The order matters for anyone changing a character's identity: **the type is tested second, before
the sight range and before the script pointer is ever read.** A character whose type is not trainer
leaves this scan immediately.

## Which characters block the player, and which do not

When the player takes a step, the destination tile is checked against every object struct by
`IsNPCAtCoord` (`engine/overworld/npc_movement.asm:314`, called from
`engine/overworld/player_movement.asm:634`). A character is **skipped** — the player walks through
it — when it has no sprite, or when **`EMOTE_OBJECT` is set in its `OBJECT_FLAGS1`**. So the game
does have a real "not solid" bit, and it is checked on the player's side. Two details that matter
more than they look:

- **A moving character occupies two tiles.** The check compares the destination against each
  object's current coordinates *and* its `LAST_MAP_X`/`LAST_MAP_Y`. A character mid-step blocks both
  the tile it left and the tile it is entering, so a walking character is a wider obstacle than a
  standing one.
- **`EMOTE_OBJECT` does not mean "emote", and it is destructive.** The bit means **"this object is a
  decoration attached to another character"** — set for the emote bubble, the **jump shadow** and
  the screenshake object alike (`SPRITEMOVEDATA_EMOTE`/`_SHADOW`/`_SCREENSHAKE`), so pass-through
  follows from being a decoration rather than from a general-purpose flag. And when an emote
  despawns, `DespawnEmote` (`engine/overworld/map_objects.asm:2098`) zeroes *every* struct carrying
  that bit, wholesale, ignoring `WONT_DELETE`: a decoration is disposable by design. What tells the
  three apart is `OBJECT_ACTION` — `EMOTE` (8) for the bubble, never for a shadow. [measured
  2026-08-26]

`NOCLIP_OBJS` (`OBJECT_FLAGS1`) is a different thing, easily confused with the above: read in
`engine/overworld/npc_movement.asm:33`, it governs whether **that character's own movement** bumps
into others, not whether the player is blocked by it.

## The three flag bytes on an object struct

Named bits, from `constants/map_object_constants.asm:46-72`. Listed in full because most of them
describe behaviour the game already handles for a character that has them set.

- **`OBJECT_FLAGS1`** (0x04): invisible, won't delete, fixed facing, sliding, noclip tiles, move
  anywhere, noclip objects, emote object.
- **`OBJECT_FLAGS2`** (0x05): low priority, high priority, boulder moving, **in grass**, use OBP1,
  frozen, off screen, **under tiles**.
- **`OBJECT_PALETTE`** (0x06) also carries bits: **swimming**, strength boulder, **big object**.

`IN_GRASS` is set and cleared by the engine as a character moves
(`engine/overworld/map_objects.asm:229-261`); the priority and `UNDER_TILES` bits place a character
behind scenery, and the priority class is also what orders the hardware sprite table (below).

## The rest of the object struct

The full 0x28 (`constants/map_object_constants.asm:3-37`), fields not covered elsewhere:

| Offset | Field | Notes |
| --- | --- | --- |
| 0x0c | step frame | which frame of the walk cycle is showing |
| 0x0e, 0x0f | tile collision, last tile | the terrain under the character |
| 0x16 | radius | how far a wandering character may stray |
| 0x19, 0x1a | sprite x/y offset | **0x1a is the one field carrying every vertical movement a character makes without changing tile** — the bite wiggle, a hop's arc, Teleport's rise, a skyfall. Signed, and the engine's own envelope is ±96 |
| 0x1b, 0x1c | movement index, step index | where the character is in its movement script |
| 0x1f | jump height | accumulates through a ledge hop; indexes the arc curve |
| 0x20 | range | the sight range, copied up from the map object |

**Game Boy WRAM is banked**, and the HRAM byte above sits outside that space entirely — so *where*
a value lives decides how it has to be reached, and a bank-1 address is not reachable the same way
as an HRAM one. [`probes/README.md`](probes/README.md) names the probe behind each field here.

## How many characters the game can hold at once

Two separate budgets, and the smaller one wins:

- **The engine's slots.** 13 **object structs** and 16 **map objects** (`NUM_OBJECT_STRUCTS` /
  `NUM_OBJECTS`). A map spends some of both on its own cast before anything else asks: New Bark
  Town leaves 9 free, Elm's lab also leaves 9 — but **outdoors the structs run out first and
  indoors the map objects do**, because an indoor map declares more map objects than it has
  characters on screen at any moment.
- **The hardware.** 40 sprite entries (`wShadowOAM`, `00:c400`–`00:c4a0`, 4 bytes each) at exactly
  4 per overworld character, so **10 characters can be on screen at once**, player included. Unused
  entries park at `y=160`, one row below the 144-line screen. The Game Boy also drops sprites past
  10 *per scanline*, which ten characters spread vertically never reach. [measured 2026-08-19] at
  60fps, saturated at 40 of 40, all ten drawing. Full table: `agent_docs/crowd-limits.md`.

## The game's UI covers characters by itself

A text box or the pause menu is drawn by the game over the map, and every character underneath it
is covered by hardware priority — the game's own NPCs and any object written into the arrays alike,
with nothing asked of whoever put the character there. A character standing *outside* the panel's
region keeps drawing normally. Confirmed on screen 2026-08-19 with the pause menu open.

**The game keeps a positive "may characters be drawn at all" byte.** Every full-screen UI — the
party menu, the fly map, the PC — calls `DisableSpriteUpdates` (`home/sprite_updates.asm`) on the
way in, clearing `wSpriteUpdatesEnabled` (`$c2ce`): measured `0` on the fly map screen, `1` on the
overworld, and `1` throughout the Fly landing animation. So *"is the overworld sprite engine
running?"* is a question the game answers directly.

**`wStateFlags`' `SPRITE_UPDATES_DISABLED` bit reads BACKWARDS from its name, and that is a trap.**
`_UpdateSprites` (`01:d0ed`, `engine/overworld/map_objects.asm`) does `bit SPRITE_UPDATES_DISABLED_F`
then `ret z` — it returns when the bit is **clear**. So **set means updates RUN**, and
`EnableSpriteUpdates` is what sets it. Anything treating the name as the polarity gets the sprite
engine's state exactly inverted, and the buffer is emptied by the caller, not by this routine.

**Where a box is on screen is a single scratch slot, not a list.** `wMenuBorder*` describes the
**most recent box drawn**, not the union of what is visible — a full-screen party menu publishes
its rectangle, and a "can't use that here" text box drawn on top of it *replaces* those
coordinates. A menu closed normally zeroes the slot (set on frame 9 of the open, cleared on frame 9
of the close); a menu torn down by a warp does **not**, so the coordinates persist until something
else draws a box. [measured 2026-08-26, `probes/menu_state_table.lua`]

## How a walking sprite's tiles become four facings and a walk cycle

A walking overworld sprite is **six views of four tiles** — three standing and three stepping —
and a character's tiles are found **relative to its own tile base** (`OBJECT_SPRITE_TILE`):

| View | Standing | Stepping | Used for |
|---|---|---|---|
| down | 0-3 | 0x80-0x83 | facing down |
| up | 4-7 | 0x84-0x87 | facing up |
| side | 8-11 | 0x88-0x8B | facing **both** left and right |

**There is no left art and no right art.** One side view is drawn as-is for one direction and
mirrored by the hardware for the other — every clean sample agreeing: left unflipped, right
mirrored.

**The stepping views are 0x80 above the standing ones, relative to the character's own base** —
a stride within a sprite's own graphics, not an absolute region of tile memory. Measured on two
characters at two different bases in one session (the player at base 0x00, an Olivine NPC at 0x30).

**In the CARTRIDGE the six views are contiguous**, because ROM has no tile base to be relative to:
VRAM `base + 0..11` are ROM tiles 0-11 and VRAM `base + 0x80..0x8B` are ROM tiles **12-23**, matched
byte for byte on both sprites above. A sprite's graphics are therefore **24 tiles**, even though the
sprite table's size field reports 192 bytes — that field describes the standing half only.

**Which view is drawn is a function of how far through its step a character is**, and the partition
is exact with no overlap, across all four directions: the **stepping** view at 0, 2, 4 and 14
pixels into the step, the **standing** view at 6, 8, 10 and 12.

**The two feet come from mirroring the stepping view**, so the flip carries two unrelated meanings
depending on direction. Facing down or up, both flips are legitimate and alternating between them
is what makes the walk cycle. Facing sideways, the flip says which way the character is looking, so
it cannot also carry the stride — a sideways walk uses one stepping view throughout. Which foot is
selected by the low two bits of `OBJECT_FACING`, the engine's own stride index. [measured
2026-08-22] by logging what the engine drew (`probes/stride_probe.lua` and
`MESHGHOST_CRYSTAL_FACING_TRACE`) against the player and an NPC walking each direction; the two
faults it produced are in `agent_docs/pitfalls.md`.

## The camera: what scrolls the screen, and the register that only looks like it

Two different quantities move when the player walks, and they are easy to mistake for each other.

**`hSCX` / `hSCY` ($ffcf / $ffd0) are the camera.** `ScrollScreen` adds the frame's player step
vector to them, and they are what the background is actually scrolled by: 2px per engine tick on
one axis walking, 4px on the bike. They are 8-bit and wrap at 256, so a difference taken across
frames has to be read the short way round.

**`wPlayerBGMapOffsetX` / `wPlayerBGMapOffsetY` ($d14c / $d14d) are NOT the camera**, despite moving
by the same amounts at the same times. They are a *per-frame delta*: `_HandlePlayerStep` subtracts
the step vector from them (opposite sign to `hSC`), and `ApplyBGMapAnchorToObjects` — reached from
`_UpdateSprites` every frame — reads them, adds them to every object's sprite X and Y as a
correction, and **zeroes them**. So their value is "how far the camera moved since the sprites were
last positioned", returning to zero each frame; integrating them as an absolute position tracks the
camera most of the time and diverges without warning, disagreeing with `hSC` read on the same frame
on about 9% of frames. Consequences before using either:

- **The two run in opposite directions**, so a difference on one is the negation of the same
  difference on the other. **Both scroll registers also run inverted to map pixels** — walking
  right moves the X register the opposite way to the player's map X, and Y behaves the same.
- **The player's sprite does not move when the player walks** — the camera does. The player's
  on-screen position only changes where the camera is clamped, such as near a map edge, so a
  screen-space calculation needs the player's OAM position as well as the camera.
- **The scroll moves whole gait strides and never an odd pixel** — 1, 2 or 4 on vanilla (one per
  gait group), 8 as well on a build with a fourth. **The registers are also REBASED, not only
  scrolled**: a map load or warp is an arbitrary jump with no walking behind it, so a difference
  means something only within one map.
- **A stride lands on ONE video frame, not spread across two**, because the scroll happens on the
  engine tick and a tick is two frames. A turbo ride therefore reads `8, 0, 8, 0` and not `4, 4` —
  and **a reading of half the stride means the sample landed mid-scroll**, which is the single
  easiest way to be wrong here. The average over two frames is half the stride either way, so an
  averaged measurement cannot tell the two apart; only the per-frame histogram can.
- **A camera reading is only as good as how often you take it.** Both quantities are differences;
  miss eight frames of a 2px walk — four ticks — and the next reading is 8px, indistinguishable
  from a jump.

Sources: `ram/wram.asm` and `engine/overworld/map_objects.asm` for the offset pair,
`player_step.asm` for `ScrollScreen`. [measured 2026-08-23] on a hash-verified V1.0.

## Every animation that does not move the character, and what each one is made of

Crystal has a whole family of animations that keep the character on its tile and change only
`OBJECT_ACTION` — turning in place, bumping a wall, spin tiles, whirlpools, fishing, Teleport, Dig.
The position fields sit still through all of them, so **`OBJECT_ACTION` is the only field that can
distinguish them**. (The `!` emote is *not* in this family: it is a separate object, not a pose the
character adopts. Neither is **Fly**, which is not on the object system at all.)

Each action handler's whole job is to write `OBJECT_FACING` — so **the facing byte is the pose**,
and the action byte only says which rule is producing it. That order is not obvious from outside:
the engine looks the facing byte up in the facing list (`data/sprites/facings.asm`) and emits the
sprite parts it finds there, so two characters with the same facing byte are drawn identically no
matter what they are doing.

Reading the facing byte the way the engine does:

| facing byte | what it names | drawn as |
| --- | --- | --- |
| `0x00`–`0x0f` | `STEP_<dir>_<0..3>`: direction is the byte over four, stride is the low two bits | strides 0 and 2 are the **standing** view, 1 and 3 the two **stepping** ones |
| `0x10`–`0x13` | `FISH_DOWN` / `UP` / `LEFT` / `RIGHT` | the character's **standing** view for that direction, **plus a fifth sprite** for the rod — but the bottom half of that view and the rod have both been overwritten in VRAM by the fishing sheet (see `FISHING` below) |
| `0x14` | `EMOTE` | four tiles of the emote box **instead of** the character — and it is a separate object, never a player |
| `0x15` and up | `SHADOW`, the dolls, the tree, boulder dust, shaking grass | scenery; a player object never holds one |
| `0xff` | `STANDING` | **nothing is drawn.** The engine skips the object entirely |

### The engine's object clock runs at half the video rate

Everything below counts in **engine ticks**, not video frames, because that is what the action
handlers count. A tick is **two video frames**: a bump advances its facing once per eight
increments of `OBJECT_STEP_FRAME` in the source and once every **sixteen** video frames on screen
(`probes/bump_probe.lua`, 2026-08-23), and an ordinary step counts down eight units of
`OBJECT_STEP_DURATION` across roughly sixteen video frames.

**Two video frames is the average, not a guarantee.** The tick does not sit on a fixed frame
parity: within one bout of walking the parity holds, across bouts it differs, and two ticks do
sometimes land on consecutive frames. So the counts below are exact in ticks, approximate in frames.

### The classes, one by one — all `engine/overworld/map_object_action.asm` unless named otherwise

- **`BUMP` (3) — walking into a wall.** Holding a direction against something impassable does not
  leave the character standing: Crystal plays a walk-in-place shuffle built out of the two poses the
  character already has, not out of the walk cycle. `OBJECT_WALKING` stays **STANDING** throughout,
  so anything keying off "is this character walking" cannot see a bump; `OBJECT_STEP_DURATION` is
  **0**, so progress-through-a-step derived from it reads as a *completed* step rather than as no
  step; and `OBJECT_ACTION` is the only field that says a bump is happening. `OBJECT_STEP_FRAME`
  counts up one a tick with the stride in **bits 3 and 4**, so the stride advances every **8
  ticks**, the tile alternating between the standing and stepping blocks in 16-frame runs and
  changing three frames before the facing does. **So a bump is a two-pose shuffle at about four
  poses a second, not a stride cycle** — heavier than a walk, which changes pose twice as often, and
  re-issued while the direction is held. [measured 2026-08-23, `probes/bump_probe.lua`]
- **`SPIN` (4)** — turns a character **counterclockwise**: `OBJECT_STEP_FRAME` is used as two
  two-bit fields, a timer in the low bits and a facing index in bits 4 and 5, and the direction
  advances **down → right → up → left** every **4 ticks**. The facing byte is the direction with
  stride 0, so a spinning character always shows a **standing** view. Used for **turning in place**
  (much the most common — see below), the **spin tiles**, a **whirlpool**, and the departure and
  arrival of **Teleport** and **Dig**. The 4-tick cadence is [measured] — the facing cycling
  `0C → 04 → 08 → 00` at **8 video frames each**, identically on a whirlpool and on a Dig
  (`probes/whirlpool_drive.lua`, `probes/dig_drive.lua`, 2026-08-26).
- **`SPIN_FLICKER` (5)** — spins the direction exactly as above and then sets `OBJECT_FACING` to
  `STANDING`, so **the character is not drawn on that tick**. Dig alternates it with `SPIN` on odd
  and even ticks, and that alternation *is* the flicker: present half the time while it spins.
- **`FISHING` (6)** — the facing becomes `FISH_` plus the direction, and **fishing is a graphics
  swap done in place, not just a pose.** The facing table asks for the character's ordinary
  standing view plus one extra sprite for the rod, whose tile id is *absolute* rather than relative
  to the character's tile base. But before the pose is drawn, the cast script loads the rod emote
  and then calls `LoadFishingGFX`, **and the second overwrites what the first loaded**:
  `engine/events/fishing_gfx.asm` copies four two-tile blocks out of a per-gender fishing sheet into
  **VRAM bank 1** — sprite tiles `$02`, `$06` and `$0a`, the **bottom half** of the standing down, up
  and left views, plus `$fc`, the rod. So a fishing character is its own top half over that sheet's
  bottom half; the rod sits below it facing down, above facing up, beside it sideways. **It has no
  fixed length** — held until the script ends it, the one class lasting many seconds. **A bite
  wiggles the character**, alternating `OBJECT_SPRITE_Y_OFFSET` 0/1 for eight ticks, and spawns the
  `!` emote. [measured 2026-08-25/26, `probes/rod_check.lua`, `probes/fish_drive.lua`]
- **`SKYFALL` (0x10)** — a character dropped into the map from above. **This is NOT Fly** (below); it
  belongs to map scripts — the Burned Tower floor-fall, the Ruins chambers. Identical arithmetic to
  a walking step except that `OBJECT_STEP_FRAME` goes up by **two** a tick, so the stride advances
  every **2 ticks**: the walk cycle runs at **double speed** while it falls. The fall is a sprite Y
  offset starting high above the tile; the top phase is 16 ticks at the full `$60`.

### Turning in place is a spin, and it happens constantly

Tapping a direction the character is not already facing turns it without moving it, using the same
counterclockwise `SPIN` for **4 ticks** — two at the old direction, two at the new
(`engine/overworld/map_objects.asm`'s turning step). So a turn passes visibly through an
intermediate direction rather than snapping, and anything reconstructing a pose from position alone
misses it every time a player looks around.

## A newly created object is not drawn for two to four frames

Writing a complete, valid object struct does not put a character on screen that frame: the engine
builds its sprite list from the object array once per frame, so a struct written between frames is
not in the list the next frame draws. [measured 2026-08-23] by dumping hardware OAM every frame —
**no entries at all** on the frame it is created, the four appearing **two or three frames later**;
a later run saw **four**. **The gap varies and the tail is longer than it looks**, so any fixed
number of frames chosen by reasoning is sometimes wrong.

## OAM entry order is by PRIORITY, not by slot

The player's four sprites are commonly the first four OAM entries, and **that is a coincidence of
what else is on screen, not a rule.** `InitSprites` emits objects in priority classes — HIGH, then
NORM, then LOW — and only *within* a class in object-struct order. So the first four entries belong
to the highest-priority object that has a sprite, whoever that is. Observed 2026-08-23 with a
second character nearby: another character occupied entries 0-3 while the player sat further down.

**The cheapest live demonstration is the `!` emote**, a HIGH_PRIORITY object: with one up, the value
read as "the player's OAM y" moved a whole tile (76 → 60) while the player's own tile, sprite
position and offsets never changed. [measured 2026-08-26]

**Anything that identifies a character by its OAM slot is reading whichever character happens to be
there.** What *is* reliable is the tile ids: a character's four parts come from its own 12-tile
block or the same block `0x80` above it, whereas everything that can displace it is drawn from
**absolute** tiles (`$f8`–`$fb` an emote, `$fc`–`$fd` the rod or jump shadow), outside any block.

## Fly is a private cutscene, not an overworld event

`FlyFromAnim` / `FlyToAnim` (`engine/events/field_moves.asm`) zero `wStateFlags`, run their own
frame loop, and animate the flying figure through the cutscene sprite-animation system
(`InitSpriteAnimStruct`) with the current Pokémon's **icon** as the bird. The overworld object
system is suspended throughout and **every character, NPCs included, is hidden**: [measured
2026-08-26] an NPC's `OBJECT_FACING` reads `$FF` (draw-nothing) for the whole sequence, and the
player's object holds action STAND, facing `$FF` and no sprite offset from start to finish. On
completion `FlyToAnim` zeroes all shadow OAM past the player's four entries. **The player's own map
object never runs a skyfall** — `STEP_TYPE_SKYFALL` is for map scripts — so nothing about a Fly
exists as object state at all.

### What the Fly LANDING actually looks like

From `SpriteAnimFunc_FlyTo` (`engine/sprite_anims/functions.asm`) and its setup in `FlyToAnim`:
the sprite is the **Pokémon's icon**, loaded from the mon in `wCurPartyMon` (icons are indirected
twice — a per-species byte gives an icon index, several species sharing one). Its Y starts at
**252** — `depixel 31, 10, 4, 0`, so 31 tiles down wraps past the top of the byte range and is
therefore above the screen — and rises by 2 a frame to 84, the centre tile: **44 frames**. (The
44 only works out from 252; the arithmetic is `(84 − 252) mod 256 = 88`, halved.) A second counter starts at 88, decays by 2 a frame to zero, and scales
a cosine that becomes the sprite's X offset.

**So the landing is a decaying-cosine SPIRAL: the Pokémon swoops down from the top of the screen,
swinging side to side, the swing shrinking to nothing as it settles on the centre tile**, and the
character reappears as it lands. It is neither a vertical fall nor a character animation, which is
why `STEP_TYPE_SKYFALL` cannot resemble it however it is timed.

## Ice: moving at the fast gait while posed STANDING

Crossing an ice tile does not walk the character. `DoPlayerMovement` forces `STEP_ICE`
(`engine/overworld/player_movement.asm`), and what that produces on the player's object is:

| Field | On ice | On an ordinary step |
| --- | --- | --- |
| `OBJECT_WALKING` | `0x0A` — **group 2**, the FAST gait (4px/tick, 4 ticks), the same group the bike uses | group 1 (2px/tick, 8 ticks) |
| `OBJECT_ACTION` | **`1` (STAND)** | `2` (STEP) |
| `OBJECT_FACING` stride | does not advance — the standing view is held | cycles 0-3 |
| `OBJECT_STEP_TYPE` | `6` (PLAYER_WALK) | `6` |

**So a glide is "moving while STANDING", and the action byte is the only field that says so.**
Position, step type and gait all describe a character in motion; nothing but `OBJECT_ACTION`
distinguishes a glide from a fast walk — and the fast gait alone does not identify ice, because the
bike shares group 2. [measured 2026-08-26] across real ice (`probes/ice_probe.lua`).

**`SLIDING` is NOT how the game does it.** `OBJECT_FLAGS1`'s `SLIDING` bit does suppress the walk
cycle — `SetFacingStepAction` (`engine/overworld/map_object_action.asm`) tests it first and jumps to
`SetFacingCurrent` without touching `OBJECT_STEP_FRAME` — but the **player never sets it while
gliding**, measured clear across a whole slide; it belongs to movement-script commands and
permanently-still templates. Two mechanisms reach the same screen and ice uses only one.

## Dig and Escape Rope are ONE routine, and a ledge hop is a two-tile jump

### Dig and Escape Rope

They are not two features. `EscapeRopeFunction` and `DigFunction` differ by a single byte written
to `wEscapeRopeOrDigType` and then fall into the same `EscapeRopeOrDig`
(`engine/events/overworld.asm`), which queues the same script — the only differences either way
being which text box is shown and, for Escape Rope, a `SpecialKabutoChamber` call. That script
plays the warp-out sound, applies a departure movement, warps to the spawn point, loads the
destination map with `MAPSETUP_DOOR`, plays the warp-in sound, and applies a return movement. So:

| phase | movement | what the player's object holds |
|---|---|---|
| departure | `step_dig 32`, then `hide_object` | `Movement_step_dig` writes `OBJECT_ACTION_SPIN` (4) and `STEP_TYPE_SLEEP` with duration 32 — a plain counterclockwise spin in place for 32 engine ticks, **no flicker** |
| arrival | `show_object`, `return_dig 32` | `Movement_return_dig` writes `STEP_TYPE_RETURN_DIG` (0x12), whose handler `StepFunction_DigTo` alternates `OBJECT_ACTION` between `SPIN` (4) and `SPIN_FLICKER` (5) on bit 0 of `OBJECT_STEP_DURATION` — one tick each, for 32 ticks |

[measured 2026-08-26] twice independently: departure 62–64 video frames of action 4 spinning at the
ordinary `SPIN` cadence (above); arrival 63 frames of 4/5 alternating in two-frame pairs. Both are
exactly 32 engine ticks. **The flicker is on the ARRIVAL only.**

**There is no vertical movement anywhere in a Dig** — `OBJECT_SPRITE_Y_OFFSET` read `+0` on every
frame of both captures, matching the source. **Teleport is different and does raise the sprite**:
`StepFunction_TeleportFrom`'s `.DoSpinRise` feeds `OBJECT_JUMP_HEIGHT` through `Sine` into
`OBJECT_SPRITE_Y_OFFSET` over 16 ticks. Teleport is otherwise unmeasured.

### A ledge hop

`.TryJump` (`engine/overworld/player_movement.asm`) matches the tile's collision high nybble
against the ledge range and the facing against its own direction table, plays the hop sound, and
issues `STEP_LEDGE`, which becomes the `jump_step` movement (`JumpStep`,
`engine/overworld/movement.asm`).

**Nothing about the character's own pose says "jump".** `JumpStep` writes the ordinary walking
action (`OBJECT_ACTION_STEP`, 2) and the ordinary walking gait. **The only field that distinguishes
a hop from a step is `OBJECT_STEP_TYPE`** — `STEP_TYPE_PLAYER_JUMP` (9) for the player,
`STEP_TYPE_NPC_JUMP` (8) for anything else, chosen by whether the object is `wCenteredObject`.
**The hop is two tiles run as one continuous motion**, at ordinary walking pace per tile:
`StepFunction_PlayerJump` (and its NPC twin) crosses the first tile, fetches the next, crosses the
second.

**The arc is one curve spanning both tiles.** `UpdateJumpPosition` accumulates
`OBJECT_JUMP_HEIGHT` by the step vector's speed each tick and reads `OBJECT_SPRITE_Y_OFFSET` out of
a fixed sixteen-entry curve indexed by `height >> 1`. Watched on screen, the offset runs **-4, -6,
-8, -10, -11, -12** — holding at -12 across the apex — then back down **-11, -10, -9, -8, -6, -4**
to zero: a hop that rises in six steps and falls in six, slightly flatter coming down. Across
2 tiles x 8 ticks the height runs 0..32, so the index walks that curve exactly once, and **half of
it happens on each tile** — which is why one tile alone only reaches the apex and never descends.

**A hop also spawns a shadow, which is a separate map object.** `JumpStep` calls `SpawnShadow`;
the character's own pose never carries it. Its template gives it no sprite of its own, the emote
palette and the shadow movement data; `MovementFunction_Shadow` parks it at
`OBJECT_SPRITE_Y_OFFSET` = **14** below a character facing down or up and **12** facing left or
right, takes its lifetime from the parent's own step duration, switches to
`STEP_TYPE_TRACKING_OBJECT` to follow the hop, and deletes itself at the end. Its graphics are
**one** tile, drawn twice with the right half X-flipped, making a 16x8 smudge.

**That tile is `$fc`, loaded on demand and shared with the fishing rod** (`data/sprites/emotes.asm`)
— so `$fc` holds the shadow normally and the rod while somebody is fishing.
