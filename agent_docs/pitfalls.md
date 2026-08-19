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

## A symptom word can name more than one subsystem — confirm which before probing

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

## Gating a handshake on its own result (deadlock, twice in one day)

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

### BizHawk Lua: `event.onframeend` outlives its script; use a `frameadvance` loop

- **Symptom** (found live 2026-08-18, Crystal): the Lua Console showed the script red and
  `1 script (0 active, 0 paused)`, while the script **kept running and spamming the console**.
  Start and stop both did nothing. Each reload made it worse.
- **Cause**: a callback registered with `event.onframeend` is owned by the emulator, not by the
  script that registered it. Stopping the script does not unregister it, so it keeps firing, and
  every reload stacks another copy on top. The UI is reporting the *script's* state honestly — it
  really is inactive; the leftover callback is what you are still seeing.
- **Fix**: drive the script with an explicit loop instead, so it dies when the script does:

  ```lua
  local function tick() ... end
  while true do
      tick()
      emu.frameadvance()
  end
  ```

- **This was already the house style and got missed.** The shipped Emerald adapter
  (`meshghost_emerald.lua`) has always used `while true do ... emu.frameadvance() end`; four new
  Crystal scripts were written with `event.onframeend` without checking the existing one first.
  **Read the working adapter before writing a new script for the same host.**
- **Two related traps in the same shape:**
  - **`event.onexit` must be registered BEFORE the loop**, since the loop never returns. Easy to
    get backwards when converting from a callback.
  - **Nothing inside `onexit` may throw.** Memory domains are not guaranteed valid while the
    emulator tears down, and an error there is one way to reach the wedged state above. Wrap the
    whole handler body in `pcall`.
- **Recovery when it happens**: restarting EmuHawk is the reliable way to clear stacked callbacks.

### BizHawk Lua: `debug.getinfo` gives no path — use the working directory

- **Symptom** (found live 2026-08-18, Crystal): a script that resolves its own folder from
  `debug.getinfo(1, "S").source` gets `"main"`, not `"@C:\...\script.lua"`. Every path built from it
  is wrong — the vendored LuaSocket DLL is not found, and the script's log file is written somewhere
  unexpected, which is *worse*, because the failure then has no record.
- **Cause**: BizHawk loads the script such that `source` is a chunk name rather than a file path.
- **Fix**: **the working directory IS the script's directory** when BizHawk loads a Lua file —
  confirmed live, `cd` returned the adapter's own folder. So `io.popen("cd")` is the *primary*
  answer here, not a fallback:

  ```lua
  local p = io.popen("cd")           -- Windows; prints the working directory
  local dir = p:read("*l"); p:close()
  ```

- **The shipped Emerald adapter already had this**, as a `pwd` fallback in its own `scriptDir()`.
  Writing a new BizHawk script without reading it cost a failed run and a round trip — the same
  lesson as the `event.onframeend` entry above, from the same session.
- **Expect this to recur on other emulator adapters.** "Where am I on disk" is a *host* question,
  not a game one, and an emulator's Lua host has no obligation to answer it the way a standalone
  interpreter does. Any adapter that loads a vendored binary or writes a log beside itself needs a
  path that does not depend on the host being generous. See `adapters/_template/README.md`'s
  "read the working adapter for the same host before writing a new script".

### Spawned actors auto-possessing (taking control away from the player)

- **Symptom**: spawning a second copy of the player's own controllable Blueprint (e.g.
  `BP_PlayerGoatMain_C` in Pseudoregalia) silently swapped `PlayerController.Pawn` to the new
  actor. The player was physically dragged around (and once, killed) as ghost-follow logic
  moved what it believed was an inert placeholder.
  - **Probe**: an isolate-by-subtraction script that spawned with the same guards but
    performed zero repositioning, logging only object addresses and `controller.Pawn` each
    tick — confirmed `controller.Pawn == ghost` immediately after spawn.
  - **Cause**: the spawned class auto-possesses on spawn (`AutoPossessPlayer` or equivalent).
  - **Fix (first version, superseded)**: capture the original pawn/controller *before*
    spawning, and call `controller:Possess(originalPawn)` immediately after every spawn —
    including subsequent ghosts, not just the first (the bug recurred identically when a second
    ghost was added without re-possessing). Still what the Lua probe scripts do.
  - **Fix (current in the shipping C++ mod, 2026-08-16): stop the clone taking the controller at
    all, rather than taking it back afterwards.** `POSSESS_TRACE` bracketing a spawn showed the
    controller holding the local pawn before, the ghost immediately after, and the local pawn
    again after the hand-back — so every spawn was putting the player through an
    unpossess/re-possess cycle, and re-possessing restores the pawn without necessarily
    restoring whatever input the game bound to it. `AutoPossessPlayer` is a stock `APawn`
    UPROPERTY read *during* spawn, so it is cleared on the pawn class's **class default object**
    before `SpawnActor` and restored immediately after — the whole window is one synchronous
    call on the game thread. Setting it on the instance afterwards is already too late.
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
  - **Fix (first version, since DELETED — do not rebuild it)**: a post-hook that captured the
    "last known good" target and re-forced it whenever a later call moved away from it while a
    ghost existed. That "block every change forever" shape was itself found to be the thing
    taking the camera, and was removed 2026-08-16. **This is the dangerous kind of fix**: it
    worked on the case it was written for and broke every legitimate camera switch.
  - **Fix (current, 2026-08-16)**: a `RegisterPreHook` on
    `/Script/Engine.PlayerController:SetViewTargetWithBlend` that identifies *whose* camera rig
    is being switched to and refuses **only** a rig owned by one of our own ghosts. A ghost is a
    clone of the player pawn, so it brings its own `BP_PlayerCam_C`; the engine's `Owner` reads
    `(none)` on every one of those rigs, but the Blueprint carries its own `OwningActor` property
    pointing at the pawn it serves, and that pointer compared against the tracked ghosts is the
    precise test. A narrow "a few ticks after our own spawn" window survives only as a fallback
    for a rig that resolves no owner at all. Everything else — cutscenes, area rigs, the game's
    own routine switching — passes through untouched. See `register_camera_fightback_hook`
    (`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`), which keeps the old name.
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

### UE4SS C++ mod threading -- on_update() is not the game thread (2026-08-13)

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
  return isn't checked against the full length. Found in `adapters/bizhawk/pokemon/emerald/
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

### Vendored RE-UE4SS SDK marshals `FRotator` as `float` regardless of engine version (UE5 games) (2026-08-13)

*Facts about the SDK below are as of the pinned submodule commit on that date — `licensing.md`'s
RE-UE4SS entry records the pin. Re-check before relying on them after a pin bump.*

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

### UFunction hooks work on native functions but CRASH on Blueprint functions (RE-UE4SS) (2026-08-15)

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
- **Fix**: don't hook Blueprint functions on this build. The feature first fell back to polling
  `actionState` each tick and edge-detecting it — less accurate (it can't distinguish a real slide
  from a quick turn-around that shares the same state value) but stable. That was then replaced by
  a physical fact, the capsule shrinking 65→22, because the enums overlap between moves and the
  shrink doesn't. **Both are superseded as of 2026-08-16**: the trigger is now the game's own
  observed afterimage spawns (`AFTERIMAGE_TRIGGER_FROM_OBSERVATION`), which is the only version
  that stops the ghost trailing on a mistimed move. See `agent_docs/effect-investigation.md`.
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

### Actor destroy unavailable on the ghost pawn — move offscreen, let the level's own teardown reclaim it

- **Symptom**: `K2_DestroyActor()` on the ghost pawn silently no-ops on this Pseudoregalia
  build — no crash, no error, the actor call simply doesn't remove the object. Earlier attempts
  to destroy ghosts through other means caused world-leak crashes.
- **Scope correction (2026-08-17 audit)**: this is a property of *that actor*, not of the build.
  The ghost pawn came from the hijack design, so it was never ours and its class reflected no
  usable `K2_DestroyActor`. An actor we spawn ourselves, of a class whose live function dump does
  list it, destroys fine — `Plugin.cpp`'s `call_destroy_actor` does exactly that for the
  thrown-weapon prop, and falls back to parking when the reflection isn't there. Read the
  "permanent constraint" below as permanent for the ghost pawn only.
- **Reversed since (recorded 2026-08-18)**: it is not a constraint at all any more.
  `GHOST_DESTROY_ON_DESPAWN` is `true` in `Plugin.cpp`, so a `despawn_remote` **destroys** the
  ghost; parking is now the *fallback* for when the destroy reflection isn't available, not the
  design. The bullet below is kept because its reasoning is still the right shape for a build where
  destroy really is unreliable — read it as history, not as current behaviour, and note that its
  accepted cost (a frozen offscreen ghost until the next area transition) no longer applies.
- **Original design note, superseded — ghosts were never destroyed.** On
  `despawn_remote`, `Plugin.cpp`'s `release_ghost` moved the ghost far offscreen via the
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
  throttled trace logging in both the Lua adapter and `core` at every hop
  (send → relay forward → roster → receive → store) — proved the entire Go pipeline was
  correct: one core (`p1`) really was sending state, the relay really was forwarding it, and
  the *other* core (`p2`) really was receiving and storing it. The bug wasn't in any of that.
  - **Actual cause**: the second BizHawk instance was launched by double-clicking `EmuHawk.exe`
    directly, rather than through a wrapper that sets `MESHGHOST_BRIDGE_PORT=7779` first. The
    Lua adapter (`meshghost_emerald.lua:134`) reads that env var and silently falls back to 7778
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
  - **Fix, originally procedural**: a per-machine, gitignored `.local.bat` launcher for
    each instance that sets `MESHGHOST_BRIDGE_PORT` before launching `EmuHawk.exe`, so this
    can't be silently skipped by launching the executable directly. See
    `dev-scripts/README.md`.
  - **Now a code fix too (2026-08-18)**: both Pokémon adapters walk the bridge port.
    `meshghost_emerald.lua` and `meshghost_crystal.lua` probe `BRIDGE_BASE_PORT` (7778) upward
    across `BRIDGE_PORT_COUNT` (8) and accept only a core that answers `bridge_ready`, so a second
    instance launched by double-clicking now finds its own core instead of sharing the first one's.
    **Not yet watched live.** TEVI still connects to a single fixed port and keeps the procedural
    fix above.
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

### `cmd` itself resolves to a devkitPro document, not an interpreter (2026-08-17)

- **Symptom**: `cmd /c "dev-scripts\build-pseudoregalia.bat"` from PowerShell failed instantly
  with `Cannot run a document in the middle of a pipeline:
  c:\devkitPro\msys2\usr\bin\cmd`. Nothing to do with the build, which was fine.
- **Actual cause**: devkitPro's MSYS2 ships a `cmd` **with no extension** — a text file, not
  `cmd.exe`. It sits earlier on `PATH` than `C:\Windows\System32`, so `cmd` resolves to a
  document PowerShell then refuses to execute. The third instance of this same MSYS2 install
  shadowing something, after `cmake` (2026-08-13) and `git.exe` (above, 2026-08-15).
- **Why it is worth its own entry**: the other two resolved to a *real tool of the wrong
  version or config*, so they failed plausibly and late — a fake `CMAKE_GENERATOR` error, a
  fake 15,000-line diff. This one is not a wrong tool at all, and the error names a category
  (`a document`) rather than a path problem, so it does not read as a `PATH` issue on first
  sight. **The tell is the error naming a file with no extension under `devkitPro`.**
- **Fix**: invoke the interpreter absolutely — `& "$env:ComSpec" /c "..."` from PowerShell.
  Prefer that over bare `cmd` for anything scripted, since the shadow is machine-wide and
  permanent.
- **Generalizes to**: on a machine with a toolchain bundle on `PATH` (devkitPro, MSYS2,
  Cygwin, Git-for-Windows), assume **any** common command name may be shadowed — including
  ones that feel too fundamental to check. Resolve interpreters by absolute path in scripts.

### The diagnostics were the bug: probes that broke the effect they measured (2026-08-16)

**The most serious regression this project has had, and the first to require comparing commits to
diagnose.** Read this one before adding any probe to an adapter.

**Context worth keeping**: this did not happen in isolation — every probe involved was added while
chasing Pseudoregalia's ultra-hop BLUE trail, and the bisection came out of that same effort. The
blue looked like a small cosmetic feature and instead reached into the whole afterimage system:
what makes a burst fire, how the engine pools the images, and how many the ghost draws. Three
separate entries below (this one, the pooling pair, and the latch) are all from that one
investigation. The transferable warning is about the *shape* of the work, not the feature: a change
that appears to be one property on one object, but sits on top of a system nobody has fully
characterised, will keep turning into that system's other problems.

- **Symptom**: the ghost's afterimage trail went intermittently sparse or missing. Sometimes a
  slide produced a full trail, sometimes almost none, with no pattern the user could pin down.
- **Why it survived four rounds of measurement**: every instrument reported *exact parity* between
  the real player and the ghost — spawn count (32 vs 32, later 40 vs 40), burst spacing (18-21
  ticks each side), position in X and Z (identical, correct loopback offset), opacity and fade
  curve (the ghost's marginally *higher*), and colour. All of it was true and all of it was
  irrelevant: **every image that survived was correct, and only the destroyed ones were missing.**
  A counter cannot see an object that never existed.
- **Cause — two of this session's own probes, both left enabled while judging the trail:**
  1. `AFTERIMAGE_DISCOVERY` called the game's own spawn function on the ghost every ~3 seconds. A
     probe that *creates* the same kind of object it is measuring is contaminating by construction.
  2. `TRAIL_COLOR_TRACE` plus a 3-tick (~50Hz) scan added a second `FindAllOf`, a
     `GetFullName()`/UTF-8 conversion and several name-keyed property lookups **per object per
     scan**, against a pool that grows past 80, all on the **game thread**. The game spawns
     afterimages as a countdown *across ticks*, so stalling that thread truncates bursts in flight.
- **The wrong turn that cost the most**: an A/B set `AFTERIMAGE_TRIGGER_OBSERVED = false` and
  concluded "the trigger revamp is innocent". It was not — only the counter increment *inside* the
  scan was gated by that flag, so the expensive enumeration ran regardless. **A flag flip is not a
  revert.** The conclusion drawn from it was wrong and sent the investigation further astray.
- **What actually found it**: the user asked to check out the session-start commit and compare.
  `8d10f67` (session start) good → `46c4d2c` good → `760b148` intermittent → `861e6cd` broken.
  **Three builds**, after hours of measurement had produced only false parity.
- **Fix**: heavy per-object tracing off; scan cadence 3 → 15 ticks; and structurally, the scan is
  now gated by the flag that owns it, so that flag is a real off-switch. Confirmed live by the user
  afterwards: dense repeating slide trail, ghost within 1-2 images of the real player.
  (**Cadence note, 2026-08-16**: that 15 is `AFTERIMAGE_COLOR_SCAN_INTERVAL_TICKS`, which now
  belongs to the disabled `AFTERIMAGE_TRIGGER_OBSERVED` path. The live cost knobs are
  `AFTERIMAGE_OBSERVE_SCAN_INTERVAL_TICKS = 6` and an idle scan at 10 — tune those, not the 15.)
- **Generalizes to** — the rules extracted from this are in `## Diagnostic methodology` above, but
  the short form: audit a probe's cost before trusting its output; never leave a spawning probe
  enabled while judging what it spawns; re-test with probes off; a flag flip is not a revert; and
  bisect real commits early rather than reasoning about a regression.
- **One durable consequence**: any measurement taken while one of these probes was live is
  retroactively suspect. The entries below that cite figures from those captures say so explicitly
  rather than being quietly trusted.
- Source: this session's `UE4SS.log` captures, the bisect above, and commit `83f30c1` for the fix.

### Pooled objects: detecting "spawned" by object identity silently undercounts (2026-08-16)

- **Symptom**: a ghost's afterimage trail was visibly thinner than the real player's, while every
  measurement said the two matched — identical counts (32 vs 32), identical spacing between spawns
  (18-21 ticks each side), identical positions modulo the loopback offset.
- **Confirmed finding**: the engine **pools** afterimage actors. They are re-used and never
  destroyed, so a spawn detector keyed on "an object name I have not seen before" fires while the
  pool is growing and then goes quiet. Established by a lifetime probe that produced **zero
  samples**: it only logged an entry when an image disappeared, and across 122 tracked afterimages
  not one ever did. The empty result was the finding — objects that never die are pooled objects.
- **NOT the cause of the symptom — the real cause was the probes themselves** (see the entry
  directly above). Counting re-use as a spawn was implemented on the strength of the pooling
  finding and then **reverted**: a census showed the ghost had produced roughly *twice* as many
  afterimages as the real player (27 vs 54 at one sample) while still looking thinner. The pooling
  discovery was sound; the fix built on it was wrong, because nobody had yet established that
  spawn count was the shortfall at all. It was not — the trail was being truncated by the
  instrumentation.
- **Which is the lesson worth keeping**: a correct, well-evidenced finding about a *mechanism* does
  not make it the *cause* of the symptom in front of you. "Pooling is real" and "pooling explains
  this bug" are separate claims needing separate evidence.
- **A probe returning nothing is data.** The instinct is to assume it is broken and widen it. Ask
  first what a genuine zero would mean — here "no object ever disappeared" *was* the finding, and
  an earlier run of the same probe had already hinted at pooling before that hint was talked away
  because a different number kept rising.
- **Generalizes to**: particles, projectiles, decals, damage numbers, audio emitters — anything an
  engine recycles for performance. Before building a spawn counter on object identity, check
  whether the objects ever actually disappear. Note that detecting pooling is useful for
  *understanding* an effect even when, as here, it is not what needs fixing.

### Latch event payloads to the event; don't republish them as per-tick state (2026-08-16)

> **Read with the caveat that this entry was written mid-investigation.** Its ratios were measured
> through the probes later found to be corrupting the trail (see "The diagnostics were the bug"),
> so treat the *numbers* as indicative rather than exact. The shape lesson below is independent of
> them and still holds. The colour path it describes was disabled along with the scan it rode on,
> and was **re-enabled 2026-08-16 as a separate, colour-only path** (`AFTERIMAGE_OBSERVE_COLOR`):
> ownership is a pointer compare rather than a name match, and it runs once per burst instead of on
> a cadence. **Confirmed on screen the same day** — `verified.md`'s blue-afterimage entry.

- **Symptom**: a peer's ultra-hop afterimage was blue, the ghost's was blue only sometimes. Ratios
  across four attempts: 2→1, 8→4, 10→4, then an over-correction to 6→98.
- **Diagnosis, in the order it was actually established** — worth reading as a sequence, because
  three of the four attempts were aimed at the wrong stage:
  1. Detection was never at fault. Instrumenting each stage separately showed every blue image was
     observed and correctly chosen (10 observed, 10 chosen). Only 4 arrived.
  2. The real cause was one line: the pawn's baseline colour was read **into the member that gets
     serialized, every tick**, while the observed colour was updated only every few ticks. So on
     most ticks the outgoing packet carried the baseline regardless of what had been observed, and
     the lower-rate send sampled whichever tick it happened to land on.
  3. The fix that finally worked was not another timer but **deleting** the timers: the counter and
     its colour describe one event, so they are written together and nothing touches the colour
     afterwards. Whenever the send samples, it sees the payload belonging to the latest event.
- **The shape to recognise**: a monotonic counter survives a lossy, low-rate send precisely because
  it is never recomputed. Any payload that travels *with* that counter needs the same property. If
  the payload is recomputed from live state each tick, the counter is exact and its payload is a
  lottery — and the two disagreeing is invisible in the code, because both fields look equally
  "synced" at the call site.
- **The meta-lesson, which cost the most here**: three fixes were added in sequence — a tie-break,
  then a hold window, then a second hold window — each patching the previous one's shortfall. That
  escalation was itself the signal that the shape was wrong. **When you are adding a second timer
  to protect a value from being overwritten, stop and remove the thing overwriting it instead.**
  The over-correction (6 real blues becoming 98) is what layered heuristics look like when they
  finally interact; the correct version has no window to size and no race to lose.
- **Generalizes to**: any adapter sending event-plus-payload over a lossy, rate-limited channel —
  a hit type with a hit counter, a colour or asset with a spawn counter, a sound id with a footstep
  counter. Latch the payload where the event is detected, and let nothing else write it.

### Sampling a multi-tick spawn once attributes its stragglers to the NEXT event (2026-08-16)

- **Symptom**: the ultra hop's blue trail reached the ghost correctly, but appeared on the first
  afterimage of the *next slide* rather than on the ultra itself. Consistently one burst late.
- **Diagnosis**: the observation scanned once, at a fixed delay after the burst fired. But the game
  spawns a burst as a countdown **across many ticks** — the log showed `new=1` against a burst size
  of `n=5`, so the single scan saw only the leading image. The other four appeared afterwards, and
  since "new" was defined as "an object this scan had not seen before", they were first sighted by
  the *following* burst's scan and counted as its own. A late blue image then won that burst's
  colour tie-break.
- **Why it was hard to see from the code**: the detection, the tie-break, the latch, the send and
  the ghost-side write were all individually correct, and each had been separately confirmed. The
  defect was entirely in *which event* a correctly-read value was filed under. Both bursts looked
  equally well-synced at every call site.
- **Fix**: observe across a window covering the whole spawn rather than at one instant; accumulate
  the tie-break over the burst; emit the wire event once the burst's full count has been seen or the
  window expires; reset the per-burst accumulators at burst start.
- **Generalizes to**: any engine effect that produces its objects over several frames — particle
  bursts, projectile volleys, multi-hit attacks, footstep clusters. **A first sighting is not a
  creation time.** If the producer runs across N ticks and the observer samples at one tick, the
  remainder does not vanish; it silently reappears attributed to whatever samples next. Before
  keying anything on "objects I have not seen before", ask how long the thing being observed takes
  to finish producing them, and cover that span. Note this is a distinct failure from the pooling
  entry above: pooling makes re-used objects look old, this makes late objects look new, and a
  detector can suffer both at once.

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
  The single-object version of this code had been correct since the ghost was first spawned
  (2026-08-13); adding a companion object two days later silently broke it.

### Cross-adapter issues that were fixed in the core, not the adapter

Found while building an adapter, but the fix belonged in `core` — listed here so the
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

### A guard that checks "did I get an answer" instead of "is the answer usable" (2026-08-18)

- **Symptom**: the Crystal adapter failed to find its vendored LuaSocket from four candidate paths
  and refused to start — but only when loaded indirectly, through a four-line wrapper that sets a
  bridge port and `dofile`s it. Loaded directly, the same file worked.
- **Diagnosis**: `scriptDir()` prefers `debug.getinfo().source` and falls back to the working
  directory. The fallback exists because BizHawk reports an empty source when a script is opened
  directly — so the guard asked "did I get a path?". Under `dofile`, source is `@./meshghost_crystal.lua`:
  a path, and a **relative** one. The guard passed, the pwd fallback was skipped, and `"."` was
  returned. That is fine for `io.open` and fatal for `package.loadlib` — Windows resolves a
  relative DLL path against the **process** directory (BizHawk's), never the working directory, so
  `./../emerald/lib/x64/` cannot resolve even with the folder sitting right there.
- **Fix**: require the property actually needed. The guard now accepts the source-derived directory
  only if it is absolute (`^%a:` or a leading slash) and otherwise falls through to pwd, which is
  the answer BizHawk gives reliably.
- **The general shape, and why it recurred the same day it was first hit**: a guard written from
  one observed failure tends to encode *that* failure ("source was empty") rather than the
  requirement ("I need an absolute directory"). Every other way of being unusable then walks
  straight through it. When writing a guard, state the requirement, not the incident.

### A patched build's WRAM shift is NON-UNIFORM, and being right most of the time is the trap (2026-08-18)

- **Symptom**: on an Archipelago-patched Crystal ROM, addresses derived from vanilla by a known
  delta returned plausible numbers and were wrong. The first derivation (four consecutive bytes
  from AP's published `wMapGroup`) produced a repeating cycle of "steps" a player cannot walk, and
  a later one pointed `wMapObjects` at `struct_id=255, sprite=0, y=255` noise.
- **Diagnosis**: the patch does not slide WRAM by one amount. Measured on the same build, same
  session:

  | address | delta from vanilla |
  | --- | --- |
  | `wBGMapOffsetX` / `wBGMapOffsetY` | **+7** |
  | `wMapStatus` | **+7** |
  | `wMapGroup` / `wMapNumber` / `wYCoord` / `wXCoord` | **+7** |
  | `wObjectStructs` | **+6** |
  | `wMapObjects` | **−0x2A** |

  **Seven of the nine measured addresses are +7 — which is precisely what makes it dangerous.** A
  rule that is right most of the time gets trusted, and the case where it is wrong looks exactly
  like the cases where it is right: a plausible number, no crash, no error. Shipping +7 blindly
  would have produced a working-looking adapter reading a garbage object table 42 bytes away, in
  the *opposite* direction, which no amount of +7 reasoning ever reaches.
- **A published address table is not a shortcut either.** AP publishes `wMapGroup = 7359`; measured,
  7359 is the X coordinate, three past where the name implied. The layout was intact and the LABEL
  was wrong, which is a failure mode a sanity check on "is this a plausible map group?" passes
  happily.
- **Fix, and the rule worth carrying to any patched build**: a delta may choose which address to
  *test* next, and may never supply the value you *ship*. Both are legitimate — pointing a probe at
  vanilla+7 first costs nothing and is right often — but an address enters the table only after it
  was measured on the build in front of you. In this adapter that is enforced structurally: an
  unmeasured entry is `nil`, a `nil` refuses to run, and the refusal names what is missing. See
  `ADDRESSES` in `adapters/bizhawk/pokemon/crystal/meshghost_crystal.lua` and the method in
  `adapters/_template/probes.md`.
- **A byte can pass every still-life test and fail the moment the game moves.** `0x0FB1` was the
  single survivor of two four-snapshot state runs for `wMapStatus`: 2 in the overworld on four
  maps, 0 in both battles, across two independent sessions. It is not `wMapStatus`. With the gate
  reading it, the gate closed several times a second while the player simply stood in the
  overworld — the byte flickers 2/1, and **all eight snapshots agreed with each other because all
  eight were taken standing still**, which is the one condition the probe itself asked for. The
  real one, `0x1439`, held 2 across 1103 samples of continuous walking. Sample a candidate while
  the game is in motion before believing a static agreement, however many times it repeated.
- **Attribute an effect to what was OBSERVED, not to the instruction you gave the human.** The
  scroll-offset probe scored each byte by the phase it asked the player to walk ("now go
  left/right"), reported that both candidates "move on both axes", and was wrong: the player had
  drifted a tile sideways at the start of the up/down phase, as anyone would. Re-scoring the same
  log against the coordinate that actually changed made it unanimous — 70/70 and 67/67. The
  instruction is an intention; only the game state is evidence.
- **Corroboration is not derivation.** `0x1154` is a fine candidate for `wBGMapOffsetY` *because a
  probe found it on its own merits* and it then also happens to sit at vanilla+7. The same address
  reached by starting from +7 would be a guess wearing evidence's clothes.

## Cross-game comparison

Recurring adapter tasks, and how differently each engine/game has answered them so far:

| Task | Pokemon Emerald (GBA, BizHawk/Lua) | Pseudoregalia (UE5, UE4SS/C++) | TEVI (Unity/Mono) |
| --- | --- | --- | --- |
| Represent the remote player visually | 2D overlay sprite drawn every frame (`gui.*`) | Spawned/duplicated 3D actor | World-space `GameObject` with `SpriteRenderer` |
| Drive an animation | N/A (2D overlay) | Two layers: continuous poses mirror via state properties (`moveState`/`actionState`), one-shot animations via a **montage mirror** — send whatever `AnimMontage` the peer plays, call stock `Montage_Play` on the ghost's anim instance (2026-08-15, `verified.md`). The game's own `CustomPlayMontage` wrapper silently no-ops on a ghost | Send the real clip name (`GetAnimationTrueName()`) and let the engine's own `Animator` play it |
| Avoid drawing over menus/UI | Explicit gate on the overworld callback state (`gui.drawImage` is a raw overlay) | Not yet needed the same way | Not needed — a world-space object under the game's own camera naturally renders under UI layers |
| Survive area/level/scene transitions | Re-read relocatable pointers every frame; debounce reads for one frame around a detected map change | Re-acquire pawn/camera references after transition; treat cached "last known good" state as invalidated, not fatal | Recreate the ghost lazily after scene unload rather than trying to preserve it across the transition |
| Version/build stability | Real drift risk, not immune: a ROM patch (Archipelago's base recompile) relocates addresses relative to a byte-identical-verified vanilla build — found live for `gObjectEvents`/`gPlayerAvatar`, `CB2_Overworld`, and sprite/palette data, each a separate offset; each patch version needs its own live-detected offsets, see `verified.md`'s Archipelago-relocation entries | Build-specific: reflection availability and rendering-on-spawn behavior are tied to the exact installed engine/mod-loader build | Steam can auto-update the game; also blocks two simultaneous instances (confirmed by testing, not assumed) |

### Pooling cuts both ways: a retirement move reads as a birth (2026-08-16)

- **Symptom**: the ghost showed two blue afterimages on an ultra hop where the real player showed
  one. Every other colour behaviour was correct by then.
- **Diagnosis, settled by one field in a log line**: the detector treated "this image moved" as "this
  image is newly spawned", because these actors are pooled and never destroyed. Logging the actor
  POINTER showed both detections carrying the **identical** pointer, ~60 ticks (~400ms, about one
  fade lifetime) apart, across all eight ultras in the capture. One image, counted twice — once when
  spawned and again when the pool reclaimed and moved it.
- **This is the exact inverse of the pooling entry above**, and they were live in the same detector
  at the same time: re-use makes an object look OLD (undercount), retirement makes it look NEW
  (overcount). Guarding one end does nothing for the other, so a pooled-object detector needs both.
- **Fix**: use a property of a real birth that a retirement cannot fake. An afterimage is a snapshot
  of the player, so it is born at the player's position; anything appearing far away is the pool
  moving something. The threshold is derived from how far the player can move between scans (~100
  units worst case, so 400 gives a 4x margin) rather than picked, and the log reports both the
  furthest mover seen and the rejection count so it can be checked instead of trusted.
- **The transferable part**: `counts` could never have settled this — "the game spawned two" and
  "one was counted twice" produce identical numbers. **Identity did, immediately.** When a count is
  suspect and the objects are pooled, log the pointer before theorising about the count.
- **And the user's own reading was the right instinct with the wrong mechanism**: they proposed
  subtracting one, having noticed the ghost consistently ran 1-2 images ahead. That would have
  masked this rather than fixed it, and broken every case where the count was legitimately right —
  but the observation that something systematically over-produced is what pointed at the detector.

## A Gold/Silver GameShark code run on Crystal writes into the object RAM MeshGhost spawns into

**Symptom (predicted, not yet suffered — recorded before it costs a session):** ghosts misbehave,
flicker, move on their own or vanish, shortly after a cheat is switched on for testing. Nothing in
the adapter changed, and the adapter looks like the culprit.

**Cause.** GB/GBC GameShark codes are `01 DD AA AA` — write value `DD` to address `AAAA`, stored
byte-swapped, with no encryption at all. Published Crystal code lists routinely give **two**
variants per effect and label the pair as one cheat, e.g. "Have All Badges: `01FF7CD5` / `01FF7DD5`
/ `91FF57D8` / `91FF58D8`". Those are not four lines of one code. Decoded against our own
hash-verified `pokecrystal` build:

| Code | Address | Symbol |
| --- | --- | --- |
| `91FF57D8` | `0xD857` | `wBadges` |
| `91FF58D8` | `0xD858` | `wKantoBadges` |
| `91018DD8` | `0xD88D` | inside `wTMsHMs` (`0xD859`, 50 TMs then 7 HMs, so HM03 = Surf) |
| `91XX93D8` | `0xD893` | `wItems` |
| `01FF7CD5` | `0xD57C` | **`wObject4Palette`** |
| `01FF7DD5` | `0xD57D` | **`wObject4Walking`** |
| `01XXB8D5` | `0xD5B8` | **`wObject5SpriteYOffset`** |

**The `91` variants are the Crystal codes and are correct. The `01` variants are the Gold/Silver
codes, and on Crystal they land squarely in `wObjectStructs`** — the exact array the Crystal
adapter spawns ghosts into. A tester who pastes "all four lines" gets a cheat that works (from the
`91` half) *and* silently scribbles on our object structs (from the `01` half), which presents as a
MeshGhost bug with a perfect alibi: the cheat did what it promised.

**Fix / rule.** For Crystal, use **only** the `91` codes. Any code list is untrusted input: decode
it (`01/91 DD AAAA`, byte-swapped) and look the address up in `pokecrystal.sym` before running it —
that is a ten-second check against an authoritative source we already build. If an address lands in
`wObjectStructs` (`0xD4D6`) or `wMapObjects`, it is the wrong game's code.

**Generalises.** The same "published lists mix two games' codes without saying so" shape applies to
any game with a close sibling release. The defence is not caution, it is the decode-and-look-it-up
step, which is cheap and mechanical.

## BizHawk accepts a GBA cheat code it cannot decrypt, and silently activates the garbage

**Symptom, seen live 2026-08-18.** `client.addcheat("F89BD08B ED8D449E")` returned without error,
and the Cheats dialog then showed **`2 cheats 2 active`** — with the code decoded to
**address `0000000E`, value `8B`, size Byte**. GBA EWRAM starts at `0x02000000`, so that is not an
address in the machine at all: BizHawk had not decrypted the code, it had parsed the hex.

**Two separate traps, and the second is the dangerous one:**

1. **"Accepted" is not "decoded".** `client.addcheat`'s own doc string says it adds a code *"if
   supported"*, and a `pcall` returning `true` only means the Lua call did not throw. Of six codes
   added, the four CodeBreaker-format ones (8+4 digits, e.g. `83000E48 1ED2`) were dropped
   silently — this build has a `GbaGameSharkDecoder` and no CodeBreaker decoder.
2. **A mis-decoded code is not inert — it is ACTIVE.** Two codes became live per-frame writes of
   an arbitrary byte to an arbitrary low address. Anything odd afterwards would have been blamed
   on the adapter, with the cheat sitting quietly in a dialog nobody had open.

**Rule.** Never conclude a cheat worked from the API's return value. Read the Cheats dialog and
check the decoded **address** is plausible for the machine (`0x02……`/`0x03……` on GBA), then remove
what you added. `dev-scripts/bizhawk-cheat-clear.lua` exists for exactly that.

**What to do instead on GBA.** Emerald's popular codes are GameShark v3 / CodeBreaker, both
encrypted and neither usable here — and the ones that look decodable often are not verifiable
either: `82005274 0YYY` resolves to `gHeap + 0x5274`, an unnamed heap offset whose meaning depends
on what is allocated at that moment, which is why such codes come with "enable one at a time, then
switch it off". Prefer writing the real structure through `gSaveBlock1Ptr`, whose offsets are in
the decomp and can be checked: key items at `+0x5D8`, badge flags at `+0x1270`. Contrast Crystal,
whose GameShark codes are unencrypted and land on named symbols — see the entry above.

## A spawned character renders a few pixels off its tile, forever

**Symptom.** A ghost sits slightly down/right of the grid the game itself snaps to. Its collision
is on the correct tile and it moves correctly — only the picture is offset, and the offset never
corrects itself. **Seen on both BizHawk adapters**: Crystal first, then Emerald 2026-08-18, where
the user recognised it immediately as "same issue as crystal had".

**Cause.** A spawned object's screen position is computed **once**, at spawn or teleport, from the
engine's own map-coords-to-screen formula. From then on the engine only applies camera *deltas* to
that sprite. So any error in the initial value is permanent — and the formula is **only exact when
the camera is at rest**. Place a ghost while the camera is mid-scroll (i.e. while the player is
part-way through a step) and the sub-tile remainder is baked into the sprite for its whole life.

**Fix.** Place only on a settled camera. In Emerald that is `gFieldCamera.x == 0 and
gFieldCamera.y == 0`, checked before both spawning and teleporting; if it is moving, skip the
frame and try the next one. The camera settles constantly, so the wait is invisible — and unlike
nudging the sprite by a few pixels afterwards, it fixes the cause.

**It came back on Crystal on 2026-08-19, because only Emerald ever got the check.** This entry
already said "seen on both adapters", and the fix was written down here — but Crystal's adapter
was never given the equivalent predicate, so the same bug was reported again by the user, this
time only when walking OUT of a building: leaving one drops the player into a scripted step out
of the doorway, so a ghost spawned there is placed mid-scroll, while walking in happens with the
world already at rest. Crystal's predicate is `wBGMapOffsetX % 16 == 0 and wBGMapOffsetY % 16 ==
0`, measured rather than assumed: a transition probe logged every object's real screen coordinate
beside what the adapter's formula computed for it, frame by frame across a map load, and the two
agree exactly on those boundaries and disagree by the sub-tile remainder off them. **The
transferable lesson is not about cameras** — it is that a pitfall recorded here is not a pitfall
fixed, and a lesson learned on one adapter has to be back-ported to its siblings deliberately
(`CLAUDE.md`'s `_template/` rule says the same thing about the template).

**The wrong fix, which is tempting and is a bandage.** Adding a compensating pixel offset to the
computed position. It "works" for the case in front of you, encodes one particular sub-tile
remainder as if it were a constant, and breaks the moment the ghost is placed at a different point
in the scroll cycle. If a correction like that ever ships, it belongs in the adapter's
`BANDAGES.md` — but the settled-camera check is available and is not a compensation.

**Generalises to any engine where a spawned entity's screen position is set once and then driven
by deltas.** The question to ask at the point of placement is not "is this value right?" but "is
the *state I am computing it from* at rest?".

## A spawned entity leaks once per zone crossing, but survives doors fine

**Symptom.** Ghosts pile up along a route as the player walks back and forth between two areas —
one left behind per crossing — while entering and leaving buildings behaves perfectly. Seen in
Emerald 2026-08-18, five deep in a screenshot.

**Cause.** The adapter identified its ghost partly by "the object's map matches the current map".
A **warp** (house, elevator) rebuilds the world: the engine clears every object, so the check
correctly reports death and a fresh spawn follows. A **connection** (route to route) changes the
map identity **without** clearing anything, so the same check reports a live ghost as dead — the
record is dropped, a replacement spawns, and the original stays active and untracked.

**Why it matters more than it looks.** Ghosts are solid. Leaked ones accumulate into a wall, so a
cosmetic-looking leak becomes "this route is now impassable".

**Fix.** Identify the entity by something the engine cannot forge and that does not mention
location — Emerald uses active + not-the-player + `localId == LOCALID_PLAYER` — and add a periodic
sweep that clears anything wearing that marker which the adapter is not tracking. Full reasoning
and the general form: `adapters/_template/README.md`, "The map changed and the world was rebuilt
are different events".

**The trap for testing:** each failure hides in the case the other one exercises. Passing a
door/elevator test says nothing about a seamless boundary, and vice versa. Test both, deliberately.

## A menu's contents are not fixed, and neither is its cursor

**Two separate assumptions, both wrong, both found scripting Emerald's bag on 2026-08-18.**

**The cursor is remembered between openings.** The first attempt pressed `Start` then `A`,
expecting the first entry — and got **EXIT**, because an earlier run had left the cursor at the
bottom. A menu opened twice in a session does not start where it started the first time. Drive it
to a known end (hold one direction past the end of the list) and count from there, or verify with a
screenshot before committing to a press.

**The ENTRIES themselves change with game progress.** The user, on seeing the sequence:

> *"menu's can sometimes include more/less things, similar to how a new save don't have your
> pokemon/badge view for example... don't assume its 'always the same'"*

The save being tested opens `BAG / <name> / SAVE / OPTION / EXIT` — no POKéDEX and no POKéMON,
because neither has been obtained yet. A later save has both, so **every index below them shifts by
two**. A sequence of button presses tuned against one save silently selects the wrong thing on
another, and "wrong thing" can be SAVE.

**So a scripted menu route is save-specific unless it is written defensively:** navigate to an
extreme rather than counting from an assumed top, screenshot at each step while developing it, and
treat the resulting sequence as valid for the save it was written against.

**And the action can be refused for reasons that have nothing to do with the menu.** The sequence
above reached `SUPER ROD -> USE` correctly and the game answered *"DAD's advice... there's a time
and place for everything"*. That is Emerald's generic **"you cannot use that HERE"** — the user:
*"whenever a thing is not usable in that specific location... for example trying to fish without
water, or riding a bike indoors"*. It is a **location/context** refusal, not a story gate, and the
first version of this entry guessed it was progress-related, which is exactly the kind of plausible
wrong explanation that outlives the session that wrote it.

**What that message actually tells a probe:** the route was right and the *precondition* was not.
For fishing it means no fishable water in front of the player — which, in this session, meant the
tile edit had not produced what it was assumed to produce. Read the game's own words before
adjusting the button sequence; a refusal is a specific answer, not a generic failure.

## An empty log reads exactly like "the game did nothing"

**Symptom.** A probe's log contains its header and one line, or stops growing partway. The obvious
reading — "the thing I am testing did not happen" — is wrong often enough to be dangerous, and it
sends the investigation to the game instead of to the instrument.

**Four causes seen in a single session (2026-08-18), all producing identical output:**

1. **The probe measured too early.** A screenshot fired a frame or two after the loader started it,
   before the adapter had connected — producing three convincing pictures of a game that had no
   ghost in it yet, and a debugging session aimed at a rendering bug that did not exist.
2. **The probe never loaded.** A backslash lost through a shell heredoc left an invalid Lua escape,
   so the file was rejected. Its empty log was read as "fishing produced no data".
3. **The emulator was paused.** BizHawk pauses while any of its own menus or dialogs is open, so
   `emu.frameadvance()` never returns, the dev loader stops polling, and every attached script
   stops ticking. Nothing errors; everything simply stops.
4. **The same misreading, repeated** an hour after (2) had been written up — because the fix was
   documented rather than made habitual.

**The fix, and it is cheap:** before drawing any conclusion from quiet output, get **positive
evidence the instrument is alive** —

- the loader log says `loaded <script>` (not `LOAD FAILED`),
- the log file's size or timestamp is **increasing**,
- a frame counter in the output is **advancing**.

**Never conclude from the absence of a symptom.** A dead probe and a quiet game are
indistinguishable from the outside, so the question is never "did anything happen?" but "is this
thing still running?" — and that has an answer you can check.

## A verification rule that reports clean while the thing it checks is broken (2026-08-18)

**Symptom.** `CLAUDE.md`'s mandated public-repo leak check printed nothing, as it had for days,
while a personal username sat in `master` in a tracked file.

**Diagnosis.** The check was
`git grep -inIF -e 'C:\Users' -e '/home/' …`. `-F` makes it a *literal* match, so it matched a
**backslash** path only. The leak was `dev-scripts/rom-swap-test.lua`'s
`C:/Users/<name>/Downloads/<seed>.gba` — **forward** slashes, because BizHawk Lua wants them.
Committed 2026-08-11 in `03e0a8b`, invisible to the rule the whole time, and it leaked a
username, a home-directory layout, a handle and an Archipelago seed name.

**Fix.** Both slash directions in the check, now
`-e 'C:\Users' -e 'C:/Users' -e '/home/'`, and the file's paths moved to
`MESHGHOST_ROM_VANILLA`/`MESHGHOST_ROM_PATCHED` env vars with its log path derived from
`scriptDir()` (which also fixed a hardcoded `C:/dev/MeshGhost/` in the same file).

**The durable lesson is not "add a slash".** This is the shape `CLAUDE.md` already warns about
elsewhere — *a diagnostic can break the thing it measures, and then every reading agrees with
itself.* A clean run of a check that cannot see the failure mode is worse than no check, because
it is read as evidence. When a rule's whole value is "this prints nothing", prove it can print
something: run it against a known-bad string before trusting a clean result. **This one had
never been shown to fail.** Two of the three found-live cases arrived via pasted tool output;
this third arrived by being typed in a form the rule did not model.

## Third time for the wrong-install-on-PATH trap — and it cost a capability, not just a build (2026-08-18)

**Symptom.** `agent_docs/testing.md` recorded that local `-race` **"does not work on this machine
and is not worth retrying"**, and `dev-scripts/run-gotests-race.bat` existed only to say so
politely. The race detector was treated as CI-only, which is why a relay race on 2026-08-16 had
to be caught by CI after a push.

**Diagnosis.** Two separate wrong conclusions stacked:

1. `gcc` on `PATH` resolves to devkitPro's MSYS2 copy, whose headers cgo cannot use
   (`stddef.h: No such file or directory`). Same trap as `cmake` (2026-08-13) and `cmd`
   (2026-08-17) — **the third instance in this repo.**
2. The real MSYS2 GCC 15.1.0 was then tested, failed with
   `runtime/cgo: cgo.exe: exit status 2`, and was written off as "Go's runtime/cgo doesn't build
   with it". **It builds fine.** Setting `CC` is not enough: cgo shells out to the compiler,
   which shells out to its own `as`/`ld` and reads its own headers, so its `bin` directory has to
   be *ahead of devkitPro's on `PATH`*. `run-gotests-race.bat`'s probe set `CC` only — so every
   candidate compiler failed identically, and the conclusion drawn was "no compiler works"
   rather than "the probe is missing a step".

That second part is exactly `CLAUDE.md`'s rule about **two guessed fixes failing with the
identical symptom being a signal, not bad luck** — two compilers, one symptom, and the common
factor was the harness, not the compilers.

**Fix.** The probe now prepends the candidate's directory to `PATH` before testing it. Verified
end to end 2026-08-18: with the `sess.timer` fix reverted, `-race` reports the race at
`relay/online.go:844`; restored, `go test -race -count=3 ./...` is clean across every package
including `internal/e2e`. Recipe and caveats: `testing.md`'s Race detector section.

**Lesson.** A negative capability finding deserves the same scepticism as a positive one, and it
ages worse: "we can't do X here" gets written into the docs, tooling gets built around the
absence, and nobody re-tests it. Cost here was every race being a push-and-wait round trip for
two days. **Treat "this doesn't work on this machine" as a dated claim, not a property.**

## Inferring what a game is MEANT to do, and "fixing" a non-bug (2026-08-18, TEVI)

**Symptom.** TEVI's peer ghosts stayed visible while the pause overlay was open. Reading
`Plugin.cs` alone, that looks like a leak — the local player is not in gameplay, so why is anyone
else's ghost on screen? A change was proposed to despawn them, which would have been a real visual
regression: peer ghosts staying up during the pause overlay is **wanted** behaviour, and the user
confirmed it as such the same day.

**Cause.** Two failures stacked. First, *intent was inferred from code* — the code says what
happens, never what should happen, and a cosmetic layer's correctness is a design question the
user owns. Second, the word **"menu"** was doing double duty: TEVI has a main menu *and* a pause
overlay, and the despawn path is deliberately gated on only one of them (`player == null`, which
`phases/phase6.md` records the pause overlay does not trigger). One sentence written as "on menu
return" covered two states with opposite required behaviour.

**Fix.** `CLAUDE.md` now carries both halves as a rule: **never assume what a game is meant to do
— ask**, before changing anything the player SEES; and **name the exact state, "main menu", never
bare "menu"**. `Plugin.cs`'s despawn call carries a comment saying which menu it means and what to
suspect first if a future TEVI build ever nulls the player on pause.

**The tell.** You are about to change a *visible* behaviour and your only evidence is what the
source implies. That is the same shape as "it ran without errors" — self-consistent, and untested
against the one person who decides what correct looks like.

## A probe global outlives the probe, and then looks exactly like a real bug (2026-08-19)

**Symptom.** A Crystal ghost looked like the player inside Elm's lab and like an NPC out in the
town. A perfectly plausible bug report — and a completely coherent one, which is what made it
dangerous: sprite 4 really is resident outdoors in New Bark and really is not loaded in the lab,
so the "bug" behaved consistently with a genuine appearance fault every time it was looked at.

**Cause.** A scratch script had set `MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE = 4` as a Lua **global**
for one experiment an hour earlier. **`dev-scripts/bizhawk-dev-loader.lua` swaps SCRIPTS, not the
Lua state** — globals set by a dropped script persist in the emulator for the rest of its life. So
every later run in that emulator was still forcing every peer to `SPRITE_RIVAL`, and the fallback
(wear the local player's sprite when the peer's tiles are not resident) did the rest.

**Fix, both halves.** Clear the global in the session's own setup script rather than assuming a
dropped script took its settings with it — and, more durably, **any flag that changes what is on
screen announces itself in the log on every startup**, which is what `MESHGHOST_CRYSTAL_AP_TRY`
already did and this one now does too (`PROBE FLAG IN USE: ...`). One line in the log the session
is read from is the difference between a five-minute check and a plausible false report.

**Generalises.** `CLAUDE.md` already says a diagnostic can break the thing it measures. This is
its quieter cousin: a diagnostic can keep changing what everyone sees **after it is gone**, and
the reading it corrupts is not the probe's own — it is the next person's.

## Saying "no" once per peer per frame costs more than the work being refused (2026-08-19, Emerald)

**Symptom.** With synthetic peers (`meshghost-fakeadapter`) aimed at the map the player was
standing on, Emerald placed ghosts normally up to the engine's ceiling and then fell apart:
**24 peers dropped the emulator from 60fps to 3, and 36 peers to 1** — measured as frames counted
against the wall clock, not as a feeling. Nothing was wrong with the ghosts that DID spawn; the
game itself was simply unplayable while too many peers were present.

**Diagnosis.** `gObjectEvents` holds 16 entries shared with the map's own NPCs, so a town with the
player plus two NPCs fits exactly 13 ghosts. Every peer past that failed to find a slot — and the
failure path did two expensive things once per unplaceable peer **per frame**: it re-scanned both
the object and sprite arrays, and it called `console.log`, which in BizHawk is a GUI append. At 36
peers that is 23 refusals × 60 frames ≈ 1,400 console writes a second. The adapter was spending the
frame budget announcing that it had nothing to do.

**Fix.** Throttle the message to once per 5 seconds, and record the refusal in `spawnGate` so
`syncGhost` stops attempting spawns for the rest of that frame — the array cannot grow mid-frame,
so the first "full" answer is the answer for every remaining peer. Re-measured: 24 and 36 peers
both hold 59.7-59.8fps with the same 13 ghosts placed.

**The general shape:** a diagnostic on a failure path is priced per failure, and failures scale
with load while successes are capped. Anything that logs unconditionally where the count is
attacker- (or room-) controlled belongs behind a throttle from the start.

## "The game blocked me" was an NPC finishing a sentence (2026-08-19)

**Symptom.** A measurement was abandoned and its absence written into the record as a property of
the game: *"Route 101 is story-blocked"*, offered as the reason a route row was missing from
Emerald's crowd-limit table.

**What actually happened.** An agent driving the game with scripted inputs walked into an NPC who
stopped it and started talking. It read the interruption as a wall, turned around, and reported the
route as unreachable. The user \u2014 who knows the game \u2014 corrected it immediately: that NPC is the
*"please go help"* stop, which says its piece and then lets you walk straight past. The genuinely
blocking version of the same character (*"it's dangerous, you can't go there yet"*) had been
cleared earlier in that save. **The route was one A press away.**

**Why it survived.** The false conclusion was *plausible, self-consistent and untestable from the
inside*: the character really did stop moving, the dialogue really was about not going somewhere,
and an agent with no memory of the save's story state has no way to tell "temporarily interrupting
you" from "permanently refusing you". Nothing failed. It simply stopped, and then explained.

**The rules it violates**, both already in `CLAUDE.md` and both worth pointing at here because this
is what they look like in the wild:

- **Never assume what a game is MEANT to do \u2014 ask.** The person who owns the save knows in one
  sentence what an agent cannot derive in twenty minutes of probing.
- **"I could not get there" is a statement about the driver, not about the game.** Write it that
  way. *"Scripted input did not get past an NPC interaction"* is true and invites the one-line
  correction; *"the route is story-blocked"* is a claim about the game that a reader will believe
  and build on.

**What to do instead.** When a game interrupts a driven run: **press A through it and try again**
before concluding anything \u2014 dialogue is the single most common interruption in these games and
the cheapest thing to clear. If it still will not pass, say what was observed, and ask.

## OPEN (2026-08-19) — Crystal: invisible collisions, and ghosts popping in and out

**Symptom, user-reported while a crowd of stationary ghosts stood around New Bark Town:** walking
into collisions with nothing visible on the tile, and characters appearing and disappearing as the
player walks toward or away from them.

**What is already measured**, from a probe reading both of Crystal's arrays at once:

- **The engine itself keeps a map object without an object struct for distant characters.** With
  no ghosts present at all, the game's own NPCs at distance 5 and 10 read `NO-STRUCT` while the
  one at distance 1 was drawn — and a struct was seen being *re-assigned* as the player moved
  closer. So "a tile is occupied but nothing is drawn on it" is a **normal state in this game**,
  not something MeshGhost invented.

**Two candidate causes, which need different fixes, and the difference matters:**

1. **An off-screen ghost still blocks its tile.** A peer standing just past the screen edge is an
   invisible wall. Arguably the game's own rule, since its NPCs behave identically — but a player
   can *see* an NPC coming and cannot see a peer who is off-screen.
2. **A ghost's struct is culled and re-assigned as the player approaches, and `stillOurs()` reads
   the empty struct as "this slot is no longer ours"** — dropping the record and respawning. That
   would produce exactly the popping described, and it would be **ours**, not the engine's. The
   identity check was added the same day (for the battle case) and was never tested against
   distance-based culling, which is precisely the kind of gap a same-day fix leaves.

**How to tell them apart:** the attached probe logs, per ghost, whether the map object and the
struct each still exist, plus the distance to the player. Cause 2 shows the struct disappearing
while the map object stays, followed by a *new* spawn line in the adapter log. Cause 1 shows both
halves intact throughout, with the player simply walking into a tile off the visible area.

**Not yet reproduced under the probe** — a scripted walk-away could not be driven while a human
was at the controls, and this needs the player to move a screen away and come back.

## A single screenshot cannot see a blinking thing (2026-08-19)

**Symptom.** A picture is taken to answer a question about the screen, and it answers a different
question: *what was on screen during one 60th of a second*.

**The user's example, which is the clearest form of it**: "PRESS START" flashing on a title
screen. Mistime the screenshot and the prompt is absent. The image is sharp, nothing errored, and
the obvious readings — the game is stuck, there is no prompt, the script did not run — are all
wrong.

**Three live cases the same evening, all the same shape:**

- **Crystal's menu rectangle strobes.** `wMenuBorder*` returns to `0,0,0,0` and back several times
  a second *while the menu is plainly on screen*, so a single read says "no menu" about half the
  time. The fix was to latch the last non-zero rectangle while a panel is up.
- **Sprite dropping happens on 2–3% of frames.** With a crowd packed together the Game Boy exceeds
  its 10-sprites-per-scanline limit on roughly one frame in forty. A screenshot would essentially
  never catch it; the user's honest *"kinda hard to tell"* was correct, and it was settled by
  counting sprites per scanline instead of looking.
- **A screenshot loop aliased with the walk cycle.** Firing every 120 frames against a 240-frame
  cycle produced identical pictures, which read as "nothing is moving" while the game moved fine.

**The rule.** Sample across time and report the **range** (`oam=14..38 of 40`), sample longer than
the period you are looking for, and choose an interval that cannot align with it — or trigger on
change rather than on a timer. Full method, with the general form: `adapters/_template/probes.md`,
"One sample cannot see a blinking thing".

**And the corollary for talking to the user**: when they say they cannot tell whether something is
happening, that is a measurement result, not a non-answer. It means the effect sits at the edge of
perception, and the next move is to count it rather than ask them to look again.

## Two things that share a file, and the silence that hides them — 2026-08-19

Both found in one two-instance Emerald session, and they are the same mistake in two places: a
name that is not unique per instance.

- **Symptom.** Lines in `adapters/bizhawk/pokemon/emerald/logs/` mangled mid-write —
  `atus: frame=...` where one write landed inside another.
  **Cause.** The log name resolved only to the second (`meshghost_emerald_%Y%m%d_%H%M%S.log`), and
  two emulators running the same adapter reload in the same second every time a shared control
  file or a restart moves them together. Both then held the same file open.
  **Fix.** The name carries the emulator's process id. A pid cannot collide while both processes
  exist; a bridge port can, and is not even known at the point the log opens (it is walked).
  Back-ported to the Crystal adapter, which had the identical shape.

- **Symptom.** One of four cores did not rejoin after the shared relay was restarted; its adapter
  read `remotes=0` for ten minutes and its log said nothing at all.
  **Cause, and it was not the reconnect loop.** The core had been started in `dev-scripts/`, where
  a `config.json` pointed it at a crowd-test relay on a private port; that relay had exited, and
  the config file had since been deleted, so nothing in the tree explained the port. The retry loop
  ran the whole time — proven by starting a relay on that port and watching it reconnect in 15s —
  but the log line was gated on the error message CHANGING, and a dead address produces a
  byte-identical error forever.
  **Fix.** A still-failing reconnect repeats once a minute with the address and the elapsed time
  (`core/core.go`, `reconnectLogInterval`).
  **The general rule:** *"log it again only if it changed"* is right for a retry that will succeed
  shortly and wrong for one that never will, and the two are indistinguishable at the moment the
  first line is written. Any unbounded retry needs a heartbeat, or it is invisible exactly when it
  matters. Corollary already in `environment.md`, now with a live case: **prefer an explicit
  `-relay` flag to a config file when several sessions share a machine** — a flag is in the
  process list forever, a config file can be deleted and take the explanation with it.

## Crystal: a drawn ghost paints over a FULL-SCREEN menu, because the adapter reads it as a text box

**Symptom** (user, watching vanilla Crystal, 2026-08-19): *"the ghost is being drawn while in the
menu's."* The adapter's own counters denied it — 21-24 peers `hidden by UI` with a menu open — and
the counters were the thing that was wrong, exactly as `CLAUDE.md` says to assume.

**What the counter missed, and why a count can never settle this.** "21 hidden" is perfectly
compatible with "and 33 more painted straight over the panel". A per-peer dump was added
(`MESHGHOST_CRYSTAL_UI_DEBUG`, off by default: the rectangle, the two open-flags, and where each
painted peer actually sat) and it separates three states that the summary line had been blurring
into one:

| On screen | `textBoxOpen()` | `uiPanelOpen()` | `wMenuBorder*` rect | Result |
| --- | --- | --- | --- | --- |
| Overworld, nothing open | false | false | none | everything painted — correct |
| **START menu** (a box on the right) | false | **true** | `l=80 t=0 r=160 b=128` | 35 painted / 9 hidden — the painted ones are all left of the rectangle, i.e. **correct** |
| **Full-screen submenu** (POKéMON, BAG…) | **true** | false | **none** | **31-34 painted / ~11 hidden — the defect** |

**Diagnosis.** A full-screen menu publishes **no** `wMenuBorder*` rectangle, so `uiPanelOpen()` is
false and there is nothing to clip against. What it *does* trip is `textBoxOpen()` — so the adapter
believes a bottom text box is up and protects **only the bottom six rows**. Every peer above screen
row 12 is painted over the menu: the dump shows them at `sy` = -4, 12, 28, 44, 60 and 76, which is
the whole top two-thirds. The loopback self-ghost is in there too (`p258-ghost@64,28`).

**So the top-level START menu was never the broken case, and that is why this was missed** — it was
the only menu tested, it is the one that publishes a rectangle, and it clips correctly.

**The obvious fix is a trap, and the probe proves it.** "Scan every row for the frame corner and
hide everything" fails on measured evidence: `uiframe_probe.lua` logged `bg row=0 col=10
edgerun=8` — the START menu's own box, still sitting in the tilemap — repeatedly during ordinary
walking with `WY` parked at 144, i.e. **frame tiles present with no panel on screen**. Same shape as
the WY-alone heuristic that blanked half the screen earlier that day. The tiles persist; only the
display state says whether anyone can see them.

**The fix, and it is not a third heuristic.** `wStateFlags` bit 0 ("overworld sprite updating
on/off") was tried first and rejected on measurement: it strobes between `01`, `40` and `41` inside
a single unchanging state, exactly like the WY-alone heuristic. What does separate the states
cleanly is the engine's own output — **how many hardware sprite entries are live** (OAM `y` in
1..159), sampled every frame and logged on change:

| On screen | Live OAM entries |
| --- | --- |
| Overworld, walking | 28-34 |
| Text box open (map still behind it) | 30+ |
| START menu (map still behind it) | 28-30 |
| **Full-screen submenu** | **exactly 0** |

So the drawn tier now returns early when **no** sprite is on screen. That follows from what the
tier *is* rather than being bolted on: it paints **alongside** the characters the engine renders,
so if the engine is rendering none, there is nothing to paint alongside — and the anchor this code
calibrates its screen positions against does not exist either, which is precisely why the old
fallback path produced plausible-looking coordinates over a menu.

**Verified numerically, same session**: the per-peer dump produced 31-34 painted peers per sample
in the submenu before the change and **zero dumps in that state at all** after it, across a full
sweep (overworld -> START menu -> POKeMON submenu -> back), while the START menu case was unchanged
(35-38 painted, every one of them left of `l=80`, nothing inside the rectangle) and the drawn tier
resumed normally on exit (63 waiting, 36-38 drawn, 31-32 mid-stride). **Not yet watched by the
user**, which is what `unverified.md` asks for.

## A probe with its own frame loop freezes every other script — 2026-08-19

**Symptom.** The dev loader stopped logging, stopped polling its control file, and the adapter
stopped ticking — no bridge traffic, no ghost, no adapter log lines — while the emulator carried on
at full speed and stayed responsive. From outside it looks exactly like the loader having quietly
died.

**Cause.** `probes/surf_bike_probe.lua` (written 2026-08-14, before the loader existed) ends in a
bare `while true ... emu.frameadvance()` and sets no `MESHGHOST_DEV_TICK`. Loaded as a loader
target, that loop never returns, so it runs **inside** the loader's own `loadTarget` call forever.
The loader's header has always stated the contract; the pre-loader probes were never updated to it,
and **~33 of them are in the same state** (`for f in adapters/bizhawk/pokemon/*/probes/*.lua; do
grep -q 'while true do' "$f" && ! grep -q MESHGHOST_DEV_TICK "$f" && echo "$f"; done`).

**Fix.** The loader now **refuses** such a target by inspecting its text before loading it, and says
why (`wouldHijackFrameLoop` in `dev-scripts/bizhawk-dev-loader.lua`). A guard in the one place that
knows a script is about to enter a shared frame loop beats rewriting 33 standalone probes that are
perfectly correct on their own. `surf_bike_probe.lua` itself was given the
`if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = step else while true ... end` shape, which is the
pattern to copy.

**The cost, which is why this is worth a guard rather than a note.** There is no recovery from
outside the emulator: no file edit, no control-file change and no signal can break that loop, so the
instance is dead until someone restarts BizHawk by hand. It cost this instance its session on
2026-08-19.

**The general form:** a shared cooperative loop needs every participant to *return*, and a
participant that does not cannot be detected once it is running — only refused before it starts.

## Crystal: a nil address reads as byte 0, so an unmeasured entry SATISFIES a gate instead of refusing

**Measured 2026-08-19, not reasoned about:** `memory.read_u8(nil)` under BizHawk **succeeds and
returns 0**. It does not error, so `pcall` does not catch it.

That silently inverts a promise this adapter makes in writing. `phases/phase9.md` states that an
unmeasured entry in an `ADDRESSES` table "stays `nil` so the adapter refuses rather than writing
somewhere plausible" -- but `inPlay()` tested `u8(W_BATTLEMODE) == 0`, and with a nil address that
term reads byte 0 and is **always true**. The adapter would believe no battle was ever happening,
which is one of the two ways a ghost gets painted over a battle screen.

**Fixed** by making `u8()` return `nil` for a nil address, and by making `inPlay()` require every
term to be a known value -- any `nil` means "this build has not been measured here" and the answer
is no. The startup refusal for missing addresses already existed and is unchanged; this closes the
case where a nil reaches a read at runtime anyway.

**The general lesson, worth carrying to every adapter:** "unmeasured" must fail CLOSED, and a
language that coerces nil into a valid argument will quietly make it fail open. Test what your read
primitive does with a nil address before relying on nil to mean refusal.

## Crystal: the drawn tier needs a POSITIVE "is the overworld on screen", not a list of screens to avoid

Two user reports on 2026-08-19 -- ghosts painted over a full-screen **menu**, ghosts painted inside
a **battle** -- are one defect. The drawn tier paints after the frame with none of the engine's
context, so anything not explicitly excluded gets painted over: a battle, a menu, an evolution
screen, the naming screen, the Pokedex, a cutscene, the title screen. **A deny-list of those will
never be finished, and every entry missing from it is a bug a user has to find first.**

Why the state gate was not enough alone, measured by the Archipelago agent on that build:
`wMapStatus` reads **2 right through an entire battle** and never leaves the in-play value, so the
battle exclusion rests **entirely** on `wBattleMode` with nothing behind it. Anything leaving
`wBattleMode` at 0 while the overworld is gone -- the encounter transition most obviously -- is
unguarded. They also A/B'd the gate itself: writing `wBattleMode = 2` in the overworld silenced the
drawn tier completely (0 log lines in 8s) and restoring 0 brought it back (32 lines in 8s), so
`drawOverflow()`'s early return works exactly as written and the terms were the problem.
`0x0FB1` is **not** a usable second term -- it reads 0 in some indoor maps.

**The test now asks the engine what it is drawing**, which no ROM revision can shift:

1. `inPlay()` -- the state gate, now nil-safe (above).
2. **At least one live hardware sprite** (OAM `y` in 1..159). Measured: overworld 28-34, behind a
   text box 30+, behind the START menu 28-30, **full-screen menu exactly 0**.
3. **The local player's own character is being drawn** -- OAM entries 0-3, which this tier already
   treats as the player's four sprites for its anchor calibration. This is the term that covers the
   encounter transition, where the overworld is gone before any state flag says so; and if it is
   false, the calibration those screen positions depend on has nothing valid to work from either.

Verified on vanilla across a full menu sweep: **zero** full-screen-menu draws after the change
against 31-34 painted peers per sample before it, the START menu case unchanged (13 dumps, every
painted peer outside its rectangle), and the overworld unaffected (38 drawn, 26 mid-stride, 7
spawned). **A vanilla battle was not reached** -- the walk to grass was blocked by our own spawned
ghosts boxing the player in, which `crowd-limits.md` predicts -- so the battle half rests on the
Archipelago agent's measurements above and still wants watching.

## Calibrating on OAM entry 0: the entry ORDER swaps when the sprite flips

**Symptom** (Crystal, 2026-08-19): drawn peers snapped around by 8px while the local player walked,
and only while walking. Standing still, everything sat correctly.

**Two plausible causes were ruled out first**, and both looked right on paper: the positions were
being computed in the engine's scrolled space (correct only at the instants the engine recomputes
it), and the anchor object was being re-chosen each frame. Fixing both reduced the jumping and did
not remove it.

**The real cause is a hardware behaviour, and it is not specific to this game.** A character's
four OAM entries are emitted **mirrored when the sprite is flipped**, so the entry that happens to
be the left-hand one changes with the direction the character faces. Calibrating the drawn tier's
origin on *entry 0* therefore gave an x that alternated by exactly 8px as the player turned --
which is why it only appeared in motion.

**Fix:** take the **minimum x across the four entries** rather than reading one of them. That is
invariant under the flip, because the set of four is the same set either way. Measured **64
discontinuities of 8 and 16px in a 20-second walk, down to 0 across 1,199 samples**.

**Carry this to any adapter that reads OAM to locate something.** "Entry 0 is the top-left one" is
an assumption about the current facing, not about the hardware, and it holds right up until the
character turns round.

## Lua 5.4 refuses a bit shift on a float, and a smoothed position is a float

**Symptom** (Emerald, 2026-08-19): a per-frame error, once every frame, from the drawn tier's
panel clipping.

**Cause:** the clip row was computed by shifting a screen position right to get a tile row -- and
that position comes from the **sub-tile smoothing**, so it is a float like `114.5`, not an integer.
Lua 5.4 raises rather than truncating (`number has no integer representation`), unlike 5.1/5.3
semantics some of us carry in our heads.

**Fix:** `math.floor` before the shift. **The general form: any value that has been through
interpolation or smoothing is a float**, however integral it looks in a log line, and every bitwise
operator and array index downstream of it is a trap. Grep for `>>`, `<<`, `&` and `|` on anything
derived from a smoothed coordinate.

Worth noting what hid it: the blanket per-frame `pcall` caught it, so the adapter kept running and
the clipping silently did nothing. `adapters/bizhawk/pokemon/emerald/BANDAGES.md` entry 2.

## A bridge port pinned in the environment cannot pin an ALREADY-RUNNING instance

**Symptom** (Emerald, 2026-08-19, with four emulators up): an instance launched with
`MESHGHOST_BRIDGE_PORT` set was port-walked anyway, walked into two other instances' cores, and
**attached to one of them** -- so two emulators drove one core and a third had none.

**Cause:** the Emerald adapter read the pin from the **environment only**. An environment variable
is fixed at process launch, so it can pin an emulator you are *starting* and can do nothing for one
that is *already running* -- which is every instance in a long session. Crystal had already learned
this and read a Lua global as well; Emerald had not been back-ported.

**Fix:** read the Lua global first, then the environment. A global can be set into a live emulator
from a control-file script, so the pin works on an instance nobody wants to restart.

**The wider rule for multi-instance sessions:** a port walk is a convenience for a single instance
and a hazard for several. When more than one emulator is up, **pin every bridge explicitly and
verify from the adapter's own log which port it settled on** (`bridge_ready on port N -- this core
is ours`). See `environment.md`, "One agent per BizHawk INSTANCE".

## A hardcoded ROM address slipped past the refuse-if-unmeasured discipline an hour after it was built

**Symptom** (Crystal, 2026-08-19): none, yet. It was caught by reading, not by a failure.

**Cause:** the cartridge sprite table had just been given a **per-ROM-build table with a nil for
any build nobody had measured**, precisely so an unmeasured build refuses instead of guessing. An
hour later a second code path used `OverworldSprites` as a **hardcoded constant**, on any build,
bypassing that table entirely. On the Archipelago ROM -- where the table lives at `0x14564`, not
vanilla's `0x14736` -- it would have painted peers from arbitrary ROM bytes.

**Why this keeps happening: "derived from the vanilla address" has now produced four wrong
addresses on this project.** A relocated build moves things in several independent blocks, and
today's Emerald case proved two of them can move by different amounts in one ROM
(`gObjectEvents` +0x284, the graphics-info pointer table +0x7530, `gSprites` not at all).

**The discipline, and it needs enforcing rather than documenting:** an address used on more than
one build belongs in the per-build table, always, with a nil where nobody measured it -- and a
constant that names a ROM location is a code smell on sight. **Grep for the constant's name after
adding the table**, because the path that bypasses it is usually written by the same person in the
same hour.

## Frame tiles in the tilemap are not the same thing as a panel on screen

**Symptom** (Crystal, 2026-08-19): a probe scanning every tilemap row for the text box's frame
corner found a full-width frame top at BG row 12 **with no panel visible on screen** and the window
register `WY` parked at its off value of 144. It cleared seconds later as the camera scrolled.

**Cause:** the tilemap holds what was last written there, not what is being displayed. A panel that
has been closed, or one scrolled out of the visible window, leaves its tiles behind.

**Why it matters:** the obvious generalisation of Crystal's text-box test -- "scan every row for
the corner tile instead of just row 12" -- would therefore **hide drawn peers for no reason**,
which is the same class of over-hiding as the earlier WY-alone heuristic that emptied the bottom
half of the screen. A tilemap test needs the window to actually be on: LCDC bit 5, `WY<=143`,
`WX<=166`.

This one was found *before* it shipped, by a probe written to check the assumption rather than to
confirm it -- which is the only reason it is a pitfall entry and not an incident.

## A stray dev-scripts/config.json silently redirects a core to a relay nobody is running

**Symptom** (2026-08-19, twice): once, four synthetic peers went to a dead port and rendered
nothing; once, a core sat retrying a relay that had exited hours earlier while everyone assumed it
had lost the shared one -- and the reconnect log said nothing, because it only logged when the
error message *changed* (fixed the same day, `verified.md`).

**Cause:** a core reads `config.json` from its **working directory**, and a core autostarted by the
BizHawk loader has `dev-scripts/` as its cwd. A config left there by an earlier session pointed at
`127.0.0.1:7787`, room `emeraldcap`. The file was then deleted, so **nothing in the tree explained
the port any more** -- the process was the only witness.

**Fixes, both applied:** `dev-scripts/config.json` is gitignored so it can never be committed, and
the retry now keeps saying which address it cannot reach.

**The habit that catches it:** when a core connects somewhere unexpected, read its **command line**
(`Get-CimInstance Win32_Process`) rather than the repo -- a flag survives in the process list, a
config file's contents do not. Prefer an explicit `-relay` flag over a config file whenever
sessions share a machine.

## "A bit choppy" cost six rewrites, because it was three separate bugs and none were where I looked — 2026-08-19

**Symptom.** A drawn (painted) ghost in Emerald looked subtly wrong next to the engine-spawned one:
choppy, then too fast, then choppy again. Six movement models were written and judged by eye.

**What it actually was**, once both ghosts were logged per frame instead:

1. **Running at walking speed.** The step machine took its duration from the peer's `anim` tag,
   which said walking while the peer ran. The ghost lost half a tile per step, fell behind, and
   SNAPPED when it passed two tiles. The snap was the visible chop.
2. **A one-tile spike in the anchor, once per step.** The player's tile counter flips to the
   DESTINATION tile the moment a step begins, so calibrating against it mid-step put a whole tile
   of error in. Direction-dependent, which is why it looked fine one way and terrible the other.
3. **A ±2px beat every frame** from mixing two camera counters — `gSpriteCoordOffset` (inside the
   player's screen position) and `gTotalCameraPixelOffset` (inside the anchor) — which the game
   does not write at the same point in the frame.

And the last one was not in the adapter at all: the remaining hitch on the SPAWNED ghost was the
core's `-interp`, 100ms, too short to cover a 20Hz arrival rate. At 250ms it was perfect.

**The lessons, in the order they would have saved time.**

- **`CLAUDE.md` says stop after ~3 failed live iterations and tabulate. That rule was ignored for
  six.** The first measurement — logging both renderers' actual positions per frame — found bug 1
  immediately, and each subsequent one found the next. Every model rewritten before that was aimed
  at a symptom whose cause was somewhere else entirely.
- **"Smooth it" and "schedule it" are different jobs.** Any model with its own timing — a step
  duration, a speed, a state machine — runs against a world that scrolls on the game's clock, and
  two clocks beat. A filter has a lag and no phase, so it cannot beat with anything. Smoothing
  between updates is the adapter's job; deciding WHEN things move is not.
- **A state tag can lie; a position cannot.** `anim` is a classification of the sender's state, and
  a cutscene, a forced walk or a turn can all move a character without setting it. Ask the peer's
  own coordinates what it is doing.
- **When two renderers must agree, pin one to the other rather than reproducing its schedule.**
  Compare mode now places the painted ghost from the spawned one's own sprite, which makes every
  remaining difference a rendering difference — which is what the mode was for.

## Approximating the game's own art never converges — read it instead, 2026-08-19

**Symptom.** A hand-drawn ellipse standing in for Emerald's ledge-jump shadow went through three
rounds of correction — too faint, still lighter than the player's, then too big, then *"or slightly
big still not sure"* — with each round costing the user a live test.

**Why it could not converge.** The thing it imitates is on screen next to it. Any difference in
size, shade or placement is directly comparable, so "close enough" is never reached; each fix moves
the discrepancy somewhere else. Measuring helped every time and still did not finish the job: the
palette dump gave the colour, the sprite dump gave the position, decoding the pixels gave the ink
extent (16x5, not the 16x8 sprite box) — and it was *still* arguably a touch big, because an
ellipse is not that silhouette.

**What ended it.** Reading the game's actual art. A shadow is an ordinary sprite, so the first time
the local player hops there is one on screen with its own `images` pointer and palette: decode it
once, draw those runs for every ghost. Confirmed perfect immediately, and it dims and clips for
free because it goes through the same draw path as everything else.

**The rule.** When compensating for something the engine will not do for a ghost, prefer reading
the engine's own asset over drawing a lookalike — and identify that asset by WHAT IT IS (in use,
this size, next to the player, during this action) rather than by an address, so nothing goes stale
against a ROM revision. Crystal's drawn tier already learns facing frames this way; the same trick
works for effects.

**Where an approximation is still correct:** as a fallback for the case that has nothing to learn
from yet — here, a ghost that hops before the local player ever does.

## A ghost has no task, so nothing ever un-pauses its animation — 2026-08-19, Emerald

**Symptom.** A spawned ghost that picked up a fishing rod held the animation's **first frame** for
the entire state. The graphic was right, the pose was right, the position was right; it simply
never moved. Reported as *"its not doing the fishing animation/s"*, and later, after a wrong fix,
*"it gets stuck in an animation instead of doing the animation"*.

**Why it survived two fixes.** The obvious reading is "nothing is advancing the animation, so
advance it" — and both attempts did exactly that, from the peer's animation number. Both looked
*worse*, because the actual cause was one layer down: the sprite was **paused**.

The overworld pauses an idle object event's sprite (`animPaused`, bit `0x40` of the sprite struct's
`+0x2C` — `pokeemerald` `include/sprite.h:211-212`, where `animDelayCounter:6` precedes it). The
player's fishing **task** un-pauses it as part of running the animation. A ghost has no task. So
the ghost sat paused, and every write of `animNum` on top of a paused sprite just re-selected an
animation that was never going to play — and writing it repeatedly (with `animBeginning`) actively
made things worse, restarting frame 0 faster than the engine could leave it.

**What ended it.** Measuring the sprite instead of reasoning about it. One trace line carrying the
player's animation state and the ghost's on the **same frame** showed the ghost pinned at `3/0` for
256 consecutive frames and then `11/0` for the rest, while the player's frame index cycled
`0, 1, 3` throughout. `+0x2C` read `0xc7` on the ghost — `0x40` set — and the answer was in the
bit, not in the number.

**The fix uses the engine's own switch, not the bit.** `ObjectEvent.enableAnim` (byte `+0x01`,
bit `0x08` — `include/global.fieldmap.h`) is what `TryEnableObjectEventAnim`
(`src/event_object_movement.c:7335-7343`) reads: it clears `animPaused` **and** `disableAnim`, then
clears itself. One write per animation start hands the whole job back to the engine, which is what
makes the frames advance at the game's own rate rather than one we would have had to invent.

**The rules.**

- **An engine pauses work it believes nobody needs, and a synthetic entity is precisely the thing
  it believes nobody needs.** Before concluding "the engine will not do X for a ghost", check
  whether the engine has been *told not to*. Idle-pausing, culling, sleep flags and LOD are all the
  same shape, and all of them make a ghost look broken in a way that reads like a missing feature.
- **Prefer the engine's own enable switch over clearing the state yourself.** Clearing `animPaused`
  directly would have worked this frame and been re-set the next; going through `enableAnim` means
  the engine stays the owner and its own bookkeeping (`disableAnim`) stays consistent.
- **A memo of "what we last told it" is not a memo of "what it is".** The first version of this fix
  remembered the animation number it had issued, so a **second** cast of the same rod matched the
  remembered number, skipped the enable, and froze again — after the engine had silently re-paused
  the sprite at the end of the first cast (measured: `+0x2C` back to `0xcd` with the memo still
  reading `3`). Condition on the observable state, not on your own history.

## A value the game DERIVES cannot be COPIED — 2026-08-19, Emerald

**Symptom.** A fishing ghost sat 8px to the side of where it belonged, or stepped 8px sideways and
back, at the start and end of every cast. Reported over many iterations as *"it snaps"*, *"it gets
pulled back a tiny bit"*, and finally *"it still looks like it snap/move at the start~ and end~ of
the fishing compared to the drawn & player"*.

**Why it was hard.** The offset is real, small, and *sometimes correct*, so every measurement of it
looked nearly right. Four separate defects produced the same 8px symptom, and each fix revealed the
next:

1. **Shape and offset applied on different frames.** The graphic swap wrote the new sprite's
   dimensions; the offset was left to a block that had already run earlier in the same frame, so
   the offset always landed one frame after the shape. A 32-wide fishing frame drawn at a walker's
   offset is exactly half a tile off.
2. **The wire carried a mismatched pair.** The sender deliberately **holds** the graphic for six
   frames before publishing it (so peers never see an unsettled state) but did not hold the offset.
   At every cast *end* it therefore published the fishing graphic together with the walker's
   offset, and at the start the reverse. A hold applied to one half of a pair **creates** the
   mismatch it was built to prevent.
3. **The receiver applied it to the wrong graphic.** With the pair briefly disagreeing on the wire,
   the ghost adopted a fishing offset while still wearing the walking graphic.
4. **The real cause: the offset is not a transmissible property at all.** The game recomputes it
   **every frame from the frame currently displayed** — `AlignFishingAnimationFrames`
   (`src/field_player_avatar.c:2045-2078`) reads `anims[animNum][animCmdIndex].type`, which for a
   frame command is that frame's image index, and sets `x2=8` for images 1/2/3 (`-8` when facing
   west, `DIR_WEST=3`, `include/constants/global.h:140`), `y2=-8` for image 5, `y2=8` for images
   10/11.

Because a ghost's animation **lags** the player's by the interpolation delay, the player's offset
is *always* the offset for a frame the ghost is not showing yet. Copying it was wrong by
construction — and no amount of tightening the pairing could fix that, which is why fixes 1-3 each
removed a real defect and left the symptom.

**What ended it.** Computing the offset locally, from the ghost's **own** displayed frame, with the
game's own rule.

**The rules.**

- **Before putting a field on the wire, ask whether the game STORES it or RECOMPUTES it.** A stored
  field is a fact about the peer and travels fine. A derived field is only meaningful *alongside
  the exact input it was derived from*, and a ghost — running behind, by design — never holds that
  input at the same time. **Send the input; derive locally.**
- **A settle/hold must cover every field of a pair, or none.** Half a held state is a state that
  never existed.
- **Two consumers of one state must agree about which MOMENT it describes**, not just about its
  value. Nearly every defect in this investigation was that same disagreement wearing a different
  hat.

## A script's writes land between frames; the game's land inside one — 2026-08-19, Emerald

**Symptom.** With the offset finally computed correctly from the ghost's own frame, the ghost
**still** flicked 8px sideways — now mid-animation rather than at the ends. Every struct field read
back exactly right on every frame.

**Why no value was ever going to fix it.** A Lua script acts at a frame boundary. The engine,
within one frame, **advances sprite animations and then builds OAM**. So a value written from Lua
is paired with whatever image the engine selects *afterwards* — structurally one step out of phase.
The offset was right for the frame we could see and wrong for the frame that got drawn, forever, no
matter how correct the arithmetic was. The game's own fishing task has no such problem because it
runs *inside* that same update, which is precisely why the player never flickers.

**How it was proved.** By reading OAM directly (`0x07000000`, 128 entries, 8 bytes each) rather
than the sprite structs that feed it. `pos2` was constant at `8,0` across frames in which the OAM x
went `144, 136, 144`. When every struct field agrees and the screen disagrees, the structs are not
the thing being drawn.

**The fix.** Run the alignment from an `event.onmemoryexecute` hook at **`BuildOamBuffer`**
(`0x08006A0C` on the vanilla ROM, from this project's own `pokeemerald.map` build — see
`environment.md`): animations for the frame are final, OAM is not yet built. That is the same point
in the pipeline the game's own task occupies, which is what makes it identical on screen. It is
vanilla-gated — an Archipelago build relocates code, so there it falls back to the frame-boundary
path until that ROM's address is measured (the adapter's `BANDAGES.md`).

**And then it broke the OTHER renderer.** The painted tier pins its position to the spawned
sprite — which had just acquired an offset specific to the *spawned* ghost's current frame — while
painting the frame the **wire** reported. Right image, another sprite's alignment: the same defect
class, in the last place it could still hide. Fixed by dropping the alignment from the pin and
having the painted tier compute the shift for the frame **it** draws, from a rule now shared by
both tiers.

**The rules.**

- **When a value must stay in lockstep with something the engine updates mid-frame, a
  frame-boundary write is structurally wrong, not merely mistimed.** Correcting the value cannot
  fix a phase error. Find the engine's own pipeline point and act there — `event.onmemoryexecute`
  makes this available on BizHawk, and it converts "I can only act between frames" into "I can act
  where the game does".
- **A phase fix must be applied to every consumer at once.** Fixing one renderer while another
  inherits its now frame-specific output just moves the defect. When two renderers must agree,
  share the *rule*, not the *result*.
- **Watch for a fix that is invisible to your instrumentation.** Everything readable from Lua said
  the code was correct; only the hardware's own draw list disagreed. See `_template/probes.md`,
  "Measure what is DRAWN".

## A sprite you BUILD is missing whatever the game's constructor computed — 2026-08-19, Emerald

**Symptom.** Two, and only the first was ever reported as a bug. A surfing ghost rode on nothing —
*"both of the ghosts don't have the 'blue fish' they are riding on while surfing"* — while the
adapter's own log showed it correctly wearing the surfing graphic and animating. And when the blob
did exist, it had been recorded since 2026-08-18 as rendering *"roughly half a tile down-right of
the rider"*, cause unknown.

**Cause 1: one construction path out of two.** The blob was spawned inside `spawnGhost`, which is
the FULL-REBUILD path. Every way a peer actually enters the water goes through
`swapGhostGraphicInPlace` instead — they were already spawned as a walker, so the graphic is
patched rather than rebuilt. The companion sprite was correct code sitting on a path that the case
it was written for never takes.

**Cause 2: a field only the constructor sets.** `spawnSurfBlob` zeroes the sprite struct, copies the
template's OAM, images, anims and callback, and sets position — everything the TEMPLATE describes.
`centerToCornerVec` (`+0x28`/`+0x29`) is not in the template: `CreateSprite` computes it from the
OAM's shape and size. Left at 0,0, the hardware draws a 32x32 sprite from its corner instead of its
centre — one tile down and right, which is the unexplained offset, and it also means the blob's
position field did not mean what every other sprite's position field means.

**What ended it.** Reading the GAME'S OWN blob and diffing it field by field against ours
(`probes/surfblob_probe.lua`). The player's read `c2c=240,240`; the ghost's read `c2c=0,0`. Nothing
else had to be understood — not the bob, not the animation, not the field-effect system.

**The rules.**

- **A sprite built from a template carries what the template says and nothing the CONSTRUCTOR
  computed.** Before trusting one, diff it against a live instance the game made; the fields that
  differ are the constructor's. Never diff it against your own expectations.
- **When a feature is triggered on one construction path, find every other path into the same
  state.** Patch-in-place and rebuild are two doors into "this ghost is now surfing", and a feature
  hung on one of them is invisible exactly when the state is reached the normal way.
- **A companion sprite is part of the state, not a decoration** (`_template/README.md`'s
  whole-effect rule) — so it belongs everywhere the state is entered AND left. A blob left behind
  keeps following the object id in its own `data[2]` and swims under a peer who is walking.

## A world-space anchor built from a SPRITE carries the sprite's own terms — 2026-08-19, Emerald

**Symptom.** A painted reflection drew a few pixels onto the ledge and grass at a pond's edge, when
the player's own reflection stopped cleanly at the water. Reported five times across a long session
in slightly different words -- *"it draws on top of the edge as well, that sits between the
grass/water"*, *"its only supposed to draw on the water"* -- and survived four different clipping
rules, each of which was independently correct.

**Cause.** The drawn tier converts a screen pixel back to a map tile using an origin captured from
the PLAYER'S SPRITE position. That position is not a world coordinate: it is the sprite's frame
top-left, which carries two terms belonging to the graphic rather than to the map.

1. **`pos2`** -- while anyone is surfing this is the BOB, so the whole tile grid rose and fell a few
   pixels with the character. Found first, and it was cutting the reflection short vertically.
2. **`centerToCornerVec`** -- the frame's own centring, `-(width/2)`. A walking player is 16 wide so
   it is **-8**; a SURFING player is 32 wide so it is **-16**. The grid was therefore **8px too far
   left for exactly as long as the player was surfing** -- which is exactly when a reflection is on
   screen to be judged.

Vertically the same term is -16 for both graphics, so the vertical edge was correct throughout and
only the SIDE ever looked wrong. That asymmetry is what made it read as a clipping-rule problem for
so long: every rule tried was tested against a boundary that happened to be right.

**Why the obvious check could not catch it.** A self-check ran the player's own frame position
through the same inverse and compared it against the object's coordinates. It agreed perfectly on
every sample -- because both sides carried the same bias. **A consistency check between two values
that share an input proves only that they share it.**

**What ended it.** Aligning the computed grid against the SCREEN, using a tile whose appearance is
not ambiguous: metatile 161 is four copies of one water tile, so it must render as 16px of uniform
bright water. The grid said it started at x 88; the pixels said 96. Everything else followed.
Method: `_template/probes.md`, "Check a computed grid against the screen".

**The rules.**

- **An origin for world space must be free of every term that belongs to the SPRITE**: animation
  offsets, bob, alignment, and the frame's own centring. Normalise them out, or derive the origin
  from the camera instead. A sprite's screen position is not a world coordinate.
- **A term that varies with the GRAPHIC will hide until the graphic changes.** This was correct for
  every walking test ever run and wrong only while surfing.
- **When one fix closes two symptoms, it was one cause.** The user, on this one: *"it also fixed the
  issue of drawing when outside of the water at the same time"* -- the leak onto grass and the leak
  onto the ledge were the same 8px.

## A rule that is right for one graphic can be wrong for another — 2026-08-20, Emerald

**Symptom.** A ghost on a Mach Bike moved with its legs stopped — *"sliding/gliding at top speed"* —
while the same code animated a walking ghost perfectly.

**Why the counters said it was fine.** Two of them, both honest and both blind to this: the sprite
was never paused while moving (`paused=0`) and its frame index advanced on 67% of stepping frames
(`slide=150/225`). Nothing about "is it animating" was false. What was false was WHICH animation.

**Cause.** While a peer moves, the adapter lets the ENGINE animate the ghost, from the movement
action it was asked to perform. That is correct for the walking graphic — the action carries the
matching walk cycle, and mirroring on top of it put two writers on one field and left ghosts stuck
in a pose after a turn (2026-08-19). On a bike it is wrong: the player rides on animation 4, while
the action-derived animation for that graphic is 8, which runs to its last frame and holds.

**What ended it.** The per-frame trace that logs the PLAYER's animation state beside the GHOST's on
one line (`MESHGHOST_EMERALD_ANIM_TRACE`), which makes "different animation" and "same animation,
stalled" distinguishable at a glance:

```
f=597  P.anim=4/0 | R.sanim=4/0 | G.anim=8/3
f=605  P.anim=4/1 | R.sanim=4/1 | G.anim=8/3   <- ten frames on one frame
```

The peer had been sending the right number the whole time.

**The rules.**

- **A rule scoped to "while moving" or "while idle" is probably scoped to the wrong thing.** Ask
  which GRAPHIC it is true for. Walking, biking, fishing and surfing are animated by different parts
  of the engine, and a rule derived from one of them is a guess about the others.
- **A counter can only disprove the defect it was built for.** `paused` and `frame advanced` were
  both built for the previous slide, and both passed while a different slide was on screen. When a
  measurement clears something the user can still see, the measurement is answering a narrower
  question than the report.
- **Trace the reference and the copy on ONE line.** Every animation defect this adapter has had was
  invisible in a trace of either side alone.

## Counters placed inside a gated block measure nothing — 2026-08-20, Emerald

**Symptom.** 71 laps of scripted riding produced an empty counter column.

**Cause.** The counters for "is the ghost animating while it moves" were added inside the animation
mirror — which is deliberately gated on the peer standing STILL. So they could only ever record the
case they were built to rule out.

**The rule.** **Put a measurement on the path the event happens on, not near the code you suspect.**
The suspicion is what is being tested; wiring the counter into it assumes the answer. Check the gate
conditions above a new counter before trusting a zero, and prefer a per-frame path with an explicit
condition to a convenient nearby block.

## A stable field can read zero exactly when the thing it describes is happening — 2026-08-20, Emerald

**Symptom.** A ghost slid down a muddy slope at half the peer's speed, after a change that had just
fixed bike speed everywhere else.

**Cause.** The speed had been moved from `movementActionId` (transient, sampled at 20Hz, missed the
fast action 6 times in 10) to `gPlayerAvatar.bikeSpeed` (stable, correct while riding). But
`ForcedMovement_MuddySlope` calls `Bike_UpdateBikeCounterSpeed(0)` before pushing the rider — so on
the one terrain built for this bike, the field reads **standing still** while the character is
visibly moving at `WALK_FAST`.

**The rule.** **"Stable" and "correct" are different properties, and a field can be authoritative in
the ordinary case and deliberately zeroed in the special one.** Before replacing one source with
another, look for the code paths that WRITE the new source, not just the ones that read it — a reset
is as much a write as an update. The fix here was neither source alone: the stable field first, the
transient one as a fallback exactly where the stable one says nothing is happening.

## A character can face one way and move another — 2026-08-20, Emerald

**Symptom.** A ghost faced the wrong way while being pushed down a slope; the player kept looking
uphill, the ghost turned to look downhill.

**Cause.** Asking the engine for a step also sets the object's facing, which is right nearly
everywhere — and wrong wherever the game has separated the two. `facingDirectionLocked` exists for
exactly that, and the muddy slope sets it.

**What it cost to find, and the cheap way to see it.** Classify frames by what the PEER was doing
(here: the sign of its coordinate delta), then tabulate the ghost's action and facing across each
class. "The ghost faced south on 181 of 527 slide frames" is a finding; watching it is an
impression. The fix needed no new wire field: the peer's facing is already sent and the step
direction is known locally, so the two DISAGREEING is itself the signal.

**The rule.** **Never infer a facing from a movement.** Send it, or derive it from something the
game states, and look for a lock/override flag before assuming the two always agree.
