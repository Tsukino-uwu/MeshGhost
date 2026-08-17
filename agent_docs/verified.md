# Verified facts

This file records facts that have been confirmed by observing actual behavior in a running
game. See `CLAUDE.md` for the full rule; summary:

- No inferred or speculative values are allowed.
- Every entry must include a source, such as a memory address, API, or documentation
  reference.
- This file is append-only, and gated on evidence whose standard depends on what is being
  claimed. There are two tracks, and **every entry must say which one it is**:
  - **Anything visual or gameplay-facing — how it looks, how it feels, whether it works in
    the game — is human-gated**: it goes in only after the user has personally watched the
    behavior happen. This is the whole adapter surface, and the user is the only one who can
    close it.
  - **Go-side facts — the Go packages, `cmd/`, the relay, the transports — are agent-confirmed**,
    established by running the tools (`dev-scripts/run-gotests.bat`, a log line, a console
    read) and recorded without waiting on the user. That code is deterministic against a
    contract we own, which is exactly why `CLAUDE.md` separates the three.

  In neither track is a successful build or a plausible-looking number sufficient grounds for
  an entry. **Append-only means don't rewrite or delete an
  existing entry's original observation** — it does not forbid adding newly confirmed detail
  to an existing entry (e.g. extending it with a later live-confirmed edge case), which has
  happened before (see the TEVI fog-of-war entry's own edit history) and is a legitimate use,
  as long as what was originally observed stays intact. Superseding an entry (below) is always
  a new entry plus an annotation, never an edit to the old one.
- **A fact confirmed against one build/ROM/version is not automatically true of another.**
  State the scope explicitly in `Notes` whenever it plausibly matters (which ROM revision or
  patch, which game/engine build) — several early entries stated a fact as if build-independent
  and were later directly contradicted by the same fact on a different build (see the
  Archipelago-ROM entries below, and the `Superseded by` annotations they prompted on the
  vanilla-only entries they corrected). When in doubt, state the scope.

## Entry format

Copy this block per fact:

```text
### <short claim, e.g. "Emerald local player X position">

- Date:
- Observed: <what was seen on screen, and what action produced it, e.g. "printed value
  decreased by 16 per tile when walking left in Littleroot Town">
- Source: <exact file + symbol/line in the referenced repo, or doc page + section>
- Notes: <build/ROM/version scope this was confirmed under, if it plausibly matters; any other
  conditional detail — edge cases found, caveats>
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
  **Scope: vanilla ROM only** — see the entry below, "Superseded by" note.
- **Superseded by** (for an Archipelago-patched ROM specifically, not vanilla): "Archipelago-
  patched ROM: gObjectEventPic_BrendanNormal/gObjectEventPal_Brendan decode to garbage, not a
  real sprite" — the addresses above decode to noise on that ROM family; a different offset,
  found via direct ROM-byte comparison, is required instead.

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
  the plan at `~/.claude/plans/nope-i-was-still-cryptic-horizon.md` and
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

### C++ mod: area-transition crash fixed by clearing the cached camera pointer before LoadMap

- Date: 2026-08-13
- Observed: with `last_known_good_view_target = nullptr;` added to the existing `LoadMap PRE`
  hook (before the transition can free the cached `AActor*`), user ran a full session covering
  every transition the earlier crash could hit: entering the second area worked fine, returning
  to the first area worked fine, exiting to the main menu and pressing "play" again worked fine,
  and normal game exit at the end had no issue. No crashes anywhere.
- Source: `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`, the `LoadMap PRE` callback
  registered via `Hook::RegisterLoadMapPostCallback` (same hook `release_all_ghosts` already used).
- Notes: closes the `EXCEPTION_ACCESS_VIOLATION` crash logged in the previous entry's notes.
  Rebuilt via `cmake --build . --config Game__Shipping__Win64` (0 errors), deployed to
  `ue4ss\Mods\MeshGhostPseudo\dlls\main.dll`, deploy confirmed via `Get-FileHash` matching the
  build output exactly, before this test.

### C++ mod: ghost animation state (moveState/actionState/speeds/movementMode) mirrors correctly

- Date: 2026-08-13
- Observed: with the ghost's `moveState`/`actionState`/`horizontalSpeed`/`verticalSpeed`/
  `animJumpType`/`CharacterMovement->MovementMode` written each tick from the real player's own
  values (sent via `extras`, the same opaque-structured-data field Emerald's `extras.gender`
  already uses), user confirmed live: the previously-stiff, non-animating ghost now plays real
  walk/run/idle animations tracking the real player, over a real relay/core/bridge loopback
  round trip. A live trace (`TRACE remote` log lines) also confirmed the writes genuinely stick
  — read-back values after each write exactly matched what was sent, not just "no error."
- Source: `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`, `game_thread_tick`'s
  local-state build and per-remote redraw loop. Field names confirmed via a read-only native
  reflection dump (`log_pawn_reflection_once`, `TFieldRange<FProperty>`) of the real pawn class
  and its `animBPref`-referenced `ABP_PlayerGoat_C` AnimBlueprint instance, not guessed — the
  AnimBP has its own near-exact-name-mirrored locals (`Move State`, `Vertical Speed`, etc.),
  consistent with the standard UE pattern of an AnimBP's Blueprint logic copying state off its
  owning pawn every tick.
- Notes: **not fully solved** — the ghost still gets stuck in a falling/airborne pose after
  landing (a slide forces a reset; two separate fix attempts, mirroring `MovementMode` and
  mirroring `landed?`/`jumped?` as latched one-shot pulses, both failed live), can't grab
  ledges, and does not turn to face different directions (a separate, previously-unnoticed
  issue). See `agent_docs/plans.md`'s deferred animation-polish note and `agent_docs/risks.md`'s
  ghost-collision entry for why collision was tried and reverted as a possible fix for the first
  two.

### C++ mod: ghost facing-direction fix — vendored SDK marshaled FRotator as float on a UE5 game

- Date: 2026-08-13
- Observed: with `FORCE_ROTATION_CYCLE_TEST = true` (forces the ghost's target yaw through
  0/90/180/270 on a ~3s timer, independent of the real player's own facing) and the new
  `call_set_actor_location_and_rotation` helper routing the ghost's rotation write, user
  confirmed live, verbatim: "it works!, the ghost is turning around." `UE4SS.log` cross-check
  from the same run shows the previously-garbage readback replaced by exact agreement between
  sent and reflected values at every step, e.g. `forcing ghost yaw to 180` immediately followed
  by `TRACE remote local-test yaw: sent=180 K2_actual=180 reflected_actual=180`, and
  `sent=270 K2_actual=-90.00000000000001 reflected_actual=-90.00000000000003` (270° and -90° are
  the same angle — expected normalization, not an error). The one-time diagnostic line
  `call_set_actor_location_and_rotation: NewLocation@0 NewRotation@24 inner_type=double
  parms_size=296` confirms the helper resolved real reflected offsets and chose the `double` path
  for this UE 5.1 build, as intended.
- Source: `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`,
  `call_set_actor_location_and_rotation` (new helper) and its two call sites in
  `run_local_offset_test_tick` and `game_thread_tick`. Root cause traced to
  `RE-UE4SS/deps/first/Unreal/src/AActor.cpp`'s `K2_SetActorLocationAndRotation` /
  `K2_SetActorRotation`, which marshal `FRotator`'s `Pitch`/`Yaw`/`Roll` as hardcoded `float`
  into the reflected parameter buffer (`UE_COPY_STRUCT_INNER_PROPERTY(..., float, ...)` at
  `AActor.cpp:120-130` and `:92-105`), unlike `FVector`'s `X`/`Y`/`Z`, which correctly branch on
  engine version via `UE_COPY_VECTOR`
  (`RE-UE4SS/deps/first/Unreal/include/Unreal/BPMacros.hpp:120-132`). Pseudoregalia is UE 5.1
  (confirmed in `phase7.md`'s 7.0 entry), where the real `FRotator` fields are `double` — writing
  a 4-byte float into an 8-byte slot of a zeroed buffer produces a denormal
  (`90.0f`'s bit pattern in a zeroed double slot is exactly `5.529052754e-315`, matching the
  `~5.5e-315` garbage logged during the investigation to three significant figures).
- Notes: fixed with a local, version-aware helper in `Plugin.cpp` rather than patching the SDK —
  `RE-UE4SS` is a git submodule (pinned at `733e5969`), so this repo tracks only its commit, never
  its file contents; an SDK patch could not be committed here at all. The helper only covers
  `K2_SetActorLocationAndRotation`, the one rotation-writing function this file calls — the same
  bug affects `K2_SetActorRotation` and presumably other native `FRotator`-taking functions in
  this SDK; do not assume any of those are safe without routing through an equivalent helper. See
  `agent_docs/pitfalls.md`. A separate, unrelated sign error found in the same investigation
  (`FRotator::Quaternion()`, `Rotator.hpp:158`, missing a negation on the `Y` term) is harmless
  for this pawn (pitch/roll are confirmed always zero, per Phase 7.1) and was left unfixed.
  **Real-networked-path verification, same day, follow-up**: with `LOCAL_OFFSET_TEST_MODE`/
  `FORCE_ROTATION_CYCLE_TEST` flipped back to `false` (real bridge/relay/core loopback, ghost
  mirroring the real player's own yaw instead of a forced cycle), user confirmed live: "its
  following properly now" — the ghost's facing now tracks the real player's turning, closing the
  gap this entry originally left open. See the new entry below for what this fix additionally,
  unexpectedly enabled and surfaced.

### C++ mod: facing-direction fix also fixed ledge-grab, and exposed a pre-existing stuck-animation bug

- Date: 2026-08-13
- Observed: with the facing-direction fix confirmed over the real networked path (previous
  entry), user reported the ghost "managed to grab onto a ledge now when the facing was fixed"
  — ledge-grab, one of the two animation gaps left open by the same day's earlier "ghost
  animation state" entry, was never a separate bug; it depended on the ghost's rotation actually
  reaching the renderer; e.g. plausibly UE's ledge-grab detection needs the character's facing to
  be geometrically correct to trace against. Also newly visible now that ledge interactions work
  at all: the ghost gets stuck in the ledge-hang animation after the real player has already let
  go and moved away. The other known-open animation bug — getting stuck in a falling pose after
  landing — is unaffected by this fix and still reproduces exactly as before.
- Source: `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`,
  `call_set_actor_location_and_rotation` (see previous entry) and the animation-mirroring block
  in `game_thread_tick` (see the "ghost animation state" entry).
- Notes: **not a fix for either animation-stuck bug** — this entry records what the rotation fix
  incidentally enabled/revealed, not a resolution. Two open animation bugs remain, both
  plausibly the same root-cause class as the already-tried-and-failed `landed?`/`jumped?` pulse
  mirroring: a one-shot state transition on the real player's side (landing, or releasing a
  ledge) that isn't being mirrored onto the ghost, so the ghost's AnimBP never receives the event
  that would move it out of the sustained pose. Not yet investigated further.

### C++ mod: stuck-falling-pose fix — the earlier `landed?`/`jumped?` pulse attempt was never actually tested

- Date: 2026-08-13
- Observed: the prior "failed live" pulse attempt (previous entry's notes) turned out to be a
  silent no-op, not a disproven theory — a real reflection dump grep confirmed `landed?`/
  `jumped?` exist only on `animBPref` (the AnimBP instance), never on the pawn the old code
  actually read/wrote. Redone to hop through `animBPref` on both ends, with the wire field
  changed from a single-tick bool to a monotonic `land_count`/`jump_count` counter (a bool pulse
  can't survive `Core.DefaultMinSendInterval`'s 50ms send-rate cap against a ~60Hz game thread,
  or `remoteBuffer.lerp` holding `extras` from the older bracketing snapshot) and a 3-tick hold
  window on the ghost's write side. User confirmed live after a real jump→land cycle: "not stuck
  in a 'falling' animation anymore after jumping." Trace log cross-check (`UE4SS.log`) for the
  same session shows `land_count`/`jump_count` incrementing once per real edge, the ghost's
  `animBPref->landed?`/`jumped?` write readback confirmed `true` during the hold window, and
  `moveState`/`actionState`/`movementMode` all resetting on the ghost within ~1s of a real
  landing.
- Source: `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp` —
  `read_animbp_bool`/`write_animbp_bool` helpers, the edge-detection block in `game_thread_tick`,
  and the hold-window block in the redraw loop. Reflection dump confirming `landed?`/`jumped?`
  live only on `animBPref`: `UE4SS.log` DIAG lines from `log_pawn_reflection_once`, lines 1774-
  1775 in the 2026-08-13 12:25 capture (`animBPref property 'landed?' (BoolProperty)` /
  `'jumped?' (BoolProperty)`), absent from the pawn's own property list earlier in the same dump.
- Notes: the ledge-hang-stuck-forever bug (next entry) was still open at this point in the
  session — this entry is the falling-pose fix specifically.

### C++ mod: ledge-hang-stuck-forever fix — the pose was an Anim Montage, not a state-machine transition

- Date: 2026-08-13
- Observed: even with the falling-pose fix above confirmed working, user reported the ghost
  stayed frozen in the ledge-hang pose indefinitely after releasing a ledge, and that jumping,
  sliding, or "doing anything else" on the real player's side never reset it. A live trace
  capture of one real hang→release→land cycle proved `moveState`/`actionState`/`movementMode`
  all reset correctly on the ghost within ~1s (readback-confirmed) — meaning the pose was
  provably outliving every state-machine byte resetting, the signature of an Anim Montage played
  independently of those bytes. A read-only `UFunction` enumeration of `animBPref`'s class chain
  (not a guessed name) found a real `Montage_Stop` function on this build; a follow-up read-only
  `FProperty` dump of that exact function confirmed its real parameters — `InBlendOutTime`
  (`FloatProperty`, offset 0) and `Montage` (`ObjectProperty`, offset 8, left null to stop
  whatever is currently playing). Wired to call on the ghost's `animBPref` on the same
  land/jump-edge rising-edge logic as the falling-pose fix. User confirmed live: "its working,
  ... now its actually going back to normal/other animations." A residual ~150-200ms lag behind
  the real player was also reported and traced to the existing, already-accepted
  `DefaultInterpolationDelay`/send-rate-cap trailing delay (the same one Phase 3 confirmed for
  ghost position), not the fix itself — reducing `Montage_Stop`'s blend-out from 0.15s to 0.0s
  made no observable difference, consistent with that lag living elsewhere in the pipeline.
- Source: `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp` — `call_montage_stop`
  (helper, confirmed-parameter-name pattern matching `call_set_actor_location_and_rotation`/
  `call_set_collision_response_to_channel`) and its call site in the redraw loop's land/jump-edge
  block. `UE4SS.log` DIAG lines from the 2026-08-13 16:25 and 16:28 captures: UFunction
  enumeration listing `Montage_Stop` (`PropertiesSize=16`) among many other real
  `UAnimInstance` montage functions, and the follow-up dump `Montage_Stop param
  'InBlendOutTime' (FloatProperty) offset=0` / `param 'Montage' (ObjectProperty) offset=8`.
- Notes: both animation-stuck bugs found in the "facing-direction fix" entry above are now
  closed. `ANIM_PULSE_TRACE`, the dense every-tick diagnostic added for this investigation, has
  been flipped back to `false` and the shipping `main.dll` rebuilt/redeployed/hash-diff-confirmed
  without it. Not yet investigated: whether `Montage_Stop` should also fire at other transition
  points (e.g. an area change) as a defensive measure — not needed for anything reproduced so
  far. **Same-day follow-up, user tested further traversal mechanics with no code changes**: wall
  gliding (cling gem) and multiple wall kicks in a row both "worked perfectly"/"just fine" on the
  ghost, confirming the existing continuous-state mirroring
  (`moveState`/`actionState`/`horizontalSpeed`/`verticalSpeed`/`movementMode`, from the original
  "ghost animation state" entry) generalizes to these mechanics without needing any
  mechanic-specific handling — only the one-shot pose transitions (falling recovery, ledge-hang
  exit) needed the `landed?`/`jumped?`/`Montage_Stop` work above.

### TEVI build 14778703 allows two simultaneous local instances

- Date: 2026-08-13
- Observed: user launched their normal Steam-library TEVI copy first (confirmed running), then
  launched `TEVI.exe` directly from a standalone `steamcmd +download_depot` copy of build
  `14778703` (2024-06-20) in a separate folder. Both windows were open at the same time, each
  showing the TEVI title screen, screenshotted side by side.
- Source: SteamDB `https://steamdb.info/patchnotes/14778703/`, depot `2230651`, manifest
  `7992513181981867642` — downloaded via `steamcmd +login <user> +download_depot 2230650
  2230651 7992513181981867642`. `steam_appid.txt` (containing `2230650`) added to the standalone
  folder so the exe's `steam_api64.dll` would initialize without being launched by Steam.
- Notes: **supersedes the "confirmed not to work" v1.01-branch entry in
  `agent_docs/phases/phase6.md`'s Notes section** — that earlier attempt's "Unable to Sync"
  dialog is now understood to have been caused by the `steamcmd` login itself signing the user's
  normal Steam session offline (Steam only allows one online session per account), not by a
  genuine single-instance-per-app block. This time the normal Steam client was confirmed online
  and TEVI running through it *before* launching the standalone copy, isolating the actual
  variable. Unblocks Phase 6.6 (two real players) for local testing without needing a second
  machine — still needs the actual gameplay/multiplayer test (both ghosts visible, moving,
  cross-area filtering), not just "both processes launch."

### v0.2.1 release: TEVI loopback ghost renders on the real, current TEVI build

- Date: 2026-08-13
- Observed: user reinstalled TEVI clean via Steam (fresh game files, fresh BepInEx, no
  Tevi Randomizer or other leftover mods), deployed `MeshGhostTevi.dll` from the v0.2.1
  release, ran it against the dev-only relay `-loopback` flag plus the release's own
  `meshghost.exe`. `meshghost.log` showed `connected to relay 127.0.0.1:7777 as p1 in room
  "default" (game "tevi")`; the BepInEx console showed `MeshGhost: connected to bridge at
  127.0.0.1:7778.`, `real remote ghost visual created for p1-ghost`, and continuous
  `local state: area=... pos=... anim=...` lines while playing. User confirmed watching the
  ghost render, animate, and follow the local player's movement correctly in-game on both the
  old test build and the current/Steam build, not just reading the logs.
- Source: `meshghost.log` / BepInEx `LogOutput.log`, this session's own transcript.
- Notes: this is the loopback **self**-ghost path (echoes the one real player's own state
  back as a ghost), not yet two distinct real players — TEVI's README EXPERIMENTAL status for
  real two-player testing stands until that's separately confirmed.

### MeshGhostTevi: EventManager.mainCharacter access must go through reflection, not a direct property read

- Date: 2026-08-13
- Observed: an older TEVI build (SteamDB build `14778703`, 2024-06-20, kept for local
  dual-instance testing) crashed every frame with `MissingMethodException: Method not found:
  CharacterBase .EventManager.get_mainCharacter()` when running a `MeshGhostTevi.dll` built
  against the current TEVI build. Decompiling both builds' `Assembly-CSharp.dll` with
  `ilspycmd` showed `EventManager.mainCharacter` is a plain public field on the old build but
  a property (backed by a private `_mainCharacter` field) on the current build — confirmed
  independently by the TEVI/`Tevi_Randomizer` developer, who has the actual source. After
  changing `Plugin.cs` to resolve `mainCharacter` via `System.Reflection`
  (`GetProperty`/`GetField` fallback) instead of a direct `.mainCharacter` read, user retested
  both the old build and the current/Steam build: both connected, both rendered a real ghost,
  no crash on either.
- Source: `adapters/tevi/MeshGhostTevi/Plugin.cs` (`GetMainCharacter`, added this session);
  old-build crash trace from `%LOCALAPPDATA%Low\CreSpirit\TEVI\Player.log`; current-build
  member shapes read directly via `ilspycmd -t EventManager` on each build's own
  `Assembly-CSharp.dll`.
- Notes: only `mainCharacter` was confirmed to differ between these two builds — other
  members the plugin touches haven't been individually checked against the old build, so
  the old build still isn't a guaranteed-compatible target beyond what's actually been
  exercised live.

### v0.2.1 release: bundled UE4SS runtime works clean, ghost renders on Pseudoregalia

- Date: 2026-08-13
- Observed: user fully uninstalled Pseudoregalia, manually deleted the leftover install
  folder (Steam's uninstall alone left `ue4ss\`/`dwmapi.dll`/old mods behind from prior dev
  work), reinstalled via Steam, then copied only the v0.2.1 release's `ue4ss-runtime\`
  (bundled UE4SS, no separate download) and `MeshGhostPseudo\` into the fresh install. First
  attempt showed no ghost because `meshghost.exe` was still locked to `game_id="tevi"` from
  the earlier TEVI test on the same process (see `contract.md`'s one-`game_id`-per-process
  rule); after restarting `meshghost.exe`, `meshghost.log` showed `connected to relay
  127.0.0.1:7777 as p2 in room "default" (game "pseudoregalia")` and the user confirmed
  watching the ghost render correctly in-game. Also confirmed: after disabling
  `ConsoleEnabled`/`GuiConsoleEnabled`/`GuiConsoleVisible` in the shipped
  `UE4SS-settings.ini` (previously left at RE-UE4SS's own stock defaults of `1`, which had
  popped an unwanted cmd window and debug overlay on the first test), a repeat run showed
  neither window.
- Source: `meshghost.log`, this session's own transcript.
- Notes: completes this session's clean-slate release validation for both shipped games
  (TEVI's own clean-slate entry is above). Same loopback self-ghost caveat as TEVI's entry —
  not yet two distinct real players.

### MeshGhostPseudo survives an AP_Randomizer reinstall that silently swaps the shared UE4SS runtime

- Date: 2026-08-13
- Observed: user reinstalled the Archipelago mod (`AP_Randomizer`) on top of an existing
  MeshGhostPseudo install. Filesystem inspection showed the reinstall rewrote not just its own
  `ue4ss\Mods\AP_Randomizer\` folder but also the *shared* runtime files `dwmapi.dll`,
  `ue4ss\UE4SS.dll`, and `ue4ss\UE4SS-settings.ini` (all rewritten at the same instant,
  08/13 19:14:52) — `MeshGhostPseudo\`'s own files were untouched (still 18:21:01). The
  resulting installed `UE4SS.dll` is a different build than the one MeshGhost bundles in
  `packaging/release/games/pseudoregalia/ue4ss-runtime/`: different size (16,240,640 vs.
  16,248,832 bytes) and different SHA-256 (`B379...79FB1` vs. `B36F...53F2F89`), confirmed via
  `Get-FileHash`. Despite the mismatch, user launched Pseudoregalia after the swap and
  confirmed watching the loopback ghost render and follow correctly in-game — "everything
  seemed to just work."
- Source: `Get-FileHash`/`Get-ChildItem` on this machine's real
  `...\Pseudoregalia\...\Binaries\Win64\` install; user's own in-game observation.
  `ue4ss\UE4SS.log`'s startup banner (`v3.0.1 Beta #0`, SHA `733e5969`) was read from a session
  that predates the 19:14:52 runtime swap, so it does NOT identify the swapped-in build — the
  live in-game test is what actually confirms the new runtime, not that log line.
- Notes: contradicts the 2026-08-12 `risks.md` finding that a mismatched `UE4SS.dll` (there,
  83 commits ahead) broke `AP_Randomizer` outright — this mismatch, whatever exact build it
  is, did not break either mod. Exact SHA/commit of the swapped-in build was not identified
  (would need a fresh `UE4SS.log` startup banner captured after 19:14:52, not done this
  session) — treat as "a nearby build works," not as validating any specific commit.

### TEVI real two-player test: ghosts render correctly, pause menu behaves as intended

- Date: 2026-08-13
- Observed: two real TEVI instances (Steam copy + the standalone `14778703` build), each its
  own core process (bridge ports 7778/7779) connected through one real, non-loopback relay as
  distinct room members. User watched both windows: each showed the other player's ghost at the
  correct position (no offset, no leftover placeholder box — both removed this session) with
  correct animation. Also opened TEVI's Characters/pause overlay in one instance and confirmed
  the other player's ghost kept moving, visible through the semi-transparent background —
  `Update()`'s log lines (`local state: area=... pos=...`) kept flowing continuously the whole
  time the overlay was open.
- Source: user's own in-game observation, this session's transcript; the BepInEx console log
  visible in the screenshot.
- Notes: this closes `phase6.md`'s open follow-up question. The continuous local-state logging
  during the pause overlay proves `EventManager.mainCharacter` does NOT read null during TEVI's
  pause menu (only at the real title screen) — so the existing `player == null` check in
  `Update()` already safely distinguishes the two, and the 2026-08-13 bridge-disconnect-cleanup
  fix (`architecture.md`'s ADR) could safely be extended to trigger off that same null check for
  a real main-menu return, without a separate pause-vs-menu signal.

### TEVI ghost cleanup: main-menu return and game close both despawn correctly; pause does not

- Date: 2026-08-13
- Observed: with `BridgeClient.Disconnect()` wired into `Plugin.cs`'s `hadPlayerLastFrame`
  transition (closes the bridge connection when returning to the real main menu, not on pause),
  user retested live across both real TEVI instances. Pausing one instance: the peer's ghost
  stayed visible, unchanged — confirmed still working correctly, not broken by this change.
  Returning one instance to the main menu: the peer's ghost was properly removed. Closing the
  game entirely: also properly removed.
- Source: user's own in-game observation, this session's transcript.
- Notes: closes the "not yet covered" gap left open by the same-day bridge-disconnect ADR in
  `architecture.md` — both disconnect paths (explicit menu-return `Disconnect()` call, and a
  bridge socket dying because the game process exited) now correctly despawn a remote for
  peers, and pause is confirmed still excluded. Reconnect behavior (does exactly one clean
  ghost come back after returning to a play session, per `TryConnect()`'s automatic redial) was
  not explicitly re-verified this round — implied by the mechanism but worth a direct look next
  time it comes up.

### TEVI cross-area filtering confirmed live; found and fixed a reactivation animation freeze

- Date: 2026-08-13
- Observed: with `Core.remoteStatesAt`'s area-equality filter built (see the same-day ADR in
  `architecture.md`), user retested a real zone-to-zone transition via portal (the same route
  that exposed the original gap). The peer's ghost properly disappeared while in a different
  zone and reappeared correctly on returning to the shared zone — both directions confirmed
  live, not just by log inspection this time.
- Also observed, same test: the peer's ghost (idle the whole time) reappeared at the correct
  position immediately, but visually "stuck" — not animating — until the peer actually moved.
  Root-caused by reading `Plugin.cs` directly, not guessed: `DespawnRemoteGhost` only calls
  `SetActive(false)`, never resets `LastAnim`, and `UpsertRemoteGhost` only calls
  `Animator.Play()` on an actual anim-string change. Reactivating with the same anim string
  ("idle") as before never re-triggers `Play()`, so the Animator stays wherever it was left
  when deactivated. Fixed by clearing `visual.LastAnim = null` in `DespawnRemoteGhost`, forcing
  a fresh `Play()` on the next reactivation regardless of whether the anim actually changed.
  **Confirmed live, same session**: user retested the same zone-reentry case — an idle peer's
  ghost now shows its default idle animation immediately on reappearing, instead of staying
  stuck on whatever frame it was left on before despawning.
- Source: user's own in-game observation; `adapters/tevi/MeshGhostTevi/Plugin.cs` read directly
  to find the mechanism.

### TEVI map marker (step 6.7) shows a peer's real room location

- Date: 2026-08-13
- Observed: with room-grid coordinates now sent over the wire (`extras.room_x/room_y`) and a
  cloned/tinted `FullMap.playerPos` marker positioned via the same `roomtilelist` scan
  `MoveMapToCurrentRoom` uses, user opened TEVI's pause-menu map screen and confirmed a small
  marker appears at the other player's actual room.
- Source: user's own in-game observation.
- Also observed, same session: user specifically tested the fog-of-war guard by checking a
  room they had and hadn't discovered — the marker shows for a discovered room and hides for
  an undiscovered one, confirming `SaveManager.GetRoomWalkedBool`'s gating works exactly as
  designed, not just present in code.
- Notes: confirms the core mechanism (extras plumbing, marker cloning/positioning, the
  `isFullMap`/same-area gating, and now fog-of-war) works end to end. Not separately
  re-verified yet: the marker disappearing when the peer leaves the area specifically
  (distinct from the world ghost's own cross-area test), and whether the marker's size tracks
  map zoom correctly (reasoned from `GemaFixedSizeMapIcon`'s own
  rescaling code, not directly observed).

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

### Room-code auth accept/reject, real config.json dry run

- Date: 2026-08-14
- Observed: a real `meshghost-relay.exe` (built from this session's changes) started with
  `packaging/release/config.json`'s `server.room_code` set to a real value, logged
  `meshghost-relay: room-code auth enabled` at startup (not the "no room code configured"
  warning). A real `meshghost.exe`, pointed at the same config with a matching
  `client.room_code`, logged `meshghost: connected to relay 127.0.0.1:17778 as p1 in room
  "default"` — a successful join. The same client, config edited to a wrong `room_code` and
  restarted, logged `core: relay disconnected: EOF` followed by
  `meshghost: core: relay refused connection: invalid room code` — the new `reject` message's
  reason string reaching the client's own log, not a bare hangup.
- Source: agent-run session, both processes' own log output (`meshghost-server.log`,
  `meshghost.log`) read directly by the agent in a scratch directory
  (`/tmp/meshghost-smoke`), both real binaries built from `cmd/meshghost`/
  `cmd/meshghost-relay` at this session's HEAD, driven through the real
  `packaging/release/config.json` file (not flags), `-game=faketest` standing in for a real
  adapter (no bridge client available in this environment) — see the corresponding entry in
  `internal/core/core_test.go` (`TestConnectRelayWithWrongRoomCodeReturnsReadableError`/
  `TestConnectRelayWithCorrectRoomCodeSucceeds`) for the same behavior under `go test`.
- Notes: per the agent-read-log gating already established above (TEVI 6.1, the cross-machine
  session entry) — a log line is sufficient confirmation for a connectivity/protocol claim
  like this one, distinct from a visual/gameplay claim, which still needs the user to watch it
  happen on screen. This confirms the room-code feature works through the actual shipped
  config-file mechanism end to end (not just the Go test suite, which exercises `ConnectRelay`
  directly) — the real gap this closes is "does `config.json`'s new `room_code` field actually
  reach the wire," not just "does the relay's comparison logic work." Not confirmed by this
  entry: the room-code feature has not been watched by the user, and no real adapter/game was
  involved — `-game=faketest` stands in for one, matching the eager-connect dev-testing path
  `cmd/meshghost-fakeadapter` also uses, not a real game session.

### Client/relay start-order independence, real dry run

- Date: 2026-08-14
- Observed: a real `meshghost.exe` (`-game=faketest`, this session's build) was started
  pointed at a relay address with nothing listening on it yet. It did not crash: its log
  showed `meshghost: bridge listening on 127.0.0.1:18778` immediately, followed by
  `core: core: dial relay: dial tcp 127.0.0.1:18777: connectex: No connection could be made
  because the target machine actively refused it. — will keep retrying` exactly once, despite
  the process actually retrying on an exponential backoff (1s→2s→4s→...) across roughly 15
  seconds of wall time before a relay existed — confirming the dedup-logging fix works, not
  just the retry itself. A real `meshghost-relay.exe` was then started on that same address;
  within one backoff interval, the client's log gained
  `meshghost: connected to relay 127.0.0.1:18777 as p1 in room "default" (game "faketest")`
  with no restart of the client involved, and the relay's own log showed the new
  join-logging line, `relay: p1 ("alice") joined room "default" as game "faketest"`, at the
  matching timestamp.
- Source: agent-run session, both processes' own log output (`meshghost-server.log`,
  `meshghost.log`) read directly by the agent in a scratch directory
  (`/tmp/meshghost-order-test`), both real binaries built from `cmd/meshghost`/
  `cmd/meshghost-relay` at this session's HEAD — see the corresponding regression tests in
  `internal/core/core_test.go` (`TestConnectRelayOnAdapterHelloRetriesUntilRelayUp`,
  `TestConnectRelayOnAdapterHelloCachesPermanentReject`) for the same behavior under `go test`.
- Notes: per the agent-read-log gating already established above (TEVI 6.1, the cross-machine
  session entry, the room-code dry run immediately above) — a log line is sufficient
  confirmation for a connectivity/protocol claim like this one, distinct from a visual/gameplay
  claim, which still needs the user to watch it happen on screen. Confirms the ADR in
  `architecture.md` (search "2026-08-14 (same-day follow-up)") end to end: the eager `-game`
  path no longer requires the relay to already be running, and the new lifecycle logging
  (join/reject, with dedup on the client side) actually reaches both processes' log files as
  designed. Not confirmed by this entry: the user has not watched this happen, and no real
  adapter/game was involved (`-game=faketest`, same limitation as the room-code entry above).
  The *permanent*-rejection case (wrong room code, version mismatch) was exercised only under
  `go test`, not this particular live dry run — see `TestConnectRelayOnAdapterHelloCachesPermanentReject`.

### Pseudoregalia post-review-sweep rebuild, live confirmed

- Date: 2026-08-14
- Observed: user tested the rebuilt/redeployed `MeshGhostPseudo` mod (2026-08-14 review/refactor
  sweep — see the ADR in `architecture.md`) live in game. Ghost spawned, followed the remote
  player, and animated correctly, with no crashes across the session.
- Source: user, live gameplay session against the Steam install
  (`C:\Program Files (x86)\Steam\steamapps\common\Pseudoregalia`), deployed from
  `packaging/release/games/pseudoregalia/.../ue4ss/Mods/MeshGhostPseudo/dlls/main.dll`,
  hash-diff-confirmed identical to the repo build before this test.
- Notes: confirms the general ghost spawn/follow/animate/no-crash path survived this session's
  fixes (cached-pointer hardening, callback unregistration in `~Plugin`, connect backoff,
  spurious-landing-pulse fix, mutex-scope fix, unclamped-cast clamp). **Not specifically
  exercised or confirmed by this entry**: the move-offscreen-on-despawn behavior change itself
  (a same-area peer leave/reconnect) and an area transition with a ghost present — those need
  their own dedicated test before being added here. Separately, the user found and reported a
  new, apparently unrelated bug during this same session — see `risks.md`'s "ghost dealing
  damage to the real player" addition to the existing 2026-08-13 collision open question.

### Relay-restart auto-reconnect, real dry run

- Date: 2026-08-14
- Observed: real two-TEVI live testing first surfaced the bug (both clients connected, the
  shared relay was restarted, and neither client ever reconnected — see `architecture.md`'s ADR,
  search "found during live testing of the sweep above"). After the fix
  (`Core.reconnectWithBackoff`, armed via `autoRetryGameID`), re-tested with real binaries: a
  real `meshghost-relay.exe` was killed mid-session while a real `meshghost.exe` (`-game=tevi`)
  was connected; the client logged `relay disconnected` followed by `dial relay: ... will keep
  retrying` (exactly once, per the existing dedup logging). A new `meshghost-relay.exe` was then
  started on the same address; within one backoff interval the client logged a fresh `connected
  to relay ... as p1 in room "default" (game "tevi")` line with no restart of the client
  involved.
- Source: agent-run session, both processes' own log output (`meshghost.log`, relay stdout)
  read directly by the agent in a scratch directory, both real binaries built from
  `cmd/meshghost`/`cmd/meshghost-relay` at this session's HEAD — see the corresponding
  regression test, `internal/core/core_test.go`'s `TestRelayDisconnectAutoReconnects`, for the
  same behavior under `go test`.
- Notes: per the agent-read-log gating already established elsewhere in this file — a log line
  is sufficient confirmation for a connectivity/protocol claim like this one, distinct from a
  visual/gameplay claim, which still needs the user to watch it happen on screen. Not confirmed
  by this entry: the user has not yet re-watched this specific scenario with the rebuilt
  binaries (their original repro was against stale, pre-fix binaries — see the ADR); worth a
  quick re-test to close the loop, though the mechanism is the same one just live-verified here
  and under `go test`.

### TEVI zone-transition ghost-invisibility fix, live confirmed

- Date: 2026-08-14
- Observed: user reproduced the original bug live (travel to a different zone, return, a
  peer's ghost that was visible before leaving no longer appears) with two real TEVI instances.
  Isolated via an isolate-by-subtraction test (a temporary `MESHGHOST_DISABLE_AREA_FILTER` env
  var bypassing `internal/core`'s cross-area filter) to confirm the despawn/recreate cycle,
  not the filter's area-matching logic, was the cause. After the real fix (`basesprite.enabled`
  forced true on ghost recreation, see the `pitfalls.md` entry), user re-tested the same
  scenario with normal filtering restored (no debug bypass) and confirmed live: the peer's
  ghost is now visible on return, with no white-glow regression from the first (rejected)
  version of the fix that also touched `color`.
- Source: user, live two-instance TEVI testing (Steam install + standalone
  `C:\dev\tevi-14778703` build), screenshot showing both windows with correctly-visible ghosts
  after a zone round-trip.
- Notes: `internal/core`'s debug escape hatch (`disableAreaFilterForDebug`) and the two
  temporary `dev-scripts/DEBUG-run-core-tevi*-nofilter.bat` scripts used only for the isolation
  test have been deleted per their own doc comments — they were never meant to ship. The fix
  itself lives in `adapters/tevi/MeshGhostTevi/Plugin.cs`'s `CreateRealGhostVisual`.

### Emerald Lua adapter sweep fixes, live-verified via loopback

- Date: 2026-08-14
- Observed: user loaded `adapters/pokemon/emerald/phase5_5_sprite.lua` in BizHawk against a real
  relay/core run with `-loopback`. Confirmed on screen: the loopback-echoed ghost spawned
  correctly, and killing the client (closing BizHawk/disconnecting) despawned the ghost cleanly
  on the other side rather than leaving it stuck.
- Source: `adapters/pokemon/emerald/phase5_5_sprite.lua` (the same-day sweep's fixes: partial-line
  receive/send handling, dead-socket-after-hard-error, `pcall` around the main loop, control-char
  JSON escaping — see the "same-day review/refactor sweep" ADR in `architecture.md`).
- Notes: this closes the last item from `status.md`'s 2026-08-14 sweep entry marked "not yet
  live-verified in an emulator." User confirmed this was a genuine loopback run (ghost spawn +
  clean despawn on client kill), not just a script load with no errors — satisfies `CLAUDE.md`'s
  "ran without errors is not evidence" standard. Not separately exercised in this pass: a relay
  restart mid-session (dead-socket path) or a two-real-peer (non-loopback) run — loopback spawn/
  despawn was the scenario tested.

### Pseudoregalia despawn-visual and area-transition, live-verified via loopback

- Date: 2026-08-14
- Observed: two separate live tests, both confirmed on screen by the user. (1) With the
  loopback ghost visible and following the player, walking back and forth between two areas
  produced no crash and the ghost kept correctly following across both transitions. (2) After a
  real, previously-unknown bug was found and fixed (see the next entry below), closing the
  client (`meshghost.exe`) with the loopback ghost visible made it actually disappear, instead
  of the earlier behavior where it was left standing frozen and visible.
- Source: `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp` — `release_all_ghosts`
  (`LoadMap PRE` hook, area transitions) and the new `release_all_ghosts_parked` (bridge
  disconnect, see below).
- Notes: closes the last item from `status.md`'s 2026-08-14 sweep entry ("not started: live
  in-game verification of Pseudoregalia's despawn-visual/area-transition behavior"). The
  despawn-visual half required a real code fix, not just testing — see the next entry.

### Pseudoregalia bridge-disconnect ghost cleanup, found live and fixed

- Date: 2026-08-14
- Observed: first test attempt (before the fix) showed the ghost left standing frozen and
  visible after closing the client — `release_ghost`/`release_all_ghosts` only ever fired from
  a real `despawn_remote` message or the `LoadMap PRE` area-transition hook, neither of which
  fires when the bridge connection itself drops (closing `meshghost.exe`). `on_update()` polled
  `bridge->is_connected()` every tick but never acted on a connected->disconnected transition.
  Fixed: `on_update()` now detects that edge and arms `bridge_disconnect_cleanup_pending`
  (guarded by `state_mutex`); `game_thread_tick()` drains it and calls the new
  `release_all_ghosts_parked`, which parks every remaining ghost the same way a real
  `despawn_remote` does. Rebuilt (0 errors after fixing a PATH issue — msys2's bundled `cmake`
  was shadowing the real `C:\Program Files\CMake\bin` install ahead of it on `PATH`, same
  problem already logged once before in `phase7.md`), deployed to both the in-repo packaging
  copy and the live Steam install (hash-diff-confirmed, `67f442bc...`). Re-tested live after the
  fix: user confirmed the ghost now disappears on client close — see the entry above.
- Source: `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`/`Plugin.hpp`
  (`release_all_ghosts_parked`, `bridge_was_connected`, `bridge_disconnect_cleanup_pending`).
- Notes: same bug class as Emerald's Phase 3 fix ("the Lua adapter didn't detect its own bridge
  connection dying"), just never previously ported to this adapter.

### Core-relay heartbeat, found live and fixed (idle-timeout reconnect-ID churn)

- Date: 2026-08-14
- Observed: while testing the above, the user noticed the relay and core logs climbing through
  player IDs (`p1`→`p2`→...→`p6`) roughly once a minute, each preceded by an `i/o timeout` on
  both sides. Root cause: a core process with no adapter attached (or any adapter reporting
  `get_local_state()==nil` for a stretch, e.g. a player parked at a menu) never calls
  `forwardLocalState`, so nothing was ever sent on an otherwise-healthy relay connection.
  `transport.DefaultIdleTimeout` (60s, added in the same-day relay-safety sweep) then killed it,
  the sweep's own auto-reconnect fix immediately redialed, and `nextPlayerID` (a
  never-reused monotonic counter) handed out a fresh id each cycle — which every other real peer
  would see as a leave+join/ghost despawn-respawn once a minute, not just log noise. Fixed:
  `Core.sendHeartbeats` (`internal/core/core.go`), started on every successful `ConnectRelay`,
  sends a `Ping` every `DefaultHeartbeatInterval` (20s) for as long as that connection stays
  current; the relay already replied to `Ping` with `Pong` (`internal/relay/relay.go`) but
  nothing on the client side had ever sent one. `go build`/`vet`/`test` clean; both named
  binaries (`meshghost.exe`, `meshghost-relay.exe`) rebuilt. Re-tested live: user left an
  idle core connected well past the old 60s failure point and confirmed no further
  timeout/reconnect messages appeared in either log — same connection, same player id, the
  whole time.
- Source: `internal/core/core.go` (`DefaultHeartbeatInterval`, `sendHeartbeats`);
  `internal/protocol/protocol.go` (`TypePing`/`TypePong`, `Ping`/`Pong`, pre-existing but
  unused by any real sender until now); `internal/relay/relay.go` (pre-existing `TypePing`
  handler).
- Notes: found by the user asking a question about the logs, not by the agent's own review —
  same pattern as the two same-day-follow-up gaps in the relay-safety hardening entry above.
  Not yet re-tested with a real second peer connected during the old failure window (to directly
  observe the leave/join churn this fixes from another client's point of view) — the fix is
  confirmed to stop the reconnect loop itself, not separately confirmed from a second peer's
  perspective.

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
- Source: `adapters/pokemon/emerald/phase5_5_sprite.lua` (unchanged by this session —
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
- Source: `adapters/pokemon/emerald/meshghost_emerald.lua` (`readLocalGender`, its call site's
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
- Source: `adapters/pokemon/emerald/battle_probe.lua` (the diagnostic used); now also cited in
  `adapters/pokemon/emerald/meshghost_emerald.lua`'s `inOverworld()`,
  `adapters/pokemon/emerald/vram_probe.lua`'s `isOverworld()`, and `battle_probe.lua` itself,
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
- Observed: user ran `adapters/pokemon/emerald/sprite_probe.lua` against the same second,
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
- Source: `adapters/pokemon/emerald/sprite_probe.lua`, reading `gObjectEventPic_BrendanNormal`
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
  1. `adapters/pokemon/emerald/avatar_scan_probe.lua` (scripted snapshot-diff): counted the
     user down through pressing and holding down, left, up, right in turn, capturing a full
     EWRAM snapshot during each hold. Kept only addresses matching the exact expected value
     (1, then 3, then 2, then 4) at every one of the four steps in order. Narrowed all 262,144
     bytes of EWRAM to exactly 2 candidates (5411 -> 8 -> 2 -> 2), 8 bytes apart
     (`0x020375EC`, `0x020375F4`).
  2. `adapters/pokemon/emerald/avatar_hexdump_probe.lua`: dumped raw bytes around both
     candidates. Matched the surrounding bytes field-by-field against pokeemerald's real
     `struct ObjectEvent` layout (`include/global.fieldmap.h`) with entry base `0x020375D4`:
     `isPlayer` bit set (`+0x02`), `trackedByCamera` bit set (`+0x01`), `localId == 0xFF` =
     `LOCALID_PLAYER` exactly (`+0x08`), `mapNum == 9` / `mapGroup == 0` (`+0x09`/`+0x0A`,
     matching Littleroot Town, already independently confirmed 2026-08-11). `facingDirection`
     (`+0x18`) is `0x020375EC` (candidate 1, the real field); `previousMovementDirection`
     (`+0x20`) is `0x020375F4` (candidate 2 -- a real, different field that happened to also
     survive the test, 8 bytes later, exactly matching the struct's own field spacing).
  3. `adapters/pokemon/emerald/avatar_array_probe.lua`: scanned 20 slots before and after
     `0x020375D4` at the confirmed 0x24-byte `ObjectEvent` stride. One slot earlier
     (`0x020375B0`) breaks the pattern completely (not the array, not the old garbage region
     either) -- confirming `0x020375D4` is index 0, the array's real start. Slots +1/+2/+3 show
     real sequential `localId` 1/2/3 (other object events on the same map). Following vanilla's
     own `gPlayerAvatar = gObjectEvents + 0x240` relationship placed a `gPlayerAvatar` candidate
     at `0x02037814`.
  4. `adapters/pokemon/emerald/avatar_verify_probe.lua`: read `struct PlayerAvatar`'s real
     fields (`include/global.fieldmap.h`: `flags`/`transitionFlags`/`runningState`/
     `tileTransitionState`/`spriteId`/`objectEventId`/`gender`) from `0x02037814` while the user
     walked, dashed, and turned in every direction. `flags` toggled cleanly `0x01`<->`0x81`
     exactly with dash; `runningState` cycled `0->1->2` matching real movement;
     `facingDirection` (read via the confirmed `gObjectEvents` address) tracked every turn
     correctly; `objectEventId`/`spriteId`/`gender` held sane constant values throughout --
     fully responsive, live data, not the frozen `0xFF`/`255`/`15` garbage the vanilla addresses
     read (see the 2026-08-11 entry and its 2026-08-14 reproduction above).
- Source: the four probe scripts above; now cited in
  `adapters/pokemon/emerald/meshghost_emerald.lua`'s `AVATAR_ADDR_ARCHIPELAGO_SHIFT` /
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
- Source: `adapters/pokemon/emerald/meshghost_emerald.lua`'s `tryDetectAvatarAddrOffset()`,
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
- Source: `adapters/pokemon/emerald/meshghost_emerald.lua`'s `smoothPosition()` and
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

### Post-sweep regression check across all three games, confirmed live -- and TEVI's loopback offset found too small

- Date: 2026-08-15
- Observed: after a full project fact-check/refactor sweep (Go dedup, dead-code removal in the
  Pseudoregalia C++ mod, doc restructure, `game_version` bumps on Emerald/TEVI/Pseudoregalia,
  both rebuilt DLLs deployed to their live game installs), the user ran a real loopback pass
  across all three games to confirm nothing broke. **Emerald**: confirmed working via loopback
  against both a vanilla ROM and an Archipelago-patched one. **Pseudoregalia**: confirmed
  working, ghost correctly placed to the side (the existing `LOOPBACK_GHOST_OFFSET_X` = 150.0
  offset, unchanged by this sweep, still reads correctly). **TEVI**: confirmed still functionally
  working (no regression), but the loopback ghost rendered basically on top of the real player,
  not offset to the side -- the existing `loopbackOffsetX` = 2.0f magnitude
  (`adapters/tevi/MeshGhostTevi/Plugin.cs`, added 2026-08-14 and explicitly flagged
  "UNVERIFIED MAGNITUDE... a guess, not yet confirmed on screen" at the time) is now confirmed
  too small in TEVI's own world-unit scale. Fixed same-day: replaced with 80f (X axis only),
  matching the magnitude of the pre-6.6 magenta-placeholder-box offset
  (`RemoteVisualTestOffset = new Vector3(-80f, 0f, 0f)`, removed in the real Phase 6.6
  two-player test -- see `agent_docs/phases/phase6.md`), a value already known to read clearly
  on screen in this exact game. Rebuilt (0 errors), deployed to both the Steam install and the
  standalone `C:\dev\tevi-14778703` build, hash-diff-confirmed. **80f confirmed on screen the
  same day** -- user provided a screenshot: player and ghost side by side (ghost to the right),
  correctly separated, still fairly close together. **Doubled to 160f same day, at the user's
  explicit direction that this step is considered confirmed/tested alongside the 80f
  screenshot, without watching 160f itself live** -- a linear doubling of an offset already
  watched rendering correctly on the same axis and render path, not a fresh, unverified guess.
  Rebuilt again (0 errors), redeployed to both installs, hash-diff-confirmed.
- Source: `adapters/tevi/MeshGhostTevi/Plugin.cs`'s `loopbackOffsetX`; the superseded
  `RemoteVisualTestOffset` value cited from `agent_docs/phases/phase6.md`'s 6.6 entry (git
  history: commit `bc642e4`).
- Notes: this closes the "UNVERIFIED MAGNITUDE" flag TEVI's loopback offset carried since
  2026-08-14 -- not by fresh measurement, but by reusing a distance this exact codebase had
  already separately confirmed worked, the same reasoning Pseudoregalia's own loopback offset
  used when it borrowed its 150.0-unit magnitude from an earlier diagnostic. Current shipped
  value is 160f, user-confirmed sufficient without a second live round.

### Pseudoregalia ability field schema, mapped to every trending-page ability via a real reflection dump

- Date: 2026-08-15
- Observed: **field existence and names only -- not behavior.** `dump_object_reflection` (new,
  gated behind `OBJECT_REFLECTION_DUMP`, a generalized restore of the deleted
  `log_pawn_reflection_once`) was built into `MeshGhostPseudo`, rebuilt, deployed to the live
  install, and run through a real play session covering as many abilities as the user could
  trigger. The dump prints `BP_PlayerGoatMain_C`'s and `ABP_PlayerGoat_C`'s full property/
  function schema (`TFieldRange<FProperty>`/`TFieldRange<UFunction>`) every
  `OBJECT_REFLECTION_DUMP_INTERVAL_TICKS` (~1.5s observed, not the ~5s originally estimated from
  tick rate) -- this confirms a field is real and spelled this way on this build, not that its
  value does what its name suggests. Every ability on the game's own trending-pages list
  resolved to at least one real field, through iterative correction against the user's actual
  gameplay knowledge (several of the model's first-pass name-based guesses were wrong and
  user-corrected -- see notes):
  - Dream Breaker (weapon): `weaponEquipped?`, `animEquippedWeapon` (on `animBPref`), `weaponRef`,
    `WeaponMesh`, `spawnWeapon`/`recallWeapon`/`changeEquippedWeapon` functions.
  - Strikebreak + Soul Cutter (one shared charge-attack mechanic, sequential upgrades to the base
    weapon per the user, not parallel branches): `obtainedChargeAttack?`, `chargeAttackHoldTime`,
    `chargingVFX`, `obtainedProjectile?`, `projectileFullDamage`.
  - Power meter (feeds Soul Cutter's damage boost): `currentPower`, `maxPower`, `baseMaxPower`,
    `powerAccum`, `powerLevel`, `powerDamageMultiplier`, `changePowerAmount`,
    `powerBuildUpgrades`, `powerMeterUpgrades`, `obtainedPowerBoost?`.
  - Sunsetter (Plunge): `obtainedPlunge?`, `doGroundPound`, `doGroundPoundHighJump`,
    `hasGroundPound`, `altAirBackflip`, `canFlipJump?` (the last two are the plunge-cancel-into-
    backflip tech, not an unrelated move -- initially guessed unrelated, corrected by the user).
  - Slide / Slide Jump / Solar Wind: `obtainedSlide?`, `canSlide`, `obtainedSlideJump`,
    `bunnyhopJumpCap` (Solar Wind itself has no dedicated unlock flag found -- consistent with it
    being a passive momentum upgrade to Slide Jump, not a new move; `slideDuration`/`SlideCurve`
    are also plausibly tuned by it, unconfirmed).
  - Cling Gem: `wallRide*`/`wallRun*` cluster (`obtainedWallRide?`, `wallRideButtonHeld?`,
    `wallRideVFX`, `wallRideSFX`) -- the game's internal name differs from both the community
    name ("Cling Gem") and the model's first guess ("wall glide"); no literal "glide" string
    exists anywhere in the dump.
  - Sun Greaves: `wallKick*`/`airKick*` cluster (`wallKickActive`, `tryWeaponKick?`,
    `obtainedAirKick?`, `currentAirKicks`, and one literally named `'wall event kick thing'`).
  - Ascendant Light: `obtainedLight?` -- present in the schema despite being untested this
    session, confirming the dump reflects the full class schema, not just exercised fields.
  - Costumes (not on the trending-pages list; user-requested mid-session):
    `outfitDataTable`, `changeActiveOutfit`, `tryAddOutfitToUnlockedList`.
- Source: `UE4SS.log` from the 2026-08-15 03:19-03:20 session (live install,
  `...\Pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\UE4SS.log`), `[MeshGhostPseudo] DIAG:`
  lines, 219 dump cycles. Dumper source: `Plugin.cpp`'s `dump_object_reflection` (added this
  session, restored/generalized from the deleted `log_pawn_reflection_once` -- see that
  function's own comment for the `TFieldRange` grounding citation, unchanged from the original).
- Notes: **this entry documents schema, not confirmed behavior -- do not treat any field above
  as "working" or implement against it as if it were.** No value was read or watched changing
  (e.g. `weaponEquipped?` was never actually observed flipping true/false); no VFX/animation was
  watched playing on the ghost from any of these fields; no sync code exists for any of them yet.
  The real next step, not yet done: a live-value trace (mirroring how `moveState`/`landed?` are
  already traced) for the highest-priority subset, to find out which fields already animate
  correctly via the existing `moveState`/`actionState` mirror "for free," which need a
  `landed?`/`jumped?`-style one-shot pulse fix, and which (object references, VFX triggers) need
  new sync code entirely -- three genuinely different amounts of work the field list alone can't
  distinguish. See `agent_docs/ideas.md`'s Pseudoregalia section for the discovery-phase framing
  this came out of.

### Pseudoregalia ability field live-value trace -- real values watched, not just names

- Date: 2026-08-15
- Observed: follow-up to the schema entry above. A live-value trace (`ABILITY_FIELD_TRACE`,
  gated, same LOG_INTERVAL_TICKS ~2s cadence as the existing `moveState` TRACE line) was added,
  built, deployed, and run through a second real session where the user deliberately tried every
  interaction in the game. 616 samples captured. Aggregated distinct values/counts per field,
  not just a few samples eyeballed (an earlier same-day informal read of 8 samples produced a
  wrong conclusion for `weaponRef`, corrected here by the full aggregate):
  - **Persistent "obtained" flags, not moment-to-moment triggers**: `weaponEquipped?` /
    `animEquippedWeapon` (false 25/616, all in the first few seconds before the weapon was
    picked up; true for the remaining 591/616, never false again) and `canFlipJump?` (false
    15/616, true 601/616, same shape). Confirmed: these track "has the ability been obtained,"
    not "is it actively in use right now."
  - **Genuinely live values, safe direct-sync candidates**: `currentPower`/`powerLevel` (real
    fluctuation observed across the session -- rose, fell, rose again). `weaponRef` (non-null
    41/616 times -- a real, transient toggle, not "always null" as an earlier same-session
    8-sample spot check had wrongly concluded). `wallRideHeld?` (true 14/616 -- a real, brief
    flag, caught despite the ~2s sampling gap). `chargingVFX` (non-null 126/616, ~20% --
    genuine toggling).
  - **Static, not live**: `chargeAttackHoldTime` only ever took two values across all 616
    samples: `-1` (the trace's own not-found sentinel, seen only pre-spawn) and `0.7`
    afterward -- never anything in between. Confirmed a tuning constant (a hold-duration
    threshold), not a live elapsed timer -- not a useful sync target as a per-tick value.
  - **Surprising, changes the reading of the schema-only entry above**: `wallRideVFX` was
    non-null in 431/616 samples (~70%) -- not the on/off toggle expected from its name. Real
    finding: this field's null-check tracks *component presence/attachment*, not *effect
    actively playing* -- the two are different questions, and this field alone answers only the
    first.
  - **Real negative result, not a sampling gap**: `hasGroundPound` was `false` in all 616/616
    samples, despite the user deliberately testing the Plunge (Sunsetter) repeatedly. Explicitly
    not attributed to sampling coincidence: `wallRideHeld?`, a plausibly similarly brief flag,
    was still caught 14 times at this same cadence in the same session -- zero hits here is
    treated as a real signal that either this field isn't what an active plunge sets, or its
    true active window is far shorter than everything else this trace caught.
- Source: `UE4SS.log` from the second 2026-08-15 session (same live install/path as the schema
  entry above), `[MeshGhostPseudo] TRACE abilities:` lines, 616 samples, aggregated by field via
  `grep -oE`/`sort`/`uniq -c` rather than reading samples individually. Trace source: `Plugin.cpp`'s
  `ABILITY_FIELD_TRACE` block in `game_thread_tick`.
- Notes: still not sync-ready for most fields -- watching a value change confirms the field means
  what its name suggests, but syncing it onto the ghost (especially the VFX/object-reference
  fields) is separate, not-yet-done work, per the three-bucket framing in the schema entry above
  and `adapters/pseudoregalia/PLAYER_FIELDS.md`. `hasGroundPound` specifically would need a
  faster, edge-triggered trace (the `ANIM_PULSE_TRACE`/`landed?`-`jumped?` pattern, not this
  fixed-cadence one) before it can be ruled in or out with confidence.

### Dream Breaker weapon-visibility sync: shipped, live-tested, root cause still unresolved -- WeaponMesh cleared as a suspect

- Date: 2026-08-15
- Observed: `RemoteGhost::target_weapon_equipped` (new) mirrors `weaponEquipped?`/
  `animEquippedWeapon` onto the ghost every tick (`Plugin.cpp`: local read, JSON extras field
  `weapon_equipped`, receive parse, ghost write). Live loopback test: the ghost's sword became
  visible on spawn matching the real player's own state, but **stayed visible after the real
  player threw the weapon away** -- a real, reproducible bug, not a one-off.
  - Independent readback (`WEAPON_SYNC_TRACE`, re-fetched pointers, not the write variable) proved
    the data pipeline itself is correct: local `weaponEquipped?` flips `false`/`true` exactly on
    every real throw/pickup (14/616 and 591/616-style clean transitions across two full cycles),
    and the ghost's own `weaponEquipped?`/`animEquippedWeapon` readback matched the target value on
    **every single sample**, no exceptions. The sync mechanism is not the bug.
  - Two function-call hypotheses for the missing throw/pickup *animation*, both confirmed called
    correctly (live signature-dumped before calling, then confirmed firing via trace log, matching
    the `call_montage_stop` ledge-hang-fix precedent's discipline) and both a clean negative --
    **zero visible effect on the ghost, no animation, sword still showing**:
    1. `updateWeaponEquip(bool animEquippedWeapon)` on `animBPref` (`Plugin.cpp`'s
       `call_update_weapon_equip`).
    2. `changeEquippedWeapon(bool weaponEquipped?)` on the pawn itself
       (`call_change_equipped_weapon`).
  - Per `CLAUDE.md`'s "two guessed fixes failing identically is a signal" rule, stopped guessing
    function names and isolated `WeaponMesh` (the component itself, not the pawn) directly instead,
    via a live-value trace of every stock-engine visibility/attachment property it has. **Four
    consecutive negative results, every single sample across a real multi-throw/pickup session,
    zero variation on any of them**: `bHiddenInGame` always `false`, `bVisible` always `true`,
    `RelativeLocation` always `(0,0,0)`, `AttachSocketName` always `'handSlot_RSocket'`.
    `WeaponMesh` itself never changes in any detectable way regardless of equip state, confirmed
    real and not a search-thoroughness gap (the schema dump that found these four names also found
    the full attach API -- `GetAttachSocketName`, `GetSocketTransform`, `K2_AttachToComponent`,
    etc. -- none of which was called, since there was no evidence yet pointing at any of them
    specifically).
  - User independently confirmed the real game DOES visually show/hide the weapon on their own
    character with a real throw animation and a real pickup animation -- so the visual effect
    itself is real and un-disputed; `WeaponMesh` genuinely not correlating with any of it means the
    visible swap is driven by something else this investigation hasn't found, or -- see below.
- **Critical finding, reframes the whole investigation**: the user reported, unprompted, that the
  ghost has correctly mirrored sword-equipped state AND outfit/costume choice **since spawning was
  first implemented, before any weapon/outfit-specific sync code ever existed** -- specifically at
  spawn time, observed but never logged at the time. Quote: "the ghost can/does follow the state
  that the current 'player' has whenever the game is started." Also: "when the ghost spawn in, it
  either has or don't have the sword equipped similar to the player. it uses the same costume/
  outfit that the player is using."
  - **This is reported observation of a real, repeatedly-seen fact, treated as strong evidence --
    not independently isolated via a dedicated test this session.** The likely explanation (the
    ghost is a spawned clone of `BP_PlayerGoatMain_C` running in the same local game process, so
    its own construction/`BeginPlay` logic plausibly reads the same local save data the real
    player's weapon/outfit ownership comes from, independent of anything this adapter syncs) is
    reasoned inference from that observation, not something directly watched -- no test this
    session isolated "the ghost's construction reads local save data" from "our sync code happens
    to also be correct at that exact instant." An inversion test (deliberately send the ghost the
    OPPOSITE of the real state and see whether the visual follows the (wrong) synced value or the
    real local state) was designed but explicitly not run -- user chose to log this finding and
    decide the fix approach separately rather than spend another build/test cycle proving it
    further this round.
  - **If true, this would mean every loopback test in this whole investigation was unable to
    distinguish "our sync is working" from "the ghost coincidentally matches because it reads the
    same local save on spawn regardless of what we sync"** -- which would cleanly explain why every
    function-call/property hypothesis tried had zero visible effect, and would mean the feature has
    not actually been proven to work for its real purpose (a real two-machine session with two
    different save files/weapon progressions) yet.
- Source: `UE4SS.log` across several 2026-08-15 sessions (live install, same path as prior
  entries), `[MeshGhostPseudo] TRACE weapon local:` / `TRACE weapon ghost:` / `TRACE weapon local
  WeaponMesh:` lines. Sync code: `Plugin.hpp`'s `RemoteGhost::target_weapon_equipped`/
  `last_synced_weapon_equipped`/`weapon_equip_call_armed`; `Plugin.cpp`'s `call_update_weapon_equip`/
  `call_change_equipped_weapon`.
- Notes: root cause not yet resolved. See the plan file referenced from this session (Pseudoregalia
  Dream Breaker visibility investigation) for the deferred fix-approach options. `WeaponMesh` is
  cleared as a suspect for the visibility toggle specifically -- do not re-investigate its own
  properties again without new grounding data. The throw/pickup *animation* question (separate from
  visibility) remains fully open and untouched beyond the two disproven function calls above.

### Dream Breaker weapon-visibility sync: inversion test run -- same-local-save-data confound CONFIRMED

- Date: 2026-08-15
- Observed: the inversion test designed but not run in the entry above (`WEAPON_SYNC_INVERT`, new
  compile-time flag in `Plugin.cpp`, applied once at the receive-parse site so every downstream
  consumer sees it) was built, deployed, and run live on loopback. It deliberately stores the
  OPPOSITE of the real player's `weaponEquipped?` as the ghost's sync target. User started the game
  holding the sword and cycled through multiple real throw/pickup transitions during the run.
  - **The ghost's sword and outfit both continued to visually match the real player throughout --
    the inversion had zero visible effect in either direction.** User's own words: "the ghost still
    had the same outfit as me, and was also holding the sword" (while the real player was, per the
    inverted target, supposed to render empty-handed).
  - `UE4SS.log` confirms the inversion was correctly and continuously applied across the whole
    session, not a one-off: local `weaponEquipped` toggled `false`->`true`->`false`->`true`->
    `false`->`true` across 6 real transitions (5/13/17/2/16/15 samples respectively), and the
    ghost's `target_weapon_equipped` tracked the exact logical opposite at every single one of
    those transitions, with zero exceptions (`grep`-verified over 391 trace lines).
  - **Stronger than a plain "no effect" result**: the ghost's own `weaponEquipped?`/
    `animEquippedWeapon` INDEPENDENT READBACK matched the (deliberately wrong) inverted target on
    every sample too (e.g. `target_weapon_equipped=false readback_weaponEquipped=false
    readback_animEquippedWeapon=false`) -- so the write mechanism itself is proven working and
    sticking correctly, exactly as the original entry already established. The property is
    correctly, verifiably set to `false` on the ghost, and the ghost still visibly holds the sword.
    This rules out "the write isn't really landing" as an alternative explanation -- the property
    demonstrably has **no causal influence on the visual at all**, in either direction.
  - New trace additions added for this run, both consistent with a same-construction-time-only
    mechanism rather than any live-updated one: ghost-side `weaponRef` stayed `null` throughout
    (matching a ghost that was never handed the weapon through the game's own pickup/throw event
    path, only spawned already matching); `WeaponMesh.SkeletalMesh` was `non-null` on the ghost at
    every sample regardless of the (inverted) equip state -- the mesh asset itself is never swapped
    or cleared, on either the real player or the ghost, consistent with the four earlier
    WeaponMesh-property negative results.
- **Conclusion: the same-local-save-data confound theorized in the entry above is CONFIRMED, not
  just plausible.** The ghost's weapon/outfit visual is set once, at spawn/construction time, from
  the same local save data the real player's own ownership state reads from -- independent of
  `weaponEquipped?`/`animEquippedWeapon`/`WeaponMesh` or any of the sync code built so far. Every
  prior "it looked right" loopback result on this feature (including the original ship) was never
  evidence the sync code did anything; this run proves that directly by showing the *opposite* of
  "it looked right" (a deliberately wrong sync value) produces the identical visual.
- **Implication for the fix**: none of `weaponEquipped?`, `animEquippedWeapon`,
  `changeEquippedWeapon`, `updateWeaponEquip`, or any `WeaponMesh` property is the right lever --
  five wired-up mechanisms now cleared as suspects for the *visibility* toggle specifically. The
  right fix mechanism is still unknown; the next step is finding what a real throw/pickup actually
  calls or writes that visibly changes the mesh (not a bool flag this investigation has already
  exhausted), most plausibly by hooking/tracing the real in-game throw input path rather than
  polling more pawn properties. A genuinely different confirmation angle for whenever it's
  available: a real two-machine session with two different save files/weapon progressions (per
  Phase 7.7, not yet run) would settle this independently of loopback.
- Source: `UE4SS.log`, 2026-08-15 session (live install, same path as prior entries),
  `[MeshGhostPseudo] TRACE weapon local:` / `TRACE weapon ghost:` / `TRACE weapon ghost ...
  WeaponMesh SkeletalMesh=` lines, 391 total trace lines this session. Diagnostic code:
  `Plugin.cpp`'s `WEAPON_SYNC_INVERT` (now reverted to `false`) and the new `weaponRef`/
  `SkeletalMesh` readback additions to the existing `WEAPON_SYNC_TRACE` block.
- Notes: `WEAPON_SYNC_INVERT`/`WEAPON_SYNC_TRACE` flipped back to `false`, rebuilt, redeployed
  (hash-confirmed) after this run, per this project's standing diagnostic-toggle convention. This
  closes the "is our sync even the lever" question for Dream Breaker visibility -- do not re-run
  the inversion test again without new grounding data. The cling-gem VFX and empty-hand glow gaps
  remain fully untouched and open.
- **Follow-up same day, user's own idea, additional confirmation**: loaded a basic save with no
  sword equipped and default outfit (still single-process loopback, same known limit as the main
  run above -- can't isolate "reads current save" from "reads same-process live pawn state"). User
  confirmed on screen (screenshot, two visually identical unarmed characters side by side): the
  ghost spawned matching -- no sword, default outfit -- same as the real player on this save.
  Rules out one remaining alternative theory the inversion test alone didn't: this isn't a
  hardcoded "ghost always spawns with a sword" default that happened to coincide with every prior
  test session -- the ghost's spawn-time snapshot genuinely tracks whichever state (armed or
  unarmed) is locally active, just not via any of the sync code exhausted above. Strengthens the
  same-local-state-at-construction theory; doesn't newly distinguish "save file" from "live pawn
  object" as the specific copy source -- that still needs the two-machine test (Phase 7.7) noted
  above.
- **Second follow-up same day, decisive, sharpens the theory**: on the "have everything" save
  (sword equipped), user reproduced the matching-sword result again (two screenshots, both
  characters holding the same glowing sword, matching gold armor/costume), then, while the ghost
  was already standing there, changed the real player's own costume live to a different outfit
  ("a sweater"). **The ghost did not follow the costume change** -- it stayed in the golden-armor
  outfit it had at the moment it spawned, screenshot-confirmed side by side with the now
  sweater-wearing real player.
  - **This refines "same-local-save-data confound" into something more precise**: it is not that
    the ghost continuously reflects whatever the real player's current state is (which a live
    "reads the same save" theory could still imply) -- it is a **one-time snapshot taken at spawn/
    construction and never re-read again for anything visual-identity-related** (mesh, weapon,
    outfit). Everything this phase already knows the ghost DOES update live (`moveState`,
    `actionState`, animation, position) goes through this adapter's own explicit per-tick sync
    code; everything that does NOT update live (weapon, outfit) is exactly the set this adapter
    has never had any sync code for at all. Consistent, not coincidental -- there is no evidence
    anywhere in this investigation of some other in-game live-update mechanism for these fields
    that our five sync attempts merely failed to reach; the simpler, now-better-supported
    explanation is that nothing live-updates them for a spawned clone at all, ours or the game's
    own.
  - **Practical implication, changes the fix framing**: since the game itself provides no live
    re-application of weapon/outfit state to an already-spawned pawn (nothing does this locally,
    not even for the real player's own visual identity via any observed mechanism), the eventual
    fix cannot be "find the one function the game calls on throw/pickup/costume-change and call it
    on the ghost too" in the way `updateWeaponEquip`/`changeEquippedWeapon` assumed -- those may
    simply not be it, or may need pairing with whatever *does* force a visual refresh (mesh/anim
    re-initialization), which hasn't been identified. This also means the Dream Breaker bug and a
    still-unbuilt outfit-sync feature (`ideas.md`'s Costumes row: `outfitDataTable`,
    `changeActiveOutfit`, `tryAddOutfitToUnlockedList`) are the same underlying problem, not two
    separate ones -- solving one plausibly solves both.
  - Source: two screenshots this session, `agent_docs/verified.md`-standard human-gated
    confirmation (screenshot evidence, not a log inference).

### Dream Breaker spawn-snapshot: cross-save property-value diff -- confirms fresh-read-at-spawn, doesn't yet find the visual lever

- Date: 2026-08-15
- Observed: new diagnostic (`dump_object_property_values`, gated behind `DUMP_GHOST_SPAWN_VALUES`)
  prints real values (not just names, unlike the earlier schema-only `dump_object_reflection`) for
  every bool/int/float/double/name/object-reference property on the ghost, right at spawn, plus the
  local pawn at that same moment. User loaded a genuine 0%-completion/fresh save (ghost spawned,
  dumped), then returned to the main menu and loaded a 100%-completion/all-items save (a second
  ghost spawned, dumped) -- both within the same running game process/log. 389 properties captured
  per dump, 4 dumps total. Diffed programmatically (instance-ID/level-path noise normalized out
  first).
  - **Ghost matched local pawn on both saves**, confirming the spawn snapshot again, this time at
    the raw property level, not just visually: only expected differences (fresh-spawn timers at 0,
    no `Controller`/`InputComponent`/`PlayerState` since the ghost isn't possessed, distinct
    per-instance camera/UI object references).
  - **Real cross-save differences on the ghost, confirming it reads genuine current-save
    progression fresh at each spawn**: `weaponEquipped?` `false`->`true`; ability-unlock flags
    `obtainedAttack?`/`obtainedAirKick?`/`obtainedSlide?`/`obtainedPlunge?`/`obtainedWallRide?`/
    `obtainedLight?`/`obtainedProjectile?`/`obtainedPowerBoost?`/`obtainedSlideJump`/
    `obtainedChargeAttack?`/`obtainedMap?` all `false`->`true`; progression stats `airKickLimit`
    0->3, `maxPower` 30->40, `healAmountPerDing` 10->20, plus nonzero upgrade counters
    (`healUpgrades`/`damageUpgrades`/`powerBuildUpgrades`/`powerMeterUpgrades`/`bonusAirKicks`).
  - **Still no new lead on the actual visual mechanism**: `WeaponMesh` itself is only an object
    *reference* (the same component either way, this dumper doesn't recurse into a referenced
    object's own properties) and `outfitDataTable` is an identical static `DataTable` asset
    reference on both saves (the options table, not a "currently equipped" selector) -- no field
    anywhere in these 389 properties represents "which outfit is equipped" or gates `WeaponMesh`'s
    own visibility. The four `WeaponMesh` sub-properties already cleared in the original
    investigation (`bHiddenInGame`/`bVisible`/`RelativeLocation`/`AttachSocketName`) were only ever
    traced mid-session on an already-armed save during a live throw -- this run did not re-check
    them on a genuinely fresh no-sword spawn specifically, since the dumper only covers the pawn's
    own top-level properties, not a referenced component's.
- Source: `UE4SS.log`, 2026-08-15 session, `[MeshGhostPseudo] DIAG: value-dumping ... = instance`
  through `DIAG: end of ... value dump.` blocks (two ghost dumps, two local-pawn dumps, 389
  properties each). Diagnostic code: `Plugin.cpp`'s `dump_object_property_values`, called from
  `ensure_ghost_spawned`, gated behind `DUMP_GHOST_SPAWN_VALUES`.
- Notes: confirms (does not newly discover) that the spawn snapshot is a real read of current save
  progression, not a hardcoded default -- consistent with, not contradicting, the two entries
  above. The open question is unchanged: what actually renders `WeaponMesh` visible/attached, since
  no property found anywhere so far (this dump or the four WeaponMesh properties from the original
  investigation) tracks it. A natural next step, not yet done: recurse the same value-dumper into
  `WeaponMesh`'s own properties specifically on a genuinely fresh unarmed spawn (as opposed to a
  live throw mid-session on an already-armed save, the only context those four properties were
  ever checked in before).

### Dream Breaker spawn-snapshot: WeaponMesh sub-properties are IDENTICAL across a genuine 0%/100% save comparison -- rules out the component entirely

- Date: 2026-08-15
- Observed: extended `dump_object_property_values` (see the entry above) to recurse into
  `WeaponMesh` itself (previously only ever printed as an object *reference* from the pawn-level
  dump), called right at ghost spawn on both the ghost and the local pawn. Same genuine
  0%-completion/fresh save vs. 100%-completion/all-items save comparison as the prior entry, one
  more pass. 250 properties captured per `WeaponMesh` instance, 4 dumps total.
  - **Ghost's `WeaponMesh` matched the local pawn's `WeaponMesh` on the 0% save**: every property
    identical (sanity check, as expected).
  - **Decisive result: the ghost's `WeaponMesh` on the 0% (no sword) save and the 100% (sword
    obtained) save are IDENTICAL across all 250 properties**, not just the four originally
    checked. Confirmed directly: `SkeletalMesh` is the exact same asset
    (`/Game/Meshes/Characters/mainWeapon.mainWeapon`) on both saves; `bVisible=true`,
    `bHiddenInGame=false` on both. This rules out `WeaponMesh` as the lever entirely, not just the
    four stock visibility/attachment properties already cleared in the original investigation --
    its full reflected surface never differs between an armed and unarmed spawn, at construction
    or otherwise. Whatever actually gates the sword being visually shown or hidden is not encoded
    anywhere on this component.
- Source: `UE4SS.log`, 2026-08-15 session, `DIAG: value-dumping ... WeaponMesh` /
  `DIAG: end of ... WeaponMesh value dump.` blocks (2 ghost + 2 local-pawn `WeaponMesh` dumps, 250
  properties each).
- Notes: this closes the WeaponMesh-as-lever question completely -- do not re-check its properties
  again without new grounding data. Next step, not yet done at the time of this entry: `animBPref`
  (the AnimBP instance) is the one remaining unexamined object in this class's own graph, and
  exactly where `landed?`/`jumped?`/`animEquippedWeapon` already live -- the dumper is being
  extended to cover it, plus enum/byte-backed fields (previously skipped as "unsupported type"),
  since a weapon-state selector is more likely to be enum-typed than the simple types checked so
  far.

### Dream Breaker weapon-visibility: animBPref cross-save diff finds the one real field; root cause identified and FIXED, confirmed live

- Date: 2026-08-15
- Observed: `dump_object_property_values` extended to also handle `EnumProperty`/`ByteProperty`
  (previously skipped entirely) and to recurse into `animBPref`. Same genuine 0%/100%-completion
  save comparison as the two entries above, one more pass -- 230 properties captured per
  `animBPref` instance, 4 dumps total.
  - **Ghost's `animBPref` matched the local pawn's on the 0% save** (sanity check; only expected
    differences -- `hSpeed`/`leanAmount`/uptime timers at 0 and `Has Movement Input?` false on the
    freshly-spawned, unpossessed ghost).
  - **Exactly one field differs between the ghost's `animBPref` on the 0% save and the 100% save,
    out of 230 properties checked**: `animEquippedWeapon` -- `false` vs. `true`. Nothing else on
    this object differs at all (the one other apparent diff, `As BP Player Goat Main`, is just the
    owning-pawn back-reference, expected per-instance noise).
  - **Root cause found from this result, not guessed**: `RemoteGhost`'s ghost-write code
    (`tickRenders` in `Plugin.cpp`) wrote the raw `weaponEquipped?`/`animEquippedWeapon`
    properties directly onto the ghost, unconditionally, every tick -- BEFORE the edge-gated
    `call_change_equipped_weapon`/`call_update_weapon_equip` calls that only fire on an actual
    transition. So by the time either function ran on a real throw/pickup, the ghost's own
    `animEquippedWeapon` had already been overwritten to the new value on that same tick. If either
    function's own Blueprint graph does the ordinary "only play the transition if the value
    actually changed" comparison (the same shape as the `animEquippedWeapon` field this pass just
    proved is the real, single differentiating field), both calls would always see old==new and do
    nothing -- explaining why two independently-tried functions failed identically without either
    being the wrong one.
  - **Fix**: reordered `tickRenders`' Dream Breaker block so `call_change_equipped_weapon`/
    `call_update_weapon_equip` run FIRST, while the ghost's own property still holds the OLD value,
    with the raw property write kept afterward as a safety-net sync (unchanged from before, just
    moved later). No new function, no new property -- purely a reorder of code already shipped.
  - **CONFIRMED LIVE, user watched it happen**: screenshot, both real player and ghost standing
    side by side, both empty-handed, sweater outfits matching, the thrown sword visible sitting on
    the ground (a real physics object) to the side. User: "yes!, the sword went away on the ghost
    when i threw it." `UE4SS.log` corroborates: `calling changeEquippedWeapon/updateWeaponEquip(false)
    -- armed=true prev=true` fired at `05:20:18.098`, and the ghost's own independent readback
    confirms `weaponEquipped?`/`animEquippedWeapon` both landed `false` immediately after, matching
    the screenshot.
  - **Not yet separately confirmed**: the reverse direction (pickup, false->true) as a standalone
    visibility-only test -- the same code path handles both directions symmetrically (any change
    from `last_synced_weapon_equipped` re-fires the calls), so it's expected to work the same way.
  - **Follow-up same day, user's own observation, mixed result -- correcting an earlier overclaim
    in this entry**: the throw/pickup *animation* (the drawing/throwing motion, distinct from mesh
    visibility) is only PARTLY fixed by this reorder. **Pickup animation**: confirmed fixed, user
    watched it directly -- previously didn't play at all, now plays correctly. **Throw animation**:
    user explicitly confirmed something else still blocks it specifically -- NOT fixed, despite
    sharing the same underlying `weaponEquipped?`/`animEquippedWeapon` sync path as pickup. The two
    directions are not symmetric here the way the visibility toggle itself is -- do not assume a
    fix confirmed for one direction (pickup) applies to the other (throw) without watching it
    separately, exactly the mistake this note originally made.
- Source: `UE4SS.log`, 2026-08-15 session -- `DIAG: value-dumping ... animBPref` dumps for the
  root-cause finding; `TRACE weapon ghost ... calling changeEquippedWeapon/updateWeaponEquip` and
  `TRACE weapon ghost ... target_weapon_equipped=false readback_weaponEquipped=false
  readback_animEquippedWeapon=false` lines for the live-test confirmation; user screenshot for the
  visibility confirmation; user's direct visual reports for the pickup-animation confirmation and
  the throw-animation still-broken finding. Fix code: `Plugin.cpp`'s `tickRenders`, Dream Breaker
  block (reordered 2026-08-15).
- Notes: this closes the Dream Breaker held/thrown visibility bug that six fix attempts (five
  negative, this one positive) chased across the day, and the pickup-animation question -- but the
  throw-animation question is still open, a real, separate, not-yet-root-caused gap -- see
  `status.md` and `phase7.md` for the updated open-items list. Cling-gem sparkle VFX and empty-hand
  glow remain completely untouched.

### Outfit/costume sync: real lever found via live value-diff (VisualMesh.SkeletalMesh/SkinnedAsset), first sync attempt produces a T-pose

- Date: 2026-08-15
- Observed: new diagnostic (`OUTFIT_TRACE`) periodically dumped the local pawn's `VisualMesh`
  (the main body mesh, distinct from `WeaponMesh`) at ~0.65s cadence while the user cycled through
  outfits live via the in-game menu. 61 samples over ~55s, diffed consecutively (no cross-save
  normalization needed -- same continuous pawn instance throughout).
  - **Decisive, immediate result**: `SkeletalMesh`/`SkinnedAsset` (both `ObjectProperty`, changing
    together on every sample) are the ONLY properties that ever differ across consecutive samples
    (one anomalous block also showed `bOverrideMinLOD`/`bUseBoundsFromLeaderPoseComponent`/
    `bForceWireframe`/`bDisplayBones`/`bDisableMorphTarget` flipping true->false once, plausibly an
    unrelated transient during the mesh hot-swap, not investigated further). A real gallery of
    outfit mesh assets was observed cycling through: `sybil_outfit_sweater`, `dreamLady_pro`,
    `sybil_outfit_shoujo`, `dreamLady_Min`, `dreamLady_pants`, `sybil_outfit_knight`,
    `sybil_outfit_Flower`, `dreamLady`, `dreamLady_pantsClass`, `sybil_outfit_nun`,
    `sybil_outfit_Jam`, and more.
  - **Unlike Dream Breaker, no boolean flag or animBPref indirection at all** -- outfit is a direct
    mesh-asset reference swap on the pawn's own `VisualMesh` component, the simplest possible
    shape. `AnimClass` stayed constant (`ABP_CopySybil_C`) across every sample, and no `Skeleton`
    property exists on the component itself (checked directly in the saved dumps) -- consistent
    with all these outfit variants sharing one common skeleton, not separate incompatible rigs.
  - **Real sync code shipped same day**: local read sends the mesh asset's real object path (not
    the `GetFullName()` "ClassName Path" form -- stripped to match `StaticFindObject`'s expected
    input, the same lookup pattern already used for the `SetViewTargetWithBlend` hook elsewhere in
    this file) as a new `outfit_mesh` extras string field; ghost side resolves it via
    `StaticFindObject<UObject*>` and writes both `SkeletalMesh`/`SkinnedAsset` directly on the
    ghost's `VisualMesh`, edge-gated the same way as the weapon sync.
  - **First live test, real negative result**: the ghost's outfit did NOT visually update to match
    the real player's costume change -- instead, the ghost's mesh entered a T-pose (screenshot
    evidence: real player correctly in a sweater, ghost's mesh in the default bind pose, arms out).
    The mesh reference itself plausibly did land (not independently confirmed by readback on this
    specific run, though the readback logging added for this feature would show it on the next
    run) -- T-pose is the standard symptom of a skeletal mesh asset changing without the engine
    re-binding/re-initializing the anim instance against it, consistent with this project's
    existing "direct property writes stick but skip whatever bookkeeping the real setter function
    performs" pattern (already seen for Mobility/render-state elsewhere in this phase).
- Source: `UE4SS.log`, 2026-08-15 session, `DIAG: value-dumping local pawn VisualMesh` /
  `DIAG: end of local pawn VisualMesh value dump.` blocks (61 samples). Sync code: `Plugin.hpp`'s
  `RemoteGhost::target_outfit_mesh`/`last_synced_outfit_mesh`; `Plugin.cpp`'s outfit ghost-write
  block in `tickRenders`. Negative result: user screenshot, T-pose visible on the ghost.
- Notes: root cause of the T-pose not yet resolved. A new one-shot diagnostic
  (`dump_object_reflection` on the ghost's `VisualMesh`, gated behind
  `DUMP_VISUALMESH_FUNCTIONS`) was added to find what setter functions this build's reflection
  actually exposes before guessing a name (e.g. `SetSkeletalMesh`) -- this build has repeatedly
  shown UFunctions silently missing from reflection while direct property writes work, so the real
  available surface needs confirming, not assumed from general UE API knowledge.

### Outfit/costume sync: T-pose FIXED via SetSkeletalMeshAsset, confirmed live

- Date: 2026-08-15
- Observed: the `DUMP_VISUALMESH_FUNCTIONS` dump (triggered live during the T-pose test above)
  found `SetSkeletalMeshAsset` as the one real candidate on `VisualMesh`'s reflection surface --
  `PropertiesSize=8` (one pointer-sized parameter). No `SetSkeletalMesh` (the older/deprecated
  name), `InitAnim`, `MarkRenderStateDirty`, or `RecreateRenderState` exist on this build at all.
  - The function's single parameter's real name was never confirmed (unlike
    `updateWeaponEquip`/`changeEquippedWeapon`, which matched by exact name) -- grounded instead by
    `PropertiesSize == 8` leaving nowhere else for a pointer to go: `call_set_skeletal_mesh_asset`
    (`Plugin.cpp`) iterates the function's reflected properties and writes to whichever single one
    it finds, rather than guessing a name.
  - **Applied the weapon-fix's ordering lesson proactively this time** (not after another failed
    live test): `call_set_skeletal_mesh_asset` is called FIRST, before the direct
    `SkeletalMesh`/`SkinnedAsset` property writes (kept afterward as a safety net) -- the reverse
    order that broke the weapon-visibility fix originally.
- **CONFIRMED LIVE**: user screenshot, both real player and ghost standing side by side in the same
  matching costume, correct pose (no T-pose), after a costume swap. `UE4SS.log` corroborates: two
  clean `outfit mesh applied for ghost ...: target=... readback=...` lines this session (sweater,
  then shoujo), independent readback matching the target on both, zero `WARNING: SetSkeletalMeshAsset`
  lines (the call never refused to fire).
- Source: `UE4SS.log`, 2026-08-15 session -- `DIAG: ... function 'SetSkeletalMeshAsset'
  PropertiesSize=8` line for the discovery; `outfit mesh applied for ghost ...` lines for the
  live-test confirmation; user screenshot for the actual visual confirmation. Fix code:
  `Plugin.cpp`'s `call_set_skeletal_mesh_asset` and the outfit ghost-write block in `tickRenders`.
- Notes: this closes the outfit/costume sync gap end to end -- read, send, resolve, apply, all
  confirmed live in one session, from discovery to fix. `DUMP_VISUALMESH_FUNCTIONS`/`OUTFIT_TRACE`
  both flipped back to `false`. Cling-gem sparkle VFX and empty-hand glow remain the only completely
  untouched Pseudoregalia visual gaps left.

## Pseudoregalia ghost trail (afterimage) VFX: `Spawn After Image` call confirmed to work

- Same-day continuation of the slide/ultra-hop trail-VFX investigation (`PLAYER_FIELDS.md`'s trail-
  VFX section): `spawnTrackingParticles?` and `AnimGraphNode_Trail` were both ruled out earlier this
  session, leaving `Spawn After Image(Duration: float)` (found on the local pawn) as the real,
  untested lead.
- Prototype: `call_spawn_after_image` (`Plugin.cpp`, modeled directly on `call_change_equipped_weapon`
  -- `GetFunctionByNameInChain`/params-buffer/`ProcessEvent`), gated behind a new diagnostic-only
  `AFTERIMAGE_CALL_TEST` flag, calling it on every remote ghost at a fixed ~3s cadence, deliberately
  decoupled from any real trigger condition -- same phased approach as the weapon-visibility chase
  (confirm the call itself does something before wiring it to the right condition).
- **CONFIRMED LIVE**: user ran a loopback test with a visible ghost and watched the afterimage/trail
  effect actually appear on the ghost, repeating on the test cadence -- including while the ghost was
  just walking (not sliding), which is expected and correct: this test call is intentionally
  unconditional, not yet tied to the real slide/ultra-hop trigger.
- Source: user's own live report, this session (2026-08-15). Fix/prototype code: `Plugin.cpp`'s
  `call_spawn_after_image` and the `AFTERIMAGE_CALL_TEST`-gated call site in `tickRenders`.
- Notes: this confirms `Spawn After Image` is the real trigger function, not just a plausible name --
  the missing piece was never "which function," it was "has anyone actually called it." Next step,
  not yet done: replace the fixed-cadence test call with a real edge-detected trigger keyed off the
  real player's `actionState` transitions (18=slide, 8=airborne flip-after-slide, both correlated
  live earlier this session -- see `PLAYER_FIELDS.md`), sent to the ghost as a one-shot pulse (same
  `landed?`/`jumped?` shape), then flip `AFTERIMAGE_CALL_TEST` back to `false` once that's real
  production code. Color (`afterimageColor`, also found this session) is a separate follow-on, not
  part of this fix.
  - **Hardening added same day, not itself live-tested (a defensive no-op for every legitimate
    asset seen so far)**: `target_outfit_mesh` is peer-controlled data (`json_string_field`'s own
    comment already documents extras fields this way), and `StaticFindObject` with `Class=nullptr`
    matches ANY object at a given path regardless of type -- a malformed or adversarial path could
    otherwise resolve to something that isn't a `USkeletalMesh` and get written into the
    `SkeletalMesh`-typed property slot anyway. Added a class-name check
    (`GetClassPrivate()->GetName() == "SkeletalMesh"`) before applying; refuses and logs a warning
    otherwise.
  - **Modded-costume behavior, reasoned from the code, not yet live-tested with a real mod**: the
    mechanism is generic -- it sends whatever real asset path the sender's `VisualMesh.SkeletalMesh`
    currently is, vanilla or modded, no per-mod code needed. A receiving peer WITH the same mod
    resolves and applies it normally. A receiving peer WITHOUT it gets a null `StaticFindObject`
    result (that asset genuinely doesn't exist in their install) -- logs a warning, ghost's outfit
    simply doesn't update, no crash, no forced fallback to any specific default. Untested caveat:
    `StaticFindObject` only finds objects already loaded into memory, not anything unloaded on
    disk, so even a peer who has the same mod installed could see a transient "not found" if that
    specific asset was never loaded into their session.
  - **First-spawn fallback, confirmed by re-reading the ghost-spawn code, not a new live test**:
    since the ghost is a clone of the RECEIVING peer's own local pawn (see the two "spawn-snapshot"
    entries above), it already starts dressed in the receiving peer's own currently-equipped
    outfit before any sync code ever touches it -- if the sender's outfit (modded or otherwise)
    never resolves, the ghost keeps that starting look rather than defaulting to nothing or a
    broken/empty mesh.
  - **Real bug found and fixed while reasoning through this, before any live test hit it**: without
    a fix, a target that fails to resolve (e.g. a peer's mod this machine lacks) would retry
    `StaticFindObject` and re-log its warning on EVERY tick forever, since a failed target never
    updates `last_synced_outfit_mesh`. Added `last_failed_outfit_mesh`/`last_outfit_attempt_tick`
    (`RemoteGhost`) to throttle retries of the same still-failing target to once per
    `LOG_INTERVAL_TICKS` (~2s), while a genuinely new target is still tried immediately regardless
    of the throttle. Not itself live-tested (no real missing-mod scenario was reproduced this
    session) -- the existing successful sync path (real, present assets) is unchanged by this fix.

## Pseudoregalia ghost trail (afterimage) VFX: real repeating trail CONFIRMED working

- Continuation of the same-day trail-VFX investigation (`PLAYER_FIELDS.md`'s trail-VFX section,
  this file's earlier "Spawn After Image call confirmed" entry). Four real live-test rounds were
  needed after the single-call confirmation, each ruled out by an actual live test, not assumption:
  1. Repeat-calling `Spawn After Image` on a tight ~40ms interval (edge-detected `afterimage_count`,
     re-fired while `actionState` held 18/8) -- fired once per action instead of repeating.
  2. A ghost-side "coalescing" fix (call the delta count of times instead of once, per received
     network update) -- identical "fires once" symptom on a second live test.
  3. A pivot to calling `spawnNumAfterimages` (the real game's own orchestrating function) once per
     edge, trusting its internal `SetTimerDelegate`-based loop for the repeat -- confirmed via
     dual-side tracing (`TRAIL_TRIGGER_TRACE`) that the call reliably resolves and fires, but
     produced ZERO visible afterimages, worse than attempt 1.
  4. A much wider real-measured interval (~200ms) for the direct-repeat-call approach -- same
     "fires once, at weird times" symptom, ruling out spacing/cooldown as the cause too.
- **Root cause found via a targeted property re-search** (`OBJECT_REFLECTION_DUMP`, one more pass):
  `afterImagesToSpawn` (`IntProperty` on the pawn) had never been searched for by name.
  `spawnNumAfterimages`'s own reflected internals (`CallFunc_Subtract_IntInt_ReturnValue`,
  `Temp_int_Variable`, `CallFunc_Greater_IntInt_ReturnValue`) are consistent with a "spawn N via a
  repeating timer, counting an externally-set N down" loop -- and attempt 3 never wrote that count
  before calling it, plausibly making its internal "count > 0" check fail immediately.
- **Fix**: write `afterImagesToSpawn = 6` on the ghost, then call `spawnNumAfterimages` once per
  action-start edge (`actionState` transitioning into 18=slide or 8=airborne flip-after-slide),
  trusting the game's own internal timer for the repeat/spacing rather than reimplementing it.
- **CONFIRMED LIVE**: user ran a real loopback test (slides, slide-jump/backflips, an ultra-hop
  attempt) and confirmed the ghost now shows a real repeating trail matching the shape of the real
  player's own afterimages, not a single flash.
- Source: user's own live report, this session (2026-08-15). Fix code: `Plugin.cpp`'s
  `call_spawn_num_afterimages`, the `afterImagesToSpawn` property write and
  `call_spawn_num_afterimages` call in the ghost-apply block (`tickRenders`), and the edge-detected
  `afterimage_count` trigger (`Plugin.hpp`/`Plugin.cpp`).
- Notes: two known follow-ups, NOT part of this fix. (1) The ultra-hop's blue trail color didn't
  show — trail color (`afterimageColor`, a separate `FLinearColor` property found earlier this
  session) isn't synced yet, only the trigger. (2) A real false positive: a quick 180-degree
  turn-around (walk one direction, quickly reverse) also fires the trigger, which shouldn't happen
  — `actionState==18` is plausibly not exclusively "sliding," or some other condition needs to be
  added to the trigger check. Not yet root-caused; see `PLAYER_FIELDS.md` for the next investigation
  step.

## Pseudoregalia trail-VFX UFunction hook: CRASHED the game — do not retry this approach

- **What was tried**: replacing the polled-`actionState` trail trigger (a known-imperfect heuristic
  — see the two follow-ups in the entry above) with a real event source:
  `UFunction::RegisterPostHook` on the local pawn's own `Spawn After Image` and
  `spawnNumAfterimages`, so `afterimage_count` would increment on the actual call rather than on a
  guess about when one probably happened. Motivated by the user's own read after five failed
  heuristic rounds: "the timing/triggers feel inconsistent ... there has to be a better way than
  trying to manually time it" — correct instinct, wrong mechanism on this build.
- **Result: Fatal error crash**, user-witnessed (`The UE-pseudoregalia Game has crashed and will
  close / Fatal error!`), ~18 seconds into normal play after the hooks registered.
- **Evidence, read directly from `UE4SS.log`**: both hooks registered successfully and logged real
  callback IDs (`trail-VFX hooks registered on BP_PlayerGoatMain_C ... (SpawnAfterImage=6
  spawnNumAfterimages=7)`, 07:29:26), then fired **zero times** across the whole session despite
  real sliding, and the log simply stops mid-normal-operation (steady `bridge: connected=true`
  lines every ~0.67s right up to 07:29:44) with no error, warning, or stack trace logged.
- **Root cause (mechanism, not just correlation)**: UE4SS's `RegisterPre/PostHook` works by
  swapping the `UFunction`'s own function pointer (`SetFuncPtr`). That is safe for **native**
  functions — which is exactly what this file's one existing, long-working hook targets
  (`SetViewTargetWithBlend`, whose `register_camera_fightback_hook` comment already documents the
  native-vs-Blueprint distinction and why a ProcessEvent-based approach failed for it). But
  `Spawn After Image`/`spawnNumAfterimages` are **Blueprint** functions, whose function pointer is
  the shared `ProcessInternal` bytecode entry point rather than a per-function native routine.
  Swapping it both failed to intercept any call (zero fires) and corrupted execution (crash).
- Source: `UE4SS.log` from the 2026-08-15 session (live install), lines around 07:29:26–07:29:44;
  user's own crash report. Reverted the same session; the trail trigger is back on the polled
  `actionState` heuristic, which does not crash.
- **Do not retry UFunction hooks on Blueprint functions on this build.** A `DO NOT re-add` note
  sits at the removed code's location in `Plugin.hpp`. A genuinely different event source (not this
  mechanism) would still be the right long-term fix for the heuristic's known imperfections.
- **Process lesson, worth more than the finding**: this same change also swapped the ghost-side
  apply path away from the confirmed-working `afterImagesToSpawn` + `spawnNumAfterimages` at the
  same time as changing the trigger — two variables at once, against `CLAUDE.md`'s "one diagnostic
  at a time" rule — which regressed a working visual and briefly confused the diagnosis. The apply
  path was restored unchanged before the revert was tested.

## Pseudoregalia ghost vs. local player, full property diff: NO master VFX gate; the real difference is possession

- **Question asked** (user, 2026-08-15): is there a quick toggle to just "enable all VFX" on the
  ghost? Answered by pointing the existing `DUMP_GHOST_SPAWN_VALUES` dumper (built for the earlier
  cross-save weapon investigation) at a new pair — the ghost and the local player, captured at the
  same instant at ghost spawn — and diffing every property value, rather than guessing gate names.
- **Result: the ghost is identical to the real player on 381 of 389 pawn properties** (and 228 of
  230 on `animBPref`). There is no master VFX/particle enable flag differing between them.
  - `spawnTrackingParticles?` — the prime suspect, a bool previously ruled out as a per-action
    *trigger* but never checked on the ghost — reads **`true` on the ghost**, same as the local
    player. Definitively not a gate.
  - Every ability-unlock flag is already `true` on the ghost too (`obtainedSlide?`,
    `obtainedWallRide?`, `obtainedSlideJump`, `obtainedChargeAttack?`), on a 100%-completion save.
- **The only meaningful differences are possession/ownership**, all null on the ghost:
  `Controller`, `InputComponent`, `Owner`, `PlayerState`, `PreviousController`. The remaining three
  (`actionStateUptime`, `moveStateUptime`, `proximityToSaveCrystal`) are incidental runtime values,
  not gates — the ghost had simply just spawned.
- **What this explains, in one stroke**: the ghost has zero VFX for *everything* (not per-effect
  bugs) because it is fully capable but **nothing drives it**. Its ability logic is input-driven —
  no `Controller` means no `InputComponent` means the input events that start a slide/charge/etc.
  never fire, so the pawn's own ability code that would spawn those effects never runs at all. This
  also explains why manually calling `spawnNumAfterimages` on the ghost works: that bypasses the
  never-run ability logic and calls the effect directly.
- Source: `UE4SS.log`, 2026-08-15 session, the `DIAG: value-dumping spawned ghost` /
  `DIAG: value-dumping local pawn at ghost-spawn` blocks (389 properties each), diffed
  programmatically with object-instance IDs normalized so identical component references don't read
  as differences. Agent's own log read, per `CLAUDE.md`'s evidence standard for log-sourced facts.
- **Consequence for design**: this is the concrete, evidence-backed form of the "let the ghost's own
  pawn logic do the work" principle (`agent_docs/ideas.md`, Pseudoregalia item 3). The general fix
  for ghost VFX is not per-effect reverse engineering but getting the pawn's own ability entry
  points to run. **Constraint**: possessing the ghost with the real player controller is exactly
  what Phase 7.4's auto-possess saga exists to prevent (it steals the player's control/camera), so
  "give it a Controller" is not a free move — see `ideas.md` for the open options.

## Pseudoregalia empty-hand recall glow via `manageRecallIdleFX`: NEGATIVE — the pattern has a precondition

- **What was tried**: the second application of the "trigger the pawn's own system" pattern that
  produced the afterimage trail. `manageRecallIdleFX` was called on the ghost on the weapon-equip
  edge (one call per real throw/pickup). Chosen over the cling-gem sparkle because it depends only
  on weapon state, which this adapter already syncs, with no geometry/collision dependency.
  Signature confirmed by live param dump first: all internals are Blueprint temporaries
  (`CallFunc_IsValid_ReturnValue` x3, `CallFunc_BooleanAND_ReturnValue`,
  `CallFunc_Not_PreBool_ReturnValue`, `CallFunc_SpawnSystemAttached_ReturnValue`,
  `CallFunc_SpawnSoundAttached_ReturnValue`) — i.e. it spawns a Niagara system plus a sound behind
  its own validity guards.
- **Result: no glow on the ghost** (user-confirmed live, screenshot). No crash, no visible change.
- **Test limitation, stated honestly**: the call was NOT instrumented with a trace line, so this
  result does not distinguish "the call never resolved" from "it resolved and bailed on a guard."
  A future retry should log resolution + entry, per this repo's own "never log the value you just
  wrote as proof" discipline applied to calls.
- **Leading explanation (unconfirmed)**: the `IsValid` guards most plausibly validate `weaponRef` —
  the reference to the **real thrown-weapon actor in the world**, previously found (see the
  `WEAPON_SYNC_TRACE` entries) to go non-null only while the weapon is actually thrown. The ghost
  has no such actor and `weaponRef` is not synced, so the guard fails and nothing spawns.
- **The real lesson, and the reason this negative result matters**: the "trigger the pawn's own
  system" pattern (`ideas.md` Pseudoregalia item 3) has a **precondition clause**. It works when
  the system's preconditions are satisfied by state we can write — the trail worked because its
  only precondition was `afterImagesToSpawn`, a plain int. It fails when preconditions depend on
  real world objects or interactions the ghost doesn't have.
- **Predictive consequence**: the cling-gem sparkle is expected to fail the same way, for a
  structural reason rather than a findable-function reason — `doWallRun`/`wallRunTick` depend on
  `wallRideHit` (a real geometry hit result), and the ghost's collision is deliberately disabled
  (`GHOST_COLLISION_ENABLED = false`, kept off for the melee-death hazard in `risks.md`), so it can
  never produce one. Both remaining Pseudoregalia VFX gaps are therefore blocked on the ghost
  lacking real world-interaction state, not on identifying the right function to call.
- Source: user's own live report + screenshot, 2026-08-15 session. Call site:
  `call_manage_recall_idle_fx` and the weapon-equip edge block in `tickRenders` (`Plugin.cpp`).

## Pseudoregalia trail (afterimage) COLOUR write: CONFIRMED working on the ghost

- **What was built**: `afterimageColor` (an `FLinearColor` on the pawn) read live from the local
  player each tick, sent through `extras` as `afterimage_color: [r,g,b]`, and written onto the
  ghost immediately before its trail burst is triggered. Read live rather than cached at spawn
  because the base game changes this dynamically — a perfect-timing "ultra" hop trails BLUE instead
  of the normal yellow, which is exactly the case a one-time read would miss.
- **Layout resolved by reflection, not assumed**: the vendored SDK only forward-declares
  `FLinearColor` (`Core/Math/MathFwd.hpp`), so `resolve_linear_color_offsets` finds the struct via
  `UClass::FindProperty` → `FStructProperty::GetStruct()` → `FindProperty("R"/"G"/"B"/"A")` and uses
  each channel's real reflected offset. Deliberate, per `pitfalls.md`'s `FRotator` entry, where
  assuming a struct's layout against this same SDK was a real bug. `A` is deliberately never
  written — its meaning (trail fade/transparency) was never verified, so the ghost keeps its own.
- **CONFIRMED LIVE**: with `AFTERIMAGE_COLOR_TEST_OVERRIDE` on, forcing the ghost's trail to bright
  magenta while the real player's stayed yellow, the user watched the ghost's trail render magenta.
  This proves the property write actually lands and is consumed by the spawn.
- **Why the override existed at all** (worth reusing): on a same-machine loopback both characters
  naturally have the SAME trail colour, so "synced correctly" and "never written at all" look
  identical on screen — the exact confound that made the weapon/outfit sync so hard to judge. The
  user raised this unprompted ("its kinda hard to tell if its different or not"). A deliberately
  WRONG value is the cheapest way to prove a write path, same technique as `WEAPON_SYNC_INVERT`.
- Source: user's own live report, 2026-08-15 session. Code: `resolve_linear_color_offsets` /
  `read_linear_color` / `write_linear_color_rgb` and the trail-burst block in `tickRenders`
  (`Plugin.cpp`), `target_afterimage_color`/`afterimage_color_valid` (`Plugin.hpp`).
- Notes: override flipped back off after confirmation, so the ghost now shows the peer's real
  colour. A per-peer distinct-colour feature idea came out of this test; see `ideas.md`'s
  Pseudoregalia section.
- **CORRECTION, same session**: an earlier version of this entry claimed the blue-on-ultra case
  "follows for free from the live read." **That is FALSE and was written before it was watched.**
  See the entry below.

## Pseudoregalia blue ultra-hop trail does NOT come from `afterimageColor` — separate mechanism

- **Symptom**: with trail-colour sync working and confirmed, the ghost still trails YELLOW during a
  perfect-timing "ultra" hop while the real player trails BLUE (user-confirmed live).
- **Decisive evidence**: an every-tick edge-logged trace of the local player's own `afterimageColor`
  (logging only on real change, deliberately not on a periodic sample, since an ultra hop's window
  is only ~690ms and a ~2s sample could miss it entirely) recorded exactly TWO events across a full
  session containing a real ultra hop: one `read_ok=false` before the pawn existed, then
  `rgb=(1.000, 0.888, 0.260)` — yellow — which then **never changed again**, through the ultra
  included.
- **Conclusion**: `afterimageColor` is the base/customisable trail colour (it is the field the
  third-party `attire-ui-overhaul` dash-colour picker writes — see `licensing.md`), NOT the source
  of the ultra's blue. The blue is produced by some other mechanism inside the spawn path.
- **What this does NOT invalidate**: the colour sync itself is still correct and still worth having
  — it carries a peer's *chosen/custom* dash colour, and its write path is independently confirmed.
  It simply does not carry the blue.
- Source: `UE4SS.log`, 2026-08-15 session, `TRACE trailColor local` lines; user's live report of the
  ghost's colour during the ultra.
- **Follow-up trace run, same session — all ultra-state candidates RULED OUT.** An edge-logged
  trace of `ultraCap`/`fullUltraModifier`/`cappedUltraModifier`/`animJumpType` across a capture the
  user described as "2-3 slides, 6-7ish backflips, 1 ultra at the end":
  - `fullUltraModifier` (1.2500) and `cappedUltraModifier` (1.1000) **never change at all** — they
    are tuning constants, not per-jump state.
  - `ultraCap` toggles, but identically on every jump cycle (false grounded → true airborne → false
    on landing), including all the normal backflips. Not ultra-specific.
  - `animJumpType` runs the identical `13 → 11 → 0` sequence on all ~8 backflips, the ultra
    included. Notable because this adapter **already syncs `animJumpType`** to the ghost, so if it
    were the marker the blue would already work.
  - The only correlate is launch `vSpeed`, and it does not separate: normal backflips reached
    1369.0 and 1348.6, the ultra 1388.9 — a ~1.4% gap, i.e. noise, not a discriminator.
- **Status: PARKED, deliberately.** The blue's source is not derivable from any polled pawn state
  found so far; it most plausibly lives inside the afterimage spawn Blueprint's own logic (a
  different Niagara asset/material picked at spawn time) rather than in a readable property. That
  would need Blueprint-graph inspection, not more property tracing — and Blueprint UFunction hooks
  are known to crash this build (see the UFunction-hook entry above), which closes the obvious
  dynamic route. Weighed against what already works (the trail itself, and custom colour sync),
  this specific cosmetic nuance is low value for the remaining cost. Do not resume by guessing more
  property names — that avenue is now well-covered and empty.

## Pseudoregalia ghost hurtbox: `bCanBeDamaged=false` does NOT stop the melee-death bug

- **Context**: ghost collision was re-enabled and kept on as a deliberate feature (see
  `ideas.md`), leaving the 2026-08-13 melee-death hazard live — attacking a ghost damages/kills the
  REAL player. User proposed the right shape of fix: keep collision, remove the hurtbox.
- **What was tried**: writing `bCanBeDamaged = false` on every ghost at spawn. Chosen because it is
  a stock `AActor` UPROPERTY — the engine-level gate standard `TakeDamage`/`ApplyDamage` paths
  check — so it is not a guess about this game's own damage model, and because `pitfalls.md`
  prefers a direct property write over a setter UFunction on this build.
- **Result: NEGATIVE, and unambiguously so.** The user could still hit and kill themselves via the
  ghost. Critically, this is not a "did the write land?" ambiguity: the log shows
  `ghost hurtbox disabled (bCanBeDamaged=false).` on all four ghost spawns that session, so the
  property resolved and was written every time.
- **Conclusion**: Pseudoregalia's melee does NOT route damage through UE's standard damage path. It
  almost certainly runs its own overlap/trace check and applies the effect directly, which
  `bCanBeDamaged` has no authority over. Any real fix has to target whatever channel/query that
  bespoke check uses — still unidentified.
- Source: user's live report + `UE4SS.log`, 2026-08-15 session. Code: the `GHOST_COLLISION_ENABLED`
  block in `ensure_ghost_spawned` (`Plugin.cpp`).
- **The hazard therefore remains live and accepted** — see `ideas.md`'s ghost-collision entry.

## Pseudoregalia wall-ride (cling gem) state: `moveState=4` is the marker, and it is ALREADY synced

- Edge-logged trace across many real clings (`WALLRIDE_TRACE`), 2026-08-15:
  - **`moveState == 4` is the cling state** — present on every single cling, unambiguous.
  - **`actionState` stays `0` throughout** — it is NOT the wall-ride marker, unlike the slide/flip
    case where 18/8 mattered.
  - `movementMode == 3` (Falling) during a cling.
  - `currentWallRunClings` counts up 1→4 per wall (`wallRunClingLimit` is 5).
  - **`canWallRun` reads `false` even while actively wall-riding** — a misleading name; it is not a
    "currently wall-running" flag and must not be used as one.
  - **`wallRideVFX` transitions null → non-null on the FIRST cling and then stays non-null for the
    rest of the session** — the VFX component is spawned once and reused/reactivated, not created
    per cling. On the ghost it is `null` (never spawned), per the ghost-vs-player diff.
- **Key consequence**: `moveState` is already mirrored to the ghost (`target_move_state`), so the
  ghost already receives `moveState = 4` during a peer's cling — and still shows no VFX. Third
  independent confirmation that ability VFX come from the gameplay logic, not from the mirrored
  state value or the AnimBP.
- **What this unlocks**: a clean, reliable trigger signal for a ghost-side `doWallRun` attempt
  (edge on `moveState` entering 4), which is what the earlier investigation lacked. Whether that
  call succeeds still depends on the precondition clause (`wallRideHit` is a real geometry hit
  result) — collision is now enabled on ghosts, which may or may not be enough.
- Source: `UE4SS.log`, 2026-08-15 session, `TRACE wallRide` lines (37 state changes across many
  real clings).

## Pseudoregalia cling-gem (wall-ride) VFX on the ghost: CONFIRMED WORKING

- **The second successful application of the "trigger the pawn's own system" pattern**
  (`ideas.md` Pseudoregalia item 3), after the afterimage trail — and the one that closes a gap
  previously written off as structurally blocked. Three iterations, each fixing a real observed
  defect rather than a guessed one:
  1. **Start**: on the ghost's mirrored `moveState` entering 4 (the confirmed cling marker), call
     `doWallRun` on the ghost. **Confirmed live: the cling-gem effect appears on the ghost.**
  2. **Stop**: the effect then persisted forever, following the ghost around while walking. Fixed by
     calling stock `Deactivate` on the ghost's own `wallRideVFX` component on the falling edge
     (`moveState` leaving 4) — matching what the real player's own logic evidently does, since
     `wallRideVFX` stays non-null on the real player too rather than being destroyed.
     **Confirmed live: stops correctly.**
  3. **Silence**: the paired `wallRideSFX` then looped forever. Fixed by stopping the audio
     component immediately after `doWallRun` starts it (falling edge also stops it, as a backstop),
     so it is never audible. **Confirmed live: audio fixed.**
- **What made this succeed where the recall glow failed**: its precondition was satisfiable.
  `doWallRun` evidently needs no state the ghost lacks — notably, ghost collision was enabled
  earlier the same session, which may or may not have been necessary (untested either way; it was
  already on before this attempt, so this entry cannot claim it was required).
- **Design rule this produced, now recorded in `ideas.md` as the "silence clause"**: triggering the
  pawn's own systems hands you its AUDIO for free, and for a visual-only layer that is a defect.
  Ghosts should be silent; suppress the audio component at the point of the triggering call, not on
  the way out. Applies to every future ability trigger.
- Source: user's own live reports across three test rounds, 2026-08-15 session. Code:
  `call_do_wall_run`, `call_component_deactivate`, `call_audio_component_stop`, and the
  `WALLRUN_TRIGGER_TEST` block in `tickRenders` (`Plugin.cpp`);
  `RemoteGhost::last_wallrun_move_state` (`Plugin.hpp`).
- Notes: this leaves the empty-hand recall glow as the only remaining Pseudoregalia ability-VFX
  gap, and that one is still genuinely blocked on a precondition (a real thrown-weapon actor) rather
  than on finding a function.

## Pseudoregalia trail trigger rewritten to mirror the game's own `afterImagesToSpawn` — pipeline exact, but incomplete coverage

- **Why rewritten**: every `actionState`-based heuristic failed live in a different way — firing on
  a quick 180-degree turn-around (shares `actionState 18` with a real slide), then on a plain
  walking backflip (`actionState 8` means "backflip" generically, not "slide-launched trick"), plus
  afterimages lingering in odd places from a hardcoded burst size.
- **The fix**: stop inferring, and mirror `afterImagesToSpawn` — the int the REAL GAME sets when IT
  decides to trail. The game's timer counts it down as it spawns, so any INCREASE is a fresh burst
  and its value is the true size. Same principle that made `moveState==4` the right cling-gem
  trigger: read the game's own decision instead of reconstructing it.
- **Result: the pipeline is exact.** A live capture recorded 6 real bursts detected locally and 6
  applied to the ghost — 1:1, no drops on either side. User: "the timing/triggers feels more
  precise now."
- **Two findings worth keeping from that capture**:
  - The real burst size is **5**, not the 6 previously hardcoded — now carried over the wire
    (`afterimage_n`) so the ghost reproduces the true size instead of a guess.
  - **`actionState` read 0 on five of the six real bursts.** This retrospectively explains why every
    actionState-based heuristic failed and could never have worked: the game trails at moments where
    that field says nothing useful.
- **REMAINING GAP, and it is not this pipeline**: some afterimages still don't appear on the ghost.
  Since detection and application match exactly, those are actions where the game **never sets
  `afterImagesToSpawn` at all** — i.e. a second spawn path, almost certainly direct
  `Spawn After Image` calls rather than the counted burst. Catching those would require
  intercepting the call itself, which is exactly the Blueprint UFunction hook that **crashed the
  game** (see that entry above). **So this is a real ceiling, not a missing idea** — do not resume
  by hunting for another property; the property-mirroring avenue is now provably exact and provably
  insufficient on its own.
- Source: `UE4SS.log`, 2026-08-15 session, `TRACE trailTrigger` lines; user's live reports.

## Pseudoregalia plain-slide trail + ghost-sinks-into-floor: BOTH FIXED, from one capture

- **One narrow capture answered both.** After several partial captures had produced wrong answers,
  a deliberately minimal one — walk, then four plain slides, nothing else — with
  `CapsuleHalfHeight`/`bIsCrouched`/`z` logged **ungated** on every active tick. Ungated matters:
  an earlier version gated the capsule log behind the slide trigger being debugged, so it captured
  nothing at all. **Never gate a diagnostic behind the thing you are trying to diagnose.**
- **What a plain slide actually is**: `actionState == 1` with the capsule **shrunk 65 -> 22**, four
  runs of *exactly* 87 ticks each, origin dropping 567.2 -> 524.2 (feet stay planted).
- **Three earlier trigger guesses were all wrong**, and this is why:
  - `actionState == 18` — also fires on a turn-around skid.
  - `actionState == 18 && animJumpType == 13` — that pair belongs to the skid and to the slide that
    *precedes a backflip*; it fired **zero** times across a session of real plain slides.
  - `afterImagesToSpawn` alone — never set during a plain slide at all (0 across 12k ticks).
  - **Fix**: key on the capsule shrink instead. Deliberate choice — the shrink is a *physical fact*
    of the move, whereas the state enums demonstrably overlap between moves and burned three
    attempts. **Confirmed live: the slide afterimage now appears.**
- **Floor-sinking, root-caused with arithmetic rather than theory**: peer feet = `524.2 - 22 =
  502.2`; a ghost still 65 tall teleported to 524.2 has feet at `459.2`, i.e. exactly **43 units**
  (65-22) under the floor.
  - **First fix attempt FAILED informatively**: mirroring the ghost's `CapsuleHalfHeight` provably
    applied (readback showed 22) but changed nothing visually — because the skeletal mesh hangs off
    the capsule at a **fixed** relative offset set at construction (-65), and it is the real
    player's own crouch logic, which an unpossessed ghost never runs, that adjusts that offset.
  - **Working fix**: compensate the ghost's *render* Z instead —
    `ghost_z = peer_z + (65 - peer_half)`, i.e. +43 while sliding, 0 standing. Applied at the
    receive site alongside the existing loopback offset, since `target_x/y/z` are only ever a local
    render target and never touch the wire. The capsule resize was **removed**, not left in: with Z
    compensation it would leave the collision capsule floating above the floor.
    **Confirmed live: "the ghost is not inside the floor during slides anymore."**
- **Trail tail tightened**: images spawned late in a slide outlive it, so new spawns are cut off
  ~40 ticks into the 87-tick slide (`SLIDE_REFIRE_WINDOW_TICKS`). Overhang went from ~0.5-1s to
  ~0.1-0.3s; user: "it looks perfectly fine now but not 1:1." Left there deliberately — tightening
  further risks visibly truncating the trail, which reads worse than a slightly long tail.
- **Known constant to watch**: the Z compensation assumes a standing capsule half-height of 65.
  That is measured on this build/character and degrades gracefully (no compensation when not
  sliding), but it is an observed constant, not a live-read one.
- Source: `UE4SS.log`, 2026-08-15 session (`TRACE trailCoverage`, `TRACE slideCapsule`,
  `applied CapsuleHalfHeight` readbacks); user's live reports across four test rounds.

## Pseudoregalia: ENEMY damage to a ghost hurts and can KILL the real player — CONFIRMED

- **This is the vector that was flagged as untested when ghost collision was kept on as a feature,
  and it is real.** User-confirmed live: "the ghost taking damage from enemies actually hurt and can
  kill the player."
- **Why this is materially worse than the previously-accepted risk.** The decision to ship collision
  on rested on the judgement that co-op players won't deliberately swing at each other — a fair call
  about *player* behaviour. But enemies attack whatever is in front of them, and a ghost stands in
  the world where enemies fight. So this is not a footgun the player can choose to avoid: a peer's
  ghost drifting into a fight can kill you during normal play, with no visible cause and no input
  from you.
- **Also observed**: the ghost gets stuck in a hurt animation indefinitely after being hit, until
  the peer jumps or falls — which swaps it briefly to the flashing-red damage visual before
  returning to normal idle/walk. Cosmetic next to the death propagation, but same root area.
- **Mechanism detail that explains the intermittency**: the ghost has i-frames for the duration of
  that hurt animation — it cannot be damaged again until it has passed through the red
  "took damage" phase. Since the ghost is stuck in the hurt state until the peer jumps/falls, it is
  accidentally invulnerable for that whole window, which rate-limits the damage rather than letting
  it chain. This does NOT make the feature safe — the first hit still reaches the player — but it
  is why the effect is occasional rather than continuous, and it means a peer standing still near
  enemies is effectively shielded after the first hit.
- **What is already ruled out as the fix**: `bCanBeDamaged = false` (provably applied, did not stop
  it — this game's melee doesn't use UE's standard damage path). See that entry above.
- **FIXED and CONFIRMED LIVE, same session**: change the ghost's collision OBJECT TYPE rather than
  its responses — `SetCollisionObjectType(ECC_WorldDynamic)` on the ghost capsule instead of
  leaving it `ECC_Pawn`. Enemy targeting/hit-detection queries the Pawn channel, so re-typing takes
  the ghost out of their queries entirely. Applied after the existing
  `SetCollisionResponseToChannel(Pawn, Block)` call, since re-typing first would leave that
  response set against a channel the capsule no longer belongs to.
  - **User-confirmed**: "the ghost didn't take any damage and was just able to push enemies around."
    So the run-ending vector is closed AND the physical presence that made the feature worth having
    is intact — the ghost even shoves enemies, which is a strictly better outcome than the
    non-solid alternative.
  - **Remaining, and unchanged**: the player can still deliberately attack their own/a peer's ghost
    and take damage from it. That is the vector already judged an acceptable footgun (a co-op player
    has to choose to swing at a friend), and it is the *controllable* one — unlike enemies, which
    attack whatever is in front of them.
  - **Why this worked where `bCanBeDamaged=false` didn't**: that tried to gate the damage after the
    hit was already registered, through a path this game doesn't use. This instead prevents the hit
    from ever being aimed at the ghost. Generalisable lesson: when a bespoke damage system ignores
    the engine's own damage gate, stop fighting the damage and change what the attacker can *see*.
- **Fallback candidate, user's own idea and a good one**: exploit the i-frames the ghost already
  demonstrably has. The hurt animation grants invulnerability (see the mechanism detail above), and
  the reflection dump found an **`activateGuardFrames`** function (PropertiesSize=0) on the pawn
  plus a `slideIframeWindow` property — so invulnerability is a real, addressable concept in this
  game's own code. If the object-type fix fails, holding the ghost permanently guard-framed would
  block damage propagation regardless of which channel or damage path an attacker uses, which is a
  strictly more general fix than channel juggling.
- **Recommendation recorded at the time**: `GHOST_COLLISION_ENABLED` should default to OFF until
  this is solved. The feature is genuinely fun and worth keeping as an opt-in, but a confirmed
  run-ending failure mode during ordinary play is not something to ship on by default.
- Source: user's own live report, 2026-08-15 session, during a deliberate enemy-damage test.

## Pseudoregalia Dream Breaker THROW animation: root-caused as a montage, FIXED via stock `Montage_Play`, confirmed live

- Date: 2026-08-15
- **The question**: the 2026-08-15 call-order reorder fixed weapon visibility both directions and
  the PICKUP animation, but the user confirmed the THROW motion specifically still didn't play on
  the ghost (see the "animBPref cross-save diff" entry's own follow-up note). Five prior attempts
  had all hunted for the right property or flag.
- **Capture 1 -- why every property hunt was doomed** (`THROW_ANIM_TRACE`, log-on-change so a
  throw's wind-up isn't missed by a sampling cadence): across a clean single-throw session,
  `moveState`/`actionState`/`animJumpType` are **bit-identical before, during and after a real
  throw** (`moveState=0 actionState=0 animJumpType=0` standing; `moveState=1 actionState=0
  animJumpType=1` mid-air, i.e. plain airborne). The only thing that moves is `weaponEquipped?`
  itself. The `actionState=18` blips near some throws last 1-2 ticks and are the already-documented
  slide/turn-around false positive, not the throw. **The throw is an Anim Montage**:
  `/Game/Animations/Player/dreamLady_WeaponThrow_Montage`, ~1.0s, starting on the same tick
  `weaponEquipped?` goes false. Pickup is `dreamLady_WeaponCatch_Montage`, same shape.
  So no property mirror could ever have reproduced it -- the data simply isn't in the state this
  adapter syncs.
- **Mechanism found by reflection dump, not assumed**: `CustomPlayMontage` on
  `BP_PlayerGoatMain_C`, one param `MontageToPlay` (ObjectProperty), PropertiesSize=8 -- sitting
  next to `InpActEvt_IA_Throw_K2Node_EnhancedInputActionEvent_7`, the input event only a real
  controller reaches. (The first capture attempt dumped `/Script/Engine.DefaultPawn` instead --
  the pre-possession placeholder pawn -- and burned its one shot; the dump is now gated on
  `animBPref` resolving. Same bug latched the montage getter off permanently. Both fixed before
  capture 2; **a one-shot diagnostic needs a gate proving the object it wants actually exists yet**.)
- **Capture 2 -- `CustomPlayMontage` on a ghost is a clean NEGATIVE**: called 10 times across 10
  throws, `called=true` every time, asset resolved every time, zero warnings -- and an independent
  readback of the ghost's OWN anim instance showed `playing='none'` on all 12 ticks after every
  call. The game's own wrapper accepts the call and does nothing. Most plausibly the possession
  state the ghost structurally lacks (no `Controller`/`InputComponent`/`PlayerState`), the same
  precondition clause `manageRecallIdleFX` hit. **This readback is the direct fix for that entry's
  own stated weakness** -- it distinguishes "never started" from "started and was killed", which
  that investigation couldn't.
- **Capture 3 -- stock `Montage_Play` on the ghost's `animBPref` WORKS.** One variable changed
  (which function is called; trigger, counter, asset resolution and readback all untouched).
  Signature dumped at the first real call, not assumed: `MontageToPlay` (Object, offset 0),
  `InPlayRate` (Float, 8), `ReturnValueType` (Enum, 12), `InTimeToStartMontageAt` (Float, 16),
  `bStopAllMontages` (Bool, 20), `ReturnValue` (Float, 24). Returned `length=1.000` (the engine's
  own verdict that it started) with the readback showing the correct montage playing on all 12
  subsequent ticks, for both throw and catch. Chosen over more guessing because this file already
  calls `Montage_Stop` successfully on that same object -- montage calls demonstrably reach it.
- **CONFIRMED LIVE, user watched it happen**: "the ghost is doing the throw animation now."
- **What shipped is general, not throw-specific**: the local side sends whatever montage is playing
  (`montage` + monotonic `montage_count` extras, the same pulse shape as `land_count` so a montage
  shorter than the send interval isn't dropped), and the ghost plays that asset. Every
  montage-driven animation this game has rides the same path. Baselined on a peer's first sample so
  a mid-session joiner doesn't replay its last throw at spawn; asset type-checked with a throttled
  warning if a peer's path doesn't resolve locally.
- **Known gap, deliberate**: montage STARTS are mirrored, stops are not -- a montage interrupted
  early on the peer still plays out on the ghost. The existing land/jump `Montage_Stop` pulse
  covers the case that motivated it (ledge-hang) and is NOT superseded by this.
- **Unrelated observation from capture 1, recorded but not acted on**: `weaponRef` read non-null
  for most of the session including while the sword was in hand, and went null once while equipped
  -- which does not match `ideas.md`'s note that it goes non-null specifically while thrown/
  in-flight. Left as-is pending a deliberate look; it bears on the empty-hand recall glow, whose
  blocked precondition is exactly this field.
- Source: `UE4SS.log`, 2026-08-15 16:27/16:35/16:38/16:40 sessions (live install) -- `TRACE
  throwAnim`, `DIAG: ... (throw search)`, `TRACE montage local/ghost`, `DIAG: Montage_Play param`
  lines; user's direct visual confirmation for the fix itself. Code: `Plugin.cpp`'s
  `call_montage_play`, `read_current_active_montage`, the montage block in `tickRenders`, and
  `RemoteGhost::target_montage`.

### Montage mirror covers the whole game; ledge-climb-up lingering root-caused (the ghost restarts montages itself); crouch trail false positive fixed

- Date: 2026-08-15
- **The montage mirror is general, confirmed live across one session**: 51 montage starts -> 49 ghost
  plays, zero refusals (`length` never 0), covering `Attack_GF1`/`GF2`/`GL2`, `Flinch`, `KnockBack`,
  `LedgeGrab`, `PoleToPerch`, `WeaponThrow`/`WeaponCatch`, and sitting (user screenshot: real player
  and ghost in the same sit pose). **No new per-animation code was written for any of these** -- they
  came free with the throw fix, which is the whole point of mirroring the mechanism rather than the
  one animation.
  - **Full vocabulary captured** via `UObjectGlobals::FindAllOf(STR("AnimMontage"))` (signature read
    from the vendored SDK header, `RE-UE4SS deps/first/Unreal/include/Unreal/UObjectGlobals.hpp:244`):
    33 montages loaded, including player ones not yet triggered -- `Guard_Main`,
    `Guard_BlockedHit`, `Guard_CounterF`, `Getup`, `SummonWeapon`, `Channel`, `Sit`, `SitLowHP`,
    `Idle_ThinkMap`. **Loaded objects only** -- an absent montage means "not streamed in", not
    "doesn't exist".
  - **Not montage-driven, established by silence**: ground pound/plunge, slide and wall-ride fired
    no montage at all, so they need the mechanisms they already have, not this path.
  - **2 of 51 starts dropped, benign and understood**: a ledge grab that started and ended within
    ~7ms (inside one sample) sends an incremented counter with an empty name, so the ghost had
    nothing to play. Fix if ever needed: latch the last-started name instead of the currently-playing
    one.
- **Ledge-grab pose lingered on the ghost after a climb-UP (~1.4-1.7s), not after a drop-down. Root
  cause: the ghost re-starts the montage ITSELF.** Two wrong guesses died on the way, both by
  measurement:
  1. *"The stop needs a hard blend."* The stop mirror used a 0.1s blend vs the land/jump pulse's
     0.0f. Changed to 0.0f: **measured as no change at all** (1.34s/1.44s/1.73s before and after).
  2. *"Our Montage_Stop call doesn't work."* Killed by an immediate same-tick readback right after
     the call: it reads `playing='none'` **every time**. The call works.
  - **What the evidence showed instead**: ~0.4s after a confirmed-effective stop, the ghost is
    playing `LedgeGrab_Montage` again with **no `Montage_Play` from this adapter in between** (every
    play is logged; there is none). The ghost restarts it on its own. **Leading explanation, NOT
    proven**: the ghost is a real pawn clone with collision enabled, and its own tick-driven
    ledge detection re-grabs the ledge it was left standing at -- which fits climb-ups being affected
    (ghost left at the lip) and drop-downs not (ghost falls away). Also casts the original
    "ledge-hang stuck forever" bug in a new light: the land/jump pulse may have been masking this
    same behavior rather than fixing it.
  - **Fix, deliberately independent of the unproven half**: a peer-authoritative montage divergence
    correction -- every 4 ticks (~27ms), if the peer is playing no montage and the ghost is, stop the
    ghost's. One-sided by design (only stops, never starts), so it cannot fight the start mirror or
    re-trigger anything. **CONFIRMED LIVE**: "the ledge(up) thing seems to be fixed, its not stuck
    anymore and does the proper animation as well."
- **Crouch trail false positive FIXED** (user-reported: the ghost trailed afterimages while
  crouching). **Both obvious discriminators are useless, measured**: crouch and slide read an
  identical `capsule=22.0` and both set `bIsCrouched=true` -- so tightening `SLIDE_CAPSULE_THRESHOLD`
  would have changed nothing and gating on `bIsCrouched` would have killed the real slide trail.
  `moveState` separates them cleanly (crouch 2, slide 0), across 3 crouches and 5 slides. Written as
  "not the crouch state" so an unrecognised future state keeps its trail. **CONFIRMED LIVE on a
  second save**: crouching clean, sliding still trails.
- **Reusable lesson, bigger than any of these**: when a call on a ghost appears not to work, read
  back the effect *immediately, in the same tick*, before theorising about the call. Here that one
  measurement flipped the diagnosis from "our call is broken" to "something else undoes it" and
  saved a third wrong fix. It is the direct generalisation of the `manageRecallIdleFX` entry's own
  stated weakness.
- Source: `UE4SS.log`, 2026-08-15 sessions 16:53-17:21 (live install) -- `TRACE montage local/ghost`,
  `TRACE animState local/ghost`, `DIAG: montage asset`, `DIAG: Montage_Play param` lines; user's
  direct visual confirmations for all three fixes and the sit screenshot. Code: `Plugin.cpp`'s
  montage divergence correction and stop mirror in `tickRenders`, the crouch exclusion in the trail
  trigger, `RemoteGhost::target_montage_stop_count`.

### `attire-ui-overhaul` re-checked for the ultra/blue trail: NEGATIVE, it knows only one colour

- Date: 2026-08-15
- **Question** (user): does that mod recolour the *blue* perfect-timed ("ultra") hop trail as well as
  the normal one — and could it therefore point at where the blue trail lives?
- **Answer: no.** Name-table strings in `Content/Mods/FoeHammers_AttireUIOverhaul_P/Blueprints/
  LibsAndMacs/DashDataLib.uasset` contain exactly one relevant game property, **`afterimageColor`**,
  alongside `SetDashColour`/`SetDefaultColour`/`SetRandomDashColour`/`OutputColour` — all one
  colour. `Blueprints/UI/UI_DashColourSelector.uasset` is hex entry, randomise and reset
  (`ColourHex_Text`, `ColourRandom_Button`, `ColourReset_Button`). **Neither asset contains any
  string for ultra, perfect timing, a second colour, or blue.**
- **Why this is worth recording**: `afterimageColor` is the same property this project already syncs
  and already proved live does NOT drive the blue trail. So an independent modder building exactly
  this feature found the same single lever — which raises confidence that the blue trail isn't
  reachable through an obvious colour property, and closes this mod as a lead for it.
- Source: the two `.uasset` files above, read as name-table strings only, per `licensing.md`'s
  facts-only posture for this no-license repo (re-confirmed 2026-08-15: `gh api` still reports no
  LICENSE). No asset content copied. Earlier findings from the same mod are in `ideas.md` item 2.

### Ghost self-starts montages: PROVEN, and it is the state sync, not collision

- Date: 2026-08-15
- **The question.** The ledge-climb-up fix that shipped earlier the same day rested on an explicitly
  unproven guess: that the ghost's own *collision-driven ledge detection* re-grabbed the lip. The
  evidence behind it was an argument from absence ("no `Montage_Play` from this adapter appears in
  the log between the stop and the montage reappearing") read off a log while the adapter was still
  making montage calls constantly. `GHOST_SELF_MONTAGE_PROBE` replaces that with subtraction: **all
  four montage call sites in `Plugin.cpp` compiled out** (start mirror, stop mirror, divergence
  correction, land/jump pulse stop), leaving only a read-only poll of the ghost's own anim instance
  logged on change. It has to be all four -- any surviving call leaves a negative ambiguous.
- **Run 1 (collision on) -- the ghost self-starts montages, PROVEN.**
  `PROBE selfmontage ghost p14-ghost tick 2920: ghost now playing 'AnimMontage
  /Game/Animations/Player/dreamLady_LedgeGrab_Montage' (peer target '(none)') -- adapter started
  NOTHING`. Peer playing nothing, adapter physically incapable of having started it. The line never
  changed again (log-on-change), i.e. it stuck. User watched and confirmed the stuck pose.
- **Run 2 (collision off, one variable) -- NOT collision.** Identical self-start
  (`p15-ghost tick 3060`). User's own observation is the sharper half: the ghost **visibly could not
  hang on the ledge** this run and still ended up stuck in the hang pose. The leading explanation
  carried since this morning is therefore **wrong**, and `GHOST_COLLISION_ENABLED` was restored to
  `true` -- the kept feature does not own this bug. *Limit of this run, stated honestly*: disabling
  the actor's collision does not disable traces cast *from* the character, so what is excluded is
  "the ghost is resting on / blocked by the ledge", not "the ghost runs a ledge query".
- **Run 3 (collision on, `ANIM_TRACE` on) -- it is THIS ADAPTER'S STATE SYNC, and it fires on the
  transition OUT of the hang.** The timeline settles it:

  | time | event |
  | --- | --- |
  | 42.792 | `montage local: START #1 'dreamLady_LedgeGrab_Montage'` (real player grabs) |
  | 42.813 | ghost `moveState=3 movementMode=5` -- told "hanging" -- `montage='none'` |
  | 42.814 | `Montage_Play(...) length=-1.000` -- `-1` = call never made (probe), as designed |
  | 42.814-42.889 | readback `t+0`..`t+11`: `playing='none'` -- twelve ticks, nothing started |
  | 47.769 | `montage local: STOP #1` (real player climbs up) |
  | 47.790 | ghost `moveState=1 movementMode=3 animJumpType=6` -- told "hang ended" |
  | 48.193 | ghost `animJumpType 6->0`, `montage='...LedgeGrab_Montage'` -- **self-start, +0.42s** |

  The ghost sat in the synced hang state for a full **5 seconds playing nothing**, then started the
  montage 0.42s after being told the hang *ended*. So the trigger is not the ledge, not collision,
  and not entering the state -- it is this adapter writing `moveState`/`animJumpType` into a real
  pawn clone whose own `ABP_PlayerGoat_C` acts on them.
- **What this means for the design, and it is not a bug in the ghost.** The self-start is the game's
  own animation logic working correctly -- precisely what mirroring state is supposed to buy (see
  the project's "let the game do the work" posture). What a ghost cannot do is **finish** it: the
  montage holds a section that input-driven logic normally advances, and a ghost has no
  Controller/InputComponent, so the pose sticks forever. Same root shape as every other ghost issue
  in this adapter. **Correcting it from outside is therefore the right shape, not a workaround** --
  and specifically, "stop syncing the field that triggers it" would trade a stuck pose for a dead
  one and must not be attempted.
- **The shipped fix survived being wrong about its own cause** because it was deliberately written
  not to depend on the guess ("it corrects the divergence whatever restarted it"). That is the
  reusable lesson: when the mechanism is unproven, write the fix so the proof isn't load-bearing.
- **Gap found by reading, then closed**: the divergence correction only ran when the peer was
  playing *nothing*, so a ghost self-starting the wrong montage *while the peer plays a different
  one* stayed uncorrected until the peer's ended. Widened to "the ghost is playing something other
  than what the peer is playing", re-playing the peer's montage in the same breath. **Candidate for
  the unexplained "ghost returns stuck in a climb pose" pole bug** (a peer on a pole may play a
  climb montage continuously, holding the old check shut) -- NOT confirmed, do not close that item
  on this basis alone.
- Source: `UE4SS.log` (live install), 2026-08-15 17:56 / 17:58 / 18:02 sessions -- `PROBE
  selfmontage` and `TRACE animState`/`TRACE montage` lines; user's direct visual confirmation of the
  stuck pose in all three runs, plus screenshots. Code: `GHOST_SELF_MONTAGE_PROBE` and the montage
  divergence correction in `Plugin.cpp`.

### Every previously-untriggered player montage works on a ghost for free -- 8 of 8

- Date: 2026-08-15
- **The blocked question, and the way around it.** verified.md's vocabulary dump found 33 loaded
  `AnimMontage` assets including nine player ones nobody had ever watched being triggered. The
  ordinary way to test them is blocked: they need whatever local player input fires them, which for
  several may be unreachable in normal play. `MONTAGE_CATALOG_PROBE` asks from the other end --
  play each montage on the ghost DIRECTLY, one every ~4s, and let the user watch. **This needs no
  knowledge of the local trigger at all**, and it answers the actual question ("does this montage
  work on a ghost") instead of a proxy for it. Reusable shape for any "does X work on a ghost"
  question where the natural trigger is out of reach.
- **Resolved by substring against loaded assets, not by a guessed path.** The vocabulary was
  recorded as short labels while the real assets carry prefixes/suffixes, and the full paths were
  never captured -- inventing one would be an address from memory. The probe enumerates what is
  actually loaded, matches case-insensitively, logs the resolved full name, and reports ambiguity or
  non-resolution explicitly. All eight resolved unambiguously; nothing went unresolved.
- **Result: 8 of 8 play on a ghost, all user-watched.** Every one returned a real non-zero length
  (the engine's own verdict that it started) *and* was seen animating:

  | label | resolved asset | length |
  | --- | --- | --- |
  | `WeaponThrow` (control, both rounds) | `dreamLady_WeaponThrow_Montage` | 1.000 |
  | `Guard_Main` | `Attacks/dreamLady_Guard_Main_Montage` | 1.350 |
  | `Getup` | `dreamLady_Getup_Montage` | 2.000 |
  | `SummonWeapon` | `dreamLady_SummonWeaponMontage` | 1.433 |
  | `Channel` | `dreamLady_Channel_Montage` | 1.433 |
  | `Idle_ThinkMap` | `dreamLady_Idle_ThinkMap_Montage` | 2.367 |
  | `Guard_BlockedHit` | `Attacks/dreamLady_Guard_BlockedHit_Montage` | 0.850 |
  | `Guard_CounterF` | `Attacks/dreamLady_Guard_CounterF_Montage` | 0.733 |
  | `SitLowHP` | `dreamLady_SitLowHP_Montage` | 5.000 |

  (`Sit` was excluded as already confirmed live by screenshot, making nine of nine for the player
  montages in the dump.) **No new per-animation code exists for any of them** -- they ride the
  general montage mirror, which is the whole return on mirroring the mechanism rather than the
  animation. User: "all the other things are playing as well."
- **What this does and does not establish.** It establishes that the *ghost side* is not the limit
  for any of these: if a peer plays one, its ghost will too. It does NOT establish that the local
  player ever triggers them -- `Idle_ThinkMap` in particular may be a UI state rather than something
  the character plays, which this probe cannot see. Coverage of the local half stays whatever the
  mirror observes.
- **The control earned its place.** `WeaponThrow` led both rounds precisely so that a round where
  nothing animated would be distinguishable from a broken probe. It animated both times.
- Source: `UE4SS.log` (live install), 2026-08-15 18:08 (round 1) and 18:12 (round 2) sessions,
  `PROBE catalog` lines; user's direct visual confirmation for both rounds. Code:
  `MONTAGE_CATALOG_PROBE` / `find_loaded_montage_by_label` in `Plugin.cpp`.

### Bubble effect is a "Blink" Timeline on the pawn, NOT the afterimage system

- Date: 2026-08-15
- **The wrong turn, and how it was caught.** A bubble-only coverage capture found a clean held state
  (`moveState==7 && movementMode==5`, 2002 ticks, `afterImagesToSpawn==0` throughout) and it was
  wired up as an afterimage trigger. Two separate errors rode along, and **neither was visible in the
  log**:
  1. The state was labelled "post-jump boost-available window". It is actually **inside the
     bubble**. Caught by the user's three-way report (in-bubble trailed / post-jump didn't / boost
     did) -- a held state looks identical either way in a log. See `pitfalls.md`'s methodology entry.
  2. The effect is **not an afterimage at all**. User, looking closely: leaving the bubble there is
     "no trail behind you", the model itself is "pulsating yellow"; and in-bubble the real player is
     "kinda flashing" while the ghost "looks like its a constant yellow colour in comparison". Their
     own conclusion, and the correct one: "we might have tried to applied the after image, where
     something else was supposed to be/play."
- **What found it: a change-detector, not a dump.** A pulsation is by definition an oscillating
  value, so `BUBBLE_FX_DIFF` snapshots the local pawn's simple-typed properties every 4 ticks while
  the effect is on screen and logs **only fields that changed**. 4844 diff lines, and the answer is
  near the top of the histogram:
  - **`Blink_NewTrack_0_<GUID>`** -- a Blueprint **Timeline** track cycling `0 -> 1 -> 2 -> 0`.
    65 changes in-bubble, 1 post-jump. A track literally named *Blink*, cycling in ~31 ticks with
    gaps of ~200-700 between cycles, matching "kinda flashing" exactly.
  - `Timeline_5_NewTrack_0_<GUID>` -- a smooth `0 -> 1` ramp running alongside it.
  - Everything else that moved is ordinary movement state (`moveStateUptime`, `verticalSpeed`,
    `moveInputAmount`, ...).
- **Why this matters more than the specific field**: the afterimage investigation hit a real
  ceiling (a second spawn path reachable only through a Blueprint UFunction hook that crashes the
  game). **This effect has no such ceiling** -- its driver is a plain readable property on the pawn,
  the same category as every mirror this adapter already ships. It was only unreachable while it was
  being mistaken for an afterimage.
- **Measured duration kills the tuning approach**: `Blink` ran **9406 ticks in a single bubble
  visit** (~52s at this build's ~180Hz), against a 900-tick guessed window. The user watched the
  ghost drop its effect early twice, counting ~16s of real effect still to come each time. Raising
  the constant would fix the duration and leave the visual wrong -- spawned afterimages read as
  constant yellow where the real thing flashes.
- **Tick rate correction, affects other entries**: this build measures **~180Hz**, from two
  independent timestamp/tick pairs (448 ticks in 2.473s; 3001 in 16.495s). Earlier entries quote
  ~150Hz, which makes every tick-based duration in this adapter read ~20% long.
- **Shipped state, deliberately provisional**: trigger C (in-bubble afterimage) stays at its
  visibly-short 900-tick window, and trigger D (post-jump) is **disabled** -- it added a trail the
  real player provably does not have, which is the crouch-trail false positive again, and that one
  is precedent for removing rather than tuning. D's window logic is kept intact because it correctly
  models a real rule the user described ("you keep it if it didn't go away inside of the bubble") and
  is what a Blink mirror will need.
- Source: `UE4SS.log` (live install), 2026-08-15 sessions -- `TRACE trailCoverage`, `TRACE
  trailTrigger`, `DIFF bubbleFX` lines; user's live visual reports throughout, including the
  observation that reframed the whole investigation. Code: `snapshot_object_values`,
  `log_value_snapshot_diff`, `BUBBLE_FX_DIFF`, and triggers C/D in `Plugin.cpp`.

### Bubble flash mirror WORKS — and a correction to the entry above it

- Date: 2026-08-15
- **CORRECTION to "Bubble effect is a 'Blink' Timeline on the pawn".** That entry named
  `Blink_NewTrack_0_<GUID>` as the pulsation's driver. **That is wrong, and this entry supersedes
  it** (this file is append-only, so the error stays visible rather than being edited away). A
  filtered function dump showed `startBlink` is built from `RandomFloatInRange` +
  `K2_SetTimerDelegate` — a random-interval timer, i.e. **idle eye-blinking**, which also explains
  the irregular 200-700 tick gaps that were noted at the time and not questioned. The change-detector
  was right that something oscillated; naming which effect it belonged to was the same
  signature-attached-to-the-wrong-event mistake `pitfalls.md` already records from earlier the same
  day, made a second time in the same investigation.
- **What actually drives it, and how it was found.** Asking the CLASS what its API is called --
  the step that produced `Montage_Play` and with it the whole montage mirror -- found named
  functions on `BP_PlayerGoatMain_C`:
  `StartBubbleJumpFlash(Condition: bool)`, `changeBubbleChargedJump(hasBubbleChargedJump: bool)`,
  `EventEnterBubble`, `startBubbleMode(reference)`, `bubble Exit Jump`, `flash(justWeapon?: bool)`.
  Named for exactly the effect and exactly the state, instead of anything this adapter had to infer.
- **Then the flag, not a third window.** Driving the ghost off the peer's in-bubble state fixed two
  of three cases but dropped the effect the instant the peer jumped out. The real rule (user): "you
  keep it if it didn't go away inside of the bubble", until the boost or a landing. Rather than a
  third guessed duration -- two had already failed -- the `changeBubbleChargedJump` parameter name
  implied a readable variable, and a search over the pawn's bool properties found exactly
  **`hasBubbleChargedJump`**. Mirrored across the wire (`bubble_charged`), OR'd with the in-bubble
  state so an older peer keeps working. **How long the effect lasts is the game's business, not
  this adapter's** -- that is the whole lesson of the two failed windows.
- **CONFIRMED LIVE, all three cases including a negative control** (user: "all 3 worked as
  intended/matched what happened to the player"):
  1. jump out while flashing, land without boosting -- ghost keeps flashing, stops on landing;
  2. jump out while flashing, use the boost -- ghost stops at the boost;
  3. wait for it to expire inside, then jump out -- ghost correctly shows **nothing**.
  Case 3 is the one that matters: cases 1 and 2 can only confirm, while 3 is the only one that could
  have caught a mirror that simply always flashes on leaving a bubble.
- **Durations measured, not eyeballed.** Logging the LOCAL flag's edges alongside the ghost's turned
  "does it last as long" into arithmetic: **2.36s/2.36s, 1.32s/1.31s, 22.59s/22.58s**, with the ghost
  trailing by 14-28ms — the pipeline's own interpolation delay, nothing more.
- **The superseded code was DELETED, not left disabled**: both afterimage triggers are gone. A
  wrong-looking effect is not a useful fallback for a correct one, and the history lives here and in
  `pitfalls.md` rather than in dead code.
- Source: `UE4SS.log` (live install), 2026-08-15 sessions -- `DIAG blinkSearch`, `DIAG bubbleFlag`,
  `BUBBLE local`, `BUBBLE ghost` lines; user's direct visual confirmation of all three cases. Code:
  `call_bool_ufunction` and the bubble flash mirror in `Plugin.cpp`.

### Pseudoregalia pole ROTATION syncs exactly — the apparent bug is a loopback artifact

- Date: 2026-08-15
- User report: climbing a pole up/down syncs, but spinning around it left/right leaves the ghost
  looking unrotated. Reading the code first ruled out the obvious: pitch/yaw/roll are already sent
  (`orientation`) and applied via `call_set_actor_location_and_rotation`, so nothing was missing
  from the wire.
- **Both hypotheses were wrong, and the measurement says the pipeline is fine.** Local `actorYaw`
  moves smoothly through a spin (12.7 -> 25.2 over 29 ticks) while `visualMeshYaw` stays pinned at
  **-90.0** throughout, so the spin IS actor rotation and not the mesh-relative rotation this game
  uses for facing elsewhere. And across **2469 ghost samples, `actualYaw` matched `wantYaw` to the
  decimal over the full -179.9..179.7 range -- zero mismatches beyond 5 degrees**, read back
  independently from the world rather than echoed from what was written.
- **The likely explanation is the loopback offset, and the agent had dismissed it wrongly.** The
  user suggested it early ("might be due to the offset maybe?") and was told it shouldn't matter
  because the ghost would still visibly swing around an empty axis. **Orbiting a pole is rotation
  about the POLE'S axis** -- a ghost displaced 150 units sideways orbits a phantom axis 150 units
  away, performing the motion faithfully while visibly not going around the pole. Still
  UNCONFIRMED visually.
- **A vertical (Z) offset was tried to put the ghost on the same axis, and failed for a reason worth
  recording**: a pole is a vertical structure, so offsetting along its own axis put the ghost far up
  the same pole -- "i couldn't see the ghost at all while on the pole". The idea is right for a
  HORIZONTAL orbit and wrong for this one; `LOOPBACK_GHOST_OFFSET_Z` is kept at 0.0.
- **Consequence: this is a loopback-can't-answer item**, the same category as ghost collision — a
  real second player stands on the pole rather than beside it. Do not spend more diagnostics on the
  transform pipeline; it is proven correct.
- **Later the same day, a sharper user report closed the question: "sometimes it works, sometimes
  i don't see the ghost, and sometimes i see it on another pole than mine."** All three are the
  sideways offset, and "another pole" is the tell that settles it. The offset is applied as a
  fixed **world-X** render target (`target_x = x + loopback_offset_x`, `target_y = y` --
  `Plugin.cpp`'s `handle_bridge_line`), not relative to facing, and the adapter re-sets the
  ghost's location every tick, so nothing can snap it to anything: where poles are spaced along
  world X, 150 units simply lines the ghost up with the NEXT pole while you climb yours. Poles
  sit against structures, so the same nudge puts it inside adjacent geometry (invisible), and in
  open space it looks fine -- hence the intermittency, which is level geometry, not timing.
- **Consequently this is not a bug and was deliberately left unchanged (user's call, 2026-08-15).**
  With a real second player, "the ghost is on a different pole" is the CORRECT rendering -- they
  really are on a different pole. The offset stays at 150.0 because judging rendering quality
  side by side is worth more than making poles legible in loopback, which they can't be anyway.
  `LOOPBACK_GHOST_OFFSET_X = 0.0` remains the one-variable isolation step if a genuine pole bug
  is ever suspected again (ghost sits exactly on you, so it must share your pole) -- but note it
  reproduces the drag/pull collision case, per that constant's own comment.
- Source: `UE4SS.log` (live install), 2026-08-15 -- `POLE local` / `POLE ghost` lines (7011 local,
  2469 ghost). Code: `POLE_ROTATION_TRACE` in `Plugin.cpp`; the offset itself is
  `LOOPBACK_GHOST_OFFSET_X` and its use site in `handle_bridge_line`.

### Release-folder loopback script works with a real game attached

- Date: 2026-08-15
- Observed: user copied `dev-scripts/run-loopback-in-release-folder.bat` into an unzipped
  release folder, ran it instead of `meshghost-server.exe`, then started `meshghost.exe` and
  loaded the Pseudoregalia UE4SS mod. The relay window showed the script's own banner,
  `-loopback enabled`, `room send rate: 20Hz`, and `relay: p1 ("player") joined room "default"
  as game "pseudoregalia"`; the client window showed `connected to relay 127.0.0.1:7777 as p1`.
  On screen: a ghost of the player standing a short distance to the side of the real character,
  not overlapping it. Screenshot supplied by the user.
- Source: `dev-scripts/run-loopback-in-release-folder.bat`; the relay's `-loopback` flag
  (`Server.Loopback` in `internal/relay/relay.go`); the side offset is
  `LOOPBACK_GHOST_OFFSET_X` in Pseudoregalia's `Mod/src/Plugin.cpp`.
- Notes: scope is **Pseudoregalia in a release-layout folder** (relay named
  `meshghost-server.exe`, sitting beside the script) — says nothing about Emerald or TEVI, and
  TEVI's loopback ghost offset remains an open question with no such constant found in its
  source. **The ghost moved visibly less smoothly than under the dev loopback, and that is
  correct, not a regression**: this script deliberately omits the dev scripts' `-send-hz=100`,
  so the relay ran at the release `config.json`'s own `send_hz` (20Hz above) instead. The user
  confirmed this is the intended way to use it — smoothing/rate is tuned in `config.json`, the
  same knob a real session uses. Don't "fix" that difference by adding `-send-hz` back to the
  script; see `dev-scripts/README.md`'s entry for the full reasoning.

### Pseudoregalia thrown Dream Breaker: full hand → flight → bounce → ground sync, CONFIRMED LIVE

- Date: 2026-08-15
- Closes `ideas.md`'s Pseudoregalia idea 0 at its **full** scope (continuous flight sync), not the
  MVP cut point it also described. The user watched flight, wall bounces, the resting sword and its
  glow ring on a ghost.
- **The thrown sword is a separate actor**, `/Game/ThirdPerson/Player/BP_looseWeapon.BP_looseWeapon_C`,
  freshly spawned per throw. The pawn's `weaponRef` points at it.
- **The two prior contradictory notes on `weaponRef` are both explained and now resolved.** It does
  NOT go null on pickup — the game parks the picked-up weapon at world origin and leaves `weaponRef`
  pointing at it. So "in hand" reads as a transform of `(0,0,0)`, and `ideas.md`'s "non-null only
  while thrown" was wrong while the throw-animation entry's "non-null while in hand" was right.
  Thrown is derived from three things together: actor exists, `weaponEquipped?` false, and the
  transform is not at origin.
- **Flight needs no physics reproduction.** A throw is a ~2s ballistic arc sampled at ~150Hz;
  position + rotation replayed on a copy reproduces bounces too, since the peer's own
  `ProjectileMovementComponent` already resolved them. Smoothing is exponential (25%/frame) with a
  400-unit snap, because `extras` is never interpolated by the core (`internal/core/interp.go`).
- **Resting pose = `weaponState`, measured 0 → 3 on touchdown, identical across five throws.**
  `isEmbedded?` never changes and the mesh's `RelativeLocation` is bit-identical in flight and at
  rest — so this was NOT the slide floor-sinking bug's mesh-offset shape, despite looking like it.
  Driven on the ghost by the class's own `Change Weapon State` (one byte, parameter resolved by
  reflection as `weaponState`), called BEFORE the raw property write per the Dream Breaker
  visibility fix's ordering lesson.
- **The "sinking while embedded" bug was gravity, and two fixes failed before it was measured.**
  A mesh-offset theory and `SetSimulatePhysics(false)` both failed with the identical symptom. Root
  cause: the diagnostic itself was reading the position back *immediately after our own write*,
  which proves the write landed but structurally cannot see drift applied between frames. Reading
  it BEFORE each write showed the actor sitting further below the previous frame's written value
  every sample (−7.5, −8.6 … −13.1 units, growing linearly ≈ 850 units/s²). The prop's own
  `ProjectileMovementComponent` integrates velocity, which is why disabling *physics simulation*
  changed nothing. Fixed by `Deactivate` on that component plus zeroing its `Velocity` and
  `ProjectileGravityScale`.
- **Cross-throw accumulation fixed separately** by destroying the prop on pickup (`K2_DestroyActor`,
  real on this class) and spawning a fresh one per throw, matching what the game itself does.
- **The glow ring is a `NiagaraComponent` running `/Game/VFX/Emitters/NS_WeaponIdle`**, created by
  the real sword on landing. `Change Weapon State` provably does NOT create it (our prop's
  `idleGlowVFX` stayed null across every state call), and `checkForValidLandingPoint` is
  flight-path prediction whose entire parameter list is Blueprint compiler temporaries and which
  line-traces against collision the prop deliberately lacks. With no in-game trigger left to
  borrow, it is spawned directly via `NiagaraFunctionLibrary:SpawnSystemAttached`, with the asset
  path read live off the peer's `idleGlowVFX.Asset` rather than hardcoded.
- **Collision is disabled on the prop and that is required, not cautious**: `BP_looseWeapon_C`
  carries a `PlayerPickup` box, so a collidable copy would let the local player pick up a peer's
  phantom sword — a game-state effect, outside this project's visual-only posture.
- **Caution recorded**: the stock engine bool block in this actor's property dump is unreliable —
  `bHidden`, `bActorIsBeingDestroyed` and `bIsEditorOnlyActor` all read `true` on a live, working
  actor in a shipping build. UE packs them into a bitfield and the byte-wide read returns true for
  any non-zero byte. Blueprint-defined bools (`isEmbedded?`, `hasLight?`) are separate properties
  and read correctly.
- **Not judgeable in loopback**: a sword thrown at the save crystal behaves oddly, which is
  expected — the ghost is offset 150 units sideways, so its arc is computed against geometry that
  isn't where the ghost is. Same artifact already recorded for pole climbing; needs a real second
  player.
- Source: `UE4SS.log` 2026-08-15 sessions (`WEAPONACTOR`, `WEAPONLAND`, `WEAPONPROP` traces, the
  thrown-weapon and `idleGlowVFX` dumps); user's direct visual confirmation for every visible
  claim. Code: `Plugin.cpp`'s `tick_remote_weapon`, `call_change_weapon_state`,
  `stop_projectile_movement`, `spawn_niagara_attached`, and `RemoteGhost::weapon_actor`.

### Pseudoregalia: a ghost's thrown sword cannot be picked up by the local player

- Date: 2026-08-16
- **Confirmed on screen by the user**, deliberately tested rather than assumed: walking into a
  ghost's thrown sword — in flight and resting on the ground — does nothing. The local player does
  not pick it up and their own weapon state is unaffected.
- Why this needed checking rather than reasoning: `BP_looseWeapon_C` carries a real `PlayerPickup`
  BoxComponent (its own property dump), so a collidable copy would have handed the local player a
  peer's phantom sword — a game-state effect, outside this project's visual-only posture and a
  genuinely different class of bug from a cosmetic one.
- Mechanism: `SetActorEnableCollision(false)` on the prop at spawn (`tick_remote_weapon`). Note
  this is the opposite choice from the ghost PAWN, whose collision is deliberately ON as a feature
  (`GHOST_COLLISION_ENABLED`) — there is no version of the weapon prop that should ever be
  touchable.
- Standing caution: this is a property of the *current* code, not a guarantee. Any future change
  that spawns or re-parents this prop must re-verify it, since the failure is silent and only
  visible by trying to walk into one.

### Pseudoregalia empty-hand recall glow: FIXED by spawning the effect directly, confirmed live

- Date: 2026-08-16
- Closes a gap `status.md` had carried as blocked, and the original diagnosis was subtly wrong in a
  way worth recording. It was recorded as blocked on a *precondition*: `manageRecallIdleFX` returned
  cleanly on a ghost while spawning nothing, and the leading theory was that its internal `IsValid`
  guards wanted a real thrown-weapon actor the ghost didn't have. The thrown-Dream-Breaker work
  provided exactly that actor — and it was never needed. Spawning the effect directly requires no
  guards to pass at all.
- **Found by enumeration, not by guessing a name.** A catalog probe cycled every loaded Niagara
  system onto a ghost, ~3s each; the user identified `/Game/VFX/Emitters/NS_WeaponCallReady` on
  screen as the empty-hand glow. 58 systems in the full catalog, narrowed to 10 by a name filter
  after the user reported that tracking 58 mostly-level-dressing effects was the real obstacle.
- Gated on the already-synced `weaponEquipped?`, so it needs no new data on the wire. Asset is a
  constant here (unlike the landed sword's ring, which reads its path off the peer) because there
  is nothing to read it from: the real player's copy is spawned into the world rather than parented
  to the pawn, established by a watcher run that found exactly one Niagara component on the pawn
  across a whole session.
- **Known-imperfect, user-reported after the live test**: the glow's position on the ghost is
  visibly off. It is attached to the ghost's root because nothing had yet said where the real one
  attaches — the first watcher logged identity only, not attachment. Being fixed by capturing
  `AttachParent`/`AttachSocketName`/`RelativeLocation` on appearance rather than by adjusting an
  offset by eye.
- **Still open, and deliberately not guessed at**: a second "sword outline" glow the user can see
  has not been located in any Niagara enumeration. The search now also covers Cascade
  (`ParticleSystemComponent`), since every pass until now silently assumed Niagara purely because
  the sword's ring happened to be Niagara. If it is in neither, it is likely a material property
  rather than a particle effect, which is a different search.
- Source: `UE4SS.log` 2026-08-15/16 (`VFXPROBE` catalog and cycle lines, `VFXWATCH`), user's direct
  visual confirmation. Code: `Plugin.cpp`'s `tick_remote_recall_glow`, `spawn_niagara_attached`.

### Pseudoregalia: use-after-free crash on level transition after a throw, FIXED and confirmed live

- Date: 2026-08-16
- **Introduced by the thrown-weapon feature earlier the same day**, not pre-existing. Distinct from
  the `Fatal Error!`-on-game-exit entry in `status.md`, which was seen once, has a different
  trigger, and remains un-root-caused — do not treat this fix as closing that one.
- **Symptom**: `EXCEPTION_ACCESS_VIOLATION` returning to the main menu after throwing the sword.
  Stack: `game_thread_tick` → `handle_bridge_line` → `release_ghost` →
  `call_set_actor_location_and_rotation`.
- **Cause**: the level tore down and destroyed our thrown-weapon prop while MeshGhost kept a raw
  pointer to it; a `despawn_remote` arriving after the transition then moved freed memory. The
  ghost pawn was immune only because `release_all_ghosts` (LoadMap PRE hook, before teardown)
  nulls *its* pointer — the prop, added later, never got the same treatment. A second, smaller
  mistake compounded it: that path still parked the prop, left over from before props became
  per-throw destroyed.
- **Fix**: every actor-shaped field on every remote is now cleared at the top of
  `release_all_ghosts`, before its "no ghost, skip" continue; `release_ghost` destroys rather than
  moves the prop. `release_all_ghosts` deliberately drops references without calling into any
  actor.
- **CONFIRMED LIVE by the user, both transition paths**: returning to the main menu after a throw,
  and moving to a different zone after a throw. Neither crashes.
- Recorded in `pitfalls.md` with the generalizable form, including why a liveness check would not
  have helped (`IsUnreachable()` is only meaningful on an object that is still allocated).

### Pseudoregalia thrown Dream Breaker: full hand → flight → bounce → ground → pickup, CONFIRMED LIVE

- Date: 2026-08-15/16
- Closes `ideas.md`'s Pseudoregalia idea 0 at its **full** scope (continuous flight sync), not the
  MVP cut point that entry also offered. User watched flight, wall bounces, the resting sword, its
  glow ring, and pickup.
- **The thrown sword is a separate actor**, `/Game/ThirdPerson/Player/BP_looseWeapon.BP_looseWeapon_C`,
  freshly spawned per throw, referenced by the pawn's `weaponRef`.
- **Resolves two contradictory prior notes about `weaponRef`.** It does NOT go null on pickup — the
  game parks a picked-up weapon at world origin and leaves the reference pointing at it. So "in
  hand" reads as a transform of `(0,0,0)`, and `ideas.md`'s "non-null only while thrown" was wrong
  while the throw-animation entry's "non-null while in hand" was right. Thrown is derived from
  three things together: actor exists, `weaponEquipped?` false, transform not at origin.
- **Flight needs no physics reproduction**: replaying position + rotation reproduces wall bounces
  too, because the peer's own `ProjectileMovementComponent` already resolved them.
- **Resting pose is `weaponState`**, measured 0 → 3 on touchdown, identical across five throws.
  `isEmbedded?` never changes and the mesh's `RelativeLocation` is bit-identical in flight and at
  rest — so this was NOT the slide floor-sinking bug's shape despite looking like it. Applied via
  the class's own `Change Weapon State`, called before the raw property write.
- **The "sinking while embedded" bug was gravity**, from the prop's own
  `ProjectileMovementComponent` integrating velocity — which is why `SetSimulatePhysics(false)`
  changed nothing. Two fixes failed first because the diagnostic read the position back
  *immediately after our own write*, which proves the write landed but cannot see drift applied
  between frames. Reading it BEFORE the write showed ~850 units/s². Fixed with `Deactivate` on that
  component plus zeroing `Velocity`/`ProjectileGravityScale`.
- **Collision is disabled on the prop, and the user confirmed on screen that the local player
  cannot pick up a ghost's sword** — required, not cautious: `BP_looseWeapon_C` carries a real
  `PlayerPickup` box. Note this is the opposite choice from the ghost PAWN, whose collision is
  deliberately ON as a feature.
- **Caution**: the stock engine bool block in this actor's dump is unreliable — `bHidden`,
  `bActorIsBeingDestroyed` and `bIsEditorOnlyActor` all read `true` on a live, working actor in a
  shipping build (UE bitfield packing vs a byte-wide read). Blueprint-defined bools
  (`isEmbedded?`, `hasLight?`) read correctly.
- Source: `UE4SS.log` 2026-08-15/16 (`WEAPONACTOR`, `WEAPONLAND`, `WEAPONPROP` traces and the
  thrown-weapon dumps); user's direct visual confirmation for every visible claim. Code:
  `Plugin.cpp`'s `tick_remote_weapon`, `call_change_weapon_state`, `stop_projectile_movement`.

### Pseudoregalia empty-hand recall glow: FIXED by spawning the effect directly, confirmed live

- Date: 2026-08-16
- Closes a gap `status.md` had carried as blocked, and **the original diagnosis was wrong in an
  instructive way**. It was recorded as blocked on a precondition: `manageRecallIdleFX` returned
  cleanly while spawning nothing, and the theory was that its `IsValid` guards wanted a real
  thrown-weapon actor. The thrown-weapon work provided exactly that — and it was never needed.
  Spawning the effect directly requires no guards to pass at all.
- **Found by enumeration, not by guessing a name**: a catalog probe cycled every loaded Niagara
  system onto a ghost ~3s each; the user identified `/Game/VFX/Emitters/NS_WeaponCallReady` on
  screen. 58 systems in the full catalog, narrowed to 10 by a name filter after the user reported
  that tracking 58 mostly-level-dressing effects was the real obstacle.
- **Placement measured, not adjusted by eye**: the real effect attaches to the pawn's `WeaponMesh`
  at zero offset — i.e. exactly where the sword is held, which is why the user perceived it as an
  outline of the sword. A first attempt attached it to the actor root and sat visibly wrong.
- **The trigger is mirrored, not reimplemented.** The real glow only appears near a save crystal
  (the sword can only be summoned there), which nobody had guessed. Rather than encode that rule,
  the local side reports whether the real effect is currently *present* and the ghost mirrors that,
  so the crystal rule and any other unnoticed condition come along for free. The presence test
  checks `IsActive()` rather than mere existence — a Niagara component with `bAutoDestroy` off is
  deactivated and kept, so an existence test never goes false again.
- **Built but NOT verifiable in loopback**: a ghost constructs itself from the LOCAL save, so it can
  spawn already glowing. A sweep clears any self-constructed glow at spawn. In loopback the peer is
  the local player, so "shows the peer's state, not yours" cannot be distinguished — this joins the
  Phase 7.7 list.
- Source: `UE4SS.log` 2026-08-16 (`VFXPROBE` catalog/cycle, `VFXWATCH` with attachment data,
  `RECALLGLOW` edges); user's visual confirmation of the glow appearing and clearing at a crystal.

### Pseudoregalia: use-after-free crash on level transition after a throw, FIXED and confirmed live

- Date: 2026-08-16
- **Introduced by the thrown-weapon feature the same day**, not pre-existing. Distinct from the
  `Fatal Error!`-on-game-exit entry in `status.md`, which has a different trigger and remains
  un-root-caused — this does not close that one.
- **Symptom**: `EXCEPTION_ACCESS_VIOLATION` returning to the main menu after throwing. Stack:
  `game_thread_tick` → `handle_bridge_line` → `release_ghost` →
  `call_set_actor_location_and_rotation`.
- **Cause**: the level tore down and destroyed the prop while MeshGhost kept a raw pointer; a
  `despawn_remote` arriving afterwards moved freed memory. The ghost pawn was immune only because
  `release_all_ghosts` (LoadMap PRE hook, before teardown) nulls *its* pointer — the prop, added
  later, never got the same treatment. A liveness check would not have helped: `IsUnreachable()` is
  only meaningful on a still-allocated object.
- **Fix**: clear every actor-shaped field for every remote at the top of `release_all_ghosts`,
  before its "no ghost, skip" continue; destroy rather than move the prop elsewhere.
- **CONFIRMED LIVE by the user on both transition paths**: main menu after a throw, and a zone
  change after a throw. Neither crashes.

### Pseudoregalia ultra-hop BLUE trail: source identified after being parked as unsolvable

- Date: 2026-08-16
- Un-parks `status.md`'s "not derivable from polled state; do not resume by guessing more property
  names" entry — resumed without guessing any property names.
- **What unlocked it**: the VFX catalog holds 58 game Niagara systems and none is an afterimage, so
  the trail was never a particle effect and every colour guess had been aimed at the wrong kind of
  object. Diffing the world around a deliberate `Spawn After Image` call on a ghost identified it:
  an afterimage is a **`BP_AfterImage_C` actor carrying a `PoseableMeshComponent`** — a posed mesh
  snapshot.
- **The blue**: `BP_AfterImage_C` has its own `Color` (a StructProperty, which is why this project's
  value dumper had always skipped it). Measured live: ordinary images `(1.000, 0.888, 0.260)`, ultra
  images `(0.000, 0.787, 1.000)`. The pawn's `afterimageColor` genuinely never changes during an
  ultra — that earlier finding was correct; it was simply the wrong object.
- **Reproduced on a ghost** (blue written, ghost's own image read back blue, user saw blue), then
  **switched off again**: the code that read the colour rode on a per-tick enumeration that broke
  the trail (see `pitfalls.md`, "The diagnostics were the bug"). The cheap way to re-enable it is
  recorded in `status.md` — compare `cachedMesh` by pointer rather than by name.
- Source: `UE4SS.log` 2026-08-16 (`AFTERIMAGE`, `AFTERIMAGECOLOR`, `TRAILCOLOR` captures) plus the
  `BP_AfterImage_C` schema dump.

### Pseudoregalia afterimage trail regression: caused by this project's own diagnostics, FIXED

- Date: 2026-08-16
- **The worst regression the project has had, and the first to require comparing commits.** Full
  incident and the transferable rules are in `pitfalls.md`, "The diagnostics were the bug"; this
  entry records the confirmed facts only.
- **Symptom**: the ghost's slide trail went intermittently sparse or absent.
- **Cause**: two probes left enabled while judging the trail — one that *spawned* an afterimage onto
  the ghost every ~3s, and a ~50Hz enumeration doing a `GetFullName()`/UTF-8 conversion and property
  lookups per object on the game thread. The game spawns afterimages as a countdown across ticks,
  so stalling that thread truncated real bursts.
- **Why four measurement rounds missed it**: every metric (count, spacing, position in X and Z,
  opacity, fade curve, colour) reported exact parity, because every image that survived WAS correct
  and only the destroyed ones were missing.
- **Located by bisecting real commits**, after a flag-flip A/B had produced the wrong conclusion:
  `8d10f67` good → `46c4d2c` good → `760b148` intermittent → `861e6cd` broken. Three builds.
- **Fix** (commit `83f30c1`): heavy tracing off, scan cadence 3 → 15 ticks, and the scan gated by
  the flag that owns it so that flag is a real off-switch.
- **CONFIRMED LIVE by the user**: dense repeating slide trail restored, ghost within 1-2 images of
  the real player. Known cosmetic remainder: 1-2 extra images at the tail of a slide
  (`SLIDE_REFIRE_WINDOW_TICKS`, recorded in `status.md`).

### Pseudoregalia colour-only afterimage observation does NOT regress the slide trail

- Date: 2026-08-16
- Re-enables the ultra-blue colour read that was switched off as collateral when the scan it rode on
  was found to be breaking the trail (see the two entries above). Split into its own flag,
  `AFTERIMAGE_OBSERVE_COLOR`, independent of `AFTERIMAGE_TRIGGER_OBSERVED`, which stays off.
- **What changed, and why it should be cheap**: the scan runs once per burst rather than on a fixed
  cadence, so it costs nothing while the player is not trailing; ownership of an afterimage is a
  single pointer compare (`cachedMesh`'s Outer against the pawn) instead of a `GetFullName()`/UTF-8
  conversion and substring search per object per scan, which was half of the original cost; and
  per-object tracing stays off. The wire event is emitted 4 ticks after the burst so the counter and
  the colour are written together and describe one burst.
- **CONFIRMED LIVE by the user**: normal slides only — trail looks correct, no sparseness or
  drop-out. This is the regression check for the change, i.e. the risk that re-enabling any
  per-object scan would repeat the 2026-08-16 incident.
- **What this specifically does NOT establish**: that the blue works. A normal slide's colour IS the
  pawn baseline, so "the colour path observed it correctly" and "the colour path read nothing and
  fell through to the baseline" produce an identical picture. Only a perfect-timing ultra hop
  separates them, and that has not been watched yet. The `AFTERIMAGE_COLOR:` log lines (bounded to
  5 per session) carry the `ours=`/`new=` counts that would settle it from the log side.

### Pseudoregalia ultra-hop BLUE reaches the ghost — but attributed one burst late

- Date: 2026-08-16
- **CONFIRMED LIVE by the user**: after performing an ultra hop, the ghost's trail did go blue — on
  the first afterimage of the *next slide*, not on the ultra hop itself.
- **What this establishes, which is most of the feature**: the entire colour pipeline works
  end-to-end. The blue is detected off `BP_AfterImage_C`'s own `Color`, survives the tie-break, is
  latched, crosses the wire, is written to the ghost's pawn before its burst, and renders visibly
  blue on the ghost. None of those stages is in doubt any more.
- **What is wrong is attribution, not colour**: a burst spawns its images over many ticks, and the
  first implementation scanned once, 4 ticks after the trigger. The log showed `new=1` against
  `n=5`, so a single scan saw only the leading image. Every image appearing after that scan was
  still unknown at the next burst's scan, and a first sighting is indistinguishable from a fresh
  spawn — so the ultra's later blue images were counted as new by the following slide and won its
  tie-break. The blue was therefore always one burst behind.
- **Fix**: observe across a window (`AFTERIMAGE_COLOR_OBSERVE_WINDOW_TICKS`, scans strided by
  `AFTERIMAGE_COLOR_OBSERVE_STRIDE_TICKS`) instead of at one instant, accumulate the tie-break over
  the whole burst, and emit the wire event when the burst's full count has been seen or the window
  expires. Per-burst accumulators reset at burst start so one burst's colour cannot carry into the
  next. NOT yet re-watched.
- Source: user's live report, plus `UE4SS.log` 2026-08-16 `AFTERIMAGE_COLOR` lines
  (`found=`/`ours=`/`new=` across five bursts).

### Pseudoregalia ultra hop fires NO local afterimage trigger — the real cause of the late blue

- Date: 2026-08-16
- **Root cause of "the blue appears on the slide after the ultra, not during it"**, replacing the
  earlier window-sizing theory, which was wrong.
- **Evidence, identical across both ultras in one capture**: `AFTERIMAGE_SPECIAL: off=4 new=4
  newTotal=4 scan=(0.000, 0.787, 1.000)` — the blue found on the FIRST scan of a burst, with four
  images at once, against `new=1` for a genuinely fresh burst. The surrounding `AFTERIMAGE_BURST`
  lines sit 12 ticks apart, i.e. slide re-fires. Four-at-once on a first scan is a backlog being
  discovered, not a burst spawning.
- **Therefore**: the ultra's afterimages are already spawned and unseen before the slide begins. No
  `burst_edge` fires during an ultra, so no observation window ever opens for it, and the images are
  first sighted by the following slide's opening scan — exactly when the ghost turns blue.
- **Confirms the "REMAINING GAP" already recorded here**: some afterimages come from a path that
  never touches `afterImagesToSpawn`, and the ultra hop is that path. Also confirms the old code
  comment that an ultra "produced NO ghost trail at all", which had been read as self-contradictory.
- **Not fixable by window tuning**, and identifying the ultra by state is a closed dead end
  (`ultraCap`, `fullUltraModifier`, `cappedUltraModifier`, `animJumpType` all ruled out live).
- **Fix built, NOT yet watched**: `AFTERIMAGE_OBSERVE_SPECIAL_TRIGGER` — a coarse idle scan
  (`AFTERIMAGE_IDLE_SCAN_INTERVAL_TICKS`, only while no burst is pending) that emits a burst when it
  finds new images the game coloured differently from its own baseline. Restricted to a divergent
  colour so ordinary gold stragglers cannot double-trail. Additive: it fires only where the existing
  trigger found nothing, unlike the reverted `AFTERIMAGE_TRIGGER_OBSERVED`.
- Source: `UE4SS.log` 2026-08-16, `AFTERIMAGE_SPECIAL`/`AFTERIMAGE_BURST` lines at ticks 2780 and
  3781, plus the user's live report on three consecutive builds.

### Pseudoregalia ultra blue now lands on the ultra — two remaining defects, one diagnosed

- Date: 2026-08-16
- **CONFIRMED LIVE by the user**: with the idle observed-spawn trigger
  (`AFTERIMAGE_OBSERVE_SPECIAL_TRIGGER`), the ghost's blue now appears at the end of the ultra hop
  itself rather than one slide later. Slide trail unaffected across every build in this sequence.
- **Defect 1 — two blue images where the real player shows one.** The capture shows the idle scan
  emitting TWICE per ultra, ~60 ticks apart (ticks 7690/7752 and 8768/8828), each with `new=1` and
  the blue colour. Cause not yet established; the counts alone cannot distinguish "the game spawned
  two" from "the pool handed the same actor back". `img=` (the actor pointer) and `sinceLast=` were
  added to the idle log to settle exactly that, and are NOT a fix.
- **Defect 2 — the slide after an ultra also came out blue, and this one is diagnosed and fixed.**
  The blue was not re-detected: the capture contains no `AFTERIMAGE_SPECIAL` line for that burst at
  all. It was **inherited**. A burst that observed no images of its own kept the previously latched
  colour, which made the latch mean "the last colour ever seen" rather than "this burst's colour".
  Fixed by falling back to the pawn's baseline instead, at both emit sites.
- **Note on the confirmation method**: the user judges trail density from a TOP-DOWN camera, because
  at the default behind-the-player angle the offset ghost's trail and the player's blend together —
  see `pitfalls.md`'s Diagnostic methodology. Density confirmations in this file rest on that.
- Source: `UE4SS.log` 2026-08-16 `AFTERIMAGE_IDLE` lines, plus the user's live report.

### Pseudoregalia double-blue: ONE image counted twice, not two spawned (2026-08-16)

- Date: 2026-08-16
- **CONFIRMED LIVE by the user, this build**: the slide after an ultra no longer comes out blue (the
  inherited-latch fix held), and the slide trail itself is unaffected.
- **Cause of the two blue images, established from the actor pointer**: every ultra logged two
  detections carrying the **identical** `img=` pointer, 60-72 ticks apart, across eight ultras
  (ticks 2730/2792, 3180/3241, 3556/3617, 3938/4010, 4654/4714, 6740/6810, 7438/7499, 8681/8743).
  The game spawns one blue image; the pool reclaims and MOVES it about one fade lifetime later, and
  a mover was being counted as a new spawn.
- **Not an off-by-one**, which is what it looked like from the symptom: counts alone cannot separate
  "two spawned" from "one counted twice", and both readings were live until the pointer settled it.
- **Fix, NOT yet watched**: `AFTERIMAGE_REQUIRE_SPAWN_PROXIMITY` — an image only counts as newly
  spawned if it appears within `AFTERIMAGE_SPAWN_PROXIMITY_UNITS` of the player, since an afterimage
  is a snapshot of the player and is therefore born where the player is. Threshold derived from how
  far the player can move between scans, not picked. `rejFar=`/`farNew=` added to the logs so the
  threshold is checkable from a capture.
- **Open and separate**: the ghost still runs 1-2 afterimages ahead of the player generally (the
  slide tail overhang, `SLIDE_REFIRE_WINDOW_TICKS`). Whether this fix also reduces that is exactly
  what the next run shows — they may share a cause or may not, and that is not yet established.
- Source: `UE4SS.log` 2026-08-16 `AFTERIMAGE_IDLE` lines with `img=`.

### Pseudoregalia ultra BLUE afterimage: CONFIRMED CORRECT ON SCREEN

- Date: 2026-08-16
- **CONFIRMED LIVE by the user**: "ultra hop/blue after image looks perfect now" — one blue image,
  on the ultra hop itself, correct colour. Slide trail unaffected. Closes the feature that had been
  parked as "not derivable from polled state; do not resume by guessing more property names".
- The working combination, for the record: colour read off `BP_AfterImage_C`'s own `Color` rather
  than the pawn's `afterimageColor`; observation triggered by the game's real spawns; a pool-
  retirement guard (birth-position test) so one image is not counted twice; and the colour latched
  to its event with a baseline fallback so it cannot be inherited by the next burst.
- Verification method: top-down camera (see `pitfalls.md`, Diagnostic methodology).

### Pseudoregalia ghost trails where the real player does not — reconstructed trigger, not the game's

- Date: 2026-08-16
- **Reported live by the user**: the ghost plays afterimages when none should appear — a slide into
  a backflip with bad timing is meant to be neutral, and the ghost trailed yellow regardless.
- **Cause, visible in the earlier captures once looked for**: every `AFTERIMAGE_BURST` line logged
  `n=5`, which is the hardcoded fallback, not a real `afterImagesToSpawn` value. So `burst_edge` --
  the only trigger that reads the game's own decision and cannot false-positive -- never fired for
  slides. Every slide trail came from the capsule-shrink heuristic, which detects "a slide is
  happening" rather than "the game decided to trail". Those diverge exactly when a move is performed
  badly, which is the reported case.
- **Fix, NOT yet watched**: `AFTERIMAGE_TRIGGER_FROM_OBSERVATION` makes the observation scan the sole
  trigger, so the ghost trails only where the game really spawned images. The reconstructed triggers
  are switched off rather than kept alongside, since both firing would double-count a burst. `false`
  is an exact revert.
- **Fourth attempt at this trigger, and the first that does not re-derive the game's rule**: three
  actionState heuristics, then the capsule shrink, all failed the same way. Same lesson as the throw
  animation and the bubble flash -- see `pitfalls.md`, "The game already knows".

### Pseudoregalia ghost afterimage density now matches the player — observation-driven trigger

- Date: 2026-08-16
- **CONFIRMED LIVE by the user**, judged from the top-down camera: "after images are identical now
  between the player & ghost, at least i can't notice any difference during normal slides anymore."
- **Closes the long-running density gap**, where the ghost consistently ran 1-2 afterimages ahead of
  the real player. Nothing was aimed at it — it fell out of `AFTERIMAGE_TRIGGER_FROM_OBSERVATION`.
- **Which explains what it actually was**: the ghost was never over-DRAWING, it was over-FIRING. The
  capsule-shrink heuristic fired on slides the game itself did not trail on, and every spurious
  burst added images. Mirroring the game's real spawns removed the extra bursts rather than the
  extra images.
- **Worth noting against the fix that was nearly taken**: subtracting one from the spawn count had
  been proposed, on the strength of the same observation. It would have hidden this instead, and
  broken every burst whose count was already correct. See `pitfalls.md`, "A count that is off by a
  constant is a reason to suspect the COUNTER".
- **Still unconfirmed on this build**: the case the change was actually written for — a badly-timed
  slide into a backflip should leave the ghost neutral rather than trailing yellow.

### Pseudoregalia afterimage/trail sync: COMPLETE — player and ghost indistinguishable

- Date: 2026-08-16
- **CONFIRMED LIVE by the user**, judged from the top-down camera: "looks perfect / identical between
  player and ghost now for all the after image/trails", exercised with slides and several ultra hops.
- Closes the longest-running thread in this adapter (roughly 2026-08-13 to 2026-08-16). What is now
  confirmed together, on one build: slide trail present and dense, density matching the real player,
  ultra hop trailing BLUE as one image on the hop itself, ordinary slides staying gold, and no trail
  bleeding between the two.
- **The working design, for the record** — every part replaced a guess with an observation:
  - Colour read off `BP_AfterImage_C`'s own `Color`, not the pawn's `afterimageColor`.
  - The trigger is the game's real spawns (`AFTERIMAGE_TRIGGER_FROM_OBSERVATION`), not a
    reconstruction of when a slide is happening. This removed both the false-positive trails and the
    long-standing 1-2 image density gap, which turned out to be the same bug.
  - A pool-retirement guard (`AFTERIMAGE_REQUIRE_SPAWN_PROXIMITY`): an afterimage is a snapshot of
    the player, so it is born where the player is — a moved actor being recycled is not a new spawn.
  - Colour latched to its burst, with the pawn baseline as fallback, so it can never be inherited.
- **The false-positive case is confirmed too**: on a deliberately badly-timed hop the ghost showed
  nothing ("when i did a bad timed hop, it didn't show anything i think"). That is the case the
  trigger change was written for — the reconstructed trigger fired on the move being *attempted*,
  the observation trigger fires only when the game actually spawned images. Reported with a slight
  hedge ("i think"), so if a spurious trail is ever seen again, reproduce a mistimed move first.
- **Absence is now confirmed as well as presence**, which is the standard `effect-investigation.md`
  argues for: a mirrored effect is only correct when it also stays absent exactly when the real one
  is absent. Every earlier "finished" moment in this saga had tested only the presence half.
- Full investigation and the transferable procedure: `effect-investigation.md`.

## Pseudoregalia loopback still works after the 2026-08-16 project-wide refactor

- Date: 2026-08-16
- **CONFIRMED LIVE by the user**: a Pseudoregalia loopback session run against the rebuilt Go
  binaries — "tested with pseudoregalia loopback, its working fine".
- What this covers: the whole live path end to end, with the refactor in place — the UE4SS C++
  adapter → bridge → `internal/core` → relay (`-loopback`) → core → bridge → adapter, ghost
  rendering included. No adapter source was changed in that refactor (no `.lua`/`.cs`/`.cpp`/
  `.hpp`), so this is confirmation that the **Go-side** changes did not regress a real adapter.
- The Go changes it exercises: the `transport.NDJSONConn` pre-registration buffering fix (an
  adapter's `hello` arrives on exactly the race window it closes), `Core.GameVersion` no longer
  being latched by the first adapter hello, and the `dropAllRemotes` guard move. See
  `architecture.md`'s two 2026-08-16 ADRs.
- **What this does NOT confirm, unchanged:** loopback cannot exercise 7.7 (two real players),
  cross-area filtering, join/leave, or despawn against a second real peer — it echoes the local
  player's own state back by construction. Those stay open in `status.md`.

## Automated Go-side test/debug tooling, and a real intermittent-failure bug it found

- Date: 2026-08-16
- **Established by the agent with the Go tools, not watched by the user** — which is the standard
  for `internal/`+`cmd/` per CLAUDE.md. Nothing here touches an adapter or a running game.

### The bug this found (real, pre-existing, now fixed)

- `internal/transport`'s `TestOversizedLineWithNoDelimiterClosesConnection` and
  `TestIdleTimeoutClosesConnection` both did `server := FromConn(conn)` and *then* assigned
  `server.MaxLineBytes` / `server.IdleTimeout`. `FromConn` starts the read loop **before it
  returns**, so those assignments race `readLoop`'s own read of the same fields — precisely the
  race `transport.go`'s `MaxLineBytes` doc comment already warned about and told callers to avoid
  by using `FromConnWithLimits`. Production code had been fixed; these two tests had not.
- Symptom when `readLoop` won the race: the limit stayed at the 64KiB/60s default, the test's
  8192-byte write never tripped it, no disconnect arrived, and the test failed on its 2s timeout.
- **Found by `go test -count=10 ./...`**, which failed once. `-count=1` and `-count=2` had both
  passed repeatedly beforehand, including a `-count=3` full-suite run minutes earlier.
- Fixed by switching both to `FromConnWithLimits`, which sets the fields before starting the
  goroutine. Verified with `-count=60` on the package (clean) and a repeat of the original
  `-count=10` full-suite run (clean). The package also got measurably faster, consistent with the
  diagnosis: it no longer sometimes waits out a 2s timeout.

### What was added

- `.github/workflows/ci.yml` — build, vet, `go test -race -count=3` on Linux, a fuzz campaign, and
  a Windows build+test job, on every push/PR. **Before this the repo had no CI for the Go code at
  all**; `release.yml` was the only workflow.
- `release.yml` now runs vet + tests before it builds and publishes. It previously went from
  checkout straight to build-and-zip, so the one artifact users actually download was the only Go
  build in the repo that nothing verified.
- `internal/e2e` — builds and launches the real `meshghost-server.exe`/`meshghost.exe` and drives a
  real adapter over the bridge. Covers `cmd/`'s flag/config wiring, which nothing else did, and
  replaces the by-hand `run-relay-loopback.bat` + `run-core-*.bat` loopback check. Its adapter
  reconnects, because `internal/core` deliberately closes a bridge connection when the relay is
  unreachable (see `core.go`'s bridge `hello` handler) and every real adapter has that loop.
- Fuzz targets for the three parsing layers, with the properties chosen to be non-tautological:
  state validity is unchanged by a marshal/unmarshal forward, accepted positions cannot become
  ±Inf when narrowed to float32, and the framing layer never delivers past its line limit.
- `internal/relay/leak_test.go` — goroutine-leak and connection-slot-leak tests. Both pass; no leak
  exists. Worth keeping because a relay holds sessions for hours and nothing else asserted teardown.
- `dev-scripts/run-gotests.bat` — the whole local gate in one command.

### Fuzz campaigns actually run (all clean, no failures)

- `FuzzValidateStateIsStableAcrossTheWire`: 23.3M executions.
- `FuzzValidPositionsSurviveNarrowingToFloat32`: 16.5M executions.
- `FuzzReadLoopNeverExceedsItsLineLimit`: 8.7M executions.
- `FuzzRelaySurvivesArbitraryLines`: 3.3M executions.
- The e2e round-trip test was negative-controlled: dropping `-loopback` from the relay makes it
  fail with its own diagnostic, so it can detect a break rather than merely passing.

### Two environment facts worth not rediscovering

- **`-race` cannot run on this machine.** `gcc` on `PATH` resolves to a devkitPro MSYS2 copy whose
  headers cgo can't use, and the real MSYS2 GCC 15.1.0 can't compile Go 1.22's `runtime/cgo`
  (its internal `-Werror` flags ignore `CGO_CFLAGS`). No WSL installed either. This is why the
  race detector runs on `ubuntu-latest` in CI, where it needs no toolchain setup — the Go code is
  platform-agnostic, so a race there is a race here. A second instance of CLAUDE.md's
  "a build tool on `PATH` may silently resolve to the wrong install".
- **The relay fuzz target must discard `log` output.** With logging on, the fuzzer finds valid
  hellos quickly and the resulting log volume — not the relay — collapses throughput to zero for
  ~18s at a stretch. Diagnosed by subtraction after two wrong guesses (a slot leak and a goroutine
  leak, both disproven by the leak tests above).

## CI's first real run: no data race, one over-strict test of my own

- Date: 2026-08-16
- **Established by the agent from the CI logs** (`gh run view 31927088210 --log-failed`), not
  watched by the user.
- The `-race` job's first execution ever — the check that could not be run locally. Result:
  **no data race anywhere.** `cmd/meshghost`, `cmd/meshghost-relay`, `internal/core`,
  `internal/e2e`, `internal/protocol` and `internal/transport` all passed clean under
  `-race -count=3` on Linux, including the e2e tests that launch the real binaries.
- The one failure was `TestNoGoroutineLeakAcrossManyConnections`, added the same day, failing all
  three runs with `got message type "leave", want "welcome"`. Not a leak and not a race: the test
  used `expectWelcome`, which requires the Welcome to be the *first* message received.
- **The underlying relay behaviour is real and benign**: a joining client is added to its room
  before its Welcome is sent, so a peer disconnecting at that moment can have its Leave forwarded
  to the newcomer first. `internal/core` ignores a Leave for a player it never knew about, so
  nothing is broken on the wire — but a test asserting on first-message ordering will fail on a
  busy room. Fixed by skipping ahead to the Welcome (`awaitWelcome` in `leak_test.go`).
- Worth noting for future flake-hunting: this passed locally every time, including at `-count=20`
  and with `GOMAXPROCS=2`, and only ever failed on CI. Not everything reproduces on this machine.

## Selectable transport (`tcp`/`udp`/`quic`) — 2026-08-16, established with the Go tools

Per `CLAUDE.md`'s split, all of the below is Go-side and was confirmed by running the tools
directly, **not** by watching a game. Nothing here is a claim about anything on screen.

- **All three transports carry a real session through an unmodified relay.**
  `TestRelayOverUDP`, `TestRelayOverQUIC`, and `TestRelayMixesAllThreeTransportsInOneRoom`
  (`internal/relay/relay_transport_test.go`): hello, welcome, join and forwarded state, with
  `internal/relay` containing no transport-aware line.
- **A room really can mix transports.** Three clients, one each on tcp/udp/quic, all see each
  other's joins and state. This is what makes the setting a feature rather than a way to
  partition the player base.
- **The shipped binaries can actually turn it on.** `internal/e2e`'s
  `TestReleaseBinariesRoundTripAGhostOnEveryTransport` launches the real `meshghost.exe` and
  `meshghost-server.exe` with `-transport udp` / `-transport quic` and drives a ghost through the
  full bridge → client → relay → client → bridge round trip.
- **`Send` used to issue two writes**, payload then `'\n'` — invisible over TCP, two datagrams per
  message over UDP. Fixed, and `TestSendIssuesExactlyOneWritePerMessage` was confirmed to fail
  against the old version by reverting it and watching it report 4 writes for 2 messages, rather
  than assumed to.
- **Reliability behaves as designed under real loss.** With a deterministic loss-injecting proxy,
  a `Send` payload survives its first 3 datagrams being dropped and is delivered exactly once,
  while a `SendUnreliable` payload is dropped and never retransmitted. The reliable test was also
  confirmed to fail with the retransmit loop disabled.
- **TCP and UDP genuinely share a port number** (`TestTCPAndUDPShareAPortNumber`), so `tcp,udp`
  costs one port. QUIC cannot share with `udp` and has its own.
- **quic-go exposes a working `ExportKeyingMaterial`** over a TLS 1.3 connection
  (`TestHandshakeIsTLS13`). This was the open question gating the shelved room-code
  channel-binding design in `ideas.md` — it would drop straight into `quic`.
- **The UDP demultiplexer survives hostile input.** `FuzzListenerSurvivesArbitraryDatagrams`,
  1,482,717 executions in 30s, no crashes and no wedged listener. Worth recording *how* that
  number was reached: the first version of the target dialled a fresh socket per execution and
  stalled at ~20k execs with the rate pinned at 0/sec, while still reporting PASS — a green run
  that was measuring almost nothing. Replacing the liveness check with a raw hello on an
  already-open socket raised throughput ~70x.
- **Full suite green at `-count=10`**, per `CLAUDE.md`'s concurrency rule, including
  `internal/e2e`.

## Transport discovery (`transport: "auto"`) — 2026-08-16, established with the Go tools

- **A real client given only a tcp address finds and uses quic.** Confirmed twice: by
  `internal/e2e`'s `TestAutoTransportUpgradesToQUIC` (real binaries, `-transport auto`, full ghost
  round trip, asserting on the client's own log), and by hand against a relay serving all three —
  the client logged `relay offers tcp:48001, udp:48001, quic:48003 — using quic at
  127.0.0.1:48003`. It could not have guessed that port; quic runs on a different one.
- **Discovery discloses nothing without the room code.** `TestQueryOnlyStillRequiresTheRoomCode`:
  a wrong code gets a `reject`, not a transport list, and the correct code gets the list. This is
  the property that made "ask before joining" acceptable rather than a new pre-auth endpoint.
- **A query never joins.** `TestQueryOnlyReturnsTheTransportListAndDoesNotJoin` watches an
  existing room member and asserts it sees nothing at all — no `join`, no `player_id` consumed.
  That is the entire point of asking first rather than joining and reconnecting.
- **An offer-less relay is harmless**, replying with an empty list, which every pre-existing test
  server exercises for free.
- **Full suite green at `-count=10`** after the change, including `internal/e2e`.

## UDP per-connection token — 2026-08-16, established with the Go tools

Added after the user asked whether the CelesteNet UDP measures were needed here. They were: the
address-validation cookie gated *admission* only, so a connection was identified by source
address alone and anyone able to spoof a live client's ip:port could inject state into its
session — the gap `internal/README.md` already cited CelesteNet's token as closing.

- `TestInjectionFromTheRightAddressWithTheWrongTokenIsDropped` forges a correctly-framed
  datagram from the client's **real** source address with a token that is merely wrong, and
  confirms it is dropped **and** that the targeted session keeps working afterwards.
- `TestUnframedDatagramsAreIgnored` covers the bypass: bare NDJSON lines were previously valid
  unreliable payloads, so leaving them accepted would have made the token optional in practice.
- Fuzzing re-run against the new framing: **4,837,744 executions in 25s**, 27 new interesting
  inputs, no crashes and no wedged listener, with seeds added for every token-carrying frame
  shape.
- Full suite green, including `internal/e2e` driving the real binaries over udp.

Technique only — no CelesteNet code was read or copied; the reference is this repo's own
prior-art summary, and a per-connection secret is generic (TCP sequence numbers, SYN cookies,
QUIC connection IDs).

## A real bug found in review, and a test that first failed to catch it — 2026-08-16

Found by a documentation-writing pass reading `udpconn` closely, not by any test.

**The bug:** a reliable udp payload was acknowledged *before* delivery. Delivery into a `Conn` is
non-blocking and drops when the 64-deep queue is full, so under a burst the sender would receive
its ack, never retransmit, and the dedup record would have suppressed the retransmit anyway — a
`join`, `leave` or `welcome` could vanish while `Write` reported success. Fixed by delivering
first and acking only on success; a duplicate is still re-acked, since a lost ack is exactly why
a sender retries.

**Worth recording more than the bug:** the first regression test written for it **passed against
the buggy code**. It flooded and drained through the public API, and the receive queue was not
reliably full at the deciding instant, so the failure never triggered — a green test that proved
nothing, the same shape as the earlier fuzz target that reported PASS while frozen at 20k
executions. Replaced with one that saturates the queue directly and asserts the precise property
(**an undeliverable payload must not be acknowledged**), then confirmed to fail against the
restored bug before being kept.

Also fixed in the same pass: `contract.md` claimed `auto` was the shipped client default (it is
`udp`), `internal/README.md`'s CelesteNet section still said the UDP token was hypothetical, and
a doc comment in `relay.go` had been merged onto the wrong function.

## Live: all three transports confirmed on screen with Pseudoregalia — 2026-08-16

**Human-gated, per `CLAUDE.md`: the user watched this.** Loopback relay serving `tcp,udp,quic`,
Pseudoregalia adapter, one transport per run, run in the order quic → tcp → udp.

- **The ghost spawned and moved on all three.** User's words: "the ghost spawned in and was moving
  around for all 3 of the protocols." This is the first time `udp` or `quic` has carried a real
  game session — everything before it was tests.
- **The client log named the transport each time**, e.g.
  `core: relay offers tcp:7777, udp:7777, quic:7780 — using udp at 127.0.0.1:7777`. That line is
  what makes the run meaningful: a preference the relay does not serve degrades silently to tcp,
  so "it worked" alone proves nothing about which transport was exercised.
- **The relay log independently corroborates the run order**, and incidentally confirmed a
  behaviour that previously had only a unit test. The quic and udp runs each show a closed tcp
  connection immediately before the join — the discovery handshake connecting, asking, and hanging
  up. The tcp run shows **no such line**, because a tcp preference short-circuits
  `resolveTransport` and never opens a discovery connection at all. Established from the log by
  the agent, not watched.

**One symptom, seen once, never reproduced, cause unknown.** On an earlier attempt the user saw
"one ghost getting stuck and not moving". It did not recur across the three ordered runs, and the
user confirmed ghosts were removed properly in all three. **Nobody established what caused it**,
and the user's own read — "idk exactly what caused it, but don't think it's protocol related" —
is the position recorded here rather than any theory.

The leading hypothesis, unconfirmed and not tested: that attempt ran all three transports back to
back **without closing the game in between**, so the mod stayed loaded across client restarts.
Killing `meshghost.exe` drops the bridge socket abruptly, and the core cannot send
`despawn_remote` because it is already gone — so cleanup would have to come from the mod side.
That would leave the previous run's ghost frozen while the new session works, which matches what
was seen. It matches; it is not evidence.

A port already in use was raised as a hypothesis and is a poor fit, recorded so it is not
re-raised: a taken port fails loudly at bind rather than yielding a running client with a frozen
ghost.

**Suspected, not confirmed, and pre-existing rather than caused by the transport work:** the
Pseudoregalia mod appears to have no despawn-on-bridge-loss path — a search found no disconnect
callback and no ghost-map clear (absence of a match is not proof, so this needs confirming
properly). If that is right, a real user whose `meshghost.exe` crashes mid-session is left with
ghosts frozen in their world rather than disappearing, on **any** transport. Worth checking
independently of this work.

**If it is ever built, the fix is `release_all_ghosts` on bridge loss — NOT moving the ghosts
somewhere out of sight.** Parking a stranded actor was suggested (reusing what zone transitions
appear to do) and is the one approach already known to be wrong here: `Plugin.cpp`'s own comment
records an `EXCEPTION_ACCESS_VIOLATION` from exactly that, `release_ghost ->
call_set_actor_location_and_rotation` on an actor whose level had already torn it down, which is
why props became destroyed-not-parked. A liveness check does not help — `IsUnreachable()` is only
safe on an object that is still allocated. What actually works is the proactive clear the LoadMap
PRE hook already performs, *before* teardown, and the bridge-loss case wants that same call.
**Nothing has been built or watched, so this is a plan, not a fix.**

Separately, if a ghost ever freezes while the client is still running, `meshghost.log` is the
place to look — specifically for repeated `core: send state to relay failed`, which is how an
oversized state message (`udpconn.MaxDatagramBytes`, 1200) would present on udp or quic.

**Not yet exercised live:** sustained multi-minute load on udp/quic (the retransmit timer and
dedup pruning only engage over time), two real machines over a network rather than loopback, and
a room genuinely mixing transports between two live players.

## 2026-08-16 — Autostart, Go side: `-exit-with-pid`, log append, config visibility

**Established with the tools, not by watching a game** (CLAUDE.md's "the Go client/server is the
opposite case" rule): `dev-scripts/run-gotests.bat` green after the change — build, vet, and the
whole suite twice including `internal/e2e` — plus these three run by hand against the real
`meshghost.exe`, in a scratch folder outside the repo:

- **`-exit-with-pid` reaps the client.** Started a throwaway parent process, started the client
  with `-exit-with-pid=<parent>` and `-bridge=127.0.0.1:7999`, confirmed it was alive and
  listening, killed the parent, and the client exited within the ~2s poll — logging
  `pid 12852 is gone -- exiting so nothing is left holding 127.0.0.1:7999`. This is the orphan
  case autostart introduces: a hidden client outliving a crashed game and holding the bridge port.
- **The log appends across runs.** Two consecutive runs left two `=== meshghost run start ===`
  banners in one `meshghost.log`, where the old truncating open would have erased the first. The
  banner correctly read `autostarted by a game adapter` for the run with `-exit-with-pid` and
  `started manually` for the run without.
- **A missing config now says so.** With no `config.json` present the log named the absolute path
  it looked at and that built-in defaults were in use; with one present it logged
  `config loaded from <abs path>`. Previously both cases were silent, which with no console window
  is indistinguishable from "the settings I edited did nothing".

**Not watched, and not claimed:** that a running Pseudoregalia actually starts a core, that no
window appears, that a ghost shows up with nothing launched by hand, or anything at all under
Proton. The mod side is built and deployed but unconfirmed — see `status.md`.

## 2026-08-16 — Autostart works live on Pseudoregalia (user-watched)

**Confirmed on screen by the user**, same day as the Go-side entry above. The user launched only
`dev-scripts/run-relay-loopback.bat` and then the game — nothing else:

- **The mod started the core by itself.** Task Manager showed exactly one `meshghost.exe`
  alongside `meshghost-relay.exe`, neither client having been launched by hand.
- **No console window appeared for the client at any point**, which is the actual feature — the
  session reads as server + game rather than server + client + game.
- **The full chain worked untouched:** the relay logged
  `p1 ("player") joined room "default" as game "pseudoregalia" over udp`, and the loopback ghost
  rendered in-game.

This closes the question the speedrunner's feedback raised for Pseudoregalia on Windows: starting
the game is now the whole ritual.

- **It cleaned up after itself.** The user watched Task Manager across the whole session and
  confirmed the client was both started and killed correctly — so a finished session leaves no
  hidden `meshghost.exe` holding the bridge port, which was the failure mode `-exit-with-pid`
  was written for.

**Still not confirmed:** reuse of a core that was already running (the "started it by hand first"
path). Nothing under Proton. TEVI and Emerald not converted.

Noted in passing from the same relay log, NOT investigated and NOT attributed to this change: a
`relay: connection error: read tcp ...: use of closed network connection` line immediately before
the join, which is the shape of the tcp handshake connection closing after the upgrade to udp.

## 2026-08-16 — "use of closed network connection" in the relay log was ours, and is fixed

**Established with the tools** (real binaries, reproduced then re-run after the fix), prompted by
the user spotting the line in a relay window and asking for it to be checked rather than assumed.

- **Reproduced deterministically.** A client on `-transport=udp` (the shipped default) made the
  relay log `relay: connection error: read tcp ...: use of closed network connection` immediately
  before **every** successful join. On `-transport=tcp` it never appeared.
- **Cause, ours entirely.** The relay closes the tcp connection itself after answering a
  `query_only` transport-discovery hello (`internal/relay/relay.go`). Its read loop was parked in
  `scanner.Scan()`, so that Close came back as `net.ErrClosed` — and `transport.fail()` only
  special-cased `io.EOF`, so it reported our own deliberate close through `OnError`.
- **Fixed in `internal/transport`, not the relay**, because every deliberate `Close()` in the
  codebase had the same problem (rejected hello, hello timeout, oversized line, rate-limit trip) —
  each already logs its own reason, then got a second, scarier line about it. `net.ErrClosed` can
  only be produced by this process closing the socket, never by a peer or the network.
- **Verified after the fix, against rebuilt binaries:** a udp client now joins with no error line
  at all, and — the control that matters — a client killed outright is *still* reported
  (`wsarecv: An existing connection was forcibly closed by the remote host`). Suppressing our own
  close did not suppress real ones. `OnDisconnect` still fires in both cases.
- Regression test: `TestLocalCloseDoesNotReportAnError` (`internal/transport`). Full suite green,
  plus `-count=10` on transport/relay/core/netx since this touches a read loop.

Cosmetic in effect, but it put an error line at the top of the very log a remote tester is now
asked to send back — which is why it was worth chasing rather than explaining away.

## 2026-08-16 — CI's race job found a relay race, and chasing it found a worse bug in the core

**Established with the tools.** CI run 31949407557 failed the race job on an intermittent
`TestOversizedPositionDropped` ("c2 unexpectedly received join") — a test that had nothing to do
with joins, which is what made it misleading.

- **Bug 1, the relay (pre-existing).** A joining client's roster was captured atomically with the
  add (`tryAddAndSnapshotRoster`), but its join was then broadcast to `allExcept(newID)` — a
  SECOND, later lock acquisition. A client that joined in the window between another client's add
  and its broadcast was therefore included, despite already having been told about that client in
  its own welcome roster. Fixed by forwarding to the roster captured with the add; `allExcept` had
  no other callers and was removed.
- **Bug 2, the core (worse, found by the test written for bug 1).** The relay adds a client to the
  room *before* sending that client's welcome, so a concurrent joiner's `join` can arrive ahead of
  our own `welcome`. `Welcome` assigned `c.roster` outright, erasing that peer — and states from
  anyone outside the roster are dropped by design, so **two players starting at the same moment
  could simply never see each other for the whole session.** Welcome now merges; the roster is
  cleared explicitly on disconnect instead (it was relying on Welcome's replace as its reset).
- **Not reproducible locally by luck, reproducible by construction.** 300 local runs of the
  failing test, then 50+ full-package runs and 100+ targeted runs, never reproduced bug 1. A test
  asserting the *invariant* under concurrent clients
  (`TestJoinIsNeverSentForAPlayerAlreadyInTheWelcomeRoster`) reproduced bug 2 within 100 runs on
  the first try. Regression tests for both, plus `TestJoinArrivingBeforeWelcomeIsNotErased` in
  `internal/core`.
- **Local tooling gap re-measured** (Go 1.25): `-race` still cannot run here — the `gcc` on PATH is
  devkitPro's (fails on `stddef.h`), MSYS2's own GCC 15.1 fails inside `runtime/cgo`, and
  `wsl.exe` is present with no distro installed. `dev-scripts/run-gotests-race.bat` now probes for
  a usable compiler and reports the gap instead of it being invisible;
  `run-gotests-stress.bat` (`-count=10 -shuffle=on -cpu=1,4`, ~3-4 min, e2e excluded) is what
  works today. Full suite green after both fixes.

**Caveat kept deliberately:** a `join` arriving before `welcome` is still possible on the wire.
Fixing that relay-side would mean holding the room lock across a network write to a brand-new
connection; tolerating it in the core is cheaper and robust to any relay that behaves this way.

## 2026-08-16 — Autostart reuses an existing core, and never kills one it didn't start (user-watched)

**Confirmed on screen by the user**, completing the Windows side of the autostart work. The user
started `dev-scripts/run-relay.bat` and `run-core-pseudoregalia.bat` by hand, then launched
Pseudoregalia:

- **The mod used the existing core instead of starting its own.** UE4SS.log:
  `bridge connected.` followed immediately by `using a MeshGhost core that was already running.`,
  with `connect_attempts=1` and no spawn line anywhere. Only one `meshghost.exe` existed.
- **The session ran clean over that reused core:** `send_ok` climbed past 1,800 with
  `send_fail=0`, `lines_malformed=0`, and the core logged the bridge dropping normally when the
  game closed.
- **Quitting the game did NOT kill the core.** The user confirmed the console windows stay open
  and `meshghost.exe` keeps running after the game exits, closing them by hand afterwards. This is
  the invariant that matters: a mod may stop a core it started, never one it merely found — which
  someone may well be using for a second game, or have started deliberately.

A first attempt at this could not settle the last point: both processes were gone by the time the
logs were read, and the log looks identical whether the core was killed at game exit or closed by
hand later. Re-run watching for it specifically, rather than inferred from the earlier run.

**Windows autostart is now fully watched:** cold start, ghost rendering, cleanup on exit, reuse,
and non-interference with a core it didn't start. Still unwatched: anything under Proton, and TEVI
and Emerald, which are deliberately not converted yet.

Incidental, from the same logs, neither a fault: `run-relay.bat` serves tcp only (it passes no
-transport), so the client correctly logged `this relay does not offer udp ... staying on tcp`
rather than failing; and a relay restart between the two script launches produced a
`will keep retrying` reconnect that recovered on its own three seconds later.

## 2026-08-16 — A release failed on a port that was free for tcp but forbidden for udp

**Established with the tools**, from the failed Release run's own log. Three e2e tests failed at
once on the windows-latest runner — both udp and quic subtests of
`TestReleaseBinariesRoundTripAGhostOnEveryTransport`, plus `TestAutoTransportUpgradesToQUIC`.

The relay said exactly why, and it was not our code:

    listen udp on 127.0.0.1:63503: bind: An attempt was made to access a socket
    in a way forbidden by its access permissions.

That is Windows `WSAEACCES` on a **udp** bind, for a port the test had obtained seconds earlier by
listening on **tcp**. `e2e_test.go`'s `freePort` asked the OS for a tcp port and handed the number
to the relay, which binds the same number for udp (and another for quic, udp underneath) — two
different questions that were being treated as one. Windows can answer them differently:
Hyper-V/WinNAT reserve blocks of the ephemeral range, and a udp bind inside one is refused outright.

`freePort` now probes udp on the candidate number as well and asks for another if it fails.

**Not reproducible on the dev machine, and the reason is worth recording:**
`netsh int ipv4 show excludedportrange udp` lists no exclusions here, so a udp bind never fails on
a tcp-free port. The failure needs a machine that reserves ranges, which the runner does and this
one does not.

**Luck-of-the-draw, which is worse than a reliable failure**: the same code had passed on the
Windows job minutes earlier (CI run 31952340980), so re-running the release would have "fixed" it
and taught us nothing. Full suite green after the fix, e2e repeated at `-count=3`.

## 2026-08-16 — The client shows a console under Wine by default (Windows side verified)

**Established with the tools**, from the user's suggestion: if MeshGhost is going to be invisible,
it should only be invisible where we have actually watched it clean up after itself.

- **On real Windows it stays hidden.** Ran the freshly built `meshghost.exe` here: no window
  appeared and the log contains no Wine line, confirming `runningUnderWine` does not false-positive
  on the platform where hidden IS the feature.
- **Wine detection** resolves `wine_get_version` in ntdll — Wine's own ntdll exports it and real
  Windows has no equivalent. Traceable, not from memory: Wine's `dlls/ntdll/version.c`, and the
  long-standing documented answer to "how do I detect Wine".
- **It is only a default.** `-show-console` or `show_console` in config.json still decides;
  regression tests cover both the four-way default matrix and a config file overriding it.
- **Caught while writing it:** the shipped mod-folder config template had `"show_console": false`
  set explicitly, which would have overridden the new default and disabled the safety valve for
  exactly the Proton users it exists for. The key is now absent from the template on purpose, with
  a comment saying why, since absent means "decide per platform".

**Untested, and the whole point of the change:** that the window actually appears under Proton, and
whether the client there dies with the game at all. If it turns out cleanup works fine through
Wine, this default becomes noise and should be reconsidered — noted in the code as well.

**What to ask the Proton tester, specifically:** after quitting the game, is the MeshGhost console
window still open? That single question separates the two outcomes that matter. Gone means the
Wine-hosted client dies with the game and the whole autostart lifecycle holds there — at which
point the visible console is noise and the default should be reconsidered. Still open means the
orphan case is real under Wine, and `-exit-with-pid` does not survive that boundary; the window is
then doing its job, and the fix belongs in the mod (a native client started by hand, per the
reuse path, avoids the problem entirely). Either answer is worth having; "it worked" alone is not.

## 2026-08-16 — Autostart works under Proton (Linux tester, with logs)

**Confirmed by the Linux speedrunner** who prompted this whole feature, on v0.7.0, with both logs
sent back. This closes the last unknown from the autostart ADR.

- **The mod spawns the Windows client inside the Proton prefix.** UE4SS.log:
  `started meshghost.exe (pid 680)` then `bridge connected` — `CreateProcessW` works through Wine.
- **The client runs normally there.** `autostarted by a game adapter`, config loaded from the mod
  folder, bridge listening on 127.0.0.1:7778, relay connected as p1…p6 across six sessions.
- **`-exit-with-pid` works across the Wine boundary**, which was the part most likely to misbehave.
  Every one of the six runs ends with `pid NNN is gone -- exiting so nothing is left holding
  127.0.0.1:7778`. No orphans. Their words: *"it closes correctly and it does load the config, a
  changed name gets sent to the server"*.
- **So a Linux user needs only the Windows zip.** Drag the mod in, edit the config beside it,
  launch. The native Linux build is an option, not a requirement.

**Two negative findings from the same test:**

- **Wine has no usable console window.** Detection worked — every run logged
  `running under Wine (Proton/CrossOver)` — but no window ever appeared, because Wine only
  emulates a console via wineconsole/conhost and a Proton-launched game has no backend for it.
  `AllocConsole` can report success and produce nothing. The Wine console default has been
  removed: it could not work, and the cleanup it was guarding turned out to hold anyway. What
  remains is a log line saying a console cannot appear here, rather than silence.
- **One mistyped value discarded the entire config.** They wrote `"show_console": "true"`
  (quoted) and got `cannot unmarshal string into Go struct field ... of type bool -- every
  setting in it is being IGNORED`. That is why the relay showed them joining as `"player"`
  instead of their configured name. Fixed: `encoding/json` already skips only the bad field and
  keeps decoding the rest, and the code was throwing that away on `err != nil`. A type error now
  warns about the one key and applies everything else; a genuine syntax error still rejects the
  file. Mirrored in the relay, where the same mistake silently dropped `room_code`.

**The appending log with a per-run banner is what made this diagnosable at all** — six runs in one
file, each naming its executable, working directory, and which `config.json` it read, from a
machine nobody here can access. Recorded because it justifies the cost of that design, and because
the relay was still truncating its own log every run until this entry (now fixed to match).

## 2026-08-16 — Pseudoregalia 7.7: two real players, two machines, online (user-watched)

**Confirmed by the user with a screenshot**: the Linux speedrunner got MeshGhost running on a
laptop, and the two of them saw each other's goats in Pseudoregalia across two separate computers.
This is the milestone the whole "Blocked on a real two-player session" list was waiting on, and it
is the first time anything in this project has been confirmed between two machines rather than two
processes on one.

**What this proves, and it is not adapter-specific:** the client, relay, and transport stack works
between real machines over a real network — a different game's adapter inherits that unchanged,
because none of it knows which game it is serving. Together with the Proton result earlier the same
day, the delivery path is now demonstrated end to end: unsigned zip → drag-and-drop mod → mod starts
its own core → relay → a peer on another computer, on two different operating systems.

**The standard this changes, per the user:** a two-machine test is **no longer a required
verification step for a new game**. What it was proving lives in game-agnostic code that has now
been proven once, and re-proving it per adapter is re-testing `internal/relay` with extra steps.

**The one carve-out, and it comes from this repo's own record rather than caution in the abstract.**
Loopback echoes *your own state back to you*, so anything whose correctness depends on the peer's
state DIFFERING from yours is not exercised by it. `status.md` itself listed items as "neither
verifiable in loopback by construction" — a fresh ghost showing the local player's state, and two
findings suspected to be loopback-offset artifacts rather than real bugs. Also unexercised: real
latency and jitter (loopback has ~none, and `contract.md` warns interpolation degrades silently
under wall-clock skew between peers), a peer with a different `game_version`, and a peer whose
appearance differs from yours. **So: loopback is sufficient for anything about rendering and
movement that is symmetric between the two sides, and not sufficient for anything that depends on
the two sides being different.** That distinction is narrower than "always needs two machines" and
is what actually failed here before.

## 2026-08-16 — Pseudoregalia pole rotation is correct (two-machine session)

**Confirmed by the user** during the same two-machine session that closed 7.7. Rotation while a
peer is on a climbing pole renders correctly.

This settles it in the direction the earlier entry suspected but could not prove: pole rotation was
listed as "very likely the loopback offset, not a real bug", because loopback puts the ghost beside
the geometry rather than on it, and a ghost standing next to a pole cannot demonstrate rotation
around one. A real peer, actually on the pole, was the only thing that could tell those apart —
and it is exactly the asymmetric case `testing.md`'s new rule keeps two machines for.

## 2026-08-16 — The Pseudoregalia camera fight-back is what takes the camera

**Established from a live trace** (user ran the session; `CAMERA_TRACE` in the mod), after the user
reported the camera going wrong after a cutscene or an in-game "reset to last save", and observed
on screen that **the ghost appeared to grab the camera after the cutscenes**.

The log shows the opposite of the theory the mechanism was built on. Twice in one session, the
game asked to switch to a *different* `BP_PlayerCam_C` rig and the mod forced it back:

    game wants BP_PlayerCam_C_2147482134 -> forced back to ..._2147482171
    game wants BP_PlayerCam_C_2147481633 -> forced back to ..._2147481681

**Neither rewrite followed a ghost spawn.** The surrounding trace shows the loopback ghost standing
still at a fixed position for seconds either side, with the player idle. This is the game's ordinary
per-area rig switching — the curated multi-rig system `phase7.md` documented — and the mod blocks
every instance of it once a ghost has ever existed. The camera then stays pinned to whichever rig
was current just after the level load, which frames where the ghost is standing; from the player's
seat that reads exactly as "the ghost grabbed the camera".

**So the fight-back is not failing to re-grab the camera. It is the thing taking it.**

Also confirmed by the same trace, and worth keeping: **cutscenes and area cameras do route through
`SetViewTargetWithBlend`** (`branch=learn target=CameraActor …TitleScreen`, then `BP_PlayerCam_C`
in `ZONE_Dungeon`). The "cutscenes use some other camera path" explanation is dead.

**Next, not yet run:** the mechanism is now behind `CAMERA_FIGHTBACK = false` and the same session
should be repeated with it off. Ghosts spawn with collision disabled now, so if rig switching is
driven by overlap volumes, a ghost may no longer be able to trigger one — in which case the
original 7.4 problem no longer exists and the mechanism should be deleted rather than tuned. If the
camera misbehaves with it off, the original problem is still real and the fix has to be aimed at
what the trace shows rather than at the symptom. Either answer is worth having; this is
`pitfalls.md`'s "run the same test without the fix applied".

## 2026-08-16 — Camera fight-back removed; the camera is correct without it

**Confirmed on screen by the user**, running the same session with the mechanism disabled:
*"the camera was correctly placed/following the player all the time"* — through the intro cutscene,
with a loopback ghost present, and across an in-game "reset to last save" and the cutscene after it.

The log agrees and shows exactly what changed: **2 camera-rig switches allowed that the previous
build would have blocked** (`branch=allowed-change from=BP_PlayerCam_C_… to=…`), **0 rewrites**, and
a ghost present (`1 remote(s)` at the transition). Same steps, same area, same rigs — the only
difference was not interfering.

**So the mechanism was removed rather than tuned.** With it, the mod pinned the camera to whichever
rig was current just after a level load and blocked every later switch; the user saw that as the
ghost stealing the camera. The 7.4 problem it was written for — a ghost spawn making the game
re-pick its camera — did not reproduce at all, most likely because ghosts now spawn with collision
disabled and can no longer trigger whatever selects a rig. **A fix aimed at a symptom outlived the
cause and became the bug.**

Deleted: the rewrite path, `last_known_good_view_target`, `any_ghost_ever_spawned`, and the LoadMap
clearing that existed only to keep the cached pointer safe. What remains is the read-only probe
that settled this, behind `CAMERA_TRACE` (off by default) — which is also the shape
`adapters/_template`'s new "observe before you override" rule asks for.

**Not claimed:** that no ghost can ever disturb the camera. This was one area, one session, with
one stationary loopback ghost. If it reappears, the trace is already in place and the next fix
should be aimed at what it shows.

## 2026-08-16 — The through-walls outline is custom depth, and the ghost inherits it

**Established by a read-only probe** (`OUTLINE_TRACE`), after the user asked whether the ghost's
see-through-walls silhouette could be turned off and how one would even find it. Screenshot shows
the ghost as a solid blue silhouette through a wall while the local player renders normally.

Measured, both actors, one session:

    local VisualMesh  bRenderCustomDepth=true  CustomDepthStencilValue=0  bRenderInMainPass=true
    local WeaponMesh  bRenderCustomDepth=true  CustomDepthStencilValue=0  bRenderInMainPass=true
    ghost VisualMesh  bRenderCustomDepth=true  CustomDepthStencilValue=0  bRenderInMainPass=true
    ghost WeaponMesh  bRenderCustomDepth=true  CustomDepthStencilValue=0  bRenderInMainPass=true

So it is the standard Unreal custom-depth outline: the component renders into the custom-depth
buffer and a post-process pass draws the silhouette where those pixels sit behind scene depth. The
ghost carries it because it is a clone of the player pawn, not because anything in this mod asked
for it. **The weapon mesh carries it separately** — a fix covering only the body would have left a
sword visible through a wall, which is the same information leak in a smaller shape.

**Fix applied, not yet watched:** `SetRenderCustomDepth(false)` on the ghost's `VisualMesh` and
`WeaponMesh` at spawn. The engine's own setter rather than writing `bRenderCustomDepth` directly,
because the raw bool is render-thread state — assigning it on the game thread can leave an
already-created render state untouched, so the flag would read false while the silhouette kept
drawing. The trace now runs *after* the calls so it reads the component's state back rather than
echoing what we wrote.

**Why it is a fix and not an option:** knowing where another player is through geometry is
information, and this project's line is visual-only with no gameplay effect. For a speedrunner
that is a real advantage. The local player's own outline is untouched.

## 2026-08-16 — A ghost brings its own camera rig, and that is what took the camera

**Confirmed by the user**: *"its working now, didn't lose control of my camera / not stuck
anymore"*, after several sessions where loading a save left the player able to walk but unable to
turn the camera.

**The mechanism, measured rather than reasoned:** every ghost spawn is followed 3-4ms later by
`SetViewTargetWithBlend` switching to a **different** `BP_PlayerCam_C`, on every load, and never at
any other time. The ghost is a clone of the player pawn, so it arrives with its own camera rig and
the game targets it. A rig that serves a ghost does not answer the player's input — hence movement
working while the camera was dead.

**This vindicates the 7.4 fight-back's premise and confirms its rule was the bug.** Blocking *every*
view-target change once any ghost existed is why removing it fixed one session and broke the next;
both behaviours were wrong in opposite directions.

**Identification, after one clean negative.** The engine's `Owner` is `(none)` on these rigs, so the
first ownership test could not fire — the log said `owned_by_ghost=no` while the camera still broke,
which is the negative result the probe was built to give. A property dump of a rig caught mid-steal
then found the real link:

    OwningActor (ObjectProperty) = BP_PlayerGoatMain_C_...

So the shipped rule is: **refuse a view-target change to a rig whose `OwningActor` is one of our
ghosts, and let everything else through** — cutscenes, area rigs, and the game's own routine
switching are untouched. Rejection redirects to the last target the game itself chose, never to
`nullptr`, which is not "no change" but "no camera". A spawn-window correlation remains only as a
fallback for a rig that cannot be identified at all.

**Also fixed along the way, and real but unrelated to the reported symptom:** the ghost auto-possessed
on spawn (`AutoPossessPlayer = 1`, confirmed), stealing the controller every time; it is now cleared
on the class default object around `SpawnActor`, and the hand-back is skipped when nothing took
control. Bracketing the spawn is what made the theft visible — a probe reading only *after* the
hand-back reported the local pawn every time and hid it completely.

**Still open:** the duplicate spawn (two ghosts per level load, the `remotes` entry going from
present to absent within three ticks, leaving an orphan). The camera hook is now registered
unconditionally, since it carries a fix rather than only a probe; the three trace flags are off.

## 2026-08-16 — Ghosts no longer render through walls (user-watched)

**Confirmed on screen by the user**, with two screenshots: standing beside a ghost, the blue
through-walls silhouette appears for the **local player** and not for the ghost — including the
second shot, where the player's own silhouette shows *through* the ghost's body. Ghost-only, which
is the important half: a change that removed both would have taken a real game feature away.

The read-back agrees, and it is the component's own state rather than an echo of the write:

    ghost VisualMesh  bRenderCustomDepth=false
    ghost WeaponMesh  bRenderCustomDepth=false
    local VisualMesh  bRenderCustomDepth=true
    local WeaponMesh  bRenderCustomDepth=true

`SetRenderCustomDepth(false)` on the ghost's two mesh components at spawn, via the engine's own
setter rather than a property write — the raw flag is render-thread state, so assigning it can
leave an already-created render state drawing while the property reads false. That risk did not
materialise, but the setter is why.

**Treated as a fix rather than an option on purpose:** seeing another player through geometry is
information, and this project's line is visual-only with no gameplay effect — for a speedrunner
that is a real advantage. `WeaponMesh` carried the flag separately from the body, so a fix aimed
only at the character would have left a sword visible through a wall.

Found by a read-only probe first (`OUTLINE_TRACE`), which is what `adapters/_template`'s
"observe before you override" rule asks for: the mechanism was confirmed as Unreal custom depth
before anything was changed, rather than assumed from the way it looked.

## udp's reliable path was reliable but NOT ordered — found and fixed 2026-08-16

**Established with the Go tools, not by watching a game** — `internal/netx/udpconn` and
`internal/core` are deterministic code against a contract we own, which is exactly the case
CLAUDE.md says to confirm with tests rather than a live session.

- **The claim that was wrong.** `contract.md` promised the reserved event plane would be "reliable,
  ordered", and `udpconn.Write`'s doc comment told callers they "get TCP-like semantics". The
  receive path delivered every payload the moment it arrived and deduped by seq, with no
  resequencing buffer — so retransmission bought delivery, never order. `udp` is the client default.
- **Confirmed before anything was changed, in two places.** At the wire level, arming the lossy
  proxy to drop exactly one datagram made `leave` overtake `join`: delivered `{"type":"leave"}` then
  `{"type":"join"}`, the reverse of the write order. At the consumer level, driving
  `handleRelayMessage` with that same reordering left the departed peer sitting in the roster —
  `delete` on an absent key is a no-op, so the late `join` re-adds someone already gone and nothing
  will ever remove them again. **Their ghost would stay on screen for the rest of the session.**
- **Reachability**: needs a join's first datagram lost *and* the peer leaving inside the ~6s
  retransmit budget (`retryInterval` 250ms × `maxRetries` 24). Rare, not theoretical — and silent,
  since every layer reports success.
- **Fixed at the transport, not the consumer.** A guard in `internal/core` would have been smaller
  but would have *corrected* the symptom while the cause kept running, which is the shape
  `adapters/_template`'s no-bandage rule names. `udpconn` now holds out-of-order payloads in a
  bounded window and releases them in sequence. Detail and the rejected options: the ADR in
  `architecture.md`.
- **Verification**: `dev-scripts/run-gotests.bat` green (build, vet, full suite twice, including
  `internal/e2e`), plus `-count=10` on `udpconn`, `core`, `relay` and `transport`. The race detector
  could not run locally — no C toolchain on this machine — so that remains CI's job, as CLAUDE.md
  already states.
- **Two pre-existing properties deliberately kept**: a buffered payload is not acked until actually
  delivered (the "ack only what was delivered" rule, which exists because `deliver` drops on a full
  queue), and window overflow declines to hold rather than dropping, leaving the sender's retransmit
  to cover it.

## quic became the default path, and shares the relay's port — 2026-08-16

**Established with the tools, not by watching a game.** Confirmed against real binaries on this
machine; no adapter or game involved.

- **The mismatch that prompted it**: the client's `-transport` defaulted to `udp` while the relay
  served `tcp` only, so *every* default session asked for something it could not have and fell back
  to tcp. The client's stated default was never honourable by a default relay.
- **Now**: client defaults to `auto`, relay to `tcp,quic`. Confirmed live —
  `core: relay offers tcp:7796, quic:7796 — using quic at 127.0.0.1:7796`, with the loopback ghost
  rendering throughout.
- **quic shares `-addr`'s port number** (`tcp:7796` and `quic:7796` above, tcp and udp being
  separate port spaces). This was a NAT decision: serving quic by default would otherwise have
  turned hosting from "forward 7777" into "forward 7777 and 7780". The relay now also prints
  `to accept players from outside this machine, forward: 7796/tcp (tcp), 7796/udp (quic)` at
  startup, protocol by protocol, because those are two separate rules on most routers.
- **Serving `udp` and `quic` together refuses to start**, with the actionable message rather than
  quietly relocating quic to a port nobody forwarded. Confirmed: *"serving both udp and quic needs a
  port for quic: udp has already taken 127.0.0.1:7794's udp port... Pass -listen-quic (e.g.
  127.0.0.1:7780)"*. `dev-scripts/run-relay-loopback.bat` is that case and now passes the flag.
- **What this does and does not buy.** Encryption against a passive observer, including the room
  code — but **not authentication**: `quicconn` uses a self-signed in-memory cert with
  `InsecureSkipVerify`. Also the only transport where `contract.md`'s lossy state plane is actually
  lossy, since on tcp `SendUnreliable` *is* `Send`. Both recorded in the ADR.
- **Verification**: `dev-scripts/run-gotests.bat` green (build, vet, full suite twice, including
  `internal/e2e`, whose transport tests set `-listen-quic` explicitly and were unaffected).

## The synthetic-peer rig could only ever test tcp — fixed 2026-08-16

`cmd/meshghost-fakeadapter` never set `core.Core.Transport` at all, so every synthetic peer
inherited `netx.Kind`'s tcp zero value. **Both load-test tiers in `dev-scripts/README.md` were
therefore tcp-only**, which is why the transports shipped that same day had no sustained-load
coverage — the rig structurally could not produce it. Added `-transport tcp|udp|quic|auto`, parsed
strictly like `cmd/meshghost`'s (a typo must not silently downgrade to the tcp zero value).
Confirmed: `-transport udp` through the new fault proxy logged `using udp`, dropped 43 of ~366
datagrams at a 10% loss setting, and kept rendering ghosts.

## The slide mesh offset is the engine's crouch path, and it is -(capsuleHalf + 1) — 2026-08-16

**Agent-established from a log read of a user's real session** (`SLIDE_MESH_PROBE`, 692 samples),
not watched on screen. The visual claims that follow from it are tracked separately.

This is the "START HERE" capture `ideas.md` specified for replacing the slide render-Z bandage.
The local player's `VisualMesh.RelativeLocation` against its `CapsuleHalfHeight`:

| State | `capsuleHalf` | `actionState`/`moveState` | mesh Z | samples |
|---|---|---|---|---|
| standing | 65 | 0 / 0 | **-66** | 410 |
| plain slide | 22 | 1 / 0 | **-23** | 43 |
| crouch, stationary | 22 | 0 / 2 | **-23** | 227 |
| other moves | 65 | 17 or 18 | **-66** | 12 |

**`meshZ == -(capsuleHalf + 1)` in every single sample, with zero variance inside a state.**

Three findings, none of them guessable from the code:

- **It is the engine's CROUCH path, not anything slide-specific.** A stationary crouch moves the
  mesh identically to a slide. `slideTick`/`slideOverheadCheck` — `ideas.md`'s lead 1 — were
  therefore never the lever, and were never tried.
- **Standing is -66, not -65.** The figure recorded up to now (`BANDAGES.md`, `ideas.md`, the
  `slide_z_comp` comment) was off by one. The +43 delta those documents cite is still exactly
  right: `-23 - (-66) = 43`.
- **The bandage had the right number on the wrong object.** It moved the ghost's whole actor to
  compensate for a mesh offset, which is why `Plugin.cpp` could describe a second bug as
  "structurally the same bug".

### Following it: the ghost fights back — 2026-08-16, same session

Reproducing that offset on the ghost's own mesh **works and is then undone**. `GHOST_MESH_Z_TRACE`,
reading back through a fresh lookup after the teleport rather than echoing the write:

```
peerHalf=22.0 desired=-23.0 readback=-23.0    <- the write lands
peerHalf=22.0 desired=-23.0 readback=-66.0    <- reverted, ~7ms (one tick) later
```

- **The first version of the fix cached what it had written and skipped re-writing when it
  matched** — so after the revert it saw "already -23" and never re-applied, and the ghost spent
  the whole slide at the standing offset. The optimisation was the bug, not the write.
- **The reverter is the ghost's own pawn maintaining a standing pose**: through every peer slide
  the ghost reads `ghostHalf=65 ghostCrouched=0` while the peer is at 22. That also explains the
  older failed attempt cleanly — it mirrored `CapsuleHalfHeight`, which is a *result* of crouching
  rather than the state that drives it.

### Three ways to pose a ghost's crouch, all NEGATIVE — 2026-08-16

Agent-established from trace reads; the two visual judgements are marked as the user's.

1. **Mirror `CapsuleHalfHeight`** (2026-08-15). Applied, readback 22, mesh never moved.
2. **Mirror `bIsCrouched`.** Applied — the same trace line read `ghostCrouched=1` — while still
   reading `ghostHalf=65` with the mesh at `-66`. The flag flipped and nothing followed it.
   **User-watched: still sinking.**
3. **Set `bWantsToCrouch`**, the input `ACharacter::Crouch()` itself sets, chosen because 1 and 2
   had both written *outputs* of the crouch machinery. **Refused: `bCanEverCrouch` reads false on
   the ghost's movement component**, so the request is correctly ignored and nothing downstream
   runs. **User-watched: still sinking.**

**The durable finding is (3): this game's slide is not an engine crouch at all.** It is the game's
own logic writing the capsule and the mesh offset directly — which is why every engine-level lever
is inert on a pawn nobody possesses, and why `slideTick`-style game logic, not another engine
function, is where any future attempt has to go (satisfying that logic's own preconditions, per
`ideas.md`'s PRECONDITION CLAUSE).

**A fourth option exists and was deliberately not shipped.** Writing the mesh offset ourselves
every tick does land, but something re-imposes `-66` about a tick later and the per-tick
re-assertion loses the race often enough to be visible — **user-watched: "the crouch was at varying
heights"**. That is worse than the compensation it was meant to replace, so the `+43` render-Z
compensation stays, now with its mechanism measured to the unit and its alternatives ruled out.
`SLIDE_MESH_PROBE` and `GHOST_MESH_Z_TRACE` are both off; the shipped runtime behaviour is
identical to before the investigation apart from the probe being disabled.

## The Pseudoregalia mod reconnects to a core started AFTER the game — 2026-08-17

**User-watched live AND agent-confirmed from logs** — the user ran the session specifically to see
whether it happened at all, and watched it connect in a running game; the log numbers below are the
same event measured. Noted because neither of us had seen this tested before and launch order was
reasonably assumed to matter.

The game was launched with no core and no relay running. The mod's bridge client retried in the
background, and when a core was started ~1 minute later it connected and ran normally:

```
bridge: connected=true connect_attempts=89 send_ok=9833 send_fail=0 lines_received=9831 lines_malformed=0
```

89 failed attempts, then a clean two-way round trip — sends *and* `lines_received` climbing together,
zero failures, zero malformed.

**Not luck, but not previously demonstrated either.** `adapters/_template/PROTOCOL.md` requires an
adapter to keep retrying, and `testing.md`'s trap list warns that an adapter missing that loop
"appears to work whenever the relay happens to start first and silently never recovers otherwise" —
this is the first time the recovery path itself was exercised end to end rather than assumed. It
also means the autostart path (`CoreLauncher`) and a hand-started core are interchangeable from the
mod's point of view: the launcher only spawns on a failed connect, so a core that appears by any
route is simply used.

Scope of the visual confirmation: the user watched the late connect take effect in the running
game. Nothing here claims a judgement about ghost *quality* through that connect — smoothness and
pose were not what this run was looking at.

## Slide/crouch pose: the render-Z bandage is GONE, replaced by the game's own path — 2026-08-17

**User-watched: "everything works now, and looks identical to the player."** The +43 render-Z
compensation is switched off (`GHOST_SLIDE_Z_COMP = false`) and the ghost is posed by the game.

### What the mechanism actually is

Five things, and **every one of them tested negative on its own** — the working configuration is
their union, which is the single most important fact here:

1. `GHOST_CAPSULE_MIRROR` — the peer's `CapsuleHalfHeight` on the ghost, re-read every tick.
2. `GHOST_SLIDE_TIMELINE_DRIVE` — `slide_t` (new wire field) carries the peer's point on the slide
   Blueprint Timeline's curve; the ghost's own track is written and `Timeline_1__UpdateFunc`, the
   Blueprint's own apply handler, is called.
3. `GHOST_CROUCH_INPUT_CALL` — `InpActEvt_IA_Crouch_..._16`, the Blueprint's own crouch input.
4. `GHOST_CROUCH_EVENT_CALL` — `K2_OnStartCrouch`/`K2_OnEndCrouch`, with the adjustment **latched
   when the crouch starts** (computing it on stand-up gives 0 and restores nothing).
5. `GHOST_CROUCH_CLEAR_ON_STAND` — `bIsCrouched` written symmetrically: set while the peer is
   short, cleared when they stand.

### The two findings that actually cracked it

- **The game maintains the mesh continuously from its own crouch state.** It forced -66 every tick
  before anything made the ghost crouch, and pinned -23 afterwards. That is why writing the mesh
  itself always lost, and why the fix is to move the *state* it reads.
- **The pose applied exactly ONCE, at the first stand-up**, then never changed — so later slides
  only looked right because the ghost was permanently crouched, standing sat 43 too high (the
  "snap"), and the first slide sank. One bug, three symptoms. Setting *and* clearing `bIsCrouched`
  on the peer's edges fixed all three.

### Dead ends, so nobody repeats them

Each of these applied successfully and changed nothing visible: `CapsuleHalfHeight` alone,
`bIsCrouched` alone *before* the ghost had ever crouched, `bWantsToCrouch` (refused —
`bCanEverCrouch` is false), `BaseTranslationOffset`, `slideTick` per tick, `UnCrouch`, `meshReset`,
`K2_OnEndCrouch` with a live-computed adjustment, and writing the mesh's `RelativeLocation`
directly (lands, then is overwritten within a tick; re-asserting it every tick loses the race
visibly).

**Method note.** Two user interventions did more than any single test: *"have we tried a run with
everything put together, if they need each other to work?"* — the working run had four mechanisms
live while I was testing three — and *"just dump everything"*, which produced all 473 pawn
functions and with them `Timeline_1__UpdateFunc`, a name no keyword filter of mine would ever have
matched. Recorded as a rule in `CLAUDE.md`.

## 2026-08-17 — Audit pass: three earlier entries superseded by later ones in this same file

- Date: 2026-08-17
- Confirmed by: a repo-wide documentation audit, cross-reading this file against itself. No new
  runtime facts here — this entry exists only because the file is append-only, so a superseded
  claim cannot be edited out and will otherwise keep reading as live.

**1. The first empty-hand recall glow entry is superseded by the second.** Two entries share the
title "Pseudoregalia empty-hand recall glow: FIXED by spawning the effect directly, confirmed
live". The earlier one says the glow attaches to the ghost's root and its position is visibly off,
and lists a second, unlocated "sword outline" glow as **still open**. The later entry corrects
both: the real effect attaches to the pawn's `WeaponMesh` at zero offset, and there was never a
second effect — the same one, mis-attached, is what read as an outline of the sword. **Nothing is
still open there.**

**2. The first thrown-Dream-Breaker / use-after-free entries are superseded the same way** — each
appears twice, and in both pairs the later entry is a rewrite, not a copy. Prefer the later one.

**3. "The Pseudoregalia camera fight-back is what takes the camera" (2026-08-16) is superseded**
by "A ghost brings its own camera rig, and that is what took the camera" (2026-08-16, later in the
file). The rig, identified by its `OwningActor`, was the cause. The fight-back's premise was
vindicated; its *rule* was the bug. The earlier heading is the misleading part — it is what a
reader scanning headings takes away.

**Convention going forward, from the same audit:** cite a file that lives outside this repo by
filename only, never with an absolute path. Several older entries here carry absolute paths to
external checkouts (a `pokeemerald` decomp, an Archipelago install, a Steam library, a CMake
install). They are harmless — no username in any of them — but unusable to a reader, and the rule
in `CLAUDE.md` is filename-only. Append-only means they stay; new entries should not add more.

### Pseudoregalia: killing a ghost leaves the real player at 0 health with no health bar

- Date: 2026-08-17
- Observed: user-watched, reported live. Two separate facts, both with
  `GHOST_COLLISION_ENABLED = true`:
  1. **Enemies can no longer hit the ghost.** This closes the enemy-damage vector that was
     confirmed open on 2026-08-15 (an enemy hitting a ghost could hurt and kill the real player).
     The fix that achieved it is re-typing the ghost's capsule as `WorldDynamic` so enemy
     targeting, which queries the Pawn object type, stops seeing it.
  2. **The real player can still hit the ghost, and killing it leaves the player respawning with 0
     / empty health.** The HUD itself is fine — the health bar is present and rendering normally,
     it is the health *value* that is 0 and stays 0 through the respawn. So this is a health-state
     problem, not a UI teardown problem. Still WIP; deliberate player-on-ghost melee remains an
     accepted footgun for now.
- Source: user observation on screen. `GHOST_COLLISION_ENABLED` (`Plugin.cpp:535`);
  the enemy-targeting fix is `call_set_collision_object_type` (`Plugin.cpp:1963`, `ECC_WorldDynamic
  = 1`); the hurtbox gate is `bCanBeDamaged = false` (`Plugin.cpp:5645-5647`).
- Notes: **The user's hypothesis is that the health itself is tied or shared between the player and
  the ghost.** It fits a standing puzzle: `bCanBeDamaged = false` is already shipped on the ghost
  and was found not to stop damage reaching the real player (`Plugin.cpp:1954`). If the ghost and
  the player resolve to the same health state, then a gate on the ghost's own `TakeDamage` path is
  irrelevant by construction — the damage never needed to travel through the ghost's damage path at
  all. The respawn detail sharpens it further: respawn evidently restores health on something that
  is not what the bar reads, or the shared value is simply never reset, which is what a single
  health state written to 0 by the ghost's death would look like. That the surviving vector is
  *player* melee rather than enemy damage is consistent too — enemy targeting was successfully
  routed around by re-typing the capsule, but the player's own attack resolves against the
  character directly. Not root-caused; this is the observation plus the lead. Ghost collision is
  being kept ON deliberately for further testing rather than switched off.

### The 2026-08-17 online-primitives work does not regress the cosmetic path (Pseudoregalia)

- Date: 2026-08-17
- Observed: user-watched, reported live — "the ghost appears fine, seems things still work
  properly" in a loopback session over quic, with the game's own mod build unchanged and the Go
  client/server built from `e3b924a` (the commit adding the event, lease, escrow, snapshot,
  resumption and clock-sync planes, plus the UTF-8 identifier fix).
- What this settles: the whole of that work is **inert by default**, on screen and not just in
  principle. The claim needed a real game because the changes touch code every ghost depends on —
  `forwardLocalState`'s timestamp is now `nowMs()`, `tickRenders`' render time is derived from the
  same clock, and `ValidateState` gained a UTF-8 check — so "opt-in" had to be demonstrated rather
  than asserted.
- Source, agent-read from the logs alongside the user's own observation:
  - The core logged **no** "negotiated capabilities" line at connect. That line prints whenever a
    room agrees on any capability, so its absence is the positive evidence that the room negotiated
    the empty set and every new code path stayed unreachable for the whole session.
  - The mod's own counters at teardown: `connected=true send_ok=5403 send_fail=0
    lines_received=5386 lines_malformed=0`. Zero malformed lines matters specifically because the
    UTF-8 check now runs on every `area_id` and `anim`; a mangled or rejected state would have
    shown up here.
  - `remote p1-ghost redraw: intended=(...) actual=(...)` with the two equal, and the slide/crouch
    pose path (`K2_OnStartCrouch` / `K2_OnEndCrouch`, `fired=true`) still firing — so the ghost was
    not merely present but posing through the game's own systems.
- Notes: loopback, so this confirms one client's full core -> relay -> core -> adapter round trip,
  not a two-machine session. Clock sync in particular is **untested against a real peer with a
  genuinely skewed clock** — it is off unless a room negotiates `clock.v1`, which nothing does, so
  what this session shows is that leaving it off costs nothing. The heavy per-frame TRACE probes
  were on in this build; per CLAUDE.md's probe rule that makes the *timing* here unrepresentative,
  which is fine because nothing about timing was being claimed.

### Session resumption, clock sync and the capability scope split, confirmed against real binaries

- Date: 2026-08-17
- Observed: agent-run, from process logs — no game involved, so this is the `internal/core` /
  `internal/relay` side that CLAUDE.md puts on the "confirm with the tools yourself" footing.
- **Resumption works end to end.** With `-resume-grace=60` and the link cut by killing
  `meshghost-netsim` mid-session (so both ends saw a real close) and then restored: relay logged
  `p1 dropped from room "default" — holding its identity for 1m0s`, then 7 seconds later the core
  logged `resumed the previous session as p1 — the room was never told we left` and the relay
  `p1 reconnected to room "default" and resumed its session`. Same `player_id` across a real
  disconnect, no `leave` broadcast.
- **Capability scoping behaves as designed, in the shipped binaries.** Against a room whose first
  member advertised `clock.v1,resume.v1`: a client advertising only `clock.v1` was **admitted**
  (differs solely in the client-scoped half) and its Welcome correctly reported `[clock.v1]` — not
  the room's full set — while a client advertising only `resume.v1` was **refused** with
  `feature set mismatch for this room`, missing the room-scoped `clock.v1`.
- **Drop detection is transport-dependent, and it dominates the grace window.** A hard-killed
  client was noticed by the relay in the same second on `tcp` (the OS sends an RST) and after
  **~17 seconds** on `quic`, where a killed peer sends no close frame and the connection lingers
  until quic's idle timeout. So a crash on the default transport freezes that ghost for roughly
  17s *plus* whatever `-resume-grace` is set to. `quicconn.quicConfig` sets no `MaxIdleTimeout`
  at all, which is the lever, and is left open.
- **A tcp session survived a 25-second total link partition without disconnecting.** Its read
  deadline is 60s, so short outages never reach resumption there at all. Resumption earns its keep
  on quic and on outages long enough to actually break a connection.
- **Two limits are structural, not bugs.** Killing the client *process* loses the resume token
  (it is in memory) so the next launch joins fresh — confirmed live, and correct, since a closed
  game should be a real leave. A relay restart likewise loses every session. Nothing is persisted
  to disk anywhere by design.
- Notes: found while wiring this up rather than by testing it afterwards — registering a session
  only on disconnect meant a resume worked *solely* when the relay had already noticed the drop,
  which on quic it usually has not. The fix (register on token issue, allow takeover of a live
  session) is in the ADR. **Clock sync is still unverified against a genuinely skewed peer** — that
  needs two machines with deliberately different clocks, which is what
  `dev-scripts/run-core-pseudoregalia-online.bat` step 3 is for.

### Two transport-divergence bugs, found by a loopback re-test and the suite it prompted

- Date: 2026-08-17
- Observed: agent-run from process logs and tests; the trigger was a user-watched loopback session.
- **A clean game-close was being treated as a network blip.** With `resume.v1` on, quitting the
  game made the relay log `p1 dropped from room "default" — holding its identity for 20s`, so every
  other player would have watched a frozen ghost for the whole grace window. The core discarding
  its own resume token was never enough: that only decides where the NEXT connection lands and says
  nothing to the relay about this one. Fixed by a voluntary `leave` sent client -> relay before a
  deliberate hangup. An unexplained drop still gets the grace, which is the whole point.
- **`quicconn.Close()` discarded the last message written before it.** It closed the stream and
  tore down the QUIC connection in the same breath; closing a stream only signals FIN, and the
  bytes cannot be delivered once the connection is gone. Confirmed by the goodbye above landing on
  tcp and vanishing on quic, and by the regression test failing when the fix is reverted.
  **This silently broke every send-before-close in the project on quic** — including the relay's
  `Reject`, so a client refused for a wrong room code saw a bare hangup instead of the reason,
  which is the entire thing `rejectAndClose` exists to prevent. Fixed with a bounded linger before
  the connection teardown; `Close()` itself still does not block.
- **A third divergence, found by the new conformance suite on its first run and NOT fixed:** udp
  signals nothing on close, so a peer waits out `transport.DefaultIdleTimeout` (60s), against an
  immediate RST on tcp and ~17s on quic. Left as a documented skip with the consequence named,
  because the fix is a new control frame in the project's most exposed parser and deserves its own
  pass. The goodbye above covers the common case there regardless.
- Notes: the first bug was found only because the user asked "no need to test loopback?" after I
  had moved on — the earlier on-screen confirmation was against an older build, and the join and
  close paths had changed under it since. Worth recording as a methodology point, not just a bug:
  **a confirmation is against a build, not against a project**, and it goes stale the moment the
  code it covered changes.

### Pseudoregalia: a ghost's slide pose CYCLES instead of holding, and it is not a latency problem

- Date: 2026-08-17
- Observed: user-watched across two loopback sessions — "it did feel like slides were a bit
  slow/delayed", and then, at a lower interpolation delay, "still feels like slide lags behind a
  bit / delayed". Position and facing felt instant in both.
- **The symptom is not lag, it is repetition.** Measured from the mod's own log: across one
  continuous player slide (local `actionState=1` sampled four times between 12:54:46 and
  12:54:50), the ghost fired `K2_OnStartCrouch` **and** `K2_OnEndCrouch` four times — starting a
  crouch roughly every 0.75-0.9s and ending it in between. The ghost is re-entering the pose
  repeatedly rather than holding it for the duration of the slide, which reads as "late" or "not
  quite right" rather than as flicker.
- **Not caused by interpolation.** The cycle period was materially the same at `-interp=250ms` and
  at `-interp=100ms`. A delay would scale with that setting; this does not.
- **Not caused by any of the 2026-08-17 Go work.** The installed mod DLL dates from 04:56 that
  day and its source was last committed at 03:57 — both before the online-primitives work began.
  The clock-sync capability was ON for the second session and shifts every timestamp uniformly, so
  it cannot single out one animation either. Position and facing ride the same state message and
  were reported instant.
- Likely mechanism, NOT confirmed: the game's own crouch/slide is a timed action driven by a
  Blueprint Timeline (`SLIDE_TIMELINE_TRACK`, `Timeline_1`), so it runs to completion and ends on
  its own; the adapter then re-asserts it, producing the cycle. That would make holding a ghost in
  a slide a fight with the game's own timeline rather than a missing input.
- Notes: deliberately not "fixed" on this evidence. The slide pose is the adapter's hardest
  feature, its five pose mechanisms are documented as required *together* ("do not simplify this"),
  and the neighbourhood already has a `BANDAGES.md` "do NOT fix these" entry. A change here costs a
  DLL rebuild, a deploy, and another live session, so it wants a stated hypothesis and one
  measurement, not a guess.

### Pseudoregalia: a held slide re-triggers every ~600ms, and the capsule really does stand up between repeats

- Date: 2026-08-17
- Observed: agent-read from `GHOST_MESH_Z_TRACE`'s `peerHalf` column during a user-played loopback
  session. **In loopback the peer is the player** — the ghost's state is the player's own, echoed
  back — so that column reads a real player's own capsule directly, which is what made this
  measurable at all without a second machine.
- **The measurement**, 53 transitions in one session:
  - Capsule at the sliding value (22.0): mean **624ms**, tightly clustered around ~600ms.
  - Capsule at standing (65.0): **sharply bimodal** — 14, 20, 36, 70, 70, 153ms, then nothing
    whatsoever until 244ms and up.
  - So a held slide is a fixed ~600ms action that re-triggers, with a genuine few-tens-of-ms
    stand-up in the seam between repeats.
- **This settles the fork** left open earlier the same day: the local capsule genuinely oscillates,
  and the adapter's read of it is correct. The ghost was mirroring reality and looked wrong for it,
  because a player's mesh is animation-blended through the seams while a ghost is posed discretely
  through the game's crouch system, which cannot complete a transition inside 14ms.
- The fix shipped is `SLIDE_SEAM_HOLD_MS` (200ms, in the empty band between the two populations),
  recorded as a bandage in `adapters/pseudoregalia/BANDAGES.md`.
- **CONFIRMED on screen, user-watched, and at a clean baseline**: *"the slide was fine now during
  the run that crashed, felt 1:1 to the player again."* That run was the `-interp=0ms` session, so
  the judgement was made with **no interpolation delay in the way** — which matters more than
  usual here, because every earlier report of the slide "feeling delayed" was made through 100ms
  or 250ms that the launcher had introduced (see the dev-script 1:1 rule). This is the first read
  of the slide against an honest baseline, and it passes.
- The instrumented side agreed independently in the same build: crouch durations went from a
  uniform ~600ms to 813/2360/819/1459ms, i.e. consecutive slides merging into one held pose, with
  the remaining start/end pairs corresponding to genuine stand-ups (an 84ms gap between ghost
  events implies a ~284ms real stand-up, above the measured 244ms floor).
- Notes: the Go side had already been cleared by test rather than by argument
  (`TestOpaqueFieldsNeverFlapAcrossInterpolation` — an opaque field that changes once across
  interpolation changes once), which is what narrowed this to a single question with two opposite
  answers and made one probe enough.

### Pseudoregalia: a hard crash mid-session, and the discovery that we ship six unnecessary UE4SS mods enabled

- Date: 2026-08-17
- Observed: user-reported live. The pause menu opened **twice** and could not be closed, then the
  game died with `EXCEPTION_ACCESS_VIOLATION`. The stack is ~25 repetitions of one address pair,
  the shape of a recursive widget/UI traversal rather than anything resembling our own call sites.
  Not the 2026-08-16 transition crash, and not the known on-exit `Fatal Error!` — this was
  mid-play.
- **Not attributable to MeshGhost on the evidence available**, and two specific hypotheses are
  dead:
  - *The ghost pressed pause.* It cannot. The ghost is spawned unpossessed with null
    `Controller`/`InputComponent`, and `AutoPossessPlayer` is cleared on the class default object
    **before** `SpawnActor` precisely so it cannot take the controller.
  - *Our riskiest call smashed memory.* `GHOST_CROUCH_INPUT_CALL` invokes the game's own Enhanced
    Input crouch handlers, which the source flags as the highest-risk thing the adapter does — but
    `call_named_no_arg` sizes its parameter buffer from `function->GetPropertiesSize()`, the
    function's real size, not a hand-guessed one, so it cannot overrun. Timing is against it too:
    the last crouch input fired **83 seconds** before the crash, and MeshGhost's final log lines are
    ordinary position updates and bridge counters.
- **What the investigation did turn up is a shipping defect of our own.** The user believed the
  other UE4SS mods came with the game; they do not — Pseudoregalia ships no UE4SS at all.
  **Our own release package stages the UE4SS runtime and its stock mods, enabled**, so installing
  "just the online mod" silently adds a cheat manager, a console, console commands, keybind hooks,
  an actor dumper and a line-trace tool to the player's game. Two of those hook keyboard input and
  one enumerates actors, which makes them live suspects for an un-closeable menu in a way MeshGhost
  is not.
- **The two loader files also disagreed**: `mods.txt` had `ActorDumperMod : 1` while `mods.json`
  had it `false`, and that mod's script failed to execute in this very session
  (`The size for property 'ArrayProperty' was unknown`). Both files now agree.
- Fixed by disabling every stock Lua mod in the shipped package except the Blueprint-loader pair.
  **This costs MeshGhost nothing**: `MeshGhostPseudo` appears in neither loader file, because C++
  mods are auto-loaded from the folder. Not yet re-tested live.
- Notes: the crash itself is **not root-caused and is not claimed to be fixed**. One occurrence
  with no clear trigger is not actionable; what this does is remove a whole class of input and
  enumeration suspects, so a recurrence is genuinely informative about MeshGhost rather than
  ambiguous. Especially worth having for the Linux tester, who is a speedrunner — a cheat manager
  and a console are not things to put in a runner's game uninvited.

### The loopback offset manufactures positions real multiplayer never produces

- Date: 2026-08-17
- Observed: user, live, while investigating the crash above — the ghost behaved oddly on a
  downward ramp mid-slide, and they identified the cause themselves as the loopback offset rather
  than as a sync fault.
- **The insight, which outlives the incident:** a peer's coordinates in a real session are always a
  position that peer was actually standing in, so a ghost placed there is by construction somewhere
  the game considers valid. The loopback offset breaks that. It takes a valid position and shifts
  it 150 units sideways (`LOOPBACK_GHOST_OFFSET_X`) **without re-grounding it**, so over any sloped
  or uneven geometry the ghost lands buried in the floor or hanging above it.
- **Why that is not a harmless rendering artefact here.** The ghost is a real pawn clone with
  collision deliberately enabled and the game's own movement systems running on it (`slideTick`,
  the crouch path, the capsule mirror). So the game is being asked to resolve a moving body inside
  world geometry — depenetration, ground checks, slide physics — in a state it would never
  otherwise be put in. That is a plausible source of instability that **exists only in the test
  rig**, and the user's own reading is that the game "dislikes being inside/under the ground".
- **Consequence for how loopback evidence is weighed:** an anomaly seen only in loopback, in a
  position that only the offset could have produced, is a rig artefact until shown otherwise. It
  should not be chased as a sync or adapter bug, and it must not be used to judge whether ghosts
  behave correctly. This applies to the crash recorded above, which was hit immediately after
  exactly such a moment and remains unexplained and not reproducible.
- **The obvious "fix" is rejected, by the user, the same day it was proposed.** Offsetting UP
  instead (`LOOPBACK_GHOST_OFFSET_Z`, which exists and is 0.0) would keep a self-ghost clear of
  geometry and remove this confounder — and it is still the wrong trade: *"moving the ghost up/down
  would only make it worse/harder to spot 1:1 differences."* A sideways offset puts ghost and
  player side by side **at the same ground level**, which is what makes pose and timing directly
  comparable; vertical separation puts them at different heights and obscures exactly the
  differences the rig exists to reveal. The horizontal offset stays as it is. See
  `adapters/pseudoregalia/BANDAGES.md`'s do-not-fix list.

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

### World custody (`world.v1`) — the relay holds a world it cannot read, and hands it on

- Date: 2026-08-17
- Established with the Go tools, not on screen: no adapter uses this plane and no game was
  involved. Recorded under CLAUDE.md's "the Go client/server is the opposite case" rule.
- **What was confirmed.** `dev-scripts/run-gotests.bat` green (build, vet, the whole suite twice,
  including `internal/e2e`), plus `internal/relay` and `internal/core` at `-count=10`. The race
  detector could not run locally (no cgo toolchain here, as CLAUDE.md already notes); CI covers it.
- **The end-to-end proof is `TestWorldSurvivesTheHostProcessDyingAndSeedsALateJoiner`**, which
  drives the real `meshghost.exe` and `meshghost-relay.exe`: a host writes two entities, its
  PROCESS is killed outright (no goodbye, no release), a second client claims the authority and is
  handed the same world byte-for-byte, and a third client that was never present joins and sees the
  current world. That is the scenario the feature exists for and the one no in-process test can
  reach.
- **Soaked under real loss.** `cmd/meshghost-fakeadapter` with `-host-entities 5 -migrate-every 2s`
  through `cmd/meshghost-netsim` at 5% loss / 5% reorder / 20ms latency over udp: 4 clients, all
  four planes on at once (events, leases, escrow, world), 2 minutes, 40 handovers, ~5000 entity
  writes, **no invariant violations**. The same run on tcp and on lossless udp was also clean.
- **The soak found two things reading did not**, both adapter-facing rules rather than relay bugs,
  and both of which passed cleanly on tcp first — the shape of thing that ships:
  1. **A lossy write replaces the whole blob**, so a blob mixing a continuously-superseded field
     with one that must not regress gets dragged backwards wholesale by an inbound reorder, and the
     relay's copy becomes the stale one that later snapshots propagate. Discrete state and
     continuous position belong on separate keys. The rig now models that.
  2. **An adoption must always send exactly one snapshot, empty world included**, or a new host
     cannot tell "nothing to adopt" from "my adoption has not landed yet" — and a host that guesses
     wrong renumbers from a stale view and rolls the world back for everyone.
- Two checker bugs were also found and fixed, both of which had accused a correctly-behaving relay:
  a lease *renew* re-broadcasts `granted` (so arming adoption on any grant was wrong), and the
  rig's exclusivity check tracked one holder across all keys, which only worked while one key
  existed.
- Detail: the ADR in `architecture.md` (2026-08-17, world custody), `contract.md`'s World custody
  section, and `internal/relay/world_test.go`, whose four "corrections" tests fail against the
  obvious implementation.

### A maximal event and a committed escrow are too large for a udp datagram (pre-existing, not fixed)

- Date: 2026-08-17
- Established by measurement while deriving the world plane's bounds, not by a failure in the
  field: a maximal `Event` marshals to **1321 bytes** and a committed `EscrowState` carrying two
  1024-byte blobs to **2294**, against 1182 usable (`udpconn.MaxDatagramBytes` 1200 minus 18 bytes
  of framing). Both fail `udpconn.checkWritable` — reliable plane included — and the refusal is
  only a `relay: send to pX failed:` log line, so the message is lost for that recipient and never
  superseded.
- Unreached today: nothing uses these planes at all. Recorded in `risks.md` as its own decision
  rather than fixed here, because shrinking the constants is a contract change.

## 2026-08-17 — The Go packages moved out of `internal/` and the module took its real path

**Track: agent-confirmed** (Go side — established with the tools, no game and no watching, per
this file's own two-track rule).

**What is now true.** The module is `github.com/Tsukino-uwu/MeshGhost`, and `protocol`,
`transport`, `bridge`, `core`, `relay` and `netx` (with `netx/udpconn`, `netx/quicconn`) live at
the repo root and are importable from outside. `internal/` holds `e2e` and nothing else. Design
and rationale: the 2026-08-17 ADR in `architecture.md`.

**How it was confirmed.**
- `go build ./...`, `go vet ./...`, and `go test -count=2 ./...` all clean, including
  `internal/e2e` (68.7s), which builds and launches the real `meshghost-server.exe` and
  `meshghost.exe` **by package path** — the only check that exercises the two build-path string
  literals, since those are not compile-checked.
- `go test -count=10 -shuffle=on -cpu=1,4` clean across `relay`, `core`, `transport`, `netx`
  (relay alone: 254s), per `CLAUDE.md`'s repeat-the-suite rule.
- **A throwaway module outside the repo**, with a `replace` directive, imported all six packages
  by their new paths, compiled, and ran — printing `protocol.Version`, a `core.Core` field, a
  `relay.Server` field and a `netx` kind. This is the only check that actually demonstrates the
  goal; the existing suite passes identically with the packages still private, so a green suite
  is not evidence for this claim.
- `git diff -M -C` showed the change as renames plus one-line import edits: 472 insertions
  against 471 deletions across 76 files, with no logic hunk anywhere.

**Reading older entries in this file.** Entries dated before 2026-08-17 name packages as
`internal/<pkg>/…`. Those map 1:1 to `<pkg>/…` — drop the `internal/` segment. **`internal/e2e`
did not move.** This file was deliberately not swept: it is a dated record, and rewriting a past
observation to match a later layout would falsify it. The same applies to `agent_docs/phases/`.

**Not covered by this entry.** Nothing about behaviour changed, so nothing here is a claim about
runtime behaviour beyond "the same tests still pass". No adapter was touched, built, or run.

## 2026-08-17 — The double pause menu recurred, and this time did NOT crash

**Track: human-gated** — user watched it and supplied a screenshot: the title screen's PRESS START
and the in-game pause menu (RESUME / OPTIONS / RESET TO LAST SAVE / MAIN MENU / QUIT) drawn at the
same time, after returning to the title to reload a save.

**Why this matters.** The earlier entry in this file ("a hard crash mid-session, and the discovery
that we ship six unnecessary UE4SS mods enabled") recorded the double menu and an
`EXCEPTION_ACCESS_VIOLATION` together, in one report. They were therefore one observation, and it
was open whether the duplicated menu was simply the first visible symptom of whatever crashed.
**It is not.** The menu duplicated and the session continued normally — so the two are separable,
and any explanation that requires them to be the same fault is wrong.

**What was running.** MeshGhost's own mod, plus eight stock UE4SS Lua mods enabled on this machine
— `[Lua] [CheatManagerEnabler] Constructed CheatManager / Enabled CheatManager` appears in this
session's `UE4SS.log`, as it did in the crash session. `Keybinds` is among them and hooks input,
which is the standing suspect for a menu that opens twice; MeshGhost's ghost is spawned
unpossessed with a null `Controller`/`InputComponent` and cannot press anything.

**Correction to the earlier entry's "we ship them" claim, established 2026-08-17 while writing
this one:** we do not, any more. That defect was real and was closed the same day by
`95b88f9` ("Stop shipping a cheat manager, a console and keybind hooks into players' games"); the
package now contains only `Mods/MeshGhostPseudo` and the runtime, with **no `mods.txt` at all**.
The eight enabled here come from this machine's own UE4SS install. Two consequences: a player
installing MeshGhost today does not get them, so this symptom is **not** something the release
inflicts; and the enablement mechanism is `Mods/mods.txt` (`Name : 1`) for Lua mods, NOT the
`enabled.txt` file C++ mods like ours use — an earlier sentence in this file saying the fix is "a
directory of `enabled.txt` files" is wrong for the stock mods specifically.

**Not established**: the cause. Nobody has yet run Pseudoregalia with the stock mods disabled and
tried to reproduce this, which is the obvious next experiment and is cheap — it is a directory of
`enabled.txt` files, not a rebuild. Until that is done, "the stock mods do it" remains a
hypothesis with motive and opportunity, not a finding.

**Scope**: seen on the loopback rig (relay `-loopback -send-hz=100`, core `-interp=0ms`), one
occurrence, during a return to the title screen for a save reload.

**Lead, user-supplied and explicitly NOT yet confirmed:** the user's impression is that this
happens when the pause menu is used **with a gamepad**, and that they have not seen it while
using the mouse. Recorded verbatim as an impression — "think" and "don't think I have seen",
across sessions, with no deliberate A/B — because it is the first reproduction handle this
symptom has had, and it is cheap to test properly: open and close the pause menu N times on
gamepad, then N times on mouse, same session, same area.

It also sharpens the stock-mods hypothesis rather than replacing it. The suspect mods hook
**keyboard** input, so a gamepad-only symptom would point at either the game's own input handling
or a device path those hooks disturb indirectly — and a clean mouse-only run would be evidence
against the simplest version of "the stock mods do it".

**The hypothesis that should be tested FIRST is that this is a vanilla Pseudoregalia bug.** A
pause menu that opens twice on gamepad input is an ordinary UI-input bug shape, it needs no mod to
explain it, and **nothing observed so far distinguishes vanilla from mod-caused** — because the
game has never been run unmodded and pushed at this. That test is cheaper than every other one
here: no rebuild, no relay, no rig. Launch Pseudoregalia with UE4SS absent (rename `dwmapi.dll`),
open and close the pause menu on a gamepad until it either duplicates or convincingly does not.

Order the work accordingly: vanilla first, then stock-mods-only (UE4SS present, MeshGhost's own
`enabled.txt` removed), then MeshGhost. Testing ours first would be the expensive end of the
ladder for the least likely cause, and a negative there would prove the least.

## 2026-08-17 — A relay that dies leaves every ghost frozen in place, for up to 60 seconds

**Track: human-gated** — user watched it and supplied a screenshot: the ghost frozen mid-jump near
the ceiling, sword still in hand, while the player stood below. The user had deliberately been
jumping so any change would be easy to spot.

**What was done.** Loopback rig (relay `-loopback -send-hz=100`, core `-interp=0ms`, both from
`dev-scripts`), user in a single zone, ghost visible. The relay process was killed outright
(`Stop-Process -Force`) at 21:25:36.876 — not a peer leaving, a server dying.

**What happened.** Nothing, visibly, for the ~18 seconds the user watched. The ghost held the
exact pose and position it had at the moment the relay died. `UE4SS.log` has **no `releasing
remote` line** in that window, so no `despawn_remote` ever reached the adapter: `release_ghost`
never ran, and neither the park nor the new destroy path was involved at all.

**Whether it would EVER have despawned on its own is untested.** The user then closed the game —
the `LoadMap PRE` at 21:25:54 is that quit, not a mid-play level change, and an earlier draft of
this entry wrongly read it as the level reclaiming the ghost. Nothing here reached the 60-second
timeout below, so "the ghost is frozen for up to 60s and then goes" is the *predicted* behaviour
from reading the code, **not an observed one**. What is observed is 18 seconds of a frozen ghost
and no despawn. Someone should sit through the full minute before that prediction is trusted.

**Why.** The core reaches the relay over **quic** here (`run-core-pseudoregalia.bat` passes no
`-transport`, so `auto` prefers quic), and a killed server is not an orderly close. Nothing
notices until `transport.DefaultIdleTimeout` — **60 seconds** — expires. Until then the core still
believes it has a relay, so it has no reason to drop remotes, and `dropAllRemotes` (core.go, in
the `OnDisconnect` handler under its `wasCurrent` guard) is never reached.

**Why it matters beyond the rig.** This is a real user-facing case, not a testing artefact: a host
whose relay crashes, or who closes it, leaves every peer staring at a frozen statue of them for up
to a minute. It is also strictly worse than the case the DESPAWN_PARK_Z bandage was written for —
that one at least parks the ghost out of sight.

**What this test did NOT establish.** It was set up to exercise the park's own case — a peer
leaving *mid-area* — and it does not. A peer leaving sends a leave that the relay forwards, giving
a prompt `despawn_remote`; killing the relay removes the thing that would deliver it. **The
mid-area despawn path remains untested**, and needs a second real peer
(`cmd/meshghost-fakeadapter` in the same room and area) that can be stopped cleanly.

## 2026-08-17 — Mid-area despawn destroys the ghost cleanly, and a peer's ghost is genuinely the PEER

**Track: human-gated** — user watched both, on a real two-client session (the real game plus
`cmd/meshghost-fakeadapter` as a second peer in the same room and area).

### 1. The despawn path the park was written for finally ran, and destroy handled it

Setup: plain relay (no `-loopback`), core via `dev-scripts/run-core-pseudoregalia.bat`, and a fake
peer circling the player at radius 180. The peer was stopped with `Stop-Process -Force`, which
drops its connection and makes the relay forward a real leave — so the core emits a genuine
`despawn_remote` with **no level transition behind it**. That is the case
`DESPAWN_PARK_Z` exists for, and until now every attempt to produce it had failed.

Peer stopped at 22:01:51.791. 60 ms later:

    22:01:51.851  releasing remote p5: ghost=0x16232a13340
    22:01:51.852  GHOSTDESTROY p5: K2_DestroyActor was reflected and called

**User: "yes the ghost went away."** The game kept running. So with
`GHOST_DESTROY_ON_DESPAWN = true`, a mid-area despawn destroys the ghost, it disappears on screen,
and there is no crash — including no `Fatal world leaks detected`, the failure this was most
suspected of. Together with the zone-transition runs earlier the same day, both despawn paths are
now covered.

### 2. A peer's ghost shows the PEER's appearance, not the local player's

`status.md` had carried this since 2026-08-16: *"A fresh ghost shows the LOCAL player's state, not
the peer's. Two fixes shipped 2026-08-16, never verifiable in loopback."* It was unanswerable by
construction — in loopback the peer IS the local player, so "did it read the peer or copy me"
has no observable difference.

This is the first non-loopback peer this adapter has ever rendered. The fake peer sends no outfit
or weapon extras, and its ghost appeared with **default appearance** — user, verbatim: *"loopback
always showed what i had, this one showed was a 'fresh no save other player had'"*. The ghost is
built from the peer's state, not the local save. **The 2026-08-16 fixes are confirmed working**,
and the item can come off `status.md`.

**Worth keeping as a method note:** a synthetic peer is not only a load-test tool. It is the only
way to answer any question of the form "is this the peer's data or mine?", because loopback makes
the two identical. Reach for `cmd/meshghost-fakeadapter` whenever that distinction matters.

## Pokémon Crystal — access-model groundwork (2026-08-17)

Scoping only; no adapter exists and none is scheduled. Every fact below was established by the
agent with local tools (hashes, a build, a symbol table) — none of it is a claim about anything
seen on screen, and none of it needed the user to watch.

### Crystal ROM revision, and the decomp build matches it byte-for-byte

- Date: 2026-08-17
- Observed: a three-way SHA1 match. The user's ROM
  (`Pokemon - Crystal Version (USA) 1.0.gbc`, 2,097,152 bytes) hashes to
  `f4cd194bdee0d04ca4eac29e09b8e4e9d818c133`; a local `make` build of `pret/pokecrystal` at
  `master` produced a `pokecrystal.gbc` with that same hash; and `pokecrystal`'s own `README.md`
  documents that hash for `Pokemon - Crystal Version (UE) (V1.0) [C][!].gbc`.
- Source: `pret/pokecrystal` `README.md` L7; `sha1sum` on both ROMs.
- Notes: this is Crystal's equivalent of the `make compare` gate recorded for pokeemerald above,
  and it is what makes every address below authoritative for the ROM actually being played rather
  than merely plausible. `pokecrystal`'s `README.md` lists four other targets (V1.1, the
  Australian release, and two PS3 VC images) with different hashes — **addresses from this build
  are valid for V1.0 only**, and a different revision needs its own build.

### Crystal player and map addresses

- Date: 2026-08-17
- Observed: `grep` over `pokecrystal.sym`, generated by the hash-verified build above. Addresses
  are `bank:offset`, GB WRAM being banked:

  | Label | Address |
  | --- | --- |
  | `wMapGroup` | `01:dcb5` |
  | `wMapNumber` | `01:dcb6` |
  | `wYCoord` | `01:dcb7` |
  | `wXCoord` | `01:dcb8` |
  | `wPlayerDirection` | `01:d4de` |
  | `wPlayerStruct` / `wObjectStructs` | `01:d4d6` (same address) |
  | `wPlayerState` | `01:d95d` |
  | `wPlayerBGMapOffsetX` / `Y` | `01:d14c` / `01:d14d` |
  | `wPlayerStepDirection` | `01:d151` |
  | `wMapObjects` | `01:d71e` |

- Source: `pret/pokecrystal` build artifact `pokecrystal.sym`; label declarations in
  `ram/wram.asm` (`wMapGroup`/`wMapNumber`/`wYCoord`/`wXCoord` are four contiguous bytes, declared
  consecutively in the `"More WRAM 1"` section).
- Notes: **`wMapGroup`..`wXCoord` being four contiguous bytes is a useful fingerprint** if these
  ever need confirming against a running game rather than trusted from the table.
  **Not yet confirmed:** which BizHawk memory domain exposes bank 1, and whether the Gambatte and
  SameBoy cores agree on domain naming — that is a `memory.getmemorydomainlist()` probe and has
  not been run. Until it is, the *addresses* are authoritative but the *way to read them* is not.

### GB/GBC decomps must be built to yield addresses at all

- Date: 2026-08-17
- Observed: `ram/wram.asm` in `pokecrystal` declares floating sections
  (`SECTION "More WRAM 1", WRAMX`) with no address, so no RAM address appears anywhere in the
  source text; addresses exist only after `rgblink` runs.
- Source: `pret/pokecrystal` `ram/wram.asm`.
- Notes: a structural difference from `pokeemerald`, where reading the C plus a built `.map` were
  both options. For GB titles the build is not optional. Toolchain details in `environment.md`.

## Pokémon Red/Blue, FireRed, Platinum — access-model groundwork (2026-08-17)

Same scoping pass as the Crystal section above, extended to the rest of the user's Pokémon ROMs so
the facts exist before any of them is picked up. No adapter exists for any of these and none is
scheduled. All established by the agent with local tools; nothing here is a visual claim.

### Red and Blue: both ROMs match, and one build produces both

- Date: 2026-08-17
- Observed: the user's `Pokemon - Red Version (USA, Europe) (SGB Enhanced).gb` hashes to
  `ea9bcae617fdf159b045185467ae58b2e4a48b9a` and `...Blue Version...gb` to
  `d7037c83e1ae5b39bde3c30787637ba1d4c48ce2`. A single local `make` of `pret/pokered` at `master`
  produced `pokered.gbc` and `pokeblue.gbc` with exactly those two hashes, and `pokered`'s own
  `README.md` documents both.
- Source: `pret/pokered` `README.md` L7-L8; `sha1sum`.
- Notes: same rgbds v1.0.3 toolchain as pokecrystal, no extra setup. Build ~2 min.

### Red and Blue are byte-identical in RAM — one adapter covers both

- Date: 2026-08-17
- Observed: comparing `pokered.sym` and `pokeblue.sym` from the verified builds above — of 21,128
  symbols each, 20,460 are identical and 668 per side differ. Restricting to **WRAM** labels
  (`00:c***`/`00:d***`), **all 2,624 are identical, with zero differences.** The key four agree
  exactly: `wCurMap` `00:d35e`, `wYCoord` `00:d361`, `wXCoord` `00:d362`,
  `wPlayerDirection` `00:d52a`. Also `wSpriteStateData1` `00:c100`, `wWalkCounter` `00:cfc5`,
  `wPlayerMovingDirection` `00:d528`, `wCurMapHeight`/`wCurMapWidth` `00:d368`/`00:d369`.
- Source: `pret/pokered` build artifacts `pokered.sym` and `pokeblue.sym`.
- Notes: **this answers whether Red and Blue need separate handling: for our purposes, no.** The
  668 differing symbols are all ROM-side (species data, sprites, text) — the parts a *randomizer*
  cares about and a presence adapter does not. One address table, no per-version branching.
  Independently corroborated by Archipelago's own structure: `worlds/pokemon_rb` is a single world
  with logic shared, but ships **two** patch files (`basepatch_red.bsdiff4`,
  `basepatch_blue.bsdiff4`) — separate ROM patches, shared everything else, exactly the split the
  symbol diff predicts.

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

### Platinum: ROM matches the decomp's Rev 1 target, but nothing is built

- Date: 2026-08-17
- Observed: the user's `Pokemon - Platinum Version (USA) (Rev 1).nds` hashes to
  `0862ec35b24de5c7e2dcb88c9eea0873110d755c`, which `pokeplatinum`'s `README.md` documents as its
  **Rev 1** target.
- Source: `pret/pokeplatinum` `README.md`.
- Notes: **not built, and it is the only one of the four that cannot be with what is installed.**
  Its `INSTALL.md` needs `bison flex gcc git make ninja python arm-none-eabi-gcc p7zip libpng`;
  devkitPro's msys2 supplies the first several from its `msys` repo but has **no mingw64/ucrt64
  repos**, so `mingw-w64-ucrt-x86_64-arm-none-eabi-gcc` and `mingw-w64-x86_64-libpng` are
  unavailable there. Needs a standalone MSYS2 or WSL. **Also note `pokeplatinum` describes itself
  as a WIP decompilation**, unlike the complete-and-matching pokered/pokecrystal/pokeemerald/
  pokefirered — so symbol coverage may be partial even after a successful build, and that should be
  checked before assuming a Platinum adapter is a tier-2 lookup.

### Archipelago's Crystal patch rearranges WRAM, non-uniformly (2026-08-17)

- Date: 2026-08-17
- Observed: `gerbiljames/Archipelago-Crystal` (branch `pokecrystal-develop`) ships
  `worlds/pokemon_crystal_prerelease/data/data.json`, which publicly contains both `rom_addresses`
  and `ram_addresses` — the Crystal equivalent of Emerald's `extracted_data.json`. Comparing its
  `ram_addresses` against the vanilla `pokecrystal.sym` from our own verified build, **the spacing
  between labels differs**, which is a base-independent comparison and so does not rest on any
  assumption about how the addresses are based:

  | Label | Offset from `wMapGroup`, vanilla | Same, Archipelago |
  | --- | --- | --- |
  | `wMapNumber` | +1 | +1 |
  | `wUnownDex` | +548 | +548 |
  | `wEventFlags` | -579 | -567 |
  | `wStatusFlags` | -1129 | -1184 |
  | `wMapEventStatus` | -2178 | -2181 |

- Source: `Archipelago-Crystal` `worlds/pokemon_crystal_prerelease/data/data.json` (MIT, licence
  row added to `licensing.md` 2026-08-17); vanilla addresses from our own hash-verified
  `pokecrystal.sym`.
- Notes: **the practical consequence is that a Crystal adapter needs a per-ROM address table, and
  cannot derive the patched addresses by applying a constant offset to the vanilla ones.** The
  patch inserts its own `wArchipelago*` variables at several points rather than appending them in
  one block. **The encouraging half:** the neighbourhood around `wMapGroup` is internally
  consistent (`wMapNumber` +1, `wUnownDex` +548 both agree exactly), so the map/coordinate block
  appears to move as a unit rather than being broken up — which is what an adapter actually reads.
  This is the same class of hazard that broke Emerald's sprite decode under a patched seed
  (`risks.md`, confirmed live 2026-08-14), found this time **before** writing any adapter code
  rather than after.
- Not yet checked: whether `wYCoord`/`wXCoord` themselves appear in Archipelago's table (they are
  absent from the entries read, which lists mainly flags and Archipelago's own variables), and
  whether the V1.0 and V1.1 basepatches (`basepatch.bsdiff4`, `basepatch11.bsdiff4`) differ in
  layout from each other.

### Crystal: what the game itself writes when it spawns the player (2026-08-17)

- Date: 2026-08-17
- Observed: `object_slot_probe.lua` watching all 13 object slots every frame while the user loaded
  a save from the main menu. At **frame 454** slot 0 went from empty to occupied, and the probe
  dumped the whole 40-byte struct as the game left it:

  ```
  01 00 00 0B 02 00 00 FF 00 01 00 01 00 FF 00 00 07 07 07 07 07 07 00 40 40 00 00 00 00 00 00 00 ...
  ```

  Decoded against `constants/map_object_constants.asm`:

  | Off | Field | Value | Note |
  | --- | --- | --- | --- |
  | 00 | `OBJECT_SPRITE` | `01` | `SPRITE_CHRIS` |
  | 03 | `OBJECT_MOVEMENT_TYPE` | `0B` | `SPRITEMOVEDATA_PLAYER` |
  | 04 | `OBJECT_FLAGS1` | `02` | |
  | 06 | `OBJECT_PALETTE` | `00` | **unexplained — see below. Do not read this as "male".** |
  | 07 | `OBJECT_WALKING` | `FF` | not walking |
  | 08 | `OBJECT_DIRECTION` | `00` | |
  | 09 | `OBJECT_STEP_TYPE` | `01` | |
  | 0B | `OBJECT_ACTION` | `01` | |
  | 0D | `OBJECT_FACING` | `FF` | |
  | 10-11 | `OBJECT_MAP_X` / `MAP_Y` | `07` `07` | |
  | 12-13 | `OBJECT_LAST_MAP_X` / `Y` | `07` `07` | equal to current, as expected at spawn |
  | 14-15 | `OBJECT_INIT_X` / `Y` | `07` `07` | equal to current |
  | 17-18 | `OBJECT_SPRITE_X` / `Y` | `40` `40` | screen position |
  | 19+ | remainder | `00` | all zero |

- Source: live capture (`object_slot_probe.lua`, read-only, no writes); field offsets and constant
  names from `pret/pokecrystal`.
- **CORRECTION, same day, before this was relied on: the dump above is NOT a finished object.**
  A second run captured the same event with materially different bytes — `OBJECT_PALETTE` `01` not
  `00`, `OBJECT_WALKING` `00` not `FF`, `OBJECT_STEP_TYPE` `00` not `01`, and different coordinates.
  The probe fires on the **first frame the slot is non-zero, which is during initialisation**, so
  the two runs caught different sub-steps of the same process. Neither is "what a correct object
  looks like", and the original wording here claimed exactly that.
  **What survives unchanged** is the ordering fact below, the slot accounting, and the confirmation
  that the fields carry `SPRITE_CHRIS` and `SPRITEMOVEDATA_PLAYER` — those agree across both runs.
  **`OBJECT_SPRITE` is `01` (`SPRITE_CHRIS`) in both runs regardless of the save**, which is
  consistent with the decomp rather than surprising: `PlayerObjectTemplate` hardcodes that sprite,
  and the gender-correct one is written afterwards from the `ChrisStateSprites`/`KrisStateSprites`
  tables (`data/sprites/player_sprites.asm`), keyed by `wPlayerState`. **So the spawn-time struct
  does not describe the player's final appearance**, and an adapter must not copy it expecting one.
  The probe now takes follow-up dumps at +1/+4/+16/+64 frames so the settling can be *seen*; until
  a settled capture exists, treat every byte above as provisional except where noted.
  **`OBJECT_PALETTE` is specifically unresolved**: `PAL_NPC_RED` is 8 and `PAL_NPC_BLUE` is 9, but
  the observed values were `00` and `01`, so the encoding in the object struct differs from the map
  object's packed nibble and has not been worked out.
- Notes: this was gathered as the ground truth the spawn ADR asked for — an object to verify
  against if the engine routine can be called, or to imitate if it cannot — and it will be, once
  a settled capture replaces the provisional one above.
  **It corroborates the decomp independently**: `SPRITE_CHRIS` and `SPRITEMOVEDATA_PLAYER` are
  exactly what `PlayerObjectTemplate` specifies in `engine/overworld/player_object.asm`, arrived at
  from live bytes rather than from reading it.
  **An ordering fact worth having**: the object is populated while `wMapGroup`/`wMapNumber` still
  read `0/0`; the map identity only becomes `24/7` afterwards. So object spawn does not wait on map
  identity being valid, and an adapter must not use "map is valid" as its cue that the player
  object exists.
  **Also confirmed:** 13 slots free before load, exactly one used after — the player. No slot was
  cleared across the menu-to-map transition.
- **Still not observed, and both matter:** a real map-to-map transition (the run stayed in
  `PLAYERS_HOUSE_2F`), and how many slots the game itself consumes on a populated map. Twelve free
  in a bedroom is an upper bound, not a budget.

### Crystal: a spawned object event renders — the create tier works on an emulator (2026-08-18)

- Date: 2026-08-18
- Observed: **watched on screen by the user**, with a screenshot. `spawn_test.lua` copied the
  player's own object struct from slot 0 into slot 1 and offset it +2 tiles in x. A **second Chris
  appeared in the room, correctly drawn** — right sprite, right palette, composited into the scene
  like any other object, not painted over it. Player at (7,7), ghost at (9,7), in
  `PLAYERS_HOUSE_2F`. Log: `ROM guard passed: vanilla Crystal V1.0` then
  `Wrote slot 1 at frame 120`.
- Source: live session; `adapters/pokemon/crystal/spawn_test.lua`.
- Notes: **this is the milestone the 2026-08-17 spawn ADR was written for.** MeshGhost has drawn
  overlays on an emulated game since Emerald; this is the first time it has asked the game itself
  to render a character, and the first game-RAM write in the project's history. It validates the
  whole approach: palettes, sprite selection and compositing are the engine's job and they came out
  right without us implementing any of them.
  **Copying a live object was the right call.** The struct was duplicated from a real, running
  object rather than built from the two disagreeing spawn-time captures, which removed field
  correctness as a variable entirely.
  **The guard did its job silently and should stay that way:** it verified the ROM header
  (`PM_CRYSTAL`, checksum `129F`) before writing anything.
- **Honest caveat about the automated check: it was inconclusive, and the screen is what settled
  this.** The script logged the engine-maintained `OBJECT_SPRITE_X`/`Y` at +1, +30 and +120 frames
  expecting movement to indicate the engine had adopted the object; all three read `64`/`64`,
  unchanged. That is exactly what a *stationary* object should read, so it neither confirms nor
  denies engine ownership — the test was badly chosen, not failed. **Do not cite those numbers as
  corroboration.** A better check is whether the object animates or reacts when it has reason to.
- **Not yet known, and none of it is implied by the above:** whether the ghost animates, whether it
  survives a map transition, whether the player collides with it, whether it can be given a
  *different* appearance from the player (a peer will need Kris, or a different state), and how it
  behaves on a map that is already using its slot.

### Crystal: writing the object struct directly makes a half-owned object (2026-08-18)

- Date: 2026-08-18
- Observed: **watched by the user**, immediately after the successful render above. The spawned
  character's **collision sat two tiles away from where its sprite was drawn** — user, verbatim:
  *"the hitbox/collission of the sprite seems to be 2 tiles to the right of where the sprite is
  shown"*, and then *"its now an 'invisible blocked tile' i can't walk onto"*.
- Source: live session; `adapters/pokemon/crystal/spawn_test.lua`.
- Notes: **the two tiles are exactly the offset the script applied**, which identifies the cause
  precisely. `OBJECT_MAP_X`/`MAP_Y` drive collision and we set them to +2; the sprite is drawn from
  `OBJECT_SPRITE_X`/`Y`, which we copied from the player and **the engine never recomputed** — the
  same `64`/`64` the script logged unchanged at +1, +30 and +120 frames. That log line was read at
  the time as "stationary object, inconclusive"; the user's observation is what gave it its real
  meaning. **A metric that agrees with itself is not evidence** — the screen settled this, twice.
- **The underlying cause, from `pokecrystal`: object structs are not the source of truth, map
  objects are.** `InitializeVisibleSprites` (`engine/overworld/player_object.asm`) walks the map
  objects and, for each with a sprite whose `MAPOBJECT_OBJECT_STRUCT_ID` is still `-1`, assigns an
  object struct and takes ownership. Writing the struct directly skips that, so the object renders
  but nothing maintains it. **This is the imitation failure `adapters/_template/README.md` predicts
  in "find out how the GAME does it before you work around it"** — and it appeared on the very
  first attempt, which is the argument for the ADR's call-the-engine branch rather than a
  refinement of the imitation.
- **Correction to the entry above:** "palettes, sprite selection and compositing are the engine's
  job and they came out right" still holds for *drawing*, but the object is not engine-driven.
  Treat that entry as "the game will render a struct we place", not "the game adopted our object".

### Crystal: the in-game gate, and a 2-second window where plausible data is not yet safe (2026-08-18)

- Date: 2026-08-18
- Observed: `ingame_gate_probe.lua`, started on the title screen and run through a save load.
  It prints only on change; the whole run to reaching play was three lines:

  ```
  [blocked ] f=5     mapStatus=START  events=0 script=0 paused=0 map=0/0  slots=0
  [blocked ] f=900   mapStatus=START  events=0 script=0 paused=0 map=24/7 slots=1
  [SPAWN-OK] f=1020  mapStatus=HANDLE events=0 script=0 paused=0 map=24/7 slots=1
  ```

- Source: live run (logs committed alongside, `ingame_gate_20260818_002003.log`); addresses
  `wMapStatus` `01:d432`, `wMapEventStatus` `01:d433`, `wScriptRunning` `01:d438`,
  `wGameLogicPaused` `00:c2cd`, from our hash-verified build.
- Notes: **the gate behaves correctly at both ends** — `blocked` on the title screen, `SPAWN-OK`
  once the overworld is running.
  **The middle line is the finding, and it justifies reading the game's state machine rather than
  its data.** For roughly **120 frames — two seconds — `wMapGroup`/`wMapNumber` read a real map
  (24/7) and object slot 0 was already populated, while `wMapStatus` was still `START`.** Every
  data-shaped check available would have passed during that window: the map is valid, the player
  object exists, coordinates are sane. Only the state machine said "not yet". An adapter gating on
  plausibility rather than state would spawn into a two-second window while the game is still
  building the map — the corruption case, not a cosmetic one.
  **This also matches the ordering fact recorded 2026-08-17**: the player object is populated
  before the map identity becomes valid. Together the two give the setup sequence as
  object -> map identity -> `MAPSTATUS_HANDLE`, and only the last of the three means "in play".
- Still not captured: what `wMapStatus` reads *during* a door/map-to-map transition, and what the
  gate reports during a battle or the START menu. Neither is pass/fail — per
  `adapters/_template/README.md` only the pre-game case is an absolute block, and the rest is a
  per-state design decision.

### Crystal: the gate must be `wMapStatus` ALONE — the other flags flicker every step (2026-08-18)

- Date: 2026-08-18
- Observed: a full `ingame_gate_probe.lua` run — title screen, save load, walking, downstairs and
  back up. The proposed gate (`wMapStatus == HANDLE` **and** `wMapEventStatus == MAPEVENTS_ON`
  **and** `wScriptRunning == 0` …) **flipped between `blocked` and `SPAWN-OK` dozens of times
  while the player was simply walking across a room**, e.g. f=2545 through f=4360. In every one of
  those lines `wMapStatus` was steady at `HANDLE`; what changed was `wMapEventStatus` going to `1`
  (`MAPEVENTS_OFF`) or `wScriptRunning` reading `9`.
- Source: live run, `ingame_gate_20260818_002003.log` (committed).
- Notes: **`wMapEventStatus` and `wScriptRunning` toggle on every walking step and must not be used
  as a spawn gate.** A ghost gated on them would flicker in and out once per footstep. They answer
  *"is the player free to act right now"* — a real question, and the one Crystal itself uses to
  decide whether to run map events — but not *"may a ghost exist"*.
  **`wMapStatus` answers this correctly on its own**, across every state seen:
  `START` before the world is built, `HANDLE` steady through all movement, `ENTER` through both
  door transitions. The gate is now `wMapStatus == MAPSTATUS_HANDLE`, plus a map-identity and
  player-object sanity check.
  **This is what "log what the gate WOULD have decided" is for.** The composite gate looked
  perfectly reasonable when written, and reads as *more* careful than the simple one. It was worse,
  and only a timeline of real play showed it.
- **Map transition captured, first time.** Leaving the bedroom: `mapStatus` -> `ENTER` with
  `wScriptRunning` = 5, map identity switching from 24/7 to 24/6 *during* the `ENTER` window, and
  the object slots repopulating (1 -> 3) before `HANDLE` returns. Returning upstairs mirrored it
  (24/6 -> 24/7, slots 3 -> 1). **So object state really is rebuilt per map**, confirming the
  consequence the spawn ADR accepted: a spawned ghost will need re-spawning on every map load, and
  `ENTER` is the signal to stop trusting anything previously spawned.
- **Slot budget, two data points:** `PLAYERS_HOUSE_2F` (bedroom) uses 1 of 13; `PLAYERS_HOUSE_1F`
  (downstairs) uses 3. Still both small indoor maps — a populated outdoor map is untested and is
  the number that actually constrains the design.

### Crystal: the engine only adopts objects scrolling onto the screen EDGE (2026-08-18)

- Date: 2026-08-18
- Observed: `spawn_test2.lua` wrote a map object into a free slot with `structId` left at `-1`, and
  it stayed unadopted through 600+ frames of walking. The map-object dump is what explained it:

  ```
   0: sprite=  1 structId=  0 at 11,4   <- player
   2: sprite=241 structId=255 at 8,8
   3: sprite=242 structId=255 at 9,8
   4: sprite=243 structId=255 at 4,5
  ```

  Sprites 241/242/243 are `SPRITE_DOLL_1`, `SPRITE_DOLL_2`, `SPRITE_BIG_DOLL` — **the game's own
  objects, in the same room, also sitting unadopted at `structId` 255.** Only the player had a
  struct. Nothing was being adopted, so our object was not being singled out.
- Source: live run; `CheckObjectEnteringVisibleRange` in
  `pret/pokecrystal` `engine/overworld/player_object.asm`.
- Notes: **`CheckObjectEnteringVisibleRange` is not a general "adopt anything unassigned" pass.**
  It is specifically *spawn objects as they scroll onto the screen edge*: it returns immediately
  unless `wPlayerStepDirection` is not `STANDING`, then scans **exactly one row** —
  `wYCoord + 9` walking down, `wYCoord - 1` walking up — for map objects on that row whose
  `structId` is still `-1`. An object placed **beside** the player is already inside the visible
  area and can never match, no matter how far the player walks.
  **So test 2's failure was about WHERE the object was put, not what was written**, and that
  distinction was only visible because the dump showed the game's own objects failing identically.
  A dump of neighbours is worth more than a dump of the thing you are debugging.
  **The two real entry points are now both known:** `InitializeVisibleSprites` at map load
  (`map_setup.asm`), and `CheckObjectEnteringVisibleRange` per step at the screen edge. **Neither
  will ever pick up an object placed next to the player mid-map**, which is exactly what a ghost
  needs — so a general solution has to either invoke the path directly or complete the linkage by
  hand. That is the ADR's call-vs-imitate question, now with the cost of each side visible.

### Crystal: the engine ADOPTED our map object — the create tier works properly (2026-08-18)

- Date: 2026-08-18
- Observed: `spawn_test3.lua` wrote a map object into a free slot at `wYCoord + 9`, left
  `MAPOBJECT_OBJECT_STRUCT_ID` as `-1`, and waited. After the player eventually walked so that row
  scrolled toward the screen edge:

  ```
  *** ADOPTED at +4789 frames: engine assigned object struct 1 ***
  ```

- Source: live run, `spawn_test3_20260818_003144.log` (committed).
- Notes: **this is the decisive result for the 2026-08-17 spawn ADR.** The engine replaced a value
  we did not write — `-1` became a real struct id — which is the game stating in its own terms that
  it accepted our object and took ownership. **Our map object bytes are legitimate**, copied from
  the player's, and the engine's own adoption path (`CheckObjectEnteringVisibleRange`) processed
  them like any other object. The ADR's "use the engine's own path" branch is proven; imitation is
  no longer the fallback it looked like after the first two tests.
- **Two side effects, both observed on screen by the user, and both consequences of joining a
  shared pool rather than data damage.** The before/after dump shows exactly what happened:

  | Map object | Before | After |
  | --- | --- | --- |
  | 1 (ours) | — | `sprite=1 structId=1 at 6,13` |
  | 2 (an NPC) | `structId=1 at 6,13` | `structId=2 at 6,13` |
  | 3 (an NPC) | `structId=3 at 10,7` | **`structId=255`** at 10,7 |

  1. **An NPC went invisible**: map object 3 reverted to unadopted (`structId` 3 -> 255).
     **CORRECTED same day — this is NOT slot exhaustion, which is how it was first written up.**
     Reading the before/after assignment properly:

     ```
     BEFORE:  0->0,  2->1,  3->3,  4->4,  5->5,  6->255
     AFTER:   0->0,  1->1,  2->2,  3->255, 4->4,  5->5,  6->255
     ```

     **Struct 3 is free and unused afterwards**, so the pool did not run out — there was room the
     whole time. What happened is a *reassignment*: our object took struct 1, the NPC that held it
     moved to struct 2, and map object 3 was bumped out and then simply never re-adopted, because
     adoption only fires at map load or when a row scrolls in at the screen edge (neither happened
     for it afterwards). **The claim that the effective budget is smaller than 13 is withdrawn; no
     evidence here supports it.** The real lesson is narrower and more useful: **inserting an object
     can cause the engine to re-shuffle struct assignments, and an object bumped in that shuffle
     stays invisible until something re-triggers its adoption.**
  2. **The ghost spawned on top of an NPC**: `wYCoord + 9` happened to be the exact tile map object
     2 occupies. **The free-slot check tested whether the SLOT was free and never whether the TILE
     was** — different questions, and only the first was asked.
- **Recovery is a map reload**; objects rebuild from ROM on map load. No save was written.
- **Supersedes the framing in commit `2c0dd31`**, which called this borrow-tier damage to the
  game's objects. That was written before the adoption line appeared in the log and before the user
  clarified that the ghost had spawned *over* an NPC rather than replacing one. The game's data was
  not corrupted; a struct was reallocated and a sprite was drawn over another.

### Crystal: a map reload restores objects a spawn disturbed (2026-08-18)

- Date: 2026-08-18
- Observed: **watched by the user.** After `spawn_test3.lua` left an NPC unadopted and therefore
  invisible, leaving the room and re-entering brought it back — user, verbatim: *"yee re entering
  the room made the npc show up again"*.
- Source: live session.
- Notes: confirms empirically what was previously only reasoned: **object state is rebuilt from ROM
  on map load, so a map reload undoes anything a spawn disturbed.** Nothing persisted, and no save
  was written. This is the property that makes the whole spawn line of work cheap to be wrong in —
  a bad write costs a door transition, not a corrupted file. It is also the flip side of the ADR's
  accepted consequence that a ghost must be re-spawned on every map load: the same rebuild that
  cleans up our mistakes also erases our ghosts.

### Crystal: `wMapStatus` stays HANDLE through a battle — the gate needs `wBattleMode` (2026-08-18)

- Date: 2026-08-18
- Observed: `ingame_gate_probe.lua` running into a wild battle on Route 29:

  ```
  [SPAWN-OK] f=21430 mapStatus=HANDLE battle=wild map=24/3 structs= 2 mapObjs= 9 (events=0 script=255 paused=0)
  ```

- Source: live run, `ingame_gate_20260818_003132.log`.
- Notes: **the gate as previously settled is wrong for battles.** `wMapStatus` remains
  `MAPSTATUS_HANDLE` for the entire battle, so a gate reading it alone reports `SPAWN-OK` while the
  player is fighting. `wBattleMode` is an **independent** signal, not derivable from the map state
  machine, and must be its own term. Gate is now `wMapStatus == HANDLE` **and**
  `wBattleMode == 0`, plus the map-identity and player-object checks.
  **This is the second time walking the full lifecycle overturned a gate that looked settled** —
  the first was `wMapEventStatus`/`wScriptRunning` flickering every step. Neither was deducible by
  reading; both needed the timeline. `wScriptRunning` also reads `255` during a battle, but it is
  already known to be unusable as a gate term.
  **Object structs are NOT wiped on battle entry** — `structs` held at 2 across the transition. Not
  yet observed: the state after the battle *ends*, which is the half that decides whether a ghost
  needs re-spawning per encounter.
- **First outdoor map-object count**: Route 29 (`24/3`) shows **9 map objects in use** of 16,
  against 4 in the player's house. **Caveat on attribution: `spawn_test3.lua` was running at the
  same time and injects one map object**, so the real figure is 8 or 9 — good enough to establish
  that outdoor maps consume roughly half the array and that free slots exist, but it should be
  re-measured with only one script running before any budget rests on it.

### Crystal: leaving a battle is a map re-entry (2026-08-18)

- Date: 2026-08-18
- Observed: running from a wild battle on Route 29, `ingame_gate_probe.lua`:

  ```
  [SPAWN-OK] f=21430 mapStatus=HANDLE battle=wild map=24/3 structs= 2 mapObjs= 9
  [blocked ] f=30000 mapStatus=ENTER  battle=-    map=24/3 structs= 2 mapObjs= 9
  [SPAWN-OK] f=30055 mapStatus=HANDLE battle=-    map=24/3 structs= 2 mapObjs= 9
  ```

- Source: live run, `ingame_gate_20260818_003132.log`.
- Notes: **the battle ends with `wMapStatus` passing through `ENTER` — the same transition a door
  produces.** So a battle exit is a map re-entry, and **every encounter is a ghost-lifecycle event,
  not just every map change.** Given how often battles happen in this game that is a central rule
  for the adapter rather than an edge case, and it is the answer to the question the battle run was
  posed to settle.
  **The gate handles it correctly with no extra work**: `ENTER` already blocks, so the re-entry
  window is covered by the term added for door transitions.
  Battle *entry* did not disturb the arrays (`structs` held at 2 going in).
- **Two things deliberately NOT concluded from this run:**
  1. **`structs` reading 2 before, during and after does not prove the structs were not rebuilt.**
     An unchanged count is not unchanged contents, and this map happens to have the same number of
     nearby objects on both sides of the battle. Whether a ghost actually survives a battle needs a
     test that watches a *specific* object, not a count.
  2. **`mapObjs` held at 9 across the `ENTER`, which is suggestive but confounded.**
     `spawn_test3.lua` was running alongside and had injected a map object; if the battle exit
     reloaded map objects from ROM, that injected object should have vanished and the count should
     have dropped. It did not — which hints the battle-exit `ENTER` is a *lighter* re-entry than a
     door transition. **But with two scripts running, the count cannot be attributed**, and the
     alternative (the object was already gone and 9 is simply the map's real count) fits equally
     well. Re-run with a single script before believing either.

### Crystal: a false ADOPTED — the slot was reused by another map's NPC (2026-08-18)

- Date: 2026-08-18
- Observed: a `spawn_test3.lua` run reported `*** ADOPTED at +307 frames ***`, but its own
  before/after dumps show the player had **changed maps** in between:

  ```
  BEFORE:  player at 63,12   8 objects, coords up to 52,20   (an outdoor map)
  AFTER:   player at  4,13   1: sprite=41 structId=1 at 10,12
  ```

  Our object was written with `sprite=1` at `48,19`. The slot afterwards holds **`sprite=41` at
  `10,12`** — a different map's own NPC, which legitimately owns struct 1.
- Source: live run, `spawn_test3_20260818_004254.log`.
- Notes: **the check was "is `structId` no longer -1?", and a stranger answered it.** The map
  change wiped our object and the new map's objects reused the slot; nothing about the value read
  was implausible, which is precisely the failure mode `CLAUDE.md` warns about — a wrong read
  returning a plausible value rather than an error. **Every line after that point in the log is
  tracking someone else's object**, so the "does a ghost survive a battle" question this run was
  set up to answer is **still unanswered**.
  **The earlier success is unaffected, and was checked rather than assumed**: in the 2026-08-18
  adoption run the slot held `sprite=1` at `6,13`, exactly what had been written, on the same map.
  That result stands.
- **Fix**: the script now records the identity of what it wrote — sprite, coordinates, and map
  group/number — and only reports adoption if the slot still holds *that*. A map change is
  detected and reported as `GONE` rather than silently invalidating everything downstream.
  **Generalises past this bug: when watching a slot in a pooled array, "the slot changed" is not
  the same claim as "my thing changed", and only an identity check separates them.**

### Crystal: hand-linking both halves does NOT make the engine drive an object (2026-08-18)

- Date: 2026-08-18
- Observed: `spawn_test4.lua` wrote a map object and an object struct and cross-linked them
  (`MAPOBJECT_OBJECT_STRUCT_ID` -> our struct, `OBJECT_MAP_OBJECT_INDEX` -> our map object), at a
  clear tile 2 west of the player. The log printed **one** line and never again — and it prints
  only on change:

  ```
  f=121  mapStatus=HANDLE  engine-maintained sprite_x=80 sprite_y=16
  ```

  **`OBJECT_SPRITE_X`/`Y` never changed for the whole run.** The user reports the ghost appeared
  **exactly where the player was standing**, and that an NPC went invisible.
- Source: live run, `spawn_test4_20260818_*.log`.
- Notes: **the cross-link is not sufficient. This is test 1's half-owned object again**, reached by
  a different route: the struct was copied from the player, screen coordinates included, so it
  draws at wherever the player stood at copy time and stays there. Collision uses the map
  coordinates we set; the sprite uses frozen screen coordinates. Exactly the split first seen
  2026-08-18 in test 1.
  **Two attempts have now failed with the identical symptom**, which by `CLAUDE.md`'s own rule
  means stop guessing and isolate by subtraction rather than try a third variation.
  **The subtraction is available and cheap**: in test 3 the engine adopted our map object and
  produced a **working** object. So a known-good, engine-built struct exists to diff, field by
  field, against the one built by hand. That is one diagnostic and one variable, and it should
  come before any further write.
  **Consequence for the ADR's open question**: imitation has now been tried twice with the full
  linkage understood, and failed both times. That is real evidence for the **call-the-engine's-own
  -routine** branch rather than a third round of reproducing what it writes — but the diff should
  run first, because it either identifies the missing field or proves there is more to adoption
  than field values.
- **An NPC went invisible again**, as in test 3. Same class as the struct reshuffle recorded there;
  mechanism still not established. Recovery is a map reload.

### Crystal: the engine CULLS objects that leave the visible window (2026-08-18)

- Date: 2026-08-18
- Observed: **watched by the user.** A hand-built ghost in Elm's lab *"disappears when i'm at the
  bottom 2 tiles of the elms lab, all the tiles above that show it properly"*, and earlier,
  *"when i go away from the ghost towards a door, it disappears... it does not happen if i go up"*.
  The trigger is the **player's** position, not the ghost's, and it is directional.
- Source: live session; `CheckObjectStillVisible` and the deletion path in
  `pret/pokecrystal` `engine/overworld/map_objects.asm`.
- Notes: **Crystal actively deletes overworld objects that leave the visible window.** Reading
  `CheckObjectStillVisible`, the test is run twice: first against the object's **current**
  `OBJECT_MAP_X`/`MAP_Y`, and if that fails, again against its **`OBJECT_INIT_X`/`INIT_Y`** — its
  spawn tile. If *both* fall outside the window (`MAPOBJECT_SCREEN_WIDTH`/`HEIGHT` from
  `wXCoord`/`wYCoord`), the object is deleted **unless `WONT_DELETE` (bit 1 of `OBJECT_FLAGS1`) is
  set**. Bit 0 of the same byte is `INVISIBLE`, a separate state.
  **This is a genuine mechanic, not a symptom of our writes** — it is how the game keeps the object
  pool bounded on large maps, and it applies to its own NPCs.
  **Two consequences for a ghost, and they are design constraints rather than bugs:**
  1. **A peer standing far from the local player cannot simply be spawned and left**; the engine
     will cull it. `WONT_DELETE` is the flag that exists precisely for objects that must persist.
  2. **`INIT_X`/`INIT_Y` matter more than expected.** They are consulted by the cull, so an object
     whose spawn tile is far away is deletable even while its current tile is near — worth setting
     deliberately rather than copying.
  **Not yet established**: which of the two mechanisms produced what the user saw. Deletion sets
  `SPRITE` to 0; the invisible flag leaves the object present. The struct-diff probe now reports
  which, and both need different fixes. The player's own struct was observed carrying
  `FLAGS1 = 0x02`, i.e. `WONT_DELETE` already set — so if our copy preserved that faithfully,
  deletion should not have applied, which is itself a reason to measure rather than assume.

### Crystal: the struct diff is clean — and the "half-owned" conclusion is now suspect (2026-08-18)

- Date: 2026-08-18
- Observed: `struct_diff_probe.lua` in Elm's lab, comparing a hand-built object against an NPC the
  engine built and drives on the same map. **Exactly one unexpected field difference:**

  ```
  >>> 0C STEP_FRAME    engine=3  ours=0   <<< INTERESTING
  ```

  Everything else matched, including `FLAGS1 = 0x02` (**`WONT_DELETE` already set on ours**),
  `MOVEMENT_TYPE`, `PALETTE`, `DIRECTION`, `STEP_TYPE`, `ACTION`, `FACING` and `SPRITE_TILE`.
- Source: live run, `struct_diff_*.log`.
- Notes: **`STEP_FRAME` is an animation frame counter** — that NPC's walk cycle mid-stride. A
  transient, not a structural difference. So the honest reading is **there is no meaningful field
  difference between what the engine builds and what we build.** That is the probe's second
  designed outcome, and it points away from "a field we forgot" entirely.
- **THE CONTROL FAILED, AND IT INVALIDATES MORE THAN THIS RUN.** The probe watches
  `OBJECT_SPRITE_X`/`Y`, which are **screen** coordinates, and prints on change. It printed once and
  never again — **for the engine's own NPC as well as ours.** Elm's lab is small enough that the
  camera never scrolls, so no object's screen coordinates changed. Per the probe's own stated rule,
  a run where neither moves measured nothing.
  **The consequence reaches backwards**: tests 1 and 4 both concluded "screen coordinates frozen,
  therefore the engine is not driving our object", and **both were run indoors**. If the camera was
  not scrolling in those either, frozen coordinates were never evidence of anything. **The
  half-owned-object conclusion is not withdrawn, but it is no longer supported by the measurement
  that produced it** — the visible symptom in test 1 (collision two tiles from the sprite) is
  independent evidence and still stands; the "engine is not driving it" inference is not.
  **This is the second time a metric that agreed with itself was mistaken for a result.** The
  correction both times came from the screen, not the numbers.
- **Next measurement must be somewhere the camera actually scrolls** — an outdoor route, not a
  room — with the same control. Only there does a frozen-versus-tracking comparison mean anything.

### RETRACTION: that struct diff compared our object against our own other object (2026-08-18)

- Date: 2026-08-18
- Observed: **the user caught it** — `spawn_test4.lua` was still loaded and running when
  `struct_diff_probe.lua` started. Comparing the two logs:

  ```
  test 4:      Linked map object 1 <-> struct 4, at 7,8
  diff probe:  Reference: map object 1 -> struct 4, built and driven by the engine.
  ```

  **The "engine-built reference" was test 4's own hand-built ghost.**
- Source: the two logs, read together.
- Notes: **the preceding entry's central finding is withdrawn.** "No meaningful field difference
  between what the engine builds and what we build" was **guaranteed by construction** — both sides
  of the comparison were built by us, the same way, minutes apart. It says nothing about the
  engine.
  **The cause is a weak identity test, the same class of mistake as the false `ADOPTED`.**
  `find_engine_object()` looked for a map object whose struct id was not 255 and assumed that meant
  the engine had adopted it. Our own scripts set that field, so our objects qualified. **"Has a
  struct id" is not the same claim as "the engine made this"** — and nothing about the value read
  was implausible, which is why it passed unnoticed.
  **What survives from that run:** the culling mechanic (independent, read from the decomp), and
  the observation that the control did not move — though even that is now doubly unusable, since
  the "reference" was not an engine object and Elm's lab does not scroll anyway.
  **Two rules earned, both already project rules and both broken here anyway:** run one writer at a
  time, and check identity rather than a proxy for it. The first was stated explicitly before the
  previous run and not followed through when a second script was added.
- **Practical guard added**: a reference object whose `SPRITE` matches the player's is now rejected
  and warned about, since our ghosts copy the player's sprite id and real NPCs do not use it.

### Crystal: a VALID struct diff — nine differences, and two explain everything (2026-08-18)

- Date: 2026-08-18
- Observed: `struct_diff_probe.lua` run alone, **in Elm's lab** (corrected — an earlier draft of
  this entry said outdoors, which was wrong), against a genuine engine-driven NPC (`SPRITE` 60, not
  the player's 1 — the guard added after the retraction did its job).
  **The control held this time**: the engine's object moved (`sprite_x` 32 -> 0) while ours stayed
  at 80. **And it held for a better reason than the one predicted.** The plan was to move somewhere
  the camera scrolls, on the theory that screen coordinates cannot change in a static room. The
  actual fix was simpler: **the reference NPC walks around by itself.** A moving *object* is all
  the control needs — a moving *camera* was never required, and Elm's aides pace on their own. So
  the earlier failed control was not caused by the room being indoors; it was caused by the
  reference being one of our own frozen ghosts, which by construction could never move.
  Nine unexpected field differences:

  | Off | Field | engine NPC | ours |
  | --- | --- | --- | --- |
  | 02 | `SPRITE_TILE` | 24 | **0** |
  | 03 | `MOVEMENT_TYPE` | 3 | **11** |
  | 04 | `FLAGS1` | 0 | 2 |
  | 09 | `STEP_TYPE` | 3 | 1 |
  | 0A | `STEP_DURATION` | 1 | 0 |
  | 0C | `STEP_FRAME` | 1 | 0 |
  | 16 | `RADIUS` | 17 | 0 |
  | 1D | `OBJECT_1D` | 0 | 12 |
  | 1F | `JUMP_HEIGHT` | 0 | 32 |

- Source: live run, `struct_diff_*.log`.
- Notes: **the half-owned-object conclusion is now properly supported.** The earlier evidence for it
  was an artifact of a non-scrolling room; here the engine's own object demonstrably tracked while
  ours did not, in the same run, on the same map.
- **Two differences explain the behaviour, and both come from the same root cause — we copied the
  PLAYER as our template:**
  1. **`MOVEMENT_TYPE` = 11 is `SPRITEMOVEDATA_PLAYER`.** We told the engine this object is driven
     by the player's input system, so it does not drive it. A real NPC uses an ordinary movement
     type (3 here). **This is the strongest single candidate for "the engine does not maintain
     it".**
  2. **`SPRITE_TILE` = 0 against the NPC's 24.** That field indexes the per-map VRAM tile
     allocation (`wUsedSprites`, arranged at map load). Ours has no graphics slot, which is a
     rendering problem independent of ownership — and consistent with the earlier session where
     injecting a sprite disturbed other objects' graphics.
  The rest follow from the same mistake: `RADIUS` 0 (an NPC's wander radius), `JUMP_HEIGHT` 32 and
  `OBJECT_1D` 12 (player state that is meaningless on an NPC), and the step fields being a stopped
  object versus a mid-stride one.
- **Consequence: the template is wrong, not the technique.** Copying the player was justified when
  the player was the only known-good object available; now that a real NPC can be read on any map,
  **an NPC is the correct template for a ghost** — it fixes `MOVEMENT_TYPE`, `RADIUS`,
  `JUMP_HEIGHT`, `OBJECT_1D` and the step fields in one move.
  **`SPRITE_TILE` remains the genuinely hard one**, because it is an allocation rather than a
  value: copying an NPC's tile index would draw that NPC's graphics. Making a ghost look like the
  player requires the player's sprite to have tiles loaded for that map, which is decided at map
  load. That is now the central rendering question for this adapter.

### Crystal: the engine IS driving our object — it was invisible, not unowned (2026-08-18)

- Date: 2026-08-18
- Observed: `spawn_test5.lua` (NPC template) with an ownership metric that could finally
  distinguish. **Our object's `STEP_FRAME` advanced on its own: 1 -> 2 -> 3**, across a run in which
  nothing of ours wrote that field after the initial copy:

  ```
  f=121  ours: map=7,6 step=1  |  template NPC: map=9,6 step=1
  f=442  ours: map=7,6 step=2  |  template NPC: map=9,6 step=1
  f=897  ours: map=7,6 step=3  |  template NPC: map=9,6 step=1
  ```

- Source: live run, `spawn_test5_*.log`.
- Notes: **`DoStepsForAllObjects` iterates every object struct with a sprite and calls
  `HandleObjectStep` on it.** Our object has a sprite, so it is being stepped and animated. **It
  was never unowned.** Every earlier "the engine is not driving it" conclusion was wrong, and wrong
  for the same reason three times over: `OBJECT_SPRITE_X`/`Y` were chosen as the ownership signal,
  and they cannot serve as one — `ApplyBGMapAnchorToObjects` only *adds a delta* to them, which is
  zero when the camera is still, so a stationary object's screen coordinates hold whether it is
  driven or not.
- **The real fault is that the screen coordinates were never initialised.** Adoption does not
  inherit them; `CopyTempObjectToObjectStruct` **computes** them from the map position
  (`engine/overworld/player_object.asm`, `.InitYCoord`/`.InitXCoord`):

  ```
  OBJECT_SPRITE_Y = ((map_y - wYCoord) & $0F) * 16 - wPlayerBGMapOffsetY
  OBJECT_SPRITE_X = ((map_x - wXCoord) & $0F) * 16 - wPlayerBGMapOffsetX
  ```

  Masking to the low nibble is what makes it a position *within the visible window*; the BG map
  offset is the sub-tile scroll. Copying a template's screen coordinates instead put ours at
  `sprite_y = 176`, below a 144-pixel screen — **invisible, while being perfectly well driven.**
  `wPlayerBGMapOffsetX`/`Y` are `01:d14c`/`01:d14d`, read on day one and never used until now.
- **Method note worth more than the finding**: three different metrics were tried before one could
  separate owned from unowned, and each of the first three had an innocent explanation for its
  reading. The one that worked was picked by asking *what could only happen if the engine were
  driving it* — an object nobody drives cannot animate.

### Crystal: A REAL SPAWNED CHARACTER — visible, engine-driven, correctly rendered (2026-08-18)

- Date: 2026-08-18
- Observed: **watched on screen by the user, with a screenshot.** `spawn_test6.lua` — an NPC used as
  the template, plus screen coordinates **computed** with the engine's own formula rather than
  copied — produced **a second, correctly drawn character**. It wears Professor Elm's appearance
  because Elm was the template object, which is exactly what the test intended. User: *"it
  duplicated an npc, 4 tiles left of Elm, and it also looks like elm"*.
- Source: live session; `adapters/pokemon/crystal/spawn_test6.lua`.
- Notes: **this closes the mechanism question the 2026-08-17 ADR opened.** A character can be
  created at an arbitrary position, without waiting for the engine's map-load or screen-edge
  adoption paths, by writing a linked map object + object struct copied from a live NPC and
  computing the screen coordinates as `CopyTempObjectToObjectStruct` does. It is drawn by the
  game's own renderer, animated by `DoStepsForAllObjects`, and needs no drawing code from us.
  **The missing ingredient was never ownership** — it was that adoption *computes* screen position
  from map position, and we had been copying a template's instead.
- **The placement error is itself an important finding: `wXCoord`/`wYCoord` are NOT the player's
  map coordinates.** They are the **origin of the visible window**. The ghost landed next to Elm
  rather than next to the player because it was placed at `wXCoord + 2`, i.e. two tiles from the
  top-left of the screen. This had been assumed to be the player's position all session, and every
  earlier placement inherited the mistake — including test 3's `wYCoord + 9`, which worked only
  because `CheckObjectEnteringVisibleRange` uses the same window origin.
  Corroborating evidence that was visible earlier and not read correctly: the player's own map
  object showed coordinates like `8,15` while `wXCoord`/`wYCoord` read much smaller numbers, and
  `CheckObjectStillVisible` compares object coordinates against `wXCoord .. wXCoord + 12`.
  **The player's real map position is in its own object struct** (slot 0, `OBJECT_MAP_X`/`MAP_Y`).
  So: use the player's struct for *placement*, and `wXCoord`/`wYCoord` only as the window origin in
  the screen-coordinate formula. Two different quantities that had been conflated into one.
- **Still open, and unchanged by this**: making the ghost wear the *player's* appearance rather than
  a copied NPC's, which is the `SPRITE_TILE` allocation problem — an allocation rather than a value.

### Crystal: spawned beside the player, on demand — mechanism complete (2026-08-18)

- Date: 2026-08-18
- Observed: **watched by the user.** After correcting placement to read the player's own object
  struct rather than `wXCoord`/`wYCoord`, `spawn_test6.lua` put a character **two tiles to the
  right of the player**, exactly where asked. User: *"yes, placed 2 tiles to the right of me"*.
- Source: live session; `adapters/pokemon/crystal/spawn_test6.lua`.
- Notes: **this completes the mechanism the 2026-08-17 ADR set out to establish.** A character can
  be created at an arbitrary chosen position, at any time during play, and the game renders and
  animates it with no drawing code from us. The recipe, all of it necessary and none of it
  guessable without the decomp:
  1. Copy a **live NPC** — both its map object and its object struct. Not the player: the player's
     `MOVEMENT_TYPE` is `SPRITEMOVEDATA_PLAYER`, meaning "driven by input".
  2. Cross-link the pair (`MAPOBJECT_OBJECT_STRUCT_ID` <-> `OBJECT_MAP_OBJECT_INDEX`).
  3. Set map coordinates relative to the **player's own struct**, which is where the player's map
     position lives.
  4. **Compute** `OBJECT_SPRITE_X`/`Y` with the engine's formula, relative to the **window origin**
     `wXCoord`/`wYCoord` and the BG map offsets. Never copy them.
  5. Set `WONT_DELETE`, or the engine culls it when both its current and spawn tiles leave the
     visible window.
- **Remaining: appearance.** The ghost wears the template NPC's face. The obstacle is
  `OBJECT_SPRITE_TILE`, a per-map VRAM allocation rather than a value.
  **A promising route, not yet tested: borrow the PLAYER's `SPRITE` and `SPRITE_TILE`.** The
  player's sprite graphics are resident on every map by construction — the player is always there —
  so no allocation problem arises, and the result is an NPC-behaviour object wearing the player's
  appearance. That is exactly the combination a ghost wants.

### Crystal: a ghost that looks like the player, spawned on demand — Phase 9's goal reached (2026-08-18)

- Date: 2026-08-18
- Observed: **watched by the user.** `spawn_test7.lua` — NPC template for behaviour, plus the
  player's `SPRITE`, `SPRITE_TILE` and `PALETTE` — produced a second **player-looking character**
  standing two tiles to the right of the player. User: *"yes, looks like the player"*.
- Source: live session; `adapters/pokemon/crystal/spawn_test7.lua`.
- Notes: **this is what the 2026-08-17 ADR set out to prove, complete.** A peer can be represented
  by a real in-game object event, created at any position at any time, rendered and animated by
  Crystal's own engine, with **no drawing code in the adapter at all** — the thing Emerald has to
  do by hand and which broke under a ROM patch.
  **Gender is inherited rather than computed.** Crystal selects the player's sprite from
  `ChrisStateSprites`/`KrisStateSprites` keyed on `wPlayerState`, so copying the player's already-
  loaded sprite gets the correct character without reading `wPlayerGender`, and follows the same
  table if the player is on a bike or surfing.
  **The VRAM allocation problem was side-stepped, not solved**: the player's sprite is resident on
  every map by construction, so borrowing its tile index needs no new allocation.
- **The limit, and the next real problem: a ghost currently looks like THIS machine's player.** If
  the local player is Chris and the peer plays Kris, the peer's ghost still appears as Chris,
  because showing Kris needs Kris's tiles loaded on the local map. That is the `wUsedSprites`
  allocation question, deferred deliberately and worth attacking only once there is a peer to
  represent.
- **Still nothing networked.** No bridge, no socket, no `get_local_state`. Emerald's socket layer
  transfers wholesale; the mechanism half of Phase 9 is what was unknown and is now closed.

### Crystal: the anatomy of one step, captured frame by frame (2026-08-18)

- Date: 2026-08-18
- Observed: `step_watch_probe.lua` during the scripted sequence with the NPC outside Elm's lab —
  the user's find, and an excellent capture: talking to them makes them step back and shove the
  player, so the game walks **two characters that are not under input control**, in seconds, and
  it repeats on demand. Both objects showed the identical pattern.
- Source: live run, `step_watch_20260818_013937.log`.
- **A step is initiated in ONE frame, then the engine plays it out over 16.** For the player
  stepping down:

  ```
  f=599  MOVEMENT_TYPE 11->20  WALKING 255->4   STEP_TYPE 1->6  STEP_DURATION 0->7
         DIRECTION 12->0       FACING 12->0     ACTION 1->2
         MAP_Y 6->7            SPRITE_Y 64->66  MOVEMENT_INDEX 0->2  STEP_INDEX 0->1
  f=601..611   STEP_DURATION 7->6->..->1   STEP_FRAME 1->2->..->7   SPRITE_Y +2 every 2 frames
  f=613  WALKING 4->255  STEP_TYPE 6->1  STEP_DURATION 1->0  LAST_MAP_Y 6->7  SPRITE_Y ->80
  f=615  MOVEMENT_TYPE 20->11  MOVEMENT_INDEX 2->0  STEP_INDEX 1->0
  ```

- Notes, and the first is the one that matters:
  1. **`MAP_X`/`MAP_Y` are the DESTINATION and are set at the START of the step**, not at the end.
     The sprite then slides to catch up. This is the opposite of the assumption made when planning
     the movement work, where the map coordinate was expected to update on completion.
  2. **`LAST_MAP_X`/`Y` update at the END** — they are "where I came from", catching up on
     completion.
  3. **The slide is 2 pixels every 2 frames, 8 times: 16 pixels, one tile, ~16 frames.**
     `STEP_DURATION` counts 7 down to 0 and is the engine's own countdown.
  4. **`MOVEMENT_TYPE` is temporarily swapped to 20 for the duration** (from 11 player / 9 NPC) and
     restored afterwards — so a scripted step overrides the object's normal movement behaviour and
     puts it back.
  5. **We only have to initiate.** Every frame after the first is the engine's own work: the
     countdown, the walk animation, the pixel slide, the completion bookkeeping.
- **Consequence for moving a ghost**: do not write `MAP_X`/`MAP_Y` on their own and hope. Write the
  initiation set — direction, facing, walking, step type, step duration, action, and the
  destination map coordinate — once per tile of movement, and let the engine walk it. That is the
  same "trigger the game's own systems" shape that produced the spawn recipe.

### Crystal: the ghost WALKS — the full cosmetic mechanism is complete (2026-08-18)

- Date: 2026-08-18
- Observed: **watched by the user.** `walk_test.lua` spawned a player-looking ghost and paced it
  four tiles right and four left by writing the step-initiation set once per tile. User: *"yee it
  looks normal i think, just like any other random npc walking around"*.
- Source: live session; `adapters/pokemon/crystal/walk_test.lua`.
- Notes: **this completes the cosmetic mechanism Phase 9 set out to build.** A peer can be
  represented by a real in-game character that is spawned on demand at any position, wears the
  player's appearance, and **walks with the game's own step animation** — and the adapter draws
  nothing, animates nothing, and interpolates nothing. Emerald does all three by hand.
  **Being indistinguishable from an ordinary NPC is the result, not a coincidence**: it *is* an
  ordinary object event, built the way the game builds them and driven by the same routines.
  The initiation set, once per tile, with the engine doing the other ~16 frames:
  `WALKING = 4 + dir`, `DIRECTION = FACING = dir * 4`, `STEP_TYPE = 2`, `STEP_DURATION = 7`,
  `ACTION = 2`, and `MAP_X`/`MAP_Y` set to the **destination**. Direction encoding derived from
  `InitStep`, not guessed, and agreeing with all three captured steps.
  **Only initiate while the object is idle** (`STEP_DURATION == 0`); interrupting a half-played step
  is what would produce a character that teleports while animating.
- **What is left is no longer about the game.** Networking (bridge, socket, `get_local_state`),
  the lifecycle (re-spawn on every map load and every battle), and showing a peer's *own* gender
  rather than the local player's. Emerald's socket layer transfers wholesale for the first.
