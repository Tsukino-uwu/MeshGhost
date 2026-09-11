# Phase 6 — Second game (TEVI)

> **A dated record. Package paths here predate the 2026-08-17 module move** — read any
> `internal/X` as `X/`. Why, and what became of `internal/README.md`: [../README.md](../README.md).

**Status: LIVE — TEVI's whole running log, appended every session that touches it.** The numbered
task list below (6.0–6.7, including two real players and map markers) was confirmed complete on
2026-08-13 and the adapter has shipped since; that is a playable-state milestone, not the end of the
work — every adapter here stays open (the user, 2026-09-06). The charged-attack VFX gap this header
once named as "still open" was closed on 2026-08-28 (`adapters/tevi/VERIFIED.md`); what is open now
is in `adapters/tevi/UNVERIFIED.md` and `agent_docs/status.md`, never here. Started 2026-08-11.
(This header said "fully done" and quoted a "fold back when done" rule until 2026-09-06; the rule
was reversed on 2026-09-02 — `README.md` in this folder — and the task list below is kept as written.)

## Purpose

Repeat phases 1–4 for TEVI (Unity/Mono, 2D platformer/metroidvania) using the frozen
`adapters/_template/`, and find out whether the contract holds up outside Emerald — the real
point of picking a second, structurally different game.

## Tasks

- [x] Confirm TEVI's IL2CPP vs Mono status before assuming any tooling applies — the literal
      first task per `plans.md`/`adapters/tevi/README.md`, previously unconfirmed. **Confirmed
      Mono** (2026-08-11) via direct filesystem inspection of this machine's install
      (`C:\Program Files (x86)\Steam\steamapps\common\TEVI`): `TEVI_Data\Managed\
      Assembly-CSharp.dll` present, no `GameAssembly.dll` anywhere in the install,
      `doorstop_config.ini` has a `[UnityMono]` section (not `[UnityIL2CPP]`). BepInEx/Harmony
      tooling applies directly — no IL2CPP interop/unhollowing step needed. Bonus finding:
      BepInEx 5.4.23.3 is already installed on this TEVI copy from prior unrelated use and
      confirmed working — `LogOutput.log` shows it chainloading a third-party plugin
      (`Randomizer 1.4.3`) under Unity v2021.3.25.6876972. See `agent_docs/environment.md`'s
      Unity/TEVI section for the full evidence.
- [x] 6.0 — Licensing gate: added BepInEx (LGPL-2.1), Harmony (MIT), and `Tevi_Randomizer`
      (MIT, own repo/license, not Archipelago's) to `agent_docs/licensing.md`, all verified via
      GitHub API + reading the actual `LICENSE` file. Read `Tevi_Randomizer.csproj` for build
      approach (facts/approach only, no code copied) — see the reference-findings note in
      `agent_docs/plans.md`'s history and the plan file. Closed the now-resolved IL2CPP risk in
      `agent_docs/risks.md`; added two new risks surfaced by TEVI (no game-version check between
      peers; BepInEx/Harmony coexistence with the already-installed Randomizer).
- [x] 6.0.5 — Environment re-baseline: user updated TEVI and the Randomizer (was stale —
      `TEVI.exe` now 2026-07-16, Randomizer now 1.6.1). Re-confirmed Mono status against
      the current build (unchanged). Unity version confirmed `2021.3.25f1` directly from
      `UnityPlayer.dll`'s own metadata. Clean baseline launch confirmed BepInEx 5.4.23.3
      chainloads cleanly with no errors. All recorded in `agent_docs/environment.md`.
- [x] 6.1 — Hello-world plugin: `adapters/tevi/MeshGhostTevi` (netstandard2.0, `BepInEx.Core`
      + `UnityEngine.Modules 2021.3.25` via NuGet, `bepinex.dev` feed). Built with
      `dotnet build -c Release`, deployed to `BepInEx/plugins/MeshGhostTevi/`, confirmed live in
      `BepInEx/LogOutput.log`: `MeshGhost v0.1.0 loaded` logs cleanly, Randomizer 1.6.1 still
      loads right after with no conflict. See `agent_docs/verified.md`.
- [x] 6.2 — Real local player state confirmed via `ilspycmd` decompile of this machine's
      `Assembly-CSharp.dll`: `EventManager.Instance.mainCharacter` (`CharacterBase`) →
      `.t.position` (world pos), `.direction` (`Character.Direction`: LEFT/RIGHT/TOPLAYER/
      NOTTOPLAYER), `.aniStatus` (`Character.PlayerAniState`: IDLE/JUMPING/DJUMPING/FALLING/
      FALLING2/RUNNING/DAMAGE/BREAKING/SLOPED — chosen over the ~100-value combat
      `PlayerLogicState` as a ghost-appropriate `anim` tag set); `WorldManager.Instance.Area`
      (`byte`) for the area/scene id. Logging confirmed live: direction correlates exactly with
      position delta, anim transitions correctly with real movement/jump/fall, area changed
      `48`→`1` on a real Randomizer-practice-area teleport. See `agent_docs/verified.md`.
      (the `48`→`1` jump was a real in-game teleport-back item, not a bug). Console spam fixed
      along the way: switched from fixed-interval to change-triggered logging (was 120 of 137
      console lines on the first run, mostly identical repeated idle state).
      **Not yet tested with the Randomizer disabled** (coexistence risk in `risks.md`) — carry
      forward, not blocking.
- [x] 6.3 — Fake ghost in-engine, no network. Settled Spine-vs-sprite by decompiling
      `PixelCharacter.cs`: plain `SpriteRenderer` + Unity `Animator`, zero Spine references
      (Spine is used only by ~14 boss/environment files, not the player) — easier than Emerald,
      no manual pixel/palette decoding needed. Placeholder ghost (translucent magenta square,
      fixed offset from local player, no networking) confirmed live by the user: tracks through
      movement/jumping, survives room transitions (recreated lazily after scene-unload). Two
      real bugs found and fixed via actual testing, not assumed from a clean build: ghost was
      initially invisible (`pixelsPerUnit` mismatch vs. the real `charHeight = 65f` field) and
      the console was spammed 7324 lines in one session (position-change epsilon sat at the real
      per-frame movement noise floor — measured and fixed, not guessed). See
      `agent_docs/verified.md`.
- [x] 6.4/6.5 — Done, confirmed live. `BridgeClient.cs` (NDJSON bridge client, non-blocking
      connect on a background thread, sends on the main thread) plus per-`player_id` remote
      ghosts (cyan, distinct from 6.3's fixed-offset magenta local one) wired into `Plugin.cs`.
      Tested against a real `cmd/meshghost -game=tevi` core and `cmd/meshghost-relay -loopback`
      (`dev-scripts/run-core-tevi.bat` / `run-relay-loopback.bat`, added this session). First
      attempt hit the predicted 120 msg/sec relay disconnect for real (TEVI's `Update()` runs
      uncapped well above that) — fixed in `internal/core` (`Core.MinSendInterval`, 20Hz
      default), not the adapter, with a regression test and an ADR in `architecture.md`. Retest
      after the fix: user confirmed the loopback-echoed cyan ghost tracks smoothly through
      movement, jumping, and area transitions, no disconnect. See `agent_docs/verified.md`'s two
      Phase 6.4/6.5 entries. Also fixed along the way (not confirmed as the cause of a one-time
      window-move crash, but a real risk regardless): `BridgeClient`'s background thread now
      queues log lines instead of calling BepInEx's logger directly from a non-main thread.
      **Confirmed not a bug:** the magenta local ghost staying visible after closing the core
      and relay — expected, it has no network dependency at all.
- [x] Real character-visual ghost rendering (not in the original 6.1-6.6 outline — added because
      it's fully solo-testable via loopback, no second player needed). The remote ghost is now a
      real clone of the player's own visual object, not a placeholder box: correct body-anchored
      position (real offset measured, not guessed — see `verified.md`), correct left/right
      facing with all five sprite layers (base/outline/effect/flash/support) kept in sync, and
      real animation playback via the actual clip name sent over the wire
      (`SpriteAnimation.GetAnimationTrueName()`) instead of an invented enum-to-animation
      mapping. User confirmed "all combat animations & everything" plays correctly, not just
      idle/run/jump. Three real bugs found and fixed live getting here — see
      `agent_docs/verified.md`'s Phase 6 real-visual entry for the full list.
- [x] Confirmed the ghost does not visually intrude on TEVI's full-screen menus (Characters,
      Map pages tested), unlike Emerald's `gui.drawImage` overlay which needed an explicit
      `inOverworld()` gate. Structural, not luck: the ghost is a world-space `GameObject`
      rendered by the game's own camera, and TEVI's menus are a UI layer drawn on top, so the
      world (ghost included) naturally ends up underneath with no adapter-side gating needed.
      **Only resolves the visual half** of the still-open "don't send this frame" question —
      state is still sent to the network while a menu is open; whether a remote's ghost should
      visibly freeze during a peer's menu is a separate question. **Decision (2026-08-12):**
      leave current behavior (always send, no menu gating) as-is deliberately, not as an
      oversight — it can't be meaningfully evaluated without a second real peer to watch react
      to it, so revisit only if real 6.6 testing shows it's actually a problem, rather than
      guessing at a fix for something not yet observed to need one. See `agent_docs/verified.md`.
- [x] 6.6 — Two real players, confirmed live 2026-08-13. `BridgePort` (`Plugin.cs`) is now a
      BepInEx config value (default 7778, unchanged) instead of a hardcoded const, so a second
      local TEVI instance (build `14778703`, see Notes below) can run its own core process on
      its own port (7779) without colliding with the Steam copy. Two real core processes, one
      real (non-loopback) relay, both connected as distinct room members (`p3`/`p4`) — user
      watched both windows and confirmed a correctly-positioned, correctly-animated ghost in
      each. Along the way, removed two leftover diagnostics that were never cleaned up after
      being superseded: the Step 6.3 magenta placeholder box (still being created next to the
      real ghost every frame) and `RemoteVisualTestOffset` (an artificial -80-unit offset on the
      remote ghost's position, explicitly commented "must NOT ship for a real 6.6 test" — this
      *is* that test).
      - Cross-area filtering was a real, unaddressed gap (loopback always echoed your own area,
        so this was never exercised before): `internal/core` sent every known remote regardless
        of `area_id`. **Tested for real, same session**: user moved between genuinely different
        zones (not just rooms within one always-loaded zone) via a portal. The remote's ghost
        wasn't actually despawning on a zone change — confirmed by reading both BepInEx
        `LogOutput.log`s directly: `area=` changed `1→4→1→13→1` across five real transitions,
        but `"real remote ghost visual created"` logged exactly once, never again — the ghost
        object was never destroyed, just silently repositioned to another zone's raw
        coordinates every frame, invisible only because those coordinates didn't happen to land
        on screen. **Fixed same session**, game-agnostically in `internal/core`
        (`Core.remoteStatesAt` now filters by `area_id` equality against the local player's own
        current area) — see the 2026-08-13 ADR in `architecture.md`. Regression-tested
        (`TestCrossAreaFiltersRemote`) and **confirmed live, same session**: user redid the
        same zone-transition test and confirmed the peer's ghost properly despawns while in a
        different zone and reappears on return, both directions. Found and fixed one more
        minor cosmetic bug along the way: an idle peer's ghost reappeared at the correct
        position but stayed frozen (not animating) until they moved, because
        `DespawnRemoteGhost` never reset `LastAnim`, so reactivation with an unchanged anim
        string never re-triggered `Animator.Play()`. Fixed (`visual.LastAnim = null` on
        despawn), built and deployed, and **confirmed live, same session**: an idle peer's
        ghost now shows its default idle animation immediately on zone-reentry instead of
        staying stuck. See `verified.md`. TEVI's cross-area behavior is now fully confirmed,
        both the filtering itself and this cosmetic follow-on.
      - **New gap found and fixed live**: a player returning to the main menu (or the game
        closing) left their ghost frozen in the other player's world forever — no staleness
        timeout exists by design, and only a real relay disconnect despawns a remote. Fixed
        game-agnostically in `internal/core` (bridge disconnect now closes the relay
        connection) — see the 2026-08-13 ADR in `architecture.md`. Confirmed live (user watched
        both windows): closing the game entirely despawned the ghost for the peer; returning to
        the main menu did NOT (as scoped — the bridge socket was still open, so nothing told
        the core anything changed).
        **Extended, same session**: user also confirmed TEVI's Characters/pause overlay does
        NOT null `mainCharacter` (local-state logging kept flowing the whole time it was open,
        ghost stayed visible/moving for the other player — see `verified.md`), so the existing
        `player == null` check safely distinguishes a real menu return from a pause overlay.
        Added `BridgeClient.Disconnect()`, called from `Plugin.cs`'s existing
        `hadPlayerLastFrame` transition (fires once, on the real menu-return edge, not every
        frame at the menu) — reuses the same bridge-disconnect despawn path, `TryConnect()`
        redials automatically once back in a real play session. **Confirmed live, same
        session**: user retested both real instances — pausing still leaves the peer's ghost
        untouched, and both a main-menu return and a full game close now properly despawn it.
        See `verified.md`. 6.6's disconnect/reconnect behavior is gap-free; cross-area
        filtering above was confirmed live the same session (see the bullet above) — this
        sentence's "still needs a live check" was left behind stale and is corrected here.
      **No longer blocked on distribution** (2026-08-12): TEVI now ships in the single release
      zip (see `packaging/README.md`'s TEVI section), marked experimental/prerelease.
- [x] 6.7 — Started 2026-08-13, built and confirmed live the same session: show remote
      players' locations on TEVI's map screens (not just the world-space ghost, which only
      helps when a peer is on-screen with you). Decompiled `Assembly-CSharp.dll` with
      `ilspycmd` to scope feasibility before assuming an approach:
      - TEVI's map (`FullMap`, the pause-menu screen, and `MiniMapDisp`, the HUD corner one) is
        **room-grid based, not continuous-world-position based**. The relevant local-player
        facts are `WorldManager.Instance.Area` (byte, already sent today) plus
        `CurrentRoomX`/`CurrentRoomY` (`short`, **not currently sent** — the wire protocol only
        carries continuous world `position`, not room-grid coordinates).
      - `FullMap.GetRoomCode(area, x, y, from)` combines those three into one lookup key
        (`1000000*area + (x+y)*100` when `from: true`, `area*10000 + (x+y)` otherwise) matched
        against `FullMap.roomtilelist` (`FullMapTile[]`) to find that room's actual UI tile.
      - The local player's own position on the map is exactly one `SpriteRenderer` field,
        `FullMap.playerPos`, positioned via `EnablePlayerPos()` at
        `flashingTile.transform.position` (`flashingTile` being the `FullMapTile` for the
        player's current room). No existing multi-player marker system — but the mechanism is
        simple and clonable, the same "clone the real visual object" pattern already used for
        the world-space ghost (`CreateRealGhostVisual`).
      - **What this means for scope**: the wire protocol already carries `area_id`; showing a
        peer's room needs `CurrentRoomX`/`CurrentRoomY` added too — fits in the existing
        `extras` free-form dict (`contract.md`), no schema change needed. Adapter work would be:
        read the local player's `CurrentRoomX`/`CurrentRoomY` each frame (same place `Area` is
        already read), send them in `extras`, and on the receiving side clone `playerPos` per
        remote and reposition it via the same `GetRoomCode`/`roomtilelist` lookup `EnablePlayerPos`
        already uses.
      - **`roomtilelist` lookup mechanism confirmed** (read `MoveMapToCurrentRoom` directly, not
        inferred): `roomtilelist` is a flat array sized `MAXAREA * maxroom`, indexed as
        `area * maxroom + <slot>` — not a code-keyed lookup despite `GetRoomCode`'s existence.
        Finding a room's tile is a linear scan of that area's slice comparing
        `roomtilelist[i].GetX()/.GetY()` against the target room coordinates (exactly what
        `MoveMapToCurrentRoom` does for the local player's current room, and the same pattern
        repeated at every other `roomtilelist[i].GetX() ==`/`GetY() ==` site in the class) —
        the same scan, generalized to any remote's `(area, x, y)` instead of always "current,"
        is the real reusable mechanism for a remote marker.
      - Not yet done: whether `MiniMapDisp`'s HUD-corner display would need the same treatment
        separately from `FullMap`'s pause-screen version (`MiniMapDisp` looked more like a
        per-room grid-highlight tile than a marker-based system when read earlier — worth a
        closer look before assuming it needs its own remote-marker logic, or can be skipped
        in favor of `FullMap` alone for a first version).
      - **`SaveManager.Instance.GetRoomWalkedBool(area, x, y)` found**: a real, existing
        fog-of-war query — whether the local player has personally ever walked a given room.
        This is the answer to "how to avoid a peer's marker leaking map layout the local
        player hasn't discovered themselves": gate every remote marker on this being true for
        the local save, not just on the remote's own state.
      - **Built AND confirmed live, 2026-08-13** (the heading said "not yet confirmed live"
        until 2026-08-16; the block's own conclusion below always said otherwise). Implemented per the design above, wire
        protocol needed zero core/Go changes (`protocol.State.Extras` was already embedded in
        both `bridge.LocalState`/`bridge.RenderRemote`; the gap was purely that
        `BridgeClient.cs`'s hand-rolled JSON didn't touch `extras` at all). What landed:
        1. `BridgeClient.cs`: `RemoteState` gained nullable `RoomX`/`RoomY`, wired through
           `SendLocalState`'s outgoing `extras.room_x/room_y` and `DrainInto`'s parsing of
           `render_remote`'s `state.extras`.
        2. `Plugin.cs`: reads `WorldManager.Instance.CurrentRoomX/CurrentRoomY` each frame
           (`currentLocalArea` also hoisted earlier in `Update()`, before `bridge.DrainInto`,
           since the marker-gating logic runs synchronously inside it). Per-remote map markers
           tracked the same shape as `remoteVisuals`, lazily cloned from `FullMap`'s own
           private `playerPos` field (via reflection, same pattern already used for
           `EventManager.mainCharacter`'s cross-build shape difference) and tinted cyan.
           Cloned with the same transform parent as the original so it inherits `FullMap`'s own
           zoom rescaling (`GemaFixedSizeMapIcon.Update` was seen doing this explicitly against
           `FullMap.Instance.transform.localScale`) — reasoned from real code, not yet watched
           live to confirm the marker actually scales correctly with map zoom.
        3. Gating implemented as designed: `FullMap.Instance.isFullMap`, same-area-as-local
           (string equality on `area_id`), and `SaveManager.Instance.GetRoomWalkedBool` for
           fog-of-war. `FindRoomTile` mirrors `MoveMapToCurrentRoom`'s own `roomtilelist` scan,
           generalized to any `(area, x, y)`.
        4. `DespawnRemoteGhost` also deactivates the matching map marker now.
        Builds clean (0 errors against the real `Assembly-CSharp.dll` reference), deployed to
        both local installs. **Confirmed live, same session**: user opened the map and
        confirmed a marker shows at the other player's actual room. **Fog-of-war confirmed
        live too**: the marker shows for a discovered room and hides for one the local player
        hasn't seen yet — `SaveManager.GetRoomWalkedBool` gating works exactly as designed.
        See `verified.md`. Not yet separately re-checked: cross-area hiding of the marker
        specifically (distinct from the world ghost's own cross-area test), and whether the
        marker's size actually tracks map zoom correctly.

## Notes

- **TEVI build 14778703 runs two simultaneous local instances — confirmed 2026-08-13.** SteamDB
  build `14778703` (2024-06-20, <https://steamdb.info/patchnotes/14778703/>), depot `2230651`,
  manifest `7992513181981867642`, downloaded standalone via `steamcmd +login <user>
  +download_depot 2230650 2230651 7992513181981867642` (raw `download_depot` ignores
  `+force_install_dir` — it lands under `steamcmd`'s own `steamapps\content\app_2230650\
  depot_2230651\` and has to be copied out manually). A `steam_appid.txt` containing `2230650`
  was added to the standalone folder so `steam_api64.dll` initializes when launched outside
  Steam. With the normal Steam-launched TEVI copy confirmed running first, launching this
  standalone copy's `TEVI.exe` opened a second window at the title screen alongside it — user
  watched both windows side by side. See `agent_docs/verified.md` for the full entry.

  **This corrects the 2026-08-12 "confirmed not to work" v1.01-branch attempt below**: that
  attempt's "Unable to Sync" dialog is now understood to have been caused by the `steamcmd`
  login itself signing the user's normal Steam session offline (Steam allows only one online
  session per account), not by a genuine single-instance-per-app block. The "second instance did
  not start" conclusion from that attempt was never actually isolated from that confound — kept
  below for the record, but treat its conclusion as superseded, not as an independently-confirmed
  mechanism.

  6.6 (two real players) can now proceed with local dual-instance testing instead of needing a
  second machine. At the time this was written it only proved "both processes launch", with the
  actual gameplay/multiplayer test still open — **6.6 closed 2026-08-13**; see this file's status
  line at the top.

  **Original (2026-08-12) v1.01-branch attempt, superseded, kept for the record:**
  `steamcmd` downloaded the `v1.01` branch (app `2230650`, depot `2230651`, buildid `12996163`,
  manifest gid `5205106925268362993`, confirmed via `steamcmd +login anonymous
  +app_info_print 2230650`) into a standalone folder outside the normal Steam library. With the
  real Steam-launched copy already running, launching the standalone `v1.01` exe directly hit
  Steam's own "Unable to Sync" cloud-save dialog before it would even start — meaning the exe
  still calls into the locally running Steam client on launch (consistent with
  `steam_api64.dll` + `SteamAPI_RestartAppIfNecessary`, which re-routes a direct exe launch
  through Steam whenever a `steam_appid.txt` is present). After clicking through, the second
  instance did not start. At the time this was attributed to Steam's single-instance block being
  tied to the Steam client's enforcement per app ID regardless of build — see the correction
  above for why that attribution wasn't actually isolated from the steamcmd-login-kicks-Steam-
  offline confound.

- **Dev-only toggle, remember to revert:** `BepInEx/config/BepInEx.cfg`'s
  `[Logging.Console] Enabled` was flipped `false` → `true` on this machine (2026-08-12) so a
  console window shows live log output while building/testing the TEVI adapter. This is a local
  config file, not something MeshGhost ships or touches programmatically — but note it here so a
  future session doesn't mistake it for a MeshGhost-caused change, and so it gets turned back off
  once Phase 6 dev work settles down (not urgent, not user-facing, just noise otherwise).

- **Packaging landed (2026-08-12):** the one-zip rework (`plans.md`'s "Release packaging",
  `packaging/README.md`) shipped with TEVI support built in from the start —
  `packaging/release/games/tevi/MeshGhost/MeshGhostTevi.dll` is a committed build output (CI
  can't build it, see `packaging/README.md`), produced by `dev-scripts/build-tevi.bat` and
  guarded by a staleness check in `release.yml`. Anyone editing `Plugin.cs`/`BridgeClient.cs`/the
  `.csproj` must re-run that script and commit the result, or the release workflow fails on
  purpose.

- **Bridge hello / `game_id` ADR, same day follow-up (2026-08-12):** the adapter now declares
  `game_id` itself (ADR in `architecture.md`), and `"game"` was dropped from the shipped
  `config.json`. A new bridge message, `internal/bridge.Hello`, is sent by the adapter as the
  first thing on a fresh bridge connection; `internal/core.Core.ConnectRelayOnAdapterHello`
  connects to the relay lazily on that hello instead of requiring `-game`/`"game"` up front. Both
  shipped adapters updated and TEVI's committed DLL rebuilt to match. `-game`/`"game"` still work
  as an explicit override, needed by `dev-scripts/run-core-*.bat` (each game's dev launcher still
  passes it explicitly) and `cmd/meshghost-fakeadapter` (no real adapter to send a hello).

- **Found live 2026-08-15, not yet fixed: charged-attack VFX missing on the ghost.** Holding the
  attack button does a couple of quick attacks then a charged big attack; the ghost's *animations*
  play correctly for all of it (base sprite/Animator state is mirrored, per the outline/effect/
  flash/support-sprite flip sync at `Plugin.cs:424-428`), but the extra visual effects that go
  with the charged attack (the burst/slash-style VFX distinct from the character sprite itself —
  see the screenshot in the session this was found) do not render on the ghost. Not yet
  root-caused; flagged here so a future session doesn't rediscover it from scratch. Working
  theory, unconfirmed: `Plugin.cs` currently mirrors position/anim/facing and the base
  outline/effect-sprite flip, but has no field carrying an attack-VFX-spawn event — if the real
  game triggers that VFX via a direct spawn call or Unity animation event tied to the *real*
  player's own input/hitbox logic rather than something already exposed through the mirrored
  Animator state, replaying the animation alone would never re-trigger it for a ghost. Needs a
  real investigation (what actually spawns the VFX game-side, is it read into `local_state`
  today or not) before touching code — per `CLAUDE.md`, no fix without a cited source for what's
  actually happening.

## 2026-08-14 — the review sweep, as it reached TEVI

**Backfilled 2026-09-11 from the commit log.** Not a TEVI session; the repo-wide server/client +
adapter review sweep (`c72472ff`, ~15 real bugs across the Go core/relay and all three adapters)
landed TEVI's share the same day: the stale-thread generation guard, `TcpClient` disposal, a real
`Destroy()` on ghost/marker despawn, `OnDestroy`/`OnApplicationQuit` bridge close, a `room_x`/
`room_y` range check, and `TryGetValue` in place of unguarded `JObject` casts. `0f34b115` added the
relay's `MaxClients` cap and join/leave/reject visibility; `627bccaf` filled in this file's own
missing build-log milestones and gave Emerald its dedicated Phase 8. Full record: `phase8.md`'s
2026-08-14 sweep task, which is where that cross-cutting work was logged at the time.

## 2026-08-18 — TEVI starts its own client, and one vague word cost a regression report

**Backfilled 2026-09-11.** Nine commits, and **the one worth keeping is not a code fix.**

- **`f0782b0d` — "menu" is not a state in a game with two menus.** The agent told the user TEVI
  peer ghosts would *"vanish when you open a menu."* In TEVI that reads as the PAUSE menu, where
  ghosts staying visible is the wanted behaviour — so the user read it exactly that way and told
  the agent to put it back. **The code was right.** This file already recorded, confirmed live
  2026-08-13, that the Characters/pause overlay does not null the player, so `player == null`
  safely distinguishes a real main-menu return from a pause overlay. **The defect was entirely in
  how it was described.** The log line and comment now say *main menu*, say loudly that the pause
  overlay must keep its ghosts, and the log line is self-verifying: if it appears when the pause
  overlay opens, the premise is wrong and the despawn goes. The game fact — pause keeps the
  player, title drops it — was missing from `tevi/documentation.md` entirely and was added.
  **This is the origin of the root `CLAUDE.md` rule "Name the exact state: 'main menu', never bare
  'menu'".**
- **`7be4ecee` — TEVI starts its own client, and takes it down again**, with `dac6d0b7` writing
  autostart down as an intended feature of every adapter rather than a TEVI convenience.
- **`d88849e1` — three stacked bridge bugs, and a DLL that could not have talked to a peer.** The
  adapter drained the bridge ABOVE the "is the local player in play" gate, so a remote's state
  could create a ghost while there was no local player at all — the exact thing the gate exists to
  prevent — and the null branch disconnected without despawning, leaving every peer ghost frozen
  in menus and between sessions. It also dumped `bridge_ready` and `reject` into its
  unknown-message-type default, so **every healthy session warned about the one message meaning
  everything was fine**, and a rejection was talked straight past — the adapter kept pushing
  `local_state` at a core that had already refused and closed. And the compiled DLL predated a
  `PluginVersion` bump to 0.2.0: **`game_version` mismatch is a hard reject at the relay, so the
  shipped artifact could not have talked to a peer built from its own source.** The send gate
  `PROTOCOL.md` requires was deliberately left to a later pass and registered as entry 5 in
  `tevi/BANDAGES.md` — getting it wrong trades a cosmetic warning for total silence.

## 2026-09-04 — one adversarial corpus for all four harnesses

**Backfilled 2026-09-11.** `726ad391` gave the four bridge-decoder harnesses a single shared
adversarial corpus, TEVI's included — and the commit records that **the audit which scoped it was
itself wrong**, which is the part worth keeping.

## 2026-09-08 — the fuzz harness was asserting nothing, in the file that warns about it

**Backfilled 2026-09-11.** `c00fab81`, and it is the cleanest instance of this repo's most expensive
failure shape. `BridgeFuzz.cs` fed `extras` keys `"anim_time"` and `"temp_pause"`; the decoder reads
`"anim_t"` and `"pause"`. **Every value decoded to null**, so the loop whose entire purpose is
proving a non-finite value cannot reach a callback inspected NOTHING and printed *"0 reached a
callback non-finite (want 0)"* unconditionally. The 18 state-level cases had the same problem one
level up. **That is the failure the file's own header cites from 2026-09-03, reproduced inside the
file that cites it.**

Fixed keys, plus the assertions that make the counter mean something: a raw narrowing to a finite
float must arrive WITH that value (computed independently, not hard-coded), a non-finite raw must
arrive absent, and the category now FAILS if zero values ever reach a callback. **The evidence that
it now exercises what it claims is the part that matters** — putting the old key names back produces
26 "arrived absent" failures, and forcing the finiteness helper to claim every raw is finite
produces exactly 18, the nine non-finite forms times two fields. Lines fed rose from 176 to 277.

## Repo-wide sweeps that touched this adapter's files — 2026-08-19, 2026-08-21, 2026-08-25

**Backfilled 2026-09-11.** Days this adapter's files changed without a TEVI session: `ec5d7734`
(2026-08-19, docs matched to code, ghost collision given a host-set switch), `c4017f7d`
(2026-08-21, every doc read against the code) and the 2026-08-25 restructure — the
`adapters/bizhawk/` → `adapters/emulator/` rename, `verified.md`/`unverified.md` split per game,
every record given an index with a preflight gate behind it, and `_template` shipping the three
files it had always mandated (`73936944`, `1b015338`, `c9ceb659`, `8646a7e5`, `abbf7c8a`,
`ad986443`, `1a303ee5`, `02ab4afa`).

## 2026-08-27 — TEVI leaves its fixed bridge port

**Backfilled 2026-09-01; given its own heading 2026-09-11.** The 8-port walk, the send gate, and
port-walk convergence with the other three adapters (`74609a6`, `5634d10`, `9a34500`).

## Catch-up record, written 2026-09-01 — the 2026-08-28 session (and 2026-08-29) that closed the question above

This file sat unwritten while the work happened; backfilled from the commit log and
`adapters/tevi/VERIFIED.md`, which carries the dated evidence for every item. The 2026-08-27 bullet
became its own section 2026-09-11; 2026-08-29's dust commit stays here, inside the session arc it
belongs to.

- **2026-08-28, the hot-reload session** — the live-reload loop was proven in-game via BepInEx
  ScriptEngine, after three green-but-did-nothing deploy bugs (`306377f`, `9905cf8`, `7cddef2`,
  `c42b6cb`), and it carried the rest of the day:
  - **The charged-attack VFX — this phase's final open question — was answered and confirmed on
    a ghost** (`fac154e`, `10697c1`, `07b3d89`): the effects are POOLED and never parent to the
    character, found by `DIAG_SPAWN_DIFF` returning a clean negative and `DIAG_POOL_WATCH`
    naming both effects on its first run (`PROBES.md`). Mirrored by pool key.
  - Afterimage trails on peer ghosts (`8ce0a44`); warp devices wake for a ghost, mirroring Stay
    rather than Enter/Exit (`d5aeef5`, `1b4930b`); ghost dust lands per hop (2026-08-29,
    `90c3562`).
  - Animation PHASE sync, the perfect-timing effect, and hitstop mirroring (`e2b7447`), measured
    with the new `DIAG_HITSTOP_PHASE` probe.
  - Map markers went frame-driven with a 1s stale-hide (`81bc6b8`), peer anim names got bounds
    (`42596d4`), the main-menu despawn got its core-side answer (`bdd1e02`), and ghosts survive
    core restarts (`2fb2ebf`).
  - Change suppression measured at ~70% of states suppressed in real play (`a2f309a`,
    `0d030a2`), and TEVI shipped a 175ms per-game interp default (`1a5aa5b`, `c2dc3b7`) — raised
    to 300ms on 2026-09-01 to price a real link.

The phase's open question is therefore CLOSED; what remains open for TEVI lives in
`adapters/tevi/UNVERIFIED.md` and `agent_docs/status.md`, not here.

## 2026-09-02 — the documentation pass, as it touched TEVI's files

No adapter code changed. The repo-wide pass (`agent_docs/doc-history.md`, 2026-09-02) reworked the
documentation mechanisms; this is what it did to this adapter's files, logged here because a phase file
is the complete running log and preflight now fails one that falls behind its adapter.

- `UNVERIFIED.md`: every entry tagged READY/OPEN/DONE (9/3/1) and a "This run — watch these first" block added at the top; the interp 175→300ms item and the portal-visual item are the READY/OPEN heads.
- `CLAUDE.md` (Unity host rules) compressed its cap paragraph and gained the pointer to `agent_docs/checklists/before-mirroring-state.md`.
- `PROBES.md` link fixes for the one-name-everywhere rename.

## 2026-09-02 (late) — pointer: TEVI's night is logged in phase9

The full session is [phase9.md](phase9.md), "2026-09-02 (late)". What touched this adapter: the portal that
stayed awake after the last ghost disconnected, fixed and watched (`8d6a67a`, `tevi/VERIFIED.md`); the
launcher that forgets a child the port walk has moved off, written, reproduced and recovered, then revised
to "wait on your own child, forget it only on busy" (`8d6a67a`, `e3c11dc`, `9b79429`); the interp ladder on
the fixed relay (300ms on the milder proxy, `e33f31f`) and again on the worst-case proxy (450ms, `4e619b5`,
`tevi/VERIFIED.md`); 450ms shipped for every game (ADR 0046, `0cd52a9`).

## 2026-09-03 — `"autostart"` moves into config.json (TEVI)

The user's ask, the morning after the config restructure: the "don't start a client" switch was an
environment variable, and *"even me that is somewhat tech savvy, has no clue what 'an environment
variable' means"*. All four launchers now read `"autostart"` from the config.json the client will read,
the variable still counts, the READMEs are rewritten around the key. Built and deployed, unwatched
(`UNVERIFIED.md`). The user's follow-on thought -- game-specific settings in the same file instead of
in-game menus -- is filed in `ideas.md`.


## 2026-09-03 — the bridge decoder gets a hostile-input harness, and it needed no adapter change (with 2026-09-05, the client's move to the TEVI folder)

From the adapter-fuzzer entry in `ideas.md`. The plan assumed TEVI would need a refactor first — split
the parse out of `DrainInto` so a test could reach it. **It does not.** `BridgeClient.cs` imports only
`System.*` and `Newtonsoft.Json`; `RemoteState` is a plain object of strings, floats and nullable ints;
and every mention of `Plugin` or `CoreLauncher` in the file is inside a comment. So the whole path from
bytes to callback arguments compiles and runs with no Unity, no BepInEx and no game.

That makes this the **strongest** of the three adapter harnesses: it reaches the DISPATCH, not just the
decode. Both Pokémon decoders can only be exercised as far as the parse, because their dispatch sits
thousands of lines further down, past the point where the file starts calling BizHawk.

**Where it lives, and why that is not arbitrary.** `MeshGhostTevi.Tests/`, a SIBLING of
`MeshGhostTevi/`. Not inside it, because that project is a plain SDK project with no explicit
`<Compile>` items: default globbing compiles `**/*.cs`, so a test file dropped in there would be built
straight into the shipped plugin DLL. `release.yml`'s staleness gate would not have caught it either —
it hashes an explicit four-file allowlist, so a new file changes nothing it checks. Worth knowing
independently of this work.

`BridgeClient.cs` is compiled by link, never copied, and the adapter source is not modified at all: the
queue `DrainInto` reads is private, so the harness reaches it by reflection, and fails loudly at startup
if that field is ever renamed rather than silently testing nothing.

**Findings: none, which is a result and not a blank.** 60 lines through the shipped decoder — malformed
envelopes, wrong-typed payloads, non-finite positions, embedded NULs, duplicate keys — and it survived
every one. Deep nesting is refused at 32 levels of `extras` by Newtonsoft's own `MaxDepth`, with
`DrainInto`'s catch turning the refusal into a dropped line, which is the correct outcome; the number is
printed on every run so a Newtonsoft upgrade that moves it is visible. Fourteen hostile peer ids —
traversal strings, format specifiers, an RTL override, a 4000-character id — all arrive at the callback
as the string they were.

**The control matters and it earned its place immediately.** The first run reported "0 renders" for
every input, which reads exactly like a broken decoder; it was a broken TEST, using a flat payload when
`bridge.RenderRemote` nests the sample under `state`. Without a control asserting that valid input
still dispatches, that harness would have passed forever while exercising nothing — the same failure
found in a Go fuzz target the same day.

CI: `tevi.yml`, path-filtered on `adapters/tevi/**`, Linux runner. It cannot build the plugin (that
needs the user's own game assemblies) and does not try to.

**2026-09-05 — the client and its config move to the TEVI folder; the plugin looks nowhere else.** The
user's call, made on Pseudoregalia and applied to both UE launchers the same afternoon: `meshghost.exe`,
`config.json`, `meshghost.log` and `replay\` live in the game's root (the folder with `TEVI.exe`), the
DLL stays in `BepInEx\plugins\MeshGhost\`. `CoreLauncher.cs`'s search list is now `MESHGHOST_CORE_DIR`
then `Paths.GameRootPath`; the plugin folder and `BepInEx\scripts` are no longer fallbacks, the start
log names the folder used, and `tevi-hotreload.ps1` checks the root. Staging puts TEVI's config at
`games/tevi/config.json` beside the README. Built, deployed to both installs (Steam and the standalone
copy) with the files moved up -- **UNWATCHED on TEVI**; Pseudoregalia's half was confirmed on screen
(`../../adapters/pseudoregalia/VERIFIED.md`). Queue: `../../adapters/tevi/UNVERIFIED.md`.

## 2026-09-06 — the documentation fact check, as it touched TEVI's files

No adapter code changed. The repo-wide pass (`agent_docs/doc-history.md`, 2026-09-06) compared every
doc against the code; this is what it corrected here, logged because a phase file is the complete
running log.

- `README.md`: the DLL date (2026-09-05, per `built-from.txt`, not 2026-08-28); the game-root lookup in "Building it"; steps 13 (anim-phase suppression, `VERIFIED.md` 2026-08-28) and 14 (a portal settles on disconnect, `VERIFIED.md` 2026-09-02).
- `FLAGS.md`: rows for `"autostart"` and `"local_game_bridge"` (config.json, 2026-09-03 / 2026-08-28), the `BridgePort` tie-break, and seven bridge constants that had none; the "only the three environment variables" paragraph rewritten.
- `CLAUDE.md`: the configuration rule now says config.json first, BepInEx second, never a new env var.
- `BANDAGES.md` entry 7 gains the disconnect edge; `PROBES.md`'s garbled first paragraph fixed. The shipped `packaging/release/games/tevi/README.txt` bridge-port paragraph, which contradicted `Plugin.cs`, was fixed in the player-facing commit.
- This file's header: "fully done" and the dead `status.md` pointer replaced with the live-log framing (the user, 2026-09-06: every adapter stays open).

## 2026-09-06 — TCP_NODELAY, from a Pseudoregalia diagnosis that applies to every bridge

TEVI's `BridgeClient` dialled with a bare `new TcpClient()`, and .NET leaves `NoDelay` false. That
is the same defect measured on Pseudoregalia the same day: the bridge writes one small JSON line per
frame, Nagle holds each write until the previous is acknowledged, and on Linux the receiver's
delayed-ACK floor is 40 ms. A Linux/Proton tester's Pseudoregalia clips showed 27-30% of updates
more than 25 ms apart with a hard floor at exactly 40 ms and identical movement per sample on either
side, which is delivery bunching rather than frame rate.

Nothing TEVI-specific was measured -- this is the fix applied across all four adapters at once,
because none of the three runtimes enables the option by default and each adapter was written
separately. `c.NoDelay = true` before `Connect`. Unbuilt and unwatched on TEVI; the Pseudoregalia
DLL is the one that was built and deployed. Detail and the measurements:
`agent_docs/pitfalls/by-lesson.md`, 2026-09-06; `dev-scripts/replay-cadence.py` is the check.


## 2026-09-07 — the "core not found" message stops naming a folder nothing searches

Part of the repo-wide stale-fact sweep (`phase10.md`); TEVI's share was one string and one rebuild.

**The defect.** `CoreLauncher.cs:100-102` told a player whose `meshghost.exe` was missing to put it
"in the TEVI folder (the one with TEVI.exe) alongside config.json, **or in the MeshGhost plugin
folder beside MeshGhostTevi.dll**". Nothing has searched that second location since `31242013`
(2026-09-05) moved the client, `config.json`, the log and replays to the game root —
`CoreSearchDirs()` yields `MESHGHOST_CORE_DIR` then `Paths.GameRootPath`, and its own comment says
the override "is not the mod folder".

**Why it was worth a rebuild for one clause.** Every other stale thing this sweep found misled a
*developer* reading a doc. This one misled a **player**, in the error path, at the exact moment they
are already stuck — they follow the advice, put the exe in the mod folder, and it still does not
work. The docs were all correct; the string was the only leftover.

**Built, deployed, and checked in the binary rather than the source.** `build-tevi.bat`, then the
DLL copied into the Steam install's `BepInEx\plugins\MeshGhost\`; deployed and built copies hash
identically, and reading the strings out of the deployed DLL shows the message ending
`...alongside config.json; if it was there, check whether antivirus removed it.` with the mod-folder
clause absent. Preflight's deployed-copy check confirms the same, with `MESHGHOST_TEVI_DLL` set.

**What is left, and it is small.** The standalone dual-instance install was NOT updated — its path
lives in `MESHGHOST_TEVI_DIR2`, which is unset in this shell, and it is deliberately not committed.
Deploy there with `tevi-hotreload.ps1 -Both` (or a copy) before any dual-instance session, or that
copy keeps the old message.

**Unwatched, and barely worth watching:** the changed line is a string literal in a branch that only
runs when `meshghost.exe` is absent. A normal launch never reaches it, so the confirmation that
matters is simply that the mod still loads. Seeing the new text needs `meshghost.exe` renamed away
first.

**Watched the same day.** Both installs launched together, ghosts spawning, moving, animating and
facing correctly in both windows — so the rebuild broke nothing and the whole chain is intact on the
freshly-deployed pair. The changed message itself was NOT seen and could not be: it prints only when
`meshghost.exe` is absent and both installs have a current one.

**Two log lines the session raised, both checked and neither a defect.**

`ignoring unknown bridge message type 'session_policy'` / `'recording_state'` — pre-existing (a
`default:` branch in `BridgeClient.cs`, last touched 2026-09-06 for TCP_NODELAY; this rebuild
changed one string in `CoreLauncher.cs`). TEVI implements neither by design: it cannot do ghost
collision at all (every `Collider2D`/`Rigidbody2D` is stripped at ghost creation, ADR 0035) and has
no recording indicator. **The wording is the real defect** — they are not *unknown*, they are known
and deliberately unimplemented, and `adapters/CLAUDE.md:170-172` asks for one line at STARTUP saying
so rather than a per-message "unknown". Already tracked (`status.md`, ADR 0035's "What is still
owed"); now also seen live.

`MeshGhost local state: ...` repeating while standing still — **MEASURED rather than argued, after a
first answer that reasoned from the code and was not good enough.** Counting the lines in
`BepInEx/LogOutput.log` over 12 seconds of an idle player gave **3 lines, 0.25/sec** — exactly the
5-second heartbeat (`MaxSilenceSeconds = 5f`), against ~60/sec if it were per-frame. So a pasted
block of sixteen identical lines spans about seventy-five seconds of standing still, not sixteen
frames. The throttle (`Plugin.cs:2509-2528`) is working: immediate on a discrete change (dir, anim,
area), at most every 0.5s while moving, 5s heartbeat when idle. Note `clip` is deliberately NOT part
of the change test, which is why `clip=brake` → `clip=stand` alone does not trigger a line.

**The lesson, and it is this repo's own:** identical lines pasted together carry no time axis, and
neither the code nor the paste could say which of "every frame" or "every five seconds" was
happening. Counting them against a clock took one command and settled it; reading the source twice
would not have.


## 2026-09-10 (later) — the projectile mirror's premise was too narrow: a bullet is not a pure function of its birth

**The report.** The user, on the projectile mirror of commit b3b3ede9 (2026-09-10, the same day): the ghost's shots were
*"not going as far as intended"*; some of their own shots *"hit walls/split in different directions
afterwards etc but the ghost don't do these"*; some core expansions' projectiles *"just go a really
short distance compared to what it looked like on the players screen"*; and *"some core expansions
still don't do their action/vfx/projectile things"*. Asked whether "bouncing" meant the ghost's
shots moving wrongly or failing to move like theirs, they picked the second, and added: *"think we
should just test all of them / assume nothing is working correct yet"*.

**What was wrong, and it is a textbook case of the right measurement generalised too far.**
`DIAG_BULLET_WATCH` had measured every bullet it saw flying with zero speed and angle drift, and
the mirror was built on the conclusion "a bullet is a pure function of its birth". Read out of the
game's own `bulletScript.BulletBehave()` — a switch on `BulletType` — the orbitar families that
move themselves change **neither speed nor angle**: `ORB_CHARGED_SABLE_TYPEB` steps its own
position up and down every physics tick (the zig-zag), `ORB_CHARGED_CELIA_TYPEC` turns 180°, homes
and then accelerates past 1.6s, `ORB_CHARGED_SABLE_TYPEC` falls on a curve, `ORB_SHOT_NORMAL` homes
when its counter 3 says so, `ORB_CHARGED_SABLE_TYPEA` stops dead. The probe was not wrong about
anything it reported; the two fields it watched were simply not where those families live.

**The fix is the repo's own rule rather than a bigger reconstruction:** the dormant bullet is
handed to the game's own `BulletBehave()`, from `FixedUpdate`, on `MainVar.fixedDeltaTime` — the
same tick `BulletManager` gives the real ones, which matters because a type that counts physics
steps to decide when to turn is not the same bullet if it is stepped once per frame. Reimplementing
five families' motion would have been the Stage-2-capsule mistake from
[`effect-investigation.md`](../effect-investigation.md) in a new game.

**Why that is safe on a machine that did not fire the shot**, and both halves are guards rather
than hopes: the bullet is not in `BulletManager`'s pool and never hits anything, so every branch
behind `hitlist.Count > 0` — the bombs, the meter spend, the camera shake, the sub-bullet spawns —
is dead code for it; and `GuardedBulletBehave` zeroes `useChargeRemove` for the duration (several
charged families erase bullets in an area while it is set, and those would be the *watcher's*
bullets) and despawns anything the call put in the real pool anyway. `ShootBullet` never returns
null — it hands out a dump slot when the pool is full — so "the call cannot spawn" was never
available as an argument, only "the spawn is undone".

**Three more defects found by reading rather than by the symptom**, each of which alone shortens a
ghost's shot, and the first of which is most of what the user saw:

1. The flat 1.5s kill was read from `EnableMe`'s `life`, which `_Update` applies **only while the
   bullet is off screen**; the hard cap is `TimeDelete`, defaulted to infinity. An on-screen
   charged shot outlives 1.5s easily.
2. `bulletScript.time` is **public**, and the reflection lookup asked for `NonPublic` only — so it
   returned null and the sprite-advance branch it gated had never once run. **A reflection lookup
   that fails is silent by construction**, which is the general lesson: the branch had shipped,
   been reviewed and been described in a commit message without ever executing.
3. `ShootBullet` sets a bullet's sprite through `BulletManager.SetSprite` for any sprite id under
   91, and the mirror skipped that step, so a clone off the prefab wore the prefab's sprite. The
   pooled-effect families hid it, because they draw nothing through that renderer at all.

Plus a genuine timing bug: a birth is up to a send interval old when it arrives, so a bullet
spawned at its **birth position** starts behind the one it mirrors and dies short. The row carries
the bullet's own age now and the spawn replays those steps at the game's own rate.

The extra birth state (size, counters, flags, both lifetimes) rides in ONE packed cell — bullets
are the field `BridgeClient` drops first at the core's 1024-byte extras cap, and a cell per field
would have been paid for in whole shots that never appeared during a core expansion's burst.

**Left open, and the user should be told rather than surprised by it:** a burst wider than about a
dozen births in a single frame still loses rows at that cap, which is a transport question and not
a per-row one. Nothing here has been seen on screen —
[`adapters/tevi/UNVERIFIED.md`](../../adapters/tevi/UNVERIFIED.md) carries the six things to look
at, in order.


## 2026-09-10 (evening, live two-instance session) — projectiles: the behaviour call comes OUT, and walls are the watcher's own question

**The session in one line:** the `BulletBehave`-on-a-ghost design from earlier the same day damaged
the watcher and was switched off within minutes; everything that made projectiles right afterwards
was done WITHOUT running any game code on the watching machine.

### 1. It damaged the other player, and the switch came before the diagnosis

User, minutes into the test: *"some projectiles are hurting the other player"*, then *"when
standalone shoot, steam takes damage from some of them"*. `GhostBulletsRunGameBehaviour = false`
was hot-deployed immediately and *"haven't seen anything deal damage, i shot a few times now"* is
the A/B. **The path was never pinned to a line and the switch stays off regardless**: `BulletBehave`
reaches ~580 `ShootBullet` sites plus `CreateBomb`, `CreateLaser`, `WallAction`, tile destruction and
`CameraScript.Shake`. The two guards it did have proved only that *bullets* it spawns are
player-owned on the watcher and therefore hit enemies — so the damage came through something the
bullet-pool guard could not see. A guard that covers one of six escape routes is not a guard.

### 2. Two symptoms, one cause that was not in the adapter: the installs are different game builds

*"shooting white circles"* and *"the blue orb is sometimes shooting red"* turned out to be the same
thing. The standalone is an old TEVI build, the Steam copy current (`Assembly-CSharp.dll` 4,614,656
vs 5,274,112 bytes, build 24159771), so `BulletType`/`SpriteType` ordinals disagree: the old build's
`ORB_LOCK_NORMAL / SHOT_CYAN` decoded on Steam as `lily_groundbreak / effect_ring1`, a white ring.
Enum NAMES now ride the wire and win over the ordinals. User: *"no more white circles, they are
properly shotting the correct red/blue bullets now"*. **The user's call, which is now a project
constraint:** cross-build play is a supported case — a Steam update does this to real players, and
it is also the only two-client rig this machine has.

Two wrong turns worth not repeating, both mine: decoding the sender's numbers with a hand-parsed
enum table from the *other* build's DLL (print `enum.ToString()` on the SENDER), and looking the
effect pool up by prefab NAME — every orb effect prefab is called "Orb".

### 3. Walls, eight builds, and the two lessons that generalise

*"can we fix bullets not dying if they hit a wall?"* — and then five rounds of it being nearly
right. What it took, in order: report the death on the frame the bullet STOPS (`isDespawning()`)
rather than when its pool slot frees ~0.15s later; carry the stop POSITION with the death and snap
to it; run the game's own wall test on the watcher (a pure read — the tile-grid arm is area data
valid anywhere, the collider arm is room-local and stays gated); and finally mirror the
`CannotPassWall` flag the lock-on shot **grants itself in flight**, per pool slot, for the bullet's
whole life. Confirmed: *"it works now"*.

The two transferable lessons are in [`pitfalls/by-lesson.md`](../pitfalls/by-lesson.md) — a
mirrored object's state is not a birth fact, and never destroy an object another system still holds
(that one cost 53,333 `NullReferenceException`s and effects stuck on screen forever, invisible in
BepInEx's own log because `WriteUnityLog = false`).

**The measurement that ended each round was the same shape every time:** log what the SENDER decided
and what the WATCHER made of it, on the same event, and compare. Deltas of 0.0 across hundreds of
kills are what proved the snap and the local wall test exact; the residue always had a name.

### 4. Left open

- **Birth rows are being lost entirely** — flag updates arrived for bullets the watcher never
  created (`spawned=False`). Almost certainly the extras-cap trim dropping rows oldest-first while
  the receiver's sequence counter advances past them. Shows up as missing shots under fire.
- **The families that move themselves still fly straight** (Sable charged B's wave, Celia charged
  C's homing). They need the replacement for the behaviour call: the shooter sending a small
  correction row only for bullets it sees deviate from their birth line.
- **The remaining build-dependent ordinals**: the follower-effect pool index (checked, with a
  same-family fallback), the two muzzle-flash pools, and the orb/summon/shield rows from the
  previous session.

## 2026-09-10 — the queue drains, five beats land, and one of them was wrong on arrival

**The record was the blocker, not the work.** TEVI's `VERIFIED.md` stopped at 2026-09-02 while its
queue ran to 2026-09-10 — orbitars, core expansions, the boost shield, the trails and projectiles
all sat in `UNVERIFIED.md` with the user's own confirmations beside them. Two agent misreadings, and
neither was the user's judgement:

1. **"think" was read as doubt.** It is not. The user, 2026-09-10: *"looks correct, think its
   perfect now etc. means its done/verified"*. Only voiced uncertainty queues.
2. **A hold was invented on COVERAGE** — *"held until a second session repeats it, the confirmation
   was one set of shots"*. No rule asks for that, and it names no trigger, so nothing could ever
   release it. Two entries said so outright; a third, in Pseudoregalia, survives on the
   intermittent-fault clause and was given the trigger it was missing.

Drained on the quotes already in the files, each entry naming the quote it drained on. Two new
`VERIFIED.md` entries: the 2026-09-10 mirroring evening, and projectiles — the second written as
what it is, *"in a good state, but not fully synced"* (user), with the unmirrored shots listed
rather than claimed.

**Five beats, not twenty.** The 2026-09-10 work is many queue entries and few capabilities, so the
orbitars, the crystal trail, the dodge fade, core expansions and the boost shield are ONE beat, and
projectiles are another. The two lessons that paid for the evening are carried inline because
without them the beat is just a list of things that now mirror: a clone of a component the game
parks INACTIVE is born with `Awake` unrun (so every cosmetic sub-feature is now walled in its own
try/catch), and a shader keyword the game strips from its own template meant the barrier popped
instead of blooming.

**`documentation.md` covered 2 of the 18 game types the adapter reflects.** It now carries warp
devices (the whole visual is in `Update`; every side effect is in the triggers; the heal goes to the
local player rather than to whoever entered), the bullet pool and why a death is not a despawn, core
expansions, the boost shield, and how the game picks an afterimage trail. The bar applied: whether
the GAME's mechanism is established, not whether our mirror of it was watched — which is why the
trail's order of precedence went in while the adapter half of it is still queued.

**A new beat was wrong on arrival, and the user caught it.** Beat 17 said 450ms *"was measured and
deliberately not shipped"*, taken from the `VERIFIED.md` entry of 2026-09-02, which says exactly
that. It was true for that hour. **ADR 0046, decided the same night, made 450ms the shipped default
for every game** — `core.DefaultInterpolationDelay` and all four per-game configs carry it. So a
brand-new beat asserted a shipped value that had been wrong since 2026-09-02. The user's rule out of
it: **before writing a build-story beat or a documentation section, fact/stale-check it against the
code** — the record supplies what happened and what was said, the code supplies what is true now,
and they are different lookups. *"or it just ends up being something that is wrong twice, or
something we have to change again directly afterwards anyway."*

The retro-check that followed found one more: beat 15 described the hot-reload loop as ScriptEngine
simply loading the plugin from `scripts\` with no keypress. The script is a **toggle** — the two
locations are mutually exclusive on purpose, because with the adapter in both, two plugin instances
run, which is two bridge connections and two ghosts per peer, *"and every reading agrees with itself
while being wrong"*. Rewritten to say that, plus the two faults the loop can never show: a cold-start
fault, and anything the old instance left parented into the scene.

## 2026-09-11 — TEVI's share of the review backlog (full record in phase10.md)

Seven findings from the 2026-09-07 adversarial review, built and deployed to both installs,
**UNWATCHED** — `UNVERIFIED.md` carries what to watch. Two of them are things another player
could do to this one:

- **I22 (HIGH):** `Mathf.Abs(int.MinValue)` THROWS, and since the 2026-08-28 frame-driven refresh
  the map-marker bound runs from `Update()` rather than inside `DrainInto`'s per-line catch — so a
  peer sending `room_x: -2147483648` killed the victim's whole `Update()`, `SendLocalState`
  included, and the victim vanished from every other player's screen. A plain range test also fixes
  the bound itself: `int.MinValue <= 100000` was true.
- **I21 (HIGH):** the bridge write is a blocking write on Unity's MAIN THREAD and .NET leaves
  `SendTimeout` infinite, so a core that stopped reading froze the game for as long as it took.
- **I23:** the position was the one peer float that never got the finite check the animator floats
  got in the 2026-09-02 review, and it reaches `transform.position` and `Vector3.Distance`, where a
  NaN spreads into the physics state of whatever it touches. Nine cases in `BridgeFuzz.cs`.
- **I24/I25/I26:** the read loop read the `stream` FIELD rather than its own connection's, held no
  bound on a partial line, and decoded UTF-8 per chunk — which silently mutates a non-ASCII
  `anim` or `area_id` split across a TCP read while the line stays valid JSON.
- **I27, I28, I29** and the reject-code change (ADR 0058's adapter half): see phase10.md.

The full session record, including what was NOT done and why, is in
[phase10.md](phase10.md)'s 2026-09-11 entry.
