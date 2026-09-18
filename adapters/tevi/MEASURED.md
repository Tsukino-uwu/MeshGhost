# Measured — TEVI

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

Sibling records: [Pokémon Emerald](../emulator/pokemon/emerald/MEASURED.md), [Pokémon Crystal](../emulator/pokemon/crystal/MEASURED.md), [Pseudoregalia](../pseudoregalia/MEASURED.md).

**Older code-level entries still sit in `UNVERIFIED.md` and `VERIFIED.md`**: sorting them into
this file is a queued task (`agent_docs/status.md`, 2026-09-16). Until it runs, look there too.

**Keep the `## Index` section below, one line per `###` entry in either section.** This file only
grows, like `VERIFIED.md`, so the index is what keeps it findable.

## Index

- 2026-09-17 — Where the saves live, what a slot's file is, and what the last autosave wrote
- 2026-09-17 — The save list's cursor, and a new game started through it by injected input
- 2026-09-17 — Under ScriptEngine a plugin's `Info.Location` is empty
- 2026-09-17 — The Randomizer turns Custom Game options on by itself
- 2026-09-17 — A new game reads its slot back from `tevisystem.sav`; a vanilla Cakewalk new game in slot 39
- 2026-09-17 — A dialogue's lines, and input while the window is unfocused
- 2026-09-17 — The collision grid, the camera's view and the map's elements, against a picture of the cell
- 2026-09-17 — Teleport, restore and the cell's right wall
- 2026-09-17 — Hits and kills go through one method; what a hit on Cakewalk costs
- 2026-09-17 — The instruction banner, the item box and a tutorial window, as text
- 2026-09-17 — A restore lets outside input in again; a teleport into a new room starts an autosave
- 2026-09-17 — Jump height by how long Jump is held (partial)
- 2026-09-17 — A trail of a jump: run speed, a ceiling that caps the arc, and a pass-through platform
- 2026-09-17 — Fighting at game speed: the fight reflex against five kinds, and blastorbs
- 2026-09-17 — The interaction bubble, the bottom-left popup and the menu's tabs, read
- 2026-09-17 — Into the Sewerways: a grate that broke on a falling quickdrop, the move list, and the first save point
- 2026-09-17 — Holding the clock: what a timeScale of 0 stops, stepping, and input while held
- 2026-09-17 — The game's hitbox drawing in a frame capture, and what the flight recorder costs
- 2026-09-17 — Jump arcs by hold, the quickdrop, the player's hurtbox and her ground swing
- 2026-09-17 — Ribauld's attacks: lasers, blastorbs, the arena's edges, and the states before each attack
- 2026-09-17 — Fighting Ribauld with the dodge: hits per try
- 2026-09-17 — Infernal BBQ: what a normal enemy's hit costs, a death, and the play time to the first save point
- 2026-09-17 — Ribauld on Infernal BBQ: his HP, the laser curtain's warning, thrown orbs, and what makes a quickdrop a double jump
- 2026-09-17 — Achievements: what TEVI calls to unlock one, and a load re-applying them
- Not measured yet — backup slots and the chapter-reset slot
- Not measured yet — what `mode: paused` reads from, and why the pause menu opened

## Measured

### 2026-09-17 — Where the saves live, what a slot's file is, and what the last autosave wrote

**Evidence** (autoplay's Phase 6, `agent_docs/phases/autoplay/tevi.md`): a listing of the save folder; the system
and settings files decompressed in memory (read, never written); `Player.log` from the 2026-09-12 session; both
installs' Unity player info file (`TEVI_Data\app` with the `.info` extension). On the Steam build (`Assembly-CSharp.dll` sha256 `ca07d121...`) and the standalone
build 14778703.

- **Both installs save to one folder**: each build's player info file names `CreSpirit` and `TEVI`, and the folder is
  `%USERPROFILE%\AppData\LocalLow\CreSpirit\TEVI`. A save either install writes, the other reads.
- **A slot is `tevisave<N>.sav`**, a gzip stream (bytes `1f 8b`) of Easy Save 3 JSON, one `{"__type", "value"}`
  object per key (`EXP`, `Resource`, ...). The same folder holds `tevisystem.sav` (keys `recentSaveSlot`,
  `recentMSave`, `backupSaveSlot`, the achievements) and `tevisetting` (`S_*` settings), both gzip JSON too, and
  `tevisigil.sav`. The Randomizer's games are `randomizer\rando.tevisave<N>.sav`, with its `settings.tevi`.
- **An autosave wrote slot 0**: `Player.log`, 2026-09-12, reads `Prepared to auto save.`, then `Game Saved to Save
  Slot 0 | Filename : tevisave0.sav`, `Save recent manual save slot : 0`, `Auto saved.`
- The files on 2026-09-17: slots 0-4, 6, 7, 69 and 80-100; `tevisetting` `S_SYSTEM_AUTOSAVESLOT` 10 and
  `S_SYSTEM_AUTOSAVETIME_SLIDE` 15; `tevisystem.sav` `backupSaveSlot` 93, `recentSaveSlot` 0, `recentMSave` 6.
- **Not seen**: a backup slot being written, or which one (see Not measured yet).

### 2026-09-17 — The save list's cursor, and a new game started through it by injected input

**Evidence**: autoplay's TEVI driver on the Steam build, `observe` reading `HUDSaveMenu.Instance`'s `page` and
`selected` beside screenshots of the same moments, presses through the driver's Rewired injection, one autoplay session.

- **The list is 4 rows a page, and the drawn number is page times 4 plus the row**: page 9, row 3 read slot 39, and
  the picture showed the row "39" highlighted.
- **A 3-frame `XAxis+` hold moves one page right**, eight holds eight pages; **a 3-frame `YAxis-` hold moves one row
  down** (36 to 37 to 38 to 39).
- **The Rewired actions** (`ReInput.mapping.Actions`, at the title): 0 `XAxis` and 1 `YAxis` (axes); buttons 2
  `Jump`, 3 `Ranged`, 4 `Attack`, 5 `Dash`, 6 `Boost`, 7 `LB`, 8 `RB`, 9 `Start`, 10 `Bag`, 11 `ButtonPadX`, 12
  `ButtonPadY`, 13 `Confirm`, 14 `Back`, 15 `Map`, 16 `DefaultX`, 17 `DefaultY`, 18 `Badge`, 19 `Craft`, 21 `Item`,
  22 `Character`, 23 `PageL`, 24 `PageR`, 25 `Notebook`, 26 `Burst`, 27 `Backflip`, 28 `AreaBomb`, 29 `Taunt`.
- **Confirm on an empty slot at the title opens Custom Game**, where `XAxis+` moved the highlight to "Confirm &
  Continue" and Confirm opened the difficulty screen, Normal highlighted by default; Confirm there started the game:
  `mode` title, `no_world` (61 frames after the press), `loading`, `play` (184 frames after it), a second
  `loading`/`play` one frame apart as the room became 5,8, then area `OASISHOME` (area id 1). The player stood at
  x 6984.78, y -6776.0, facing `RIGHT`, clip `stand`, HP 100 of 100.
- `MainVar.instance._saveslot` read 39 on the Custom Game screen and 0 once in the game.

### 2026-09-17 — Under ScriptEngine a plugin's `Info.Location` is empty

**Evidence**: `BepInEx\LogOutput.log` on the Steam install. autoplay's driver built its config path from
`Info.Location` and logged `no .\meshghost-autoplay.txt` though the file sat beside the DLL in `scripts\`; the dev
cheats' own load line reads `Toggle file: .\meshghost-devcheats.txt`, and with a toggle file in `scripts\` they kept
logging all five on until the file was moved to the game's root folder, when they logged
`hp=False mp=False charge=False crystal=False swap=False`.

- A path built from a ScriptEngine-loaded plugin's location lands in the process's working folder, the game root.
  `Paths.BepInExRootPath` gives the install's BepInEx folder instead (what the autoplay driver uses since).

### 2026-09-17 — The Randomizer turns Custom Game options on by itself

**Evidence**: the Steam build with `Tevi Randomizer` 1.6.1 loaded and switched on; a new game started with none of
the twelve options ticked ("Custom Selected : 0/12" on screen); then `SaveManager.GetCustomGame` asked for each value
by the driver, and the corner text drawn during the fade-in.

- The running save answered `SpeedRun`, `FreeRoam`, `TurboMode` and `WeaponMastery`, and the fade-in drew those four
  names. The mod's `GemaNewGame.OnEnable` prefix sets the first two (read in its installed DLL, MIT-licensed); where the other two come
  from is not traced.

### 2026-09-17 — A new game reads its slot back from `tevisystem.sav`; a vanilla Cakewalk new game in slot 39

**Evidence**: the game's own `Player.log` for two starts on the Steam build with the Randomizer disabled, and autoplay's
driver (`observe`, events) around them, the same session.

- **Starting a new game writes the recent-slot pointer, then reads it back from the file**: `[GemaNewGame] Try to start game
  at saveslot 39`, `Save recent manual save slot : 39` twice, then after the scene reload `Load recent auto or manual save
  slot : <N>` and the load of slot N. With both pointer writes refused (the first save guard), N read 0 and `Loaded Save Slot
  0.` put the player's autosave on screen (HP 1009, 22,650 coins). With them written to a shadow copy, N read 39 and `Save
  File Slot 39 do not exist. Trying to start New Game` began the intro.
- **The title's menus**, read through `GemaTitleScreenManager`: the main menu `Start`, `Contents`, `Gallery`, `Options`,
  `About`, `Exit`; Custom Game's twelve options and `Confirm & Continue`, four of them drawn `? ? ?` without the Randomizer;
  the difficulty list `Cakewalk`, `Picnic`, `Normal`, `Hard`, `Expert`, `Infernal BBQ`, opening on `Normal` (cursor 2).
  `YAxis+` moves that cursor up; two presses reached `Cakewalk`, and the game logged `Diffiuclty : 0` for it (3 for Normal).
- **The intro**: `mode` `event` in area `INTRO_ROOM` (area id 48), room 14,3, x 19152.0, y -2912.0, facing `RIGHT`, HP 100
  of 100, no Custom Game option on, the save's slot 39; the screen black with the story's first line of text.

### 2026-09-17 — A dialogue's lines, and input while the window is unfocused

**Evidence**: autoplay's driver reading `ChatSystem.Instance` (`getStatus`, the private `CurrentSection`, `CurrentLine`,
`chatdb`, `TargetText`, `text_prefer`, `autovoiceadvance`) through the intro of the Cakewalk game above, in 180-frame
waits; `ReInput.configuration.ignoreInputWhenAppNotInFocus` and `Application.isFocused`; the user's report.

- **While a conversation is open `getStatus()` reads `OPEN`, and the driver's `mode` reads `paused`** (`GameSystem.isAnyPause()`
  is true); between conversations of the intro, `mode` read `event`. The lines came in order: `chapter0_opening3` lines 3-6
  of 7 (speaker ids `Ribauld`, then `Tevi!`), `chapter0_opening4` lines 0-2 of 3, `chapter0_opening5` lines 0-2 of 3;
  `TargetText` held the whole line with its colour tags, and the text drawn matched its length once printed. The game's own
  prompt bar names Next, Fast-forward, Auto, Log and Skip.
- **Auto**: after a 3-frame `ButtonPadX` press, line 4 still read `autovoiceadvance` false 27 seconds on; from line 5 it read
  true and lines advanced with no injected input. The user was typing in another window around then, which that unfocused
  TEVI took as input (below), so what turned Auto on is not settled. With no input and Auto off, a line waited 600 frames
  unchanged.
- **Input while unfocused**: `ignoreInputWhenAppNotInFocus` read true and `Application.isFocused` false. The user: TEVI started
  by Steam while another window had focus took typing and mouse input from that window (the intro advanced; earlier the pause
  menu opened on its Notebook tab), until the TEVI window had been clicked once and left; after that it ignored input while
  unfocused. Not measured: which input reached it before that first focus.

### 2026-09-17 — The collision grid, the camera's view and the map's elements, against a picture of the cell

**Evidence**: autoplay's driver `observe` beside a screenshot of the same moment in the Bandit Base cell (area `BASE`, room
12,11), the player at x 16688, y -9072.

- **The camera's view** (`CameraScript.GetEdgeLeft/Right/Top/Bottom`): 16048 to 17328 and -8564 to -9284, 1280 by 720 world
  units for the 1280 by 720 picture, the player's x at the centre. So a screen pixel is a world unit here.
- **The grid** (`areadata.hitbox`, 56-unit tiles, a tile `x / 56` and `-y / 56 + 1` as the game's wall test computes it), with
  each boundary converted from the picture: the cell's left wall's inner edge falls on the boundary of tiles 291 and 292, the
  right wall's on 304 and 305, the floor's top on rows 163 and 164, the ceiling's inside on rows 156 and 157 -- each a change
  from byte 1 to byte 0 in the grid. The tall bookshelf's top is byte 255 over tiles 292-294 of row 161 and the short one's
  over 295-296 of row 162, each within a few pixels of the drawn shelves: byte 255 is a platform stood on from above.
- **The player's `t.position` is 57 units above the drawn feet**: y -9072 is the top of tile row 163, and the feet are drawn
  on the floor at row 164's top.
- **The elements in view** included 9 `B_BOMB_CHAIN` along row 163 from tile 305 (inside the right wall), and markers
  `MAPOBJECT0`/`12`, `FadeFrontLayerTo0_1x2`, `ID1` and a `MapPoint`. **The one active bullet** was the player's own, type
  `BREAK_STAND`, 58 units below its position. No other character.

### 2026-09-17 — Teleport, restore and the cell's right wall

**Evidence**: autoplay's driver in the cell above, the same session, and the tracked scenario
`autoplay/games/tevi/scenarios/cell_right_wall.json` run twice: 3 of 3 passed, and a deliberately broken copy failed.

- **A snapshot** is `SaveManager.SaveGame` with the slot set to 39, which stores the area and the player's x and y: 3,924
  bytes, written into the save guard's shadow. **A restore** copies it back, sets the recent slot and calls
  `SaveManager.ReloadToGame`: play resumed 88 frames later with the player back at x 16688, but with the area reading `NONE`
  and the camera's view elsewhere; waiting also for the area and for the camera to hold the player took 138 frames; then the
  fade-in: its alpha 0.492 at the first `observe` after, falling each 12 frames through 0.35, 0.249 ... 0.016 to 0 about 132
  frames later.
  With the fade too, a restore took 272 frames. Two restores in a row both returned the player to x 16688.
- **A teleport** (the transform set, the velocity zeroed) read back 10 frames later: 16688 to 16912 held in play; one made 11
  frames after a restore had answered (inside the fade, by the later restore's curve; its alpha then was not read) read 16688
  again, and one made once the fade was 0 held. One of each: the fade and the load's own timing are not told apart.
- **The cell's right wall**: from x 16912, 60 frames of `XAxis+` took the player to x 17066 and stopped it (the wall's inner
  edge at 17080, 14 short), and 60 more moved it nothing; the same three runs of the scenario each read it again.

### 2026-09-17 — Hits and kills go through one method; what a hit on Cakewalk costs

**Evidence**: autoplay's TEVI driver on the Steam build, a prefix and postfix on `CharacterBase.BulletHurtPlayer` (named from the
assembly; the decompilation read as a map showed every hit on a character calling it) and a per-frame read of the player's
`health`, through the Cakewalk game walked out of the cell (walked, one autoplay session).

- **A hit on the player**: `GH_Member_Cat` (35 HP) twice, `damage_taken` with `bullet_type` `ENEMY_HURTBOX` (contact, the cat 25.7
  units off) and `INVISIBLE` (its attack, 67.4 off), each 1 HP (`final_damage_raw` 1), `logic` `PLAYERDAMAGE`; the per-frame read
  saw each on the same frame. `GH_Member_Mouse` (30 HP) and `GH_Member_Dog` (28 HP, contact) the same, 1 HP each.
- **A kill**: the dog's HP taken to 0 by the method's call with `bullet_type` `TEVI_GROUND_COMBO_ATTACK` and the player as owner,
  66 frames into a combo of Attack taps every 10 frames; it left `nearby` at once. The cat went from 35 to 24 with four taps.
- **Hits the player lands on an enemy never reported as the player's**: none of the cat's 11 HP lost read as `damage_taken`.
- **Not seen**: a hit that does no damage (blocked, godmode) or a death; HP lost from buffs, falls or scripts, which the method
  does not carry and only the per-frame read would see. While TEVI sat idle between calls, the cat took 20 HP 1 at a time.

### 2026-09-17 — The instruction banner, the item box and a tutorial window, as text

**Evidence**: the same driver and session; `ControlTips.Instance` (private `lastkeyword`, `text`, `targetalpha`),
`HUDObtainedItem.Instance` (`isDisplaying`, private `gotitem`, `itemname`, `itemdesc`) and every active `TMP_Text`, beside
screenshots of the same moments (the upper corridor, a switch hit, a slope, up-right, after the dagger).

- **The banner**: walking from the cell drew, in turn, the quickdrop line ("Hold ... + [Z] while in the air to quickdrop, which can
  break locked ventilation ducts"), "When a bubble prompt appears, press ... to interact", "Press [X] for ranged orbitar attacks,
  [C] for melee attacks", and `Tips.MaintainDistance_LONG`, "Avoid contact damage by keeping distance from enemies".
- **The keyword changes before the text**: the first read of `Tips.MaintainDistance_LONG` had alpha 0.012 and the orbitar line's
  text; at alpha 0.764 the text was its own. The driver reports a banner once past alpha 0.5.
- **The item box**: Dagger ("A sharp, trusty dagger. Allows for use of melee attacks.") then Orbitars, each closed by Confirm;
  `mode` read `paused` while each was up.
- **A tutorial window** ("Basic Engagement", closed by Confirm) is none of those: its words read from `TMP_Text` objects named
  `Help Desc` and `Help Exit`. Its own class is not found yet.

### 2026-09-17 — A restore lets outside input in again; a teleport into a new room starts an autosave

**Evidence**: the user; the driver's `extras.input_focus` and its own log, same session.

- After a `restore` (`SaveManager.ReloadToGame`), the pause menu opened on its Items tab during a 19-frame hold of `XAxis+`, closed,
  and opened again. The user: *"its grabbing inputs from outside the game when a save is reloaded i think ? i need to manually press
  the game and focus it, then unfocus. and then it will stop reading inputs again"*. `application_focused_raw` read false.
- With the driver dropping real input while unfocused (`real_input_muted` true), a `restore` of a snapshot at the first enemy, a
  100-frame `sequence` and 300 frames with no input read `mode` `play` and `any_pause_raw` false throughout. Whether any
  outside input was typed during it is not known, so this shows no leak, not that one was stopped.
- A teleport from the cell (room 12,11) to x 17800 (room 13,11) logged `HELD an autosave (SaveManager.ReallyDoAutoSave skipped)`
  one frame before the teleport's answer.

### 2026-09-17 — Jump height by how long Jump is held (partial)

**Evidence**: the driver's `press` and `sequence` answers in the same session. The user: *"you should be able to jump short/high
depending on how long the jump button is held"*.

- From standing on flat floor: Jump held 15 frames rose from y -9072 to -8896.5 (175.5 units) by its last frame; held 16 frames,
  it reached a pass-through platform 112 above, and held 14 frames three times 45 frames apart, three stacked 112 apart.
- Held 26 frames with `XAxis-`, it landed on a block 168 above; held 11 frames with `XAxis-` from a slope, on a platform 154 above.
- **Not measured**: the rise per frame of hold, the shortest hop, or the highest jump.

### 2026-09-17 — A trail of a jump: run speed, a ceiling that caps the arc, and a pass-through platform

**Evidence**: autoplay's TEVI driver recording the player's position every frame (`observe`'s `trail`), in Bandit Base below the
second ventilation duct, the session walked out of the cell. The user, watching: *"think you hit
your head at the roof/celing"* and *"try to jump below the platform/just a bit to the side of the platform"*.

- **Running moves 6.33 units a frame** (19 units every 3 frames, level and on the slope alike); the slope there drops 1 unit
  for 1.
- **A ceiling caps a jump**: from y -9072, holds of 5 and of 9 frames both peaked at y -8968 and fell from there; in the air 33
  frames, they came down 212 units along. Holds of 16 and 30 frames did no better.
- **A platform stood on from above (tile byte 255) is jumped up through**: from the slope 150 units below it and just to its
  side, an 18-frame hold of Jump with left held from its 10th frame rose through its edge, peaked 38 units above, and landed on it.
- Not measured: the height of the ceiling itself, or the player's collision box.

### 2026-09-17 — Fighting at game speed: the fight reflex against five kinds, and blastorbs

**Evidence**: the driver's `reflex` `fight` (each frame: face the nearest enemy, hold toward it outside 110 units, tap Attack
inside it, jump or shoot when it is above), its answers and events, the same session; `observe`'s `nearby` and
`projectiles`; a screenshot of the blastvines. The user: *"these
things are bombs you can attack/push towards things to break them, not enemies"* and, of the Clean Staff, *"you can't reach that
enemy from here / with your current items"*.

- **Defeated** on Cakewalk: `GH_Member_Mouse` (30 HP) twice, 130 and 136 frames, 1 hit taken each; `GH_Member_Dog` (28 HP) 126
  frames, 1 hit; `GH_Member_Cat` (35 HP) 99 frames, none; `GH_Bot` (34 HP) 133 frames, none. The four after a fix to how taps were counted took 14 to 17 taps of Attack each.
- **Out of reach**: `GH_CleanStaff` (59 HP) on a ledge 224 units above the floor, behind a wall; 28 jumps into the wall over
  1200 frames, until the reflex was changed to end `unreachable` after 45 frames not moving with its target more than 180 above
  where she stood (it then ended in 44 frames).
- **Blastorbs**: `EnergyBall` characters on the blastvines read `isCharacterEnemy` true, HP 99999 of 99999, with bullets
  `ENEMY_HURTBOX` and `BODYBOX` of their own. Three Attack taps on one on the floor drew "3 HITS!", a 6 and a bar under it and moved
  it from x 10052 to 10126, then to 10246; 150 frames on it had not burst. Tevi's lines on meeting them (`chapter0_point2`):
  "Blastvines?", "I'm sure these blastorbs will come in handy." What they break was not seen.
- **Shoot-chain blocks** (`B_SHOOT_CHAIN`) at the slope's top: ten Orbitar taps, a 30-frame Orbitar hold and three melee taps
  against them left them whole.

### 2026-09-17 — The interaction bubble, the bottom-left popup and the menu's tabs, read

**Evidence**: the driver reading `EnterTips.Instance` (active, a private `fadeout` above 0, its sprite against the private
`entersprite`, `talksprite`, `actionsprite`), `HUDPopupMessage.Instance` (private `timer`, `targetTitleText`, `targetPopupText`)
and every `TMP_Text`; screenshots of the menu and the sigils; the same session. The user: *"there will
be an icon above the player head, when you can use the up arrow to interact with things"*.

- **The bubble**: walking to the artifact room's red switch, `interact` read `action` from the frame she stood beside it (a
  `sequence` stopped on `interact_changed` there); Up then ran the scene that opened the floor hatch. A door drawn in the tall
  room by the Clean Staff gave no bubble.
- **The bottom-left popup** (a new ability and its use) came and went during a 240-frame run before it was read; the driver has
  read it since, not yet seen with a message up.
- **The pause menu** opened on Characters, and PageR went Items, Sigils, Map, Characters. Characters lists each move with its
  input and a description ("Starting jump height is 3 tiles. Hold jump to reach full height, tap jump to perform a smaller jump").
  On Sigils, `YAxis-` moved to Palladium (cost 3) and Confirm read it `Equipped`, EP used 3 of 10.
- **Items picked up**: the Astral Gear (`STACKABLE_COG`, the artifact) and Palladium (`BADGE_ANTIENERGYBALL`: "All damage taken
  -2, damage taken from blastorbs -50%"), each through the item box and closed by Confirm.

### 2026-09-17 — Into the Sewerways: a grate that broke on a falling quickdrop, the move list, and the first save point

**Evidence**: the same driver and session, `trail`, `screen_text`, `menu`, `save.guard`, and screenshots down the shaft,
of the map and toward the save point; the real save folder hashed against its
backup afterwards. The user: *"normal enemies are never required to defeat, only bosses"*, and *"you can equip sigils directly when
picking them up, without having to go to the menu. if you have enought EP to do so"* (not tried yet).

- **A duct grate over a shaft** (Bandit Base, x about 12935-13045) held against two quickdrops begun while rising (Jump held 14
  and 16 frames, down + Jump pressed 4 frames after the hold ended), each falling about 22 units a frame and drifting up to 45
  forward; it broke on a third begun after the peak (Jump held 22 frames, down + Jump from 8 frames after), with no drift, and
  the player fell into area `SEWER`. One of each: whether the timing or the drift decided it is not told apart.
- **The move list** (pause menu, Characters, the cursor walked down with `YAxis-` and each move's detail read): 26 rows, wrapping;
  known so far Jump, Quickdrop ("Contact with a target during quickdrop will negate contact damage and perform 1 additional
  bounce"), Basic Ground Combo I-III (`[C]`, `[C][C]`, `[C][C][C]`), Upper Slash (Up + `[C]`, "Rise into the air while performing a
  multi-stage attack"; the bottom-left popup had announced it, unread) and Basic Air Combo I-III; the rest `???`. `screen_text`
  missed rows until its caps were raised to 150 entries and 1500 characters.
- **More fights**: two Clean Staffs (59 HP) in 263 and 315 frames; a bat (17 HP, flying) in 52; mice (22 HP, the sewer's) in 45 and
  109; `GH_Member_Mouse` (60 HP) in 195; `GH_Member_Cat` (70 HP) in 192; `GH_Bot` twice. A `GH_Member_Dog` 232 units below, under a
  floor, took 137 Orbitar shots over 900 frames and lost no HP; the reflex now ends `no_progress` after 300 frames of that.
- **The save point** (x about 20690, y -12880, a green glow): standing on it drew `Tips.SavePoint` ("Save points can fully recover
  HP. Press ... to save game progress"). Up raised HP one point a frame from 53 to 67 and opened the save list with `purpose`
  `save` and the cursor on slot 39; Confirm asked "Save game?", Confirm again saved and HP read 100. The guard: 42 paths
  shadowed, 0 writes refused, 210 autosaves held. The real save folder: 57 files, every hash equal to the backup.
- **Sigils**: Knives Out (`BADGE_Normal2AntiHealth`, cost 4: "When target's HP is above 70%, basic ground combo damage +2")
  equipped from the Sigils tab, EP 7 of 10; Biscuit Delivery (cost 0) also on.

### 2026-09-17 — Holding the clock: what a timeScale of 0 stops, stepping, and input while held

**Evidence**: autoplay's driver with a postfix on `GameSystem.TimeScale` (which sets `Time.timeScale` every frame: 0 while paused or in
the game's own short stops, the game speed otherwise; read as a map) setting 0 while the clock is held; `observe`'s `trail`, the same session,
at the Sewerways' save point room, the player jumping in place.

- **Held, the player stops mid-air**: 8 frames into a jump she stayed at y -12857.4 for 150 frames, `Time.timeScale` reading 0 each.
- **Input while held moves nothing and is not kept**: 30 frames of `XAxis+` and an `Attack` tap while held, then a step, showed
  neither a move nor an attack.
- **A step runs exactly its frames**: 20 frames of the fall, then still again; a step of 1 moved her one frame's fall (12.8 units).
- **The game's call runs before the plugin's update each frame**: a hold that only set 0 in the postfix let one more frame pass
  (6 units of rise); setting 0 when the hold is made stopped it on the next frame.
- **A 30-frame `sequence` while held** (right and Jump) moved her 190 units (30 frames at 6.33) and stopped mid-fall when it ended;
  a request's `after` is read before its last frame's movement, one frame behind.
- **Not measured**: enemies, projectiles and the systems that run on the game's unscaled delta (banner fades, dialogue printing,
  the save point's refill) while held.

### 2026-09-17 — The game's hitbox drawing in a frame capture, and what the flight recorder costs

**Evidence**: autoplay's driver (`Annotate.cs`, `Recorder.cs`) on the Steam build, at the Sewerways save point room and in Ribauld's
arena; screenshots plain, annotated and plain again of one frame, and one of the sewer's right side, pixels counted by a
script, one autoplay session.

- **`BulletManager.showHitBox(true)` draws into the captured frame**: 456 cyan pixels in a box at the player's feet (her
  `BREAK_STAND` bullet, 32 by 56) in the annotated shot, 0 in plain shots taken before and 10 frames after it; the switch was
  on for 1 frame of game update. Ribauld's `BODYBOX` drew blue. It draws while the clock is held.
- **Tags placed by the camera's edges** landed on the save point's glow and on Ribauld, also with his scene's camera zoomed in.
  Tags are drawn over the game's windows, where the hitbox lines are not (a tutorial window covered the lines, not the tag).
- **The recorder**: 0.005 to 0.02 ms a recorded frame on average, worst 0.25 to 0.53 ms, with 4 characters and 8 boxes a row.
  Nothing is recorded while the clock is held (90 frames held, the newest row unchanged). 600 idle rows fit in 42.8 KB; rows with
  boxes need every 4th.

### 2026-09-17 — Jump arcs by hold, the quickdrop, the player's hurtbox and her ground swing

**Evidence**: the flight recorder (`recent`, every frame) on the save point block and in Ribauld's arena; `observe`'s
`player.hurtbox` (Bodybox and `GameSystem.hitboxDisplay`, named from the assembly) and `projectiles` with boxes, stepped with the
clock held; the same session.

- **Rise per frame from the ground**: Jump held 24 frames 16.9, 32.9, 48.2, 62.8 ... peak 191.3 on frame 23, landing after 46
  frames; held 3 frames peak 89.7 on frame 12, landing after 27. Let go, the rise shrinks by about a quarter a frame; falling
  gains about 0.78 a frame to at most 15. Running is 6.33 a frame, in the air too.
- **A quickdrop** (down held, Jump pressed in the air): from the next frame she falls 22.5 units a frame, straight, to the ground
  (logic `QUICKDROP`), from a full jump's peak and from a short one alike.
- **Her hurtbox**: 11 wide, 15 high, centred 17 below her position, standing.
- **Her ground swing** (`TEVI_GROUND_COMBO_ATTACK`): a box 189 by 67.5 centred 45 ahead of her, there about 10 frames after the
  press; a swing's logic state (`TEVI_WEAK_GROUND_NORMAL1`) lasts about 18 frames. An air swing kept her x fixed while it ran.

### 2026-09-17 — Ribauld's attacks: lasers, blastorbs, the arena's edges, and the states before each attack

**Evidence**: the flight recorder with boxes, owners, and nearby characters' animation, logic state and hitstun; `damage_taken`
events; `observe`'s `lasers`; Cakewalk, Sewerways, from a snapshot before Ribauld (it restores at the save point, x 20671.7, not
where it was taken); read as a map beside it, `Ribauld`, `EnergyBall`, `LaserController2D` and `GemaPoolManager.CreateLaser`.

- **The fight**: a conversation (`chapter0_mainstory2-1`, 11 lines), then the Quickdrop tutorial window; at about 181-194 HP the line
  `chapter0_point3` and the Charged Shot window; 480 HP. Beating him gave the Spiral Slash popup earlier in the fight ("+[C] while
  in the air").
- **Attacks seen**, with the logic state before each and the frames from that state's start to the box's birth: a charge
  (`RIBAULD_INVISIBLE`, 80 by 75, running with him at about 9-18 units a frame) 16-17 frames into `ATTACK2`, five times of five; a
  ring of `Ribauld_BombShoot` (11 by 11) about 80 frames after `ATTACK1` began; `speeddown` (36 by 36, from his gun 72 ahead, 24 units
  a frame) and `BULLET_RIBAULD_SLOWDOWN` (25 by 25, rolling on the floor) 34 frames into `ATTACK4`, and again at 66 and 99; a
  vertical laser (`RIBAULD_CUTIN_LASER`, radius 22.2, the whole screen high) at the player's x, in `ATTACK5`.
- **A laser hit reads bullet type `NORMAL`** with no bullet near her: lasers hurt through their own circle cast, not a bullet.
- **Blastorbs**: an orb's blast (`ENERGYBALL_EXPLODE`) read 0 by 0 for two frames, then 405 by 405. Orbs knocked by Ribauld flew at
  her at 20-30 units a frame and went off beside her; blasts on Ribauld took 56 to 91 HP each (480 to 424 to 333 with no attack of
  hers). Both orbs in the arena hopped straight up on the same frame and went off as they landed, one 122 units from her. The user:
  *"the orb only explode when it touch something, not when laying idle on the ground"*.
- **The arena's edges are the camera's**: she stopped at x 22282 and 23530 with the view at 22266.5 to 23545.5, 15.5 inside each
  edge, and no solid tile there.

### 2026-09-17 — Fighting Ribauld with the dodge: hits per try

**Evidence**: `reflex` `fight` and `evade` answers and `damage_taken` events, each try from that snapshot (reached), Cakewalk;
the same session. The fight replays closely: the first charge hit landed about 1,890-1,900 frames after the restore in two tries.

| Try | Phase one | Hits | Ribauld's HP after |
| --- | --- | --- | --- |
| no dodge, melee | 2,999 frames | 9 | 172, into the phase-two line |
| `evade` only, first version | 1,800 frames | 2 | – |
| melee kept 110-150 away | 3,600 (limit) | 2 | 226 |
| ranged, 250-400 away | 2,961 | **0** | 213; phase two 1,917 frames, 1 hit (a detonating orb), beaten |
| auto (melee in reach), hugging | 3,080 | 2 | 183 |
| + quickdrop instead of falling | 2,773 | 4 | 194 |
| + tells learned (learning run) | 2,721 | 1 | 193 |
| + tells used | 3,408 | **0** (163 swings, 13 orb pushes) | 181; phase two 2,182 frames, 2 hits (charges), beaten |

- **Not measured**: which field the outline follows. The user: no outline; yellow while she is attacking it, when it is stunned and
  does no attacks; red once it has been attacked too much, until a short cooldown, when her hits do less damage, do not knock it
  back, and it attacks freely. Read as a map, a red flash comes with a hit passed as `blocked`, whose stun and knockback are zeroed.
  Also not measured: holding Attack; the fight on harder difficulties.

### 2026-09-17 — Infernal BBQ: what a normal enemy's hit costs, a death, and the play time to the first save point

**Evidence**: a new game in slot 40 started at Infernal BBQ from the title's difficulty list (the HUD read "Infernal BBQ"); `reflex` answers,
`damage_taken` events and the flight recorder; the saves' own `playtime` and `damageTakenTime` read from snapshots at
the first save point of each (Cakewalk, the first run, and Infernal BBQ), the same session.

- **A hit from a normal enemy**: a mouse 26 and 35 HP, a cat 33, a Clean Staff's and a bot's sweep (`INVISIBLE`, 80 by 75) 39; the
  Clean Staff's sweep came 40 frames into its `ATTACK1`, 50 units ahead of it. On Cakewalk the same hits cost 1.
- **Setting the difficulty with `SaveManager.SetDifficulty` on a Cakewalk save** changed the HUD's label and not a hit's cost (still 1 HP
  against Ribauld's charge); the user judged the fight unchanged on screen.
- **A death** (HP 0) showed a scene away from the area, then reloaded the last save with HP 50 of 100 and the room as it was at that save
  (the blastorbs back on their vines); every time.
- **To the first save point**: `playtime` 713.7 s and `damageTakenTime` 7 on Infernal BBQ, against 3,393.2 s and 49 on Cakewalk. Only the
  timeline kept by the saves counts: attempts lost to deaths are not in it.
- **The Outline Status tutorial** (Sewerways, as text): attacked, a target enters the yellow outline, submissive, then the red, dominant;
  submissive it takes knockback and blowback when not attacking; dominant its actions cannot be interrupted and melee does less damage.
- **Tab** in the pause menu is the `Bag` action; the options list ends with "Return to title screen", whose question Confirm answers yes.

### 2026-09-17 — Ribauld on Infernal BBQ: his HP, the laser curtain's warning, thrown orbs, and what makes a quickdrop a double jump

**Evidence**: autoplay's flight recorder (`recent`, read every frame where stated, otherwise every 3rd), `reflex` `fight` answers with
their `orb_log`, and the fight's damage events; Steam build, slot 40 (a new game started at Infernal BBQ), each try walked from the
Sewerways save point after restoring a snapshot taken there (reached), one autoplay session.

- **Ribauld has 807 HP** (480 on Cakewalk). The phase-two line (`chapter0_point3`) came at 328 to 379 HP, then the Charged Shot window.
  Beaten once, in 8,324 frames of fighting with one hit taken (30 HP); afterwards the conversations `chapter0_mainstory2-2` to `2-13`.
- **Hits on her**: his charge 45 (a second touch in the same charge 11), a `speeddown` shot 36, the bomb ring 27, an orb's blast 52 to 73,
  a cut-in laser 27 to 30.
- **The cut-in laser curtain** (`ATTACK5`): `RIBAULD_CUTIN_LASER` beams, vertical, radius 22.2, the first set 7 beams 56 apart centred on
  her x, later sets 84 apart and offset, up to 17 beams alive at once. Read every frame: a set appeared at frame 1163311 and hurt
  (`LaserController2D`'s private `hurt`) from 1163367, **56 frames**; the next set about 58 (read every 2nd frame), at the same x. A
  first reading of 138 frames was wrong: it came from rows printed only when the count of beams changed. She was hit standing in a gap
  5 units off its centre (gap about 11.6 wide between two beams) and running 25 units from a beam's centre.
- **Thrown orbs are characters, not bullets**: an `EnergyBall` came into play 26-27 frames into his `ATTACK1` (about 64 ahead of him and
  41 up) and 40 frames into `ATTACK3`; a thrown orb bounced up and down many times (`JUMPING`, `FALLING`) without going off, and went
  off on touching her. In `ATTACK3` a swing (`DISAPPEAR`, 65 wide) beside a resting orb 15 units from him sent it at her at about 16
  units a frame; it went off 45 units from her 12 frames later.
- **His charge** from beside her: the box appeared 16-17 frames into `ATTACK2` and reached her in about 5 more.
- **Her air swing landing** carried on as the air combo on the ground (`TEVI_WEAK_AIR_NORMAL1` to `3`, about 48 frames), during which a
  move she was given did not happen.
- **Quickdrop against double jump**, from the input column of every quickdrop and double jump in a 60-second stretch: each of five
  double jumps began with Down (`YAxis-`) and Jump pressed on the same frame, or with Down let go while Jump was still held; each
  quickdrop had Down held 2 frames or more before Jump. The double jump rose, frame by frame from the press, 15.0, 29.2, 42.7, 55.4,
  67.3, 78.4, 88.7, 98.3, 107.1, 115.1, 122.3, 128.8, 134.4 units, the same each time.
- **He starts no attack while his hitstun runs**: over ten more tries (the flight recorder every 3rd frame, `near`'s `hitstun_raw` and
  `armor_recovering`), 337 of 339 attack starts (`ATTACK1` to `ATTACK5`) came with his hitstun at or below 0; the two others were
  `ATTACK1` with his armor recovering. Hitstun counts down 0.05 every 3 frames: seconds of game time. His charge (`ATTACK2`) started 61
  times with the armor recovering and 61 without.
- **Hits by cause** over those ten tries (every frame before each hit): his charge the most (about 11), the bomb ring about 7 (nearly all
  in the air), cut-in lasers 3, `speeddown` and its rolling shot 3.
- **Not measured**: how far an Orbitar shot moves a resting orb; whether a quickdrop onto an orb pushes it and which way; how long a
  set of beams keeps hurting.

### 2026-09-17 — Achievements: what TEVI calls to unlock one, and a load re-applying them

**Evidence**: the Steam build's assemblies read for names (PowerShell reflection); autoplay's achievement guard, its log line and
`observe`'s `save.achievement_guard` counter, around a `restore` of a snapshot at Infernal BBQ's first save point.

- **The Steam library is Facepunch.Steamworks** (`Facepunch.Steamworks.Win64.dll`); the game's own entry points are
  `GemaSteamAPIAchievements.UnlockAchievement` and `GemaSteamAPIAccess.TrySyncAchievements`.
- **Loading a save called `UnlockAchievement` 62 times** within the restore (counter 0 before, 62 after), all skipped by the guard.
- During an autoplay fight before the guard existed, the user saw "Squeak By" unlock (beat a boss under 5% HP).
- **Not measured**: which achievement each of the 62 calls named.

## Not measured yet

### Not measured yet — backup slots and the chapter-reset slot

The code, read as a map (`SaveManager.SaveGame`, `ReallyDoAutoSave`; `SettingManager.GetBackupSaveSlotStart`,
`IncreaseBackupSaveSlot`), says: an autosave writes slot 0 and, when the player is in a new room and
`S_SYSTEM_AUTOSAVETIME_SLIDE` minutes have passed, also a backup slot, which runs from `S_SYSTEM_AUTOSAVESLOT` times 4
plus 40 up to 99 and wraps; a chapter reset saves and loads slot 100; the save list refuses a manual save and a new game
at or past the backup start. **To settle**: with a backup of the folder, watch which file changes across an autosave
after the timer, and whether slot 93 (the stored counter) is the one written.

### Not measured yet — what `mode: paused` reads from, and why the pause menu opened

The driver's `paused` is `GameSystem.isAnyPause()`. Right after the Randomizer new game above, the pause menu was open
on its Notebook tab with no injected input, and `mode` read `paused` both while it was open and for 360 frames after
Back closed it (the picture showed the player in the field). **To settle**: log `isAnyPause()` and the pause menu's own
open state each frame across opening and closing it, and whether the game opens the menu when its window loses focus.
Pointer, same day: a TEVI never focused took typing from another window ("A dialogue's lines, and input while the window is
unfocused" above), which may be what opened it; not confirmed. Pointer, later: the user tied it to a restore ("A restore lets
outside input in again" above).
