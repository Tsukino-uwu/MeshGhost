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

**UNCONFIRMED, flagged 2026-08-27: which member this is read through.** This passage named
`PlayerControl.instance`, and `PlayerControl` appears nowhere in the adapter — it gates on
`EventManager.Instance.mainCharacter` (`Plugin.cs`). TEVI's assemblies are not in this repo, so
`PlayerControl` may well be a real game type that simply is not what we read; the user, asked, was
unsure and noted only that the behaviour works as intended today. **Nothing was changed on that
basis** — this is the exact file whose pause-menu reasoning produced the 2026-08-18 false
regression, and reasoning from code about what a game means is what caused it. A probe settles it:
`PROBES.md`'s `DIAG_MENU_GATE` section.

That single difference is what lets a `player == null` check tell "the player left the session"
apart from "the player opened a menu" — without it, a pause would be indistinguishable from
quitting. It is the reason peer ghosts can stay on screen while you are in the pause overlay, which
is the intended, wanted behaviour (user, 2026-08-18), and disappear when you actually quit to the
title.

**Be precise about which menu when describing this.** Bare "menu" is ambiguous in a game with both,
and on 2026-08-18 that ambiguity alone produced a false regression report about working code.
