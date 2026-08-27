# Unverified — Pseudoregalia's queue waiting on the user

<!-- line-cap: none -- queue that drains; size is how much the user has not seen yet. Why: agent_docs/claude-md-cap.md. -->

**What this is.** [`VERIFIED.md`](VERIFIED.md) is the append-only record of what is *confirmed*.
This is its waiting room: things the agent believes work, has self-tested as far as it can, and
**the user has not seen yet**. It exists so work can continue while the user is away without
either losing track of what still needs checking or quietly drifting into calling it done.

**The rule it serves** (`../../agent_docs/testing.md`, `../../agent_docs/environment.md`): the agent
verifies the Go client/server with tools; **anything about a running game needs the user to watch
it**. A screenshot the agent took is not a substitute, and neither is a healthy log. *"nothing is
considered done/fixed until i actually confirm it as such."*

**How to use it.**

- The agent adds an item the moment it believes something works, with **what to look at** and
  **what correct looks like** — enough that the user can judge it without re-deriving anything.
- The user works down the list and answers each **confirm** or **decline**. Decline is a normal
  answer, not a failed handover.
- **On confirm:** move it to [`VERIFIED.md`](VERIFIED.md) with the date, and delete it here.
- **On decline:** it goes back to being work. Note what was actually seen — that is usually the
  most valuable line in the whole file.
- Nothing here is cited as established anywhere else while it sits here.

**Created 2026-08-27.** Pseudoregalia had no queue, and three files said that was fine because "an
adapter with nothing pending does not need an empty one" — while `../../agent_docs/status.md` was
carrying Pseudoregalia items nobody had watched. The premise was wrong, not the rule: the user's
call is that **every adapter carries this file**, and `preflight.ps1` now requires it. The entries
below were moved here from `status.md` rather than invented.

**This queue drains.** Confirmed items move to `VERIFIED.md` with the date and are deleted here;
declined ones go back to being work. An entry still here has not been confirmed. Sibling queues:
`../emulator/pokemon/crystal/UNVERIFIED.md`, `../emulator/pokemon/emerald/UNVERIFIED.md`,
`../tevi/UNVERIFIED.md`.

---

## Pending — THE GHOST CAN DAMAGE THE PLAYER with the charge/projectile attack (2026-08-27)

**STATE AT END OF 2026-08-27. Still open. Three candidates tried, none fixed it, and only two of
them actually produced evidence — read the third carefully before repeating it.**

| Tried | Result |
| --- | --- |
| Our `chg` VFX mirror removed (one-variable test) | **REFUTED as the cause** — ghost still hit the player. Row restored. |
| Ghost's damage numbers zeroed (`lightAttackDamage` 15→0, `heavyAttackDamage` 50→0, `projectileFullDamage` 45→0) plus `obtainedProjectile?` already `false` | **REFUTED** — all confirmed applied in the log, ghost still hit the player. So the damage reads none of these. |
| Ghost's hitbox collision disabled (`Hit Component 1`, `CollisionComponent`) | **INCONCLUSIVE, NOT refuted.** The block logged *nothing*: neither property resolved non-null, and the first version of the code only printed on success. Nothing can be concluded from that run. **Logging fixed the same day** so every branch prints; re-run it and the log will actually say which case it is. |

**The strongest untested theory, and it explains the detail nothing else does.** Only the FIRST
charged attack lands; later ones never do. The pawn carries **`hitActorsArray`** — an already-hit
list. A ghost whose copy is never cleared would hit the player once and then treat them as
permanently already-hit, forever. That fits the symptom exactly, and it would mean the bug is a
single hit rather than a repeating one. **Start here next session.**

**Also unexplained and probably the same mechanism:** the ghost's projectile is never VISIBLE. An
actor that damages but does not render is consistent with the ghost spawning something real that
our side never draws.

**The frame that has solved two of these already** (`VERIFIED.md` 2026-08-27, and the camera rig in
2026-08-16): a ghost is a clone of the player's pawn, so **it brings its own copy of everything the
player owns** and each copy is live. Camera rig and HUD were both exactly this. Ask what component
of the player's the ghost also has, rather than what value to overwrite.


**User-reported live. This is the most serious open item in this adapter**, because it is not a
cosmetic defect: a ghost affecting the player's game state is the thing `CLAUDE.md` and
`../../agent_docs/brief.md` forbid outright. Everything else in this queue is a picture being
wrong; this is a peer's ghost interfering with the local player's run.

**Almost certainly the ghost running the game's own logic, not our VFX.** The `chg` mirror spawns a
Niagara system and nothing else — a particle system does not deal damage. The likelier mechanism is
that the ghost, being a real clone of the player's pawn fed the peer's state and montages, reaches
the charge-attack path itself and fires a genuine `PRJ_PlayerCutter_C`, which then hits the player.
That would also explain the user's separate report that the ghost does NOT visibly spawn a
projectile: an actor that exists and damages is not the same as one that renders.

**This is the sharp edge of "let the game do the work"** (`feedback_let_game_engine_do_work`, and
`ideas.md`'s Pseudoregalia item 3). Triggering the pawn's own systems is what made the afterimage
trail, cling gem and slide pose work. The same property means a ghost can reach systems that were
never cosmetic. The rule that resolves it is already written: cosmetics yes, **movement and combat
authority no**.

**What to measure first, and it is one variable.** Turn the `chg` row off in `MIRRORED_EFFECTS` and
see whether the ghost still damages. That separates "our VFX mirror somehow triggers it" from "the
ghost's own logic does it", and those need completely different fixes. Do NOT guess between them —
`../../agent_docs/pitfalls/method.md` on two guesses at one symptom.

**Second measurement, if it is the ghost's own logic:** whether a `PRJ_PlayerCutter_C` is spawned
with the ghost as its owner. `VFX_WATCH` sees these — the capture run logged each projectile's own
actor by name — so a run with it on says outright whether extra projectiles exist.

**Related and probably the same root:** the ghost self-starting montages is already recorded in
this adapter (the ledge-grab self-start, `VERIFIED.md`), where the ghost provably ran its own
animation logic ~0.4s after a readback-confirmed stop. That is the same "the ghost has a mind of
its own" mechanism, already demonstrated once here.

## FOUND, then CORRECTED — health is `CurrentHp` on the GameInstance, and the ghost does NOT corrupt it

**The field, measured.** `CurrentHp` (Double) on the object the pawn holds as
`As MV Game Instance Ref`. Max 80, exactly 5 per pit fall, heal restores to 80, death 0, respawn
80. Found by diffing GameInstance snapshots across a run the user drove deliberately — attack for
heal stock, pit repeatedly, heal to full, pit until death. It is not on the pawn: every
health-shaped pawn property is config (`healAmountPerDing`, `HPpiecesNeededForHeart`, `hitsToFill`).

**The control experiment settled the rest, and it was the user's own design** (*"should we do a non
ghost probe on losing/gaining health/current health? and then one with a ghost next to us?"*):

| | `CurrentHp` value | health bar on screen |
| --- | --- | --- |
| **No ghost** | correct | **correct** — user-confirmed |
| **With a ghost** | **correct** | **stuck visually full** |

**So the shared-singleton theory is REFUTED.** `CurrentHp` moves correctly with a ghost present —
damage, heal, death and respawn all land on the right values. The ghost is not writing the player's
health. **The bug is the HUD display alone**, and everything built on the other reading is wrong:

- Clearing `As MV Game Instance Ref` / `UI_HudRef` / `BP_HpHitable` / `LastHitBy` on the ghost
  (`GHOST_DECOUPLE_SHARED_STATE`) — all four confirmed cleared in the log, no effect. **Separately
  useful as a fact: clearing a cached pointer decouples nothing**, since any actor reaches the
  singleton via `GetGameInstance()`.
- Zeroing the ghost's damage fields — `lightAttackDamage` 15→0, `heavyAttackDamage` 50→0,
  `projectileFullDamage` 45→0 all confirmed applied, and `obtainedProjectile?` was **already
  false** — and the ghost still hits the player with its first charge attack. So the damage comes
  from neither the pawn's damage numbers nor its projectile unlock flag.

**Both fixes are still in place and both are unproven.** Neither made anything worse; neither did
what it was built to do. They should be reverted rather than left as decoration unless a later
finding justifies them.

**Where to look next for the HUD**, and it is NOT another property hunt: the HUD stores nothing
health-related (only `AnimationTickManager` moved across a whole run), so it reads `CurrentHp` live.
A live reader showing a stale value means the widget on screen is not the one being updated, or its
update stopped running. The ghost spawn briefly **possesses** the ghost and then re-possesses the
player — a controller's pawn changing is exactly the kind of thing a HUD binds to. **Test whether
the bar breaks at the moment the first ghost spawns**, which is cheap and needs no new instrument.

**And the standing trap, recorded before anyone reaches for it:** now that `CurrentHp` is known,
the tempting fix is to watch it and restore it. That is a bandage by this project's definition —
restoring a value rather than preventing what changed it — and it would also be fixing the wrong
thing entirely, since the value is already correct.

## Pending — the ghost's SHADOW is glued to the model instead of falling on the ground (2026-08-27)

**User-reported, live, and not previously recorded anywhere.** The ghost's shadow sits on the model
rather than being cast onto the ground beneath it, wherever the ghost actually is.

Not investigated yet. Worth stating what is already known that bears on it, so the next session
does not start from zero: the ghost is a spawned clone of the player's own pawn class, and
`GHOST_COLLISION_ENABLED` was turned **off** the same day this was reported — so the first thing to
establish is whether this is new. A shadow that needs a ground trace, or a mesh whose bounds are
computed from a component that is no longer colliding, would both plausibly change with that flag.
**Check it against a build with collision back on before theorising**, because that is a one-flag
A/B that either implicates the change or clears it, and `../../agent_docs/pitfalls/method.md` is
explicit that guessing twice at one symptom is the thing not to do.

Also relevant: the ghost is drawn with custom depth (the through-walls outline work, `VERIFIED.md`
2026-08-16), which is exactly the kind of render-path change that can affect how a mesh is treated
by the shadow pass.

## Pending — the ghost FLOATS UP slightly during a melee sword attack (2026-08-27)

**User-reported, live.** While the peer swings the sword, the ghost rises a little.

Not investigated. The specific thing to look at first: this adapter already has a fully worked
precedent for a ghost's Z going wrong during an animation — the slide, where the answer turned out
to be the engine's own CROUCH path moving the MESH by `-(capsuleHalf + 1)`, and where the first fix
was a render-Z bandage that has since been deleted (`BANDAGES.md` entry 1). A melee montage that
changes the capsule, or a mesh Z that is not being maintained while a montage plays, is the same
shape of problem and the same place to measure.

**Do NOT fix this with an offset.** That is precisely the bandage this adapter already removed
once, and the register records what it cost.

## Pending — the mod's core AUTOSTART did not fire, and a real player would hit this (2026-08-27)

**Found while setting up the VFX test, not by looking for it.** The mod loaded and ran correctly —
hooks installed, local state read, `STATESEND` lines flowing — but the bridge never connected:
`bridge: connected=false connect_attempts=232`, climbing by 8 per sweep, forever. **No
`meshghost.exe` was ever spawned**, and the mod's own `meshghost.log` was still from 2026-08-17.

**It is not a port conflict.** `netstat` showed nothing listening on any of 7778-7785; the only
MeshGhost process was the relay on 7777. So every port should have refused, `try_port` should have
set `refused = true`, `spawnable_port` should have offered the lowest, and `tick_disconnected`
should have spawned a core. It did not, and **it logged nothing at all** — every failure path in
`CoreLauncher::tick_disconnected` prints something, so the honest reading is that the spawn was
never attempted, i.e. `spawnable_port` returned false. Not yet root-caused; nothing below the
`spawnable_port` gate has been ruled in or out.

Starting a core by hand fixed it immediately and the session then ran clean.

**Why this matters more than it looks.** Autostart is how a *player* is meant to use this — the
mod starts the client for them and the release README says so. A developer with a core already
running would never see it. It is adjacent to the already-open "port walk is built and has never
been watched live" item above, and may be the same defect seen from the other side.

**What to look at.** Launch the game with NO core and NO relay running, and watch for
`[MeshGhostPseudo] ... started a core` (or any CoreLauncher line) in `UE4SS.log`. **What correct
looks like:** a core spawns within a few seconds and `bridge connected on port 7778` follows.
**What failure looks like:** what happened here — attempts climbing with total silence from the
launcher.

## Pending — is "heal" actually healing, or the charge's body aura? (2026-08-27)

**The mirror pipeline itself is proven**: 56 local state changes produced 56 ghost actions, zero
warnings, every start paired with a stop, `component=ok` on every spawn. Detection, wire and apply
all work. This entry is about what one of the two rows is NAMED, not about whether it functions.

**The anomaly.** Across both runs, `NS_Healing` **brackets every single charge** — the sequence is
always `'' -> heal -> heal,chg -> heal -> ''`, eight times in the test run, five times in the
capture run, with no exceptions. `NS_Healing` sits on the capsule (the body); `NS_ProjectileCharged`
sits on `handslot_R` (the hand). That is a very good fit for the user's own unprompted report that
*"the charge had a VFX happening on itself as well, while charging"* — two effects during a charge,
one on the sword and one on the character.

**But it is not conclusive**, and the counter-evidence is in the capture run: `NS_Healing` also
appeared three times (ticks 15121, 16991, 18121) with **no** charge following, and the 15121 one
completed with `NS_HealWave` + `NS_HealEndwave`. So it appears both alone and before every charge.

Two readings survive, and they need opposite fixes:
1. `NS_Healing` is the heal, and charging also triggers it — the mirror is correctly labelled.
2. `NS_Healing` is a body aura the game reuses for both, and the REAL heal is the
   `NS_HealWave`/`NS_HealEndwave` pair — in which case the "heal" row is misnamed and the actual
   healing visual is still missing.

**This is the trap `../../agent_docs/effect-investigation.md` §1 is entirely about** — names lie in
this game specifically, and it has cost this project real time before: `AnimGraphNode_Trail` turned
out to be cloth physics, and Cling Gem has no "glide" string anywhere. An asset called `NS_Healing`
is evidence about what a Blueprint author typed, not about what the effect does.

**What settles it, and it is one question to the user, not a probe:** when the ghost showed the
body aura, was that while the peer was HEALING, or only while CHARGING? Nobody has to name an
asset to answer that.

## Pending — healing and charged-projectile VFX now mirror onto a ghost (2026-08-27)

**Built from a measured capture, not from names.** One `VFX_WATCH` + `ABILITY_FIELD_TRACE` run on
2026-08-27 logged every effect the local player spawned, with its `AttachParent`,
`AttachSocketName` and `RelativeLocation` on appearance. Both instruments are back off.

What that run established, and every one of these is a measurement:

| Effect | Asset | Attached to | Socket |
| --- | --- | --- | --- |
| Healing | `/Game/VFX/Systems/NS_Healing` | the player's `CapsuleComponent` | none, zero offset |
| Charge glow | `/Game/VFX/Emitters/NS_ProjectileCharged` | the player's `VisualMesh` | **`handslot_R`** |

The hand socket is why the user sees the charge on the sword rather than centred on the character
— their own report, independently, before the log was read.

**How it works, and why it is shaped this way.** `MIRRORED_EFFECTS` in `Plugin.cpp` is a
compile-time table; the wire carries a short **key** (`heal`, `chg`) and never an asset path. That
is deliberate and it closes rather than repeats the peer-data item in `../../agent_docs/ideas.md`
("Pseudoregalia plays any montage a peer names"): a peer selects a row of our table and cannot
reach `StaticFindObject` with a string of its own. The wire carries **state, not events** — the
full active set every update — so a dropped datagram self-corrects instead of stranding an effect
on a ghost forever, which is the recall-glow bug this adapter has already paid for once.
Detection is by `component_is_active`, not by existence, for the same reason.

**No durations anywhere in the path.** The user's note that a heal "can last longer/shorter" is
exactly what a reconstructed rule gets wrong; mirroring the observed effect gets it right for free.

**What to look at.** Loopback, the ghost offset to the side. Heal, and charge the sword attack.
**What correct looks like:** the ghost shows the heal aura for as long as you hold the heal, and
the charge glow appears **in the ghost's right hand** and goes away when you release. A long heal
and a short heal should both match. **What failure looks like:** the effect never appears (check
the log for `MIRRORVFX ghost ...: started` — if that line is there, spawning worked and the
problem is placement, which is a completely different fix from the effect never firing); or it
appears and never stops, which means the falling edge is not being seen.

**The log says which half is wrong, so read it before theorising.** `MIRRORVFX local:` prints the
active-key set on every change, `MIRRORVFX ghost:` prints each start and stop. Local lines with no
ghost lines means the detection works and the apply does not; neither means detection is failing.

**Two effects the user named are deliberately NOT in this** — both need attribution work this
table avoids by only ever mirroring things attached to the player:

- **The ranged projectile itself.** It is a separate world actor, `PRJ_PlayerCutter_C`, one spawned
  per shot, carrying `NS_PlayerProjectile` on its `EnvCollider`. Structurally identical to the
  thrown Dream Breaker, which already ships — spawn a prop per shot, sample its transform, replay
  it. Not built.
- **The death burst.** The user confirmed it appears **where you died**, so it is world-spawned and
  owned by the level, not by the player — which means proximity attribution, and in a boss fight
  the screen is full of enemy effects. Candidates from the run are `NS_BasicBurst` (appears before
  every death, but also 14× during ordinary combat, so it is a generic hit burst) and
  `NS_BasicBurstRedBig` (once, across three deaths). **Neither is established**; the honest next
  step is the catalog probe playing both onto a ghost for the user to pick, per
  `../../agent_docs/effect-investigation.md` §0b.

## Pending — the FRotator float/double fix is generalised, and the ghost transform path moved onto it

`write_struct_triple` + `write_vector_param` / `write_rotator_param` (`Plugin.cpp`) now carry the
version branch and inner-field resolution that the vendored SDK gets wrong for `FRotator`, and
**`call_set_actor_location_and_rotation` was migrated onto them in the same pass** rather than
leaving them unexercised. `BANDAGES.md`'s entry is updated.

**What to look at.** Nothing specific — that is the point. This is the call that puts every ghost
where it stands and points it where it faces, so **a ghost standing in the right place facing the
right way IS the confirmation**, in any session, without testing it on purpose. **What failure
looks like:** ghosts at the wrong position or spinning to a near-zero rotation — the original
denormal symptom — or a new `refusing to call it` warning in the log.

Behaviour-preserving by construction and it compiles, but neither is the standard this project
holds adapter changes to, so it sits here until a ghost is actually seen.

## Pending — ghost collision turned OFF again (2026-08-27), and it may cost the cling-gem VFX

`GHOST_COLLISION_ENABLED` is `false` again at the user's request, reversing the 2026-08-15
keep-it-on decision. No new evidence prompted it; the feature worked as described. Built and
deployed to the live Steam install the same hour, hash-matched.

**The flag is a real revert, not a decision-only gate** (`../../agent_docs/pitfalls/method.md`):
it turns `SetActorEnableCollision` to `false` and compiles out two `if constexpr` blocks
entirely — the `bCanBeDamaged` hurtbox disable and the Pawn-channel `Block` response. So the
melee-death hazard and the never-tested non-player-damage vector both stop existing while it is
off, rather than merely being unreachable.

**The risk this creates, and it is a real one.** The cling-gem (wall-ride) VFX is a *confirmed
working* ghost visual, and it was confirmed with collision ON. This file's own earlier reasoning
predicted that effect would be structurally blocked without collision, because `doWallRun`
depends on `wallRideHit`, a real geometry hit result a collisionless ghost cannot produce. That
prediction was then beaten — but by a `doWallRun` call made on a ghost that *had* collision. **So
nobody has watched the cling gem on a collisionless ghost, and it is the single most likely thing
to have just regressed.**

**What to look at.** A peer clinging to a wall. **What correct looks like:** the ghost still shows
the cling-gem sparkle, and it still stops when the peer leaves the wall. **What failure looks
like:** no sparkle at all on the ghost while the peer clings — which would mean the effect was
riding on collision the whole time and this is now a trade, not a free revert. Check
`WALLRUN_TRIGGER_TEST`'s `TRACE wallRide ghost` lines: `moveState entered 4, calling doWallRun`
still firing with no visible effect pins it on the precondition rather than the trigger.

Also worth a glance in the same session, for the same reason: the ledge-grab self-start behaviour,
which a 2026-08-15 run showed happens with collision off *too*, so it should be unchanged.

## Pending — the bridge port walk is built and has never been watched live

The 8-port walk (7778-7785) is in `MeshGhostPseudo/Mod/src/BridgeClient.hpp` — `BRIDGE_BASE_PORT`
and `BRIDGE_PORT_COUNT`, and `preflight.ps1` checks those constants agree with the two Pokémon
adapters. It is the shape the other adapters' walk was copied FROM, which is exactly why nobody has
watched this one: it was written first and confirmed second-hand.

**What to look at.** Two games at once, which is the case the walk exists for — one Pseudoregalia
and one other game, or two Pseudoregalia instances, with no bridge port set by hand anywhere. **What
correct looks like:** each adapter's log names a *different* port it settled on, and both see their
own peers. **What failure looks like:** two adapters on one core, which presents as peers appearing
in the wrong game, or one instance with no ghosts at all and a log line about a busy port.

Recorded as the built-but-unwatched half of "two different games at once" in
`../../agent_docs/status.md` and `../../agent_docs/ideas.md`.

## Pending — a hard crash mid-session after the pause menu opened twice (2026-08-17)

**Not root-caused, and not attributable to MeshGhost on the evidence available.** Seen once. It is
here rather than in `VERIFIED.md` because nothing about it is established: not the trigger, not the
cause, and not whether this adapter is involved at all.

**What to look at.** A session with the pause menu opened and closed repeatedly, with a peer
connected. **What would settle it:** the same crash with the mod's `constexpr bool` flags off — and
per `../../agent_docs/pitfalls/method.md`, a flag flip only counts as a revert if it gates the
*work* rather than the decision the work feeds, so check the flag actually disables the cost before
believing an A/B. Bisecting real commits is the method that cannot be fooled here.

Recorded 2026-08-17 in `VERIFIED.md` as an observation, not a finding.

## Pending — a `Fatal Error!` on game exit, seen once, never root-caused

Distinct from the 2026-08-16 level-transition crash, which is fixed and confirmed. Seen once on
exit; no repro, no cause, no attribution.

**What to look at.** Whether it recurs at all on a normal quit. **What correct looks like:** the
game closes with no dialog. **If it recurs**, the UE4SS log from that run is the first thing to
read, before any theory — a mod framework's own error log is the cheapest evidence available and
this project has twice gone looking for a rendering bug that was a load failure.

## Pending — every probe under the three UE4SS mod directories predates this queue

`PROBES.md` indexes them (three directories, six scripts). They are the record of how each fact was
established, and several were run before this file existed — so the honest statement is that nothing
in this queue depends on them, and none of their logs is evidence for anything not already in
`VERIFIED.md`.

Kept as an entry so that the *next* probe run has somewhere to land before it is confirmed.
