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
- 2026-09-23 (later) — a chaser as the attacker: DamageType 5 works, DamageType 2 crashes
- 2026-09-23 (night) — what marks talking, reading and sitting on the player
- 2026-09-23 (autoplay) — LuaSocket's received strings, injected input, the camera rig, the title's keys, File Select

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

### 2026-09-23 (later) — a chaser as the attacker: DamageType 5 works, DamageType 2 crashes

Same install and build. `probes/probe_hitlist/Scripts/chaser_hit_sweep.lua`: `BPI_TryDamage` on the
player, `Attacker` = the nearest chaser pawn (`BP_PlayerGoatMain_C`, 151 units away), `ST_HitboxData`
built from a Lua table with the body-touch values above (sound resolved by `StaticFindObject`), the
chaser-to-player direction as `ForwardVector`, the player's location as `QueryLocation`.

- **Step 1, Damage 20, DamageType 5:** CurrentHp 80 → 60 inside the call, `intangible?` true at +0 and
  +500 ms. The user: *"yes i did take damage"*. So the amount follows `Damage`, and a ghost is
  accepted as `Attacker` for this kind.
- **Step 2, Damage 5, DamageType 2, another chaser 310 units away:** the game crashed inside the call
  (UE4SS "Fatal Error!" dump; the fault is in `VCRUNTIME140.dll+0x1C460`, the crashed thread's stack
  unattributable by `dev-scripts/read-minidump.py --stack`). A real `BP_Enemy_Maid_C` hit with
  DamageType 2 did not crash (the entry above), and `BPI_PerformDamageResponse(2)` with no attacker
  crashed on 2026-09-18. What DamageType 2 reads from its attacker is unmeasured; a ghost's
  `BP_HpHitable` reference is cleared at spawn (the decouple), which is one difference.
- **Step 3 (DamageType 0) never ran.** Nothing here says what knockback or the sword drop are driven by.

### 2026-09-23 (night) — what marks talking, reading and sitting on the player

Same install. Found by widening, one instrument at a time, each read-only and hot-loaded through the
scratch slot:

- **`dialogue_watch.lua`** (`probes/probe_inputnodes/Scripts/`), on the pawn, camera and controller
  across a whole NPC conversation: the only field that moved was `Interaction Target` (→ `BP_NPC_C_2` at
  the start), and it stayed set after the end. It does not mark "talking now". `DialogueCam.bIsActive`
  read `true` at rest.
- **`widget_watch.lua`**, a census of every `UserWidget` by class and `Visibility`: a conversation creates
  a `UI_DialoguePrompt_C` (owned by `MV_GameInstance_C`) with a `BP_ExpressiveTextWidget_C`, and one was
  removed at a conversation's end (01:40:37). But finished prompts also linger and vanish together later
  (01:42:39, two at once, no conversation boundary): garbage collection. A widget existing does not
  mark a conversation.
- **`probe_dump`** of `MV_GameInstance_C` with a book open vs at rest: only `activeRoom` differed. Of the
  player pawn's 389 properties, book open vs closed: **`controlState` 2 vs 0** (the rest were an
  animation track and two uptime timers).
- **`controlstate_watch.lua`**, on change, across the user's sequence: `controlState` 1 (01:46:26–29,
  01:46:56–59) and 2 (01:46:39–41, 01:47:06–08) for two NPC conversations and two books, 0 between; a
  chair gave `moveState` 8 with `controlState` 0; the pause menu left both 0 (it sets
  `WorldSettings.PauserPlayerState`). Which of 1 and 2 is the NPC and which the book is not pinned: the
  book alone read 2 in the dump.
- **The respawn loop, from the adapter's own log, contact `kill`:** the first chaser killed a freshly
  respawned player ~2.5 s after `LoadMap PRE` (01:25:41.6 → 01:25:44.2), then again at +0.3 s and so on,
  five deaths in ~25 s.
- **`intangible?` stays set ~1.86 s** per hit, from the spacing of the adapter's gated `hurt` calls
  (01:23:17.5, 19.4, 21.2, 23.1, 25.0, 26.8).

### 2026-09-23 (autoplay) — LuaSocket's received strings, injected input, the camera rig, the title's keys, File Select

Steam install (buildid 13615456, the title reads ver. 1.272), UE4SS v3.0.1 `733e5969` (`UE4SS.log` header). Measured by the
autoplay driver (`autoplay/drivers/ue4ss/`) through its `exec`, each read back from the game, not from the value written.

- **A string the vendored LuaSocket creates reads as empty in UE4SS's Lua once it is longer than 40 bytes.** An in-game
  loopback self-test (a socket pair in one Lua state, the same bytes received four ways): a 43-byte line read `#` 43 but
  `string.byte` returned nothing and concatenation gave `""`; the same 43 bytes as a `receive(43)` the same; a 13-byte line
  and 43 one-byte receives joined in UE4SS's own runtime read right. UE4SS.dll exports no `lua_`/`luaL_` symbol (0 of 4,087
  exports), so LuaSocket cannot be bound to UE4SS's runtime. The 98% corrupt lines of Phase 7.5 fit this: most bridge lines
  were longer than 40. Receiving in pieces of at most 40 carried a 30,000-byte line whole.
- **`InjectInputVectorForAction` exists on `/Script/EnhancedInput.EnhancedInputSubsystemInterface`** (params `Action`,
  `Value` struct, `Modifiers`, `Triggers`; the `InjectInputForAction` beside it too; not on the local-player subsystem class
  itself), called on the one `EnhancedInputLocalPlayerSubsystem`. The 15 `InputAction`s: IA_Attack, Crouch, Guard, Interact,
  Jump, LockOn, Look, MenuAdvance, Move, Pause, PerspectiveToggle, Power, QuickMap, Throw, WallRide. `IMC_Default` and
  `IMC_Reference` map them (keyboard: Move W/A/S/D, Jump and MenuAdvance SpaceBar, MenuAdvance and Interact E, Pause Escape).
- **In play, injected `IA_Move` walks the player relative to the camera**: 60 frames of (0, 1) moved her ~133 units; 30
  frames headed -104.94 degrees with the camera's yaw -104.94 (read from `PlayerCameraManager:GetCameraRotation`); 20 frames of
  (1, 0) headed -14.94, yaw + 90.
- **The camera is a rig, not the controller's rotation.** 60 frames of injected `IA_Look` (1, 0) moved the camera manager's
  location from (-2067, -3565) to (-2323, -3177) around the player while `PlayerController.ControlRotation` stayed at yaw 130,
  pitch 0. (1, 0) raises the camera's yaw: 10 frames took it from -105 to -91. A positive Y raises the camera's pitch: a look aimed at
  pitch -30 with Y positive drove it from 0 to 50 and stopped there; with Y negative it came to -28.
- **The title applies no mapping context**: `HasMappingContext` false for `IMC_Default` and `IMC_Reference` on the title, and an
  injected `IA_MenuAdvance` left PRESS START on screen. `UI_TitleScreen_C` has `OnKeyDown`. A `WM_KEYDOWN`/`WM_KEYUP` for Space
  (VK 0x20, scan 0x39) posted to the game's main window while another window had focus turned PRESS START into the main menu.
- **File Select** (`UI_FileSelect_C`, owned by the game instance; slots `UI_FileSlot` to `UI_FileSlot_7` read `SlotName` "File 1"
  to "File 8"): `hoveredFile` stayed empty through posted Down, Right and Left; the slot's `OnButtonBaseHovered_Event` did not set
  it either. With it written to File 8's slot, a posted X held 2.6 s ran the delete: `attemptingDelete` true and
  `deleteHeldTime` 1.57 at 1.2 s, then `SlotIs Valid?` false and `File 8.sav` gone (`deleteHoldTime` reads 2.0). The screen's
  `onSaveClicked(slot)` on the empty slot wrote a new `File 8.sav`; a posted Space then loaded `ZONE_Dungeon`.
- **A new game**: `controlState` 2 through the opening camera shot, then 0; HP 30 of 30 (a read of 20 of 80 during the load
  was not the new game's).
- **`shot showui`** (through `KismetSystemLibrary:ExecuteConsoleCommand`) writes `Saved\Screenshots\Windows\ScreenShot<NNNNN>.png`
  (1920x1080 here) with the UI; `HighResShot 1` writes `HighresScreenshot<NNNNN>.png` without it.
- **What it cannot say:** the injection's timing against a real pad (one frame late or not); whether a posted key works with
  the game minimized; what `moveState` and `actionState` values mean.

## Not measured yet

&lt;None yet.&gt;
