# Pitfalls — method, and instruments that lie

<!-- line-cap: none -- incident record; its control is the index in ../pitfalls.md plus preflight's coverage check, not a line count. Why: agent_docs/claude-md-cap.md. -->

How to diagnose, and the ways an instrument reports something that is not true. This is the half
read *before* trouble rather than during it: the diagnostic methodology, the failure signatures, and
the two entries about confirming what you are actually looking at before you probe it.

**The index over every entry in every one of these files is [../pitfalls.md](../pitfalls.md).**
Add an entry here, add its one line there — `dev-scripts/preflight.ps1` fails if you do not.

## A symptom word can name more than one subsystem — confirm which before probing (2026-08-16)

**Symptom:** four live test cycles spent chasing the wrong subsystem, while every probe returned
true findings that looked like progress.

**What happened, 2026-08-16.** The user reported the Pseudoregalia camera acting wrong, and
clarified: *"it was focused on the player, but I couldn't move/control it."* That was read as
**movement** loss. Two probes and a fix followed, aimed at the ghost stealing possession from the
player pawn. The user's actual meaning was *"I can walk around, the camera won't rotate"* — a
different subsystem entirely.

**Why it survived several rounds.** The wrong reading produced *correct* findings. The ghost really
did auto-possess and steal the controller on every spawn, so each probe confirmed something real
and each fix changed something real. Nothing failed in a way that pointed back at the
misunderstanding. A probe built on a misread symptom can be right about the wrong thing, and that
reads exactly like being on the right track.

**What actually resolved it:** the user saying "I never lost movement". One sentence, after four
build-deploy-replay cycles.

**The rule:** when a report could reasonably mean two things — "move", "stuck", "frozen", "lost
control", "not responding" — ask which, and say what each would imply so the answer is one word.
The user confirmed this explicitly: *"its fine to ask if you are unsure."* A question costs a
sentence; a wrong reading costs a test cycle, and the person paying it is the one who has to
replay the save.

**The tell:** you are about to instrument a subsystem the reporter never named. Here the report
said "camera" three times and the probes all went to possession.

## Gating a handshake on its own result (deadlock, twice in one day) (2026-08-16)

**Symptom:** the Pseudoregalia adapter reconnected to the bridge every ~12 seconds forever, logging
`bridge connected on port 7778` and then `whatever is on port 7778 never answered our hello`, while
the core's own log showed the adapter hanging up on it (`forcibly closed by the remote host`). No
ghost ever appeared. Found live 2026-08-16.

**Cause:** the bridge gained a handshake — the core answers a `hello` with `bridge_ready` or
`reject`. The adapter grew an `is_ready()` state, and the existing tick code said
`bool now_connected = bridge->is_ready();`. Two things were already inside `if (now_connected)`:

1. **sending the hello** — so the message that *starts* the handshake waited on the handshake's
   result. Caught by reading the code before shipping.
2. **`poll_lines()`** — so the adapter would not *read the socket* until it was ready, but
   readiness arrives over that socket. Not caught, and it is what produced the 12s loop: connect,
   send hello, never read the answer, hit the 1.5s answer timeout, blacklist the port for 10s,
   repeat.

**Fix:** both belong on `is_connected()`, not `is_ready()`. Only *game* traffic — sending
`local_state`, processing ghost messages — waits for readiness.

**The transferable rule:** when adding a handshake to an existing loop, every step that *produces*
the answer must be gated on the transport existing, never on the answer having arrived. Search for
the old "are we connected" boolean and check each thing under it: some of those are handshake
machinery and must move up, and the ones that don't move look completely fine until they hang.

**Why it took a live run to find:** the Go side was fully tested and correct — `core` and
`internal/e2e` both proved the core answers a hello, and an e2e test walked real binaries. None of
that could catch it, because the bug was the adapter never listening. This is the exact split
CLAUDE.md draws: the Go side is verifiable with tools, an adapter is only verifiable by watching.

## Diagnostic methodology

Rules that kept paying off across multiple sagas below. Each came from a specific incident —
know the incident, not just the rule, so you can judge when it applies.

- **One diagnostic at a time.** Add the next probe only after the previous one gave a clean,
  unambiguous answer. Stacking multiple changes at once (a fix + a new log line + a new
  guard) makes it impossible to tell which one mattered. Source: the Phase 7.5 LuaSocket
  investigation (`phase7.md`), which narrowed a "ghost teleports instead of following" bug
  through five sequential, single-variable probes before finding the real cause.
- **A count that is off by a constant is a reason to suspect the COUNTER, not to subtract the
  constant.** When something consistently produces one or two too many, adjusting the number by one
  or two makes the symptom go away while leaving the cause in place — and it breaks every case where
  the count was legitimately right, which is usually the majority. Near-miss, 2026-08-16: the ghost
  showed two blue afterimages against the real player's one, and the ghost ran 1-2 images ahead
  generally, so "just emit one fewer" looked reasonable and would have worked on the day. Logging the
  actor pointer showed the real cause in one line — a single image counted twice, once at spawn and
  once when the pool moved it to retire it (full entry below). A `-1` would have hidden that
  permanently, and the double-count would have gone on corrupting every other count it touched.
  **The tell is that the error is CONSTANT.** A miscount produces a fixed offset; a genuine
  difference in what the game did varies with what happened. So before tuning a number, ask what
  would have to be true for the count itself to be wrong, and log identity rather than quantity to
  find out. Same family as "a probe returning nothing is data" — believe the instrument only after
  checking what it actually measures.
- **Judge trail/afterimage density from a TOP-DOWN camera, not from behind the player.** User's own
  method, 2026-08-16, and it is what every "the trail looks right" confirmation in this file now
  rests on. The loopback ghost stands a couple of tiles to the side, so from the default
  behind-the-player angle the two trails overlap and blend — especially sliding left or right, where
  it becomes genuinely impossible to tell which afterimage belongs to whom. Swinging the camera to
  look down from above separates them into two distinct lines and makes per-image density directly
  countable by eye. **This matters because comparing the ghost's trail against the real player's is
  the primary check for the whole afterimage feature**, and the incident below ("The diagnostics were
  the bug") turned on a density difference that instrumentation reported as exact parity. If the
  human check is being done from an angle where the two blend, a real difference can be looked at
  and not seen. Applies to any paired local/ghost VFX comparison, not just the trail.
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
  **The move that keeps paying: dump the class's own function/property names and read what they are
  called.** **Dump them ALL — do not filter first.** An earlier version of this line recommended
  filtering by a needle list, and that advice cost most of a night on 2026-08-17: the filter is
  itself a guess about what the answer is called, and the one it hid was the answer (see "Dump
  everything" below). That single step produced `Montage_Play` and then
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
  and a full 250-property sub-component dump proved the day's prime suspect (`WeaponMesh`)
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

- **A diagnostic can break the thing it measures — and then every reading agrees with itself.**
  This is the hardest-won rule in the file; it cost the worst regression the project has had. Two
  probes were left enabled while judging the effect they instrumented: one *spawned* an afterimage
  onto the ghost every ~3s, and one enumerated every afterimage on the game thread ~50×/sec with a
  string conversion and a log line per object. The game spawns that effect as a countdown across
  ticks, so stalling the thread truncated real bursts. Four independent metrics then reported exact
  parity, because every image that survived *was* correct — only the destroyed ones were missing.
  So: **audit a probe's cost before trusting its output**, prefer edge-triggered logging over
  per-tick, never leave a probe that *spawns* the same kind of object enabled while judging that
  object, and re-run with probes off before believing a result. Treat numbers gathered while a
  corrupting probe was live as retroactively suspect, not as evidence. Full incident below.
- **"It measured correct" is not evidence** — the measurement counterpart of `CLAUDE.md`'s "it ran
  without errors is not evidence". A clean build proves nothing about behaviour; a clean *metric*
  proves nothing either if the instrument shares a blind spot with what it measures. The user's
  framing, 2026-08-16: *"I trust the code, but I don't trust the output."*
- **When instruments and a human observer disagree repeatedly, suspect the instruments.** Four
  rounds of counters said "identical" while the user kept reporting a visibly thinner trail. The
  user was right every time. A human reporting a difference your metrics deny is a reason to
  re-examine the metric, not to re-explain the metric.
- **A flag flip is not a revert.** A `constexpr bool` only reverts behaviour if it gates the
  *work*, not merely the decision the work feeds. The trail regression's A/B set a flag to false,
  concluded "this change is innocent", and was wrong: only the counter increment *inside* the
  expensive scan was gated, so the scan still ran. If a flag exists as an off-switch, verify it
  disables the cost too — or revert the commit instead.
- **When a regression appears, bisect real commits early.** This project had never needed it before
  2026-08-16, and inference had already burned hours by the time it was tried; the bisect then
  located the cause in three builds. Check out the last-known-good commit's source, build, confirm
  it is actually good, then halve. It is mechanical, needs no theory, and — unlike a flag flip —
  cannot be fooled by a partial revert. Everything committed makes this cheap and risk-free.

### Case study: the slide pose — how to track down something the game does for itself

**2026-08-17, ~15 live test cycles.** The hardest single fix in the Pseudoregalia adapter alongside
the ultra-hop blue trail, and worth reading as *method* rather than as a Pseudoregalia fact. The
mechanism itself is in `adapters/pseudoregalia/documentation.md`; the evidence trail is in
`verified.md`. This entry is only about how it was found, and about the four ways it was nearly not
found.

**The problem.** A ghost sank 43 units into the floor during a peer's slide, because the game poses
a sliding character by shrinking its capsule *and* moving its mesh, and a ghost never runs that
code. It had shipped with a `+43` render-Z compensation. Replacing that with the real mechanism is
what took the night.

#### 1. Dump everything. The filter is a guess too

Nine candidate levers were tried and every one applied cleanly and changed nothing visible. The
answer was a Blueprint Timeline update handler — `Timeline_1__UpdateFunc` — and it was invisible for
hours because the function dump had been **filtered** by a needle list (`slide|crouch|duck|mesh`).
That filter was a guess about what the answer would be called, made *before* knowing what the answer
was, and it excluded the answer by construction.

The unfiltered dump was **473 functions**: one screen of scrolling, read in under a minute. The
noise this repo had been carefully avoiding was cheaper than a single wasted test cycle, let alone
several.

**Rule: dump everything first; filter while reading, never before.** The same applies to property
dumps and to log greps. If you are choosing a needle before you have seen the haystack, you are
guessing, and you will not be told when the guess is wrong — the dump will simply look complete.

#### 2. "A alone does nothing" is not evidence that A is useless

The working configuration turned out to be **five mechanisms together**, every one of which tested
**negative in isolation**: mirror the capsule; drive the game's own pose curve; fire the crouch
input; fire the crouch events; set and clear the crouch state. Tested one at a time — correctly, by
the one-variable rule — each produced a clean negative.

Worse, two of them were switched off *as proven no-ops* and had to be restored: removing them broke
a working build, which is how the precondition structure was finally noticed.

**One-variable-at-a-time is necessary but not sufficient.** It is the right way to attribute an
effect, and it is blind to systems with preconditions, where the effect only exists for the union.
The practical addition: **after ~3 single-variable negatives, run the union of everything plausible
before concluding any of it is wrong.** If the union works, subtract from it — that direction is
safe, because you always have a working state to compare against.

#### 3. Measure the lag, not just the value

An on-change trace of the ghost's mesh offset showed the right values and hid the bug for several
cycles. Replacing it with a **per-tick window across each transition** — 14 consecutive ticks
logging the peer's state and the ghost's state side by side, read *after* the frame's writes —
showed in one capture that the pose applied **exactly once, at the first stand-up**, and never
again.

That single measurement collapsed three symptoms that had been treated as three separate bugs: the
first slide sank, later slides looked fine, and every stand-up snapped. All three were the one
latch. **When something looks intermittent or ordering-dependent, log a window, not an event** — an
on-change trace can only tell you what a value became, never when, and "when" was the whole answer.

#### 4. A write that gets undone means something is MAINTAINING that value

Writing the mesh offset landed every time and was reverted within about a tick. The instinct is to
write harder — re-assert per tick — and that produced a visible flicker as it lost the race some
frames.

The question that actually helps is **"what state does the thing overwriting me read?"** Here the
game maintains the mesh continuously from the character's crouch state, so the fix was to move that
state and let the maintenance do the work. Writing the *output* lost every time; writing the *input*
won immediately.

Related, and general: **outputs of a system look exactly like inputs from outside.** `bIsCrouched`,
`CapsuleHalfHeight` and `BaseEyeHeight` all change during a crouch, and none of them causes one.

#### 5. Once one direction works, check the other before looking elsewhere

Clearing the crouch state fixed the snap — which also *proved* the maintenance reads that state. The
remaining bug (the first slide still sinking) was the same bug from the other side: nothing was
*setting* the state on the way down. Writing it symmetrically finished the job in one build.

**When a fix works in one direction, the next thing to try is the mirror of it**, not a new theory.

#### 6. Two small traps found on the way

- **UE bitfield bools share a byte.** `bIsCrouched`, `bPressedJump`, `bClientUpdating`,
  `bClientWasFalling`, `bClientResimulateRootMotion(Sources)`, `bSimGravityDisabled` and
  `bProxyIsJumpForceApplied` are `uint32 :1` on `ACharacter`, and UE4SS's
  `GetValuePtrByPropertyNameInChain<bool>` hands back the containing **byte**. All seven read `true`
  when any one is set, and writing one stamps the byte and clears the rest. A property diff will
  show seven fields changing when one did.
- **Latch an event's magnitude when the event starts.** `K2_OnEndCrouch` was being called with
  `adjust=0.0`, because the delta was recomputed on stand-up when the peer had already returned to
  standing height. Engine convention is that both ends carry the same magnitude; compute it at the
  start and store it.

#### 7. What the user contributed, recorded as method

Two interventions moved this more than any single test, and both were corrections to *how* it was
being searched, not to what was being searched for:

- *"Have we tried a run with everything put together, if they need each other to work to begin
  with?"* — the working run had four mechanisms live; three were being tested.
- *"Just dump everything, we might have been looking in the wrong place all along."* — which
  produced the 473-function list and the answer inside it.

The shared shape: when a search stalls, suspect the *shape of the search* before adding another
candidate to it.

## A reference is not the thing — clearing a pointer removes nothing (2026-08-27)

**Symptom.** A ghost in Pseudoregalia appeared to share the player's health: damage, death and
healing all really happened while the health bar sat permanently full.

**Two fixes, both wrong in the same way, both confirmed to have RUN.**

1. The ghost's `As MV Game Instance Ref` was cleared, on the reasoning that the ghost shared the
   player's GameInstance. It changed nothing: a UE GameInstance is a singleton and **any actor
   reaches it through `GetGameInstance()`**, so a cached pointer was never the only route.
2. The ghost's `UI_HudRef` was cleared, on the reasoning that the ghost shared the HUD. It changed
   nothing either: **a widget's lifetime belongs to its parent, not its referrer.** The ghost's own
   health bar stayed parented to the viewport with nobody left pointing at it.

**Cause.** Both treated a *reference* as if it were the *thing*. Nulling a pointer does not destroy
an object, unparent a widget, or revoke access to a singleton. The fix was `RemoveFromParent` on the
widget — acting on the object, not on the handle.

**Why it was seductive twice.** Both changes were *verifiable*: the log said `cleared (was set)`
each time, so each looked like a fix that had definitely applied. **"The change applied" and "the
change did anything" are different claims**, and a log line only ever proves the first. This is the
same family as "it ran without errors is not evidence", one level up: the write really did land, and
still meant nothing.

**Reach for instead.** Ask what would have to be true for the object to stop mattering — is it
parented somewhere, registered somewhere, reachable by a global accessor? If a null-out is the whole
fix, ask what still holds the thing.

## An instrument that logs only its success path proves nothing (2026-08-27)

**Symptom.** A candidate fix (disabling a ghost's hitbox component) was shipped and tested. The
ghost still damaged the player, which looked like a clean refutation.

**It was not a refutation.** The block printed *nothing at all* — the property never resolved, and
the code only logged on success. The run could not distinguish **"disabled it and that was not the
cause"** from **"never found it"**, which need completely different next steps. An afternoon of
reasoning was nearly built on a result that did not exist.

**Cause.** `if (found && non_null) { do it; log it }` with no `else`. Silence read as "it worked and
didn't help" when it meant "it never ran".

**Fix.** Every branch logs, including "not there" and "resolved but null". This is
[effect-investigation.md](../effect-investigation.md) §3's `ours=` field and CLAUDE.md's "log the
thing that would prove you wrong", both of which already existed and were not applied.

**The general rule:** before believing a negative result, check that the instrument could have
produced a positive one. A quiet log is only evidence when silence was one of its designed outputs.

## An aggregate over a mixed series invents a defect that is not there (2026-08-25)

**Crystal, judging a ghost's motion against the player's.** A per-frame delta histogram of the
camera-free difference between ghost and player said the two disagreed on ~18% of moves, which was
written up as a "1-frame parity slip" and then FIXED -- a clock gate added to the spawned tier to
chase it. Printing the frames themselves killed both:

```
f=652  P=118  S=160     <- player and spawned ghost advance on the same frame
f=654  P=120  S=162        constant separation, no slip anywhere
```

**The series contained starts, stops and steady walking, and the aggregate averaged across all
three.** A constant-lag follower genuinely disagrees with its target at every start and every stop
-- that is what lag IS -- so those transitions produced the 18%, and steady walking, the thing
being judged, was already perfect. The gate was reverted.

**The rule: an aggregate is only meaningful over a segment where the thing being measured is in
ONE regime.** Segment first (walking / starting / stopping), or print the raw frames and look. A
histogram cannot tell you which regime its outliers came from, and it reads as authoritative
precisely because it is quantitative -- this is the same family as `probes.md`'s "a probe that
returns a boolean cannot be sanity-checked", one level up: a probe that returns a DISTRIBUTION
cannot be sanity-checked either, unless it also says what went into it.

**Corollary, from the same session:** the fix that follows a phantom defect can look like it
worked. The gate suppressed a duplicate step issue on the following frame, so it had a visible
effect and a plausible story -- and changed nothing about the symptom, because there was no
symptom. Before/after on the RAW evidence is what separated them.


## A deploy that reports success can deploy nothing — three ways, one loop (2026-08-28)

**Symptom.** TEVI's new hot-reload loop reported `deployed ... (hash match: True)` and the game
did not change. Three separate causes, found in one session (2026-08-28) while standing the loop
up, and **every one of them printed a success line**. That is the transferable part: the loop's
own output was never evidence that a reload happened.

**Cause 1 — a wrong-format symbol file reads as a missing one.** BepInEx's ScriptEngine loads a
plugin through Mono.Cecil WITH SYMBOLS. The .NET SDK emits a *portable* pdb by default, and
Cecil's `DefaultSymbolReaderProvider` cannot read one — it throws
`SymbolsNotFoundException: No symbol found for file: <the DLL>`. The message names the DLL, so it
reads as "you forgot the pdb" while the pdb is sitting right beside it. **Settled by looking at
the file's magic bytes**, not by trusting the build setting: portable starts `BSJB`, a Windows pdb
starts `Microsoft C/C++ MSF`. Fix: `<DebugType>full</DebugType>`.

**Cause 2 — `Copy-Item` preserves the source timestamp.** A file watcher fires on LastWrite.
A rebuild that produced a byte-identical DLL therefore copied an identical timestamp, changed
nothing observable, and fired no reload — while the script still said "deployed". **The first
reload test was a pass that reloaded nothing**, and it would have gone on passing. Fix: stamp the
destination's `LastWriteTime` after copying, so the deploy is the trigger regardless of whether
the bytes moved. **Generalises past PowerShell**: any copy that preserves metadata breaks any
watcher keyed on that metadata.

**Cause 3 — `Assembly.Location` is empty when an assembly is loaded from bytes.** ScriptEngine
uses `Assembly.Load(byte[])`, so anything resolving a path relative to "where am I" resolves to
nowhere. TEVI's `CoreLauncher` correctly reported that no `meshghost.exe` sat beside it and
declined to start one — correct behaviour, invisible consequence: the loop could not autostart.
Fix: an explicit short search list, assembly directory first (the shipping path), then an
environment override, then the loader's own `Paths.*`. **Not a scan** — each entry is a place the
file legitimately is.

**The lesson, which is the same one three times.** A dev loop is an instrument, and
`CLAUDE.md`'s rule that *a diagnostic can break the thing it measures* applies to it before it
applies to anything it measures. **Prove the loop moves the thing** — here, by counting
ScriptEngine's own `Loading plugins from` lines in the log and the adapter's own despawn lines,
not by reading the deploy script's output. A loop that silently stops reloading turns every later
result into a measurement of the previous build.

**Cross-reference:** `adapters/tevi/VERIFIED.md`, "TEVI hot-reload dev loop"; the loop itself is
`dev-scripts/tevi-hotreload.ps1`, whose header carries the two limits that remain.

## Failure signatures

Misleading symptoms that mean something other than their surface reading:

| Symptom | Actual meaning |
| --- | --- |
| UE4SS Lua: "Tried calling a member function but the UObject instance is nullptr" | Usually means the UFunction isn't reflected on this build, not that the object is actually null — confirm the object's validity separately before trusting this message. |
| An API call reports success but the on-screen symptom is unchanged | The call may be hitting the wrong object/mechanism entirely (e.g. poking a `CameraComponent` when the game's camera system doesn't use it) — stop iterating on the call and question the target. |
| Console output truncates or corrupts partway through an unprintable byte | The console itself is truncating on unprintable bytes, not a bug in the data — hex-dump instead of plain-text logging when bytes might be non-ASCII. |
| A property write succeeds and reads back correctly, but nothing changes on screen | Direct UPROPERTY writes can "stick" (readback confirms) without the engine acting on them if the underlying mechanism (e.g. render state, mobility) needs a separate trigger. |
| A read is `(0,0,0)` or otherwise implausible right after a spawn/level load | Reading a transform before the engine has placed it — guard with a plausibility check, don't trust the first read after spawn/load. |

