# Verified facts

This file records facts that have been confirmed by observing actual behavior in a running
game. See `CLAUDE.md` for the full rule; summary:

- No inferred or speculative values are allowed.
- Every entry must include a source, such as a memory address, API, or documentation
  reference.
- This file is append-only and human-gated: an entry goes in only after the user has
  personally watched the behavior happen. A successful build or a plausible-looking number
  is not sufficient grounds for an entry.

## Entry format

Copy this block per fact:

```text
### <short claim, e.g. "Emerald local player X position">

- Date:
- Observed: <what was seen on screen, and what action produced it, e.g. "printed value
  decreased by 16 per tile when walking left in Littleroot Town">
- Source: <exact file + symbol/line in the referenced repo, or doc page + section>
- Notes: <anything conditional — game version, ROM revision, edge cases found>
```

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

### TEVI Phase 6.1 — BepInEx plugin loads and coexists with the Randomizer

- Date: 2026-08-12
- Observed: `adapters/tevi/MeshGhostTevi` built via `dotnet build -c Release`, deployed to
  `BepInEx/plugins/MeshGhostTevi/MeshGhostTevi.dll`, TEVI launched to the main menu.
  `BepInEx/LogOutput.log` shows `2 plugins to load`, `Loading [MeshGhost 0.1.0]` immediately
  followed by `[Info : MeshGhost] MeshGhost v0.1.0 loaded (Phase 6 step 6.1 hello-world).`, then
  `Loading [Randomizer 1.6.1]` / `Plugin Randomizer is loaded!`, ending in
  `Chainloader startup complete` with no errors. User confirmed the Randomizer's own in-game menu
  entry still renders normally alongside ours loading — no conflict at load time.
- Source: `adapters/tevi/MeshGhostTevi/Plugin.cs` (this repo); confirmed against
  `BepInEx/LogOutput.log` on this machine's TEVI install (`Assembly-CSharp.dll` dated
  2026-07-09, see `agent_docs/environment.md`).
- Notes: per user guidance, an agent-read log line is treated as sufficient confirmation for
  this file (distinct from genuinely visual/gameplay claims, which still require the user to
  watch on screen). Toolchain (netstandard2.0 + BepInEx.Core/UnityEngine.Modules via NuGet)
  confirmed working end to end for TEVI. Coexistence with the Randomizer confirmed at load time
  only — the read-vs-patch conflict risk from `risks.md` isn't tested until 6.2 actually reads
  game memory.

### TEVI Phase 6.2 — real local player position/facing/anim/area tracked correctly

- Date: 2026-08-12
- Observed: `BepInEx/LogOutput.log` (2026-08-12 play session, TEVI + Randomizer 1.6.1 both
  loaded) shows correct "no local player yet" while at the main menu, then live
  `area=… pos=(x,y) dir=… anim=…` lines once in a real play session. Direction correlates
  exactly with position delta over consecutive log lines — e.g. `pos.x` increases only while
  `dir=RIGHT` and decreases only while `dir=LEFT` across a run of 4 consecutive lines — and
  `anim` transitions correctly through `IDLE`/`RUNNING`/`FALLING`/`JUMPING` matching what the
  user was doing. `area` changed `48` → `1` when the user used an in-game teleport-back item
  (a recall/fast-travel mechanic, also used to prevent randomizer softlocks) — the one
  large-coordinate-jump line at the exact transition is the new position read one frame before
  `WorldManager.Instance.Area` itself updated, not a bug (confirmed by the user's explanation of
  what they'd actually done, not guessed at).
- Source: `adapters/tevi/MeshGhostTevi/Plugin.cs`, reading `EventManager.Instance.mainCharacter`
  (type `CharacterBase`) → `.t.position` (`Transform.position`), `.direction`
  (`Character.Direction` enum: `LEFT`/`RIGHT`/`TOPLAYER`/`NOTTOPLAYER`), `.aniStatus`
  (`Character.PlayerAniState` enum: `IDLE`/`JUMPING`/`DJUMPING`/`FALLING`/`FALLING2`/`RUNNING`/
  `DAMAGE`/`BREAKING`/`SLOPED`); and `WorldManager.Instance.Area` (`byte`). All four names and
  types read directly from decompiling this machine's own `Assembly-CSharp.dll` (dated
  2026-07-09, see `agent_docs/environment.md`) with `ilspycmd` — not from memory or guessing,
  same standard as the `pokeemerald` addresses. Decompiled output kept only in the scratch
  directory, never committed; see `agent_docs/licensing.md`.
- Notes: per the same agent-read-log-is-sufficient guidance as the 6.1 entry. **Not yet tested
  with the Randomizer disabled** (the coexistence risk in `risks.md`) — this session only ran
  with it enabled. `PlayerAniState` (9 values, player-scoped) was deliberately chosen over the
  much larger `PlayerLogicState` (~100 values, combat-move-scoped) as the `anim` tag source —
  a smaller, ghost-relevant vocabulary, matching the contract's "each adapter defines its own
  tag set" guidance rather than exposing every internal combat state. `area` is a `byte` — will
  be stringified for the schema's `area_id`, same shape as Emerald's `"{mapGroup}:{mapNum}"`
  string. Not yet decided: what `get_local_state()` should treat as "don't send this frame"
  (menus, cutscenes) — TEVI's equivalent of Emerald's `inOverworld()` gate, deferred to when
  ghost rendering (6.3) makes it concretely necessary.

### TEVI Phase 6.3 — placeholder ghost tracks the local player in-engine

- Date: 2026-08-12
- Observed: user watched a translucent magenta square appear next to their character in a real
  play session, correctly offset, and confirmed it stayed "tied/glued to the player when
  moving/jumping" and did **not** disappear or fail to reappear when changing rooms/areas
  (screenshot: "Oasis Cove" area, ghost visible beside the player character). This is a
  genuinely visual/gameplay claim, confirmed by the user watching it directly, not from an
  agent-read log.
- Source: `adapters/tevi/MeshGhostTevi/Plugin.cs`, `CreateGhost()`/`Update()`. Ghost is a plain
  `SpriteRenderer` on a runtime-generated flat-color texture, positioned every frame at
  `player.t.position + GhostOffset` (no network, fixed local offset only, per the step's scope).
  Recreated lazily (`if (ghost == null) CreateGhost();`) since a scene unload on an area
  transition destroys it along with the rest of that scene's objects — this is what the
  "persisted across a room transition" observation actually confirms, not the same instance
  surviving.
- Notes: this took two real, on-screen-confirmed bugs to get right, both found by the user
  actually testing rather than assumed correct off a clean build (per `CLAUDE.md`'s standing
  rule):
  1. **First attempt was invisible.** `Sprite.Create`'s `pixelsPerUnit=100` shrank a 32px
     texture to 0.32 world units — about 1/200th of `CharacterBase.charHeight = 65f` (a real
     field read from `Assembly-CSharp.dll`). Fixed by setting `pixelsPerUnit=1` and scaling the
     transform to a `GhostSizeUnits = 48` (~0.7x `charHeight`) calibrated against that cited
     fact, not a guess.
  2. **First attempt spammed the console** (7324 lines in one play session). The
     change-triggered logging from 6.2 used a `0.5`-unit position-change epsilon, but real
     per-frame movement in TEVI is itself only ~0.5–0.7 units — confirmed from that very run's
     own log lines (e.g. consecutive `pos.x` values `7403.64` → `7402.85` → `7402.06`) — so the
     epsilon sat at the noise floor and fired almost every frame. This is the same "guessed
     constant instead of measured" mistake already flagged once in Emerald's Phase 5.5 history
     (`STEP_DURATION_FRAMES`). Fixed by capping continuous-position-change logging to a fixed
     `MinLogIntervalSeconds = 0.5` cadence while still logging discrete changes (direction/anim/
     area) immediately.

### TEVI Phase 6.4/6.5 — real bridge→relay→core round trip, loopback ghost confirmed on screen

- Date: 2026-08-12
- Observed: after the `MinSendInterval` fix below, user re-ran a real `cmd/meshghost -game=tevi`
  core and `cmd/meshghost-relay -loopback`, and watched the loopback-echoed cyan remote ghost
  render in TEVI and track their own character (screenshot: cyan ghost overlapping/beside the
  player near a beach umbrella). User confirmed it "follows me really well, even if i move
  around and jump. and also across different rooms" — smooth tracking through movement,
  jumping, and area transitions, no disconnect this time. This is the real Phase 6 analogue of
  Emerald's Phase 3 loopback milestone: a full adapter→bridge→core→relay→core→bridge→adapter
  round trip through real processes, not a same-process shortcut.
- Source: `adapters/tevi/MeshGhostTevi/BridgeClient.cs` (bridge NDJSON client) and `Plugin.cs`
  (`UpsertRemoteGhost`/`DespawnRemoteGhost`, cyan `RemoteGhostColor`, distinct from 6.3's
  magenta local-diagnostic ghost). Core/relay: `internal/core`, `internal/relay` with
  `-loopback` (unmodified relay-side logic from Phase 3, `internal/relay/relay.go`).
- Notes: getting here required first hitting and fixing a real bug (see the next entry below)
  — the first attempt's connection was closed by the relay before the ghost could be clearly
  observed. This confirms the fix actually worked, not just that it compiled and passed a unit
  test. Also investigated and ruled out during this session, not a bug: the magenta ghost
  staying visible after closing the core and relay processes — expected, since it's a fixed
  local-offset diagnostic with no dependency on network state at all (only the cyan remote
  ghost should react to connection state). A one-time crash on moving the TEVI window was also
  reported; not reproduced or diagnosed, though a related-but-unconfirmed background-thread
  BepInEx-logging thread-safety risk was found and fixed defensively regardless (see below).

### TEVI Phase 6.4/6.5 — relay rate-limit disconnect, found live and fixed in `internal/core`

- Date: 2026-08-12
- Observed: relay log showed `client exceeded 120 messages/second, closing connection` roughly
  2m17s after the relay started (01:45:47 → 01:48:04), and the core log showed the matching
  cascade of `send state to relay failed: ... connection was aborted` once the relay side
  closed — TEVI's `Update()` runs uncapped well above the relay's `MaxMessagesPerSecond = 120`,
  and `forwardLocalState` previously sent to the relay on every single call.
- Source: `internal/core/core.go` (`Core.MinSendInterval`, `DefaultMinSendInterval = 50ms` /
  20Hz), gating `forwardLocalState` independent of adapter call rate. Full reasoning in the
  2026-08-12 ADR in `architecture.md`. `agent_docs/contract.md`'s Limits section updated to
  match (the old "up to ~60Hz, one per adapter frame" assumption was itself wrong for a
  frame-driven engine adapter with no fixed cap).
- Notes: this is the exact issue predicted (not guessed at the time, but not yet observed
  either) during Phase 6 planning — see `phase6.md`'s carried-over plan notes. Fixed in
  `internal/core`, not the TEVI adapter specifically, so every current and future adapter
  benefits. Regression-tested (`TestForwardLocalStateRespectsMinSendInterval`,
  `internal/core/core_test.go`, drives 1000 calls in a tight loop and asserts the send count
  stays capped) and the full `go test ./...` suite stays green. While in this code, also fixed
  a real (but not confirmed as the cause of the window-move crash above) thread-safety risk:
  `BridgeClient`'s background connect/read thread now queues log lines
  (`BridgeClient.DrainLogsInto`) instead of calling BepInEx's logger directly from a non-main
  thread.

### TEVI Phase 6 — real character-visual ghost rendering, confirmed correct via loopback

- Date: 2026-08-12
- Observed: entirely solo-testable via loopback (see Part 4 of the planning session's original
  reasoning — a remote's *rendering* doesn't require a second real player, only real remote
  data, which `-loopback` already provides). User confirmed, across two rounds of real bugs
  found and fixed live: the remote ghost is a real clone of the player's own character (not a
  flat placeholder), anchored at the correct body position (not floating near the head),
  offset to the side for solo-testing visibility (not overlapping the real player), facing the
  correct direction when turning, with **no outline-seam glitch**, and "all combat animations &
  everything" playing correctly — confirmed explicitly, not just idle/run/jump.
- Source: `adapters/tevi/MeshGhostTevi/Plugin.cs` (`CreateRealGhostVisual`, `UpsertRemoteGhost`).
  The ghost is `Instantiate(player.spranim_prefer.pixel.gameObject)` — cloning
  `CharacterBase.spranim_prefer.pixel` (`PixelCharacter`, confirmed via decompiling
  `PixelCharacter.cs` to have no `Update`/`Awake`/`Start` of its own, i.e. no gameplay logic to
  strip beyond defensively removing any `Collider2D`/`Rigidbody2D`) rather than the
  gameplay-carrying `CharacterBase`/`playerController` hierarchy. Animation is driven by
  `Animator.Play()` with the *real* currently-playing clip name
  (`SpriteAnimation.GetAnimationTrueName()`, sent as the network `anim` field instead of the
  `PlayerAniState` enum) — chosen specifically to avoid inventing an enum-to-animation-name
  mapping table; confirmed correct on the first real test.
- Notes: three real bugs found and fixed live, each with a concrete, cited cause rather than a
  patched-over symptom:
  1. **Ghost rendered near the head, not the body.** The clone's world position was set
     directly from network position, discarding the local offset between
     `spranim_prefer.pixel.transform.position` and `t.position` that existed in the original
     hierarchy. Fixed by measuring that real offset (`RemoteGhostVisual.AnchorOffset`) at clone
     time and re-applying it every frame — the same class of fix as Emerald's
     `GHOST_Y_CORRECTION`, but derived from a live-read value instead of a hand-tuned constant.
  2. **Facing was inverted**, and caused a visible outline seam. `flipX = (Orientation ==
     "LEFT")` was backwards (fixed to `"RIGHT"`), and only `basesprite.flipX` was being set —
     the outline/effect/flash/support sprite layers are normally kept in sync by
     `SpriteAnimation`'s own per-frame logic, which this clone deliberately doesn't carry (see
     the class comment above `RemoteGhostVisual`), so the outline sprite was stuck at a stale
     flip state whenever facing didn't match it. Fixed by flipping all five sprite layers
     together explicitly.
  3. (Carried from the prior entry) the relay rate-limit disconnect, without which none of this
     could have been observed at all.

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
  live via `adapters/pokemon/emerald/phase1_probe.lua`. User pressed d-pad left, up, right, down (one
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
  that `adapters/pokemon/emerald/phase1_probe.lua`'s decision to re-read `gSaveBlock1Ptr` every frame
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
  on an outdated copy of `adapters/pokemon/emerald/phase1_probe.lua` (no flags/dash/runningState in
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
  `orientation`/`anim` decision in `agent_docs/contract.md`.

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
  `adapters/pokemon/emerald/phase1_probe.lua` together in the same BizHawk Lua Console, against an
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

### Emerald Phase 2 ghost overlay renders and tracks the player near screen center

- Date: 2026-08-11
- Observed: `adapters/pokemon/emerald/phase2_ghost.lua` loaded in BizHawk's Lua Console against the
  same Emerald ROM/save used for Phase 1, standing outside in Littleroot Town. The 16x16
  magenta placeholder image (`adapters/pokemon/emerald/assets/ghost_placeholder.bmp`) rendered on
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

### BizHawk loads a Lua script as an in-memory string chunk, not a file — debug.getinfo can't recover its path

- Date: 2026-08-11
- Observed: `phase3_loopback.lua` computed its own directory via
  `debug.getinfo(1, "S").source`, expecting a `@`-prefixed file path. Running it live threw
  `NLua.Exceptions.LuaScriptException: [string "main"]:130: The specified module could not be
  found` — the `[string "main"]` chunk-name format (Lua's standard formatting for a chunk name
  with no `@`/`=` prefix) proved `source` was just the literal string `"main"`, not a file path,
  so every path built from it silently resolved to `./` relative to BizHawk's own working
  directory instead of the script's real location.
- Source: `TASEmulators/BizHawk` `src/BizHawk.Client.Common/lua/LuaLibraries.cs`,
  `SpawnCoroutineAndSandbox`: `var content = File.ReadAllText(file); var main =
  _lua.LoadString(content, "main");` — the script's text is read in C# and loaded as an
  in-memory chunk, never via a file-path load.
- Notes: the working fix (see next entry) is `io.popen("cd")`, not `debug.getinfo`. Any future
  BizHawk Lua work in this project should assume the same: there is no reliable way to recover
  "this script's own file path" from inside the script via chunk/debug metadata.

### io.popen("cd") reliably returns the script's own directory in BizHawk Lua

- Date: 2026-08-11
- Observed: after the `debug.getinfo` approach above failed, switched to
  `io.popen("cd"):read("*l")` (matching the identical, documented workaround already used by
  Archipelago's `connector_bizhawk_generic.lua`/`socket.lua`). Confirmed independently via
  `cmd /c cd` from a shell with the working directory set to the script's folder, printing
  exactly that path with no extra output — and confirmed live in BizHawk that paths built from
  this (`lib/x64/socket-windows-5-4.dll`, `lib/x64/lua54.dll`, `assets/ghost_placeholder.bmp`)
  all resolved correctly once used.
- Source: `TASEmulators/BizHawk` `src/BizHawk.Client.Common/lua/LuaSandbox.cs`, `Sandbox()` →
  `CoolSetCurrentDirectory` → (Windows) `BizHawk.Common.CWDHacks.Set`, confirmed by reading
  `src/BizHawk.Common/Win32/CWDHacks.cs` to be a direct P/Invoke of the real
  `SetCurrentDirectoryW` — BizHawk genuinely sets the OS process working directory to the
  script's own directory before running it, restoring the previous value after.
- Notes: matches Archipelago's own script's comment ("for some reason `./` isn't working, so
  use a horrible hack to get the pwd") — that project independently found the same thing.

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
  their real paths (`adapters/pokemon/emerald/lib/x64/`) with a direct PowerShell `LoadLibraryW` test
  before asking for a live retry.
- Notes: the vendored `lua54.dll` is a byte-for-byte copy of the one already running inside the
  user's BizHawk install (`C:\ProgramData\Archipelago\Bizhawk\dll\lua54.dll`, matching hash),
  not an independent build — confirmed genuine unmodified upstream Lua 5.4.4 by reading its
  embedded copyright string (`Copyright (C) 1994-2022 Lua.org, PUC-Rio`). See
  `agent_docs/licensing.md` and the Phase 3 ADR in `agent_docs/architecture.md`.

### BizHawk's gui.* drawn graphics persist across frames — they do not auto-clear

- Date: 2026-08-11
- Observed: closing the relay (and separately, the core) while `phase3_loopback.lua` was
  running left the ghost frozen on screen indefinitely — even after the underlying data was
  confirmed correctly cleared (`internal/core`'s remotes map empty, the Lua adapter's own
  `remotes` table empty), the last-drawn image simply stayed visible, because nothing had ever
  called `gui.clearGraphics()`. Adding an unconditional `gui.clearGraphics()` at the top of
  every frame (before any connect/send/draw logic) fixed it — confirmed live: killing the
  relay and separately the core each now make the ghost disappear instantly.
- Source: `TASEmulators/BizHawk` `Assets/Lua/_docs_luacats/gui.d.lua`
  (`gui.clearGraphics` — "clears all lua drawn graphics from the screen", a function that would
  be meaningless if the overlay already auto-cleared); real precedent in BizHawk's own bundled
  scripts calling it every frame for moving overlays (`Assets/Lua/Doom/doom.lua`,
  `Assets/Lua/Genesis/Gargoyles.lua`, `Assets/Lua/Genesis/Earthworm Jim 2.lua`,
  `Assets/Lua/SNES/Super Mario World.lua`).
- Notes: **corrects a wrong assumption stated in `agent_docs/contract.md`'s tick model since
  Phase 2** ("BizHawk's `gui.*` overlay is cleared every frame") — that claim was never
  actually tested against "stop drawing entirely," only against "draw every frame vs. draw at
  network rate," and turned out to be false for the former case. Phase 2's own ghost never hit
  this because it drew unconditionally every single frame for the phase's whole duration. The
  redraw-every-frame requirement itself was already correct; only the stated reason, and the
  missing explicit clear call, were wrong. `contract.md` has been corrected in place.

### internal/core did not despawn remotes when its own relay connection was lost

- Date: 2026-08-11
- Observed: killing the relay process mid-session left the loopback ghost's last known
  position sitting in `internal/core`'s `remotes` map forever — `remoteBuffer.at()` holds the
  newest sample with no extrapolation once render time passes it, and nothing about the
  existing per-frame tick logic had a reason to notice the relay was gone, since only an
  explicit `Leave` message (impossible once the relay itself is unreachable) previously drove a
  despawn. Fixed with `Core.dropAllRemotes()`, wired into the relay connection's
  `OnDisconnect` handler — confirmed live afterward: killing the relay now makes the ghost
  disappear immediately, and the core's own log shows `core: relay disconnected` at the exact
  moment.
- Source: `internal/core/core.go` (`ConnectRelay`'s `OnDisconnect` handler, `dropAllRemotes`);
  regression test `TestOwnRelayDisconnectDespawnsRemotes` in `internal/core/core_test.go`.
- Notes: distinct from the pre-existing, already-correct `TestDisconnectDespawnsRemote`, which
  covers a *peer* disconnecting (driven by a real `Leave` message) — this is the core's *own*
  relay connection dying, which has no `Leave` to drive it.

### adapters/pokemon/emerald/phase3_loopback.lua did not detect its own bridge connection dying

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
- Source: `adapters/pokemon/emerald/phase3_loopback.lua` (`drainBridge`).
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
- Source: `adapters/pokemon/emerald/phase3_loopback.lua` (`drawRemotes`, the
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
  `EmuHawk.exe` instances each running `adapters/pokemon/emerald/phase4_multiplayer.lua` with
  `MESHGHOST_BRIDGE_PORT` set to the matching port. Each client showed a ghost tracking the
  other's real, independent movement — the first time this project has exercised a real second
  physical peer rather than the relay's synthetic `-loopback` echo.
- Source: `adapters/pokemon/emerald/phase4_multiplayer.lua`; `internal/relay`, `internal/core`
  (unmodified from Phase 3).
- Notes: no drift or flicker reported during normal movement, though the placeholder
  magenta-box art makes subtle stutter hard to judge by eye — a real sprite would give a more
  sensitive check. Both clients landed in the same room automatically via matching `-room`
  defaults (`default`).

### Phase 4: real peer leaving (core process closes) despawns correctly; adapter-only disconnect does not

- Date: 2026-08-11
- Observed: closing only the BizHawk/Lua adapter for `player2` (leaving its core process
  running and still connected to the relay) left `player2`'s ghost frozen at its last position
  on `player1`'s screen — correct, since the relay had no `Leave` to broadcast. Separately
  closing `player2`'s core process (clean window close) triggered an immediate despawn of the
  ghost on `player1`'s screen. Reconnecting a fresh BizHawk/core pair afterward was stamped a
  new sequential ID (`p3`, not `p2`) by the relay, as expected from `nextPlayerID`'s
  connection-order counter.
- Source: `internal/relay/relay.go` (`nextPlayerID`, `Leave` broadcast on disconnect);
  `internal/core`'s existing per-remote despawn-on-`Leave` logic (unmodified from before Phase
  3).
- Notes: first real-second-peer confirmation that an adapter dying alone does *not* end the
  session (by design — the peer might just be relaunching BizHawk), only the core's relay
  connection dropping does.

### Phase 4: unclean core kill (Task Manager End Task) also despawns correctly, and the killed peer's own adapter detects it

- Date: 2026-08-11
- Observed: killing `player2`'s (reconnected as `p3`) core process via Task Manager's End Task
  (not a graceful window close) still made the ghost disappear instantly on `player1`'s screen
  — the relay's console logged a `connection error: ... wsarecv: An existing connection was
  forcibly closed by the remote host` at the same moment. `p3`'s own BizHawk console also
  logged `MeshGhost Phase 4: bridge connection lost, will retry connecting.`, confirming its
  adapter independently detected its own core dying.
- Source: same as the two entries above; `adapters/pokemon/emerald/phase4_multiplayer.lua`
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
  `adapters/pokemon/emerald/phase4_multiplayer.lua` reads the same `gSprites[gPlayerAvatar.spriteId]`
  anchor, now shown corrupting *remote* ghost placement on the affected client's own screen, not
  just a local hardcoded-offset ghost.
- Notes: confirms Phase 2's design conclusion still holds and is now demonstrated with a real
  `render_remote` ghost as that entry anticipated: the fix is skipping all ghost drawing on a
  client while *that client's own* player is in battle, not despawning or altering data for the
  player who's fighting. Still needs a verified battle-state detection address before
  implementing — not looked up yet.

### Emerald gMain.callback2 / CB2_Overworld confirmed as a general "not showing the overworld" signal

- Date: 2026-08-11
- Observed: with `adapters/pokemon/emerald/battle_probe.lua` printing `gMain.callback2` on change,
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
  is just one case of that.

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
- Source: `adapters/pokemon/emerald/phase4_multiplayer.lua` (`inOverworld`, gating the `drawRemotes`
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
- Source: `adapters/pokemon/emerald/phase4_multiplayer.lua` (`drawRemotes`); root cause per
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

### Phase 5: Core runs standalone against an in-process fake adapter, no game attached

- Date: 2026-08-11
- Observed: `run-relay.bat` plus two `run-fakeadapter{1,2}.bat` (these three scripts were at
  the repo root at the time; moved to `dev-scripts/` 2026-08-11, same content, see
  `agent_docs/phases/phase5.md`) (`meshghost-fakeadapter.exe
  -name=alice -radius=10 -period=4` and `-name=bob -radius=6 -period=6`) run in separate
  console windows. Each window's `render_remote` lines showed the *other* client's position
  continuously changing — radius holding steady (~10 and ~6 respectively) while the angle kept
  advancing sample to sample, consistent with each tracing its own circle — not frozen, not
  jumping to garbage values. User watched both windows and confirmed this.
- Source: `internal/core/core.go`'s new `Core.RunAdapter` (in-process driver added this phase,
  reusing the existing `tickRenders` diff logic also used by the bridge-wire path) and
  `cmd/meshghost-fakeadapter/main.go`'s `circleAdapter`, which satisfies `core.Adapter` and is a
  pure function of wall-clock time — no game, no bridge socket, no import of anything under
  `adapters/`.
- Notes: this is the Phase 5 milestone from `agent_docs/plans.md` — proof the core has no
  game-specific leaks. `TestRunAdapterInProcess` in `internal/core/core_test.go` covers the same
  path with an assertion (two in-process Cores exchanging state over a real relay); this entry
  is the additional human-observed confirmation the automated test can't provide on its own.
  Console print rate is throttled to `-log-every` (default 500ms) per remote — `RunAdapter`
  itself still ticks at the full `-tick` rate (default ~60fps) underneath; only the demo's
  logging is throttled, not the core's drive loop.

### gObjectEventPic_BrendanNormal / gObjectEventPal_Brendan decode to a real Brendan sprite

- Date: 2026-08-11
- Observed: `adapters/pokemon/emerald/sprite_probe.lua` read `gObjectEventPic_BrendanNormal`
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

### gui.drawPixel color format is 0xAARRGGBB, not 0xRRGGBBAA — and the decoded sprite renders correctly on screen

- Date: 2026-08-11
- Observed: `adapters/pokemon/emerald/sprite_ghost_test.lua`, drawing the same decoded frame from the
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
- Observed: `adapters/pokemon/emerald/phase5_5_sprite.lua` run on two real BizHawk/Emerald instances
  (same two-core/two-relay-client setup as Phase 4). User confirmed: a remote's ghost faces
  all four directions correctly without needing to move a tile first, walking one tile or
  walking around continuously looks correct, and — after the sub-tile position-smoothing fixes
  above — a stationary remote no longer wobbles on a moving viewer's screen, and a moving
  remote no longer looks choppy/teleport-y, including at direction changes, wall bumps, and
  stopping while running. Ledge jumps, Mach Bike, Acro Bike, and Surfing are explicitly not
  covered (see `agent_docs/phases/phase5_5.md`'s deferred-scope note) and still look rough —
  expected, not a regression.
- Source: `adapters/pokemon/emerald/phase5_5_sprite.lua` (`advanceAnim`, `drawSpriteFrame`,
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
- Source: `adapters/pokemon/emerald/phase5_5_sprite.lua` (`readLocalGender`, `loadGenderFrames`,
  `drawSpriteFrame`'s gender parameter); `gSaveBlock2Ptr` = `0x03005D90`, `playerGender` at
  `+0x08` (`include/global.h` L511, `pret/pokeemerald`, same `make compare`-verified build as
  every other address in this file).
- Notes: this is the Phase 5.5 Step 4 milestone and closes the female-save-untested gap in
  `agent_docs/risks.md`. `extras.gender` required no core/relay change — `extras` was already

### Phase 7.1: Pseudoregalia local player pawn/position/rotation/level read confirmed live via UE4SS Lua probe

- Date: 2026-08-12
- Observed: the user launched Pseudoregalia with `adapters/pseudoregalia/probe/Scripts/main.lua`
  deployed as the `MeshGhostProbe` UE4SS Lua mod, then moved around a real castle area for
  roughly a minute — running, crouching, backflipping, hanging on a ledge, jumping off and
  dying a few times, and finally running into a second area (the `ZONE_Dungeon` transition
  below) — and confirmed on screen (`UE4SS.log`, ~190 change-triggered probe lines) that values
  tracked this real movement, not plausible-looking noise. Independently cross-checked by
  reading `UE4SS.log` directly rather than relying on the user's own description alone.
  Specifics:
  - Pawn resolves via `UEHelpers.GetPlayerController().Pawn` to a real Blueprint class,
    `BP_PlayerGoatMain_C` (Pseudoregalia's playable character), confirming a Blueprint-only
    player pawn is reachable through UE4SS's Lua reflection without needing a C++/decompiled
    field name — the open question flagged in `agent_docs/risks.md`'s Blueprint-readability
    risk.
  - `K2_GetActorLocation()` X/Y/Z changed smoothly and continuously across ~180 consecutive
    samples while the user ran around (e.g. `pos=(4900.00, 8450.00, -732.85)` through many
    intermediate points to `pos=(-501.55, 10797.85, -1832.85)`), consistent with real
    continuous movement, not a static or garbage read.
  - `K2_GetActorRotation()`'s yaw changed correctly and continuously while turning (observed
    the full range, e.g. swinging through `-174.30` to `178.46` and back, including correct
    wraparound near ±180°). Pitch and roll stayed exactly `0.00` throughout every sample in
    both levels observed — including through the backflips and ledge-hang the user performed —
    consistent with a standard UE character movement component that only yaws the capsule
    root, with backflip/crouch/hang posing done entirely in the skeletal animation, not the
    actor's root transform. Relevant to 7.6: a wire `orientation` built only from this actor
    rotation will carry facing correctly but no pitch/lean, so a visually convincing ghost
    still needs the `anim` tag to carry pose, not rotation.
  - `level` (read via `world.PersistentLevel:GetFullName()`) changed correctly on a real level
    transition: `.../ZONE_LowerCastle:PersistentLevel` → `.../ZONE_Dungeon:PersistentLevel`
    (`UE4SS.log` 03:01:43–03:01:44) and later back to a *new* `ZONE_LowerCastle` pawn instance
    (`BP_PlayerGoatMain_C_2147473294`, a different object id than the original
    `..._2147480153` — consistent with a fresh pawn spawned on the transition back, not a
    stale/incorrect read).
  - `get_local_state()`-returning-nil equivalent (`"waiting: no valid PlayerController yet"`)
    fired at exactly the moments a real adapter needs to treat as "don't send this frame": the
    title screen before a save is loaded, and during both observed level transitions — never
    spuriously while a valid pawn existed.
  - In `ZONE_Dungeon` specifically, position moved (falling motion, `Y` pinned at `50.00`,
    `X`/`Z` decreasing smoothly) while rotation stayed frozen at exactly `(0,0,0)` for all 5
    samples in that level — likely an intro/fall sequence with rotation not player-driven yet;
    noted, not yet explained.
- Source: `adapters/pseudoregalia/probe/Scripts/main.lua` (this session, 2026-08-12); raw
  values read from `...\Pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\UE4SS.log` lines
  containing `[MeshGhostProbe]`, 2026-08-12 03:00–03:02. UE4SS `v3.0.1 Beta`/SHA `733e5969`
  (see `agent_docs/environment.md`).
- Notes: this is a 7.1 discovery-probe result, not the real adapter — confirms the *read* is
  possible and the values are trustworthy, not any bridge/rendering behavior (7.2 onward,
  not started). `UEHelpers`/`GetPlayerController`/`.Pawn` usage pattern was cross-checked
  against this same install's own bundled `LineTraceMod` example before writing the probe, per
  `agent_docs/licensing.md` — no `pseudoregalia-archipelago` source was read to produce this
  script or these findings.

### Phase 7.2 investigation: UE4SS runtime mismatch breaks AP_Randomizer; UE4SS Lua exposes package.loadlib

- Date: 2026-08-12
- Observed, two separate confirmed facts from the same investigation:
  1. **A mismatched UE4SS.dll build breaks AP_Randomizer, confirmed both ways.** After
     updating the installed `UE4SS.dll`/`dwmapi.dll` from the running `733e5969` build to a
     newer `1c1a1497` build (83 commits ahead, used to match a downloaded zDEV headers
     package), the user launched the game and saw an in-game `ERROR: Incompatible APWorld
     version` screen. `UE4SS.log` showed the real cause: `Failed to load dll
     ...AP_Randomizer\dlls\main.dll..., error: [0x7f] The specified procedure could not be
     found` — a real exported-symbol ABI break, not the in-game message's apparent cause.
     After restoring the original `733e5969` `UE4SS.dll` from a pre-change backup, the user
     relaunched and confirmed getting back in-game normally; `UE4SS.log` independently
     confirmed `AP_Randomizer`'s hooks (`ProcessEvent`, `BeginPlay`, `StaticConstructObject`)
     installing cleanly again.
  2. **UE4SS's embedded Lua 5.4 exposes `package.loadlib` as a real, callable function.**
     `adapters/pseudoregalia/probe_socket/Scripts/main.lua` (`MeshGhostSocketProbe`, Stage 1,
     capability-check only — no DLL loaded), deployed and run live, printed
     `_VERSION = Lua 5.4`, `type(package) = table`, `type(package.loadlib) = function`, and a
     `package.cpath` that already includes each mod's own `Scripts\` folder for `require()`.
- Source: `UE4SS.log` lines around `03:24:11`–`03:26:20` (`.../ue4ss/UE4SS.log`, this
  session); `adapters/pseudoregalia/probe_socket/Scripts/main.lua`.
- Notes: (1) contradicts nothing already recorded but is a real, live-observed instance of
  the "environment drift" risk, now with actual consequences instead of just a version-number
  mismatch. (2) reopens (does not resolve) the earlier Phase 7 adapter-language reasoning —
  that conclusion was based on the *absence* of a first-party socket library, not on
  `loadlib` being disabled. **Not yet tested**: whether MeshGhost's vetted
  `lua54.dll`/`socket-windows-5-4.dll` pair can actually be loaded and used without crashing —
  UE4SS's Lua is statically embedded in `UE4SS.dll`, unlike BizHawk's separate-DLL NLua host,
  so a `lua_State` ABI mismatch here is a real crash risk, not just a load failure. A Stage 2
  script exists but was deliberately not run this session.
  free-form and opaque to both per `agent_docs/contract.md`.

### Phase 7.2: vendored LuaSocket core loads and creates a socket inside UE4SS's embedded Lua

- Date: 2026-08-12
- Observed: `adapters/pseudoregalia/probe_socket/Scripts/stage2_loadlib.lua`
  (`MeshGhostSocketProbe`, Stage 2) deployed over the Stage 1 script and run live. User played
  an extended session — moving around, testing multiple things — with no crashes or
  instability. `UE4SS.log` shows every step completing without error, in order: `lua54.dll`
  preload (`pcall` returned `ok=true`), `package.loadlib` on `socket-windows-5-4.dll` returning
  an opener function, `luaopen_socket_core()` returning without erroring, `type(socketCore) =
  table` with `type(socketCore.tcp) = function`, `socket.tcp()` returning a `userdata` object,
  and a clean `:close()`. `AP_Randomizer` continued running normally throughout (hooks,
  overlay, item messages all logged as usual) — no load-order or coexistence conflict.
- Source: `UE4SS.log` lines around `12:35:30` (this session, 2026-08-12), `[MeshGhostSocketProbe]`
  prefix; `adapters/pseudoregalia/probe_socket/Scripts/stage2_loadlib.lua`.
- Notes: resolves the risk flagged in the entry above — a `lua_State` ABI mismatch between the
  vendored `lua54.dll` and UE4SS's own statically-embedded Lua 5.4 build does not appear to
  corrupt memory, at least through object creation. **Not yet tested**: a real
  `bind`/`connect`/send/receive round trip — Stage 2 deliberately stopped at creating and
  immediately closing the socket object. This reopens the Phase 7 adapter-language decision in
  `agent_docs/phases/phase7.md`: a Lua-only shipping adapter (no C++/UEPseudo build) is now
  plausible, pending that network round-trip test.

### Phase 7.2: real bridge-protocol round trip works over UE4SS's embedded Lua

- Date: 2026-08-12
- Observed: `adapters/pseudoregalia/probe_socket/Scripts/stage3_roundtrip.lua`
  (`MeshGhostSocketProbe`, Stage 3) deployed over the Stage 1 script and run live against a
  real `meshghost.exe` core (`dev-scripts/run-core-pseudoregalia.bat`) with
  `dev-scripts/run-relay-loopback.bat` running behind it. User launched the game: booted fine,
  no lag, freeze, or other weirdness noticed in the menu or in-game, "worked just as usual."
  `UE4SS.log` shows the script connecting, sending a `hello` and a `local_state` frame, then
  receiving a real `render_remote` back on its second attempt:
  `{"type":"render_remote","payload":{"player_id":"p1-ghost","state":{"player_id":"p1-ghost","seq":1,...}` —
  the relay loopback's own-state echo, read back successfully inside UE4SS's statically-embedded
  Lua via the vendored LuaSocket core. A first attempt at this same test surfaced a real core
  bug (`Core.ConnectRelay`'s direct startup path never recorded `c.relayGame`, so the adapter's
  own matching `hello` got refused as a false "second game" conflict) — fixed in
  `internal/core/core.go`, with a regression test (`TestAdapterHelloAfterStartupConnectIsNoOp`,
  `internal/core/core_test.go`) confirmed to reproduce the exact failure before the fix and
  pass after.
- Source: `UE4SS.log` lines around `12:50:08`–`12:50:11` (this session, 2026-08-12),
  `[MeshGhostSocketProbe]` prefix; `adapters/pseudoregalia/probe_socket/Scripts/stage3_roundtrip.lua`;
  `internal/core/core.go` and `internal/core/core_test.go` (commit `8a2228c`).
- Notes: this is the full bridge protocol — connect, send, and receive — working end to end
  through the vendored LuaSocket core inside UE4SS's embedded Lua, with no C++/UEPseudo build
  involved. Closes the `lua_State` ABI-mismatch risk in `agent_docs/risks.md` for this specific
  vendored DLL pair against UE4SS `v3.0.1 Beta`/SHA `733e5969`. A Lua-only shipping adapter is
  now the working plan for the rest of Phase 7, not just a plausible fallback. **Open, not
  investigated**: three further receive attempts in the same run returned empty strings rather
  than `"timeout"` or a real line — logged as observed, not yet explained; worth understanding
  before trusting this probe's read loop as a model for the real adapter's per-frame loop.

### Phase 7.4: spawning the player's own Blueprint as a placeholder ghost physically dragged the player

- Date: 2026-08-12
- Observed: `adapters/pseudoregalia/probe_ghost/Scripts/main.lua` (`MeshGhostGhostProbe`)
  deployed and run live, twice. First run (before two bugs were fixed — see
  `agent_docs/phases/phase7.md`): no ghost visible on screen; `UE4SS.log` explained why —
  `K2_GetActorLocation()` read `(0,0,0)` at spawn time (the pawn existing doesn't mean its
  transform is placed yet during level load), so the ghost spawned near world origin instead of
  next to the player. Second run, after fixing that and a related double-spawn race: the log
  shows a clean single spawn at the player's real position (`before=4900.00`, matching 7.1's
  confirmed values) plus "ghost is following" for ~14.5s. But the user reported being
  **physically dragged/pulled toward another location at high speed** immediately after
  spawning in — sustained forced movement, not a teleport — until dying, after which respawning
  was normal with no further dragging.
- Source: user's live report (this session, 2026-08-12); `UE4SS.log` lines around `13:06:28`–
  `13:06:45`, `[MeshGhostGhostProbe]` prefix; `adapters/pseudoregalia/probe_ghost/Scripts/main.lua`.
- Notes: the log confirms the *spawn* itself was correct on this run (real position, single
  spawn, no error) — the dragging is a *gameplay* effect, not a script bug caught in the log.
  **Working theory, not confirmed**: the ghost is a full, physically-simulated copy of the
  player's gameplay Blueprint (collision, gravity, movement) spawned only 150 units away; if it
  fell/slid under its own physics, its collision capsule pushing against the real player's every
  tick could produce exactly this. Not proven — no direct evidence isolates collision as the
  mechanism versus some other interaction (e.g. a shared component/singleton the Blueprint
  assumes is unique). `MeshGhostGhostProbe` disabled in `mods.txt` pending a redesign;
  `mods.txt` itself was accidentally corrupted (stripped newlines) by a `Set-Content -NoNewline`
  call while disabling it, caught and fixed immediately by rewriting the whole file with a
  known-good line structure — no confirmation the corrupted version was ever read by anything,
  fixed before any further game launch.

### Phase 7.4: the collision theory was wrong — dragging was the script mutating the player's own live position

- Date: 2026-08-12
- Observed: the collision-theory mitigation (`SetActorEnableCollision(false)`/
  `SetActorTickEnabled(false)` on the ghost) was deployed and run live as a third test. The
  user was dragged again — this time described more precisely as a smooth, straight-line drift
  to the side into the void, not a sudden pull — ruling out collision/physics as the cause,
  since both were disabled on the ghost and it happened anyway. Re-reading
  `adapters/pseudoregalia/probe_ghost/Scripts/main.lua` (not guessing again) found the real
  cause: the follow loop read `pawn:K2_GetActorLocation()` fresh every tick and mutated its `X`
  field in place before handing that same object to the ghost's position setter.
  `K2_GetActorLocation()` appears to return a live reference into the actor's own transform,
  not a detached copy, so the "offset" was writing +150 units directly into the real player's
  position roughly every 100ms, compounding forever — exactly the smooth, never-ending
  straight-line drift both drag incidents showed.
- Source: user's live report (this session, 2026-08-12, both the second and third runs);
  `adapters/pseudoregalia/probe_ghost/Scripts/main.lua` (commit `c5a4c7d`, the fix).
- Notes: this also explains why no separate ghost model was ever visible in either drag
  incident — it was likely always co-located with wherever the corrupted player position ended
  up. Fixed by never mutating anything read from the pawn; the offset is now only ever applied
  to a vector owned by the ghost itself. **Not yet retested live** — the collision/tick disable
  calls stay in place as a reasonable safety measure, but the actual fix is this one.

### Phase 7.4: fourth live run, live-reference fix in place, dragged identically

- Date: 2026-08-12
- Observed: the live-reference fix above was deployed and run live as a fourth test. User
  reported being dragged again, same symptom, still no separate ghost model seen — this time
  with a fix in place that addressed a mechanism (mutating a vector read from the pawn) which
  no longer existed anywhere in the code. Two different mutation-target fixes in a row failing
  identically.
- Source: user's live report (this session, 2026-08-12, fourth run).
- Notes: this rules out both the collision theory and the live-reference-mutation theory as
  complete explanations — something else is going on, most plausibly something that makes the
  distinction between "the pawn" and "the ghost" meaningless (e.g. an auto-possession swap; see
  the plan at `C:\Users\nyden\.claude\plans\nope-i-was-still-cryptic-horizon.md` and
  `agent_docs/phases/phase7.md`). Not yet investigated further live — a diagnostic-only script
  (`adapters/pseudoregalia/probe_ghost/Scripts/diagnose.lua`) was written to gather evidence
  before attempting a fifth fix.

### Phase 7.4: root cause confirmed — BP_PlayerGoatMain_C auto-possesses on spawn

- Date: 2026-08-12
- Observed: `diagnose.lua` — deliberately containing zero position-setting calls anywhere —
  deployed and run live as a fifth test. `UE4SS.log` shows `controller.Pawn == ghost: true` on
  every single logged tick immediately after spawning, and the logged player position never
  changed across the entire run (`(4469.77, 8279.23, -732.85)`, identical on every line). User
  reported no dragging this run, and also reported seeing a second model on screen (most likely
  an orphaned ghost left over from an earlier spawn attempt in the same session, since no
  despawn logic exists).
- Source: `UE4SS.log` lines around `13:27:49`–`13:27:52` (this session, 2026-08-12),
  `[MeshGhostDiagnose]` prefix; `adapters/pseudoregalia/probe_ghost/Scripts/diagnose.lua`.
- Notes: direct, conclusive confirmation of the auto-possession theory — `SpawnActor` on
  `BP_PlayerGoatMain_C` really does swap `PlayerController.Pawn` to the newly-spawned instance.
  This also directly confirms the diagnostic itself, with no repositioning code, could not have
  caused a drag — the zero position change over the whole run is positive evidence, not just an
  absence of a negative one. Every previous fix (three of them, across runs 2–4) was moving
  what it believed was a separate, uncontrolled placeholder, but "the ghost" was the actual
  possessed, camera-attached character the entire time. Fixed in `main.lua` (commit `67a499f`)
  by calling `controller:Possess(pawn)` immediately after spawn to hand control back. **Not yet
  retested live** with the offset re-enabled — this run was diagnostic-only.

### Phase 7.4: placeholder ghost confirmed visible on screen — via a hijacked existing actor, not a spawned one

- Date: 2026-08-12
- Observed: `DIAGNOSTIC_HIJACK_EXISTING_PROP` mode (`adapters/pseudoregalia/probe_ghost/Scripts/main.lua`)
  repositioned a real, already-in-the-level `StaticMeshActor` (found via `FindAllOf`) to follow
  the player at the intended 150-unit offset, instead of spawning a new actor. User provided
  screenshots from a live run: a statue in area 1 and a cage in area 2 both visibly followed the
  player correctly, matching `UE4SS.log`'s `intended=`/`actual=` agreement on every logged tick.
- Source: user screenshots (this session, 2026-08-12); `UE4SS.log` lines around `17:16:26`–
  `17:17:04`, `[MeshGhostGhostProbe]` prefix, `DIAGNOSTIC: hijacking existing level prop:` and the
  `pawn=.../intended=.../actual=...` lines that follow.
- Notes: this is the phase's first confirmed-visible placeholder result. It also settles the
  investigation into five prior failed live runs where a freshly `SpawnActor`'d `StaticMeshActor`
  never appeared on screen despite every individual API call (spawn, collision, mesh assignment,
  mobility, position writes) reporting success: **actors spawned at runtime via UE4SS's
  `UWorld:SpawnActor` do not render in this game/build**, while actors that already existed in
  the level before the script touched them render and reposition correctly. Not yet explained —
  leading theory is Blueprint-reflection stripping in this Shipping build (see
  `agent_docs/phases/phase7.md`'s Phase 7.4 entry for the reasoning) — but the symptom itself is
  now directly observed, not inferred.

### Phase 7.4: placeholder ghost confirmed done — spawns, follows, survives level transitions, camera stays correct

- Date: 2026-08-12
- Observed: `adapters/pseudoregalia/probe_ghost/Scripts/main.lua` (cleaned-up final design) spawns
  a second instance of the player's own Pawn class after a short delay, re-possesses the real
  player immediately, and follows at a fixed 150-unit offset. User confirmed live, repeatedly,
  across multiple runs and two level transitions (`ZONE_LowerCastle` <-> `ZONE_Dungeon`): a
  second goat model visibly follows the player, and — critically — the camera correctly stays on
  the real player throughout, including immediately after the ghost spawns and after each level
  transition. `UE4SS.log` shows the underlying mechanism firing and succeeding: this game's own
  `MainPlayerController_C` repeatedly tries to re-target the camera to a different
  `BP_PlayerCam_C` rig in reaction to the ghost spawning (an overlap/proximity trigger), and a
  `RegisterHook`-based post-callback fights back every time, forcing it back to the correct rig
  (`HOOK: FIGHTING BACK ... SetViewTargetWithBlend override: ok`, three separate times across the
  final confirmation run).
- Source: user reports (this session, 2026-08-12, multiple runs); `UE4SS.log` lines around
  `18:21:26`–`18:21:56`, `[MeshGhostGhostProbe]` prefix, `HOOK: FIGHTING BACK` /
  `SetViewTargetWithBlend override: ok`; `adapters/pseudoregalia/probe_ghost/Scripts/main.lua`.
- Notes: this closes a long investigation (full detail in `agent_docs/phases/phase7.md`'s Phase
  7.4 entries) — the eventual fix was not a pawn-side camera/possession fix (five pre-pivot
  attempts and six more this session all failed or had zero visible effect) but intercepting and
  overriding the *game's own* camera-retargeting call in real time. One small accepted visual
  side effect: a brief black flash each time the camera gets forced back, most likely the
  `SetViewTargetWithBlend` cut/blend transition itself being visible for a frame — not
  investigated further, a reasonable tradeoff.

### Pseudoregalia UEPseudo access unblocked, and the C++ hello-world mod builds and coexists with AP_Randomizer

- Date: 2026-08-12
- Observed: the private `deps/first/Unreal` (UEPseudo) submodule, previously confirmed
  inaccessible (`gh api` 404), cloned successfully (2498 real files) after the user linked their
  GitHub account to their Epic Games account and accepted the resulting `EpicGames` GitHub org
  invite. `cmake --build . --config Game__Shipping__Win64` then completed with exit code 0 and
  produced `MeshGhostPseudo.vcxproj -> .../Mod/Game__Shipping__Win64/main.dll` (16.9KB), built
  against a UE4SS configure step that printed `UE4SS Version: 3.0.1.0.0 (733e5969)` — an exact
  match to this machine's installed build. Deployed to `ue4ss\Mods\MeshGhostPseudo\dlls\main.dll`
  and `enabled.txt` (deploy confirmed via `diff`). User launched the game and closed it after it
  loaded; `UE4SS.log` shows `Mod 'MeshGhostPseudo' has enabled.txt, starting mod.` and
  `[MeshGhostPseudo] Phase 7.2 hello-world mod loaded, on_unreal_init reached.` at
  `23:53:48.77`/`23:53:50.08`, essentially simultaneous with `AP_Randomizer`'s own
  `has enabled.txt, starting mod.` line — and `AP_Randomizer` continued working normally
  afterward (hooks installed, its own Archipelago connect/disconnect cycling with no server
  configured, expected and unrelated).
- Source: `gh issue view 577 --repo UE4SS-RE/RE-UE4SS --comments` (the Epic-account-link
  mechanism); local build output
  (`adapters/pseudoregalia/MeshGhostPseudo/build/Mod/Game__Shipping__Win64/main.dll`);
  `UE4SS.log` lines at `23:53:48`–`23:53:50`, `[MeshGhostPseudo]` prefix.
- Notes: closes the Phase 7.2 blocker that had been open since early in this phase (private
  submodule, no prebuilt import library). Reopens the C++/UEPseudo path as viable for 7.5's
  actual open blocker (the vendored-LuaSocket receive-corruption bug under sustained traffic) —
  see `agent_docs/phases/phase7.md`'s 7.2 entry for the full build-toolchain detail (Rust/
  `patternsleuth`, the `Game__Shipping__Win64` config-triplet naming).

### Pseudoregalia C++ mod reads real local-player position natively, tracking through a level transition

- Date: 2026-08-13
- Observed: `UE4SS.log` shows `[MeshGhostPseudo] pawn position: (X, Y, Z)` lines with real,
  changing coordinates every ~2s, correctly re-acquiring the controller/pawn after a
  `ZONE_LowerCastle` -> `ZONE_Dungeon` transition (briefly logging "no PlayerController with a
  valid Pawn yet" mid-transition, then resuming with the new level's controller instance name).
  Two real bugs were found and fixed first via this same log, not guessed: `FindFirstOf` was
  returning the class CDO (fixed with `FindAllOf` + an `RF_ClassDefaultObject` flag check), and
  `GetValuePtrByPropertyName` was reading the inherited `Pawn` property as null (fixed by
  switching to `GetValuePtrByPropertyNameInChain`).
- Source: `UE4SS.log` lines at `00:07:35`-`00:07:42`, `[MeshGhostPseudo]` prefix;
  `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`.
- Notes: this is the C++ equivalent of the Phase 7.1 Lua finding (already verified above),
  redone natively as step 1 of rebuilding the shipping adapter in C++ per the LuaSocket
  receive-corruption blocker — see `agent_docs/phases/phase7.md`'s 7.2 entry and
  `agent_docs/pitfalls.md`'s "Engine reflection / API availability" section for the two bugs'
  full detail.

### Native C++ bridge networking has zero receive corruption, side by side against the Lua version's 98%

- Date: 2026-08-13
- Observed: the still-enabled Lua `MeshGhostGhostProbe` mod and the new C++ `MeshGhostPseudo`
  mod were both connected to the same core bridge port at the same real time, against identical
  live traffic (user playing normally). `UE4SS.log` shows the Lua side's already-known bug
  reproducing exactly: `sends(calls=400 ok=400 timeout=0 error=0) recv(lines=386 decodeFail=379
  unknownType=0)` (~98% corrupted). The C++ side, same window: `bridge: connected=true
  connect_attempts=1 send_ok=6241 send_fail=0 lines_received=6058 lines_malformed=0` -- zero
  corrupted lines. User separately confirmed on screen that the Lua-spawned ghost was visibly
  teleporting (the known bug's visual symptom); the C++ mod does not spawn anything yet, so
  nothing was expected or seen from it.
- Source: `UE4SS.log` lines at `00:14:47`-`00:15:06`, `[MeshGhostGhostProbe]` and
  `[MeshGhostPseudo]` prefixes.
- Notes: isolates the vendored `lua54.dll`/`socket-windows-5-4.dll` pair itself as the cause of
  7.5's original blocker (not the core, relay, or wire format) -- see
  `agent_docs/risks.md`'s LuaSocket ABI entry for the resolution and
  `agent_docs/phases/phase7.md`'s 7.5-in-C++ step 2 entry for full detail.

### C++ mod ghost render-freeze fixed: on_update() runs off the game thread, EngineTick hook doesn't

- Date: 2026-08-13
- Observed: a hijacked level actor repositioned from `Plugin::on_update()` visually froze after
  following correctly for a while, on every test run, regardless of which object was hijacked, in
  both `ZONE_LowerCastle` and `ZONE_Dungeon`, even though every logged position readback
  (`K2_GetActorLocation()` called independently after each write) matched the intended target on
  every single tick with no divergence. After moving all actor reads/writes into a
  `Hook::RegisterEngineTickPostCallback` callback instead (`Plugin::game_thread_tick()`,
  `on_unreal_init()`) and leaving `on_update()` as pure bridge networking, the user confirmed live:
  "yes it works, everything was following me constantly now" -- no freeze, sustained following.
- Source: `UE4SS/src/UE4SSProgram.cpp`'s own `UE4SSProgram::update()` (the function that calls
  every C++ mod's `on_update()`): `ProfilerSetThreadName("UE4SS-UpdateThread")` followed by a loop
  with `std::this_thread::sleep_for(std::chrono::milliseconds(5))` -- a dedicated UE4SS-internal
  polling thread, not the real Unreal game thread.
  `UE4SS/include/Mod/CppUserModBase.hpp`'s `on_update()` declaration (no threading guarantee
  documented). `UE4SS/include/Unreal/Hooks/Hooks.hpp`'s `RegisterEngineTickPostCallback`, which
  hooks the real `UEngine::Tick`.
- Notes: explains the entire render-freeze investigation this session -- direct property writes
  (Mobility, position, `bHidden`) all "succeeded" and read back correctly because the readback was
  same-thread relative to the write, but never reached the renderer, which expects transform
  changes to flow through the real game thread's tick and component-update pipeline. This is the
  same reason Lua code in this project has needed `ExecuteInGameThread()` wrapping for anything
  touching game state -- Lua's `LoopAsync`/callbacks aren't guaranteed to run on the game thread
  either, and the earlier-working Lua hijack script (Phase 7.4, confirmed via screenshots) very
  likely had that wrapping around its position-setting calls, while this C++ port never did until
  now. See `agent_docs/pitfalls.md`'s "Host-embedded scripting runtimes" section for the
  transferable lesson.

### C++ mod: spawn-based ghosts survive the game thread, and the camera fight-back fix works

- Date: 2026-08-13
- Observed: (1) spawning a clone of the local player's pawn class from `game_thread_tick` (the
  real game thread), with the auto-possess safety fix, no longer reproduces the earlier "Fatal
  world leaks detected" crash — user, verbatim: "the game worked fine, no crash" and "i saw the
  ghost/player model". (2) Once `UFunction::RegisterPreHook`-based camera fight-back was added
  (rewriting `SetViewTargetWithBlend`'s `NewViewTarget` argument in place before the engine's own
  native call runs), user confirmed: camera stayed on the player at spawn-in, stayed on the player
  when the ghost spawned in (previously it locked onto the ghost and froze camera control
  entirely), and "the ghost is also following the player perfectly without stopping or
  teleporting."
- Source: `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`,
  `Plugin::ensure_ghost_spawned` and `Plugin::register_camera_fightback_hook`. The
  `RegisterPreHook`/`RegisterPostHook` mechanism itself confirmed against
  `RE-UE4SS/UE4SS/src/Mod/LuaMod.cpp:3907-3921` (Lua's own `RegisterHook` implementation) and
  `RE-UE4SS/deps/first/Unreal/include/Unreal/CoreUObject/UObject/Class.hpp:421-422` (the public
  `UFunction` API).
- Notes: two earlier `RegisterProcessEventPostCallback`-based camera-hook attempts never fired at
  all for this call (confirmed via `UE4SS.log`: zero matching log lines across a live run that
  visibly hit the bug) because this game calls `SetViewTargetWithBlend` as a native function call,
  which does not dispatch through `ProcessEvent`. A separate crash (`EXCEPTION_ACCESS_VIOLATION`)
  was found immediately after this confirmation, when entering a new area — see `pitfalls.md`/the
  next phase7.md entry for the fix; this entry covers only the two behaviors explicitly confirmed
  live above, not area-transition safety.
