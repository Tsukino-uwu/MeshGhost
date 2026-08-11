# Phase 5.5 — Real Emerald ghost sprite (gender-correct, no more magenta box)

**Status: complete**, 2026-08-11. Inserted between Phase 5 and Phase 6 — see
`agent_docs/plans.md`. Not a numbered roadmap phase in the original sense (it doesn't gate the
game-count milestones), same treatment as the unnumbered "Post-Phase-4 — Room codes" entry, but
the user explicitly wants Emerald's ghost rendering "finished" before Phase 6 (TEVI) starts.
All three scoped items (real sprite art, `extras.gender`, female-save re-verification) are done
and confirmed live — see `agent_docs/verified.md`.

## Purpose

Every ghost so far renders as a flat magenta placeholder box
(`adapters/pokemon/emerald/assets/ghost_placeholder.bmp`) — deliberate, not a bug
(`agent_docs/risks.md`). This phase replaces it with the actual Brendan/May overworld sprite,
adds gender to the packet schema so a remote's ghost uses the right sprite, and re-verifies
every Phase 1/2 address on a female-character save (previously only tested on male).

Full research, address citations, and the step-by-step approach are recorded in the plan this
phase executes: see the plan mode transcript from 2026-08-11 (research summary duplicated into
the task list below so it survives independent of that transcript).

## Scope, explicitly

In scope: real sprite art, `extras.gender` in the schema, female-save re-verification.
Deliberately out of scope, staying exactly as already documented and deferred: bike/surf flags,
the `coordOffsetEnabled` assumption, seamless route/town ghost rendering, the relay-disconnect
log spam, and the two open contract questions (snapshot frequency, seq/timestamp semantics).

Surfaced during Step 3 live testing, not fixed this phase, added to the same deferred list:
**ledge jumps, Mach Bike, Acro Bike, and Surfing all need their own position-smoothing and
sprite handling**, same category as the already-deferred bike/surf flags. Confirmed via
`src/field_player_avatar.c`'s `sPlayerAvatarGfxIds`: `PLAYER_AVATAR_STATE_MACH_BIKE`/
`ACRO_BIKE`/`SURFING` each have their own distinct `graphicsId` (and therefore their own pic
table), unlike plain on-foot Running Shoes dashing — checked all four on-foot speed tiers
(`sAnim_GoSouth`/`GoFastSouth`/`GoFasterSouth`/`GoFastestSouth`) and all four reuse the exact
same frame indices, only the hold-duration differs, and `sPlayerAvatarGfxIds` has no separate
state for dashing at all. So a visually distinct "running pose" is not expected from this
data — what reads as one during real play is most likely the faster cadence plus the camera
panning faster, not a different sprite; a ghost has no camera of its own to reproduce that
second part. Not chased further; logged here rather than guessed at again.

## Key research facts (citations, not yet verified — verification happens per task below)

- `gui.drawPixel(x, y, color)` (BizHawk `gui.d.lua`) is the drawing primitive — `gui.drawImage`
  only loads from a file, unusable for dynamically-decoded graphics.
- Player sprite graphics are **raw, uncompressed** ROM data (`.4bpp`/`.gbapal`, not `.lz`) —
  confirmed by reading `pokeemerald`'s `src/data/object_events/object_event_graphics.h`. No
  LZ77 decompression needed.
- Real addresses from the user's own `make compare`-verified `pokeemerald.sym`:
  `gObjectEventPic_BrendanNormal` = `0x084975F8` (size `0x900`, 9 frames × 256 bytes),
  `gObjectEventPic_BrendanRunning` = `0x08497EF8`, `gObjectEventPic_MayNormal` = `0x084A3078`,
  `gObjectEventPic_MayRunning` = `0x084A3978` (all `0x900`), `gObjectEventPal_Brendan` =
  `0x084987F8`, `gObjectEventPal_May` = `0x084A4278` (both `0x20` = 16 colors × 2 bytes BGR555).
  `gSaveBlock2Ptr` = `0x03005D90`, `playerGender` at `+0x08` (`include/global.h` L511),
  `MALE`/`FEMALE` = `0`/`1` (`include/constants/global.h`).
- Precedent: `src/union_room_player_avatar.c` is vanilla Emerald's own code for spawning
  *another linked player's* sprite (Union Room), confirming gender-indexed graphics-id lookup
  is the game's own real mechanism for this, not a novel hack.

## Tasks

- [x] Step 1: probe script decodes one static Brendan/May frame (whichever matches the current
      save) from `gObjectEventPic_*Normal` + `gObjectEventPal_*`, prints sample RGB pixel
      values. Visible outcome: printed colors plausibly match the real sprite. User-confirmed
      before proceeding. Confirmed 2026-08-11 — see `agent_docs/verified.md`; user compared the
      decoded ASCII silhouette and palette against a screenshot of their own in-game sprite.
- [x] Step 2: draw that decoded frame via `gui.drawPixel` at a fixed test offset (mirrors Phase
      2's first hardcoded-offset ghost). Visible outcome: a real (blocky, 4bpp) trainer sprite
      renders on screen instead of the magenta box. User-confirmed 2026-08-11 — see
      `agent_docs/verified.md`. Also found and fixed along the way: `gui.drawPixel`'s integer
      color format is `0xAARRGGBB`, not the `0xRRGGBBAA` initially assumed.
- [x] Step 3: facing direction (`orientation`) selects the right animation frame; a locally
      driven animation-phase timer cycles walk/run frames while `anim` is `walking`/`running`.
      Visible outcome: ghost's pose matches facing and legs visibly animate, confirmed live
      with two real peers. Confirmed 2026-08-11 — see `agent_docs/verified.md`. Along the way,
      found and fixed a real, separate problem not originally scoped for this step: the raw
      `gSaveBlock1Ptr` position sent over the network is a whole-tile coordinate that only
      updates once per completed tile-step, which made a moving remote's ghost look
      choppy/teleport-y and made even a stationary remote's ghost wobble on a moving viewer's
      own screen. Fixed with adapter-side sub-tile position smoothing (`smoothPosition` in
      `phase5_5_sprite.lua`) using real measured per-tile frame counts (16 walking, 8 running —
      see `agent_docs/verified.md`) locked in at the moment each step commits rather than
      re-derived live (which caused snapping whenever `anim` changed mid-glide, e.g. stopping
      while running). Also fixed: a stale-remotes bug where restarting a core process without
      restarting its adapter left an old peer's ghost on screen alongside the new one
      (`remotes = {}` on bridge reconnect).
- [x] Step 4: `extras.gender` added to local state (read from `gSaveBlock2Ptr->playerGender`);
      remote rendering picks Brendan-vs-May by the remote's `extras.gender` (default `"male"`
      if absent). Live two-peer test with one male-save and one female-save BizHawk instance —
      confirmed gender-correct rendering both ways AND re-verified every Phase 1/2 address
      (`gSaveBlock1Ptr`, `gPlayerAvatar`, `gObjectEvents`, `gSprites`,
      `gSpriteCoordOffsetX/Y`) still resolves correctly on a female save, closing the
      `agent_docs/risks.md` gap. Confirmed 2026-08-11 — see `agent_docs/verified.md`. Along the
      way, found and fixed a real, separate problem not originally scoped: running had been
      implemented as the walk cycle played faster, but real Emerald running uses a genuinely
      separate pic table (`gObjectEventPic_BrendanRunning`/`_MayRunning`) with its own
      asymmetric per-pose timing (`5,3,5,3` frames, not a flat quarter of the walk speed) —
      rewired and confirmed live afterward that running now looks like real running, not fast
      walking. See `agent_docs/verified.md`.

## Links

- `agent_docs/contract.md` — packet schema (`extras` is already free-form/opaque, no
  core/relay change needed for `gender`).
- `agent_docs/phases/phase4.md` — the script this phase's new script is copied from.
- `agent_docs/risks.md` — the female-save-untested gap this phase closes.
- `agent_docs/verified.md` — where each step's confirmed facts land, human-gated as always.
