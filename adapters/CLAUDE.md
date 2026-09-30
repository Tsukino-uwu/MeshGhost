# Adapters — the rules that apply to every one

<!-- line-cap: 300 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**Loaded automatically** the first time this session reads or edits anything under `adapters/`.
Host rules live in the nearest `CLAUDE.md` below this one; per-game facts live in each adapter's own
`documentation.md`, `FLAGS.md` and `BANDAGES.md`. **Capped, and part of every adapter session's rule
stack** (`agent_docs/claude-md-cap.md`): before adding, what comes out? The stories behind these
rules: `agent_docs/pitfalls/by-lesson.md`, "The stories behind the rule files".

## How this folder is arranged: create a level only when two things share it

**The tree's only job is making rules auto-load at the right scope**; grep and the doc index find
things. A folder level is created when a second thing actually shares its rule-set, never in
anticipation: a second emulator creates `emulator/bizhawk/`, a second Unity game creates `unity/`.
Until then host rules sit at the level that exists, which is why `tevi/CLAUDE.md` and
`pseudoregalia/CLAUDE.md` hold Unity and Unreal rules at game scope.

**Do not sort adapters by anything a reader would have to look up.** Engine and commercial category
were both rejected (user's call): the release a player installs is flat and named by game. Where
access genuinely differs, that is an **access model**; `agent_docs/access-models.md` is its one home.

## Build the live-reload loop before the first feature, on every host

(User, 2026-08-28.) Per-host table, the five traps that reported success while doing nothing, and the
scratch-slot rule: [_template/README.md](_template/README.md), "BUILD THE LIVE-RELOAD LOOP FIRST";
`/new-adapter` has the detail. **Two things it can never test:** a cold-start bug, and the orphans a
reload leaves in the scene, so despawn everything you spawned in your teardown. **On a new host, ask
where the adapter runs**: as its own process over IPC, reload is free by construction; prefer that shape.

## Anything the player can do, a ghost must be able to do

(User, 2026-08-19.) **This is the standing answer to "the engine cannot do that for a ghost".** A ghost
is a character the same way the player is, so the game already contains a working implementation of
whatever is asked for; if it looks impossible, the mechanism has not been found yet.
[effect-investigation.md](../agent_docs/effect-investigation.md) is the how-to-search playbook.

- **A painted tier has no engine behind it**, so every rule the hardware applies for free (priority,
  occlusion, palette, flip) has to be found and reproduced rather than approximated.
- **The proper mechanism is the goal, not the fallback.** The test is what is being worked around, not
  how hard the fix looks: a hardware ceiling (the console runs out of something and the game hits the
  same wall, e.g. Crystal's object cap) is the legitimate case; a mechanism not found yet is not.
- **A bandage is held to the root `CLAUDE.md`'s 1:1 bar, as a floor, not a licence**: one that merely
  gets close is refused outright; one indistinguishable on screen is still registered in that adapter's `BANDAGES.md`, naming the real
  mechanism and why it could not be used. **Two bandages for one feature means the mechanism was never
  found**: go back and find it. Sorting rule and what a ceiling bandage owes: [BANDAGES.md](_template/BANDAGES.md).
- **It cuts the other way too:** a ghost is not judged on what a player cannot do. Artefacts seen only
  in a rig that places a ghost where no player stands (the compare rig's side offset) are the rig's;
  say so rather than building a rule around them.

## Reproduce the whole effect: the animation and its extras

**A state is not just a pose.** If the game spawns something alongside it (a trail, a splash, a
shadow, a dust puff, a held item, a mount), the ghost needs that too; the Emerald surf blob is the
worked example ([effect-investigation.md](../agent_docs/effect-investigation.md)). When mirroring any state:

- **Perform it in the real game and count what appears** (objects, sprites, field effects) before
  deciding what to copy; the graphics table describes one sprite and says nothing about companions.
  **Ask what else the state owns**: TEVI's charged-attack VFX and Pseudoregalia's ultra-hop trail are
  the same question in other games.
- **If the extras are not done, the state is not done.** "The animation plays" is not "the state is
  reproduced".
- **Hang the extra on every path into the state, and remove it on the way out**: enumerate the doors
  into a state; a peer patched in place never runs a spawn-only path.
- **Build the extra by diffing it against a live one the game made**, never from the template alone:
  a constructor computes fields no description contains. Method: [probes.md](_template/probes.md),
  "Diff what you BUILT against what the game BUILT".

## Peer values get clamps, peer keys get allowlists, peer names get a local catalog

A peer string never reaches a global object lookup: an asset name resolves only through a catalog of
the local game's own loaded assets of that class. It refuses nothing a same-game watcher could render
(mods included) and prices spam at a hash lookup. Mechanism: `resolve_peer_named_asset`, `pseudoregalia/.../Plugin.cpp`.

## Reproduce the effect, never adopt a handle the engine can recycle

**A structure that stores another object's id is safe for the engine, which owns every lifetime
involved, and unsafe for you, who own none of them.**

- **Copy what the effect does, not the data structure that does it.** **A game class is structure too:
  a singleplayer constructor may claim the player; build visuals from engine components you own, never
  the gameplay class.**
- **If you must hold an engine handle, re-validate it every use**, never against "it was valid when I
  stored it".
- **Two writers on one field is its own bug**: decide which side is the authority and let the other stop.
- **Never re-use a despawned entity's resources in the tick that despawned it**: free on one tick,
  allocate on the next.
- **"Our code broke the game" is found by bisecting features, before anyone reads code**: adapter
  dropped, tier off, effects off, one effect on. Method: [probes.md](_template/probes.md).

## Honour every shared setting, or say in your log that you cannot

A key in the shared config template is **generic by definition**: what the player wants, not a fact
about any game, so every adapter honours it. **How** is yours; **whether** is not. The mechanism and
its numbers are per-game and belong in that adapter's `FLAGS.md`, never in the player's config.

**An adapter that cannot honour one logs that once, at startup, rather than silently appearing to
comply.** **`render_remote.cosmetic: true` outranks `ghost_collision` from room and client: a
replay/chaser ghost is a picture, never solid or damageable** (ADR 0047; `_template/PROTOCOL.md`).
**The adapter that turns collision on is the one that has to implement it.**

## The adapter may not cost the game its frame rate

**The standard (user, 2026-08-20 and 2026-09-01): the game's intended base fps, for every adapter,
as a shipping requirement**; for an emulated game that is the console's own rate.

**Measure it against a control before believing any number**: the same route, the same probe, one
variable, and the identical run with nothing loaded; the machine has its own floor. Harness and
instruments: [probes.md](_template/probes.md), "Price a suspicion before fixing it". **The five costs
that actually showed up** (symptom → cause → fix: `agent_docs/pitfalls.md`), all general:

1. **Never allocate what the engine will immediately free.** A spawn decision asks "will this survive
   the engine's own housekeeping?", not merely "is there a free slot?".
2. **A front end's console is a GUI append, not a print; a file is not.** A handful of load-time lines
   go to the console (`say()`); every per-frame or per-second path goes to the file (`log()`).
   The emulator how: `emulator/CLAUDE.md`, "A per-second log line".
3. **"In use by the engine" and "in use by us" are different questions.** Anything claimed by asking
   the engine "is this free?" has a window where our own claim is invisible to it: exclude what you
   already hold, and audit for duplicates so a collision announces itself.
4. **Probes come off when they are not answering a question**, and a flag that is merely not set is
   not off (below).
5. **Never enumerate the whole world per ghost per tick**: scope scans to the ghost's own attach tree.
   **And a flag-gated diagnostic must not pay its cost when unarmed.** Timer and audit method:
   `_template/probes.md`.

**A per-frame diagnostic is a shipping decision, not a debugging convenience**: off by default,
flag-gated, and unloaded once the question is answered.

**If the host loads scripts into one shared environment, an isolation run is only valid when the
flags are exhaustive**: a global set by an earlier flags file survives a swap. Set every flag
explicitly, false included, and read the adapter's own startup lines for what is actually enabled.
**Find the counter that reports work done, and treat its absence as a result.**

## Never move a ghost faster than the game moves, or in units the game does not use

**Speed.** Whatever a renderer compensates, catches up or repays, the visible result never exceeds the
pace the engine uses for that action: **constant lag is invisible on screen and a change of speed is
not**, so trading the first for the second is never a good trade.

**Units.** If the engine moves 0, 2 or 4 pixels a frame and never 1, a 1px correction is smoother than
the game and reads as shimmer. **The engine's rhythm is as visible as its speed**: find the quantum
before writing anything that nudges a position.

**Do not save up a correction and pay it in one go**: a debt paid at a boundary is a snap by
construction. Repay continuously and finely, or decide the error is a constant offset and leave it.

## A tier handover is a position handover, and it needs an overlap

Any adapter with more than one way to render a peer will switch between them while the peer is on
screen. Both must hold or the switch is visible:

1. **Both tiers agree where the peer is at that instant.** They will not by default: one usually
   carries a smooth sub-tile position and the other snaps to a grid.
2. **No frame is left empty: hold the old tier until the new one is seen drawing, never for a counted
   number of frames.** Release on evidence (the object's entries in the sprite table), bounded so a
   peer whose object never appears cannot pin the old tier. **A gap is visible; an exact overlap is not.**

**Fix the position first**: overlapping two tiers that disagree draws the peer twice. **Do not "fix" a
handover by removing the transition** (Crystal's idle rule is load-bearing); make the seam invisible.

## Files every adapter keeps honest

- **`FLAGS.md` is the flag register, five kinds of switch, not just compile-time bools: when a flag's
  comment and its value disagree, the register and the value win.** Flags that only work as a set are
  marked there; never switch one off alone.
- **`documentation.md` is the game's mechanics and nothing else**: no bandages, rule text, file
  history or adapter-design asides; only what we measured or saw on a running copy, plus its known
  unknowns (the root `CLAUDE.md`, "measured or observed only").
- **User-facing, so no working notes**: the adapter's `README.md`, `documentation.md`, `BANDAGES.md`
  and `SYNCED.md` (every sent key, and its check on arrival, never an empty cell). Audit queues,
  "edited on" markers, rule history and "treat this as unestablished" go to `UNVERIFIED.md`, the phase
  file or `status.md`.
