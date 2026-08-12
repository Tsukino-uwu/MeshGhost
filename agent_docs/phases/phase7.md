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
- [ ] 7.4 — Placeholder ghost spawned in-engine, fixed offset from the local player, no
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
