# How many ghosts can a game actually hold?

<!-- line-cap: 350 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**This is a first-class question for any adapter, and especially for an emulated one.** A modern
engine spawns actors until memory runs out; a 1998 handheld game has a fixed array of character
slots and a fixed hardware sprite budget, both decided long before anyone thought about
multiplayer. So "how many players can share a room" has a *per-game*, and often *per-map*, answer
that no amount of relay capacity changes.

**Ask it early.** It decides whether a game can host a crowd at all, what the adapter should do
when it cannot, and what a player is told when their friend is standing next to them and invisible.

## Method — measure it, don't reason about it

The rig that produced everything below, reusable for the next game:

1. **Generate real peers, not fake objects.** `meshghost-fakeadapter.exe` runs N synthetic clients
   in one process, each a genuine relay client sending genuine state:
   `-relay=127.0.0.1:7777 -room=default -game-id=<game> -area-id=<exactly what the adapter sends>
   -center=<player position> -radius=4 -dims=2 -clients=N -extras=@<file.json>`.
   This exercises the whole path — relay, core, bridge, adapter, engine — so the number that comes
   out is the number a real session would get. Poking objects straight into RAM would measure the
   engine and skip everything that decides whether the engine is ever asked.
   - `-extras` must be `@path` on Windows; a literal JSON argument gets mangled by shell quoting.
   - `-area-id` **must match what the adapter sends**, or every ghost is correctly despawned as
     "peer is somewhere else" and the measurement reads zero. Live case: walking into Elm's lab
     during a town-pinned flood emptied the screen instantly, which is the adapter being right.
   - The relay needs `-max-clients` raised (`80` here) and `-loopback` OFF, so the count is exact.
2. **Read the engine's own terms with a probe**: slots in use out of the array size, hardware
   sprite entries in use out of the hardware's, and how many ghosts the adapter actually spawned.
3. **Check the frame rate the same way**, by counting emulated frames over a wall-clock interval —
   "it looked fine" is not a measurement, and a game that quietly runs at 45fps is broken.
4. **Step the count up** (6, 12, 24, 36) and repeat **in more than one kind of map**. The answer
   changes with the map, and often changes for a different reason in each.

## Pokémon Crystal (Game Boy Color) — measured 2026-08-19

**Ceiling as measured: 9 ghosts, in both maps tested, for two different reasons. Everything past
that is refused cleanly, and the emulator never leaves 60fps.**

**The SHIPPED ceiling is now lower on purpose — see "What the crowd broke" below.** The adapter
stops at **10 characters on screen** (about 7 ghosts in New Bark Town) because that is what the
Game Boy can draw without dropping sprites, and it gives a ghost's slots back beyond 8 tiles so
the game's own characters can have them. The engine's 13/16 arrays are still the outer wall; the
hardware is the one that binds first once a crowd is actually standing around you.

| Where | Peers offered | Ghosts rendered | Object structs | Map objects | Hardware sprites | Frame rate |
|---|---|---|---|---|---|---|
| New Bark Town (outdoor) | 6 | 6 | 10 of 13 | 10 of 16 | 24–28 of 40 | 60fps |
| New Bark Town (outdoor) | 12 | **9** | **13 of 13 (full)** | 13 of 16 | 34–36 of 40 | 60fps |
| New Bark Town (outdoor) | 36 | **9** | **13 of 13 (full)** | 13 of 16 | 34–36 of 40 | **60fps** (600 frames / 10s) |
| Elm's lab (indoor) | 24 | **9** | 11 of 13 | **16 of 16 (full)** | **40 of 40 (saturated)** | **60fps** (600 frames / 10s) |

**The two pools, and which one runs out first.** Crystal has **13 object structs** and **16 map
objects** (`NUM_OBJECT_STRUCTS` / `NUM_OBJECTS`, from `pret/pokecrystal`'s
`constants/map_object_constants.asm`). Every map spends some of both on its own cast before a
ghost asks for one, and the two are not spent at the same rate:

- **Outdoors**, structs ran out first (13 of 13) while 3 map objects were still free — a struct is
  what an on-screen character needs.
- **Indoors**, map objects ran out first (16 of 16) while 2 structs were still free — the lab
  declares more map objects than it has characters visible at once.

So **the binding resource depends on the map**, and an adapter that reports only one of them will
sometimes say the wrong thing. That is why the "no room" log line names *which* pool ran out.

**Under both of those sits a hardware ceiling that no game can raise.** The Game Boy has **40
sprite entries** (`wShadowOAM`, `00:c400`–`00:c4a0`, 4 bytes each), and a raw dump showed each
overworld character using **exactly 4** of them, with every unused entry parked at `y=160`, one row
below the 144-line screen. **40 ÷ 4 = 10 characters on screen at once, ever** — player included.
In the lab the crowd pinned it at 40 of 40, i.e. the hardware completely saturated, and the user
confirmed **all ten still drew correctly, with no flicker or dropout**.

**The per-scanline limit is the one that actually bites, and it was measured rather than watched.**
The Game Boy draws at most **10 sprites on any single scanline** whatever the 40-entry total says,
and the user's honest answer to "can you see flicker?" was *"kinda hard to tell"* — which is the
correct answer for a 60fps effect and a good reason not to settle it by eye. A probe computed it
instead, counting for every scanline how many shadow-OAM entries overlap it:

- **Spread out naturally: never exceeded.**
- **Packed into a clump** (12 peers at radius 1.5 tiles, ghosts shoulder to shoulder): the worst
  scanline held **12** sprites, and **6–8 frames out of every 300** went over the limit — about
  2–3% of frames, each losing a quarter of one character. Real, and close to invisible.
- **Which one blinks is predictable**: the hardware keeps the first ten sprites in OAM order and
  drops the rest, and ghosts are appended after the map's own cast — so it is always the most
  recently arrived peer, never an NPC and never the player.

**What happens past the limit: nothing bad.** The extra peers are simply never given a body. With
36 peers offered against 9 slots, the game held 60fps exactly, no NPC was displaced or lost, and
nothing crashed. The adapter now logs it once a minute, naming the pool that ran out and how many
ghosts are present, because *"my friend is invisible"* and *"my friend is not connected"* look
identical from the player's chair.

### What the crowd broke — three defects the test found, all in one evening

Running the crowd was not a formality. With peers standing around New Bark the user reported, in
this order: NPCs popping in and out, invisible collisions, and an NPC drawn in halves. All three
were one root cause with three faces — **a ghost took engine resources the engine expected to get
back, and took them from the end the engine allocates from.**

- **Ghosts held object structs forever.** Crystal hands a struct to each of its characters as they
  come into range and takes it back when they leave; a ghost carries `FLAG1_WONT_DELETE`, so it
  never released. Measured at its worst: **11 of 13 structs held by ghosts, and an NPC standing
  ONE TILE from the player simply not drawn.** Fixed two ways — a ghost now gives its slots back
  beyond 8 tiles, and three structs are reserved for the game outright.
- **An off-screen ghost still occupied its tile**, so the player walked into a solid character
  they could not see. The same range rule fixes it: far away, the ghost is not there at all.
- **The game's own NPCs lost the draw fight.** The Game Boy keeps the first ten sprites in OAM
  order, which follows struct order — and the adapter allocated from the LOW end, putting ghosts
  ahead of the game's cast. Both pools now allocate from the top down, so when the hardware drops
  someone it drops a ghost. (Emerald's adapter already did this; Crystal's did not, and nobody had
  compared them.)

**The lesson for the next adapter**: a crowd is not a stress test of your code, it is a stress test
of *the engine's assumptions about who owns its resources*. None of these three appear with one or
two peers, and all of them are things a player would report as "the game is broken", not "MeshGhost
is broken".

**A peer with no slot has NO footprint at all** — read off the arrays, not argued from the code.
A census taken with the crowd live showed all 16 map objects accounted for: the lab's own 7 plus
exactly the 9 ghosts the adapter spawned, and nothing else anywhere. Collision in this game comes
from those arrays, so an unspawned peer cannot block a tile, be talked to, or be drawn. The only
cost it carries is a few memory reads per frame while the adapter re-tries.

**Ghosts stack on each other freely** — the same census had three on one tile and three on
another. The engine checks collision against the player's movement, not object against object, so
a crowd never jams itself; it can still box the player in.

**What this means for a real session.** Nine simultaneous visible peers on one map is far past
anything this project has planned, so Crystal's limit is not a constraint in practice — but it is
a *hard* one, and it arrives silently. A room of twelve players standing in one town would show
nine of each other, chosen by whoever arrived first.

## Pokémon Crystal — Route 39, and the first PACING measurement (2026-08-25)

**Why here.** Route 39 is the most demanding map this project has measured: its own cast holds
**11 of Crystal's 13 object structs**, leaving exactly **2** for ghosts, against the 9 free in New
Bark Town. Measured directly — the adapter spawned 2 and then logged *"no room ... object struct
slots are all in use. Ghosts already here: 2"* for every other peer.

**Why re-measure at all when 2026-08-19 already did this.** That run reported frame RATE (600
frames in 10s). A rate cannot see a hitch — ten frames lost inside one second still reads as 58fps
— and `dev-scripts/bizhawk-hitch-meter.lua` did not exist until 2026-08-21. These runs are the
first pacing numbers for a Crystal crowd.

**Rig:** shipped settings (relay default send rate, core default 250ms interpolation), loopback
OFF, `-max-clients=80`, player parked, 60s per run, `-area-id=1/13 -center=14,20 -radius=4`.

| Run | Peers | Rendered | emu fps | Hitches >20ms | Worst gap |
|---|---|---|---|---|---|
| Control — nothing loaded | 0 | — | 60.0 | 0/s | 17ms |
| Adapter attached, idle | 0 | — | 60.0 | 0/s | 17-18ms |
| **Spawn cap** (drawn tier OFF) | 12 | 2 spawned, 10 refused | 60.0 | 0/s | 17ms |
| **Drawn cap** | 12 | 2 spawned + 10 painted | 60.0 | 0/s | 17-18ms |
| **Max pressure** | 36 | 2 spawned + 34 painted | 60.0 | **1/s** | 20-28ms |
| Max pressure | 60 | 2 spawned + 58 painted | 60.0 | **1-2/s** | 22-31ms |
| Max pressure | 100 | 2 spawned + 98 painted | 60.0 | 3-6/s | 32-43ms |
| **Past the wall** | 160 | 2 spawned + **158 painted** | **29-33** | **19-24/s** | **82ms** |
| Attribution: same flood, tier OFF | 160 | 2 spawned, 158 refused | **60.0** | 5-17/s | 42-57ms |

**What it says.** Up to **98 painted characters the emulator holds a full 60fps**, and the cost
appears only as pacing: free to a dozen peers (indistinguishable from the control), about one
20-28ms frame per second past ~34, and 3-6 hitches per second at 98. Rate alone reports "60fps"
across that entire range and can see none of it.

**The wall is between 100 and 160 painted, and it is a cliff rather than a slope.** At 158 the
frame rate HALVES — 29-33fps, 19-24 hitches a second, 10-12 frames over 33ms, worst gap 82ms.

**That halving is the painting, not this machine.** The same 160-peer flood with only
`DRAW_OVERFLOW` turned off — identical relay, core, network traffic and load-generator CPU, the
adapter still tracking all 158 peers and re-attempting their spawns every frame — runs at a **full
60fps**. Subtraction, not inference: the one removed variable is the paint. (Its residual 5-17
hitches a second are the load generator competing for this machine, and they are present in both
sides of the pair, which is what makes the rate comparison sound.)

**The spawn-refusal path is free** at every size tried: 10, then 34, then 158 peers re-attempted
every frame cost nothing measurable. Emerald's allocate/cull trap (`pitfalls/`) is not present here.

**None of this is a shipping limit.** The adapter's own ceiling is ~10 characters on screen, and
Route 39 offers 2 engine slots — so 98 painted is already an order of magnitude past any real
session, and the wall past it is a stress-test fact, not a player-facing one.

**What this rig CANNOT see, and it matters.** The synthetic peers never exercise the drawn tier's
STEPPING render path: `stepping view drawn on 0 of 646854 peer-frames` across every run, because
`-extras` is a static JSON object and `prog` therefore never cycles. Adding `-facing-follows-path`
fixed the facing half (`0 with no facing yet`) and not this half. **So every number above is a
FLOOR, not a worst case** — a crowd of real walking peers renders a per-peer animation these did
not. Closing that needs either a second real game instance or a game-specific synthetic driver
that cycles `prog`; `meshghost-fakeadapter` is game-agnostic on purpose and is the wrong place for
it.

**One rig defect worth not repeating**, and it was caught by the user's eyes rather than by any
log: the first drawn-tier runs measured the tier while it was OFF. The dev loader shares one Lua
environment, so `MESHGHOST_CRYSTAL_DRAW_OVERFLOW = "0"` set by the earlier spawn-cap run survived
into the next, whose flags file merely omitted the line. The adapter's `holding: painted{...}` line
lists peers WAITING for the tier, so it looked right; the `tiers:` line, which reports what was
actually drawn, was absent because it only prints when the tier runs. **Set every flag explicitly
every run, and check `tiers:` before believing a drawn-tier number.** The rule this violates was
already written down in `adapters/emulator/CLAUDE.md`.

## Pokémon Emerald (Game Boy Advance) — measured 2026-08-19

**Ceiling: `16 − (objects the map currently has)`, which was 13 ghosts in Littleroot Town. The
hardware is nowhere near being the constraint — the engine's array is the whole story.**

| Location | Peers offered | Ghosts rendered | Object slots | Sprite table | OAM | Frame rate |
|---|---|---|---|---|---|---|
| Littleroot town (3 map objects) | 6 | 6 | 9 of 16 | 13 of 64 | 8–9 of 128 | 59.7 |
| Littleroot town | 12 | 12 | 15 of 16 | 19 of 64 | 15 of 128 | 59.7 |
| Littleroot town | 18 | **13** | **16 of 16 (full)** | 20 of 64 | 16 of 128 | 59.7 |
| Littleroot town | 36 | **13** | **16 of 16 (full)** | 20 of 64 | 16 of 128 | 59.7 *(after the fix below)* |
| **Route 101** (6 objects) | 12 | **10** | 16 of 16 (full) | 30–31 of 64 | 26–27 of 128 | 59.7–59.8 |
| **Route 101** | 36 | **10 → 11** | 16 of 16 (full) | 28–30 of 64 | 16–25 of 128 | 59.7–59.8 |
| **Indoors**, house, 2 NPCs | 24 | **13** | 16 of 16 (full) | 20 of 64 | 16 of 128 | 59.7–59.8 |
| **Indoors** | 36 | **13** | 16 of 16 (full) | 20 of 64 | 16 of 128 | 59.7–59.8 |

**Indoors the ceiling is stable; outdoors it is not** — and that is the sharpest difference
between Emerald's maps. Every indoor sample at saturation was byte-identical across ~2 minutes and
three peer counts (`16/16, 20 sprites, 16 OAM, 13 ghosts`), because an indoor map's cast is fixed
and nothing loads or unloads with the camera. On Route 101 the same measurement gave 10 ghosts on
16 samples and 11 on 5: the cap **moved mid-run** as a route NPC unloaded, and a queued ghost took
the freed slot within a second, unprompted. A player walking a route has a ceiling that breathes.

**Outdoors costs more sprites per character** — 16 characters used 30 sprites and 27 OAM on the
route versus 20 and 16 for the same 16 indoors, because tall grass adds a rustle field-effect
sprite per character moving through it. Still far from the 64/128 ceilings, so the object array
remains the only real limit on every map type measured.

**No NPC was displaced, and that is measured rather than eyeballed**: on the route with 11 ghosts
the array held `16 − 11 = 5` game objects, the same five it held with no peers at all; indoors ids
0–2 stayed the game's throughout while ghosts took 3–15. Ghosts allocate downward from slot 15,
the engine upward from 0. Baselines were restored exactly when the peers left, with no orphans.

**Still unobserved, and worth a human's eyes:** the reverse direction — the array saturated by
ghosts while a *new* NPC scrolls into view. Only the unload direction was ever caught. The
mechanism predicts the newly-visible NPC gets no slot, which would be a missing NPC on a crowded
route. **Crystal's equivalent of this was not hypothetical** (see its section), so do not assume
Emerald's allocation direction makes it impossible — confirm it.

- **A GBA overworld character is ONE OAM entry**, not four — 16×32 is a native object shape on
  that hardware. So 13 ghosts plus the player and NPCs used **16 of 128** sprite entries. Where
  Crystal's ceiling is a negotiation between the engine and the console, Emerald's is purely the
  engine's 16-entry `gObjectEvents`, with the 64-entry sprite table a distant second.
- **The ceiling MOVES during play.** The same town read 3, 2 and 1 active objects from different
  camera positions, so the number of free slots changes as you walk — and a placed ghost can lose
  its slot when a nearby NPC loads. Crystal's map objects are fixed per map; Emerald's are not.
- **Route and indoor rows are missing, and the stated reason for that was WRONG.** The agent that
  measured this reported Route 101 as *story-blocked*, having driven into an NPC who spoke to it.
  **The user corrected it the same day: nothing was blocking anything.** That NPC is the *"please
  go help"* stop — it interrupts you, says its piece, and then lets you walk straight up into the
  route. The genuinely blocking version of that NPC (*"it's dangerous, you can't go there yet"*)
  had already been cleared earlier in the save. The agent stopped one **A press** short of the
  measurement and wrote the wall into the record as a fact about the game.
  **The lesson is `pitfalls.md`'s, not this file's**: an NPC talking to you is not an NPC blocking
  you, and "I could not get there" is a statement about the driver, not about the game.

**The defect this measurement found, which is the reason to run it at all.** Past the ceiling
Emerald did not degrade gracefully — it became **unplayable: 3fps at 24 peers, 1fps at 36**. For
every peer that could not be placed, every frame, the adapter re-scanned both arrays *and* called
`console.log`, which in BizHawk appends to a GUI window: roughly 1,400 console writes per second
at 36 peers. Throttling the message to once per 5s and remembering the refusal for the rest of the
frame restored 59.7–59.8fps with 13 ghosts placed. See `pitfalls.md`.

**Both adapters had the same shape of bug and only one of them showed it**, which is worth
remembering when reading the Crystal table above as reassurance: Crystal survived 62 offered peers
at a flat 60fps because its refusal path happens to be cheap and its log line is rate-limited to
once a minute. Nothing enforced that; it was luck, until it was measured.

## Pseudoregalia (UE5) — measured 2026-09-01, after the three crowd fixes

**No hard ceiling: 150 ghosts rendered, every one spawned, named and animated. The limit is frame
rate, and it is the adapter's own per-ghost tick cost plus the engine's pawn cost — linear to 32
peers, superlinear past ~50.** Measured on the fixed build (bounded Welcome, write-poisoning,
latest-wins drain — each found by an earlier rung of this same ladder); idle orbiting peers with
nametags, one machine carrying the game, relay and all N synthetic cores at once.

| Peers | Adapter tick | Per-ghost | ~Frame rate |
|---|---|---|---|
| 0 | 1.4 ms | — | ~143 |
| 2 | 2.2 ms | 340 us | ~139 |
| 4 | 3.0 ms | 319 us | ~133 |
| 8 | 4.4 ms | 332 us | ~124 |
| 16 | 8.0 ms | 321 us | ~82 |
| 32 | 12.7 ms | 312 us | ~53 |
| 100 | 55.8 ms | 454 us | ~12 |
| 150 | 166.6 ms | 657 us | ~4.5 |

Removing the crowd returned the tick to 1.9 ms within 25 seconds; full frame rate needs a world
rebuild (a reset-to-save clears the destroyed pawns the GC has not collected yet).

- **Per-ghost cost is flat ~320 us to 32 peers, then RISES with population** (657 us at 150):
  name-based reflection scales with total object count, so big-room numbers cannot be
  extrapolated from small-room ones. `loop_tail` (the per-ghost redraw span) is ~80% of it and
  is instrumented in four sub-slots for the next optimization pass.
- **The comfortable band on this machine: ~30 peers at 50fps+, ~16 at 80fps+.** Contrast the
  pre-fix state, where ONE peer cost 144 -> 70fps (four whole-world scans; `pitfalls/method.md`).
- The synthetic rig itself is a real cost at 100+: the relay fanning N x N states burned multiple
  cores. A two-machine run is the honest next measurement for the big rungs.

### The property-cache re-run (2026-09-01, same day): every rung roughly twice as fast

Post-cache (`plans.md` step 2), same rig, agent-measured, unwatched: **16 peers 2.8 ms/~133fps
(was 6.9/~82), 32 peers 5.1 ms/~90fps (was 12.7/~53), 100 peers 25.5 ms/~16.5fps, 150* 33 ms/~11fps.**
The comfortable band moved from ~16 peers at 80fps+ to ~32 at 90fps (solo baseline ~143), and
the rise-with-population halved but survived (97 -> 219 us/ghost, was 321 -> 657): the riser left is
`tail_sweeps` (the outline attach walk, 51 -> 108 us/ghost) plus `local_state`/`ls_rest` at ~6 ms
each by 150 despite iterating no ghosts -- `ls_rest` is unsplit and next. *150 was dirty: ~114
live, the relay reset 17 fake cores under single-box load. Detail: `pseudoregalia/UNVERIFIED.md`.

## What to do about a ceiling you cannot raise — BUILT FOR CRYSTAL, 2026-08-19

**Do as much as the game can handle on its own, then fake it above that cap** (the user's rule,
2026-08-19). **Crystal now does exactly that, and the ceiling is gone in practice**: 89 peers
offered on a 10x9 window rendered 89 characters at 60fps, user-confirmed — the engine holding as
many as it can and the adapter painting the rest. Emerald's equivalent is built and still shipped
OFF (`MESHGHOST_EMERALD_DRAWN_OVERFLOW`, `FLAGS.md`); its UI regions were measured on two maps
2026-08-19 and it does clip a real panel. The painted tier itself has since been watched by the
user in ordinary play — the Acro Bike, surfing/diving, ice, fog and cave darkness were all judged
on all three tiers 2026-08-20/21 (`verified.md`) — but the flag's default stays off until the
clipping has been repeated under controlled play. Emerald also gained a middle rung between the
two on 2026-08-21, the hardware-sprite tier (`MESHGHOST_EMERALD_HW_OVERFLOW`, also off by default),
which the PPU draws and which therefore gets occlusion and palette fades the painted tier lacks.
Details, costs and the measurements:
`ideas.md`, `phases/phase9.md`, and Crystal's `BANDAGES.md` entry 1.

**Three leaks only a crowd could have found**, all in the new tier and all invisible individually,
because a leaked drawn ghost looks exactly like a peer standing still: a peer who **left** kept
being painted, a peer who walked into **another map** kept being painted, and every drawn position
survived a **map change** having been computed against the old camera. The rule that falls out:
with two rendering paths, every lifecycle message must reach both, and the tier that gets missed
is the one with no engine bookkeeping to go stale.

### The general form

Spawn real objects while the engine has slots — they get animation, occlusion,
priority and collision for free — and draw the overflow over the emulator's output, which is
subject to none of the engine's or the hardware's limits because it happens after both. Hardware
tricks like per-scanline OAM multiplexing do **not** substitute: they relieve the drawing limits
while the engine still has nowhere to record another character.

Filed, not scheduled, with the costs and the which-peers-get-the-good-tier question:
`ideas.md`, "Spawn to the game's cap, then DRAW above it". The rule itself is in
`adapters/_template/README.md`.

## For a new adapter

Put the answer in the adapter's `documentation.md` (it is a fact about the game, not a
compensation), and make the adapter **refuse cleanly and say so** rather than writing into a slot
it does not own. `adapters/_template/README.md` asks the question as part of bringing a game up.
