# Unverified — Pokémon Emerald's queue waiting on the user

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
no Pseudoregalia or TEVI entries by design. Sibling queues: `../crystal/UNVERIFIED.md`.

**This queue drains.** Every entry marked CLOSED or CONFIRMED was moved to `VERIFIED.md` on
2026-08-25 and deleted here — the file had been carrying confirmed items indefinitely, each
explaining that it stayed because `verified.md` was "the user's to append". A queue that does not
drain is not a queue. Confirmed items go to `VERIFIED.md` with the date; declined ones go back to
being work. An entry still here has not been confirmed.

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
- **Archipelago ROMs still use the old drawn overlay.** See `adapters/emulator/pokemon/emerald/BANDAGES.md`
  — one live run on a patched seed either closes it or refuses safely.

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

