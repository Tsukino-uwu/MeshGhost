# Phase 6 — Second game (TEVI)

> **A dated record. Package paths here predate the 2026-08-17 module move** — read any
> `internal/X` as `X/`. Why, and what became of `internal/README.md`: [../README.md](../README.md).

**Status: fully done, including 6.6 (two real players) and 6.7 (map markers)**, confirmed
2026-08-13 — with one cosmetic gap still open, charged-attack VFX missing on the ghost (see
Notes at the end of this file, and `status.md`). Started 2026-08-11. Per `agent_docs/README.md`'s convention: a phase earns a file
when it's live, folded back into `agent_docs/plans.md` once done — kept here (rather than folded
back) for the task-by-task record, matching `agent_docs/plans.md`'s own Phase 6 section.

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

## Catch-up record, written 2026-09-01 — the 2026-08-28 session that closed the question above

This file sat unwritten while the work happened; backfilled from the commit log and
`adapters/tevi/VERIFIED.md`, which carries the dated evidence for every item.

- **2026-08-27** — TEVI left its fixed bridge port: the 8-port walk, the send gate, and
  port-walk convergence with the other three adapters (`74609a6`, `5634d10`, `9a34500`).
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

