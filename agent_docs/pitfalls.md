# Adapter pitfalls

This file is the durable record of **adapter-specific** issues: things that went wrong while
building a game adapter, how they were tracked down, and what fixed them. It exists so the
next game adapter starts from the lessons already paid for instead of re-learning them.

**Scope boundary** — this file is not a duplicate of the others:

- `agent_docs/verified.md` holds confirmed runtime facts (dates, sources, human-gated). This
  file links to those entries by heading rather than restating the evidence.
- `agent_docs/risks.md` holds open/closed design risks and forward-looking assumptions. This
  file holds closed incidents: symptom → cause → fix.
- `agent_docs/phases/*.md` hold the chronological run-by-run log for each phase and stay
  around afterward as an archive — but they're long and narrative. This file pulls out the
  transferable lessons so a future adapter author doesn't have to re-read a whole phase's
  saga to find them.

## Diagnostic methodology

Rules that kept paying off across multiple sagas below. Each came from a specific incident —
know the incident, not just the rule, so you can judge when it applies.

- **One diagnostic at a time.** Add the next probe only after the previous one gave a clean,
  unambiguous answer. Stacking multiple changes at once (a fix + a new log line + a new
  guard) makes it impossible to tell which one mattered. Source: the Phase 7.5 LuaSocket
  investigation (`phase7.md`), which narrowed a "ghost teleports instead of following" bug
  through five sequential, single-variable probes before finding the real cause.
- **Two guessed fixes failing identically is a signal, not bad luck.** If a second guess
  reproduces the exact same symptom as the first, both guesses were wrong in the same way —
  stop guessing and go isolate instead. Source: the Phase 7 player-drag bug, where a
  collision-disable fix and a live-reference fix both failed identically, which is what
  triggered writing a zero-repositioning diagnostic script instead of a third guess.
- **Never log the value you just wrote.** A log line that echoes the value your own code just
  set proves the code ran, not that the world changed. Read back an independent value instead
  (`actual = ghost:K2_GetActorLocation()`, not the local variable you wrote into `ghostLoc`).
  Source: Phase 7's rendering saga — ten runs of reassuring `positions:` log lines turned out
  to be proof of what the script wrote, never proof the actor's transform changed.
- **Run the same test without the fix applied.** If a "fix" is real, removing it should change
  the outcome. If the bug reproduces identically with the fix skipped, the fix was never the
  mechanism. Source: an early camera-fix attempt in Phase 7 that looked plausible until a
  no-fix control run produced the identical (wrong) result.
- **Isolate by subtraction.** When several plausible causes compete, write a diagnostic that
  does the *minimum* — e.g. spawn the actor and log addresses every tick, with zero
  repositioning logic — and let that alone answer which theory survives. Source: the Phase 7
  drag-bug `diagnose.lua`, which proved `controller.Pawn` had silently swapped to the ghost
  by removing every other variable from the test.
- **Verify the deploy before trusting a live run.** `diff` the file actually copied into the
  mod/script directory against the repo copy before believing a "first test of the new
  design" — a stale deployed file makes a live test meaningless. Source: Phase 7 hit this
  twice; every later deploy in that phase is explicitly logged as "confirmed via diff."
- **When bundled docs and installed binary disagree, read the actual source at the installed
  SHA.** Third-party doc bundles (e.g. UE4SS's `docs/lua-api`) can describe a larger surface
  than what's actually compiled into the version you have. Source: Phase 7's UE4SS reflection
  gaps — the docs described APIs the installed `UE4SS.dll` didn't expose.
- **A staged probe ladder must include sustained real traffic, not just a round trip.**
  Capability check → object creation → one real round trip is not sufficient to close a risk
  about behavior under load — test at the actual rate and duration the real feature will use
  before declaring it closed. Source: the LuaSocket ABI risk (`risks.md`) — a clean one-shot
  Stage 3 round trip passed, the risk was marked closed, then reopened the same day once real
  10Hz sustained traffic revealed an 83-98% receive-side failure rate that light testing never
  hit.
- **`pcall` does not protect a deferred callback.** Code running inside
  `ExecuteInGameThread` (or any deferred/async callback) is not on the caller's stack — a
  `pcall` wrapping the call that *schedules* the callback does not catch errors thrown
  *inside* it. Source: Phase 7, a diagnostic call that crashed past its own `pcall` this way.
- **When a blocker looks externally imposed (404, access denied, private repo), spend real
  effort tracing the exact mechanism before routing around it with a workaround — a workaround
  that "passes a test" can hide a worse problem than the one it avoided.** Phase 7 hit the
  private `UEPseudo` submodule blocker early (7.2), treated it as a hard wall after a `gh api`
  404 and an SSH failure, and pivoted to a Lua-only shipping adapter instead of digging into
  *why* the submodule was private. The pivot wasn't unreasonable in isolation — the Lua
  workaround (`package.loadlib` + a vendored LuaSocket DLL) was real engineering, validated with
  a genuine Stage 1→2→3 probe ladder including a real connect/send/receive round trip — but that
  round trip was light traffic, and the same "staged probe ladder must include sustained real
  traffic" gap above meant the workaround's fatal flaw (an ABI/timing bug corrupting 83-98% of
  received lines under real 10Hz load) wasn't caught until 7.5, well after the Lua path had
  already been built out through spawn/possession/camera-fix. The actual cause of the original
  blocker turned out to be one targeted web search away: `UE4SS-RE/RE-UE4SS` issue #577 spells
  out that linking a GitHub account to an Epic Games account unlocks the exact submodule, a
  fact nobody looked for at the time because the workaround already seemed to be working. Had
  that search happened at 7.2, the entire Lua-networking saga — and the eventual C++ rewrite
  once the corruption bug proved unfixable — might have been unnecessary. **Generalizes to**:
  treat "access denied" as a question to research (who gates this, how does anyone get past it),
  not just a wall to build around — especially before investing in a workaround substantial
  enough that undoing it later is expensive.

## Failure signatures

Misleading symptoms that mean something other than their surface reading:

| Symptom | Actual meaning |
| --- | --- |
| UE4SS Lua: "Tried calling a member function but the UObject instance is nullptr" | Usually means the UFunction isn't reflected on this build, not that the object is actually null — confirm the object's validity separately before trusting this message. |
| An API call reports success but the on-screen symptom is unchanged | The call may be hitting the wrong object/mechanism entirely (e.g. poking a `CameraComponent` when the game's camera system doesn't use it) — stop iterating on the call and question the target. |
| Console output truncates or corrupts partway through an unprintable byte | The console itself is truncating on unprintable bytes, not a bug in the data — hex-dump instead of plain-text logging when bytes might be non-ASCII. |
| A property write succeeds and reads back correctly, but nothing changes on screen | Direct UPROPERTY writes can "stick" (readback confirms) without the engine acting on them if the underlying mechanism (e.g. render state, mobility) needs a separate trigger. |
| A read is `(0,0,0)` or otherwise implausible right after a spawn/level load | Reading a transform before the engine has placed it — guard with a plausibility check, don't trust the first read after spawn/load. |

## Pitfalls by theme

### Spawned actors auto-possessing (taking control away from the player)

- **Symptom**: spawning a second copy of the player's own controllable Blueprint (e.g.
  `BP_PlayerGoatMain_C` in Pseudoregalia) silently swapped `PlayerController.Pawn` to the new
  actor. The player was physically dragged around (and once, killed) as ghost-follow logic
  moved what it believed was an inert placeholder.
  - **Probe**: an isolate-by-subtraction script that spawned with the same guards but
    performed zero repositioning, logging only object addresses and `controller.Pawn` each
    tick — confirmed `controller.Pawn == ghost` immediately after spawn.
  - **Cause**: the spawned class auto-possesses on spawn (`AutoPossessPlayer` or equivalent).
  - **Fix**: capture the original pawn/controller *before* spawning, and call
    `controller:Possess(originalPawn)` immediately after every spawn — including subsequent
    ghosts, not just the first (the bug recurred identically when a second ghost was added
    without re-possessing).
  - **Generalizes to**: any engine/framework where a controllable actor class may
    auto-possess. Treat a spawned controllable-class actor as "may steal control" until
    proven otherwise for that specific class, and re-possess defensively right after every
    spawn. See also `risks.md`'s auto-possession entry (search "auto-possess") for the
    forward-looking risk framing of the same lesson.
  - **Related backstop pitfall**: a `MAX_TICK_DELTA` guard added to catch this class of bug
    (refuse and log an implausible single-tick move) then caused a *new* bug — a legitimate
    large player dash got refused forever with no recovery path, freezing the ghost
    permanently. Fix: a refusal counter that treats N consecutive refusals as a real
    displacement and resyncs. **Lesson: a safety backstop with no recovery path is itself a
    bug.**

### Camera / view-target ownership

- **Symptom**: after spawning a ghost actor, the game camera stayed locked onto the ghost
  instead of the player, surviving every attempt to explicitly set the view target back via
  UFunction calls, property writes, component activation/deactivation, and component
  destruction — 13 sequential attempts, all failing without a clear reason.
  - **Probe that broke it open**: a read-only hook on the controller's own
    `SetViewTargetWithBlend` call (never overriding, just logging) caught the *game's own
    code* re-picking a camera target ~2.6ms after the ghost spawned — reframing the bug from
    "our fix doesn't apply" to "something the game does on its own overrides us."
  - **Cause**: the game used a curated, pre-placed camera-rig system (dedicated actors the
    controller targets), not a pawn-owned camera component — every attempt had been poking
    the wrong object. The re-pick was most likely triggered by the spawned ghost briefly
    sharing collision/proximity with the player before collision was disabled.
  - **Fix**: a post-hook on the game's own view-target-setting call that captures the
    "last known good" target the first time it fires with no ghost present, then re-forces
    that target (deferred, with a same-target short-circuit to avoid a hook loop) whenever a
    later call moves away from it while a ghost exists.
  - **Generalizes to**: before assuming a pawn owns its own camera, check whether the game
    uses a dedicated camera-rig/controller-driven system instead — especially in
    third-person/platformer engines with curated per-area camera framing.
  - **Related transition pitfall**: a level transition destroys the old camera rig, which
    invalidated the cached "last known good" reference — the hook's first version gave up
    forever instead of re-baselining. Fixed by treating a stale/invalid cached reference the
    same as "never learned yet."

### Runtime-spawned actors not rendering

- **Symptom**: a `StaticMeshActor` spawned at runtime via the engine's own spawn API never
  appeared on screen, across six different attempts (mesh assignment, visibility calls,
  render-state-dirty calls, mobility changes, using a guaranteed-cooked mesh) — every API call
  reported success.
  - **Probe**: instead of spawning, reposition an actor that already exists in the level
    (found via a class-search API) — it rendered and moved correctly immediately.
  - **Cause**: on this build, actors spawned at runtime through the engine's plain spawn API
    did not render, while pre-existing level actors did. The one class known to render when
    spawned was the player's own Pawn subclass — suggesting the split is Pawn-vs-plain-Actor
    spawning specifically, not native-vs-Blueprint or dev-asset-vs-cooked-asset (both of
    which were tested and ruled out).
  - **Fix (practical)**: prefer spawning/duplicating a Pawn-class actor over a plain
    `StaticMeshActor` for anything that must render at runtime, or reposition/reuse an
    existing level actor if one is available.
  - **Status**: root engine-level cause was never confirmed (blocked on inaccessible engine
    source) — treat as a build-specific constraint, not an explained mechanism.

### Engine reflection / API availability

- **Symptom**: many UFunction calls that should exist per the engine's own bundled
  documentation failed outright on the actual installed build, while direct property
  (UPROPERTY) reads/writes reliably worked.
  - **Working pattern found**: prefer a direct property write (`component.Property = value`)
    over a setter UFunction call when both exist, on builds where reflection appears
    stripped down. Confirm every unfamiliar API's real usage by searching public source
    (e.g. `gh api search/code`) for hit counts before trusting it — "0 hits both ways" is
    itself grounds to treat a call as speculative rather than reliable.
  - **Cause (leading theory, unconfirmed)**: a Shipping-type build can strip Blueprint
    reflection for any UFunction never actually invoked by the game's own Blueprints, which
    would explain an inconsistent working/failing pattern that doesn't track cleanly with
    "old vs new API" or "core engine vs game-specific."
  - **Generalizes to**: on any embedded scripting/reflection layer (UE4SS Lua, modding APIs
    in general), do not assume a documented API works on the specific build you're targeting
    — verify each one live, and keep a running list (in your own phase notes) of
    confirmed-working vs confirmed-failing calls for that build, since the pattern isn't
    guessable in advance.
  - **A property-by-name lookup may only search the object's own most-derived class, not
    inherited properties.** UE4SS's C++ SDK (UEPseudo) exposes both
    `GetValuePtrByPropertyName` and `GetValuePtrByPropertyNameInChain` as separate functions —
    the plain version silently returned null for a property (`Pawn`) declared several levels up
    the inheritance chain from the actual object's class (`MainPlayerController_C` extends
    `PlayerController` extends `Controller`, where `Pawn` lives), while the `InChain` variant
    found it correctly. Symptom looked identical to "the object doesn't have this property yet"
    (a timing bug), and was only distinguished from a real timing bug by cross-checking against
    a sibling Lua mod reading the same property successfully at the same tick.

- **First `FindFirstOf` returning the wrong instance for a UI-adjacent lookup**: reflection
  helpers like `FindFirstOf("PlayerController")` return the *first* matching object in the
  engine's global object array with no filtering — which is as likely to be the class's CDO
  (Class Default Object, a template instance that always has empty/default properties) as a
  real, active instance. UE4SS's own Lua convenience library (`UEHelpers.lua`) works around this
  by using `FindAllOf` plus an explicit validity/CDO filter rather than trusting the first match
  — the same filtering is needed when reimplementing equivalent lookups directly (e.g. in a C++
  mod), not just assumed away because "FindFirstOf" sounds authoritative. An `RF_ClassDefaultObject`
  object-flag check is a reliable, standard-UE way to exclude the CDO specifically.

### UE4SS C++ mod threading -- on_update() is not the game thread

- **Symptom**: an actor's position was repositioned every tick from `CppUserModBase::on_update()`.
  Every read-back of the position immediately after the write matched exactly, on every single
  logged tick, for entire sessions across real level transitions -- yet the actual on-screen model
  visually froze in place after following correctly for a while, every single time, regardless of
  which actor was targeted, its Mobility setting, distance to the camera, or whether a forced
  render-refresh nudge (toggling `bHidden` off/on) was applied. Multiple targeted fixes (Mobility
  force-write, bHidden toggle, preferring already-Movable candidates) all failed to change the
  outcome, and all read back as "successful."
  - **Cause, confirmed by reading UE4SS's own source, not inferred from the symptom**:
    `UE4SSProgram::update()` (`UE4SS/src/UE4SSProgram.cpp`), the function that calls every C++
    mod's `on_update()` for every loaded mod, calls
    `ProfilerSetThreadName("UE4SS-UpdateThread")` and runs its own loop with
    `std::this_thread::sleep_for(std::chrono::milliseconds(5))` — a dedicated UE4SS-internal
    polling thread, entirely separate from the real Unreal game thread. `on_update()`'s own header
    declaration (`Mod/CppUserModBase.hpp`) documents no threading guarantee at all. Every actor
    write from `on_update()` was landing in memory (hence the always-matching same-thread
    readback) but never reaching the renderer, which expects transform changes to flow through
    the real game thread's tick and component-update pipeline.
  - **Fix**: register a `Hook::RegisterEngineTickPostCallback` (`Unreal/Hooks/Hooks.hpp`) in
    `on_unreal_init()` and move all actor reads/writes into that callback instead — it hooks the
    real `UEngine::Tick`, so it genuinely runs on the game thread. Keep `on_update()` for anything
    that doesn't touch UObjects (e.g. pure socket I/O), and hand data between the two threads with
    a mutex if both need to touch shared state.
  - **Generalizes to**: this is the exact same reason Lua code throughout this whole project has
    needed `ExecuteInGameThread()` wrapping for anything touching game state — Lua's own
    `LoopAsync`/timer callbacks aren't guaranteed to run on the game thread either, only
    `ExecuteInGameThread`-wrapped code and native engine hooks are. A C++ mod has no equivalent
    "just wrap it" helper exposed — the fix is to do the work inside a real engine hook
    (`EngineTick`, `ProcessEvent`, etc.) instead of the mod's own `on_update()`.
  - **Diagnostic dead ends this caused, recorded so they aren't re-tried first next time**: a
    forced Mobility flip (Static → Movable) via direct property write, an "always prefer an
    already-Movable hijack candidate" heuristic (which also had the side effect of preferring
    gameplay-relevant moving objects like walls/platforms over safe decoration — backwards from
    what a safety heuristic should want), and a periodic `bHidden` off/on toggle nudge. None of
    these were the actual bug; all were symptoms of the same underlying thread issue and stopped
    being necessary once the writes moved to the real game thread.
  - **How it was actually found**: not guessed — isolated by testing a local-only reproduction
    (no bridge/core/relay, just reposition a hijacked object to the local player's own position
    every tick) to rule out networking, confirming the freeze was independent of it, then reading
    UE4SS's own source for exactly how `on_update()` gets invoked rather than assuming its
    execution context.

### Level/scene transitions invalidating cached references

A recurring bug class across every engine touched so far: anything cached across a level,
scene, or area transition can go stale, and the failure modes vary by what "stale" means in
that engine.

- **Pseudoregalia (UE5)**: a transition can nil out a cached actor reference between when a
  deferred callback is scheduled and when it runs — `not ghost:IsValid()` on a nil reference
  is a hard Lua error, not a clean "invalid" result. Fix: check `== nil` explicitly before
  calling any method on a cached reference.
- **Pseudoregalia (UE5)**: a transition produces an entirely new pawn instance (different
  object identity), so any cached pawn reference from before the transition is simply wrong
  after it, not merely uninitialized.
- **Pokemon Emerald (BizHawk/Lua)**: the save-block pointer relocates in memory and must be
  re-read every frame, never cached. Separately, reads taken during the exact frame of a map
  transition can return transient garbage (a placeholder coordinate, a stale prior-frame
  value, or an all-zero frame) — not a fixed pattern per warp type, but a general
  "mid-relocation read" glitch. Fix: a one-frame debounce around any detected area/map change
  before trusting position or facing data.
- **Generalizes to**: assume any cached actor/pointer/object reference is invalid immediately
  after a transition until freshly re-acquired, and add an explicit debounce window around
  the transition itself for any data read that might land mid-relocation — don't assume a
  transition is atomic from the adapter's point of view.

### Memory probing / address hunting (Emerald-style, static addresses)

- **Gate every address on a byte-identical build.** An address is only trustworthy if it was
  found in a local build that matches the target binary byte-for-byte (verified via the
  project's own compare/checksum tooling) — a differently-configured build (different
  toolchain, different compiler) can shift addresses even from the "same" source.
- **Cross-check symbol tables, and check size against struct math.** Confirm an address
  independently in more than one generated artifact (map file and symbol file), and where a
  size is reported, verify it against the expected struct layout math rather than accepting
  it on faith.
- **Bitfields need an on-screen check, not just a struct read.** C bitfield packing order
  isn't guaranteed by the standard — confirm a bitfield's meaning by producing all its known
  values in sequence in-game and matching them against the read, not by reading the struct
  definition alone.
- **Test state against known motion, not "a number changed."** A value that changes when you
  move is not proof it means what you think it means — confirm it changes in the *specific*
  way your theory predicts (e.g. facing-direction values matching a known direction
  sequence).
- **Probe every state where a value might be meaningless**, not just the states where you
  expect it to work — menus, dialogue, forced-movement cutscenes, and battle are all worth
  explicitly checking, and "confirmed still valid here too" is as real a finding as the
  reverse.
- **A patch/randomizer applied to the base game can silently invalidate fixed addresses**
  while leaving pointer-relative reads intact — plan the fallback (e.g. deriving a value from
  a position delta instead of a flag) as the *only* code path where relevant, not as a
  conditional triggered by garbage-detection, since garbage-detection itself can't
  distinguish "wrong patch" from "different patch that happens to return plausible data."

### Overlay / sprite rendering (2D, retained-mode drawing APIs)

- **Drawn overlay graphics can persist across frames with no auto-clear.** If the host's
  drawing API is retained rather than cleared automatically, stopping your own draw calls
  (e.g. because the connection died) leaves the last frame's drawing stuck on screen forever.
  Fix: unconditionally clear the overlay at the top of every frame regardless of connection
  state, don't rely on "we always draw every frame" as an implicit clear.
- **Verify a color format against the host's actual source, not by pattern-matching other
  scripts.** A byte-order assumption (e.g. ARGB vs RGBA) copied from other scripts' constants
  can be wrong; confirm against the host's own implementation.
- **A sprite/object index can be silently reused by an unrelated game system** (e.g. a UI
  element reusing the same pooled sprite slot as the player during a mode change). If a
  tracked visual starts drifting in sync with something unrelated (a UI bar, an animation),
  suspect index/slot reuse rather than a math error in your own positioning code — and
  consider gating your feature off entirely during the state where the pool is reused, rather
  than chasing the reuse itself.
- **A sprite anchor point may not be the tile/ground position** — a returned screen position
  can be a bounding-box corner rather than the point the character visually stands on,
  requiring a manual correction confirmed by eye, not by re-deriving it from sprite
  dimensions.
- **Lock an interpolation's duration at the moment you commit to it**, not re-derived from
  current state every frame — otherwise the animation visibly snaps whenever the driving
  state changes mid-glide.

### Host-embedded scripting runtimes, vendored DLLs, and ABI mismatch

- **A scripting host may load your script as an in-memory string, not a file.** If script-path
  introspection (e.g. `debug.getinfo`) returns a placeholder instead of a real path, any
  relative path built from it silently resolves against the host's own working directory
  instead of your script's directory. Fix: derive the actual working directory a different
  way (e.g. shelling out to the OS) rather than trusting the scripting host's path APIs.
- **A vendored native dependency (e.g. a `.dll`) may need its own dependency pre-loaded by
  full path.** Standard library search order can exclude the loading DLL's own directory —
  placing a same-named dependency next to the DLL that needs it is not sufficient; it may
  need to be explicitly loaded by full path first, after which the OS reuses the already-loaded
  module.
- **A statically-embedded scripting runtime inside a host binary is a higher-risk target for
  a vendored native module than a separately-hosted runtime.** Loading a foreign build of the
  same interpreter can risk a low-level state-object ABI mismatch that corrupts memory rather
  than failing cleanly, instead of just failing to load. Treat this as a real risk requiring
  a staged probe (see Diagnostic methodology above) rather than a "if it loads, it's fine"
  assumption — and re-test at real sustained load even after a light round-trip test passes.
- **The full diagnostic sequence that isolated a receive-side corruption bug** (useful as a
  template for a similar "data looks wrong on one side of a socket" problem):
  1. Log the intended vs. actual value on the write/apply side — rule out the consumer.
  2. Log send-side success/failure/timeout counters — rule out the sender's own socket calls.
  3. Log raw receive-line counts *before* any parsing — confirms whether volume or content is
     the problem.
  4. Hex-dump (not plain-text-log) the actual failing bytes — plain-text logging can itself
     be lossy on unprintable bytes and needs ruling out first.
  5. Test the leading mitigation hypotheses (e.g. message size, send frequency) individually
     — a hypothesis that produces statistically identical failure rates when varied is ruled
     out, not confirmed by "it seems better."
  6. Look for a time-based rather than content-based pattern (e.g. failure rate changing with
     session duration, not message content) — consistent with a timing/reentrancy bug in the
     dependency rather than a data-format bug.
- **A dependency version bump can break a coexisting, unrelated component via a real ABI
  break**, surfacing as a misleading downstream error message (e.g. an unrelated compatibility
  screen) rather than a clear load failure. A changelog/commit-message keyword scan is not
  sufficient to catch this — when rolling back, back up *everything* the bumped component
  touched, not just the component itself (a partial rollback can leave one dependency on the
  newer version by oversight).

### Cross-adapter issues that were fixed in the core, not the adapter

Found while building an adapter, but the fix belonged in `internal/core` — listed here so the
next adapter author doesn't re-diagnose them as adapter bugs:

- An adapter sending updates at its natural uncapped rate exceeded the relay's rate limit and
  got disconnected — fixed with a core-side minimum send interval, not adapter-side throttling.
- A core process's own startup handshake wasn't recorded the same way a probe's handshake was,
  causing a spurious "already connected as a different game" rejection — fixed with a core-side
  regression test for the startup path specifically.
- An adapter has no way to detect its own bridge/relay connection dying from a single
  request/response probe, because the core only pushes remote state as a side effect of
  processing a new local update — a "send once, wait" test can look broken even when the
  socket is fine.

## Cross-game comparison

Recurring adapter tasks, and how differently each engine/game has answered them so far:

| Task | Pokemon Emerald (GBA, BizHawk/Lua) | Pseudoregalia (UE5, UE4SS/Lua) | TEVI (Unity/Mono) |
| --- | --- | --- | --- |
| Represent the remote player visually | 2D overlay sprite drawn every frame (`gui.*`) | Spawned/duplicated 3D actor | World-space `GameObject` with `SpriteRenderer` |
| Drive an animation | N/A (2D overlay) | No direct equivalent of "play this named clip on a clone" — open problem | Send the real clip name (`GetAnimationTrueName()`) and let the engine's own `Animator` play it |
| Avoid drawing over menus/UI | Explicit gate on the overworld callback state (`gui.drawImage` is a raw overlay) | Not yet needed the same way | Not needed — a world-space object under the game's own camera naturally renders under UI layers |
| Survive area/level/scene transitions | Re-read relocatable pointers every frame; debounce reads for one frame around a detected map change | Re-acquire pawn/camera references after transition; treat cached "last known good" state as invalidated, not fatal | Recreate the ghost lazily after scene unload rather than trying to preserve it across the transition |
| Version/build stability | ROM is fixed once verified against a byte-identical build — no drift risk after that | Build-specific: reflection availability and rendering-on-spawn behavior are tied to the exact installed engine/mod-loader build | Steam can auto-update the game; also blocks two simultaneous instances (confirmed by testing, not assumed) |
