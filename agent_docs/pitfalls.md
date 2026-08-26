# Adapter pitfalls

<!-- line-cap: 400 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

This file is the durable record of **adapter-specific** issues: things that went wrong while
building a game adapter, how they were tracked down, and what fixed them. It exists so the
next game adapter starts from the lessons already paid for instead of re-learning them.

**Scope boundary** — this file is not a duplicate of the others:

- `agent_docs/verified.md` holds confirmed runtime facts (dates, sources, human-gated). This
  file links to those entries by heading rather than restating the evidence.
- `agent_docs/risks.md` holds open/closed design risks and forward-looking assumptions. This
  file holds closed incidents: symptom → cause → fix.
- `agent_docs/phases/*.md` hold the chronological run-by-run log for each phase and stay
  around afterward as an archive — but they're long and narrative. This file pulls out the
  transferable lessons so a future adapter author doesn't have to re-read a whole phase's
  saga to find them.

## Index — every entry in this file

**This file IS the index, and the entries live in [pitfalls/](pitfalls/).** Split 2026-08-25:
the index and 5,000 lines of evidence were one file, so reading the lessons cost the whole
history. Now reading the lessons costs this page. **Nothing was re-filed** — the three body files
are the halves this index already declared, cut where it already drew the lines:

| File | What is in it | Reach for it when |
|---|---|---|
| [pitfalls/method.md](pitfalls/method.md) | Diagnostic methodology, failure signatures, instruments that lie | Before trouble, and when an instrument disagrees with the screen |
| [pitfalls/by-host.md](pitfalls/by-host.md) | BizHawk Lua, UE4SS, Unity, memory probing, overlay rendering | You know which subsystem you are touching |
| [pitfalls/by-lesson.md](pitfalls/by-lesson.md) | The chronological half, and the largest | You have a symptom and want the lesson that matches |

**The titles are the lessons.** That is why they are indexed rather than re-filed under themes,
and why a per-game split was rejected: a lesson found in Emerald has to be findable while working
on Crystal. `dev-scripts/preflight.ps1` checks that every heading in every body file appears here
— a taxonomy cannot be checked that way, which is why this is an index.

**Maintained by adding ONE line when you add an entry**, and new entries go at the END of
`by-lesson.md`, so appending never touches an existing one.

### Method, and instruments that lie — [pitfalls/method.md](pitfalls/method.md)

- A symptom word can name more than one subsystem — confirm which before probing (2026-08-16)
- Gating a handshake on its own result (deadlock, twice in one day) (2026-08-16)
- Diagnostic methodology
- An aggregate over a mixed series invents a defect that is not there (2026-08-25)
- Failure signatures
- Pitfalls by theme
- Cross-game comparison

### By host and subsystem — [pitfalls/by-host.md](pitfalls/by-host.md)

- BizHawk Lua: `event.onframeend` outlives its script; use a `frameadvance` loop
- BizHawk Lua: `debug.getinfo` gives no path — use the working directory
- Spawned actors auto-possessing (taking control away from the player)
- Camera / view-target ownership
- Runtime-spawned actors not rendering
- Engine reflection / API availability
- UE4SS C++ mod threading -- on_update() is not the game thread (2026-08-13)
- Level/scene transitions invalidating cached references
- Memory probing / address hunting (Emerald-style, static addresses)
- Overlay / sprite rendering (2D, retained-mode drawing APIs)
- Reconstructing continuous motion from discrete, throttled position samples (Emerald sub-tile glide saga, 2026-08-14)
- Host-embedded scripting runtimes, vendored DLLs, and ABI mismatch
- Vendored RE-UE4SS SDK marshals `FRotator` as `float` regardless of engine version (UE5 games) (2026-08-13)
- UFunction hooks work on native functions but CRASH on Blueprint functions (RE-UE4SS) (2026-08-15)
- Actor destroy unavailable on the ghost pawn — move offscreen, let the level's own teardown reclaim it
- Running two instances of the same emulator/game silently collide on a shared default port
- Personal paths reaching a public repo, and a leak-check that silently passes (2026-08-15)
- Two `git.exe` installs on one machine disagree about whether the tree is dirty (2026-08-15)
- `cmd` itself resolves to a devkitPro document, not an interpreter (2026-08-17)
- The diagnostics were the bug: probes that broke the effect they measured (2026-08-16)
- BizHawk's Lua console charges by BUFFER SIZE, and a day-long session pays it on every append (2026-08-25)
- Pooled objects: detecting "spawned" by object identity silently undercounts (2026-08-16)
- Latch event payloads to the event; don't republish them as per-tick state (2026-08-16)
- Sampling a multi-tick spawn once attributes its stragglers to the NEXT event (2026-08-16)
- A raw actor pointer added to a tracking struct must also be dropped in the pre-teardown hook (2026-08-16)
- Cross-adapter issues that were fixed in the core, not the adapter
- A guard that checks "did I get an answer" instead of "is the answer usable" (2026-08-18)
- A patched build's WRAM shift is NON-UNIFORM, and being right most of the time is the trap (2026-08-18)
- Pooling cuts both ways: a retirement move reads as a birth (2026-08-16)

### By lesson, in the order they were found — [pitfalls/by-lesson.md](pitfalls/by-lesson.md)

- A Gold/Silver GameShark code run on Crystal writes into the object RAM MeshGhost spawns into (2026-08-18)
- BizHawk accepts a GBA cheat code it cannot decrypt, and silently activates the garbage (2026-08-18)
- A spawned character renders a few pixels off its tile, forever (2026-08-18)
- A spawned entity leaks once per zone crossing, but survives doors fine (2026-08-18)
- A menu's contents are not fixed, and neither is its cursor (2026-08-18)
- An empty log reads exactly like "the game did nothing" (2026-08-18)
- A verification rule that reports clean while the thing it checks is broken (2026-08-18)
- Third time for the wrong-install-on-PATH trap — and it cost a capability, not just a build (2026-08-18)
- Inferring what a game is MEANT to do, and "fixing" a non-bug (2026-08-18, TEVI)
- A probe global outlives the probe, and then looks exactly like a real bug (2026-08-19)
- Saying "no" once per peer per frame costs more than the work being refused (2026-08-19, Emerald)
- ONE console line a second cost 7.4 fps — and the feature it was measuring cost nothing (2026-08-21, Emerald)
- Comparing two renderers: four ways to measure the wrong thing (2026-08-21, Emerald)
- "The game blocked me" was an NPC finishing a sentence (2026-08-19)
- PARTLY RESOLVED (2026-08-19) — Crystal: invisible collisions, and ghosts popping in and out
- A single screenshot cannot see a blinking thing (2026-08-19)
- Two things that share a file, and the silence that hides them — 2026-08-19
- Crystal: a drawn ghost paints over a FULL-SCREEN menu, because the adapter reads it as a text box (2026-08-19)
- A probe with its own frame loop freezes every other script — 2026-08-19
- Crystal: a nil address reads as byte 0, so an unmeasured entry SATISFIES a gate instead of refusing (2026-08-19)
- Crystal: the drawn tier needs a POSITIVE "is the overworld on screen", not a list of screens to avoid (2026-08-19)
- Calibrating on OAM entry 0: the entry ORDER swaps when the sprite flips (2026-08-19)
- Lua 5.4 refuses a bit shift on a float, and a smoothed position is a float (2026-08-19)
- A bridge port pinned in the environment cannot pin an ALREADY-RUNNING instance (2026-08-19)
- A hardcoded ROM address slipped past the refuse-if-unmeasured discipline an hour after it was built (2026-08-19)
- Frame tiles in the tilemap are not the same thing as a panel on screen (2026-08-19)
- A stray dev-scripts/config.json silently redirects a core to a relay nobody is running (2026-08-19)
- "A bit choppy" cost six rewrites, because it was three separate bugs and none were where I looked — 2026-08-19
- Approximating the game's own art never converges — read it instead, 2026-08-19
- A ghost has no task, so nothing ever un-pauses its animation — 2026-08-19, Emerald
- A value the game DERIVES cannot be COPIED — 2026-08-19, Emerald
- A script's writes land between frames; the game's land inside one — 2026-08-19, Emerald
- A sprite you BUILD is missing whatever the game's constructor computed — 2026-08-19, Emerald
- A world-space anchor built from a SPRITE carries the sprite's own terms — 2026-08-19, Emerald
- A rule that is right for one graphic can be wrong for another — 2026-08-20, Emerald
- Counters placed inside a gated block measure nothing — 2026-08-20, Emerald
- A stable field can read zero exactly when the thing it describes is happening — 2026-08-20, Emerald
- A character can face one way and move another — 2026-08-20, Emerald
- Two draw paths, and a fix applied to one of them — 2026-08-20, Emerald
- Occlusion has two sources, and one of them is a sprite — 2026-08-20, Emerald
- An adjustment that changes nothing is evidence about the MECHANISM — 2026-08-20, Emerald
- A watchdog that names what it caught — 2026-08-20, Emerald
- Emerald: a ghost that reports the right pose and DISPLAYS the wrong one (2026-08-20)
- Emerald: one tile of bike travel cost the ghost a whole pedal cycle (2026-08-20)
- Emerald: the mount/dismount pose war — five hours, three wrong instruments (2026-08-20)
- Emerald: the seam-crossing frame-killer, and the two habits that hid it (2026-08-20)
- Emerald: the seam-crossing pop was the CORE's, and every adapter instrument measured innocent (2026-08-20)
- Emerald: the vanishing hat — the panel scanner's flicker, and six innocent suspects (2026-08-20)
- CI: "could not find a port free for both tcp and udp" — the draw was rigged, 2026-08-20
- Emerald: ghosts blinking in and out in a doorway — two peers, one object slot (2026-08-20)
- Emerald: "laggy while moving" — a cull→respawn loop, console lines, and probes (2026-08-20)
- The dev loader shares ONE Lua environment — an unset flag keeps its old value (2026-08-20)
- Emerald: a NULL sprite callback is a SOFT RESET, not a glitch (2026-08-21)
- Emerald: the frame rate went to ~1fps, and it was the ALLOCATOR, not the drawing (2026-08-21)
- Emerald: dressing a ghost in a direction its body is not performing (2026-08-21)
- Emerald: `sprite->hFlip` is a BASE, not the flip (2026-08-21)
- Emerald: a ghost that WALKS a tile the peer JUMPED gets no ground effects (2026-08-21)
- Emerald: a remembered riding style outlived the peer's actual one (2026-08-21)
- Emerald: the ghost stopped hopping when it had nothing to cross (2026-08-21)
- 2026-08-21 (later) -- method notes from the water/warp session
- Emerald: a savestate load makes us draw from tiles we no longer own (2026-08-21)
- Emerald: a graphic swap left fresh tiles unwritten, and the ghost went grey (2026-08-21)
- Emerald: THE PAIR was wrong -- and fixing it did NOT clear the symptoms (2026-08-21)
- Emerald: the mount-blob saga — every authority for "where" lies during a transition (2026-08-21)
- Emerald: never hold an engine handle the engine can recycle (2026-08-21)
- Emerald: a gate written for ANIMATION also swallowed a POSITION (2026-08-21)
- Emerald: three renderers are a control group -- use them (2026-08-21)
- A probe written for one session leaked a home path into the repo (2026-08-21)
- Emerald: one field, two meanings — "not animating" is not "may not animate" (2026-08-21)
- Emerald: a "hold the pose" fix must hold the RIGHT pose (2026-08-21)
- Emerald: the drawn tier's freeze has to outlast the peer's flag (2026-08-21)
- Emerald: a floor that is right for a sub-pixel gap is wrong for a real distance (2026-08-21)
- Emerald: `goto_map` changed the map and placed nobody (2026-08-21)
- A fix named after WHERE it was found will be re-found somewhere else (Emerald, 2026-08-21)
- An explanation that only fits your own case is not an explanation (Emerald, 2026-08-21)
- Emerald: the painted tier is outside the PPU, so every hardware effect is its problem (2026-08-21)
- A clip's GATE is more dangerous than the clip (Emerald, 2026-08-21)
- Two write-only GBA registers that lie when read (Emerald, 2026-08-21)
- Lua's 200-local ceiling: the adapter does not load, and almost nothing says so (2026-08-21)
- A file can LOAD cleanly and then throw on every frame (2026-08-21)
- Lua: a use above its `local` is a silent nil, not an error (2026-08-21)
- BizHawk's drawing layer persists: "draw nothing" leaves the last frame (2026-08-21)
- Crystal does not fade the OBJ palette shadow, so Emerald's lighting trick has nothing to read (2026-08-21)
- A ghost inherits its template's flags, and a STILL object cannot animate (2026-08-21)
- Instruments that agree with each other can share a blind spot (2026-08-21)
- The dev rig's update rate is part of the experiment (2026-08-21)
- `extras` is opaque, so nothing that must be SMOOTH can ride in it (2026-08-21)
- Painted-tier motion: three attempts, all reverted, all the same mistake (2026-08-21)
- Crystal: our own ghost's OAM entries are indistinguishable from the player's (2026-08-22)
- An input-driving probe left loaded becomes a suspect in every later report (2026-08-22)
- Crystal: the learned frame measured its parts from OAM entry 0, so right-facing drew 8px left (2026-08-22)
- The rig ran the SHIPPED interpolation while the test needed none (Crystal, 2026-08-22)
- A WRITING probe that half-identifies its target corrupts everything else (Crystal, 2026-08-22)
- Adding one local silently unloaded the adapter -- an hour after fixing the same fault elsewhere (2026-08-22)
- Crystal: a ghost must NOT use the player's step type -- it scrolls the camera (2026-08-22)
- Crystal: the drawn tier's stutter was never in the drawing (2026-08-22)
- Three more instruments that lied, in the same session (2026-08-22)
- Crystal: the drawn ghost stutters at shipped settings but not at `-interp=0ms` — 2026-08-23
- Crystal: the drawn ghost's motion, from "stuttery" to clean — the whole chain, 2026-08-23
- Crystal: a spawned ghost was a TRAINER, and it hung the game (2026-08-23)
- A reverted `.go` file comes back as CRLF, and nothing shows you why (2026-08-23)
- Crystal: the end-of-walk snap was TWO faults sharing one trigger (2026-08-23)
- Crystal: a tier handover is a position handover, and a gap is a blink (2026-08-23)
- A scripted edit can land a thousand lines from where you meant it (2026-08-23)
- Crystal: the ghost jittered before stopping, and the "camera" was three different mistakes (2026-08-23)
- A peer walks, and the adapter reports `0 spawned as real objects` (Crystal, 2026-08-23)
- Interpolating a quantity that only moves in whole steps (Crystal, 2026-08-23)
- A ghost that is "static, but follows the player around" (Crystal, 2026-08-23)
- "It still flickers" after a fix aimed straight at the flicker (Crystal, 2026-08-23)
- A probe that returns a boolean cannot be sanity-checked (Crystal, 2026-08-23)
- An animation that plays without moving the character (Crystal, 2026-08-23)
- A local declared below its use, inside one function (Crystal, 2026-08-23)
- A probe committed with a developer's absolute path in it (2026-08-23)
- `pcall` catches errors, not loops — a malformed line froze the emulator (Crystal, 2026-08-25)
- A parked audit rots faster than the thing it audited (2026-08-25)
- Two probes had never parsed, and nothing in the repo could have told us (2026-08-25)
- A check that lists no files passes every time (2026-08-25)
- Planning on a model of the game you never watched (2026-08-18, Crystal)
- Splitting a file moves its content out from under that file's exclusions (2026-08-25)
- A cache whose comment claims it is invalidated, and nothing ever clears it (Crystal, 2026-08-25)
- A partition measured EXACT is only exact at the rate it was measured (Crystal, 2026-08-25)
- A cache with an invalidation comment and no invalidation (Crystal, 2026-08-25) — see by-host
- The right ADDRESS pointing at the wrong ASSET, and every check that starts from the name passes (2026-08-26, Crystal)
- The player does not own OAM entries 0-3, and a priority object silently moves every painted peer (2026-08-26, Crystal)
- A ghost that VANISHES is usually an adapter that was unloaded, and the loader log says so in one line (2026-08-26, Crystal)
- Splitting a file moved its content out of three exclusion lists, and CI went red on its own documentation (2026-08-26)
- A repo-wide fix covers the files that exist that day, and a file added later brings the problem back (2026-08-26)
- The decompilation says what the engine CAN do; only a measurement says what the game DOES (Crystal, 2026-08-26)
- A stale coordinate is indistinguishable from a live one, and the game may never clear it (Crystal, 2026-08-26)
- A field that describes "the most recent X" cannot describe "every X on screen" (Crystal, 2026-08-26)
- A fix validated on the neighbouring path, not the reported one (Crystal, 2026-08-26)
- Three fixes in one day attached to a trigger that was a subset of the event (Crystal, 2026-08-26)
- A gate that defers a decision must also freeze the evidence it reads (Crystal, 2026-08-26)
- An edge-triggered trace on an ADDRESS cannot see the CONTENT change under it (Crystal, 2026-08-26)
- An instrument blind to one of its two paths reads exactly like a quiet system (Crystal, 2026-08-26)
- A measurement from the wrong bank motivated an entire fix (Crystal, 2026-08-26)
