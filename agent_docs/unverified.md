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

---

## Pending — Emerald: what 2026-08-20 left unwatched (2026-08-20)

Everything else from that session is user-confirmed and in `verified.md`. These are the leftovers,
each with what to look at and what correct looks like.

- [ ] **Landing dust, both tiers.** Painted from `gFieldEffectObjectTemplate_GroundImpactDust`
      (0850CCA0): frames 0,1,2 at eight game-frames each, drawn on the tile a jump lands on.
      *What to look at:* hop on a bike. *Correct:* a small puff under the ghost as it lands, gone
      within half a second, on BOTH ghosts. It is painted over our own shadow deliberately -- the
      engine's dust for the spawned ghost is hidden behind that shadow and cannot be raised while
      the shadow sprite below is disabled.
- [ ] **A REAL shadow sprite for a spawned ghost -- WRITTEN AND DISABLED, do not simply re-enable.**
      `genderFrames.shadowSpriteEnabled` is false because turning it on RESET THE GAME on every
      jump. The likely fault is the tile allocation: the frame's byte count is read from the
      template's `SpriteFrameImage` and, if wrong, the copy writes past the range it owns and over
      OBJ VRAM. Before switching it on again, LOG the byte count and tile range and prove they are
      sane -- writing first is what cost the user a reset. Working, it would put the shadow under
      the character (subpriority 148, as the engine does), stop it covering the dust, and let the
      painted-shadow bandage come out of `BANDAGES.md`.
- [ ] **A ghost cannot abandon a step it has started.** The general form of the corner snapping:
      when the muddy slope reverses a peer mid-tile the ghost finishes its current tile first.
      Measured, not yet judged on screen -- it may read as nothing.

## Pending — Emerald: the Acro Bike's wheelie poses are not reproduced (2026-08-20)

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

## Known incomplete — do NOT confirm, these are not finished

- **Surfing: the SPAWNED tier is done and user-confirmed** (2026-08-19, `verified.md`) — the
  blob's missing `centerToCornerVec` was the unexplained "half a tile down-right", and it was never
  created at all when a peer walked into water. The DRAWN tier still has neither the blob nor a
  water reflection; that is the open half, below.
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
what hid the defect for days (`pitfalls.md`, trap 4). **To actually test it, turn compare mode OFF**
-- then the painted copy is placed from the glide like a real peer, and running speed is where any
difference lives.
