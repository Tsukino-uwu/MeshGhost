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
no Pseudoregalia or TEVI entries by design — both of those gained their own queue on 2026-08-27.
Sibling queues: `../crystal/UNVERIFIED.md`, `../../../tevi/UNVERIFIED.md`,
`../../../pseudoregalia/UNVERIFIED.md`.

**This queue drains.** Every entry marked CLOSED or CONFIRMED was moved to `VERIFIED.md` on
2026-08-25 and deleted here — the file had been carrying confirmed items indefinitely, each
explaining that it stayed because `verified.md` was "the user's to append". A queue that does not
drain is not a queue. Confirmed items go to `VERIFIED.md` with the date; declined ones go back to
being work. An entry still here has not been confirmed.

---

## This run — watch these first

**The READY entries below, newest first, at most ten.** Each says what to look at and what correct looks
like; answer each with a plain yes or no at the end of the run. Every entry in this file carries
**READY** (built, waits for your eyes), **OPEN** (not fixed, parked as work) or **DONE** (kept for its
mechanism; nothing to confirm) — the rule is [`../../../_template/UNVERIFIED.md`](../../../_template/UNVERIFIED.md), and `dev-scripts/preflight.ps1` fails an
entry without one.

- READY — `"autostart": false` in config.json now stops the mod starting a client (the old MESHGHOST_NO_AUTOSTART still counts), built and deployed 2026-09-03, unwatched
- MEASURED 2026-09-02 (logs) — two instances 1s and 3s apart both found their own core (7778, then busy -> 7779); the forgotten-child path itself is not reachable by launch timing here
- DONE 2026-09-02 — the interp ladder on a 100-200ms lossy link, judged by the user: same shape as Crystal's, the shipped 250ms stands
- WATCHED 2026-09-02 — the ladder spawned -> OAM -> drawn is the shipped default now, and the three tile leaks it exposed are fixed; what the user saw, what is left
- WATCHED 2026-09-02 — `extras.gender` accepts only `male`/`female` (adversarial review): a female save drew May on all three tiers
- MEASURED: the config's bridge port, the relay-down backoff, and a config file nobody was reading (2026-08-28)
- Emerald: the boat and Fly are BUILT and UNWATCHED; rails are still only assumed (2026-08-26)
- Emerald compiles again, but has not been RUN since the fix (2026-08-22)
- 2026-08-21 (ice/fog/cave session) — what the user has NOT confirmed
- 2026-08-21 (dive session, evening) — the surf transition work, and what remains unjudged
- 2026-08-21 (dive session) — what the user has NOT confirmed
- 2026-08-21 (water/warp session) — what was NOT confirmed
- Pending — Emerald: the DRAWN tier after the glide fix (2026-08-21)
- Pending — Emerald: the hardware-sprite tier, what still needs the user's eye (2026-08-21)

## [READY] `"autostart"` in config.json replaces the environment variable as the way to say "don't start a client" (2026-09-03), unwatched

The user's call: *"even me that is somewhat tech savvy, has no clue what 'an environment variable' means."*
The launcher reads `"autostart"` out of the same config.json the client will read (own folder first, the
same search order as everything else it resolves), by a hand scan for `"autostart": false`; absent or
anything else means start. `MESHGHOST_NO_AUTOSTART` still counts as a no. `AUTOSTART` is now the variable check AND an inline scan of `config.json` in the script's folder, then the release root, then a source checkout's root (an IIFE: no local to spare). **What to watch:**
with `false` in the file, the game comes up with no client started and the log line naming the reason;
with `true` (the shipped value) the client starts exactly as before. Root and per-game READMEs rewritten
around the key ("Turning autostart off").

## [READY] the launcher forgets a child the port walk has moved off — mirrored from TEVI 2026-09-02, unwatched

**Tried the same night (agent, from `logs/meshghost_emerald_*.log`):** two vanilla instances launched 3s
apart and then 1s apart, no `MESHGHOST_BRIDGE_PORT` set. Both times the second found 7778 `busy`, skipped it
and spawned its own core on 7779 -- the normal walk, twice. The cross-wire that hit TEVI and Pseudoregalia
needs the second adapter to reach the first's freshly spawned core before the first does, and this
adapter sweeps the whole range before spawning while EmuHawk boots 5-7s apart even when launched a
second apart, so that window does not open by launch timing. The fix stays in as insurance (a hand-run
core or a slower machine could open it); nothing about it is watched beyond the normal walk.

**Mirrored from TEVI, 2026-09-02, unwatched here.** "My child process is alive" was read as "I have a
core": two copies launched a few seconds apart can each spawn on the base port, one core wins the
bind, the OTHER copy's adapter can reach it first, and the spawner is answered `busy` on its own
child's port and walks on while its launcher never spawns again. Watched on TEVI, reproduced on purpose
there and recovered (`adapters/tevi/UNVERIFIED.md`, "the port walk's dead end"). The fix here is the same
shape: `meshghost_emerald.lua`'s `startCore` keeps the spawn port inside `coreSpawnFrame` (now a table, because this file is one local from Lua's ceiling) and forgets `coreChild` when the cursor has moved off it. **What to watch:** two instances launched a few seconds apart both reach a ghost, with
nobody killing a core; the log line in the copy that lost the race is `the core this script started on port P is serving another instance`.


**REVISED the same night, after Emerald showed the first version's flaw (2026-09-02, ~23:00).** Forgetting the
child whenever the walk moved off its port was too eager: two instances whose cores were restarted
together each spawned on the base port, each adapter's sweep attached to the OTHER's fresh core first,
each then took `busy` on its own child, forgot it, spawned again -- three cores for two games, and the
emulator at 3fps under the connect storm (Emerald's sweep ran every frame, eight blocking 50ms connects
each). The rule is now two-part in all four launchers: **a spawner waits on its own child's port and never
sweeps past it while that child lives; the child is forgotten only when its port answers "busy"**, never
on silence. Emerald's sweep also runs every 30 frames instead of every frame. Built and deployed (TEVI,
Pseudoregalia DLLs; both Lua files); unwatched beyond one Emerald reload that reattached cleanly.

## [READY] Pending — Emerald: what 2026-08-20 left unwatched (2026-08-20)

Everything else from that session is user-confirmed and in `verified.md`. These are the leftovers,
each with what to look at and what correct looks like.

(The landing-dust and real-shadow-sprite items that stood here are **CLOSED and user-confirmed**,
2026-08-21 -- both, on all three tiers, plus the side hop. `verified.md`. The reset that had the
shadow sprite disabled was a NULL sprite callback, not the tile allocation this file recorded as
the likely fault; that guess is written up in `pitfalls.md` as its own lesson.)

- [ ] **A ghost cannot abandon a step it has started.** The general form of the corner snapping:
      when the muddy slope reverses a peer mid-tile the ghost finishes its current tile first.
      Measured, not yet judged on screen -- it may read as nothing.

## [READY] Pending — Emerald: a ghost cannot abandon a step it has started (2026-08-20)

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

## [READY] Pending — Emerald: what the two-renderer comparison left open (2026-08-19)

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

## [READY] Pending — Emerald: no ghost until you are actually in the game (2026-08-19)

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

## [READY] Pending — Emerald: a room bigger than the map (2026-08-19)

Measured with synthetic peers, not with people: the engine's 16-entry object array is shared with
the map's own NPCs, so a town holding the player and two NPCs fits exactly **13 ghosts** (measured
2026-08-19, before the reserved slot existed — the same town budgets **12** today, see
`README.md`'s Limits section); peers
past that are refused and simply never appear. Past the ceiling the adapter used to log a refusal
per unplaceable peer per frame, which cost 60fps → 3fps at 24 peers and 1fps at 36; that is fixed
(throttled message, and no further spawn attempts once the array is full for the frame) and
re-measured at 59.7-59.8fps with 24 and 36 peers offered. See `pitfalls.md` for the full story.

- [ ] **A crowded map still plays normally.** *What to look at:* full speed, and the ghosts that
      are there. *Correct:* the game runs at normal speed with a dozen ghosts around you, the ones
      that fit look and move like ghosts always have, and the map's own NPCs are all still there
      and still walking their routes. Extra peers being invisible is expected, not a fault.

## [READY] Pending — Emerald: two tiers of ghost, so nobody is missing (2026-08-19)

Phase 9.1's Emerald half. Peers now fall into two tiers: real spawned object events up to what the
map can spare (**nearest peers win**, with a 3-tile hysteresis band so ghosts do not swap tiers
while someone walks past, and a reserve so the engine always keeps a slot for a character of its
own), and everything past that painted with the older `gui.*` pixel path so that **no peer is
simply absent**. The drawn tier is behind `MESHGHOST_EMERALD_DRAWN_OVERFLOW` and is **off by
default** — see `BANDAGES.md`: a drawn ghost has no engine occlusion. (The text-box/START-menu
region has since been measured and the tier clips it — `tiering.scanPanel()` reads BG0's tilemap,
shipped 2026-08-19 — so the reason the flag stays off is now that the clip has not been repeated
under controlled real play, not that the region is unmeasured.)

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

## [READY] Pending — peer graphics: bikes, surfing, fishing (2026-08-18)

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

## [OPEN] Known incomplete — do NOT confirm, these are not finished

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

## [READY] Pending — Emerald: what a BLOCKED rider actually does (2026-08-20)

A ghost on a bike no longer performs the walker's bump (`BUMP_ACTION`, the walk-in-place slow
shuffle from `PlayerNotOnBikeCollide`) when it has nowhere to go -- it stands still instead. That
removes a visibly wrong animation (*"the spawned one actually flips the sprite in reverse for a
bit"*) but standing still is a placeholder, not a measured answer.

- [ ] **Ride into a wall on each bike and read the player's own `movementActionId`.** Whatever the
      engine gives a blocked rider is what a ghost should perform. `probes/wheelie_watch.lua` is the
      shape to copy -- drive it, log the player's object per frame. Until then a blocked ghost on a
      bike is silent where the player is not.

## [READY] Pending — Emerald: two edges the mount/dismount fixes may have (2026-08-20)

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

## [READY] Pending — Emerald: cross-map ghosts, what still needs the user's eye (2026-08-20)

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

## [READY] Pending — Emerald: a reversal while hopping leaves the SPAWNED ghost facing the old way (2026-08-20)

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


## [READY] Pending — Emerald: the hardware-sprite tier, what still needs the user's eye (2026-08-21)

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

## [READY] Pending — Emerald: the DRAWN tier after the glide fix (2026-08-21)

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

## [READY] 2026-08-21 (water/warp session) — what was NOT confirmed

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

## [READY] 2026-08-21 (dive session) — what the user has NOT confirmed

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


## [READY] 2026-08-21 (dive session, evening) — the surf transition work, and what remains unjudged

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

## [READY] 2026-08-21 (ice/fog/cave session) — what the user has NOT confirmed

Ice, the fog fallback and the cave-darkness clip are all **confirmed** and live in `verified.md`.
What that session left untested:

- **The flash clip on a PATCHED ROM.** It is gated to vanilla on purpose — the scanline addresses
  are our own build's — so on an Archipelago seed the clip declines and a painted ghost still shows
  through a dark cave. Deliberate, never seen.
- **`MESHGHOST_LOOPBACK_OFFSET_X/_Y`**, added so a loader script can place the copies for a
  particular question. Used once and put back; the defaults are unchanged, so nothing shipped
  should differ — but the shipped default path has not been re-watched since the globals went in.

## [READY] Emerald: the boat and Fly are BUILT and UNWATCHED; rails are still only assumed (2026-08-26)

**The 2026-08-21 entry this replaces recorded the ferry and rails as assumptions, and had the boat
wrong.** It named the S.S. Tidal. The ride the user actually meant is **Mr. Briney's**, the one
between the first and fifth gyms — a different mechanism, and the one that has now been built for.
The user's original framing still stands for the half nobody has touched: *"ferry, rails untested.
assumed to work. unverified. dropped from status for now."*

### What was built, 2026-08-26 — nothing here has been on screen

Both states were unrepresentable in what the adapter sent, for the same reason: every field it
publishes describes a character standing on a tile, and in these two the engine has taken the
character off the board. The mechanisms are written up in `documentation.md`, "Two states where the
game stops drawing the player as a character". Four new `extras` reach the wire — `invis`, `boat`,
`fly`, `flyk` — and the receive side acts on them.

- **The boat is a SPRITE OF ITS OWN, and the ghost inside it is hidden.** That is what the ride is:
  the player's object hidden, a boat object on the same coordinates. The spawned tier builds the
  boat the way it builds a shadow — from the graphic's own ROM entry, engine dummy callback,
  positioned from Lua each frame.
- **The boat can REFUSE, and then the ghost is hidden instead.** Its graphic sits on an NPC palette
  slot rather than the shared Brendan/May tag, so it can only be drawn where the watcher's own map
  has that palette loaded. This is the user's option 2 arriving automatically as the fallback for
  option 1, rather than as a separate decision — **and which of the two actually happens on Route
  104 and in Dewford has never been observed.** It is the first thing to look at.
- **A flying peer rides the ENGINE'S OWN BIRD.** `FldEff_NPCFlyOut` already flies characters who
  are not the player, and its arc routine names its passenger in its own sprite data — so the
  adapter builds the bird from the template, points it at that routine, and names the ghost. The
  flight is the engine's; nothing reimplements the curve.
- **A fly is the one state allowed past the peer-graphics gate.** `MESHGHOST_GHOST_PEER_GFX` is off
  by default, so a ghost normally wears the LOCAL player's graphic — which for a fly would mean
  taking off in a pose the game does not have. Narrowed to the fly states only; see below.
- **Neither self-drawn tier attempts any of it.** Painted and hardware peers get the ABSENCE — they
  are not drawn while a peer is hidden, sailing, or carried by the bird. That is deliberate: the
  boat and the bird are engine sprites, and a painted re-implementation of something the hardware
  does correctly two tiles away is a second implementation, not parity. A standing tier gap.

### Nine fly faults found and fixed on 2026-08-26, none of them user-confirmed yet

Driven from the user's savestates on two instances (flyer on 1, watcher on 2), so every one below
is measured rather than reported. **The user has confirmed exactly one thing on screen** — a
same-town departure watched from the other instance: *"the flying animation was done properly etc.
the position after landing was right, the bird blob was done properly"*. Everything else here is
agent-measured and belongs in this file until they say otherwise.

1. **The bird was spawned and destroyed every frame** of a departure. The engine's arc callback
   sets "done" past 0x80 and keeps incrementing; there is no task here to tear the sprite down, so
   each teardown was followed by a fresh spawn seeded past the end. One loop, both original
   symptoms (*"sprites are glitchy"*, *"not following the player at all"*).
2. **The bird started at arc 80 of 128** — a bird and its passenger are two different events, and
   waiting for the hand-off skipped the whole descent.
3. **The `fly == 1` branch retired the bird** the same frame the spawn made it, so a bird only ever
   survived once the peer reported being carried.
4. **A surf blob was attached during a fly.** The mount pose borrows the surfing graphic, so every
   attach site saw "surfing" and obliged — and a blob follows an object id in its own sprite data,
   so it outlived the flight. **The user spotted this one; no log would have shown it.**
5. **The ghost's first frame was never written to VRAM** on a rebuild — `graphicsInfo(wantedGfx)`
   is nil whenever the peer's graphic is not adopted, and `loadGhostFrameNow` then returns early
   leaving freshly claimed tiles unwritten. Pre-existing; the landing rebuild is what made it stick.
6. **The bird's arc was anchored at screen centre.** Correct for the engine, which flies only the
   player; for a ghost it dragged the character to the watcher's own feet first.
7. **A carried sprite was never put back on the map** — nothing on the engine's side recomputes an
   object event's sprite position from its coordinates, so the sprite stayed where the arc let go.
8. **The done-latch was phase-gated** and an arrival never reaches phase 2, so the arrival bird
   flickered on alternate frames — which is why no bird was visible on arrival.
9. **The latch then hid the landing.** Departures end carried, landings end released; the phase a
   flight ended on is the discriminator, not the latch.

### Still open on Fly, per tier, from the user's 2026-08-26 pass

They confirmed a same-town fly *"looks fine from another instance"*. The rest of their list is
untouched or only partly addressed, and it splits by tier -- which is itself the finding: three
renderers, three different faults, one shared cause only in the blob's case.

- **Drawn tier: wrong pose, and an 8px sideways nudge before the flight.** *"drawn gets pushed a
  tiny bit to the left, then snaps back, and then does the flying animation. also looks stiff/idle
  pose instead of 'holding up a pokeball'"*. `runsForPeerGfx` CAN decode the field-move graphic
  from the cartridge, so this is a lookup failing and falling back to the cached walker, not a
  missing capability -- the fallback is silent. The nudge is the same event: the pose graphic is
  32 wide against the walker's 16, and the tier's centring term steps by 8 when the width changes.
  Whether that step is correct (it mirrors the engine's centerToCorner) or doubled has not been
  measured against the spawned copy standing beside it.
- **Hardware tier: a brief glitched sprite** at a graphic change. Not diagnosed. Same shape as the
  spawned tier's, below, and probably the same cause.
- **Spawned tier: intermittent glitch**, which the user places as *"similar to the issue we had
  with egg/orange sprite when doing dive"* -- so a known family: a tile range read before the
  frame that belongs in it was written. `loadGhostFrameNow`'s early return was one instance of
  that family and is fixed; this is another and is not.
- **Spawned tier: arrives seated.** *"arrives with fly in a 'sitting/surfing' pose instead of
  standing 'idle' on the ground"*. The engine releases its character partway down and finishes
  with an 18-frame drop table while still wearing the mount graphic, so a ghost re-anchored to the
  landing tile at the release sits on the ground in that pose for those frames. Whether the ghost
  should descend with the drop instead (the peer sends the offset as `soy`) has not been compared
  side by side with the player doing it.

### What is still open on Fly

- **Nothing above is user-confirmed except the same-town departure.** The cross-town arrival was
  fixed after the user's last look at it and has only been judged from screenshots by the agent.
- **The arrival drop is not mirrored deliberately-or-not.** The engine finishes an arrival with an
  18-frame hand-written drop table on its own sprite; the ghost gets whatever `soy` carries. Never
  compared side by side.
- **The warp-gap hold is a 480-frame timeout.** If an arrival never comes (a peer that quits
  mid-fly), the ghost stays hidden for eight seconds before being rebuilt. Untested.
- **Rails remain untouched** — not built for, not measured, not watched.

### What the two savestate pairs can and cannot show

The user's states: flyer 5 same-town, flyer 6 different-town; watcher 3 and 4 for the two towns.
**A same-town fly takes off and lands on the SAME TILE** (measured 27,24 both sides), so slot 5
cannot show a landing-position fault at all. **A landing is only visible from the town the flyer
arrives in** — two paired runs came back clean while a bug was still there because the watcher was
in the departure town watching a peer leave.

### The peer-graphics gate is probably stale, and was NOT lifted

`MESHGHOST_GHOST_PEER_GFX` is off because peer graphics rendered corrupted on 2026-08-18, and
`FLAGS.md` records the cause: the spawn path forced `subspriteTableNum = 0` while the engine manages
that field itself. **Both spawn paths stopped forcing it on 2026-08-21** — `swapGhostGraphicInPlace`
and `spawnGhost` each carry the fix and its reasoning — and the gate has not been re-judged since.
So the recorded cause is fixed and the gate may now be pure cost: every peer special state, not just
these two, is invisible to a watcher whose own player is not in the same state.

That is a live question, not a reading one, and it was deliberately not answered by flipping the
flag. What shipped instead is the one state that provably cannot be served without it. **Worth one
run with the flag set once the boat and the fly have been judged**, not before — two changes at once
is how a working fix gets blamed for a broken one.

## [READY] Emerald compiles again, but has not been RUN since the fix (2026-08-22)

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


## [READY] MEASURED: the config's bridge port, the relay-down backoff, and a config file nobody was reading (2026-08-28)

**Here rather than in `VERIFIED.md` because the evidence is a log this agent read**, from a
staged-release run it drove itself. Nothing below was watched on screen, and none of it changes
what a ghost looks like.

**The rig.** A release staged to a scratch folder, `config.json` edited to
`"local_game_bridge": "127.0.0.1:6672"` and `"connect_to": "127.0.0.1:7999"` — a port with nothing
on it, so the relay is unreachable **without touching the relay the user had running on 7777**.
BizHawk launched with the vanilla ROM and the staged script.

**1. The config's port is honoured, end to end.** It was not before this day: the range was a
constant, so a player who moved the port moved the client and not the script, and the two then
never met.

```
MeshGhost: bridge ports 6672-6679, from local_game_bridge in config.json
Bridge: walking 127.0.0.1:6672-6679 for a core that will have us.
MeshGhost: started a core (no window) on bridge port 6672
MeshGhost: bridge_ready on port 6672 -- this core is ours.
```

Independently confirmed from outside the adapter: the spawned core held a listening socket on
**6672**, checked with `Get-NetTCPConnection`, not read back from the thing that set it.

**2. The relay-down backoff waits instead of walking — the first time this was measured on
Emerald.** Over ~60 seconds with the relay unreachable: **7 connect attempts, every one on 6672,
and no other port ever touched.** Broken, this would have cooled 6673, 6674 and the rest of the
range in turn, reported "no free port to start a core on", and gone on spawning cores nobody could
use — the shape Crystal's own comment prices at *Emerald running at 5fps while a relay was full*.

**Only ONE branch of the distinction was exercised here**, unlike TEVI's run: this adapter never
met a genuinely busy core, so "walks on busy" is still unmeasured on Emerald. Do not read this as
both halves.

**3. A shipped bug found by accident, and fixed: an autostarted core was reading no config at
all.** The first run's core reported

```
working directory ...\games\pokemon\emerald (config and this log are read/written here)
no config file at ...\games\pokemon\emerald\config.json -- using built-in defaults (connect_to 127.0.0.1:7777)
```

It then connected to `127.0.0.1:7777` — the machine's own relay — while the config it was supposed
to obey said `7999`. The child process inherited the emulator's working directory, and this
adapter's folder ships no `config.json`, so **every setting a player edited in the release root was
silently ignored whenever the adapter started the core itself.** A player pointing `connect_to` at
a friend's host would have autostarted a core that quietly talked to nobody, with its log written
somewhere they were never told to look. The README promised the opposite: *"It reads the
config.json next to it, so there is nothing to copy and nothing to edit anywhere else."*

TEVI (`WorkingDirectory`) and Pseudoregalia (`CreateProcessW`'s `lpCurrentDirectory`) had always
set this; the two Lua adapters were the pair that did not. After the fix, the same run reports

```
working directory ...\mg_porttest (config and this log are read/written here)
config loaded from ...\mg_porttest\config.json
core: dial relay: dial tcp 127.0.0.1:7999 ... -- will keep retrying
```

which is the configured address being obeyed. **The core's log moves with the working directory**,
from the game's folder to the folder holding `meshghost.exe` — the same place option 1 has always
written it.

**What is still not measured on this adapter:** anything a player sees. No ghost, no seam, no
sprite was part of this run.

## [READY] Pending — `extras.gender` accepts only `male`/`female` (2026-09-02 adversarial review), unwatched

`meshghost_emerald.lua`, the remote's gender read: anything but those two strings — a number, a
table, or a string naming a `genderFrames` method — made `drawRemotes` error every frame, and every
peer sorted after the hostile one in `pairs(remotes)` stopped drawing. Now falls back to `male`,
the same as a missing value. ADR 0044, `docs/security.md`.

**WATCHED 2026-09-02, the same evening:** the user started a fresh save as May with a 24-peer crowd up and
read all three tiers at once: *"OAM, drawn & spawned all look like May"*. The guarded path draws the female
frames; the review change cost nothing visible.

## [READY] WATCHED 2026-09-02 — the ladder spawned -> OAM -> drawn is the shipped default now, and the three tile leaks it exposed are fixed; what the user saw, what is left

**The decision, the user's:** *"Spawned -> OAM -> drawn should be the 'default shipped' preference ...
spawned works everywhere, OAM should be preferred everywhere whenever possible, Drawn should be used
underwater or whenever OAM can't render due to fog"*, and *"any weather overlay, desert, fog, underwater.
is where OAM breaks. but it perform way better than drawn everywhere else in the game"*. Both overflow
rungs default ON since today (`FLAGS.md`); the stand-down under a screen-covering overlay is the
fall-through to drawn, and the desert's sandstorm triggers it like fog and the underwater haze do.

**The rig that watched it:** vanilla Emerald, dev loader, compare mode, `meshghost-fakeadapter` with 24
synthetic peers circling the player at radius 5 on Route 111 (`-area-id 0:26`), the hitch meter, and
two new read-only probes (`dev-scripts/objtiles_probe.lua`: the engine's OBJ tile bitmap against the
live sprite table; `dev-scripts/ghostobjs_probe.lua`: every object wearing our marker and every
hardware OAM entry). The counts, from the adapter's status line: in the sand 13 spawned / 0 OAM / 19
painted; outside it 13 spawned / 13 OAM / 1 painted — the ladder, on screen, at 60fps.

**Three leaks and one corruption, all found by the bitmap probe, all fixed and re-watched:**
1. **Weather stand-down forgot its tiles.** `hwReleaseAll(false)` (the map-change form) under an
   overlay leaked one body per peer per stand-down; the third sand pass ran OBJ VRAM dry, the game
   fell to 6fps and the sandstorm's own sprite corrupted. Now released WITH the deferred free.
2. **A seam is not a warp.** The tier forgot its tiles on every area change; a connection crossing
   keeps the bitmap. Three seam signals now (the cross-map rebase, a surviving spawned ghost, and
   "never left CB2_Overworld" — the last is the one that needs nothing armed); pending frees are
   re-stamped to the new area; the helper's area-blanking no longer triggers a second, forgetting
   pass one frame later.
3. **Hot reload leaked the hardware tier's ranges** (~208 tiles a reload): the unload flush judged
   them "not ours" because the release had already blanked the area. Captured before the release.
4. **A double-queued free cleared bits a NEW owner had taken** — an NPC drawing Brendan's frames
   through its own green palette with the hat row missing (tiles 212..227 ours, the NPC at 216).
   Every free now checks the sprite table for a live owner first (`rangeDrawnByLiveSprite`) and
   skips with a logged reason rather than corrupt; the warp-time pending frees got the same guard.

**Also fixed on the way:** two compare-mode traces (`WALKER REFL`, `HOP`) fired per peer per frame or
per tile and read as *"performance is chugging"* — moved behind their own probe flags; the "no run of
free OBJ tiles" console line throttled to the file. **User's final read after the full cycle** (cave,
four seam crossings, four sand passes): *"didn't see any weird/glitched sprites now"*, *"now it looks
like all are moving, even after crossing routes"*. Bitmap flat at 444/1024 across it, zero skipped
frees, zero refusals.

**Open, from the same session:**
- [ ] **The attach burst.** A core that remembers many nametags (103 today, one per synthetic peer per
      crowd restart, never pruned across relay reconnects) pushes them all at attach and the adapter
      gives up on its hello ("never answered") — a loop of attach/drop every 3s until the core was
      restarted. Two halves: the core should drop names the roster no longer holds (Go), and the
      adapter should not time out its hello while lines are arriving (Lua). Neither built.
- [ ] **Rung churn.** With a crowd walking, peers at the spawned/OAM boundary swap rungs every ~14
      frames (217 hardware acquires in two minutes). Harmless now that frees are correct, but each
      swap is a tile allocation and a frame load; a stickier boundary is an efficiency item.
- [ ] **Drawn clipping under a text box and the START menu** with a painted crowd — the caveat the
      drawn rung was held back for — was not exercised today.
- [ ] The `hw area change` and `tile free SKIPPED` lines stay in as low-rate diagnostics (they fire
      per area change and per skipped free, never per frame).

## [DONE] The interp ladder on a 100–200ms lossy link, judged by the user (2026-09-02): same shape as Crystal's, the shipped 250ms stands

**Rig:** vanilla Emerald in shipped mode (adapter on the command line, one loopback ghost), relay 15Hz,
`meshghost-netsim` at 75ms ±25ms each way with 2% loss on the same seed Crystal's ladder used
(`1788359927364670300`), loss cover on, fast-forward off. The user walked and biked a square.

| Interp | Loss | User's read |
|---|---|---|
| 100ms | 2% | *"its gliding around a bit"* |
| 250ms (shipped) | 2% | *"still noticing some glide ... seems to be the same issues"* as Crystal |
| 300ms | 2% | *"still some glide at 300ms. so yes same as crystal"* |
| 300ms | off | *"think its good enough, same as crystal"* |

**Verdict:** identical to Crystal's ladder the same day (`crystal/UNVERIFIED.md`): delay alone is fine at
the shipped interp; what remains with loss on is the residual quic-after-a-loss glide filed in
`ideas.md`. **250ms stays shipped** for the same loopback reason (a loopback ghost's samples make the
round trip). The RATE was not swept on Emerald — 15Hz is still inherited from the Pseudoregalia and
Crystal judgements. **Rig note:** with the adapter's autostart on, a core restarted for a new interp
loses the race to the adapter's own spawn, which runs from the REPO ROOT and reads `config.json`
there — the ladder's last steps were driven through a temporary root `config.json` (`connect_to`
127.0.0.2, `interp`), deleted at teardown; never commit one.
