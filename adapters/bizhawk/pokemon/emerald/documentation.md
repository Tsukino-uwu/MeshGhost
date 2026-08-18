# How Pokémon Emerald works

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
[`agent_docs/verified.md`](../../../../agent_docs/verified.md).

**Written 2026-08-18**, after this adapter had been shipping for a week. It was previously argued
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
(`StartUnderwaterSurfBlobBobbing`) rather than spawning a companion.

**Frame size.** The blob's frames are 32×32 — sixteen tiles, the same tile cost as the rider's.

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

Observed live on a May save (`verified.md`, 2026-08-18): `gfx 89 -> 138`, then `anim 3` (take out
rod, east), `anim 7` (put away — a bite that got away), `anim 3` again, `anim 11` (hooked), and
finally back to `gfx 89`. `PLAYER_AVATAR_FLAG_ON_FOOT | PLAYER_AVATAR_FLAG_CONTROLLABLE` stayed set
throughout.

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

```
IsPlayerFacingSurfableFishableWater()          (field_player_avatar.c:1322)
    GetCollisionAtCoords(...) == COLLISION_ELEVATION_MISMATCH
 && PlayerGetElevation() == ELEVATION_DEFAULT
 && MetatileBehavior_IsSurfableFishableWater(behaviour at that tile)
```

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
false when `fishingMonsInfo` is `NULL`, and the fishing task then does

```
if (!DoesCurrentMapHaveFishingMons())
    task->tStep = FISHING_NO_BITE;     // field_player_avatar.c:1851
```

— it jumps **straight to the no-bite branch**. The rod still comes out, the animation still plays,
and nothing can ever bite.

**Consequence for testing, learned the hard way 2026-08-18.** Water was created in Littleroot Town
(`probes/watertile.lua`) and fishing worked — the cast played, confirmed on screen. But Littleroot
is a town with no wild encounters of any kind, so **no bite is possible there, ever**. The tile
made the *action* legal; only the map's own encounter data can make the *outcome* happen. To reach
a bite, a hook, or the battle that follows, the water has to be on a map that actually defines
`fishingMonsInfo` — a route, not a starting town.

The user's framing, which is the general form: *"we added water, we made it so we could fish, but
we missed an important extra step on top of it that made it not do all functions it's actually
intended to do."*
