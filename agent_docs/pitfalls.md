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

**This taxonomy stops partway through the file, and everything after it is chronological.**
Noted 2026-08-25. The themed sections below run to the Gold/Silver GameShark entry; from there to
the end — roughly seven tenths of the file — entries are appended in the order they were found,
one `##` each. **So "look under the relevant theme" finds only a fraction of what is here: search
the whole file.** Restructuring it is its own pass and was deliberately not attempted here.


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

**Superseded as a procedure, 2026-08-24: this is now enforced mechanically.**
`.githooks/pre-commit` refuses such a commit and CI re-scans the whole tree (`136a413`,
`cddc303`), so the answer is no longer "be careful" — it is `git config core.hooksPath .githooks`
once per clone, and never `--no-verify` past it. The cases below are why the rule exists.

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
  (2026-08-13); adding a companion object later silently broke it.

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

## A Gold/Silver GameShark code run on Crystal writes into the object RAM MeshGhost spawns into (2026-08-18)

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

## BizHawk accepts a GBA cheat code it cannot decrypt, and silently activates the garbage (2026-08-18)

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

## A spawned character renders a few pixels off its tile, forever (2026-08-18)

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

## A spawned entity leaks once per zone crossing, but survives doors fine (2026-08-18)

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

## A menu's contents are not fixed, and neither is its cursor (2026-08-18)

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

## An empty log reads exactly like "the game did nothing" (2026-08-18)

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

**Symptom.** `CLAUDE.md`'s mandated public-repo leak check printed nothing, as it had been doing,
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
for one experiment earlier. **`dev-scripts/bizhawk-dev-loader.lua` swaps SCRIPTS, not the
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

## ONE console line a second cost 7.4 fps — and the feature it was measuring cost nothing (2026-08-21, Emerald)

**Symptom.** The user, watching the Stage 1 hardware-sprite probe: *"i think its lagging constantly"*.
The ride harness agreed immediately — **50.7 avg / 25 worst against a 58.1 / 38 control**, reproduced
at 50.8 on a second run. The probe under suspicion does about **ten memory reads and three memory
writes a frame**, which is not a cost anyone would predict, so the obvious conclusion was that
writing OAM from Lua is expensive.

**That conclusion was wrong, and subtraction is what showed it.** Three switches, one run each, one
thing removed at a time — never a third guess:

| configuration | avg fps | worst |
| --- | --- | --- |
| ride alone (bare control) | 58.1 | 38 |
| ride + an EMPTY second script | 58.1 | 37 |
| probe, everything on | 50.7 / 50.8 | 25 / 27 |
| probe, **OAM writes removed** | 50.4 | 25 |
| probe, **the player scan removed** | 50.5 | 26 |
| probe, **the log line removed**, writes and scan still on | **58.1** | 37 |
| probe, log line sent to the FILE instead, everything on | **58.1** | 37 |

Removing the writes changed nothing. Removing the scan changed nothing. Removing **one**
`console.log` per second — about 33 lines over a 33-second route — recovered the entire 7.4 fps and
landed exactly on the bare-emulator control, with the hardware sprite still on screen.

**Diagnosis, and the part worth internalising.** `console.log` in BizHawk is **not a print**. It is
a text append into the Lua Console *window*, and its cost is a function of **what that window
already holds** — a long-running session has a large backlog, so the same call gets
more expensive the longer you work, which is exactly the shape that makes it hard to attribute. The
2026-08-19 entry above priced this at ~1,400 calls a second and read as a lesson about volume. It is
not about volume. **One line a second is already too many.** The threshold is far lower than any
reasonable person would guess, and it is not a fixed threshold at all.

**The rule, stated so it cannot be read as being about bursts.** Nothing on a per-frame or
per-second path calls `console.log`, in a probe or in an adapter. Split the two: a `say()` for the
handful of orientation lines at load, and a `log()` that only ever writes the file. That is what
`probes/oaminject_probe.lua` does now, and its header carries these numbers as the reason.

**And the quality bar this serves, in the user's words (2026-08-21):** *"there can't be any fps
drops like this in a shipped/release of the game, not allowed to pass quality wise by me. we have to
keep base fps"*. A release holds the platform's base rate — 60 for a GBA — measured against a bare
control run on the same route, because the machine has its own floor and without the control the
game's own map loading gets blamed for whatever was loaded at the time. **A drop of this size is a
blocker, not a rough edge**, and the fact that it came from a diagnostic rather than a feature makes
it worse, not more forgivable: it is a cost the user pays for nothing.

**The second lesson, free with the first.** A diagnostic can break the thing it measures, and this
is the cheapest possible illustration — the probe existed to price a feature and instead priced
itself, and it very nearly convicted OAM writing of a cost it does not have. When something
measures slow, subtract the instrument before believing the subject.

## Comparing two renderers: four ways to measure the wrong thing (2026-08-21, Emerald)

Pricing the new hardware-sprite tier against the painted one took **four invalid measurements**
before a valid one. Every single one was convincing at the time, and the user caught two of them
from the screen before any instrument did. They are worth having as a set, because they are traps
about COMPARISON rather than about either renderer.

### 1. The instrument cost more than the thing measured

A probe logging **one `console.log` per second** measured 50.7 avg fps against a 58.1 control. The
OAM writes and the sprite were free; the log line was the whole 7.4 fps. Its own entry above has the
detail. **Subtract the instrument before believing the subject.**

### 2. The load never arrived, and the failure looked like a catastrophic result

Eight painted peers measured **2-3 fps** -- so bad it read as a damning result for the painted tier.
It was the relay's **`-max-clients` default of 8** refusing every peer: the adapter logged `relay
refused connection: server full` and finished with `remotes=0 ghosts=0 drawn=0`. It was measuring an
adapter thrashing to reconnect, with nothing rendered at all. The user saw the same thing from the
other side -- *"i never saw any drawn ghosts either"*.

**The lesson is not "raise max-clients".** It is that a load generator's success has to be CONFIRMED
from the receiving side before its numbers mean anything. The adapter prints exactly that
(`remotes=N ghosts=N hw=N drawn=N`) and it was sitting there unread.

### 3. One side of the comparison was off screen

The next run looked reasonable, which made it worse. Synthetic peers from `meshghost-fakeadapter`
orbit a **fixed map coordinate**, while the hardware-sprite probe positioned its copies **relative to
the player**. Riding `fpsride`'s left/right route therefore walked away from the painted crowd while
carrying the hardware one along -- and the painted tier's own off-screen cull then made its peers
nearly free. A loaded tier was being compared against an unloaded one.

The user caught it: *"the drawn ghosts are not following when you go to the left. not accurate
testing"*. The adapter's status line had been printing `drawn=0` mid-ride the whole time, and it had
been read past twice.

**The fix is a different instrument, not a tweak.** `probes/fpsride.lua` is right for *"does this cost
the player anything while they play"* and structurally wrong for putting two renderers side by side.
`probes/fpshold.lua` exists for the second question: the player stands still, the peers are centred
on them, and the load stays on screen for the whole window.

### 4. The reference hid the defect it shared

With the tiers finally priced, the hardware ghost still looked *"really choppy"*. The cause was in the
**shared position pipeline** -- `glideRemote` measuring target speed frame-to-frame against a bursty
stream, which collapsed its speed limit and left the ghost unable to follow a running player
(`verified.md`, same date). The painted tier had the identical defect and had shipped with it.

**Why nobody had seen it:** in compare mode the painted copy is **pinned to the spawned ghost's own
sprite** and never uses its own position, so the one instrument aimed at that tier was structurally
incapable of showing the fault. It took a THIRD renderer, placed from the pipeline, to expose a bug
in code the second one had been running unnoticed.

**Two rules out of this.** A comparison harness that pins one side has removed a whole class of
defect from view -- know which class. And when a new implementation looks worse than an old one,
check whether the old one is being measured on the same path at all before concluding anything about
the new one.

### And the one that was not a measurement error at all

Between 3 and 4 the tier rendered **nobody** for a full cycle. OBJ VRAM was 996/1024 used and
`allocSpriteTiles` could not find a run. **A tier that silently renders no one is indistinguishable
from a tier that is switched off**, and there was no way to tell them apart. Acquisition failure now
logs its reason, throttled, to the file. A map load frees every range (the engine's own
`ResetSpriteData`), which is how the 52/1024 baseline was recovered and the leak shown to predate
this work.

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

## PARTLY RESOLVED (2026-08-19) — Crystal: invisible collisions, and ghosts popping in and out

**The popping half was fixed and user-confirmed** (`verified.md`; `unverified.md`). The collision
half is the part that stayed open. Restatused 2026-08-25 — it had no status line at all, and a
still-OPEN item is out of scope for a file of closed incidents anyway.

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

## Crystal: a drawn ghost paints over a FULL-SCREEN menu, because the adapter reads it as a text box (2026-08-19)

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

## Crystal: a nil address reads as byte 0, so an unmeasured entry SATISFIES a gate instead of refusing (2026-08-19)

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

## Crystal: the drawn tier needs a POSITIVE "is the overworld on screen", not a list of screens to avoid (2026-08-19)

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

## Calibrating on OAM entry 0: the entry ORDER swaps when the sprite flips (2026-08-19)

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

## Lua 5.4 refuses a bit shift on a float, and a smoothed position is a float (2026-08-19)

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

## A bridge port pinned in the environment cannot pin an ALREADY-RUNNING instance (2026-08-19)

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

## A hardcoded ROM address slipped past the refuse-if-unmeasured discipline an hour after it was built (2026-08-19)

**Symptom** (Crystal, 2026-08-19): none, yet. It was caught by reading, not by a failure.

**Cause:** the cartridge sprite table had just been given a **per-ROM-build table with a nil for
any build nobody had measured**, precisely so an unmeasured build refuses instead of guessing. Then
a second code path used `OverworldSprites` as a **hardcoded constant**, on any build,
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

## Frame tiles in the tilemap are not the same thing as a panel on screen (2026-08-19)

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

## A stray dev-scripts/config.json silently redirects a core to a relay nobody is running (2026-08-19)

**Symptom** (2026-08-19, twice): once, four synthetic peers went to a dead port and rendered
nothing; once, a core sat retrying a relay that had already exited while everyone assumed it
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

## Two draw paths, and a fix applied to one of them — 2026-08-20, Emerald

**Symptom.** Occlusion for the painted tier was implemented, reloaded, and the ghost still walked
over the building.

**Cause.** The painted tier draws a character two ways: from the peer's OWN graphic when it has one
(a bike, a rod, a surfboard) and from the cached gender frames when it does not. Every session
recently had been spent in the first path, so the fix went there and nowhere else — and the peer was
on foot.

**What made it obvious, and it is worth copying.** The change shipped with a one-shot diagnostic
beside it, which printed NOTHING. An empty diagnostic is not a quiet success and not a broken
probe by default: **first check whether the code it lives in ran at all.** That distinguished
"the mask is wrong" from "the mask never executed" in one reload, without a guess and without asking
the user to look again.

**The rules.**

- **Count the paths before fixing one.** Ask what else renders, spawns or moves the same thing.
  This adapter has two draw paths, two tiers, and a spawn path plus an in-place swap — four places a
  change can need to land, and each has caught something.
- **Put a diagnostic INSIDE the change, not near it.** Then "did it work" and "did it run" are
  different lines in the log rather than the same silence.

## Occlusion has two sources, and one of them is a sprite — 2026-08-20, Emerald

**Symptom.** A painted ghost was confirmed hiding correctly behind buildings, and then did not hide
at all in tall grass.

**Cause.** This engine occludes a character two entirely separate ways:

1. **BG layers** — a metatile's top layer on a BG the sprite does not outrank. Buildings, roof
   edges, tree tops. Handled by a per-pixel metatile mask.
2. **Field-effect SPRITES** — the engine spawns one per object standing in grass and draws it above
   them. Nothing about the map's layers is involved, and the grass metatile's top layer is empty.

A painted tier needs both, and finishing the first reads exactly like finishing the job.

**How to tell which one you are looking at, in one probe:** dump the metatile under a character who
IS correctly occluded. If its top layer has content, it is the BG; if the top layer is empty, the
occluder is a sprite and the map cannot tell you anything about it.

**The rule.** **"Is it hidden?" is not one question.** Before believing an occlusion feature is
done, list the things in that game that can be in front of a character — scenery, ground effects,
weather, UI — and check that each is either handled or knowingly out of scope. A spawned ghost gets
all of them free, which is exactly what makes the painted tier's gaps easy to miss.

## An adjustment that changes nothing is evidence about the MECHANISM — 2026-08-20, Emerald

**Symptom.** A painted ghost was hidden too much by tall grass. The bound controlling how far the
grass could rise was adjusted, twice, and the user reported no change either time. Both times the
response was to reason harder about which pixel rows ought to be covered.

**What that should have said immediately.** A value that makes no difference when changed is not a
wrong value -- it is a value that is not being read. "The clip is set wrong" and "the clip never
applies" predict the same screen and are separated by one experiment, not by more thought.

**What ended it.** A deliberately WRONG build: the bound set so far in one direction that the result
could not be mistaken -- grass unable to rise above the character's feet at all. One look
distinguishes "the clip works and the number is wrong" from "the clip does nothing". It also
happened to be the correct answer, which two rounds of pixel-row reasoning had not reached.

**The rules.**

- **When a change produces no visible difference, test whether it applies at all** before changing
  it again. Set it absurdly, or log it. Two rounds of "no change" is already one too many.
- **A deliberately wrong build is a cheap instrument.** Pushing a value to an extreme makes the next
  observation binary, and a binary observation cannot be over-interpreted.
- **Vary the condition before generalising a measurement.** The same feature produced a second trap:
  the engine's grass sprites were captured while the player walked DOWN, which supported both "the
  lower tile draws in front" and "the tile being entered draws in front". Both were adopted in turn
  and both were wrong. One capture walking the other way would have killed both.

## A watchdog that names what it caught — 2026-08-20, Emerald

**The problem it solved.** A ghost stopped following entirely and stayed stopped. `ghostIsIdle`
already cleared a movement that FINISHED; nothing handled one that never does, and a blocked ghost
is never issued another step, so it strands for the rest of the session.

**Why a plain watchdog would have been a mistake.** Freeing the ghost after a timeout fixes the
symptom and hides the cause -- the fault becomes "occasionally the ghost lurches", which is far
harder to chase than "the ghost freezes". Logging the action id when it fires turned it into a
finding within one reload:

```
a ghost was stuck 61 frames in movement action 0x69 -- freeing it
a ghost was stuck 61 frames in movement action 0x6D -- freeing it
```

0x69/0x6B/0x6D are `ACRO_POP_WHEELIE_*` and `ACRO_END_WHEELIE_FACE_*` -- wheelie transitions that a
ghost cannot complete, presumably because they wait on `gPlayerAvatar.acroBikeState`, which only the
player has. That is now a written-down question instead of an intermittent glitch.

**The rules.**

- **A recovery mechanism must report what it recovered from.** Otherwise it converts a loud failure
  into a quiet one, which is worse.
- **Pick the timeout from what the game does, not from taste.** A step is 16 frames, the fastest 4,
  a ledge jump about 24 -- so 60 can only catch something genuinely stuck.

## Emerald: a ghost that reports the right pose and DISPLAYS the wrong one (2026-08-20)

**Symptom.** Idle on the Acro Bike, the spawned ghost wore the frame it should only have while
rolling -- *"it looks as if its tilted while idle, due to the 'while moving' animation making the
sprite move a bit back/forth left/right while pedaling"*. Facing up or down; the side-on frames hide
it, which is why it survived a left/right-only test. Correct for a moment after every script reload,
then wrong again after the next move.

**Why every existing trace denied it.** Player and ghost agreed on *every struct field* -- both on
animation `4/3`, unchanged for 180 frames. The adapter's `MESHGHOST_EMERALD_ANIM_TRACE` compares
those fields and the OAM entries, and it saw nothing.

**Cause.** An object event's frame image is copied into its own OBJ VRAM range when its animation
ADVANCES. A ghost standing still advances nothing, so it reported the standing pose and went on
displaying the last rolling frame it had been handed. The reload "fixed" it because the spawn path
does its own frame copy.

**Fix.** Copy the frame the peer is actually displaying when the ghost settles -- and **only once
the engine has let go**. A peer stopping does not stop the ghost: it is still a step or two behind
and keeps taking catch-up steps, each of which copies a rolling frame over ours. The first version
copied during that catch-up, measured `differing: 0`, and was then overwritten -- which the user saw
exactly: *"it only looks correct after stopping and then changing a facing direction"*, the turn
being the next thing to hand the tiles one last copy. Gate on `movementActionId` back to NONE.

**The method, which is the durable part: COMPARE THE TILES, NOT THE FIELDS.** When the fields all
agree and the screen does not, read the two sprites' OBJ VRAM ranges and count differing bytes --
`probes/posediff.lua`. It reported 120 of 512 while every field matched, and 0 after the fix.

## Emerald: one tile of bike travel cost the ghost a whole pedal cycle (2026-08-20)

**Symptom.** *"When moving a single tile, its 'over animating', the characther is not supposed to
wiggle from just 1 step, only when constantly biking in 1 direction"* -- spawned tier only.

**Cause, and it was in a table rather than in any animation code.** `FACE_ACTION` is
**walk-in-place-fast**, chosen deliberately in 2026-08-18 because that is how a walking player turns
(`PlayerTurnInPlace`), and a static `FACE_*` pose made a ghost snap round without animating. A RIDER
never turns on the spot -- turning is part of moving -- and a player stopped on the Acro Bike reports
the static poses `0x00..0x03` throughout. So on a bike both the turn and the settle were spending a
walk-in-place animation the player never performed, and a single tile buys two of them: measured with
`probes/onestep.lua`, one tile east cost the player ONE action and two frames of the pedal cycle, and
the ghost THREE actions and four.

**Fix.** On a bike, use the static `FACE_STILL_ACTION` for the turn and the settle. Both then
complete in one frame with no animation.

**The general lesson.** A constant chosen correctly for one state can be wrong for another, and the
comment saying why it was chosen is the thing that makes the wrongness invisible -- it reads as
settled. When a state animates too much, look at WHICH ACTION is being issued before looking at the
animation code.

## Emerald: the mount/dismount pose war — five hours, three wrong instruments (2026-08-20)

The spawned ghost wore the wrong pose after getting on or off a bike, and showed it *slower* than
the painted copy. User-confirmed fixed the same day. What made it expensive was not the bug — it
was that **three separate measuring instruments were wrong before the code was**, and each wrong
instrument produced a round of confident fixes aimed at nothing. Symptom → cause → fix for each:

**1. The player-tile comparison measured garbage, including its zeros.** `posediff.lua` compared
the ghost's OBJ VRAM range against the player's, taking the player's tile number from their
sprite's OAM attribute 2. That reads **0** — the player draws through a subsprite table with the
struct's own tile entry parked — so every byte compared "against the player" was whatever lived at
tile 0. Two fixes were reverted because this number said they changed nothing; one of them was
later re-applied unchanged and was the actual fix. *The tell:* the user said "walking looks fine"
while the probe insisted 376 of 512 bytes differed. When the user contradicts the meter, the meter
is the suspect — that rule is already in this file and it paid again. *Fix:* compare the ghost's
tiles against the **ROM frame** its animation names (`romDiff` in `posediff.lua`) — the ROM owes
nothing to either sprite. That column diagnosed in one reading what six field-level fixes missed.

**2. The measurement procedure erased the symptom before measuring it.** Every change to the
dev-loader's control file reloads the script set; a reload respawns the ghost; **the respawn path
loads the correct frame**. So every screenshot taken by first adding `shot_once.lua` to the target
photographed a freshly reset ghost — pixel-identical to the player, twice, in the exact state the
user was seeing wrong. The user's own screenshots finally showed the stride the agent's never
could. *Fix:* load every probe you might need in ONE set before the test starts, and never touch
the control file between the user's action and the reading. The general form is already this
file's "a diagnostic can break the thing it measures" — this is the variant where the *harness*
resets the state, and it is nastier because each individual reading is genuinely correct.

**3. Field agreement is not pixel agreement.** Player and ghost reported identical animation
number and index for 180 straight frames while displaying different frames. An object event's
frame image is only copied to VRAM when its animation *advances*; a paused sprite reports whatever
its fields say while displaying whatever was last copied. Every trace this adapter had compared
fields. *Fix:* the tile/ROM comparison above, now a standing probe.

**With honest instruments, the actual bugs took minutes each:**

- **The swap loaded a mid-transition frame and pinned it.** `swapGhostGraphicInPlace` sampled
  `sanim`/`sidx` from the wire at swap time — mid-transition, often a stride — and the
  paused-arrival meant nothing ever repainted it. Fix: the settle. A graphic change now arms
  `needsSettle` + `settleStatic`, and the **engine** sets the pose via the static face action —
  the user's own observation named the mechanism: *"it does get the correct/proper pose if you
  mount/dismount and then move 1 tile afterwards."* A settle is a zero-motion step.
- **The swap started an animation nobody was playing.** It set `animBeginning` unconditionally, so
  a standing peer's swap played a walk/pedal cycle out of nowhere until the settle caught it. Fix:
  gated on the peer's own paused bit — a paused peer's ghost arrives paused; a rod cast still
  animates.
- **Two latency sources, measured by frame-by-frame screenshot burst** (player changed at frame
  22, ghost at 29): the "never interrupt a half-played step" gate deferred swaps behind catch-up
  steps (fixed: non-fishing swaps land mid-step; the gate was measured in for fishing's offset and
  stays for fishing), and the sender's 6-frame graphic hold (fixed: skipped for the six known
  offset-free graphics — walker/Mach/Acro both genders — kept for anything else).

**The meta-lesson, worth more than any fix here: when N fixes in a row "don't work", stop fixing
and audit the instrument.** Six attempts failed against bad metrics; the seventh with a good
metric was one of the six, re-applied.

## Emerald: the seam-crossing frame-killer, and the two habits that hid it (2026-08-20)

**Symptom.** After cross-map ghosts shipped, crossing a route seam made the drawn ghost vanish and
the spawned one stop following — on the far side only, healing on return. Every internal
measurement insisted the paints were happening: position right, occlusion spans full, pixels
decoded, no dim, no panel clip.

**Cause.** The cross-map rebase, defined early in the file, referenced `ghosts` and `ghostAlive` —
locals defined a THOUSAND lines below it. Lua resolves those as nil globals silently, the function
threw, and because the throw landed before `lastKey` updated, it re-fired every frame on the far
side: the whole tick died after `gui.clearGraphics()` but before both the paint and the ghost sync.
Clear-without-repaint IS "the drawn ghost vanished"; no sync IS "the spawned one stopped".

**Why it took an hour: two observability habits, both now fixed.**

- **The per-frame error guard logged to the CONSOLE only.** Every file grep was blind to the one
  line that named the bug. The guard now writes to the log file too. *Rule: any catch-and-continue
  guard must write somewhere greppable.*
- **Instrumentation was added stage by stage INSIDE the suspect path** — mask, spans, decode, each
  measured innocent — when the tick was dying before the path ran at all. *Rule: when every stage
  of a path measures innocent, check whether the path executes on the failing side before
  instrumenting a fifth stage.* The magenta-box experiment (a probe drawing raw pixels with zero
  adapter logic) was the right instinct and mis-set-up twice; what finally broke the case was
  routing the guard's error to the log.

**The two Lua traps, for the next early-defined function:** a forward reference to a later local
is a nil GLOBAL, not an error, until you call or iterate it; and this file's 200-local ceiling
pushes shared state onto tables (`genderFrames.*`), which is also the correct fix — the rebase now
reaches `ghosts` through a field registered at the local's definition site.

**Related, same feature:** the ROM-scan self-location verified candidates against the LIVE map
header, so the player crossing a seam mid-pass invalidated the pass — in roaming play the scan
retried for minutes. A pass now snapshots its target at start. *General form: a multi-frame scan
must capture what it is looking for when it starts, not compare against a world that moves.*

## Emerald: the seam-crossing pop was the CORE's, and every adapter instrument measured innocent (2026-08-20)

**Symptom.** Every route crossing: the spawned follower vanished for ~9 frames and popped back;
the drawn twin lurched sideways (its pin to the spawned sprite broke) or flickered. A static
cross-map peer sailed through untouched.

**The chain that found it, worth more than the fix.** Frame-by-frame screenshot bursts of DRIVEN
crossings measured zero missing pixels — but the user's own crossings, captured the same way,
showed the 9-frame gap plainly (83→35→53 hat pixels). The difference was never speed or timing:
the driven test's ghosts crossed alongside the player inside the coast window, the user's followed
behind. Then one log line at the despawn site ended it: `remote=false` — the peer's ENTRY was
gone from the remotes table. Nothing in the adapter deletes entries; the core's `despawn_remote`
does. The core's cross-area filter (its own 2026-08-13 ADR, correct then) turned the one-delivery
lag of an echoed `area_id` into a despawn per crossing. **The static peer was immune because it is
injected adapter-side and never passes through the core — that asymmetry was the whole diagnosis,
once the user pointed it out.**

**Fix:** `render_all_areas` in the bridge hello (contract revision, ADR 2026-08-20): the adapter
that translates maps owns area visibility; the core delivers and decides nothing.

**The rules this adds:**
- **When every instrument inside a component measures innocent, suspect the component's INPUTS.**
  Four hours of adapter-side probes (pixels, spans, flags, coordinates) were all correct — the
  data they measured was being deleted upstream between measurements.
- **A driven reproduction must match the user's SHAPE, not just their action.** "Cross the seam"
  reproduced nothing until the followers trailed the way real play trails.
- **An asymmetric survivor is a bisection for free.** One peer immune + one peer affected =
  the difference between their code paths IS the bug's address. The user handed that over in one
  sentence: *"the static ghost stays fine all the time."*

## Emerald: the vanishing hat — the panel scanner's flicker, and six innocent suspects (2026-08-20)

**Symptom.** The DRAWN ghost's hat-top vanished at Mach speed, sustained, downward rides only,
restored on stopping or turning. The spawned ghost beside it: never affected. User-confirmed fixed
the same evening, including the hardest case (full speed built before a seam, descent through it).

**Cause.** `tiering.scanPanel()` reads BG0's tilemap with no notion of the map-name banner's
mid-flight tilemap redraws: riding at speed it flickered between "no panel" and "panel rows 0-4"
every few scans. Those rows are screen y 0-39 — exactly the band a TRAILING ghost's hat occupies
when the player rides DOWN (the follower trails up-screen). Riding up, the follower trails
down-screen, outside the band: the entire direction asymmetry, which the user kept correctly
insisting on, was geometry. The clip is drawn-tier-only by design, which is why the spawned ghost
never flickered — the second correct user observation that named the subsystem.

**Fix, two layers in `scanPanel`:** rows only clip when present in two consecutive scans (a real
panel is rock-stable), and rows 0-4 with LEFT-side spans — the banner's home, START menu spans
start right of midscreen — need a five-scan streak. An intermediate attempt gated those rows to a
time window after a map change instead: wrong, because riding away from a fresh crossing is
exactly when the user tests, so the window re-admitted the flicker for their whole ride. Stability
is the discriminator, not time.

**The six suspects that measured innocent first, in order — the expensive part:** occlusion spans
(384/384 kept, always), the screen edge (never nearer than y=28), the walker fallback (0 firings),
the ROM art (all twelve fast-family frames carry full hats — `probes/framedump.lua`), the frame
resolution (raw anim commands logged clean), and the emitted runs (min row 9, matching the art's
own top row exactly). The instrument that finally pointed upstream was `clipped=` — a counter that
already existed — read next to a per-frame panel-rows dump.

**Rules worth keeping:**
- **"Which direction breaks it" is data about GEOMETRY.** Down-only + drawn-only intersected to
  one subsystem before any code was read: something clipping the top screen band, painted tier
  only. The user supplied both halves; the mistake was not intersecting them sooner.
- **A visible ruler beats an invisible log when the user is the sensor.** One magenta line at the
  paint row let the user report the box-vs-art relationship directly — and its "1-1.5 heads above"
  reading turned out to be NORMAL (the art starts 9 rows into the box), which retired a whole
  false lead in one look.
- **When a fix depends on when the user tests, the fix is wrong.** The map-change window failed
  precisely because the user's habits sat inside it. A structural discriminator (stability) does
  not care who is testing.

## CI: "could not find a port free for both tcp and udp" — the draw was rigged, 2026-08-20

- **Symptom**: three `internal/e2e` tests fail together on the Windows CI runner with
  `could not find a port free for both tcp and udp after 20 attempts`, on code that passes locally
  and passed on the same runner earlier. Second occurrence; the first was 2026-08-16.
- **Cause**: the helper asked TCP for an ephemeral port and then probed UDP on that same number.
  That is backwards. Windows' WinNAT/Hyper-V reservations exclude blocks of the ephemeral range
  **from UDP** while TCP hands those numbers out happily, so every attempt was a fresh chance to
  draw a number UDP could never have accepted. On a runner whose exclusions cover much of the
  range, twenty draws can all lose — and because it is luck of the draw, a re-run "fixes" it and
  teaches nothing.
- **Fix**: ask the OS for a **UDP** port first and probe TCP on that number. The exclusions are
  then applied by the OS rather than gambled against, and the side being probed (TCP) is the one
  with no reservations. Attempts raised 20 → 200 (each is microseconds), and the failure message
  now carries the last error, because the old one named a count and hid the reason.
- **Generalizes to**: when two resources must agree on one identifier, let the OS choose on the
  **scarcer, more restricted** side and verify on the freer one. Retrying the unrestricted side
  is just re-rolling the same bad die.

## Emerald: ghosts blinking in and out in a doorway — two peers, one object slot (2026-08-20)

- **Symptom**: with two peers in the room, standing in front of a door made both tiers' ghosts pop
  in and out continuously. Away from the door it was fine.
- **Diagnosis**: the adapter's own logs could not show it, and that is the important part —
  everything it logs is PER PEER, so two peers writing one object is invisible by construction:
  each peer's lines look perfectly correct on their own. It was found by enumerating the engine's
  object array directly from a separate probe and watching a single slot, which alternated every 8
  frames between two peers' complete states (position, facing, action, graphic).
- **Cause**: `findFreeObjectSlot`/`findFreeSpriteSlot` tested the engine's **active bit** — "is this
  in use by the GAME" — and never "is it already claimed by one of OUR peers". A doorway is a warp
  tile, so the engine culls ghost slots constantly there; a culled slot reads inactive for the
  frames between the cull and the respawn, and a second peer searching in that window is handed a
  slot the first peer's record still names.
- **Fix**: both searches skip slots claimed by any tracked ghost, and a once-a-second audit logs
  `BUG -- <peer> and <peer> both hold object slot N` if it ever happens again by another route.
- **Generalizes to**: **"in use by the engine" and "in use by us" are different questions**, and
  wherever a shared resource is allocated by asking the engine, any window in which our own claim
  is invisible to that question is a collision waiting for a second consumer. Sprite slots, VRAM
  tile ranges and object slots all have this shape.
- **Second trap, paid for in the same pass**: this file is against Lua's **200-locals-per-chunk
  ceiling**. A new top-level `local function` failed the whole script with `too many local
  variables (limit is 200)` and the adapter simply did not load. Locals inside a function are free,
  so the claim scan is written as two inline loops on purpose — do not tidy it into a helper.

## Emerald: "laggy while moving" — a cull→respawn loop, console lines, and probes (2026-08-20)

- **Symptom**: the game chugging while running around, worst *"in 2 places consistently"* (the
  user's own observation, which beat the profiler to the cause). Scripted A/B ride: 45.9 avg fps,
  dips to 15, against a bare-emulator control of 58.1 / 37.
- **Cause, three stacked**: (1) **spawn churn** — the engine culls an object event that falls out
  of its view, and the adapter respawned it next frame, so a peer parked off-view was spawned and
  culled in a loop: VRAM allocation + sprite setup every cycle, 16 reclaims per ride clustered at
  the route's two seam crossings, worst frames 217ms. (2) The **reclaim message was a
  `console.log`** — a GUI append, the measured fps killer — firing exactly where the churn was.
  (3) **Per-frame probes** left loaded (hopwatch's 16-slot enumeration, the anim trace).
- **Fix**: never spawn a ghost outside a conservative subset of the visible screen (±8x/±7y of the
  player) — outside it the engine deletes the object anyway, so the spawn bought nothing; reclaim
  lines go to the log file only; probes come off when not answering a question. After: 56.9 avg,
  worst Lua frame 5ms, zero reclaims, user: *"it feels way better now"*.
- **Exonerated by A/B, not guessed at**: the BuildOamBuffer execute hook (52.0 without vs 52.6
  with) — the "obvious" suspect was innocent. The remaining transition hitch is VANILLA: the bare
  control dips to 37 on the same seam legs with no scripts loaded.
- **Generalizes to**: don't allocate what the engine will immediately free — a spawn decision has
  to ask "will this survive the engine's own housekeeping?", not just "is there a slot".

## The dev loader shares ONE Lua environment — an unset flag keeps its old value (2026-08-20)

- **Symptom**: an A/B run "with compare mode off" showed compare mode's exact cost profile; the
  anim trace ran on after being "turned off".
- **Cause**: `bizhawk-dev-loader.lua` loads every target into one shared environment, so a global
  set by an earlier flags file survives every later swap. A flags file that merely *doesn't set*
  a flag inherits whatever the last session set it to — "not mentioned" is not "off".
- **Fix**: the session flags file sets EVERY dev flag explicitly, false included.
- **Generalizes to**: any isolation run under the dev loader is invalid unless the flags file is
  exhaustive. Check the adapter's own `PROBE FLAG IN USE` startup lines — they say what is
  actually on, which is the ground truth the flags file only requests.

## Emerald: a NULL sprite callback is a SOFT RESET, not a glitch (2026-08-21)

**Symptom.** Building a real shadow sprite for a spawned ghost restarted the game on every jump --
user, 2026-08-20: *"everytime i jump with the bike, the game restarts now"*. It was switched off at
the door and stayed off.

**The theory recorded at the time was wrong, and plausibly so.** The adapter blamed the tile
allocation: a bad `SpriteFrameImage` byte count overrunning OBJ VRAM. That is a real failure mode,
this project has had a garbled-NPC incident from a tile range freed at the wrong moment, and
"corrupting VRAM ends in a reset" sounds right. It was innocent -- the frame is 64 bytes and two
tiles, now logged and range-checked at spawn so the next reader does not have to wonder.

**Cause.** The sprite was built with `callback = 0`, reasoning that the engine's own callback would
re-find its object by localId and follow the player. `AnimateSprites` (`src/sprite.c:308-322`) calls
`sprite->callback(sprite)` for EVERY sprite with `inUse` set and **has no null check** -- it never
needs one, because `sDummySprite` seeds `SpriteCallbackDummy` and `CreateSpriteAt` always copies the
template's. A zero there is a call to `0x00000000`: the GBA BIOS reset vector.

**Fix.** `SpriteCallbackDummy` (`08007428`, `pokeemerald.map` and `.sym`; the bytes there are
`70 47` = `bx lr`), checked at spawn rather than trusted -- on a relocated ROM that address is
something else, and the entire point of this entry is that a wrong callback is a reset.

**The method worth keeping: a RESET is a different CLASS of evidence from a glitch.** Corrupt
pixels, a wrong palette, a sprite in the wrong place -- data faults, and VRAM is the right place to
look. A reset means control flow left the program: a bad function pointer, a jump to an unmapped
address, a smashed stack. On a GBA, "the game restarts" is very nearly a signature for a call to
zero. Sorting the symptom into the right class first would have saved a day and a wrong write-up.

## Emerald: the frame rate went to ~1fps, and it was the ALLOCATOR, not the drawing (2026-08-21)

**Symptom.** After a session of dust/shadow work: *"feels like its chugging at like 1fps"*.

**Isolation, not theory.** Two guesses had already been spent, so the next move was subtraction:
`git checkout` the committed adapter in place, reload, ask. Smooth -- so the cost was in that
session's changes, mechanically and in one reload.

**Cause.** `allocSpriteTiles` imitates the engine's allocator by walking the 1024-tile OBJ bitmap,
so a **failed** call is the most expensive call it can make. Failures were not cached, so every live
dust puff and every jumping ghost re-ran that walk **every frame** -- and with three tiers up, OBJ
tiles are the first resource to run out, making the failing case the normal case on a busy map
rather than a rare one.

**Fix.** Cache negative results with a slow retry, cleared on the area change with the positive
ones. Separately, a 64-sprite scan for a live dust sprite (to copy its palette) had become
per-puff-per-frame once the trail existed; replaced with the engine's own `sSpritePaletteTags`
lookup (`03000CF0`, 16 entries), which is cheaper AND correct when no neighbour happens to be
landing.

**The rule: an expensive FAILURE path is the one to audit, not the expensive success path.** A cache
that only remembers successes does nothing exactly when the system is under pressure. Re-measured on
the stressed path -- 30s of continuous hopping, all three tiers -- `lowest 58.0, average 60.0`.

## Emerald: dressing a ghost in a direction its body is not performing (2026-08-21)

**Symptom.** A ghost turning while hopping looked wrong in a way three reports circled without
naming: *"facing the wrong direction"*, then *"stuck facing the direction it starts the jumping
with"*, then *"doing some extra/weird animation before swapping direction"*.

**Five attempts, four of which made it worse.** The turning point was writing them out as a table
(config vs outcome), which showed every attempt since the first had been fixing what the first one
caused. Attempt 1 silenced the animation mirror during jumps; that removed the only writer able to
turn a ghost at all, because a held-B hop is ONE repeating action so the engine never re-reads a
direction on its own, and `ghostIsIdle` is false for the whole of a continuous hop, closing every
other path in the same stroke.

**Cause, once measured** (`probes/facing_probe.lua` -- both characters' animation number, frame
index and both flip bits on one line):

```
P face=up act=75 anim=21 | G face=right act=77 anim=23   <- still hopping right, correct
P face=up act=75 anim=21 | G face=right act=77 anim=21   <- hopping RIGHT, wearing the UP sprite
P face=up act=75 anim=21 | G face=up    act=75 anim=21   <- action adopted, consistent
```

The mirror copies the peer's animation number instantly; the ghost's ACTION cannot change until its
bounce ends. Three frames of travelling one way dressed for another, every turn.

**Fix.** Mirror freely while both are performing the SAME action -- that is what keeps a pedal cycle
in step -- and stand aside while they disagree, leaving the engine to animate the hop the ghost is
actually doing.

**Two methods worth keeping.** When a fix makes a symptom CHANGE rather than go away, suspect the
fix. And an object's `facingDirection` is not what a character looks like -- the sprite's ANIMATION
NUMBER is, plus the hardware flip; two fixes were reasoned out from the object field while it was
already correct.

## Emerald: `sprite->hFlip` is a BASE, not the flip (2026-08-21)

**Symptom.** A ghost facing the mirror image of the peer -- but only after the animation next
advanced, which is why it survived a visual check.

**Cause.** `SetSpriteOamFlipBits` (`src/sprite.c:1246-1251`) computes the on-screen flip as
`hFlip ^ sprite->hFlip`: the struct field is a BASE that the animation command's own flip is XORed
against. A held-frame fix set the struct field AND the OAM bit, which reads correct for exactly as
long as the sprite stays paused and inverts the moment the engine advances that animation again.

**Fix.** Write the OAM bit only, as the engine does. Measured: player `hflipSpr=0 hflipOAM=1`,
ghost `hflipSpr=1 hflipOAM=1` -- the same picture now and the mirror image later.

## Emerald: a ghost that WALKS a tile the peer JUMPED gets no ground effects (2026-08-21)

**Symptom.** *"none of the ghosts have a shadow or dust, when doing the side hop"* -- and after the
shadow was fixed, the spawned ghost still had no dust.

**Cause, in two layers.** The Acro Bike's side hop is **not** an `ACRO_*` action:
`AcroBikeTransition_SideJump` (`src/bike.c:639-664`) calls `GetJumpMovementAction`, i.e. the plain
`JUMP_*` family at **0x42..0x45**, and the adapter's jump range started at 0x46 -- reading the ACRO
block alone could never have found it. Deeper: 0x42..0x45 was in neither the in-place nor the
travelling list, so the ghost never PERFORMED the hop, it stepped to the tile. The engine raises
landing dust from a jump FINISHING, so a ghost that walks the tile has nothing to raise it. Measured
over a run of side hops: **19 dust sprites, every one at dx=0** -- the player's own, none for the
ghost.

**Fix.** Perform the action verbatim, like a ledge hop, and let the engine give the ghost the arc,
the dust and the landing. Painting a puff ourselves would have hidden the real defect.

**Two consequences, both the engine's own mechanism.** A side hop travels sideways WITHOUT turning,
and the engine says so with `facingDirectionLocked` set *before* the jump is issued -- `InitJump`
opens with `SetObjectEventDirection`, which would otherwise turn the character. And that lock must
be released when the peer stops side hopping, not when the ghost next stands still: held too long it
pins facing through the steps that follow (`AcroBikeHandleInputSidewaysJump`, `src/bike.c:518-523`,
releases it on the input tick after the jump).

**The rule: "it has no X" is often "it never did the thing that produces X".** Two rounds went into
where to draw a puff before anyone asked whether the ghost was jumping at all.

## Emerald: a remembered riding style outlived the peer's actual one (2026-08-21)

**Symptom.** *"the spawned ghost is also 'jumping/doing the dust' when just riding left/right on the
bike normally"*, and later the same shape again with wheelies.

**Cause.** `lastAcroBase` is a fallback for the frames where a peer has already stopped while the
ghost still owes a tile. It remembered whichever acro family came last -- including the hop families
-- and was consulted *before* `base`, which is derived from the peer's CURRENT `movementActionId`.
One wheelie hop therefore turned every later catch-up step into a hop, dust and all.

**Fix.** Never remember a hop family, and let live data beat remembered data: where `base` exists it
wins, and the memory is dropped outright.

**The rule: a fallback must never outrank the real thing.** A cache of "how this peer moves"
consulted before "what this peer is doing right now" is not a fallback, it is a stale override.

## Emerald: the ghost stopped hopping when it had nothing to cross (2026-08-21)

**Symptom.** *"its turning around a bit slow while jumping around and changing facing direction"* --
the last thing between the Acro Bike and finished, and the one most tempting to write off as
network delay.

**Why it was nearly recorded as a known gap, wrongly.** The reasoning was that neither the player
nor a ghost may change hop direction mid-arc -- true -- so a turn waits for a bounce boundary, and
the ghost's boundaries sit a wire-delay behind the player's. That story is coherent, matches the
symptom, and is exactly the kind of explanation that closes an investigation. The user refused it on
the project's own rule: *"the player can, so the ghost must ... no excuses for not making it match"*.

**Cause, measured in one pass** by frame-stamping `probes/facing_probe.lua`:

```
f=240 P=77 G=73     peer starts hopping right
f=243 P=77 G=FF     ghost action NONE -- idle, not mid-bounce
f=251 P=77 G=77     adopted, eleven frames late
```

The ghost was FREE at 243 and did nothing for eight frames. The wheelie-hop families are handled as
animation-only, so those hops are performed only as part of covering a tile -- caught up with the
peer, the ghost stopped bouncing and waited for ground to cross, and since a turn is only adopted
when an action is issued, the turn waited for that step too. None of the eleven frames was the wire.

**Fix.** A peer who is hopping has a ghost that is hopping: re-issue the peer's hop each time the
ghost comes free, which keeps its bounces in step with the peer's rather than on a grid of its own.
Re-measured: adoption gap **0 frames**, and **zero** frames of `act=NONE` across the capture.

**The rule: "it is the network" is a hypothesis, not an explanation, until a frame counter says so.**
Latency is the most available excuse in a multiplayer project and it costs nothing to state; here it
was wrong, and one frame-stamped capture separated eight frames of adapter stall from a wire delay
that measured zero.

---

## 2026-08-21 (later) -- method notes from the water/warp session

Five defects in one sitting, four found by the user with three renderers on screen. The fixes are
in `verified.md`; what follows is how they were FOUND, which outlasts them.

### A compensation is only measured where it was measured

The painted tier's two ways of hiding a ghost through a transition -- the invisible bit on the
player's sprite, and scene brightness -- were both built and confirmed on a HOUSE DOOR. A cave
mouth is a warp with **no door animation**, so the invisible bit never sets, and it fades to
**white**, which a downward-only brightness ratio reads as a perfectly normal scene. Neither
mechanism fired and nobody had ever asked whether they would.

**The move:** when a compensation has a gate, enumerate the situations that reach it before
believing it covers them. "Confirmed on screen" names one situation, not a class.

### A ratio is the wrong SHAPE for a blend, and the wrong shape cannot be tuned

`live/ROM` clamped to 1 can only express fading toward black. The engine's fades are
`BlendPalette` -- a move toward one target colour -- so fitting `live = a*rom + b` recovers the
whole family (black, white, cave tint, weather, night) in one expression. **A gate that is blind
in one direction is a modelling error; no threshold fixes it.**

### COMPARE MODE PINS, so it is blind to everything about the unpinned path

Both self-drawn tiers took a peer's jump arc from the spawned sprite they are pinned to. An
overflow peer has no spawned sprite, so it slid across ledges with no arc and (painted) no shadow
-- and **the mode built for comparing renderers is the one mode that cannot show this**, because
pinning is what it does.

**The move:** every quantity a tier reads from the pinned source needs an explicit answer for
"where does this come from when there is nothing to pin to?", and that answer can only be tested
with compare mode OFF. The same applies to any future pinned comparison.

### A local declared BELOW a function is a nil global inside it -- twice in one session

This file already carries the warning, and it was still walked into twice on the same afternoon.
The second one referenced `SURFING_GFX` from a helper defined ~200 lines above its `local`
declaration; it threw once per frame from inside the draw path, aborted the whole tick, and took
the painted ghost off the screen along with the hardware tier's reflection. The user saw it as
*"the drawn ghost is not visible, and the OAM lost its reflection ? did you break/regress
something ?"* -- i.e. **a scope slip presents as a feature regression, not as an error**, because
the error goes to a log nobody is watching.

**The move:** when adding a helper high in this file, check every non-local name it uses against
where that name is declared -- and read the log for `frame error` before believing any report about
what is or is not on screen. It is the first thing to grep, not the last.

### Ask the ENGINE'S OWN SPRITE for ground truth, not the decompilation

Two questions were settled in one read each, with no derivation to get wrong:

- *"where does a reflection actually go?"* -- read the live reflection sprite's `pos1 + ctc + pos2`
  against the player's: drawn top 208 against 238, i.e. `height - 2`, exactly.
- *"is our OAM entry the same as the engine's?"* -- dump both entries and decode them. Ours came
  back **byte-identical in geometry** to the engine's own (`y=86, 16x32, affine=1, matrix 0,
  palette 1`), which retires a whole class of "it looks slightly off" without another guess.

**The hardware tier is measurable in a way the painted one is not**: its output IS OAM, so it can
be compared to the engine's output field by field. Use that before asking anyone to look.

### A savestate load orphans field-effect sprites, and the orphan sweep cannot see them

Loading a state rewinds the GAME's sprites but not the adapter's Lua bookkeeping, so a blob from
the restored state survives alongside the one the adapter then makes -- and it keeps following the
object event id it names, which is now the new ghost. Two blobs on one ghost. The object-slot
orphan sweep cannot catch it because **a blob has no object event**; the engine's own
`ResetSpriteData` clears it at the next map load, which is what the user saw: *"the extra blob went
away if i went into a house and out again"*.

Dev artefact, not a shipping bug -- but the count is what said so (`objEvent=0` is the player's,
`objEvent=15` the ghost's, one each), not the reasoning. **That verdict was too narrow: the same
event breaks OBJ TILE OWNERSHIP too, and that half IS a shipping bug** -- see the next entry.

### A driven run needs the test kit loaded, or it measures an encounter

`grant_test_kit.lua` tops Repel up every half second while it is loaded, and it was not in the
loader set. A ten-second scripted surf walked into a wild battle, and the probe run captured the
battle-transition sprites instead of ripples. **Anything that drives the player for a measurement
should have the kit in the same target set.**

### Never judge a subject against an instrument you have not checked -- the costliest lesson here

A long stretch of 2026-08-21 went into "the drawn ghost has no reflection a tile from the water",
comparing the painted tier against the SPAWNED one -- while the spawned one was itself stuck in the
wrong pose and therefore showing a different picture. Every comparison was between two unequal
things, and every conclusion drawn from it was wrong. The user ended it in one sentence: *"you are
trying to test/compare to something, that is not displaying it due to another issue."*

Fixing the pose first made the same question answerable in a single measurement.

**The move:** before comparing tier A against tier B, establish that B is correct -- against the
ENGINE, or against a fact that does not depend on B. `CLAUDE.md` already says the instrument is the
suspect before the subject; this is that rule applied to a renderer being used as a reference.

### Measure the target's BEHAVIOUR, not just its position, before changing how you draw it

The reflection's horizontal ripple took two wrong fixes on the user's screen -- one that inflated a
one-pixel run to three, one that froze it in place -- because each was reasoned from the formula
rather than measured. **Six screenshots of the engine's own reflection, diffed against each other,
gave the width AND the movement in one step** (one pixel, alternating between two columns), and the
correct rule followed immediately.

A single frame answers "where is it". Only several frames answer "what does it DO", and a scaling
rule is a claim about what it does.

### Fields are not pixels

A ghost whose `animNum`, `animCmdIndex` and `animPaused` all read correct was still showing the
wrong picture, because the engine had copied a different frame into its tiles and then held there.
Reading back the actual VRAM art rows is what settled it -- `artRows=11..31` where the requested
image's own art is `10..30`.

**Asking "what did I set?" is not asking "what is on screen?"** For anything tile-based, read the
tiles.

### Reproducing a hardware transform: invert ITS mapping, don't transform your bounds

The ripple's horizontal scale was wrong twice because both attempts scaled the SOURCE run's
endpoints onto the screen. Hardware does not work that way. A GBA affine sprite walks the
DESTINATION and, for each screen pixel, samples `texture = (x - cx) * a / 256 + cx` and truncates.
Inverting that gives the destination range covering a source run `[x1, x2]`:

```
x_dest in [ cx + (x1 - cx)*s , cx + (x2 + 1 - cx)*s )        s = 256/a
```

— ceil at both ends, far edge as `x2+1` then brought back. **The same rule at both ends is what
preserves width**, and the two failures are each diagnostic of a specific mistake:

| What was done | What it looks like on screen |
| --- | --- |
| different rounding per edge (`floor` / `ceil`) | narrow runs INFLATE, and breathe as the scale swings |
| same rounding, but forward-mapped (nearest-neighbour) | width correct, but a small feature never moves — sub-pixel shifts round away |

**Generalises past this one case:** whenever reproducing something the PPU does, write down what
the hardware does per destination pixel and invert it. Transforming source extents is a different
operation that happens to agree in the easy cases.

### A diagnostic that re-implements what it measures will lie the moment one of them changes

The reflection's ink range was logged by a line that recomputed the flip itself rather than
reporting what the draw had done. The draw was fixed; the log was not; the next reading showed the
OLD numbers and briefly read as "the fix did nothing". Two minutes were spent doubting a correct
fix.

**The move:** either have the diagnostic report values the code actually used (compute once, pass
it to both), or change them in the same edit — and treat "the numbers did not move at all after a
change that should have moved them" as a suspicion about the instrument first.

## Emerald: a savestate load makes us draw from tiles we no longer own (2026-08-21)

**Symptom.** The hardware (OAM) tier renders as black-and-white striped garbage after a savestate
load -- body and reflection alike -- and gets worse with each load. The user, twice: *"the OAM gets
weird after save states"*, then *"the OAM sprite broke completely now after a save state"*.

**Cause.** Everything this adapter holds about the engine describes the machine *as it was*: which
object slots the ghosts occupy, which OBJ tile ranges we claimed out of the engine's own allocation
bitmap, which hardware OAM entries we own. A state load rewinds the engine's side of all three at
once and leaves our record untouched. From the next frame we copy sprite frames into tiles the
engine has since handed to one of its own sprites, and draw our characters out of the same range.

**Fix.** Detect the load and **forget**, rather than clean up. The tell is not in the game at all --
it is the emulator's frame counter, which advances by exactly one per tick and *jumps* when a state
is loaded (either direction). On a jump: release the hardware tier without freeing, drop every
ghost record, and discard the queued tile frees. Freeing "our" tiles there would clear bits in a
bitmap that is somebody else's now -- the same identity-first rule `despawnGhost` already follows
for a map load, with the same silent consequence if ignored.

**Two lessons past the fix:**

- **It is a SHIPPED bug, not a rig one.** Loading a state is ordinary BizHawk use. The instinct to
  file anything savestate-shaped as a dev artefact is what left the earlier entry above half-right.
- **A savestate replay cannot judge the hardware tier.** A whole diagnosis nearly went the wrong
  way on this: the striped garbage was filmed frame by frame off a state-load replay and read as a
  32x32-graphic bug in the tier. Re-running with the state loaded FIRST and the adapter loaded
  AFTER it -- so its bookkeeping starts from the world that actually exists -- produced clean
  frames. **Load the state, then attach the thing under test.**

## Emerald: a graphic swap left fresh tiles unwritten, and the ghost went grey (2026-08-21)

**Symptom.** The spawned ghost occasionally turns into a grey/garbled block at the start of
surfing -- *"the spawned ghost glitch out sometimes when starting surf"* -- and only sometimes.

**Cause.** A graphic change claims a NEW tile range and points the sprite at it before copying the
frame's pixels in. The frame is resolved through the peer's reported animation number -- which
belongs to the graphic the peer *just left*. Every special state carries its own animation table,
and they are not the same length (`sAnimTable_FieldMove` against `sAnimTable_Standard`), so a peer
mid-way through a high-numbered animation indexes past the end of the new graphic's table, reads
whatever ROM follows, and the copy is abandoned as unresolvable. The sprite is then drawing from
VRAM nobody has written. Whether it happened depended on which animation the peer was in when the
graphic changed -- hence "sometimes".

**Fix.** Fall back to the graphic's own first frame when the peer's animation cannot be resolved.
A ghost briefly facing the wrong way is a small, legible wrongness; a grey block is not.

**The general shape, which is the part worth keeping:** an early return is safe when it leaves the
previous state in place, and unsafe when the caller has already half-applied a change. Here the
pointer swap had already happened, so "do nothing" meant "draw rubbish". **Ask what the caller has
already done before returning early.**

## Emerald: THE PAIR was wrong -- and fixing it did NOT clear the symptoms (2026-08-21)

**CORRECTION, same day, and the reason this header changed.** The entry below was written when the
probe went clean, and it presents the incoherent pair as THE single cause -- a claim the user never
confirmed and the screen then contradicted: *"its not fixed. the drawn ghost still goes away for a
tiny bit... and the spawned ghost still does the grey/flash."* The pair was real, measured, and
worth fixing -- but it was not the (whole) cause of either symptom. The entry stands as a record of
a correct measurement wrongly promoted to a diagnosis, which is itself the pitfall: **a probe
going clean is not the defect going away, and writing "cause" before the user has watched the fix
is the same violation as writing "confirmed" on a build.** What the pair fix provably did (stored
state and VRAM checks clean across a scripted run) is in the commit; what it did on screen is: not
enough.

**Symptoms, reported as three separate things across an hour:** the spawned ghost flashes grey at
the start of surfing, every few attempts; the drawn ghost *"disappears for a bit"* at the same
moment; the hardware (OAM) copy is perfect throughout. That last one is not a footnote — it is the
clue that solves the other two.

**Cause, single.** The receive path adopted a peer's GRAPHIC one update late (a debounce that
exists for fishing, whose sprite offset lands four frames after its graphic) while adopting the
peer's ANIMATION NUMBER immediately. For one update per transition the ghost therefore held a
(graphic, animation) pair the player is never in. An animation number only means something for its
own graphic -- the tables differ in length -- so:

- the SPAWNED tier resolved that pair to a frame that does not exist and drew unwritten VRAM (grey);
- the PAINTED tier could not resolve it either, gave up, and fell back to painting a walker;
- the HARDWARE tier was fine **because it resolves the graphic and the animation together itself,
  every frame, instead of consuming the stored pair**.

**"One tier is perfect" is a diagnosis, not a curiosity.** Three tiers rendering the same peer is a
built-in control: whatever the healthy one does differently IS the fix. It was in front of me for
several cycles while I wrote per-tier defences.

**What it cost, and the rule that would have saved it.** Four fixes were written before the pair
itself was measured -- a fallback frame, a mirror gate, a send-side hold, an action deferral --
each plausible, each treating a consumer. The measurement that ended it took one probe line: log
the PLAYER's own (graphic, animation) every time either changes. It goes `gfx=3 anim=0/0..0/4` then
straight to `gfx=2 anim=20/0`; the intermediate pair never happens. **When several consumers of one
piece of state each break differently, measure the STATE, not the consumers.**

**A second-order trap, worth its own line:** a savestate replay driven by a script is
DETERMINISTIC. Eight "attempts" produced byte-identical screenshots, which reads exactly like "the
bug is fixed" and means "the bug was never given a chance to appear". An intermittent defect that a
person hits every two or three tries is being sampled by their TIMING -- so a driver has to vary
its input phase per round or it is running one attempt N times.

## Emerald: the mount-blob saga — every authority for "where" lies during a transition (2026-08-21)

Placing one sprite (the surf blob a mounting ghost jumps onto) took five attempts, each defeated
by a different lying authority. The list is the lesson:

1. **The ghost's own coordinates** — the swap runs before the jump is issued (the swap-pending
   gate orders them), so they still name the land tile.
2. **The wire position** — the sender publishes the SMOOTHED glide, not raw coordinates, so
   during a jump it lags at the origin. Never treat a wire position as a discrete destination.
3. **`spawnSurfBlob`'s screen math** — carries the two camera terms that only cancel while the
   camera is at rest (`documentation.md` warned about exactly this sprite), and a mount jump is
   precisely when the camera moves. Logged born at the correct water TILE while the user watched
   it sit on the grass: tile bookkeeping and pixel placement are separate claims.
4. **The rider's sprite position** — engine-maintained and camera-correct, but the sprite
   ANIMATES across the jump rather than snapping, so at the accept frame it still stands ashore.
5. **What finally worked**: rider's sprite position + one tile along the jump's direction (the
   action id carries it) + the blob's measured (0,+8) seat — every term engine-maintained or
   constant.

Also met again, fourth time today: **a gate on one spawn site does nothing about the others** —
the blob had three birth sites (swap, rebuild-spawn, catch-up) and each needed the mid-mount gate;
the fix that ended the guessing was making every birth LOG its site and tile.

And the bob/arc conflation: on these tiers the body's `pos2` is the surf BOB in steady state and
the JUMP ARC mid-jump. Subtracting it from the blob to fix the jump also froze the blob's bobbing
-- *"the blob is not going up/down"*. One field, two meanings, keyed by whether a jump action is
live; handle them by state, not by arithmetic.

## Emerald: never hold an engine handle the engine can recycle (2026-08-21)

**Symptom.** Diving black-screened the GAME -- palettes zeroed, effect stuck -- after its banner
showed the wrong Pokemon. Nothing in the adapter errored; the adapter was, by its own logs,
running perfectly underwater.

**Cause.** Our underwater bobber: a faithful copy of the engine's dummy sprite, whose callback
holds ANOTHER SPRITE'S INDEX and nudges it every fourth frame. When the named slot was reused, the
bobber went on nudging whatever now lived there -- during a dive, the show-mon's Pokemon picture --
which corrupted the pic and stalled the effect waiting on it.

**The rule.** The engine may store an object id or sprite index because it owns every lifetime
involved: it creates, destroys and reuses those slots, and its effects end when it says so. We own
none of that. **Copy the EFFECT, not the data structure** -- and when the effect is already
described by something on the wire (the peer's own sprite offset, here), copy nothing at all.

**Two corollaries, both paid for the same evening:**

- The intermediate fix -- driving the same bob from Lua -- was safe but still wrong: the peer's
  offset was already being applied, so the ghost had two writers on one field and jittered.
  Before adding a driver, check whether the wire already carries the thing.
- A tier can be structurally unable to draw somewhere, and that is not a bug to fix. Our hardware
  tier lives in OAM entries 64+, where ties are broken by index; underwater the game covers the
  screen in its own semi-transparent sprites at lower indices, so nothing we put there can appear,
  and raising our priority to escape only makes the fog draw opaque around us. The answer is to
  stand the tier down where it cannot win and let another tier carry those peers.

## Emerald: a gate written for ANIMATION also swallowed a POSITION (2026-08-21)

**Symptom.** Underwater, ghosts bobbed while idle and went rigid the moment they moved.

**Cause.** The peer's sprite offset is applied inside the animation-mirror gate, which
deliberately stands aside for a walking peer -- correct for animations, because the engine drives a
moving ghost's walk cycle and mirroring on top of it puts two writers on one field. But an offset
is not an animation: underwater it IS the bob, and the engine drives nothing for our ghost there
(we deliberately do not reproduce its bobber). So the bob was gated off exactly when the peer moved.

**The rule.** When a gate exists to arbitrate one KIND of state, check what else has been parked
inside it. Animation, position, offset and graphic have different owners at different moments; a
condition that is right for one is arbitrary for the others.

## Emerald: three renderers are a control group -- use them (2026-08-21)

Twice in one session the user's report named which tiers misbehaved, and the tier they did NOT
name was the answer:

- The orange sprite appeared on the spawned and painted copies. The hardware tier -- the one that
  behaved -- was the only one resolving the surf blob's palette from its TAG through the engine's
  table instead of hardcoding slot 0. The show-mon effect had taken slot 0 for a Pokemon.
- The incoherent (graphic, animation) pair broke the spawned and painted copies while the hardware
  one stayed correct, because that tier resolves both together itself every frame rather than
  consuming the stored pair.

**When one renderer of the same peer behaves and the others do not, diff what it does differently
before forming any theory.** It is a free A/B that is already running.

## A probe written for one session leaked a home path into the repo (2026-08-21)

**Superseded as a procedure — see the 2026-08-24 hook note on the 2026-08-15 entry above.** This
is the third recorded instance of one class; the leak check is mechanical now.

Two probes written during the dive session hardcoded an absolute scratchpad path for their
screenshots -- convenient while driving the session, and a violation the moment they were
committed: this repo is public and no tracked file may carry a home directory. `CLAUDE.md`'s own
`git grep` check caught it after the commit, not before.

**The habit that prevents it:** a probe resolves its own directory (`debug.getinfo`) for anything
it writes, exactly as its log file already does -- there is never a reason for a second, absolute
path in the same script. Run the repo-cleanliness grep before committing anything written in a
hurry, not only before a release.

## Emerald: one field, two meanings — "not animating" is not "may not animate" (2026-08-21)

**Symptom.** On Shoal Cave's ice the player glides with its legs held still; the spawned and
painted ghosts stride across it. The OAM tier was correct all along, which is the clue.

**Diagnosis.** `spaused` (the sprite's `animPaused`) was already on the wire and means *the
animation is not running*. `disableAnim`, on the object event, means *this object is FORBIDDEN
one* — and unlike the first, a movement cannot override it. Everywhere else in the game the two
agree, so one bit had always been enough. `ForcedMovement_Slide` is where they come apart: it sets
`disableAnim` and then walks the character fast, which is a character crossing tiles with its legs
still. The OAM tier looked right for free because it copies the peer's `animNum`/`animCmdIndex`
straight from the wire, and those simply stop advancing.

**Fix.** Send the bit (`extras.noanim`) and let it beat the three separate things that were each
undoing it: `requestAction`'s `enableAnim` rescue, the mirror's "the engine is already driving
this graphic" gate, and the painted tier's distance-derived cycle.

**The lesson, which is general.** *When one tier of three is already correct, ask what IT is
reading.* The correct tier is a free bisection: it was consuming the peer's state directly, and
the two wrong ones were each re-deriving it. Re-derivation is where a state gets lost.

**And a rule about sticky bits.** `disableAnim` is only ever cleared by the engine through
`enableAnim`. Setting an engine flag on a ghost obliges you to clear it in the same place, on the
same path — a flag set once and never cleared costs that ghost the behaviour for the rest of the
session, which is worse than the defect it fixed.

## Emerald: a "hold the pose" fix must hold the RIGHT pose (2026-08-21)

**Symptom.** Nearly invisible, and the reason to write it down: an ice slide freezes the character
on **whatever frame the walk cycle happened to be on** when it started. Measured across three runs
the player held `10/2`, `11/0`, `11/2`.

**Why it matters.** "Freeze the animation" invites two wrong implementations that both look right
in a single test: freeze on the *first* frame of the animation, or freeze on *whatever frame this
renderer had reached*. The first is correct about a quarter of the time; the second is a different
picture from the player's every time. Neither fails loudly — they produce an intermittent,
low-grade wrongness that reads as "close enough".

**Fix.** Resolve the peer's OWN image the engine's way — anim table by `animNum`, then by
`animCmdIndex`, low half is the image index (`genderFrames.peerImageIndex`) — and check it lands in
the same index space as the tier's own table before using it. The peer's `11/0` resolved to image
7, which is `DIRECTION_ANIM.east.steps[1]`; the tier had been drawing image 2, the standing frame.

## Emerald: the drawn tier's freeze has to outlast the peer's flag (2026-08-21)

**Symptom.** With the freeze correct, the painted ghost played one extra stride *as it stopped*
(*"1 extra animation or something when stopping after gliding on the ice"*).

**Diagnosis.** The wire flag clears the instant the player's slide ends, but the painted copy is
still GLIDING across the ground that slide covered. Releasing on the flag handed those catch-up
frames back to the distance-derived cycle.

**Fix.** Latch the freeze to the glide, not to the flag, and hold a frame remembered from when it
started — by release time the peer is already on its idle frame, which is not the picture a copy
still moving should wear. Reset `gDist` too: none of the distance covered while frozen was walked,
and leaving it merely moves the same stride one step later.

**The lesson.** *A self-drawn tier is not where the peer is, so a peer's state flag is not a
schedule for that tier.* Anything gated on peer state that this tier renders with a lag has to be
released on the tier's own progress. Conspicuous here and nowhere else only because the player
animates through an ordinary stop and does not animate through this one.

## Emerald: a floor that is right for a sub-pixel gap is wrong for a real distance (2026-08-21)

**Symptom.** The drawn ghost *"doing the ending part a bit slow"* after a slide.

**Diagnosis, from `probes/tier_compare.log` rather than by eye.** The glide's speed limit is
`max(tspd, 0.02) * 1.25`. When the peer stops, `tspd` falls away and the limit drops to the
`0.02 tiles/frame` floor — so whatever ground the copy still owed was paid off at a crawl however
far it was. A slide is fast and the position stream is bursty, so after one it owed most of a
tile: **0.86 tiles closing at 0.025/frame = 34 frames, over half a second of creep after the
player had come to rest.** Fixed by holding the travelling speed as the floor until the copy has
arrived: 0.50 tiles at 0.0625/frame = 8 frames, which is exactly the 8-frame delay line this tier
reproduces on purpose, then a dead stop.

**THE PART THAT NEARLY SHIPPED WRONG, and the real lesson.** The first version assigned
`gSpd = tspd` on every frame above the threshold. But `tspd` is an **8-frame average**, so when
the peer stops it does not drop to zero — it DECAYS across the window, walking the floor down with
it and leaving the last value above the threshold: 0.023 against a travelling 0.0625. The measured
tail went 0.025 -> 0.029/frame. **A fix that moves the number by 15% is a wrong fix, not a partial
one** — and re-measuring is the only thing that says so, because by eye "still a bit slow" and
"unchanged" are the same report. Hold the high-water mark, and clear it on arrival so it cannot
leak into the next movement.

## Emerald: `goto_map` changed the map and placed nobody (2026-08-21)

**Symptom.** The user warped somewhere and could not move in any direction, on a screen of open
water with no land in it. Twice.

**Diagnosis.** The probe's header asserted that `CB2_LoadMap` runs `WarpIntoMap`. It does not —
that path is `CB2_DoChangeMap -> CB2_LoadMap2 -> DoMapLoadLoop`, and `WarpIntoMap`, the only
caller of `SetPlayerCoordsFromWarp`, is nowhere on it. The map loaded; the coordinates stayed.
Invisible because every warp had been to Mauville (40x20) from somewhere small.
Warping out of Route 126 at (45,68) into Mossdeep City (80x40) left the player outside the map in
the border fill, with `MAPGRID_UNDEFINED` on every side.

**Fix.** Write `gSaveBlock1Ptr->pos` as well, from `MESHGHOST_WARP_X/_Y` taken from the
destination's own warp event in `data/maps/<Map>/map.json`; warn loudly when they are not given.

**Two lessons.** *A dev tool that has only ever been pointed at one destination has only ever been
tested for one destination* — this one had a hardcoded Mauville default and a caller who never
changed it, so its single most important behaviour was never exercised. And **"the user is stuck"
is a bug report about our tooling**: the instinct was to reach for a savestate, which would have
hidden it. Reading what the callback chain actually does took minutes and found a week-old defect.

**One thing that needed no fixing, worth knowing:** the map load re-derives the avatar state from
the tile landed on (`GetAdjustedInitialTransitionFlags`), so a SURFING player warped onto a cave
floor arrives on foot with no blob to clean up.

## A fix named after WHERE it was found will be re-found somewhere else (Emerald, 2026-08-21)

**Symptom.** The OAM ghost invisible in Mt Pyre's fog — a bug fixed earlier the same session, underwater.

**Diagnosis.** The dive fix was correct and its predicate was `is the player underwater`, because
underwater is where it was seen. The actual cause is *the engine is tiling the screen with
semi-transparent sprites at low OAM entries*, which is also true of weather fog on dry land. The
same code, the same measurement, a second bug report.

**Fix.** Test the cause: count objMode-1 sprites among the engine's entries. `underwater` was never
a property of the failure — it was a property of the afternoon.

**The rule.** *When a fix's condition names a place, a mode, or a map, ask what is TRUE there that
breaks it, and whether that thing can be asked about directly.* If it can, ask it. A place-shaped
predicate silently scopes the fix to the one instance you happened to be standing in.

## An explanation that only fits your own case is not an explanation (Emerald, 2026-08-21)

**What was recorded underwater:** *"a semi-transparent sprite cannot blend against another sprite,
and gives up and draws opaque."* It explained the observation, it was measured at two priorities,
and it is wrong.

**What disproves it, and it was on screen the whole time:** the engine's own character is in front
of the same semi-transparent sheet, in the same frame, with no artifact. Any explanation of the
form "the hardware cannot do X" has to survive the game itself doing X ten pixels away.

**The real distinction was HOW you get in front.** The player wins at *equal priority on a lower
entry number*, which leaves the sheet's blend target unchanged. We can only win by *outranking it
on priority*, which changes the layer the blend resolves against, and then it fails. Same visible
outcome, completely different cause — and only the second one predicts that the artifact is one
opaque block **per entry rectangle** (16×32 in fog, ~3×3 tiles underwater with a wider graphic and
more entries). The user's own two descriptions, taken together, are what forced the better model.

**The habit.** When you write down a hardware or engine limit, look for the engine doing the thing
you just called impossible. If it is, your rule is about YOUR configuration, not the hardware —
and it will generalise wrongly the first time the configuration changes.

## Emerald: the painted tier is outside the PPU, so every hardware effect is its problem (2026-08-21)

**Symptom.** *"drawn ghost is not hidden in darkness/caves"* — in Granite Cave the painted copy
shines through the black while the spawned and OAM copies are correctly hidden.

**Diagnosis.** A dark cave is **Window 0**, not an overlay: the engine writes the lit span per
scanline into the scanline-effect buffer and DMAs it to `REG_WIN0H` each HBlank, so outside the
circle nothing is displayed. Real sprites are clipped by the window for free. The painted tier
paints with `gui.drawPixel` after the PPU has finished, where windows no longer exist.

**Fix.** Read the same spans and intersect each painted row with its own — one halfword per row.

**The general shape, and it is the third instance.** Everything the hardware does for a sprite,
this tier has to do for itself, and each one is discovered as a bug rather than anticipated:
occlusion by a text panel (`scanPanel`), reflection clipping to water (`reflectiveSpans`), and now
the flash window. **When adding anything to the painted tier, the question to ask is "what would
the PPU have done to this, and can I read it?"** Sometimes the answer is yes and cheap — the flash
circle is readable data. Sometimes it is no, and then the tier is the wrong renderer for that
situation (see the semi-transparent sheet entry above).

## A clip's GATE is more dangerous than the clip (Emerald, 2026-08-21)

**The trap.** The flash clip's data is a per-scanline buffer of lit spans, and an inactive buffer
reads as all zeroes — *nothing lit anywhere*. Trusting it unconditionally would not have produced a
subtle error; it would have **erased the painted tier on every ordinary map**, far from the cave
that motivated it and long after the change looked good.

**The habit.** When a new clip's "no data" state is indistinguishable from "clip everything",
confirm the effect at its SOURCE rather than inferring it from the data. Here that is
`gScanlineEffect.dmaDest == REG_WIN0H` with a non-zero `state`, so a scanline effect on another
register leaves the tier alone.

**And test the negative case, not the motivating one.** The cave is where it obviously works; the
regression lives on the ordinary map where nothing should have changed. Write the check for that
one down at the same time — `unverified.md` carries it as the thing to look at.

## Two write-only GBA registers that lie when read (Emerald, 2026-08-21)

`WIN0H`, `WIN0V` and `BLDY` are write-only. Reading them back returns garbage that looks like data:
a register dump chasing the fog showed `BLDY` swinging between plausible-looking values every
frame, and `WIN0H` reading `0x2800` in a cave whose real span was `96-144`. `BLDCNT`, `BLDALPHA`,
`WININ`, `WINOUT` and `DISPCNT` all read fine, which is what makes the bad ones convincing.

**When a display register is write-only, the live value has to come from wherever the engine keeps
its own copy** — for the flash circle, the scanline-effect buffer. Check the register's read/write
status before building an argument on a dump.

## Lua's 200-local ceiling: the adapter does not load, and almost nothing says so (2026-08-21)

**Recorded TWICE — see also "Adding one local silently unloaded the adapter" below**, whose own
title admits it happened again an hour later. It has since recurred a third time
(`unverified.md`, `d551da1`), and Emerald now sits at 197 of 200 file-scope locals, so the next
one is close. Cross-linked 2026-08-25.

**Symptom.** A change to the adapter has no effect whatsoever. The game runs, the core connects, no
ghosts appear. It reads as a networking fault, a dead relay, or an edit that silently missed.

**Cause.** A Lua chunk may declare at most 200 locals in its main body. Past that BizHawk refuses
the file: `too many local variables (limit is 200) in main function`. The dev loader prints ONE
`LOAD FAILED` line and moves on; every other script keeps loading normally, so the log looks healthy
unless that specific line is read.

**Hit four times in one session on Crystal.** The counts, measured the same day:

| adapter | lines | top-level locals |
|---|---|---|
| Crystal | 3,219 | 157 |
| Emerald | 10,496 | **198 of 200** |

**Emerald is two names away in a file three times the size** — this is not solved anywhere, and the
smaller adapter hits it first because it is denser in top-level names per line.

**Fix.** Group related values onto one table rather than spending a name each — `oam`, `COMPARE`,
`playerHistory`, `tiering`, `genderFrames`. Doing it up front is cheap; doing it while chasing a bug
(which is how every table in both adapters was born) is not.

**The general lesson: when a change to a large Lua adapter does nothing at all, read the loader log
for `LOAD FAILED` before re-examining the change.**

## A file can LOAD cleanly and then throw on every frame (2026-08-21)

**Symptom.** Two commits went out with confident messages describing behaviour that never ran. The
ghosts looked oddly *stable* — no jitter, no snapping — and the user reasonably read that as an
improvement worth keeping and asked to return to it.

**Cause.** The dev loader reports load failures and per-tick errors on SEPARATE lines
(`LOAD FAILED` vs `TICK ERROR`). A scripted revert had removed a helper the placement code called,
so the file parsed and loaded fine and then threw on the first frame, every frame. Only the
`loaded` line was checked.

**Why the symptom was so misleading:** a crashed draw tier does not blank — it stops updating. The
ghosts froze in their last painted positions and were dragged along by other code paths, which looks
exactly like "smooth, no artefacts". **A defect that removes motion can be mistaken for a fix that
removes jitter.**

**Fix.** After any reload, check for BOTH failure kinds before believing anything about behaviour —
and never treat "loaded" as "running". Same family as the read-back rule: confirm the effect, not
the acceptance.

## Lua: a use above its `local` is a silent nil, not an error (2026-08-21)

**Recorded THREE times in this file** — this entry, one 550 lines further down from the same day,
and "A local declared below its use, inside one function" (2026-08-23) — plus two more instances
logged elsewhere (`unverified.md`, `86e4ed2`). **Five occurrences of one fault.** That frequency
is the finding: it is the single most repeated defect in the project. Cross-linked 2026-08-25.

**Symptom.** The painted ghost teleported straight onto its destination tile instead of walking, and
several rounds of tuning a smoothing constant changed nothing at all.

**Cause.** `peerProg`/`peerWalking` were declared *below* the block that built the compare copies, so
those two entries resolved a nonexistent GLOBAL: both fields arrived `nil`, the sub-tile offset was
always zero, and every knob being turned multiplied a term by nothing. Lua issues no warning.

**The tell that was missed:** the same values reached the *other* overflow entries correctly, because
those are constructed further down. **Two copies of the same peer behaving differently is a scope
question, not a data question.**

**Fix.** Declare peer-derived values once, above every consumer. When a constant has no effect at
all, check that the thing it multiplies is non-nil before tuning it again.

## BizHawk's drawing layer persists: "draw nothing" leaves the last frame (2026-08-21)

**Symptom.** The painted ghost stayed on screen through both halves of a door transition — exactly
when every gate in the drawn tier was correctly refusing to draw.

**Cause.** `gui.*` output is not cleared by the script's inaction. A frame in which the tier draws
nothing leaves the PREVIOUS frame's peers on screen, frozen — indistinguishable from a tier that is
wrongly drawing. Every early return in `drawOverflow` fell silent rather than clearing.

**Fix.** Stop by CLEARING (`gui.clearGraphics()`), not by returning early, on every exit path
including the ones that "obviously" draw nothing.

**Generalises:** for any renderer outside the engine, *absence of output is not absence of pixels*.

## Crystal does not fade the OBJ palette shadow, so Emerald's lighting trick has nothing to read (2026-08-21)

**Emerald's painted tier** hides transitions by matching the LIGHTING: it compares the live OBJ
palette against the ROM palette its pixels were decoded from, so the copy dims with every fade.

**That does not port to Crystal.** `transition_probe.lua` measured a full door crossing: `wMapStatus`
went `2 -> 1 -> 2` while the OBJ palette shadow's channel sum sat at a flat **99 throughout**. This
engine does not fade through `wOBPals1`, so there is no signal to match, and copying the mechanism
would copy something with nothing to read.

**What works here instead** is the event the spawned tier already acts on — the world was rebuilt
(`lastArea` changed) — plus clearing the layer on every early return. **Before porting a solution
between adapters, confirm the SIGNAL it depends on exists in the target.**

## A ghost inherits its template's flags, and a STILL object cannot animate (2026-08-21)

**Symptom.** The spawned ghost walked correctly but never animated. Intermittent across sessions and
maps for no apparent reason.

**Cause.** `spawnGhost` copies a live NPC's whole struct as a template, `OBJECT_FLAGS1` included. On
Route 39 the available templates are `SPRITEMOVEDATA_STILL` objects (the fruit tree, the Tauros),
whose flags are exactly `FIXED_FACING | SLIDING`. `SetFacingStepAction` tests `SLIDING` FIRST and
jumps to `SetFacingCurrent` without advancing `OBJECT_STEP_FRAME`, so the walk cycle never runs;
`FIXED_FACING` likewise stops `InitStep` writing `OBJECT_DIRECTION`.

**Measured**: `posediff_probe.lua` caught the ghost at `frame=0` through entire steps while the
player's ran 7, 8, 9, with `flags1=0x2E`. After clearing the two bits, ghost and player match frame
for frame.

**Why it looked intermittent:** it depends on which NPC the map offers. A room with a walking NPC
passes; a route full of scenery fails. **This was found only because the user insisted on testing on
the busiest map in the game.**

**Fix, and the general rule: a spawned entity's flags must describe what IT is, not what its donor
was.** Normalise every inherited field that carries behavioural meaning; do not merely OR in your own.

## Instruments that agree with each other can share a blind spot (2026-08-21)

Three separate detectors reported clean while the user reported twitching:

- a per-frame twitch detector (jumps > 4px between frames): **0 hits** — because a 16px jump on the
  exact frame a tile changes is not a discontinuity *between* samples, it IS the sample. **A detector
  tuned for noise cannot see a perfectly regular defect.**
- a pose differ (position error vs the player): **0px residual** — it measured POSITION while the
  fault was in TIMING (step-start lag swinging 0–6 frames) and in the IMAGE (which sprite frame).
- tier counts (`1 drawn, 0 spawned`): correct numbers, wrong question — a count cannot say WHICH peer
  ids are in which table, and the user was watching two copies of one peer.

**The rule that would have saved the evening:** when the user reports something the instruments deny,
add an instrument that measures a DIFFERENT QUANTITY, not another one measuring the same quantity
more precisely.

## The dev rig's update rate is part of the experiment (2026-08-21)

**Symptom.** Ghost motion became visibly worse after a clean restart of the rig; an hour was spent
attributing it to the adapter.

**Cause.** The restart used the relay's defaults (`-send-hz=20`) instead of the documented dev rig
(`-send-hz=100` plus the core's `-min-send=10ms`). `run-relay-loopback.bat` even carries a comment
saying 20Hz silently overrides the core's faster rate. At 20Hz a peer position arrives every 3 frames
while a step takes 8; the two do not divide, so step starts beat irregularly.

**Measured**: step-start lag spread `0–6 frames` at 20Hz versus `3–5` at 100Hz. A varying lag looks
like snapping; a constant one looks like following.

**Fix.** Start the rig from the `dev-scripts/*.bat` files, or copy their flags exactly. **Rig settings
belong in the bug report** — a rate change is an experiment change.

## `extras` is opaque, so nothing that must be SMOOTH can ride in it (2026-08-21)

**Symptom.** With the core's interpolation enabled, the painted ghost stuttered every frame.

**Cause.** `extras` is opaque to the core by contract (`contract.md`), so interpolation smooths
`position` while `extras.prog` — the peer's sub-tile step progress — passes through latest-wins. The
painted tier then combined a smoothed tile with an unsmoothed sub-tile offset: two terms describing
different instants, once per frame.

**SUPERSEDED TWICE — do not follow the "fix for now" below.** (1) The design lesson was
*implemented*: sub-tile progress moved into `position` (`25277b9`, `ba10a53`), so the two terms
cannot disagree any more. (2) The rig workaround was refuted by the shipped-settings entry further
down this file and by `af50938` — `run-core-crystal-shipped.bat` exists precisely so the rig does
NOT run `-interp=0ms`, because judging only at 0ms is how the shipped smoothing went unexamined.

**Fix at the time:** the dev rig ran `-interp=0ms` anyway (deliberately, so 1:1 could be judged),
and with interpolation off the two terms agree.

**The design lesson, which is the part that survived:** sub-tile progress is really part of
POSITION, and putting it in `extras` was expedient rather than right. Anything a renderer needs to
be smooth must live where the core is allowed to interpolate it.

## Painted-tier motion: three attempts, all reverted, all the same mistake (2026-08-21)

**SUPERSEDED — painted-tier motion WORKS.** Read alone this entry says "do not attempt it". The
three-layer model that succeeded is in the later entries on the drawn tier's motion and the
shipped-settings rig, and the result is user-confirmed (`verified.md`, 2026-08-22/23). What
generalises is the *diagnosis* below — measure the position's own behaviour before adding a term
on top of it — not the conclusion that the attempts were doomed.

The Crystal painted tier renders outside the engine, so it must reconstruct by hand what the engine
gives the spawned tier for free: sub-tile motion, stride phase, camera tracking. Three fixes were
tried and reverted in one session, and **all three added or froze a term on top of a position whose
own behaviour had never been measured**:

1. **A sub-tile glide** — walk back from the destination by the distance not yet covered. Result: one
   tile of movement became two of visible travel, because the destination position ALREADY carries
   the camera's scroll and delivers it in a lump ~12 frames into the step. Smooth plus quantised is
   two motions.
2. **Freezing the calibration** — to kill a ±2px wiggle. Result: the painted copy stopped tracking
   the camera entirely, drifted a tile ahead and snapped back. The frozen term was the one that
   follows the scroll.
3. **Dead reckoning the peer's progress** — advance the last known value at 2px/frame. Result: the
   ghost ran ahead of itself, a full tile at the cap, because the refresh stamp could only fire when
   the VALUE changed and a repeated value let the extrapolation compound.

**What finally worked was a model, not a correction**: paint the peer at
`playerScreen + (peerTile − playerTile)×16 + peerOffset − playerOffset`, with every player term read
from one frame and offsets measured from the DESTINATION (`MAP_X`/`MAP_Y` are written at the START of
a step). **The camera appears on neither side because it moved the player and the world together.**

**The transferable rule: when a position is wrong, measure what that position already does per frame
before adding anything to it.** A per-frame trace of one peer answered in one line what three
attempts could not.

## Crystal: our own ghost's OAM entries are indistinguishable from the player's (2026-08-22)

**Symptom.** The drawn tier's ghost swapped between two facings while the peer walked in one
direction — *"going right has the 'facing down/right constantly' issue"*. It appeared to MOVE
between directions across reloads (left one session, right the next, up after that), which read as
a regression each time, and it degraded within a session: *"it was working at first, but then it
started flipping/swapping in all 4 directions"*.

**Six attempts, four of them wrong, and every wrong one was reasoned from the code.** The fault
looked like a transition bug, then a one-frame skew, then a cache-locking rule. It was none of
those on its own. What ended it was a ten-line trace logging what actually landed in the cache.

**Cause, in two independent layers — which is why every single-variable attempt failed.**

1. **`learnFacingFromPlayer` read OAM entries 0-3 on faith.** Those are assumed to be the local
   player's four sprites, here and in the tier's own anchor calibration, and the assumption had
   never been checked. The engine lays OAM out in its own order, so another character can occupy
   them. Offsets are computed against the PLAYER's tile base, so a frame captured from a foreign
   sprite decoded to ~128 instead of 0-11.
2. **The range check that fixed layer 1 could not see the case that mattered.** It only rejects a
   sprite with a DIFFERENT tile base — and **our own spawned ghost wears the local player's sprite
   id and tile base**, because that is the fallback when a peer's own sprite is not resident. Its
   entries decode to perfectly in-range offsets: the player's tiles, arranged for whichever way the
   GHOST is facing. Nothing about such a frame is detectably foreign. This is why the contamination
   arrived ~2,000 frames in — it needs the ghost up and facing elsewhere — and why the tier looked
   correct at first and then degraded.

**Fix: a rule about the DESTINATION, not the source.** Whatever the entries belong to, art that
disagrees with what a facing must wear is not that facing's art. A 12-tile walking sprite is three
views of four tiles — down 0-3, up 4-7, left/right sharing 8-11 and told apart by the hardware flip
— so the view is DERIVED from the facing and any frame from another view is refused.

**Two wrong versions of that rule, both instructive:**

- **Learning the view per facing from its first sample.** One contaminated first sample locks a
  facing to the wrong view, and the check then ENFORCES it, rejecting every correct frame after.
  `up` locked to the down view and the ghost faced down whichever way the peer walked. **A rule
  that protects whatever arrived first is only as good as that arrival.**
- **Checking the view but not the flip.** Left and right share one view, so the group test passes a
  right-facing frame into left's cache and the two alternate. Up/down were unaffected, which is why
  they went clean an attempt earlier — their views are separate groups. The flip constraint applies
  to the side view ONLY: up and down animate BY mirroring, so both flips are legitimate there and
  requiring one would reject half the walk cycle.

**The methodology lessons, which cost more than the fix.**

- **A cache that keeps the first N samples and never clears turns any single bad sample into a
  permanent fault** — and re-rolls it on every reload, so it looks like a different bug each
  session and like a regression after every unrelated change. The tell is a fault that MOVES
  between cases without the responsible code changing.
- **Build the instrument before the first attempt, not after the fourth.** Four fixes were shipped
  on inference; the trace took ten minutes and answered in eight lines. Every real step —the
  sprite's view layout, the out-of-range entries, the late-arriving contamination — was invisible
  to reading the code, and two of them contradicted a theory that had already been shipped.
- **Log the INVARIANT, not just the values.** Printing each accepted frame's view beside the one
  its facing requires turned the log into a pass/fail the agent could read, instead of a symptom
  the user had to characterise for the fifth time.
- **A revert can be wrong.** The frame-pairing fix was reverted for "making it worse" when it was
  half of a two-part fix whose other half did not exist yet. After several single-variable
  negatives, `CLAUDE.md`'s rule is to try the UNION — that rule applied here and was not followed
  until the trace forced it.
- **"It worked at first and then degraded" is a lifetime statement**, and it points at accumulated
  state rather than at logic. It was the single most useful sentence the user said.

**Generalises to any adapter with a second renderer.** A ghost built to look like the local player
is, by construction, indistinguishable from them in every buffer that records appearance rather
than identity. Anything learned by observing "the player's" sprite data has to establish WHICH
character it is reading, or be validated against something only the real player can satisfy.

## An input-driving probe left loaded becomes a suspect in every later report (2026-08-22)

**Symptom.** The user reported the drawn ghost wiggling. `door_loop.lua` — a probe that presses Up
and Down on a cycle to walk in and out of a house — was still loaded from an earlier driven
measurement while they tested by hand.

**Why it cost a round.** In a loopback session the ghost is the local player echoed, so anything
jittering the player jitters the ghost, and it presents as a RENDERING fault in the tier under
test. That made the probe a genuinely plausible cause, and ruling it out took a reload and a
round trip to the user.

**It was innocent, and that is the part worth keeping.** The wiggle was a real bug. **An
uncontrolled instrument does not have to cause the fault to cost you the investigation** — it only
has to be an explanation you cannot dismiss cheaply. The same reload that cleared the suspicion
would have been unnecessary had the probe come off when its own measurement finished.

**A second, separate error in the same exchange, worth naming because it is the more expensive
habit:** the probe was then offered to the user as the likely explanation. That was a guess wearing
the clothes of isolation. The correct move with two candidate causes and a user at the controls is
to BISECT — put the tree back to the last committed state, confirm the symptom's presence or
absence, and only then reason. That is what eventually settled it, several messages later.

**Fixes, both applied:** the probe announces at load that it is holding the controller
(`door_loop.lua`), and the general rule is in `adapters/_template/probes.md` — "an input-driving
probe is not a passive instrument". A driving probe is unloaded when its run ends, never left on
between runs, and never present when the game is handed back.

**Note the legitimate case, so the rule is not read as a ban:** when the user hands the controls
over explicitly — *"if you want to go 1 tile up to enter, then 1 tile down to exit"* — driving is
exactly right, and got 32 measured crossings in three minutes that a person would have had to walk
by hand. The rule is about who is holding the pad, not about whether driving is allowed.

## Crystal: the learned frame measured its parts from OAM entry 0, so right-facing drew 8px left (2026-08-22)

**Symptom.** The drawn ghost sat ~8px left of where it belonged **only when facing right** — the
user: *"when facing right, the drawn ghost gets offset a bit to the left. it does not do that for
any of the other directions"*.

**Cause.** `readPlayerOamFrame` recorded each of the four sprite parts as an offset from **OAM entry
0**. The engine emits a character's entries MIRRORED when the sprite is flipped, so entry 0 is the
top-LEFT part one way round and the top-RIGHT part the other. Right-facing is the only direction
drawn from the mirrored side view, so it was the only one affected. Measured directly:

```
up     [4@0,0  5@8,0   6@0,8   7@8,8 ]
left   [8@0,0  9@8,0  10@0,8  11@8,8 ]
down   [0@0,0  1@8,0   2@0,8   3@8,8 ]
right  [8F@0,0 9F@-8,0 10F@0,8 11F@-8,8]   <- every dx negated
```

**Fix.** Measure the parts from the minimum x and y across the four entries. The minimum is
invariant under the flip, because the SET of four positions is identical either way — only which
entry reports which member changes. Confirmed on screen (*"absolutely perfect/static in all
directions now"*) and in the log: all four facings inside a 0..8 box, no negatives.

**THE FIX ALREADY EXISTED IN THIS FILE, ONE FUNCTION AWAY.** The tier's own anchor calibration takes
the minimum x across the same four entries, for exactly this reason — recorded 2026-08-19, in this
file, under "Calibrating on OAM entry 0: the entry ORDER swaps when the sprite flips". It was never
carried across to the learner.

**That is the pattern worth extracting, and it happened THREE times in one session:**

| rule | where it lived | where it was missing |
|---|---|---|
| place only on a settled camera | Emerald's spawn path | Crystal's, until it was re-reported (2026-08-19) |
| take the MINIMUM x across the four OAM entries | the tier's anchor | the tier's frame learner (this entry) |
| pair a value with the frame OAM was built from | the position model | the facing learner |

Each was found, written down, and fixed correctly — in one place. The sibling path kept the bug and
surfaced it later as a fresh-looking user report, which is expensive precisely because it does not
look like a known issue. **When a fix is recorded, the same pass should ask: what ELSE reads this,
and does it need the same rule?** `CLAUDE.md` says this about back-porting to `_template/`; it is
just as true between two functions in one file. Candidate sweep: `agent_docs/ideas.md`.

**And the user's instinct is the transferable half:** told about an 8px offset the obvious response
is an 8px correction, and they pushed back — *"so maybe its another issue we haven't found yet
instead of just an offset?"* A compensation would have worked for right-facing and broken the
moment anything else flipped. `_template/BANDAGES.md` calls this shape out; here it was avoided
because the reporter refused it.

## The rig ran the SHIPPED interpolation while the test needed none (Crystal, 2026-08-22)

**Symptom.** The drawn ghost, offset two tiles to the side for comparison, looked *"really
stuttery whenever you walk in any direction"* and *"still stuttering/small snap kinda when moving to
the next tile"*. Two rounds of work went into the renderer looking for it.

**Cause: the core under the test was the one the ADAPTER autostarts, on shipped defaults** —
`-interp=250ms`. With a loopback ghost offset to the side, the whole point is judging the drawn
tier against the player 1:1, and a quarter second of interpolation means what is on screen is the
wire, not the renderer. The measurement is unambiguous once taken: the painted ghost moved 2px
relative to the player on **100 of 132** walking frames at the shipped default, and **0px on all
194** with `-interp=0ms -min-send=10ms`. Nothing about the renderer changed between those two runs.

**Why it happened here and not in Emerald: Emerald has `dev-scripts/run-core-emerald.bat` and
Crystal had no equivalent**, so every Crystal session silently got an autostarted core on play
defaults. `run-core-crystal.bat` now exists and mirrors it. The two modes are deliberately
opposite and both are legitimate — `run-core-emerald.bat` (`-interp=0ms`) for judging a
side-offset ghost against the player, `run-core-emerald-trail.bat` (`-interp=200ms`) for a ghost
sitting ON the player where the delay is the thing being judged.

**This is the THIRD time the rig's own settings have been misattributed to the adapter**, after
the relay's 20Hz-instead-of-100Hz default on 2026-08-21 (`phases/phase9.md`, which already records
"the rig's settings are part of the experiment" as a method lesson). The lesson keeps being
relearned because nothing checks it. So: **before judging a renderer, print what the rig is
actually running and read it** — the core's interp, the relay's send rate, and which core the
adapter attached to. A number in a log costs nothing; two rounds of renderer work cost a session.

**What it does NOT mean.** The 250ms is correct for play and was measured with the user
(`core/core.go`'s own comment, 2026-08-19). The user, on being told the smoothing might be a
bandage: *"i don't think we did that as a bandage thing for emerald, pretty sure we did it for the
network reasons? it can never 1:1 match the player due to network i think?"* — exactly right, and
it is the reason Emerald's drawn tier carries an exponential filter that Crystal's still does not.
A tier with no filter draws the staircase between deliveries; at `-interp=0ms` there is nothing to
absorb and it looks perfect, which is precisely why a zero-interp rig cannot tell you whether the
filter is needed.

## A WRITING probe that half-identifies its target corrupts everything else (Crystal, 2026-08-22)

**Symptom.** *"the ghost is flickering in/out from the middle~ and below"*, then, moments later,
*"actually its flickering from anywhere right now, even the left side. you broke something"* — a
regression report against code that had just been committed and was not the cause.

**Cause.** A probe was blanking the four sprite-buffer entries belonging to one character, to test
whether a ghost could be hidden without losing its collision. It identified those entries by
screen position and matched **about 1.5 of the 4** — so every frame it blanked roughly one and a
half entries of the intended character and, whenever the match drifted, entries belonging to
somebody else: NPCs, and the player. The buffer is shared and rebuilt every frame, so the damage
was invisible in any log and total on screen.

**The rule this extends.** `pitfalls.md` already carries "a diagnostic can break the thing it
measures". This is the sharper case: **a probe that WRITES to shared state must prove it has
identified its target before it writes, not after.** Its own counter said 1.5 of 4 and that number
was printed and read — as a note about the probe's accuracy, not as what it plainly was, a warning
that half its writes were landing on strangers. A partial match is not a weak measurement, it is
an active corruption.

**Two habits that would have caught it:**

- **Refuse to write unless the match is exact.** Four entries or nothing. A probe that finds three
  should log and skip, never write three.
- **Say out loud that a writing probe is loaded, every time.** The user was mid-test on an
  unrelated question and had no reason to suspect the rig; the flicker read as a regression in the
  commit that had just landed. `probes/README.md` already lists which probes write RAM for exactly
  this reason — being on that list is not the same as the person watching the screen knowing it is
  running right now.

## Adding one local silently unloaded the adapter -- an hour after fixing the same fault elsewhere (2026-08-22)

**See also "Lua's 200-local ceiling" above**, the first recording of this; it has since happened a
third time. Cross-linked 2026-08-25.

**2026-08-22.** Crystal's adapter stopped loading entirely with `too many local variables (limit is
200) in main function`. The cause was a single new top-level local, `DRAWN_DELAY_FRAMES`, added for
a feature the user had just asked for.

**What makes this worth an entry is the timing.** Emerald's adapter had been found broken by exactly
this, for exactly this reason, and fixed **the same session** -- and Crystal's own source says "this
file is at 197 of Lua's 200 locals" in FOUR separate comments, each one written by someone who had
just been bitten. Knowing the rule, having just applied it elsewhere, and having it written in the
file being edited were all insufficient.

**Two things follow, and the second is the useful one:**

- The fix is the same one the file already uses everywhere: hang the value on an existing table
  (`facingFrames.drawnDelay`). A field costs no local.
- **The failure is silent to the person watching the screen.** The adapter simply does not load;
  the game plays normally and the ghosts are absent or frozen at whatever they last were. During
  this session the user reported on the drawn ghost's behaviour TWICE while no adapter was
  running -- so those two reports describe the previous build, and were nearly used as evidence
  about the change that had just been made. **After any edit, confirm the adapter actually LOADED
  before asking anyone to look at anything.** The loader log says so in one line.

## Crystal: a ghost must NOT use the player's step type -- it scrolls the camera (2026-08-22)

**The idea, which looked obviously right.** Watching both objects at once showed the player's own
object walking on `OBJECT_STEP_TYPE` **6** and crossing a tile in 15.8 frames, while a spawned ghost
was hardcoded to **2** and crossed in 14.2. A ghost on a different step type is a different movement
machine rather than a copy of one, and it was recorded as a real defect: the ghost was FASTER than
the player, and that was the only thing keeping its 4-frame start lag from accumulating.

**Why it is wrong.** Step type 6 is the step type that **scrolls the camera**, because moving the
player is what it exists to do. Given to a ghost, the ghost drags the view: the user, within seconds
of it loading, *"this moved/drifted the whole game camera"*.

**So the pace difference is not a defect, it is the price of a ghost not being the player**, and 2 is
correct. It is now commented in `stepGhost` as a rejected alternative rather than left looking like
an oversight, because "just use the player's step type" is an obvious-looking idea that will be had
again and whose failure mode is invisible until it is on screen.

**THE DAMAGE OUTLIVED THE CODE.** Reverting the adapter did not put the camera back -- the user had
to load a savestate: *"i reloaded savestate9, and its back to normal now"*. A ghost driving the
camera moves the engine's own scroll state, and nothing in the adapter owns or restores that. So a
write that hands a ghost a player privilege can leave the WORLD altered after the write stops, and
"I reverted it" is not the same as "it is undone" -- check the symptom, not the diff. Any experiment
of this shape wants a savestate taken first.

**The transferable rule: a field copied from the PLAYER'S object may carry the player's privileges.**
The player's struct is not a template with better numbers in it -- some of its values exist to drive
things only the player may drive. `phase9.md` already learned the same shape from the other side:
the ghost is built from an NPC's movement behaviour wearing the player's face, precisely because the
player's own movement type means "driven by input".

## Crystal: the drawn tier's stutter was never in the drawing (2026-08-22)

**Symptom.** At the shipped 250ms interpolation the painted ghost was *"really really bad"* — a
coarse staircase — while the engine-driven one looked correct. At `-interp=0ms` the same code
measured 0px of relative motion in all four directions and the user called it 1:1.

**Cause: the adapter sent whole TILES.** The core therefore spent each step interpolating between two
identical values and output a constant, then lurched when the tile changed. Measured at the shipped
settings before the fix: **1911 messages, 1838 carrying no movement at all, and the 72 that moved
jumped 4–6px.** The smooth motion was simply not on the wire, so no renderer could have drawn it.

**Why it hid.** The sub-tile position rode in `extras.prog`, and `extras` is opaque to the core and
not interpolated. `pitfalls.md` recorded that in August as a design lesson whose stopgap was "the dev
rig runs `-interp=0ms` anyway, and with interpolation off the two terms agree" — which is exactly
the configuration everything was judged in.

**Fix.** `position` is `[]float64` and variable length by contract, and the core interpolates every
component, so components 3 and 4 now carry the character's position in map pixels — absolute, not an
offset from the destination, because a tile index and such an offset cancel at a boundary when
interpolated independently. After: **521 movements, 517 of them 1px.** The stride is derived from the
same position, since a body moving smoothly while its legs run off an un-interpolated value is the
same defect in the other half.

**The general form is in `_template/README.md`**: anything a renderer must draw smoothly belongs in
`position`; `extras` is for facts that are already discrete.

## Three more instruments that lied, in the same session (2026-08-22)

Collected in full, with the general rule, in `adapters/_template/probes.md` ("Five ways an instrument
lied in one session"). The short forms, because each changed a decision:

- **A trace gated on `frames % 2 == 0`** showed a value advancing 2px per sample and it was reported
  as 1px per frame. It moves 2px every two frames — identical to the value it was replacing — so the
  change justified by that reading did nothing, and was described to the user as a fix. **Print the
  sampling interval in the output line.**
- **A histogram bucketed by a float** (an interpolated distance) while its report looped over integer
  keys: it printed 2 movements out of 224 recorded. **Round at insert time and print the total beside
  the distribution.**
- **A wire trace reported "1 distinct position this second"** and it was read as a field not being
  sent. The driving probe pauses at corners, so a stationary second had been sampled — **and a
  correct change was reverted on that reading.** Report unchanged samples beside changed ones:
  "nothing moved" and "nothing was sampled" must not print the same.

## Crystal: the drawn ghost stutters at shipped settings but not at `-interp=0ms` — 2026-08-23

**Symptom.** *"the drawn ghost still looks a bit stuttery/jittery while moving around"*, at the
shipped 250ms interpolation. Invisible on the dev rig, which runs `-interp=0ms`.

**Why the dev rig could never show it.** At `-interp=0ms` the ghost replays the player's own past
positions, which are integers the engine itself produced. At 250ms the core INTERPOLATES, and an
interpolated position is fractional. Any defect that only appears once positions stop being
engine-legal is invisible on a rig that never interpolates. **A dev rig that removes a variable
cannot test that variable** — Crystal now has `run-core-crystal-shipped.bat` for exactly this.

**Diagnosis, in the order the suspects fell.**

1. *The two clocks beat against each other.* Refuted: 660 of 660 rendered frames received exactly
   one message, and `receive()` drains its whole buffer per frame so a 0 or a 2 would have shown.
2. *The aged player reference wobbles.* Refuted from the code: `playerHistory.age` is a constant.
3. *The interpolated position is fractional.* Confirmed: mean 0.970 px/frame — the right speed —
   but only 65 of 198 moving frames advanced a whole pixel, against 58 at 0.75 and 52 at 1.25.

**Fix, which took three attempts, each corrected by a measurement rather than a guess.**

| attempt | what it did | why it was wrong |
|---|---|---|
| 1px per frame | walked the ghost a pixel a frame | **smoother than the game** — the scroll moves 0/2/4px and never 1 |
| 2px on a fixed parity | matched the quantum | moved on the frames the player did not: 2px of shake every frame |
| **2px grid + phase latched per burst** | rounds the interpolated position onto the engine's grid, and takes its 2px on the engine's observed tick | — |

**Three separate defects were found underneath it, all live before this session:**

- **`stepProg` was computed and never read.** A dead local under a comment explaining why the stride
  had to share the body's clock, while the stepping band, the frame picker and the counters all went
  on reading the raw un-interpolated `extras.prog`. The comment described an intention, not the code.
- **The stride's progress had a sign bug.** `16 + (pix - tile*16)` is correct only where that term is
  negative — right and down. Walking **left or up** it pins at 16 for the whole step, and 16 is
  inside the stepping band, so those directions held one image instead of running a cycle.
- **The engine's tick parity is stable within a bout of walking and differs BETWEEN bouts** (measured
  odd 95 / even 1 inside one bout; 64 / 32 across several). A phase latched once and kept is right
  for a while and then exactly wrong.

**The tell worth carrying: a fault whose severity grows with the length of the action is something
that REPEATS.** *"1 tile looks good/perfect... 4-5+ tiles and it starts to look really jittery"* was
the phase being re-rolled every time the model momentarily caught up — many times in a long walk,
once in a short one. Constant offsets and rounding errors do not behave that way; count the repeats
rather than looking harder at the magnitudes.

## Crystal: the drawn ghost's motion, from "stuttery" to clean — the whole chain, 2026-08-23

One symptom word, *"jittery"*, covered **nine distinct defects** in three different layers. They are
listed together because the order they were found in is the lesson: every layer read clean while a
layer beneath it was wrong, and the instruments agreed with each wrong layer in turn.

### Layer 1 — the position model (what the ghost's world coordinate does)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | stutter at 250ms, invisible at 0ms | interpolation gives FRACTIONAL pixels; mean 0.970 px/frame was right, but only 65 of 198 frames advanced a whole pixel | quantise onto the engine's 2px grid |
| 2 | still stuttering | a 1px/frame ghost is **smoother than the game** — the scroll never moves 1px | move in the engine's 2px quantum |
| 3 | "same/bad" while histograms read perfect | ghost moving on a fixed parity, ANTI-PHASE with the player: 2px of relative shift EVERY frame | take the phase from the engine's observed tick |
| 4 | "1 tile fine, 4-5+ tiles jittery" | the phase cleared whenever the model momentarily caught up — many re-latches in a long walk, half landing anti-phase | release the phase only after a real stop (30 frames) |
| 5 | "stuttering constantly" / "snapping back" alternately | three catch-up policies in a row: too eager stuttered, too patient let lag reach the emergency snap | commit whole tiles; decide only at boundaries |
| 6 | "gliding backward during the walk" | mid-gait boundaries held to the 6px cold-start cushion, bleeding 1-2px per tile (measured: sx 14 -> 2 across one side) | chain at 2px when already walking |
| 7 | "snapping back every single step" | the "never move on consecutive frames" rule — **the engine's scroll DOES tick on consecutive frames**, and the rule zeroed the budget exactly then (`cam=2 gap=1 bud=0`) | on a camera frame, copy the camera's delta unconditionally |

### Layer 2 — the paint (how a world coordinate becomes a screen position)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 8 | one -2/+2 pair per tile, surviving every model fix | the screen origin came from the player's **tile + step progress**, two values that hand over on DIFFERENT frames at each boundary. The old ghost term shared that machinery so the seams cancelled; a seamless model term exposed it | paint as `model - camera + K`, one coordinate frame |
| 9 | "1 tile further back the whole walk, snaps home on stopping" | an 8px **diagonal** register jump on the first frame of each walk — a REBASE, not motion, and the accumulator painted it | absorb an implausible delta into the accumulator AND K in the same frame |

### Layer 3 — the animation (which pose is drawn)

- **The stride's clock**: progress came from distance REMAINING to a destination tile that advances
  when the peer starts its next step, so the cycle restarted a few pixels early every step and its
  last images were mostly never drawn (`0:134 2:166 ... 14:114 16:64` — the end of the cycle three
  times rarer than the middle). Now distance TRAVELLED: model position modulo the tile grid.
- **The stride's axis** came from the peer's reported facing, so one flickering frame moved the
  measurement to the other coordinate. Now from where the ghost is actually going.
- **A one-frame facing flicker counted as a turn**, and the turn suppression punched a single-frame
  hole in an otherwise correct burst (`RRRRrRRR`). A facing must now survive a frame.
- **The legs were gated on the wire's `walking` flag**, which describes the peer NOW while the model
  walks a position a quarter-second older — so the legs froze mid-stride at every stop while the
  body glided on. Now gated on the model's own movement.
- **`stepProg` was computed and never read** — a dead local under a comment explaining why the
  stride had to share the body's clock, while everything downstream read the raw value the comment
  said was the problem.
- **A sign bug** in the old progress (`16 + (pix - tile*16)`) pinned left and up at 16 for the whole
  step, so those two directions held one image instead of running a cycle.

### The two rules worth carrying out of all of it

> **A fault whose severity grows with the length of the action is something that REPEATS.** "One
> tile is perfect, five tiles is bad" is not a constant offset and not a rounding error — count the
> repeats and find what re-rolls.

> **When the model and the screen disagree, the coordinate frame is the suspect.** Layers 1 and 3
> were each measured clean while layer 2 was wrong, because every instrument was built in the
> model's own frame. The only instrument that could see it was one that watched the painted screen
> position — the number the eye actually watches.

## Crystal: a spawned ghost was a TRAINER, and it hung the game (2026-08-23)

**Symptom.** A `!` appears over a spawned ghost's head, as if a trainer had spotted the player, and
the game then stops responding to input. The overworld is still emulating — frames advance, the
adapter keeps logging — so it is the game's own script engine that is wedged, not the emulator and
not Lua. User's words: *"the spawned ghost got the trainer battle thing, and now we are stuck"*.
Rare, and it had been seen *"from time to time"* with no idea how to reproduce it.

**Cause.** `spawnGhost` clones a donor: all 16 bytes of a live NPC's map object plus its object
struct. The adapter understands four of those bytes (struct id, sprite, y, x) and copies the other
twelve blind. Byte 8's low nibble is the object's TYPE and byte 9 is its SIGHT RANGE
(`constants/map_object_constants.asm:79-99`). The donor that did it read

    05 2E 17 0F 09 00 FF FF 82 04 82 5B FF FF 00 00

— type nibble `2` = trainer, sight range `4`, and a real script pointer. The ghost *was* that
trainer, with a four-tile sightline, and unlike a real trainer it walks around; sooner or later it
faced the player from somewhere no trainer stands, raised the `!`, and ran a battle script for a
trainer that is not on that tile.

**Why it was rare, and why it never reproduced.** The donor is whichever object the map declares
first (`findTemplateNpc` returns the first eligible map object). Whether a ghost is a trainer is
therefore a property of *the map you happen to be standing on*, not of anything the player did — so
it travelled with the route and no repro ever held still.

**Fix.** Normalise what the ghost IS, on the ghost's own map object only: type nibble to
`OBJECTTYPE_3`, sight range 0, script pointer 0, event flag `FFFF`. Type 3-6 are the game's own
dummy events whose handlers return immediately, so a ghost can be faced and nothing happens — and
critically they are the only types that never dereference the script pointer, so blanking the
pointer while leaving type 0 would have traded a trainer hang for a null-pointer jump.
`_CheckTrainerBattle` (`home/trainers.asm:13`) tests the type nibble *second*, before sight range
and before the pointer is read, so the ghost now leaves that scan immediately.

### The third instance of one root cause, patched three times

The two earlier ones are commented in `spawnGhost` itself: a ghost inherited `SLIDING`/`FIXED_FACING`
from a still object and never animated, and inherited a WANDER movement type that snapped its facing
at the end of every step. Each was fixed where it showed, as its own field. **All three are the same
bug: a ghost inherits its donor's identity.** Three symptoms, three patches, one cause that was
never named. When the same shape appears a third time, the thing to change is not the fourth field.

### What was tried first, and why it was wrong

Templating the **player** instead of an NPC — the player carries no trainer type, no sight range and
no script, so the whole class disappears. It was a bad fix and was reverted within the hour: the
player's map object and its 0x28-byte object struct carry the engine's own driving state, and
copying them broke camera-follow and displaced the map's objects. User: *"this is not a fix, this is
a really big regression"*. **The donor was never the thing to change; the four bytes that say what
the copy IS were.** Replacing a donor whose unknown bytes are *sometimes* wrong with one whose
unknown bytes are *always special* is not a narrowing, it is a bigger blind copy.

### The method worth keeping

- **An unreproducible fault deserves an instrument, not a repro hunt.** A one-line log of the donor
  and its 16 bytes was added while the bug was still just a suspicion. It caught the offending
  object on the very first spawn after it went in, and named the culprit outright. The fault was
  unexplained from the first time it was seen; the instrument is one log line.
- **A cleared decompilation is faster than measurement — read it FIRST.** Every fact above came from
  reading `pret/pokecrystal`, which `licensing.md` cleared for facts-with-citation and which
  `environment.md` records as already built locally since 2026-08-17. The field names, the type
  values, the dispatch table and the scan order were all sitting there. The earlier `FLAGS1` fix in
  this same function was derived by probe over multiple sessions, and those bit names were in a file
  we were always allowed to read. Measurement is for confirming what the source says, not for
  discovering it.
- **Verify a write by reading it back out of the game.** The spawn log now reports the type nibble
  re-read from emulator memory rather than the value just written.

## A reverted `.go` file comes back as CRLF, and nothing shows you why (2026-08-23)

**Symptom.** `dev-scripts/preflight.ps1`'s first check fails: `not gofmt-clean` on several `.go`
files. `gofmt -d` prints the ENTIRE file as changed, which reads like a catastrophic formatting
problem. Meanwhile `git status` and `git diff` show nothing wrong with those files — some of them
are byte-identical to `HEAD` in content — so there is no edit to point at and no obvious culprit.

**Cause.** `core.autocrlf=true`, and `*.go` was not pinned in `.gitattributes`. Git therefore writes
CRLF whenever it *materializes* a `.go` file, so any revert re-creates it with CRLF — `git checkout
--`, a reversed patch, a stash pop. Git then normalizes on read, which is why the diff is empty; but
`gofmt` sees a file whose every line ends `\r\n` and rewrites every one of them.

Note what makes this hard to attribute: **no one edited the file.** Reaching for "whose editor did
this" is wrong twice over — it blames a person, and it stops the search before the real mechanism.
The tell that settles it is that the *content* matches `HEAD` while the *bytes on disk* do not.

**Fix.** Pin it, exactly as `go.mod`/`go.sum` already were for the same reason:
`*.go text eol=lf`. Repair the existing files with `perl -pi -e 's/\r\n/\n/g'` before rebuilding —
`CLAUDE.md`'s order for the LF-pinned adapter sources (normalize, then build, then commit) applies
here too.

**Worth knowing:** `.gitattributes` already pinned `*.cs`, `*.cpp`/`*.hpp`, `*.sh`, `go.mod` and
`go.sum`. `.go` was simply missed, and it is the extension this repo has most of.

## Crystal: the end-of-walk snap was TWO faults sharing one trigger (2026-08-23)

**Symptom.** At shipped settings only, the drawn ghost snapped onto its last tile whenever the
player stopped. Clean at `-interp=0ms` the same date, which is why every earlier confirmation had
missed it: the lag being repaid is the model trailing its own INTERPOLATED target, so with no wire
delay there is no debt and the fault cannot occur. **A dev rig that removes the delay cannot find a
delay-dependent fault.**

**Cause 1 — the model was allowed to move at double the engine's walk, but only at rest.** The
model's budget copies the camera's delta while the camera moves; parked, it falls back to its own
beat, and that fallback granted 4px where a walker moves 2px. The camera only parks once the PLAYER
has stopped, so the branch could never fire mid-walk — it fired once per walk, at the end.

**Cause 2 — the paint had two formulas and switched between them at that same moment.** It
CALIBRATED `K` from the player-tile formula while parked and PAINTED from the camera formula while
moving — an `if`/`elseif`. The frame the camera parks is the frame the source changes, and the two
formulas disagree by accumulated drift: **worst measured 14px, paid in one frame.**

**Fix.** Cap the parked fallback at 2px; paint from one formula on every frame and let only `K`
move. Also fixed on the way, by algebra: **the X camera rebase was absorbed with the wrong sign** —
painted position is `model + camA + K` on both axes, so a rebase added to `camA` cancels only if
SUBTRACTED from `K`. Y did that; X added, doubling every X rebase into the paint.

### Why "sometimes" was the most useful word in the report

Fixing cause 1 turned *"snapping ... whenever the player stop"* into *"still doing the weird ending
snap, but just sometimes"*. **A defect that becomes intermittent has not become smaller — it has
become a second defect whose magnitude varies.** Both fired on the same trigger, so one fix could
never have been judged as a partial success; "sometimes" was the signal that a magnitude was
varying while the trigger was not, which is what pointed at accumulated drift.

### "Before" and "after" are diagnostic words — ask which

The residue was chased in the wrong place until the user said *"sometimes have the 'jitter' right
before stopping on a tile"*. **Before**, not after. At 250ms the ghost is still walking its last
tile while the camera is ALREADY parked, so a park-time correction runs during the ghost's final
approach. That one word moved the cause from "what happens at rest" to "what happens during
arrival", and no instrument had distinguished them.

### Two repayment rules that sound better and are worse

Recorded so they are not re-invented; both were tried against the user's eyes.

| Rule | Result |
| --- | --- |
| Deadband — ignore drift under 4px, since a constant offset is invisible | Drift walked up to **16px** per park, at the snap threshold. The premise is right; the conclusion is not, because the drift is CONTINUOUS, so repayment must be too. |
| Wait for arrival, then repay 2px on the engine's tick | *"now its overshooting, and then gliding back ... added a snap to every single stop"*. 2px is coarser than the drift it chases, and a post-arrival burst is a snap by construction — the original fault moved later in time. |

**The rule that survived: repay continuously and finely, on a frame the model itself did not move.**

### The engine's RHYTHM is as visible as its speed

The first repayment moved `K` 1px per frame. Every frame stayed within the walk speed and it still
looked wrong, because the model advances 2px on its beat and the correction filled the gaps —
turning a clean `2-0-2-0` cadence into `2-1-2-1`. This file already carries the same lesson from the
other direction (a 1px-per-frame ghost is *smoother than the game* and reads as shimmer). **A
correction does not get its own units.** If the engine moves 0, 2 or 4 pixels and never 1, then
neither does anything we add to it — including error repayment.

## Crystal: a tier handover is a position handover, and a gap is a blink (2026-08-23)

**Symptom.** *"the spawned ghost is 'teleporting' 1 tile whenever it starts to walk after being
idle/respawned"*.

**Cause.** Not stepping at all — a HANDOVER. The shipped idle rule demotes a ghost that has not
changed tile to the drawn tier, which despawns its engine object; the moment the peer moves it is
promoted back and a fresh object is placed. So "after being idle" is a re-spawn every time. The two
tiers disagree about where the peer is at that instant, and an instrument at the promotion measured
it as the same value on every occurrence:

    promoted across a -1,+0 tile handover (drawn model at 15,20, peer at 16,20)

**A full tile, always along the direction of travel — structural, not incidental.** The promotion is
TRIGGERED by the peer moving, so it fires exactly as the peer leaves the tile the drawn ghost is
still standing on.

**Fix.** Promote onto the tile the drawn model is over, not the peer's current tile, and let the
ordinary step logic walk the remainder. The sub-tile remainder is deliberately NOT carried across:
an object parked between tiles is what the standing re-anchor exists to destroy, so it would be
undone within a frame and the jump would return by another route.

**Then a flicker was left** — *"its not teleporting now, but it 'flickers' real quick"*. Dropping the
drawn copy on the frame the engine object is created leaves one frame in which NEITHER draws the
peer: the adapter paints during its own tick, while a new object is not in the engine's sprite list
until the engine next builds one. **A gap is visible; an exact overlap is not.** The two tiers now
overlap by one frame, which is invisible only BECAUSE the tile handover was fixed first — they agree
on the tile, so it is the same character in the same place. Overlapping before fixing the tile would
have drawn the peer twice, a tile apart.

**Generalise:** any renderer with two tiers has a handover, and the handover has a position. It is
invisible only if both tiers agree on that position AND neither frame is left empty.

## A scripted edit can land a thousand lines from where you meant it (2026-08-23)

**Symptom.** A Python edit reported success. The file had a comment stub at the intended site and
six lines of the new code pasted into an unrelated function far below — syntactically valid Lua,
loaded without error, and wrong.

**Cause.** Computed insert indices. The replacement targeted one line correctly, then `insert()`ed
the remainder at hand-arithmetic offsets that were stale the moment the first edit shifted the file.

**Fix, and the rule.** `CLAUDE.md` already says to re-read the FILE after any scripted edit — this is
what it is protecting against, and "it printed `applied`" is not evidence. Prefer replacing a
contiguous block in ONE operation over an anchor plus offsets; when line numbers must be used, assert
on the CONTENT of every line before touching it. Recovery is `git diff --stat` plus a look at the
hunk headers: four intended sites showed as four hunks, and the stray sixth hunk was the corruption.

**Also, repeatedly, in the same session:** several `old in s` assertions failed because indentation
in the heredoc did not match the file's tabs. Those failed LOUDLY and were harmless. The dangerous
one is the edit that half-applies — **an assertion that fires is a good outcome; the one to fear is
the edit that succeeds in the wrong place.**

## Crystal: the ghost jittered before stopping, and the "camera" was three different mistakes (2026-08-23)

**Symptom.** The drawn ghost tracked cleanly, then jittered on its final approach as it stopped —
*"works/looks fine most of the time, and then sometimes have the 'jitter' right before stopping on a
tile"*, most reproducible on one leg of a scripted square walk. It had survived every previous fix
aimed at the model's motion, the wire and the interpolation delay.

**Three wrong theories, each of which looked right.**

1. *A continuous bleed between two formulas.* The evidence was a log line reading "K drift repaid
   206px" against only 5 camera rebases. The counter added the whole REMAINING error every frame
   while the corrector repaid 1px of it, so it inflated quadratically — 206 was about two ordinary
   episodes. **The theory was built entirely on a counter whose units nobody had checked.**
2. *An aged player reference.* Written down as the next suspect; already dead, because the aging
   knob had been set to 0 earlier the same day for an unrelated reason. Cost nothing to rule out —
   by reading, not running.
3. *A sub-pixel rounding residue making the corrector oscillate.* Plausible, and refuted in one run
   by a reversal counter (158 correction frames, 3 reversals — steady chasing, not oscillation).

**What actually settled it, in the order that worked.**

- **Algebra first.** Substituting the definitions into the disagreement made the ghost's own position
  cancel exactly: `wantKX = oamX - 8 - pTile.x*16 - ppx - camAX`. That one line proved the residue
  was not the ghost's, could not be affected by the wire or the model, and was entirely
  player-and-camera-side. It deleted most of the search space before any measurement.
- **Then the decompilation, which named the bug.** The register the adapter integrated as "the
  camera" was `wPlayerBGMapOffsetX/Y`. `pokecrystal` says it is "used in FollowNotExact", and
  `ApplyBGMapAnchorToObjects` (`engine/overworld/map_objects.asm:2768`) reads it, applies it to every
  object's sprite, and **zeroes it every frame**. A per-frame delta, not a scroll position. The real
  scroll is `hSCX`/`hSCY`, written by `ScrollScreen` from the same step vector with the opposite
  sign. **The adapter's own comment claimed this register "cannot disagree with what the player
  sees."** A confident comment is not evidence; the source is.
- **Then an audit that could fail.** Reading both registers on the same frame: 30 of 340 frames
  disagreed, in three shapes that each matched a reported symptom.
- **Finally the real cause, from asking how often the instrument ran.** The plausibility filter
  rejected 16/20/22/24px scroll deltas as "register rebases". Those sizes are 8-12 frames of ordinary
  2px scrolling. A gap histogram showed five sampling gaps and five rejections — **the same five
  events.** The camera never jumped: `drawOverflow` increments its frame counter at the top and then
  has many early returns, and the camera sampling sat below all of them, so a gated frame left the
  reference stale. **The adapter was reading its own blindness as the game doing something, and
  throwing away that much real scroll.** That manufactured the entire drift the corrector then repaid
  one visible pixel at a time.

**Fix.** Clock off `hSCX`/`hSCY`; correct the calibration constant only against a reference identical
to the previous frame's; and sample the camera in a global called before every early return. Gaps
went to zero, rebases to zero, per-park drift from 15px to 1px, and the directional asymmetry that
was the user's reported signature disappeared.

**The rules worth keeping.**

- **A filter that discards "implausible" readings will hide your own bugs by making them look like
  the game's.** Every rejected value here was the adapter's blind spot dressed as a register rebase.
  Count what a filter rejects, and check the rejected sizes against how long you were not looking.
- **Ask how often your sampler actually runs before trusting any delta it produces.** A per-frame
  difference is only a per-frame difference if the code ran on every frame. Histogram the gap; 1
  should be the only value.
- **A quantity sampled below an early return is not sampled.** Anything integrated over time belongs
  above every gate, in its own function, not wherever it was first needed.
- **Cancel the algebra before measuring.** Knowing which terms drop out of an expression is free and
  eliminates whole categories of suspect that would each have cost a live cycle.

## A peer walks, and the adapter reports `0 spawned as real objects` (Crystal, 2026-08-23)

**Symptom.** Every peer stays on the drawn tier. The spawn budget is healthy, structs are free, the
sprite is the local player's own, and the player is plainly walking on screen.

**Cause.** `MESHGHOST_CRYSTAL_GHOSTS_PASSABLE` was still set from an earlier run. The dev loader drops
and re-loads script FILES; **it does not reset BizHawk's Lua globals**, so deleting the line from a
flags file does not unset the flag. And that flag makes `shouldBlock` return false *before* it updates
`movedAt`, so every peer's idle counter climbs forever and no peer is ever "moving".

**Fix.** A dev flags file sets every flag it cares about explicitly, **including to `nil`**. The tell
is in the numbers, if anything is printing them: an idle counter that rises at exactly 60 per second
and never resets is not an idle peer, it is a code path that never reaches the reset.

**Method note.** Three guesses were spent on budget, residency and struct exhaustion, all off a
counter reading zero — and a zero counter is compatible with every one of them. What settled it in one
run was making the refusal name itself (`stays on the drawn tier -- wearable=... blocking=...`).
**When a count of zero has more than one explanation, print the reason, not the count.**

## Interpolating a quantity that only moves in whole steps (Crystal, 2026-08-23)

**Symptom.** A spawned ghost's steps begin an inconsistent number of frames after the peer's — 2 to 5
at the shipped relay rate — which reads on screen as walking, hesitating, walking. Raising the relay
rate to 100Hz makes it exactly constant; the shipped 250ms interpolation does not help at all.

**Cause.** The relay ships a room at 20Hz, and the core lerps every component of `Position` between the
two bracketing samples. Crystal's `Position[0..1]` are TILE INDICES — a step function, since MAP_X/Y
jump to the destination the instant a step starts. Lerping a step function turns an exact instant into
a ramp as long as the sample interval, and `math.floor` crosses that ramp at a moment that depends on
where the jump fell between samples. **The jitter is the sample interval, in frames.**

**Not a core bug.** Nothing in `core/` may know which component is a tile and which is a pixel (ADR
2026-08-20). Lerping uniformly is right; reading a lerped tile index as an instant is the adapter's
mistake.

**Fix (designed, unbuilt).** Recover the instant instead of watching for the crossing: the peer's
sub-tile progress is on the wire, so a sample says how far into its step the peer already is, which is
how long ago it committed. Schedule the ghost's step at a constant offset from that. Constant lag has
no reference to be seen against; varying lag is the whole of what is visible.

**The general lesson, which is not about Crystal.** Before smoothing a value, ask whether it is
continuous. Anything that jumps — a tile index, a facing, a state id, an animation number — must be
carried across, never blended, and if a renderer needs the TIME of the jump it has to recover it from
a continuous quantity beside it, not from the jump's own arrival.

## A ghost that is "static, but follows the player around" (Crystal, 2026-08-23)

**Symptom.** A character stays on screen after the core and relay are gone, frozen in one pose, and
appears to travel with the player instead of staying where it was.

**Diagnosis, from the wording alone.** "Follows the player" is a statement about a COORDINATE SYSTEM,
not about behaviour. An engine object lives on a tile: it would stay put and slide off the edge as
the camera moved. Something that holds its place on the display is painted in SCREEN pixels, so it is
the drawn tier's overlay, frozen — not an object at all.

**Cause.** `disconnect()` cleaned up the bookkeeping but not the canvas. Forgetting a peer does not
un-draw it, and nothing repaints afterwards because `drawOverflow()` is the last call in `tick()`
while `tick()` returns early on `not connected`. The last painted frame simply stays.

**Fix.** Clear the overlay wherever the tier can stop being called, not only where it decides not to
paint. `drawOverflow` already had `stopDrawing()` for door transitions; `disconnect()` needed the same.
**The general form: every early return that skips a renderer is a place a stale frame can survive.**

**A memory dump cannot see a rendering artefact, and that cost two wrong answers.** Every probe in
`probes/` reads WRAM, so the drawn tier is invisible to all of them: an orphaned-object theory and a
contaminated-savestate theory were both investigated and disproved before the tier was even
established. **Settle WHICH RENDERER is showing a fault before choosing an instrument** — with two
renderers, half of what can go wrong leaves no trace in the game's state.

**A worked corollary on reading your own numbers.** The object array did hold an extra character
wearing the player's sprite, at tile 13,20 with the player at 9,20 — and `MESHGHOST_LOOPBACK_OFFSET_X`
was 4. That was the adapter's own ghost, exactly where it belonged, misread as evidence of a leak.
When a rig deliberately displaces a ghost, subtract the offset before calling a position suspicious.
`orphan_sweep.lua` said "nothing to clear" eleven times and was correct each time; a probe that keeps
reporting nothing is answering, not failing.

## "It still flickers" after a fix aimed straight at the flicker (Crystal, 2026-08-23)

**Symptom.** A spawned ghost blinks at the instant it starts moving after standing still. A one-frame
tier handover had been added for exactly this and the blink survived it.

**Cause, two layers deep.** The handover kept the drawn copy for one frame; measured, the engine does
not render a newly created object for one to two frames, so the copy was released into a hole rather
than overlapping anything. AND a second, unconditional `overflow[id] = nil` further down the same
function wiped the entry regardless of what `handover` said — so the mechanism had never had any
effect at all. **Fixing only the first would have changed nothing and read as the theory being wrong.**

**The general form: when a fix aimed correctly produces no change, check that the value it sets is
still set by the time anything reads it.** Search for every other write to the same field before
concluding the diagnosis was wrong. A second unconditional assignment is invisible in a diff of the
first one.

**Second general form: a comment describing an intended mechanism is not evidence the mechanism runs.**
This one said the two tiers overlap for one frame and cost one doubled frame; they were never on
screen together, and the "overlap" was a gap. It had been read as a description of behaviour by two
sessions.

## A probe that returns a boolean cannot be sanity-checked (Crystal, 2026-08-23)

Three versions of one OAM probe, and only the third could have been right.

1. Calibrated off OAM entry 0 assuming it was the player — the adapter's own code warns that is false
   once a ghost is on screen. Reported 21-24 frames, a third of a second, for something that should
   take one or two. **A number that implausible is the probe reporting on itself.**
2. Assumed a fixed sprite-coord-to-OAM offset. Object coords are map-relative and the real offset
   moves with the camera. This one **gated every reading on finding the player at its own predicted
   position**, so when the assumption broke it produced nothing rather than a wrong number. That gate
   is the only reason the error did not enter the record as a measurement.
3. Printed the ghost's coords, the predicted position, AND every live OAM entry, per frame. The
   answer — two rows missing on two frames — was readable without trusting the prediction at all.

**Both rules are cheap: make a probe state the raw evidence behind any match it claims, and make it
verify its own assumption against something already known (here, the player) and stay silent when
that fails.** `_template/probes.md`.

## An animation that plays without moving the character (Crystal, 2026-08-23)

**Symptom.** The spawned ghost bumps into walls like the player; the drawn ghost stands there.

**Cause, and it is structural rather than specific.** The spawned tier hands the engine the peer's
`OBJECT_ACTION` and the engine animates. The drawn tier DERIVES its pose from position and sub-tile
progress, so **any animation that does not move the character cannot reach it**. Bump, spin, fishing,
the emote and the Fly landing are one gap. All already ride on `extras.act`; the tier ignored it.

**The general rule: a renderer that infers a pose from motion can only ever show motion.** When one
renderer copies the source's animation state and another reconstructs it from position, they are not
two implementations of the same thing and they will disagree exactly on the animations that stand
still. Emerald sends `sanim`/`sidx` -- the peer's own animation number and frame index -- and never
has this class of bug at all.

**The wrong fix, and how it announced itself.** Forcing `walking = true` for the duration of the bump
makes the picker return a stepping frame every time and cycle the stride images. The user: *"now the
drawn is doing it but it looks slow/weird"*. **A pose built from the correct data can still be the
wrong animation.** What settled it was measuring the frames the engine actually draws, run-length
encoded so the cadence was visible: a bump alternates STANDING art and STEPPING art in 16-frame runs
while the facing walks 0,1,2,3. It is a two-pose shuffle, not a stride cycle -- and no amount of
reasoning about `facing` values would have produced that, because the first 100-frame sample caught
only part of the cycle and looked like a plain 1<->2 alternation.

**Method note: run-length encode a per-frame probe.** One line per frame hides a cadence inside a
hundred identical rows; `value x13 frames` states it. The 3/13 split -- the drawn block changing three
frames before the facing does -- is only visible in that form.

## A local declared below its use, inside one function (Crystal, 2026-08-23)

**The fifth recorded instance of one fault — see "a use above its `local` is a silent nil" above**
for the full tally and why the repetition matters more than any single case.

Fourth time in this file. `peerAct` was declared ~130 lines below the drawn tier's `overflow`
constructors, which now read it. Lua resolves that to a nil GLOBAL, silently -- so `act` reached the
`MESHGHOST_COMPARE_TIERS` copy as nil, and the new bump animation would have appeared simply not to
work **on the exact rig used to judge it**.

**`dev-scripts/lua-forward-refs.py` cannot catch this one**: it checks FILE-SCOPE locals, and both the
declaration and the use are inside `renderRemote`. When adding a field to a table built early in a
long function, check where its value is declared -- the compile check passes either way, because a
nil global is valid Lua.

## A probe committed with a developer's absolute path in it (2026-08-23)

**Third instance, and the last one that had to be caught by eye** — `.githooks/pre-commit` and the
CI tree scan now refuse this mechanically (`136a413`). See the 2026-08-15 and 2026-08-21 entries.

**What happened.** A probe was drafted in the scratchpad with a `SPDIR` placeholder, `sed` substituted
the real absolute path into that copy, and the SUBSTITUTED copy was then copied into `probes/` and
committed. The repo's own leak check (`git grep -inIF -e 'C:\Users' ...`) caught it on the next run --
one commit too late.

**The rule this breaks** is CLAUDE.md's: no personal username, home-directory path or machine-identifying
detail in any tracked file. **And the sequence is the trap, not the carelessness:** a placeholder makes
a file safe to write and unsafe to COPY, because the safety lives in the placeholder and the copy is
taken after it is gone.

**Two habits that would each have prevented it:**
- **A probe resolves its own directory** (`debug.getinfo(1, "S").source`), the way every other probe in
  that folder already does. Then there is no absolute path to leak, in any copy of the file.
- **Run the leak check BEFORE `git add`, not after the commit.** It was run after -- which is how the
  path is now in history rather than only in the working tree.

**Note for cleanup:** a leak in an already-made commit is still in history after the file is fixed.
Fixing forward removes it from the working tree only; removing it from history is a rebase, which is
the user's call and not something to do unasked.

### The fix for it was a hook, not a stricter rule (2026-08-23)

The user asked the right question after this: *"whats the best way to fix this so it don't happen
again ? stricter/more enforced rule about it ? or something else ?"*

**A stricter rule would have bought nothing, because the rule was already as strong as prose gets.**
CLAUDE.md stated it in bold, gave the exact `git grep`, warned that both slash directions and `-F`
are load-bearing, and listed three dated live cases. It was read and broken anyway. Emphasis was not
the missing ingredient, and adding more would have cost lines against the 300-line cap while making
every other rule slightly weaker (`claude-md-cap.md`).

**What was actually missing was a check at the moment of commit.** The rule was obeyed as "scan the
working tree", and the scan was run AFTER committing — so the finding was true and one commit late.

Three layers now, cheapest first:

1. **`.githooks/pre-commit`** scans the STAGED blobs and refuses the commit. Staged, not the working
   tree: they can differ, and the staged content is what becomes history. Install once per clone,
   `git config core.hooksPath .githooks` — hooks are not carried by `git clone`.
2. **`dev-scripts/preflight.ps1`** fails if `core.hooksPath` is not set, so a clone with the hook
   switched off says so instead of looking clean. A fresh clone is exactly that state.
3. **A `paths` job in CI** re-scans the whole tree, catching `--no-verify` and any clone that never
   ran step 1. Late and expensive, but before a release.

**The general shape, worth reusing: when a rule is broken despite being read, do not restate it —
find the moment the mistake becomes expensive and put a machine there.** For anything irreversible,
that moment is always earlier than it feels: here, one commit earlier.

**And verify the guard against the actual failure, not a synthetic one.** The hook was tested by
reconstructing the exact commit that caused this — the same file, with the same substituted absolute
path, staged the same way — and confirming both that it was refused and that `HEAD` did not move.
A guard that has only ever been tested on a case someone invented is a guard of unknown value.

## `pcall` catches errors, not loops — a malformed line froze the emulator (Crystal, 2026-08-25)

**Symptom.** A truncated or malformed line arriving on the bridge freezes BizHawk outright. No Lua
error, no log line, no red script in the console — the emulator simply stops advancing frames.

**Cause.** `jsonDecode`'s object and array loops were `while true` with **no end-of-input check**,
and the fallthrough at the bottom of `parseValue` did `pos = pos + 1; return nil` rather than
raising. So on `{`, `[`, `{"a":1` or `{"type":"state"` the position walks past the end of the
string forever and never matches a closing brace.

**The part worth keeping: the `pcall` wrapper looked like it covered this, and could not.**
`pcall` turns an *error* into a return value; an infinite loop raises nothing, so there is nothing
to catch. A defensive wrapper around a parser is only as good as the parser's willingness to fail
— **a parser that never errors cannot be made safe by the caller.**

**Why only this adapter.** All seven copies of this decoder in the repo were compared: the other
six — Emerald's, and five probes — raise `json: unterminated string` from `decodeString` and carry
an explicit `else error("json: expected ',' or '}'")` in both loops. Crystal's was written fresh
rather than copied, and lost the guards. **Duplicated code does not drift only by being edited; a
fresh reimplementation of the same thing drifts on day one**, and the copy everyone trusts is the
oldest one, not the newest.

**How it was found.** Not by fuzzing and not in a game: by transliterating the function into
another language and running it against a list of truncated inputs with a step cap, so a runaway
shows up as hitting the cap instead of hanging the shell. Valid inputs were run as a control in
the same pass — without that, "everything returned nil" would have looked like the same bug.
**This is a cheap technique for any interpreted adapter code that is awkward to exercise in situ.**

**Fix.** A `pos > #s` guard at the top of both container loops, explicit errors matching the other
six copies' wording, a depth cap (64) so deep nesting cannot exhaust the stack either, and the
silent fallthrough replaced by an error. Confirmed by re-running the harness against the fixed
version: valid input still parses, every malformed input returns `nil`.

**Not remotely reachable**, and worth stating so the severity is not overstated: the core emits
well-formed JSON via `encoding/json` and the framing only dispatches on `\n`, so reaching this
needs a local process on the bridge port — which is what the 2026-08-25 loopback-bind refusal in
`cmd/meshghost` keeps local. Fixed anyway; that assumption is the kind that stops holding.

**Still unconfirmed in BizHawk's own Lua** (`unverified.md`).

## A parked audit rots faster than the thing it audited (2026-08-25)

**Symptom.** A whole-repo doc audit was completed 2026-08-23 and parked unexecuted. Two days
later, working it top-down, its `file:line` coordinates no longer pointed at the right lines and
three of its findings were simply wrong.

**Cause.** An audit is a set of measurements against a tree, and the tree kept moving — one commit
touching `status.md` shifted every line number below it. Worse, an audit reads as *authoritative*
precisely because it is specific: `status.md:40` feels checked in a way "somewhere in status.md"
does not, so the temptation is to act on the coordinate rather than re-derive it.

**The three that were wrong, and they are the useful part** — each was wrong in a different way:

- **A count taken from a list rather than a grep.** It said nine probes carry the Crystal ROM
  guard; the real answer is **ten** — it had enumerated the obvious `spawn_test*` family and missed
  `grant_test_kit.lua`. The file it was correcting said eight. Three numbers, no two alike.
- **A claim about a file that was already right.** It flagged `docs/security.md` for naming the
  relay binary wrongly; that file distinguishes the release name from the built-from-source name
  precisely and needed nothing. Only its neighbour did.
- **A defect generalised past its evidence.** It reported the `jsonDecode` freeze as affecting
  "all Lua adapters". Six of the seven copies in the repo raise on end-of-input; only Crystal's
  does not. Acting on the audit as written would have meant editing six healthy files.

**Fix, and it is a rule rather than a patch: re-grep every claim before writing a correction, and
treat the audit as a list of *questions*, not findings.** Its real value is knowing where to look
— that survives; the specifics do not. Budget for the re-check rather than treating it as
paranoia, because it is what caught all three above.

**Corollary for writing one:** state what was grepped for, not just the conclusion. A finding that
carries its own query can be re-run; one that carries only a line number cannot.

## Two probes had never parsed, and nothing in the repo could have told us (2026-08-25)

**Symptom.** None — that is the entry. `adapters/bizhawk/pokemon/crystal/probes/noclip_off.lua`
and `adapters/bizhawk/pokemon/emerald/probes/framedump.lua` were committed, reviewed and sitting
in the tree as ordinary tools. Neither had ever been a valid Lua file.

**Cause, and it is one this file already warns about twice: a scripted edit wrote Windows
backslashes into Lua source.** `noclip_off.lua` had a hardcoded `"C:\dev\MeshGhost\adapters\..."`
in which Lua had eaten `\a` as a bell, `\b` as a backspace and `\n` as a real newline — so
"adapters" became `<BEL>dapters`, "bizhawk" became `<BS>izhawk`, and the string ran off the end of
the line. It was also prefixed `r"..."`, **Python's raw-string syntax, which Lua does not have**.
`framedump.lua` had an unterminated pattern string from the same class of mangling.

**Why nothing caught them.** A syntax error in Lua is not a loud failure here. BizHawk loads a
script at runtime; a file that does not compile simply never loads, and from outside the emulator
that is indistinguishable from "the ghost did not appear". Neither probe had been loaded since it
was written, so neither had ever announced anything. `dev-scripts/bizhawk-syntax-check.lua` would
have caught both — but it runs *inside* BizHawk, needs a human to point the dev loader at it, and
checks a hand-maintained list of files rather than all of them.

**Fix.** A standalone Lua 5.4 is now installed and `luac -p` gates the whole tree in
`preflight.ps1` and in `.github/workflows/lua.yml` (`environment.md`). It compiles and discards,
so it runs no game code. **All 162 tracked files parse as of 2026-08-25.**

**The general lesson, which is bigger than Lua: a check that requires a human and a running game
is not a gate.** The syntax checker existed for months of project time and had never been pointed
at these two files, because pointing it at anything costs an emulator session. The same check
moved into CI runs on every push and needs nobody. **When a tool exists but keeps not being run,
the problem is usually its trigger, not the tool.**

**And the narrower one:** never let a scripted edit put a Windows path into a language with
backslash escapes. Prefer resolving the script's own directory (`debug.getinfo`), which is what
both files do now, and which removes the reason to write an absolute path at all.
