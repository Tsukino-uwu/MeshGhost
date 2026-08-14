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
- **Gender read may resolve before a real save is loaded — raised by the user 2026-08-14,
  fix applied and confirmed live the same day.** `readLocalGender()` only ever runs once per
  session, the first time `getLocalState()` succeeds; that only checked `gSaveBlock1Ptr` being
  non-null, not that the player has actually finished the intro/title screen/character select.
  Every previous gender test (see the two "Closed 2026-08-11" entries above) was run with a
  save already present, so this path had never actually been exercised. If a bad read had
  occurred during the intro, it would have silently locked in the wrong gender for the rest of
  the session (no crash, no error — exactly the "plausible number instead of crashing" case
  CLAUDE.md warns about). **Fix**: the gender read is now additionally gated on `inOverworld()`
  (`adapters/pokemon/emerald/meshghost_emerald.lua`), the same gate already used before drawing
  remotes. **Confirmed live 2026-08-14**: user started BizHawk fresh with an existing female
  save, deleted it, created a new male-gender save, and watched the Lua Console directly — the
  `MeshGhost: local gender = ...` line did not print at all during the title screen/intro/
  character-creation sequence, and printed exactly once, correctly as `male`, only once actual
  gameplay began in the overworld. See `agent_docs/verified.md`.
  - **Confirms the most likely real trigger, per the user: booting BizHawk with no save,
    deleting/skipping to a fresh save, and picking a gender during character creation** — not
    the rarer "already playing, return to menu, delete and remake a save mid-session" case,
    which the user judged unlikely enough not to design around.
  - **Known, accepted limitation, not fixed**: `localGender` is cached for the rest of a Lua
    script session once resolved and never re-checked. If a player deletes and remakes a save
    as the other gender *mid-session* without reloading the script, their ghost keeps showing
    the stale gender to peers until they reload `meshghost_emerald.lua` — cosmetic only, no
    crash. Deliberately not fixed: the user judged this specific sequence (already playing →
    back to menu → delete → remake save, same session) rare enough not to be worth the
    complexity of re-checking gender on every `inOverworld()` false→true transition.
- **Licensing exposure**: `pokeemerald` carries no LICENSE file (see `agent_docs/licensing.md`)
  and SilklessCoop is restrictively licensed. Both are permitted as read-only fact sources,
  never as copied code — the risk is a future session forgetting that distinction under time
  pressure.
- **macOS distribution friction**: an unsigned Go binary will trip Gatekeeper on first run.
  Not a blocker for early phases, but worth planning for before a public release.
- **No-auth relay window — closed 2026-08-14, with two real limits.** Room-code auth shipped
  (`protocol.Hello.RoomCode`, constant-time-checked against `Server.RoomCode`; empty/unset
  means auth stays off, unchanged default). See the ADR in `agent_docs/architecture.md` and
  `internal/README.md`'s "What changed" section for the full record, including the design
  options considered (a plain shared secret was chosen over an HMAC challenge-response or a
  per-room lobby code). Two things this does **not** close: (1) **no TLS** — the code crosses
  the wire in plaintext, so this raises the bar from "anyone with the address" to "anyone with
  the address and the code," not to "safe against a network-level attacker"; tracked as its own
  entry below. (2) **the new "stale relay" risk**, also below — auth is enforced entirely by
  the relay, so it only works if the relay binary is current.
- **No TLS on the relay/bridge connection.** `internal/transport` is plaintext NDJSON over TCP,
  deliberately, for the "greppable with netcat" debuggability property (see
  `internal/README.md`'s "Why TCP, not UDP" section). This means room-code auth (above) doesn't
  defend against a network-level attacker who can observe the connection — they can read the
  code in transit. Not attempted as part of the 2026-08-14 hardening pass (see that ADR's
  "Options considered (auth)" for why); a real, separately-scoped piece of future work if the
  threat model ever requires it.
- **Stale relay silently disables room-code auth — found while scoping the 2026-08-14 pass,
  from the user asking what happens with an old client/server against new ones.** Room-code
  auth is enforced entirely by the relay (the host controls admission, not each joiner — the
  correct architecture), which means it only exists if the *relay* binary is current. A
  `room_code` in an old relay's `config.json` is an unrecognized JSON field to that binary and
  is silently ignored — no error, no warning, the relay just starts up open. A host could set a
  room code, believe their session is protected, and be completely wrong, with nothing telling
  them so. Not a client-side problem and can't be fixed client-side. See the ADR in
  `agent_docs/architecture.md`'s "Consequences" for the full reasoning. Follow-up not yet done:
  `internal/README.md`/`packaging/README.md` should say plainly that room-code auth requires an
  updated *relay*, not just an updated client.
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
- **No game-version check between peers, surfaced by TEVI (Phase 6) — closed 2026-08-14, with
  one real limit, and evidence the limit is the right call, not just an accepted gap.** `hello`
  now carries an optional `game_version` (`protocol.Hello.GameVersion`/`bridge.Hello.GameVersion`),
  sticky per room the same way `game_id` already is; a mismatch is refused at handshake. See the
  ADR in `agent_docs/architecture.md`. **The limit**: each shipped adapter reports its own
  adapter/mod version (e.g. Emerald's `"phase5.5"`, TEVI's BepInEx `PluginVersion`), not the
  actual game/DLC build — there's no cited memory address to read a real game version from in
  any of the three games, and `CLAUDE.md`'s rule against guessing addresses from memory means
  one wasn't invented for this. So this catches two peers on different *adapter* revisions, not
  a real game-version/DLC mismatch.
  - **User feedback, 2026-08-14, real usage evidence**: TEVI has actually been played across
    different game builds/versions successfully — interoperates fine as long as the map/world
    itself hasn't changed, contradicting the original Phase 6 worry that any version difference
    would cause silent desync. DLC compatibility specifically is still untested either
    direction (the user doesn't own the DLC; the older build predates it existing at all).
  - **This changes the right design for any future real-version check, not just this session's
    scope**: the earlier "wiring in TEVI's actual build/DLC state as `game_version` would be a
    natural, low-risk follow-up" framing was wrong given this evidence — a **hard reject on any
    version difference would incorrectly block a combination already known to work**. If a real
    game-version read is ever added, it should not reuse this field's current hard-reject
    behavior as-is; a softer signal (e.g. a warning surfaced to the user, not a connection
    refusal) or a narrower check (DLC presence/absence specifically, since that's the one
    axis actually untested) would better match what's actually been observed. Not designed —
    just recording the constraint so a future session doesn't rebuild the wrong version check.
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
  `agent_docs/phases/phase7.md` for the full investigation.
  **Mechanism confirmed 2026-08-12**, not just inferred: read the actual maintainer/reporter
  thread on `UE4SS-RE/RE-UE4SS` issue #577 (`gh issue view 577 --repo UE4SS-RE/RE-UE4SS
  --comments`). The gate is exactly the Epic-Games-account-linked-to-GitHub mechanism guessed
  earlier — linking a GitHub account to an Epic Games account (epicgames.com account settings)
  sends an invite to the `github.com/EpicGames` org; **accepting that invite** is the fix, per
  a RE-UE4SS collaborator (`Buckminsterfullerene02`) and confirmed working immediately after by
  another reporter (`Jenspi`). One documented wrinkle: a June 2024 Epic bug briefly routed new
  links to a separate "mirror" GitHub org without the same fork access — watch for an invite
  that isn't from the org named plain `EpicGames` if this doesn't work on the first try. No
  other steps reported in the thread (no NDA, no manual approval queue).
  **Resolved 2026-08-12**: user linked their GitHub account to their Epic Games account
  (Connections → Accounts → GitHub, OAuth authorize, propagation took a few minutes as
  expected) and accepted the resulting `EpicGames` org invite. `git submodule update --init
  deps/first/Unreal` in the local `RE-UE4SS` checkout then succeeded — 2498 real files (headers,
  source, `CMakeLists.txt`), not an empty stub. **The C++/UEPseudo path is unblocked.** This
  reopens the Phase 7.2 "C++ for the shipping adapter" option, no longer forced into Lua-only —
  still needs a real build attempt before trusting it (submodule clone success only proves
  access, not that the build itself succeeds).
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
  **Reopened 2026-08-12, same day, once 7.5 exercised this under real sustained traffic**: Stage
  3's one-shot probe (a handful of hardcoded dummy frames) never hit this; the real adapter
  running at 10Hz two-way for tens of seconds hits it constantly. Confirmed via layered
  diagnostics in `main.lua` (send counters 100% ok; raw receive-line counters showing 83-98% of
  lines failing to decode; a hex dump of the actual bytes showing well-formed JSON up to an
  inconsistent cutoff point, then unreadable data for the rest of a line `#line` still reports the
  full length of) that this is genuine data corruption on receive, not a JSON-format or
  application-logic bug. Neither message size (area_id shortened ~325→~274 bytes, no change in
  failure rate) nor send frequency (100ms→250ms tick, no change) is the trigger; the failure rate
  does drop from ~98% early in a connection to ~83% by 30-45s in, in every test, independent of
  both — consistent with a timing/reentrancy bug in the vendored DLL pair, not a fixed size limit.
  **The `lua_State`-mismatch risk this entry originally raised is not closed after all** — it was
  only ever exercised lightly before. See `agent_docs/phases/phase7.md`'s 7.5 entry for the full
  diagnostic trail. Next steps, neither tried: an alternate vendored LuaSocket build, or the
  C++/UEPseudo path (still blocked on private submodule access, above).
  **Resolved by side-by-side comparison, 2026-08-13**: with UEPseudo unblocked (above), a native
  C++ bridge client (`adapters/pseudoregalia/MeshGhostPseudo`) was run *simultaneously* with the
  still-enabled Lua `MeshGhostGhostProbe`, both connected to the same bridge port at the same
  real time, against identical live traffic. `UE4SS.log` shows the Lua side still corrupting
  ~98% of received lines (386 received, 379 malformed) while the C++ side received 6058+ lines
  with **zero** malformed. This isn't a difference in load or timing (same session, same
  wall-clock window) -- it isolates the vendored `lua54.dll`/`socket-windows-5-4.dll` pair itself
  as the cause, not the core, the relay, or the wire format. The C++ rewrite is the resolution;
  no alternate LuaSocket build was ever needed.
- **Spawning the player's own gameplay Blueprint as a placeholder ghost physically dragged the
  player, found 2026-08-12, root cause confirmed the same day**:
  `adapters/pseudoregalia/probe_ghost/Scripts/main.lua` spawned a second instance of
  `BP_PlayerGoatMain_C` 150 units from the player. The user was physically dragged/pulled
  toward another location at high speed on three separate runs, until dying each time. Two
  wrong theories tried and ruled out in turn — disabling `SetActorEnableCollision`/
  `SetActorTickEnabled` on the ghost made no difference, then a rewrite to stop mutating a
  suspected live-reference FVector read from the pawn *also* made no difference (still dragged,
  identically, on the very next run). **Confirmed root cause, via a read-only diagnostic
  script that performed zero repositioning and still let the address logging speak for
  itself**: `BP_PlayerGoatMain_C` auto-possesses on spawn, silently swapping
  `PlayerController.Pawn` to the newly-spawned ghost — every "fix" was moving what it believed
  was a separate, uncontrolled placeholder, but the ghost *was* the actual possessed,
  camera-attached character the whole time. Fixed by calling `controller:Possess(pawn)`
  immediately after spawn to hand control back to the original pawn. See
  `agent_docs/verified.md` and `agent_docs/phases/phase7.md` for the full five-bug history.
  **General lesson for any future UE4SS Lua script in this repo that spawns another instance of
  a controllable pawn Blueprint**: assume it may auto-possess on spawn until proven otherwise
  for that specific class, and re-possess the original pawn defensively right after spawning —
  don't assume a spawned actor is inert just because nothing told it to take control. (A weaker,
  now-superseded version of this lesson — about never writing into a vector/rotator struct read
  from an actor you don't intend to move — turned out not to be the actual mechanism here, but
  is still reasonable defensive practice and is enforced by `main.lua`'s current design either
  way.)

- **Enabling ghost collision can kill the real player's own character, confirmed live
  2026-08-13.** Tried `SetActorEnableCollision(true)` on the spawn-based Pseudoregalia ghost
  (was `false`) as a real fix attempt for the stuck-falling-pose and can't-grab-ledges
  animation bugs (both plausibly need a real physics trace to detect ground/ledge contact).
  **Confirmed live, corrected from an earlier wrong write-up**: the ghost did *not* become
  physically solid — the real player could still walk straight into/through it, no blocking
  collision at all. But it could be attacked and killed with melee, and doing so killed the
  **real player's own character**, not just the ghost. So this one call produced the worst
  combination: no physical solidity (the actual goal), but real vulnerability to being killed
  (a new danger). Consistent with standard UE behavior: `SetActorEnableCollision` only restores
  whatever `CollisionEnabled` query/physics mode the component's existing collision profile
  already specifies — it does not change per-channel collision *responses* (Block/Overlap/
  Ignore). A stock "Pawn" collision preset commonly overlaps (not blocks) other Pawn-channel
  actors by default while still registering weapon-trace hits via that same overlap query — real
  physical blocking would need an explicit response-channel change, separately from this toggle,
  not guessed yet. The real-player-death effect is the more serious finding on top of that: it
  suggests health/damage state on `BP_PlayerGoatMain_C` may not be safely scoped per-instance (a
  `'As MV Game Instance Ref'` object property, found during the animation-state reflection dump,
  is one candidate mechanism, not yet confirmed) — i.e. this game's own gameplay Blueprints were
  plausibly never written to expect two live instances of the player class at once, unlike an
  NPC class. **Reverted same-day.**

  **Second attempt, same day, also failed, real melee-death risk still unaddressed**: added
  `UPrimitiveComponent::SetCollisionResponseToChannel(ECC_Pawn, ECR_Block)` on the ghost's own
  `CapsuleComponent` on top of `SetActorEnableCollision(true)`, via a real UFunction call whose
  parameter offsets come from the function's own reflected properties (not a guessed struct
  layout). Confirmed via log that the function was genuinely found and the call made — no
  reflection failure this time, unlike many other UFunctions on this build. Still no physical
  solidity; the real player could still walk straight through the ghost. Leading theory: UE's
  dynamic-vs-dynamic actor blocking requires **both** actors' collision response to agree on
  Block, and only the ghost's side was ever changed — the real player's own capsule was very
  likely never configured to Block the Pawn channel at all, since two-pawn contact was never a
  real case in a single-player game. Fixing that would require modifying the **real player's
  own live collision component**, not just the ghost's — a materially bigger risk than anything
  tried so far, layered on top of the still-unresolved melee-death danger above. **Reverted
  same-day** (`GHOST_COLLISION_ENABLED` toggle in `Plugin.cpp`, currently `false`). Do not
  re-enable, and do not attempt modifying the real player's own collision setup, without
  explicit go-ahead given the accumulated risk.
- **Open question, raised by the user 2026-08-13, not yet investigated**: does *any* in-world
  damage source reach the ghost and propagate to the real player the same way melee did, or was
  that specific to collision-enabled melee hit detection? With collision back off (current
  state), the ghost should be undetectable by most world hazards, but this hasn't been checked
  — some UE trigger volumes (hazards, out-of-bounds kill-Z, scripted death triggers) fire on
  overlap events that may not depend on the same collision toggle just tested. Needs its own
  grounded investigation (what actually caused the real-player death above) before any future
  collision-related change, not an assumption that "collision off" fully closes this off.
- **New data point, 2026-08-14, minor and not yet investigated: the ghost may be able to land
  attacks on the real player, in the opposite direction from the 2026-08-13 finding above.**
  During otherwise-successful live testing of this session's rebuild (ghost spawn/follow/
  animate all confirmed working, see `verified.md`), the user did a flip, gained height, and
  spammed attacks; the ghost appeared to land hits back — the real player's hit/hurt (red flash)
  animation played, though the player didn't die, and this reproduced a few times under the same
  conditions (airborne + rapid attack spam). `GHOST_COLLISION_ENABLED` is confirmed still `false`
  in the current build (`Plugin.cpp:143`, unchanged by this session's fixes), so the mechanism is
  unclear — this is the same open question above (does something other than the disabled
  collision toggle let a hit register?), just observed from the other direction: the *ghost's*
  attack reaching the player, not the player's damage reaching the ghost. Two real possibilities,
  neither confirmed: (1) the same shared/not-per-instance state theorized in the 2026-08-13 entry
  (`'As MV Game Instance Ref'`) could mean the ghost's attack-hit trigger and the real player's
  hurt-react are reading/writing the same instance-scoped gameplay state rather than two
  genuinely separate pawns; (2) an attack hitbox/trigger volume keyed off proximity or animation
  state rather than the `SetActorEnableCollision`/response-channel path already tested, which
  would explain it surviving collision being off. **Not yet reproduced with a minimal isolated
  test** (e.g. does it happen with no attack spam, does height/airborne state matter, does it
  happen with the real player *not* attacking at all) — treat the "airborne + attack spam"
  framing as the user's field observation, not a confirmed trigger condition. Low priority (no
  real damage taken), but should be investigated with the same rigor as the collision work above
  before any future combat/animation-adjacent change, since it points at the same
  "two live instances of a class the game never expected to duplicate" risk class.

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
