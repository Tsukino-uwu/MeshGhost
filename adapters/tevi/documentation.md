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

Dated evidence: [`agent_docs/verified.md`](../../agent_docs/verified.md) ·
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
current build. Which of the two exists is a version-dependent fact, so the adapter resolves it by
reflection instead of binding to one shape at compile time.

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

## Animation: Spine, addressed by name

TEVI animates with **Spine**, and the currently-playing animation is obtainable as a **name string**
via the sprite-animation component (`spranim_prefer.GetAnimationTrueName()`).

That name is what makes a cosmetic clone tractable: a peer's animation can be carried as an opaque
string and replayed on a clone, with no need to model the state machine that chose it. The core
never interprets it — animation tags are opaque outside the adapter that produced them.

## Facing is a sprite flip, not a rotation

The character faces left or right by **flipping the sprite**, not by rotating a transform. The
component that must be flipped is the sprite-animation logic component, not only the base sprite —
flipping one and not the other produces a visibly half-mirrored character.

## The map screen is its own system

The full map screen is a separate component (`FullMap`) with its own representation of where the
player is — a private `playerPos`, a `maxroom` bound, and per-room tiles (`FullMapTile`) that carry
their own transforms. Marking a position on the map screen means placing something at a *tile's*
transform, in the map screen's own space, rather than converting world coordinates.

**This is a genuinely separate coordinate system from the world one**, and the two do not convert
into each other.

## Saves and progression

`SaveManager` owns save state. **MeshGhost never writes it** — `CLAUDE.md`'s absolute rule — and it
is named here only because it is the component a reader will otherwise go looking for.
