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
- 2026-09-23 (autoplay, later) — how she moves: frame rate, the capsule, jump heights, the backflip, the save slot
- 2026-09-23 (autoplay, evening) — ledge grabs, climb poles, the float at a jump's top, coyote time, the slide, breakable walls
- 2026-09-23 (autoplay, night) — the Keeper, a pit's cost, a bubble's boost, the castle's exits
- 2026-10-02 — Facts the code comments carried, moved here word for word

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

### 2026-09-23 (autoplay, later) — how she moves: frame rate, the capsule, jump heights, the backflip, the save slot

Same install. Read by the autoplay driver's flight recorder (`recent`: one row a frame of position, velocity, `moveState`,
`actionState`, `controlState`) around injected inputs, and by named reads through `exec`.

- **144 frames a second**: `GetWorldDeltaSeconds` 0.00694; 418 driver frames in 2.94 s of `GetTimeSeconds`. The game
  instance's `Frame Rate Limit` reads 144.
- **The capsule and movement component**: `CapsuleRadius` 22, `CapsuleHalfHeight` 65 (the centre reads 67 over a floor
  traced at -400); `CharacterMovement`: `MaxStepHeight` 45, `WalkableFloorZ` 0.643, `MaxWalkSpeed` 550, `JumpZVelocity`
  900, `GravityScale` 2.
- **A jump's height follows the hold**: Jump held 3 frames rose 85 units, 30 frames 180, 80 frames 206 (205 in two more
  tries). Air time 93, ~116 and 139 frames. `moveState` 1 in the air, 0 on the ground, 2 crouched (the capsule's centre
  43 lower). A ledge 200 over the floor (ZONE_Dungeon's hall, x ~ -2000) was climbed by a running jump held 80 frames.
- **The backflip**: 40 frames of MoveUp, then MoveDown (the ground state `actionState` 18 while it is held), Jump held
  80 frames starting 1 to 16 frames into the reverse, then MoveUp again: peak 265-266 over the takeoff in all six tries.
  With MoveUp held again from 2 frames after the Jump, she drifted back ~24 units, stalled at ~120 up, then went forward:
  200 up about level with the takeoff, the peak ~40 units past it. The user saw it on screen: *"yes you did a proper
  backflip there"*.
- **Crouch then Jump** (Crouch held, Jump 20 or 70 frames in) is a different move: `actionState` 17, a hop backward from
  the facing, 40 high, ~290-320 long at horizontal speed 500.
- **The save slot**: `MV_GameInstance_C.activeSaveSlotName` read "File 5" while the game ran the new game started in File 8
  through File Select; written "File 8" and read back through a fresh lookup. The game's own `instSaveGameToSlot()` then
  changed File 8.sav only (the other seven identical by hash); `reloadAndRespawn()` put the player back on the zone's spawn
  (-2300, -3650) with the slot still File 8. `Last Save Point Name` read "None" and `activeSpawnTag` "gameStart".
- **Line traces**: `KismetSystemLibrary:LineTraceSingle` channel 0 stopped at walls and at the cages; `CapsuleTraceSingle`
  takes the same arguments plus radius and half-height. A downward trace that starts inside solid geometry found no floor.
  Every hit read `bStartPenetrating` true, which is not understood: the distances were plausible walls.
- **What it cannot say:** coyote time's length and the ledge grab's reach are not measured (the user named both); a
  backflip from a standstill is not tried.

### 2026-09-23 (autoplay, evening) — ledge grabs, climb poles, the float at a jump's top, coyote time, the slide, breakable walls

Same install. From the autoplay driver's flight recorder (every 3rd frame kept for minutes) over two runs the user played
from File 8 and over the driver's own attempts to repeat them.

- **A ledge grab is `moveState` 3**: she hangs still (horizontal and vertical speed 0) 6-21 frames in the user's runs;
  a Jump press then climbs (vertical speed ~860 at the start), and pushing toward the wall with it matters: taps with no
  stick left her hanging. The grabs recorded lifted her floor by 178-328 over the takeoff. A fence (the hall's side, the
  user) has no ledge: a backflip against it reached 265 and slid down with no grab.
- **A climb pole is `moveState` 5** while on it (the user's: at (12237, -1527), climbing at up to 650 a second) **and 6 at
  its top**, from where a Jump sets off (the user's rose 931, then a second jump at speed 600 toward the next floor). The
  driver's hop code only climbed in state 5 and stayed in state 6 until it jumped from there too.
- **Holding Jump through the top of a jump floats her**: the user's arc read vertical speed 36, 10, -27 over ~10 frames at
  its top; the driver letting go at the apex read 24 then -100 three frames later. At the 2349 ledge the user grabbed at
  z 2264; the let-go arc reached the same x at 2236-2255 and missed; held through the top, the grab worked.
- **Coyote time**: in the user's runs a jump came 6-9 frames after leaving the ground (sampled every 3rd frame) and still
  rose at 900+ a second -- the window is at least 9 frames.
- **The slide** (after the upgrade; "Press Left Trigger/Q Key on the ground to Slide", Q mapped to `IA_Crouch`): an injected
  Crouch while running gives `actionState` 1, the capsule's centre 43 lower, horizontal speed from 550 to ~1,160, easing back
  to a run over ~90 frames.
- **A breakable wall** (`BP_BreakableWall_C`) has its own `BP_HpHitable`: `maxHP` 100, about 7 per Dream Breaker hit (55 to 10
  over six swings); at 0 the actor is destroyed. The save crystal (`BP_SavePoint_C`) saves when struck, not by Interact:
  `Last Save Point Name` then named it and only File 8 changed.
- **What it cannot say:** the exact coyote window and grab reach; whether the camera's direction changes any move (the
  stick is recomputed from its yaw each frame, and no move measured differently for it).

### 2026-09-23 (autoplay, night) — the Keeper, a pit's cost, a bubble's boost, the castle's exits

Same install, File 8. From the flight recorder, which also recorded the Keeper beside her, and from reads by name.

- **The Keeper** (`BP_Enemy_Keeper_C`, spawned when she walks into its arena): `BP_HpHitable` 640 of 640. The user's win
  landed 42 hits of 15 over 96 s from 108-314 away (median 233); its attacks were short moves of ~0.1 s at 1000-1700,
  and its two 10-damage hits on the user came ~410 away as one ended. At 0 its HP read -20 and the key was free.
- **Breakable wall `_0`** (dungeon, 9150, -2900): `CurrentHp` 200, `maxHP` 40; swings and a slide left it at 200.
- **A pit fall costs 5 HP** and the game puts her back at a spot on the room's side (a jump of ~2000 in one sample).
- **A bubble** holds her at `moveState` 7; the stick did not move her in it; Jump with the stick held threw her at 700
  along it, rising then falling.
- **Exits** (`BP_TransitionZone_C`) name their far side in `startTag` (`Level Name` read None): the castle's `_7` at
  (6350, -11450) reads `libraryWest`, `_8` `theatreEast`, `_0` `theatreSouthEast`, `_4`/`_5`/`_6` `upper...`.
- **Reading every simple property on the Keeper by name crashed the game** in UE4SS; names alone (ForEachProperty) did not.

### 2026-10-02 — Facts the code comments carried, moved here word for word

Each fact below sat in a code comment beside the code that uses it (at `f64560cc`), and no entry above held it. On 2026-10-02 the comments were cut to what and why and the facts moved here word for word. Each names the probe, capture or date it was measured with where the comment did; none was re-measured for this entry. The label above each group is the file it came from, then the entry it was checked against.

**`autoplay/drivers/ue4ss/games/pseudoregalia.lua`**, checked against adapters/pseudoregalia/MEASURED.md, "2026-09-23 (night) — what marks talking, reading and sitting on the player", "2026-09-23 (autoplay, later) — how she moves: frame rate, the capsule, jump heights, the backflip, the save slot", "2026-09-23 (autoplay, evening) — ledge grabs, climb poles, the float at a jump's top, coyote time, the slide, breakable walls" and "2026-09-23 (autoplay, night) — the Keeper, a pit's cost, a bubble's boost, the castle's exits"

- AXES: the swinging axes (BP_HazardAxe_C), from the registry. Each swings +-45 degrees in the x-z plane about its pivot (the actor's position, 3250 over the axes' corridor floor at 2550); the long one's blade (Box) came down to ~2660 at the bottom of its arc, into a standing player (top 2682) and over a sliding one (~2596) (sampled 2026-09-23). A cell under one is where goto slides.
- DIALOGUE: a conversation's words are the game instance's UI_DialoguePrompt_C: `Text Bubbles` (every line, with the game's markup: `[3rr]` a pause, `[#cf2525](word)` a colour), `currentLine` (from 1), `writing` while a line prints, `canClose?` (an NPC conversation, 2026-09-23). Finished prompts linger until garbage collection (MEASURED.md, "what marks talking"), so the newest -- the lowest name number, the one created last -- is read, and only while controlState says she is reading or talking. A sign's words come from the sign itself (`things`).
- What she has: the pawn's own obtained/has flags (BP_PlayerGoatMain_C, read by name 2026-09-23: obtainedSlide? turned true with the slide's screen).
- The save is synchronous here (File 8 changed inside the call, 2026-09-23); wait a few frames for the OS anyway, and accept an unchanged file after 30 (nothing in the save changed since the last one).
- advance_text {every (default 45), max_taps (default 20)}: while the player reads or talks (`controlState` 1 or 2, the values an NPC conversation and a book gave, MEASURED.md 2026-09-23; a mirror gave 2 the same day), tap MenuAdvance for 4 frames every `every` frames. Ends `closed` once `controlState` is back to 0 for 10 frames, `not_reading` if it was 0 from the start, or `stuck` after max_taps with no close. An upgrade's screen (UI_NewUpgradePrompt_C) pauses the game and its CONTINUE answered neither a posted key nor an injected action; the widget's own bound click handler is what a click on it runs (the Dream Breaker and the slide, 2026-09-23). Returns the upgrade prompt when one is on screen.
- The slide (actionState 1, speed about 1100 for ~85 frames after a Crouch tap at a run, 2026-09-23): the capsule's centre drops from 2267 to 2224 over a floor at 2200, and CrouchedHalfHeight reads 20. Swept a little inside, as CAP_H.
- FLIPGRAB_UP: a backflip (peak 265 against a jump's 206) into a ledge grab: a jump grabbed ledges 80-94 over its apex, so a flip should catch ~350. The rises just past GRAB_UP (320-324) were the smallest the dungeon's full flood refused (2026-09-23). Executed as a flip; the hang handler climbs.
- Further, a leap lands only by catching the ledge: the user's grab hops rose 178 across 661 and 286 across 283.
- And, with the slide, the floor under a low beam: probed from above, the passage under the slide room's corridor read as the beam's top 150 up, its underside 100 over the real floor (2026-09-23).
- Too low to walk, low enough to slide: the slide's capsule (centre 24 over the floor, measured 2226-2224 from 2267 standing) swept at SLIDE_H. The passage under the slide room's corridor (2026-09-23) is one.
- A slide edge: a Crouch tap on the ground at a run starts the slide (actionState 1); tapped again only once it has ended, 4 frames each. Crouch held while standing still crouches her in place (moveState 2) and she does not move. Crouched (moveState 2) counts as on the ground: a slide that ends under the low ceiling leaves her crouched there. Under the swinging axes: slide through, as the corridor teaches -- walking, she was hit 5 at a time and knocked off the shelf (2026-09-23). Tapped when a cell up to 4 ahead is under one and she is within 200 of it.

**`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.hpp`**, checked against adapters/pseudoregalia/MEASURED.md, "2026-09-23 (autoplay, later) — how she moves: frame rate, the capsule, jump heights, the backflip, the save slot", "2026-09-23 (autoplay, night) — the Keeper, a pit's cost, a bubble's boost, the castle's exits" and "2026-10-02 — Facts the code comments carried, moved here word for word"; also documentation.md "Bubble", FLAGS.md `GHOST_HOLD_LIGHT_OFF`, VERIFIED.md 2026-08-13 (landed?/jumped? on animBPref) and UNVERIFIED.md "the ambient emitter off"

- **Has this ghost's ascendant light been turned down yet?** Per ghost, and it gates a FAST path rather than a log line: until it is true the light sweep runs every tick instead of every LIGHT_SWEEP_INTERVAL_TICKS. Measured 2026-08-29, and it is the whole bug: a ghost is born at Intensity 5000 and the interval sweep took ~1.5s to find it, because the light lives in a ChildActorComponent that does not exist at spawn. **A flash is enough.** The game latches its own dark-area state from the light level, so a second of 5000 leaves the room lit until the player walks out of the area and back in -- which is exactly what the user reported: the room brightening the instant a peer connected, from across the level, and staying that way.
- The tick this ghost was spawned on, for the short retry window in which its ambient particle emitter is looked for (the game attaches it at BeginPlay; measured present at spawn, retried a few ticks in case a build attaches it later).
- Landing/jump pulse mirror, redone 2026-08-13 (follow-up session). The first attempt at this (a plain bool, read/written on the PAWN) was a no-op on both ends: a real reflection dump (log_pawn_reflection_once) proved 'landed?'/'jumped?' exist ONLY on animBPref (the AnimBP instance, ABP_PlayerGoat_C), never on BP_PlayerGoatMain_C itself -- the pawn's only landing-related member is 'playerLanded?', a MulticastInlineDelegateProperty (an event, not a flag). Every prior TRACE local: line confirms it: landed=false jumped=false on every sample, including ticks where movementMode=3 (Falling). So the theory that the landing transition is gated on a one-shot AnimBP pulse the ghost never receives (its CharacterMovementComponent can never detect ground contact with collision disabled, so its own LandedDelegate/'landed?' pulse never fires) was never actually tested. This redo reads/writes animBPref->landed?/jumped? directly on both ends. It also switches from a bool to a monotonic counter, because a single-tick bool pulse is the wrong shape for this pipeline: Core.DefaultMinSendInterval (50ms) drops roughly 2 of every 3 frames from a ~60Hz game thread before the relay ever sees them, and remoteBuffer.lerp holds extras from the OLDER bracketing snapshot, so a snapshot renderTime steps over is never returned at all. A counter that only ever increases survives both: the receiver fires the one-shot on any observed increase over target_land_count/target_jump_count.
- Bubble post-jump "boost available" trail, 2026-08-15 (trigger C). The user reported the ghost animating correctly through the bubble but never trailing, and a bubble-only coverage capture found why: across 2002 ticks of that state the game sets `afterImagesToSpawn` to **zero every single tick**, so trigger A cannot see it and the capsule never shrinks, so trigger B can't either. It is the documented second spawn path. Unlike the slide there is no end-of-move tick count to bound: the state ends when the player presses jump (which they may do at any time) or lands, measured at 261-793 ticks across repetitions. So this re-fires for as long as the state is HELD, with no window cutoff -- the real player's trail lasts the whole time too. `moveState==7 && movementMode==5` is INSIDE the bubble (originally mislabelled as the post-jump window; corrected by the user's live three-way report, see the trigger's own comment). bubble_enter_tick bounds the in-bubble trail, because sitting in a bubble is player-terminated and can outlast the real trail, which the user watched happen.

**`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`**, checked against adapters/pseudoregalia/MEASURED.md, "Measured" (every entry) and "Not measured yet"; VERIFIED.md, UNVERIFIED.md and documentation.md searched too.

- Risk, stated plainly: a 48-byte parameter buffer whose layout we do not know, zero-filled. Same risk profile as call_do_wall_run, which worked -- but this one drives INPUT, so watch for a ghost that starts moving under its own power rather than merely posing.
- (a) **Ledge-grab pose lingers on the ghost after release** -- and NOT because of montages: LedgeGrab_Montage is 0.567s and the log shows it running to completion, with its mirrored stop landing 15-20ms after the local one. So the hang itself is a state-machine pose and the release is a state transition. This trace now logs the LOCAL state timeline and the GHOST's applied state side by side so the actual lag can be measured rather than guessed at -- this adapter's own pulse-hold logic being the first suspect.

**`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`**, checked against adapters/pseudoregalia/MEASURED.md, "Measured" (all seven 2026-09-23 entries) and "Not measured yet"; documentation.md, VERIFIED.md and UNVERIFIED.md searched too

- Off 2026-08-16 after the throw/save-crystal capture answered both open questions: the recall glow attaches to WeaponMesh (fixing its placement) and its trigger is now mirrored by observing the real effect rather than inferred. Left in place -- it is the tool for the next effect, and NS_WeaponPickup is already a known, un-reproduced candidate it found.
- Pre-stripping the pool cannot close it either. Afterimages are pooled and re-used, and the player's own still outline correctly after ours have been stripped -- which proves the game re-enables custom depth on each spawn rather than carrying it on the actor.
- Why it exists: the text renders pure black while the component demonstrably holds the right TextRenderColor -- confirmed by readback in two different colours, in a BRIGHT room, after a forced render-state rebuild, with the engine's own SetTextRenderColor having resolved and run. Every one of those addressed getting the colour INTO the component, and that half works. What has never been tested is whether the material it draws with uses that colour at all. EmissiveMeshMaterial takes its colour from vertex colour and is unlit, which is what a nametag wants anyway. The risk is that it does not sample the font texture, in which case the glyphs come out as solid blocks -- and THAT is still a useful result, because it would prove the vertex colour is reaching the mesh and the original material was ignoring it. TRIED AND REVERTED, kept as the record of what the answer is NOT. EmissiveMeshMaterial rendered a solid WHITE BOX: no glyphs (it does not sample the font texture) and no cyan (it did not pick up the colour either). That second half is the finding. The material was demonstrably in control of what appeared, and the vertex colour still did not reach it -- so TextRenderColor is not arriving as vertex colour on this build, and every attempt aimed at getting the value into the component was aimed at the wrong half.
- The three candidates tried for "a ghost's charged attack damages the player" are now two refuted and one dead: our `chg` VFX mirror was removed and the ghost still hit (refuted); the pawn's three damage numbers were zeroed and confirmed applied and the ghost still hit (refuted); and the hitbox disable came back this session with `'Hit Component 1' resolves but is NULL on the ghost` and `'CollisionComponent' does not resolve on this build` -- so there was never a hitbox component to disable and that line of attack is finished, not inconclusive.

**`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`**, checked against adapters/pseudoregalia/MEASURED.md, "Measured" (all seven entries) and "Not measured yet"

- **Slide pose, 2026-08-17: call the game's own slide function on the ghost.** Fourth application of the "trigger the pawn's own system" pattern, after call_spawn_num_afterimages, call_manage_recall_idle_fx and call_do_wall_run above. Why a CALL and not a property write, which is the whole story of this investigation: the diff-of-diffs (see GHOST_SLIDE_DIFF) showed a real player changes 19 pawn fields through a slide while its ghost changes 3 -- and the ghost already carries actionState==1, the one field that plausibly means "sliding", with its mesh still at the standing offset. Since the pose does not follow the state on a pawn that HAS the state, nothing tick-driven is reading it; the pose is written by event-driven code that fires when a slide starts. That cannot be reached by writing any property, which is exactly what the four failed attempts have been. Same zero-filled-buffer shape as call_do_wall_run: whatever PropertiesSize reports is Blueprint-internal temporaries on every function inspected in this file so far.

**`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`**, checked against adapters/pseudoregalia/MEASURED.md, "## Measured" (every 2026-09-23 entry) and "## Not measured yet"; also documentation.md, VERIFIED.md and FLAGS.md (`rec_indicator.txt` row)

- Defaults below were derived from the first screenshot rather than invented: the indicator sat at ~68% of the width and ~31% of the height with right/forward = 52/140 and up/forward = 30/140, which solves to a horizontal half-angle of tan ~1.03 and a vertical of ~0.563 -- a 16:9 frame at ~92 degrees horizontal, consistent, so the same solve puts the corner at right 88 and up 55.

**`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`**, checked against adapters/pseudoregalia/MEASURED.md, "## Measured" (every 2026-09-23 entry) and "## Not measured yet"; also documentation.md, VERIFIED.md, UNVERIFIED.md, FLAGS.md and agent_docs/chaser-planning.md

- 38 units DOWN from the sword's actor origin to the floor it is embedded in -- measured, not guessed: every landed sword in the 16:49 capture sat at z=-761..-766 over the -800 floor. At the origin itself the ring hovered ("a bit too high above the sword", user 2026-09-01).
- **Was 3, and 3 was wrong** (2026-08-16). At that delay the probe reported "0 new objects" every time and concluded afterimages were pooled -- the exact opposite of the truth. The give-away was in its own output: the total object count rose by exactly 2 between one probe and the next (1460 -> 1462 -> 1464 ...), so each call was demonstrably creating two objects that simply had not appeared yet 3 ticks in, and then persisted. A negative result from a sampling window that is too narrow looks identical to a real negative, which is worth remembering: the counts, not the diff, are what caught it.
- **Decode the ubergraph's own EntryPoint and Attacker, every time -- unconditional on the de-dup below, since this IS the "watch a real hit" instrument the 2026-09-18 session needed.** Three BPI_* interface calls (`BPI_PerformDamageResponse`, `BPI_ContactDamageResponse`, `BPI_CombatDeath`) each did nothing when called directly with `Attacker`/`incomingHitboxInfo` left at their null defaults -- the dump named EntryPoint and two same-named `Attacker` parameters (`K2Node_Event_Attacker`/`_1`, one per merged interface) as exactly the fields that would explain it. Read here from the FUNCTION's own reflected offsets (never assumed), against the real `params` buffer this hook receives -- the same "named reads only" shape as `probes/probe_dump/`, just off a stack buffer instead of an object.

**`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`**, checked against adapters/pseudoregalia/MEASURED.md, "## Measured" (every 2026-09-23 entry, including "how an enemy hurts the player: `BPI_TryDamage` and `ST_HitboxData`") and "## Not measured yet"

- **And the objects that actually carry scene brightness.** The pawn and the shared singleton both came back with nothing but uptime timers, which is a real negative -- so the next place to look is whatever holds the level's own post-process. The scene census named it: one unbound `PostProcessComponent` on `BP_Ambience_C_1`, blending at weight 1 over the whole level. Its knobs live inside a struct, hence include_structs.
- **The `BP_HpHitable` function vocabulary, once. Armed by `dump_hphitable.txt`, 2026-09-18.** `log_damage_fns.txt` (above) proved nothing NAMED damage/hurt/hp/ health/kill/die/dead is ever called on it through ProcessEvent -- only the compiled ubergraph itself runs. So this asks the class what it OFFERS instead of guessing another name to watch for: every property and every function with its parameter types, through the proven `census_named_fields` walker (named reads and reflected metadata only, the safe shape -- `probes/probe_dump/`'s method, not a blind walk). One-shot: it costs a class-chain walk, so it runs once and disarms itself.

**`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`**, checked against adapters/pseudoregalia/MEASURED.md, every entry in "## Measured" (none is about afterimages) and "## Not measured yet" (empty); also documentation.md, "The afterimage trail" (holds the pooling, not the opacity Timeline fade or its GUID-suffixed name)

- Creation parity is now measured and exact (40 vs 40), so counting bodies says nothing more. What a person sees is how many are VISIBLE at an instant, and these actors fade themselves via a Timeline (`Timeline_0_opacity` in the schema dump) rather than being destroyed -- which is also why the pool only ever grows. So this counts images that are actually opaque enough to see, alongside the raw bodies. The property name carries a Blueprint-compile GUID suffix, so it is found by PREFIX rather than by the exact name from one dump -- an exact name would be a value copied from a single observation, and would silently read nothing on any other build of the game.

**`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`**, checked against adapters/pseudoregalia/MEASURED.md, "Measured" (all seven 2026-09-23 entries) and "Not measured yet"

- The render flags, because a blob shadow is very often an INVISIBLE mesh that still casts -- and the census found this one `hiddenInGame=true` on the player too, where the shadow is correct. That combination only makes sense if the shadow is what this mesh is for, so whether it casts is load-bearing.
- One reflected call: the pawn and the action in, three doubles out. The type byte after them is not read -- a bool action carries 1.0 in X and an Axis2D its two components, which is all the track needs (Conv_InputActionValueToBool/Axis2D read the same vector).

**`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`**, checked against adapters/pseudoregalia/MEASURED.md, "Measured" (an adapter cost or timing no entry held)

- Cost: `live()` is a pass over ~400 weak pointers (a serial compare each), microseconds; the belt is one walk per 600 ticks per registry. Behaviour: the same objects the walk returned, at the same cadences, so every consumer's logic is untouched.
- Wire key. Short on purpose: extras are capped at MaxExtrasBytes = 1024 and this block measured ~689 bytes worst case before this field existed.
- **Pooled actors HELD between samples since 2026-09-01 -- same precondition story as find_local_controller_and_pawn (see its comment): the reliable new-world signal exists, and release_all_ghosts clears this pool at LoadMap PRE, InitGameState PRE and the Reset click, before any teardown frees the actors. The game pools and re-uses these (established -- it is why a spent shot keeps existing), so within one world the list only grows; discovery of a slot no scan has seen waits at most PROJECTILE_RESCAN_INTERVAL_TICKS, and an empty pool re-scans at the RESCAN interval like everything else -- the first version re-scanned an empty pool at the SAMPLE cadence "so the first shot is not delayed", which meant the common case (a session where nobody fires) paid the full pre-cache cost forever: the 2026-09-01 baseline showed ls_projectile at 577 us/frame with zero shots ever fired. A first shot discovered up to PROJECTILE_RESCAN_INTERVAL_TICKS (~0.2s) late is invisible; 577 us of every frame is not. The fresh scan this replaces cost ~1.2 ms/frame.
- Thrown Dream Breaker -- see the local read above. Only the flag is always present; the class path and transform are sent as fixed one-decimal values (0.1 Unreal units is well under a visible difference) specifically to bound this block's size, since agent_docs/contract.md caps extras at MaxExtrasBytes = 1024 and an unbounded double can print 17 significant digits. Measured worst case with this block: ~689 bytes.
- **A dormant ghost keeps its nametag, and the tag keeps following the peer (the user's call, 2026-09-06: *"seeing the vfx/nametag so someone actually know a player is over there is fine gameplay wise"*).** The tag hangs off the hidden actor, so the actor still gets its location write -- one engine call, ~25 us -- and the tag its update; everything else a ghost costs (pose, mirrors, holds, sweeps) is skipped until it wakes.
- **The other half: components attached to the ghost at RUNTIME.** Attributed by name containment, the same test VFX_WATCH uses -- a component's full name carries its outer chain, so anything living under this ghost's instance is ours to strip. This is what covers an attack's own mesh, which no property walk can see. **Walks THIS GHOST'S attach tree, not the level.** It used to ask UObjectGlobals for every SkeletalMeshComponent and StaticMeshComponent in the world and then run a name-chain property lookup plus a full-name string build on each one, every 5th frame, per ghost. Measured 2026-08-30: ~3.8 ms/frame amortised, i.e. roughly 19 ms every time it fired, for a sweep that `../../adapters/pseudoregalia/FLAGS.md` records as having NEVER ONCE found custom depth on -- it is the belt to the SetRenderCustomDepth pre-hook's braces. The attach tree reaches the same components for the same reason the old name test worked: a runtime-attached mesh (an attack's own mesh, a child actor's parts) hangs under this actor's root. Attribution is now structural rather than by string containment, so the name test is gone with the scan -- anything the walk reaches is ours by construction.
- **Every tick until this ghost's light has actually been turned down, then back to the interval.** The interval alone left a ~1.5s window at 5000 (measured), and the window is the bug rather than a cosmetic delay: the game latches its dark-area state off the light level, so one bright second lights the room until the player leaves the area and returns. The fast path costs one small class-scoped FindAllOf per tick and only until the light is found -- the light lives in a ChildActorComponent that does not exist at spawn, which is why a spawn-time write cannot replace this. **Per tick, always -- `light_zeroed` no longer buys an interval.** It used to mean "found it once, slow down", which assumed the game writes 5000 exactly once at birth. If instead the ghost's own logic re-lights it every frame, a 30-tick sweep leaves it LIT for 29 of every 30 -- and the log stays silent, because the announce fires once per component. The user reporting a ghost that still glows while every readback says 0 is precisely that shape (2026-08-29). The flag now drives the COUNTER instead: the first zero is the announcement, and any later one means the game put the light back, which is a fact about this game worth having rather than something to quietly undo.

## Not measured yet

&lt;None yet.&gt;
