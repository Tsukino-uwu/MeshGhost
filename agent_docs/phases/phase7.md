# Phase 7 — Third game (Pseudoregalia)

**Status: in progress**, started 2026-08-12. Per `agent_docs/README.md`'s convention: a phase
earns a file when it's live, folded back into `agent_docs/plans.md` once done. Kept here for
the task-by-task record.

## Purpose

Repeat phases 1–4 for Pseudoregalia (UE5, small movement-focused 3D platformer) using the
frozen `adapters/_template/`, and find out whether the contract holds up for a third,
structurally different engine (Blueprint-heavy UE5 vs. TEVI's Mono/Unity and Emerald's raw
GBA memory). Started early relative to Phase 6's own two-player milestone (6.6) — see
`plans.md`'s Phase 6 status note for why that's a deliberate, recorded tradeoff.

## Tasks

- [x] Confirm Pseudoregalia's actual modding tooling before assuming anything — the literal
      first task per `plans.md`/`adapters/pseudoregalia/README.md`, previously unconfirmed
      (`environment.md`'s "UE4SS version for Pseudoregalia: unfilled" line). **Confirmed
      2026-08-12** via direct filesystem inspection of this machine's install
      (`C:\Program Files (x86)\Steam\steamapps\common\Pseudoregalia`): engine is **UE 5.1**
      (`++UE5+Release-5.1-CL-23901901`, read from `pseudoregalia-Win64-Shipping.exe`); UE4SS is
      **v3.0.1 Beta, Git SHA `733e5969`**, installed under the newer `Binaries\Win64\ue4ss\`
      layout. A C++ UE4SS mod (`AP_Randomizer`, the Archipelago integration) is already
      installed and running, and its `dlls/` folder proves a UE4SS C++ mod can hold a real
      TLS/websocket socket in this exact game — the load-bearing fact for the language
      decision below. See `agent_docs/environment.md`'s Unity/TEVI, UE5/Pseudoregalia section
      for the full evidence.
- [x] **Mid-task correction, same day:** the user updated their local UE4SS install from an
      older `v2.5.2 Beta` / SHA `a267c64` (read earlier in the same session) to
      `v3.0.1 Beta` / SHA `733e5969`, following a Mar 2026 update to the
      `pseudoregalia-archipelago` repo's own `RE-UE4SS` submodule pin (its `.gitmodules` pins
      exactly `733e596`, confirmed matching). Re-scanned the install and corrected
      `environment.md`, `licensing.md`, and this file to the new version and folder layout —
      a real example of "verify fresh, don't trust an earlier reading in the same session."
- [x] 7.0 — Licensing gate: added **RE-UE4SS** (MIT, `Copyright (c) 2022 Narknon`, read from
      the local `ue4ss\LICENSE` file) and **pseudoregalia-archipelago** (no LICENSE file, `gh
      api` reports `license: null` → all rights reserved, facts-only per the standing rule) to
      `agent_docs/licensing.md`. Added four new UE5-specific risks to `agent_docs/risks.md`:
      Blueprint-vs-C++ readability, no clip-name animation playback equivalent in UE5, UE4SS
      version drift (observed live this session), and mod-load-order coexistence with
      `AP_Randomizer`.
- [x] **Adapter-language decision (2026-08-12):** Lua for discovery, C++ for the shipping
      adapter. UE4SS's Lua API has **no socket support** — zero `luasocket` references
      anywhere in the RE-UE4SS repo (`gh api search/code`) and no networking/`io`/binary-module
      capability documented at docs.ue4ss.com — but the bridge protocol requires a real TCP
      socket. `AP_Randomizer` proves a UE4SS **C++** mod can hold one in this exact
      game/UE4SS build. So: use a build-free Lua script only for 7.1's discovery probe (fast
      iteration, no CMake loop), then write the real adapter as a UE4SS C++ mod targeting
      **v3.0.1** (not the earlier-read v2.5.2 — see the correction above).
      **Superseded 2026-08-12, same day, once 7.2's C++ path hit the UEPseudo blocker below:**
      the "no socket support" premise only held for a first-party library shipping with
      RE-UE4SS, not for `package.loadlib` itself — see the Stage 2 result under 7.2. With the
      vendored LuaSocket core confirmed loadable, the shipping adapter can plausibly stay
      **Lua**, no CMake/UEPseudo build required at all. Keep this line for the record of what
      was believed and why; treat the Stage 2 finding under 7.2 as the current decision.
      **Confirmed, not just plausible, 2026-08-12**: Stage 3 did a real connect/send/receive
      round trip over the full bridge protocol from inside UE4SS's embedded Lua — see 7.2's
      Stage 3 entry and `agent_docs/verified.md`. **The adapter-language decision for
      Pseudoregalia is now Lua**, for both discovery and the shipping adapter; the C++/UEPseudo
      path is no longer being pursued unless something in 7.3+ forces a return to it.
- [x] 7.1 — Lua probe. Deployed `adapters/pseudoregalia/probe/Scripts/main.lua` as the
      `MeshGhostProbe` UE4SS Lua mod (`ue4ss\Mods\MeshGhostProbe\`, added to `mods.txt`); also
      flipped `UE4SS-settings.ini`'s `[Debug] ConsoleEnabled` `0`→`1` (was off by default,
      same dev-only-toggle shape as TEVI's BepInEx console flag — remember to revert later).
      **Confirmed live** (2026-08-12): the user moved around a real castle area — running,
      crouching, backflipping, ledge-hanging, dying a few times, and transitioning into a
      second area — and `UE4SS.log` shows the pawn (`BP_PlayerGoatMain_C`, a Blueprint class,
      resolved via `UEHelpers.GetPlayerController().Pawn`), position, yaw, and level name all
      tracking correctly, plus the `nil`-equivalent firing exactly at the title screen and
      real level transitions. Closes the Blueprint-readability risk's core uncertainty — the
      pawn and its transform *are* reachable via plain UE4SS Lua reflection, no C++/decompiled
      field name needed for this part. See `agent_docs/verified.md`'s Phase 7.1 entry for full
      detail, including the pitch/roll-always-zero finding relevant to 7.6.
- [ ] 7.2 — C++ hello-world mod (`adapters/pseudoregalia/MeshGhostPseudo/`), built against
      UE4SS v3.0.1, deployed to `ue4ss\Mods\`. Visible outcome: `ue4ss\UE4SS.log` shows the new
      mod starting *and* `AP_Randomizer` still starting and working — the TEVI coexistence
      check, repeated for UE4SS mod load order.
      **Toolchain gap closed 2026-08-12**: user installed CMake 4.4.2 and VS 2022 Build Tools
      (C++ workload) via winget, both confirmed present afterward (`cmake --version`, `vswhere`
      reporting the BuildTools install path). Source/CMake scaffolding was written against
      RE-UE4SS's own official C++ mod guide (`adapters/pseudoregalia/MeshGhostPseudo/`,
      `CppUserModBase`/`Output::send` usage confirmed by reading RE-UE4SS's own headers and two
      of its bundled example mods, `EventViewerMod`/`KismetDebuggerMod` — MIT, see
      `agent_docs/licensing.md`; OUTPUT_NAME forced to `main` per both RE-UE4SS's loader source
      (`CppMod.cpp`: "dlls folder must contain either main.dll or {ModName}.dll") and the
      real, already-installed `AP_Randomizer/dlls/main.dll`).

      **New, harder blocker found next: building UE4SS from source requires a private
      submodule.** `git submodule add`'d RE-UE4SS, pinned to this machine's exact SHA
      (`733e5969`) — succeeded. But `deps/first/Unreal` (its own submodule, `Re-UE4SS/UEPseudo`)
      failed to clone: SSH `Host key verification failed`, and after rewriting to HTTPS
      (editing `RE-UE4SS/.gitmodules` locally, not global git config), `gh api
      repos/Re-UE4SS/UEPseudo` confirmed **404 — private, no access**. Confirmed this is a
      hard dependency, not optional: `UE4SS/CMakeLists.txt` links `Unreal` into the core
      `UE4SS` target directly. Checked for a prebuilt workaround — neither the plain runtime
      zip nor the "zDEV" package (`experimental-latest` release assets) ships an import
      library (`.lib`) anywhere, only `UE4SS.dll` (+ a `.pdb` in zDEV). So there is currently
      **no way to build or link a C++ UE4SS mod on this machine without UEPseudo access** —
      recorded in `agent_docs/risks.md`, not routed around silently.

      **Side effect, found and reverted the same session:** to get an exact-SHA match for
      the zDEV headers (commit `1c1a1497`, 83 commits ahead of the installed `733e5969` —
      no release exists for the exact installed SHA), updated the game's `UE4SS.dll` +
      `dwmapi.dll` to the matching build (after backing up the original `ue4ss\` folder to
      the session scratchpad, since a full-repo build attempt turned out to be moot anyway).
      This **broke `AP_Randomizer`**: `Failed to load dll ... main.dll ... error: 0x7f The
      specified procedure could not be found` — a real ABI break in those 83 commits that a
      commit-message keyword scan (checked for "abi/breaking/cppmod" — found only two benign
      hits) did not catch. **User confirmed on screen** (an in-game "ERROR: Incompatible
      APWorld version" message, actually a downstream symptom of `AP_Randomizer` failing to
      load at all). Rolled `UE4SS.dll` back to the `733e5969` backup immediately; user
      relaunched and confirmed `AP_Randomizer` loads cleanly again (`UE4SS.log`: hooks
      installed, `BPModLoaderMod` loading it normally). `dwmapi.dll` was left at the newer
      build (no backup was taken of the original, an oversight) — empirically fine paired with
      the reverted `UE4SS.dll`, confirmed by the same successful relaunch, but flagged here
      since it wasn't a deliberate, verified-in-advance choice.

      **Reopened question found in the same investigation:** while probing this,
      `adapters/pseudoregalia/probe_socket/Scripts/main.lua` (`MeshGhostSocketProbe`, Stage 1,
      capability-check only, no DLL loaded) confirmed live that UE4SS's embedded Lua 5.4 **does**
      expose `package.loadlib` as a real callable function, and `package.cpath` already
      includes each mod's own `Scripts\` folder — contradicting the earlier "Lua has no
      socket path" conclusion, which was based on the *absence of a first-party socket
      library* (zero `luasocket` references in RE-UE4SS, no networking in the Lua API docs),
      not on `loadlib` actually being disabled. See `agent_docs/verified.md`. **Not yet
      tested:** whether the already-vetted `lua54.dll`/`socket-windows-5-4.dll` pair (copied
      into `adapters/pseudoregalia/probe_socket/Scripts/lib/x64/` for this) can actually be
      loaded and used without crashing — a real risk, since UE4SS's Lua is statically
      embedded in `UE4SS.dll` (not a separate `lua54.dll` the way BizHawk's NLua host is), so
      a mismatched `lua_State` ABI between our vendored binary and UE4SS's own build could
      corrupt memory rather than fail cleanly. A Stage 2 script now exists
      (`adapters/pseudoregalia/probe_socket/Scripts/stage2_loadlib.lua`, written 2026-08-12) —
      preloads the vendored `lua54.dll`, calls `luaopen_socket_core`, then creates and
      immediately closes a `socket.tcp()` object only (no bind/connect/send). It is **not**
      wired in as the mod's entry point (UE4SS Lua mods always load `Scripts/main.lua`);
      running it means deliberately swapping it in over the currently-deployed Stage 1
      `main.lua`, per the deploy note at the top of the file.

      **Run and confirmed 2026-08-12.** Deployed over the Stage 1 `main.lua` (backed up as
      `main.lua.stage1.bak` in the mod's `Scripts\` folder, restored afterward), user launched
      the game and played an extended session — no crashes or instability reported. `UE4SS.log`
      shows every Stage 2 step completing without error: `lua54.dll` preload, `package.loadlib`
      on `socket-windows-5-4.dll`, `luaopen_socket_core()` returning a table with a callable
      `.tcp`, `socket.tcp()` returning a `userdata` object, and a clean close. `AP_Randomizer`
      kept running normally throughout (hooks, overlay, item messages all logged as usual) —
      the coexistence check passes for this path too. This resolves the reopened question: the
      vendored LuaSocket core loads and creates objects cleanly inside UE4SS's statically-embedded
      Lua, despite the two builds being independent binaries. **Not yet tested:** an actual
      `bind`/`connect`/send-receive round trip (this stage deliberately stopped at object
      creation) — that's the next, still-untested step before trusting this for the real bridge
      connection in 7.5.

      **Stage 3 script written 2026-08-12**
      (`adapters/pseudoregalia/probe_socket/Scripts/stage3_roundtrip.lua`): a real
      connect/send/receive round trip against the actual bridge protocol, not a synthetic
      test — sends hardcoded dummy `local_state` frames to a real `meshghost.exe` core
      (`dev-scripts/run-core-pseudoregalia.bat`, new) with `dev-scripts/run-relay-loopback.bat`
      running behind it, and expects to read back the loopback relay's own-state echo as a
      `render_remote` frame.

      **First run found a real core bug, not a socket bug**: `run-core-pseudoregalia.bat`
      passes `-game` explicitly, which connects to the relay via `Core.ConnectRelay`'s direct
      startup path — but that path never recorded which `game_id` it connected as
      (`c.relayGame` stayed `""`). When the probe's own `hello` arrived for `"pseudoregalia"`,
      `ConnectRelayOnAdapterHello` compared it against `""`, treated it as a second conflicting
      game, and closed the bridge connection — `core: already connected to the relay as game
      "", cannot also serve "pseudoregalia"`. This would have hit Emerald and TEVI identically,
      since both send `hello` too (`2f95a83`). **Fixed** in `internal/core/core.go` (set
      `c.relayGame` on the direct path too) with a new regression test,
      `TestAdapterHelloAfterStartupConnectIsNoOp` (`internal/core/core_test.go`), confirmed to
      fail with the exact same log line before the fix and pass after.

      **Second attempt, after the core fix, connected and sent cleanly but received nothing**:
      not a bug either — `onAdapterFrame`/`tickRenders` (`internal/core/core.go`) only pushes
      `render_remote` as a side effect of processing a *new* `local_state` frame from the same
      adapter; the core never pushes proactively. The script's original one-frame-then-wait
      shape could never see anything come back regardless of whether the socket worked.
      Rewrote it to resend a fresh dummy frame before each receive attempt, the way a real
      per-frame adapter naturally does.

      **Run and confirmed 2026-08-12.** User launched the game (booted fine, no lag/freeze/
      weirdness in the menu or in-game, "worked just as usual"). `UE4SS.log` shows a real
      `render_remote` received back on the second attempt:
      `{"type":"render_remote","payload":{"player_id":"p1-ghost","state":{"player_id":"p1-ghost","seq":1,...`
      — the relay's own-state loopback echo, read back successfully inside UE4SS's embedded
      Lua. This is the full bridge protocol working end to end through the vendored LuaSocket
      core, with no C++/UEPseudo build involved at all. **Open, not yet explained**: three
      further receive attempts in the same run returned empty strings instead of `"timeout"` or
      a real line — logged as-is, not investigated; worth understanding before trusting this
      probe's read loop as a model for the real adapter's.
- [x] 7.3 — Decide the real local-state field shapes, adapter-side (never in the core, per
      `contract.md`), from 7.1's confirmed findings. **Decided 2026-08-12** (now a Lua decision,
      not the C++ mod's — see 7.2's language decision above):
      - `position`: raw UE units (cm), `[X, Y, Z]` — matches Emerald/TEVI precedent of sending
        native values as-is; the core never interprets it, and the eventual receiving adapter
        is the same game, so units always match by construction.
      - `orientation`: full `[pitch, yaw, roll]`, not yaw-only. 7.1 found pitch/roll pinned at
        zero for normal ground movement, but Pseudoregalia is a movement-platformer with
        wall-running/backflips/ledge-hangs — locking the schema to yaw-only now is a real risk
        if those states turn out to move pitch/roll, and it's cheap to send all three now
        versus expensive to widen the schema later.
      - `area_id`: the level name string 7.1 already read live
        (`.../ZONE_LowerCastle:PersistentLevel` etc., via `world.PersistentLevel:GetFullName()`)
        — already confirmed working, no further decision needed.
      - "don't send this frame": reuse 7.1's already-confirmed nil-equivalent (no valid
        `PlayerController`) as the gate — fires correctly at the title screen and mid-transition.
      - `anim`: **placeholder only**, not a final vocabulary — a cheap movement-state tag
        (idle/running/falling/etc., inferred from velocity) for 7.4/7.5's wiring. Real animation
        playback is 7.6's problem, flagged in `risks.md` as likely the hardest task in the
        phase (no `Animator.Play(clipName)` equivalent in UE5 the way TEVI had in Unity).
- [x] 7.4 — Placeholder ghost spawned in-engine, fixed offset from the local player, no
      networking yet — proves spawn + per-frame positioning before adding the bridge. TEVI's
      6.3 analogue. **Script written 2026-08-12**
      (`adapters/pseudoregalia/probe_ghost/Scripts/main.lua`, new mod `MeshGhostGhostProbe`):
      spawns a second instance of the player's own pawn class (`pawn:GetClass()`) via
      `world:SpawnActor`, then repositions it every 100ms via `K2_SetActorLocationAndRotation`
      to trail the real player. Every API used is grounded against this install's own bundled
      `RE-UE4SS/docs/lua-api` and bundled example mods (`SplitScreenMod` in particular, for
      `K2_SetActorLocationAndRotation` and the `ExecuteInGameThread` wrapper) — no addresses/
      APIs from memory, per CLAUDE.md. One real gap found: no bundled doc or example anywhere
      constructs or mutates an `FVector`'s fields, so the fixed X offset is attempted
      defensively (`pcall`, read back to confirm it stuck) with a zero-offset fallback if it
      silently doesn't — the script logs which happened rather than assuming. Riskier than the
      socket probes: spawns a real gameplay Blueprint instance, not just a background
      connection — possible physics/collision oddities with two pawns of the same class in the
      world weren't ruled out in advance. Not yet deployed/run — needs its own go-ahead.

      **First live run found a real bug**: the spawn fired on the very first tick the pawn
      became non-nil, before the level-load sequence had actually placed its transform —
      `UE4SS.log` showed `K2_GetActorLocation()` reading back `(0,0,0)`, even though 7.1 already
      confirmed real positions here are in the thousands. The ghost spawned near world origin,
      nowhere near the player, so nothing was visible on screen. A second bug in the same log:
      `ExecuteInGameThread` queues its callback for a later tick, so the next `LoopAsync` tick
      could still see `ghost == nil` and fire a redundant second spawn before the first one's
      callback had run. **Both fixed** the same session: a `MIN_PLAUSIBLE_DISTANCE` guard skips
      spawning until the read position isn't suspiciously close to the origin, and a `spawning`
      flag prevents the double-fire.

      **Second live run, after both fixes, found something more serious.** The spawn itself was
      correct this time (`before=4900.00`, matching the player's real position) and the log
      shows a clean single spawn + "ghost is following" for ~14.5s. But the user reported being
      physically dragged/pulled toward another location at high speed immediately on spawning
      in — not a teleport, a sustained forced movement — until dying, after which respawning
      was normal with no more dragging. **Working theory, not yet confirmed**: the ghost is a
      full, physically-simulated copy of the player's own gameplay Blueprint (collision,
      gravity, movement component) spawned only 150 units away — if it started falling/sliding
      under its own physics, its collision capsule shoving against the real player's every tick
      could produce exactly this. This is the exact risk `7.6`'s design already named
      ("collision/input/gameplay stripped") — it surfaced earlier than planned, as a real
      safety issue (forced movement, death) rather than just a visual one, because 7.4 hadn't
      stripped anything yet. **`MeshGhostGhostProbe` disabled in `mods.txt` (set to `0`)
      pending a redesign** — not safe to re-enable as-is. Next step should follow TEVI's own
      6.3 precedent more closely: a simple, harmless placeholder (TEVI used a translucent
      magenta square, not a full player clone) instead of spawning the real gameplay Blueprint,
      rather than trying to strip collision/physics off a class never designed to have a second
      instance in the world.

      **Attempted mitigation, same session**: rather than switching designs immediately (a full
      `StaticMeshActor` placeholder needs mesh-asset APIs not confirmed anywhere in this
      install's bundled docs), tried the smaller fix first — call
      `SetActorEnableCollision(false)`/`SetActorTickEnabled(false)` on the ghost right after
      spawn. Neither is in the bundled RE-UE4SS docs (confirmed incomplete already), so grounded
      via `gh api search/code` confirming both as real, commonly-used `AActor` functions across
      independent UE-Lua-modding projects (172/138 hits) — names only, no project's source read.
      Explicitly **not a guaranteed fix** — disabling actor tick may not stop a
      CharacterMovementComponent that ticks independently — still needs re-enabling
      `MeshGhostGhostProbe` in `mods.txt` and a live retest to know.

      **Drag bug fully diagnosed and fixed** after two more live runs (full detail in
      `agent_docs/verified.md`, `agent_docs/risks.md`, and this file's own earlier text below
      before this edit — see git history if the fuller blow-by-blow is needed): the real cause
      was `BP_PlayerGoatMain_C` auto-possessing on spawn, confirmed via a read-only
      `diagnose.lua` script that proved `controller.Pawn == ghost: true` with zero repositioning
      code running. Fixed by capturing the original pawn/controller and calling
      `controller:Possess(pawn)` right after spawn — confirmed live, an 82-second clean run with
      no dragging (versus ~13s to death on every dragged run). A `MAX_TICK_DELTA` backstop and a
      main-menu-reentry respawn fix were added along the way.

      **Camera bug: five straight fixes, all failed or made it worse — pivoted the whole design
      instead of a sixth guess.** `Possess()` restores control but not the camera's view target,
      a separate UE concept. In order: (1) `SetViewTargetWithBlend` with 2 args → hard error
      ("UFunction expected 5 parameters"); (2) fixed to all 5 args → succeeded, camera still on
      ghost; (3) called every follow tick instead → succeeded every tick, but visibly broke the
      camera differently (stuck low near the floor, fighting the engine's own camera
      interpolation); (4) bounded to two corrections (immediate + delayed) → both succeeded, but
      the *delayed* one turned out to be actively harmful — its ~1s timing matched exactly when
      the user reported the camera snapping to the floor, so removed; (5) theorized competing
      `CameraComponent` active state (both pawn's and ghost's cameras were simultaneously active
      — confirmed via diagnostic log) and added `ghostCamera:Deactivate()`/
      `pawnCamera:Activate()` → logged the correct resulting state (`pawn=true ghost=false`) yet
      the camera was **still** observed on the ghost. A follow-up diagnostic run that skipped
      applying that fix entirely produced an *identical* result, proving the fix was never the
      actual mechanism. The user separately recalled that the much earlier `diagnose.lua` run
      (no camera/possession calls at all) kept the camera correctly on the player despite the
      same auto-possession swap being real — doesn't fit any theory tried so far, an open
      question never resolved.

      **Seventh live run, new StaticMeshActor design: no dragging, but the user reported seeing
      no cube on screen at all.** The pivoted design (below) had been written but never actually
      copied out to the game's `ue4ss\Mods\` folder — the file deployed for the first live test
      of this design was still the old player-Blueprint-clone `main.lua`, a real deploy-step gap
      caught only by diffing the deployed file against the repo afterward. Deployed the correct
      file and re-ran. `UE4SS.log` showed the API-level path succeeding end to end: `StaticMeshActor
      spawned`, `SetActorEnableCollision(false): ok`, `cube mesh already resident, found via
      StaticFindObject`, `cube mesh assignment attempted` — no errors anywhere, "ghost is
      following" logged once. But the run was short (~9s from spawn to the next `no valid
      PlayerController yet`, i.e. death or menu exit) and nothing in the log actually confirmed
      the mesh assignment *stuck* or that the actor rendered anywhere reachable — `SetStaticMesh`'s
      return value and a position readback were never logged, so "no errors" isn't yet "confirmed
      working," per CLAUDE.md's "ran without errors is not evidence" rule.

      **Added diagnostics, not a guessed redesign, before the next run**: `meshComponent:SetStaticMesh()`'s
      return value and a `GetStaticMesh()` readback are now logged (grounded via `gh api
      search/code`: `SetStaticMesh` 267 hits, `GetStaticMesh()` 24 hits — no bundled docs exist for
      this at all, since the runtime-zip UE4SS install has no `docs/lua-api` folder locally,
      correcting an earlier session's now-stale assumption that it did); `ghost:IsHidden()` is
      logged right after spawn (`SetActorHiddenInGame`/`IsHidden`/`IsVisible` grounded the same
      way: 262/25088/80896 hits); and `followTick` now logs both actors' exact world positions
      plus `IsHidden()` every ~2s (`POSITION_LOG_INTERVAL_TICKS`), not just a one-time "following"
      message — so the next run's log will show directly whether the cube is really sitting 150
      units from the player in open space (a visibility/rendering question) or the mesh
      assignment silently failed to stick (an API question), rather than guessing between the
      two. **Redeployed 2026-08-12, not yet retested live.**

      **Eighth live run: still no cube seen, but the diagnostics found the real cause this
      time.** `UE4SS.log` showed the ghost spawn/mesh path succeed cleanly and the ghost
      following correctly for ~10 seconds. Then a single tick's target jumped 1004 units (real
      player movement, likely a dash/backflip -- not investigated further, not the bug) and
      `MAX_TICK_DELTA`'s backstop correctly refused it. But the refusal **never recovered**:
      `lastGhostTarget` only advances on a successful move, so as the player kept moving normally
      afterward the gap only grew, tick over tick -- the log shows it refusing an ever-increasing
      distance every single tick for the rest of the run (1004 -> 1212 -> 1638 -> 2005 -> ... ->
      11354+ units) with zero recovery. The ghost froze exactly where it was at the moment of the
      first refusal and was never seen again, not because it failed to spawn or render, but
      because it was permanently stranded far from the player. This is a real design flaw in the
      backstop added earlier in this phase, not a guess -- confirmed directly from the log's own
      numbers. Separately, two of the new diagnostics themselves turned out unconfirmed in this
      build: `meshComponent:GetStaticMesh()` and `ghost:IsHidden()` both threw "Tried calling a
      member function but the UObject instance is nullptr" despite both objects being valid
      immediately beforehand -- UE4SS's generic error for a UFunction it can't resolve on that
      class, not real null objects. One of them crashed hard past this script's own `pcall`
      because it ran inside an `ExecuteInGameThread` callback, which isn't covered by the
      caller's `pcall` (documented earlier in this same phase for a different call). **Fixed**:
      removed both unconfirmed calls (kept `SetStaticMesh`'s return value, which is grounded and
      did not error); added `REFUSAL_RESYNC_LIMIT` (5) so five consecutive refused ticks are
      treated as a real displacement (dash, respawn teleport, etc.) rather than a bad single-tick
      read, and the ghost resyncs straight to the target instead of freezing forever. Redeployed
      2026-08-12.

      **Ninth live run: the position/resync fix confirmed working, and the real mesh bug found.**
      `UE4SS.log` showed the offset tracking working correctly and continuously across a full
      level transition -- ghost stayed at pawn.X+150 the entire time, including recovering
      cleanly from a 12,638-unit jump at the transition (refused 4 ticks, then resynced on the
      5th, exactly as designed). But the user reported seeing no cube in either area -- only a
      magenta/checkerboard gate-like shape in area 2 that turned as they turned, which is almost
      certainly the level's own real geometry (a missing-texture gate/fence the character was
      climbing), not the ghost. The log explains why: `SetStaticMesh returned false` --
      the UFunction ran without erroring but never actually assigned the mesh, so the
      `StaticMeshActor` spawned with no mesh at all and rendered invisibly the whole time.
      **Fixed**: switched from the `SetStaticMesh()` UFunction call to direct property assignment
      (`meshComponent.StaticMesh = mesh`) -- the same reflection mechanism already confirmed
      working throughout this file for plain UPROPERTY reads/writes, grounded via `gh api
      search/code` (12 hits for the exact `.StaticMesh = ` assignment pattern in Lua). Also logs
      a readback of the property after assignment. Redeployed 2026-08-12.

      **Tenth live run: position tracking still solid (including a second clean resync through
      another level transition), but still no visible cube anywhere, even standing right at the
      spawn point.** `UE4SS.log` this time showed the direct property assignment succeeding
      *and* reading back correctly: `direct StaticMesh property assignment ok; readback is
      StaticMesh /Engine/BasicShapes/Cube.Cube.` So the component genuinely holds a valid
      reference to the mesh asset, yet nothing rendered. **Working theory, not yet confirmed**: a
      direct UPROPERTY write (unlike the `SetStaticMesh()` UFunction, which failed outright
      moments earlier under this file's own then-current code) may not trigger the engine's usual
      "recreate render state" side effect a real setter call performs internally -- the component
      could be holding a correct reference the renderer was never told about. **Fixed
      (attempted)**: added explicit `meshComponent:SetVisibility(true)` and
      `meshComponent:MarkRenderStateDirty()` calls right after the property assignment, each
      grounded via `gh api search/code` (1600 and 48 hits respectively) and each wrapped/logged
      independently. **Not yet ruled out**: `/Engine/BasicShapes/Cube.Cube` is an editor/dev
      asset that may simply not be cooked into Pseudoregalia's packaged Shipping build at all --
      if so, `StaticFindObject`/property assignment can still succeed on a lightweight UObject
      shell with no real render data, which no visibility/render-state call can fix. If this
      run also shows nothing, the next step is `FindAllOf("StaticMesh")` (grounded,
      `docs/lua-api/global-functions/findallof.md`) to find and reuse a mesh already actively
      rendering in this exact level instead of an engine default shape. Redeployed 2026-08-12.

      **Eleventh live run: `SetVisibility(true)` and `MarkRenderStateDirty()` both FAILED
      outright** (not reflected on this build either -- the same generic UE4SS error class as
      `GetStaticMesh()`/`IsHidden()` earlier), confirming those two additions did nothing;
      still no cube seen, mesh property still read back correctly. Three straight rendering-side
      guesses (`SetStaticMesh()` return value, direct property write, then
      `SetVisibility`/`MarkRenderStateDirty`) have now all failed to produce a visible result
      while the mesh assignment itself keeps succeeding at the reflection layer -- the same
      "API succeeds, symptom unchanged" shape as the earlier camera bug, which is the signal to
      stop patching the assignment mechanism and test the actual "is this asset even cooked"
      theory directly instead. **Implemented the planned fallback**: `tryFindLevelMesh()`, a new
      function using `FindAllOf("StaticMeshActor")` (grounded) to find a real
      `StaticMeshComponent.StaticMesh` from an actor genuinely rendering elsewhere in the current
      level, tried first and preferred over the engine dev cube. If a real level-native mesh
      renders on the ghost, that confirms the spawn/assignment pipeline was fine all along and
      the dev cube specifically wasn't cooked into this build; if it still doesn't render, the
      problem is in actor/component registration, not the asset choice. Redeployed 2026-08-12.

      **Twelfth live run: decisive.** A real level-native mesh
      (`/Game/Meshes/Environment/Props/deadStatue.deadStatue`, confirmed cooked and already
      rendering elsewhere in that exact level) was assigned to the ghost and read back correctly
      -- and still nothing was visible. This rules out the "engine dev cube not cooked" theory
      outright: the asset was never the problem. Four straight mesh/rendering-side attempts
      (`SetStaticMesh()` return value, direct property write, `SetVisibility`/
      `MarkRenderStateDirty`, and now a guaranteed-good asset) have all failed to produce a
      visible result while every individual call kept reporting success -- the same
      "API succeeds, symptom unchanged" shape as the earlier camera bug. Went to plan mode rather
      than trying a sixth guess. Two findings from that planning pass, both evidence-based:

      1. **The position log was self-fulfilling.** `followTick` logged the same `ghostLoc` table
         it had just written into via `offsetGhostToward` -- ten runs of reassuring
         `positions:` lines matching pawn+150 were proof of what the script *wrote*, never proof
         the actor's transform actually changed. **Fixed**: the periodic log now does a genuinely
         separate `ghost:K2_GetActorLocation()` read afterward and logs `intended=` vs.
         `actual=` side by side, so the next run can tell the two apart directly.
      2. **New leading theory**: `AStaticMeshActor`'s root `StaticMeshComponent` defaults to
         **Static** mobility. A Static component isn't meant to move or rebuild its render proxy
         at runtime -- which would explain both `K2_SetActorLocationAndRotation` reporting
         success without the actor ever visibly moving, and no mesh assignment to an
         already-registered Static component ever producing a render proxy, regardless of which
         asset was assigned (matching the dead-statue result exactly). **Fixed (attempted)**:
         `meshComponent.Mobility = 2` (`EComponentMobility::Movable`) set via direct property
         write -- the mechanism that has actually worked throughout this file, since every
         UFunction setter tried so far on this build has failed -- right before mesh assignment,
         with a readback logged. Also checks whether `ghost.RootComponent` is the same object as
         the mesh component (logged, not assumed) and sets its `Mobility` too if it's a different
         object. Grounded via `gh api search/code`: `.Mobility = ` 125 hits, literal
         `Mobility = 2` 587 hits, `RootComponent` 740 hits, all in Lua. Redeployed 2026-08-12
         (deploy confirmed via `diff` against the repo copy, catching the earlier phase's own
         missed-deploy mistake before it could repeat).

      **Thirteenth live run: decisive on movement, still not on visibility.** The honest
      `intended=`/`actual=` log confirmed the Mobility fix worked -- in area 1, `actual` matched
      `intended` on every logged tick, proving the ghost genuinely moved 150 units from the
      player the whole time. The user still saw nothing there. A second, separate bug surfaced
      after the level transition to area 2: `actual` froze at one value
      (`(-4272.74, 4322.12, -200.00)`) and never changed again across five more logged ticks,
      even as `intended` kept updating and the resync path reported success -- position writes
      silently stopped taking effect on the same still-valid ghost object after that specific
      transition (not yet investigated; plausibly level-streaming related). But area 1 alone is
      enough to rule out mobility/movement/asset as the rendering blocker: a real, correctly
      positioned, definitely-moving actor with a real mesh assigned was still invisible.

      **Went to Step 3 of the approved plan**: `DIAGNOSTIC_HIJACK_EXISTING_PROP` (new flag,
      default `true`) -- when set, `trySpawnGhost` does not call `SpawnActor` at all. Instead
      `tryFindMovablePropActor()` (new function, `FindAllOf("StaticMeshActor")`, same grounding
      as `tryFindLevelMesh`) finds a real, already-registered, already-rendering level prop and
      that becomes `ghost` directly -- the existing follow-tick logic then repositions the real
      object instead of a freshly spawned one. If a real prop visibly follows the player, the bug
      is specific to actors spawned at runtime via `SpawnActor`; if even this doesn't visibly
      move, positioning was never the actual blocker and the problem is deeper (render pipeline,
      streaming, or something else not yet identified). Deliberately invasive (displaces a real
      level prop for the run) and one-run-only per the plan; deploy confirmed via `diff` against
      the repo copy.

      **Fourteenth live run: confirmed live on screen, both areas.** User provided screenshots:
      a real statue in area 1 and a real cage in area 2 both visibly followed the player
      correctly at the intended offset, matching the log's `intended=`/`actual=` agreement
      exactly. **This is the phase's first confirmed-visible placeholder.** It also settles the
      investigation decisively: positioning, mobility, and mesh assignment were never the
      problem -- **actors spawned at runtime via UE4SS's `UWorld:SpawnActor` never actually
      render in this game/build**, while actors that already existed in the level before this
      script touched them render and reposition correctly. The RE-UE4SS doc for `SpawnActor`
      states it uses `BeginDeferredActorSpawnFromClass` + `FinishSpawningActor` internally --  a
      real, UE-standard theory (not yet proven) is that this specific game's Shipping build has
      Blueprint-reflection stripped for any UFunction never actually invoked by one of the game's
      own Blueprints (consistent with every other failure this phase: `SetVisibility`,
      `MarkRenderStateDirty`, `GetStaticMesh`, `IsHidden` all failed with the same "instance
      nullptr" error, while `SetStaticMesh`, `K2_GetActorLocation`,
      `K2_SetActorLocationAndRotation`, `GetComponentByClass`, `SetActorEnableCollision` all
      worked -- functions plausibly used by *some* Blueprint already shipped in this game, versus
      ones that likely aren't). If the deferred-spawn finish step (or component registration) is
      similarly never invoked by any of this game's own Blueprints, its reflection could be
      stripped the same way, leaving `SpawnActor`'s actors permanently stuck mid-spawn --
      unregistered, therefore invisible, despite every other property/behavior on them working
      normally through raw reflection.

      **User pointed out a sharper theory, grounded in this phase's own earlier history**: the
      pre-pivot design spawned `BP_PlayerGoatMain_C` -- a Blueprint (`_C`) class -- via this exact
      same `world:SpawnActor(...)` call, and it *was* visible on screen (that's how the drag and
      camera bugs were ever seen at all, across five confirmed live runs). So `SpawnActor` itself
      can render something in this game; the only variable that changed is spawning the raw
      **native** engine class `/Script/Engine.StaticMeshActor` instead of a Blueprint class. Read
      RE-UE4SS's own `LuaUWorld.cpp` source (MIT, already an approved reference for this phase)
      to check the theory against the actual binding rather than guessing further: the Lua
      `SpawnActor` binding calls the raw `UWorld::SpawnActor(class, &location, &rotation)` member
      function directly -- not `BeginDeferredActorSpawnFromClass`/`FinishSpawningActor` as the
      bundled markdown doc claims (the doc appears stale relative to this exact source revision).
      The private `UEPseudo` submodule (already a known, recorded blocker -- see 7.2) means the
      actual `UWorld::SpawnActor` signature/default `FActorSpawnParameters` can't be read from
      source, so the native-vs-Blueprint theory can't be confirmed by reading code alone.

      **New diagnostic, `DIAGNOSTIC_SPAWN_EXISTING_CLASS`** (replaces
      `DIAGNOSTIC_HIJACK_EXISTING_PROP`, now `false` -- that theory is settled): finds a real
      existing level prop the same way as before, reads its actual `UClass` via `:GetClass()`
      (grounded -- this exact call was already used and confirmed live earlier in this same
      file's history, for the pre-pivot design's `pawn:GetClass()`), and calls the same
      `SpawnActor` with THAT class instead of the native `StaticMeshActor` class -- otherwise
      identical spawn path (Mobility fix, collision disable). If the new instance renders,
      native-vs-Blueprint is confirmed as the real variable; if it still doesn't, that's ruled out
      too. Deployed 2026-08-12, deploy confirmed via `diff`.

      **Fifteenth live run: inconclusive, and it surfaced a real oversight.** `UE4SS.log` showed
      the reference prop this run's `tryFindMovablePropActor()` found was itself a plain native
      `/Script/Engine.StaticMeshActor` (`SkeletalMeshActor_1` in area 1, `StaticMeshActor_471` in
      area 2, despite the misleading names) -- this level has no Blueprint prop to copy a class
      from, so the native-vs-Blueprint theory was never actually exercised. Worse: this
      diagnostic branch never assigned a mesh to the freshly spawned instance at all
      (`has a mesh already: false`) -- with zero mesh, invisibility was guaranteed regardless of
      the theory. Run proved nothing either way; `DIAGNOSTIC_SPAWN_EXISTING_CLASS` turned back off.

      What it did surface, combined with everything already confirmed: the object that renders
      when hijacked (native `StaticMeshActor`, already in the level) is the *exact same class* as
      the one that stays invisible when freshly `SpawnActor`'d -- so class type was never the
      variable. The one class in this whole investigation *known* to render when spawned via this
      exact `SpawnActor` call is `BP_PlayerGoatMain_C` (the pre-pivot design -- confirmed across
      five live runs, including a run where a second model was directly seen on screen, per
      `agent_docs/verified.md`'s Phase 7.4 auto-possession entry). User asked directly whether we
      could just spawn it and reposition it, without redoing the old camera/collision work --
      correct: none of that blocks a pure visibility check. **New diagnostic,
      `DIAGNOSTIC_SPAWN_KNOWN_GOOD_PAWN_CLASS`** (replaces the now-off `DIAGNOSTIC_SPAWN_EXISTING_CLASS`):
      spawns a new `BP_PlayerGoatMain_C` instance via `SpawnActor(pawn:GetClass(), loc, rot)`,
      immediately calls `controller:Possess(pawn)` (the already-proven drag fix) to hand control
      straight back, disables its collision, and does nothing else -- no camera calls, no
      follow-mesh work, deliberately narrowed to "does a second body appear at all." If it's
      visible, the real distinguishing variable is Pawn-vs-plain-Actor spawning, not class origin.
      `trySpawnGhost` now also takes `controller` as a parameter (previously only `pawn`) to make
      the re-possess call possible; the follow tick's existing generic positioning logic will
      still move this ghost the same way as any other, once spawned. Deployed 2026-08-12, deploy
      confirmed via `diff`.

      **Sixteenth live run: confirmed live on screen -- a second goat model, visible, following
      correctly.** First actual visibility success for a *spawned* (not hijacked) actor this
      phase. User's screenshot shows both models clearly: the real player (animating normally)
      and the ghost (gliding, no animation -- consistent with a Pawn with no input driving its
      movement component). This closes the "why doesn't SpawnActor render" investigation as
      "spawn a Pawn class, not a plain Actor" -- the engine-level *why* is still unexplained (the
      private `UEPseudo` submodule blocks reading the actual registration source, an existing
      recorded blocker from 7.2), but the practical fact is now directly observed, not theorized.

      This reopens the exact camera-stuck-on-ghost bug this phase pivoted away from earlier, in
      the same session it was previously fixed for the drag: even with `controller:Possess(pawn)`
      called immediately, the camera stayed on the ghost. User asked directly whether fixing the
      camera or fixing non-Pawn rendering is the easier path -- went to plan mode given no
      remaining lead on the non-Pawn side (recorded plan:
      `C:\Users\nyden\.claude\plans\still-nothing-no-greedy-horizon.md`). Chose to keep the
      Pawn-class design (needed for 7.6's real skeletal-mesh ghost anyway) and fix the camera,
      rather than resume chasing StaticMeshActor rendering with no new leads.

      **Camera fix, attempt 6 overall, first with a genuinely new mechanism**: all five earlier
      attempts called UFunctions (`SetViewTargetWithBlend` in three shapes,
      `CameraComponent:Activate()`/`:Deactivate()`) -- every one either errored or "succeeded"
      with zero visible effect. This session's separate StaticMeshActor investigation found a
      consistent pattern across many calls: UFunctions not present in the bundled docs mostly
      fail outright on this build, while direct UPROPERTY writes reliably stick
      (`.StaticMesh =`, `.Mobility =`). Attempt 6 applies that same working mechanism to the
      camera itself: `ghostCamera.bIsActive = false` / `pawnCamera.bIsActive = true`, direct
      property writes instead of `:Deactivate()`/`:Activate()` calls, with a readback logged.
      Grounded via `gh api search/code`: `.bIsActive = ` 149 hits, `bIsActive = false` 124 hits,
      in Lua. Deployed 2026-08-12, deploy confirmed via `diff`.

      **Seventeenth live run: decisive, and it's a sixth straight failure.** `UE4SS.log` proves
      the write stuck -- `camera bIsActive after direct write -- ghost=false pawn=true`, logged
      immediately after the write succeeded -- yet the user reported the camera still centered on
      the ghost. This is stronger evidence than any prior attempt: it's not a call that failed,
      not a call that was too late, not a readback that lied -- the flag is confirmed correctly
      set to exactly what should mean "don't use this camera," and the game still uses it
      anyway. Combined with attempt 5's earlier finding (`CameraComponent:Activate()`/
      `:Deactivate()` also succeeded with zero effect, confirmed via a diagnostic run that showed
      an identical result whether the fix was applied or not) -- across two different mechanisms
      (UFunction call and direct property write) and two different times this phase, the ghost's
      `CameraComponent.bIsActive` state provably does not influence which camera the game
      actually renders through. Skipped attempt 2 (`bAutoActivate`) from the plan -- same flag
      family, and this run already shows a correctly-set active-state flag being ignored, so a
      different default-state flag is unlikely to behave differently.

      **Escalated to attempt 3 immediately**: `ghostCamera:DestroyComponent()`, removing the
      competing component entirely rather than toggling its state -- grounded via `gh api
      search/code` (`DestroyComponent`, 1190 hits, in Lua).

      **User asked a sharp question**: does the log show *why* the ghost has the camera, and what
      would happen with multiple ghosts? Checked `UE4SS.log` around spawn time directly -- no
      engine-level camera/view-target logging exists unless a mod explicitly asks for it, and
      neither of the two prior camera-fix attempts (`SetViewTargetWithBlend`, `bIsActive`) had
      ever actually read back what the engine currently believes the `ViewTarget` is -- both were
      trusted as "succeeded" purely because the call didn't error. Closed that real gap instead of
      testing the multiple-ghosts question (interesting but adds a new confound without new
      leverage): added a read-only diagnostic, `controller.PlayerCameraManager.ViewTarget.Target`,
      a plain property-chain read (no function call, matching the mechanism that's worked
      throughout this session) logged right after the `DestroyComponent` fix. Grounded via `gh api
      search/code`: `PlayerCameraManager` 712 hits, `.ViewTarget.Target` 95 hits, in Lua. This will
      show directly whether the engine still genuinely thinks the ghost is the view target (the
      fixes never really landed) or thinks the player is the target while the screen shows
      otherwise (a different, deeper bug -- e.g. a custom camera system bypassing
      `PlayerCameraManager` entirely). Deployed 2026-08-12, deploy confirmed via `diff`.

      **Eighteenth live run: the most informative one yet, and a real self-caught mistake.**
      `UE4SS.log` showed two things together for the first time: `ghostCamera:DestroyComponent()`
      **FAILED** (the removal never actually ran), and separately,
      `PlayerCameraManager.ViewTarget.Target is ... BP_PlayerGoatMain_C_2147481675 (isGhost=false
      isPawn=true)` -- the engine's own record of the camera target is genuinely, already correct,
      pointing at the real player. Yet the user still saw the camera centered on the ghost. Put
      together, this reframes the whole bug: it was never that our `ViewTarget`/`bIsActive` fixes
      failed to apply -- they apply correctly and the engine agrees -- it's that something renders
      independently of `ViewTarget`, and the prime remaining suspect is the ghost's own
      `CameraComponent`, which is still fully alive because its removal call never executed.

      Caught a real gap in the previous diagnostic before drawing further conclusions: the
      `DestroyComponent()` failure was only logged as a boolean, never with the actual error text
      (`local destroyOk = pcall(...)`, error discarded). **Fixed**: now captures and logs
      `destroyErr`, and retries with an explicit `false` argument
      (`ghostCamera:DestroyComponent(false)`) -- `DestroyComponent`'s real UE signature takes one
      bool parameter (`bPromoteChildren`), and this file has already hit this exact class of bug
      once before (`SetViewTargetWithBlend` silently requiring all 5 args, not 2). No `gh api`
      precedent exists for either exact call shape (0 hits both ways), so this is tried
      defensively with the real failure reason now captured either way. Deployed 2026-08-12,
      deploy confirmed via `diff`.

      **Nineteenth live run: `DestroyComponent(false)` also failed with the same generic
      "instance nullptr" error as `GetStaticMesh()`/`IsHidden()`/`SetVisibility()`/
      `MarkRenderStateDirty()`** -- ruling out the arg-count theory; this function simply isn't
      reflected at all on this build, same as that whole family. Combined with the already-
      confirmed-correct `ViewTarget.Target`, every reflection-level lever available has now been
      exhausted: three `ViewTarget` approaches, two `CameraComponent` active-state approaches
      (function call and property write), and a removal attempt that can't execute -- all either
      fail outright or apply correctly with zero visual effect. Whatever actually selects the
      rendered camera in this game does not go through the standard `PlayerCameraManager`/
      `ViewTarget` path reachable via reflection, most plausibly a custom camera system
      implemented in this game's own Blueprint graphs (unreadable -- no decompile license) or
      requiring the still-blocked C++/`UEPseudo` path from Phase 7.2. Presented this to the user
      as a genuine wall, with options (fall back to the proven-working hijack design / keep
      digging / stop for the session).

      **User's chosen next step, before deciding**: spawn a *second* ghost on the opposite side,
      to settle by direct observation whether the camera really is on a ghost, or whether two
      similar-looking models standing close together made a player-centered camera hard to read
      correctly. `offsetGhostToward` generalized to take an explicit offset parameter; a second
      `ghost2`/`OFFSET_X_2` (-150, mirroring the existing +150) added as a diagnostic-only
      companion -- spawned alongside the first (same class, same camera `bIsActive` fix, same
      collision disable), repositioned in lockstep each tick, no independent respawn-on-invalid
      state machine (one-run diagnostic, not a permanent second ghost). With three bodies on
      screen (ghost / player / ghost), whichever one the camera actually follows will be
      unambiguous regardless of how similar the models look. Deployed 2026-08-12, deploy
      confirmed via `diff`.

      **Twentieth live run: a real, serious drag incident -- user was pulled left continuously
      for over 30 seconds until closing the game.** `UE4SS.log` shows exactly why: the periodic
      position log's own `pawn=` value (not the ghost's) dropped by a constant ~150 units every
      single 100ms tick (`2050 -> -950 -> -3950 -> ... -> -42950`), an exact match for "the
      followed-`pawn` reference IS a ghost, being told to move to its own current position minus
      the offset, every tick, forever." Root cause: `ghost2` is the same auto-possessing
      `BP_PlayerGoatMain_C` class as `ghost`, and `controller:Possess(pawn)` was only called once,
      right after spawning `ghost` -- never after `ghost2`. `ghost2` silently auto-possessed
      itself on spawn; because `followTick` re-fetches `controller.Pawn` fresh every tick (by
      design, so it always tracks whoever's really possessed), every tick thereafter its own
      `pawn` variable literally *was* `ghost2`. Same bug class as the original Phase 7.4 drag
      incident, re-triggered by the second ghost this diagnostic added. User was safe (closed the
      game) before this was found. **Fixed**: `controller:Possess(pawn)` called again right after
      `ghost2` spawns, using the originally-captured `pawn` reference. **New safety backstop
      added, not present before**: `followTick` now checks whether `pawn`'s address matches
      either `ghost`'s or `ghost2`'s at the top of every tick, before any positioning logic runs
      -- if so, refuses to move anything and logs loudly instead of repeating this exact incident
      silently, e.g. if a future respawn/possession event does the same thing again. Deployed
      2026-08-12, deploy confirmed via `diff`.

      **User's next planned test, once confirmed safe**: deliberately die in-game and observe
      where the camera goes on respawn -- the game's own real respawn/re-possession logic is a
      different code path than this script's `Possess()` call, so it's new evidence regardless of
      outcome.

      **Twenty-first live run: three bodies confirmed on screen (ghost / player / ghost), camera
      confirmed still locked to one specific ghost -- and the death/respawn test ran too.**
      User's screenshot shows the layout unambiguously: middle = the real player, one ghost each
      side, camera locked on the same one that had it before. `UE4SS.log` confirms the drag-bug
      fix held through a level transition this run (both ghosts respawned cleanly, `Possess()`
      logged `ok` twice, no drag recurred). Death/respawn (via a level transition the script
      detected as `ghost became invalid`) also completed cleanly -- both ghosts respawned, and the
      camera was still on a ghost afterward, per the user's report.

      **User's own observation, worth recording verbatim as a real finding**: the *second* ghost
      (spawned after, on the opposite side) never took the camera at any point -- the same one
      ghost keeps it regardless of spawn order, activation, or a full respawn cycle. This argues
      against "most-recently-activated camera wins" and toward "the game latches onto a camera
      once, early, and never re-evaluates" -- useful information for what kind of event to look
      for next, rather than which fix to try next.

      **User also asked whether delaying the ghost spawn (giving the real player's camera time to
      "win" first) might help.** Reasoned through it rather than testing blind: the death/respawn
      result already argues against this -- respawning re-runs the game's own native possession
      logic completely fresh, a real "clean slate" moment, and the camera was still wrong
      immediately after. If pure first-claim timing were the mechanism, respawn should have fixed
      it. Not ruled out entirely, but deprioritized in favor of a more direct approach.

      **New investigative approach, not a seventh property/function guess**: `RegisterHook`
      (grounded, `docs/lua-api/global-functions/registerhook.md`; this install's own log already
      shows native hooks in normal use for `PlayerController:ClientRestart`) registered on two
      real native UFunctions already confirmed callable on this build --
      `PlayerController:SetViewTargetWithBlend` and `CameraComponent:Activate` -- logging every
      call, by anyone (us or the game itself), with the calling object's identity. Both hooks are
      read-only (return `nil`, never override behavior), registered once at mod load via a new
      `tryHookCameraCalls()`, independent of any per-ghost diagnostic branch. This should show
      directly whether/when the game's own code calls either function, rather than continuing to
      guess at fixes. Deployed 2026-08-12, deploy confirmed via `diff`.

      **Twenty-second live run: the pivotal finding of the whole investigation.**
      `CameraComponent:Activate` failed to register as a hook at all ("no UFunction with the
      specified name was found" -- not reflected on this build, consistent with the broader
      pattern seen all session). But `SetViewTargetWithBlend` registered and fired three times,
      all within ~60ms of each other right at level entry, and none of them targeted the pawn or
      any `CameraComponent`:

      ```
      SetViewTargetWithBlend called on MainPlayerController_C -> NewViewTarget=BP_PlayerCam_C_2147481622
      SetViewTargetWithBlend called on MainPlayerController_C -> NewViewTarget=BP_PlayerCam_C_2147481446
      SetViewTargetWithBlend called on MainPlayerController_C -> NewViewTarget=BP_PlayerCam_C_2147481466
      ```

      **Pseudoregalia does not use a simple pawn-owns-its-camera system.** The actual
      `PlayerController` class is `MainPlayerController_C`, a custom Blueprint subclass (not the
      plain engine `PlayerController`), and it targets dedicated, pre-placed `BP_PlayerCam_C`
      camera-rig actors -- three different ones switched between within milliseconds of entering
      the area -- rather than the pawn itself. This is a fixed/curated per-area camera system, not
      a per-pawn one. It reframes every camera fix attempted this phase (`bIsActive`,
      `DestroyComponent`, even the original `SetViewTargetWithBlend(pawn, ...)` calls earlier in
      Phase 7.4): all of them targeted the pawn's own `CameraComponent`, which was never the
      mechanism actually driving what's on screen. No further `SetViewTargetWithBlend` calls
      fired later in the session, including during the user's death/respawn test -- whatever these
      `BP_PlayerCam_C` rigs do to decide their framing target, it isn't through this function
      being called again afterward.

      This is a genuine reframing, not just another failed attempt -- the real lever, if one
      exists through reflection, would involve these `BP_PlayerCam_C` actors directly (e.g. what
      they track, whether their own Tick logic reads something cacheable/overridable), a
      completely unexplored avenue.

      **User provided a fresh download of RE-UE4SS at the exact installed SHA
      (`733e59695ec01e8ae74590e33345a5e8f4e12808`, `C:\dev\RE-UE4SS`), hoping it might unblock
      the private submodule.** It didn't -- `deps/first/Unreal` is present but empty (0 files),
      confirming the Phase 7.2 blocker still stands even at this exact commit. It was still
      useful for a different reason: cross-referencing the real source at this precise version
      (rather than the bundled docs, which may be from a later commit) showed `ForEachProperty`
      genuinely IS implemented (`UE4SS/src/LuaType/LuaUStruct.cpp`) and that `UClass` (what
      `GetClass()` returns) properly inherits it via `UStruct::construct`. So the runtime failure
      isn't "never implemented" -- something about how the actually-running `UE4SS.dll` differs
      from this source is unexplained, and not resolvable without building UE4SS ourselves
      (still blocked). Separately, `CameraComponent:Activate`'s hook-registration failure
      ("no UFunction with the specified name was found") is a different kind of gap -- the
      game's own reflection data, not a UE4SS binding question -- consistent with the
      Shipping-build reflection-stripping theory from earlier in this phase.

      **User agreed to pivot to the hijack design**, with a goal beyond the plain placeholder:
      reskin the hijacked object to look like the player and eventually animate it. Before
      committing to the rewrite, two more quick questions came up, both real gaps in the
      investigation so far:
      1. Every prior test spawned a ghost within a couple seconds of the pawn becoming valid --
         never tested whether a longer delay (letting the player's own camera "settle" first)
         changes anything, even though the hook evidence suggests the game's own camera-rig
         switching already completes within ~60ms of level entry, before any ghost could exist.
      2. Every single-ghost test used the same `+150` offset slot (`ghost`) -- never tested the
         `-150` slot (`ghost2`) alone, to see whether it's specifically that slot/order that grabs
         the camera or whether any solo ghost does.

      **One more live test queued, combining both**: `SPAWN_DELAY_TICKS` (50, ~5s) added --
      `followTick` now counts ticks since the pawn first becomes valid and holds off calling
      `trySpawnGhost` until the delay elapses, logging the countdown. `OFFSET_X` flipped to
      `-150` and the second-ghost spawn block removed entirely from
      `DIAGNOSTIC_SPAWN_KNOWN_GOOD_PAWN_CLASS` -- this run spawns only one ghost, in the
      previously-untested slot, after a real delay. The settled-dead-end `DestroyComponent` call
      was also dropped (confirmed unreflected twice already, no point retrying). Deployed
      2026-08-12, deploy confirmed via `diff`.

      **Twenty-fourth live run: the real trigger caught on camera, and it's a live reaction, not
      a stale cache.** User reported the camera correctly started on the player during the delay
      window and only swapped the instant the ghost spawned in -- ruling out the "camera latches
      once at level load" theory. `UE4SS.log` confirms exactly why: 2.6ms after
      `DIAGNOSTIC: new BP_PlayerGoatMain_C instance spawned`, the hook caught
      `MainPlayerController_C` calling `SetViewTargetWithBlend` **again**, switching from rig
      `BP_PlayerCam_C_2147481622` to a *different* rig `BP_PlayerCam_C_2147481303` -- the game's
      own code, not our script, not a stale reference. Almost certainly an overlap/proximity
      trigger: the ghost spawns exactly at the player's location, briefly sharing collision
      before `SetActorEnableCollision(false)` runs a few lines later (already too late -- the
      spawn itself is synchronous per the `LuaUWorld.cpp` reading from Phase 7.2/7.4), and
      something reads "a player-class pawn entered this camera zone" and re-picks a rig.

      **This is a real, hookable, fightable mechanism** -- unlike every prior fix target
      (`ViewTarget` property, `CameraComponent.bIsActive`), this one is a live function call we
      can react to. Extended `tryHookCameraCalls()`'s existing `SetViewTargetWithBlend` hook with
      a **post-hook**: captures `lastKnownGoodViewTarget` the first time the hook fires while no
      ghost exists (the game's own natural, uninterfered-with choice), then on any later call
      where a ghost exists and the target changed away from that captured value, immediately
      calls `SetViewTargetWithBlend` again (same 5-arg shape already confirmed callable earlier
      in this phase) to force it back -- deferred via `ExecuteInGameThread` rather than called
      re-entrantly from inside the hook's own call stack, no grounding either way for whether
      that's safe on this build. The corrective call re-triggers the same hook, but since it
      restores the exact captured target, the `sameTarget` check short-circuits it without
      recursing further. Deployed 2026-08-12, deploy confirmed via `diff`.

      **Twenty-fifth live run: CONFIRMED WORKING, on screen, twice.** User: "it work!, the camera
      is focused on the player even after the ghost spawned in." `UE4SS.log` shows the fight-back
      firing cleanly in two different areas across a level transition:

      ```
      ZONE_LowerCastle: target changed to BP_PlayerCam_C_2147481320, forced back to
      BP_PlayerCam_C_2147481622 -- override: ok
      ZONE_Dungeon (after transition): target changed to BP_PlayerCam_C_2147479023, forced back
      to BP_PlayerCam_C_2147479089 -- override: ok
      ```

      Both times the corrective call itself re-triggered the hook exactly once (as expected) and
      the `sameTarget` check stopped it there -- no runaway loop, no repeated fighting. **This is
      the first confirmed-working camera fix in the entire investigation**, after five failed
      pre-pivot attempts and eight more failed/blocked attempts this session (three `ViewTarget`
      shapes, `bIsActive` via function and property write, a `DestroyComponent` that never ran,
      hook registration on an unreflected function, a property-enumeration approach that also
      wasn't reflected) -- solved not by patching the pawn's own camera state but by catching and
      overriding the game's own re-targeting call in real time.

      **Phase 7.4's actual goal -- a visible placeholder ghost, following the player, with the
      camera correctly staying on the real player -- is now achieved**, using the
      `DIAGNOSTIC_SPAWN_KNOWN_GOOD_PAWN_CLASS` design (spawn a second `BP_PlayerGoatMain_C`,
      re-possess immediately, camera-hook fight-back) plus `SPAWN_DELAY_TICKS` and the single
      `-150` ghost.

      **Cleanup done, 2026-08-12**: `main.lua` rewritten to drop the now-dead code paths
      (`DIAGNOSTIC_HIJACK_EXISTING_PROP`, `DIAGNOSTIC_SPAWN_EXISTING_CLASS`, the original
      StaticMeshActor spawn/mesh-assignment branch, `tryFindLevelMesh`/`tryFindMovablePropActor`/
      `tryLoadCubeMesh`, the two-ghost `ghost2`/`OFFSET_X_2` machinery, the unreflected
      `CameraComponent:Activate` hook, and the unreflected `ForEachProperty`-based rig dump) --
      all confirmed dead ends or superseded, kept only in git history and this file's record. The
      surviving design: spawn `pawn:GetClass()` after `SPAWN_DELAY_TICKS`, re-possess, disable
      the ghost's own camera/collision (harmless extras, not the real fix), and the
      `SetViewTargetWithBlend` hook's fight-back post-callback (the actual fix). A condensed
      design-history comment block replaces the old header. Deployed 2026-08-12, deploy confirmed
      via `diff`. Not yet retested live in this cleaned-up form -- next live run should confirm
      the full follow loop (offset-following over time, ideally through another level transition)
      still works identically to the pre-cleanup version before writing to `agent_docs/verified.md`.

      **Twenty-sixth live run: CONFIRMED, cleaned-up version, extended play.** User: "yee it
      still works." `UE4SS.log` shows the fight-back firing and succeeding three separate times
      across two level transitions (`ZONE_LowerCastle` -> `ZONE_Dungeon` -> `ZONE_LowerCastle`
      again), each time forcing the camera back to the correct rig. **One small, accepted visual
      side effect**: the user reports a brief black flash each time the camera gets forced back
      -- almost certainly the `SetViewTargetWithBlend` cut/blend transition itself being visible
      for a frame. Not investigated further; a fine tradeoff for a camera that stays correctly on
      the real player. **Phase 7.4 is now genuinely done**: a placeholder ghost spawns, follows
      the player at a fixed offset, survives level transitions, and the camera correctly stays on
      the real player throughout -- confirmed live, repeatedly, by the user watching it happen.

      **User chose to investigate the camera rigs directly.** Added `tryDumpCameraRigTargets()`:
      finds all live `BP_PlayerCam_C` instances via `FindAllOf` (grounded, already used
      elsewhere this phase), then uses `UStruct:ForEachProperty` (grounded,
      `docs/lua-api/classes/ustruct.md`) to enumerate every `ObjectProperty`/`WeakObjectProperty`
      on the class dynamically -- every field that could hold a reference to another actor --
      without needing to guess the Blueprint's internal variable names (unknowable without
      decompiling, not licensed). Each match's current value is read via `GetPropertyValue`
      (grounded, `docs/lua-api/classes/uobject.md`) and logged by full name. Runs once at level
      entry (retried every second via a small `LoopAsync` until rigs exist, since they only exist
      once a real level is loaded) and then again on the same ~2s cadence as the existing
      position log, so the log becomes a time series -- what each rig points to before the ghosts
      exist, right after they spawn, and afterward -- rather than one snapshot. Required a small
      structural change: `tryDumpCameraRigTargets` forward-declared near the top of the file
      (with `ghost2`) since `followTick`, defined earlier in the file, now calls it periodically,
      while its actual definition stays with the rest of the camera-rig investigation near the
      bottom. Deployed 2026-08-12, deploy confirmed via `diff`.

      **Twenty-third live run: `ForEachProperty` is not present on this build either.** All three
      `BP_PlayerCam_C` rigs were found correctly (`found 3 BP_PlayerCam_C instance(s)`, repeated
      every ~2s as designed), but every single call to `rig:GetClass():ForEachProperty(...)`
      failed identically: `attempt to call a nil value`. Same root cause already established for
      `GetStaticMesh`/`IsHidden`/`SetVisibility`/`MarkRenderStateDirty`/`CameraComponent:Activate`/
      `DestroyComponent` -- this exact installed build (v3.0.1 Beta, SHA `733e5969`) has a
      meaningfully smaller reflection surface than the bundled docs describe (sourced from a later
      commit -- `environment.md`'s already-recorded version-drift risk). This closes the
      introspection avenue, not just another fix attempt: it's not that we don't know the right
      property to poke, it's that the *method for finding out* isn't available on this build
      either. Camera remained on the same ghost, unaffected (this run was purely observational,
      no fix applied).

      **Status: a genuine, thorough wall.** Eight distinct attempts across two structurally
      different mechanisms have now failed: three `ViewTarget` approaches, `CameraComponent`
      active-state via both function call and property write, a component-removal attempt that
      can't execute, a hook-based observation of camera activation that can't register, and a
      property-enumeration approach that can't run either. The one thing that *did* work --
      hooking `SetViewTargetWithBlend` -- revealed the real mechanism (dedicated `BP_PlayerCam_C`
      rig actors, not the pawn) but every subsequent way of interacting with or inspecting those
      rigs has been blocked by this build's reflection gaps. Recommending the hijack design as the
      practical path forward for the rest of the phase, with this investigation kept as a detailed
      record for later (e.g. if a UE4SS version matching the bundled docs is ever installed --
      itself a real risk, already recorded, since the one attempt at updating `UE4SS.dll` this
      phase broke `AP_Randomizer`).

      **Pivoted the design entirely rather than a sixth guess** (commit `9c186f9`): `main.lua`
      now spawns a plain, non-Pawn `StaticMeshActor` (a basic cube) instead of a second instance
      of `BP_PlayerGoatMain_C`. This sidesteps the whole bug class structurally — a
      `StaticMeshActor` can never be auto-possessed and never has a `CameraComponent`, so there
      is nothing left for a camera or possession bug to attach to. Matches `risks.md`'s own
      recorded mitigation and TEVI's 6.3 precedent. Carries over every proven-safe piece from the
      old design (`MIN_PLAUSIBLE_DISTANCE`, the spawning-race guard, `MAX_TICK_DELTA`, the
      never-mutate-the-pawn's-vector rule, the menu-reentry respawn fix). New ungrounded piece:
      `StaticLoadObject` to force-load the engine's default cube mesh if not already resident —
      no confident `gh api` hit count for this exact call shape, tried defensively with a
      fallback to an unmeshed actor, logged either way. **Not yet deployed/tested live.**

      **Third live run, with the collision/tick mitigation in place: still dragged, ruling that
      theory out.** Same symptom, this time described more precisely — a smooth, straight-line
      drift to the side into the void, not a sudden pull. Disabled the mod again immediately.
      Re-reading the code (not guessing again) found the actual cause: the follow loop read
      `pawn:K2_GetActorLocation()` fresh every tick and mutated its `X` field in place before
      handing that same object to the ghost's position setter.
      `K2_GetActorLocation()` appears to return a **live reference** into the actor's own
      transform, not a detached copy — so every tick's "offset" was actually writing +150
      units directly into the **real player's** position, roughly 10 times a second,
      compounding forever. That's exactly a smooth, never-ending straight-line drift — not
      physics, not collision, just the script silently overwriting the player's real position
      every tick. This also explains why no separate ghost was ever visible in either drag
      incident: it was likely always co-located with wherever the corrupted player position
      ended up. **Fixed**: `offsetGhostToward` now only ever mutates a vector owned by the
      ghost itself (`ghost:K2_GetActorLocation()`, fetched fresh each tick), never anything
      read from the pawn; the initial spawn happens at the player's exact, unmodified position
      (no mutation at that point at all). Collision/tick disable calls left in place as a
      reasonable safety measure even though they turned out not to be the actual fix.

      **Fourth live run, with the live-reference fix in place: still dragged, identically.**
      Same ~13s-to-death symptom, still no separate ghost ever seen, despite this run's fix
      addressing a mechanism (mutating the pawn's live vector) that no longer existed in the
      code at all. Two guess-based fixes in a row failing identically is a signal the guesses
      were both wrong in the same way — assuming the *positioning math* was the problem. Went
      to plan mode rather than trying a fifth guess; new leading theory recorded in
      `C:\Users\nyden\.claude\plans\nope-i-was-still-cryptic-horizon.md`: `BP_PlayerGoatMain_C`
      may have "Auto Possess Player" set to Player 0 (a common pawn-Blueprint default), meaning
      `SpawnActor` may silently swap `PlayerController.Pawn` to the new ghost — which would
      explain both the identical-looking drag regardless of which mutation-target fix was
      applied (if `pawn` and `ghost` became the same object, the distinction was meaningless)
      and why no second model was ever visible (only ever one body in the world). Wrote
      `adapters/pseudoregalia/probe_ghost/Scripts/diagnose.lua` — spawns the ghost with the
      same guards but performs zero repositioning, only logs `UObject:GetAddress()` for the
      original pawn / ghost / controller's current Pawn (re-fetched fresh every tick) to
      directly test whether they converge, plus a one-time read of `ghost.AutoPossessPlayer`
      (grounded via `gh api search/code`, 10 hits).

      **Confirmed live, fifth run (diagnostic-only, zero repositioning code).** `UE4SS.log`
      showed `controller.Pawn == ghost: true` on every single tick immediately after spawning,
      and the logged position never changed across the whole run (`(4469.77, 8279.23,
      -732.85)`, unchanged) — direct proof both that the auto-possession swap is real and that
      the diagnostic itself, with no position-setting call anywhere in it, caused zero drag on
      its own. `BP_PlayerGoatMain_C` does auto-possess on spawn. User also reported seeing a
      second model on screen this run — almost certainly an orphaned ghost left over from an
      earlier spawn attempt earlier in the same session (no despawn/cleanup logic exists yet,
      a known limitation), not evidence against the theory.

      **Fixed** in `main.lua` (bug 5 of 5): captures the original pawn and controller before
      spawning, then calls `controller:Possess(pawn)` immediately after spawn to hand control
      back — leaving the ghost genuinely uncontrolled. `Possess` grounded via `gh api
      search/code` (470 hits). Also added a `MAX_TICK_DELTA` defensive backstop: refuses and
      logs any single-tick ghost move larger than 500 units rather than applying it, so a
      future bug of this shape freezes the ghost instead of dragging the player again.

      **Confirmed live, sixth run: the drag is genuinely fixed.** `re-possess original pawn
      after spawn: ok`, `ghost is following`, and the run lasted **82 seconds** with no
      dragging and no forced death — versus ~13s to death on every one of the prior three
      dragged runs. The ghost visibly moved around following the player. One smaller, separate
      issue found the same run: the camera stayed pointed at the ghost even though input
      control had correctly returned to the real pawn — `Possess()` reassigns control but not
      necessarily the active camera view target, a distinct concept in UE. **Fixed**: added
      `controller:SetViewTargetWithBlend(pawn, 0)` right after `Possess()`, grounded via `gh
      api search/code` (218 hits). Not yet retested live.
- [ ] 7.5 — Port 7.1's real local-state read (not just Stage 3's hardcoded dummy frame) and
      7.3's field decisions into a persistent, per-frame Lua bridge client — a `RegisterHook`-
      or engine-tick-driven loop, not a one-shot script like Stages 1-3, non-blocking connect
      with retry (Stage 3 used a blocking connect+timeout, fine for a one-shot probe, not for
      a real per-frame adapter), envelope shapes exactly per `adapters/_template/PROTOCOL.md`,
      send `local_state` every frame including `null`. `dev-scripts/run-core-pseudoregalia.bat`
      and reused `run-relay-loopback.bat` already exist (written for Stage 3). Visible outcome:
      a ghost trailing the local player over a real relay/core/bridge loopback round trip.
- [ ] 7.6 — Real character-visual ghost: duplicate the player's skeletal mesh actor with
      collision/input/gameplay stripped, driven by the wire `anim` tag. Flagged in `risks.md`
      as likely the hardest task in the phase — UE5 has no direct equivalent of Unity's
      `Animator.Play(clipName)` on a cloned actor.
- [ ] 7.7 — Two real players. Test explicitly and early rather than assuming Pseudoregalia
      behaves like TEVI's Steam single-instance restriction (or doesn't) — record the result
      either way, blocked or not.

## Notes

- `adapters/pseudoregalia/README.md` updated 2026-08-12 with the confirmed tooling facts and
  the Lua-probe/C++-adapter decision.
- Inherited, not fixed in this phase: cross-area filtering is genuinely unbuilt in
  `internal/core` (sends every known remote regardless of `area_id`), and there's no
  peer game-version check in `hello` — both apply to Pseudoregalia the same way they already
  apply to TEVI (`agent_docs/risks.md`).
- Environment drift is now a live, observed risk for this phase specifically (see the
  mid-task UE4SS version correction above) — re-check `environment.md`'s UE4SS version at the
  start of any future session before resuming, rather than trusting the last recorded value.
