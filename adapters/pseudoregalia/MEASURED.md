# Measured — Pseudoregalia

**What this is.** The code-level facts about this game that the agent MEASURED: addresses, what a
field or byte reads in which state, encodings, timings, costs, which routine fires when. Each one is
settled by its own evidence, not by the user watching, because nobody can watch a byte.

**The three records, and which one a thing belongs in:**

| Record | Holds | Who settles it |
| --- | --- | --- |
| [`VERIFIED.md`](VERIFIED.md) | what the game visibly does with the adapter: "jumping works", "the ghost's fly looks right" | the user, on screen |
| [`UNVERIFIED.md`](UNVERIFIED.md) | the same kind of claim, built and waiting for the user's eyes | the user, on screen |
| **MEASURED.md** (this) | the bytes, addresses and timings underneath | the agent's own measurement |

When a measurement has a visible consequence, the bytes go here and the visible part goes to
`UNVERIFIED.md` for the user.

**The rule for an entry** (`CLAUDE.md`, MEASURED OR OBSERVED ONLY; `agent_docs/licensing.md`):

- **It names its evidence and its date**: the probe or test, the log or capture, what was done in the
  game while it ran. "Measured" with no instrument named is not an entry.
- **It is true as of that date, on that build.** Say which ROM, version or install; a fact from one
  build is not a fact about another.
- **A source is never the evidence.** A decompilation, wiki, symbol file, dump or other project says
  where to look. A `.sym` from a build we hashed identical to the ROM proves an ADDRESS, never what
  the byte means.
- **Superseding is a new dated entry** that says what it replaces; the old one gets a one-line
  pointer, not a rewrite. A measurement that turns out wrong is itself worth keeping.
- **The instrument is the first suspect** (`agent_docs/checklists/before-trusting-a-reading.md`):
  write down what it could NOT see, so the next reader knows the entry's edges.

**Keep the `## Not measured yet` section LAST.** It holds what a source says and nobody has measured,
each item written as a question with how to settle it. Nothing in it is a fact, and nothing in it is
cited as one anywhere else. Measuring an item moves it up into the measured entries; the pattern is
`documentation.md`'s "what we know, plus a plainly marked list of what we know we do not know".

Sibling records: [Pokémon Emerald](../emulator/pokemon/emerald/MEASURED.md), [Pokémon Crystal](../emulator/pokemon/crystal/MEASURED.md), [TEVI](../tevi/MEASURED.md).

**Older code-level entries still sit in `UNVERIFIED.md` and `VERIFIED.md`**: sorting them into
this file is a queued task (`agent_docs/status.md`, 2026-09-16). Until it runs, look there too.

**Keep the `## Index` section below, one line per `###` entry in either section.** This file only
grows, like `VERIFIED.md`, so the index is what keeps it findable.

## Index

- 2026-09-23 — how an enemy hurts the player: `BPI_TryDamage` and `ST_HitboxData`

## Measured

### 2026-09-23 — how an enemy hurts the player: `BPI_TryDamage` and `ST_HitboxData`

Steam install, the build of that date; `main.dll` built from the tree at this entry's commit.

- **`BP_HpHitable_C`'s event entry points, read from the class's own bytecode** (the `dump_hphitable.txt`
  one-shot, `UBERGRAPH_ENTRY` lines: each stub's script calls `ExecuteUbergraph_BP_HpHitable` with an
  `EX_IntConst` after the function pointer, the pointer matched against the ubergraph's address):
  `BPI_ConfirmAttack` 174, `BPI_CreateHitboxes` 175, `BPI_CombatDeath` 176, `BPI_PerformDamageResponse`
  177, `BPI_EndActiveFrames` 178, `BPI_TouchHazard` 179, `BPI_ContactDamageResponse` 180,
  `ReceiveBeginPlay` 181, `doHitStop` 475, `BPI_TryDamage` 603, `BPI_TryParry` 2536. **No event enters
  at 15**, so the `EntryPoint=15` that `log_damage_fns.txt` saw on every real hit (2026-09-18) is a
  resume point inside the graph, not an event.
- **What a real hit leaves on the player's `BP_HpHitable`** (`probes/probe_hitlist/Scripts/hitbox_capture.lua`,
  14 real hits, read at +0/+100/+500 ms after each HP drop; the same at all three reads): `Attacker` (the
  enemy actor), `incomingHitboxInfo` of struct `ST_HitboxData`, `Forward Vector` (a horizontal unit
  vector) and `Query Location`, and `intangible?` true after the hit. `ST_HitboxData`'s fields, by
  reflection: `Damage` (double), `HitStopDuration` (double), `HitType` (bool), `HitSound` (object),
  `hitboxSocketName` (name), `lengthRadiusHalfHeight` (vector), `DamageType` (byte).
  - A body touch, from `BP_Enemy__WalkinEgg_C`, `BP_EnemyJumper_C` and `BP_Enemy_Maid_C` alike: Damage
    5.0, HitStopDuration 0.2, HitType false, HitSound `/Game/Audio/Sounds/Actions/Cue_contact.Cue_contact`,
    `handSlot_RSocket`, 120/80/80, DamageType 5 — cost 5 HP.
  - `BP_Enemy_Maid_C`'s other hit: Damage 10.0, HitStopDuration 0.25, `Root`, 0/160/160, DamageType 2 —
    cost 10 HP. So `Damage` is the HP cost.
  - `BP_HazardZone_C` and a `PRJ_Heavy_C` projectile: Damage 5.0, HitStopDuration 0.1, no sound,
    DamageType 0 — cost 5 HP each.
  - At rest (fresh pawn): Damage 5.0, HitStopDuration 0.1, no sound, DamageType 0, `Attacker` null.
- **`BPI_TryDamage` called with those values deals the damage** (`try_damage_once.lua`, one call: the
  stored `Attacker` and `incomingHitboxInfo`, the stored `Forward Vector`, the player's own location):
  CurrentHp 75 → 70 inside the call, `intangible?` true from +0 to +1500 ms. The user saw it land as a
  normal hit. The four bare calls of 2026-09-18 (`chaser-planning.md`, Part B) left these inputs empty.
- **What it cannot say:** the sword-dropping knockback costs 0 HP (2026-09-18), and the capture fires
  on an HP drop, so that hit's struct is unread. Whether `DamageType` or `HitType` selects the reaction
  is unmeasured, and so is whether `BPI_TryDamage` accepts a non-enemy `Attacker`.

## Not measured yet

&lt;None yet.&gt;
