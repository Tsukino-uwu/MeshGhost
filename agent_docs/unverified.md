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

- **Surfing renders the rider without the blue Pokémon underneath.** Confirmed by the agent's own
  screenshot and by the user's description. The blob is a separate sprite — `ObjectEvent` carries
  a `fieldEffectSpriteId` (offset `0x1A`), so a surfing ghost needs that companion field effect
  spawned too, which is not built. **Fishing and underwater are untested and may have the same
  shape of problem.**
- **Archipelago ROMs still use the old drawn overlay.** See `adapters/pokemon/emerald/BANDAGES.md`
  — one live run on a patched seed either closes it or refuses safely.
