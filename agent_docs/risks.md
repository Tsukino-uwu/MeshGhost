# Risks and assumptions

## Current assumptions

- The core/adapter/relay split, with an out-of-process Go core, is the right long-term
  architecture (see `agent_docs/architecture.md` ADR on the Go decision).
- A replayable JSON snapshot schema is sufficient for the first two target games.
- Pokémon Emerald can expose local player position, area, and basic animation state from
  BizHawk — not yet confirmed, Phase 1's actual purpose.
- Lua overlay rendering (`gui.drawImage`) is the fastest practical approach for Emerald ghost
  drawing, and won't visibly flicker once the tick model in `contract.md` is implemented
  correctly (redraw the whole remote-ghost set every frame, not on receipt).
- **Closed 2026-08-12 (Phase 6 start):** TEVI's engine tooling assumption is confirmed, not
  analogized. TEVI is Mono, not IL2CPP — `TEVI_Data\Managed\Assembly-CSharp.dll` present, no
  `GameAssembly.dll` anywhere in the install, `doorstop_config.ini` has a `[UnityMono]` section.
  Re-confirmed against the current on-disk build (`TEVI.exe` 2026-07-16) after updating, not just
  the original April-2025 check. BepInEx/Harmony tooling applies directly; see
  `agent_docs/environment.md`'s Unity/TEVI section and `agent_docs/licensing.md`.
- **Closed 2026-08-11 (Phase 5.5):** every Emerald finding through Phase 2 had only been tested
  on a male save. Re-verified live on a real female-character save (`gSaveBlock1Ptr`,
  `gPlayerAvatar`, `gObjectEvents`, `gSprites`, `gSpriteCoordOffsetX/Y` all confirmed correct —
  see `agent_docs/verified.md`'s Phase 5.5 Step 4 entry) — no longer an open risk. Running
  specifically wasn't exercised on that save (no Running Shoes yet, a save-progression limit,
  not an address concern).
- **Closed 2026-08-11 (Phase 5.5):** player appearance (gender) is now in the schema, as
  `extras.gender`, read from `gSaveBlock2Ptr->playerGender` and confirmed live rendering the
  correct Brendan/May sprite for a remote on both a male-save and a female-save client. See
  `agent_docs/phases/phase5_5.md` and `agent_docs/verified.md`.

## Known risks

- Changing the adapter contract after Phase 5 may create compatibility issues across
  already-built adapters.
- The TEVI and Pseudoregalia targets may require substantially different adapter behavior
  than Emerald — the brief's own estimate is 60–70% new work for the second game, ~50% for
  the third.
- BizHawk Lua's socket support may be slower or more limited than expected for real-time
  ghost rendering once the adapter is calling out to an out-of-process Go core every frame
  (see the tick model in `contract.md` — chatty by design, cost unverified at 60fps).
- Relying on a single emulator version or toolchain may create setup drift between sessions.
- Undocumented game state or menu/camera edge cases can break ghost placement or crash the
  adapter's assumptions about `get_local_state()`'s return shape.
- **Licensing exposure**: `pokeemerald` carries no LICENSE file (see `agent_docs/licensing.md`)
  and SilklessCoop is restrictively licensed. Both are permitted as read-only fact sources,
  never as copied code — the risk is a future session forgetting that distinction under time
  pressure.
- **macOS distribution friction**: an unsigned Go binary will trip Gatekeeper on first run.
  Not a blocker for early phases, but worth planning for before a public release.
- **No-auth relay window**: Phases 3–4 run without authentication (see the relay-auth ADR).
  Anyone with the address can join during that window. Acceptable for a friend-shared
  IP:port, not for anything posted publicly, until room codes ship.
- **Archipelago coexistence, confirmed with a real gap**: tested 2026-08-11 with the real
  `connector_bizhawk_generic.lua` against a real `.apemerald`-patched ROM (see
  `agent_docs/verified.md`). Two scripts coexist fine, no performance difference, and
  position/map (`gSaveBlock1Ptr`-relative) reads are unaffected. But `gPlayerAvatar`/
  `gObjectEvents` (fixed EWRAM addresses) read as invalidated garbage under the patch — the
  patch's own code/data insertion shifts what's at those addresses, unlike the pointer-based
  SaveBlock1 fields. Concretely: `flags`, `runningState`, and `facingDirection` cannot be
  trusted when Archipelago is present. Planned mitigation (not yet built, deferred until after
  Phases 2–4 prove the vanilla path, since position/map already syncs correctly regardless of
  the patch and the ghost isn't blocked by this):
  - **Facing**: derive it from the delta between consecutive position reads (`dx`/`dy`,
    tile-grid, no diagonals) instead of reading `facingDirection`. Hold the last known facing
    while stationary. Make this the *only* code path (not a conditional fallback triggered by
    detecting "weird" values) — garbage-detection is itself fragile against a different patch
    returning plausible-but-wrong data, and there's no accuracy lost by not reading the raw
    field even when it would be valid.
  - **Walk/run/idle**: no good proxy identified yet. Candidate: infer from tiles-per-second
    (frames between position changes), since Emerald's walk and run speeds are different fixed
    frame-counts-per-tile — but this is an unverified hypothesis, not a known fact, and needs
    its own on-screen verification pass (vanilla first, then patched) before it can be trusted
    or written into `verified.md`, per the same "no addresses/facts from memory" standard as
    everything else in this project.
  This is also the concrete argument for keeping the read-only default (see the depth ladder
  in `plans.md`): two readers never race, but a future memory-*writing* feature could race
  Archipelago's own writes.
- **No game-version check between peers, surfaced by TEVI (Phase 6)**: `hello` carries `game_id`
  (e.g. `"tevi"`) but nothing identifying the game's *version* or installed DLC. Emerald sidesteps
  this because the ROM is a fixed artifact players share by hash; TEVI updates via Steam and has
  active DLC (the randomizer author was still adding DLC support as of June 2026). Two peers on
  different TEVI versions, or one with DLC and one without, will connect and exchange state
  happily but may disagree about what a given `area_id` (scene name) means, or one may reference a
  scene the other doesn't have. Not yet designed: whether this needs a version field in `hello`
  (a contract revision) or is left as a "both players should be on the same version" operational
  note. Surface this at Phase 6 rather than silently designing around it.
- **BepInEx/Harmony coexistence with an already-installed mod, surfaced by TEVI (Phase 6)**: this
  machine's TEVI already runs `Tevi_Randomizer` (the Archipelago integration mod) under the same
  BepInEx. Same shape as the Emerald/Archipelago coexistence risk below: if the randomizer
  Harmony-patches the same methods MeshGhost's adapter wants to read, the two could conflict.
  Mitigation planned the same way — confirm the position read works both with the randomizer
  enabled and disabled, prefer reads that survive patching, record which was tested in
  `verified.md`.
- **Reserved-but-unbuilt contract fields going stale**: the `features` field and the `event`
  message type (`agent_docs/contract.md`, Extensibility section) are documented now and
  implemented never, until something needs them. The risk is a future session building
  routing for them speculatively, before any adapter actually sends an event — that produces
  code with no on-screen consumer, which this project's own verification standard treats as
  unproven. The mitigation is procedural: don't implement the event plane until a specific
  Tier 3 feature (see `plans.md`) is approved via its own ADR and has a concrete adapter
  ready to use it.

- **Blueprint-vs-C++ readability, surfaced at Phase 7 start**: Pseudoregalia is largely
  Blueprint-driven (per `adapters/pseudoregalia/README.md`'s brief note and no `.pdb`/managed
  assembly equivalent to decompile the way TEVI's `Assembly-CSharp.dll` was). Player state may
  only be reachable by reflection/property-name lookup through UE4SS rather than a fixed,
  named field the way `pokeemerald`'s C structs or TEVI's decompiled C# fields were. Highest
  single source of uncertainty in Phase 7; the 7.1 Lua probe exists specifically to resolve
  this empirically before committing to the C++ adapter's design.
- **No clip-name animation playback in UE5, surfaced at Phase 7 start**: TEVI's remote ghost
  works by calling `Animator.Play(clipName)` on a cloned GameObject using the real Animator
  clip name sent over the wire. UE5 has no direct equivalent for a cloned actor driven by an
  AnimBP/Blueprint-based character — likely needs either a montage-based approach or a
  simplified driven AnimBP. Unresolved design question, not just an implementation detail;
  expect this to be the hardest single task in Phase 7, not the local-state read.
- **UE4SS version drift already observed mid-Phase-7 (2026-08-12)**: the user updated their
  local UE4SS from v2.5.2 Beta to v3.0.1 Beta mid-session, following a Mar 2026 update to
  `pseudoregalia-archipelago`'s own `RE-UE4SS` submodule pin. Confirms the environment can
  drift out from under an in-progress phase without warning — re-check `environment.md`'s
  UE4SS version before resuming any Pseudoregalia work in a new session, the same standard
  applied to TEVI's Steam updates.
- **UE4SS mod-load-order coexistence with `AP_Randomizer`, surfaced at Phase 7 start**: same
  shape as TEVI's BepInEx/Harmony-vs-`Tevi_Randomizer` risk below — confirm the adapter's
  reads/hooks work with `AP_Randomizer` both enabled and disabled, record which was tested.
  **Confirmed live, both directions, 2026-08-12**: a mismatched `UE4SS.dll` build (83 commits
  ahead of the installed one) broke `AP_Randomizer` outright (`0x7f`, a missing exported
  procedure) — not a theoretical risk, an actual observed break, immediately rolled back and
  re-confirmed working. Any future UE4SS runtime change on this machine needs the same
  before/after check, not just "it built."
- **Building a UE4SS C++ mod requires a private submodule this project has no access to,
  found 2026-08-12**: RE-UE4SS's own C++ mod guide builds the engine from source via CMake,
  and its core `UE4SS` target hard-depends on `deps/first/Unreal` (`Re-UE4SS/UEPseudo`),
  confirmed private (`gh api` 404, SSH host-key-verification failure). No prebuilt import
  library ships in any official release asset (checked both the plain runtime zip and the
  "zDEV" package — DLL and PDB only, no `.lib`). This blocks the "C++ for the shipping
  adapter" decision from earlier in Phase 7 unless UEPseudo access is granted — see
  `agent_docs/phases/phase7.md` for the full investigation. Likely explanation: this is
  probably the same Epic-Games-account-linked-to-GitHub gate Epic uses for Unreal Engine's
  own source access on GitHub, applied to RE-UE4SS's own reflected-headers submodule — not
  independently confirmed, a plausible inference from a web search, not a fact to build on.
- **UE4SS Lua *does* expose `package.loadlib`, reopening the socket question, found
  2026-08-12**: contradicts the earlier "Lua has no socket path" reasoning (Phase 7's
  adapter-language decision), which was based only on the *absence* of a first-party socket
  library, not on `loadlib` being disabled. `MeshGhostSocketProbe` Stage 1 confirmed
  `type(package.loadlib) == "function"` live. Untested and risky: UE4SS's Lua is statically
  embedded in `UE4SS.dll`, not a separate `lua54.dll` the way BizHawk's NLua host is — loading
  MeshGhost's already-vetted `lua54.dll`/`socket-windows-5-4.dll` pair here could crash the
  game rather than fail cleanly if the two compiled Lua runtimes' `lua_State` layouts don't
  match, unlike BizHawk where there was only ever one real Lua runtime involved.
  **Downgraded 2026-08-12**: Stage 2 (`adapters/pseudoregalia/probe_socket/Scripts/stage2_loadlib.lua`)
  ran live — preload, `loadlib`, `luaopen_socket_core()`, and `socket.tcp()` create/close all
  succeeded with no crash, `AP_Randomizer` unaffected, extended play session stable (see
  `agent_docs/verified.md`). The `lua_State`-mismatch risk hasn't corrupted anything through
  object creation. Still open: a real `bind`/`connect`/send/receive round trip is untested and
  is where an ABI mismatch would most plausibly surface (e.g. buffer/struct handling under
  actual I/O, not just table construction) — treat as unresolved until that's tried.
  **Resolved 2026-08-12**: Stage 3
  (`adapters/pseudoregalia/probe_socket/Scripts/stage3_roundtrip.lua`) did a real
  connect/send/receive round trip against the actual bridge protocol — a real
  `meshghost.exe` core, a real relay loopback echo, and a real `render_remote` frame read back
  successfully inside UE4SS's embedded Lua. Extended play session stable, no crash/lag/
  weirdness (user-confirmed, see `agent_docs/verified.md`). The `lua_State`-mismatch risk is
  now considered closed for this specific vendored `lua54.dll`/`socket-windows-5-4.dll` pair
  against this UE4SS build (`v3.0.1 Beta`/SHA `733e5969`) — a **Lua-only shipping adapter** is
  viable, no C++/UEPseudo build required.
- **Spawning the player's own gameplay Blueprint as a placeholder ghost physically dragged the
  player, found 2026-08-12**: `adapters/pseudoregalia/probe_ghost/Scripts/main.lua` spawned a
  second instance of `BP_PlayerGoatMain_C` 150 units from the player. The user was physically
  dragged/pulled toward another location at high speed immediately on spawning in, until dying.
  Working theory (not confirmed): the spawned instance is fully physically simulated —
  collision, gravity, movement — and its capsule pushing against the real player's every physics
  tick as it fell/slid could produce this. This is the exact risk 7.6's design already named
  ("collision/input/gameplay stripped"), but it showed up as a real safety issue (forced
  movement, death) earlier than planned, at 7.4, before anything had been stripped. See
  `agent_docs/verified.md` and `agent_docs/phases/phase7.md`. Mitigation going forward: don't
  spawn the real gameplay Blueprint as a placeholder at all — follow TEVI's own 6.3 precedent
  (a simple, harmless placeholder shape, not a player clone) until collision/physics/input are
  deliberately and verifiably stripped.

## Mitigations

- Keep the contract minimal, and validate it early with a fake adapter (Phase 5).
- Record confirmed facts in `agent_docs/verified.md` and treat everything else as
  provisional — including this file.
- Keep transport abstract and swap-friendly so the relay layer can evolve past no-auth
  without touching the core or any adapter.
- Use phase-based validation to catch contract or rendering issues early rather than after
  a second game is underway.
- Track toolchain versions in `agent_docs/environment.md` as soon as Phase 1 starts.
- Re-check a project's license (`agent_docs/licensing.md`) before treating it as anything
  more than a documentation reference.
