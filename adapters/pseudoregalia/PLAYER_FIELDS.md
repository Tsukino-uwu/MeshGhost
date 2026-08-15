# Pseudoregalia player fields — currently synced, and the wider schema map

Reference doc, not narrative — see [agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md)
for the build story and [agent_docs/verified.md](../../agent_docs/verified.md) for the dated,
evidence-cited entries this file summarizes. Two purposes: (1) a single place that says what
MeshGhost actually reads/writes on `BP_PlayerGoatMain_C` today, which didn't exist as a standalone
list before this file, and (2) a map from every ability the game exposes (per its own
trending-pages listing) to the internal field names behind it — useful for extending this adapter,
and plausibly for anyone else working on a Pseudoregalia UE4SS mod, since none of this is
Pseudoregalia-modding-community-published anywhere obvious.

**Everything here is Pseudoregalia's own reflected class data**, read via UE4SS's native
`TFieldRange<FProperty>`/`GetValuePtrByPropertyNameInChain` against the user's own local install —
not copied from any other project. See [agent_docs/licensing.md](../../agent_docs/licensing.md).

## Currently synced (production, confirmed live)

Read from the local pawn (`BP_PlayerGoatMain_C`) every tick in `Plugin::game_thread_tick`, sent
as `extras` fields per [PROTOCOL.md](../_template/PROTOCOL.md), and mirrored onto the ghost's own
pawn instance/AnimBP every redraw tick:

| Field | Lives on | Notes |
|---|---|---|
| `moveState` | pawn | uint8 enum driving the AnimBP's core movement state |
| `actionState` | pawn | uint8 enum, secondary action state |
| `horizontalSpeed` / `verticalSpeed` | pawn | doubles, feed blend spaces |
| `animJumpType` | pawn | uint8 |
| `MovementMode` | pawn → `CharacterMovement` | uint8, stock engine `CharacterMovementComponent` field. Needed to fix the ghost getting stuck in a falling pose (see `verified.md`) |
| `landed?` / `jumped?` | pawn → `animBPref` | bool, **not** on the pawn itself. One-shot pulses, not continuous state — mirrored as a monotonic counter + hold window (`PULSE_HOLD_TICKS`) since a single-tick flag doesn't survive the ~20Hz send-rate/network round trip. Writing `jumped?`/`landed?` alone didn't fix the ledge-hang-stuck-forever bug — that needed an explicit `Montage_Stop` call on the ghost's AnimBP instance too. |
| `weaponEquipped?` / `animEquippedWeapon` | pawn / pawn → `animBPref` | bool, mirrored continuously (`RemoteGhost::target_weapon_equipped`). **FIXED and confirmed live, 2026-08-15** — see the Dream Breaker section below. The property write alone never drove the visual; the real fix was calling `changeEquippedWeapon`/`updateWeaponEquip` *before* the raw property overwrite, not after, so those functions see the value actually change. This row is now "done" the same as the others above. |
| `SkeletalMesh` / `SkinnedAsset` (on `VisualMesh`) | pawn → `VisualMesh` | object reference to a `USkeletalMesh` asset, one per outfit. **FIXED and confirmed live, 2026-08-15** — see the Outfit section below. Sent as the asset's real object path (`RemoteGhost::target_outfit_mesh`); ghost resolves it via `StaticFindObject` and calls `SetSkeletalMeshAsset` (found via a live function-name dump) before the direct property write. |

`position`/`orientation` (top-level packet fields, not `extras`) come from `K2_GetActorLocation`/
`K2_GetActorRotation`; `area_id` from `PersistentLevel`'s `GetFullName()`.

**Not synced today, known gap**: ability VFX (cling-gem effect, sword/empty-hand glow) —
`agent_docs/status.md`. This is now the only remaining Pseudoregalia visual gap. This file's second
half is the field-discovery work originally aimed at both this and the (now-fixed) outfit/weapon
gaps.

## Ability → internal field map (schema only, not yet synced or behavior-confirmed)

Found via a real reflection dump (`Plugin.cpp`'s `dump_object_reflection`, gated behind
`OBJECT_REFLECTION_DUMP`) against a live play session, 2026-08-15 — full citation and caveats in
`verified.md`'s "Pseudoregalia ability field schema" entry. **This section documents field
existence and spelling only.** No value has been watched changing, no field has been wired into
the sync path, and several entries below only reached their current mapping after correcting an
initial name-based guess against actual gameplay knowledge — a plausible-sounding name was wrong
more than once (see `verified.md` for the specific corrections). Treat every row as "confirmed to
exist," not "confirmed to do what the name suggests."

| Ability (in-game name) | Internal fields |
|---|---|
| Dream Breaker (the weapon itself) | `weaponEquipped?`, `animEquippedWeapon` (on `animBPref`), `weaponRef`, `WeaponMesh`, `spawnWeapon`/`recallWeapon`/`changeEquippedWeapon` (functions) |
| Strikebreak + Soul Cutter (one shared charge-attack mechanic — sequential upgrades to the base weapon, not parallel branches) | `obtainedChargeAttack?`, `chargeAttackHoldTime`, `chargingVFX`, `obtainedProjectile?`, `projectileFullDamage` |
| Power meter (feeds Soul Cutter's damage boost) | `currentPower`, `maxPower`, `baseMaxPower`, `powerAccum`, `powerLevel`, `powerDamageMultiplier`, `changePowerAmount`, `powerBuildUpgrades`, `powerMeterUpgrades`, `obtainedPowerBoost?` |
| Sunsetter (Plunge) | `obtainedPlunge?`, `doGroundPound`, `doGroundPoundHighJump`, `hasGroundPound`, `altAirBackflip`, `canFlipJump?` (the last two are the plunge-cancel-into-backflip tech, not an unrelated move) |
| Slide | `obtainedSlide?`, `canSlide` |
| Slide Jump | `obtainedSlideJump` |
| Solar Wind (passive Slide Jump upgrade — no unlock flag of its own) | `bunnyhopJumpCap`; plausibly also tunes `slideDuration`/`SlideCurve`, unconfirmed |
| Cling Gem (internal name differs from both the community name and an obvious guess — no "glide" string exists anywhere in the dump) | `wallRide*`/`wallRun*` cluster: `obtainedWallRide?`, `wallRideButtonHeld?`, `wallRideVFX`, `wallRideSFX` |
| Sun Greaves | `wallKick*`/`airKick*` cluster: `wallKickActive`, `tryWeaponKick?`, `obtainedAirKick?`, `currentAirKicks`, and one literally named `'wall event kick thing'` |
| Ascendant Light | `obtainedLight?` |
| Costumes (not on the trending-pages list; found because a real player-visual feature, same category as the outfit-swap this doc exists partly to support) | `outfitDataTable`, `changeActiveOutfit`, `tryAddOutfitToUnlockedList`. **Turned out to be a genuinely separate gap from Dream Breaker visibility, not the same one** — both looked identical at first (spawn-time snapshot, no live update), but the weapon bug's real cause (a call-order bug specific to `changeEquippedWeapon`/`updateWeaponEquip`) doesn't generalize: a live costume change still didn't propagate to the ghost even after that fix shipped (screenshot-confirmed, 2026-08-15). No sync code exists for outfit at all — this is unstarted work, not a known-cause bug waiting on the same fix. |

## Turning a mapped field into a real synced feature

Per `CLAUDE.md`'s evidence standard, none of the above is implementation-ready as-is. Each
candidate field needs its own answer to which of three buckets it falls into, and that answer has
to come from watching it live, not from the field's type:

1. **Might already animate for free.** The ghost already mirrors `moveState`/`actionState`
   continuously and shares the same AnimBP class as the real player. If an ability's whole
   animation is just another value one of those two enums can take, the ghost may already play it
   correctly with zero new code.
2. **Needs the `landed?`/`jumped?` pulse treatment.** A one-shot trigger (a bool that's true for
   one frame) gets lost between the adapter's own send cadence and the network round trip unless
   it's turned into a monotonic counter with a hold window on write, exactly like `landed?`/
   `jumped?` needed. A "weapon thrown" or "charge attack fired" moment is a likely candidate.
3. **Needs real new sync code.** Object-reference fields (`weaponRef`, `WeaponMesh`,
   `outfitDataTable`) represent *which visual asset to show* — syncing these means reading an
   index/reference, sending it, and calling something on the ghost side to apply it, the same
   shape of work the `Montage_Stop` fix already required for a different problem. VFX fields
   (`chargingVFX`, `wallRideVFX`) are the least automatic of all: a particle effect is normally
   triggered by *calling a function* (spawn/activate), not by a value changing, so this needs
   finding and calling the real trigger function, not just copying a property.

The next concrete step (not yet done): a live-*value* trace for the highest-priority subset —
mirroring how `moveState` is already traced — to sort real fields into these three buckets with
evidence instead of a guess.

## Dream Breaker (weapon) visibility: FIXED, 2026-08-15 — worked example of why this was genuinely hard

Full history in `verified.md`'s five "Dream Breaker weapon-visibility" entries — summarized here as
a worked example for whoever picks up the next field (cling-gem VFX, empty-hand glow, or outfit
sync are all still open). Bucket 3 above ("needs real new sync code") turned out to undersell it:

1. Mirroring `weaponEquipped?`/`animEquippedWeapon` continuously (bucket 1 shape) shipped as real
   code, and the ghost's sword *did* show/hide correctly on spawn — but never updated again after
   a real throw.
2. Independent readback proved the data pipeline itself was correct on every sample. Two
   game-specific function calls (`updateWeaponEquip`, `changeEquippedWeapon`), both confirmed
   firing correctly via a live signature dump before calling, both had zero visible effect.
3. Direct isolation of `WeaponMesh`'s own stock-engine visibility/attachment properties
   (`bHiddenInGame`, `bVisible`, `RelativeLocation`, `AttachSocketName`) — four consecutive
   negative results, none of them ever changes.
4. **The likely real explanation only surfaced from the user's own memory, not from any reflection
   dump**: the ghost has apparently matched weapon/outfit state since spawning was first built,
   because it's a clone of the same class reading the same local save data at construction — which
   would mean every "it looks right" loopback result in this whole chase was never proof any of the
   sync code above actually did anything.
5. **CONFIRMED, not just theorized (2026-08-15)**: an inversion test — deliberately syncing the
   ghost the *opposite* of the real player's `weaponEquipped?` — showed zero visible effect across
   a real multi-throw/pickup session, with an independent readback proving the inverted value
   genuinely wrote and stuck on the ghost's own properties the whole time. The property is real,
   the write works, and it drives nothing. See `verified.md`'s "inversion test run" entry.
6. **Root cause found and FIXED, same day.** A genuine 0%-completion vs. 100%-completion save
   comparison (a new reusable technique — dump every reflected property's real value at ghost
   spawn on two maximally-different saves, diff the results; see the general-purpose
   `dump_object_property_values` and `adapters/pseudoregalia/README.md`'s build-log step 20)
   found the *one* field that actually differs on `animBPref` between an armed and unarmed spawn
   (`animEquippedWeapon`, out of 230 properties) and separately proved `WeaponMesh`'s own full
   250-property surface never differs at all, clearing the component entirely — narrower and more
   decisive than the four hand-picked properties checked in step 3. That pointed straight at the
   real bug: the ghost-write code set the raw `weaponEquipped?`/`animEquippedWeapon` properties
   *before* calling `changeEquippedWeapon`/`updateWeaponEquip`, every tick — so by the time those
   functions ran on a real transition, the property already held the new value, and any ordinary
   "only transition if the value changed" check inside them saw no change. Reordering the calls to
   run first (property write kept after, as a safety net) fixed it — confirmed on screen, sword
   disappears on a real throw. No new function or property was needed; the two functions tried in
   step 2 were the right ones all along.

Lesson for the next field: a same-machine loopback test cannot distinguish "our sync works" from
"the ghost's own spawn-time construction happens to produce the same visual anyway" for anything
that's also driven by local save/progression data (weapon ownership, outfit, unlocked abilities).
For fields with this confound, an inversion test tells you whether your sync is the lever at all;
if it isn't, the 0%/100%-save value-diff technique above can then find the *actual* differing
field directly, rather than guessing property names one at a time. Fields with no
persistent-ownership angle (moveState, landed?, wall-ride) don't have the confound problem in the
first place. **Caution, learned from outfit**: two fields sharing the same symptom (spawn
snapshot, no live update) does not mean they share the same root cause — outfit still doesn't
propagate live even after the weapon fix shipped, so it needs its own investigation from scratch,
not an assumption that the same reorder will fix it too.

## Slide/ultra-hop trail (afterimage) VFX: investigated 2026-08-15, not yet built

User-confirmed live: the ghost currently has **zero VFX/particles for anything**, not just the
cling-gem/glow gap — a systemic gap, not case-by-case. Two negative results and one real lead
this session (all via `OBJECT_REFLECTION_DUMP`/`ABILITY_FIELD_TRACE`, see their own comments):

1. **Ruled out**: `spawnTrackingParticles?` (bool, on the pawn). Looked like a promising bucket-1
   candidate by name, but a live edge-triggered trace showed it goes `false→true` once at pawn
   spawn and never changes again — a static flag, not tied to sliding/hopping at all.
2. **Ruled out**: the `AnimGraphNode_Trail`/`_1`-`_6` cluster found on `animBPref`. Recursing into
   the struct's own fields (`TrailBone`, `ChainLength`, `ChainBoneAxis`, `bLimitStretch`, ...)
   showed this is the stock Unreal `FAnimNode_Trail` bone-physics dangle node (tails/ears/cloth
   secondary motion) — a red herring from name-matching "Trail," unrelated to the particle effect.
3. **CONFIRMED LIVE, 2026-08-15, same session**: two real functions on the pawn, `Spawn After
   Image(Duration: float)` and `spawnNumAfterimages` (the latter is a Blueprint event-graph
   wrapper exposing only internal compiler temporaries — no real caller-facing parameter).
   Prototyped calling `Spawn After Image` on the ghost (`call_spawn_after_image`, gated behind
   `AFTERIMAGE_CALL_TEST`, fixed ~3s test cadence, decoupled from any real trigger) — user watched
   the afterimage/trail effect actually appear on the ghost. See `verified.md`'s "Pseudoregalia
   ghost trail (afterimage) VFX" entry. **Not yet production code**: still needs a real
   edge-detected trigger (see point 4 below) in place of the fixed test cadence, and
   `AFTERIMAGE_CALL_TEST` flipped back to `false` once that's wired up.
4. **TRIGGER — three wrong answers before the right one. Read this before touching it again.**
   The trail trigger is **NOT** `actionState`-based, despite that being the obvious candidate and
   the one three separate attempts used. All were disproven live:
   - `actionState == 18` — also fires on a quick 180° turn-around skid (false positives).
   - `actionState == 18 && animJumpType == 13` — that pair belongs to the skid and to the slide that
     *precedes a backflip*; it fired **zero** times across a whole session of real plain slides.
   - `afterImagesToSpawn` increases alone — the game never sets it during a plain slide at all
     (zero across 12k ticks), so this covered almost nothing.
   - **The correct signal, measured**: a plain slide is `actionState == 1` with the **capsule shrunk
     from 65 to 22**, running a consistent 87 ticks. The shipped trigger keys on that capsule shrink
     (plus `afterImagesToSpawn` increases as a second, authoritative-but-rare path). Keying on the
     capsule is deliberate: the shrink is a *physical fact* of the move, whereas the state enums
     demonstrably overlap between moves.

5. **Color — DONE, synced and confirmed live.** `afterimageColor` (an `FLinearColor` on the pawn) is
   read live each tick, sent through `extras`, and written to the ghost immediately before each
   burst. Found by strings-scanning the third-party `attire-ui-overhaul` mod's `.uasset` binaries
   (facts-only per its "no license" posture, `licensing.md`) — its dash-color picker casts the
   player to `BP_PlayerGoatMain_C` and writes this field — but it is a **first-party base-game
   property**, so syncing it needs no dependency on that mod. Layout resolved by reflection, not
   assumed (the vendored SDK only forward-declares `FLinearColor`); alpha deliberately never
   written. Write path proven with a deliberate magenta override.
   - **It does NOT carry the ultra hop's blue**: an every-tick trace showed `afterimageColor` never
     changes during a real ultra. That variant comes from some other mechanism and is parked — see
     `verified.md`, and do not resume by guessing more property names.

6. **Ghost sinking into the floor during slides — FIXED, and the first fix was wrong in an
   instructive way.** The slide drops the player's capsule origin 567.2 → 524.2 as it shrinks
   65 → 22 (feet stay planted), so a still-65-tall ghost teleported to that origin sits exactly 43
   units under the floor. Mirroring the ghost's `CapsuleHalfHeight` **provably applied** (readback
   showed 22) and changed nothing visually — because the skeletal mesh hangs off the capsule at a
   *fixed* offset set at construction, and it is the player's own crouch logic, which an
   unpossessed ghost never runs, that adjusts it. The working fix compensates the ghost's **render
   Z** instead: `ghost_z = peer_z + (65 - peer_half)`.
