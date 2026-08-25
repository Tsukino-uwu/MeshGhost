# Unverified — the queue waiting on the user

**What this is.** `verified.md` is the append-only record of what is *confirmed*. This is its
waiting room: things the agent believes work, has self-tested as far as it can, and **the user has
not seen yet**. It exists so that work can continue while the user is away without either losing
track of what still needs checking or quietly drifting into calling it done.

**The rule it serves** (`testing.md`, `environment.md`): the agent verifies the Go client/server
with tools; **anything about a running game needs the user to watch it**. A screenshot the agent
took is not a substitute, and neither is a healthy log. *"nothing is considered done/fixed until i
actually confirm it as such."*

**How to use it.**

- The agent adds an item the moment it believes something works, with **what to look at** and
  **what correct looks like** — enough that the user can judge it without re-deriving anything.
- The user works down the list and answers each **confirm** or **decline**. Decline is a normal
  answer, not a failed handover.
- **On confirm:** move it to `verified.md` with the date, and delete it here.
- **On decline:** it goes back to being work. Note what was actually seen — that is usually the
  most valuable line in the whole file.
- Nothing here is cited as established anywhere else while it sits here.

**Emerald's many open sections here do NOT contradict its "feature complete" call.** Noted
2026-08-25, because the two files never mentioned each other and the pairing reads as a
contradiction on arrival. `verified.md` records Emerald FEATURE COMPLETE as of 2026-08-21, on the
user's own call about *animation and effect parity* — the features are done. What is still listed
below is the other kind of item: details never watched, edges never reached, and measurements
taken but never judged on screen. `status.md` is the arbiter of what that means for scheduling —
a new Emerald item needs a reason it is not polish, and a real fault is a defect against a
finished adapter. **Do not read a Pending Emerald entry here as a missing feature.**

Several entries below were also closed by later work and never restatused; those now say so in
place. An entry with no CLOSED line has not been checked against `verified.md` since 2026-08-25.

---

## Pending — Emerald: what 2026-08-20 left unwatched (2026-08-20)

Everything else from that session is user-confirmed and in `verified.md`. These are the leftovers,
each with what to look at and what correct looks like.

(The landing-dust and real-shadow-sprite items that stood here are **CLOSED and user-confirmed**,
2026-08-21 -- both, on all three tiers, plus the side hop. `verified.md`. The reset that had the
shadow sprite disabled was a NULL sprite callback, not the tile allocation this file recorded as
the likely fault; that guess is written up in `pitfalls.md` as its own lesson.)

- [ ] **A ghost cannot abandon a step it has started.** The general form of the corner snapping:
      when the muddy slope reverses a peer mid-tile the ghost finishes its current tile first.
      Measured, not yet judged on screen -- it may read as nothing.

## CLOSED — Emerald: the Acro Bike's wheelie poses are not reproduced (2026-08-20)

**CLOSED 2026-08-21: the Acro Bike is FINISHED on all three tiers, user-confirmed on screen**
(`verified.md`, *"a acro bike is confirmed done now"*). Kept for the method — the watchdog and
the disproof below are the reusable part, and the entry recorded its own disproof inline without
ever changing status.

A ghost never COMPLETES the wheelie transition actions. Measured by the watchdog added to
`ghostIsIdle`, which logs what it frees: 0x69, 0x6B and 0x6D (`ACRO_POP_WHEELIE_UP/RIGHT`,
`ACRO_END_WHEELIE_FACE_UP`) each held a ghost for the full 60-frame limit, repeatedly. A blocked
ghost takes no further steps, falls behind, and is then teleported by the catch-up -- which is what
the user saw as sliding.

**They are mirrored again as of 2026-08-20**, because the reason for dropping them turned out to be
untrue -- see the disproof below. Re-enabling them brought back the older *"not following me when
im jumping and moving"* once, since the branch that issues a pose returns without stepping; a pose
is now issued only when the ghost is already at the peer's tile.

- [ ] **Why do they never finish?** **The acro-state theory is DISPROVED, 2026-08-20**: driven on
      the player, every one of these actions completes -- `0x6B` itself ran nine frames and reported
      finished (`verified.md`, `probes/wheelie_watch.lua`). The fault is a property of the ghost, so
      the next step is the ghost's own fields during the same action beside the player's, not
      another theory. A fix would restore the standing wheelie, which peers cannot see today.

## Pending — Emerald: a ghost cannot abandon a step it has started (2026-08-20)

Found while fixing the muddy slope, and it is the general form of the corner-snapping seen on the
bike square. A ghost's step is engine-driven and runs to completion, so a peer whose direction
INVERTS mid-step (the slope reversing them) leaves the ghost travelling the wrong way until the
step ends. Measured: during 514 frames of the peer sliding back, the ghost's action was mostly
`WALK_FAST` NORTH while the peer went south -- right speed, wrong way.

- [ ] **How wrong does it look?** Ride the muddy slope at less than top speed with both tiers on
      screen. *Correct:* the ghost reverses with the peer. *Known wrong:* it finishes its current
      tile first. Whether that reads as a defect or as nothing at all decides if it is worth a fix,
      and the fix is not obvious -- interrupting a held movement is what broke the ghost twice
      before (`BANDAGES.md`, the parked-hitbox experiments).

## Pending — Emerald: what the two-renderer comparison left open (2026-08-19)

`MESHGHOST_COMPARE_TIERS` found a dozen real defects in one session. **Most are already confirmed
and live in `verified.md`** — network-paced movement, the turn animation, cutscene sliding, the
single-tile walk cadence, the spawned ghost sticking after a run, both house transitions, scene
brightness, and a smooth run. These are what is left:

- [ ] **The painted ghost dims in a dark cave.** *What to look at:* any cave. *Correct:* it darkens
      like the spawned one. The fade half is confirmed (both house directions); a cave has not been
      visited yet.
- [x] **Surfing is CONFIRMED on both tiers** (2026-08-19, `verified.md`) — the spawned ghost's
      Pokemon, and the drawn ghost's reflection with its bob, ripple and per-pixel clipping. Bikes
      are the remaining half of this item.
- [ ] **Bikes, on BOTH tiers.** Fishing is now confirmed on both (`verified.md`,
      2026-08-19), and these are the same class of state: a task-driven `graphicsId` whose animation
      the engine will not run for a ghost unaided, and whose sprite offset may likewise be *derived*
      per frame rather than stored. Expect the same two questions to decide it — does the ghost
      animate at all, and does it sit still while it does. `MESHGHOST_EMERALD_ANIM_TRACE` is the
      probe for exactly this, and the shared `fishingFrameShift()` is the shape any equivalent rule
      should take. Read `pitfalls.md`'s three 2026-08-19 Emerald entries before starting.

### Closed as far as it goes, and NOT worth another attempt

- **Ghost collision cannot be removed from a MOVING spawned ghost.** The engine drives a step from
  the same coordinates the collision scan reads, so parking them frees the hitbox and breaks the
  movement -- confirmed twice on screen, once with all three coordinate pairs and once with only
  `currentCoords`. Elevation is not the mechanism either: 0, 1 and 15 all block.
  `MESHGHOST_EMERALD_NO_COLLISION` therefore frees a STANDING ghost and nothing more.

## Pending — Emerald: no ghost until you are actually in the game (2026-08-19)

The question above ("should the adapter be broadcasting from the main menu?") is **answered** — the
user, 2026-08-19: *"it should not show/send the ghost for other people if you are in the main
menu/intro. should only show when you are actually in game."* The adapter now sends nothing at all
until the player is confirmed in the overworld, and when the game goes back to the title screen it
**drops its bridge connection**, which the core turns into a real relay leave and every peer into a
despawn — rather than leaving the ghost frozen at the last position, which is what simply going
quiet would do (the core never expires a peer's newest sample on its own).

Self-tested from the adapter's own log on a real session, with the game driven by a scratch input
probe rather than by a person: cold boot to the title, the continue screen and the intro all logged
`overworld=false inGame=false` with nothing sent; the moment the save loaded into the overworld,
`in game -- now sending local state`; a soft reset logged `left the game (title screen) -- dropping
the bridge`, and the relay issued this client a new player id a second later — which is the leave
the peers would have seen. What a log cannot show is the other player's screen.

- [ ] **A peer's ghost of you disappears when you go back to the title screen.** The one item here
      that survived 2026-08-19: the other three were confirmed that day (hard reset rather than
      soft — `verified.md`), but this one is about the OTHER player's screen, and under `-loopback`
      the ghost is your own echo, so it cannot be told apart from the local render stopping.
      **Needs two clients.** *What to look at:* the ghost, while the other player resets back to
      the title. *Correct:* it vanishes within about a second. Wrong: it stands there frozen.

## Pending — Emerald: a room bigger than the map (2026-08-19)

Measured with synthetic peers, not with people: the engine's 16-entry object array is shared with
the map's own NPCs, so a town holding the player and two NPCs fits exactly **13 ghosts**; peers
past that are refused and simply never appear. Past the ceiling the adapter used to log a refusal
per unplaceable peer per frame, which cost 60fps → 3fps at 24 peers and 1fps at 36; that is fixed
(throttled message, and no further spawn attempts once the array is full for the frame) and
re-measured at 59.7-59.8fps with 24 and 36 peers offered. See `pitfalls.md` for the full story.

- [ ] **A crowded map still plays normally.** *What to look at:* full speed, and the ghosts that
      are there. *Correct:* the game runs at normal speed with a dozen ghosts around you, the ones
      that fit look and move like ghosts always have, and the map's own NPCs are all still there
      and still walking their routes. Extra peers being invisible is expected, not a fault.

## Pending — Emerald: two tiers of ghost, so nobody is missing (2026-08-19)

Phase 9.1's Emerald half. Peers now fall into two tiers: real spawned object events up to what the
map can spare (**nearest peers win**, with a 3-tile hysteresis band so ghosts do not swap tiers
while someone walks past, and a reserve so the engine always keeps a slot for a character of its
own), and everything past that painted with the older `gui.*` pixel path so that **no peer is
simply absent**. The drawn tier is behind `MESHGHOST_EMERALD_DRAWN_OVERFLOW` and is **off by
default** — see `BANDAGES.md`: a drawn ghost has no engine occlusion, and the region a text box or
the START menu occupies is not measured yet on this game, so with the flag on it would paint over
them.

Self-tested with synthetic peers on one indoor map, from the adapter's own counters: 40 peers →
13 spawned + 27 painted at a full 59.7fps; 150 peers → 13 spawned + up to 172 painted (the ones
left over are genuinely off screen) at 22-31fps; the same 150 with the tier off → 53fps, which is
what says the cost is the painting rather than the network. A screenshot shows a crowded room that
looks right, but the synthetic peers circle in tight rings and stack on each other, so it does not
show one-per-tile.

- [ ] **The spawned half did not change.** Flag off (the default), ordinary play with a few peers.
      *Correct:* exactly as before — ghosts spawned, animated by the engine, hidden behind the
      pause menu, on the grid. This is the half that has to be safe regardless of the other.
- [ ] **The map's own NPCs always win.** *What to look at:* a busy map with more peers than slots.
      *Correct:* every NPC that belongs on that map is there and behaving; ghosts fill what is
      left, never the other way round.
- [ ] **Ghosts do not swap tiers while you walk.** With the flag ON and more peers than slots.
      *What to look at:* walk past a cluster. *Correct:* ghosts do not visibly flicker between
      "engine-drawn" and "painted" as distances change; a swap should look like at most one
      ghost changing over, not a churn.
- [ ] **What a painted ghost looks like next to a spawned one.** *Correct:* the same character,
      same size, on the grid — the difference should be that a painted one does not slide as
      smoothly and is not hidden by scenery. **Expected wrong, and the reason the flag is off:**
      a painted ghost will draw on top of a text box or the START menu.

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

## Pending — peer graphics: bikes, surfing, fishing (2026-08-18)

Turned OFF by default (`MESHGHOST_GHOST_PEER_GFX`), because it is incomplete — see below.

- [ ] **A ghost can be drawn with a graphic the local player is not using.** Self-tested by
      forcing the Mach Bike graphic while the player walked: the ghost rendered as a bike rider,
      cleanly, at the correct 32-wide size.
      *What to look at:* a peer on a bike while you are on foot. *Correct:* they look like they
      are on a bike, not scrambled, not half-drawn.
- [ ] **The corruption is fixed by taking only shape/size from the graphic.** Copying the whole
      template OAM renders as scrambled pieces; skipping it renders cleanly at the wrong width.
      *Correct:* neither symptom.

**CLOSED for three of the four, 2026-08-21** — bikes, surfing and fishing are all user-confirmed
on screen (`verified.md`: the Acro Bike is FINISHED 2026-08-21, surfing and diving are DONE
2026-08-21). `MESHGHOST_GHOST_PEER_GFX` being "off by default because it is incomplete" is the
2026-08-18 state and has not been true since. Kept for the corruption diagnosis above.

## Known incomplete — do NOT confirm, these are not finished

- **CLOSED — surfing and diving are DONE on every tier, user-confirmed 2026-08-21**
  (`verified.md`, "SURFING AND DIVING ARE DONE"). The spawned tier closed 2026-08-19; the drawn
  tier's water reflection closed the same day (`verified.md`, "a drawn ghost's water reflection,
  1:1 with the engine") and its blob followed. **The text below is kept for its method, not its
  status** — it said the drawn tier had neither, and that has been false since 2026-08-19.
  - **Not yet re-checked: the "dark navy instead of blue" report from 2026-08-18.** The palette slot
    is confirmed correct (0, matching the player's own blob), so the suspect is the palette not
    being LOADED while the local player is on foot — the game loads it only when *you* surf. Every
    confirmation so far had the local player surfing too, so this is untested where it bites.
  - **Fishing on synthesised water WORKS (user-confirmed 2026-08-18)** — but only its first two
    branches are reachable there. Wild encounters are per-map data (`gWildMonHeaders`), and a
    starting town defines none, so the game jumps straight to no-bite. Moved to `verified.md`.
  - **Still untested: whether fishing spawns a companion sprite** the way surfing does. Answering
    it needs the bite/hooked branches, which means fishing on a **route that defines fishing
    encounters** — not on a tile invented in a town. Underwater likewise untested.
    **Superseded: underwater closed with diving, 2026-08-21 (`verified.md`).**
  - **`probes/watertile.lua` now makes real water**, after two wrong versions. It writes metatile
    id + **collision 0** + **elevation 1 (`ELEVATION_SURF`)**, which is what the game means by
    water — the earlier version set the collision bit, which made the tile solid and *prevented*
    fishing, while looking like success because the player was blocked by it.
    *Self-tested* by reading back what the game computes at that tile: `behaviour 21
    (OCEAN_WATER)`, collision 0, elevation 1, player at elevation 3 adjacent. **Not confirmed on
    screen, and no rod has successfully been cast on it yet.**
- **Archipelago ROMs still use the old drawn overlay.** See `adapters/bizhawk/pokemon/emerald/BANDAGES.md`
  — one live run on a patched seed either closes it or refuses safely.

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
`adapters/bizhawk/pokemon/crystal/probes/uiframe_probe.lua` scans **both** tilemaps on **every**
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


## Pending — Emerald: what a BLOCKED rider actually does (2026-08-20)

A ghost on a bike no longer performs the walker's bump (`BUMP_ACTION`, the walk-in-place slow
shuffle from `PlayerNotOnBikeCollide`) when it has nowhere to go -- it stands still instead. That
removes a visibly wrong animation (*"the spawned one actually flips the sprite in reverse for a
bit"*) but standing still is a placeholder, not a measured answer.

- [ ] **Ride into a wall on each bike and read the player's own `movementActionId`.** Whatever the
      engine gives a blocked rider is what a ghost should perform. `probes/wheelie_watch.lua` is the
      shape to copy -- drive it, log the player's object per frame. Until then a blocked ghost on a
      bike is silent where the player is not.

## Pending — Emerald: two edges the mount/dismount fixes may have (2026-08-20)

The transitions themselves are user-confirmed 1:1. These are the trades the fixes made, believed
invisible, not yet watched for deliberately:

- [ ] **A swap landing mid-step now runs the rest of that step with the new graphic paused.**
      *What to look at:* mount or change state at the exact moment the ghost is mid-stride
      (walk up to the bike and mount instantly, repeatedly). *Known worst case:* legs frozen for
      up to half a tile. If visible, the fix is releasing the pause when the step's animation is
      the one running, not another gate.
- [ ] **Fishing kept both delays on purpose** — the mid-step deferral and the sender's 6-frame
      hold — so a rod cast is now the one state that changes later than the painted copy.
      *Correct:* nobody notices, because a cast starts from a standstill. If a cast ever reads as
      laggy, the offset-pairing problem the hold solves has to be solved another way first.

## Pending — Emerald: cross-map ghosts, what still needs the user's eye (2026-08-20)

The feature is user-confirmed working (peers visible across a seam, followers crossing with the
player). These are the specific leftovers:

- [x] **The transition pop: RESOLVED and user-confirmed 2026-08-20** -- it was the CORE's
      cross-area filter, not any renderer; fixed by `render_all_areas` (ADR). In `verified.md`.
- [ ] **A seam with a real offset.** Every test so far crossed an offset=0 seam, so the offset
      SIGN in the translation has never been exercised — a peer near an offset seam (Route 0:26's
      west pair, offset 20) could be drawn 20 tiles displaced with everything else correct.
      *What to look at:* the test peer on such a seam standing on the correct column.
- [ ] **A house still clears ghosts.** By design a warp keeps the old teardown; watched only in
      passing. *Correct:* enter any door — every ghost is gone until you come out.
- [ ] **The 7-second arming window per adapter load.** Before the ROM scan completes, cross-map is
      off and crossings tear down the old way. Live it reads as "the first crossing after a load
      reloads the ghosts once"; if that ever bothers, the scan result could be cached to a file.

## Pending — Emerald: a reversal while hopping leaves the SPAWNED ghost facing the old way (2026-08-20)

**User, 2026-08-20:** *"when i was going right, the spawned ghost was still facing left, and hopping
backwards"*, and, asked which tier: *"the drawn ghost was fine, only the spawned one had this
issue"*. Same data into both tiers, one of them wrong, so the fault is in what the spawned tier
DOES with it -- the same diagnosis shape that found the travelling-action lurch earlier that day.

One instance is already in the measured log (`probes/hopwatch.lua`, 2026-08-20): across a
turnaround the ghost held `act=0x72 dir=west` for ~16 frames while the player was already
`act=0x73 dir=east`. Whether that is the whole symptom or only its edge is unmeasured.

- [ ] **Capture a real reversal.** `hopwatch.lua` now logs a facing disagreement with its LENGTH
      and any ghost tile step taken opposite to the player's direction of travel. A few frames is
      the interpolation delay; a sustained one is a defect.
- [ ] **The likely mechanism to test first, not to assume:** a ghost cannot abandon a step it has
      started (the standing open item above), so a hop issued just before the peer reverses must
      finish -- and `stepDir` comes from the tile delta, which can point backwards for a beat if
      the ghost overshot. Both are measurable from the same capture.


## Pending — Emerald: the hardware-sprite tier, what still needs the user's eye (2026-08-21)

The tier is built, measured and **confirmed as a renderer** -- *"and yes the OAM looks fine now"*,
judged in the three-way compare (`verified.md`). It ships **off** (`MESHGHOST_EMERALD_HW_OVERFLOW`)
until the list below is closed. Four things are open, and the first is the one the tier exists for.

1. ~~**OCCLUSION.**~~ **CLOSED 2026-08-21** -- *"Occlusion looked fine on OAM"*, watched with the
   loopback ghost, which follows the player and so could actually be taken somewhere. Moved to
   `verified.md`. This was the claim the tier exists for.
2. **Scene brightness.** A hardware sprite reads the live OBJ palette, so it should dim with a door
   fade, a cave and weather with nothing of ours involved. Never watched.
3. **UNPINNED position quality.** Every confirmation so far is from compare mode, where the copy is
   pinned to the spawned ghost's sprite. How the tier looks placed from the glide -- which is what a
   REAL peer gets -- has not been judged. Expect the deliberate 8-frame trailing delay to be visible
   at running speed; whether that reads as correct or as lag is a question about how it looks.
4. **Sprite-vs-sprite ordering, as an accepted artifact rather than a bug.** Entries above the
   engine's range always lose an overlap tie, so a hardware ghost passes BEHIND the player and behind
   NPCs. Predicted, recorded in the ADR, never watched. Worth one look to confirm it is as harmless
   as expected.

## Pending — Emerald: the DRAWN tier after the glide fix (2026-08-21)

**Shipped, user-confirmed code changed underneath.** `glideRemote` now measures target speed over an
8-frame window instead of frame-to-frame (`verified.md`, `pitfalls.md`). That was a real defect --
the filter could not follow a RUNNING player and snapped every ~17 frames -- and the painted tier had
been living with it since it shipped.

**So the painted tier's movement is due a re-judgement, and it was never re-watched after the
change.** The expectation is that it is strictly better, especially at running speed, and especially
on a bike. But the tier's movement has been through five separate attempts and several rounds of the
user's eye, and a change to its filter is exactly the kind that trades one artifact for another.
Watch a peer walking single tiles, running, and on the Mach Bike, against the spawned ghost.

**Downgraded but NOT closed, 2026-08-21.** The user: *"think its fine for now, haven't seen anything
weird with it this session i think ?"* -- and nothing weird was seen, which is worth having. It is
not evidence about this change, though, and the reason is structural rather than pedantic: **every
run after the glide fix was in compare mode, where the painted copy is PINNED to the spawned
ghost's sprite and never uses the glide at all.** The only runs that exercised the painted tier's
own movement -- the 56- and 150-peer crowds -- happened BEFORE the fix. So the filter that changed
has not been on screen since it changed.

This is the same shape as the bug it fixed: the pinning that makes compare mode useful is exactly
what hid the defect (`pitfalls.md`, trap 4). **To actually test it, turn compare mode OFF**
-- then the painted copy is placed from the glide like a real peer, and running speed is where any
difference lives.

## 2026-08-21 (water/warp session) — what was NOT confirmed

Everything else from that session is user-confirmed and in `verified.md`. These are not:

- **The unpinned jump arc, on either self-drawn tier.** Both tiers took a peer's hop from the
  spawned sprite they are PINNED to in compare mode; an overflow peer has none, so it slid across
  ledges with no arc and (painted) no shadow. Fixed from the peer's own `soy`, **never watched on
  screen** — and it cannot be, in compare mode, because compare mode pins. Judging it needs
  `MESHGHOST_COMPARE_TIERS = false` with `MESHGHOST_EMERALD_MAX_SPAWNED = 0`, twice: once with the
  hardware tier on, once with only the painted one.
- **Diving.** Never reached. The player was taken to Route 126 (`g0.n41`, where the Dive spots are)
  and then brought straight back at the user's request, so no dive was performed and nothing about
  an underwater peer has been seen. Underwater is a different mechanism from surfing —
  `StartUnderwaterSurfBlobBobbing` bobs the player's own sprite rather than spawning a companion —
  so none of the surf-blob work covers it.
- **The ripple trail under load.** Confirmed on screen with ONE surfer. The hardware pool holds 12
  and a steady trail is 10, so a second surfing peer overflows it and drops its oldest ripples; that
  path logs but has never been watched.
- **Everything above at frame rate.** The session added per-frame work to both self-drawn tiers —
  a blend fit, a reflection for every peer on reflective ground, and a ripple trail — and **no
  `probes/fpshold.lua` run was made afterwards.** Frame rate is a shipping requirement; this is the
  first thing the next session should measure, against a bare control.

## 2026-08-21 (dive session) — what the user has NOT confirmed

Four changes went into the Emerald adapter this session. **None of the on-screen outcomes is
confirmed** — the measurements behind them are in `verified.md`, and they are measurements of the
GAME, not of how our copies look. Judge each with compare mode on, all three tiers in a row.

- **The surf-start hop.** The ghost now performs the game's own `JUMP_SPECIAL` onto the water
  instead of gliding. Measured on the object event (`act=3A`, `pos2 y=-4`, two frames behind the
  peer); never judged by eye. Known remainder to look for: **the ghost wears the field-move pose
  during its hop while the player is already in the surfing one**, because the graphic swap trails
  the action by a frame or two. If that reads wrong, the swap has to be ordered ahead of the action.
- ~~The grey/flash, the splash vanish, and the savestate glitches~~ — **all three USER-CONFIRMED
  FIXED 2026-08-21**; the entries, causes and methods are in `verified.md` and `pitfalls.md`.
- **Savestate loads no longer break the hardware tier.** The detector is confirmed firing from the
  adapter's own log, but *"the OAM copy looks right after several state loads"* is a visual claim
  and nobody has made it yet.
- **Everything underwater.** The underwater graphic and a bobbing driver for a spawned diver are
  built and load cleanly; **nothing has been underwater yet**, so no part of it has been seen. The
  self-drawn tiers' handling of a diver — palette, no reflection, no ripple — is likewise unlooked
  at. See `documentation.md`'s underwater section for what the game does.

**Also open from this session, not diagnosed:** the user reports the DRAWN ghost *"popping in/out"*
at the start of surfing. The painted tier falls back to a walker rather than vanishing, so a real
pop-out needs a different explanation than the one that covered the other two tiers.


## 2026-08-21 (dive session, evening) — the surf transition work, and what remains unjudged

The mount and dismount of surfing were rebuilt across the whole evening, defect by user-reported
defect. **User-confirmed on screen**: the dismount (blobs park in the water, riders jump ashore
clean, nothing follows or flashes), and the mount up to *"everything else looks correct now"*.
Records in `verified.md`; methods in `pitfalls.md`.

- **"OAM missing an animation step at surf start" — reported tentatively, does not reproduce in
  the measurement.** The scripted mount's log shows the hardware tier loading pose frames
  0/0..0/4 at exactly the player's own 4-frame spacing, then the jump and the surf idle; the film
  shows every step displayed, offset by the uniform ~4-frame wire lag. Needs the user to either
  re-look or name the specific step.
- ~~The dive itself~~ — **REACHED AND USER-CONFIRMED 2026-08-21**: *"I confirm that surf & dive is
  properly done now."* `verified.md` has the entries. What remains unjudged there: a CROWD
  underwater (only the loopback ghost has been seen), and the painted tier's cost when it carries
  peers the hardware tier would otherwise have taken (the underwater exception in `FLAGS.md`).

## 2026-08-21 (ice/fog/cave session) — what the user has NOT confirmed

Ice, the fog fallback and the cave-darkness clip are all **confirmed** and live in `verified.md`.
What that session left untested:

- **The flash clip on a PATCHED ROM.** It is gated to vanilla on purpose — the scanline addresses
  are our own build's — so on an Archipelago seed the clip declines and a painted ghost still shows
  through a dark cave. Deliberate, never seen.
- **`MESHGHOST_LOOPBACK_OFFSET_X/_Y`**, added so a loader script can place the copies for a
  particular question. Used once and put back; the defaults are unchanged, so nothing shipped
  should differ — but the shipped default path has not been re-watched since the globals went in.

## Emerald: the ferry and rail movement — ASSUMED to work, never tested (2026-08-21)

**The user's own framing, closing the Emerald phase:** *"ferry, rails untested. assumed to work.
unverified. dropped from status for now."* Recorded here rather than in `status.md` because they
are not open work — nobody is going to look at them next — but the assumption must not decay into
a memory of having checked.

- **The ferry (S.S. Tidal and any other boat ride).** Nobody has ridden one with the adapter
  loaded, on any tier. The assumption is reasonable and is *why* it was dropped rather than
  scheduled: the feature-complete call of the same date covers every mechanism a boat would use —
  a `graphicsId` swap, a forced movement, a map with a different frame — and each of those is
  confirmed elsewhere. **But "the parts are confirmed" is not "the combination was seen"**, which
  is the exact shape of assumption this project has been caught by before.
- **Rail movement.** On the original Phase 8 scope list and never separately closed. Same status:
  assumed covered by the feature-complete call, never watched.
- **What would settle either**: one ride each, with compare mode on, watched by the user. Cheap —
  `probes/goto_map.lua` reaches the dock — and worth doing whenever Emerald is next opened, but
  deliberately NOT scheduled. Emerald is parked; Crystal has the attention.
- **If either turns out to be wrong**, it is a defect against a feature-complete adapter and
  belongs in `verified.md`/`pitfalls.md` as such, not as a missing feature.

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

## CONFIRMED ON SCREEN 2026-08-21/22 — Crystal's two tiers move properly

Listed here rather than in `verified.md` only because that file is the user's to append; these were
each confirmed by the user watching a loopback session on Route 39, in their own words:

- **The painted tier walks** rather than teleporting, with no wiggle and no stutter — *"perfect
  now"*. **The confirmation stands; the mechanism named here does not.** It read "player-relative
  placement with sub-tile progress from `extras.prog`", which was true when written and was
  reworked by `25277b9`/`ba10a53`: the sub-tile position now rides in `position` itself, the ghost
  walks from the destination tile rather than being placed at an offset, and progress is *derived*
  from the interpolated position so it cannot disagree with it
  (`meshghost_crystal.lua`, "THE GHOST WALKS; IT IS NOT PLACED"). `extras.prog` still exists but
  now only picks the animation frame. Corrected 2026-08-25.
- **The painted tier disappears properly across a door transition** — *"the drawn ghost is going away
  properly now when going in/out of the house"*. It was never being drawn during the crossing; the
  drawing layer was simply not cleared.
- **The spawned ghost stays visible and animates.** The inherited `SLIDING` flag was suppressing the
  walk cycle; after the fix the ghost's step frame matches the player's frame for frame.

## Pending — Crystal, after the 2026-08-21/22 session

1. **The hardware (OAM) tier has never been judged on screen.** It is built, shipped OFF, and proven
   to reach the hardware by reading entry 39 back from the `OAM` domain. Two questions only the user
   can answer: does an injected sprite draw OVER a text box (the decomp predicts it does, which is
   the opposite of what a hardware tier is usually wanted for), and does opening START remove it.
2. **`extras.act` has still never been tested** — on the wire since the start of that session. It is
   the byte that would let the engine play fishing, bumping, spinning, the "!" emote and the Fly
   landing on a spawned ghost. It rests on an unchecked assumption that `probes/action_watch.lua`
   exists to settle: that the PLAYER's own object carries those action values at all.
3. **The end-of-step lag is the loopback round trip**, 3–5 frames measured. It is a rig property, not
   an adapter defect; three attempts to hide it locally all made things worse.
4. **`playerHistory.age` is tuned by eye** (currently 2). Direction is documented in the source: too
   high and the painted ghost races, too low and it snaps backwards at tile boundaries.
5. **Emerald's logging fix is unmeasured.** The same change was made there as in Crystal, but that
   adapter has not been run since, so the frame-pacing improvement is inferred rather than measured.
6. **Emerald sits at 198 of Lua's 200 top-level locals** — two names from an adapter that silently
   does not load. Consolidation there is due before its next feature.

## CONFIRMED ON SCREEN 2026-08-22 — Crystal: the drawn tier's exit position and its facing

Listed here rather than in `verified.md` only because that file is the user's to append; both were
confirmed by the user watching a loopback session in New Bark Town, in their own words.

- **A drawn ghost no longer appears in the wrong place on the way out of a door** — *"yes this is
  fixed"*. The painted position measures the peer against the player as they were `age` frames ago;
  after a map load the ring still held the PREVIOUS map's samples, so the first painted frames
  placed the ghost against a world that was gone. The tier now WAITS until enough samples describe
  the current map. **Clearing the ring instead is what a first attempt did, and it was a
  regression**: an empty ring makes the aged lookup miss and fall through to this frame's own
  sample — a wrong reference rather than a missing one — which the user saw as the ghost wiggling
  while simply walking up. `pitfalls.md`.
- **The drawn ghost sits on its tile in all four directions** — *"absolutely perfect/static in all
  directions now"*. Right-facing drew 8px left because the learned frame measured its parts from OAM
  entry 0, which is the top-RIGHT part on a mirrored sprite. `pitfalls.md`.
- **The drawn ghost faces the right way in all four directions** — *"seems to work properly now"*,
  after six attempts. Cause and method: `pitfalls.md`, "our own ghost's OAM entries are
  indistinguishable from the player's". Verified in the log as well as on screen: four facings,
  each holding only its own view, zero invariant violations.

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

## Emerald compiles again, but has not been RUN since the fix (2026-08-22)

The adapter had crossed Lua's 200-local ceiling and failed to compile as committed — `too many
local variables (limit is 200)`, which in a real session is a silent non-load. Fixed by folding
seven top-level constants onto two tables (`surfBlob`, `gbaReg`), taking it from 202 declared names
to 197.

**What is verified**: it compiles, along with all 16 other files, via
`dev-scripts/bizhawk-syntax-check.lua`. Every one of the 28 rewritten references was read back, no
old name survives, and every use sits below its table's declaration — the "a local declared BELOW a
function is a nil global inside it" trap.

**What is NOT verified**: that it still WORKS. Compiling is not running, and this touched the surf
blob's constants — spawn, the update callback, the bob mode, the frame size and the subpriority —
which is live code on a feature the user signed off as 1:1. Emerald is parked, so nothing has been
watched since. **Before Emerald is next used for anything, load it and surf**; a wrong field name
here reads as nil and would show up as a missing or misplaced blob rather than an error.

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
