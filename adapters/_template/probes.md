# Probes: how to build one that answers something

**A probe is a question asked of a running game, and most of them fail as questions rather than as
code.** This file is the method: how to search for something you cannot name, how to instrument a
running game without changing what it does, and how to make a probe a human can actually run.

**Read it before writing your first probe for a new game**, alongside
[README.md](README.md) (which is the adapter-building story) and
[../../agent_docs/effect-investigation.md](../../agent_docs/effect-investigation.md) (which is the
how-to-run-the-hunt playbook for visual effects specifically).

Every lesson here is dated and came from a real run in this repo, most of them expensive.

**The three that cost the most, if you read nothing else:**

1. **A probe can break the thing it measures**, and then every reading agrees with itself.
2. **A probe too expensive to run does not report being too expensive** — it reports nothing, which
   reads as "the game did nothing".
3. **A filter applied before you look is a guess about the answer**, and a wrong guess still
   produces a complete-looking result.

---

## Hard rule: a probe asks for endurance, not timing — the user's standing preference

**Every live probe run costs the user a real game launch.** A probe that needs a re-run because a
window was missed spends their time, not compute, and that is the expensive resource here.

So, as a rule and not a nicety:

- **Fixed-length phases with a spoken countdown** — "walk one way for 15 seconds, then walk back",
  "stand still, then get into a battle" — never a keypress at the right frame and never a moment
  the player has to hit.
- **When a moment must be caught, catch it yourself.** Sample through the phase and keep the
  snapshot that best fits what you are looking for (the one least like the baseline, say), so a
  slow encounter or a late door costs nothing.
- **Let the sloppy parts not count rather than spoil the run.** Turning around, pausing, walking
  into a wall: a phase should tolerate all of it and simply record less.
- **Never close a phase on a race to a threshold.** A byte ticking on a frame timer reaches any hit
  count long before a walking player does, so the phase ends while the real answer has moved twice.
  Four Crystal runs produced four different "candidates" that way, every one a counter.
- **Detail to the log file, headlines to the console.** A full dump floods the emulator's console
  pane and scrolls the answer away; the file is uncapped and authoritative, which is also why every
  probe writes one beside itself.

**Stated by the user 2026-08-18**: these runs are "way easier to do/follow" than the earlier
Crystal probes, and the Emerald ones were "way too fast/hard to time". Treat a probe that demands
precision from the player as unfinished work, the same way a flaky test is.

## Dump everything. A filter is a guess about the answer

**When you dump a class's functions or properties to read yourself, do not filter first.** The
needle list you would filter by is a guess about what the answer is called, made before you know
what the answer is — and if the guess is wrong the dump still looks complete, so nothing tells you.

Found the expensive way, 2026-08-17: a filtered function dump (`slide|crouch|duck|mesh`) hid the
one function that mattered — a Blueprint Timeline update handler — through nine failed attempts.
The unfiltered dump was **473 functions**, which is one screen of scrolling and under a minute to
read. The noise costs less than a single wasted build-deploy-play cycle.

Filter while reading, never before. Same for property dumps and log greps.

## Log a window, not an event

An on-change trace tells you what a value became; it cannot tell you *when*, and "when" is often the
whole answer. When something looks intermittent, ordering-dependent, or "mostly fine", log a fixed
window of consecutive ticks across the transition, with the source state and the result side by
side. One such capture collapsed three apparently separate Pseudoregalia bugs into one latch.

Related, when a write of yours keeps getting undone: something is **maintaining** that value. Ask
what state *it* reads rather than writing harder — re-asserting every tick just loses the race
visibly.

## Drive the input one way, then reverse it — a probe the player can actually run

When you need to find *which* of 32k bytes is a thing, the hard part is usually the reference: a
differential scan wants to know when a step happened, which normally means already knowing the
coordinate you are looking for. **Remove the reference by making the input unmistakable instead.**

**Hold one direction for a long stretch, then hold the opposite for a long stretch.** Almost
nothing in memory changes by the same ±1 many times running, and of the few things that do, only
the ones that answer to you *reverse* when you reverse. A counter keeps counting; a timer keeps
ticking; the player's coordinate flips sign. That single contrast did in two runs what four runs of
one-direction scanning could not, and it needed no published address, no anchor, and no assumption
carried over from a vanilla build (Crystal/Archipelago, 2026-08-18 — `ap_reverse_probe.lua`).

It generalises past addresses. Anything you can drive hard in one direction and then undo — walking
an axis, gaining then spending a resource, entering then leaving a state — lets you ask "what
follows me, and what merely moves?" without a reference value to compare against.

**Two design rules make it a probe a human can actually run:**

- **Fixed-length phases, not a race to a threshold.** An earlier version closed its phase on the
  first address to reach N hits — and a byte ticking on a frame timer reaches any N long before a
  walking player does, so the phase ended while the real answer had moved twice. Four runs, four
  different "candidates", all counters. Run each phase for a fixed count of frames, keep
  *everything* that qualified, and let the reversal do the discriminating.
- **Ask for endurance, not timing.** "Walk one way for 15 seconds, then walk back" needs no
  precision, no keypress at the right frame, and no re-run when the moment is missed — compare
  that against a probe requiring a change to be caught within a window. Print a countdown so the
  player knows where they are, and let the sloppy parts (turning around, pausing) simply not count
  rather than spoil the run.

Carry nothing forward as an exclusion, either. If a byte fails the reversal, let the run *say so*
with its evidence, rather than hard-coding it out of the next probe: an exclusion list is a claim
you stop re-testing, and the next counter just inherits the place you cleared for it.

## Test it in motion, and score it against what moved

Two failures from the same day, both of which produced a confident wrong answer that survived
repetition:

**A still-life test agrees with itself.** A candidate for a game-state byte survived two
independent four-snapshot runs — right value in the overworld, right value in a battle, twice
over. It was wrong, and it was wrong because every one of those eight snapshots was taken while
the player stood still, which is exactly what the probe asked for. In motion the byte flickers
several times a second. **Before believing a static agreement, sample the candidate while the game
is actually doing the thing** — repetition of the same condition is not independent evidence.

**Score against the observation, not the instruction.** A probe that asked the player to "walk
left/right, then up/down" and attributed every change to the current phase reported that both real
candidates moved on both axes, and rejected them. The player had drifted a tile sideways at the
start of a phase, as anyone would. Re-scoring the same log against *which coordinate actually
changed* made it unanimous: 70 of 70 X steps and 67 of 67 Y steps, mirrored. **What you asked for
is an intention; only the game state is evidence** — and the fix costs nothing, since the probe is
already reading the coordinate it needs to attribute by.

## Two parameters that trade off against each other give you one answer N times

If a search varies both a base address and an offset within the entry, then `base+k` with
`offset-k` describes the same bytes as `base` with `offset` — so a table found at one place gets
reported at every alignment, and a clean single result looks like sixteen candidates. Found live
2026-08-18 hunting Crystal's map-object table: 16 "candidates", all one table, `base + offset`
constant across every row.

That is not a reason to fix the parameter you were unsure about. **Search both, then collapse the
degenerate family and pick the alignment on independent evidence** — here, entries carry an index
back to the struct that points at them, and only one alignment makes that back-pointer agree in
both directions. A search dimension you cannot resolve from *within* the search needs a constraint
from outside it.

## Reverse the STATE too, not just the input

The reversal idea generalises past movement. A state flag is found the same way a coordinate is:
put the game into a state, take it back out, and keep only the bytes that came back. Overworld ->
battle -> overworld finds a battle flag; map A -> map B finds map identity; and the two together
separate them, because a map identity byte is unchanged by a battle and a battle flag is unchanged
by a map.

**Match on the game's SEMANTICS rather than its addresses when a build has moved things.** "This
byte reads 2 in the overworld and something else in a battle" is knowledge about the game that
survives a patch rearranging WRAM; "this byte is at 0xD432" is not. A signature of three or four
such facts across snapshots is not something a byte satisfies by accident.

**Do not make the human time the transition.** Sample through the phase and keep the snapshot that
differs most from the baseline — the battle is then found wherever inside the phase it happened,
and a slow encounter costs nothing.

## Delay your own change, so its effects separate from the game's own startup

The noisiest moment in any game is the first few seconds of a level: cameras pick targets, systems
initialise, actors register. Introduce your thing into *that*, and every consequence of it arrives
tangled up with consequences of the level loading, which you cannot tell apart.

**Hold your change back by a few seconds after the local player is valid, and the game goes quiet
first.** Whatever then happens is yours. Pseudoregalia held ghost spawning for ~300 game-thread
ticks (~5s), and that alone turned "the camera sometimes ends up on the wrong target" into a
clean, isolated event ~2.6ms after spawn — a timestamped one-off instead of a vague interaction
with level entry. It is the time-domain version of logging a window: rather than logging a window
around a moment, you *move* the moment somewhere the log is empty.

Two things to get right. Delay from **the player becoming valid**, not from mod load — mod load is
early and varies, player-valid is the event the game's own startup hangs off. And **make it a
constant you can set to zero**, because this is a diagnostic scaffold, not behaviour: once the
question is answered, a delay before a peer appears is a cost users pay for an investigation that
already finished. Zero it, and keep the constant so the next investigation can raise it again.

## The cost warning: a probe can break the effect you are measuring

This is the single most expensive lesson in this repo, and it is a *method* failure rather than a
game-specific one — which is why it sits in this file rather than in one adapter's notes. Full incident in
[agent_docs/pitfalls.md](../../agent_docs/pitfalls.md), "The diagnostics were the bug".

A per-tick enumeration of live objects, with a name lookup or string conversion per object, is far
more expensive than it looks — and if the engine spawns the effect you are studying as a *countdown
across ticks*, stalling the game thread truncates the very bursts you are trying to count. In
Pseudoregalia that produced an intermittently missing trail while **four separate metrics reported
exact parity**, because every object that survived was correct and only the destroyed ones were
absent. A second probe made it worse by *spawning* the same kind of object it measured.

So, when instrumenting an effect:

- **Compare by pointer, not by name.** The enumeration itself was affordable; the per-object
  `GetFullName()` and UTF-8 conversion were not. Comparing an object reference against a known
  component pointer is nearly free.
- **Keep probes off by default and re-test with them off** before believing any result. Never leave
  a probe that *spawns* the effect enabled while judging that effect.
- **Prefer edge-triggered logging** to per-tick, and treat any figure gathered while a heavy probe
  was live as suspect afterwards.
- **If a human keeps reporting a difference your metrics deny, suspect the metrics.** Agreement
  between two sides measured by one instrument is not correctness — a shared blind spot makes them
  agree and describes neither.

## Two more probe traps

- **A probe that returns nothing is a result, not a malfunction.** Ask what a genuine zero would
  mean before widening the net. Here, "no object ever disappeared" *was* the finding.
- **A sampling window that is too narrow produces a false negative indistinguishable from a real
  one.** One probe reported "0 new objects" every run and concluded the effect was pooled; the
  objects were in fact created slightly later than the sample and then persisted. What caught it
  was the *totals* printed beside the diff, climbing by exactly two each time. So: always print a
  **total**, not only the difference; diff **across** probes so anything appearing in a gap is
  still attributed; and never let a probe write its conclusion into the log ("likely pooled") —
  log the observation and conclude outside it, because a wrong conclusion in a log file outlives
  the run and gets believed later.

## Don't pay a relaunch per probe revision (BizHawk)

`EmuHawk.exe --lua=<script> "<rom>"` attaches a script at launch, but swapping one on a *running*
emulator is a Lua Console GUI action nothing outside the process can drive — so every edit
otherwise costs a full relaunch, and each relaunch interrupts whoever is holding the controller.
`dev-scripts/bizhawk-dev-loader.lua` is attached once and then loads, swaps or drops whatever
script a one-line control file names. Write a probe to its contract — set `MESHGHOST_DEV_TICK`,
no `while true ... emu.frameadvance()` loop of your own, and gate that loop on
`MESHGHOST_DEV_LOADER` if the file should still work opened directly. Details and the confirmed
live behaviour: `agent_docs/environment.md`.

## A probe's read budget is real — an emulator's script host is slow

**Scanning a lot of memory every frame does not work, and it fails silently.** An emulator's Lua (or
equivalent) host charges per call across a managed boundary, so a scan that looks trivial as an
expression is thousands of those calls per frame. It does not error — the script stalls, the
emulator drags or hangs, and **you get no log at all**, which reads as "the probe did nothing"
rather than "the probe never ran".

**Found live 2026-08-18**, hunting for an address on a patched Crystal ROM: a probe read all 32 KB
of WRAM every other frame. It produced no output whatsoever, and the live testing done for it
measured nothing — the run had to be repeated.

**What to do instead**, cheapest first:

- **Sample less often.** If the thing you are watching takes ~16 frames (one walking step, say),
  sampling every 10 frames still cannot miss it, and costs a sixth as much.
- **Only pay the big cost on interesting frames.** A cheap check first — has a single reference
  byte changed? — then the wide scan only when it has. An earlier probe in the same session
  survived a full-WRAM scan precisely because it only ran it on change frames.
- **Narrow the range** once you can justify it, and say in the log what you excluded, so a null
  result cannot be mistaken for "searched everywhere".
- **Check for a bulk-read call** in the host's API, which is one boundary crossing instead of
  thousands — but confirm it against the host's own documentation rather than assuming it exists
  ([CLAUDE.md](../../CLAUDE.md)'s no-APIs-from-memory rule).

**The general shape, worth carrying to any future emulator adapter:** a probe that is too expensive
does not report being too expensive. Budget the reads *before* the run, and if a probe produces no
log at all, suspect its cost before suspecting the game.

## See also

- [README.md](README.md) — the adapter-building story this file was split out of, including
  "Ask the game what it has, before you guess at what it might have" (enumerate first) and
  "When several mechanisms each 'do nothing', try them together" (the union rule, which is about
  the testing *cycle* rather than the probe).
- [../../agent_docs/effect-investigation.md](../../agent_docs/effect-investigation.md) — the
  how-to-search playbook for a game's visual effects, followed end to end on one real investigation.
- [../../agent_docs/pitfalls.md](../../agent_docs/pitfalls.md) — the adapter-specific issues log;
  "The diagnostics were the bug" is the full incident behind the cost warning above.
- [../../agent_docs/testing.md](../../agent_docs/testing.md) — the Go-side automated checks, which
  are the opposite case: deterministic code against a contract we own, confirmed with tools rather
  than by watching.
- [FLAGS.md](FLAGS.md) — where a probe's switch goes once it exists, so that "off by default" is
  written down somewhere and not just believed.

## Ways of finding things that worked — collected 2026-08-18

A day of Emerald spawn work produced these. Each one replaced something slower or wronger, and
they are ordered by how often they paid off.

**Compare against a control that definitely works, field by field.** The player's own object and
sprite are a live, correct example of exactly the thing being built. Log both side by side and
every matching field is ruled out while every differing one is a candidate. This turned "the ghost
does not render and I cannot see why" into a two-line diff showing the OAM was the only thing out
of place. **Always log the working example next to the broken one** — it is far more informative
than dumping the broken one in more detail.

**Ask the host what it has; do not trust documentation or DLL strings.** `joypad.get()` returns a
table whose KEYS are exactly the buttons this core accepts. `client.getluafunctionslist()` returns
what this build actually implements. `memory.getmemorydomainlist()` returns the real domains. This
project has already been burned by a function whose doc string existed while the function was nil
at runtime, and by button names that differ per core.

**Grep the decompilation for who WRITES a field, not for what it means.** Suspecting
`subspriteTableNum` was wrong, one `grep -rn "subspriteTableNum" src/*.c` showed the engine sets it
from elevation every frame — killing the hypothesis in a single call instead of an experiment.
"Who writes this?" is usually a faster question than "what is this for?".

**Dump a whole TABLE, not the one entry you care about.** Printing the graphics entry for seven
player states at once made the answer obvious at a glance: the normal graphic is 16 wide and every
special state is 32 wide with a different OAM and subsprite table. Asking only about the bike would
have shown a number with nothing to compare it to. Same principle as dumping neighbouring objects
rather than the object being debugged.

**Bisect by toggling one write at a time, through globals you can flip between reloads.** Debug
switches (`skip the OAM copy`, `share the player's tiles`) turned "some part of this rewrite is
wrong" into three runs that named the part. **Assign every switch every time** — Lua globals
survive a script reload, so a switch left unassigned keeps a previous experiment's value, which
caused two confusing runs on its own.

**Zoom the screenshot before judging a sprite.** A GBA frame is 240x160; a character is 16 pixels
wide and unreadable at that size. `dev-scripts/zoom.ps1` crops and nearest-neighbour upscales, which
is what made "is that a bike or a person?" answerable at all. Nearest-neighbour matters — smoothing
invents detail that is not in the frame.

**Decode a number, then look it up, before believing it.** Cheat codes, addresses out of a scan, a
pointer read live: `grep` it in the decomp's `.sym`. `0xD857` becoming `wBadges` is confirmation;
`0xD57C` becoming `wObject4Palette` is a trap caught before it corrupted anything.

**And the failure mode that recurred all day: a measurement taken at the wrong moment.** A
screenshot fired before the adapter had connected produced three convincing pictures of a game with
no ghost in it. A probe does not fail when it measures the wrong instant — it answers a different
question persuasively. Delay to a known state, and log the state alongside the reading so the
mismatch is visible.

## Edit the world instead of travelling to it — 2026-08-18

**If the game decides something from a value, the cheapest way to reach that state is to write the
value.** Emerald's surf and fishing work needed water, and the water was several maps away. Walking
there costs the user's time; warping needed machinery we did not have. But a tile is water because
one halfword says so — so the tile the player was standing next to became water, and the state was
reachable in seconds. `adapters/pokemon/emerald/probes/watertile.lua` is the worked example.

The generalisable parts, in the order they matter:

**Ask the decompilation what makes the state true, not how to get there.** "How do I reach water"
is a navigation problem with no good answer. "What does the game read to decide a tile is water" is
a lookup: a metatile id, whose behaviour byte lives in the tileset's attribute table. One is a
journey, the other is a write.

**Search what is ALREADY LOADED for something with the property you need.** The water metatile was
found by scanning the current map's own primary and secondary tilesets for a behaviour of
`MB_POND_WATER`/`MB_OCEAN_WATER`, rather than hardcoding an id from a seaside map. An id from a
tileset this map has not loaded would render as unrelated garbage. **Generalises to anything
id-based**: graphics, items, animations, palettes — find a live instance of the property in the
data the game currently has, and copy its identifier.

**One field is not one property.** The map grid halfword holds a metatile id, collision bits and
elevation bits, and they are independent. The first attempt changed the id only, so the tile had
water *behaviour* while remaining walkable — and a "walk into it" test walked straight through and
reported the edit had failed, when the half that fishing cares about had worked. **When a write
seems not to have taken, check whether the property your test measures is the property you
changed.**

**Visual absence is not functional absence.** The edited tile still *looked* like grass, because
the map view is only redrawn as it scrolls — while the game's own collision and behaviour checks
read the grid and agreed it was water. A screenshot would have said "the edit did nothing". The
behavioural test (drive into it, read the coordinates) is what settled it.

**Make the edit reversible and say so.** The tool restores the original halfword when unloaded, and
the map is rebuilt from ROM on the next map load regardless — so a mistake costs a door. A dev tool
that edits the world should always have an obvious way back, because the alternative is being
cautious with it, and being cautious with it is how it stops being used.
