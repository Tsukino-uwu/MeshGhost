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

## Pending — the charged attack DAMAGES THE PLAYER, and it now looks like the player hitting their OWN ghost (2026-08-27)

**STATE AT END OF 2026-08-27. Still open. Three candidates tried, none fixed it, and only two of
them actually produced evidence — read the third carefully before repeating it.**

| Tried | Result |
| --- | --- |
| Our `chg` VFX mirror removed (one-variable test) | **REFUTED as the cause** — ghost still hit the player. Row restored. |
| Ghost's damage numbers zeroed (`lightAttackDamage` 15→0, `heavyAttackDamage` 50→0, `projectileFullDamage` 45→0) plus `obtainedProjectile?` already `false` | **REFUTED** — all confirmed applied in the log, ghost still hit the player. So the damage reads none of these. |
| Ghost's hitbox collision disabled (`Hit Component 1`, `CollisionComponent`) | **DEAD, 2026-08-27 — there was never anything to disable.** The fixed logging ran and said it outright: `'Hit Component 1' resolves but is NULL on the ghost -- nothing to disable` and `'CollisionComponent' does not resolve on this build`. Not inconclusive any more; this line of attack is finished. |

**The user confirmed the shape of it again, 2026-08-27:** *"I don't see a visual projectile coming
from the ghost (unlike the thrown sword that we have fixed before), but it does hurt me on the
first attack."* So all three tried candidates are now closed, and what remains is the theory the
next paragraph has always named: something real exists, it damages, and our side never draws it.

**An instrument for it is now built and deployed — `GHOST_PROJECTILE_WATCH`, ON for the next run.**
It sweeps every live object ONCE for the projectile name shape (so the probe reports what this
build actually calls them rather than finding nothing because it was handed the wrong name), then
polls each class it found and logs every instance one time with its **Owner** and **Instigator**.
Those two fields are the measurement: a projectile owned by the ghost ends the guessing, and one
only ever owned by the player says the damage comes from somewhere else and the search moves.

**RUN, 2026-08-27 — and the answer moves the search.** The sweep found the class immediately
(`BlueprintGeneratedClass /Game/Blueprints/Projectiles/PRJ_PlayerCutter.PRJ_PlayerCutter_C`), and
across the whole session **exactly one projectile instance ever appeared**:

```text
PRJWATCH: + APPEARED tick=17251 'PRJ_PlayerCutter_C ...PRJ_PlayerCutter_C_2147473717'
    owner='<none>' instigator='BP_PlayerGoatMain_C ...BP_PlayerGoatMain_C_2147482216'
```

`..._2147482216` is the **local pawn** (the census names both instances in the same log; the ghost
was `..._2147477779`). So the only projectile in the world was the player's own, and the user was
hit by the ghost's charged attack in that same session.

**Two readings, and they are not equally likely — do not pick one yet.**

1. **The ghost never spawns a projectile, and the damage is something else entirely** — a melee
   hitbox during the charge montage, most plausibly, which would also explain why nothing is ever
   visible.
2. **The probe cannot see a second one.** This game pools and re-uses actors — that is established
   here, it is why no afterimage ever disappears — and this probe remembers every instance it has
   seen forever, so a **pooled projectile re-fired by the ghost would log once and never again**.
   The single sighting is at tick 17251, and the user's charges came later.

**Reading 2 is a defect in the instrument and is fixable before the next run:** track each
projectile's *instigator* rather than its identity, and log whenever an actor's instigator changes
or it goes active again. Then a re-used actor fired by the ghost announces itself. Until that is
done, this measurement **does not** clear the ghost — and saying it does would be exactly the
"a clean instrument means widen the subsystem" mistake `CLAUDE.md` warns about.

### THE TITLE OF THIS ENTRY IS PROBABLY WRONG — it looks like the player hitting their own ghost

**The user's own reading, 2026-08-27, and it fits the evidence better than anything above:**
*"when im getting hurt, its only the player that blink red/take damage, not the ghost. so i guess
it might be us hitting ourself by attacking the ghost? ... im pretty sure it is a 'player
accidently hurting the ghost, causing damage to us self' issue."*

**Why that explains what nothing else did.** Health is `CurrentHp` on the **GameInstance**, which is
a singleton — measured this same day, and the reason clearing the ghost's reference to it changed
nothing (any actor reaches it through `GetGameInstance()`). **There is only one health value in the
running game.** So damage landing on the ghost decrements the number the player's bar reads, and
only the player flashes red because the ghost has no bar of its own any more. This adapter already
has the coupling confirmed on screen: *"ENEMY damage to a ghost hurts and can KILL the real
player"* (`VERIFIED.md`, 2026-08-17). This is that bug, with the player as the source.

It also absorbs the "only the FIRST attack lands" detail, and better: `hitActorsArray` is an
already-hit list, so once the ghost has been hit it stays permanently already-hit — no clearing of
a ghost-side copy required.

**What the three instrumented sessions actually established** (all with `GHOST_PROJECTILE_WATCH`):

| Measurement | Result |
| --- | --- |
| Every `PRJ_PlayerCutter_C` in the world | instigated by the **local pawn**, never by a ghost — and this is a loopback rig, so a ghost firing one would produce a second projectile ~100ms later. There was never a second. |
| The **player's** `LastHitBy` | `<none>` for a whole session in which the user was repeatedly hurt |
| The **ghost's** `LastHitBy` (cleared at spawn, so any value means something hit it) | `<none>` |

So **this game does not record either hit in `LastHitBy`** — that field is a dead end for this
question, and the two runs spent on it are the answer to "is it worth trying". Neither result
implicates or clears the ghost.

**The measurement that is built but has NEVER been run**, and it is the next thing: a readback of
the ghost's actual collision state, `GetActorEnableCollision()`, long after spawn. `SetActorEnableCollision(false)`
runs at every ghost spawn with `GHOST_COLLISION_ENABLED` false, so on paper nothing can touch the
ghost at all — and yet the user is being hurt by what looks like their own projectile meeting it.
**Exactly one of those two things is false.** A pawn clone runs the player's own `BeginPlay`, which
is precisely the kind of thing that could turn its collision back on afterwards, and this file has a
standing rule against trusting a value because we wrote it.

**If collision does read back true, the fix is not a new flag** — it is finding what re-enables it,
and the two existing switches (`GHOST_HURTBOX_DISABLED`, the Pawn-channel response) are both gated
behind `GHOST_COLLISION_ENABLED` and so compile out entirely today. Note `bCanBeDamaged=false` is a
**recorded negative** for the melee case (`VERIFIED.md`, 2026-08-15), so it is not the answer on its
own.

**The old theory, kept because it is not disproven:** the pawn's `hitActorsArray` on a ghost that
fires its own attack. It now has no evidence for it — no ghost-instigated projectile has ever been
seen — and it should not be worked on before the collision readback is run.

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

### REPRODUCED exactly, 2026-08-27, on a deliberately clean start

The shadow-census run was launched with **no core running and no MeshGhost process holding any port
in 7778-7785** (only a relay on 7777, which the launcher has nothing to do with). The mod came up
fine — hooks installed, `STATESEND` flowing, `TRACE local` every tick — and the bridge counter
climbed `8, 16, 24, 32, 40, 80, 120` with **not one CoreLauncher line of any kind**, exactly as
before. Starting a core by hand connected it instantly (`bridge connected on port 7778`) and the
session ran clean from there.

So this is not intermittent and not environmental: it is a repeatable defect on the path from
`try_port` through `spawnable_port` to `tick_disconnected`.

### ROOT-CAUSED and FIXED in code the same day — a Winsock `select()` rule. NOT yet watched

`BridgeClient::try_port` opened a non-blocking socket, got `WSAEWOULDBLOCK` from `connect` (which is
what a loopback connect to a closed port always does), and then waited on `select` with **only a
write set and `nullptr` for the exception set**.

**Windows signals a FAILED non-blocking connect in `exceptfds`, and marks the socket writable only
on SUCCESS.** So a refused port never became writable, `select` timed out with 0, and `refused`
stayed `false`. From there it is a straight line: no refusal → `have_spawnable_port` never set →
`spawnable_port()` returns false → **`CoreLauncher::tick_disconnected` is never called at all**.
That is why the launcher printed nothing: it was never reached. The counter climbed because the
sweep itself was working perfectly.

Two things were wrong and only one of them was that bug:

1. **The bug**: `select` now takes an exception set, and a socket that finished without succeeding
   has its `SO_ERROR` read to decide whether it was a refusal. Immediate refusals (the
   `err != WSAEWOULDBLOCK` branch) were always detected correctly — only the in-progress path was
   blind, which is the path loopback always takes.
2. **The silence**: the `else` of `spawnable_port()` in `Plugin.cpp` was the one branch on the whole
   autostart path that logged nothing, which is why a code-level bug read as "the launcher is not
   running". It now prints, throttled to the bridge-stats cadence and next to that line.

### That fix was NOT enough — and measuring instead of guessing again found the real cause

The `select` fix shipped, the game was relaunched, and **autostart still did not fire**. What had
changed is that the new log line said which gate was failing, every two seconds: *"the sweep found
NO free port to start a core on"*. So `refused` was still never true.

**Rather than a third guess at the socket code, the behaviour was measured directly** — outside the
game, in isolation, connecting to each port in the range with the same non-blocking sequence:

| Port | Result |
| --- | --- |
| 7778, with a core listening | **writable in ~4ms** — a successful connect |
| 7779-7785, nothing listening | **neither writable nor errored after 500ms** |
| 65000, nothing listening | same |

**A closed loopback port on this machine is never refused at all.** The SYN is dropped, not
rejected — the behaviour of a firewall in "block" mode rather than "reject" — so the connection
just sits in `SYN_SENT`. No `select` timeout could have fixed that, because nothing was ever
coming. The original 2ms window was not too short; it was waiting for an answer that does not exist.

**So the question stopped being asked of the network and started being asked of the OS: a free port
is one we can BIND.** `port_is_bindable` opens a socket with `SO_EXCLUSIVEADDRUSE`, binds, and
closes — instant, deterministic, and immune to whatever a firewall does to traffic. It is also the
same question the core itself asks a moment later when it binds its listener, so a port with a core
on it fails and is excluded for free, exactly as the refusal test was meant to do. `refused` is kept
as the first test, because when it does arrive it is unambiguous and costs nothing.

**Verified outside the game before rebuilding:** with a core on 7778, that port reports
`bindable=False (AddressAlreadyInUse)` and 7779/7780 report `bindable=True`.

**And it fired on the next launch, 2026-08-27: `started meshghost.exe (pid 30368)`, with nothing
started by hand.** Not moved to `VERIFIED.md` yet — a player-visible claim ("the mod starts the
client for you") needs the user to see a ghost appear without anyone starting anything, which is
what that same run is for.

**The method is the part worth keeping.** Two socket-level fixes were reasoned out from the code and
neither was the cause; the thing that ended it was ten seconds of measuring what the OS actually
does with a connect to a closed port. That is `CLAUDE.md`'s "two guessed fixes failing the same way
is a signal — isolate by subtraction, never a third guess", and the subtraction here was to take the
socket code out of the game entirely and ask the question standalone.

## RESOLVED — "heal" IS healing; the table row is correctly labelled (2026-08-27)

Asked because `NS_Healing` bracketed every single charge across two runs, which fitted "the charge
has a body aura the game happens to have named NS_Healing" at least as well as it fitted "this is
the heal" — and in this game names have lied before (`AnimGraphNode_Trail` is cloth physics; Cling
Gem has no "glide" string anywhere).

**Answered by the user, who watched it**: the white particle effect appears *while healing*, not
only while charging. So the row is right and the mirror is correctly labelled. **The pairing in the
log was just what they happened to be doing** — heal, then charge — and reading a mechanism into it
would have been a wrong turn.

Worth keeping rather than deleting: the anomaly was real, the two readings needed opposite fixes,
and **the thing that settled it was a question a person could answer without naming an asset**.
That is cheaper than any probe and should be reached for first.

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

### DECLINED on screen, 2026-08-27 — the heal's "yellow ball" does not appear on the ghost

**User, watching a real heal:** *"the ghost is still not doing the 'yellow ball' vfx when
healing."* This is a decline of the healing half of the mirror, and it is worth more than a
confirmation would have been, because the log from the same session says every stage worked:

```text
MIRRORVFX local: '' -> heal -> heal,hw,hew -> hw,hew -> ''   (a real heal, tick 24705)
MIRRORVFX ghost p1-ghost: started 'hw' (component=ok)
MIRRORVFX ghost p1-ghost: started 'hew' (component=ok)
```

Detection fired, the wire carried it, and both wave systems spawned with `component=ok` on the
ghost. **The effect still is not on screen** — so `component=ok` is exactly the same species of
non-evidence as "it ran without errors", and this is the second time this adapter has been told
that by a person rather than by an instrument.

**The first suspect is WHERE, not whether.** `hw`/`hew` are `world_spawned` rows: the player's real
ones are attached to nothing and carry a world coordinate, while the ghost's copies are spawned
attached to `RootComponent` — the capsule's centre, mid-body, which is not the ground a wave rises
from. That is the recall glow's bug in a new place (it shipped attached to the ghost's root purely
because nothing said otherwise, and the user reported it sitting visibly wrong).

**What settles it, and it is the measurement that already fixed the glow:** one `VFX_WATCH` run
over a real heal, reading the PLAYER's own wave pair against the GHOST's — asset, `AttachParent`,
`AttachSocketName` and `RelativeLocation` on appearance. Do not adjust an offset by eye first;
`../../agent_docs/effect-investigation.md` is the playbook and this is the case it was written for.

**Note the white aura is a separate question and is already answered** — see the RESOLVED entry
above: `NS_Healing` IS the heal's own body effect, confirmed by the user watching it.

### That run happened, the placement was corrected, and it is STILL missing (2026-08-27)

`VFX_WATCH` over a real heal established the arrangement: the player's own `NS_HealWave` and
`NS_HealEndwave` are owned by **`WorldSettings` and attached to nothing** — placed in the world,
not carried on the body — while `NS_Healing` sits on the player's own capsule. The mirror was
spawning every row ATTACHED, so the ghost's wave copies rode the capsule's centre, mid-body.

**Corrected, and still not visible.** World-spawned rows now spawn unattached at the ghost's feet
(the foot offset read from the ghost's own `VisualMesh`, not hardcoded), the call's signature was
dumped and every parameter matched by name, and both waves reported `component=ok`. The user,
watching: *"healing is still missing the last VFX"*.

**Two different spawn arrangements producing the same nothing is the signal to stop adjusting
placement** (`../../agent_docs/pitfalls/method.md`). So the question changed from *where did it go*
to *which system is the yellow ball at all*, and the catalog probe answered as far as a three-way
cycle can: *"its those 3 effects, but im unsure what order they are in, only 2 of them are
shown/visible during the healing itself. think the 'ball' thing is the one in the middle between
them"*.

**So the ball IS one of the three already mirrored**, and probably `NS_HealWave` — but "probably"
is carrying real weight there, because a 2.5s cycle of three systems with nothing on screen naming
them is not an identification. **Next run narrows `VFX_PROBE_NAME_FILTERS` to ONE name** so a single
system loops on the ghost and the answer is yes or no about one thing. That build was made and then
reverted with the other probes at session end; re-narrowing it is a one-line change.

**One fact from the same capture that should stop a wrong turn:** the ghost demonstrably RECEIVES
all three heal systems. Detection, wire, spawn and placement are not the defect. Whatever is wrong
is downstream of the component existing on the ghost — a Niagara user parameter the game sets after
spawning is the most plausible candidate, and it is a thing this project has never had to reproduce
before.

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

### RECURRED 2026-08-27 — on exiting to the MAIN MENU, not on quitting

User: *"The UE-pseudoregalia Game has crashed and will close / Fatal error!"* — *"got this when i
exited out to the main menu"*. That is a level transition, which makes it adjacent to the
2026-08-16 transition crash (fixed and confirmed) rather than a straight repeat of the exit case
above; "exit" now covers two different actions and the entry should not be allowed to blur them.

**The log was read first, and it says almost nothing** (archived from that session). The last
adapter line is a ghost-spawn census at 18:59:08, then the ordinary bridge-stats line every ~0.7s
until it simply stops at 18:59:34. No warning, no unresolved name, no release path, no `LoadMap PRE`
line for the transition.

**Attribution is genuinely open, and this run is a bad witness.** Three probes were compiled ON
(`SHADOW_COMPONENT_PROBE`, `GHOST_PROJECTILE_WATCH`, `VFX_CATALOG_PROBE`), and the catalog probe
spawns Niagara components onto a ghost — a component whose owner is destroyed at a transition is
exactly the kind of thing that turns a teardown into a crash. But the same class of crash was seen
on 2026-08-17 with none of that on, so **the honest reading is "unattributed, and the next
occurrence must be on a probe-free build to be worth anything"**. Do not record a cause from this
one — `CLAUDE.md`'s rule about numbers gathered while a heavy probe was live applies to crashes as
much as to measurements.

## Pending — every probe under the three UE4SS mod directories predates this queue

`PROBES.md` indexes them (three directories, six scripts). They are the record of how each fact was
established, and several were run before this file existed — so the honest statement is that nothing
in this queue depends on them, and none of their logs is evidence for anything not already in
`VERIFIED.md`.

Kept as an entry so that the *next* probe run has somewhere to land before it is confirmed.
