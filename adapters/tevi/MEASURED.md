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
`selected` beside screenshots of the same moments (`dev-scripts/shots/tevi/autoplay_save_list_slot39.png`, gitignored),
presses through the driver's Rewired injection; run log `autoplay/runs/2026-09-17_121000.061030.ndjson`.

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
driver (`observe`, events) around them; run log `autoplay/runs/2026-09-17_121000.061030.ndjson`, segments 3 and 4.

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
12,11; `dev-scripts/shots/tevi/autoplay_layer1_cell.png`, gitignored), the player at x 16688, y -9072.

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

**Evidence**: autoplay's driver in the cell above; run log `autoplay/runs/2026-09-17_121000.061030.ndjson` (segment 5) and the
scenario runs `2026-09-17_130522.657707.ndjson` (3 of 3 passed) and `2026-09-17_130541.142367.ndjson` (a broken copy, failed).

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
unfocused" above), which may be what opened it; not confirmed.
