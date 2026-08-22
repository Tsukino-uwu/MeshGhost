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

## Screenshot to your own game's folder, and actually take them — 2026-08-19

`dev-scripts/shots/<game>/`, one folder per game **and per patched variant** (`crystal/`,
`apcrystal/`, and so on); create it if missing. `bizhawk-screenshot.lua` is the tool, and a probe
that overwrites one PNG on a timer is enough to watch a session evolve.

**Why it is a rule and not a preference**: a session ran four emulators for hours and produced
screenshots for exactly one of them, because the other three wrote into a per-session scratch
directory that then disappeared. Nobody — including the user — could see what three games were
doing.

A picture is a working aid, never evidence (`agent_docs/testing.md`), and the tree is gitignored
accordingly. But it is how a human checks an agent's claim cheaply, and how an agent notices the
thing it was not looking for. Take them; and when a picture is ambiguous, answer the question with
a counter instead — see the entry below.

## One sample cannot see a blinking thing — 2026-08-19

**The user's example, and it is the clearest one: "PRESS START" flashing on a title screen.** Take
a screenshot on the wrong frame and the prompt is simply not there. Nothing failed, nothing
errored, and the picture is perfectly sharp — it just shows a screen with no instruction on it,
and a reader concludes the game is stuck, or that there is no prompt, or that the script is not
running. **A single sample of a periodic thing is a coin flip you did not know you were tossing.**

This is not a screenshot problem. It is a **sampling-rate problem**, and it applies to every probe
that reads a value once:

- **Anything that blinks**: a prompt, a cursor, a selected menu entry, a flashing low-health bar.
- **Anything that strobes as a side effect of being redrawn**: Crystal's menu rectangle
  (`wMenuBorder*`) returns to `0,0,0,0` and back several times a second **while the menu is
  plainly on screen**, so a single read says "no menu" half the time.
- **Anything that happens on a small fraction of frames**: the Game Boy dropping sprites past its
  per-scanline limit happened on **2-3% of frames** with a crowd on screen. A screenshot would
  essentially never catch it, and the user's own honest answer to "can you see flicker?" was
  *"kinda hard to tell"* — which is the correct answer, and the reason it was settled by counting
  sprites per scanline instead.
- **Anything alternating**: a two-frame walk cycle, an animation that swaps between two poses.

**What to do instead:**

- **Sample across time and report the RANGE**, not the instant: min, max, and "was it ever true".
  The crowd probe logs `oam=14..38 of 40` per window for exactly this reason — the 14 and the 38
  are both true, and either alone is a lie.
- **Sample for longer than the period you are looking for**, and if you do not know the period,
  log every change rather than every Nth frame. "Log a window, not an event" above is the same
  advice from the other direction.
- **Beware a sampling interval that shares a factor with the thing you are watching.** A
  screenshot loop firing every 120 frames against a walk cycle of 240 produced *identical* pictures
  every time, which read as "nothing is moving" — the game was moving fine. Pick an interval that
  cannot align (a prime number of frames is a cheap way), or trigger on change instead.
- **When a human says they cannot tell, that is data.** It means the effect is near the edge of
  perception, so measure it rather than asking them to look harder.

**The general form**: a probe that reads once answers *"what was true at this instant"*, and it is
easy to read that as *"what is true"*. If the thing can change faster than you sample, those are
different questions.

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

## How to find things — the general form, collected 2026-08-19

A night of adapter work produced the same handful of moves over and over. They are listed as
moves rather than principles because each one is something to *do* when stuck.

**1. Ask the system for its answer instead of re-deriving it.** Three attempts to convert the
engine's sprite coordinates into screen pixels by reasoning each left rows and columns unfilled.
What worked was reading OAM — what the hardware actually draws from — and calibrating against it
every frame. Same move solved facing and animation: rather than decode how 12 tiles become a walk
cycle, watch the engine render the player and copy the arrangement it used. **If the system
already computes the thing correctly, read its answer.**

**2. Validate the method on a case whose answer you know.** The Archipelago sprite table was found
by scanning the ROM for a structural signature — and the same scan, run against the vanilla ROM,
returns the address already established from the decomp. That agreement is what makes the new
number evidence instead of a guess. **A method that cannot rediscover what you already know is not
a method.**

**3. Make the log separate the candidate causes.** "Half the screen is empty" is unactionable;
`89 waiting, 43 drawn, 0 no sprite tiles, 40 off screen, 0 hidden by UI` names the culprit in one
line. Design the counters so each hypothesis has its own bucket, and the next number you read
tells you which one is true.

**4. When two fixes do not move the number, stop fixing.** The ghost-snapping bug took three
attempts; the first two were plausible, correct in themselves, and moved 64 jumps to 39 and then
37. That flatness was the signal that the real cause was elsewhere — it turned out to be an OAM
entry whose order flips with facing. **A fix that barely moves the measurement is evidence about
the diagnosis, not a partial win.**

**5. Cross-check from an independent direction.** The patched ROM's table was measured by scanning
the file, then confirmed by the adapter validating it inside the running emulator. The menu
rectangle was read from RAM, and it agreed with something the user had noticed by eye. Two
disagreeing methods is a finding; two agreeing methods is a fact.

**6. Test with a crowd, not a case.** Three leaks appeared only with dozens of peers — each
invisible alone, because a leaked ghost looks exactly like a peer standing still. **Load is a
different question from correctness, and it finds different bugs.**

**7. Assert the number, do not describe it.** One measurement was quoted in six documents and two
comments, wrong in all of them, because nothing checked it — the tests asserted only an
inequality, which stays true however far off the number drifts.

**8. Phrase a failure as what YOU observed.** *"Scripted input did not get past this NPC"* invites
a one-line correction; *"the route is story-blocked"* is a claim about the game that a reader will
believe and build on. This project has one of the latter in its record, and it was wrong.

**9. Watch invariants continuously, and log only violations.** A watcher that prints nothing is a
result. The three rules worth watching were each something that had just broken — which is the
general recipe: **today's bug is tomorrow's invariant.**

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

## Or play to it — reaching a state is a legitimate way to measure it (2026-08-19)

The section below says to edit the world rather than travel to it, and that is usually right. The
complement, granted by the user on 2026-08-19: **an agent may simply play the game to reach a
state**, on an instance it owns, with `client.speedmode()` to make it cheap.

**When playing beats editing:**

- **The state is a whole situation, not a value.** A trainer battle is a script, a party, a menu
  and an opponent — writing a byte that says "in a trainer battle" gets you a number, not the
  situation, and the thing you wanted to measure is usually a consequence of the situation.
- **You do not yet know which value to write.** The Archipelago Crystal `wBattleMode` question is
  exactly this: the whole point is to find out which address holds it, so there is nothing to
  fake — the game has to actually be in a trainer battle.
- **The journey is a test.** Walking to a state drags the adapter through menus, warps, cutscenes
  and battles nobody scripted, which is where bugs of the kind a crowd test finds tend to live.

**When editing still wins:** a state that is a single well-understood value, a state you need
hundreds of times, or anything where the walk is long and the value is already known.

**But if the PLAYTHROUGH is the test, editing is disqualifying** (user, 2026-08-19): no spawned
items, no teleporting, no warping past something not yet earned — **and no savestates either**,
because a savestate is time travel and lands in the same category ("its the same as not
cheating"). Reading is unrestricted —
position, flags, tile behaviour, the decomp itself — because the rule is *observe freely, intervene
never*. The two claims are simply different: a probe that fakes water tests "what does the fishing
code do", a playthrough tests "a player can get there and the adapter survives the trip", and a
faked state answers only the first. See `agent_docs/environment.md`.

**Finding the route is a deliverable, not overhead** (user, 2026-08-19). When an agent has to get
somewhere in a game, *how* it worked out the way is worth recording — the next agent dropped into
an unfamiliar map can reuse a method, and cannot reuse a sequence of button presses. The user's
framing when they gave a stuck agent one hint and deliberately withheld the rest: *"i want it to
figure it out mostly on its own, as that would be great to document/log how to do/search/find
things"*. So a hint exists to stop a dead stop, not to replace the search. What to capture:

- **What you READ to decide where to go.** A decomp gives you map connections, warp events and each
  map's own object list — route-planning from data is the same discipline as probe-planning from
  data, and beats wandering by a wide margin.
- **How you distinguished "blocked" from "not talked to yet" from "wrong tile".** That exact
  distinction cost this project a false finding in the record (`pitfalls.md`, the NPC that was read
  as a story block).
- **What the adapter already tells you for free.** Map group/number and coordinates are read every
  frame by the adapter itself — a position fix with no screenshot and no ambiguity.
- **What you did when a picture was ambiguous**, remembering that one frame cannot see a blinking
  prompt.
- **The dead ends, briefly.** A route that did not work is the more useful half of a map.

**Practicalities**, all measured on this project's own hardware (`agent_docs/environment.md`):
speed settings are a request rather than a guarantee — 400% delivered about 2.3x on a loaded host
while 200% delivered its full 2x — so measure frames against the wall clock rather than trusting
the multiplier. **Savestate every milestone** and name the slot in your report: a state that cost
ten minutes of scripted play is worth more than the measurement it unlocked, because the next
session inherits it. And read the decomp to plan the route — knowing what a script checks turns
"wander and hope" into "walk here, press this".

## Edit the world instead of travelling to it — 2026-08-18

**If the game decides something from a value, the cheapest way to reach that state is to write the
value.** Emerald's surf and fishing work needed water, and the water was several maps away. Walking
there costs the user's time; warping needed machinery we did not have. But a tile is water because
one halfword says so — so the tile the player was standing next to became water, and the state was
reachable in seconds. `adapters/bizhawk/pokemon/emerald/probes/watertile.lua` is the worked example.

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

## A state is often a multi-step process with branches, not a flag — 2026-08-18

**Do not assume a state is on/off, or that one input produces it.** The user, on being told fishing
would be scripted:

> *"fishing happens in steps, you can not get a bait, you can get a bite but need to time it 1 or
> several times, and then you get into a battle if you do all the baits properly. so after that you
> would have to run from the battle."*

So "use the rod" is not one behaviour but at least four outcomes, as the user enumerated them:

1. **nothing bit** — the cast simply fails
2. **something bit and you missed it** — a bite, then a failed reaction
3. **something bit and it takes several rounds** — the timed reaction repeats before it resolves
4. **something bit and you land it** — which starts a battle, that you then have to escape

A probe written as "press the button, read the result" measures whichever of those four it happened
to land in, and reports it as *the* behaviour. Worse, outcome 1 and outcome 2 both end with the
player standing still holding a rod, so a probe that samples only the endpoints cannot tell them
apart at all.

**What this changes about how to probe such a state:**

- **Record a window across the whole process, not a reading at the end.** The Emerald fishing
  capture is the model: logging every change produced `take out rod -> put away rod` (a bite that
  got away), then `take out rod -> hooked`, which is the branch structure visible in the data
  without anyone having to describe it first.
- **Expect to see the failure branches, and keep them.** They are usually more informative than
  the success: "put away rod" is what told us a failed bite is a distinct animation rather than
  nothing happening.
- **Do not script the timed parts blind.** A human plays the minigame far better than a scripted
  input sequence guessing at frame windows, and the point of the probe is what the ENGINE does, not
  whether the agent can fish. Drive the setup (reach water, open the bag, start the state) and let
  the person handle the timed middle — or accept many retries, which savestates make cheap.
- **Plan for the state to end somewhere else entirely.** Fishing can drop you into a battle, which
  is a different map state with a different object array. Anything the probe holds across that
  boundary — a spawned ghost, a slot index, a tile edit — has to survive it or be re-established.

**The general form:** before probing a state, ask *"how many steps is this, and which of them can
fail?"* If the answer is more than one, the probe wants a window, a log of every transition, and no
assumption about which branch it will see.

## Check what a thing IS and DOES — never assume from its name or its effect

**The user, 2026-08-18, after the third time in one session:** *"check what something is/does,
don't assume."* Each instance below cost real time, and each was one grep away from being right.

**1. Assumed a message meant one thing; it meant another.** A scripted rod use in Emerald failed
with a refusal message phrased as fatherly advice about doing things in the right place. That was
written up as a story-progress gate. It is actually the game's generic **"you cannot use that
HERE"** — the same message you get riding a bike indoors. (Described, not quoted: extracted in-game
text is on the Never side of `README.md`'s Fine/Never table. Naming *which* message it is carries
the whole lesson; reproducing the text carries none of it.) The wrong explanation was plausible, fitted the evidence, and would
have sent the next session looking at save progress instead of at the tile in front of the player.

**2. Assumed an effect proved a cause.** A tile was edited to be water, the player walked into it,
and was **blocked** — recorded as "the game treats it as water". It proved only that the tile was
*impassable*. Behaviour and collision are different fields of the same halfword, and only one of
them had been tested.

**3. Assumed a value was correct because it produced the expected symptom.** Setting the collision
bit made the tile solid "like water". Reading what the game actually requires
(`IsPlayerFacingSurfableFishableWater`) showed fishing needs
`GetCollisionAtCoords(...) == COLLISION_ELEVATION_MISMATCH` — **real water is not impassable, it is
a different elevation**. The "fix" that made the symptom look right was the thing preventing the
feature from working at all.

**The rule, and it is cheap:** before believing what a value, flag, message or symptom means, find
the code that produces or consumes it. `grep` the decompilation for the name; read the function
that checks it. "What does the game do with this?" takes one command and replaces a guess that can
survive several experiments — because a wrong assumption does not fail, it produces a result that
looks like an answer.

## A scripted interaction must return the game to a known state — and prove it did

**Found 2026-08-18: a fishing sequence ended with the bag still open.** Every later step was then
being driven into a menu rather than the overworld, and the session was handed back to the user
sitting in a submenu. The script had "finished" in the sense that it ran out of steps.

Two failures in one, and they compound:

- **It never exited.** A sequence that opens menus must close them — and closing is not optional
  politeness, it is what makes the next thing work at all. Input sent to a menu does something
  different from input sent to the overworld, so a leftover menu silently changes the meaning of
  everything that follows.
- **It assumed a press had landed.** The final `A` was issued and the screenshot shows the submenu
  still open, so either it did not register or the sequence moved on before the game had processed
  it. **Pressing is not doing.** Confirm the state changed before continuing, rather than counting
  frames and hoping.

**So a scripted interaction should:**

- **End at a known baseline, and reach it by SPAMMING the back button.** The user's general point,
  2026-08-18: *"you can usually exit/go back from menu's by repeatedly pressing, for example in
  most games, to reach a neutral overworld state / no menu open"*. This is the cheapest known
  technique in scripted-input work and it generalises across games: whatever the UI depth, whatever
  screen you are on, pressing Cancel more times than the menu could possibly be deep lands you at
  neutral. It needs no knowledge of the menu tree, survives the menu having more or fewer entries
  than expected, and recovers from a sequence that went wrong halfway.
  **Which buttons:** the user, 2026-08-18 — *"B/Start is usually for quickly/repeatedly closing
  menus"*. B is Cancel/back one level; Start closes the whole menu outright in many games, so
  alternating or spamming both is more robust than either alone. Neither does damage in the
  overworld: B does nothing, Start reopens the menu — which is why a **preamble** of B/Start
  presses should end on B, so a stray Start does not leave a menu open.
  **Use it as a PREAMBLE too, not only a cleanup** — a scripted route that assumes it starts in the
  overworld should make that true first, rather than inheriting whatever the last run left open.
- **Verify, not assume.** The overworld has a checkable signature (`gMain.callback2` equals
  `CB2_Overworld`); use it as a gate before and after, instead of trusting a frame count.
- **Clean up after itself even on failure**, exactly as a probe that edits the world restores what
  it edited. The user has to be able to pick the controller back up.

### Writing the rule down is not applying it

**2026-08-18, immediately after the entry above was written.** The lesson "spam B/Start to reach a
neutral state, and do it as a *preamble* as well as a cleanup" was committed — and the very next
run of the same script started without a preamble, into a game the previous run had left sitting
in an open bag. The user, watching: *"you repeated the same mistake again."*

**Documentation is a note to a future reader; the code is what runs.** A rule that is written but
not implemented in the thing it is about will be violated by the next person to touch it, and the
first such person is usually the one who wrote it, minutes later, still holding the same
assumptions that caused it.

**So when a probe or script teaches you a rule: change the script in the same pass.** Not
afterwards, not in the next iteration — the same edit. If the rule cannot be expressed in the code,
say why in a comment at the exact place it applies, so the next reader meets it where it matters
rather than in a document they may never open.

## Look first, then write the script — not the other way round

**The user, 2026-08-18, after watching several failed attempts to script a menu:** *"take a
picture, observe it, then write whatever needs to be done. so you actually know what it has to
do."*

That session went: write a button sequence from assumption -> run it -> read a log -> guess what
went wrong -> adjust -> run again. Four rounds, and it ended up on the SAVE dialog, because every
round was inferring the screen instead of looking at it. **A screenshot costs one command and
removes the guessing entirely.**

**The working order:**

1. **Put the game in the state you want to script from**, and screenshot it.
2. **Look at the screenshot.** What is on screen, where is the cursor *actually*, how many entries
   does this menu have on *this* save?
3. **Write the step you can see is correct** — one step.
4. **Screenshot again** and check it landed. Only then write the next step.

This is slower per step and far faster overall, because a blind sequence fails at an unknown point
and every re-run costs the full setup. It also produces a route that is right for the save in front
of you rather than for an imagined one — which matters, since menu contents change with game
progress.

**Screenshots are for the agent's own eyes here, not evidence** (see `agent_docs/testing.md`):
looking at one to decide what to press next is exactly what they are for, and it never becomes a
claim about whether a feature works.

**And when the blind approach has failed twice, stop.** Scripting a menu the user can navigate in
five seconds is rarely worth a fifth attempt — especially when a wrong press can hit SAVE.

### Why a picture FIRST, rather than a picture when something breaks

The user's framing, 2026-08-18: *"taking a picture first means you always know what to expect,
instead of running into issues later."*

That is the difference between one unknown and two. Look first and the starting state is a **fact**,
so if the next step misbehaves the only thing left to question is the step. Script blind and you
discover the state at the moment something fails — and now you are debugging the route and the
state together, with no way to tell which is wrong. Every one of the four failed menu rounds in
that session was that: a wrong route and an unexpected starting screen, indistinguishable from each
other in the log.

It also changes what "expected" means. With a picture you can state the expectation *before*
running — "the cursor is on BAG, so A opens the bag" — and a failure then falsifies something
specific. Without one, "it didn't work" is the whole result, and the next attempt is another guess.

**Generalises past menus:** screenshot before any scripted interaction, and before any test whose
result depends on where the game currently is. It is one command, and it converts an assumption
into an observation at the exact moment that is still cheap.

## Faking a thing gets you its FORM; the data behind it is a separate step

**2026-08-18, Emerald.** A tile was edited into real water so that fishing could be tested without
walking to the sea. It worked: the game accepted the tile, allowed the rod, and played the cast.
And **nothing could ever bite**, because which Pokemon appear is per-MAP data
(`gWildMonHeaders`, keyed by map group and number, with separate lists for land, water, rock smash
and fishing) and the town in question defines none. The fishing routine checks exactly that and
jumps straight to its no-bite branch.

So the fake water was genuinely water for movement and for the rod, and genuinely empty for
everything that makes fishing *mean* anything. The user put it best: *"we added water, we made it
so we could fish, but we missed an important extra step on top of it that made it not do all
functions it's actually intended to do."*

**The general rule: when you synthesise a piece of a game, enumerate what the real thing depends
on before believing the copy is complete.** A real water tile is (a) a metatile whose behaviour is
water, (b) an elevation the player cannot walk onto, and (c) a map that has water encounters. Two
out of three is a tile that looks right, behaves right, and does nothing.

**How to find the missing third:** ask *"what does the game look up when this actually works?"* and
follow it — the encounter path was two greps from the fishing task. Faking geometry is usually
easy; the data keyed to a location, a species, an item id or a flag is the part that is invisible
until it is missing. **And prefer doing the test where the real thing exists** — moving to a route
would have cost less than making water in a town that could never use it.

## Check what tools you actually have before concluding you can't — 2026-08-18

**The rule:** *"don't just assume you can't do something without checking what possible tools you
have available first."* Recorded here because probes are where it bites: a probe exists to answer
a question, and "we have no way to ask that" is itself an answer that must be *checked* rather
than assumed.

**The live example was scripted input.** BizHawk gives a Lua probe `joypad.set`, so an Emerald
probe can drive the game — walk into a tile, hold a direction, run a fishing sequence — and every
probe in `emerald/probes/` that does so exists because that tool was obvious. The PC games looked
like they had no equivalent, so setup stayed manual: every Pseudoregalia or TEVI iteration costs a
real game launch and a hand-walk to the test state, and the ghost-load rig has to be *aimed* by a
human reading a log line. Ten minutes of actually looking found three candidates
(`agent_docs/ideas.md`, "Driving the game itself"), one of which — calling a UFunction through
`ProcessEvent` — the Pseudoregalia mod **already does**, for the ghost's own animation. The
capability was in the file the whole time; only the framing was missing.

**The general shape, and why it is a probe-method rule and not a nice sentiment:**

- **A negative capability finding ages badly and is rarely re-tested.** Once "X can't be done
  here" is written down, tooling gets built *around* the absence and nobody revisits it. In this
  repo that pattern cost the local race detector for two days — see `pitfalls.md`'s
  wrong-install-on-PATH entry, where the conclusion "this compiler can't build cgo" was really
  "the probe was missing a step". Treat "not possible on this machine" as **a dated claim, not a
  property**, exactly as `CLAUDE.md` says for every other dated fact.
- **Look for the capability you already ship.** The cheapest tool is one the adapter is using for
  something else. Before reaching for a new dependency, grep your own mod for the general
  mechanism (`ProcessEvent`, a reflection helper, an existing hook) — a new *caller* is far
  cheaper and far less risky than a new *capability*.
- **Record checked dead ends, not just wins.** UE4SS's `RegisterKeyBind` observes input and does
  not synthesise it, and `QueueInputSource` looks like injection but is explicitly *"not an
  implemented input source"* with `is_available()` returning `false`. Writing that down is what
  stops the next session re-deriving it — the same reason a probe that answered its question is
  kept rather than deleted.

**If you build one, it is a probe and it stays one.** An adapter that can press buttons can play
the game, which is a completely different promise from a cosmetic ghost — off by default, never
shipped, and gated the way `agent_docs/beyond-cosmetic.md` gates anything past cosmetic. The first
milestone is the smallest observable one: reach a loaded save from the main menu, and nothing else.

## Trace the producer and the consumer on the SAME LINE, on the same frame — 2026-08-19

**The single change that ended a ten-cycle investigation.** Emerald's spawned ghost would not
fish correctly, and two guessed fixes had already failed the same way. What broke it open was one
trace line per frame carrying **both** sides:

```
f=2474 P.gfx=137 P.anim=3/3 P.2c=02 P.pos2=8,0 | R.gfx=137 R.sanim=3/1 R.sox=8 |
       G.gfx=0 G.anim=3/0 G.2c=c7 G.pos2=8,0 | gOAM[x=136 y=56] pOAM[x=304 y=160]
```

`P.` is the player (the producer), `R.` is what arrived over the wire, `G.` is the ghost (the
consumer). Every defect found that day was a **disagreement between those columns on a single
frame** — a ghost frozen at `3/0` while the player cycled `0,1,3`; an offset of `8` sitting beside
a graphic of `0`; a wire that said `sox=8` while it still said `gfx=0`.

**Why one line and not two traces.** Every one of those is invisible when you follow one side at a
time, because each side is *individually plausible*. The ghost's numbers looked fine. The player's
numbers looked fine. Only their relationship was wrong, and a relationship cannot be seen in two
files with different timestamps.

### When the data is in ROM, look for the POINTER — it is usually in RAM

**Established on Crystal 2026-08-21**, where the user's verdict was *"its working"* and then *"or
well, partly. good enought noclip at least"* — so: the technique is proven, the coverage is not
complete. It generalises to any game where a lookup table lives somewhere you may not write.

The problem: Crystal's per-block collision comes from the TILESET's table, and that table is in ROM.
This project never writes a ROM, so the Emerald technique — zero the collision bits in the live map
grid — has no equivalent. The first conclusion was "no noclip on this platform", and that was wrong.

**The lookup goes through a pointer, and the pointer is in RAM.** `wTilesetCollisionAddress` +
`wTilesetCollisionBank`, dereferenced by `GetFarByte`, which ends in a plain `ld a, [hl]`. A bank
switch only affects the ROM window, so **if `hl` points into WRAM the read comes from WRAM** and the
bank byte stops mattering. Point the table at a stretch of WRAM that is already zeroes and every
block reports "floor". Nothing is patched; putting two bytes back restores it exactly.

**The question to ask on any game, then:** not "can I change this data?" but "what does the code go
THROUGH to reach it?" A pointer, a length, an index, a bank — those live in RAM far more often than
the data does, and changing one is smaller, reversible, and needs no write where writes are banned.

**Two rules that made it safe, and both are the general lesson:**

- **FIND the scratch region, never assume it.** Picking an address that "looks unused" is how a save
  gets corrupted. Scan for the longest run of zeroes, report where it was found and how much of the
  index range it covers, and re-check periodically that it is still zeroes — if the game starts
  using it, switch the cheat off rather than inventing data.
- **Know what the redirect does NOT cover, and say so.** The zero run found on Crystal was 928
  bytes, which is 232 of the 256 possible block ids; a map using a higher id indexes past the run
  into whatever follows and can still block. Mechanisms that are not this table — ledges, water,
  warps, a trainer's line of sight — are untouched by construction. "Partly" is the honest word for
  a cheat bounded by the size of the scratch it found.
- **Verify by reading what the GAME computed, not what you wrote.** Here that is the four
  adjacent-tile collision values the engine recalculates every frame. Note the trap: read them in
  the same frame as the change and half of them are stale (`down=0 up=0 left=7 right=7`), which
  reads like a partial failure. One second later they were all zero. A verification taken too early
  is its own false negative.

### Performance is a CORRECTNESS property of a probe, not a nicety

**The user's rule, 2026-08-21:** *"non laggy/good performance should be the default for things like
this"* — said after a session where the instrumentation, not the adapter, was what made the game
stutter for an hour.

A probe that costs frame time is not "a slightly slow probe". It is a probe **reporting on a game
that is no longer the game the user plays**, and every number it produces is about the disturbed
system. That makes cost a correctness question, and it gets designed in from the first line rather
than tuned afterwards:

- **The file is the record; the console is a glance.** Open the log buffered (`setvbuf("full", …)`),
  write every line to it, and send only the opening lines and the occasional one to `console.log`.
- **Never flush per line.** Flush on a timer and on close.
- **Both halves cost, and they were measured separately on 2026-08-21**: removing the per-line disk
  flush alone still left **87–175 ms** hitches, because `console.log` appends to BizHawk's GUI
  window and is the expensive half on its own. Fixing one and declaring victory is a wasted cycle —
  and it was, twice in the same evening.
- **Per-frame work is the other half.** Enumerate once per frame, not once per peer; compare by
  pointer or index rather than by name; and never re-scan an array you already scanned this frame.
- **Measure it, do not assume it.** `dev-scripts/bizhawk-hitch-meter.lua` is standing rig: attach it
  first, and read frames-over-20ms and worst-gap rather than an average frame rate, which cannot see
  a stutter at all.

**A probe is not finished when it prints the right answer. It is finished when it prints the right
answer and the hitch meter still reads zero.**

**The practical form:**

- **Buffer, and flush in batches. THIS APPLIES TO SHIPPED ADAPTERS, NOT ONLY TO PROBES** — written
  2026-08-19, read as probe-only advice until 2026-08-21, and in between both Lua adapters shipped
  flushing every log line.
  Per-frame `console.log` visibly lags the emulator — the user reported it within a minute
  (*"its spamming the console lag, and the game is lagging"*). Even a per-frame `io.open` is a
  probe heavy enough to change what it measures. Accumulate into a table and write every ~120
  lines, or open the file with `setvbuf("full", …)` and flush on a timer.
- **A PER-SECOND LOG LINE IS A PER-SECOND STALL.** Measured 2026-08-21: one `console.log` plus one
  `flush` cost **63–83ms** — four to five frames — every time, on the emulator's own thread.
  Crystal's drawn tier wrote one summary line a second whenever peers were present, so a real
  player lost that every second; Emerald wrapped the global `console.log` so every console line
  flushed too. Neither showed up in any frame-RATE reading, which stayed at 59.7fps throughout.
  **The cost is per call, so "only once a second" is not small — it is 5% of every second.**
- **Measure PACING, not rate, whenever anybody says "choppy".** An average cannot see a hitch: ten
  frames lost inside one second still reads as 58fps. Attach `dev-scripts/bizhawk-hitch-meter.lua`
  — it is game-agnostic, standing rig, and reports frames over 20ms, frames over 33ms and the worst
  gap. It also reads `client.get_approx_framerate()` beside `os.clock`, because `os.clock` measures
  only the Lua process's own CPU: a big gap there blames a script, while a low emulator framerate
  with small gaps means the cost is elsewhere and no adapter tuning will find it.
- **Print raw values, not interpretations.** `G.2c=c7` is what let the paused bit (`0x40`) be
  spotted after the fact. A field printed as `paused=false` by code that had the polarity wrong
  would have hidden it forever.
- **Collapse to transitions when reading.** 60fps of identical lines is unreadable; the answer is
  always at the changes. One `awk` pass that prints a line only when the interesting columns differ
  from the previous line turns 6000 lines into 30:

  ```
  awk '{k=$3" "$5" "$9; if(k!=p){print; p=k}}' animtrace.log
  ```

- **Keep the timestamp/frame number in every line**, so a symptom the user describes by *when* it
  happened ("at the start and at the end") can be found without guessing.

**Keep the trace when it is done.** This one is now behind its own off-by-default flag rather than
deleted, because the next states in the queue (bikes, surfing) are the same class of problem. But
give it **its own** flag — it was originally written inside the two-renderer comparison flag, which
is the intended dev default for judging a drawn tier, and leaving per-frame file I/O in there would
have taxed every future comparison with a diagnostic nobody asked for.

## Measure what is DRAWN, not the fields that feed it — 2026-08-19

**The trap.** A ghost visibly flicked 8px sideways while **every readable struct field was
correct on every frame**. Position, offset, animation number, frame index: all right, all stable.
The fields were not lying — they were just not the thing being drawn.

**The fix is to read the hardware's own draw list.** On GBA that is OAM at `0x07000000`: 128
entries, 8 bytes each, `attr0` at `+0`, `attr1` at `+2`, `attr2` at `+4`. Screen Y is
`attr0 & 0xFF`, screen X is `attr1 & 0x1FF`, and the tile number (`attr2 & 0x3FF`) is what lets you
find *your* sprite among all of them — match it against the tile range the adapter allocated.

With that column added, the answer appeared immediately: `pos2` held constant at `8,0` across
frames where the OAM x went `144, 136, 144`. That is a **phase** error, not a value error, and it
is not visible in any amount of struct reading. See `pitfalls.md`, "A script's writes land between
frames".

**The general rule:** every engine has a stage where its own state stops being authoritative and
the hardware's takes over — a draw list, a command buffer, a submitted frame. When the numbers all
agree and the screen disagrees, that stage is where to look, and it is usually one read away.

### Two traps that come with this, both hit the same day

- **A dud instrument reads as a finding.** A checksum of the ghost's VRAM tiles (`0x06010000`)
  returned `00000000` on every frame. Taken at face value that says "the pixels never change" — a
  dramatic and completely false conclusion. The *reader* was broken (that region did not read back
  through the domain in use). **Before believing a measurement, check that the instrument can
  produce a non-trivial result at all.** A reading that is constant, zero, or suspiciously tidy is
  a claim about your probe until proven otherwise.
- **A measurement carries the conditions it was taken under.** An earlier note in this project read
  "the engine advances a ghost's animation fine — measured `3/0 → 3/1 → 3/2`". That observation was
  genuine, but it had **not** been taken on a paused idle ghost, which was the case under
  investigation. Two wrong fixes were justified by it. Record the conditions with the number, and
  when a measurement contradicts a symptom, suspect the *scope* of the measurement before
  suspecting the symptom.

### The capability note: you may not be limited to frame boundaries

A script that can only act between frames cannot keep a value in lockstep with something the engine
updates *inside* a frame. That reads like a hard limit and is not one: BizHawk exposes
`event.onmemoryexecute`, which fires when the CPU reaches an address. Hooking the engine's own
pipeline point — here `BuildOamBuffer`, after animations are final and before OAM is built — put
the adapter's write at exactly the place the game's own code does the same job, and that is what
made the result identical on screen rather than merely close.

Finding the address needs a symbol source, not a guess (for Emerald, this project's own
`pokeemerald.map` — see `environment.md`), and it should be **gated on the ROM you measured it
on**: a patched build relocates code, and a hook at a stale address is a hook into whatever now
lives there. This is the same *check-what-tools-you-actually-have* point made earlier in this file,
and it cost several cycles of trying to fix a phase error by correcting values.

## Diff what you BUILT against what the game BUILT — 2026-08-19

**When to reach for this.** Any time the adapter constructs one of the engine's own objects — a
sprite, an actor, an entity, a component — from a description rather than by calling the game's
constructor. That covers most of what a spawned ghost is made of, and it has a failure mode that
no amount of re-reading your own code will show you.

**The trap.** A description in ROM (a sprite template, a class default, a prefab) says what a thing
*is*. The **constructor** adds what it *computes* — derived sizes, anchors, back-links, defaults —
and those fields exist nowhere in the description you copied from. So the object is correct in
every field you thought about and wrong in the ones you did not know existed. Emerald's surf blob
lost `centerToCornerVec`, which `CreateSprite` derives from the OAM shape and size; the blob then
drew from its corner instead of its centre and sat a tile down-right of its rider, with a cause
recorded as "unknown" for a day.

**The method, and it is mechanical.** Get a LIVE instance the game made itself — the player almost
always has one — and dump the same struct for both, side by side, every field. Then read down the
two columns for disagreements. In Emerald that was one probe and one line each:

```
player blob: ... pal=0 oam=003d 8068 c2c=240,240 sub=150 pos2=0,-3
ghost  blob: ... pal=0 oam=004f 8098 c2c=0,0     sub=150 pos2=0,0
```

`c2c` is the answer and it took no theory at all. **Do not diff against your expectations** — the
whole point is that the missing fields are ones you do not know to expect.

**Getting a live instance to diff against.** This is the part that needs planning, because some
states only exist while somebody is in them: no surf blob exists unless someone is already surfing.
Reach the state yourself (see "Or play to it" above, and "Edit the world instead of travelling to
it") and take the dump then. A probe that quietly reports nothing because the state never occurred
looks exactly like a probe that found no difference.

**Two things the same dump answers for free**, both of which would otherwise be guessed:

- **Which palette slot the thing actually resolves to** — read it off the live one rather than
  reasoning from a palette tag.
- **Its offset from whatever it is attached to.** Ours is right when the ghost-to-blob delta equals
  the player-to-blob delta; that is a comparison between two pairs, so it survives both sprites
  using different position helpers, which a single absolute number does not.

## Check a computed grid against the SCREEN, not against another computed value — 2026-08-19

**When to reach for this.** Any time adapter code converts between screen pixels and world/tile
coordinates -- placing a painted ghost, clipping to terrain, deciding what a peer is standing on.
An error of a few pixels there does not look like a coordinate bug. It looks like whatever rule
consumes the coordinate is wrong, and you will rewrite that rule several times before suspecting
its input.

**The failing check to avoid.** The natural self-test is to run something whose answer you know --
the player -- through the same conversion and compare. Emerald did exactly this, printing "the
inverse says (43,5), the object says (43,5)" every second, and it agreed on every sample while the
grid was 8px out. Both sides were built from the same origin, so **they shared the bias and the
check could only confirm they shared it**.

**The check that works: find a LANDMARK whose appearance is unambiguous, and compare the grid's
prediction against the actual pixels.**

1. Pick a tile whose graphics you can identify with certainty from its data -- ideally one that is
   uniform, so there is no doubt which pixels are it. In Emerald that was a metatile built from
   four copies of a single water tile: it must render as 16 pixels of one flat colour.
2. In ONE frame, take a screenshot and log the grid's predicted screen rectangle for that tile.
3. Read the pixels. If the flat-colour run starts 8px from where the grid says, the grid is 8px out
   -- and you now know the size and the direction of the error, which is usually enough to name the
   term responsible.

**Print the ids and their predicted screen ranges together**, e.g. `x80..95:id=184  x96..111:id=161`,
so the comparison is a glance rather than arithmetic. Take the screenshot from the same code, in the
same frame -- the earlier attempt at this used a separate probe on its own schedule and compared two
different moments.

**What to suspect when it IS out.** Almost always a term that belongs to the sprite you anchored on
rather than to the world: an animation offset, a bob, a frame-centring vector. See `pitfalls.md`,
"A world-space anchor built from a SPRITE carries the sprite's own terms" -- and note that such a
term can be correct for every test you have ever run and wrong only for one graphic.

## When every field agrees and the screen does not: compare the PIXELS

Found live on Emerald, 2026-08-20. A ghost sat in the wrong pose while every struct field said
otherwise -- the same animation number, the same command index, unchanged for 180 frames, matching
the player exactly. The adapter already had a per-frame trace comparing those fields *and* the
hardware OAM entries, and it reported agreement the whole time.

The layer nobody was reading was the tiles. On this engine a character's current frame is COPIED
into its own sprite VRAM when the animation advances; a character standing still advances nothing,
so an object can report a pose it is not displaying. Any engine that copies frames on demand rather
than pointing at them can do this.

**The probe is trivial and worth writing early:** find both sprites' tile ranges, read them, count
the bytes that differ (`adapters/bizhawk/pokemon/emerald/probes/posediff.lua`). It said 120 of 512
while every field matched.

**Two rules came out of it, both general:**

- **Log on CHANGE, not on a timer.** The first version sampled once a second and could not show the
  ORDER things happened in. "Wrong right after stopping, right again after a turn" is a sequence,
  and a sample cannot see one. Writing a line only when the picture changes keeps the log short and
  catches every transition.
- **A fix that measures correct can still be overwritten a frame later.** The frame copy read
  `differing: 0` and was then undone by the engine's next step, because a peer stopping does not
  stop the ghost -- it is still catching up. Check that the thing you wrote is still there once
  everything has settled, not only at the moment you wrote it.

## A scripted ride must be able to see

Found the expensive way on Emerald, 2026-08-20: several probes that drive the player counted tiles
and nothing else. Across one session they rode into a trainer, drifted across the map, and finally
parked the player in a gap in a fence holding a direction against it -- which logged nothing for the
rest of the run and cost a whole measurement pass. Each was fixed with a timeout, which stops the
damage without removing the cause.

**Before writing a probe that drives the character, find out whether the game will tell you what is
walkable.** On a tile-based game it usually will, and cheaply -- Emerald keeps collision bits in the
same map-grid word the probe already reads for the metatile id, so "can I go there" costs one read.

**Check BOTH sources.** The map says what the terrain allows; it does not know about characters. An
NPC standing in a doorway blocks it while the tile underneath reads perfectly free, and NPCs move.
The object array is the second lookup.

**Verify the layout, do not assume it.** Dump a grid around the player, print it as characters, and
compare it against a screenshot of the same moment. If the walls in the picture are the walls in the
grid, the layout is confirmed; a bit layout taken from memory is exactly the kind of plausible-
looking wrong that this project has a hard rule against.

**Then give every driving probe two things:** a walkability test before it commits to a direction,
and a timeout so a leg that cannot finish still ends. The timeout is the backstop, never the plan.

## Three probe rules from the mount/dismount pose war (Emerald, 2026-08-20)

The full story is in `agent_docs/pitfalls.md`; these are the parts every future probe should
inherit. A wrong-pose bug survived six fixes because three instruments were wrong before the code
was.

**Compare a sprite's pixels against the ROM, never against another live sprite.** A character that
draws through a subsprite table parks its struct's own tile entry — reading its tileNum gives 0 and
"its" pixels are whatever lives there. The trustworthy comparison resolves (animation, index)
through the graphic's own anims table to a ROM image and diffs against that: it owes nothing to
either sprite, and it splits "the copy did not land" from "we asked for the wrong frame" in one
reading (`adapters/bizhawk/pokemon/emerald/probes/posediff.lua`, the `ghost vs ROM` column).

**A dev-loader reload is part of the experiment.** Reloading the adapter respawns its ghosts, and a
respawn re-derives exactly the state a transition bug corrupts — so "add the screenshot probe, then
look" photographs a reset ghost, correct every time, while the user stares at the wrong one. Load
everything the test might need in ONE control-file write before the user acts, and change nothing
until the reading is taken. The user's own screenshots outrank any the agent takes after a reload.

**When the question is "how much later", answer in frames, with a screenshot burst.**
`dev-scripts/bizhawk-screenshot-loop.lua` at interval 1 across a driven transition, then hash a
fixed block per figure per frame and print the frame where each changed. One run turned "still
slower" into "7 frames, 6 of which are the sender's hold" — an argument nothing verbal was
settling. Point `MESHGHOST_SHOT_DIR` at the scratchpad; 400 PNGs do not belong in the repo.

## Two instruments from the vanishing-hat hunt (Emerald, 2026-08-20)

**Dump the art itself when a sprite looks wrong** (`probes/framedump.lua`): decode a graphic's
animation frames straight from ROM through its own anim table and write them as image files. It
answers "is the art what I think it is" in one look — here it retired both an art theory and a
decode theory in a single dump, and measuring each image's true top row (row 9) later converted a
suspicious user observation ("the ruler sits 1.5 heads above the sprite") into a NORMAL reading.

**Give the user a ruler when they are the only sensor.** The drawn tier is invisible to
`client.screenshot`, so when only the user can see the defect, paint a reference line at the
coordinate under test and let them describe the relationship. One magenta line at the frame-top
row split "painter puts the box in the wrong place" from "the box is right and pixels die later"
without a single log line. Remove it the moment it has answered.

And the meta-rule the whole hunt kept teaching: **intersect the user's qualifiers before
instrumenting anything.** "Drawn only" names the tier; "downwards only" names the screen band a
trailing follower occupies; the two together pointed at the one subsystem that clips that band on
that tier. Six instruments measured innocent before that intersection was taken seriously.

## Identical results across conditions are a probe bug until proven otherwise (Emerald, 2026-08-20)

A probe ran six conditions -- the same wheelie action issued in each of four directions, plus two
control cases -- and every one of them finished in **exactly eleven frames**. That looked like a
clean negative result and was written up as one, in a comment that then justified a real behaviour
change. It was a bug: the table carried a per-condition action id, and the line that issued the
action ignored it and re-derived the id from the object's own facing. All six conditions issued the
same id. The question the run was built to ask was never asked.

**The rules that come out of it:**

- **A table of conditions needs one line proving each condition is DIFFERENT.** Log the value you
  actually wrote, not the one you meant to write -- the same reason nothing here logs the variable
  it just set as proof. One extra field in the header line (`issuing %02X`) is the whole fix.
- **Suspiciously identical outcomes are a signal, the way two guessed fixes failing the same way
  are.** Real conditions vary by a frame or two; six runs agreeing to the frame means they were the
  same run six times.
- **A negative result deserves the same scepticism as a positive one.** "Nothing reproduced the
  hang" closed an investigation and re-enabled behaviour that had been dropped for a reason. If a
  result is about to change what ships, re-read what the probe actually did before it does.

## Per-peer logging cannot see a collision BETWEEN peers (Emerald, 2026-08-20)

Two peers ended up sharing one engine object slot, and every line the adapter logged about either
of them was correct. It has to be: each peer's log describes what that peer asked for, and both
asks were reasonable. What was wrong lived in the relationship between them, which nothing logged.

- **When a symptom looks like one thing behaving impossibly, enumerate the engine's own array
  instead of reading your own bookkeeping.** A single slot alternating between two complete,
  internally-consistent states every few frames is the signature of two owners, and it is obvious
  the moment the raw array is watched.
- **Log the ASSIGNMENT, not just the behaviour.** Which peer holds which slot is the fact that was
  missing; without it the diagnosis was inference from position data. A one-line audit that names
  two peers holding the same resource costs nothing and turns a future occurrence into a sentence.
- **This generalizes past slots.** Anything allocated by asking the engine "is this free?" —
  sprite slots, VRAM tile ranges, an object array — has a window where your own claim is invisible
  to that question, and a second consumer will eventually land in it.

## Price a suspicion before fixing it — the fps A/B harness (Emerald, 2026-08-20)

The lag hunt produced a reusable method, and its two instruments earned their keep in one session:

- **A scripted ride + `client.get_approx_framerate`** (`probes/fpsride.lua`): drive the same route
  every run, record avg/min/max. An impression cannot be A/B'd; the same route twice can. The
  emulator's own framerate is the instrument, because `os.clock` in Lua measures only the script's
  CPU and misses everything the host and core pay (it read 0.44ms while the user felt lag).
- **A whole-frame + per-section Lua profiler behind a flag** (`MESHGHOST_EMERALD_PROFILE`):
  os.clock around the frame and around each major block, reported once per 300 frames with the
  window's WORST frame. The worst frame is the number that matches "chugging" — 217ms spikes at an
  average of 3ms.
- **What each can and cannot see, and why both are needed**: the profiler prices the script; the
  ride prices the world. A big profiler number is the script's fault. A SMALL profiler number with
  a low ride number means the cost is in the emulator core or another script — which is exactly
  how the execute-breakpoint suspect was exonerated (52.0 fps without vs 52.6 with) instead of
  "fixed".
- **Run a bare control on the same route** before believing any number: this machine's emulator
  dips to 37 with nothing loaded. Without the control, that dip gets attributed to whatever was
  loaded at the time.

## Read BOTH characters on ONE line — the parity probe (Emerald, 2026-08-21)

A ghost is always a copy of something, so nearly every question about one is really a question about
a DIFFERENCE. A probe that follows the ghost alone cannot answer it: every field looks plausible on
its own, and the reader supplies the missing half from memory.

`probes/facing_probe.lua` is the shape worth copying. Each frame it reads the player and the ghost
from the same fields at the same instant and prints them side by side, logging only on change:

```
f=240  P face=up act=75 anim=21/0 paused=0 hflipOAM=0 hflipSpr=0 | G face=right act=77 anim=21/1 ...
```

Three properties, each of which earned itself in one session:

1. **Both halves, same line, same instant.** The bug was three frames of the ghost travelling one
   way while wearing the artwork for another. No single-character trace can show that; two traces
   read side by side hide it in the interleaving.
2. **The DRAWN state, not the logical one.** An object's facing field is not what a character looks
   like — the sprite's animation number is, plus the hardware flip. Two fixes were reasoned out from
   the object field while it was already correct. Print what the screen is built from.
3. **A frame number.** It turns "seems slow" into a count, and — more importantly — lets a CONSTANT
   offset be told apart from a GROWING one. The first is a pipeline; the second is a bug. Here it
   showed eight frames of the ghost sitting idle doing nothing, which no amount of watching could
   have separated from network delay.

**Find the subject by what it IS, never by an address.** The probe locates the ghost by scanning the
object slots for the borrowed local id, so it keeps working across adapter reloads and does not read
a single adapter global. A probe that depends on the code under test fails at the same time as it.

## "It is the network" is a hypothesis, not an explanation (2026-08-21)

Latency is the most available excuse in a multiplayer project: it is always plausible, always
partly true, and costs nothing to say. It closed an investigation wrongly here — a turn that
"waited for the wire" turned out to be the adapter idling for eight frames, with a measured wire
delay of zero.

**The test is cheap.** Stamp frames on both sides and count. A real network delay is roughly
constant and applies to everything the peer does; if one action lags while position does not, or if
the gap grows over a sequence, it was never the network.

**The user's rule is the better default anyway**: anything the player can do, a ghost must too, and
"impossible" means the mechanism has not been found yet. An explanation that ends in a shrug should
be treated as an unfinished investigation, not a result.

## Two ways to get ground truth out of a game that will not tell you directly

Both were found on Emerald, 2026-08-21, and neither is Emerald-specific.

### Diff two screenshots to isolate exactly what YOUR code draws

A Lua overlay does not appear in `client.screenshot()`, which is a real blind spot — but anything
you put in the game's own sprite/OAM data DOES. So:

1. screenshot with the adapter loaded;
2. drop the adapter through the dev loader;
3. screenshot again;
4. diff the two PNGs **host-side** (a PNG decoder is ~30 lines of Python — zlib plus the five
   filter types) and every differing pixel is something your adapter contributed.

That gives per-pixel answers the emulator's Lua API may not expose at all — on this BizHawk build
`emu.getscreenpixel` does not exist. It gave the exact row AND column of a single-pixel reflection,
which no amount of reading the code would have.

**Its limit, and it is a real one:** anything your code causes the ENGINE to create may outlive the
drop by a frame or persist through it, so it will not show in the diff. Check that what you are
isolating actually disappears when the adapter does.

**Diff several frames against EACH OTHER, too.** One diff answers "where is it". Diffing six
consecutive screenshots answers "what does it DO" — that is how a reflection's shimmer was measured
as *one pixel alternating between two columns*, which settled both its width and its motion in a
single step. A scaling or animation rule is a claim about behaviour, and behaviour needs more than
one frame.

### Compare your OAM entries against the engine's, field by field

If your adapter writes hardware sprite entries, the engine's own are sitting in the same buffer.
"Is our sprite the same as the game's?" is then a read, not a question for the user: dump both,
decode shape, size, position, priority, palette, flip and affine mode, and compare.

This retired a whole class of "it looks slightly off" in one line — ours came back byte-identical to
the engine's own reflection entry — and it is the fastest way to split "we are drawing it wrong"
from "we are drawing the wrong thing".

## Write breakpoints: the only instrument that sees BETWEEN frames (Emerald, 2026-08-21)

A defect that exists at RENDER time but never at the Lua tick is invisible to every per-frame
probe by construction -- struct dumps, OAM scans, VRAM-vs-ROM checks and allocation-bitmap dumps
all read clean while the screen shows garbage. The instrument for that gap is
`event.onmemorywrite` on the affected range: each write event carries the address and value, and
`emu.getregister` the CPU state.

What a day of using it taught:

- **Register one address per tile (stride 32), not every byte** -- a breakpoint can push the
  emulator core onto a slow path, and sampling catches any multi-byte copy anyway.
- **PC inside the BIOS (0x2A0) means a CpuSet/LZ77 call; LR is ALSO banked to the BIOS there**,
  so registers cannot name the game-side caller. Name the writer by its DATA instead: search the
  ROM for the written values at the observed stride. No ROM match means a RAM source
  (decompressed graphics, heap frame buffers).
- **Budget the event count and stamp `emu.framecount()` into every line** -- the interesting
  window is a handful of frames, and correlating with screenshots requires one shared clock
  across probe lines, log lines and screenshot filenames.
- **The engine's sprite-copy queue executes at VBlank, one frame AFTER the request** -- so a
  sprite despawned this tick can still write its tiles next frame. Tiles freed at despawn and
  re-claimed in the same tick get the dead sprite's frame stamped over the new owner's load.
  If a despawn frees tile ranges, defer the free by a few frames.

## When one renderer of several is already right, that IS the bisection (Emerald, 2026-08-21)

An adapter that draws a peer more than one way has a free control group, and the cheapest thing to
do with a defect that appears on some copies and not others is to ask **what the correct one is
reading**. On an ice slide the hardware tier held the pose while the engine-driven and painted
copies both animated: the correct one consumed the peer's animation state straight off the wire,
and the two wrong ones each RE-DERIVED it. Re-derivation is where a state gets dropped, so the
answer was "carry the missing field", found in minutes and without a single guess at a fix.

Ask it before reaching for any instrument. The negative case is just as informative: a defect on
ALL copies is upstream of every renderer, which means the wire or the sender.

## Drive the state with a script, and log both sides on ONE line (Emerald, 2026-08-21)

A defect that only exists during a specific movement is worth reaching mechanically rather than by
hand: a ~60-line probe of fixed phases (`settle`, press LEFT, coast, press RIGHT, coast) driving
`joypad.set`, logging the player's object event and every ghost's **on the same line, every
frame**. It made the ice-slide diagnosis a single read — same action id, same tile behaviour,
`disableAnim` 1 against 0 — and it is re-runnable after each fix, which is what turns "looks
better" into a number.

Two things that made it work, both worth copying:

- **Log the fields you have not formed a theory about yet.** The line carried the metatile
  behaviour, both animation indices, the pause bit, the direction pair and every bit of the flags
  byte. The flag that mattered was one nobody had suspected, and it was already in the output.
- **Re-run it after the fix and diff the same column.** A fix that moves the number by 15% reads
  by eye as "hmm, still a bit off" — indistinguishable from "no change" — and is a WRONG fix, not
  a partial one. One such nearly shipped in this session (see `agent_docs/pitfalls.md`, the glide
  floor): the corrected version moved the same column by 2.5x.

**A caveat the runs taught.** A scripted drive moves the player, so consecutive runs start from
different places and can quietly stop exercising the thing being measured — one run spent most of
its frames pressed against a wall. Log a state the phase depends on (here the tile behaviour under
the player) and check it before reading the result.

## Read the engine's own copy when the register is write-only (Emerald, 2026-08-21)

Several GBA display registers are write-only and return garbage when read — `WIN0H`, `WIN0V`,
`BLDY` among them — while their neighbours (`DISPCNT`, `BLDCNT`, `BLDALPHA`, `WININ`, `WINOUT`)
read fine. A register dump therefore mixes real values with convincing noise, and nothing marks
which is which.

The live value usually exists in RAM anyway, because the engine has to keep its own copy to write
each frame: a per-scanline effect keeps a buffer plus a small descriptor saying which register it
targets and whether it is running. Read those instead. It is also strictly better than the
register would have been — a per-scanline effect has 160 different values and the register only
ever holds the current line's.

**Check a register's read/write status before building an argument on a dump**, and prefer the
engine's own state to a hardware read whenever both exist.

## Your own ghost is indistinguishable from the player in any buffer that records APPEARANCE

**Found on Crystal, 2026-08-22, after four fixes reasoned from the code had each failed on screen.**

An adapter that learns by observing the player — "read what the engine drew for the character and
copy that arrangement" — has to establish **which** character it is reading. A ghost built to look
like the local player is, by construction, identical to them in every buffer that records what
things look like rather than who they are: same sprite id, same tile base, same palette. So a frame
captured from the ghost decodes as perfectly valid *player* data, arranged for whichever way the
GHOST happens to be facing.

**Why it is nastier than an ordinary wrong-object bug:**

- **A range or sanity check does not catch it.** Crystal's first fix rejected entries whose tiles
  fell outside the player's sprite — which correctly caught a *different* character, and could not
  see the ghost at all, because the ghost wears the player's own tiles.
- **It needs the ghost to exist and to differ.** The contamination arrived ~2,000 frames into a
  session, once a ghost was up and facing elsewhere. Before that the tier was visibly correct, so
  the report was *"it was working at first, then it started swapping"* — which reads as a lifetime
  bug in the adapter, not as a wrong read.
- **A cache makes it permanent.** If what is learned is kept (first N samples win, never cleared),
  one bad sample poisons that case for the session and **re-rolls on every reload** — so the fault
  appears to move between cases and to be a regression after every unrelated change.

**What to do:**

- **Validate against what the destination MUST be, not against what the source looks like.**
  Crystal derives which view a facing may wear from the sprite format and refuses anything else, so
  contamination cannot win regardless of arrival order. A rule that instead *learns* the correct
  answer from the first sample is only as good as that first sample — Crystal shipped that version
  too, and one bad first sample locked a facing to the wrong view and then enforced it.
- **Ask whether the identifying property is shared.** Sprite id, tile base and palette are all
  shared by design here. Position is not, and neither is the object slot — prefer those.
- **Learn while no ghost exists if you can.** The cheapest version of this is to do the observing
  before the first peer is rendered.

**Generalises past emulators.** Any adapter that clones the player and then reads back "the
player's" animation state, bone transforms, material parameters or draw calls has the same
exposure. The question to ask of any observed data is not *"is this valid?"* but *"could my own
ghost have produced this, and would I be able to tell?"*

## An input-driving probe is not a passive instrument — never leave one loaded

**A probe that presses buttons is a second player.** While it is loaded it is holding the
controller alongside whoever else is at the keyboard, and the two fight: the character stutters,
walks off on its own, or refuses to go where it is told. In a LOOPBACK session that is worse than
it sounds, because the ghost is the local player echoed — so a probe jittering the player jitters
the ghost, and it presents as a **rendering** fault in the thing being tested.

**Found live 2026-08-22 (Crystal).** A door-walking probe was left loaded while the user tested by
hand. When they reported the ghost wiggling, the probe was a real suspect and cost a round of
diagnosis. It was innocent that time — the wiggle was a genuine bug — which is the part worth
keeping: **an uncontrolled instrument does not have to cause the fault to cost you the
investigation.** It only has to be a plausible explanation you cannot rule out cheaply.

**The rules:**

- **Unload it the moment the driven run ends**, the same way a per-frame trace comes off when it
  has answered its question. "Off by default" is not enough for something that moves the character;
  it has to be off *between* runs.
- **Never hand the game back with one loaded.** If the user is going to look at anything, the
  controller is theirs alone.
- **Say so in the script itself**, loudly, at load — not only in a doc. A driving probe should
  announce that it has the controller, because the symptom (a character that will not obey) looks
  nothing like "a script is loaded".
- **When the user hands the controls over explicitly, driving is the right move** — it is far
  cheaper than asking a person to repeat a crossing forty times. The rule is about who is holding
  the pad, not about whether driving is allowed.

**The general form, and it is the input-side twin of the cost warning above:** a probe that only
*reads* can bias a measurement, and a probe that *writes input* can author the behaviour being
measured. Ask of any instrument: could this have produced the thing I am about to explain?

## Six ways an instrument lied in one session — and how each was caught (Crystal, 2026-08-22)

One session produced six separate false readings, each of which changed a decision, and two of
which caused work to be reverted or shipped on a wrong justification. They are collected here rather
than spread across the fix entries, because the shape repeats and the cost was far higher than any
of the bugs being hunted.

**1. The probe inherited the rule it was built to test.** The adapter identified a character's sprite
by "tile offset from its own base must be under 12", and the first probe written to audit that used
the same rule. It therefore agreed with the adapter perfectly — and both were wrong, because a
sprite's STEPPING frames sit at offset 0x80 and up. **A probe that shares a premise with its subject
confirms the premise.** The fix was to widen the probe's rule and print how many samples each rule
would have discarded; the difference was 320 frames out of 640.

**2. Sampling every other frame halved a measured rate.** A trace gated on `frames % 2 == 0` showed a
value advancing 2px per sample and it was reported as "1px per frame". It moves 2px every two
frames — the same as the value it was supposed to be replacing — so a change justified by that
reading did nothing at all, and was described to the user as a fix. **Write the sampling interval
into the output line**, or a rate read off it is a guess.

**3. Float keys silently dropped 99% of the samples.** A histogram bucketed by a distance that turned
out to be a float (an interpolated position), while the report looped over integer keys. It printed
`4px:2` from 224 recorded movements. **Round to the bucket key at insert time**, and print the total
count beside the distribution so the two can be checked against each other — the discrepancy is
invisible if only the buckets are shown.

**4. A quiet window was read as a frozen value.** A wire trace reported "1 distinct peer position this
second" and it was taken as proof that a field was not being sent. The driving probe simply pauses at
corners, so a stationary second had been sampled. **A whole change was reverted on that reading.**
Report the count of UNCHANGED samples beside the changed ones: "nothing moved" and "nothing was
sampled" must not look the same.

**5. Two instruments disagreed and neither was checked.** A cumulative counter reported the ghost on a
stepping frame for 214 of 507 walking frames — the engine's own proportion — while another readout of
the same thing showed it never stepping at all. That contradiction was noticed and work continued
anyway. **When two instruments measuring one quantity disagree, stop: at least one is measuring a
different moment than it claims, and until that is settled neither can support a conclusion.**

> **Settled 2026-08-23, and the data never disagreed.** There were *three* readouts, not two, and the
> one that read zero was a third: a per-frame local, printed once a second, in the tiers summary
> line. The character-per-frame cadence trace was fine all along — its uppercase bursts line up with
> the player's in the same log. A ghost walks about 1% of the frames in a run, so one frame sampled
> per second finds a stepping ghost roughly **twice in 441 samples**, which is what it found: 439
> zeros read as "never". **Being suspicious of the pair while a third instrument was the liar cost a
> whole session's judgement of the stride** — and the comment two lines above that counter already
> described this exact mistake, about the counter it had replaced.

**6. The counter measured the renderer's INPUT and called it the output.** The same stepping counters
tested a step-progress band — the value that *feeds* the frame choice — while three separate gates
(a per-step latch, a turn suppression, and "is this peer moving") sit between that band and the image
on screen. So the band can read a healthy 45% while the ghost never once steps, and the two readings
are not comparable even when both are right. **Count the variable the renderer actually acts on**, at
the point it acts on it — here the latch that selects the stepping view — and keep the input count
beside it on the next line, because the *gap* between the two is the only thing that separates "the
peer sent nothing to step on" from "the renderer refused to draw it". Both look like a ghost standing
still. Fixed the same day by counting at the latch and logging the three refusal reasons separately.

**The common thread**, and the rule worth carrying: **every one of these was cheap to catch and
expensive to miss.** Each would have been exposed by printing one extra number — the discarded
count, the sample interval, the total, the unchanged count, the other instrument's value. So:

> **An instrument reports its own coverage, not just its findings.** How many samples it took, how
> many it discarded and why, and over what window. A probe that prints only what it found cannot be
> distinguished from a probe that found nothing because it was looking in the wrong place.

## A uniform histogram can BE the fault (Crystal, 2026-08-23)

The most expensive wrong reading of the drawn-ghost stutter hunt was not a probe that found nothing.
It was a probe that found a **perfect** result.

A histogram of the ghost's painted movement, one entry per frame, read `2px:59` — every moving frame
exactly 2px, no odd values, no outliers. That is what "fixed" looks like. The user, watching the same
build: *"left/right also looks the same/bad i think"*.

Both were right. The engine moves the world 2px every **other** frame. The ghost had been locked to
2px on a frame parity of its own, so it moved on the frames the player did not — and because the
camera is locked to the player, a ghost that moves when the player doesn't shifts 2px **relative to
the player on every single frame**. That is a shake, and its signature in a per-frame histogram of
relative movement is a flawless, uniform, single-bucket 2px.

> **A quantity that should sometimes be zero and never is has not been smoothed — it has been made
> to oscillate.** Before celebrating a single-bucket histogram, ask what the RIGHT distribution is.
> Two bodies moving together should read mostly ZERO relative movement, with the occasional step;
> uniform motion means they are never in agreement, which is the opposite of the goal.

Three rules came out of the same hunt, each of which cost an iteration:

- **Measure the engine's own quantum before matching it.** A ghost moving 1px a frame was built to fix
  a stutter and was *smoother than the game*: the background scroll moves 0, 2 or 4 pixels and never
  1, and the player's sprite does not move at all — the world scrolls past it. 1:1 fails from the
  smooth side as well as the jerky side. What looks like a lossy reading of a finer value (`(8 -
  STEP_DURATION) * 2`, always even) may simply *be* the value.
- **Quantise the position, not the time.** Timing quantisation needs a phase, a phase has to be
  guessed, and a wrong guess is anti-phase. Rounding the position onto the engine's grid needs no
  phase at all and cannot oscillate, because a monotone input stays monotone.
- **A phase must be released on a real stop, not on a momentary catch-up.** Latched at the start of
  each burst and cleared the instant the model was up to date, the phase re-rolled many times inside
  a long walk and once inside a short one — which presents as *"1 tile looks perfect... 4-5+ tiles
  starts to look really jittery"*. **A fault whose severity grows with the length of the action is
  something that REPEATS**, not a constant offset and not a rounding error; count the repeats.

### Two instruments this needed, both cheap

- **Split a computed position into its terms and histogram each.** The painted position is the
  ghost's own motion plus a player reference. Both axes ran identical code and only the vertical was
  wrong, so the difference had to be in the values — and the split said in one line that the ghost
  moved 0 or 1px while the reference moved 0 or 2px and never 1. A histogram of the finished
  position can never say which half carried the error.
- **Print the RHYTHM, not just the magnitudes — both bodies on one line.** Frames between successive
  moves, for the ghost and for the player: `player 2:91 | ghost 1:8 2:73 3:11`. Every positional
  instrument read clean at that point; the ghost was landing on the right pixels at the wrong times.
  The player's own figure has to be on the line beside it, because the engine is irregular too and
  the target is to match *its* irregularity, not to be metronomic.
