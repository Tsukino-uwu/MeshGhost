# Pitfalls — by lesson, in the order they were found

<!-- line-cap: none -- incident record; its control is the index in ../pitfalls.md plus preflight's coverage check, not a line count. Why: agent_docs/claude-md-cap.md. -->

The chronological half, and the larger one. These cut across hosts: the titles ARE the lessons,
which is why they are indexed rather than re-filed under themes. A lesson found in Emerald is here
so it is findable while working on Crystal — that property is the whole point, and any per-game
split would destroy it (decided 2026-08-25).

**New entries go at the end of this file.** Appending never touches an existing one.

**The index over every entry in every one of these files is [../pitfalls.md](../pitfalls.md).**
Add an entry here, add its one line there — `dev-scripts/preflight.ps1` fails if you do not.

## A Gold/Silver GameShark code run on Crystal writes into the object RAM MeshGhost spawns into (2026-08-18)

**Symptom (predicted, not yet suffered — recorded before it costs a session):** ghosts misbehave,
flicker, move on their own or vanish, shortly after a cheat is switched on for testing. Nothing in
the adapter changed, and the adapter looks like the culprit.

**Cause.** GB/GBC GameShark codes are `01 DD AA AA` — write value `DD` to address `AAAA`, stored
byte-swapped, with no encryption at all. Published Crystal code lists routinely give **two**
variants per effect and label the pair as one cheat, e.g. "Have All Badges: `01FF7CD5` / `01FF7DD5`
/ `91FF57D8` / `91FF58D8`". Those are not four lines of one code. Decoded against our own
hash-verified `pokecrystal` build:

| Code | Address | Symbol |
| --- | --- | --- |
| `91FF57D8` | `0xD857` | `wBadges` |
| `91FF58D8` | `0xD858` | `wKantoBadges` |
| `91018DD8` | `0xD88D` | inside `wTMsHMs` (`0xD859`, 50 TMs then 7 HMs, so HM03 = Surf) |
| `91XX93D8` | `0xD893` | `wItems` |
| `01FF7CD5` | `0xD57C` | **`wObject4Palette`** |
| `01FF7DD5` | `0xD57D` | **`wObject4Walking`** |
| `01XXB8D5` | `0xD5B8` | **`wObject5SpriteYOffset`** |

**The `91` variants are the Crystal codes and are correct. The `01` variants are the Gold/Silver
codes, and on Crystal they land squarely in `wObjectStructs`** — the exact array the Crystal
adapter spawns ghosts into. A tester who pastes "all four lines" gets a cheat that works (from the
`91` half) *and* silently scribbles on our object structs (from the `01` half), which presents as a
MeshGhost bug with a perfect alibi: the cheat did what it promised.

**Fix / rule.** For Crystal, use **only** the `91` codes. Any code list is untrusted input: decode
it (`01/91 DD AAAA`, byte-swapped) and look the address up in `pokecrystal.sym` before running it —
that is a ten-second check against an authoritative source we already build. If an address lands in
`wObjectStructs` (`0xD4D6`) or `wMapObjects`, it is the wrong game's code.

**Generalises.** The same "published lists mix two games' codes without saying so" shape applies to
any game with a close sibling release. The defence is not caution, it is the decode-and-look-it-up
step, which is cheap and mechanical.

## BizHawk accepts a GBA cheat code it cannot decrypt, and silently activates the garbage (2026-08-18)

**Symptom, seen live 2026-08-18.** `client.addcheat("F89BD08B ED8D449E")` returned without error,
and the Cheats dialog then showed **`2 cheats 2 active`** — with the code decoded to
**address `0000000E`, value `8B`, size Byte**. GBA EWRAM starts at `0x02000000`, so that is not an
address in the machine at all: BizHawk had not decrypted the code, it had parsed the hex.

**Two separate traps, and the second is the dangerous one:**

1. **"Accepted" is not "decoded".** `client.addcheat`'s own doc string says it adds a code *"if
   supported"*, and a `pcall` returning `true` only means the Lua call did not throw. Of six codes
   added, the four CodeBreaker-format ones (8+4 digits, e.g. `83000E48 1ED2`) were dropped
   silently — this build has a `GbaGameSharkDecoder` and no CodeBreaker decoder.
2. **A mis-decoded code is not inert — it is ACTIVE.** Two codes became live per-frame writes of
   an arbitrary byte to an arbitrary low address. Anything odd afterwards would have been blamed
   on the adapter, with the cheat sitting quietly in a dialog nobody had open.

**Rule.** Never conclude a cheat worked from the API's return value. Read the Cheats dialog and
check the decoded **address** is plausible for the machine (`0x02……`/`0x03……` on GBA), then remove
what you added. `dev-scripts/bizhawk-cheat-clear.lua` exists for exactly that.

**What to do instead on GBA.** Emerald's popular codes are GameShark v3 / CodeBreaker, both
encrypted and neither usable here — and the ones that look decodable often are not verifiable
either: `82005274 0YYY` resolves to `gHeap + 0x5274`, an unnamed heap offset whose meaning depends
on what is allocated at that moment, which is why such codes come with "enable one at a time, then
switch it off". Prefer writing the real structure through `gSaveBlock1Ptr`, whose offsets are in
the decomp and can be checked: key items at `+0x5D8`, badge flags at `+0x1270`. Contrast Crystal,
whose GameShark codes are unencrypted and land on named symbols — see the entry above.

## A spawned character renders a few pixels off its tile, forever (2026-08-18)

**Symptom.** A ghost sits slightly down/right of the grid the game itself snaps to. Its collision
is on the correct tile and it moves correctly — only the picture is offset, and the offset never
corrects itself. **Seen on both BizHawk adapters**: Crystal first, then Emerald 2026-08-18, where
the user recognised it immediately as "same issue as crystal had".

**Cause.** A spawned object's screen position is computed **once**, at spawn or teleport, from the
engine's own map-coords-to-screen formula. From then on the engine only applies camera *deltas* to
that sprite. So any error in the initial value is permanent — and the formula is **only exact when
the camera is at rest**. Place a ghost while the camera is mid-scroll (i.e. while the player is
part-way through a step) and the sub-tile remainder is baked into the sprite for its whole life.

**Fix.** Place only on a settled camera. In Emerald that is `gFieldCamera.x == 0 and
gFieldCamera.y == 0`, checked before both spawning and teleporting; if it is moving, skip the
frame and try the next one. The camera settles constantly, so the wait is invisible — and unlike
nudging the sprite by a few pixels afterwards, it fixes the cause.

**It came back on Crystal on 2026-08-19, because only Emerald ever got the check.** This entry
already said "seen on both adapters", and the fix was written down here — but Crystal's adapter
was never given the equivalent predicate, so the same bug was reported again by the user, this
time only when walking OUT of a building: leaving one drops the player into a scripted step out
of the doorway, so a ghost spawned there is placed mid-scroll, while walking in happens with the
world already at rest. Crystal's predicate is `wBGMapOffsetX % 16 == 0 and wBGMapOffsetY % 16 ==
0`, measured rather than assumed: a transition probe logged every object's real screen coordinate
beside what the adapter's formula computed for it, frame by frame across a map load, and the two
agree exactly on those boundaries and disagree by the sub-tile remainder off them. **The
transferable lesson is not about cameras** — it is that a pitfall recorded here is not a pitfall
fixed, and a lesson learned on one adapter has to be back-ported to its siblings deliberately
(`CLAUDE.md`'s `_template/` rule says the same thing about the template).

**The wrong fix, which is tempting and is a bandage.** Adding a compensating pixel offset to the
computed position. It "works" for the case in front of you, encodes one particular sub-tile
remainder as if it were a constant, and breaks the moment the ghost is placed at a different point
in the scroll cycle. If a correction like that ever ships, it belongs in the adapter's
`BANDAGES.md` — but the settled-camera check is available and is not a compensation.

**Generalises to any engine where a spawned entity's screen position is set once and then driven
by deltas.** The question to ask at the point of placement is not "is this value right?" but "is
the *state I am computing it from* at rest?".

## A spawned entity leaks once per zone crossing, but survives doors fine (2026-08-18)

**Symptom.** Ghosts pile up along a route as the player walks back and forth between two areas —
one left behind per crossing — while entering and leaving buildings behaves perfectly. Seen in
Emerald 2026-08-18, five deep in a screenshot.

**Cause.** The adapter identified its ghost partly by "the object's map matches the current map".
A **warp** (house, elevator) rebuilds the world: the engine clears every object, so the check
correctly reports death and a fresh spawn follows. A **connection** (route to route) changes the
map identity **without** clearing anything, so the same check reports a live ghost as dead — the
record is dropped, a replacement spawns, and the original stays active and untracked.

**Why it matters more than it looks.** Ghosts are solid. Leaked ones accumulate into a wall, so a
cosmetic-looking leak becomes "this route is now impassable".

**Fix.** Identify the entity by something the engine cannot forge and that does not mention
location — Emerald uses active + not-the-player + `localId == LOCALID_PLAYER` — and add a periodic
sweep that clears anything wearing that marker which the adapter is not tracking. Full reasoning
and the general form: `adapters/_template/README.md`, "The map changed and the world was rebuilt
are different events".

**The trap for testing:** each failure hides in the case the other one exercises. Passing a
door/elevator test says nothing about a seamless boundary, and vice versa. Test both, deliberately.

## A menu's contents are not fixed, and neither is its cursor (2026-08-18)

**Two separate assumptions, both wrong, both found scripting Emerald's bag on 2026-08-18.**

**The cursor is remembered between openings.** The first attempt pressed `Start` then `A`,
expecting the first entry — and got **EXIT**, because an earlier run had left the cursor at the
bottom. A menu opened twice in a session does not start where it started the first time. Drive it
to a known end (hold one direction past the end of the list) and count from there, or verify with a
screenshot before committing to a press.

**The ENTRIES themselves change with game progress.** The user, on seeing the sequence:

> *"menu's can sometimes include more/less things, similar to how a new save don't have your
> pokemon/badge view for example... don't assume its 'always the same'"*

The save being tested opens `BAG / <name> / SAVE / OPTION / EXIT` — no POKéDEX and no POKéMON,
because neither has been obtained yet. A later save has both, so **every index below them shifts by
two**. A sequence of button presses tuned against one save silently selects the wrong thing on
another, and "wrong thing" can be SAVE.

**So a scripted menu route is save-specific unless it is written defensively:** navigate to an
extreme rather than counting from an assumed top, screenshot at each step while developing it, and
treat the resulting sequence as valid for the save it was written against.

**And the action can be refused for reasons that have nothing to do with the menu.** The sequence
above reached `SUPER ROD -> USE` correctly and the game answered *"DAD's advice... there's a time
and place for everything"*. That is Emerald's generic **"you cannot use that HERE"** — the user:
*"whenever a thing is not usable in that specific location... for example trying to fish without
water, or riding a bike indoors"*. It is a **location/context** refusal, not a story gate, and the
first version of this entry guessed it was progress-related, which is exactly the kind of plausible
wrong explanation that outlives the session that wrote it.

**What that message actually tells a probe:** the route was right and the *precondition* was not.
For fishing it means no fishable water in front of the player — which, in this session, meant the
tile edit had not produced what it was assumed to produce. Read the game's own words before
adjusting the button sequence; a refusal is a specific answer, not a generic failure.

## An empty log reads exactly like "the game did nothing" (2026-08-18)

**Symptom.** A probe's log contains its header and one line, or stops growing partway. The obvious
reading — "the thing I am testing did not happen" — is wrong often enough to be dangerous, and it
sends the investigation to the game instead of to the instrument.

**Four causes seen in a single session (2026-08-18), all producing identical output:**

1. **The probe measured too early.** A screenshot fired a frame or two after the loader started it,
   before the adapter had connected — producing three convincing pictures of a game that had no
   ghost in it yet, and a debugging session aimed at a rendering bug that did not exist.
2. **The probe never loaded.** A backslash lost through a shell heredoc left an invalid Lua escape,
   so the file was rejected. Its empty log was read as "fishing produced no data".
3. **The emulator was paused.** BizHawk pauses while any of its own menus or dialogs is open, so
   `emu.frameadvance()` never returns, the dev loader stops polling, and every attached script
   stops ticking. Nothing errors; everything simply stops.
4. **The same misreading, repeated** an hour after (2) had been written up — because the fix was
   documented rather than made habitual.

**The fix, and it is cheap:** before drawing any conclusion from quiet output, get **positive
evidence the instrument is alive** —

- the loader log says `loaded <script>` (not `LOAD FAILED`),
- the log file's size or timestamp is **increasing**,
- a frame counter in the output is **advancing**.

**Never conclude from the absence of a symptom.** A dead probe and a quiet game are
indistinguishable from the outside, so the question is never "did anything happen?" but "is this
thing still running?" — and that has an answer you can check.

## A verification rule that reports clean while the thing it checks is broken (2026-08-18)

**Symptom.** `CLAUDE.md`'s mandated public-repo leak check printed nothing, as it had been doing,
while a personal username sat in `master` in a tracked file.

**Diagnosis.** The check was
`git grep -inIF -e 'C:\Users' -e '/home/' …`. `-F` makes it a *literal* match, so it matched a
**backslash** path only. The leak was `dev-scripts/rom-swap-test.lua`'s
`C:/Users/<name>/Downloads/<seed>.gba` — **forward** slashes, because BizHawk Lua wants them.
Committed 2026-08-11 in `03e0a8b`, invisible to the rule the whole time, and it leaked a
username, a home-directory layout, a handle and an Archipelago seed name.

**Fix.** Both slash directions in the check, now
`-e 'C:\Users' -e 'C:/Users' -e '/home/'`, and the file's paths moved to
`MESHGHOST_ROM_VANILLA`/`MESHGHOST_ROM_PATCHED` env vars with its log path derived from
`scriptDir()` (which also fixed a hardcoded `C:/dev/MeshGhost/` in the same file).

**The durable lesson is not "add a slash".** This is the shape `CLAUDE.md` already warns about
elsewhere — *a diagnostic can break the thing it measures, and then every reading agrees with
itself.* A clean run of a check that cannot see the failure mode is worse than no check, because
it is read as evidence. When a rule's whole value is "this prints nothing", prove it can print
something: run it against a known-bad string before trusting a clean result. **This one had
never been shown to fail.** Two of the three found-live cases arrived via pasted tool output;
this third arrived by being typed in a form the rule did not model.

**Fourth case, same shape, 2026-08-25 — preflight's "Leftover scaffolding" check.** It reported
*"no MeshGhost processes left running"* while two launcher shells from a session an hour earlier
were still open. Both were real: `cmd.exe /c run-core.bat pseudoregalia tcp` and
`… run-core.bat emerald auto 2`. The check looked for `meshghost*.exe` by name, and every
`run-*.bat` ends at a `pause` — so killing the binary leaves its shell parked forever, holding no
port and matching no name. Eight more accumulated during one four-adapter test pass. The modelling
error is the same one as the slash: the check knew what the failure looked like *the way it had
seen it*, and leftover scaffolding had only ever been met as a live process. Fixed by also
listing `cmd.exe` processes whose command line mentions `dev-scripts`. The reason to catch them is
not the handful of idle shells — it is that an idle shell is indistinguishable from a rig somebody
is still using, so the next session cannot tell what it is allowed to kill.

## Third time for the wrong-install-on-PATH trap — and it cost a capability, not just a build (2026-08-18)

**Symptom.** `agent_docs/testing.md` recorded that local `-race` **"does not work on this machine
and is not worth retrying"**, and `dev-scripts/run-gotests-race.bat` existed only to say so
politely. The race detector was treated as CI-only, which is why a relay race on 2026-08-16 had
to be caught by CI after a push.

**Diagnosis.** Two separate wrong conclusions stacked:

1. `gcc` on `PATH` resolves to devkitPro's MSYS2 copy, whose headers cgo cannot use
   (`stddef.h: No such file or directory`). Same trap as `cmake` (2026-08-13) and `cmd`
   (2026-08-17) — **the third instance in this repo.**
2. The real MSYS2 GCC 15.1.0 was then tested, failed with
   `runtime/cgo: cgo.exe: exit status 2`, and was written off as "Go's runtime/cgo doesn't build
   with it". **It builds fine.** Setting `CC` is not enough: cgo shells out to the compiler,
   which shells out to its own `as`/`ld` and reads its own headers, so its `bin` directory has to
   be *ahead of devkitPro's on `PATH`*. `run-gotests-race.bat`'s probe set `CC` only — so every
   candidate compiler failed identically, and the conclusion drawn was "no compiler works"
   rather than "the probe is missing a step".

That second part is exactly `CLAUDE.md`'s rule about **two guessed fixes failing with the
identical symptom being a signal, not bad luck** — two compilers, one symptom, and the common
factor was the harness, not the compilers.

**Fix.** The probe now prepends the candidate's directory to `PATH` before testing it. Verified
end to end 2026-08-18: with the `sess.timer` fix reverted, `-race` reports the race at
`relay/online.go:844`; restored, `go test -race -count=3 ./...` is clean across every package
including `internal/e2e`. Recipe and caveats: `testing.md`'s Race detector section.

**Lesson.** A negative capability finding deserves the same scepticism as a positive one, and it
ages worse: "we can't do X here" gets written into the docs, tooling gets built around the
absence, and nobody re-tests it. Cost here was every race being a push-and-wait round trip for
two days. **Treat "this doesn't work on this machine" as a dated claim, not a property.**

## Inferring what a game is MEANT to do, and "fixing" a non-bug (2026-08-18, TEVI)

**Symptom.** TEVI's peer ghosts stayed visible while the pause overlay was open. Reading
`Plugin.cs` alone, that looks like a leak — the local player is not in gameplay, so why is anyone
else's ghost on screen? A change was proposed to despawn them, which would have been a real visual
regression: peer ghosts staying up during the pause overlay is **wanted** behaviour, and the user
confirmed it as such the same day.

**Cause.** Two failures stacked. First, *intent was inferred from code* — the code says what
happens, never what should happen, and a cosmetic layer's correctness is a design question the
user owns. Second, the word **"menu"** was doing double duty: TEVI has a main menu *and* a pause
overlay, and the despawn path is deliberately gated on only one of them (`player == null`, which
`phases/phase6.md` records the pause overlay does not trigger). One sentence written as "on menu
return" covered two states with opposite required behaviour.

**Fix.** `CLAUDE.md` now carries both halves as a rule: **never assume what a game is meant to do
— ask**, before changing anything the player SEES; and **name the exact state, "main menu", never
bare "menu"**. `Plugin.cs`'s despawn call carries a comment saying which menu it means and what to
suspect first if a future TEVI build ever nulls the player on pause.

**The tell.** You are about to change a *visible* behaviour and your only evidence is what the
source implies. That is the same shape as "it ran without errors" — self-consistent, and untested
against the one person who decides what correct looks like.

## A probe global outlives the probe, and then looks exactly like a real bug (2026-08-19)

**Symptom.** A Crystal ghost looked like the player inside Elm's lab and like an NPC out in the
town. A perfectly plausible bug report — and a completely coherent one, which is what made it
dangerous: sprite 4 really is resident outdoors in New Bark and really is not loaded in the lab,
so the "bug" behaved consistently with a genuine appearance fault every time it was looked at.

**Cause.** A scratch script had set `MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE = 4` as a Lua **global**
for one experiment earlier. **`dev-scripts/bizhawk-dev-loader.lua` swaps SCRIPTS, not the
Lua state** — globals set by a dropped script persist in the emulator for the rest of its life. So
every later run in that emulator was still forcing every peer to `SPRITE_RIVAL`, and the fallback
(wear the local player's sprite when the peer's tiles are not resident) did the rest.

**Fix, both halves.** Clear the global in the session's own setup script rather than assuming a
dropped script took its settings with it — and, more durably, **any flag that changes what is on
screen announces itself in the log on every startup**, which is what `MESHGHOST_CRYSTAL_AP_TRY`
already did and this one now does too (`PROBE FLAG IN USE: ...`). One line in the log the session
is read from is the difference between a five-minute check and a plausible false report.

**Generalises.** `CLAUDE.md` already says a diagnostic can break the thing it measures. This is
its quieter cousin: a diagnostic can keep changing what everyone sees **after it is gone**, and
the reading it corrupts is not the probe's own — it is the next person's.

## Saying "no" once per peer per frame costs more than the work being refused (2026-08-19, Emerald)

**Symptom.** With synthetic peers (`meshghost-fakeadapter`) aimed at the map the player was
standing on, Emerald placed ghosts normally up to the engine's ceiling and then fell apart:
**24 peers dropped the emulator from 60fps to 3, and 36 peers to 1** — measured as frames counted
against the wall clock, not as a feeling. Nothing was wrong with the ghosts that DID spawn; the
game itself was simply unplayable while too many peers were present.

**Diagnosis.** `gObjectEvents` holds 16 entries shared with the map's own NPCs, so a town with the
player plus two NPCs fits exactly 13 ghosts. Every peer past that failed to find a slot — and the
failure path did two expensive things once per unplaceable peer **per frame**: it re-scanned both
the object and sprite arrays, and it called `console.log`, which in BizHawk is a GUI append. At 36
peers that is 23 refusals × 60 frames ≈ 1,400 console writes a second. The adapter was spending the
frame budget announcing that it had nothing to do.

**Fix.** Throttle the message to once per 5 seconds, and record the refusal in `spawnGate` so
`syncGhost` stops attempting spawns for the rest of that frame — the array cannot grow mid-frame,
so the first "full" answer is the answer for every remaining peer. Re-measured: 24 and 36 peers
both hold 59.7-59.8fps with the same 13 ghosts placed.

**The general shape:** a diagnostic on a failure path is priced per failure, and failures scale
with load while successes are capped. Anything that logs unconditionally where the count is
attacker- (or room-) controlled belongs behind a throttle from the start.

## ONE console line a second cost 7.4 fps — and the feature it was measuring cost nothing (2026-08-21, Emerald)

**Symptom.** The user, watching the Stage 1 hardware-sprite probe: *"i think its lagging constantly"*.
The ride harness agreed immediately — **50.7 avg / 25 worst against a 58.1 / 38 control**, reproduced
at 50.8 on a second run. The probe under suspicion does about **ten memory reads and three memory
writes a frame**, which is not a cost anyone would predict, so the obvious conclusion was that
writing OAM from Lua is expensive.

**That conclusion was wrong, and subtraction is what showed it.** Three switches, one run each, one
thing removed at a time — never a third guess:

| configuration | avg fps | worst |
| --- | --- | --- |
| ride alone (bare control) | 58.1 | 38 |
| ride + an EMPTY second script | 58.1 | 37 |
| probe, everything on | 50.7 / 50.8 | 25 / 27 |
| probe, **OAM writes removed** | 50.4 | 25 |
| probe, **the player scan removed** | 50.5 | 26 |
| probe, **the log line removed**, writes and scan still on | **58.1** | 37 |
| probe, log line sent to the FILE instead, everything on | **58.1** | 37 |

Removing the writes changed nothing. Removing the scan changed nothing. Removing **one**
`console.log` per second — about 33 lines over a 33-second route — recovered the entire 7.4 fps and
landed exactly on the bare-emulator control, with the hardware sprite still on screen.

**Diagnosis, and the part worth internalising.** `console.log` in BizHawk is **not a print**. It is
a text append into the Lua Console *window*, and its cost is a function of **what that window
already holds** — a long-running session has a large backlog, so the same call gets
more expensive the longer you work, which is exactly the shape that makes it hard to attribute. The
2026-08-19 entry above priced this at ~1,400 calls a second and read as a lesson about volume. It is
not about volume. **One line a second is already too many.** The threshold is far lower than any
reasonable person would guess, and it is not a fixed threshold at all.

**The rule, stated so it cannot be read as being about bursts.** Nothing on a per-frame or
per-second path calls `console.log`, in a probe or in an adapter. Split the two: a `say()` for the
handful of orientation lines at load, and a `log()` that only ever writes the file. That is what
`probes/oaminject_probe.lua` does now, and its header carries these numbers as the reason.

**And the quality bar this serves, in the user's words (2026-08-21):** *"there can't be any fps
drops like this in a shipped/release of the game, not allowed to pass quality wise by me. we have to
keep base fps"*. A release holds the platform's base rate — 60 for a GBA — measured against a bare
control run on the same route, because the machine has its own floor and without the control the
game's own map loading gets blamed for whatever was loaded at the time. **A drop of this size is a
blocker, not a rough edge**, and the fact that it came from a diagnostic rather than a feature makes
it worse, not more forgivable: it is a cost the user pays for nothing.

**The second lesson, free with the first.** A diagnostic can break the thing it measures, and this
is the cheapest possible illustration — the probe existed to price a feature and instead priced
itself, and it very nearly convicted OAM writing of a cost it does not have. When something
measures slow, subtract the instrument before believing the subject.

## Comparing two renderers: four ways to measure the wrong thing (2026-08-21, Emerald)

Pricing the new hardware-sprite tier against the painted one took **four invalid measurements**
before a valid one. Every single one was convincing at the time, and the user caught two of them
from the screen before any instrument did. They are worth having as a set, because they are traps
about COMPARISON rather than about either renderer.

### 1. The instrument cost more than the thing measured

A probe logging **one `console.log` per second** measured 50.7 avg fps against a 58.1 control. The
OAM writes and the sprite were free; the log line was the whole 7.4 fps. Its own entry above has the
detail. **Subtract the instrument before believing the subject.**

### 2. The load never arrived, and the failure looked like a catastrophic result

Eight painted peers measured **2-3 fps** -- so bad it read as a damning result for the painted tier.
It was the relay's **`-max-clients` default of 8** refusing every peer: the adapter logged `relay
refused connection: server full` and finished with `remotes=0 ghosts=0 drawn=0`. It was measuring an
adapter thrashing to reconnect, with nothing rendered at all. The user saw the same thing from the
other side -- *"i never saw any drawn ghosts either"*.

**The lesson is not "raise max-clients".** It is that a load generator's success has to be CONFIRMED
from the receiving side before its numbers mean anything. The adapter prints exactly that
(`remotes=N ghosts=N hw=N drawn=N`) and it was sitting there unread.

### 3. One side of the comparison was off screen

The next run looked reasonable, which made it worse. Synthetic peers from `meshghost-fakeadapter`
orbit a **fixed map coordinate**, while the hardware-sprite probe positioned its copies **relative to
the player**. Riding `fpsride`'s left/right route therefore walked away from the painted crowd while
carrying the hardware one along -- and the painted tier's own off-screen cull then made its peers
nearly free. A loaded tier was being compared against an unloaded one.

The user caught it: *"the drawn ghosts are not following when you go to the left. not accurate
testing"*. The adapter's status line had been printing `drawn=0` mid-ride the whole time, and it had
been read past twice.

**The fix is a different instrument, not a tweak.** `probes/fpsride.lua` is right for *"does this cost
the player anything while they play"* and structurally wrong for putting two renderers side by side.
`probes/fpshold.lua` exists for the second question: the player stands still, the peers are centred
on them, and the load stays on screen for the whole window.

### 4. The reference hid the defect it shared

With the tiers finally priced, the hardware ghost still looked *"really choppy"*. The cause was in the
**shared position pipeline** -- `glideRemote` measuring target speed frame-to-frame against a bursty
stream, which collapsed its speed limit and left the ghost unable to follow a running player
(`verified.md`, same date). The painted tier had the identical defect and had shipped with it.

**Why nobody had seen it:** in compare mode the painted copy is **pinned to the spawned ghost's own
sprite** and never uses its own position, so the one instrument aimed at that tier was structurally
incapable of showing the fault. It took a THIRD renderer, placed from the pipeline, to expose a bug
in code the second one had been running unnoticed.

**Two rules out of this.** A comparison harness that pins one side has removed a whole class of
defect from view -- know which class. And when a new implementation looks worse than an old one,
check whether the old one is being measured on the same path at all before concluding anything about
the new one.

### And the one that was not a measurement error at all

Between 3 and 4 the tier rendered **nobody** for a full cycle. OBJ VRAM was 996/1024 used and
`allocSpriteTiles` could not find a run. **A tier that silently renders no one is indistinguishable
from a tier that is switched off**, and there was no way to tell them apart. Acquisition failure now
logs its reason, throttled, to the file. A map load frees every range (the engine's own
`ResetSpriteData`), which is how the 52/1024 baseline was recovered and the leak shown to predate
this work.

## "The game blocked me" was an NPC finishing a sentence (2026-08-19)

**Symptom.** A measurement was abandoned and its absence written into the record as a property of
the game: *"Route 101 is story-blocked"*, offered as the reason a route row was missing from
Emerald's crowd-limit table.

**What actually happened.** An agent driving the game with scripted inputs walked into an NPC who
stopped it and started talking. It read the interruption as a wall, turned around, and reported the
route as unreachable. The user \u2014 who knows the game \u2014 corrected it immediately: that NPC is the
*"please go help"* stop, which says its piece and then lets you walk straight past. The genuinely
blocking version of the same character (*"it's dangerous, you can't go there yet"*) had been
cleared earlier in that save. **The route was one A press away.**

**Why it survived.** The false conclusion was *plausible, self-consistent and untestable from the
inside*: the character really did stop moving, the dialogue really was about not going somewhere,
and an agent with no memory of the save's story state has no way to tell "temporarily interrupting
you" from "permanently refusing you". Nothing failed. It simply stopped, and then explained.

**The rules it violates**, both already in `CLAUDE.md` and both worth pointing at here because this
is what they look like in the wild:

- **Never assume what a game is MEANT to do \u2014 ask.** The person who owns the save knows in one
  sentence what an agent cannot derive in twenty minutes of probing.
- **"I could not get there" is a statement about the driver, not about the game.** Write it that
  way. *"Scripted input did not get past an NPC interaction"* is true and invites the one-line
  correction; *"the route is story-blocked"* is a claim about the game that a reader will believe
  and build on.

**What to do instead.** When a game interrupts a driven run: **press A through it and try again**
before concluding anything \u2014 dialogue is the single most common interruption in these games and
the cheapest thing to clear. If it still will not pass, say what was observed, and ask.

## PARTLY RESOLVED (2026-08-19) — Crystal: invisible collisions, and ghosts popping in and out

**The popping half was fixed and user-confirmed** (`verified.md`; `unverified.md`). The collision
half is the part that stayed open. Restatused 2026-08-25 — it had no status line at all, and a
still-OPEN item is out of scope for a file of closed incidents anyway.

**Symptom, user-reported while a crowd of stationary ghosts stood around New Bark Town:** walking
into collisions with nothing visible on the tile, and characters appearing and disappearing as the
player walks toward or away from them.

**What is already measured**, from a probe reading both of Crystal's arrays at once:

- **The engine itself keeps a map object without an object struct for distant characters.** With
  no ghosts present at all, the game's own NPCs at distance 5 and 10 read `NO-STRUCT` while the
  one at distance 1 was drawn — and a struct was seen being *re-assigned* as the player moved
  closer. So "a tile is occupied but nothing is drawn on it" is a **normal state in this game**,
  not something MeshGhost invented.

**Two candidate causes, which need different fixes, and the difference matters:**

1. **An off-screen ghost still blocks its tile.** A peer standing just past the screen edge is an
   invisible wall. Arguably the game's own rule, since its NPCs behave identically — but a player
   can *see* an NPC coming and cannot see a peer who is off-screen.
2. **A ghost's struct is culled and re-assigned as the player approaches, and `stillOurs()` reads
   the empty struct as "this slot is no longer ours"** — dropping the record and respawning. That
   would produce exactly the popping described, and it would be **ours**, not the engine's. The
   identity check was added the same day (for the battle case) and was never tested against
   distance-based culling, which is precisely the kind of gap a same-day fix leaves.

**How to tell them apart:** the attached probe logs, per ghost, whether the map object and the
struct each still exist, plus the distance to the player. Cause 2 shows the struct disappearing
while the map object stays, followed by a *new* spawn line in the adapter log. Cause 1 shows both
halves intact throughout, with the player simply walking into a tile off the visible area.

**Not yet reproduced under the probe** — a scripted walk-away could not be driven while a human
was at the controls, and this needs the player to move a screen away and come back.

## A single screenshot cannot see a blinking thing (2026-08-19)

**Symptom.** A picture is taken to answer a question about the screen, and it answers a different
question: *what was on screen during one 60th of a second*.

**The user's example, which is the clearest form of it**: "PRESS START" flashing on a title
screen. Mistime the screenshot and the prompt is absent. The image is sharp, nothing errored, and
the obvious readings — the game is stuck, there is no prompt, the script did not run — are all
wrong.

**Three live cases the same evening, all the same shape:**

- **Crystal's menu rectangle strobes.** `wMenuBorder*` returns to `0,0,0,0` and back several times
  a second *while the menu is plainly on screen*, so a single read says "no menu" about half the
  time. The fix was to latch the last non-zero rectangle while a panel is up.
- **Sprite dropping happens on 2–3% of frames.** With a crowd packed together the Game Boy exceeds
  its 10-sprites-per-scanline limit on roughly one frame in forty. A screenshot would essentially
  never catch it; the user's honest *"kinda hard to tell"* was correct, and it was settled by
  counting sprites per scanline instead of looking.
- **A screenshot loop aliased with the walk cycle.** Firing every 120 frames against a 240-frame
  cycle produced identical pictures, which read as "nothing is moving" while the game moved fine.

**The rule.** Sample across time and report the **range** (`oam=14..38 of 40`), sample longer than
the period you are looking for, and choose an interval that cannot align with it — or trigger on
change rather than on a timer. Full method, with the general form: `adapters/_template/probes.md`,
"One sample cannot see a blinking thing".

**And the corollary for talking to the user**: when they say they cannot tell whether something is
happening, that is a measurement result, not a non-answer. It means the effect sits at the edge of
perception, and the next move is to count it rather than ask them to look again.

## Two things that share a file, and the silence that hides them — 2026-08-19

Both found in one two-instance Emerald session, and they are the same mistake in two places: a
name that is not unique per instance.

- **Symptom.** Lines in `adapters/emulator/pokemon/emerald/logs/` mangled mid-write —
  `atus: frame=...` where one write landed inside another.
  **Cause.** The log name resolved only to the second (`meshghost_emerald_%Y%m%d_%H%M%S.log`), and
  two emulators running the same adapter reload in the same second every time a shared control
  file or a restart moves them together. Both then held the same file open.
  **Fix.** The name carries the emulator's process id. A pid cannot collide while both processes
  exist; a bridge port can, and is not even known at the point the log opens (it is walked).
  Back-ported to the Crystal adapter, which had the identical shape.

- **Symptom.** One of four cores did not rejoin after the shared relay was restarted; its adapter
  read `remotes=0` for ten minutes and its log said nothing at all.
  **Cause, and it was not the reconnect loop.** The core had been started in `dev-scripts/`, where
  a `config.json` pointed it at a crowd-test relay on a private port; that relay had exited, and
  the config file had since been deleted, so nothing in the tree explained the port. The retry loop
  ran the whole time — proven by starting a relay on that port and watching it reconnect in 15s —
  but the log line was gated on the error message CHANGING, and a dead address produces a
  byte-identical error forever.
  **Fix.** A still-failing reconnect repeats once a minute with the address and the elapsed time
  (`core/core.go`, `reconnectLogInterval`).
  **The general rule:** *"log it again only if it changed"* is right for a retry that will succeed
  shortly and wrong for one that never will, and the two are indistinguishable at the moment the
  first line is written. Any unbounded retry needs a heartbeat, or it is invisible exactly when it
  matters. Corollary already in `environment.md`, now with a live case: **prefer an explicit
  `-relay` flag to a config file when several sessions share a machine** — a flag is in the
  process list forever, a config file can be deleted and take the explanation with it.

## Crystal: a drawn ghost paints over a FULL-SCREEN menu, because the adapter reads it as a text box (2026-08-19)

**Symptom** (user, watching vanilla Crystal, 2026-08-19): *"the ghost is being drawn while in the
menu's."* The adapter's own counters denied it — 21-24 peers `hidden by UI` with a menu open — and
the counters were the thing that was wrong, exactly as `CLAUDE.md` says to assume.

**What the counter missed, and why a count can never settle this.** "21 hidden" is perfectly
compatible with "and 33 more painted straight over the panel". A per-peer dump was added
(`MESHGHOST_CRYSTAL_UI_DEBUG`, off by default: the rectangle, the two open-flags, and where each
painted peer actually sat) and it separates three states that the summary line had been blurring
into one:

| On screen | `textBoxOpen()` | `uiPanelOpen()` | `wMenuBorder*` rect | Result |
| --- | --- | --- | --- | --- |
| Overworld, nothing open | false | false | none | everything painted — correct |
| **START menu** (a box on the right) | false | **true** | `l=80 t=0 r=160 b=128` | 35 painted / 9 hidden — the painted ones are all left of the rectangle, i.e. **correct** |
| **Full-screen submenu** (POKéMON, BAG…) | **true** | false | **none** | **31-34 painted / ~11 hidden — the defect** |

**Diagnosis.** A full-screen menu publishes **no** `wMenuBorder*` rectangle, so `uiPanelOpen()` is
false and there is nothing to clip against. What it *does* trip is `textBoxOpen()` — so the adapter
believes a bottom text box is up and protects **only the bottom six rows**. Every peer above screen
row 12 is painted over the menu: the dump shows them at `sy` = -4, 12, 28, 44, 60 and 76, which is
the whole top two-thirds. The loopback self-ghost is in there too (`p258-ghost@64,28`).

**So the top-level START menu was never the broken case, and that is why this was missed** — it was
the only menu tested, it is the one that publishes a rectangle, and it clips correctly.

**The obvious fix is a trap, and the probe proves it.** "Scan every row for the frame corner and
hide everything" fails on measured evidence: `uiframe_probe.lua` logged `bg row=0 col=10
edgerun=8` — the START menu's own box, still sitting in the tilemap — repeatedly during ordinary
walking with `WY` parked at 144, i.e. **frame tiles present with no panel on screen**. Same shape as
the WY-alone heuristic that blanked half the screen earlier that day. The tiles persist; only the
display state says whether anyone can see them.

**The fix, and it is not a third heuristic.** `wStateFlags` bit 0 ("overworld sprite updating
on/off") was tried first and rejected on measurement: it strobes between `01`, `40` and `41` inside
a single unchanging state, exactly like the WY-alone heuristic. What does separate the states
cleanly is the engine's own output — **how many hardware sprite entries are live** (OAM `y` in
1..159), sampled every frame and logged on change:

| On screen | Live OAM entries |
| --- | --- |
| Overworld, walking | 28-34 |
| Text box open (map still behind it) | 30+ |
| START menu (map still behind it) | 28-30 |
| **Full-screen submenu** | **exactly 0** |

So the drawn tier now returns early when **no** sprite is on screen. That follows from what the
tier *is* rather than being bolted on: it paints **alongside** the characters the engine renders,
so if the engine is rendering none, there is nothing to paint alongside — and the anchor this code
calibrates its screen positions against does not exist either, which is precisely why the old
fallback path produced plausible-looking coordinates over a menu.

**Verified numerically, same session**: the per-peer dump produced 31-34 painted peers per sample
in the submenu before the change and **zero dumps in that state at all** after it, across a full
sweep (overworld -> START menu -> POKeMON submenu -> back), while the START menu case was unchanged
(35-38 painted, every one of them left of `l=80`, nothing inside the rectangle) and the drawn tier
resumed normally on exit (63 waiting, 36-38 drawn, 31-32 mid-stride). **Not yet watched by the
user**, which is what `unverified.md` asks for.

## A probe with its own frame loop freezes every other script — 2026-08-19

**Symptom.** The dev loader stopped logging, stopped polling its control file, and the adapter
stopped ticking — no bridge traffic, no ghost, no adapter log lines — while the emulator carried on
at full speed and stayed responsive. From outside it looks exactly like the loader having quietly
died.

**Cause.** `probes/surf_bike_probe.lua` (written 2026-08-14, before the loader existed) ends in a
bare `while true ... emu.frameadvance()` and sets no `MESHGHOST_DEV_TICK`. Loaded as a loader
target, that loop never returns, so it runs **inside** the loader's own `loadTarget` call forever.
The loader's header has always stated the contract; the pre-loader probes were never updated to it,
and **~33 of them are in the same state** (`for f in adapters/emulator/pokemon/*/probes/*.lua; do
grep -q 'while true do' "$f" && ! grep -q MESHGHOST_DEV_TICK "$f" && echo "$f"; done`).

**Fix.** The loader now **refuses** such a target by inspecting its text before loading it, and says
why (`wouldHijackFrameLoop` in `dev-scripts/bizhawk-dev-loader.lua`). A guard in the one place that
knows a script is about to enter a shared frame loop beats rewriting 33 standalone probes that are
perfectly correct on their own. `surf_bike_probe.lua` itself was given the
`if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = step else while true ... end` shape, which is the
pattern to copy.

**The cost, which is why this is worth a guard rather than a note.** There is no recovery from
outside the emulator: no file edit, no control-file change and no signal can break that loop, so the
instance is dead until someone restarts BizHawk by hand. It cost this instance its session on
2026-08-19.

**The general form:** a shared cooperative loop needs every participant to *return*, and a
participant that does not cannot be detected once it is running — only refused before it starts.

## Crystal: a nil address reads as byte 0, so an unmeasured entry SATISFIES a gate instead of refusing (2026-08-19)

**Measured 2026-08-19, not reasoned about:** `memory.read_u8(nil)` under BizHawk **succeeds and
returns 0**. It does not error, so `pcall` does not catch it.

That silently inverts a promise this adapter makes in writing. `phases/phase9.md` states that an
unmeasured entry in an `ADDRESSES` table "stays `nil` so the adapter refuses rather than writing
somewhere plausible" -- but `inPlay()` tested `u8(W_BATTLEMODE) == 0`, and with a nil address that
term reads byte 0 and is **always true**. The adapter would believe no battle was ever happening,
which is one of the two ways a ghost gets painted over a battle screen.

**Fixed** by making `u8()` return `nil` for a nil address, and by making `inPlay()` require every
term to be a known value -- any `nil` means "this build has not been measured here" and the answer
is no. The startup refusal for missing addresses already existed and is unchanged; this closes the
case where a nil reaches a read at runtime anyway.

**The general lesson, worth carrying to every adapter:** "unmeasured" must fail CLOSED, and a
language that coerces nil into a valid argument will quietly make it fail open. Test what your read
primitive does with a nil address before relying on nil to mean refusal.

## Crystal: the drawn tier needs a POSITIVE "is the overworld on screen", not a list of screens to avoid (2026-08-19)

Two user reports on 2026-08-19 -- ghosts painted over a full-screen **menu**, ghosts painted inside
a **battle** -- are one defect. The drawn tier paints after the frame with none of the engine's
context, so anything not explicitly excluded gets painted over: a battle, a menu, an evolution
screen, the naming screen, the Pokedex, a cutscene, the title screen. **A deny-list of those will
never be finished, and every entry missing from it is a bug a user has to find first.**

Why the state gate was not enough alone, measured by the Archipelago agent on that build:
`wMapStatus` reads **2 right through an entire battle** and never leaves the in-play value, so the
battle exclusion rests **entirely** on `wBattleMode` with nothing behind it. Anything leaving
`wBattleMode` at 0 while the overworld is gone -- the encounter transition most obviously -- is
unguarded. They also A/B'd the gate itself: writing `wBattleMode = 2` in the overworld silenced the
drawn tier completely (0 log lines in 8s) and restoring 0 brought it back (32 lines in 8s), so
`drawOverflow()`'s early return works exactly as written and the terms were the problem.
`0x0FB1` is **not** a usable second term -- it reads 0 in some indoor maps.

**The test now asks the engine what it is drawing**, which no ROM revision can shift:

1. `inPlay()` -- the state gate, now nil-safe (above).
2. **At least one live hardware sprite** (OAM `y` in 1..159). Measured: overworld 28-34, behind a
   text box 30+, behind the START menu 28-30, **full-screen menu exactly 0**.
3. **The local player's own character is being drawn** -- OAM entries 0-3, which this tier already
   treats as the player's four sprites for its anchor calibration. This is the term that covers the
   encounter transition, where the overworld is gone before any state flag says so; and if it is
   false, the calibration those screen positions depend on has nothing valid to work from either.

Verified on vanilla across a full menu sweep: **zero** full-screen-menu draws after the change
against 31-34 painted peers per sample before it, the START menu case unchanged (13 dumps, every
painted peer outside its rectangle), and the overworld unaffected (38 drawn, 26 mid-stride, 7
spawned). **A vanilla battle was not reached** -- the walk to grass was blocked by our own spawned
ghosts boxing the player in, which `crowd-limits.md` predicts -- so the battle half rests on the
Archipelago agent's measurements above and still wants watching.

## Calibrating on OAM entry 0: the entry ORDER swaps when the sprite flips (2026-08-19)

**Symptom** (Crystal, 2026-08-19): drawn peers snapped around by 8px while the local player walked,
and only while walking. Standing still, everything sat correctly.

**Two plausible causes were ruled out first**, and both looked right on paper: the positions were
being computed in the engine's scrolled space (correct only at the instants the engine recomputes
it), and the anchor object was being re-chosen each frame. Fixing both reduced the jumping and did
not remove it.

**The real cause is a hardware behaviour, and it is not specific to this game.** A character's
four OAM entries are emitted **mirrored when the sprite is flipped**, so the entry that happens to
be the left-hand one changes with the direction the character faces. Calibrating the drawn tier's
origin on *entry 0* therefore gave an x that alternated by exactly 8px as the player turned --
which is why it only appeared in motion.

**Fix:** take the **minimum x across the four entries** rather than reading one of them. That is
invariant under the flip, because the set of four is the same set either way. Measured **64
discontinuities of 8 and 16px in a 20-second walk, down to 0 across 1,199 samples**.

**Carry this to any adapter that reads OAM to locate something.** "Entry 0 is the top-left one" is
an assumption about the current facing, not about the hardware, and it holds right up until the
character turns round.

## Lua 5.4 refuses a bit shift on a float, and a smoothed position is a float (2026-08-19)

**Symptom** (Emerald, 2026-08-19): a per-frame error, once every frame, from the drawn tier's
panel clipping.

**Cause:** the clip row was computed by shifting a screen position right to get a tile row -- and
that position comes from the **sub-tile smoothing**, so it is a float like `114.5`, not an integer.
Lua 5.4 raises rather than truncating (`number has no integer representation`), unlike 5.1/5.3
semantics some of us carry in our heads.

**Fix:** `math.floor` before the shift. **The general form: any value that has been through
interpolation or smoothing is a float**, however integral it looks in a log line, and every bitwise
operator and array index downstream of it is a trap. Grep for `>>`, `<<`, `&` and `|` on anything
derived from a smoothed coordinate.

Worth noting what hid it: the blanket per-frame `pcall` caught it, so the adapter kept running and
the clipping silently did nothing. `adapters/emulator/pokemon/emerald/BANDAGES.md` entry 2.

## A bridge port pinned in the environment cannot pin an ALREADY-RUNNING instance (2026-08-19)

**Symptom** (Emerald, 2026-08-19, with four emulators up): an instance launched with
`MESHGHOST_BRIDGE_PORT` set was port-walked anyway, walked into two other instances' cores, and
**attached to one of them** -- so two emulators drove one core and a third had none.

**Cause:** the Emerald adapter read the pin from the **environment only**. An environment variable
is fixed at process launch, so it can pin an emulator you are *starting* and can do nothing for one
that is *already running* -- which is every instance in a long session. Crystal had already learned
this and read a Lua global as well; Emerald had not been back-ported.

**Fix:** read the Lua global first, then the environment. A global can be set into a live emulator
from a control-file script, so the pin works on an instance nobody wants to restart.

**The wider rule for multi-instance sessions:** a port walk is a convenience for a single instance
and a hazard for several. When more than one emulator is up, **pin every bridge explicitly and
verify from the adapter's own log which port it settled on** (`bridge_ready on port N -- this core
is ours`). See `environment.md`, "One agent per BizHawk INSTANCE".

## A hardcoded ROM address slipped past the refuse-if-unmeasured discipline an hour after it was built (2026-08-19)

**Symptom** (Crystal, 2026-08-19): none, yet. It was caught by reading, not by a failure.

**Cause:** the cartridge sprite table had just been given a **per-ROM-build table with a nil for
any build nobody had measured**, precisely so an unmeasured build refuses instead of guessing. Then
a second code path used `OverworldSprites` as a **hardcoded constant**, on any build,
bypassing that table entirely. On the Archipelago ROM -- where the table lives at `0x14564`, not
vanilla's `0x14736` -- it would have painted peers from arbitrary ROM bytes.

**Why this keeps happening: "derived from the vanilla address" has now produced four wrong
addresses on this project.** A relocated build moves things in several independent blocks, and
today's Emerald case proved two of them can move by different amounts in one ROM
(`gObjectEvents` +0x284, the graphics-info pointer table +0x7530, `gSprites` not at all).

**The discipline, and it needs enforcing rather than documenting:** an address used on more than
one build belongs in the per-build table, always, with a nil where nobody measured it -- and a
constant that names a ROM location is a code smell on sight. **Grep for the constant's name after
adding the table**, because the path that bypasses it is usually written by the same person in the
same hour.

## Frame tiles in the tilemap are not the same thing as a panel on screen (2026-08-19)

**Symptom** (Crystal, 2026-08-19): a probe scanning every tilemap row for the text box's frame
corner found a full-width frame top at BG row 12 **with no panel visible on screen** and the window
register `WY` parked at its off value of 144. It cleared seconds later as the camera scrolled.

**Cause:** the tilemap holds what was last written there, not what is being displayed. A panel that
has been closed, or one scrolled out of the visible window, leaves its tiles behind.

**Why it matters:** the obvious generalisation of Crystal's text-box test -- "scan every row for
the corner tile instead of just row 12" -- would therefore **hide drawn peers for no reason**,
which is the same class of over-hiding as the earlier WY-alone heuristic that emptied the bottom
half of the screen. A tilemap test needs the window to actually be on: LCDC bit 5, `WY<=143`,
`WX<=166`.

This one was found *before* it shipped, by a probe written to check the assumption rather than to
confirm it -- which is the only reason it is a pitfall entry and not an incident.

## A stray dev-scripts/config.json silently redirects a core to a relay nobody is running (2026-08-19)

**Symptom** (2026-08-19, twice): once, four synthetic peers went to a dead port and rendered
nothing; once, a core sat retrying a relay that had already exited while everyone assumed it
had lost the shared one -- and the reconnect log said nothing, because it only logged when the
error message *changed* (fixed the same day, `verified.md`).

**Cause:** a core reads `config.json` from its **working directory**, and a core autostarted by the
BizHawk loader has `dev-scripts/` as its cwd. A config left there by an earlier session pointed at
`127.0.0.1:7787`, room `emeraldcap`. The file was then deleted, so **nothing in the tree explained
the port any more** -- the process was the only witness.

**Fixes, both applied:** `dev-scripts/config.json` is gitignored so it can never be committed, and
the retry now keeps saying which address it cannot reach.

**The habit that catches it:** when a core connects somewhere unexpected, read its **command line**
(`Get-CimInstance Win32_Process`) rather than the repo -- a flag survives in the process list, a
config file's contents do not. Prefer an explicit `-relay` flag over a config file whenever
sessions share a machine.

## "A bit choppy" cost six rewrites, because it was three separate bugs and none were where I looked — 2026-08-19

**Symptom.** A drawn (painted) ghost in Emerald looked subtly wrong next to the engine-spawned one:
choppy, then too fast, then choppy again. Six movement models were written and judged by eye.

**What it actually was**, once both ghosts were logged per frame instead:

1. **Running at walking speed.** The step machine took its duration from the peer's `anim` tag,
   which said walking while the peer ran. The ghost lost half a tile per step, fell behind, and
   SNAPPED when it passed two tiles. The snap was the visible chop.
2. **A one-tile spike in the anchor, once per step.** The player's tile counter flips to the
   DESTINATION tile the moment a step begins, so calibrating against it mid-step put a whole tile
   of error in. Direction-dependent, which is why it looked fine one way and terrible the other.
3. **A ±2px beat every frame** from mixing two camera counters — `gSpriteCoordOffset` (inside the
   player's screen position) and `gTotalCameraPixelOffset` (inside the anchor) — which the game
   does not write at the same point in the frame.

And the last one was not in the adapter at all: the remaining hitch on the SPAWNED ghost was the
core's `-interp`, 100ms, too short to cover a 20Hz arrival rate. At 250ms it was perfect.

**The lessons, in the order they would have saved time.**

- **`CLAUDE.md` says stop after ~3 failed live iterations and tabulate. That rule was ignored for
  six.** The first measurement — logging both renderers' actual positions per frame — found bug 1
  immediately, and each subsequent one found the next. Every model rewritten before that was aimed
  at a symptom whose cause was somewhere else entirely.
- **"Smooth it" and "schedule it" are different jobs.** Any model with its own timing — a step
  duration, a speed, a state machine — runs against a world that scrolls on the game's clock, and
  two clocks beat. A filter has a lag and no phase, so it cannot beat with anything. Smoothing
  between updates is the adapter's job; deciding WHEN things move is not.
- **A state tag can lie; a position cannot.** `anim` is a classification of the sender's state, and
  a cutscene, a forced walk or a turn can all move a character without setting it. Ask the peer's
  own coordinates what it is doing.
- **When two renderers must agree, pin one to the other rather than reproducing its schedule.**
  Compare mode now places the painted ghost from the spawned one's own sprite, which makes every
  remaining difference a rendering difference — which is what the mode was for.

## Approximating the game's own art never converges — read it instead, 2026-08-19

**Symptom.** A hand-drawn ellipse standing in for Emerald's ledge-jump shadow went through three
rounds of correction — too faint, still lighter than the player's, then too big, then *"or slightly
big still not sure"* — with each round costing the user a live test.

**Why it could not converge.** The thing it imitates is on screen next to it. Any difference in
size, shade or placement is directly comparable, so "close enough" is never reached; each fix moves
the discrepancy somewhere else. Measuring helped every time and still did not finish the job: the
palette dump gave the colour, the sprite dump gave the position, decoding the pixels gave the ink
extent (16x5, not the 16x8 sprite box) — and it was *still* arguably a touch big, because an
ellipse is not that silhouette.

**What ended it.** Reading the game's actual art. A shadow is an ordinary sprite, so the first time
the local player hops there is one on screen with its own `images` pointer and palette: decode it
once, draw those runs for every ghost. Confirmed perfect immediately, and it dims and clips for
free because it goes through the same draw path as everything else.

**The rule.** When compensating for something the engine will not do for a ghost, prefer reading
the engine's own asset over drawing a lookalike — and identify that asset by WHAT IT IS (in use,
this size, next to the player, during this action) rather than by an address, so nothing goes stale
against a ROM revision. Crystal's drawn tier already learns facing frames this way; the same trick
works for effects.

**Where an approximation is still correct:** as a fallback for the case that has nothing to learn
from yet — here, a ghost that hops before the local player ever does.

## A ghost has no task, so nothing ever un-pauses its animation — 2026-08-19, Emerald

**Symptom.** A spawned ghost that picked up a fishing rod held the animation's **first frame** for
the entire state. The graphic was right, the pose was right, the position was right; it simply
never moved. Reported as *"its not doing the fishing animation/s"*, and later, after a wrong fix,
*"it gets stuck in an animation instead of doing the animation"*.

**Why it survived two fixes.** The obvious reading is "nothing is advancing the animation, so
advance it" — and both attempts did exactly that, from the peer's animation number. Both looked
*worse*, because the actual cause was one layer down: the sprite was **paused**.

The overworld pauses an idle object event's sprite (`animPaused`, bit `0x40` of the sprite struct's
`+0x2C` — `pokeemerald` `include/sprite.h:211-212`, where `animDelayCounter:6` precedes it). The
player's fishing **task** un-pauses it as part of running the animation. A ghost has no task. So
the ghost sat paused, and every write of `animNum` on top of a paused sprite just re-selected an
animation that was never going to play — and writing it repeatedly (with `animBeginning`) actively
made things worse, restarting frame 0 faster than the engine could leave it.

**What ended it.** Measuring the sprite instead of reasoning about it. One trace line carrying the
player's animation state and the ghost's on the **same frame** showed the ghost pinned at `3/0` for
256 consecutive frames and then `11/0` for the rest, while the player's frame index cycled
`0, 1, 3` throughout. `+0x2C` read `0xc7` on the ghost — `0x40` set — and the answer was in the
bit, not in the number.

**The fix uses the engine's own switch, not the bit.** `ObjectEvent.enableAnim` (byte `+0x01`,
bit `0x08` — `include/global.fieldmap.h`) is what `TryEnableObjectEventAnim`
(`src/event_object_movement.c:7335-7343`) reads: it clears `animPaused` **and** `disableAnim`, then
clears itself. One write per animation start hands the whole job back to the engine, which is what
makes the frames advance at the game's own rate rather than one we would have had to invent.

**The rules.**

- **An engine pauses work it believes nobody needs, and a synthetic entity is precisely the thing
  it believes nobody needs.** Before concluding "the engine will not do X for a ghost", check
  whether the engine has been *told not to*. Idle-pausing, culling, sleep flags and LOD are all the
  same shape, and all of them make a ghost look broken in a way that reads like a missing feature.
- **Prefer the engine's own enable switch over clearing the state yourself.** Clearing `animPaused`
  directly would have worked this frame and been re-set the next; going through `enableAnim` means
  the engine stays the owner and its own bookkeeping (`disableAnim`) stays consistent.
- **A memo of "what we last told it" is not a memo of "what it is".** The first version of this fix
  remembered the animation number it had issued, so a **second** cast of the same rod matched the
  remembered number, skipped the enable, and froze again — after the engine had silently re-paused
  the sprite at the end of the first cast (measured: `+0x2C` back to `0xcd` with the memo still
  reading `3`). Condition on the observable state, not on your own history.

## A value the game DERIVES cannot be COPIED — 2026-08-19, Emerald

**Symptom.** A fishing ghost sat 8px to the side of where it belonged, or stepped 8px sideways and
back, at the start and end of every cast. Reported over many iterations as *"it snaps"*, *"it gets
pulled back a tiny bit"*, and finally *"it still looks like it snap/move at the start~ and end~ of
the fishing compared to the drawn & player"*.

**Why it was hard.** The offset is real, small, and *sometimes correct*, so every measurement of it
looked nearly right. Four separate defects produced the same 8px symptom, and each fix revealed the
next:

1. **Shape and offset applied on different frames.** The graphic swap wrote the new sprite's
   dimensions; the offset was left to a block that had already run earlier in the same frame, so
   the offset always landed one frame after the shape. A 32-wide fishing frame drawn at a walker's
   offset is exactly half a tile off.
2. **The wire carried a mismatched pair.** The sender deliberately **holds** the graphic for six
   frames before publishing it (so peers never see an unsettled state) but did not hold the offset.
   At every cast *end* it therefore published the fishing graphic together with the walker's
   offset, and at the start the reverse. A hold applied to one half of a pair **creates** the
   mismatch it was built to prevent.
3. **The receiver applied it to the wrong graphic.** With the pair briefly disagreeing on the wire,
   the ghost adopted a fishing offset while still wearing the walking graphic.
4. **The real cause: the offset is not a transmissible property at all.** The game recomputes it
   **every frame from the frame currently displayed** — `AlignFishingAnimationFrames`
   (`src/field_player_avatar.c:2045-2078`) reads `anims[animNum][animCmdIndex].type`, which for a
   frame command is that frame's image index, and sets `x2=8` for images 1/2/3 (`-8` when facing
   west, `DIR_WEST=3`, `include/constants/global.h:140`), `y2=-8` for image 5, `y2=8` for images
   10/11.

Because a ghost's animation **lags** the player's by the interpolation delay, the player's offset
is *always* the offset for a frame the ghost is not showing yet. Copying it was wrong by
construction — and no amount of tightening the pairing could fix that, which is why fixes 1-3 each
removed a real defect and left the symptom.

**What ended it.** Computing the offset locally, from the ghost's **own** displayed frame, with the
game's own rule.

**The rules.**

- **Before putting a field on the wire, ask whether the game STORES it or RECOMPUTES it.** A stored
  field is a fact about the peer and travels fine. A derived field is only meaningful *alongside
  the exact input it was derived from*, and a ghost — running behind, by design — never holds that
  input at the same time. **Send the input; derive locally.**
- **A settle/hold must cover every field of a pair, or none.** Half a held state is a state that
  never existed.
- **Two consumers of one state must agree about which MOMENT it describes**, not just about its
  value. Nearly every defect in this investigation was that same disagreement wearing a different
  hat.

## A script's writes land between frames; the game's land inside one — 2026-08-19, Emerald

**Symptom.** With the offset finally computed correctly from the ghost's own frame, the ghost
**still** flicked 8px sideways — now mid-animation rather than at the ends. Every struct field read
back exactly right on every frame.

**Why no value was ever going to fix it.** A Lua script acts at a frame boundary. The engine,
within one frame, **advances sprite animations and then builds OAM**. So a value written from Lua
is paired with whatever image the engine selects *afterwards* — structurally one step out of phase.
The offset was right for the frame we could see and wrong for the frame that got drawn, forever, no
matter how correct the arithmetic was. The game's own fishing task has no such problem because it
runs *inside* that same update, which is precisely why the player never flickers.

**How it was proved.** By reading OAM directly (`0x07000000`, 128 entries, 8 bytes each) rather
than the sprite structs that feed it. `pos2` was constant at `8,0` across frames in which the OAM x
went `144, 136, 144`. When every struct field agrees and the screen disagrees, the structs are not
the thing being drawn.

**The fix.** Run the alignment from an `event.onmemoryexecute` hook at **`BuildOamBuffer`**
(`0x08006A0C` on the vanilla ROM, from this project's own `pokeemerald.map` build — see
`environment.md`): animations for the frame are final, OAM is not yet built. That is the same point
in the pipeline the game's own task occupies, which is what makes it identical on screen. It is
vanilla-gated — an Archipelago build relocates code, so there it falls back to the frame-boundary
path until that ROM's address is measured (the adapter's `BANDAGES.md`).

**And then it broke the OTHER renderer.** The painted tier pins its position to the spawned
sprite — which had just acquired an offset specific to the *spawned* ghost's current frame — while
painting the frame the **wire** reported. Right image, another sprite's alignment: the same defect
class, in the last place it could still hide. Fixed by dropping the alignment from the pin and
having the painted tier compute the shift for the frame **it** draws, from a rule now shared by
both tiers.

**The rules.**

- **When a value must stay in lockstep with something the engine updates mid-frame, a
  frame-boundary write is structurally wrong, not merely mistimed.** Correcting the value cannot
  fix a phase error. Find the engine's own pipeline point and act there — `event.onmemoryexecute`
  makes this available on BizHawk, and it converts "I can only act between frames" into "I can act
  where the game does".
- **A phase fix must be applied to every consumer at once.** Fixing one renderer while another
  inherits its now frame-specific output just moves the defect. When two renderers must agree,
  share the *rule*, not the *result*.
- **Watch for a fix that is invisible to your instrumentation.** Everything readable from Lua said
  the code was correct; only the hardware's own draw list disagreed. See `_template/probes.md`,
  "Measure what is DRAWN".

## A sprite you BUILD is missing whatever the game's constructor computed — 2026-08-19, Emerald

**Symptom.** Two, and only the first was ever reported as a bug. A surfing ghost rode on nothing —
*"both of the ghosts don't have the 'blue fish' they are riding on while surfing"* — while the
adapter's own log showed it correctly wearing the surfing graphic and animating. And when the blob
did exist, it had been recorded since 2026-08-18 as rendering *"roughly half a tile down-right of
the rider"*, cause unknown.

**Cause 1: one construction path out of two.** The blob was spawned inside `spawnGhost`, which is
the FULL-REBUILD path. Every way a peer actually enters the water goes through
`swapGhostGraphicInPlace` instead — they were already spawned as a walker, so the graphic is
patched rather than rebuilt. The companion sprite was correct code sitting on a path that the case
it was written for never takes.

**Cause 2: a field only the constructor sets.** `spawnSurfBlob` zeroes the sprite struct, copies the
template's OAM, images, anims and callback, and sets position — everything the TEMPLATE describes.
`centerToCornerVec` (`+0x28`/`+0x29`) is not in the template: `CreateSprite` computes it from the
OAM's shape and size. Left at 0,0, the hardware draws a 32x32 sprite from its corner instead of its
centre — one tile down and right, which is the unexplained offset, and it also means the blob's
position field did not mean what every other sprite's position field means.

**What ended it.** Reading the GAME'S OWN blob and diffing it field by field against ours
(`probes/surfblob_probe.lua`). The player's read `c2c=240,240`; the ghost's read `c2c=0,0`. Nothing
else had to be understood — not the bob, not the animation, not the field-effect system.

**The rules.**

- **A sprite built from a template carries what the template says and nothing the CONSTRUCTOR
  computed.** Before trusting one, diff it against a live instance the game made; the fields that
  differ are the constructor's. Never diff it against your own expectations.
- **When a feature is triggered on one construction path, find every other path into the same
  state.** Patch-in-place and rebuild are two doors into "this ghost is now surfing", and a feature
  hung on one of them is invisible exactly when the state is reached the normal way.
- **A companion sprite is part of the state, not a decoration** (`_template/README.md`'s
  whole-effect rule) — so it belongs everywhere the state is entered AND left. A blob left behind
  keeps following the object id in its own `data[2]` and swims under a peer who is walking.

## A world-space anchor built from a SPRITE carries the sprite's own terms — 2026-08-19, Emerald

**Symptom.** A painted reflection drew a few pixels onto the ledge and grass at a pond's edge, when
the player's own reflection stopped cleanly at the water. Reported five times across a long session
in slightly different words -- *"it draws on top of the edge as well, that sits between the
grass/water"*, *"its only supposed to draw on the water"* -- and survived four different clipping
rules, each of which was independently correct.

**Cause.** The drawn tier converts a screen pixel back to a map tile using an origin captured from
the PLAYER'S SPRITE position. That position is not a world coordinate: it is the sprite's frame
top-left, which carries two terms belonging to the graphic rather than to the map.

1. **`pos2`** -- while anyone is surfing this is the BOB, so the whole tile grid rose and fell a few
   pixels with the character. Found first, and it was cutting the reflection short vertically.
2. **`centerToCornerVec`** -- the frame's own centring, `-(width/2)`. A walking player is 16 wide so
   it is **-8**; a SURFING player is 32 wide so it is **-16**. The grid was therefore **8px too far
   left for exactly as long as the player was surfing** -- which is exactly when a reflection is on
   screen to be judged.

Vertically the same term is -16 for both graphics, so the vertical edge was correct throughout and
only the SIDE ever looked wrong. That asymmetry is what made it read as a clipping-rule problem for
so long: every rule tried was tested against a boundary that happened to be right.

**Why the obvious check could not catch it.** A self-check ran the player's own frame position
through the same inverse and compared it against the object's coordinates. It agreed perfectly on
every sample -- because both sides carried the same bias. **A consistency check between two values
that share an input proves only that they share it.**

**What ended it.** Aligning the computed grid against the SCREEN, using a tile whose appearance is
not ambiguous: metatile 161 is four copies of one water tile, so it must render as 16px of uniform
bright water. The grid said it started at x 88; the pixels said 96. Everything else followed.
Method: `_template/probes.md`, "Check a computed grid against the screen".

**The rules.**

- **An origin for world space must be free of every term that belongs to the SPRITE**: animation
  offsets, bob, alignment, and the frame's own centring. Normalise them out, or derive the origin
  from the camera instead. A sprite's screen position is not a world coordinate.
- **A term that varies with the GRAPHIC will hide until the graphic changes.** This was correct for
  every walking test ever run and wrong only while surfing.
- **When one fix closes two symptoms, it was one cause.** The user, on this one: *"it also fixed the
  issue of drawing when outside of the water at the same time"* -- the leak onto grass and the leak
  onto the ledge were the same 8px.

## A rule that is right for one graphic can be wrong for another — 2026-08-20, Emerald

**Symptom.** A ghost on a Mach Bike moved with its legs stopped — *"sliding/gliding at top speed"* —
while the same code animated a walking ghost perfectly.

**Why the counters said it was fine.** Two of them, both honest and both blind to this: the sprite
was never paused while moving (`paused=0`) and its frame index advanced on 67% of stepping frames
(`slide=150/225`). Nothing about "is it animating" was false. What was false was WHICH animation.

**Cause.** While a peer moves, the adapter lets the ENGINE animate the ghost, from the movement
action it was asked to perform. That is correct for the walking graphic — the action carries the
matching walk cycle, and mirroring on top of it put two writers on one field and left ghosts stuck
in a pose after a turn (2026-08-19). On a bike it is wrong: the player rides on animation 4, while
the action-derived animation for that graphic is 8, which runs to its last frame and holds.

**What ended it.** The per-frame trace that logs the PLAYER's animation state beside the GHOST's on
one line (`MESHGHOST_EMERALD_ANIM_TRACE`), which makes "different animation" and "same animation,
stalled" distinguishable at a glance:

```
f=597  P.anim=4/0 | R.sanim=4/0 | G.anim=8/3
f=605  P.anim=4/1 | R.sanim=4/1 | G.anim=8/3   <- ten frames on one frame
```

The peer had been sending the right number the whole time.

**The rules.**

- **A rule scoped to "while moving" or "while idle" is probably scoped to the wrong thing.** Ask
  which GRAPHIC it is true for. Walking, biking, fishing and surfing are animated by different parts
  of the engine, and a rule derived from one of them is a guess about the others.
- **A counter can only disprove the defect it was built for.** `paused` and `frame advanced` were
  both built for the previous slide, and both passed while a different slide was on screen. When a
  measurement clears something the user can still see, the measurement is answering a narrower
  question than the report.
- **Trace the reference and the copy on ONE line.** Every animation defect this adapter has had was
  invisible in a trace of either side alone.

## Counters placed inside a gated block measure nothing — 2026-08-20, Emerald

**Symptom.** 71 laps of scripted riding produced an empty counter column.

**Cause.** The counters for "is the ghost animating while it moves" were added inside the animation
mirror — which is deliberately gated on the peer standing STILL. So they could only ever record the
case they were built to rule out.

**The rule.** **Put a measurement on the path the event happens on, not near the code you suspect.**
The suspicion is what is being tested; wiring the counter into it assumes the answer. Check the gate
conditions above a new counter before trusting a zero, and prefer a per-frame path with an explicit
condition to a convenient nearby block.

## A stable field can read zero exactly when the thing it describes is happening — 2026-08-20, Emerald

**Symptom.** A ghost slid down a muddy slope at half the peer's speed, after a change that had just
fixed bike speed everywhere else.

**Cause.** The speed had been moved from `movementActionId` (transient, sampled at 20Hz, missed the
fast action 6 times in 10) to `gPlayerAvatar.bikeSpeed` (stable, correct while riding). But
`ForcedMovement_MuddySlope` calls `Bike_UpdateBikeCounterSpeed(0)` before pushing the rider — so on
the one terrain built for this bike, the field reads **standing still** while the character is
visibly moving at `WALK_FAST`.

**The rule.** **"Stable" and "correct" are different properties, and a field can be authoritative in
the ordinary case and deliberately zeroed in the special one.** Before replacing one source with
another, look for the code paths that WRITE the new source, not just the ones that read it — a reset
is as much a write as an update. The fix here was neither source alone: the stable field first, the
transient one as a fallback exactly where the stable one says nothing is happening.

## A character can face one way and move another — 2026-08-20, Emerald

**Symptom.** A ghost faced the wrong way while being pushed down a slope; the player kept looking
uphill, the ghost turned to look downhill.

**Cause.** Asking the engine for a step also sets the object's facing, which is right nearly
everywhere — and wrong wherever the game has separated the two. `facingDirectionLocked` exists for
exactly that, and the muddy slope sets it.

**What it cost to find, and the cheap way to see it.** Classify frames by what the PEER was doing
(here: the sign of its coordinate delta), then tabulate the ghost's action and facing across each
class. "The ghost faced south on 181 of 527 slide frames" is a finding; watching it is an
impression. The fix needed no new wire field: the peer's facing is already sent and the step
direction is known locally, so the two DISAGREEING is itself the signal.

**The rule.** **Never infer a facing from a movement.** Send it, or derive it from something the
game states, and look for a lock/override flag before assuming the two always agree.

## Two draw paths, and a fix applied to one of them — 2026-08-20, Emerald

**Symptom.** Occlusion for the painted tier was implemented, reloaded, and the ghost still walked
over the building.

**Cause.** The painted tier draws a character two ways: from the peer's OWN graphic when it has one
(a bike, a rod, a surfboard) and from the cached gender frames when it does not. Every session
recently had been spent in the first path, so the fix went there and nowhere else — and the peer was
on foot.

**What made it obvious, and it is worth copying.** The change shipped with a one-shot diagnostic
beside it, which printed NOTHING. An empty diagnostic is not a quiet success and not a broken
probe by default: **first check whether the code it lives in ran at all.** That distinguished
"the mask is wrong" from "the mask never executed" in one reload, without a guess and without asking
the user to look again.

**The rules.**

- **Count the paths before fixing one.** Ask what else renders, spawns or moves the same thing.
  This adapter has two draw paths, two tiers, and a spawn path plus an in-place swap — four places a
  change can need to land, and each has caught something.
- **Put a diagnostic INSIDE the change, not near it.** Then "did it work" and "did it run" are
  different lines in the log rather than the same silence.

## Occlusion has two sources, and one of them is a sprite — 2026-08-20, Emerald

**Symptom.** A painted ghost was confirmed hiding correctly behind buildings, and then did not hide
at all in tall grass.

**Cause.** This engine occludes a character two entirely separate ways:

1. **BG layers** — a metatile's top layer on a BG the sprite does not outrank. Buildings, roof
   edges, tree tops. Handled by a per-pixel metatile mask.
2. **Field-effect SPRITES** — the engine spawns one per object standing in grass and draws it above
   them. Nothing about the map's layers is involved, and the grass metatile's top layer is empty.

A painted tier needs both, and finishing the first reads exactly like finishing the job.

**How to tell which one you are looking at, in one probe:** dump the metatile under a character who
IS correctly occluded. If its top layer has content, it is the BG; if the top layer is empty, the
occluder is a sprite and the map cannot tell you anything about it.

**The rule.** **"Is it hidden?" is not one question.** Before believing an occlusion feature is
done, list the things in that game that can be in front of a character — scenery, ground effects,
weather, UI — and check that each is either handled or knowingly out of scope. A spawned ghost gets
all of them free, which is exactly what makes the painted tier's gaps easy to miss.

## An adjustment that changes nothing is evidence about the MECHANISM — 2026-08-20, Emerald

**Symptom.** A painted ghost was hidden too much by tall grass. The bound controlling how far the
grass could rise was adjusted, twice, and the user reported no change either time. Both times the
response was to reason harder about which pixel rows ought to be covered.

**What that should have said immediately.** A value that makes no difference when changed is not a
wrong value -- it is a value that is not being read. "The clip is set wrong" and "the clip never
applies" predict the same screen and are separated by one experiment, not by more thought.

**What ended it.** A deliberately WRONG build: the bound set so far in one direction that the result
could not be mistaken -- grass unable to rise above the character's feet at all. One look
distinguishes "the clip works and the number is wrong" from "the clip does nothing". It also
happened to be the correct answer, which two rounds of pixel-row reasoning had not reached.

**The rules.**

- **When a change produces no visible difference, test whether it applies at all** before changing
  it again. Set it absurdly, or log it. Two rounds of "no change" is already one too many.
- **A deliberately wrong build is a cheap instrument.** Pushing a value to an extreme makes the next
  observation binary, and a binary observation cannot be over-interpreted.
- **Vary the condition before generalising a measurement.** The same feature produced a second trap:
  the engine's grass sprites were captured while the player walked DOWN, which supported both "the
  lower tile draws in front" and "the tile being entered draws in front". Both were adopted in turn
  and both were wrong. One capture walking the other way would have killed both.

## A watchdog that names what it caught — 2026-08-20, Emerald

**The problem it solved.** A ghost stopped following entirely and stayed stopped. `ghostIsIdle`
already cleared a movement that FINISHED; nothing handled one that never does, and a blocked ghost
is never issued another step, so it strands for the rest of the session.

**Why a plain watchdog would have been a mistake.** Freeing the ghost after a timeout fixes the
symptom and hides the cause -- the fault becomes "occasionally the ghost lurches", which is far
harder to chase than "the ghost freezes". Logging the action id when it fires turned it into a
finding within one reload:

```
a ghost was stuck 61 frames in movement action 0x69 -- freeing it
a ghost was stuck 61 frames in movement action 0x6D -- freeing it
```

0x69/0x6B/0x6D are `ACRO_POP_WHEELIE_*` and `ACRO_END_WHEELIE_FACE_*` -- wheelie transitions that a
ghost cannot complete, presumably because they wait on `gPlayerAvatar.acroBikeState`, which only the
player has. That is now a written-down question instead of an intermittent glitch.

**The rules.**

- **A recovery mechanism must report what it recovered from.** Otherwise it converts a loud failure
  into a quiet one, which is worse.
- **Pick the timeout from what the game does, not from taste.** A step is 16 frames, the fastest 4,
  a ledge jump about 24 -- so 60 can only catch something genuinely stuck.

## Emerald: a ghost that reports the right pose and DISPLAYS the wrong one (2026-08-20)

**Symptom.** Idle on the Acro Bike, the spawned ghost wore the frame it should only have while
rolling -- *"it looks as if its tilted while idle, due to the 'while moving' animation making the
sprite move a bit back/forth left/right while pedaling"*. Facing up or down; the side-on frames hide
it, which is why it survived a left/right-only test. Correct for a moment after every script reload,
then wrong again after the next move.

**Why every existing trace denied it.** Player and ghost agreed on *every struct field* -- both on
animation `4/3`, unchanged for 180 frames. The adapter's `MESHGHOST_EMERALD_ANIM_TRACE` compares
those fields and the OAM entries, and it saw nothing.

**Cause.** An object event's frame image is copied into its own OBJ VRAM range when its animation
ADVANCES. A ghost standing still advances nothing, so it reported the standing pose and went on
displaying the last rolling frame it had been handed. The reload "fixed" it because the spawn path
does its own frame copy.

**Fix.** Copy the frame the peer is actually displaying when the ghost settles -- and **only once
the engine has let go**. A peer stopping does not stop the ghost: it is still a step or two behind
and keeps taking catch-up steps, each of which copies a rolling frame over ours. The first version
copied during that catch-up, measured `differing: 0`, and was then overwritten -- which the user saw
exactly: *"it only looks correct after stopping and then changing a facing direction"*, the turn
being the next thing to hand the tiles one last copy. Gate on `movementActionId` back to NONE.

**The method, which is the durable part: COMPARE THE TILES, NOT THE FIELDS.** When the fields all
agree and the screen does not, read the two sprites' OBJ VRAM ranges and count differing bytes --
`probes/posediff.lua`. It reported 120 of 512 while every field matched, and 0 after the fix.

## Emerald: one tile of bike travel cost the ghost a whole pedal cycle (2026-08-20)

**Symptom.** *"When moving a single tile, its 'over animating', the characther is not supposed to
wiggle from just 1 step, only when constantly biking in 1 direction"* -- spawned tier only.

**Cause, and it was in a table rather than in any animation code.** `FACE_ACTION` is
**walk-in-place-fast**, chosen deliberately in 2026-08-18 because that is how a walking player turns
(`PlayerTurnInPlace`), and a static `FACE_*` pose made a ghost snap round without animating. A RIDER
never turns on the spot -- turning is part of moving -- and a player stopped on the Acro Bike reports
the static poses `0x00..0x03` throughout. So on a bike both the turn and the settle were spending a
walk-in-place animation the player never performed, and a single tile buys two of them: measured with
`probes/onestep.lua`, one tile east cost the player ONE action and two frames of the pedal cycle, and
the ghost THREE actions and four.

**Fix.** On a bike, use the static `FACE_STILL_ACTION` for the turn and the settle. Both then
complete in one frame with no animation.

**The general lesson.** A constant chosen correctly for one state can be wrong for another, and the
comment saying why it was chosen is the thing that makes the wrongness invisible -- it reads as
settled. When a state animates too much, look at WHICH ACTION is being issued before looking at the
animation code.

## Emerald: the mount/dismount pose war — five hours, three wrong instruments (2026-08-20)

The spawned ghost wore the wrong pose after getting on or off a bike, and showed it *slower* than
the painted copy. User-confirmed fixed the same day. What made it expensive was not the bug — it
was that **three separate measuring instruments were wrong before the code was**, and each wrong
instrument produced a round of confident fixes aimed at nothing. Symptom → cause → fix for each:

**1. The player-tile comparison measured garbage, including its zeros.** `posediff.lua` compared
the ghost's OBJ VRAM range against the player's, taking the player's tile number from their
sprite's OAM attribute 2. That reads **0** — the player draws through a subsprite table with the
struct's own tile entry parked — so every byte compared "against the player" was whatever lived at
tile 0. Two fixes were reverted because this number said they changed nothing; one of them was
later re-applied unchanged and was the actual fix. *The tell:* the user said "walking looks fine"
while the probe insisted 376 of 512 bytes differed. When the user contradicts the meter, the meter
is the suspect — that rule is already in this file and it paid again. *Fix:* compare the ghost's
tiles against the **ROM frame** its animation names (`romDiff` in `posediff.lua`) — the ROM owes
nothing to either sprite. That column diagnosed in one reading what six field-level fixes missed.

**2. The measurement procedure erased the symptom before measuring it.** Every change to the
dev-loader's control file reloads the script set; a reload respawns the ghost; **the respawn path
loads the correct frame**. So every screenshot taken by first adding `shot_once.lua` to the target
photographed a freshly reset ghost — pixel-identical to the player, twice, in the exact state the
user was seeing wrong. The user's own screenshots finally showed the stride the agent's never
could. *Fix:* load every probe you might need in ONE set before the test starts, and never touch
the control file between the user's action and the reading. The general form is already this
file's "a diagnostic can break the thing it measures" — this is the variant where the *harness*
resets the state, and it is nastier because each individual reading is genuinely correct.

**3. Field agreement is not pixel agreement.** Player and ghost reported identical animation
number and index for 180 straight frames while displaying different frames. An object event's
frame image is only copied to VRAM when its animation *advances*; a paused sprite reports whatever
its fields say while displaying whatever was last copied. Every trace this adapter had compared
fields. *Fix:* the tile/ROM comparison above, now a standing probe.

**With honest instruments, the actual bugs took minutes each:**

- **The swap loaded a mid-transition frame and pinned it.** `swapGhostGraphicInPlace` sampled
  `sanim`/`sidx` from the wire at swap time — mid-transition, often a stride — and the
  paused-arrival meant nothing ever repainted it. Fix: the settle. A graphic change now arms
  `needsSettle` + `settleStatic`, and the **engine** sets the pose via the static face action —
  the user's own observation named the mechanism: *"it does get the correct/proper pose if you
  mount/dismount and then move 1 tile afterwards."* A settle is a zero-motion step.
- **The swap started an animation nobody was playing.** It set `animBeginning` unconditionally, so
  a standing peer's swap played a walk/pedal cycle out of nowhere until the settle caught it. Fix:
  gated on the peer's own paused bit — a paused peer's ghost arrives paused; a rod cast still
  animates.
- **Two latency sources, measured by frame-by-frame screenshot burst** (player changed at frame
  22, ghost at 29): the "never interrupt a half-played step" gate deferred swaps behind catch-up
  steps (fixed: non-fishing swaps land mid-step; the gate was measured in for fishing's offset and
  stays for fishing), and the sender's 6-frame graphic hold (fixed: skipped for the six known
  offset-free graphics — walker/Mach/Acro both genders — kept for anything else).

**The meta-lesson, worth more than any fix here: when N fixes in a row "don't work", stop fixing
and audit the instrument.** Six attempts failed against bad metrics; the seventh with a good
metric was one of the six, re-applied.

## Emerald: the seam-crossing frame-killer, and the two habits that hid it (2026-08-20)

**Symptom.** After cross-map ghosts shipped, crossing a route seam made the drawn ghost vanish and
the spawned one stop following — on the far side only, healing on return. Every internal
measurement insisted the paints were happening: position right, occlusion spans full, pixels
decoded, no dim, no panel clip.

**Cause.** The cross-map rebase, defined early in the file, referenced `ghosts` and `ghostAlive` —
locals defined a THOUSAND lines below it. Lua resolves those as nil globals silently, the function
threw, and because the throw landed before `lastKey` updated, it re-fired every frame on the far
side: the whole tick died after `gui.clearGraphics()` but before both the paint and the ghost sync.
Clear-without-repaint IS "the drawn ghost vanished"; no sync IS "the spawned one stopped".

**Why it took an hour: two observability habits, both now fixed.**

- **The per-frame error guard logged to the CONSOLE only.** Every file grep was blind to the one
  line that named the bug. The guard now writes to the log file too. *Rule: any catch-and-continue
  guard must write somewhere greppable.*
- **Instrumentation was added stage by stage INSIDE the suspect path** — mask, spans, decode, each
  measured innocent — when the tick was dying before the path ran at all. *Rule: when every stage
  of a path measures innocent, check whether the path executes on the failing side before
  instrumenting a fifth stage.* The magenta-box experiment (a probe drawing raw pixels with zero
  adapter logic) was the right instinct and mis-set-up twice; what finally broke the case was
  routing the guard's error to the log.

**The two Lua traps, for the next early-defined function:** a forward reference to a later local
is a nil GLOBAL, not an error, until you call or iterate it; and this file's 200-local ceiling
pushes shared state onto tables (`genderFrames.*`), which is also the correct fix — the rebase now
reaches `ghosts` through a field registered at the local's definition site.

**Related, same feature:** the ROM-scan self-location verified candidates against the LIVE map
header, so the player crossing a seam mid-pass invalidated the pass — in roaming play the scan
retried for minutes. A pass now snapshots its target at start. *General form: a multi-frame scan
must capture what it is looking for when it starts, not compare against a world that moves.*

## Emerald: the seam-crossing pop was the CORE's, and every adapter instrument measured innocent (2026-08-20)

**Symptom.** Every route crossing: the spawned follower vanished for ~9 frames and popped back;
the drawn twin lurched sideways (its pin to the spawned sprite broke) or flickered. A static
cross-map peer sailed through untouched.

**The chain that found it, worth more than the fix.** Frame-by-frame screenshot bursts of DRIVEN
crossings measured zero missing pixels — but the user's own crossings, captured the same way,
showed the 9-frame gap plainly (83→35→53 hat pixels). The difference was never speed or timing:
the driven test's ghosts crossed alongside the player inside the coast window, the user's followed
behind. Then one log line at the despawn site ended it: `remote=false` — the peer's ENTRY was
gone from the remotes table. Nothing in the adapter deletes entries; the core's `despawn_remote`
does. The core's cross-area filter (its own 2026-08-13 ADR, correct then) turned the one-delivery
lag of an echoed `area_id` into a despawn per crossing. **The static peer was immune because it is
injected adapter-side and never passes through the core — that asymmetry was the whole diagnosis,
once the user pointed it out.**

**Fix:** `render_all_areas` in the bridge hello (contract revision, ADR 2026-08-20): the adapter
that translates maps owns area visibility; the core delivers and decides nothing.

**The rules this adds:**
- **When every instrument inside a component measures innocent, suspect the component's INPUTS.**
  Four hours of adapter-side probes (pixels, spans, flags, coordinates) were all correct — the
  data they measured was being deleted upstream between measurements.
- **A driven reproduction must match the user's SHAPE, not just their action.** "Cross the seam"
  reproduced nothing until the followers trailed the way real play trails.
- **An asymmetric survivor is a bisection for free.** One peer immune + one peer affected =
  the difference between their code paths IS the bug's address. The user handed that over in one
  sentence: *"the static ghost stays fine all the time."*

## Emerald: the vanishing hat — the panel scanner's flicker, and six innocent suspects (2026-08-20)

**Symptom.** The DRAWN ghost's hat-top vanished at Mach speed, sustained, downward rides only,
restored on stopping or turning. The spawned ghost beside it: never affected. User-confirmed fixed
the same evening, including the hardest case (full speed built before a seam, descent through it).

**Cause.** `tiering.scanPanel()` reads BG0's tilemap with no notion of the map-name banner's
mid-flight tilemap redraws: riding at speed it flickered between "no panel" and "panel rows 0-4"
every few scans. Those rows are screen y 0-39 — exactly the band a TRAILING ghost's hat occupies
when the player rides DOWN (the follower trails up-screen). Riding up, the follower trails
down-screen, outside the band: the entire direction asymmetry, which the user kept correctly
insisting on, was geometry. The clip is drawn-tier-only by design, which is why the spawned ghost
never flickered — the second correct user observation that named the subsystem.

**Fix, two layers in `scanPanel`:** rows only clip when present in two consecutive scans (a real
panel is rock-stable), and rows 0-4 with LEFT-side spans — the banner's home, START menu spans
start right of midscreen — need a five-scan streak. An intermediate attempt gated those rows to a
time window after a map change instead: wrong, because riding away from a fresh crossing is
exactly when the user tests, so the window re-admitted the flicker for their whole ride. Stability
is the discriminator, not time.

**The six suspects that measured innocent first, in order — the expensive part:** occlusion spans
(384/384 kept, always), the screen edge (never nearer than y=28), the walker fallback (0 firings),
the ROM art (all twelve fast-family frames carry full hats — `probes/framedump.lua`), the frame
resolution (raw anim commands logged clean), and the emitted runs (min row 9, matching the art's
own top row exactly). The instrument that finally pointed upstream was `clipped=` — a counter that
already existed — read next to a per-frame panel-rows dump.

**Rules worth keeping:**
- **"Which direction breaks it" is data about GEOMETRY.** Down-only + drawn-only intersected to
  one subsystem before any code was read: something clipping the top screen band, painted tier
  only. The user supplied both halves; the mistake was not intersecting them sooner.
- **A visible ruler beats an invisible log when the user is the sensor.** One magenta line at the
  paint row let the user report the box-vs-art relationship directly — and its "1-1.5 heads above"
  reading turned out to be NORMAL (the art starts 9 rows into the box), which retired a whole
  false lead in one look.
- **When a fix depends on when the user tests, the fix is wrong.** The map-change window failed
  precisely because the user's habits sat inside it. A structural discriminator (stability) does
  not care who is testing.

## CI: "could not find a port free for both tcp and udp" — the draw was rigged, 2026-08-20

- **Symptom**: three `internal/e2e` tests fail together on the Windows CI runner with
  `could not find a port free for both tcp and udp after 20 attempts`, on code that passes locally
  and passed on the same runner earlier. Second occurrence; the first was 2026-08-16.
- **Cause**: the helper asked TCP for an ephemeral port and then probed UDP on that same number.
  That is backwards. Windows' WinNAT/Hyper-V reservations exclude blocks of the ephemeral range
  **from UDP** while TCP hands those numbers out happily, so every attempt was a fresh chance to
  draw a number UDP could never have accepted. On a runner whose exclusions cover much of the
  range, twenty draws can all lose — and because it is luck of the draw, a re-run "fixes" it and
  teaches nothing.
- **Fix**: ask the OS for a **UDP** port first and probe TCP on that number. The exclusions are
  then applied by the OS rather than gambled against, and the side being probed (TCP) is the one
  with no reservations. Attempts raised 20 → 200 (each is microseconds), and the failure message
  now carries the last error, because the old one named a count and hid the reason.
- **Generalizes to**: when two resources must agree on one identifier, let the OS choose on the
  **scarcer, more restricted** side and verify on the freer one. Retrying the unrestricted side
  is just re-rolling the same bad die.

## Emerald: ghosts blinking in and out in a doorway — two peers, one object slot (2026-08-20)

- **Symptom**: with two peers in the room, standing in front of a door made both tiers' ghosts pop
  in and out continuously. Away from the door it was fine.
- **Diagnosis**: the adapter's own logs could not show it, and that is the important part —
  everything it logs is PER PEER, so two peers writing one object is invisible by construction:
  each peer's lines look perfectly correct on their own. It was found by enumerating the engine's
  object array directly from a separate probe and watching a single slot, which alternated every 8
  frames between two peers' complete states (position, facing, action, graphic).
- **Cause**: `findFreeObjectSlot`/`findFreeSpriteSlot` tested the engine's **active bit** — "is this
  in use by the GAME" — and never "is it already claimed by one of OUR peers". A doorway is a warp
  tile, so the engine culls ghost slots constantly there; a culled slot reads inactive for the
  frames between the cull and the respawn, and a second peer searching in that window is handed a
  slot the first peer's record still names.
- **Fix**: both searches skip slots claimed by any tracked ghost, and a once-a-second audit logs
  `BUG -- <peer> and <peer> both hold object slot N` if it ever happens again by another route.
- **Generalizes to**: **"in use by the engine" and "in use by us" are different questions**, and
  wherever a shared resource is allocated by asking the engine, any window in which our own claim
  is invisible to that question is a collision waiting for a second consumer. Sprite slots, VRAM
  tile ranges and object slots all have this shape.
- **Second trap, paid for in the same pass**: this file is against Lua's **200-locals-per-chunk
  ceiling**. A new top-level `local function` failed the whole script with `too many local
  variables (limit is 200)` and the adapter simply did not load. Locals inside a function are free,
  so the claim scan is written as two inline loops on purpose — do not tidy it into a helper.

## Emerald: "laggy while moving" — a cull→respawn loop, console lines, and probes (2026-08-20)

- **Symptom**: the game chugging while running around, worst *"in 2 places consistently"* (the
  user's own observation, which beat the profiler to the cause). Scripted A/B ride: 45.9 avg fps,
  dips to 15, against a bare-emulator control of 58.1 / 37.
- **Cause, three stacked**: (1) **spawn churn** — the engine culls an object event that falls out
  of its view, and the adapter respawned it next frame, so a peer parked off-view was spawned and
  culled in a loop: VRAM allocation + sprite setup every cycle, 16 reclaims per ride clustered at
  the route's two seam crossings, worst frames 217ms. (2) The **reclaim message was a
  `console.log`** — a GUI append, the measured fps killer — firing exactly where the churn was.
  (3) **Per-frame probes** left loaded (hopwatch's 16-slot enumeration, the anim trace).
- **Fix**: never spawn a ghost outside a conservative subset of the visible screen (±8x/±7y of the
  player) — outside it the engine deletes the object anyway, so the spawn bought nothing; reclaim
  lines go to the log file only; probes come off when not answering a question. After: 56.9 avg,
  worst Lua frame 5ms, zero reclaims, user: *"it feels way better now"*.
- **Exonerated by A/B, not guessed at**: the BuildOamBuffer execute hook (52.0 without vs 52.6
  with) — the "obvious" suspect was innocent. The remaining transition hitch is VANILLA: the bare
  control dips to 37 on the same seam legs with no scripts loaded.
- **Generalizes to**: don't allocate what the engine will immediately free — a spawn decision has
  to ask "will this survive the engine's own housekeeping?", not just "is there a slot".

## The dev loader shares ONE Lua environment — an unset flag keeps its old value (2026-08-20)

- **Symptom**: an A/B run "with compare mode off" showed compare mode's exact cost profile; the
  anim trace ran on after being "turned off".
- **Cause**: `bizhawk-dev-loader.lua` loads every target into one shared environment, so a global
  set by an earlier flags file survives every later swap. A flags file that merely *doesn't set*
  a flag inherits whatever the last session set it to — "not mentioned" is not "off".
- **Fix**: the session flags file sets EVERY dev flag explicitly, false included.
- **Generalizes to**: any isolation run under the dev loader is invalid unless the flags file is
  exhaustive. Check the adapter's own `PROBE FLAG IN USE` startup lines — they say what is
  actually on, which is the ground truth the flags file only requests.

## Emerald: a NULL sprite callback is a SOFT RESET, not a glitch (2026-08-21)

**Symptom.** Building a real shadow sprite for a spawned ghost restarted the game on every jump --
user, 2026-08-20: *"everytime i jump with the bike, the game restarts now"*. It was switched off at
the door and stayed off.

**The theory recorded at the time was wrong, and plausibly so.** The adapter blamed the tile
allocation: a bad `SpriteFrameImage` byte count overrunning OBJ VRAM. That is a real failure mode,
this project has had a garbled-NPC incident from a tile range freed at the wrong moment, and
"corrupting VRAM ends in a reset" sounds right. It was innocent -- the frame is 64 bytes and two
tiles, now logged and range-checked at spawn so the next reader does not have to wonder.

**Cause.** The sprite was built with `callback = 0`, reasoning that the engine's own callback would
re-find its object by localId and follow the player. `AnimateSprites` (`src/sprite.c:308-322`) calls
`sprite->callback(sprite)` for EVERY sprite with `inUse` set and **has no null check** -- it never
needs one, because `sDummySprite` seeds `SpriteCallbackDummy` and `CreateSpriteAt` always copies the
template's. A zero there is a call to `0x00000000`: the GBA BIOS reset vector.

**Fix.** `SpriteCallbackDummy` (`08007428`, `pokeemerald.map` and `.sym`; the bytes there are
`70 47` = `bx lr`), checked at spawn rather than trusted -- on a relocated ROM that address is
something else, and the entire point of this entry is that a wrong callback is a reset.

**The method worth keeping: a RESET is a different CLASS of evidence from a glitch.** Corrupt
pixels, a wrong palette, a sprite in the wrong place -- data faults, and VRAM is the right place to
look. A reset means control flow left the program: a bad function pointer, a jump to an unmapped
address, a smashed stack. On a GBA, "the game restarts" is very nearly a signature for a call to
zero. Sorting the symptom into the right class first would have saved a day and a wrong write-up.

## Emerald: the frame rate went to ~1fps, and it was the ALLOCATOR, not the drawing (2026-08-21)

**Symptom.** After a session of dust/shadow work: *"feels like its chugging at like 1fps"*.

**Isolation, not theory.** Two guesses had already been spent, so the next move was subtraction:
`git checkout` the committed adapter in place, reload, ask. Smooth -- so the cost was in that
session's changes, mechanically and in one reload.

**Cause.** `allocSpriteTiles` imitates the engine's allocator by walking the 1024-tile OBJ bitmap,
so a **failed** call is the most expensive call it can make. Failures were not cached, so every live
dust puff and every jumping ghost re-ran that walk **every frame** -- and with three tiers up, OBJ
tiles are the first resource to run out, making the failing case the normal case on a busy map
rather than a rare one.

**Fix.** Cache negative results with a slow retry, cleared on the area change with the positive
ones. Separately, a 64-sprite scan for a live dust sprite (to copy its palette) had become
per-puff-per-frame once the trail existed; replaced with the engine's own `sSpritePaletteTags`
lookup (`03000CF0`, 16 entries), which is cheaper AND correct when no neighbour happens to be
landing.

**The rule: an expensive FAILURE path is the one to audit, not the expensive success path.** A cache
that only remembers successes does nothing exactly when the system is under pressure. Re-measured on
the stressed path -- 30s of continuous hopping, all three tiers -- `lowest 58.0, average 60.0`.

## Emerald: dressing a ghost in a direction its body is not performing (2026-08-21)

**Symptom.** A ghost turning while hopping looked wrong in a way three reports circled without
naming: *"facing the wrong direction"*, then *"stuck facing the direction it starts the jumping
with"*, then *"doing some extra/weird animation before swapping direction"*.

**Five attempts, four of which made it worse.** The turning point was writing them out as a table
(config vs outcome), which showed every attempt since the first had been fixing what the first one
caused. Attempt 1 silenced the animation mirror during jumps; that removed the only writer able to
turn a ghost at all, because a held-B hop is ONE repeating action so the engine never re-reads a
direction on its own, and `ghostIsIdle` is false for the whole of a continuous hop, closing every
other path in the same stroke.

**Cause, once measured** (`probes/facing_probe.lua` -- both characters' animation number, frame
index and both flip bits on one line):

```
P face=up act=75 anim=21 | G face=right act=77 anim=23   <- still hopping right, correct
P face=up act=75 anim=21 | G face=right act=77 anim=21   <- hopping RIGHT, wearing the UP sprite
P face=up act=75 anim=21 | G face=up    act=75 anim=21   <- action adopted, consistent
```

The mirror copies the peer's animation number instantly; the ghost's ACTION cannot change until its
bounce ends. Three frames of travelling one way dressed for another, every turn.

**Fix.** Mirror freely while both are performing the SAME action -- that is what keeps a pedal cycle
in step -- and stand aside while they disagree, leaving the engine to animate the hop the ghost is
actually doing.

**Two methods worth keeping.** When a fix makes a symptom CHANGE rather than go away, suspect the
fix. And an object's `facingDirection` is not what a character looks like -- the sprite's ANIMATION
NUMBER is, plus the hardware flip; two fixes were reasoned out from the object field while it was
already correct.

## Emerald: `sprite->hFlip` is a BASE, not the flip (2026-08-21)

**Symptom.** A ghost facing the mirror image of the peer -- but only after the animation next
advanced, which is why it survived a visual check.

**Cause.** `SetSpriteOamFlipBits` (`src/sprite.c:1246-1251`) computes the on-screen flip as
`hFlip ^ sprite->hFlip`: the struct field is a BASE that the animation command's own flip is XORed
against. A held-frame fix set the struct field AND the OAM bit, which reads correct for exactly as
long as the sprite stays paused and inverts the moment the engine advances that animation again.

**Fix.** Write the OAM bit only, as the engine does. Measured: player `hflipSpr=0 hflipOAM=1`,
ghost `hflipSpr=1 hflipOAM=1` -- the same picture now and the mirror image later.

## Emerald: a ghost that WALKS a tile the peer JUMPED gets no ground effects (2026-08-21)

**Symptom.** *"none of the ghosts have a shadow or dust, when doing the side hop"* -- and after the
shadow was fixed, the spawned ghost still had no dust.

**Cause, in two layers.** The Acro Bike's side hop is **not** an `ACRO_*` action:
`AcroBikeTransition_SideJump` (`src/bike.c:639-664`) calls `GetJumpMovementAction`, i.e. the plain
`JUMP_*` family at **0x42..0x45**, and the adapter's jump range started at 0x46 -- reading the ACRO
block alone could never have found it. Deeper: 0x42..0x45 was in neither the in-place nor the
travelling list, so the ghost never PERFORMED the hop, it stepped to the tile. The engine raises
landing dust from a jump FINISHING, so a ghost that walks the tile has nothing to raise it. Measured
over a run of side hops: **19 dust sprites, every one at dx=0** -- the player's own, none for the
ghost.

**Fix.** Perform the action verbatim, like a ledge hop, and let the engine give the ghost the arc,
the dust and the landing. Painting a puff ourselves would have hidden the real defect.

**Two consequences, both the engine's own mechanism.** A side hop travels sideways WITHOUT turning,
and the engine says so with `facingDirectionLocked` set *before* the jump is issued -- `InitJump`
opens with `SetObjectEventDirection`, which would otherwise turn the character. And that lock must
be released when the peer stops side hopping, not when the ghost next stands still: held too long it
pins facing through the steps that follow (`AcroBikeHandleInputSidewaysJump`, `src/bike.c:518-523`,
releases it on the input tick after the jump).

**The rule: "it has no X" is often "it never did the thing that produces X".** Two rounds went into
where to draw a puff before anyone asked whether the ghost was jumping at all.

## Emerald: a remembered riding style outlived the peer's actual one (2026-08-21)

**Symptom.** *"the spawned ghost is also 'jumping/doing the dust' when just riding left/right on the
bike normally"*, and later the same shape again with wheelies.

**Cause.** `lastAcroBase` is a fallback for the frames where a peer has already stopped while the
ghost still owes a tile. It remembered whichever acro family came last -- including the hop families
-- and was consulted *before* `base`, which is derived from the peer's CURRENT `movementActionId`.
One wheelie hop therefore turned every later catch-up step into a hop, dust and all.

**Fix.** Never remember a hop family, and let live data beat remembered data: where `base` exists it
wins, and the memory is dropped outright.

**The rule: a fallback must never outrank the real thing.** A cache of "how this peer moves"
consulted before "what this peer is doing right now" is not a fallback, it is a stale override.

## Emerald: the ghost stopped hopping when it had nothing to cross (2026-08-21)

**Symptom.** *"its turning around a bit slow while jumping around and changing facing direction"* --
the last thing between the Acro Bike and finished, and the one most tempting to write off as
network delay.

**Why it was nearly recorded as a known gap, wrongly.** The reasoning was that neither the player
nor a ghost may change hop direction mid-arc -- true -- so a turn waits for a bounce boundary, and
the ghost's boundaries sit a wire-delay behind the player's. That story is coherent, matches the
symptom, and is exactly the kind of explanation that closes an investigation. The user refused it on
the project's own rule: *"the player can, so the ghost must ... no excuses for not making it match"*.

**Cause, measured in one pass** by frame-stamping `probes/facing_probe.lua`:

```
f=240 P=77 G=73     peer starts hopping right
f=243 P=77 G=FF     ghost action NONE -- idle, not mid-bounce
f=251 P=77 G=77     adopted, eleven frames late
```

The ghost was FREE at 243 and did nothing for eight frames. The wheelie-hop families are handled as
animation-only, so those hops are performed only as part of covering a tile -- caught up with the
peer, the ghost stopped bouncing and waited for ground to cross, and since a turn is only adopted
when an action is issued, the turn waited for that step too. None of the eleven frames was the wire.

**Fix.** A peer who is hopping has a ghost that is hopping: re-issue the peer's hop each time the
ghost comes free, which keeps its bounces in step with the peer's rather than on a grid of its own.
Re-measured: adoption gap **0 frames**, and **zero** frames of `act=NONE` across the capture.

**The rule: "it is the network" is a hypothesis, not an explanation, until a frame counter says so.**
Latency is the most available excuse in a multiplayer project and it costs nothing to state; here it
was wrong, and one frame-stamped capture separated eight frames of adapter stall from a wire delay
that measured zero.

---

## 2026-08-21 (later) -- method notes from the water/warp session

Five defects in one sitting, four found by the user with three renderers on screen. The fixes are
in `verified.md`; what follows is how they were FOUND, which outlasts them.

### A compensation is only measured where it was measured

The painted tier's two ways of hiding a ghost through a transition -- the invisible bit on the
player's sprite, and scene brightness -- were both built and confirmed on a HOUSE DOOR. A cave
mouth is a warp with **no door animation**, so the invisible bit never sets, and it fades to
**white**, which a downward-only brightness ratio reads as a perfectly normal scene. Neither
mechanism fired and nobody had ever asked whether they would.

**The move:** when a compensation has a gate, enumerate the situations that reach it before
believing it covers them. "Confirmed on screen" names one situation, not a class.

### A ratio is the wrong SHAPE for a blend, and the wrong shape cannot be tuned

`live/ROM` clamped to 1 can only express fading toward black. The engine's fades are
`BlendPalette` -- a move toward one target colour -- so fitting `live = a*rom + b` recovers the
whole family (black, white, cave tint, weather, night) in one expression. **A gate that is blind
in one direction is a modelling error; no threshold fixes it.**

### COMPARE MODE PINS, so it is blind to everything about the unpinned path

Both self-drawn tiers took a peer's jump arc from the spawned sprite they are pinned to. An
overflow peer has no spawned sprite, so it slid across ledges with no arc and (painted) no shadow
-- and **the mode built for comparing renderers is the one mode that cannot show this**, because
pinning is what it does.

**The move:** every quantity a tier reads from the pinned source needs an explicit answer for
"where does this come from when there is nothing to pin to?", and that answer can only be tested
with compare mode OFF. The same applies to any future pinned comparison.

### A local declared BELOW a function is a nil global inside it -- twice in one session

This file already carries the warning, and it was still walked into twice on the same afternoon.
The second one referenced `SURFING_GFX` from a helper defined ~200 lines above its `local`
declaration; it threw once per frame from inside the draw path, aborted the whole tick, and took
the painted ghost off the screen along with the hardware tier's reflection. The user saw it as
*"the drawn ghost is not visible, and the OAM lost its reflection ? did you break/regress
something ?"* -- i.e. **a scope slip presents as a feature regression, not as an error**, because
the error goes to a log nobody is watching.

**The move:** when adding a helper high in this file, check every non-local name it uses against
where that name is declared -- and read the log for `frame error` before believing any report about
what is or is not on screen. It is the first thing to grep, not the last.

### Ask the ENGINE'S OWN SPRITE for ground truth, not the decompilation

Two questions were settled in one read each, with no derivation to get wrong:

- *"where does a reflection actually go?"* -- read the live reflection sprite's `pos1 + ctc + pos2`
  against the player's: drawn top 208 against 238, i.e. `height - 2`, exactly.
- *"is our OAM entry the same as the engine's?"* -- dump both entries and decode them. Ours came
  back **byte-identical in geometry** to the engine's own (`y=86, 16x32, affine=1, matrix 0,
  palette 1`), which retires a whole class of "it looks slightly off" without another guess.

**The hardware tier is measurable in a way the painted one is not**: its output IS OAM, so it can
be compared to the engine's output field by field. Use that before asking anyone to look.

### A savestate load orphans field-effect sprites, and the orphan sweep cannot see them

Loading a state rewinds the GAME's sprites but not the adapter's Lua bookkeeping, so a blob from
the restored state survives alongside the one the adapter then makes -- and it keeps following the
object event id it names, which is now the new ghost. Two blobs on one ghost. The object-slot
orphan sweep cannot catch it because **a blob has no object event**; the engine's own
`ResetSpriteData` clears it at the next map load, which is what the user saw: *"the extra blob went
away if i went into a house and out again"*.

Dev artefact, not a shipping bug -- but the count is what said so (`objEvent=0` is the player's,
`objEvent=15` the ghost's, one each), not the reasoning. **That verdict was too narrow: the same
event breaks OBJ TILE OWNERSHIP too, and that half IS a shipping bug** -- see the next entry.

### A driven run needs the test kit loaded, or it measures an encounter

`grant_test_kit.lua` tops Repel up every half second while it is loaded, and it was not in the
loader set. A ten-second scripted surf walked into a wild battle, and the probe run captured the
battle-transition sprites instead of ripples. **Anything that drives the player for a measurement
should have the kit in the same target set.**

### Never judge a subject against an instrument you have not checked -- the costliest lesson here

A long stretch of 2026-08-21 went into "the drawn ghost has no reflection a tile from the water",
comparing the painted tier against the SPAWNED one -- while the spawned one was itself stuck in the
wrong pose and therefore showing a different picture. Every comparison was between two unequal
things, and every conclusion drawn from it was wrong. The user ended it in one sentence: *"you are
trying to test/compare to something, that is not displaying it due to another issue."*

Fixing the pose first made the same question answerable in a single measurement.

**The move:** before comparing tier A against tier B, establish that B is correct -- against the
ENGINE, or against a fact that does not depend on B. `CLAUDE.md` already says the instrument is the
suspect before the subject; this is that rule applied to a renderer being used as a reference.

### Measure the target's BEHAVIOUR, not just its position, before changing how you draw it

The reflection's horizontal ripple took two wrong fixes on the user's screen -- one that inflated a
one-pixel run to three, one that froze it in place -- because each was reasoned from the formula
rather than measured. **Six screenshots of the engine's own reflection, diffed against each other,
gave the width AND the movement in one step** (one pixel, alternating between two columns), and the
correct rule followed immediately.

A single frame answers "where is it". Only several frames answer "what does it DO", and a scaling
rule is a claim about what it does.

### Fields are not pixels

A ghost whose `animNum`, `animCmdIndex` and `animPaused` all read correct was still showing the
wrong picture, because the engine had copied a different frame into its tiles and then held there.
Reading back the actual VRAM art rows is what settled it -- `artRows=11..31` where the requested
image's own art is `10..30`.

**Asking "what did I set?" is not asking "what is on screen?"** For anything tile-based, read the
tiles.

### Reproducing a hardware transform: invert ITS mapping, don't transform your bounds

The ripple's horizontal scale was wrong twice because both attempts scaled the SOURCE run's
endpoints onto the screen. Hardware does not work that way. A GBA affine sprite walks the
DESTINATION and, for each screen pixel, samples `texture = (x - cx) * a / 256 + cx` and truncates.
Inverting that gives the destination range covering a source run `[x1, x2]`:

```
x_dest in [ cx + (x1 - cx)*s , cx + (x2 + 1 - cx)*s )        s = 256/a
```

— ceil at both ends, far edge as `x2+1` then brought back. **The same rule at both ends is what
preserves width**, and the two failures are each diagnostic of a specific mistake:

| What was done | What it looks like on screen |
| --- | --- |
| different rounding per edge (`floor` / `ceil`) | narrow runs INFLATE, and breathe as the scale swings |
| same rounding, but forward-mapped (nearest-neighbour) | width correct, but a small feature never moves — sub-pixel shifts round away |

**Generalises past this one case:** whenever reproducing something the PPU does, write down what
the hardware does per destination pixel and invert it. Transforming source extents is a different
operation that happens to agree in the easy cases.

### A diagnostic that re-implements what it measures will lie the moment one of them changes

The reflection's ink range was logged by a line that recomputed the flip itself rather than
reporting what the draw had done. The draw was fixed; the log was not; the next reading showed the
OLD numbers and briefly read as "the fix did nothing". Two minutes were spent doubting a correct
fix.

**The move:** either have the diagnostic report values the code actually used (compute once, pass
it to both), or change them in the same edit — and treat "the numbers did not move at all after a
change that should have moved them" as a suspicion about the instrument first.

## Emerald: a savestate load makes us draw from tiles we no longer own (2026-08-21)

**Symptom.** The hardware (OAM) tier renders as black-and-white striped garbage after a savestate
load -- body and reflection alike -- and gets worse with each load. The user, twice: *"the OAM gets
weird after save states"*, then *"the OAM sprite broke completely now after a save state"*.

**Cause.** Everything this adapter holds about the engine describes the machine *as it was*: which
object slots the ghosts occupy, which OBJ tile ranges we claimed out of the engine's own allocation
bitmap, which hardware OAM entries we own. A state load rewinds the engine's side of all three at
once and leaves our record untouched. From the next frame we copy sprite frames into tiles the
engine has since handed to one of its own sprites, and draw our characters out of the same range.

**Fix.** Detect the load and **forget**, rather than clean up. The tell is not in the game at all --
it is the emulator's frame counter, which advances by exactly one per tick and *jumps* when a state
is loaded (either direction). On a jump: release the hardware tier without freeing, drop every
ghost record, and discard the queued tile frees. Freeing "our" tiles there would clear bits in a
bitmap that is somebody else's now -- the same identity-first rule `despawnGhost` already follows
for a map load, with the same silent consequence if ignored.

**Two lessons past the fix:**

- **It is a SHIPPED bug, not a rig one.** Loading a state is ordinary BizHawk use. The instinct to
  file anything savestate-shaped as a dev artefact is what left the earlier entry above half-right.
- **A savestate replay cannot judge the hardware tier.** A whole diagnosis nearly went the wrong
  way on this: the striped garbage was filmed frame by frame off a state-load replay and read as a
  32x32-graphic bug in the tier. Re-running with the state loaded FIRST and the adapter loaded
  AFTER it -- so its bookkeeping starts from the world that actually exists -- produced clean
  frames. **Load the state, then attach the thing under test.**

## Emerald: a graphic swap left fresh tiles unwritten, and the ghost went grey (2026-08-21)

**Symptom.** The spawned ghost occasionally turns into a grey/garbled block at the start of
surfing -- *"the spawned ghost glitch out sometimes when starting surf"* -- and only sometimes.

**Cause.** A graphic change claims a NEW tile range and points the sprite at it before copying the
frame's pixels in. The frame is resolved through the peer's reported animation number -- which
belongs to the graphic the peer *just left*. Every special state carries its own animation table,
and they are not the same length (`sAnimTable_FieldMove` against `sAnimTable_Standard`), so a peer
mid-way through a high-numbered animation indexes past the end of the new graphic's table, reads
whatever ROM follows, and the copy is abandoned as unresolvable. The sprite is then drawing from
VRAM nobody has written. Whether it happened depended on which animation the peer was in when the
graphic changed -- hence "sometimes".

**Fix.** Fall back to the graphic's own first frame when the peer's animation cannot be resolved.
A ghost briefly facing the wrong way is a small, legible wrongness; a grey block is not.

**The general shape, which is the part worth keeping:** an early return is safe when it leaves the
previous state in place, and unsafe when the caller has already half-applied a change. Here the
pointer swap had already happened, so "do nothing" meant "draw rubbish". **Ask what the caller has
already done before returning early.**

## Emerald: THE PAIR was wrong -- and fixing it did NOT clear the symptoms (2026-08-21)

**CORRECTION, same day, and the reason this header changed.** The entry below was written when the
probe went clean, and it presents the incoherent pair as THE single cause -- a claim the user never
confirmed and the screen then contradicted: *"its not fixed. the drawn ghost still goes away for a
tiny bit... and the spawned ghost still does the grey/flash."* The pair was real, measured, and
worth fixing -- but it was not the (whole) cause of either symptom. The entry stands as a record of
a correct measurement wrongly promoted to a diagnosis, which is itself the pitfall: **a probe
going clean is not the defect going away, and writing "cause" before the user has watched the fix
is the same violation as writing "confirmed" on a build.** What the pair fix provably did (stored
state and VRAM checks clean across a scripted run) is in the commit; what it did on screen is: not
enough.

**Symptoms, reported as three separate things across an hour:** the spawned ghost flashes grey at
the start of surfing, every few attempts; the drawn ghost *"disappears for a bit"* at the same
moment; the hardware (OAM) copy is perfect throughout. That last one is not a footnote — it is the
clue that solves the other two.

**Cause, single.** The receive path adopted a peer's GRAPHIC one update late (a debounce that
exists for fishing, whose sprite offset lands four frames after its graphic) while adopting the
peer's ANIMATION NUMBER immediately. For one update per transition the ghost therefore held a
(graphic, animation) pair the player is never in. An animation number only means something for its
own graphic -- the tables differ in length -- so:

- the SPAWNED tier resolved that pair to a frame that does not exist and drew unwritten VRAM (grey);
- the PAINTED tier could not resolve it either, gave up, and fell back to painting a walker;
- the HARDWARE tier was fine **because it resolves the graphic and the animation together itself,
  every frame, instead of consuming the stored pair**.

**"One tier is perfect" is a diagnosis, not a curiosity.** Three tiers rendering the same peer is a
built-in control: whatever the healthy one does differently IS the fix. It was in front of me for
several cycles while I wrote per-tier defences.

**What it cost, and the rule that would have saved it.** Four fixes were written before the pair
itself was measured -- a fallback frame, a mirror gate, a send-side hold, an action deferral --
each plausible, each treating a consumer. The measurement that ended it took one probe line: log
the PLAYER's own (graphic, animation) every time either changes. It goes `gfx=3 anim=0/0..0/4` then
straight to `gfx=2 anim=20/0`; the intermediate pair never happens. **When several consumers of one
piece of state each break differently, measure the STATE, not the consumers.**

**A second-order trap, worth its own line:** a savestate replay driven by a script is
DETERMINISTIC. Eight "attempts" produced byte-identical screenshots, which reads exactly like "the
bug is fixed" and means "the bug was never given a chance to appear". An intermittent defect that a
person hits every two or three tries is being sampled by their TIMING -- so a driver has to vary
its input phase per round or it is running one attempt N times.

## Emerald: the mount-blob saga — every authority for "where" lies during a transition (2026-08-21)

Placing one sprite (the surf blob a mounting ghost jumps onto) took five attempts, each defeated
by a different lying authority. The list is the lesson:

1. **The ghost's own coordinates** — the swap runs before the jump is issued (the swap-pending
   gate orders them), so they still name the land tile.
2. **The wire position** — the sender publishes the SMOOTHED glide, not raw coordinates, so
   during a jump it lags at the origin. Never treat a wire position as a discrete destination.
3. **`spawnSurfBlob`'s screen math** — carries the two camera terms that only cancel while the
   camera is at rest (`documentation.md` warned about exactly this sprite), and a mount jump is
   precisely when the camera moves. Logged born at the correct water TILE while the user watched
   it sit on the grass: tile bookkeeping and pixel placement are separate claims.
4. **The rider's sprite position** — engine-maintained and camera-correct, but the sprite
   ANIMATES across the jump rather than snapping, so at the accept frame it still stands ashore.
5. **What finally worked**: rider's sprite position + one tile along the jump's direction (the
   action id carries it) + the blob's measured (0,+8) seat — every term engine-maintained or
   constant.

Also met again, fourth time today: **a gate on one spawn site does nothing about the others** —
the blob had three birth sites (swap, rebuild-spawn, catch-up) and each needed the mid-mount gate;
the fix that ended the guessing was making every birth LOG its site and tile.

And the bob/arc conflation: on these tiers the body's `pos2` is the surf BOB in steady state and
the JUMP ARC mid-jump. Subtracting it from the blob to fix the jump also froze the blob's bobbing
-- *"the blob is not going up/down"*. One field, two meanings, keyed by whether a jump action is
live; handle them by state, not by arithmetic.

## Emerald: never hold an engine handle the engine can recycle (2026-08-21)

**Symptom.** Diving black-screened the GAME -- palettes zeroed, effect stuck -- after its banner
showed the wrong Pokemon. Nothing in the adapter errored; the adapter was, by its own logs,
running perfectly underwater.

**Cause.** Our underwater bobber: a faithful copy of the engine's dummy sprite, whose callback
holds ANOTHER SPRITE'S INDEX and nudges it every fourth frame. When the named slot was reused, the
bobber went on nudging whatever now lived there -- during a dive, the show-mon's Pokemon picture --
which corrupted the pic and stalled the effect waiting on it.

**The rule.** The engine may store an object id or sprite index because it owns every lifetime
involved: it creates, destroys and reuses those slots, and its effects end when it says so. We own
none of that. **Copy the EFFECT, not the data structure** -- and when the effect is already
described by something on the wire (the peer's own sprite offset, here), copy nothing at all.

**Two corollaries, both paid for the same evening:**

- The intermediate fix -- driving the same bob from Lua -- was safe but still wrong: the peer's
  offset was already being applied, so the ghost had two writers on one field and jittered.
  Before adding a driver, check whether the wire already carries the thing.
- A tier can be structurally unable to draw somewhere, and that is not a bug to fix. Our hardware
  tier lives in OAM entries 64+, where ties are broken by index; underwater the game covers the
  screen in its own semi-transparent sprites at lower indices, so nothing we put there can appear,
  and raising our priority to escape only makes the fog draw opaque around us. The answer is to
  stand the tier down where it cannot win and let another tier carry those peers.

## Emerald: a gate written for ANIMATION also swallowed a POSITION (2026-08-21)

**Symptom.** Underwater, ghosts bobbed while idle and went rigid the moment they moved.

**Cause.** The peer's sprite offset is applied inside the animation-mirror gate, which
deliberately stands aside for a walking peer -- correct for animations, because the engine drives a
moving ghost's walk cycle and mirroring on top of it puts two writers on one field. But an offset
is not an animation: underwater it IS the bob, and the engine drives nothing for our ghost there
(we deliberately do not reproduce its bobber). So the bob was gated off exactly when the peer moved.

**The rule.** When a gate exists to arbitrate one KIND of state, check what else has been parked
inside it. Animation, position, offset and graphic have different owners at different moments; a
condition that is right for one is arbitrary for the others.

## Emerald: three renderers are a control group -- use them (2026-08-21)

Twice in one session the user's report named which tiers misbehaved, and the tier they did NOT
name was the answer:

- The orange sprite appeared on the spawned and painted copies. The hardware tier -- the one that
  behaved -- was the only one resolving the surf blob's palette from its TAG through the engine's
  table instead of hardcoding slot 0. The show-mon effect had taken slot 0 for a Pokemon.
- The incoherent (graphic, animation) pair broke the spawned and painted copies while the hardware
  one stayed correct, because that tier resolves both together itself every frame rather than
  consuming the stored pair.

**When one renderer of the same peer behaves and the others do not, diff what it does differently
before forming any theory.** It is a free A/B that is already running.

## A probe written for one session leaked a home path into the repo (2026-08-21)

**Superseded as a procedure — see the 2026-08-24 hook note on the 2026-08-15 entry above.** This
is the third recorded instance of one class; the leak check is mechanical now.

Two probes written during the dive session hardcoded an absolute scratchpad path for their
screenshots -- convenient while driving the session, and a violation the moment they were
committed: this repo is public and no tracked file may carry a home directory. `CLAUDE.md`'s own
`git grep` check caught it after the commit, not before.

**The habit that prevents it:** a probe resolves its own directory (`debug.getinfo`) for anything
it writes, exactly as its log file already does -- there is never a reason for a second, absolute
path in the same script. Run the repo-cleanliness grep before committing anything written in a
hurry, not only before a release.

## Emerald: one field, two meanings — "not animating" is not "may not animate" (2026-08-21)

**Symptom.** On Shoal Cave's ice the player glides with its legs held still; the spawned and
painted ghosts stride across it. The OAM tier was correct all along, which is the clue.

**Diagnosis.** `spaused` (the sprite's `animPaused`) was already on the wire and means *the
animation is not running*. `disableAnim`, on the object event, means *this object is FORBIDDEN
one* — and unlike the first, a movement cannot override it. Everywhere else in the game the two
agree, so one bit had always been enough. `ForcedMovement_Slide` is where they come apart: it sets
`disableAnim` and then walks the character fast, which is a character crossing tiles with its legs
still. The OAM tier looked right for free because it copies the peer's `animNum`/`animCmdIndex`
straight from the wire, and those simply stop advancing.

**Fix.** Send the bit (`extras.noanim`) and let it beat the three separate things that were each
undoing it: `requestAction`'s `enableAnim` rescue, the mirror's "the engine is already driving
this graphic" gate, and the painted tier's distance-derived cycle.

**The lesson, which is general.** *When one tier of three is already correct, ask what IT is
reading.* The correct tier is a free bisection: it was consuming the peer's state directly, and
the two wrong ones were each re-deriving it. Re-derivation is where a state gets lost.

**And a rule about sticky bits.** `disableAnim` is only ever cleared by the engine through
`enableAnim`. Setting an engine flag on a ghost obliges you to clear it in the same place, on the
same path — a flag set once and never cleared costs that ghost the behaviour for the rest of the
session, which is worse than the defect it fixed.

## Emerald: a "hold the pose" fix must hold the RIGHT pose (2026-08-21)

**Symptom.** Nearly invisible, and the reason to write it down: an ice slide freezes the character
on **whatever frame the walk cycle happened to be on** when it started. Measured across three runs
the player held `10/2`, `11/0`, `11/2`.

**Why it matters.** "Freeze the animation" invites two wrong implementations that both look right
in a single test: freeze on the *first* frame of the animation, or freeze on *whatever frame this
renderer had reached*. The first is correct about a quarter of the time; the second is a different
picture from the player's every time. Neither fails loudly — they produce an intermittent,
low-grade wrongness that reads as "close enough".

**Fix.** Resolve the peer's OWN image the engine's way — anim table by `animNum`, then by
`animCmdIndex`, low half is the image index (`genderFrames.peerImageIndex`) — and check it lands in
the same index space as the tier's own table before using it. The peer's `11/0` resolved to image
7, which is `DIRECTION_ANIM.east.steps[1]`; the tier had been drawing image 2, the standing frame.

## Emerald: the drawn tier's freeze has to outlast the peer's flag (2026-08-21)

**Symptom.** With the freeze correct, the painted ghost played one extra stride *as it stopped*
(*"1 extra animation or something when stopping after gliding on the ice"*).

**Diagnosis.** The wire flag clears the instant the player's slide ends, but the painted copy is
still GLIDING across the ground that slide covered. Releasing on the flag handed those catch-up
frames back to the distance-derived cycle.

**Fix.** Latch the freeze to the glide, not to the flag, and hold a frame remembered from when it
started — by release time the peer is already on its idle frame, which is not the picture a copy
still moving should wear. Reset `gDist` too: none of the distance covered while frozen was walked,
and leaving it merely moves the same stride one step later.

**The lesson.** *A self-drawn tier is not where the peer is, so a peer's state flag is not a
schedule for that tier.* Anything gated on peer state that this tier renders with a lag has to be
released on the tier's own progress. Conspicuous here and nowhere else only because the player
animates through an ordinary stop and does not animate through this one.

## Emerald: a floor that is right for a sub-pixel gap is wrong for a real distance (2026-08-21)

**Symptom.** The drawn ghost *"doing the ending part a bit slow"* after a slide.

**Diagnosis, from `probes/tier_compare.log` rather than by eye.** The glide's speed limit is
`max(tspd, 0.02) * 1.25`. When the peer stops, `tspd` falls away and the limit drops to the
`0.02 tiles/frame` floor — so whatever ground the copy still owed was paid off at a crawl however
far it was. A slide is fast and the position stream is bursty, so after one it owed most of a
tile: **0.86 tiles closing at 0.025/frame = 34 frames, over half a second of creep after the
player had come to rest.** Fixed by holding the travelling speed as the floor until the copy has
arrived: 0.50 tiles at 0.0625/frame = 8 frames, which is exactly the 8-frame delay line this tier
reproduces on purpose, then a dead stop.

**THE PART THAT NEARLY SHIPPED WRONG, and the real lesson.** The first version assigned
`gSpd = tspd` on every frame above the threshold. But `tspd` is an **8-frame average**, so when
the peer stops it does not drop to zero — it DECAYS across the window, walking the floor down with
it and leaving the last value above the threshold: 0.023 against a travelling 0.0625. The measured
tail went 0.025 -> 0.029/frame. **A fix that moves the number by 15% is a wrong fix, not a partial
one** — and re-measuring is the only thing that says so, because by eye "still a bit slow" and
"unchanged" are the same report. Hold the high-water mark, and clear it on arrival so it cannot
leak into the next movement.

## Emerald: `goto_map` changed the map and placed nobody (2026-08-21)

**Symptom.** The user warped somewhere and could not move in any direction, on a screen of open
water with no land in it. Twice.

**Diagnosis.** The probe's header asserted that `CB2_LoadMap` runs `WarpIntoMap`. It does not —
that path is `CB2_DoChangeMap -> CB2_LoadMap2 -> DoMapLoadLoop`, and `WarpIntoMap`, the only
caller of `SetPlayerCoordsFromWarp`, is nowhere on it. The map loaded; the coordinates stayed.
Invisible because every warp had been to Mauville (40x20) from somewhere small.
Warping out of Route 126 at (45,68) into Mossdeep City (80x40) left the player outside the map in
the border fill, with `MAPGRID_UNDEFINED` on every side.

**Fix.** Write `gSaveBlock1Ptr->pos` as well, from `MESHGHOST_WARP_X/_Y` taken from the
destination's own warp event in `data/maps/<Map>/map.json`; warn loudly when they are not given.

**Two lessons.** *A dev tool that has only ever been pointed at one destination has only ever been
tested for one destination* — this one had a hardcoded Mauville default and a caller who never
changed it, so its single most important behaviour was never exercised. And **"the user is stuck"
is a bug report about our tooling**: the instinct was to reach for a savestate, which would have
hidden it. Reading what the callback chain actually does took minutes and found a week-old defect.

**One thing that needed no fixing, worth knowing:** the map load re-derives the avatar state from
the tile landed on (`GetAdjustedInitialTransitionFlags`), so a SURFING player warped onto a cave
floor arrives on foot with no blob to clean up.

## A fix named after WHERE it was found will be re-found somewhere else (Emerald, 2026-08-21)

**Symptom.** The OAM ghost invisible in Mt Pyre's fog — a bug fixed earlier the same session, underwater.

**Diagnosis.** The dive fix was correct and its predicate was `is the player underwater`, because
underwater is where it was seen. The actual cause is *the engine is tiling the screen with
semi-transparent sprites at low OAM entries*, which is also true of weather fog on dry land. The
same code, the same measurement, a second bug report.

**Fix.** Test the cause: count objMode-1 sprites among the engine's entries. `underwater` was never
a property of the failure — it was a property of the afternoon.

**The rule.** *When a fix's condition names a place, a mode, or a map, ask what is TRUE there that
breaks it, and whether that thing can be asked about directly.* If it can, ask it. A place-shaped
predicate silently scopes the fix to the one instance you happened to be standing in.

## An explanation that only fits your own case is not an explanation (Emerald, 2026-08-21)

**What was recorded underwater:** *"a semi-transparent sprite cannot blend against another sprite,
and gives up and draws opaque."* It explained the observation, it was measured at two priorities,
and it is wrong.

**What disproves it, and it was on screen the whole time:** the engine's own character is in front
of the same semi-transparent sheet, in the same frame, with no artifact. Any explanation of the
form "the hardware cannot do X" has to survive the game itself doing X ten pixels away.

**The real distinction was HOW you get in front.** The player wins at *equal priority on a lower
entry number*, which leaves the sheet's blend target unchanged. We can only win by *outranking it
on priority*, which changes the layer the blend resolves against, and then it fails. Same visible
outcome, completely different cause — and only the second one predicts that the artifact is one
opaque block **per entry rectangle** (16×32 in fog, ~3×3 tiles underwater with a wider graphic and
more entries). The user's own two descriptions, taken together, are what forced the better model.

**The habit.** When you write down a hardware or engine limit, look for the engine doing the thing
you just called impossible. If it is, your rule is about YOUR configuration, not the hardware —
and it will generalise wrongly the first time the configuration changes.

## Emerald: the painted tier is outside the PPU, so every hardware effect is its problem (2026-08-21)

**Symptom.** *"drawn ghost is not hidden in darkness/caves"* — in Granite Cave the painted copy
shines through the black while the spawned and OAM copies are correctly hidden.

**Diagnosis.** A dark cave is **Window 0**, not an overlay: the engine writes the lit span per
scanline into the scanline-effect buffer and DMAs it to `REG_WIN0H` each HBlank, so outside the
circle nothing is displayed. Real sprites are clipped by the window for free. The painted tier
paints with `gui.drawPixel` after the PPU has finished, where windows no longer exist.

**Fix.** Read the same spans and intersect each painted row with its own — one halfword per row.

**The general shape, and it is the third instance.** Everything the hardware does for a sprite,
this tier has to do for itself, and each one is discovered as a bug rather than anticipated:
occlusion by a text panel (`scanPanel`), reflection clipping to water (`reflectiveSpans`), and now
the flash window. **When adding anything to the painted tier, the question to ask is "what would
the PPU have done to this, and can I read it?"** Sometimes the answer is yes and cheap — the flash
circle is readable data. Sometimes it is no, and then the tier is the wrong renderer for that
situation (see the semi-transparent sheet entry above).

## A clip's GATE is more dangerous than the clip (Emerald, 2026-08-21)

**The trap.** The flash clip's data is a per-scanline buffer of lit spans, and an inactive buffer
reads as all zeroes — *nothing lit anywhere*. Trusting it unconditionally would not have produced a
subtle error; it would have **erased the painted tier on every ordinary map**, far from the cave
that motivated it and long after the change looked good.

**The habit.** When a new clip's "no data" state is indistinguishable from "clip everything",
confirm the effect at its SOURCE rather than inferring it from the data. Here that is
`gScanlineEffect.dmaDest == REG_WIN0H` with a non-zero `state`, so a scanline effect on another
register leaves the tier alone.

**And test the negative case, not the motivating one.** The cave is where it obviously works; the
regression lives on the ordinary map where nothing should have changed. Write the check for that
one down at the same time — `unverified.md` carries it as the thing to look at.

## Two write-only GBA registers that lie when read (Emerald, 2026-08-21)

`WIN0H`, `WIN0V` and `BLDY` are write-only. Reading them back returns garbage that looks like data:
a register dump chasing the fog showed `BLDY` swinging between plausible-looking values every
frame, and `WIN0H` reading `0x2800` in a cave whose real span was `96-144`. `BLDCNT`, `BLDALPHA`,
`WININ`, `WINOUT` and `DISPCNT` all read fine, which is what makes the bad ones convincing.

**When a display register is write-only, the live value has to come from wherever the engine keeps
its own copy** — for the flash circle, the scanline-effect buffer. Check the register's read/write
status before building an argument on a dump.

## Lua's 200-local ceiling: the adapter does not load, and almost nothing says so (2026-08-21)

**Recorded TWICE — see also "Adding one local silently unloaded the adapter" below**, whose own
title admits it happened again an hour later. It has since recurred a third time
(`unverified.md`, `d551da1`), and Emerald now sits at 197 of 200 file-scope locals, so the next
one is close. Cross-linked 2026-08-25.

**Symptom.** A change to the adapter has no effect whatsoever. The game runs, the core connects, no
ghosts appear. It reads as a networking fault, a dead relay, or an edit that silently missed.

**Cause.** A Lua chunk may declare at most 200 locals in its main body. Past that BizHawk refuses
the file: `too many local variables (limit is 200) in main function`. The dev loader prints ONE
`LOAD FAILED` line and moves on; every other script keeps loading normally, so the log looks healthy
unless that specific line is read.

**Hit four times in one session on Crystal.** The counts, measured the same day:

| adapter | lines | top-level locals |
|---|---|---|
| Crystal | 3,219 | 157 |
| Emerald | 10,496 | **198 of 200** |

**Emerald is two names away in a file three times the size** — this is not solved anywhere, and the
smaller adapter hits it first because it is denser in top-level names per line.

**Fix.** Group related values onto one table rather than spending a name each — `oam`, `COMPARE`,
`playerHistory`, `tiering`, `genderFrames`. Doing it up front is cheap; doing it while chasing a bug
(which is how every table in both adapters was born) is not.

**The general lesson: when a change to a large Lua adapter does nothing at all, read the loader log
for `LOAD FAILED` before re-examining the change.**

## A file can LOAD cleanly and then throw on every frame (2026-08-21)

**Symptom.** Two commits went out with confident messages describing behaviour that never ran. The
ghosts looked oddly *stable* — no jitter, no snapping — and the user reasonably read that as an
improvement worth keeping and asked to return to it.

**Cause.** The dev loader reports load failures and per-tick errors on SEPARATE lines
(`LOAD FAILED` vs `TICK ERROR`). A scripted revert had removed a helper the placement code called,
so the file parsed and loaded fine and then threw on the first frame, every frame. Only the
`loaded` line was checked.

**Why the symptom was so misleading:** a crashed draw tier does not blank — it stops updating. The
ghosts froze in their last painted positions and were dragged along by other code paths, which looks
exactly like "smooth, no artefacts". **A defect that removes motion can be mistaken for a fix that
removes jitter.**

**Fix.** After any reload, check for BOTH failure kinds before believing anything about behaviour —
and never treat "loaded" as "running". Same family as the read-back rule: confirm the effect, not
the acceptance.

## Lua: a use above its `local` is a silent nil, not an error (2026-08-21)

**Recorded THREE times in this file** — this entry, one 550 lines further down from the same day,
and "A local declared below its use, inside one function" (2026-08-23) — plus two more instances
logged elsewhere (`unverified.md`, `86e4ed2`). **Five occurrences of one fault.** That frequency
is the finding: it is the single most repeated defect in the project. Cross-linked 2026-08-25.

**Symptom.** The painted ghost teleported straight onto its destination tile instead of walking, and
several rounds of tuning a smoothing constant changed nothing at all.

**Cause.** `peerProg`/`peerWalking` were declared *below* the block that built the compare copies, so
those two entries resolved a nonexistent GLOBAL: both fields arrived `nil`, the sub-tile offset was
always zero, and every knob being turned multiplied a term by nothing. Lua issues no warning.

**The tell that was missed:** the same values reached the *other* overflow entries correctly, because
those are constructed further down. **Two copies of the same peer behaving differently is a scope
question, not a data question.**

**Fix.** Declare peer-derived values once, above every consumer. When a constant has no effect at
all, check that the thing it multiplies is non-nil before tuning it again.

## BizHawk's drawing layer persists: "draw nothing" leaves the last frame (2026-08-21)

**Symptom.** The painted ghost stayed on screen through both halves of a door transition — exactly
when every gate in the drawn tier was correctly refusing to draw.

**Cause.** `gui.*` output is not cleared by the script's inaction. A frame in which the tier draws
nothing leaves the PREVIOUS frame's peers on screen, frozen — indistinguishable from a tier that is
wrongly drawing. Every early return in `drawOverflow` fell silent rather than clearing.

**Fix.** Stop by CLEARING (`gui.clearGraphics()`), not by returning early, on every exit path
including the ones that "obviously" draw nothing.

**Generalises:** for any renderer outside the engine, *absence of output is not absence of pixels*.

## Crystal does not fade the OBJ palette shadow, so Emerald's lighting trick has nothing to read (2026-08-21)

**Emerald's painted tier** hides transitions by matching the LIGHTING: it compares the live OBJ
palette against the ROM palette its pixels were decoded from, so the copy dims with every fade.

**That does not port to Crystal.** `transition_probe.lua` measured a full door crossing: `wMapStatus`
went `2 -> 1 -> 2` while the OBJ palette shadow's channel sum sat at a flat **99 throughout**. This
engine does not fade through `wOBPals1`, so there is no signal to match, and copying the mechanism
would copy something with nothing to read.

**What works here instead** is the event the spawned tier already acts on — the world was rebuilt
(`lastArea` changed) — plus clearing the layer on every early return. **Before porting a solution
between adapters, confirm the SIGNAL it depends on exists in the target.**

## A ghost inherits its template's flags, and a STILL object cannot animate (2026-08-21)

**Symptom.** The spawned ghost walked correctly but never animated. Intermittent across sessions and
maps for no apparent reason.

**Cause.** `spawnGhost` copies a live NPC's whole struct as a template, `OBJECT_FLAGS1` included. On
Route 39 the available templates are `SPRITEMOVEDATA_STILL` objects (the fruit tree, the Tauros),
whose flags are exactly `FIXED_FACING | SLIDING`. `SetFacingStepAction` tests `SLIDING` FIRST and
jumps to `SetFacingCurrent` without advancing `OBJECT_STEP_FRAME`, so the walk cycle never runs;
`FIXED_FACING` likewise stops `InitStep` writing `OBJECT_DIRECTION`.

**Measured**: `posediff_probe.lua` caught the ghost at `frame=0` through entire steps while the
player's ran 7, 8, 9, with `flags1=0x2E`. After clearing the two bits, ghost and player match frame
for frame.

**Why it looked intermittent:** it depends on which NPC the map offers. A room with a walking NPC
passes; a route full of scenery fails. **This was found only because the user insisted on testing on
the busiest map in the game.**

**Fix, and the general rule: a spawned entity's flags must describe what IT is, not what its donor
was.** Normalise every inherited field that carries behavioural meaning; do not merely OR in your own.

## Instruments that agree with each other can share a blind spot (2026-08-21)

Three separate detectors reported clean while the user reported twitching:

- a per-frame twitch detector (jumps > 4px between frames): **0 hits** — because a 16px jump on the
  exact frame a tile changes is not a discontinuity *between* samples, it IS the sample. **A detector
  tuned for noise cannot see a perfectly regular defect.**
- a pose differ (position error vs the player): **0px residual** — it measured POSITION while the
  fault was in TIMING (step-start lag swinging 0–6 frames) and in the IMAGE (which sprite frame).
- tier counts (`1 drawn, 0 spawned`): correct numbers, wrong question — a count cannot say WHICH peer
  ids are in which table, and the user was watching two copies of one peer.

**The rule that would have saved the evening:** when the user reports something the instruments deny,
add an instrument that measures a DIFFERENT QUANTITY, not another one measuring the same quantity
more precisely.

## The dev rig's update rate is part of the experiment (2026-08-21)

**Symptom.** Ghost motion became visibly worse after a clean restart of the rig; an hour was spent
attributing it to the adapter.

**Cause.** The restart used the relay's defaults (`-send-hz=20`) instead of the documented dev rig
(`-send-hz=100` plus the core's `-min-send=10ms`). `run-relay-loopback.bat` even carries a comment
saying 20Hz silently overrides the core's faster rate. At 20Hz a peer position arrives every 3 frames
while a step takes 8; the two do not divide, so step starts beat irregularly.

**Measured**: step-start lag spread `0–6 frames` at 20Hz versus `3–5` at 100Hz. A varying lag looks
like snapping; a constant one looks like following.

**Fix.** Start the rig from the `dev-scripts/*.bat` files, or copy their flags exactly. **Rig settings
belong in the bug report** — a rate change is an experiment change.

## `extras` is opaque, so nothing that must be SMOOTH can ride in it (2026-08-21)

**Symptom.** With the core's interpolation enabled, the painted ghost stuttered every frame.

**Cause.** `extras` is opaque to the core by contract (`contract.md`), so interpolation smooths
`position` while `extras.prog` — the peer's sub-tile step progress — passes through latest-wins. The
painted tier then combined a smoothed tile with an unsmoothed sub-tile offset: two terms describing
different instants, once per frame.

**SUPERSEDED TWICE — do not follow the "fix for now" below.** (1) The design lesson was
*implemented*: sub-tile progress moved into `position` (`25277b9`, `ba10a53`), so the two terms
cannot disagree any more. (2) The rig workaround was refuted by the shipped-settings entry further
down this file and by `af50938` — `run-core-crystal-shipped.bat` exists precisely so the rig does
NOT run `-interp=0ms`, because judging only at 0ms is how the shipped smoothing went unexamined.

**Fix at the time:** the dev rig ran `-interp=0ms` anyway (deliberately, so 1:1 could be judged),
and with interpolation off the two terms agree.

**The design lesson, which is the part that survived:** sub-tile progress is really part of
POSITION, and putting it in `extras` was expedient rather than right. Anything a renderer needs to
be smooth must live where the core is allowed to interpolate it.

## Painted-tier motion: three attempts, all reverted, all the same mistake (2026-08-21)

**SUPERSEDED — painted-tier motion WORKS.** Read alone this entry says "do not attempt it". The
three-layer model that succeeded is in the later entries on the drawn tier's motion and the
shipped-settings rig, and the result is user-confirmed (`verified.md`, 2026-08-22/23). What
generalises is the *diagnosis* below — measure the position's own behaviour before adding a term
on top of it — not the conclusion that the attempts were doomed.

The Crystal painted tier renders outside the engine, so it must reconstruct by hand what the engine
gives the spawned tier for free: sub-tile motion, stride phase, camera tracking. Three fixes were
tried and reverted in one session, and **all three added or froze a term on top of a position whose
own behaviour had never been measured**:

1. **A sub-tile glide** — walk back from the destination by the distance not yet covered. Result: one
   tile of movement became two of visible travel, because the destination position ALREADY carries
   the camera's scroll and delivers it in a lump ~12 frames into the step. Smooth plus quantised is
   two motions.
2. **Freezing the calibration** — to kill a ±2px wiggle. Result: the painted copy stopped tracking
   the camera entirely, drifted a tile ahead and snapped back. The frozen term was the one that
   follows the scroll.
3. **Dead reckoning the peer's progress** — advance the last known value at 2px/frame. Result: the
   ghost ran ahead of itself, a full tile at the cap, because the refresh stamp could only fire when
   the VALUE changed and a repeated value let the extrapolation compound.

**What finally worked was a model, not a correction**: paint the peer at
`playerScreen + (peerTile − playerTile)×16 + peerOffset − playerOffset`, with every player term read
from one frame and offsets measured from the DESTINATION (`MAP_X`/`MAP_Y` are written at the START of
a step). **The camera appears on neither side because it moved the player and the world together.**

**The transferable rule: when a position is wrong, measure what that position already does per frame
before adding anything to it.** A per-frame trace of one peer answered in one line what three
attempts could not.

## Crystal: our own ghost's OAM entries are indistinguishable from the player's (2026-08-22)

**Symptom.** The drawn tier's ghost swapped between two facings while the peer walked in one
direction — *"going right has the 'facing down/right constantly' issue"*. It appeared to MOVE
between directions across reloads (left one session, right the next, up after that), which read as
a regression each time, and it degraded within a session: *"it was working at first, but then it
started flipping/swapping in all 4 directions"*.

**Six attempts, four of them wrong, and every wrong one was reasoned from the code.** The fault
looked like a transition bug, then a one-frame skew, then a cache-locking rule. It was none of
those on its own. What ended it was a ten-line trace logging what actually landed in the cache.

**Cause, in two independent layers — which is why every single-variable attempt failed.**

1. **`learnFacingFromPlayer` read OAM entries 0-3 on faith.** Those are assumed to be the local
   player's four sprites, here and in the tier's own anchor calibration, and the assumption had
   never been checked. The engine lays OAM out in its own order, so another character can occupy
   them. Offsets are computed against the PLAYER's tile base, so a frame captured from a foreign
   sprite decoded to ~128 instead of 0-11.
2. **The range check that fixed layer 1 could not see the case that mattered.** It only rejects a
   sprite with a DIFFERENT tile base — and **our own spawned ghost wears the local player's sprite
   id and tile base**, because that is the fallback when a peer's own sprite is not resident. Its
   entries decode to perfectly in-range offsets: the player's tiles, arranged for whichever way the
   GHOST is facing. Nothing about such a frame is detectably foreign. This is why the contamination
   arrived ~2,000 frames in — it needs the ghost up and facing elsewhere — and why the tier looked
   correct at first and then degraded.

**Fix: a rule about the DESTINATION, not the source.** Whatever the entries belong to, art that
disagrees with what a facing must wear is not that facing's art. A 12-tile walking sprite is three
views of four tiles — down 0-3, up 4-7, left/right sharing 8-11 and told apart by the hardware flip
— so the view is DERIVED from the facing and any frame from another view is refused.

**Two wrong versions of that rule, both instructive:**

- **Learning the view per facing from its first sample.** One contaminated first sample locks a
  facing to the wrong view, and the check then ENFORCES it, rejecting every correct frame after.
  `up` locked to the down view and the ghost faced down whichever way the peer walked. **A rule
  that protects whatever arrived first is only as good as that arrival.**
- **Checking the view but not the flip.** Left and right share one view, so the group test passes a
  right-facing frame into left's cache and the two alternate. Up/down were unaffected, which is why
  they went clean an attempt earlier — their views are separate groups. The flip constraint applies
  to the side view ONLY: up and down animate BY mirroring, so both flips are legitimate there and
  requiring one would reject half the walk cycle.

**The methodology lessons, which cost more than the fix.**

- **A cache that keeps the first N samples and never clears turns any single bad sample into a
  permanent fault** — and re-rolls it on every reload, so it looks like a different bug each
  session and like a regression after every unrelated change. The tell is a fault that MOVES
  between cases without the responsible code changing.
- **Build the instrument before the first attempt, not after the fourth.** Four fixes were shipped
  on inference; the trace took ten minutes and answered in eight lines. Every real step —the
  sprite's view layout, the out-of-range entries, the late-arriving contamination — was invisible
  to reading the code, and two of them contradicted a theory that had already been shipped.
- **Log the INVARIANT, not just the values.** Printing each accepted frame's view beside the one
  its facing requires turned the log into a pass/fail the agent could read, instead of a symptom
  the user had to characterise for the fifth time.
- **A revert can be wrong.** The frame-pairing fix was reverted for "making it worse" when it was
  half of a two-part fix whose other half did not exist yet. After several single-variable
  negatives, `CLAUDE.md`'s rule is to try the UNION — that rule applied here and was not followed
  until the trace forced it.
- **"It worked at first and then degraded" is a lifetime statement**, and it points at accumulated
  state rather than at logic. It was the single most useful sentence the user said.

**Generalises to any adapter with a second renderer.** A ghost built to look like the local player
is, by construction, indistinguishable from them in every buffer that records appearance rather
than identity. Anything learned by observing "the player's" sprite data has to establish WHICH
character it is reading, or be validated against something only the real player can satisfy.

## An input-driving probe left loaded becomes a suspect in every later report (2026-08-22)

**Symptom.** The user reported the drawn ghost wiggling. `door_loop.lua` — a probe that presses Up
and Down on a cycle to walk in and out of a house — was still loaded from an earlier driven
measurement while they tested by hand.

**Why it cost a round.** In a loopback session the ghost is the local player echoed, so anything
jittering the player jitters the ghost, and it presents as a RENDERING fault in the tier under
test. That made the probe a genuinely plausible cause, and ruling it out took a reload and a
round trip to the user.

**It was innocent, and that is the part worth keeping.** The wiggle was a real bug. **An
uncontrolled instrument does not have to cause the fault to cost you the investigation** — it only
has to be an explanation you cannot dismiss cheaply. The same reload that cleared the suspicion
would have been unnecessary had the probe come off when its own measurement finished.

**A second, separate error in the same exchange, worth naming because it is the more expensive
habit:** the probe was then offered to the user as the likely explanation. That was a guess wearing
the clothes of isolation. The correct move with two candidate causes and a user at the controls is
to BISECT — put the tree back to the last committed state, confirm the symptom's presence or
absence, and only then reason. That is what eventually settled it, several messages later.

**Fixes, both applied:** the probe announces at load that it is holding the controller
(`door_loop.lua`), and the general rule is in `adapters/_template/probes.md` — "an input-driving
probe is not a passive instrument". A driving probe is unloaded when its run ends, never left on
between runs, and never present when the game is handed back.

**Note the legitimate case, so the rule is not read as a ban:** when the user hands the controls
over explicitly — *"if you want to go 1 tile up to enter, then 1 tile down to exit"* — driving is
exactly right, and got 32 measured crossings in three minutes that a person would have had to walk
by hand. The rule is about who is holding the pad, not about whether driving is allowed.

## Crystal: the learned frame measured its parts from OAM entry 0, so right-facing drew 8px left (2026-08-22)

**Symptom.** The drawn ghost sat ~8px left of where it belonged **only when facing right** — the
user: *"when facing right, the drawn ghost gets offset a bit to the left. it does not do that for
any of the other directions"*.

**Cause.** `readPlayerOamFrame` recorded each of the four sprite parts as an offset from **OAM entry
0**. The engine emits a character's entries MIRRORED when the sprite is flipped, so entry 0 is the
top-LEFT part one way round and the top-RIGHT part the other. Right-facing is the only direction
drawn from the mirrored side view, so it was the only one affected. Measured directly:

```
up     [4@0,0  5@8,0   6@0,8   7@8,8 ]
left   [8@0,0  9@8,0  10@0,8  11@8,8 ]
down   [0@0,0  1@8,0   2@0,8   3@8,8 ]
right  [8F@0,0 9F@-8,0 10F@0,8 11F@-8,8]   <- every dx negated
```

**Fix.** Measure the parts from the minimum x and y across the four entries. The minimum is
invariant under the flip, because the SET of four positions is identical either way — only which
entry reports which member changes. Confirmed on screen (*"absolutely perfect/static in all
directions now"*) and in the log: all four facings inside a 0..8 box, no negatives.

**THE FIX ALREADY EXISTED IN THIS FILE, ONE FUNCTION AWAY.** The tier's own anchor calibration takes
the minimum x across the same four entries, for exactly this reason — recorded 2026-08-19, in this
file, under "Calibrating on OAM entry 0: the entry ORDER swaps when the sprite flips". It was never
carried across to the learner.

**That is the pattern worth extracting, and it happened THREE times in one session:**

| rule | where it lived | where it was missing |
|---|---|---|
| place only on a settled camera | Emerald's spawn path | Crystal's, until it was re-reported (2026-08-19) |
| take the MINIMUM x across the four OAM entries | the tier's anchor | the tier's frame learner (this entry) |
| pair a value with the frame OAM was built from | the position model | the facing learner |

Each was found, written down, and fixed correctly — in one place. The sibling path kept the bug and
surfaced it later as a fresh-looking user report, which is expensive precisely because it does not
look like a known issue. **When a fix is recorded, the same pass should ask: what ELSE reads this,
and does it need the same rule?** `CLAUDE.md` says this about back-porting to `_template/`; it is
just as true between two functions in one file. Candidate sweep: `agent_docs/ideas.md`.

**And the user's instinct is the transferable half:** told about an 8px offset the obvious response
is an 8px correction, and they pushed back — *"so maybe its another issue we haven't found yet
instead of just an offset?"* A compensation would have worked for right-facing and broken the
moment anything else flipped. `_template/BANDAGES.md` calls this shape out; here it was avoided
because the reporter refused it.

## The rig ran the SHIPPED interpolation while the test needed none (Crystal, 2026-08-22)

**Symptom.** The drawn ghost, offset two tiles to the side for comparison, looked *"really
stuttery whenever you walk in any direction"* and *"still stuttering/small snap kinda when moving to
the next tile"*. Two rounds of work went into the renderer looking for it.

**Cause: the core under the test was the one the ADAPTER autostarts, on shipped defaults** —
`-interp=250ms`. With a loopback ghost offset to the side, the whole point is judging the drawn
tier against the player 1:1, and a quarter second of interpolation means what is on screen is the
wire, not the renderer. The measurement is unambiguous once taken: the painted ghost moved 2px
relative to the player on **100 of 132** walking frames at the shipped default, and **0px on all
194** with `-interp=0ms -min-send=10ms`. Nothing about the renderer changed between those two runs.

**Why it happened here and not in Emerald: Emerald has `dev-scripts/run-core-emerald.bat` and
Crystal had no equivalent**, so every Crystal session silently got an autostarted core on play
defaults. `run-core-crystal.bat` now exists and mirrors it. The two modes are deliberately
opposite and both are legitimate — `run-core-emerald.bat` (`-interp=0ms`) for judging a
side-offset ghost against the player, `run-core-emerald-trail.bat` (`-interp=200ms`) for a ghost
sitting ON the player where the delay is the thing being judged.

**This is the THIRD time the rig's own settings have been misattributed to the adapter**, after
the relay's 20Hz-instead-of-100Hz default on 2026-08-21 (`phases/phase9.md`, which already records
"the rig's settings are part of the experiment" as a method lesson). The lesson keeps being
relearned because nothing checks it. So: **before judging a renderer, print what the rig is
actually running and read it** — the core's interp, the relay's send rate, and which core the
adapter attached to. A number in a log costs nothing; two rounds of renderer work cost a session.

**What it does NOT mean.** The 250ms is correct for play and was measured with the user
(`core/core.go`'s own comment, 2026-08-19). The user, on being told the smoothing might be a
bandage: *"i don't think we did that as a bandage thing for emerald, pretty sure we did it for the
network reasons? it can never 1:1 match the player due to network i think?"* — exactly right, and
it is the reason Emerald's drawn tier carries an exponential filter that Crystal's still does not.
A tier with no filter draws the staircase between deliveries; at `-interp=0ms` there is nothing to
absorb and it looks perfect, which is precisely why a zero-interp rig cannot tell you whether the
filter is needed.

## A WRITING probe that half-identifies its target corrupts everything else (Crystal, 2026-08-22)

**Symptom.** *"the ghost is flickering in/out from the middle~ and below"*, then, moments later,
*"actually its flickering from anywhere right now, even the left side. you broke something"* — a
regression report against code that had just been committed and was not the cause.

**Cause.** A probe was blanking the four sprite-buffer entries belonging to one character, to test
whether a ghost could be hidden without losing its collision. It identified those entries by
screen position and matched **about 1.5 of the 4** — so every frame it blanked roughly one and a
half entries of the intended character and, whenever the match drifted, entries belonging to
somebody else: NPCs, and the player. The buffer is shared and rebuilt every frame, so the damage
was invisible in any log and total on screen.

**The rule this extends.** `pitfalls.md` already carries "a diagnostic can break the thing it
measures". This is the sharper case: **a probe that WRITES to shared state must prove it has
identified its target before it writes, not after.** Its own counter said 1.5 of 4 and that number
was printed and read — as a note about the probe's accuracy, not as what it plainly was, a warning
that half its writes were landing on strangers. A partial match is not a weak measurement, it is
an active corruption.

**Two habits that would have caught it:**

- **Refuse to write unless the match is exact.** Four entries or nothing. A probe that finds three
  should log and skip, never write three.
- **Say out loud that a writing probe is loaded, every time.** The user was mid-test on an
  unrelated question and had no reason to suspect the rig; the flicker read as a regression in the
  commit that had just landed. `probes/README.md` already lists which probes write RAM for exactly
  this reason — being on that list is not the same as the person watching the screen knowing it is
  running right now.

## Adding one local silently unloaded the adapter -- an hour after fixing the same fault elsewhere (2026-08-22)

**See also "Lua's 200-local ceiling" above**, the first recording of this; it has since happened a
third time. Cross-linked 2026-08-25.

**2026-08-22.** Crystal's adapter stopped loading entirely with `too many local variables (limit is
200) in main function`. The cause was a single new top-level local, `DRAWN_DELAY_FRAMES`, added for
a feature the user had just asked for.

**What makes this worth an entry is the timing.** Emerald's adapter had been found broken by exactly
this, for exactly this reason, and fixed **the same session** -- and Crystal's own source says "this
file is at 197 of Lua's 200 locals" in FOUR separate comments, each one written by someone who had
just been bitten. Knowing the rule, having just applied it elsewhere, and having it written in the
file being edited were all insufficient.

**Two things follow, and the second is the useful one:**

- The fix is the same one the file already uses everywhere: hang the value on an existing table
  (`facingFrames.drawnDelay`). A field costs no local.
- **The failure is silent to the person watching the screen.** The adapter simply does not load;
  the game plays normally and the ghosts are absent or frozen at whatever they last were. During
  this session the user reported on the drawn ghost's behaviour TWICE while no adapter was
  running -- so those two reports describe the previous build, and were nearly used as evidence
  about the change that had just been made. **After any edit, confirm the adapter actually LOADED
  before asking anyone to look at anything.** The loader log says so in one line.

## Crystal: a ghost must NOT use the player's step type -- it scrolls the camera (2026-08-22)

**The idea, which looked obviously right.** Watching both objects at once showed the player's own
object walking on `OBJECT_STEP_TYPE` **6** and crossing a tile in 15.8 frames, while a spawned ghost
was hardcoded to **2** and crossed in 14.2. A ghost on a different step type is a different movement
machine rather than a copy of one, and it was recorded as a real defect: the ghost was FASTER than
the player, and that was the only thing keeping its 4-frame start lag from accumulating.

**Why it is wrong.** Step type 6 is the step type that **scrolls the camera**, because moving the
player is what it exists to do. Given to a ghost, the ghost drags the view: the user, within seconds
of it loading, *"this moved/drifted the whole game camera"*.

**So the pace difference is not a defect, it is the price of a ghost not being the player**, and 2 is
correct. It is now commented in `stepGhost` as a rejected alternative rather than left looking like
an oversight, because "just use the player's step type" is an obvious-looking idea that will be had
again and whose failure mode is invisible until it is on screen.

**THE DAMAGE OUTLIVED THE CODE.** Reverting the adapter did not put the camera back -- the user had
to load a savestate: *"i reloaded savestate9, and its back to normal now"*. A ghost driving the
camera moves the engine's own scroll state, and nothing in the adapter owns or restores that. So a
write that hands a ghost a player privilege can leave the WORLD altered after the write stops, and
"I reverted it" is not the same as "it is undone" -- check the symptom, not the diff. Any experiment
of this shape wants a savestate taken first.

**The transferable rule: a field copied from the PLAYER'S object may carry the player's privileges.**
The player's struct is not a template with better numbers in it -- some of its values exist to drive
things only the player may drive. `phase9.md` already learned the same shape from the other side:
the ghost is built from an NPC's movement behaviour wearing the player's face, precisely because the
player's own movement type means "driven by input".

## Crystal: the drawn tier's stutter was never in the drawing (2026-08-22)

**Symptom.** At the shipped 250ms interpolation the painted ghost was *"really really bad"* — a
coarse staircase — while the engine-driven one looked correct. At `-interp=0ms` the same code
measured 0px of relative motion in all four directions and the user called it 1:1.

**Cause: the adapter sent whole TILES.** The core therefore spent each step interpolating between two
identical values and output a constant, then lurched when the tile changed. Measured at the shipped
settings before the fix: **1911 messages, 1838 carrying no movement at all, and the 72 that moved
jumped 4–6px.** The smooth motion was simply not on the wire, so no renderer could have drawn it.

**Why it hid.** The sub-tile position rode in `extras.prog`, and `extras` is opaque to the core and
not interpolated. `pitfalls.md` recorded that in August as a design lesson whose stopgap was "the dev
rig runs `-interp=0ms` anyway, and with interpolation off the two terms agree" — which is exactly
the configuration everything was judged in.

**Fix.** `position` is `[]float64` and variable length by contract, and the core interpolates every
component, so components 3 and 4 now carry the character's position in map pixels — absolute, not an
offset from the destination, because a tile index and such an offset cancel at a boundary when
interpolated independently. After: **521 movements, 517 of them 1px.** The stride is derived from the
same position, since a body moving smoothly while its legs run off an un-interpolated value is the
same defect in the other half.

**The general form is in `_template/README.md`**: anything a renderer must draw smoothly belongs in
`position`; `extras` is for facts that are already discrete.

## Three more instruments that lied, in the same session (2026-08-22)

Collected in full, with the general rule, in `adapters/_template/probes.md` ("Five ways an instrument
lied in one session"). The short forms, because each changed a decision:

- **A trace gated on `frames % 2 == 0`** showed a value advancing 2px per sample and it was reported
  as 1px per frame. It moves 2px every two frames — identical to the value it was replacing — so the
  change justified by that reading did nothing, and was described to the user as a fix. **Print the
  sampling interval in the output line.**
- **A histogram bucketed by a float** (an interpolated distance) while its report looped over integer
  keys: it printed 2 movements out of 224 recorded. **Round at insert time and print the total beside
  the distribution.**
- **A wire trace reported "1 distinct position this second"** and it was read as a field not being
  sent. The driving probe pauses at corners, so a stationary second had been sampled — **and a
  correct change was reverted on that reading.** Report unchanged samples beside changed ones:
  "nothing moved" and "nothing was sampled" must not print the same.

## Crystal: the drawn ghost stutters at shipped settings but not at `-interp=0ms` — 2026-08-23

**Symptom.** *"the drawn ghost still looks a bit stuttery/jittery while moving around"*, at the
shipped 250ms interpolation. Invisible on the dev rig, which runs `-interp=0ms`.

**Why the dev rig could never show it.** At `-interp=0ms` the ghost replays the player's own past
positions, which are integers the engine itself produced. At 250ms the core INTERPOLATES, and an
interpolated position is fractional. Any defect that only appears once positions stop being
engine-legal is invisible on a rig that never interpolates. **A dev rig that removes a variable
cannot test that variable** — Crystal now has `run-core-crystal-shipped.bat` for exactly this.

**Diagnosis, in the order the suspects fell.**

1. *The two clocks beat against each other.* Refuted: 660 of 660 rendered frames received exactly
   one message, and `receive()` drains its whole buffer per frame so a 0 or a 2 would have shown.
2. *The aged player reference wobbles.* Refuted from the code: `playerHistory.age` is a constant.
3. *The interpolated position is fractional.* Confirmed: mean 0.970 px/frame — the right speed —
   but only 65 of 198 moving frames advanced a whole pixel, against 58 at 0.75 and 52 at 1.25.

**Fix, which took three attempts, each corrected by a measurement rather than a guess.**

| attempt | what it did | why it was wrong |
|---|---|---|
| 1px per frame | walked the ghost a pixel a frame | **smoother than the game** — the scroll moves 0/2/4px and never 1 |
| 2px on a fixed parity | matched the quantum | moved on the frames the player did not: 2px of shake every frame |
| **2px grid + phase latched per burst** | rounds the interpolated position onto the engine's grid, and takes its 2px on the engine's observed tick | — |

**Three separate defects were found underneath it, all live before this session:**

- **`stepProg` was computed and never read.** A dead local under a comment explaining why the stride
  had to share the body's clock, while the stepping band, the frame picker and the counters all went
  on reading the raw un-interpolated `extras.prog`. The comment described an intention, not the code.
- **The stride's progress had a sign bug.** `16 + (pix - tile*16)` is correct only where that term is
  negative — right and down. Walking **left or up** it pins at 16 for the whole step, and 16 is
  inside the stepping band, so those directions held one image instead of running a cycle.
- **The engine's tick parity is stable within a bout of walking and differs BETWEEN bouts** (measured
  odd 95 / even 1 inside one bout; 64 / 32 across several). A phase latched once and kept is right
  for a while and then exactly wrong.

**The tell worth carrying: a fault whose severity grows with the length of the action is something
that REPEATS.** *"1 tile looks good/perfect... 4-5+ tiles and it starts to look really jittery"* was
the phase being re-rolled every time the model momentarily caught up — many times in a long walk,
once in a short one. Constant offsets and rounding errors do not behave that way; count the repeats
rather than looking harder at the magnitudes.

## Crystal: the drawn ghost's motion, from "stuttery" to clean — the whole chain, 2026-08-23

One symptom word, *"jittery"*, covered **nine distinct defects** in three different layers. They are
listed together because the order they were found in is the lesson: every layer read clean while a
layer beneath it was wrong, and the instruments agreed with each wrong layer in turn.

### Layer 1 — the position model (what the ghost's world coordinate does)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | stutter at 250ms, invisible at 0ms | interpolation gives FRACTIONAL pixels; mean 0.970 px/frame was right, but only 65 of 198 frames advanced a whole pixel | quantise onto the engine's 2px grid |
| 2 | still stuttering | a 1px/frame ghost is **smoother than the game** — the scroll never moves 1px | move in the engine's 2px quantum |
| 3 | "same/bad" while histograms read perfect | ghost moving on a fixed parity, ANTI-PHASE with the player: 2px of relative shift EVERY frame | take the phase from the engine's observed tick |
| 4 | "1 tile fine, 4-5+ tiles jittery" | the phase cleared whenever the model momentarily caught up — many re-latches in a long walk, half landing anti-phase | release the phase only after a real stop (30 frames) |
| 5 | "stuttering constantly" / "snapping back" alternately | three catch-up policies in a row: too eager stuttered, too patient let lag reach the emergency snap | commit whole tiles; decide only at boundaries |
| 6 | "gliding backward during the walk" | mid-gait boundaries held to the 6px cold-start cushion, bleeding 1-2px per tile (measured: sx 14 -> 2 across one side) | chain at 2px when already walking |
| 7 | "snapping back every single step" | the "never move on consecutive frames" rule — **the engine's scroll DOES tick on consecutive frames**, and the rule zeroed the budget exactly then (`cam=2 gap=1 bud=0`) | on a camera frame, copy the camera's delta unconditionally |

### Layer 2 — the paint (how a world coordinate becomes a screen position)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 8 | one -2/+2 pair per tile, surviving every model fix | the screen origin came from the player's **tile + step progress**, two values that hand over on DIFFERENT frames at each boundary. The old ghost term shared that machinery so the seams cancelled; a seamless model term exposed it | paint as `model - camera + K`, one coordinate frame |
| 9 | "1 tile further back the whole walk, snaps home on stopping" | an 8px **diagonal** register jump on the first frame of each walk — a REBASE, not motion, and the accumulator painted it | absorb an implausible delta into the accumulator AND K in the same frame |

### Layer 3 — the animation (which pose is drawn)

- **The stride's clock**: progress came from distance REMAINING to a destination tile that advances
  when the peer starts its next step, so the cycle restarted a few pixels early every step and its
  last images were mostly never drawn (`0:134 2:166 ... 14:114 16:64` — the end of the cycle three
  times rarer than the middle). Now distance TRAVELLED: model position modulo the tile grid.
- **The stride's axis** came from the peer's reported facing, so one flickering frame moved the
  measurement to the other coordinate. Now from where the ghost is actually going.
- **A one-frame facing flicker counted as a turn**, and the turn suppression punched a single-frame
  hole in an otherwise correct burst (`RRRRrRRR`). A facing must now survive a frame.
- **The legs were gated on the wire's `walking` flag**, which describes the peer NOW while the model
  walks a position a quarter-second older — so the legs froze mid-stride at every stop while the
  body glided on. Now gated on the model's own movement.
- **`stepProg` was computed and never read** — a dead local under a comment explaining why the
  stride had to share the body's clock, while everything downstream read the raw value the comment
  said was the problem.
- **A sign bug** in the old progress (`16 + (pix - tile*16)`) pinned left and up at 16 for the whole
  step, so those two directions held one image instead of running a cycle.

### The two rules worth carrying out of all of it

> **A fault whose severity grows with the length of the action is something that REPEATS.** "One
> tile is perfect, five tiles is bad" is not a constant offset and not a rounding error — count the
> repeats and find what re-rolls.

> **When the model and the screen disagree, the coordinate frame is the suspect.** Layers 1 and 3
> were each measured clean while layer 2 was wrong, because every instrument was built in the
> model's own frame. The only instrument that could see it was one that watched the painted screen
> position — the number the eye actually watches.

## Crystal: a spawned ghost was a TRAINER, and it hung the game (2026-08-23)

**Symptom.** A `!` appears over a spawned ghost's head, as if a trainer had spotted the player, and
the game then stops responding to input. The overworld is still emulating — frames advance, the
adapter keeps logging — so it is the game's own script engine that is wedged, not the emulator and
not Lua. User's words: *"the spawned ghost got the trainer battle thing, and now we are stuck"*.
Rare, and it had been seen *"from time to time"* with no idea how to reproduce it.

**Cause.** `spawnGhost` clones a donor: all 16 bytes of a live NPC's map object plus its object
struct. The adapter understands four of those bytes (struct id, sprite, y, x) and copies the other
twelve blind. Byte 8's low nibble is the object's TYPE and byte 9 is its SIGHT RANGE
(`constants/map_object_constants.asm:79-99`). The donor that did it read

    05 2E 17 0F 09 00 FF FF 82 04 82 5B FF FF 00 00

— type nibble `2` = trainer, sight range `4`, and a real script pointer. The ghost *was* that
trainer, with a four-tile sightline, and unlike a real trainer it walks around; sooner or later it
faced the player from somewhere no trainer stands, raised the `!`, and ran a battle script for a
trainer that is not on that tile.

**Why it was rare, and why it never reproduced.** The donor is whichever object the map declares
first (`findTemplateNpc` returns the first eligible map object). Whether a ghost is a trainer is
therefore a property of *the map you happen to be standing on*, not of anything the player did — so
it travelled with the route and no repro ever held still.

**Fix.** Normalise what the ghost IS, on the ghost's own map object only: type nibble to
`OBJECTTYPE_3`, sight range 0, script pointer 0, event flag `FFFF`. Type 3-6 are the game's own
dummy events whose handlers return immediately, so a ghost can be faced and nothing happens — and
critically they are the only types that never dereference the script pointer, so blanking the
pointer while leaving type 0 would have traded a trainer hang for a null-pointer jump.
`_CheckTrainerBattle` (`home/trainers.asm:13`) tests the type nibble *second*, before sight range
and before the pointer is read, so the ghost now leaves that scan immediately.

### The third instance of one root cause, patched three times

The two earlier ones are commented in `spawnGhost` itself: a ghost inherited `SLIDING`/`FIXED_FACING`
from a still object and never animated, and inherited a WANDER movement type that snapped its facing
at the end of every step. Each was fixed where it showed, as its own field. **All three are the same
bug: a ghost inherits its donor's identity.** Three symptoms, three patches, one cause that was
never named. When the same shape appears a third time, the thing to change is not the fourth field.

### What was tried first, and why it was wrong

Templating the **player** instead of an NPC — the player carries no trainer type, no sight range and
no script, so the whole class disappears. It was a bad fix and was reverted within the hour: the
player's map object and its 0x28-byte object struct carry the engine's own driving state, and
copying them broke camera-follow and displaced the map's objects. User: *"this is not a fix, this is
a really big regression"*. **The donor was never the thing to change; the four bytes that say what
the copy IS were.** Replacing a donor whose unknown bytes are *sometimes* wrong with one whose
unknown bytes are *always special* is not a narrowing, it is a bigger blind copy.

### The method worth keeping

- **An unreproducible fault deserves an instrument, not a repro hunt.** A one-line log of the donor
  and its 16 bytes was added while the bug was still just a suspicion. It caught the offending
  object on the very first spawn after it went in, and named the culprit outright. The fault was
  unexplained from the first time it was seen; the instrument is one log line.
- **A cleared decompilation is faster than measurement — read it FIRST.** Every fact above came from
  reading `pret/pokecrystal`, which `licensing.md` cleared for facts-with-citation and which
  `environment.md` records as already built locally since 2026-08-17. The field names, the type
  values, the dispatch table and the scan order were all sitting there. The earlier `FLAGS1` fix in
  this same function was derived by probe over multiple sessions, and those bit names were in a file
  we were always allowed to read. Measurement is for confirming what the source says, not for
  discovering it.
- **Verify a write by reading it back out of the game.** The spawn log now reports the type nibble
  re-read from emulator memory rather than the value just written.

## A reverted `.go` file comes back as CRLF, and nothing shows you why (2026-08-23)

**Symptom.** `dev-scripts/preflight.ps1`'s first check fails: `not gofmt-clean` on several `.go`
files. `gofmt -d` prints the ENTIRE file as changed, which reads like a catastrophic formatting
problem. Meanwhile `git status` and `git diff` show nothing wrong with those files — some of them
are byte-identical to `HEAD` in content — so there is no edit to point at and no obvious culprit.

**Cause.** `core.autocrlf=true`, and `*.go` was not pinned in `.gitattributes`. Git therefore writes
CRLF whenever it *materializes* a `.go` file, so any revert re-creates it with CRLF — `git checkout
--`, a reversed patch, a stash pop. Git then normalizes on read, which is why the diff is empty; but
`gofmt` sees a file whose every line ends `\r\n` and rewrites every one of them.

Note what makes this hard to attribute: **no one edited the file.** Reaching for "whose editor did
this" is wrong twice over — it blames a person, and it stops the search before the real mechanism.
The tell that settles it is that the *content* matches `HEAD` while the *bytes on disk* do not.

**Fix.** Pin it, exactly as `go.mod`/`go.sum` already were for the same reason:
`*.go text eol=lf`. Repair the existing files with `perl -pi -e 's/\r\n/\n/g'` before rebuilding —
`CLAUDE.md`'s order for the LF-pinned adapter sources (normalize, then build, then commit) applies
here too.

**Worth knowing:** `.gitattributes` already pinned `*.cs`, `*.cpp`/`*.hpp`, `*.sh`, `go.mod` and
`go.sum`. `.go` was simply missed, and it is the extension this repo has most of.

## Crystal: the end-of-walk snap was TWO faults sharing one trigger (2026-08-23)

**Symptom.** At shipped settings only, the drawn ghost snapped onto its last tile whenever the
player stopped. Clean at `-interp=0ms` the same date, which is why every earlier confirmation had
missed it: the lag being repaid is the model trailing its own INTERPOLATED target, so with no wire
delay there is no debt and the fault cannot occur. **A dev rig that removes the delay cannot find a
delay-dependent fault.**

**Cause 1 — the model was allowed to move at double the engine's walk, but only at rest.** The
model's budget copies the camera's delta while the camera moves; parked, it falls back to its own
beat, and that fallback granted 4px where a walker moves 2px. The camera only parks once the PLAYER
has stopped, so the branch could never fire mid-walk — it fired once per walk, at the end.

**Cause 2 — the paint had two formulas and switched between them at that same moment.** It
CALIBRATED `K` from the player-tile formula while parked and PAINTED from the camera formula while
moving — an `if`/`elseif`. The frame the camera parks is the frame the source changes, and the two
formulas disagree by accumulated drift: **worst measured 14px, paid in one frame.**

**Fix.** Cap the parked fallback at 2px; paint from one formula on every frame and let only `K`
move. Also fixed on the way, by algebra: **the X camera rebase was absorbed with the wrong sign** —
painted position is `model + camA + K` on both axes, so a rebase added to `camA` cancels only if
SUBTRACTED from `K`. Y did that; X added, doubling every X rebase into the paint.

### Why "sometimes" was the most useful word in the report

Fixing cause 1 turned *"snapping ... whenever the player stop"* into *"still doing the weird ending
snap, but just sometimes"*. **A defect that becomes intermittent has not become smaller — it has
become a second defect whose magnitude varies.** Both fired on the same trigger, so one fix could
never have been judged as a partial success; "sometimes" was the signal that a magnitude was
varying while the trigger was not, which is what pointed at accumulated drift.

### "Before" and "after" are diagnostic words — ask which

The residue was chased in the wrong place until the user said *"sometimes have the 'jitter' right
before stopping on a tile"*. **Before**, not after. At 250ms the ghost is still walking its last
tile while the camera is ALREADY parked, so a park-time correction runs during the ghost's final
approach. That one word moved the cause from "what happens at rest" to "what happens during
arrival", and no instrument had distinguished them.

### Two repayment rules that sound better and are worse

Recorded so they are not re-invented; both were tried against the user's eyes.

| Rule | Result |
| --- | --- |
| Deadband — ignore drift under 4px, since a constant offset is invisible | Drift walked up to **16px** per park, at the snap threshold. The premise is right; the conclusion is not, because the drift is CONTINUOUS, so repayment must be too. |
| Wait for arrival, then repay 2px on the engine's tick | *"now its overshooting, and then gliding back ... added a snap to every single stop"*. 2px is coarser than the drift it chases, and a post-arrival burst is a snap by construction — the original fault moved later in time. |

**The rule that survived: repay continuously and finely, on a frame the model itself did not move.**

### The engine's RHYTHM is as visible as its speed

The first repayment moved `K` 1px per frame. Every frame stayed within the walk speed and it still
looked wrong, because the model advances 2px on its beat and the correction filled the gaps —
turning a clean `2-0-2-0` cadence into `2-1-2-1`. This file already carries the same lesson from the
other direction (a 1px-per-frame ghost is *smoother than the game* and reads as shimmer). **A
correction does not get its own units.** If the engine moves 0, 2 or 4 pixels and never 1, then
neither does anything we add to it — including error repayment.

## Crystal: a tier handover is a position handover, and a gap is a blink (2026-08-23)

**Symptom.** *"the spawned ghost is 'teleporting' 1 tile whenever it starts to walk after being
idle/respawned"*.

**Cause.** Not stepping at all — a HANDOVER. The shipped idle rule demotes a ghost that has not
changed tile to the drawn tier, which despawns its engine object; the moment the peer moves it is
promoted back and a fresh object is placed. So "after being idle" is a re-spawn every time. The two
tiers disagree about where the peer is at that instant, and an instrument at the promotion measured
it as the same value on every occurrence:

    promoted across a -1,+0 tile handover (drawn model at 15,20, peer at 16,20)

**A full tile, always along the direction of travel — structural, not incidental.** The promotion is
TRIGGERED by the peer moving, so it fires exactly as the peer leaves the tile the drawn ghost is
still standing on.

**Fix.** Promote onto the tile the drawn model is over, not the peer's current tile, and let the
ordinary step logic walk the remainder. The sub-tile remainder is deliberately NOT carried across:
an object parked between tiles is what the standing re-anchor exists to destroy, so it would be
undone within a frame and the jump would return by another route.

**Then a flicker was left** — *"its not teleporting now, but it 'flickers' real quick"*. Dropping the
drawn copy on the frame the engine object is created leaves one frame in which NEITHER draws the
peer: the adapter paints during its own tick, while a new object is not in the engine's sprite list
until the engine next builds one. **A gap is visible; an exact overlap is not.** The two tiers now
overlap by one frame, which is invisible only BECAUSE the tile handover was fixed first — they agree
on the tile, so it is the same character in the same place. Overlapping before fixing the tile would
have drawn the peer twice, a tile apart.

**Generalise:** any renderer with two tiers has a handover, and the handover has a position. It is
invisible only if both tiers agree on that position AND neither frame is left empty.

## A scripted edit can land a thousand lines from where you meant it (2026-08-23)

**Symptom.** A Python edit reported success. The file had a comment stub at the intended site and
six lines of the new code pasted into an unrelated function far below — syntactically valid Lua,
loaded without error, and wrong.

**Cause.** Computed insert indices. The replacement targeted one line correctly, then `insert()`ed
the remainder at hand-arithmetic offsets that were stale the moment the first edit shifted the file.

**Fix, and the rule.** `CLAUDE.md` already says to re-read the FILE after any scripted edit — this is
what it is protecting against, and "it printed `applied`" is not evidence. Prefer replacing a
contiguous block in ONE operation over an anchor plus offsets; when line numbers must be used, assert
on the CONTENT of every line before touching it. Recovery is `git diff --stat` plus a look at the
hunk headers: four intended sites showed as four hunks, and the stray sixth hunk was the corruption.

**Also, repeatedly, in the same session:** several `old in s` assertions failed because indentation
in the heredoc did not match the file's tabs. Those failed LOUDLY and were harmless. The dangerous
one is the edit that half-applies — **an assertion that fires is a good outcome; the one to fear is
the edit that succeeds in the wrong place.**

## Crystal: the ghost jittered before stopping, and the "camera" was three different mistakes (2026-08-23)

**Symptom.** The drawn ghost tracked cleanly, then jittered on its final approach as it stopped —
*"works/looks fine most of the time, and then sometimes have the 'jitter' right before stopping on a
tile"*, most reproducible on one leg of a scripted square walk. It had survived every previous fix
aimed at the model's motion, the wire and the interpolation delay.

**Three wrong theories, each of which looked right.**

1. *A continuous bleed between two formulas.* The evidence was a log line reading "K drift repaid
   206px" against only 5 camera rebases. The counter added the whole REMAINING error every frame
   while the corrector repaid 1px of it, so it inflated quadratically — 206 was about two ordinary
   episodes. **The theory was built entirely on a counter whose units nobody had checked.**
2. *An aged player reference.* Written down as the next suspect; already dead, because the aging
   knob had been set to 0 earlier the same day for an unrelated reason. Cost nothing to rule out —
   by reading, not running.
3. *A sub-pixel rounding residue making the corrector oscillate.* Plausible, and refuted in one run
   by a reversal counter (158 correction frames, 3 reversals — steady chasing, not oscillation).

**What actually settled it, in the order that worked.**

- **Algebra first.** Substituting the definitions into the disagreement made the ghost's own position
  cancel exactly: `wantKX = oamX - 8 - pTile.x*16 - ppx - camAX`. That one line proved the residue
  was not the ghost's, could not be affected by the wire or the model, and was entirely
  player-and-camera-side. It deleted most of the search space before any measurement.
- **Then the decompilation, which named the bug.** The register the adapter integrated as "the
  camera" was `wPlayerBGMapOffsetX/Y`. `pokecrystal` says it is "used in FollowNotExact", and
  `ApplyBGMapAnchorToObjects` (`engine/overworld/map_objects.asm:2768`) reads it, applies it to every
  object's sprite, and **zeroes it every frame**. A per-frame delta, not a scroll position. The real
  scroll is `hSCX`/`hSCY`, written by `ScrollScreen` from the same step vector with the opposite
  sign. **The adapter's own comment claimed this register "cannot disagree with what the player
  sees."** A confident comment is not evidence; the source is.
- **Then an audit that could fail.** Reading both registers on the same frame: 30 of 340 frames
  disagreed, in three shapes that each matched a reported symptom.
- **Finally the real cause, from asking how often the instrument ran.** The plausibility filter
  rejected 16/20/22/24px scroll deltas as "register rebases". Those sizes are 8-12 frames of ordinary
  2px scrolling. A gap histogram showed five sampling gaps and five rejections — **the same five
  events.** The camera never jumped: `drawOverflow` increments its frame counter at the top and then
  has many early returns, and the camera sampling sat below all of them, so a gated frame left the
  reference stale. **The adapter was reading its own blindness as the game doing something, and
  throwing away that much real scroll.** That manufactured the entire drift the corrector then repaid
  one visible pixel at a time.

**Fix.** Clock off `hSCX`/`hSCY`; correct the calibration constant only against a reference identical
to the previous frame's; and sample the camera in a global called before every early return. Gaps
went to zero, rebases to zero, per-park drift from 15px to 1px, and the directional asymmetry that
was the user's reported signature disappeared.

**The rules worth keeping.**

- **A filter that discards "implausible" readings will hide your own bugs by making them look like
  the game's.** Every rejected value here was the adapter's blind spot dressed as a register rebase.
  Count what a filter rejects, and check the rejected sizes against how long you were not looking.
- **Ask how often your sampler actually runs before trusting any delta it produces.** A per-frame
  difference is only a per-frame difference if the code ran on every frame. Histogram the gap; 1
  should be the only value.
- **A quantity sampled below an early return is not sampled.** Anything integrated over time belongs
  above every gate, in its own function, not wherever it was first needed.
- **Cancel the algebra before measuring.** Knowing which terms drop out of an expression is free and
  eliminates whole categories of suspect that would each have cost a live cycle.

## A peer walks, and the adapter reports `0 spawned as real objects` (Crystal, 2026-08-23)

**Symptom.** Every peer stays on the drawn tier. The spawn budget is healthy, structs are free, the
sprite is the local player's own, and the player is plainly walking on screen.

**Cause.** `MESHGHOST_CRYSTAL_GHOSTS_PASSABLE` was still set from an earlier run. The dev loader drops
and re-loads script FILES; **it does not reset BizHawk's Lua globals**, so deleting the line from a
flags file does not unset the flag. And that flag makes `shouldBlock` return false *before* it updates
`movedAt`, so every peer's idle counter climbs forever and no peer is ever "moving".

**Fix.** A dev flags file sets every flag it cares about explicitly, **including to `nil`**. The tell
is in the numbers, if anything is printing them: an idle counter that rises at exactly 60 per second
and never resets is not an idle peer, it is a code path that never reaches the reset.

**Method note.** Three guesses were spent on budget, residency and struct exhaustion, all off a
counter reading zero — and a zero counter is compatible with every one of them. What settled it in one
run was making the refusal name itself (`stays on the drawn tier -- wearable=... blocking=...`).
**When a count of zero has more than one explanation, print the reason, not the count.**

## Interpolating a quantity that only moves in whole steps (Crystal, 2026-08-23)

**Symptom.** A spawned ghost's steps begin an inconsistent number of frames after the peer's — 2 to 5
at the shipped relay rate — which reads on screen as walking, hesitating, walking. Raising the relay
rate to 100Hz makes it exactly constant; the shipped 250ms interpolation does not help at all.

**Cause.** The relay ships a room at 20Hz, and the core lerps every component of `Position` between the
two bracketing samples. Crystal's `Position[0..1]` are TILE INDICES — a step function, since MAP_X/Y
jump to the destination the instant a step starts. Lerping a step function turns an exact instant into
a ramp as long as the sample interval, and `math.floor` crosses that ramp at a moment that depends on
where the jump fell between samples. **The jitter is the sample interval, in frames.**

**Not a core bug.** Nothing in `core/` may know which component is a tile and which is a pixel (ADR
2026-08-20). Lerping uniformly is right; reading a lerped tile index as an instant is the adapter's
mistake.

**Fix (designed, unbuilt).** Recover the instant instead of watching for the crossing: the peer's
sub-tile progress is on the wire, so a sample says how far into its step the peer already is, which is
how long ago it committed. Schedule the ghost's step at a constant offset from that. Constant lag has
no reference to be seen against; varying lag is the whole of what is visible.

**The general lesson, which is not about Crystal.** Before smoothing a value, ask whether it is
continuous. Anything that jumps — a tile index, a facing, a state id, an animation number — must be
carried across, never blended, and if a renderer needs the TIME of the jump it has to recover it from
a continuous quantity beside it, not from the jump's own arrival.

## A ghost that is "static, but follows the player around" (Crystal, 2026-08-23)

**Symptom.** A character stays on screen after the core and relay are gone, frozen in one pose, and
appears to travel with the player instead of staying where it was.

**Diagnosis, from the wording alone.** "Follows the player" is a statement about a COORDINATE SYSTEM,
not about behaviour. An engine object lives on a tile: it would stay put and slide off the edge as
the camera moved. Something that holds its place on the display is painted in SCREEN pixels, so it is
the drawn tier's overlay, frozen — not an object at all.

**Cause.** `disconnect()` cleaned up the bookkeeping but not the canvas. Forgetting a peer does not
un-draw it, and nothing repaints afterwards because `drawOverflow()` is the last call in `tick()`
while `tick()` returns early on `not connected`. The last painted frame simply stays.

**Fix.** Clear the overlay wherever the tier can stop being called, not only where it decides not to
paint. `drawOverflow` already had `stopDrawing()` for door transitions; `disconnect()` needed the same.
**The general form: every early return that skips a renderer is a place a stale frame can survive.**

**A memory dump cannot see a rendering artefact, and that cost two wrong answers.** Every probe in
`probes/` reads WRAM, so the drawn tier is invisible to all of them: an orphaned-object theory and a
contaminated-savestate theory were both investigated and disproved before the tier was even
established. **Settle WHICH RENDERER is showing a fault before choosing an instrument** — with two
renderers, half of what can go wrong leaves no trace in the game's state.

**A worked corollary on reading your own numbers.** The object array did hold an extra character
wearing the player's sprite, at tile 13,20 with the player at 9,20 — and `MESHGHOST_LOOPBACK_OFFSET_X`
was 4. That was the adapter's own ghost, exactly where it belonged, misread as evidence of a leak.
When a rig deliberately displaces a ghost, subtract the offset before calling a position suspicious.
`orphan_sweep.lua` said "nothing to clear" eleven times and was correct each time; a probe that keeps
reporting nothing is answering, not failing.

## "It still flickers" after a fix aimed straight at the flicker (Crystal, 2026-08-23)

**Symptom.** A spawned ghost blinks at the instant it starts moving after standing still. A one-frame
tier handover had been added for exactly this and the blink survived it.

**Cause, two layers deep.** The handover kept the drawn copy for one frame; measured, the engine does
not render a newly created object for one to two frames, so the copy was released into a hole rather
than overlapping anything. AND a second, unconditional `overflow[id] = nil` further down the same
function wiped the entry regardless of what `handover` said — so the mechanism had never had any
effect at all. **Fixing only the first would have changed nothing and read as the theory being wrong.**

**The general form: when a fix aimed correctly produces no change, check that the value it sets is
still set by the time anything reads it.** Search for every other write to the same field before
concluding the diagnosis was wrong. A second unconditional assignment is invisible in a diff of the
first one.

**Second general form: a comment describing an intended mechanism is not evidence the mechanism runs.**
This one said the two tiers overlap for one frame and cost one doubled frame; they were never on
screen together, and the "overlap" was a gap. It had been read as a description of behaviour by two
sessions.

## A probe that returns a boolean cannot be sanity-checked (Crystal, 2026-08-23)

Three versions of one OAM probe, and only the third could have been right.

1. Calibrated off OAM entry 0 assuming it was the player — the adapter's own code warns that is false
   once a ghost is on screen. Reported 21-24 frames, a third of a second, for something that should
   take one or two. **A number that implausible is the probe reporting on itself.**
2. Assumed a fixed sprite-coord-to-OAM offset. Object coords are map-relative and the real offset
   moves with the camera. This one **gated every reading on finding the player at its own predicted
   position**, so when the assumption broke it produced nothing rather than a wrong number. That gate
   is the only reason the error did not enter the record as a measurement.
3. Printed the ghost's coords, the predicted position, AND every live OAM entry, per frame. The
   answer — two rows missing on two frames — was readable without trusting the prediction at all.

**Both rules are cheap: make a probe state the raw evidence behind any match it claims, and make it
verify its own assumption against something already known (here, the player) and stay silent when
that fails.** `_template/probes.md`.

## An animation that plays without moving the character (Crystal, 2026-08-23)

**Symptom.** The spawned ghost bumps into walls like the player; the drawn ghost stands there.

**Cause, and it is structural rather than specific.** The spawned tier hands the engine the peer's
`OBJECT_ACTION` and the engine animates. The drawn tier DERIVES its pose from position and sub-tile
progress, so **any animation that does not move the character cannot reach it**. Bump, spin, fishing,
the emote and the Fly landing are one gap. All already ride on `extras.act`; the tier ignored it.

**The general rule: a renderer that infers a pose from motion can only ever show motion.** When one
renderer copies the source's animation state and another reconstructs it from position, they are not
two implementations of the same thing and they will disagree exactly on the animations that stand
still. Emerald sends `sanim`/`sidx` -- the peer's own animation number and frame index -- and never
has this class of bug at all.

**The wrong fix, and how it announced itself.** Forcing `walking = true` for the duration of the bump
makes the picker return a stepping frame every time and cycle the stride images. The user: *"now the
drawn is doing it but it looks slow/weird"*. **A pose built from the correct data can still be the
wrong animation.** What settled it was measuring the frames the engine actually draws, run-length
encoded so the cadence was visible: a bump alternates STANDING art and STEPPING art in 16-frame runs
while the facing walks 0,1,2,3. It is a two-pose shuffle, not a stride cycle -- and no amount of
reasoning about `facing` values would have produced that, because the first 100-frame sample caught
only part of the cycle and looked like a plain 1<->2 alternation.

**Method note: run-length encode a per-frame probe.** One line per frame hides a cadence inside a
hundred identical rows; `value x13 frames` states it. The 3/13 split -- the drawn block changing three
frames before the facing does -- is only visible in that form.

## A local declared below its use, inside one function (Crystal, 2026-08-23)

**The fifth recorded instance of one fault — see "a use above its `local` is a silent nil" above**
for the full tally and why the repetition matters more than any single case.

Fourth time in this file. `peerAct` was declared ~130 lines below the drawn tier's `overflow`
constructors, which now read it. Lua resolves that to a nil GLOBAL, silently -- so `act` reached the
`MESHGHOST_COMPARE_TIERS` copy as nil, and the new bump animation would have appeared simply not to
work **on the exact rig used to judge it**.

**`dev-scripts/lua-forward-refs.py` cannot catch this one**: it checks FILE-SCOPE locals, and both the
declaration and the use are inside `renderRemote`. When adding a field to a table built early in a
long function, check where its value is declared -- the compile check passes either way, because a
nil global is valid Lua.

## A probe committed with a developer's absolute path in it (2026-08-23)

**Third instance, and the last one that had to be caught by eye** — `.githooks/pre-commit` and the
CI tree scan now refuse this mechanically (`136a413`). See the 2026-08-15 and 2026-08-21 entries.

**What happened.** A probe was drafted in the scratchpad with a `SPDIR` placeholder, `sed` substituted
the real absolute path into that copy, and the SUBSTITUTED copy was then copied into `probes/` and
committed. The repo's own leak check (`git grep -inIF -e 'C:\Users' ...`) caught it on the next run --
one commit too late.

**The rule this breaks** is CLAUDE.md's: no personal username, home-directory path or machine-identifying
detail in any tracked file. **And the sequence is the trap, not the carelessness:** a placeholder makes
a file safe to write and unsafe to COPY, because the safety lives in the placeholder and the copy is
taken after it is gone.

**Two habits that would each have prevented it:**
- **A probe resolves its own directory** (`debug.getinfo(1, "S").source`), the way every other probe in
  that folder already does. Then there is no absolute path to leak, in any copy of the file.
- **Run the leak check BEFORE `git add`, not after the commit.** It was run after -- which is how the
  path is now in history rather than only in the working tree.

**Note for cleanup:** a leak in an already-made commit is still in history after the file is fixed.
Fixing forward removes it from the working tree only; removing it from history is a rebase, which is
the user's call and not something to do unasked.

### The fix for it was a hook, not a stricter rule (2026-08-23)

The user asked the right question after this: *"whats the best way to fix this so it don't happen
again ? stricter/more enforced rule about it ? or something else ?"*

**A stricter rule would have bought nothing, because the rule was already as strong as prose gets.**
CLAUDE.md stated it in bold, gave the exact `git grep`, warned that both slash directions and `-F`
are load-bearing, and listed three dated live cases. It was read and broken anyway. Emphasis was not
the missing ingredient, and adding more would have cost lines against the 300-line cap while making
every other rule slightly weaker (`claude-md-cap.md`).

**What was actually missing was a check at the moment of commit.** The rule was obeyed as "scan the
working tree", and the scan was run AFTER committing — so the finding was true and one commit late.

Three layers now, cheapest first:

1. **`.githooks/pre-commit`** scans the STAGED blobs and refuses the commit. Staged, not the working
   tree: they can differ, and the staged content is what becomes history. Install once per clone,
   `git config core.hooksPath .githooks` — hooks are not carried by `git clone`.
2. **`dev-scripts/preflight.ps1`** fails if `core.hooksPath` is not set, so a clone with the hook
   switched off says so instead of looking clean. A fresh clone is exactly that state.
3. **A `paths` job in CI** re-scans the whole tree, catching `--no-verify` and any clone that never
   ran step 1. Late and expensive, but before a release.

**The general shape, worth reusing: when a rule is broken despite being read, do not restate it —
find the moment the mistake becomes expensive and put a machine there.** For anything irreversible,
that moment is always earlier than it feels: here, one commit earlier.

**And verify the guard against the actual failure, not a synthetic one.** The hook was tested by
reconstructing the exact commit that caused this — the same file, with the same substituted absolute
path, staged the same way — and confirming both that it was refused and that `HEAD` did not move.
A guard that has only ever been tested on a case someone invented is a guard of unknown value.

## `pcall` catches errors, not loops — a malformed line froze the emulator (Crystal, 2026-08-25)

**Symptom.** A truncated or malformed line arriving on the bridge freezes BizHawk outright. No Lua
error, no log line, no red script in the console — the emulator simply stops advancing frames.

**Cause.** `jsonDecode`'s object and array loops were `while true` with **no end-of-input check**,
and the fallthrough at the bottom of `parseValue` did `pos = pos + 1; return nil` rather than
raising. So on `{`, `[`, `{"a":1` or `{"type":"state"` the position walks past the end of the
string forever and never matches a closing brace.

**The part worth keeping: the `pcall` wrapper looked like it covered this, and could not.**
`pcall` turns an *error* into a return value; an infinite loop raises nothing, so there is nothing
to catch. A defensive wrapper around a parser is only as good as the parser's willingness to fail
— **a parser that never errors cannot be made safe by the caller.**

**Why only this adapter.** All seven copies of this decoder in the repo were compared: the other
six — Emerald's, and five probes — raise `json: unterminated string` from `decodeString` and carry
an explicit `else error("json: expected ',' or '}'")` in both loops. Crystal's was written fresh
rather than copied, and lost the guards. **Duplicated code does not drift only by being edited; a
fresh reimplementation of the same thing drifts on day one**, and the copy everyone trusts is the
oldest one, not the newest.

**How it was found.** Not by fuzzing and not in a game: by transliterating the function into
another language and running it against a list of truncated inputs with a step cap, so a runaway
shows up as hitting the cap instead of hanging the shell. Valid inputs were run as a control in
the same pass — without that, "everything returned nil" would have looked like the same bug.
**This is a cheap technique for any interpreted adapter code that is awkward to exercise in situ.**

**Fix.** A `pos > #s` guard at the top of both container loops, explicit errors matching the other
six copies' wording, a depth cap (64) so deep nesting cannot exhaust the stack either, and the
silent fallthrough replaced by an error. Confirmed by re-running the harness against the fixed
version: valid input still parses, every malformed input returns `nil`.

**Not remotely reachable**, and worth stating so the severity is not overstated: the core emits
well-formed JSON via `encoding/json` and the framing only dispatches on `\n`, so reaching this
needs a local process on the bridge port — which is what the 2026-08-25 loopback-bind refusal in
`cmd/meshghost` keeps local. Fixed anyway; that assumption is the kind that stops holding.

**Still unconfirmed in BizHawk's own Lua** (`unverified.md`).

## A parked audit rots faster than the thing it audited (2026-08-25)

**Symptom.** A whole-repo doc audit was completed 2026-08-23 and parked unexecuted. Two days
later, working it top-down, its `file:line` coordinates no longer pointed at the right lines and
three of its findings were simply wrong.

**Cause.** An audit is a set of measurements against a tree, and the tree kept moving — one commit
touching `status.md` shifted every line number below it. Worse, an audit reads as *authoritative*
precisely because it is specific: `status.md:40` feels checked in a way "somewhere in status.md"
does not, so the temptation is to act on the coordinate rather than re-derive it.

**The three that were wrong, and they are the useful part** — each was wrong in a different way:

- **A count taken from a list rather than a grep.** It said nine probes carry the Crystal ROM
  guard; the real answer is **ten** — it had enumerated the obvious `spawn_test*` family and missed
  `grant_test_kit.lua`. The file it was correcting said eight. Three numbers, no two alike.
- **A claim about a file that was already right.** It flagged `docs/security.md` for naming the
  relay binary wrongly; that file distinguishes the release name from the built-from-source name
  precisely and needed nothing. Only its neighbour did.
- **A defect generalised past its evidence.** It reported the `jsonDecode` freeze as affecting
  "all Lua adapters". Six of the seven copies in the repo raise on end-of-input; only Crystal's
  does not. Acting on the audit as written would have meant editing six healthy files.

**Fix, and it is a rule rather than a patch: re-grep every claim before writing a correction, and
treat the audit as a list of *questions*, not findings.** Its real value is knowing where to look
— that survives; the specifics do not. Budget for the re-check rather than treating it as
paranoia, because it is what caught all three above.

**Corollary for writing one:** state what was grepped for, not just the conclusion. A finding that
carries its own query can be re-run; one that carries only a line number cannot.

## Two probes had never parsed, and nothing in the repo could have told us (2026-08-25)

**Symptom.** None — that is the entry. `adapters/emulator/pokemon/crystal/probes/noclip_off.lua`
and `adapters/emulator/pokemon/emerald/probes/framedump.lua` were committed, reviewed and sitting
in the tree as ordinary tools. Neither had ever been a valid Lua file.

**Cause, and it is one this file already warns about twice: a scripted edit wrote Windows
backslashes into Lua source.** `noclip_off.lua` had a hardcoded `"C:\dev\MeshGhost\adapters\..."`
in which Lua had eaten `\a` as a bell, `\b` as a backspace and `\n` as a real newline — so
"adapters" became `<BEL>dapters`, "bizhawk" became `<BS>izhawk`, and the string ran off the end of
the line. It was also prefixed `r"..."`, **Python's raw-string syntax, which Lua does not have**.
`framedump.lua` had an unterminated pattern string from the same class of mangling.

**Why nothing caught them.** A syntax error in Lua is not a loud failure here. BizHawk loads a
script at runtime; a file that does not compile simply never loads, and from outside the emulator
that is indistinguishable from "the ghost did not appear". Neither probe had been loaded since it
was written, so neither had ever announced anything. `dev-scripts/bizhawk-syntax-check.lua` would
have caught both — but it runs *inside* BizHawk, needs a human to point the dev loader at it, and
checks a hand-maintained list of files rather than all of them.

**Fix.** A standalone Lua 5.4 is now installed and `luac -p` gates the whole tree in
`preflight.ps1` and in `.github/workflows/lua.yml` (`environment.md`). It compiles and discards,
so it runs no game code. **All 162 tracked files parse as of 2026-08-25.**

**The general lesson, which is bigger than Lua: a check that requires a human and a running game
is not a gate.** The syntax checker existed for months of project time and had never been pointed
at these two files, because pointing it at anything costs an emulator session. The same check
moved into CI runs on every push and needs nobody. **When a tool exists but keeps not being run,
the problem is usually its trigger, not the tool.**

**And the narrower one:** never let a scripted edit put a Windows path into a language with
backslash escapes. Prefer resolving the script's own directory (`debug.getinfo`), which is what
both files do now, and which removes the reason to write an absolute path at all.

## A check that lists no files passes every time (2026-08-25)

**Symptom.** Two new `preflight.ps1` checks — one for broken markdown links, one for rules restated
without a pointer home — reported `PASS` on a tree with a deliberately broken link and a
deliberately orphaned rule sitting in `agent_docs/status.md`. Both had been written minutes
earlier and had never once been seen to fail.

**Cause, one layer down.** Both looped over `& git ls-files '*.md'`, which returned **2** files
instead of 70. PowerShell resolves `git` on this machine to `c:\devkitPro\msys2\usr\bin\git.exe`,
and the MSYS2 runtime **glob-expands the argument against the current directory before git ever
sees it**. Two `.md` files exist at the repo root, so `*.md` became `CLAUDE.md README.md`. The loop
then ran over two files, found nothing wrong in them, and reported success. Nothing errored.

**The part worth keeping.** `'*.lua'` in the same script is fine, and only by luck: no `.lua` file
sits at the top level, so nothing matches, the pattern reaches git intact, and all 162 are listed.
The identical line is correct or silently broken depending on **where in the tree the file type
happens to live**. `'*.go'` is in the same position and equally lucky.

**Fix.** List with a bare `git ls-files` and filter in PowerShell (`-like '*.md'`), which no shell
runtime can rewrite — then assert a floor: fewer than 40 tracked `.md` files is itself a `FAIL`,
because the honest report for a broken listing is "not a clean result", never "clean". **Any check
that iterates a collection needs to fail when the collection is empty**, or its passing state means
nothing. This is `agent_docs/verified.md`'s "a verification rule that reports clean while the thing
it checks is broken", arrived at from a new direction.

**And a second defect in the same check, found the same way.** The canonical-source check asked
"does this file mention `pitfalls.md` anywhere?" — which `status.md` does, in its link footer. So a
drifted copy of a rule pasted anywhere in that file would have been vouched for by an unrelated
line hundreds of lines away. Fixed by requiring the pointer **within 4 lines of the statement**.
This is structurally identical to the unanchored provenance grep in `agent_docs/licensing.md`
repaired in the same session: *a bare phrase match is satisfied by text that has nothing to do with
the thing being checked.* Anchor on position or on syntax, never on a phrase alone.

**Method, which is the transferable part.** Neither defect was found by reading the code — both
were found by **planting the failure the check exists to catch and confirming it fires**. A check
is not finished when it passes; it is finished when it has been *seen to fail on purpose*. Write
it, then try to fool it. It cost about two minutes and caught two false-clean checks.

**Fourth appearance of the wrong-install-on-PATH trap**, after `cmake` (2026-08-13), `git` itself
(2026-08-15), and `cmd` (2026-08-17). It no longer costs a build — it now costs *a check that
claims the tree is clean*, which is worse, because a failed build announces itself.

## Planning on a model of the game you never watched (2026-08-18, Crystal)

**"Observe before you override" is usually stated about fixes. It applies just as hard to
DESIGNING**, and that is the easier half to miss, because planning does not feel like changing
anything — nothing is written, so nothing seems risky yet.

**Symptom.** A plan for moving a ghost rested on an assumed model: that a character's map
coordinate updates when a step *completes*, so a ghost could be moved by writing coordinates and
letting the animation follow. Nothing about the model was flagged as an assumption; it was simply
how stepping obviously worked.

**What one capture showed.** A single read-only capture of an NPC taking a real step showed the
opposite — the map coordinate **is the destination, and is set at the START**, in the same frame as
everything else, with the sprite sliding to catch up over the following ~16 frames. Every frame
after the first is the engine's own work. The mechanism now lives where a game fact belongs, in
`adapters/emulator/pokemon/crystal/documentation.md`.

**What the wrong model would have cost.** A character that teleports while looking like it is
walking — and a bug that presents as a *smoothing* fault, so the search starts in the interpolation
code and never reaches the assumption underneath it. That is the real expense: a wrong model does
not just cost the implementation and the debugging, it aims both of them at the wrong subsystem.

**The tell, and it is a precise one:** *you can describe what the game does, but you cannot point
at the run where you watched it do that.* Not "am I confident?" — confidence is exactly what the
assumption feels like. The question is whether a capture exists. If it does not, that is the moment
to spend one, and a read-only frame-by-frame capture costs a single live run.

**When the capture contradicts you, say so plainly in the write-up** instead of quietly adopting
the new model. The wrong assumption is worth recording precisely because it was intuitive — the
next person arrives carrying the same one, and a write-up that shows only the correct model gives
them nothing to catch themselves on.

## Splitting a file moves its content out from under that file's exclusions (2026-08-25)

**Symptom.** `pitfalls.md` was split into `pitfalls/`, every check passed locally, and the
pre-commit hook then refused the commit: *"a machine-specific path would be recorded in this
repo"*, naming two of the brand-new body files. Nothing had been written. The offending lines were
years-old-in-repo-terms documentary text that had never once been flagged.

**Cause.** The leak check excludes a small list of files by exact path, `agent_docs/pitfalls.md`
among them, because those files legitimately *quote* the patterns they search for -- the check
would otherwise match itself forever. The exclusion is on the **path**, and a split gives the
content a new path. So five lines that were deliberately tolerated at one path became five
violations at another, without a single character changing.

**Fix.** Extend the exclusion to the directory, in **both** places that carry the list:
`.githooks/pre-commit`'s `KEEP` and `dev-scripts/preflight.ps1`'s pathspec. They are deliberately
kept identical, so changing one and not the other leaves the hook and the audit disagreeing about
what is allowed -- which is worse than either rule alone.

**Generalizes to any path-keyed rule, and this repo has several**: leak-check exclusions, the
invented-duration exclusions, `.gitattributes` LF pins, `.gitignore` negations. **Before splitting
or moving a file, grep the tooling for its path** -- `git grep -n '<old/path>' -- dev-scripts .githooks .github .gitattributes .gitignore`
-- and decide what each hit should say about the new location. The same session had already been
bitten once by the sibling of this: renaming `adapters/bizhawk/` to `adapters/emulator/` silently
un-ignored every probe log and un-excepted two vendored DLLs, because `.gitignore`'s rules were
scoped to the old path too.

**The good news is that this is what the hook is for.** It refused a commit that a human review
would have waved through, on a change whose whole point was that nothing moved but the line
numbers.

## A cache whose comment claims it is invalidated, and nothing ever clears it (Crystal, 2026-08-25)

**Symptom.** On the compare rig the SPAWNED ghost surfed correctly and the DRAWN one stood on the
water wearing the walking sprite — the same peer, the same frame, two renderers disagreeing. The
report before it was stranger: after coming ashore the drawn ghost swapped between the walking and
surf sprites, *"only when walking downwards"*.

**Two theories reasoned from the code, both wrong, both plausible.** The peer's sprite id was
oscillating (refuted by measurement: it held 1 on land and 83 on water across four clean
transitions, 5,490 frames, no flicker). Or the facing cache was contaminated with surf frames
(refuted by reading: a learned frame stores an OFFSET inside its own sprite's graphics, and
`SurfSpriteGFX` is a 12-tile `WALKING_SPRITE` shaped exactly like `ChrisSpriteGFX` — so a
blob-learned offset applied to the walking base still draws walking tiles).

**Cause.** The drawn tier decodes VRAM tiles itself and caches the decoded PIXELS by tile index.
The comment above the cache said it was cleared on every map load. **Nothing in the file cleared it
at any point** — the cache had three references: declare, read, write. Mounting the surf blob
rewrites the player's sprite tiles IN PLACE: same VRAM base, new graphics, and no map load. The
spawned ghost is drawn by the PPU from live VRAM so it followed; the drawn one kept painting
pixels the game had overwritten.

**Why "only walking downwards" was the tell, not noise.** Only indices already IN the cache were
stale. Ones first decoded while surfing came back as blob pixels and stayed that way on land. So
whether a given direction was wrong depended on whether its stepping tiles had happened to be
decoded on the water — which reads exactly like a facing bug and is not one.

**Fix.** Invalidate on `wUsedSprites` changing (the record of which sprite sits at which VRAM base,
so it moves precisely when the graphics behind an index do — including a surf or bike mount, which
no map or coordinate signal sees), folding the map in as well. Cartridge decodes are kept: ROM
cannot move. Confirmed on screen by the user the same session.

**The transferable lessons, in the order they cost time:**

1. **Two renderers disagreeing on the same frame is a gift** — it localises the fault to what
   differs between them and nothing else. Here both were pointed at the same VRAM base, so the
   source was excluded outright and only the pixel path was left. **Build the comparison rig
   before you need it**; `MESHGHOST_COMPARE_TIERS` existed for exactly this and paid for itself.
2. **A comment describing an invalidation is not an invalidation.** `git grep -n '<cacheName>'`
   and count the references: declare, read, write, and nothing else means the cache is permanent
   whatever the prose says. Cheap enough to do on sight.
3. **Ask what writes the thing you cached, not just what reads it.** A tile index is a hardware
   address, not an identity — the game rewrites what lives there without telling anyone.
4. **The instrument to reach for separates "wrong input" from "wrong output" at the seam**, and
   there is usually exactly one seam. `MESHGHOST_CRYSTAL_SPRITE_TRACE` printed which graphics each
   ghost resolved to; once it said `peerSprite=83 -> vram 0` with the local player also at base 0,
   every theory about the id was dead in one line.

## A partition measured EXACT is only exact at the rate it was measured (Crystal, 2026-08-25)

**Symptom.** The drawn ghost pedalled the bike at visibly double speed. Walking was perfect and had
been confirmed on screen months of commits earlier.

**Cause.** The tier chose its standing-vs-stepping frame from the peer's sub-tile PROGRESS, on a
partition (`prog 14,0,2,4` stepping; `6,8,10,12` passing) that had been measured against the
engine frame by frame in 2026-08-22 and found exact. It was exact. The engine's walk cycle is not
a function of progress at all: `SetFacingStepAction` advances `OBJECT_STEP_FRAME` once per action
tick — a FIXED clock, one stride per 8 video frames, identical at every gait. At the walk, 16
frames a tile, the two clocks coincide; the measurement could not tell them apart. On the bike, 8
frames a tile, progress laps the clock and the animation runs exactly 2x.

**Fix.** Read the pose off the peer's own `face` byte, which IS the engine's step-frame clock, at
every gait — the rule the bump/spin/fishing branches already used.

**The transferable part.** A measurement taken at one rate cannot distinguish two quantities that
happen to be proportional at that rate. Before trusting a derived quantity, ask *what is this a
function of in the source* — and if the answer is a clock, do not reconstruct it from a distance.
Crystal has three gaits and the whole cost was measuring against one of them; the same trap is
waiting in any game with a walk and a run.

**Related, same evening, same shape:** the drawn model's catch-up band and commit cushions were
tuned in PIXELS at the walk, and the hover they were sized against scales with the gait — so the
bike's ordinary hover reached the arming line and catch-up cycled continuously. Restating them in
STRIDES (6/3 arming, 3/1 cushions, exactly what the pixel values were at the walk) made one set of
numbers correct at every gait. **A constant with a unit that is not the engine's own unit is a
constant that only works at the rate it was found.**

## A cache with an invalidation comment and no invalidation (Crystal, 2026-08-25) — see by-host

Full write-up: "A cache whose comment claims it is invalidated, and nothing ever clears it".
Recorded again here only for the one-line check it produced, which costs nothing on sight:
**`git grep -n '<cacheName>'` and count the references.** Declare, read, write and nothing else
means the cache is permanent, whatever the prose above it says.
## The right ADDRESS pointing at the wrong ASSET, and every check that starts from the name passes (2026-08-26, Crystal)

**Symptom:** a peer's fishing rod is drawn, in the right place, at the right moment, and looks
wrong — the user: *"they both spawn a rod but it looks sideways/weird"*. The player's own rod
beside it is correct.

**What passed anyway.** The adapter read `FishingRodGFX` from the cartridge, and every check
confirmed it: the symbol is at `41:4560`, the flat offset was computed correctly, and the 32 bytes
there are byte-identical to `gfx/overworld/fishing_rod.2bpp`. An offline audit that morning had
verified exactly that and found nothing.

**Cause.** `Script_FishCastRod` runs `loademote EMOTE_ROD` and then `callasm LoadFishingGFX`, and
the second overwrites what the first loaded: `engine/events/fishing_gfx.asm` copies four two-tile
blocks out of `chris_fish.2bpp` into VRAM bank 1 — the bottom half of three standing views, and
the rod at `$fc`. `FishingRodGFX` is on screen for a few frames at most and never during the pose.
So the address was right, the decode was right, and the asset was the wrong one.

**Fix:** read the rod (and the swapped body half) from `FishingGFX` / `KrisFishingGFX`, chosen by
the PEER's sprite id rather than the local `wPlayerGender`.

**The lesson, and it is not about fishing.** *Verifying that a pointer points where its name says
proves nothing about whether the engine draws from it.* The check that works is the one that starts
from the SCREEN and reads backwards: take the tile id out of the engine's own OAM entry, dump that
VRAM tile, and diff it against what you were about to draw. `probes/rod_check.lua` is ten lines of
that and settled it in one run. Reach for it whenever art looks wrong but the numbers agree —
**a name is a claim about intent, and VRAM is a statement about fact.**

## The player does not own OAM entries 0-3, and a priority object silently moves every painted peer (2026-08-26, Crystal)

**Symptom:** every painted ghost jumps a full tile and back, at a moment when the player is
standing perfectly still. The user, on hooking a fish: *"if i catch a fish, the 2 ghosts move back
1 tile (that is not supposed to happen)"*.

**What looked guilty and was not.** The send side derives a peer's pixel position by walking it
BACKWARD along its facing when the peer is mid-step — exactly the shape of the symptom. It was
innocent: through the whole bite the player's `OBJECT_WALKING` stays `STANDING`, its map tile never
changes, and its sprite position and offsets are constant. Logging those fields beside the symptom
is what cleared it, and it took one run.

**Cause.** The drawn tier calibrates screen space against the player's OAM corner, and read
**entries 0-3** for it. But `InitSprites` emits by PRIORITY — HIGH, then NORM, then LOW, and only
within a class in struct order — so the first four entries belong to the highest-priority object
that has a sprite. `SpawnEmote` creates the "!" as a HIGH_PRIORITY object sitting 16px above the
tile, so while it is up, entries 0-3 are the emote's and the calibration is a tile too high. The
measurement: the value read as "the player's OAM y" went 76 → 60 on the exact frame the emote
object appeared in struct 1.

**Fix:** find the player's entries by their TILE IDS — a sprite's graphics are a 12-tile block plus
the same block `0x80` above it, and everything that displaces the player is drawn from ABSOLUTE
tiles (`$f8`-`$fb` an emote, `$fc`-`$fd` a fishing rod) which are outside any block by construction.

**The lesson.** *An index into a list the engine builds is not an identity.* Any "object 0 is always
first" assumption holds only until the engine sorts, and engines sort — by priority, by depth, by
Y. Identify by something intrinsic (a tile block, an id) and the assumption cannot rot. Note also
how narrow the symptom looked: this reads as a fishing bug and is nothing of the kind — **any**
emote over **any** character's head moves every painted peer.

## A ghost that VANISHES is usually an adapter that was unloaded, and the loader log says so in one line (2026-08-26, Crystal)

**Symptom:** *"both ghosts disappeared before they could show the ! above their head"* — every peer
gone at once, at a specific moment in the game, twice in a row. It reads as a gate: a state flag
flipping, a UI clip, the send side going quiet.

**Cause:** a Lua error in the adapter's per-frame tick. The dev loader unloads a target that throws
rather than letting it kill the session, so ALL rendering stops instantly and nothing on screen
distinguishes that from a deliberate hide. The error was a new function calling `readVram`, a local
declared 80 lines BELOW it — a nil global at that point — and it only fired on the frame an emote
object existed, so the adapter ran perfectly for hours before it.

**Fix:** read through `memory.read_u8` directly, and check the declaration order of every helper a
new function uses.

**The lesson is the DIAGNOSTIC ORDER, and it costs one command.** `adapters/emulator/CLAUDE.md`
already says to check the loader log for `LOAD FAILED` when a change does nothing; this is its
runtime twin, and it is the more confusing of the two because the adapter *did* load. So:

> **Every peer vanishing at once is an adapter fault until the loader log says otherwise.** Read
> that log BEFORE reasoning about gates, flags or the wire. One peer vanishing is a gate; all of
> them is a process.

Two supporting notes, both live the same day. **The trap is dated twice already in this repo and
still caught a third case** — a local declared below a function is a nil global inside it — because
the new function was placed by what it read *about* (sprites) rather than by what it *called*.
Place a new function below every helper it uses, and let the comment explain the position. And
**an error that needs a rare game state will not appear in any amount of ordinary running**: the
scan ran every frame and was clean; only the identification branch inside it was broken.

## Splitting a file moved its content out of three exclusion lists, and CI went red on its own documentation (2026-08-26)

**Symptom:** the `No machine-specific paths` CI job failed and stayed failed, naming two lines in
`agent_docs/pitfalls/` — both of which are *prose quoting the very grep the job runs*. No real path
leaked. Local `preflight.ps1` and the pre-commit hook were both green throughout, which made the
failure look like a CI-only quirk.

**Cause.** The privacy scan excludes files that are ABOUT paths. `agent_docs/pitfalls.md` was one
of them, and on 2026-08-25 it was split into `agent_docs/pitfalls/*.md`. The hook and
`preflight.ps1` had their exclusion lists updated at the split; **the workflow was the third copy
and was missed**, so the excluded prose walked out from behind its exclusion.

**Fix:** add `':!agent_docs/pitfalls/'` to the workflow's list, and a comment there saying all
three copies exist.

**Two lessons, and the second is the bigger one.**

*A file split relocates every path-based rule that mentions it* — exclusion lists, coverage checks,
hook globs, CI filters. Grep the old path across the whole repo as part of the split, not after
something breaks; the split itself is the moment those references are all findable.

*A check that fails on its own documentation trains people to ignore it.* This one is the mirror of
the "verification rule that reports clean while the thing it checks is broken" entry above: this
one reported broken while nothing was wrong, which is cheaper only if somebody reads it. **Nobody
did — it was red for a day**, which is exactly what `CLAUDE.md` says to look for at session start
(`gh run list -L 5`) and exactly what did not happen.

## A repo-wide fix covers the files that exist that day, and a file added later brings the problem back (2026-08-26)

**Symptom:** the Node 20 deprecation warning reappeared on a CI job, on a repo where it had been
fixed. The user, reasonably: *"didn't we fix this node.js thing before? why do we have it again?"*

**It had not regressed.** On 2026-08-17 every workflow was moved off Node 20 — `checkout` v4→v7,
`setup-go` v5→v7, `upload-artifact` v4→v7 — and that commit was correct and stayed correct. On
2026-08-25 a NEW workflow, `lua.yml`, was added, written with `actions/checkout@v4`. Nothing
undid the fix; a new file simply arrived carrying the old pattern, eight days later, and nothing
in the repo could notice.

**This is the second case in one day.** The other is the entry above: splitting `pitfalls.md` moved
prose out from behind an exclusion that three separate lists carried. Same family — *a fix applied
to "all the files" is a fix applied to the files that existed that day* — and both were invisible
to every local check.

**The fix that lasts is a check that compares the copies to EACH OTHER, with no version written
down.** `dev-scripts/preflight.ps1` now fails when two workflows pin different major versions of
the same action. Nothing in it goes stale, because it asserts agreement rather than a value: bump
one workflow and it demands the rest. A check that hardcodes "v7" becomes the wrong thing itself at
the next bump, and then gets edited to match rather than believed.

**Reach for this shape whenever a rule spans copies you cannot enumerate in advance** — workflow
action versions, bridge constants across adapters, a shared exclusion list. Assert that the copies
agree; let the value float.

## The decompilation says what the engine CAN do; only a measurement says what the game DOES (Crystal, 2026-08-26)

**Symptom:** a ghost did nothing sensible during a Fly landing, and the queue confidently said it
should fall out of the sky.

**Cause:** the Fly fall was implemented from `StepFunction_Skyfall`, which expresses the whole
descent in `OBJECT_SPRITE_Y_OFFSET` — one byte already on the wire since fishing. Every word of
that reading was correct, and the conclusion drawn from it was still wrong: **through an entire
Fly the player's own object holds action 1 (STAND), facing `$FF` and `yoff` 0.** The game hides the
player object for the sequence and animates it some other way, so that step function never runs on
the object we copy. There was nothing to send and nothing to reproduce.

**Fix:** none required in the code — the correction was to the claim. `probes/fly_probe.lua`
answered it in one run by logging the player and every occupied object slot on one line.

**The lesson is a direction, not a rule reversal.** `CLAUDE.md` says to read a cleared decompilation
FIRST, and that stands: it names fields and dispatch order a probe can never discover. What it does
not do is say which paths this game takes. Reading tells you *where to look*; only the running game
tells you *whether it goes there*. The failure here was reading REPLACING measuring rather than
aiming it — the same mistake as measuring without reading, wearing the opposite coat.

**The tell was available before the live test and was not asked for:** the change shipped with a
queue entry saying the fall "may have gained its fall for free — nobody has looked." A claim that
names itself unlooked-at is a claim to measure, not to write down and build on.

## A stale coordinate is indistinguishable from a live one, and the game may never clear it (Crystal, 2026-08-26)

**Symptom:** after a Fly, a painted ghost went invisible and never came back — but only when flying
to the town you were already in. Flying somewhere else looked fine.

**Cause:** `wMenuBorderTopCoord`..`RightCoord` hold a menu's geometry and are zeroed when a menu
closes normally. Fly's menu is not closed normally — a warp tears it down — so it left `0,10,15,19`,
the entire right half of the screen, set permanently. The adapter treated "these coordinates are
non-zero" as "a panel is on screen", re-latched on it every frame, and hid every painted peer
standing in that half for the rest of the session. The different-town case only *looked* fine
because a map load respawns the peer into the ENGINE tier, which that rectangle never applied to —
**a symptom that appears to depend on where you fly actually depended on which renderer was used.**

**Fix:** clear the latch where the world is rebuilt. A menu cannot survive a map load, so a
rectangle still set there is stale by definition.

**Two better-looking gates were tried first, and measurement killed both** — the reason the fix
lives at the map load rather than in a smarter freshness test:

- **"the panel's own frame tiles are in the tilemap"** — the exact test this adapter already uses
  for text boxes, and the drawing path really is shared (`MenuBox` → `Textbox` → `TextboxBorder`).
  The corner **survives the menu closing**: 87 consecutive samples said present, through a menu
  being opened and shut.
- **LCDC window-enable / WY / WX** — byte-identical with a menu open, with none, and after closing
  one (`LCDC=E3`, window enabled, `WY=144`, `WX=7`).

**The generalisable part: ask what CLEARS a field before trusting it as a state.** A field written
when something starts and never written when it ends is a record that it once happened, not a
statement that it is happening — and it will read as live forever after the one code path that
skips the teardown. When a signal has no reliable clear, do not hunt for a cleverer reading of it;
clear it yourself at an event you already trust.

**And a three-state table beats a third guess.** Two candidate signals had already failed when the
answer came from driving the state — no menu, menu open, menu closed — and printing every cheap
display byte for each. Both dead candidates were visible in that table at a glance, and so was the
real behaviour: the coordinates are set at frame 9 of the open and cleared at frame 9 of the close,
which is the level test the adapter had all along.

## A field that describes "the most recent X" cannot describe "every X on screen" (Crystal, 2026-08-26)

**Symptom:** a ghost painted over the top of the party menu — but only after choosing Surf
somewhere it fails, and persisting until the adapter reloaded.

**Cause:** the adapter clipped painted peers against `wMenuBorder*`, treating it as "the rectangle
of the UI on screen". It is not — it is a scratch slot describing the most recent box the game
DREW. The party menu publishes a full-screen rectangle; the "can't use that here" text box then
replaces it with its own bottom strip; and the adapter went on protecting six rows of a screen
that was entirely menu. Nothing ever re-publishes a covered menu's rectangle, so the fault
persisted for as long as the stack stayed up.

**Fix:** remember every distinct rectangle published while the UI latch is alive and hide inside
any of them. The union dies with the latch, exactly as the single value did.

**The general form: before clipping/gating against a singular engine field, ask what happens when
two of the thing exist.** A game UI is a stack, and any "current X" register describes the top of
it at best — usually just the most recent write. If the engine keeps only one slot, the adapter
must keep the history itself, bounded by the same signal that says the stack is gone.

**The capture method is worth keeping too:** the user could still reproduce it, so the fix waited
for one debug line from the live failure rather than being reasoned out — `boxOpen=true
coords=12,0,17,19 — painted at: p13-ghost@56,4` names the mechanism outright, and the debug line
had been extended an hour earlier to carry the raw coords precisely so a healthy-looking single
rectangle could not hide behind it.

## A fix validated on the neighbouring path, not the reported one (Crystal, 2026-08-26)

**Symptom:** "the spawned ghost was still invisible while using fly" — the same report the
morning's fix had already closed.

**Cause:** the stale menu-rectangle clear was placed in the AREA-CHANGE block, and the reported
case was flying to the town you are already in — a warp that keeps the same area id. The clear
never ran on the reported trigger. It was checked against a door crossing, which does change area:
the fix validated on the path next to the bug, and the report's own wording ("the same town that
you were in") already named the difference.

**Fix:** moved to the `not inPlay()` branch — `wMapStatus` leaves HANDLE on every warp, same-map
included, so the trigger set now contains the reported case by construction.

**The rule: re-test a fix on the EXACT trigger in the report, not on the nearest trigger the rig
makes convenient.** When a report distinguishes two variants ("same town" vs "another town"), that
distinction is data about the mechanism — here it separated same-area warps from area-changing
ones, which is precisely the line the broken fix was placed on.

## Three fixes in one day attached to a trigger that was a subset of the event (Crystal, 2026-08-26)

Not three unrelated slips — one habit, caught three times in a single session, each time by the
user re-testing and the symptom surviving:

1. **Stale menu rectangle cleared on AREA CHANGE**, when the reported case was flying to the town
   you were already in. Same-map warps do not change the area.
2. **The drawn tier's "world is rebuilding, do not paint" window, armed on AREA CHANGE** — same
   blind spot, same event, still unfixed after (1) was moved, because only the rectangle had been
   moved and the settle window right beside it was left on the old trigger.
3. **A fly-arrival drop armed on `teleportGhost`**, when a fly landing usually lands within three
   tiles (walked) or across a map load (respawned). The teleport branch is the path a fly rarely
   takes.

**The shape every time: the trigger chosen was a proper SUBSET of the event that mattered.** Area
change ⊂ map load. Teleport ⊂ ghost placement. Each subset is the *most familiar* member of its
set — the case already handled elsewhere, the one that comes to mind first — which is exactly why
it gets picked and why the gap is invisible in review.

**The check that would have caught all three, before any of them shipped: enumerate the event's
members and say which one the report describes.** "A ghost gets placed by: a step, a catch-up walk,
a teleport, or a spawn — the report says it walked, so the teleport hook is wrong" takes one
sentence and needs no rig. `../CLAUDE.md` already demands this for entering a STATE ("enumerate the
doors into a state before deciding one of them is the door", the Emerald surf blob, 2026-08-19).
The same rule applies to *events*, and that generalisation is what was missing.

**And when a fix like this is corrected, check its siblings in the same file immediately** — (2)
was sitting four lines from (1) on the identical wrong trigger and cost an extra live cycle.

**It reached five before the day was out.** (4) the fly-arrival drop compared the peer's old and
new tiles to detect a landing — but map coordinates are map-local, so a cross-town landing reads as
a three-tile hop and never armed; and (5) the same feature carried an explicit "never on a spawn"
guard, written to stop a promotion falling from the sky, which excluded the one path a cross-map
arrival actually takes. **Both are the subset habit wearing a different coat: (4) compared a
quantity that is only meaningful within one map, and (5) excluded a member of the set by name
instead of by the property that made it wrong.** (5) is the more instructive: the guard's REASON
was "a promotion must not drop", and the envelope already guaranteed that — so the guard was
excluding a path for a property it did not have. **When a guard names a case rather than a
property, check whether the property it cares about is already guaranteed elsewhere; if it is, the
guard is not protection, it is a second, coarser trigger that will exclude the wrong things.**

## A gate that defers a decision must also freeze the evidence it reads (Crystal, 2026-08-26)

**Symptom:** a fly-arrival drop that had just been fixed stopped firing entirely — no fall on either
tier, and no error anywhere. It read exactly like the feature was never reached.

**Cause:** the fix had added a gate — do not arm the drop while the world is still rebuilding —
which was correct. But the line that maintained the evidence for that decision, the peer's
last-known position, went on updating through the deferred frames. By the time the gate opened, the
"previous" position was the landing tile and the area matched it, so the jump the decision looks for
no longer existed. The deferral had consumed its own trigger.

**Fix:** freeze the last-known position for as long as a landing is pending.

**The general form: deferring a decision is only safe if the state that decision reads is held
still.** Whenever a gate is added of the shape *"not yet — wait until X"*, ask what the deferred
code will compare against when it finally runs, and whether anything mutates it in between. The
failure is quiet by construction: no crash, no wrong value, just a comparison that has become true
and a branch that never runs.

**And it is the reason a fix should be re-traced rather than re-watched.** This was the fifth
attempt at one symptom; the fourth was correct and introduced this. Only the trace could
distinguish "the drop ran and looked wrong" from "the drop never armed", and those two have
completely different causes while looking similar on screen.

## An edge-triggered trace on an ADDRESS cannot see the CONTENT change under it (Crystal, 2026-08-26)

**Symptom:** a peer's sprite garbled during a Fly landing and looked normal afterwards. The sprite
trace — which exists precisely to answer "which graphics is this peer being drawn from" — logged
two lines at session start and then nothing at all, through four flies.

**Cause:** the trace was edge-triggered on the peer's sprite id, the source branch, and the tile
BASE. All three were genuinely constant. What changed was the VRAM content under that base:
`FlyFunction_InitGFX` loads cutscene graphics for the duration of a fly and restores them after.
Adding a 16-byte signature of the actual pixels to the trace key made it fire on every fly
immediately — `sig=0906 -> 036A -> 0906`.

**Fix:** peers are drawn from the cartridge while a fly is in progress.

**This is the SECOND time this class has cost this adapter a session** — the first was the fishing
rod, written up as "the right ADDRESS pointing at the wrong ASSET". That entry did not prevent this
one, because it was recorded as a fact about the rod rather than as a property of resident
graphics. **The general rule: any tile base a game hands you is a lease, not a deed.** An engine
reuses VRAM for whatever it is doing now, so a base that was a character's a moment ago may be a
cutscene's, and nothing about the address says so.

**And the instrument rule that follows: when a trace keys on an identifier, ask what could change
without changing that identifier.** If the answer is "the thing I actually care about", the key is
wrong and the trace's silence is worthless. A cheap checksum of the underlying data is usually the
whole fix.

## An instrument blind to one of its two paths reads exactly like a quiet system (Crystal, 2026-08-26)

**Symptom:** a garbled STANDING pose, hunted with `MESHGHOST_CRYSTAL_FACING_TRACE` on. The trace
reported nothing across a whole session while the fault was visible on screen.

**Cause:** the learner stores standing frames and stepping frames on two paths, and the trace sat at
the bottom of the function — below `if (frame[1].offset & 0x80) == 0 then entry.stand = frame;
return end`. So it had only ever been able to report stepping frames. Every standing frame it ever
learned, correct or corrupt, was invisible.

**Fix:** trace both branches. The first run afterwards showed the corruption immediately — the DOWN
standing view alternating `[0,1,2,3]` with `[0,1,9,3]`, a left/right tile in a downward pose — and
also exposed the reason it got in: the group check validated `frame[1]` alone, so one foreign part
among four passed every test.

**The rule: before trusting a trace's SILENCE, check that it covers every path the value can take
out of the function.** An early `return` above the logging is enough to make an instrument
permanently blind to half its subject, and nothing about the empty log says so. Diff the trace's
position against the function's exits, not against its entry.

## A measurement from the wrong bank motivated an entire fix (Crystal, 2026-08-26)

**Symptom:** a peer's sprite garbled during a Fly landing. A pixel signature added to the sprite
trace showed VRAM content under the peer's tile base changing on every fly — `0906 -> 036A -> 0906`
— which looked like conclusive evidence that the cutscene borrows sprite VRAM, and three successive
versions of a fix were built on it (a timer, a learned reference, then cartridge validation).

**The signature was reading VRAM bank 0. Character graphics are in bank 1.** Once corrected, the
signature held perfectly steady through two clean flies: the peer's tiles are never borrowed at
all. Bank 0 holds other graphics that legitimately change during a cutscene, so the "evidence" was
real data about the wrong thing.

**What actually fixed the garbled sprite was the other change made in the same session** — the
frame learner's group check validating all four parts of a frame instead of only the first, caught
directly by the facing trace as the DOWN standing view alternating `[0,1,2,3]` with `[0,1,9,3]`.

**Three lessons, in order of how much they cost:**

- **The file already warned about this bank**, at `decodeTileAt`, written from the first thing the
  user ever said about the drawn tier (2026-08-19) — and it was rediscovered anyway, twice in one
  session: once in the check and once in the trace. **A warning attached to the ONE function that
  got it right does not protect the next reader who writes their own access.** Where a domain has a
  trap like this, the accessor should be the only way in (`readVram` + `VRAM_BANK1` here), and new
  code that reaches past it is the smell.
- **Two fixes shipped in one session make the confirming run ambiguous.** The group check and the
  VRAM guard landed together, so "it looks fine now" cannot say which did it — and only the
  corrected instrument, run afterwards, separated them. Ship one, or expect to do this work later.
- **An unexplained fix is not a finished fix.** The cartridge guard is kept because its invariant is
  true, but it now logs the first time it ever fires and says in that line that never appearing
  means it is dead weight — so a later session deletes it on evidence rather than on a guess.

## The session that cost the most, and what it was actually made of (Crystal, 2026-08-26)

One feature — a peer's Fly landing — took most of a day and about fifteen live cycles. It shipped,
and it is worth knowing where the time went, because almost none of it went into the feature.

**Six of my own edits were wrong in ways the tooling could not see.** Three scripted edits failed
to apply and said nothing; one left a name undeclared, which in Lua is a silent nil GLOBAL; one read
the wrong VRAM bank; one logged a value it had just written. Every one passed `luac -p`, because a
parse check confirms an edit is valid Lua, never that it happened or that it means what you
intended.

**And the rule against this was ALREADY in `CLAUDE.md`, dated 2026-08-21** — "re-read the FILE after
any scripted edit, because an unmatched pattern fails SILENTLY". So this was not a documentation
gap and no amount of further prose would have helped. What was missing was the MECHANISM, and it is
specific: these edits were multi-part Python scripts of the shape `assert old in s; s = s.replace(...)`
repeated several times, with one `write` at the end. **A failing `assert` anywhere aborts the whole
script, so the replacements that DID match are discarded along with it** — and the visible symptom
is a single `AssertionError` naming one edit, which reads as "one edit needs fixing" when it
actually means "none of them were saved". Fixing the named one and moving on is what lost the
others, twice.

**So the rule now carries the mechanism rather than the exhortation: one edit per script, and grep
the result back.** An `assert` proves the pattern matched at that moment; only reading the file
proves the change is in it.

**Five fixes were aimed at a trigger narrower than the event.** Area-change ⊂ map-load (twice),
teleport ⊂ ghost-placement, a coordinate comparison only meaningful within one map, and a guard
that excluded a case by name rather than by the property that made it wrong. Each time the chosen
trigger was the most FAMILIAR member of its set. Enumerate the members and say which one the
report describes — one sentence, no rig.

**Three instruments were blind or lying**, and each read as a healthy system: a trace below an early
return could only ever see one of its two paths; a trace keyed on an address could not see the
content change under it; a signature read the wrong bank and produced real data about the wrong
thing, which then motivated three versions of a fix for a problem that did not exist.

**What actually broke the deadlock was economics, not insight.** The user offered savestates at the
decision point, the loop became self-driving, and three faults fell in the time one live request
used to take. **When a loop is running at one iteration per user-request, fixing the loop beats
fixing the bug** — and the way to fix it is usually a prepared state plus a probe that presses the
button, not a cleverer theory.

**The last lesson is about the stand-in.** A vertical fall was accepted as a placeholder for a
spiral descent, and it read as a defect rather than a placeholder — so every report about it was
work on the wrong animation. A stand-in for something ANIMATED buys far less time than one for
something static, and this one cost more than building the real thing would have.
