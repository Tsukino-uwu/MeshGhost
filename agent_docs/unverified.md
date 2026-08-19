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
- [ ] **A question, not a claim — should the adapter be broadcasting from the main menu?**
      Observed in the live log, not decided: `gSaveBlock1Ptr` is already populated at the
      **continue screen**, so the adapter sends the saved position (`pos=(10,10)`,
      `overworld=false`) for as long as someone sits there. `contract.md`'s closed question says
      `nil` is warranted only when that pointer reads null ("title screen / no save loaded"), which
      this technically is not. **A peer would see a ghost of you standing at your last save point
      while you are in the main menu.** Left alone deliberately — it is a change to what a player
      sees, so it needs the user's answer first.

## Pending — Crystal: a ghost can wear the peer's own sprite (2026-08-19)

The adapter now looks a peer's sprite id up in `wUsedSprites` and gives the ghost that sprite and
its VRAM tile when the tiles are already loaded on this map; otherwise nothing changes and the
ghost wears the local player's sprite, exactly as before. Self-tested two ways — a RAM read-back
showing the ghost's `sprite`/`tile` equal to the engine's own object wearing that sprite, and a
loopback session where the peer's sprite IS the player's, which must look unchanged.

- [ ] **A loopback ghost still looks right.** This is the no-regression half, and the one that
      matters: in loopback the peer's sprite is your own, so the new path runs on every spawn.
      *What to look at:* the ghost beside you, standing and walking.
      *Correct:* exactly as before — a clean character, correct colours, not scrambled and not
      half-drawn.
- [ ] **A ghost wearing a sprite you are not wearing.** Set
      `MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE=4` (an id New Bark Town has resident) with
      `MESHGHOST_LOOPBACK_OFFSET_X=2`. *What to look at:* the ghost two tiles to your right.
      *Correct:* it is the RIVAL's character, drawn cleanly, while you are still yourself.
      (An agent screenshot looks right; a screenshot is not proof, so this is here.)

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
