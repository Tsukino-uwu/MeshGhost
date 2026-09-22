# Chaser contact damage (Pseudoregalia), closing the ghost-attack leaks, freezing during dialogue

Planned 2026-09-15. **Status as of 2026-09-23: Part B FOUND (`BPI_TryDamage`) and Part E WORKS on
screen: `hurt` user-confirmed (a touch hurts and knocks back), `kill` kills through the game's own
death, and a 3 s respawn hold (the user: timing "about right") stops the respawn death loop. The
chasers now also hold while seated (user-confirmed) and, built and awaiting the user, while talking or
reading (`controlState`, Part C). Part D DONE (`e546d38c`, ADR 0068). Part A (the attack leaks) is
still NOT fixed. Facts: `adapters/pseudoregalia/MEASURED.md` (2026-09-23, three entries). This file
is deleted when the last part lands.**

**Decided with the user, 2026-09-23:** after a death the pack pauses briefly rather than resetting
(*"a small pause/freeze for them, or small iframe when respawning"*); sitting holds the pack (*"so you
can catch your breath and heal up"*). **No damage-amount setting** (the user: *"5 or just insta death
is probly fine"*): `hurt` stays an enemy touch's 5, `kill` is the stronger option. Knockback and
sword-drop kinds stay out (DamageType 2 with a chaser crashes).

## Context

Chaser ghosts (`core/chaser.go`) follow the player the way Badeline chases Madeline in Celeste. Right
now, touching one does nothing. The goal is an opt-in config toggle that makes a touch hurt or kill,
which turns the chaser into a game mode.

Chasers are local only and never go on the network, so the toggle only ever affects the player's own
game.

The contract already reserves this exact hook: `session_policy.chaser_contact` (`contract.md`,
ADR 0047). The contract calls it "the ONE effect a cosmetic ghost may ever have". It needs a per-game
ADR and the user's on-screen confirmation, and no adapter builds it yet.

A second problem is already live and breaks the contract. Cosmetic ghosts must never damage or
interact with anything (`contract.md`). Today only the sword swings are stopped, by
`GHOST_PREHIT_PLAYER` in `Plugin.cpp`. That flag pre-fills the ghost's `hitActorsArray` with the
player. The user still sees the following:

- **Sunsetter** hurts the player and other ghosts.
- **Strikebreak** hurts the player and other ghosts.
- Ghost attacks **hit switches and levers**.

This leak gets fixed first. Otherwise "chaser contact off" isn't actually harmless, and a chaser's own
Sunsetter becomes a second damage path that nothing controls.

Decisions made with the user:

- `chaser.contact` becomes `"off" | "hurt" | "kill"`.
- **hurt** is exactly what an enemy's touch does in-game.
- **kill** is a guaranteed death.
- Chasers also freeze during NPC dialogue and note reading, the same way they do for the pause menu
  and item pickups.

## Corrections after checking the code (2026-09-15, later the same day)

Three premises below were stale when written; the parts that rest on them start from these facts:

- **`player_frozen` IS sent** by the C++ mod (`Plugin.cpp`, from `PauserPlayerState`, since
  2026-09-05) for the pause menu and the item-pickup popup. The `UNVERIFIED.md` "blocker" entry of
  2026-09-04 predates that. Part E's "first confirm the adapter sends it" is answered; what stays
  open is the I6 watch item (pause about ten seconds with a chaser running, unpause, it resumes
  where it left off).
- **`render_remote.cosmetic` IS emitted** by the core on every chaser and replay frame. The adapter
  parses neither it nor `session_policy` at all; Part E's step 1 is a new handler, not a fix.
- **No grace window exists** in the core, and none is needed there: a seam is a `despawn_remote` and
  a fresh spawn the adapter already sees, and a player respawn is the adapter's own fact. The window
  is adapter-side (ADR 0068).

## Part A: make every ghost attack inert (bug fix, first)

**MECHANISM FOUND, 2026-09-18, fix NOT yet built.** `probe_hitlist/` was run live: Sunsetter next to a
loopback ghost's save-crystal leak reproduced on command. The victim is recorded in the attacking
ghost's own `hitActorsArray` — the SAME array `GHOST_PREHIT_PLAYER` already pre-fills for the player.
At spawn: `hits=1 [player]`. After one Sunsetter near a save point: `hits=3 [player, BP_SavePoint_C_1,
BP_SavePoint_C_1]` (added twice in one hit). This is why the leak fires only ONCE per ghost, then again
after a save reload: the array is the gate, and a reload makes an entirely new ghost pawn with a fresh
array (measured: pawn address changes, array resets to `hits=1`).

**Sunsetter/Strikebreak reach interactables that ordinary melee never touches** — melee's query stays
inside `hitActorsArray`'s existing player pre-mark and never reaches a save crystal; these two abilities
clearly query something wider. So extending `GHOST_PREHIT_PLAYER` to cover interactables (not just the
player) is the most likely fix, but WHICH actor/array a save crystal is discovered through by these two
specific abilities is not yet isolated — `probe_leakcount`'s class census at the moment of a hit is the
next instrument, not another guess. Ghosts have no `BP_HpHitable` at all (confirmed, see Part B), so
"hurts other ghosts" cannot happen via HP — the 2026-09-15 report of ghosts blinking red is separately
explained: `MIRROR_HURT_REACTION` deliberately plays the hurt reaction on ghosts (see Part E's chaser
no-blink change), so a chaser pack replaying moments the player was hit will visibly flash without any
HP involved. Not yet fixed: whether that flash was ever mistaken for real ghost-on-ghost damage.

1. ~~Measure each leak~~ DONE above for the save-crystal path. Sunsetter/Strikebreak-on-player and
   the lever path are the same array by construction (the pre-mark already covers the player; a lever
   is untested but expected to be the same "reaches wider than melee" shape).
2. **Fix the cause.** Extend the pre-mark to interactables once the exact query is named (above), or use
   the game's own attack-owner check if the census finds one. Never skip the attack montages.
3. **Record it.** Flag row in `FLAGS.md`; measurements in `UNVERIFIED.md`; user confirms on screen.

## Part B: find how the game hurts and kills the player

**FOUND 2026-09-23: `BPI_TryDamage(Attacker, HitboxInfo, ForwardVector, QueryLocation)` with a real
`ST_HitboxData` deals the damage** (75 → 70, i-frames on, the user saw a normal hit). The struct's fields,
what a body touch carries, the entry points and what is still unread are in
`adapters/pseudoregalia/MEASURED.md` (2026-09-23). `Damage` is the HP cost, so an amount is one field.
**Then, the same day, with a chaser as `Attacker` and the struct built from a table: DamageType 5 at
Damage 20 took exactly 20 HP (the user saw the hit); DamageType 2 CRASHED the game** (MEASURED.md,
"(later)"). So the shipped hurt is DamageType 5 with a chaser as Attacker; never 2 with a ghost. The
2026-09-18 account below is kept as the record of the four calls that did not work and why.

**DAMAGE FACTS MEASURED, 2026-09-18. The CALL MECHANISM to trigger it artificially is UNRESOLVED after
four attempts — read this before trying a fifth.**

**Measured, `enemy_hit_watch.lua` (read-only) across ~15 real hits:** an enemy's contact usually costs
**5.0 HP**; at least one event cost **10.0**; a strong knockback (the one that drops the sword) cost
**0**. Both health locations (`CurrentHp` on the GameInstance and on the pawn's own `BP_HpHitable`) move
in the SAME 25ms sample on a normal hit, so no ordering claim is possible at that resolution — but on
RESPAWN the GameInstance moved ALONE (0→80 with the component still reading 0 for one sample), so they
are not one value mirrored instantly; the GameInstance write is independent. **i-frames ≤ ~1.56s**
(two consecutive real hits landed 1564ms and 1602ms apart; wider gaps were the enemy's own attack
cadence, not invulnerability). **Death → respawn ≈ 3.0s**, through an entirely new pawn object (the
`As MV Game Instance Ref` briefly read `nil` across the swap).

**`BP_HpHitable_C`'s full function list was dumped** (`probes/probe_hitlist/` grew a `dump_hphitable`
one-shot, since folded into the mod's `dump_damage_fns.txt`/decode path). It exposes several `BPI_*`
Blueprint interface functions: `BPI_PerformDamageResponse(DamageType, attackDirection)`,
`BPI_ContactDamageResponse()`, `BPI_CombatDeath(dissolveDelay)`, `BPI_TouchHazard(Location)`,
`BPI_TryDamage(Attacker, HitboxInfo, ForwardVector, QueryLocation)`,
`BPI_TryParry(Attacker, HitboxInfo, ForwardVector, QueryLocation, Knockback?)`,
`BPI_ConfirmAttack(HitPerson, EnemiesHitResponse, ConfirmLocation, providesBounce?, providesPower?)`.

**Four calls tried live, in this order, EACH producing zero HP change and no visible effect** (each
called correctly — resolved, `ProcessEvent` succeeded, no crash from the call itself):
1. `BPI_PerformDamageResponse(0, zero-vector)` — the shipped hurt mirror already calls this on ghosts;
   confirmed reaction-only (blink at type 0, knockback+blink at type 1) with a live tripwire proving no
   HP moves. **DamageType ≥ 2 crashes the game instantly** (types 2 and 3 both did, identically —
   `damage_sweep.lua`'s own header has the full account; do not try 4+).
2. `BPI_ContactDamageResponse()` — zero params, called on the player's own `BP_HpHitable`. No effect.
3. `BPI_CombatDeath(dissolveDelay=0.0)` — no effect (first test was contaminated by an edge-latch bug
   that fired it dozens of times a second; the bug is fixed — see Part E — but a CLEAN retest of this
   call specifically has not happened yet).
4. `BPI_TouchHazard(Location=player's own position)` — tied by this mod's own 2026-08-27 comment to
   "a pit fall costs exactly 5 HP". No effect either, called every tick while overlapping.

**Working theory, not yet tested:** every one of these reads context (`Attacker`, `incomingHitboxInfo`
— both plain properties on the component, confirmed present in the dump, both null/default at rest)
that a real attacker sets before dispatching, and calling the bare interface with that state untouched
is calling half a mechanism. `Attacker` is a plain `ObjectProperty` (a pointer, not a guessed struct),
so writing a real actor reference into it before calling `BPI_ContactDamageResponse()` is the next
cheap, low-risk test — untried as of this entry.

**A dead end, recorded so it is not retried:** the real dispatch point is
`ExecuteUbergraph_BP_HpHitable` (the ONLY thing `ProcessEvent` ever sees fire on `BP_HpHitable`, hit or
not — none of the seven named `BPI_*` functions above ever appear as their own `ProcessEvent` call, real
hit or ours). Its `EntryPoint` parameter reads a CONSISTENT `15` on every real player-took-damage
sample — but also on `BP_EnemyJumper_C_3`/`BP_Enemy_Horn_C_7` when the PLAYER damaged THEM, the exact
opposite direction. So `EntryPoint` is not a per-interface discriminator and this instrument has
nothing further to give. **A live crash came from this path** (`EXCEPTION_ACCESS_VIOLATION` inside
`UE4SS.dll`, `GetFullName()` called on a garbage `Attacker`/`HitPerson` pointer read from the shared
ubergraph params buffer): fixed to print the raw address only, never dereference — the same
"IsValid() refuses is address-only" lesson `pitfalls/by-lesson.md` already carries, violated once
here and now closed. Two DIFFERENT hitables were also observed with IDENTICAL `Attacker` addresses
microseconds apart, confirming those particular reads are stale buffer garbage, not real data, even
address-only.

**Kill path specifics, if `BPI_CombatDeath` is retried:** does it also zero `CurrentHp`, or only play
the dissolve/respawn while HP stays wherever it was? Unverified either way — the one live call so far
was unreadable through the edge-latch spam bug.

## Part C: freeze the chaser during NPC dialogue and note reading

Today `player_frozen` (ADR 0053) covers the pause menu and item pickups. Talking to an NPC or reading a
note doesn't count, so chasers keep closing in. With contact on, they would hit a player who can't
move.

1. **Probe what marks these states on the player pawn.** Candidates to test:
   - `DialogueCam` becoming the active view target;
   - a dialogue or reading flag;
   - an input or movement lock the game sets.

   Measure the start and end of both an NPC conversation and a note. Check each against the pause and
   item signals the adapter already uses.
2. **Feed the measured signal into the same `player_frozen` path.** The core needs no change, because
   gameplay time simply stops.
3. **The user confirms on screen:** during a conversation and a note, chasers stop in place. They
   resume when the player regains control, with no hit on resume.

## Part D: the contract revision (Go side) — DONE 2026-09-15, commit `e546d38c`

What shipped, so the adapter work reads the right shape:

- ADR 0068 (`agent_docs/adr/0068-...`), indexed in `architecture.md`. `chaser.contact` is
  `"off" | "hurt" | "kill"`; a legacy bool `true` reads as `"hurt"`, `false` as `"off"`; any other
  value is refused (the flag exits at launch, a saved file keeps its old value and says so).
- `session_policy.chaser_contact` carries `"hurt"` or `"kill"` and is absent when off or when the
  chaser is disabled. `"enabled"` is retired; no adapter ever read it.
- The grace window is **adapter-side**, no wire change: it starts from the chaser spawn the adapter
  already sees (a seam is a despawn plus a fresh spawn) and from the player's own respawn. Its
  length is measured in Part E.
- Root `CLAUDE.md` unchanged (the user's call): the ADR explains that contact triggers the game's own
  damage path exactly as an enemy does and writes no state.
- `core.ChaserContact` (`core/chaser.go`), the string flag, the bool-or-word file reader
  (`cmd/meshghost/main.go`), hot reload, the policy push, the five shipped `config.json` files,
  `contract.md`, `bridge.go`, the template `PROTOCOL.md`/`README.md`, `docs/config.md`.
- Tests green including race and the two e2e runs; the e2e chaser test starts the real binary with
  `-chaser-contact kill` and asserts the word arrives.

## Part E: the Pseudoregalia adapter

**BUILT 2026-09-18, blocked on Part B — every piece below exists and runs without crashing, but
produces no gameplay effect because the damage call itself is still unresolved.**

1. **DONE — read the policy.** `session_policy` gets its own handler in `Plugin.cpp` (there was none),
   parsing `chaser_contact` into `g_chaser_contact_mode` (`""`/`"hurt"`/`"kill"`) and logging
   `ghost_collision` once (read, not acted on — this adapter ships no solid ghost). Confirmed live:
   `SESSION_POLICY: chaser_contact = "hurt"` / `"kill"` both round-tripped from `config.json` through
   the core to the adapter.
2. **DONE — the contact test.** `chaser_capsules_overlap()`: horizontal separation vs. the sum of both
   capsules' radii, vertical vs. the sum of both half-heights, both read LIVE off each pawn's own
   `CapsuleComponent` (never assumed). Gated on the `chaser:` id prefix and `!player_frozen_sent`
   (`player_frozen_sent` is this adapter's OWN record of what it last told the core, reused rather
   than re-derived). **NOT yet built: the grace windows** (a window after a chaser spawns, and after
   the player's own respawn) and an explicit i-frame/death skip — the plan's own requirement, still
   open. Confirmed live that the overlap test itself fires correctly (it detected real chasers
   touching the player).
3. **DONE (mechanically) — the call sites**, currently calling the Part B candidates in turn as each
   was tried: `hurt` → `BPI_TouchHazard(player's own location)` every tick while overlapping (relying
   on the real i-frame gate to throttle it, the way a real hazard would); `kill` → `BPI_CombatDeath`,
   edge-triggered. **A real bug found and fixed live:** the first `kill` test re-fired dozens of times
   a second — position jitter (interpolation) flickered `overlapping` false/true between ticks, and a
   purely geometric edge-latch treated each flicker as a fresh trigger. Fixed by latching on the
   PAWN'S OWN IDENTITY instead (`static UObject* last_killed_pawn`): a player has exactly one life at
   a time, survives jitter by construction, and clears itself for free on the next respawn (a new pawn
   object, already measured in Part B). **Both call sites are dead until Part B lands a working call.**
4. **NOT started — the records**, since there is nothing confirmed yet to record as a mechanism:
   - an `FLAGS.md` row;
   - the mechanism in `SYNCED.md` and `documentation.md`;
   - `UNVERIFIED.md` until the user confirms;
   - a README build-story step once confirmed;
   - how the leaks were found, in `pitfalls.md`;
   - back-port to `adapters/_template/README.md` the lesson that cosmetic ghost attacks must be inert
     on every attack path, interactables included;
   - a phase-file entry.

## Verification

- **Go side (verified by Claude): done 2026-09-15** — build, vet, gofmt, the package tests, the race
  run and the two e2e tests, all green on the committed tree. CI runs when the user pushes.
- **Live (the user confirms on screen):** Claude starts the relay, core and scaffolding hidden, and
  asks before launching Pseudoregalia. The checks are small steps, in order:
  1. A loopback ghost uses Sunsetter, Strikebreak and swings next to the player, another ghost and a
     lever: no damage, no reaction, and the lever doesn't move.
  2. With `contact: "off"` and a chaser, a touch does nothing.
  3. With `"hurt"`, a touch looks exactly like an enemy's touch (reaction, HP loss, i-frames), with
     no repeated hits.
  4. With `"kill"`, the game's own death and respawn play, with no instant re-hit on respawn.
  5. In the pause menu, NPC dialogue and note reading, the chaser freezes while closing in and deals
     no damage.

  Afterwards, close every process Claude started and verify they are gone.
