# TEVI probes

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

Every probe here is a **development tool**, not part of what the mod does for a player. They are
the record of how a fact about TEVI was established — read this rather than guessing which flag
answers which question.

**Why this file is `PROBES.md` at the adapter root, and not `probes/README.md` holding scripts.**
The host decides the shape, the same way it does for Pseudoregalia. BepInEx loads compiled plugins;
it has **no equivalent of BizHawk's Lua console**, so there is nothing to attach a standalone
script to and no `probes/` folder for one to live in. A probe for TEVI is therefore a block inside
`MeshGhostTevi/Plugin.cs` behind a `private const bool DIAG_*`, which the compiler removes entirely
when the flag is `false`. `DIAG_REDRAW_TRACE` set that precedent on 2026-08-14; the two below
followed on 2026-08-27.

**That is a host constraint, not a per-adapter exception** — any future BepInEx adapter inherits it,
and `adapters/_template/probes-README.md` says so.

**How to run one.** Flip its flag to `true`, `dev-scripts/build-tevi.bat`, and copy the DLL to the
game's `BepInEx/plugins/MeshGhostTevi/`. Output lands in BepInEx's own console and log. **Flip it
back and rebuild when the question is answered** — a diagnostic left on is a shipping decision, and
one of these iterates a dictionary while the map is open.

**The cost rule these are written to.** A per-frame log line is a per-frame stall on every host this
project has measured, so each one below is either edge-triggered or throttled, and each says which
in its own comment. `adapters/_template/probes.md` is the method; `adapters/emulator/CLAUDE.md` has
the measurement that made it a rule.

---

## The register

| Probe | Flag | What it answers | Cost when on | Run? |
|---|---|---|---|---|
| Redraw trace | `DIAG_REDRAW_TRACE` | Whether a peer ghost's position, `activeInHierarchy` and scene drift *after* creation — written for the 2026-08-14 zone-transition invisibility bug, which is root-caused and fixed. | One line per remote every 2s, **forever** while on. | Yes, 2026-08-14 |
| Marker staleness | `DIAG_MARKER_STALENESS` | How old the position each FullMap peer marker is showing actually is. | One line per marker per second, **only while the map is open**. | **No** |
| Menu gate | `DIAG_MENU_GATE` | What the adapter can see at each play-session transition, and therefore what really distinguishes the pause overlay from the main menu. | One line per transition. | **No** |
| Spawn diff | `DIAG_SPAWN_DIFF` | What a move actually **spawns** — every GameObject that appears or disappears near the player *and* near each peer ghost, by instance id. Written for the charged-attack gap, where the ghost animates and no effect appears. | A scene-wide `FindObjectsOfType<Transform>()` at 20Hz, plus one line per appearance. **Reports its own scan time**; raise `SpawnDiffSampleInterval` if that is bad. | Yes, 2026-08-28 (rebuilt first — see below) |
| Pool watch | `DIAG_POOL_WATCH` | Which POOLED effect the game just spawned, **by prefab name** (`Normal4H Blast`, `CutinStar`), for effects that do not parent to the character — which is most of them. The widening to reach for when Spawn diff comes back empty. | Walks the two `ObjectPooler`s (~375 objects) per sample; measured `avgMs=0.09`. | Yes, 2026-08-28 |

**Three of the five have been run; `DIAG_MARKER_STALENESS` and `DIAG_MENU_GATE` never have.** That
is their honest state and it is written here rather than left to be assumed: a probe that has never
run proves nothing, and neither does its own output once it has
(`../../agent_docs/testing.md`). Both unrun ones are queued in [UNVERIFIED.md](UNVERIFIED.md).

**`DIAG_SPAWN_DIFF` had to be rebuilt before it was usable, and the reason is the point of the cost
column.** Its first version enumerated every `Transform` in the scene and **measured itself at
`avgMs=19.19`, `worstMs=27.13` against a 16.7ms frame**, in a scene holding 36,854 transforms. It
said so, which is the only reason it was not simply believed — a probe too expensive to run does
not report being expensive, it reports NOTHING, and a quiet log reads exactly like "the game spawned
nothing". Rebuilt to walk only the anchors' own subtrees (~50 objects): `avgMs=0.22`.

**Then it returned a clean negative, and that was the finding.** 4,926 scans, the player's subtree
constant, budget at 12/500 so nothing was truncated: the charged attack's effects do not parent to
the character. That is the documented cue to widen the SUBSYSTEM rather than sample harder, and
`DIAG_POOL_WATCH` is that widening — it named both effects on its first run.

## Marker staleness — `DIAG_MARKER_STALENESS`

**The question.** `UpdateRemoteMapMarker` runs only from `UpsertRemoteGhost`, which runs only when a
`render_remote` arrives. So the marker is update-driven, not frame-driven: a peer that stops sending
leaves it frozen wherever it was, and nothing hides or refreshes it. **The defect is known from
reading the code; what is not knowable that way is the AGE of what a person is looking at**, and age
is not recoverable from the screen afterwards.

**What it prints.** Per visible marker, once a second while the map is open: the peer id, whether
the marker is active in the hierarchy, and seconds since a `render_remote` last moved it.

**How to read it.** An age that climbs while the map stays open is the defect happening in front of
you. An age that stays near zero is a peer still sending, which means the run did not exercise the
case at all — stop the peer (close its game, or kill its core) with the map open.

**Why it needs a field.** `RemoteMapMarker.LastUpdateTime` is written unconditionally — one float
assignment on a path already touching the object — and read only under the flag. The alternative,
deriving age from the wire, would measure a different thing: when a packet arrived rather than when
the marker last moved, and the whole defect lives in the gap between those two.

## Menu gate — `DIAG_MENU_GATE`

**The question, and why it is a probe rather than an edit.** `documentation.md` says the
pause-overlay-versus-main-menu distinction is `PlayerControl.instance`. `PlayerControl` appears
**nowhere** in this adapter, which gates on `EventManager.Instance.mainCharacter`. TEVI's assemblies
are not in this repo, so `PlayerControl` may well be a real game type that simply is not what we
read — and asked directly, the user was unsure and said only that the behaviour works as intended
today.

**So nothing was changed.** This is the file whose pause-menu reasoning produced a false regression
report on 2026-08-18, and it was produced by reasoning from code about what a game means. The rule
that came out of that is in the root `CLAUDE.md`: never assume what a game is meant to do, and name
the exact state — "main menu", never bare "menu".

**What it prints.** One line on each edge — leaving play and re-entering it — carrying `player ==
null`, whether the player transform is null, whether `EventManager.Instance` is null, and whether
`FullMap` reports itself open.

**How to read it, and this is the whole test:**

- **Open and close the pause overlay.** Neither line may appear. If one does, the gate is wrong and
  peer ghosts are being despawned mid-session — the failure `Plugin.cs` names as the first thing to
  suspect if a future TEVI build ever nulls the player on pause.
- **Quit to the title, then start play again.** Exactly one LEFT-PLAY line, then exactly one
  ENTER-PLAY line.
- **What it cannot tell you** is whether `PlayerControl` exists or what it does. It can only tell
  you whether the member this adapter actually reads is doing the work the doc credits to another
  one. If the answer is yes, `documentation.md`'s claim needs the user's word, not ours.
