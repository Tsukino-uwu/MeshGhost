---

<!-- line-cap: 120 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

name: play-game
description: Read before driving, playing or steering a running game on a MeshGhost dev instance — BizHawk Emerald and Crystal (vanilla or Archipelago) above all, and any game a dev session drives. Carries what you may change (anything inside the game), the one limit (make the situation, then let the game run the mechanism), instance and savestate-slot ownership, the look-act-verify loop, state-building recipes, speed and screenshots. Use when reaching a game state to test or measure (a trainer battle, surfing, a ledge, a map), moving the character, getting through menus, dialogue or battles, using savestates, cheats or memory writes, or taking a screenshot of a running game. Not for writing, building or fixing adapter code.
---

# Playing a game

Dev-driven play on an instance you own: reaching, holding and repeating a state so it can be
measured. **None of it applies to shipped code** — nothing that ships writes a save or game state
(`CLAUDE.md`). The dated rulings and the reasoning behind every rule here are in
`agent_docs/playing-rationale.md`; probes have `/write-a-probe`; a PC game's dev channels are in that
adapter's `CLAUDE.md` and `PROBES.md`.

## Whose instance, whose slot

- **One agent per BizHawk instance, and never drive a game the user is at.** Your handoff names your
  pid, control file, bridge port and the off-limits list (`agent_docs/running-the-rig.md`).
- **On an instance you drive, a warp is a tool like any other**; the user's position while THEY play
  is theirs.
- **Savestate slot 1 is the user's on every instance.** Rigs hold named states in other slots: read
  "Rig notes" in `running-the-rig.md` and the adapter's `UNVERIFIED.md` first — assignments drift.

## You decide what happens inside the game

- **Anything INSIDE the game is yours to change** (user, 2026-09-16): its memory and code, the tiles
  around the player, the items in hand, whether a battle happens and how it ends, whether an NPC
  speaks or a script runs. Nothing inside a game can stop you, strand you or make you wait — a
  ledge, a wall, a locked door and a missing HM are all just memory.
- **A test situation is MADE, never found, waited for or asked for** — and made fresh, not loaded from
  an old named slot, which the user rewrites often.
- **The one limit is on the thing being tested.** Create the situation any way at all, then let the
  game run the mechanism through ordinary input: make a ledge and walk off it, never force a hop; put
  water beside the player, then face it and cast. Forcing the OUTCOME tests nothing.
- **Label what you claim.** "Walked to X" and "reached X" are different sentences, and only the first
  is about the game; `verified.md` entries name which. Judging what is on screen stays the user's.

## Drive it yourself before asking

**Use every tool** — memory, savestates, hooks, overlays, speed, the decomp as a map, the Go rig,
probes that write (`references/bizhawk.md`). If a state can be reached, forced, faked or measured by
a tool you have, use it; involve the user for a JUDGEMENT, never for labour. **The tell: a message
asking the user to do something in the game that no human hand was needed for.** Script, in rough
order of demand: reaching a state, holding it steady while measuring, repeating it exactly after a
change, returning to a checkpoint.

## The loop: look, check, act, verify

1. **Look first** — a screenshot on arriving anywhere new, before deciding anything.
2. **Check what this SAVE has** — party, bag, badges — before planning around an ability.
3. **Somewhere unfamiliar, talk to NPCs and read signs**: they usually say where to go and why not.
4. **Act. Menus are cursor-then-confirm**: move the selection, THEN confirm. **A** activates whatever
   is highlighted; **B** cancels, declines and advances dialogue; **START** often means OK on entry
   screens. **TAP** confirm, never hold it (a held A answered the menu under it), and never press blind.
5. **Verify with a memory read** — did the coordinate, map id, cursor or menu state change? A wrong
   menu press looks exactly like being stuck: ask "what is selected", not "why is this game broken".

## Pressed, and nothing changed

A wall, a one-way ledge, an NPC mid-sentence, an open text box, an ability the save lacks and the
wrong menu entry all look the same from the input side. **If the trip is not the test, skip it and
build the state** (`references/building-a-state.md`). If walking IS the test, cheapest first: walk
it; after two failures look at a screenshot (usually an NPC or a text box, not geometry); if it really
is geometry, step perpendicular or walk the edge for the gap, backtracking if needed; then write past
it and move on. **Never a third attempt on inputs** (`references/navigation.md`).

## Rigs and savestates

- **Build a state with `cmd_drive.lua`** (Crystal and Emerald, vanilla): commands in `cmd_drive.cmd`
  beside it, read every 15 frames (`references/building-a-state.md`).
- **Any driven-input rig needs an explicit idle-does-nothing mode** a measurement can take — a driver
  that "kept going" walked a player six tiles off the measurement tile. **A queue file beats a
  reload**: reloading a driver drops the adapter with it. Take the driver off the target when done.
- **On a trip to one state, bank a savestate at every milestone** in a free slot and name the slots
  in your report. A savestate is not an in-game save (`agent_docs/environment.md`).
- **A run that ends badly is still a result.** Stuck, lost, softlocked: report it, never rewind out
  of it quietly — the reload deletes exactly the evidence worth having.
- **Move as a player does, never in stutter steps** — one continuous `sequence` (overlapping holds) or a
  one-call program (`walk`, `goto`, `battle`, `advance_text`); stepping is tolerable only while a driver is
  new, and fixed early. A loop you run must stop within seconds of nothing changing and say what it saw.

## Speed and screenshots

- `client.speedmode(n)` is a request, not a guarantee (400% gave about 2.3x on a loaded host).
  Measure what you got; **never reset a speed you did not set**; put back what you changed.
  **Set the game's own text speed to its fastest** (a main-menu or in-game OPTION); a snapshot keeps its own.
- **Capture the game frame** where the host can (`client.screenshot()`); a drawn-tier ghost is not in
  it, so judge that tier with counters. Picture and numbers in the SAME frame. Shots go to
  `dev-scripts/shots/<game>/` (gitignored), never a scratch folder (`references/screenshots.md`).

## Along the way

- **An Archipelago seed is the same world**: routes and NPCs transfer; item contents, addresses and
  earned progress do not. Share route knowledge with the other instances (`references/navigation.md`).
- **Write down what you pass through** — battles, menus, cutscenes, warps — not only what you came
  for: untested states are where adapter bugs live. A recipe that worked goes into
  `references/building-a-state.md`, dated.
- **The decomp is a map** of where to look and what a script checks, never evidence
  (`agent_docs/licensing.md`). Perfect information is not cheating.
- **Finishing is optional**: a state reached is a state banked.

## Report

Goal and result; walked or reached, per segment; cheats used; savestate slots banked, with labels;
stuck events and their causes; new facts learned; the screenshot folder used.

## References

- `references/building-a-state.md` — before making anything happen: `cmd_drive` and the recipes.
- `references/navigation.md` — moving through a world by input: what things on screen are,
  backtracking, NPCs and signs, what the save has, the Archipelago transfer table.
- `references/screenshots.md` — before taking or reading a picture: folders, tools, the drawn tier,
  the surfing-reflection example, the same-frame rule.
- `references/bizhawk.md` — the whole Lua tool surface, and the speed measurements.
- Scripts, at their repo paths: `adapters/emulator/pokemon/{crystal,emerald}/probes/cmd_drive.lua`,
  `dev-scripts/bizhawk-screenshot-loop.lua`, and `emerald/probes/bikeloop_probe.lua` (a scripted run
  that reports the speed it actually reached).
