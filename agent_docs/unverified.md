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

## Pending — Emerald spawn adapter (2026-08-18)

The adapter now renders peers as real spawned object events instead of drawing them. Several
pieces were confirmed individually during the session; these are the ones that were **not**.

- [ ] **End-to-end, in one sitting.** Each behaviour below was confirmed separately as it was
      fixed, but never all together after the last change. *What to look at:* walk around, run,
      cross a route boundary, enter and leave a building, open the pause menu.
      *Correct:* one ghost, always exactly two tiles to your right, matching your movement, on the
      grid, hidden behind the menu, and never more than one.
- [ ] **On-grid placement after the settled-camera fix.** *What to look at:* the ghost's feet
      against the tile grid while standing still, after several map changes.
      *Correct:* square on a tile, never a few pixels off it.
- [ ] **House and elevator transitions.** Clean across 57 log samples, but not watched.
      *Correct:* the ghost disappears during the transition and reappears beside you, and **no
      real NPC goes missing** from the map you left or entered.
- [ ] **Ghosts are non-interactable.** *What to look at:* press A facing the ghost, repeatedly, in
      a few places. *Correct:* nothing happens at all — no text box, no minigame.
      (The bug this fixed launched the slot-machine minigame.)

## Pending — Emerald robustness pass (2026-08-19)

Four defects found by reading and fixed; none changes what a ghost is supposed to look like, so
the only thing to watch for is that nothing got *worse*. The end-to-end item above now has to be
run against this version rather than yesterday's.

- [ ] **Nothing regressed.** *What to look at:* the same walk-around the end-to-end item asks for.
      *Correct:* exactly as before — one ghost, two tiles to your right, on the grid, hidden behind
      the pause menu. The changes were: the orphan sweep is now gated to the overworld on a
      confirmed vanilla address; a bridge rejection no longer throws; a peer's `graphicsId` is
      bounds-checked before it indexes a ROM table; the frame-error log no longer swallows the
      first 300 frames.

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

- [ ] **A peer's ghost of you disappears when you go back to the title screen.** Needs two clients,
      or one client plus the relay's loopback ghost. *What to look at:* the ghost, while the other
      player soft-resets (A+B+Start+Select) back to the title. *Correct:* it vanishes within about
      a second. Wrong: it stands there frozen where they were.
- [ ] **No ghost at all while someone is in the main menu / intro.** *What to look at:* the other
      player boots the game and sits on the title, the continue screen and the intro without
      entering the world. *Correct:* no ghost anywhere on your screen the whole time — in
      particular, none standing at their last save point, which is what used to happen.
- [ ] **The ghost comes back, and nothing else changed, once they are in.** *What to look at:* they
      choose CONTINUE and walk around. *Correct:* the ghost appears beside you within a second or
      two of them reaching the overworld, and everything else behaves as before — pause menu,
      doors, battles, route changes. The gate is a latch and is deliberately NOT re-tested per
      frame, so a battle or a warp must NOT make the ghost blink out.
- [ ] **Two sessions in a row.** Soft reset, then continue again. *Correct:* one ghost, not two,
      and it wears the right character (gender is re-read per session now).

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
- [ ] **Ten seconds that would let this tier ship on: open a text box, then the START menu.**
      *What to do:* stand anywhere, talk to an NPC or read a sign and leave the box up for a few
      seconds, then open the START menu and leave it up for a few seconds.
      *Why:* `probes/textbox_probe.lua` reads what the GAME drew into the background tilemaps, and
      has already confirmed the quiet half — with nothing open, BG0 is completely empty while the
      map sits on BG2/BG3. The other half, which rows a panel writes into, cannot be measured
      without a panel on screen, and the drawn tier stays off until it is. Nothing to judge here:
      the probe records it, no correctness claim is being made about what you see.
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

- **Surfing: the blob is now spawned and the engine drives it, but it sits in the wrong place and
  the wrong colour.** Progress worth keeping, and not finished:
  - **What works.** `UpdateSurfBlobFieldEffect` turns out **not** to be hardcoded to the player —
    it reads an object event id out of `sprite->data[2]` and synchronises to whatever that names.
    Point one at a ghost and the engine animates and follows it for free. Built from
    `gFieldEffectObjectTemplate_SurfBlob` (`0850CBC4`) because no live blob exists to copy unless
    somebody is already surfing. Confirmed alive by its OAM Y changing every sample — that is the
    engine's own bobbing running on our sprite.
  - **What does not.** It renders roughly half a tile down-right of the rider instead of under it,
    and **dark navy instead of blue** — the palette the blob expects is not loaded while the local
    player is walking, since the game only loads it when *you* surf. Walking the ghost does not
    correct the offset, so it is not a stale initial placement; the engine puts it there.
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

## Pending — ten seconds of input in EMERALD, to unblock its drawn tier (2026-08-19)

Emerald's drawn-overflow tier is built but **shipped off**, because a drawn ghost would paint over
text boxes and nothing reliable said where the UI is. The Crystal method (ask the game what it
drew, not the LCD what it is displaying) has been ported — `probes/textbox_probe.lua` computes each
background's tilemap address from the GBA's own `BGnCNT` registers, so it cannot go stale against a
ROM revision, and it costs nothing measurable (59.8fps with it running).

It already shows the map on BG2/BG3 with **BG0 completely empty**, which is the shape the answer
predicts: the panel layer stays blank until the game draws a panel into it. What is missing is a
sample of the other state.

- [ ] **Talk to an NPC in the Littleroot house (or read any sign)**, leave the text box up for
      about three seconds, then close it.
- [ ] **Open the START menu**, leave it up about three seconds, then close it.

That is the whole request. A watcher is running on the probe's log for the first frame where BG0
stops being empty; the rows and tile ids it captures decide whether the drawn tier can ship on.
If BG0 turns out to carry other things too (HUD, weather), the honest answer is to leave the flag
off, and that is what will happen.
