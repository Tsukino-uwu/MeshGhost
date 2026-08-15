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
- **Read an effect back in the SAME tick before theorising about the call.** When a call on a
  ghost looks like it did nothing, the first probe is an immediate readback right after it —
  not a hypothesis about the call. Source: the 2026-08-15 ledge-climb-up saga, where "our
  Montage_Stop doesn't work" survived two rounds of reasoning and one wrong fix, and a same-tick
  readback killed it instantly (it read `none` every time — the ghost was re-starting the montage
  by itself ~0.4s later). Generalises the `manageRecallIdleFX` entry's own stated weakness:
  an uninstrumented call can't distinguish "never ran" from "ran and was undone".
- **The game already knows — find what it calls the thing instead of reconstructing it.** Every
  hard visual-sync problem in Phase 7 ended the same way, and every failed attempt was an attempt to
  rebuild something the game was already tracking:
  - *The throw animation.* Guessing which synced state meant "throwing" was hopeless —
    `moveState`/`actionState`/`animJumpType` are bit-identical through a real throw. `Montage_Play`
    on the ghost's own anim instance fixed it, and generalised for free to every montage in the game.
  - *The bubble flash.* Two guessed tick windows failed identically because the duration was never
    ours to know. `StartBubbleJumpFlash` + the game's own `hasBubbleChargedJump` flag matched the
    real player to within 0.01s across three cases, including one that could only ever have caught
    us being wrong.
  - *The slide trail.* Three `actionState` heuristics failed; what worked was keying on a physical
    fact of the move (the capsule shrinking 65 → 22) rather than an enum whose meanings overlap.
  **The move that keeps paying: dump the class's own function/property names, filtered by a needle
  list, and read what they are called.** That single step produced `Montage_Play` and then
  `StartBubbleJumpFlash`/`changeBubbleChargedJump` — both named for exactly the effect and exactly
  the state, after hours of inference had failed. Do it EARLY, not after the guesses run out.
  Two specific tells that you are reconstructing instead of asking:
  1. **You are about to tune a duration constant.** How long an effect lasts is the game's business.
     A `change<X>(hasX: bool)` function name is a near-certain sign that a readable `X` flag exists —
     search the properties for it rather than timing the effect with a stopwatch.
  2. **You are on your second guess with the same symptom.** That is the existing "two guessed fixes
     failing identically" rule, and "ask the class what its API is called" is usually the isolation
     step it should send you to.
  One caveat, learned the hard way twice in one day: **a name found this way still needs its
  real-world meaning confirmed by a human watching** — see the entry directly below.
- **A state signature can be perfectly solid and still be attached to the wrong event — only a
  human watching can tell you which.** A bubble-only coverage capture found `moveState==7 &&
  movementMode==5` holding for 2002 ticks with `afterImagesToSpawn` at 0 throughout: clean,
  repeatable across every repetition, unambiguous. It was labelled "the post-jump boost-available
  window" and shipped as a trail trigger on that basis. It is actually *inside the bubble*. The log
  could not have caught the error — a held state looks identical either way, and which real-world
  moment it corresponds to exists only on screen. The user's three-way report (in-bubble trailed /
  post-jump didn't / boost did) separated them in one sentence.
  **So: naming which real moment a signature belongs to is a visual claim, not a log claim, and it
  needs the same human gate as any other visual claim** (see `verified.md`'s own gating rule). State
  the mapping as an assumption when you write it, and have the watcher confirm the *label*, not just
  that the effect appeared. Corollary that saved the follow-up fix: when a window is bounded by an
  event you can't see (a trail "running out"), don't infer its length from the state's duration —
  the state outlived the effect here, and the ghost kept trailing long after the real player stopped.
- **A soft/"nicer" parameter value is a change, not a freebie.** The same session shipped a
  montage stop with a 0.1s blend purely because a gentle blend seemed more appropriate than the
  existing hard 0.0f, and it was inert on this build — the bug it caused was then chased as if it
  were pre-existing. If an existing call in the file uses a specific value that works, match it,
  and change it only with a measurement.
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
- **A doc string embedded in a binary is not proof a function is callable at runtime.**
  `BizHawk.Client.Common.dll`'s embedded doc strings mention `memory.hash_region` and read like
  any other confirmed API entry in this project's records — but a real session found it reports
  as `nil` (not a function) at runtime despite the doc string being present in the DLL. Guard
  every such call with `type(memory.x) == "function"` and have a fallback path, the way
  `vram_probe.lua` does, rather than trusting a doc string the same way an address citation is
  trusted. Source: Stage 1 of the VRAM/sprite injection investigation (`ideas.md`), first real
  run, 2026-08-14 — see `agent_docs/environment.md`'s Memory Lua API entry for the corrected
  record.
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
- **Measuring the gap between two discrete events is not the same as measuring one event's real
  duration.** A "gap between commits" naturally includes any idle time sitting in between them,
  and a plausibility range alone (min/max frame count) can't tell "one genuinely slow event"
  apart from "idle time plus one normal-speed event" if both land in the same numeric range —
  ordinary tap-then-pause human input reliably produces exactly this ambiguity. Source: the
  Emerald sub-tile smoothing saga below — a live per-frame raw-position trace was needed to
  prove real per-tile timing had *zero* variance, which is what finally justified dropping
  dynamic measurement for a plain fixed constant instead of chasing a self-correction that
  wasn't actually correcting anything.
- **When a rendered difference between two known states can't be traced to any field you've
  thought to check by name, dump every reflected property's real VALUE at the moment that
  matters, for both states, and diff the two dumps — instead of continuing to guess field names
  one at a time.** A schema-only dump (property names/types, no values — this project's
  `dump_object_reflection`) only tells you a field exists; it can't tell you which of dozens of
  candidates actually differs between two states. Extending the same reflection loop into a
  generic value-printer (per-type: bool/int/float/double/name/object-reference, one line per
  property) and running it against two save files chosen to be maximally different (a genuine
  0%-completion save vs. a 100%-completion save, loaded within the same session so the ghost's
  spawn snapshot captures each cleanly) turned a guessing game into an exhaustive search: out of
  230 properties on an AnimBP instance, exactly one differed between an armed and unarmed spawn,
  and a full 250-property sub-component dump proved a longtime prime suspect (`WeaponMesh`)
  never differed at all — ruling it out completely, not just the handful of properties anyone
  had thought to check by name. Source: the Phase 7 Dream Breaker weapon-visibility
  investigation, 2026-08-15 (`agent_docs/verified.md`'s "cross-save" entries,
  `adapters/pseudoregalia/PLAYER_FIELDS.md`, `adapters/pseudoregalia/README.md`'s build-log step
  20). **Generalizes to**: any adapter/engine with runtime property reflection (UE4SS, other
  Lua/C++ modding APIs) — when two save files, game modes, or player states produce a visibly
  different result and the responsible field isn't obvious, this diff-driven search finds it
  without prior knowledge of the field's name, and normalizing out per-instance object
  IDs/level-path noise before diffing keeps the result from drowning in expected, irrelevant
  differences.

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

- **Writing a property directly before calling a function that also sets that property can
  silently defeat the function.** Symptom: two independently-chosen candidate functions
  (`updateWeaponEquip` on the AnimBP, `changeEquippedWeapon` on the pawn) both confirmed firing
  correctly (live signature-dumped, confirmed called via trace log) with zero visible effect —
  the exact "two guessed fixes failing identically" signal above, but the fixes here weren't
  wrong, the *call order* was. The ghost-sync code wrote the raw property
  (`weaponEquipped?`/`animEquippedWeapon`) directly onto the object every tick, unconditionally,
  *before* the edge-gated function calls that were supposed to be the real trigger — so by the
  time either function ran on an actual transition, the property already held the new value on
  that same tick. If a Blueprint graph's own custom event does the ordinary "only play the
  transition if the value actually changed" comparison against the object's current property (a
  common pattern for a named "update"/"change" event), it will always see old==new and do
  nothing — with no error, no warning, and a trace log that shows the call firing "successfully."
  **Fix**: call the function *first*, while the property still holds the old value, and only
  write the raw property afterward (kept as a safety-net sync, not removed). **Generalizes to**:
  whenever a sync/mirror path both (a) writes a raw property directly and (b) also calls a
  function that's supposed to react to that property changing, the property write must happen
  after the function call, not before, or the function can never observe a real transition.
  Diagnosed via the value-diff technique above, not guessed — comparing `animBPref`'s reflected
  values across a genuine 0%/100%-completion save pair found `animEquippedWeapon` as the one
  real differing field, which is what made the write-order bug obvious once looked for directly
  in the code. Source: the Phase 7 Dream Breaker weapon-visibility fix, 2026-08-15
  (`agent_docs/verified.md`'s "animBPref cross-save diff" entry, confirmed live).

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
- **TEVI (Unity)**: the same class again, but in *render state* terms instead of a memory
  address or object reference. `Instantiate()`-cloning a live character's visual hierarchy to
  make a remote ghost (`CreateRealGhostVisual`, `adapters/tevi/MeshGhostTevi/Plugin.cs`) deep-
  copies every component's *current* field values, including whatever transient state the
  source is in at that exact instant — not just static geometry. **Symptom, found live
  2026-08-14**: a peer's ghost, recreated (via cross-area filtering's despawn/respawn cycle,
  see the 2026-08-13 ADR in `architecture.md`) right as the traveling player's own zone-load
  finished, went permanently invisible — alive, active, correctly positioned, never destroyed
  again (ruled out via dedicated redraw/despawn diagnostic logging added specifically to chase
  this), just invisible. **Root cause, confirmed via logging the inherited state before
  overwriting it**: `basesprite.enabled` was `false` at clone time (some in-engine hide/fade
  tied to the zone-load transition), and the clone has no `CharacterBase` gameplay logic of its
  own to ever flip it back — a bad state captured mid-transition is permanent for a detached
  clone, exactly like a Lua reference going stale mid-warp. **Fix, and a real mis-fix caught
  first**: the first attempt forced *every* sprite renderer to `enabled = true` **and**
  `color = Color.white` — this "fixed" the invisibility but immediately introduced a visible
  regression, a solid white glow replacing the character's outline effect (`outlinesprite` is
  deliberately not white; overwriting its color broke it). Correct fix: log what was actually
  inherited *before* resetting anything — the log showed `color` was already a correct opaque
  `(1,1,1,1)`, only `enabled` was wrong — so only reset the field actually confirmed broken,
  not everything that plausibly could be.
- **A guessed delay was considered and rejected for the TEVI case above**, same reasoning as
  every other guessed-constant mistake in this file's history (the console-spam epsilon, TEVI's
  own position-change epsilon): it would only narrow the race window against a transition
  effect of unknown/variable duration, not close it, and would add latency to every recreate
  even when nothing was mid-transition. **Generalizes further**: when a symptom looks like "the
  right value eventually settles, so just wait for it," check first whether the actual fix is
  cheaper and more certain — forcing a known-good value directly, rather than racing a timer
  against an effect whose duration was never measured.

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
- **A network-side delay/buffer (e.g. interpolation smoothing) can silently mask a local timing
  bug** by absorbing small glitches into a larger, already-fuzzy window. Emerald's sub-tile
  glide bug (see below) had likely been present since it was first written, but only became
  visible once local loopback testing ran with the network buffer removed — treat "looks fine
  with the buffer on" as untested, not confirmed, for anything the buffer could plausibly be
  hiding.

### Reconstructing continuous motion from discrete, throttled position samples (Emerald sub-tile glide saga, 2026-08-14)

A whole-tile integer position (changes once per completed step, not continuously) needs local
smoothing to look continuous when re-rendered. This project's Emerald adapter went through
three real, disproven attempts before landing on the right one — kept here so none of the
three gets re-tried blind:

- **Attempt 1 (original, 2026-08-11): measure the real gap between consecutive commits and use
  it as the next glide's duration**, "self-correcting" to whatever the real per-tile cadence
  is. Sounds robust, and initially was — until interp=0 loopback testing exposed that ordinary
  tap-then-pause play (not holding a direction key continuously) produces gaps that are mostly
  idle time plus one real step, indistinguishable from a genuinely slow step by a plausibility
  range alone. Result: the ghost visibly crawled through what should have been "stand still,
  then snap."
- **Attempt 2: gate the measured gap on whether the current anim matches the anim of the step
  that produced it**, to stop reusing a stale duration across a pace change. Also wrong, and
  for a subtly different reason: the `anim` field can already show the *next* pace before the
  *current* (still-old-paced) step's own commit event lands, so gating on it forced some
  perfectly valid measurements to be discarded in favor of the wrong constant — verified by a
  live trace showing a real, accurate 16-frame walking-paced gap forcibly overridden to 8 (the
  running constant) because `anim` had already flipped, animating that one step in half its
  real duration.
- **Attempt 3 (adopted): drop measurement and gating entirely, use a plain fixed
  per-anim constant.** Justified only after live data proved it, not by preference: a
  per-frame raw-position trace showed every genuinely continuous step measuring *exactly* 8 or
  16 frames across dozens of real steps, zero variance — the self-correction attempt 1 existed
  for was never actually correcting anything real.
- **A follow-up dead end during the same investigation**: suspecting a real hardware sprite
  read (`playerScreenPos()`) was stale/wrong because it appeared frozen across an entire real
  walked tile. A per-component trace (logging `sx`/`coordOffsetX` etc. separately instead of
  their sum) proved it was correct all along — pokeemerald's camera keeps the player's own
  sprite screen-locked and scrolls the world instead, so a frozen *combined* value is expected,
  correct behavior, not a bug. **Generalizes to**: a value that never changes is not
  automatically a stale-read bug — confirm by decomposing it into parts that *should* vary
  independently before concluding the read itself is wrong.

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
- **A plain, undiscarded `sock:receive()`/`sock:send()` call on a non-blocking socket silently
  drops data at NDJSON framing boundaries — found independently in two languages during the
  2026-08 review sweep.** `receive()` with `settimeout(0)` returns `nil, "timeout", partial`
  when a line straddles the read boundary; code that only checks the first two returns discards
  `partial` outright, and the next successful read starts mid-line. `send()` on the same kind of
  socket can accept only part of a buffer, silently truncating the newline-terminated line if the
  return isn't checked against the full length. Found in `adapters/pokemon/emerald/
  meshghost_emerald.lua`'s `drainBridge`/`sendLine` (fixed: resume `receive("*l", partial)`,
  drop-and-reconnect on a partial send) and, as a partial-send-only variant, in
  `BridgeClient::send_line` (`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/BridgeClient.cpp`,
  fixed the same review sweep). The exact same discard-the-partial `sock:receive()` pattern (no
  prefix argument) is also present, unfixed, in the abandoned Pseudoregalia Lua probe scripts
  (`adapters/pseudoregalia/probe_ghost/Scripts/main.lua:499`,
  `adapters/pseudoregalia/probe_socket/Scripts/stage3_roundtrip.lua:110`) — a plausible
  *contributing* cause for the 7.5 "receive-side corruption" symptom (see the ABI-mismatch entry
  above), though the diagnostic ladder that investigation ran (failure rate independent of
  message size/frequency, correlated with session duration) points at a genuinely separate
  timing/ABI issue as the dominant cause; this pattern was never live-tested in isolation on that
  now-superseded Lua path, so treat it as an additional real bug found by code inspection, not a
  replacement for that diagnosis. **Generalizes to**: any non-blocking socket loop across any
  language — check every return value of `send`/`receive` against the full requested length, and
  never assume a documented "timeout" or "partial" result means "nothing happened."

### Vendored RE-UE4SS SDK marshals `FRotator` as `float` regardless of engine version (UE5 games)

- **Symptom**: writing a ghost's rotation via `K2_SetActorLocationAndRotation` or
  `K2_SetActorRotation` had position stick correctly but rotation read back as an implausible
  denormal (`~5.5e-315`) via every read method tried (`K2_GetActorRotation()`, direct
  `RelativeRotation` property reads). A forced yaw-cycle test (0/90/180/270 on a timer) produced
  zero visible change, which looked like proof the write mechanism wasn't reaching the renderer
  at all.
  - **Probe**: read the vendored SDK's actual marshaling code
    (`RE-UE4SS/deps/first/Unreal/src/AActor.cpp` and `include/Unreal/BPMacros.hpp`) rather than
    continuing to guess at the ghost/engine side. `UE_COPY_VECTOR` (used for `FVector`
    parameters) branches on `Version::IsBelow(5, 0)` to marshal `float` vs `double`; every
    `FRotator`-taking native function hardcodes `UE_COPY_STRUCT_INNER_PROPERTY(..., float, ...)`
    with no equivalent version branch. Confirmed arithmetically, not just plausibly: `90.0f`'s
    bit pattern placed in the low 4 bytes of a zeroed 8-byte double slot is exactly
    `5.529052754e-315` — matching the logged garbage to three significant figures.
  - **Cause**: on a UE 5.0+ game, the engine's real `FRotator` fields are `double`. The SDK
    writes only the low 4 bytes of each 8-byte reflected slot, leaving the upper 4 bytes
    whatever the zeroed buffer already had — the engine then reads a near-zero denormal instead
    of the intended value. This is a bug in the third-party SDK, not in adapter code, and not in
    the game.
  - **Fix**: a local, version-aware marshaling helper in the adapter's own source
    (`call_set_actor_location_and_rotation`, `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/
    Plugin.cpp`) that mirrors `UE_COPY_VECTOR`'s version branch for the rotation fields too,
    using real `FProperty::GetOffset_Internal()` offsets rather than a guessed struct layout —
    not a patch to the SDK itself. See the reasoning below for why.
  - **Why not patch the submodule**: `RE-UE4SS` is a git submodule: the parent repo tracks only
    its pinned commit, never its file contents. A patch to `BPMacros.hpp`/`AActor.cpp` could not
    be committed to this repo at all — it would live as uncommitted dirt in a nested repo,
    invisible to anyone cloning fresh, invisible to CI, and silently wiped by any
    `git submodule update`. This SDK is source compiled into the mod's own DLL, not the UE4SS
    runtime the game loads, so patching it was never a risk to the installed UE4SS build or to a
    coexisting mod — the problem is purely that a submodule edit isn't committable.
  - **Generalizes to**: any UE5 (5.0+) game targeted via this SDK. The local helper covers only
    the one function this adapter calls (`K2_SetActorLocationAndRotation`) — `K2_SetActorRotation`
    and presumably other native `FRotator`-taking functions in the same SDK carry the identical
    bug. Before calling any new SDK function that takes or returns an `FRotator` on a UE5 target,
    check whether its marshaling macro is version-aware the way `UE_COPY_VECTOR` is — if not,
    route it through an equivalent local helper rather than assuming it works because the
    function compiles and "succeeds." A secondary, unrelated bug found in the same investigation:
    `FRotator::Quaternion()` (`include/Unreal/Rotator.hpp:158`) is missing a negation on its `Y`
    term versus UE's real formula — harmless when pitch and roll are both zero (true for this
    game's pawn), but would corrupt a spawn-time rotation for a pawn with non-zero pitch/roll.

### UFunction hooks work on native functions but CRASH on Blueprint functions (RE-UE4SS)

- **Symptom**: `UFunction::RegisterPostHook` on two Blueprint functions of the Pseudoregalia player
  pawn (`Spawn After Image`, `spawnNumAfterimages`) registered successfully — real callback IDs
  returned and logged — then fired **zero times** across ~18s of real play that definitely
  triggered those effects on screen, and the game died with `Fatal error!` and nothing written to
  the log (steady per-tick output right up to the last line, no error/warning/stack trace).
- **Cause**: RE-UE4SS's `RegisterPre/PostHook` installs itself by swapping the `UFunction`'s own
  function pointer (`SetFuncPtr`). For a **native** (`FUNC_Native`) function that pointer is a real
  per-function C++ routine, so swapping it is well-defined — this is why the long-working
  `SetViewTargetWithBlend` camera hook in the same file is fine. For a **Blueprint** function the
  pointer is the shared `ProcessInternal` bytecode entry point, not a per-function routine;
  swapping it neither intercepts the call nor leaves execution intact.
- **Fix**: don't hook Blueprint functions on this build. The feature reverted to polling a property
  (`actionState`) each tick and edge-detecting it — less accurate (it can't distinguish a real
  slide from a quick turn-around that shares the same state value) but stable.
- **Generalizes to**: before reaching for a UFunction hook on any UE target, check whether the
  function is native or Blueprint (the reflection dump's `FUNC_Native` flag, or simply: is it a
  `/Script/Engine.*` engine function, or a `_C` Blueprint class member?). A hook that *registers
  successfully* is not evidence it works — this one returned valid IDs and still never fired. If
  the only available event source is a Blueprint function, prefer polling a property that the
  Blueprint itself sets over hooking the call.
- **Process note, transferable beyond UE**: this change also swapped a *confirmed-working*
  ghost-side apply path at the same time as changing the trigger — two variables at once, against
  the "one diagnostic at a time" rule at the top of this file — which regressed a working visual
  and briefly muddied the diagnosis of the crash. When replacing the *source* of an event, hold the
  *handling* of that event fixed.
- Full evidence: `agent_docs/verified.md`'s "Pseudoregalia trail-VFX UFunction hook" entry.

### Actor destroy unavailable on this build — move offscreen, let the level's own teardown reclaim it

- **Symptom**: `K2_DestroyActor()` on a spawned ghost actor silently no-ops on this Pseudoregalia
  build — no crash, no error, the actor call simply doesn't remove the object. Earlier attempts
  to destroy ghosts through other means caused world-leak crashes.
- **Design (not a bug fix, a permanent constraint)**: ghosts are never destroyed. On
  `despawn_remote`, `Plugin.cpp`'s `release_ghost` moves the ghost far offscreen via the
  already-proven `call_set_actor_location_and_rotation` path (see the `FRotator` marshaling
  pitfall above for why that specific call needed its own version-aware helper) instead of
  attempting any destroy/pool/reuse. The level's own teardown on the next area transition
  reclaims it, the same as every other actor in the level — so ghosts aren't leaked forever, the
  cost is purely cosmetic: a peer leaving/reconnecting *within a single area* leaves a frozen,
  offscreen (not visible) ghost standing until the next transition, rather than a truly clean
  removal.
- **Generalizes to**: on any engine/build where a runtime destroy call is confirmed unreliable
  (no-op, or worse, a crash), prefer "move it somewhere inert and let a mechanism the engine
  already trusts (a level transition, an object pool the engine itself manages) do the real
  cleanup" over building your own destroy/lifetime-management layer on top of an already-shaky
  primitive.

### Running two instances of the same emulator/game silently collide on a shared default port

- **Symptom**: a real two-peer Emerald test (2026-08-14, the first ever attempted for this
  adapter) showed both BizHawk instances' `MeshGhost TRACE` diagnostic stuck at
  `knownRemotes=0` forever, even with a stable relay connection, matching area_ids, and no
  connection churn. A long diagnostic session — checking cross-area filtering, adding
  throttled trace logging in both the Lua adapter and `internal/core` at every hop
  (send → relay forward → roster → receive → store) — proved the entire Go pipeline was
  correct: one core (`p1`) really was sending state, the relay really was forwarding it, and
  the *other* core (`p2`) really was receiving and storing it. The bug wasn't in any of that.
  - **Actual cause**: the second BizHawk instance was launched by double-clicking `EmuHawk.exe`
    directly, rather than through a wrapper that sets `MESHGHOST_BRIDGE_PORT=7779` first. The
    Lua adapter (`meshghost_emerald.lua:132`) reads that env var and silently falls back to 7778
    (the same default `meshghost.exe -bridge` uses) if it's unset — so *both* BizHawk instances
    connected to the *same* core process's bridge. The second core (the real, correctly-running
    peer on port 7779) sat there with no adapter ever talking to it, so it had nothing of its
    own to forward — not a bug, just nobody driving it.
  - **Why this was hard to catch**: nothing errors. Both BizHawk windows show a normal
    "connected to bridge" line; the port number is only visible if you read it in the console
    text carefully (`Connecting to bridge at 127.0.0.1:7778 ...` on *both* windows), and it's
    easy to assume — as happened here — that a launcher script or convention automatically
    handles per-instance port assignment when actually nothing does unless something sets the
    env var for that specific process before it starts.
  - **Fix (procedural, not a code fix)**: a per-machine, gitignored `.local.bat` launcher for
    each instance that sets `MESHGHOST_BRIDGE_PORT` before launching `EmuHawk.exe`, so this
    can't be silently skipped by launching the executable directly. See
    `dev-scripts/README.md`.
  - **Generalizes to**: any two-instance local multiplayer test where the adapter/game process
    picks its own listen/connect port from an environment variable with a same-for-everyone
    default. Don't assume a second manually-launched instance picked up a distinguishing
    setting just because a first instance worked — verify the actual port/id each instance
    logs on connect before spending time on protocol-level diagnosis. If a whole pipeline
    trace (send confirmed, forward confirmed, receive confirmed) comes back clean but the
    end-to-end symptom persists, seriously consider that the two "peers" are not actually
    talking to two distinct instances of anything before adding more diagnostics to the
    pipeline that already proved itself correct.

### Personal paths reaching a public repo, and a leak-check that silently passes (2026-08-15)

Backing detail for `CLAUDE.md`'s public-repo rule. Two live cases, and they failed differently:

- **2026-08-11, code**: a Phase 2 script had a hardcoded personal path that only ever worked on
  the machine it was written on — a portability bug, not just a style nit.
- **2026-08-15, prose**: four `Recorded plan: <absolute path>` citations had accreted across
  `phases/phase7.md` and `verified.md`. The rule already covered these; what failed was the
  *check it cues*. Its worked example is script-shaped ("would this run on another machine?"),
  and against a design doc that question returns a false pass — a doc doesn't run anywhere,
  while the leak is a privacy problem rather than a portability one. All four were pasted
  verbatim from tool output rather than typed, which is when authoring-time judgement doesn't
  fire at all. Hence the rule now names prose and pasted output explicitly.
- **The check itself had a false-pass bug**, found while writing it down: `git grep` with a
  backslash pattern (`'C:\\Users'`, `"C:\\\\Users"`, any regex form tried) matches **nothing**
  on Windows paths and exits clean. An earlier scan looked like it verified the tree, but was
  entirely carried by an unrelated username in the same alternation; the path half never
  matched anything. Only `-F` (fixed string) works: `git grep -inIF -e 'C:\Users' -e '/home/'`.
  Verified in both directions — against a deliberately planted leak (must find it) and against
  the clean tree (must find nothing). **Generalizes**: a hygiene check that can only ever print
  "nothing found" is indistinguishable from a broken one. Plant a positive before trusting it.
  Corollary found the same way: don't put a literal example of the banned pattern in the rule
  text, or the rule trips its own check and trains you to ignore the output.

### Two `git.exe` installs on one machine disagree about whether the tree is dirty (2026-08-15)

- **Symptom**: `git status --short` run from PowerShell reported 53 modified files and
  `git diff --stat` showed 15,039 insertions / 15,039 deletions — every line of every file
  replaced. Run from the Bash tool, the same tree was clean.
- **Actual cause**: the two shells resolve different git binaries with different configs.
  PowerShell's `PATH` hits `c:\devkitPro\msys2\usr\bin\git.exe` (devkitPro's bundled MSYS2
  git) with `core.autocrlf` **unset**; the Bash tool gets Git for Windows
  (`C:\Program Files\Git`) with `core.autocrlf=true` in its system config. The worktree is
  CRLF and the blobs are LF (`git ls-files --eol` → `i/lf w/crlf`), so the autocrlf-less git
  sees a whole-file difference in everything while the other normalizes it away.
- **Why this is dangerous**: the obvious "fix" is a `git checkout --`/`git restore` to wipe
  the churn. That would rewrite 52 files for nothing, and on a tree with genuine uncommitted
  work it would destroy it — all in response to a diff that doesn't exist. `git diff
  --ignore-cr-at-eol --stat` returning empty is the cheap tell that a diff is line-ending
  artifact rather than content.
- **Fix**: none applied — nothing is actually wrong with the tree. Before acting on a
  surprisingly large diff, confirm which git produced it (`(Get-Command git).Source` /
  `which git`) and check `git config --show-origin --get core.autocrlf` for that binary.
- **Generalizes to**: the same "wrong install on `PATH`" trap `CLAUDE.md` already records for
  `cmake`, and from the same devkitPro MSYS2 install. Treat a tool's *config-dependent*
  output (not just its success/failure) as suspect until the binary is identified.

### A raw actor pointer added to a tracking struct must also be dropped in the pre-teardown hook (2026-08-16)

- **Symptom**: `EXCEPTION_ACCESS_VIOLATION` returning to the main menu, reported live. Stack:
  `game_thread_tick` → `handle_bridge_line` → `release_ghost` →
  `call_set_actor_location_and_rotation`. Use-after-free on the thrown-weapon prop.
- **Diagnosis**: the level transition destroyed the prop; nothing cleared MeshGhost's raw pointer to
  it; a `despawn_remote` arriving afterwards then tried to *move* freed memory. Two contributing
  mistakes: (1) that path still *parked* the prop, left over from before props became per-throw
  destroyed, so it moved an actor the code no longer keeps alive; (2) `release_all_ghosts` — which
  runs in the **LoadMap PRE hook**, the one moment guaranteed to be before the engine destroys
  actors — nulled the *ghost* pointer but had never been extended to the prop added later.
- **A liveness check would NOT have prevented this**, which is the part worth internalising:
  `IsUnreachable()` is only meaningful on an object that is still *allocated*. Against genuinely
  freed memory it is another read of a dangling pointer, not a guard. Dropping the reference while
  it is still valid is the only real defence.
- **Fix**: clear every actor-shaped field for every remote at the top of `release_all_ghosts`,
  before its existing "no ghost, skip" continue, and destroy (never move) the prop elsewhere. That
  function deliberately only drops references and calls into no actor — calling into actors during a
  LoadMap hook is itself something this file has crashed on before.
- **Generalizes to**: the moment you add a *second* engine object to a per-peer tracking struct, it
  inherits every lifetime rule the first one has, and those rules usually live somewhere
  non-obvious — a hook rather than the destructor. Grep for where the existing pointer is nulled and
  match it, rather than assuming the new field is like the old ones because it sits next to them.
  The single-object version of this code was correct for a year; adding a companion object silently
  broke it.

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
| Drive an animation | N/A (2D overlay) | Two layers: continuous poses mirror via state properties (`moveState`/`actionState`), one-shot animations via a **montage mirror** — send whatever `AnimMontage` the peer plays, call stock `Montage_Play` on the ghost's anim instance (2026-08-15, `verified.md`). The game's own `CustomPlayMontage` wrapper silently no-ops on a ghost | Send the real clip name (`GetAnimationTrueName()`) and let the engine's own `Animator` play it |
| Avoid drawing over menus/UI | Explicit gate on the overworld callback state (`gui.drawImage` is a raw overlay) | Not yet needed the same way | Not needed — a world-space object under the game's own camera naturally renders under UI layers |
| Survive area/level/scene transitions | Re-read relocatable pointers every frame; debounce reads for one frame around a detected map change | Re-acquire pawn/camera references after transition; treat cached "last known good" state as invalidated, not fatal | Recreate the ghost lazily after scene unload rather than trying to preserve it across the transition |
| Version/build stability | Real drift risk, not immune: a ROM patch (Archipelago's base recompile) relocates addresses relative to a byte-identical-verified vanilla build — found live for `gObjectEvents`/`gPlayerAvatar`, `CB2_Overworld`, and sprite/palette data, each a separate offset; each patch version needs its own live-detected offsets, see `verified.md`'s Archipelago-relocation entries | Build-specific: reflection availability and rendering-on-spawn behavior are tied to the exact installed engine/mod-loader build | Steam can auto-update the game; also blocks two simultaneous instances (confirmed by testing, not assumed) |
