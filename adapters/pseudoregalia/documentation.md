# How Pseudoregalia works

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

> Everything here is **measured from a running game** during Phases 2, 5 and 7 and the work that
> followed them (2026-08-11 through 2026-08-27), using engine reflection against a running instance
> to learn real type and member *names*. This game has **no public source**, and no decompiled or
> disassembled material was used in producing it. **No asset content or verbatim dump is reproduced
> here** — only facts, per `agent_docs/licensing.md` (assessed 2026-08-17, re-checked 2026-08-27).

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
| `VERIFIED.md` | Dated evidence behind every claim here |
| `UNVERIFIED.md` | What is believed to work but nobody has watched yet |
| `FLAGS.md` | Which compile-time switch turns each of these on |

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

Four `uint8` enums carry nearly everything — three on the pawn, one on her movement component.
These are the values we have actually seen; each enum certainly has more.

| Field | Confirmed values |
| --- | --- |
| `moveState` | `0` grounded/default · `1` airborne · `2` **crouch** · `3` pole hang · `4` **wall ride** · `7` bubble |
| `actionState` | `0` none · `1` **slide** · `17`, `18` other moves — `18` also fires on a turn-around skid |
| `MovementMode` (on `CharacterMovement`, not the pawn) | `5` **flying**, used by poles and bubbles · `1` walking, `3` falling *(inferred)* |
| `animJumpType` | `13 → 11 → 0` over a backflip · `2` bubble boost · `6` drop-down · `0` neutral |

Alongside them: `CapsuleHalfHeight`, `horizontalSpeed`/`verticalSpeed`, `afterImagesToSpawn`,
`afterimageColor`, and the uptime timers (`actionStateUptime`, `moveStateUptime`, and their
`previousMoveState`/`previousActionState` counterparts) measuring how long the current state has been held.

Full field inventory and sync status: `PLAYER_FIELDS.md`.

---

## Slide

> **Fields** `actionState 1` · `moveState 0` · `bIsCrouched true` · `BaseEyeHeight 64 → 32`
> **Components** `CapsuleComponent` (halved) · `VisualMesh` (offset shortened)
> **We read it at** `Plugin.cpp`, where the local-state builder emits `slide_t`

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

**Duration is fixed at 87 ticks**, consistent across four timed runs, and separately **~600ms**,
consistent across 26 timed repeats (mean 624ms — see the held-slide section below). Those are the
same fact measured two ways and they agree: this build's frame rate is not fixed, ranging roughly
**150-180Hz**, at which 87 ticks spans 483-580ms. **Count the slide in ticks, not milliseconds** —
the tick count is what holds still.

A Blueprint `Timeline` float track runs `1.0 → ~0.17` through a slide and is completely untouched
by a crouch, so it is slide-specific — most likely the speed curve. Unidentified beyond that.

**The shrink is the invariant, the enums are not.** `CapsuleHalfHeight` dropping below ~50 is a
physical fact of the move that nothing else in the game produces except a crouch, whereas the state
enums demonstrably overlap between moves (see Crouch, and the trail's four rebuilt triggers in
`VERIFIED.md`). Anything that needs to know a slide is happening should ask the capsule and
disambiguate on `moveState`, not the other way round.

**It is not Unreal's crouch.** `bCanEverCrouch` reads **false** on the movement component, which
disables the engine feature outright — `bWantsToCrouch` is ignored, no resize happens, no
`OnStartCrouch` fires. Every value above is the game's own code doing it by hand, and the `+1` in
the mesh law is the fingerprint: engine crouch would seat the mesh exactly at the capsule bottom.
*Confidence: high for the class, and the citation is worth stating precisely — the reading was taken
on a second instance of the same pawn class rather than on the one the player is driving. It is a
class default, so it holds for both, but no direct reading on the player's own instance exists.*

### Sliding: a held slide is a chain of repeats, not one long one

A held slide is **not one continuous crouch**. The slide is a fixed-duration action of roughly
**600ms** that re-triggers for as long as the input is held, and the character's capsule genuinely
returns to its standing half-height (65.0) in the seam between two repeats before dropping back to
the sliding value (22.0).

Measured 2026-08-17 across 53 capsule transitions in one session. The two populations are sharply
separated, with nothing at all in between:

| | Observed |
|---|---|
| Slide (capsule 22.0) | ~600ms, tightly clustered (mean 624ms over 26 samples) |
| Seam between repeats (capsule 65.0) | 14, 20, 36, 70, 70, 153ms |
| A real stand-up (capsule 65.0) | 244ms and longer |

The seams are invisible to the player because their mesh is animation-blended through them — the
capsule is a physics shape, not what is drawn. That distinction matters for anything that mirrors a
character's pose rather than its animation: the capsule tells you what the game *is doing*, not
what the player *sees*.

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
is measured rather than inferred: the offset is restored within about one tick whenever it disagrees
with a standing character, and left alone whenever it agrees with a crouched one. The offset is a
value the game keeps, not one it leaves lying around.

Three pieces, and they are only separable in principle:

- **`bIsCrouched` is the state the maintenance reads.** Set it and the mesh follows to the crouched
  offset; clear it and the mesh returns. Everything else downstream — capsule size, `BaseEyeHeight`
  — moves with it.
- **The crouch input is the normal entry point.** `InpActEvt_IA_Crouch_K2Node_EnhancedInputActionEvent_15`
  and `_16` are the Blueprint's own Enhanced Input handlers for the crouch button — two of them
  because an input action fires separate press and release events — and they are what start and end
  the pose in ordinary play.
- **`Timeline_1` is the slide's motion, not the pose.** Its track carries an eased curve applied by
  `Timeline_1__UpdateFunc`, the Blueprint's own per-frame handler. A stationary crouch never moves
  it — which is exactly how we know the timeline belongs to the slide and not to the shape.

**None of this goes through Unreal's built-in crouch.** `bCanEverCrouch` is false, so `Crouch()`,
`OnStartCrouch` and the engine's own capsule resize never run — the game reimplements all of it.
The consequence is that the engine's own crouch levers (`CapsuleHalfHeight`, `bWantsToCrouch`,
`BaseTranslationOffset`) are outputs or dead inputs here rather than controls: `bIsCrouched` plus
the timeline above is the live state. *Confidence: high for `bCanEverCrouch` and the reimplementation;
the levers were each measured inert on a pawn nobody was possessing, which is where the maintenance
loop above does not run either — so "inert" is established for that case and inferred for the other.*

*How MeshGhost reproduces this on a ghost is deliberately not described here — see `BANDAGES.md`
and `VERIFIED.md`. This file is what the game does.*

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

**Where the blue comes from: answered.** It is *not* `afterimageColor`, which was edge-traced
through a real ultra and never changed from yellow — because the colour does not live on the pawn
at all. **Each afterimage is a posed copy of the character carrying its own `Color`**, and the
ultra path colours those actors individually, bypassing the pawn field entirely. Normal images
measure `(1.000, 0.888, 0.260)`, ultra images `(0.000, 0.787, 1.000)`.

## The afterimage trail

> **Fields** `afterImagesToSpawn` (int) · `afterimageColor` (`FLinearColor`)
> **Function** `spawnNumAfterimages` — `Plugin.cpp`, `call_spawn_num_afterimages`

`spawnNumAfterimages` performs a burst, spawning `BP_AfterImage_C` actors — the trail is **not** a
particle system: the build's VFX catalog holds 58 Niagara systems and none of them is an afterimage.
Each actor carries a `PoseableMeshComponent` (a frozen snapshot of the character's pose), its own
`Color`, and `copyActor`, a reference back to whoever it was copied from.

**`afterImagesToSpawn` is counted *down* by the game's own timer loop as it spawns** — but it is
**not** a reliable census of the trail, and that is the single most expensive thing to learn about
this mechanic. Some afterimages come from a path that never touches the field at all: it stayed at
zero across 12k ticks of ordinary sliding, and the ultra hop is one of the paths that bypasses it.
*Confidence: high, and negative — measured across a whole session of real slides.*

**The actors are pooled, not destroyed.** A spent afterimage is reclaimed and moved about one fade
lifetime later, and the identical actor pointer comes back: measured 60-72 ticks apart, eight times
across eight ultras. **None ever disappears**, so counting live `BP_AfterImage_C` actors counts the
pool, not the trail — a fresh one is told apart by being born where the character currently is.
*Confidence: high — pointer identity across eight runs.*

`afterimageColor` is the base, customisable trail colour — measured yellow at
`(1.000, 0.888, 0.260)`. It is the same field the third-party attire-ui-overhaul dash-colour picker
writes, so a player with that mod has already changed it. Ultra-hop images measure
`(0.000, 0.787, 1.000)`, but not because this field changed.

## Wall ride (Cling Gem)

> **Fields** `moveState 4` · `wallRideButtonHeld?` · `wallRideVFX` · `wallRideSFX`
> **Function** `doWallRun`, plus `wallRunTick`/`doWallRunJump` — `Plugin.cpp`, `call_do_wall_run`

`moveState == 4` is the marker. Note the naming: internally this is **wall ride/run**, matching
neither the item's name ("Cling Gem") nor the community's usual term — worth knowing before
searching for "cling" or "glide" and finding nothing.

## Bubble

> **Fields** `moveState 7` with `MovementMode 5`, `actionState 0`, `animJumpType 0`, capsule 65
> **Functions** `StartBubbleJumpFlash(Condition)` · `changeBubbleChargedJump(hasBubbleChargedJump)` — `Plugin.cpp`, the bubble-jump flash helpers

The boost out of it is `animJumpType == 2`, which also moves `moveState` to 4. The visual is the
model itself pulsating, not a trail — and the two functions above are named for exactly that
effect and exactly that state, so no inference was needed to find them.

## Pole hang

> **Fields** `moveState 3` with `MovementMode 5`

Leaving a pole moves to `moveState 1` / `MovementMode 3`. A brief
`moveState 1, actionState 0, animJumpType 6` window of ~0.4s is a drop-down.

---

## Health, and the HUD that shows it

> **Fields** `CurrentHp` on the **GameInstance**, not on the pawn · `UI_HudRef` on the pawn
> **We read it at** `Plugin.cpp`, the shared-health reader behind the death and hurt counters

**No current health lives on the character.** A full reflection dump of the pawn returns only
*config* — `healAmountPerDing`, `HPpiecesNeededForHeart`, `hitsToFill`, `healUpgrades`,
`healMoveSpeed` — and the damage constants `lightAttackDamage` (15), `heavyAttackDamage` (50) and
`projectileFullDamage` (45). None of them is state.

The live value is `CurrentHp`, a double on the object the pawn holds as `As MV Game Instance Ref`.
**A UE GameInstance is one object for the whole running game**, so there is exactly one health value
in existence no matter how many characters are on screen.

| | Value |
| --- | --- |
| Full | **80** |
| A pit fall | costs exactly **5** — damage, not death |
| Heal to full | writes 80 in one step |
| Death / respawn | 0, then 80 |

*Confidence: high — measured across one user-driven run covering damage, healing, death and
respawn, and cross-checked against a control run. Found 2026-08-27.*

**Loading a save does not rewrite `CurrentHp` — the value carries across save swaps.** Within one
app session, switching save files (main menu → another save, a fresh one included) leaves the
health at whatever the previous save last had, because the GameInstance outlives the swap and
nothing in the load path resets the field. *Confidence: high — observed on screen 2026-08-27, and
measured as the game's own behaviour by a control run with no ghost and no MeshGhost connection
active; first noticed because a MeshGhost mirror briefly reacted to the carried-over value, which
is how anyone would meet it.* A pit fall, death or heal after the swap moves it normally.

**The HUD is built per pawn, and stores no health of its own.** The character's own `BeginPlay`
constructs its health bar, adds it to the viewport, and keeps it as `UI_HudRef`. Across a whole run
the only property that changes on that widget is `AnimationTickManager`, so it reads `CurrentHp`
live every frame rather than caching it. Two consequences worth knowing before debugging anything
health-shaped here:

- **A second character of this class puts a second health bar on the screen**, initialised full, on
  top of the first. A bar showing the wrong number therefore means the widget being *looked at* is
  not the widget being *updated* — the value itself is fine.
- **A widget's lifetime belongs to its parent, not to whoever holds a reference.** Clearing
  `UI_HudRef` leaves the bar on screen with nobody pointing at it.

*Confidence: high — user-confirmed on screen 2026-08-27.*

## Taking damage, hits, and death

> **Functions** `BPI_PerformDamageResponse(DamageType, attackDirection)` · `dieFade(DieNotRez)`
> **Fields** `hitActorsArray` on the attacking pawn · `LastHitBy`
> **We read it at** `Plugin.cpp`, the hurt and death mirrors

**This game does not use Unreal's damage path at all.** `ApplyDamage` and its two siblings were
hooked and **armed on 3 of 3, and never fired once** across attacks that demonstrably did damage;
the victim's `LastHitBy` stays `<none>` through being hurt. Damage travels by Blueprint interface
instead. *Confidence: high, and it is a negative worth trusting — three engine entry points, none
of them ever reached.*

**How a hit actually lands**, measured end to end:

1. an attack montage's notifies run the attack code on the attacking pawn;
2. that code queries **outward** for victims — the attacker's own collision is not involved;
3. each victim found is appended to the **attacker's own `hitActorsArray`**;
4. the attacker then calls `BPI_PerformDamageResponse(DamageType, attackDirection)` on the victim,
   carrying a damage **TYPE, not an amount** — the victim decides what it costs;
5. the victim's cost is applied to the single shared `CurrentHp` above.

**`hitActorsArray` is not cleared between swings.** It is the game's own already-hit list, and a
target already in it is not hit again — which is why a given attacker only ever lands its *first*
blow on a given target. *Confidence: high — the array was read every tick through a charged attack
with the victim's own object name visible in it, 2026-08-27.*

`BPI_PerformDamageResponse` **paints the reaction rather than deducting the health**: `CurrentHp`
was read immediately before and after the call across a session and never moved. *Confidence: high,
measured; it is a negative, so it is worth re-measuring on another build.*

**Death is an animated material parameter, not a particle effect.** Through a death the model is
**never hidden** (`hidden=false visible=true` throughout) while three of its material slots become
`MaterialInstanceDynamic`. The function that runs it is `dieFade`, whose single `DieNotRez` bool
distinguishes dying from resurrecting. *Confidence: high — two probes, one showing the mesh is never
hidden and one naming the function; user-confirmed on screen 2026-08-27.*

Effects around a death, all measured from a pit-fall capture:

| Effect | How the game places it |
| --- | --- |
| `NS_BasicBurst` | world-spawned at the death point — **a generic hit burst that also fires in ordinary combat**, so it is not a death marker |
| `NS_DustLand` | world-spawned at the landing point, and fires on ordinary landings too |
| `NS_RespawnSafe` | attached to the `CapsuleComponent` at zero offset — the aura around the character |

`startBlink` is **not** any of this: its reflected locals are a `RandomFloatInRange` and a timer, and
it is the character's **eyes**. The third time a name in this game has pointed the wrong way, after
`AnimGraphNode_Trail` (stock bone-physics dangle, not the trail) and `NS_Healing`.

## Healing

> **Effects** `NS_Healing` (attached) · `NS_HealWave`, `NS_HealEndwave` (world-spawned)

The body aura attaches to the `CapsuleComponent`. **The two wave effects attach to nothing** — they
are owned by `WorldSettings` with no attach parent, carrying plain world coordinates, which is why
they stay where they were raised instead of following the character. Measured against the
character's own actor origin in the same second:

| Effect | Offset from the character's origin |
| --- | --- |
| `NS_HealWave` | ≈ (−8.5, +49, **+100**) — the top of the model |
| `NS_HealEndwave` | ≈ (0, 0, **+10**) |

For scale, the feet are at −66, so the two are a whole character apart. The horizontal component is
in the performer's facing frame; a single sample cannot recover which way they were pointing.
*Confidence: high for the attachment and the heights, user-confirmed on screen 2026-08-27; the
horizontal offset is one sample.*

## The charged attack and the ranged shot

> **Effect** `NS_ProjectileCharged`, on `VisualMesh` at the **`handslot_R`** socket
> **Actor** `PRJ_PlayerCutter_C` (`/Game/Blueprints/Projectiles/PRJ_PlayerCutter`), carrying
> `NS_PlayerProjectileWeak`

The charge glow hangs off a **bone socket in the character's hand**, which is why it reads as being
on the sword rather than centred on the body.

The shot itself is a separate world actor: **exactly one instance per shot**, its `Owner` is
`<none>` on every one ever logged, and its **`Instigator` is the firing pawn** — the instigator is
the only thing that says who fired it. Flight and wall bounces are resolved by the actor's own
`ProjectileMovementComponent`.

**Two traps, both measured:**

- **Its lifetime belongs to the game** — it is destroyed on impact. Anything holding a pointer to
  one is holding a pointer that will be freed underneath it.
- **The actors are pooled, so existence is not activity.** A spent projectile keeps existing with
  the firing pawn still named as its instigator. A live shot is one whose `ProjectileMovement`
  component is **active** — the same correction the recall glow needed, for the same reason.

*Confidence: high — three watch sessions plus a user-confirmed run, 2026-08-27.*

## The through-walls outline

> **Fields** `bRenderCustomDepth`, `CustomDepthStencilValue`, `bRenderInMainPass` on `VisualMesh`
> and `WeaponMesh` · **Function** the native `PrimitiveComponent:SetRenderCustomDepth`

The blue silhouette the character shows through geometry is stock Unreal **custom depth**, not an
effect: both meshes carry `bRenderCustomDepth=true` with `CustomDepthStencilValue=0` and
`bRenderInMainPass=true`, and a post-process pass draws the outline wherever those pixels sit behind
scene depth.

Two things about it are non-obvious and cost real time to discover:

- **`bRenderCustomDepth` is render-thread state.** Assigning the raw bool from the game thread can
  leave an already-created render state still drawing; `SetRenderCustomDepth` is the setter that
  propagates.
- **Afterimages carry the outline too, and the game turns it on before it says whose they are.**
  Custom depth is enabled on a `BP_AfterImage_C` **before** its `copyActor` is set — measured: the
  first image of a session reached the following tick with `copyActor` still null. Anything that
  needs to know which character an afterimage belongs to at the moment the outline goes on cannot
  learn it from that field.

*Confidence: high — both components read back the same flags, the silhouette is visible through
geometry, and the ordering was measured live 2026-08-27.*

## Animation montages

The character's animation assets are prefixed `dreamLady_`; the pawn class itself is
`BP_PlayerGoatMain_C`. The ground attack combo on this build is
`dreamLady_Attack_GF1`/`GF2`/`GF3`/`GL2_Montage`, and the named ones elsewhere in this document's
territory are `dreamLady_WeaponThrow_Montage` and `dreamLady_LedgeGrab_Montage`. A full dump found
33 montages. The charged projectile throw uses a montage that has **still never been logged by
name** — see Known unknowns.

---

## The black planes between rooms are translucent, and they out-draw anything translucent

The game separates rooms with flat black planes you walk through — no loading, no area change, and
the player crosses them freely. **They are translucent geometry**, which matters to anything this
adapter draws in the world: a translucent surface in front of one can still be drawn *behind* it,
because translucents are sorted per object rather than depth-tested against each other.

Measured 2026-08-29 while building nametags: a translucent plate disappeared behind these planes at
every sort priority tried, up to 32760, while opaque geometry in the same spot was unaffected. The
practical consequence for any future world-space visual — marker, label, outline — is that "must
stay visible" means "must be opaque". Full evidence: `agent_docs/pitfalls/by-host.md`, 2026-08-29.

## Light and darkness: painted into the geometry, not cast by lights

**Fields:** none on the pawn drive it. **Components:** `PlayerLight` (a `ChildActorComponent`
holding a `BP_DynamicVertexLight_C`), `LightMesh` (a `StaticMeshComponent`), `PointLight`.
**Where we read it:** engine reflection against two running instances, 2026-08-29.

**The dark areas are not lit by light components.** A census of `LightComponent` and every subclass
in a dark dungeon map finds exactly two lights in the whole level — one per character — and the
walls are still lit. What actually lights the room is **vertex lighting painted into the level
geometry**: the world holds a `BP_StaticVertexLight_C` per fixture (32 of them in that map, one per
wall sconce) and every character carries a **`BP_DynamicVertexLight_C`** inside its `PlayerLight`
child actor component, which paints brightness onto nearby geometry as the character moves.

The practical consequence is that **the usual way of asking "what is lighting this?" returns
nothing** — no light, no material parameter on the surface, no post-process. The brightness is in
the geometry's own vertex data, put there by an actor whose class name is the only thing that says
so. Anything chasing a lighting question in this game should enumerate actors, not lights.

A second collection sits alongside it: **`MPC_PlayerRelated`**, a material parameter collection
with exactly one parameter, `PlayerLocation`, updated every tick with the player's world position.
Materials that need to know where the player is read it from there — one global slot, written by
the character, which makes it a singleplayer assumption the same way the trigger volumes below are.

**Room lighting is driven by trigger volumes, not by where you are.** `BP_LightTransition_C`
volumes (four in that map) feed a single `BP_LightManager_C`, which holds the level's illuminated
components in a map and transitions them. Walking through a volume is what changes the scene's
lighting state — which is why walking out of a dark area and back in repairs a scene whose lighting
has ended up in the wrong state.

**How the pieces talk to each other — measured 2026-08-30, function census plus live calls on a
running copy:**

- **Every `BP_DynamicVertexLight_C` registers with the light manager when it begins play** —
  the manager exposes `Register`, each light carries a `LightIndex` (the player's own light is
  index 0; the next light to appear takes 1), and registration happens inside actor spawn,
  before the spawner regains control. **Destroying a light does not unregister it**: the
  manager keeps rendering the registered entry — at the player's position — with the intensity
  and radius the light had when it registered. A destroyed-but-registered light is invisible to
  every actor-level read, because the actor's own properties no longer participate.
- **The manager's repair verbs are `FixAllLights`, `FixDynamicLights` and `FixStaticLights`** —
  what a `BP_LightTransition_C` runs when crossed, and callable directly. `FixAllLights` clears a
  stale dynamic registration; `FixDynamicLights` alone does not (both watched live on a scene
  carrying exactly that fault).
- **Each transition volume is a `toDark`/`toLight` overlap pair** with two timelines, an
  `ambienceRef`, and per-volume targets (`2Target`, `2targetWithLight`, `actualDarkTarget`,
  `standardIntensity` 0.6) plus `isDarkZone?`/`isLightOut` state. The ambience actor it drives
  carries the fog and shade knobs (`FogColor`, `FogDensity`, `ShadeColor`, `Intensity`).
- **The player's own vertex light dims by zone**: Intensity reads 0.05 standing in a dark area
  and 0.2 in a lit one, radius 300 either way. The manager's illuminated-components map holds 32
  entries in that level — one per wall-sconce fixture.

**The player does not normally glow.** In ordinary play a character in a dark area is dark. The
three sources of light on or near a character, per a player who knows the game (2026-08-29):

- **The ascendant light upgrade**, which is a save flag (`havelight?`) — once obtained, the
  character carries light with them.
- **A temporary light after throwing the sword and picking it back up**, which also appears when
  collecting light while unarmed. It is temporary and gameplay-driven.
- **The pickup orbs in the world**, which emit light of their own.

## The blade aura is a separate mesh, not a material or an effect

**Components:** `LightMesh` on the pawn. **Material:** `M_SpiritAura_Inst1`, whose parent is
`M_SpiritAura` — a gold colour, roughly `(0.88, 0.81, 0.27)`, at half opacity. **Where we read it:**
component and material census on two running instances, 2026-08-29.

The golden shimmer along the sword when the ascendant light is active is **its own mesh component**,
drawn over the weapon. It is not a material swap on the weapon (`mainWeapon`'s material is
`MI_PlayerWepon` with or without the aura), not an overlay material (that field is empty on every
mesh), not a Niagara or particle effect (the only particle system on a character is
`NE_Particles_System`, and hiding it changes nothing about the aura), and not custom depth — which
is the through-walls outline and a visibly different look.

**This matters because it is the third component in the same family**, and all three answer to the
save rather than to what the character is currently doing: `PlayerLight`'s vertex light, `LightMesh`
for the blade, and the pawn's own `PointLight`. Anything reasoning about "is this character lit"
has to ask all three, and none of them is visible to a search for lights.

## Known unknowns

Recorded so nobody re-runs a search that already came up empty:

- ~~The ultra hop's blue trail source.~~ **Answered** — the colour is per-afterimage, not a pawn
  property. See "The afterimage trail" above.
- ~~What writes the capsule and mesh during a slide.~~ **Answered 2026-08-17** — see "How the pose
  is actually driven" above.
- **What the `Timeline_1` curve's overshoot is for.** The track is now known to drive the slide (it
  is what `Timeline_1__UpdateFunc` applies), and it does not run a clean `1.0 → 0`: it eases, and
  dips slightly *below* zero near the end (`… 0.11 → 0.03 → −0.06 → −0.01`) before settling. An
  overshoot like that usually means a curve with an ease-out or a small bounce, but what the game
  does with the negative portion is unexamined.
- **`slideOverheadCheck`.** The pawn exposes it; that a slide under a low ceiling must keep her
  down is inference, not observation.
- **`BPI_CombatDeath(dissolveDelay)` and `flash(justWeapon?)`.** Both were named by a function
  census on the pawn while looking for the death fade, and neither has ever been called or watched.
  They exist and their signatures are real; what they do is unexamined. `dieFade` is the one that
  was measured, and it is what the death visual actually runs through.
- **The charged projectile throw's montage.** The four ground-combo attack montages are known by
  name (see Animation montages); the charged throw plays a different asset that has never appeared
  in a log. Anything filtering montages by name will silently miss it — which is how it was noticed.
- **What decides `NS_BasicBurst`'s meaning.** It fires at a death *and* roughly a dozen times in
  ordinary combat as a generic hit burst, so the burst alone does not distinguish the two. Whatever
  the game keys the difference on has not been looked for.

## Adding to this file

One section per mechanic, in the game's own vocabulary, with the same three-line header: the
**fields** it sets, the **components** it moves, and **where we read it**. Then say what the game
does and how confident you are, and link the evidence in `VERIFIED.md` instead of pasting it.

If you catch yourself writing "so we…", stop — that sentence belongs in `BANDAGES.md` or the
`README.md`.
