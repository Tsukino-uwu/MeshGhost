# How Pokémon Emerald works

<!-- line-cap: 900 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

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

> Everything here is **measured from a running game** across Phases 1–5.5 and 8, and cross-checked
> against the public `pret/pokeemerald` decompilation, which is cited by file so any claim can be
> re-checked. **No source text, data table, or asset from that decompilation is reproduced here** —
> only facts, per `agent_docs/licensing.md`.

**What this file is: how *the game* does things**, per mechanic, in our own words. **Nothing here
describes an adapter workaround** — those belong in [BANDAGES.md](BANDAGES.md).

Dated evidence for every claim, with addresses cited to the decomp build:
[`VERIFIED.md`](VERIFIED.md).

**Written 2026-08-18**, after this adapter had already shipped. It was previously argued
that a `documentation.md` was unnecessary for a game with a decompilation. That was overturned by
the user: a curated description of *the mechanics this adapter actually depends on* is a different
artifact from a decompilation, and "we can look it up" does not survive a session where nobody does.

## Where the player's state lives, and why one address is not enough

Emerald keeps player state in two places, and an adapter needs both:

- **`gSaveBlock1Ptr`** — a **pointer**, not a struct. The save block can relocate, so it must be
  **re-read every frame** rather than cached. Player x/y, map bank/number and warp data are read
  relative to it.
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
assumed: **0 = not moving, 1 = turning in place, 2 = moving**. Turning in place is a real state in
this game — pressing a direction while stationary turns the character without changing tiles, and
it produces a `1` per direction change.

A tile is **16 pixels**.

## Which state machine is running: `gMain.callback2`

Emerald tracks what the game is currently doing as a **function pointer** — the current "callback".
Comparing it against the overworld callback (`CB2_Overworld`) is how you ask *"is the player in the
overworld right now"*, rather than inferring it from whether the data looks reasonable.

Measured behaviour worth knowing: during a door transition the callback briefly becomes a series of
warp/fade/map-load handlers and then **settles back** to the field callback. So the callback is
transient during transitions, not merely on or off.

This matters because outside the overworld the save-block pointers can be mid-update, and reading
them then returns plausible values rather than obviously wrong ones.

## Appearance: the player sprite is gender-dependent and stored in ROM

The overworld player graphics exist as separate sprite sets for the two player characters, with
**separate tables for walking and for running** — running is not the walk cycle played faster, and
treating it as such looked visibly wrong in live testing.

The adapter decodes those graphics out of the player's own ROM at runtime rather than shipping any
image (`agent_docs/licensing.md`'s assets rule).

## Sprites: how one frame's hardware sprite table is built

The GBA draws sprites from a 128-entry hardware table (OAM). Emerald never writes that table
directly during play. It keeps its own **shadow copy of all 128 entries inside `gMain`**, rebuilds
that copy once per frame from its sprite list (`BuildOamBuffer`, which finalises sprite animation
first and then lays out the entries), and transfers it to the hardware during the next vertical
blank (`LoadOam`). So what is on screen for a frame is decided before the frame is drawn, in one
place, from one buffer.

**`gOamLimit` bounds the WRITE CURSOR, not the transfer, and the difference is the interesting part.**
On the overworld the engine sets it to **64**: the layout pass stops adding entries there, and its
tail loop — which fills anything it did not use with a dummy entry parked off-screen at priority 3 —
also stops there. Entries **at or above the limit are neither written nor cleared by the per-frame
path**. The transfer, meanwhile, is unconditional and copies **all 128**.

That gap is deliberate on the game's part, not an accident to be discovered: **Emerald parks its own
sprites above the limit** — the wireless-link status indicator lives at entry 125, and several
minigame screens allocate from 64 upward — precisely because the sprite system will not overwrite
them there. The one thing that does touch all 128 entries every frame is the affine-matrix pass,
and it writes only each entry's **fourth halfword** (the affine parameter), leaving the three
attribute halfwords alone.

Measured live on a town map, 2026-08-21: `gOamLimit` was 64 for 2250 consecutive overworld frames,
entries 64–127 held nothing and never changed, and **5 of 128 hardware entries were in use**.

**A ground-level overworld character is exactly ONE entry.** Every character graphic carries a table
of subsprite layouts selected by the character's elevation, which is what lets a sprite be split
into pieces at different priorities — that is how a character's head shows above a bridge while its
feet are hidden, and how tall grass covers the legs. At ordinary ground elevation the selected
layout is a **single full-size piece whose offset cancels against the sprite's own centre-to-corner
vector**, so the split path is geometrically a no-op and the character occupies one entry.

Two fields on that entry do the compositing work the engine gets for free and an overlay does not:
**priority**, which comes from the character's elevation (ordinary ground is priority 2) and is what
makes an NPC disappear behind a roof and under a text window; and the **palette slot**, which comes
from the graphic's own descriptor and is read live by the hardware, so a character dims with every
fade, cave and weather effect the game applies without anything re-deriving it.

**What this means for capacity, in the game's own terms:** the hardware sprite table is never the
thing that runs out. 128 entries, 64 of them not even addressed by the layout pass, and a handful in
use on a normal map — against a **16-entry object-event array** shared by the player, every NPC on
the map, and anything else that wants to be a character. The engine's own array is the binding
limit, and it is not a drawing limit at all.

*(Why that fact settles a design question — hardware sprites without the per-scanline OAM
multiplexing that Game Boy games used — is the 2026-08-21 ADR in
[`agent_docs/architecture.md`](../../../../agent_docs/architecture.md). It is a decision about our
code, so it lives there rather than here.)*

## Maps are identified by a pair

Map identity is **bank + number**, not a single id. Neither means anything alone. Warp data (which
map a door leads to) is held in the save block.

## What is known to differ under the Archipelago randomizer

Recorded here because it is a property of *that ROM*, and the difference is real and measured:
Archipelago's Emerald patch is a full base-ROM recompile, so **fixed addresses move**. Confirmed
cases include the overworld callback, the player sprite data, and the overworld object arrays. Its
own client reads the save-block pointers, which is why those keep working.

Full citation trail, including what is and is not covered:
[`agent_docs/risks.md`](../../../../agent_docs/risks.md).

## Surfing: a rider plus a second sprite the game spawns underneath

**[measured]** **A special player state is not just a graphic.** Surfing changes the player's
`graphicsId` like every other special state, and it *also* puts a separate blue Pokémon sprite
under the rider. Give something only the surfing graphic and it renders a rider sitting on nothing,
which is the half a player notices first — so this is the worked example behind
`_template/README.md`'s rule about reproducing the whole effect, animation *and* extras.

**How the two are joined.** An object event owns its field effect through its own
`fieldEffectSpriteId` field. That is the link the engine follows, and it is per-object rather than
global.

**The blob follows an object event id it reads from itself, not the player.** Its per-frame update
routine, `UpdateSurfBlobFieldEffect`, is **not hardcoded to the player**: it reads an object event
id out of the sprite's own `data[2]` and synchronises the blob's animation and position to whatever
that names. This is the single fact that makes a surfing *anything* possible — point the field at a
character and the engine drives the blob for that character, every frame, with nothing further
required.

**The blob's data slots** (`field_effect_helpers.c`): `data[0]` bob state, `data[2]` the object
event id it follows, `data[3]` velocity, `data[6]`/`data[7]` the previous x and y. The game's own
`FldEff_SurfBlob` seeds velocity and both previous coordinates to −1, enables the coordinate
offset, uses palette 0, and sets **subpriority 150** — which is what puts the blob behind the rider
rather than over them.

**The blob is described by a sprite template in ROM** (`gFieldEffectObjectTemplate_SurfBlob`), so
it can be built from that description rather than copied from a live one. That matters practically:
**no blob exists at all unless somebody is already surfing**, so there is nothing to copy from
until the state you are trying to produce already exists.

**Two different map-coordinate-to-screen helpers, and they are not interchangeable.** The rider is
placed with the one behind `GetMapCoordsFromSpritePos`, which subtracts only the total camera pixel
offset. The blob is placed by `SetSpritePosToOffsetMapCoords` — `SetSpritePosToMapCoords` plus
(8, 8) — which subtracts **both** the total camera pixel offset **and** the field camera. The two
terms cancel while the camera is at rest, so the difference is invisible in the easy case and puts
the blob a tile out of place in the others. **Which helper a given sprite uses is part of what that
sprite is**, and picking by resemblance rather than by looking it up is how the blob ends up one
tile below its rider.

**Underwater is a different mechanism, not a variant of this one.** It bobs the player's own sprite
(`StartUnderwaterSurfBlobBobbing`) rather than spawning a companion — see its own section below.

**Frame size.** The blob's frames are 32×32 — sixteen tiles, the same tile cost as the rider's.

### Getting onto the water is a sequence, not a state change

**[measured]** Surfing does not begin the moment the graphic changes. `Task_SurfFieldEffect`
(`src/field_effect.c:2994-3074`) runs four steps in order, and each one is visible:

1. **The field-move pose.** The player's graphic becomes the field-move one and it is held as a
   movement — `MOVEMENT_ACTION_START_ANIM_IN_DIRECTION`.
2. **The Pokémon is shown.** A full-screen effect that covers the map while it plays; it is
   ordinary and it happens for every HM used in the field, not just Surf.
3. **The jump onto the water.** *Only now* does the graphic become the surfing one, and in the same
   step the engine issues `GetJumpSpecialMovementAction(direction)` — a real one-tile jump with an
   arc — and creates the surf blob at the **destination** tile, not where the character is standing.
4. **The end**, which releases the hold.

Measured live on the player's own object event, 2026-08-21, Sootopolis shore:

```
 184 | gfx=3 act=0x39  tile=(38,43)            <- field-move pose
 292 | gfx=2 act=0x3A  tile=(38,44) pos2=(0,-4) <- surfing graphic + JUMP_SPECIAL, mid-arc
```

The two things worth carrying away: **the graphic and the jump arrive together**, and **the jump is
what covers the tile** — anything reproducing this by moving a character onto the water some other
way is not doing what the game does. The action ids are `MOVEMENT_ACTION_JUMP_SPECIAL_DOWN..RIGHT`,
`0x3A..0x3D` (`include/constants/event_object_movement.h:145-148`).

## Underwater: the character's own sprite is made to bob

**[measured]** Diving warps to a separate map, so an underwater character and a surface one are
never on screen together. On arrival `PlayerAvatarTransition_Underwater`
(`src/field_player_avatar.c:888-894`) does three things: sets the underwater graphic, sets the
underwater avatar flag, and starts the bobbing.

**The bobbing is a third sprite that draws nothing.** `StartUnderwaterSurfBlobBobbing`
(`src/field_effect_helpers.c:1150-1176`) creates an invisible dummy sprite and gives it a callback
that moves *another* sprite: it holds the target's sprite id, adds its step to that sprite's `y2`
every fourth frame, and reverses the step every sixteenth. The result is a slow drift of a few
pixels, and — because a character standing still underwater does nothing else — it is essentially
the whole of what "underwater" looks like.

**Underwater is covered by a full-screen sprite overlay.** The scene is laid over with a grid of
64×64 semi-transparent sprites — measured live: OAM entries 4..23, five columns by four rows,
priority 2, palette 12, covering every pixel — which is what gives the water its drifting light.
Two consequences follow from how the hardware composites it, and both are facts about the game
rather than about any adapter:

- **The engine's own characters sit at entries 0..3, above that overlay**, and sprite-vs-sprite
  ties are broken by entry number — so they are drawn over the fog rather than under it.
- **A semi-transparent sprite cannot blend against another sprite.** Put any sprite beneath the
  overlay and the overlay stops blending there and draws OPAQUE — a solid grey block the size of
  the sprite underneath (measured: pure greys, 181..247, against purple water).

**Nothing else comes with it.** There is no companion sprite (that is surfing), the underwater
graphics declare no reflection, and the graphic is 32×32 like every other special state. The one
asymmetry worth knowing: Brendan's underwater graphic resolves to the player palette slot and
May's to the NPC-special one, though both share the same underwater palette tag.

## Fishing

**Fishing is a multi-stage process with four outcomes, not a state you enter and leave.** Recorded
because an adapter that mirrors a peer has to represent whichever stage they are in, and two of the
outcomes look identical at the end.

**Two different kinds of evidence are mixed below, and they are labelled**, because they are not
interchangeable. **[player]** is what the game does as experienced by someone playing it — the
user's account, 2026-08-18: *"from a players perspective that is how it looks/feels like in game.
you start to fish, can fail/work, and then if you keep doing it a few times a battle starts (you
catched the fish)"*. That is authoritative about the experience and says nothing about the
implementation. **[measured]** is read from memory or from our own `pokeemerald` build. Where the
two agree the mechanic is understood; where only `[player]` exists, the code path is still unknown.

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

**[measured] The animation is driven by a TASK, and the sprite is otherwise paused.** The overworld
leaves an idle character's sprite with `animPaused` set (bit `0x40` of the sprite struct's `+0x2C`;
`animDelayCounter` occupies bits 0-5 — `include/sprite.h:211-212`). Nothing about holding a fishing
graphic changes that on its own: it is the fishing task that un-pauses the sprite and lets the
frames advance. The engine's own switch for this is the object event's `enableAnim` bit (byte
`+0x01` bit `0x08`), which `TryEnableObjectEventAnim` (`src/event_object_movement.c:7335-7343`)
consumes — it clears both `animPaused` and `disableAnim`, then clears itself.

**[measured] The sprite offset during fishing is DERIVED PER FRAME, not held.** A fishing frame is
32px wide where a walking frame is 16, and the frames are not all aligned the same way inside that
canvas. So the game recomputes the sprite's offset **every frame from the frame currently being
displayed** — `AlignFishingAnimationFrames` (`src/field_player_avatar.c:2045-2078`) looks up
`anims[animNum][animCmdIndex].type`, which for a frame command is that frame's image index, and
sets:

| image index | offset |
| --- | --- |
| 1, 2, 3 | `x2 = 8` (`x2 = -8` when facing west; `DIR_WEST = 3`, `include/constants/global.h:140`) |
| 5 | `y2 = -8` |
| 10, 11 | `y2 = 8` |

`ANIMCMD_END` is `-1`, and when the index lands on it the game steps back one frame before reading
the type. This is why the player never appears to shift while fishing even though the offset
changes several times per cast: the image and its offset are chosen together, inside the same frame
update, so they can never be seen disagreeing.

**Observed again on a Brendan save, vanilla, 2026-08-19** (`VERIFIED.md`): `gfx 0 -> 137`, then
`anim 3` (take out rod, east) → `anim 11` (hooked, east) → `anim 7` (put away, east) → `gfx 0`,
with the per-frame offset moving between `0,0` and `8,0` throughout — matching the table above.

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
metatile behaviour — `MB_POND_WATER` (16), `MB_DEEP_WATER` (18), `MB_OCEAN_WATER` (21) and so on.

**Water is NOT impassable.** This is the part that is easy to get backwards: a water tile has
**collision 0** and sits at **`ELEVATION_SURF` (1)**, while the player walks at
`ELEVATION_DEFAULT` (3). You cannot walk onto it because the *elevations differ*, not because it
is solid — and the difference matters, because the game reads that specific outcome:
`IsPlayerFacingSurfableFishableWater` (`field_player_avatar.c:1322`) is satisfied by three things
together — the collision at the faced tile comes back as `COLLISION_ELEVATION_MISMATCH`
specifically, the player is standing at `ELEVATION_DEFAULT`, and that tile's metatile behaviour is
one of the surfable/fishable water behaviours.

So a tile made solid (collision 1) blocks the player *and* fails the fishing check, because
`GetCollisionAtCoords` returns `COLLISION_IMPASSABLE` rather than `COLLISION_ELEVATION_MISMATCH`.
Being blocked looks like water and is not.

**Using a rod** goes through `CanFish` (`item_use.c:234`), which additionally refuses on a
waterfall tile and while underwater, and takes a different branch while surfing (where the tile
must be surfable water with collision 0, or a bridge over water). A refusal shows **the game's
generic "you cannot use that here" message** — the one that also appears when you try to ride a
bike indoors, phrased as advice from the player's father. It is **not** a story-progress gate, and
reading it as one sends an investigation to the save block instead of to the tile in front of the
player. (Described rather than quoted: extracted in-game text is on the Never side of
`_template/README.md`'s Fine/Never table, and identifying the message is the fact that matters.)

Confirmed live 2026-08-18 by editing a Littleroot tile to `id 44 / collision 0 / elevation 1` and
reading back what the game computes for it: `behaviour 21 (OCEAN_WATER)`, with the player at
elevation 3 one tile north. `probes/watertile.lua` does this on demand.

## Wild encounters are per-map data, not a property of the tile

**[measured]** What a tile *is* and what can *appear* on it are two different systems, and only
the first lives in the map grid.

`gWildMonHeaders[]` is a table keyed by **(mapGroup, mapNum)** — one entry per map — and each entry
holds **four independent lists**:

| field | used by |
| --- | --- |
| `landMonsInfo` | walking in grass/caves |
| `waterMonsInfo` | surfing |
| `rockSmashMonsInfo` | smashing rocks |
| `fishingMonsInfo` | any rod |

A map with no entry, or an entry whose list is `NULL`, simply has nothing to encounter there.
Fishing checks this explicitly: `DoesCurrentMapHaveFishingMons` (`wild_encounter.c:770`) returns
false when `fishingMonsInfo` is `NULL`, and when it does, the fishing task sets its own step
straight to the no-bite branch (`field_player_avatar.c:1851`) instead of rolling for a bite. The
rod still comes out, the animation still plays, and nothing can ever bite.

**Consequence for testing, learned the hard way 2026-08-18.** Water was created in Littleroot Town
(`probes/watertile.lua`) and fishing worked — the cast played, confirmed on screen. But Littleroot
is a town with no wild encounters of any kind, so **no bite is possible there, ever**. The tile
made the *action* legal; only the map's own encounter data can make the *outcome* happen. To reach
a bite, a hook, or the battle that follows, the water has to be on a map that actually defines
`fishingMonsInfo` — a route, not a starting town.

The user's framing, which is the general form: *"we added water, we made it so we could fish, but
we missed an important extra step on top of it that made it not do all functions it's actually
intended to do."*

## The Acro Bike: three moves, and one action family per move

**Everything the Acro Bike can do, as the player experiences it** — the user, 2026-08-20, naming
the complete set: *"it can wheelie and go around, it can stand idle then start jumping and after
that go around, or you can stand idle and do the sideway jump"*. **[player]**, and it is the whole
list:

**There is a base state under all three: just riding.** On the bike, moving or standing, doing none
of the moves below — the state each of them is entered from and returned to. Called out explicitly
because it is easy to leave off a list of *capabilities* precisely for being the default; the user,
2026-08-20, after naming the three: *"forgot to explain the base/doing nothing on the bike state"*,
the other three being *"the unique things you can do while actually on the bike"*. A ghost that only
reproduced the tricks would be wrong for nearly the whole ride.

1. **Ride in a wheelie.** Hold B and move off *before* any hop starts, and the rider travels on the
   back wheel for as long as B is held.
2. **Bunny hop.** Stand still and keep B held; after a moment the rider starts hopping on the spot.
   *"After you start to jump, you can also move around if B is continued to be held"* — so the hop
   is entered from a standstill and only then becomes a hopping ride.
3. **Sideways jump.** From a standstill, not already hopping, press a direction together with B
   (*"up+B while idle on the bike and not jumping"*) for a single jump in that direction. This is
   the move that clears the rails.

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
frames and reported finished on the tenth. That matters because the same ids issued to a spawned
ghost sat busy until a watchdog freed them, so *"the action cannot be completed"* is not the
explanation — the action completes perfectly well for the engine's own object.

**The standing wheelie is a pose the engine re-asserts, not a single long action.** `0x64`'s
family reports finished immediately and is issued again on the following frames, so what looks like
one continuous hold is the same short action repeating for as long as B is down. The hop behaves
the same way: `0x70` for the hop, `0x7C` between hops, over and over.

**The sideways jump is NOT an `ACRO_*` action** — **[measured, 2026-08-21]**. It is the plain
`JUMP_*` family at **`0x42`..`0x45`**, chosen by facing in the same south/north/west/east order.
Worth stating plainly because the rest of this section is one `ACRO_*` family per move, and reading
that block alone will never find this one: the whole family lives four ids below
`JUMP_IN_PLACE_*` (`0x46`), which is where an eye scanning for "the jump ones" tends to stop.

**It travels one tile sideways WITHOUT turning, and the engine has a specific mechanism for that.**
An ordinary jump turns the character, because starting one calls `SetObjectEventDirection` with the
jump's direction. The side jump is set up with the object's **facing lock** raised first, so that
call writes the movement direction and leaves the facing alone — which is why the rider keeps
looking the way they were while sailing sideways. The lock is dropped again on the input tick after
the jump resolves, not when the player next stands still; held any longer it would pin the facing
through everything that followed.

**A jump lasts 16 frames** for both the in-place and the one-tile distances, and 32 for the
two-tile one. That number is what makes a *held* hop legible: a held button is ONE repeating action
reporting one id the whole time, so individual bounces are only visible as multiples of that
period — there is no per-bounce change in anything the object reports.

## Shadows and landing dust: what raises them, and what does not

**[measured, 2026-08-21, `probes/shadowdust_probe.lua`]** — a probe that finds field effects by the
ROM `images` pointer they draw from, so it identifies them by what they ARE rather than by address.

- **A shadow appears when a jump STARTS.** It is an ordinary sprite at **subpriority 148**, using
  **OBJ palette 0**, positioned at the character's own sprite position plus a per-graphic drop —
  and deliberately WITHOUT the jump arc, so it stays on the ground while the character rises over
  it. It follows the character's background priority, so it passes behind a bridge with them.
- **Landing dust appears when a jump FINISHES**, on the tile landed on, at **subpriority 135** and
  a palette resolved from the field-effect palette tag (slot 14 in the runs measured). Lower
  subpriority means the dust draws IN FRONT of the shadow — back to front, the order is shadow,
  character, dust.
- **The dust belongs to the TILE, not the character.** It stays where it was born and finishes its
  animation there while the character hops on, which is what makes a run of hops leave a trail of
  puffs rather than one puff dragged along underneath.
- **Both are driven by the jump itself.** A character that merely *walks* onto the tile another
  character *jumped* to gets neither — there is no jump to start a shadow or to finish and raise
  dust. Obvious in hindsight and easy to miss: "it has no dust" turned out to mean
  "it never jumped", not "the dust is drawn in the wrong place".
- **The two effects bind differently, and it matters.** The shadow is bound to its object by
  **local id** and re-finds it every frame; the dust is positional, spawned at coordinates and left
  to play out. Anything wearing a borrowed local id therefore inherits somebody else's shadow and
  its own dust.

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
Measured (`probes/coordwatch.log`): the frame the save block's map group/number flip, live objects
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

**And there are TWO KINDS of reflection, not one.** `GetReflectionTypeByMetatileBehavior` asks
`MetatileBehavior_IsIce` **first** and only then `IsReflective`, so `MB_ICE` is `REFL_TYPE_ICE`
while every other reflective behaviour is `REFL_TYPE_WATER`. `GroundEffect_IceReflection` sets its
reflection up with `stillReflection = TRUE`, and that flag is the only thing gating the affine
mode — so an ice reflection is a plain vertical flip with no matrix behind it, and none of the
shimmer described above. Ice does not ripple, and neither does a reflection in it.

## A dark cave is a WINDOW, not an overlay

**[measured]** The darkness outside a cave's lit circle is not something drawn on top of the scene.
It is **Window 0**: the engine writes each scanline's lit span into the scanline-effect buffer and
DMAs it to `REG_WIN0H` every HBlank (`sFlashEffectParams` targets `&REG_WIN0H`,
`src/field_screen_effect.c`), so outside the circle the layers are simply not displayed. Nothing is
painted black — nothing is painted at all.

Each entry is `(left << 8) | right`, one per scanline, right edge exclusive; rows outside the
circle read `0-0`. Read live in Granite Cave B1F: rows 56–104 lit, `114-126` at the top edge
widening to `96-144` at the middle — centre (120, 80), radius 24, which is
`sFlashLevelToRadius[7]`, the smallest non-zero flash level.

**Two consequences.** Anything the hardware draws — backgrounds and sprites alike — is clipped to
the circle for free. And **`WIN0H` and `WIN0V` cannot be read back**: they are write-only, so a
register dump shows garbage. The live shape has to come from the scanline buffer, and whether the
effect is running from `gScanlineEffect` (`dmaDest` = `REG_WIN0H`, non-zero `state`).

## Weather fog is a grid of semi-transparent SPRITES, not a background

**[measured]** In Mt Pyre Exterior the fog is twelve **64×64 sprites in objMode 1**
(semi-transparent), at priority 2, laid out on a 64-pixel grid that covers the screen — OAM entries
3–17, with the map's characters at 0–2. Underwater the same idea appears with about twenty. It
fades in over a few seconds after the map loads rather than arriving with the first step, so a
freshly loaded savestate shows none of it.

**Characters stay visible because of the ENTRY NUMBER, not the priority.** They share priority 2
with the fog and win the tie by sitting at lower entries, so they draw in front of it while the
fog blends normally everywhere else.

**`BLDY` cannot be read back** — it is write-only on GBA and returns garbage. `BLDCNT` and
`BLDALPHA` read fine; `BLDALPHA` is what animates as the fog fades.

## Ice slides you, and a slide is a movement that does not animate

**[from the decomp]** Stepping onto an `MB_ICE` tile hands control to `ForcedMovement_Slide`, which
keeps the character moving in the same direction until something blocks them. It is built from
`PlayerWalkFast` — an ordinary fast walk, so the movement action is a plain `WALK_FAST_*` — plus
**two bits set on the character's own object event**:

| bit | effect |
| --- | --- |
| `disableAnim` | the character crosses tiles with its animation held on one frame |
| `facingDirectionLocked` | the step cannot turn it, so it keeps the facing it slid in with |

**`disableAnim` is not the same statement as `animPaused`,** and ice is the place that proves it.
`animPaused` says the sprite's animation is not running; `disableAnim` says the object may not have
one, and a movement cannot override it. Everywhere else the two agree. The engine only ever clears
`disableAnim` through `enableAnim` (`TryEnableObjectEventAnim`), so it is sticky.

**Which frame gets held is whatever the cycle had reached** — not the animation's first frame.
Measured across three slides: `10/2`, `11/0`, `11/2`.

**Ends when blocked, not after a fixed distance.** Nothing stops a slide but an obstacle, which is
why removing collision (a noclip probe) makes the player slide to the map border.

**The crack-and-fall ice is a different mechanic entirely** — `MB_THIN_ICE` and `MB_CRACKED_ICE`,
driven by `SootopolisGymIcePerStepCallback`. It is used by **Sootopolis Gym only**; Shoal Cave's
ice room is all `MB_ICE` and does not break.

## Standing still is a HELD animation, not an idle one

**[measured]** A character that has stopped does not switch to an "idle" animation. It keeps the
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

**[measured, and cross-checked against `src/bike.c` and `src/field_player_avatar.c`]** There is no
one field that says how fast a character is moving. This game keeps it in three, and which one is
authoritative depends on what the character is doing:

- **`gPlayerAvatar.bikeSpeed` (+0x0B)** — the Mach Bike. A *stable* field holding the game's own
  `PLAYER_SPEED_*` value, which maps to a movement action (`FAST` to `WALK_FAST`, `FASTEST` to
  `WALK_FASTER`). Stable is the property that matters: `movementActionId` is transient, so sampling
  it at 20Hz catches an ordinary walk or a turn as often as a fast action.
- **`movementActionId` as `WALK_FAST`** — the muddy slope's forced movement, during which
  `bikeSpeed` reads **0** even though the rider is visibly moving fast. Here the action is the
  reliable source, because the forced movement holds it.
- **`movementActionId` as `RIDE_WATER_CURRENT`** — the Acro Bike, which genuinely moves with the
  ride-water-current transition rather than with any bike-specific one.

**"Stable" and "correct" are different properties**, and this is where they come apart:
`bikeSpeed` is authoritative while riding and deliberately zeroed by the slope's own code.

## The muddy slope: the one place facing and movement disagree

**[measured, 527 frames of slide-back]** The Mach Bike exists to climb a muddy slope, and below top
speed the slope pushes the rider back. `ForcedMovement_MuddySlope` does three things at once when
the rider is not heading north at `PLAYER_SPEED_FASTEST`: it resets the bike's speed counter to
zero, sets `facingDirectionLocked` on the player's object event so the character keeps **facing
north**, and issues a forced movement **south** at walk-fast speed.

So this is the only ordinary situation in the game where a character's facing and its direction of
travel point opposite ways, and where the field that describes a rider's speed reads zero while
they are visibly moving. Any code that derives one from the other is wrong here and only here.

## Tall grass is a SPRITE, and that makes two different kinds of occlusion

**[measured]** A character standing in tall grass is hidden from the waist down — and not by the
map. The grass metatile's **top layer is completely empty** (layer type NORMAL), so no background
layer covers anything at all. Instead the engine spawns a **field-effect sprite** per object
standing in grass and draws it above them, from the tall-grass and long-grass field effect
templates (`MB_TALL_GRASS` and `MB_LONG_GRASS` respectively).

**Two kinds of occlusion follow, and doing one says nothing about the other.** Scenery — buildings,
roof edges, tree tops — is a metatile's top layer on a background the sprite does not outrank.
Grass is a sprite drawn over the character. A real object event gets both for free; anything else
has to reproduce each separately, and "it hides behind buildings" is not evidence that it hides.

## Two states where the game stops drawing the player as a character

Every other special state is still a character on a tile: a different `graphicsId`, sometimes a
companion sprite, but a person standing somewhere. These two are not, and each breaks a different
assumption.

**Riding Mr. Briney's boat.** The ride hides the player's own object outright and then applies the
*same* scripted movement to that invisible object and to a separate boat object, so the two travel
one on top of the other with only the boat drawn (`data/maps/Route104/scripts.inc`,
`Route104_EventScript_SailToDewford`). Three consequences worth knowing:

- **The player's `graphicsId` never changes.** Nothing about the character's own appearance says
  they are on a boat; the state lives in the object's `invisible` bit and in a second object's
  existence on the same coordinates.
- **The crossing uses `walk_fast` and `walk_faster` movements**, which ordinary play never
  produces — running is a different mechanism entirely (see *A rider's speed lives in three
  unrelated places*). `gPlayerAvatar.bikeSpeed` reads zero throughout, because nobody is pedalling,
  so the character's real pace is legible only from its movement action.
- **The map changes mid-ride**, by the boat crossing a map connection, with no warp and no fade.

The boat's graphic is 32x32 on an ordinary NPC palette slot rather than the shared Brendan/May tag
(`src/data/object_events/object_event_graphics_info.h`), so unlike every player state its colours
are not already loaded wherever the player is.

**Fly.** Fly takes the character off the map altogether rather than moving it. The departure runs
as a sequence (`src/field_effect.c`, the `Task_FlyOut` state table):

1. The field-move pose, and the panel showing the Pokémon — the same show-mon banner every field
   move raises.
2. A bird sprite leaves its ball and swoops down on a cosine/sine arc.
3. The character takes the **surfing** graphic and the mount animation, and jumps in place onto it.
   Its shadow is switched off and it is marked inanimate.
4. The bird's own sprite callback then drives the character's sprite in **screen** coordinates,
   with `coordOffsetEnabled` cleared, until the arc finishes and the screen fades.

Arrival is that sequence in reverse, plus a hand-written eighteen-frame drop table for the step off
the bird, and it ends by restoring whichever state the player was in before — including surfing,
blob and all.

Two facts matter more than the rest:

- **The map position never moves.** Through the whole departure the object stands on the tile it
  took off from. Position, movement action and animation all describe a character standing still,
  which is why none of them can tell you a Fly is happening.
- **The engine already flies characters who are not the player.** `FldEff_NPCFlyOut` hands the same
  arc routine an arbitrary sprite id and lets it carry an NPC away, and the bird names its
  passenger in its own sprite data rather than assuming the player. The routine is general; only
  the task around it is about the player.
