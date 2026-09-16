# How Pokémon Emerald works

> Everything here is **what we measured from a running game or what the user saw on screen**, across
> Phases 1–5.5 and 8, with the dated record in `VERIFIED.md`. Every claim carries a `[measured …]`
> / `[player]` / `[user on screen …]` label naming that record, or sits under a heading that does.
> What has been read about the game but not yet measured is not here: it waits as a question in
> `UNVERIFIED.md`. No source text, data table or asset from any decompilation is reproduced here.

How the game does the things a ghost has to look like, per mechanic. Adapter compensations are in
[BANDAGES.md](BANDAGES.md); dated evidence, with addresses from our own byte-identical build, in
[`VERIFIED.md`](VERIFIED.md).

## Where the player's state lives, and why one address is not enough

Emerald keeps player state in two places, and an adapter needs both:

- **`gSaveBlock1Ptr`** — a **pointer**, not a struct. The save block relocates — its value changed
  across a door warp [measured 2026-08-11, `VERIFIED.md`] — so it must be **re-read every frame**
  rather than cached. Player x/y, map bank/number and warp data are read relative to it.
- **`gPlayerAvatar`** — a fixed struct holding how the player is currently *moving*: flags
  (including a dash/running bit), and `runningState`.
- **`gObjectEvents`** — the overworld object array, holding facing and per-object state.

The pointer/fixed-address split is the thing to remember: half the state moves, half does not.

## Movement is tile-based, with a sub-tile phase

The player occupies a tile, and moves between tiles over several frames rather than instantly.
That produces two different notions of "where the player is":

- The **tile** coordinates, which change once per completed step.
- The **visual** position, which slides between tiles during the step.

`runningState` distinguishes them, and its values were behaviour-tested in BizHawk rather than
assumed [measured 2026-08-11, `VERIFIED.md`'s four `runningState` entries]: **0 = not moving,
1 = turning in place, 2 = moving**. Turning in place is a real state in
this game — pressing a direction while stationary turns the character without changing tiles, and
it produces a `1` per direction change.

A tile is **16 pixels**, and a character never moves on both axes at once — there is no diagonal
step. **[player]**

## How a moving character actually works — the engine's step machine (2026-09-12)

**This is the reference any MeshGhost renderer is judged against.** The decompilation said where to
look; every line below is what `probes/npc_step_probe.lua` read off a live NPC
(`probes/npc_step_20260912_220545.log` and `_220639.log`, 2026-09-12) unless it names another
record. An NPC is the engine moving a character with its own machinery, which is exactly what a
ghost has to look like.

### A step is a fixed table, one entry a frame

`NpcTakeStep` moves a character by a fixed per-frame cadence rather than at a rate. The gaits
measured so far:

| Speed | Frames | Pixels per frame | Used by | Evidence |
|---|---|---|---|---|
| `MOVE_SPEED_NORMAL` | 16 | 1,1,1,… | walking | [measured 2026-09-12, `probes/npc_step_20260912_220545.log` and `_220639.log`] |
| running | 8 | not read per frame | running | [measured 2026-08-11, `VERIFIED.md`: tile-change gaps of 8 while the user ran] |

The per-frame pixel split while running and the faster bike tiers are open questions in
`UNVERIFIED.md`.

**Confirmed live on a walking NPC**, one line per frame: `pos1.y` fell by exactly 1 every frame
while the sprite's step timer (`data[5]`) ran 1..16 and reset — and **there is no pause between
steps**. A character that walks two tiles moves 32 frames of 1px, not two bursts with a gap.

### The tile coordinate is a whole tile AHEAD of the pixels

The tile coordinates take the DESTINATION at the moment the step begins (the engine's
`ShiftObjectEventCoords`, whose `previousCoords` keep the tile just left). Measured: the tile flipped
from `23,71` to `23,70` on the same frame the timer reset to 1, with the sprite still a full 16px
short of that tile.

**So "where is this character" has two honest answers during a step**, and they disagree by a whole
tile for the whole step. Anything that mixes them — a mask built from one and a position from the
other, a model that takes the tile as truth mid-step — is wrong for 16 frames out of every 16.

### Motion lives in the sprite's `pos1`, not `pos2`

Across a whole walking NPC capture, `pos1` moved and `pos2` stayed `0,0` [measured 2026-09-12].
`pos2` is where a jump arc shows (`pos2=(0,-4)` mid-arc, `probes/dive_probe.lua`, 2026-08-21) and
where the engine's surf blob bobs its rider (`pos2=0,-3`, `probes/surfblob_probe.lua`, 2026-08-19)
— never ordinary walking. A probe that watches
`pos2` for movement sees an NPC that teleports one tile at a time; that is a real reading this
repo's own instrument produced before it was fixed.

### The walk animation swaps twice per tile

The animation command index advanced every 8 frames while walking (`anim=5/0` for frames 1-8,
`5/1` for 9-16, then `5/2` on the next tile), so one tile shows two animation frames and a step's
pose cannot be derived from the position alone.

### Draw order is by where a character STANDS

Lower on the screen draws in front: a ghost sharing the player's tile goes BEHIND the player, and
the painted tier's reproduction of that rule — the sprite's bottom edge, banded per 16px — matched
the game's own sorting in every facing [user on screen 2026-09-12, `VERIFIED.md`; scope: vanilla, on
foot]. The engine's own subpriorities read 148 for a jump shadow and 135 for landing dust [measured
2026-08-21, `probes/shadowdust_probe.lua`]. The formula the engine computes
(`SetObjectSubpriorityByElevation`: which band, which elevation offset) is an open question in
`UNVERIFIED.md`.

### Why the camera is the part that matters

**The camera is slaved to the player's own sprite.** The world's pixel offset and the player
sprite's own x were read moving ±1px a frame in lockstep while walking — the same amount, in the
same frame [measured 2026-08-14, `VERIFIED.md`: `sx` and `coordOffsetX`].

So the player's sprite does not travel across the screen at all: it sits still and **the world
scrolls under it at exactly the step cadence** — 1px a frame walking, 2px running. Every other
character's screen position is its map position plus `gSpriteCoordOffset`, which is why an NPC
walking towards you moves on screen at the SUM of both cadences, and why a character standing still
appears to move at the camera's rate.

### The bikes are two different machines [user on screen 2026-08-20]

**The Mach bike has speed tiers, and its speed changes mid-ride.** `gPlayerAvatar.bikeSpeed`
(`+0x0B`) is a stable field that reads the tier the rider is at, and each tier is stepped by a fast
movement action — `WALK_FAST` (`0x15`) at the fast tier, `WALK_FASTER` (`0x2D`) at the fastest
[measured 2026-08-20, `VERIFIED.md`]. Sampling the movement action instead caught an ordinary walk
or a turn as often as the fast action (6 steps in 10 fell back to walking pace), which is why the
speed is read from the stable field and sent every frame rather than latched at mount. How the
tier climbs and falls, and what the field reads at the slowest tier, are open questions in
`UNVERIFIED.md`.

**The Acro bike is a family of movement actions, not a speed** [measured 2026-08-20,
`probes/acroride.lua`, `probes/wheelie_watch.lua`, `probes/hopwatch.lua`; user on screen the same
day]. Plain riding reports `RIDE_WATER_CURRENT` (`0x2B`/`0x2C` riding left/right) with the sprite
on the ground on every frame, while `bikeSpeed` stays 0. A wheelie, a hop, a side jump and a turn
jump are their own action ids — the in-place ones (`0x46..0x4D`, `0x7C..0x7F`) hold the tile, the
travelling ones (`0x74..0x7B`, `0x80..0x8B`) move it, and a standing hop is `0x72`/`0x73` against a
travelling `0x76`/`0x77` — and every one of them runs to completion on the engine's own object (a
wheelie pop is 9 busy frames, a wheelie hop 15). Its per-tile cadence is an open question in
`UNVERIFIED.md`.

**What that means for a ghost.** A wheelie, a bunny hop, a side jump and a turn jump are ordinary
MOVEMENT ACTIONS, so they reach a peer the same way any other action
does: through the graphic and the sprite animation on the wire. A ghost reproduces them by wearing
the peer's own graphic and animation frame — it cannot derive them from position, because a wheelie
in place moves nothing at all and a hop moves exactly like a step.

### Surf, Dive and Fly, as the movement model sees them

The states have their own sections further down (the rider plus a second sprite, the underwater bob,
the fishing alignment). This is only how each one MOVES, because that is what a ghost's per-frame
quantum depends on:

- **Surfing is RUNNING speed** — 8 frames a tile, 2px a frame [measured 2026-08-21,
  `probes/ripple_probe.lua`: one ripple per tile, 8 frames and 16px apart].
- **Underwater's cadence, and whether B does anything down there, are open questions** in
  `UNVERIFIED.md` — nothing has been measured below the surface.
- **A peer holding B is not necessarily running.** Running is 8 frames a tile [measured 2026-08-11,
  `VERIFIED.md`]; which conditions the game checks before it lets a player run is an open question
  in `UNVERIFIED.md`. Either way a ghost reads the gait from the object, never from an input.
- **Fly is not movement at all.** It is a field-effect sequence that hides the character and puts it
  on a bird sprite [user on screen 2026-08-26]; nothing steps, so no position describes it.

**The sprite's own step speed sits in `data[4]`**, which read 0 on every sampled frame of a 16-frame
walk [measured 2026-09-12]. That every state above ends as an ordinary movement action reporting its
`MOVE_SPEED_*` there is an open question in `UNVERIFIED.md`.

## Which state machine is running: `gMain.callback2`

Emerald tracks what the game is currently doing as a **function pointer** — the current "callback".
Comparing it against the overworld callback (`CB2_Overworld`) is how you ask *"is the player in the
overworld right now"*, rather than inferring it from whether the data looks reasonable.

Measured behaviour worth knowing [2026-08-11, `probes/battle_probe.lua`, `VERIFIED.md`]: during a
door transition, a battle or a full-screen menu the callback becomes a series of other values and
then **settles back** to the field callback. So the callback is
transient during transitions, not merely on or off.

This matters because outside the overworld the save-block pointers can be mid-update, and reading
them then returns plausible values rather than obviously wrong ones.

## Appearance: the player sprite is gender-dependent and stored in ROM

The overworld player graphics exist as separate sprite sets for the two player characters, with
**separate tables for walking and for running** — running is not the walk cycle played faster, and
treating it as such looked visibly wrong in live testing [measured 2026-08-11, `VERIFIED.md`: the
four faster walk tiers reuse the walk frames, the run pose is its own table].

Both sets live in the ROM the player already owns, which is where anything needing them reads them
from (`agent_docs/licensing.md`'s assets rule).

## Sprites: how one frame's hardware sprite table is built

The GBA draws sprites from a 128-entry hardware table (OAM). Emerald keeps a **shadow copy of all
128 entries inside `gMain`**, rebuilds it once per frame (`BuildOamBuffer`, the hook this adapter
owns), and the whole copy reaches the hardware at the next vertical blank: an entry written into the
shadow at index 64 was drawn by the emulated PPU [measured 2026-08-21, `probes/oaminject_probe.lua`],
and at a frame boundary the shadow and the hardware differ by exactly one frame of phase wherever
sprites are moving [measured 2026-08-21, `probes/oamshadow_probe.lua`].

**`gOamLimit` bounds what the per-frame path touches, not what is transferred.** On the overworld it
read **64** on all 2250 frames sampled; entries 64–127 were never written, never cleared and held
nothing; and **5 of 128 hardware entries were in use** on a town map [measured 2026-08-21,
`probes/oamshadow_probe.lua`]. What the engine itself does with the window above the limit — which
of its own screens or effects park entries there, and whether a matrix pass rewrites the fourth
halfword (the probe saw 0 frames move it) — is an open question in `UNVERIFIED.md`.

**A ground-level overworld character occupies ONE entry**: the player read at entry 1 in Mt Pyre
Exterior, and the scene's characters sat at entries 0..3 underwater [measured 2026-08-21,
`VERIFIED.md`, the fog and underwater entries]. How the engine splits a character across subsprites
at other elevations — a head above a bridge with the feet hidden — has not been measured.

Two fields on that entry do the compositing work the engine gets for free: **priority** (ground
characters read priority 2 [measured 2026-08-21, the fog entry], which is what puts an NPC behind a
roof and under a text window), and the **palette slot**, read live by the hardware, so a character
dims with every fade, cave and weather effect the game applies — and a wrong slot draws the right
pixels in a Pokémon's colours [measured 2026-08-21, `VERIFIED.md`: the orange-blob entry].

**What this means for capacity, in the game's own terms:** the hardware sprite table is never the
thing that runs out. 128 entries, 64 of them not even addressed by the layout pass, and a handful in
use on a normal map — against a **16-entry object-event array** shared by the player, every NPC on
the map, and anything else that wants to be a character. The engine's own array is the binding
limit, and it is not a drawing limit at all.

## Maps are identified by a pair

Map identity is **bank + number**, not a single id. Neither means anything alone. Warp data (which
map a door leads to) is held in the save block.

## What is known to differ under the Archipelago randomizer

Recorded here because it is a property of *that ROM*, and the difference is real and measured:
Archipelago's Emerald patch is a full base-ROM recompile, so **fixed addresses move**. Confirmed
cases: the overworld callback, the player sprite data, the overworld object arrays, the
**graphics-info pointer table** (2026-08-19), and **everything Fly needs** — its task function
pointers, the bird's sprite template and the arc callback, all ROM addresses (2026-08-26). Its own
client reads the save-block pointers, which is why those keep working. **The list keeps growing,
so treat it as examples rather than a boundary**: none of these fail loudly when read at the
vanilla address, they return a plausible value instead.

Full citation trail, including what is and is not covered:
[`agent_docs/risks.md`](../../../../agent_docs/risks.md).

## Surfing: a rider plus a second sprite the game spawns underneath

**[measured]** **A special player state is not just a graphic.** Surfing changes the player's
`graphicsId` like every other special state, and it *also* puts a separate blue Pokémon sprite
under the rider. Give something only the surfing graphic and it renders a rider sitting on nothing,
which is the half a player notices first — so this is the worked example behind
`_template/README.md`'s rule about reproducing the whole effect, animation *and* extras.

**The blob follows an object event id it reads from itself, not the player.** The id sits in the
sprite's own `data[2]`: a blob left behind kept following that id on its own, and a blob built for a
ghost and pointed at it was driven by the engine from then on — position, animation and the rider's
bob (`pos2=0,-3` on the rider while the blob bobs) [measured 2026-08-19, `probes/surfblob_probe.lua`;
user on screen the same day]. This is
the single fact that makes a surfing *anything* possible. How the OBJECT side names its blob (the
engine's `fieldEffectSpriteId`), what the blob's other data slots hold, and the subpriority and
palette slot the engine gives it, are open questions in `UNVERIFIED.md`.

**The blob is described by a sprite template in ROM** (`gFieldEffectObjectTemplate_SurfBlob`; its
OAM shape, size and tiles read off the ROM [measured 2026-08-18, `VERIFIED.md`'s template table]), so
it can be built from that description rather than copied from a live one. That matters practically:
**no blob exists at all unless somebody is already surfing**, so there is nothing to copy from
until the state you are trying to produce already exists.

**Where the blob sits relative to its rider is measured, not derived**: the engine's own blob reads
at OAM offset `0,+8` from its rider, and a copy built without `centerToCornerVec` set drew half a
tile down-right [measured 2026-08-19, the same probe]. Which coordinate helper the engine places
each sprite with is an open question in `UNVERIFIED.md`.

**Underwater is a different mechanism, not a variant of this one.** It bobs the player's own sprite
rather than spawning a companion — see its own section below; how it bobs is open in
`UNVERIFIED.md`.

**Frame size.** The blob's frames are 32×32 — sixteen tiles, the same tile cost as the rider's.

### Getting onto the water is a sequence, not a state change

**[measured 2026-08-21, `probes/dive_probe.lua`]** Surfing does not begin the moment the graphic
changes. `Task_SurfFieldEffect` runs a sequence, and two of its steps were caught on the player's
own object event:

1. **The field-move pose.** The player's graphic becomes the field-move one and it is held.
2. **The jump onto the water.** *Only now* does the graphic become the surfing one, and in the same
   step the character makes a real one-tile jump with an arc, landing on the water tile.

Read live, one line per event, Sootopolis shore:

```
 184 | gfx=3 act=0x39  tile=(38,43)            <- field-move pose
 292 | gfx=2 act=0x3A  tile=(38,44) pos2=(0,-4) <- surfing graphic + JUMP_SPECIAL, mid-arc
```

The two things worth carrying away: **the graphic and the jump arrive together**, and **the jump is
what covers the tile** — anything reproducing this by moving a character onto the water some other
way is not doing what the game does. The jump's action id read `0x3A` in that run.

## Underwater: the character's own sprite is made to bob

**[measured 2026-08-18, `VERIFIED.md`]** Diving warps to a separate map, so an underwater character
and a surface one are never on screen together, and the character arrives wearing the underwater
graphic (`graphicsId` 111 for Brendan, 112 for May). How the engine bobs that sprite is an open
question in `UNVERIFIED.md`.

**Underwater is covered by a full-screen sprite overlay.** The scene is laid over with a grid of
64×64 semi-transparent sprites — measured live: OAM entries 4..23, five columns by four rows,
priority 2, palette 12, covering every pixel — which is what gives the water its drifting light.
Two consequences follow from how the hardware composites it, and both are facts about the game
rather than about any adapter:

- **The engine's own characters sit BELOW the overlay's entries — 0..3 in this scene**, and
  sprite-vs-sprite
  ties are broken by entry number — so they are drawn over the fog rather than under it.
- **The overlay stops blending only where a same-priority, lower-entry-number sprite outranks
  it** — there it draws OPAQUE, one solid grey block per entry rectangle (measured: pure greys,
  181..247, against purple water). The earlier reading, "a semi-transparent sprite cannot blend
  against another sprite", was wrong — the engine's own characters sit in front of the same sheet
  with no artifact; see `FLAGS.md`'s `MESHGHOST_EMERALD_HW_PRIORITY` row for the Mt Pyre run that
  corrected it.

**Nothing else comes with it.** There is no companion sprite (that is surfing), the underwater
graphics declare no reflection, and the graphic is 32×32 like every other special state. The one
asymmetry worth knowing: Brendan's underwater graphic resolves to the player palette slot and
May's to the NPC-special one, though both share the same underwater palette tag.

## Fishing

**Fishing is a multi-stage process with four outcomes, not a state you enter and leave.** Recorded
because an adapter that mirrors a peer has to represent whichever stage they are in, and two of the
outcomes look identical at the end.

**Two kinds of evidence are labelled below.** **[player]** is what happens as experienced by
someone playing it (the user's account, 2026-08-18) and says nothing about the implementation;
**[measured]** is read from memory. Where only `[player]` exists, the code path is still unknown.

The stages:

1. **[measured] Cast.** The player's `graphicsId` changes to the fishing graphic for the whole action —
   `OBJ_EVENT_GFX_BRENDAN_FISHING` (137) or `..._MAY_FISHING` (138). Position, `movementType` and
   `movementActionId` do not change; the player does not move.
2. **[player] Nothing bites.** The rod is put away and it ends.
3. **[player] Something bites and is missed.** Also ends with the rod put away — **the same pose as (2)**,
   so the outcomes are indistinguishable from the final frame alone.
4. **[player] Something bites and the reaction succeeds**, possibly over **several rounds** of timed input,
   and then a **battle starts** — so fishing can end in a different game state entirely, with a
   different object array.

**[measured]** The whole animation plays out in the **sprite's `animNum`**, not in the object's movement fields:

| animNum | meaning |
| --- | --- |
| 0-3 | `ANIM_TAKE_OUT_ROD_*` — south, north, west, east |
| 4-7 | `ANIM_PUT_AWAY_ROD_*` — same order |
| 8-11 | `ANIM_HOOKED_POKEMON_*` — same order |

Observed live on a May save (`VERIFIED.md`, 2026-08-18): `gfx 89 -> 138`, then `anim 3` (take out
rod, east), `anim 7` (put away — a bite that got away), `anim 3` again, `anim 11` (hooked), and
finally back to `gfx 89`. `PLAYER_AVATAR_FLAG_ON_FOOT | PLAYER_AVATAR_FLAG_CONTROLLABLE` stayed set
throughout.

**[measured 2026-08-19, `probes/animtrace.log`] The animation is driven by a TASK, and the sprite
is otherwise paused.** The overworld leaves an idle character's sprite with `animPaused` set — bit
`0x40` of the sprite struct's `+0x2C` byte, read set on the idle player and clear on a ghost whose
animation was running. Nothing about holding a fishing graphic changes that on its own: it is the
fishing task that un-pauses the sprite and lets the frames advance, and once the engine rather than
the adapter was left to drive a ghost's animation, its frames advanced with the player's. Which
object-event bit requests that un-pause, and what exactly it clears, is an open question in
`UNVERIFIED.md`.

**Observed again on a Brendan save, vanilla, 2026-08-19** (`VERIFIED.md`): `gfx 0 -> 137`, then
`anim 3` (take out rod, east) → `anim 11` (hooked, east) → `anim 7` (put away, east) → `gfx 0`,
with the per-frame sprite offset moving between `0,0` and `8,0` throughout. How the game derives
that offset per frame is an open question in `UNVERIFIED.md`.

**Not yet established:** whether fishing also owns a companion sprite the way surfing does
(surfing attaches a separate Pokemon sprite through the object event's `fieldEffectSpriteId`).
`probes/fishing_watch.lua` exists to answer exactly that and has not been run through a full set of
outcomes yet.

## Water tiles, and what the game checks before letting you fish or surf

**[measured]** A tile is one 16-bit word in the map grid (`gBackupMapLayout.map`), and it carries
**three independent things**:

| bits | field | mask |
| --- | --- | --- |
| 0-9 | metatile id | `0x03FF` |
| 10-11 | collision | `0x0C00` |
| 12-15 | elevation | `0xF000` |

The **metatile id** is what selects the behaviour: the id indexes the map's tileset attribute
table (primary tileset below 512, secondary above), and the low byte of that attribute is the
metatile behaviour — `21` read back as `OCEAN_WATER` on the synthesised Littleroot tile [measured
2026-08-18, `probes/watertile.lua`]; the other water behaviours have not been read off a tile.

**Water is NOT impassable.** This is the part that is easy to get backwards: a water tile has
**collision 0** and sits at **`ELEVATION_SURF` (1)**, while the player walks at
`ELEVATION_DEFAULT` (3). You cannot walk onto it because the *elevations differ*, not because it
is solid — and the difference matters, because the game reads that specific outcome: a tile given
the water behaviour *plus* a collision bit blocked the player, which looked like water, and then
refused the rod [measured 2026-08-18, `VERIFIED.md`]. Being blocked looks like water and is not.
The exact conditions the rod check reads are an open question in `UNVERIFIED.md`.

**Using a rod** can be refused, and a refusal shows **the game's
generic "you cannot use that here" message** — the one that also appears when you try to ride a
bike indoors, phrased as advice from the player's father. It is **not** a story-progress gate, and
reading it as one sends an investigation to the save block instead of to the tile in front of the
player. (Described rather than quoted: extracted in-game text is on the Never side of
`_template/README.md`'s Fine/Never table, and identifying the message is the fact that matters.)

Confirmed live 2026-08-18 by editing a Littleroot tile to `id 44 / collision 0 / elevation 1` and
reading back what the game computes for it: `behaviour 21 (OCEAN_WATER)`, with the player at
elevation 3 one tile north. `probes/watertile.lua` does this on demand.

## Wild encounters are per-map data, not a property of the tile

**[user on screen 2026-08-18]** What a tile *is* and what can *appear* on it are two different
systems, and only the first lives in the map grid. Wild encounters belong to the map, and a town
that has none has nothing to bite in water synthesised there: the rod still comes out and the cast
plays. How the game keys and consults that per-map
encounter data, and which branch a cast takes when there is none, are open questions in
`UNVERIFIED.md`.

Littleroot Town defines no wild encounters of any kind, so on water synthesised there the rod comes
out and the cast plays but **no bite is possible, ever**: the tile makes the *action* legal, and only
the map's own encounter data makes the *outcome* happen. A bite, a hook or the battle that follows
needs a map that defines fishing encounters — a route, not a starting town [user on screen
2026-08-18, `probes/watertile.lua`].

## The Acro Bike: three moves, and one action family per move

**Everything the Acro Bike can do, as the player experiences it** [player, 2026-08-20] — the whole
list:

**There is a base state under all three: just riding.** On the bike, moving or standing, doing none
of the moves below — the state each of them is entered from and returned to, and the state a rider
is in for nearly the whole ride.

1. **Ride in a wheelie.** Hold B and move off *before* any hop starts, and the rider travels on the
   back wheel for as long as B is held.
2. **Bunny hop.** Stand still and keep B held; after a moment the rider starts hopping on the spot.
   Once hopping, moving with B still held carries the hop along — so the hop is entered from a
   standstill and only then becomes a hopping ride.
3. **Sideways jump.** From a standstill, not already hopping, press a direction together with B for
   a single jump in that direction. This is the move that clears the rails.

**Each move is a family of four movement actions, one per facing** — **[measured]**, from the
player's own object event across a driven ride (`probes/wheelie_watch.lua`, 2026-08-20). The
families sit at multiples of four and the member is picked by facing, in the engine's own direction
order: south, north, west, east, so **member = base + (direction id − 1)**. Confirmed by driving
the same move twice, facing south and then facing east, and reading the ids that came out:

| Action family | What it is | Frames it takes |
|---|---|---|
| `0x64` `ACRO_WHEELIE_FACE_*` | holding the standing wheelie | completes the frame it is set |
| `0x68` `ACRO_POP_WHEELIE_*` | rising onto the back wheel | 10 |
| `0x6C` `ACRO_END_WHEELIE_FACE_*` | dropping back down | 9 |
| `0x70` `ACRO_WHEELIE_HOP_FACE_*` | one hop on the spot | 15 |
| `0x7C` `ACRO_WHEELIE_IN_PLACE_*` | repeats while B is held with a direction | 7 |
| `0x74`/`0x78` `ACRO_WHEELIE_HOP_*`/`_JUMP_*` | a hop or jump that covers a tile | not exercised in this run |
| `0x80`/`0x84`/`0x88` `ACRO_POP_WHEELIE_MOVE_*`/`WHEELIE_MOVE_*`/`END_WHEELIE_MOVE_*` | riding in a wheelie, one tile at a time | not exercised in this run |

**Every one of them completes.** The engine sets `heldMovementFinished` on the player's object at
the end of each, including `0x6B`, which is a member of the pop-wheelie family: it ran for nine
frames and reported finished on the tenth. **None of these actions can hang** — the engine's own
object retires every one of them on schedule.

**The standing wheelie is a pose the engine re-asserts, not a single long action.** `0x64`'s
family reports finished immediately and is issued again on the following frames, so what looks like
one continuous hold is the same short action repeating for as long as B is down. The hop behaves
the same way: `0x70` for the hop, `0x7C` between hops, over and over.

**The sideways jump is NOT an `ACRO_*` action** — **[measured, 2026-08-21]**. It is the plain
`JUMP_*` family at **`0x42`..`0x45`**, chosen by facing in the same south/north/west/east order.
Worth stating plainly because the rest of this section is one `ACRO_*` family per move, and reading
that block alone will never find this one: the whole family lives four ids below
`JUMP_IN_PLACE_*` (`0x46`), which is where an eye scanning for "the jump ones" tends to stop.

**[player]** It travels one tile sideways without turning. How the engine keeps the facing through
it (a facing lock raised before the jump and dropped after) and how many frames a jump lasts are
open questions in `UNVERIFIED.md`. What IS measured: a held hop is ONE repeating action reporting
one id the whole time, so individual bounces are not visible in anything the object reports
[measured 2026-08-20, `probes/hopwatch.lua`].

## Shadows and landing dust: what raises them, and what does not

**[measured, 2026-08-21, `probes/shadowdust_probe.lua`]** — a probe that finds field effects by the
ROM `images` pointer they draw from, so it identifies them by what they ARE rather than by address.

- **A shadow appears when a jump STARTS.** It is an ordinary sprite at **subpriority 148**, using
  **OBJ palette 0**, positioned at the character's own sprite position plus a per-graphic drop —
  and deliberately WITHOUT the jump arc, so it stays on the ground while the character rises over
  it.
- **Whether the shadow is suppressed over some ground** (grass, water, reflective tiles), and on
  which of the two tiles a jump spans, is an open question in `UNVERIFIED.md`; no jump into grass
  or beside water has been watched for it.
- **Landing dust appears when a jump FINISHES**, on the tile landed on, with a palette resolved from
  the field-effect palette tag (slot 14 in the runs measured). It measured subpriority **135**
  against the shadow's 148, so the dust drew in front — shadow, character, dust, back to front — in
  the runs measured. Whether the engine recomputes the dust's subpriority per frame from the screen
  row, so that the ordering depends on where the jump happens, is an open question in
  `UNVERIFIED.md`.
- **The dust belongs to the TILE, not the character.** It stays where it was born and finishes its
  animation there while the character hops on, which is what makes a run of hops leave a trail of
  puffs rather than one puff dragged along underneath.
- **Both are driven by the jump itself.** A character that merely *walks* onto the tile another
  character *jumped* to gets neither — there is no jump to start a shadow or to finish and raise
  dust. Obvious in hindsight and easy to miss: "it has no dust" turned out to mean
  "it never jumped", not "the dust is drawn in the wrong place".
- **The two effects behave differently, and it matters.** The shadow followed its character frame
  by frame; the dust stayed at its coordinates and played out. Whether the shadow re-finds its
  object by local id every frame — so that anything wearing a borrowed local id inherits somebody
  else's shadow — is an open question in `UNVERIFIED.md`.

## What blocks a character, and where it is written down

**Two entirely separate sources, and a script that reads only one will still walk into things.**

**The map itself.** The loaded map is a grid of one 16-bit word per tile, and that single word carries
three things at once — **[measured]**, 2026-08-20, by dumping a 13x13 grid around the player and
comparing it against the screen (`probes/collisionmap.lua`):

| bits | what it holds |
| --- | --- |
| 0-9 | the metatile id, which is what the tile is drawn from and what its behaviour is looked up by |
| 10-11 | **collision** -- zero means a character may stand there, non-zero means it may not |
| 12-15 | elevation -- the same value that decides which characters collide with each other at all |

So "can I walk onto this tile" is a lookup, not an experiment: read the word, test the two collision
bits. In the confirmed dump the fences, the buildings and the map edge all read non-zero and every
tile of open ground read zero, with elevation 3 -- `ELEVATION_DEFAULT` -- across the walkable area.

**Characters are not in that grid at all.** An NPC standing in a doorway blocks it while the tile
underneath reads free, because object events live in their own array of sixteen entries, each
carrying its own coordinates. Anything deciding where a character can go has to check both: the
tile's collision bits, and whether any live object event is already standing on it.

**The elevation nibble is the same rule that lets a bridge and the water under it hold two
characters on one tile** -- two non-zero, different elevations do not collide, and elevation zero
collides with everything. That is the game's own mechanism, not a special case.

## Maps join two different ways, and only one of them is seamless

**[measured]** A map's header carries a **connections** list (`probes/connections.lua`,
2026-08-20): for each seam, a direction, an offset along the seam, and which map lies on the other
side. A route touching a town is a connection — the engine stitches the two into one continuous
world, you can see across the boundary, and crossing it never fades the screen. A door, a cave
mouth or a stair is a **warp** — a scripted teleport with a fade, recorded in the events data, not
in the connections list. An indoor map simply has no connections at all: measured, its connections
pointer does not point anywhere valid.

**The offset field is what lets one long route border two towns**: measured live, Route 0:26
carries TWO west connections, the second at offset 20 — the neighbor's frame is shifted 20 tiles
along the shared edge.

**Crossing a connection rebases every loaded object, one frame after the map identity changes.**
Measured (`probes/coordwatch.lua`): the frame the save block's map group/number flip, live objects
still hold old-frame coordinates; the next frame every one of them reads shifted by exactly the
seam delta (a city NPC at y=6 reads y=146 after crossing into the 140-tall route above). Nothing
despawns — the same object slots persist with translated coordinates, which is why NPCs near a
seam never visually jump when you cross it.

**Consequence an adapter can rely on:** "is this other map adjacent and visible" is a lookup in
the current map's own connection list, and "hide peers who went indoors" needs no house detection
at all — an indoor map's empty connection list already says it.

## The water ripple a moving character leaves behind

**[measured]** A character moving on water drops a **ripple** behind it — a field effect, not part
of the character's own sprite. What it is, from watching the game's own
(`probes/ripple_probe.lua`, 2026-08-21):

| | |
| --- | --- |
| Sprite | 16x16, `centerToCornerVec` -8,-8, palette tag `0x1005`, subpriority **151** |
| When | **one per tile stepped**, not on a timer — surfing crosses a tile in 8 frames and the ripples land 8 frames and 16 pixels apart |
| Where | the character's sprite position plus `(0, height/2 - 2)` |
| Life | 80 frames, eight animation frames |
| Behaviour | fixed at birth — it does NOT follow the character, it stays on the water it was dropped in |

Its subpriority places it between a reflection (152) and a surf blob (150), i.e. behind the rider
and its Pokemon but in front of the reflection. Ten are alive at once at a steady surfing pace,
which is what a trail looks like: about five tiles of water behind the character.

## Reflections are AFFINE sprites, and that has two consequences

**[measured]** A reflection is not the character's sprite with a flip bit set. `SetUpReflection`
copies the sprite, gives it priority 3 and a different palette, and makes it an **affine** sprite
pointed at OAM matrix 0 — or matrix 1 when the character itself is mirrored. Those two matrices
hold `d = -256` (the vertical flip) and an `a` breathing between 252 and 260, and the engine keeps
them updated every frame; `a` is the sideways shimmer a reflection has.

**Consequence one: the flip is `h - y`, not `h - 1 - y`.** A GBA affine transform is centred on
`h/2` — 16 for a 32-row sprite, not 15.5 — so the hardware samples `texture = 32 - screen`, one row
lower than a flip bit would give. Confirmed against the game's own reflection: its lowest pixel sits
at screen row 108 for a reflection box starting at 86.

**Consequence two: the shimmer moves the SAMPLING, so a feature does not change size.** The
hardware walks the destination and, per screen pixel, samples
`texture = (x - cx) * a / 256 + cx`, truncated. A one-pixel feature therefore shifts by a pixel and
stays one pixel — measured across six frames, the engine's single reflected pixel alternating
between two adjacent columns.

**The vertical offset is the graphic's own height minus two**, read directly off the sprite table:
the player's sprite drawn at top 208, its reflection at 238.

**A character standing on ordinary ground beside water still reflects** — the test is the ground
below the character, not whether it is surfing. Grass, being a NORMAL metatile, covers a
priority-3 sprite completely, so a character two tiles from the shore shows nothing while one a
single tile away shows the topmost sliver of itself.

**And there are TWO KINDS of reflection, not one**: on ice the reflection holds still [user on
screen 2026-08-21, `VERIFIED.md`, Shoal Cave's ice room]. Which routine picks the kind, and whether
the ice one is a plain flip with no matrix behind it, is an open question in `UNVERIFIED.md`. Ice
does not ripple, and neither does a reflection in it.

## A dark cave is a WINDOW, not an overlay

**[measured 2026-08-21, user on screen and live reads in Granite Cave B1F]** The darkness outside a
cave's lit circle is not something drawn on top of the scene. It is **Window 0**: the engine writes
each scanline's lit span into the scanline-effect buffer and DMAs it to `REG_WIN0H` every HBlank,
so outside the circle the layers are simply not displayed. Nothing is painted black — nothing is
painted at all.

Each entry is `(left << 8) | right`, one per scanline, right edge exclusive; rows outside the
circle read `0-0`. Read live in Granite Cave B1F: rows 56–104 lit, `114-126` at the top edge
widening to `96-144` at the middle — centre (120, 80), radius 24. Which flash level that radius
belongs to has not been measured.

**Two consequences.** Anything the hardware draws — backgrounds and sprites alike — is clipped to
the circle for free. And **`WIN0H` and `WIN0V` cannot be read back**: they are write-only, so a
register dump shows garbage. The live shape has to come from the scanline buffer, and whether the
effect is running from `gScanlineEffect` (`dmaDest` = `REG_WIN0H`, non-zero `state`).

## Weather fog is a grid of semi-transparent SPRITES, not a background

**[measured]** In Mt Pyre Exterior the fog is twelve **64×64 sprites in objMode 1**
(semi-transparent), at priority 2, laid out on a 64-pixel grid that covers the screen. They sit
**within the span of OAM entries 3–17 — twelve entries inside a range of fifteen, not a contiguous
block** — with the player measured at entry 1. Underwater the same idea appears with about twenty. It
fades in over a few seconds after the map loads rather than arriving with the first step, so a
freshly loaded savestate shows none of it.

**Characters stay visible because of the ENTRY NUMBER, not the priority.** They share priority 2
with the fog and win the tie by sitting at lower entries, so they draw in front of it while the
fog blends normally everywhere else.

**`BLDY` cannot be read back** — it is write-only on GBA and returns garbage. `BLDCNT` and
`BLDALPHA` read fine; `BLDALPHA` is what animates as the fog fades.

## Ice slides you, and a slide is a movement that does not animate

**[user on screen 2026-08-21]** Sliding on ice renders 1:1 on a ghost. Which forced-movement
routine ice hands control to, and which bits it sets against the conveyor tiles' slide, is an open
question in `UNVERIFIED.md`.

**Which frame gets held is whatever the cycle had reached** — not the animation's first frame.
Measured across three slides: `10/2`, `11/0`, `11/2`.

**Ends when blocked, not after a fixed distance.** Nothing stops a slide but an obstacle, which is
why removing collision (a noclip probe) makes the player slide to the map border.

**The crack-and-fall ice is a different mechanic**: the ice in Shoal Cave's Low Tide Ice Room slides
and never breaks [user on screen 2026-08-21]. Which tiles carry the cracking behaviour and what
drives it is an open question in `UNVERIFIED.md`.

## Standing still is a HELD animation, not an idle one

**[measured 2026-08-21, the `GHOSTPOSE` trace in `VERIFIED.md`; user on screen the same day]** A
character that has stopped does not switch to an "idle" animation. It keeps the
animation it was last playing, stops on whatever command index it reached, and sets `animPaused` —
e.g. facing north after a step reads `animNum 5, animCmdIndex 3` with the pause bit set, and
command 3 of that animation is the standing picture.

**Two things follow.** The pose is the pair plus the pause, so all three have to be reproduced
together. And `animPaused` alone does not hold anything while `animBeginning` is still set: the
engine runs the animation once more before honouring the pause, **and a running animation copies
its frame into the object's tiles** — so the numbers say "standing" while the pixels show a stride.

## A cave mouth fades through WHITE

**[measured]** Not every screen transition fades to black. Entering the Victory Road cave at Ever
Grande fades the palette to **white** — the OBJ palette's channel sum climbs from 747 to 1488
(sixteen colours with every channel at 31) over fourteen frames and holds there for the ~65 frames
of the transition, then the destination map fades in from black. The engine's fades are
`BlendPalette`: every colour moves a fraction of the way toward one target colour, so "how bright
is the scene" is the wrong question — the right one is which colour it is blending toward and by
how much.

## A rider's speed lives in three unrelated places

**[user on screen 2026-08-20]** There is no
one field that says how fast a character is moving. This game keeps it in three, and which one is
authoritative depends on what the character is doing:

- **`gPlayerAvatar.bikeSpeed` (+0x0B)** — the Mach Bike. A *stable* field holding the game's own
  `PLAYER_SPEED_*` value, which maps to a movement action (`FAST` to `WALK_FAST`, `FASTEST` to
  `WALK_FASTER`). Stable is the property that matters: `movementActionId` is transient, so sampling
  it at 15Hz (the send rate) catches an ordinary walk or a turn as often as a fast action.
- **`movementActionId` as `WALK_FAST`** — the muddy slope's forced movement, during which
  `bikeSpeed` reads **0** even though the rider is visibly moving fast. Here the action is the
  reliable source, because the forced movement holds it.
- **`movementActionId` as `RIDE_WATER_CURRENT`** — the Acro Bike, which genuinely moves with the
  ride-water-current transition rather than with any bike-specific one.

**"Stable" and "correct" are different properties**, and this is where they come apart:
`bikeSpeed` is authoritative while riding and deliberately zeroed by the slope's own code.

## The muddy slope: the one place facing and movement disagree

**[measured 2026-08-20, 527 frames of slide-back; user on screen the same day]** The Mach Bike
exists to climb a muddy slope, and below top speed the slope pushes the rider back. Through the
slide the rider's `movementActionId` held `WALK_FAST` while `bikeSpeed` read **0**, and the
character kept **facing north** while travelling **south** (`VERIFIED.md`, the muddy-slope entry).
Which routine does that, whether it raises the object's facing lock, and what it does to the bike's
speed counter are open questions in `UNVERIFIED.md`.

So this is the only ordinary situation in the game where a character's facing and its direction of
travel point opposite ways, and where the field that describes a rider's speed reads zero while
they are visibly moving. Any code that derives one from the other is wrong here and only here.

## Tall grass is a SPRITE, and that makes two different kinds of occlusion

**[measured 2026-08-20, `VERIFIED.md`'s two grass entries; user on screen the same day]** A
character standing in tall grass is hidden from the waist down — and not by the map. The grass
metatile's **top layer is completely empty** (layer type NORMAL, all four top tiles zero in the
dump), so no background layer covers anything at all. Instead the engine draws a **field-effect
sprite** over each character standing in grass: a live one was read for its palette while the
player stood in grass, and its rustle (frames 1,2,3,4,0 at ten game-frames each) was read from the
field-effect template in ROM, tall grass and long grass each with their own.

**Two kinds of occlusion follow, and doing one says nothing about the other.** Scenery — buildings,
roof edges, tree tops — is a metatile's top layer on a background the sprite does not outrank.
Grass is a sprite drawn over the character. A real object event gets both for free; anything else
has to reproduce each separately, and "it hides behind buildings" is not evidence that it hides.

## Two states where the game stops drawing the player as a character

Every other special state is still a character on a tile: a different `graphicsId`, sometimes a
companion sprite, but a person standing somewhere. These two are not, and each breaks a different
assumption.

**Riding Mr. Briney's boat.** Never watched. What the ride does to the player's object, what the
boat object is and how its graphic is loaded are open questions in `UNVERIFIED.md`.

**Fly.** Fly takes the character off the map altogether rather than moving it. The departure is a
field-effect sequence — the field-move pose and the panel showing the Pokémon, a bird that swoops
in, the character carried off on it until the screen fades — and a same-town Fly watched from a
second instance looked right: the departure animation, the bird, and the landing position [user on
screen 2026-08-26]. Which engine states run inside that sequence is an open question in
`UNVERIFIED.md`.

Arrival brings the bird back down and leaves the character on the destination tile, and in the
same-town case the landing position was right [user on screen 2026-08-26]. How the step off the
bird is timed, what the object's map position does during the flight, and whether the engine's
bird can carry a character that is not the player are open questions in `UNVERIFIED.md`.

## Known unknowns

Open questions about **the game**, kept so a later session can strike one through and point at the
section that answered it.

- **What the boat actually does to the object arrays.** Never watched; the question is in
  `UNVERIFIED.md` (2026-09-16), and it is the last movement class with nothing of ours measured.
- **Also open, in `UNVERIFIED.md` since 2026-09-16**: the draw-order formula, the OAM layout pass and
  the window above `gOamLimit`, the blob's object-side link and placement helper, what the game
  checks before letting a player run, the side jump's facing lock and the jump's frame count,
  shadow suppression and binding, the two reflection kinds, the cracking ice, the muddy slope's
  routine — each an `[OPEN]` entry in `UNVERIFIED.md` naming what is ours and what would settle it.
- **Whether a cross-town Fly differs from a same-town one** in anything the arrays show. Only the
  same-town case has been watched.
- **What Teleport does**, in the same terms as Dig and Escape Rope.
- **Which of the randomizer's differences are patch-wide and which are per-seed.** The list of what
  moves has grown every time another seed was looked at, which is why the section on it says to
  treat it as examples rather than a boundary.
- **Whether the sprite-priority rule under a text window matches Crystal's**, where a text box was
  found not to hide characters at all. Emerald's equivalent has never been exercised.
