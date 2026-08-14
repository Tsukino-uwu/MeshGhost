# Current status

## Active status

- `Active phase:` Phases 1 and 2 are both complete (2026-08-11, folded into
  `agent_docs/plans.md`) — see `agent_docs/verified.md`. Phase 2 confirmed
  `adapters/pokemon/emerald/phase2_ghost.lua` renders and tracks the local player correctly, including
  at a real camera-pinned map edge, with no unexplained flicker. Three transient-rendering
  quirks were found and traced to already-understood causes rather than new bugs: (1) the
  sprite-slot-based screen-position read breaks during battle — resolved as a design decision
  (skip all ghost drawing during local battle; the data side already doesn't need a `nil`
  return, so a remote player's ghost just holds still, not despawns — implementation deferred
  to whichever phase first has `render_remote` calls to gate), (2) a brief jitter crossing
  seamless route/town connections and (3) a brief dip-then-correct on door warps, both
  plausibly the same `gSaveBlock1Ptr`-relocation glitch Phase 1 already found in raw position
  data, now visible in rendering too. Only loose ends: bike/surf flags (deferred, not
  blocking) and the `coordOffsetEnabled` assumption (unverified but low-risk, cheap to revisit
  if a non-centered-camera area is ever found that contradicts it).
- `Current focus:` Phase 3 (loopback) is **complete** (2026-08-11) — see
  `agent_docs/phases/phase3.md`. Confirmed on screen: a ghost trails the player ~200ms behind,
  `TILE = 16` correct, holding steady across walking/running and route/house transitions, no
  flicker, over the real relay/core/bridge round trip (`-loopback` flag, not a same-process
  shortcut). Three real bugs were found via live testing and fixed, all now covered by
  `verified.md` entries: `internal/core` didn't despawn remotes when its own relay connection
  dropped (fixed: `Core.dropAllRemotes`, wired into `OnDisconnect`, regression test added); the
  Lua adapter didn't detect its own bridge connection dying (fixed: `drainBridge`'s error
  handling inverted to treat only `"timeout"` as harmless); and — the one that made both of
  those look worse than they actually were — BizHawk's `gui.*` overlay does not auto-clear
  between frames, contradicting a wrong assumption `contract.md`'s tick model had stated since
  Phase 2 (now corrected there). Two Lua environment gotchas also found and fixed along the
  way: `debug.getinfo` can't recover a script's own path in BizHawk (scripts load as in-memory
  string chunks, not files — `io.popen("cd")` works instead), and the vendored LuaSocket binary
  needed `lua54.dll` explicitly pre-loaded by full path before it would load.
- `Next step:` **Phase 4 (two players) is complete** (2026-08-11) — see
  `agent_docs/phases/phase4.md`. Two real BizHawk/Emerald instances, distinct `-bridge`/`-name`
  cores, one relay without `-loopback`: confirmed on screen each client renders the other's
  ghost, a join is visible to the earlier client, a clean peer-leave (core process closes)
  despawns the ghost while an adapter-only disconnect correctly does not, an unclean leave
  (Task Manager kill) also despawns correctly, and no flicker/drift with two independently
  moving real players. `internal/core`'s `dropAllRemotes`/despawn work and the Lua adapter's
  disconnect-handling fixes from Phase 3 — previously only exercised via loopback — are now
  confirmed to generalize to a real second peer. Two more bugs found live and fixed in the same
  session: (1) a client's ghost-anchor read broke while *that client's own* player was in
  battle or in any full-screen pause-menu submenu (Pokédex/Bag/Card/Options) — fixed via a real,
  cited `pokeemerald` signal (`gMain.callback2` vs `CB2_Overworld`), confirmed live to hide/reshow
  ghosts correctly and strictly per-viewer, with NPC dialogue correctly left ungated; (2) remote
  ghosts rendered one tile too high (sprite-anchor vs. tile-position mismatch) — fixed with a
  `GHOST_Y_CORRECTION` constant, confirmed on screen. See `agent_docs/verified.md` for full
  entries. Any future Archipelago-coexistent adapter work will still need to re-derive
  `gPlayerAvatar`/`gObjectEvents`-equivalent addresses for a patched ROM rather than reusing the
  vanilla-decomp ones. One small deferred item from Phase 3: `internal/core` logs a noisy
  `send state to relay failed` error every frame after a relay disconnect — harmless, worth
  quieting opportunistically. Deferred idea from Phase 4 testing (not scheduled): rendering
  ghosts across a seamless route/town connection instead of just hiding them like any other
  different `area_id` — see `agent_docs/plans.md`.
- `Current focus:` **Phase 5 (extract the template) is complete** (2026-08-11) — see
  `agent_docs/phases/phase5.md`. Added `Core.RunAdapter`, an in-process driver for the
  already-existing (but previously unused) `core.Adapter` Go interface, sharing its tick-model
  diff logic with the existing bridge-wire path rather than duplicating it. Confirmed live:
  `cmd/meshghost-fakeadapter` (two instances, `dev-scripts/run-fakeadapter1.bat`/
  `run-fakeadapter2.bat`),
  each driving a circle-motion fake ghost with no game and no `adapters/` import, correctly
  exchanged and rendered each other's continuously-moving position over a real relay — user
  watched both console windows directly. `adapters/_template/` is now frozen
  (`README.md` + `PROTOCOL.md`), written language-agnostically since Phase 6's target (TEVI) is
  Unity/C#, not Lua. `TestRunAdapterInProcess` in `internal/core/core_test.go` covers the same
  path as an automated regression test.
- `Current focus:` **Phase 5.5 (real Emerald ghost sprite) is complete** (2026-08-11) — see
  `agent_docs/phases/phase5_5.md`. User pushed back on moving to Phase 6 while Emerald ghosts
  still rendered as a magenta placeholder box; scoped to three items, all done and confirmed
  live with two real peers: real decoded Brendan/May sprite renders (`gui.drawPixel`, fixed a
  wrong assumption about its color format along the way), `extras.gender` in the schema with
  gender-correct rendering confirmed both directions (male-save client sees May, female-save
  client sees Brendan), and every Phase 1/2 address re-verified on a real female save —
  `agent_docs/risks.md`'s male-only-tested gap is now closed. Facing direction and both
  walk/run animation are correct, including a genuinely separate running pose (found live —
  running is not a faster walk cycle, it uses its own pic table with asymmetric per-pose
  timing). Beyond the original three items, testing with a real detailed sprite (instead of the
  old placeholder box) surfaced and fixed real bugs: sub-tile position smoothing for a
  choppy/wobbly remote-ghost movement bug (real measured constants: 16 frames/tile walking, 8
  running, locked in per-step to avoid mid-glide snapping) and a stale-remotes-on-core-restart
  bug. Ledge jumps/Mach Bike/Acro Bike/Surfing confirmed out of scope, added to the existing
  bike/surf deferred item.
- `Current focus:` The repo is now public on GitHub — a cleanup pass fixed the stale README,
  removed hardcoded personal paths, and added a `CLAUDE.md` rule against that recurring. Since
  then, a real release pipeline was added (2026-08-11, not a numbered phase — see
  `agent_docs/plans.md`'s "Release packaging" entry): `cmd/meshghost`/`cmd/meshghost-relay`
  both load an optional `config.json`, and `.github/workflows/release.yml` builds/zips two
  downloadable packages (`packaging/relay/`, `packaging/emerald-player/`), triggered manually
  from the Actions tab (deliberately not automatic on a tag push) — confirmed working via a
  real local dry run (actual relay + client processes, config-only, no flags) before
  committing, though the GitHub Actions workflow itself is still untested end-to-end (the dry
  run proved the packaging logic, not the CI YAML). All 8 dev/testing `.bat` launchers also
  moved from the repo root into `dev-scripts/` for a cleaner public root, alongside
  `packaging/`'s end-user-facing scripts.
- `Current focus:` **Phase 6 (TEVI) has gone about as far as it can go solo** (started
  2026-08-11) — see `agent_docs/phases/phase6.md`. Confirmed live through 6.5 and beyond
  (2026-08-12): Mono (not IL2CPP), a BepInEx plugin (`adapters/tevi/MeshGhostTevi`) reading real
  player position/facing/anim/area, a full bridge→relay→core round trip via the relay's
  `-loopback` flag, and — going beyond the original 6.1-6.6 outline, since it's fully
  solo-testable — a real character-visual ghost clone (not a placeholder box): correctly
  anchored, correctly facing, and playing real animations including full combat moves, driven by
  the actual Animator clip name over the wire rather than an invented mapping. Two real bugs
  fixed in `internal/core` and adapter code along the way, including the relay's 120 msg/sec
  limit (`Core.MinSendInterval`, ADR in `architecture.md`, regression-tested) since TEVI's
  `Update()` runs uncapped. Next: **6.6 (two real players) is blocked** — Steam won't run two
  TEVI instances at once, confirmed by the user; needs a second machine. Everything else
  solo-testable is done; what's left (cross-area filtering, real join/leave) genuinely needs a
  second peer. Also carried forward, not blocking: testing the position read with the TEVI
  Randomizer mod disabled (coexistence risk).
- `Current focus:` **Decided 2026-08-12: not blocking Phase 7 (Pseudoregalia) on TEVI's 6.6.**
  Adapters are structurally isolated, so no technical reason blocks starting a third game while
  6.6 waits on a second machine with no ETA — see `plans.md`'s Phase 6 status note for the full
  reasoning and the accepted tradeoff (a real, not hypothetical, chance 6.6 later surfaces a bug
  the same way Emerald's Phase 4 did).
- `Current focus:` **Phase 7 (Pseudoregalia) started 2026-08-12, paused mid-7.2** — see
  `agent_docs/phases/phase7.md` for the full task-by-task record; this entry is the short
  version for picking the session back up.
  - **7.1 is done and confirmed live**: a Lua discovery probe
    (`adapters/pseudoregalia/probe/Scripts/main.lua`) showed the user's real pawn
    (`BP_PlayerGoatMain_C`, a Blueprint class reachable via plain `UEHelpers` reflection),
    position, yaw, and level name all tracking correctly through real movement (running,
    crouching, backflips, ledge-hang, deaths, a real level transition). See `verified.md`.
  - **7.2's original plan — a C++ UE4SS mod as the shipping adapter — is blocked**, and not
    on a local setup gap: CMake + VS Build Tools are now installed (confirmed), but building
    UE4SS itself requires a private submodule (`Re-UE4SS/UEPseudo`, confirmed 404/no access)
    that no official release provides a prebuilt substitute for (no `.lib` ships anywhere).
    **Do not re-attempt building RE-UE4SS from source next session without first checking
    whether UEPseudo access was granted** — see `agent_docs/risks.md`.
  - **While investigating that, two real things happened, both recorded in `verified.md`**:
    (1) a same-day UE4SS runtime update (to get header/binary version parity) broke
    `AP_Randomizer` for real (`0x7f`, missing exported procedure) — caught via the user
    seeing an in-game error, rolled back, re-confirmed working. `UE4SS.dll` is back at the
    original `733e5969`; `dwmapi.dll` was left at the newer build with no original backup,
    empirically fine but not a deliberately verified pairing.
    (2) UE4SS's embedded Lua 5.4 **does** expose `package.loadlib` as a real function
    (`MeshGhostSocketProbe` Stage 1, confirmed live) — this reopens, not resolves, the
    adapter-language question, since the earlier "Lua has no sockets" reasoning was about a
    missing first-party library, not `loadlib` being disabled.
  - **Next step, not yet started**: a Stage 2 script exists
    (`adapters/pseudoregalia/probe_socket/`) to actually try loading the vetted
    `lua54.dll`/`socket-windows-5-4.dll` pair — genuinely risky (could crash the game, not
    just error) since UE4SS's Lua is statically embedded, unlike BizHawk's separate-DLL host.
    Needs an explicit decision with the user before running, not just picking it up and going.
- `Current focus:` **Release packaging reworked 2026-08-12, TEVI added to the release** — see
  `plans.md`'s "Release packaging" entry and `packaging/README.md`. The two-zip
  `meshghost-relay-.../meshghost-emerald-player-...` split (from the `v0.1.0` cut, flagged
  right after as confusing to a non-technical downloader) is replaced by one zip:
  `packaging/release/` holds `meshghost.exe`/`meshghost-server.exe`, one `config.json` with
  `client`/`server` sections, and `games/<publisher>/<game>/` mirroring `adapters/`. The
  launcher `.bat` files were removed 2026-08-13 once both `.exe`s started writing their own
  `meshghost.log`/`meshghost-server.log` next to themselves — see `packaging/README.md`'s "No
  launcher .bat files" section. TEVI now ships in that same zip, marked experimental — its
  `MeshGhostTevi.dll` is a committed build output (`dev-scripts/build-tevi.bat`), since CI can't
  build it itself (needs the developer's own proprietary TEVI install), guarded by a staleness
  check in `.github/workflows/release.yml` that fails the release if the DLL predates its
  source. This is how Phase 6.6 (two real players) is meant to finally get tested — not a claim
  that it has been; nothing here has been watched running by the user yet, so nothing moves to
  `verified.md` on the strength of this work alone.
- `Current focus:` **Same day, follow-up: adapter declares `game_id` (ADR in
  `architecture.md`), `"game"` dropped from the shipped `config.json`.** A new bridge message,
  `internal/bridge.Hello`, is sent by the adapter as the first thing on a fresh bridge
  connection; `internal/core.Core.ConnectRelayOnAdapterHello` connects to the relay lazily on
  that hello instead of requiring `-game`/`"game"` up front. Both shipped adapters updated and
  TEVI's committed DLL rebuilt to match. `-game`/`"game"` still work as an explicit override,
  needed by `dev-scripts/run-core.bat` and `cmd/meshghost-fakeadapter` (no real adapter to send
  a hello). `go build`/`vet`/`test` clean; not yet watched running against a real game by the
  user, so — same as the packaging entry above — nothing here moves to `verified.md` yet.
- `Current focus:` **Phase 7.6 (2026-08-13): C++ adapter switched back to spawn-based ghosts (a
  real player-model clone, not a rigid hijacked prop) and confirmed live, camera bug and all.**
  Full record in `agent_docs/phases/phase7.md`; short version:
  - **Earlier sessions' "no working destroy mechanism, must hijack instead" verdict was a
    thread-context artifact, not a fact about this build.** That verdict came from spawn/destroy
    calls made off the game thread (`on_update()`, since fixed — see the entry below this one).
    Retested on the game thread (`ensure_ghost_spawned`, called from `game_thread_tick`): no
    crash, real player-model ghost, **confirmed live 2026-08-13.** `K2_DestroyActor()`'s own
    no-op status was never re-tested (this design still never calls it) — still an open, separate
    claim.
  - **Camera fight-back (Phase 7.4's other proven fix) took three attempts to port to C++, and
    the reason the first two failed is a real, transferable finding.** This game calls
    `SetViewTargetWithBlend` as a **native** function, which bypasses `ProcessEvent` entirely — a
    `RegisterProcessEventPostCallback`-based hook (attempts 1 and 2) never fires for it at all,
    confirmed via `UE4SS.log` showing zero hits across a live run that visibly hit the bug.
    Root cause read directly from UE4SS's own `RegisterHook` implementation
    (`LuaMod.cpp:3907-3921`): native UFunctions need `UFunction::RegisterPreHook` instead, which
    patches the function's native entry point directly. Attempt 3, built on that, **confirmed
    live 2026-08-13**: camera stays on the player through ghost spawn, ghost follows without
    stopping or teleporting. See `agent_docs/verified.md`.
  - **Area-transition crash found and fixed, confirmed live 2026-08-13**: `EXCEPTION_ACCESS_VIOLATION`
    inside the camera hook, root-caused to `last_known_good_view_target` (a raw `AActor*` cached
    across calls) being dereferenced via `->IsUnreachable()` after a level transition had already
    freed it. Fix: clear the cached pointer proactively in the existing `LoadMap PRE` hook, before
    a transition can free it. Rebuilt (0 errors — the earlier `could not create CMAKE_GENERATOR`
    failure was a `PATH` issue, msys2's bundled cmake 4.0.2 shadowing the real install at
    `C:\Program Files\CMake\bin` 4.4.2, not a toolchain regression), deployed, hash-diff-confirmed.
    User ran a full session: second area, back to first area, main-menu-and-replay, and normal
    exit all worked with no crashes. See `agent_docs/verified.md`.
  - **Ghost animation: confirmed working for basic locomotion, 2026-08-13** (same day, later
    session) — see `agent_docs/verified.md`'s "ghost animation state" entry. The ghost was
    stiff-gliding with no animation; root cause was that the wire's `anim` field had only ever
    been a hardcoded `"idle"` placeholder (7.3's decision, never revisited) and the ghost was
    teleported via direct position writes with no animation-state driving it at all. Fixed by
    reflecting the real pawn's `moveState`/`actionState`/`horizontalSpeed`/`verticalSpeed`/
    `animJumpType`/`CharacterMovement->MovementMode` (confirmed field names via a read-only
    native reflection dump, not guessed) and mirroring them onto the ghost's own pawn instance
    each tick via `extras` (the same opaque field Emerald's `extras.gender` already uses) — the
    ghost's own already-attached `ABP_PlayerGoat_C` AnimBP instance then drives itself the same
    way it does for the real player. User confirmed real walk/run/idle animation live.
    **Still broken, not solved**: the ghost gets stuck in a falling/airborne pose after landing
    (two fix attempts — mirroring `MovementMode`, then latched `landed?`/`jumped?` pulses — both
    failed live); can't grab ledges; doesn't turn to face different directions (a separate,
    previously-unnoticed gap). Legs/animation itself is no longer a gap — the `bHidden`
    render-nudge revisit is now moot.
  - **Ghost collision: tried, reverted — real danger found, 2026-08-13.** Tried enabling ghost
    collision (`GHOST_COLLISION_ENABLED`, was permanently off) as a real fix attempt for the
    stuck-landing/ledge-grab issues. Confirmed live: it did **not** make the ghost physically
    solid (the real player could still walk straight through it), but the real player could
    attack and kill it, which killed the **real player's own character** too — not a cosmetic
    bug, a real progress-loss risk, and the worst of both worlds (no solidity, new death risk).
    Reverted same-day. **Second attempt same day, also reverted**: added a real
    `SetCollisionResponseToChannel(Pawn, Block)` UFunction call on the ghost's capsule (confirmed
    via log that the call genuinely fired, not a reflection failure) — still no solidity, since
    UE's actor-vs-actor blocking needs both sides to agree, and only the ghost's side was
    changed. Fixing that would mean touching the real player's own collision component, a bigger
    risk than anything tried so far, on top of the still-unresolved melee-death danger. See
    `agent_docs/risks.md`'s ghost-collision entry — do not re-enable without explicit go-ahead.
  - **Still not done**: a separate, not-yet-root-caused `Fatal Error!` crash (crashdump, not
    `LowLevelFatalError`) observed once on game exit in an earlier session.
  - **Facing-direction bug: root cause found and fix confirmed live, 2026-08-13 (follow-up
    session).** Full record in `agent_docs/phases/phase7.md`'s 7.6 entry; short version:
    - **Root cause**: not a game-side or adapter-logic bug at all — the vendored `RE-UE4SS` SDK's
      `K2_SetActorLocationAndRotation`/`K2_SetActorRotation` (`RE-UE4SS/deps/first/Unreal/src/
      AActor.cpp`) marshal `FRotator`'s Pitch/Yaw/Roll as hardcoded `float`, unlike `FVector`'s
      X/Y/Z, which correctly branch on engine version (`UE_COPY_VECTOR`,
      `include/Unreal/BPMacros.hpp`). Pseudoregalia is UE 5.1, where the real `FRotator` fields
      are `double` — every rotation write put 4 bytes of float into an 8-byte slot, leaving a
      denormal near zero. Confirmed arithmetically, not just plausibly: `90.0f`'s bit pattern in
      a zeroed double slot is exactly `5.529052754e-315`, matching the previously-logged
      `~5.5e-315` "garbage" readback to three significant figures. This explains every earlier
      symptom: position (marshaled correctly) always stuck while rotation never did, in the same
      call; the forced yaw-cycle test showed no visual change because every value became ≈0, not
      because the write mechanism was dead; and the direct `RelativeRotation` property write held
      correctly in memory precisely because it was the one path that bypassed the broken macro.
    - **Fix**: `call_set_actor_location_and_rotation`, a new local, version-aware helper in
      `Plugin.cpp` (same "real `FProperty::GetOffset_Internal()` offsets, no guessed struct
      layout" pattern the file already used for
      `call_set_collision_response_to_channel`), replacing the three-writes-stacked-together
      block at both call sites. Deliberately not a submodule patch — `RE-UE4SS` is a git
      submodule, so this repo tracks only its pinned commit (`733e5969`), never its file
      contents; an SDK edit couldn't be committed here, would be invisible to a fresh clone, and
      would be silently wiped by `git submodule update`. See `agent_docs/pitfalls.md`'s new
      entry — this will recur on any future UE5 game targeted through this SDK, not just here.
    - **Confirmed live**, with `LOCAL_OFFSET_TEST_MODE`/`FORCE_ROTATION_CYCLE_TEST` both `true`:
      user, verbatim, "it works!, the ghost is turning around." `UE4SS.log` cross-check: the
      one-time diagnostic line confirms the `double` path was chosen, and every `TRACE` line
      shows `sent`/`K2_actual`/`reflected_actual` in exact agreement. See `agent_docs/verified.md`.
    - **Both diagnostic flags flipped back to `false`, rebuilt, redeployed, hash-diff-confirmed.**
      Current deployed `main.dll` is the normal shipping configuration.
      `GHOST_COLLISION_ENABLED` remains `false` (unchanged, safe).
    - **Real networked path also confirmed live, same day, follow-up**: user, verbatim, "its
      following properly now" — the ghost mirrors the real player's own turning correctly, not
      just the forced test cycle. **Facing direction is now fully closed end-to-end.** See
      `agent_docs/verified.md`.
    - **Unexpected side effect of the fix**: ledge-grab — one of the two animation gaps left open
      by the "ghost animation state" work earlier the same day — now works. It was never a
      separate bug; it plausibly depended on the ghost's rotation actually reaching the renderer
      (e.g. ledge-grab detection needing a geometrically correct facing to trace against).
    - **New bug surfaced by ledge-grab now working**: the ghost gets stuck in the ledge-hang
      animation after the real player has already released the ledge and moved away. Not yet
      investigated.
    - **Still open, unaffected by this fix**: the stuck falling/airborne pose after landing
      (unchanged — reproduces exactly as before), and the not-yet-root-caused `Fatal Error!` exit
      crash noted above. Both this and the new stuck-hanging bug are plausibly the same root-cause
      class as the already-tried-and-failed `landed?`/`jumped?` pulse mirroring: a one-shot state
      transition on the real player's side not being mirrored onto the ghost's AnimBP.
  - **Follow-up session, same day: the `landed?`/`jumped?` pulse attempt above never actually
    ran — root-caused and redone, built, deployed, not yet tested live.** A real reflection-dump
    grep (`UE4SS.log`, `log_pawn_reflection_once`'s output) confirmed `landed?`/`jumped?` exist
    only as `BoolProperty`s on `ABP_PlayerGoat_C` (the AnimBP instance, reached via the pawn's
    `animBPref`), never on `BP_PlayerGoatMain_C` itself — the prior code read/wrote both names
    straight off the pawn on both ends, so every access silently resolved to `nullptr` and the
    "failed live" verdict was actually an untested no-op, not a disproven theory. Fix in
    `Plugin.cpp`/`Plugin.hpp`: new `read_animbp_bool`/`write_animbp_bool` helpers take the extra
    `animBPref` hop; the wire field changed from a single-tick bool to monotonic
    `extras.land_count`/`extras.jump_count` (a bool pulse can't survive
    `Core.DefaultMinSendInterval`'s 50ms send-rate cap against a ~60Hz game thread, or
    `remoteBuffer.lerp` holding `extras` from the older bracketing snapshot — a counter is
    drop-safe and repeat-safe); on the ghost side a rising edge in the received counter arms a
    3-tick (`PULSE_HOLD_TICKS`) hold window writing `landed?`/`jumped?` = true onto the ghost's own
    `animBPref`. Added a new dense every-tick `ANIM_PULSE_TRACE` (gated on airborne-or-pulsing, not
    the usual ~2s cadence) logging both sides plus a same-tick readback after the ghost write, per
    `CLAUDE.md`'s "ran without errors is not evidence" rule — if this doesn't fix it, the log
    should show exactly where (e.g. the AnimBP's own graph stomping the write back to false)
    instead of another silent failure. Built (0 errors), deployed to
    `ue4ss\Mods\MeshGhostPseudo\dlls\main.dll`, hash-diff-confirmed, old `UE4SS.log` archived
    (not deleted) for a clean capture.
  - **Confirmed live 2026-08-13: the falling-pose fix above works.** User, after a real jump→land
    cycle: "not stuck in a 'falling' animation anymore after jumping." See `verified.md`.
  - **Ledge-hang-stuck-forever: found, fixed, and confirmed live the same day — both animation
    bugs from the "facing-direction fix" entry are now closed.** With the falling-pose fix
    confirmed, the user reported the ledge-hang pose stayed frozen forever regardless of any
    later jump/slide/land. A live trace of one real hang→release→land cycle proved
    `moveState`/`actionState`/`movementMode` all reset correctly on the ghost (readback-confirmed)
    within ~1s — meaning the pose outlives every state-machine byte resetting, the signature of an
    Anim Montage playing independently rather than a state-machine transition. Per `CLAUDE.md`, no
    function name was guessed: a read-only `UFunction` enumeration of `animBPref`'s class chain
    found a real `Montage_Stop` on this build, and a follow-up read-only `FProperty` dump of that
    exact function confirmed its real parameters (`InBlendOutTime` float at offset 0, `Montage`
    pointer at offset 8, left null to stop whatever's currently playing) before any call was made.
    New `call_montage_stop` helper (same confirmed-offset pattern as
    `call_set_actor_location_and_rotation`) fires on the same land/jump-edge rising-edge logic the
    pulse fix already computes. **User confirmed live: "its working, ... now its actually going
    back to normal/other animations."** A residual ~150-200ms lag behind the real player was also
    reported and traced to the existing, already-accepted `DefaultInterpolationDelay`/send-rate-cap
    trailing delay (the same one Phase 3 confirmed for ghost position) — reducing the blend-out
    from 0.15s to 0.0s made no observable difference, confirming the lag lives elsewhere in the
    pipeline, not in this fix. Left as-is; tightening it further would mean lowering
    `InterpolationDelay` globally, trading smoothness for every ghost movement, a separate decision
    not made as a side effect of this bug fix. See `verified.md` for both entries.
  - **`ANIM_PULSE_TRACE` flipped back to `false`, rebuilt, redeployed, hash-diff-confirmed** —
    current deployed `main.dll` is the normal shipping configuration, same pattern as the earlier
    rotation-test flags.
  - **Remaining open Phase 7 item, unaffected by this session's work**: the not-yet-root-caused
    `Fatal Error!` exit crash noted earlier in this phase.
- `Current focus:` **2026-08-13, later same session — TEVI 6.6/6.7 wrapped up, next priority
  set: relay safety.** TEVI's real two-player test (6.6) fully closed — cross-area filtering,
  ghost cleanup on disconnect (menu return + game close, pause confirmed unaffected), and a
  new 6.7 feature (a peer's real room shown on TEVI's map, fog-of-war respected) all built and
  confirmed live. See `phase6.md`. **User has now named the next thing to actually work on**:
  the relay/core is currently no-auth and safe only for a friend you hand an address to — the
  goal is being safe to use with people you don't personally know, including against someone
  actively trying to be malicious with the server/client. Two known concrete gaps (no auth, no
  peer game-version check) plus a broader look at malicious-peer hardening generally. Not yet
  designed or scoped — see `risks.md`'s "No-auth relay window" entry and `plans.md`'s "Room
  codes / relay safety" section for what's recorded so far. Start here next session.
- `Current focus:` **2026-08-14 — relay-safety hardening built.** Full record: the ADR in
  `architecture.md` (search "room-code/version ADR"), `internal/README.md`'s "What changed"
  section, and `plans.md`'s "Room codes / relay safety" section. Short version:
  - **Room-code auth**: `hello` carries an optional `room_code`, constant-time-checked against
    the relay's own configured `Server.RoomCode`; empty (still the default) means auth stays
    off. A refused `hello` (bad version, wrong code, game/version mismatch, full room) now gets
    a `reject` message with a reason before the connection closes, instead of a bare hangup —
    the old behavior made "wrong code" indistinguishable from "relay is down."
  - **Peer game-version check**: `hello` carries an optional `game_version`, sticky per room the
    same way `game_id` already is. Each shipped adapter reports its own adapter/mod version
    (Emerald `"phase5.5"`, TEVI's BepInEx `PluginVersion`, Pseudoregalia `"phase7.6"`) — not a
    real game/DLC build number, since no cited memory address exists for one in any of the
    three games and `CLAUDE.md`'s no-addresses-from-memory rule means one wasn't guessed at.
    Real, useful gap this still leaves open for TEVI specifically: two peers on different Steam
    patch levels or DLC states still aren't caught — see `risks.md`'s updated entry.
  - **Malicious-peer hardening, scoped from concrete findings, not a checklist**: a real
    remote-OOM in `internal/transport` (unbounded read buffer — fixed via `bufio.Scanner` with
    a real max-token-size, enforced during the read, not after), read/write deadlines and a
    relay hello-timeout (none existed before), `Room.Forward` no longer holds its lock across a
    potentially-blocking `Send` (was a one-stalled-peer room freeze once `Send` could block),
    and `internal/core` no longer trusts the relay completely — it keeps its own roster (from
    `welcome`/`join`/`leave`) and drops `state` for any `player_id` it never saw announced.
    New size/length caps on `orientation`, `area_id`, `anim`, and every `hello` string field.
  - **A real, live-run confirmation, not just `go test`**: built both binaries, ran a real
    relay + real client through the actual shipped `packaging/release/config.json` (not
    flags), confirmed both the correct-code accept and the wrong-code reject via each
    process's own log output — see `verified.md`'s new entry (agent-read-log gated, same
    pattern as the TEVI/cross-machine entries above; not yet watched by the user).
  - **Explicit, honest limits, not silently glossed over**: no TLS (`risks.md`, new entry) — a
    room code crosses the wire in plaintext, so this raises the bar from "anyone with the
    address" to "anyone with the address and the code," not to "safe against a network
    attacker." And a new risk this work itself creates: **room-code auth is enforced entirely
    by the relay, so a stale (pre-2026-08-14) relay binary silently provides zero protection**
    regardless of what any client sends or believes it configured — found from the user asking
    what an old client/server does against new ones. No protocol-level fix exists for that;
    `packaging/README.md`/`packaging/release/README.txt` now say plainly that room-code auth
    needs the *relay* to be current, not just the client.
  - **TEVI's committed `MeshGhostTevi.dll` is now stale relative to source** (`Plugin.cs`/
    `BridgeClient.cs` changed to add `game_version`) — this session has no TEVI/Unity install
    to rebuild it with (same constraint that keeps CI from building it). The release workflow's
    staleness check will correctly fail until someone with a real TEVI install re-runs
    `dev-scripts/build-tevi.bat` and commits the result.
  - `go build`/`vet`/`test` clean across the whole module. New regression tests throughout
    (`internal/transport`, `internal/relay`, `internal/core`) for every fix above, plus three
    pre-existing coverage gaps closed in passing (protocol-version-mismatch, `MaxExtrasBytes`,
    `MaxMessagesPerSecond` — none had a test before).
  - **Same-day follow-up, from user questions**: two real gaps found by the user actually
    asking how this behaves, not by the agent's own review. (1) A rejection previously reached
    nobody but the client's own log — the relay now logs join/leave/reject (lifecycle events
    only, can't spam); `internal/core` logs a connect failure once per distinct message, not
    once per retry. (2) `cmd/meshghost`'s eager `-game` path required the relay to already be
    running (crashed via `log.Fatalf` on the first failed dial) — now retries with backoff
    (1s→15s) instead, routed through the same `ConnectRelayOnAdapterHello`/`relayConnectMu`
    the lazy path already used, so a real adapter connecting concurrently can't race it into a
    duplicate dial. A genuinely permanent rejection (wrong code, version mismatch) still exits
    loudly — only "the relay isn't up yet" gained tolerance. `RejectError`/
    `IsPermanentRejectErr` (`internal/core`) do the classification; `protocol.ReasonRoomFull`
    is the one reason treated as retry-worthy. **Confirmed live**, not just `go test`: real
    `meshghost.exe` started before any relay existed, retried silently (one log line, not one
    per retry) across ~15s of real backoff, then connected the instant a real
    `meshghost-relay.exe` came up on that address — see `verified.md`'s new entry and the ADR
    in `architecture.md` (search "same-day follow-up"). Also, from the same conversation: the
    game-version check's design was confirmed correct as already scoped (adapter/plugin
    version, not a real game build) against real user evidence that different TEVI game
    versions already interoperate fine — see `risks.md`'s updated entry, no code change needed
    there. Separately flagged, not yet acted on: this pass hardened the Go relay/core layer
    against DoS/trust issues, but has not audited the adapters' own message-parsing code with
    an adversarial-input mindset — Pseudoregalia's hand-rolled C++ JSON field extraction
    (`Plugin.cpp`'s `json_string_field`/`json_vec3_field`/`json_number_field`) was spot-checked
    and its own doc comment's "not adversarial input" assumption is now known to be wrong for
    the multiplayer case, though no actual bug was found in the ~50 lines read. A real next
    step if "safe with strangers" is the goal, not done this session.

- `Next step (2026-08-14 review/refactor sweep):` A full review/refactor pass across
  `internal/`, `cmd/`, and all three adapters is code-complete; live testing has started and is
  turning up real, previously-unknown bugs (expected — that's what this pass was for). See the
  ADR in `architecture.md` (search "same-day review/refactor sweep") for the sweep's four
  original behavior-changing decisions and the full fix list, plus a follow-up ADR (search
  "found during live testing of the sweep above") for a relay-auto-reconnect gap found live.
  `pitfalls.md` has the partial-send/receive NDJSON-framing pattern found independently in
  Emerald's Lua and Pseudoregalia's C++, and the "move offscreen, never destroy" ghost-lifecycle
  pitfall. Status by layer:
  - **Go (`internal/`, `cmd/`)**: all sweep fixes applied, plus a same-day follow-up fix found
    during live testing — a relay that drops *after* a successful connect (crash, restart,
    network blip) previously had no path back to "connected" short of a full client restart;
    `Core` now auto-retries in the background. `go build`/`go vet`/`go test` clean, including a
    new regression test (`TestRelayDisconnectAutoReconnects`). Live-verified via real binaries
    (kill relay → client retries → new relay → client reconnects automatically) — see
    `verified.md`. **Important operational note, also found live**: `meshghost.exe`/
    `meshghost-relay.exe`/`meshghost-fakeadapter.exe` at the repo root are NOT kept fresh by
    `go build ./...`/`go vet`/`go test` — those compile-check packages but don't overwrite the
    named binaries the `dev-scripts/*.bat` files launch. The user's first repro of the
    auto-reconnect bug was against binaries a full day stale, predating even the prior session's
    start-order-independence fix. **Always `go build -o meshghost.exe ./cmd/meshghost` (and the
    other two) explicitly before testing via the `.bat` files**, the same discipline already
    required for the Pseudoregalia/TEVI adapter builds.
  - **Pseudoregalia (C++)**: all fixes applied, rebuilt (0 errors), hash-diff-confirmed deployed
    to both the in-repo packaging copy and the live Steam install. **Live-confirmed working**
    (2026-08-14, see `verified.md`): ghost spawn/follow/animate, no crashes. Not specifically
    exercised yet: the move-offscreen-on-despawn behavior itself, and an area transition with a
    ghost present. Unrelated to this sweep, found live during the same test: a possible ghost→
    real-player combat interaction (ghost landing hits despite `GHOST_COLLISION_ENABLED = false`)
    — logged as a new data point on the existing 2026-08-13 collision open question in
    `risks.md`, low priority, not yet investigated.
  - **Emerald (Lua)**: all fixes applied (partial-line receive, partial send, dead-socket-after-
    hard-error, `pcall` around the main loop, control-char JSON escaping) — no rebuild step for
    Lua, but **not yet live-verified in an emulator.**
  - **TEVI (C#)**: all fixes applied (stale-thread generation guard, `TcpClient` disposal, real
    `Destroy()` on ghost/marker despawn, `OnDestroy`/`OnApplicationQuit` bridge close, `room_x`/
    `room_y` range check, `TryGetValue` in place of unguarded `JObject` casts). Rebuilt via
    `dev-scripts\build-tevi.bat` (0 errors) — this machine does have the gitignored
    `lib\Assembly-CSharp.dll`/`lib\Newtonsoft.Json.dll` from a prior session, so a real rebuild
    against TEVI's actual types was possible after all, correcting the plan's original "no
    rebuild possible here" assumption. Deployed to both the Steam install and the standalone
    `C:\dev\tevi-14778703` build, hash-diff-confirmed. Two dedicated dual-instance dev scripts
    added: `dev-scripts\run-core-tevi.bat` (existing, port 7778) / `run-core-tevi2.bat` (new,
    port 7779). **Live two-instance testing found and fixed a real bug, now confirmed working**:
    a peer's ghost went permanently invisible (not merely hidden) after the traveling player
    returned to a zone — root cause was `CreateRealGhostVisual` cloning a live character's
    visual hierarchy mid-transition, inheriting a disabled `basesprite` renderer with nothing to
    ever re-enable it. Fixed (`basesprite.enabled` forced true on recreate) and live-confirmed
    by the user with normal cross-area filtering restored — see `verified.md` and the
    `pitfalls.md` entry under "Level/scene transitions invalidating cached references." The
    relay-auto-reconnect gap and stale-binary issue that complicated the first test attempt are
    both resolved (see the ADR above).
  - **Docs**: this entry, all three ADRs above, and the `pitfalls.md`/
    `adapters/_template/PROTOCOL.md` updates (Pseudoregalia added to the adapter list, `extras`
    documented as load-bearing, `orientation` shown as opaque any-JSON, a peer-controlled-data
    warning added, plus the TEVI ghost-invisibility entry) are done.
  - **Not started**: live in-game verification of Pseudoregalia's despawn-visual/area-transition
    behavior specifically (general spawn/follow/animate already confirmed) and Emerald's
    connect/retry/receive paths — per `CLAUDE.md`, nothing above goes in `verified.md` until
    watched happening on screen.

## Go networking layer (2026-08-11)

Built and tested ahead of the BizHawk blocker, since it doesn't require a game or emulator:

- `internal/transport` — real NDJSON-over-TCP framing (`Dial`/`FromConn`, `Send`, lifecycle
  callbacks). 3 tests.
- `internal/relay` — a real `Server`: hello/welcome handshake, room/roster tracking, forwards
  `state` to the rest of a room, broadcasts `join`/`leave`, rejects a mismatched `game_id` per
  room. `cmd/meshghost-relay` runs it. 4 tests.
- `internal/bridge` — added envelope framing so `local_state`/`render_remote`/
  `despawn_remote` are distinguishable on the wire (was missing from the Phase 0 skeleton).
- `internal/core` — a real `Core`: relay handshake, per-remote interpolation buffer (linear
  position lerp, opaque fields held from the older sample, clamped at buffer edges — no
  extrapolation), and a bridge listener where each adapter frame call triggers forwarding
  local state out and pushing interpolated `render_remote`/`despawn_remote` back. `cmd/
  meshghost` runs it. 9 tests.
- Verified beyond `go test`: built both binaries, ran a real relay + two real core processes,
  and drove one over a raw TCP socket standing in for an adapter — confirmed `render_remote`
  arrived at the other side with correct data. This is not a Phase 3 completion (see above)
  because no real adapter and no on-screen ghost were involved, but it is real evidence the
  plumbing works end-to-end.
- What's still missing before this layer is exercised for real: a BizHawk Lua adapter that
  dials the bridge and speaks `local_state`/`render_remote`/`despawn_remote` — that adapter is
  Phase 2+ work and needs Phase 1's memory addresses first.

## Update guidance

- Update this file whenever the active phase changes.
- Keep entries short; this is a one-screen summary, not a log.
