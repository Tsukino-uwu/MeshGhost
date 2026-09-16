# Playing the game — the rulings and the reasoning

**The instructions now live in the `play-game` skill** — `.claude/skills/play-game/SKILL.md` and its
`references/` (`building-a-state.md`, `navigation.md`, `screenshots.md`, `bizhawk.md`) — which loads
itself whenever a task drives or plays a running game. **This file keeps what the skill does not
carry: the user's rulings in their own words, dated; why each rule exists; and the live cases that
produced them.** Renamed from `playing.md` and trimmed of its instructions on 2026-09-16; that file
had been split out of `environment.md` on 2026-08-19, when it had grown to a third of it.

A new ruling goes here, dated, and its instruction goes into the skill in the same pass.

## Permissions — the grant, and the reversal

**The user's grant:** *"i don't really want or need you to 'play the whole game'. but feel free to
try and progress/do things in the game on your own if you can as it might unlock new things like
'fighting trainers' or possibly finding new/untested things along the way."* And on scale:
*"completing the whole game would give us a lot of information actually."*

**Why it is worth doing rather than a novelty.** Several measurements this project needs were gated
behind game states nobody had reached: `wBattleMode` on the Archipelago build needed a **trainer**
battle to tell 1 from 2 (settled that way 2026-08-19, `crystal/VERIFIED.md`), surfing and fishing
need water and a rod, and the whole "does a ghost survive X" family needs an X. Reaching those states
by playing is often cheaper than inventing them — and the walk there is itself a test, because it
exercises the adapter through menus, battles, warps and cutscenes nobody scripted.

**REVERSED 2026-08-19, later the same day: CHEATS ARE ALLOWED TO PROGRESS A PLAYTHROUGH.** The
user's ruling, verbatim: *"new rule, cheats are allowed to progress in a playthrough."* This
overrides the earlier no-cheating rule entirely; what that rule was for is kept as one dated note
below, because it says exactly what a cheated run stops proving. The measurement a state unlocks is
the goal; the walk there was never the deliverable.

**Including the world itself** (user, 2026-08-19, watching an agent stall against a ledge):
*"you are allowed to turn off collision, or change a tile to something else if its in the way, do
anything you can think of to progress."* An agent grinding directional inputs at a ledge, a wall, a
locked door or a missing HM is choosing the hard version of a solved problem.

### The mindset: you decide what happens in the game (user, 2026-09-16)

*"you are free to do absolutely ANYTHING you want to get into a situation where we can test/measure
things. as long as we actually test how "the game handles" something and not "i made this happen, but
this is now how the game does it""* — and, the user's precision the same minute, *"ANYTHING(Inside the
game itself)"*: the freedom is over the game's world, memory and code, not over anything outside it.

The user: *"you are able to do anything and everything in a game. a wild pokemon battle or a trainer
can't stop you either as you decide what happens in the game. you have complete freedom of what
happens inside of a game"*, and *"you can never be or get stuck as you can just control what happens
in the game"*. In practice (same day): *"use items without opening menus, teleport around to
different locations, spawn items/enemies/tiles next to you, just create whatever you need for a good
testing situation yourself ... a npc or a text box is only a block if you don't know how to get around
it but when you control the code you decide what happens or not"*. And: *"just cheat/make things
happen if you want to do something. be creative."* Nor is it bounded by what a player can do: *"you
are able to freely change to code to make things happen the way you want so you can test anything you
want to do or remove anything that is blocking your path"*. On making states fresh rather than
loading a named savestate slot, which the user rewrites often: *"its a better habit to get into just
reproducing everything on your own this way."*

**The one limit is on the thing being tested, not on getting there:** *"you are free to cheat to do
things, or make things appear. but then you have to interact with them the way the game intends you
to if you actually want to check how they work."* Getting there is unbounded (*"you are not limited
to reaching things with a menu, or any collission related things in game"*); forcing the OUTCOME is
the mistake. That day an agent poked the standing-tile collision byte and hooked the jump check to
make a hop happen; neither worked, and neither would have been the game's own hop. The answer was
*"make a ledge, don't force a jump without a ledge. let the game handle it the intended way to see how
it does it"* — write the tileset's own ledge block into the map, then walk off it
(`phases/phase12.md`, 2026-09-16).

**Why it matters: the division of labour.** *"if you learn how to do all of this properly i only have
to confirm things visually, instead of setting up perfect testing scenarios for you."* Building the
scenario is the agent's job; the user's is the look.

**What a cheat costs, which is why the skill makes you label it:** a run that was warped past a
stretch no longer shows that *a player* can make that trip, and a state that was written is not
evidence that the game produces that state. *"Reached X"* and *"walked to X"* are different
sentences, and only the second one is about the game.

**Still off the table, because it is not about progress:** nothing that SHIPS may write a save or
game state — `CLAUDE.md`'s rule stands untouched; this permission is for dev-driven play, never for
an adapter.

### The superseded rule, kept because its reasoning still matters

Until the reversal the rule was the opposite — *"cheating is not allowed… try to progress just as a
player would"* (user, 2026-08-19, earlier the same day), savestates included. It was not wrong, it was
answering a different question: a playthrough tests **"a player can get from here to there, and the
adapter survives the trip,"** and a run that cheats has stopped testing that. That claim is simply no
longer the one being made, which is why the labelling is the part that has to survive. The full text
is in this file's history.

It was never the same as the dev-tooling carve-out: `CLAUDE.md` always let a *probe* cheat —
`adapters/emulator/pokemon/emerald/probes/watertile.lua` writes a water tile so fishing can be
measured without walking to a route, because the claim there is *"what does the fishing code do"*.

### Use every tool (user, 2026-08-19)

*"use any possible means/tools to try/test/find/probe things inside of the bizhawk games. all tools
are there to be used."* Said in the same breath as the cheats reversal, and the same instruction
pointed at investigation rather than progress. The surface is listed in the skill's
`references/bizhawk.md` because agents kept using a third of it. **The rule it replaced was "ask the
user to do it".**

### Speed (2026-08-19)

The user set all four instances to 400% at once, with: *"i changed all 4 bizhawk instances to 400%.
please try to progress in the games. instead of all 4 of them being idle/not doing anything."* Read
the gesture for what it is: raising the speed is the user removing the excuse that progress is slow
— which is why the skill says never to reset a speed you did not set. The measurement that showed
400% buys about 2.3x on a loaded host is in `references/bizhawk.md`.

## Building a state

The per-game recipes (Crystal and Emerald, 2026-09-16) moved into the skill's
`references/building-a-state.md`, where the next working recipe gets added. They came out of the
2026-09-16 session in `phases/phase12.md` and `phases/phase8.md`.

## Driving input — the live cases

**A wrong menu press looks exactly like being stuck** (user, 2026-08-19): an agent on a naming screen
pressed A expecting "accept the name" and kept typing the same letter, because the cursor was still
on the letter grid rather than on OK. Nothing errors, the screen barely changes, and the driver
concludes the game is unresponsive — the question was always "what is selected".

**The frames between two commands belong to somebody** (2026-08-19). A driver whose idle behaviour
was "keep going the way the queue was going" — added so the character never looked parked —
silently walked a player six tiles between a warp and the command after it, and the measurement that
followed ran from a tile the driver had already left. It was the same defect as the random patrol it
replaced, just tidier-looking.

**Why a queue file rather than a reload**: reloading a driver script drops the adapter with it, and a
driver that re-reads a small text file lets the session steer without disturbing anything else. It
also keeps the game moving while the agent thinks, which is what the user is watching. The
2026-08-19 driver re-read its file every frame; `cmd_drive.lua` (2026-09-16) re-reads every 15.

## Navigation — why the rules are what they are

**BACKTRACK AND GO AROUND — the user's reminder, 2026-08-19, after watching two agents push at the
same tile:** *"you might have to backtrack, or 'go around things' in games. very often."* The user
had to say twice that a right-hand exit was at the TOP of the town, not the bottom.

**Talk to NPCs, read signs** (user, 2026-08-19, restated the same day: *"they usually tell you where
to go/what to do. most of the time"*). These games are built to tell a player where to go next, and
an agent that ignores that is doing the hard version of a solved problem.

**Check what this SAVE has** — live case 2026-08-19: an agent working toward a trainer battle started
planning around cutting grass, which is optional, is not on the critical path, and which that save
could not do anyway. A decomp makes every mechanic visible and therefore feel available.

**An Archipelago seed is the SAME GAME** (user, 2026-08-19: *"ap crystal/emerald is the exact same game
as crystal/emerald. feel free to cross share info about how to progress in the game"*). An agent that
has worked out how to get from New Bark to Cherrygrove is holding an answer the other instance's agent
needs.

**Perfect information is not cheating** was written before the cheats reversal, when its point was
that understanding the world is fine even where changing it was not. The second half no longer
applies; the first stands.

## Drive the game YOURSELF before asking — user, 2026-08-19

*"try to do things in the game on your own, before asking me. you can cheat/use inputs/savestates
etc. make sure you actually make use of those tools."*

**It is also better evidence.** A person cannot hold a game's fastest movement steady for a minute
while watching a ghost for defects, and should not have to: the Mach Bike work spent several rounds
with empty counters purely because the sample window and the riding never lined up. Ten lines of
`joypad.set` fixed that — `adapters/emulator/pokemon/emerald/probes/bikeloop_probe.lua` rides a
square at top speed, reports the speed it actually reached, and produced in one run the sustained
data that hand-riding had failed to produce in six.

**What still needs the user is judging what is on screen**: `agent_docs/verified.md`'s gate does not
move, and scripting the *input* does not make the agent's *eyes* count.

## Screenshots — how the rules were learned

**The folder rule, found by the user 2026-08-19**: after a whole session with four emulators running,
`dev-scripts/shots/` contained **only `emerald/`**. The Crystal work had written its screenshots into
the session's own scratch directory — which disappears with the session — and the two Archipelago
instances had taken none at all. Nobody could see what three of the four instances were doing.

**Pictures as the primary sense** (user, 2026-08-19): *"use screenshots/pictures to help with
progressing, i don't think they did that before."* So it is not only a reporting duty but how you get
anywhere, and it belongs in the handoff every agent is given — which is why `running-the-rig.md`'s
handoff names the `play-game` skill. **Look first**: every stretch of wasted effort in the 2026-08-19
driven runs began with an agent choosing an action from coordinates alone and only looking at the
screen once it was already stuck.

**Capture the GAME, not the window** (user, 2026-08-19): *"only capture what is in the game itself."*
A window grab (`PrintWindow`, `PW_RENDERFULLCONTENT`, DPI-aware) was proposed after a real problem:
an agent photographed a screen full of drawn ghosts three times and got an empty map, because the
drawn tier is a Lua overlay painted after the frame. The answer was not a bigger camera but counters,
which settle a walk cycle in a way no single frame can.

**Window capture where there is no frame capture** (user, 2026-09-16, planning a harness meant for
any game): a host that cannot capture its own frame may use a window capture — and every capture,
from any tool, is gitignored and never goes up on the public repo.

**The surfing reflection** (2026-08-19): its clipping was pinned down by photographing the engine's
own reflection at a shoreline and reading it row by row, which gave an exact target no amount of
reading the decompilation had produced.

**The same frame**: the first attempt at that comparison had a probe screenshot on one schedule and
the adapter's log on another, seconds apart; the two described different scenes, and the difference
got blamed on the player moving, who was in fact idle.

**Losing the ability to read images** happened on 2026-08-19, when the API began rejecting them after
a long conversation had accumulated many. Counters, invariants and register reads settled every
visual question in that session.

## Ground rules — the reasoning

- **One agent per instance** is the user's standing grant, `running-the-rig.md` ("Working two games at
  once"): an emulator is a single-owner resource. Since 2026-09-16 it is also a `CLAUDE.md` rule.
- **Bank a state at every milestone** because a state that was expensive to reach outlives the
  measurement it enabled. Since 2026-09-16 the habit is to rebuild a state fresh rather than trust an
  old named slot, so a banked state serves the session that made it and names its slot in the report.
- **A run that ends badly is still a result**: reloading past a problem deletes exactly the evidence
  worth having, whether or not the reload was permitted.
- **Write down what you learn on the way**: the untested states passed through are exactly where
  adapter bugs live.
- **It is a test, not an obligation.** Finishing a game is a fine goal; not finishing costs nothing.
