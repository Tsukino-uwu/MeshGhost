# Unverified — Pokémon Crystal's queue waiting on the user

<!-- line-cap: none -- queue that drains; size is how much the user has not seen yet. Why: agent_docs/claude-md-cap.md. -->

**What this is.** [`VERIFIED.md`](VERIFIED.md) is the append-only record of what is *confirmed*.
This is its waiting room: things the agent believes work, has self-tested as far as it can, and
**the user has not seen yet**. It exists so work can continue while the user is away without either
losing track of what still needs checking or quietly drifting into calling it done.

**The rule it serves** (`../../../../agent_docs/testing.md`, `../../../../agent_docs/environment.md`): the agent verifies the Go
client/server with tools; **anything about a running game needs the user to watch it**. A
screenshot the agent took is not a substitute, and neither is a healthy log. *"nothing is
considered done/fixed until i actually confirm it as such."*

**How to use it.**

- The agent adds an item the moment it believes something works, with **what to look at** and
  **what correct looks like** — enough that the user can judge it without re-deriving anything.
- The user works down the list and answers each **confirm** or **decline**. Decline is a normal
  answer, not a failed handover.
- **On confirm:** move it to [`VERIFIED.md`](VERIFIED.md) with the date, and delete it here.
- **On decline:** it goes back to being work. Note what was actually seen — that is usually the
  most valuable line in the whole file.
- Nothing here is cited as established anywhere else while it sits here.

**Split out of `../../../../agent_docs/unverified.md` on 2026-08-25**, verbatim and in original order. That file
was 1,670 lines and, unlike `verified.md`, was already 100% per-game — Crystal and Emerald only,
no Pseudoregalia or TEVI entries by design. Sibling queues: `../emerald/UNVERIFIED.md`.

**This queue drains.** Every entry marked CLOSED or CONFIRMED was moved to `VERIFIED.md` on
2026-08-25 and deleted here — the file had been carrying confirmed items indefinitely, each
explaining that it stayed because `verified.md` was "the user's to append". A queue that does not
drain is not a queue. Confirmed items go to `VERIFIED.md` with the date; declined ones go back to
being work. An entry still here has not been confirmed.

---

## Pending — Crystal: a peer's sprite that the local player is NOT wearing (2026-08-19)

The no-regression half is CONFIRMED and has moved to `verified.md` — a loopback ghost looks like
the player, indoors and out. What is still unwatched is the case the lookup exists for.

- [ ] **A ghost wearing a sprite you are not wearing.** Set
      `MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE=4` (an id New Bark Town has resident, and the lab does
      not) with `MESHGHOST_LOOPBACK_OFFSET_X=2`. *What to look at:* the ghost two tiles to your
      right, outdoors. *Correct:* it is the RIVAL's character, drawn cleanly, while you are still
      yourself — and indoors it falls back to your own sprite rather than drawing garbage.
      **The adapter prints `PROBE FLAG IN USE` while this is set; clear it afterwards.**

## Pending — Crystal: re-check the battle and the door after the fixes (2026-08-19)

Both were WATCHED and both were broken — see `verified.md` for what was seen. Fixed the same
session; the fixes themselves have not been watched.

- [ ] **One wild battle.** *Correct:* exactly ONE ghost afterwards (it duplicated before), and
      every NPC on the map still there and behaving.
- [ ] **Out of Elm's lab.** *Correct:* the ghost square on its tile, not a few pixels off it.
- [ ] **In and out of a door generally**, since the placement code changed for every case.

## Pending — Crystal's drawn tier (2026-08-19)

The screen-filling half is **confirmed** (`verified.md`); these landed after that and have not
been watched. All of them concern peers past the engine's cap, which are painted rather than
spawned.

- [ ] **A drawn peer faces the way it is walking, and animates.** *What to look at:* a peer moving
      across the screen while the engine is already full. *Correct:* it turns to face its
      direction and its legs move, rather than sliding while facing down.
      (The frames are learned from watching the engine render YOUR character, so if your own
      sprite animates correctly, a drawn one should match it.)
- [ ] **A drawn peer does not paint over a text box.** *What to look at:* talk to an NPC with a
      crowd on screen. *Correct:* nothing is drawn over the bottom six rows while the box is up,
      and they come back when it closes. (Measured working both ways from the adapter's counters:
      32 peers hidden with a box open, 0 with it closed — but not watched.)
- [ ] **A drawn peer does not paint over the START menu.** Same, for the menu's own rectangle,
      which is the right half of the screen.
- [ ] **Idle peers stop blocking, moving ones do not.** *What to look at:* stand next to a peer
      who stops moving — after five seconds you should be able to walk through them; a peer who is
      actively walking should still block. Turning on the spot must NOT count as moving.
- [ ] **Shoving past a peer works.** *What to look at:* hold a direction into a peer that is
      blocking a doorway. *Correct:* after about half a second they stop blocking and you walk
      through.

- [ ] **A drawn peer can wear a sprite this map never loaded** (2026-08-19). *What to look at:* set
      `MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE=6` (SPRITE_RED, which New Bark does not load) with a
      crowd on screen. *Correct:* they render as that character, cleanly, in its own colours.
      Measured: 89 of 89 drawn from the cartridge at 59.6fps, and the adapter says so in its log
      (`89 drawn (89 from the cartridge)`). **This is the fix for "a ghost looks like this
      machine's player"** — for the drawn tier. A spawned ghost still needs tiles the hardware can
      reach, so it keeps the old behaviour.

## Crystal's drawn tier does NOT clip the PHONE-CALL panel at the TOP of the screen (2026-08-19)

**Reported by the user, watching the Archipelago Crystal instance:** *"there is a 'text box/ui'
thing at the top. think we forgot that one earlier for the gui draw, as it only appears when
someone in the game call your phone."*

Both of `meshghost_crystal.lua`'s occlusion tests are blind to it, and for different reasons:

- `textBoxOpen()` looks for the frame's corner tile (121) and its edge (122) **at row 12 only** —
  the constant bottom-of-screen box (`TEXTBOX_Y = SCREEN_HEIGHT - TEXTBOX_HEIGHT`). A panel drawn
  at the top of the screen is not on that row, so it is never seen.
- `uiPanelOpen()` latches the rectangle a **menu** publishes in `wMenuBorder*`; a text box does not
  publish one (measured 2026-08-19), and there is no reason to assume the call panel does either.

So a drawn peer standing near the top of the screen paints over an incoming call. The spawned tier
is unaffected — the engine occludes it.

**The likely fix, and why it is not just another constant:** the corner-tile test is already
style-independent and cheap, so **scan for the frame corner on the top rows as well as row 12** and
clip against whichever rectangle is found, rather than adding a second hard-coded row. That also
covers any other panel this game draws in the same frame style.

- [ ] **Confirm where the panel actually sits** — its first row, its height, whether it spans the
      full width, and whether it publishes `wMenuBorder*` after all. Trigger: wait for an in-game
      phone call, with a crowd of drawn peers on screen. A screenshot settles the geometry in one
      frame; the tilemap read settles the detection.

**Geometry SEEN 2026-08-19 on the Archipelago instance, from the agent's own screenshots** —
`dev-scripts/shots/apcrystal/00-arrival.png` and `01-after-call.png`, Prof. Elm's "It's a
disaster!" call on Route 30. Permitted to confirm visually because the ROM is patched
(`CLAUDE.md`); the tilemap read is still outstanding, so the detection half of the item stands.

- The panel is at the **very top of the screen**, **full width**, and about **3-4 tile rows** tall
  (the overworld resumes at roughly screen row 4). It holds one line — the caller's name,
  `PROF.ELM:`, with a small phone icon in the first cell.
- **The normal bottom text box is on screen AT THE SAME TIME**, carrying the speech. So a call is
  TWO panels, top and bottom, and `textBoxOpen()`'s row-12 test sees only the bottom one — which is
  exactly why a drawn peer near the top of the screen is unclipped while one near the bottom is
  fine. The proposed fix (scan the top rows for the frame corner too) is aimed correctly.
- Not yet read: `wMenuBorder*` while it is up, and which tilemap rows the frame tiles occupy.

**Measured 2026-08-19 on the VANILLA instance, and it changes the proposed fix.** The call panel
itself was **not observed** — no call came in during the session, so its geometry is still unknown
and the item above stands. What *was* measured is the trap the naive version of the fix walks into.
`adapters/emulator/pokemon/crystal/probes/uiframe_probe.lua` scans **both** tilemaps on **every**
row for the frame corner and logs the window registers beside it. In New Bark Town, with nothing
open and the player walking, it found a full-width frame top at **BG row 12 while `WY` was parked
at 144** — i.e. the frame tiles were sitting in the tilemap with **no panel on screen at all**, and
they cleared a few seconds later as the camera scrolled other terrain into that row.

So **"frame tiles are present" and "a panel is visible" are different questions**, and a scan of
every row would hide drawn peers for no reason — the same shape as the bug that emptied the bottom
half of the screen earlier that day. A generalised test needs the visibility half too: LCDC bit 5
(window enabled) and `WY <= 143` / `WX <= 166`. Today's row-12 test survives this only because its
third check (the far end of the row) happens to fail on the leftover tiles; that is luck, not
design. **Log-line evidence, agent-verified; no visual claim.**

## Pending — Crystal's drawn tier: what a crowd on VANILLA showed (2026-08-19)

The queue above ("Pending — Crystal's drawn tier") asks for five things. This is what a synthetic
crowd could establish without the user, on **vanilla Crystal in New Bark Town**, ~60 peers offered
by `meshghost-fakeadapter.exe` in five concentric rings around the player (radii 1-5, 8-18 peers
each, distinct periods so they do not step in lockstep). **Nothing here is a confirmation** — this
is a vanilla ROM, so every visual claim still needs the user's eyes.

**A note that changes how any of this gets checked: BizHawk's `client.screenshot()` does NOT
capture the drawn tier.** The drawn peers are `gui.drawLine` calls on the Lua overlay;
`client.screenshot()` writes the emulator's video output, which contains the engine's own sprites
(so a SPAWNED ghost appears) and none of the overlay (so a DRAWN one never does). Three "the crowd
is invisible" screenshots were taken of a screen that was full of ghosts.

**The answer is NOT to photograph the emulator window** — that was tried and the user ruled it
out the same day; `client.screenshot()` is the only screenshot tool here. The rule and its wording
live in `playing.md`, "Screenshots", rather than being restated here.

**So the drawn tier is judged NUMERICALLY, and that is the better evidence anyway** — the same
reason the collision policy and the crowd ceiling were settled with counters. One frame cannot see
a walk cycle or a facing, and a counter over time can: the adapter's own once-a-second line carries
the numbers, and the two entries below rest on them rather than on any image.

- [x] *(agent-measured, not a confirmation)* **A drawn peer has a facing, and animates.** Counted
      rather than photographed, because one frame cannot see a walk cycle: the adapter's
      once-a-second line now ends `N on a walk frame, M with no facing yet`. Over 12 consecutive
      samples with ~40 peers drawn, **14-36 were rendering a walk stride at any instant and M was
      0 every single time** — no peer ever fell back to the "nothing learned for that facing"
      path. *For the user:* it should look like a crowd of characters walking, each facing the way
      it is going, not sliding while facing down.
      **This needed a rig change**: `meshghost-fakeadapter` sent no orientation at all for a 2D
      game, so every synthetic peer had `facing = nil` and rendered a static forward frame — which
      looks exactly like broken animation and is not. New flag `-facing-follows-path` sends a
      cardinal string from the circle tangent; off by default.
- [x] *(agent-measured, from the counter)* **A drawn peer is withheld while a text box is open.**
      With ~40 drawn peers around the player and an NPC's box up, the adapter counted **13-14
      `hidden by UI`**, and **0** with the box closed — measured both ways, so it is the box doing
      it rather than a latch stuck on. What a counter cannot say is whether the withheld ones are
      exactly the ones overlapping the box, which is the part still needing the user's eyes.
- [x] *(agent-measured, from the counter)* **A drawn peer is withheld while the START menu is
      open.** Same crowd, menu open: **21-24 `hidden by UI`**, against 0 with nothing open. More
      than the text box withholds, which is the right direction — the menu's rectangle covers the
      right half of the screen where most of this crowd was standing.
- [ ] **Small anomaly worth a second look:** 3-4 peers were counted `hidden by UI` while the player
      was walking with nothing open. Too few to be the text-box rule (that would hide everything
      below row 12); the suspect is a stale `lastMenuBox` inside the 20-frame latch. Harmless
      today, and not chased.
- [ ] **Still unwatched, and not answerable with synthetic peers:** the collision half of the queue
      — idle peers stopping blocking after five seconds, and shoving past one in a doorway.

**Also settled in passing, from the log:** crossing a map boundary (Route 29 -> New Bark Town) with
62 drawn peers on screen dropped every one of them within a second — the adapter's drawn-tier
bookkeeping stops when the peers' `area_id` no longer matches, which is the leak fixed earlier that
day still holding. Log-line evidence.

## Pending — Crystal: a drawn ghost no longer paints over a full-screen menu (2026-08-19)

**The user reported this while watching:** *"the ghost is being drawn while in the menu's."* The
cause was not the menu clipping being broken in general — the START menu was always clipped
correctly — but that a **full-screen** menu (POKeMON, BAG, the PokeGear) publishes no
`wMenuBorder*` rectangle and *does* trip the text-box test, so the adapter protected only the
bottom six rows and painted ghosts over the whole top two-thirds. Mechanism, the measured table and
the two rejected heuristics: `pitfalls.md`.

Fixed by drawing nothing when the engine has **no live hardware sprites at all** (measured: 28-34
in the overworld, 28-30 behind the START menu, 30+ behind a text box, exactly **0** in a
full-screen menu). Self-tested from the adapter's own per-peer dump across a full sweep: 31-34
peers painted per sample in that state before, **none** after, with the START menu case unchanged
and the drawn tier resuming normally on exit.

- [ ] **Open the menus with a crowd on screen.** *What to look at:* press START, then go into
      POKeMON, the BAG and the POKeGEAR, and come back out. *Correct:* no ghost anywhere on any
      full-screen menu; the START menu's own box stays clean as before; and when you close
      everything the ghosts are all still there and moving, not missing or frozen.
- [ ] **Nothing got quieter that should not have.** *What to look at:* ordinary walking with a
      text box open. *Correct:* ghosts still visible above the text box exactly as before — the fix
      must not have turned into "hide everything whenever anything is open".

## Pending -- Crystal: a drawn ghost inside a BATTLE (2026-08-19)

**The user, watching the Archipelago instance:** *"ap crystal is showing a ghost inside of the
battle and stuffs now. think its a drawn one?"* Same defect as the menu report, and now handled by
the same positive test -- the drawn tier draws only when the engine is actually drawing the
overworld, including the local player's own character. Two contributing causes, both closed: a nil
address reading as byte 0 (so the battle term was always true on an unmeasured build), and the
state gate having only one battle term on a build where `wMapStatus` never leaves the in-play
value. Both in `pitfalls.md`.

- [ ] **A battle with a crowd on screen.** *What to look at:* walk into tall grass with peers
      around you and fight a wild Pokemon through to the end. *Correct:* no ghost anywhere on the
      encounter transition, the battle screen, or the fade back -- and when you return to the
      overworld the ghosts are all there again and moving. **Not self-tested on vanilla**: the walk
      to grass was blocked by our own spawned ghosts boxing the player in, so this rests on the
      Archipelago agent's memory reads rather than on a run of the fixed build.


## Pending — Crystal: four changes from 2026-08-21, none confirmed on screen

All four were made in one session while the user watched a loopback session. Each is **measured but
not confirmed**: the measurements are mine, so per `CLAUDE.md` none of this is verified until the
user says what they saw.

1. **The end-of-step snap.** A ghost's movement type was inherited from whatever NPC its template
   came from, so on a wandering template the engine ran `MovementFunction_RandomWalkXY` for the one
   frame between our steps and the ghost chose a direction of its own.
   `probes/posediff_probe.lua` caught one frame per step with the facing jumping to an unrelated
   direction (9 -> 2 -> 8 while walking left) and a `STEP_DURATION` the adapter never writes. Now
   pinned per direction to `SPRITEMOVEDATA_STANDING_DOWN/UP/LEFT/RIGHT` (`0x06..0x09`). After the
   fix the same probe reads a clean cycle and `residual +0px` per step. **The user has not yet said
   whether the snap is gone.**
2. **The runaway.** `BANDAGES.md` entry 5 — repaired, cause unknown.
3. **A peer that stops sending is now forgotten after three seconds.** Nothing timed a peer out
   before: a ghost lived until an explicit despawn, an area change, or the bridge dropping. The dev
   rig exposed it because the core is issued a new player id on every relay reconnection (sixteen in
   one session), so each old id was left painted forever. **This is a shipped bug, not a rig
   artifact** — a peer whose game crashes would have been painted at their last position for the
   rest of the session.
4. **Peer animation on the wire.** `extras.act` carries `OBJECT_ACTION`, and a spawned ghost is
   given it while idle so the engine plays fishing, bump, spin, emote and the Fly landing itself.
   **Completely untested** — and it rests on an assumption nobody has checked, which
   `probes/action_watch.lua` exists to settle: that the PLAYER's own object struct carries those
   action values at all. If fishing is driven entirely by a script that never touches the struct,
   the byte never changes and the ghost animates nothing while every log line looks healthy.

Also unconfirmed, and worth separating from the above: a peer whose sprite is not resident is now
routed to the drawn tier so a surfing or biking peer is not shown wearing this machine's walking
sprite. The first version of that rule was wrong in a way worth recording — it treated "not in
`wUsedSprites`" as "cannot be worn", which is false for the local player's own sprite, so **every**
peer was demoted and the spawned tier was silently off. Caught by the adapter's own drawn-tier line
reading `0 spawned as real objects`.

## Pending — Crystal's hardware tier (2026-08-21)

Built on the user's request as the middle rung of **spawned -> hardware -> drawn**, behind
`MESHGHOST_CRYSTAL_OAM_OVERFLOW` (off by default). What is **measured**, by me, and therefore not
verified: entries written at the adapter's frame boundary DO reach the hardware — entry 39 read back
from the `OAM` domain, which is what the DMA delivered rather than the shadow bytes we wrote. Cost
is nil at this scale: `emu 60.0fps`, 0 hitches over 20ms, worst frame gap 17-18ms, with three
renderers live at once.

**Nothing about how it LOOKS has been confirmed.** The queue, and the first two are predictions from
the decomp that the screen may well refute:

1. **A text box should draw BEHIND the hardware ghost** — the opposite of what a hardware tier is
   usually wanted for, because a Crystal text box is background tiles with the BG-to-OAM priority
   bit clear (`TextboxPalette`, `home/text.asm:100`) and the window is parked off-screen in normal
   play. This was claimed the other way round earlier in the session and corrected from the source;
   the screen is what settles it.
2. **Opening START should make the hardware ghost vanish**, because `_UpdateSprites` stops running
   and the tier stands down with it. That is the only occlusion it genuinely inherits.
3. **Position, palette, flip and the walk cycle** — the arrangement comes from frames learned off
   the local player, the same table the drawn tier uses, so a facing the player has not used since
   the map loaded has nothing to draw and the peer falls through to being painted.
4. **The three-way comparison itself**: hardware 4 tiles left, drawn 2 tiles left, spawned 2 tiles
   right. Each copy is pinned to one rung — without that the hardware tier claims the drawn copy
   too and the comparison silently becomes a renderer against itself.

## Pending — Crystal, after the 2026-08-22 session

1. **The drawn tier's STRIDE animation is unconfirmed.** With the facing fixed, only one frame per
   facing was ever captured in the runs watched, and the tier's own summary line has read
   `0 on a walk frame` throughout. A painted ghost may therefore be facing correctly and not
   animating. Not a regression — it was never confirmed working — but it is the next thing to look
   at, and `MESHGHOST_CRYSTAL_FACING_TRACE` reports what gets captured.
2. **The transition hold now spends its 30 frames DURING the crossing — user-confirmed
   2026-08-22**, *"think it looks pretty good"*. Measured across 32 driven crossings, zero
   variance: the tier returns **5 frames late going in, 2 coming out**, against ~30 either way
   before. **A CORRECTION IS RECORDED HERE DELIBERATELY**: this change was reverted earlier the
   same evening as "judged worse", and that was a misattribution. It had shipped alongside a first
   attempt at the stale-reference fix which CLEARED the player-history ring, and the wiggle
   belonged to the clearing. Tested with the readiness gate in its place, the user's report was
   *"no wiggle"*; the regression named in that same message was the drawn tier's FACING, a
   separate pre-existing fault. Cost: one revert and a wrong entry in this file.
3. **The drawn ghost still appears slightly after the PLAYER does on a crossing** — the user,
   2026-08-22: *"the drawn ghost does appear a bit slower than what the player itself does"*, and
   *"hard to tell how it compares to the other ghost"*. Three measured components, ~8-13 frames
   total: the hold's leftover (2-5, above), the readiness gate waiting for `age + 1` current-map
   samples (3 by construction), and the peer's own state arriving over the wire (3-5, measured).
   **Only the first two are ours** — a ghost represents somebody else, whose state is genuinely
   late. Untested next step: whether the hold is needed at all now, which `paintgate_probe.lua`
   already scores as `ready+0 = 0 late`.
4. **Nothing has ever compared the DRAWN tier's first frame against the SPAWNED tier's** after a
   crossing, which is the user's own question above and the thing that would say whether the
   painted tier is actually slower or merely differently timed. Neither tier logs the frame it
   first renders on.
4. **`extras.act` remains untested**, unchanged from the previous session — the byte that would let
   the engine play fishing, bumping, spinning, the "!" emote and the Fly landing on a spawned
   ghost. `probes/action_watch.lua` has now shown STAND, STEP and BUMP reaching the player's own
   object during ordinary play; FISHING, SPIN, EMOTE and SKYFALL were never produced in that run.

## Crystal's two anti-stuck passability rules have never been watched (2026-08-22)

`shouldBlock` makes a peer passable two ways, and both were held OFF during the collision
confirmation in `verified.md` because a frozen ghost trips them within seconds:

- **idle**: a peer that has not changed tile for `IDLE_FRAMES_BEFORE_PASSABLE` becomes passable and
  is demoted to the painted tier, which has no collision at all. So a peer standing still stops
  being solid *and* changes renderer, and nobody has seen either transition happen.
- **pushed**: holding the d-pad into a peer for `PUSH_FRAMES_BEFORE_PASSABLE` frames makes it
  passable for `PASSABLE_HOLD_FRAMES`, so a player cannot be trapped. Never watched.

Both are shipped behaviour on the tier most peers actually get. To test them, clear
`MESHGHOST_CRYSTAL_FREEZE_STATE` — it forces `shouldBlock` true precisely to keep them out of the
way of a hitbox test.

## Crystal: the spawned ghost starts each step ~4 frames after the peer (2026-08-22)

Measured with both step machines watched at once, counting between actual tile changes with no
`OBJECT_WALKING` gate (every earlier instrument had one, and it hid the frames where the
disagreement lives):

| | frames per tile | step type | starts its step |
|---|---|---|---|
| player | 15.8 | **6** | — |
| spawned ghost | 14.2 | **2** | mean **4.3 frames** later, worst 15 |

The user, watching: *"Its falling behind and not keeping up again while walking around, looks
slightly behind/slow/late, everything else looks alright on it now no snapping/teleport etc"* — so
motion QUALITY is settled and only the phase lag remains.

**The wire is 1.5 frames of the 4.3** (measured separately against the player's own history ring on
loopback). The rest is the adapter's own pipeline: the peer state is read, a step is decided, and
the engine acts on the following frame.

**Two separate findings, and only the first is a defect:**

- **The step type is NOT a defect — closed 2026-08-22.** Copying the player's type 6 was tried
  and it SCROLLS THE CAMERA, because moving the player is what that step type exists to do; the
  ghost dragged the whole view within seconds of it loading (`pitfalls.md`). The ghost stays on 2,
  and crossing a tile in 14.2 frames where the player takes 15.8 is the price of a ghost not being
  the player rather than an oversight.
- **The start lag is structural for an engine-driven ghost** and `architecture.md` already says so.
  Cutting it means starting a step from `extras.prog` -- which the peer already sends and the DRAWN
  tier already uses to sit exactly on the peer — instead of waiting to notice a tile change.

Neither is scheduled. Both are measured, and the numbers above are what any fix has to beat.

## Crystal's drawn tier at the SHIPPED 250ms: the stutter, and what it turned out to be — 2026-08-23

**Status: measured and fixed in code, NOT confirmed on screen.** The user reported it live —
*"the drawn ghost still looks a bit stuttery/jittery while moving around"* — while playing the
shipped-settings rig (`run-relay-loopback-shipped.bat` + `run-core-crystal-shipped.bat`, 250ms
interpolation at the relay's default 20Hz).

### What it was

The drawn tier painted wherever the interpolated position said, every frame. Over 198 moving
frames the peer's position advanced a mean of **0.970 px/frame** — the player's own walking speed,
which is why every earlier per-message instrument called the wire clean — but only 65 of those
frames advanced a whole pixel, against **58 at 0.75px and 52 at 1.25px**. The core interpolates on
wall-clock time and the adapter samples it once per emulated frame; emulated frames are not exactly
16.667ms apart, so each sample lands a different fraction of a pixel along. Rounded to the screen
grid that paints 1,1,2,1,2,1.

It appears at shipped settings **only**, which is why every earlier session missed it: at
`-interp=0ms` the ghost replays the player's own past *integer* positions and there is nothing to
round.

### Two suspects measured and cleared before anything was changed

- **The two clocks beating against each other.** Refuted: 660 of 660 rendered frames received
  exactly one message. `receive()` drains its whole buffer each frame, so a 0 or a 2 would have
  shown — the instrument could see the case, and the case was not happening.
- **The aged player reference wobbling.** Refuted from the code: `playerHistory.age` is the
  constant 2, so the reference cannot pick a different sample frame to frame.

### The correction that mattered: the game's own quantum

The first fix walked the ghost at 1px per frame and fixed left and right (10 and 5 two-pixel jumps
down to 1 each) while leaving up and down untouched. Splitting the paint into its two halves showed
why: the ghost moved 0 or 1px and the **player reference moved 0 or 2px and never 1**.

The obvious next move was to find the odd pixel the reference was losing. **There isn't one.**
Measured on the running game: the background scroll moves 0, 2 or 4 pixels and **never 1**, and the
player's sprite does not move at all — the world scrolls past a fixed sprite.

> **A tile is 8 ticks of 2px.** `stepProgress`'s `(8 - STEP_DURATION) * 2` is not a lossy reading of
> a finer value; it *is* the value. A 1px-per-frame ghost is **smoother than the game**, which fails
> the 1:1 bar from the other side — the player steps and the ghost glides.

### The numbers any further work has to beat

Painted screen movement per frame, walking down: **44×1px + 15×3px** before, **59×2px** after — the
mixed odd/even pattern that *was* the stutter, gone. Up, left and right likewise carry no odd
values. The model never fell more than 20px behind a 16px step and **never once resynced**.

### Two defects found on the way, both live before this session

- **`stepProg` was computed and never read** — a dead local sitting under a comment explaining why
  the stride had to come from the same quantity as the body, while the stepping band, the frame
  picker and the counters all went on reading the raw un-interpolated `extras.prog`. So "the stride
  comes from the smooth quantity" was never true. Assigned now.
- **The stride's progress had a sign bug.** `16 + (pix - tile*16)` is correct only where that term
  is negative — right and down. Walking **left or up** the destination tile is the smaller number,
  the term is positive for the whole step, the progress pins at 16, and 16 is inside the stepping
  band: those two directions held ONE image for the whole step instead of running a cycle. Taken as
  a distance now, which has no sign to get wrong. This is a candidate explanation for the
  directional complaints (*"still doing right a bit fast sometimes"*) and is not confirmed as such.

## Crystal's drawn tier: what the 2026-08-23 confirmation does NOT cover

The user confirmed the drawn tier clean — *"i think this one looks perfect now"* — at the **dev rig's
settings** (`verified.md`). Everything below is measured, not confirmed, and the first item is the
one the session originally set out to answer.

1. **THE SHIPPED 250ms CONFIGURATION WAS NEVER RE-JUDGED.** The session began there (the reported
   fault), moved to `-interp=0ms` to isolate the renderer from the delay, and every fix since was
   judged at 0ms. The model was designed for the noisy interpolated stream and should behave at
   least as well there, but that is a prediction. **Run `run-relay-loopback-shipped.bat` +
   `run-core-crystal-shipped.bat` and look, before calling the shipped case anything.**
2. **A real peer, rather than loopback.** Every reading came from a peer whose motion is the local
   player's own, on one machine. A second machine's peer has genuinely independent timing.
3. **The camera-frame paint assumes one camera.** `camAX/camAY/camKX/camKY` live on `facingFrames`,
   i.e. one accumulator shared by all peers, which is correct (there is one camera) but has only
   been exercised with a single peer on screen.
4. **Map changes and warps.** `K` re-calibrates whenever the camera is parked for 8 frames, which
   should cover a transition, and the rebase absorber handles the register jump — neither has been
   watched across a real door, ledge or Fly.
5. **Non-walking movement.** Bike, surf, ledge hops and the Fly landing all move the camera at rates
   the model clamps to 2-4px. Untested, and `catchup`'s 4px bike gait is the only faster path.
6. **The `x` (perpendicular) and `>` (large) marks that remain in the screen trace** cluster at lap
   transitions and 8px camera frames. Small, unexplained, and now visible to the instrument.

## Crystal: the trainer-clone hang — fixed, NOT yet confirmed on screen (2026-08-23)

A spawned ghost raised the trainer `!` and wedged the game's script engine. Cause, fix and method:
`pitfalls.md`, "a spawned ghost was a TRAINER". The ghost was cloned from a map object whose type
nibble was trainer and whose sight range was 4, and it inherited both.

**What is confirmed.** The user saw the `!` over a ghost and the resulting hang, twice, the second
time on adapter code identical to `HEAD` — so it is a pre-existing shipped fault, not something a
session introduced. The donor's 16 bytes were captured live by the adapter's own log.

**What is NOT confirmed.** That the fix holds. The failure is rare by nature — it needs a map whose
first eligible object is a trainer, plus a ghost that walks into a sightline — so an evening without
a `!` proves very little. What a session CAN check is that nothing else changed: ghosts still spawn,
walk, animate and despawn as before. One run after the fix showed a ghost live for 18,921
peer-frames, type read back as 3 on every spawn and never 2, despawning through the ordinary
passable rule — but no user has watched it.

**The cheap standing check.** The spawn line reports the type nibble re-read from memory. Any `type
2,` in an adapter log is this bug, live, and the same line names the donor to blame.

**2026-08-23, after the fix: no recurrence seen.** The user, on the same rig and the same route that
had produced it twice that day — *"haven't seen it again so far i think, so probly fixed"*. Recorded
as a data point and NOT as a confirmation, deliberately. The fault needs a map whose first eligible
object is a trainer AND a ghost that walks into a sightline, so not seeing it is the expected
outcome of almost any session, fixed or not — it is exactly what the two sightings were surrounded
by before. What WOULD confirm it is the standing check above going quiet on a route known to offer
a trainer donor, which is a thing to watch for rather than a thing to conclude.

## Crystal: what the source says about ghost collision, unused as of 2026-08-23

Read from `pret/pokecrystal`, not measured, and nothing has been built on it yet:

- The player's step tests its destination against every object struct via `IsNPCAtCoord`
  (`engine/overworld/npc_movement.asm:314`), which **skips any object with `EMOTE_OBJECT` set in
  `OBJECT_FLAGS1`**. That is a real engine-level "walk through me" bit, checked on the player's side
  — the thing the adapter currently substitutes for by demoting a peer to the drawn tier.
- **It is not free.** `DespawnEmote` (`engine/overworld/map_objects.asm:2098`) zeroes *every* object
  struct carrying that bit whenever an emote finishes, and does not consult `WONT_DELETE`. A ghost
  wearing it would be wiped at arbitrary moments.
- **A moving character blocks two tiles**, not one: the check compares both current and
  `LAST_MAP_X`/`LAST_MAP_Y`. This is a plain explanation for why a walking ghost is a worse obstacle
  than a standing one, which the open collision item describes from the player's chair.

Whether the trade is worth taking is undecided; it is written down so the option is not rediscovered.

## Crystal's drawn tier at the SHIPPED 250ms: one snap fixed, a small one left (2026-08-23)

**Fixed and judged better by the user.** Two independent causes of the end-of-walk snap, both of
which only fire when the camera parks — which is only when the player stops:

1. **The model was allowed to move at double the engine's walk while the player stood still.** The
   camera-parked fallback granted a 4px catch-up where a walker moves 2px. Measured before changing
   it: 85 frames took that branch with catch-up armed, `0 resyncs` ruling out both snap-to-tile
   paths. Capped at 2px.
2. **The paint switched formula on the frame the camera parked.** It calibrated `K` from the
   player-tile formula while parked and painted from the camera formula while moving — an
   `if`/`elseif`, so the frame the player stops on is the frame the source changes. The two
   disagree by accumulated drift: **worst park measured 14px**, paid in one frame. Now there is one
   formula on every frame and only `K` moves.

Also fixed on the way, by algebra rather than measurement: **the X camera rebase was absorbed with
the wrong sign.** Painted position is `model + camA + K` on both axes, so a rebase added to `camA`
cancels only if subtracted from `K`. Y did that; X added, doubling every X rebase into the painted
position instead of cancelling it.

### What is NOT fixed, and must not be chased with a bigger correction

The user, on the surviving residue: *"works/looks fine most of the time, and then sometimes have
the 'jitter' right before stopping on a tile"*. **Before** stopping — the ghost's final approach,
while the camera is already parked.

**The cause is upstream of the repayment.** `K` needs continuous correction at all because the
camera accumulator and the player tile+progress formula disagree by a continuous bleed: **206px
repaid against only 5 camera rebases** in one run, so rebases are not it. Find that bleed; the
`K` nudge is a symptom-level patch holding it at ~2px.

**Two repayment rules were tried and are worse — do not re-try them:**

| Rule | Result |
| --- | --- |
| Deadband: ignore drift under 4px | Drift walked up to **16px** per park, at the snap threshold. The theory (a constant offset is invisible) is right; the drift is continuous, so repayment must be too. |
| Wait for arrival, then repay 2px on the engine tick | User: *"now its overshooting, and then gliding back ... added a snap to every single stop"*. 2px is coarser than the drift it chases, and a post-arrival burst is a snap by construction. |

**The suspect worth measuring next**: the tile formula reads an *aged* player position (`aged.oamX`,
paired with OAM timing) while `camA` is current. If the aging is ever absent or inconsistent, the
two references differ by however far the player moved in that window — which would present exactly
as a walk-proportional bleed. Checkable from the existing log; no new probe needed.

## Crystal: the "206px continuous bleed" was a counter artefact, and the bleed has an identity (2026-08-23)

Two results, both from reading the adapter rather than running it, both correcting the entry above
("Crystal's drawn tier at the SHIPPED 250ms: one snap fixed, a small one left").

**1. The suspect that entry named is already dead.** It proposed that the tile formula reads an
*aged* player position while `camA` is current, which would present as a walk-proportional bleed.
`playerHistory.age` is **0** — set that way on 2026-08-23, in the same session, for an unrelated
reason (a real-time model subtracting a two-frame-old reference turned every camera irregularity
into a late wobble). With `age = 0` the aged lookup is the current frame and there is no window to
bleed through. The suspect cannot be it.

**2. The 206px figure does not mean what it was read as.** The counter behind "K drift repaid 206px"
added the whole *remaining* disagreement on every nudge frame while the nudge repays 1px per axis.
A single 14px park therefore scored 14+13+...+1 = 105. The inflation is quadratic in the drift, so
206 is roughly what two ordinary parks produce, not 206px of anything. **"206px repaid against only
5 rebases" was the entire evidence that the bleed is continuous rather than event-driven, and that
evidence is gone.** `kFixMax` ("worst park 2px") was always sound — it is a per-frame maximum, not
a sum — so the only trustworthy number in that line is the small one.

Fixed in `meshghost_crystal.lua`: `kFix` now counts pixels actually repaid, `kNudges` the frames it
was busy, and `kParkSum`/`kParks`/`kParkMax` sample the disagreement **once per park**, on the frame
`camStillFor` passes through 8 — which is the drift a whole walk built, measured instead of inferred.
All under `COMPARE_TIERS`. **Nothing here has been run; the numbers above are arithmetic on the old
counter's definition, and the new counters have never produced a reading.**

### What the algebra says the bleed IS

Substituting `gx = modelX - pTile.x*16` into the tile formula and then into `wantKX`:

    wantKX = sx - modelX - camAX = oamX - 8 - pTile.x*16 - ppx - camAX

**`modelX` cancels exactly.** The disagreement K is correcting contains no peer term, no model term
and no wire term — it is entirely player-side: the player's sprite screen position, the player's
tile, the player's sub-tile offset, and the integrated scroll register. Consequences:

- **The residual jitter is not the ghost's.** No change to the model, the wire, interpolation or the
  peer's timing can affect it. Chasing it there is chasing nothing.
- **Between two parks the drift is `16 x (tiles the player walked) - (scroll camA captured)`** — the
  player is at rest at both ends, so `oamX` and `ppx` return to fixed values and only the tile count
  and the accumulator move. The drift is therefore *exactly the camera motion `camA` failed to
  capture*, which is a much smaller thing to search than "a bleed".
- **Camera rebases are neutral to it, provably.** The implausible branch adds `pdx` to `camA` and
  subtracts it from `K`; `wantK` falls by `pdx` and `K` falls by `pdx`, so `ddx` is unchanged. The
  original "206 against 5 rebases" contrast was comparing against a quantity that cannot contribute.
- **Caveat on exactness:** `sx` is floored while `modelX` is subtracted unrounded, so the
  cancellation leaves a rounding residue in [-0.5, 0.5) if `modelX` is ever fractional. That is
  jitter of half a pixel, not accumulation.

### The next measurement, stated so it cannot drift into a theory

Run the shipped rig, walk, and read `K drift Npx over M parks (worst Wpx)`. **`kParkSum/kParks`
is the drift an average walk produces.** If W is ~2px the residue is at the rounding floor and the
open item is about something else; if W grows with the length of the walk, the missing pixels are in
a path where the camera block did not run or rejected real motion, and the places that can happen
are enumerable (no drawn peer that frame, the UI latch, the settle window, a >128px sample gap).

## Crystal's drawn tier: three real bugs behind the residual jitter — measured, NOT confirmed (2026-08-23)

Continues the entry above ("the '206px continuous bleed' was a counter artefact"). All three were
found by measurement against a source citation, all three are deployed on the shipped-settings rig
(`hSCX`-clocked, 250ms/20Hz), and **no user has judged any of them on screen yet.**

### 1. The adapter's "camera" register was not the camera

`meshghost_crystal.lua` integrated `wPlayerBGMapOffsetX/Y` ($d14c/$d14d) and claimed in comment that
it "cannot disagree with what the player sees". From `pret/pokecrystal`:

- `ram/wram.asm:2477` comments it "used in FollowNotExact; unit is pixels".
- `ApplyBGMapAnchorToObjects` (`engine/overworld/map_objects.asm:2768`), called from `_UpdateSprites`
  every frame, reads it, adds it to every object's sprite X/Y, and **zeroes it** (`:2800`). It is a
  per-frame delta the engine consumes and clears, not an absolute scroll position.
- The screen is scrolled by `hSCX`/`hSCY` ($ffcf/$ffd0), written by `ScrollScreen`
  (`engine/overworld/player_step.asm:37`) from the same `wPlayerStepVector` but ADDING where the
  offset SUBTRACTS (`:29-34`) — hence `dOff == -dHSC`, and hence the earlier "both registers run
  inverted" reading.

Measured before changing anything, by reading both registers on the same frame: **30 of 340 frames
disagreed**, in three shapes that are each a reported symptom — screen moved 2px while the offset
register said nothing (x15, the ghost blind to real motion); offset moved while the screen did not
(x9, the ghost stepping on a still frame, which is this code's own definition of jitter); and offset
24 where the screen moved 22 (x4). Now clocked off `hSCX`/`hSCY`, negated so every downstream sign
convention, the plausibility test and `K` are untouched.

### 2. `K` was corrected against a reference that had not settled

The corrector ran on "camera parked for 8 frames", used as a proxy for "the player has stopped".
A per-term counter showed the target moving on **54 parked frames**, of which **27 were the player's
step progress still advancing** and 6 the player's tile handing over (player OAM: 0, so nothing to do
with the adapter's own drawn ghost sharing OAM). The camera register goes quiet for a beat at the
start of a step, so the branch ran over the opening frames of a new walk with `camStillFor` still
high from the previous stop, nudging `K` — a constant — toward a mid-handover reference.

Now gated on the invariant itself rather than another proxy: correct only on a frame where the target
is identical to the previous frame's. **Note the trap avoided:** the comparison state is updated
OUTSIDE the `COMPARE_TIERS` guard, because it is now shipped behaviour — inside it, a build with
probes off would find the state frozen and never correct `K` at all.

### 3. Every "camera rebase" was the adapter's own blind spot — this is the big one

The plausibility filter rejected implausible scroll deltas as register rebases and absorbed them.
The rejected sizes were 16/20/22/24px, which is 8–12 frames of ordinary 2px scrolling. A gap
histogram confirmed it: one run had **five sampling gaps (one of 14 frames, four over 25) and exactly
five rejected "implausible" moves — the same five events.** The camera never jumped. `drawOverflow`
increments `drawFrames` at the top and then has many early returns (UI open, settle window,
transition hold, no peers), and the sampling sat below all of them inside the per-peer loop, so a
gated frame left `camX` stale and the next sample read several frames of scroll as one delta.

The adapter was reading its own blindness as the game doing something, and discarding that much real
scroll. **That manufactured the entire drift `K` then repaid one visible pixel at a time.** Sampling
is now a global `meshghostSampleCamera()` called before every gate (a global, not a local — the file
is at 197 of Lua's 200 and has hit that ceiling as a bare LOAD FAILED four times).

### What the numbers did

One run each, same rig, same 9x9 square walk/stop drive:

| Metric | Before | After |
| --- | --- | --- |
| Camera sampling gaps | 5 large (14–25+ frames) | 719 frames, every gap = 1 |
| K drift at park entry | 47px over 5 parks, worst 15px | 4px over 4 parks, worst 1px |
| Visible 1px corrections | 94–158 nudge frames | 9 |
| "Camera rebases" | 5 | 0 |
| Worst direction (`u`) | 12.5px avg | 1.0px avg |

**This is a measurement, not a confirmation.** Worst park 1px is the rounding floor, so there is
little left to repay — but "little left to repay" is a log line, and the bar is what the user sees.
The user's reproducible case is the down leg's stop on lap 2 of the square drive; that is what has to
be watched. Also untouched by any of this: a real peer rather than loopback, bike/surf/ledges/warps,
and the map-change path, all still as listed in the entry above.

### The user's reaction, 2026-08-23 — a data point, not yet a confirmation

After the three fixes above went live on the shipped rig, watching the square drive lap:
*"I think it looks fine everywhere now, nothing is standing out during the laps anymore"* — the
first run since 2026-08-23's session began in which the down-leg stop did not reproduce.

Deliberately NOT promoted to `verified.md`: it is a first positive reaction, it carries a hedge
("I think"), and it is scoped to the square drive's laps. What would settle it is the same rig
reproducing nothing on a later session, and ordinary play rather than a scripted square.

**Still not covered by it, unchanged from the list above:** a real peer instead of loopback,
bike/surf/ledge/warp movement, and a map change. The camera sampler now runs on every frame
including those, which is new exposure the square drive cannot exercise.

**One residue, measured and deliberately left alone.** 32 of the surviving 51 corrections reverse
direction — a +-1px dither at the rounding floor, not drift (0.9% of frames). If a faint shimmer is
ever reported, the answer is a 1px deadband, and that is NOT the 4px deadband recorded above as
worse: that one was tried while drift was large and continuous, so suppressing repayment let it walk
to 16px. With drift at ~1px there is nothing left to accumulate. Untried, and not to be added
speculatively.

## Crystal: the camera addresses bypass the adapter's own per-build table (2026-08-23)

Opened by the camera fix above, deliberately not closed in the same pass — the fix had just been
judged good on screen and a refactor at that moment would have made a regression impossible to
attribute.

`hSCX`/`hSCY` are read as **literals inline** (`u8(0xFFCF, "System Bus")`), where every other address
in this adapter lives in the per-ROM-build `ADDRESSES` table. That table exists precisely so a build
which rearranges memory gets its own measured entries rather than vanilla's "because they are close".

**Why it matters more than tidiness, for the Archipelago build.** Vanilla V1.0's `$ffcf`/`$ffd0` come
from a hash-verified local `pokecrystal` build. The Archipelago build's are **assumed, not measured** —
the reasoning being that the patch moves WRAM data (its `wPlayerBGMapOffset` is vanilla+7) while HRAM
is small and hardware-adjacent. That is a plausible argument, not a measurement, and this is exactly
the case the adapter's "a wrong address returns a plausible number instead of crashing" rule was
written for: HRAM always reads, so a wrong entry would produce a believable scroll value and the
graceful fallback would never fire.

**What to do**: measure `hSCX`/`hSCY` on the Archipelago build the way `W_BGMAPOFFSETX/Y` was measured
there (correlation across real tile steps — sweeps 0,2,4..254 within a step, moves on one axis only),
then move both pairs into the `ADDRESSES` tables. Until then, the drawn tier's camera clock on the
Archipelago build rests on an assumption, and the AP build has not been run since the change.

## Crystal: the spawned ghost's step lag was measured wrong, and the jitter has a mechanism (2026-08-23)

**Supersedes the 2026-08-22 entry above** ("Crystal: the spawned ghost starts each step ~4 frames
after the peer"), whose split — *"the wire is 1.5 frames of the 4.3 ... the rest is the adapter's own
pipeline"* — is wrong in both halves. Re-measured with an instrument that separates them by
construction rather than by subtraction: `MESHGHOST_CRYSTAL_STEP_LAG=1`, which on loopback times each
step from the frame the PLAYER's own object committed to the tile (MAP_X/Y are written at the start of
a step), through the frame that tile came back through the core, to the frame `stepGhost` wrote it.

| relay | core interp | wire | adapter | total | spread |
|---|---|---|---|---|---|
| 20Hz (shipped) | 0ms | mean 3.1 | mean 0.7 | mean 3.9 | **2-5 frames** |
| 100Hz | 0ms | **flat 2, every step** | mean 0.6 | mean 2.6 | **0** |
| 20Hz (shipped) | 250ms (shipped) | mean ~16 | mean 0.6 | mean ~16.5 | **2-3 frames** |

Roughly 100 steps, `square_drive` lapping a 3-tile square with the ghost 4 tiles clear of it.

**The adapter is not where the time goes.** Its whole contribution is 0-1 frames (mean ~0.6), of which
the nameable part is a tile arriving while the ghost is still mid-step — `renderRemote` will not
interrupt a step, by design. There is no fix worth having in `stepGhost`.

**The mean does not matter; the SPREAD does.** A lag that is the same on every step is a constant
offset, and a constant offset has no reference to be judged against unless the peer is your own echo
— which is only true on this loopback rig. What a real player can see is the lag CHANGING from step
to step: the ghost walks, hesitates, walks. That is the *"slightly behind/slow/late"* report.

**The mechanism, and it predicts all three rows.** The relay ships a room at 20Hz — one sample every
50ms, three frames. The core lerps every component of `Position` between the two bracketing samples
(`core/interp.go`), and Crystal's `Position[0..1]` are TILE INDICES: a quantity that only ever moves
in whole steps. Lerping a step function turns an exact instant into a three-frame ramp, and
`math.floor` crosses that ramp at a moment that depends on where the jump fell between samples. So
the spread is the relay's sample interval, in frames — 3 at 20Hz, 0 at 100Hz (10ms, sub-frame), and
still 3 at the shipped 250ms because interpolation delay changes WHEN a sample is rendered, never how
far apart the samples are. Every row above follows from that one sentence.

**Not a core bug, and the core must not fix it.** Nothing in `core/` may know that `Position[0]` is a
tile and `Position[2]` is a pixel — that is the game-agnostic rule (ADR 2026-08-20). The core lerping
uniformly is correct; reading a lerped tile index as if it were an instant is the adapter's mistake.

**Where the fix goes.** The peer's sub-tile progress is on the wire (`extras.prog`) and its pixel
position is in `Position[2..3]`, and both say how far into its step the peer already is when a sample
arrives — which is the same as saying how long ago it committed. A step scheduled at a CONSTANT offset
from that recovered instant has no spread at all, at any relay rate, and costs only a fixed delay
nobody can see. Designed, not built, and not yet watched on screen.

**What is NOT established.** That any of this is what the user is looking at. The numbers are mine,
from loopback, and CLAUDE.md's bar is what happens on screen — a spread of three frames is 3px of a
16px step, and whether that is the stutter or merely a true thing about the pipeline is a question
only a real session answers.

## Crystal: a dev-loader flag file cannot turn a flag OFF by deleting the line (2026-08-23)

Cost a full run today and reads as a completely different fault, so it is written down rather than
re-learned. `dev-scripts/bizhawk-dev-loader.lua` drops and re-loads script FILES; it does not reset
BizHawk's Lua globals. A flag set by an earlier flags file therefore stays set after its line is
deleted, and the adapter goes on reading it.

Live case: `MESHGHOST_CRYSTAL_GHOSTS_PASSABLE` was set for one run and removed for the next. It
remained `"1"`, and that flag makes `shouldBlock` return false **before** it updates `movedAt` — so
every peer read as idle forever, every peer stayed on the drawn tier, and the spawned tier under
measurement did not exist. The symptom was `0 spawned as real objects` with a peer plainly walking,
which looks like a spawn failure, a budget problem or a sprite-residency problem, and is none of them.

**The rule: a dev flags file sets every flag it cares about explicitly, including to `nil`.** The
adapter's own tier-refusal line (`stays on the drawn tier -- wearable=... blocking=...`, under
`MESHGHOST_CRYSTAL_STEP_LAG`) is what named it, after three wrong guesses off a zero counter.

## Crystal: the adapter was compiling at exactly Lua's 200-local ceiling (2026-08-23)

Found by adding ONE local and watching the whole file stop compiling — `too many local variables
(limit is 200) in main function`, which in a real session is a silent non-load, not an error. Emerald
had been brought to 197 on 2026-08-22 after hitting this twice; Crystal was never counted and was
sitting at the limit with zero headroom, so the next local anyone added would have killed it.

Three cohesive groups were folded onto tables in the same pass — `JOY` (5 names), `MENUBOX` (4) and
`TEXTBOX` (5) — leaving roughly eleven spare. `dev-scripts/bizhawk-syntax-check.lua` is the only thing
on this machine that can answer "does this file even parse?"; it can be run without a ROM by launching
`EmuHawk.exe --lua=<it>` and reading `bizhawk-syntax-check.log`. **Run it after any edit to an adapter,
not just before shipping** — one added `local` is enough.

## Crystal: the spawned ghost now steps off the peer's PROGRESS, not its tile — measured, NOT confirmed (2026-08-23)

Built on the measurement above. `STEP_TRIGGER_PROG = 4`: the ghost waits until the peer is four
pixels of sixteen into its step before taking one, instead of stepping the moment the peer's
(interpolated, and therefore ramped) tile index crosses an integer.

**The A/B, same session, same rig, same sample size** — shipped settings, relay 20Hz, core 250ms,
`square_drive` lapping a 3-tile square:

| `STEP_TRIGGER_PROG` | step-start spread, p5-p95 | full range | mean | shape |
|---|---|---|---|---|
| **0** (the tile trigger, i.e. what ships today) | **6 frames** (14-20) | 13-21 | 16.87 | flat across nine buckets |
| **4** (the progress trigger) | **2 frames** (18-20) | 17-21 | 18.98 | 73 of 119 steps at exactly 19 |

n=119 each. Arrival jitter was 12-19 frames in BOTH runs — the wire did not change, only what the
adapter does with it.

**What was bought, and what was paid.** Step-start jitter down from six frames to two; mean lag up by
2.1 frames. That is the trade on purpose: a lag that is the same every step is a constant offset with
nothing to see it against, and a lag that wanders is the walk/hesitate/walk the user reported. Two
frames is the once-per-frame sampling floor — the adapter can only look at the peer once a frame — so
this is close to as far as the idea goes.

**Set `STEP_TRIGGER_PROG = 0` to revert exactly.** It gates the work, not a decision: at zero the
progress is never computed and the trigger is the old tile comparison, byte for byte.

**It cannot help at `-interp=0ms`, and that is not a fault in it.** With interpolation off the pixel
position is the newest 20Hz sample and jumps in threes like the tile does, so there is no smooth
quantity to lean on. **Judge this at shipped settings only** — `run-relay-loopback-shipped.bat` +
`run-core-crystal-shipped.bat`, and read the core's own `smoothing:` line before believing anything.

**NOT confirmed on screen.** Every number here is mine, from loopback. Whether two frames of residual
spread is invisible and six frames was the stutter is a question only a real session answers, and the
honest possibility is that the user was looking at something else entirely.

## Crystal: shoving a MOVING ghost aside could never work — fixed, NOT confirmed (2026-08-23)

The open item said a walking peer reaches neither shipped passable rule. Half of that turns out to be
a plain bug rather than a missing feature.

`shouldBlock`'s shove rule releases a peer after half a second of the player standing still and
pressing into its tile — the rule that makes doorways and route exits work without the adapter
knowing where they are. It compared the player's intended destination against the peer's CURRENT tile
only. But `MAP_X`/`MAP_Y` name the DESTINATION from the instant a step begins, and the engine's own
`IsNPCAtCoord` blocks on both the current coords and `LAST_MAP_X`/`LAST_MAP_Y` — so a character
mid-step is a two-tile obstacle, and the tile actually stopping the player is very often the one the
rule was not looking at. Pressing into it therefore never accumulated, and the ghost never released.

Fixed by remembering the tile a peer steps out of and accepting either, while the peer is actually
mid-step (20 frames, a step being ~16). The idle rule is untouched and still needs five seconds on one
tile, which a walking peer still cannot reach — that half of the item stands.

**NOT confirmed.** What to watch: walk into a MOVING ghost and keep holding the d-pad into it; after
about half a second you should pass through. `MESHGHOST_CRYSTAL_GHOSTS_PASSABLE` must be UNSET for
this to mean anything — it short-circuits the whole rule.

## Crystal: the promotion blink was a one-frame hole, not an overlap — fixed, NOT confirmed (2026-08-23)

**The user, on the rig:** *"the spawned ghost still 'flicker' whenever it has been idle/despawned, and
then moves 1 tile"*, and, asked to place it, *"at the start of moving from idle to another tile"*.
That is the PROMOTION — a peer that stands still is demoted to the drawn tier and its engine object
despawned, so every time a peer starts walking a fresh object is created.

**Measured by dumping hardware OAM every frame across four promotions.** An object this adapter
creates has **no OAM entries at all on the frame it is created**, and first appears one or two frames
later. The adapter released the drawn copy after one frame, so on at least one frame **neither tier
drew the peer**.

| frame after promotion | drawn copy (before the fix) | engine object in OAM |
|---|---|---|
| +0 (the promotion frame) | painted | absent |
| +1 | **released** | absent, or first appears |
| +2 | gone | present |

**The comment was describing an intention, not the behaviour.** It read *"OVERLAP THE TWO TIERS BY
ONE FRAME... that costs a single frame where both draw the peer"*. The measurement says the two were
never on screen together at all — what was called an overlap was a hole.

**And the handover had never been doing anything anyway.** A second, UNCONDITIONAL `overflow[id] = nil`
runs further down `renderRemote` on every frame for a spawned peer, so the entry the promotion
deliberately kept was wiped one frame later whatever `handover` said. Both release points now honour
it; fixing only the first would have changed nothing and looked like the theory being wrong.

**Safe to hold the extra frame:** the promotion places the object on the drawn model's own tile, and
the model's discarded sub-tile remainder measures **0.0px** at that instant (logged under
`MESHGHOST_CRYSTAL_STEP_LAG`). The two agree on the pixel for as long as the handover lasts, so a
frame where both draw is invisible — which is what the original comment assumed and never got.

**A theory killed on the way, worth not re-deriving.** The promotion was suspected of jumping the
peer by up to 15px, because it places a tile-aligned object where a sub-pixel drawn model was. It
does not: the remainder is 0.0 every time, because promotion is triggered by the peer STARTING to
move, at which point the model is still parked on its tile.

**NOT confirmed on screen.**

### Probe note: three iterations, and only the last one could have been right

The first two versions of the OAM probe produced confident numbers that were artefacts.

1. **Calibrating off OAM entry 0 as "the player".** The adapter's own `readPlayerOamFrame` warns that
   entries 0-3 are the player's only while nothing else is on screen, and a spawned ghost takes them.
   Reported "21-24 frames to visible", a third of a second, which is not a rendering delay and should
   have been disbelieved on its face.
2. **Assuming a fixed sprite-coord-to-OAM offset of +8,+16.** Object coords are map-relative, not
   screen-relative: measured, the offset was +64,+44 and moves with the camera. This version at least
   **failed loudly** — it gated every reading on finding the PLAYER at its own predicted position, so
   when the assumption broke it recorded nothing instead of inventing a number. **That gate is the
   only reason the wrong answer did not get written down as a measurement.**
3. **Dumping the whole window** — the ghost's coords, the predicted OAM position, and every live OAM
   entry, frame by frame. The answer was visible directly in the entry list without trusting the
   prediction at all.

**The lesson: a probe that computes a match should also print the raw evidence the match was made
from.** Both wrong versions returned a boolean, and a boolean cannot be sanity-checked. The third
printed the OAM table, and the two missing rows were simply there to see.

## Crystal: the drawn tier renders a BUMP — measured, user says it looks good (2026-08-23)

**The user, watching the compare rig:** *"when standing idle, and walking into a wall. the drawn
ghost is not doing the 'walking' animation like the player & spawned ghost does"*. After a first
wrong attempt, *"now the drawn is doing it but it looks slow/weird"*; after the fix below, *"think it
looks good"* — **their hedge kept, so this is not a confirmation.**

**Why the drawn tier misses it, and why this is not a bump-specific bug.** The spawned tier hands the
engine the peer's `OBJECT_ACTION` and the engine animates for free. The drawn tier DERIVES its pose
from position and sub-tile progress, so **anything that animates without moving is invisible to it by
construction**: bump, spin, fishing, the `!` emote and the Fly landing are one gap with one cause.
All of them already ride on `extras.act`, which the drawn tier was not reading at all.

**How Emerald avoids the whole problem.** It puts the peer's own animation state on the wire —
`extras.sanim` (sprite animation number) and `extras.sidx` (frame index) — and resolves the actual
ROM frame from them, so its drawn tier renders whatever the peer is genuinely playing. It never has
to know a bump happened. (Its spawned tier also infers one — peer "walking" but not moving for
`BUMP_AFTER_FRAMES = 20` — and requests `BUMP_ACTION[dir]`.) Crystal derives instead of copying,
which is the design difference behind this whole class.

### What a bump actually is, measured

`probes/bump_probe.lua`, holding a direction into a wall, run-length encoded so the cadence reads:

```
facing 2: 0x80 x3, 0x00 x13     facing 3: 0x00 x3, 0x80 x13
facing 0: 0x80 x3, 0x00 x13     facing 1: 0x00 x3, 0x80 x13
```

- `OBJECT_WALKING` stays **STANDING**, which is why a bumping peer goes out as `anim="idle"` and the
  tier's `moving` flag can never see it.
- `OBJECT_ACTION` reads **3** (BUMP) throughout.
- The tile actually drawn alternates between the character's **standing** art (`base + 0x00`) and its
  **stepping** art (`base + 0x80`) in **16-frame runs**, while `OBJECT_FACING` walks 0,1,2,3.
- `OBJECT_STEP_DURATION` is 0, so `stepProgress` is 16 — already inside the stepping-view band the
  frame picker tests, which is why no special case was needed for `prog`.

**So a bump is a two-pose shuffle, not a stride cycle**, and that distinction is the entire fix.

### The wrong version, and what it looked like

The first attempt passed `walking = true` for the whole bump. `pick` then returns a STEPPING frame
every time and cycles the stride images — the ghost performing something the player never does.
*"slow/weird"* was exactly right. **A pose derived from the correct data can still be the wrong
animation; only the frame sequence the engine actually draws settles it.**

### Two caveats on the fix

- **Only the DOWN wall was measured.** The other three directions rest on `OBJECT_FACING = dir * 4 +
  stride` (which `setGhostStanding` writes), so masking to two bits strips the direction and leaves
  the stride the alternation is keyed on. That is arithmetic, not an observation.
- **The 3-frame lead-in is ignored.** The image block changes three frames before the facing does;
  the fix matches the 13-frame majority and does not special-case the transition.

### `peerAct` was declared below two of the four places that now read it

The drawn tier's `overflow` entries — including the `MESHGHOST_COMPARE_TIERS` copy, which is the one
on screen while judging this — are built ~130 lines ABOVE where `peerAct` was declared. A local
referenced above its declaration is a nil GLOBAL in Lua, silently, so `act` would have arrived as nil
and the bump would have looked simply not to work **on the exact rig used to judge it**. Hoisted to
sit above every use. Fourth time this file has hit that trap; `dev-scripts/lua-forward-refs.py` does
not catch it because both the use and the declaration are inside one function.

## Crystal: the residual promotion flicker was a 2px backward hop, not a missing frame (2026-08-23)

**The user, after the frame-gap fix:** *"lets fix the spawned ghost 'flickering' slightly whenever it
moves 1 tile after having being despawned/respawned"*, and, placing it exactly, *"it only happens
after the spawned ghost has been idle for a bit and despawned, and then respawn and move a tile. not
anywhere else"*.

**It was NOT another gap.** The frame-count fix earlier the same day was correct and complete: traced
with the paint position and the live OAM count on one line, the drawn copy covers both frames before
the engine's copy exists, and nothing is ever undrawn. What was left:

```
f=1093  drawn copy PAINTED at 112,76   oam=16   (engine object not rendered)
f=1094  drawn copy PAINTED at 112,78   oam=16   (engine object not rendered)
f=1095  released                                (object appears, tile-aligned, at 76)
```

**The drawn copy keeps tracking the peer during the handover.** The peer has by definition just
started moving -- that is what triggers the promotion -- so the painted model walks on while the
engine object sits on its tile until it takes its own step. The engine's copy therefore appears 2px
BEHIND where the painted one just was. Two pixels, once per promotion, and a promotion happens every
time a peer starts walking after standing still.

**Fix:** latch the paint position on the first handover frame and hold it until release. That frame is
the one where the two tiers provably agree -- the model's discarded sub-tile remainder measures 0.0px
there. Verified in the same trace: both handover frames now paint at 112,76. **NOT confirmed on screen.**

### `client.screenshot` does not capture the Lua overlay — so no screenshot can see the drawn tier

Found while chasing this, and it invalidates a whole class of evidence. Six consecutive frames were
captured across a promotion and decoded column by column: the only extra character in ANY frame was
the spawned object at +3 tiles. The `MESHGHOST_COMPARE_TIERS` drawn copy at -2 tiles appears in none
of them, while the adapter's own log says it was painted on every one.

**So BizHawk's `client.screenshot` captures the emulated framebuffer, not the composited window.**
The drawn tier is invisible to it, permanently. A screenshot showing "no ghost there" says nothing
about the drawn tier, and the first reading of those six frames -- *"the peer vanishes on the
promotion frame"* -- was exactly that mistake, from an instrument that cannot see the thing.

**What to use instead:** the tier's own paint trace (position, and whether it painted at all), with
the live OAM count on the SAME line so the paint clock and the engine clock can be compared without
aligning two logs. That pairing is what produced the answer above in one run.

## Crystal: a fresh ghost wore the DONOR's facing, and a later change made it visible (2026-08-23)

**The user, immediately after the handover hop was fixed:** *"the facing direction is a bit weird when
its happening now, but i think the flicker is gone"*.

`spawnGhost` pins the new object's standing facing to whatever direction the TEMPLATE it was cloned
from happened to be facing, and leans on `stepGhost` re-pinning it on the first step. That cost one
frame while the first step went out on the very next frame. It stopped being cheap when
`STEP_TRIGGER_PROG` began holding that first step until the peer is four pixels into its own, so the
donor's facing now sits on screen for several frames.

**A latent fault a later change exposed, not a new one** — and the third of its family: it is the same
inherited-donor-identity class as the trainer clone (`pitfalls.md`, "a spawned ghost was a TRAINER").
**A ghost must describe the PEER, never the character whose struct it was copied from**, and every
field copied from a template is a place that rule can be broken quietly.

Fixed by writing the peer's own direction — the movement byte plus DIRECTION and FACING, the same
three `stepGhost` writes — immediately after a successful spawn. **NOT confirmed on screen.**

**Worth noting for the next change of this kind:** the fault was invisible for as long as the window
was one frame wide, and no test would have caught it. Widening a window is a way of REVEALING bugs,
not only of causing them — when a timing change produces a new visual report, check what is now on
screen for longer before assuming the change itself is wrong.

## Crystal: the periodic whole-TILE drift, and the state it happens in (2026-08-23)

Found by the 9x9 square run: the spawned tier's standing re-anchor corrects the ghost by a **whole
tile** — `+16,+0` px, always on one axis — four times in 375 steps, evenly spaced about 13 seconds
apart. Everything else in that run was clean: zero runaways, zero `WROTE WALKING`, zero respawns,
zero snaps, zero teleports, no peer timeouts, and step-start lag steady at 17-20 frames with 239 of
375 at exactly 19.

**It is periodic, and it is not the promotion** — correlated from outside the adapter, the nearest
promotion is 4-5 seconds away every time.

**The state it is in, once the drift line was made to name it rather than just report its size:**

```
tile 17,20 last 16,20 walking=255 step_type=5 duration=8 action=1 facing=12
tile 16,20 last 16,20 walking=255 step_type=1 duration=0 action=2 facing=12   (a -16,+0 case)
```

- **`step_type=5`, and this adapter only ever writes 2.** So the ENGINE has put the object into a
  step type of its own choosing.
- **`duration=8` alongside `walking=255`** — a live step duration on an object that reports STANDING.
- `OBJECT_MAP_X` is 17 while `LAST_MAP_X` is 16: the object has been told it is on the next tile
  while its sprite is still on the previous one, which is exactly the 16px the re-anchor takes back.

**The leading suspicion, NOT established:** a ghost is cloned from a live map object, and
`RestoreDefaultMovement` re-reads `MAPOBJECT_MOVEMENT` when a movement ends — so the engine may be
resuming the DONOR's own movement behaviour and walking the ghost itself. That would make this the
fourth member of the inherited-donor-identity family, after the trainer clone, the `!` sight range,
and the donor's facing at spawn. It would also explain the periodicity: a wander routine on its own
timer rather than anything keyed to our steps.

**What to do next, in order:** name what step type 5 is in `pret/pokecrystal`'s step-type table;
log `OBJECT_MOVEMENT_TYPE` and `MAPOBJECT_MOVEMENT` on the same line as the drift; and check whether
`setGhostStanding`'s movement byte is one the engine will resume from. The re-anchor bounds the
damage to one tile, so this is visible as an occasional snap rather than a runaway — which is why it
survived a session that was otherwise clean.

## 2026-08-25 — Crystal: the rest of the action classes on the drawn tier

**Built and not watched. Nothing below is confirmed.** The bump case (2026-08-23) was the first row
of `phase9.md`'s 2026-08-19 animation enumeration; this is the rest of it — spin (which includes
turning in place, spin tiles, Teleport and Dig), the Dig/Teleport flicker, fishing, and the Fly
landing. Written from the decompilation, cited per class in
`adapters/emulator/pokemon/crystal/documentation.md`; the narrative is in `phases/phase9.md`.

**Where it lives:** `facingFrames.pose` in `meshghost_crystal.lua`, called once per peer per frame
and shared by the drawn and hardware tiers. It replaces the bump special case and returns exactly
what that special case returned for action 3.

### What is a derivation from the source, not a measurement

- **The engine's action handlers tick roughly every two video frames.** Derived: the decomp has a
  bump advancing its facing once per 8 increments of `OBJECT_STEP_FRAME`, and `bump_probe.lua`
  measured that facing advancing once per 16 video frames on screen. Consistent with the
  2026-08-23 scroll measurements, which put a tile at 8 ticks across ~16 frames, and with those
  measurements' own finding that the parity is not fixed. **Not separately measured for spin,
  fishing or skyfall.**
- **The per-class cadences** — spin advances its direction every 4 ticks, a turn in place is 2 + 2
  ticks, skyfall advances its stride every 2 ticks (double a walk), the Teleport/Dig spin phases
  are 16 ticks each. All read off `engine/overworld/map_object_action.asm` and
  `engine/overworld/map_objects.asm`. **None seen on screen.**
- **`probes/action_probe.lua` exists to confirm all of the above** and has never been run. It
  drives the turn and the bump itself, then opens a long free phase for fishing, Fly, spin tiles,
  Dig and Teleport, run-length encoded with the engine-tick count inside each run.

### What was removed, and why it matters

**`OBJECT_ACTION_EMOTE` (8) is no longer accepted from a peer.** A player's object never holds it:
the `!` is a separate map object (`SpawnEmote`, flagged `EMOTE_OBJECT_F`). Writing 8 onto a spawned
ghost would have replaced its **body** with the emote box, on its own tile rather than above it.
Nothing observed — this is a fault removed from the code by reading, not a symptom that was seen.

### The fishing rod is read from the cartridge, and only on V1.0

The rod is an absolute tile id, i.e. one of two shared tiles the game loads on demand — which on a
receiving machine hold the jump shadow unless the local player is also fishing. So the drawn tier
reads `FishingRodGFX` from ROM (`41:4560` on our own hash-verified `pokecrystal` build), gated on
`classifyRom()` returning `known`. **The offset has never been read on a running ROM**, and unlike
the sprite table it has no cheap signature check, which is why the gate is ROM identity. On any
other build the rod is simply absent.

## DRAINED 2026-08-26 — fishing, the bite and the "!"

**Everything this queue held about fishing left it in one pass**, on the user's confirmation:
*"okay now it worked perfectly, Fishing is complete/verified."* Five entries: the offline
decompilation audit, the wrong rod asset, the one-tile jump at a bite, the wiggle and the emote,
and the session's plan for what to watch.

They are not summarised here, because that would be an index of an index. Where each went:

- **The confirmation, with what it does and does NOT cover** — [`VERIFIED.md`](VERIFIED.md),
  "CONFIRMED ON SCREEN 2026-08-26 — Crystal: fishing, the bite wiggle and the '!'", and the
  separate entry for the tile jump. **Read the *not covered* half**: the spawned and hardware tiers
  were never exercised, only one fishing direction was, and in loopback the fishing BODY half was
  right by accident.
- **How each was found, and the three lessons** — `../../../../agent_docs/pitfalls/by-lesson.md`,
  the 2026-08-26 entries: the right address pointing at the wrong asset, the player not owning OAM
  entries 0-3, and a ghost that vanishes being an adapter that was unloaded.
- **How the GAME does fishing** — [`documentation.md`](documentation.md), which now records the
  graphics swap `LoadFishingGFX` performs.
- **The instruments** — `probes/rod_check.lua` (diff the cartridge against VRAM) and
  `probes/fish_drive.lua` (cast, clear with B, recast; reload only on a battle).

**What fishing left behind, unwatched:** `extras.yoff` is the same byte the Fly landing's fall and
the Dig/Teleport drop use, so those may have gained their fall for free — nobody has looked. And
peers can now show every emote in the table, not just the "!".

### What to look at, and what correct looks like

**Item 3 (fishing) is DONE and confirmed** — 2026-08-26, see the drain note above. The other four
are still the list, and the rig for them is unchanged: loopback, ghost offset to the side with
interpolation at 0, so the drawn ghost can be judged against the player frame for frame.

1. **Turn in place** — tap a direction the player is not facing, without walking. The drawn ghost
   should turn through the same intermediate direction the player does, not snap.
2. **Walk into a wall** — the 2026-08-23 case, re-checked because the code that produced it moved.
   Should look exactly as it did then.
3. **Fish** — the ghost should hold the standing pose for the direction it cast in, with a rod, for
   as long as the player's rod is out. A ghost that faces down while the player fishes to the left
   is the facing byte not being read; a body with no rod is the ROM gate refusing.
4. **Fly into a town** — **nothing is expected to work here, and the reason is measured.** See
   the 2026-08-26 entry below: through an entire Fly the player's own object holds action 1
   (STAND), facing `$FF` (the engine draws nothing for it) and `yoff` 0. The game hides the player
   object and animates the sequence some other way, so there is no skyfall action and no fall on
   the wire to copy — not because the adapter drops them, but because the player's object never
   carries them. Anything a ghost does during a Fly today is an artefact.
5. **Dig or Teleport** — unmeasured. Fly turned out not to use the player's object at all, so the
   assumption that these do cannot be carried over; `probes/fly_probe.lua` answers it for either
   one in a single run.

**Known remaining differences, stated so they are not reported as faults:** no emote over a peer's
head at all; the spawned tier's spin runs on the engine's own clock rather than the peer's phase;
and no Fly landing at all, per the above.

## 2026-08-25 — Crystal: `jsonDecode` could loop forever on truncated input

**Fixed, and unconfirmed in BizHawk's own Lua.** Crystal's decoder was the only one of the repo's
seven copies written fresh rather than from the guarded shape the other six use, and it had neither
guard: both container loops were `while true` with no end-of-input test, and the fallthrough at the
bottom of `parseValue` advanced the position by one and returned `nil` instead of erroring. On
`{"a":1` with no closing brace the loop asked for the next key forever. **The surrounding `pcall`
is no protection — an infinite loop raises nothing**, so in BizHawk this is a frozen emulator
rather than a dropped message.

**Not reachable from a relay**: the core emits well-formed JSON and the framing only splits on
newlines, so it needs a local process on the bridge port. Fixed anyway.

**What changed**: an end-of-input check at the top of each container loop, an explicit
`expected ',' or '}'` / `']'` on a bad separator (matching the other six copies' wording), a
function-scope depth counter capped at 64 so deep nesting cannot exhaust the Lua stack either, and
the silent fallthrough replaced by an error.

**Self-test, and what it is worth**: the function was extracted and run against eight valid inputs
and ten truncated or malformed ones. All eight valid ones parse to the right values, including a
full `remote_state` message and backslash escapes; all ten bad ones return `nil` within
milliseconds instead of hanging. **That was a desktop Lua, not BizHawk's** — the file compiles
there too, but the check that matters is that the adapter still loads and connects in a real
session, which is part of the live test below.

## DRAINED 2026-08-25 (evening) — surf, the bike, movement, the promotion seam, and the lag

**Sixteen entries left this queue in one pass**, on the user's confirmation at the end of that
session: *"moving perfect, surf working, bike working etc etc"*, and, riding a 9x9 on the bike with
the full stack live, *"yee its smooth to play/control as well now. and looks smooth visually"*.

They are not summarised here, because that would be an index of an index. Where each went:

- **The confirmation itself, with what it does and does NOT cover** —
  [`VERIFIED.md`](VERIFIED.md), "CONFIRMED ON SCREEN 2026-08-25 (evening)". Read the *not covered*
  half before assuming anything about fishing, Fly, Dig, the emote, UI clipping, battles or the
  hardware tier: none of those was exercised.
- **How each fault was found, and the three reverts** — `agent_docs/phases/phase9.md`, the
  2026-08-25 evening section. The reverts matter more than the fixes: two overlay optimisations
  and two camera-beat delays, each the obvious next idea, each killed by measurement.
- **The transferable lessons** — `pitfalls/by-lesson.md` (the never-invalidated cache; a partition
  that is exact at one gait only), `pitfalls/by-host.md` (the Lua console's buffer cost, and why
  "60fps while the user says lag" means the UI thread), `_template/probes.md` (two renderers of one
  state disagreeing is the cheapest localiser there is).

**What is still open on this adapter is above this line, and is genuinely unwatched** — the action
classes (fishing, the Fly landing, Dig/Teleport, spin tiles), the UI clipping cases, the battle
cases, and the hardware tier. The movement and gait work is done until a real two-machine session
says otherwise: every number behind the confirmation is loopback, whose echo is smaller than any
network peer's.

## 2026-08-26 — Crystal: the SPAWNED tier never applied the peer's `yoff` at all

**Fixed by reading, not by watching, and nothing below has been on screen.** `yoff`
(`OBJECT_SPRITE_Y_OFFSET`) went on the wire with fishing earlier the same day and the drawn tier
applied it — that is the bite wiggle the user confirmed. The spawned tier did not: the constant was
declared as `emote.F_YOFF` and then **never read anywhere in the file**. So a spawned ghost stood
perfectly still through every vertical animation the game has — the bite wiggle, the Fly landing's
fall, the Dig/Teleport drop, and a ledge hop's arc — while the painted copy two tiles away moved.
Nobody saw it because the 2026-08-26 fishing session painted both copies throughout
([`VERIFIED.md`](VERIFIED.md), "What it does NOT cover").

**The fix is one write per update**, above the idle branch rather than inside it, because a ledge
hop changes tile while its arc runs. It works because the engine already reads that field for us:
`_UpdateSprites` adds `OBJECT_SPRITE_Y_OFFSET` to `OBJECT_SPRITE_Y` when it builds OAM, and nothing
on a ghost's own step path writes the byte back — `StepFunction_NPCWalk`, the step type 2 a ghost
walks on, calls `Stubbed_UpdateYOffset`, which the game dummies out to a bare `ret`. All three from
`engine/overworld/map_objects.asm`.

**The value is now floored and clamped to ±96 once, at decode, so both tiers get the same number.**
That is the engine's own envelope, not a taste value: `StepFunction_SkyfallTop` writes exactly `$60`
and the fall scales `Sine` by `$60`, so -96..+96 is the whole range the byte ever holds (a jump arc
reaches -12, the bite wiggle 1). It is peer-controlled state that now ends in a memory write, which
is the same reason `ACTIONS.peer` bounds the action byte.

**What to watch, on the compare rig with both tiers up:** the two ghosts should wiggle and hop
*together*. **Not the Fly or Dig fall** — the paragraph above claimed those came along for free and
that claim was wrong; it was written from the decompilation without measuring, and the measurement
the same day killed it. See "the Fly landing is not on the player's object at all" below. What is
left of this entry is the bite wiggle and a ledge hop's arc, which are real and still unwatched.
**No new top-level local was spent** — the file is still 197 of 200 (`emulator/CLAUDE.md`).

## 2026-08-26 — Crystal: the Fly landing is not on the player's object at all, and two fixes from it

**All of this is measured, none of it is confirmed on screen.** The user, after the morning's
`yoff` work went live: *"fly looks really broken on the ghosts, also the spawned ghost goes
invisible when fly is used & it goes invisible when despawned after fly has been used"*, and, asked
which: *"drawn ghost just looks weird/bad sprite during fly"*, *"goes invisible during the fly
animation, and also goes invisible when despawned afterwards if flying to the same town that you
were in (seems to stay visible if flying to another town)"*.

Three separate faults wearing one symptom. `probes/fly_probe.lua` (read-only, player and every
occupied object slot on one line) and `probes/menu_state_table.lua` (drives a START menu and
tabulates the display state) did the work.

### The finding that invalidates the morning's premise

**Through an entire Fly the player's own object holds `OBJECT_ACTION` 1 (STAND), `OBJECT_FACING`
`$FF` and `OBJECT_SPRITE_Y_OFFSET` 0.** Facing `$FF` is STANDING, which is the engine's own way of
saying *draw nothing for this object* — so the game hides the player object for the whole sequence
and animates the landing some other way. Not one frame of the log shows action 16 (SKYFALL) or a
non-zero `yoff`, on any object.

So **there is nothing on the wire to reproduce a Fly landing from**, and the entry above this one
was wrong to say the fall arrived for free with fishing's `yoff`. That was written from
`StepFunction_Skyfall` in the decompilation — which does express the fall in that byte — without
checking whether the player's object ever runs it. It does not. **The decompilation says how the
engine CAN do a thing; only a measurement says whether this game DOES it here** — the same rule
that already has its own bullet in `CLAUDE.md`, applied in the wrong direction for once: reading
replaced measuring rather than the other way round.

What still stands from that entry: the bite wiggle (confirmed on screen) and a ledge hop's arc
(unwatched) are genuinely in `yoff`, and the spawned tier now applies it.

### Fault 1 — the drawn ghost's "weird/bad sprite" (FIXED, unwatched)

While the player's facing is `$FF` the engine emits no OAM entries for it, so entries 0-3 belong to
whatever else is on screen. `readPlayerOamFrame` read them anyway: the log shows tile offsets `$84`
and `$88` arriving during the Fly, and both PASS the `(offset & 0x7F) < 12` art test, so another
character's stepping views were filed as the player's own artwork for whatever direction the player
happened to be facing — and that cache is kept for the session. **Fix: learn nothing while the
player's own facing is STANDING.** Fourth entry in this family; the y-range test cannot catch it,
because those entries are a real character that really is on screen.

### Fault 2 — the ghost that never comes back (FIXED, unwatched)

`wMenuBorderTopCoord`..`RightCoord` (`$cf82-$cf85`) are non-zero for exactly as long as a menu is
open and are zeroed when one closes **normally** — driven and logged, set at frame 9 of the open and
cleared at frame 9 of the close. Fly is the exception: its menu is torn down by a warp, leaving
`0,10,15,19` — the whole right half of the screen — set forever. `uiPanelOpen()` re-latched on that
every frame, and every painted peer in that half was hidden for the rest of the session. Measured in
the failed state: `uiOpen=true rect=l=80 t=0 r=160 b=144 wy=144` with no menu on screen.

**Fix: clear the latch and the remembered rectangle where the world is rebuilt** — a menu cannot
survive a map load, so a rectangle still set there is stale by definition. That block already
clears four other pieces of per-map bookkeeping.

**Two other gates were tried first and both were killed by measurement, which is why the fix is
where it is** — worth knowing before either is proposed again:

| candidate | why it looked right | what the measurement said |
|---|---|---|
| the panel's own frame corner is in the tilemap (the test `textBoxOpen()` already uses) | `MenuBox` → `Textbox` → `TextboxBorder` writes tiles 121/122 at the box's top-left | the corner **survives the menu closing** — 87 consecutive samples said `true`, straight through a menu being opened and shut |
| LCDC window-enable / WY / WX | menus are panels, panels drive the window layer | **byte-identical in all three states**: `LCDC=E3`, window enabled, `WY=144`, `WX=7`, with a menu open, with none, and after closing one |

### What to watch

1. **Fly to the town you are already in, then walk around.** The ghost must come back and stay.
   This is the whole point of fault 2, and the same-town case is the one that failed.
2. **Open the START menu with a ghost beside you.** It must still be clipped by the menu — that
   was confirmed on 2026-08-19 and fault 2's fix must not have regressed it.
3. **The ghost's sprite after a Fly.** Wrong-looking art that persists after the Fly is fault 1 not
   being fixed; the cache keeps what it learns, so this is judged after the sequence, not during.
4. **The Fly itself is not under test.** Expect the ghost to do nothing sensible during the
   animation; that is the measured gap above, not a regression.

## 2026-08-26 — Crystal: the menu rectangle is a SHARED SCRATCH SLOT, and the Fly fix was in the wrong place

**Both measured live in the failing states, neither fix confirmed on screen.** Two reports on the
first re-test of the morning's Fly fixes: *"a weird sprite showed up in my pokemon inventory when i
tried to use surf (somewhere where i can't)"*, and *"the spawned ghost was still invisible while
using fly"*.

### The weird sprite in the party menu (FIXED, unwatched)

Caught with `MESHGHOST_CRYSTAL_UI_DEBUG` on while the user reproduced it, one line carrying the
whole mechanism: `boxOpen=true coords=12,0,17,19 — 1 painted at: p13-ghost@56,4`. The party menu
publishes a full-screen rectangle (`0,0,17,19` — watched live), but choosing Surf where it cannot
be used draws a "can't use that here" text box whose `12,0,17,19` **replaces** it —
`wMenuBorder*` describes the most recent box drawn, never the union of what is on screen. One
remembered rectangle then protected the bottom six rows of a screen that was entirely menu, and
the ghost painted at y=4 over the party list, persisting because a covered menu never re-publishes.

**Fix: `lastMenuBox` is now a list.** Every distinct rectangle published while the UI latch is
alive stays in it, and a peer inside ANY of them is hidden. The list dies with the latch exactly as
the single rectangle did. Stacked UI — a menu with a text box on top — is the normal case.

### The Fly fix that never fired (FIXED, unwatched)

The stale-rectangle clear shipped this morning lived in the **area-change** block — and flying to
the town you are already in keeps the same area id, so the clear never ran in precisely the case
the user reported. It now lives at the `not inPlay()` branch: `wMapStatus` leaves HANDLE across
every warp, same-map ones included (the 2026-08-23 transition measurements), while an overlaid menu
or text box never takes the status there at all. A battle also clears it, which is correct — no
menu survives the battle screen either.

**A placement lesson worth the ink:** the fix was tested by watching the counter clear on a rig
where the tester walked through a DOOR — an area change — and the symptom's own trigger, a
same-area warp, was never exercised. The fix validated on the neighbouring path, not the reported
one.

### What to watch

1. **Party menu → Surf where it fails → let the text sit.** Nothing painted over the menu, and
   nothing after dismissing it either.
2. **Fly to the same town, walk around.** The ghost returns and stays.
3. **The START menu and ordinary text boxes still clip** — the list must not have broken the
   single-rectangle cases confirmed 2026-08-19.

## 2026-08-26 — Crystal: a peer that arrives by Fly now drops out of the sky (BUILT, unwatched)

**The user's call**, choosing between this and a plain teleport-in, after pushing back on "the
ghost can't do fly" — correctly: the parity rule stands, the missing piece was only a SIGNAL. What
shipped, none of it watched:

- **The signal**: `hMapEntryMethod` ($ff9f, HRAM) is the game's own record of how the player last
  entered a map — `$FC` is `MAPSETUP_FLY` — set at the warp and zeroed before play resumes
  (`engine/overworld/events.asm`). The adapter latches it per frame in `tick()` (getLocalState
  cannot see it: the byte lives entirely inside the window it refuses to sample) and wears it on
  the wire as `extras.entry` for 240 frames, which spans the fly cutscene's own send silence.
  ROM-gated like the fishing rod: HRAM is as rearrangeable by a patch as WRAM.
- **The spawned tier** runs the REAL fall: `teleportGhost` gains a `skyfall` arg and writes
  `STEP_TYPE_SKYFALL` (0x0e, the Burned Tower floor-fall) plus a zeroed `OBJECT_STEP_INDEX`
  (0x1c, the anon-jumptable cursor). The engine then does everything: 16 ticks hidden, 16 ticks
  falling -96→0 on its own Sine, ending in FROM_MOVEMENT which parks the ghost normally. Two
  guards keep the adapter's own hands off mid-fall: `applyPeerAction` and the peer-yoff write both
  skip while the ghost's step type is 0x0e.
- **The painted tiers** mirror it: a per-peer drop envelope (64 frames, matching the engine at the
  measured 2 frames/tick) hides the copy for the first half via the existing `poseHide` path and
  feeds the same quarter-sine into `yoff` for the second. One start frame for all tiers: the drop
  begins when the flag is worn AND the tile jumps, once per flag-wearing.

**Deliberately absent, so they are not reported as faults:** nothing on the DEPARTURE (the flying-
off animation is a private cutscene even in the flyer's own game — `documentation.md`); the
painted copy falls in its standing pose while the spawned one runs the engine's falling walk-cycle;
a cross-map arrival where the ghost is freshly SPAWNED (not teleported) does not drop — the
teleport path is the only trigger, on purpose, because promotion also spawns and must never drop.

**What to watch, loopback:** fly anywhere; as the player lands, both copies should hold hidden
~half a second, then fall onto their tiles together and park. A copy that blinks straight in is
the flag not arriving; one pinned to the ground mid-fall is a guard not holding; a drop at any
moment OTHER than a fly landing (a door, a promotion) is the trigger being too loose and matters
most.

### Follow-up the same day: the fall was armed on the one path a fly does not take

**The user, on the first watch:** *"the drawn ghost does the 'landing fly' animation, but with a
somewhat glitched sprite, the spawned ghost does not do this... it just walks towards where its
supposed to be afterwards."* So the painted half worked and the engine half never ran.

**Cause: the drop was hung on `teleportGhost`, and a fly landing hardly ever reaches it.** A
SAME-town fly usually lands within three tiles, which is the short-deficit branch that WALKS the
ghost there — exactly what was seen — and a cross-town fly rebuilds the world, so the ghost is
freshly spawned rather than moved. The teleport branch is the one placement path a fly rarely
takes. **Third time today a fix has been attached to a trigger that is a proper SUBSET of the
event it meant to catch** (area-change vs map-load, twice, and now teleport vs placement); the
pattern is in `pitfalls/by-lesson.md`.

**Fix:** the fall is armed on the ENVELOPE, above every movement decision — while the drop is live
the ghost belongs at its landing tile falling onto it, and the function returns until the engine's
skyfall ends, so nothing can step, chain or catch-up a ghost in mid-air.

**And the glitched sprite is a hypothesis, not a finding.** The drawn tier's "world is being
rebuilt, do not paint" window was armed by an area change only, so a same-town fly painted straight
through the map load — and that tier draws from resident VRAM tiles while `wUsedSprites` is being
repopulated across those very frames. The window is now armed by the map-entry byte itself and
re-armed for as long as it is stamped. **If the sprite is still glitched after this, the cause is
elsewhere and the next step is a sprite trace** (`MESHGHOST_CRYSTAL_SPRITE_TRACE`), which names
which source branch each peer took and the tile base it landed on.

### And the cross-town landing: two reasons it could never arm

**The user, after the same-town landing came good:** *"it looks fine when landing now, but only if
its flying to the same town."* The same-town case is confirmed on screen (`VERIFIED.md`); the
cross-town one had two independent blockers, both of them consequences of a map load:

1. **Map coordinates are map-LOCAL, so a cross-town landing routinely reads as a SHORT hop.** Fly
   from tile 10,5 on one map to 12,6 on another and the distance test sees three tiles and declines
   to arm. Comparing two positions from different maps is meaningless in the first place — the
   comparison now carries `area_id`, and a changed area IS the jump. (A peer with no previous
   position at all arms too: that is a peer whose bookkeeping the map load cleared.)
2. **A cross-map arrival reaches the engine tier through a SPAWN**, never through the teleport or
   the catch-up walk. The blanket "never on a spawn" written a commit earlier — added to stop a
   PROMOTION dropping out of the sky — excluded the exact path this case takes. The envelope
   already makes promotions safe, because it exists only when the peer wears MAPSETUP_FLY and a
   peer that merely started walking never does; so the spawn path now drops when the envelope is
   live, and the blanket rule is gone.

**Fourth and fifth instance of the same habit in one day** — a trigger that is a proper subset of
the event that mattered. The pattern, and the one-sentence check for it, are in
`pitfalls/by-lesson.md`.

**What to watch:** fly to a DIFFERENT town — the ghost should hold hidden then fall, exactly as the
same-town case now does. Same-town must still work. And a promotion (a ghost appearing as you start
walking, no fly involved) must still be a plain appearance with no fall.

## 2026-08-26 — Crystal: a flying peer should wear its POKEMON, and does not (NOT BUILT)

**Spotted by the user while testing the drop:** *"both same/different town teleports are not
changing their sprites to the 'pokemon that used fly' like the player does."* Correct, and it is a
parity gap rather than a nicety — anything the player can do, a ghost must too.

**How the game does it** (`engine/events/field_moves.asm`, `engine/gfx/mon_icons.asm`):
`FlyFromAnim` and `FlyToAnim` call `FlyFunction_InitGFX`, which reads `wCurPartyMon` -> the party's
species and loads THAT MON'S ICON through `FlyFunction_GetMonIcon` into the `FIELDMOVE_FLY` tile
slot ($84). The flier is then animated by the cutscene sprite-anim system, not by its map object —
which is the same reason the object carries no fly animation at all (`documentation.md`).

**What it needs, none of it built:**

- **The species on the wire.** A new `extras` field, sent for the same window the `entry` byte uses.
  One byte; a peer on an older build sends nothing and simply keeps its own sprite, as today.
- **Mon icons are not overworld sprites.** They are a different graphics family (2x2 tiles, their
  own table and bank) from the walking-sprite tiles both tiers currently draw from, so the drawn
  tier needs a second decode path and the spawned tier cannot use its usual sprite-id route at all.
- **A decision on WHAT a watcher should see**, which is the user's to make: the fly itself is a
  private cutscene, so a peer taking off is on a map you may not be on. The visible cases are the
  take-off (peer on your map, flies away) and the landing (this drop). Whether the mon icon should
  replace the ghost for both, or only the departure, is not obvious from the game.

**Sequenced after the drop lands**, deliberately: this queue already carries three unwatched fly
fixes, and adding a graphics path on top of an unsettled animation is how a session stops being
able to tell which change did what.

### The cross-town landing, measured rather than guessed (fourth attempt)

**Three live cycles had gone into guessing which placement path a landing takes; the fourth added a
trace and the answer was not a path at all.** Two lines carry it:

```
f=3659  hide t=0   ghost=false  step=-   armed=nil
f=3691  fall t=32  ghost=true   step=14  armed=true
```

**The envelope starts ~32 frames before a ghost can exist.** The drop arms at the landing, but on a
cross-town fly the map is still loading then, so no object can be spawned for about half a second:
the painted copy ran its hide and started falling while the engine tier had not begun, and the
engine's own 64-frame fall then ran on from t=32. Two tiers, two clocks, half an envelope apart —
*"the drawn ghost is just dropping down and not doing it properly, the spawned ghost is kinda just
teleporting"*. A same-town fly never showed it because nothing reloads, so the ghost is placeable on
the frame the drop arms and both clocks start together.

**Fix: arm below the area gate and only once the world has settled**, so `t=0` is the first frame
the peer is actually renderable here. One start frame for both tiers, which is what the envelope was
always supposed to guarantee.

**And the trace printed a value it had just written** — `was 20,26` for a peer standing at 20,26,
because the position update sat above it — which hid the arming condition completely. Moved below.
The rule it broke is in `CLAUDE.md` and had to be rediscovered anyway; the instrument was still
decisive on the half it got right.

### The settle gate consumed the very jump it was waiting to act on (fifth attempt)

**The trace after the fourth fix, complete — one line, and no hide or fall phase on either tier:**

```
f=3546  flagged t=nil  ghost=false  (was nil,nil area nil)
```

So the drop never armed at all, and what looked like the drawn ghost "working" was it simply
arriving cleanly. **The settle gate was correct and the line below it was not.** Arming is now
suppressed while the world rebuilds — but the last-known-position update went on running through
those same frames, so by the time the world had settled, the "previous" position WAS the landing
tile and the area matched it. The jump had been consumed by the window that existed to defer the
decision.

**Fix: freeze the peer's last-known position while it wears MAPSETUP_FLY and has not yet dropped**,
so the comparison still sees where it was before the fly whenever the decision finally runs.

**The transferable shape: a gate that DEFERS a decision must also freeze the evidence that
decision reads.** Deferring is not free if the state it depends on keeps moving underneath — the
delay window quietly converts a difference into a match, and the result is not a wrong answer but
no answer at all, which reads exactly like the feature never being reached. `pitfalls/by-lesson.md`.

### The drop is a STAND-IN, and the real landing is now specified

**Both tiers drop together as of the fifth attempt** — the user: *"they just 'dropped down' instead
of doing the fly landing animation now"*, which is the envelope working and the animation being the
wrong one. Traced the same day (`documentation.md`): the real landing swoops the **Pokémon's icon**
down from the top of the screen on a **decaying-cosine spiral**, the swing shrinking to nothing as
it settles. A vertical skyfall cannot be tuned into that.

**Kept anyway, on the user's call** — *"keep the drop for now"* — and registered as
[`BANDAGES.md`](BANDAGES.md) #3 rather than left to look finished. What retires it is the mon-icon
work already queued above, plus the cosine descent in place of the fall.

**Still unwatched and worth a look when convenient:** that a plain promotion (a ghost appearing as
you start walking) never drops, and that a door or Dig arrival never does either — the envelope is
gated on MAPSETUP_FLY, so neither should, and neither has been checked.

## 2026-08-26 — Crystal: the garbled fly sprite was TWO faults, both measured (FIXED, unwatched)

**The user, after the drop itself was working:** *"same town fly sprites still look a bit
glitchy/broken"*, then, crucially, *"'was' garbled, it goes back to the normal sprite once landing.
but it did have the garbled sprite on the last fly 'landing' animations"* — transient, not a
poisoned cache, which is what the first two theories assumed. It reproduced on the third fly of a
run with both traces on, and the two instruments named two different faults.

### Fault 1 — the pixels under the ghost are not its sprite during a fly

```
sprite-trace  sig=0906 -> 036A -> 0906   (on every fly, base never moved off 0)
```

`FlyFunction_InitGFX` loads cutscene graphics — the leaves, and the flying mon's icon — for the
duration of the sequence, so the VRAM under a resident sprite's base holds something else and goes
back afterwards. **The base is stable throughout, which is why the sprite trace had sat silent
through four flies**: it was edge-triggered on the address. Adding a 16-byte signature of the
actual pixels made it announce itself immediately. Same shape as the fishing rod (`pitfalls.md`,
"the right ADDRESS pointing at the wrong ASSET") — the second time this exact class has bitten this
adapter, and the first fix did not generalise because it was written as a fact about the rod.

**Fix:** while the local player is inside a fly window, peers are drawn from the CARTRIDGE instead
— the path that already exists for a peer wearing a sprite this map never loaded.

### Fault 2 — the group check validated one part of four

```
facing-trace  STAND facing=0 [0,1,2,3] -> [0,1,9,3] -> back, repeatedly
```

Tile **9** is left/right artwork (group 2) sitting in the bottom-left corner of a downward-facing
character. The learner's group check read `frame[1]` only, so a frame whose first tile was the
player's and whose others were not passed every test it has. Why a foreign part gets in is already
recorded (2026-08-26, the fishing session): the player does not own OAM entries 0-3
unconditionally. **Fix:** all four parts must agree on the group.

### The instrument lesson, which cost the most

**The facing trace could not see the STANDING path at all** — it sits below an `entry.stand = frame;
return`, so for its whole life it only ever reported STEPPING frames. A session spent hunting a
garbled standing pose logged **nothing**, and a silent instrument reads exactly like a quiet
system. Both branches are traced now. `pitfalls/by-lesson.md`.

### What to watch

Fly several times — it took three to show. During each landing the ghost should wear its normal
artwork, and afterwards too. A ghost that vanishes during the landing instead means the cartridge
path is refusing (that gate is ROM identity, so it is vanilla-only); wrong-looking art that
persists after landing is fault 2 still alive.

### The timer expired before the game restored the tiles — so the check is now content-driven

**Not confirmed; the user's "think it worked, not seeing any bad sprite now" was watched on the
TIMER build**, and the trace from that same build shows why it was marginal rather than fixed:

```
f=11374  -> rom 786432        the cartridge path fires
f=11587  -> vram 0 sig=036A   window expired, back on the cutscene's pixels
f=11750  -> vram 0 sig=0906   the game finally restores them
```

Measured swaps ran 175-220 frames, from a start this code cannot observe, so the 240-frame window
sat right on the boundary — a fall that landed inside those ~160 exposed frames would still garble,
and one that missed them would look perfect. **Any constant here is a guess**, and picking constants
is what several of today's fixes got wrong in a row.

**So the resident-tile check now compares the PIXELS.** The signature a base had while nothing was
borrowing VRAM is remembered (keyed by base and sprite id, so the bike and surfing re-learn rather
than reading as a permanent mismatch), and a base whose content has since changed falls through to
the cartridge. No duration to be wrong about, self-correcting the moment the game restores the
tiles, and it covers anything else that borrows sprite VRAM rather than Fly alone.

**What would confirm it:** several flies with no garbled frame at any point in the landing. What
would refute it: a ghost that vanishes during a landing (the cartridge gate is ROM identity, so
vanilla only) or one whose art is wrong in ordinary play, which would be the signature check
mis-firing on a legitimate sprite change.
