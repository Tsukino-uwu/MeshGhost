# Verified facts — Pokémon Emerald

<!-- line-cap: none -- append-only human-gated record. Why: agent_docs/claude-md-cap.md. -->

Facts about this adapter and this game, **confirmed by watching a running game**. Split out of
`agent_docs/verified.md` on 2026-08-25, verbatim and in their original order; that file had
reached 10,174 lines with four games and the Go side interleaved chronologically, and was the most
frequently touched file in the repo.

**The gate is unchanged, and it is the strict one.** Nothing adapter- or game-side on the
BASE/VANILLA game goes in here until **the user has confirmed it on screen** — no probe log,
console read or screenshot substitutes. Measurements that are not yet confirmed live in
[`UNVERIFIED.md`](UNVERIFIED.md). A patched ROM (Archipelago and similar) is the agent's to confirm
visually; say so in the entry. The full rule is in [../../../../agent_docs/../CLAUDE.md](../../../../agent_docs/../CLAUDE.md).

**Append-only.** Do not rewrite or delete an entry's original observation. Adding later
live-confirmed detail to an existing entry is fine; superseding one is a NEW entry plus an
annotation, never an edit to the old.

**A fact confirmed against one build/ROM/version is not automatically true of another.** State the
scope in `Notes` whenever it plausibly matters.

**The entry format, and the two evidence tracks**, are in
[../../../../agent_docs/verified.md](../../../../agent_docs/verified.md), which remains the home for Go-side and cross-game
entries and carries the index to these files.

> **NOTE: `internal/X` package paths throughout this file predate the 2026-08-17 move.** The six
> library packages (`protocol`, `relay`, `core`, `transport`, `bridge`, `netx`) left
> `internal/` for the repo root that day — read any `internal/X` as `X/`. Left as written,
> because a dated record records what was true when it was written.

Sibling registers: `../crystal/VERIFIED.md`, `../../../pseudoregalia/VERIFIED.md`, `../../../tevi/VERIFIED.md`.

## Confirmed facts

### Emerald ROM revision

- Date: 2026-08-11
- Observed: `Get-FileHash` on the user's ROM (`Pokemon - Emerald Version (USA, Europe).gba`,
  16,777,216 bytes) gives SHA1 `F3AE088181BF583E55DAF962A92BB46F4F1D07B7`, an exact match for
  the target ROM documented in `pret/pokeemerald`'s own `README.md`.
- Source: `pret/pokeemerald` `README.md` ("It builds the following ROM... sha1:
  f3ae088181bf583e55daf962a92bb46f4f1d07b7").
- Notes: this is the same ROM used for every other entry below.

### pokeemerald local build matches the real ROM

- Date: 2026-08-11
- Observed: user built `pret/pokeemerald` locally (agbcc toolchain via msys2, siblings
  `C:\dev\pokeemerald` and `C:\dev\agbcc`) and ran `make compare`, which printed
  `pokeemerald.gba: OK`.
- Source: `pret/pokeemerald` `Makefile` `compare` target.
- Notes: this is the gate that makes every address below trustworthy — a `make modern`
  (devkitARM) build would NOT match and its addresses would be wrong for this ROM.

### Emerald gSaveBlock1Ptr address

- Date: 2026-08-11
- Observed: `grep -i gSaveBlock1Ptr pokeemerald.map` and, separately, `make syms` +
  `grep -i gSaveBlock1Ptr pokeemerald.sym` both gave the same address, `0x03005D8C`, from the
  `make compare`-verified build above. `03005d8c g 00000004 gSaveBlock1Ptr` (4-byte pointer).
- Source: `pret/pokeemerald` build artifacts `pokeemerald.map` and `pokeemerald.sym`,
  generated from the verified local build; struct layout from `include/global.h` L1081
  (`extern struct SaveBlock1 *gSaveBlock1Ptr;`).
- Notes: this is a pointer, not a fixed struct address — the save block can relocate, so it
  must be re-read every frame rather than cached.

### TEVI Phase 6 — ghost does not visually intrude on full-screen menus (unlike Emerald)

- Date: 2026-08-12
- Observed: user opened TEVI's full-screen Characters page and Map page with the plugin active
  and both rendered cleanly — no ghost sprite drawn over the UI. On the Map screen specifically
  the blurred game world is visibly still rendering behind the semi-transparent panel, meaning
  the world (ghost included) keeps existing and rendering underneath the menu rather than being
  hidden or occluding it.
- Source: `adapters/tevi/MeshGhostTevi/Plugin.cs` — the ghost is an ordinary world-space
  `GameObject`/`SpriteRenderer`, rendered by the game's own camera through its normal pipeline,
  not an out-of-band overlay.
- Notes: this is a structurally different situation from Emerald, not just a lucky outcome.
  Emerald's ghost was drawn via BizHawk's `gui.drawImage`, an emulator-level overlay entirely
  outside the game's own rendering — it had no notion of "behind the menu" and needed an
  explicit `inOverworld()` gate to avoid drawing over battle/menu screens. TEVI's menus are a UI
  layer (almost certainly a `Canvas` in a separate overlay render pass) drawn on top of the
  world scene, so a world-space object naturally ends up underneath it with no adapter-side
  gating required. **This resolves the visual-intrusion half of the still-open "don't send this
  frame" question, but not the other half**: state is still being sent to the network the whole
  time a menu is open, and whether that's the *semantically* right behavior (e.g. should a
  remote's ghost visibly freeze while a peer is in a menu) is undecided and untested — a
  separate question from whether the ghost looks broken locally.

- Date: 2026-08-11
- Observed: `grep -i gPlayerAvatar pokeemerald.map` and `grep -i gPlayerAvatar pokeemerald.sym`
  both gave the same address, `0x02037590`, from the same `make compare`-verified build as
  `gSaveBlock1Ptr` above. Both also report size `0x24` (36 bytes), which matches summing every
  field in the `struct PlayerAvatar` layout below by hand — an independent cross-check that
  the address and the struct layout agree.
- Source: `pret/pokeemerald` build artifacts `pokeemerald.map`/`pokeemerald.sym`; struct from
  `include/global.fieldmap.h` L342-362 (`struct PlayerAvatar { ... }`,
  `extern struct PlayerAvatar gPlayerAvatar;` L374) and flag bits L288-295
  (`PLAYER_AVATAR_FLAG_DASH = (1 << 7)` at offset `0x00`).
- Notes: unlike `gSaveBlock1Ptr`, this is a plain global struct, not a pointer — no
  dereference needed, read fields directly at `0x02037590 + offset`. Relevant offsets not yet
  behavior-tested in BizHawk: `+0x00 flags` (bit 7 = dash/running), `+0x02 runningState`
  (0=not moving, 1=turning, 2=moving).

### Emerald local player X/Y position and direction mapping

- Date: 2026-08-11
- Observed: in BizHawk (2.11, mGBA core, "System Bus" memory domain), reading
  `u32 @ 0x03005D8C` as `base`, then `s16 @ base+0x00` (x) and `s16 @ base+0x02` (y), printed
  live via `adapters/emulator/pokemon/emerald/probes/phase1_probe.lua`. User pressed d-pad left, up, right, down (one
  tap each) starting from x=5,y=4 and observed: left → x=4,y=4; up → x=4,y=3; right → x=5,y=3;
  down → x=5,y=4 (back to start). Reproduced identically on a second run. So: right/left move
  x +1/-1, down/up move y +1/-1.
- Source: address from the entries above; struct offsets from `pret/pokeemerald`
  `include/global.h` L984-986 (`struct SaveBlock1 { /*0x00*/ struct Coords16 pos; ... }`) and
  L174-178 (`struct Coords16 { s16 x; s16 y; }`).
- Notes: tile-grid movement, one unit per tile step (not sub-tile pixels) in this test. Tested
  only in a single room (mapGroup=1, mapNum=1); not yet tested across a map transition or in
  menus/cutscenes.

### Emerald map bank/number fields

- Date: 2026-08-11
- Observed: alongside the X/Y test above, `s8 @ base+0x04` (mapGroup) and `s8 @ base+0x05`
  (mapNum) both read as constant `1, 1` throughout all movement in one room — stable while
  not changing maps, consistent with them being map identifiers.
- Source: `pret/pokeemerald` `include/global.h` L987 (`/*0x04*/ struct WarpData location;`)
  and L581-587 (`struct WarpData { s8 mapGroup; s8 mapNum; s8 warpId; ... }`).
- Notes: only confirms stability within one map so far — changing on a real map transition,
  and the `area_id` encoding decision, are still open (see `agent_docs/phases/phase1.md`).

### Emerald map bank/number change on a real map transition, and gSaveBlock1Ptr relocation

- Date: 2026-08-11
- Observed: user stood outside a house (mapGroup=0, mapNum=9, x=5,y=9), walked up one tile
  (y→8, mapGroup/mapNum unchanged — consistent with the earlier direction mapping), then
  walked inside. On entering, `mapGroup`/`mapNum` changed to `1,0` and stayed there. Separately,
  `base` (the dereferenced `gSaveBlock1Ptr` value) changed from `0x02025A4C` to `0x02025A28`
  between the two readings taken just after entering — i.e. the save block actually relocated
  in EWRAM during this transition.
- Source: same address/offsets as the two entries above.
- Notes: confirms both that `mapGroup`/`mapNum` are the right fields to key `area_id` on, and
  that `adapters/emulator/pokemon/emerald/probes/phase1_probe.lua`'s decision to re-read `gSaveBlock1Ptr` every frame
  (never cache it) is not just defensive — the pointer was observed moving in this exact test.

### Emerald pause-menu submenus (bag, options, player profile) do not invalidate x/y/map

- Date: 2026-08-11
- Observed: user opened and closed the bag, options, and player profile screens from the
  pause menu, separately. In every case x/y/mapGroup/mapNum held steady at the last field
  position (`8,8,1,0`) — no garbage or zeroed values seen. `base` changed a few times each
  time (pointer relocation, same as the earlier outdoors→indoors test), harmless since it's
  re-read every frame.
- Source: same address/offsets as the entries above.
- Notes: this is a partial answer to `phase1.md`'s "note any state where these values are
  invalid or meaningless" — the standard pause-menu submenus are NOT such a state. Battle,
  cutscenes, dialogue, and warp transitions are still untested.

### Emerald map bank/number transition confirmed in reverse (indoors→outdoors)

- Date: 2026-08-11
- Observed: user walked out of the same house from the earlier test. Reading immediately
  after exiting showed `mapGroup=0, mapNum=9, x=5, y=8` — an exact match for the outdoor
  values recorded before entering, and the player spawned on the door tile (`5,8`) before
  taking a further step down to `y=9` (consistent with the confirmed down=+y mapping).
- Source: same address/offsets as the entries above.
- Notes: confirms the earlier outdoors→indoors transition wasn't a fluke — both directions of
  a warp update `mapGroup`/`mapNum` correctly and land the player on the expected tile.

### Emerald NPC dialogue does not invalidate x/y/map

- Date: 2026-08-11
- Observed: user talked to a normal NPC; the probe printed nothing at all during the
  conversation, meaning x/y/mapGroup/mapNum never changed (including no pointer relocation
  this time) — same "stays valid, just doesn't move" pattern as the pause-menu tests.
- Source: same address/offsets as the entries above.
- Notes: still untested: battle, a scripted cutscene (as opposed to a simple NPC text box),
  and the mid-fade moment of a warp transition.

### Emerald scripted forced-movement event (NPC blocker) does not invalidate x/y

- Date: 2026-08-11
- Observed: user walked up into a flag-gated area; a blocking NPC event triggered, gave a
  "can't go there yet" message, and forcibly moved the player back one tile. The probe showed
  `y: 1→2` (a real, valid change matching the confirmed down=+y mapping) with no invalid or
  garbage readings during the scripted push-back, and nothing printed during the dialogue
  itself (position unchanged while text was on screen, same pattern as plain NPC dialogue).
- Source: same address/offsets as the entries above.
- Notes: still untested: battle, and the mid-fade moment of a warp transition.

### Emerald multi-tile forced-movement cutscene tracks correctly

- Date: 2026-08-11
- Observed: a scripted event moved the player forward (not pushed back) across 5 consecutive
  tiles; the probe showed `y: 20→19→18→17→16→15`, one tile per step, matching the confirmed
  up=−y mapping, with `mapGroup`/`mapNum` steady at `0,16` throughout.
- Source: same address/offsets as the entries above.
- Notes: still untested: battle, and the mid-fade moment of a warp transition. This run was
  on an outdated copy of `adapters/emulator/pokemon/emerald/probes/phase1_probe.lua` (no flags/dash/runningState in
  the output) — script needs a fresh reload next session to get those fields.

### Emerald runningState and flags behavior confirmed

- Date: 2026-08-11
- Observed: with the updated probe script, user turned in place (left, up, right, down — no
  tile movement, just facing changes) and x/y stayed at `9,15` throughout while
  `runningState` toggled `1→0→1→0→1→0→1→0`, one `1` (turning) per direction change settling
  back to `0` (not moving). `flags` stayed constant at `0x01`
  (`PLAYER_AVATAR_FLAG_ON_FOOT`, bit 0) the whole time; `dash` stayed `false`.
- Source: address/offsets from the `gPlayerAvatar` entry above.
- Notes: matches `pokeemerald`'s own comment on `runningState` exactly (0=not moving,
  1=turning, 2=moving) — `2` (moving) not yet observed since this test had no tile movement.
  Dash flag (running shoes) still untested — user doesn't have running shoes yet.

### Emerald cutscene-driven warp/teleport does not invalidate position

- Date: 2026-08-11
- Observed: user was moved by a cutscene (teleported into a house, in front of an NPC).
  Reading showed `x=6, y=5, mapGroup=1, mapNum=4, flags=0x21` both before and after, no
  invalid values; `base` relocated (`0x02025A60 → 0x02025A10`), same harmless pattern as
  every other transition tested. `flags=0x21` decodes to `PLAYER_AVATAR_FLAG_ON_FOOT (0x01)
  | PLAYER_AVATAR_FLAG_CONTROLLABLE (0x20)`.
- Source: address/offsets from the `gSaveBlock1Ptr` and `gPlayerAvatar` entries above.
- Notes: closes most of the "invalid state" question from `phase1.md` — pause menus,
  dialogue, forced movement, and cutscene warps have all now been observed to keep
  x/y/mapGroup/mapNum valid throughout. Only battle remains untested.

### Emerald CONTROLLABLE flag tracks the post-warp control-lock window

- Date: 2026-08-11
- Observed: user exited a house. Position/map (`7,16,0,9`) were valid immediately, but
  `flags=0x01` (`ON_FOOT` only, no `CONTROLLABLE` bit) for the first two readings, then
  flipped to `0x21` (`ON_FOOT | CONTROLLABLE`) — only after that did the player actually move
  (`y:16→17`, matching the confirmed down=+y mapping).
- Source: address/offsets from the `gPlayerAvatar` entry above.
- Notes: confirms `CONTROLLABLE` is a usable "can the player act right now" signal, distinct
  from position validity — position stays valid even while `CONTROLLABLE` is unset.

### Emerald entering a house transiently reads a fixed placeholder state for one frame

- Date: 2026-08-11
- Observed: reproduced twice independently, entering the same house both times. Sequence each
  time: `(7,16,0,9)` outside the door → `(6,12,1,4)` warped inside → on the very next reading,
  where `base` had just relocated, the printed values were **exactly** `(4,2,0,9)` both times
  (identical x, y, mapGroup, mapNum) — outdoor-looking coordinates and outdoor map, despite
  the player already being inside — then the reading immediately after, same `base`, corrected
  to `(6,12,1,4)` and stayed there. Leaving the same house (tested twice) never showed this;
  only entering did.
- Source: address/offsets from the `gSaveBlock1Ptr`/`gPlayerAvatar` entries above.
- Notes: **contradicts the earlier generalization** that transitions never produce invalid
  values — this shows a single-frame exception, and getting the identical `(4,2,0,9)` both
  times rules out random stale EWRAM; it looks like a deterministic placeholder/default warp
  state the game briefly holds before writing the real destination, specific to entering (not
  leaving) this warp. Not yet confirmed whether this generalizes to other warps or is specific
  to this one. Practical implication for `get_local_state()`: a lone frame read exactly when
  `mapGroup`/`mapNum` changes should not be trusted uncritically — either re-check on the next
  frame or treat a one-frame outlier as suspect.

### The placeholder-glitch does not happen on every house entry, but is not house-specific either

- Date: 2026-08-11
- Observed: entering two other houses (mapGroup=1,mapNum=0 and mapGroup=1,mapNum=2) both went
  cleanly with no bad intermediate frame, unlike the first house tested (which glitched to
  `(4,2,0,9)` twice in a row). Exits from both were also clean. **Then** the identical
  `(4,2,0,9)` placeholder reappeared a third time — see the battle entry below — this time
  triggered by starting a wild battle, not a house warp at all.
- Source: address/offsets from the `gSaveBlock1Ptr`/`gPlayerAvatar` entries above.
- Notes: revises the earlier "house-specific" theory — three reproductions of the exact same
  values (`4,2,0,9`) across two different kinds of transitions (one house's warp, and battle
  entry) means this is a general transient default/placeholder state on certain transition
  code paths, not tied to one house. Still inconsistent — most transitions tested don't show
  it. `get_local_state()` should still guard against a one-frame outlier around any map/mode
  change on general principle.

### Emerald runningState=2 confirmed during sustained walking, and battle does not invalidate position

- Date: 2026-08-11
- Observed: user walked right through grass (`x:12→13→14`, `mapGroup=0,mapNum=16`) with
  `runningState=2` held throughout the walk — first observation of state `2`, matching
  `pokeemerald`'s own comment ("02 is moving"), distinct from the earlier-confirmed `1`
  (turning) and `0` (idle). A wild encounter then started; `base` relocated and briefly showed
  the same `(4,2,0,9)` placeholder as the house-entry glitch (see above), then corrected back
  to `(14,10,0,16)` — the same overworld tile the player was on before the fight — and held
  there for the entire battle. After the fight ended, `base` relocated once more (still
  `14,10,0,16`), `flags` returned to `0x21` (`CONTROLLABLE`) and `runningState` settled to `0`.
- Source: address/offsets from the `gSaveBlock1Ptr`/`gPlayerAvatar` entries above.
- Notes: closes the last two open Phase 1 animation-state questions (`runningState=2`,
  battle behavior). Only the running-shoes `dash` flag remains untested.

### Emerald runningState does not track forced/scripted movement, only player input

- Date: 2026-08-11
- Observed: a scripted "follow me" NPC event moved the player 6 tiles (`y:14→8`,
  `mapGroup=0,mapNum=10`), same as the earlier multi-tile forced-movement cutscene test. In
  contrast to the earlier player-walked-right test (where `runningState=2` held for the whole
  walk), here `runningState` stayed `0` for every reading despite continuous position change;
  `flags=0x01` (no `CONTROLLABLE`) throughout, consistent with the player not having input
  control during the scripted follow.
- Source: address/offsets from the `gPlayerAvatar` entry above.
- Notes: `runningState` reflects player-input movement specifically, not "position is
  currently changing" in general — a forced/scripted walk does not set it. Relevant if
  `runningState` is ever used as an animation-driving signal: it would under-report movement
  during any cutscene-driven walk.

### Emerald trainer battle also does not invalidate position

- Date: 2026-08-11
- Observed: a trainer battle (triggered by the trainer's sightline, not by talking to them)
  showed the same pattern as the earlier wild battle — position frozen at `(9,3,0,18)` for the
  whole fight, no placeholder glitch this time, `flags` returning to `0x21`
  (`CONTROLLABLE`) once the fight ended.
- Source: address/offsets from the `gSaveBlock1Ptr`/`gPlayerAvatar` entries above.
- Notes: second confirmation (after the wild encounter) that battle doesn't invalidate
  position, and another data point that the placeholder glitch is inconsistent rather than
  guaranteed on every transition.

### Emerald dash flag (running shoes) confirmed

- Date: 2026-08-11
- Observed: user got the running shoes and ran left for 9 tiles (`x:9→0`, matching the
  confirmed left=−x mapping). Throughout, `flags=0x81` (`ON_FOOT (0x01) | DASH (0x80)`),
  `dash=true`, `runningState=2`. The instant movement stopped, all three reverted cleanly to
  `flags=0x01`, `dash=false`, `runningState=0`.
- Source: address/offsets from the `gPlayerAvatar` entry above (`PLAYER_AVATAR_FLAG_DASH =
  (1 << 7)`, `global.fieldmap.h` L295).
- Notes: closes the last open Phase 1 animation-state question. All planned `flags`/
  `runningState` behavior for Phase 1 is now confirmed except bike/surf (deferred — far into
  the game, not blocking).

### Emerald dash and runningState toggle independently mid-movement

- Date: 2026-08-11
- Observed: user walked left while repeatedly tapping/releasing the run button. `runningState`
  stayed `2` continuously for the whole walk (only `1` at the very first step, `0` once fully
  stopped), while `dash`/`flags` bit 7 flipped `true`/`false` multiple times in between without
  ever interrupting `runningState=2`.
- Source: address/offsets from the `gPlayerAvatar` entry above.
- Notes: confirms `dash` and `runningState` are independent bits, not a paired state machine —
  useful for `anim` tag design (they can be read/combined separately rather than needing a
  single enumerated "movement state").

### Emerald gObjectEvents address and facing direction confirmed

- Date: 2026-08-11
- Observed: `grep -i gObjectEvents pokeemerald.map`/`.sym` both gave `0x02037350`, size
  `0x240` — matching `OBJECT_EVENTS_COUNT (16) * sizeof(struct ObjectEvent) (0x24)` exactly,
  same cross-check pattern as the earlier addresses. Then, reading
  `u16 @ (0x02037350 + objectEventId*0x24 + 0x18) & 0xF` (`objectEventId` from
  `gPlayerAvatar+0x05`): facing down at script load gave `1`; facing left, up, right, down in
  sequence gave `3, 2, 4, 1`. All four match `DIR_WEST=3, DIR_NORTH=2, DIR_EAST=4,
  DIR_SOUTH=1` from `constants/global.h` exactly.
- Source: `pret/pokeemerald` build artifacts (address); `include/global.fieldmap.h` L194-256
  (`struct ObjectEvent`, `facingDirection:4` at `+0x18`) and L371
  (`extern struct ObjectEvent gObjectEvents[OBJECT_EVENTS_COUNT];`); direction values from
  `include/constants/global.h` L137-141.
- Notes: the bitfield-packing assumption (facingDirection in the low 4 bits of the u16 at
  `+0x18`) was not guaranteed by the C standard and needed exactly this kind of on-screen
  check — it turned out correct. This closes the facing-direction question feeding the
  `orientation`/`anim` decision in `agent_docs/contract.md`. **Scope: vanilla ROM only** — see
  the entry below, "Superseded by" note.
- **Superseded by** (for an Archipelago-patched ROM specifically, not vanilla): "Archipelago-
  relocated gObjectEvents/gPlayerAvatar found and fixed" — the base address above does not hold
  on that ROM family; a live-detected offset is required instead.

### Emerald seamless town/route connections can transiently report out-of-bounds coordinates

- Date: 2026-08-11
- Observed: crossing a town↔route map connection (not a door warp — Emerald scrolls
  seamlessly between connected outdoor maps) in both directions.
  Town→route: `(11,20,0,16)→(11,19,0,16)`, clean, `mapNum` changed correctly, no glitch.
  Route→town: `(11,-1,0,9)→(11,0,0,9)` — **`y=-1`** for one frame right at the boundary,
  before settling to `y=0`. `mapGroup`/`mapNum` were already correct (`0,9`) on that same
  glitched frame, unlike the door-warp placeholder glitch where the map fields were also
  wrong.
  `facingDirection` tracked correctly throughout both crossings (`2`=north walking into route,
  `1`=south walking back into town).
- Source: address/offsets from the `gSaveBlock1Ptr`/`gPlayerAvatar` entries above.
- Notes: a second, distinct kind of transient edge case from the door-warp placeholder glitch
  — here only `y` briefly goes out of the map's valid range (negative) at a connection seam,
  while `mapGroup`/`mapNum` stay correct throughout. Reinforces the same practical guidance:
  debounce a frame around any map-adjacent reading rather than trusting every single frame
  uncritically, but confirms it's specifically boundary coordinates that can wobble here, not
  the map identity.

### Archipelago-patched ROM: SaveBlock1 fields hold, PlayerAvatar/ObjectEvents fields do not

- Date: 2026-08-11
- Observed: user ran `connector_bizhawk_generic.lua` (from
  `C:\dev\Archipelago\data\lua\connector_bizhawk_generic.lua`) and
  `adapters/emulator/pokemon/emerald/probes/phase1_probe.lua` together in the same BizHawk Lua Console, against an
  Archipelago-patched Emerald ROM (`.apemerald` patch generated from the user's own
  `Pokemon Emerald.yaml`, applied via `ArchipelagoLauncher.exe`), on a save already past
  getting the running shoes. Both scripts loaded and ran without conflict; the connector
  reported "Client connected" successfully — satisfies the coexistence-risk check for the
  real connector, not just placeholder scripts.
  Position/map tracked correctly: standing still, then one tap each of left/up/right/down
  produced `(10,9)→(9,9)→(9,8)→(10,8)→(10,9)`, matching the vanilla-confirmed direction
  mapping (left/right = x∓1/±1, up/down = y∓1/±1) and returning to the start tile, with
  `mapGroup=0,mapNum=9` constant throughout.
  `flags`, `runningState`, and `facingDirection` did NOT track real state: they read
  `0xFF`/`255`/`15` (all-ones on each field, the signature of reading an address whose
  contents aren't the expected struct) on the very first line printed after connecting, and
  stayed exactly `0xFF`/`255`/`15` through all four moves above — including while dash was
  held and the facing direction visibly changed on screen. `objEventId=3` stayed constant too
  and can't be independently checked from this data.
- Source: addresses/offsets are the same `gSaveBlock1Ptr` (`0x03005D8C`), `gPlayerAvatar`
  (`0x02037590`), and `gObjectEvents` (`0x02037350`) entries cited above, all sourced from a
  vanilla-ROM `pokeemerald` build; not re-derived against the patched ROM's own build (the
  patched ROM isn't a `pokeemerald` checkout the user can rebuild and `make compare`).
- Notes: **the Archipelago patch appears to shift or otherwise invalidate the fixed
  `gPlayerAvatar`/`gObjectEvents` addresses, while the `gSaveBlock1Ptr`-relative fields
  (position, map) remain correct.** This tracks with `gSaveBlock1Ptr` being a *pointer*
  re-read fresh every frame versus `gPlayerAvatar`/`gObjectEvents` being *fixed* addresses —
  a patch that inserts or removes code/data changes what ends up at a fixed EWRAM offset far
  more easily than it changes where a runtime-allocated pointer target lands. Not yet
  determined: the correct fixed addresses for this patched build (would need the AP world's
  own base-ROM diff or a decomp-equivalent build of the patched ROM, neither attempted here),
  or whether every Archipelago Emerald patch shifts these the same way or only this
  particular player's patch. Practical takeaway for `contract.md`: an adapter targeting
  Archipelago-coexistent play cannot trust `gPlayerAvatar`/`gObjectEvents` addresses learned
  from a vanilla-ROM decomp build without re-deriving them per patch; position/map reads are
  unaffected. Performance: user reported 0 noticeable difference running both scripts
  together vs. the probe alone (no stutter, lag, or console slowdown). Reproduced again
  separately with mixed running/walking (left, `x` 9→1, one tile per print) — same frozen
  `flags`/`runningState`/`facingDirection` values, no new information.
- **Reproduced again, 2026-08-14, on a second, independent Archipelago-patched ROM/seed**
  (`0x080867F1` CB2_Overworld one), `phase1_probe.lua` loaded alongside the real
  `meshghost_emerald.lua` adapter: same exact frozen signature throughout ~28 tiles of real
  movement (`flags=0xFF dash=true runningState=255 objEventId=3 facingDirection=15`, never once
  changing), while `x`/`y`/`mapGroup`/`mapNum` tracked every step correctly. Confirms this isn't
  a one-seed fluke. **New consequence traced this session**: `playerScreenPos()`
  (`meshghost_emerald.lua:633`) reads a sprite index from `GPLAYERAVATAR_ADDR + 0x04` — the same
  struct, an offset not printed by `phase1_probe.lua` so not directly observed here, but
  adjacent to the confirmed-garbage `flags`/`runningState`/`objEventId` fields — then indexes
  into `gSprites[]` with it to find the local player's own screen anchor, which every remote
  ghost is drawn relative to. Live-observed symptom matching this exactly: a loopback ghost that
  spawns at a different fixed screen location each script restart, jitters slightly when the
  local player moves (from the real, correctly-tracking `x`/`y` feeding the position-delta half
  of the draw formula) but never actually follows — consistent with a wrong-but-constant screen
  anchor. Circumstantial, not a direct read of the `+0x04` byte itself — see the open item in
  `risks.md`.

### Emerald Phase 2 ghost overlay renders and tracks the player near screen center

- Date: 2026-08-11
- Observed: `adapters/emulator/pokemon/emerald/probes/phase2_ghost.lua` loaded in BizHawk's Lua Console against the
  same Emerald ROM/save used for Phase 1, standing outside in Littleroot Town. The 16x16
  magenta placeholder image (`adapters/emulator/pokemon/emerald/assets/ghost_placeholder.bmp`) rendered on
  screen at the expected position — up and to the right of the player sprite, consistent with
  the script's hardcoded `(+16,-16)` offset — and moved together with the player while
  walking, holding that same relative offset rather than staying fixed on screen or lagging.
- Source: address/offsets/formula from the `phase2_ghost.lua` header (see script), all
  ultimately from the same `pokeemerald` build cited in the Phase 1 entries above.
- Notes: confirms `gui.drawImage` itself works from this script and that the screen-position
  formula (`sprite.x + x2 + centerToCornerVecX + gSpriteCoordOffsetX`, same for Y) is at least
  correct near screen center, where the camera is actively scrolling to keep the player
  centered. **Not yet confirmed:** behavior at a map edge, where the camera stops scrolling
  and the player's own on-screen position moves away from center — this is the case that
  would actually catch a formula mistake that happens to look right near center. See
  `agent_docs/phases/phase2.md` for that remaining task.

### Emerald Phase 2 ghost offset survives map transitions (house entry, route change)

- Date: 2026-08-11
- Observed: with `phase2_ghost.lua` running, the user entered a house and separately crossed
  into another route. In both cases the ghost held its offset correctly relative to the player
  once the new map rendered — no visible snap to a wrong position, no lingering at the old
  location, no disappearance. Both screenshots show the player still screen-centered (camera
  re-centers after a transition), so this is a different case from the still-open map-edge
  test, not a substitute for it.
- Source: same address/offsets/formula as the entry above.
- Notes: relevant because `gSaveBlock1Ptr` (and by extension the whole read chain, including
  `gSprites`) was already shown in Phase 1 to relocate in EWRAM during exactly these kinds of
  transitions — this confirms the Phase 2 read chain tolerates that relocation cleanly, same
  as Phase 1's position/map reads did. Still open: the map-edge/camera-boundary case where the
  player is off-center on screen, which neither this nor the screen-center tracking test above
  exercises.

### Emerald cold boot (title screen → intro → save load) shows a zero-placeholder frame and a lagging facingDirection

- Date: 2026-08-11
- Observed: user loaded `phase1_probe.lua` before the ROM was even running a save — rebooted,
  sat through the intro cutscene, the main menu, and into the game. Sequence printed:
  `gSaveBlock1Ptr is null` (title/menu, no save loaded) →
  `base=0x02025A44 x=0 y=0 mapGroup=0 mapNum=0 flags=0x00 facingDirection=0` (one frame, right
  as `base` first goes non-null) →
  `base=0x02025A44 x=10 y=9 mapGroup=0 mapNum=9 flags=0x00 facingDirection=0` (position/map now
  correct, but `facingDirection=0` — not a valid `DIR_*`, which only runs 1–4) →
  `base=0x02025A10 ... facingDirection=3` (base relocates again; `facingDirection` now valid) →
  `base=0x02025A10 ... flags=0x21 facingDirection=3` (settles: `PLAYER_AVATAR_FLAG_ON_FOOT
  (0x01) | PLAYER_AVATAR_FLAG_CONTROLLABLE (0x20)`).
- Source: same `gSaveBlock1Ptr`/`gPlayerAvatar`/`gObjectEvents` addresses and `DIR_*` constants
  cited above.
- Notes: not a new field for `get_local_state()` to expose — nothing outside "in-game" needs
  syncing, per the project's own scope — but two new data points for the debounce guidance
  already decided in `contract.md`: (1) the one-frame placeholder-on-relocation pattern
  previously seen only on warps/battles (as the fixed `(4,2,0,9)`) also happens on the very
  first save load, here as all-zeros instead — confirms it's a general "read during
  relocation, before the real value is written" glitch, not warp-specific or tied to one fixed
  placeholder value. (2) `facingDirection` can independently lag a frame behind
  `x`/`y`/`mapGroup`/`mapNum` becoming valid, reading `0` (invalid) after position had already
  corrected — prior transient-glitch entries only documented position/map fields going stale
  together; this shows `facingDirection` can be stale on its own frame boundary. Practical
  takeaway: the adapter-side one-frame debounce around a `mapGroup`/`mapNum` change (already
  decided in `contract.md`) should also hold off trusting `facingDirection` during that same
  window, not just position.

### Emerald Phase 2 ghost offset holds at a real camera-pinned map edge

- Date: 2026-08-11
- Observed: user stood near the edge of a small interior room (smaller than the screen — the
  camera couldn't scroll far enough to center the player, leaving black/undrawn space past the
  room's actual boundary). The player sprite was visibly off-center on screen as a result. The
  ghost still held its correct offset (up-and-right of the player) relative to the player, not
  the screen — same behavior as every screen-centered test.
- Source: same address/offsets/formula as the Phase 2 tracking entry above.
- Notes: closes the map-edge task in `agent_docs/phases/phase2.md` — this is a genuine
  camera-pinned case (small interior maps don't always have room to scroll the camera to
  center the player), distinct from every prior test where the camera was actively
  re-centering. The screen-position formula holds under it.

### Emerald Phase 2 ghost tracks the wrong thing during battle — sprite slot reuse, not a math bug

- Date: 2026-08-11
- Observed: entering a wild battle (and separately, another wild battle) with
  `phase2_ghost.lua` running, the ghost box detached from the player's last overworld position
  and instead appeared near the battle scene itself (close to the wild Pokémon's sprite), even
  though `flags`/`runningState`/`facingDirection` reads and (per Phase 1) the raw
  `gSaveBlock1Ptr`-relative position stay valid and frozen during battle. Follow-up
  observation: the box visibly moved up/down in sync with the HP/EXP bar sliding into view,
  confirming it's tracking a battle-UI sprite's slot, not floating at a fixed wrong value.
- Source: same address/offsets/formula as the Phase 2 tracking entry above.
- Notes: **not a screen-position formula bug** — the formula itself was already confirmed
  correct (see the two entries above). The likely cause: `gSprites` is a shared, dynamically
  allocated pool, and `gPlayerAvatar.spriteId` — read fresh each frame like everything else —
  stays the same index, but the overworld player sprite occupying that slot is torn down when
  battle starts, and the slot gets reused for a battle-scene sprite (the HP/EXP bar animation,
  going by the follow-up observation). Not yet root-caused beyond this hypothesis; sprite-slot
  reuse is inferred from the visible symptom, not confirmed against `pokeemerald` source for
  battle-specific sprite teardown.
- **Design conclusion (superseding this entry's earlier framing):** no battle-state read or
  gate is needed on the *data* side. `get_local_state()` already shouldn't return `nil` during
  battle (decided in `contract.md`, confirmed valid by Phase 1) — a remote player's ghost
  should simply hold still at their last overworld position while they're fighting, not
  despawn, which is the desired UX anyway (a friend's ghost shouldn't vanish just because
  they're in a fight). The actual fix is on the *rendering* side, and is simpler than "find the
  right signal to gate the sprite-slot read on": the adapter should skip all ghost drawing
  (local and remote) whenever the local player itself is in battle, since there's no overworld
  on screen to draw onto — this sidesteps the sprite-slot bug entirely rather than diagnosing
  it further, since the fix doesn't depend on why the read goes stale. Needs its own
  battle-detection signal for the adapter to gate drawing on (not yet identified/verified) —
  deferred to whichever phase first implements `render_remote` for real, since Phase 2 has no
  remote ghosts to demonstrate it with yet.

### Emerald Phase 2 ghost is stable within a map, jitters briefly crossing route/town connections

- Date: 2026-08-11
- Observed: walking around within one route or town, the ghost felt "static/stiff" — glued
  exactly to the player every frame, no visible flicker or lag. Crossing from one route/town to
  an adjacent connected one (seamless scroll, not a door warp), the ghost showed a very slight,
  barely-noticeable jitter right at the crossing, as if briefly correcting to a new position.
- Source: same address/offsets/formula as the Phase 2 tracking entries above.
- Notes: the "static/stiff" feel while walking is the *correct* result for this phase, not a
  flaw — the ghost is deliberately glued to the player with no interpolation or smoothing here;
  that's Phase 3+'s job with real network data (`internal/core`'s interpolation buffer, per the
  tick model in `agent_docs/contract.md`), not something Phase 2's hardcoded-offset test does
  or should do. The route-crossing jitter is more likely a real, already-known data hiccup
  surfacing visually rather than a new bug: Phase 1 already found that crossing exactly this
  kind of seamless map connection can transiently report an out-of-bounds coordinate
  (`y=-1` for one frame — see "Emerald seamless town/route connections can transiently report
  out-of-bounds coordinates" above) before settling. The sprite fields this phase reads
  ultimately derive from the same per-frame object-event position, so a one-frame position
  hiccup at the same seam plausibly explains the jitter. Not independently re-confirmed by
  reading the sprite fields frame-by-frame during a crossing — inferred from the matching
  location and matching "brief, one-frame, self-correcting" character of both symptoms, not a
  new root-cause investigation.

### Emerald Phase 2 ghost also glitches briefly on door-warp transitions (dips, then corrects)

- Date: 2026-08-11
- Observed: entering and exiting a house, the ghost briefly moved down before "teleporting"
  back up to the correct tracked position, only during the transition itself — same
  static/correct tracking immediately before and after.
- Source: same address/offsets/formula as the Phase 2 tracking entries above.
- Notes: same family as the route-crossing jitter above and the Phase 1 "entering a house
  transiently reads a fixed placeholder state for one frame" / "map bank/number change on a
  real map transition, and gSaveBlock1Ptr relocation" findings — door warps were already known
  to relocate `gSaveBlock1Ptr` and, on at least one tested house, transiently read a wrong
  placeholder position for exactly one frame. This is that same class of glitch now visible in
  the Phase 2 ghost's derived screen position rather than in a raw position print. Consistent
  with, not a new mechanism beyond, what Phase 1 already characterized: brief, self-correcting,
  tied to the moment `gSaveBlock1Ptr` (and by extension the object event feeding the player's
  sprite) relocates. No new adapter guidance beyond what's already decided — the existing
  one-frame debounce recommendation around a `mapGroup`/`mapNum` change (`contract.md`) covers
  visible rendering glitches too, not just data reads.

### LuaSocket (vendored) requires lua54.dll to be pre-loaded by full path before it will load

- Date: 2026-08-11
- Observed: after fixing the path bug above, a second live failure at the same
  `package.loadlib(dllPath, "luaopen_socket_core")` call, same error ("the specified module
  could not be found"). Reproduced the exact failure outside BizHawk via a direct
  `LoadLibraryW` call on the vendored `socket-windows-5-4.dll` using its correct real path —
  failed with Win32 error 126. Inspecting the DLL's PE import table showed a dependency on
  `lua54.dll`; testing that dependency's resolvability alone (bare-name `LoadLibraryW`) also
  failed. Confirmed the fix: explicitly `LoadLibraryW`-ing `lua54.dll` by its own full path
  immediately before loading `socket-windows-5-4.dll` made the second call succeed — Windows
  reuses an already-loaded module of the same name for later dependency resolution regardless
  of which directory either came from. Placing a copy of `lua54.dll` next to
  `socket-windows-5-4.dll` without the explicit pre-load did **not** fix it on its own, since
  plain `LoadLibrary`'s dependency search order does not include the loading DLL's own
  directory.
- Source: `socket-windows-5-4.dll`'s own PE import table (read directly via a PowerShell byte
  scan, not assumed); `lua/lua` `loadlib.c` (`lsys_load` calls `LoadLibraryExA` with
  `LUA_LLE_FLAGS`, default `0`); confirmed empirically against the real vendored files at
  their real paths (`adapters/emulator/pokemon/emerald/lib/x64/`) with a direct PowerShell `LoadLibraryW` test
  before asking for a live retry.
- Notes: the vendored `lua54.dll` is a byte-for-byte copy of the one already running inside the
  user's BizHawk install (`C:\ProgramData\Archipelago\Bizhawk\dll\lua54.dll`, matching hash),
  not an independent build — confirmed genuine unmodified upstream Lua 5.4.4 by reading its
  embedded copyright string (`Copyright (C) 1994-2022 Lua.org, PUC-Rio`). See
  `agent_docs/licensing.md` and the Phase 3 ADR in `agent_docs/architecture.md`.

### adapters/emulator/pokemon/emerald/probes/phase3_loopback.lua did not detect its own bridge connection dying

- Date: 2026-08-11
- Observed: after the `internal/core` fix above, killing the *core* process (as opposed to the
  relay) still left the ghost frozen — with zero new Lua console output, meaning the disconnect
  wasn't even being detected. Root cause: `drainBridge()`'s error handling special-cased
  `err == "closed"` as the only trigger for cleanup, treating any other error string from
  `sock:receive()` as a harmless timeout. Whatever LuaSocket actually reports for a forcibly-
  terminated peer process fell through unnoticed. Fixed by inverting the check — `"timeout"` is
  now the only value treated as harmless, everything else triggers `resetBridge()` and clears
  the local `remotes` table — confirmed live: killing the core now makes the ghost disappear
  immediately and logs "MeshGhost Phase 3: bridge connection lost, will retry connecting."
- Source: `adapters/emulator/pokemon/emerald/probes/phase3_loopback.lua` (`drainBridge`).
- Notes: `sendLine`'s equivalent check (`if not ok and err ~= "timeout"`) was already written
  the safe way round; only `drainBridge`'s was inverted.

### Phase 3 loopback: full round trip confirmed, ghost trails the player correctly

- Date: 2026-08-11
- Observed: with `meshghost-relay -loopback` and `meshghost -game=emerald -interp=200ms`
  running and `phase3_loopback.lua` attached, a ghost was visible on screen consistently
  trailing the player by about one tile, holding steady whether walking or running and across
  route/town and house transitions (the same cases Phase 1/2 previously found transient
  glitches in) — no drift, no overshoot, confirming `TILE = 16` (the pixel-per-tile constant in
  the ghost's placement formula) is correct rather than merely assumed. No flicker observed
  across the full session, including after `gui.clearGraphics()` was added unconditionally
  every frame (see the entry above). Separately (before the disconnect-handling fixes above
  were in place), the frozen ghost was seen scrolling fully off-screen as the player walked away
  and reappearing on walking back — confirming the ghost is placed at a real world coordinate
  that BizHawk's own viewport culling naturally hides/reveals, not something screen- or
  player-relative, which stands as evidence the tile-delta placement formula holds even where
  the player's on-screen anchor position isn't centered (the risk Phase 2's own map-edge test
  targeted for the player's own anchor).
- Source: `adapters/emulator/pokemon/emerald/probes/phase3_loopback.lua` (`drawRemotes`, the
  `playerScreenPos() + (remote - player) * TILE` formula); `internal/relay`'s `-loopback` flag;
  `internal/core`'s interpolation buffer.
- Notes: this is the Phase 3 milestone from `agent_docs/plans.md` — a client sending its own
  state through a real relay and rendering its ghost trailing itself, over the real Go
  networking layer, not a same-process shortcut. Battle-drawing-skip gating remains deferred
  per Phase 2's decision (no verified battle-detection signal yet); vanilla ROM only, per
  `agent_docs/risks.md`'s Archipelago-coexistence entry.

### Phase 4: two real BizHawk/Emerald instances render each other's ghosts correctly

- Date: 2026-08-11
- Observed: one `meshghost-relay` (no `-loopback`), two `meshghost.exe` cores
  (`-bridge=127.0.0.1:7778 -name=player1`, `-bridge=127.0.0.1:7779 -name=player2`), two
  `EmuHawk.exe` instances each running `adapters/emulator/pokemon/emerald/probes/phase4_multiplayer.lua` with
  `MESHGHOST_BRIDGE_PORT` set to the matching port. Each client showed a ghost tracking the
  other's real, independent movement — the first time this project has exercised a real second
  physical peer rather than the relay's synthetic `-loopback` echo.
- Source: `adapters/emulator/pokemon/emerald/probes/phase4_multiplayer.lua`; `internal/relay`, `internal/core`
  (unmodified from Phase 3).
- Notes: no drift or flicker reported during normal movement, though the placeholder
  magenta-box art makes subtle stutter hard to judge by eye — a real sprite would give a more
  sensitive check. Both clients landed in the same room automatically via matching `-room`
  defaults (`default`).

### Phase 4: unclean core kill (Task Manager End Task) also despawns correctly, and the killed peer's own adapter detects it

- Date: 2026-08-11
- Observed: killing `player2`'s (reconnected as `p3`) core process via Task Manager's End Task
  (not a graceful window close) still made the ghost disappear instantly on `player1`'s screen
  — the relay's console logged a `connection error: ... wsarecv: An existing connection was
  forcibly closed by the remote host` at the same moment. `p3`'s own BizHawk console also
  logged `MeshGhost Phase 4: bridge connection lost, will retry connecting.`, confirming its
  adapter independently detected its own core dying.
- Source: same as the two entries above; `adapters/emulator/pokemon/emerald/probes/phase4_multiplayer.lua`
  (`drainBridge`'s error handling, carried over unchanged from the Phase 3 fix).
- Notes: this is the real-second-peer generalization of two things Phase 3 only tested against
  the loopback synthetic peer or self-inflicted disconnects: (1) the relay correctly detects an
  abrupt, non-graceful TCP drop from a *remote* peer and broadcasts `Leave`, and (2)
  `drainBridge`'s Phase 3 fix (treating anything but `"timeout"` as fatal) holds for a real
  forcibly-killed core, not just the original bug's reproduction case.

### Phase 4: local-battle ghost-anchor corruption confirmed with a real remote ghost, matching Phase 2's prediction exactly

- Date: 2026-08-11
- Observed: with `player2` in a wild battle, `player1`'s screen correctly showed `player2`'s
  ghost frozen at the overworld tile the battle was entered from (expected — overworld position
  doesn't change during a battle). `player2`'s own screen, however, showed `player1`'s ghost
  drifting incorrectly — tracking `player1`'s real movement, but anchored to a position that
  also moved up/down in sync with the battle's HP/EXP bar sliding into view.
- Source: same root cause as the Phase 2 entry "Emerald Phase 2 ghost tracks the wrong thing
  during battle — sprite slot reuse, not a math bug" — `playerScreenPos()` in
  `adapters/emulator/pokemon/emerald/probes/phase4_multiplayer.lua` reads the same `gSprites[gPlayerAvatar.spriteId]`
  anchor, now shown corrupting *remote* ghost placement on the affected client's own screen, not
  just a local hardcoded-offset ghost.
- Notes: confirms Phase 2's design conclusion still holds and is now demonstrated with a real
  `render_remote` ghost as that entry anticipated: the fix is skipping all ghost drawing on a
  client while *that client's own* player is in battle, not despawning or altering data for the
  player who's fighting. Still needs a verified battle-state detection address before
  implementing — not looked up yet.

### Emerald gMain.callback2 / CB2_Overworld confirmed as a general "not showing the overworld" signal

- Date: 2026-08-11
- Observed: with `adapters/emulator/pokemon/emerald/probes/battle_probe.lua` printing `gMain.callback2` on change,
  standing in the overworld read a constant `0x08085E5D`. Starting a wild battle produced a
  sequence of different values (`0x08085E51`, `0x08036761`, `0x08036FAD`, `0x08038421`, ...)
  through the battle, returning to `0x08085E5D` after running away. Opening each pause-menu
  submenu in turn — Pokédex, Bag (tested twice, worded "pokemon bag" and "inventory/bag" by the
  user), Player Card, Options — each produced its own distinct non-`0x08085E5D` value on open
  and a consistent `0x08086195 → 0x080860F5 → 0x08085E5D` sequence on close. Talking to a plain
  NPC printed nothing at all — `callback2` never left `0x08085E5D`.
- Source: `gMain` struct address `0x030022C0` (`pokeemerald.map`/`.sym`, size `0x43C` matches
  `struct Main`); `callback2` field at `+0x004` (`include/main.h` L11); `CB2_Overworld` address
  `0x08085E5C` (`pokeemerald.map`/`.sym`), the callback for ordinary field play
  (`src/overworld.c` L1484).
- Notes: **the live value is `0x08085E5D`, i.e. `CB2_Overworld`'s address with the GBA
  Thumb-mode bit set** — confirmed rather than assumed, closing the one open question from the
  probe script's header. More importantly, this address distinguishes "the overworld screen is
  not currently being shown" in general, not "in battle" specifically — every full-screen
  pause-menu submenu triggers it exactly like battle does, while an overlay (NPC dialogue, and
  by inference the base pause-menu list and other overlays already confirmed in Phase 1/2) does
  not. This generalizes and supersedes the "battle-detection address" framing from Phase 2's
  deferred item — the real, simpler question was "is the overworld even on screen," and battle
  is just one case of that. **Scope: vanilla ROM only** — see the entry below, "Superseded by"
  note.
- **Superseded by** (for an Archipelago-patched ROM specifically, not vanilla): "Archipelago-
  recompiled CB2_Overworld address found, closing the ghost-never-renders gap" — `0x08085E5D`
  does not hold on that ROM family; a different, live-cited address is required instead.

### phase4_multiplayer.lua's overworld gate correctly hides/reshows remote ghosts, per-viewer only

- Date: 2026-08-11
- Observed: wired the `gMain.callback2 == CB2_Overworld` (or `+1`) check from the entry above
  into `phase4_multiplayer.lua`, skipping `drawRemotes()` whenever false. Confirmed live: a
  client's screen showed no ghost at all while that client's own player was in battle (previously
  showed the broken drifting-with-the-HP-bar box, see the entry above) or in any pause-menu
  submenu, and the ghost reappeared correctly, tracking normally, once back in the overworld —
  tested after both a battle and cycling through all four submenus. Confirmed the gate is
  strictly per-viewer: while one client had a submenu open, the *other* client kept seeing that
  player's ghost the entire time (correctly held at its last position, same "holds still, not
  despawned" behavior as any other stationary remote) — a remote's own menu/battle state never
  affects whether the local client draws it.
- Source: `adapters/emulator/pokemon/emerald/probes/phase4_multiplayer.lua` (`inOverworld`, gating the `drawRemotes`
  call in the main loop).
- Notes: closes the deferred battle-skip-gating item from Phase 2/3/4 for real. NPC dialogue
  was not independently re-tested with the gate wired in (only with the standalone probe above)
  but is not expected to differ, since the underlying signal is identical.

### phase4_multiplayer.lua's remote ghost placement needed a one-tile vertical correction

- Date: 2026-08-11
- Observed: with two real peers on the same tile (one directly beside the other), the ghost
  rendered one tile above the actual player position — confirmed via screenshot showing the box
  inside a tree one row above where the remote player was actually standing, with horizontal
  placement already correct. Added `GHOST_Y_CORRECTION = TILE` (16px) to `drawRemotes`'s
  `screenY` calculation; confirmed live afterward the ghost renders directly on the correct
  tile.
- Source: `adapters/emulator/pokemon/emerald/probes/phase4_multiplayer.lua` (`drawRemotes`); root cause per
  `phase2_ghost.lua`'s header citation of `pokeemerald`'s `event_object_movement.c`
  (`UpdateObjectEventOffscreen`) — `playerScreenPos()` returns the sprite's top-left bounding-box
  corner, not the tile the player stands on, and overworld character sprites are taller than one
  tile.
- Notes: the exact `TILE`-sized (16px) correction was a first guess based on GBA overworld
  sprites commonly being 16x32, not independently re-derived from source — it's confirmed
  correct by the on-screen result, not by re-checking the sprite dimensions directly. Phase 2's
  own local-anchor ghost never hit this because it used a different, deliberately
  arbitrary-looking hardcoded offset `(+16,-16)` rather than trying to land exactly on the
  player's tile.

### Emerald base pause-menu list does not trigger the overworld gate — accepted, not a bug

- Date: 2026-08-11
- Observed: opening the top-level pause menu (the POKéDEX/POKéMON/BAG/.../EXIT list, before
  selecting a submenu) does not change `gMain.callback2` away from `CB2_Overworld`, consistent
  with dialogue and unlike every full-screen submenu. Visible consequence: a remote ghost can
  render directly on top of this list's text if the player happens to be positioned there on
  screen.
- Source: same `inOverworld()` gate as the entry above.
- Notes: user's explicit call, not a bug — the base pause menu is still genuinely "in the
  overworld" per the same signal that correctly ungates NPC dialogue, so gating it too would be
  inconsistent with that reasoning; the overlap is minor, rare (only near the menu's fixed
  screen position), and not worth chasing given how narrow the case is. Left as-is
  deliberately.

### gObjectEventPic_BrendanNormal / gObjectEventPal_Brendan decode to a real Brendan sprite

- Date: 2026-08-11
- Observed: `adapters/emulator/pokemon/emerald/probes/sprite_probe.lua` read `gObjectEventPic_BrendanNormal`
  (`0x084975F8`) and `gObjectEventPal_Brendan` (`0x084987F8`), decoded frame 0 (4bpp, 2x4
  tiles) and the 16-color BGR555 palette, and printed both. The palette resolved to a coherent
  light/mid/dark trainer palette (skin tones at indices 1-3, blue shading at 5-8, greens at
  10-11, red/orange at 12-13, black outline at 15) rather than noise, and the decoded frame's
  ASCII silhouette read top-to-bottom as a recognizable head/hat, a two-pixel "eyes in a skin
  band" pattern at row 20, a red/orange collar at rows 23-26, and two separated leg shapes at
  row 31. User compared this directly against a screenshot of their own in-game Brendan sprite
  (red cap, dark jacket, light/green hair visible under the cap matching palette indices
  10-11) and confirmed it matches.
- Source: `pret/pokeemerald`, same `make compare`-verified build as every other address in this
  file. `gObjectEventPic_BrendanNormal`/`gObjectEventPal_Brendan` addresses and sizes from
  `pokeemerald.sym`; frame dimensions (2x4 tiles) from
  `src/data/object_events/object_event_pic_tables.h`'s `sPicTable_BrendanNormal`; uncompressed
  format (`.4bpp`/`.gbapal`, not `.lz`) from
  `src/data/object_events/object_event_graphics.h`'s `INCGFX_U32` calls.
- Notes: this is Phase 5.5 Step 1 (`agent_docs/phases/phase5_5.md`) — confirms the sprite data
  is raw and uncompressed as expected (no LZ77 decode needed) and that the 4bpp tile-decode
  math in `sprite_probe.lua` is correct, before building any on-screen rendering on top of it.
  **Scope: vanilla ROM only** — see the entry below, "Superseded by" note.
- **Superseded by** (for an Archipelago-patched ROM specifically, not vanilla): "Archipelago-
  patched ROM: gObjectEventPic_BrendanNormal/gObjectEventPal_Brendan decode to garbage, not a
  real sprite" — the addresses above decode to noise on that ROM family; a different offset,
  found via direct ROM-byte comparison, is required instead.

### gui.drawPixel color format is 0xAARRGGBB, not 0xRRGGBBAA — and the decoded sprite renders correctly on screen

- Date: 2026-08-11
- Observed: `adapters/emulator/pokemon/emerald/probes/sprite_ghost_test.lua`, drawing the same decoded frame from the
  entry above via `gui.drawPixel` (214 opaque pixels/frame) at a fixed offset from the local
  player, produced a correctly-colored, recognizable Brendan sprite on screen (cap, hair,
  jacket colors all correct) — confirmed by the user via screenshot, tracking the player as
  they moved. This confirms the color-channel packing fix made before this test: BizHawk's
  `gui.drawPixel` integer color argument is `0xAARRGGBB` (alpha in the high byte), not
  `0xRRGGBBAA` as initially assumed from pattern-matching other scripts' example color
  constants — the initial assumption would have produced wrong or invisible colors.
- Source: `src/BizHawk.Client.Common/lua/NLuaTableHelper.cs`'s Lua-integer-to-color conversion
  (`Color.FromArgb((int)l)`, .NET's `Color.FromArgb(int)` being alpha-high-byte by definition),
  cross-checked against `Assets/Lua/_docs_luacats/classes.d.lua`'s `color` alias doc comment
  ("Number in the format `0xAARRGGBB`") — both read via `gh api`/`gh search code` against
  `TASEmulators/BizHawk` (MIT, already an approved reference in `agent_docs/licensing.md`).
- Notes: this is Phase 5.5 Step 2. The sprite is still static (no facing/animation yet, Step 3)
  and not yet wired into real remote rendering (still Phase 4's magenta box in the actual
  multiplayer script) — this only proves decode-then-draw works on screen at all.

### Emerald player movement: 16 frames/tile walking, 8 frames/tile running

- Date: 2026-08-11
- Observed: a temporary diagnostic in `phase5_5_sprite.lua` printed the real frame gap between
  every consecutive `gSaveBlock1Ptr` pos.x/y tile-coordinate change while the user walked and
  ran around live in BizHawk. Walking gaps were consistently `16`; running gaps were
  consistently `8`; both repeated many times in a row with no drift. A handful of outlier
  values (12, 17, 25 frames) occurred right at genuine transitions — direction changes, the
  step right after unblocking from a wall — which is a property of that specific step, not
  evidence the steady-state number is wrong. Separately, values in the hundreds occurred after
  standing idle for a while (the gap between the last real step and the next one, not a step
  duration at all) and were correctly excluded from consideration.
- Source: live measurement against the running game (BizHawk + this project's own Lua
  instrumentation), not `pokeemerald` source — this is a timing/behavior fact, not a memory
  address, so there's no struct field to cite; it's the kind of fact this project's
  verification standard exists to require actually watching rather than assuming from general
  GBA-Pokemon community knowledge of "16 frames per tile" conventions.
- Notes: used in Phase 5.5's sub-tile position smoothing (`smoothPosition` in
  `phase5_5_sprite.lua`) to interpolate a remote's position between real tile-grid samples at
  the correct real-world pace instead of guessing — earlier guesses (a flat 8, then an
  adaptive self-measurement) both produced visible artifacts (choppy/paused motion, and
  lag/snapping right at transitions) before this was actually measured. `object_event_anims.h`'s
  `sAnim_GoSouth`/`sAnim_GoFastSouth` etc. hold each of a 4-pose walk cycle for 8/4 frames
  respectively — 4 poses × 8 (or 4) frames = 32 (or 16) frames — consistent with a full walk
  cycle covering 2 tiles at this measured per-tile rate, not a contradiction.

### Phase 5.5 Step 3: remote ghost facing and walk/run animation confirmed live with two real peers

- Date: 2026-08-11
- Observed: `adapters/emulator/pokemon/emerald/probes/phase5_5_sprite.lua` run on two real BizHawk/Emerald instances
  (same two-core/two-relay-client setup as Phase 4). User confirmed: a remote's ghost faces
  all four directions correctly without needing to move a tile first, walking one tile or
  walking around continuously looks correct, and — after the sub-tile position-smoothing fixes
  above — a stationary remote no longer wobbles on a moving viewer's screen, and a moving
  remote no longer looks choppy/teleport-y, including at direction changes, wall bumps, and
  stopping while running. Ledge jumps, Mach Bike, Acro Bike, and Surfing are explicitly not
  covered (see `agent_docs/phases/phase5_5.md`'s deferred-scope note) and still look rough —
  expected, not a regression.
- Source: `adapters/emulator/pokemon/emerald/probes/phase5_5_sprite.lua` (`advanceAnim`, `drawSpriteFrame`,
  `smoothPosition`); frame-index/duration citations from `object_event_anims.h` as in the
  Phase 5.5 Step 1/2 entries above.
- Notes: this is the Phase 5.5 Step 3 milestone. Two real bugs were found and fixed live
  during this test beyond the step's original scope: (1) sub-tile position smoothing (see the
  "16 frames/tile walking, 8 frames/tile running" entry above) and the follow-up fix locking
  each step's interpolation duration at commit time rather than re-deriving it from the
  current `anim` every frame (which caused snapping whenever `anim` changed mid-glide, e.g.
  stopping while running); (2) a stale-remotes bug where restarting a core process without
  restarting its adapter left an old peer's ghost on screen alongside the new one, fixed by
  clearing the adapter's local `remotes` table on a fresh bridge reconnect.

### Emerald running uses a genuinely separate pic table, not a faster walk cycle

- Date: 2026-08-11
- Observed: an earlier version of `phase5_5_sprite.lua` reused the walk pic table's frames for
  running (just cycled faster), and the user reported live that a real remote's running looked
  like "walking, but fast" rather than a real running pose (head bent forward, arms pumping) —
  contradicting that implementation. Rewired to decode `gObjectEventPic_BrendanRunning`/
  `_MayRunning` (a separate 9-frame pic table) with per-pose durations `{5,3,5,3}` instead of
  reusing the walk table's frames at `{8,8,8,8}`/`{4,4,4,4}`. User confirmed live afterward,
  from the other client's screen: running now looks correct — not choppy, and visibly a real
  running animation, not fast-walking.
- Source: `pret/pokeemerald`, same `make compare`-verified build as every other address in this
  file. `gObjectEventPic_BrendanRunning` = `0x08497EF8`, `gObjectEventPic_MayRunning` =
  `0x084A3978` (both size `0x900`, same 9-frame/256-byte-per-frame layout as the walk tables).
  Referenced by `src/data/object_events/object_event_anims.h`'s `sAnim_RunSouth`/`RunNorth`/
  `RunWest`/`RunEast`, which use combined pic-table indices 9-17 in `sPicTable_BrendanNormal`
  (`object_event_pic_tables.h`) — i.e. the running table's own local frames 0-8. Per-pose
  durations read directly from `sAnim_RunSouth`'s `ANIMCMD_FRAME(12,5),(9,3),(13,5),(9,3)`.
- Notes: this corrects an earlier wrong assumption (recorded only in code comments, never in
  this file) that the `ANIM_STD_GO_FAST/FASTER/FASTEST` tiers governed on-foot Running Shoes
  dashing — checked all four of those tiers directly and they all reuse the walk table's frame
  indices, only duration changes; they are unrelated to dashing (`sPlayerAvatarGfxIds` in
  `field_player_avatar.c` confirms dashing never changes `graphicsId`, so the separate running
  pose must come from a different mechanism — `sAnim_RunSouth`/etc, found by searching for
  `MovementAction_PlayerRun*` instead). A user-supplied ripped fan spritesheet prompted
  re-checking this, but was not used as a data source — the frames drawn are decoded from the
  ROM at runtime, per `agent_docs/licensing.md`.

### Phase 5.5 Step 4: gender-correct remote rendering confirmed live, and every Phase 1/2 address re-verified on a female save

- Date: 2026-08-11
- Observed: two real BizHawk/Emerald instances, one on an existing male save, one on a newly
  started female save, both running `phase5_5_sprite.lua`, joined to the same relay room.
  Console confirmed each client's own gender read correctly (`local gender = male` /
  `local gender = female`, from `gSaveBlock2Ptr->playerGender`). On screen: the male-save
  client's ghost for the female remote is a real May sprite (correct palette — light/green
  hair, distinct from Brendan's); the female-save client's ghost for the male remote is a real
  Brendan sprite. User confirmed both directions via screenshots. Separately, on the female
  save: position tracking, walking, facing, and area (both correctly in Littleroot Town)
  through `gSaveBlock1Ptr`/`gPlayerAvatar`/`gObjectEvents`/`gSprites`/
  `gSpriteCoordOffsetX/Y` — every address Phase 1/2 confirmed only on a male save — all worked
  correctly on this female save too. Running specifically wasn't re-tested on the female save
  (no Running Shoes yet on that save, a game-progression limit, not a code gap — the read
  itself, `GPLAYERAVATAR_ADDR`'s flags byte, is identical regardless of which character owns
  the item).
- Source: `adapters/emulator/pokemon/emerald/probes/phase5_5_sprite.lua` (`readLocalGender`, `loadGenderFrames`,
  `drawSpriteFrame`'s gender parameter); `gSaveBlock2Ptr` = `0x03005D90`, `playerGender` at
  `+0x08` (`include/global.h` L511, `pret/pokeemerald`, same `make compare`-verified build as
  every other address in this file).
- Notes: this is the Phase 5.5 Step 4 milestone and closes the female-save-untested gap in
  `agent_docs/risks.md`. `extras.gender` required no core/relay change — `extras` was already

### Emerald first real cross-machine online session (open port, two different PCs)

- Date: 2026-08-13
- Observed: user hosted `cmd/meshghost-relay` with an open port and connected two real,
  physically separate machines — the host's own client (Emerald) locally, and a friend's
  client (Emerald) over the internet — into the same relay room. Relay log shows only
  `meshghost-relay: listening on [::]:7777`; host client log shows
  `connected to relay 127.0.0.1:7777 as p2 in room "default" (game "emerald")`; friend's
  client log shows `connected to relay MYWANIP:7777 as p1 in room "default" (game "emerald")`
  — distinct player IDs (`p1`/`p2`) in the same room, confirming both real connections joined
  together, not just two independent single-player sessions. This is the first confirmed
  proof of the client/server stack working over a real internet connection between two
  separate computers, not just on one machine via loopback.
- Source: three real session logs, `internal/meshghost emerald first online.log` (friend's
  client), `internal/meshghost.log` (host's client), `internal/meshghost-server.log` (relay) —
  all from the same 2026-08-13 22:28–22:44 session, IPs manually redacted by the user before
  sharing.
- Notes: per the agent-read-log gating already established for TEVI 6.1 above, a log line is
  sufficient confirmation for a connectivity claim like this one (distinct from a
  visual/gameplay claim, which still needs the user to watch it on screen — no ghost rendering
  was verified in this particular session, only the relay/core connection layer). Also
  confirms `internal/README.md`'s "no message type carries an IP" claim from the client
  side: the friend's log shows only the relay's IP (`MYWANIP`, which it must have to connect
  at all) and never the host's own IP, consistent with there being no peer-to-peer channel.
  Separately noted by the user as a possible gap, not yet acted on: the relay log recorded
  only its own startup line and nothing for either client connecting, joining, or
  disconnecting — worth revisiting when relay-side logging is next touched, since richer
  connect/disconnect logging would have made this exact kind of session easier to confirm from
  logs alone.

### Emerald Lua adapter sweep fixes, live-verified via loopback

- Date: 2026-08-14
- Observed: user loaded `adapters/emulator/pokemon/emerald/probes/phase5_5_sprite.lua` in BizHawk against a real
  relay/core run with `-loopback`. Confirmed on screen: the loopback-echoed ghost spawned
  correctly, and killing the client (closing BizHawk/disconnecting) despawned the ghost cleanly
  on the other side rather than leaving it stuck.
- Source: `adapters/emulator/pokemon/emerald/probes/phase5_5_sprite.lua` (the same-day sweep's fixes: partial-line
  receive/send handling, dead-socket-after-hard-error, `pcall` around the main loop, control-char
  JSON escaping — see the "same-day review/refactor sweep" ADR in `architecture.md`).
- Notes: this closes the last item from `status.md`'s 2026-08-14 sweep entry marked "not yet
  live-verified in an emulator." User confirmed this was a genuine loopback run (ghost spawn +
  clean despawn on client kill), not just a script load with no errors — satisfies `CLAUDE.md`'s
  "ran without errors is not evidence" standard. Not separately exercised in this pass: a relay
  restart mid-session (dead-socket path) or a two-real-peer (non-loopback) run — loopback spawn/
  despawn was the scenario tested.

### Real two-peer Emerald test, non-loopback (Phase 4 shape, closes the sweep's Lua-not-live-tested-outside-loopback gap)

- Date: 2026-08-14
- Observed: two real BizHawk/Emerald instances (`phase5_5_sprite.lua`), two distinct
  `meshghost.exe` cores (`-bridge` 7778/7779), one real `meshghost-relay.exe` with no
  `-loopback`. User confirmed live, both directions: each client's Lua console showed
  `knownRemotes=1`/`match=true` for the other player's id, and each BizHawk window visibly
  rendered the other player's real Brendan/May ghost sprite tracking their live movement — the
  first real (non-loopback) two-Emerald-peer test since the 2026-08-14 review/refactor sweep
  landed, and the first time this specific pipeline (bridge → core → relay → core → bridge →
  Lua render) was exercised end-to-end with two genuinely independent local processes for this
  adapter.
- Real bug found and fixed along the way, unrelated to Emerald itself: the second BizHawk
  instance was launched by double-clicking `EmuHawk.exe` directly rather than through a
  wrapper setting `MESHGHOST_BRIDGE_PORT=7779` first, so it silently fell back to the same
  default (7778) as instance 1 and both ended up talking to one core's bridge — not a MeshGhost
  code bug, but real enough to cost a long diagnostic session (temporary throttled trace
  logging added at every hop of both the Lua adapter and `internal/core`, all reverted once
  diagnosed) before the actual cause was found. See `pitfalls.md`'s new entry ("Running two
  instances of the same emulator/game silently collide on a shared default port") and
  `environment.md`'s BizHawk section for the procedural fix (per-machine gitignored
  `.local.bat` launchers that set the port explicitly).
- Source: `adapters/emulator/pokemon/emerald/probes/phase5_5_sprite.lua` (unchanged by this session —
  the diagnostic trace added to investigate was reverted, not shipped);
  `internal/core/core.go` (same — diagnostic trace added and reverted, no net code change).
- Notes: closes the "Emerald (Lua): all fixes applied ... not yet live-verified in an
  emulator" / "not separately exercised: ... a non-loopback two-real-peer run" gaps noted in
  `status.md`'s 2026-08-14 sweep entry. Relay-restart-mid-session (the dead-socket
  auto-reconnect path) still not separately exercised for this adapter.

### Gender read correctly deferred past character creation on a fresh save

- Date: 2026-08-14
- Observed: user raised a real, previously-untested gap -- `readLocalGender()` only ever runs
  once per session, gated only on `gSaveBlock1Ptr` being non-null, which is not the same as
  confirming a real save is loaded and the player has actually chosen a gender (every earlier
  gender test had a save already present). Fixed by additionally gating the read on
  `inOverworld()` (the same gate already used before drawing remotes), on the reasoning that
  character creation runs under some other `gMain.callback2` value, not `CB2_Overworld`.
  Confirmed live: user started BizHawk with an existing female save, deleted it, created a new
  save choosing male, and watched the Lua Console directly through the whole sequence -- the
  `MeshGhost: local gender = ...` line did not appear at all during the title screen, intro, or
  character-creation sequence, and printed exactly once, correctly as `male`, only once real
  gameplay began in the overworld.
- Source: `adapters/emulator/pokemon/emerald/meshghost_emerald.lua` (`readLocalGender`, its call site's
  `inOverworld()` gate).
- Notes: closes the open risk in `risks.md` (search "Gender read may resolve before a real save
  is loaded"). The rarer mid-session delete-and-remake-a-save case (no script reload) is a
  known, accepted, unfixed limitation -- see that same risks.md entry.

### Archipelago-recompiled CB2_Overworld address found, closing the ghost-never-renders gap

- Date: 2026-08-14
- Observed: found via Stage 1 of the VRAM injection investigation (`vram_probe.lua`) surfacing
  `ow=0` for a full ~29-minute real Archipelago-patched-ROM session. Diagnosed live with
  `battle_probe.lua` (raw `gMain.callback2` printer) loaded alongside the real adapter against
  the same patched ROM. User watched, isolated per action, no decomp source available for this
  build so this is confirmed by direct on-screen observation instead:
  - Standing still/idle in the overworld: exactly one value printed, `0x080867F1`.
  - Walking multiple tiles, and crossing into a different route: no new line printed at all
    (value held steady the whole time).
  - Entering a house: `0x08086965` -> `0x0813873D` -> `0x08086995` (three transient values,
    consistent with fade-out/map-load/fade-in), settling back to `0x080867F1` once inside and
    idle.
  - Leaving the same house: the identical `0x08086965` -> `0x0813873D` -> `0x08086995` ->
    `0x080867F1` sequence in reverse, and walking around inside the house beforehand held
    `0x080867F1` steady the same way outside did.
  This is the same "transient callback during a warp, then reverts to the field callback" shape
  already on record for vanilla's own `CB2_Overworld` (see the cold-boot entry above), just at a
  different address -- strong evidence `0x080867F1` is this patched build's `CB2_Overworld`
  equivalent, not a coincidental match.
- Source: `adapters/emulator/pokemon/emerald/probes/battle_probe.lua` (the diagnostic used); now also cited in
  `adapters/emulator/pokemon/emerald/meshghost_emerald.lua`'s `inOverworld()`,
  `adapters/emulator/pokemon/emerald/probes/vram_probe.lua`'s `isOverworld()`, and `battle_probe.lua` itself,
  all updated to check this address alongside the vanilla one.
- Notes: **real, previously-undocumented bug this closes**: `meshghost_emerald.lua` gates both
  local-gender resolution and remote-ghost rendering itself behind `inOverworld()`
  (`:825`/`:850` before this fix) — with only the vanilla address checked, neither would ever
  fire on this Archipelago-patched ROM, meaning ghosts would never render at all while playing
  on it. Scoped to this specific `.apemerald` base-patch version — per `risks.md`'s
  Archipelago-coexistence entry, the base patch is one static recompile shared by every seed
  (only small per-seed `write_token` calls differ), so this address should hold for every
  player on the same base-patch version, but a future Archipelago Emerald world update could
  recompile to a different one. Not yet re-verified with an actual rendered ghost on screen
  (a loopback/two-peer session with the fix applied) -- that's the next concrete check.
  **Reproduced independently on a second, unique Archipelago-patched ROM/seed (2026-08-14,
  same day)**, this time with `battle_probe.lua`'s own `looksLikeOverworld` flag updated to
  include the new address, so it read `true` directly rather than needing inference: a hard
  reset through the intro cutscene, main menu, and new-game character creation showed a series
  of other values (none matching either `CB2_Overworld` address, correctly), then
  `looksLikeOverworld=true` at `0x080867F1` the moment real gameplay began (exiting the
  starting truck). Held through the exact same `0x08086965` -> `0x0813873D` -> `0x08086995` ->
  `0x080867F1` warp sequence on entering/leaving three different houses and going
  upstairs/downstairs, and through a different, longer transition sequence for the in-room
  clock-setting menu (`0x08135F31` -> `0x081361D9` -> `0x0809F68D` -> `0x08086B65` ->
  `0x08086A8D` -> `0x080867F1`) — still settling back to the same address. This is the
  seed-independence the "static base patch" reasoning predicted, now confirmed rather than
  inferred.

### Archipelago-patched ROM: gObjectEventPic_BrendanNormal/gObjectEventPal_Brendan decode to garbage, not a real sprite

- Date: 2026-08-14
- Observed: user ran `adapters/emulator/pokemon/emerald/probes/sprite_probe.lua` against the same second,
  independent Archipelago-patched ROM/seed used for the `CB2_Overworld` confirmation above.
  Printed a 16-color BGR555->RGB palette and a 16x32 palette-index dump of decoded frame 0.
  The palette is not a plausible hand-authored sprite palette: 6 of its 16 entries (indices 0,
  3, 5, 7, 9, 11) are the exact same color (`r=239 g=115 b=189`, a pink/magenta), and 4 more
  (indices 12-15) are another single exact-duplicate color (`r=140 g=66 b=33`, brown) -- 10 of
  16 slots collapsed to two colors, which a real 16-color sprite palette (designed specifically
  to maximize distinct colors within the budget) would essentially never do. This is also a
  direct, exact match for what was independently seen rendered live in the same loopback
  session earlier the same day: a solid pink block with brown horizontal stripes, not a
  Brendan/May sprite. The bitmap itself is similarly non-humanoid -- long runs of repeated hex
  digits (`7777777`, `6666666`, `5555555`) rather than a recognizable hat/head/body silhouette.
- Source: `adapters/emulator/pokemon/emerald/probes/sprite_probe.lua`, reading `gObjectEventPic_BrendanNormal`
  (`0x084975F8`) and `gObjectEventPal_Brendan` (`0x084987F8`) -- both fixed
  vanilla-`pokeemerald`-decomp ROM addresses, never re-derived for this patch.
- Notes: upgrades the `risks.md` sprite-decode item from "confirmed broken" (inferred from what
  was visually rendered) to a direct read of the actual garbage data being decoded. Same
  mechanism as the `CB2_Overworld` finding above (a fixed vanilla ROM address landing on
  different real ROM bytes after Archipelago's recompile), applied to a different address pair.
  No replacement address found yet -- per `risks.md`, needs Archipelago's own symbol data or a
  decomp-fork build of the patched ROM to get one, the same rigor already applied to every other
  address in this project.

### Archipelago-relocated gObjectEvents/gPlayerAvatar found and fixed -- ghost confirmed following correctly on screen

- Date: 2026-08-14
- Observed: found via a real loopback session on the same Archipelago-patched ROM used for the
  sprite-decode entry above, once the sprite fix made a real (but positionally stuck) ghost
  visible for the first time. Located the real relocated addresses through a four-stage live
  investigation, all on the same ROM/seed:
  1. `adapters/emulator/pokemon/emerald/probes/avatar_scan_probe.lua` (scripted snapshot-diff): counted the
     user down through pressing and holding down, left, up, right in turn, capturing a full
     EWRAM snapshot during each hold. Kept only addresses matching the exact expected value
     (1, then 3, then 2, then 4) at every one of the four steps in order. Narrowed all 262,144
     bytes of EWRAM to exactly 2 candidates (5411 -> 8 -> 2 -> 2), 8 bytes apart
     (`0x020375EC`, `0x020375F4`).
  2. `adapters/emulator/pokemon/emerald/probes/avatar_hexdump_probe.lua`: dumped raw bytes around both
     candidates. Matched the surrounding bytes field-by-field against pokeemerald's real
     `struct ObjectEvent` layout (`include/global.fieldmap.h`) with entry base `0x020375D4`:
     `isPlayer` bit set (`+0x02`), `trackedByCamera` bit set (`+0x01`), `localId == 0xFF` =
     `LOCALID_PLAYER` exactly (`+0x08`), `mapNum == 9` / `mapGroup == 0` (`+0x09`/`+0x0A`,
     matching Littleroot Town, already independently confirmed 2026-08-11). `facingDirection`
     (`+0x18`) is `0x020375EC` (candidate 1, the real field); `previousMovementDirection`
     (`+0x20`) is `0x020375F4` (candidate 2 -- a real, different field that happened to also
     survive the test, 8 bytes later, exactly matching the struct's own field spacing).
  3. `adapters/emulator/pokemon/emerald/probes/avatar_array_probe.lua`: scanned 20 slots before and after
     `0x020375D4` at the confirmed 0x24-byte `ObjectEvent` stride. One slot earlier
     (`0x020375B0`) breaks the pattern completely (not the array, not the old garbage region
     either) -- confirming `0x020375D4` is index 0, the array's real start. Slots +1/+2/+3 show
     real sequential `localId` 1/2/3 (other object events on the same map). Following vanilla's
     own `gPlayerAvatar = gObjectEvents + 0x240` relationship placed a `gPlayerAvatar` candidate
     at `0x02037814`.
  4. `adapters/emulator/pokemon/emerald/probes/avatar_verify_probe.lua`: read `struct PlayerAvatar`'s real
     fields (`include/global.fieldmap.h`: `flags`/`transitionFlags`/`runningState`/
     `tileTransitionState`/`spriteId`/`objectEventId`/`gender`) from `0x02037814` while the user
     walked, dashed, and turned in every direction. `flags` toggled cleanly `0x01`<->`0x81`
     exactly with dash; `runningState` cycled `0->1->2` matching real movement;
     `facingDirection` (read via the confirmed `gObjectEvents` address) tracked every turn
     correctly; `objectEventId`/`spriteId`/`gender` held sane constant values throughout --
     fully responsive, live data, not the frozen `0xFF`/`255`/`15` garbage the vanilla addresses
     read (see the 2026-08-11 entry and its 2026-08-14 reproduction above).
- Source: the four probe scripts above; now cited in
  `adapters/emulator/pokemon/emerald/meshghost_emerald.lua`'s `AVATAR_ADDR_ARCHIPELAGO_SHIFT` /
  `detectAvatarAddrOffset()`, applied in `getLocalState()` and `playerScreenPos()`.
- Notes: `playerScreenPos()` anchored every remote ghost's drawn position off a `spriteId` read
  from this exact struct, which explained the "ghost renders but is stuck at a different fixed
  spot each restart" symptom watched live earlier the same day. Both `gObjectEvents` and
  `gPlayerAvatar` shift by the identical delta relative to vanilla (`0x284`), detected once at
  startup by scanning up to 16 entries at each candidate base for the `isPlayer`+
  `LOCALID_PLAYER` signature above (not assumed from a single hardcoded index, since which array
  slot the player occupies isn't guaranteed constant). Scoped to this Archipelago Emerald
  base-patch version, same portability caveat as every other Archipelago-specific address in
  this project.
  **First fix attempt failed a live re-test the same day**: loading the fixed
  `meshghost_emerald.lua` and watching the ghost showed the exact same stuck-position symptom.
  Root cause: `playerObjEventExistsAt()`'s `isPlayer`+`LOCALID_PLAYER` check alone had a false
  positive against the *abandoned* vanilla address's frozen `FF 03 FF 03...` garbage pattern --
  `OBJECTEVENT_SIZE` (`0x24`) is even, so every entry lands on the same phase of that 2-byte
  repeat, and offset `+0x02`/`+0x08` both read `0xFF`, coincidentally satisfying both checks at
  once. `detectAvatarAddrOffset()` picked vanilla on a ROM already confirmed relocated. Fixed by
  also requiring `mapGroup` to be a plausible real value -- bounded by `MAP_GROUPS_COUNT` (34,
  `pret/pokeemerald`'s `include/constants/map_groups.h:598`, not a guessed round number) rather
  than the garbage pattern's `255`.
  **Confirmed on screen after the second fix**: user reloaded `meshghost_emerald.lua` and
  watched a loopback ghost follow their real position correctly -- "it follows the player now,
  works perfect" / "the ghost is not stuck at a random coordinate anymore."
  **Re-confirmed across all three ROMs**: user then live-tested loopback again separately on
  both independent Archipelago-patched seeds AND the vanilla ROM -- ghost spawned and followed
  correctly on all three, confirming the added auto-detect logic doesn't regress the vanilla
  path. This closes the third of four Archipelago rendering bugs found via this investigation.

### Archipelago avatar-detection timing bug found and fixed: script loaded during the intro cutscene no longer gets stuck

- Date: 2026-08-14
- Observed: same day as the previous entry, immediately after confirming bug #3's fix on
  screen. User found that loading `meshghost_emerald.lua` WHILE still in the intro cutscene
  (before the game's own object-event system has spawned the player's entry) reproduced the
  identical stuck-ghost symptom bug #3 was supposed to have closed. Confirmed as a timing bug
  specifically, not a new address problem: reloading the script after actually reaching real
  gameplay fixed it every time. Root cause: `detectAvatarAddrOffset()` (as it existed after the
  bug #3 fix) ran exactly once at script startup; if the player's object event didn't exist yet
  at that exact moment, both candidate checks failed and the function permanently fell back to
  the vanilla offset for the rest of the session, never retrying once the player's entry
  actually appeared. Fixed by replacing the one-shot call with `tryDetectAvatarAddrOffset()`,
  called every frame from the main loop until it actually finds the player's entry (checked via
  the same `isPlayer`+`LOCALID_PLAYER`+plausible-`mapGroup` signature as bug #3), then stopping.
  **Confirmed on screen**: user reloaded the script during the intro cutscene itself (the exact
  failing case) and watched the ghost correctly follow once real gameplay started, with no
  stuck/anchored symptom -- then re-confirmed the ordinary mid-game reload case still works with
  no regression.
- Source: `adapters/emulator/pokemon/emerald/meshghost_emerald.lua`'s `tryDetectAvatarAddrOffset()`,
  called once at startup and again every frame from the main loop until `avatarAddrConfirmed`.
- Notes: same class of problem `readLocalGender()`'s own header comment already documents for
  `gSaveBlock1Ptr`/`gSaveBlock2Ptr` needing an `inOverworld()` gate -- a "resolve once, trust
  forever" pattern is fragile against anything read before the game state it depends on
  actually exists. This closes the fourth and final Archipelago rendering bug found via this
  investigation.

### Emerald walk/run sub-tile glide: fixed-duration constants confirmed pixel-exact, and a real transition-snap bug found and fixed

- Date: 2026-08-14
- Observed: session prompted by the user testing `meshghost_emerald.lua`'s loopback ghost with
  `-interp=0 -min-send=10ms` (removes the network-side smoothing that previously masked local
  timing imprecision) and reporting a visible snap whenever movement pace changed (idle->walk,
  walk->run, run->walk, idle->run). A temporary per-commit diagnostic (`console.log` of
  `frameCounter`/`anim`/measured frame-gap between tile commits) showed the adapter's then-live
  "measure the real gap and reuse it" smoothing scheme misapplying a stale gap across a pace
  change (e.g. a walk->run transition animating its first running step over a leftover
  16-frame walking-paced gap instead of the correct 8) -- a real, reproducible bug, not a
  network artifact. A further per-frame raw-position trace (`rawX`/`rawY` logged every frame,
  not just at commits) showed something narrower and more important: every genuinely
  continuous step measured **exactly** 8 (running) or **exactly** 16 (walking) frames, with
  zero variance across dozens of real steps -- and that the same "measure it live" scheme also
  misread ordinary tap-then-pause play (release the direction key, briefly idle, press again)
  as one long, slow single step, since a brief idle gap plus one real step both land inside the
  same "plausible" frame-count window. A final trace comparing the adapter's own synthetic
  glide curve against `playerScreenPos()`'s real hardware sprite-offset read
  (`sx`/`sy`/`sx2`/`sy2`/`cx`/`cy`/`coordOffsetX`/`coordOffsetY`, logged individually) confirmed
  two more things directly, not by inference: (1) `sx` (the sprite's own screen offset) and
  `coordOffsetX` (the camera's world-scroll offset) move by exactly ±1 pixel per frame in
  perfect lockstep during a real step, summing to a value that never changes -- i.e.
  pokeemerald's screen-locked-player/scrolling-world camera behavior is real and confirmed on
  this Archipelago-patched ROM, not a stale/wrong address as first suspected; and (2) that
  1px/frame real cadence matches the fixed `STEP_DURATION_FRAMES` constants exactly (16
  frames observed for a full 16px walked tile). **Confirmed on screen** by the user across
  multiple test rounds: idle->walk, walk->run, run->walk, and idle->run transitions all glide
  cleanly with no snap after reverting to fixed-only durations (no live measurement, no
  anim-gating -- both tried and reverted the same session after being disproven by this data);
  a single walked tile visually matches the real character's own pace.
- Source: `adapters/emulator/pokemon/emerald/meshghost_emerald.lua`'s `smoothPosition()` and
  `playerScreenPos()`; `pokeemerald`'s real per-tile timing was originally measured 2026-08-11
  (see the "Emerald walk/run tile duration" entry above) and re-confirmed here via the same
  live-measurement discipline against real per-frame data, not re-derived from source.
- Notes: the two rejected fix attempts (live-measured duration, and gating a measured duration
  on whether `anim` matched the previous step) are kept as historical comments in the source
  rather than deleted, specifically so neither is re-attempted blind in a future session -- see
  `agent_docs/pitfalls.md`'s new entry on this investigation for the transferable lesson.
  Network-side tuning from the same session (`-interp=0`, a new `-min-send` flag on
  `cmd/meshghost`, `dev-scripts/run-core-*.bat` defaults changed to instant-for-local-testing)
  is design/config work, not a runtime fact, so it isn't a `verified.md` entry on its own --
  see `dev-scripts/README.md` and `internal/core/core.go`'s `MinSendInterval` for that half.

### A client could be orphaned into a room that had already been dropped

- Date: 2026-08-17
- Observed: agent-found and reproduced deterministically in
  `TestRoomDroppedWhileAClientIsJoiningIt`, after the user asked whether dropping a room could
  affect other rooms and described a real churn pattern (start emerald, start tevi, start
  pseudoregalia, drop tevi, drop emerald, start emerald, ...).
- **The defect:** `handleConn` finds or creates a room under `Server.mu`, releases it, reserves a
  slot and mints a player_id, and only then adds the client under `Room.mu`. If the room's last
  existing member left inside that window, `finishLeave` -> `dropIfEmpty` saw an empty room and
  removed it from `Server.rooms` — and the joining client then added itself to a room nothing
  could reach, because the next client asking for that name got a freshly created one. Both
  clients are "connected", neither sees an error, and the ghosts simply never appear.
- **Same class as the roster-snapshot race, and just as silent.** Timing alone did not reproduce
  it: 200 paired join/leave races passed. It was proved by driving the two critical sections in
  the order `handleConn` can actually interleave them, which is a stronger demonstration than a
  flaky reproduction anyway.
- **Fix:** `Room.joining` counts clients handed the room but not yet added, guarded by `Server.mu`
  (the lock `dropIfEmpty` already holds), and `dropIfEmpty` declines to sweep while it is non-zero.
  `handleConn` releases the hold with a `defer`, so every exit from the hello path — joined,
  refused for a full server, resumed — is covered, and `finishJoin` re-runs the sweep so a room
  held only by a joiner that gave up is still collected rather than pinned forever.
- Confirmed by the suite at `-count=10`, and by the leak tests specifically: a fix that pinned
  rooms in the table would have been worse than the bug it replaced.

### FireRed: ROM matches, decomp builds byte-identical with the existing agbcc

- Date: 2026-08-17
- Observed: the user's `1636 - Pokemon Fire Red (U)(Squirrels).gba` hashes to
  `41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc`, which `pokefirered`'s `README.md` documents as its
  primary target (`pokefirered.gba`). A local build produced that exact hash. `make syms` then
  produced `pokefirered.sym`; `gPlayerAvatar` is `0x02037078` and `gObjectEvents` is `0x02036e38`.
- Source: `pret/pokefirered` `README.md` L7; build artifacts `pokefirered.map`/`.sym`.
- Notes: **needed no new tooling** — the already-built `C:\dev\agbcc` installed into the FireRed
  tree with its own `install.sh`. Build ~3.5 min with `-j8`. **The addresses differ from Emerald's**
  (Emerald's `gObjectEvents` is `0x02037350`), so despite both being GBA Pokémon with similar
  structures, FireRed needs its own table — the symbol names transfer, the addresses do not.
  `pokefirered` also builds LeafGreen and rev1/switch variants, each with its own hash.

### Emerald spawns a real object event: visible, engine-drawn, engine-walked, and behind the pause menu (2026-08-18)

- Date: 2026-08-18
- Observed: `adapters/emulator/pokemon/emerald/probes/spawn_test.lua` wrote one synthetic object event plus a
  sprite copied from the player's, into free slots on a vanilla ROM. **The user watched it on
  screen**: a second player-looking character stood two tiles to the left, and when the script
  requested two held movements it walked one tile left and one tile down, animated, with the
  adapter drawing and animating nothing. The log shows the engine doing the work —
  `cur=(15,16) -> (14,17)` with `action=8 held=1` — and the object surviving 15 seconds untouched
  before that.
- Source: live run, user-watched (the visual half); the coordinate/field readings are my own from
  the run's log.
- **The pause-menu question is answered, and positively — this was the motivating question and
  `ideas.md`'s Q3 explicitly listed it as unanswered and as something that could kill the idea
  before any write was attempted.** The user confirmed on screen that the spawned ghost is
  **hidden behind the pause menu**, which the `gui.drawPixel` overlay never was. So the spawn path
  fixes the exact defect the overlay path documented as an accepted trade-off
  (`verified.md`'s earlier base-pause-list/NPC-dialogue entry).
- **Gender comes for free.** The second session ran on a save whose player is May: the player's
  object event read `gfx=89` (`OBJ_EVENT_GFX_MAY_NORMAL`) and the ghost inherited it by
  construction, because the sprite is copied from the player's. The first session, a Brendan save,
  read `gfx=0` the same way. No gender logic exists in the script at all — the same win Crystal
  gets from borrowing the player's sprite.
- **The engine takes ownership of fields we set.** The ghost was written with the player's
  elevation (3) and the engine recomputed it to 0 from the tile within a frame. That is the
  clearest available evidence that the object is genuinely adopted rather than merely resident.
- What this does NOT establish: anything about an Archipelago-patched ROM (the script refuses to
  write on one by design), behaviour across a battle, or more than one ghost at once.

### Emerald: a map load destroys the ghost completely, and identity is the only safe liveness test (2026-08-18)

- Date: 2026-08-18
- Observed: after the player changed map, the ghost's object event read back fully cleared —
  `active=0 gfx=0 localId=255 map=255/255 cur=(0,0)` — and its sprite slot was returned to the
  engine (`inUse=0`, callback `0x08007429`, the dummy). The script kept issuing turn requests at
  the dead slot for several minutes, which is what made this obvious in the log.
- Source: live run, my own reading of the log.
- **Why it matters:** re-spawning per map load was predicted by the ADR; what the run adds is that
  the clear is total, so nothing of ours survives to be repaired — a fresh spawn is the only
  option. `RemoveAllObjectEventsExceptPlayer` (`event_object_movement.c:1407`) is the matching
  engine-side routine.
- **And the trap:** the freed slot is immediately reusable by the game. One reading later, slot 4
  came back as `active=1 gfx=6 localId=1 map=0/9` — a real NPC of the new map, in our old slot. A
  liveness check that asks "is this slot active?" would have called that our ghost, which is the
  same false positive Crystal lost a run to. The fix, now in the script, is to check **identity**:
  slot active AND `localId` is ours AND the map matches.

### Emerald: every special player state is a different graphicsId, and fishing is fully characterised (2026-08-18)

- Date: 2026-08-18
- Observed: `probes/fishing_probe.lua` recorded a real fishing session on a May save. The player's
  object event swapped `graphicsId` **89 -> 138** for the whole action and back to 89 at the end,
  while `movementType`, position and `movementActionId` never changed. The animation played out
  entirely in the sprite's `animNum`:

  ```
   306 | gfx=138 anim= 3   <- take out rod, east
   547 | gfx=138 anim= 7   <- put away rod, east   (a nibble that got away)
   882 | gfx=138 anim= 3   <- cast again
  1123 | gfx=138 anim=11   <- HOOKED, east
  2780 | gfx= 89           <- back to normal
  ```

- Source: live run, my own reading of the probe's log; every number below is cross-checked against
  our own `make compare`-verified `pokeemerald` build, so this needs no visual confirmation.
- **Decoded**: `138` is `OBJ_EVENT_GFX_MAY_FISHING`; anim `3/7/11` are `ANIM_TAKE_OUT_ROD_EAST` /
  `ANIM_PUT_AWAY_ROD_EAST` / `ANIM_HOOKED_POKEMON_EAST` (`constants/event_object_movement.h:309`),
  the four directions being +0/1/2/3 within each group. `flags=0x21` is
  `PLAYER_AVATAR_FLAG_ON_FOOT | PLAYER_AVATAR_FLAG_CONTROLLABLE`.
- **The general result, which is bigger than fishing.** `sPlayerAvatarGfxIds`
  (`field_player_avatar.c:246`) maps every special state to its own graphic, per gender:

  | State | Brendan | May |
  | --- | --- | --- |
  | normal | 0 | 89 |
  | Mach Bike | 1 | 90 |
  | Acro Bike | 63 | 91 |
  | surfing | 2 | 92 |
  | underwater | 111 | 112 |
  | field move | 3 | 93 |
  | fishing | 137 | 138 |
  | watering | 191 | 192 |

  So **the open surf/Mach Bike/Acro Bike item does not need anim classification at all** — the
  state IS the `graphicsId`, readable in one byte from the player's object event, alongside the
  `PLAYER_AVATAR_FLAG_*` bits `phase8.md` already identified. That is a much smaller and more
  reliable thing to send over the wire than a guessed anim tag plus per-mode step timings.
- **What it means for the spawn path, and it is a real constraint.** A ghost currently borrows the
  PLAYER's sprite — its `images`/`anims` pointers and now its own copy of the player's tiles — so
  it can only ever show the graphic the local player is currently using. Rendering a *surfing*
  peer while you walk needs the sprite built from `gObjectEventGraphicsInfoPointers[gfxId]`
  instead of copied: its own `images`/`anims`/OAM shape, tiles sized from that entry's `size`, and
  its palette resolved rather than inherited. Not attempted yet; this is the next piece of work,
  and it is the same mechanism for all eight states rather than eight special cases.

### Emerald: two spawn-path bugs found by playing, not by reading (2026-08-18)

- Date: 2026-08-18
- Source: live session, user-watched; the field readings are mine from the adapter's own log file
  (which had to be added first — this adapter logged only to the Lua Console, so nothing outside
  the emulator could see why it was failing).

**1. Talking to a ghost ran a garbage script and opened the slot-machine minigame.**

- Observed: the user pressed A facing a spawned ghost and landed in the Game Corner slot machine,
  which then reported "You've run out of COINS".
- Cause: an A-press resolves an object's script by looking its **`localId` up in the map's
  template table** (`GetInteractedObjectEventScript` -> `GetObjectEventScriptPointerByObjectEventId`
  -> `GetObjectEventTemplateByLocalIdAndMap`). A synthesised ghost has no template, so the lookup
  returns NULL and the game jumps to whatever is at that address. The decomp marks that NULL
  dereference as a known bug of its own (`event_object_movement.c:2387`).
- Fix: give ghosts `localId = LOCALID_PLAYER` (255). `GetInteractedObjectEventScript`
  (`field_control_avatar.c:292`) returns NULL for any object with that id, so the ghost becomes
  non-interactable **through the engine's own check** rather than a guard of ours. Ghost object
  slots are now allocated from slot 15 downward, because `GetObjectEventIdByLocalId` scans upward
  and returns the first match — keeping the real player (slot 0) ahead of every ghost.
- **`ideas.md` predicted this exact failure for a different design** (the "hijack a live NPC"
  variant: *"its dialogue script is presumably still attached to the same local ID — interacting
  with 'the ghost' could plausibly trigger the real NPC's own conversation"*). The from-scratch
  spawn path inherited the same problem for a different reason, and nobody connected the two until
  it happened on screen.

**2. A ghost took exactly one step, then froze forever.**

- Observed: `held=1/1` in every status line — held movement flagged both active and finished — with
  the ghost stuck at its spawn tile while the player walked away.
- Cause: the engine sets `heldMovementFinished` when a step completes but **leaves
  `heldMovementActive` set**; clearing is the caller's job (`ObjectEventClearHeldMovement`,
  `event_object_movement.c:4895`). The adapter treated "active" as "still moving", so after the
  first step it never issued another.
- Fix: treat active+finished as a completed step, clear it the way the engine does (action
  `MOVEMENT_ACTION_NONE`, both bits cleared, sprite `sTypeFuncId`/`sActionFuncId` reset), then
  accept the next order. Confirmed live: the ghost now steps, and the user confirmed its collision
  and its sprite line up.
- **Worth keeping as a shape**: "is a movement flagged active" and "is this object ready for a new
  order" read like the same question and are not. The same distinction exists in Crystal's step
  code, where the idle check is `STEP_DURATION == 0`.

### Emerald: route boundaries are connections, not warps — and that leaked a solid ghost every crossing (2026-08-18)

- Date: 2026-08-18
- Observed: walking back and forth between routes left a line of ghosts standing where previous
  ones had been — the user sent a screenshot with five. On deploying the fix, the orphan sweep
  immediately cleared four stale objects (slots 12-15) and settled to one tracked ghost.
- Source: live session, user-watched; slot readings mine from the adapter log.
- **Cause, and it is a distinction the adapter did not know it was making.** A ghost's identity
  check included "the object's map matches the player's current map". That is correct across a
  **warp** (a house, an elevator), where the engine clears the whole object array and hands the
  slots to the new map's NPCs. It is **wrong across a connection** — route to route — where the
  map identity changes but the object array is left intact. So at every route boundary the
  adapter declared a live ghost dead, dropped its record, and spawned a replacement, while the
  original object stayed active with nothing tracking it.
- **Why this was a hazard rather than an eyesore**, in the user's words: *"they would eventually
  just block the route itself if they get stuck/don't despawn like this"*. Ghosts are solid by
  design (decided the same day), so leaked ones accumulate into a wall. Solid and leaking is a
  much worse combination than either alone.
- **Fix**: identify a ghost without reference to the map. Ours are the only objects that are
  active, not the player, and carry `localId == LOCALID_PLAYER` — a real NPC always has a template
  localId (numbered from 1), and the player has `isPlayer` set. That survives a connection
  unchanged and still reports death after a warp. Plus a per-second **orphan sweep**: anything
  wearing that marker which the adapter is not tracking gets cleared, which also cleans up after a
  script reload.
- **The general lesson**: "the map changed" and "the world was rebuilt" are different events, and
  an engine can do the first without the second. Any identity check keyed on map identity inherits
  that distinction whether or not its author considered it.

### Emerald: what the game means by "water", and why a solid tile is not it (2026-08-18)

- Date: 2026-08-18
- Source: my own reading of memory (the map grid and the tileset attribute tables) plus
  `pokeemerald`; no visual claim, so this needs no user watching under `CLAUDE.md`'s rule.
- **A map-grid tile is one 16-bit word carrying three independent fields**: metatile id
  (`0x03FF`), collision (`0x0C00`), elevation (`0xF000`). The metatile id selects the *behaviour*
  by indexing the map's tileset attribute table — primary tileset below id 512, secondary above,
  behaviour in the low byte of the attribute.
- **Water has collision 0 and elevation `ELEVATION_SURF` (1)**, against the player's
  `ELEVATION_DEFAULT` (3). You cannot walk onto it because the elevations *differ*, not because it
  is solid. `IsPlayerFacingSurfableFishableWater` (`field_player_avatar.c:1322`) requires exactly
  `GetCollisionAtCoords(...) == COLLISION_ELEVATION_MISMATCH`, the player at `ELEVATION_DEFAULT`,
  and a surfable/fishable behaviour at the target tile.
- **Therefore making a tile solid makes fishing impossible.** An impassable tile returns
  `COLLISION_IMPASSABLE`, which fails that check. Found by doing it: a tile edited to water
  behaviour *plus* a collision bit blocked the player — which read as success — and then refused
  the rod with *"DAD's advice... there's a time and place"*.
- **That message is the generic "not usable here"**, not a story gate — the same text as riding a
  bike indoors (user, 2026-08-18). Two separate wrong conclusions were drawn from it before it was
  looked up.
- **Verified by construction afterwards**: a Littleroot tile written as
  `id 44 / collision 0 / elevation 1` reads back, through the game's own lookup path, as
  `behaviour 21 (MB_OCEAN_WATER)` with the player at elevation 3 one tile away.
- **What this does NOT establish**: that a rod has been successfully cast on such a tile. The
  setup is ready and unconfirmed — `unverified.md`.

### Emerald: fishing works on a synthesised water tile — and can never catch anything there (2026-08-18)

- Date: 2026-08-18
- Observed: with `probes/watertile.lua` turning the tile in front of the player into water
  (metatile behaviour `MB_OCEAN_WATER`, collision 0, elevation `ELEVATION_SURF`), **the user
  confirmed on screen that fishing works** — the rod comes out and the cast plays, in Littleroot
  Town, where no water exists in the real game.
- **And nothing can ever bite there**, which the user diagnosed before the code was read: *"pokemon
  are tied to per town/route... there are no pokemon in this town as its not supposed to have any
  grass/water or wild pokemon battles to begin with"*.
- Source: user-watched for the fishing itself; the mechanism below is my own reading of
  `pokeemerald`, so it needs no separate confirmation.
- **Mechanism.** `gWildMonHeaders[]` is keyed by `(mapGroup, mapNum)` and holds four independent
  lists — `landMonsInfo`, `waterMonsInfo`, `rockSmashMonsInfo`, `fishingMonsInfo`.
  `DoesCurrentMapHaveFishingMons` (`wild_encounter.c:770`) is false when `fishingMonsInfo` is
  `NULL`, and the fishing task then sets `task->tStep = FISHING_NO_BITE`
  (`field_player_avatar.c:1851`) — jumping straight past every bite branch.
- **What this means for the ghost work.** The synthesised tile is enough to reach the *cast* and
  the *no-bite* branches of fishing, and cannot reach *bite*, *hooked*, or the *battle* — so those
  branches must be tested on a map that actually defines fishing encounters. It also means the
  earlier plan to answer "does fishing spawn a companion sprite?" from this setup can only answer
  it for the first two branches.
- **The general lesson, recorded in `probes.md`**: synthesising a piece of a game gets you its
  form, not the data keyed to it. A real water tile is a behaviour, an elevation, **and** a map
  with water encounters; two of the three produce something that looks right and does nothing.

### 2026-08-19 — Emerald: the orphan sweep's predicate never fired outside the overworld

**Track: probe log, read by the agent. No visual claim, and nothing here needs the user.**

`meshghost_emerald.lua`'s `sweepOrphanGhosts()` clears any object event that is *active, not the
player, `localId == LOCALID_PLAYER`*, on the argument that only our own spawned ghosts can be in
that state. Until today it ran unconditionally every 60 frames — including before the object array
had been located, outside the overworld, and on an Archipelago ROM, where it would have read a
**relocated** `gObjectEvents` and then written the **vanilla** `gSprites`. That last combination is
exactly the unmeasured write the adapter's render-path split exists to avoid (`BANDAGES.md`).

`probes/sweep_guard_probe.lua` (read-only) measured the predicate directly on the vanilla ROM,
sitting at the title/continue screen: **5,760 frames, zero matches**, with the player's own object
event findable at the vanilla base the whole time (`playerObjAt(vanilla)=true`, `overworld=false`).

So on vanilla the sweep was harmless in practice, and the gate added the same day
(`avatarAddrConfirmed and avatarAddrOffset == 0 and inOverworld()`) is **defensive, not a fix for
an observed corruption**. The Archipelago half of the argument is untested — no patched ROM was
loaded — and remains the real reason the gate is there.

**Also confirmed the same day, from the adapter's own session log:** a bridge `reject` (port 7779,
Crystal's core, during the normal port walk) is now handled without a Lua error, and the adapter
went on to start its own core on 7778 and reach `bridge_ready`. Before the fix the reject left
`drainBridge()` indexing a nil socket; the error was invisible because the frame-error rate limiter
started at frame 0 and could not log anything in the first 300 frames — which is why none of the
eight earlier session logs that record a rejection shows it.

## A core that "would not reconnect" was dialing a relay nobody was running — 2026-08-19

**Confirmed with the Go tools, not by watching a game** (`CLAUDE.md`'s client/server rule).

The vanilla Emerald instance's core (bridge 7786) was the one of four that did not come back after
the shared relay on 7777 was restarted at 08:02. Its adapter read `remotes=0` while the other
Emerald instance read `remotes=1`. Cause, straight out of `dev-scripts/meshghost.log`:

- The core started at 07:40:49 with `config loaded from ...\dev-scripts\config.json` and connected
  to **`127.0.0.1:7787`, room `emeraldcap`** — a private crowd-test relay, not the shared one.
- That relay exited; at 07:52:58 the core logged `dial relay: dial tcp 127.0.0.1:7787 ... — will
  keep retrying` and then said nothing for ten minutes.
- `dev-scripts/config.json` no longer exists (the crowd-test session cleaned it up), so nothing in
  the tree explained the port. Restarting the relay on 7777 could never have helped it.

**The reconnect loop was never broken, and that was proven rather than argued**: starting a relay
on 127.0.0.1:7787 made the core reconnect within 15s, unprompted (`connected to relay
127.0.0.1:7787 as p1 in room "emeraldcap"`). Killing the stale core let the adapter autostart a
fresh one, which logged `no config file ... using built-in defaults` and joined the shared relay as
`p12` in room `default`; the adapter's own status line then read `remotes=1`.

Two facts fall out, both of which cost the investigation time:

- **A core's relay address comes from `config.json` in its WORKING DIRECTORY**, which under the dev
  loader is `dev-scripts/` — the hazard `environment.md` already warns about, now seen doing
  exactly what it predicts. A config file that has since been deleted leaves no trace at all
  except the run banner in the log.
- **All four cores share `dev-scripts/meshghost.log`**, so the file is four sessions interleaved
  and the only way to tell them apart is the run banner and the ports in each line.

Fixed on the Go side: a still-failing reconnect now repeats its complaint once a minute, naming the
relay address and how long it has been failing, instead of logging once and going silent
(`core/core.go`, `reconnectLogInterval`; regression test
`TestReconnectKeepsSayingItCannotReachTheRelay`, which fails without the change).

## Two Emerald instances no longer share one log file — 2026-08-19

**A filesystem fact, not a visual one.** Both BizHawk Emerald instances run the same adapter, whose
log name resolved only to the second, so two instances reloading in the same second opened the same
file and their writes landed inside each other (`atus: frame=...`). The name now carries the
emulator's process id — `meshghost_emerald_20260819_082128_22592.log` alongside
`meshghost_emerald_20260819_081711_15628.log`, one per emulator, confirmed on disk. Back-ported to
the Crystal adapter unchanged, which had the identical shape.

## Emerald: where the game draws its UI panels, measured on a SECOND map — 2026-08-19

`probes/textbox_probe.lua`, driven by a scripted START press **outdoors in Littleroot Town** (the
earlier sample was indoors), read from the BG tilemaps rather than the LCD:

- **Nothing open:** BG0 entirely empty. BG1 is NOT empty outdoors (rows 1, 5-9, 13, 17 carry tiles)
  — which is the reason the detector reads BG0 and only BG0.
- **START menu open:** BG0 rows 0-13, and only in the right-hand columns (sampled columns 21, 24,
  27 non-zero; everything left of them zero) — the panel, nothing else.
- **Closed again:** BG0 back to entirely empty, same frame the menu disappeared.

Same geometry as the indoor sample, on a different map, which is what says the detector is reading
the panel rather than the room. The text-box half (BG0 rows 14-19, full width) has one indoor
sample from 2026-08-19 and no second one yet.

### Same day, an A/B that closes it from the adapter's own side

**Track: agent-run experiment on the live Archipelago instance, read from the adapter's log. No
visual claim.** Filling `W_BATTLEMODE = 0x1234` was the last nil in the AP table, so the adapter
**ran on that ROM for the first time** — classified `ROM title "AP_CRYSTAL"`, connected to its
bridge on 127.0.0.1:7783, spawned a loopback ghost (`p327-ghost`, map object 15 <-> struct 12) and
drove the drawn tier from the cartridge.

With it running, the address was then exercised directly rather than only observed: `0x1234` was
**written** to 2 while the player stood in the overworld (permitted — cheats are allowed to
progress a dev playthrough, `environment.md`).

| `0x1234` | `drawn tier:` lines emitted in 8 seconds |
|---|---|
| forced to **2** | **0** |
| restored to **0** | **32** |

`drawOverflow()` early-returns on `not inPlay()`, and `inPlay()`'s only battle term is
`wBattleMode == 0` — so the drawn tier going completely silent on a 2 and resuming on a 0 is the
adapter's own gate agreeing, from a third direction, that `0x1234` is the byte.

**And it names the real exposure on this build.** `W_MAPSTATUS` (`0x1439` on Archipelago) was
observed reading **2 throughout every battle in this session** — it never leaves the in-play value.
So on the patched ROM the battle exclusion rests **entirely** on `wBattleMode`; the map-status term
that backs it up on vanilla contributes nothing. Anything that leaves `wBattleMode` at 0 while the
overworld is gone — the encounter transition, most obviously — is unguarded, which is the shape of
the "ghost showing inside the battle" the user reported the same day.

## Emerald/Archipelago: the graphics-info POINTER TABLE moves too, and that is why nothing spawned — 2026-08-19

**The symptom, from the Archipelago Emerald instance:** peers received and in the same area as the
player (`remotes=2`, `area=0:9 local=0:9`), and **`ghosts=0` forever**. No error, no refusal, no
log line of any kind.

**Four candidate causes were measured and cleared first** (`probes/apspawn_gate_probe.lua`, a
read-only probe written for exactly this): the slot budget was **12**, not 0; the player's
object/sprite cross-link through `gSprites` **checked out**, so `spawnGhost()`'s own guard was not
firing; the field camera was **settled** (`x=0 y=0`), so `syncGhost()`'s placement gate was open;
and the peer's `area_id` **matched the local one exactly** (an `unrendered <peer>: area=… local=…`
line was added to the adapter's status block to settle that one, and it stays).

That left exactly one path out of `spawnGhost()` that returns without logging: `if not info then
return nil end`, where `info` comes from `graphicsInfo()` — which reads a **ROM pointer table**.

**Measured** (`scratchpad/apem_gfxinfo.lua`, read-only, three ids sampled):

| `gObjectEventGraphicsInfoPointers` | id 0 | id 1 | id 8 |
|---|---|---|---|
| vanilla `0x08505620` | `ptr=00077CCD` **not ROM** | `ptr=00007777` **not ROM** | `ptr=00000000` **not ROM** |
| shifted `0x0850CB50` (+`0x7530`) | `08510E84`, size 512, 16 tiles, pal `1100`, 16x32 | `08510EA8`, size 512, pal `1100`, 32x32 | `08510FC8`, size 256, pal `1104`, 16x32 |

So the table moves by **`0x7530`** — the same shift already measured for the sprite/palette data
block, i.e. it is in that same relocated ROM region, and *not* the `0x284` that `gObjectEvents`
moves by. `gSprites` still does not move at all.

**Fix:** `loadGenderFrames()` now caches `detectSpriteAddrOffset()`'s result as
`genderFrames.romOffset` (stored on that table rather than a new local — the main chunk is at
Lua's 200-local ceiling) and `graphicsInfo()` adds it to the table address. **Result: `ghosts=0`
became `ghosts=1` on the first reload, and a loopback ghost stands beside the player as a real
spawned object event** — confirmed visually from a screenshot taken on this instance, which is
permitted here because it is a PATCHED ROM (`dev-scripts/shots/apemerald/171-ghost-walk.png`).

**The second fix is the one that matters more:** that `return nil` is no longer silent. It now
names the graphics id and the table address it failed against, throttled the same way the
out-of-slots refusal is. A refusal the log never mentions is indistinguishable from a peer who is
not there, and it cost most of a session.

## Emerald's drawn tier clips a REAL panel, not just a fake one — 2026-08-19

**A counter from the adapter's own status line, not a picture** (the accompanying screenshots are of
a vanilla ROM and are not offered as evidence).

Setup: drawn overflow tier ON, `MESHGHOST_EMERALD_MAX_SPAWNED=0` (new probe flag) so the single
loopback peer is PAINTED rather than spawned — `ghosts=0 drawn=1` — and
`MESHGHOST_EMERALD_FAKE_PANEL_ROW` **unset**, so the only panel geometry in play is what
`tiering.scanPanel()` read out of the BG0 tilemap.

- Nothing open: `clipped=0`, sustained over many 300-frame windows.
- With a real panel on screen and the drawn ghost overlapping it: **`clipped=475`** in one
  300-frame window, returning to 0 the window after.

That is the first time the clipping has been driven by the real detector rather than by the fake
panel row (the earlier 1.1M-run figure was `FAKE_PANEL_ROW=0`). **What is NOT yet done is a
controlled repeat**: the loopback ghost sits on the player's own row, and a text box only occupies
the bottom six rows, so an overlap happens only when the camera puts the player low on screen. A
peer whose Y genuinely differs from the player's (a synthetic peer on a private relay) or a small
indoor map where the camera clamps is the way to make it repeatable.

Reached by writing the player's coordinates (permitted for progress, 2026-08-19) — so this is a
**state that was reached, not a state that was played to**, and it says nothing about whether a
player walking normally would find that overlap.

## Emerald's spawn adapter, end to end in one sitting — 2026-08-19

**User-confirmed on screen**, vanilla ROM, one loopback peer, drawn-overflow tier off (the
default), a single session of ordinary play a little over two hours long.

Walking, running, a route boundary, in and out of a building, the pause menu, and pressing A at
the ghost repeatedly: *"works fine"*. That closes, together and against the current build rather
than piece by piece:

- one ghost, two tiles to the right, on the tile grid, hidden behind the pause menu;
- on-grid placement after the settled-camera fix, across several map changes;
- house transitions, with no real NPC lost from either map;
- ghosts non-interactable — pressing A at one does nothing (this is what used to launch the
  slot-machine minigame);
- the 2026-08-19 robustness pass regressed nothing (gated orphan sweep, non-throwing bridge
  rejection, bounds-checked `graphicsId`, un-swallowed frame errors).

**From the adapter's own log for the same session** (tool-side, not a claim about the screen):
**zero** lines matching `error` in 14,731; `ghosts=` never once read higher than 1 across 6,372
status samples; four orphan-slot clears in total, at transitions.

### The in-game gate, exercised by a HARD reset

The user could not soft-reset, so this ran as a power-cycle instead — the adapter sees the same
title screen either way, and the log shows the same path taken: `left the game (title screen) --
dropping the bridge` at 13:36:49, matched a second later by the core's own bridge disconnect, then
`in game -- now sending local state` with `local gender = male` re-read for the new session. No
ghost anywhere during the title, the continue screen or the intro; one ghost — not two — after
CONTINUE, wearing the right character.

**Still open, and loopback cannot answer it:** whether a peer's ghost of *you* disappears from
*their* screen within about a second of you returning to the title. Under `-loopback` the ghost is
your own echo, so its disappearing and the local render stopping are the same event. Two clients.

## Emerald: where the game draws its panels, measured with a box and a menu open — 2026-08-19

**Agent-measured from `probes/textbox_probe.log`** during the session above (a log read, not a
picture), which is what the "ten seconds of input" request in `unverified.md` was for.

BG0 is the panel layer, and nothing else uses it:

| State | BG0 rows | Columns | Border tile ids |
|---|---|---|---|
| Nothing open | *completely empty* | — | — |
| Text box | 14-19 | full width | 513/516 top and bottom, 519 left edge |
| START menu | 0-13 | right-hand only, from col ~21 | 532/535/538 |

97 samples with a panel-free BG0 were taken while walking around, so the quiet case is not a
one-frame accident. This **confirms both premises `tiering.scanPanel()` was written on**: a
non-empty BG0 cell means the game drew a panel there, and a per-ROW first/last-column span is the
right shape — a full-width band at the bottom for a box, a right-hand column range for the menu.
The detector reads the tilemap base out of `BG0CNT` at runtime, so none of this is a ROM address.

What this does **not** settle is whether `MESHGHOST_EMERALD_DRAWN_OVERFLOW` should ship on: the
UI-clipping objection to it is now answered, but occlusion, shadows and water reflection are not.

## A peer's own STATE renders on the spawned tier — fishing confirmed, 2026-08-19

**User-confirmed on screen:** with `MESHGHOST_GHOST_PEER_GFX` set, *"the spawned ghost is fishing"*.

This closes an item that had been open since Phase 8 (*"a peer's own state (surf/bike/fishing) is
not rendered yet"*) and the interesting part is that **no new code was needed**. The peer's
`graphicsId` — which is what the game changes when you mount a bike, surf, or cast a rod — has been
travelling in `extras.gfx` all along, and `spawnGhost` already rebuilds a ghost's sprite when it
changes (*"the peer changed what they are... a graphic swap means different images, animations, OAM
shape and tile count, so the sprite is rebuilt rather than patched"*). The adapter simply refused to
adopt it, behind a flag whose comment said so: *"changes nothing visually but keeps the wire format
and the plumbing live and exercised. Set MESHGHOST_GHOST_PEER_GFX to opt in and continue the
investigation."*

The investigation was continued by a save that could finally fish — `probes/grant_test_kit.lua`.

**The other half is confirmed NOT working, and expected:** *"not the drawn one"*. The painted tier
decodes its pixels from the walk and run pic tables for the local player's gender, so it can draw a
character walking and nothing else. A peer on a bike, surfing, or fishing is painted as if walking.
The route to fixing it is the one the spawned tier already uses — `graphicsInfo(graphicsId)` yields
that graphic's own images pointer and palette tag, and Crystal's drawn tier already reads a
non-resident character out of the cartridge this way — but the frame SIZE also varies by graphic
(a bike is wider than a walker), so the decode cache has to key on the graphic rather than assume
one shape.

## Emerald: peer STATE, ledges and shadows — a long confirmation pass, 2026-08-19

All user-confirmed on screen, with both renderers up (`MESHGHOST_COMPARE_TIERS`), on vanilla.

### A peer's state renders on both tiers now

- **Fishing, spawned tier**: *"the spawned ghost is fishing"*. Needed no new code — `extras.gfx`
  already carried the graphics id and `spawnGhost` already rebuilt on a change; the adapter simply
  declined to adopt it behind `MESHGHOST_GHOST_PEER_GFX`.
- **The full fishing ANIMATION, not just its first frame**: *"neither of them are doing the mid
  fishing animations"* → fixed by sending the peer's sprite `animNum`/`animCmdIndex` and starting
  the animation the way the game does (`StartSpriteAnim`: set the number, set `animBeginning`,
  clear `animEnded`).
- **The drawn tier draws the actual graphic** — rod, bike, surfboard — by resolving
  `anims[animNum][animCmdIndex]` to an image index and decoding from that graphic's own `images`,
  with the frame SIZE taken from the graphic too. Colours come from the live palette slot, so a
  drawn peer keeps dimming with fades and caves.
- **A regression this caused, and its fix**: mirroring the peer's animation also fired on the plain
  walking graphic, where the engine already drives the ghost through our step/turn/bump actions.
  Two writers of one field left it stuck — *"its stuck in the wrong pose after turning
  directions"*, and after running. Scoped to graphics the engine is NOT driving.

### Ledge hops — three attempts, and only the measurement worked

*"neither ghost knows how to jump down/off a ledge"*. Two failures first, both recorded because
they look reasonable and are not:

1. **"the peer moved two tiles in one update"** — never happens. The engine advances the tile
   counter ONE TILE AT A TIME through a hop (measured: 16,18 → 16,19 → 16,20 with the action
   holding at 12 throughout), and the core's interpolation smooths it further.
2. **The same test as an `elseif` after the one-tile branch** — unreachable, because a one-tile
   delta is exactly what a hop looks like every frame, so the ghost walked down the ledge.

What works is the ENGINE'S OWN INTENTION: `movementActionId` (+0x1C) reads `JUMP_2_*` (0xC..0xF)
for the whole hop, so the peer sends it and the ghost performs the same action, arc and all —
checked BEFORE any distance is measured, and latched so one hop is one jump.

### The jump shadow — a bandage, and almost none of it is invented

The engine does create a shadow for any object's hop, and it cannot reach a ghost: it binds by
`localId` and re-finds its object every frame, and ghosts wear `LOCALID_PLAYER` — which is exactly
what makes them non-interactable through the engine's own check, so it is not negotiable. The
user's call was to draw it ourselves. Everything about it was then measured rather than tuned:

| Property | How it was settled |
| --- | --- |
| Arc | The engine's: a jumping sprite carries its hop in `pos2.y`, so the shadow is drawn without that term |
| Colour | Three alpha guesses all read too light; dumping the OBJ palettes mid-hop showed every candidate entry is pure black |
| Position | The shadow sprite sits at the character's own x, 12px below its un-arced y |
| Size | The sprite is 16x8 (`SHADOW_SIZE_M`), but decoding its pixels showed the INK is **16x5**, rows 3..7 — filling the box read as *"pretty big on the ghosts"* |

**Then it stopped being ours at all.** *"think they look fine now"* was followed by *"or slightly
big still not sure"* — which is the tell that an approximation is being judged against the original
and will keep losing. So the original is read instead: `learnShadowArt()` waits for the local
player's first hop, finds the shadow sprite by what it IS (in use, 16x8, beside the player,
mid-jump — never by an address), and decodes its pixels and palette once. The adapter says so in
its own log: *"learned the game's own jump shadow (5 runs) -- ghosts now use it instead of an
ellipse."* **User-confirmed after that: *"yee think its good/perfect now"*.**

The ellipse survives only as the fallback for a ghost that hops before the player ever has.

### Also confirmed in the same pass

- **Walking into a wall animates**, at the half pace the game uses for a collision (walk-in-place
  SLOW). Two bugs here: a distance-driven cycle has no distance to work with when you walk into a
  wall, and the first fix tested the FILTER's per-frame movement against exactly zero — true only
  when the ghost had already stopped, which is why it worked *"if im next to a wall"* and not
  *"if i walk and hit a wall and keep walking"*. The peer's target is discrete and cannot be
  thresholded wrong.
- **A tile leak, found by a garbled NPC the user could talk to.** The battle guard added the same
  day dropped a ghost's record without freeing its VRAM tile range (it could not: outside the
  overworld that bitmap belongs to the battle), so the engine ran short and drew one of its own
  NPCs from whatever was left. Ranges are queued and settled on the way back in.

### "Both ghosts move while fishing" — CLOSED, and it was two real bugs plus an illusion

Reported five times while every position measurement said the ghost was exactly where it belonged.
All of those measurements were right, and none of them was the question. Dumping every field the
hardware draws from — not just position — found it:

1. **`pos2` was missing.** The game's fishing TASK sets the player's sprite offset to 8,0, which is
   what keeps the character on its tile inside a 32-wide frame (a walker is 16). A ghost has no
   task, so it wore the wider frame with no correction and sat half a tile to the side. `pos2` now
   travels with the state, under the same gate as the peer's animation number, and is applied in
   the same frame as a graphic rebuild rather than the frame after.
2. **The painted copy was centred twice.** A pinned position is copied from the spawned sprite and
   already carries that sprite's `centerToCorner` — which IS the engine's centring for a wide frame
   — and the drawn tier applied its own on top: 8px left, in steady state, for every wide graphic.
   User-confirmed after the fix: *"the drawn one is perfect now"*.
3. **What was left is not the ghost.** Frame by frame across the swap: the ghost reads an effective
   400 the entire time and never moves; the PLAYER reads 360 for two or three frames and then 368.
   The game hands the player the wide frame slightly before its own task applies the compensating
   offset, so the gap between the two characters changes for a moment — and watching the ghost
   while the reference moves reads as the ghost snapping. The ghost is provably still.

**The lesson, and it cost a lot of live tests:** *"the ghost moved"* and *"the ghost is drawn
somewhere else"* are different claims, and only the second one was ever true. Position was measured
five times and was correct five times. What needed measuring was everything ELSE the hardware uses
to draw — `pos2`, `centerToCorner`, OAM shape, the animation frame — because a sprite can be in
exactly the right place and still put its character half a tile away.

### Still open from this pass

- **Bikes and surfing** on both tiers: fishing is confirmed, and they are the same class of state
  (a graphicsId the engine swaps, driven by a task) so they are likely to work — but "likely" is
  not "watched", and the `pos2` bug above would have looked identical on a bike.
- **A cave**, for the painted tier's scene dimming. The fade half is confirmed; a cave is not.

## The fishing snap: four real defects, and what "1:1" turned out to mean — 2026-08-19

The last of the fishing reports, and the most instructive sequence of the session. Five separate
reports, five position measurements that were all CORRECT, and four genuine defects underneath.

| # | Defect | How it was found |
| --- | --- | --- |
| 1 | `pos2` never sent — the game's fishing TASK offsets the sprite by 8,0 to keep the character on its tile inside a 32-wide frame, and a ghost has no task | Dumping every field the hardware draws from, not just position |
| 2 | The painted copy was centred twice — a pinned position already carries the spawned sprite's `centerToCorner` | Reading the two draw paths against each other |
| 3 | A second ghost survived up to a second after the bag closed — the transition sweep runs while the stale ghost is still TRACKED, so it spares it, and by the time `syncGhost` drops the record the sweep for that tick is done | The user saw it; the frame log confirmed two live objects. Fixed by sweeping at the moment the record is dropped |
| 4 | The ghost faithfully replayed four frames the player was visible for but nobody could see | Frame-by-frame capture with the player's own visibility and offset |

**Defect 4 is the one worth keeping.** The game gives the player the 32-wide fishing graphic FOUR
FRAMES before its task applies the compensating `pos2`. The player is visible (`vis=1`) throughout,
so those frames are genuinely displayed — but they land while the bag is still closing, where an
8px hop is imperceptible. The ghost replayed them 250ms later in a clean frame, as the only moving
thing on screen, and it read as a snap. **Verified after the fix: 90 of 90 frames at the correct
x=400, with the intermediate x=392 gone entirely.**

**And the definition that settled it, from the user:** *"1:1 = it looks exactly the same as the
player doing it / perfect / intended."* Under a numbers-match reading, defect 4 was not a defect at
all — the ghost matched the player exactly. Under the real standard it was, because the standard is
what is SEEN. That is now in `CLAUDE.md` and the adapter template.

**Two process notes, both earned:**

- *"lets fix the actual issue instead of making excuses"* — offering a send-rate change or a
  graphics-swap rework as "paths to 1:1" was rejected, and rightly: neither addressed the cause.
  The eventual fix changed no rate, no tick and no swap mechanism. It removed the intermediate
  state, which was the defect.
- The user's own observation is what aimed the search: *"the drawn ghost is still perfect, its just
  the spawned one"*. Both are drawn from the same position, so a position bug would show on both —
  which ruled out an entire class of causes in one sentence and pointed straight at the object
  array, where the duplicate was.

## Emerald: fishing is 1:1 on BOTH tiers — 2026-08-19

**User-confirmed, visually, on the vanilla ROM:** *"Its working 1:1 / perfect now"*, after a
final double-cast test with `MESHGHOST_COMPARE_TIERS` on — the painted ghost, the spawned ghost and
the player all casting side by side. Confirms: the ghost plays the full fishing animation
(cast, the reel loop, and the put-away), it does not move at the start or the end of a cast, and a
**second** cast behaves identically to the first. Judged against the player and the painted tier in
the same frame, which is what the compare mode exists for.

Everything below is the evidence trail. **The three mechanism facts are from the `pokeemerald`
decomp with file/line citations; the behavioural readings are from an in-adapter per-frame trace,
not from watching.**

### The mechanisms (decomp-cited, so citable rather than measured)

| Fact | Source |
|---|---|
| `animPaused` is bit `0x40` of the sprite struct's `+0x2C` (`animDelayCounter:6` occupies bits 0-5) | `include/sprite.h:211-212` |
| `ObjectEvent.enableAnim` is byte `+0x01` bit `0x08` (after `frozen` `0x01`, `facingDirectionLocked` `0x02`, `disableAnim` `0x04`); `TryEnableObjectEventAnim` clears `animPaused` and `disableAnim`, then clears itself | `include/global.fieldmap.h`; `src/event_object_movement.c:7335-7343` |
| The fishing sprite offset is **recomputed every frame** from the displayed frame's image index: `x2=8` for images 1/2/3 (`-8` facing west), `y2=-8` for image 5, `y2=8` for images 10/11 | `AlignFishingAnimationFrames`, `src/field_player_avatar.c:2045-2078`; `DIR_WEST=3` per `include/constants/global.h:140` |
| Fishing graphics ids are 137 (Brendan) and 138 (May) | `include/constants/event_objects.h:144-145` |
| `BuildOamBuffer` is at `0x08006A0C` on the vanilla ROM | this project's own `pokeemerald.map` build (`environment.md`) |

### The behavioural readings (from `probes/animtrace.log`, agent-read, no watching involved)

- **A ghost's sprite is paused while idle, exactly like the player's.** Both read `0x40` set at
  `+0x2C` while standing (`P.2c=48`, `G.2c=47`). The player is un-paused by its fishing task; the
  ghost has nothing to do that, so it held frame 0 for **256 consecutive frames** of a cast
  (`G.anim=3/0` throughout) and then `11/0` for the remainder, while the player's frame index
  cycled `0, 1, 3`.
- **After the `enableAnim` fix the engine drives the ghost's animation itself**, at the game's own
  rate: `3/0 → 3/1 → 3/2 → 3/3`, then the reel loop `11/0 ↔ 11/1 ↔ 11/3`, with the paused bit clear
  (`G.2c=0x80|delay`).
- **The sender published a mismatched pair at every cast end.** The graphic is held six frames
  before publishing; the offset was not. Measured at all six cast-ends in one trace (f=2512, 3027,
  5301, 5452, 5613, 5753): `sox` flipped to 0 roughly **9 frames before** `gfx` did.
- **A frame-boundary write is one step out of phase with the image.** With `pos2` held constant at
  `8,0`, the ghost's real OAM x went `144, 136, 144` on consecutive frames — a phase error
  invisible in every sprite struct field.
- **After the `BuildOamBuffer` hook: zero frames** in a whole multi-cast run where the ghost's
  offset and its graphic disagreed (previously the defining symptom).

### Capability confirmed

**`event.onmemoryexecute` works in this BizHawk build** and can hook a GBA ROM address: registered
at `0x08006A0C`, fires per frame, and the adapter runs with 0 frame errors and no
`hook unavailable` fallback line. This is the first use of a code hook in any adapter here — until
now every adapter acted only at frame boundaries. Vanilla-gated; not measured on an Archipelago
ROM, which relocates code (the adapter's `BANDAGES.md`).

### What it cost, for the next estimate

Roughly ten live test cycles and six wrong fixes, because the symptom ("it snaps") was produced by
**five different defects of one class** — two consumers disagreeing about which frame a value
belonged to — and each fix exposed the next. The write-ups are in `pitfalls.md` (three entries) and
`_template/probes.md` (two method sections). The measurement that ended it is kept as a probe
behind `MESHGHOST_EMERALD_ANIM_TRACE`, off by default.

## Emerald: the surfing ghost's Pokemon, on the spawned tier — 2026-08-19

**User-confirmed on screen, vanilla ROM:** *"the fish/pokemon under the spawned ghost looks perfect
now"*. Reported the same session as *"both of the ghosts don't have the 'blue fish' they are riding
on while surfing"*, with a screenshot showing two ghosts sitting on open water.

Two defects, and the second had been recorded as unexplained since 2026-08-18:

1. **The blob was spawned on one construction path out of two.** `spawnGhost` created it; a peer
   who walks into the water is patched in place by `swapGhostGraphicInPlace` instead, which did
   not. The adapter's log showed the ghost correctly wearing `gfx 2` and animating, with no blob
   line ever printed — so the state was right and its companion sprite simply never existed. Now
   handled in both directions by the swap, because a blob left behind keeps following the object
   id in its own `data[2]`.
2. **`centerToCornerVec` was never set** (`+0x28`/`+0x29`). It is not part of the sprite template —
   `CreateSprite` derives it from the OAM shape and size — so a struct built from the template
   alone leaves it 0,0 and the hardware draws a 32x32 sprite from its corner. That is the
   *"renders roughly half a tile down-right of the rider"* recorded on 2026-08-18.

**How it was found**, since the method is worth more than the fix: `probes/surfblob_probe.lua`
dumps the PLAYER's own live blob and the ghost's, field by field. The player's read `c2c=240,240`
and the ghost's `c2c=0,0`; nothing about the bob, the animation or the field-effect system had to
be understood. Agent-verified afterwards from the same dumps: the ghost's blob now sits at the same
`0,+8` OAM offset from its rider that the player's does. Method: `_template/probes.md`, "Diff what
you BUILT against what the game BUILT"; symptom and rules: `pitfalls.md`.

**Also settled in passing, from the probe:** a surf blob set to `BOB_PLAYER_AND_MON` drives the
RIDER's `pos2` as well as its own — the player's rider reads `pos2=0,-3` while the blob does. So the
peer's own sprite offset is no longer written onto a ghost that has a live blob: the engine is
already doing it, and two writers of one field is the defect shape this adapter has hit repeatedly.

**Still open, same feature:** the DRAWN tier has neither the blob nor a water reflection —
*"still nothing under/ no reflection in the water for the drawn ghost"*. `unverified.md`.

## Emerald: a drawn ghost's water reflection, 1:1 with the engine — 2026-08-19

**User-confirmed on screen, vanilla:** *"it looks good now, it also fixed the issue of drawing when
outside of the water at the same time. confirmed visually now."*

The painted tier has no hardware behind it, so every rule a reflection gets for free had to be
located and reproduced. All of these are the game's own, none approximated:

- **It is a copy of the sprite, flipped, `height - 2` lower, in a mapped palette** — `SetUpReflection`
  and `gReflectionEffectPaletteMap`.
- **Its `y2` is the NEGATED rider's `y2`**, so the gap between character and reflection is
  `height - 2 - 2 * bob`. Missing that term made it sit a little high AND perfectly still, which
  reads as two faults and is one.
- **A moving reflection is an AFFINE sprite, not a plain flip.** Nothing in the overworld source
  writes its matrices, so they were measured: `oamMatrix[0]` sweeps `a` between 252 and 260 one step
  per frame with `d = -256`. Drawn width is `width * 256 / a` — read live rather than reconstructed,
  so there is no phase of ours to keep in step.
- **Coverage is per pixel, decoded from the metatiles**: a priority-3 sprite loses to BG1 and BG2
  and wins against BG3, so a NORMAL metatile's ground hides it while a COVERED/SPLIT one's does not.
- **Whether a reflection exists at all** is the engine's own scan — a region `(w+8)>>4` by `(h+8)>>4`
  starting one row below the character, around the previous coordinates as well as the current ones.
  The previous-coordinate half is what makes a reflection slide out from under a character leaving
  the water instead of blinking off; it must expire after a step, or a ghost parked at the shore
  keeps claiming the water it came from.

**The bug that took the longest was not in any of that.** The tile grid was anchored to the
player's sprite position, which carries `pos2` (the bob) and `centerToCornerVec` (the frame's own
centring, **-8 for the 16-wide walker and -16 for the 32-wide surfer**). So the grid was 8px too far
left for exactly as long as the player was surfing, and the mask permitted 8px of ledge and grass.
Vertically both graphics are -16, so the vertical edge was right the whole time and only the side
looked wrong — which is why four different clipping rules were tried first. `pitfalls.md`.

**How it was finally caught**, since the method outlasts the fix: the computed grid was compared
against the SCREEN using a landmark whose appearance is unambiguous — a metatile built from four
copies of one water tile, which must render as 16px of flat colour. The grid said x 88, the pixels
said 96. `_template/probes.md`, "Check a computed grid against the screen".

**Agent-verified numbers at the moment of the fix:** `gbX` -680 → -672; metatile 184 relocated to
x 80..95, matching the visible ledge at 80-83 and water from 84; the allowed span moved from
`76-103` to `84-111`, i.e. beginning at the first water pixel. Two reported symptoms — painting on
the grass and painting on the ledge — closed together, which is what says they were one cause.

## Emerald: the Mach Bike, and walk-through ghosts — 2026-08-20

**User-confirmed on screen, vanilla, both tiers.** Four separate defects, each found by measurement
after a guess had already failed:

1. **Idle on a bike pedalled on the spot.** A sprite's animation state is three things — the number,
   the frame, and whether it is RUNNING — and only two were on the wire. The overworld PAUSES an
   idle character's sprite (measured: the player's own Mach Bike idles at anim 7 frame 3 with
   `animPaused` set), so `spaused` now travels with the other two and a held peer is reproduced as
   held: exact frame index, paused bit set, pixels loaded, and no `animBeginning` (which would
   reset to frame 0 and show the wrong frame of the loop).
2. **Ghosts teleported when the peer rode fast.** The step speed was being read from
   `movementActionId`, which is TRANSIENT: sampled at 20Hz it caught `WALK_NORMAL` or a turn as
   often as a fast action, so 6 steps in 10 fell back to walking pace behind a peer at bike speed
   (`walk/run=6` against `2D=3`, `15=1`). It now reads `gPlayerAvatar.bikeSpeed` (+0x0B), a STABLE
   field holding the game's own `PLAYER_SPEED_*`, and maps it to that speed's action —
   `FAST -> WALK_FAST 0x15`, `FASTEST -> WALK_FASTER 0x2D` (`sMachBikeSpeedCallbacks`, src/bike.c:75-80).
3. **The place-it branch was catching the wrong thing.** Written for a warp or a dropped packet, it
   also fired whenever a peer simply moved faster than one tile per step: at top speed the ghost
   settles ~2 tiles back (the interpolation delay made visible) and a one-tile step cannot close
   that. Measured: `PLACED=13`, every one `dist2`, against 54 correctly-sped steps. A gap of 3 tiles
   or less is now WALKED at the peer's own speed; a longer one is still a warp and still placed.
4. **The ghost slid at top speed** — the last one, and the only one the counters could not see,
   because the sprite was neither paused (`paused=0`) nor frozen (`slide=150/225`). The per-frame
   trace showed why: the ghost was on a DIFFERENT animation from the player and stuck on its last
   frame — `P.anim=4/0 | R.sanim=4/0 | G.anim=8/3`, held ten-plus frames. Letting the engine pick a
   moving ghost's animation from the movement action is right for the WALKING graphic and wrong for
   a bike: the player rides on animation 4 while the action-derived one is 8, which runs out and
   holds. On a bike the peer's number now wins even while moving — the number only, so the engine
   still advances the frames and there is still one writer.

**Agent-verified afterwards, over 1920 traced frames of scripted riding at top speed:** the ghost's
animation number matched the peer's on **1920/1920 frames (100%)**, and its frame index advanced 958
times and held 961 with a longest hold of **2 frames** — *identical* to the player's 958/961/2. The
held frames are the animation's own delay, not a stall.

## Emerald: a ghost you can walk through, using the engine's own rule — 2026-08-20

**User-confirmed:** *"collision on the spawned ghost seems to be removed/working properly now"*.

`DoesObjectCollideWithObjectAt` only reports a collision when the two objects' elevations are
COMPATIBLE, and `AreElevationsCompatible` (src/event_object_movement.c:7789) is three lines: 0
collides with anything, equal collides, and **two different non-zero elevations do not collide at
all**. That is the switch, and it is the game's own — it is how a bridge and the water under it hold
two characters on one tile.

**Why this file twice said no such switch exists.** An earlier attempt set elevation 0, 1 and 15,
saw all three still block, and concluded elevation was not the mechanism — leaving two positional
hacks that each broke the ghost's movement. The missing piece is `ObjectEventUpdateElevation`
(:7759): the engine REWRITES `currentElevation` from the map tile whenever an object moves, so the
value was reset within a step to whatever the ghost stood on — the same terrain as the player, hence
equal, hence colliding. It is now re-applied every frame and chosen against the player's current
elevation, so it can never match.

Only the LOW nibble of +0x0B is touched. The high nibble is `previousElevation`, which
`SetObjectSubpriorityByElevation` draws with, so the ghost keeps its exact ordering behind and in
front of scenery: collision changes, rendering does not. A transition frame still collides, because
the player's own elevation reads 0 mid-step and the rule says 0 collides with everything — the
engine's behaviour for every character.

**This is the mechanism the ghost-collision POLICY has been waiting for.** The ADR's `"disabled"`
setting has shipped on the Go side with no adapter able to honour it (`architecture.md`, 2026-08-19).

## Emerald: the muddy slope, where facing and movement come apart — 2026-08-20

**User-confirmed on screen, vanilla:** *"it looks good in game, visually confirmed"*.

The Mach Bike exists to climb a muddy slope, and below top speed the slope pushes the rider back —
which turns out to be the only place in this game where a character's FACING and its MOVEMENT
disagree, and where the field that describes a rider's speed reads zero while they are visibly
moving fast. `ForcedMovement_MuddySlope` (pokeemerald src/field_player_avatar.c:567-581):

```c
if (movementDirection != DIR_NORTH || GetPlayerSpeed() < PLAYER_SPEED_FASTEST)
{
    Bike_UpdateBikeCounterSpeed(0);                 // speed counter reset to zero
    playerObjEvent->facingDirectionLocked = TRUE;   // keeps FACING north
    return DoForcedMovement(DIR_SOUTH, PlayerWalkFast);  // pushed SOUTH at WALK_FAST
}
```

Both halves broke a ghost, and both were measured over 527 frames of slide-back before the fix and
514 after:

| | before | after |
| --- | --- | --- |
| ghost movement action | `WALK_NORMAL` (never fast) | **`WALK_FAST`**, 416 frames — matching the peer's 21 |
| ghost facing north | 346/527 (66%) | **436/514 (85%)** |

1. **Speed.** The step speed reads `gPlayerAvatar.bikeSpeed`, which is the right source for riding
   and is forced to **0** by this very code — so the ghost slid at half the peer's pace. The peer's
   `movementActionId` IS reliable here (the forced movement holds it), so the action is now a
   FALLBACK used only when the field says "standing still": stable field first, transient second.
2. **Facing.** Asking for a step also turns a ghost, which is right everywhere except where the
   engine has taken the facing away from the movement. No new wire field was needed — the peer
   already sends its facing and the step direction is known locally, so a DISAGREEMENT between them
   is the locked case. The ghost is then given the peer's facing plus the engine's own lock bit
   (`facingDirectionLocked`, bit 0x02 of byte +0x01, include/global.fieldmap.h:204-211).

**Still open, and newly visible:** during the peer's slide the ghost's action is mostly `WALK_FAST`
*north* rather than south — it is finishing the step it was already committed to while the peer is
already sliding back. That is the same "a ghost cannot abandon a step" limit that caused corner
snapping, showing up in the one place where a peer's direction INVERTS mid-step. `unverified.md`.

## Emerald: a drawn ghost hides behind the map — 2026-08-20

**User-confirmed on screen, vanilla:** *"works properly now, confirmed"*. A painted peer now passes
behind buildings, roof edges and tree tops exactly as a spawned one does.

This was the oldest gap in the drawn tier and the last of the three the tier shipped OFF for
(`status.md`: *"drawn-tier visual parity: occlusion, shadows, water reflection"*). It needed no new
machinery — the reflection work had already built the per-pixel metatile decoder, and occlusion is
the same question asked for a different OAM priority.

**The whole rule, and it is the game's own.** A sprite is hidden where a BG layer it does not
outrank is opaque. `sElevationToPriority` (src/event_object_movement.c:7729) draws a character on
ordinary ground at priority **2**; `SetUpReflection` pins a reflection at **3**. The overworld gives
BG1/BG2/BG3 priorities 1/2/3 (`sOverworldBgTemplates`), and OBJ wins ties:

| | BG1 (prio 1) | BG2 (prio 2) | BG3 (prio 3) |
| --- | --- | --- | --- |
| character (2) | covers | ties, sprite wins | no |
| reflection (3) | covers | covers | ties, sprite wins |

Crossed with where `DrawMetatile` puts each layer (src/field_camera.c:255-300):

- **NORMAL** — a character is hidden by the TOP layer only; a reflection by both.
- **COVERED** — a character by NOTHING; a reflection by the top layer.
- **SPLIT** — both by the top layer.

The character row is exactly what a building is: the roof edge that overlaps a walkable tile is that
tile's top layer, which is the layer the engine draws above sprites — the source says so in a
comment on the NORMAL case.

**The first attempt changed nothing, and the log said why before the screen did.** The occlusion was
added to the branch that draws a peer's OWN graphic — a bike, a rod, a surfboard. A peer on FOOT is
drawn from the cached gender frames by a different function, so the mask never ran. The tell was a
one-shot diagnostic that printed no line at all: not a quiet success, an unreached code path.

## Emerald: grass drawn over a painted ghost — 2026-08-20

**User-confirmed on screen, vanilla:** *"its working now ... confirmed visually by me"*. A painted
peer standing in tall grass is now hidden from the waist down, like the player and like a spawned
ghost.

**This is a SECOND kind of occlusion, and the first one could never have done it.** The BG mask
confirmed hours earlier handles scenery — buildings, roof edges, tree tops — because those are a
metatile's top layer on a BG the sprite does not outrank. Grass is not scenery: measured, the grass
metatile's top layer is completely EMPTY (`BOTTOM 2012 2013 2022 2023  TOP 0000 0000 0000 0000`,
layer type NORMAL), so no BG layer covers anything at all. The engine spawns a field-effect SPRITE
per object standing in grass and draws it above them (`FldEff_TallGrass`,
src/field_effect_helpers.c:291-309).

A spawned ghost gets one for free, being a real object event — the user confirmed player and spawned
were both already right. A painted ghost gets nothing, so the painted tier now draws the grass
itself, over the character, from the field effect's own art:

- `gFieldEffectObjectTemplate_TallGrass` 0850CAA0 (`MB_TALL_GRASS` 2) and
  `gFieldEffectObjectTemplate_LongGrass` 0850CF94 (`MB_LONG_GRASS` 3), both named in pokeemerald.map.
- Placement is the surf blob's helper again — `SetSpritePosToOffsetMapCoords(x, y, 8, 8)` centres it
  on the tile, and a 16x16 sprite centred on a tile is one at the tile's corner.
- The PALETTE is read off a live grass sprite rather than resolved from the template's tag: the
  player is standing in the same grass whenever this matters. With no live one, nothing is drawn —
  a wrong-coloured rectangle over a ghost is worse than no grass.

**So the painted tier's occlusion is complete only if BOTH are done**, and "it hides behind
buildings" was not evidence that it hides at all in general.

## Emerald: a drawn ghost in tall grass — 2026-08-20

**User-confirmed on screen, vanilla:** *"good now, confirmed visually"*. A painted peer walking
through tall grass is hidden by it the way the player and a spawned ghost are, including between
tiles, with the grass rustling as it is stepped into.

Grass turned out to be four separate facts, and getting one right looked exactly like being done:

1. **Grass is a SPRITE, not scenery.** The grass metatile's top layer is empty (measured:
   `BOTTOM 2012 2013 2022 2023  TOP 0000 0000 0000 0000`), so the BG occlusion mask confirmed
   earlier that day could never have touched it. The engine spawns a field effect per object
   standing in grass (`FldEff_TallGrass`, src/field_effect_helpers.c:291-309).
2. **It belongs to the TILE, not the character.** Drawn at the ghost's own frame it travelled along
   with them; grass sits still and a character walks through it.
3. **It rustles on ENTRY and the clock restarts each time.** The animation is frames 1,2,3,4,0 at
   ten game-frames each (`sAnim_TallGrass`), read from the template at runtime so long grass gets
   its own timing. Keyed on "first ever drawn" instead, a tile walked over twice rustled only once
   -- and a looping test walks the same tiles for ever, so it never moved again.
4. **Both tiles the FEET span are drawn, and nothing above them.** Standing that is one tile;
   mid-step two, so nothing shows through between them. The coverage stops at the foot box, so it
   can never reach the body or the head.

**Agent-measured against the engine's own sprites**, which is what settled the geometry: the grass
sprite's position formula matched to the pixel (`anchorWouldBe=24,-56` against the live sprite's
`pos=24,-56`), the palette matched (14), and the animation frame index lined up. Three assumptions
proven right that would otherwise have been "fixed".

## Emerald: the Acro Bike — 2026-08-20

**User-confirmed on screen, vanilla.** Hops and jumps mirror instead of turning the ghost, the ghost
follows without teleporting, and its legs animate while it rides.

**Three speed sources in one game, and none generalises from the others.** This is the finding worth
keeping:

| what the peer is doing | where the speed lives |
| --- | --- |
| Mach Bike | `gPlayerAvatar.bikeSpeed` (+0x0B), a `PLAYER_SPEED_*` |
| pushed down a muddy slope | `movementActionId` -- `WALK_FAST`, while `bikeSpeed` is forced to 0 |
| **Acro Bike** | `movementActionId` -- **`RIDE_WATER_CURRENT` 0x29..0x2C** |

`AcroBikeTransition_Moving` moves the player with `PlayerRideWaterCurrent` (src/bike.c:546-570), so
an Acro rider reports a family nothing recognised: the ghost WALKED after a cycling peer, the gap
reached four tiles, and four is past the three-tile chase limit -- so it was placed rather than
walked, over and over. `bikeSpeed` stays 0 on this bike because it is the Mach Bike's acceleration
counter and the Acro has no ramp.

**The in-place actions had to be split from the travelling ones.** `0x64..0x8B` reads as one block
and is not: `0x46..0x4D` and `0x7C..0x7F` happen on the spot, `0x74..0x7B` and `0x80..0x8B` travel.
Holding the ghost for all of them stopped it following; issuing the travelling ones verbatim moved
it twice (the action moves it AND the step logic did). Travelling actions are now used for their
ANIMATION only, with the step taking the direction the ghost actually needs -- family base is
`act & 0xFC`.

**Agent-measured, riding a scripted square:** the ghost's sprite went from paused on **232 of 252**
stepping frames to **52 of 250**, with its legs advancing on 99 -- the engine pauses an object's
sprite whenever it settles, and the bike animation mirror was setting a number on a paused sprite,
which changes nothing.

**Known gap, deliberately:** a ghost does not pop a wheelie. Those transition actions never report
finished for a ghost, stranding it -- see `unverified.md`.

---

## 2026-08-20 — Every Acro Bike wheelie action DOES complete, on the engine's own object

**Agent-measured, from a driven ride** (`adapters/emulator/pokemon/emerald/probes/wheelie_watch.lua`
on the vanilla ROM; the user has not been asked to watch anything, and nothing visual is claimed).
The probe mounts the bike, holds B through a fixed set of phases, and logs the PLAYER's own object
event once a frame: `movementActionId`, `heldMovementActive`, `heldMovementFinished`, the sprite's
animation number and `animEnded`, and its step-function indices.

**This disproves the standing theory.** `unverified.md` recorded that the wheelie actions "never
report finished" and guessed they needed acro state the engine keeps on the player. They finish:

| action | busy frames before `heldMovementFinished` |
| --- | --- |
| `0x64` `ACRO_WHEELIE_FACE_*` | 0 -- finished on the frame it is set, and re-issued next frame |
| `0x68` `ACRO_POP_WHEELIE_*` | 9, finished on the 10th |
| `0x6C` `ACRO_END_WHEELIE_FACE_*` | 9 |
| `0x70` `ACRO_WHEELIE_HOP_FACE_*` | 15, 16 hops in one phase |
| `0x7C` `ACRO_WHEELIE_IN_PLACE_*` | 7, 38 repeats in one phase |

**`0x6B` was measured directly**, not inferred from its family: it is one of the three ids the
adapter's watchdog kept freeing at the 60-frame limit, and on the player it ran nine frames and
reported finished. So the fault is a property of the GHOST, not of the action, and the next
measurement is the ghost's own fields during the same action rather than another theory.

**The direction rule, confirmed by driving the same move twice.** Facing south produced the `+0`
member of every family and facing east produced `+3`, so **member = base + (direction id - 1)** in
the engine's own order south, north, west, east. The same rule holds for the plain FACE actions
(`0x00`..`0x03`).

**Two probe traps, both paid for in live cycles.** `joypad.set` replaces the whole pad state, so a
probe writing an empty table every frame silently cancels another probe's press -- that is why the
first two runs captured a walk while `use_acro` was pressing SELECT. And a capture that cannot see
whether it is even on the bike will happily log 976 frames of walking; `wheelie_watch` now waits on
the Acro Bike's `graphicsId` (63/91) before starting. Method notes in `_template/probes.md`.

---

## 2026-08-20 — Emerald: the spawned ghost's Acro Bike idle pose, confirmed on screen

**User-confirmed** after a side-by-side session: *"works now"*. Two separate defects, both spawned
tier only, both found by measurement rather than by reasoning about the code:

- **The idle pose displayed a rolling frame while reporting the standing one.** An object event's
  frame image is only copied into its VRAM when its animation advances, and a ghost standing still
  advances nothing. Fixed by copying the peer's own frame at the settle, gated on the ghost's
  `movementActionId` returning to NONE so the engine's catch-up steps cannot overwrite it.
- **One tile of bike travel played a whole pedal cycle.** `FACE_ACTION` is walk-in-place-fast, which
  is right for a walking peer and wrong for a rider; a bike now settles and turns with the static
  `FACE_STILL_ACTION`.

Both are written up symptom -> cause -> fix in `pitfalls.md`, with the method that found them.

**Also confirmed the same session, agent-measured from the logs:**

- **The relay's `-ghost-collision=disabled` reaches the CORE and stops there.** The core logs
  `ghost collision disabled (set by the room) -- told the adapter` and the ghost stays solid; the
  adapter's own `MESHGHOST_EMERALD_NO_COLLISION` is what actually frees it. That is `status.md`'s
  "Go side DONE, adapters not wired" item, seen live rather than read.
- **A ghost never gets on or off a bike unless `MESHGHOST_GHOST_PEER_GFX` is set.** Without it
  `wantedGfx` returns nil and a ghost keeps whatever graphic the LOCAL player happened to be wearing
  when it spawned -- on both tiers. Confirmed on screen by the user, who saw the spawned ghost stay
  on its bike after dismounting and the drawn one never mount at all.

**The dev-session default that follows from both:** a local Emerald test wants
`MESHGHOST_COMPARE_TIERS`, `MESHGHOST_GHOST_PEER_GFX` and `MESHGHOST_EMERALD_NO_COLLISION` set
together, plus the relay's own `-ghost-collision=disabled`. Three tiers to compare, peers that wear
their own state, and a ghost you can ride through -- the user, on the last: *"it ruins the tests if
its disabled as you keep bumping into the spawned ghost"*.

---

## 2026-08-20 — Emerald: collision is readable, so a scripted ride can path

**Agent-measured** (`probes/collisionmap.lua`, vanilla ROM), and cross-checked against a screenshot
of the same moment -- a patched-ROM-style visual check is not needed here because the claim is about
numbers, and the picture only had to agree.

**The map grid's word carries collision in bits 10-11 and elevation in bits 12-15**, above the
metatile id the adapter already reads from bits 0-9. Confirmed by dumping a 13x13 grid around the
player: every fence, building and map edge read non-zero, every tile of open ground read zero, and
the walkable area read elevation 3 throughout. Details in `adapters/.../documentation.md`.

**Why it matters beyond the fact.** Every scripted ride in this project counts tiles blind, and they
have driven the player into scenery repeatedly -- the muddy-slope ride into a trainer, the bike loop
that drifted across the map, and on 2026-08-20 a square that parked the player in a gap in a fence
and logged nothing for the rest of the run. All of that is avoidable with a lookup that now exists.
The method, and the two sources that must BOTH be read (the grid, and the object-event array, since
an NPC blocks a tile the grid calls free), are in `adapters/_template/probes.md`.

---

## 2026-08-20 — Emerald: bike mount/dismount is 1:1 on the spawned tier, confirmed

**User-confirmed on screen**, the end of a five-hour chain: *"think its actually perfect now."*
Mount and dismount now show the correct idle pose, with no phantom walk/pedal animation in between,
at the same visible moment as the painted copy — within ~1 frame of the wire.

What shipped, each measured before and after (`pitfalls.md` 2026-08-20 has the full chain):

- A graphic change ends in a **settle** — `needsSettle` + `settleStatic`, the engine sets the pose
  via the static face action. The user's own one-tile observation named this mechanism.
- The in-place swap **arrives paused when the peer is paused** (`spaused` threaded through), and
  passes the peer's frame index instead of a hardcoded 0.
- Non-fishing swaps **land mid-step**; the never-interrupt gate stays for fishing, whose measured
  offset fault is the reason the gate exists.
- The sender's 6-frame graphic hold is **skipped for the six known offset-free graphics**
  (walker/Mach/Acro, both genders), keeping it for fishing and anything unrecognised.

**Also established, agent-measured:** the player's sprite draws through its subsprite table with
its struct tile entry parked at 0 — so comparing any sprite's VRAM "against the player" reads
garbage. The ROM-frame comparison in `probes/posediff.lua` is the trustworthy instrument, and the
frame-by-frame screenshot burst (player at frame 22, ghost at 29) is what turned "slower" into a
number.

---

## 2026-08-20 — Emerald: cross-map ghosts — the structures, the engine's behaviour, and the feature

**User-confirmed on screen:** a peer standing on a CONNECTED neighboring route is visible across
the seam on both tiers (*"i can see it in the other route"*), and after the frame-killer fix both
following ghosts cross a seam with the player (*"Both ghosts follow me across the route properly
now"*). The remaining transition blink was measured to be the drawn tier only and fixed; the fix
awaits the user's eye. Requested, designed and shipped in one day.

**Agent-measured, each with a probe and a log:**

- **The map header's connection structures** (`probes/connections.lua`): connections ptr at header
  +0x0C -> {count s32, list}, entries 12 bytes {direction u8, offset s32 +4, group u8 +8, num u8
  +9}, directions 1/2/3/4 south/north/west/east. Verified from both sides of a real seam; a
  double-west pair with offset=20 confirmed the offset field's meaning. Indoor maps carry no
  connections pointer at all -- which is the whole house-hiding rule.
- **gMapGroups self-located at 08486578** by three chained ROM scans, each verified by reading
  back, found independently by the probe and the adapter. Never hardcoded: the adapter re-locates
  per session (~7s of 128KB chunks), and a scan pass snapshots its target header first so the
  player crossing a seam mid-pass cannot invalidate it (it did, and cost three of four rebases
  before the snapshot).
- **The engine rebases every live object one frame AFTER a connection crossing**
  (`probes/coordwatch.log`): same slots, coordinates shifted by exactly the seam delta. Ghost
  objects survive crossings; across four driven crossings the sprite invisible flag NEVER went up
  (`probes/blinkwatch.log`), so the spawned tier does not blink -- the observed blink was the
  drawn tier being cleared on the transition frames that deliberately skip repainting.

**The design that shipped** (all adapter-side; core and wire untouched, `area_id` still opaque):
peers are translated at ingest into the local frame when their map is in the current map's own
connection list, re-translated every frame so the local player's crossing rebases everyone the
same frame, with a 10-tile existence margin (the user's +3 safety over the engine's 7-tile border)
and the spawned tier gated at the border where object coordinates stay engine-safe. Crossing a
connection shifts every peer's glide state and ghost bookkeeping by the seam delta; a warp has no
connection entry and keeps the teardown, which is exactly right for a door.

---

## 2026-08-20 — Emerald: seam crossings are clean — the pop was the core's cross-area filter

**User-confirmed on screen:** *"Think its actually working now, they are not going away anymore."*
Both following ghosts ride through route crossings with no despawn, no flicker, no lurch, walking
and biking; the static cross-map peer unaffected throughout, as it always was.

**Agent-measured, same build:** eight driven crossings, zero `DESPAWN` lines, zero frame errors,
rebases firing on every armed crossing. Root cause and the contract change (`render_all_areas`,
bridge hello) are in `architecture.md`'s ADR; the diagnosis chain is `pitfalls.md`'s entry of the
same day. Full Go suite green twice (`run-gotests.bat`) after the core change.

---

## 2026-08-20 — Emerald: the drawn ghost's hat survives Mach speed, confirmed

**User-confirmed on screen:** *"yee it looks fine/good now, the hat stays on"* — including full
speed built before a seam and a descent straight through the crossing. Cause was the panel
scanner's banner flicker clipping screen rows 0-4, drawn tier only; fix is a stability gate
(two-scan debounce, five-scan streak for the banner band). `pitfalls.md` same date has the six
innocent suspects and the method. Driven verification: clipped=0 across fast rides with four seam
crossings, zero despawns, zero frame errors.

**Also shipped in the same hunt, compare mode only:** the pinned drawn twin now takes its
animation frame from the spawned sprite's LIVE fields, the same source its position already
pins to — the wire-rate frame strobe at top speed is gone with it.

---

## 2026-08-20 — Emerald: plain Acro Bike riding left/right is correct, and no ghost invents a hop

**User-confirmed on screen:** *"moving left/right looks correct now"*, after a report the same
session that ghosts were hopping while riding normally.

**Agent-measured, from a driven ride** (`probes/acroride.lua`, vanilla ROM, loopback with
COMPARE_TIERS): three tiles left, three right, three laps. The player's object reported **only
`RIDE_WATER_CURRENT` 0x2B/0x2C** throughout -- no wheelie or hop id appeared at all -- the adapter
classified them `inPlace=false travels=false`, and **both sprites stayed on the ground on every
sampled frame** (`pos2 y = 0`). So plain riding does not produce a hop on either side.

**Agent-measured, from the user's own hopping** (`probes/hopwatch.lua`): 66 ghost hops captured,
and **every one had the player in a hop action too** (0x72/0x73 standing, 0x76/0x77 travelling).
Zero ghost hops occurred while the player was on a plain ride action. The watcher's own control
passed in the same run -- it was silent through the left/right riding and fired immediately once
real hops began, so the silence was evidence rather than an unarmed probe.

**Also measured, and NOT a defect on its own:** the ghost's hop starts on the frame the player's
hop ends -- consistently about half a hop cycle behind. That is the interpolation delay made
visible, the same shape as every other trailing measurement in this file.

**Open, from the same session:** turning left-to-right while hopping left the ghost facing the old
way for ~16 frames, and the user reports it hopping backwards there -- spawned tier only, the drawn
tier fine. Measurement armed, not yet captured; `unverified.md`.

---

## 2026-08-20 — Emerald: two peers could share one object slot, and a doorway made it constant

**User-confirmed on screen**, after the fix: *"the door thing seems to be fixed as well. they are
not popping in/out anymore, both ghosts look fine when in front of the door"*. The report that
started it, same session: *"both ghosts in emerald are blinking in/out all the time ... its when i
stand right infront of a door"*.

**Cause, measured before anything was changed.** `findFreeObjectSlot` asked the engine's ACTIVE
BIT, which answers "is this slot in use by the GAME" -- not "is it in use by US". A door is a warp
tile, so the engine culls ghost slots constantly there, and a culled slot reads inactive for the
frames between the cull and the adapter's respawn. A second peer searching in that window is handed
a slot the first peer's record still names, and from then on both peers write the same object every
frame. `findFreeSpriteSlot` had the identical hole.

**What it looks like in numbers:** one object slot alternating every 8 frames between two peers'
complete states -- `xy=44,13 dir=east` (the loopback ghost, player +2) and `xy=42,4 dir=north` (the
cross-map test peer, 9 tiles north) -- with the adapter's own `drawn=` counter flipping 1 -> 0
between samples, because the drawn twin follows the spawned sprite's live fields.

**Fix:** both slot searches skip anything another tracked ghost already claims, plus a once-a-second
audit that names any two peers found holding the same object or sprite slot. Method and the general
form are in `pitfalls.md`; the Lua-local ceiling this ran into is there too.

---

## 2026-08-20 — Emerald: the moving-around lag, priced, fixed, and user-confirmed

**User-confirmed:** *"yee it feels way better now"*, after reporting the game *"laggy while
moving"* and *"chugging and dropping frames real bad"*, worst *"in 2 places consistently"*.

**Agent-measured throughout** (`probes/fpsride.lua`, the same scripted run-left/run-right route
every time, `client.get_approx_framerate` as the instrument):

| configuration | avg fps | worst dip |
| --- | --- | --- |
| bare emulator, no scripts (control) | 58.1 | 37 |
| adapter, shipped-like config | 56.8 | 27 |
| adapter, full dev compare mode | 56.9 | 27 |
| before the fixes (what was being played) | 45.9 | 15 |

**The causes and fixes are `pitfalls.md`'s entry of this date** (cull→respawn churn at seams and
doors; the reclaim line as a console GUI append; per-frame probes left loaded). The remaining
transition hitch is VANILLA: the bare control dips to 37 on the same seam legs with nothing loaded.

**Spawned vs drawn ghost, priced per frame from the section profiler:** a SPAWNED ghost costs
~0.05ms of Lua (the engine animates it; the adapter only steers), a DRAWN one ~0.6ms every frame
(panel scan + one gui call per pixel-run). At one ghost the difference is invisible (56.8 vs 56.9
avg); it is a statement about SCALE — 137 drawn peers measured 17fps on 2026-08-19, while spawned
ghosts are capped at ~13 by the engine's own object array and cost almost nothing each.

**The BuildOamBuffer execute hook is exonerated**: 52.0 avg without vs 52.6 with, same route --
the plausible suspect A/B'd innocent instead of "fixed".


## 2026-08-21 — BizHawk 2.11 has no scanline hook, and Emerald does not need one

**Source: the emulator's own binary and the project's `make compare`-verified pokeemerald build.**
No game was watched and none needed to be — every claim here is a tool read, per `CLAUDE.md`'s rule
that a fact from a console read or a file may be recorded without waiting for the user.

**The `event` library this build actually exposes**, read out of
`C:\ProgramData\Archipelago\Bizhawk\dll\BizHawk.Client.Common.dll` rather than asked for (the
older `client.getluafunctionslist()` route is unavailable on this build --
`dev-scripts/bizhawk-capabilities.log`): `onframestart`, `onframeend`, `oninputpoll`, `onloadstate`,
`onsavestate`, `onexit`, `onmemoryexecute`, `onmemoryexecuteany`, `onmemoryread`, `onmemorywrite`,
`availableScopes`, `unregisterbyid`, `unregisterbyname`. **There is no scanline or LYC callback of
any kind.** Every mid-frame wakeup available to a Lua script on this build is therefore a memory
callback on an address the game itself touches.

**Emerald's OAM pipeline, from the decomp and the build map** (`C:\dev\pokeemerald`, the sanctioned
address source -- `environment.md`):

| fact | value | where from |
| --- | --- | --- |
| `gMain` | 0x030022C0, size 0x43c | `pokeemerald.map` |
| `gMain.oamBuffer` struct offset | **0x038** | `include/main.h` field walk; cross-checked by the `0x438` annotation on the field after it, and 0x038 + 128x8 = 0x438 |
| `gMain.oamBuffer[0]` / `[64]` | 0x030022F8 / **0x030024F8** | derived |
| `gOamLimit` | 0x02021B38, set to **64** by `ResetSpriteData` | `pokeemerald.map`, `src/sprite.c` |
| `LoadOam` | 0x08007188, copies the **full 128 entries** unconditionally each VBlank | `src/sprite.c` |
| per-frame dummy fill | stops at `gOamLimit`, so **64..127 are never touched per frame** | `src/sprite.c`, `AddSpritesToOamBuffer` |
| `gDummyOamData` (the engine's own "hidden") | attr0 0x00A0, attr1 0x0130, attr2 0x0C00 | `src/sprite.c` |
| rewritten on all 128 every frame | only `affineParam` at byte `+6` | `CopyMatricesToOamBuffer` |
| `BuildOamBuffer` | 0x08006A0C (the hook we already own) | `pokeemerald.map` |

**So the HBlank question is closed for Emerald**: `oamBuffer[64..127]` is dead space that reaches
hardware OAM on the game's own already-paid DMA, and Emerald itself parks the wireless status
indicator at index 125 for exactly that reason. An extra hardware sprite costs three halfword writes
per ghost per frame, with no multiplexing, no scanline hook and no ROM patch. Design and staged
build order: `plans.md` Phase 8.1.

**Two corrections this turned up, both recorded so they do not cost anyone a session:**

- **The "VRAM bank 1, not bank 0 / bit 3 of the OAM attribute" note earlier in this file is a GAME
  BOY COLOR fact** (it belongs to the Crystal work it sits beside). **The GBA has no OAM VRAM-bank
  bit** -- attr2 is 10 bits of tile index, 2 of priority, 4 of palette, and nothing else. Do not
  port that bit to Emerald.
- **A ground-level GBA overworld character is ONE OAM entry**, as `README.md` and `crowd-limits.md`
  say. `probes/capacity_probe.lua`'s "drawn from two" comment was wrong: the elevation-3 subsprite
  table is a single full-size subsprite whose x/y offsets cancel against `centerToCorner`, so the
  subsprite path is geometrically a no-op at ground level. Comment corrected in place.

## 2026-08-21 — Emerald: the shadow-OAM window above `gOamLimit` is real, measured live

**Agent-measured with `probes/oamshadow_probe.lua` (read-only) on the running vanilla Emerald
instance, 2250 overworld frames.** No visual claim is made here and none is needed — every line is a
memory read, which `CLAIM 1`/`CLAIM 3` below settle outright and `CLAIM 2` deliberately does not.

| claim | result |
| --- | --- |
| `gOamLimit` is 64 on the overworld | **HOLDS** — 64 on all 2250 frames, never moved |
| the engine never writes attrs at/above the limit | **HOLDS** — 0 frames moved `+0/+2/+4` in 64..127 |
| nothing already lives in 64..127 | **HOLDS** — high-water of non-dummy entries there: **0** |
| `affineParam` at `+6` is rewritten every frame up there | **NOT SEEN** — 0 frames moved it, so the tier is not fighting `CopyMatricesToOamBuffer` at all in that range. Better than the decomp reading predicted; still write only `+0/+2/+4`. |
| `LoadOam` pushes all 128 to hardware | **UNDECIDED HERE, by design** — see below |

**Why the transfer claim is not settled by this probe, and the trap it walked into first.** Above
the limit both shadow and hardware are dummy, so they agree trivially. Below the limit they differed
on 134 of 2250 frames (~6%), and the probe's first verdict line called that a FAILURE — wrong. This
probe reads at a **frame boundary**, where the engine has already rebuilt the shadow for the coming
frame while hardware still holds the copy `LoadOam` made at the last VBlank. That is one frame of
phase, and it appears exactly when sprites are moving. The verdict text was corrected in the probe
so the log does not mislead the next reader. **The transfer is settled by Stage 1 instead**: park
something non-dummy above the limit and see whether it appears on screen.

**Also confirmed in passing**: `gMain.callback2` holds the **Thumb** form of the pointer —
`0x08085e5d`, not `0x08085e5c`. The adapter has always tested both (`meshghost_emerald.lua:136`); a
probe that tests only the even address stays silent forever and reads as a dead emulator, which is
how the first run of this one looked.

## 2026-08-21 — Emerald: a hardware sprite is DRAWN from Lua, and costs nothing measurable

**Agent-measured, `probes/oaminject_probe.lua` + `probes/fpsride.lua`, same scripted route every
run.** One OAM entry written into `gMain.oamBuffer[64]` every frame, borrowing the player's own tile
number and palette slot, positioned two tiles above the player.

**It renders.** A second copy of the player appears above the player, drawn by the emulated PPU from
an entry no engine code ever wrote. That settles the claim `oamshadow_probe.lua` deliberately could
not: `LoadOam` really does push all 128 entries, so the window above `gOamLimit` reaches hardware.
**The on-screen behaviour — occlusion behind scenery, hiding under the START menu and text boxes,
dimming with fades — is still the user's to confirm** on this vanilla ROM.

**It is free, and that is the headline for the tier:**

| configuration | avg fps | worst |
| --- | --- | --- |
| ride alone (bare control) | 58.1 | 38 |
| ride + an empty second script | 58.1 | 37 |
| probe, everything on, logging to the FILE | **58.1** | 37 |
| probe, everything on, one `console.log` per second | 50.7 / 50.8 | 25 / 27 |
| probe, OAM writes removed | 50.4 | 25 |
| probe, player scan removed | 50.5 | 26 |

So the OAM writes, the per-frame player lookup and the extra hardware sprite together cost **nothing
measurable** against a bare-emulator control — against ~0.6ms per ghost per frame for the painted
tier. The 7.4 fps that looked like the feature was one `console.log` a second; see `pitfalls.md`
2026-08-21, which is also where the general rule was tightened and the template back-port recorded.

**Method note worth keeping:** the empty-second-script row is what made the result trustworthy. It
separates "this probe costs something" from "loading a second script costs something", and it took
one run.

## 2026-08-21 — Emerald: the hardware-sprite tier is FLAT in ghosts, 1 to 56

**Agent-measured, `probes/oaminject_probe.lua` at COUNT=N + `probes/fpsride.lua`**, same 8-leg route
every run, peers spread over the screen in a grid rather than stacked (stacking would measure the
GBA's per-scanline OBJ cycle budget instead, which is a different question). Logging to the file
only, so the 2026-08-21 console trap is not in these numbers.

| hardware sprites injected | avg fps | worst leg |
| --- | --- | --- |
| 0 (bare control, ride alone) | 58.1 | 38 |
| 1 | 58.0 | 36 |
| 8 | 58.0 | 35 |
| 16 | 58.1 | 35 |
| 32 | 58.1 | 37 |
| 56 | **58.1** | 36 |

**The slope is zero within the harness's noise.** 56 extra hardware sprites -- the whole 64..119
window -- cost nothing against a bare emulator. That is the tier's central claim and it is now a
measurement rather than an argument.

**For scale, against the painted tier's own measured per-ghost cost** (~0.6ms/ghost/frame, recorded
2026-08-20): 56 painted peers would be ~33.6ms of host work per frame against a 16.7ms budget for
60fps. That is a derivation from a measured number, not a measured number itself -- a same-session
drawn run at these exact counts is the comparison still owed.

**What this does NOT measure**, and neither should be inferred from it: peers whose ANIMATION FRAME
changes (each change is a tile copy into OBJ VRAM, and that cost scales with moving peers, not with
entries), and the per-scanline case where many sprites share rows.

## 2026-08-21 — Emerald: the three tiers priced against each other, standing still

**Agent-measured, `probes/fpshold.lua` (new), 1800 samples per run, player STATIONARY, synthetic
peers centred on the player so every one of them is genuinely on screen.** Each tier run alone --
no overflow, no mixing -- on the user's instruction: *"just to see how they compare exactly to each
other, don't overflow/mix them"*.

| run | avg fps | lowest |
| --- | --- | --- |
| control, nothing loaded | 60.0 | 58 |
| **SPAWNED**, 16 peers offered (**11 placed** -- the engine's cap on this map) | 60.0 | 58 |
| **DRAWN**, 16 painted | 60.0 | 58 |
| **OAM**, 16 hardware sprites | 60.0 | 58 |
| **OAM**, 56 -- its whole window | **60.0** | 58 |
| **DRAWN**, 56 -- matching OAM's ceiling | **39.6** | 34 |
| **DRAWN**, 150 painted | **10.4** | 6 |

**The like-for-like is the 56 row: OAM 60.0 against DRAWN 39.6, on the same count, same map, same
stationary player.** At 16 the three tiers are indistinguishable from each other and from the
control -- which is worth stating plainly, because it means the tier choice is invisible at small
peer counts and only matters under crowd load. The painted tier then falls off a cliff: 56 peers
costs a third of the frame rate and 150 costs five sixths of it.

**Ceilings are part of the answer and are not the same kind of limit:**

- **SPAWNED** cannot reach 16 at all. `gObjectEvents` holds 16 entries shared with the map's own
  cast; with 5 in use here, 11 ghosts was the whole budget. Hard engine limit.
- **OAM** stops at the 56-entry window `oamBuffer[64..119]`, and is free right up to it.
- **DRAWN** has no ceiling except the host CPU, which is exactly why it stays as the last resort.

**Method notes, both of them mistakes caught before they became conclusions:**

1. **An earlier ride-based comparison was invalid and the user caught it from the screen** --
   *"the drawn ghosts are not following when you go to the left. not accurate testing"*. Synthetic
   peers orbit a FIXED map coordinate while the hardware-sprite probe positions its copies RELATIVE
   to the player, so walking `fpsride`'s route left the painted peers behind and the painted tier's
   own off-screen cull made them nearly free. The adapter's status line had been printing `drawn=0`
   mid-ride the whole time. **A tier comparison must hold the load on screen, which is why
   `fpshold.lua` exists and why `fpsride.lua` is the wrong instrument for it.**
2. **An earlier run showing 2-3 fps for 8 painted peers was the relay's default `-max-clients=8`**,
   not the tier: the adapter logged `relay refused connection: server full` and finished with
   `remotes=0 ghosts=0 drawn=0`, so it was measuring an adapter thrashing to reconnect. The rig for
   these numbers was rebuilt with `-max-clients=200`.

**Networking is not in the difference**: the SPAWNED run carried 16 live peers over a real relay and
core and still measured exactly the bare control, so peer traffic at these counts costs nothing that
this instrument can see.

## 2026-08-21 — Emerald: both cheap tiers FULL at once is still free

**Agent-measured, `probes/fpshold.lua`, 1800 samples, player stationary, crowd on screen.** The
combination the earlier rows do not cover and the one that actually matters for shipping, asked for
by the user: *"what about max spawned ones + max OAM ? still basically 0 impact"*.

| run | avg fps | lowest |
| --- | --- | --- |
| control, nothing loaded | 60.0 | 58 |
| **SPAWNED at the cap (11) + OAM at its ceiling (56), together** | **60.0** | **58** |

**67 characters on screen — 11 drawn by the engine as real object events, 56 drawn by the PPU from
entries we wrote — and the frame rate is indistinguishable from an emulator with nothing loaded.**
Confirmed from the adapter's own status line in the same run (`ghosts=11 drawn=0`) and the probe's
(`COUNT=56`), so neither tier was quietly idle.

Reading it against the rows above: the painted tier alone needs only 56 peers to fall to 39.6. The
two engine-and-hardware tiers together, at more characters than that, cost nothing measurable. That
is the ladder's whole case in one comparison.

**Still not measured**, and neither should be assumed from this: peers whose ANIMATION FRAME changes
(a tile copy into OBJ VRAM per change, scaling with moving peers rather than with entries), and the
per-scanline case where many sprites share rows.

## 2026-08-21 — Emerald: the `spawn -> OAM -> drawn` ladder is built and running

**Agent-measured** (`probes/fpshold.lua`, 1800 samples, player stationary, peers centred on the
player). The hardware-sprite tier is now in the adapter behind `MESHGHOST_EMERALD_HW_OVERFLOW`
(`FLAGS.md`), not a probe. **On-screen behaviour is still the user's to judge** -- what is recorded
here is that it runs, that the dispatch is correct, and what it costs.

| peers offered | spawned | hardware | painted | avg fps | lowest |
| --- | --- | --- | --- | --- | --- |
| 30 | 11 | 19 | 0 | — | — |
| **56** | **11** | **45** | **0** | **60.0** | **58** |
| 150 | 11 | 47 | 83 | 13.5 | 8 |

**The 56 row is the result.** The same 56 peers painted cost 39.6 avg (same instrument, same map,
earlier this date); on the ladder they cost nothing at all. At 150 the ladder still helps but is
dominated by the 83 peers it could not lift off the painted tier -- 13.5 against 10.4 for all-drawn.
**The ladder helps exactly as much as it moves peers off the painted tier, and no more**, which is
the honest way to describe it.

`hw=47` rather than 56 at 150 peers is correct, not a shortfall: the counter reports entries
actually WRITTEN, and a hardware peer that is off screen gets the engine's hidden entry instead.

**Dispatch verified from the adapter's own status line in each run** -- `ghosts` + `hw` + `drawn`
account for every peer in range, no double-rendering, no frame errors in any run.

**Two implementation facts worth keeping:**

1. **The tier's constants had to live on the `tiering` table, not in file-scope locals.** Five
   constants and one helper pushed the main chunk past Lua's hard 200-local ceiling, and that does
   not misbehave at runtime -- the script fails to PARSE. Caught immediately by
   `dev-scripts/bizhawk-syntax-check.lua`, which is exactly the failure it was written for.
2. **The screen-anchor calculation had to be EXTRACTED and shared, not copied.** It is stateful --
   the anchor is only refreshed while the player stands still on a tile-aligned camera -- so two
   copies would drift apart and place the same peer in two places. It also has to run when the
   painted tier is off, which is the shipping default; otherwise the anchor is never calibrated and
   every hardware sprite lands at the wrong offset.

## 2026-08-21 — Emerald: hardware-sprite ghosts move correctly on screen (user-confirmed)

**User-confirmed**, watching six peers circling on the hardware tier with the engine tier starved to
zero so every visible ghost was one: *"It looks smooth i think ? not laggy when moving around
either, they are consistently moving around in the circle. they are all also drawing/showing
properly everywhere"*.

**What that confirms:** the tier renders, the sprites are correct, movement is smooth and consistent
under interpolation, and there is no perceptible frame cost while the player moves around -- which
matches the instrument (60.0 avg standing still with 45 of them).

**What it does NOT confirm, and the word that had to be checked rather than assumed:** *"showing
properly everywhere"* can mean "correct wherever it goes" or "visible even where scenery should
cover it" -- and the second reading would be the tier's central feature FAILING. Asked rather than
guessed, per `CLAUDE.md`'s rule about ambiguous symptom words. The answer was neither: **the peers
could not be taken anywhere.** Synthetic peers from `meshghost-fakeadapter` orbit a fixed map
coordinate, so there was no way to walk one behind a building. *"they don't follow me, so couldn't
check"*. **Occlusion remains unjudged.**

**The fix, and it is a reusable one:** a LOOPBACK ghost echoes the player's own state, so it goes
wherever the player goes -- which is what an occlusion test needs and a fixed synthetic peer can
never provide. The hardware tier now applies the same two-tile side offset the other two tiers give
a loopback ghost, so it stands beside the player rather than on them and can be judged at all.

## 2026-08-21 — Emerald: the hardware-sprite tier renders correctly (user-confirmed)

**User-confirmed**, watching the three-way compare -- one loopback ghost drawn by all three tiers at
once, spawned 2 tiles right, its hardware copy 2 tiles above that, painted 2 tiles left: *"and yes
the OAM looks fine now"*, after two rounds of defects they found by comparing rather than by
looking at the tier alone.

**What that confirms:** the renderer. Sprite, palette, facing, pose and animation match the engine's
own ghost beside it. **Position is deliberately NOT in that claim** -- the compare copy is pinned to
the spawned ghost's sprite (see the entry below), which is what makes the rest judgeable.

### The two defects, and what each one actually was

**1. Facing was inverted half the time.** *"OAM is facing left, whenever i face right"*. Emerald ships
no east-facing artwork: east is the WEST frames with the hardware's horizontal flip set, which is
why one animation number serves both directions. The flip lives at **bit 22 of the animation command
word** -- the same bit the painted tier already reads -- and an OAM entry that ignores it faces the
wrong way exactly half the time. Fixed by reading it from the peer's own current animation command.

**2. The trailing was the SHARED GLIDE, not this tier -- and it was a real shipped bug.** Reported
twice (*"really choppy"*, then *"still trailing behind/not following properly"*). The compare log gave
the number: the camera moved **4px a frame while the glide advanced 1.25**, sawtoothing -- drift for
seventeen frames, then a 2.4-tile snap when the discontinuity guard fired.

Cause: `glideRemote`'s speed limit was measured **between consecutive frames**, and a peer's position
stream is bursty by nature (it creeps for several frames, then jumps at a tile boundary). On most
frames that measured ZERO, collapsing the limit to its 0.02-tile floor -- and a ghost that may move
0.025 tiles a frame cannot follow a player RUNNING at 0.25. Fixed by measuring target speed over an
**8-frame window**, using the history ring the delay line already keeps, so *"nothing arrived this
frame"* reads as the peer's real speed instead of a standstill.

**This affected the PAINTED tier identically and had gone unnoticed since that tier shipped**, for a
structural reason worth remembering: in compare mode the painted copy is pinned to the spawned
ghost's sprite and does not use its own position at all, so the one instrument pointed at it could
not show the fault. It took a THIRD column to make it visible.

### The compare copy is pinned, and that is the point

After the glide fix the hardware copy still trailed while moving, and correctly so: the glide carries
a **deliberate** trailing delay (`genderFrames.drawnDelay`, 8 frames) that reproduces the distance
the engine's own step machine lags by. Any compare copy placed from the glide is therefore 8 frames
behind the reference BY DESIGN -- measured as 0px aligned for 1243 standing frames and up to ~30px
mid-run.

So the hardware compare copy is pinned to the spawned ghost's sprite, exactly as the painted one has
always been. **Verified on the same ride that showed the fault: x offset spawned-vs-hardware is 0 on
all 2520 frames**, y exactly the two-tile park, 58.0 avg fps. Position is removed from the
comparison; what remains different on screen is the renderer, which is what compare mode is for.

### OBJ VRAM: a 944-tile leak that predates this tier

For one test cycle the tier rendered nobody, and the reason was **OBJ VRAM at 996/1024 used** --
`allocSpriteTiles` could not find a 16-tile run. Not this tier's doing: a map load runs the engine's
own `ResetSpriteData`, which frees every range, and the baseline came back **52/1024**. With all
three renderers live afterwards it held steady at **100/1024** over 1440 frames -- flat, no leak.
The ~944 tiles were leaked earlier in the long-running emulator session by something else.

**What was missing was the ability to tell "switched off" from "rendering nobody"**, which cost a whole
cycle. Acquisition failure now logs its reason -- free slots, tiles wanted, graphic id -- throttled
to once per 5 seconds, to the file.

## 2026-08-21 — Emerald: hardware-sprite ghosts ARE occluded by scenery (user-confirmed)

**User-confirmed:** *"Occlusion looked fine on OAM"*.

**This is the claim the whole tier exists for**, and the one thing no measurement of ours could
settle. A hardware sprite is composited by the PPU with a real background priority, so scenery, a
text box and the START menu hide it the way they hide an NPC -- for free, from one 2-bit field
copied out of the graphic's own descriptor. The painted tier cannot do this at all: it is drawn
after the PPU has finished, and its missing occlusion is the blocking defect `BANDAGES.md` has
registered against it since 2026-08-19.

So the ladder's middle rung is now confirmed to deliver the thing that motivated it, not just to be
cheaper. Priority came from the graphic's ROM template with no reconstruction on our side, which is
why it was right first time.

## Emerald: the Acro Bike is FINISHED — shadow, dust and facing, on all three tiers (2026-08-21)

**User-confirmed on screen, end of a long session:** *"a acro bike is confirmed done now"*, and on
what it cost: *"this was probly the single hardest thing to finish for emerald"*.

What is confirmed working, with all three renderers side by side (spawned / OAM / painted):

- **A real shadow SPRITE under a spawned ghost.** No longer painted: a hardware sprite at the
  engine's own subpriority 148, so it sits UNDER the character and under the dust instead of in
  front of everything. The painted shadow is retired for that tier (`BANDAGES.md`). It had been
  written and disabled for a day because it reset the game; the cause was a NULL sprite callback,
  not the tile allocation this file had recorded as the suspect (`pitfalls.md`, same date).
- **Landing dust on all three tiers.** The spawned ghost gets the engine's own; the OAM and painted
  tiers get a puff that stays on the tile it was born on and plays out there while the ghost hops
  away -- confirmed as a trail that follows the ground, not the character.
- **A shadow and dust on the OAM tier for the first time**, as two extra hardware entries per peer
  from pooled tile ranges shared by every peer.
- **The side hop** -- `JUMP_*` 0x42..0x45, which is not an `ACRO_*` action -- gets its shadow, its
  dust on the tile it lands on, and keeps facing forward while travelling sideways.
- **Facing while hopping**: the ghost turns with the peer, without an extra turn animation, and
  without wearing a direction its body is not performing.
- **Ordinary riding no longer inherits a hop or a wheelie** from an earlier one.

**Measured, not felt** (`probes/fpshold.lua`, 30s of continuous hopping with all three tiers live):
`lowest 58.0, average 60.0` -- full speed on the stressed path. A ~1fps regression during the
session was isolated by subtraction to an uncached allocator failure path and fixed; `pitfalls.md`.

**Also measured** (`probes/facing_probe.lua`, frame-stamped): after the final fix the ghost adopts a
peer's new hop action with a gap of **0 frames**, and spends **0** frames at `movementActionId =
NONE` mid-sequence -- the eight-frame idle stall that read as "turning slow" is gone rather than
reduced.

**The engine facts this rests on**, all traceable to our own `make compare`-verified pokeemerald
build rather than to memory:

| Fact | Source |
|---|---|
| `AnimateSprites` calls every in-use sprite's callback with no null check | `src/sprite.c:308-322` |
| `SpriteCallbackDummy` = `08007428` (`70 47` = `bx lr`) | `pokeemerald.map:6220`, `.sym` |
| On-screen flip is `animCmd.hFlip ^ sprite->hFlip` | `src/sprite.c:1246-1251` |
| Shadow templates carry `paletteTag = TAG_NONE`, so paletteNum stays 0 | `field_effect_objects.h:31-70`, `sprite.c:584` |
| Landing dust is positional, not localId-bound | `event_object_movement.c:7994-8001` |
| A jump ends at 16 frames (in-place/normal), 32 (far) | `event_object_movement.c:8462-8492` |
| The side hop is `GetJumpMovementAction`, i.e. `JUMP_*` 0x42..0x45 | `src/bike.c:639-664` |
| It locks facing before jumping, and releases on the next input tick | `src/bike.c:518-523, 662-664` |
| `hasShadow` gates `DoShadowFieldEffect` | `event_object_movement.c:8768-8775` |

**Measured live, and worth keeping**: the engine's own shadow and dust sprites read
`shadow.M sub=148 pal=0` and `dust sub=135 pal=14` -- i.e. dust draws in FRONT of the shadow, and a
shadow really does use OBJ palette 0 while the dust resolves `FLDEFF_PAL_TAG_GENERAL_0` to slot 14.
Both confirmed with `probes/shadowdust_probe.lua`, which identifies field effects by their ROM
`images` pointer rather than by address.

---

## 2026-08-21 (later) -- Emerald: warp fades, the unpinned jump arc, and the water tiers

Five defects, four of them found by the user with all three renderers on screen at once, and every
one of them a case the previous confirmation pass could not have reached. Recorded together because
they share a shape: **a compensation that was measured in one situation and silently assumed to
cover the others.**

### A cave mouth fades to WHITE, and a brightness RATIO cannot see that -- USER-CONFIRMED

**Symptom**, user: *"when going inside a cave, the drawn ghost stays on the screen for a bit too
long."* Only the painted tier; the spawned and hardware ones are drawn by the PPU from the live
palette and fade for free.

**Measured**, `probes/cavewarp_probe.lua`, one real cave entry and exit at Ever Grande:

| Phase | old scalar ratio | the blend fit that replaced it |
| --- | --- | --- |
| fade out to black | 1.000 -> 0.000 | a 1.000 -> 0.000 |
| black hold | 0.000 | a 0.000 |
| **fade in from white** | **1.000 for all 20 frames -- blind** | a 0.000 / b 255 -> a 1.000 / b 0 |

The OBJ palette's channel sum climbs `747 -> 1488` over fourteen frames -- 1488 being sixteen
colours with every channel at 31, i.e. pure white -- and holds for the ~65 frames of the
transition. `live/ROM` reads 1.99 there, clamps to 1, and reports an ordinary scene, so the painted
copy kept drawing at full colour over a washed-out screen.

**The fix is a shape change, not a tuning.** The engine's fades are `BlendPalette`: every colour
moves a fraction of the way toward ONE target colour, `c -> c + (target - c) * coeff/16`
(`src/palette.c`). A scalar ratio can only express the case where that target is black. Fitting
`live = a*rom + b` over all 48 channel values recovers the whole line -- `a = 1 - coeff/16`,
`b = target * coeff/16` -- and covers black, white, a cave's tint, weather and night in one
expression. **User-confirmed on screen**: *"okay the cave thing is fixed"*.

### The jump arc never reached an UNPINNED peer on either self-drawn tier

Both non-engine tiers took a peer's hop from the spawned sprite they are PINNED to in compare mode.
An overflow peer -- one with no spawned counterpart, which is every peer in a real crowd -- has no
such sprite, and its position comes from the glide pipeline, which carries no hop. So a peer was
drawn SLIDING across a ledge, and the painted tier skipped its shadow entirely (its shadow was
gated on `pinned`). **Compare mode pins, which is exactly why no measurement could ever have shown
this.** The peer's own `pos2.y` has been on the wire as `soy` since the surf bob needed it, so the
arc was arriving all along and only these two tiers threw it away. Not yet watched on screen.

### The hardware tier had no surf blob and no reflection -- USER-CONFIRMED

User, on the water at Sootopolis: *"OAM is missing water reflections & the water blob."* Both are
one OAM entry each. The reflection costs no tiles at all -- it is the body's own frame drawn again
through `gReflectionEffectPaletteMap`'s palette at priority 3, and priority is the thing this tier
has that the painted one does not, so the water clips it for free.

**The ripple is the hardware's own.** `SetUpReflection` does not use the flip bits: it makes the
reflection an AFFINE sprite through OAM matrix 0, or matrix 1 when the character is mirrored
(`src/field_effect_helpers.c:66-68`). Those matrices hold `d = -256` and an `a` breathing between
252 and 260, and the engine updates them every frame -- so pointing our entry at the same matrix is
not an imitation of the shimmer, it IS the shimmer. Measured live this session as `a=255 d=-256`.
**User-confirmed**: *"OAM looks fine"*.

**And it is byte-identical to the engine's**, measured afterwards from the OAM buffer itself:

| | y | size | affine | matrix | palette |
| --- | --- | --- | --- | --- | --- |
| engine's own reflections (entries 2, 3) | 86 | 16x32 | 1 | 0 | 1 |
| ours, hardware tier (entry 112) | 86 | 16x32 | 1 | 0 | 1 |

The engine's own vertical offset was read off the sprite table at the same time and is `height - 2`
exactly: player drawn top 208, its reflection 238.

### A reflection is about the GROUND, not about surfing -- USER-CONFIRMED

User: *"the drawn ghost, and probably the OAM, don't have a reflection in the water while standing
on grass/next to water."* Two separate causes with the same symptom:

- **the gate was too tight.** The reflection sat inside the surfing branch on both tiers, with a
  note conceding that a peer beside water reflects too but that the tile lookup did not exist yet.
  It did exist -- `hasReflection` is the engine's own test and was written for that block.
- **the cached-walker path had no reflection code at all.** A peer on foot with no special graphic
  never enters the peer-graphic path, so nothing there had ever run for it. Its frames are decoded
  once at load with the ROM palette baked into each pixel, and a colour cannot be mapped back to
  the index it came from -- so the same picture is decoded a SECOND time from the same ROM address
  with the live reflection palette. No approximation, and the load path's own machinery.

**User-confirmed**: *"yee all ghost have reflections when standing on the grass now"*.

### The water trail, fully specified from the game -- NOT YET CONFIRMED

User: *"drawn & oam are not leaving trails in the water when they move around."* Measured with
`probes/ripple_probe.lua`, watching the game's own ripples while the player surfed:

| What | Value |
| --- | --- |
| template | `0850CB08` -- **derived**, by scanning for the structure whose `anims`/`images` match a live ripple sprite's (`0850CB04` / `0850CAB8`); its callback matches too |
| frame | 16x16, palette tag `0x1005`, subpriority **151** |
| cadence | **one per tile stepped** -- 8 frames apart and 16px apart, and surfing crosses a tile in 8 frames |
| life | 80 frames, 8 animation frames |
| position | character sprite pos1 + `(0, height/2 - 2)`, the engine's own expression |
| behaviour | fixed at birth, camera-anchored -- it does not follow the character |

Subpriority 151 sits between the reflection (152) and the blob (150), which is the depth order the
hardware tier's entry pools were re-cut for. Implemented on both self-drawn tiers; **not yet
watched on screen.**

### The idle pose, and the two reflection defects it was hiding -- ALL USER-CONFIRMED

**A held pose is three writes AND one un-write.** A peer standing still does not report "idle": it
reports the animation it last played, the command index it stopped on, and `animPaused` -- for a
peer facing north, `sanim=5 sidx=3` paused, which resolves to the standing picture. Setting
`animPaused` is not enough while `animBeginning` is still set, and it always is, because a ghost's
sprite is copied from the player's. The engine runs the animation once more before honouring the
pause, and **a running animation copies its frame into the object's tiles** -- so the ghost ended up
with the right numbers and command 0's picture.

Measured with a `GHOSTPOSE` trace: `want=5/3 img=1` against `artRows=11..31`, where image 1's own
art is rows `10..30`. After clearing `animBeginning`/`animEnded` (the exact pair `StartSpriteAnim`
sets, `src/sprite.c:1346-1351`) the same trace reads `artRows=10..30`. **User-confirmed**: *"its
spawning in the idle pose now"*. The held logic now lives in one `applyHeldPose` used by both the
spawn path and the steady-state mirror -- the split between them WAS the bug.

**And that pose was hiding two more, because it was the reference everything else was judged
against.** The user, cutting through a long unproductive investigation: *"you are trying to
test/compare to something, that is not displaying it due to another issue"*, and then *"now you can
at least compare to the spawned ghost properly"*. Both of the following fell out of one framebuffer
diff once the poses agreed.

**A reflection's flip is `h - y`, not `h - 1 - y`.** The engine does not use the OAM flip bit for a
reflection; it makes it an AFFINE sprite through matrix 0 (`src/field_effect_helpers.c:66-68`), and
a GBA affine transform is centred on `h/2` -- 16 for a 32-row sprite, not 15.5. The hardware
therefore samples `texture = 32 - screen`, one row lower than a flip bit's `31 - screen`. The
painted tier used a plain flip and sat one row high everywhere; it was only visible at a shoreline,
where a single row is all there is. Measured: the engine's own reflection pixel at row **108** for a
box starting at 86, against our `inkRange 87..107`. After the fix, `inkRange 88..108`,
`paintedPx=1`.

**The ripple's horizontal scale must use the hardware's own INVERSE mapping.** An affine sprite does
not scale a source run onto the screen -- it walks the DESTINATION and, per screen pixel, samples
`texture = (x - cx) * a / 256 + cx`, truncated. So a source run `[x1, x2]` covers
`[cx + (x1-cx)*s, cx + (x2+1-cx)*s)` with `s = 256/a`: **ceil at both ends**, far edge as `x2+1`
then brought back. Both wrong answers were tried on screen first, and each has its own signature:

| Rounding | What it looks like |
| --- | --- |
| `floor` near / `ceil` far (shipped until now) | a one-pixel run inflates to 2-3 and breathes with the ripple |
| nearest-neighbour at both ends | width correct, but pinned to one column -- no wobble at all |
| **`ceil` both ends** | one pixel wide, moving by one -- the hardware |

**The target was measured, not reasoned**: six screenshots of the engine's own reflection, its
single pixel alternating between columns 53 and 54 (and 117/118, 149/150 for the other two
characters on screen). **User-confirmed**: *"looks perfect now"*.

### Emerald: how a character actually gets onto the water, measured on the player (2026-08-21)

- Date: 2026-08-21 (third session that day)
- Source: **my own reading of `probes/dive_probe.lua`'s log**, written for this session; the player
  was driven from the user's own savestate at the Sootopolis shore. Not a visual claim — every
  number below is a field of the player's own object event, so it needs no watching. The
  ON-SCREEN outcomes of the fixes it prompted are NOT recorded here; they are in `unverified.md`
  until the user says so.

**The sequence, and the gap it exposed.** Starting to surf is four steps
(`Task_SurfFieldEffect`, `src/field_effect.c:2994-3074`), not a graphic change. Measured on the
player's object event:

```
 184 | gfx=3 act=0x39  tile=(38,43)              <- field-move pose (START_ANIM_IN_DIRECTION)
 292 | gfx=2 act=0x3A  tile=(38,44) pos2=(0,-4)  <- surfing graphic + JUMP_SPECIAL, mid-arc
```

`0x3A..0x3D` are `MOVEMENT_ACTION_JUMP_SPECIAL_DOWN..RIGHT`. The graphic and the jump are set in
the same step, and the surf blob is created at the **destination** tile — the jump is what covers
the ground. Written up as game behaviour in the adapter's `documentation.md`.

**What the ghost was doing instead:** `act=0x00/0xFF` throughout. `0x3A..0x3D` was in none of the
adapter's action lists, so the ghost performed no jump at all — it glided onto the sea while the
peer hopped. Fixed by adding the range to the travelling set, where the ledge hop and the Acro
side hop already live; measured again afterwards, the ghost reads `act=3A` two frames after the
peer and takes the same one-tile arc (`pos2 y=-4`). **Two frames is the wire, not a defect.**

**A savestate load invalidates our claim on OBJ VRAM.** Confirmed by the adapter's own log the
moment a state was loaded under a live adapter: `state load detected: emu frame 4194351 ->
4183317`. The engine's tile-allocation bitmap rewinds and our record of what we own does not, so
we go on writing frames into tiles it has since given away. Symptom, cause and the
forget-don't-free fix: `pitfalls.md`. **It is a shipped bug** — loading a state is ordinary
BizHawk use.

**A ghost can be dressed in one graphic and posed from another.** Measured in the same log: the
ghost held `gfx=3` (field-move) while being fed `anim=20` (surfing), because the graphic swap and
the animation mirror are applied by different code on different frames. An animation number is
only meaningful for the graphic it belongs to — the tables differ in length — so the pair is
incoherent for a handful of frames at every transition. Both mirror sites now stand aside while
the two disagree.

### Emerald: the grey/flashing spawned ghost at the start of surfing — USER-CONFIRMED FIXED (2026-08-21)

- Date: 2026-08-21. **Source: the user, on screen, in these words: "The grey/flashing for the
  spawned ghost is not happening anymore. confirmed fixed."** First adapter-side entry under the
  tightened gate, and it cites the user's confirmation, not a probe.
- **The cause**: asking the engine to restart a ghost's animation right after a graphic swap. The
  restart re-copies the frame into the sprite's tiles on the ENGINE's clock — mid-frame, during
  active display — immediately after the tile range moved, when old and new bytes differ most, so
  the PPU could scan the tiles mid-copy: a one-frame torn sprite. Every boundary-time instrument
  (struct, hardware OAM, VRAM-vs-ROM, allocation bitmap) read clean throughout, which is exactly
  what mid-frame tearing looks like from outside.
- **The fix**: engine animation restarts (and the enableAnim un-pause) are refused for 30 frames
  after a ghost's graphic swap; within the window the ghost stays paused and the wire mirror's
  boundary-time frame loads — which cannot tear — carry the pose. Fishing's engine-driven cast,
  user-confirmed 1:1 earlier, is untouched outside the window.
- **How it was found, after six narrower fixes failed on screen — the method outlasts the fix**:
  1. **Subtraction, which should have been first**: with the peer-graphic path off (no swaps) the
     scramble never occurs — the swap is the trigger. One control run ended a day of theories.
  2. **A write breakpoint on the tile range** put BIOS CpuSet bursts inside the ghost's tiles on
     exactly the scramble frames, after five boundary-sampling instruments in a row measured
     clean — a mid-frame writer is invisible to every per-tick probe by construction.
  3. **"One tier is perfect" is a diagnosis**: the OAM tier resolves graphic+animation together
     itself and never showed the earlier incoherent-pair half of this; the tiers are a built-in
     control group. Both lessons are in `pitfalls.md` in full.

### Emerald: the drawn copy no longer vanishes through the HM splash — user-confirmed (2026-08-21)

- Date: 2026-08-21. **Source: the user, on screen**: *"think the drawn ghost looks better now, its
  not disappearing anymore."*
- **The cause**: the painted tier's UI clip reads panels from BG0's tilemap, and the HM banner's
  tilemap rows are fully written for the whole effect — but the game REVEALS the banner through
  hardware window 0, a rectangle it animates open and shut (`field_effect.c:2613-2668`). Clipping
  from the tilemap hid the painted body for all ~76 frames while the engine's own sprites were
  hidden only where the rectangle actually covered them.
- **The fix**: while a show-mon task is live, the panel spans are intersected with that window
  rectangle — read from the TASK's own data (`tWinHoriz`/`tWinVert`, data[1]/data[2]), because
  WIN0H/V are write-only registers and this emulator returns open-bus junk for them (measured:
  WIN0H == WIN0V every sample). Mid-effect the rectangle genuinely covers the character rows and
  everything behind the banner — player and spawned ghost included, confirmed from capture — so
  the drawn copy staying hidden THERE is the game's own behaviour; the edges now open and close
  with the hardware.

### Emerald: savestate loads no longer break any tier — user-confirmed (2026-08-21)

- Date: 2026-08-21. **Source: the user, on screen** — *"Yee looks fine now"*, after water-to-grass
  loads, the case that survived the first two fixes.
- Three causes, peeled in order, each measured before fixed: (1) our tile-claim and OAM-entry
  bookkeeping survives a load while the engine's world rewinds — the adapter now detects the
  emulator's frame-counter jump and FORGETS rather than frees; (2) its own first version then
  violated that rule by freeing tiles inside the despawn sweep, and the rewound gMain.oamBuffer
  can hold entries in slots the fresh roster never re-claims — frees suppressed under the purge,
  and the whole hardware range swept blind; (3) the wire echoes the PRE-load world for 2-4 frames,
  and acting on it rebuilt the pre-load ghost (surf blob and all) on the load tick — the spawned
  and hardware tiers now stand down for twelve frames after a load while the painted tier covers
  the gap. The scripted water-to-grass repro that showed shards and churn shows one clean walker
  acquire on film after the third fix.

### Emerald: the orange glitched sprite (and the wrong Pokémon in the HM banner) — user-confirmed fixed (2026-08-21)

- Date: 2026-08-21. **Source: the user, on screen**, running their own recipe (A to surf, up one
  tile, down, A again, repeated): *"i didn't see any of the orange/glitchy things anymore."*
  Corroborated by a scan of 3172 captured frames of that loop: no orange-pixel spike at all.
- **The cause was a DOUBLE FREE of an OBJ tile range.** Several despawn paths could queue the same
  range for freeing (a ghost's body, its blob, its shadow, a hardware release). Freeing twice is
  not a no-op: the first free releases our bits, the ENGINE then allocates that run for something
  of its own, and the second free clears the bits out from under it -- so the next allocation
  lands on tiles already in use. At a surf start the thing the engine is allocating is the
  show-mon POKEMON PICTURE, which is why the user saw both halves of one collision: a *"weird
  glitched orange sprite"* on the ghosts (our sprite drawing the picture's tiles) and the banner
  showing *"an egg instead of sharpedo"* (the picture drawing ours).
- **The fix**: queueing is idempotent (one pending free per range), and the service point refuses
  to free a range that is not currently marked allocated. Both guards, because either path alone
  leaves the other reachable.
- **The tell worth keeping**: a wrong-but-COHERENT game asset (a clean egg, not garbage) says
  "shared allocation", not "corrupted memory" -- something else is legitimately drawing from a
  range we also think we own. Garbage says corruption; a wrong real sprite says collision.


### Emerald: the orange sprite was a PALETTE SLOT, not tiles (2026-08-21)

- Date: 2026-08-21. **Source: the user, on screen**, after the palette fix: *"orange seems to be
  gone at least"*. (An earlier double-free fix reduced it but did not remove it -- that entry
  above stands as a real bug fixed, not as this one's cause.)
- **The cause**: our surf blob hardcoded OBJ palette slot 0 -- as the engine's own
  `FldEff_SurfBlob` does, which it may, because it runs when its slot is loaded. Ours does not:
  at a surf start the show-mon effect loads a POKEMON's palette, and when it took slot 0 our blob
  drew in that Pokemon's colours.
- **What identified it, and it is the session's most reusable trick**: the user named the SPAWNED
  and DRAWN copies and not the hardware one -- and the hardware tier was the only tier that
  resolved the blob's palette from its template TAG through the engine's table instead of
  hardcoding 0. Three renderers of the same peer are a built-in control group: when one behaves
  and two do not, diff what that one does differently. Both other tiers now resolve by tag.

### Emerald: the DIVE black screen was ours, and the OAM tier cannot draw underwater (2026-08-21)

- Date: 2026-08-21, late. **Source: the user's own dives, bisected live with them**, which is the
  only reason this was found at all.
- **The black screen.** Diving with the adapter loaded left the game stuck on a black screen with
  every palette zeroed, after the dive banner showed *"an egg instead of sharpedo"*. Bisected
  against their dive, one variable at a time: adapter dropped -> fine; spawned tier off -> fine;
  spawned ghosts with blob and bobber off -> fine; blob ON, bobber OFF -> fine; bobber ON ->
  black. **The cause was our UNDERWATER BOBBER**: a faithful copy of the engine's own dummy
  sprite, which holds ANOTHER SPRITE'S INDEX and nudges that sprite every fourth frame. The index
  is only meaningful while the ghost it names is alive; once the slot was reused, our bobber wrote
  into whatever landed there -- during a dive, the show-mon's Pokemon picture. That corrupted the
  pic (the egg) and left its effect waiting forever for a sprite that could no longer report
  itself finished, so the fade-in never ran.
- **The fix**: no bobber at all. A diver's bob is the PEER's own sprite offset, already on the
  wire (`soy`) and already applied to a ghost with no blob -- the same "the peer is the authority"
  answer the surf blob taught. An intermediate version drove the bob from Lua and was also wrong:
  two writers on one field, which the user saw as *"moving really fast/weird"*.
- **The OAM tier is structurally invisible underwater, and stands down there.** Its entries live
  at 64+, sprite ties are broken by entry number, and the game lays a full-screen grid of 64x64
  semi-transparent fog sprites over the scene (measured: entries 4..23, priority 2) with its own
  characters at 0..3 above it. Raising our priority does make the ghost appear -- and drags a
  32x32 white box with it, because a semi-transparent sprite cannot blend against another sprite
  and draws opaque wherever ours is in the way (*"a fog/smoke square that follows the OAM ghost"*,
  at priority 1 and 0 alike). So underwater those peers go to the painted tier, which is drawn
  after the frame and subject to none of it.
- **What this cost, and the rule it earns**: hours, because I twice reproduced an engine mechanism
  by copying its DATA STRUCTURE rather than its EFFECT. A structure that stores another object's
  id is safe for the engine, which owns every lifetime involved, and unsafe for us, who own none
  of them. **Reproduce the effect; never adopt a handle to something the engine can recycle.**

### Emerald: SURFING AND DIVING ARE DONE — user-confirmed (2026-08-21)

- Date: 2026-08-21, end of session. **Source: the user, on screen**: *"It works now, I confirm that
  surf & dive is properly done now."*
- **What that covers**, each fixed and watched during the session (details in the entries above and
  in `pitfalls.md`): the surf-start hop and its pose timing; the grey/flashing spawned ghost; the
  drawn copy vanishing through the HM banner; every savestate glitch; the mount and dismount blob
  behaviour on all three tiers; the orange sprite and the wrong Pokémon in the banner; the dive
  black screen; and underwater ghosts — graphic, bob, and the bob continuing while moving.
- **The last fix, and its shape is the session in miniature**: underwater a diver's bob is the
  peer's sprite OFFSET, and the code that applies it sat inside a gate that deliberately excludes
  a walking peer — correct for animation mirroring, wrong for a position. Idle ghosts bobbed;
  moving ones went rigid. A bob is not an animation.

## Emerald: ice sliding is 1:1 on all three tiers — user-confirmed (2026-08-21)

- Date: 2026-08-21, fourth session that day. **Source: the user, on screen**, in Shoal Cave Low
  Tide Ice Room (`g24.n83`), compare mode on, all three tiers up: *"Ice is done/confirmed."*
- **The game's mechanic, read from the decomp, not guessed.** Shoal Cave's ice is `MB_ICE` (32),
  which `GetReflectionTypeByMetatileBehavior` and the forced-movement table both key on. Stepping
  onto it runs `ForcedMovement_Slide` (`src/field_player_avatar.c:526`), which is `PlayerWalkFast`
  PLUS two bits on the player's own object event: `disableAnim` and `facingDirectionLocked`. The
  crack-and-fall ice is a DIFFERENT mechanic and is Sootopolis Gym only
  (`SetSootopolisGymCrackedIceMetatiles`, `src/field_tasks.c:637`) — nothing in Shoal Cave uses it.

### Three defects, found in the order the user saw them

1. **Reflections shimmered on ice** (*"the OAM & DRAWN ghost reflections are wobbling/moving. they
   are supposed to stay static while on ice"*). The engine has TWO reflection kinds and we had
   one. `GroundEffect_IceReflection` calls `SetUpReflection` with `stillReflection = TRUE`, and
   that flag is the only thing gating `ST_OAM_AFFINE_NORMAL` — a still reflection is a plain
   vertical flip with no matrix, so nothing breathes. Both self-drawn tiers were doing the water
   case unconditionally: the OAM tier pointed its entry at matrix 0/1, the painted tier scaled its
   width by that matrix's `a`. `reflectiveBehaviour` now maps behaviour -> `"ice"`/`"water"`
   instead of `true`, and the kind reaches both draw paths.
2. **Spawned and drawn ghosts walked across the ice** while the player glided
   (*"doing the 'walking' animation instead of freezing/holding the pose"*). Measured with a
   scripted left/right slide, player and ghost on one line per frame: identical `act`, identical
   tile behaviour `mb=20`, and `disableAnim` **1 on the player, 0 on the ghost** — the player held
   anim `11/0` for the whole slide while its copy cycled `11/1, 11/2, 11/3`.
3. **The drawn copy played one extra stride at the stop**, then — once that was fixed — **took too
   long to come to rest**. Both are the glide, not the animation. See the numbers below.

### Why `spaused` was not already enough — the pair, and what each means

`spaused` (the sprite's `animPaused`) was already on the wire and says *the animation is not
running*. `disableAnim` says *this object is FORBIDDEN one*, and that outranks a movement.
Everywhere else in the game the two agree, which is why one bit had sufficed; an ice slide is
where they come apart, because it is a character CROSSING TILES with its legs held still. Sent now
as `extras.noanim`. Three separate things were each independently undoing it:

- `requestAction` set `enableAnim` whenever the sprite was paused — the fix from the muddy-slope
  gliding bug, and exactly wrong here. It now sets `disableAnim` on the ghost instead, **and
  clears it again on the first step off the ice**: the bit is sticky (the engine only ever clears
  it via `enableAnim`), so leaving it set once would cost that ghost its walk cycle for the rest
  of the session — a far worse bug than the one being fixed.
- The animation mirror's gate excluded a peer the engine was already driving, which is precisely
  what stops being true here; `engineDrivesAnim` now yields to `remote.noanim`.
- The painted tier derives its own frame from distance travelled, so it read the slide as walking.

### The held frame is NOT a fixed one — the measurement that mattered

Across runs the player held `10/2`, `11/0`, `11/2`: **the slide freezes whatever frame the walk
cycle happened to be on when it started.** A hardcoded "first frame of the fast walk" would have
looked right about a quarter of the time and been an invisible, intermittent wrongness the rest.
So the painted tier takes the peer's own resolved image index (`genderFrames.peerImageIndex`,
the engine's own two reads: anim table by `animNum`, then by `animCmdIndex`, low half is the
image). Confirmed in the same index space as `DIRECTION_ANIM`: the peer's `11/0` resolved to image
**7**, which is east's `steps[1]`, while the tier was drawing image **2**, the standing frame.

### The stop: two glide defects behind one symptom

- **The extra stride.** The freeze was released on the wire flag, one moment too early — the peer
  unfreezes when the player's slide ends, but the painted copy is still gliding across the ground
  that slide covered, and those catch-up frames went back to the derived cycle. It is conspicuous
  here and nowhere else because the player animates through an ordinary stop and does not animate
  through this one. The freeze is now latched to the GLIDE, and holds a frame remembered from when
  it started — by then the peer is already on its idle frame, which is not the picture a copy
  still moving should wear. `gDist` is reset on release too: none of the distance covered while
  frozen was walked, and leaving it moves the same extra stride one step later instead of removing it.
- **The slow ending, measured** (`probes/tier_compare.log`). `limit` collapses to its
  `0.02 tiles/frame` floor once the peer stops, so whatever ground the copy still owed was paid off
  at a crawl however far it was:

  | at the stop (f=224) | before | after |
  | --- | --- | --- |
  | copy behind the peer | 0.86 tiles | **0.50 tiles** |
  | closing rate | 0.025 /frame | **0.0625 /frame** — its travelling speed |
  | frames to come to rest | 34 (~0.6 s of creep) | **8** |

  0.50 tiles over 8 frames is not lag: it is exactly the 8-frame delay line, the trailing distance
  this tier reproduces on purpose to match a spawned ghost. So it finishes at the pace it was
  going and stops dead. The standing lag during the slide improved as a side effect, because a
  limit that no longer collapses lets the copy keep pace instead of owing the difference.

### `goto_map` was placing nobody, and it trapped the user twice

Not an ice defect, found on the way there and fixed in the same pass. The probe believed
`CB2_LoadMap` runs `WarpIntoMap` and therefore places the player. It does not: that path is
`FieldClearVBlankHBlankCallbacks`, `ScriptContext_Init`, `UnlockPlayerFieldControls`, then
`CB2_DoChangeMap -> CB2_LoadMap2 -> DoMapLoadLoop`, and `WarpIntoMap` — the only caller of
`SetPlayerCoordsFromWarp` — is nowhere on it. So the map changed and the coordinates did not.
Invisible for a week because every warp had been to Mauville (40x20) from somewhere small;
warping out of Route 126 at (45,68) into Mossdeep City (80x40) put the player OUTSIDE the map in
the border fill — open water, `MAPGRID_UNDEFINED` in every direction. It reads exactly like a
hang. The probe now writes `gSaveBlock1Ptr->pos` from `MESHGHOST_WARP_X/_Y` and warns when it is
not given them. **The avatar state needs no help**: the map load re-derives it from the tile landed
on (`GetAdjustedInitialTransitionFlags`), so a surfing player warped onto a cave floor arrives on
foot with no blob to clean up — confirmed on screen.

## Emerald: the OAM tier's stand-down was written for the wrong reason, and fog proved it (2026-08-21)

- Date: 2026-08-21. **The user's call to go and look at real weather fog after seeing the
  underwater fog square** is what turned a place-specific fix into a general one — *"I figured we
  should try to go where there is real fog in the game."*
- **Reproduced on dry land.** Mt Pyre Exterior (`g24.n21`), on foot, no water anywhere: *"the OAM
  ghost is invisible as soon as the fog appears."* The dive session's fix tested for UNDERWATER, so
  it did nothing here.

### What it is, measured (`dev-scripts/fog.log`, `fog2.log`)

| | entries | size | objMode | priority |
| --- | --- | --- | --- | --- |
| the fog | 3–17, twelve of them | 64×64 on a 64px grid, covering the screen | **1, semi-transparent** | 2 |
| the player | 1 | 16×32 | 0 | 2 |
| our OAM ghost | 68 | 16×32 | 0 | 2 |

Equal priority, so the tie goes to the lower entry: the fog draws over entry 68 and under entry 1.

**Two other explanations were eliminated first, not assumed away.** Our entry survives into the
hardware byte-for-byte unchanged across the boundary, in both `gMain.oamBuffer` and OAM itself — so
nothing overwrites or hides it. And DISPCNT, BLDCNT, WININ and WINOUT are identical before and
after the fog appears, so it is not a window or a display-enable. (`BLDY` reads as garbage: it is
write-only on GBA. Worth knowing before trusting a register dump.)

### The earlier reading was wrong, and the player is what disproves it

The dive session recorded *"a semi-transparent sprite cannot blend against another sprite"*. It
cannot be that: **the engine's own character is in front of the same sheet in the same frame with
no artifact.** The difference is HOW you get in front. The player wins at equal priority on a lower
entry number, which does not change the layer the sheet blends against. Outranking it on priority
does — and then the blend fails and the sheet paints opaque.

Measured at priority 1 (`MESHGHOST_EMERALD_HW_PRIORITY`, added for exactly this): the ghost appears,
*"but it has a weird square on itself"* — **one opaque block per entry rectangle**, 16×32 in fog
(*"the tile its at + 1 tile above"*), against roughly 3×3 tiles underwater where the graphic is
wider and the tier places more entries per peer. One rule, two footprints; not two bugs.

### What shipped

The stand-down now tests **the screen rather than the place**: a count of objMode-1 sprites among
the engine's entries, four or more meaning covered (12 in fog, 20 underwater, 0 in normal play).
attr0 only and every 8th frame with the answer latched, because a per-frame OAM scan is the shape
this project has been bitten by. Peers fall to the painted tier, which is drawn after the frame and
subject to none of it — **before this they were simply not drawn at all**, since the painted tier
skips whoever the hardware tier took.

**This is a limit, not a fix, and it is worth being honest about which.** The only artifact-free way
in front of the sheet is the player's — equal priority, lower entry — and entries 0–63 are the
engine's own sprite list, rebuilt and blanked every frame from sprites a ghost cannot join. Taking
one would mean deleting a fog patch to make room for it.

## Emerald: fog and cave darkness — user-confirmed (2026-08-21)

- Date: 2026-08-21, same session as the ice work. **Source: the user, on screen**: *"Ice, fog,
  cave darkness have been confirmed."*
- **Fog** covers the OAM tier's stand-down under a screen-covering semi-transparent sheet, and the
  peers falling to the painted tier instead of vanishing. The entry above has the measurements and
  the reason the tier cannot win that fight. **This is an accepted limit, not a repaired tier.**

### Cave darkness: the painted tier now clips to the flash circle

*"drawn ghost is not hidden in darkness/caves."* In Granite Cave the spawned and OAM copies were
correctly hidden and the painted one shone through the black.

**A dark cave is Window 0, not an overlay.** The engine writes each scanline's lit span into the
scanline-effect buffer and DMAs it to `REG_WIN0H` every HBlank (`sFlashEffectParams` targets
`&REG_WIN0H`, `src/field_screen_effect.c`), so outside the circle nothing is displayed at all. Real
sprites are clipped by the window for free; the painted tier draws after the PPU has finished,
where windows no longer exist. It now reads the same spans and intersects each painted row with
its own — one halfword per row, only while a flash effect is running.

Measured live in Granite Cave B1F: rows 56–104 lit, `114-126` at the top edge widening to `96-144`
at the middle — centre (120, 80), radius 24, i.e. `sFlashLevelToRadius[7]`. Rows outside read `0-0`.

**Unlike the fog, this one was fixable, and the difference is worth naming: the lit region is
READABLE DATA, where the sheet was a priority we cannot win.** That is the question to ask of any
future hardware effect this tier is missing.

**The gate was the dangerous half, not the clip.** An inactive scanline buffer reads as all zeroes
— *nothing lit anywhere* — so trusting it unconditionally would have erased the painted tier on
every ordinary map, far from the cave that motivated it. The effect is confirmed at its source
instead: `gScanlineEffect.dmaDest == REG_WIN0H` with a non-zero `state` (read live in the cave:
`dmaDest=04000040 state=1`). A scanline effect on any other register leaves the tier alone.

**Vanilla only**, like the hardware tier and the fishing hook: those are our own build's addresses.
On a patched ROM the clip declines and a painted ghost still shows through a dark cave —
`unverified.md`.

### Two write-only registers that lie when read

`WIN0H`, `WIN0V` and `BLDY` are write-only and return convincing garbage: `BLDY` swung between
plausible values every frame during the fog investigation, and `WIN0H` read `0x2800` in a cave
whose real span was `96-144`. `DISPCNT`, `BLDCNT`, `BLDALPHA`, `WININ` and `WINOUT` all read fine,
which is exactly what makes the bad ones believable. The live value has to come from the engine's
own copy — for the flash circle, the scanline buffer. `pitfalls.md`, `_template/probes.md`.

## Emerald is FEATURE COMPLETE — the user's call (2026-08-21)

- Date: 2026-08-21, end of the fourth session that day. **Source: the user**, unprompted, after
  the ice/fog/cave-darkness confirmations: *"i consider the game to be fully synced up animation
  and effect wise now."* They also wrote it into the adapter's own build story as step 37.
- **What the claim covers**: every way this game moves a character, and every field effect it hangs
  off one, is mirrored on all three rendering tiers. Walking, running, ledges, the muddy slope,
  fishing, both bikes including the Acro Bike's hop and wheelie, surfing, diving, ice sliding — plus
  the shadow, landing dust, the surf blob, the water trail, the reflection, tall grass, occlusion,
  cave darkness and fog. Each has its own dated entry above; this one records only that the SET is
  now considered closed, by the person who sets the bar.
- **What it does NOT mean.** It is not "no defects" and not "everything watched". It means no known
  animation or effect is missing. Two things stay open and neither contradicts it: the **ferry**,
  which nobody has ridden with the adapter loaded (unchecked, not known-missing — `status.md`), and
  the standing patched-ROM limits, where the hardware tier, the cave clip and the fishing hook all
  decline by design (`FLAGS.md`, `unverified.md`).
- **The bar this was judged against** was the project's own: 1:1 on screen, judged by the user
  watching, never by matching numbers. Every item in the list above was confirmed that way.
- **What it changes for a future session**: a new animation or effect item for Emerald now needs a
  reason it is not polish or a custom feature. The class of work is finished; the next Emerald
  entry here should be a defect, a state nobody had watched, or something the game does not do.


### Drained from the queue 2026-08-25 — the Acro Bike closure, kept for its method

- Date: 2026-08-25 (the confirmation itself is dated 2026-08-21)
- Confirmed by: **the user, on screen** — *"a acro bike is confirmed done now"*. Nothing here
  is newly confirmed. The entry had been marked CLOSED in the queue since 2026-08-21 and
  stayed there because it carries a reusable method: a watchdog on `ghostIsIdle` that logs
  what it frees, and a theory disproved by driving the same actions on the PLAYER. The method
  is worth keeping; the queue is not where it belongs.

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

