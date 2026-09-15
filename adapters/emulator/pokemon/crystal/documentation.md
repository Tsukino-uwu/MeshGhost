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
forever?* — applied to prose. No, or merely unclear, means out. Full guidance and the two edge
cases: [adapters/_template/README.md](../../../_template/README.md).

> **Measured from a running game** during Phase 9 (2026-08-17 onward), mostly on vanilla V1.0.
> **Facts are marked `[measured]` or `[seen on screen]` with a date.**

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

1. **At map load** — the map's objects get their structs as the map is built, and a map reload
   rebuilds what a stray write disturbed. [measured 2026-08-18, the map-object dumps in
   `VERIFIED.md`]
2. **At the screen edge** — `CheckObjectEnteringVisibleRange` runs *per step*, and is how characters
   appear as the world scrolls. It scans **one line at the edge the player is walking toward**,
   matching map objects there whose struct id is still `-1`, and does nothing while the player
   stands still: walking down, that line is the row at `wYCoord + 9`, and an object placed there
   was adopted the moment the row scrolled in, while one placed beside the player never was.
   [measured 2026-08-18, `probes/spawn_test2.lua` and `probes/spawn_test3.lua`]

**There is no general "anything unassigned gets picked up" pass.** A character standing inside the
visible area with no struct simply stays absent until one of the two events above reaches it. The
player itself is spawned by `SpawnPlayer`: copy a template map object, convert coordinates, choose
a palette by gender, then `CopyMapObjectToObjectStruct` — a **generic** routine, not a
player-specific one.

## The player's appearance

The player's sprite follows gender and `wPlayerState`: on foot the male player wears
`SPRITE_CHRIS` (1); on the bike a bike sprite replaces it in place (*A mount rewrites tiles in
place*, below) [measured 2026-08-25]; surfing, the whole character becomes `SPRITE_SURF`, one
sprite for both genders -- though its COLOUR is not shared; see "How the game colours a character"
below [measured 2026-09-09, across five builds].

So a character's whole appearance reduces to **gender + player state → one sprite id**. Note the
spawn template hardcodes `SPRITE_CHRIS` whatever the save's gender, so a struct captured at the
instant of spawn does not yet show the final appearance. [measured 2026-08-17,
`probes/object_slot_probe.lua`, two captures of the same spawn]

### How the game colours a character

A sprite id says which picture; the **object palette** says in what colours, and the two are set
independently.

**The player's palette is chosen by gender**, and the player object carries it in `OBJECT_PALETTE`:
a Chris is red and a Kris is blue, in every window once the byte crossed the wire. [user on screen
2026-09-09: V1.1's Chris red everywhere, Speedchoice's Kris blue everywhere]

**The surf blob inherits the rider's palette.** The sprite is shared between genders; the colour is
not, so a surfing character is red or blue exactly as they were on foot. [measured 2026-09-09,
across five builds, and confirmed on screen the same day]

**A palette slot is four BGR555 words, and one of them is the clothing**: rewriting that word
recolours a character's clothes and nothing else, the skin and outline staying the game's own.
[measured 2026-09-10, `probes/set_colour.lua`, four builds; user on screen the same day]

**Eight object palettes are live at once**, four words each, in palette RAM. Reading the *live* RAM
rather than the cartridge's palette table is what makes a colour portable between builds: whatever
put it there -- the base game, a patch, or a player's own choice -- is what is actually on screen.
[measured 2026-09-10, all four builds tested]

**The hardware copies from the SECOND palette block, 128 bytes past the shadow the CPU writes.** A
reader that stops at the shadow sees a value the screen may not be showing yet. [measured
2026-09-10]

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
character outright** — the whole four-tile character becomes `SPRITE_SURF`, one shared blob sprite
for both genders (its palette is still the rider's, so a surfer is red or blue by gender -- see
"How the game colours a character"), with no second object and no rider drawn on top (the opposite of Emerald, which spawns a separate
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

- `OBJECT_ACTION` (offset `0x0b`) selects the rule producing the pose. The values a player's
  object has been read holding: `STAND` (1), `STEP` (2), `BUMP` (3), `SPIN` (4), `SPIN_FLICKER`
  (5), `FISHING` (6); `EMOTE` (8) is held only by the separate emote object. [measured 2026-08-17
  to 2026-08-26, the probes named per class under *Every animation that does not move the
  character*]
- `OBJECT_FACING` (offset `0x0d`) is a flat list rather than a direction plus a frame number:
  `STEP_DOWN_0..3`, `STEP_UP_0..3`, `STEP_LEFT_0..3`, `STEP_RIGHT_0..3` fill `0x00`-`0x0f`, then
  `FISH_DOWN`, `FISH_UP`, `FISH_LEFT`, `FISH_RIGHT` at `0x10`-`0x13`. [measured 2026-08-22,
  `probes/stride_probe.lua`; 2026-08-26, `probes/rod_check.lua`; 2026-09-13, a driven turn]

Three consequences worth stating plainly:

- **Fishing is not a sprite change**, so it does not appear in the `wPlayerState` table above at
  all. It is an action plus a facing on the ordinary character — which is why a character reading
  "fishing" still wears its normal sprite.
- **The "!" emote is not on the character at all.** `SpawnEmote` creates a **separate map
  object** parked directly above the character it belongs to — its hardware sprite sits 16px above
  the character's — so a character's own `OBJECT_ACTION` never becomes `EMOTE`, which is why an
  emote survives the character underneath it walking, turning or being frozen. [measured
  2026-08-26: the emote object appearing moved the first OAM entry from y 76 to 60 while the
  player's own tile, sprite position and offsets held] Its flag, shared with the jump shadow, is
  below (*Which characters block the player*).
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
thing is one byte. `GetStepVector` indexes `StepVectors` with `OBJECT_WALKING & $0F`, and the
table is **three groups of four directions** — so the low nibble carries both the gait and the
direction, and nothing has to be inferred [measured 2026-08-26, the table found by its own byte
signature in four cartridges, and `OBJECT_WALKING` read against it on the bike and on foot]:

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
groups at `0x004700`; an Archipelago seed carries four at `0x0048C9`. **The count is the
cartridge's, not the family's.** [UNVERIFIED.md](UNVERIFIED.md).

**On the Archipelago build, RUNNING is group 2 — the bike's gait — and the fourth group is the faster
bike.** [measured 2026-09-13] with `probes/player_sprite_probe.lua` on an Archipelago V1.0-base seed:
a running player's `OBJECT_WALKING` read `$0A` (group 2, facing left) while its `OBJECT_SPRITE` read
`$65`, one of the two ids that build repoints to a walking-shaped sprite of its own; walking again,
the sprite went back to `$01`. So a runner is told apart from a rider by its **sprite**, never by its
gait. The fourth group is the mode the user has called the turbo bike since 2026-08-26
([VERIFIED.md](VERIFIED.md)).

### The player's movement, as measured

- **Gaits in use** — walking is group 1 and the bike group 2 [measured 2026-08-25, a bike lap:
  `OBJECT_WALKING` `08`/`09`]; ice glides at group 2 in the standing pose (*Ice*, below); on the
  Archipelago build running is group 2 and the fourth group is the faster bike (above).
- **A step's direction and its first pixel land on the same frame.** [measured 2026-09-13, the
  adapter's move trace, both builds]: of 750 step starts after standing, 636 changed the sent
  direction on the frame the position first moved; the other 114 changed it 6-7 frames earlier,
  which is a turn on the spot followed by a step (*Turning in place*, below). The map coordinates
  take the destination on that first frame too [measured 2026-08-18] (*Position*, above).
- **Every tick moves the same distance**: on screen a walk is `2, 0, 2, 0` per video frame
  [measured 2026-08-23] (*The camera*, below), and a tick is two video frames on average, with no
  fixed parity [measured 2026-08-23] (*The engine's object clock*, below).
- **The stepping or standing view shown is `OBJECT_FACING`'s stride** — odd strides step, even ones
  stand — [measured 2026-09-13, a driven turn: `0D` drawn stepping, `0E`/`0C` standing, the same on
  the watching client once it drew the byte verbatim]; and deriving the stride from step progress
  instead made a ghost pedal at double speed on the bike [seen on screen 2026-08-25].

## Map identity

`wMapGroup` (`01:dcb5`) and `wMapNumber` (`01:dcb6`) are consecutive bytes, followed immediately by
`wYCoord` and `wXCoord` — four consecutive bytes in total. Map identity is a **pair**; neither byte
means anything alone. Groups are broadly regional (group 24 is the New Bark Town area).

## What a patched or alternate build moves, and what it does not

Recorded because it is a property of *those cartridges*, and because none of it fails loudly: an
address read on the wrong build returns a plausible value rather than an error. Facts only -- the
per-build address tables live in the adapter's own source, and the measurements in
[`VERIFIED.md`](VERIFIED.md).

**A build identifies itself from its header.** The title bytes, the version byte and the global
checksum are together enough to tell these five apart. [measured 2026-09-09]

**Vanilla V1.1 against V1.0:** one WRAM label moves; a few hundred ROM bytes differ, none of them
inside the regions this adapter reads. [address only: byte-identical build, 2026-09-09]

**Speedchoice v8.1** inserts one byte ahead of the coordinate block, so the map group, the map
number and the Y/X coordinates -- and the party species -- all sit one byte later than vanilla. The
object array, the map-object table, both gate bytes, both scroll offsets and the HRAM scroll pair do
not move. [address only: byte-identical build, 2026-09-09]

**ROM tables move on Speedchoice but carry vanilla's contents at the new address** -- with one
exception that matters: a table whose *entries are themselves addresses* cannot be relocated
wholesale, so it has to be read at the new location rather than assumed. The overworld sprite table
is byte-identical to vanilla's, which is why a sprite id means the same thing on both. [measured
2026-09-09, each table compared by hash between the user's cartridge and vanilla]

**The Archipelago builds rearrange WRAM non-uniformly** -- no constant offset recovers vanilla, so
each address is measured rather than derived. Some vanilla addresses do survive unchanged, which is
a coincidence to verify per address and not a rule. There are two Archipelago bases, one on V1.0
and one on V1.1, and one address table serves both. [measured 2026-09-09; both bases in one room
2026-09-10]

**Treat this as examples rather than a boundary.** The list has grown every time another build was
looked at.

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
address space everything else here lives in) with a `MAPSETUP_*` value, and it is zero again once
play resumes. `$F5` is `MAPSETUP_DOOR`, `$FC` is `MAPSETUP_FLY`. So for a short window after
arriving, the game itself can say whether the player
walked through a door, flew, or was warped by a script. **But not everything gets its own value**:
a Dig or an Escape Rope arrives wearing `MAPSETUP_DOOR`, indistinguishable from a door from the
outside. [measured 2026-08-23/26, `probes/transition_probe.lua` and `probes/fly_probe.lua`]

## Forced movement: a script freezes every other character

Some tiles take control of the player rather than blocking them — a whirlpool is the clearest case.
**While the whirlpool spins the player, every other character on the map — the game's own NPCs
included — stops where it stands, mid-step included**, and resumes when the sequence ends,
completing its interrupted step normally. [measured 2026-08-26, `probes/whirlpool_drive.lua`] An
object caught in it held five of eight ticks of a step — 10px of 16 — for about 60 frames, thawing
exactly as the player's spin finished. **The game does this to itself**, so a frozen character is
correct.

## Battles

`wBattleMode` (`01:d22d`): `0` none, `1` wild, `2` trainer.

**A battle is invisible to the map state machine** — `wMapStatus` stays `HANDLE` throughout, so
battle state cannot be inferred from map state. Object structs are not cleared on battle entry.

## What a character IS: type, sight range, and script

A map object's 16 bytes begin with the object-struct id, the sprite, y and x [measured 2026-08-18,
the map-object dumps in `VERIFIED.md`]. Further in sit a byte whose **low nibble is the object's
TYPE**, a **sight range** byte, a script pointer and an event flag: a ghost cloned wholesale from an
NPC inherited that NPC's dialogue until the pointer and flag were zeroed [user on screen
2026-08-18], and one cloned from a trainer inherited the trainer's type nibble — **`2`** — and its
sight range of 4 [measured 2026-08-23, the adapter's own spawn log]. The type decides what happens
when the player faces the character: **a type-0 object's script pointer is dereferenced and run**,
so a character with type 0 and a blank pointer is not inert — it is a jump through a null pointer,
and it froze the game. [user on screen 2026-08-18]

## How a trainer spots you

A trainer is a map object whose type nibble is trainer, and its sight range byte is how far it
looks: a ghost cloned from one, keeping both, raised the `!` and started the trainer script when
the player walked into its line of sight. [user on screen 2026-08-23, twice]

## Which characters block the player

A character with a sprite and an object struct is solid: the player bumps into it, a spawned ghost
included. [seen on screen 2026-08-18]

**`EMOTE_OBJECT` (`OBJECT_FLAGS1`) does not mean "emote".** The bit is carried by the emote bubble
and by the **jump shadow** alike, so it alone cannot identify an emote. What tells the two apart is
`OBJECT_ACTION` — `EMOTE` (8) for the bubble, never for a shadow. [measured 2026-08-26: a hop's
shadow matched an emote check written on the flag, and the action byte separated them]

`OBJECT_FLAGS1` also carries a bit named `NOCLIP_OBJS`. What either bit does to collision has not
been measured ([`UNVERIFIED.md`](UNVERIFIED.md)).

## The three flag bytes on an object struct

`OBJECT_FLAGS1` (0x04), `OBJECT_FLAGS2` (0x05) and the high bits of `OBJECT_PALETTE` (0x06) hold
the behaviour bits the engine reads for a character. Two have been measured:

- **`WONT_DELETE`** (`OBJECT_FLAGS1`, bit 1) keeps an object whose tile and spawn tile have both
  scrolled out of the window from being deleted. [measured 2026-08-18]
- **`SLIDING`** (`OBJECT_FLAGS1`) stops the walk cycle while the object moves: set on a ghost, its
  stride no longer advanced. [measured 2026-08-26; user on screen: *"ice works now. confirmed"*]

The remaining named bits wait in [`UNVERIFIED.md`](UNVERIFIED.md). The priority class is what
orders the hardware sprite table (below).

## The rest of the object struct

Of the 0x28 bytes, the fields not covered elsewhere that have been measured:

| Offset | Field | Notes |
| --- | --- | --- |
| 0x0c | step frame | counts the walk cycle; a bump's stride sits in its bits 3 and 4 [measured 2026-08-23, `probes/bump_probe.lua`] |
| 0x1a | sprite y offset | **the one field carrying every vertical movement a character makes without changing tile** — the bite wiggle, a hop's arc [measured 2026-08-26, `probes/fly_probe.lua` reads through a bite and a hop]. Signed |
| 0x1f | jump height | rises through a ledge hop [measured 2026-08-26] |
| 0x20 | range | the sight range, copied up from the map object [measured 2026-08-23, a ghost cloned from a trainer carried its 4] |

The fields between them wait in [`UNVERIFIED.md`](UNVERIFIED.md).

**Game Boy WRAM is banked**, and the HRAM byte above sits outside that space entirely — so *where*
a value lives decides how it has to be reached, and a bank-1 address is not reachable the same way
as an HRAM one. [`PROBES.md`](PROBES.md) names the probe behind each field here.

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

**This section said until 2026-09-09 that every character under a box is covered by hardware
priority. That is true of a MENU and false of a TEXT BOX**, and the difference cost an evening. The
2026-08-19 confirmation it rested on was of the pause menu, generalised to boxes in general. There
are three mechanisms here, not one:

**1. A text box does not hide characters at all.** Its tiles carry palette 7 with the CGB priority
bit **clear**, and an NPC's hardware sprites stay live inside the box's rows with no behind-BG bit
anywhere. The game draws its characters *over* its text boxes. [measured 2026-09-09]

**2. A menu hides characters by not drawing them, and which characters differs by build.** Vanilla
clears the whole sprite engine on the way in (below); one patched build removes only its NPC's
hardware entries under the pause menu and keeps the player's; another keeps sprites running beside
its menu entirely. Under a frameless status panel, one build kept an NPC's entry live where another
deleted it. So "a menu is open" does not by itself say what is still on screen. [measured
2026-09-09, across five builds]

**3. Whether a published rectangle is actually on screen is answered by its own frame.** The tile at
the rectangle's top-left is the box frame's corner tile -- the same tile the text-box test reads --
and if it is not drawn, the rectangle is stale. This is the game's own answer to a question
`wMenuBorder*` alone cannot settle (see the scratch-slot paragraph below). [measured 2026-09-09]

A character standing *outside* a panel's region keeps drawing normally in every case.

**The game keeps a positive "may characters be drawn at all" byte.** A full-screen UI clears
`wSpriteUpdatesEnabled` (`$c2ce`) on the way in: measured `0` on the fly map screen, `1` on the
overworld, and `1` throughout the Fly landing animation. So *"is the overworld sprite engine
running?"* is a question the game answers directly. [measured 2026-08-26, from a prepared
savestate; user on screen the same day: no ghost over the fly map screen]

`wStateFlags` carries a bit named `SPRITE_UPDATES_DISABLED`; which way it reads has not been
measured ([`UNVERIFIED.md`](UNVERIFIED.md)).

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
pixels into the step, the **standing** view at 6, 8, 10 and 12 — **at the walk**. On the bike that
partition is wrong: a ghost posed from it pedalled at double speed [seen on screen 2026-08-25], and
the view drawn follows `OBJECT_FACING`'s own stride (*The player's movement, as measured*, above).

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
by the same amounts at the same times, in the opposite direction: integrating them as an absolute
position tracks the camera most of the time and diverges without warning, disagreeing with `hSC`
read on the same frame on about 9% of frames. Consequences before using either:

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

[measured 2026-08-23] on a hash-verified V1.0.

## Every animation that does not move the character, and what each one is made of

Crystal has a whole family of animations that keep the character on its tile and change only
`OBJECT_ACTION` — turning in place, bumping a wall, spin tiles, whirlpools, fishing, Teleport, Dig.
The position fields sit still through all of them, so **`OBJECT_ACTION` is the only field that can
distinguish them**. (The `!` emote is *not* in this family: it is a separate object, not a pose the
character adopts. Neither is **Fly**, which is not on the object system at all.)

Each action handler's whole job is to write `OBJECT_FACING` — so **the facing byte is the pose**,
and the action byte only says which rule is producing it. That order is not obvious from outside:
two characters with the same facing byte are drawn identically no matter what they are doing, and
a ghost that copies the byte verbatim is drawn as its peer was. [measured 2026-08-22,
`probes/stride_probe.lua`; 2026-09-13, a driven turn drawn the same on the watching client]

Reading the facing byte the way the engine does:

| facing byte | what it names | drawn as |
| --- | --- | --- |
| `0x00`–`0x0f` | `STEP_<dir>_<0..3>`: direction is the byte over four, stride is the low two bits | strides 0 and 2 are the **standing** view, 1 and 3 the two **stepping** ones [measured 2026-08-22, 2026-09-13] |
| `0x10`–`0x13` | `FISH_DOWN` / `UP` / `LEFT` / `RIGHT` | the character's **standing** view for that direction, **plus a fifth sprite** for the rod — but the bottom half of that view and the rod have both been overwritten in VRAM by the fishing sheet (see `FISHING` below) [measured 2026-08-26] |
| `0xff` | `STANDING` | **nothing is drawn** [measured 2026-08-26: every character through a Fly] |

The values between `0x14` and `0xfe` — the emote box and the scenery poses — have not been read
off an object ([`UNVERIFIED.md`](UNVERIFIED.md)).

### The engine's object clock runs at half the video rate

Everything below counts in **engine ticks**, not video frames, because that is what the action
handlers count. A tick is **two video frames**: a bump advances its facing once per eight
increments of `OBJECT_STEP_FRAME` in the source and once every **sixteen** video frames on screen
(`probes/bump_probe.lua`, 2026-08-23), and an ordinary step counts down eight units of
`OBJECT_STEP_DURATION` across roughly sixteen video frames.

**Two video frames is the average, not a guarantee.** The tick does not sit on a fixed frame
parity: within one bout of walking the parity holds, across bouts it differs, and two ticks do
sometimes land on consecutive frames. So the counts below are exact in ticks, approximate in frames.

### The classes, one by one

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
  stride 0, so a spinning character always shows a **standing** view. Used for the **spin tiles**, a
  **whirlpool**, and the departure and arrival of **Teleport** and **Dig** — not for turning in place
  (below). The 4-tick cadence is [measured] — the facing cycling
  `0C → 04 → 08 → 00` at **8 video frames each**, identically on a whirlpool and on a Dig
  (`probes/whirlpool_drive.lua`, `probes/dig_drive.lua`, 2026-08-26).
- **`SPIN_FLICKER` (5)** — spins the direction exactly as above and then sets `OBJECT_FACING` to
  `STANDING`, so **the character is not drawn on that tick**. Dig alternates it with `SPIN` on odd
  and even ticks, and that alternation *is* the flicker: present half the time while it spins.
- **`FISHING` (6)** — the facing becomes `FISH_` plus the direction, and **fishing is a graphics
  swap done in place, not just a pose.** The pose is the character's ordinary standing view plus
  one extra sprite for the rod, drawn from a tile outside the character's own block. But before
  the pose is drawn, the cast loads a per-gender fishing sheet over the character's graphics — the
  **bottom half** of the standing views and the rod tile both come from that sheet, not from the
  rod emote the cast loaded a moment earlier, **the second load overwriting the first**. So a
  fishing character is its own top half over that sheet's bottom half; the rod sits below it
  facing down, above facing up, beside it sideways. **It has no fixed length** — held until the
  script ends it, the one class lasting many seconds. **A bite wiggles the character**,
  alternating `OBJECT_SPRITE_Y_OFFSET` 0/1 for eight ticks, and spawns the `!` emote. [measured
  2026-08-25/26, `probes/rod_check.lua`, `probes/fish_drive.lua`; user on screen 2026-08-26 once
  the ghost's rod was read from the sheet]
- **`SKYFALL` (0x10)** — a character dropped into the map from above. **This is NOT Fly** (below); it
  belongs to map scripts — the Burned Tower floor-fall, the Ruins chambers. Identical arithmetic to
  a walking step except that `OBJECT_STEP_FRAME` goes up by **two** a tick, so the stride advances
  every **2 ticks**: the walk cycle runs at **double speed** while it falls. The fall is a sprite Y
  offset starting high above the tile; the top phase is 16 ticks at the full `$60`.

### Turning in place is a STEP that goes nowhere, and it happens constantly

Tapping a direction a standing player is not facing turns it without moving it, and **it goes
straight from the old direction to the new one, with the STEP action, not `SPIN`.** [measured
2026-09-13, the adapter's move trace on an Archipelago V1.0-base seed, turns driven by
`probes/turn_drive.lua`, left → right]: `OBJECT_STEP_TYPE` `10`, `OBJECT_ACTION` `2`; `OBJECT_FACING`
`08` (left, standing) for three frames, then `0D` — **right, stride 1, a STEPPING view** — for eight
frames, then `0E` (stride 2) for two, then `0C`. So a turn shows the new direction's stepping pose
for a moment before settling, and anything reconstructing a pose from position alone, or gating the
stepping view on the character moving, shows a snap instead.

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

Fly plays as a cutscene of its own, with the current Pokémon's **icon** as the bird, and the
overworld object system shows nothing while it runs: **every character, NPCs included, is
hidden**. [measured 2026-08-26, `probes/fly_probe.lua`] An NPC's `OBJECT_FACING` reads `$FF`
(draw-nothing) for the whole sequence, and the player's object holds action STAND, facing `$FF`
and no sprite offset from start to finish — so **nothing about a Fly exists as object state at
all**, and the player's own object never falls into the map.

### What the Fly LANDING actually looks like

**The landing is a decaying SPIRAL: the Pokémon swoops down from the top of the screen, swinging
side to side, the swing shrinking to nothing as it settles on the centre tile**, and the character
reappears as it lands. [user on screen 2026-08-26, a ghost's landing beside the player's own, same
town and another town] It is neither a vertical fall nor a character animation, which is why
`STEP_TYPE_SKYFALL` cannot resemble it however it is timed. The curve's numbers have not been
read off the game ([`UNVERIFIED.md`](UNVERIFIED.md)).

## Ice: moving at the fast gait while posed STANDING

Crossing an ice tile does not walk the character. What a glide produces on the player's object is:

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
cycle — set on a ghost, its stride stopped advancing [measured 2026-08-26; user on screen: *"ice
works now. confirmed"*] — but the **player never sets it while gliding**, measured clear across a
whole slide. Two mechanisms reach the same screen and ice uses only one.

## Dig and Escape Rope, and a ledge hop is a two-tile jump

### Dig and Escape Rope

Both play the same two-phase animation, and a peer's Escape Rope and a peer's Dig look alike on
screen [user on screen 2026-08-26]. The item warps out, arrives on the destination map wearing
`MAPSETUP_DOOR` (*Warps*, above), and the player's object holds:

| phase | what the player's object holds |
|---|---|
| departure | `OBJECT_ACTION` `SPIN` (4) — a plain counterclockwise spin in place for 32 engine ticks, **no flicker** — and then the character is hidden |
| arrival | the character shown again, `OBJECT_ACTION` alternating `SPIN` (4) and `SPIN_FLICKER` (5) one tick each, for 32 ticks |

[measured 2026-08-26] twice independently: departure 62–64 video frames of action 4 spinning at the
ordinary `SPIN` cadence (above); arrival 63 frames of 4/5 alternating in two-frame pairs. Both are
exactly 32 engine ticks. **The flicker is on the ARRIVAL only.**

**There is no vertical movement anywhere in a Dig** — `OBJECT_SPRITE_Y_OFFSET` read `+0` on every
frame of both captures. Teleport is unmeasured ([`UNVERIFIED.md`](UNVERIFIED.md)).

### A ledge hop

**Nothing about the character's own pose says "jump".** A hopping character carries the ordinary
walking action (`OBJECT_ACTION_STEP`, 2) and the ordinary walking gait. **The only field that
distinguishes a hop from a step is `OBJECT_STEP_TYPE`** — `STEP_TYPE_PLAYER_JUMP` (9) on the
player, `STEP_TYPE_NPC_JUMP` (8) on any other object. **The hop is two tiles run as one continuous
motion**, at ordinary walking pace per tile: an object given step type 8 crosses both tiles by
itself, and would overshoot if it were also walked. [measured 2026-08-26, `probes/ledge_drive.lua`
and `probes/fly_probe.lua`]

**The arc is one curve spanning both tiles.** Watched on screen, `OBJECT_SPRITE_Y_OFFSET` runs
**-4, -6, -8, -10, -11, -12** — holding at -12 across the apex — then back down **-11, -10, -9,
-8, -6, -4** to zero: a hop that rises in six steps and falls in six, slightly flatter coming
down, half of it on each tile. [measured 2026-08-26, the same probes]

**A hop also spawns a shadow, which is a separate map object**; the character's own pose never
carries it. It wears `EMOTE_OBJECT`, like the emote bubble (*Which characters block the player*,
above), and its graphics are drawn from a tile outside any character's block. [measured 2026-08-26;
user on screen the same day: a shadow under both ghosts] How the game places it under the
character, how long it lives and which tile it shares with the rod are in
[`UNVERIFIED.md`](UNVERIFIED.md).

## Maps join two ways, and the game itself draws the line

Crystal joins maps by **connection** or by **warp**, and the difference is the whole basis for
deciding which other characters you can see.

A **connection** is a seam: two outdoor maps sharing an edge, walked across without a fade, with
the world continuous on both sides. The engine decodes the current map's connections into WRAM on
every map load — a direction bitmask at `wMapConnections` followed by four 12-byte structs in the
order north, south, west, east. Direction bits are EAST `0x01`, WEST `0x02`, SOUTH `0x04`,
NORTH `0x08`. **Only the directions the bitmask claims are live**: an unflagged struct still holds
whatever the previous map left there.

A **warp** is a door, a cave mouth, a Fly. The screen fades, the world is rebuilt, and the two
sides share no coordinate space at all. **An interior is only ever reached by a warp**, and an
interior map carries `mask=00` — no connections whatsoever.

So "a character on a connected map is visible, anyone else is not" is the game's own rule, and it
needs no special case for buildings.

**A map's dimensions are in BLOCKS of 2x2 tiles** (`wMapWidth`, `wMapHeight`), while characters
live in tiles — every dimension doubles before it meets a coordinate. **An object's coordinates
carry a +4 border offset** relative to the map's own tile grid, so a character standing one tile
off the west edge reads `3` in object space, not `-1`.

Crossing a seam is a genuine map load: the object array is rebuilt and the map-load byte is
stamped, exactly as for a warp. What differs is that nothing fades and the player keeps walking —
so anything the game holds back "until the world settles" is measured against a screen that never
went away.

Measured 2026-08-27 across ~90 driven crossings on two seams; addresses and the coordinate
arithmetic in `VERIFIED.md`.

## Tile collision: the loaded tileset, and a map edge that stays solid

- **The loaded tileset's header in WRAM is a byte-for-byte copy of one 15-byte entry of a table in
  the ROM**, and it moves with the tileset. [measured 2026-09-13, `probes/tileset_header_probe.lua`,
  which finds the ROM table by the shape of its entries and then every entry in WRAM]: on vanilla V1.0
  the table at ROM `$4D596` and the header at WRAM flat `$11D9` — exactly the `.sym` addresses of
  `Tilesets` and `wTileset` from our byte-identical build; on an Archipelago V1.0-base seed the table
  at ROM `$4D46B` and the header at flat `$11E0`. Both builds: 37 entries, one WRAM match, stable
  across six reads a second apart.
- **Pointing the header's collision pointer (`wTilesetCollisionAddress`, flat `$11E0` vanilla /
  `$11E7` Archipelago) at a table of our own changes what the player may walk on.** [seen on screen
  2026-09-13 by the user, with `probes/noclip.lua` on both builds]: the player walked where the
  original table blocks them.
- **A map's outer edge stayed solid when every tile of the map had been opened that way.** [seen on
  screen 2026-09-13 by the user]
- **The CPU-visible WRAM zero run `$C8C0-$CD1F` is identical on vanilla V1.0 and the Archipelago
  seed**, while every zero run at `$D000` and above moved between them. [measured 2026-09-13,
  `probes/zero_runs_probe.lua`, ten seconds of re-reads with no byte of it changing]

## Known unknowns

Open questions about **the game**, kept here so a later session can strike one through and point at
the section that answered it rather than re-deriving that it was ever open.

- ~~**What decides the fourth gait on the Archipelago build.**~~ Answered 2026-09-13 in *How a
  character crosses a tile*: it is the faster bike, and running uses group 2 with a sprite of its own.
  What SELECTS either on that build was not measured and is not recorded here.
- **Whether the object-struct layout is identical on every Archipelago seed**, or only on the two
  base patches looked at so far. Measured per build, never derived.
- **Which colours a coloured Archipelago seed assigns, and where it writes them.** The
  clothing-colour mechanism was exercised with a probe rather than with a seed that chose colours.
- **What Teleport does to the object arrays.** Fly and Dig are mapped; Teleport is not.
- ~~**RUNNING's gait on the Archipelago build**~~ -- measured 2026-09-13: group 2, sprite `$65`
  (*How a character crosses a tile*).
- **Why a map's outer edge stays solid** when every tile inside the map reads as walkable, and what
  one step past an edge with no neighbouring map would do.
- **Whether a moving player ever turns before stepping**, and how long input stays locked after a turn
  on the spot.
- **What resets `wPlayerBGMapOffsetX/Y`**, and so what produces their 9% disagreement with `hSC`.
