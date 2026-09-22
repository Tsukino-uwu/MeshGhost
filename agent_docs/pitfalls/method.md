# Pitfalls — method, and instruments that lie

How to diagnose, and the ways an instrument reports something that is not true. This is the half
read *before* trouble rather than during it: the diagnostic methodology, the failure signatures, and
the two entries about confirming what you are actually looking at before you probe it.

**The index over every entry in every one of these files is [INDEX.md](INDEX.md), one tagged line
each; the reading path is [../checklists/](../checklists/).** Add an entry here, add its line there
with its outcome — `dev-scripts/preflight.ps1` fails if you do not. How: [../pitfalls.md](../pitfalls.md).

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
  the state, after inference had failed. Do it EARLY, not after the guesses run out.
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
  `adapters/pseudoregalia/documentation.md`, `adapters/pseudoregalia/README.md`'s build-log step
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

**Cause 4 (2026-08-28) -- rewriting a config file WHOLE drops the sections you did not write.**
`-On` wrote ScriptEngine's config with only its `[AutoReload]` section, so BepInEx regenerated
`[General]` with the shipped default `LoadOnStart = false`: the switch that arms the loop disarmed
the loop. The game then launched with the adapter sitting in `scripts\` **unloaded** -- no ghost,
no error, indistinguishable from a broken mod.

**Cause 5 (2026-08-28) -- the symbols have to MOVE with the DLL, and this one is fatal rather than
untidy.** `-On` moved `MeshGhostTevi.dll` into `scripts\` and left `MeshGhostTevi.pdb` behind in
`plugins\`. Cecil then threw `SymbolsNotFoundException` out of `ScriptEngine.Awake`, which kills
the whole component: nothing loads at startup AND the file watcher is never armed, so no later
`-Deploy` can recover it either. One Unity error line is the entire trace. Note this is the SAME
exception as cause 1 with a different cause -- the message names the DLL either way.

**The lesson, which is now the same one five times.** A dev loop is an instrument, and
`CLAUDE.md`'s rule that *a diagnostic can break the thing it measures* applies to it before it
applies to anything it measures. **Prove the loop moves the thing** — here, by counting
ScriptEngine's own `Loading plugins from` lines in the log and the adapter's own despawn lines,
not by reading the deploy script's output. A loop that silently stops reloading turns every later
result into a measurement of the previous build.

**Cross-reference:** `adapters/tevi/VERIFIED.md`, "TEVI hot-reload dev loop"; the loop itself is
`dev-scripts/tevi-hotreload.ps1`, whose header carries the two limits that remain.


## Owning a live core you cannot reach — a walk that never advances past an empty port (2026-08-28)

**Symptom.** Two TEVI instances logged `bridge connection ended: ... actively refused` on repeat
for minutes, with no ghosts, while `netstat` showed each instance's OWN core alive and listening
on a bridge port in range. Every component looked healthy in isolation.

**Cause: two correct early-returns meeting.** The adapter's port walk advanced when a core
answered `busy`, and when one accepted then went silent -- but a connection **refusal** only
logged. Nothing moved the cursor off a port with nothing listening. Meanwhile the core launcher
returns early while the child it spawned is still running, so having already spawned a core it
would not spawn another. Result: an adapter **owning a live core it could not reach**. The
launcher thought its job was done; the walk had nothing to move it. Neither half is wrong alone.

**Why it stayed hidden.** The adapter's own core had always won the base port, so the cursor never
sat anywhere empty. The bug needed a core to die while the adapter's child lived on a *different*
port -- which only happened once a hot-reload loop made killing and respawning cores routine.
**A new dev loop is a new set of orderings**, and it will find interleavings the old one could not
reach. That is a reason to expect bugs when the loop changes, not a reason to distrust the loop.

**The fix, and why it is counted rather than immediate.** A port that refuses N times running
releases the cursor. It cannot advance on the FIRST refusal, because a refusal is the normal first
thing that happens on a cold start -- the adapter dials before its own core has bound. Advancing
immediately would walk the cursor off the base port on every launch and creep the whole range
upward run after run. The threshold has to exceed the spawn-plus-bind window, so it is derived
from the launcher's own cooldown rather than picked.

**The instrumentation lesson, which is the transferable one.** The failure line did not name the
port. `bridge connection ended: actively refused`, repeated, cannot distinguish *"the cursor is
stuck on one dead port"* from *"the walk is sweeping a range that is genuinely empty"* -- and those
want opposite responses. It read as a networking fault for several minutes. **A message about a
resource must name the resource**; a retry log without the target is a log that cannot be
diagnosed from.

**Cross-reference:** `adapters/tevi/MeshGhostTevi/BridgeClient.cs` (`RefusalsBeforeWalking`, `portRefusals`),
`adapters/tevi/UNVERIFIED.md` -- the fix's own recovery path is reasoned, not reproduced.


## Mirror the handler the game actually uses — Stay, not Enter/Exit (2026-08-28)

**Symptom.** TEVI's warp devices were made to wake for a peer ghost, and did. Then: a ghost stands
in a portal, the LOCAL player walks over it and away, and the portal shuts — with the ghost still
standing on it. User: *"it basically becomes inactive, if the player walks on top of it and then
away. even if another ghost is making the portal 'active'"*.

**Cause.** The adapter mirrored the game's `OnTriggerEnter2D`/`OnTriggerExit2D` and set its flags on
the ghost's TRANSITION in. The game does not work that way: its `OnTriggerStay2D` re-zeroes the
close timer on **every frame** the player is inside. So when the player's exit fired the game's own
Exit handler, nothing re-asserted the ghost that had never left.

**The rule.** **A transition cannot answer "is anyone still here" — only a per-frame test can.**
Two independent occupants make that concrete: any edge-triggered scheme silently assumes one. When
mirroring a game's own reaction, **check WHICH handler carries the state you care about** rather
than assuming Enter/Exit; a Stay handler that looks like mere bookkeeping is often where the
liveness actually lives.

**The asymmetry is real and worth keeping.** The fix re-asserts "keep open" every frame but leaves
"close" on the transition. Asserting both continuously would override the game opening the thing for
its own reasons — so the direction that ADDS a reason is continuous, and the direction that
REMOVES one is edge-triggered.

**And the cost it drags in.** Moving from transition to per-frame turned a once-per-entry lookup
into a per-frame one, and `GetComponentsInChildren` allocates an array on every call — a per-frame
allocation per object, which `adapters/CLAUDE.md`'s cost rule forbids. **Changing a check's
FREQUENCY changes its cost class**; cache whatever it reads at the same time.

**Cross-reference:** `adapters/tevi/VERIFIED.md`, warp devices; `adapters/tevi/BANDAGES.md` 7.


## A probe's sample rate is not a mechanism's sample rate (2026-08-28)

**Symptom.** A mirrored effect landed *"a tiny bit late"* on a peer ghost — consistently late,
never early, which is the shape of a bias rather than of jitter.

**Cause.** The code that detects the effect was written by copying a PROBE's polling interval
(20Hz) into the shipped mechanism. For a probe that rate is correct: a diagnostic must not cost
frames, and 50ms of sampling delay costs a diagnostic nothing because it is only ever read
afterwards. For a mechanism the same interval IS latency, added to every event, in one direction.

**The rule.** **A sample rate chosen for cost is not a sample rate chosen for latency, and code
that moves from probe to product must have that number re-decided rather than inherited.** The
give-away is a one-directional error: jitter is symmetric, sampling delay never is.

**Also check what the two are actually walking.** The probe here enumerated 375 pooled objects, the
mechanism only an allowlist of three pools — a few dozen. The mechanism could always have run
per-frame; the shared constant implied a shared cost that was never real.

**Cross-reference:** `adapters/tevi/MeshGhostTevi/Plugin.cs`, `WatchLocalVfx`;
`adapters/tevi/UNVERIFIED.md`, the charged attack.


## Mirroring through SHARED state makes symmetric peers echo each other (2026-08-28)

**Symptom.** A mirrored one-shot effect fired repeatedly instead of once — user: *"it sometimes
spams the ending VFX"*, and then, on checking, *"both the VFX & stars can get repeated/spammed"*.

**Cause, and it is a feedback loop of our own making.** The mechanism detected the effect by
watching the game's OBJECT POOL for a rise in active objects. Playing the effect on a ghost
activates an object in **that same pool**. Both peers run the same adapter, so: A attacks, B plays
it on A's ghost, B's own watcher sees B's pool rise, B reports it as B's own effect, A plays it on
B's ghost, and round it goes.

**The guard that could not work.** Ownership was decided by distance — an effect within N units of
the local player is the local player's. That is exactly wrong here: it fails precisely when the two
characters are NEAR each other, which is when anyone is watching them. **A heuristic that degrades
where the feature is used is not a weak guard, it is an inverted one.**

**The fix is identity.** Record the instance ids of the objects THIS adapter activated for a ghost
and never count those as local activity. Counts cannot separate *"the game spawned one"* from *"we
spawned one"*; ids can, which is the same lesson `effect-investigation.md` already records for
pooled effects and here appears in a new place.

**The general rule, worth having before mirroring anything else this way.** Reading a game's own
state to detect an event is a great way to MIRROR A DECISION rather than re-derive it — and it is
safe only while that state is written by the game alone. **The moment your own mirroring writes to
the same place you are reading, two symmetric peers form a loop.** Ask, before choosing a detector:
*if the peer ran this exact code, would my detector see their output as my input?* Field reads
(a clip name, a speed value) are immune; shared containers — pools, spawn lists, scene queries —
are not.

**Cross-reference:** `adapters/tevi/MeshGhostTevi/Plugin.cs` (`ghostSpawnedEffects`),
`adapters/tevi/VERIFIED.md`, the charged-attack entry.

## An answer that ARRIVED and was never READ -- a control-plane message parsed behind a gameplay gate (2026-08-28)

**Symptom.** Two TEVI instances, launched against two healthy cores that were already listening,
walked the entire 7778-7785 bridge range on every launch, spawning a core per port and logging
`bridge port N accepted a connection but never answered hello within 1.5s` for every one of them.
The user saw ports churning and no ghosts until they reached play.

**What settled it in ONE step: read the ACCUSED side's log at the accusing timestamp.** The
adapter said the core never answered. The core's own log, at that exact second, said
`core: ghost collision enabled (set by the room) -- told the adapter` -- which the core only ever
prints AFTER accepting an adapter's hello. Two logs disagreeing about one event localises the bug
to whichever side's claim is unsupported, without a theory, a probe, or a rebuild. **Whenever a
component blames another component, go and read the other one before believing it.**

**Cause.** `bridge_ready` is parsed inside `DrainInto`, which runs on the main thread -- and
`Plugin.Update` called `DrainInto` only BELOW its play-session gate. At the main menu, on the title
and through every loading screen, nothing consumed the message. Meanwhile the 1.5s deadline ran on
wall clock, so it expired against a core that had already accepted us, and the walk moved on. TEVI
always launches into a main menu, so this fired on every launch.

**Fix, and the shape of it is the lesson.** Two halves: the gate now drains every frame with the
remote callbacks replaced by no-ops (the control plane gets through, the invariant that no ghost
may exist without a local player is untouched), and the deadline additionally requires that the
drain has actually RUN a number of times since the hello went out. A wall clock cannot express
"we had a chance to look" -- which is exactly what the Lua adapters' equivalent bound, 90 FRAMES,
expresses for free, because a frame count cannot advance while the host is stalled.

**Transferable, and none of it is about TEVI:**

- **A timeout on a message you only read on a gated path is measuring the gate, not the peer.**
  Either read it ungated, or measure the deadline in units that stop when the reader stops.
- **Separate the CONTROL plane from the CONTENT plane at the gate.** The reason it is safe to
  drain out of play is that only the remote-state callbacks were ever the hazard, and they can be
  dropped independently. A gate that blocks both is blocking more than its stated reason.
- **Any host with a loading screen has a multi-second main-thread stall built in**, so any
  wall-clock deadline whose satisfaction depends on the main thread is a launch-time bug waiting
  for a slow disk. Look for these deliberately when porting the pattern to a new host.

**Cross-reference:** the walk's two earlier and DIFFERENT causes are "Owning a live core you cannot
reach" above (a refusal that never released the cursor) and the misattributed reject in
`adapters/tevi/BANDAGES.md` entry 5. Three distinct causes, one identical symptom -- which is why
the log line now names the port the CONNECTION was on.


## A second derivative of network samples is visible no matter how you gate it (2026-08-28)

**Symptom.** Ghost prediction that included acceleration produced visible chop -- twice, in two
different forms. Raw acceleration made every axis snap ("left/right looks snappy/bad"). A second
attempt gated the acceleration by its own cross-window consistency, passed a clean-parabola test
beautifully, and on screen produced jump chop AND a new snap at the end of a steady run.

**Cause.** The size of the acceleration term fluctuates frame to frame under sample-timing jitter,
whatever gates it -- consistency, damping, thresholds. A prediction whose DIRECTION is right but
whose SIZE wobbles is still visible, because the eye reads the wobble as motion. Velocity has the
same problem one derivative down, where it is small enough to damp; differentiating jittery data
twice amplifies the jitter past what any gate can hide.

**Fix.** Velocity-only prediction, damped per axis by consistency with a 40% floor
(`core/interp.go`, `PredictDamped`). The jump's residual lag is the accepted price, written down
as such. Both failed variants are pinned by tests that a future re-attempt will trip
(`core/extrapolate_test.go`).

**Transferable.** Two differently-shaped fixes failing with the SAME visible symptom is the stop
signal (CLAUDE.md) -- the shared ingredient is the cause. And a unit test on clean synthetic data
cannot clear a mechanism whose failure mode IS noise: the gated version passed its parabola test
and failed the screen within minutes.


## An interpolation delay below the link's jitter converts smoothing into chop (2026-08-28)

**Symptom.** Lowering `interp` from 100ms to 50ms -- "more responsive" on paper -- made steady
walking and jumping choppy, "feels like low frame rate". Raising it back cured it. A confidence-
smoothing change was blamed first and A/B'd innocent; the interp value was the variable.

**Cause.** With the render delay below the link's jitter (±25ms simulated), the render time
oscillates across the newest-sample boundary every few frames: one frame interpolates between two
real samples, the next predicts past the newest, the next interpolates again. The two regimes
place the ghost by different rules, and crossing between them at frame rate is the chop.

**Fix.** Keep `interp` at or above the link's jitter and let prediction cover the immediacy
(`interp 100ms` + `extrapolate` won the sweep). The rule of thumb is now in the shipped config
template's comment: never set interp below your connection's jitter.

**Transferable.** "Lower delay = more responsive" has a floor, and the floor is a property of the
LINK, not the renderer. Judged on a clean loopback the floor is invisible -- every render-timing
change needs a netsim pass before its verdict counts.


## A count-bounded history silently shortens a time-based delay -- "250ms" was 140ms with stutter (2026-08-28)

**Symptom.** On the netsim rig, the 250ms-interp baseline looked "a bit stuttery when just doing a
long left/right walk" (user) -- while a jump from standing still looked correctly quarter-second
late. The stutter read as a network artifact; it was the renderer's own history.

**Cause.** `remoteBuffer` kept the last 8 SAMPLES -- a count -- while the interpolation delay is
TIME. At the dev rigs' 100Hz send rate, 8 samples span ~80ms during sustained movement, so a 250ms
render time fell off the buffer's old edge and edge-held, which is both stutter and a silently
shorter delay. Change suppression made it intermittent: idle samples arrive 250ms apart, so a
jump from standing had a deep-enough window and honestly showed 250ms -- one rig, two behaviours,
depending on what the player had just been doing.

**Fix.** Trim by time (600ms of the newest sample's clock) with the count kept only as an
adversarial cap (`core/interp.go`, pinned by `TestRemoteBufferEvictsOldSnapshots`).

**Which past readings this poisons, audited rather than waved at:** any run with interp >= ~100ms
on a 100Hz rig during sustained movement -- both of 2026-08-28's 250ms baselines, and the
`run-core-emerald-trail.bat` rig (200ms at 100Hz), whose smoothness judgements should be re-made.
Unaffected: every `-interp=0` dev run, the 20Hz shipped-rate rigs (8 x 50ms = 350ms of cover), and
the sweep's 100ms netsim runs (netsim's 60ms latency happened to keep the render time inside the
window) -- so the sweep's winner stands.

**Transferable.** When one knob is a TIME and the resource behind it is a COUNT, the knob's range
is silently bounded by rate x count, and it fails only at one end of the rate range -- check which
unit every buffer behind a duration setting actually trims on. And the tell was the SPLIT symptom:
correct in one motion pattern, wrong in another, on the same settings.


## A probe that edge-triggers on part of a value is blind to the rest of it (2026-08-28)

**Symptom.** A ghost's weapon rendered the wrong colour variant. A probe watched the player's
sprite layers and logged every colour CHANGE -- and reported the effect layer strobing while
saying nothing at all about the flash layer, which looked like "the flash layer never changes".
The real hunt then ran for several rounds against an incomplete picture.

**Cause.** The probe compared only the RGB part of each colour. A layer whose ALPHA varies while
its RGB stays put -- which is how this game shows and hides an overlay -- is structurally
invisible to that comparison. The probe was not quiet because nothing happened; it was quiet
because it could not see the axis the change was on.

**Fix.** Dump the WHOLE value at a known event (all five layers, full RGBA, sprite and material,
once per hitstop) rather than edge-triggering on a projection of it. That dump answered the
question on its first run.

**Transferable, and it generalises past colours:**

- **An edge trigger encodes a hypothesis about which field matters.** When the hypothesis is
  wrong the instrument reports silence, and silence reads as evidence of absence.
- **Prefer dumping everything at a rare EVENT over sampling a projection continuously.** A hitstop
  happens a few times per attack; there was never a cost argument for the narrower probe.
- **The game's own idiom is the clue**: this engine leaves colours set and drives alpha. The same
  session's other bug -- a ghost stuck on one colour forever -- was the mirror image of the same
  fact, ignoring alpha when deciding whether a layer was showing at all.


## When mirroring an IMPULSE and a HOLD, the hold needs the truth of its own frame (2026-08-28)

**Symptom.** TEVI's charged attack, mirrored onto a ghost over a jittery link. The frozen pose
landed early; fixing that with phase-gating then made the star fire AFTER the freeze, reversing
the game's own order; and a sender that reported a remembered colour to keep a strobe continuous
made every held pose show the wrong colour.

**Cause.** Two kinds of event were being mirrored with one mechanism. An IMPULSE (the star) is
already ordered correctly by arrival, because it rides the same delivered timeline as everything
else. A HOLD (the hitstop pose, the frozen colour) is a state the peer is SITTING IN, so it must
be reproduced from what the peer reports at that moment -- not waited for, not substituted, not
smoothed.

**Fix.** Impulses fire on arrival. The hold snaps: the ghost seeks to the peer's reported phase and
stops there, and takes the peer's instantaneous colour verbatim. Continuity tricks that help the
moving case (bridging a strobe's gaps) live on the RECEIVER, where they cannot corrupt what the
sender reports about the current frame.

**Transferable.** **Ask of every mirrored event: is this a thing that HAPPENED, or a thing the peer
is IN?** The first wants ordering, the second wants truth. And a "helpful" substitution in a sender
-- reporting what is usually true instead of what is true now -- is invisible until some consumer
needs the exact frame, which is exactly when it is hardest to attribute.


## A test that builds both processes in the same breath cannot catch a bug about the delay between them (2026-08-28)

**Symptom.** First live Emerald session after relay-side area filtering shipped: *"the ghost gets
stuck right on the tile they crossed over into, and despawn after a few seconds."*

**Cause.** A client declares `own_area_only` in its relay Hello. But `cmd/meshghost` connects to the
relay at STARTUP from its `-game` flag, while its adapter attaches when the GAME launches -- two
minutes later in that session. So the Hello was sent with no adapter to ask, defaulted to "filter
me", and the relay filtered Emerald, whose cross-map ghosts must never be filtered.

**Fix.** `protocol.TypePrefs`, a small client-to-relay message sent when an adapter attaches,
correcting what the Hello could not know. ADR 0041's amendment.

### Why every automated check missed it, which is the transferable part

The unit tests all passed, and so did the first `internal/e2e` case written specifically for this
feature. **Because they constructed the client and the adapter in the same breath** -- so the
adapter attached within milliseconds, usually before the client had finished connecting, and the
Hello happened to carry the right answer. The one arrangement that hides the bug is the one a test
writes by default.

**The rule: when a defect is about the ORDER of two real processes, the test must force that order,
and forcing it usually means letting real time pass.** The regression test here sleeps a second
between starting the clients and attaching the adapters, and that sleep IS the test rather than
something to tune away. It was confirmed by deleting the fix and watching it go red -- which the
version without the sleep did not.

Related, and the same shape: `_template/probes.md`'s warning that a diagnostic can break the thing
it measures. Here a TEST was hiding the thing it measured.

### Two more lessons, both cheap to reuse

**"It fails open, so it is harmless" is only true if the fail-open is permanent.** The code comment
justifying the broken default said an unattached adapter was harmless *"because it sends no state,
so the relay's filter fails open for it regardless."* True -- until the client starts playing and
its area becomes known, after which the stale declaration applies for the whole session. **A
temporary fail-open is not a fail-open**, and the window it covers is exactly the window before
anyone would notice.

**A counter built to SIZE a decision is also the diagnostic for that decision regressing.** The
cross-area shadow counters shipped on 2026-08-18 to answer "would filtering be worth it?" On
2026-08-28 the same `-introspect` line answered "is the filter wrongly on for this game?" in
seconds: it read **60% of bytes filtered in a room that should have had 0%**. Reach for the numbers
a feature was justified with before reasoning about the feature's behaviour -- they are usually
still pointed at the right place.

## LOG THE SUCCESS PATH FROM THE FIRST BUILD, or three bugs share one symptom (2026-08-28)

**The rule, paid for over roughly twelve live launches in one evening:** anything that DRAWS
something needs a readback of what it actually built, in the very first version, not after it fails.

Pseudoregalia's nametags logged only failures. That made three completely different states
indistinguishable on screen and in the log:

- the component was never created (a lookup returned null and the code quietly did nothing),
- it existed and rendered nothing,
- it existed and rendered the WRONG STRING -- `UTextRenderComponent`'s default `"Text"`, which
  reads exactly like "the name never arrived".

Each needed a different fix and each cost a live session to tell apart. The readback that finally
separated them -- registered / visible / hidden / font / material / size / the string it actually
holds / where it actually is / its colour bytes -- took twenty minutes to write and would have
skipped nearly all of that had it existed from the start.

**"No warning" is not evidence of success.** It only ever means "not missing". Twice in that
session a call was read as having worked because nothing complained, when it had resolved and done
nothing. Log which lookups RESOLVED, not only which ones failed -- an absence proves nothing about
either.

**And the corollary that catches the rest:** when two logs disagree, believe the pair, not either
one. The bug that had eaten the evening was found in one minute by logging every distinct bridge
message type on first sight: the adapter's log listed one type, the core's log showed three being
sent, and the contradiction pointed straight at the tick between them.

## TWO COPIES OF ONE GAME SHARE ONE LOG FILE, so neither can be attributed (2026-08-28)

Two instances of the same install write to the SAME `UE4SS.log` and, because the mod launches the
core with its own folder as the working directory, the same `meshghost.log`. The second process's
lines are simply absent -- the first holds the file.

That produced a false finding and most of an evening's misdirection: "only the game started FIRST
shows a nametag" was taken as a fact about join ORDER between clients. In truth the second instance
logged nothing at all, so there was no evidence either way about what it did.

**So a two-instance test on one install can confirm what a person SEES and can prove nothing from
logs.** When a symptom needs log evidence, reproduce it with ONE game plus a synthetic peer
(`meshghost-fakeadapter`, which can join first to recreate the "already in the room" ordering), or
use a second install. Stamp the process id into any log line you intend to attribute -- one call,
and it is what finally made the two separable.

**A related rig limitation, same evening:** `meshghost-fakeadapter` does NOT redial when the relay
restarts. Twice a "the ghost vanished" report was the rig quietly dying rather than anything about
the code under test. Check the peer is still connected before believing a disappearance.

**RECURRED 2026-08-29, in the opposite direction and worse.** Here both instances DID reach one
`UE4SS.log`, interleaved — and that is the more dangerous shape, because the file looks complete.
Two `MIRRORVFX local: '' -> 'dl'` lines 280ms apart were read as two players landing independently,
and a whole diagnosis ("single jumps work, fast repeats do not") was built on top of it and reported
as a clean pattern. Both lines were one player: the second was the feedback loop echoing. **The user
corrected the premise, not the analysis** — *"its not supposed to show your own 'dust' on a ghost"* —
and the same log then read unambiguously.

**The tell was present and unused:** the interleaved tick counters ran in two clearly separate
series (≈39841/41335 against ≈44855/47105). A field that should advance monotonically and instead
jumps between two bands IS the "this file has two writers" signal. Check for it before attributing
any line, and prefer the lines that name a peer (`ghost p4: started`) over the ones that do not
(`local: ...`), because only the former carry whose stream they belong to.

**And the general form, which outlives the log detail:** an agent reading a log decides which
process each line came from, usually without noticing it decided. Say the attribution out loud
before building on it. Two of this session's three diagnoses were wrong, both because of an
unstated assumption about who produced a line — and both were corrected by the user describing
what they SAW, which no amount of further log analysis would have produced.

## Failure signatures

Misleading symptoms that mean something other than their surface reading:

| Symptom | Actual meaning |
| --- | --- |
| UE4SS Lua: "Tried calling a member function but the UObject instance is nullptr" | Usually means the UFunction isn't reflected on this build, not that the object is actually null — confirm the object's validity separately before trusting this message. |
| An API call reports success but the on-screen symptom is unchanged | The call may be hitting the wrong object/mechanism entirely (e.g. poking a `CameraComponent` when the game's camera system doesn't use it) — stop iterating on the call and question the target. |
| Console output truncates or corrupts partway through an unprintable byte | The console itself is truncating on unprintable bytes, not a bug in the data — hex-dump instead of plain-text logging when bytes might be non-ASCII. |
| A property write succeeds and reads back correctly, but nothing changes on screen | Direct UPROPERTY writes can "stick" (readback confirms) without the engine acting on them if the underlying mechanism (e.g. render state, mobility) needs a separate trigger. |
| A read is `(0,0,0)` or otherwise implausible right after a spawn/level load | Reading a transform before the engine has placed it — guard with a plausibility check, don't trust the first read after spawn/load. |


## NOTHING THAT CAN BLOCK GOES BEFORE A HANDSHAKE COMPLETES — and a change with no proven benefit is not free (2026-08-29)

**What happened.** A nametag failed to appear for a peer already in the room, and a plausible cause
was found by reading: the roster's names were stored in a `defer`, which runs at FUNCTION exit and
therefore AFTER the line that hands the Welcome to the waiting handshake. The handshake's caller
then pushes the adapter everything already known — so the push would read an empty map. Airtight,
and moving the store earlier was an obvious tightening.

**It was wrong twice.** The race was tested before shipping the fix: with the store deliberately
left late, the delivery test passed 60 runs out of 60, so it decides nothing. The change was kept
anyway, on the reasoning that deterministic beats timing-dependent — and that reasoning is what
cost, because `storeRemoteName` writes to the adapter's bridge socket, that write can BLOCK, and
blocking before the Welcome send delays the very handshake it is waiting on. The pre-existing
`FuzzSchedule` caught it as `alice ... timed out waiting for welcome`.

**Two rules out of it.** Nothing that can block — a socket write, a lock somebody else may hold, an
unbounded callback — belongs on the path before a handshake completes; move it after, or make it
asynchronous. And **a change with no demonstrated benefit still has a cost**: "it cannot hurt" is a
claim about code nobody has measured. Having measured that this one did not help, the honest move
was to revert it, not to keep it for tidiness.

**And the reason it was caught at all:** a schedule fuzzer that already existed and was not
believed to. It had been described, in this repo's own planning notes, as absent — from listing
target names and reading their categories rather than reading what they do. **An inventory taken by
name is a guess.**

## A DATA RACE SEEN ONCE IS REAL — AND FILTERING THE OUTPUT LOSES THE ONLY PART THAT ATTRIBUTES IT (Go side, 2026-08-30, CLOSED)

**Symptom.** One full `-race -count=3` run reported `WARNING: DATA RACE` with
`--- FAIL: TestARelayDropInsideTheHandshakeStillReconnects`.

**Not reproduced since**, across 12 runs of `./core`, 3 runs of the whole package, and a clean
full-suite race run. **Status: OPEN, unattributed, and specifically NOT fixed.** The temptation is
to call a non-reproducing race a flake and move on; a race that appears once is a real race whose
window is narrow, which is exactly the kind that reaches a user and never reaches a test.

**The method mistake, which is the transferable half.** The race report was piped through a
`Select-String` filter that matched only the summary lines, so the goroutine stacks — the only part
that says WHICH two accesses raced and therefore whose bug it is — were discarded, and the run
never reproduced to give them back. **Capture the whole race output to a FILE first and filter the
file afterwards.** A race report is not like a test failure that can be re-run on demand.

**Where to look first if it returns**, offered as a starting point and not a conclusion: the
handshake/reconnect path the failing test exercises. The interpolation work that landed the same
day touches neither that path nor anything the test uses — but "the new code looks unrelated" is a
hypothesis, and this entry exists precisely because nobody could check it.

**CI is the likelier place to catch it again**, since it runs `-race` on every push against
different scheduling. A red CI run naming this test is a gift to be READ (`gh run view <id>
--log-failed`), never re-run until it goes green.

**CLOSED THE SAME DAY, and the method above is what closed it.** The next full race run was captured
to a FILE first and filtered afterwards — the exact change this entry prescribes — and it
reproduced with the stacks intact. Reproduction rate was roughly one full suite in five, which is
why the first four attempts (12x `./core`, 3x the package, a clean full suite) all missed it: the
earlier "not reproduced" was a sampling failure, not evidence of absence.

**The cause, and it is not what "handshake reconnect test fails" suggests.** The race was on
`beforeArmingAutoRetryHook`, a plain `func()` package variable that exists only as a test seam. The
WRITE is the test's own `t.Cleanup` clearing it; the READ is this package's RECONNECT goroutine,
which outlives the test that started it and is still looping through `ConnectRelayOnAdapterHello`
when Cleanup runs. Fixed by making the hook an `atomic.Pointer[func()]`.

**Two lessons worth more than the fix:**

- **A TEST SEAM IS PRODUCTION CODE FOR RACE PURPOSES.** The hook is nil in every real session, so
  nothing shipped was ever at risk — and it failed the suite exactly as hard as a real bug would.
  "Only tests" is not a reason to leave a race in a package whose `-race` job is the thing standing
  between this project and the bugs local runs cannot find.
- **A GOROUTINE THAT OUTLIVES ITS TEST IS THE DEFAULT, NOT THE EXCEPTION.** Anything a test starts
  that retries, backs off or reconnects is still running during `Cleanup`. Assume it, rather than
  assuming the test owns the end of its own lifetime.

**Evidence:** `agent_docs/testing.md`'s Traps list, `core/relaysession.go`'s comment above the hook.

## A ghost cost half the frame rate, and every suspect was wrong (Pseudoregalia, 2026-08-30)

**Symptom, user-reported:** one peer took the game from 144fps to 70-80. Two real clients were the
same, three ~40, four ~30 -- *"the game becomes unplayable with even just 2-3 players"*.

**What made it tractable was the fake peer.** `cmd/meshghost-fakeadapter` puts a synthetic player
in the room wearing a real `game_id`/`area_id`, so ONE running copy of the game renders a ghost.
That separates the cost of a ghost from the cost of a second game process on the same machine --
the user's original numbers could not, and they turned out to be nearly identical, which was itself
the first finding.

**Then a subtraction settled CPU vs GPU in one run:** `hide_ghost_mesh.txt` keeps the ghost
ticking and stops it being drawn. The frame rate did not move. Not rendering. That single reading
retired every "make the ghost cheaper to draw" idea -- LODs, shadow casting, lights -- before any
of them cost a build.

**Every remaining theory was still wrong.** The per-tick mirrors, the VFX census, the nametag, the
custom-depth strip: all named as suspects from reading the code, all measured at 0-13 us/frame.
The instrument that settled it was a **per-subsystem frame-cost timer** -- scoped timers around each
block, accumulated microseconds printed every ~2s, armed by a file so it costs no rebuild to switch
on (`adapters/_template/probes.md` has the shape). `tick_total` is the whole game-thread cost, so
every other slot reads as a share of it and **the unattributed remainder is a finding rather than a
gap** -- which is exactly how this was cornered: the cost kept living in whatever had not been
wrapped yet, and three rounds of bisection put it in one place.

**The cause, four times over: WHOLE-WORLD SCANS ON THE TICK.** Every one asked
`UObjectGlobals::FindAllOf` for a class and then ran a name-chain property lookup, or built a
`GetFullName()` string, per object returned:

| What | Cost | Why it was there |
| --- | --- | --- |
| `find_local_controller_and_pawn` | 1308 us/frame | Re-finding the local pawn every tick. Ran with **zero peers** -- it was slowing single player down. |
| The ghost-light hold | ~6357 us/frame | Two scans per ghost per tick to re-find a light that had to be held down every frame. |
| The dev-toggle subtractions | ~3300 us/frame | `hide_ghost_shadow`/`hide_ghost_nametag`/`hide_ghost_fx` swept the world **in normal play, armed or not**. |
| The outline + afterimage sweeps | ~500 + ~1300 us/frame | Belt-and-braces behind a pre-hook that already refuses the write. |

**The fixes are all the same shape, and none of them trade fidelity:** find the object once and
hold the pointer (the light components, the controller); walk the ACTOR'S OWN attach tree instead
of the level (the outline sweep); run a dev instrument only while it is armed, plus one pass to
restore what it hid; put a belt-and-braces sweep on an interval when the braces cannot be late.

**Result: 9819 -> 2924 us/frame with a ghost, per-ghost cost 6283 -> 309 us (~20x), and the user's
own reading 70-80fps -> 141-144fps.** That is what decides whether a room scales: at 6.3ms a ghost
you are unplayable at three players; at 0.3ms, ten ghosts cost 3ms.

**What to carry forward:**

- **`FindAllOf` in anything that runs per tick is a bug, not a style question.** It is O(all
  objects) and the per-object property lookup on top of it is the expensive half. Resolve once,
  hold the handle, invalidate where every other raw pointer is already dropped.
- **A dev instrument that runs when it is not armed is a shipped cost.** CLAUDE.md's "a diagnostic
  can break the thing it measures" turned up here in the SHIPPED path, not in a probe -- and it was
  the second-largest cost in the game. When adding a toggle-driven sweep, gate it on the toggle
  plus a latch for the one restoring pass, never on an interval "so it stays responsive".
- **Do not theorise about which subsystem is expensive.** Six suspects were named from reading the
  code and every one measured at ~0. The timer took three rounds and answered it exactly.
- **Measure the no-peer baseline too.** It was 2269 us/frame before any of this -- proof that a
  third of the cost had nothing to do with multiplayer at all.

## Caching a level-owned pointer is a crash, and the hook you would hang it on does not fire (Pseudoregalia, 2026-08-30)

**The optimisation is obvious and it is wrong.** Four whole-world scans per tick were costing half
the frame rate (previous entry), and the natural fix -- find the object once, keep the pointer --
crashed the user's game within the hour.

**Symptom:** the empty `Fatal error!` dialog on the second client, when the user chose **reload
save**. The adapter's log has no `LoadMap PRE fired` line anywhere near it.

**IMPORTANT, and the reason this entry nearly recorded a falsehood: THAT CRASH WAS NOT CAUSED BY
THE CACHES.** It was attributed to them for three exchanges on the strength of the reasoning below,
and then a bisect -- deploy the pre-session DLL, ask the same question -- showed the same crash on a
build with none of this in it. **The lifetime defect described here is still real and the caches
still had to go**, but the crash that exposed the argument belongs to a separate, older bug
(`adapters/pseudoregalia/UNVERIFIED.md`). CLAUDE.md already says to bisect real commits early; the
cost of not doing it here was three rounds of confident wrong attribution to the user.

**Cause:** a same-level save reload frees the level's actors **without firing the LoadMap PRE
hook**, which is where this adapter drops every other level-owned pointer. Three caches added that
day -- the local PlayerController, a ghost's light components, the pooled projectile actors -- were
all left pointing at freed memory, and the next tick dereferenced one.

**And the guard is the same crash.** `IsUnreachable()` reads the object's own memory, so testing a
freed pointer with it *is* the access violation. This file already carried that lesson from
2026-08-13, on the camera view-target pointer; it was not applied to the caches written on top of
it.

**What to do instead, in order of preference:**

1. **Walk from an object whose lifetime you already manage.** The light hold was rewritten to walk
   the GHOST'S own attach tree -- `remote.ghost` is released at teardown and world-checked every
   tick, so nothing new is assumed -- and it kept the entire ~6357 us/frame saving. This is the
   right shape: same saving, no new lifetime claims.
2. **Scan on an interval** where the immediate half is guaranteed by something else (a pre-hook
   that refuses the write, for instance).
3. **Pay the scan** and say so in a comment, which is what the controller and projectile paths now
   do.

**Before caching across ticks in a UE adapter at all, you need a RELIABLE new-world signal** -- a
hook that fires on a same-level reload, not just on LoadMap. Finding one is the prerequisite piece
of work, not an optimisation detail.

## A diagnostic sweep can be load-bearing: check what it does when it is NOT armed (Pseudoregalia, 2026-08-30, OPEN)

Gating three dev subtractions to run only while armed removed ~3300 us/frame -- and the same
session reported ghosts going invisible. The unexamined half: while nothing was armed the sweep
still ran and called `call_set_visibility(component, true)` on anything of the ghost's it found
hidden. **It may have been an accidental per-tick RE-SHOW that other code depended on.**

**ANSWERED the same evening: the gating was innocent.** A clean-rig A/B -- gating off, then on,
nothing else changed -- kept the ghosts visible both times (0 and 1 spawn/despawn cycles, against 44
during the bad session). The vanishing was a polluted rig: a fault-injecting proxy left in the path
and dead cores still counted as room members.

**The lesson that survives is about the A/B, not the sweep.** The suspicion was reasonable, the code
reading was plausible, and it was still wrong. What settled it in one run was **cleaning the rig and
changing one thing** -- not more code reading. When a symptom appears during a session whose rig has
been restarted repeatedly, REBUILD THE RIG BEFORE THEORISING: three exchanges went into a visibility
mechanism that was never involved.

The generalisable half of the original note stands anyway: **before gating a sweep, ask what it
writes on the path where nothing is armed.** A subtraction instrument that also restores is two
mechanisms wearing one name.

## Six hypotheses before opening the crash dump (Pseudoregalia, 2026-08-30)

**What happened.** "Reset to last save" crashed reproducibly whenever a ghost had been spawned. Over
several hours the agent proposed and tested six mechanisms -- the ghost actor existing at reset, the
tick respawning into a tearing-down world, a stale camera pointer, all five UFunction hooks, a
leaked light registration, an orphaned pawn -- each needing a build, a deploy and a game relaunch by
the user. **All six were refuted by measurement.**

**Then the dump was read, and took ten minutes.** It gave two facts no amount of code-reading had
produced: the faulting instruction is **inside the game's own executable**, and the fault is a
**null dereference at one fixed offset, identical across five crashes**. That immediately retires
every "we corrupted/leaked a pointer" theory -- a null read means the game wanted a pointer that
something CLEARED -- and it says the crash is deterministic and single-cause.

**The user's own words, and they are the rule now:** *"why didn't we do this from the start, after
the first crash? makes more sense to debug and find the issue, than testing like 5-10+ things"*.

**Why it was skipped, so the next agent recognises the trap:** `CrashContext.runtime-xml` was
opened early, its `<CallStack>` element was EMPTY, and that was read as "the dump tells us
nothing". The `.dmp` file sitting beside it is a different artifact entirely. No debugger is
installed on this machine, which made "read the dump" feel unavailable -- but the MINIDUMP format
is documented and a 100-line `struct` parser gets the module and the fault kind
(`dev-scripts/read-minidump.py`).

**The generalisation, beyond crashes:** when an artifact of the failure ALREADY EXISTS -- a dump, a
core file, a log the game wrote itself -- read it before generating hypotheses. Guess-and-test costs
the user a relaunch per guess; reading costs nothing and often ends the search. This is the same
instinct as "if a game has a cleared decompilation, READ IT FIRST" in CLAUDE.md, applied to runtime
evidence instead of source.

## A dozen single-run A/Bs against an intermittent bug (Pseudoregalia, 2026-08-31)

**What happened.** A crash was chased from 22:00 to 01:15 on 2026-08-30/31 with one run per configuration -- destroy here,
suppress there, hook this, skip that -- each result written down as a verdict. Then the user
reported several successful resets followed by a failure on the same build, and the whole method
collapsed: **the fault is probabilistic**, so a single run distinguishes nothing and most of those
"refutations" were coin flips.

**The tell was there earlier and was noticed without being acted on:** the crash did not reproduce
while a heavy trace slowed the game down. That is a race, and a race is by definition not
one-run-testable. The right response was to switch to N-run comparisons immediately; instead the
next single-run A/B went out.

**The rule: as soon as a fault is known or suspected to be timing-sensitive, a configuration costs
N attempts, not one.** Record it as "k of n", pick n so that a zero would be surprising (five is
usually enough to notice), and refuse to compare configurations tested at different n.

**And prefer a measurement to an A/B entirely.** "What is different about the world after a ghost
has existed" is answerable in one pass and does not care about timing; "does this change help" needs
a sample. When the bug is probabilistic and the user pays a game relaunch per sample, the
measurement is the cheaper instrument by a wide margin.

## An error names its LIMIT, not its cause — and two layers can hold different limits (2026-09-01)

`bufio.Scanner: token too long` from a core at 150 peers led the hunt to the transport package,
whose `DefaultMaxLineBytes` is a generous 64KiB no legitimate message approaches — so the first
theories were exotic: partial writes mis-framing the stream, quic datagrams splicing mid-line.
The actual connection was constructed with `protocol.MaxLineBytes` = **4096**, and the dying
line was a perfectly healthy Welcome that a ~100-member room legitimately outgrows. The error
text carries no limit value and no offending bytes, so every reader assumed the limit they knew.

**Three moves that settled it, in order of cheapness:**

1. **A raw client with no line cap, joined to the live room** (a dozen lines of python: dial,
   hello, measure every line received). It cleared the room-wide traffic in one run — biggest
   line 941 bytes — which narrowed the oversized line to something only the DYING client
   receives, i.e. its own Welcome.
2. **Make the failing instrument dump its evidence**: the scanner's split function sees the full
   buffer at the moment it overflows, so `transport` now attaches the line's head to the error
   (`read-minidump.py`'s lesson again — the diagnostic that names the thing beats the theory).
   The head read "welcome", mid-JSON, healthy — refuting corruption in one look.
3. **Grep for who CONSTRUCTS the connection, not who defines the default** — the limit that
   binds is the one passed at the call site (`FromConnWithLimits(netConn,
   protocol.MaxLineBytes, ...)`), and it was sixteen times tighter than the package default the
   error was being read against.

**The rule: when a limit-shaped error fires, print or find the LIMIT'S ACTUAL VALUE at that call
site before theorizing about what exceeded it.** And the design half: any message that grows
with room membership will cross ANY fixed line limit eventually — bound the message (the Welcome
now lists 32 members and hands the rest over as ordinary Joins), don't raise the limit.

## An embedded-interface wrapper hid WriteUnreliable, and the relay forwarded every state on the stream from 01:28 to 21:45 (2026-09-02)

**Symptom:** TEVI ghosts snapped every few seconds through `meshghost-netsim` at 2% loss, at 175, 250 and
300ms interp alike, with the loss cover on or off. **Wrong theories that looked right:** interp too short
for the link (the documented lesson, and 175ms really was); the loss cover, landed that day (A/B'd off:
same snaps); the quic-go bump, also that day (v0.61.0 built and run: same). **What settled it:** two
meters on the core's stats line — `buffer dry` (renders past a MOVING peer's newest sample) and
`transit` (arrival minus the sender's timestamp). Transit hit 770ms on a proxy that adds ~230ms at most,
so a stall, not a short buffer; tcp on the same proxy never exceeded its ceiling; a QLOGDIR-gated qlog
trace then showed the relay sending zero datagram frames on every server connection. **Cause:**
`netx.LimitListener`'s `limitedConn{net.Conn}` embeds the INTERFACE, so the concrete connection's
`WriteUnreliable` was hidden and `transport.SendUnreliable`'s type assertion fell back to the stream.
**Fix:** `341a768`, a wrapper that forwards the method, with a test that fails without it.

**What to reach for first next time:** the meters before the ladder, a transport A/B (tcp/udp/quic on
the same movement) before any theory, and a fake peer (`meshghost-fakeadapter`) so the measurement runs
without a person at the keyboard. And on the day a wrapper is written: assert for the optional methods
on the wrapped result. `agent_docs/verified.md`, "The limiter hid WriteUnreliable". [RULE:
checklists/before-a-network-change.md] [CHECK: netx/limit_test.go TestLimitListenerKeepsTheUnreliableWrite]

## An inline heredoc plus a bypassing PowerShell in one bash command is a Defender trojan signature (2026-09-03)

**Symptom:** the Bash tool failed with `EPERM: operation not permitted, uv_spawn bash.exe`, and the user saw
Microsoft Defender raise **Trojan:Win32/PowhidSubExec.B**, alert level Severe, status Active, on the
command line itself. **Cause:** one bash call that piped a multi-line Python edit through
`python - <<'PYEOF'` and, in the same line, ran `powershell -NoProfile -ExecutionPolicy Bypass -File
dev-scripts/stage-release.ps1` — "PowerShell hidden sub-execution", a heuristic on the shape of the
command (a shell spawning a bypassing PowerShell inside a long, heavily quoted payload), not on any
file. Nothing ran; nothing was quarantined; the user allowed it after checking the affected item was
the command line. **Fix:** the same edit written to a scratchpad `.py` and run by path passed at once.
**Rule:** edit scripts live in files; `.ps1` scripts run from the PowerShell tool; inline bash stays
short. The agent's own memory carries the same rule. [RULE: checklists/before-a-scripted-edit.md]


## A fuzz target that exercises nothing passes exactly like one that exercises everything (2026-09-03)

**Symptom:** none, for as long as the bug existed. `FuzzEverything` was green in every campaign, in
every `go test`, and under the race job at `-count=3`. It was found by reading the `-v` log while
adding a seed, not by a failure.

**Cause:** the target picks its op with `b&0x1F`, so a step byte reaching `fuzzEverythingClip` has
its low five bits pinned to `file.valid`'s index. That function then read nine clip-header keys out
of the whole byte as though all eight bits were free — and `speed` came from `(b>>1)&0x07`, which is
bits 3..1, every one of them pinned. It therefore always selected the string `"fast"`, the loader
always refused the header with `line 1 is not a replay header`, and **playback-from-a-file had never
once run** in the target that exists to fuzz it. A deliberate 2s recorded gap sitting in that
function, written to produce a seam, had never executed either. Replays only ever started via
`ctl.replayLast`/`ctl.saveLast` on a real recording, which is why the target still looked busy in
its logs.

**The general shape, which is the transferable part:** a generator whose output is silently rejected
downstream produces a target that passes for the wrong reason. Absence of a crash proves the input
was handled; it never proves the input was the one you meant. This is the fuzzing form of "it ran
without errors is not evidence", and of an instrument that logs only its success path.

**Fix:** eight bits of pretend entropy replaced by eight deliberate shapes off the three bits that
are actually free, five of which the loader must accept and three it must refuse. The count and the
split are pinned by `TestFuzzEverythingClipShapesAreWhatTheyClaim`, which also asserts the
cheap-seam shape carries exactly one forced seam and spans milliseconds rather than seconds. Commit
`b7205acb`.

**Rule:** when a fuzz generator builds a structured input, assert the SHAPE it produces, not just
that nothing crashed — and check at least once that the thing downstream actually accepted it.
[CHECK: core.TestFuzzEverythingClipShapesAreWhatTheyClaim]

## A discriminator built on the wrong direction labelled every ghost as the player (Pseudoregalia, 2026-09-04)

**Symptom:** an audio census written to separate a ghost's sounds from the player's reported
`owner=PLAYER` on every event, and its `GHOSTCOUNT` never left 0 — while the adapter's own log was
refusing camera switches to ghost rigs in the same seconds, so ghosts plainly existed.

**Cause:** the probe asked each pawn for a `Controller` and called a pawn holding one the player,
on the reasoning that the auto-possess fix leaves a ghost unpossessed. **It does not: a ghost here
reads as possessed.** Every ghost therefore passed the test, and the attribution column — the whole
output of the instrument — was wrong in a way that looked entirely plausible.

**What caught it** was not the wrong-looking data; it was the coverage line, which prints the
evidence the tag was decided from (`pawns=[...=PLAYER(possessed) ...=PLAYER(possessed)]`). Two
pawns both claiming to be the player is visibly impossible, where a column of `owner=PLAYER` is
not. This is what `checklists/before-trusting-a-reading.md` means by "a probe that returns a
boolean cannot be sanity-checked".

**Fix:** reverse the direction. Ask the ONE controller which pawn it drives
(`AcknowledgedPawn`/`Pawn`), and treat everything else of that class as a ghost or a corpse the
transition has not collected. One authority beats a per-object guess, and the coverage line still
prints what it decided from.

**Rule:** when a discriminator rests on a property being absent, verify the absence on this build
before believing the tag — and print the evidence beside the verdict, every time.
[RULE: checklists/before-trusting-a-reading.md]

## A probe that throws reads exactly like a game doing nothing (Pseudoregalia, 2026-09-04)

**Symptom:** a hot-reloaded probe went silent mid-session. The game was running, the reload had
been confirmed in `UE4SS.log`, and the log simply stopped carrying that probe's lines — which is
the same picture as a quiet subsystem.

**Cause:** a `string.format("%.0f", …)` on a value that was not a number. The helper checked for
`nil` and not for TYPE, a reflected field handed it a wrapper, and the error propagated out of the
sample function into `ExecuteInGameThread`, killing the loop for the rest of the session. Four
minutes of a live session were spent believing the game had gone quiet.

**Fix:** the sample body runs under `pcall` and reports the first failure ONCE before continuing,
and every formatter type-checks rather than nil-checks. An instrument may return `"?"`; it may
never raise.

**The sibling, same session:** `prop()` reports a read as *resolved* whenever the read itself
succeeds — but the controller's listener-override fields each returned a fresh UObject wrapper at
a different address every sample. A value that changes every 200ms is the tell that a reflected
read is handing back a wrapper rather than a value, and "resolved" is not "worked".

**Rule:** a probe's failure must be LOUD and non-fatal. Wrap the sample, report once, keep
sampling — silence is a reading, and it must never be one your own instrument caused.
[RULE: checklists/before-a-probe.md]

## A corrective SECOND call must run in the POST hook, and rewriting the argument beats both (Pseudoregalia, 2026-09-04)

**Symptom:** a fix that was right in substance failed intermittently. The user: *"works sometimes,
had one time where it didn't work"* on one case, and *"still losing sfx when i cross zones"* on
another — the same fix, two different-looking outcomes.

**Cause:** the correction was made from a **PRE** hook. A pre-hook runs BEFORE the engine's own
call, so the corrective write was applied and then immediately overwritten by the very call it was
answering. The only thing that ever healed anything was a 5Hz poll arriving behind the steal — and
that made the outcome depend on where the poll happened to fall: a plain despawn recovered most
times, and a zone crossing never did, because there the poll had already spent its one shot on that
ghost's arrival before the theft happened.

**Two fixes, and the second is better:**

- **Move the corrective call to the POST hook.** Deterministic, and it is what the user confirmed.
- **Do not make a second call at all — rewrite the argument in the PRE hook.** The engine's own
  call then uses the corrected value, so there is no ordering to get wrong, no re-entrancy guard,
  and no window. This is what shipped, and it is the same shape this adapter already uses for the
  camera fight-back and the PlayerLocation guard.

**Rule:** when answering a call you do not own, prefer changing what that call DOES to racing it
with a second call. If a second call is unavoidable, it goes in the POST hook — and note that an
intermittent result from a correct-looking fix is a timing signature, not a flaky game.
[RULE: checklists/before-spawning-in-unreal.md]

## An ordinary edit can rewrite a file's LINE ENDINGS, and every gate reads clean (2026-09-07)

**Symptom.** A one-word `sed -i` change to a *comment* in `dev-scripts/run-core.bat` produced a
one-line content diff, a green tree and a green preflight — and stored the file as LF where it had
been CRLF. It kept running here, because `core.autocrlf=true` re-smudges the working copy to CRLF
on checkout, so the only place the change existed was the blob everyone else clones.

**Why it mattered on that file specifically.** `run-core.bat:34-35` is where the requirement is
recorded: *"This file MUST keep CRLF line endings. cmd.exe mis-parses labels and `goto` in an
LF-only .bat, and the first draft ran straight past its own argument validation and launched a core
with an empty `-game`."* Two more tracked `.bat` files use `goto` — `run-gotests.bat` and
`run-gotests-race.bat`, both `go test ... || goto :failed` — and both were **already** LF. A label
that failed to resolve there would let a failing suite fall through to "All Go checks passed".

**What was and was not demonstrated, because the difference decides how much to trust the story.**
The silent flip is proven. The cmd.exe breakage is *not* — a minimal LF `.bat` with a bare `goto`,
and a second with a multi-line parenthesised `if`, both behaved identically to their CRLF twins on
this machine. The 2026-08-25 observation stands as what was seen then; it did not reproduce here.
**Guard the flip anyway**: it is the half that goes unnoticed either way, and a property that
depends on which machine checks the tree out is not a property.

**Cause.** Nothing enforced it. `.gitattributes` had rules for `*.go`, `*.sh`, `*.cs`, `go.mod`,
`.githooks/*` and two `README.txt` globs, and none for `*.bat` — so the endings lived in whichever
bytes happened to be in each blob. 17 of 22 tracked `.bat` files were already LF.

**Fix.** `*.bat text eol=crlf`, which makes the answer the same on every machine (5 blobs
renormalised, all 22 now check out CRLF). Plus a preflight section, `CRLF-pinned batch files`,
which checks the **attribute** first and the bytes second — bytes here say nothing about what a
Linux runner or a `core.autocrlf=false` clone gets. The attribute half runs under `-TreeOnly`, so
`docs.yml` enforces it. Both halves were deliberately broken once to prove they can fail.

**The transferable rule.** *A line-ending requirement recorded only in a comment is not enforced.*
This repo had already learned it once — `.gitattributes:57-59` says the release READMEs' endings
"used to survive on the raw bytes in the blob rather than on a rule, which held only until
something rewrote one" — and `.bat` was simply left out of the fix. When a file's format matters,
pin it where the tooling reads, not where a human does.

## "A file is not there" is a filesystem answer to a HISTORY question (2026-09-07)

**Symptom.** A survey pass reported two documentation references as pointing at files that never
existed. Both were wrong in the same way: the files *had* existed at exactly the cited paths.
`packaging/release/games/client-config-template.json` lived there until `0c4bf08f`, and each game's
`client-config-overrides.json` was **renamed** into `packaging/config-overrides/<game>.json` by
`6dd8c2ef` (git renders it as a pure rename, zero changed lines).

**Why it matters more than a wrong bug report.** The two possible repairs are opposite. If a path
was never real, the sentence is wrong and gets rewritten. If it was real on the day it was written,
a **dated record is correct as written** and only a *living* doc needs the new path — which is
exactly how it played out: ADR 0040's citation was accurate for its date and was left alone, while
`scaling.md`'s copy of the same claim was the actual error. Treating absence-now as never-existed
would have rewritten a decision record to say something that did not happen.

**The check, before calling any reference dead:**

```
git log --diff-filter=A --all -- '<path>'      # when did it appear?
git log --diff-filter=D --all -- '<path>'      # when did it go, if it did?
git show --stat <that commit>                  # deleted, or RENAMED?
```

**The transferable rule.** *`ls` cannot answer "was this ever true?"* Anything about a path's
history is a `git log` question, and a rename looks exactly like a deletion to every tool that only
sees the working tree.

## A MEASUREMENT THAT CAN READ BACK YOUR OWN WRITE IS NOT A MEASUREMENT -- an address "learned" at frame 2 was our own stranded write (Emerald, 2026-09-12)

**Symptom.** A patched build was asked to discover an address it could not derive — this build's
`Task_AnimateDoor` — by watching its own engine and reading the `func` of any task recognisable as
a door. Two builds "learned" one at **frame 2**, instantly and confidently, and the value was
exactly `vanilla + romOffset`: the number the broken previous version had been *writing into that
table*. The learner was reading back the adapter's own stranded writes and reporting them as the
engine's.

**Cause.** "Read the engine" was implemented as "read the table", and the table is shared. Nothing
in the reading distinguished a task the game created from a task we created, so the instrument's
input included its own output.

**Fix, and the general shape.** Require an EDGE, not a state: learn only from a task that was **not
there on a previous frame** — one we watched arrive. A stranded write is always already present, so
it can never satisfy an arrival, and the false answer disappeared while the true one (measured the
moment the player opened a door) came back completely different: `+0x9A0` and `+0x670`, against
data shifts of `+0x7530` and `+0x6408`.

**Reach for this whenever a discovery routine reads a structure the code also writes** — a task
table, an object array, a sprite slot, a save block. The tell is a reading that arrives *sooner and
cleaner than the thing it measures could have happened*. Frame 2 is not when a player opens a door.
Sibling of the rule one level up in `CLAUDE.md` — *never log the value you just wrote as proof it
worked* — which this is the discovery-time form of: there, you re-read your own write; here, you
*search* and find it.

## LOG THE PASS, NOT ONLY THE FAILURE -- silence meant "verified good" and "never ran", and three fixes aimed at the wrong build (Emerald, 2026-09-12)

**Symptom.** One build of four could not animate a ghost's door. Its address tables were checked at
load by a routine that logged **only when the check failed**, and it logged nothing — so its log
was read three reload cycles running as "tables are fine, look elsewhere", and three fixes were
aimed elsewhere. The check had in fact never run: it was lazy, and nothing had yet asked it.

**Cause.** A one-sided diagnostic. "No line" covered *"verified good"*, *"never evaluated"* and
*"evaluated but not reached"*, and the one build in question was in the third state.

**Fix.** Log the verdict either way, with the addresses it resolved, and resolve eagerly rather
than on first use. The next reading said `DOOR tables OK ... off=641912` on every build including
that one — which immediately moved the search to what was left, and found `gTasks` relocated.

**The general rule: a diagnostic whose quiet state is ambiguous is worse than no diagnostic**,
because it is read as evidence. Either print both outcomes, or make absence impossible by running
the check eagerly. Costs one line per load. The same session then paid for it twice over — a lazy
locator meant "where is this build's map grid?" could only be answered by asking the user to walk
through a door so a log could be read. **A reading that costs nothing should never cost a round
trip through the user.**

## A GATE THAT DISTINGUISHES BY ORIGIN MUST LIVE WHERE THE ORIGIN IS STILL KNOWN -- a relay-id check in shared code would have deleted every replay ghost (core, 2026-09-12)

**Symptom.** The third adversarial review found that a hostile relay could mint a `player_id` in
this core's OWN namespace — `chaser:1`, `replay:whatever` — and land its states in the buffer the
local chaser feeds, rendering cosmetic and exempt from the stale age-out. The obvious fix is a
shape gate refusing those prefixes, and the obvious home for it is `storeRemoteState`, which every
inbound sample passes through. Written that way it builds, and the new regression test passes.

It also silently deletes replays and chasers entirely. `feedLocalPeer` routes this core's own
ghosts through the same function, under exactly the prefixes the gate refuses. Caught by running
the existing replay/chaser tests before committing — nothing shipped.

**Cause.** The gate distinguished by **origin**, not by value: "relay-supplied" versus "minted by
us". `storeRemoteState` is where those two origins *converge*, and past that point the value alone
cannot say which it was — a `chaser:1` from a hostile relay and a `chaser:1` from our own pack are
byte-identical. The property the gate existed to refuse was the property the other caller depends
on being allowed. Both are correct; they point opposite ways.

**Fix.** The gate went to the three relay-facing doors instead — the welcome roster, the join arm
and the state arm — where the caller still knows the value came off a socket. `storeRemoteState`
now carries a comment saying why it is deliberately NOT there, because the next reader will
otherwise "notice the gap" and close it.

**The general rule: origin is a property of the CALLER, not of the value, so a check that turns on
origin belongs at the boundary and nowhere downstream of it.** Before adding any refusal to an
existing function, enumerate its callers and ask which of them must NOT be refused — a refusal
applies to every caller, including the ones whose whole identity is the thing being refused. The
"defence in depth, put it where everything passes" instinct is right for a bound on SIZE or SHAPE
that no legitimate caller can exceed, and wrong for anything that encodes trust.

**And the sub-lesson, which is the part that nearly let it through:** a call-site sweep had already
been done that session — for a different finding, on the relay's emit paths — and the confidence
from it was carried into this fix without re-sweeping. **A sweep done for finding X does not cover
fix Y.** The scope of a sweep is the question it was asked, not the session it happened in.

## A BOUND IS MEASURED THE WAY THE PARTY THAT MUST SATISFY IT MEASURES IT -- and a SAMPLE COUNT is not a memory bound at all (core, 2026-09-12)

**Symptom.** Two shapes of the same mistake, found in one pass, which is what makes it a rule
rather than two entries.

The first is the repeat, and a repeat promotes: `relay/states.go` bounded `area_id` and `anim` with
`len()` and then re-encoded the state with `encoding/json`, which escapes `&`, `<` and `>` to six
bytes each -- and `prev` carries its own copy of both. Measured: a 1185-byte inbound line that
`ValidateState` accepts left `forwardState` at **6305 bytes**, against a receiver cap of 4095. Not a
reject: `bufio.ErrTooLong` in every OTHER member's read loop, so one sender drops the whole room's
ghosts. The world plane had the identical defect fixed on 2026-09-08 (`ValidOpaqueStringOnWire`),
applied there to `World.Authority`/`Key` and to nothing else.

The second is the same error in a different unit. `core/replay.go` budgeted a clip and an archive in
SAMPLES, sized on "128 bytes each on 64-bit" -- true of the `{}` line that figure was measured
against and of nothing else. Measured 2026-09-12 by holding 20,000 decoded samples and reading
`HeapAlloc` either side:

    {}                      2 B line ->    126 B/sample ->  0.23 GB at 2,000,000
    timestamp + position   40 B line ->    160 B/sample ->  0.30 GB
    ~90 flat extras keys  926 B line ->  4,129 B/sample ->  7.69 GB
    extras nested 5 deep  596 B line -> 21,896 B/sample -> 40.78 GB
    near-maximal, flat  1,644 B line ->  4,849 B/sample ->  9.03 GB

**Cause.** A bound was written in the unit that was convenient to the code holding it, not the unit
the cost is actually spent in.

**Fix.** Ask who has to satisfy the bound, and measure it their way.

- A **forwarder** measures what it will WRITE. `relay/states.go` now applies the same
  drop-prev-then-drop-state ladder `core/sending.go` already used, on the marshalled bytes, before
  `recordState` -- so a line nobody can receive is never stored and re-served to a joiner either.
- A **terminal receiver** measures what it was HANDED. This is the part that is easy to get wrong in
  the other direction: after two forwarding bugs the instinct is to reach for `JSONWireLen`
  everywhere, and `ValidateLeaseState`/`ValidateEscrowState` deliberately do not. The core is
  terminal for those, the wire form was already bounded by the line cap on the way in, and a
  receiver stricter than its sender drops legitimate traffic -- the inverse defect, equally silent.
- A **memory budget** measures memory. The replay budgets now charge a per-sample cost estimated
  from the DECODED value, walking containers and entries, because **the line length is not a usable
  proxy**: the worst row above is the SMALLEST of the big lines. 596 bytes of nested extras cost
  36.7x their length; 1,644 bytes of flat ones cost 2.9x. A budget counting input bytes would have
  passed the 40 GB case and refused the 9 GB one.

**Reach for this first when** a constant's comment justifies its value with an arithmetic ("N of
these at M bytes is X MB"). Check the M. It was measured against something, and the something is
usually the smallest legal value rather than the largest.

## A GUARD ITS SIBLING HAS AND THIS ONE DOES NOT IS THE HIGHEST-YIELD THING TO GREP FOR (core/relay/protocol, 2026-09-12)

**Symptom.** Eleven of the roughly twenty-five defects fixed in one review pass were the same
structural shape, and several of them had a comment a few lines away describing the rule they were
breaking:

- `validPrev` applied every bound `ValidateState` applies except the timestamp one -- while its own
  doc comment promised "every bound the carrying state must meet".
- `handleOnlineMessage` forwarded four opt-in planes with no capability check while every matching
  SEND path gated.
- `lease_state` and `escrow_state` had no receive validator while `event`, `state` and `world_state`
  each had one.
- The input ring had a COUNT bound and a span bound; the state ring beside it had only the span --
  and `maxInputRingEdges`' own comment states the lesson and NAMES the state ring as the buffer that
  only got half of it.
- The input ring was disarmed at bridge teardown; the state ring one line away was not.
- A Welcome's peer ids got `acceptableRelayPeerID`; the id naming THIS client was assigned verbatim.
- `maxMissedEventsPerMember` picked its value from "a section that could fill the 192-line snapshot
  would push the escrow, world and lease lines off the end" -- and the escrow section had no cap.

**Cause.** A guard is written for the site that motivated it. Nothing walks the other sites of the
same kind, so the second, third and fourth get it only if whoever wrote them happened to look.

**Fix, as a method rather than a patch.** Build the roster before hunting: grep `func Validate*`,
`func Valid*`, `Clamp*`, `Sanitize*`, `Max*` consts, and every `len(...) >` comparison. Then for
each one ask "what ELSE is of this kind, and does it go through this?". The pairs that pay:

    send path            vs   receive path
    wire path            vs   file path
    one plane            vs   its twin
    a struct's field     vs   the same field inside its delta/nested type
    a buffer             vs   the buffer declared beside it
    admission            vs   teardown
    an id we are given   vs   an id we are given about ourselves

**Reach for this first when** a fix is finished. Before closing it, ask what else has that shape --
the answer is rarely nothing, and finding it costs one grep against the cost of the next review pass
finding it instead.

## AN EVICTION ORDERED BY AGE IS ORDERED BY WHATEVER A THIRD PARTY CONTROLS (relay, 2026-09-12)

**Symptom.** Three separate bounded structures in one package chose their victim by age alone, and
in all three the age is something an uninvolved member drives:

- A terminal escrow record is retained so a party who dropped between the relay committing and the
  message arriving can resume and be told the outcome. The per-member cap counts LIVE exchanges
  only, so somebody uninvolved could open-and-abort in a loop and push out an older record -- and
  the record most likely to go is exactly a committed one that has been waiting a while. That party
  resumes and is told nothing: "both or neither" holds on the relay's side and is broken from
  theirs, which is the uncertainty the plane exists to remove.
- A suspended member's event backlog is 64 slots, oldest-out. A broadcast reaches every backlog, so
  64 of them push out the ADDRESSED events underneath -- the half aimed at that member, and the half
  a conversation is made of.
- The escrow section of a resume snapshot had no cap, and a client does not choose how many
  exchanges it is a party to: anyone can open one naming it as the counterparty.

**Cause.** "Oldest first" is the right rule when age correlates with irrelevance. It stops being
that the moment an attacker can manufacture youth.

**Fix.** Order by what the entry is FOR, then by age within that class:

- Escrow eviction: anything no suspended party is still waiting on goes first, oldest of those; only
  if every terminal record is owed does the oldest of THOSE go. The converse needs its own test --
  a table where everything is owed must still evict, or a full table refuses new exchanges forever.
- The backlog: broadcasts before anything addressed to this member.
- The resume section: live exchanges before terminal ones, capped at a quarter of the budget, which
  is the number the sibling section already uses.

**Reach for this first when** you see `.Before(oldest)` or `q[1:]` in anything bounded. Ask who
decides the age of the entries, and whether that is the same person the bound is protecting.

## A LIVE-RELOADED SETTING IS A WRITE PRIMITIVE FOR ANYTHING THAT CAN WRITE THE FILE -- and holding it back at the point of USE is half a fix (cmd/meshghost, 2026-09-12)

**Symptom.** `meshghost.exe` re-reads `config.json` about a second after a save, and that included
`connect_to`, `room` and `room_code` -- so anything else on the machine able to write that file
could move a live session onto a relay of its choosing, mid-play, with nothing on screen saying so.

**The argument for leaving it, which was put to the user and rejected:** a process that can write
your config can equally kill the core and start its own, so locking it buys almost nothing. That
is true and it is not enough. **It argues that one hole is no worse than another, not that this one
should stay open**, and what it protected was a convenience with a cheap substitute (a relaunch)
rather than a capability. The user's call, 2026-09-12: *"its nice to live edit toggles/hotkeys/names
etc, but ip/adress and/or room related stuffs probly don't make sense to have as live editable"*.

**The half that was nearly shipped broken, which is the reusable part.** Holding the three keys back
where they are USED left the gate holding for exactly one save. `configWatcher.reload` replaces
"what is live" with what it just read -- so the file's relay address landed there anyway, and the
NEXT save of any other key at all (a name, a colour) would have rejoined carrying it, because the
rejoin builds its Hello from that same "what is live". The fix has two halves: refuse the value at
the point of use, AND stop it becoming the baseline the next diff is measured against.

`cmd/meshghost/reload_test.go` therefore pins the SECOND save, not the first. A test of the first
save passes against the broken version.

**Reach for this first when** anything is excluded from a reload. Ask what the excluded value does
to the state the next reload diffs against -- an exclusion that leaks into the baseline is not an
exclusion, it is a delay.

## A TARGET'S SEEDS ARE A CLAIM ABOUT WHAT IT REACHES, AND COVERAGE IS HOW YOU CHECK IT (netx/udpconn, bridge, core, 2026-09-12)

**Symptom.** Twenty-seven fuzz targets, every one registered, stepped in CI, listed in the roster,
running green. Four of them reached nothing worth reaching:

- `FuzzListenerSurvivesArbitraryDatagrams` never completed a handshake, and
  `udpconn.Listener.handle` routes every application frame through `l.lookup`. So
  `Conn.handleControl` -- the constant-time token compare, the `seqLen` bound, the reorder window,
  the ack path -- was at **0.0%** for the whole campaign, while NINE of that target's own seeds were
  written for exactly that code.
- `bridge`'s two targets `json.Unmarshal` into plain structs with no custom `UnmarshalJSON` and
  marshal back. Between them they campaign `encoding/json` and no line of `bridge`.
- `ValidateInputSample` was the reverse: used as the ORACLE in another package's target -- the thing
  a parser's output is checked AGAINST -- and always on a batch of exactly one hand-built edge, so
  it ran constantly and its edge cap, its within-batch ordering and its whole header half never ran
  at all.
- Nothing anywhere pushed arbitrary bytes into the two sockets the CORE reads from, though five
  findings in that same pass were about what the core does with a line the relay chose.

**Cause.** Every one of these is invisible to the checks that exist. The fuzz census gate added
earlier in the same pass asks "is this target registered, stepped and rostered", and all four
answered yes. A green campaign proves no input broke anything it reached; it says nothing about
what it reached. And a seed corpus is written by whoever believed the target reached that code --
so the seeds are the strongest evidence of the belief and no evidence at all of the fact.

**Fix, as a method.** `go test ./pkg -run FuzzName -count=1 -coverprofile=x` then
`go tool cover -func=x` on the functions the target is FOR. It restricts to that one target's seed
corpus, takes seconds, and answers the question directly: `handleControl 0.0%` is not a claim
anyone has to be talked into. Do it before extending a target and after fixing one -- the number
either moved or the fix was cosmetic (here: 0.0% to 89.7%, `sendAck` 0 to 100%, and the live corpus
grew 55 to 71 because there was somewhere new to go).

**Reach for this first when** a target has seeds naming a code path, when a target's assertion never
fires, or when a review says a surface is unfuzzed and the roster says otherwise. The two are not in
conflict: a target can exist, run, and reach nothing.

## THE ASSERTION ANYONE WOULD WRITE FIRST CAN PASS AGAINST THE BROKEN CODE (netx, 2026-09-12)

**Symptom.** `transport.CloseGracefully` asserts for `CloseWrite` and silently degrades to a hard
close without it -- which neither datagram transport had. The obvious test is
"after `CloseGracefully`, does the message written just before it still arrive?", because that is
what the method exists for. It passes on all three transports **against the unfixed code**: on
loopback the single udp datagram is not lost, and quic's `closeLinger` covers its own case by
another route. Only "does the peer's next line still get READ during the drain" fails, and it fails
on both.

**Cause.** The visible half of a two-part promise is the half that gets tested, and it is often the
half that another mechanism accidentally covers. `CloseGracefully` promises two things -- stop
writing, keep reading -- and the second is invisible from outside unless you have a peer that is
still talking.

**A second shape of the same trap, from the same day.** A test written for the fix's own
vocabulary cannot fail against the old tree: `netx/udpconn/halfclose_test.go` names `CloseWrite`, so
without the fix it does not compile rather than failing. That is not a regression test, it is a
compile check wearing one. When it happens, say so and point at the test that CAN fail -- here the
conformance one, which asks only for behaviour.

**Fix, as a method.** For any promise with more than one clause, write the assertion for the clause
nobody would notice was broken, and confirm it red before the fix. Then ask of the obvious
assertion: *what would have to also be true for this to pass anyway?* Loopback not dropping a
packet, a linger timer, a retry elsewhere -- each is a reason the green light means nothing.

**Reach for this first when** a fix lands and its test was green on the first run against the old
code. That is the tell, and the correct response is to find the other clause rather than to be
pleased.

## A FULL RING THAT COPIES DOWN IS O(n) PER ADD, AND CI'S TEN-MINUTE LIMIT IS WHERE IT SHOWED (core, 2026-09-15)

**Symptom.** CI's race job timed out the whole `core` package at Go's default ten-minute `go test`
limit (run 35015767091; 528s the run before, when the package still passed). The goroutine dump
named no hung test -- the one listed was 0s in -- so the package was simply too slow, not stuck.
Locally, `go test -race -count=1 ./core` ranked the tests: two of 403 took 52 of 127 seconds, both
"the ring is bounded by count" tests that feed 205,000 samples into a 200,000-slot ring.

**Cause.** Both `sampleRing.add` and `inputRing.add` dropped their expired prefix with
`copy(r.buf, r.buf[drop:])`. A full ring drops about one sample per add, so every add moved every
live sample down one slot: 200,000 moves per sample at the cap, and in a game the whole live buffer
memmoved once per frame while `replay.save_last` (on by default, 30s) is armed. The comment beside
the copy said a reslice "keeps the whole backing array alive and growing for as long as the ring is
on" -- wrong: `append` grows from the slice's LENGTH, so the shrunk capacity runs out within a
quarter-ring of adds and the next allocation drops the dead prefix.

**Fix.** `r.buf = r.buf[drop:]`, O(1). `core/ringcost_test.go` pins it as a ratio against the same
ring's fill in the same run (a full add may cost at most 100x a filling add; the copy-down was
about 5,000x), plus a `cap(r.buf) <= 2*cap` bound so the reslice cannot leak its prefix. Windows'
half-millisecond clock read a few hundred adds as 0s, which is why the baseline is the 200,000-add
fill and not a handful of empty adds. Core under `-race` went 129s -> 79s locally.

**Reach for this first when** a package's total time creeps toward the limit with no hung test in
the dump: rank the tests with `-json`, and read the top one's inner loop for a per-item cost that
scales with the container.

## A SCANNER VERDICT IS PER FILE: ONE ZERO IS LUCK, AND THE SAME SOURCE WITH A NEW COMMIT IS A NEW SAMPLE (release, 2026-09-22)

**Symptom.** Chasing antivirus false positives on the shipped exes, four builds of the same source
went to VirusTotal in one evening: the two untrimmed ones drew Microsoft's `!ml` verdict, the
stripped one drew Bkav and Elastic, and an unstripped build with `-trimpath` scored 0/70. A tidy
story wrote itself (Microsoft follows the embedded home-directory paths, Bkav and Elastic follow
stripping), the release flags were changed on it, v1.3.1 was cut, and its CI-built exes scored 1/70
and 2/71 -- Microsoft on both. A local rebuild differing from the 0/70 file only in the git revision
Go embeds in the build info scored 1/70 too.

**Cause.** A machine-learning verdict is a guess about one file, not a rule about the code. Two
files that differ by a few bytes no scanner reasons about landed on opposite sides of its threshold.
Reading one clean result as "the flag fixed it" was the same mistake as closing an intermittent
fault on one good run: the evidence was one sample of a per-sample process. The story looked
strong because every one of the four files fit it, and four files is nothing against a coin.

**What held up, and only once counted BY ENGINE across every upload.** Elastic: on both stripped
files, none of seven unstripped. Bkav: both stripped, one of seven unstripped clients, two of two
servers. Microsoft: six of seven clients and both servers, following nothing. So the flag change
was kept for what it did (Elastic, and Bkav on the client), the 0/70 claim was withdrawn from the
release text, and Defender was recorded as unreachable from the build. The table is in
`security-design.md`'s code-signing section.

**Reach for this first when** a verdict, benchmark or flake is a per-run or per-file thing: get
several samples of the SAME shape before naming a cause (a rebuild after any commit is a new
sample for free), tally by category rather than by total, and hold the release text until the
shipped artefact, not the local one, has been measured.
