# Adapters — the rules that apply to every one

**Loaded automatically** the first time this session reads or edits anything under `adapters/`.
You do not have to go and find it, and it costs nothing on a session that never touches an
adapter. Host-specific rules live one level down (`bizhawk/CLAUDE.md`); per-game facts live in
each adapter's own `documentation.md`, `FLAGS.md` and `BANDAGES.md`.

**Capped at 300 lines**, for the reason the root `CLAUDE.md` is: this loads without being asked,
so it spends the same instruction budget, and an uncapped auto-loading file recreates the problem
the cap exists to prevent (`agent_docs/claude-md-cap.md`). Before adding: what comes out?

**This file never restates the root `CLAUDE.md`.** Anything already there stays there — a rule
with two homes is a rule that drifts, which this repo can already demonstrate in two places.

Moved verbatim from `adapters/_template/README.md` on 2026-08-25, where they were reachable only
by reading 1,723 lines end to end. `_template/` keeps a headed pointer at each site.

## Hard rule: anything the player can do, anything else should be able to do

**User, 2026-08-19:** *"anything the player can do, anything else should be able to do"*, and, when
told a piece of behaviour might not be reproducible: *"it is, we just have to figure out how. the
game is doing it on the player itself after all"*.

**This is the standing answer to "the engine cannot do that for a ghost".** A ghost is a character
the same way the player is, so the game already contains a working implementation of whatever is
being asked for — reflections, bobbing, animation, shadows, occlusion. If it looks impossible, the
mechanism has not been found yet; that is a statement about the search, not about the game.
[effect-investigation.md](../agent_docs/effect-investigation.md) is the how-to-search playbook,
and the surf blob is the worked example: `UpdateSurfBlobFieldEffect` looked hardcoded to the player
and turned out to read an object id out of its own sprite data, so pointing it at a ghost drives the
whole effect for free.

**Where this bites hardest is a PAINTED tier**, which has no engine behind it — so every rule the
hardware applies for free (priority, occlusion, palette, flip) has to be found and reproduced rather
than approximated. That is real work and it is the work; "the painted one cannot do that" is not an
acceptable resting place.

**The proper mechanism is the goal, not the fallback.** User, 2026-08-19: *"I prefer doing things
the proper/intended way when achieving 1:1, so we should not try to use bandages often/for
everything"*, and *"we shouldn't use bandage/temp fixes for things the game can actually already do
properly due to us being lazy."*

**The test is what is being worked around, not how hard the fix looks.** A HARDWARE CEILING is the
legitimate case — the console runs out of something and the game has no mechanism either, because
it hits the same wall (Crystal's object cap, and the painted overflow tier that answers it). A
mechanism we have simply not found yet is not, and it is the common case: **if the player has this,
an implementation exists and is reachable.** Full sorting rule, and the cost a legitimate ceiling
bandage still owes: [BANDAGES.md](_template/BANDAGES.md).

The 1:1 test is what a bandage must still pass if one is ever justified — the same user, on the
same day: *"its probly a bandage then, but think thats fine if we can get it to look identical to
the player and spawned ghost. I want 1:1 after all."* So it is a floor, not a licence: a
compensation that merely gets close is refused outright (see the bandage rule below), and one that
is indistinguishable on screen is still registered in that adapter's `BANDAGES.md` naming the real
mechanism and why it could not be used. **Two bandages for the same feature is a sign the mechanism
was never found**, and the right move then is to go back and find it.

**It cuts the other way too:** a ghost should not be judged on what a player CANNOT do. The compare
rig offsets a painted ghost sideways by a couple of tiles, which can put a surfer on grass;
artefacts seen only there are the rig's, not the adapter's. Say so plainly rather than building a
rule around them.

## Hard rule: reproduce the WHOLE effect — the animation and its extras

**A state is not just a pose.** If the game spawns something alongside it, the ghost needs that
too, and shipping the pose alone is shipping a bug that looks like a half-finished character.
User, 2026-08-18, on a ghost given the surfing graphic: *"surfing is also supposed to show a 'Blue
thing you are riding on' not just the animation itself... we should do the animation + extra
things if there are any, not just the animation and miss extras/VFX"*.

The Emerald case is the clean example. Every special player state — both bikes, surfing, fishing —
is a different `graphicsId`, so switching the graphic *looks* like the whole job. It is not:
surfing also spawns a **separate sprite for the Pokémon being ridden**, attached through the
object's own `fieldEffectSpriteId`. The ghost rendered as a rider sitting on nothing, which is the
half a player notices first.

**So, when mirroring any state:**

- **Perform it in the real game and count what appears** — objects, sprites, field effects — before
  deciding what to copy ([effect-investigation.md](../agent_docs/effect-investigation.md) has
  the diffing method). The graphics table describes one sprite and says nothing about companions.
- **Ask what else the state owns**: a trail, a splash, a shadow, a dust puff, a held item, a
  mount. TEVI's charged-attack VFX and Pseudoregalia's ultra-hop trail are the same question in
  other games.
- **If the extras are not done, say the state is not done.** "The animation plays" is not "the
  state is reproduced", and the difference is exactly what a person sees.
- **Hang the extra on EVERY path into the state, and remove it on the way out.** Emerald again,
  2026-08-19: the blob was created only where a ghost is built from scratch, while a peer walking
  into water reaches the same state by having its graphic *patched in place* — so the code was
  correct and never ran in the case it existed for, and the ghost rode on nothing while its log
  said the state was right. Enumerate the doors into a state before deciding one of them is the
  door. The exit matters as much: Emerald's blob follows an object id stored in its own data, so
  one left behind swims along under a peer walking down a road.
- **Build the extra by DIFFING it against a live one the game made**, never from the template
  alone — a constructor computes fields no description contains, and the same blob spent a day
  drawn a tile out of place because of one of them. Method: [probes.md](_template/probes.md), "Diff what you
  BUILT against what the game BUILT".


## Hard rule: reproduce the EFFECT, never adopt a handle the engine can recycle

**A structure that stores another object's id is safe for the engine, which owns every lifetime
involved, and unsafe for you, who own none of them.** Learned twice in Emerald on 2026-08-21, the
second time costing hours and a black-screened game.

The engine's underwater bob is a dummy sprite whose callback nudges *another* sprite, named by
index. Copying that structure faithfully worked exactly as long as the ghost it named stayed
alive. Once the engine recycled that slot, our copy wrote into whatever landed there -- during a
dive, the picture the game was busy showing -- which corrupted it and left an effect waiting
forever for a sprite that could no longer report itself finished.

**What to do:**

- **Copy what the effect DOES, not the data structure that does it.** The bob turned out to be one
  number the peer was already sending. The engine's shape was never needed.
- **If you must hold an engine handle, re-validate it every use**, against the identity marker from
  the section above -- never against "it was valid when I stored it".
- **Two writers on one field is its own bug.** An intermediate version drove the same bob from both
  the wire and our own code; the user saw it as the ghost *"moving really fast/weird"*. Decide which
  side is the authority and let the other one stop.
- **Never re-use a despawned entity's resources in the same tick that despawned it.** Freeing tiles
  and immediately allocating them for the replacement gave Emerald a scrambled ghost: the engine had
  not finished with them yet. Free on one tick, allocate on the next.

**The bisect that found it is the method, and it is cheap.** Adapter dropped -> fine. Tier off ->
fine. Tier on, effects off -> fine. One effect on -> broken. Four runs, no theory. Any "our code
broke the game" hunt should take that shape before anyone reads code.


## Hard rule: the adapter may not cost the game its frame rate

**The standard, user 2026-08-20: *"i don't want to ship/release anything that can't even keep the
intended base fps"*.** For an emulated game that is the console's own rate -- 60fps for a GBA or a
Game Boy -- and it is a shipping requirement, not a nice-to-have. A ghost nobody can see because
the game is stuttering is worth less than no ghost at all.

**Measure it against a CONTROL before believing any number.** Same route, same probe, one variable:
a scripted ride with the adapter, and the identical ride with nothing loaded. The machine running
the emulator has its own floor -- Emerald's control dipped to 37fps on seam crossings with zero
scripts loaded -- and without that run, the game's own map loading gets attributed to whatever was
loaded at the time. The harness and the two instruments are in [probes.md](_template/probes.md), "Price a
suspicion before fixing it".

**The four costs that actually showed up, in the order they bit** (all Emerald 2026-08-20,
symptom -> cause -> fix in `agent_docs/pitfalls.md`) -- every one of them applies to any emulator
adapter, because none is about that game:

1. **Never allocate what the engine will immediately free.** An engine culls objects outside its
   own view. Respawning one it just culled starts a loop -- allocate, cull, allocate -- that costs
   tile allocation and sprite setup every cycle and produced 217ms frames. A spawn decision must
   ask *"will this survive the engine's own housekeeping?"*, not merely *"is there a free slot?"*.
2. **The front-end's console is a GUI append, not a print — and ONE line a second is already too
   many.** Measured 2026-08-21 on Emerald: a probe logging a single `console.log` once a second ran
   **50.7 avg fps against a 58.1 control**, and sending that same line to the file instead recovered
   all of it — 58.1, exactly the control, with the feature it was measuring still running. The cost
   is not per line; it scales with **what the console window already holds**, so it grows through a
   session and gets harder to attribute the longer you work. This entry used to say the danger was
   events arriving in BURSTS. That was too generous, and the measurement above is why it no longer
   says it. **Split the two calls**: a `say()` for the handful of orientation lines at load, and a
   `log()` on every per-frame or per-second path that only ever writes the FILE. Full numbers and
   the subtraction that found it: `agent_docs/pitfalls.md`, 2026-08-21.
3. **"In use by the engine" and "in use by us" are different questions.** Anything claimed by
   asking the engine *"is this free?"* -- object slots, sprite slots, VRAM tile ranges -- has a
   window where our own claim is invisible to that question, and a second peer will land in it.
   Exclude what you already hold, and audit for duplicates so a collision announces itself.
4. **Probes come off when they are not answering a question**, and a flag that is merely not set
   is not off -- see below.

**A per-frame diagnostic is a shipping decision, not a debugging convenience.** Enumeration of an
array every frame, a string built per object per frame, a file write per frame: each is affordable
alone and none of them is affordable together. Off by default, flag-gated, and unloaded once the
question is answered.

**If the host loads scripts into one shared environment, an isolation run is only valid when the
flags are exhaustive.** MeshGhost's dev loader shares one Lua environment across every script it
loads, so a global set by an earlier flags file survives a swap -- an A/B "with the trace off" ran
with it on throughout. Set every flag explicitly, false included, and check the adapter's own
startup lines for what is ACTUALLY enabled rather than trusting what the flags file requested.


## Hard rule: never move a ghost faster than the game moves, and never in units the game does not use

Two halves, and the second is the one that gets missed.

**Speed.** Whatever compensation, catch-up or error-repayment a renderer performs, the visible
result may never exceed the pace the engine itself uses for that action. A ghost covering ground
faster than a player can walk is doing something no player can do, which fails the 1:1 bar on its
own — and it is worse than the lag it repays, because **constant lag is invisible on screen and a
change of SPEED is not.** Trading the first for the second is never a good trade.

**Units.** The correction does not get its own units either. If the engine moves 0, 2 or 4 pixels
per frame and never 1, then a 1px correction is *smoother than the game* and reads as shimmer rather
than as motion. Crystal, 2026-08-23: a repayment of 1px per frame kept every frame within walking
speed and still looked wrong, because the model advances 2px on its beat and the correction filled
the gaps — a clean `2-0-2-0` cadence became `2-1-2-1`. **The engine's RHYTHM is as visible as its
speed.** Find the quantum before writing anything that nudges a position.

Corollary worth stating, because it is the fix that keeps getting reinvented and keeps being worse:
**do not save up a correction and pay it in one go.** A debt paid at a boundary is a snap by
construction, whatever the boundary is — the end of a walk, an arrival, a state change. Repay
continuously and finely, or decide the error is a constant offset and leave it alone.

## Hard rule: a tier handover is a POSITION handover, and it needs an overlap

Any adapter with more than one way to render a peer — an engine object and a painted copy, a
hardware sprite and a software one — will switch between them while the peer is on screen. Two
things must both be true or the switch is visible, and Crystal got each wrong in turn on 2026-08-23:

1. **Both tiers must agree where the peer is at that instant.** They will not by default: one
   usually carries a smooth sub-tile position and the other snaps to a grid. Crystal's promotion
   placed the engine object on the peer's CURRENT tile while the painted copy was still a full tile
   behind — measured at exactly `-1,+0` every time, because the promotion is triggered by the peer
   moving, so it fires precisely as the peer leaves the tile the painted copy stands on.
2. **Neither frame may be left empty.** Dropping the old tier on the same frame the new one is
   created leaves one frame with nothing drawn, because an adapter paints during its own tick while
   a freshly created engine object is not in the sprite list until the engine next builds one. One
   missing frame is a blink. **A gap is visible; an exact overlap is not** — so overlap the two by
   one frame.

**Order matters:** fix the position first. Overlapping two tiers that disagree about position draws
the peer twice, a tile apart, which is worse than the blink.

Finally, **do not "fix" a handover by removing the transition** — Crystal's is the idle rule that
stops a stationary ghost blocking a doorway, and it is load-bearing. Make the seam invisible instead.

