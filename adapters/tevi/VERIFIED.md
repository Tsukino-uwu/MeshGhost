# Verified facts — TEVI

Facts about this adapter and this game, **confirmed by watching a running game**. Split out of
`agent_docs/verified.md` on 2026-08-25, verbatim and in their original order; that file had
reached 10,174 lines with four games and the Go side interleaved chronologically, and was the most
frequently touched file in the repo.

**The gate is unchanged, and it is the strict one.** Nothing adapter- or game-side on the
BASE/VANILLA game goes in here until **the user has confirmed it on screen** — no probe log,
console read or screenshot substitutes. Measurements that are not yet confirmed live in
[`../../agent_docs/unverified.md`](../../agent_docs/unverified.md) (this adapter has no queue file yet). A patched ROM (Archipelago and similar) is the agent's to confirm
visually; say so in the entry. The full rule is in [../../agent_docs/../CLAUDE.md](../../agent_docs/../CLAUDE.md).

**Append-only.** Do not rewrite or delete an entry's original observation. Adding later
live-confirmed detail to an existing entry is fine; superseding one is a NEW entry plus an
annotation, never an edit to the old.

**A fact confirmed against one build/ROM/version is not automatically true of another.** State the
scope in `Notes` whenever it plausibly matters.

**The entry format, and the two evidence tracks**, are in
[../../agent_docs/verified.md](../../agent_docs/verified.md), which remains the home for Go-side and cross-game
entries and carries the index to these files.

> **NOTE: `internal/X` package paths throughout this file predate the 2026-08-17 move.** The six
> library packages (`protocol`, `relay`, `core`, `transport`, `bridge`, `netx`) left
> `internal/` for the repo root that day — read any `internal/X` as `X/`. Left as written,
> because a dated record records what was true when it was written.

Sibling registers: `../pseudoregalia/VERIFIED.md`, `../bizhawk/pokemon/crystal/VERIFIED.md`, `../bizhawk/pokemon/emerald/VERIFIED.md`.

## Confirmed facts

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

