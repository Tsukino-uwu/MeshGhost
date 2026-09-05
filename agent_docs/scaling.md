# Scaling and efficiency — what the Go side can carry

**Read this before proposing efficiency or scale work on `core`, `relay`, `transport` or the wire.**
It holds the standing principle, the measured numbers, the ranking those numbers produce, and the
decisions already ratified — so a session proposes the next thing rather than re-deriving the last
one. Nothing here is scheduled; like `ideas.md`, an item moves into `plans.md` to become work.

**This file is the Go-side half of a pair.** `crowd-limits.md` answers *how many ghosts a GAME can
hold* — fixed character-slot arrays, hardware sprite budgets, per-game and often per-map. This file
answers *how many the SERVER/CLIENT can carry*. The principle below is the relationship between
them: the game may be the limit; the Go side never may.

## The principle: the Go side may never be the ceiling

**Stated by the user 2026-08-30 and refined the same day.** **the server/client must never be what caps a session. The adapters/games may be
the limit; preferably nothing is.** Their own expected sessions are 2-20 people, but large
community hosts (Archipelago lobbies run 100-1000+) must be POSSIBLE — *"i just don't want to
limit the project itself, i want the adapters/games to be the limit, never the server/client and
preferebly nothing."* So the target is not a player count to plan FOR; it is a prohibition on
designs whose shape tops out. The area filter is the model: it did not raise the limit, it moved
the limit out of the relay and into "how many people stand in one place" — the game's fact, not
ours. Everything below is re-read under that principle rather than under the 2-10 friends the
entries above implicitly assumed. Consequences, recorded so the ranking is read at
the right scale: at n=1000, n x (n-1) is ~a million messages per tick — not slow, DOES NOT RUN —
so the WHO axis is existential rather than an optimization, and the area filter's shape ("the
limit is how many people stand in the same place") is the only one that survives.
Priority-under-budget stops being "if a room ever needs 30" and becomes real roadmap material.
The scale goal is also the strongest future argument for revisiting the wire-format entry: 58%
JSON CPU is a curiosity at 8 states/tick and the bill at thousands. And honestly: other things
break first — the shipped max-clients default is 8, per-client goroutines and TLS handshakes have
never been counted at that size, and nothing has been benchmarked past 16 peers. A 100+ target
needs its own measurement pass before any of the above is re-ranked by it.

## What is in this file, in reading order

- **The four axes** — the map every efficiency idea is placed on, and the measured ranking.
- **Culling — who receives what** — the general culling model, distance culling the downlink,
  adaptive Hz by distance, and culling an isolated player's uploads: all four now live in
  [culling.md](culling.md) (split out 2026-09-02, ~570 lines, one topic).
- **Per-game tested settings** — the Hz x interp sweep each game still needs, and what already ships.
- **The wire format** — JSON vs binary, ratified 2026-08-30, with the tripwire that reopens it.
- **Coalescing writes** — deferred, with the measurement it would need.
- **What a recording costs on disk** — ~310 MB/hour measured, and the three ways to shrink it.

## Efficiency, standing: the four axes, and three additions from the 2026-08-30 pass

**Filed 2026-08-30, prompted by the user:** the server/client will never be finished — it will keep
taking changes forever — so efficiency work needs a standing map, not another one-off list. This
entry is that map, plus the three ideas from this pass that were not already filed elsewhere.

**Every efficiency idea in this file attacks one of four axes.** Place a new idea on its axis
first, and it inherits that axis's measurements and its ranking instead of re-deriving them:

- **WHO receives it** — area filter (shipped), declared sets, distance culling, priority budget.
- **WHEN it is sent** — change suppression (shipped), rate scaling by distance, keepalive floor.
- **WHAT fields it carries** — reduced tier / presence packet, per-field suppression.
- **HOW the bytes encode it** — hand-written encoders, quantization, short keys.

**The standing ranking, measured 2026-08-28 and worth restating once here:** packet COUNT beats
packet SIZE — relay CPU and header overhead scale with how many messages exist, not how big they
are. So WHO and WHEN beat WHAT and HOW, and every win that has mattered so far came from not
sending something. HOW-axis work is still taken when cheap (small wins count — the user's standing
rule), it just never outranks removing a send. **The user's reasoning behind that rule, stated
2026-08-30 and worth keeping with it:** some decisions are effectively permanent — staying JSON
rather than going binary is likely one, per the wire-format entry below — and a permanent
decision's cost is paid forever. Small reversible wins elsewhere are the compensation account for
the losses locked in by the choices we keep: *"we might endup with something we can't change ...
so we have to try and make up for those loses somewhere else instead."* The only bar a small win
must clear is its KEEP cost — maintenance, an extra code path, reader confusion — never its size.

**One idea died on inspection and is recorded so it stays dead:** "stop the relay ticking when
rooms are empty." The relay is event-driven — forwarding runs on the sending client's read path;
there is no tick loop. An idle relay already costs nothing.

### Quantize BEFORE suppressing — the multiplier hiding in shipped work

Change suppression compares states for EQUALITY, so a position that jitters in its fourth decimal
defeats it exactly the way TEVI's `anim_t` did: never equal, always sent. TEVI's measured 70%
proves its idle position is bit-stable. **Pseudoregalia's suppression share is filed below as
unmeasured, and it is a 3D physics game whose capsule may micro-jitter at rest — if it does, its
share could be near ZERO today.** The fix would be adapter-side rounding to sub-visible precision
before the state is handed to the bridge: no protocol change, fewer JSON bytes as a side effect,
and suppression turns ON for that adapter. This is a hypothesis with a named measurement, not a
claim: measure Pseudoregalia's suppression share first (the netsim counters that measured TEVI's
apply unchanged), and if it is already high, this entry closes with no code. Rounding must stay
below what interpolation can show on screen — a visible grid-snap would violate 1:1 and the user
judges that, not the numbers.

### Allocation-count regression tests — the durable half of every win in v1.0.0

If the server changes forever, every efficiency win can be silently lost by a later change, and
`ns/op` in CI is too noisy to gate on. **allocs/op is deterministic.** `testing.AllocsPerRun` (or
`b.ReportAllocs` asserted in a plain test) can pin "the fan-out path allocates N per state" as a
regression test that fails the exact commit that adds an allocation — the same shape as the race
detector failing the exact commit that races. The per-recipient buffer removed in v1.0.0
(`WriteUnreliable`) is precisely the regression it would catch coming back. Start with the two
paths already benchmarked: `forward_bench_test.go`'s fan-out, and `ValidateState`. Pin the number
the day it is measured, with a comment saying what each allocation IS, so a legitimate increase is
a considered edit rather than a mystery failure.

### Short `extras` keys — adapter-side, legal today, ranked last on purpose

Emerald sends 14 `extras` keys on every state and the key STRINGS repeat in every message. `extras`
is opaque by contract, so key naming is entirely the adapter's business — renaming `runningState`
to a short key is a bandwidth trim with no protocol change and no Go-side involvement. It is
HOW-axis and bytes-only, so it never outranks a removed send; filed because the user's standing
rule is that small wins count when they cost nothing. The cost that must stay zero: the keys are
read by humans in `-introspect` and netsim dumps daily, so any shortening keeps a legend in the
adapter's documentation.md, or is not worth its confusion.

## What Hz could Go actually carry? — measured, and it is not a Go limit

**Short version, measured 2026-08-30; the full investigation is [hz-ceiling.md](hz-ceiling.md).**
`MaxSendHz` is 100 and that is a bandwidth-and-safety policy, not a technical wall — relay CPU at
480Hz with 8 players is 2.4% of one core. The real limits, in the order they arrive:

1. **The game's own frame rate**, a hard ceiling on USEFUL rate (Pseudoregalia ticks ~180Hz here).
   The one true thing in "align your tick rate to the engine": a ceiling, not a target.
2. ~~`64 / interp` — a silent edge-hold~~ **FIXED 2026-08-30**: the window now derives from the
   render settings, so nothing edge-holds below 2000Hz. **The wall is now the MILLISECOND
   TIMESTAMPS at 1000Hz**, above which samples share a millisecond and carry no new information.
3. **Bandwidth**, linear and the host's: 1.2 GB/h at 20Hz for a full 8-seat room, 28 GB/h at 480Hz.
4. **Millisecond timestamps** — zero error at rates dividing 1000, up to ±0.5ms otherwise. Bounded
   jitter, never a break.
5. **Go's CPU** — never.

**Raising Hz buys SAMPLING ACCURACY, never FRESHNESS.** A ghost at 480Hz with a 250ms delay is
still drawn 250ms in the past; lateness is `interp`'s to fix. Anyone raising the rate to cure a
"delayed" look is turning the wrong knob.

## Per-game tested settings: the Hz x interp sweep every game still needs (filed 2026-08-30)

**The user's goal:** every game ships values that were actually measured on that game, not one
global number — *"i think 'tested settings' per game would be the best end user experience
possible afterwards"*, accepted as more work than shipping one setting and worth it because
adapters are per-game anyway. **The mechanism for this ALREADY SHIPPED; what is missing is the
measurements.**

**What exists today (do not rebuild it).** ADR 0040 made the render model three per-game knobs, and
`packaging/config-overrides/<game>.json` (moved out of the release tree 2026-09-05) is applied onto the shared
`client-config-template.json` when the release is staged. TEVI already ships `interp: 175ms` this
way, with the sweep quotes recorded in the file itself. Pseudoregalia ships `ghost_collision:
disabled`. **Emerald and Crystal have no overrides file at all** and silently keep the template's
250ms, never netsim-tested.

**The two real gaps:**
- **`min_send` is a config key (`cmd/meshghost/main.go`) that is NOT in the shipped template**, so
  a per-game SEND rate is expressible and undiscoverable. Adding it with a comment is the small
  concrete task that makes an Hz sweep shippable at all. `max_receive_hz_per_player` IS in the
  template but defaults to 0 (off), and the room's forward rate is server-side (ADR 0017), so of
  the three Hz knobs one is hidden, one is unused, one is not the client's to set.
- **A HARD ASYMMETRY that shapes the whole sweep (checked in `core/core.go`, not assumed):
  `min_send` is a FLOOR on the interval, never a ceiling — `effectiveSendInterval` takes the SLOWER
  of it and the relay's advertised rate, so a client may throttle itself below the room and the
  relay "can never speed this Core up past a rate it deliberately chose".** Therefore **a per-game
  client config can make a game send SLOWER, never faster.** If the sweep finds a game wants a
  HIGHER rate, that is not shippable in its config file at all — it needs the host to raise the
  room rate, which applies to everyone. The shippable per-game rate values are reductions (Emerald
  confirmed fine at a lower rate would be free bandwidth); a game that needs more would require an
  adapter-DECLARED preferred rate, the same shape the per-adapter interp idea proposes.
- **Three of four games have never been measured for interp, and none for Hz.**

**The sweep is 2D, and a full grid is unaffordable in live cycles.** Hz x interp is a plane, and
every point costs the user a real game launch — the standing rule after ~3 failed iterations is to
tabulate and try the COMBINATION, not to grind one variable. So anchor on what is already known
and test the coordinates that the shape of each game predicts, rather than sweeping blind:

| game | starting hypothesis (2026-08-30, from the user watching) |
|---|---|
| Emerald / Crystal | *"probly looks perfect already at 20hz and 250ms"* — a tile game moves on a beat, so confirm rather than explore; the win here would be finding it survives LOWER Hz, which is free bandwidth. |
| TEVI | 175ms measured 2026-08-28 and shipped. Hz never varied. |
| Pseudoregalia | *"a bit choppy/low fps at 20hz and 250ms when turning around fast but super smooth when turning around slow"* |

**PSEUDOREGALIA'S SYMPTOM IS ORIENTATION, NOT POSITION — corrected 2026-08-30 by the user, and
the code settles the mechanism.** The observation is specifically about FACING: standing still and
spinning the character with a gamepad — smooth on a slow pan, choppy on a fast spin. Position never
changes in that test, so `curve` and `extrapolate` are not in play at all; an earlier reading of
this entry blamed linear position interpolation and was wrong about which field was stepping.

**`core/interp.go` is explicit: orientation is NEVER interpolated.** It is opaque per `contract.md`
(a `json.RawMessage` the core cannot parse), so the interpolator takes it from the older of the two
bracketing snapshots and holds it until the next real sample passes render time. **Orientation is a
step function**, and interpolation delay does not smooth it — it only delays it. At 20Hz a ghost's
facing snaps 20 times a second: a slow pan has a tiny angular delta per step and looks smooth, a
fast spin has a large one and reads as choppy. That is the observation, exactly.

**Why only this game shows it — and the generalisation for every future adapter:** a stepped
orientation is CORRECT for a discrete-facing game and WRONG for a continuous-rotation one. Pokemon
has four directions and TEVI flips a sprite, so the step IS the truth there. Pseudoregalia is the
only adapter with continuous 3D rotation, so it is the only one where the step is an artefact. Any
future 3D adapter inherits this the day it ships.

**The fix is adapter-side and costs no bandwidth. BUILT AND SHIPPED 2026-08-30, ADR 0043** — the
core may never interpolate a field it is forbidden to parse, so it names the bracket instead
(`orientation_from`/`orientation_to`/`interp_t` on `render_remote`, bridge only, both blobs already
on the wire as consecutive samples) and the Pseudoregalia mod interpolates it. No wire change, no
Hz change, no config key. **Try this before concluding Pseudoregalia needs a higher rate** —
raising Hz would only make the steps smaller and would pay bandwidth forever to hide a step that
should not be there. Note the wording this paragraph carried before it was built: "slerps toward
the newest sample" is the DAMPER, which the fork below rejects. It ships as bracket slerp.

**The names, expanded once, because the file used them as jargon:** `lerp` is LINEAR
INTERPOLATION; `slerp` is SPHERICAL LINEAR INTERPOLATION — the same idea on a sphere rather than a
flat line. The rotation ladder has more rungs than the two named below: **slerp** (shortest arc,
constant angular speed — the correct default), **nlerp** (lerp the quaternion components then
renormalize; cheaper, speed varies slightly mid-arc, invisible at small angles), **squad**
(rotation's `catmull-rom`, four samples, rarely worth it), and **damped/spring** (chase the newest
rotation at a maximum rate, no brackets at all).

**That last one is a real fork for the Pseudoregalia fix, and the easy option is the wrong one.**
A damper is much simpler to write, but position is already interpolated BETWEEN THE TWO BRACKETING
SAMPLES at the interpolation delay — so a damped rotation chasing the newest value would put facing
and position on different clocks, and they would visibly disagree during fast movement: the body
where the peer was an interp-delay ago, the head turning toward where they are now. **Slerp between
the same two brackets keeps them in lockstep**, which is the only version that can reach 1:1.

**ROTATION GETS NO KNOBS OF ITS OWN — it follows the position ones** (asked 2026-08-30: should
nlerp/squad/damped ship as options the way `curve`/`extrapolate` did?). No, and the lockstep
argument above is why, generalised: every position knob must apply to rotation too, or the two
fields run on different clocks and disagree exactly when movement is fastest. So `interp` covers
both, `curve: linear` means slerp, and **`extrapolate: 300ms` must extrapolate rotation by angular
velocity for the same 300ms** — otherwise the body predicts while the head lags, during precisely
the motion extrapolation exists for. **Zero new config keys.** On the individual candidates:
`nlerp` takes the same path as slerp at slightly uneven speed and buys only CPU, which is not the
constraint here (one rotation per ghost per frame, and at most ~18 degrees between samples even on
a fast spin); `squad` is rotation's `catmull-rom`, and `catmull-rom` has never earned its own place
— shipped as an option in ADR 0040, and TEVI chose `linear` anyway — so building the four-sample
version for a field that is not interpolated AT ALL yet is two speculative steps at once. Pair
`squad` with `catmull-rom` if that day ever comes.

**Slerp is not a fourth option beside `linear`/`catmull-rom`/`extrapolate` — it is the first rung
of a DIFFERENT ladder** (asked 2026-08-30, worth pinning because the names invite the confusion).
Those three all interpolate POSITION, component-wise in a flat space. Slerp interpolates ROTATION,
which needs its own math: straight-line-between-two-samples is `linear` for position and `slerp`
for rotation, the four-sample smooth version is `catmull-rom` and `squad`, and each has its own
extrapolation. **This project has never interpolated rotation at all** — the core is forbidden to,
since orientation is opaque and it cannot parse it — so there is no knob, no config key, and
`curve: linear` describes position only. Why rotation cannot simply reuse lerp: yaw 350 -> 10
lerps BACKWARDS through 340 degrees instead of forward through 20, and component-wise quaternion
lerp gives uneven angular speed that slows in the middle. Slerp takes the shortest path at a
constant rate.

**What CAN be smoothed at all — three families, decided by the maths of the quantity** (asked
2026-08-30; generalises to every future adapter, so it belongs in `_template` too if the slerp
fix works on screen):

1. **Vector quantities — lerp works directly.** Position, velocity, scale, camera offset. The space
   is flat, so a straight line between samples is correct.
2. **Cyclic quantities — need wrap-aware interpolation.** Rotation, a compass heading, a hue, and
   ANIMATION PHASE, which runs 0->1 and restarts: phase 0.95 -> 0.05 lerps backwards through the
   whole clip exactly as yaw 350 -> 10 lerps the long way round. **Wrap-aware just means lerp plus
   a shortest-arc correction**: fold `target - current` into the short half of the range (+-180 for
   degrees, +-0.5 for a 0..1 phase) before interpolating, so 350 -> 10 travels +20 rather than
   -340. Slerp is the same principle for quaternions, where the check is negating one of the pair
   when their dot product is negative; a scalar angle or phase gets it far more cheaply.
3. **Discrete quantities — never interpolated, only TIMED.** `anim` tags, `area_id`, booleans.
   There is no midpoint between "walking" and "idle"; the only choice is WHEN the switch lands,
   which is what holding the older sample already does. Its failure mode is a pop at the wrong
   instant — and the related trap this repo already hit is believing a discrete tag over a
   continuous fact (Emerald's drawn tier believed the anim tag and slid, when movement is a
   position fact).

**Where this project stands against those three:** position has all three knobs (ADR 0040);
orientation has nothing (the gap above); **animation phase needs no smoothing at all, for a reason
worth keeping — THE RECEIVING GAME ADVANCES THE CLIP ITSELF**, so a phase sample is a correction
rather than a value to hold, and the game extrapolates it for free (the same let-the-game-do-the-
work pattern that gave the spawned tier its screen culling); and everything else lives in `extras`,
which the core may not smooth by contract, so an adapter syncing a continuous value owns its own
smoothing. Colour is a fourth case, not relevant yet: linear RGB interpolation gives muddy
midpoints, so a CHANGING tint would want a perceptual space — nametag colours are static.

**The arithmetic, which makes the fix testable.** Each step is 1/Hz — 50ms at 20Hz — so the visible
error is ANGULAR VELOCITY / Hz. A fast spin of ~360 deg/s is ~18 deg per step and unmistakable; a
slow pan of ~45 deg/s is ~2.3 deg per step and invisible. Identical step COUNT in both cases, which
is why the rate never feels like the problem until the player spins quickly.

**The 1:1 test is a side-by-side spin**, in the shape already used for renderer comparisons: the
local character's facing is drawn at frame rate, the ghost's at 20 steps a second. A working slerp
makes them indistinguishable at EVERY spin speed — that is the bar, not "better than before".

**Status, 2026-08-30: BUILT, SHIPPED, AND CONFIRMED BETTER ON SCREEN — not yet confirmed 1:1.** A
three-launch A/B (on, off, on, nothing else changed) got *"it looked a bit choppy/low fps in
comparison"* with the flag off and *"its noticable and visually better with slerp on"* with it on,
so the causal link below is now a RESULT rather than a hypothesis. What remains is the bar itself:
indistinguishable at every spin speed, which nobody has asserted. **And the symptom swapped —
choppy became "delayed", which is the interpolation delay becoming legible once the chop stopped
masking it, not a new defect.** `pseudoregalia/VERIFIED.md` carries the run-by-run reads; `pseudoregalia/UNVERIFIED.md` carries the
remaining gap and the re-check the later opt-in change owes. ADR 0043 carries the reasoning. The
three-family rule below is now back-ported to `_template/README.md`.

**The end state:** every game ships a measured overrides file, and the template's values stop being
"what everyone gets" and become "what a game that has not been measured yet gets". That reframing
is worth stating in the template's own comment, because it changes 250ms from a recommendation into
a placeholder — which is what it has always actually been for three of the four games.

**Judged on screen by the user, never by the counters** — the netsim rig produces the bad link, the
counters say what it cost, and only the user says whether it looks right. That split is ADR 0040's
own status line: the Go side is confirmed, *"nothing about how any of it LOOKS is confirmed."*

## The wire format itself: JSON costs ~58% of the relay's per-state CPU (measured 2026-08-28)

**The standing decision this entry argues against is ADR 0002 (2026-08-08), and that ADR is
PROVISIONAL BY DESIGN — "JSON until it hurts", with two named exit conditions: the contract is
stable, and bandwidth is demonstrably limiting. Check both before treating anything below as
actionable** (2026-08-30: contract still moving — ADRs 0039-0042 revised the wire that same week —
and bandwidth not limiting at current scale). One cost of switching that the sections below
under-weigh: the contract's "unknown fields are ignored" rule gives FREE forward compatibility —
0039's and 0041's fields shipped without breaking any older client — and a binary format must
rebuild that with tagged fields or turn every contract revision into a version cutover.

**RATIFIED BY THE USER 2026-08-30, with the full ranking and the scale tables below in hand:**
JSON's benefits outweigh binary's ~30% bytes and single-digit CPU — *"think this probly actually
decided that byte gets burried forever?"* — amended only from "forever" to ADR 0002's tripwire,
because burying it outright would let the server/client cap the very sessions the no-ceiling
principle protects. Practical meaning: nobody spends a line of code on binary unless a real
session's bandwidth demonstrably limits, and if that day comes the state-plane-only path below is
the shape it takes. **Do not re-open this casually; re-open it with a saturation measurement.** The user's underlying
reasoning, same day, and it is the stronger form of the decision: binary trades a bandwidth ceiling
for an EVOLVABILITY ceiling — *"not being able to debug bytes/having to maintain it if adding new
things etc. sounds like a lot of work for a project that has to last in the long run."* Its keep
cost is permanent and compounds with every contract revision (four ADRs added ignored-by-old-clients
fields in one week of 2026-08), while its win is conditional on a day that may never come. A
long-lived project prices standing costs above conditional wins.

**Filed, not scheduled.** Recorded because the number is much higher than anyone had assumed, and
because the obvious conclusion drawn from it -- "go binary" -- is the wrong one for reasons that
are easy to forget and expensive to re-derive.

**The measurement.** After the 2026-08-28 efficiency pass removed the two redundant JSON passes
(`ValidateState` marshaling `Extras` purely to measure it; `forward` re-marshaling a payload
`envelope()` had already produced), a CPU profile of `Room.forwardState` on an 8-member room
carrying an Emerald-shaped state reads:

| | share of the path |
|---|---|
| `encoding/json.Unmarshal` | 34% |
| `encoding/json.Marshal` | 24% |
| `runtime.mallocgc` | 27%, largely driven by the two above |

So the format costs roughly **58% of what the relay spends per state**, and what remains is not
redundancy -- it is the price of the syntax and of walking a `map[string]any` through reflection.
Reproduce with `go test ./relay/ -bench StateFanout/emerald/8 -cpuprofile`.

### Two candidates, and they do not compose

**Hand-written JSON encoders** for the hot types (`State`, `Envelope`). Go's JSON cost is mostly
*reflection* -- walking the struct type, tag lookup, interface dispatch -- not the braces and
quotes, so writing the bytes directly is typically 3-6x faster while producing **identical output**.
No wire change, no protocol version bump, no negotiation, and debuggability is untouched: a raw
socket, `-introspect` and `meshghost-netsim` all still read as text. `protocol.AppendEnvelope`
already proves the pattern, including the differential fuzz target that keeps it honest. It buys
**CPU only** -- not one byte of bandwidth.

**A binary wire format.** Bigger on both axes, since it also removes float-to-decimal formatting,
which runs on every position component. But: a new parser on untrusted input (the highest-risk
change category in this repo, and the reason `protocol/limits.go` and the fuzz corpus exist), a
version bump with negotiation forever, a corpus migration, and an opaque wire in a project that
debugs live sessions daily.

**Its bandwidth win is also smaller here than it looks**, which is the part most likely to be
forgotten: a state is mostly strings and `extras`, and `extras` is **free-form by contract** -- the
core and relay may not know what is inside it. A binary format cannot compress data it is forbidden
a schema for, so it would end up carrying embedded JSON inside binary framing: most of the
complexity, a fraction of the saving. Emerald sends 14 `extras` keys per state; Pseudoregalia's
597-byte lines are extras-heavy.

**And the ranking above still applies to both.** Neither removes a single PACKET, and this file's
own 2026-08-28 finding is that relay CPU and header overhead scale with packet count rather than
packet size -- the same reason per-field deltas ranked last. Every win that mattered so far came
from not sending something (suppression, derivation, area filtering), not from sending it smaller.

### AT SCALE THE RANKING ABOVE INVERTS (estimated 2026-08-30)

**Everything above was reasoned at 8-peer scale, where CPU is the point. Under the no-ceiling
principle it must also be read at 1000.** Ran `go test ./relay/ -bench StateFanout -benchtime 2s`
on 2026-08-30 (Ryzen 5 9600X, emerald shape) and fitted the two terms:

| peers | ns/op | allocs/op |
|---|---|---|
| 2 | 6075 | 83 |
| 8 | 6262 | 84 |
| 32 | 6862 | 84 |
| 128 | 10085 | 84 |

**Fixed cost ~6.0us per inbound state (parse + marshal once, JSON-dominated); per-recipient cost
~32ns (framing + queue, barely JSON at all).** Allocations stay flat as the room grows, which is
v1.0.0's per-recipient allocation removal showing up as a straight line.

That split is the whole finding: **JSON's share of relay CPU SHRINKS as the room grows**, because
fan-out overtakes parsing — ~58% at 8 peers (the measured figure above), ~25% at 128, **~9% at
1000**. So hand-written encoders save ~40-48% of relay CPU at 8 peers and only ~6-8% at 1000.

Extrapolated 1000-peer room, unfiltered, all sending and receiving:

| rate | relay CPU | relay uplink (~350B states) |
|---|---|---|
| 10 Hz | ~0.4 cores | ~3.5 GB/s |
| 20 Hz | ~0.8 cores | **~7 GB/s — does not run** |
| 100 Hz | ~3.8 cores | ~35 GB/s |

Area-filtered to ~8 visible peers at 20Hz it becomes ~56 MB/s (450 Mbps) of uplink — a real
server, not a home host — and binary's ~30% would make it ~39 MB/s.

**CONCLUSIONS, and two of them reverse what is written above.**

1. **CPU is not what breaks at scale; bandwidth is.** The CPU table is survivable at every rate;
   the uplink table is not.
2. **Binary's case gets STRONGER with scale and hand-written encoders' gets WEAKER** — the exact
   opposite of the 8-peer ranking. Binary buys bytes, and bytes are what bind at 1000.
3. **But no wire format saves you at 1000: filtering is not optional.** 30% off an impossible
   number is still impossible. This is the same conclusion the culling entries reach, arrived at
   from the other direction.

**Caveats, so nobody treats these as measurements.** The per-recipient term is fitted from 8->128
and extrapolated 8x past the largest room ever benchmarked; it likely UNDERCOUNTS real network
writes, since the outbox is async and the benchmark does not cross a NIC. Binary's ~30% is capped
by `extras` being opaque by contract. Re-measure at real scale before any of this is acted on.

### "Can we run both -- one for testing, one for release?" (user's question, 2026-08-28)

Yes for one of them, and the difference is the whole argument.

- **Hand-written encoders: trivially yes, and this is what makes them safe.** Both paths emit the
  same bytes, so the choice is invisible to everything downstream -- a build tag, a flag, or even a
  test-only switch works, and the two can be fuzzed against each other continuously. That is not a
  hypothetical: `FuzzAppendEnvelopeMatchesMarshal` already runs exactly that comparison and caught
  three real escaping bugs on its first outings.
- **Binary: yes in principle, no in practice.** Two formats on the wire means negotiating which one
  a connection speaks and maintaining **both parsers against hostile input, forever** -- the
  security surface is the union, not the cheaper of the two. A debug-only text mode also decays
  quietly: it is exercised least exactly when it is needed most, which is when the binary path is
  behaving strangely. If binary is ever adopted it should REPLACE JSON behind a version bump, not
  sit beside it.

### Does binary LOCK US IN permanently? (user's question, 2026-08-30 — checked, not assumed)

**No, and the distinction matters.** `protocol.Version = 1` is carried in Hello and a mismatch is
refused with `ReasonProtocolVersionMismatch`, so a v2 binary protocol REFUSES a v1 client rather
than misparsing it, and a v3 could go anywhere. Nothing is architecturally welded.

**The real lock-in is the installed base.** Once players run released v1 JSON binaries, a v2 binary
relay refuses all of them — a hard cutover where everyone updates or nobody plays. With releases
distributed as a downloadable zip and no auto-update, that cost grows with every release. It is a
RELEASE problem, not an architecture one, and it is the honest reason to decide early rather than
late.

**What WOULD be permanent is supporting both wires**, which is the union security surface
maintained against hostile input forever — the reason the section above concludes "replace behind a
version bump, never sit beside".

**THE MIDDLE PATH NOT PREVIOUSLY CONSIDERED: binary on the STATE PLANE ONLY.** State carries
essentially all the volume (20-100Hz per peer); event, world and control are low-rate and are
exactly where a live session gets debugged by reading a socket. Binary the state plane, keep JSON
everywhere else and you get nearly the whole bandwidth win, a far smaller parser surface, and text
handshakes forever. It also concentrates the win where binary is actually strong: the state's
non-`extras` fields are schema'd (floats to 4 bytes instead of ~8-12 characters, varint seq and
timestamp), while `extras` is the part binary cannot compress anyway. Note it composes with the
plane split this project already has, rather than adding a new axis.

**If this is picked up, the order is: measure, then hand-written encoders, then re-measure, and
only then ask whether binary is still worth its risk.** The hand-written step is reversible and
provable; the binary step is neither.

## Coalescing writes to one peer -- deferred with the measurement it would need (2026-08-28)

**Filed, not scheduled.** ADR 0042 gave every client an outbound queue and a single writer. That
makes coalescing possible for the first time: when the writer wakes and several lines are already
queued for the same peer, they could go out in one syscall, and NDJSON makes the concatenation exact
-- lines already end in a newline and the reader splits them back identically.

**Deliberately not built, because nothing has shown it would pay.** The 2026-08-28 profile puts
~58% of the relay's per-state path in `encoding/json` and the syscall nowhere near the top. The
measurement that would justify it is a profile where write syscalls are actually significant --
most likely a large room on a real socket rather than the discard transport the benchmarks use.

**Three constraints any implementation must respect**, recorded because each is easy to get wrong:

- **Opportunistic only.** Batch what is ALREADY queued; never a timed tick that waits for more. The
  user picked 175ms interpolation for TEVI and called 150ms *"living at the edge"* (ADR 0040), and
  per-adapter tuning may go lower -- there is no latency budget to spend, so the only acceptable
  form adds none.
- **Never on udp or quic.** `netx/udpconn`'s `MaxDatagramBytes` is 1200 and Pseudoregalia's state
  lines are 597+, so two do not reliably fit; and a merged datagram doubles the blast radius of one
  loss on the plane that is deliberately lossy. Detect with the same `unreliableWriter` assertion
  `SendUnreliable` already uses.
- **It is a saving in syscalls and IP/UDP header overhead, not in payload.** That puts it in the
  same class as this file's packet-count finding: it removes per-message overhead rather than bytes.

## What a recording costs on disk: ~310 MB/hour, and the three ways to shrink it (measured 2026-09-03)

**Measured on a real 3-minute Pseudoregalia clip**, not estimated: 15,762 samples, 15,500,011
bytes, ~983 bytes per sample, 87.5 Hz average with 5-12ms between samples. In the unit that means
something to a person: **~310 MB/hour of recording**, and a ten-minute run is ~52 MB.

**The rate is deliberate and should not be "fixed".** The recorder taps at the top of
`forwardLocalState` (`core/sending.go:55`), BEFORE the send-rate limit and before the relay check,
so a recording samples at the GAME's frame rate rather than the 15 Hz `DefaultSendHz` — which is
why a replay looks better than a live peer and why recording works with no relay at all. Cutting
the rate would cut fidelity; the size is worth attacking from the encoding end instead.

**Three shrink options, all measured on that same file:**

| | bytes | vs. raw | costs |
|---|---|---|---|
| as written | 15,500,011 | — | — |
| floats rounded to 3dp | 14,374,946 | 0.93x | nothing visible: 3dp of a UE unit is 10 micrometres |
| rounded + `extras` delta-encoded, `player_id` dropped | 3,555,757 | **4.4x** | a format revision |
| `gzip -9` of the file exactly as written | 802,790 | **19.3x** | nothing — the loader already reads `.ndjson.gz` |
| rounded AND gzipped | 462,375 | 33.5x | shipped for a few hours on 2026-09-03, then withdrawn — see below |
| **rounded + per-KEY delta — WHAT SHIPS** | **3,476,990** | **4.5x** | nothing: still plain text, ~310 MB/hour becomes **~70 MB/hour** |
| rounded + delta + gzip (opt-in) | 398,928 | **38.9x** | ~8 MB/hour, for archiving rather than reading |

**Why whole-line dedup is the wrong shape**, which is the non-obvious part: only **274 of 15,761**
lines carry an `extras` block identical to the line before it, so "skip a line that did not change"
saves ~2%. The reason is narrow — `h_speed` changes on 12,471 lines, `v_speed` on 5,079 and
`slide_t` on 3,989, while **every other one of the 40 keys changes on 117 lines or fewer**. Per-KEY
delta works, per-line does not, and the difference is three jittering floats.

**What shipped (2026-09-03, ADR 0049's sibling commit):** the recorder writes `.ndjson.gz` and
rounds on the way out (`replay.gzip`, on by default, with a plain-file escape hatch since a
recording is a debugging artefact too). Rounding matters more in combination than alone — it is
worth 7% by itself, but it deletes the highest-entropy bytes in the file, so gzip then does far
better: 19.3x becomes 33.5x. **Delta encoding was NOT built** — see `ideas.md`.

**GZIP WAS WITHDRAWN AS THE DEFAULT THE SAME EVENING, and the reason is worth more than the
ratio.** A recording ends when the game closes, which is the NORMAL end of a session — and the
client exits through `watchParentPID`'s `os.Exit(0)`, which ran no cleanup, so the gzip footer was
never written. The data survived (the recorder syncs every second), but `gzip -t` reports
`unexpected end of file` and Windows Explorer and 7-Zip refuse the file outright: *"Error
0x8000FFFF: Catastrophic failure"*, which is what the user actually saw. A plain file cut short at
the same instant loses nothing visible. **Two fixes, not one:** the exit path now closes the
recording before exiting (a bug that outlived the format decision), and plain text became the
default with the size moved into per-key delta encoding, which is lossless, still editable, and
4.5x on its own. Compression stays as an opt-in for archiving, where 38.9x is real.

**The older note on editing, which stands:** the header is the line
people actually hand-edit -- a clip's name, colour, `speed`, `loop` -- and editing it inside a `.gz`
means decompress, change one word, recompress. Two things answer it. A decompressed clip STAYS
VALID, since `replay/active/` takes either extension, so a clip you fiddle with is decompressed once
and left plain. And the recorder now writes `replay.name`/`replay.color` (falling back to the
player's own name and colour) into the header, so a clip is born labelled and the common edit
disappears rather than getting more awkward. The user's call, 2026-09-03: keep gzip, remove the
reason to edit.

**Playback does not need the repetition.** `parseReplay` builds `clip.samples` fully in memory
before anything plays and every seek, rewind and loop indexes into that array, so a carry-forward
reconstruction at LOAD time yields identical samples and no playback path changes at all.
