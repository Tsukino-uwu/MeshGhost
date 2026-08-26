# Pokémon Emerald

<!-- line-cap: 400 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**Status: feature complete 2026-08-21 — the user's call**, in their words: *"i consider the
game to be fully synced up animation and effect wise now."* Every way this game moves a character
and every field effect it hangs off one is mirrored, on all three rendering tiers. First game
targeted, shipped, and live-tested with real two-player sessions.

**Reopened 2026-08-26 to finish Fly**, which was one of the two states that call had never
actually tested. Fly is now built and partly confirmed but **not complete** — the user, that day:
*"good nuff for now"*, and *"not properly working fully yet"*. Four compensations are named in
[BANDAGES.md](BANDAGES.md) §4. The **boat** is the other state: built, and never once watched.
**Rails are neither** — not built, not measured (step 38 below;
[UNVERIFIED.md](UNVERIFIED.md), [status.md](../../../../agent_docs/status.md)). See
[agent_docs/phases/phase8.md](../../../../agent_docs/phases/phase8.md) for the full record.

- Platform: GBA, played via BizHawk.
- Confirmed working roms: "Vanilla", "Archipelago 0.6.7".
- **Targets, not yet supported: "speedchoice-1.2.2", "ex-speedchoice-0.4.0"** — work started
  2026-08-21. Both relocate the ROM non-uniformly (SPEEDCHOICE has at least seven distinct deltas;
  EX SPEEDCHOICE is a 32 MB build that also changes graphics outright), so the two-layout scheme
  this adapter ships cannot reach them. Nothing has been run on either.
- **It writes game RAM** — object RAM only (`gObjectEvents`, `gSprites`, the sprite-tile
  allocation bitmap, and the shadow-OAM window above `gOamLimit`), never a save, cosmetic only,
  and only on a ROM whose addresses were measured. Cleared by
  `agent_docs/architecture.md`'s 2026-08-18 ADR, which extends Crystal's spawn ADR to this
  adapter. The adapter's own header said "Never writes memory" until that day; see
  [BANDAGES.md](BANDAGES.md) for the ROM guard that decides where it may write.
- Adapter language: Lua (BizHawk's scripting host).
- **How the game is read: an external source decompilation.** Fixed memory addresses, looked up in
  [`pokeemerald`](https://github.com/pret/pokeemerald) and cited — nothing is discovered at runtime.
  Addresses are unknowable but authoritative: you cannot invent one, and once the decomp gives it to
  you it is right. See [agent_docs/access-models.md](../../../../agent_docs/access-models.md) for what
  each access model costs and what the other adapters used.
- **Rendering is a three-rung ladder: spawn → OAM → drawn.** A peer is first a **real object
  event plus a sprite**, which Emerald itself animates, walks and occludes (step 18 below). Past
  the engine's own object cap a peer gets **real GBA hardware sprite entries** in the shadow-OAM
  window the engine never touches, so the PPU draws it with background priority and the live
  palette (step 27). Past that it is **painted** with `gui.*` pixels — steps 1–9's original path,
  which survives as the overflow tier. Both overflow rungs ship OFF; the ladder, its exceptions
  and every switch are in [FLAGS.md](FLAGS.md), and what each rung compensates for is in
  [BANDAGES.md](BANDAGES.md). **The hardware rung has two of those exceptions**: it stands down
  under a screen-covering semi-transparent sheet (weather fog, underwater), and it is **vanilla
  only** — on an Archipelago ROM it declines outright.
- **[documentation.md](documentation.md)** describes how Emerald itself works — where player state
  lives and why one address is not enough, the tile-based movement model, the callback that says
  which state machine is running, how maps join at a seam, and how the sprite table is laid out.
  It was previously argued that a game with a decompilation needed no such file; **the user
  overturned that 2026-08-18** and every adapter now carries one. A curated description of the
  mechanics this adapter depends on is a different artifact from the decompilation, and being able
  to look something up is not the same as having looked
  ([adapters/_template/README.md](../../../_template/README.md)'s folder convention).
- Reading local state is trivial — the `pokeemerald` decompilation documents player X/Y,
  map bank/number, and camera offset rather than requiring reverse engineering. See
  [agent_docs/licensing.md](../../../../agent_docs/licensing.md) for the rule on how that decomp
  may and may not be used.
- Tile-grid movement means small integer positions; the brief's original "10Hz sync looks
  fine" hypothesis was superseded once real send-rate limits shipped — the real cap is 20Hz
  (`core.DefaultMinSendInterval`), live-confirmed across the three games shipping at the time —
  Emerald, TEVI and Pseudoregalia; **Crystal is the fourth and came later** (2026-08-18) (see
  [agent_docs/contract.md](../../../../agent_docs/contract.md)'s Limits section).
- No ROM is or will be shipped with this repo. Bring your own legally-obtained copy.
- The shipped/maintained adapter script is `meshghost_emerald.lua`, in this folder — that's
  what `.github/workflows/release.yml` ships and what any future fix belongs in.
  `phase5_5_sprite.lua` is a historical copy under its original development-phase name (split
  off 2026-08-14, byte-identical only at that moment — see that file's own header for how far
  it's since diverged) — the "How this adapter was built" section below is the accurate
  history of how it came to be, under whatever name it had at each point.

See [agent_docs/contract.md](../../../../agent_docs/contract.md) for the adapter interface and
tick model this adapter must implement, and
[agent_docs/phases/phase8.md](../../../../agent_docs/phases/phase8.md) for the current
verification task list.

## Limits that come from the game, not from us

Measured 2026-08-19 and 2026-08-21 with real peers over the real relay. Full tables and method:
[agent_docs/crowd-limits.md](../../../../agent_docs/crowd-limits.md).

- **The engine's own tier holds `16 − (the most objects this map has ever shown) − 1 reserved`
  ghosts** — **12** in Littleroot Town, 11 on the map the tier comparison used. `gObjectEvents`
  has 16 entries and every NPC shares it. The budget is measured against the running *maximum*
  rather than the current count, because budgeting against the current one hands out slots the
  engine wants back two steps later. (`crowd-limits.md`'s table records **13**: it was measured
  2026-08-19, against the current count and before the reserved slot existed.)
- **The ceiling moves while you walk.** The same town reported 3, 2 and 1 active objects from
  different camera positions, so free slots change during play and a ghost can lose its slot when
  a nearby NPC loads.
- **The hardware is not the constraint here.** A GBA overworld character is a single OAM entry, so
  13 ghosts plus the cast used 16 of 128. (Crystal, on the Game Boy, hits a hardware wall of ten
  characters — this one does not.) The hardware tier adds **56** more characters on top of the
  engine's own, and both full at once — **67 characters on screen** — still measured 60.0fps,
  indistinguishable from a bare emulator.
- **The painted tier is the rung that costs.** Those same 56 peers painted instead cost a third of
  the frame rate. That comparison is why the ladder is ordered the way it is, and why both overflow
  rungs are opt-in.
- **Past every rung, extra peers are refused and never appear**; nothing is corrupted and no NPC is
  displaced. That path used to cost the game its frame rate — 3fps at 24 peers — because the
  adapter re-scanned and logged per unplaceable peer per frame; fixed 2026-08-19, now a flat
  ~59.7fps with 36 peers offered.

## How this adapter was built

First game targeted, so the server and client didn't exist yet either — this build included
making those, not just the adapter. Getting from nothing to "good enough" (the end of
Phase 5.5) took about 10 hours.

Roughly in order, with the phase file that covers each part in more depth:

1. Drew a static purple box on screen as proof the overlay-rendering path worked at all.
   ([agent_docs/phases/phase2.md](../../../../agent_docs/phases/phase2.md))
2. Probed memory while walking in each direction, recording what changed, to find the
   position-related addresses. ([agent_docs/phases/phase1.md](../../../../agent_docs/phases/phase1.md))
3. Probed again while facing each direction without moving a tile, to separate "facing" from
   "position" in what had been found. ([agent_docs/phases/phase1.md](../../../../agent_docs/phases/phase1.md))
4. Made the box follow the player, still drawn at a fixed point on screen.
   ([agent_docs/phases/phase2.md](../../../../agent_docs/phases/phase2.md))
5. Made the box track world position instead of screen position, so it stayed correct whether
   the player was on- or off-screen. ([agent_docs/phases/phase2.md](../../../../agent_docs/phases/phase2.md))
6. Tested going in and out of buildings and between routes, to check position tracking
   survived map/warp transitions. ([agent_docs/phases/phase1.md](../../../../agent_docs/phases/phase1.md),
   [phase2.md](../../../../agent_docs/phases/phase2.md))
7. Replaced the static box with an idle sprite that moves around.
   ([agent_docs/phases/phase5_5.md](../../../../agent_docs/phases/phase5_5.md))
8. Added a walking animation. ([agent_docs/phases/phase5_5.md](../../../../agent_docs/phases/phase5_5.md))
9. Added a running animation — initially just the walk cycle sped up, corrected to Emerald's
   real, separate running pic table once live testing showed it looked wrong.
   ([agent_docs/phases/phase5_5.md](../../../../agent_docs/phases/phase5_5.md))

The real networking — the relay, the core, and the bridge protocol connecting an adapter to
both — got built alongside this adapter rather than before it, since Emerald was also the
first game to need it. [phase3.md](../../../../agent_docs/phases/phase3.md) (loopback: one real
client, a synthetic echoed "ghost") and [phase4.md](../../../../agent_docs/phases/phase4.md) (two
real players, join/leave, despawn on disconnect) cover that side.
[phase5.md](../../../../agent_docs/phases/phase5.md) is not Emerald-specific — it's where the
core got proven game-agnostic by running it against a fake, non-Emerald adapter, which is what
let TEVI (Phase 6) reuse it directly.

See [agent_docs/phases/phase1.md](../../../../agent_docs/phases/phase1.md) through
[phase5_5.md](../../../../agent_docs/phases/phase5_5.md) for the detailed, dated log of this
work, and [agent_docs/pitfalls.md](../../../../agent_docs/pitfalls.md) for the transferable
lessons pulled out of it (memory probing methodology, overlay rendering gotchas, map-transition
read glitches).

### Further work past "good enough"

Real work continued after Phase 5.5 closed — given its own phase file,
[phase8.md](../../../../agent_docs/phases/phase8.md), rather than 1–5.5 (which bundled Emerald
with building the server/client/core themselves) or living homeless in `status.md`. Roughly in
order:

10. A review/refactor sweep fixed several real socket-framing and crash-safety bugs (partial
    send/receive, dead-socket detection, a `pcall` guard, JSON control-character escaping).
11. Ran a real two-peer (non-loopback) session for the first time; found and fixed a
    port-collision test-setup mistake along the way, not an adapter bug.
12. A real Archipelago-patched ROM broke this adapter in four distinct ways — a relocated
    `CB2_Overworld`, relocated sprite/palette data, relocated `gObjectEvents`/`gPlayerAvatar`,
    and a timing bug in that last fix — all found via live memory investigation and fixed.
13. Found and fixed a gender-read timing bug — it could resolve before character creation
    finished on a fresh save; now gated on being confirmed in the overworld.
14. Found and fixed a sub-tile movement-smoothing bug once local testing stopped hiding it —
    the self-correcting glide-duration scheme was measuring idle time as step time; replaced
    with fixed per-anim timing after two other fixes were tried and disproven.
15. Taught the emulator to work for us, which turned out to matter more than any single fix.
    A loader script attached once at launch now loads, swaps and drops any number of scripts
    from a one-line control file — so an edit costs no relaunch, and the adapter and a test-state
    script run side by side. Before this, every probe revision interrupted whoever held the pad.
16. Kept going through the rest of what BizHawk exposes, once it was clear how much was sitting
    unused: savestates (all ten slots, save and load), the cheat engine, a Lua syntax checker,
    controller input, and screenshots the agent can read. Reaching a test state stopped costing
    real playing time — checkpoint once, restore instantly, forever.
17. Wrote down the limit in the same breath. A screenshot answers "what is on screen now", never
    "does this look right moving", so it changes no rule: the user still confirms every visual
    claim personally. That is the anti-hallucination split this project rests on — see
    [testing.md](../../../../agent_docs/testing.md).
18. Replaced the drawn ghost with a **spawned one**. A peer is now a real object event plus a
    sprite, and Emerald's own engine draws, animates and walks it — no drawing code at all. It
    is hidden behind the pause menu, which the overlay never was, and gets the right gender and
    palette for free by borrowing the player's own graphics.
19. Six bugs came out of that, each found by watching rather than reading, and the logs looked
    healthy for every one: a ghost wearing the player's animation frames (it had no tiles of its
    own), talking to a ghost launching the slot machine, a ghost frozen after one step, a run
    that was really a fast walk, a sprite a few pixels off its grid, and — the worst — a solid
    ghost leaked at every route crossing, which would eventually wall the route off.
20. The leak taught the general lesson: **"the map changed" and "the world was rebuilt" are
    different events.** A house rebuilds the world, a route boundary does not, and an identity
    check keyed on the map is wrong in exactly the case the other one hides. Houses had tested
    perfectly clean. ([_template/README.md](../../../_template/README.md))
21. Scoped what a peer's *special* states would take — surf, both bikes, ledges, rail sections.
    Half was already solved, because every special state is simply its own `graphicsId` and no
    animation classifier is needed; what remained was rendering each one, since a ghost borrows
    the player's graphics. Every state on that list has since landed, in steps 22–36.
22. Made a peer's fishing look exactly like the player's, on both renderers. A ghost holds a
    rod because it copies the peer's `graphicsId`, but the rod only *moves* because the game's own
    fishing task drives it — and a ghost has no task, so it sat on the animation's first frame and
    slid 8px sideways whenever the frame changed. Two things fixed it: asking the engine to animate
    the ghost through its own `enableAnim` switch, and computing the sprite offset from the frame
    the ghost is actually showing rather than copying the player's, at the point in the frame where
    the game itself does it. ([pitfalls.md](../../../../agent_docs/pitfalls.md) has all three
    write-ups; [probes.md](../../../_template/probes.md) has how it was finally measured.)
23. Took ghosts across the seam. A peer on a *connected* neighbouring route is now visible from
    this one, while a peer inside a house is correctly not — the difference being that indoor maps
    carry no connection list at all, so the engine states the rule for us. Peers are translated
    into the local frame at ingest and re-translated every frame, so the player's own crossing
    rebases everyone on the same frame. It cost the contract a revision: the core used to filter
    peers by `area_id`, and Emerald now declares `render_all_areas`
    ([architecture.md](../../../../agent_docs/architecture.md), ADR of 2026-08-20).
24. Put a peer on the Mach Bike, and made a ghost something you can walk through. The walk-through
    uses the engine's own elevation rule rather than a collision hack — the same mechanism the game
    already uses for a character on a bridge — which is why it costs nothing and behaves correctly
    everywhere instead of only where it was tested.
25. The muddy slope, where facing and movement come apart, and where the lesson generalises past
    this one game: **Emerald keeps a rider's speed in three unrelated places** — `bikeSpeed` for
    the Mach Bike, a `WALK_FAST` movement action for the slope's forced movement (with `bikeSpeed`
    reading 0 throughout), and `RIDE_WATER_CURRENT` for the Acro Bike. "Stable" and "correct" are
    different properties: `bikeSpeed` is authoritative while riding and deliberately zeroed here.
26. Taught the painted tier the map it had never been able to see — occlusion behind scenery, read
    from the background layers by sprite priority, and **tall grass, which is a sprite and not
    scenery**. The grass rule was adopted wrong twice first, because the engine's grass sprites had
    been captured walking in one direction only, and a measurement taken in a single condition
    supported two contradictory rules equally well.
27. Added a THIRD renderer between the two: extra characters drawn by the console's own sprite
    hardware, from entries we write into the range of the game's sprite table its per-frame code
    never touches. The engine transfers that whole table every frame regardless, so the entries
    reach the screen for free — and the game itself parks a sprite up there for the same reason.
    Costs three halfword writes per ghost per frame against ~0.6ms of painting, and brings real
    background priority and the live palette, which the painted tier can only fake.
28. Priced all three against each other, standing still with the crowd on screen. At 16 peers they
    are indistinguishable from a bare emulator; at 56 the hardware tier still is, while painting
    the same 56 costs a third of the frame rate. Both cheap tiers full at once — 67 characters —
    is still 60fps. That measurement is the reason the ladder is ordered the way it is.
29. Two defects the user found by comparing rather than by looking at the new tier alone: facing
    was inverted (this game has no east-facing art — east is west plus the hardware flip, and the
    flip lives in the animation command), and the ghost trailed. The trailing turned out to be a
    bug in the SHARED movement filter that the painted tier had shipped with: it measured the
    peer's speed frame-to-frame against a stream that arrives in bursts, so it read zero on most
    frames and could not follow a running player. ([pitfalls.md](../../../../agent_docs/pitfalls.md)
    has that one and the four ways the comparison itself was measured wrong first.)
30. Finished the Acro Bike, which the user called the single hardest thing in this adapter. A
    ghost now gets a real shadow SPRITE under it rather than a painted one, landing dust on all
    three renderers, and the sideways jump — which is not an `ACRO_*` action at all, but the plain
    jump family four ids below where anyone would look. The shadow had been written and disabled
    because it reset the game on every hop: the cause was a NULL sprite callback, since
    the engine calls every live sprite's callback with no null check and a zero there is a jump to
    the console's reset vector. Facing while hopping took five attempts, four of which fixed damage
    done by the first.
    ([pitfalls.md](../../../../agent_docs/pitfalls.md) has all seven, and the methods matter more
    than the fixes: sort a RESET apart from a glitch, audit the expensive FAILURE path, and never
    let "it is the network" stand in for a frame counter.)
31. Took the ghosts onto the water, and found that most of what a character does there had never
    reached the two tiers that draw for themselves. The hardware tier had no surf blob and no
    reflection; neither tier left a wake; and both reflected only while SURFING, so a ghost on the
    grass at a water's edge cast nothing. Each one is a field effect the engine makes and a spawned
    ghost therefore gets for free — so each was measured off the game's own sprite and rebuilt from
    the ROM data it points at, never approximated (`documentation.md`, and `probes/ripple_probe.lua`
    for the trail's whole specification).
32. Fixed a ghost arriving mid-stride. Holding a pose turned out to be three writes AND one
    un-write: `animPaused` does nothing while `animBeginning` is still set, because the engine runs
    the animation once more first — and a running animation copies its frame into the object's
    tiles. The numbers said "standing" while the pixels showed a stride. The held logic now lives in
    one place used by both the spawn path and the steady mirror; the split between them was the bug.
33. Chased a single missing PIXEL of reflection at a shoreline, and it was worth it, because two
    real defects were hiding behind it. A reflection is an AFFINE sprite, not a flipped one: the
    flip is `h - y` rather than `h - 1 - y` (a GBA affine transform is centred on `h/2`), and the
    shimmer moves the SAMPLING, so a one-pixel feature shifts by a pixel instead of growing.
    Both were settled by photographing the engine's own reflection across several frames.
    **The lesson was the expensive part, and it is in `pitfalls.md`:** most of that hunt compared
    the painted ghost against the spawned one while the spawned one was itself in the wrong pose.
34. Made the drawn tier survive a cave, in two steps. Its brightness gate was a ratio, which can
    only express fading toward black — and a cave mouth fades to WHITE, so the gate read a
    washed-out screen as an ordinary one and the ghost stayed at full colour. Fitting the engine's
    actual blend line (`live = a*rom + b`) covers black, white, cave tint, weather and night in one
    expression. Then the darkness itself: **a dark cave is Window 0, not an overlay**, so real
    sprites are clipped by it for free while a painted ghost — drawn after the PPU has finished,
    where windows no longer exist — shone straight through. It now reads the same per-scanline lit
    spans the engine DMAs to the window register, and intersects each painted row with its own.
35. Made surfing and diving 1:1, mount to dismount. Getting on the water is a sequence rather than
    a graphic change — pose, banner, then the surfing graphic and a jump onto the water together —
    so a ghost performs the game's own jump and every tier parks its blob in the water instead of
    dragging it ashore. Diving works once our copy of the engine's underwater bobber was gone: it
    held another sprite's index, so a reused slot let it corrupt whatever landed there and hang the
    game. A diver's bob rides the peer's own offset. Evidence: `VERIFIED.md`.
36. Ice and fog, and the distinction between them worth carrying forward. **An ice slide is a
    movement that does not animate** — the game's forced slide is a fast walk plus two bits on the
    object, `disableAnim` and a facing lock, and we were sending neither; `disableAnim` outranks a
    movement, which is why three separate things were each undoing it. Fog is the other kind of
    answer: under a screen-covering semi-transparent sheet the hardware tier **stands down** and
    its peers are painted instead. **The cave was fixable and the fog was not, and the reason is
    the question to ask of any future hardware effect — the lit region is readable data, where the
    sheet was a priority we cannot win.**
37. **FEATURE COMPLETE, 2026-08-21** — the user's call, and the bar was theirs to set: *"i consider
    the game to be fully synced up animation and effect wise now."* Every way this game moves a
    character and every field effect it hangs off one is mirrored on all three tiers. What is left
    after this is minor polish or custom features that go beyond matching the game, not gaps —
    so a new item here needs a reason it is not one of those. **Two states were never tested and
    were assumed to work: the boat, and Fly.** Assumed rather than open, and recorded as an
    assumption in `UNVERIFIED.md` so it could not quietly become a memory of having checked. The
    attention moved to Crystal — and the assumption did not survive contact (step 38).
38. Came back for Fly, and the assumption was wrong in nine distinct ways across three renderers.
    Fly is not an overworld event at all: the character is taken off the map, a bird sprite flies
    the arc in SCREEN coordinates, and on a patched ROM every address it needs is shifted and
    **none of them fail loudly**. Three bugs each hid the next, and the savestate chosen to watch
    it decided whether the landing was visible at all. It ships **bandaged, not finished** — the
    user's call, *"good nuff for now"* — with four compensations named in
    [BANDAGES.md](BANDAGES.md) §4, and one confirmed case: a same-town fly watched from a second
    instance. **The boat is still assumed**, and rails were never built at all.

**~3 hours for the hardware tier**, most of it spent discovering that the comparison harness, not
either renderer, was what kept producing wrong answers.

**~2 hours from a drawn ghost to a spawned one**, on top of the ~10 hours the drawn one took —
most of it spent on the six bugs above rather than on the spawn itself.

**The one rule the peer-state work produced, and it held for every item above:** every guess was
wrong, and every measurement was right first time. The measurements that worked all had the same
shape — **read what the engine does for the player, then make the ghost match it.**

See [phase8.md](../../../../agent_docs/phases/phase8.md) for the full record.

## Dev tools

Everything lives in [probes/](probes/), and **[probes/README.md](probes/README.md) is the full
index** — including the scripts that WRITE, one of which alters the save. Read that before running
any of them. The adapter's own switches are in [FLAGS.md](FLAGS.md), and
[adapters/_template/probes.md](../../../_template/probes.md) is the probe method itself.

**How to run one**: point `dev-scripts/bizhawk-dev-loader.target` at it — the loader swaps scripts
live with no emulator relaunch (step 15 above, `agent_docs/environment.md`).

The handful reached for most often, as orientation rather than an index:

- `goto_map.lua` — **writes.** Warp anywhere, so reaching a test state costs nobody's playing time.
- `testkit.lua` — **writes `SaveBlock1`, and it persists if you save.** Bikes, a rod and badges in
  one second, so a save that can do the thing under test is a second away rather than an hour.
- `capacity_probe.lua` and `fpshold.lua` — the two instruments behind the "Limits" section above:
  how many ghosts each rung can hold, and what they cost with the player standing still.
- `probe_render_remote_trace.lua` — a headless companion (the same bridge/networking/JSON code as
  the adapter, no rendering) printing this client's own area/position and every known remote's,
  for diagnosing a "ghost isn't rendering" report without a second game.
- `shadow_ghost_probe.lua` — a second ghost driven by the *same* local-state read, smoothing and
  animation code as a real peer, but with no bridge, relay or core in the picture. Isolates "is the
  rendering wrong?" from "is the network wrong?".
- `avatar_scan_probe.lua` → `avatar_hexdump_probe.lua` → `avatar_array_probe.lua` →
  `avatar_verify_probe.lua` — the four-stage template for finding where a patched ROM moved
  something. Written for one Archipelago address shift, and the first thing to reach for if a ROM
  moves something again.
