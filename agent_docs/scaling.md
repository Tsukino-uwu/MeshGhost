# Scaling and efficiency — what the Go side can carry

<!-- line-cap: 800 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

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
- **The culling model** — one model for every adapter, and the display-vs-draw rule it turns on.
- **Distance culling the downlink**, and the uplink entry it mirrors.
- **Adaptive Hz** — per-recipient send rate banded by distance, and the interpolation bound on it.
- **Per-game tested settings** — the Hz x interp sweep each game still needs, and what already ships.
- **The wire format** — JSON vs binary, ratified 2026-08-30, with the tripwire that reopens it.
- **Coalescing writes** — deferred, with the measurement it would need.

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

## A general culling model for every adapter — declared SETS and TIERS, not a rule per game (filed 2026-08-30)

**The user's question, 2026-08-30:** does Pokemon need its own kind of culling, or should there be
one overall model that covers TEVI, Pseudoregalia and every future adapter — given that top-down
tile, 2D and 3D games see different distances and that Pseudoregalia's zones are far coarser than
its rooms? Answer: one model, two primitives, and most of what is wanted is already reachable
without a protocol change.

**Granularity is ALREADY the adapter's choice.** `area_id` is opaque to the core — compared by
equality, never interpreted — so what an "area" *is* was never decided by the Go side. Pseudoregalia
reports the UE Level's full name (`Plugin.cpp:12011`), TEVI reports its area enum
(`Plugin.cs:2359`). Moving Pseudoregalia from zone to room granularity is **not** a core or relay
change; it is that adapter reporting a finer string, and the shipped `own_area_only` filter starts
culling per room the same day. Nothing in `core` or `relay` learns anything about the game.

**THE RULE THAT DECIDES GRANULARITY: cull to the widest thing the adapter DISPLAYS, not the widest
thing it DRAWS.** This is the trap, and TEVI is the live example the user suspected. Its pause-map
marker gates on `state.AreaId == currentLocalArea` (`Plugin.cs:383`) — a peer's marker appears
because that peer's state is arriving while they are anywhere in the zone. Switch TEVI to room-level
`area_id` and the ghosts get cheaper while the map marker silently loses everyone outside your own
room. The character is drawn per room; the map is displayed per zone; the wider one sets the floor.

**Which is why the model needs TIERS, not one on/off filter.** Three levels, decided by the adapter,
applied by the relay with equality and arithmetic only:

- **Full state** — peers whose character is actually rendered (own room, own screen, within R).
- **Reduced state** — peers displayed only in the abstract: a map marker, a room list, a nameplate.
  Position and identity at a slow rate; no animation, orientation or `extras`. This is the same
  **presence packet** the uplink entry ("Stop sending when nobody can see you") already specifies, so one mechanism serves both
  directions rather than two designs meeting in the middle.
- **Nothing** — everyone else.

**THE REDUCED TIER IS A THIRD AXIS OF SENDING LESS, and naming it that way keeps it apart from
what already ships.** Temporal: skip the message when nothing changed (shipped). Per-FIELD: fewer
fields per message (filed below, unbuilt; TEVI's `anim_t` removal was a hand-rolled instance).
Per-RECIPIENT: different amounts of the SAME state to different people, which is new — today every
recipient gets identical bytes, which is exactly why the shipped filter can only be all-or-nothing
per peer. The reduced tier is per-field and per-recipient together.

Two things follow. **Most of the cost is the message, not its fields** — header, relay write,
receiver wake-up — so trimming ~140 bytes to ~40 saves less than it reads; the reduced tier must
also drop its RATE (a map marker needs a position a few times a second, not 20-100), and that is
where its saving actually comes from. And **encode each tier once per state, never per recipient**,
the same discipline as the per-recipient allocation removed in v1.0.0.

**What is missing in the protocol today is the middle, not the concept.** `own_area_only` is binary:
your own area, or the entire room. Emerald and Crystal render maps in their connection list, which
is neither, so they decline filtering entirely and receive everything. **A declared SET of
`area_id`s** — the areas I currently render, refreshed as the player moves — is still equality-only,
still game-blind, and gives them real filtering back for the first time. It is also exactly what
TEVI's tiers need: full set = my room, reduced set = my zone.

**What falls out per game, with no new game knowledge in the Go side:**

- **Emerald / Crystal** — full set = own map + connected maps (the adapter already computes this
  list); distance inside the set is an optional extra, and probably worth nothing on a map that
  mostly fits the screen. Measure before building.
- **TEVI** — full set = current room, reduced set = current zone, which keeps the pause-map marker
  working while making ghost traffic room-scoped. Today it is zone for both.
- **Pseudoregalia** — its `area_id` is the UE Level, so "per room" needs the adapter to define
  sub-areas from the level's own geometry. Long sightlines in 3D mean a set alone is the wrong tool
  for the big rooms: this is the case that actually wants **distance with hysteresis** (send within
  R, stop at R + margin, seed on entry), since a hard room boundary is what would make peers pop.

**For future adapters the two primitives cover both world shapes:** equality-on-a-declared-set for
discrete worlds (tiles, rooms, levels), distance for continuous ones (3D, large open rooms). They
compose — a set first, distance inside it. Anything cleverer, such as line of sight or occlusion, is
game knowledge and stays in the adapter, which is free to simply not render what it receives.

**Build order, cheapest first:** (1) declared set of `area_id`s, which unblocks Emerald and Crystal
and costs no new concepts; (2) the reduced tier, reusing the presence packet; (3) distance with
hysteresis, for Pseudoregalia's big rooms — see "Distance culling the DOWNLINK" below. Each step
gets shadow counters before code, the way the area filter's 93% was known before the filter existed.

### Prior art, and the build order it revised (2026-08-30)

**PROVENANCE, because this section is unlike the checked one at the top of this file: everything
below is GENERAL KNOWLEDGE stated from memory on 2026-08-30. No source was read, no documentation
page was opened, and nothing here was verified.** The Monster Hunter World observation is the
user's own, from playing. The Unreal and Quake claims are the shape of well-known engine behaviour
and are good enough to REASON with — they are not good enough to BUILD against. Before any of it
informs code, check it against a documentation page and re-date it, per CLAUDE.md's rule that
nothing traceable to nowhere gets used. No licensing question arises: these are concepts and
published behaviour, not any project's source.

The discipline has a name — **interest management** / **area of interest** — and its framing is
wider than culling: for each observer, every entity gets a RELEVANCE, and relevance decides not
only whether you hear about it but how OFTEN and in how much DETAIL. Four levers, as used across
the industry:

- **Relevance / culling** — grid-cell subscription (your cell plus its neighbours, which is exactly
  the declared-set idea above) or a distance radius with hysteresis. MMOs also hard-cap it
  ("the 50 nearest players") so a capital city cannot melt.
- **Frequency scaling** — send it, but rarely: near entities every tick, far ones every 5th or 10th.
- **Precision reduction** — quantized positions, dropped axes, no animation phase for something four
  pixels tall.
- **Prediction / dead reckoning** — send rarely AND extrapolate on the receiver, so a low rate does
  not look like one. Quake-derived engines pair this with delta compression against the last
  acknowledged snapshot.

**Why MMOs cap visible players is not purely bandwidth** (asked 2026-08-30): the binding constraint
is usually the CLIENT's CPU — skinning and animating hundreds of characters — then the server's
fan-out, which is our own n x (n-1) term, with bandwidth the most graceful of the three. Culling
looks like a network feature because it is the one lever that fixes all three at once. For us the
middle term is the one that matters.

**Monster Hunter World's distant monsters animating at ~5fps** is the same principle applied to
animation rather than networking, and it is standard enough that Unreal ships it by default
(skinned-mesh update-rate optimization: evaluate less often with distance, interpolate between).
The principle behind every lever: SPEND DETAIL WHERE ATTENTION IS.

**Unreal's networking is the reference design** — a cull distance beyond which an actor is not
replicated, a per-actor update frequency, and a priority score used to spend a fixed per-connection
bandwidth budget each tick. **We cannot use it and should not try.** It needs the game running as a
net session with a netdriver and connection-owned replicated actors; more decisively, an adapter
may never send bytes off-machine (CLAUDE.md), and UE replication IS an off-machine transport. It is
also not a fast path, it is a featureful one — and those features can be built in the relay we own,
where they then serve BizHawk and Unity too.

**RATE SCALING IS THE CHEAPEST ITEM ON THIS WHOLE LIST, and it was mis-ranked above.** It needs no
protocol change and no second encoding: the relay already decides per recipient whether to forward,
so "forward every Nth state to peers beyond R" is a DROP RULE. Two safety rules, both already
learned in another form:

- **Never drop the last state before a peer goes still**, or the ghost freezes mid-stride in the
  wrong pose. Same shape as the area filter's crossing-state rule.
- **Thin change-driven states, never the keepalive floor.** Change suppression already made states
  rare; a quiet peer at one keepalive per 250ms, thinned to every 4th, is one update per second
  against a 3s stale timer — which is how ghosts disappear.

**Extrapolation belongs WITH rate scaling, not on its own.** `-extrapolate` already exists as a
global opt-in. Its failure mode is overshoot-and-snap, which is least visible on someone far away —
so "thin the rate for distant peers, extrapolate to cover the gap" is safe precisely because it is
applied where mistakes do not show. Global is the setting that makes it risky.

**Occlusion is never the relay's.** A peer behind a wall in your own area is sent, and always will
be: geometry is game knowledge. The adapter is free to receive and not draw, which is what the
Emerald draw path already does.

### Priority under a budget — the shape, if the tiers ever outgrow themselves

Instead of discrete full/reduced/none, each peer gets a score and the sender spends a byte budget
top-down each tick.

- **Where:** the relay, per recipient, per tick. It is the only party that knows everyone, and the
  state plane is explicitly allowed to lose messages, so dropping is legal there in a way it is not
  on the reliable plane.
- **Scoreable without game knowledge:** same-area (equality, already cached), distance (arithmetic;
  needs a `lastPos` cache mirroring the `lastArea` cache added in v1.0.0), staleness (ticks since
  this recipient last heard about this peer), and whether the sender is moving.
- **Staleness MUST be a term in the score**, rising each tick a peer is skipped. That is what turns
  "starved" into "merely delayed" and guarantees eventual delivery.
- **Three things exempt from the budget**, all learned by the area filter: the state carrying a NEW
  area (it triggers despawn — drop it and the ghost stands frozen at the doorway for the full 3s
  stale timeout), the seed an arriving client gets, and the keepalive floor.
- **The cost trap, and the distinction it turns on (sharpened by the user, 2026-08-30 — "wouldn't
  it make sense to save cpu/bandwidth whenever its possible?").** THE SAVINGS ARE ALWAYS ON; only
  the ORDERING is conditional, and the two must not be conflated:
  - A **threshold** — "beyond R? send every 4th" — is O(1) per peer, needs no global view, and
    should always run. Culling and rate scaling are thresholds. They save at 2 players exactly as
    at 30, and on the common setup the host is also PLAYING, so relay CPU competes with their own
    frame time. There is no "we are not busy enough to bother".
  - An **ordering** — rank every peer, spend a budget top-down — is n^2 log n across a room and
    produces a different answer ONLY when demand exceeds supply. Below the budget it is arithmetic
    with no consequence, so the sort is skipped; the cheap path stays exactly as cheap as today.
    Precedent: the relay's existing per-client 120/sec cap.

  So priority is not a better rate scaling, it is TRIAGE on top of it: policy always on, ranking
  only for what policy could not fit in the pipe.
- **What it buys over tiers:** the room cap becomes a bandwidth number rather than a player count,
  and degradation is gradual — far peers get choppier before anyone disconnects.

**The scale principle this entry is read under has been hoisted to the top of this file.**

**Ghost/replay games are prior art for PRESENTATION, not the wire** (user's read, 2026-08-30, and
it is correct): Trackmania and kart ghosts are mostly replay files — downloaded or local, no live
netcode — so they say little about networking and a lot about how many translucent ghosts stay
readable on one screen without occluding the game. That question arrives the day a big room works.

**The generalized let-the-game-do-the-work rule for culling, in one line:** every game already
maintains an active set — loaded maps, streamed levels, object pools — because it must answer
"what exists right now" every frame to run at all. **A future adapter's `area_id` granularity
should be the game's own load/unload boundary**, which is what Emerald's connection list, TEVI's
rooms and Pseudoregalia's UE levels each already are. Ask the game, not the genre.

**BUILD ORDER, revised by the 2026-08-30 conversation:** (1) rate scaling by distance — no protocol
change, needs only the `lastPos` cache and the two safety rules; (2) the declared SET of `area_id`s,
which unblocks Emerald and Crystal; (3) the reduced tier; (4) priority-under-budget, only if a room
ever needs to hold 30 people. Shadow counters before each, the way the area filter's 93% was known
before the filter existed — and note that (1)'s `lastPos` cache is the prerequisite for MEASURING
any of it, since the relay cannot compute a distance today.

## Distance culling the DOWNLINK: `own_area_only` with a declared radius (filed 2026-08-30)

**Origin:** the user, reading v1.0.0's release notes, asked why "culling" wasn't already
screen-distance based — *"tought culling was actually being done outside of the screen ... its
kinda what i intended when asking for culling to begin with"*. Three different culls exist, and
they were being read as one, so this entry starts by separating them.

**What already exists today**

- **Drawing is screen-culled.** `meshghost_emerald.lua`'s draw path skips any peer whose sprite
  falls outside 240x160, and the walk-cycle timer is inside that check rather than beside it, so
  an off-screen peer costs nothing to draw AND nothing to animate. The spawned tier gets the same
  for free from the engine's own object culling.
- **The adapter culls by MAP ADJACENCY, not distance.** Emerald renders peers on its own map plus
  maps in its connection list and hides everyone else; that one rule is simultaneously the
  houses-hidden rule and the distance cull, because two maps away is not in the list.
- **The relay culls by `area_id` EQUALITY** (shipped 2026-08-28, ADR in `architecture.md`). A
  client that declares `own_area_only` stops being sent the rest. 16 peers over 8 areas suppress
  93% of offered state bytes; 16 in one area suppress 0%, which is the control.

**The gap:** inside a single area, nothing is culled on the wire. A peer 900px away on a large map
is sent, received, buffered and then discarded by the draw check above — the work is done at every
stage except the last one. A single-area room is the shipped filter's worst case by construction,
so this is the case worth attacking next.

**The shape, if built:** a new optional field beside `OwnAreaOnly`, NOT anything in `extras` —
`extras` is opaque to the core by contract (`protocol.go:49`), so the relay may never read it. The
adapter declares a radius in its own units (a game-specific number that stays adapter-side, exactly
as `RenderAllAreas` does today), the core forwards it as a declaration, and the relay applies pure
game-blind arithmetic to coordinates it already relays. Absent means send everything, for the same
load-bearing reason `own_area_only`'s absence does.

**It only works WITHIN an area.** Coordinates are in the sender's own map frame, so the distance
between peers with different `area_id`s is not a number the relay can compute; translating them
needs the connection offsets, which are game knowledge that must stay in the adapter. So this
composes with the area filter rather than replacing it: equality first, then distance inside the
match.

**The hard part is the edges, and it is harder here than for areas.** A map boundary is a discrete
crossing event; a radius is continuous. Both non-optional rules the area filter needed come back in
continuous form:

- **Hysteresis, not a threshold.** Send within R, stop beyond R + margin, or a peer pacing the
  boundary flickers. The area filter got this free from map geometry.
- **Seed on entry, before anything is visible.** The area filter had to deliver the crossing state
  and seed an arriving client precisely because change suppression means a motionless peer only
  re-states every keepalive — walk into a radius with no seed and the room looks empty for up to
  250ms. Emerald's 7-tile margin exists to prevent exactly this pop-in on the draw side.

**Measure before building, with the method that sized the area filter.** Shadow counters shipped
2026-08-18 where the real filter would later run, so 93% was known before a line of filtering
existed. Same move: count what share of forwarded states are already outside a plausible R in a
real single-area room. If a Pokemon town or a TEVI screen is small enough that everyone in the area
is usually on screen anyway, the answer is near zero and the edge cases above are not worth buying.
Emerald and Crystal would not benefit regardless while cross-map rendering is on — they decline the
area filter for the same reason.

**Related:** the uplink half of this question is "Stop sending when nobody can see you" below,
whose third rung ("Nobody within N tiles") deferred distance for this same reason. This entry is
the downlink mirror and answers the "unless the relay does it from coordinates it already relays"
carve-out that entry left open.

## Adaptive Hz: rate as a percentage of the room's rate, banded by distance (filed 2026-08-30)

**The user's proposal**, extending the Monster Hunter World observation in the prior-art section:
a server setting that scales a PERCENTAGE of the room's configured Hz by how far a peer is —
*"20hz if someone is right next to you, 0-1hz if they are the room next over, 5-10hz if they are
in the same room but like really far away on the other side of it where it won't be noticable"* —
with the expectation that it needs per-game visual tuning the way interpolation delay does.

**"Can the server send at multiple Hz at the same time?" Yes, and it is the cheapest form of any
of this, because THE RELAY HAS NO CLOCK.** It is event-driven: clients send, it forwards on the
sender's own read path. So per-recipient Hz is not multiple timers — it is a counter per
(recipient, sender) pair and a modulo test. Nothing new is scheduled, nothing new is encoded.

**Achievable rates are DIVISORS of the source rate, not arbitrary numbers.** A drop rule can only
forward 1 in N, so a 20Hz sender yields 20, 10, 6.7, 5, 4, 3.3 Hz and nothing between. Percentages
are still the right CONFIG surface (a host thinks in "half rate", not "every 2nd"), they just round
to the nearest divisor. Say so in the config's own documentation or the setting will look broken.

**Two knobs, and they belong to different owners** — the same split the rest of this file uses:
- **The adapter declares what near and far MEAN**, in its own units, because 8 tiles and 800
  Unreal centimetres are unrelated numbers. Same shape as the per-adapter interpolation idea in
  `ideas.md`, and the same reason `own_area_only` is adapter-declared.
- **The host declares how aggressive to be** — the percentages per band — because that is a
  bandwidth/quality trade belonging to whoever pays for the uplink.

**THE CONFIG SHAPE (user, 2026-08-30): one boolean on the SERVER, on by default.** *"a user can
decide if they want a set/fixed hz to always be used, or if they want the adaptive to try and be
more efficient ... only disabled manually for example if someone want 100hz and always 100hz no
matter what."* No client setting is needed for the POLICY — the relay decides what it forwards, and
this inherits two existing patterns rather than inventing one: the room's send rate is already an
operator knob (ADR 0017) and ghost collision is already a host-set room policy the relay tells
clients about (ADR 0035). Adaptive Hz is a modifier on a knob the host already owns. It also
belongs in the relay's startup log beside the existing `room send rate: NHz` line, which is where
an operator checks what a room is actually doing.

**But the boolean alone cannot be safe, for two reasons that put the ADAPTER back in the loop —
as a declaration, not a setting:**
- **The relay has no idea what "far" means.** It can compute a distance; it cannot know whether
  400 is close. The bands must be adapter-declared, which gives the natural fail-safe: **an
  adapter that declares no bands gets NO thinning even with the setting on**, exactly as absent
  `own_area_only` means send everything. A new or untuned adapter is then never silently degraded,
  and "on by default" stays honest rather than shipping an unwatched visual change — which the
  1:1 bar and the never-assume-game-intent rule would both refuse.
- **The relay cannot see the interpolation delay** that bounds thinning (below); that is
  client-side, so the client declares it the way it already declares `own_area_only`.

**THE HARD BOUND IS INTERPOLATION DELAY, and it is what will actually limit the bands.** A peer
thinned to 5Hz has 200ms between samples; if the interpolation delay is shorter than the gap, the
receiver's buffer runs dry and edge-holds — the ghost does not move slowly and smoothly, it
FREEZES AND JUMPS, which fails the 1:1 bar outright. So either the receiver adapts its delay per
peer from the observed interval, or the maximum thinning is capped at the delay. This couples
directly to "interpolation delay should be PER ADAPTER" and should be designed with it, not after.

**The "room next over" band is already solved and should not be rebuilt here:** a different
`area_id` is culled entirely today for clients that opt in, and the case where you still want to
KNOW about them (a map marker, a room list) is the reduced tier / presence packet described above,
not a 1Hz full state.

**The two safety rules from the prior-art section apply unchanged:** never drop the last state
before a peer goes still (a frozen mid-stride pose is worse than a lower rate), and thin
change-driven states rather than the keepalive floor.

**Testing is per-game and on screen, like the render knobs (ADR 0040), and the variable is not
world distance.** What decides whether thinning is visible is APPARENT motion — pixels per second
across the screen — which is constant with world distance in a fixed-zoom top-down game and varies
with perspective in 3D. So a band tuned in Emerald tiles transfers to Crystal and not at all to
Pseudoregalia, and a 3D game may need the band expressed in screen terms by the adapter rather
than in world units. Expect the netsim rig plus an A/B with one variable per run, and expect the
user to judge it, not the counters.

## Per-game tested settings: the Hz x interp sweep every game still needs (filed 2026-08-30)

**The user's goal:** every game ships values that were actually measured on that game, not one
global number — *"i think 'tested settings' per game would be the best end user experience
possible afterwards"*, accepted as more work than shipping one setting and worth it because
adapters are per-game anyway. **The mechanism for this ALREADY SHIPPED; what is missing is the
measurements.**

**What exists today (do not rebuild it).** ADR 0040 made the render model three per-game knobs, and
`packaging/release/games/<game>/client-config-overrides.json` is applied onto the shared
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

**Pseudoregalia's symptom names its own cause, and it is probably NOT the rate.** Choppy on fast
turns and smooth on slow ones is the signature of LINEAR interpolation across a direction change: a
straight line between two samples interpolates a straight path perfectly at any rate, and cuts the
corner exactly when the path bends. That is what `curve: catmull-rom` was added for in ADR 0040,
and **it has never been tried on Pseudoregalia**. It is free, already shipped, and costs no
bandwidth — so it must be A/B'd BEFORE any conclusion that this game needs a higher Hz, or the
project will pay bandwidth forever for a fix that a spline gives away. Same logic for
`extrapolate`, which hides lateness at the cost of a correction when the guess is wrong — a
momentum game is where it is most likely to earn its keep.

**The end state:** every game ships a measured overrides file, and the template's values stop being
"what everyone gets" and become "what a game that has not been measured yet gets". That reframing
is worth stating in the template's own comment, because it changes 250ms from a recommendation into
a placeholder — which is what it has always actually been for three of the four games.

**Judged on screen by the user, never by the counters** — the netsim rig produces the bad link, the
counters say what it cost, and only the user says whether it looks right. That split is ADR 0040's
own status line: the Go side is confirmed, *"nothing about how any of it LOOKS is confirmed."*

## Stop sending when nobody can see you — cull an isolated player's uploads

**Requested 2026-08-21.** *"don't send your ghost data to the server whenever there is no one
around you — basically culling when someone is isolated, no need to send their data to the server
if no one else can see them anyway."*

Most of a singleplayer session is spent alone: a room of one, or a player two maps from anybody.
Every one of those position updates is uploaded, relayed nowhere, and dropped. On the host that is
the expensive direction — the README's own numbers grow with the square of room size — and for a
player on a metered or mobile connection it is upload spent for nothing.

**Where the knowledge is, and it decides the design.** Only the relay knows who else is in the room
and (per `area_id`) who shares a place; the core knows only what it has been told. So the honest
shape is the **relay telling the core to go quiet**, not the core guessing. That keeps the core
game-agnostic — it compares `area_id` by equality, which it already does, and never learns what an
area is.

Three levels, each strictly cheaper than the last:

- **Room of one.** Nobody else is connected. Unambiguous, needs no `area_id` reasoning, and covers
  the case of starting the game before a friend joins. The obvious first version.
- **Nobody in your area.** Everyone else is elsewhere by `area_id`. Bigger win in practice — a
  12-player room is usually 12 people in 12 places — and still equality-only.
- **Nobody within N tiles.** Needs distance, which is a game-shaped question; **out of scope for
  the core** under the game-agnostic rule unless the relay does it from coordinates it already
  relays. Note it and leave it. The DOWNLINK mirror of exactly this — the relay declining to send
  a peer who is in your area but far away — is worked out in "Distance culling the DOWNLINK" above
  in this file (2026-08-30).

**The hard part is not the culling, it is coming back.** A player who has been silent for a minute
and then walks into someone must appear *immediately and correctly*, not on the next heartbeat and
not at a stale position:

- The relay must un-cull **before** the peer can see anything — the moment a peer enters the room
  or the area, not once movement is noticed, or the first ghost pops in late.
- The first packet after silence has to be a **full state**, not a delta from a state nobody kept.
- A culled player must still be **known to be present** (a slow keepalive) or a room list, a
  nameplate or a join sound has nothing to show, and the relay cannot tell "quiet" from "gone" —
  which the udp path already gets wrong for 60s (`status.md`).
- **Never cull the receive direction**, only the send: a lone player must still see someone arrive.

**Worth measuring rather than assuming:** how much a heartbeat-only idle stream actually costs.
A useful shape is a floor rather than silence — the send rate collapsing to a keepalive — which
sidesteps most of the resume problem while keeping nearly all of the saving.

**The shape the user asked for, 2026-08-21, and it is the better default:** *"maybe just send the
bare minimum. no positions or anything just 'current area' or something so it stays alive but use
way less data."* Not silence — a **presence packet**: who you are and which `area_id` you are in,
and nothing else. No position, no facing, no animation, no graphic.

Why that is the right minimum rather than an arbitrary one:

- **The area is exactly what the relay needs to decide.** Culling is an area question, so the one
  field that must keep flowing is the one the decision is made on. A player who dives, enters a
  cave, or crosses a seam un-culls themselves by saying so — the relay does not have to guess from
  silence, and there is no window where somebody walks up to a ghost that stopped existing.
- **It removes the "quiet or gone?" ambiguity for free**, which plain silence introduces and which
  the udp path already gets wrong for up to 60s.
- **It is most of the saving.** The expensive part of the stream is the 20-100 Hz position update,
  not identity — and a presence packet only needs to go out on a CHANGE of area plus a slow
  keepalive, so an idle player costs a few packets a minute instead of thousands.
- **It keeps room lists, counts and nameplates working**, which full silence quietly breaks.

The resume rule from above still applies and gets easier: the first packet after presence-only must
be a **full state**, not a delta — the relay never had a position to delta against.

**Third rung, same ladder (requested 2026-08-21) -- THE WHOLE-STATE HALF SHIPPED 2026-08-28**, see
ADR 0039: a core no longer restates an identical state, with a 250ms keepalive floor and a bracket
re-statement on resume so no receiver interpolates across the silence. What is described below as
per-FIELD suppression is the part still unbuilt, and it is a protocol revision rather than a patch.
TEVI is the adapter this saves nothing for, because it sends animation phase every frame: *"clients should not send new values if they
have not changed since the previous ones... we don't really need to send things we already know
from before already."* Not culling but **change suppression**, and it applies all the time, not
only when isolated:

- **A standing player's stream is almost entirely repeats.** Position, facing, graphic, animation
  — identical packet after identical packet at 20-100 Hz. Suppressing repeats collapses the idle
  cost of every player, which stacks with the culling above (an isolated player's stream first
  shrinks to repeats, then the repeats stop going out).
- **Per-field, not per-packet, is where the real win is**: while moving, the position changes every
  tick but `gender`/`gfx`/`area_id` almost never do. Sending only changed fields turns the steady
  packet into position-plus-orientation. This is a WIRE FORMAT change (fields become optional, with
  "unchanged" as the default meaning), so it belongs behind a protocol rev, not a patch.
- **The traps are the resend rules, all shapes of one rule: "unchanged" is relative to what the
  RECEIVER knows.** A late joiner has seen nothing, so every peer owes them a full state; a
  reconnect after a drop likewise; on udp a suppressed field rides on a lossy channel, so
  "I sent it once" is not "they have it" — either changed fields repeat for a few packets, or the
  keepalive carries a periodic full state as a correction, the same way video streams key-frame.
- **The adapter already half-does this at the edge**: Emerald's sender debounces the graphic and
  pairs it with its offset before publishing. That is suppression for CORRECTNESS; this idea is the
  same mechanism for COST, generalised across every field and done once in the core (game-agnostic
  — "has this value changed?" needs no knowledge of what the value means), not per adapter.

### Ranked by measurement, 2026-08-28 -- and per-field deltas are NOT the biggest win

Measured on the netsim rig: **~136 bytes per state** on the wire, so a shipped 20Hz room costs
about **9.8 MB/hour** per uploading player before IP/UDP overhead (another ~30-50 bytes a packet).
Against that baseline the three candidates rank opposite to intuition, because **relay CPU and
header overhead scale with PACKET COUNT, not packet size**:

| Option | Idle cost at 20Hz | Verdict |
|---|---|---|
| **Do not send a value the receiver can DERIVE** (TEVI's `anim_t` while a clip loops) | **~4 packets/s, ~2 MB/h** | **BUILT AND CONFIRMED 2026-08-28** -- 70% of states suppressed, 49.8 -> 16.5 MB/h, and the user's read was *"looks identical"*. `adapters/tevi/VERIFIED.md` |
| Quantise that value instead | ~no saving | Dead end: a 1/32 step still changes faster than a 20Hz send rate, and a step coarse enough to help (1/8) exceeds the 0.06 phase tolerance and visibly seeks |
| **Per-field deltas** (the entry above) | ~4-6 MB/h | Real but smallest, and by far the most expensive |

**Why deltas cost the most for the least here:** they shrink packets without removing any, so the
relay still parses, validates, re-encodes and fans out the same number of messages. They need
capability negotiation (absent must flip from "not present" to "unchanged", reinterpreting every
existing message), keyframe/resend rules for late joiners, reconnects and udp loss, and -- the part
to weigh hardest -- **the relay would have to hold per-peer state to reconstruct full states**,
weakening the property the ACE audit leaned on: today it keeps nothing and re-encodes every message
from a parsed, validated struct.

**THE LINE THAT DECIDES WHETHER A SAVING IS FREE (user's synthesis, 2026-08-28): suppressing a
value the receiver can DERIVE EXACTLY is free; suppressing one it can only GUESS is extrapolation
under another name, and costs exactly what extrapolation costs.**

A looping idle's phase is derivable: the ghost plays the same clip at the same rate, so recovering
it means running the animation it was already running -- zero error, indefinitely. A running
player's POSITION is a guess: the receiver must assume the velocity holds, and every stop or turn
is that assumption being wrong and having to be repaid. Dead reckoning with an error threshold
would buy bandwidth during sustained movement in exactly that currency -- the lag on direction
changes, the overshoot and the floor-sink measured in the same session's render sweep, which is
why TEVI's shipped pick turned prediction OFF. The threshold would also be in GAME UNITS, so the
core could not own it.

**The rule to generalise instead: do not send what the receiver can derive for itself.** Pokemon
already gets the full benefit (a standing player's states are byte-identical); Pseudoregalia's
per-frame values go constant when idle and should too, **unmeasured -- the one piece of this left
to check**; TEVI was the only adapter with a continuously-advancing field and is now done.

**The safety property that makes this uncontroversial** (user's constraint, 2026-08-28: *"i don't
want normal gameplay to look/feel weird due to data not being sent. but we don't have to send
'everything' all the time either"*): suppression skips only a BYTE-IDENTICAL state, so any
movement, clip change, effect or hitstop resumes full rate instantly. Active play cannot degrade;
only a motionless peer is affected, and the phase re-anchors the moment they act -- so the idle
drift is bounded by how long someone stands perfectly still, not by session length.

**Not scheduled.** Nothing here is committed until it moves into `plans.md`.

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
