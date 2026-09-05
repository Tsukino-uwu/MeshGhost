# Phase 7 — Third game (Pseudoregalia)

> **A dated record. Package paths here predate the 2026-08-17 module move** — read any
> `internal/X` as `X/`. Why, and what became of `internal/README.md`: [../README.md](../README.md).
> **Adapter paths predate the 2026-08-25 folder rename** — read any `adapters/bizhawk/` as
> `adapters/emulator/`. Left as written for the same reason: a phase file records what was true
> while the phase ran.

**Status: 7.0-7.8 done, and the adapter was declared FEATURE COMPLETE by the user on 2026-08-27**
(scope written down in `adapters/pseudoregalia/VERIFIED.md`). 7.7 (real two-player test) confirmed
2026-08-16 — two real players on two machines, with the Linux tester. Started 2026-08-12. **This
file's task list ends at 7.8; work after 2026-08-17 has no phase number** — see the pointer at the
bottom for where it lives. Per
`agent_docs/README.md`'s convention: a phase
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
      **Superseded at 7.5 — the escape clause fired.** The shipping adapter is C++: Lua sockets
      worked under light testing but corrupted memory under sustained real traffic. See 7.5.
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
- [x] 7.2 — C++ hello-world mod (`adapters/pseudoregalia/MeshGhostPseudo/`), built against
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
      `still-nothing-no-greedy-horizon.md`, outside this repo). Chose to keep the
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
      `nope-i-was-still-cryptic-horizon.md` (outside this repo): `BP_PlayerGoatMain_C`
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

      **C++/UEPseudo path reopened and unblocked, 2026-08-12 (later session)**: the private
      `deps/first/Unreal` (UEPseudo) submodule that blocked the C++ mod build in the earlier 7.2
      entry above is now accessible — the user linked their GitHub account to their Epic Games
      account (Connections → Accounts → GitHub, OAuth authorize) and accepted the resulting
      `EpicGames` GitHub org invite, confirmed via `UE4SS-RE/RE-UE4SS` issue #577's own
      maintainer/reporter thread (`gh issue view 577 --repo UE4SS-RE/RE-UE4SS --comments`), not
      guessed. `git submodule update --init deps/first/Unreal` then succeeded (2498 real files).
      A second, previously-unhit toolchain gap surfaced immediately after: `patternsleuth` (a
      RE-UE4SS first-party dep) is written in Rust, and this machine had no `rustc`/`cargo` —
      installed via `winget install Rustlang.Rustup` (confirmed: `rustc 1.97.1`). CMake configure
      then succeeded end to end and printed `UE4SS Version: 3.0.1.0.0 (733e5969)` — an exact
      match to this machine's installed build, not just "close enough." One non-obvious build
      detail: the CMake project defines configs as `<TargetType>__<Configuration>__<Platform>`
      triplets (e.g. `Game__Shipping__Win64`), not plain `Debug`/`Release` — `cmake --build
      . --config Release` fails with `MSB8013` since that combination doesn't exist; the correct
      config for a Shipping-build game is `Game__Shipping__Win64`. The full build (`cmake --build
      . --config Game__Shipping__Win64`) then completed with exit code 0 — warnings only (mostly
      pre-existing deprecation warnings in RE-UE4SS's own upstream code, not ours), no errors —
      and produced `MeshGhostPseudo.vcxproj -> .../Mod/Game__Shipping__Win64/main.dll` (16.9KB),
      linked against the real, version-matched UE4SS build. **This closes 7.2's original
      C++-hello-world blocker.** Not yet deployed to `ue4ss\Mods\` or run live — that's the next
      step, per 7.2's original visible-outcome bar (log shows the new mod starting *and*
      `AP_Randomizer` still starting normally).

      **7.5-in-C++, step 1 (position reflection), 2026-08-13**: with the C++ path unblocked and
      7.5's LuaSocket receive-corruption bug having no known fix, decided to rebuild the shipping
      adapter in C++ rather than keep chasing an alternate DLL -- reusing the Lua version's
      already-proven designs (field shapes, spawn/possession/camera-fix mechanisms), not its
      implementation. Following this whole phase's own methodology: one small step at a time,
      confirmed live before adding the next. Step 1: read the real local pawn's position natively
      in `on_update()`, throttled to ~2s intervals, grounded against this build's own UEPseudo
      headers (`UObjectGlobals::FindFirstOf`/`FindAllOf`, `UObject::GetValuePtrByPropertyName{,InChain}`,
      `AActor::K2_GetActorLocation`, `FVector::X()/Y()/Z()` -- confirmed as accessor methods, not
      plain fields, by reading `UnrealCoreStructs.hpp` directly rather than assuming the Lua
      binding's plain-field presentation carried over). Two real bugs found and fixed via live
      runs, not guesses:
      1. `FindFirstOf("PlayerController")` returned the class's CDO (Class Default Object),
         which never has a real Pawn -- found by comparing against the sibling Lua probe
         (`MeshGhostProbe`, still running in the same session), which read a real pawn/position at
         the exact same tick our C++ code logged "no valid PlayerController yet." Root cause
         confirmed by reading `UEHelpers.lua`'s own `GetPlayerController()` (the reference this
         whole phase's Lua probes relied on) -- it filters via `FindAllOf` plus a validity check,
         not a raw `FindFirstOf`. Fixed with `FindAllOf` + an `RF_ClassDefaultObject` flag check
         (a real, standard UE object flag, confirmed present in this exact build's own
         `UnrealFlags.hpp`).
      2. After that fix, the one correctly-found `MainPlayerController_C` instance (level-matching,
         confirmed via diagnostic logging of every candidate) still read `Pawn` as null every
         tick, while the sibling Lua probe read a real pawn at the same moment. Cause: `Pawn` is
         declared on the base `AController` class, several levels above `MainPlayerController_C`
         in the inheritance chain, and `GetValuePtrByPropertyName` only searches the object's own
         most-derived class's declared properties, not inherited ones --
         `GetValuePtrByPropertyNameInChain` (both declared side by side in `UObject.hpp`) walks the
         superclass chain instead. Switched to the chain-walking variant.
      **Confirmed live, 2026-08-13**, after both fixes: `UE4SS.log` shows correct real-time
      pawn positions tracking cleanly through a `ZONE_LowerCastle` -> `ZONE_Dungeon` level
      transition (the controller/pawn re-acquired correctly on the far side, matching the
      already-known "cached references go stale across transitions" lesson from `pitfalls.md`).
      This closes step 1. Next: real networking (the actual point of moving to C++), then port
      the spawn/possession/camera-fix design.

      **7.5-in-C++, step 2 (real networking), 2026-08-13**: added `BridgeClient` (plain Winsock2
      TCP, non-blocking connect via `ioctlsocket`/`select`, line-buffered receive) and wired hello/
      local_state sends + render_remote/despawn_remote receive-counting into `on_update()`. Wire
      format ported field-for-field from the proven Lua adapter and `PROTOCOL.md` -- no JSON
      library needed for this step since only fixed-shape envelopes are built/parsed (raw string
      construction for sends, count-only for receives; real parsing deferred to the spawn step).
      **Confirmed live and decisive, 2026-08-13**: user launched the game with the still-enabled
      Lua `MeshGhostGhostProbe` running at the same time (unintentionally, left over from earlier
      7.5 testing) -- and its already-known teleporting bug reproduced identically
      (`UE4SS.log`: `sends(calls=400 ok=400 ...) recv(lines=386 decodeFail=379 ...)`, ~98%
      corruption). The C++ mod, connected to the same bridge at the same real time, logged
      `lines_received=6058 lines_malformed=0` -- zero corruption across 6000+ lines under
      identical live conditions. This is the decisive comparison the phase needed: same core,
      same relay, same wall-clock window, only the client implementation differs. **7.5's
      original blocker is resolved.** Next: parse `render_remote` for real and port the
      spawn/possession/camera-fix design from the Lua version.

      **7.5-in-C++, step 3 (ghost spawn), 2026-08-13**: added JSON field extraction (minimal, not
      a general parser -- fixed-shape server-generated envelopes only), a `remotes` map driven by
      `render_remote`/`despawn_remote`, and real spawn logic porting the Lua version's already-
      proven design from the start rather than rediscovering it: spawn a clone of the local pawn's
      class via `UWorld::SpawnActor`, immediately re-possess the real local player via
      `GetFunctionByNameInChain("Possess")` + raw `ProcessEvent` (the already-confirmed
      auto-possess safety fix from Phase 7.4 -- skipping it risks repeating the known drag/death
      incident), disable collision, redraw every remote unconditionally every tick per
      `PROTOCOL.md`. Deliberately did NOT yet port the camera fight-back hook, to test spawn+follow
      in isolation first.

      **First live run: a real engine crash, not a soft bug.** `LowLevelFatalError
      [UnrealEngine.cpp:15915] Fatal world leaks detected.` -- the game force-closed. `UE4SS.log`
      shows the ghost spawned successfully (`spawned ghost for remote p1-ghost`, ~3s after
      connecting) and everything else (send/receive counters, zero corruption) stayed clean right
      up to the log's abrupt end -- no final line explains what leaked. User reported this
      happened before even reaching the main menu, meaning the ghost was very likely cloned from
      whatever transient pawn exists during the game's earliest boot/title-screen world, and never
      cleaned up before that world was torn down for the next one.

      **Two mitigations attempted, both still crashed.** (1) A reactive per-tick check comparing
      each ghost's `spawn_world` to the local player's current world, destroying and clearing any
      ghost whose world no longer matches -- still crashed (~15s run). (2) Added
      `SPAWN_DELAY_TICKS` (300) to avoid ever spawning against the transient boot-time pawn in the
      first place -- ran much longer this time (~35s, well past the delay window, matching normal
      boot-to-gameplay timing) but still crashed the same way, meaning the cause isn't specific to
      the earliest boot transition and both mitigations are addressing symptoms, not the mechanism.

      **Leading theory investigated directly against source and disproven, not just dropped.**
      Suspected the C++ mod's `UWorld::SpawnActor` wrapper might take a different, riskier path
      than the Lua binding's `SpawnActor` -- checked both real implementations, now readable since
      UEPseudo access was unblocked this session: `deps/first/Unreal/src/World.cpp`'s
      `UWorld::SpawnActor(UClass*, FVector const*, FRotator const*)` calls
      `BeginDeferredActorSpawnFromClass`/`FinishSpawningActor` internally, and
      `UE4SS/src/LuaType/LuaUWorld.cpp` (line 139) shows the Lua binding calls that exact same C++
      method, not a different raw engine call. **Both spawn paths are identical.** Whatever's
      different is elsewhere -- most likely candidate not yet tested: the `Possess` call itself
      (Lua's `controller:Possess(pawn)` goes through UE4SS's Lua argument-marshalling layer; the
      C++ mod calls raw `ProcessEvent` with a hand-built params struct, which could skip
      bookkeeping a "proper" call path performs).

      **Went to plan mode rather than a third blind guess** -- two guessed fixes failing
      identically is the exact "signal, not bad luck" pattern already in `agent_docs/pitfalls.md`.
      Recorded plan: `lowlevelfatalerror-file-d-build-ue5-sync-zazzy-star.md` (outside this repo)
      -- diagnostic-first (granular logging + a `LoadMapPreCallback`/`PostCallback` hook to confirm
      whether a real `LoadMap` call correlates with the crash, plus an isolate-by-subtraction
      fallback test disabling the `Possess` call entirely) before attempting a targeted fix.

      **Diagnostic hook confirmed the mechanism directly.** A `LoadMap PRE` hook logged a live
      ghost still referencing the old world at the exact moment `LoadMap` fired, and no `POST`
      ever followed -- the engine's own fatal-world-leak check kills the process synchronously
      inside that call. Fix applied: `destroy_all_ghosts()` called synchronously from the
      `LoadMapPreCallback` itself. **Still crashed, identically**, on the very next run.

      **Root cause found by adding a readback instead of trusting the destroy call.** Logged
      `ghost->GetWorld()` immediately after `K2_DestroyActor()` and again ~2s later: both times it
      still returned the *same, un-nulled* world pointer -- `K2_DestroyActor()` never actually
      detached the actor at all. Read the actual C++ implementation
      (`deps/first/Unreal/src/AActor.cpp`): `K2_DestroyActor()` is `UE_BEGIN_NATIVE_FUNCTION_BODY(
      "/Script/Engine.Actor:K2_DestroyActor") UE_CALL_FUNCTION()` -- the same reflected-UFunction-
      lookup mechanism already confirmed broken for `SetVisibility`/`MarkRenderStateDirty`/
      `DestroyComponent` earlier this phase, just via a different-looking C++ wrapper. **There is
      no working way to destroy a runtime-spawned actor on this build, full stop** -- confirmed,
      not assumed.

      **Redesigned from spawn-based to hijack-based ghosts** (matching the plan's fallback
      option): stop spawning entirely, find and repurpose an already-existing, already-registered
      `StaticMeshActor` in the local player's current world instead. Since nothing new is ever
      created, there's nothing that ever needs destroying -- the level's own normal teardown
      (which has always worked correctly for its own real props) handles cleanup transparently.
      This also removed the whole auto-possess safety-fix machinery: a `StaticMeshActor` can never
      auto-possess. **Confirmed live**: a real statue (`SkeletalMeshActor_1`, the same
      misleadingly-named prop the Lua saga found in this exact spot) followed the player through a
      full `ZONE_LowerCastle` → `ZONE_Dungeon` transition, no crash. User flagged a real safety
      concern mid-test: interactive objects (chairs, notes) must never get hijacked, since
      Archipelago hooks into them -- added a best-effort keyword exclusion list
      (`HIJACK_EXCLUDE_KEYWORDS`) as a belt-and-suspenders check on top of the structural argument
      that `StaticMeshActor` has no interaction support, so genuinely interactive objects are very
      unlikely to be that class at all.

      **New symptom surfaced once the crash was fixed: a hijacked ghost followed correctly for a
      while, then visually froze in place, every single run, regardless of which object was
      grabbed.** A `intended=`/`actual=` readback (same technique that caught two real bugs
      earlier this phase) showed something new: unlike every previous "silent failure" pattern in
      this file, the position data was **always** correct -- `intended` and `actual` matched on
      literally every logged tick, across entire sessions, through real transitions, with zero
      exceptions. The disconnect was between the (provably correct) data and the (visibly frozen)
      screen. Two guessed fixes tried and both failed to change the outcome: a periodic `bHidden`
      off/on toggle nudge (a working mechanism grounded via `gh api search/code`, 65 hits), and
      preferring hijack candidates that were already Mobility=Movable by default over ones needing
      a forced Mobility write (a real, single-variable test that **disproved** the Mobility theory
      outright -- both a statue and a "wall structure" confirmed already-Movable still froze
      identically, and the already-Movable heuristic had the further problem of preferring
      gameplay-relevant moving objects like walls/platforms over safe decoration, backwards from
      what a safety heuristic should want).

      **Found by isolating the variable, not guessing a third fix.** User suggested testing with
      "just the loopback thing, mimicking my own movement" -- built `LOCAL_OFFSET_TEST_MODE`, a
      mode that skips the bridge/core/relay entirely and repositions a hijacked object to
      (local pawn position + a fixed offset) every tick, driven purely by local reflection reads.
      This isolated the render-freeze from networking entirely -- and it froze identically,
      confirming the bug was never about the network layer, the JSON, or the core/relay, only
      about repositioning an actor from this specific code path. That redirected the investigation
      to *how* the position-setting code runs, not *what* data drives it.

      **Root cause, read directly from UE4SS's own source, not inferred:**
      `UE4SSProgram::update()` (`UE4SS/src/UE4SSProgram.cpp`) -- the function that calls every C++
      mod's `on_update()` -- runs `ProfilerSetThreadName("UE4SS-UpdateThread")` and its own loop
      with `std::this_thread::sleep_for(std::chrono::milliseconds(5))`. **`on_update()` has never
      run on the real Unreal game thread** -- it's a dedicated UE4SS-internal polling thread.
      Every actor write this mod ever made was landing in memory (hence the always-correct
      same-thread readback) but never reaching the renderer, which expects transform changes to
      flow through the real game thread's tick pipeline. This is the exact same reason Lua code
      throughout this project has needed `ExecuteInGameThread()` wrapping -- Lua callbacks aren't
      guaranteed to run on the game thread either, and the earlier-working Lua hijack script
      (Phase 7.4, confirmed via screenshots) almost certainly had that wrapping around its own
      position-setting calls, while this C++ port never did until now.

      **Fix**: registered `Hook::RegisterEngineTickPostCallback` (hooks the real `UEngine::Tick`)
      in `on_unreal_init()`, moved all actor reads/writes into that callback (`game_thread_tick()`)
      instead of `on_update()`, and added a mutex to hand data between the two threads (cached
      outgoing `local_state` JSON, a queue of incoming bridge lines). `on_update()` is now pure
      networking. **Confirmed live, 2026-08-13**: user, verbatim -- "yes it works, everything was
      following me constantly now." No freeze. See `agent_docs/verified.md` and
      `agent_docs/pitfalls.md`'s new "UE4SS C++ mod threading" section for the full transferable
      lesson. Reverted the now-unnecessary already-Movable-preference heuristic back to simple
      first-eligible-candidate selection + an always-applied Mobility force-write, since the real
      fix makes that force-write actually take visible effect, and the heuristic's side effect
      (preferring walls/platforms) was undesirable on its own merits.

      **Also found, not yet fixed**: a separate `Fatal Error!` crash (different signature, a
      `.dmp` crashdump, not `LowLevelFatalError`) on game *exit* while this mod was active --
      surfaced once during the hijack-crash investigation. Not yet root-caused; flagged here so a
      future session doesn't rediscover it from scratch. Possibly related to the `LoadMap` hook or
      a hijacked actor being touched during final shutdown teardown.

      **Confirmed live, 2026-08-12.** Deployed to `ue4ss\Mods\MeshGhostPseudo\dlls\main.dll` +
      empty `enabled.txt` (the documented alternative to a `mods.txt` line, per RE-UE4SS's own
      `installing-a-c++-mod.md` and matching the already-installed `AP_Randomizer`'s exact same
      setup) — deploy confirmed via `diff` against the build output. User launched the game and
      closed it after it loaded. `UE4SS.log` shows both mods starting within the same
      millisecond and `on_unreal_init` reached cleanly:
      ```
      [23:53:48.77] Mod 'MeshGhostPseudo' has enabled.txt, starting mod.
      [23:53:48.77] Mod 'AP_Randomizer' has enabled.txt, starting mod.
      [23:53:50.08] [MeshGhostPseudo] Phase 7.2 hello-world mod loaded, on_unreal_init reached.
      [23:53:50.08] AP_Randomizer hooks installed (ProcessEvent/ProcessConsoleExec/BeginPlay/
      StaticConstructObject), then its own normal Archipelago connect/disconnect cycling (no
      server configured -- expected, unrelated to this mod).
      ```
      **7.2 is now genuinely complete.** The C++/UEPseudo path -- blocked for the entire rest of
      this phase after the initial "no submodule access" finding -- is confirmed working end to
      end: real access, real build against the exact matching UE4SS version, real deploy, real
      coexistence with `AP_Randomizer`. This reopens the C++ path as viable for 7.5's actual
      blocker (the LuaSocket receive-corruption bug) -- next step is porting the bridge client to
      real C++ networking, sidestepping the vendored-Lua-runtime ABI issue entirely rather than
      hunting for an alternate DLL pair.

      **Confirmed live, sixth run: the drag is genuinely fixed.** `re-possess original pawn
      after spawn: ok`, `ghost is following`, and the run lasted **82 seconds** with no
      dragging and no forced death — versus ~13s to death on every one of the prior three
      dragged runs. The ghost visibly moved around following the player. One smaller, separate
      issue found the same run: the camera stayed pointed at the ghost even though input
      control had correctly returned to the real pawn — `Possess()` reassigns control but not
      necessarily the active camera view target, a distinct concept in UE. **Fixed**: added
      `controller:SetViewTargetWithBlend(pawn, 0)` right after `Possess()`, grounded via `gh
      api search/code` (218 hits). Not yet retested live.
- [x] 7.5 — Port 7.1's real local-state read (not just Stage 3's hardcoded dummy frame) and
      7.3's field decisions into a persistent, per-frame Lua bridge client — a `RegisterHook`-
      or engine-tick-driven loop, not a one-shot script like Stages 1-3, non-blocking connect
      with retry (Stage 3 used a blocking connect+timeout, fine for a one-shot probe, not for
      a real per-frame adapter), envelope shapes exactly per `adapters/_template/PROTOCOL.md`,
      send `local_state` every frame including `null`. `dev-scripts/run-core-pseudoregalia.bat`
      and reused `run-relay-loopback.bat` already exist (written for Stage 3). Visible outcome:
      a ghost trailing the local player over a real relay/core/bridge loopback round trip.
      **Written 2026-08-12**: `adapters/pseudoregalia/probe_ghost/Scripts/main.lua` rewritten
      from the 7.4 local-offset design into the real adapter. Reuses everything already confirmed
      live in 7.4 as-is (spawn `pawn:GetClass()`, re-possess, the `SetViewTargetWithBlend`
      camera-fight-back hook now gated on `anyGhostSpawned` instead of a single `ghost` var, the
      `MAX_TICK_DELTA`/`REFUSAL_RESYNC_LIMIT` backstop, the never-mutate-a-vector-read-from-
      elsewhere rule). New: vendored LuaSocket loading and a non-blocking
      connect/hello/send/receive loop (`settimeout(0)`, the same shape
      `adapters/bizhawk/pokemon/emerald/probes/phase5_5_sprite.lua` already uses, not Stage 3's blocking
      one-shot version); a real `getLocalState()` per 7.1's confirmed reads and 7.3's decided
      field shapes (`position` cm `[X,Y,Z]`, `orientation` full `[pitch,yaw,roll]`, `area_id` the
      level name, `anim` a placeholder inferred from position-delta speed rather than an
      unverified `CharacterMovement.Velocity` property read); a `remotes` table (`player_id` ->
      state + lazily-spawned ghost actor) driven entirely by `render_remote`/`despawn_remote`,
      redrawn unconditionally every tick per `PROTOCOL.md`'s rule, instead of the old single
      local-offset `ghost`. JSON encode/decode ported directly from
      `adapters/bizhawk/pokemon/emerald/probes/phase5_5_sprite.lua`'s own minimal implementation (plain Lua,
      already proven against the real wire format). `despawn_remote` and connection-loss cleanup
      both try `K2_DestroyActor()` (grounded, 710 hits, not yet confirmed live on this build)
      with a hide-far-away fallback, given this build's UFunction reflection has repeatedly
      turned out narrower than expected this phase. LuaSocket DLLs copied from
      `probe_socket/Scripts/lib/x64/` into this mod's own `lib/x64/`. Deployed, and
      `dev-scripts/run-relay-loopback.bat`/`run-core-pseudoregalia.bat`'s underlying processes
      started for testing (relay listening on 7777, core connected to it and bridge listening on
      7778, both confirmed via their own console output) — not yet tested live in-game.

      **First live test, next session (2026-08-12), found two real bugs, both fixed and
      confirmed.** (1) A crash: `redrawRemote`'s deferred `ExecuteInGameThread` callback checked
      `not remote.ghost:IsValid()`, but a level transition can nil `remote.ghost` out from under
      it before the callback runs — `nil:IsValid()` is a hard Lua error
      (`attempt to index a nil value (field 'ghost')`), not "invalid", confirmed live in
      `UE4SS.log` right at a `ZONE_LowerCastle` → `ZONE_Dungeon` transition. Fixed with an explicit
      `remote.ghost == nil` check. (2) The camera stuck on the ghost after any area change: the
      `SetViewTargetWithBlend` fight-back hook (7.4) caches `lastKnownGoodViewTarget`, which a
      transition invalidates (the old rig is destroyed) — the hook's old behavior was to give up
      forever once that reference went bad, rather than re-baselining on the next legitimate call.
      Fixed by treating a stale/invalid cached target the same as "never learned yet." **Confirmed
      live, camera correct through a transition.**

      **The "teleporting instead of following" symptom took much longer to explain, and is now a
      genuine open blocker, not a bug in this script.** Progressively narrower diagnostics (each
      added only after the previous one gave a clean, unambiguous answer, per this phase's
      standing rule against guessed fixes):
      - A `target=`/`actual=` redraw log (same technique that caught two real bugs in 7.4) showed
        every write landing exactly as intended — ruling out the apply/positioning side entirely.
        But the *target* value itself sat frozen for 6-20+ seconds at a stretch before jumping.
      - Outgoing send counters showed **100% success, 0 timeouts, 0 errors** across every test —
        ruling out the adapter's own socket writes.
      - Raw receive-side counters (before any JSON parsing) showed **83-98% of received lines
        failing to decode** — lines were arriving at the expected volume, but the content was bad.
      - A hex dump of the actual failing bytes (plain-text logging first hit UE4SS's console
        truncating hard on unprintable bytes, itself informative) showed well-formed JSON up to an
        inconsistent cutoff point, then unreadable garbage for the rest of the line —
        `string.byte` itself failing partway through a string `#line` correctly reports as, e.g.,
        325 bytes long. The cutoff point moves between messages (sometimes covering the whole
        line, sometimes none of it), not tied to any specific byte value in the data.
      - Two mitigation hypotheses were tested and both came back null: shrinking `area_id` from
        the full `GetFullName()` path to just the short level name (~325 → ~274 bytes) produced
        statistically identical failure rates at matching tick counts (98/96/89/86% vs.
        98/99/88/88%); halving the tick rate (100ms → 250ms) also produced the same ~84% failure
        rate at the same real-elapsed-time mark. Neither message size nor send frequency is the
        trigger.
      - One consistent pattern across every run: the failure rate drops from ~98% early in a
        session to ~83% by 30-45 seconds in, regardless of size or rate — something about
        sustained connection time changes the failure probability, without ever approaching 0%.

      **Conclusion: this is a genuine binary-compatibility bug in the vendored
      `socket-windows-5-4.dll`/`lua54.dll` pair against UE4SS's own independently-built, statically
      embedded Lua 5.4 — not a JSON-format bug, not a core/relay bug, not an adapter logic bug.**
      This connects to an already-flagged, previously unresolved risk from 7.2 Stage 3: "three
      further receive attempts in the same run returned empty strings instead of `timeout`", noted
      then as worth understanding before trusting this exact library pairing for the real adapter.
      Under a one-shot probe's light traffic that mystery never recurred visibly; under 7.5's real
      sustained 10Hz two-way traffic it's the dominant behavior. **7.5 is not complete** — the
      bridge round trip works (confirmed: hello, spawn, camera fix all correct), but reliable data
      delivery does not, so a ghost cannot smoothly follow. Reverted the tick-rate experiment back
      to 100ms (250ms tested no better, only choppier). Options for a future session, neither
      attempted yet: hunt for an alternate prebuilt `socket-windows-5-4.dll`/`lua54.dll` build that
      might not hit this exact ABI mismatch; or the C++/UEPseudo path from 7.2, still blocked on
      the same private-submodule access. See `agent_docs/risks.md`.
- [x] 7.6 — Real character-visual ghost: duplicate the player's skeletal mesh actor with
      collision/input/gameplay stripped, driven by the wire `anim` tag. Flagged in `risks.md`
      as likely the hardest task in the phase — UE5 has no direct equivalent of Unity's
      `Animator.Play(clipName)` on a cloned actor.
      **2026-08-13, retest started**: user asked directly how the Lua adapter handled despawn
      across area/menu transitions, since the C++ port can't despawn and that blocks anything
      but rigid hijacked-prop ghosts. Answer, from re-reading both adapters: **Lua never
      despawned either** — its `K2_DestroyActor()` fallback path is dead code (the call
      silently no-ops on this build rather than throwing, so `pcall` reports success and the
      "hide far away" fallback never runs). What actually worked was a lazy per-world respawn:
      poll `remote.ghost:IsValid()` every tick, nil the reference once a level transition
      invalidates it, respawn fresh in the new world (`main.lua:787-794`). Critically, every
      call in that path ran inside `ExecuteInGameThread` — and the original C++ spawn attempt's
      "Fatal world leaks detected" crash and "`K2_DestroyActor` never works on this build"
      verdict (see the "Root cause found by adding a readback" entry above) were both produced
      entirely from `on_update()`, discovered only afterwards to be UE4SS's own polling thread,
      not the game thread. That thread bug wasn't found/fixed (`RegisterEngineTickPostCallback`)
      until later the same session, so the spawn path was never retried on the game thread.
      **Implemented, not yet live-tested**: `SPAWN_BASED_GHOSTS` in `Plugin.cpp` retests exactly
      this — `ensure_ghost_spawned` ports `trySpawnRemoteGhost` field-for-field (spawn a clone of
      the local pawn's class, immediately `Possess` the real player back via
      `GetFunctionByNameInChain("Possess")` + `ProcessEvent`, matching the pattern already
      confirmed live for this exact call before the original crash), called only from
      `game_thread_tick` so every call is on the real game thread. Ported Lua's staleness poll
      (`actor_is_alive`, using `UObject::IsUnreachable()` — read directly from UE4SS's own Lua
      `IsValid()` binding, `LuaUObject.hpp:721-733`, not guessed) as the primary per-tick check,
      replacing the old world-pointer-only comparison. Added a guard the Lua adapter didn't need
      (it never spawned before reaching a real level): refuse to spawn unless the local pawn's
      class name contains "PlayerGoat", so no ghost is ever cloned from the title screen's
      transient `DefaultPawn` — the actual origin of the original crash's leaked world. The old
      hijack-a-StaticMeshActor path is kept intact, selected by flipping `SPAWN_BASED_GHOSTS` to
      `false`, as an instant revert if the leak reproduces even on the game thread. Deployed to
      `ue4ss\Mods\MeshGhostPseudo\dlls\main.dll`, diff-confirmed identical to the build output.

      **Confirmed live 2026-08-13**: user, verbatim — "the game worked fine, no crash" and "i saw
      the ghost/player model". The "Fatal world leaks detected" crash does NOT reproduce once
      spawn/reposition/Possess calls run from `game_thread_tick` (the real game thread) instead of
      `on_update()` — the original spawn-crash verdict was a thread-context artifact, not a fact
      about this build's spawn API. Note this does not touch the separate `K2_DestroyActor`
      no-op finding — this design still never calls it, so that claim remains untested, not
      disproven.

      **New symptom, expected**: the camera stayed locked on the ghost instead of the player —
      exactly Phase 7.4's camera bug, re-opened because a spawned pawn clone (unlike the hijacked
      StaticMeshActor) again shares proximity with the player and triggers the game's own
      view-target re-pick. User couldn't test an area transition yet because the stuck camera
      made movement impractical. **Fix applied, not yet tested**: ported the confirmed Lua
      `SetViewTargetWithBlend` fight-back hook (`main.lua:520-581`) to C++ via
      `RegisterProcessEventPostCallback` filtered to that one UFunction (C++ has no per-function
      `RegisterHook` like Lua's — a cached UFunction pointer comparison inside the generic
      ProcessEvent hook is the same mechanism Lua's own `RegisterHook` is built on). The actual
      override call is deferred to `game_thread_tick` rather than invoked from inside the hook,
      matching Lua's own `ExecuteInGameThread` deferral of the identical call. Deployed,
      diff-confirmed.

      **First camera-fix run: made things worse, not just ineffective.** User: camera still
      stuck/centered on the ghost, and now camera control (look-around) was broken entirely —
      a real regression, not just a failed fix. This is a stronger signal than an ordinary
      failed attempt (`pitfalls.md`'s "two guessed fixes failing identically" rule doesn't even
      apply here; a single attempt made the game less controllable than before it ran).
      **Root cause found by inspection, not a second guess**: the restore call built its own
      hand-guessed 5-field `SetViewTargetWithBlendParams` struct as the `ProcessEvent` Parms
      buffer, sized by assumption rather than read from the engine. If the function's real
      reflected parameter block (`UFunction::GetPropertiesSize()`) is larger than that guess, the
      engine writes past the end of a local stack struct during the call — plausible stack
      corruption, which would explain a control-breaking side effect far better than a plain
      logic bug would. The read side (extracting `NewViewTarget` from the *engine's own*,
      correctly-sized incoming Parms buffer) was never at risk — only the write/call side, where
      *we* pick the buffer's size. **Fix**: added `call_ufunction_with_leading_actor_arg`, which
      always sizes the Parms buffer from the function's own `GetPropertiesSize()`, zero-fills it
      (matching every default argument value both this call and the `Possess` call need), and
      writes only the one pointer argument at offset 0 — the same thing UE4SS's own Lua binding
      does under the hood, just without Lua's marshalling layer doing it automatically. Applied to
      both the camera restore call and the earlier `Possess` call (lower risk there, a single-
      pointer-argument function, but fixed for the same reason). Rebuilt (0 errors), deployed,
      diff-confirmed.

      **Second camera-fix run: identical symptom, unchanged.** Camera still stuck on the ghost,
      still couldn't look around — no different from before the buffer-size fix. This ruled out
      the buffer-size theory as the (or at least the only) cause.

      **Went further and made the hook itself purely read-only** (no `ProcessEvent` call
      anywhere, just logging) to isolate whether the override call was the problem at all.
      **Third run: identical symptom again, with zero override calls being made.** This is
      stronger than an ordinary failed-fix signal — `pitfalls.md`'s "two guessed fixes failing
      identically" rule doesn't even fully cover it, since a *read-only* hook shouldn't be able to
      break camera control at all if the only thing wrong were the fight-back logic. Real,
      unresolved candidates going into the next round: (a) this game may call
      `SetViewTargetWithBlend` through a path `RegisterProcessEventPostCallback` never sees at all
      (UE4SS's Lua `RegisterHook`, which the original Phase 7.4 fix used, may hook at a different,
      lower layer than a generic ProcessEvent filter — untested assumption); (b) registering a
      global post-hook on literally every reflected call in the game may itself have a cost or
      side effect distinct from anything the hook's own logic does.

      **User-requested pivot, 2026-08-13: stop guessing a fourth camera-hook variant.** Removed
      `register_camera_fightback_hook()`'s call site entirely (function kept, not deleted, for
      when this resumes) and re-added Lua's original `SPAWN_DELAY_TICKS` mechanism
      (`ticks_since_pawn_valid`, gates `ensure_ghost_spawned`, ~300 ticks/~5s at 60fps) — this is
      the exact setup (player spawns and gets a settled camera first, ghost spawns after a real
      delay and the swap is a clean, isolated, observable event) that originally broke this bug
      open in Phase 7.4 (`agent_docs/phases/phase7.md`'s "Twenty-fourth live run" entry above).
      Rebuilt (0 errors), deployed, diff-confirmed, `UE4SS.log` cleared for a clean capture.

      **User asked directly whether the deploy was even taking effect.** Verified properly rather
      than asserted: confirmed the game wasn't running (no stale locked DLL), the deployed
      `main.dll` was byte-identical to the fresh build, `UE4SS.log` was freshly regenerated by the
      run in question, and no duplicate/stale copy of the mod existed anywhere else on the
      machine. All clean — the deploy was real.

      **Reading the log instead of guessing found a real, separate bug.** `ticks_since_pawn_valid`
      was incrementing from the moment *any* pawn+controller pair existed -- including the title
      screen's own `DefaultPawn`, which sits valid for several real seconds before "Start" -- so
      by the time the real player pawn spawned, the counter had already blown past
      `SPAWN_DELAY_TICKS`. Log proof: `local world changed: pawn=BP_PlayerGoatMain_C ...` and
      `spawned ghost for remote p1-ghost` fired at the **same timestamp**, not ~5s apart. Fixed:
      only count ticks while `class_looks_like_player(pawn_obj)` is true; reset to 0 otherwise.
      Rebuilt, deployed, diff-confirmed.

      **Confirmed live, delay now working correctly**: user had full camera control on spawn-in,
      then once the (correctly-delayed) ghost spawned, the camera both centered on the ghost AND
      lost the ability to look around at all — the exact same combined symptom as before, now
      confirmed against the *correct* scenario rather than a delay-bug-contaminated one. This
      reproduces Phase 7.4's original camera re-pick cleanly, plus the new-to-this-build control
      freeze on top of it.

      **Re-enabled the read-only-only diagnostic hook** (no `ProcessEvent` call anywhere in its
      body) now that the scenario it's observing is the real one, not the delay-bug-contaminated
      one from the previous read-only attempt. Rebuilt, deployed, diff-confirmed, log cleared.

      **Live run: user reproduced the bug again (had camera, lost it and froze the instant the
      ghost spawned) — and this time the log answered the real question.** Read `UE4SS.log`
      directly rather than asking the user to describe it: `grep -c "SetViewTargetWithBlend"`
      across the entire session returned **zero** real hits (the one case-insensitive match was
      an unrelated hook name, `DiagnosticLoadMapPost`). The read-only hook registered successfully
      (confirmed by its own "Added posthook" log line) but never fired once, despite the camera
      visibly locking onto the ghost during that exact run. **Confirms hypothesis (a) from the
      previous entry**: `RegisterProcessEventPostCallback` genuinely does not see this call on
      this build.

      **Root cause found by reading UE4SS's own `RegisterHook` implementation directly**
      (`RE-UE4SS/UE4SS/src/Mod/LuaMod.cpp:3907-3921`), not inferred: for a **native** UFunction
      (`FUNC_Native` — which `SetViewTargetWithBlend` is), Lua's `RegisterHook` does NOT install a
      ProcessEvent filter at all. It calls `UFunction::RegisterPreHook`/`RegisterPostHook` directly
      on the function object, which patches the function's own native entry point and catches
      every call regardless of dispatch path. `RegisterProcessEventPostCallback` only sees calls
      dispatched *through* `ProcessEvent` (the Blueprint VM path) — a real, narrower, and
      previously undocumented-in-this-project distinction. This game evidently calls
      `SetViewTargetWithBlend` as a direct native call, bypassing `ProcessEvent` entirely, which is
      exactly why two attempts built on the wrong hook layer never had a chance regardless of what
      logic was inside them.

      **Rewrote the hook using `UFunction::RegisterPreHook`** (confirmed present and public in
      UEPseudo, `Class.hpp:421-422`) — and this also enables a strictly safer design than either
      previous attempt: a pre-hook fires *before* the engine's own native call runs, and
      `UnrealScriptFunctionCallableContext::GetParams<T>()` gives direct access to the engine's
      own, already-correctly-sized argument buffer (`TheStack.Locals()`). The fix rewrites
      `NewViewTarget` (the first argument, offset 0) in place when it needs to fight back, so the
      engine's own call simply proceeds with the corrected target — no second call anywhere, no
      guessed buffer size (the whole class of bug from the first attempt), no reentrancy, no
      defer-to-next-tick machinery. Removed the now-fully-dead `pending_camera_restore_*`
      deferral fields. Rebuilt (0 errors), deployed, diff-confirmed, log cleared.

      **CONFIRMED WORKING, live, on screen.** User: camera stayed on the player at spawn-in,
      stayed on the player once the ghost spawned in (previously locked to the ghost and froze
      camera control entirely), and "the ghost is also following the player perfectly without
      stopping or teleporting." Logged to `agent_docs/verified.md`. This closes both of Phase
      7.6's headline questions from the top of this entry: the game-thread spawn retest survives,
      and the camera bug (re-opened by returning to spawn-based ghosts) has a real, working fix.

      **New crash found immediately after, entering a second area**: `EXCEPTION_ACCESS_VIOLATION
      reading address 0x000000000000001c`, crash stack shows the fault inside
      `register_camera_fightback_hook`'s own lambda, called from the game's native code via
      `UFunction::RegisterPreHook`'s dispatch (`UE4SS.dll` frames), during what the user describes
      as entering another area. Leading theory, not yet confirmed: `last_known_good_view_target`
      is a raw `AActor*` cached across calls, and calling `->IsUnreachable()` on it (the existing
      staleness check) requires dereferencing the object's own memory -- safe if the object is
      merely GC-unreachable-but-still-allocated, but not safe if a level transition has fully
      freed it, unlike Lua's `IsValid()` which checks a separate live-object registry first and
      never touches the object's own memory for an already-freed pointer. This is the same
      "level transition invalidates cached references" failure class documented in
      `pitfalls.md`, just now crashing instead of silently reading garbage because we're calling a
      real member function, not a Lua-marshalled property read. Not yet fixed at the time of this
      entry -- see the next entry for the fix once tested.

      **Fixed and confirmed live, 2026-08-13**: added `last_known_good_view_target = nullptr;` to
      the existing `LoadMap PRE` hook (the same hook `release_all_ghosts` already runs from),
      clearing the cached pointer proactively before a transition has a chance to free the object
      it points to, rather than trying to detect staleness after the fact. Rebuild hit one
      unrelated snag first: `cmake --build . --config Game__Shipping__Win64` failed with
      `could not create CMAKE_GENERATOR "Visual Studio 17 2022"` -- traced to the agent's Bash
      tool `PATH` resolving `cmake` to msys2's bundled copy (`C:\devkitPro\msys2\...`, version
      4.0.2, no VS generator support) ahead of the real confirmed install
      (`C:\Program Files\CMake\bin`, 4.4.2, see `environment.md`); invoking the full path fixed
      it, 0 build errors. Deployed to `ue4ss\Mods\MeshGhostPseudo\dlls\main.dll`,
      hash-diff-confirmed identical to the build output (`Get-FileHash`), `UE4SS.log` cleared for
      a clean capture, no stale game process holding a lock. User then ran a full transition
      sweep in one session: entering the second area, returning to the first area, exiting to the
      main menu and pressing "play" again, and a normal game exit at the end -- no crashes at any
      point. **7.6 is now fully closed**, including the item that paused it mid-session. See
      `agent_docs/verified.md`.

      **7.6 reopened same day: ghost animation, collision, and facing-direction, once the spawn
      mechanism itself was solid.** With spawn/possess/camera/area-transition all confirmed
      working, the ghost was still stiff-gliding with no animation at all — 7.3's `anim` field had
      only ever been a hardcoded `"idle"` placeholder, never revisited once real spawn-based
      ghosts existed to drive. Fixed by reflecting the real pawn's
      `moveState`/`actionState`/`horizontalSpeed`/`verticalSpeed`/`animJumpType`/
      `CharacterMovement->MovementMode` (field names confirmed via a read-only native reflection
      dump, `log_pawn_reflection_once`, not guessed) and mirroring them onto the ghost's own pawn
      instance each tick via `extras` — since the ghost is a full spawned clone of the same
      Blueprint class, its own already-attached `ABP_PlayerGoat_C` AnimBP instance then drives
      itself the same way it does for the real player. **Confirmed live**: real walk/run/idle
      animation. See `agent_docs/verified.md`'s "ghost animation state" entry. Two follow-on gaps
      were tried and not solved: a stuck falling/airborne pose after landing (two attempts,
      mirroring `MovementMode` then latched `landed?`/`jumped?` pulses, both failed live), and no
      ledge-grab. A `GHOST_COLLISION_ENABLED` attempt at fixing both (the theory being both need a
      real physics trace) was tried twice and reverted twice — the first attempt
      (`SetActorEnableCollision(true)` alone) made the ghost killable, which killed the *real
      player's own character* too, without ever making the ghost solid; the second attempt (adding
      `SetCollisionResponseToChannel(Pawn, Block)` on the ghost's capsule, confirmed via log to
      have genuinely fired) still produced no solidity, since UE's dynamic-vs-dynamic blocking
      needs both actors' collision response to agree, and only the ghost's side was ever changed —
      fixing the real player's side was judged too large a risk to take without a separate,
      explicit decision. See `agent_docs/risks.md`'s ghost-collision entry.

      **Facing direction: the ghost never turned to face a different direction, and this took the
      rest of the session to actually solve.** Established early: the real player's own
      `CapsuleComponent` rotation genuinely tracks turning, so capsule rotation is this game's real
      facing mechanism (not some other, undiscovered one). But the *ghost's* rotation read back as
      implausible garbage (`~5.5e-315`) through every read path tried —
      `K2_GetActorRotation()` and a direct `RelativeRotation` property read alike — confirmed
      already-garbage by the very first tick after spawn via a tick-by-tick trace. A forced
      0/90/180/270 yaw-cycle test produced zero visible change, which looked at the time like
      proof the write mechanism itself wasn't reaching the renderer. Several fix attempts failed
      live and in this order: `bTeleport=true` on `K2_SetActorLocationAndRotation`; forcing the
      ghost's own `bOrientRotationToMovement` to `false`; calling the separate native
      `K2_SetActorRotation` function instead; and — the one real partial finding along the way —
      writing `CapsuleComponent.RelativeRotation` as a **direct property** (bypassing every native
      call) stopped the garbage readback and held the written value stably, but still had zero
      visual effect, even after a `bHiddenInGame` render-nudge toggle (the same trick already
      proven for the actor-level `bHidden` elsewhere in this file). This cleanly separated the
      problem into two: the property write itself worked; something in render-transform
      propagation (normally handled by UE's own `SetRelativeRotation()`, which a raw property poke
      skips) did not.

      **Root cause found by reading the vendored SDK's own source, not by further guessing at the
      ghost/engine side**, in a follow-up session on 2026-08-13: `RE-UE4SS/deps/first/Unreal/src/
      AActor.cpp`'s `K2_SetActorLocationAndRotation` and `K2_SetActorRotation` marshal `FRotator`'s
      `Pitch`/`Yaw`/`Roll` as hardcoded `float` into the reflected native-call parameter buffer.
      `FVector`'s `X`/`Y`/`Z`, by contrast, correctly branch on engine version via `UE_COPY_VECTOR`
      (`include/Unreal/BPMacros.hpp:120-132`) — `float` below UE 5.0, `double` on 5.0+. There is no
      equivalent version branch for `FRotator`. Pseudoregalia is UE 5.1 (confirmed in 7.0 above),
      so the real engine fields are `double`; writing 4 bytes of float into an 8-byte slot of a
      zeroed buffer leaves the upper 4 bytes zero, and the engine reads back a denormal near zero.
      Confirmed arithmetically, not just plausibly: `90.0f`'s bit pattern placed in the low half of
      a zeroed double slot is exactly `5.529052754e-315` — matching the logged `~5.5e-315` garbage
      to three significant figures. This explained every earlier symptom at once: position (marshaled
      correctly by the version-aware `UE_COPY_VECTOR`) always stuck while rotation (marshaled by the
      broken hardcoded-float path) never did, in the very same call; the forced yaw cycle produced
      no visible change because every value became ≈0, not because the write mechanism was dead;
      and the direct property write was the one path in the file that bypassed the bug entirely,
      which is exactly why it was the only one that ever held a correct value in memory.

      **Fix**: a new local, version-aware helper, `call_set_actor_location_and_rotation` (added
      beside the file's existing `call_set_collision_response_to_channel`, same "read real
      `FProperty::GetOffset_Internal()` offsets, don't guess a struct layout" pattern), replacing
      the stacked three-writes-fighting-each-other block at both call sites
      (`run_local_offset_test_tick` and `game_thread_tick`) with one correct call. Deliberately
      *not* a patch to the SDK itself — `RE-UE4SS` is a git submodule, so this repo tracks only its
      pinned commit (`733e5969`), never its file contents; an edit to `BPMacros.hpp` could not be
      committed to this repo at all, would be invisible to anyone cloning it fresh, and would be
      silently wiped by any `git submodule update`. See `agent_docs/pitfalls.md`'s new SDK-marshaling
      entry for the full transferable lesson (it will recur on any UE5 game targeted via this SDK).

      Rebuilt (0 errors, `cmake --build . --config Game__Shipping__Win64` via the full path per the
      earlier `CMAKE_GENERATOR` PATH note above), deployed, hash-diff-confirmed. Tested with
      `LOCAL_OFFSET_TEST_MODE` and `FORCE_ROTATION_CYCLE_TEST` both `true` (no relay/core/bridge
      needed) — **CONFIRMED WORKING, live, on screen.** User, verbatim: "it works!, the ghost is
      turning around." `UE4SS.log` cross-check from the same run: the one-time diagnostic line
      confirms the helper resolved real offsets and chose the `double` path
      (`NewLocation@0 NewRotation@24 inner_type=double parms_size=296`), and every subsequent
      `TRACE` line shows `sent`/`K2_actual`/`reflected_actual` in exact agreement (e.g.
      `sent=180 K2_actual=180 reflected_actual=180`; `sent=270` normalizing to `K2_actual=-90...`,
      the same angle, not an error) — replacing the earlier `~5.5e-315` garbage entirely. See
      `agent_docs/verified.md`.

      Both diagnostic flags were then flipped back to `false` (restoring the real networked path
      and real yaw-mirroring as the normal shipping behavior), rebuilt, redeployed, and
      hash-diff-confirmed again. **Real-networked-path facing confirmed live the same day**: user,
      verbatim, "its following properly now" — the ghost mirrors the real player's own turning,
      not just the forced test cycle. **Facing direction is now fully closed end-to-end.**

      **Unexpected side effect**: with facing now correct, ledge-grab — one of the two animation
      gaps left open by the earlier "ghost animation state" work — started working. It was never
      a separate bug; it plausibly depended on the ghost's rotation actually reaching the
      renderer (e.g. ledge-grab detection needing a geometrically correct facing to trace
      against). This also surfaced a **new** bug, only reachable now that ledge-grab works at
      all: the ghost gets stuck in the ledge-hang animation after the real player has already
      released the ledge and moved away. Not yet investigated. The other open animation bug (a
      stuck falling/airborne pose after landing) is unaffected by this fix and still reproduces
      exactly as before — both are plausibly the same root-cause class as the already-tried-and-
      failed `landed?`/`jumped?` pulse mirroring: a one-shot state transition on the real
      player's side not being mirrored onto the ghost's AnimBP. See `agent_docs/verified.md`.

      A secondary, unrelated bug found in the same investigation and deliberately left unfixed:
      `FRotator::Quaternion()` (`include/Unreal/Rotator.hpp:158`) is missing a negation on its `Y`
      term versus UE's real formula — harmless here because pitch and roll are confirmed always
      zero for this pawn (Phase 7.1), so not worth patching a submodule over; revisit only if a
      future game with non-zero pawn pitch is targeted through this same SDK.

      **Both open animation gaps closed, same day, follow-up session (full detail in
      `agent_docs/status.md`/`agent_docs/verified.md`, condensed here for this file's own
      record):** the earlier `landed?`/`jumped?` pulse-mirroring attempt (above) turned out to
      have been a silent no-op, not a disproven theory — a reflection dump confirmed those
      fields live only on `animBPref` (the AnimBP instance), never on the pawn the old code
      actually read/wrote. Redone hopping through `animBPref` on both ends, with the wire field
      changed from a single-tick bool to a monotonic `land_count`/`jump_count` counter (a bool
      pulse can't survive the send-rate cap or the interpolation buffer holding an older
      snapshot). **Confirmed live**: no longer stuck in a falling pose after landing. The
      separate ledge-hang-stuck-forever bug turned out to be an Anim Montage playing
      independently of the state-machine bytes (which all provably reset correctly) — found and
      called the real `Montage_Stop` UFunction (name and parameter offsets confirmed via
      read-only reflection, not assumed) on the same land/jump-edge transition. **Confirmed
      live.** Both fixes are in `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`
      (`read_animbp_bool`/`write_animbp_bool`, `call_montage_stop`). **7.6 is now fully closed**,
      including both animation gaps this entry originally left open.
- [x] Release packaging (2026-08-13, ahead of 7.7): rebuilt `main.dll` fresh from the current
      `a1e1557` sources (`cmake --build`, 0 errors) and staged it under
      `packaging/release/games/pseudoregalia/MeshGhostPseudo/` (`dlls/main.dll` + empty
      `enabled.txt`, the UE4SS mod-folder layout confirmed live earlier in this phase), with
      `built-from.txt` recording source hashes and a new `dev-scripts/build-pseudoregalia.bat`
      mirroring TEVI's staleness-gate pattern. `.github/workflows/release.yml` got a matching
      staleness-check step. Cut as **EXPERIMENTAL / pre-release**, the same status TEVI shipped
      at before its own untested-with-a-second-player release — this is packaging, not a claim
      that two-player works; that's 7.7 below.
- [x] 7.7 — Two real players. **Confirmed 2026-08-16**: two players on two separate machines,
      one of them the Linux/Proton tester. Cleared pole rotation specifically (came back fine).
      Evidence in `verified.md`. It did **not** settle three items that are still open in
      `agent_docs/status.md`: the thrown sword near a save crystal, the pole-*vanish* bug (a
      different item from pole rotation, and easy to conflate with it), and the ghost-collision
      keep-or-axe call, which no session has recorded a judgement on.
- [x] 7.8 — Slide pose via the game's own crouch path (2026-08-17). Retired the `+43` render-Z
      bandage: the ghost is now posed by driving the game's crouch, so the capsule and the mesh
      agree instead of being corrected apart. Evidence in `verified.md`; build-log form:
      `adapters/pseudoregalia/README.md` steps 43-44; the retired bandage is struck through in
      `adapters/pseudoregalia/BANDAGES.md`. Commit `7f7399a`.
- [x] Release packaging restructured (2026-08-13): both this entry's `MeshGhostPseudo/` path
      and `ue4ss-runtime/` (from the earlier UE4SS-bundling ADR) moved to
      `packaging/release/games/pseudoregalia/pseudoregalia/Binaries/Win64/...`, mirroring the
      real Steam install's own folder layout so the whole `pseudoregalia/` folder is a single
      drag-and-drop, matching how the Archipelago randomizer's own download works — see
      `agent_docs/licensing.md`'s RE-UE4SS entry and `packaging/release/games/pseudoregalia/README.txt`.
      `dev-scripts/build-pseudoregalia.bat`/`stage-ue4ss-runtime.bat` and `release.yml`'s
      staleness gates updated to match; `built-from.txt` files kept outside the drag-and-drop
      tree so they never land in a user's game folder.

## Notes

- `adapters/pseudoregalia/README.md` updated 2026-08-12 with the confirmed tooling facts and
  the Lua-probe/C++-adapter decision.
- **Both since shipped, game-agnostically in `internal/core`, so they now apply to Pseudoregalia
  the same way they already do to TEVI/Emerald**: cross-area filtering (`Core.remoteStatesAt`
  now filters by `area_id` equality — 2026-08-13 ADR in `architecture.md`, built as part of
  TEVI's Phase 6.6) and a peer game-version check (`hello` carries an optional `game_version`,
  sticky per room — 2026-08-14 room-code/version ADR, see `agent_docs/plans.md`'s "Room codes /
  relay safety" section). Neither was re-verified specifically against a live Pseudoregalia
  session (that needs 7.7's real second player), but both are the same core-level code path
  already confirmed live for TEVI, not something Pseudoregalia-specific left undone.
- Environment drift is now a live, observed risk for this phase specifically (see the
  mid-task UE4SS version correction above) — re-check `environment.md`'s UE4SS version at the
  start of any future session before resuming, rather than trusting the last recorded value.
- **Found live 2026-08-15: cling-gem effect and empty-hand glow both missing on the ghost.**
  **Status now (same day): cling gem FIXED and confirmed live; empty-hand glow still open, but
  for a known reason — see the VFX-session bullet below.** Two symptoms as originally found:
  (1) the cling gem's sparkle/effect doesn't render on the ghost when
  the real player clings (the cling *animation* itself already works for free via the existing
  continuous-state mirror — see `verified.md`'s ability-field-trace entry — this is specifically
  the sparkle VFX layered on top); (2) the real player's hand glows when empty (not currently
  holding the sword) — that glow doesn't appear on the ghost's hand. Neither has any sync code
  today; `wallRideVFX`/`chargingVFX` exist only in the disabled `ABILITY_FIELD_TRACE` diagnostic
  block (read-only, never sent). **Superseded, same day**: the sword-held/thrown half of this
  entry (originally "the underlying sword-held state isn't tracked at all") is now stale —
  `weaponEquipped?`/`animEquippedWeapon` sync shipped as `RemoteGhost::target_weapon_equipped`
  the same day, five fix attempts in. **Root cause now confirmed, not just theorized, and sharper
  than first framed**: an inversion test (deliberately syncing the ghost the opposite of the real
  player's weapon state) showed zero visible effect across a real multi-throw/pickup session, with
  an independent readback proving the inverted value genuinely wrote and stuck. A follow-up test
  changed the real player's *costume* live after the ghost had already spawned — the ghost's
  outfit didn't follow either. Together these show the ghost's visual identity (mesh/weapon/
  outfit) is a **one-time snapshot taken at spawn, never re-applied by anything**, ours or the
  game's own — not a live link to "current save state" that our sync code merely failed to
  override. **Superseded again, same day: the weapon half is now FIXED and confirmed live**,
  found via a genuine 0%/100%-completion save comparison (dumping every reflected property's real
  value at ghost spawn on two saves, diffing them — see the new build-log step 20 in
  `adapters/pseudoregalia/README.md`, a reusable technique, not weapon-specific). That diff found
  the one real differing field (`animEquippedWeapon` on `animBPref`, out of 230 properties) and
  separately proved `WeaponMesh`'s own 250 properties never differ at all, ruling the component
  out entirely. Root cause: the ghost-write code overwrote the raw property BEFORE calling
  `changeEquippedWeapon`/`updateWeaponEquip`, so those calls always saw no change and silently
  did nothing — a pure reorder (calls first, property write after) fixed it. User confirmed on
  screen: sword disappears on a real throw; pickup animation also confirmed fixed as a free side
  effect of the same reorder (the throw animation specifically remains separately broken, not
  fixed — a real, distinct, not-yet-root-caused gap). **Outfit sync: also FIXED, same day,
  originally a genuinely separate investigation from the weapon bug** — despite sharing the
  "spawn-snapshot" symptom, it needed its own root cause: a live value-diff straddling real
  costume swaps found `VisualMesh.SkeletalMesh`/`SkinnedAsset` swap directly per outfit (no
  boolean flag or animBPref indirection like weapon needed). First sync attempt (a raw property
  write) produced a real negative — the ghost T-posed instead of showing the new costume, the
  mesh reference stuck but the engine never re-bound the anim instance against it. A live
  function-name dump found `SetSkeletalMeshAsset` as the one real candidate this build's
  reflection exposes; calling it before the property write (applying the weapon fix's ordering
  lesson proactively) fixed the T-pose. User confirmed on screen: ghost correctly swaps costume,
  no T-pose. A class-type safety check was also added (peer-controlled asset path, resolved via a
  type-unchecked `StaticFindObject` otherwise) as a defensive hardening pass, not itself
  live-tested. See `verified.md`'s five "Dream Breaker weapon-visibility" entries plus its two
  "Outfit/costume sync" entries, and `adapters/pseudoregalia/PLAYER_FIELDS.md` for the current
  state. **The cling-gem/glow VFX half above was then taken on the same day too — see the next
  bullet; only the empty-hand glow half survives, and with a known blocker.**
- **Ghost VFX session, 2026-08-15 (commit `4c76a8a`) — five fixes, all confirmed live by the
  user watching them on screen.** This is the session that closed the cling-gem gap logged in the
  bullet above, plus four things found along the way. Condensed here; full evidence in
  `agent_docs/verified.md`'s eight Pseudoregalia entries from that day, and a narrative version as
  build-log steps 23–28 in `adapters/pseudoregalia/README.md`.
  1. **Slide/ultra-hop trail (afterimages)** — write `afterImagesToSpawn` on the ghost, then call
     `spawnNumAfterimages` (the count write was the missing piece; the call alone did nothing).
     The trigger keys on the **capsule shrink 65→22**, not an `actionState` enum: three enum-based
     attempts were each disproven live (`as==18` also fires on a turn-around skid; `as==18 &&
     ajt==13` belongs to the skid and to the pre-backflip slide, firing zero times on a plain
     slide; and the game's own `afterImagesToSpawn` is never set during a plain slide at all, so
     mirroring it is pipeline-exact but has incomplete coverage). The shrink is a physical fact of
     the move, in a place where the enums overlap between moves.
  2. **Ghost sinking into the floor during a slide** — arithmetic, not animation: the same shrink
     drops the capsule origin 43 units (feet stay planted), so a full-height ghost teleported
     there sat 43 under the floor. Mirroring the ghost's capsule provably applied and did nothing
     (the mesh offset is fixed at construction, and the crouch logic that adjusts it never runs on
     an unpossessed ghost); fixed by compensating render Z instead.
     **Superseded 2026-08-17**: the +43 render-Z compensation was removed and replaced with the
     game's own crouch path (Timeline drive + crouch input/events + `bIsCrouched`) — see
     `adapters/pseudoregalia/BANDAGES.md` entry 1 and `adapters/pseudoregalia/README.md` steps
     43-44. The paragraph above describes what shipped on 2026-08-15, not current behaviour.
  3. **Cling-gem (wall-ride) VFX** — `moveState==4` was already the confirmed marker and already
     on the wire, so no new sync: call the pawn's own `doWallRun` on the ghost on entry,
     `Deactivate` `wallRideVFX` on the falling edge, suppress the paired SFX entirely (ghosts are
     visual-only and silent by design).
  4. **Trail colour, incl. modded colours** — `afterimageColor` read live, sent via `extras`,
     written before each burst; `FLinearColor` layout resolved by reflection, not assumed; write
     path proven with a deliberate magenta override first.
  5. **Enemy damage to a ghost hurting/killing the real player** — `bCanBeDamaged=false` was tried
     and provably did not work (this game bypasses UE's standard damage path); fixed by re-typing
     the ghost capsule's collision *object type* to `WorldDynamic`, since enemy targeting queries
     the Pawn channel. Confirmed live: no enemy damage, and the ghost shoves enemies.

  **Ghost collision is kept ON as a deliberate feature** (user decision, 2026-08-15); the
  keep-or-axe call is explicitly deferred to 7.7's real two-player session, because loopback
  cannot answer it. **Never judge collision with `LOOPBACK_GHOST_OFFSET_X = 0`** — that reproduces
  the 7.4 drag bug by construction and says nothing about real peers.

  **Negative results from the same session, recorded so they aren't re-walked**: (a) a UFunction
  hook on `Spawn After Image` — the correct event-sourced design in principle — **CRASHED this
  build** (registered fine, never fired, then fatal error); UE4SS hooks are safe here only for
  *native* functions, and this is now in `pitfalls.md`. (b) `manageRecallIdleFX` produces nothing
  on a ghost: its `IsValid` guards need a real thrown-weapon actor, which established the
  **precondition clause** — triggering the pawn's own systems only works when those systems'
  preconditions are state we can write. This is why the empty-hand glow is still open. (c) The
  ultra hop's **blue** trail does not come from `afterimageColor`, nor from `ultraCap` /
  `fullUltraModifier` / `cappedUltraModifier` / `animJumpType`; parked with evidence — don't
  resume by guessing more property names.

  **New gap found live in the same session, cause UNKNOWN**: the ghost disappears while a peer is
  climbing/on a pole, then reappears stuck in a climb pose. Two suspects ruled out with evidence —
  not the slide floor fix above (`CapsuleHalfHeight` read 65 for all 10,930 in-game ticks
  including throughout a climb, so the render-Z compensation never fires during one), and not
  purely the loopback sideways offset either (a reasonable theory, but untestable without the
  zero-offset setting that reproduces the 7.4 drag bug). Next step is 7.7's real second player,
  which sidesteps the offset entirely.

  All diagnostic flags were returned to `false` at the end of the session, and the shipped
  `main.dll` was rebuilt and redeployed from these sources.

### 2026-08-15 — Dream Breaker throw animation: root-caused and fixed (montage mirror)

The last open piece of the Dream Breaker work. Three captures, one variable each, full evidence in
`verified.md`'s "THROW animation" entry:

1. **Why five property hunts failed.** `moveState`/`actionState`/`animJumpType` are bit-identical
   through a real throw — the animation was never in the state this adapter mirrors. It's an Anim
   Montage (`dreamLady_WeaponThrow_Montage`); pickup is `dreamLady_WeaponCatch_Montage`.
2. **The game's own `CustomPlayMontage` is a negative on a ghost** — 10 calls, all `called=true`,
   montage never started (12-tick independent readback said `none` every time). Consistent with the
   ghost lacking `Controller`/`InputComponent`/`PlayerState`.
3. **Stock `Montage_Play` on the ghost's `animBPref` works** — `length=1.000`, readback confirms,
   user watched the ghost throw. Reasonable next step rather than a guess because `Montage_Stop`
   already worked on that same object.

What shipped is a **general montage mirror** (`montage` + monotonic `montage_count` extras), not a
throw special-case, so any montage-driven animation rides it. Starts are mirrored, stops are not —
the land/jump `Montage_Stop` pulse still covers the ledge-hang case and is not superseded.

**The reusable lesson, and the reason this matters beyond one animation**: when the game's own
wrapper silently no-ops on a ghost, the stock engine function underneath it may still work. That is
a second, cheaper move to try before concluding a precondition is unsatisfiable — and it is exactly
the shape `manageRecallIdleFX` (empty-hand glow) was parked on.

### 2026-08-15 — what the montage mirror unlocked, and two follow-up fixes

- **The mirror is general, confirmed**: 51 starts -> 49 ghost plays in one session, covering
  attacks, flinch, knockback, ledge grab, pole-to-perch, throw/catch and sitting, with **no new
  per-animation code**. Full 33-montage vocabulary captured via `FindAllOf`. Plunge, slide and
  wall-ride fired no montage — established as not-montage-driven by silence.
- **Ledge climb-up lingering (~1.4s): the ghost re-starts the montage itself.** Two guesses died by
  measurement first (a blend-time change: no measurable difference; "our stop call fails": disproved
  by an immediate same-tick readback showing `none`). Fixed with a peer-authoritative divergence
  correction. Confirmed live.
- **Crouch trail false positive**: crouch and slide are identical on capsule *and* `bIsCrouched`;
  only `moveState` separates them. Fixed and confirmed live on a second save.
- **Open question this raised** (see `status.md`): if the ghost re-grabs ledges on its own, the
  climbing-pole bug may be the same mechanism.
- **Reference checked, negative**: `attire-ui-overhaul`'s dash-colour feature touches only
  `afterimageColor` (name-table strings in `DashDataLib.uasset`) — no separate ultra/blue colour
  concept, so it doesn't help the parked blue-trail question. Licence posture per `licensing.md`.

## 2026-08-16 — thrown Dream Breaker, the glows, and the trail regression

A long session that shipped four features and then spent most of its length on a regression the
session itself caused. Confirmed facts are in `verified.md`; the transferable rules are in
`pitfalls.md` ("The diagnostics were the bug"). This is the narrative.

**Shipped and user-confirmed**: the thrown Dream Breaker end to end (flight, wall bounces, resting
pose, pickup, its glow ring, and confirmed un-pickupable by the local player); the empty-hand recall
glow; a use-after-free crash on level transitions after a throw.

**The blue trail, un-parked.** `status.md` had it as "not derivable from polled state; do not resume
by guessing more property names." It was resumed without guessing any: the VFX catalog turned out to
hold 58 Niagara systems and *none* is an afterimage, which meant the effect was never a particle
system and every colour guess had been aimed at the wrong kind of object. Diffing the world around a
deliberate spawn call identified `BP_AfterImage_C` + `PoseableMeshComponent`, and its own `Color`
property carries the blue. The pawn's `afterimageColor` never changing was a correct finding all
along — just about the wrong object.

**The regression.** Replacing the trail trigger introduced a per-tick enumeration, and an earlier
discovery probe was still spawning an afterimage onto the ghost every ~3s. Together they truncated
real bursts, because the game spawns afterimages as a countdown *across ticks* and the probes stalled
the game thread. The trail went intermittently sparse.

**Why it took so long.** Four rounds of measurement — count, spacing, position in X and Z, opacity
and fade, colour — all reported exact parity, because every image that survived was correct and only
the destroyed ones were missing. Each round produced a confident wrong conclusion. Worse, an A/B that
flipped the trigger flag to `false` "proved" the trigger innocent; only the counter increment inside
the scan was gated, so the expensive work kept running.

**What actually worked**, and the reason to write this down: the user asked to check out the
session-start commit and compare. That located it in three builds — `8d10f67` good, `46c4d2c` good,
`760b148` intermittent, `861e6cd` broken — after hours of inference had produced nothing but false
parity. It is the first time this project has needed a commit bisect.

**Two habits worth carrying forward from the user's side of this session**, both of which
outperformed the tooling:

- *Isolated single-action tests* (fresh session, one slide, stop) produced more signal in one run
  than several minutes-long mixed captures, because nothing accumulated to be teased apart.
- *Trusting the eyes over the metrics.* The report "the player has more afterimages" was correct and
  was contradicted by four instruments for several rounds. The instruments were measuring their own
  blind spot.

The blue remained switched off at the end of that session, since the code reading it rode on the
scan that caused the regression.

## Superseded 2026-08-16 — the blue landed

The paragraph above was this file's last word for one day. It is no longer true, and this section
exists so a reader reaching the end doesn't stop on a stale conclusion.

The ultra hop's blue trail is **on and confirmed on screen** (`AFTERIMAGE_OBSERVE_COLOR = true`,
`Plugin.cpp:4231`; user's own verdict, *"looks perfect now"*, in `verified.md`). It took five more
rounds, each fixing a real bug that exposed the next: the colour was read then thrown away, then
arrived a whole slide late, then bled into the following slide, then the ghost drew two blue images
where the game drew one.

The trigger changed with it, and that is the more transferable half. The trail no longer fires on a
reconstructed rule at all — not the `actionState` enums (three of them, each disproven live), and
not the capsule-shrink physical fact that replaced them. It fires on **the game's own afterimage
spawns**, observed (`AFTERIMAGE_TRIGGER_FROM_OBSERVATION = true`, `Plugin.cpp:4310`), with a
birth-proximity check so a recycled pooled actor isn't counted as a new one. That also closed a
complaint nothing was aimed at — the ghost had been drawing 1-2 more afterimages than the player —
and fixed the ghost trailing on mistimed moves where the real player doesn't.

Full narrative, and the method extracted from it: `agent_docs/effect-investigation.md`. Build-log
form: `adapters/pseudoregalia/README.md` steps 36-41.

## Pseudoregalia work after this file's last entry (pointer, added 2026-08-17)

This file's narrative stops at the blue trail, and its task list stops at 7.8. Later Pseudoregalia
work is real but recorded elsewhere, so a reader reaching the end doesn't take that as "nothing
since". **Nothing after this file has a phase sub-number** — there is no 7.9.

- **To 2026-08-17**: autostart (the mod starts the client itself, Windows and Proton), the ghost's
  camera rig identified by `OwningActor`, ghosts no longer rendering through walls, the bridge port
  walk, and the slide pose moving from the +43 render-Z bandage to the game's own crouch path.
  Build-log form: `adapters/pseudoregalia/README.md` steps 42-44.
- **2026-08-27**: nine confirmed entries ending in the user declaring the adapter **feature
  complete** — the duplicate HUD, the blob shadow, heal placement, the ghost-damages-player fix,
  autostart's closed-port bug, the charge glow, the ranged projectile, death/pit/hurt/respawn, and
  the afterimage outline. README steps 45-53.

Evidence for both: **`adapters/pseudoregalia/VERIFIED.md`** — the adapter ledgers were split out of
`agent_docs/verified.md` on 2026-08-25, and that file now keeps only the Go side and cross-game
entries. What is still open: `adapters/pseudoregalia/UNVERIFIED.md`, then `agent_docs/status.md`.

## Catch-up record, written 2026-09-01 — the five days after "feature complete"

"Feature complete" is the user's term for "playable / good-enough state", not "no further work"
(their clarification, 2026-09-01) — and true to that, 2026-08-28 → 2026-09-01 became the
adapter's busiest stretch while this file recorded none of it. Backfilled from the commit log;
the dated evidence for every item
is in `adapters/pseudoregalia/VERIFIED.md` (entries through 2026-09-01), `UNVERIFIED.md`,
`agent_docs/pitfalls/by-lesson.md`, and the ADRs named below.

- **2026-08-28 — nametags.** The peer's `display_name` reaches a ghost as a
  `UTextRenderComponent` (`f9b51a2`, `91bb841`, `1246432`, `3698d4d`), after finding the adapter
  had been dropping handshake messages and throwing every rejection away — three stacked bugs
  (`02cdfc5`, `243b8e9`, `c8cb15a`, `6bec7d4`). The bridge port became a config setting the same
  day.
- **2026-08-29 — the colour plate, and the light hunt.** `name_color` renders as an opaque plate
  behind the glyphs (`634afc2`, `ed4d4b6`), confirmed by three peers at once (`0e9dd97`); blank
  name means no tag (`ac2d5d6`). Then the whole glow/light subtraction night (`9c05a41` through
  `ca95ab8`): the room brightening with company was never a copied light — every spawned pawn
  carries the Blueprint's default 5000-intensity light the game only turns down on a real
  player, plus a camera rig nobody looks through. Probe cost the user could feel became a gate
  the same evening (`40922c3`, `924da4e`, `3cbecc5`, `e648a0e`).
- **2026-08-30 — the light fixes ship; the orientation bracket; the perf finding.** Three light
  holds shipped as defaults and the connect-time scene latch closed via the level's own
  `FixAllLights` (`f9ef404`, `e339796`, `f4d444f`). **ADR 0043**: the core hands the adapter its
  orientation bracket and the adapter slerps facing (`1c960dd`, `133223f`, `b74a1d1` — the
  adapter half is `GHOST_ROTATION_SLERP`, still unwatched). And a ghost was measured costing
  half the frame rate with none of it rendering (`7d13660`, `0457a84`).
- **2026-08-30 → 08-31 — the reset-crash hunt.** A pawn spawned into a world made by "reset to
  last save" killed the game. The minidump reader (`dev-scripts/read-minidump.py`), the
  world-fingerprint probe (`probe_menuwatch/`), the race pinned, the zone-change crash fixed,
  and hot reload promoted to a standing rule (`b96596c` … `1aa0222`).
- **2026-09-01 — root cause, the peer ladder, and the sword-throw day.** The reset crash
  root-caused to stale nametag pointers and user-confirmed fixed (`02c7f8a`, `7e0f722`); the
  FWeakObjectPtr pool rule plus its preflight gate followed (`cfb201b`, `b2f4508`). The peer
  ladder ran 150 live ghosts, ~30 above 50fps, removing three ceilings (`c6d937d` and kin;
  property cache −59% at 16 peers) — the program that fed the project-wide 15Hz default
  (`c16441f`) and the blind 15-vs-20 A/B (`956790c`). The thrown sword was rebuilt as our own
  flyer after the game's class claimed the watcher's player (`ead064e` … `b2f4508`), and the
  peer-named-asset catalog gate closed the last unbounded lookups (`0ee2a63`).

- **2026-09-01, later — the register audit's follow-through, on the user's call.**
  `PLAYER_STATE_DIFF_ON_GHOST_SPAWN` flipped off (its reset-crash question is closed; it was a
  diagnostic shipping `true` against its own comment), `GHOST_CUSTOM_DEPTH_DEV_TOGGLE` kept
  `true` with its comment corrected — it had quietly become the master gate for the whole
  file-toggle dev workflow — and `probe_swordthrow/` disarmed (`enabled.txt` parked as `.off`;
  its day is closed) along with `probe_slashvfx/` (the user confirmed the melee slash/arc VFX
  fixed — it ships as the `NS_PlayerSlash` row in `MIRRORED_EFFECTS`). DLL rebuilt and deployed
  to both installs.

Open items from this stretch live in `adapters/pseudoregalia/UNVERIFIED.md` and
`agent_docs/status.md`; the crowd plan is `agent_docs/crowd-limits.md`.

## 2026-09-02 — the documentation pass, as it touched Pseudoregalia's files

No adapter code changed. The repo-wide pass (`agent_docs/doc-history.md`, 2026-09-02) reworked the
documentation mechanisms; this is what it did to this adapter's files, logged here because a phase file
is the complete running log and preflight now fails one that falls behind its adapter.

- `UNVERIFIED.md`: every entry tagged READY/OPEN/DONE (11/14/7), a "This run" block added, and the four two-machine items from `status.md` (collision as a setting, 0-health after killing a ghost, the pole vanish, the sword near a save crystal) filed as one OPEN entry.
- `FLAGS.md`: 19 dev traces the register had never heard of (`*_TRACE`, `*_CENSUS`, the dumps), found by the new preflight completeness check, listed with a pointer to their code comment.
- `CLAUDE.md` (Unreal host rules) trimmed for the 700-line stack budget and pointed at `agent_docs/checklists/before-spawning-in-unreal.md`; preflight now ratchets the bitfield-bool read.
- `PROBES.md` link fixes for the rename.

## 2026-09-02 (late) — pointer: Pseudoregalia's night is logged in phase9

The full session is [phase9.md](phase9.md), "2026-09-02 (late)". What touched this adapter: the launcher
rule mirrored from TEVI into `CoreLauncher.cpp` and reproduced here with both installs on one port base
(`e3c11dc`), then revised with the bridge sweep waiting on its own child and forgetting it only on busy
(`9b79429`); the custom port bases 6700/6800 removed from both installs, back to the shipped 7778; the
interp ladder on the fixed relay (300ms on the milder proxy, `d2b6496`) and on the worst-case proxy
(450ms, `1164853`, `pseudoregalia/VERIFIED.md`); 450ms shipped for every game (ADR 0046, `0cd52a9`).

## 2026-09-03 — `"autostart"` moves into config.json (Pseudoregalia)

The user's ask, the morning after the config restructure: the "don't start a client" switch was an
environment variable, and *"even me that is somewhat tech savvy, has no clue what 'an environment
variable' means"*. All four launchers now read `"autostart"` from the config.json the client will read,
the variable still counts, the READMEs are rewritten around the key. Built and deployed, unwatched
(`UNVERIFIED.md`). The user's follow-on thought -- game-specific settings in the same file instead of
in-game menus -- is filed in `ideas.md`.


## 2026-09-04 — Two adapter defects found by playing, logged in Phase 11

Three commits touched `adapters/pseudoregalia/` on 2026-09-04 and none of them is Phase 7 work.
Both came out of a Phase 11 session (replays and the chaser) with the user playing:

- **`json_string_field` did not decode JSON escapes**, so a display name containing a quote was
  truncated at the backslash on a ghost's nametag, and `\uXXXX` came back as its own text. It reads
  every string field this adapter takes off the wire, so the blast radius was wider than nametags.
- **The title screen reported a player at [0,0,0]**, because it is a real level with a real pawn and
  the existing "no pawn, send null" branch never fired. Every `record_on_launch` clip opened with
  dead frames.

Both are READY in `../../adapters/pseudoregalia/UNVERIFIED.md`; the full account, including the
third finding (the player's own SFX going quiet while ghosts are audible, logged and not chased) is
in [phase11.md](phase11.md), 2026-09-04. Noted here so this file's gap is a decision rather than a
lapse.

## 2026-09-04 (later) — an instrument for the SFX report, and one run that answers two queue items

Picking up two of the three things `status.md` had waiting on the user's eyes: the player's own SFX
going quiet near a ghost (OPEN, reported 2026-09-03, never measured) and the title-screen gate
(READY, built the same night, never watched).

**The SFX report got an instrument rather than a guess.** `probe_audiocensus/` logs every
`AudioComponent` appearing, starting and stopping, attributed to the player or to a ghost by name
containment (the outer walk missed 12 of 12 on a ghost in 2026-08-29's census), and dumps each
distinct cue's own concurrency settings the first time it is seen. That dump is the half that
decides the second of the two shapes on its own: if a cue the ghost plays caps its instances and
resolves by stopping the oldest, the mechanism for "the ghost spends the player's voices" is
present, and no ear has to adjudicate it. Named property reads inside `pcall` only, two classes at
5Hz, a coverage line every 10s carrying the pawn list and how the player/ghost split was decided —
the `probe_slashvfx/` shape, which has run through live sessions without incident.

**What it cannot see is in its header and matters here:** a sound started by
`PlaySoundAtLocation`/`PlaySound2D` creates no component at all, which is the usual shape of an
anim-notify footstep, and concurrency is resolved on the audio device's active-sound list rather
than on the component — so a quiet log is not an acquittal and an active component is not proof
the player was audible. If the run comes back clean the subsystem widens rather than the
measurement deepening (`../../CLAUDE.md`).

**The A/B is built into the session so there is no window to hit.** The chaser is configured to
60s: the first minute of play has no ghost, the second has one repeating the same actions in the
same place, and the probe marks the boundary itself with a `GHOSTCOUNT 0 -> 1` line. The same
launch carries `record_on_launch: true`, which is the title-screen gate's own test — sit in the
main menu first, and the recording should still open on the first real frame.

**Deployed to both installs**, hash-verified: the Copy's `main.dll` was stale (it had never
received the 2026-09-04 build) and every `meshghost.exe` under both `Mods/` trees was behind the
current Go build. Each install's `config.json` was overwritten with the shipped one per the
standing rule, with a `.pre-2026-09-04` backup — that reset the Steam install's display name, which
was still the quoted string from the JSON-escape test, and its chaser label.

Nothing is watched yet; both entries stay where they are in `../../adapters/pseudoregalia/UNVERIFIED.md`.

## 2026-09-04 (evening) — the SFX fault reproduced, and it is not what either of us thought

The run set up earlier that day did its job in about twenty minutes, and the diagnosis turned over
twice. Both turns came from the user narrowing the trigger, not from a new instrument:

1. *"I lost the player sfx after moving to another zone"* — a zone change.
2. *"moving back and forth between the zones fixed it"* — recoverable, so not a teardown.
3. *"both the player & ghost had sounds while it was spawned, but the sfx went away once the ghost
   despawned"* — **the zone held constant, and the trigger isolated: ghost presence.**

**The measurement that decided the shape:** the player's own footstep, land and jump components are
still created and still go active during the silence. The game plays them; they are inaudible. That
kills the whole "a missed silence clause" and "the ghost steals voices" pair the entry had been
carrying since 2026-09-03 — nothing is being suppressed and nothing is being stolen. Music, which is
a different sound class, is unaffected throughout.

**Ruled out by measurement rather than by argument, which is the point of writing them down:** a
second local player (one `MainPlayerController_C`, driving the player's pawn, unchanged across a
whole spawn/despawn cycle), and a wandering view target (the same `BP_PlayerCam_C`, tracking the
player, correct across the 12:09 zone change — the "stale rig from the zone you just left" theory
this session started with is dead).

**Where it stands:** this game splits its audio into `SoundClass_SFX`, `SoundClass_Music`,
`SoundClass_UI` and `Master`, which is exactly how the symptom splits, and a ghost is a clone of the
player pawn — so its BeginPlay/EndPlay runs the game's own pawn audio setup and teardown against the
single global audio device. A mix pushed on spawn and popped on despawn fits every observation. The
probe now hooks the six sound-mix statics that could do it (`StopAllSounds` is not on this build), so
the next despawn either names the call or removes the hypothesis.

**Two instrument failures worth more than the fault, both filed in `checklists/`:** the probe's pawn
discriminator asked each pawn for a Controller and called a possessed one the player — **every ghost
here reads as possessed**, so every ghost's audio was labelled as the player's, and only the coverage
line printing its own evidence made that visible. And a `string.format` on a value that was not a
vector threw out of the sample loop, which stopped the probe for four minutes while the log read
exactly like a quiet game. Both fixed in place by hot reload, no relaunch.

**Second finding, the user's call:** a ghost is audible at all, which the project decided against on
2026-08-15 and never implemented past one component. Ghost audio ships OFF, with a setting to turn it
on. Queued, not started — `../../adapters/pseudoregalia/UNVERIFIED.md`.

## 2026-09-04 (later still) — CAUSE FOUND: every ghost steals the player's audio attenuation listener

Two hooked calls, two ghost spawns, ~0.1s before each `GHOSTCOUNT 0 -> 1`:

```
LISTENERCALL SetAudioListenerAttenuationOverride
  arg1=CapsuleComponent ...PersistentLevel.BP_PlayerGoatMain_C_<ghost>.CollisionCylinder
```

`BP_PlayerGoatMain_C` pins the player controller's audio ATTENUATION listener to its own collision
capsule when it begins play — confirmed for the player's own pawn too, on the 12:39 zone entry — and
a ghost is a clone of that pawn, so **every ghost takes the listener with it.** While the ghost
lives it stands near the player and everything sounds normal; the instant it is destroyed the
override names a component that no longer exists and every SPATIALIZED sound attenuates to nothing.
Music is 2D and never consults attenuation, which is why it survives, and why the silence is total
rather than faint. The next ghost re-points it, which is the "it comes back when the chaser spawns".

**This is the loose-sword class, second instance** (`VERIFIED.md` 2026-09-01): a singleplayer game's
own code claims *the* player, and a ghost is a real player pawn, so it claims it too. The rule was
already in `adapters/CLAUDE.md`; this is the first time it bit outside gameplay state.

**Everything else was eliminated by measurement first**, and the order is the useful part: the
silence clause and voice-stealing (the player's components are still created and go active during
the silence — the sounds play and are inaudible), a second local player (one controller throughout),
a wandering camera (same view target, tracking the player, correct across the transition), sound
mixes (a spawn re-applies `MySoundMix` with **SFX at 1.0**, a despawn calls nothing, `Duration=-1`),
and the class volumes (never change). Six hypotheses, five dead, and the survivor named itself.

**The fix is under test in Lua before it is built**, per the user: *"try with lua first, so we
actually test the fix before making it"*. `probe_audiofix/` re-points the listener at the player's
own capsule whenever a ghost appears — the same call that belongs in the C++ ghost-decouple pass
beside the HUD ref, game-instance ref and damage clears. **A new mod folder cannot be hot-loaded**
(UE4SS reads folders at launch), so the test hosted that code temporarily inside the census probe,
which was already loaded; the folder itself arms on the next launch. Verdict pending.

## 2026-09-04 (evening) — the SFX fix CONFIRMED in Lua, then built as production C++

The user, after testing both cases across a full session: *"yee both the spawn/despawn & zone
transition sfx things are fixed now"*. The cause and the fix are in `pseudoregalia/VERIFIED.md`;
what belongs here is how the last two rounds went, because both were about TIMING rather than about
the fix.

**Round one failed on a race, and the log said so rather than the ear:** the Lua correction ran on
the 5Hz poll, and at a zone change it landed 6ms BEFORE a ghost's own BeginPlay took the listener
again. **Round two failed on hook ORDER** -- the correction sat in the PRE callback, where it is
applied and then overwritten by the engine's own call. That is exactly why the user saw *"works
sometimes"* on a despawn and never on a crossing: the poll behind it was the only thing healing
anything, and on a crossing the poll had already spent its one shot on that ghost's arrival before
the steal happened. Moving it to the POST callback made both cases deterministic, and that is the
version the user confirmed.

**The shipped C++ does neither.** `register_audio_listener_guard` REWRITES the first argument of
`SetAudioListenerAttenuationOverride` in a pre-hook, the same shape as the PlayerLocation guard and
the camera fight-back: the engine's own call uses the corrected component, so there is no second
call and no ordering to get wrong. It needs no ghost attribution either -- any call naming a
component that is not the driving pawn's own is pointed back at the driving pawn, and a transition
window with no acknowledged pawn passes through untouched rather than pinning the listener to a
pawn that has just been destroyed. Built and deployed to both installs; **unwatched**, because a
different implementation is a different thing to watch.

**Housekeeping the same pass:** the census probe hosted the Lua fix for the session (a new mod
folder cannot be hot-loaded) and has been returned to read-only; `probe_audiofix/` keeps the proven
Lua version as the record of how it was established.

## 2026-09-04 (later) — the fourth adapter fuzzer, and it broke an assumption this file had trusted

**The job:** Pseudoregalia was the one adapter with no hostile-input harness (`ideas.md`,
"Adapter-side fuzzers"). The Lua and TEVI ones were built 2026-09-03; this is the third of three,
plus an audit of the other three against the user's actual goal — *"make sure only valid
values/names/inputs can be used"*.

**The refactor first.** `json_string_field`, `json_vec3_field`, `json_number_field`, `json_escape`,
`json_hex4`, `append_utf8` and `clamp_to_uint8` moved verbatim from `Plugin.cpp`'s anonymous
namespace into `Mod/src/PeerJson.hpp`. They need `<string> <cstdio> <cmath> <cstdint>` and nothing
else, so a **Linux** runner compiles them — the original idea entry assumed Windows and was wrong.
`to_utf8` and `to_wide_ascii` stayed behind; either one would have made the header un-compilable
off Windows and retired the whole exercise.

**ASSUMPTION 1 IS BROKEN, and it had been stated three times in the source.**
`json_number_field`'s comment argued a whole-string needle search is safe against a hostile peer
because peer STRINGS are escaped, so one can never contain a bare `"h_speed":`. True about strings,
and not the whole wire. Measured against the real field order of `protocol.State`
(`player_id, seq, timestamp, area_id, position, orientation, anim, extras, prev` — `encoding/json`
emits struct fields in declaration order):

- **`orientation` is `json.RawMessage`** — raw, UNESCAPED JSON, bounded only by bytes and depth —
  and it marshals **before** `anim` and `extras`. `"orientation":{"h_speed":1e999}` returned `+inf`
  where the real value was `1.0`. A shadow and a non-finite value at once, through a field `extras`
  validation never sees. The escaping argument never covered it, because orientation is not a string.
- **`extras` is `omitempty`**, so a sample with none of its own but carrying a `prev` that has them
  left exactly one match and it was prev's — a stale value mirrored as current.
- **`encoding/json` sorts MAP keys**, so `extras:{"aaa":{"h_speed":9999},"h_speed":1}` puts a nested
  needle first, at depth 2, well inside `MaxJSONDepth = 32`.

Three other corners are SAFE and are now asserted rather than assumed, so a reorder of
`protocol.State` fails in CI instead of on someone's screen: an escaped needle inside a peer string,
prefix collisions (`anim_h_speed` vs `h_speed` — the trailing colon is what saves it), and an extras
key named after a real top-level field.

**The fix is scoped reading, not a parser.** `json_member_value` / `json_object_member` /
`json_string_member` / `json_number_member` / `json_vec3_member` read a named member of a named
object at *its own* top level, tracking nesting depth and string state — which is precisely what
"first match wins" lacked. `handle_bridge_line` resolves root → payload → state → extras once and
reads members of those spans: 4 payload, 2 state, 36 extras, plus 4 in the name/despawn branches.
The unscoped readers are kept and still correct for the envelope, where one object exists and
nothing peer-controlled can precede a real key.

**ASSUMPTION 2 was half right.** `clamp_to_uint8` is sound; the gap was that narrowings never called
it. The audit said nine; the fuzzer's inventory found a **tenth** (`target_move_state`, wallrun).
All ten now route through `clamp_to_uint8` / `clamp_to_float` / `clamp_count_to_int`, three bounds
that live beside it in the header and are fuzzed there. **`isfinite` is not a sufficient guard in
front of a float cast** and that widened the finding: `1e300` is a finite double that is not
representable as `float`, so that cast is UB exactly as NaN is — which is why `clamp_to_float`
bounds MAGNITUDE rather than merely checking finiteness.

**Three more bounds from the same run:** `position` now gets an adapter-side finiteness check (it
had none, and rode entirely on whichever core it was paired with — `protocol.IsValidPosition` is
real but an adapter that is only safe next to a correct core is not safe); `json_number_member`
refuses any value not starting with a digit or a sign-then-digit, so `nan`/`inf`/`0x1p999` cannot
enter through that door at all (glibc's `sscanf` accepts 34 of 39 raw forms, JSON emits far fewer);
and the `vfx` `:count` suffix is length-bounded, because a digits-only filter admitted a 400-digit
run that `strtod` turned into `+inf` and that then latched its key off permanently.

**The harness caught a bug in its own fix, which is the argument for writing it first.** The first
version of `json_number_member` tested "digit or minus" — and `-inf` starts with a minus. It now
requires a digit *after* the sign.

**Mod compatibility is asserted, not hoped for.** The user's rule, same day: a modded outfit or a
modded weapon must still work if the watcher has that mod locally. `resolve_peer_named_asset`
already gets this right — a peer's name is a key into a catalog of the LOCAL game's own loaded
assets, so anything a watcher could render, it renders. At the parser layer the property is that an
asset path survives byte-for-byte, modded paths with spaces, `#` and non-ASCII included, because a
mangled path is a mod that silently stops working. That is a test now, and the header says the
catalog must never narrow to a vanilla allowlist.

**CI, and the per-adapter scoping the user asked for.** `pseudoregalia.yml` is path-filtered to
`adapters/pseudoregalia/**`, builds `-fsanitize=address,undefined` with
**`-fno-sanitize-recover=all`** (UBSan's default is print-and-continue, which would leave a real
finding in a log behind a green tick) at `-std=c++23`, because that is what RE-UE4SS sets and
checking code under a different standard answers a different question. The emulator fuzz job MOVED
out of `lua.yml` into `emulator.yml`: `**.lua` matches 22 Pseudoregalia probes and ~28 dev-scripts,
so **editing a Pseudoregalia probe was running the Pokemon decoder fuzzers**. `lua.yml` keeps the
syntax gate, which is correctly repo-wide because it is a LANGUAGE gate, not an adapter one.

**The registration trap was paid in advance and then tested.** `PeerJson.hpp` went into
`release.yml`'s `$files` and `build-pseudoregalia.bat`'s hash set in the same commit as the file
itself — and the gate was verified by corrupting the hash and watching it name the file, rather
than by assuming. `preflight.ps1` needed no edit: its `Check-BuiltFrom` iterates `built-from.txt`'s
own lines. Two registrations, not three.

**What is NOT established:** that the rebuilt DLL still behaves correctly in the game. The
extraction was verbatim and the scoped reads are covered by the harness, but 42 call sites changed
shape and no one has watched a ghost since. Queued in `UNVERIFIED.md`.

## 2026-09-04 (later still) — the corpus across all four, and an audit that had to be corrected

**Part C of the same job:** one adversarial corpus, seven categories, defined once in
`_template/README.md` and implemented in each harness's own language. Categories 1 (wrong type for
every field) and 2 (extreme numerics) landed everywhere first, because that is where the known
defects were. Lua went 726 -> 796 decodes, TEVI 90 -> 155 lines.

**What it measured, and both numbers are worth keeping.** Both Lua decoders accept exactly three of
eighteen extreme forms as NON-FINITE — `1e309`, `1e999`, `-1e999`. Those are valid JSON, the relay
forwards them untouched, and the decoder is right to hand them over: a peer reaches infinity without
ever writing `inf`. TEVI fed 22 forms including the `"NaN"` and `"Infinity"` STRINGS that
Newtonsoft casts without throwing, and **zero reached a callback non-finite** — `FiniteOrNull` holds,
and is now asserted rather than assumed.

**THE AUDIT THAT SCOPED THIS WAS WRONG, and the correction is the more durable finding.** A
subagent's audit reported Emerald as leaving 13 extras fields unbounded and Crystal six, calling
Emerald "the largest gap of the four". Traced field by field to where each value actually means
something, **every one is bounded**: Emerald checks each on the very next line (`sanim`/`sidx`/`act`
0-255, `sox`/`soy` ±32, `pspeed` 0-4, `boat` 0-255, `fly` ∈ {1,2}, `flyk` 0-0xFF), coerces
`spaused`/`noanim`/`invis` with `~= 0`, and bounds `gfx` inside `graphicsInfo` — integer, 0-255,
every ROM pointer validated before the engine dereferences it. Crystal passes `act` through the
`ACTIONS.peer` allowlist, `face` through `pose()` (range tests and `& 3` masks, never an index),
`fly` through `iconGfx` (species 1-251), `emote` through `emoteGfx` (0-11); `entry` is an equality
test and `prog` is overwritten by a locally computed value on the path that moves.

**So the clamps this was scoped to add would have been churn with regression risk against the 1:1
bar, on code that was already right.** `security-design.md`'s claim that Crystal validates
`prog`/`face` "not at all" is struck and corrected in place. The method lesson, written where the
next audit will read it: **ask where the value ENDS UP, never whether there is a check on the line
that reads it.** A `tonumber` with a bound three lines later is bounded; a beautifully checked read
whose value then indexes a table is not.

**One real defect did come out of the same pass, and the fuzzer found it rather than a person
looking at a nametag.** `json_string_field` has decoded multi-byte UTF-8 correctly since
2026-09-03, so a display name arrives as real UTF-8 bytes — and `to_wide_ascii` widened each BYTE
separately, so any non-ASCII name rendered as mojibake. The core had sanitised it correctly and the
adapter drew the right bytes wrongly. `utf8_to_wide` (the inverse of the `to_utf8` already here)
now covers all five name render and log sites. `to_wide_ascii` was never the bug: its comment
scopes it to core-stamped ASCII ids and it is correct for those; a NAME is user-typed free text and
was routed through the function built for ids.

**Also this pass:** `preflight.ps1` gained an adapter-workflow check — every adapter must be covered
by a path-filtered gate, and no adapter gate may filter broader than its own tree. Both directions
were verified by making them fail. The rule and the seven-category corpus are both in
`_template/README.md`, and `/new-adapter` points at the workflow rule while CI is being wired.

**Still open, named rather than dropped:** corpus categories 3-7 on the three older harnesses.

## 2026-09-04 (evening) — two replay faults reported, both traced by reading, neither fixed

Both came from playing rather than from testing, and in both the user's first guess pointed at the
render while the reading points upstream. Neither is reproduced or measured by the agent; both are
OPEN in `UNVERIFIED.md`.

**1. Dust VFX in wrong places after a replay ghost restarts or loops.** A tester added the half that
named the cause: *"seems to be somewhat related to the height of ghost sybil when it despawns"*.
`observed_world_offset_z[]` is LEARNED at runtime from the local player's own effect, is file-scope
rather than per-peer by design, and is never reset. The detection pass excludes components we
spawned on a ghost — but the exclusion set is built by walking `remotes`, so it only covers ghosts
that still EXIST, while a fire-and-forget burst outlives the tick that spawned it. On a despawn the
entry is erased and its still-live dust falls outside the exclusion, so `dz` can be measured from
the player to a GHOST's dust and written into a value every later burst uses.

**And it is not only loop/restart.** Asked whether backward/forward hit it too, the core says yes by
the identical path: `replayPlayer.seam` is drop → wait a render tick → re-admit, and it has four
callers — every seek, the loop, **a recorded gap longer than `replayGapSeamMs`**, and a clock
step-back. The third fires during ordinary playback with nobody touching a key, which makes this
much more reachable than the report suggested.

The user's instinct — reset the ghost wherever it jumps — is right and **fixes exactly half**:
per-ghost state (`vfx_counts`, the `last_seen_*` counters) should reset on release, but the
exclusion list and the observed offset are NOT per-ghost, and erasing the entry is precisely what
causes the leak. Both, or neither.

**2. A replay ghost wears the Dream Breaker from a clip recorded before the pickup.** User-confirmed
scenario, so it is a straight bug rather than faithful playback. **The show/hide path is ruled out by
reading**: the apply gate is `!weapon_equip_call_armed || target != last_synced` with `armed`
starting false, so the first tick always applies; `WEAPON_SYNC_INVERT` is off; an absent field parses
to 0. The suspect is the SEND side — `PLAYER_FIELDS.md:264` already records that `weaponEquipped?`
means the sword is IN HAND rather than owned, and nothing here establishes what it reads before the
pickup. If it is true then, the recording faithfully carries the wrong value, and the receive side
does not merely write a property — it CALLS `changeEquippedWeapon`, the game's own pickup path, on
the ghost. That would explain why the player and their own ghost disagree: one had a function called
on it.

**A DESIGN RULE CAME OUT OF THE SECOND ONE and is now in `_template/README.md`.** The user:
*"recordings should be identical to when they were recorded. the state of the current player is
irrelevant to that"*. So a replay is never filtered through the watcher's progression, no toggle for
it, and the same answer covers `outfit_mesh` and every field added later. The consequence worth
having in writing: **if a replay shows something it should not, the fault is in what was RECORDED,
never in what playback chose to show** — which also rules out the tempting fix here (hide the sword
when the watcher has none), since that would have concealed the real defect.

**Method note for both:** the useful move each time was to read the code for what it ACTUALLY does
and report what that rules OUT, rather than to accept the reported location. Two guesses at the
render, two causes upstream.

## 2026-09-04 (night) — a live pickup run: three defects measured, and two of my own theories killed

**The user ran it; I only read.** A new save, walked to the Dream Breaker, held the pickup popup open
deliberately so it could be sampled, then threw and re-caught the sword. `probe_pickup/` (written
this session, named reads only) logged on change at 10Hz throughout. All three findings are in
`pseudoregalia/UNVERIFIED.md`; none is fixed.

**1. The sword is `WeaponMesh.bVisible`, and only TRANSITIONS are applied.** A census of BOTH pawns
side by side settled it in one line: ghost `WeaponMesh.bVisible = true` while the player's is
`false`, with `weaponEquipped?`, `animEquippedWeapon` and `weaponRef` identical and correct on both.
The ghost's class defaults disagree with each other — flag false, mesh visible — and
`changeEquippedWeapon` early-outs when handed a value the ghost already holds, so a clip in which the
peer never held the sword never produces an edge and the default-visible mesh is never touched.

**TWO OF MY THEORIES DIED HERE, and how they died is the lesson.** First: *"`weaponEquipped?` reads
true before the pickup, so we send a wrong value"* — measured false on the fresh save, and the
recorded ndjson carries `weapon_equipped:0`, so the send side and the clip were both right all along.
Second: *"the ghost always shows a sword, so a thrown-sword clip would show two"* — the user
contradicted it within the hour with a clip recorded while the sword was thrown, which showed no
sword at all. **That contradiction is what produced the correct rule**; the model only became right
once a prediction failed. The general form: the answer came from reading TWO pawns and diffing them,
where every wrong theory came from reasoning about one field.

**2. World-spawned VFX are UNOWNED.** `spawn_niagara_at_location` calls
`NiagaraFunctionLibrary::SpawnSystemAtLocation`, which is free-standing and world-space — the
`world_context` argument is a world handle, not a parent. So `Plugin.cpp:10683`'s comment
(*"attached to the flyer; dies with the ghost"*) is false, and the release path drops the only handle
to a live ring. The user saw it directly: *"i picked up the sword now, but i still see the sword
ground vfx"*. **This unifies three separate reports** — the left-behind glow, the stranded dust, and
the poisoned `observed_world_offset_z` (which is learned at runtime, file-scope, and never reset) are
one defect, and a replay makes it constant because `seam` despawns the ghost on every seek, loop and
recorded gap.

**3. The item-pickup popup freezes the pawn but not what we send.** 1081 samples — about 110 seconds
— byte-identical at `loc=-3527,4898,147 h=550.0 v=-290.6 move=1`, i.e. full running speed and falling,
held for the whole modal. So we transmit "static position, running, falling" and a ghost run-falls on
the spot for as long as the player reads the popup. Nothing we sample marks the state:
`moveState` 1, `actionState` 0, `MovementMode` 3 throughout. Both obvious fixes fail the
recording-fidelity rule (see `_template/README.md`) — the faithful result is a ghost frozen in the
same mid-fall pose, which means pausing its ANIMATION, a lever nothing currently syncs.

**A defect in my own instrument, found by using it.** `on_change` stayed silent on a key's first
sighting so the baseline census could print it — which meant a ghost spawning LATER had its entire
starting state swallowed, and the log had nothing to say about the one thing being measured. Fixed
mid-session and hot-reloaded (the reloader worked; sample counter reset to 1). **An instrument that
hides first sightings cannot answer a question about how something STARTS**, which was the question.

**Rig state at the end:** relay stopped, `record_on_launch` restored to the shipped `false`, probe
disarmed in the install. Clips from the run are kept in the install's `replay/` folder — the
pre-pickup one (`rec-20260904-165557.ndjson`, 4515 samples) is the reproduction for the sword bug.

## 2026-09-04 (later) — two of the three replay defects fixed in one rebuild, plus the instrument for the third

**Fixed from reading, off the previous entry's measurements; nothing here is watched yet.** Both
sit in `pseudoregalia/UNVERIFIED.md` as READY with what to look at.

**1. The sword.** A new mirror writes `WeaponMesh.bVisible` from `target_weapon_equipped` beside the
blob-shadow one — a component write on our own actor, so it cannot depend on an edge the way
`changeEquippedWeapon` does. **The part that would have wasted a live cycle was found by reading, not
by watching:** the ghost mesh loop re-asserts `WeaponMesh` visible every tick unless something claims
it, so it had to learn the same signal or it would have undone the mirror one tick later and the fix
would have read as "no change". The "two writers on one field" rule again, this time caught before
it cost a live cycle.

**2. The stranded VFX.** `release_ghost` destroys everything world-spawned that the entry holds
before dropping the handles. The design question was the one-shot ring: those pointers legitimately
go stale (a burst destroys itself and nothing tells us), which is fine for the identity comparison
they exist for and fatal for a `ProcessEvent`. So the release path takes one
`FindAllOf("NiagaraComponent")` and touches only what the engine still lists — the same "membership
proves allocation" move the redraw loop's `IsUnreachable` comment argues for, at per-event cadence.
Preflight's FindAllOf ratchet caught the new site immediately and made the cadence be named at it,
which is the check working exactly as designed.

**3. The offset poisoning is still unmeasured, but now instrumented.** `VFXOFFSET` logs every real
change to `observed_world_offset_z` with the component it was measured from and both Z values.
Naming the component is the whole point: a stranded ghost effect mistaken for the player's own is the
theory, and a bare "the value changed" line could not tell that from an ordinary re-observation.

**Not touched: the frozen-player state.** It needs a signal nothing currently samples, and its chaser
half has to reach the core, so it wants an ADR rather than a rebuild. It still blocks
`chaser_contact`.

**Rig state:** DLL rebuilt and deployed to both installs, `meshghost.exe` rebuilt and deployed to all
four copies under `Mods\`, preflight clean, no processes left running.

## 2026-09-04 (evening) — a live session: four confirmations, one self-inflicted regression, and three findings nobody was looking for

**The user played; I ran the rig.** Two of the morning's fixes were confirmed on screen, a
regression I had shipped earlier the same day was caught by them on sight, and the instruments added
along the way produced more than the fixes did.

**CONFIRMED (`VERIFIED.md`):** a clip recorded before the Dream Breaker pickup renders a ghost with
no sword; one recorded after it still renders the sword (the control, without which the first result
means nothing); a despawning ghost takes its landed sword and ground ring with it; and the same
mirror holds for LIVE PEERS with the watcher owning no sword, then owning one. That last pair used
two synthetic peers over the relay rather than replays — a genuinely different door, since a replay
only reaches the adapter as a local fake peer.

**THE REGRESSION, AND HOW IT WAS FOUND, because that is the reusable part.** Showing a ghost's
`WeaponMesh` lit the ascendant-light blade aura on a save that has never had the upgrade. Cause:
`call_set_visibility` has written SetVisibility's `bPropagateToChildren` as a literal 1 since it was
written, and the measured chain is `CollisionCylinder -> VisualMesh -> WeaponMesh -> LightMesh`, so
the aura is a CHILD of the sword. **The A/B needed no extra run** — the same tick already held a
ghost whose sword the new code hid (`LightMesh.bVisible=false`) and one whose sword it showed
(`true`). When a regression lands in code that already runs on several instances, look for the
instance where it did NOT fire before building anything.

**TWO OF MY OWN INSTRUMENTS WERE WRONG BEFORE THE GAME WAS.** `probe_bladeglow`'s first version
reused a `short()` helper that matches the ACTOR pattern first, so every `AttachParent` collapsed to
the pawn and the attach chain — the whole question — was invisible behind complete-looking output.
And the shipped `VFXCLEANUP` counter could not distinguish "never ran" from "ran and destroyed
nothing", because a live component whose destroy did not resolve incremented neither counter. Both
are the same shape as the pickup probe's swallowed first sighting, three days running.

**THREE FINDINGS NOBODY WENT LOOKING FOR:**

1. **The cleanup HIDES rather than destroys.** `GetFunctionByNameInChain("DestroyComponent")`
   returns null on every NiagaraComponent in this build while a Lua probe reading the same live
   objects reports the member present. Two lookup mechanisms, one build, opposite answers — and the
   glow teardown's "no DeactivateImmediate on this build" rests on the same walk, so that
   conclusion is now suspect too. Fixed by resolving `K2_DestroyComponent` by path.
2. **`observed_world_offset_z` was re-learned every sample a burst was alive.** A burst does not
   move; the player does — so the quantity silently became "how far is the player above a burst
   standing still", and one fall dragged the shared value 90 units. Fixed to learn only at first
   sighting; the user watched dust land correctly afterwards and hedged it, so it sits in
   `UNVERIFIED.md` rather than `VERIFIED.md`.
3. **A population census found ~2 Niagara components per despawn that never come back**, while
   ghost PAWNS collect normally — the user's own "stuck in garbagecollection" hunch, narrowed to the
   half that is actually true.

**TOOLING THE USER ASKED FOR, and it paid for itself inside the hour.** `probe_scratch/` is a
permanently registered empty probe slot: UE4SS only knows mods enabled at LAUNCH, so `RestartMod`
cannot see a folder created since and every genuinely new probe cost a relaunch — which they had hit
across sessions. The leak-count probe that produced finding 3 was written, deployed and answering
inside a running game about a minute after the slot existed. `preflight.ps1` now fails a slot left
holding a probe, which is what paid for the CLAUDE.md lines the rule needed.

**BUILT, NOT YET WATCHED: the recording indicator** (ADR 0052). A red dot and elapsed time in the
top-right while the core is recording, because the record hotkey is system-wide, lives in the core,
and the core can never draw — so the only feedback was a console line the user does not have open.
The design is theirs; the implementation is the nametag's mechanism twice, since that "box" is not
geometry but a second text component with a tinted material, which makes a circle a CHARACTER and
costs no asset. New bridge message `recording_state`, the first core -> adapter state message any
adapter here has ever handled.

## 2026-09-05 — the recording indicator, and what a dozen looks at a red square actually taught

**Shipped in one session, from the user's design (ADR 0052).** A red square and an elapsed clock,
top right, while the core is recording. Confirmed on screen: the clock counts, the pair is fixed to
the view, it disappears on stop, and the colours are the ones asked for. Four numbers are still
being judged and the last build is **built, not deployed** — see `UNVERIFIED.md`.

**THE DEFECT WORTH REMEMBERING IS NOT ABOUT THE INDICATOR.** This build has neither `SetText` nor
`MarkRenderStateDirty` on `TextRenderComponent`, so `set_text_render_string` has always fallen
through to a property write that changes what the component HOLDS and nothing about what it DRAWS.
**Nametags only work because they rewrite their world transform every tick and that dirties the
render state as a side effect.** The indicator is attached and holds still by design, which removed
the accident and exposed the bug: a clock frozen at `0:00` while `elapsed_s` climbed past 60 in the
log. A neighbouring feature that works is not evidence the mechanism works.

**Three more things the mechanism refused, each found by trying it:**

- **Coloured text does not land here** — `set_text_render_color` resolves and draws black, which is
  what `NAMETAG_COLOR_PLATE` was invented for. So the only colourable thing is a plate, whose
  material fills each glyph's whole quad, so **every shape is a rectangle**. A circle was never
  reachable; three looks were spent proving it.
- **Padding by spaces does nothing** — no advance in the generated mesh.
- **Plate colours were never converted sRGB → linear**, so every plate in this adapter has been
  washed out since nametags shipped. `#EE4B2B` arrived as salmon. Fixed globally; the user judged
  the richer nametag parchment *"good/better"*.

**THE PROCESS LESSON, and it is the reusable one.** A dozen looks went into this, and the split is
stark: **every look that changed a NUMBER was free** (a tuning file re-read 5x/second, edited while
the game ran), and **every look that changed a MECHANISM cost a rebuild and a relaunch**. Building
the live loop early paid for itself several times over — and the tell for "this needs a build" was
always the same, that the same knob was being asked to do two opposite things. `plate_w` giving
side margins while also making the box tower over the text is the clean example: no value existed
that satisfied both, and the fix was separating width from height, not searching harder.

**The user's own framing drove two of the three mechanism changes** — that padding should be
constant rather than proportional (a multiplier gives a long name a huge gap and a short clock
none), and that the square needed the same per-axis freedom as the box.

## 2026-09-05 (second session) — the indicator's shapes settled, and the order that got there

**Ask:** *"fix the nametag, red square, white/timer square size/positions first mainly"*. Rigs
already up (relay `127.0.0.1:7777`, two fake peers). **Outcome:** nametags judged fine on the first
look; the square, gap and box went through nine live edits and one rebuild to *"think they are
actually pixel perfect now"* — first read as a hedge, then made a confirmation by the user's own
method: *"I was trying to pixel peep, and even used sharex to line up with the zoom for taking a
picture and the pixels were aligned"*. **In `VERIFIED.md`**; `UNVERIFIED.md` keeps the one look
left (the BAKED defaults, no tuning file). Numbers: the `VERIFIED.md` entry.

**Two rebuilds, both mechanism, both paid for themselves the same afternoon:**

1. **The nametag's knobs made live** (`name_up name_size name_behind`, plus `plate_margin`/`plate_h`
   re-applying to tags already on screen via a tuning GENERATION each tag stamps itself with).
   Its height and plate offset were `constexpr`, its plate scale applied once at spawn — so any
   verdict would have cost a relaunch. Spent BEFORE the first look, on the last session's own
   lesson. As it turned out the nametags needed nothing, which is the cheap way to learn that.
2. **`plate_up`, the timer box's own vertical offset.** The box is centred on the digits' QUAD and
   the ink sits high in it, so the box's spare space was all BELOW — and `plate_h` shrinks about
   the centre, so 0.68 clipped the tops while leaving the bottom. The tell was the same as last
   session's `plate_w`: one knob being asked for two things (cover the top, lose the bottom).

**The order that worked, worth writing down because the wrong order cost three looks: CENTRE
FIRST, THEN SIZE.** A box that is off-centre cannot be sized — every height reads wrong on one
edge and the fix looks like the other knob. Once `plate_up` had it centred (one overshoot, 1.0 →
0.7), `plate_h` converged in two edits. Same for the square: its height matched before its position
was touched, and the last two edits were ~2px nudges of `dot_up` alone.

**Also this session:** three ShareX GIFs shrunk with the user's `make-gif.bat` (40/54/82 MB → 6/8/8
MB); my tool sandbox refuses writes to their Screenshots folder, so the bat runs unsandboxed. Not a
repo fact — noted in agent memory only.

**Later the same session — the frozen-player defect, chaser half (ADR 0053).** The user asked how it
gets fixed and set the scope in one line: *"I only want it to affect chaser, not recordings/replay
ghosts"*. Built and tested on the Go side: a `player_frozen` bridge message (adapter -> core, on
change) and a GAMEPLAY clock for the chaser — wall time minus every frozen span — that its sleeps
run on, with frames taken while frozen never offered to it. Regression test
`TestChaserHoldsWhileThePlayerIsFrozen` fails without the fix (the chaser walked 21 -> 31 onto a
player held at 31) and passes with it; full suite and `-race` green. The design point worth
keeping: a FILTER (stop offering frames) is not enough, because queued frames still fall due on
the wall clock and the first frame after is a seam — a CLOCK fixes both. **The adapter half is
open and is a probe:** what Pseudoregalia's own frozen signal is (`UNVERIFIED.md`, the frozen
entry). No adapter sends the message yet, so nothing changes on screen until it does.

**Later still — the frozen-signal probe ran, and a reset-to-save crash named the indicator.**
`probe_frozen/` (`PROBES.md`) through the scratch slot, three faults fixed by hot reload without a
relaunch. **Result:** the pause menu is the engine's own pause — `WorldSettings.PauserPlayerState`
flips on the exact samples the menu opens and closes, across the options submenu and a 100ms
open/close spam, so the adapter's `player_frozen` signal for the pause menu is that field. Five
controller input gates do not resolve through UE4SS on this build. The item popup, the intro
cutscene (a fourth frozen state the user found by loading a new save) and a zone transition are
still unmeasured, because the run ended in a crash: *reset to last save* with a recording running.
`read-minidump.py --stack` put the reset-hook lambda on the crash thread; the probe's next sample
was 70ms away and is cleared by timing. **The user named the cause before the dump was open** — the
recording indicator's components, dropped but never removed, *"this is like the 3rd or 4th time"* —
and it is the fourth handle in the reset-crash family. Fix: `destroy_recording_indicator` at the
reset button's PRE hook, built and deployed, UNWATCHED. Promoted to a rule the user asked for:
`checklists/before-spawning-in-unreal.md`, first bold line.

**And then the reset crash was reproduced on demand, and the indicator theory fell.** The user's
recipe: *"spam opening/closing the pause menu, and then doing reset to last save"*. It crashed
identically WITH the indicator's destroy line in the log — so the indicator was not it. What the
night's log actually said: nineteen resets with three ghosts and a recording running were clean, and
every one of them had skipped the reset-button hook, because that hook only ARMS when a closed
menu's uncollected widget copy is still around (the tick is silent while paused; the widget exists
only while paused). Both crashes had it armed. The hook's own destroy-at-click — which its
2026-08-31 comment already called the INSTANT crash, next to a LATER crash that 2026-09-01 fixed —
was the cause all along, and the accidental arming is why it read as intermittent from 2026-08-30 on.
**Fix:** the hook is observe-only by default (`guard_destroy.txt` for the A/B), built and deployed,
UNWATCHED. The pitfall written at 04:07 was rewritten to the right lesson: never destroy
anything from inside a game UI callback, and a hook that arms by scanning arms by luck.

**Third crash, same recipe, with the hook doing NOTHING.** Observe-only was not enough: a
pre-hook whose callback only wrote a log line still crashed the click. Three dumps, three
subtractions (probe, indicator, destroy-at-click), one survivor: the hook's existence. It is no
longer registered (`guard_hook.txt` for the A/B); resets release at LoadMap PRE, which nineteen
clean resets already used. The user closed the design question — *"do we even need the pause menu
hook?"* — no, it was never a feature. The pitfall was rewritten a second time, to the rule that
should have come first: subtract the hook before subtracting what it does.

**Confirmed.** Eleven resets on the hook-free build, spam and slow, recording on and off, three
ghosts each: *"don't think its crashing anymore, even if i spam or do it slow, or with recording
on/off"*. In `VERIFIED.md`. The frozen-signal probe still owes the item popup, the intro cutscene
and a zone transition.

**The probe finished its list.** Item popup: the engine's pause, `PauserPlayerState` set on the
sample the upgrade prompt appeared and cleared on continue, a 19-second span with exact edges — the
same signal as the pause menu. Intro cutscene: not a freeze but a scripted possession (the game ran
and jumped the pawn itself), engine pause off, dilation 1.0; a skip-listener widget marks the start
and is only collected ~12s after the end, so no Lua-readable edge; the controller input gates want a
C++ read if an edge is ever needed, and the chaser does not need one. So the adapter's
`player_frozen` is one property: `WorldSettings.PauserPlayerState != null`. Probe unloaded, stub
restored.

**The adapter half of ADR 0053 is built.** `player_frozen` is sent on change from
`WorldSettings.PauserPlayerState`, read before the tick's paused early-return (the pause menu flips
the cursor on the same sample it sets the pauser, so a read after that return would miss the rising
edge); reset at every hello so a core attaching mid-pause is told. Deploys at the next game exit;
the look is a chaser that holds through a pause menu and resumes the same distance behind.

**Confirmed: the chaser holds through a pause.** Six pauses of 1 to 24 seconds with a 3-second
chaser: *"yee looks like its pausing when in menu/item etc"*. ADR 0053 is done end to end and the
frozen-player defect is closed for the chaser. Found on the way: the 2026-09-04 sword mirror read
`WeaponMesh.bVisible` through a plain byte -- the bitfield trap, a third time -- and rewrote plus
logged it every tick per ghost (~140 lines/s per ghost, seen with the chaser); fixed with
`mg_read_bool`, built, deploys at the next game exit. Sixty-five other `mg_property_value<bool>`
reads want the same audit.

**The chaser blink, reproduced and fixed the same hour.** Eight chasers on: 3..8 cycled
despawn/respawn, 1 and 2 never. The release timestamps per chaser gave the answer before any
theory: period = delay + 3s spawn window. The core's chaser queue is sized for 100 samples/s and
this adapter sends ~180 (read off the bridge counter), so every chaser more than ~6s behind filled
its queue, lost a run of samples longer than the seam threshold, despawned and came back on the
player. The tap now thins to 100Hz; regression test in `core/chaser_test.go`; core rebuilt and
deployed to every install. `pitfalls/by-lesson.md` has the rule. UNWATCHED.

**Confirmed.** Eight chasers, two minutes of walking and circling: *"Seems to be working, no random
teleporting & they also don't despawn randomly anymore"* -- eight spawns, zero releases in the log.
In `VERIFIED.md`.

**Session close, 2026-09-05.** Fifteen commits (plus this close), pushed at the user's ask. Confirmed
on screen today: the indicator's shapes twice, the reset crash closed, the chaser holding through a
pause, the chaser blink gone. Built and UNWATCHED: the sword-mirror bitfield read (one WEAPONMESH
line per change instead of per tick). Open for the next session: the 65 other
`mg_property_value<bool>` reads that want the bitfield audit; the older Pseudoregalia queue entries
nobody has watched; a cutscene edge if a chaser ever needs one (C++ read of the controller input
gates); the other three adapters do not send `player_frozen` yet. Rig torn down and verified gone;
the Steam install's config restored to the shipped one (chaser back off).

**After the push: CI was red twice over, both fixed before bed.** (1) The race job: both
recording-state tests set `ReplayDir` AFTER the adapter attached while `StartReplays` read it on the
bridge goroutine -- a harness race from 2026-09-04, flaky (the next run passed); the field is now
set before the bridge serves, through the helper made for exactly that. (2) The fuzz job:
`FuzzDepthBoundsAgreeAndNeverPanic` found the decoded-walk depth check counting a scalar leaf as a
level, so 32 nested arrays around a number were refused by the walk and accepted by the byte scan;
the walk now tests the bound on containers only, the failing input is committed as a seed under
`protocol/testdata/fuzz/`, and 30s of local fuzzing found nothing more. Suite and `-race` green,
binaries rebuilt and deployed.

**And a third red job the morning after (run 33942692231), from the fix commit's own push:** the
race job failed `TestReliablePayloadIsNotAckedWhenItCannotBeDelivered` in `netx/udpconn` -- "the
retransmitted payload never arrived after the receive queue drained", 8.5s. A test-harness race,
not a product bug: the retry ticker starts at the Write, the test slept exactly two retry ticks,
so the second resend could land while the test's blind `<-srv.in` drain loop ran and be swallowed as
filler -- delivered, so acked, so the sender had nothing left to resend, and the wait timed out.
The drain now goes through the same Read loop that waits for the payload, so a resend arriving
mid-drain counts. 40/40 under `-race` locally (the old loop never failed locally either; the
sleep-equals-two-ticks alignment only bites on a loaded runner). Same lesson as the 09-04 harness
race: a test that pokes a Conn's queue directly must not also let the other side keep filling it.

**Afternoon, 2026-09-05 — v1.1.5 released; Archipelago coexistence re-checked on a fresh reinstall, both
orders.** The user reinstalled Pseudoregalia, applied v1.1.5 then the Archipelago zip, and asked
for the pair to be confirmed in both orders. Hashing first: the two zips overlap on exactly three
files (the UE4SS runtime and its .ini), both builds are RE-UE4SS `733e5969`, everything else is
disjoint. Order one (Archipelago's runtime) with loopback, chaser, two fake peers: user-confirmed
with a screenshot of items arriving. Order two (our runtime copied on top): user-confirmed the
same. Record: `pseudoregalia/VERIFIED.md`. Rig notes: the mod autostarted the shipped client from
its folder when the dev core was restarted and took the bridge port — the realistic setup, kept;
the chaser was flipped in the install's config and the client killed so the adapter respawned it;
a scratch script waited for the session's first `STATESEND` line and launched the fake peer itself.
The `tasklist` process name is truncated to `pseudoregalia-Win64-Shipp`, so a monitor grepping the
full name never fires — match on `pseudoregalia-Win64`. Rig torn down, install config restored.

**Later, 2026-09-05 — the client and its config move to the game root; a high-priority outline defect
is measured but not yet found.** The user, after a question about `client-config-overrides.json`
(a staging input that shipped as an empty `{}` -- moved out of the release tree), asked for the client
and config to sit in the game's root folder with the DLL left deep in the mod folder, then made it a
full swap: nothing read from the mod folder any more. Built for both UE launchers, READMEs and staging
rewritten (per-game `config.json` now at `games/<game>/`), DLLs rebuilt and deployed, the three
installs' files moved up. Pseudoregalia confirmed on screen (`VERIFIED.md`); TEVI unwatched.
Two scripted-edit lessons paid for again: Python non-raw strings ate `\u` in `\ue4ss` and a `\/`
inside a wide literal (the compiler said C4129 and the grep of the RESULT caught the second), and a
CRLF README rejected an LF multi-line pattern -- read universal, write back `\r\n`.
Then the outline: the player and the player's sword go blue around ghosts, and after a melee attack it
sticks (screenshot). One live A/B with `keep_custom_depth.txt` (no restart): ghosts keeping custom
depth removes both symptoms until the first melee swing, then body and sword stay blue permanently;
ghosts show through walls but not through the translucent void doors. `probe_outline/` written and
staged in the scratch slot; the reinstall had wiped the reloader, so it arms on the next launch.
Record: `UNVERIFIED.md`'s OPEN entry.

**Evening, 2026-09-05 — the stuck blue outline, found in one session with three hot-loaded probes and
fixed.** The report: sword silhouette through the player's own body after an attack or slide,
permanent until a save reload; afterimages through the body; the player outlined behind a ghost.
Stage 1 (flags) said the body read custom depth OFF after the attack on a pawn the game had recreated
at a same-level reload; stage 2 (pre/post hook on `SetRenderCustomDepth` with owner attribution) caught
ONE `false` on the PLAYER's body 0.2 s after the first afterimage and its property dump named
`BP_AfterImage_C.cachedMesh` -> the player's `VisualMesh`; RESTORE through the same setter cleared the
screen at once. Cause: the afterimage sweep strips every object property with a custom-depth flag with
no ownership check, and a player afterimage attributed to a ghost by proximity carried the player's
body. Fix: `component_is_owned_by` on both strips, per-property announce. Built, deployed at the next
close, user-confirmed on the first run. Stage 3 (stencil 1 and 255 on ghosts with `keep_custom_depth`)
proved the outline pass ignores stencil; the user chose option 3 -- ghosts stay stripped, the outline
on the player behind a ghost is accepted. Records: `VERIFIED.md`, `documentation.md` (three facts),
`pitfalls/by-lesson.md`, `PROBES.md`, README step 57. Lessons: the UE4SS Lua placeholder-object read,
pre-hook ordering, `tasklist` truncating process names. The Pseudoregalia copy install got the same
DLL and the game-root layout. Rig torn down and verified gone; scratch slot restored.

**Later still, 2026-09-05 — a two-machine session over the internet on v1.1.6.** Online reported as
working with no big issues; one rare visual fault logged at no priority: a remote ghost came back
glitched (fragments, floating sword, shadow intact) after its peer's reset-to-save following a hit;
the watcher's own reset cleared it; the peer saw nothing and could not reproduce it. `UNVERIFIED.md`.

**Night, 2026-09-05 — the sword model.** The user asked whether weapons sync like outfits. Reading the
state: everything the sword DOES is sent, nothing about how it LOOKS. `weapon.lua`, hot-loaded into the
live two-machine session: the hand sword is one skeletal mesh asset on `WeaponMesh` at `handSlot_RSocket`;
the user swapped BusterSword -> Dream Breaker Keyblade -> stock and only the asset line changed. The peer
confirmed their modded sword shows as stock on the user's screen. Filed as buildable (`ideas.md`), the
facts in `documentation.md`; not built tonight. Two rare no-priority items logged from the same session:
a glitched remote ghost after a peer's reset-to-save, and a nametag occasionally too low.
