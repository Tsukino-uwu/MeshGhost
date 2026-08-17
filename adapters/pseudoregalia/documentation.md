# How Pseudoregalia works

**What this file is: how *the game* does things.** Slide, crouch, wall ride, the trail — what each
move actually does to the character, which fields carry it, and which components it moves. Written
down so the next person can read "oh, *that's* how a slide works" instead of rediscovering it by
watching pixels.

**Hard rule: nothing here describes a MeshGhost workaround.** No compensations, no "we add 43 to
the render Z", no re-asserting a value something else keeps changing. If a line is only true
because of something *this adapter* does, it belongs in `BANDAGES.md`, not here. This file must
read as a description of the game to someone who has never seen our code.

Pointers to our code are fine and useful — *where we read this* — but keep them one line. No code
listings; the code is one click away and stays the source of truth.

| File | Answers |
| --- | --- |
| **`documentation.md`** (this) | How does the game do X? |
| `PLAYER_FIELDS.md` | Which fields exist, which we sync, how to promote one |
| `BANDAGES.md` | Where we compensate instead of reproducing the mechanism |
| `agent_docs/verified.md` | Dated evidence behind every claim here |

## Standing rule: everything in here must be fine on a public repo, forever

This file is **facts observed from a running copy of a game the reader owns** — nothing else. That
is what keeps it publishable, and it is a rule about content, not a disclaimer at the bottom.

**Allowed**, and the whole point of the file: measured numbers, timings, field and function *names*,
which component moves, how states relate. Facts are not copyrightable, and short identifiers carry
no copyright of their own.

**Never**, regardless of how convenient: game source, decompiled or disassembled output, asset
content or extracted strings, and **verbatim reflection dumps** — a dump is bulk copying of the
game's own data, which a hand-written description of the same mechanism is not. Nothing that
describes obtaining the game or bypassing anything.

**The test is the repo-wide one** (`CLAUDE.md`): not "does a licence permit this?" but *"is this
fine sitting in a public repo forever?"* If the answer is no or unclear, it doesn't go in. If an
entry can only be written by quoting something, it isn't an entry.

**Keep the provenance line.** Every claim below is measured from a running game and says how
confident it is; this game has no public source, and no decompiled or disassembled material was
used anywhere in producing it. That sentence is the difference between notes from observation and
something a reader might assume came from leaked source — assessed 2026-08-17, recorded in
`agent_docs/licensing.md`.

---

## The character's anatomy

Sybil is an Unreal `Character` built from two parts that matter constantly:

- **`CapsuleComponent`** — the pill-shaped volume that does the colliding. Crucially it is
  positioned by its **centre**, so the actor's Z *is* the capsule centre, not her feet.
- **`VisualMesh`** — the skeletal mesh, parented to the capsule and hanging below it by
  `RelativeLocation.Z`. It knows nothing about the floor.

Because of that split, every height change has to be paid twice: once on the capsule, once on the
mesh. And the mesh offset follows an exact law in all 692 samples, in every state —
`RelativeLocation.Z` is always **`−(CapsuleHalfHeight + 1)`**. Standing: capsule half 65, mesh −66.
Shrunk: capsule half 22, mesh −23. The mesh root sits permanently one unit under the capsule's
bottom. *Confidence: high — zero variance anywhere in the sample set.*

**Reading these fields correctly.** `bIsCrouched`, `bPressedJump`, `bClientUpdating`,
`bClientWasFalling`, `bClientResimulateRootMotion(Sources)`, `bSimGravityDisabled` and
`bProxyIsJumpForceApplied` are `uint32 :1` bitfields **sharing one byte** on `ACharacter`. UE4SS's
`GetValuePtrByPropertyNameInChain<bool>` hands back that byte, so all seven read `true` when any
one bit is set, and writing through it stamps the byte and clears the other six. Read them as a
group, never individually. *Found 2026-08-17.*

## The state fields

Four `uint8` enums on the pawn carry nearly everything. These are the values we have actually seen;
each enum certainly has more.

| Field | Confirmed values |
| --- | --- |
| `moveState` | `0` grounded/default · `1` airborne · `2` **crouch** · `3` pole hang · `4` **wall ride** · `7` bubble |
| `actionState` | `0` none · `1` **slide** · `17`, `18` other moves — `18` also fires on a turn-around skid |
| `movementMode` | `5` **flying**, used by poles and bubbles · `1` walking, `3` falling *(inferred)* |
| `animJumpType` | `13 → 11 → 0` over a backflip · `2` bubble boost · `6` drop-down · `0` neutral |

Alongside them: `CapsuleHalfHeight`, `horizontalSpeed`/`verticalSpeed`, `afterImagesToSpawn`,
`afterimageColor`, and the uptime timers (`actionStateUptime`, `moveStateUptime`, and their `prev*`
counterparts) measuring how long the current state has been held.

Full field inventory and sync status: `PLAYER_FIELDS.md`.

---

## Slide

> **Fields** `actionState 1` · `moveState 0` · `bIsCrouched true` · `BaseEyeHeight 64 → 32`
> **Components** `CapsuleComponent` (halved) · `VisualMesh` (offset shortened)
> **We read it at** [`Plugin.cpp:6742`](MeshGhostPseudo/Mod/src/Plugin.cpp#L6742)

The game shrinks her and drops her, in a way that leaves her floor contact untouched:

| | Standing | Sliding | Δ |
| --- | --- | --- | --- |
| `CapsuleHalfHeight` | 65 | 22 | −43 |
| actor Z (capsule centre) | 567.2 | 524.2 | −43 |
| capsule bottom | **502.2** | **502.2** | **0** |
| mesh `RelativeLocation.Z` | −66 | −23 | +43 |
| mesh root, world | **501.2** | **501.2** | **0** |

The capsule halves; its centre falls by exactly what it lost, so the bottom stays put; the mesh's
hang-distance shrinks by the same 43, so the mesh stays put too. **She never moves down — she gets
shorter around a fixed point on the floor.**

**Duration is fixed: 87 ticks**, ~0.58s at this build's ~150Hz, consistent across four timed runs.
A Blueprint `Timeline` float track runs `1.0 → ~0.17` through a slide and is completely untouched
by a crouch, so it is slide-specific — most likely the speed curve. Unidentified beyond that.

**Detecting it:** `CapsuleHalfHeight < 50 && moveState != 2`. The shrink is a physical fact of the
move; the enums alone are not safe (see Crouch).

**It is not Unreal's crouch.** `bCanEverCrouch` reads **false** on her movement component, which
disables the engine feature outright — `bWantsToCrouch` is ignored, no resize happens, no
`OnStartCrouch` fires. Every value above is the game's own code doing it by hand, and the `+1` in
the mesh law is the fingerprint: engine crouch would seat the mesh exactly at the capsule bottom.

## Crouch

> **Fields** `moveState 2` · `actionState 0` · `bIsCrouched true` · `BaseEyeHeight 64 → 32`
> **Components** identical to a slide

**Physically identical to a slide** — same capsule 22, same mesh −23, same flags, same eye height.
There is no geometric difference at all. They separate on exactly two fields:

| | Slide | Crouch |
| --- | --- | --- |
| `actionState` | **1** | 0 |
| `moveState` | 0 | **2** |
| duration | 87 ticks | held until released |

So the game has **one shrunk pose**, entered for two reasons: a slide is that pose plus a timer and
forward momentum; a crouch is that pose standing still.

**Consequence:** `bIsCrouched`, `CapsuleHalfHeight` and the mesh offset cannot tell them apart.
`moveState` is the clean discriminator. `actionState == 18` is the tempting wrong answer — a quick
180° turn-around skid fires it too.

## How the pose is actually driven

> **Fields** `bIsCrouched` (the state) · `Timeline_1`'s track (the slide's curve)
> **Functions** the crouch input `InpActEvt_IA_Crouch_…` · `Timeline_1__UpdateFunc`
> **Components** `CapsuleComponent`, `VisualMesh`

**The game does not set the mesh offset once per transition — it *maintains* it, continuously, from
the character's own crouch state.** That is the single most useful fact about this mechanic, and it
is measured rather than inferred: an external write to the mesh is undone within about one tick
while the character is standing, and the same write *sticks* while it is crouched. The offset is a
value the game keeps, not one it leaves lying around.

Three pieces, and they are only separable in principle:

- **`bIsCrouched` is the state the maintenance reads.** Set it and the mesh follows to the crouched
  offset; clear it and the mesh returns. Everything else downstream — capsule size, `BaseEyeHeight`
  — moves with it.
- **The crouch input is the normal entry point.** `InpActEvt_IA_Crouch_K2Node_EnhancedInputActionEvent_16`
  is the Blueprint's own handler for the crouch button, and it is what starts the pose in ordinary
  play.
- **`Timeline_1` is the slide's motion, not the pose.** Its track carries an eased curve applied by
  `Timeline_1__UpdateFunc`, the Blueprint's own per-frame handler. A stationary crouch never moves
  it — which is exactly how we know the timeline belongs to the slide and not to the shape.

**None of this goes through Unreal's built-in crouch.** `bCanEverCrouch` is false, so `Crouch()`,
`OnStartCrouch` and the engine's own capsule resize never run — the game reimplements all of it.
That is why engine-level levers (`CapsuleHalfHeight`, `bWantsToCrouch`, `BaseTranslationOffset`) do
nothing here even when they write successfully: they are outputs or dead inputs, and the state above
is the live one.

*How MeshGhost reproduces this on a ghost is deliberately not described here — see `BANDAGES.md`
and `agent_docs/verified.md`. This file is what the game does.*

## Standing and walking

Geometry never changes: capsule 65, mesh −66, `bIsCrouched` false, whether she is still or running.
Locomotion is animation and velocity, not shape.

## Jumps, backflips and the ultra hop

> **Fields** `animJumpType 13 → 11 → 0` · `ultraCap` · `verticalSpeed`

The **ultra hop** — the perfect-timing jump that trails blue instead of yellow — is very hard to
separate from an ordinary backflip in polled state. Ruled out by measurement, so nobody retries
them:

- `ultraCap` toggles identically on *every* jump (false grounded → true airborne → false landing).
- `fullUltraModifier` (1.25) and `cappedUltraModifier` (1.10) never change — tuning constants.
- `animJumpType` runs the same `13 → 11 → 0` on an ultra as on a normal backflip.
- Launch `verticalSpeed` doesn't separate: normal backflips 1369.0 and 1348.6, ultra 1388.9 — noise.

**Where the blue comes from: unknown, deliberately parked.** It is *not* `afterimageColor`, which
was edge-traced through a real ultra and never changed from yellow. Most plausibly the spawn path
picks a different asset or material, which needs Blueprint-graph inspection rather than property
tracing. Don't resume by guessing property names — that ground is covered and empty.

## The afterimage trail

> **Fields** `afterImagesToSpawn` (int) · `afterimageColor` (`FLinearColor`)
> **Function** `spawnNumAfterimages` — [`Plugin.cpp:3164`](MeshGhostPseudo/Mod/src/Plugin.cpp#L3164)

Unusually direct, as game mechanisms go. `afterImagesToSpawn` is counted **down** by the game's own
timer loop as it spawns, so any *increase* is the game starting a fresh burst and its value is the
true burst size. `spawnNumAfterimages` performs the burst, spawning a Niagara system.

`afterimageColor` is the base, customisable trail colour — measured yellow at
`(1.000, 0.888, 0.260)`. It is the same field the third-party attire-ui-overhaul dash-colour picker
writes, so a player with that mod has already changed it. Ultra-hop images measure
`(0.000, 0.787, 1.000)`, but not because this field changed.

## Wall ride (Cling Gem)

> **Fields** `moveState 4` · `obtainedWallRide?` · `wallRideButtonHeld?` · `wallRideHeld?` · `wallRideVFX` · `wallRideSFX`
> **Function** `doWallRun`, plus `wallRunTick`/`doWallRunJump` — [`Plugin.cpp:3087`](MeshGhostPseudo/Mod/src/Plugin.cpp#L3087)

`moveState == 4` is the marker. Note the naming: internally this is **wall ride/run**, matching
neither the item's name ("Cling Gem") nor the community's usual term — worth knowing before
searching for "cling" or "glide" and finding nothing.

## Bubble

> **Fields** `moveState 7` with `movementMode 5`, `actionState 0`, `animJumpType 0`, capsule 65
> **Functions** `StartBubbleJumpFlash(Condition)` · `changeBubbleChargedJump(hasBubbleChargedJump)` — [`Plugin.cpp:2715`](MeshGhostPseudo/Mod/src/Plugin.cpp#L2715)

The boost out of it is `animJumpType == 2`, which also moves `moveState` to 4. The visual is the
model itself pulsating, not a trail — and the two functions above are named for exactly that
effect and exactly that state, so no inference was needed to find them.

## Pole hang

> **Fields** `moveState 3` with `movementMode 5`

Leaving a pole moves to `moveState 1` / `movementMode 3`. A brief
`moveState 1, actionState 0, animJumpType 6` window of ~0.4s is a drop-down.

---

## Known unknowns

Recorded so nobody re-runs a search that already came up empty:

- **The ultra hop's blue trail source.** Parked; Blueprint-graph work, and UFunction hooks are
  known to crash this build.
- ~~What writes the capsule and mesh during a slide.~~ **Answered 2026-08-17** — see "How the pose
  is actually driven" above.
- **What the `Timeline_1` curve's overshoot is for.** The track is now known to drive the slide (it
  is what `Timeline_1__UpdateFunc` applies), and it does not run a clean `1.0 → 0`: it eases, and
  dips slightly *below* zero near the end (`… 0.11 → 0.03 → −0.06 → −0.01`) before settling. An
  overshoot like that usually means a curve with an ease-out or a small bounce, but what the game
  does with the negative portion is unexamined.
- **`slideOverheadCheck`.** The pawn exposes it; that a slide under a low ceiling must keep her
  down is inference, not observation.

## Adding to this file

One section per mechanic, in the game's own vocabulary, with the same three-line header: the
**fields** it sets, the **components** it moves, and **where we read it**. Then say what the game
does and how confident you are, and link the evidence in `verified.md` instead of pasting it.

If you catch yourself writing "so we…", stop — that sentence belongs in `BANDAGES.md` or the
`README.md`.
