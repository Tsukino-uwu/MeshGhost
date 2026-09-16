# Navigation — finding your way through a game's world

Read when moving through a world by input: arriving somewhere unfamiliar, stopped against something,
planning a route, or working an Archipelago instance. When the trip itself is not the test, skip the
trip and make the state (`building-a-state.md`). The dated rulings behind these rules are in
`agent_docs/playing-rationale.md`.

## What the things on screen ARE

A driver that cannot name what it is looking at cannot plan.

| On screen | What it is | What to do |
|---|---|---|
| A person | NPC — may block, may talk, may battle you | Face and press A. **Talking is not the same as being refused** |
| A small board | Sign | Face and press A — usually names the route or town ahead |
| A red ball on the ground | An item pickup (in an Archipelago seed, a randomised check) | Walk to it and press A |
| A one-tile step down | **Ledge — a one-way edge.** Passable downward only | Route around; find the gap and go up through it |
| Tall grass | Wild encounters, walkable | Walk through, or around if avoiding battles |
| Chunky cuttable grass / boulders | Needs an earned ability | **Check what this SAVE has** before planning around it |
| A doorway or stair | A warp | Step onto it; it rebuilds the world, and undoes any tile you wrote on that map |

## Backtrack and go around

A building is solid; its door is the only way in. A town's exit is at one point on an edge, not
along the whole edge. And the way forward is often backwards first: the route out of an area can
require returning to a place already visited.

**A direction that stops producing coordinate changes is not a closed route — it is the wrong
tile.** Step perpendicular along the obstacle until it clears, then resume; or walk the edge looking
for the gap. Pressing the same direction harder is the most common way a driven run stalls.

## Choosing how to move — mix them, like a player

A player does not run non-stop; each way of moving has its place, in any game:

- **Walk** for precision: lining up with a tile, a door, a character's sight, or before running exists.
- **Run** to go faster where you still need to stop on the right tile.
- **A bike (or any faster mount)** for long distances, accepting that it can overshoot or hit a wall.
- **Hold the direction across tiles** rather than stopping on every one: a stop-start run looks wrong
  and is not how anyone plays. Stop when there is a reason to look.

## Failures that look identical from the driver's seat

*"I pressed a direction and did not move"* is the same signal for all of these, and each has a
different answer:

- **an obstacle that is not one** — an NPC mid-sentence, an open text box;
- **an obstacle that is one-way rather than solid** — a ledge;
- **a plan that needs an ability the save has not earned**;
- **a wrong menu entry selected** — A activates whatever is highlighted, not the obvious thing;
- **a wall.**

**The picture says which one it is; the memory read says whether it changed** (`screenshots.md`).

## Use the game's own guidance — talk to NPCs, read signs

Treat an NPC as the game's quest log: **pressing A on everyone who will talk is the default first
move in an unfamiliar town**, not a last resort. A sign at a route entrance names the town it leads
to; an NPC says which way is blocked and why; a character's line is often the flag check you were
about to look up, in plain words. Three reasons it is not just flavour:

- **It is usually the fastest route-planning available**, and it needs no map data at all.
- **It tells apart the failures that look identical.** An NPC who talks and then steps aside is not
  the wall an agent once reported it as (`agent_docs/pitfalls.md`) — and you only learn that by
  reading what they said.
- **It tests the adapter for free.** Every text box is a UI panel over the world: exactly where a
  drawn ghost must be clipped, where the send gate must behave, and where Crystal's occlusion work
  was measured.

## Check what this SAVE has, not what the game has

A decomp makes every mechanic visible, so every mechanic feels available. The question is never
*"does this game have Cut"* but *"does this save have Cut"* — party, bag and badges are readable in
one go. **A plan that depends on a capability you do not have fails exactly like a wall does.** Stay
on the critical path: cutting grass on the way to a trainer battle is a detour even for a save that
can. When the trip is not the test, give the save what it needs instead (`building-a-state.md`).

## An Archipelago seed is the SAME world

The patch randomises what is IN the world, not the world: the towns, routes, buildings, ledges, NPCs
and the order events happen in are vanilla's. An agent that has worked out a route, or which NPC has
to be talked to before a door opens, holds an answer another instance's agent needs — **say it, in
the report and in a message.**

| Transfers | Does not transfer |
|---|---|
| Routes, map layout, where a door or a ledge is | **What is in an item ball** — randomised per seed |
| Which NPC gates what, and roughly what they say | **Which check a location gives**, and therefore what to detour for |
| Battle order, when the rival appears | **Memory addresses** — the recompile shifts them (`gObjectEvents` +0x284 on AP Emerald's base patch, measured by the adapter at startup) |
| Menu conventions, how to trigger a state | **What the save has earned** — two seeds diverge immediately |

Both `cmd_drive.lua` drivers are vanilla-only, so on an Archipelago instance their address-bound
commands do not apply.

## Perfect information is not cheating

Knowing exactly where you are, what the game is checking and which tile is a one-way ledge is what
makes a driver good rather than lucky — the relationship a speedrunner has with a decomp. The decomp
is a MAP of where to look, never evidence of what a byte means (`agent_docs/licensing.md`).
