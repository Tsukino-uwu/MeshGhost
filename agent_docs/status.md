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
  `client`/`server` sections, `run-client.bat`/`run-server.bat`, and `games/<publisher>/<game>/`
  mirroring `adapters/`. TEVI now ships in that same zip, marked experimental — its
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
- `Current focus:` **Phase 7 progressed through 7.1–7.5 across several sessions; as of
  2026-08-13 the C++ rewrite has a working hijack-based ghost that follows the player smoothly
  and survives real level transitions, confirmed live.** Full record in
  `agent_docs/phases/phase7.md`; short version:
  - **The old Lua-path blocker is gone.** The private `Re-UE4SS/UEPseudo` submodule access
    (`agent_docs/phases/phase7.md`'s 7.2) turned out to be gated by linking a GitHub account to
    an Epic Games account (confirmed via `UE4SS-RE/RE-UE4SS` issue #577) — the user did that
    2026-08-13 and the submodule cloned immediately after. The C++ mod
    (`adapters/pseudoregalia/MeshGhostPseudo`) now builds and runs.
  - **7.5's original blocker (the vendored LuaSocket receive-corruption bug) is resolved by
    switching to real C++ networking** (`Mod/src/BridgeClient.cpp`, plain Winsock2) — confirmed
    live side-by-side against the still-corrupting Lua path: 0 malformed lines out of 6000+ vs.
    ~98% corruption on the identical connection at the identical moment.
  - **Ghost spawning hit a second, harder wall: no working way was ever found to destroy an
    actor spawned at runtime on this build** (`K2_DestroyActor()` silently no-ops — confirmed via
    a `GetWorld()` readback showing the "destroyed" actor still fully alive). Every spawned ghost
    left behind a real `LowLevelFatalError: Fatal world leaks detected` crash on the next level
    transition. **Fixed by redesigning to hijack an already-existing level prop
    (`StaticMeshActor`) instead of spawning anything** — since nothing new is ever created,
    nothing ever needs destroying.
  - **A second, subtler bug then surfaced: the hijacked ghost followed correctly for a while,
    then visually froze, every run, despite position data staying provably correct on every
    logged tick.** Root cause, found by reading UE4SS's own source rather than guessing further:
    `CppUserModBase::on_update()` runs on UE4SS's own internal ~5ms polling thread
    (`UE4SSProgram.cpp`: `ProfilerSetThreadName("UE4SS-UpdateThread")`), never the real Unreal
    game thread — every actor write was landing in memory but never reaching the renderer. Fixed
    by moving all actor reads/writes into a `RegisterEngineTickPostCallback` hook instead (the
    real game thread). **Confirmed live 2026-08-13**: sustained, uninterrupted following. See
    `agent_docs/pitfalls.md`'s new "UE4SS C++ mod threading" section for the transferable lesson.
  - **Not yet done**: the camera fight-back hook (Phase 7.4's other proven fix, not yet ported to
    C++); a real animated player-model ghost (a `StaticMeshActor` can only ever be a rigid,
    non-animated stand-in — needs either hijacking an existing skeletal/animated actor, if a safe
    one exists, or returning to spawn-based ghosts with a real fix for the destroy problem, e.g.
    the `Engine.VerifyLoadMapWorldCleanup.Severity.Shipping 0` console-command suppression
    explored but not completed this session); a separate, not-yet-root-caused `Fatal Error!`
    crash (crashdump, not `LowLevelFatalError`) observed once on game exit.

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
