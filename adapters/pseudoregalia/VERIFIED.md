# Verified facts — Pseudoregalia

Facts about this adapter and this game, **confirmed by watching a running game**. Split out of
`agent_docs/verified.md` on 2026-08-25, verbatim and in their original order; that file had
reached 10,174 lines with four games and the Go side interleaved chronologically, and was the most
frequently touched file in the repo.

**The gate is unchanged, and it is the strict one.** Nothing adapter- or game-side on the
BASE/VANILLA game goes in here until **the user has confirmed it on screen** — no probe log,
console read or screenshot of yours substitutes, and neither does a clean test run. Measurements
that are not yet confirmed live in this adapter's own [`UNVERIFIED.md`](UNVERIFIED.md) (created
2026-08-27 — this paragraph used to say the adapter had no queue of its own, and `preflight.ps1`
now requires one per adapter). A patched ROM (Archipelago and similar) is the agent's to confirm
visually; say so in the entry. The full rule is in [../../CLAUDE.md](../../CLAUDE.md).

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

Sibling registers: `../tevi/VERIFIED.md`, `../emulator/pokemon/crystal/VERIFIED.md`, `../emulator/pokemon/emerald/VERIFIED.md`.

## Index — every entry in this file

**Titles only, one line per entry, and `dev-scripts/preflight.ps1` fails if an entry is missing
from it.** Added 2026-08-25: this file is append-only and only grows, so without an index the
cheapest way to find a fact was to read the whole record. Now it is to read this list.

**Entries sit at two heading levels** — the earliest are `###` under "Confirmed facts", later ones
are `##` — and both are indexed. The levels are historical and are deliberately NOT normalised:
changing an entry's heading is a rewrite of the record, which is the one thing this file forbids.

**Adding an entry costs one line here.** That is the whole maintenance contract, and it is the
reason this is an index rather than a taxonomy — nothing can mechanically check that an entry is
filed under the right theme, but anything can check that it is listed.

- Phase 7.1: Pseudoregalia local player pawn/position/rotation/level read confirmed live via UE4SS Lua probe
- Phase 7.2 investigation: UE4SS runtime mismatch breaks AP_Randomizer; UE4SS Lua exposes package.loadlib
- Phase 7.2: vendored LuaSocket core loads and creates a socket inside UE4SS's embedded Lua
- Phase 7.2: real bridge-protocol round trip works over UE4SS's embedded Lua
- Phase 7.4: spawning the player's own Blueprint as a placeholder ghost physically dragged the player
- Phase 7.4: the collision theory was wrong — dragging was the script mutating the player's own live position
- Phase 7.4: fourth live run, live-reference fix in place, dragged identically
- Phase 7.4: root cause confirmed — BP_PlayerGoatMain_C auto-possesses on spawn
- Phase 7.4: placeholder ghost confirmed visible on screen — via a hijacked existing actor, not a spawned one
- Phase 7.4: placeholder ghost confirmed done — spawns, follows, survives level transitions, camera stays correct
- Pseudoregalia UEPseudo access unblocked, and the C++ hello-world mod builds and coexists with AP_Randomizer
- Pseudoregalia C++ mod reads real local-player position natively, tracking through a level transition
- Native C++ bridge networking has zero receive corruption, side by side against the Lua version's 98%
- C++ mod ghost render-freeze fixed: on_update() runs off the game thread, EngineTick hook doesn't
- C++ mod: spawn-based ghosts survive the game thread, and the camera fight-back fix works
- C++ mod: area-transition crash fixed by clearing the cached camera pointer before LoadMap
- C++ mod: ghost animation state (moveState/actionState/speeds/movementMode) mirrors correctly
- C++ mod: ghost facing-direction fix — vendored SDK marshaled FRotator as float on a UE5 game
- C++ mod: facing-direction fix also fixed ledge-grab, and exposed a pre-existing stuck-animation bug
- C++ mod: stuck-falling-pose fix — the earlier `landed?`/`jumped?` pulse attempt was never actually tested
- C++ mod: ledge-hang-stuck-forever fix — the pose was an Anim Montage, not a state-machine transition
- v0.2.1 release: bundled UE4SS runtime works clean, ghost renders on Pseudoregalia
- MeshGhostPseudo survives an AP_Randomizer reinstall that silently swaps the shared UE4SS runtime
- Pseudoregalia post-review-sweep rebuild, live confirmed
- Pseudoregalia despawn-visual and area-transition, live-verified via loopback
- Pseudoregalia bridge-disconnect ghost cleanup, found live and fixed
- Pseudoregalia ability field schema, mapped to every trending-page ability via a real reflection dump
- Pseudoregalia ability field live-value trace -- real values watched, not just names
- Dream Breaker weapon-visibility sync: shipped, live-tested, root cause still unresolved -- WeaponMesh cleared as a suspect
- Dream Breaker weapon-visibility sync: inversion test run -- same-local-save-data confound CONFIRMED
- Dream Breaker spawn-snapshot: cross-save property-value diff -- confirms fresh-read-at-spawn, doesn't yet find the visual lever
- Dream Breaker spawn-snapshot: WeaponMesh sub-properties are IDENTICAL across a genuine 0%/100% save comparison -- rules out the component entirely
- Dream Breaker weapon-visibility: animBPref cross-save diff finds the one real field; root cause identified and FIXED, confirmed live
- Outfit/costume sync: real lever found via live value-diff (VisualMesh.SkeletalMesh/SkinnedAsset), first sync attempt produces a T-pose
- Outfit/costume sync: T-pose FIXED via SetSkeletalMeshAsset, confirmed live
- Pseudoregalia ghost trail (afterimage) VFX: `Spawn After Image` call confirmed to work
- Pseudoregalia ghost trail (afterimage) VFX: real repeating trail CONFIRMED working
- Pseudoregalia trail-VFX UFunction hook: CRASHED the game — do not retry this approach
- Pseudoregalia ghost vs. local player, full property diff: NO master VFX gate; the real difference is possession
- Pseudoregalia empty-hand recall glow via `manageRecallIdleFX`: NEGATIVE — the pattern has a precondition
- Pseudoregalia trail (afterimage) COLOUR write: CONFIRMED working on the ghost
- Pseudoregalia blue ultra-hop trail does NOT come from `afterimageColor` — separate mechanism
- Pseudoregalia ghost hurtbox: `bCanBeDamaged=false` does NOT stop the melee-death bug
- Pseudoregalia wall-ride (cling gem) state: `moveState=4` is the marker, and it is ALREADY synced
- Pseudoregalia cling-gem (wall-ride) VFX on the ghost: CONFIRMED WORKING
- Pseudoregalia trail trigger rewritten to mirror the game's own `afterImagesToSpawn` — pipeline exact, but incomplete coverage
- Pseudoregalia plain-slide trail + ghost-sinks-into-floor: BOTH FIXED, from one capture
- Pseudoregalia: ENEMY damage to a ghost hurts and can KILL the real player — CONFIRMED
- Pseudoregalia Dream Breaker THROW animation: root-caused as a montage, FIXED via stock `Montage_Play`, confirmed live
- Montage mirror covers the whole game; ledge-climb-up lingering root-caused (the ghost restarts montages itself); crouch trail false positive fixed
- `attire-ui-overhaul` re-checked for the ultra/blue trail: NEGATIVE, it knows only one colour
- Ghost self-starts montages: PROVEN, and it is the state sync, not collision
- Every previously-untriggered player montage works on a ghost for free -- 8 of 8
- Bubble effect is a "Blink" Timeline on the pawn, NOT the afterimage system
- Bubble flash mirror WORKS — and a correction to the entry above it
- Pseudoregalia pole ROTATION syncs exactly — the apparent bug is a loopback artifact
- Release-folder loopback script works with a real game attached
- Pseudoregalia thrown Dream Breaker: full hand → flight → bounce → ground sync, CONFIRMED LIVE
- Pseudoregalia: a ghost's thrown sword cannot be picked up by the local player
- Pseudoregalia empty-hand recall glow: FIXED by spawning the effect directly, confirmed live
- Pseudoregalia: use-after-free crash on level transition after a throw, FIXED and confirmed live
- Pseudoregalia thrown Dream Breaker: full hand → flight → bounce → ground → pickup, CONFIRMED LIVE
- Pseudoregalia empty-hand recall glow: FIXED by spawning the effect directly, confirmed live
- Pseudoregalia: use-after-free crash on level transition after a throw, FIXED and confirmed live
- Pseudoregalia ultra-hop BLUE trail: source identified after being parked as unsolvable
- Pseudoregalia afterimage trail regression: caused by this project's own diagnostics, FIXED
- Pseudoregalia colour-only afterimage observation does NOT regress the slide trail
- Pseudoregalia ultra-hop BLUE reaches the ghost — but attributed one burst late
- Pseudoregalia ultra hop fires NO local afterimage trigger — the real cause of the late blue
- Pseudoregalia ultra blue now lands on the ultra — two remaining defects, one diagnosed
- Pseudoregalia double-blue: ONE image counted twice, not two spawned (2026-08-16)
- Pseudoregalia ultra BLUE afterimage: CONFIRMED CORRECT ON SCREEN
- Pseudoregalia ghost trails where the real player does not — reconstructed trigger, not the game's
- Pseudoregalia ghost afterimage density now matches the player — observation-driven trigger
- Pseudoregalia afterimage/trail sync: COMPLETE — player and ghost indistinguishable
- Pseudoregalia loopback still works after the 2026-08-16 project-wide refactor
- Live: all three transports confirmed on screen with Pseudoregalia — 2026-08-16
- 2026-08-16 — Autostart, Go side: `-exit-with-pid`, log append, config visibility
- 2026-08-16 — Autostart works live on Pseudoregalia (user-watched)
- 2026-08-16 — Autostart reuses an existing core, and never kills one it didn't start (user-watched)
- 2026-08-16 — Autostart works under Proton (Linux tester, with logs)
- 2026-08-16 — Pseudoregalia 7.7: two real players, two machines, online (user-watched)
- 2026-08-16 — Pseudoregalia pole rotation is correct (two-machine session)
- 2026-08-16 — The Pseudoregalia camera fight-back is what takes the camera
- 2026-08-16 — Camera fight-back removed; the camera is correct without it
- 2026-08-16 — The through-walls outline is custom depth, and the ghost inherits it
- 2026-08-16 — A ghost brings its own camera rig, and that is what took the camera
- 2026-08-16 — Ghosts no longer render through walls (user-watched)
- The slide mesh offset is the engine's crouch path, and it is -(capsuleHalf + 1) — 2026-08-16
- Following it: the ghost fights back — 2026-08-16, same session
- Three ways to pose a ghost's crouch, all NEGATIVE — 2026-08-16
- The Pseudoregalia mod reconnects to a core started AFTER the game — 2026-08-17
- Slide/crouch pose: the render-Z bandage is GONE, replaced by the game's own path — 2026-08-17
- What the mechanism actually is
- The two findings that actually cracked it
- Dead ends, so nobody repeats them
- 2026-08-17 — Audit pass: three earlier entries superseded by later ones in this same file
- Pseudoregalia: killing a ghost leaves the real player at 0 health with no health bar
- The 2026-08-17 online-primitives work does not regress the cosmetic path (Pseudoregalia)
- Session resumption, clock sync and the capability scope split, confirmed against real binaries
- Pseudoregalia: a ghost's slide pose CYCLES instead of holding, and it is not a latency problem
- Pseudoregalia: a held slide re-triggers every ~600ms, and the capsule really does stand up between repeats
- Pseudoregalia: a hard crash mid-session, and the discovery that we ship six unnecessary UE4SS mods enabled
- CONFIRMED ON SCREEN 2026-08-28 — relay-side area filtering is invisible in Pseudoregalia, both halves
- CONFIRMED ON SCREEN 2026-08-28 — two real Pseudoregalia instances, and the three bugs that were between them
- The loopback offset manufactures positions real multiplayer never produces
- 2026-08-17 — The double pause menu recurred, and this time did NOT crash
- 2026-08-17 — A relay that dies leaves every ghost frozen in place, for up to 60 seconds
- 2026-08-17 — Mid-area despawn destroys the ghost cleanly, and a peer's ghost is genuinely the PEER
- 1. The despawn path the park was written for finally ran, and destroy handled it
- 2. A peer's ghost shows the PEER's appearance, not the local player's
- CORRECTION: the Pseudoregalia bridge-loss despawn path does exist, and always did (2026-08-18)
- CORRECTION: ghosts do NOT spawn with collision disabled — the camera fix was the rig, not collision (2026-08-18)
- CORRECTION: the recall-glow and throw-crash entries above each appear TWICE (2026-08-25)
- 2026-08-27 — The player's health bar was the GHOST'S OWN HUD, drawn over it (user-confirmed)
- 2026-08-27 — The ghost's shadow was glued to its model because one spring arm was 100 long instead of 5000 (user-confirmed)
- 2026-08-27 — The heal's world-spawned VFX were being placed at the ghost's feet; the game puts them at the top of the model (user-confirmed)
- 2026-08-27 — A ghost's attack could damage the player, and the fix was the game's own already-hit list (user-confirmed)
- 2026-08-27 — The mod starts its own core: a closed port that never refuses, and the port sweep that could not see it (user-confirmed)
- 2026-08-27 — The charged-attack glow mirrors onto a ghost; what is missing is the projectile ACTOR (user-confirmed)
- 2026-08-27 — A ghost's ranged projectile is mirrored as an EFFECT, after an actor handle crashed the game (user-confirmed)
- 2026-08-27 — Death, the pit, the hurt reaction and the respawn: four effects, found by measuring rather than naming (user-confirmed)
- 2026-08-27 — Pseudoregalia declared FEATURE COMPLETE by the user, with the scope written down
- 2026-08-27 — A ghost's afterimage outline is at ZERO frames: refused at the enable call itself, not stripped after
- 2026-08-27 (late session) — A hard crash on "retry last save": the VFX mirror's component map outlived its level (user-confirmed)
- 2026-08-27 (late session) — A hard crash on starting a NEW SAVE: the camera fallback pointer, never cleared, dereferenced two levels later (user-confirmed)
- 2026-08-27 (late session) — The ghost flinched on every save-file swap; and the carried-over health is the GAME's, proven by the user's control run (user-confirmed)
- Nametags: a peer's name renders above their ghost, both join orderings (2026-08-28)
- Nametag COLOUR, as a plate the name stands on — three peers, three cases (2026-08-29)
- Landing dust on a ghost: the echo loop, the swallowed repeats and the mid-body height, all three fixed (2026-08-29)
- 2026-08-30 — the three ghost-light bugs are fixed, and the fixes ship as defaults
- 2026-08-30 — a ghost's FACING is interpolated, and the choppy fast spin is gone
- 2026-09-01 — the reset-to-save crash is FIXED, and its cause was the nametag's stale pointers
- 2026-09-01 — the 2026-08-30 per-ghost performance win, restated here now that its crash is closed
- 2026-09-01 — 150 peers live: stable, recoverable, and the wire is no longer the ceiling
- 2026-09-01 — the melee slash arc mirrors, user-confirmed: *"the slash works"*
- 2026-09-01 — the thrown sword, rebuilt on a component we own, and user-confirmed end to end
- 2026-09-01 (evening) — the send-rate floor MEASURED on screen, the 15-vs-20 blind test, and the interp-per-link rule
- 2026-09-04 — a display name with quotes in it reaches the nametag WHOLE
- 2026-09-04 — a zip of two recordings plays as two ghosts
- Pseudoregalia: 300ms interp at the 15Hz relay on the 60/25/2/2 proxy, on the fixed relay (2026-09-02)
- Pseudoregalia: 450ms interp at 15Hz on the WORST-CASE proxy (NA<->EU ping plus bad wifi), the ladder climbed on the fixed relay (2026-09-02)
## Confirmed facts

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
  real `meshghost.exe` core (`dev-scripts/run-core-pseudoregalia.bat` — renamed to
  `run-core-pseudoregalia-online.bat` since; pointer corrected 2026-08-27) with
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
  `packaging/release/games/pseudoregalia/ue4ss-runtime/` *(pointer corrected 2026-09-01: the
  runtime is now staged in-tree at
  `packaging/release/games/pseudoregalia/pseudoregalia/Binaries/Win64/ue4ss/`; the provenance
  file `ue4ss-runtime-built-from.txt` keeps the old level)*: different size (16,240,640 vs.
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
  `LOOPBACK_GHOST_OFFSET_X` in Pseudoregalia's `MeshGhostPseudo/Mod/src/Plugin.cpp` (path
  completed 2026-08-27; ten other citations in this file already carried the full form).
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

Setup: plain relay (no `-loopback`), core via `dev-scripts/run-core-pseudoregalia.bat` (now
`run-core-pseudoregalia-online.bat`; pointer corrected 2026-08-27), and a fake
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

### CORRECTION: the Pseudoregalia bridge-loss despawn path does exist, and always did (2026-08-18)

- Date: 2026-08-18
- Confirmed by: my own reading of `Plugin.cpp`/`Plugin.hpp`. No new runtime facts and no visual
  claim, so this needs no user watching under `CLAUDE.md`'s rule. This file is append-only, so the
  wrong entry cannot be edited out and would otherwise keep reading as live.
- **What was wrong.** The 2026-08-16 transport entry (it stayed in
  [../../agent_docs/verified.md](../../agent_docs/verified.md) at the 2026-08-25 split) records, under "Suspected, not
  confirmed": *"the Pseudoregalia mod appears to have no despawn-on-bridge-loss path — a search
  found no disconnect callback and no ghost-map clear"*, and then plans the fix. **The path was
  already built and confirmed live on 2026-08-14** — two entries far earlier in this same file
  ("Pseudoregalia bridge-disconnect ghost cleanup, found live and fixed", and the entry above it
  where the user watched the ghost disappear on client close) describe building it and watching it
  work.
- **Why the search missed it.** It looked for a *disconnect callback*. There is none, by design:
  `on_update()` **polls** `bridge->is_connected()`/`is_ready()` every tick and acts on the
  connected -> disconnected **edge** (`bridge_was_connected`), arming
  `bridge_disconnect_cleanup_pending` under `state_mutex`. `game_thread_tick()` drains that flag
  and calls `release_all_ghosts_parked(STR("bridge disconnected"))` — the split exists because the
  actual release must happen on the game thread. Grepping for a callback registration finds
  nothing; grepping for the symbol finds all of it. **The general lesson: absence of a match is
  evidence about the search term, not about the code** — which the original entry said in the same
  breath as drawing the conclusion anyway.
- **One detail in the superseded plan is also wrong.** It insists the fix is `release_all_ghosts`
  and *"NOT moving the ghosts somewhere out of sight"*. What shipped, and what was watched
  working, is `release_all_ghosts_parked`, which parks — the same thing a real `despawn_remote`
  does. The parking-is-unsafe reasoning it cites applies to a ghost whose *level has already been
  torn down* (the `LoadMap` case), which is not the bridge-loss case.
- **Consequence:** the corresponding open item has been deleted from `status.md`. Nothing is open
  here.

### CORRECTION: ghosts do NOT spawn with collision disabled — the camera fix was the rig, not collision (2026-08-18)

- Date: 2026-08-18
- Confirmed by: my own reading of `Plugin.cpp`. No visual claim, so no user watching is needed.
- **What was wrong.** Two 2026-08-16 entries above reason from *"ghosts spawn with collision
  disabled now"* / *"most likely because ghosts now spawn with collision disabled"* — offered as
  the reason a camera-rig problem stopped reproducing, and as grounds for expecting a ghost to no
  longer trigger overlap volumes.
- **`GHOST_COLLISION_ENABLED` is `true`** (`Plugin.cpp:620`) and has been since 2026-08-15. It was
  never flipped off. Collision is *shipped on*, and is the subject of its own still-open item (a
  player killing a ghost leaves them respawning at 0 health — see the 2026-08-17 entry).
- **The real mechanism, already recorded correctly elsewhere in this file**: a ghost brings its own
  `BP_PlayerCam_C` camera rig, identified by its `OwningActor`, and *that* is what took the camera
  — see "A ghost brings its own camera rig, and that is what took the camera" (2026-08-16) and the
  2026-08-17 audit entry that supersedes the fight-back heading. The enemy-targeting half was fixed
  by re-typing the ghost's capsule as `WorldDynamic` (`call_set_collision_object_type`), which
  changes what *queries* see, not whether collision exists.
- **Why it matters beyond tidiness:** any future reasoning of the form "a ghost cannot trigger an
  overlap volume, so that mechanism is dead" is built on a premise that is false. A ghost has
  collision and can.


### CORRECTION: the recall-glow and throw-crash entries above each appear TWICE (2026-08-25)

- Date: 2026-08-25
- Confirmed by: the agent, mechanically, while splitting `agent_docs/verified.md` per game. No new
  runtime facts and no visual claim, so this needs no user watching under `CLAUDE.md`'s rule.
- **What is wrong.** A block of this file was appended twice, in rewritten form, and the two copies
  **contradict each other**:
  - `### Pseudoregalia empty-hand recall glow: FIXED by spawning the effect directly, confirmed
    live` at **line 2150** and again at **line 2242**.
  - `### Pseudoregalia: use-after-free crash on level transition after a throw, FIXED and confirmed
    live` at **line 2181** and again at **line 2270**.
- **Which one is right.** The **later** copy of the recall-glow pair. The earlier one describes the
  glow being attached to the ghost's **root**; the later one has it on **`WeaponMesh` at zero
  offset**, which is what actually shipped and what the code does. Read the later copy; the earlier
  is superseded.
- **Why both are still here.** This file is append-only, and deleting one would be the only real
  violation of that rule in the whole per-game split. They are kept, and this entry is the
  annotation that says which to believe — the same treatment any superseded entry gets.
- Notes: these were the **only** duplicate heading pair in the 10,174-line original; `sort | uniq
  -d` over its headings returned exactly these two lines, which is a live check if the file is ever
  audited again.

## 2026-08-27 — The player's health bar was the GHOST'S OWN HUD, drawn over it (user-confirmed)

- **User-confirmed on screen**: *"this fixed the health bar/UI stuffs, i can see it visually go
  down/up now"*, after a session where the bar sat permanently full while damage, death and healing
  all really happened.
- **The fix**: call stock `RemoveFromParent` on the ghost's own `UI_HudRef` widget at spawn, before
  that reference is cleared. `Plugin.cpp`, under `GHOST_DECOUPLE_SHARED_STATE`.
- **The cause**: a ghost here is a clone of the player's own pawn class, so it runs the player's
  `BeginPlay` and **builds its own copy of everything the player owns**. It created a second health
  bar, initialised full, and added it to the viewport on top of the real one.
- **This adapter had already solved the same bug once, in a different component** — "A ghost brings
  its own camera rig, and that is what took the camera" (2026-08-16, above). The user made that
  connection themselves: *"maybe similar to how we had to decouple/remove the camera things?"* That
  is what turned a stalled investigation around, after two wrong fixes.
- **Two wrong fixes preceded it, and both failed the same way** — the durable lesson is
  **a reference is not the thing**:
  - Clearing the ghost's `As MV Game Instance Ref` did not decouple health, because any actor
    reaches the GameInstance singleton through `GetGameInstance()` regardless of a cached pointer.
  - Clearing `UI_HudRef` did not remove the health bar, because a widget's lifetime belongs to its
    **parent**, not its referrer -- the bar stayed on screen with nobody pointing at it.
  Both were confirmed to have actually applied (`cleared (was set)` in the log), so neither was a
  case of the fix not running. The theory was wrong, twice, in the same way.
- **What made it findable was a control experiment the user designed**: *"should we do a non ghost
  probe on losing/gaining health/current health? and then one with a ghost next to us?"* Run with
  no ghost, health displayed correctly; run with a ghost, the value was STILL correct and only the
  display was wrong. That pair is what proved the health STATE was never corrupted and sent the
  search to the display.
- Supporting measurement (agent-side, not a user confirmation): health is `CurrentHp` on the object
  the pawn holds as `As MV Game Instance Ref` -- max 80, 5 per pit fall. See `PLAYER_FIELDS.md`.

## 2026-08-27 — The ghost's shadow was glued to its model because one spring arm was 100 long instead of 5000 (user-confirmed)

- Date: 2026-08-27
- Observed: the user, after the fix: *"Shadow is fixed now, its following the ghost properly on the
  ground"*. Before it, reported twice: *"the shadow is still following right below the ghost's
  model, no matter if they are in the air or not it sticks to them instead of being 'below the
  ghost on the ground'"*.
- **The cause, and it is one number.** The pawn carries a `BlobShadow` StaticMeshComponent attached
  to a `SpringArm`, with `bDoCollisionTest=true` — so the ARM'S LENGTH is how far the shadow may
  fall before its trace finds floor. `TargetArmLength` is **5000 on the player** and was **100 on
  the ghost**, which is the class default: nothing ever set it there. 100 pins the shadow about
  that far under the model and no further, which is exactly the symptom, in the air included.
- **The measurement that showed it**, both sides in one log at the same tick:

  | | armLength | offset from actor, standing | offset mid-jump |
  | --- | --- | --- | --- |
  | Player | 5000.0 | -66.2 | **-808.2** — it reaches the floor |
  | Ghost | 100.0 | -66.2 | **-104.0** — pinned |

  The standing row is why it looked correct until the ghost left the ground: with floor right
  there, both arms find it.
- **The fix**: mirror the LOCAL player's own `SpringArm.TargetArmLength` onto the ghost's, every
  tick, sampled live rather than written as a constant (`GHOST_BLOB_SHADOW_ARM_MIRROR`). Same shape
  as the shipped capsule mirror: copy what the game is doing to the real player and let the engine
  do the rest, so a build that uses a different length is followed rather than broken.
- **A wrong fix came first, and the readback caught it before the user had to.** The census found
  exactly one shadow-shaped function on the pawn, `manageBlobShadow`, present on the ghost too, and
  the obvious move was to call it — "let the game do the work", which is right often enough here
  that it was worth trying first. It ran every tick (the log says so) and the ghost's arm still read
  100. The function is not what sets that value, or it takes an early branch on a pawn nobody
  controls. **The independent readback is what settled it**: the probe reports the arm length it
  reads, not the value we wrote.
- **How it was found, which is the part worth keeping.** The frame the user carried in from the
  previous session — *ask what component of yours the ghost also has, not what value to overwrite* —
  produced the census: every component-valued property on the ghost AND the player, in one log, at
  ghost spawn. `BlobShadow` was in the first run's output with its class, parent and flags. The
  first trace then measured the wrong thing (`RelativeLocation`, constant on both sides, because a
  spring arm moves its child through its own transform) — and **that null result was the useful
  one**: it said the position is not written, so the thing that moves it must be measured instead.
  World positions plus the parent's arm length were in the next run, and the answer was in the first
  jump.
- Notes: `bDoCollisionTest` was already `true` on both sides, so the ghost's collision setting was
  never implicated — an A/B against `GHOST_COLLISION_ENABLED` had been queued as the first move and
  would have cost a live cycle to clear nothing. The census made it unnecessary.

## 2026-08-27 — The heal's world-spawned VFX were being placed at the ghost's feet; the game puts them at the top of the model (user-confirmed)

- Date: 2026-08-27
- Observed: the user, after the third placement: *"it did the VFX healing thing properly now"*.
  Before it, three declines across the session: *"the ghost is still not doing the 'yellow ball'
  vfx when healing"*, *"healing is still missing the last VFX"*, and finally the one that named it
  — *"healing still don't show the 'yellow ball' at the top of the model when doing the
  animation"*.
- **The cause**: `NS_HealWave` and `NS_HealEndwave` are not attached to the player at all. A
  `VFX_WATCH` capture showed the real ones **owned by `WorldSettings`, `attach='<none>'`**, carrying
  a world coordinate — while the mirror spawned every row attached to a component of the ghost.
- **The number, recovered from the capture rather than guessed.** The effects' world positions
  against the player's own actor position in the same second:

  | Effect | World position | Offset from the player |
  | --- | --- | --- |
  | `NS_HealEndwave` | (4578.96, 4417.69, -422.85) | ≈ (0, 0, **+10**) |
  | `NS_HealWave` | (4570.51, 4466.97, -332.85) | ≈ (-8.5, +49, **+100**) |

  +100 above the actor origin is the top of the model — the user's own words for where the ball
  belongs. The feet are -66, so the second placement was about 165 units low: a whole character.
- **The fix**: world-spawned rows spawn unattached, at a height **observed live from the local
  player's own effect** — the mirror's proximity test already computed that offset every time one
  fired and was discarding it. The table's measured values (+100 / +10) remain only as the fallback
  for a peer who performs the action before the local player ever has. Horizontal offset is
  deliberately zero: the real one is in the performer's facing frame, and one sample cannot recover
  which way they were pointing, so it centres on the character rather than sitting confidently to
  one side.
- **Three placements, and the discipline that mattered was refusing to nudge the fourth by eye.**
  Attached to the capsule (mid-body) → declined. World-placed at the feet → declined. Two wrong
  placements in a row is `pitfalls/method.md`'s "two guessed fixes failing the same way is a
  signal", so the third came from the capture's own numbers plus a live observation, not from an
  offset chosen to look right.
- **What the failed attempts cost, and what they were worth**: each one logged `component=ok` on
  the ghost, which is why the log never disagreed with the bug. `component=ok` is the same species
  of non-evidence as "it ran without errors" — it says a component exists, never that anybody can
  see it.
- **The identification came from a person, not an instrument.** The catalog probe cycling three
  `Heal` systems onto the ghost got the user to *"its those 3 effects... think the 'ball' thing is
  the one in the middle"*, and their later "at the top of the model" is what actually closed it.
  `effect-investigation.md`'s rule holds: ask the question a person can answer without naming an
  asset.
- Notes: the mirror sends a compile-time KEY over the wire, never an asset path, and that is
  unchanged — the height is resolved locally on each machine from local observation.

## 2026-08-27 — A ghost's attack could damage the player, and the fix was the game's own already-hit list (user-confirmed)

- Date: 2026-08-27
- Observed: the user, after the fix: *"no damage taken, even after multiple attacks"*. Before it,
  across a long session: *"first attack still hit/hurt"*, repeatedly, with the ghost's attack
  animation playing normally each time.
- **Why this one mattered more than a cosmetic defect.** A peer's ghost changing the local player's
  health is the thing `CLAUDE.md` and `brief.md` forbid outright — cosmetics yes, game-state
  authority no. Everything else open in this adapter was a picture being wrong.
- **The mechanism, measured end to end:**
  1. the adapter mirrors a peer's montages onto the ghost — shipped behaviour, and what makes the
     attack pose work at all;
  2. an attack montage's notifies run the game's own attack code **on the ghost**;
  3. that code queries outward, finds the local player, and records them in the pawn's own
     `hitActorsArray`;
  4. it then calls the Blueprint interface **`BPI_PerformDamageResponse(DamageType, attackDirection)`**
     on the player — carrying a damage **TYPE, not an amount**, so the victim decides the cost;
  5. health is `CurrentHp` on the GameInstance **singleton**, so only the player's bar moves.
- **The list, caught in the act.** Read every tick across one charged attack:

  ```text
  PRJWATCH: ghost hitActorsArray count -> 0 tick=923
  PRJWATCH: ghost hitActorsArray count -> 2 tick=1547
      hitActors[0] = 'BP_PlayerGoatMain_C ...BP_PlayerGoatMain_C_2147482216'   <- the local pawn
      hitActors[1] = 'BP_PlayerGoatMain_C ...BP_PlayerGoatMain_C_2147482216'
  ```

- **The fix**: mark the local player as already-hit in the **ghost's own** `hitActorsArray`, checked
  every tick, before its first swing (`GHOST_PREHIT_PLAYER`). Nothing on the player is written; the
  montage, the pose and the VFX are untouched. **The game itself proved the lever worked before we
  used it** — only the FIRST attack ever landed, because after it the player was already in that
  list. The fix extends the game's own behaviour by one attack rather than introducing a rule.
- **Six candidates were closed first, each by a live run**, and each is left gated off in
  `Plugin.cpp` with its own recorded negative: the `chg` VFX mirror; the pawn's three damage numbers
  (never read — the interface passes a type); the hitbox component (`Hit Component 1` is NULL on
  this build); the player hitting their own ghost (collision reads `false` at actor level and `0` on
  every component, re-asserted every tick); engine damage hooks (`ApplyDamage` and its two siblings
  **armed on 3 of 3 and never fired** — this game does not use the engine's damage path, which also
  explains the player's `LastHitBy` staying `<none>` through being hurt); and the pawn's own attack
  gate booleans (`lockAttack?` and six others, all held, all ignored by the attack path).
- **The instrument lied twice before it told the truth, in the same way both times.** The hit-list
  read and the per-component collision read first sat inside a ~5Hz gate and came back "empty,
  nothing enabled" across an attack that demonstrably did damage. A swing's hit window is a few
  FRAMES: the probe was reporting that it was not looking. Moving those two cheap reads to per-tick
  produced the answer in one run. **"The measurement came back clean" is worth nothing until the
  sampling rate is checked against the event's duration.**
- **A single run was treated as proof, and it cost two builds.** Suppressing every montage stopped
  the damage on one attack in one run, which was read as the mechanism being proven. The later
  narrow test — skipping only the four ground-combo attack montages — left the first attack harmless
  but not the charged projectile, whose montage the filter never matched. The mechanism was right;
  the confidence was not earned. Repeat a negative result before building on it.
- **What made the fix possible was checking an assumption instead of trusting it.** Writing into a
  UE `TArray` from this DLL was refused twice as a heap hazard — our allocator is not the game's.
  RE-UE4SS's `TArray::Add` goes through `AddUninitialized` → its allocator → `FMemory`, and this
  SDK's `FMemory` wraps the **game's own `GMalloc`**, resolved at runtime (`Unreal/FMemory.hpp`).
  The hazard was in the assumption. **A refusal on safety grounds is still a claim, and claims get
  checked.**
- Notes: the user withdrew an interim bandage that skipped attack montages (*"i do want the ghost to
  do all animations"*), so no animation is sacrificed by the shipped fix. Scope: the ghost's attack
  vocabulary on this build is `dreamLady_Attack_GF1/GF2/GF3/GL2_Montage` plus the charged projectile
  throw, which uses a different asset that has still never been logged by name.

## 2026-08-27 — The mod starts its own core: a closed port that never refuses, and the port sweep that could not see it (user-confirmed)

- Date: 2026-08-27
- Observed: the user launched the game with only a relay running and nothing started by hand:
  *"saw a ghost directly now"*. The mod's own log carries `started meshghost.exe (pid N)` followed
  ~1.6s later by `bridge connected on port 7778`, and it did so on every subsequent launch of the
  session.
- **Why it matters more than it looks.** Autostart is how a *player* is meant to use this — the mod
  starts the client for them and the release README says so. A developer with a core already running
  would never see it fail.
- **The failure**: `connect_attempts` climbed forever while `CoreLauncher` logged **nothing at all**.
- **The first fix was real and insufficient.** `BridgeClient::try_port` waited on `select` with only
  a write set and `nullptr` for the exception set, and **Windows signals a FAILED non-blocking
  connect in `exceptfds`**, marking a socket writable only on success. Genuine bug, fixed — and the
  autostart still did not fire.
- **What ended it was measuring the OS directly**, standalone, outside the game:

  | Target | Result |
  | --- | --- |
  | a port with a listener | writable in ~4ms |
  | a closed loopback port | **neither writable nor errored after 500ms** |

  **A closed loopback port on this machine is never refused** — the SYN is dropped rather than
  rejected, which is what a firewall in "block" mode does. No `select` timeout could ever have fixed
  that, because nothing was coming. The original 2ms window was not too short.
- **The fix**: stop asking the network and ask the OS — **a free port is one we can `bind`**, with
  `SO_EXCLUSIVEADDRUSE` so a socket sharing the address cannot make it look free. Instant,
  deterministic, unaffected by firewalls, and it is the same question the core itself asks when it
  binds its listener, so a port already holding a core is excluded for free. Verified outside the
  game before rebuilding: with a core on 7778 that port reports `bindable=False (AddressAlreadyInUse)`
  while 7779/7780 report `bindable=True`.
- **A silent branch turned a socket bug into a mystery.** The gate that decided "nowhere to spawn"
  logged nothing, so a bug in a socket helper read as "the launcher never runs". It now prints,
  throttled, next to the bridge-stats line.
- **Method**: two fixes reasoned out from the code, both wrong the same way, then the subsystem was
  taken out of the program and tested standalone. That is `CLAUDE.md`'s "two guessed fixes failing
  the same way is a signal — isolate by subtraction, never a third guess", and the subtraction took
  seconds.
- Notes: `"connection refused"` is a courtesy, not a guarantee. Any logic that reads *absence of a
  refusal* as *something is listening* is wrong on a machine that drops instead of rejecting.

## 2026-08-27 — The charged-attack glow mirrors onto a ghost; what is missing is the projectile ACTOR (user-confirmed)

- Date: 2026-08-27
- Observed: the user, asked specifically about the charge glow because it had been on screen all
  session with attention elsewhere: *"charge is doing its vfx, its just that we don't have a visible
  projetcile shooting from the ghost yet"*.
- **What this confirms**: the `chg` row of `MIRRORED_EFFECTS` works end to end on a ghost —
  `NS_ProjectileCharged`, attached to `VisualMesh` at the **`handslot_R`** socket, which is why it
  reads as being on the sword rather than centred on the character. That completes the VFX mirror's
  confirmed set alongside the heal (same day) and the recall glow (2026-08-16).
- **What it does NOT cover, stated so the entry cannot be read as more than it is**: the ranged
  projectile itself is a separate world actor and has never been mirrored. A peer firing one shows
  the charge on their ghost and then nothing leaves it.
- **What the projectile watch established about that actor**, three sessions of it: the class is
  `PRJ_PlayerCutter_C` (`/Game/Blueprints/Projectiles/PRJ_PlayerCutter`), exactly one instance is
  spawned per shot, its `Owner` is `<none>` and its **`Instigator` is the firing pawn**. Every one
  ever seen was instigated by the local pawn, never by a ghost — consistent with the ghost's attack
  damaging through the interface rather than by spawning anything.
- Notes: structurally this is the thrown Dream Breaker's job — spawn a prop per shot, sample the
  real actor's transform, replay it on the receiving side — which already ships and needs no
  simulation because the peer's own `ProjectileMovementComponent` has already resolved the flight.

## 2026-08-27 — A ghost's ranged projectile is mirrored as an EFFECT, after an actor handle crashed the game (user-confirmed)

- Date: 2026-08-27
- Observed: the user, after the third correction: *"the projectiles work properly now"*. Before
  that, in order: no shot visible at all; then *"i think the ghost was doing a projectile attack
  now. but only once and then when doing it again it wouldn't do any"* plus a hard crash; then
  *"still only did the projectile the first time/once... also no crash anymore"*.
- **What it does**: the sender finds its own `PRJ_PlayerCutter_C` by class, attributes it by
  **`Instigator`** (the firing pawn — `Owner` is `<none>` on every one ever logged), samples position
  and rotation every 3 ticks, and the receiver plays the projectile's own Niagara system along that
  path. Nothing is simulated on the receiving side: the peer's `ProjectileMovementComponent` has
  already resolved the flight.
- **Three separate faults, each with its own lesson, and none of them was the feature's logic:**

  1. **The rig hid it.** The transform crosses the wire in absolute world space, and a loopback
     ghost is nudged 150 units sideways while its projectile was not — so the ghost's shot spawned
     exactly inside the player's own real one, invisible by construction. The log said
     `spawned projectile prop` while the user saw nothing. The thrown sword already applied that
     offset for the same reason; the projectile simply inherited a rig artefact nobody had extended
     it to.
  2. **Holding a game-owned actor CRASHED the game**, with a stack trace naming it:
     `call_destroy_actor` → `ProcessEvent` → `EXCEPTION_ACCESS_VIOLATION`, from `release_ghost`. The
     first version spawned the real `PRJ_PlayerCutter_C` as a prop, the way the thrown sword does.
     A landed sword rests where it falls and nothing takes it away; **a projectile's lifetime
     belongs to the game**, which destroys it on impact — so the prop pointer was asking a freed
     actor to destroy itself. The same stale pointer produced the "fires once, then never again"
     symptom, because a non-null pointer reads as "already spawned".
     **A liveness check does not fix that, and the comment directly above the crashing line already
     said so**: `IsUnreachable()` is only safe on an object that is still ALLOCATED. Adding one was
     treating a pointer that must not be held as a pointer that needs checking.
     The fix was to hold no game-owned actor at all and reproduce the EFFECT instead —
     `adapters/CLAUDE.md`'s rule verbatim.
  3. **Existence is not activity.** With the crash gone the shot still fired only once: this game
     pools actors, so a spent projectile keeps existing with the pawn still named as its instigator,
     and the sender reported "in flight" forever. The effect was never torn down and never
     respawned. Detection now requires the projectile's own `ProjectileMovement` component to be
     **active** — the identical correction the recall glow needed (`VERIFIED.md` 2026-08-16), for
     the identical reason.
- **The asset was read off the live projectile, and the recorded name was wrong.** The queue had
  `NS_PlayerProjectile` from an earlier log; what the real actor actually carries is
  **`NS_PlayerProjectileWeak`**. A hardcoded path would have resolved to nothing and looked like a
  broken mirror.
- Notes: the wire carries `prj`, `prj_vfx` and two vectors, replacing the class path — the same
  extras-size discipline as the thrown weapon block. In a real session the loopback offset is zero,
  so a peer's shot leaves their own ghost.

## 2026-08-27 — Death, the pit, the hurt reaction and the respawn: four effects, found by measuring rather than naming (user-confirmed)

- Date: 2026-08-27
- Observed: the user, at the end of the sequence: *"it works correctly now, pit/dying/respawn
  confirmed working"*, and earlier *"its doing the pit VFX properly now"*.
- **What ships**, all four riding mechanisms the game already had:

  | Effect | How |
  | --- | --- |
  | Death burst at the pit | `NS_BasicBurst`, world-spawned, mirrored row `bb` |
  | Landing/respawn dust | `NS_DustLand`, world-spawned, row `dl` |
  | Respawn aura around the character | `NS_RespawnSafe`, attached to the capsule, row `rsp` |
  | The white/invisible model flash, and the red hurt blink | the pawn's own `dieFade(DieNotRez)` and `BPI_PerformDamageResponse(DamageType, attackDirection)`, called on the ghost |

- **The captures that produced them.** A `VFX_WATCH` run over two pit deaths gave all three Niagara
  systems with their attach points — `NS_RespawnSafe` on the `CapsuleComponent` at zero offset, the
  other two world-spawned with their coordinates. No name was guessed.
- **The model flash was not a VFX at all, and two probes said so before anything was built.**
  `DEATH_VISIBILITY_PROBE` watched the player's mesh through a death: `hidden=false visible=true`
  throughout — never hidden — while three material slots became `MaterialInstanceDynamic`. That is
  an animated material PARAMETER, which no particle watcher could ever have found. Rather than walk
  `ScalarParameterValues` (an array of structs) to read it, a second census asked what STARTS it and
  named `dieFade(DieNotRez: bool)` — one function whose own parameter distinguishes dying from
  resurrecting, which is exactly the two-sided effect the user described.
- **A wrong guess came first, and it is the lesson.** Between those two probes, `startBlink` was
  inferred from a name and shipped as a fix. It resolved, ran, and did nothing visible — because its
  reflected locals are a `RandomFloatInRange` and a timer: it is the character's **eyes** blinking.
  The user caught the process, not just the result: *"tought we were just probing/finding how?"*
  Third time this game's names have pointed the wrong way, after `AnimGraphNode_Trail` (cloth
  physics) and `NS_Healing` (needed a control run).
- **The hurt reaction needed the user's own correction.** The death fade was first triggered on
  `CurrentHp` reaching zero, and half of it never fired: *"probly cuz it can't take any damage? it
  never blinks red/gets hurt etc either"*. A pit fall costs **exactly 5 HP** — damage, not death —
  so the trigger became any DECREASE in the shared health, and the reaction became the game's own
  damage response.
- **That call ships with a tripwire, because health is a GameInstance singleton.** If
  `BPI_PerformDamageResponse` deducted HP rather than painting the reaction, calling it on a ghost
  would hurt the local player — the bug this same day was spent eliminating. So the mirror reads
  `CurrentHp` immediately before and after the call and **disarms itself for the session** if the
  value moves. It ran and the tripwire never fired, which is now a measured fact about that
  function rather than a hope.
- Notes: `NS_BasicBurst` is a generic hit burst that also fires in ordinary combat, so proximity
  attribution can occasionally show a stray burst on a ghost — accepted knowingly, and the row to
  pull first if it ever reads as noise.

## 2026-08-27 — Pseudoregalia declared FEATURE COMPLETE by the user, with the scope written down

- Date: 2026-08-27
- Observed: the user, ending the session: *"i think we can consider pseudoregalia 'feature complete'
  at this point as well"*.
- **The scope is recorded deliberately**, because a bare "feature complete" with no description is
  already a known problem in this repo — Crystal carries exactly that complaint in its own queue.
  What that declaration covers, as of this date:
  - **Body and motion**: spawned pawn-clone ghosts, position/rotation, the pose cluster (slide,
    crouch, capsule), wall-ride, ledge grab, montage mirroring for the game's whole animation
    vocabulary, outfit and weapon-equip state.
  - **Effects**: the afterimage trail with its observed colour, the cling-gem and recall glows, the
    thrown Dream Breaker with its landed glow, healing (aura and both waves), the charged-attack
    glow, the ranged projectile, the death burst, landing dust, the respawn aura, and the
    death/hurt/respawn model fade.
  - **Correctness**: the ghost's shadow on the ground, its own HUD off the screen, the camera left
    with the player, and a ghost that cannot damage the local player.
  - **Plumbing**: the mod starts its own core, and the bridge port sweep asks the OS for a free port.
- **What it does NOT cover, stated in the same breath** — all still in `UNVERIFIED.md`:
  - the **black flash** when a ghost appears: two mechanisms ruled out by measurement (the fade
    timelines were not playing; no camera fade is raised near a spawn) and the cause still unknown;
  - the ghost **floating up slightly during a melee swing** — seen once and never reproduced across ~a dozen later runs the same day, so a single sighting rather than a live defect;
  - the second-instance case of the **bridge port walk**, still unwatched;
  - two **crash reports** on exit/pause whose cause is not established — one of them, the projectile
    prop, was root-caused and fixed this day, but the 2026-08-17 sighting predates it;
  - real **two-machine** confirmation of anything confirmed only in loopback.
- Notes: the day's work is nine confirmed entries above this one. The declaration is the user's, and
  the scope above is the agent's reading of it written down so a later session cannot quietly widen
  it.

## 2026-08-27 — A ghost's afterimage outline is at ZERO frames: refused at the enable call itself, not stripped after

- Date: 2026-08-27
- Observed: the user, after attacking and sliding behind a wall next to the ghost: *"Yee its
  working perfectly now"* — the through-walls blue outline is *"visible for the player, invisible
  during attack/slide for the ghost"*. This closes the "one frame is the floor for this approach"
  entry in `UNVERIFIED.md`, and it was closed by abandoning the approach, not by tuning it.
- **The mechanism**: a `RegisterPreHook` on the native `PrimitiveComponent:SetRenderCustomDepth`
  (the same proven-safe native-prehook shape as the camera fightback, fade guard and damage
  guards) rewrites `bValue` to `false` before the real call runs, whenever the component belongs
  to a `BP_AfterImage_C` attributed to a ghost. The outline never turns on, so there is no frame
  to see. `register_afterimage_outline_guard` in `Plugin.cpp`.
- **The ordering problem it had to survive, measured this session**: the game calls the enable
  BEFORE `copyActor` is set on the image — the first ghost image of the session reached the tick
  pass with `copyActor` still null. So an unattributable enable (while any ghost is alive) is
  REFUSED on the spot and remembered; the per-tick sweep attributes it a tick later and RESTORES
  the outline if the image turns out to be the player's own. That inverts the failure mode: worst
  case is one outline-less frame on a player image (invisible except through a wall) instead of
  one outlined frame on a ghost's. The full refuse→attribute→restore round trip was seen in the
  log completing within 3ms, and the player's own double outline behind a wall was confirmed
  intact in the same session.
- **Why every reactive variant lost**: the strip pass runs in the engine-tick POST callback, after
  the frame's rendering is already enqueued — so an image born outlined always got one frame on
  screen no matter where inside the tick the strip ran. Moving the strip right next to the
  triggered burst was tried first this session and changed nothing the user could see, which is
  the measurement that proved the approach reactive-by-construction.
- Notes: the backstop sweep's "had custom depth ON past the enable-time guard" line never appeared
  across the confirming session — nothing slipped past the hook. `copyActor` read null even at
  sweep time throughout this session, so birth proximity carried attribution; on the loopback rig
  the ghost sits 150 units to the side, which keeps proximity exact.

## 2026-08-27 (late session) — A hard crash on "retry last save": the VFX mirror's component map outlived its level (user-confirmed)

- Date: 2026-08-27, the same evening as the feature-complete declaration.
- Observed: the user, testing a comments-only rebuild: a `Fatal Error!` with a full stack trace on
  "retry last save" — `game_thread_tick` → `tick_remote_mirrored_vfx` → `GetFunctionByNameInChain`,
  `EXCEPTION_ACCESS_VIOLATION` reading a poisoned address. After the fix: *"the 'return to last
  save' thing and 'going back to the main menu' worked fine"*.
- **The cause**: `RemoteGhost::vfx_components` holds raw pointers to Niagara components the LEVEL
  owns, and its only clear was the tick path's own teardown branch — the branch that dereferences
  them. A transition freed every component while the map still named them; the next tick that
  wanted one stopped called `Deactivate` on freed memory.
- **The fix is the file's own established mechanism**: drop the references in the LoadMap PRE hook
  (`release_all_ghosts`), the one moment guaranteed to be before the level's teardown — exactly how
  the ghost pointer has always been kept safe, and how the thrown prop was fixed on 2026-08-16.
  That hook's comment said it in advance: *"Anything actor-shaped added to RemoteGhost in future
  belongs in these lines too."* The 2026-08-27 VFX mirror shipped without being added. Third
  instance of the family. `release_ghost` (peer despawn) got the same clear, and
  `projectile_component` was added to the hook as well — it survives today only via its tick path's
  world-staleness check, a weaker guarantee than dropping the pointer before teardown.
- Notes: the crash was NOT introduced by that day's earlier work — the map was born uncleared when
  the mirror shipped. It surfaced now because "retry last save" with active mirrored VFX had never
  been done. An audit of every pointer member on `RemoteGhost` followed; all are now covered.

## 2026-08-27 (late session) — A hard crash on starting a NEW SAVE: the camera fallback pointer, never cleared, dereferenced two levels later (user-confirmed)

- Date: 2026-08-27, immediately after the entry above.
- Observed: the user: an EMPTY `Fatal Error!` dialog — no stack — *"whenever i stared a 'new game'"*,
  reproduced as: main menu → delete an old save → new game on that slot, crashing the moment the
  new save loaded. Their own theory on report: *"so its probly camera/cutscene related ?"* — which
  is what it was. After the fix: *"no crashing anymore"*.
- **The log pinned the line without a stack.** `owned_by_ghost=YES` printed, then NEITHER of the
  two prints that follow it in the refuse branch appeared — the game thread died between them, at
  `last_non_ghost_view_target->IsUnreachable()`. The ~20s of healthy bridge lines after it were
  UE4SS's own thread still ticking under the error dialog.
- **The cause**: `last_non_ghost_view_target` remembers the last view target the game chose for
  itself so a refused ghost-rig switch can be redirected somewhere real. It is a raw pointer to a
  LEVEL-owned camera and was never cleared — after ZONE_Dungeon → TitleScreen → ZONE_Dungeon it
  named an actor two teardowns dead. The new level spawned a ghost, the game switched to the
  ghost's rig, the refuse branch ran, and the "validity check" dereferenced freed memory.
- **Why "retry last save" never crashed here while a new save did** — the user's observation, and
  the diagnostic key: reloading the SAME level tends to hand the allocator the same addresses back,
  so the stale pointer survives by luck; the intervening TitleScreen is what makes the old camera
  genuinely gone. A stale-pointer bug that same-level reloads cannot reproduce.
- **`IsUnreachable()` is not a validity check — third finding of the same fact in this file**
  (release_ghost's crash, the projectile prop, now this): it is only meaningful on an object that
  is still ALLOCATED. The fix is the same clear in the LoadMap PRE hook. Fourth member of the
  never-cleared-handle family.
- Notes: the earlier audit had FOUND this pointer and deferred it as "latent, nothing attributed" to
  avoid touching the camera minutes before a live test. It was the very next crash. When an audit
  turns up an instance of a bug family that has already crashed twice, the audit is the evidence —
  fix it then.

## 2026-08-27 (late session) — The ghost flinched on every save-file swap; and the carried-over health is the GAME's, proven by the user's control run (user-confirmed)

- Date: 2026-08-27, closing the same session.
- Observed: the user, after the two crash fixes: *"the ghost is getting 'hit/hurt' whenever i swap
  between save files now"*. After the fix: *"this worked"* — and the real hurt reaction was
  deliberately re-confirmed with a pit fall afterwards: *"yes, this still works fine"*, so the fix
  did not cost the feature.
- **The cause**: the hurt mirror fires on any DECREASE in the shared `CurrentHp`, and the sender's
  baseline (`last_seen_hp`) was a function-local static that survived save swaps. A save-file swap
  rewrites the GameInstance singleton wholesale, so arriving in a save with less health than the
  one just left counted as damage and the ghost flinched. Not a hit — a stale baseline straddling a
  boundary it should never straddle. Not caused by that night's fixes either: swapping saves with a
  ghost present had simply never been done before the mirror existed.
- **The fix**: the hurt/death baselines became plugin members and are invalidated in the same
  LoadMap PRE hook (−1 = prime on next read, compare on the one after). The COUNTERS deliberately
  keep running — they are monotonic on the wire, and a reset would make a receiver that has seen a
  higher value silently swallow real hurts until the count caught back up.
- **A second instance found by the fix's own audit**: the receiver baselines `last_seen_land/jump/
  montage` on a peer's FIRST sample so a mid-session joiner does not replay old events at spawn —
  and the day's new hurt/death/blink counters had never been added to that list. A peer hurt before
  their ghost existed would have flinched it at spawn. Added.
- **The health value carrying across saves is the BASE GAME's behaviour, and the user's control run
  is what proved it**: with the relay stopped so no ghost could spawn and nothing of MeshGhost
  active in the world, swapping saves still left `CurrentHp` at the previous save's value —
  *"still happened. so its not from our mod i guess ?"* Correct: the mod never writes that field
  (every access re-audited: all reads; the mirror's tripwire never restores). Recorded as a game
  fact in `documentation.md`'s health section. The mirror reacting to it was how anyone would first
  meet this; the mirror was wrong to react, and only that was fixed.
- Notes: same control-experiment shape as the health-bar investigation earlier the same day — one
  run without the suspect, one with — and it exonerated the mod in a single swap.

## CONFIRMED ON SCREEN 2026-08-28 — relay-side area filtering is invisible in Pseudoregalia, both halves

**The largest unwatched change of the day, watched.** Relay-side cross-area filtering (ADR 0041)
applies to exactly two adapters — TEVI and Pseudoregalia — because the other two declare
`render_all_areas` and are exempt. Until this run it had never been seen working on any screen.

**User, watching a peer hop between their area and another every 20s:**

- On the way out: *"it just pops in/out cleanly, when it leaves or comes back"* — **no freeze.**
- On the way back: *"whenever the ghost comes back, it starts to move around in a circle
  directly"* — **already in motion, no beat of empty space.**

**Those are the two fixes, and each has a distinct failure mode that would have looked different.**

- **The transition rule.** A peer leaving your area is announced by exactly one message: its first
  state carrying the new `area_id`. Filter that and the recipient hears silence, `remoteBuffer`
  edge-holds the last sample, and the ghost **stands frozen mid-circle** until
  `DefaultRemoteStaleAfter` (3s) removes it. "Pops out cleanly" is that message arriving.
- **The arrival seed.** A filtered client receives nothing from another area, so on arriving it
  knows nothing about who is standing there — and change suppression (ADR 0039) means a motionless
  peer says nothing for up to `IdleKeepalive`. Without the seed the ghost appears a quarter-second
  late. "Starts moving in a circle directly" is the seed landing: the state is already there, so it
  renders in motion rather than after a wait.

**CORRECTION 2026-08-28, same day:** the claim below that this game cannot run two copies is
FALSE. A Pseudoregalia speedrunner told the user that the game has no Steam single-instance
integration, so launching pseudoregalia-Win64-Shipping.exe directly -- outside Steam -- starts as
many copies as you like. It was believed otherwise when this entry was written, which is why the run used
a synthetic peer; two real instances have been possible the whole time.

**Where the wrong belief came from, because it is the reusable part:** TEVI really does refuse a
second copy, which is why a separate standalone TEVI install exists on this machine purely for
two-instance testing. That per-game constraint was then carried over to Pseudoregalia without
being checked. **A launcher restriction is a fact about one GAME, not about games** -- Steam
single-instance behaviour, a mutex, or a save-file lock differ per title, and the cost of assuming
is a whole class of test quietly written off as impossible. Check it per adapter; it is one launch. **The confirmation
below still stands** -- the peer was a real relay client speaking the real protocol -- but it is
the weaker version of a test that can now be done properly, and a false limitation left in a
VERIFIED file would send the next person looking for a workaround they do not need.

**Setup, stated because it is not a two-instance test.** Pseudoregalia was believed unable to run two copies on this
machine, so the peer was `meshghost-fakeadapter` — a synthetic client that is nonetheless a REAL
relay client speaking the real protocol, circling radius 250 at the user's own `area_id` and
position, with `-churn-every 20s -churn-for 8s` moving it to a second area and back. The relay,
the client and the mod were all **release** builds from `packaging/release/`; only the extra peer
was synthetic. That is the tier-3 rig `dev-scripts/README.md` describes, used here to answer a
correctness question rather than a load one.

**Also confirmed incidentally: the shipped build is quiet again.** The same session showed **zero
`TRACE local` lines**, where the build an hour earlier wrote 24 of them per 18 seconds. See
`FLAGS.md`'s `LOCAL_MOVEMENT_TRACE`.

**Ghost collision is now disabled by default for this game** (user's call, same session): a solid
ghost in a 3D platformer can stand in a doorway or on a ledge and block the player, which is worse
than one you walk through. It rides the per-game config override, and
`protocol.ResolveGhostCollision` returns disabled if EITHER side asks — so this holds even in a room
whose relay advertises collision enabled, and a room can never force it back on.

## CONFIRMED ON SCREEN 2026-08-28 — two real Pseudoregalia instances, and the three bugs that were between them

**User, after launching the game twice directly from the exe:** *"Think pseudo is working now, got in
game on both clients and they saw each other"*. First time this game has ever been tested with two
genuine peers.

**The chain, from the adapter's own log, every line of it new:**

```
bridge port range moved to 6672-6679 by configuration.
bridge connected on port 6672.
core on port 6672 refused us ({"reason":"busy: this core already has a game attached"}) -- trying another port.
bridge connected on port 6673.
```

with the two cores reporting `bridge listening on 127.0.0.1:6672` and `...:6673`, joining the relay
as p10 and p11, and the relay holding `members=2`.

**Three separate defects had to be fixed to get that, and each hid the next.**

1. **The rejection was destroyed on arrival.** `close_socket()` cleared `recv_buffer`, and a core
   that refuses writes its reject and then closes -- so `poll_lines` read the reject into the
   buffer, saw the close on the next `recv`, and wiped the buffer before the parse loop two lines
   below could read it. Measured before the fix: the second instance reported
   `connect_attempts=127, send_ok=127, lines_received=0` while the first core's log showed **202
   refusals sent**. The buffer is now cleared when a connection is ESTABLISHED, not when it closes.
2. **The rejection could not be attributed to a port.** `close_socket()` also zeroes
   `current_port`, and it still ran before the parse loop -- so the reject was read but logged as
   `core on port 0 refused us`, and the busy-marking guarded by `current_port >= base_port` could
   never fire. The port is now captured at the top of `poll_lines`, before anything can close.
3. **Which is why autostart reported "NO free port to start a core on".** The sweep RETURNS as
   soon as a port answers, so it only ever examined 6672; it reaches the free port beyond only if
   6672 is cooled down first. One cause, two symptoms -- and the same "no free port" line the
   0.9.9 Linux user reported.

**Why only this adapter.** The other three parse as they read: TEVI handles complete lines inside
its read loop, and the two Lua adapters take LuaSocket's `partial` data before acting on a "closed"
error, so a rejection is never sitting unparsed when cleanup runs. Pseudoregalia reads all available
data first and parses afterwards, which is the one shape where a cleanup step can slip between the
two. Confirmed by Emerald and Crystal logging real rejections with real ports the same evening.

**Defect 2 is not unique, though.** TEVI had the same FAILURE -- a reject attributed to the wrong
port, so the genuinely busy port was never cooled -- fixed on 2026-08-27 via a different cause (it
used the walk cursor instead of the connected port). Two adapters, two mechanisms, one symptom:
reject attribution belongs on a bridge conformance checklist rather than being rediscovered per
adapter.

**The test that found all of it existed only because an assumption was corrected.** Pseudoregalia
was believed unable to run two copies, inferred from TEVI needing a standalone build; a
Pseudoregalia speedrunner pointed out the game has no Steam single-instance integration and the exe
can simply be launched twice. That one correction turned a whole class of test from impossible to
routine, and it found three real bugs in the first run.


## Nametags: a peer's name renders above their ghost, both join orderings (2026-08-28)

**User-confirmed on screen**, which is the gate this file holds and the reason this entry exists
separately from `UNVERIFIED.md`'s record of the colour.

- *"can see the name 'Rin' now"* — a peer already in the room when the game launched.
- *"text appeard on 1 client"*, then after the handshake fix, both orderings.
- Billboarding, in the user's own words: *"think the text is cardboarded, and facing towards my
  direction while looking at it / spins around and follows so its always visible"*.
- Centring, after switching from a position nudge to the component's own `HorizontalAlignment`:
  *"the text looks a bit more centered now"*.
- A screenshot shows the name rendering clearly above the ghost at the shipped height.

**What is drawn:** a `UTextRenderComponent` created at runtime on the ghost pawn with
`AActor:AddComponentByClass`, using the engine's own `RobotoDistanceField` font and
`DefaultTextMaterialOpaque` — both confirmed present in this shipped build by
`NAMETAG_CENSUS_PROBE`, even though the game itself uses no text component anywhere (0 instances).

**Nothing of ours ships to draw it**, which is what ruled out the UMG-widget approach the other
Pseudoregalia multiplayer mod took — that one ships its own `.uasset` font, which this repo cannot
commit.

**What is NOT claimed here:** the colour. It renders black; the evidence and the exhausted routes
are in `UNVERIFIED.md`'s entry for the same date.

**A peer with no name draws nothing at all** — the shipped default is an empty name, on the user's
call: *"if its blank it should not display/do anything, it should only have a text box/show
something if a custom name is put in"*.

## Nametag COLOUR, as a plate the name stands on — three peers, three cases (2026-08-29)

**User-confirmed on screen**, closing what `UNVERIFIED.md` had recorded as exhausted the day
before: *"yee it works/looks fine"*, *"confirmed name/nametag stuffs are done now"*. Judged in a
real three-instance session (three games, one relay, quic), each instance a different case:

| Peer | Config | On screen |
|---|---|---|
| `Tsukino` | name + `#F54927` | black name on a flat orange plate, sized to the name |
| `Blank` | name, no colour | black text, nothing behind it |
| (third) | no name, no colour | no tag at all |

**What is drawn:** a SECOND `UTextRenderComponent` four units behind the name, rendering the same
string through a `MaterialInstanceDynamic` of `/Engine/EngineDebugMaterials/DebugMeshMaterial`
with its **`Color`** parameter set to the peer's colour. The glyphs come out as solid blocks, so
the plate *is* the name and sizes itself; the text in front keeps the default material and stays
black for contrast.

**Why that material, out of everything tried:** the plate must be OPAQUE, UNLIT and colourable.
The game's black room-divider planes out-draw every TRANSLUCENT plate — `EmissiveMeshMaterial`
still vanished behind one at `TranslucencySortPriority` 32760 — while opaque materials depth-test
and survive, as the opaque text always did. The game's own opaque masters (`M_PawnMaster` and
kin) survive but carry stylized lit banding that no scalar flattened. `GizmoMaterial` with
`"GizmoColor"` looked identical and is the runner-up.

**Coloured TEXT is impossible on this build** and that is now measured, not assumed: the default
text material ignores every parameter forced into a dynamic instance of it,
`DefaultTextMaterialTranslucent` is not cooked, vertex colour reaches nothing, and the font atlas
carries its distance field in the red channel so anything sampling it as base colour renders red.

**Facing: the CAMERA, and pitch included.** The tag aims at `PlayerCameraManager`'s location
(resolved once per tick, not per ghost), so it stays square-on from above and below. Facing the
local pawn instead — the first shipped guess — visibly leaned the tag, since this game's camera
sits behind and above the player.

**Two defects found live and fixed inside the same session:** a fresh `UTextRenderComponent` is
born holding the class-default string `"Text"`, so a colourless peer's plate drew that word in
the material's default colour (the white box the user saw behind `Blank`); and the tag's facing,
above.

**The default for a player who never edits their config is `name_color: "#A89975"`** — the
parchment the user picked from a probe lineup — shipped in `packaging/release/config.json` and
the client template. A blank colour still means no plate, on the user's rule.

**How it was found:** ~12 rounds of labeled experiment rows in ONE game session, via a Lua probe
(`probe_nametag/`) hot-reloaded by a resident watcher mod (`probe_reloader/`) off a trigger file.
Method: `../_template/probes.md`, "Label each experiment with the variable it tests".

**Fourth case, confirmed the same day: a blank name with a colour SET draws nothing at all** —
user: *"yee it works"*, on a two-instance session where one peer had `name: ""` and
`name_color: "#F54927"`. A blank name beats a colour at every layer, each independently: the
relay's `sanitizedNametag` returns nil and drops the colour with the name, `core.storeRemoteName`
stores an empty name as an ABSENCE rather than as `""`, and the adapter returns before creating
any component. All three carry the same reasoning in their comments — a colour with nothing to
colour would have a renderer draw an empty coloured box.

**So the shipped default is deliberately NO TAG** (`name: ""` in `packaging/release/config.json`
and the client template), with the parchment `name_color` sitting ready for the moment a player
types a name. The user's call: *"guess we keep the default name in the config as blank"*.

## Landing dust on a ghost: the echo loop, the swallowed repeats and the mid-body height, all three fixed (2026-08-29)

**User-confirmed on screen**, two instances, after each fix in turn: *"works correctly/as intended
now"* for the echo, then *"yes both work perfect now, for single and multiple hops"*, and finally
*"yes it works now, first jump, normal jump, short/fast jumps — confirmed"*.

**Four separate defects sat on top of each other**, and each was only visible once the one above it
was gone. That is the entry's real content: the first diagnosis was wrong twice, and both times the
correction came from the user describing what they saw rather than from more analysis.

**1. The mirror fed itself (the echo)**

**Symptom, the user's:** *"player jump, player get its own dust, a small delay, someone elses ghost
trigger that same dust even if they shouldn't ... that other player never jumped"*.

**Cause.** Local detection enumerates every `NiagaraComponent` in the world and attributes a
`world_spawned` effect purely by distance to the local player (`MIRROR_WORLD_VFX_RADIUS`, 600). It
never excluded the components this mod had itself spawned onto ghosts. So: you land, `dl` goes on
the wire, the peer spawns the dust on YOUR ghost — correct so far — but that ghost stands near
THEIR player, so their detector reads our component as their own dust and sends it straight back.

**The measurement that named it**, from the adapter's own log: a `local: '' -> 'dl'` transition
appearing **14ms, 37ms and 75ms** after this mod spawned a dust on a ghost. One sample interval,
three times running; no human jumping produces that correlation.

**Fix:** an exclusion set built by IDENTITY from what the remotes hold, consulted before
attribution. Proximity cannot fix this — a ghost standing next to you is the normal case.

**2. A one-shot event was being carried as a level, so repeats were lost**

**Symptom, the user's:** *"from client1's pov only the first jump gets the dust, not all the
short/fast jumps afterwards"*.

**Cause.** `dl` was mirrored as STATE and the receiver acted on the rising edge of the key's
presence. Each hop spawns a fresh `NS_DustLand`; they overlap, so "is any active" never falls back
to false, the key never leaves the set, and there is no second edge. Measured windows of **3.5s,
5.3s, 6.9s and 8.1s** of continuously-set `dl`, each delivering exactly one dust to the ghost.

**Fix:** one-shot rows are latched to a COUNTER (`key:count` on the wire), incremented once per
distinct component the game creates. Counting components is what separates bursts whose active
windows have merged. A counter is still state — a dropped datagram costs at most one burst and the
next update carries the running total.

**A pulse-with-hold was considered and rejected**: it must be long enough for the send to sample it
and short enough to fall back between hops, and those constraints collide exactly when hops are
fastest, which is the case being fixed.

**3. The echo came back, because the fix in §1 rested on an invariant §2 broke**

**Symptom, within a minute of that build:** *"its echoing onto the ghost again + spamming it"*, and
then *"even from a single jump"*.

**Cause, and it is the lesson of the whole session.** §1's exclusion set is built from the
components the remotes are HOLDING. §2 made one-shots fire-and-forget, so they were no longer held
anywhere — and silently dropped out of the exclusion. The loop returned with the counter now
amplifying it, since every echo also incremented it, which is why one jump was enough to run away.

**The invariant was never written down**: *every component we create must stay reachable from a
remote*. A change to one class of component's LIFETIME broke a fix that depended on its REACHABILITY,
in a different function, with nothing to catch it.

**Fix:** a bounded ring of recent burst components per ghost (32), walked alongside `vfx_components`
when building the exclusion. A ring rather than one slot because fast hops keep several bursts alive
at once; bounded because these destroy themselves and never tell us.

**4. The dust appeared at mid-body, not on the floor**

**Symptom, the user's:** *"it appears like in the 'middle of the body' instead of at the floor"* —
seen from the client that had NOT jumped.

**Cause.** The spawn height prefers a value observed from the local player's own dust and falls back
to the row's constant, which was `0.0`. Zero is the actor ORIGIN, and this game's characters stand
with their origin `GHOST_STANDING_CAPSULE_HALF` (65) above their feet. A watcher who has not jumped
has observed nothing, so it always used the fallback.

**Fix:** the row's fallback is the feet (`-GHOST_STANDING_CAPSULE_HALF`). The observed value still
wins when there is one. Anchoring to the ghost's feet also satisfies what the user described of the
real effect — *"it can appear higher/lower depending on where the player is jumping ... its tied to
the player/always where they land"* — because it follows the ghost's own Z rather than a fixed height.

**5. The first jump after loading in did nothing**

**Cause.** A peer BASELINES against the first counter value it sees and deliberately does not fire
on it, so a ghost joining mid-session does not replay every landing the peer has ever made. But the
counter was only sent while its effect was ACTIVE, so its first appearance on the wire WAS the first
burst, and the baseline consumed exactly that one.

**Fix:** one-shot counters are sent always, active or not. The baseline then lands on a quiet value
before anyone jumps. Costs a fixed ~20 bytes against a 1024-byte extras budget and adds no traffic,
since the string only changes when a count does.

**Notes**

- **The ~270ms between a player's own dust and their ghost's is NOT a defect** and was deliberately
  left alone: the dust is applied from the same render-time line as the ghost's position, so it
  fires in sync with the ghost's DRAWN landing. The gap is `interp: 250ms` doing its job.
- **`bb`, `hw` and `hew` are also `world_spawned`** and went through the same change, so they gain
  the same repeat-correctness. Only `dl` was watched on screen; the other three are unwatched and
  are noted as such in `UNVERIFIED.md`.
- Scope: Steam build, `ZONE_Dungeon`, two instances on one machine over quic, loopback relay.

## 2026-08-30 — the three ghost-light bugs are fixed, and the fixes ship as defaults

**User-confirmed on screen, across three separate runs the same night** — first through dev
toggles, then live on a latched scene, then on the final build with every toggle file deleted:

1. **The connect-time scene latch is FIXED.** With client 1 standing in a dark area and client 2
   connecting: *"client1 didn't glow up this time"* (toggle build), and on the shipped-default
   build: *"client1 stayed dark even after client2 connected"*. The fix is the adapter calling
   `BP_LightManager_C::FixAllLights` after every ghost spawn — the level's own repair, the one a
   `BP_LightTransition_C` runs. Its causal link was proven live: on a latched scene, the call was
   made while the user watched and *"client1 lost the glow"* the same second.
2. **A ghost never glows** (vertex-light kill, confirmed 2026-08-29, reconfirmed on the
   shipped-default build): *"ghosts are dark on both clients"*.
3. **A ghost's blade never wears the ascendant aura** (LightMesh hide): *"the blade is clean for
   both as well"*.
4. **A ghost crossing light-transition volumes disturbs nothing** — deliberately tested with the
   capsule-overlap suppression OFF: client 2's ghost walked into the dark area, out and in again,
   while client 1 watched: *"the client1 glow or client1 ghost's glow didn't change/do anything as
   intended"*. So the overlap suppression is NOT needed for lighting and stays dev-only.

**What the latch was**: the ghost's `BP_DynamicVertexLight_C` registers with the light manager
during `SpawnActor` and nothing unregisters it; the stale registration renders at the local
player's position (it follows the player — walked and confirmed), survives the peer leaving, and
lives in no reflected scalar (a 401-field latched-vs-clean diff read zero differences).
`FixDynamicLights` alone was a measured no-op; `FixAllLights` clears it.

**Policy, user's call**: ghosts stay light-less like the blue outline — *"keep it fully disabled
similar to how we did with the blue outlines"*. Mirroring a peer's real light state is filed in
`agent_docs/ideas.md`, not scheduled.

- Scope: Steam build + a user-made copy of the install (separate logs), `ZONE_Dungeon`, two
  instances on one machine over quic, relay with `-ghost-collision=disabled`. The shipped-default
  run had ZERO toggle files beside either DLL.
- Method and failed-fix table: `UNVERIFIED.md`'s 2026-08-30 section and
  `agent_docs/pitfalls/by-lesson.md`'s two 2026-08-30 entries.

## 2026-08-30 — a ghost's FACING is interpolated, and the choppy fast spin is gone

**Confirmed by the user on a three-launch A/B**, flag on, off, on, with nothing else changed
between the runs: *"its noticable and visually better with slerp on"*.

The run-by-run reads, in order, because the SEQUENCE is the evidence and no single line is:

1. **ON:** *"it actually looks smooth now i think ?"*
2. **OFF** (`GHOST_ROTATION_SLERP = false`, a real revert — the flag compiles the work out, not
   just the decision): *"it looked a bit choppy/low fps in comparison"*.
3. **ON again:** *"now when im testing slerp again it just looks 'delayed' not bad/choppy"*, and
   *"so slerp is for sure doing 'something' better"*, then plainly: *"its noticable and visually
   better with slerp on"*.

**What the defect was.** Orientation is opaque to the core by contract, so `core/interp.go` never
interpolated it — it held the older bracketing snapshot's value until render time crossed the
newer one, making facing a step function at the send rate. The visible error is angular velocity
divided by Hz: at 20Hz a slow pan steps ~2 degrees and is invisible, a fast spin steps ~18 and is
not. That is the user's original report exactly (*"choppy/low fps at 20hz and 250ms when turning
around fast but super smooth when turning around slow"*), and it is why the rate never felt like
the problem until they spun quickly.

**What ships.** The core now names the pair it interpolated position between and the fraction it
rendered at (`orientation_from`/`orientation_to`/`interp_t` on `render_remote` — bridge only, zero
bandwidth, ADR 0043); this adapter interpolates its degrees triple shortest-arc per component.
`GHOST_ROTATION_SLERP`, `true`.

**STILL OPEN, and stated here so the entry is not read as more than it is: this is confirmed
BETTER, not confirmed 1:1.** The bar is indistinguishable from the local character at every spin
speed, and nobody has asserted that. `UNVERIFIED.md` carries the gap.

**The finding worth carrying to the next adapter: the symptom SWAPPED, and that is not a
regression.** Choppy became *delayed*. Different complaints about different mechanisms — the chop
was the stepping, the lateness is the 250ms interpolation delay doing its job on both runs
equally. Slerp does not add delay; it very slightly REDUCES it, since the step showed the older
bracket until render time crossed the newer sample, about half a sample interval (~25ms at 20Hz)
staler than the interpolated value. What changed is that the lateness became LEGIBLE: a choppy
motion masks a smooth lag. **Expect this on any future adapter — fixing a stutter routinely
"reveals" a delay that was always there, and mistaking that for a regression is how a good fix
gets reverted.**

- Scope: Steam install, loopback rig — relay `-loopback -send-hz=20 -ghost-collision=disabled`,
  install config 250ms interp / linear / no extrapolation, the ghost offset 150 units to the side
  so the two facings are side by side. Spin-in-place test, so position never changed and the read
  is on facing alone. One machine, one instance; a real two-peer session has not been tried.
- The extrapolation half of ADR 0043 (`interp_t` above 1, rotation predicted over the same window
  as position) was OFF in every run here and has never been on screen.
- Method, the hedged reads, and the interp/extrapolate question the "delayed" observation opens:
  `UNVERIFIED.md`, 2026-08-30. Reasoning: ADR 0043. Flag: `FLAGS.md`.

## 2026-09-01 — the reset-to-save crash is FIXED, and its cause was the nametag's stale pointers

**User, after the second gauntlet: "no crashing, it always kept the nametag now — cross zone,
reset save, main menu. mixes of these."** Two separate confirmations in one day:

- **The crash.** *Reset to last save* with a peer's ghost (a bug that consumed two sessions,
  2026-08-30/31, and a dozen guards) no longer crashes: two user gauntlets of mixed same-zone and
  cross-zone resets, zone changes and menu trips, all clean. Cause: `update_ghost_nametag`'s
  three component pointers (tag, plate, plate material) were cleared by NO release path, so any
  teardown left them dangling and the respawned ghost's first tag update ran `ProcessEvent` on
  freed memory. Found by symbolizing the crash thread's stack from a minidump against our own
  PDB (`dev-scripts/read-minidump.py --stack` / `--symbolize`). Full story and the transferable
  rules: `agent_docs/pitfalls/by-lesson.md`, "The reset-to-save crash".
- **Nametags now survive separation.** Before 2026-09-01 any spell apart from a peer (zone
  change, cross-zone reset) lost their name for the rest of the game session — the adapter
  erased it on `despawn_remote`, which fires on a mere area change, and `remote_name` is never
  re-sent. The name is kept for the session now (the relay never reuses player ids, so the case
  the erase guarded cannot occur), and the user watched tags survive every mix they tried.

**The teardown spawn holds are REMOVED (both constants 0), and zero is the user-watched value.**
With `no_spawn_hold.txt` armed, ghosts respawned 60-100ms after InitGameState across at least
eight mixed-zone reset cycles in the log, no crash — so the ~5 ghostless seconds after every
load, shipped as mitigation while the cause was unknown, bought nothing and are gone. The window
machinery remains in the code at zero, one constant away from re-arming.

- Scope: Steam install + `meshghost-fakeadapter` as the peer (relay loopback rig,
  `-ghost-collision=disabled`), single machine. A two-real-client session has not re-run this
  gauntlet.
- Rig note for repeats: the fake peer spawns at ZONE_LowerCastle (4718, 8712, -733) — the user's
  chosen standing spot, kept for future sessions.

## 2026-09-01 — the 2026-08-30 per-ghost performance win, restated here now that its crash is closed

The user's original report — 144fps alone, 70-80 with one peer, ~40 with three, ~30 with four —
was **four whole-world `FindAllOf` scans on the tick, not the hooks and not rendering**: unarmed
dev-toggle sweeps (~3300 us/frame), two whole-world light scans per ghost per tick (~6357
us/frame — the per-peer multiplier), a mesh sweep every 5th frame (~500), an afterimage scan
every tick (~1200). Fixes shipped 2026-08-30, user read 141-144fps with a peer; the crash that
shadowed that session is the nametag residue above, now closed. Numbers and the what-shipped /
what-reverted table: `UNVERIFIED.md` §"the PERFORMANCE WORK"; method:
`agent_docs/pitfalls/method.md`, "A ghost cost half the frame rate".

## 2026-09-01 — 150 peers live: stable, recoverable, and the wire is no longer the ceiling

The user watched the whole arc on screen, one fix per rung:

- **150 fake peers joined with zero wire errors** (bounded Welcome relay fix) and rendered as a
  ring of ghosts, every one wearing its nametag — the name-keep fix visibly working at scale.
- **The game no longer spirals at 150.** Before the drain collapse: single ticks of 19-45s, 0fps,
  and 2051 pawns measured alive as the backlog replayed spawn history. After: a stable slideshow
  (~250ms ticks, bounded, not growing), heavily starvation-amplified by the rig sharing the box.
- **Removing the crowd recovers.** Before: stuck at 20fps with a ~2000-corpse hangover. After:
  ~40fps within seconds, climbing to 50-60 — and a *reset to last save* (the crash of two days
  ago, now the cleanup tool) rebuilt the world and, user: **"put me at max fps again."** The
  50-60 plateau was transient corpse bloat awaiting GC, not a leak.

- Scope: one machine carrying game + relay + 150 synthetic cores (relay burned 530 CPU-seconds
  fanning ~450k msg/s); a two-machine run is the honest next measurement. Crowd rig calibration
  for repeats: ZONE_LowerCastle standing spot, ring z=-545, radius 200.
- Still open, filed in `UNVERIFIED.md`: `loop_tail` (the reflection redraw) dominates per-ghost
  cost (~80%), and per-ghost cost rises with world population — the two levers if crowds should
  ever be PLAYABLE rather than survivable.

## 2026-09-01 — the melee slash arc mirrors, user-confirmed: *"the slash works"*

The user found it on a two-client session (*"we are not doing the a vfx when using the melee
attacks"* -- *"like a curved slash ish going outward"*), and the whole loop closed inside the
hour: `probe_slashvfx` captured six swings (`NS_PlayerSlash`, world-spawned at the player's x/y,
+30 over the actor origin), the `sl` one-shot row shipped on the same counter path as `dl`/`bb`,
and the wire was watched end to end -- a swing on one client (`sl:0 -> 1`) fired `burst 'sl'` on
the other's ghost within ~0.3s -- before the user judged it on screen and confirmed.

- First DIRECTIONAL one-shot: spawned with the performer's `target_yaw`, written through
  SpawnSystemAtLocation's Rotation param by its reflected SIZE (the vendored FRotator marshals
  as float whatever the engine uses -- this adapter's `CLAUDE.md`). The user's confirmation did
  not separately call out direction; if a wrong-facing arc is ever reported, that write is the
  first suspect.
- Scope: two real clients, one machine. Found, measured, built and confirmed 2026-09-01.
- The same capture found `NS_FootstepDust` world-spawned at the feet and unmirrored -- filed as
  a candidate in `UNVERIFIED.md`, deliberately not added unasked.

## 2026-09-01 — the thrown sword, rebuilt on a component we own, and user-confirmed end to end

**The two-peer session refuted every loopback-era sword-throw confirmation** (the watching
PLAYER lost their sword to a peer's throw; the ghost's hand never changed; the prop froze
mid-air, snapped, sank), and the day ended with the whole suite rebuilt and confirmed on two
real clients:

- **The carrier was the spawned `BP_looseWeapon_C` itself** -- proven by a subtraction ladder
  (whole prop off -> player keeps sword; spawn-only -> player loses it) after four other
  carriers were exonerated by isolated, self-measuring probes. Its construction repoints the
  local player's `weaponRef` and strips `weaponEquipped?` -- a singleplayer class claiming THE
  player. Fix: `create_ghost_weapon_flyer` -- a mesh component on the ghost, same class and
  asset as its hand WeaponMesh (both read live; `SetSkeletalMeshAsset` is this build's setter),
  driven from the wire. User: *"Tsukino don't lose their weapon anymore."*
- **Flight, wall bounces and the tumbling pose**: the wire's own position+rotation replay, plus
  a measured constant -- the real sword's mesh sits at roll+90 inside its actor, composed
  exactly by adding to the innermost rotation. User: *"think air rotation/pose and the wall
  bounce vfx worked as intended."* Bounces are a sender-side velocity-sign-flip counter playing
  the measured `NS_WallKickHit` at the flyer.
- **Landing dust at the sword, not at anyone's feet** -- the sword's own `NS_DustLand` excluded
  from the player's `dl` counter by closer-to-sword distance, replayed on the 0->3 edge at the
  landing; our spawn registered for echo exclusion after one round of bouncing onto the other
  ghost. User: *"sword dust works properly now, not shown at any ghost/feet anymore."*
- **The landed ring**: world-aligned (attached, it stood on edge), floor-seated (38 units below
  the actor origin, measured), re-seated from the live target each tick, and hidden before
  destroy on the catch edge (this build has no `DeactivateImmediate` -- measured). User:
  *"the ground vfx goes away directly when picking it up"*; seating *"i think ... properly
  seated now"* (their hedge, kept).
- **The chair shadow**: `shadow_on` mirrors the player's `BlobShadow.bVisible` (the game's own
  sit/stand flag, measured by the shadow_sit capture) onto the ghost's component -- shipped
  inert once because the flag was read through a plain byte (the bitfield trap, third case);
  `mg_read_bool` masks properly. User: *"chair shadow is fixed properly now."*
- Scope: two real clients, one machine, one session (2026-09-01). Unwatched still: a throw
  across a map seam, a reset mid-throw, and the ring/dust on non-flat ground (the 38 is one
  floor's measurement).


## 2026-09-01 (evening) — the send-rate floor MEASURED on screen, the 15-vs-20 blind test, and the interp-per-link rule

**The rig for all of it:** two real instances through `meshghost-netsim`, relay rate stepped by
restart (the clients rejoin on their own -- quic takes ~17s to notice, then reconnects, which made
a 9-rung ladder cost zero relaunches). Two link tiers: "same-continent" (60ms/±25ms/2% loss/2%
reorder -- a ~120ms round trip) and "ocean" (100ms/±40ms/5% loss/2% reorder -- ~200 ping,
EU<->NA-on-bad-Wi-Fi grade, the user's target for a shipped default).

- **The sub-10Hz floor, watched for the first time** (a dev build lowered `MinSendHz` for the
  session; reverted the same evening): **1Hz** *"really snappy/teleporting"*; **3Hz** *"still
  teleporting everywhere"*; **5Hz** *"not teleporting anymore, but constantly snapping"*; **7Hz**
  *"visually smooth, but it jitter/lag every now and then"*; **10Hz** *"fine, but some stutters
  every now and then"*; **15Hz** *"can't really tell if there are any stutter/jitter things"*;
  20Hz clean. The interp-model's prediction held exactly: the wall sits where the sample gap
  (plus a loss hole) crosses the interp delay -- and the "constant snapping" rungs are LOSS
  showing through, not the base rate.
- **15Hz vs 20Hz is blind-indistinguishable at the same-continent tier.** Five rounds, rate
  hidden, user guessed 2.5/5 -- and their one consistent "15Hz tell" (a choppy thrown sword) fired
  on two rounds that were actually 20Hz, which convicted the sword's renderer, not the rate
  (below). At the ocean tier both rates were equally bad (three rounds: constant stutter at 15
  AND 20) until interp was raised, which settles that rate was never the lever there either.
- **The interp-per-link rule, measured:** on the ocean link at 15Hz, **250ms stuttered
  constantly, 350ms was smooth with rare blips, 375ms** *"actually looks fine, i saw 1 single
  snap"*. The rule: interp must clear the link's jitter PLUS its loss holes; raw ping does not
  matter (it only sets how far behind the ghost rides). **375ms is now this game's shipped
  default** (`client-config-overrides.json`), the user's call, with 250ms documented in the
  release README as the same-continent value.
- **The thrown sword's mid-air chop was the RENDERER, not the rate** -- the blind test's real
  finding. Fixed and user-accepted the same evening after three watched rotation strategies:
  position now glides one segment behind the wire steps (replacing the EMA chase); rotation is
  written straight through, because a fast tumble's direction is unreconstructable from these
  samples (shortest-arc drew it backwards -- *"swaps direction sometimes"* -- and
  velocity-continuity unwrapping ran away). Final state, the user: *"the rotation/spin is better
  (the original games spin also looks a bit choppy/low frame rate by design in pseudoregalia
  anyway) ... good enought for the sword throw."* The occasional position snap mid-arc stays OPEN
  (`UNVERIFIED.md`).
- Scope: one machine, two instances, simulated faults, walking/jumping/sword-throwing. The
  cross-adapter `DefaultSendHz` 20->15 change was deliberately NOT made tonight -- evidence
  supports it, decision pending.

## Pseudoregalia: 300ms interp at the 15Hz relay on the 60/25/2/2 proxy, on the fixed relay (2026-09-02)

**User, on screen, two real instances** (the main install and the Copy), both through `meshghost-netsim` at
60ms/±25ms/2% loss/2% reorder (~125ms one-way peer to peer, the proxy is crossed twice), relay at the
shipped 15Hz with loss cover on, quic, the relay carrying the limiter fix (`341a768`). Climbed from 250ms
with the core's `buffer dry` counter beside each rung:

| Interp | Dry renders (render time past a moving peer's newest sample) | The user |
|---|---|---|
| 250ms | 8%, max 163ms past | *"saw 1 stutter"* |
| 300ms | 0.5%, max 135ms past | *"I don't see anything bad/stutter etc."* |

**How this sits with the shipped 375ms:** that pick (`956790c`, 2026-09-01, before the limiter existed) was
made on the HARSHER ocean profile (~200 ping / ±40ms / 5% loss) and stands for that link; the README's
250ms same-continent line was measured at 20Hz on 2026-08-30. Tonight's profile sits between the two, and
at 15Hz it wants 300ms -- the same number TEVI settled on the same night on the same link
(`adapters/tevi/VERIFIED.md`). Nothing in the shipped config changed on this run.

## Pseudoregalia: 450ms interp at 15Hz on the WORST-CASE proxy (NA<->EU ping plus bad wifi), the ladder climbed on the fixed relay (2026-09-02)

**User, on screen, two real instances,** both through `meshghost-netsim` on the profile that is now
`run-netsim.bat`'s no-arg default and the only one a verdict is made on (user's rule that night): 100ms
±50ms one-way per pass (~200 ping peer to peer, the proxy is crossed twice), 5% loss, 3% reorder, a
one-second blackout every 45s. Relay at the shipped 15Hz with loss cover on, quic, the limiter fix in.
Climbed from 300 with the core's `buffer dry` counter beside each rung; "small-hole seconds" are the
rate-limited dry lines under 150ms past the newest sample, "outages" those over 500ms (the blackouts):

| Interp | Meter | The user |
|---|---|---|
| 300ms | dry on 20-40% of moving renders, transit avg 208ms | *"stutters"* |
| 375ms | 12 small-hole seconds in ~3 min, 3 outages | *"looked fine, but then it started to lag/stutter a lot for a tiny bit, also some small stutters here and there but overall fine?"* |
| 450ms | 6 small-hole seconds, 1 outage | *"Yee i think it looked good now, except for the big drop that was probly the wifi drop"* |

**So on the worst case Pseudoregalia wants 450ms at 15Hz; the one-second freeze every 45s is the blackout
itself and no interp value covers it.** The 300ms verdict from earlier the same night was on the milder
60/25/2/2 profile and stands only for that link. The shipped `375ms` was NOT changed on this run -- whether
450 ships is the user's call once all four games have their worst-case number.

## 2026-09-04 — a display name with quotes in it reaches the nametag WHOLE

**Human-gated track.** The user, with a screenshot of the ghost's tag: *"can confirm the name shows
up fully now"*.

- **Date:** 2026-09-04
- **Observed:** the nametag over a replay ghost reads the whole display name, quotes included,
  where hours earlier the same name rendered as `uwu325235#` followed by a backslash and nothing
  else. The name under test was deliberately hostile -- quotes, a currency sign, a run of
  punctuation -- and was the user's own idea for finding exactly this class of bug.
- **Source:** `json_string_field` in `MeshGhostPseudo/Mod/src/Plugin.cpp`, which scanned for the
  next bare quote and returned the raw bytes between it: an escaped quote (`\"` on the wire)
  ended the string early, and `\uXXXX` came back as its own text. It now decodes JSON escapes,
  surrogate pairs included.
- **One honest detail from the screenshot:** the currency sign renders as a missing-glyph box. That
  is the game's font having no glyph for it, NOT truncation -- every character reaches the tag, and
  the characters either side of it draw normally. A name made only of unsupported glyphs would look
  broken while being perfectly delivered, which is worth knowing before anyone debugs the next one.
- **Scope:** the same function reads every string field this adapter takes off the wire (`anim`,
  `area_id`, effect keys, the outfit path), so the fix is wider than nametags -- but only the
  nametag has been watched.

## 2026-09-04 — a zip of two recordings plays as two ghosts

**Human-gated track.** The user, after dropping one zip into `replay/active/`: *"saw both"*.

- **Date:** 2026-09-04
- **Observed:** one `.zip` holding two `.ndjson` recordings produced two replay ghosts in a running
  Pseudoregalia, from a single file the user made with Windows' own right-click compress.
- **Source:** `loadReplayAll` (`core/replay.go`). The clips were the user's own, 13,916 and 3,554
  samples; ids are `replay:<archive>/<entry>`, so clips from different zips cannot collide.
- **Why zip and not 7z:** zip needs no tool to make or open on Windows, which is the whole point of
  the feature; 7z would need a third-party LZMA decoder, and a `.7z` in the folder is logged as
  ignored rather than skipped in silence.
- **Nothing WRITES a zip**, and that is deliberate (ADR 0051): an archive cut short when the game
  closes is refused whole by ordinary tools, which is the fault that took gzip out of the recorder
  the same day.
- **Known and unsurprising:** both ghosts wore the same nametag, because both clips carry the same
  `name` in their header. Editing one clip's first line is how you tell them apart.
