# Playing the game, and looking at it

Everything an agent may do to a running game: what it is permitted to change, how to drive input,
how to find its way, and how to use pictures. Split out of `environment.md` on 2026-08-19, when it
had grown to a third of that file — a toolchain record nobody rereads is worse than two files.

`environment.md` keeps the host, the toolchain and the tool/mod versions. **Read this file before
driving any game.** Its companion for probes is `adapters/_template/probes.md`.

## Permissions — what may be changed, and what that costs

**The user's grant:** *"i don't really want or need you to 'play the whole game'. but feel free to
try and progress/do things in the game on your own if you can as it might unlock new things like
'fighting trainers' or possibly finding new/untested things along the way."* And on scale:
*"completing the whole game would give us a lot of information actually."*

**Why it is worth doing rather than a novelty.** Several measurements this project needs are gated
behind game states nobody has reached: `wBattleMode` on the Archipelago build needs a **trainer**
battle to tell 1 from 2, surfing and fishing need water and a rod, and the whole
"does a ghost survive X" family needs an X. Reaching those states by playing is often cheaper than
inventing them — and the walk there is itself a test, because it exercises the adapter through
menus, battles, warps and cutscenes nobody scripted.

**REVERSED 2026-08-19, later the same day: CHEATS ARE ALLOWED TO PROGRESS A PLAYTHROUGH.** The
user's ruling, verbatim: *"new rule, cheats are allowed to progress in a playthrough."* This
overrides the earlier no-cheating rule entirely; what that rule was for is kept as one dated note
below, because it says exactly what a cheated run stops proving.

**What it means in practice:** writing position, setting a flag a script checks, warping, giving
an item or a badge, and savestates are all on the table **when the point is getting further along**.
The measurement that a state unlocks is the goal; the walk there was never the deliverable.

**Including the world itself** (user, 2026-08-19, watching an agent stall against a ledge):
*"you are allowed to turn off collision, or change a tile to something else if its in the way, do
anything you can think of to progress."* So the map is not a constraint either — clear a tile's
collision bits, rewrite the metatile, write the player's coordinates past the obstacle, or drop
the collision check entirely. **A ledge, a wall, a locked door and a missing HM are all just
memory**, and an agent grinding directional inputs at one of them is choosing the hard version of
a solved problem.

**The order to try things in, cheapest first:** walk it; if that fails twice, look at a screenshot
(it is usually an NPC or an open text box, not geometry); if it really is geometry, write past it
and move on. Do not spend a third attempt on inputs.

**What it costs, and say so when it applies:** a run that was warped past a stretch no longer shows
that *a player* can make that trip, and a state that was written is not evidence that the game
produces that state. So keep the two claims apart in whatever you record — *"reached X"* and
*"walked to X"* are different sentences, and only the second one is about the game. `verified.md`
entries should name which they are.

**Still off the table, because it is not about progress:** nothing that SHIPS may write a save or
game state — `CLAUDE.md`'s rule stands untouched, and this permission is for a dev-driven
playthrough, never for an adapter.

The superseded rule, and its reasoning, follows.

**The superseded rule, kept as one dated line because its reasoning still matters.** Until that
message the rule was the opposite — *"cheating is not allowed… try to progress just as a player
would"* (user, 2026-08-19, earlier the same day), savestates included. It was not wrong, it was
answering a different question: a run that cheats has stopped testing *"a player can get from here
to there, and the adapter survives the trip."* That claim is simply no longer the one being made,
which is why the labelling above is the part that has to survive. The full text is in this file's
history, and nothing below re-states it.

**Why this is not the same as the dev-tooling carve-out.** `CLAUDE.md` permits a *probe* to cheat
— `probes/watertile.lua` writes a water tile so fishing can be measured without walking to a
route, and that is fine, because the claim being tested is *"what does the fishing code do"*. A
playthrough tests a different claim: **"a player can get from here to there, and the adapter
survives the trip."** Cheat and you have tested nothing — you have confirmed that the state you
wrote is the state you wrote.

**USE EVERY TOOL — the user, 2026-08-19:** *"use any possible means/tools to try/test/find/probe
things inside of the bizhawk games. all tools are there to be used."* Said in the same breath as
the cheats reversal above, and it is the same instruction pointed at investigation rather than
progress: the emulator's whole surface is fair game, and reaching for the smallest one out of
caution is the mistake.

What that surface actually is, since agents keep using a third of it: `memory.read*`/`write*`
across every domain, `mainmemory`, VRAM/OAM/palette reads, `client.screenshot()`,
`client.speedmode()`, `joypad.set`/`get`, `savestate.save`/`load`/`saveslot`/`loadslot`,
`event.on*` hooks, `emu.framecount`, `gui.*` for an overlay, `luanet` for .NET (that is how the
adapter learned its own pid), plus everything outside the emulator — the decomp for facts, the
Go rig, `meshghost-fakeadapter`, `meshghost-netsim`, the relay's `-loopback`, and probes that
write.

**The rule this replaces is "ask the user to do it".** If a state can be reached, forced, faked or
measured by a tool you have, use the tool. Involve the user for a JUDGEMENT — does this look right
on screen — not for labour.

### Speed

**Speed control, measured 2026-08-19.** `client.speedmode(n)` is exposed to Lua on this build
(confirmed at runtime, not from a doc string — `n` ∈ 50/75/100/150/200/400):

| Requested | Measured on a loaded host (4 emulators, a crowd of drawn ghosts) |
|---|---|
| 100% | 59.8 fps |
| 200% | 122.5 fps — the full 2x |
| 400% | 138.3 fps — about **2.3x**, not 4x |

**The user may set the speed themselves, and did — 2026-08-19, all four instances to 400% at
once, with:** *"i changed all 4 bizhawk instances to 400%. please try to progress in the games.
instead of all 4 of them being idle/not doing anything."* Two things follow. **Do not reset a speed
you did not set** — put back only what you changed, and check `client.get_approx_framerate()` or
frames-against-the-wall-clock before assuming your instance is at 100. And read the gesture for
what it is: raising the speed is the user removing the excuse that progress is slow.

**So a speed setting is a request, not a guarantee**: past some multiple the host CPU is the limit,
and on a busy machine 400% buys little more than 200%. Measure what you actually got (frames
against the wall clock) rather than assuming the multiplier, and put the speed back to 100 when
finished so the next reader of that instance is not confused by a fast-running game.

## Driving input

**Menus are cursor-then-confirm, and A does not mean "do the obvious thing"** (user, 2026-08-19).
The convention across these games, and most others: **A confirms/activates WHATEVER IS CURRENTLY
SELECTED; B goes back, cancels, declines.** So every menu interaction is two steps — move the
selection, *then* confirm — and an agent that presses A without checking what is highlighted keeps
activating the wrong entry. Live case: an agent on a naming screen pressed A expecting "accept the
name" and kept typing the same letter, because the cursor was still on the letter grid rather than
on OK.

**This is the failure mode worth internalising: a wrong menu press looks exactly like being
stuck.** Nothing errors, the screen barely changes, and the driver concludes the game is
unresponsive. The general defence is the same one that applies to movement — **check the state
after the press rather than assuming the press did what you meant.** Did the cursor move? Did the
box close? Did the coordinate change? If not, the question is "what is selected", not "why is this
game broken".

Related conventions worth knowing before driving any of these: **START** usually opens the main
menu and often doubles as OK/confirm on entry screens; **B** advances or closes dialogue as well as
A; and a long conversation is several boxes, so one press is rarely enough.

**The frames between two commands belong to somebody.** A driver whose idle behaviour is "keep
going the way the queue was going" — added so the character never looks parked — silently walked a
player six tiles between a warp and the command after it, and the measurement that followed ran
from a tile the driver had already left (2026-08-19). It is the same defect as the random patrol it
replaced, just tidier-looking. **Any driven-input rig needs an explicit idle-does-nothing mode that
a measurement can take.**

**A queue file beats a reload.** Reloading a driver script drops the adapter with it, so a driver
that re-reads a small text file every frame lets the session steer without disturbing anything
else. It also means the game keeps moving while you think, which is what the user is watching.

## Navigation

**The world's vocabulary — what the things on screen ARE.** A driver that cannot name what it is
looking at cannot plan, and every one of these was learned the hard way during the 2026-08-19 runs:

| On screen | What it is | What to do |
|---|---|---|
| A person | NPC — may block, may talk, may battle you | Face and press A. **Talking is not the same as being refused** |
| A small board | Sign | Face and press A — usually names the route or town ahead |
| A red ball on the ground | An item pickup (in an Archipelago seed, a randomised check) | Walk to it and press A |
| A one-tile step down | **Ledge — a one-way edge.** Passable downward only | Route around; find the gap and go up through it |
| Tall grass | Wild encounters, walkable | Walk through, or around if avoiding battles |
| Chunky cuttable grass / boulders | Needs an earned ability | **Check what this SAVE has** before planning around it |
| A doorway or stair | A warp | Step onto it; it rebuilds the world (see the map-load rules) |

**BACKTRACK AND GO AROUND — the user's reminder, 2026-08-19, after watching two agents push at
the same tile:** *"you might have to backtrack, or 'go around things' in games. very often."* A
building is solid; its door is the only way in. A town's exit is at one point on an edge, not
along the whole edge — the user had to say twice that a right-hand exit was at the TOP of the
town, not the bottom. And the way forward is frequently backwards first: the route out of an area
can require returning to a place already visited.

**So a direction that stops producing coordinate changes is not a closed route — it is the wrong
tile.** The move is to step perpendicular along the obstacle until it clears, then resume; or to
walk the edge looking for the gap. Pressing the same direction harder is the single most common
way a driven run stalls, and it is indistinguishable, from the input side, from all four failures
below.

**The three failures these prevent are all the same shape**: an obstacle that is not an obstacle
(an NPC mid-sentence), an obstacle that is one-way rather than solid (a ledge), and a plan that
needs an ability the save has not earned. Each looks identical from a driver's seat — *"I pressed a
direction and did not move"* — and each has a different answer.

**Use the game's own guidance — talk to NPCs, read signs** (user, 2026-08-19, restated the
same day: *"they usually tell you where to go/what to do. most of the time"*). Treat an NPC as the
game's own quest log — **pressing A on everyone who will talk is the default first move in an
unfamiliar town**, not a last resort, and it is right often enough to plan around. These games are
built to tell a player where to go next, and an agent that ignores that is doing the hard version
of a solved problem. A sign at a route entrance names the town it leads to; an NPC says which way
is blocked and why; a character's dialogue is often the flag-check you were about to go looking
for in the decomp, stated in English.

Three reasons this is not just flavour:

- **It is usually the fastest route-planning available**, and it needs no map data at all.
- **It distinguishes the failures that look identical.** An NPC who talks and then steps aside is
  not the wall an agent reported it as (`pitfalls.md`) — and you only learn that by *reading what
  they said*.
- **It is a test of the adapter in its own right.** Every text box is a UI panel over the world:
  exactly the state where a drawn ghost must be clipped, where the send gate must behave, and
  where Crystal's occlusion work was measured. Talking to people is free coverage.

**Check what this SAVE has, not what the game has.** A decomp makes every mechanic visible and
therefore feel available, so an agent plans around abilities it has not earned — live case
2026-08-19: an agent working toward a trainer battle started planning around cutting grass, which
is optional, is not on the critical path, and which that save could not do anyway. The question is
never *"does this game have Cut"* but *"does this save have Cut"*, and party, bag and badges are
all readable in one go. **A plan that depends on a capability you do not have fails exactly like a
wall does** — the driver does not move, and the wrong conclusion is one sentence away.

**An Archipelago seed is the SAME GAME — share route knowledge across instances** (user,
2026-08-19: *"ap crystal/emerald is the exact same game as crystal/emerald. feel free to cross
share info about how to progress in the game"*). The patch randomises what is in the world, not the
world: the towns, routes, buildings, ledges, NPCs and the order events happen in are the ones the
vanilla game has. So an agent that has worked out how to get from New Bark to Cherrygrove, or which
NPC has to be talked to before a door opens, is holding an answer the other instance's agent needs
— **say it, in the report and in a message, rather than letting the other one rediscover it.**

**What does NOT transfer, and mixing these up is the trap:**

| Transfers | Does not |
|---|---|
| Routes, map layout, where a door or a ledge is | **What is in an item ball** — randomised per seed |
| Which NPC gates what, and roughly what they say | **Which check a location gives**, and therefore what to detour for |
| Battle order, when the rival appears | **Memory addresses** — the recompile shifts them (`gObjectEvents` +0x284 on AP Emerald) |
| Menu conventions, how to trigger a state | **What the save has earned** — two seeds diverge immediately |

**Perfect information is not cheating.** Knowing exactly where you are, what the game is checking,
and which tile is a one-way ledge is what makes an agent good at this rather than lucky; it is the
same relationship a speedrunner has with a decomp. The prohibition is on *changing* the world, not
on understanding it.

## Screenshots — the navigation sense

**A screenshot is still never proof.** `environment.md`'s BizHawk section holds that rule and the
evidence gate it protects, and this section does not move it: `verified.md`'s human gate on
anything visual stands exactly as written. What follows is about pictures as an agent's *sense*,
not as evidence.

**One folder per game AND per patched variant**, under `dev-scripts/shots/`:
`emerald/`, `crystal/`, `apcrystal/`, `apemerald/`. Create yours if it does not exist. The whole
tree is gitignored (a picture is a working aid, never project content and never evidence), but it
is the agreed place, so the user can look at any instance's output without asking which folder
some agent invented.

**The failure this fixes, found by the user 2026-08-19**: after a whole session with four
emulators running, `dev-scripts/shots/` contained **only `emerald/`**. The Crystal work had written
its screenshots into the session's own scratch directory — which is per-session and disappears with
it — and the two Archipelago instances had taken none at all. Nobody could see what three of the
four games were doing.

**When PLAYING, a picture is the primary sense, not a verification aid** (user, 2026-08-19). A
player navigates by looking: they see that there is a door up and to the right, that the thing
ahead is a person rather than a rock, that a step is a ledge, that a menu is open and which entry
is highlighted. **Memory reads cannot supply that** — they give precision, not situation. Knowing
you are at tile 12,8 tells you nothing about what is around you unless you have already built a
map; a screenshot tells you immediately, the same way it tells a human.

**Restated by the user 2026-08-19, after watching a session go by without it:** *"use
screenshots/pictures to help with progressing, i don't think they did that before."* So this is
not only a reporting duty — it is **how you get anywhere**, and it belongs in the handoff every
agent is given, alongside its pid, its control file and its port. An agent that has taken no
pictures is navigating blind whatever else it is doing right.

**The habit that follows: LOOK FIRST, then act.** Take a screenshot when you arrive somewhere new,
before deciding what to do — not after something has failed. One picture tells you exactly where
you are and what is around you, which is the whole of the orientation problem, and it costs a
frame. Every stretch of wasted effort in the 2026-08-19 driven runs began with an agent choosing an
action from coordinates alone and only looking at the screen once it was already stuck. (The same
rule already exists for probes, in `adapters/_template/probes.md`: *look first, then write the
script*.)

So the two are a **pair, and neither replaces the other**:

| Question | Answer it with |
|---|---|
| *What is around me? Where can I go? What is this thing?* | **A picture** |
| *Did my input actually do anything?* | **A memory read** (coordinates, map id, menu state) |
| *Is this rare/periodic thing happening?* | **A counter over time** — one frame cannot see it |

That pairing is also the answer to the failure that dogged this project's driven runs: *"I pressed
a direction and did not move"* is the same signal for a wall, a ledge, an NPC mid-sentence and an
open text box. **The picture says which one it is; the memory read says whether it changed.**

**Use pictures.** `dev-scripts/bizhawk-screenshot.lua` writes a PNG a probe can drop on a timer or
on an event; a loop that overwrites one file is enough to watch a session evolve. They also answer
questions no memory read does — whether a sprite is garbled, what a menu looks like — and they are
how the user checks an agent's claim without driving the game themselves.

**Capture the GAME, not the window** (user, 2026-08-19): *"only capture what is in the game
itself."* `client.screenshot()` and nothing else — no `PrintWindow`, no
`PW_RENDERFULLCONTENT`, no DPI-aware window grab, even though one was proposed after a real
problem. The problem it was proposed for is genuine: **a drawn-tier ghost is a Lua overlay painted
after the frame, so it does not appear in `client.screenshot()` output** — an agent photographed a
screen full of ghosts three times and got an empty map. The answer is not a bigger camera.

**The answer is to judge the drawn tier NUMERICALLY**, with counters sampled over time, which is
better evidence anyway: "14-36 of ~40 peers were mid-stride at every sample, and none ever fell
back for want of a facing" settles the question in a way no photograph does, and one frame could
not have seen a walk cycle regardless. Pictures remain the navigation sense (what is around me,
what is this thing, which entry is highlighted) — and for that, the game frame is all anyone needs.

**Two things to know about pictures, both learned the hard way:**

- **One frame cannot see a blinking thing** (probes.md has the entry). Sample over time, and pick
  an interval that cannot align with what you are watching.
- **An agent may lose the ability to READ images mid-session** — this happened on 2026-08-19, when
  the API began rejecting them after a long conversation had accumulated many. **Keep taking them
  anyway**: the user can still look, and they remain the record of what happened. Then answer the
  question numerically instead — counters, invariants, register reads — which is the better evidence
  regardless, and is what settled every visual question in that session.

## Ground rules

**Ground rules for an agent playing a game:**

- **Only on an instance you own** — one agent per BizHawk instance, `environment.md`. Never drive
  an emulator the user is sitting at.
- **Savestates: allowed everywhere, and actively wanted on a measurement trip.** Slot 1 is the
  user's on every instance; use 2+. On a trip whose point is reaching one state — "get to a trainer
  battle so `wBattleMode` can be read" — **bank one at every milestone and name the slots in the
  report**: a state that took ten minutes to reach outlives the measurement it enabled, because
  every later session inherits it.
- **A run that ends badly is still a result.** Stuck, lost, softlocked — report it rather than
  quietly rewinding out of it. Reloading past a problem deletes exactly the evidence worth having,
  and that is true whether or not the reload was permitted.
- **Write down what you learn on the way**, not only the thing you set out for — the untested
  states passed through (a battle, a menu, a cutscene, a warp) are exactly where adapter bugs live.
- **Reading the decomp is normal and encouraged here**: knowing what a script checks turns "wander
  until something happens" into "walk here, press this". Facts only, per `licensing.md`.
- **It is a test, not an obligation.** Finishing a game is a fine goal and an interesting one; not
  finishing costs nothing, and a state reached is a state banked.
