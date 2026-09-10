# How TEVI works

## Before adding anything to this file

**Explain facts; never reproduce expression.** Measured numbers, timings, field/function/type
*names*, and behaviour described in your own sentences are all fine. Source text in any language,
decompiler or disassembler output, asset content or extracted strings, verbatim reflection or memory
dumps, and data tables copied wholesale are never fine — **regardless of what a licence permits**.

**The test: could someone re-derive this by owning the game and watching it?** If yes, it is a fact
and may be explained; whatever you learned it from only saved you the time, and is not the source of
your right to know it. If the only way to have it is to copy something, it stays out.

This is [CLAUDE.md](../../CLAUDE.md)'s standing rule — *is this fine sitting in a public repo
forever?* — applied to prose. No, or merely unclear, means out. Full guidance and the two edge cases
worth knowing: [adapters/_template/README.md](../_template/README.md).

> Everything here is **measured from a running game** during Phase 6 (2026-08-12 onward), and
> cross-checked by inspecting the game's own managed assembly locally to learn real type and member
> *names*. **No decompiled source, asset content, or verbatim dump is reproduced here** — only
> facts, per `agent_docs/licensing.md`. The game's assemblies are never committed.

**What this file is: how *the game* does things**, per mechanic, in our own words. **Nothing here
describes an adapter workaround** — those belong in [BANDAGES.md](BANDAGES.md).

**A section belongs here only once the mechanic is actually established** — what it does, and what
it does under the cases that matter. Half-mapped mechanics go to "Known unknowns" at the bottom
instead, where a later session can strike one through and point at the section that answered it.
Facts watched on screen are marked `[player]`; facts read by instrumenting the running game are
`[measured]`.

Dated evidence: [`VERIFIED.md`](VERIFIED.md) ·
[`phases/phase6.md`](../../agent_docs/phases/phase6.md).

**Written 2026-08-18**, after this adapter shipped. Previously it was argued that a game with a
readable managed assembly did not need one; the user overturned that, and the reason generalises —
being *able* to look something up is not the same as having looked, and a curated description of the
mechanics an adapter depends on is a different artifact from the assembly it was learned from.

## Finding the player

The player character is reached through the game's own event system rather than by searching the
scene: `EventManager.Instance` exposes **`mainCharacter`**.

One practical detail, discovered the hard way and worth stating because it is a property of the
build rather than of our code: `mainCharacter` is a **property backed by a private field** in the
current build. Which of the two exists is a version-dependent fact, so anything reading it
has to tolerate either shape.

Both `EventManager.Instance` and `mainCharacter` can legitimately be **null** — during loads, menus
and scene changes. That is normal game state, not an error condition.

## Position: the logic position and the drawn position are different

A character carries two positions that do **not** coincide:

- **`t.position`** — the character's transform: its logical position in the world.
- **`spranim_prefer.pixel.transform.position`** — where the *visual* actually sits.

The offset between them is real and non-zero. This is the single most useful thing to know about
rendering a second character in TEVI: placing a clone at the logic position alone puts the visible
sprite in the wrong place, because the game's own visual hangs off a child transform with its own
offset.

## Animation: a Unity `Animator` on a sprite, addressed by clip name

**Playable characters are not Spine.** They are a plain `SpriteRenderer` plus a Unity `Animator`;
`PixelCharacter` carries no Spine reference at all. Spine *is* used in this game — around fourteen
boss and environment types use it — so "TEVI uses Spine" is true of the game and false of the
player, and that distinction is the one that matters when cloning a character.

The currently-playing animation is obtainable as a **clip name string** from the sprite-animation
component (`spranim_prefer.GetAnimationTrueName()`), which reads the `Animator`'s own current clip
info rather than any state enum the game keeps alongside it.

That name is what makes a cosmetic clone tractable: a peer's animation can be carried as an opaque
string and handed straight back to the clone's own `Animator`, with no invented name-mapping table
and no need to model the state machine that chose it. The core never interprets it — animation tags
are opaque outside the adapter that produced them.

## Facing is a sprite flip, not a rotation

The character faces left or right by **flipping the sprite**, not by rotating a transform. The
component that must be flipped is the sprite-animation logic component, not only the base sprite —
flipping one and not the other produces a visibly half-mirrored character.

## The map screen is its own system

The full map screen is a separate component (`FullMap`) with its own representation of where the
player is — a private `playerPos`, a `maxroom` **stride** into its flat room-tile list, and per-room tiles (`FullMapTile`) that carry
their own transforms. Marking a position on the map screen means placing something at a *tile's*
transform, in the map screen's own space, rather than converting world coordinates.

**This is a genuinely separate coordinate system from the world one**, and the two do not convert
into each other.

## Saves and progression

`SaveManager` owns save state. **MeshGhost never writes it** — `CLAUDE.md`'s absolute rule — and it
is named here only because it is the component a reader will otherwise go looking for.

## The pause overlay and the main menu are different states, and only one drops the player

TEVI's Characters/pause overlay leaves the player object alive: it stays non-null while the overlay
is up, and returning to the **main menu / title** does null it. The *behaviour* was confirmed live
2026-08-13 and is recorded in `agent_docs/phases/phase6.md`, which is where the detail sits.

**The member this is read through is `EventManager.Instance.mainCharacter`** — settled by reading
the adapter, where `PlayerControl` appears nowhere. [measured] An earlier revision of this passage
named `PlayerControl.instance`; whether that is a real game type that simply is not what we read is
a question about the game rather than about us, and it sits in "Known unknowns" below. **Nothing was
changed on the strength of it** — this is the exact file whose pause-menu reasoning produced the
2026-08-18 false regression, and reasoning from code about what a game means is what caused it.

That single difference is what lets a `player == null` check tell "the player left the session"
apart from "the player opened a menu" — without it, a pause would be indistinguishable from
quitting. It is the reason peer ghosts can stay on screen while you are in the pause overlay, which
is the intended, wanted behaviour (user, 2026-08-18), and disappear when you actually quit to the
title.

**Be precise about which menu when describing this.** Bare "menu" is ambiguous in a game with both,
and on 2026-08-18 that ambiguity alone produced a false regression report about working code.

## Warp devices: the animation is in `Update`, the save and the heal are in the triggers

A warp device wakes into an "assembling" glow while a character stands in it and settles when they
step off. [player, 2026-08-28 and 2026-09-02]

**`WarpDevice.Update()` produces the entire visual** — the assembling animation, the particle
scale, the light intensity — from two private ready flags and the last animation it played. Nothing
about the look depends on the trigger callbacks. [measured]

**Every side effect lives in the trigger callbacks instead**: an autosave, a heal, the interaction
prompt and the minimap icon all fire from `OnTriggerEnter2D` / `OnTriggerStay2D`. [measured]

**The heal is applied to `EventManager.Instance.mainCharacter`, not to whatever entered the
trigger.** A second character standing in a portal heals the *local* player. [measured] This is the
single most useful fact in the section: it is why letting the game's own trigger fire for a
non-player character is not an option, however correct it looks.

**Membership is the device's own trigger collider**, tested by overlap — so "in the portal" is the
game's own shape rather than a radius somebody chose. [measured] **A scene change hands out new
device ids**, so anything keyed on one has to be dropped at a transition. [measured]

## Projectiles: a pool, and a death that is not a despawn

**Bullets come from a pool.** A slot is reused, so "which bullet is this" is a slot plus what the
slot currently carries, never the slot alone. [measured]

**A bullet's death is the frame it STOPS, not the frame its slot frees.** On a wall the game calls
its destroy path: the bullet halts and plays a pop for roughly a sixth of a second before the
despawn clears the slot. Anything watching only the slot sees the bullet alive for that whole pop.
[measured]

**The game's wall test has two arms with different scopes.** One reads the area's tile grid by
absolute position and is valid wherever a character is; the other overlaps the colliders loaded for
the room the local player is in, and is therefore only meaningful there. Treating them as
interchangeable makes wall behaviour depend on how far away the shooter is. [measured]

**"Cannot pass wall" is not a property a bullet is born with.** The lock-on shot grants itself that
flag a frame or two after launch, from inside the per-bullet behaviour routine. Reading it at birth
reads it before it exists. [measured]

**The per-bullet behaviour routine is not a small thing to run.** It reaches several hundred
shoot sites plus bomb, laser and wall-action spawns, tile destruction and a camera shake — which is
why it cannot be sandboxed by guarding the bullet pool alone. [measured]

**A pool slot's kind is an enum, and enum ORDINALS differ between game builds.** Two installs of
TEVI at different versions disagree about which number means which bullet and which sprite; the
names do not move. [measured, across two installs 2026-09-10]

## Core expansions: an orb becomes a humanoid, and comes back

The B-button orbitar skills. The path runs from the character's boost call through the boost system
to an "orbs to humanoid" event, and the sequence is fixed: **the orb is hidden**, a trail object
flies from the orb to a freshly created Celia/Sable made with no AI and started invisible; about a
third of a second later it plays its arrival clip, turns visible, becomes a non-player character,
runs the boost logic, plays its departure clip, a trail flies back, it despawns, and the orb
returns. [measured]

**A non-player Celia or Sable in the character list IS the local player's core expansion** — the
game identifies its own the same way. [measured] Anything else wearing that shape has to be
distinguishable by construction, or the game will find it.

**There is an older, unused path** through the orb's own skill flags and a summon boss type. Nothing
in the current build triggers it. [measured] Reading it as the live mechanism produces a mirror that
compiles, runs and shows nothing.

## The boost shield is a shader mesh the game parks INACTIVE between uses

**The shield object is left disabled when not in use**, so anything cloned from it is born with its
initialisation never having run — no materials, and the first call that touches one throws.
[measured]

**Its material setup builds four materials from the renderer's CURRENT material, then strips an
activation keyword from the base one.** Run twice — as it is on a copy of an
already-initialised object — the second pass builds every material from the stripped copy, and the
activation materials never get the keyword back. The visible result is a shield that pops on and off
at full opacity instead of blooming and fading. [measured]

**The camera keeps its own list of shields to post-process**, and membership is not implied by
existing. [measured]

**Two sprites fade in beneath a boosting character** — the game calls them boost platforms, and
they are part of this mechanic rather than a movement feature. [measured]

## The afterimage trail: the game picks one every frame

**The character's sprite-animation component carries the trail's rate, decay, colour, sort order and
an effect-layer flag**, and they are live values rather than constants — code elsewhere sets them
per situation. [measured]

**The order of precedence is fixed**: a speed bonus asks for the blue trail, a ready dodge asks for
the yellow one, and a timed request — hover — asks for blue **last and unconditionally**. So a
hovering character with a charged dodge trails blue, not yellow. Consulting the timed request only
when nothing else is set gets exactly that case wrong. [measured]

**The dodge branch fades its afterimages several times faster than the slide branch does.** One
decay value for both leaves yellow images lingering. [measured]

**Spawning is per FIXED step, not per frame and not per message** — a trail's density is a function
of the game's own clock. [measured]

## Known unknowns

Open questions about **the game**, kept so a later session can strike one through and point at the
section that answered it.

- **Whether `PlayerControl` is a real type in TEVI's assemblies.** The adapter gates on
  `EventManager.Instance.mainCharacter`; an earlier revision of this file named
  `PlayerControl.instance`. The assemblies are not in this repo and the user was unsure. A probe
  settles it: `PROBES.md`'s `DIAG_MENU_GATE`.
- **What the return glow on the orbs is** when a core expansion ends. Named in the game's own code,
  not yet traced.
- **What a summoned humanoid fires**, and whether it uses the same bullet pool as its owner.
- **Which projectile families move themselves** versus being moved by the game each step. The
  distinction decides whether a mirror can carry position at all, and only part of it is mapped.
- **What a bullet does to the WORLD when it ends** — sub-bullets and effects spawned by its wall
  action are new births in their own right, and the set of them is not enumerated.
