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

### What to look at, and what correct looks like

Loopback, ghost offset to the side with interpolation at 0, so the drawn ghost can be judged
against the player frame for frame.

1. **Turn in place** — tap a direction the player is not facing, without walking. The drawn ghost
   should turn through the same intermediate direction the player does, not snap.
2. **Walk into a wall** — the 2026-08-23 case, re-checked because the code that produced it moved.
   Should look exactly as it did then.
3. **Fish** — the ghost should hold the standing pose for the direction it cast in, with a rod, for
   as long as the player's rod is out. A ghost that faces down while the player fishes to the left
   is the facing byte not being read; a body with no rod is the ROM gate refusing.
4. **Fly into a town** — during the landing the ghost should run its walk cycle at about double
   speed. It will **not** fall from the sky; that is a known gap, not a fault.
5. **Dig or Teleport** — the ghost should spin and flicker. Because the flicker alternates faster
   than the send rate, expect it to look coarser than the player's, not identical.

**Known remaining differences, stated so they are not reported as faults:** no fall for Fly,
Teleport or Dig (the sprite Y offset is not on the wire); no emote over a peer's head at all; the
spawned tier's spin runs on the engine's own clock rather than the peer's phase.

## 2026-08-25 — Crystal: the whole promotion seam, refound and fixed in three layers

**Fixed and traced clean end to end; NOT confirmed on screen.** The user, on the compare rig:
*"the idle thing is still causing some 'flicker' whenever you move afterwards"*, then after the
first fix *"no flicker, but the spawned ghost 'snaps' a bit when moving the first tile after
respawning"*, then *"still snaps... like 2-3 tiles instead of at the first tile"*. Each report was
a different layer of the same seam — the idle demotion's return trip — and both 08-23 fixes for it
had shipped unwatched. All measured with the 9x9 square drive (stop-and-go, crossing the idle
release every lap) plus the STEP_LAG handover trace, extended twice: a raw OAM window dump
(entries printed, never a match boolean — the 08-23 probe lesson), and one line per commanded
spawned-tier step with branch and deficit.

**Layer 1 — the hole.** The 08-23 one-extra-frame hold assumed the engine object reaches OAM at
handover+2; measured, it arrives at **handover+4**, every time — so the painted copy was released
two frames early and one frame drew nobody. Fix: `holdHandover()` — release only when the
object's four OAM entries actually exist at the latched paint position (+8,+16 GB offsets), capped
at 8 frames. A frame count was the wrong instrument for a question about another clock.

**Layer 2 — the discarded remainder.** The 08-23 "remainder is 0.0 at promotion" stopped being
true the same day it was written, when the model began stepping off the peer's PROGRESS: the
peer's tile change arrives as their step COMPLETES, so the model is ~10px into its tile when
promotion fires, and the object lands tile-aligned — a 10px backward snap per respawn. Fix: defer
the spawn to the model's tile boundary, detected as a TILE CROSSING (floor(model/16) changing),
not as remainder==0 — the 4px catch-up gait goes 14→18→2 and never touches 0, which is how the
first deferral rode its 24-frame cap and moved the snap 1.5 tiles downstream (the user's
"2-3 tiles in").

**Layer 3 — the real culprit under both: `cameraSettled()` gated every spawn.** During continuous
walking the camera scrolls almost every frame, so a spawn could only land in the camera's 1-2
frame boundary breath — a clock the model's boundary is a constant phase away from. That is why
spawns took ~7 attempts and why the deferral kept expiring mid-step. Fix: `liveScreenCoords()` —
anchor on the player's OWN object (struct 0 sprite coords + map pixels derived exactly as the send
path derives them), coherent on every frame including mid-scroll, so the gate is gone from
`spawnGhost` AND `teleportGhost` (whose gate was the documented freeze-then-jump during walking).

**Traced after all three, four promotions:** every landing `0.0,0.0px after 0 deferred frames`,
one spawn attempt each, paint held to the frame the OAM entries appear, step cadence resumes at
16 frames/step, deficit constant 1, in phase. Zero teleports, zero re-anchors, zero snap reports.

**The steady-state walk was measured healthy the whole time** — in-phase steps every 16-17
frames at constant one-tile deficit — so nothing was touched there; constant lag is the invisible
kind. **What to look at:** compare rig, idle the ghost past 5s, then walk long sides. **Correct
looks like** the ghost stepping off with no blink, no backward hop at any tile, and the same walk
rhythm as the player throughout. The residual known difference: the fresh object stands 1-3 extra
frames at its landing tile while the engine first draws it (the OAM hold) — a boundary-breath
sized pause, not a snap. If that still reads on screen, the next rung is spawning the object
already mid-step via the engine's own step fields, measured from the decomp first.

## 2026-08-25 — Crystal: the 1:1 double-check, the drawn stop, and two reverted attempts

**Fixed and traced clean; NOT confirmed on screen.** The user, after the promotion seam: *"no snap
anymore, drawn & spawned look identical i think?"* (hedged, so nothing above is promoted either),
*"maybe drawn stopping a bit fast whenever pausing/stopping at the end?"*, and then, asked for a
full check: *"its basically perfect now, but still not fully 1:1?"*.

**The instrument.** A three-way trace inside the adapter (STEP_LAG-gated): player, spawned ghost
and drawn model, in map pixels AND in engine-maintained sprite screen coordinates, one line per
frame anything moved. The sprite pair matters — its DIFFERENCE is camera-free, so it is the drawn
truth the field-derived map pixels get checked against.

### The stop was real, and the fix is the peer's own state

All 22 stops, identically: `2.2.2.2.2.2.2.......2.2.2` — the drawn model froze mid-step for 7
frames, then finished its last 6px. Cause: the 8-still-camera-frames guard (which exists so the
camera's 1-2 frame boundary breath cannot trigger a free step mid-walk) was also holding the
REMAINDER OF A COMMITTED STEP hostage. A committed 16px is owed whatever the clock says.

**First fix was a tuned constant** (3 frames instead of 8) and it improved the number without
answering the question. **The shipped fix asks the peer**: a committed step whose peer has already
stopped walking (`o.walking`, straight off the wire) finishes on the model's own beat with no
camera consent; new steps still wait 8. Mid-walk is untouched, because there the peer IS still
walking. Re-measured: `2.2.2.2.2.2.2.2.2.2.2.2.2` at every stop — the player's own shape, no gap
at all — and stop lag +15 → +9 frames. This file has now made the same correction three times
(K's `stable` guard, camera-as-clock, this): when the invariant itself is on hand, a proxy is what
leaves a residue.

### What the raw frames say about 1:1, and what the aggregates got wrong

```
f=652  P=118  S=160  M=76     <- player and SPAWNED ghost advance together
f=653  P=118  S=160  M=78     <- drawn model advances, one frame later
f=654  P=120  S=162  M=78
```

- **The spawned ghost is exactly 1:1 with the player** — same frames, constant separation, no slip.
  The engine moves both, so it inherits the player's timing for free.
- **A "1-frame parity slip" reported here earlier was an artefact of my own aggregate** (a
  per-frame delta histogram over a series containing starts and stops). It did not survive
  printing the frames. **A camera-tick gate added to the spawned tier to chase it has been
  reverted**; the tier was already correct.
- **The drawn model runs a metronomic 2-frame beat where the engine's is irregular** (player: gaps
  2, 1, 2, 2; model: 2, 2, 2, 2). It is smoother than the game — the defect
  `adapters/CLAUDE.md` names in its own words. This is the last measured difference, and it is a
  CONSTANT one-frame phase, which is the invisible kind.

### Two attempts at that beat, both reverted — kept because each is the obvious next idea

1. **OR the player's sprite movement into the model's trigger.** By construction that can only make
   it fire earlier, so the trace came back byte-identical — which is what proved the idea had not
   actually been tested rather than that it was wrong.
2. **Replace the camera beat with the player's sprite beat while the local player walks.** The
   model's beat did not change AND the paint began wobbling (`25 → 23 → 25`), because the painted
   position IS the camera formula: moving the model on frames the camera did not move puts the
   disagreement straight on screen.

**So the model's beat and the paint's origin are one decision, not two, and the camera owns both.**
Matching the engine's irregular rhythm means moving the paint off the camera formula first — a
real change, not a trigger tweak, and not one to start while the current state is unwatched. The
reverted build was re-measured and reproduces the good state exactly (paint constant, stops clean,
spawned in lockstep).

**What to look at:** walk long sides and stop; watch the drawn ghost's finish, and the two ghosts
against each other. **Correct looks like** the drawn ghost walking through to its stop with no
freeze before the last half-step. **Known remaining differences:** the drawn ghost's constant
one-frame phase and metronomic beat (above), and a fresh object's 1-3 frame stand at its landing
tile after a promotion (the engine's own draw delay).

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

## 2026-08-25 — Crystal: the loopback ghost now stands 2 tiles to the side, like Emerald's

**The user asked for this after watching both games back to back**, in the smoke test that confirmed
all four adapters (`../../../../agent_docs/verified.md`): *"i would prefer the ghost offset to the
right similar to emerald instead of 0offset/trailing me."* Crystal ran at shipped settings, so its
ghost sat on the player's own tile a quarter second behind — which hides the thing being judged
behind the character doing it, the same finding Emerald already had on 2026-08-14.

**What changed.** `LOOPBACK_OFFSET_X` defaults to `2` instead of `0`, and honours
`MESHGHOST_LOOPBACK_TRAIL` (set to anything) to force `0` for the exact-trail mode — the same
env-var name and meaning Emerald's `LOOPBACK_GHOST_OFFSET_TILES_X` uses, so one variable now
switches either game between the two ways of looking at a loopback ghost.

**The gate is the part worth checking.** Crystal applied that offset to *every* peer, which is why
0 was the only safe default: a nonzero value would have moved a real peer off their own position in
a two-machine session. It is now applied only where `id` ends in `-ghost`, at its single use site,
matching what Emerald has always done in `syncGhost`. So the new default is safe for a real session
in a way the old code could not have been.

**What to look at:** start Crystal on the loopback rig and walk around. **Correct looks like** one
ghost two tiles to your right, mirroring your steps and facing — not on top of you, and not
doubled. If `MESHGHOST_COMPARE_TIERS` is on you should still get exactly two copies (drawn left at
-2, spawned right at +2), not three and not a stack.

**Self-tested only as far as `luac -p`.** It parses, and it is a two-line change in a file that
loaded and connected in a real session minutes earlier. It has **not** been seen running: the
hot-swap through the dev loader did not take, because the loader polls on a frame tick and the
emulator was paused at the time. First Crystal launch settles it.

## 2026-08-25 — Crystal: the surf report, drained; the BIKE from the same session is not

**The surf half is CONFIRMED and has moved to [`VERIFIED.md`](VERIFIED.md)** — "the drawn ghost
surfs". The cause was the drawn tier's decoded-tile cache never being invalidated, the method and
the two theories it refuted are in `pitfalls.md`, and none of it needs to sit in the queue.

**The bike half is open, and is NOT the same fault.** The user, immediately after confirming the
surf, on the same rig: *"the bike was still weird, the ghost moving at really different speeds from
each other"* — the two tiers disagreeing with each other about a biking peer's SPEED, having just
been made to agree about its graphics. Earlier in the same session, before the bike existed in the
bag: *"spawned ghost was walking fast/weird after getting out of surf"*. **Treat those two as one
report until something separates them** — both are a spawned ghost's pace going wrong right after a
gait change, and the second was seen without a bike involved at all.

**The leading theory, untested:** the engine drives a spawned ghost's step, and it steps a normal
object at the walking gait; the drawn tier carries its own 4px-per-beat bike stride beside the 2px
walk (`meshghost_crystal.lua`, the MODEL walk notes). A biking peer would then be paced correctly
by the painted copy and at walking speed by the spawned one — which is "really different speeds
from each other" exactly. **Nothing has measured this**, and CLAUDE.md's rule about a rate change
being an excuse rather than a fix applies with full force here: the question is what the ghost's
gait is DERIVED from, not what constant would make it look closer.

**What to run first:** the bike is now in the bag (`probes/grant_items.lua`), so the rig can reach
it in seconds. Compare rig, interp 0, ride in a straight line and read the adapter's own
`RHYTHM`/`MODEL walk` lines — they already report frames-between-moves for the player and the ghost
separately, which is the measurement, and no new instrument is needed to take it.

## 2026-08-25 — Crystal: the bike, measured on a vertical lap; the pace fixed, a residue named

**The spawned tier's bike pace is FIXED and looks right by the numbers; the user has not yet
confirmed it as done.** The drawn tier is gait-aware now too, and what remains on it is measured,
bounded, and deliberately NOT chased tonight.

### What was wrong, and what the wire carries now

The engine's own `StepVectors` table has three gaits -- slow 1px/16 ticks, normal 2px/8, fast
4px/4 -- indexed by `OBJECT_WALKING & $0F`. Measured on the running game while biking: the
player's own byte holds 08/09, the FAST group. The adapter hard-coded the normal group into
`stepGhost` (`4 + dir`, duration 8), so a biking peer's spawned ghost walked at half pace and the
catch-up path snapped it forward -- the user: *"the spawned ghost is really slow, and sometimes
teleports to keep up"*.

`extras.gait` now carries the group (one byte, changes only on mount/dismount, remembered across
the standing frames between steps so it is present the frame a peer starts moving). `stepGhost`
writes that group's own row -- group and duration, the engine's two numbers, nothing tuned. A
gait the receiver does not recognise falls back to a walk. The drawn model's two stride bounds
(camera-frame clamp, camera-parked fallback) read the same byte instead of hard-coding 4 and 2.

### The before/after, same rig

| | before (bike, mixed riding) | after (vertical 3-tile bike lap) |
|---|---|---|
| catch-up frames | 540 | **0** |
| resyncs / beat corr. | 0 / 21 | 0 / ~1.3 per reversal |
| wire moves >=9px (snaps) | 135 | **0** (all 4px/8px) |
| ghost rhythm vs player | drifting | 2:275 vs 2:266, matched |
| K drift per park | 4.6px avg, worst 10px | 2.9px avg, **worst 3px, every park** |

### The residue, measured and NOT fixed

Mid-run the paint is exact -- zero KJUMP events between boundary clusters. Everything visible
sits at a REVERSAL: a `+4/+5` pair while the camera breathes (the ghost legitimately finishing
its step late; the +1 is a K nudge landing in the same frame), then up to `-8` in the single
frame where the camera resumes and the model commits its next step together. At parks: 2-3px
off-tile in the direction of travel, repaid at 1px/frame -- which is what the user reports as
*"drift from their current tile when moving/turning on the bike"*.

**Why it was not chased tonight:** the K-nudge block carries two rules already tried against the
user's eyes and REVERTED (a deadband; waiting for arrival) -- both are the obvious next ideas
here too. The file's own conclusion stands: the cause is upstream, in the ~one-engine-tick
disagreement between the camera accumulator and the tile+progress formula, which the bike scales
from ~2px to ~3-4px per run. "K target moved on exactly 2 parked frames per park" (the handover
frames) is the standing measurement of it. The next work is on that disagreement, not on a third
repayment rule.

### The residue was then fixed the same evening, and the fix is instrument-verified

The user asked for the residue fixed rather than parked. The KPARK decomposition (one line per
park: dd plus the run's target/model/camA deltas) came back `dd=0,-3` with ALL THREE run deltas
zero -- nothing bleeds during a run; the -3 appears at the stop itself. KSETTLE (dd sampled at
stillness 8..64) pinned it: `still=8 -> -3, still=16 -> 0`, every park -- **a settling transient
of at most 8 frames in the player-side reference**, plateau-shaped, so it passed the two-frame
equality guard and the K nudge chased it down and back at every stop. That chase (24px repaid
against 12px "drift", ~2 nudge reversals per park) WAS the on-screen 3px slide-and-return.

Fix, all three from the measurement rather than a theory: the nudge now requires the target
stable for 8 consecutive frames (outlasting the transient); the per-park drift sample moved from
stillness 8 to 16 (at 8 it was measuring the transient and calling it the walk's bleed); KSETTLE
stays as a regression sentinel, silent unless a park opens with a nonzero disagreement.

**Verified by instrument over 12 parks: K drift 0px, worst 0px, 0 nudge frames, 0 reversals** --
against 3px at every park before. NOT yet confirmed by the user on screen.

### What to watch, when the user next rides

Up/down on the bike, compare rig: mid-run both ghosts hold formation exactly, and a stop should
now be completely still -- no slide, no return. What REMAINS at each reversal is the drawn copy
visibly finishing its last step a beat after the player turns -- that is the echo's real lag
rendered at the engine's own pace, the spawned copy does the same thing, and it is not the drift.
If a stop still slides, KSETTLE will have spoken in the log -- read it before theorising.

## 2026-08-25 — Crystal: the spawned ghost's boundary handoff removed by chaining steps engine-style

**Built, instrument-verified, NOT confirmed on screen.** The user, with both tiers side by side on
the bike: *"still looks like the spawned one is lagging after the drawn ghost a bit, make sure
both ghosts are identical to the player."*

**Measured first, and the measurement killed the obvious theory:** `STEP_TRIGGER_PROG=4` was
holding NOTHING (`0 frames held`, every report). The spawned ghost's seen lag decomposed as wire 2
frames (the loopback echo) + apply 1-2 (arrivals blocked while the ghost finished its previous
step, issued only after it was SEEN standing) + the engine acting the frame after our write. Seen
lag ~4-5 frames, ~8-10px at bike speed. The drawn twin paces off the live camera in loopback and
sits at ~0, which is why the difference is visible there and nowhere else.

**The fix is the engine's own chaining.** `GetStepVector` re-reads `OBJECT_WALKING` every tick and
`StepFunction_NPCWalk` ends a step purely on the duration reaching zero — so on a step's last
tick, when the peer is exactly one tile further in the same direction at the same gait, the
duration is topped back up and the map coords moved on, and the engine never sees a boundary
(the same mechanism as its own `STEP_TYPE_CONTINUE_WALK`). Two details that were each half the
work: the ending step is still OWED its final tick, so the chained duration is a full step **+1**
(without it every chained step landed one stride short — 47 re-anchor corrections in one lap,
±4px, sign following travel); and the landing's `CopyCoordsTileToLastCoordsTile` is written by
hand, or collision keeps the tile before last occupied.

**Verified over bike laps: total step lag mean 2.0-2.4 frames (was 3-4.6), apply ~0.2 (was
0.9-1.5), blocked frames ~1 per lap (was 10-17), re-anchor corrections 0, K drift still 0px.**

**The floor, stated so it is not chased:** ~3 seen frames = 2 of loopback echo + 1 of
engine-acts-after-write. Nothing closes those without predicting the peer. A real network peer
carries more wire than that on both tiers equally; the drawn twin's ~0 is a loopback artefact of
its camera clock, not a standard the spawned tier can meet.

**What to watch:** bike and walk, both ghosts. The spawned one should now hold a constant ~3-frame
trail (~6px on the bike) with no per-step hesitation and no snap at stops. If a stop shows a snap,
the re-anchor line in the log names the size and direction — read it before theorising.

## 2026-08-25 — Crystal: the "2nd ghost" after a respawn was the handover hold never matching a moving body

**Fixed, NOT confirmed on screen.** The user, on the compare rig: *"the spawned ghost is getting a
2nd ghost when moving again now (after the despawn)"*. Ruled out first, by instrument:
`orphan_probe.lua` found exactly one object carrying our fingerprint, being driven — no orphaned
engine object. The handover trace then showed the real mechanism: after a promotion the drawn tier
deliberately keeps painting until the spawned body reaches OAM (`holdHandover`, the anti-blink
from the promotion-seam fix), and its OAM check matched EXACT coordinates. A peer promoted while
MOVING — every bike promotion — has its body stepping away from the latch from its first engine
tick, so the match never hit and the hold ran its full 8 frames every time: the painted copy and
the moving body visibly apart, at every re-promotion. Invisible at walking pace, half a tile at
bike pace. The match is now within one fast-gait stride (±8px per axis) — "the body has arrived",
not "the body is exactly where it was latched".

**Open risk, stated:** in a crowd, another sprite within 8px of the latch could end the hold a
frame early — a 1-frame blink, the original fault, in a rarer shape. Not observed; noted so a
blink report in a crowd finds this paragraph.

Also this session: heavy diagnostics all switched off (sprite trace, step lag, orphan probe,
facing trace) after the user reported the game *"laggy when the scripts are running"* — and the
remaining *"slightly off from each other when reversing/turning"* on the bike is to be re-judged
on the lighter stack before any further work, because probe-induced frame drops desync the two
tiers differently and can BE that symptom.

## 2026-08-25 — Crystal: the two tiers' bike speed difference was the catch-up band cycling hot

**Fixed, instrument-verified, NOT confirmed on screen.** On the light probe stack (so not the lag
artefact) the user still saw *"both ghosts moving at different speeds on the bike"*. The RHYTHM
line cleared the spawned tier (matched to the player, 2:513 vs 2:474); the MODEL line convicted
the drawn one: **412 catch-up frames** in one short session, KJUMP showing `cu=true` continuously
with dist oscillating ±12px.

The catch-up band (arm at 12px over two boundaries, disarm under 6) and the commit cushions (6px
walking, 2px chaining) were all measured at the WALK and written as pixels. The hover they were
sized against — echo plus cushion, per-frame terms — scales with the gait, so on the bike the
ordinary hover reached the arming line and catch-up cycled: arm, repay on frames the camera did
not move (the drawn ghost visibly faster than the player), disarm, rebuild, re-arm. Stated in
STRIDES (6/3 arming, 3/1 cushions — exactly what 12/6/6/2px are at the walk's 2px) the same
tuning holds at every gait. Verified over a bike lap: catch-up frames 412 -> 0, `cu=true` events
continuous -> 0, K drift still 0px, no resyncs.

**What remains at a reversal, measured:** ~10 relative-movement frames per lap side, the 2-3 frame
echo rendered as the drawn copy starting its new direction late. Same class as the spawned tier's
3-frame floor; not a speed difference.

## 2026-08-25 — Crystal: the 1:1 audit, both tiers, both gaits — agent-measured, awaiting eyes

**The user asked for a double-check that both ghosts are 1:1 to the player, on and off the bike.**
Driven with `square_drive` (full 3-tile square, all four directions, corners included), compare
rig, interp 0, light probe stack. Agent-measured throughout — nothing here is user-confirmed.

**Spawned tier — clean at both gaits.**
- Bike: rhythm 2:610 vs player 2:505 with corner pauses matching (8:31 vs 8:29); walk: 2:465 vs
  2:450, 8:15 vs 8:14. Zero re-anchor corrections at either gait, zero resyncs, zero runaways.
- Constant ~3-frame trail (2 loopback echo + 1 engine-acts-after-write), no per-step variation.

**Drawn tier — clean mid-leg at both gaits; corners show the echo, and only the echo.**
- Mid-leg: zero relative movement against the player, both gaits. Catch-up frames 24 (bike,
  brief) / 0 (walk); K drift 0px over 15 walk parks and 0.0-0.9px avg over 16 bike parks; no
  resyncs, no snaps, corrector silent.
- At corners: ~5-7 single-stride relative moves per corner, decoded from KJUMP as (a) diagonal
  2+2 frames -- the model finishing the old leg's committed step while the camera begins the new
  leg -- and (b) the model completing its owed pixels during the corner breath. That is the 2-3
  frame echo rendered as motion: a real player walking the same square 3 frames behind would
  paint exactly this. The |dx|+|dy| histogram bins these diagonals as "4px", which is why the
  horizontal rows look double-stride at walk; no single-axis double-stride move exists in the
  event trace.
- One wrinkle, watched and left alone: two bike parks on the right leg opened up to 4px off and
  settled within 8 frames unaided; the stability gate correctly declined to chase them.

**The claim this audit supports:** both tiers are 1:1 with the player up to a constant ~3-frame
loopback delay -- same speed, same rhythm, same quantum, no accumulation, at both gaits. The
delay itself is the rig's echo, is smaller than any real peer's, and shows only at corners and
reversals as a beat of trailing motion, identically in kind on both tiers.

## 2026-08-25 — Crystal: the drawn ghost pedalled at double speed, and the walk cycle was never prog's to derive

**Fixed, NOT confirmed on screen.** The user, after the 1:1 position audit came back clean:
*"the drawn ghost is doing the 'biking' animation way faster."* The decomp settles it in ten
lines: `SetFacingStepAction` advances `OBJECT_STEP_FRAME` once per action tick and takes the
stride from bits 2-3 — a FIXED clock, one stride per 8 video frames, the same speed at every
gait — and `data/sprites/facings.asm` binds strides 0/2 to the STANDING view, 1 to the stepping
view, 3 to its mirror. So the engine's walk cycle is a function of TIME, not of step progress.

The drawn tier derived its stand/step alternation from `extras.prog` — a partition measured EXACT
at the walk on 2026-08-22, because at 16 frames a tile the fixed clock and prog happen to align.
At 8 frames a tile they do not: prog laps the clock and the ghost pedalled per-tile — exactly 2x.

Fix: ordinary walking now reads the pose off the peer's `face` byte — stride = face & 3, stepping
view on the odd strides — the same rule the bump/spin/fish branches already used, and the byte IS
the peer's own step-frame clock, engine-paced at every gait. The prog band inside the frame
picker is gone; both rendering tiers take the same pose. At the walk the two rules agree by
construction, so nothing the user confirmed there should look different. Position numbers after
the change, one bike lap: 0 resyncs, 0 catch-up, K drift 0 — the motion work is untouched.

**What to watch:** ride beside the spawned ghost — both should pedal at the player's own cadence
(one pedal alternation per tile on the bike, NOT two). Walk a few tiles too: the walking
animation should look exactly as it did before this change.

## 2026-08-25 — Crystal: the 9x9 square, both gaits, after the day's five fixes — agent-measured

**The user asked for the 9x9 test** — the long-side square that historically exposed what short
walks hide (*"moving 1 tile looks good/perfect... 4-5+ tiles and it starts to look really
jittery"*, 2026-08-23). Driven from savestate slot 9, compare rig, light stack; both gaits.

**Walk, 8 laps (~36 nine-tile sides):** K drift 0.0px worst 0 in ALL four directions over 35
parks; 0 resyncs, 0 catch-up frames, 0 re-anchor corrections, 0 runaways; ghost rhythm 2:2121
against the player's 2:1969. Relative movement 2-4% of frames per direction, every event
single-stride and corner-localised — **no growth over the long sides**, which is the specific
failure this test exists to catch.

**Bike, ~6 laps:** the same shape — K drift 0.0px worst 0 in all four directions over 23 parks;
0 resyncs, 0 catch-up, catch-up never armed, 0 re-anchors; relative movement 2-4%, single-stride, corners only, one lone 8px frame in ~1300.

Nothing user-confirmed here; what this closes is the INSTRUMENT side of the 9x9 question at both
gaits, on the build carrying today's five fixes (tile-cache invalidation, gait on the wire, the
stop-transient guard, step chaining, the stride-scaled band, the face-byte walk cycle).

## 2026-08-25 — Crystal: quick reversals cut the corner, and the spawned ghost now walks the PATH

**Fixed, NOT confirmed on screen.** The user, on a bike up/down drill: the spawned ghost
*"trailing after... like reversing instead of hitting the walls/stopping. mid movement reverse"*
— and then gave the repro themselves: 3-5 tiles, flip, repeat, short of any wall.

**What it was.** The spawned tier stepped toward the peer's LATEST tile. Trailing by the echo,
every quick reversal truncated: by the time the ghost closed the distance, the target was already
back past the tile the peer turned on — so the ghost reversed 1-2 tiles short, in open ground,
and the turn tile was never visited. The chain-overshoot counter proved the shape before the fix:
faithful retraces of the turn tile logged at ONE end of the drill only — the other end was being
cut. (The first theory — the step chain overshooting past the turn — was wrong and the instrument
killed it: a chain's target is always a tile the peer actually stood on.)

**The fix:** each new peer tile is queued (`facingFrames.pathGoal`, capped at 3 — beyond that is
the catch-up/teleport regime, which sees the live target exactly as before), and the ghost walks
the queue in order, reaching every tile the peer stood on — the turn tile included — before
following it back. A teleport clears the queue. The chain also gained a continuation guard in the
same session: it commits from an arrival that must still say walking-in-that-direction, so the
stale beat around a reversal falls to the ordinary landing path.

**Measured on the drill (3-tile flips, ~50 reversals):** rhythm still matched (2:430 vs the
player's 2:424), 0 re-anchors, 0 runaways, 0 resyncs, spawned-side clean. Hit Lua's 200-local
ceiling adding the helper and moved it onto `facingFrames`, per this file's own convention.

**What to watch:** the user's own drill — a few tiles up/down on the bike, flipping mid-motion.
The spawned ghost should ride THROUGH to the tile the player turned on and reverse there, trailing
by its constant beat — never turning early in open ground.
